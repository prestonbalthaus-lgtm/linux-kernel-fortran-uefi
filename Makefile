# Phase 1 differential test build. Runs INSIDE the podman container only
# (./tools/run.sh). Never invoke on the host toolchain.
#
# Adding a translation requires NO edit to this file -- drop a fragment in
# mk/<name>.mk declaring four variables. This keeps parallel agents from
# colliding on a shared Makefile.
KDIR   := vendor/linux-7.1.8
BUILD  := build
CFLAGS := -O2 -std=gnu11 -Wall -Itests/shims -Itests/harness -fno-builtin

# -fwrapv is CORRECTNESS-CRITICAL, not an optimisation preference. Every
# translation carries u32/u64 bit patterns in signed integers and relies on
# two's-complement wrap being defined rather than UB. Removing it does not fail
# the suite today (GCC 16 at -O2 does not exploit the UB here) -- which is
# exactly why it must not be dropped casually. See docs/AUDIT-PHASE1.md, A-4.
FFLAGS := -O2 -fwrapv -fno-underscoring -Wall -J$(BUILD)

# KFLAGS -- the real kernel flag set -- now lives in mk/kflags.mk, because
# Makefile.boot and tools/linkscript-test.sh must use exactly the same list and
# a second copy would eventually disagree with this one. It arrives via the
# wildcard include below.
TESTS :=
include $(sort $(wildcard mk/*.mk))

# Stated explicitly: mk/*.mk is a wildcard, and a fragment that ever defines a
# rule would otherwise silently steal the default goal from `test`.
.DEFAULT_GOAL := test

.PHONY: test symcheck clean list kflags-test selftest audit linkscript \
        kernel iso mbcheck symcheck-boot undefcheck-boot clean-boot bootgate
test: $(addprefix $(BUILD)/run-,$(TESTS))
	@echo "=== all $(words $(TESTS)) translation(s) matched the C oracle ==="

# The differential suite proves correctness for objects built with FFLAGS, but
# linktest.sh proves kernel-linkability for objects built with KFLAGS -- two
# different binaries. This target closes that gap by running the SAME oracle
# comparison against kernel-flag objects. Separate BUILD dir so it never leaves
# mixed-flag objects behind in build/.
kflags-test:
	@$(MAKE) --no-print-directory BUILD=build-kflags \
	         FFLAGS="$(KFLAGS) -Jbuild-kflags" test
	@echo "=== oracle match holds under the real kernel flag set ==="

# Roadmap 0.1: does linker.ld lay the image out the way it claims? Links the
# real nine modules, not a toy object.
linkscript:
	@bash tools/linkscript-test.sh

# Prove the gates reject what they claim to reject before trusting their output.
selftest:
	@bash tools/gate-selftest.sh

# Roadmap 1.2/0.2: the bootable kernel image. Delegated to Makefile.boot so
# that the Phase 1 differential harness above cannot be disturbed by boot work
# -- different flags, different objects, different output directory.
kernel iso mbcheck symcheck-boot undefcheck-boot clean-boot bootgate:
	@$(MAKE) --no-print-directory -f Makefile.boot $@

# Everything a translation must survive before it is considered done.
audit: selftest test kflags-test symcheck
	@bash tools/compliance.sh
	@bash tools/linktest.sh
	@bash tools/linkscript-test.sh
	@$(MAKE) --no-print-directory -f Makefile.boot bootgate
	@echo "=== full audit clean ==="

# FSRC_<test> is a LIST, in module-dependency order: a translation may be split
# across several modules (fk_font_8x16 + fk_gop_renderer), and splitting one is
# a refactor of the code under test, not a reason to fight the harness.
#
# Objects are named fk_<test>__<basename>.o so two tests may name a source file
# the same way without silently overwriting each other's object.
fobj = $(foreach s,$(FSRC_$(1)),$(BUILD)/fk_$(1)__$(basename $(notdir $(s))).o)

define FSRC_template
$(BUILD)/fk_$(1)__$(basename $(notdir $(2))).o: $(2) | $(BUILD)
	gfortran $$(FFLAGS) -c -o $$@ $$<
endef

# Of the four variables a fragment declares, ORACLE_<name> is the only one that
# is OPTIONAL.
#
# Every translation up to now had a single C function it was translated FROM, so
# naming that file under $(KDIR) and diffing against it was the entire method.
# mk/serial.mk is the first fragment with no such original: a 16550 UART driver
# is a translation of a hardware specification, not of a C file, and the nearest
# thing the kernel tree holds -- include/uapi/linux/serial_reg.h -- is a header
# of register offsets and bit masks that compiles to no code at all. Its test
# includes that header DIRECTLY, so the register numbers are still checked
# against the kernel's own, and diffs the driver's port-write trace against a
# reference model in the test itself. There is simply nothing for gcc to build
# into oracle-serial.o.
#
# Without the guard, omitting ORACLE_<name> does not produce a clear error: the
# prerequisite expands to "$(KDIR)/" -- the vendor directory itself -- and gcc is
# asked to compile a directory, naming neither the fragment nor the variable
# that is missing.
#
# The guard has to appear TWICE and both halves are load-bearing: once around
# the compile rule, so no rule for an oracle object is generated at all, and
# once in run-<name>'s prerequisites, so the link does not ask for an object
# that nothing knows how to build.
#
# The promise at the top of this file is intact: adding a translation still
# requires NO edit here. A fragment declares an oracle if it has one and stays
# silent if it does not.
define TEST_template
$(if $(ORACLE_$(1)),
$(BUILD)/oracle-$(1).o: $(KDIR)/$(ORACLE_$(1)) | $(BUILD)
	gcc $(CFLAGS) $(CFLAGS_$(1)) -c -o $$@ $$<
)
$(BUILD)/drv-$(1).o: $(DRV_$(1)) | $(BUILD)
	gcc $(CFLAGS) $(CFLAGS_$(1)) -c -o $$@ $$<
$(BUILD)/run-$(1): $(if $(ORACLE_$(1)),$(BUILD)/oracle-$(1).o) $(call fobj,$(1)) $(BUILD)/drv-$(1).o
	gcc -o $$@ $$^
	@./$$@
endef
$(foreach t,$(TESTS),$(foreach s,$(FSRC_$(t)),$(eval $(call FSRC_template,$(t),$(s)))))
$(foreach t,$(TESTS),$(eval $(call TEST_template,$(t))))

# gfortran emits <module>.mod as a SIDE EFFECT of producing the .o, and a USE
# cannot compile until that .mod exists. Chain each object on the previous one
# so `make -j` honours the order the fragment declares instead of racing on it.
# (Spelling the prerequisite on the .o rather than on the .mod is deliberate:
# gfortran leaves an unchanged .mod's timestamp alone, so a .mod-as-target rule
# oscillates between out-of-date and up-to-date forever.)
$(foreach t,$(TESTS),\
  $(eval fk_prev :=)\
  $(foreach o,$(call fobj,$(t)),\
    $(if $(fk_prev),$(eval $(o): $(fk_prev)))\
    $(eval fk_prev := $(o))))

# Kernel-linkability gate: a Fortran object destined for kernel space must not
# pull in the libgfortran runtime. Any _gfortran_* undefined symbol fails.
symcheck: $(foreach t,$(TESTS),$(call fobj,$(t)))
	@fail=0; for o in $^; do \
	  if nm -u $$o | grep -q '_gfortran_'; then \
	    echo "  FAIL $$o depends on libgfortran:"; nm -u $$o | grep '_gfortran_'; fail=1; \
	  else echo "  OK   $$o  ($$(nm -u $$o | wc -l) undefined symbols)"; fi; \
	done; exit $$fail

list:
	@echo $(TESTS)
$(BUILD):
	@mkdir -p $(BUILD)
clean:
	rm -rf build build-kflags
