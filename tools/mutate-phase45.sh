#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Drives the mutation tables in docs/HARNESS-VALIDATION-PHASE4.md and
# docs/HARNESS-VALIDATION-PHASE5.md: injects one defect at a time into the
# roadmap 4.1/4.2/5.1 code, rebuilds from clean, boots it and restores the
# tree.  The baseline must PASS; a MUTATION that passes is an ESCAPE, because
# the gate accepted a kernel with a known defect.
#
# Edits the working tree in place and restores with `git checkout`, so run it
# on a clean tree.  Needs a VM, so it runs on the host, not in the container.
#
#   tools/mutate-phase45.sh            every case
#   tools/mutate-phase45.sh M45 M53    only those
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${FK_MUTATE_OUT:-$(mktemp -d /tmp/fk-mutate45.XXXXXX)}"
mkdir -p "$OUT"
echo "logs: $OUT"

# EVERY FILE ANY CASE BELOW MUTATES MUST BE IN THIS LIST -- restore() rewinds
# exactly these, so a case that seds a file not named here leaves its mutation
# behind and it gets reported against the next defect.
FILES="src/acpi/fk_acpi.f90 src/acpi/fk_madt.f90 src/acpi/fk_mcfg.f90 \
       src/drivers/bus/fk_pcie.f90 src/drivers/bus/fk_pcie_types.f90 \
       src/drivers/usb/fk_xhci.f90 src/drivers/usb/fk_xhci_types.f90 \
       src/mm/fk_vmm.f90 src/boot/fk_kmain.f90"

restore() { git checkout -- $FILES 2>/dev/null; }

for f in $FILES; do
  git ls-files --error-unmatch "$f" >/dev/null 2>&1 || {
    echo "ABORT: $f is not tracked -- 'git checkout --' cannot restore it."
    echo "       git add it first."; exit 1; }
done
if ! git diff --quiet -- $FILES && [ -z "${FK_MUTATE_FORCE:-}" ]; then
  echo "ABORT: unstaged changes in the files this script mutates:"
  git status --short -- $FILES | sed 's/^/       /'
  echo "       git add or stash them; the first restore would discard them."
  echo "       FK_MUTATE_FORCE=1 to override."; exit 1
fi

# A substitution that matched nothing is a case that silently tested the
# BASELINE and reported it as an escape.  Refuse instead.
subst() {
  local file=$1 from=$2 to=$3
  python3 - "$file" "$from" "$to" <<'PY' || { echo "SUBST FAILED in $file"; exit 1; }
import sys
path, frm, to = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if frm not in s:
    sys.exit(1)
open(path, 'w').write(s.replace(frm, to, 1))
PY
}

run_case() {
  local name=$1
  ./tools/run.sh clean-boot >/dev/null 2>&1
  if ! ./tools/run.sh iso >"$OUT/$name.build" 2>&1; then
    echo "$name: BUILD FAILED (caught at build time)"
    restore; return
  fi
  FK_CHECK_HW=1 tools/qemu-boot-test.sh >"$OUT/$name.log" 2>&1
  local rc=$? line
  line=$(sed 's/\x1b\[[0-9;]*m//g' "$OUT/$name.log" \
         | grep -aE "^(QEMU EXITED|THE HARDWARE|COM1 CARRIED|Sentinel assertion)|^  FAIL  |^      (MISSING|PRESENT)  :|^    no  " \
         | head -3 | tr -d '\r' | sed 's/^ *//' | paste -sd'|')
  if [ $rc -eq 0 ]; then
    if [ "$name" = baseline ]; then echo "$name: boot gate PASSED :: $line"
    else echo "$name: boot gate PASSED  <-- ESCAPE :: $line"; fi
  else                   echo "$name: boot gate FAILED (caught) :: $line"; fi
  restore
}

SELECT="$*"
want_case() { [ -z "$SELECT" ] && return 0; case " $SELECT " in *" $1 "*) return 0;; esac; return 1; }

case_baseline() { run_case baseline; }

