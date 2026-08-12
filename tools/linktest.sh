#!/usr/bin/env bash
# Does a translated module survive kernel build constraints?
# Usage: tools/linktest.sh [srcdir]   (srcdir defaults to src)
#
# Flag set mirrors arch/x86/Makefile for x86_64 (:76, :152-153, :175-176) plus
# -fno-common, -fno-PIE and -fno-strict-aliasing from the top-level Makefile.
#
# Three gates per module:
#   (a) compiles under the kernel flag set
#   (b) emits no FP/vector instruction
#   (c) every undefined symbol is defined elsewhere in this tree, and the object
#       survives a real freestanding link against the rest of it
#
# `ld -r` cannot serve for (c): a relocatable link never resolves symbols, so an
# object calling print * passes it (--no-undefined is ignored under -r).
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

# Build the whole tree first, so (c) can ask what this tree defines rather than
# whether a symbol is absent.  boot/*.S is part of the tree: it holds the
# primitives with no Fortran spelling (fk_cpu_halt, fk_outb, fk_inb).
# [ -e ] guards the unmatched glob: without nullglob an empty boot/ leaves the
# literal string "boot/*.S" in $s.
# FK_BOOTDIR lets tools/gate-selftest.sh point this at a directory of broken .S.
BOOTDIR="${FK_BOOTDIR:-boot}"

objs=""
for s in "$BOOTDIR"/*.S; do
  [ -e "$s" ] || continue
  a=$(basename "$s" .S)
  # -m64 -fno-pic -Wall is Makefile.boot's AFLAGS_KERNEL.  Assembling through
  # gcc rather than as is what runs cpp, which boot.S's PHYS() macro needs.
  if gcc -m64 -fno-pic -Wall -c -o "$WORK/$a.o" "$s" 2>"$WORK/$a.aserr"; then
    objs="$objs $WORK/$a.o"
  else
    echo "  FAIL  $s does not assemble (everything it defines is now missing"
    echo "        from the in-tree symbol set, so ignore any orphan reports below)"
    sed 's/^/        /' "$WORK/$a.aserr" | head -5
    fail=1
  fi
done
pending=$(find "$SRCDIR" -name "fk_*.f90" | sort)
for attempt in 1 2; do
  retry=""
  for f in $pending; do
    n=$(basename "$f" .f90)
    if gfortran $KFLAGS -J"$WORK" -c -o "$WORK/$n.o" "$f" 2>"$WORK/$n.err"; then
      objs="$objs $WORK/$n.o"
    else
      retry="$retry $f"
    fi
  done
  pending="$retry"
  [ -z "$pending" ] && break
done

# Every global symbol this tree DEFINES. nm -P prints "name Type Value Size";
# lowercase types are local, so -g keeps this to real definitions.
PROVIDED=$(for o in $objs; do nm -g --defined-only -P "$o" 2>/dev/null | cut -d' ' -f1; done | sort -u)

for f in $(find "$SRCDIR" -name "fk_*.f90" | sort); do
  n=$(basename "$f" .f90)
  obj="$WORK/$n.o"

  # (a) compiles under kernel flags
  if ! gfortran $KFLAGS -J"$WORK" -c -o "$obj" "$f" 2>"$WORK/$n.err"; then
    echo "  FAIL  $n: does not compile under kernel flags"
    sed 's/^/        /' "$WORK/$n.err" | head -5
    fail=1; continue
  fi

  # (b) no FP/vector instructions
  fp=$(objdump -d "$obj" | grep -oE '%(x|y|z)mm[0-9]+|%mm[0-7]|[[:space:]]f(ld|st|add|mul|div|sub)[a-z]*[[:space:]]' | sort -u)
  if [ -n "$fp" ]; then
    echo "  FAIL  $n: emits FP/vector instructions (needs kernel_fpu_begin):"
    echo "$fp" | sed 's/^/        /' | head -8
    fail=1; continue
  fi

  # (c) every undefined symbol is provided by this tree
  undef=$(nm -u -P "$obj" | cut -d' ' -f1)
  orphans=""
  for u in $undef; do
    printf '%s\n' "$PROVIDED" | grep -qx -- "$u" || orphans="$orphans $u"
  done
  if [ -n "$orphans" ]; then
    echo "  FAIL  $n: undefined symbols that NOTHING in this tree defines:"
    for u in $orphans; do
      case "$u" in
        _gfortran_*) echo "        $u   <- the libgfortran runtime" ;;
        memcpy|memset|memmove|malloc|free|printf|puts)
                     echo "        $u   <- a libc that kernel space does not have" ;;
        *)           echo "        $u" ;;
      esac
    done
    fail=1; continue
  fi
  ndep=$(printf '%s' "$undef" | wc -w)

  # ... and a real freestanding link against the rest of the tree; linked alone
  # it would fail on the legitimate cross-module references.
  ent=$(nm --defined-only -g "$obj" | awk '$2=="T"{print $3; exit}')
  if [ -z "$ent" ]; then
    echo "  FAIL  $n: no global text symbol to link against"; fail=1; continue
  fi
  others=$(for o in $objs; do [ "$o" = "$obj" ] || printf '%s ' "$o"; done)
  # boot.o references three symbols that only linker.ld defines; this probe links
  # without that script, so they are supplied as placeholder absolutes.
  LDSCRIPT_SYMS="--defsym __bss_start=0 --defsym __bss_end=0 --defsym __boot_stack_top=0"
  if ld -nostdlib $LDSCRIPT_SYMS -e "$ent" -o /dev/null "$obj" $others 2>"$WORK/$n.link"; then
    echo "  OK    $n  (kernel flags, no FP/vector, $ndep in-tree dep(s), links -nostdlib)"
  else
    echo "  FAIL  $n: freestanding link failed"
    sed 's/^/        /' "$WORK/$n.link" | head -5
    fail=1
  fi
done

echo
if [ $fail -eq 0 ]; then
  echo "=== all modules survive kernel build constraints ==="
else
  echo "=== FAILURES ABOVE ==="
fi
exit $fail
