! SPDX-License-Identifier: GPL-2.0
! Text console on the GOP framebuffer -- roadmap 2.4.
!
! Cell geometry and cursor state only.  Every pixel is the renderer's; every
! byte of font is fk_font_8x16's.  The split is what makes this module
! host-testable against a reference model with no framebuffer at all.
!
! THE SCROLL IS WIDER THAN THE GRID, and it is stated because it is visible.
! vga_scroll_up moves and refills whole SCANLINES, while console_clear paints
! only cols*FONT_W.  On a framebuffer whose width is not a whole number of 8
! pixel cells, the leftover columns on the right are scrolled but never
! cleared.  The band above the console is not affected -- org_y bounds the
! scroll -- so what this costs is at most seven columns of stale pixels on a
! screen this kernel does not otherwise draw in.
!
! REENTRANCY.  console_putc is not atomic: a glyph is sixteen scanline writes
! and a scroll is a whole screen.  Once roadmap 4.0's scheduler preempts on the
! timer, a tick landing between two of them leaves the next thread drawing at a
! cursor that has moved under it.  The public entry points therefore run with
! IF clear and restore the caller's IF on the way out -- restore, not blanket
! STI, because the panic handler calls in here with interrupts already off and
! must not have them turned back on underneath it.
module fk_console_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t, c_char, &
                                         c_null_char
  use fk_font_8x16_m,    only: FONT_W, FONT_H
  use fk_gop_renderer_m, only: vga_print_char, vga_fill_rect, vga_scroll_up
  implicit none
  private
  public :: console_init, console_putc, console_write, console_print_hex, &
            console_clear, console_set_color, console_newline, &
            console_cols, console_rows, console_x, console_y, console_ready, &
            fk_console_scrolls, &
            FK_CON_OK, FK_CON_E_GEOMETRY, FK_CON_TAB

  integer(c_int32_t), parameter :: FK_CON_OK         =  0_c_int32_t
  integer(c_int32_t), parameter :: FK_CON_E_GEOMETRY = -1_c_int32_t

  integer(c_int32_t), parameter :: FK_CON_TAB = 8_c_int32_t

  integer(c_int32_t), parameter :: ASCII_BS  =  8_c_int32_t
  integer(c_int32_t), parameter :: ASCII_HT  =  9_c_int32_t
  integer(c_int32_t), parameter :: ASCII_LF  = 10_c_int32_t
  integer(c_int32_t), parameter :: ASCII_CR  = 13_c_int32_t
  integer(c_int32_t), parameter :: ASCII_SP  = 32_c_int32_t

  integer(c_int32_t), save :: cols  = 0_c_int32_t
  integer(c_int32_t), save :: rows  = 0_c_int32_t
  integer(c_int32_t), save :: cx    = 0_c_int32_t
  integer(c_int32_t), save :: cy    = 0_c_int32_t
  integer(c_int32_t), save :: org_y = 0_c_int32_t
  integer(c_int32_t), save :: fg    = 0_c_int32_t
  integer(c_int32_t), save :: bg    = 0_c_int32_t
  logical,            save :: armed = .false.

  ! How many scroll operations have happened.  Read from outside the guest, so
  ! "the console wrapped and scrolled" is a fact about the machine rather than
  ! a line the kernel printed about itself.  VOLATILE and bind(c) for the
  ! reason fk_pit_m states: a cross-module accessor over a volatile is treated
  ! as side-effect-free by gfortran 16.1.1 and its result gets reused.
  integer(c_int64_t), volatile, bind(c, name="fk_console_scrolls") :: &
       fk_console_scrolls = 0_c_int64_t

  character(kind=c_char, len=*), parameter :: HEX = "0123456789ABCDEF"

  interface
    function fk_read_rflags() result(v) bind(c, name="fk_read_rflags")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: v
    end function fk_read_rflags

    subroutine fk_irq_enable() bind(c, name="fk_irq_enable")
      implicit none
    end subroutine fk_irq_enable

    subroutine fk_irq_disable() bind(c, name="fk_irq_disable")
      implicit none
    end subroutine fk_irq_disable
  end interface

