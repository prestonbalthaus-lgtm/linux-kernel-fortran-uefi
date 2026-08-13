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
echo "=== the TSS and its emergency stack (roadmap 3.2.5) ==="
# nm -S: <addr> <size> <type> <name>.
symsize() { nm -S "$K" | awk -v s="$1" '$4==s{print "0x"$2}'; }

# THE CHECK THIS SECTION EXISTS FOR.  A 64-bit TSS puts RSP0 at offset 4, and a
# bind(c) derived type follows C struct rules: a c_int64_t declared there is
# aligned up to offset 8, which moves IST1 from 0x24 to 0x28 and every field
# after it.  Nothing complains -- the type compiles, the descriptor loads, and
# the CPU then reads the #DF stack pointer out of the wrong eight bytes.  The
# structure is spelled in 32-bit halves for exactly this reason, and 104 bytes
# is how that decision is held in place.
tsz=$(( $(symsize fk_tss) ))
if [ "$tsz" -eq 104 ]; then
  ok "fk_tss is 104 bytes -- the architectural TSS, with no padding in it"
else
  bad "fk_tss is $tsz bytes, not 104: a field has been aligned up, so IST1 is"
  bad "     no longer at offset 0x24 and the CPU will load a #DF stack pointer"
  bad "     out of whichever eight bytes landed there instead"
fi

dsz=$(( $(symsize fk_df_stack) ))
if [ "$dsz" -ge 4096 ]; then ok "fk_df_stack is $dsz bytes"
else bad "fk_df_stack is $dsz bytes -- too small to take a panic dump"; fi

bs=$(sym __bss_start); be=$(sym __bss_end)
for v in fk_tss fk_df_stack; do
  a=$(sym $v)
  if [ -z "$a" ]; then bad "$v is not in the linked image"
  elif [ $(( a >= bs && a < be )) -eq 1 ]; then
    ok "$v is inside .bss, so boot.S zeroes it and it costs no image bytes"
  else
    bad "$v at $a is OUTSIDE .bss [$bs,$be): it is not zeroed before use"
  fi
done

# The whole point of IST1 is that it is NOT the stack that just failed.
#
# HONEST LABEL: this one is an INVARIANT, not a test. linker.ld emits
# *(.bss .bss.*) and *(COMMON) and only then reserves the boot stack inline,
# with no symbol inside the reservation, so no Fortran object can land there
# and no layout the current script can produce makes this fail. It is kept
# because the day the boot stack becomes an ordinary .bss array -- which is
# how most kernels end up spelling it -- it starts to bite. The property it
# does NOT cover is reported below it.
sb=$(sym __boot_stack_bottom); st=$(sym __boot_stack_top)
ds=$(sym fk_df_stack); de=$(( ds + dsz ))
if [ $(( ds >= st || de <= sb )) -eq 1 ]; then
  ok "the #DF stack [$ds,0x$(printf %x $de)) is disjoint from the boot stack"
else
  bad "the #DF stack OVERLAPS the boot stack -- the emergency stack would be"
  bad "     the same memory as the one whose corruption caused the #DF"
fi

echo
echo "=== roadmap 3.5: the guard page below the boot stack ==="
# What this block used to print as a NOTE is now a property. Until 3.5 the boot
# stack grew DOWN out of __boot_stack_bottom into whatever .bss happened to put
# underneath it -- first the TSS, then the PMM's bitmap with ZERO bytes of
# slack -- and which object that was could only be reported, never asserted,
# because link order decided it rather than anybody. linker.ld now reserves a
# page for the fall to land in, and the VMM leaves it unmapped.
#
# The ASSERTs inside linker.ld already fail the LINK on alignment and size, so
# what is left for this gate is the thing a linker script cannot see: that the
# guard frame is EMPTY. A .bss object sharing that frame would be unmapped
# along with the guard, and the fault would land on the object rather than on
# the overflow.
gp=$(sym __boot_stack_guard); sb=$(sym __boot_stack_bottom)
if [ -z "$gp" ]; then
  bad "__boot_stack_guard missing: linker.ld reserves no guard page"
else
  ok "__boot_stack_guard exported = $gp"
  if [ $(( (gp & 0xfff) == 0 )) -eq 1 ]; then
    ok "the guard page is 4 KiB aligned, so it is a page frame of its own"
  else
    bad "the guard page is not 4 KiB aligned and cannot be unmapped by itself"
  fi
  if [ $(( sb - gp == 4096 )) -eq 1 ]; then
    ok "the guard page is exactly the 4096 bytes below __boot_stack_bottom"
  else
    bad "__boot_stack_bottom is $(( sb - gp )) bytes above the guard, not 4096"
  fi
