#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Drives the mutation table in docs/HARNESS-VALIDATION-PHASE3.md: injects one
# defect at a time into the roadmap 3.1/3.2/3.2.5/3.4/3.5 code, rebuilds from clean,
# boots it and restores the tree.  The baselines must PASS; a MUTATION that
# passes is an ESCAPE, because the gate accepted a kernel with a known defect.
#
# Edits the working tree in place and restores with `git checkout`, so run it on
# a clean tree.  Needs a VM, so it runs on the host, not in the container.
#
#   tools/mutate-phase3.sh            every case
#   tools/mutate-phase3.sh M7 M10     only those
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${FK_MUTATE_OUT:-$(mktemp -d /tmp/fk-mutate.XXXXXX)}"
mkdir -p "$OUT"
echo "logs: $OUT"

# Every file any mutation below touches.  A short restore list is how a defect
# survives into the NEXT case and gets attributed to it.
FILES="boot/interrupts.S boot/gdt_flush.S boot/faultgen.S boot/ksyms.S \
       boot/mmu.S \
       src/cpu/fk_gdt.f90 src/cpu/fk_idt.f90 src/cpu/fk_tss.f90 \
       src/drivers/pic/fk_pic.f90 src/mm/fk_pmm.f90 src/mm/fk_vmm.f90 \
       src/boot/fk_kmain.f90"

restore() { git checkout -- $FILES 2>/dev/null; }

# restore() rewinds to the INDEX, so a file that is untracked is not rewound at
# all and a file with unstaged edits loses them.  Either one turns this script
# from a measurement into a corruption: the first mutation would survive into
# every later case and be reported against the wrong defect.  Refuse instead.
for f in $FILES; do
  git ls-files --error-unmatch "$f" >/dev/null 2>&1 || {
    echo "ABORT: $f is not tracked -- 'git checkout --' cannot restore it."
    echo "       git add it first."; exit 1; }
done
# UNSTAGED edits are the fatal case, not uncommitted ones: restore() rewinds to
# the index, so anything staged survives every case unharmed.
if ! git diff --quiet -- $FILES && [ -z "${FK_MUTATE_FORCE:-}" ]; then
  echo "ABORT: unstaged changes in the files this script mutates:"
  git status --short -- $FILES | sed 's/^/       /'
  echo "       git add or stash them; the first restore would discard them."
  echo "       FK_MUTATE_FORCE=1 to override."; exit 1
fi

# The #DE build reaches the ISR_NOERR half of boot/interrupts.S; the #DF build
# reaches ISR_ERR and the IST1 stack switch.  Neither is a superset.
#
# roadmap 3.4's six verdicts ride on EVERY case, not just the PMM ones. A
# mutation is only attributable if everything it did not touch still holds, and
# these lines are printed before the deliberate fault on every build.
PMM_EXPECT=$'Fortran Kernel: PMM reserved and ACPI frames are all marked used.\nFortran Kernel: PMM locked the kernel image and the loader map out.\nFortran Kernel: PMM allocated 5 contiguous frames.\nFortran Kernel: PMM freed and reclaimed the same 5 frames.\nFortran Kernel: PMM refused a double, unaligned and locked free.\nFortran Kernel: PMM rewound its scan cursor to a freed frame.'
PMM_REJECT=$'Fortran Kernel: PMM init FAILED, status 0x\nFortran Kernel: PMM reserved or ACPI frames are STILL FREE.\nFortran Kernel: PMM did NOT lock the kernel image out.\nFortran Kernel: PMM allocation is NOT contiguous.\nFortran Kernel: PMM reclaim FAILED.\nFortran Kernel: PMM guard FAILED.\nFortran Kernel: PMM cursor rewind FAILED.'

# roadmap 3.5's verdicts ride on every case for the same reason 3.4's do. The
# last line of each is not a verdict at all: " R-X" and "RWX" are the W^X
# property read off the permission column of the LIVE page tables, and they
# carry no address, so they survive any relayout.
VMM_EXPECT=$'Fortran Kernel: VMM has EFER.NXE and CR0.WP, so the permissions bite.\nFortran Kernel: VMM mapped every kernel page with the asked-for permission.\nFortran Kernel: VMM left the stack guard page unmapped.\nFortran Kernel: identity window still live, [0x100000] = 0x00000000E85250D6\nFortran Kernel: PML4[0] unmapped; the identity window is dead.\nFortran Kernel: VMM mapped a frame above 4 GiB and read back what it wrote.\n R-X'
VMM_REJECT=$'Fortran Kernel: VMM init FAILED, status 0x\nFortran Kernel: VMM could not enable NX; .rodata is not no-execute.\nFortran Kernel: VMM section permissions are WRONG, pages 0x\nFortran Kernel: VMM guard page is MAPPED.\nFortran Kernel: PML4[0] is STILL MAPPED.\nFortran Kernel: VMM high-frame mapping FAILED.\nRWX'

