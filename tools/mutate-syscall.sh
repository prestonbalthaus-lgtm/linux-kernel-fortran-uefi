#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Roadmap 6.3's mutation table.  Injects one defect at a time into the syscall
# MSR programming, the entry stub or the router, and re-runs whichever gate can
# see it.  The baseline must PASS; a MUTATION that passes is an ESCAPE.
#
# TWO KINDS OF CASE, and the split is not arbitrary -- it is what each gate can
# establish.  Most of the table is the HOST suite, seconds per case, because
# the values and the dispatch are ordinary code.  Three cases need a BOOT,
# because what they break is a claim about the CPU: whether the instruction
# arrives, and whether the instruction cleared a flag.  Those take minutes, and
# `tools/mutate-syscall.sh S130 S131 S132` runs only them.
#
# BOTH OF tools/mutate-hostlib.sh's CORRECTIONS ARE INHERITED AT BIRTH:
#
#   * A PER-CASE TIMEOUT.  S131 gives SYSCALL a data descriptor for CS, which
#     is a fault inside a fault inside a fault -- it arrives as a TRIPLE FAULT
#     and the guest never answers, not as a wrong assertion.
#
#   * RESTORE FROM HEAD, NOT FROM THE INDEX, so a concurrent `git add` cannot
#     make a later restore put the DEFECT back.
#
# AND ONE OF ROADMAP 6.2's, which cost that table two false escapes: run_case
# RESTORES THE TREE BEFORE IT RETURNS, so a second run_case in the same case
# function runs against a CLEAN tree and reports the baseline as an escape.
# Any case below that wants two gates re-applies its substitution first.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${FK_MUTATE_OUT:-$(mktemp -d /tmp/fk-mutate-syscall.XXXXXX)}"
mkdir -p "$OUT"
echo "logs: $OUT"

FILES="src/cpu/fk_syscall.f90 boot/interrupts.S"

restore() { git checkout HEAD -- $FILES 2>/dev/null; }

for f in $FILES; do
  git ls-files --error-unmatch "$f" >/dev/null 2>&1 || {
    echo "ABORT: $f is not tracked -- 'git checkout HEAD --' cannot restore it."
    exit 1; }
done
if ! git diff --quiet HEAD -- $FILES && [ -z "${FK_MUTATE_FORCE:-}" ]; then
  echo "ABORT: the files this script mutates differ from HEAD:"
  git status --short -- $FILES | sed 's/^/       /'
  echo "       FK_MUTATE_FORCE=1 to override."; exit 1
fi

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
  local name=$1 rc line
  timeout -k 10 300 ./tools/run.sh build/run-syscall >"$OUT/$name.log" 2>&1
  rc=$?
  if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
    echo "$name: suite TIMED OUT (caught)"; restore; return
  fi
  line=$(grep -aE "MISMATCH|checks,|Error [0-9]" "$OUT/$name.log" \
         | head -3 | tr -d '\r' | sed 's/^ *//' | paste -sd'|')
  if [ $rc -eq 0 ]; then
    case "$name" in
    baseline*) echo "$name: suite PASSED :: $line";;
    *)         echo "$name: suite PASSED  <-- ESCAPE :: $line";;
    esac
  else echo "$name: suite FAILED (caught) :: $line"; fi
  restore
}

# The boot runner. A case reaches this only when the host suite structurally
# cannot see the defect, because it costs a full build and a full boot.
boot_case() {
  local name=$1 rc line
  ./tools/run.sh clean-boot >/dev/null 2>&1
  if ! timeout -k 10 900 ./tools/run.sh iso >"$OUT/$name.build" 2>&1; then
    echo "$name: BUILD FAILED (caught at build time)"; restore; return
  fi
  timeout -k 10 420 tools/qemu-boot-test.sh >"$OUT/$name.log" 2>&1
  rc=$?
  if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
    echo "$name: boot gate TIMED OUT (caught -- the guest never answered)"
    restore; return
  fi
  line=$(sed 's/\x1b\[[0-9;]*m//g' "$OUT/$name.log" \
         | grep -aE "^(QEMU EXITED|Sentinel assertion)|^  FAIL  |^      (MISSING|PRESENT)  :" \
         | head -3 | tr -d '\r' | sed 's/^ *//' | paste -sd'|')
  if [ $rc -eq 0 ]; then
    case "$name" in
    baseline*) echo "$name: boot gate PASSED :: $line";;
    *)         echo "$name: boot gate PASSED  <-- ESCAPE :: $line";;
    esac
  else echo "$name: boot gate FAILED (caught) :: $line"; fi
  restore
}

case_baseline() { run_case baseline-syscall; }

