! SPDX-License-Identifier: GPL-2.0-only
!
! Derived from Linux 7.1.8 lib/math/lcm.c
! Original C authors retain copyright; this is a translation, not new work.
!> Fortran translation of linux-7.1.8 lib/math/lcm.c :: lcm_not_zero()
!!
!! Original C:
!!     unsigned long lcm_not_zero(unsigned long a, unsigned long b)
!!     {
!!             unsigned long l = lcm(a, b);
!!             if (l)
!!                     return l;
!!             return (b ? : a);
!!     }
!!
!! lcm_not_zero() is a leaf of a three-function call chain that all has to be
!! reproduced here, because the object may not call out to C:
!!     lcm_not_zero -> lcm (lib/math/lcm.c) -> gcd (lib/math/gcd.c, binary_gcd)
!!
!! ---------------------------------------------------------------------------
!! UNSIGNED-SAFETY NOTES (every hazard this file had to handle)
!! ---------------------------------------------------------------------------
!! * `unsigned long` is 64-bit on the LP64 target, so the bit pattern is carried
!!   in integer(c_long).  Fortran has no unsigned type; every operation below is
!!   one whose two's-complement semantics are bit-identical to the C unsigned
!!   one.
!!
!! * THE DIVIDE.  lcm() computes `(a / gcd(a, b)) * b` on unsigned long.  A
!!   Fortran `/` is a SIGNED divide and is flatly wrong the moment the dividend
!!   has bit 63 set (e.g. 0x8000000000000000 / 2 would give 0xC000000000000000
!!   instead of 0x4000000000000000).  So fk_udiv64() below implements a genuine
!!   unsigned 64-bit restoring long division:
!!     - n < d (unsigned, via BLT)            -> quotient 0, early out;
!!     - d with bit 63 set and n >= d         -> quotient is exactly 1, because
!!       d >= 2**63 forces n < 2*d.  This case is peeled off first so that the
!!       main loop only ever sees d <= 2**63-1, which is what keeps the running
!!       remainder from overflowing: the invariant rem < d gives
!!       2*rem + 1 <= 2*d - 1 <= 2**64 - 3, i.e. it always still fits in 64 bits.
!!     - the loop itself uses BTEST to pull bit i of the dividend, BGE for the
!!       UNSIGNED `rem >= d` test, and IBSET to place quotient bit i (IBSET at
!!       position 63 sets the sign bit -- that is the intended bit pattern, not
!!       an overflow).
!!   The subtraction `rem - d` wraps identically in two's complement, and the
!!   build passes -fwrapv so the wrap is defined rather than UB.
!!
!! * `>> ` on unsigned long -> SHIFTR (zero fill).  SHIFTA would smear the sign
!!   bit and, in binary_gcd's `a >>= __ffs(a)` normalisation, would spin forever
!!   on an all-ones value.
!!
!! * `<` between unsigned longs (binary_gcd's `if (a < b) swap(a, b)`) -> BLT.
!!   A signed `<` mis-orders any operand with bit 63 set, which would make the
!!   subtractive loop underflow and diverge.
!!
!! * `__ffs(word)` (index of the least-significant set bit, undefined for 0)
!!   -> TRAILZ.  Every call site here is guarded so the operand is non-zero.
!!
!! * `r & -r` (isolate the lowest set bit) is written as SHIFTL(1, TRAILZ(r))
!!   rather than IAND(r, -r): identical result for r /= 0, but it avoids negating
!!   INT64_MIN, which is a signed overflow that only -fwrapv rescues.
!!
!! * `(a / gcd) * b` multiplication wraps modulo 2**64; two's-complement signed
!!   multiplication has the identical bit pattern, so nothing special is needed.
!!
!! * The GNU "elvis" operator `(b ? : a)` is just `b != 0 ? b : a` -- b is
!!   evaluated once and reused, which is trivially true of a value here.
!!
!! * No arrays are indexed in this translation, so the 0-based-table hazard does
!!   not arise.  Bit positions are used directly as 0..63 shift counts, which is
!!   already the C convention.
!!
!! * Reachability note: lcm(a,b) can only be 0 when a or b is 0.  Writing
!!   a = 2**i*u and b = 2**j*v with u, v odd gives (a/gcd)*b = 2**max(i,j) *
!!   lcm(u,v) with lcm(u,v) odd, so the 2-adic valuation of the product is
!!   max(i,j) <= 63 < 64 and it can never wrap to exactly zero.  The `(b ? : a)`
!!   fallback is therefore reached exactly on the a==0 / b==0 inputs.  The code
!!   still follows the C structure literally rather than relying on that.
module fk_lcm_not_zero_m
  use iso_c_binding, only: c_long
  implicit none
  private
  public :: fk_lcm_not_zero

  integer, parameter :: ul = c_long          !< bit container for unsigned long
  integer(ul), parameter :: UL_ZERO = 0_ul
  integer(ul), parameter :: UL_ONE  = 1_ul

contains

  !> Unsigned 64-bit division: quotient of the bit patterns n / d.
  !! Precondition: d /= 0 (guaranteed by the single call site, where gcd of two
  !! non-zero values is >= 1).
  pure function fk_udiv64(n, d) result(q)
    implicit none
    integer(ul), intent(in) :: n, d
    integer(ul)             :: q, rem
    integer                 :: i

    q = UL_ZERO

    ! Unsigned compare -- BLT, never `<`.
    if (blt(n, d)) return

    ! d >= 2**63 and n >= d  =>  n < 2*d  =>  quotient is exactly 1.
    ! Peeling this off also guarantees d <= 2**63-1 below, which is what makes
    ! the running remainder safe from overflow.
    if (btest(d, 63)) then
       q = UL_ONE
       return
    end if

    rem = UL_ZERO
    do i = 63, 0, -1
       rem = shiftl(rem, 1)                       ! zero-fill, no sign smear
       if (btest(n, i)) rem = ior(rem, UL_ONE)
       if (bge(rem, d)) then                      ! UNSIGNED >=
          rem = rem - d                           ! wraps identically
          q   = ibset(q, i)                       ! i == 63 sets the sign bit
       end if
    end do
  end function fk_udiv64

  !> lib/math/gcd.c :: binary_gcd() -- the CONFIG_CPU_NO_EFFICIENT_FFS=n path,
  !! which is the one the static key selects by default.
  !! Precondition: a /= 0 .and. b /= 0.
  pure function fk_binary_gcd(a_in, b_in) result(g)
    implicit none
    integer(ul), intent(in) :: a_in, b_in
    integer(ul)             :: g, a, b, r, t

    a = a_in
    b = b_in
    r = ior(a, b)                                 ! r /= 0

    b = shiftr(b, trailz(b))                      ! b >>= __ffs(b)
    if (b == UL_ONE) then
       g = shiftl(UL_ONE, trailz(r))              ! return r & -r
       return
    end if

    do
       a = shiftr(a, trailz(a))                   ! a >>= __ffs(a)
       if (a == UL_ONE) then
          g = shiftl(UL_ONE, trailz(r))           ! return r & -r
          return
       end if
       if (a == b) then
          g = shiftl(a, trailz(r))                ! return a << __ffs(r)
          return
       end if
       if (blt(a, b)) then                        ! UNSIGNED <
          t = a
          a = b
          b = t
       end if
       a = a - b                                  ! a > b here, so a - b /= 0
    end do
  end function fk_binary_gcd

  !> lib/math/gcd.c :: gcd()
  pure function fk_gcd(a, b) result(g)
    implicit none
    integer(ul), intent(in) :: a, b
    integer(ul)             :: g, r

    r = ior(a, b)
    if (a == UL_ZERO .or. b == UL_ZERO) then
       g = r
       return
    end if
    g = fk_binary_gcd(a, b)
  end function fk_gcd

  !> lib/math/lcm.c :: lcm()
  pure function fk_lcm(a, b) result(l)
    implicit none
    integer(ul), intent(in) :: a, b
    integer(ul)             :: l

    if (a /= UL_ZERO .and. b /= UL_ZERO) then
       l = fk_udiv64(a, fk_gcd(a, b)) * b         ! unsigned divide, wrapping mul
    else
       l = UL_ZERO
    end if
  end function fk_lcm

  !> lib/math/lcm.c :: lcm_not_zero()
  function fk_lcm_not_zero(a, b) result(res) bind(c, name="fk_lcm_not_zero")
    implicit none
    integer(c_long), intent(in), value :: a, b
    integer(c_long)                    :: res
    integer(c_long)                    :: l

    l = fk_lcm(a, b)
    if (l /= UL_ZERO) then
       res = l
       return
    end if

    if (b /= UL_ZERO) then                        ! the GNU elvis (b ? : a)
       res = b
    else
       res = a
    end if
  end function fk_lcm_not_zero

end module fk_lcm_not_zero_m