DE_EXPECT="EXCEPTION 0x00 ERR 0x0000000000000000 -- #DE Divide-by-Zero Error"$'\n'"$PMM_EXPECT"$'\n'"$VMM_EXPECT"
DF_EXPECT=$'EXCEPTION 0x08 ERR 0x0000000000000000 -- #DF Double Fault\n*** #DF ENTERED ON IST1 -- THE EMERGENCY STACK HELD ***\n'"$PMM_EXPECT"$'\n'"$VMM_EXPECT"
# The OOM build's proof is three facts: the allocator refused, it said so, and
# the panic that followed came from the CPU with a full register dump.
OOM_EXPECT=$'*** PMM OUT OF MEMORY ***\nEXCEPTION 0x03 ERR 0x0000000000000000 -- #BP Breakpoint\n*** HALTED -- CLI/HLT ***\n'"$PMM_EXPECT"$'\n'"$VMM_EXPECT"
COMMON_REJECT=$'Fortran Kernel: the deliberate fault did NOT trap.\nFortran Kernel: 8259 PIC mask readback FAILED.\n'"$PMM_REJECT"$'\n'"$VMM_REJECT"

# roadmap 3.5's two page-fault builds. The CR2 line is the whole assertion: both
# faults are vector 14 with error code 0, so without it the two cases are
# indistinguishable and either would satisfy the other's expectation.
PF_EXPECT=$'EXCEPTION 0x0E ERR 0x0000000000000000 -- #PF Page Fault\n*** HALTED -- CLI/HLT ***\n'"$PMM_EXPECT"$'\n'"$VMM_EXPECT"
DF_REJECT="*** #DF ENTERED ON THE FAULTING STACK -- NO IST SWITCH ***"$'\n'"$COMMON_REJECT"

EXPECT="$DF_EXPECT"; REJECT="$DF_REJECT"

# subst <file> <old> <new> -- and ABORT the run if the text was not there.
# A sed that quietly matches nothing rebuilds the pristine kernel, the gate
# passes, and the table records an escape that never happened.
subst() {
  python3 - "$@" <<'PY' || exit 1
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if old not in s:
    sys.exit("  MUTATION DID NOT APPLY: %r not found in %s" % (old[:70], path))
open(path, 'w').write(s.replace(old, new, 1))
PY
}

# Rebuild kernel_main's deliberate fault as a #DE instead of a #DF.
mode_de() {
  subst src/boot/fk_kmain.f90 \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = 8_c_int32_t" \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = 0_c_int32_t"
  EXPECT="$DE_EXPECT"; REJECT="$COMMON_REJECT"
}

# ...or as roadmap 3.4's out-of-memory panic: drain the PMM, then INT3.
mode_oom() {
  subst src/boot/fk_kmain.f90 \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = 8_c_int32_t" \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = -1_c_int32_t"
  EXPECT="$OOM_EXPECT"; REJECT="$COMMON_REJECT"
}

# The guard page, whose address is READ OUT OF THE IMAGE that was just built
# rather than written down here -- the whole point is that the fault lands on
# the page linker.ld reserved, and a constant would still match after a
# relayout moved it. bash arithmetic is signed 64-bit, so 0xFFFFFFFF... wraps
# negative; printf %X prints the bit pattern, which is what is wanted.
mode_guard() {
  subst src/boot/fk_kmain.f90 \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = 8_c_int32_t" \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = -2_c_int32_t"
  EXPECT="$PF_EXPECT"; REJECT="$COMMON_REJECT"; POST_BUILD=guard_cr2
}
guard_cr2() {
  local b cr2
  b=$(nm build/boot/kernel.elf | awk '$3=="__boot_stack_bottom"{print $1}')
  [ -n "$b" ] || { echo "  (cannot read __boot_stack_bottom)"; return; }
  cr2=$(printf '%016X' $(( 0x$b - 8 )))
  echo "  guard probe: __boot_stack_bottom 0x$b, expecting CR2 0x$cr2"
  EXPECT="$EXPECT"$'\n'"CR2     = 0x$cr2"
}

