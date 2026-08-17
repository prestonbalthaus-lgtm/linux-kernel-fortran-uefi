! SPDX-License-Identifier: GPL-2.0
! The UEFI path's memory map: the EFI_MEMORY_DESCRIPTOR array GetMemoryMap()
! returned (UEFI 7.2), presented as an iterator the PMM drives.  No bitmap, no
! allocation, no ownership -- this module only reads firmware's array.
!
! THE STRIDE IS A RUNTIME VALUE AND IS NOT sizeof(descriptor).  A descriptor is
! 40 bytes of fields; firmware reports DescriptorSize separately and commonly
! says 48.  Every offset below is computed from the reported stride, which is
! also why the array is read as bytes rather than through a bind(c) derived
! type -- a derived-type array would bake the 40 in at compile time.
module fk_efi_mmap_m
  use, intrinsic :: iso_c_binding, only: c_int8_t, c_int32_t, c_int64_t, &
                                         c_ptr, c_f_pointer, c_associated
  implicit none
  private
  public :: FK_EFI_DESC_MIN, FK_EFI_DESC_MAX, FK_EFI_MAX_DESCRIPTORS, &
            FK_EFI_PAGES_MAX, FK_EFI_BAD64, FK_EFI_BAD32, &
            FK_EFI_TYPE_CONVENTIONAL, &
            FK_EFI_OK, FK_EFI_E_BASE_NULL, FK_EFI_E_DESC_SIZE, &
            FK_EFI_E_TOO_MANY, FK_EFI_E_NOT_MULTIPLE, FK_EFI_E_NO_ENTRIES, &
            efi_mmap_set, efi_mmap_count, efi_mmap_base, efi_mmap_pages, &
            efi_mmap_type, efi_mmap_attr, efi_mmap_bytes, efi_type_is_ram

  ! UEFI 7.2 field offsets.  VirtualStart at 16 is deliberately unread: it is
  ! meaningful only after SetVirtualAddressMap, which this kernel never calls.
  integer(c_int64_t), parameter :: OFF_TYPE  = 0_c_int64_t
  integer(c_int64_t), parameter :: OFF_PHYS  = 8_c_int64_t
  integer(c_int64_t), parameter :: OFF_PAGES = 24_c_int64_t
  integer(c_int64_t), parameter :: OFF_ATTR  = 32_c_int64_t

  ! Below 40 the fields do not fit and the last descriptor's Attribute would be
  ! read past the end of the array.  The UPPER cap is not cosmetic either:
  ! FK_EFI_MAX_DESCRIPTORS * desc_size is the bound that makes the one division
  ! in efi_mmap_set legal, and it must not overflow.
  integer(c_int64_t), parameter :: FK_EFI_DESC_MIN = 40_c_int64_t
  integer(c_int64_t), parameter :: FK_EFI_DESC_MAX = 4096_c_int64_t

  ! Real OVMF maps run to a few dozen entries.  Overflow is refused, never
  ! truncated: a map this module silently shortened is a machine whose reserved
  ! tail the PMM would then hand out.
  integer(c_int64_t), parameter :: FK_EFI_MAX_DESCRIPTORS = 1024_c_int64_t

  ! EFI pages are 4 KiB, always (UEFI 7.2), regardless of the CPU's page size.
  integer(c_int32_t), parameter :: FK_EFI_PAGE_SHIFT = 12_c_int32_t

  ! 2^51-1: the largest NumberOfPages whose byte count still fits a
  ! non-negative signed 64-bit integer.  SHIFTR and never SHIFTA -- the operand
  ! is all-ones, and an arithmetic shift leaves it all-ones, which as an
  ! unsigned bound accepts every page count there is.
  integer(c_int64_t), parameter :: FK_EFI_PAGES_MAX = shiftr(not(0_c_int64_t), 13)

  integer(c_int64_t), parameter :: U32_MASK = int(z'FFFFFFFF', c_int64_t)

  ! Out-of-range index, and a byte count that would not fit.  All-ones is not a
  ! 4 KiB-aligned address, not an EFI memory type and not a plausible length.
  integer(c_int64_t), parameter :: FK_EFI_BAD64 = not(0_c_int64_t)
  integer(c_int32_t), parameter :: FK_EFI_BAD32 = not(0_c_int32_t)

  ! ONLY ConventionalMemory is free RAM.  LoaderCode/LoaderData hold this
  ! kernel and its boot information; BootServicesCode/Data are reclaimable in
  ! principle and not by this kernel.  Everything else is firmware's.  Both of
  ! the PMM's rounding directions err towards not allocating; so does this.
  integer(c_int32_t), parameter :: FK_EFI_TYPE_CONVENTIONAL = 7_c_int32_t

  integer(c_int32_t), parameter :: FK_EFI_OK             = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_EFI_E_BASE_NULL    = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_EFI_E_DESC_SIZE    = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_EFI_E_TOO_MANY     = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_EFI_E_NOT_MULTIPLE = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_EFI_E_NO_ENTRIES   = 5_c_int32_t

  integer(c_int8_t),  pointer :: map_b(:) => null()
  integer(c_int64_t), save    :: stride = 0_c_int64_t
  integer(c_int32_t), save    :: ndesc  = 0_c_int32_t
  integer(c_int32_t), save    :: ver    = 0_c_int32_t

