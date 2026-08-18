! SPDX-License-Identifier: GPL-2.0
! The MCFG table: where the PCIe configuration space is (roadmap 4.2).
!
! PCI Firmware Specification 3.0 section 4.1.2.  A standard 36-byte ACPI
! description header, then EIGHT RESERVED BYTES, and only then the array of
! 16-byte allocation entries.  Those eight bytes are the whole trap in this
! table: a decoder that starts the array at offset 36 reads the base address
! out of the reserved field, gets 0, and every later step fails somewhere far
! away from the cause.
!
! Cross-checked against vendor/linux-7.1.8/include/acpi/actbl1.h (struct
! acpi_table_mcfg and acpi_mcfg_allocation) and drivers/acpi/pci_mcfg.c.
!
! It takes a VIRTUAL address and reads through it, so a host test can point it
! at ordinary memory -- the split that made fk_madt_m testable.  Every field is
! assembled BYTE BY BYTE: nothing an ACPI table points at is aligned.  On this
! project's own BIOS path the RSDT sits at 0x7FFE2525.
module fk_mcfg_m
  use, intrinsic :: iso_c_binding, only: c_int8_t, c_int32_t, c_int64_t, &
                                         c_size_t, c_ptr, c_loc, c_f_pointer, &
                                         c_associated
  use fk_string_m, only: fk_memcmp
  implicit none
  private
  public :: FK_MCFG_OK, FK_MCFG_E_NULL, FK_MCFG_E_LEN, FK_MCFG_E_SIG, &
            FK_MCFG_E_CHECKSUM, FK_MCFG_E_TRUNC, FK_MCFG_E_TOO_MANY, &
            FK_MCFG_E_BUS_RANGE, FK_MCFG_E_NO_ALLOC, &
            FK_MCFG_MAX_ALLOC, FK_MCFG_MIN_LEN, FK_MCFG_LEN_MAX, &
            FK_MCFG_ENTRY_LEN, FK_MCFG_BUS_SHIFT, &
            mcfg_parse, mcfg_count, mcfg_base, mcfg_segment, &
            mcfg_bus_start, mcfg_bus_end, mcfg_bytes

  integer(c_int32_t), parameter :: FK_MCFG_OK           = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_MCFG_E_NULL       = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_MCFG_E_LEN        = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_MCFG_E_SIG        = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_MCFG_E_CHECKSUM   = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_MCFG_E_TRUNC      = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_MCFG_E_TOO_MANY   = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_MCFG_E_BUS_RANGE  = 7_c_int32_t
  integer(c_int32_t), parameter :: FK_MCFG_E_NO_ALLOC   = 8_c_int32_t

  integer(c_int32_t), parameter :: FK_MCFG_MAX_ALLOC = 8_c_int32_t
  ! 36 header + 8 reserved.  A table this length declares no allocations at
  ! all, which is malformed rather than empty: firmware that emits MCFG is
  ! saying an ECAM window exists.
  integer(c_int32_t), parameter :: FK_MCFG_MIN_LEN   = 44_c_int32_t
  integer(c_int32_t), parameter :: FK_MCFG_LEN_MAX   = 4096_c_int32_t
  integer(c_int32_t), parameter :: FK_MCFG_ENTRY_LEN = 16_c_int32_t
  ! One bus is 32 devices * 8 functions * 4096 bytes = 1 MiB.
  integer(c_int32_t), parameter :: FK_MCFG_BUS_SHIFT = 20_c_int32_t

  integer(c_int32_t), parameter :: OFF_LEN    =  4_c_int32_t
  ! actbl1.h: the header is 36 bytes and acpi_table_mcfg adds a
  ! u8 reserved[8] before the allocation array starts.
  integer(c_int32_t), parameter :: OFF_ALLOC  = 44_c_int32_t
  ! Within one allocation entry, actbl1.h struct acpi_mcfg_allocation.
  integer(c_int32_t), parameter :: EOFF_BASE   =  0_c_int32_t
  integer(c_int32_t), parameter :: EOFF_SEG    =  8_c_int32_t
  integer(c_int32_t), parameter :: EOFF_BUS_LO = 10_c_int32_t
  integer(c_int32_t), parameter :: EOFF_BUS_HI = 11_c_int32_t

  integer(c_int64_t), parameter :: U32_MASK = int(z'FFFFFFFF', c_int64_t)

  integer(c_int8_t), target, save :: SIG_MCFG(0:3) = &
       [77_c_int8_t, 67_c_int8_t, 70_c_int8_t, 71_c_int8_t]

  integer(c_int8_t), pointer :: tab(:) => null()
  integer(c_int32_t), save :: tlen  = 0_c_int32_t
  integer(c_int32_t), save :: nallo = 0_c_int32_t
  integer(c_int64_t), save :: a_base(0:FK_MCFG_MAX_ALLOC - 1) = 0_c_int64_t
  integer(c_int32_t), save :: a_seg(0:FK_MCFG_MAX_ALLOC - 1)  = 0_c_int32_t
  integer(c_int32_t), save :: a_lo(0:FK_MCFG_MAX_ALLOC - 1)   = 0_c_int32_t
  integer(c_int32_t), save :: a_hi(0:FK_MCFG_MAX_ALLOC - 1)   = 0_c_int32_t