# --- roadmap 4.1: ACPI and the MADT ------------------------------------------
case_M40() {
  subst src/acpi/fk_acpi.f90 \
    $'    if (.not. sum_zero(off, RSDP_V1_LEN)) then' \
    $'    if (.false.) then'
  run_case M40-rsdp-checksum-ignored
}
case_M41() {
  subst src/acpi/fk_madt.f90 \
    $'       if (elen < 2_c_int32_t) then\n          status = FK_MADT_E_ENTRY_ZERO\n          return\n       end if' \
    $'       if (elen < 0_c_int32_t) then\n          status = FK_MADT_E_ENTRY_ZERO\n          return\n       end if'
  run_case M41-zero-length-entry-admitted
}
case_M42() {
  subst src/acpi/fk_madt.f90 \
    $'          iso_gsi(n_iso) = d32(off + 4_c_int32_t)' \
    $'          iso_gsi(n_iso) = d32(off + 8_c_int32_t)'
  run_case M42-iso-gsi-from-wrong-offset
}
case_M43() {
  subst src/acpi/fk_madt.f90 \
    $'       if (elen > hlen - off) then\n          status = FK_MADT_E_ENTRY_OVERRUN\n          return\n       end if' \
    ''
  run_case M43-entry-overrun-guard-removed
}
case_M44() {
  subst src/acpi/fk_madt.f90 \
    $'          ioa_gsi(n_ioa)  = d32(off + 8_c_int32_t)' \
    $'          ioa_gsi(n_ioa)  = d32(off + 4_c_int32_t)'
  run_case M44-ioapic-gsi-base-from-wrong-offset
}

# --- roadmap 4.2: ECAM, the walk, capabilities -------------------------------
case_M45() {
  subst src/drivers/bus/fk_pcie_types.f90 \
    "FK_PCI_ECAM_DEV_SHIFT = 15_c_int32_t" \
    "FK_PCI_ECAM_DEV_SHIFT = 16_c_int32_t"
  run_case M45-ecam-device-shift-16
}
case_M46() {
  subst src/drivers/bus/fk_pcie_types.f90 \
    "FK_PCI_ECAM_FUNC_SHIFT = 12_c_int32_t" \
    "FK_PCI_ECAM_FUNC_SHIFT = 11_c_int32_t"
  run_case M46-ecam-function-shift-11
}
case_M47() {
  subst src/drivers/bus/fk_pcie.f90 \
    $'    p = shiftl(ibits(raw, FK_PCI_CAP_PTR_POS, FK_PCI_CAP_PTR_LEN), &\n               FK_PCI_CAP_PTR_POS)' \
    $'    p = iand(raw, int(z\'FF\', c_int32_t))'
  run_case M47-cap-pointer-low-bits-kept
}
case_M48() {
  subst src/drivers/bus/fk_pcie.f90 \
    $'    o = iand(pcie_cfg_read32(bus, dev, fn, cap + MSIX_OFF_TBL), &\n             not(7_c_int32_t))' \
    $'    o = pcie_cfg_read32(bus, dev, fn, cap + MSIX_OFF_TBL)'
  run_case M48-msix-table-offset-carries-bir
}
case_M49() {
  subst src/drivers/bus/fk_pcie.f90 \
    $'    if (btest(lo, FK_PCI_BAR_SPACE_BIT)) return\n    a = iand(iand(int(lo, c_int64_t), MASK32), &\n             not(shiftl(1_c_int64_t, FK_PCI_BAR_MEM_ADDR_POS) - 1_c_int64_t))' \
    $'    if (btest(lo, FK_PCI_BAR_SPACE_BIT)) return\n    a = iand(int(lo, c_int64_t), MASK32)'
  run_case M49-bar0-low-flag-bits-kept
}
case_M50() {
  subst src/boot/fk_kmain.f90 \
    "    down = pcie_cmd_disable(i)" \
    "    down = pcie_command(i)"
  run_case M50-command-never-taken-down
}
case_M51() {
  subst src/drivers/bus/fk_pcie.f90 \
    $'    st = pcie_cfg_write32(bus, dev, fn, OFF_CMDSTAT, &' \
    $'    st = 0_c_int32_t\n    if (.false.) st = pcie_cfg_write32(bus, dev, fn, OFF_CMDSTAT, &'
  run_case M51-command-enable-never-written
}

