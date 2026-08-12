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

# The real entry point (roadmap 1.2) and the port-I/O primitives (roadmap 2.1).
# Assembled exactly the way Makefile.boot assembles it -- through gcc with
# AFLAGS_KERNEL, so cpp expands boot.S's PHYS() macro.
#
# ONE NAMED CHECK PER FILE, not one for the set. A single "the boot assembly
# assembles" line tells whoever reads the failure that something under boot/ is
# broken without saying WHICH file, and these files are written by different
# people against different roadmap items; the name is the first half of the
# diagnosis.
#
# THIS GLOBS WHERE Makefile.boot DELIBERATELY DOES NOT, and the difference is
# not an oversight. Makefile.boot names its sources one by one because the
# CONTENTS OF THE BOOTABLE IMAGE are a decision -- a stray experiment left in
# boot/ must not silently become part of what boots. A gate wants the opposite
# property: anything sitting in the tree must be held to the layout contract,
# and a new boot/*.S that no gate has ever looked at is precisely the file that
# will be discovered by a machine that reboots. So the image is a named list and
# the gate is a glob, on purpose.
#
# [ -e ] guards the unmatched glob: with no nullglob an empty boot/ would leave
# the literal string "boot/*.S" here.
#
# Assembly order: the glob is sorted, so boot.S goes first today. Nothing below
# depends on that. linker.ld places *(.text.boot) ahead of *(.text .text.*) and
# KEEPs .multiboot_header as its own first output section, so the entry stub and
# the Multiboot2 header stay at the front of the image whatever order the
# objects reach ld in -- which is worth writing down, because the "first byte of
# the image" checks further down WOULD be link-order-sensitive if the layout
# were relying on input order instead of on section names.
aobjs=""
for s in boot/*.S; do
  [ -e "$s" ] || continue
  a=$(basename "$s" .S)
  if gcc -m64 -fno-pic -Wall -c -o "$WORK/$a.o" "$s" 2>"$WORK/$a.err"; then
    ok "$s assembles"; aobjs="$aobjs $WORK/$a.o"
  else
    bad "$s does not assemble:"; sed 's/^/        /' "$WORK/$a.err" | head -8
  fi
done

echo
echo "=== linking with linker.ld ==="
# $aobjs, not a hardcoded boot.o: without boot/io.S on this line the link dies
# on an undefined fk_outb the moment fk_serial exists, and the failure would be
# reported against linker.ld -- a layout gate blaming the layout for a missing
# input file is a diagnosis nobody recovers from quickly.
if ld -nostdlib -z max-page-size=0x1000 -T linker.ld \
      -o "$WORK/kernel.elf" $aobjs $objs 2>"$WORK/link.err"; then
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
echo "=== every routine the boot assembly exports is in the executable segment ==="
# roadmap 2.1 put fk_outb and fk_inb in boot/io.S. A port-I/O primitive is a
# four-instruction leaf, and a four-instruction leaf is exactly the kind of code
# that gets written under whatever .section directive happened to be in effect
# above it -- a stray `.section .data, "aw"` assembles clean, links clean, and
# produces a kernel whose I/O routines live in a WRITABLE segment, which on a
# tree that later sets NX on .data is also a non-executable one. Nothing else in
# the build would notice.
#
# The segment checks further up prove the .text SEGMENT is R+E and not writable.
# This is the separate claim that the code actually landed inside it.
#
# DIVISION OF LABOUR with the other gate, so neither is written twice:
# tools/linktest.sh fails fk_serial if NOTHING in this tree defines fk_outb, so
# "does the symbol exist" is answered there. Only a gate that links with
# linker.ld can answer "and where did the definition end up". Neither covers for
# the other.
#
# Driven by what the assembly actually exports rather than by a hardcoded pair
# of names: it then extends itself to whatever boot/*.S grows next, and it stays
# correct on a tree where io.S does not exist yet (with boot.S alone it checks
# _start and fk_cpu_halt). `nm -P` type T means precisely "global, defined, in a
# text section", which is the right filter here -- boot.S's other globals are
# deliberately NOT in .text and must not be dragged in: mb2_header_start/end are
# R (.multiboot_header), saved_magic/saved_mbi are D (.data), pml4_table and its
# three siblings are B (.bootpt), and each of those already has its own check.
#
# On the arithmetic: these addresses are above 0x7FFFFFFFFFFFFFFF, and bash
# evaluates $(( )) as SIGNED 64-bit, so every one of them wraps to a negative
# number. That is safe here and was NOT safe in the KERNEL_VMA comparison above,
# for a reason worth keeping straight: here all three values wrap by the same
# 2^64 and their ordering survives intact, whereas there the two sides came from
# different files and one of them overflowed printf into a fixed value, which
# turned the comparison into one that could not fail.
ts=$(sym __text_start); te=$(sym __text_end)
nre=0
for o in $aobjs; do
  for t in $(nm -g --defined-only -P "$o" | awk '$2=="T"{print $1}'); do
    a=$(sym "$t"); nre=$((nre+1))
    if [ -z "$a" ]; then
      bad "$t is exported by the boot assembly but is not in the linked image"
    elif [ $(( a >= ts && a < te )) -eq 1 ]; then
      ok "$t at $a is inside .text [$ts,$te)"
    else
      bad "$t at $a is OUTSIDE .text [$ts,$te) -- wrong .section in the .S?"
    fi
  done
done
# A loop with nothing to iterate over passes silently, which is how a check
# quietly stops being one. boot/boot.S alone exports two text symbols, so zero
# here means the assembly did not build or nm's output changed shape -- not that
# the tree is clean.
[ "$nre" -gt 0 ] || bad "no global text symbols found in the boot assembly at all"

echo
echo "=== fk_inb defines the whole of EAX before it reads the port (2.1) ==="
# THE ONLY WHITE-BOX CHECK IN THIS FILE, and it is here because it is the only
# thing that can see this defect at all. Stated plainly so nobody mistakes it for
# a behavioural test: it inspects the INSTRUCTIONS, not what they compute.
#
# 'inb %dx, %al' writes AL and leaves EAX bits 31:8 exactly as it found them, so
# fk_inb must define them itself or it returns a byte with whatever the previous
# occupant of EAX left attached. boot/io.S does that with 'xorl %eax, %eax'
# before the IN.
#
# WHY NO BLACK-BOX TEST REACHES IT, which is the whole justification:
#   * tests/drivers/serial/test_serial.c supplies its OWN fk_inb in C. boot/io.S
#     is not linked into the host suite at all, so nothing there can observe it.
#   * The boot gate cannot see it either, and this was MEASURED, not assumed:
#     deleting the xorl and booting the result produces a completely clean run --
#     banner present, no self-test failure reported -- because at that call site
#     the stale upper bits of EAX happen to be zero, so the loopback probe still
#     compares equal to 0xAE. Recorded as M15 in docs/HARNESS-VALIDATION-SERIAL.md.
#     "Happen to be zero" is the point: it is a property of today's register
#     allocation, and the day it changes the failure is a self-test that reports
#     broken hardware on a UART that is fine.
#
# WHAT THIS CHECK IS WORTH, HONESTLY. It asserts that some instruction other than
# the IN writes EAX inside fk_inb -- a spelling, not a semantics. 'xorl %eax,%eax'
# and 'movzbl %al,%eax' after the IN would both satisfy it, and both are correct;
# an instruction that wrote EAX and then clobbered it would satisfy it and not be.
# It is a tripwire on a property no other gate can reach, not a proof.
if [ -z "$(sym fk_inb)" ]; then
  ok "fk_inb is not in this tree yet -- nothing to check"
else
  eax_def=$(objdump -d --disassemble=fk_inb "$K" 2>/dev/null \
            | grep -cE '(xor|mov|movz)[a-z]*[[:space:]].*%eax')
  if [ "${eax_def:-0}" -gt 0 ]; then
    ok "fk_inb defines EAX itself ($eax_def instruction(s) write %eax besides the IN)"
  else
    bad "fk_inb writes only AL: bits 31:8 of the returned int32_t are whatever"
    bad "     the caller left in EAX. serial_init's 0xAE loopback probe then"
    bad "     compares unequal on a UART that is working perfectly."
  fi
fi

echo
echo "=== no 2 MiB segment padding (the -z max-page-size flag is doing its job) ==="
# The 256 KiB bound was re-measured, not assumed, when roadmap 2.1 added
# boot/io.S and src/drivers/serial/fk_serial.f90.
#
# HOW THESE TWO NUMBERS WERE OBTAINED, because a figure labelled "measured" that
# nobody can reproduce is worse than no figure: run this gate, then move
# boot/io.S and src/drivers/serial/ aside, restore src/boot/fk_kmain.f90 to its
# pre-2.1 revision, and run it again. The gate tolerates the reduced tree by
# construction (it globs boot/*.S and finds src/**/fk_*.f90), reporting 42 checks
# instead of 45. Re-derive them the same way after any change that moves them.
#
# 25248 bytes before either file existed, 25600 bytes after both -- 352 bytes for two
# leaf I/O routines, the UART driver and its banner, because all of it fits in
# slack already inside the 4 KiB-aligned .text and .rodata regions. That leaves
# ~231 KiB of headroom, and even a pessimistic future in which all four aligned
# sections each gain a whole page only reaches ~37 KiB.
#
# So the bound is left where it is rather than tightened to hug the current
# size. What it exists to catch is the -z max-page-size flag going missing,
# which pads three PT_LOADs to 2 MiB each and adds MEGABYTES; a bound tuned to
# the present size would instead fire on ordinary growth, and a gate that cries
# wolf on every new module gets raised rather than investigated.
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
