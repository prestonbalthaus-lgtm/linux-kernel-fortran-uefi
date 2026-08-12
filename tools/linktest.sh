#!/usr/bin/env bash
# Does a translated module survive REAL kernel build constraints?
# "no libgfortran symbols" is necessary but not sufficient -- the kernel also
# compiles with its own code model, no red zone, no PIC, no stack protector,
# and links -nostdlib. This script rebuilds each module under those flags and
# links it freestanding to prove nothing pulls in a userspace runtime.
set -uo pipefail
KFLAGS="-O2 -fwrapv -fno-underscoring -mcmodel=kernel -mno-red-zone -fno-pic \
        -fno-stack-protector -fno-asynchronous-unwind-tables -fno-common"
fail=0
for f in src/lib/*/fk_*.f90 src/lib/*/*/fk_*.f90; do
  [ -e "$f" ] || continue
  n=$(basename "$f" .f90)
  if ! gfortran $KFLAGS -c -o "/tmp/$n.ko.o" "$f" 2>/tmp/$n.err; then
    echo "  FAIL  $n: does not compile under kernel flags"; sed 's/^/        /' /tmp/$n.err | head -5; fail=1; continue
  fi
  undef=$(nm -u "/tmp/$n.ko.o")
  if [ -n "$undef" ]; then
    echo "  FAIL  $n: undefined symbols under kernel flags:"; echo "$undef" | sed 's/^/        /'; fail=1; continue
  fi
  # freestanding link: no libc, no crt, no libgfortran available at all
  if ld -r -o "/tmp/$n.linked.o" "/tmp/$n.ko.o" 2>/dev/null; then
    echo "  OK    $n  (kernel flags, 0 undefined, links -nostdlib)"
  else
    echo "  FAIL  $n: freestanding link failed"; fail=1
  fi
done
[ $fail -eq 0 ] && echo "=== all modules survive kernel build constraints ===" || echo "=== FAILURES ABOVE ==="
exit $fail