# --- roadmap 5.1: the xHCI ---------------------------------------------------
case_M52() {
  subst src/boot/fk_kmain.f90 \
    "    st = xhci_reset()" \
    "    st = FK_XHCI_OK"
  run_case M52-controller-never-reset
}
case_M53() {
  subst src/drivers/usb/fk_xhci.f90 \
    "    call fk_writel(ir0(FK_XHCI_IR_ERSTSZ_OFF), 1_c_int32_t)" \
    "    call fk_writel(ir0(FK_XHCI_IR_ERSTSZ_OFF), trbs)"
  run_case M53-erstsz-given-trb-count
}
case_M54() {
  subst src/drivers/usb/fk_xhci.f90 \
    $'    ctrl = ior(shiftl(int(FK_XHCI_TRB_TYPE_LINK, c_int32_t), &\n                      FK_XHCI_TRB_CTRL_TYPE_POS), &\n               ibset(0_c_int32_t, FK_XHCI_TRB_CTRL_TC_BIT))' \
    $'    ctrl = shiftl(int(FK_XHCI_TRB_TYPE_LINK, c_int32_t), &\n                  FK_XHCI_TRB_CTRL_TYPE_POS)'
  run_case M54-link-trb-no-toggle-cycle
}
case_M55() {
  subst src/drivers/usb/fk_xhci.f90 \
    "    if (cmd_cyc == 1_c_int32_t) ctrl = ibset(ctrl, FK_XHCI_TRB_CTRL_CYCLE_BIT)" \
    "    continue"
  run_case M55-noop-trb-cycle-bit-clear
}
case_M56() {
  subst src/drivers/usb/fk_xhci.f90 \
    $'    evt_deq = evt_deq + 1_c_int32_t\n    if (evt_deq >= evt_trbs) then' \
    $'    if (evt_deq >= evt_trbs) then'
  run_case M56-erdp-never-advanced
}
case_M57() {
  subst src/drivers/usb/fk_xhci.f90 \
    "    v = ibset(v, FK_XHCI_IMAN_IE_BIT)" \
    "    v = ibclr(v, FK_XHCI_IMAN_IE_BIT)"
  run_case M57-interrupter-not-enabled
}
case_M58() {
  subst src/drivers/usb/fk_xhci.f90 \
    $'    call cmd_set(FK_XHCI_USBCMD_INTE_BIT, .true.)\n    status = FK_XHCI_OK' \
    $'    status = FK_XHCI_OK'
  run_case M58-usbcmd-inte-never-set
}
case_M59() {
  subst src/boot/fk_kmain.f90 \
    "    if (st == FK_XHCI_OK) st = xhci_set_dcbaap(dcbaa)" \
    "    if (st == FK_XHCI_OK) st = FK_XHCI_OK"
  run_case M59-dcbaap-never-written
}
case_M60() {
  subst src/drivers/bus/fk_pcie.f90 \
    $'    call fk_writel(e + FK_PCI_MSIX_E_VCTRL, &\n                   ibset(0_c_int32_t, FK_PCI_MSIX_VCTRL_MASK_BIT))' \
    ''
  run_case M60-msix-entry-not-masked-while-written
}
case_M61() {
  subst src/boot/fk_kmain.f90 \
    "    cmd  = pcie_intx_disable(idx)" \
    "    cmd  = pcie_command(idx)"
  run_case M61-intx-never-disabled
}
case_M62() {
  subst src/boot/fk_kmain.f90 \
    $'    trb = xhci_cmd_noop()\n    call xhci_doorbell(0_c_int32_t, 0_c_int32_t)' \
    $'    trb = xhci_cmd_noop()'
  run_case M62-doorbell-never-rung
}
case_M63() {
  subst src/drivers/usb/fk_xhci.f90 \
    $'    call fk_writel(a, plo)\n    call fk_writel(a + 4_c_int64_t, phi)\n    call fk_writel(a + 8_c_int64_t, sts)' \
    $'    call fk_writel(a + 12_c_int64_t, ctrl)\n    call fk_writel(a, plo)\n    call fk_writel(a + 4_c_int64_t, phi)\n    call fk_writel(a + 8_c_int64_t, sts)'
  run_case M63-cycle-bit-published-first
}
case_M64() {
  subst src/boot/fk_kmain.f90 \
    "    if (st == FK_XHCI_OK) st = xhci_run()" \
    "    if (st == FK_XHCI_OK) st = FK_XHCI_OK"
  run_case M64-run-stop-never-set
}

CASES="baseline M40 M41 M42 M43 M44 M45 M46 M47 M48 M49 M50 M51 \
       M52 M53 M54 M55 M56 M57 M58 M59 M60 M61 M62 M63 M64"

trap 'restore' EXIT INT TERM
for c in $CASES; do
  want_case "$c" || continue
  restore
  "case_${c}"
done
restore