contains

  ! Validate and latch the array.  EVERY failure leaves the module in the state
  ! it starts in, and the reset is before the first check rather than in each
  ! failing branch: a caller that ignores the status must read sentinels, not
  ! the map latched by a previous call.
  function efi_mmap_set(base, total_bytes, desc_size, desc_version) &
       result(status) bind(c, name="fk_efi_mmap_set")
    implicit none
    type(c_ptr),        intent(in), value :: base
    integer(c_int64_t), intent(in), value :: total_bytes, desc_size
    integer(c_int32_t), intent(in), value :: desc_version
    integer(c_int32_t) :: status

    nullify(map_b)
    stride = 0_c_int64_t
    ndesc  = 0_c_int32_t
    ! DescriptorVersion is recorded and not acted on: the offsets above are
    ! version 1's, and no firmware has shipped another.
    ver    = desc_version

    if (.not. c_associated(base)) then
       status = FK_EFI_E_BASE_NULL
       return
    end if

    ! BLT/BGT throughout: MapSize and DescriptorSize are UINTN, so a value with
    ! bit 63 set is enormous, not negative.
    if (blt(desc_size, FK_EFI_DESC_MIN) .or. &
        bgt(desc_size, FK_EFI_DESC_MAX)) then
       status = FK_EFI_E_DESC_SIZE
       return
    end if

    ! This bound is what makes the MOD and the divide below legal: past it,
    ! total_bytes is small and positive and cannot be a bit pattern carrying
    ! bit 63, on which a signed MOD would be meaningless.
    if (bgt(total_bytes, FK_EFI_MAX_DESCRIPTORS * desc_size)) then
       status = FK_EFI_E_TOO_MANY
       return
    end if
    if (mod(total_bytes, desc_size) /= 0_c_int64_t) then
       status = FK_EFI_E_NOT_MULTIPLE
       return
    end if
    if (total_bytes == 0_c_int64_t) then
       status = FK_EFI_E_NO_ENTRIES
       return
    end if

    call c_f_pointer(base, map_b, [int(total_bytes, c_int32_t)])
    stride = desc_size
    ndesc  = int(total_bytes / desc_size, c_int32_t)
    status = FK_EFI_OK
  end function efi_mmap_set

  function efi_mmap_count() result(n) bind(c, name="fk_efi_mmap_count")
    implicit none
    integer(c_int32_t) :: n

    n = ndesc
  end function efi_mmap_count

  ! --- reading the array ---------------------------------------------------
  ! Bytes, one at a time: the stride is a runtime value, so no field of any
  ! descriptor after the first has a guaranteed alignment.

  function db(off) result(v)
    implicit none
    integer(c_int64_t), intent(in) :: off
    integer(c_int32_t) :: v

    ! c_int8_t is signed, so 0xFF arrives as -1.
    v = iand(int(map_b(off + 1_c_int64_t), c_int32_t), 255_c_int32_t)
  end function db

  function d32(off) result(v)
    implicit none
    integer(c_int64_t), intent(in) :: off
    integer(c_int32_t) :: v

    v = ior(ior(db(off), shiftl(db(off + 1_c_int64_t), 8)), &
            ior(shiftl(db(off + 2_c_int64_t), 16), &
                shiftl(db(off + 3_c_int64_t), 24)))
  end function d32

  function d64(off) result(v)
    implicit none
    integer(c_int64_t), intent(in) :: off
    integer(c_int64_t) :: v

    ! Mask after widening: d32 returns a bit pattern, and int() on one with
    ! bit 31 set sign-extends it across the whole upper half.
    v = ior(iand(int(d32(off), c_int64_t), U32_MASK), &
            shiftl(iand(int(d32(off + 4_c_int64_t), c_int64_t), U32_MASK), 32))
  end function d64

  ! The ONLY place a descriptor's position is computed, and it multiplies by
  ! the stride firmware reported.  -1 for an index outside the array.
  function d_off(i) result(off)
    implicit none
    integer(c_int32_t), intent(in) :: i
    integer(c_int64_t) :: off

    off = -1_c_int64_t
    if (i >= 0_c_int32_t .and. i < ndesc) off = int(i, c_int64_t) * stride
  end function d_off

  ! --- accessors, index 0-based ---------------------------------------------

  function efi_mmap_base(i) result(v) bind(c, name="fk_efi_mmap_base")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t) :: v, off

    off = d_off(i)
    if (off < 0_c_int64_t) then
       v = FK_EFI_BAD64
    else
       v = d64(off + OFF_PHYS)
    end if
  end function efi_mmap_base

  function efi_mmap_pages(i) result(v) bind(c, name="fk_efi_mmap_pages")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t) :: v, off

    off = d_off(i)
    if (off < 0_c_int64_t) then
       v = FK_EFI_BAD64
    else
       v = d64(off + OFF_PAGES)
    end if
  end function efi_mmap_pages

  function efi_mmap_attr(i) result(v) bind(c, name="fk_efi_mmap_attr")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t) :: v, off

    off = d_off(i)
    if (off < 0_c_int64_t) then
       v = FK_EFI_BAD64
    else
       v = d64(off + OFF_ATTR)
    end if
  end function efi_mmap_attr

  function efi_mmap_type(i) result(v) bind(c, name="fk_efi_mmap_type")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v
    integer(c_int64_t) :: off

    off = d_off(i)
    if (off < 0_c_int64_t) then
       v = FK_EFI_BAD32
    else
       v = d32(off + OFF_TYPE)
    end if
  end function efi_mmap_type

  ! NumberOfPages * 4096, REFUSED rather than clamped or wrapped when the
  ! product would need bit 63.  BGT and not >: NumberOfPages is a UINT64, and a
  ! signed compare calls every count above 2^63 small.
  function efi_mmap_bytes(i) result(v) bind(c, name="fk_efi_mmap_bytes")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t) :: v, off, pages

    off = d_off(i)
    if (off < 0_c_int64_t) then
       v = FK_EFI_BAD64
       return
    end if
    pages = d64(off + OFF_PAGES)
    if (bgt(pages, FK_EFI_PAGES_MAX)) then
       v = FK_EFI_BAD64
    else
       v = shiftl(pages, FK_EFI_PAGE_SHIFT)
    end if
  end function efi_mmap_bytes

  function efi_type_is_ram(t) result(r) bind(c, name="fk_efi_type_is_ram")
    implicit none
    integer(c_int32_t), intent(in), value :: t
    integer(c_int32_t) :: r

    r = 0_c_int32_t
    if (t == FK_EFI_TYPE_CONVENTIONAL) r = 1_c_int32_t
  end function efi_type_is_ram

end module fk_efi_mmap_m
