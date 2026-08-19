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
!
! THE STRING HALF (roadmap 1.1) IS MEASURED SEPARATELY and the reason is that
! the paragraph above is about the wrong idiom.  gcc recognises a fill or copy
! loop as memset/memcpy, and it separately recognises an EXIT-ON-SENTINEL loop
! as strlen or rawmemchr -- a different pattern, and the one every function
! below is built out of.  Measured on 16.1.1 under FFLAGS, under KFLAGS and
! under -O3 with -ftree-loop-distribute-patterns forced on: no undefined
! strlen, no rawmemchr, nothing.  docs/HARNESS-VALIDATION.md carries the table.
module fk_string_m
  use, intrinsic :: iso_c_binding, only: c_int8_t, c_int32_t, c_size_t, &
                                         c_ptr, c_f_pointer, c_associated
  implicit none
  private
  public :: fk_memset, fk_memcpy, fk_memmove, fk_memcmp
  public :: fk_strlen, fk_strcpy, fk_strcmp, fk_strncmp

  ! A DESCRIPTOR EXTENT, NEVER A LENGTH LIMIT, and the two cannot be the
  ! same thing: a string's length is not known until its terminator is
  ! found, and c_f_pointer wants the shape before the search.  C needs no
  ! such number because it walks a bare pointer; this is the whole
  ! difference between the two languages here.  The contract is C's,
  ! unchanged -- the object is NUL-terminated, and an unterminated one runs
  ! off the end in either implementation.  Nothing is allocated: an array
  ! descriptor is a base address and a pair of bounds.
  integer(c_size_t), parameter :: SCAN_MAX = int(huge(0_c_int32_t), c_size_t)

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

  ! ---- roadmap 1.1: the string half ------------------------------------------

  function fk_strlen(s) result(n) bind(c, name="fk_strlen")
    implicit none
    type(c_ptr), intent(in), value :: s
    integer(c_size_t) :: n
    integer(c_int8_t), pointer :: b(:)

    n = 0_c_size_t
    if (.not. c_associated(s)) return
    call c_f_pointer(s, b, [SCAN_MAX])
    do while (b(n + 1_c_size_t) /= 0_c_int8_t)
       n = n + 1_c_size_t
    end do
  end function fk_strlen

  ! Copies the terminator and stops there, so the write is strlen(src)+1 bytes.
  function fk_strcpy(dest, src) result(r) bind(c, name="fk_strcpy")
    implicit none
    type(c_ptr), intent(in), value :: dest, src
    type(c_ptr) :: r
    integer(c_int8_t), pointer :: d(:), s(:)
    integer(c_size_t) :: i

    r = dest
    if (.not. c_associated(dest)) return
    if (.not. c_associated(src)) return
    call c_f_pointer(dest, d, [SCAN_MAX])
    call c_f_pointer(src,  s, [SCAN_MAX])
    i = 1_c_size_t
    do
       d(i) = s(i)
       if (s(i) == 0_c_int8_t) return
       i = i + 1_c_size_t
    end do
  end function fk_strcpy

  ! -1, 0 or 1 -- NOT the difference of the two bytes, which is what fk_memcmp
  ! above returns and what a C standard reading alone would permit.
  ! lib/string.c:35 is `return c1 < c2 ? -1 : 1`, so an implementation handing
  ! back c1-c2 is a conforming strcmp and a failing translation.  The compare
  ! is UNSIGNED as well, so 0x80 against 0x00 is 1.
  function fk_strcmp(cs, ct) result(r) bind(c, name="fk_strcmp")
    implicit none
    type(c_ptr), intent(in), value :: cs, ct
    integer(c_int32_t) :: r
    integer(c_int8_t), pointer :: a(:), b(:)
    integer(c_size_t) :: i
    integer(c_int32_t) :: c1, c2

    r = 0_c_int32_t
    if (.not. c_associated(cs)) return
    if (.not. c_associated(ct)) return
    call c_f_pointer(cs, a, [SCAN_MAX])
    call c_f_pointer(ct, b, [SCAN_MAX])
    i = 1_c_size_t
    do
       c1 = ubyte(a(i))
       c2 = ubyte(b(i))
       if (c1 /= c2) then
          if (c1 < c2) then
             r = -1_c_int32_t
          else
             r = 1_c_int32_t
          end if
          return
       end if
       if (c1 == 0_c_int32_t) return
       i = i + 1_c_size_t
    end do
  end function fk_strcmp

  ! THE TERMINATOR TEST IS LOAD BEARING; THE ORDER IT SITS IN IS NOT, and the
  ! difference was measured rather than argued.  lib/string.c:302-317 spends the
  ! count AFTER testing for the terminator, and this used to claim that order
  ! was observable.  It is not: both forms return on the spot and neither reads
  ! `left` or `i` again, so swapping them returns the same value for every
  ! input.  M93 injects the swap and the suite passes it, correctly.  Deleting
  ! the test is a different defect entirely -- M96 -- and both channels see it.
  function fk_strncmp(cs, ct, count) result(r) bind(c, name="fk_strncmp")
    implicit none
    type(c_ptr), intent(in), value :: cs, ct
    integer(c_size_t), intent(in), value :: count
    integer(c_int32_t) :: r
    integer(c_int8_t), pointer :: a(:), b(:)
    integer(c_size_t) :: i, left
    integer(c_int32_t) :: c1, c2

    r = 0_c_int32_t
    ! `== 0` AND `/= 0`, NEVER `<= 0` AND `> 0`, and this is a bug that was in
    ! the file until the suite refused it.  C's size_t is unsigned and Fortran's
    ! c_size_t is a signed int64, so a count with the top bit set arrives here
    ! NEGATIVE: `count <= 0` sent strncmp(a, b, SIZE_MAX) straight to 0 while
    ! lib/string.c compared to the terminator and answered 1.  Testing the bit
    ! pattern against zero instead works for the whole unsigned domain, because
    ! the terminator ends the loop long before a decrement from -1 could.
    if (count == 0_c_size_t) return
    if (.not. c_associated(cs)) return
    if (.not. c_associated(ct)) return
    call c_f_pointer(cs, a, [SCAN_MAX])
    call c_f_pointer(ct, b, [SCAN_MAX])
    i = 1_c_size_t
    left = count
    do while (left /= 0_c_size_t)
       c1 = ubyte(a(i))
       c2 = ubyte(b(i))
       if (c1 /= c2) then
          if (c1 < c2) then
             r = -1_c_int32_t
          else
             r = 1_c_int32_t
          end if
          return
       end if
       if (c1 == 0_c_int32_t) return
       i = i + 1_c_size_t
       left = left - 1_c_size_t
    end do
  end function fk_strncmp

end module fk_string_m
