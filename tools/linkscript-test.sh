#!/usr/bin/env bash
# Does linker.ld actually lay the image out the way it claims? (roadmap 0.1)
#
# Roadmap 0.1's validation is "properly aligns .text, .data and .bss for a
# 64-bit ELF kernel". That is checkable, so it is checked here rather than
# asserted in a commit message -- same standard tools/linktest.sh holds the
# modules to.
#
# This links the REAL nine kernel modules, not a toy object, so the test fails
# if the script cannot place what the tree actually produces. The entry symbol
# is a throwaway stub generated here: the real one is roadmap 1.2 and does not
# exist yet, and inventing it in this script would be building 1.2 by accident.
set -uo pipefail
cd "$(dirname "$0")/.."

KFLAGS="-O2 -fwrapv -fno-underscoring \
        -mcmodel=kernel -mno-red-zone -fno-pic -fno-stack-protector \
        -fno-asynchronous-unwind-tables -fno-common -fno-strict-aliasing \
        -mno-sse -mno-mmx -mno-sse2 -mno-3dnow -mno-avx -mno-sse4a \
        -mno-80387 -mno-fp-ret-in-387"

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf "  \033[32mPASS\033[0m  %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; fail=$((fail+1)); }

# want <name> <expected> <actual>
want() { [ "$2" = "$3" ] && ok "$1 = $2" || bad "$1: expected $2, got $3"; }

echo "=== building the real kernel objects under KFLAGS ==="
objs=""
for f in $(find src -name 'fk_*.f90' | sort); do
  n=$(basename "$f" .f90)
  if gfortran $KFLAGS -J"$WORK" -c -o "$WORK/$n.o" "$f" 2>"$WORK/$n.err"; then
    objs="$objs $WORK/$n.o"
  else
    bad "$n does not compile under KFLAGS"; sed 's/^/        /' "$WORK/$n.err" | head -3
  fi
done
echo "  $(echo $objs | wc -w) objects"

# Throwaway entry point. Deliberately minimal: proves the script can resolve
# ENTRY(_start), nothing more. Roadmap 1.2 replaces this.
cat > "$WORK/stub.S" <<'ASM'
        .section .text.boot, "ax", @progbits
        .globl _start
_start:
        hlt
        jmp _start
ASM
gcc -c -o "$WORK/stub.o" "$WORK/stub.S" || bad "stub assembly failed"

echo
echo "=== linking with linker.ld ==="
if ld -nostdlib -z max-page-size=0x1000 -T linker.ld \
      -o "$WORK/kernel.elf" "$WORK/stub.o" $objs 2>"$WORK/link.err"; then
  ok "links (ASSERTs in linker.ld all held)"
else
  bad "link failed:"; sed 's/^/        /' "$WORK/link.err" | head -12
  echo; echo "=== $pass passed, $fail failed ==="; exit 1
fi

K="$WORK/kernel.elf"
sym() { nm "$K" | awk -v s="$1" '$3==s{print "0x"$1}'; }
secaddr() { readelf -SW "$K" | sed 's/^ *\[[ 0-9]*\] *//' \
              | awk -v s="$1" '$1==s{print "0x"$3}'; }
# LOAD line: 1=LOAD 2=Off 3=VirtAddr 4=PhysAddr 5=FileSiz 6=MemSiz 7..NF-1=Flg NF=Align
# Flg is "R E" (two fields) or "RW" (one), so it must be joined, not indexed.
segflags() { readelf -lW "$K" | awk '/^  LOAD/{f="";for(i=7;i<NF;i++)f=f $i; print f}'; }

echo
echo "=== addresses ==="
want "__kernel_start"     "0xffffffff80100000" "$(sym __kernel_start)"
want "entry point"        "$(sym _start)"      "0x$(readelf -hW "$K" | awk '/Entry point/{print $NF}' | sed 's/^0x//')"

echo
echo "=== 4 KiB alignment of every section (roadmap 0.1's actual criterion) ==="
for s in .text .rodata .data .bss; do
  a=$(secaddr "$s")
  if [ -z "$a" ]; then bad "$s missing from the image"
  elif [ $(( a & 0xFFF )) -eq 0 ]; then ok "$s at $a is 4 KiB aligned"
  else bad "$s at $a is NOT 4 KiB aligned"; fi
done

echo
echo "=== physical (LMA) vs virtual (VMA) split ==="
lma=$(readelf -lW "$K" | awk '/LOAD/{print $4; exit}')
if [ "$lma" = "0x0000000000100000" ]; then ok "first PT_LOAD physical address is 1 MiB ($lma)"
else bad "first PT_LOAD LMA is $lma, expected 0x0000000000100000"; fi

nseg=$(readelf -lW "$K" | grep -c '^  LOAD')
want "PT_LOAD segments (text/rodata/data)" "3" "$nseg"

# Distinct permissions are the whole reason for having three segments: this is
# what lets the VMM map code RX, constants RO and data RW-noexec. If all three
# came out RWX the split would be decorative.
perms=$(segflags | tr '\n' ' ')
want "segment permissions (text rodata data)" "RE R RW " "$perms"

# .text must be executable and NOT writable -- a writable .text is the single
# most valuable thing an exploit can find in a kernel image.
tflags=$(segflags | sed -n 1p)
case "$tflags" in
  *W*) bad ".text segment is WRITABLE ($tflags)" ;;
  *E*) ok  ".text segment is executable and not writable ($tflags)" ;;
  *)   bad ".text segment is not executable ($tflags)" ;;
esac
dflags=$(segflags | sed -n 3p)
case "$dflags" in
  *E*) bad ".data segment is EXECUTABLE ($dflags)" ;;
  *W*) ok  ".data segment is writable and not executable ($dflags)" ;;
esac

echo
echo "=== .bss contract for the entry stub's zeroing loop (roadmap 1.3) ==="
for s in __bss_start __bss_end __boot_stack_top __boot_stack_bottom \
         __kernel_end __kernel_phys_start __kernel_phys_end; do
  [ -n "$(sym $s)" ] && ok "$s exported = $(sym $s)" || bad "$s missing"
done
bs=$(sym __bss_start); be=$(sym __bss_end)
if [ $(( be > bs )) -eq 1 ]; then ok ".bss is non-empty ($(( be - bs )) bytes incl. 16 KiB stack)"
else bad ".bss is empty or inverted"; fi

echo
echo "=== the font really is read-only ==="
ro_s=$(sym __rodata_start); ro_e=$(sym __rodata_end)
fa=$(nm "$K" | awk '/MOD_font_8x16$/{print "0x"$1}')
if [ -z "$fa" ]; then bad "font symbol not found in the image"
elif [ $(( fa >= ro_s && fa < ro_e )) -eq 1 ]; then ok "font table is inside .rodata (not writable)"
else bad "font at $fa is OUTSIDE .rodata [$ro_s,$ro_e)"; fi

echo
echo "=== no 2 MiB segment padding (the -z max-page-size flag is doing its job) ==="
sz=$(stat -c%s "$K")
if [ "$sz" -lt 262144 ]; then ok "image is $sz bytes (< 256 KiB)"
else bad "image is $sz bytes -- looks like 2 MiB segment padding crept back in"; fi

echo
echo "=== discarded sections really are gone ==="
for s in .comment .note.gnu.property .eh_frame; do
  readelf -SW "$K" | grep -qE "[[:space:]]$s[[:space:]]" \
    && bad "$s survived into the image" || ok "$s discarded"
done

echo
echo "=== $pass passed, $fail failed ==="
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
