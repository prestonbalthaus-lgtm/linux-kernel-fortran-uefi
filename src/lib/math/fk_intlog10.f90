! SPDX-License-Identifier: LGPL-2.1-or-later
!
! Derived from Linux 7.1.8 lib/math/int_log.c
! Original C authors retain copyright; this is a translation, not new work.
!> Fortran translation of linux-7.1.8 lib/math/int_log.c :: intlog10()
!!
!! Original C signature:  unsigned int intlog10(u32 value)      -> fk_intlog10
!! Helper, same translation unit and needed by it:
!!                        unsigned int intlog2(u32 value)       -> module-private
!!
!! intlog10() calls intlog2(), which is a file-scope function of the same
!! kernel .c, so both live in this one module. Only fk_intlog10 is exported
!! with bind(c); the log2 helper stays module-private so its symbol cannot
!! collide with a separate intlog2 translation.
!!
!! UNSIGNED-SAFETY NOTES (Fortran has no unsigned types; the BIT PATTERN of a
!! u32/u64 is carried in a signed integer of the same width, and every operation
!! below is one whose result is bit-identical to the unsigned C one):
!!
!!  1. u32 -> integer(c_int32_t), u64 -> integer(c_int64_t).
!!  2. `significand >> 23` and `... >> 15` and `log >> 31` are shifts of
!!     UNSIGNED operands in C, i.e. zero-fill. They are SHIFTR here, never
!!     SHIFTA. This is load-bearing for the >> 15: the product
!!     `(significand & 0x7fffff) * diff` reaches 0x7fffff * 0x171 = 0xB87FFE8F,
!!     which has bit 31 SET. As a signed int32 that is negative, so SHIFTA
!!     would smear ones down and give a wrong interpolation. SHIFTR reproduces
!!     the C unsigned shift exactly.
!!  3. `x % ARRAY_SIZE(logtable)` with ARRAY_SIZE == 256 is a modulo of an
!!     UNSIGNED value by a power of two, so it is exactly IAND(x, 255). A
!!     Fortran MOD() on a bit pattern whose sign bit is set would be wrong;
!!     IAND is not. Same for `(logentry + 1) % 256`.
!!  4. No unsigned division by a non-power-of-two occurs anywhere, so the
!!     "signed divide of a high-bit-set value" trap does not arise.
!!  5. Multiplications/additions of u32 wrap modulo 2**32; two's-complement
!!     signed arithmetic has the identical bit pattern and the build passes
!!     -fwrapv, so the wrap is defined behaviour rather than UB.
!!  6. `u64 log = intlog2(value)` is a widening of an UNSIGNED int, i.e. zero
!!     extension. int(x, c_int64_t) sign-extends, so the result is masked with
!!     0xFFFFFFFF. (intlog2's result is in fact always < 2**31 here, but the
!!     mask makes the zero-extension explicit rather than accidental.)
!!  7. Narrowing the u64 product back to the `unsigned int` return value is
!!     done by masking to 32 bits and folding the range down to int32 by hand,
!!     avoiding an out-of-range INT() conversion.
!!
!! INDEXING NOTES:
!!  * logtable is a C array indexed 0..255, so it is declared with an EXPLICIT
!!    lower bound: logtable(0:255). Fortran's default 1-based bound would shift
!!    every lookup by one entry.
!!  * The kernel table is `static const unsigned short`. It is stored here as
!!    integer(c_int32_t) holding the ZERO-EXTENDED value 0..0xFFFF, which is
!!    exactly what C's integer promotion of an `unsigned short` rvalue yields;
!!    every use of the table in the C source is such a promoted rvalue. Storing
!!    it as int16 would instead require reasoning about negative bit patterns at
!!    each of the three use sites.
!!  * `msb = fls(value) - 1` is the 0-based index of the most significant set
!!    bit. LEADZ is an inline bit-scan intrinsic (no libgfortran call), and for
!!    kind c_int32_t it counts within 32 bits, so msb = 31 - LEADZ(value). The
!!    value == 0 case is returned before this, matching the C early exit.
module fk_intlog10_m
  use iso_c_binding, only: c_int32_t, c_int64_t
  implicit none
  private
  public :: fk_intlog10

  !> lib/math/int_log.c :: logtable[256], zero-extended into int32.
  !! C index range 0..255 is preserved by the explicit lower bound.
  integer(c_int32_t), parameter :: logtable(0:255) = [ &
       int(z'0000'), int(z'0171'), int(z'02e0'), int(z'044e'), int(z'05ba'), int(z'0725'), int(z'088e'), int(z'09f7'), &
       int(z'0b5d'), int(z'0cc3'), int(z'0e27'), int(z'0f8a'), int(z'10eb'), int(z'124b'), int(z'13aa'), int(z'1508'), &
       int(z'1664'), int(z'17bf'), int(z'1919'), int(z'1a71'), int(z'1bc8'), int(z'1d1e'), int(z'1e73'), int(z'1fc6'), &
       int(z'2119'), int(z'226a'), int(z'23ba'), int(z'2508'), int(z'2656'), int(z'27a2'), int(z'28ed'), int(z'2a37'), &
       int(z'2b80'), int(z'2cc8'), int(z'2e0f'), int(z'2f54'), int(z'3098'), int(z'31dc'), int(z'331e'), int(z'345f'), &
       int(z'359f'), int(z'36de'), int(z'381b'), int(z'3958'), int(z'3a94'), int(z'3bce'), int(z'3d08'), int(z'3e41'), &
       int(z'3f78'), int(z'40af'), int(z'41e4'), int(z'4319'), int(z'444c'), int(z'457f'), int(z'46b0'), int(z'47e1'), &
       int(z'4910'), int(z'4a3f'), int(z'4b6c'), int(z'4c99'), int(z'4dc5'), int(z'4eef'), int(z'5019'), int(z'5142'), &
       int(z'526a'), int(z'5391'), int(z'54b7'), int(z'55dc'), int(z'5700'), int(z'5824'), int(z'5946'), int(z'5a68'), &
       int(z'5b89'), int(z'5ca8'), int(z'5dc7'), int(z'5ee5'), int(z'6003'), int(z'611f'), int(z'623a'), int(z'6355'), &
       int(z'646f'), int(z'6588'), int(z'66a0'), int(z'67b7'), int(z'68ce'), int(z'69e4'), int(z'6af8'), int(z'6c0c'), &
       int(z'6d20'), int(z'6e32'), int(z'6f44'), int(z'7055'), int(z'7165'), int(z'7274'), int(z'7383'), int(z'7490'), &
       int(z'759d'), int(z'76aa'), int(z'77b5'), int(z'78c0'), int(z'79ca'), int(z'7ad3'), int(z'7bdb'), int(z'7ce3'), &
       int(z'7dea'), int(z'7ef0'), int(z'7ff6'), int(z'80fb'), int(z'81ff'), int(z'8302'), int(z'8405'), int(z'8507'), &
       int(z'8608'), int(z'8709'), int(z'8809'), int(z'8908'), int(z'8a06'), int(z'8b04'), int(z'8c01'), int(z'8cfe'), &
       int(z'8dfa'), int(z'8ef5'), int(z'8fef'), int(z'90e9'), int(z'91e2'), int(z'92db'), int(z'93d2'), int(z'94ca'), &
       int(z'95c0'), int(z'96b6'), int(z'97ab'), int(z'98a0'), int(z'9994'), int(z'9a87'), int(z'9b7a'), int(z'9c6c'), &
       int(z'9d5e'), int(z'9e4f'), int(z'9f3f'), int(z'a02e'), int(z'a11e'), int(z'a20c'), int(z'a2fa'), int(z'a3e7'), &
       int(z'a4d4'), int(z'a5c0'), int(z'a6ab'), int(z'a796'), int(z'a881'), int(z'a96a'), int(z'aa53'), int(z'ab3c'), &
       int(z'ac24'), int(z'ad0c'), int(z'adf2'), int(z'aed9'), int(z'afbe'), int(z'b0a4'), int(z'b188'), int(z'b26c'), &
       int(z'b350'), int(z'b433'), int(z'b515'), int(z'b5f7'), int(z'b6d9'), int(z'b7ba'), int(z'b89a'), int(z'b97a'), &
       int(z'ba59'), int(z'bb38'), int(z'bc16'), int(z'bcf4'), int(z'bdd1'), int(z'bead'), int(z'bf8a'), int(z'c065'), &
       int(z'c140'), int(z'c21b'), int(z'c2f5'), int(z'c3cf'), int(z'c4a8'), int(z'c580'), int(z'c658'), int(z'c730'), &
       int(z'c807'), int(z'c8de'), int(z'c9b4'), int(z'ca8a'), int(z'cb5f'), int(z'cc34'), int(z'cd08'), int(z'cddc'), &
       int(z'ceaf'), int(z'cf82'), int(z'd054'), int(z'd126'), int(z'd1f7'), int(z'd2c8'), int(z'd399'), int(z'd469'), &
       int(z'd538'), int(z'd607'), int(z'd6d6'), int(z'd7a4'), int(z'd872'), int(z'd93f'), int(z'da0c'), int(z'dad9'), &
       int(z'dba5'), int(z'dc70'), int(z'dd3b'), int(z'de06'), int(z'ded0'), int(z'df9a'), int(z'e063'), int(z'e12c'), &
       int(z'e1f5'), int(z'e2bd'), int(z'e385'), int(z'e44c'), int(z'e513'), int(z'e5d9'), int(z'e69f'), int(z'e765'), &
       int(z'e82a'), int(z'e8ef'), int(z'e9b3'), int(z'ea77'), int(z'eb3b'), int(z'ebfe'), int(z'ecc1'), int(z'ed83'), &
       int(z'ee45'), int(z'ef06'), int(z'efc8'), int(z'f088'), int(z'f149'), int(z'f209'), int(z'f2c8'), int(z'f387'), &
       int(z'f446'), int(z'f505'), int(z'f5c3'), int(z'f680'), int(z'f73e'), int(z'f7fb'), int(z'f8b7'), int(z'f973'), &
       int(z'fa2f'), int(z'faea'), int(z'fba5'), int(z'fc60'), int(z'fd1a'), int(z'fdd4'), int(z'fe8e'), int(z'ff47')  ]

