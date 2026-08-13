# SPDX-License-Identifier: GPL-2.0
#
# The bootable kernel image (roadmap 0.2 and 1.2).
#
# Runs INSIDE the dev container and never invokes podman itself:
#     ./tools/run.sh kernel      build build/boot/kernel.elf
#     ./tools/run.sh bootgate    build it and put it through every gate
#     ./tools/run.sh iso         build the GRUB rescue ISO
# (tools/run.sh is the podman wrapper; ./Makefile forwards these targets here.)
#
# DELIBERATELY SEPARATE from ./Makefile, which is the Phase 1 differential-test
# harness. That harness builds HOST objects with host flags and links them
# against a C oracle; this builds KERNEL objects with kernel flags and links
# them against nothing. Sharing one file would mean sharing one BUILD directory
# and one FFLAGS, and mixing the two flag sets in one object directory is a
# genuinely hard bug to see. Nothing here writes outside build/boot/.

# --- isolation guard ---------------------------------------------------------
# The host also has gcc and ld, so without this guard a stray `make -f
# Makefile.boot` on the host would half-build against the host toolchain. Fail
# loudly instead. Podman and Docker both drop a marker file.
FK_IN_CONTAINER := $(wildcard /run/.containerenv /.dockerenv)
ifeq ($(strip $(FK_IN_CONTAINER)$(FK_ALLOW_HOST_BUILD)),)
$(error This build must run inside the dev container: use ./tools/run.sh kernel \
  (set FK_ALLOW_HOST_BUILD=1 only if you really mean to build on the host))
endif

# The kernel flag set, from the one place it is defined.
include mk/kflags.mk

BUILD  := build/boot
ISODIR := $(BUILD)/isodir
KERNEL := $(BUILD)/kernel.elf
ISO    := $(BUILD)/fortran-kernel.iso

FC := gfortran
CC := gcc
LD := ld
NM := nm

# boot.S goes through gcc, not as, so that cpp runs on it: the PHYS() macro
# that converts every higher-half symbol to its physical address is a cpp
# macro, and without the preprocessor the file does not assemble.
AFLAGS_KERNEL := -m64 -fno-pic -Wall

FFLAGS_KERNEL := $(KFLAGS) -Wall -J$(BUILD) -I$(BUILD)

# -z max-page-size=0x1000 is NOT optional and NOT a size optimisation.
# GNU ld defaults to a 2 MiB max page size on x86-64 and pads every PT_LOAD out
# to it; with three segments that is up to 6 MiB of zero padding around a 19 KiB
# kernel, and GRUB then loads all of it. linker.ld documents the flag as a
# requirement of the script; this is where it is honoured.
LDFLAGS_KERNEL := -nostdlib -z max-page-size=0x1000 -T linker.ld

# Fortran sources linked into the image, in module-dependency order.
#
# THE ORDER OF THIS LIST IS SEMANTIC, not cosmetic: fk_idt USEs fk_gdt_m and
# fk_serial_m, fk_kmain USEs all three, and a .mod exists only once the module
# that produces it has been compiled. The generator under "module ordering"
# below turns this list's order into real prerequisites, which is what makes
# that true under `make -j` as well as serially.
#
# Only the boot path is here, and that rule has NOT been relaxed. The library
# and driver modules are proven to link into this layout by
# tools/linkscript-test.sh, which links ALL of them against the real boot stub;
# putting them in the bootable image as well would add code with no caller to
# the thing being booted, which is exactly the kind of unexplained bulk a boot
# failure then has to be untangled from. fk_serial is in the image for precisely
# the reason the rule states: roadmap 2.1 made kernel_main CALL it, so it is
# boot path now, not library. fk_gdt and fk_idt clear the same bar for roadmap
# 3.1/3.2, fk_pmm for 3.4, and the next module to appear here has to clear it
# too.
FSRC_KERNEL := src/drivers/serial/fk_serial.f90 \
               src/cpu/fk_gdt.f90 \
               src/cpu/fk_tss.f90 \
               src/cpu/fk_idt.f90 \
               src/drivers/pic/fk_pic.f90 \
               src/mm/fk_pmm.f90 \
               src/lib/fk_string.f90 \
               src/lib/fk_string_abi.f90 \
               src/mm/fk_vmm.f90 \
               src/boot/fk_kmain.f90

