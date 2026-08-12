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

# The flag set the kernel actually builds x86_64 with, mirrored from
# $(KDIR)/arch/x86/Makefile. Used by `make kflags-test` and tools/linktest.sh.
KFLAGS := -O2 -fwrapv -fno-underscoring \
          -mcmodel=kernel -mno-red-zone -fno-pic -fno-stack-protector \
          -fno-asynchronous-unwind-tables -fno-common -fno-strict-aliasing \
          -mno-sse -mno-mmx -mno-sse2 -mno-3dnow -mno-avx -mno-sse4a \
          -mno-80387 -mno-fp-ret-in-387

TESTS :=
include $(sort $(wildcard mk/*.mk))

.PHONY: test symcheck clean list kflags-test selftest audit
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

# Prove the gates reject what they claim to reject before trusting their output.
selftest:
	@bash tools/gate-selftest.sh

# Everything a translation must survive before it is considered done.
audit: selftest test kflags-test symcheck
	@bash tools/compliance.sh
	@bash tools/linktest.sh
	@echo "=== full audit clean ==="

define TEST_template
$(BUILD)/oracle-$(1).o: $(KDIR)/$(ORACLE_$(1)) | $(BUILD)
	gcc $(CFLAGS) $(CFLAGS_$(1)) -c -o $$@ $$<
$(BUILD)/fk_$(1).o: $(FSRC_$(1)) | $(BUILD)
	gfortran $(FFLAGS) -c -o $$@ $$<
$(BUILD)/drv-$(1).o: $(DRV_$(1)) | $(BUILD)
	gcc $(CFLAGS) $(CFLAGS_$(1)) -c -o $$@ $$<
$(BUILD)/run-$(1): $(BUILD)/oracle-$(1).o $(BUILD)/fk_$(1).o $(BUILD)/drv-$(1).o
	gcc -o $$@ $$^
	@./$$@
endef
$(foreach t,$(TESTS),$(eval $(call TEST_template,$(t))))

# Kernel-linkability gate: a Fortran object destined for kernel space must not
# pull in the libgfortran runtime. Any _gfortran_* undefined symbol fails.
symcheck: $(addprefix $(BUILD)/fk_,$(addsuffix .o,$(TESTS)))
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