contains

  ! RFLAGS.IF is bit 9.
  function lock() result(saved)
    implicit none
    integer(c_int64_t) :: saved

    saved = fk_read_rflags()
    call fk_irq_disable()
  end function lock

  subroutine unlock(saved)
    implicit none
    integer(c_int64_t), intent(in) :: saved

    if (iand(saved, 512_c_int64_t) /= 0_c_int64_t) call fk_irq_enable()
  end subroutine unlock

  !> Take over the pixel band [top_y, height) as a character grid.
  !!
  !! WIDTH and HEIGHT are the renderer's, passed in rather than queried, so a
  !! host test can drive this module with no framebuffer behind it.  TOP_Y is
  !! how many pixel rows above the console belong to somebody else -- the boot
  !! status bar -- and is never scrolled through.
  function console_init(width, height, top_y, fg_color, bg_color) &
       result(status) bind(c, name="console_init")
    implicit none
    integer(c_int32_t), intent(in), value :: width, height, top_y
    integer(c_int32_t), intent(in), value :: fg_color, bg_color
    integer(c_int32_t) :: status
    integer(c_int32_t) :: c, r

    armed = .false.
    if (width <= 0_c_int32_t .or. height <= 0_c_int32_t .or. &
        top_y < 0_c_int32_t .or. top_y >= height) then
       status = FK_CON_E_GEOMETRY
       return
    end if

    ! Computed into locals and published only once the geometry is ACCEPTED:
    ! a refused console that had already overwritten cols/rows answers
    ! console_cols() with a number from a layout it is not using.
    c = width / FONT_W
    r = (height - top_y) / FONT_H
    if (c < 1_c_int32_t .or. r < 1_c_int32_t) then
       status = FK_CON_E_GEOMETRY
       return
    end if

    cols  = c
    rows  = r
    org_y = top_y
    fg    = fg_color
    bg    = bg_color
    armed = .true.
    call console_clear()
    status = FK_CON_OK
  end function console_init

  subroutine console_set_color(fg_color, bg_color) &
       bind(c, name="console_set_color")
    implicit none
    integer(c_int32_t), intent(in), value :: fg_color, bg_color

    fg = fg_color
    bg = bg_color
  end subroutine console_set_color

  subroutine console_clear() bind(c, name="console_clear")
    implicit none
    integer(c_int64_t) :: saved

    if (.not. armed) return
    saved = lock()
    call vga_fill_rect(0_c_int32_t, org_y, cols * FONT_W, rows * FONT_H, bg)
    cx = 0_c_int32_t
    cy = 0_c_int32_t
    call unlock(saved)
  end subroutine console_clear

  subroutine console_newline() bind(c, name="console_newline")
    implicit none
    integer(c_int64_t) :: saved

    if (.not. armed) return
    saved = lock()
    call nl()
    call unlock(saved)
  end subroutine console_newline

  ! Cursor motion only.  Every caller below is already holding the lock.
  subroutine nl()
    implicit none

    cx = 0_c_int32_t
    cy = cy + 1_c_int32_t
    if (cy >= rows) then
       cy = rows - 1_c_int32_t
       call vga_scroll_up(org_y, rows * FONT_H, FONT_H, bg)
       fk_console_scrolls = fk_console_scrolls + 1_c_int64_t
    end if
  end subroutine nl

  subroutine put(code)
    implicit none
    integer(c_int32_t), intent(in) :: code
    integer(c_int32_t) :: next
    ! NOT `call vga_print_char(achar(code, c_char), ...)`, and this is a
    ! codegen constraint rather than style.  vga_print_char's first dummy is a
    ! bind(c) character(kind=c_char) with the VALUE attribute; handed a
    ! FUNCTION-RESULT expression, gfortran 16.1.1 materialises a temporary and
    ! passes its ADDRESS, while the callee reads the low byte of RDI as the
    ! character.  Every glyph on screen then becomes the same one -- the low
    ! byte of a stack address, constant per call site -- and cursor motion,
    ! wrapping and scrolling all stay perfectly correct, so nothing short of
    ! comparing pixels against the font sees it.  A plain variable is passed
    ! by value as the ABI requires.
    character(kind=c_char) :: glyph

    if (code == ASCII_CR) then
       cx = 0_c_int32_t
       return
    end if
    if (code == ASCII_LF) then
       call nl()
       return
    end if
    if (code == ASCII_BS) then
       if (cx > 0_c_int32_t) cx = cx - 1_c_int32_t
       return
    end if
    if (code == ASCII_HT) then
       ! To the next tab stop, and off the end of the line is a wrap like any
       ! other: a tab that landed exactly on the last column would otherwise
       ! leave the cursor one cell past the grid.
       next = (cx / FK_CON_TAB + 1_c_int32_t) * FK_CON_TAB
       if (next >= cols) then
          call nl()
       else
          cx = next
       end if
       return
    end if
    ! Anything below space that is not handled above is a control code with no
    ! glyph.  Printing the font's cell for it would put mojibake on screen.
    if (code < ASCII_SP) return

    ! Opaque cell: the renderer composes glyphs over what is already there, so
    ! without the fill a character overwriting another leaves both.
    call vga_fill_rect(cx * FONT_W, org_y + cy * FONT_H, FONT_W, FONT_H, bg)
    glyph = achar(code, c_char)
    call vga_print_char(glyph, cx * FONT_W, org_y + cy * FONT_H, fg)

    cx = cx + 1_c_int32_t
    if (cx >= cols) call nl()
  end subroutine put

  subroutine console_putc(c) bind(c, name="console_putc")
    implicit none
    character(kind=c_char), intent(in), value :: c
    integer(c_int64_t) :: saved

    if (.not. armed) return
    saved = lock()
    call put(iand(ichar(c, c_int32_t), 255_c_int32_t))
    call unlock(saved)
  end subroutine console_putc

  !> A NUL-terminated string, bounded by MAX_CHARS.
  !!
  !! ASSUMED-SIZE, never s(:): an assumed-shape dummy makes gfortran expect a
  !! CFI_cdesc_t where the caller passed a bare pointer.  Same constraint
  !! vga_print_string documents.
  subroutine console_write(s, max_chars) bind(c, name="console_write")
    implicit none
    character(kind=c_char), intent(in)        :: s(*)
    integer(c_int32_t),     intent(in), value :: max_chars
    integer(c_int32_t) :: i
    integer(c_int64_t) :: saved

    if (.not. armed) return
    if (max_chars <= 0_c_int32_t) return
    ! ONE critical section for the whole string, not one per character: a line
    ! half-printed by two threads is exactly what the lock exists to prevent.
    saved = lock()
    do i = 1_c_int32_t, max_chars
       if (s(i) == c_null_char) exit
       call put(iand(ichar(s(i), c_int32_t), 255_c_int32_t))
    end do
    call unlock(saved)
  end subroutine console_write

  !> V as DIGITS hex digits, most significant first.  The console's counterpart
  !! to serial_print_hex, so a verdict can go to both with the same shape.
  subroutine console_print_hex(v, digits) bind(c, name="console_print_hex")
    implicit none
    integer(c_int64_t), intent(in), value :: v
    integer(c_int32_t), intent(in), value :: digits
    integer(c_int32_t) :: i, nib
    integer(c_int64_t) :: saved

    if (.not. armed) return
    if (digits <= 0_c_int32_t .or. digits > 16_c_int32_t) return
    saved = lock()
    do i = digits - 1_c_int32_t, 0_c_int32_t, -1_c_int32_t
       ! ISHFT with a negative count is a LOGICAL right shift, so the sign bit
       ! of a high address does not smear across the top digits.
       nib = int(iand(ishft(v, -4_c_int32_t * i), 15_c_int64_t), c_int32_t)
       call put(ichar(HEX(nib + 1:nib + 1), c_int32_t))
    end do
    call unlock(saved)
  end subroutine console_print_hex

  function console_cols() result(v) bind(c, name="console_cols")
    implicit none
    integer(c_int32_t) :: v
    v = cols
  end function console_cols

  function console_rows() result(v) bind(c, name="console_rows")
    implicit none
    integer(c_int32_t) :: v
    v = rows
  end function console_rows

  function console_x() result(v) bind(c, name="console_x")
    implicit none
    integer(c_int32_t) :: v
    v = cx
  end function console_x

  function console_y() result(v) bind(c, name="console_y")
    implicit none
    integer(c_int32_t) :: v
    v = cy
  end function console_y

  function console_ready() result(v) bind(c, name="console_ready")
    implicit none
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (armed) v = 1_c_int32_t
  end function console_ready

end module fk_console_m
