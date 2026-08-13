! SPDX-License-Identifier: GPL-2.0
! The compiler-facing spellings of roadmap 1.3's intrinsics.  gcc's
! loop-distribution pass turns an array fill or copy into a call to memset or
! memcpy by name, so these symbols must exist in a kernel with no libc; the
! implementations they forward to live in fk_string_m, where the differential
! test can link them against vendor lib/string.c without a symbol collision.
!
! Separate OBJECT as well as separate module: Makefile.boot links this one and
! ./Makefile's string test does not.
module fk_string_abi_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_size_t, c_ptr
  use fk_string_m, only: fk_memset, fk_memcpy, fk_memmove, fk_memcmp
  implicit none
  private
  ! PUBLIC even though nothing in Fortran ever calls them: these four exist to
  ! be found by the LINKER, resolving the calls gcc's loop-distribution pass
  ! emits by name. tools/compliance.sh asks every module for a public bind(c)
  ! export and is right to -- a module whose exports are all private is one
  ! whose symbols leave the image by accident.
  public :: c_memset, c_memcpy, c_memmove, c_memcmp

contains

  function c_memset(s, c, n) result(r) bind(c, name="memset")
    implicit none
    type(c_ptr), intent(in), value :: s
    integer(c_int32_t), intent(in), value :: c
    integer(c_size_t), intent(in), value :: n
    type(c_ptr) :: r

    r = fk_memset(s, c, n)
  end function c_memset

  function c_memcpy(dest, src, n) result(r) bind(c, name="memcpy")
    implicit none
    type(c_ptr), intent(in), value :: dest, src
    integer(c_size_t), intent(in), value :: n
    type(c_ptr) :: r

    r = fk_memcpy(dest, src, n)
  end function c_memcpy

  function c_memmove(dest, src, n) result(r) bind(c, name="memmove")
    implicit none
    type(c_ptr), intent(in), value :: dest, src
    integer(c_size_t), intent(in), value :: n
    type(c_ptr) :: r

    r = fk_memmove(dest, src, n)
  end function c_memmove

  function c_memcmp(cs, ct, n) result(r) bind(c, name="memcmp")
    implicit none
    type(c_ptr), intent(in), value :: cs, ct
    integer(c_size_t), intent(in), value :: n
    integer(c_int32_t) :: r

    r = fk_memcmp(cs, ct, n)
  end function c_memcmp

end module fk_string_abi_m
