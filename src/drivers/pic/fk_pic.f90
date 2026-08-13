! SPDX-License-Identifier: GPL-2.0
! The legacy 8259A pair: remapped clear of the CPU exception vectors, then
! fully masked (roadmap 3.3, first half).  Nothing in this kernel wants a
! legacy IRQ.  What it wants is for one to be impossible to MISREAD: out of
! reset the master answers on vectors 0x08-0x0F, so a spurious timer interrupt
! arrives as vector 8 and the panic handler reports a #DF that never happened.
module fk_pic_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: FK_PIC1_VECTOR, FK_PIC2_VECTOR, pic_remap

  integer(c_int32_t), parameter :: PIC1_CMD  = int(z'20', c_int32_t)
  integer(c_int32_t), parameter :: PIC1_DATA = int(z'21', c_int32_t)
  integer(c_int32_t), parameter :: PIC2_CMD  = int(z'A0', c_int32_t)
  integer(c_int32_t), parameter :: PIC2_DATA = int(z'A1', c_int32_t)

  ! ICW1 0x11: bit 4 is what marks the byte as ICW1 at all, bit 0 says an ICW4
  ! follows.  Writing it to the COMMAND port starts the four-word sequence;
  ! ICW2..ICW4 then go to the DATA port, in that order and no other.
  integer(c_int32_t), parameter :: FK_ICW1 = int(z'11', c_int32_t)

  ! ICW2, the whole point: the vector the chip's IRQ0 becomes.
  integer(c_int32_t), parameter :: FK_PIC1_VECTOR = int(z'20', c_int32_t)
  integer(c_int32_t), parameter :: FK_PIC2_VECTOR = int(z'28', c_int32_t)

  ! ICW3 is asymmetric: the master takes a BITMASK of which of its lines has a
  ! slave on it (IRQ2 -> 0x04), the slave takes that line as a NUMBER (2).
  integer(c_int32_t), parameter :: FK_ICW3_MASTER = int(z'04', c_int32_t)
  integer(c_int32_t), parameter :: FK_ICW3_SLAVE  = int(z'02', c_int32_t)

  ! ICW4 bit 0 = 8086/8088 mode.  Clear leaves the chip in MCS-80/85 mode.
  integer(c_int32_t), parameter :: FK_ICW4 = int(z'01', c_int32_t)

  integer(c_int32_t), parameter :: FK_MASK_ALL = int(z'FF', c_int32_t)

  ! The 8259 needs bus settling time between writes and there is no timer yet.
  ! Port 0x80 is the POST diagnostic latch: unclaimed, harmless to write, and
  ! one I/O cycle long -- the delay every PC BIOS has used for this since 1981.
  integer(c_int32_t), parameter :: FK_IO_DELAY_PORT = int(z'80', c_int32_t)

  interface
    subroutine fk_outb(port, val) bind(c, name="fk_outb")
      import :: c_int32_t
      implicit none
      integer(c_int32_t), intent(in), value :: port, val
    end subroutine fk_outb

    function fk_inb(port) result(val) bind(c, name="fk_inb")
      import :: c_int32_t
      implicit none
      integer(c_int32_t), intent(in), value :: port
      integer(c_int32_t)                    :: val
    end function fk_inb
  end interface

contains

  subroutine pic_out(port, val)
    implicit none
    integer(c_int32_t), intent(in) :: port, val

    call fk_outb(port, val)
    call fk_outb(FK_IO_DELAY_PORT, 0_c_int32_t)
  end subroutine pic_out

  ! Remap and mask.  0 if both interrupt mask registers read back 0xFF, 1 if
  ! either did not: once the ICW sequence has completed, a read of the data
  ! port returns the IMR, so this is the chip's answer rather than ours.
  function pic_remap() result(status) bind(c, name="pic_remap")
    implicit none
    integer(c_int32_t) :: status

    call pic_out(PIC1_CMD,  FK_ICW1)
    call pic_out(PIC2_CMD,  FK_ICW1)
    call pic_out(PIC1_DATA, FK_PIC1_VECTOR)
    call pic_out(PIC2_DATA, FK_PIC2_VECTOR)
    call pic_out(PIC1_DATA, FK_ICW3_MASTER)
    call pic_out(PIC2_DATA, FK_ICW3_SLAVE)
    call pic_out(PIC1_DATA, FK_ICW4)
    call pic_out(PIC2_DATA, FK_ICW4)

    ! ICW4 leaves the IMR holding whatever the firmware left; masking is a
    ! separate write and is the one that makes the remap safe to have done.
    call pic_out(PIC1_DATA, FK_MASK_ALL)
    call pic_out(PIC2_DATA, FK_MASK_ALL)

    status = 0_c_int32_t
    if (fk_inb(PIC1_DATA) /= FK_MASK_ALL) status = 1_c_int32_t
    if (fk_inb(PIC2_DATA) /= FK_MASK_ALL) status = 1_c_int32_t
  end function pic_remap

end module fk_pic_m