# ...and physical 1 MiB, which needs no lookup: it is where linker.ld puts this
# image, and it resolved a few lines of console output earlier.
mode_idmap() {
  subst src/boot/fk_kmain.f90 \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = 8_c_int32_t" \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = -3_c_int32_t"
  EXPECT="$PF_EXPECT"$'\n'"CR2     = 0x0000000000100000"
  REJECT="$COMMON_REJECT"
}

# Both gates, because they see different things: the static one reads the
# linked image (a TSS that grew from 104 bytes to 112 is visible there and
# nowhere else), the boot one reads a running CPU.  Which one caught a defect
# is part of the result, not an implementation detail.
run_case() {
  local name=$1 static=clean
  ./tools/run.sh clean-boot >/dev/null 2>&1
  ./tools/run.sh linkscript >"$OUT/$name.static" 2>&1 || static=CAUGHT
  if ! ./tools/run.sh iso >"$OUT/$name.build" 2>&1; then
    echo "$name: static=$static, BUILD FAILED (caught at build time)"
    return
  fi
  # A case whose expectation depends on an address only the fresh image knows.
  [ -n "${POST_BUILD:-}" ] && "$POST_BUILD"
  FK_EXPECT_SERIAL="$EXPECT" FK_REJECT_SERIAL="$REJECT" FK_CHECK_HW=1 \
    tools/qemu-boot-test.sh >"$OUT/$name.log" 2>&1
  local rc=$? line
  # The CAUSE, not the gate's echo of what it was looking for: the header lines
  # quote every expected string, so a grep for those matches on every run.
  line=$(sed 's/\x1b\[[0-9;]*m//g' "$OUT/$name.log" \
         | grep -aE "^(QEMU EXITED|THE HARDWARE|COM1 CARRIED|Sentinel assertion)|^  FAIL  |^      (MISSING|PRESENT)  :" \
         | head -3 | tr -d '\r' | sed 's/^ *//' | paste -sd'|')
  if [ $rc -eq 0 ]; then echo "$name: static=$static, boot gate PASSED :: $line"
  else                   echo "$name: static=$static, boot gate FAILED :: $line"; fi
}

SELECT="$*"
want_case() { [ -z "$SELECT" ] && return 0; case " $SELECT " in *" $1 "*) return 0;; esac; return 1; }

case_baseline_df()  { run_case baseline-df; }
case_baseline_de()  { mode_de;  run_case baseline-de; }
case_baseline_oom()   { mode_oom;   run_case baseline-oom; }
case_baseline_guard() { mode_guard; run_case baseline-guard-page; }
case_baseline_idmap() { mode_idmap; run_case baseline-identity-dead; }

# --- the #DE build: roadmap 3.2's frame normalisation ------------------------
case_M1() {
  mode_de
  subst boot/interrupts.S $'isr\\vec:\n\tpushq\t$0\n\tpushq\t$\\vec' $'isr\\vec:\n\tpushq\t$\\vec'
  run_case M1-no-dummy-errcode
}
case_M2() {
  mode_de
  subst src/cpu/fk_idt.f90 "FK_IDT_ATTR_INTR = int(z'8E', c_int8_t)" \
                           "FK_IDT_ATTR_INTR = int(z'0E', c_int8_t)"
  run_case M2-gate-not-present
}
case_M3() {
  mode_de
  subst boot/interrupts.S $'\tpushq\t%rbx\n\tpushq\t%rbp' $'\tpushq\t%rbp\n\tpushq\t%rbx'
  run_case M3-swapped-gprs
}
case_M4() {
  mode_de
  subst boot/interrupts.S \
    $'\tmovslq\t%edi, %rdi\t\t/* the ABI leaves bits 63:32 undefined */' \
    $'\tmovslq\t%edi, %rdi\n\taddq\t$1, %rdi'
  run_case M4-stub-off-by-one
}
case_M5() {
  mode_de
  subst boot/interrupts.S \
    $'\t/* An interrupt gate does not clear DF, and SysV requires DF=0 on entry. */\n\tcld\n' ''
  run_case M5-no-cld
}

