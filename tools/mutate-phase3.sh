#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Drives the mutation table in docs/HARNESS-VALIDATION-PHASE3.md: injects one
# defect at a time into the roadmap 3.1/3.2 code, rebuilds from clean, boots it
# and restores the tree.  A mutation the boot gate ACCEPTS is an ESCAPE.
#
# Edits the working tree in place and restores with `git checkout`, so run it on
# a clean tree.  Needs a VM, so it runs on the host, not in the container.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${FK_MUTATE_OUT:-$(mktemp -d /tmp/fk-mutate.XXXXXX)}"
mkdir -p "$OUT"
echo "logs: $OUT"
EXPECT="EXCEPTION 0x00 ERR 0x0000000000000000 -- #DE Divide-by-Zero Error"
REJECT="Fortran Kernel: the divide by zero did NOT trap."

run_case() {
  local name=$1
  # clean-boot every time: make decides freshness by mtime, and a restored file
  # can be newer than the object it was NOT built from.
  ./tools/run.sh clean-boot >/dev/null 2>&1
  if ! ./tools/run.sh iso >"$OUT/$name.build" 2>&1; then
    echo "$name: BUILD FAILED (caught at build time)"
    return
  fi
  FK_EXPECT_SERIAL="$EXPECT" FK_REJECT_SERIAL="$REJECT" \
    tools/qemu-boot-test.sh >"$OUT/$name.log" 2>&1
  local rc=$?
  local line
  line=$(grep -aE "EXCEPTION 0x|RBX|RBP|QEMU EXITED|did NOT trap" "$OUT/$name.log" \
         | head -4 | tr -d '\r' | sed 's/^ *//' | paste -sd'|')
  if [ $rc -eq 0 ]; then
    echo "$name: gate PASSED (ESCAPE) :: $line"
  else
    echo "$name: gate FAILED (caught) :: $line"
  fi
}

restore() { git checkout -- boot/interrupts.S src/cpu/fk_idt.f90 2>/dev/null; }

echo "=== baseline (unmutated) ==="
run_case baseline

echo "=== M1: ISR_NOERR pushes no dummy error code ==="
python3 - <<'PY'
p='boot/interrupts.S'; s=open(p).read()
s=s.replace("""isr\\vec:
	pushq	$0
	pushq	$\\vec""","""isr\\vec:
	pushq	$\\vec""",1)
open(p,'w').write(s)
PY
run_case m1-no-dummy-errcode; restore

echo "=== M2: IDT gates installed with the present bit clear ==="
sed -i "s/FK_IDT_ATTR_INTR = int(z'8E', c_int8_t)/FK_IDT_ATTR_INTR = int(z'0E', c_int8_t)/" src/cpu/fk_idt.f90
run_case m2-gate-not-present; restore

echo "=== M3: RBX and RBP pushed in the wrong order ==="
python3 - <<'PY'
p='boot/interrupts.S'; s=open(p).read()
s=s.replace("""	pushq	%rbx
	pushq	%rbp""","""	pushq	%rbp
	pushq	%rbx""",1)
open(p,'w').write(s)
PY
run_case m3-swapped-gprs; restore

echo "=== M4: fk_isr_stub returns the stub for vector n+1 ==="
python3 - <<'PY'
p='boot/interrupts.S'; s=open(p).read()
s=s.replace("""	movslq	%edi, %rdi		/* the ABI leaves bits 63:32 undefined */""",
            """	movslq	%edi, %rdi
	addq	$1, %rdi""",1)
open(p,'w').write(s)
PY
run_case m4-stub-off-by-one; restore

echo "=== M5: no CLD before calling into Fortran ==="
python3 - <<'PY'
p='boot/interrupts.S'; s=open(p).read()
s=s.replace("""	/* An interrupt gate does not clear DF, and SysV requires DF=0 on entry. */
	cld
""","",1)
open(p,'w').write(s)
PY
run_case m5-no-cld; restore

echo "=== restoring and rebuilding the real tree ==="
restore
./tools/run.sh clean-boot >/dev/null 2>&1
./tools/run.sh iso >/dev/null 2>&1 && echo "tree restored and ISO rebuilt"
git status --short
