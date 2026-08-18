! SPDX-License-Identifier: GPL-2.0
! Physical memory manager: the Multiboot2 memory map, and a bitmap of 4 KiB
! page frames (roadmap 3.4).  One bit per frame, 0 = free, 1 = used.
!
! THE IDENTITY-MAP DEPENDENCY, WHICH IS A DEADLINE AND NOT A DETAIL.
! The Multiboot information structure is at a PHYSICAL address the loader chose,
! and this module dereferences it.  That works only because boot/boot.S leaves
! PML4[0] mapping the low 1 GiB one-to-one, so a physical address below
! FK_PMM_IDMAP_BYTES is also a valid virtual one.  pmm_init must therefore run
! BEFORE roadmap 3.5 unmaps the identity window, and it refuses an MBI outside
! that window rather than taking a page fault it cannot explain.  Nothing else
! here dereferences physical memory: the allocator hands out addresses and never
! touches the frames, which is why it can manage RAM far above the 1 GiB the
! kernel can currently reach.
!
! WHY THE BITMAP IS STATIC .bss AND NOT PLACED IN DISCOVERED RAM.
! A real kernel puts the bitmap in memory it just found.  Doing that needs a
! writable mapping for an arbitrary physical address, which is exactly what does
! not exist until the VMM at 3.5 -- the boot stub maps 1 GiB and nothing else.
! A fixed array costs 2 MiB of .bss, which is NOLOAD, so it costs zero image
! bytes and one rep-stosq in boot/boot.S.  The price paid instead is a ceiling:
! FK_PMM_MAX_PHYS.  Memory above it is COUNTED and REPORTED (pmm_ignored_bytes)
! rather than silently dropped, because a PMM that quietly forgets a third of
! the machine's RAM is indistinguishable from one that works.
module fk_pmm_m
  use fk_efi_mmap_m, only: FK_EFI_OK, FK_EFI_BAD64, FK_EFI_TYPE_CONVENTIONAL, &
                           efi_mmap_set, efi_mmap_count, efi_mmap_base, &
                           efi_mmap_bytes, efi_mmap_type
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t, c_ptr, &
                                         c_f_pointer
  implicit none
  private
  public :: FK_PMM_PAGE_SIZE, FK_PMM_MAX_PHYS, FK_PMM_MAX_REGIONS, &
            FK_PMM_IDMAP_BYTES, &
            FK_PMM_FRONT_NONE, FK_PMM_FRONT_MB2, FK_PMM_FRONT_EFI, &
            pmm_front_end, &
            FK_PMM_TYPE_AVAILABLE, FK_PMM_TYPE_RESERVED, FK_PMM_TYPE_ACPI, &
            FK_PMM_TYPE_NVS, FK_PMM_TYPE_BADRAM, &
            FK_PMM_OK, FK_PMM_E_MBI_NULL, FK_PMM_E_MBI_ALIGN, &
            FK_PMM_E_MBI_RANGE, FK_PMM_E_MBI_SIZE, FK_PMM_E_TAG_OVERRUN, &
            FK_PMM_E_NO_MMAP, FK_PMM_E_ENTRY_SIZE, FK_PMM_E_TOO_MANY, &
            FK_PMM_E_NO_RAM, FK_PMM_E_NOT_READY, FK_PMM_E_UNALIGNED, &
            FK_PMM_E_RANGE, FK_PMM_E_NOT_RAM, FK_PMM_E_DOUBLE_FREE, &
            FK_PMM_E_LOCKED, &
            pmm_init, pmm_alloc_page, pmm_alloc_page_from, pmm_free_page, &
            pmm_alloc_contiguous, pmm_free_contiguous, pmm_page_is_free, &
            pmm_total_pages, pmm_free_pages, pmm_used_pages, &
            pmm_ignored_bytes, pmm_region_count, pmm_region_base, &
            pmm_region_len, pmm_region_type, pmm_verify_reserved, &
            pmm_verify_kernel_locked

  integer(c_int64_t), parameter :: FK_PMM_PAGE_SIZE  = 4096_c_int64_t
  integer(c_int32_t), parameter :: FK_PMM_PAGE_SHIFT = 12_c_int32_t

  ! The ceiling this module can describe.  64 GiB / 4 KiB = 16777216 frames,
  ! / 64 bits = 262144 quadwords = 2 MiB of .bss.  Raising it costs 32 KiB of
  ! .bss per additional GiB and nothing else.
  integer(c_int64_t), parameter :: FK_PMM_MAX_PHYS = 68719476736_c_int64_t
  integer(c_int32_t), parameter :: FK_PMM_PAGES = &
       int(FK_PMM_MAX_PHYS / FK_PMM_PAGE_SIZE, c_int32_t)
  integer(c_int32_t), parameter :: FK_PMM_WORDS = FK_PMM_PAGES / 64_c_int32_t

  ! MUST equal PD_ENTRIES * SIZE_2M in boot/boot.S.  There is no way to import
  ! an assembler constant, so it is duplicated and tools/linkscript-test.sh
  ! diffs the two -- the same arrangement KERNEL_VMA has had since roadmap 1.2,
  ! for the same reason: a silent divergence here makes this module accept an
  ! MBI pointer that is not mapped, and the read faults.
  integer(c_int64_t), parameter :: FK_PMM_IDMAP_BYTES = 1073741824_c_int64_t

  ! A Multiboot2 map is an e820 map; real ones hold well under 32 entries.
  ! Overflow is FATAL rather than truncating (see pmm_init): a display cap that
  ! doubles as a safety cap is how reserved memory gets handed out.
  integer(c_int32_t), parameter :: FK_PMM_MAX_REGIONS = 128_c_int32_t

  ! Sanity bound on the loader's own structure.  GRUB's is a few kilobytes.
  integer(c_int64_t), parameter :: FK_PMM_MBI_MAX = 16777216_c_int64_t

  ! Multiboot2 specification 3.6.  Only type 1 is usable; everything else --
  ! listed here or not -- is treated as reserved, which is why every test in
  ! this module asks whether a type IS available rather than which one it is.
  integer(c_int32_t), parameter :: FK_PMM_TYPE_AVAILABLE = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_TYPE_RESERVED  = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_TYPE_ACPI      = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_TYPE_NVS       = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_TYPE_BADRAM    = 5_c_int32_t

  integer(c_int32_t), parameter :: MB2_TAG_END  = 0_c_int32_t
  integer(c_int32_t), parameter :: MB2_TAG_MMAP = 6_c_int32_t
  ! Tag 17 is the array GetMemoryMap() returned, passed straight through by
  ! a loader that came up on UEFI.  Present ONLY on that path: a BIOS boot of
  ! the same image carries tag 6 and no 17, which is what makes the choice
  ! below a fact about the firmware rather than a build-time switch.
  integer(c_int32_t), parameter :: MB2_TAG_EFI_MMAP = 17_c_int32_t

  integer(c_int32_t), parameter :: FK_PMM_FRONT_NONE = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_FRONT_MB2  = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_FRONT_EFI  = 2_c_int32_t

  ! EFI types worth keeping apart once mapped onto this module's codes.
  ! Everything not named here is RESERVED, which is the conservative answer:
  ! LoaderData holds the kernel and the boot info, and BootServices memory is
  ! reclaimable in principle but not by a kernel that never called
  ! ExitBootServices itself.
  integer(c_int32_t), parameter :: EFI_TYPE_ACPI_RECLAIM = 9_c_int32_t
  integer(c_int32_t), parameter :: EFI_TYPE_ACPI_NVS     = 10_c_int32_t

  ! pmm_init failures.  Distinct values because "the PMM did not come up" is
  ! never a useful thing to print on a console that has one line to say it in.
  integer(c_int32_t), parameter :: FK_PMM_OK             = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_E_MBI_NULL     = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_E_MBI_ALIGN    = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_E_MBI_RANGE    = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_E_MBI_SIZE     = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_E_TAG_OVERRUN  = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_E_NO_MMAP      = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_E_ENTRY_SIZE   = 7_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_E_TOO_MANY     = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_E_NO_RAM       = 9_c_int32_t

  ! pmm_free_page refusals.  A free that is merely ignored is a bitmap that
  ! drifts from the machine one page at a time.
  integer(c_int32_t), parameter :: FK_PMM_E_NOT_READY    = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_E_UNALIGNED    = 17_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_E_RANGE        = 18_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_E_NOT_RAM      = 19_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_E_DOUBLE_FREE  = 20_c_int32_t
  integer(c_int32_t), parameter :: FK_PMM_E_LOCKED       = 21_c_int32_t

  ! All ones, spelled so that no literal has to carry a bit-63 sign.
  integer(c_int64_t), parameter :: FK_PMM_WORD_FULL = not(0_c_int64_t)

  ! bind(c) so gates outside the program can find it: tools/linkscript-test.sh
  ! asserts its size and its section.  NO initialiser -- one would move 2 MiB
  ! out of .bss and into the image.
  integer(c_int64_t), save, bind(c, name="fk_pmm_bitmap") :: bitmap(FK_PMM_WORDS)

  ! The map as the loader reported it, kept verbatim for display and for the
  ! ownership question pmm_free_page and pmm_verify_reserved ask.  Parallel
  ! arrays rather than an array of a derived type: a whole-record assignment is
  ! one of the forms gfortran may lower to memcpy.
  integer(c_int64_t), save :: reg_base(FK_PMM_MAX_REGIONS)
  integer(c_int64_t), save :: reg_len(FK_PMM_MAX_REGIONS)
  integer(c_int32_t), save :: reg_type(FK_PMM_MAX_REGIONS)
  integer(c_int32_t), save :: reg_count = 0_c_int32_t
  integer(c_int32_t), save :: front_end = FK_PMM_FRONT_NONE

  integer(c_int64_t), save :: ram_pages    = 0_c_int64_t
  integer(c_int64_t), save :: free_count   = 0_c_int64_t
  integer(c_int64_t), save :: ignored      = 0_c_int64_t
  integer(c_int64_t), save :: kern_lo      = 0_c_int64_t
  integer(c_int64_t), save :: kern_hi      = 0_c_int64_t
  integer(c_int64_t), save :: mbi_lo       = 0_c_int64_t
  integer(c_int64_t), save :: mbi_hi       = 0_c_int64_t

  ! First word that might hold a free bit.  Without it the scan is O(n) per
  ! allocation and draining 6 million frames is quadratic; with it, a run of
  ! allocations is linear and five consecutive calls return five consecutive
  ! frames -- which is what makes "contiguous" and "reclaimed the same pages"
  ! observable properties rather than hopes.
  integer(c_int32_t), save :: cursor = 1_c_int32_t
  logical,            save :: ready  = .false.

  ! Set by pmm_init for the duration of the parse only.  A module-scope pointer
  ! rather than a passed descriptor because no descriptor may cross the C
  ! boundary; the target is memory the loader owns and nothing is allocated.
  integer(c_int32_t), pointer :: mbi_w(:)

  interface
    ! linker.ld's __kernel_phys_start / __kernel_phys_end.  They are ABSOLUTE
    ! symbols -- the value IS the address -- which Fortran cannot name; see
    ! boot/ksyms.S.
    function fk_kernel_phys_start() result(a) bind(c, name="fk_kernel_phys_start")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_kernel_phys_start

    function fk_kernel_phys_end() result(a) bind(c, name="fk_kernel_phys_end")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_kernel_phys_end
  end interface