contains

  ! c_int8_t is signed, so 0xFF arrives as -1.  Without this mask every byte
  ! from 0x80 up poisons the whole assembled field with sign bits -- and the
  ! ECAM base is the field where that matters most, because 0xB0000000 has
  ! bit 31 set and a 64-bit assembly built from sign-extended halves gives an
  ! address 4 GiB away from the window.
  function db(off) result(v)
    implicit none
    integer(c_int32_t), intent(in) :: off
    integer(c_int32_t) :: v

    v = iand(int(tab(off + 1_c_int32_t), c_int32_t), 255_c_int32_t)
  end function db

  function d16(off) result(v)
    implicit none
    integer(c_int32_t), intent(in) :: off
    integer(c_int32_t) :: v

    v = ior(db(off), shiftl(db(off + 1_c_int32_t), 8))
  end function d16

  function d32(off) result(v)
    implicit none
    integer(c_int32_t), intent(in) :: off
    integer(c_int32_t) :: v

    v = ior(ior(db(off), shiftl(db(off + 1_c_int32_t), 8)), &
            ior(shiftl(db(off + 2_c_int32_t), 16), &
                shiftl(db(off + 3_c_int32_t), 24)))
  end function d32

  ! Masked AFTER the widening: int() on a value with bit 31 set sign-extends
  ! it across the whole upper half.
  function wide(v) result(w)
    implicit none
    integer(c_int32_t), intent(in) :: v
    integer(c_int64_t) :: w

    w = iand(int(v, c_int64_t), U32_MASK)
  end function wide

  function d64(off) result(v)
    implicit none
    integer(c_int32_t), intent(in) :: off
    integer(c_int64_t) :: v

    v = ior(wide(d32(off)), shiftl(wide(d32(off + 4_c_int32_t)), 32))
  end function d64

  subroutine reset()
    implicit none

    nullify(tab)
    tlen  = 0_c_int32_t
    nallo = 0_c_int32_t
    a_base = 0_c_int64_t
    a_seg  = 0_c_int32_t
    a_lo   = 0_c_int32_t
    a_hi   = 0_c_int32_t
  end subroutine reset

  function mcfg_parse(virt, len) result(status) bind(c, name="mcfg_parse")
    implicit none
    integer(c_int64_t), intent(in), value :: virt
    integer(c_int32_t), intent(in), value :: len
    integer(c_int32_t) :: status
    type(c_ptr) :: p

    ! Every failure leaves the module in the state it starts in, so a caller
    ! that ignores the status reads zeros rather than a table a previous call
    ! latched.
    call reset()
    ! Signed, deliberately: len is this kernel's own count of mapped bytes, so
    ! bit 31 set is a caller bug and not a 2 GiB table.
    if (len < FK_MCFG_MIN_LEN .or. len > FK_MCFG_LEN_MAX) then
       status = FK_MCFG_E_LEN
       return
    end if
    p = transfer(virt, p)
    if (.not. c_associated(p)) then
       status = FK_MCFG_E_NULL
       return
    end if
    call c_f_pointer(p, tab, [len])
    tlen = len

    status = walk(p)
    if (status /= FK_MCFG_OK) call reset()
  end function mcfg_parse

  function walk(p) result(status)
    implicit none
    type(c_ptr), intent(in) :: p
    integer(c_int32_t) :: status, hlen, ck, i, n, off, lo, hi

    if (fk_memcmp(p, c_loc(SIG_MCFG), 4_c_size_t) /= 0_c_int32_t) then
       status = FK_MCFG_E_SIG
       return
    end if
    hlen = d32(OFF_LEN)
    ! One signed test covers both ends: a length field with bit 31 set is
    ! negative here and is refused with the too-short ones.
    if (hlen < FK_MCFG_MIN_LEN) then
       status = FK_MCFG_E_LEN
       return
    end if
    if (hlen > tlen) then
       status = FK_MCFG_E_TRUNC
       return
    end if

    ! Sum-mod-256 over the whole table, masked every step so the accumulator
    ! cannot overflow.  Note this sum is IDENTICAL for signed and unsigned
    ! bytes, so a clean checksum proves nothing about the sign handling in db.
    ck = 0_c_int32_t
    do i = 0_c_int32_t, hlen - 1_c_int32_t
       ck = iand(ck + db(i), 255_c_int32_t)
    end do
    if (ck /= 0_c_int32_t) then
       status = FK_MCFG_E_CHECKSUM
       return
    end if

    ! Whole entries only.  A trailing fragment is firmware disagreeing with
    ! itself about its own length, and reading it would run past hlen.
    n = (hlen - OFF_ALLOC) / FK_MCFG_ENTRY_LEN
    if (n <= 0_c_int32_t) then
       status = FK_MCFG_E_NO_ALLOC
       return
    end if
    if (n > FK_MCFG_MAX_ALLOC) then
       status = FK_MCFG_E_TOO_MANY
       return
    end if

    do i = 0_c_int32_t, n - 1_c_int32_t
       off = OFF_ALLOC + i * FK_MCFG_ENTRY_LEN
       lo  = db(off + EOFF_BUS_LO)
       hi  = db(off + EOFF_BUS_HI)
       if (hi < lo) then
          status = FK_MCFG_E_BUS_RANGE
          return
       end if
       a_base(i) = d64(off + EOFF_BASE)
       a_seg(i)  = d16(off + EOFF_SEG)
       a_lo(i)   = lo
       a_hi(i)   = hi
    end do
    nallo  = n
    status = FK_MCFG_OK
  end function walk

  function mcfg_count() result(n) bind(c, name="mcfg_count")
    implicit none
    integer(c_int32_t) :: n

    n = nallo
  end function mcfg_count

  function mcfg_base(i) result(v) bind(c, name="mcfg_base")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (i < 0_c_int32_t .or. i >= nallo) return
    v = a_base(i)
  end function mcfg_base

  function mcfg_segment(i) result(v) bind(c, name="mcfg_segment")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (i < 0_c_int32_t .or. i >= nallo) return
    v = a_seg(i)
  end function mcfg_segment

  function mcfg_bus_start(i) result(v) bind(c, name="mcfg_bus_start")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (i < 0_c_int32_t .or. i >= nallo) return
    v = a_lo(i)
  end function mcfg_bus_start

  function mcfg_bus_end(i) result(v) bind(c, name="mcfg_bus_end")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (i < 0_c_int32_t .or. i >= nallo) return
    v = a_hi(i)
  end function mcfg_bus_end

  ! The window's size in bytes: one bus is 1 MiB, and the range is inclusive
  ! at both ends.  Computed rather than stored, because a size field is one
  ! more thing that can disagree with the bus numbers it was derived from.
  function mcfg_bytes(i) result(v) bind(c, name="mcfg_bytes")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (i < 0_c_int32_t .or. i >= nallo) return
    v = shiftl(int(a_hi(i) - a_lo(i) + 1_c_int32_t, c_int64_t), &
               FK_MCFG_BUS_SHIFT)
  end function mcfg_bytes

end module fk_mcfg_m
