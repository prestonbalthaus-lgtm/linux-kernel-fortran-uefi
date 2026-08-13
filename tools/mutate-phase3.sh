#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Drives the mutation table in docs/HARNESS-VALIDATION-PHASE3.md: injects one
# defect at a time into the roadmap 3.1/3.2/3.2.5 code, rebuilds from clean,
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
FILES="boot/interrupts.S boot/gdt_flush.S boot/faultgen.S \
       src/cpu/fk_gdt.f90 src/cpu/fk_idt.f90 src/cpu/fk_tss.f90 \
       src/drivers/pic/fk_pic.f90 src/boot/fk_kmain.f90"

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
DE_EXPECT="EXCEPTION 0x00 ERR 0x0000000000000000 -- #DE Divide-by-Zero Error"
DF_EXPECT=$'EXCEPTION 0x08 ERR 0x0000000000000000 -- #DF Double Fault\n*** #DF ENTERED ON IST1 -- THE EMERGENCY STACK HELD ***'
COMMON_REJECT=$'Fortran Kernel: the deliberate fault did NOT trap.\nFortran Kernel: 8259 PIC mask readback FAILED.'
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

case_baseline_df() { run_case baseline-df; }
case_baseline_de() { mode_de; run_case baseline-de; }

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

ALL="baseline_df baseline_de M1 M2 M3 M4 M5 M6 M7 M8 M9 M10 M11 M12 M13"
for c in $ALL; do
  want_case "$c" || continue
  echo "=== $c ==="
  EXPECT="$DF_EXPECT"; REJECT="$DF_REJECT"
  restore
  "case_$c"
  restore
done

echo "=== restoring and rebuilding the real tree ==="
restore
./tools/run.sh clean-boot >/dev/null 2>&1
./tools/run.sh iso >/dev/null 2>&1 && echo "tree restored and ISO rebuilt"
git status --short
