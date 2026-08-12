#!/usr/bin/env bash
# Does a translated module survive REAL kernel build constraints?
#
# "no libgfortran symbols" is necessary but not sufficient. The kernel also
# builds with its own code model, no red zone, no PIC, no stack protector, and
# -- critically -- with every FP/vector instruction set disabled, because kernel
# code may not touch FPU/SSE registers outside kernel_fpu_begin()/end().
#
# Flag set mirrors vendor/linux-*/arch/x86/Makefile for x86_64:
#   :76      -mno-sse -mno-mmx -mno-sse2 -mno-3dnow -mno-avx -mno-sse4a
#            ("Prevent GCC from generating any FP code by mistake")
#   :152-153 -mno-80387 -mno-fp-ret-in-387
#   :175-176 -mno-red-zone -mcmodel=kernel
# plus -fno-common / -fno-PIE / -fno-strict-aliasing from the top-level Makefile.
#
# Three gates per module, all of which must hold:
#   (a) compiles under the kernel flag set
#   (b) emits NO FP/vector instruction  -- enforces the flags above
#   (c) has zero undefined symbols AND survives a real freestanding link
#
# NOTE on (c): the previous version ran `ld -r`, which never resolves symbols
# and therefore always succeeded -- an object calling print * passed it. See
# docs/AUDIT-PHASE1.md finding A-2. `--no-undefined` does NOT fix that under
# -r (it is a final-link option, silently ignored); only a real link does.
set -uo pipefail
cd "$(dirname "$0")/.."

KFLAGS="-O2 -fwrapv -fno-underscoring \
        -mcmodel=kernel -mno-red-zone -fno-pic -fno-stack-protector \
        -fno-asynchronous-unwind-tables -fno-common -fno-strict-aliasing \
        -mno-sse -mno-mmx -mno-sse2 -mno-3dnow -mno-avx -mno-sse4a \
        -mno-80387 -mno-fp-ret-in-387"

SRCDIR="${1:-src}"
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
fail=0

for f in $(find "$SRCDIR" -name "fk_*.f90" | sort); do
  n=$(basename "$f" .f90)
  obj="$WORK/$n.o"

  # (a) compiles under kernel flags
  if ! gfortran $KFLAGS -J"$WORK" -c -o "$obj" "$f" 2>"$WORK/$n.err"; then
    echo "  FAIL  $n: does not compile under kernel flags"
    sed 's/^/        /' "$WORK/$n.err" | head -5
    fail=1; continue
  fi

  # (b) no FP/vector instructions -- would corrupt user FPU state in kernel ctx
  fp=$(objdump -d "$obj" | grep -oE '%(x|y|z)mm[0-9]+|%mm[0-7]|[[:space:]]f(ld|st|add|mul|div|sub)[a-z]*[[:space:]]' | sort -u)
  if [ -n "$fp" ]; then
    echo "  FAIL  $n: emits FP/vector instructions (needs kernel_fpu_begin):"
    echo "$fp" | sed 's/^/        /' | head -8
    fail=1; continue
  fi

  # (c) zero undefined symbols ...
  undef=$(nm -u "$obj")
  if [ -n "$undef" ]; then
    echo "  FAIL  $n: undefined symbols under kernel flags:"
    echo "$undef" | sed 's/^/        /'
    fail=1; continue
  fi

  # ... and a REAL freestanding link (entry symbol derived from the object, so
  # this stays generic as new translations are added).
  ent=$(nm --defined-only -g "$obj" | awk '$2=="T"{print $3; exit}')
  if [ -z "$ent" ]; then
    echo "  FAIL  $n: no global text symbol to link against"; fail=1; continue
  fi
  if ld -nostdlib -e "$ent" -o /dev/null "$obj" 2>/dev/null; then
    echo "  OK    $n  (kernel flags, no FP/vector, 0 undefined, links -nostdlib)"
  else
    echo "  FAIL  $n: freestanding link failed"; fail=1
  fi
done

echo
if [ $fail -eq 0 ]; then
  echo "=== all modules survive kernel build constraints ==="
else
  echo "=== FAILURES ABOVE ==="
fi
exit $fail
