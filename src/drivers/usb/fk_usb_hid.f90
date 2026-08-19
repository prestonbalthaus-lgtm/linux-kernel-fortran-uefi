! SPDX-License-Identifier: GPL-2.0
! The HID boot keyboard report, decoded to ASCII.  Roadmap 5.2.
!
! Pure arithmetic: no MMIO, no state the controller can see, nothing that needs
! a machine.  That is deliberate -- it is the half of 5.2 a host test can hold
! an opinion about, and tests/drivers/usb/test_usb_hid.c holds it.
!
! BOOT PROTOCOL, HID 1.11 appendix B.1.  Eight bytes: a modifier bitmap, one
! reserved byte, then six usage ids.  The six are a ROLLOVER SET and not a
! queue -- a key held down reappears in every report until it is released -- so
! translating a report to keystrokes needs the PREVIOUS report to subtract, and
! that is the caller's job.  This module answers one question about one usage.
!
! Usage ids are from the HID Usage Tables Keyboard/Keypad page (0x07).  The
! mapping from usage to KEY is the specification's; the mapping from key to
! ASCII is a US layout and is this kernel's own choice.
module fk_usb_hid_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private

  public :: hid_ascii, hid_is_shift, hid_is_ctrl
  public :: FK_HID_USAGE_A, FK_HID_USAGE_0, FK_HID_USAGE_ENTER, &
            FK_HID_USAGE_SLASH, FK_HID_USAGE_CAPS
  public :: FK_HID_MOD_LCTRL_BIT, FK_HID_MOD_LSHIFT_BIT, FK_HID_MOD_LALT_BIT, &
            FK_HID_MOD_LGUI_BIT, FK_HID_MOD_RCTRL_BIT, FK_HID_MOD_RSHIFT_BIT, &
            FK_HID_MOD_RALT_BIT, FK_HID_MOD_RGUI_BIT

  ! Modifier byte, HID 1.11 table in appendix B.1: left half in 3:0, right in 7:4.
  integer(c_int32_t), parameter :: FK_HID_MOD_LCTRL_BIT  = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_HID_MOD_LSHIFT_BIT = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_HID_MOD_LALT_BIT   = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_HID_MOD_LGUI_BIT   = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_HID_MOD_RCTRL_BIT  = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_HID_MOD_RSHIFT_BIT = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_HID_MOD_RALT_BIT   = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_HID_MOD_RGUI_BIT   = 7_c_int32_t

  integer(c_int32_t), parameter :: FK_HID_USAGE_A     = int(z'04', c_int32_t)
  integer(c_int32_t), parameter :: FK_HID_USAGE_0     = int(z'27', c_int32_t)
  integer(c_int32_t), parameter :: FK_HID_USAGE_ENTER = int(z'28', c_int32_t)
  integer(c_int32_t), parameter :: FK_HID_USAGE_ESC   = int(z'29', c_int32_t)
  integer(c_int32_t), parameter :: FK_HID_USAGE_BS    = int(z'2A', c_int32_t)
  integer(c_int32_t), parameter :: FK_HID_USAGE_TAB   = int(z'2B', c_int32_t)
  integer(c_int32_t), parameter :: FK_HID_USAGE_SPACE = int(z'2C', c_int32_t)
  integer(c_int32_t), parameter :: FK_HID_USAGE_MINUS = int(z'2D', c_int32_t)
  integer(c_int32_t), parameter :: FK_HID_USAGE_SLASH = int(z'38', c_int32_t)
  integer(c_int32_t), parameter :: FK_HID_USAGE_CAPS  = int(z'39', c_int32_t)

  ! 0x04 through 0x27: the letters in alphabetical order, then 1-9, then 0.
  ! The digit row is the reason this is one table and not two ranges -- 0 comes
  ! LAST in the usage page, not before 1.
  character(len=*), parameter :: ALNUM = &
       "abcdefghijklmnopqrstuvwxyz1234567890"
  character(len=*), parameter :: ALNUM_SHIFT = &
       "ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()"

  ! 0x2D through 0x38.  achar(92) rather than a literal backslash: KFLAGS
  ! carries no -fbackslash today, and a table whose correctness depends on that
  ! staying true is a table that breaks the day somebody adds it.
  ! 0x32 is the non-US hash key and answers as backslash on a US layout, which
  ! is what usbkbd.c does too -- it maps 0x31 and 0x32 to the same keycode 43.
  character(len=*), parameter :: PUNCT = &
       "-=[]" // achar(92) // achar(92) // ";'`,./"
  character(len=*), parameter :: PUNCT_SHIFT = '_+{}' // '||' // ':"~<>?'

  integer(c_int32_t), parameter :: ASCII_BS = 8_c_int32_t
  integer(c_int32_t), parameter :: ASCII_HT = 9_c_int32_t
  integer(c_int32_t), parameter :: ASCII_LF = 10_c_int32_t
  integer(c_int32_t), parameter :: ASCII_SP = 32_c_int32_t

contains

  function hid_is_shift(mods) result(v) bind(c, name="hid_is_shift")
    implicit none
    integer(c_int32_t), intent(in), value :: mods
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (btest(mods, FK_HID_MOD_LSHIFT_BIT) .or. &
        btest(mods, FK_HID_MOD_RSHIFT_BIT)) v = 1_c_int32_t
  end function hid_is_shift

  function hid_is_ctrl(mods) result(v) bind(c, name="hid_is_ctrl")
    implicit none
    integer(c_int32_t), intent(in), value :: mods
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (btest(mods, FK_HID_MOD_LCTRL_BIT) .or. &
        btest(mods, FK_HID_MOD_RCTRL_BIT)) v = 1_c_int32_t
  end function hid_is_ctrl

  ! The ASCII code for one usage id, or 0 for a usage this layout has no
  ! character for -- which includes every function key, every arrow, and the
  ! modifiers themselves.  CAPS applies to letters only: shift-caps-a is 'a',
  ! and shift-caps-1 is still '!'.
  function hid_ascii(usage, mods, caps) result(ch) bind(c, name="hid_ascii")
    implicit none
    integer(c_int32_t), intent(in), value :: usage, mods, caps
    integer(c_int32_t) :: ch, i, shifted, upper

    ch = 0_c_int32_t
    shifted = hid_is_shift(mods)

    if (usage >= FK_HID_USAGE_A .and. usage <= FK_HID_USAGE_0) then
       i = usage - FK_HID_USAGE_A + 1_c_int32_t
       upper = shifted
       ! A letter is upper case when exactly one of shift and caps is on.
       if (usage < FK_HID_USAGE_A + 26_c_int32_t .and. caps /= 0_c_int32_t) &
            upper = 1_c_int32_t - shifted
       if (upper /= 0_c_int32_t) then
          ch = iachar(ALNUM_SHIFT(i:i))
       else
          ch = iachar(ALNUM(i:i))
       end if
       return
    end if

    if (usage >= FK_HID_USAGE_MINUS .and. usage <= FK_HID_USAGE_SLASH) then
       i = usage - FK_HID_USAGE_MINUS + 1_c_int32_t
       if (shifted /= 0_c_int32_t) then
          ch = iachar(PUNCT_SHIFT(i:i))
       else
          ch = iachar(PUNCT(i:i))
       end if
       return
    end if

    select case (usage)
    case (FK_HID_USAGE_ENTER)
       ch = ASCII_LF
    case (FK_HID_USAGE_BS)
       ch = ASCII_BS
    case (FK_HID_USAGE_TAB)
       ch = ASCII_HT
    case (FK_HID_USAGE_SPACE)
       ch = ASCII_SP
    end select
  end function hid_ascii

end module fk_usb_hid_m