fi
if python3 - "$K" <<'GUARDPY'
import subprocess, sys
gp = None
syms = []
for line in subprocess.run(["nm", "-S", "-n", sys.argv[1]],
                           capture_output=True, text=True).stdout.splitlines():
    f = line.split()
    if len(f) == 3 and f[2] == "__boot_stack_guard":
        gp = int(f[0], 16)
    elif len(f) == 4 and f[2] in "Bb":
        syms.append((int(f[0], 16), int(f[1], 16), f[3]))
if gp is None:
    print("__boot_stack_guard not found"); sys.exit(1)
clash = [(a, n, nm) for a, n, nm in syms if a < gp + 4096 and a + n > gp]
for a, n, nm in clash:
    print("%s [0x%x,0x%x) lies inside the guard frame [0x%x,0x%x)"
          % (nm, a, a + n, gp, gp + 4096))
if clash:
    sys.exit(1)
below = [x for x in syms if x[0] < gp]
if below:
    a, n, nm = max(below)
    print("no .bss object is inside the guard frame [0x%x,0x%x); below it sits %s,"
          % (gp, gp + 4096, nm))
    print("        ending 0x%x, and an overflow must now cross the guard to reach it"
          % (a + n))
else:
    print("no .bss object is inside the guard frame [0x%x,0x%x)" % (gp, gp + 4096))
GUARDPY
then
  :
else
  bad "an object shares the guard page frame (see above)"
fi

echo
echo "=== the PMM bitmap and the linker symbols it is built from (roadmap 3.4) ==="

# fk_pmm.f90 duplicates two constants boot/boot.S owns, because there is no way
# to import an assembler .set into Fortran -- the same situation KERNEL_VMA has
# been in since roadmap 1.2, and the same remedy: diff them here.
#
# FK_PMM_IDMAP_BYTES is the load-bearing one. pmm_init dereferences the
# Multiboot information structure at its PHYSICAL address, which is only legal
# inside the window boot.S identity-maps. If this constant grows past what the
# stub actually maps, the check that is supposed to refuse an unmapped MBI
# accepts it instead, and the kernel takes a page fault reading the memory map.
asm_num() { sed -n "s/^[[:space:]]*\.set[[:space:]]*$1,[[:space:]]*\([0-9xA-Fa-f]*\).*/\1/p" boot/boot.S | head -1; }
f90_num() { sed -n "s/^[[:space:]]*integer(c_int64_t), parameter :: $1[[:space:]]*=[[:space:]]*\([0-9]*\)_c_int64_t.*/\1/p" src/mm/fk_pmm.f90 | head -1; }

pd_entries=$(asm_num PD_ENTRIES)
size_2m=$(asm_num SIZE_2M)
asm_page=$(asm_num PAGE_SIZE)
pmm_idmap=$(f90_num FK_PMM_IDMAP_BYTES)
pmm_page=$(f90_num FK_PMM_PAGE_SIZE)
pmm_maxphys=$(f90_num FK_PMM_MAX_PHYS)

if [ -z "$pd_entries" ] || [ -z "$size_2m" ] || [ -z "$pmm_idmap" ]; then
  bad "cannot read PD_ENTRIES/SIZE_2M from boot.S or FK_PMM_IDMAP_BYTES from fk_pmm.f90"
else
  want_idmap=$(( pd_entries * size_2m ))
  want "the identity window fk_pmm assumes == the one boot.S builds" \
       "$want_idmap" "$pmm_idmap"
fi
want "PAGE_SIZE agrees between boot.S and fk_pmm.f90" "$asm_page" "$pmm_page"

# The bitmap is one bit per 4 KiB frame of FK_PMM_MAX_PHYS. Read the size back
# out of the LINKED image rather than trusting the arithmetic in the source: a
# mistyped exponent in either constant is invisible until the allocator walks
# off the end of the array, which in a kernel is somebody else's .bss.
if [ -n "$pmm_maxphys" ] && [ -n "$pmm_page" ]; then
  want_bytes=$(( pmm_maxphys / pmm_page / 8 ))
  got_bytes=$(( $(symsize fk_pmm_bitmap) ))
  want "fk_pmm_bitmap is one bit per frame of $pmm_maxphys bytes" \
       "$want_bytes" "$got_bytes"
fi

pb=$(sym fk_pmm_bitmap); bs=$(sym __bss_start); be=$(sym __bss_end)
if [ -z "$pb" ]; then bad "fk_pmm_bitmap is not in the linked image"
elif [ $(( pb >= bs && pb < be )) -eq 1 ]; then
  ok "fk_pmm_bitmap is inside .bss, so boot.S zeroes it and it costs no image bytes"
else
  bad "fk_pmm_bitmap at $pb is OUTSIDE .bss [$bs,$be): 2 MiB of zeros in the image,"
  bad "     and nothing clears it before pmm_init reads it"
fi