contains

  !> lib/math/int_log.c :: intlog2()  --  returns log2(value) * 2**24.
  !! Module-private: it exists only because intlog10() calls it. Not bind(c),
  !! so gfortran gives it a module-mangled symbol that cannot clash with a
  !! standalone intlog2 translation.
  function fk_intlog2_impl(value) result(res)
    implicit none
    integer(c_int32_t), intent(in) :: value
    integer(c_int32_t)             :: res
    integer(c_int32_t) :: msb, logentry, significand, interpolation, diff

    ! if (unlikely(value == 0)) { WARN_ON(1); return 0; }
    if (value == 0_c_int32_t) then
       res = 0_c_int32_t
       return
    end if

    ! msb = fls(value) - 1;   fls(v) = 32 - leadz(v)  for a non-zero u32
    msb = 31_c_int32_t - int(leadz(value), c_int32_t)

    ! significand = value << (31 - msb);   0 <= 31-msb <= 31, so never a
    ! shift-by-width. u32 << is SHIFTL.
    significand = shiftl(value, 31_c_int32_t - msb)

    ! logentry = (significand >> 23) % 256;   unsigned >> is SHIFTR (zero
    ! fill) and % 256 on an unsigned is IAND(.., 255).
    logentry = iand(shiftr(significand, 23), 255_c_int32_t)

    ! diff = (logtable[(logentry + 1) % 256] - logtable[logentry]) & 0xffff
    ! The C subtraction happens in int after promotion; the & 0xffff keeps the
    ! low 16 bits, which is the u16 wrap the comment calls the "overflow
    ! correction if logtable_next is 256" (logentry == 255 wraps to entry 0).
    diff = iand(logtable(iand(logentry + 1_c_int32_t, 255_c_int32_t)) - logtable(logentry), &
                int(z'FFFF', c_int32_t))

    ! interpolation = ((significand & 0x7fffff) * diff) >> 15;
    ! u32 multiply (wraps, -fwrapv) then an UNSIGNED >> : SHIFTR, not SHIFTA.
    ! The product's bit 31 can be set, which is exactly where SHIFTA breaks.
    interpolation = shiftr(iand(significand, int(z'7FFFFF', c_int32_t)) * diff, 15)

    ! return (msb << 24) + (logtable[logentry] << 8) + interpolation;
    res = shiftl(msb, 24) + shiftl(logtable(logentry), 8) + interpolation
  end function fk_intlog2_impl

  !> lib/math/int_log.c :: intlog10()  --  returns log10(value) * 2**24.
  function fk_intlog10(value) result(res) bind(c, name="fk_intlog10")
    implicit none
    integer(c_int32_t), intent(in), value :: value
    integer(c_int32_t)                    :: res
    integer(c_int64_t) :: log64, prod
    integer(c_int64_t), parameter :: mask32 = int(z'FFFFFFFF', c_int64_t)

    ! if (unlikely(value == 0)) { WARN_ON(1); return 0; }
    if (value == 0_c_int32_t) then
       res = 0_c_int32_t
       return
    end if

    ! u64 log = intlog2(value);   widening an unsigned int == zero extension.
    log64 = iand(int(fk_intlog2_impl(value), c_int64_t), mask32)

    ! return (log * 646456993) >> 31;   log10(x) = log2(x) * log10(2).
    ! Both operands are non-negative and the product is < 2**59, so the u64
    ! multiply cannot wrap; the shift is still SHIFTR to model the unsigned >>.
    prod = shiftr(log64 * 646456993_c_int64_t, 31)

    ! Narrow to `unsigned int`: keep the low 32 bits, then map 2**31..2**32-1
    ! onto the negative int32 half rather than letting INT() go out of range.
    prod = iand(prod, mask32)
    if (prod > int(z'7FFFFFFF', c_int64_t)) prod = prod - (mask32 + 1_c_int64_t)
    res = int(prod, c_int32_t)
  end function fk_intlog10

end module fk_intlog10_m
