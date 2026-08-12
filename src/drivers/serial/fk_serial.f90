! SPDX-License-Identifier: GPL-2.0
! 16550 UART console on COM1, polled, 115200 8N1.
! The port-I/O primitives it is built on, fk_outb and fk_inb, are in boot/io.S.
! No Fortran I/O statement may appear here: it would pull in libgfortran.
module fk_serial_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_char
  implicit none
  private
  public :: FK_SERIAL_COM1, serial_init, serial_print_char, &
            serial_print_string

  integer(c_int32_t), parameter :: FK_SERIAL_COM1 = int(z'3F8', c_int32_t)

  ! Register offsets.  LCR.DLAB re-maps offsets 0 and 1 to the divisor latch.
  integer(c_int32_t), parameter :: UART_TX  = 0_c_int32_t  ! serial_reg.h:22
  integer(c_int32_t), parameter :: UART_RX  = 0_c_int32_t  ! serial_reg.h:21
  integer(c_int32_t), parameter :: UART_DLL = 0_c_int32_t  ! serial_reg.h:166
  integer(c_int32_t), parameter :: UART_IER = 1_c_int32_t  ! serial_reg.h:24
  integer(c_int32_t), parameter :: UART_DLM = 1_c_int32_t  ! serial_reg.h:167
  integer(c_int32_t), parameter :: UART_FCR = 2_c_int32_t  ! serial_reg.h:54 (W)
  integer(c_int32_t), parameter :: UART_IIR = 2_c_int32_t  ! serial_reg.h:34 (R)
  integer(c_int32_t), parameter :: UART_LCR = 3_c_int32_t  ! serial_reg.h:105
  integer(c_int32_t), parameter :: UART_MCR = 4_c_int32_t  ! serial_reg.h:128
  integer(c_int32_t), parameter :: UART_LSR = 5_c_int32_t  ! serial_reg.h:139

  ! Register bits, include/uapi/linux/serial_reg.h.
  integer(c_int32_t), parameter :: UART_LCR_DLAB  = int(z'80', c_int32_t) ! :110
  integer(c_int32_t), parameter :: UART_LCR_WLEN8 = int(z'03', c_int32_t) ! :119

  integer(c_int32_t), parameter :: UART_FCR_ENABLE_FIFO = int(z'01', c_int32_t) ! :55
  integer(c_int32_t), parameter :: UART_FCR_CLEAR_RCVR  = int(z'02', c_int32_t) ! :56
  integer(c_int32_t), parameter :: UART_FCR_CLEAR_XMIT  = int(z'04', c_int32_t) ! :57
  integer(c_int32_t), parameter :: UART_FCR_TRIGGER_14  = int(z'C0', c_int32_t) ! :87

  integer(c_int32_t), parameter :: UART_MCR_DTR  = int(z'01', c_int32_t) ! :137
  integer(c_int32_t), parameter :: UART_MCR_RTS  = int(z'02', c_int32_t) ! :136
  integer(c_int32_t), parameter :: UART_MCR_OUT1 = int(z'04', c_int32_t) ! :135
  integer(c_int32_t), parameter :: UART_MCR_OUT2 = int(z'08', c_int32_t) ! :134
  integer(c_int32_t), parameter :: UART_MCR_LOOP = int(z'10', c_int32_t) ! :133

  integer(c_int32_t), parameter :: UART_LSR_DR   = int(z'01', c_int32_t) ! :147
  integer(c_int32_t), parameter :: UART_LSR_THRE = int(z'20', c_int32_t) ! :142

  ! 0xC7.  The two CLEAR bits are self-clearing, so serial_init writes FCR twice.
  integer(c_int32_t), parameter :: FK_FCR_SETUP = &
       ior(ior(UART_FCR_ENABLE_FIFO, UART_FCR_CLEAR_RCVR), &
           ior(UART_FCR_CLEAR_XMIT,  UART_FCR_TRIGGER_14))

  ! 0x1E: LOOP|OUT2|OUT1|RTS.
  integer(c_int32_t), parameter :: FK_MCR_SELFTEST = &
       ior(ior(UART_MCR_LOOP, UART_MCR_OUT2), &
           ior(UART_MCR_OUT1, UART_MCR_RTS))

  ! 0x0F.  OUT2 gates the UART's interrupt line onto the 8259.
  integer(c_int32_t), parameter :: FK_MCR_LIVE = &
       ior(ior(UART_MCR_OUT2, UART_MCR_OUT1), &
           ior(UART_MCR_RTS,  UART_MCR_DTR))

  ! Divisor 1 == 115200 baud; the latch holds 115200/baud.
  integer(c_int32_t), parameter :: FK_DIVISOR_LO = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_DIVISOR_HI = 0_c_int32_t

  ! 0xAE alternates bits; 0x00 and 0xFF would match a stuck or floating line.
  integer(c_int32_t), parameter :: FK_PROBE_BYTE = int(z'AE', c_int32_t)

  ! Poll bound, the same value Linux uses here.  arch/x86/boot/tty.c:30
  integer(c_int32_t), parameter :: FK_SERIAL_TX_SPINS = 65535_c_int32_t

  ! Truncates an unterminated string instead of walking memory.
  integer(c_int32_t), parameter :: FK_SERIAL_MAX_STRING = 4096_c_int32_t

  integer(c_int32_t) :: serial_base  = 0_c_int32_t
  logical            :: serial_ready = .false.

  interface
    ! OUT takes its port in DX and one byte of data, so io.S reads %di and %sil.
    subroutine fk_outb(port, val) bind(c, name="fk_outb")
      import :: c_int32_t
      implicit none
      integer(c_int32_t), intent(in), value :: port, val
    end subroutine fk_outb

    ! The result is zero-extended into EAX, so val is 0..255, never negative.
    function fk_inb(port) result(val) bind(c, name="fk_inb")
      import :: c_int32_t
      implicit none
      integer(c_int32_t), intent(in), value :: port
      integer(c_int32_t)                    :: val
    end function fk_inb
  end interface

