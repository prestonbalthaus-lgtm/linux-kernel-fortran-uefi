! SPDX-License-Identifier: GPL-2.0
!> Fortran translation of linux-7.1.8 lib/bcd.c
!!
!! Original C signatures:
!!   unsigned      _bcd2bin(unsigned char val)
!!   unsigned char _bin2bcd(unsigned val)
!!
!! UNSIGNED-SAFETY NOTES (see docs plan, Global Constraints):
!!   * u8 -> integer(c_int8_t), u32 -> integer(c_int32_t). Fortran has no
!!     unsigned types, so the BIT PATTERN is carried in a signed integer and
!!     every operation used below is one whose semantics are bit-pattern
!!     identical to the unsigned C operation it replaces.
!!
!!   * _bcd2bin's `val` is an unsigned char. The c_int8_t dummy carries the
!!     same 8 bits, but INT(val, c_int32_t) SIGN-extends, so 0x80..0xFF would
!!     arrive as negative. Every use therefore goes through
!!         v = iand(int(val, c_int32_t), 255)
!!     which re-creates C's integer promotion of an unsigned char (0..255).
!!     Without the mask, `val >> 4` on e.g. 0x99 would yield 0x0FFFFFF9
!!     instead of 9. C promotes `val` to int before `&`/`>>`, and since the
!!     promoted value is always 0..255 the shift is a plain zero-fill shift;
!!     SHIFTR reproduces it. (SHIFTA would be wrong on the masked value only
!!     if the mask were omitted -- SHIFTR is used regardless, as the C
!!     operand is conceptually unsigned.)
!!     Result range is 15 + 15*10 = 165, so the u32 return never overflows.
!!
!!   * _bin2bcd operates on a full-range u32. `val * 103` WRAPS modulo 2**32
!!     for val >= 41698712 (the first val with val*103 >= 2**32). Two's
!!     complement signed multiplication has the identical low-32-bit pattern,
!!     and the build passes -fwrapv so the wrap is defined rather than UB.
!!     A 64-bit intermediate would NOT match here -- everything is kept in
!!     c_int32_t deliberately.
!!
!!   * `(val * 103) >> 10` is a shift of an *unsigned* int: zero fill. SHIFTR
!!     matches; SHIFTA would propagate the sign bit and corrupt every input
!!     whose product has bit 31 set.
!!
!!   * `t << 4` and `val - t * 10` are u32 operations that wrap; SHIFTL
!!     (zero fill, bits shifted out discarded) and two's-complement
!!     subtraction reproduce them bit for bit.
!!
!!   * The C function returns `unsigned char`, i.e. the low 8 bits of the u32
!!     expression `(t << 4) | (val - t * 10)`. The mask-then-bias sequence
!!         k = iand(res, 255);  if (k > 127) k = k - 256
!!     converts that byte to the c_int8_t of identical bit pattern without
!!     relying on out-of-range INT() truncation, which is not standard
!!     conforming.
!!
!!   * No lookup tables are used, so no 0-based array-indexing hazard arises.
module fk_bcd_m
  use, intrinsic :: iso_c_binding, only: c_int8_t, c_int32_t
  implicit none
  private
  public :: fk__bcd2bin, fk__bin2bcd

contains

  !> unsigned _bcd2bin(unsigned char val)
  function fk__bcd2bin(val) result(res) bind(c, name="fk__bcd2bin")
    implicit none
    integer(c_int8_t), intent(in), value :: val
    integer(c_int32_t)                   :: res
    integer(c_int32_t)                   :: v

    ! C promotes the unsigned char to int: value is 0..255. INT() on the
    ! signed c_int8_t sign-extends, so mask the low 8 bits back out.
    v = iand(int(val, c_int32_t), 255_c_int32_t)

    ! return (val & 0x0f) + (val >> 4) * 10;
    res = iand(v, 15_c_int32_t) + shiftr(v, 4) * 10_c_int32_t
  end function fk__bcd2bin

  !> unsigned char _bin2bcd(unsigned val)
  function fk__bin2bcd(val) result(res) bind(c, name="fk__bin2bcd")
    implicit none
    integer(c_int32_t), intent(in), value :: val
    integer(c_int8_t)                     :: res
    integer(c_int32_t)                     :: t, wide, k

    ! const unsigned int t = (val * 103) >> 10;   -- multiply wraps mod 2**32,
    ! shift is a zero-fill (logical) shift of an unsigned value.
    t = shiftr(val * 103_c_int32_t, 10)

    ! return (t << 4) | (val - t * 10);   -- all u32, all wrapping.
    wide = ior(shiftl(t, 4), val - t * 10_c_int32_t)

    ! Truncate to unsigned char, keeping the bit pattern in a signed byte.
    k = iand(wide, 255_c_int32_t)
    if (k > 127_c_int32_t) k = k - 256_c_int32_t
    res = int(k, c_int8_t)
  end function fk__bin2bcd

end module fk_bcd_m
