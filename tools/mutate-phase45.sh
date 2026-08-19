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
       src/drivers/usb/fk_usb_kbd.f90 src/drivers/usb/fk_usb_hid.f90 \
       src/drivers/usb/fk_usb_types.f90 src/cpu/fk_idt.f90 \
       src/drivers/storage/fk_nvme.f90 src/drivers/storage/fk_nvme_types.f90 \
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


# --- roadmap 5.2: the USB HID keyboard ---------------------------------------
case_M65() {
  subst src/drivers/usb/fk_usb_kbd.f90 \
    $'    status = xhci_port_reset(port)\n' \
    $'    status = FK_XHCI_OK\n'
  run_case M65-port-never-reset
}
case_M66() {
  subst src/drivers/usb/fk_xhci.f90 \
    $'    call fk_writel(port_addr(port), &\n                   ior(iand(fk_readl(port_addr(port)), &\n                            FK_XHCI_PORTSC_PRESERVE), bits))' \
    $'    call fk_writel(port_addr(port), &\n                   ior(fk_readl(port_addr(port)), bits))'
  run_case M66-portsc-read-modify-write
}
case_M67() {
  subst src/drivers/usb/fk_usb_kbd.f90 \
    $'    call xhci_dcbaa_set(dcbaa_virt, slot_id, dctx_phys)\n' ''
  run_case M67-dcbaa-slot-never-written
}
case_M68() {
  subst src/drivers/usb/fk_usb_kbd.f90 \
    $'    call xhci_slot_ctx_init(ictx_virt, speed, port, DCI_EP1_IN)' \
    $'    call xhci_slot_ctx_init(ictx_virt, speed, port, DCI_EP0)'
  run_case M68-context-entries-left-at-one
}
case_M69() {
  subst src/drivers/usb/fk_usb_kbd.f90 \
    $'    call xhci_ictx_flags(ictx_virt, ior(1_c_int32_t, shiftl(1_c_int32_t, &\n                                                            DCI_EP1_IN)), &\n                         0_c_int32_t)' \
    $'    call xhci_ictx_flags(ictx_virt, 1_c_int32_t, 0_c_int32_t)'
  run_case M69-add-flag-A3-not-set
}
case_M70() {
  subst src/drivers/usb/fk_usb_kbd.f90 \
    $'    call xhci_doorbell(slot_id, DCI_EP1_IN)' \
    $'    call xhci_doorbell(slot_id, DCI_EP0)'
  run_case M70-doorbell-at-dci-1-not-3
}
case_M71() {
  subst src/drivers/usb/fk_xhci.f90 \
    $'    v = fk_readl(ir0(FK_XHCI_IR_IMAN_OFF))\n    v = ibset(v, FK_XHCI_IMAN_IP_BIT)\n    call fk_writel(ir0(FK_XHCI_IR_IMAN_OFF), v)\n\n    do i = 1_c_int32_t, FK_XHCI_TR_MAX * 64_c_int32_t' \
    $'    do i = 1_c_int32_t, FK_XHCI_TR_MAX * 64_c_int32_t'
  run_case M71-iman-ip-never-cleared
}
case_M72() {
  subst src/drivers/usb/fk_usb_kbd.f90 \
    $'    status = ctrl(ior(FK_USB_TYPE_CLASS, FK_USB_RECIP_INTERFACE), &\n                  FK_HID_REQ_SET_PROTOCOL, FK_HID_BOOT_PROTOCOL, iface, &\n                  0_c_int64_t, 0_c_int32_t, 0_c_int32_t)\n    if (status /= FK_XHCI_OK) return\n' ''
  run_case M72-set-protocol-removed
}
case_M73() {
  subst src/drivers/usb/fk_usb_kbd.f90 \
    $'    mods = rpt_byte(w, FK_USB_HID_MOD_OFF)' \
    $'    mods = 0_c_int32_t'
  run_case M73-modifier-byte-ignored
}
case_M74() {
  subst src/drivers/usb/fk_usb_kbd.f90 \
    $'       if (held(prev_rpt, usage)) cycle\n' ''
  run_case M74-previous-report-not-subtracted
}
case_M75() {
  subst src/drivers/usb/fk_usb_kbd.f90 \
    $'    if (.not. armed) return\n\n    n = xhci_drain()' \
    $'    n = xhci_drain()\n    if (.not. armed) return'
  run_case M75-isr-drains-before-it-owns-the-ring
}