contains

  ! Poll the LSR for mask; .false. if the spin bound ran out.  fk_inb must stay
  ! impure, or the read is hoisted out of the loop and this never terminates.
  function lsr_wait(base, mask) result(seen)
    implicit none
    integer(c_int32_t), intent(in) :: base, mask
    logical            :: seen
    integer(c_int32_t) :: spin

    seen = .false.
    do spin = 1_c_int32_t, FK_SERIAL_TX_SPINS
       if (iand(fk_inb(base + UART_LSR), mask) /= 0_c_int32_t) then
          seen = .true.
          exit
       end if
    end do
  end function lsr_wait

  ! Bring a 16550 up at 115200 8N1; 0 if the loopback probe read back what it
  ! wrote, 1 if it did not or either poll timed out.
  function serial_init(port) result(status) bind(c, name="serial_init")
    implicit none
    integer(c_int32_t), intent(in), value :: port
    integer(c_int32_t)                    :: status
    integer(c_int32_t) :: probe
    logical            :: thre_seen, dr_seen

    ! IER first, before anything else: there is no IDT, so an IRQ4 is fatal.
    call fk_outb(port + UART_IER, 0_c_int32_t)

    ! DLAB=1 for the two divisor writes, then 8N1 with DLAB back to 0.
    call fk_outb(port + UART_LCR, UART_LCR_DLAB)
    call fk_outb(port + UART_DLL, FK_DIVISOR_LO)
    call fk_outb(port + UART_DLM, FK_DIVISOR_HI)
    call fk_outb(port + UART_LCR, UART_LCR_WLEN8)
    call fk_outb(port + UART_FCR, FK_FCR_SETUP)
    call fk_outb(port + UART_MCR, FK_MCR_SELFTEST)

    ! A timeout must not return early: MCR would be left in loopback.
    thre_seen = lsr_wait(port, UART_LSR_THRE)
    call fk_outb(port + UART_TX, FK_PROBE_BYTE)
    dr_seen   = lsr_wait(port, UART_LSR_DR)
    probe     = fk_inb(port + UART_RX)

    call fk_outb(port + UART_FCR, FK_FCR_SETUP)
    call fk_outb(port + UART_MCR, FK_MCR_LIVE)

    if (thre_seen .and. dr_seen .and. probe == FK_PROBE_BYTE) then
       status = 0_c_int32_t
    else
       status = 1_c_int32_t
    end if

    ! Armed even when the probe failed; the status is reported, not acted on.
    serial_base  = port
    serial_ready = .true.
  end function serial_init

  ! Write one byte, raw.  A timeout drops the character.
  subroutine serial_print_char(c) bind(c, name="serial_print_char")
    implicit none
    character(kind=c_char), intent(in), value :: c

    if (.not. serial_ready) return
    if (.not. lsr_wait(serial_base, UART_LSR_THRE)) return

    ! iachar is ASCII by definition and yields 0..255, never a negative.
    call fk_outb(serial_base + UART_TX, iachar(c, c_int32_t))
  end subroutine serial_print_char

  ! Write a NUL-terminated C string.  s(*) and not s(:): an assumed-shape dummy
  ! expects a descriptor where C passes a bare pointer.
  subroutine serial_print_string(s) bind(c, name="serial_print_string")
    implicit none
    character(kind=c_char), intent(in) :: s(*)
    integer(c_int32_t) :: i

    if (.not. serial_ready) return

    ! Integer compare: s(i) == c_null_char would emit _gfortran_compare_string.
    do i = 1_c_int32_t, FK_SERIAL_MAX_STRING
       if (iachar(s(i), c_int32_t) == 0_c_int32_t) return
       call serial_print_char(s(i))
    end do
  end subroutine serial_print_string

end module fk_serial_m