# --- the #DF build: roadmap 3.2.5's TSS, IST and PIC -------------------------
case_M6() {
  subst src/cpu/fk_gdt.f90 $'    gdt(FK_GDT_TSS_SLOT)     = lo\n    gdt(FK_GDT_TSS_SLOT + 1) = hi' \
                           $'    gdt(FK_GDT_TSS_SLOT)     = lo'
  run_case M6-tss-descriptor-8-bytes
}
case_M7() {
  subst src/cpu/fk_idt.f90 "idt(vec)%ist   = int(FK_TSS_IST_DF, c_int8_t)" \
                           "idt(vec)%ist   = FK_IDT_IST_NONE"
  run_case M7-df-gate-no-ist
}
case_M8() {
  subst src/cpu/fk_tss.f90 $'    tss%ist1_lo = u32(df_hi)\n    tss%ist1_hi = u32(ishft(df_hi, -32))' \
                           $'    tss%ist1_lo = u32(df_lo)\n    tss%ist1_hi = u32(ishft(df_lo, -32))'
  run_case M8-ist1-at-stack-bottom
}
case_M9() {
  subst src/cpu/fk_tss.f90 "    call tss_flush(FK_GDT_SEL_TSS)" \
                           "    if (df_lo == 1_c_int64_t) call tss_flush(FK_GDT_SEL_TSS)"
  run_case M9-no-ltr
}
case_M10() {
  subst src/drivers/pic/fk_pic.f90 "FK_PIC1_VECTOR = int(z'20', c_int32_t)" \
                                   "FK_PIC1_VECTOR = int(z'08', c_int32_t)"
  run_case M10-master-not-remapped
}
case_M11() {
  subst src/drivers/pic/fk_pic.f90 \
    $'    call pic_out(PIC1_DATA, FK_MASK_ALL)\n    call pic_out(PIC2_DATA, FK_MASK_ALL)' ''
  run_case M11-irqs-never-masked
}
case_M12() {
  subst src/cpu/fk_tss.f90 "    tss%iomap_base = int(c_sizeof(tss), c_int16_t)" \
                           "    tss%iomap_base = 0_c_int16_t"
  run_case M12-iomap-base-zero
}
case_M13() {
  # The exact trap the 32-bit-halves layout exists to avoid: one c_int64_t at
  # the head of the type and C alignment moves IST1 from 0x24 to 0x28.
  subst src/cpu/fk_tss.f90 "    integer(c_int32_t) :: reserved0" \
                           "    integer(c_int64_t) :: reserved0"
  run_case M13-tss-c-padding
}

# --- roadmap 3.4: the PMM ----------------------------------------------------
# Every one of these is ALREADY caught by the host suite (H1..HG in
# docs/HARNESS-VALIDATION-PHASE3.md). They are re-run on a real machine because
# the host suite feeds the parser a memory map this file wrote, and the boot
# gate feeds it one GRUB wrote -- and the two disagree about where things are.
case_M14() {
  subst src/boot/fk_kmain.f90 "    status = pmm_init(mbi)" \
                              "    status = pmm_init(0_c_int64_t)"
  run_case M14-mbi-pointer-lost
}
case_M15() {
  subst src/mm/fk_pmm.f90 $'    if (span_outward(kern_lo, kern_hi - kern_lo, first, last)) &\n         free_count = free_count - bits_set(first, last)\n\n    ! The loader\'s own structure.' \
                          $'    ! The loader\'s own structure.'
  run_case M15-kernel-image-allocatable
}
case_M16() {
  # The anchor MUST reach as far as `cursor`: pmm_init's cleanup path carries a
  # byte-identical fill loop and the same first five resets, appears earlier in
  # the file, and would be the one substituted -- which mutates a path this gate
  # never exercises and reports a spurious escape.  It did, once.
  subst src/mm/fk_pmm.f90 $'    do w = 1_c_int32_t, FK_PMM_WORDS\n       bitmap(w) = FK_PMM_WORD_FULL\n    end do\n    ready      = .false.\n    reg_count  = 0_c_int32_t\n    ram_pages  = 0_c_int64_t\n    free_count = 0_c_int64_t\n    ignored    = 0_c_int64_t\n    cursor     = 1_c_int32_t' \
                          $'    ready      = .false.\n    reg_count  = 0_c_int32_t\n    ram_pages  = 0_c_int64_t\n    free_count = 0_c_int64_t\n    ignored    = 0_c_int64_t\n    cursor     = 1_c_int32_t'
  run_case M16-bitmap-never-filled
}
case_M17() {
  subst src/mm/fk_pmm.f90 $'       b = trailz(not(bitmap(w)))\n       bitmap(w) = ibset(bitmap(w), b)' \
                          $'       b = trailz(not(bitmap(w)))'
  run_case M17-alloc-never-marks
}
case_M18() {
  subst src/mm/fk_pmm.f90 "    if (w < cursor) cursor = w" "    continue"
  run_case M18-free-never-rewinds
}
case_M19() {
  subst src/mm/fk_pmm.f90 $'    if (in_span(phys, kern_lo, kern_hi) .or. in_span(phys, mbi_lo, mbi_hi)) then\n       status = FK_PMM_E_LOCKED\n       return\n    end if' \
                          "    continue"
  run_case M19-free-ignores-locked
}
# The one that only a linked image can catch: boot/ksyms.S hands Fortran the
# value of an absolute linker symbol, and a wrong constant marks the wrong
# frames used while every console verdict still prints PASS.
case_M20() {
  # roadmap 3.5 turned seventeen near-identical accessors into one KSYM macro,
  # so the defect is now injected into the macro BODY and every accessor in the
  # image returns zero at once. printf builds both strings: the anchor contains
  # tabs, a '$' immediate and a '\sym' macro parameter, and no bash quoting
  # style leaves all three alone.
  subst boot/ksyms.S "$(printf '\tmovabsq\t$\\sym, %%rax')" \
                     "$(printf '\tmovabsq\t$0x0, %%rax')"
  run_case M20-ksyms-wrong-constant
}

