! SPDX-License-Identifier: GPL-2.0
! The 8253/8254 programmable interval timer, channel 0 (roadmap 3.2b).  It is
! wired to the master 8259's line 0 and it is the only interrupt source this
! kernel has: no device is attached, no key is pressed, and the APIC is not up
! (roadmap 3.3), so if a Fortran interrupt handler is ever going to run and
! return, this is what makes it run.
!
! The counter is a bind(c) module variable ON PURPOSE.  It is the one piece of
! evidence for this milestone that can be read from OUTSIDE the guest -- QEMU's
! pmemsave against the symbol in the ELF -- so "the machine is still taking
! interrupts and returning from them" is a fact about a running CPU rather than
! a line the kernel printed about itself.  tools/qmp-sentinel.py reads it twice.
!
! ALL THREE OF THESE ARE EXPORTED AS VARIABLES AND NOT THROUGH ACCESSOR
! FUNCTIONS, and that is a codegen constraint rather than a matter of taste.
! Measured on gfortran 16.1.1 with this tree's KFLAGS: a module FUNCTION whose
! whole body is a volatile load is compiled correctly inside its own
! translation unit, and treated as side-effect-free from ANOTHER one -- the
! caller has only the .mod, the volatility is inside the body it cannot see, and
! the optimiser then deletes a wait loop whose condition is that call and reuses
! one result for two reads.  The VOLATILE attribute on the variable itself does
! travel through use association, and the load is then emitted in the reader.
module fk_pit_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t
  implicit none
  private
  public :: FK_PIT_BASE_HZ, FK_PIT_HZ, FK_PIT_IRQ, pit_init, pit_tick, &
            fk_tick_count, fk_first_rip, fk_first_rflags

  ! The crystal is 14.31818 MHz divided by 12.  Not 1.2 MHz, not 1193180: the
  ! divisor below is computed from it, so a rounded constant here is a clock
  ! that runs at the wrong rate and nothing in the kernel would ever say so.
  integer(c_int32_t), parameter :: FK_PIT_BASE_HZ = 1193182_c_int32_t

  ! 100 Hz -- 10 ms a tick.  Fast enough that the proof loop in kernel_main does
  ! not have to spin long, slow enough that the interrupt costs nothing.
  integer(c_int32_t), parameter :: FK_PIT_HZ = 100_c_int32_t

  ! Channel 0's output is hardwired to the master's line 0.  Named here rather
  ! than written as a 0 at the call site: it is a property of the machine.
  integer(c_int32_t), parameter :: FK_PIT_IRQ = 0_c_int32_t

  integer(c_int32_t), parameter :: PIT_CH0 = int(z'40', c_int32_t)
  integer(c_int32_t), parameter :: PIT_CMD = int(z'43', c_int32_t)

  ! 0x36 = channel 0, lobyte-then-hibyte access, mode 3 (square wave), binary.
  ! Mode 3 rather than mode 2 because it is what the reload divisor below is
  ! sized for and what every PC has run its tick on; the distinction that
  ! matters is BINARY, since the BCD bit would reinterpret 11932 as a decimal
  ! digit string and the timer would fire at a rate nobody chose.
  integer(c_int32_t), parameter :: FK_PIT_MODE = int(z'36', c_int32_t)

  integer(c_int32_t), parameter :: FK_BYTE = int(z'FF', c_int32_t)

  ! VOLATILE and bind(c): the writer is an interrupt handler and one reader is
  ! outside the program entirely.  A 64-bit aligned load or store is a single
  ! access on x86-64, so a reader never sees half of an increment.
  integer(c_int64_t), volatile, bind(c, name="fk_tick_count") :: &
       fk_tick_count = 0_c_int64_t

  ! The interrupted context of the FIRST tick, kept because it is the only
  ! thing that says WHERE the interrupt was taken.  A tick counter proves the
  ! handler ran; this proves the CPU was executing kernel code at the time and
  ! that IRETQ therefore had somewhere real to go back to.
  integer(c_int64_t), volatile, bind(c, name="fk_first_rip") :: &
       fk_first_rip = 0_c_int64_t
  integer(c_int64_t), volatile, bind(c, name="fk_first_rflags") :: &
       fk_first_rflags = 0_c_int64_t

  interface
    subroutine fk_outb(port, val) bind(c, name="fk_outb")
      import :: c_int32_t
      implicit none
      integer(c_int32_t), intent(in), value :: port, val
    end subroutine fk_outb
  end interface

contains

  ! Program channel 0 to interrupt at hz, and return the divisor written.  The
  ! caller prints it: a divisor is a number the kernel COMPUTED from the crystal
  ! rate, so it is evidence the sequence ran, where "PIT initialised" is not.
  !
  ! Rounded to nearest rather than truncated.  A returned 0 always means REFUSED
  ! and never "programmed with a reload of 65536": those are the same byte on
  ! the wire, and 65536 is also the reload the firmware leaves behind, so a
  ! result that meant both could not be told from never having touched the chip.
  ! Any hz below 19 lands there, so it is turned away instead.
  function pit_init(hz) result(divisor) bind(c, name="pit_init")
    implicit none
    integer(c_int32_t), intent(in), value :: hz
    integer(c_int32_t) :: divisor

    if (hz <= 0_c_int32_t .or. hz > FK_PIT_BASE_HZ) then
       divisor = 0_c_int32_t
       return
    end if

    divisor = (FK_PIT_BASE_HZ + hz / 2_c_int32_t) / hz
    if (divisor > 65535_c_int32_t) then
       divisor = 0_c_int32_t
       return
    end if

    call fk_outb(PIT_CMD, FK_PIT_MODE)
    call fk_outb(PIT_CH0, iand(divisor, FK_BYTE))
    call fk_outb(PIT_CH0, iand(ishft(divisor, -8), FK_BYTE))
  end function pit_init

  ! Called from the IRQ router with the interrupted RIP and RFLAGS.  It does not
  ! print: the console is not re-entrant and the main thread is using it.
  subroutine pit_tick(rip, rflags) bind(c, name="pit_tick")
    implicit none
    integer(c_int64_t), intent(in), value :: rip, rflags

    if (fk_tick_count == 0_c_int64_t) then
       fk_first_rip    = rip
       fk_first_rflags = rflags
    end if
    fk_tick_count = fk_tick_count + 1_c_int64_t
  end subroutine pit_tick

end module fk_pit_m
