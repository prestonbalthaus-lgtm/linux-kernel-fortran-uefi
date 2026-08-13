! SPDX-License-Identifier: GPL-2.0
! Flat 64-bit GDT (roadmap 3.1).  Supersedes the throwaway table in boot/boot.S:
! that one lives in .rodata with a 32-bit LGDT operand built for pre-paging
! addresses, this one is kernel data with a 64-bit operand.  Selector values are
! handed to the flush stub rather than hardcoded there, so this module is the
! only place they are decided.
module fk_gdt_m
  use, intrinsic :: iso_c_binding, only: c_int16_t, c_int32_t, c_int64_t, c_loc
  implicit none
  private
  public :: FK_GDT_SEL_CODE, FK_GDT_SEL_DATA, FK_GDT_SEL_TSS, gdt_init, &
            gdt_set_tss

  integer(c_int16_t), parameter :: FK_GDT_SEL_CODE = int(z'08', c_int16_t)
  integer(c_int16_t), parameter :: FK_GDT_SEL_DATA = int(z'10', c_int16_t)
  integer(c_int16_t), parameter :: FK_GDT_SEL_TSS  = int(z'18', c_int16_t)

  ! A TSS descriptor is SIXTEEN bytes in 64-bit mode, not eight: it eats the
  ! slot the selector names and the one after it.  The slot index is derived
  ! from the selector rather than written down twice.
  integer(c_int32_t), parameter :: FK_GDT_TSS_SLOT = &
       int(FK_GDT_SEL_TSS, c_int32_t) / 8 + 1

  ! Access 0x9A = P|S|code|read, flags 0xA = G|L.  The L bit is the whole point
  ! of the code descriptor; D/B must be 0 whenever it is set.  Access 0x92 =
  ! P|S|data|write.  Base and limit are ignored in long mode, but ds/es/ss must
  ! still name a present descriptor.
  integer(c_int64_t), parameter :: FK_GDT_NULL = 0_c_int64_t
  integer(c_int64_t), parameter :: FK_GDT_CODE = int(z'00AF9A000000FFFF', c_int64_t)
  integer(c_int64_t), parameter :: FK_GDT_DATA = int(z'00CF92000000FFFF', c_int64_t)

  integer(c_int64_t), target, save :: &
       gdt(5) = [FK_GDT_NULL, FK_GDT_CODE, FK_GDT_DATA, &
                 0_c_int64_t, 0_c_int64_t]

  ! LGDT reads a PACKED 16-bit limit followed by a 64-bit base.  A bind(c)
  ! derived type cannot express that -- C struct rules pad the base out to
  ! offset 8 -- so it is five contiguous 16-bit words, which Fortran does
  ! guarantee to be packed.
  integer(c_int16_t), save :: gdtr(5)

  interface
    ! Installs the table and reloads cs/ds/es/fs/gs/ss.  boot/gdt_flush.S.
    subroutine gdt_flush(desc, code_sel, data_sel) bind(c, name="gdt_flush")
      import :: c_int16_t
      implicit none
      integer(c_int16_t), intent(in)        :: desc(*)
      integer(c_int16_t), intent(in), value :: code_sel, data_sel
    end subroutine gdt_flush
  end interface

contains

  ! Low 16 bits of v in the signed kind Fortran has to store them in.
  pure function u16(v) result(w)
    implicit none
    integer(c_int64_t), intent(in) :: v
    integer(c_int16_t) :: w
    integer(c_int64_t) :: bits

    bits = iand(v, 65535_c_int64_t)
    if (bits > 32767_c_int64_t) bits = bits - 65536_c_int64_t
    w = int(bits, c_int16_t)
  end function u16

  subroutine gdt_init() bind(c, name="gdt_init")
    implicit none
    integer(c_int64_t) :: base
    integer(c_int32_t) :: i

    base = transfer(c_loc(gdt), 0_c_int64_t)

    ! Limit is the offset of the last valid byte, not the size.
    gdtr(1) = u16(int(8 * size(gdt) - 1, c_int64_t))
    do i = 0_c_int32_t, 3_c_int32_t
       gdtr(2 + i) = u16(ishft(base, -16 * i))
    end do

    call gdt_flush(gdtr, FK_GDT_SEL_CODE, FK_GDT_SEL_DATA)
  end subroutine gdt_init

  ! The two quadwords of the TSS descriptor, built by fk_tss_m because only it
  ! knows where the TSS is.  Safe to run after LGDT: the CPU re-reads the table
  ! on every descriptor load, and nothing has loaded FK_GDT_SEL_TSS yet.
  subroutine gdt_set_tss(lo, hi) bind(c, name="gdt_set_tss")
    implicit none
    integer(c_int64_t), intent(in), value :: lo, hi

    gdt(FK_GDT_TSS_SLOT)     = lo
    gdt(FK_GDT_TSS_SLOT + 1) = hi
  end subroutine gdt_set_tss

end module fk_gdt_m
