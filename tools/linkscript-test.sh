#!/usr/bin/env bash
# Does linker.ld actually lay the image out the way it claims? (roadmap 0.1)
#
# Roadmap 0.1's validation is "properly aligns .text, .data and .bss for a
# 64-bit ELF kernel". That is checkable, so it is checked here rather than
# asserted in a commit message -- same standard tools/linktest.sh holds the
# modules to.
#
# This links the REAL kernel modules and the REAL boot stub, not toy objects,
# so the test fails if the script cannot place what the tree actually produces.
# (Until roadmap 1.2 existed this used a throwaway `hlt` stub for ENTRY; now
# boot/boot.S is here, the gate links the thing that will actually boot -- which
# is what makes the .multiboot_header and .bootpt placement checks below real.)
set -uo pipefail
cd "$(dirname "$0")/.."

# The kernel flag set, read back from its single source of truth rather than
# kept as a fourth copy. mk/kflags.mk defines KFLAGS and nothing else.
KFLAGS=$(printf 'include mk/kflags.mk\nprint:\n\t@echo $(KFLAGS)\n' | make -s -f - print) || {
  echo "  FAIL  cannot read KFLAGS out of mk/kflags.mk"; exit 1; }

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf "  \033[32mPASS\033[0m  %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; fail=$((fail+1)); }

# want <name> <expected> <actual>
want() { [ "$2" = "$3" ] && ok "$1 = $2" || bad "$1: expected $2, got $3"; }

echo "=== building the real kernel objects under KFLAGS ==="
# Two passes, because one module USEs another and a single alphabetical pass
# only happens to work today: whatever fails for want of a .mod is retried once
# the rest have been compiled. Anything still failing is a real failure.
objs=""; pending=$(find src -name 'fk_*.f90' | sort)
for attempt in 1 2; do
  retry=""
  for f in $pending; do
    n=$(basename "$f" .f90)
    if gfortran $KFLAGS -J"$WORK" -c -o "$WORK/$n.o" "$f" 2>"$WORK/$n.err"; then
      objs="$objs $WORK/$n.o"
    elif [ "$attempt" = 1 ]; then
      retry="$retry $f"
    else
      bad "$n does not compile under KFLAGS"; sed 's/^/        /' "$WORK/$n.err" | head -3
    fi
  done
  pending="$retry"
  [ -z "$pending" ] && break
done
echo "  $(echo $objs | wc -w) objects"

# The real entry point (roadmap 1.2). Assembled exactly the way Makefile.boot
# assembles it -- through gcc, so cpp expands the PHYS() macro.
if gcc -m64 -fno-pic -Wall -c -o "$WORK/boot.o" boot/boot.S 2>"$WORK/boot.err"; then
  ok "boot/boot.S assembles"
else
  bad "boot/boot.S does not assemble:"; sed 's/^/        /' "$WORK/boot.err" | head -8
fi

echo
echo "=== linking with linker.ld ==="
if ld -nostdlib -z max-page-size=0x1000 -T linker.ld \
      -o "$WORK/kernel.elf" "$WORK/boot.o" $objs 2>"$WORK/link.err"; then
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
echo "=== roadmap 1.2: the Multiboot2 header and the boot page tables ==="
# boot.S cannot import a linker script constant, so it redefines KERNEL_VMA.
# A silent divergence would shift every PHYS() by a fixed offset and produce a
# kernel that triple-faults the instant paging comes on. boot.S's header comment
# promises this gate diffs the two; this is that diff.
# Compared as normalised hex TEXT, not as numbers: 0xFFFFFFFF80000000 exceeds
# the range of bash's signed 64-bit arithmetic, so `printf %d` fails on both
# sides and a numeric comparison passes by accident -- a check that cannot fail
# is worse than no check.
norm_hex() { printf '%s' "$1" | tr 'A-F' 'a-f' | sed 's/^0x0*/0x/'; }
vma_ld=$(sed -n 's/^ *KERNEL_VMA *= *\(0x[0-9A-Fa-f]*\).*/\1/p' linker.ld | head -1)
vma_s=$(sed -n 's/^#define KERNEL_VMA *\(0x[0-9A-Fa-f]*\).*/\1/p' boot/boot.S | head -1)
if [ -z "$vma_ld" ] || [ -z "$vma_s" ]; then
  bad "cannot read KERNEL_VMA from linker.ld ('${vma_ld:-?}') or boot.S ('${vma_s:-?}')"
elif [ "$(norm_hex "$vma_ld")" = "$(norm_hex "$vma_s")" ]; then
  ok "KERNEL_VMA agrees between linker.ld and boot.S ($vma_ld)"
else
  bad "KERNEL_VMA differs: linker.ld says '$vma_ld', boot.S says '$vma_s'"
fi

mbaddr=$(secaddr .multiboot_header)
want "the Multiboot2 header sits at the image base" "$(sym __kernel_start)" "$mbaddr"
want "mb2_header_start is the first byte of the image" "$(sym __kernel_start)" "$(sym mb2_header_start)"
first=$(readelf -SW "$K" | sed 's/^ *\[[ 0-9]*\] *//' | awk '$2 ~ /^(PROGBITS|NOBITS)$/{print $1; exit}')
want "the first section in the image is the header" ".multiboot_header" "$first"
hdrlen=$(( $(sym mb2_header_end) - $(sym mb2_header_start) ))
if [ "$hdrlen" -gt 0 ] && [ "$hdrlen" -le 32768 ]; then
  ok "header is $hdrlen bytes, inside the 32 KiB the spec lets a loader scan"
else bad "header length is $hdrlen bytes"; fi

# The page tables must NOT be in the region boot.S zeroes -- see the .bootpt
# comment in linker.ld. This is the check that keeps that argument true.
bp_s=$(sym __bootpt_start); bp_e=$(sym __bootpt_end)
bs=$(sym __bss_start);      be=$(sym __bss_end)
if [ -z "$bp_s" ]; then bad "__bootpt_start missing: where did the page tables go?"
elif [ $(( bp_s >= be || bp_e <= bs )) -eq 1 ]; then
  ok "boot page tables [$bp_s,$bp_e) are outside the .bss clear [$bs,$be)"
else
  bad "boot page tables OVERLAP the region boot.S zeroes -- clearing .bss would"
  bad "erase the live PML4 and triple-fault on the next instruction fetch"
fi
if [ $(( bp_s & 0xFFF )) -eq 0 ]; then ok "boot page tables are 4 KiB aligned"
else bad "boot page tables at $bp_s are not 4 KiB aligned (CR3 requires it)"; fi
for t in pml4_table pdpt_low pdpt_high pd_table; do
  a=$(sym $t)
  if [ -z "$a" ]; then bad "$t is not in the image"
  elif [ $(( a >= bp_s && a < bp_e )) -eq 1 ]; then ok "$t is inside .bootpt"
  else bad "$t at $a is outside .bootpt [$bp_s,$bp_e)"; fi
done
bptype=$(readelf -SW "$K" | sed 's/^ *\[[ 0-9]*\] *//' | awk '$1==".bootpt"{print $2}')
want ".bootpt occupies no file space" "NOBITS" "$bptype"

# GRUB's own rule about the entry point, plus the whole header contract.
echo
echo "=== the linked image is one GRUB would accept (tools/mb2-check.py) ==="
if python3 tools/mb2-check.py "$K" --quiet; then
  ok "Multiboot2 conformance of the fully-linked image"
else
  bad "the fully-linked image fails Multiboot2 conformance"
  python3 tools/mb2-check.py "$K" | sed 's/^/        /'
fi

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
