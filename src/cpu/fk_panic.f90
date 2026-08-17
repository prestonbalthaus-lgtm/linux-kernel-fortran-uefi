! SPDX-License-Identifier: GPL-2.0
module fk_panic_m
  use, intrinsic :: iso_c_binding, only: c_char, c_int32_t, c_int64_t
  implicit none
  private
  public :: FK_PANIC_MAGIC, FK_PANIC_MAX, FK_PANIC_SLOTS, &
            fk_panic_state, panic, panic_code

  integer(c_int64_t), parameter :: FK_PANIC_MAGIC = int(z'50414E4943', c_int64_t)
  integer(c_int32_t), parameter :: FK_PANIC_MAX   = 512_c_int32_t
  integer(c_int32_t), parameter :: FK_PANIC_SLOTS = 4_c_int32_t

  character(kind=c_char, len=*), parameter :: FK_CRLF = achar(13) // achar(10)
  character(kind=c_char, len=*), parameter :: FK_PANIC_BANNER = &
       FK_CRLF // "*** FORTRAN KERNEL PANIC (SOFTWARE) ***" // FK_CRLF // achar(0)
  character(kind=c_char, len=*), parameter :: FK_PANIC_CODE_TAG = &
       FK_CRLF // "CODE    = 0x" // achar(0)
  character(kind=c_char, len=*), parameter :: FK_PANIC_TAIL = &
       FK_CRLF // "*** HALTED -- CLI/HLT ***" // FK_CRLF // achar(0)

  ! The panic record, in .bss at a bind(c) name so tools/qmp-sentinel.py can
  ! pmemsave it out of the guest.  A panic that reaches neither console is still
  ! provable from outside; every line the reporter prints stops being evidence
  ! the moment the thing being reported is the console itself.
  ! [0] magic once a panic has begun  [1] nesting depth
  ! [2] caller's code                 [3] first 8 message bytes, little-endian
  integer(c_int64_t), volatile, save, bind(c, name="fk_panic_state") :: &
       fk_panic_state(0:FK_PANIC_SLOTS - 1)

  interface
    subroutine fk_cli() bind(c, name="fk_cli")
      implicit none
    end subroutine fk_cli

    subroutine fk_cpu_halt() bind(c, name="fk_cpu_halt")
      implicit none
    end subroutine fk_cpu_halt

    subroutine serial_print_string(s) bind(c, name="serial_print_string")
      import :: c_char
      implicit none
      character(kind=c_char), intent(in) :: s(*)
    end subroutine serial_print_string

    subroutine serial_print_hex(v, nibbles) bind(c, name="serial_print_hex")
      import :: c_int64_t, c_int32_t
      implicit none
      integer(c_int64_t), intent(in), value :: v
      integer(c_int32_t), intent(in), value :: nibbles
    end subroutine serial_print_hex

    ! Reached by name, not by USE: a panic must work whether or not a screen was
    ! ever initialised, and USE would order the whole video stack ahead of this
    ! module in Makefile.boot.  Both are no-ops before console_init.
    subroutine console_write(s, max_chars) bind(c, name="console_write")
      import :: c_char, c_int32_t
      implicit none
      character(kind=c_char), intent(in)        :: s(*)
      integer(c_int32_t),     intent(in), value :: max_chars
    end subroutine console_write

    subroutine console_print_hex(v, digits) bind(c, name="console_print_hex")
      import :: c_int64_t, c_int32_t
      implicit none
      integer(c_int64_t), intent(in), value :: v
      integer(c_int32_t), intent(in), value :: digits
    end subroutine console_print_hex

    subroutine idt_set_panic_colors() bind(c, name="idt_set_panic_colors")
      implicit none
    end subroutine idt_set_panic_colors
  end interface

contains

  function msg_head(msg) result(packed)
    implicit none
    character(kind=c_char), intent(in) :: msg(*)
    integer(c_int64_t) :: packed
    integer(c_int32_t) :: i
    integer(c_int64_t) :: b
    packed = 0_c_int64_t
    do i = 1_c_int32_t, 8_c_int32_t
       if (iachar(msg(i), c_int32_t) == 0) exit
       b = int(iand(iachar(msg(i), c_int32_t), 255_c_int32_t), c_int64_t)
       packed = ior(packed, shiftl(b, 8 * (i - 1)))
    end do
  end function msg_head

  subroutine panic(msg) bind(c, name="fk_panic")
    implicit none
    character(kind=c_char), intent(in) :: msg(*)
    call panic_code(msg, 0_c_int64_t)
  end subroutine panic

  ! The policy, in order, and the order is the point:
  !   quiesce -- report -- park, with the record latched BEFORE anything that
  !   can itself fault, and a re-entrancy guard between the two.
  subroutine panic_code(msg, code) bind(c, name="fk_panic_code")
    implicit none
    character(kind=c_char), intent(in)        :: msg(*)
    integer(c_int64_t),     intent(in), value :: code
    integer(c_int64_t) :: depth

    call fk_cli()

    depth = fk_panic_state(1) + 1_c_int64_t
    fk_panic_state(1) = depth
    fk_panic_state(0) = FK_PANIC_MAGIC
    fk_panic_state(2) = code
    fk_panic_state(3) = msg_head(msg)

    ! A panic raised by the reporting path itself must not re-enter it: the
    ! second report would fault in the same place and recurse until the stack
    ! walks through the guard page.  Depth is latched above, so the record still
    ! carries how deep it got.
    if (depth > 1_c_int64_t) call fk_cpu_halt()

    call idt_set_panic_colors()

    call serial_print_string(FK_PANIC_BANNER)
    call serial_print_string(msg)
    call serial_print_string(FK_PANIC_CODE_TAG)
    call serial_print_hex(code, 16_c_int32_t)
    call serial_print_string(FK_PANIC_TAIL)

    call console_write(FK_PANIC_BANNER, FK_PANIC_MAX)
    call console_write(msg, FK_PANIC_MAX)
    call console_write(FK_PANIC_CODE_TAG, FK_PANIC_MAX)
    call console_print_hex(code, 16_c_int32_t)
    call console_write(FK_PANIC_TAIL, FK_PANIC_MAX)

    call fk_cpu_halt()
  end subroutine panic_code

end module fk_panic_m