# --- roadmap 5.3: the NVMe controller ----------------------------------------
case_M76() {
  subst src/drivers/storage/fk_nvme.f90 \
    $'    v = ibset(v, FK_NVME_CC_EN_BIT)\n' ''
  run_case M76-cc-en-never-set
}
case_M77() {
  subst src/drivers/storage/fk_nvme.f90 \
    $'    call mvbits(FK_NVME_CC_IOSQES_NVM, 0_c_int32_t, FK_NVME_CC_IOSQES_LEN, v, &\n                FK_NVME_CC_IOSQES_POS)\n    call mvbits(FK_NVME_CC_IOCQES_NVM, 0_c_int32_t, FK_NVME_CC_IOCQES_LEN, v, &\n                FK_NVME_CC_IOCQES_POS)\n' ''
  run_case M77-iosqes-iocqes-left-zero
}
case_M78() {
  subst src/drivers/storage/fk_nvme.f90 \
    $'    call mvbits(FK_NVME_ADMIN_ENTRIES - 1_c_int32_t, 0_c_int32_t, &\n                FK_NVME_AQA_ASQS_LEN, v, FK_NVME_AQA_ASQS_POS)\n    call mvbits(FK_NVME_ADMIN_ENTRIES - 1_c_int32_t, 0_c_int32_t, &\n                FK_NVME_AQA_ACQS_LEN, v, FK_NVME_AQA_ACQS_POS)' \
    $'    call mvbits(FK_NVME_ADMIN_ENTRIES, 0_c_int32_t, &\n                FK_NVME_AQA_ASQS_LEN, v, FK_NVME_AQA_ASQS_POS)\n    call mvbits(FK_NVME_ADMIN_ENTRIES, 0_c_int32_t, &\n                FK_NVME_AQA_ACQS_LEN, v, FK_NVME_AQA_ACQS_POS)'
  run_case M78-aqa-not-zero-based
}
case_M79() {
  subst src/drivers/storage/fk_nvme.f90 \
    $'    call wr64(FK_NVME_REG_ASQ_OFF, sq_p)\n    call wr64(FK_NVME_REG_ACQ_OFF, cq_p)' \
    $'    call wr64(FK_NVME_REG_ASQ_OFF, cq_p)\n    call wr64(FK_NVME_REG_ACQ_OFF, sq_p)'
  run_case M79-asq-and-acq-swapped
}
case_M80() {
  subst src/drivers/storage/fk_nvme.f90 \
    $'       cq_phase(q) = 1_c_int32_t - cq_phase(q)\n' ''
  run_case M80-phase-never-flipped-on-wrap
}
case_M81() {
  subst src/drivers/storage/fk_nvme.f90 \
    $'    call fk_writel(db_addr(qid_of(q), FK_NVME_DB_CQ), cq_head(q))\n' ''
  run_case M81-cq-head-doorbell-never-rung
}
case_M82() {
  subst src/drivers/storage/fk_nvme.f90 \
    $'    call mvbits(blocks - 1_c_int32_t, 0_c_int32_t, FK_NVME_RW_NLB_LEN, cdw12, &' \
    $'    call mvbits(blocks, 0_c_int32_t, FK_NVME_RW_NLB_LEN, cdw12, &'
  run_case M82-nlb-not-zero-based
}
case_M83() {
  subst src/boot/fk_kmain.f90 \
    $'    if (st == FK_NVME_OK) st = nvme_read(1_c_int32_t, 0_c_int64_t, &' \
    $'    if (st == FK_NVME_OK) st = nvme_read(1_c_int32_t, 1_c_int64_t, &'
  run_case M83-reads-lba-1-not-lba-0
}
case_M84() {
  subst src/drivers/storage/fk_nvme.f90 \
    $'    call fk_writel(e + int(z\'18\', c_int64_t), &\n                   int(iand(prp1, int(z\'FFFFFFFF\', c_int64_t)), c_int32_t))' \
    $'    call fk_writel(e + int(z\'18\', c_int64_t), 0_c_int32_t)'
  run_case M84-prp1-low-half-zero
}
case_M85() {
  subst src/drivers/storage/fk_nvme.f90 \
    $'    if (isr_owns) then\n       status = FK_NVME_OK\n       return\n    end if\n' ''
  run_case M85-completion-polled-not-taken-by-interrupt
}

CASES="baseline M40 M41 M42 M43 M44 M45 M46 M47 M48 M49 M50 M51 \
       M52 M53 M54 M55 M56 M57 M58 M59 M60 M61 M62 M63 M64 \
       M65 M66 M67 M68 M69 M70 M71 M72 M73 M74 M75 \
       M76 M77 M78 M79 M80 M81 M82 M83 M84 M85"

trap 'restore' EXIT INT TERM
for c in $CASES; do
  want_case "$c" || continue
  restore
  "case_${c}"
done
restore