# ---- the MSR values -------------------------------------------------------

# segment.h:173-189.  CS comes from STAR[47:32] and SS from that PLUS EIGHT, so
# naming the data selector gives the CPU a data descriptor for CS.
case_S110() {
  subst src/cpu/fk_syscall.f90 \
    $'    v = shiftl(iand(int(FK_GDT_SEL_CODE, c_int64_t), &' \
    $'    v = shiftl(iand(int(FK_GDT_SEL_DATA, c_int64_t), &'
  run_case S110-STAR-names-the-data-selector
}

# The mistake a reader of common.c would make: copying __USER32_CS into the
# sysret half while this GDT still has no Ring 3 descriptors for it to name.
case_S111() {
  subst src/cpu/fk_syscall.f90 \
    $'    v = shiftl(iand(int(FK_GDT_SEL_CODE, c_int64_t), &\n                    int(z\'FFFF\', c_int64_t)), 32)' \
    $'    v = ior(shiftl(iand(int(FK_GDT_SEL_CODE, c_int64_t), &\n                    int(z\'FFFF\', c_int64_t)), 32), shiftl(int(z\'23\', c_int64_t), 48))'
  run_case S111-a-plausible-sysret-half-nothing-can-name
}

case_S112() {
  subst src/cpu/fk_syscall.f90 \
    $'       int(z\'00257FD5\', c_int64_t)' \
    $'       int(z\'00257DD5\', c_int64_t)'
  run_case S112-FMASK-without-IF
}

case_S113() {
  subst src/cpu/fk_syscall.f90 \
    $'       int(z\'00257FD5\', c_int64_t)' \
    $'       int(z\'003FFFFF\', c_int64_t)'
  run_case S113-FMASK-is-a-blanket-mask
}

# ---- the read-back --------------------------------------------------------
# boot/mmu.S's PAT routine states the rule: a wrmsr that never executed is
# otherwise indistinguishable from one that did.  The host suite's model MSR
# file can DROP a write, which is what makes these observable at all.

case_S114() {
  subst src/cpu/fk_syscall.f90 \
    $'    status = FK_SYS_E_STAR\n    if (fk_rdmsr(FK_MSR_STAR) /= star) return\n' \
    $''
  run_case S114-STAR-is-never-read-back
}

case_S115() {
  subst src/cpu/fk_syscall.f90 \
    $'    status = FK_SYS_E_FMASK\n    if (fk_rdmsr(FK_MSR_FMASK) /= FK_SYSCALL_FMASK) return\n' \
    $''
  run_case S115-FMASK-is-never-read-back
}

case_S116() {
  subst src/cpu/fk_syscall.f90 \
    $'    status = FK_SYS_E_SCE\n    if (.not. btest(fk_rdmsr(FK_MSR_EFER), FK_EFER_SCE_BIT)) return\n' \
    $''
  run_case S116-EFER-SCE-is-never-read-back
}

# EFER LAST.  With SCE set before LSTAR holds an address, a SYSCALL arriving in
# the gap jumps to whatever the register was left at.
case_S117() {
  subst src/cpu/fk_syscall.f90 \
    $'    star = syscall_star_value()\n    call fk_wrmsr(FK_MSR_STAR, star)' \
    $'    star = syscall_star_value()\n    efer = fk_rdmsr(FK_MSR_EFER)\n    call fk_wrmsr(FK_MSR_EFER, ibset(efer, FK_EFER_SCE_BIT))\n    call fk_wrmsr(FK_MSR_STAR, star)'
  run_case S117-SCE-is-armed-before-LSTAR-holds-an-address
}

# LSTAR is loaded into RIP.  A low-half address is not where this kernel lives,
# and the fault it causes lands arbitrarily far from the cause.
case_S118() {
  subst src/cpu/fk_syscall.f90 \
    $'    if (entry >= 0_c_int64_t) return\n' \
    $''
  run_case S118-a-low-half-entry-point-is-accepted
}

case_S119() {
  subst src/cpu/fk_syscall.f90 \
    $'    if (iand(top, 15_c_int64_t) /= 0_c_int64_t) return\n' \
    $''
  subst src/cpu/fk_syscall.f90 \
    $'    v = iand(v, not(15_c_int64_t))' \
    $'    v = v - 4_c_int64_t'
  run_case S119-the-syscall-stack-is-not-16-byte-aligned
}

# ---- the router -----------------------------------------------------------

