! SPDX-License-Identifier: LGPL-2.1-or-later
!> Fortran translation of linux-7.1.8 lib/math/int_log.c :: intlog2()
!!
!! Original C signature:  unsigned int intlog2(u32 value)
!! Returns log2(value) * 2**24 as a fixed-point value; returns 0 for value == 0
!! (the C code hits WARN_ON(1) there, which is a no-op for the pure result).
!!
!! UNSIGNED-SAFETY NOTES
!!   * u32 -> integer(c_int32_t) and "unsigned int" -> integer(c_int32_t).
!!     Fortran has no unsigned types, so the BIT PATTERN travels in a signed
!!     integer and every operation below is one whose result is bit-identical
!!     to the unsigned C operation.
!!   * fls(value) is reproduced as 32 - LEADZ(value). LEADZ counts leading zero
!!     bits of the 32-bit pattern, so it is sign-agnostic: LEADZ(0x80000000)=0
!!     -> fls = 32 -> msb = 31, matching generic_fls().  fls(0) = 0 would make
!!     msb underflow to 0xFFFFFFFF, so the value == 0 early return must come
!!     FIRST, exactly as in the C.
!!   * "significand >> 23" is a shift of an unsigned int whose bit 31 is ALWAYS
!!     set (the msb was normalised to bit 31), i.e. the signed interpretation is
!!     always negative. SHIFTR (zero fill) is mandatory; SHIFTA would smear the
!!     sign bit and produce a garbage table index.
!!   * "value << (31 - msb)" -> SHIFTL. The shift count is 0..31, always a legal
!!     Fortran shift for a 32-bit integer.
!!   * "% ARRAY_SIZE(logtable)" with ARRAY_SIZE == 256 is a power-of-two modulo
!!     of an unsigned value -> IAND(x, 255). A signed MOD would be wrong for a
!!     high-bit-set operand; IAND is exact for both.
!!   * The C multiply "(significand & 0x7fffff) * diff" is an unsigned int
!!     multiply that wraps mod 2**32 before the ">> 15". It is done here in
!!     64-bit and then masked to 32 bits, so the wrap is modelled explicitly
!!     rather than relying on the sign of a 32-bit intermediate.
!!   * logtable[] is "unsigned short" in C but is promoted to int before the
!!     subtraction, so the difference may be NEGATIVE (it is, at the 255 -> 0
!!     wraparound: 0x0000 - 0xff47) and is then masked with 0xffff. The table is
!!     therefore held as non-negative integer(c_int32_t) values, which makes the
!!     Fortran subtraction and IAND(...,0xffff) match the C promotion exactly.
!!
!! ARRAY-INDEXING NOTE
!!   * logtable is a C array indexed 0..255. It is declared here with an
!!     explicit lower bound logtable(0:255) so the index arithmetic is a
!!     literal transcription of the C -- no +1 fixups anywhere.
module fk_intlog2_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t
  implicit none
  private
  public :: fk_intlog2

  !> Verbatim transcription of the 256-entry `static const unsigned short
  !! logtable[256]` from lib/math/int_log.c, in source order, index 0 first.
  integer(c_int32_t), parameter :: logtable(0:255) = [ &
       int(z'0000', c_int32_t), int(z'0171', c_int32_t), int(z'02e0', c_int32_t), int(z'044e', c_int32_t),  &
       int(z'05ba', c_int32_t), int(z'0725', c_int32_t), int(z'088e', c_int32_t), int(z'09f7', c_int32_t),  &
       int(z'0b5d', c_int32_t), int(z'0cc3', c_int32_t), int(z'0e27', c_int32_t), int(z'0f8a', c_int32_t),  &
       int(z'10eb', c_int32_t), int(z'124b', c_int32_t), int(z'13aa', c_int32_t), int(z'1508', c_int32_t),  &
       int(z'1664', c_int32_t), int(z'17bf', c_int32_t), int(z'1919', c_int32_t), int(z'1a71', c_int32_t),  &
       int(z'1bc8', c_int32_t), int(z'1d1e', c_int32_t), int(z'1e73', c_int32_t), int(z'1fc6', c_int32_t),  &
       int(z'2119', c_int32_t), int(z'226a', c_int32_t), int(z'23ba', c_int32_t), int(z'2508', c_int32_t),  &
       int(z'2656', c_int32_t), int(z'27a2', c_int32_t), int(z'28ed', c_int32_t), int(z'2a37', c_int32_t),  &
       int(z'2b80', c_int32_t), int(z'2cc8', c_int32_t), int(z'2e0f', c_int32_t), int(z'2f54', c_int32_t),  &
       int(z'3098', c_int32_t), int(z'31dc', c_int32_t), int(z'331e', c_int32_t), int(z'345f', c_int32_t),  &
       int(z'359f', c_int32_t), int(z'36de', c_int32_t), int(z'381b', c_int32_t), int(z'3958', c_int32_t),  &
       int(z'3a94', c_int32_t), int(z'3bce', c_int32_t), int(z'3d08', c_int32_t), int(z'3e41', c_int32_t),  &
       int(z'3f78', c_int32_t), int(z'40af', c_int32_t), int(z'41e4', c_int32_t), int(z'4319', c_int32_t),  &
       int(z'444c', c_int32_t), int(z'457f', c_int32_t), int(z'46b0', c_int32_t), int(z'47e1', c_int32_t),  &
       int(z'4910', c_int32_t), int(z'4a3f', c_int32_t), int(z'4b6c', c_int32_t), int(z'4c99', c_int32_t),  &
       int(z'4dc5', c_int32_t), int(z'4eef', c_int32_t), int(z'5019', c_int32_t), int(z'5142', c_int32_t),  &
       int(z'526a', c_int32_t), int(z'5391', c_int32_t), int(z'54b7', c_int32_t), int(z'55dc', c_int32_t),  &
       int(z'5700', c_int32_t), int(z'5824', c_int32_t), int(z'5946', c_int32_t), int(z'5a68', c_int32_t),  &
       int(z'5b89', c_int32_t), int(z'5ca8', c_int32_t), int(z'5dc7', c_int32_t), int(z'5ee5', c_int32_t),  &
       int(z'6003', c_int32_t), int(z'611f', c_int32_t), int(z'623a', c_int32_t), int(z'6355', c_int32_t),  &
       int(z'646f', c_int32_t), int(z'6588', c_int32_t), int(z'66a0', c_int32_t), int(z'67b7', c_int32_t),  &
       int(z'68ce', c_int32_t), int(z'69e4', c_int32_t), int(z'6af8', c_int32_t), int(z'6c0c', c_int32_t),  &
       int(z'6d20', c_int32_t), int(z'6e32', c_int32_t), int(z'6f44', c_int32_t), int(z'7055', c_int32_t),  &
       int(z'7165', c_int32_t), int(z'7274', c_int32_t), int(z'7383', c_int32_t), int(z'7490', c_int32_t),  &
       int(z'759d', c_int32_t), int(z'76aa', c_int32_t), int(z'77b5', c_int32_t), int(z'78c0', c_int32_t),  &
       int(z'79ca', c_int32_t), int(z'7ad3', c_int32_t), int(z'7bdb', c_int32_t), int(z'7ce3', c_int32_t),  &
       int(z'7dea', c_int32_t), int(z'7ef0', c_int32_t), int(z'7ff6', c_int32_t), int(z'80fb', c_int32_t),  &
       int(z'81ff', c_int32_t), int(z'8302', c_int32_t), int(z'8405', c_int32_t), int(z'8507', c_int32_t),  &
       int(z'8608', c_int32_t), int(z'8709', c_int32_t), int(z'8809', c_int32_t), int(z'8908', c_int32_t),  &
       int(z'8a06', c_int32_t), int(z'8b04', c_int32_t), int(z'8c01', c_int32_t), int(z'8cfe', c_int32_t),  &
       int(z'8dfa', c_int32_t), int(z'8ef5', c_int32_t), int(z'8fef', c_int32_t), int(z'90e9', c_int32_t),  &
       int(z'91e2', c_int32_t), int(z'92db', c_int32_t), int(z'93d2', c_int32_t), int(z'94ca', c_int32_t),  &
       int(z'95c0', c_int32_t), int(z'96b6', c_int32_t), int(z'97ab', c_int32_t), int(z'98a0', c_int32_t),  &
       int(z'9994', c_int32_t), int(z'9a87', c_int32_t), int(z'9b7a', c_int32_t), int(z'9c6c', c_int32_t),  &
       int(z'9d5e', c_int32_t), int(z'9e4f', c_int32_t), int(z'9f3f', c_int32_t), int(z'a02e', c_int32_t),  &
       int(z'a11e', c_int32_t), int(z'a20c', c_int32_t), int(z'a2fa', c_int32_t), int(z'a3e7', c_int32_t),  &
       int(z'a4d4', c_int32_t), int(z'a5c0', c_int32_t), int(z'a6ab', c_int32_t), int(z'a796', c_int32_t),  &
       int(z'a881', c_int32_t), int(z'a96a', c_int32_t), int(z'aa53', c_int32_t), int(z'ab3c', c_int32_t),  &
       int(z'ac24', c_int32_t), int(z'ad0c', c_int32_t), int(z'adf2', c_int32_t), int(z'aed9', c_int32_t),  &
       int(z'afbe', c_int32_t), int(z'b0a4', c_int32_t), int(z'b188', c_int32_t), int(z'b26c', c_int32_t),  &
       int(z'b350', c_int32_t), int(z'b433', c_int32_t), int(z'b515', c_int32_t), int(z'b5f7', c_int32_t),  &
       int(z'b6d9', c_int32_t), int(z'b7ba', c_int32_t), int(z'b89a', c_int32_t), int(z'b97a', c_int32_t),  &
       int(z'ba59', c_int32_t), int(z'bb38', c_int32_t), int(z'bc16', c_int32_t), int(z'bcf4', c_int32_t),  &
       int(z'bdd1', c_int32_t), int(z'bead', c_int32_t), int(z'bf8a', c_int32_t), int(z'c065', c_int32_t),  &
       int(z'c140', c_int32_t), int(z'c21b', c_int32_t), int(z'c2f5', c_int32_t), int(z'c3cf', c_int32_t),  &
       int(z'c4a8', c_int32_t), int(z'c580', c_int32_t), int(z'c658', c_int32_t), int(z'c730', c_int32_t),  &
       int(z'c807', c_int32_t), int(z'c8de', c_int32_t), int(z'c9b4', c_int32_t), int(z'ca8a', c_int32_t),  &
       int(z'cb5f', c_int32_t), int(z'cc34', c_int32_t), int(z'cd08', c_int32_t), int(z'cddc', c_int32_t),  &
       int(z'ceaf', c_int32_t), int(z'cf82', c_int32_t), int(z'd054', c_int32_t), int(z'd126', c_int32_t),  &
       int(z'd1f7', c_int32_t), int(z'd2c8', c_int32_t), int(z'd399', c_int32_t), int(z'd469', c_int32_t),  &
       int(z'd538', c_int32_t), int(z'd607', c_int32_t), int(z'd6d6', c_int32_t), int(z'd7a4', c_int32_t),  &
       int(z'd872', c_int32_t), int(z'd93f', c_int32_t), int(z'da0c', c_int32_t), int(z'dad9', c_int32_t),  &
       int(z'dba5', c_int32_t), int(z'dc70', c_int32_t), int(z'dd3b', c_int32_t), int(z'de06', c_int32_t),  &
       int(z'ded0', c_int32_t), int(z'df9a', c_int32_t), int(z'e063', c_int32_t), int(z'e12c', c_int32_t),  &
       int(z'e1f5', c_int32_t), int(z'e2bd', c_int32_t), int(z'e385', c_int32_t), int(z'e44c', c_int32_t),  &
       int(z'e513', c_int32_t), int(z'e5d9', c_int32_t), int(z'e69f', c_int32_t), int(z'e765', c_int32_t),  &
       int(z'e82a', c_int32_t), int(z'e8ef', c_int32_t), int(z'e9b3', c_int32_t), int(z'ea77', c_int32_t),  &
       int(z'eb3b', c_int32_t), int(z'ebfe', c_int32_t), int(z'ecc1', c_int32_t), int(z'ed83', c_int32_t),  &
       int(z'ee45', c_int32_t), int(z'ef06', c_int32_t), int(z'efc8', c_int32_t), int(z'f088', c_int32_t),  &
       int(z'f149', c_int32_t), int(z'f209', c_int32_t), int(z'f2c8', c_int32_t), int(z'f387', c_int32_t),  &
       int(z'f446', c_int32_t), int(z'f505', c_int32_t), int(z'f5c3', c_int32_t), int(z'f680', c_int32_t),  &
       int(z'f73e', c_int32_t), int(z'f7fb', c_int32_t), int(z'f8b7', c_int32_t), int(z'f973', c_int32_t),  &
       int(z'fa2f', c_int32_t), int(z'faea', c_int32_t), int(z'fba5', c_int32_t), int(z'fc60', c_int32_t),  &
       int(z'fd1a', c_int32_t), int(z'fdd4', c_int32_t), int(z'fe8e', c_int32_t), int(z'ff47', c_int32_t) ]

