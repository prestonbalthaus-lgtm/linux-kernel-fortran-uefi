! SPDX-License-Identifier: GPL-2.0
!
! Derived from Linux 7.1.8 lib/math/int_sqrt.c
! Original C authors retain copyright; this is a translation, not new work.
!> Fortran translation of linux-7.1.8 lib/math/int_sqrt.c
!!
!! Original C signature:  unsigned long int_sqrt(unsigned long x)
!! Computes floor(sqrt(x)) by Guy L. Steele's shift-and-subtract algorithm.
!!
!! UNSIGNED-SAFETY NOTES (Fortran has no unsigned types -- the BIT PATTERN of
!! the u64 is carried in integer(c_int64_t) and every operation below is one
!! whose semantics are bit-identical to the unsigned C operation):
!!   * `x <= 1` compares UNSIGNED longs. A signed `<=` would be true for every
!!     high-bit-set x (they look negative) and the function would wrongly
!!     return x itself for half the input domain. Uses BLE (bitwise <=).
!!   * `x >= b` compares UNSIGNED longs -- x still holds the full 64-bit
!!     remainder and can have its high bit set. Uses BGE (bitwise >=).
!!     This is the comparison that drives every bit of the result, so a signed
!!     `>=` here corrupts the answer for all x >= 2**63.
!!   * `y >>= 1` and `m >>= 2` are LOGICAL shifts on unsigned longs -> SHIFTR
!!     (zero fill), never SHIFTA. (Here m <= 2**62 and y < 2**32 so no sign bit
!!     is ever shifted, but SHIFTR is what the C semantics actually specify.)
!!   * `x -= b` and `y += m` wrap modulo 2**64; two's-complement signed
!!     add/sub has the identical bit pattern. Built with -fwrapv so the wrap
!!     is defined behaviour rather than UB.
!!   * `__fls(x)` (index of the most significant set bit, undefined for x==0)
!!     == 63 - LEADZ(x) at BITS_PER_LONG==64. No shim is needed on the Fortran
!!     side. LEADZ counts the leading zeros of the BIT PATTERN, so it is
!!     already the unsigned-correct answer for negative-looking values.
!!   * `__fls(x) & ~1UL` rounds the shift count down to an even number. The
!!     `x <= 1` early return guarantees x >= 2 here, hence LEADZ(x) <= 62 and
!!     the shift count lies in [0,62] -- SHIFTL is therefore always in range
!!     and m never sets the sign bit. That dependency is load-bearing: without
!!     the early return, x==0 would give a shift count of 63-64 = -1.
!!   * No array lookup tables, so no 0-based/1-based indexing hazard.
!!
!! `unsigned long` is 64-bit on the LP64 targets this project builds for, so
!! BITS_PER_LONG == 64 and the int_sqrt64 variant in the C file is compiled
!! out; it is deliberately not translated here.
module fk_int_sqrt_m
  use, intrinsic :: iso_c_binding, only: c_int64_t
  implicit none
  private
  public :: fk_int_sqrt

contains

  !> Computes floor(sqrt(x)) for the unsigned 64-bit value held in x.
  function fk_int_sqrt(x) result(y) bind(c, name="fk_int_sqrt")
    implicit none
    integer(c_int64_t), intent(in), value :: x
    integer(c_int64_t)                    :: y
    integer(c_int64_t)                    :: b, m, v
    integer                               :: sh

    v = x
    y = 0_c_int64_t

    ! if (x <= 1) return x;   -- UNSIGNED compare
    if (ble(v, 1_c_int64_t)) then
       y = v
       return
    end if

    ! m = 1UL << (__fls(x) & ~1UL);
    sh = iand(63 - leadz(v), not(1))
    m  = shiftl(1_c_int64_t, sh)

    do while (m /= 0_c_int64_t)
       b = y + m
       y = shiftr(y, 1)

       if (bge(v, b)) then          ! if (x >= b)  -- UNSIGNED compare
          v = v - b
          y = y + m
       end if

       m = shiftr(m, 2)
    end do
  end function fk_int_sqrt

end module fk_int_sqrt_m
