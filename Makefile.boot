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
# Only the boot path is here on purpose. The library and driver modules are
# proven to link into this layout by tools/linkscript-test.sh, which links ALL
# of them against the real boot stub; putting them in the bootable image as
# well would add code with no caller to the thing being booted, which is
# exactly the kind of unexplained bulk a boot failure then has to be untangled
# from.
FSRC_KERNEL := src/boot/fk_kmain.f90

AOBJ := $(BUILD)/boot.o
FOBJ := $(patsubst src/boot/%.f90,$(BUILD)/%.o,$(FSRC_KERNEL))
OBJS := $(AOBJ) $(FOBJ)

# Undefined symbols that mean a libgfortran or libc runtime crept in.
# _gfortran_ is matched as a substring (the prefix is the whole tell); the libc
# names are matched whole-line so that e.g. "free_page" is not a hit.
BADSYM_RE := _gfortran_|^(memcpy|memset|memmove|malloc|free|printf|puts)$$

.DEFAULT_GOAL := kernel
.PHONY: kernel iso mbcheck symcheck-boot bootgate selftest-boot clean-boot
# A failed post-link gate must not leave a bogus kernel.elf behind for the QEMU
# boot test to pick up and "boot".
.DELETE_ON_ERROR:

kernel: $(KERNEL)
iso: $(ISO)

# --- compilation -------------------------------------------------------------
$(AOBJ): boot/boot.S | $(BUILD)
	$(CC) $(AFLAGS_KERNEL) -c -o $@ $<

$(BUILD)/%.o: src/boot/%.f90 | $(BUILD)
	$(FC) $(FFLAGS_KERNEL) -c -o $@ $<

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
symcheck-boot: $(FOBJ)
	@fail=0; for o in $^; do \
	  bad=`$(NM) -u -P $$o | cut -d' ' -f1 | grep -E '$(BADSYM_RE)'`; \
	  if [ -n "$$bad" ]; then \
	    echo "  FAIL  $$o references a userspace runtime:"; \
	    printf '%s\n' "$$bad" | sed 's/^/        /'; fail=1; \
	  else \
	    echo "  OK    $$o  (`$(NM) -u $$o | wc -l` undefined symbols)"; \
	  fi; \
	done; \
	[ $$fail -eq 0 ] && echo "  === no libgfortran/libc dependency in the kernel objects ==="; \
	exit $$fail

# Prove the header gate can FAIL before trusting the fact that it passes.
selftest-boot: $(KERNEL)
	@bash tools/mb2-selftest.sh $(KERNEL)

# Everything the boot path must survive inside the container. The remaining
# gate -- does it actually boot -- needs a VM and therefore runs on the host:
# tools/qemu-boot-test.sh.
bootgate: $(KERNEL) mbcheck symcheck-boot selftest-boot
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
	grub2-mkrescue -o $@ $(ISODIR) 2>&1 | sed 's/^/  /'
	@test -s $@ || { echo "  FAIL  grub2-mkrescue produced an empty $@"; exit 1; }
	@echo "  OK    $@ (`wc -c < $@` bytes)"

# --- housekeeping ------------------------------------------------------------
$(BUILD):
	@mkdir -p $(BUILD)

clean-boot:
	rm -rf $(BUILD)