# --- roadmap 3.5: the VMM and the higher-half handoff ------------------------
# M21 is the one that says why the boot gate rejects the string "RWX". The
# kernel's own vmm_verify_image compares the LIVE tables against the table of
# intentions it built -- so mutating the INTENTION passes that check with
# nothing to report. What it cannot do is stop the permission column from
# saying so.
case_M21() {
  subst src/mm/fk_vmm.f90 "    sec_flags(2) = perm(.false., .true.)" \
                          "    sec_flags(2) = perm(.true., .true.)"
  run_case M21-text-mapped-writable
}
case_M22() {
  subst src/mm/fk_vmm.f90 $'       if (v /= guard_page) then\n          status = vmm_map_page(v, v - kernel_vma, flags)\n          if (status /= FK_VMM_OK) return\n       end if' \
                          $'       status = vmm_map_page(v, v - kernel_vma, flags)\n       if (status /= FK_VMM_OK) return'
  run_case M22-guard-page-mapped
}
case_M23() {
  subst src/mm/fk_vmm.f90 $'    t(1) = 0_c_int64_t\n    call fk_write_cr3(pml4_phys)' \
                          $'    call fk_write_cr3(pml4_phys)'
  run_case M23-pml4-0-never-zeroed
}
# THE ONE THE DEFAULT BUILD CANNOT SEE, and the reason FK_FAULT_MODE grew a
# third value. Zeroing PML4[0] without reloading CR3 leaves the translation in
# the TLB: vmm_translate walks the tables in software and correctly reports the
# window gone, every console verdict prints PASS -- and the CPU goes on
# resolving physical addresses through a cached entry. Only a real load from
# 0x100000 disagrees, which is what the idmap build performs.
case_M24() {
  subst src/mm/fk_vmm.f90 $'    t(1) = 0_c_int64_t\n    call fk_write_cr3(pml4_phys)' \
                          $'    t(1) = 0_c_int64_t'
  mode_idmap
  run_case M24-unmap-without-tlb-flush
}
# EFER.NXE left clear while the tables still carry bit 63. That bit is then
# RESERVED rather than no-execute, so the first read of a .rodata string faults,
# the fault handler reads .rodata to say so, and the machine triple-faults.
case_M25() {
  subst boot/mmu.S "$(printf '\torl\t$EFER_NXE, %%eax\n\twrmsr')" \
                   "$(printf '\torl\t$EFER_NXE, %%eax')"
  run_case M25-nx-bits-without-nxe
}
# The guard accessor pointed at a different linker symbol. The static gate
# catches it on the naming convention alone; the boot gate catches it because
# the VMM then leaves a live .bss page unmapped and maps the guard.
case_M26() {
  subst boot/ksyms.S "$(printf '\tKSYM\tfk_boot_stack_guard,   __boot_stack_guard')" \
                     "$(printf '\tKSYM\tfk_boot_stack_guard,   __bss_start')"
  run_case M26-guard-accessor-wrong-symbol
}

ALL="baseline_df baseline_de baseline_oom baseline_guard baseline_idmap \
     M1 M2 M3 M4 M5 M6 M7 M8 M9 M10 M11 \
     M12 M13 M14 M15 M16 M17 M18 M19 M20 M21 M22 M23 M24 M25 M26"
for c in $ALL; do
  want_case "$c" || continue
  echo "=== $c ==="
  EXPECT="$DF_EXPECT"; REJECT="$DF_REJECT"; POST_BUILD=""
  restore
  "case_$c"
  restore
done

echo "=== restoring and rebuilding the real tree ==="
restore
./tools/run.sh clean-boot >/dev/null 2>&1
./tools/run.sh iso >/dev/null 2>&1 && echo "tree restored and ISO rebuilt"
git status --short
