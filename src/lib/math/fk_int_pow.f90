! SPDX-License-Identifier: GPL-2.0
!
! Derived from Linux 7.1.8 lib/math/int_pow.c
! Original C authors retain copyright; this is a translation, not new work.
!> Fortran translation of linux-7.1.8 lib/math/int_pow.c
!!
!! Original C signature:  u64 int_pow(u64 base, unsigned int exp)
!!
!! UNSIGNED-SAFETY NOTES (see docs plan, Global Constraints):
!!   * u64 -> integer(c_int64_t), u32 -> integer(c_int32_t). Fortran has no
!!     unsigned types, so the BIT PATTERN is carried in a signed integer and
!!     every operation must be one whose semantics are bit-pattern-identical
!!     to the unsigned C operation.
!!   * `exp >>= 1` on an unsigned int is a LOGICAL shift. Fortran SHIFTR is
!!     defined as zero-fill, so it matches. An arithmetic shift (SHIFTA) here
!!     would loop forever when exp has its high bit set.
!!   * `result *= base` on u64 wraps modulo 2**64. Two's-complement signed
!!     multiplication has the identical bit pattern, so this is exact --
!!     built with -fwrapv so the wrap is defined rather than UB.
module fk_int_pow_m
  use, intrinsic :: iso_c_binding, only: c_int64_t, c_int32_t
  implicit none
  private
  public :: fk_int_pow

contains

  !> Computes base**exp with u64 wrapping semantics.
  function fk_int_pow(base, exp) result(res) bind(c, name="fk_int_pow")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t), intent(in), value :: exp
    integer(c_int64_t)                    :: res
    integer(c_int64_t)                    :: b
    integer(c_int32_t)                    :: e

    res = 1_c_int64_t
    b   = base
    e   = exp

    do while (e /= 0_c_int32_t)
       if (iand(e, 1_c_int32_t) /= 0_c_int32_t) res = res * b
       e = shiftr(e, 1)          ! zero-fill: SHIFTA here would hang forever
       b = b * b                 ! wraps mod 2**64, bit-identical signed
    end do
  end function fk_int_pow

end module fk_int_pow_m
