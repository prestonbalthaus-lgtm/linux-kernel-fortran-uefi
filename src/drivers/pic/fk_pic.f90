! SPDX-License-Identifier: GPL-2.0
! The legacy 8259A pair: remapped clear of the CPU exception vectors and then
! fully masked (roadmap 3.2.5), plus the four operations a kernel that actually
! takes an IRQ needs (roadmap 3.2b) -- unmask one line, acknowledge it, and read
! back either mask register or either in-service register from the chip itself.
!
! The remap came first and on its own: out of reset the master answers on
! vectors 0x08-0x0F, so a spurious timer interrupt arrives as vector 8 and the
! panic handler reports a #DF that never happened.
module fk_pic_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: FK_PIC1_VECTOR, FK_PIC2_VECTOR, FK_PIC_LINES, FK_PIC_CASCADE, &
            pic_remap, pic_eoi, pic_mask, pic_unmask, pic_imr, pic_isr

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

  ! Eight lines to a chip, and the master's line 2 is the one the slave hangs
  ! off: a masked IRQ2 mutes all eight slave lines however they are programmed.
  integer(c_int32_t), parameter :: FK_PIC_LINES   = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_PIC_CASCADE = 2_c_int32_t

  ! OCW2 with bits 6:5 clear = NON-SPECIFIC EOI: clear the highest-priority bit
  ! currently set in the in-service register.  It is the right form here because
  ! this kernel never nests IRQs -- every gate clears IF -- so the bit being
  ! cleared can only be the one line being serviced.
  integer(c_int32_t), parameter :: FK_OCW2_EOI = int(z'20', c_int32_t)

  ! OCW3, written to the COMMAND port, chooses what the next read of that port
  ! returns: 0x0A the request register, 0x0B the in-service register.  The IMR
  ! needs no such command -- it is what the DATA port reads once ICW4 has landed.
  integer(c_int32_t), parameter :: FK_OCW3_READ_ISR = int(z'0B', c_int32_t)

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

  ! Acknowledge line irq.  SLAVE FIRST, THEN MASTER, and only ever the master
  ! for a line below 8: a slave interrupt reaches the CPU through the master's
  ! cascade line, so both chips hold an in-service bit and a chip left holding
  ! one delivers nothing further.  That failure is silent and looks exactly like
  ! "interrupts stopped working" -- one tick and then nothing.
  !
  ! No FK_IO_DELAY_PORT write here, unlike pic_out: the settling delay exists
  ! for the four-word initialisation sequence, and an EOI is one write on a chip
  ! that has been initialised for some time.  This runs inside every interrupt.
  subroutine pic_eoi(irq) bind(c, name="pic_eoi")
    implicit none
    integer(c_int32_t), intent(in), value :: irq

    if (irq >= 8_c_int32_t) call fk_outb(PIC2_CMD, FK_OCW2_EOI)
    call fk_outb(PIC1_CMD, FK_OCW2_EOI)
  end subroutine pic_eoi

  ! Which chip and which bit line irq lives on.
  pure subroutine pic_line(irq, port, bit)
    implicit none
    integer(c_int32_t), intent(in)  :: irq
    integer(c_int32_t), intent(out) :: port, bit

    if (irq < 8_c_int32_t) then
       port = PIC1_DATA
       bit  = irq
    else
       port = PIC2_DATA
       bit  = irq - 8_c_int32_t
    end if
  end subroutine pic_line

  subroutine pic_mask(irq) bind(c, name="pic_mask")
    implicit none
    integer(c_int32_t), intent(in), value :: irq
    integer(c_int32_t) :: port, bit

    call pic_line(irq, port, bit)
    call fk_outb(port, ibset(fk_inb(port), bit))
  end subroutine pic_mask

  ! Clearing the bit is the whole operation for a master line.  For a slave line
  ! it is half of it: the master's IRQ2 carries every slave interrupt, so an
  ! unmasked slave line behind a masked cascade is still silent.
  subroutine pic_unmask(irq) bind(c, name="pic_unmask")
    implicit none
    integer(c_int32_t), intent(in), value :: irq
    integer(c_int32_t) :: port, bit

    call pic_line(irq, port, bit)
    call fk_outb(port, ibclr(fk_inb(port), bit))
    if (irq >= 8_c_int32_t) &
         call fk_outb(PIC1_DATA, ibclr(fk_inb(PIC1_DATA), FK_PIC_CASCADE))
  end subroutine pic_unmask

  ! Both interrupt mask registers, slave in bits 15:8 and master in bits 7:0,
  ! read off the chips.  Callers use it to state what the hardware holds rather
  ! than what they asked it to hold.
  function pic_imr() result(v) bind(c, name="pic_imr")
    implicit none
    integer(c_int32_t) :: v

    v = ior(fk_inb(PIC1_DATA), ishft(fk_inb(PIC2_DATA), 8))
  end function pic_imr

  ! Both in-service registers, laid out the same way.  This is how a SPURIOUS
  ! interrupt is identified: the 8259 raises line 7 (or the slave's line 7, i.e.
  ! 15) when a request withdraws before the CPU acknowledges it, and the one
  ! thing that distinguishes it from a real one is that the chip never set the
  ! in-service bit -- so a handler that trusts the vector alone acknowledges an
  ! interrupt that never happened, and cancels a real one still in service.
  function pic_isr() result(v) bind(c, name="pic_isr")
    implicit none
    integer(c_int32_t) :: v

    call fk_outb(PIC1_CMD, FK_OCW3_READ_ISR)
    call fk_outb(PIC2_CMD, FK_OCW3_READ_ISR)
    v = ior(fk_inb(PIC1_CMD), ishft(fk_inb(PIC2_CMD), 8))
  end function pic_isr

end module fk_pic_m