# Assembly sources. NAMED ONE BY ONE, deliberately not $(wildcard boot/*.S):
# with a wildcard, what ends up inside the bootable image would be a function of
# what happens to be sitting in the directory -- a half-finished experiment, a
# file left behind by a rebase -- and nothing would say so. The image's contents
# are a decision, so they are written down.
#
# tools/linkscript-test.sh does the exact OPPOSITE and globs boot/*.S, which is
# not a contradiction to resolve but two different jobs: that gate exists so
# that no assembly file in the tree can escape review, so it must see whatever
# is on disk; this list exists to state what the shipped image contains, so it
# must see only what somebody chose to put in it.
#
# boot.S is listed first by convention only. It is NOT what puts the Multiboot2
# header in the first 32 KiB: linker.ld pins .multiboot_header by section name
# with KEEP() as its first output section and ASSERTs the 32 KiB bound, so input
# object order does not decide it, and `make mbcheck` would catch it if it did.
ASRC_KERNEL := boot/boot.S \
               boot/io.S \
               boot/gdt_flush.S \
               boot/interrupts.S \
               boot/faultgen.S \
               boot/ksyms.S \
               boot/mmu.S

AOBJ := $(patsubst boot/%.S,$(BUILD)/%.o,$(ASRC_KERNEL))
FOBJ := $(foreach s,$(FSRC_KERNEL),$(BUILD)/$(basename $(notdir $(s))).o)
OBJS := $(AOBJ) $(FOBJ)

# Objects are flattened into one directory by basename, so two sources whose
# basenames match -- in different directories, which this tree already has --
# would compile onto the SAME .o, and the image would quietly contain whichever
# one make built last. ./Makefile survives that by mangling the name
# (fk_<test>__<base>.o) because it juggles many independent test binaries; the
# kernel image is a single namespace where the honest answer is to refuse to
# build rather than to invent a mangling nobody reads. $(sort) removes
# duplicates, so a sorted list that is shorter than the original IS the
# collision, detected before a single compiler runs.
ifneq ($(words $(OBJS)),$(words $(sort $(OBJS))))
$(error two kernel sources share a basename, so they would share an object file \
  in $(BUILD): [$(OBJS)] -- rename one, or teach this file to mangle names)
endif

# Undefined symbols that mean a libgfortran or libc runtime crept in.
# _gfortran_ is matched as a substring (the prefix is the whole tell); the libc
# names are matched whole-line so that e.g. "free_page" is not a hit.
#
# The mem* half of that list changed meaning at roadmap 1.3 and the gate had to
# change with it. gcc's loop-distribution pass rewrites an array fill into a
# call to memset BY NAME, so `U memset` in fk_pmm.o is now the pass working as
# intended rather than a libc creeping in -- provided this image defines memset
# itself, which src/lib/fk_string_abi.f90 does. So the rule is no longer "these
# names may not appear" but "these names may not appear UNRESOLVED", and the
# distinction is checked against what the image actually defines rather than
# against a list somebody keeps up to date. malloc/free/printf/puts stay
# unconditional: nothing in a kernel with no allocator and no console
# formatting may define them either.
BADSYM_RE       := _gfortran_|^(memcpy|memset|memmove|memcmp)$$
NEVERSYM_RE     := ^(malloc|free|printf|puts|calloc|realloc|abort|exit)$$

.DEFAULT_GOAL := kernel
.PHONY: kernel iso mbcheck symcheck-boot undefcheck-boot bootgate selftest-boot \
        clean-boot