contains

  ! --- bitmap primitives ---------------------------------------------------
  ! Both take an INCLUSIVE page range, already clamped, and return how many
  ! bits they actually changed.  The counts are the accounting: nothing else
  ! ever recomputes free_count, so an overlapping region cannot be counted
  ! twice.  The whole-word shortcuts are for the two states a freshly built
  ! bitmap is almost entirely in; a mixed word falls back to bit-at-a-time.

  function bits_set(first, last) result(flipped)
    implicit none
    integer(c_int64_t), intent(in) :: first, last
    integer(c_int64_t) :: flipped, p, wbase, lo, hi
    integer(c_int32_t) :: w, b

    flipped = 0_c_int64_t
    if (last < first) return

    do w = int(ishft(first, -6), c_int32_t) + 1_c_int32_t, &
           int(ishft(last,  -6), c_int32_t) + 1_c_int32_t
       wbase = ishft(int(w - 1_c_int32_t, c_int64_t), 6)
       lo = max(first, wbase)
       hi = min(last,  wbase + 63_c_int64_t)
       if (lo == wbase .and. hi == wbase + 63_c_int64_t) then
          if (bitmap(w) == FK_PMM_WORD_FULL) cycle
          if (bitmap(w) == 0_c_int64_t) then
             bitmap(w) = FK_PMM_WORD_FULL
             flipped = flipped + 64_c_int64_t
             cycle
          end if
       end if
       do p = lo, hi
          b = int(iand(p, 63_c_int64_t), c_int32_t)
          if (.not. btest(bitmap(w), b)) then
             bitmap(w) = ibset(bitmap(w), b)
             flipped = flipped + 1_c_int64_t
          end if
       end do
    end do
  end function bits_set

  function bits_clear(first, last) result(flipped)
    implicit none
    integer(c_int64_t), intent(in) :: first, last
    integer(c_int64_t) :: flipped, p, wbase, lo, hi
    integer(c_int32_t) :: w, b

    flipped = 0_c_int64_t
    if (last < first) return

    do w = int(ishft(first, -6), c_int32_t) + 1_c_int32_t, &
           int(ishft(last,  -6), c_int32_t) + 1_c_int32_t
       wbase = ishft(int(w - 1_c_int32_t, c_int64_t), 6)
       lo = max(first, wbase)
       hi = min(last,  wbase + 63_c_int64_t)
       if (lo == wbase .and. hi == wbase + 63_c_int64_t) then
          if (bitmap(w) == 0_c_int64_t) cycle
          if (bitmap(w) == FK_PMM_WORD_FULL) then
             bitmap(w) = 0_c_int64_t
             flipped = flipped + 64_c_int64_t
             cycle
          end if
       end if
       do p = lo, hi
          b = int(iand(p, 63_c_int64_t), c_int32_t)
          if (btest(bitmap(w), b)) then
             bitmap(w) = ibclr(bitmap(w), b)
             flipped = flipped + 1_c_int64_t
          end if
       end do
    end do
  end function bits_clear

  ! --- page-range arithmetic -----------------------------------------------
  ! THE ROUNDING IS ASYMMETRIC AND THAT IS THE SAFETY PROPERTY.  A range being
  ! made AVAILABLE rounds INWARD, so a frame only partly covered by usable RAM
  ! is never handed out.  A range being made USED rounds OUTWARD, so a frame
  ! only partly covered by a reserved region, the kernel image or the loader's
  ! own structure is never handed out either.  Both directions err towards not
  ! allocating; a symmetric rule would have to be wrong in one of them.
  ! .false. means the range has nothing inside the managed window.

  function span_inward(base, length, first, last) result(any)
    implicit none
    integer(c_int64_t), intent(in)  :: base, length
    integer(c_int64_t), intent(out) :: first, last
    logical :: any
    integer(c_int64_t) :: last_byte

    any = .false.
    first = 0_c_int64_t
    last  = -1_c_int64_t
    if (length <= 0_c_int64_t .or. base < 0_c_int64_t) return
    if (base >= FK_PMM_MAX_PHYS) return

    last_byte = base + (length - 1_c_int64_t)
    if (last_byte < base .or. last_byte >= FK_PMM_MAX_PHYS) &
         last_byte = FK_PMM_MAX_PHYS - 1_c_int64_t

    first = ishft(base + (FK_PMM_PAGE_SIZE - 1_c_int64_t), -FK_PMM_PAGE_SHIFT)
    ! last_byte+1 is the exclusive end; the last WHOLE frame ends at or below it.
    last  = ishft(last_byte + 1_c_int64_t, -FK_PMM_PAGE_SHIFT) - 1_c_int64_t
    any   = last >= first
  end function span_inward

  function span_outward(base, length, first, last) result(any)
    implicit none
    integer(c_int64_t), intent(in)  :: base, length
    integer(c_int64_t), intent(out) :: first, last
    logical :: any
    integer(c_int64_t) :: last_byte

    any = .false.
    first = 0_c_int64_t
    last  = -1_c_int64_t
    if (length <= 0_c_int64_t .or. base < 0_c_int64_t) return
    if (base >= FK_PMM_MAX_PHYS) return

    last_byte = base + (length - 1_c_int64_t)
    if (last_byte < base .or. last_byte >= FK_PMM_MAX_PHYS) &
         last_byte = FK_PMM_MAX_PHYS - 1_c_int64_t

    first = ishft(base,      -FK_PMM_PAGE_SHIFT)
    last  = ishft(last_byte, -FK_PMM_PAGE_SHIFT)
    any   = .true.
  end function span_outward

  ! Bytes of the region that fall outside the managed window, so that a machine
  ! with more RAM than FK_PMM_MAX_PHYS says so instead of looking smaller.
  function lost_bytes(base, length) result(lost)
    implicit none
    integer(c_int64_t), intent(in) :: base, length
    integer(c_int64_t) :: lost, last_byte

    lost = 0_c_int64_t
    if (length <= 0_c_int64_t .or. base < 0_c_int64_t) return
    if (base >= FK_PMM_MAX_PHYS) then
       lost = length
       return
    end if
    last_byte = base + (length - 1_c_int64_t)
    if (last_byte < base) return
    if (last_byte >= FK_PMM_MAX_PHYS) lost = last_byte - (FK_PMM_MAX_PHYS - 1_c_int64_t)
  end function lost_bytes

  ! --- reading the loader's structure --------------------------------------
  ! Everything in a Multiboot2 structure is at a 4-byte-aligned offset, so one
  ! int32 view covers it.  The 64-bit fields are assembled from two halves
  ! rather than read as a quadword: it costs nothing and removes an alignment
  ! assumption about a structure this kernel did not lay out.

  function mbi_u32(off) result(v)
    implicit none
    integer(c_int32_t), intent(in) :: off
    integer(c_int64_t) :: v

    v = iand(int(mbi_w(off / 4_c_int32_t + 1_c_int32_t), c_int64_t), &
             int(z'FFFFFFFF', c_int64_t))
  end function mbi_u32

  function mbi_u64(off) result(v)
    implicit none
    integer(c_int32_t), intent(in) :: off
    integer(c_int64_t) :: v

    v = ior(mbi_u32(off), ishft(mbi_u32(off + 4_c_int32_t), 32))
  end function mbi_u64

  ! --- the manager ---------------------------------------------------------

  ! THE ONLY WAY IN, and the only place that decides what a failure leaves
  ! behind.  pmm_build below can fail halfway through a map it has already
  ! started clearing bits for; an allocator holding half a machine's memory map
  ! is worse than one holding none, because it looks like it works.
  function pmm_init(mbi_phys) result(status) bind(c, name="pmm_init")
    implicit none
    integer(c_int64_t), intent(in), value :: mbi_phys
    integer(c_int32_t) :: status
    integer(c_int32_t) :: w

    status = pmm_build(mbi_phys)
    if (status == FK_PMM_OK) then
       ready = .true.
       return
    end if

    ! Back to "this machine has no memory the PMM will admit to", which is the
    ! state every accessor and every gate can then report consistently.
    do w = 1_c_int32_t, FK_PMM_WORDS
       bitmap(w) = FK_PMM_WORD_FULL
    end do
    ready      = .false.
    reg_count  = 0_c_int32_t
    front_end  = FK_PMM_FRONT_NONE
    ram_pages  = 0_c_int64_t
    free_count = 0_c_int64_t
    ignored    = 0_c_int64_t
    mbi_lo     = 0_c_int64_t
    mbi_hi     = 0_c_int64_t
  end function pmm_init

  function pmm_build(mbi_phys) result(status)
    implicit none
    integer(c_int64_t), intent(in) :: mbi_phys
    integer(c_int32_t) :: status
    type(c_ptr) :: p
    integer(c_int64_t) :: total, first, last
    integer(c_int32_t) :: off, mmap_off, efi_off, tag_type, tag_size, i, w

    ! EVERY BIT SET FIRST, AND THIS IS NOT A FORMALITY.  .bss arrives zeroed,
    ! which for this bitmap means "the whole address space is free RAM": ACPI
    ! tables, MMIO apertures and the holes between them included.  The default
    ! must be the safe one, and it must be established before any path that can
    ! return early -- an aborted pmm_init leaves an allocator that hands out
    ! nothing rather than one that hands out anything.
    do w = 1_c_int32_t, FK_PMM_WORDS
       bitmap(w) = FK_PMM_WORD_FULL
    end do
    ready      = .false.
    reg_count  = 0_c_int32_t
    ram_pages  = 0_c_int64_t
    free_count = 0_c_int64_t
    ignored    = 0_c_int64_t
    cursor     = 1_c_int32_t
    front_end  = FK_PMM_FRONT_NONE
    mbi_lo     = 0_c_int64_t
    mbi_hi     = 0_c_int64_t
    kern_lo    = fk_kernel_phys_start()
    kern_hi    = fk_kernel_phys_end()

    if (mbi_phys == 0_c_int64_t) then
       status = FK_PMM_E_MBI_NULL
       return
    end if
    if (iand(mbi_phys, 7_c_int64_t) /= 0_c_int64_t) then
       status = FK_PMM_E_MBI_ALIGN
       return
    end if
    ! The read below is a dereference of a PHYSICAL address, valid only inside
    ! the boot stub's identity window.  Refusing is the whole point: outside it
    ! the load is a page fault whose cause is three files away.
    if (mbi_phys < 0_c_int64_t .or. &
        mbi_phys > FK_PMM_IDMAP_BYTES - 8_c_int64_t) then
       status = FK_PMM_E_MBI_RANGE
       return
    end if

    p = transfer(mbi_phys, p)
    call c_f_pointer(p, mbi_w, [2])
    total = mbi_u32(0_c_int32_t)
    if (total < 16_c_int64_t .or. total > FK_PMM_MBI_MAX) then
       status = FK_PMM_E_MBI_SIZE
       return
    end if
    if (mbi_phys + total > FK_PMM_IDMAP_BYTES) then
       status = FK_PMM_E_MBI_RANGE
       return
    end if
    mbi_lo = mbi_phys
    mbi_hi = mbi_phys + total
    call c_f_pointer(p, mbi_w, [int((total + 3_c_int64_t) / 4_c_int64_t, c_int32_t)])

    ! --- locate the memory-map tag ---------------------------------------
    ! Tags start after the 8-byte header and each is padded up to 8 bytes.  A
    ! zero or overlong size is rejected rather than stepped over: it is the one
    ! malformed input that turns this walk into an infinite loop or a read past
    ! the end of the structure.
    mmap_off = -1_c_int32_t
    efi_off  = -1_c_int32_t
    off = 8_c_int32_t
    do while (int(off, c_int64_t) + 8_c_int64_t <= total)
       tag_type = int(mbi_u32(off), c_int32_t)
       tag_size = int(mbi_u32(off + 4_c_int32_t), c_int32_t)
       if (tag_size < 8_c_int32_t .or. &
           int(off, c_int64_t) + int(tag_size, c_int64_t) > total) then
          status = FK_PMM_E_TAG_OVERRUN
          return
       end if
       if (tag_type == MB2_TAG_END) exit
       if (tag_type == MB2_TAG_MMAP)     mmap_off = off
       if (tag_type == MB2_TAG_EFI_MMAP) efi_off  = off
       off = off + iand(tag_size + 7_c_int32_t, not(7_c_int32_t))
    end do

    ! THE FRONT END IS CHOSEN BY WHAT THE LOADER ACTUALLY PROVIDED, and tag 17
    ! wins where both exist: on the UEFI path tag 6 is GRUB's own summary of the
    ! EFI map, and the EFI map is the original.
    if (efi_off >= 0_c_int32_t) then
       status = collect_efi(efi_off)
       front_end = FK_PMM_FRONT_EFI
    else if (mmap_off >= 0_c_int32_t) then
       status = collect_mb2(mmap_off)
       front_end = FK_PMM_FRONT_MB2
    else
       status = FK_PMM_E_NO_MMAP
       return
    end if
    if (status /= FK_PMM_OK) return
    free_count = ram_pages

    ! --- pass B: everything that is not available is used -----------------
    ! Separate from pass A and strictly after it.  Maps with overlapping
    ! entries exist, and a single pass would let an available region clear bits
    ! a reserved one had already set, with the result depending on entry order.
    ! Reserved wins, always.
    do i = 1_c_int32_t, reg_count
       if (reg_type(i) == FK_PMM_TYPE_AVAILABLE) cycle
       if (span_outward(reg_base(i), reg_len(i), first, last)) &
            free_count = free_count - bits_set(first, last)
    end do

    ! --- the three things the map does not mention ------------------------
    ! The kernel image: roadmap 3.4's stated critical requirement, and the one
    ! defect whose symptom is the kernel overwriting its own text.
    if (span_outward(kern_lo, kern_hi - kern_lo, first, last)) &
         free_count = free_count - bits_set(first, last)

    ! The loader's own structure.  It sits in memory GRUB reported as AVAILABLE
    ! -- correctly, since it is ordinary RAM -- and this module is still reading
    ! it.  Handing it out is a memory map that rewrites itself while it is used.
    if (span_outward(mbi_lo, mbi_hi - mbi_lo, first, last)) &
         free_count = free_count - bits_set(first, last)

    ! Frame 0, so that 0 is an unambiguous out-of-memory answer from
    ! pmm_alloc_page and never also a valid address.
    free_count = free_count - bits_set(0_c_int64_t, 0_c_int64_t)

    if (ram_pages == 0_c_int64_t) then
       status = FK_PMM_E_NO_RAM
       return
    end if

    status = FK_PMM_OK
  end function pmm_build

  function pmm_front_end() result(w) bind(c, name="pmm_front_end")
    implicit none
    integer(c_int32_t) :: w

    w = front_end
  end function pmm_front_end

  ! Append one region and, if it is usable RAM, free its whole frames.  Shared
  ! by both front ends so that the two differ ONLY in how they decode firmware's
  ! table -- the rounding, the accounting and the table itself are one decision.
  function add_region(base, length, rtype) result(status)
    implicit none
    integer(c_int64_t), intent(in) :: base, length
    integer(c_int32_t), intent(in) :: rtype
    integer(c_int32_t) :: status
    integer(c_int64_t) :: first, last

    if (reg_count >= FK_PMM_MAX_REGIONS) then
       status = FK_PMM_E_TOO_MANY
       return
    end if
    reg_count = reg_count + 1_c_int32_t
    reg_base(reg_count) = base
    reg_len(reg_count)  = length
    reg_type(reg_count) = rtype

    if (rtype == FK_PMM_TYPE_AVAILABLE) then
       ignored = ignored + lost_bytes(base, length)
       if (span_inward(base, length, first, last)) &
            ram_pages = ram_pages + bits_clear(first, last)
    end if
    status = FK_PMM_OK
  end function add_region

  ! Multiboot2 tag 6.  entry_size is READ, never assumed to be 24: the
  ! specification reserves the right to grow the entry.
  function collect_mb2(tag_off) result(status)
    implicit none
    integer(c_int32_t), intent(in) :: tag_off
    integer(c_int32_t) :: status
    integer(c_int32_t) :: off, tag_size, ent_size, rtype
    integer(c_int64_t) :: base, length

    tag_size = int(mbi_u32(tag_off + 4_c_int32_t), c_int32_t)
    ent_size = int(mbi_u32(tag_off + 8_c_int32_t), c_int32_t)
    if (ent_size < 24_c_int32_t .or. iand(ent_size, 7_c_int32_t) /= 0_c_int32_t) then
       status = FK_PMM_E_ENTRY_SIZE
       return
    end if

    off = tag_off + 16_c_int32_t
    do while (int(off - tag_off, c_int64_t) + int(ent_size, c_int64_t) <= &
              int(tag_size, c_int64_t))
       base   = mbi_u64(off)
       length = mbi_u64(off + 8_c_int32_t)
       rtype  = int(mbi_u32(off + 16_c_int32_t), c_int32_t)
       status = add_region(base, length, rtype)
       if (status /= FK_PMM_OK) return
       off = off + ent_size
    end do
    status = FK_PMM_OK
  end function collect_mb2

  ! Multiboot2 tag 17 -- the EFI_MEMORY_DESCRIPTOR array GetMemoryMap() returned
  ! (roadmap 0.3).  The header is type/size/descriptor_size/descriptor_version
  ! and the array follows at +16.  The STRIDE comes from the tag and is not
  ! sizeof(descriptor): real OVMF reports 48 against 40 bytes of fields, so a
  ! parser that assumed the struct size would desynchronise on descriptor 1.
  ! fk_efi_mmap_m owns that decoding; this function only maps its types onto the
  ! codes the rest of the PMM already speaks.
  function collect_efi(tag_off) result(status)
    implicit none
    integer(c_int32_t), intent(in) :: tag_off
    integer(c_int32_t) :: status
    integer(c_int32_t) :: tag_size, dver, i, n, etype, rtype
    integer(c_int64_t) :: dsize, abytes, base, length
    type(c_ptr) :: arr

    tag_size = int(mbi_u32(tag_off + 4_c_int32_t), c_int32_t)
    if (int(tag_size, c_int64_t) < 16_c_int64_t) then
       status = FK_PMM_E_TAG_OVERRUN
       return
    end if
    dsize  = mbi_u32(tag_off + 8_c_int32_t)
    dver   = int(mbi_u32(tag_off + 12_c_int32_t), c_int32_t)
    abytes = int(tag_size, c_int64_t) - 16_c_int64_t
    arr    = transfer(mbi_lo + int(tag_off, c_int64_t) + 16_c_int64_t, arr)

    if (efi_mmap_set(arr, abytes, dsize, dver) /= FK_EFI_OK) then
       status = FK_PMM_E_ENTRY_SIZE
       return
    end if

    n = efi_mmap_count()
    do i = 0_c_int32_t, n - 1_c_int32_t
       base   = efi_mmap_base(i)
       length = efi_mmap_bytes(i)
       etype  = efi_mmap_type(i)
       ! A refused byte count is a descriptor claiming more memory than an
       ! address space holds.  Treating it as reserved keeps it out of the
       ! allocator instead of wrapping it into a small usable region.
       if (length == FK_EFI_BAD64) then
          status = FK_PMM_E_ENTRY_SIZE
          return
       end if
       if (etype == FK_EFI_TYPE_CONVENTIONAL) then
          rtype = FK_PMM_TYPE_AVAILABLE
       else if (etype == EFI_TYPE_ACPI_RECLAIM) then
          rtype = FK_PMM_TYPE_ACPI
       else if (etype == EFI_TYPE_ACPI_NVS) then
          rtype = FK_PMM_TYPE_NVS
       else
          rtype = FK_PMM_TYPE_RESERVED
       end if
       status = add_region(base, length, rtype)
       if (status /= FK_PMM_OK) return
    end do
    status = FK_PMM_OK
  end function collect_efi

  ! First free frame, marked used.  0 means out of memory -- frame 0 is
  ! reserved by pmm_init precisely so that this cannot be mistaken for success.
  function pmm_alloc_page() result(phys) bind(c, name="pmm_alloc_page")
    implicit none
    integer(c_int64_t) :: phys
    integer(c_int32_t) :: w, b

    phys = 0_c_int64_t
    if (.not. ready) return

    do w = cursor, FK_PMM_WORDS
       if (bitmap(w) == FK_PMM_WORD_FULL) cycle
       ! not(w) has its lowest set bit exactly where w has its lowest clear
       ! one, so this is the first free frame in the word.  Excluded above is
       ! the all-ones case, where not() is zero and trailz would answer 64.
       b = trailz(not(bitmap(w)))
       bitmap(w) = ibset(bitmap(w), b)
       cursor = w
       free_count = free_count - 1_c_int64_t
       phys = ishft(ishft(int(w - 1_c_int32_t, c_int64_t), 6) + &
                    int(b, c_int64_t), FK_PMM_PAGE_SHIFT)
       return
    end do

    ! Nothing above the cursor: leave it past the end so a caller that keeps
    ! asking does not rescan the whole bitmap for each refusal.
    cursor = FK_PMM_WORDS + 1_c_int32_t
  end function pmm_alloc_page

  ! The same first-fit scan, floored at a physical address.  roadmap 3.5 needs
  ! it: everything a plain pmm_alloc_page hands out during boot is low memory,
  ! so the one thing the VMM exists to prove -- that a frame ABOVE the old 1 GiB
  ! identity window becomes writable memory rather than a number -- cannot be
  ! asked for without it.  The cursor is NOT moved: this is a targeted request,
  ! and rewinding the ordinary allocator's scan to a high floor would make every
  ! subsequent allocation start there.
  function pmm_alloc_page_from(min_phys) result(phys) &
       bind(c, name="pmm_alloc_page_from")
    implicit none
    integer(c_int64_t), intent(in), value :: min_phys
    integer(c_int64_t) :: phys
    integer(c_int32_t) :: w, b, first_w, first_b

    phys = 0_c_int64_t
    if (.not. ready) return
    if (min_phys < 0_c_int64_t .or. min_phys >= FK_PMM_MAX_PHYS) return

    ! Round the floor UP to a frame, then split it into the word holding it and
    ! the bit within that word: the first candidate word may be partly below
    ! the floor, so its low bits have to be masked off rather than scanned.
    first_w = int(ishft(min_phys + (FK_PMM_PAGE_SIZE - 1_c_int64_t), &
                        -(FK_PMM_PAGE_SHIFT + 6)), c_int32_t) + 1_c_int32_t
    first_b = int(iand(ishft(min_phys + (FK_PMM_PAGE_SIZE - 1_c_int64_t), &
                             -FK_PMM_PAGE_SHIFT), 63_c_int64_t), c_int32_t)

    do w = first_w, FK_PMM_WORDS
       if (bitmap(w) == FK_PMM_WORD_FULL) cycle
       do b = merge(first_b, 0_c_int32_t, w == first_w), 63_c_int32_t
          if (btest(bitmap(w), b)) cycle
          bitmap(w) = ibset(bitmap(w), b)
          free_count = free_count - 1_c_int64_t
          phys = ishft(ishft(int(w - 1_c_int32_t, c_int64_t), 6) + &
                       int(b, c_int64_t), FK_PMM_PAGE_SHIFT)
          return
       end do
    end do
  end function pmm_alloc_page_from

  ! PAGES contiguous free frames, or 0.  The block allocator above cannot serve
  ! this and does not try: heap_sbrk hands out a virtual window mapped from
  ! whatever frames were free, and a bus master does not walk the CPU's page
  ! tables.  The answer is a PHYSICAL base because that is the address the
  ! DEVICE uses; vmm_phys_to_virt turns it into the one the CPU uses.
  !
  ! First fit, scanned as WORDS.  A full word cannot contribute to a run, so
  ! the scan skips its 64 bits outright rather than testing them.  A clear bit
  ! is by construction usable RAM -- pmm_init marks the whole bitmap used and
  ! clears only AVAILABLE regions -- so a contiguous run of clear bits is a
  ! contiguous run of frames and needs no second check against the region
  ! table.  What page granularity does NOT promise is a run clear of a 64 KiB
  ! boundary, which a TRB data buffer may not cross
  ! (vendor/linux-7.1.8/drivers/usb/host/xhci.h:1265).
  function pmm_alloc_contiguous(pages) result(phys) &
       bind(c, name="pmm_alloc_contiguous")
    implicit none
    integer(c_int64_t), intent(in), value :: pages
    integer(c_int64_t) :: phys
    integer(c_int64_t) :: page, run_start, run
    integer(c_int32_t) :: w, b

    phys = 0_c_int64_t
    if (.not. ready) return
    if (pages <= 0_c_int64_t) return
    if (pages > int(FK_PMM_PAGES, c_int64_t)) return

    run       = 0_c_int64_t
    run_start = 0_c_int64_t
    page      = 0_c_int64_t
    do w = 1_c_int32_t, FK_PMM_WORDS
       if (bitmap(w) == FK_PMM_WORD_FULL) then
          run  = 0_c_int64_t
          page = page + 64_c_int64_t
          cycle
       end if
       do b = 0_c_int32_t, 63_c_int32_t
          if (btest(bitmap(w), b)) then
             run = 0_c_int64_t
          else
             if (run == 0_c_int64_t) run_start = page
             run = run + 1_c_int64_t
             if (run == pages) then
                call mark_run(run_start, pages)
                phys = ishft(run_start, FK_PMM_PAGE_SHIFT)
                return
             end if
          end if
          page = page + 1_c_int64_t
       end do
    end do
  end function pmm_alloc_contiguous

  ! The cursor is deliberately not touched.  It is a lower bound on where a
  ! free frame can be, and every word below it was FULL when pmm_alloc_page
  ! last moved it forward; pmm_free_page is the only thing that can put a free
  ! frame below it, and it moves the cursor back itself.  Marking frames USED
  ! can only make that bound more true, so a run never invalidates it -- and a
  ! run can never start below it either, which is why this is not a case that
  ! needs handling rather than one that has been forgotten.
  subroutine mark_run(first_page, count)
    implicit none
    integer(c_int64_t), intent(in) :: first_page, count
    integer(c_int64_t) :: p
    integer(c_int32_t) :: w, b

    do p = first_page, first_page + count - 1_c_int64_t
       w = int(ishft(p, -6), c_int32_t) + 1_c_int32_t
       b = int(iand(p, 63_c_int64_t), c_int32_t)
       bitmap(w) = ibset(bitmap(w), b)
    end do
    free_count = free_count - count
  end subroutine mark_run

  ! Hands a run back one frame at a time through the checked single-frame path,
  ! so a caller that frees a range it never owned is refused by exactly the
  ! rules that refuse a stray pmm_free_page -- and refused at the first bad
  ! frame, leaving the rest of the run allocated rather than half-released.
  function pmm_free_contiguous(phys, pages) result(status) &
       bind(c, name="pmm_free_contiguous")
    implicit none
    integer(c_int64_t), intent(in), value :: phys, pages
    integer(c_int32_t) :: status
    integer(c_int64_t) :: i

    status = FK_PMM_OK
    if (pages <= 0_c_int64_t) then
       status = FK_PMM_E_RANGE
       return
    end if
    do i = 0_c_int64_t, pages - 1_c_int64_t
       status = pmm_free_page(phys + ishft(i, FK_PMM_PAGE_SHIFT))
       if (status /= FK_PMM_OK) return
    end do
  end function pmm_free_contiguous

  function pmm_free_page(phys) result(status) bind(c, name="pmm_free_page")
    implicit none
    integer(c_int64_t), intent(in), value :: phys
    integer(c_int32_t) :: status
    integer(c_int64_t) :: page
    integer(c_int32_t) :: w, b

    if (.not. ready) then
       status = FK_PMM_E_NOT_READY
       return
    end if
    if (iand(phys, FK_PMM_PAGE_SIZE - 1_c_int64_t) /= 0_c_int64_t) then
       status = FK_PMM_E_UNALIGNED
       return
    end if
    if (phys < 0_c_int64_t .or. phys >= FK_PMM_MAX_PHYS) then
       status = FK_PMM_E_RANGE
       return
    end if
    ! The kernel image and the loader's structure are ordinary RAM inside an
    ! available region, so the RAM test below WOULD let them through and the
    ! allocator would start handing out this module's own text.  The PMM has no
    ! ownership tracking and cannot tell a stray free from a legitimate one in
    ! general -- but these two ranges it can, and they are the two whose loss is
    ! unrecoverable.
    if (in_span(phys, kern_lo, kern_hi) .or. in_span(phys, mbi_lo, mbi_hi)) then
       status = FK_PMM_E_LOCKED
       return
    end if
    ! Not merely "was it marked used".  Every bit outside usable RAM is marked
    ! used too, so without this an accidental free of an ACPI or MMIO address
    ! would succeed, and the allocator would start handing that address out.
    if (.not. page_in_ram(phys)) then
       status = FK_PMM_E_NOT_RAM
       return
    end if

    page = ishft(phys, -FK_PMM_PAGE_SHIFT)
    w = int(ishft(page, -6), c_int32_t) + 1_c_int32_t
    b = int(iand(page, 63_c_int64_t), c_int32_t)
    if (.not. btest(bitmap(w), b)) then
       status = FK_PMM_E_DOUBLE_FREE
       return
    end if

    bitmap(w) = ibclr(bitmap(w), b)
    free_count = free_count + 1_c_int64_t
    if (w < cursor) cursor = w
    status = FK_PMM_OK
  end function pmm_free_page

  ! Does the frame holding phys touch [lo, hi)?  Outward rounding, so a range
  ! that ends mid-frame still owns the whole frame.
  function in_span(phys, lo, hi) result(hit)
    implicit none
    integer(c_int64_t), intent(in) :: phys, lo, hi
    logical :: hit
    integer(c_int64_t) :: first, last, page

    hit = .false.
    if (.not. span_outward(lo, hi - lo, first, last)) return
    page = ishft(phys, -FK_PMM_PAGE_SHIFT)
    hit = page >= first .and. page <= last
  end function in_span

  ! Is this frame wholly inside a region the loader called available?  The
  ! table is the authority, and it is complete: pmm_init fails rather than
  ! truncate it.
  function page_in_ram(phys) result(inside)
    implicit none
    integer(c_int64_t), intent(in) :: phys
    logical :: inside
    integer(c_int64_t) :: page, first, last
    integer(c_int32_t) :: i

    inside = .false.
    page = ishft(phys, -FK_PMM_PAGE_SHIFT)
    do i = 1_c_int32_t, reg_count
       if (reg_type(i) /= FK_PMM_TYPE_AVAILABLE) cycle
       if (.not. span_inward(reg_base(i), reg_len(i), first, last)) cycle
       if (page >= first .and. page <= last) then
          inside = .true.
          return
       end if
    end do
  end function page_in_ram

  function pmm_page_is_free(phys) result(isfree) bind(c, name="pmm_page_is_free")
    implicit none
    integer(c_int64_t), intent(in), value :: phys
    integer(c_int32_t) :: isfree
    integer(c_int64_t) :: page
    integer(c_int32_t) :: w, b

    isfree = 0_c_int32_t
    if (phys < 0_c_int64_t .or. phys >= FK_PMM_MAX_PHYS) return
    page = ishft(phys, -FK_PMM_PAGE_SHIFT)
    w = int(ishft(page, -6), c_int32_t) + 1_c_int32_t
    b = int(iand(page, 63_c_int64_t), c_int32_t)
    if (.not. btest(bitmap(w), b)) isfree = 1_c_int32_t
  end function pmm_page_is_free

  ! --- the safety assertions roadmap 3.4 asks for --------------------------

  ! Frames still free inside a region the loader did NOT call available.  Zero
  ! is the only acceptable answer; the count is returned rather than a flag
  ! because "one page" and "half the ACPI tables" are different bugs.
  function pmm_verify_reserved() result(loose) bind(c, name="pmm_verify_reserved")
    implicit none
    integer(c_int64_t) :: loose, first, last, page
    integer(c_int32_t) :: i

    loose = 0_c_int64_t
    do i = 1_c_int32_t, reg_count
       if (reg_type(i) == FK_PMM_TYPE_AVAILABLE) cycle
       if (.not. span_outward(reg_base(i), reg_len(i), first, last)) cycle
       do page = first, last
          if (pmm_page_is_free(ishft(page, FK_PMM_PAGE_SHIFT)) /= 0_c_int32_t) &
               loose = loose + 1_c_int64_t
       end do
    end do
  end function pmm_verify_reserved

  ! The same question for the two ranges that are ordinary RAM and must still
  ! never be handed out: this kernel's own image, and the loader's structure.
  function pmm_verify_kernel_locked() result(loose) &
       bind(c, name="pmm_verify_kernel_locked")
    implicit none
    integer(c_int64_t) :: loose, first, last, page

    loose = 0_c_int64_t
    if (span_outward(kern_lo, kern_hi - kern_lo, first, last)) then
       do page = first, last
          if (pmm_page_is_free(ishft(page, FK_PMM_PAGE_SHIFT)) /= 0_c_int32_t) &
               loose = loose + 1_c_int64_t
       end do
    end if
    if (span_outward(mbi_lo, mbi_hi - mbi_lo, first, last)) then
       do page = first, last
          if (pmm_page_is_free(ishft(page, FK_PMM_PAGE_SHIFT)) /= 0_c_int32_t) &
               loose = loose + 1_c_int64_t
       end do
    end if
  end function pmm_verify_kernel_locked

  ! --- accessors, so the console and the VMM at 3.5 stay outside the state --

  function pmm_total_pages() result(n) bind(c, name="pmm_total_pages")
    implicit none
    integer(c_int64_t) :: n

    n = ram_pages
  end function pmm_total_pages

  function pmm_free_pages() result(n) bind(c, name="pmm_free_pages")
    implicit none
    integer(c_int64_t) :: n

    n = free_count
  end function pmm_free_pages

  function pmm_used_pages() result(n) bind(c, name="pmm_used_pages")
    implicit none
    integer(c_int64_t) :: n

    n = ram_pages - free_count
  end function pmm_used_pages

  function pmm_ignored_bytes() result(n) bind(c, name="pmm_ignored_bytes")
    implicit none
    integer(c_int64_t) :: n

    n = ignored
  end function pmm_ignored_bytes

  function pmm_region_count() result(n) bind(c, name="pmm_region_count")
    implicit none
    integer(c_int32_t) :: n

    n = reg_count
  end function pmm_region_count

  ! 1-based, matching the printed table.  An out-of-range index answers zero
  ! rather than reading past the array.
  function pmm_region_base(i) result(v) bind(c, name="pmm_region_base")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (i >= 1_c_int32_t .and. i <= reg_count) v = reg_base(i)
  end function pmm_region_base

  function pmm_region_len(i) result(v) bind(c, name="pmm_region_len")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (i >= 1_c_int32_t .and. i <= reg_count) v = reg_len(i)
  end function pmm_region_len

  function pmm_region_type(i) result(v) bind(c, name="pmm_region_type")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (i >= 1_c_int32_t .and. i <= reg_count) v = reg_type(i)
  end function pmm_region_type

end module fk_pmm_m