contains

  !> log2(value) * 2**24, fixed point. bind(c) name matches the kernel symbol.
  function fk_intlog2(value) result(res) bind(c, name="fk_intlog2")
    implicit none
    integer(c_int32_t), intent(in), value :: value
    integer(c_int32_t)                    :: res
    integer(c_int32_t) :: msb, logentry, significand, interpolation, diff
    integer(c_int64_t) :: prod

    ! if (unlikely(value == 0)) { WARN_ON(1); return 0; }
    if (value == 0_c_int32_t) then
       res = 0_c_int32_t
       return
    end if

    ! msb = fls(value) - 1;   fls(x) = 32 - leadz(x) for x /= 0
    msb = 31_c_int32_t - leadz(value)

    ! significand = value << (31 - msb);
    significand = shiftl(value, 31_c_int32_t - msb)

    ! logentry = (significand >> 23) % 256;   (zero-fill shift, mask not mod)
    logentry = iand(shiftr(significand, 23), 255_c_int32_t)

    ! (logtable[(logentry + 1) % 256] - logtable[logentry]) & 0xffff
    diff = iand(logtable(iand(logentry + 1_c_int32_t, 255_c_int32_t)) &
                - logtable(logentry), int(z'FFFF', c_int32_t))

    ! interpolation = ((significand & 0x7fffff) * diff) >> 15;  u32 wrap, then
    ! a zero-fill shift of the 32-bit unsigned product.
    prod = int(iand(significand, int(z'7FFFFF', c_int32_t)), c_int64_t) &
           * int(diff, c_int64_t)
    prod = iand(prod, int(z'FFFFFFFF', c_int64_t))
    interpolation = int(shiftr(prod, 15), c_int32_t)

    ! return ((msb << 24) + (logtable[logentry] << 8) + interpolation);
    res = shiftl(msb, 24) + shiftl(logtable(logentry), 8) + interpolation
  end function fk_intlog2

end module fk_intlog2_m
