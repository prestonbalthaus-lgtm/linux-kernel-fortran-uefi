! SPDX-License-Identifier: GPL-2.0
! Fortran entry point for the Multiboot2 boot path.  boot/boot.S calls
! kernel_main once the CPU is in 64-bit long mode; it records the loader handoff
! in fk_boot_sentinel, brings COM1 up, installs the GDT and IDT, and then faults
! on purpose so roadmap 3.2's catcher has something to catch.
! tools/qemu-boot-test.sh reads the sentinel back over QMP and greps the
! captured COM1 log.
module fk_kmain_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t, c_char, &
                                         c_null_char
  use fk_serial_m, only: FK_SERIAL_COM1, serial_init, serial_print_string
  use fk_gdt_m,    only: gdt_init
  use fk_idt_m,    only: idt_init
  implicit none
  private
  public :: kernel_main

  ! "KBOT": marks the sentinel as written here rather than left uninitialised.
  integer(c_int32_t), parameter :: FK_BOOT_TAG = int(z'4B424F54', c_int32_t)

  ! The value a Multiboot2-compliant loader is required to leave in EAX.
  integer(c_int32_t), parameter :: MB2_BOOTLOADER_MAGIC = int(z'36D76289', c_int32_t)

  ! Not zero, so "never written" and "written with zeros" stay distinguishable.
  integer(c_int32_t), parameter :: FK_UNWRITTEN = int(z'11111111', c_int32_t)

  ! Handoff record: (1) FK_BOOT_TAG, (2) the loader's magic, (3) the low 32
  ! bits of the MBI pointer, (4) tag xor magic computed at run time.  VOLATILE:
  ! the only reader is outside the program -- QMP, after the CPU has parked.
  integer(c_int32_t), volatile, bind(c, name="fk_boot_sentinel") :: &
       fk_boot_sentinel(4) = [FK_UNWRITTEN, FK_UNWRITTEN, FK_UNWRITTEN, FK_UNWRITTEN]

  ! CR LF, never a bare LF: a raw serial line does no newline translation.
  character(kind=c_char, len=*), parameter :: FK_CRLF = achar(13) // achar(10)

  ! tools/qemu-boot-test.sh greps the COM1 log for this text exactly.  The
  ! concatenation is constant-folded into one .rodata string only because these
  ! are PARAMETERs; in executable code gfortran may lower // to a memmove call.
  character(kind=c_char, len=*), parameter :: FK_BANNER = &
       "Fortran Kernel: UART Serial Initialized." // FK_CRLF // c_null_char

  ! Printed when serial_init's loopback probe failed; qemu-boot-test.sh asserts
  ! this string is ABSENT from the log.
  character(kind=c_char, len=*), parameter :: FK_SELFTEST_FAILED = &
       "Fortran Kernel: COM1 loopback self-test FAILED." // FK_CRLF // c_null_char

  character(kind=c_char, len=*), parameter :: FK_GDT_READY = &
       "Fortran Kernel: GDT loaded, flat 64-bit model." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IDT_READY = &
       "Fortran Kernel: IDT loaded, 32 CPU exceptions armed." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_TRIGGER = &
       "Fortran Kernel: dividing by zero on purpose (roadmap 3.2)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_NO_FAULT = &
       "Fortran Kernel: the divide by zero did NOT trap." // FK_CRLF // c_null_char

  ! BOTH operands are volatile, and that is not belt and braces: with a literal
  ! numerator gcc rewrites 1/x into a compare against +-1 and emits no DIV at
  ! all, so the fault this milestone exists to raise never happens.  Module
  ! scope keeps the values inspectable in guest memory.
  integer(c_int32_t), volatile :: fk_dividend = 1_c_int32_t
  integer(c_int32_t), volatile :: fk_divisor  = 0_c_int32_t
  integer(c_int32_t), volatile :: fk_quotient = 0_c_int32_t

  interface
    ! Parks this CPU permanently (CLI; HLT) and never returns.  In boot/boot.S,
    ! because a privileged CPU-control instruction has no Fortran spelling.
    subroutine fk_cpu_halt() bind(c, name="fk_cpu_halt")
      implicit none
    end subroutine fk_cpu_halt
  end interface

contains

  ! Entry point called by boot/boot.S once the CPU is in 64-bit long mode.
  ! Does not return.  magic and mbi arrive by value per the SysV AMD64 C ABI,
  ! in EDI and RSI.
  subroutine kernel_main(magic, mbi) bind(c, name="kernel_main")
    implicit none
    integer(c_int32_t), intent(in), value :: magic
    integer(c_int64_t), intent(in), value :: mbi
    integer(c_int32_t) :: status

    ! Scalar stores, not an array assignment: gfortran may lower that to a
    ! memset call, which is an undefined symbol in a kernel with no libc.
    fk_boot_sentinel(1) = FK_BOOT_TAG
    fk_boot_sentinel(2) = magic
    ! Masked to 32 bits because the sentinel word is; INT() alone on a value
    ! with bit 31 set would be a range violation.
    fk_boot_sentinel(3) = int(iand(mbi, int(z'FFFFFFFF', c_int64_t)), c_int32_t)
    fk_boot_sentinel(4) = ieor(FK_BOOT_TAG, magic)

    ! After the sentinel: the stores are the evidence this routine ran, and
    ! must not be sequenced behind a driver that touches hardware.
    status = serial_init(FK_SERIAL_COM1)

    ! Sequence association (F2018 15.5.2.11): FK_BANNER is a character scalar
    ! and the dummy is character(kind=c_char) :: s(*), so the call passes the
    ! address of the .rodata literal and copies nothing.
    call serial_print_string(FK_BANNER)

    if (status /= 0_c_int32_t) call serial_print_string(FK_SELFTEST_FAILED)

    call gdt_init()
    call serial_print_string(FK_GDT_READY)
    call idt_init()
    call serial_print_string(FK_IDT_READY)

    ! Roadmap 3.2's validation: a real #DE, raised by the CPU rather than
    ! simulated by a call.
    call serial_print_string(FK_TRIGGER)
    fk_dividend = 1_c_int32_t
    fk_divisor  = 0_c_int32_t
    fk_quotient = fk_dividend / fk_divisor

    ! Reached only if vector 0 returned, which no gate installed here does.
    call serial_print_string(FK_NO_FAULT)
    call fk_cpu_halt()
  end subroutine kernel_main

end module fk_kmain_m
