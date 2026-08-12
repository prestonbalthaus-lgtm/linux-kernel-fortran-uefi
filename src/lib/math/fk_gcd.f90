! SPDX-License-Identifier: GPL-2.0-only
!
! Derived from Linux 7.1.8 lib/math/gcd.c
! Original C authors retain copyright; this is a translation, not new work.
!> Fortran translation of linux-7.1.8 lib/math/gcd.c
!!
!! Original C signature:  unsigned long gcd(unsigned long a, unsigned long b)
!!
!! WHICH PATH IS TRANSLATED
!!   gcd.c has two implementations. The oracle build (x86-64, no
!!   CONFIG_CPU_NO_EFFICIENT_FFS, static key efficient_ffs_key TRUE so
!!   static_branch_likely() is taken) executes the gcd() prologue followed by
!!   binary_gcd(). That is the code path mirrored here, inlined into one
!!   procedure. The even/odd fallback below the static branch is not compiled
!!   in the oracle, so it is deliberately not translated -- untested dead code
!!   is worse than none. binary_gcd() recomputes r = a|b from the same a and b
!!   the caller already OR-ed, so the single `r` here is exactly both r's.
!!
!! UNSIGNED-SAFETY NOTES (project Global Constraints)
!!   * unsigned long is 64-bit on the LP64 target (BITS_PER_LONG == 64), so the
!!     BIT PATTERN is carried in integer(c_int64_t). Fortran has no unsigned
!!     types; every operation below is one whose semantics are bit-identical to
!!     the C unsigned operation.
!!   * __ffs(x) -> TRAILZ(x). Both count trailing zero bits. __ffs is UNDEFINED
!!     for 0 in the kernel; TRAILZ(0) would return 64 and SHIFTR by 64 is
!!     illegal, so every call site must have a nonzero argument -- and does:
!!       - b at `b >>= __ffs(b)`: the `if (!a || !b)` prologue already returned.
!!       - a at `a >>= __ffs(a)`: nonzero on entry; on later iterations a was
!!         replaced by a-b where a > b strictly (a /= b was checked, and the
!!         swap makes a the larger), so a-b > 0.
!!       - r at `a << __ffs(r)`: r = a|b with both operands nonzero.
!!     Consequently every shift count is TRAILZ of a nonzero 64-bit value, i.e.
!!     in 0..63, which is a legal Fortran shift count.
!!   * `>>` on unsigned -> SHIFTR (zero fill). SHIFTA would be wrong: for
!!     b = 0x8000000000000000, __ffs(b) = 63 and b >>= 63 must give 1, whereas
!!     a sign-propagating shift gives -1 and the loop would misbehave.
!!   * `<<` on unsigned -> SHIFTL (bits shifted out are discarded, same as the
!!     C mod-2**64 result).
!!   * `a < b` on unsigned -> BLT (bitwise/unsigned compare). A signed `<` is
!!     the silent-failure trap here: both operands are odd at that point and
!!     odd values with bit 63 set (e.g. 0x8000000000000001) are reachable, so a
!!     signed compare would swap in exactly the wrong direction.
!!   * `r & -r` (isolate lowest set bit) -> IAND(r, -r). Negating the bit
!!     pattern 0x8000000000000000 overflows the signed range; the build passes
!!     -fwrapv so the two's-complement wrap is defined and the bit pattern is
!!     the same one C computes. The test drives gcd(2**63, 2**63) explicitly to
!!     prove it rather than assert it.
!!   * `a -= b` is a two's-complement subtraction: identical bit pattern
!!     signed or unsigned (and a > b here, so it does not even wrap).
!!   * No array indexing in this routine, so no 0-based/1-based hazard.
module fk_gcd_m
  use, intrinsic :: iso_c_binding, only: c_int64_t
  implicit none
  private
  public :: fk_gcd

contains

  !> Greatest common divisor of two u64 bit patterns (binary/Stein GCD).
  function fk_gcd(a_val, b_val) result(res) bind(c, name="fk_gcd")
    implicit none
    integer(c_int64_t), intent(in), value :: a_val
    integer(c_int64_t), intent(in), value :: b_val
    integer(c_int64_t)                    :: res
    integer(c_int64_t)                    :: a, b, r, tmp

    a = a_val
    b = b_val
    r = ior(a, b)                                  ! unsigned long r = a | b;

    if (a == 0_c_int64_t .or. b == 0_c_int64_t) then   ! if (!a || !b)
       res = r                                     !         return r;
       return
    end if

    ! ---- binary_gcd(a, b), reached via static_branch_likely() ----
    b = shiftr(b, trailz(b))                       ! b >>= __ffs(b);
    if (b == 1_c_int64_t) then                     ! if (b == 1)
       res = iand(r, -r)                           !         return r & -r;
       return
    end if

    do                                             ! for (;;) {
       a = shiftr(a, trailz(a))                    !   a >>= __ffs(a);
       if (a == 1_c_int64_t) then                  !   if (a == 1)
          res = iand(r, -r)                        !           return r & -r;
          return
       end if
       if (a == b) then                            !   if (a == b)
          res = shiftl(a, trailz(r))               !           return a << __ffs(r);
          return
       end if

       if (blt(a, b)) then                         !   if (a < b)
          tmp = a                                  !           swap(a, b);
          a   = b
          b   = tmp
       end if
       a = a - b                                   !   a -= b;
    end do                                         ! }
  end function fk_gcd

end module fk_gcd_m
