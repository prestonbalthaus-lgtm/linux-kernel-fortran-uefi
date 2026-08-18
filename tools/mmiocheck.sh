#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Refuses a kernel object that reaches a device register with anything other
# than a whole 32-bit access.
#
# THE DEFECT THIS EXISTS FOR, found the expensive way.  fk_lapic_m and
# fk_ioapic_m used to read their registers through a VOLATILE Fortran pointer.
# lapic_max_lvt is ibits(reg_read(base, REG_VERSION), 16, 8), and gfortran -O2
# proved only one byte of that load is ever used and emitted
#
#     movzbl 0x2(%rax),%eax
#
# a ONE-BYTE read of a device register, through a pointer declared VOLATILE.
# Fortran's VOLATILE forbids eliminating and reordering an access.  It does not
# forbid NARROWING one, and neither does C's.
#
# Both parts this kernel talks to forbid it.  The SDM requires every local APIC
# register to be accessed with a naturally aligned 4-byte load or store (Vol.3
# 11.4.1).  The I/O APIC's IOWIN is a single 32-bit window and the 82093AA
# datasheet defines no sub-dword behaviour for it -- QEMU answers a one-byte
# read of IOWIN+2 with ZERO, which is how this was caught: ioapic_max_redir
# reported 1 entry instead of 24 and every route was refused. The LAPIC's own
# narrowed read happened to return the right byte on QEMU, so it had been
# passing every gate in the tree since roadmap 3.3 landed.
#
# The fix is fk_readl/fk_writel in boot/io.S: a call the compiler cannot see
# through can be neither narrowed nor reordered against the next one.  This
# gate is what keeps it that way, because the bad form compiles, links, and
# boots.
#
# Usage:
#   tools/mmiocheck.sh [obj...]   default: the MMIO modules under build/boot
#   tools/mmiocheck.sh --selftest prove the check refuses the narrowed form
set -uo pipefail
cd "$(dirname "$0")/.."

OBJDUMP="${OBJDUMP:-objdump}"

# A sub-dword move whose operand list contains a memory reference.  The
# register-to-register forms -- movzbl %al,%eax, which is how a c_int8_t
# becomes a c_int32_t -- touch no device and are not what this is about, so the
# parenthesis is load-bearing: it is what makes an operand an address.
# [(] rather than \( on purpose: the pattern is handed to awk through -v, so a
# backslash would be eaten as a string escape before the regex engine ever saw
# it -- and awk's answer to the resulting unmatched paren is to die with the
# scan half done, which the caller reads as a clean object.
BAD_RE='^[[:space:]]*[0-9a-f]+:[[:space:]]+(movz[bw][lq]?|mov[bw])[[:space:]]+[^#]*[(]'

scan_one() {
	local obj="$1" hits fn
	[ -r "$obj" ] || { echo "  MISSING  $obj"; return 1; }
	hits=$("$OBJDUMP" -d --no-show-raw-insn "$obj" \
	       | awk -v re="$BAD_RE" '
	           /^[0-9a-f]+ <.*>:$/ { fn = $2; next }
	           $0 ~ re             { print "    " fn "  " $0 }')
	# A scanner that died half way through prints nothing and would
	# otherwise read as a clean object.
	if [ ${PIPESTATUS[1]:-0} -ne 0 ]; then
		echo "  REFUSED  $obj -- the scanner itself failed"
		return 1
	fi
	if [ -n "$hits" ]; then
		echo "  REFUSED  $obj -- sub-dword access to a device register"
		printf '%s\n' "$hits"
		return 1
	fi
	printf "  %-28s every device access is a whole dword\n" "OK  $(basename "$obj")"
	return 0
}

if [ "${1:-}" = "--selftest" ]; then
	# The gate has to be shown refusing something, or a green run says
	# nothing about the run where it passes.  Both halves are built here
	# rather than described: the narrowed form is what the compiler ACTUALLY
	# emits for it, not what this script assumes it emits.
	command -v gfortran >/dev/null || {
		echo "  SKIP  no gfortran; run this inside the dev container"; exit 0; }
	t=$(mktemp -d) || exit 1
	trap 'rm -rf "$t"' EXIT
	pass=0; fail=0

	cat > "$t/bad.f90" <<'FSRC'
module bad_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t, c_ptr, c_f_pointer
  implicit none
  private
  public :: bad_field
contains
  function bad_field(base) result(v) bind(c, name="bad_field")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t) :: v
    integer(c_int32_t), volatile, pointer :: r
    type(c_ptr) :: p
    p = transfer(base, p)
    call c_f_pointer(p, r)
    v = ibits(r, 16, 8)
  end function bad_field
end module bad_m
FSRC
	cat > "$t/good.f90" <<'FSRC'
module good_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t
  implicit none
  private
  public :: good_field
  interface
    function fk_readl(addr) result(v) bind(c, name="fk_readl")
      import :: c_int32_t, c_int64_t
      implicit none
      integer(c_int64_t), intent(in), value :: addr
      integer(c_int32_t)                    :: v
    end function fk_readl
  end interface
contains
  function good_field(base) result(v) bind(c, name="good_field")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t) :: v
    v = ibits(fk_readl(base), 16, 8)
  end function good_field
end module good_m
FSRC

	gfortran -O2 -J"$t" -c -o "$t/bad.o"  "$t/bad.f90"  2>/dev/null
	gfortran -O2 -J"$t" -c -o "$t/good.o" "$t/good.f90" 2>/dev/null

	echo "=== mmiocheck self-test (the volatile-pointer form, as compiled) ==="
	if scan_one "$t/bad.o" >/dev/null 2>&1; then
		echo "  FAIL  a VOLATILE pointer feeding ibits() was ACCEPTED"
		echo "        (gfortran did not narrow it here -- the gate is"
		echo "         still correct, but this build cannot prove it)"
		"$OBJDUMP" -d --no-show-raw-insn "$t/bad.o" | sed 's/^/        /' \
			| grep -E 'mov' | head -4
		fail=$((fail + 1))
	else
		echo "  PASS  the narrowed volatile-pointer read is refused"
		pass=$((pass + 1))
	fi
	if scan_one "$t/good.o" >/dev/null 2>&1; then
		echo "  PASS  the same field taken through fk_readl is accepted"
		pass=$((pass + 1))
	else
		echo "  FAIL  the fk_readl form was refused"
		fail=$((fail + 1))
	fi
	echo "=== $pass passed, $fail failed ==="
	exit $((fail > 0))
fi

OBJS=("$@")
if [ ${#OBJS[@]} -eq 0 ]; then
	OBJS=(build/boot/fk_lapic.o build/boot/fk_ioapic.o)
fi

rc=0
echo "=== device-register access widths ==="
for o in "${OBJS[@]}"; do
	scan_one "$o" || rc=1
done
if [ $rc -eq 0 ]; then
	echo "=== every device register is reached a whole dword at a time ==="
else
	echo "=== SUB-DWORD DEVICE ACCESS ABOVE -- use fk_readl/fk_writel ==="
fi
exit $rc
