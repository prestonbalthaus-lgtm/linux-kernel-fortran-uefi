! SPDX-License-Identifier: GPL-2.0
! The four memory intrinsics gcc emits calls to (roadmap 1.3), translated from
! vendor lib/string.c and diffed against it by tests/lib/test_string.c.
!
! WHY THE C NAMES ARE NOT HERE.  gcc's loop-distribution pass rewrites an array
! fill or copy into a call to memset/memcpy, so a kernel with no libc must
! define those symbols -- but a host object that defines them cannot be linked
! against the C original it is being diffed against, and lib/string.c's
! `#undef memcmp` defeats renaming the oracle instead.  The compiler-facing
! spellings are therefore in src/lib/fk_string_abi.f90, which the kernel image
! links and the differential test does not.
!
! The loops here survive the pass that made them necessary: c_f_pointer builds
! an array descriptor whose stride is a run-time value, which the pass cannot
! recognise as a memset, so nothing recurses into itself.  Measured on gfortran
! 16.1.1, both with the pass on and off.
module fk_string_m
  use, intrinsic :: iso_c_binding, only: c_int8_t, c_int32_t, c_size_t, &
                                         c_ptr, c_f_pointer, c_associated
  implicit none
  private
  public :: fk_memset, fk_memcpy, fk_memmove, fk_memcmp

contains

  ! Bytes are compared and returned UNSIGNED -- memcmp's contract is the
  ! difference of two unsigned chars -- while Fortran can only store them in a
  ! signed kind, so every read is masked back up.
  pure function ubyte(b) result(v)
    implicit none
    integer(c_int8_t), intent(in) :: b
    integer(c_int32_t) :: v

    v = iand(int(b, c_int32_t), 255_c_int32_t)
  end function ubyte

  function fk_memset(s, c, n) result(r) bind(c, name="fk_memset")
    implicit none
    type(c_ptr), intent(in), value :: s
    integer(c_int32_t), intent(in), value :: c
    integer(c_size_t), intent(in), value :: n
    type(c_ptr) :: r
    integer(c_int8_t), pointer :: b(:)
    integer(c_int8_t) :: v
    integer(c_size_t) :: i

    r = s
    if (n <= 0_c_size_t) return
    if (.not. c_associated(s)) return
    call c_f_pointer(s, b, [n])
    v = int(iand(c, 255_c_int32_t) - ishft(iand(c, 128_c_int32_t), 1), c_int8_t)
    do i = 1_c_size_t, n
       b(i) = v
    end do
  end function fk_memset

  function fk_memcpy(dest, src, n) result(r) bind(c, name="fk_memcpy")
    implicit none
    type(c_ptr), intent(in), value :: dest, src
    integer(c_size_t), intent(in), value :: n
    type(c_ptr) :: r
    integer(c_int8_t), pointer :: d(:), s(:)
    integer(c_size_t) :: i

    r = dest
    if (n <= 0_c_size_t) return
    if (.not. c_associated(dest)) return
    if (.not. c_associated(src)) return
    call c_f_pointer(dest, d, [n])
    call c_f_pointer(src,  s, [n])
    do i = 1_c_size_t, n
       d(i) = s(i)
    end do
  end function fk_memcpy

  ! The direction is chosen by comparing the two addresses, which is why they
  ! are transferred to an integer first: Fortran has no ordering on c_ptr.
  function fk_memmove(dest, src, n) result(r) bind(c, name="fk_memmove")
    implicit none
    type(c_ptr), intent(in), value :: dest, src
    integer(c_size_t), intent(in), value :: n
    type(c_ptr) :: r
    integer(c_int8_t), pointer :: d(:), s(:)
    integer(c_size_t) :: i, da, sa

    r = dest
    if (n <= 0_c_size_t) return
    if (.not. c_associated(dest)) return
    if (.not. c_associated(src)) return
    call c_f_pointer(dest, d, [n])
    call c_f_pointer(src,  s, [n])
    da = transfer(dest, 0_c_size_t)
    sa = transfer(src,  0_c_size_t)
    if (da <= sa) then
       do i = 1_c_size_t, n
          d(i) = s(i)
       end do
    else
       do i = n, 1_c_size_t, -1_c_size_t
          d(i) = s(i)
       end do
    end if
  end function fk_memmove

  function fk_memcmp(cs, ct, n) result(r) bind(c, name="fk_memcmp")
    implicit none
    type(c_ptr), intent(in), value :: cs, ct
    integer(c_size_t), intent(in), value :: n
    integer(c_int32_t) :: r
    integer(c_int8_t), pointer :: a(:), b(:)
    integer(c_size_t) :: i

    r = 0_c_int32_t
    if (n <= 0_c_size_t) return
    if (.not. c_associated(cs)) return
    if (.not. c_associated(ct)) return
    call c_f_pointer(cs, a, [n])
    call c_f_pointer(ct, b, [n])
    do i = 1_c_size_t, n
       if (a(i) /= b(i)) then
          r = ubyte(a(i)) - ubyte(b(i))
          return
       end if
    end do
  end function fk_memcmp

end module fk_string_m
