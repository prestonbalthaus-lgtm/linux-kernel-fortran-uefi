#!/usr/bin/env bash
# Does linker.ld lay the image out the way it claims?  Links the real kernel
# modules and the real boot stub, then checks the resulting ELF.
set -uo pipefail
cd "$(dirname "$0")/.."

# KFLAGS is read back from mk/kflags.mk rather than kept as a fourth copy.
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
# Two passes: a module that USEs another may need a .mod not written yet.
objs=""; pending=$(find src -name 'fk_*.f90' | sort)
# Retry until a pass adds nothing.  Path order is not USE order, and the chains
# are deeper than one level (fk_kmain -> fk_idt -> fk_gdt), so a fixed number of
# passes silently mistakes "not compiled yet" for "does not compile".
while [ -n "$pending" ]; do
  retry=""
  for f in $pending; do
    n=$(basename "$f" .f90)
    if gfortran $KFLAGS -J"$WORK" -c -o "$WORK/$n.o" "$f" 2>"$WORK/$n.err"; then
      objs="$objs $WORK/$n.o"
    else
      retry="$retry $f"
    fi
  done
  if [ "$(echo $retry | wc -w)" -eq "$(echo $pending | wc -w)" ]; then
    for f in $retry; do
      n=$(basename "$f" .f90)
      bad "$n does not compile under KFLAGS"; sed 's/^/        /' "$WORK/$n.err" | head -3
    done
    break
  fi
  pending="$retry"
done
echo "  $(echo $objs | wc -w) objects"

# Assembled the way Makefile.boot does it -- through gcc, so cpp expands boot.S's
# PHYS() macro.  [ -e ] guards the unmatched glob.
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

# Three segments exist so code maps RX, constants RO and data RW-noexec.
perms=$(segflags | tr '\n' ' ')
want "segment permissions (text rodata data)" "RE R RW " "$perms"

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
# boot.S redefines KERNEL_VMA because it cannot import a linker script constant;
# a divergence shifts every PHYS().  Compared as normalised hex TEXT: the value
# exceeds bash's signed 64-bit arithmetic, so a numeric compare cannot fail.
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

# The page tables must not sit in the region boot.S zeroes.
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
# nm -P type T means global, defined, in a text section; boot.S's other globals
# are R, D and B and are checked above.
# These addresses wrap negative under bash's signed $(( )), but all of them wrap
# by the same 2^64, so the ordering survives.
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
[ "$nre" -gt 0 ] || bad "no global text symbols found in the boot assembly at all"

echo
echo "=== the 32 IDT stub addresses really are isr0..isr31, in order (3.2) ==="
# Only vectors 0 and 14 are ever fired by a boot test, so a duplicated or
# transposed .quad in boot/interrupts.S boots perfectly green and mis-routes an
# exception nobody has raised yet.  The table is read back out of the linked
# image and compared against the symbols it names.  python3, not awk: these
# addresses exceed the 53 bits awk keeps exactly.
if out=$(python3 - "$K" 2>&1 <<'PY'
import subprocess, sys

elf = sys.argv[1]
hexd = "0123456789abcdef"

syms = {}
for line in subprocess.run(["nm", elf], capture_output=True, text=True).stdout.splitlines():
    f = line.split()
    if len(f) == 3:
        syms.setdefault(f[2], int(f[0], 16))
if "isr_stub_table" not in syms:
    sys.exit("isr_stub_table is not in the linked image")

mem = {}
dump = subprocess.run(["objdump", "-s", "-j", ".rodata", elf],
                      capture_output=True, text=True).stdout
for line in dump.splitlines():
    f = line.split()
    if len(f) < 2 or not all(c in hexd for c in f[0]):
        continue
    a = int(f[0], 16)
    for i, w in enumerate(f[1:5]):
        if len(w) == 8 and all(c in hexd for c in w):
            for j in range(4):
                mem[a + 4 * i + j] = int(w[2 * j:2 * j + 2], 16)

base = syms["isr_stub_table"]
for v in range(32):
    want = syms.get("isr%d" % v)
    if want is None:
        sys.exit("isr%d is not in the linked image" % v)
    try:
        got = sum(mem[base + 8 * v + k] << (8 * k) for k in range(8))
    except KeyError:
        sys.exit("entry %d lies outside the .rodata dump" % v)
    if got != want:
        sys.exit("entry %d is 0x%016x, but isr%d is at 0x%016x" % (v, got, v, want))
print("32 entries, each pointing at the stub its index names")
PY
); then ok "isr_stub_table: $out"; else bad "isr_stub_table: $out"; fi

echo "=== fk_inb defines the whole of EAX before it reads the port (2.1) ==="
# 'inb %dx, %al' writes AL and leaves EAX bits 31:8 as it found them, so fk_inb
# must define them itself; no black-box test in this tree can observe the bits.
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
# Catches a missing -z max-page-size, which pads each of the three PT_LOADs to
# 2 MiB.  Image is 25600 bytes today, 25248 without io.S and the serial driver.
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