# A failed post-link gate must not leave a bogus kernel.elf behind for the QEMU
# boot test to pick up and "boot".
.DELETE_ON_ERROR:

kernel: $(KERNEL)
iso: $(ISO)

# --- compilation -------------------------------------------------------------
# The assembly sources stay on ONE pattern rule: every file in ASRC_KERNEL lives
# in boot/, so a single stem covers all of them and there is no second directory
# for the stem to be ambiguous about. Explicit rules always beat a pattern rule
# in GNU make, so the Fortran objects generated below are never matched against
# a boot/<name>.S that does not exist.
$(BUILD)/%.o: boot/%.S | $(BUILD)
	$(CC) $(AFLAGS_KERNEL) -c -o $@ $<

# One EXPLICIT rule per Fortran source, generated with $(foreach)/$(eval) --
# the same idiom ./Makefile uses for FSRC_template, for the same reason.
#
# What this replaces is the single pattern rule '$(BUILD)/%.o: src/boot/%.f90',
# which matched src/boot and nothing else; fk_serial.f90 lives in
# src/drivers/serial. The one-line repair would be a vpath, and it is the wrong
# repair: vpath resolves a stem by SEARCHING a directory list and takes the
# first basename that matches, so the file compiled into the kernel would be
# chosen by directory order rather than named by FSRC_KERNEL. This tree already
# holds same-named sources in different directories -- that is exactly why
# ./Makefile has to name its objects fk_<test>__<base>.o -- so the day a second
# fk_<something>.f90 appears, a vpath build silently compiles the wrong one and
# still succeeds. An explicit rule carries the full path of its prerequisite and
# has nothing to search.
define FOBJ_template
$(BUILD)/$(basename $(notdir $(1))).o: $(1) | $(BUILD)
	$(FC) $$(FFLAGS_KERNEL) -c -o $$@ $$<
endef
$(foreach s,$(FSRC_KERNEL),$(eval $(call FOBJ_template,$(s))))

# --- module ordering ---------------------------------------------------------
# gfortran writes fk_serial_m.mod as a SIDE EFFECT of producing fk_serial.o, and
# fk_kmain.f90's `use fk_serial_m` cannot compile until that .mod exists on the
# -I path. Nothing in the graph above orders the two compilations, so under
# `make -j` they race: the build fails perhaps one time in N with "Cannot open
# module file", and both a serial rebuild and a plain retry then pass. That is
# the most expensive class of build bug there is, so the order is stated instead
# of hoped for.
#
# Chain each object on the previous one in FSRC_KERNEL order, exactly as
# ./Makefile does for FSRC_<test>. Spelling the prerequisite on the .o rather
# than on the .mod is deliberate: gfortran leaves an unchanged .mod's timestamp
# alone when it recompiles, so a .mod-as-target rule never looks satisfied and
# oscillates between out-of-date and up-to-date forever.
fk_prev :=
$(foreach o,$(FOBJ),\
  $(if $(fk_prev),$(eval $(o): $(fk_prev)))\
  $(eval fk_prev := $(o)))

# --- link --------------------------------------------------------------------
$(KERNEL): $(OBJS) linker.ld | $(BUILD)
	$(LD) $(LDFLAGS_KERNEL) -o $@ $(OBJS)
	@$(MAKE) --no-print-directory -f Makefile.boot mbcheck

# --- gates -------------------------------------------------------------------
# THE MANDATED GATE plus the one it cannot replace.
#
# grub2-file (Fedora's name for grub-file) answers "is there a well-formed
# Multiboot2 header here". tools/mb2-check.py answers "and can this image
# actually be entered" -- entry-address tag present, agreeing with e_entry,
# 32-bit, inside a loaded executable segment. For a higher-half kernel the
# second question is the one that decides whether the machine boots or reboots,
# and grub2-file passes an image that fails it. See that file's header.
mbcheck: $(KERNEL)
	@if grub2-file --is-x86-multiboot2 $(KERNEL); then \
	   echo "  OK    grub2-file --is-x86-multiboot2 $(KERNEL) -> exit 0"; \
	 else \
	   echo "  FAIL  grub2-file --is-x86-multiboot2 $(KERNEL) -> exit $$?"; \
	   echo "        GRUB does not recognise a Multiboot2 header in this image."; \
	   exit 1; \
	 fi
	@python3 tools/mb2-check.py $(KERNEL)