# The claim above, measured: the data segment must carry the bitmap in its
# MemSiz and not in its FileSiz.
read -r dfile dmem < <(readelf -lW "$K" \
  | awk '/^  LOAD/{f=$5; m=$6} END{printf "%d %d\n", strtonum(f), strtonum(m)}')
if [ "${dmem:-0}" -gt "${dfile:-0}" ] && [ $(( dmem - dfile )) -ge "$got_bytes" ]; then
  ok "the last PT_LOAD carries $(( dmem - dfile )) bytes of NOBITS, so the bitmap is not in the file"
else
  bad "the last PT_LOAD has FileSiz $dfile MemSiz $dmem -- the bitmap is taking file space"
fi

# boot/ksyms.S hands Fortran the value of an ABSOLUTE linker symbol as an
# immediate. Nothing else in the tree can check that the immediate is the right
# one: a wrong constant marks the wrong frames used and every verdict the PMM
# prints still says PASS.
# The pairs are PARSED OUT OF boot/ksyms.S rather than listed here: roadmap 3.5
# took that file from two accessors to seventeen, and a gate carrying its own
# copy of the list checks only the ones somebody remembered to add to it.
# Process substitution, not a pipe: `while read` on the right of a pipe runs in
# a SUBSHELL, and every bad() it called would increment a $fail that dies with
# it -- the gate would print FAIL and exit 0.
ksym_pairs=$(sed -n 's/^[[:space:]]*KSYM[[:space:]]\+\([A-Za-z0-9_]\+\),[[:space:]]*\([A-Za-z0-9_]\+\).*/\1 \2/p' boot/ksyms.S)
nksym=$(printf '%s\n' "$ksym_pairs" | grep -c .)
if [ "$nksym" -lt 2 ]; then
  bad "boot/ksyms.S declares $nksym KSYM accessors -- has the macro been renamed?"
  bad "     This gate would then silently check nothing."
else
  ok "boot/ksyms.S declares $nksym accessors, all checked below"
fi
# The NAME is the third fact, and it is what keeps this gate honest. Reading
# the (accessor, symbol) pairing out of the same file the gate is testing means
# a defect that edits the pairing moves the expectation with it -- the check
# would follow the mutation and pass. Every accessor in this tree is spelled
# fk_<X> for the linker symbol __<X>, so the expected symbol is DERIVED from the
# accessor's own name and the KSYM argument is then checked against it. A
# mutation now has to break one of two independent things to go unnoticed.
while read -r fn sy; do
  [ -n "$fn" ] || continue
  wantsym="__${fn#fk_}"
  if [ "$sy" != "$wantsym" ]; then
    bad "$fn is declared for $sy, but the naming convention makes it $wantsym"
    continue
  fi
  set -- "$fn" "$wantsym"
  imm=$(objdump -d --disassemble="$1" "$K" 2>/dev/null \
        | sed -n 's/.*movabs[[:space:]]*\$\(0x[0-9a-f]*\),%rax.*/\1/p' | head -1)
  real=$(sym "$2")
  if [ -z "$imm" ]; then
    bad "$1 does not load an immediate -- is it still a movabs of $2?"
  elif [ "$(norm_hex "$imm")" = "$(norm_hex "$real")" ]; then
    ok "$1 returns $2 = $imm"
  else
    bad "$1 returns $imm but the linker puts $2 at $real"
  fi
done < <(printf '%s\n' "$ksym_pairs")

echo
echo "=== roadmap 3.5: the TLB flush no boot can observe ==="
# vmm_drop_identity zeroes PML4[0] and then reloads CR3. The reload is
# ARCHITECTURALLY required -- a translation the CPU has cached outlives the
# table write that invalidated it -- and it is invisible to every boot gate in
# this tree. Mutation M24 removes it and the machine still takes the page fault
# the gate is looking for: by the time the deliberate read happens, the entry
# has been evicted by the console output and the page-table walk in between, so
# a kernel that never flushes behaves exactly like one that does. On this CPU,
# today, with this much work in between.
#
# So it is checked where it can be: in the instruction stream. This is the same
# situation as M20 -- a defect that leaves every console verdict printing PASS
# -- and it gets the same answer.
dis=$(objdump -d --disassemble=vmm_drop_identity "$K" 2>/dev/null)
if [ -z "$dis" ]; then
  bad "vmm_drop_identity is not in the image -- has the VMM been renamed?"
elif printf '%s' "$dis" | grep -qE '(call|jmp).*<fk_write_cr3>'; then
  # jmp as well as call: the reload is the last statement in the subroutine, so
  # gcc tail-calls it. Matching only `call` would fail on correct code.
  ok "vmm_drop_identity still reloads CR3 after zeroing PML4[0]"
else
  bad "vmm_drop_identity does NOT call fk_write_cr3: PML4[0] is zeroed but the"
  bad "     cached translation survives, and no boot gate can tell"
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
