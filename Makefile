# Phase 1 differential test build. Runs INSIDE the podman container only
# (./tools/run.sh). Never invoke on the host toolchain.
#
# Adding a translation requires NO edit to this file -- drop a fragment in
# mk/<name>.mk declaring four variables. This keeps parallel agents from
# colliding on a shared Makefile.
KDIR   := vendor/linux-7.1.8
BUILD  := build
CFLAGS := -O2 -std=gnu11 -Wall -Itests/shims -Itests/harness -fno-builtin
FFLAGS := -O2 -fwrapv -fno-underscoring -Wall -Jbuild

TESTS :=
include $(sort $(wildcard mk/*.mk))

.PHONY: test symcheck clean list
test: $(addprefix $(BUILD)/run-,$(TESTS))
	@echo "=== all $(words $(TESTS)) translation(s) matched the C oracle ==="

define TEST_template
$(BUILD)/oracle-$(1).o: $(KDIR)/$(ORACLE_$(1)) | $(BUILD)
	gcc $(CFLAGS) $(CFLAGS_$(1)) -c -o $$@ $$<
$(BUILD)/fk_$(1).o: $(FSRC_$(1)) | $(BUILD)
	gfortran $(FFLAGS) -c -o $$@ $$<
$(BUILD)/drv-$(1).o: $(DRV_$(1)) | $(BUILD)
	gcc $(CFLAGS) -c -o $$@ $$<
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
	rm -rf $(BUILD)