# Necessary condition for a kernel with no runtime: no Fortran object may
# reference libgfortran or a libc. nm -P prints "name Type ...", so the bare
# symbol name is field 1.
#
# WHAT THIS GATE MUST NOT FLAG, now that there are two Fortran objects:
# fk_serial.o legitimately arrives with fk_outb and fk_inb UNDEFINED. They are
# defined in $(BUILD)/io.o, assembled from boot/io.S, because IN and OUT are
# privileged instructions with no Fortran spelling -- the same situation as
# fk_kmain.o's undefined fk_cpu_halt, which this gate has always let through.
# BADSYM_RE does not match either name and cannot start to: '_gfortran_' is a
# substring test that no name beginning "fk_" can satisfy, and the libc half is
# anchored ^(...)$ around whole symbol names, so only those seven exact names
# hit. Nothing here proves those two symbols RESOLVE -- the link does, and an
# unresolved fk_outb fails $(KERNEL) loudly rather than silently.
symcheck-boot: $(OBJS)
	@provided=`for o in $(OBJS); do $(NM) -g --defined-only -P $$o 2>/dev/null \
	             | cut -d' ' -f1; done | sort -u`; \
	 fail=0; for o in $(FOBJ); do \
	  bad=""; \
	  for u in `$(NM) -u -P $$o | cut -d' ' -f1`; do \
	    case "$$u" in \
	      *_gfortran_*) bad="$$bad $$u(libgfortran)"; continue ;; \
	    esac; \
	    if printf '%s\n' "$$u" | grep -qE '$(NEVERSYM_RE)'; then \
	      bad="$$bad $$u(libc)"; continue; \
	    fi; \
	    if printf '%s\n' "$$u" | grep -qE '$(BADSYM_RE)'; then \
	      printf '%s\n' "$$provided" | grep -qx -- "$$u" \
	        || bad="$$bad $$u(no definition in this image)"; \
	    fi; \
	  done; \
	  if [ -n "$$bad" ]; then \
	    echo "  FAIL  $$o references a userspace runtime:"; \
	    for b in $$bad; do echo "        $$b"; done; fail=1; \
	  else \
	    echo "  OK    $$o  (`$(NM) -u $$o | wc -l` undefined symbols)"; \
	  fi; \
	done; \
	[ $$fail -eq 0 ] && echo "  === no libgfortran/libc dependency in the kernel objects ==="; \
	exit $$fail

# The other half of the same question, asked of the IMAGE rather than of an
# object: an undefined symbol in a -nostdlib link is a symbol nothing will ever
# supply. `ld` itself does not refuse one for a non-PIE static link, so a typo'd
# bind(c) name reaches the CPU as a call to address zero.
undefcheck-boot: $(KERNEL)
	@u=`$(NM) -u $(KERNEL) | sed 's/^ *//'`; \
	 if [ -n "$$u" ]; then \
	   echo "  FAIL  $(KERNEL) has undefined symbols:"; \
	   printf '%s\n' "$$u" | sed 's/^/        /'; exit 1; \
	 fi; \
	 echo "  OK    $(KERNEL) has no undefined symbols"
	@for s in memset memcpy memmove memcmp; do \
	   $(NM) --defined-only $(KERNEL) | grep -qE "[[:space:]]T[[:space:]]$$s$$" \
	     || { echo "  FAIL  the image does not define $$s (roadmap 1.3)"; exit 1; }; \
	 done; \
	 echo "  OK    the image defines memset/memcpy/memmove/memcmp itself"