case_S120() {
  subst src/cpu/fk_syscall.f90 \
    $'    if (nr == FK_SYS_NR_READ) then\n       ret = sys_read(regs%rdi, regs%rsi, regs%rdx)\n    else if (nr == FK_SYS_NR_WRITE) then\n       ret = sys_write(regs%rdi, regs%rsi, regs%rdx)' \
    $'    if (nr == FK_SYS_NR_READ) then\n       ret = sys_write(regs%rdi, regs%rsi, regs%rdx)\n    else if (nr == FK_SYS_NR_WRITE) then\n       ret = sys_read(regs%rdi, regs%rsi, regs%rdx)'
  run_case S120-read-and-write-are-dispatched-to-each-other
}

# THE RESULT MUST GO BACK IN THE FRAME.  POP_GPRS is what puts it in RAX; a
# handler that only returned it delivers nothing to the caller.
case_S121() {
  subst src/cpu/fk_syscall.f90 \
    $'    last_ret = ret\n    regs%rax = ret' \
    $'    last_ret = ret'
  run_case S121-the-result-is-never-written-into-the-frames-rax
}

case_S122() {
  subst src/cpu/fk_syscall.f90 \
    $'       ret = FK_E_NOSYS\n    end if' \
    $'       ret = 0_c_int64_t\n    end if'
  run_case S122-an-unknown-number-answers-success
}

case_S123() {
  subst src/cpu/fk_syscall.f90 \
    $'    written = written + count\n    ret = count' \
    $'    ret = count'
  run_case S123-a-successful-write-is-not-counted
}

case_S124() {
  subst src/cpu/fk_syscall.f90 \
    $'    ret = FK_E_BADF\n    if (fd < 0_c_int64_t) return\n    ret = FK_E_FAULT\n    if (buf == 0_c_int64_t) return\n    if (count < 0_c_int64_t) then' \
    $'    written = written + count\n    ret = FK_E_BADF\n    if (fd < 0_c_int64_t) return\n    ret = FK_E_FAULT\n    if (buf == 0_c_int64_t) return\n    if (count < 0_c_int64_t) then'
  run_case S124-a-refused-write-still-moves-the-byte-total
}

case_S125() {
  subst src/cpu/fk_syscall.f90 \
    $'    exit_called = exit_called + 1_c_int32_t\n    exit_code = code' \
    $'    exit_called = exit_called + 1_c_int32_t'
  run_case S125-exit-does-not-record-its-code
}

# ---- what only a CPU can refuse -------------------------------------------
# These three need a boot because the host suite cannot execute SYSCALL. They
# are the milestone's hardware claims: that the instruction arrives, and that
# the instruction cleared a flag.

case_S130() { boot_case baseline-boot; }

# FMASK WITHOUT IF.  The kernel-side syscall_masked_flags() cannot see this --
# it ANDs the entry flags with the same constant that was written, so removing
# a bit removes it from both sides.  Only the sentinel's own independent list
# refuses it, which is why that check spells the fourteen flags out rather than
# reading them from the guest.
case_S131() {
  subst src/cpu/fk_syscall.f90 \
    $'       int(z\'00257FD5\', c_int64_t)' \
    $'       int(z\'00257DD5\', c_int64_t)'
  boot_case S131-boot-FMASK-without-IF-so-the-stack-switch-is-interruptible
}

# A DATA DESCRIPTOR FOR CS is a fault taken while handling a fault: it arrives
# as a TRIPLE FAULT and the guest never answers. Caught by timeout or by QEMU
# exiting, never as a wrong assertion.
case_S132() {
  subst src/cpu/fk_syscall.f90 \
    $'    v = shiftl(iand(int(FK_GDT_SEL_CODE, c_int64_t), &' \
    $'    v = shiftl(iand(int(FK_GDT_SEL_DATA, c_int64_t), &'
  boot_case S132-boot-STAR-gives-the-CPU-a-data-descriptor-for-CS
}

# The stub's tail. IRETQ pops int_no and err_code off first; without the
# adjustment it reads the line number as the return RIP.
case_S133() {
  subst boot/interrupts.S \
    $'\tPOP_GPRS\n\taddq\t$16, %rsp\t\t/* int_no and err_code */' \
    $'\tPOP_GPRS'
  boot_case S133-boot-the-syscall-tail-does-not-skip-int_no-and-err_code
}

CASES="baseline S110 S111 S112 S113 S114 S115 S116 S117 S118 S119 \
       S120 S121 S122 S123 S124 S125 S130 S131 S132 S133"

SELECT="$*"
want_case() {
  [ -z "$SELECT" ] && return 0
  case " $SELECT " in *" $1 "*) return 0;; esac
  return 1
}

trap 'restore' EXIT INT TERM
for c in $CASES; do
  want_case "$c" || continue
  restore
  "case_${c}"
done
restore
