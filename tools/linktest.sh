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
#   (c) every undefined symbol is defined ELSEWHERE IN THIS TREE, and the
#       module survives a real freestanding link against it
#
# NOTE on (c), part 1: the original version ran `ld -r`, which never resolves
# symbols and therefore always succeeded -- an object calling print * passed
# it. See docs/AUDIT-PHASE1.md finding A-2. `--no-undefined` does NOT fix that
# under -r (it is a final-link option, silently ignored); only a real link does.
#
# NOTE on (c), part 2 -- WHY THIS IS NO LONGER "ZERO UNDEFINED SYMBOLS".
# That was the right rule while every module was a self-contained leaf
# translation, and it was a proxy for the property actually wanted: no
# dependency on a runtime that will not exist in kernel space. Roadmap 1.2
# introduced two references that are correct and unavoidable:
#
#   fk_kmain       -> fk_cpu_halt   (boot/boot.S: CLI/HLT is a privileged
#                                    instruction with no Fortran spelling)
#   fk_gop_renderer-> vga_font_row  (fk_font_8x16: the font is DATA in its own
#                                    module, reached through an accessor so the
#                                    4 KiB table is not duplicated per object)
#
# Keeping the literal rule would have meant either fusing modules that have no
# business being fused, or deleting the gate. Instead the rule now states the
# property directly: an undefined symbol is acceptable if and only if something
# in this tree defines it. libgfortran, libc and typos are all still failures,
# and tools/gate-selftest.sh proves each of those is still rejected.
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

# PASS 0: build everything first, so that (c) can ask "does anything in this
# tree define this symbol?" instead of "is this symbol absent?".
#
# boot/boot.S is part of the tree even when SRCDIR is not src/: it is where the
# privileged-instruction primitives live, and a Fortran module calling
# fk_cpu_halt is depending on the tree, not on a runtime. Two passes over the
# Fortran, because one module USEs another and the .mod it needs may not have
# been written yet on the first pass.
objs=""
[ -f boot/boot.S ] && gcc -m64 -fno-pic -c -o "$WORK/boot.o" boot/boot.S 2>/dev/null \
  && objs="$WORK/boot.o"
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

  # (b) no FP/vector instructions -- would corrupt user FPU state in kernel ctx
  fp=$(objdump -d "$obj" | grep -oE '%(x|y|z)mm[0-9]+|%mm[0-7]|[[:space:]]f(ld|st|add|mul|div|sub)[a-z]*[[:space:]]' | sort -u)
  if [ -n "$fp" ]; then
    echo "  FAIL  $n: emits FP/vector instructions (needs kernel_fpu_begin):"
    echo "$fp" | sed 's/^/        /' | head -8
    fail=1; continue
  fi

  # (c) every undefined symbol is provided by this tree ...
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

  # ... and a REAL freestanding link, against the rest of the tree, which is
  # the environment the object will actually live in. Linking it alone would
  # now fail for the legitimate cross-module references described in the
  # header, and linking with `ld -r` would resolve nothing at all.
  ent=$(nm --defined-only -g "$obj" | awk '$2=="T"{print $3; exit}')
  if [ -z "$ent" ]; then
    echo "  FAIL  $n: no global text symbol to link against"; fail=1; continue
  fi
  others=$(for o in $objs; do [ "$o" = "$obj" ] || printf '%s ' "$o"; done)
  # boot.o legitimately references symbols that only linker.ld defines (the
  # bounds of the region it zeroes, and the top of the boot stack). This probe
  # links WITHOUT that script -- it is asking "does this object need a runtime",
  # not "is the image laid out correctly" -- so those three are supplied here as
  # placeholder absolutes. That they really are exported by linker.ld, at
  # sensible addresses, is asserted by tools/linkscript-test.sh, which links the
  # whole tree WITH the script. Neither gate covers for the other.
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