# THE INTRINSIC MUST NOT CALL ITSELF. gcc's loop-distribution pass is enabled
# again as of roadmap 1.3, and the thing that stops it rewriting fk_memset's own
# byte loop into a call to memset is that c_f_pointer gives the array a run-time
# stride the pass cannot recognise -- measured on gfortran 16.1.1, which is a
# property of a compiler version and not a guarantee. Linux buys the same safety
# structurally, with -ffreestanding on lib/string.c.
#
# So it is checked rather than assumed, and checked where it is unambiguous: the
# translation unit that IMPLEMENTS the intrinsics may not reference one. If the
# pass ever fires here, memset -> fk_memset -> memset recurses until the stack
# walks off the bottom, and this line fails the build instead.
	@bad=`$(NM) -u -P $(BUILD)/fk_string.o | cut -d' ' -f1 \
	      | grep -E '^(memcpy|memset|memmove|memcmp)$$'`; \
	 if [ -n "$$bad" ]; then \
	   echo "  FAIL  fk_string.o CALLS an intrinsic it implements:"; \
	   printf '%s\n' "$$bad" | sed 's/^/        /'; \
	   echo "        the loop-distribution pass has rewritten one of the bodies"; \
	   echo "        into a call to itself -- it would recurse until the stack"; \
	   echo "        falls through the guard page."; exit 1; \
	 fi; \
	 echo "  OK    fk_string.o implements the intrinsics without calling one" 

# Prove the header gate can FAIL before trusting the fact that it passes.
selftest-boot: $(KERNEL)
	@bash tools/mb2-selftest.sh $(KERNEL)

# Everything the boot path must survive inside the container. The remaining
# gate -- does it actually boot -- needs a VM and therefore runs on the host:
# tools/qemu-boot-test.sh.
bootgate: $(KERNEL) mbcheck symcheck-boot undefcheck-boot selftest-boot
	@echo "=== boot path gates clean: header valid, image enterable, no runtime ==="

# --- ISO ---------------------------------------------------------------------
# timeout=0 with default=0 boots straight through: a headless boot test must
# never sit at a menu waiting for a keypress that will not come.
$(ISO): $(KERNEL)
	rm -rf $(ISODIR)
	mkdir -p $(ISODIR)/boot/grub
	cp $(KERNEL) $(ISODIR)/boot/kernel.elf
	printf '%s\n' \
	  'set timeout=0' \
	  'set default=0' \
	  '' \
	  'menuentry "PROJECT FORTRAN-KERNEL" {' \
	  '    multiboot2 /boot/kernel.elf' \
	  '    boot' \
	  '}' > $(ISODIR)/boot/grub/grub.cfg
# NOT `grub2-mkrescue ... | sed`: make takes a pipeline's status from its LAST
# command, so sed's zero would mask a mkrescue that died -- and mkrescue that
# dies before it opens the output leaves the PREVIOUS run's ISO in place, which
# `test -s` then accepts because it is a non-emptiness test and not a freshness
# one. The gate downstream compounds it: tools/qemu-boot-test.sh boots the ISO
# but derives every address it asserts from kernel.elf, so a constant-only
# defect moves no symbol and the whole boot passes against a kernel that is no
# longer on disk. `rm -f` first is what turns `test -s` into a freshness test.
	@rm -f $@
	@grub2-mkrescue -o $@ $(ISODIR) > $(BUILD)/mkrescue.log 2>&1; rc=$$?; \
	 sed 's/^/  /' $(BUILD)/mkrescue.log; \
	 [ $$rc -eq 0 ] || { echo "  FAIL  grub2-mkrescue exited $$rc"; exit 1; }
	@test -s $@ || { echo "  FAIL  grub2-mkrescue wrote no $@"; exit 1; }
	@echo "  OK    $@ (`wc -c < $@` bytes)"

# --- housekeeping ------------------------------------------------------------
$(BUILD):
	@mkdir -p $(BUILD)

clean-boot:
	rm -rf $(BUILD)
