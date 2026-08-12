! SPDX-License-Identifier: GPL-2.0-only
!
! Derived from Linux 7.1.8 lib/math/lcm.c
! Original C authors retain copyright; this is a translation, not new work.
!> Fortran translation of linux-7.1.8 lib/math/lcm.c
!!
!! Original C:
!!     unsigned long lcm(unsigned long a, unsigned long b)
!!     {
!!             if (a && b)
!!                     return (a / gcd(a, b)) * b;
!!             else
!!                     return 0;
!!     }
!!
!! UNSIGNED-SAFETY NOTES
!! ---------------------
!!   * `unsigned long` is 64-bit on the LP64 targets this project builds for, so
!!     it is carried as integer(c_int64_t). Fortran has no unsigned types: the
!!     BIT PATTERN lives in a signed integer and every operation below is one
!!     whose semantics are bit-identical to the unsigned C operation.
!!
!!   * THE DIVIDE. `a / gcd(a, b)` is a u64/u64 division and `a` routinely
!!     exceeds INT64_MAX (any input with bit 63 set). A signed Fortran `/`
!!     would treat such an `a` as negative and produce garbage, e.g.
!!     0x8000000000000000 / 2 would give -2^62 instead of 2^62. So the divide
!!     is done by u64_div() below: a restoring shift/subtract long division
!!     that uses only bitwise comparison (BGE) and wrapping subtraction, and is
!!     therefore exact for the full 0 .. 2^64-1 range. It carries the 65th bit
!!     of the shifted partial remainder explicitly (`carry`), because r < d can
!!     still make 2*r overflow 64 bits when d > 2^63.
!!     Note the divide happens to be exact here (gcd(a,b) always divides a),
!!     but u64_div is written for the general case rather than relying on that.
!!
!!   * THE GCD. The build template compiles exactly one .f90 per test, so an
!!     external fk_gcd cannot be linked in; the kernel's binary-GCD loop is
!!     duplicated here as the private procedure fk_gcd_u64. Inside it:
!!       - `x >>= __ffs(x)` -> SHIFTR(x, TRAILZ(x)). SHIFTR is zero-fill, which
!!         is what C's >> on an unsigned does. SHIFTA would smear the sign bit
!!         and never terminate for a high-bit-set operand.
!!       - `a < b` -> BLT(a, b). A signed `<` would rank every high-bit-set
!!         value below every other value and pick the wrong swap direction.
!!       - `r & -r` (isolate lowest set bit) -> IBSET(0, TRAILZ(r)). Written
!!         this way rather than IAND(r, -r) because negating INT64_MIN is an
!!         overflow in Fortran; r /= 0 is guaranteed at both use sites.
!!       - `a << __ffs(r)` -> SHIFTL, shift count is TRAILZ(r) <= 63 < 64.
!!       - `a -= b` wraps modulo 2^64; two's-complement subtraction has the
!!         identical bit pattern (and -fwrapv makes the wrap defined).
!!
!!   * THE MULTIPLY. `(...) * b` wraps modulo 2^64 for large operands; signed
!!     two's-complement multiplication has the identical low-64-bit pattern.
!!
!!   * ARRAY INDEXING: none -- this translation uses no lookup tables.
module fk_lcm_m
  use, intrinsic :: iso_c_binding, only: c_int64_t
  implicit none
  private
  public :: fk_lcm

contains

  !> Lowest common multiple, u64 semantics. Mirrors lib/math/lcm.c exactly.
  function fk_lcm(a, b) result(res) bind(c, name="fk_lcm")
    implicit none
    integer(c_int64_t), intent(in), value :: a, b
    integer(c_int64_t)                    :: res
    integer(c_int64_t)                    :: g

    if (a /= 0_c_int64_t .and. b /= 0_c_int64_t) then
       g   = fk_gcd_u64(a, b)
       res = u64_div(a, g) * b
    else
       res = 0_c_int64_t
    end if
  end function fk_lcm

  !> Greatest common divisor, u64 semantics. Private duplicate of the binary
  !! (Stein) GCD in lib/math/gcd.c -- see the header note on why it cannot be
  !! an external call.
  pure function fk_gcd_u64(a_in, b_in) result(g)
    implicit none
    integer(c_int64_t), intent(in) :: a_in, b_in
    integer(c_int64_t)             :: g
    integer(c_int64_t)             :: a, b, r, t

    r = ior(a_in, b_in)

    ! gcd(): if (!a || !b) return a | b;
    if (a_in == 0_c_int64_t .or. b_in == 0_c_int64_t) then
       g = r
       return
    end if

    ! binary_gcd(a, b) from here on.
    a = a_in
    b = b_in

    b = shiftr(b, trailz(b))                 ! b >>= __ffs(b)
    if (b == 1_c_int64_t) then
       g = ibset(0_c_int64_t, trailz(r))     ! return r & -r
       return
    end if

    do
       a = shiftr(a, trailz(a))              ! a >>= __ffs(a)
       if (a == 1_c_int64_t) then
          g = ibset(0_c_int64_t, trailz(r))  ! return r & -r
          return
       end if
       if (a == b) then
          g = shiftl(a, trailz(r))           ! return a << __ffs(r)
          return
       end if
       if (blt(a, b)) then                   ! unsigned compare, then swap
          t = a
          a = b
          b = t
       end if
       a = a - b                             ! a > b here, so a stays /= 0
    end do
  end function fk_gcd_u64

  !> Truncating unsigned 64-bit division, n / d, exact over the whole
  !! 0 .. 2^64-1 range. Caller guarantees d /= 0 (C's u64 divide by zero is
  !! undefined too, so nothing is lost).
  pure function u64_div(n, d) result(q)
    implicit none
    integer(c_int64_t), intent(in) :: n, d
    integer(c_int64_t)             :: q
    integer(c_int64_t)             :: r
    integer                        :: i
    logical                        :: carry

    q = 0_c_int64_t
    r = 0_c_int64_t

    do i = 63, 0, -1
       ! Shift the next bit of n into the partial remainder. r < d always
       ! holds, but 2*r can still need 65 bits when d > 2^63, so remember the
       ! bit that is about to fall off the top.
       carry = btest(r, 63)
       r = ior(shiftl(r, 1), iand(shiftr(n, i), 1_c_int64_t))
       if (carry .or. bge(r, d)) then
          r = r - d                          ! wraps back into range when carry
          q = ibset(q, i)
       end if
    end do
  end function u64_div

end module fk_lcm_m
