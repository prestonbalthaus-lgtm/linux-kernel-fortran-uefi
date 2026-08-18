! SPDX-License-Identifier: GPL-2.0
! Virtual memory manager: 4-level paging, the kernel's own mapping, and the
! higher-half handoff (roadmap 3.5 and 1.2b).
!
! WHAT REPLACES WHAT.  boot/boot.S builds a throwaway hierarchy: 1 GiB of 2 MiB
! pages, mapped twice -- identity, so the instruction stream survives CR0.PG,
! and at KERNEL_VMA, so the linker's addresses become valid.  Everything in it
! is writable and executable, including .text and .rodata, and it ends one
! gigabyte up.  This module builds the real one out of PMM frames: 4 KiB pages
! with per-section permissions, a linear window onto all of physical memory, and
! no identity window at all once vmm_drop_identity has run.
!
! WHY THERE IS A LINEAR MAP AND NOT JUST THE KERNEL.  A page table is written
! through a VIRTUAL address, and the frames the PMM hands out for tables are at
! arbitrary physical ones.  While the boot stub's identity window is live,
! physical IS virtual and that question does not arise; the instant PML4[0] is
! zeroed, a VMM with no linear map can never touch a page table again -- it maps
! exactly one set of pages, once, and is then bricked.  FK_VMM_PHYSMAP is what
! keeps vmm_map_page callable afterwards, and it is also roadmap 3.4's debt
! coming due: a frame above the old 1 GiB window becomes memory rather than a
! number.
module fk_vmm_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t, c_size_t, &
                                         c_ptr, c_f_pointer
  use fk_pmm_m,    only: FK_PMM_IDMAP_BYTES, &
                         FK_PMM_MAX_PHYS, FK_PMM_TYPE_AVAILABLE, &
                         pmm_alloc_page, pmm_free_page, &
                         pmm_region_count, pmm_region_base, pmm_region_len, &
                         pmm_region_type
  use fk_string_m, only: fk_memset
  use fk_gdt_m,    only: gdt_reload
  use fk_idt_m,    only: idt_reload
  implicit none
  private
  public :: FK_VMM_OK, FK_VMM_E_NOMEM, FK_VMM_E_UNALIGNED, FK_VMM_E_BIG_PAGE, &
            FK_VMM_E_NOT_READY, FK_VMM_E_UNREACHABLE, FK_VMM_E_NO_NX, &
            FK_VMM_PHYSMAP, FK_VMM_SCRATCH, &
            FK_PTE_P, FK_PTE_RW, FK_PTE_PS, FK_PTE_NX, FK_PTE_ADDR, &
            FK_PTE_PWT, FK_PTE_PCD, FK_VMM_MMIO, FK_VMM_HEAP, FK_VMM_WC, &
            vmm_reserve_mmio, vmm_reserved_holes, vmm_map_mmio, &
            vmm_punch_physmap, FK_VMM_E_IS_RAM, FK_VMM_IOAPIC, &
            vmm_pat_arm, vmm_read_pat, FK_VMM_UC, FK_VMM_LAPIC, &
            vmm_init, vmm_activate, vmm_drop_identity, vmm_map_page, &
            vmm_translate, vmm_phys_of, vmm_pml4_phys, vmm_table_frames, &
            vmm_physmap_top, vmm_nx_enabled, vmm_verify_image, &
            vmm_kernel_vma, vmm_phys_to_virt, vmm_read_cr3, &
            FK_VMM_SECTIONS, vmm_section_start, vmm_section_end, &
            vmm_section_flags, vmm_guard_page

  integer(c_int64_t), parameter :: FK_VMM_PAGE_SIZE = 4096_c_int64_t
  integer(c_int64_t), parameter :: FK_VMM_SIZE_2M   = 2097152_c_int64_t
  integer(c_int32_t), parameter :: FK_VMM_PTES      = 512_c_int32_t

  ! Intel SDM Vol.3 4.5.  Bit 63 is NX and is RESERVED -- i.e. every access
  ! faults -- unless EFER.NXE is set first; fk_mmu_arm does that and says so.
  integer(c_int64_t), parameter :: FK_PTE_P    = 1_c_int64_t
  integer(c_int64_t), parameter :: FK_PTE_RW   = 2_c_int64_t
  integer(c_int64_t), parameter :: FK_PTE_PS   = 128_c_int64_t
  integer(c_int64_t), parameter :: FK_PTE_NX   = ishft(1_c_int64_t, 63)
  integer(c_int64_t), parameter :: FK_PTE_ADDR = int(z'000FFFFFFFFFF000', c_int64_t)

  ! PWT and PCD are the low two bits of the PAT index.  boot/mmu.S puts
  ! write-combining at index 1, so PWT alone selects it and the third selector
  ! bit -- which moves between PTE bit 7 and bit 12 with the page size -- is
  ! never needed.  A PWT mapping is UNCACHED-WRITE-THROUGH, not WC, on a CPU
  ! where fk_pat_arm found no PAT: slow and correct rather than wrong.
  integer(c_int64_t), parameter :: FK_PTE_PWT  = 8_c_int64_t
  integer(c_int64_t), parameter :: FK_PTE_PCD  = 16_c_int64_t
  integer(c_int64_t), parameter :: FK_VMM_WC   = ior(ior(FK_PTE_P, FK_PTE_RW), &
                                                     ior(FK_PTE_PWT, FK_PTE_NX))

  ! PAT index 3 -- PCD and PWT together -- which boot/mmu.S leaves at 0x00,
  ! strong UC.  The LAPIC must be strongly uncacheable (SDM Vol.3 11.4.1); UC-
  ! at index 2 would let an MTRR promote it to something weaker.
  integer(c_int64_t), parameter :: FK_VMM_UC   = ior(ior(FK_PTE_P, FK_PTE_RW), &
                                                     ior(ior(FK_PTE_PWT, FK_PTE_PCD), &
                                                         FK_PTE_NX))

  ! PML4[256].  The canonical hole starts at bit 47, so this is the lowest
  ! address in the upper half and leaves the whole top 2 GiB to the kernel.
  integer(c_int64_t), parameter :: FK_VMM_PHYSMAP = int(z'FFFF800000000000', c_int64_t)

  ! A virtual address inside no section, for probing a mapping without
  ! disturbing one.  Top 1 GiB: PML4[511], PDPT[511], above every kernel symbol.
  integer(c_int64_t), parameter :: FK_VMM_SCRATCH = int(z'FFFFFFFFC0000000', c_int64_t)

  ! PML4[257], the slot after the linear map.  Device apertures go here and not
  ! in the linear map, because the linear map is write-back and an MMIO range
  ! reachable at two virtual addresses with two memory types is architecturally
  ! undefined (SDM Vol.3 11.12.4), not merely slow.
  integer(c_int64_t), parameter :: FK_VMM_MMIO = int(z'FFFF808000000000', c_int64_t)

  ! The LAPIC's own page, in the same PML4[257] window but far clear of any
  ! framebuffer that starts at FK_VMM_MMIO.
  integer(c_int64_t), parameter :: FK_VMM_LAPIC = &
       FK_VMM_MMIO + int(z'20000000', c_int64_t)
  ! 16 MiB above the LAPIC's page, derived from the same base rather than
  ! written out: two constants that must stay inside one window are two things
  ! that can drift apart.
  integer(c_int64_t), parameter :: FK_VMM_IOAPIC = &
       FK_VMM_MMIO + int(z'21000000', c_int64_t)

  ! PML4[258], the slot after the device window.  The kernel heap grows upward
  ! from here (roadmap 4.0).  A slot of its own rather than a hole inside the
  ! linear map: the heap's pages come from the PMM at arbitrary physical
  ! addresses and must be CONTIGUOUS in virtual space, which is exactly the
  ! property a linear map cannot offer.
  integer(c_int64_t), parameter :: FK_VMM_HEAP = int(z'FFFF810000000000', c_int64_t)

  integer(c_int32_t), parameter :: FK_VMM_OK           = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_VMM_E_NOMEM      = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_VMM_E_UNALIGNED  = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_VMM_E_BIG_PAGE   = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_VMM_E_NOT_READY  = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_VMM_E_UNREACHABLE = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_VMM_E_NO_NX      = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_VMM_E_IS_RAM     = 7_c_int32_t

  ! The image, as six page-granular spans with a permission each.  ONE table
  ! rather than one open-coded sequence per job: mapping, verifying and
  ! reporting all walk it, so a section that is mapped cannot be forgotten by
  ! the check that is supposed to catch a section being mapped wrong.
  integer(c_int32_t), parameter :: FK_VMM_SECTIONS = 6_c_int32_t

  integer(c_int64_t), save :: sec_start(FK_VMM_SECTIONS) = 0_c_int64_t
  integer(c_int64_t), save :: sec_end(FK_VMM_SECTIONS)   = 0_c_int64_t
  integer(c_int64_t), save :: sec_flags(FK_VMM_SECTIONS) = 0_c_int64_t
  integer(c_int64_t), save :: guard_page = 0_c_int64_t

  ! The physical span map_physmap must NOT cover.  See FK_VMM_MMIO.
  ! A LIST, not one span.  It held exactly one until roadmap 3.3, and one was
  ! enough only while the framebuffer was the sole aperture: a second caller
  ! silently OVERWROTE the first, and the physmap then kept a write-back alias
  ! of whichever device did not win.  The LAPIC is that second caller.
  integer(c_int32_t), parameter :: FK_VMM_MAX_HOLES = 4_c_int32_t
  integer(c_int64_t), save :: hole_base(FK_VMM_MAX_HOLES)  = 0_c_int64_t
  integer(c_int64_t), save :: hole_bytes(FK_VMM_MAX_HOLES) = 0_c_int64_t
  integer(c_int32_t), save :: hole_count = 0_c_int32_t

  integer(c_int64_t), save :: pml4_phys   = 0_c_int64_t
  integer(c_int64_t), save :: kernel_vma  = 0_c_int64_t
  integer(c_int64_t), save :: table_count = 0_c_int64_t
  integer(c_int64_t), save :: map_top     = 0_c_int64_t
  logical,            save :: physmap_on  = .false.
  logical,            save :: nx_on       = .false.

  interface
    subroutine fk_write_cr3(phys) bind(c, name="fk_write_cr3")
      import :: c_int64_t
      implicit none
      integer(c_int64_t), intent(in), value :: phys
    end subroutine fk_write_cr3

    function fk_read_cr3() result(v) bind(c, name="fk_read_cr3")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: v
    end function fk_read_cr3

    subroutine fk_invlpg(virt) bind(c, name="fk_invlpg")
      import :: c_int64_t
      implicit none
      integer(c_int64_t), intent(in), value :: virt
    end subroutine fk_invlpg

    function fk_mmu_arm() result(s) bind(c, name="fk_mmu_arm")
      import :: c_int32_t
      implicit none
      integer(c_int32_t) :: s
    end function fk_mmu_arm

    function fk_pat_arm() result(s) bind(c, name="fk_pat_arm")
      import :: c_int32_t
      implicit none
      integer(c_int32_t) :: s
    end function fk_pat_arm

    function fk_read_pat() result(v) bind(c, name="fk_read_pat")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: v
    end function fk_read_pat

    ! linker.ld's absolute symbols; see boot/ksyms.S for why they cannot be
    ! named directly from Fortran.
    function fk_kernel_start()      result(a) bind(c, name="fk_kernel_start")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_kernel_start
    function fk_kernel_end()        result(a) bind(c, name="fk_kernel_end")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_kernel_end
    function fk_kernel_phys_start() result(a) bind(c, name="fk_kernel_phys_start")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_kernel_phys_start
    function fk_text_start()        result(a) bind(c, name="fk_text_start")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_text_start
    function fk_text_end()          result(a) bind(c, name="fk_text_end")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_text_end
    function fk_rodata_start()      result(a) bind(c, name="fk_rodata_start")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_rodata_start
    function fk_rodata_end()        result(a) bind(c, name="fk_rodata_end")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_rodata_end
    function fk_data_start()        result(a) bind(c, name="fk_data_start")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_data_start
    function fk_data_end()          result(a) bind(c, name="fk_data_end")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_data_end
    function fk_bss_start()         result(a) bind(c, name="fk_bss_start")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_bss_start
    function fk_bss_end()           result(a) bind(c, name="fk_bss_end")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_bss_end
    function fk_bootpt_start()      result(a) bind(c, name="fk_bootpt_start")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_bootpt_start
    function fk_bootpt_end()        result(a) bind(c, name="fk_bootpt_end")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_bootpt_end
    function fk_boot_stack_guard()  result(a) bind(c, name="fk_boot_stack_guard")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_boot_stack_guard
  end interface

contains

  ! --- address arithmetic ---------------------------------------------------

  function vmm_kernel_vma() result(v) bind(c, name="vmm_kernel_vma")
    implicit none
    integer(c_int64_t) :: v

    v = kernel_vma
  end function vmm_kernel_vma

  ! The window through which a page table is reachable RIGHT NOW.  Identity
  ! while boot/boot.S's PML4[0] is still what CR3 points at, the linear map
  ! afterwards.  Getting this wrong in either direction writes a page-table
  ! entry into somebody else's memory, so it is one function and not a
  ! convention every caller has to remember.
  function vmm_phys_to_virt(p) result(v) bind(c, name="vmm_phys_to_virt")
    implicit none
    integer(c_int64_t), intent(in), value :: p
    integer(c_int64_t) :: v

    if (physmap_on) then
       v = FK_VMM_PHYSMAP + p
    else
       v = p
    end if
  end function vmm_phys_to_virt

  subroutine table_at(p, t)
    implicit none
    integer(c_int64_t), intent(in) :: p
    integer(c_int64_t), pointer, intent(out) :: t(:)
    type(c_ptr) :: cp

    cp = transfer(vmm_phys_to_virt(p), cp)
    call c_f_pointer(cp, t, [FK_VMM_PTES])
  end subroutine table_at

  ! 1-based Fortran index of the entry level SHIFT selects.
  pure function idx(virt, shift) result(i)
    implicit none
    integer(c_int64_t), intent(in) :: virt
    integer(c_int32_t), intent(in) :: shift
    integer(c_int32_t) :: i

    i = int(iand(ishft(virt, -shift), 511_c_int64_t), c_int32_t) + 1_c_int32_t
  end function idx

  pure function round_down(v, granule) result(r)
    implicit none
    integer(c_int64_t), intent(in) :: v, granule
    integer(c_int64_t) :: r

    r = iand(v, not(granule - 1_c_int64_t))
  end function round_down

  pure function round_up(v, granule) result(r)
    implicit none
    integer(c_int64_t), intent(in) :: v, granule
    integer(c_int64_t) :: r

    r = iand(v + (granule - 1_c_int64_t), not(granule - 1_c_int64_t))
  end function round_up

  ! --- table allocation -----------------------------------------------------

  ! A fresh, zeroed table.  Zeroed and not merely allocated: the MMU walks
  ! whatever is in an entry the moment an address reaches it, so one stale
  ! quadword left by a previous owner is a present-looking pointer into
  ! arbitrary memory and an unexplainable fault later.
  subroutine new_table(phys, status)
    implicit none
    integer(c_int64_t), intent(out) :: phys
    integer(c_int32_t), intent(out) :: status
    type(c_ptr) :: cp, done

    phys = pmm_alloc_page()
    if (phys == 0_c_int64_t) then
       status = FK_VMM_E_NOMEM
       return
    end if

    ! Before the linear map exists the only window onto physical memory is the
    ! boot stub's 1 GiB identity one, so a table above it could not be written.
    ! The PMM's first fit hands out low frames and this has never fired -- which
    ! is exactly why it must be checked rather than assumed.
    if (.not. physmap_on .and. phys >= FK_PMM_IDMAP_BYTES) then
       status = pmm_free_page(phys)
       phys   = 0_c_int64_t
       status = FK_VMM_E_UNREACHABLE
       return
    end if

    cp   = transfer(vmm_phys_to_virt(phys), cp)
    done = fk_memset(cp, 0_c_int32_t, int(FK_VMM_PAGE_SIZE, c_size_t))
    table_count = table_count + 1_c_int64_t
    status = FK_VMM_OK
  end subroutine new_table

  ! --- mapping --------------------------------------------------------------

  ! Walks to the level SHIFT names, creating tables on the way, and returns the
  ! physical address of the table BELOW it.  Intermediate entries are always
  ! present+writable: the CPU ANDs the write permission and ORs the NX bit down
  ! the whole walk, so a restrictive parent silently clamps every leaf under it
  ! and the leaf's own flags stop meaning anything.
  subroutine walk(virt, stop_shift, tbl, status)
    implicit none
    integer(c_int64_t), intent(in)  :: virt
    integer(c_int32_t), intent(in)  :: stop_shift
    integer(c_int64_t), intent(out) :: tbl
    integer(c_int32_t), intent(out) :: status
    integer(c_int64_t), pointer :: t(:)
    integer(c_int64_t) :: e, nxt
    integer(c_int32_t) :: sh

    tbl    = pml4_phys
    status = FK_VMM_OK
    sh     = 39_c_int32_t
    do while (sh > stop_shift)
       call table_at(tbl, t)
       e = t(idx(virt, sh))
       if (iand(e, FK_PTE_P) == 0_c_int64_t) then
          call new_table(nxt, status)
          if (status /= FK_VMM_OK) return
          t(idx(virt, sh)) = ior(nxt, ior(FK_PTE_P, FK_PTE_RW))
       else if (iand(e, FK_PTE_PS) /= 0_c_int64_t) then
          ! A large page already covers this address.  Shattering it into 4 KiB
          ! entries is a real operation and not this milestone's; refusing is
          ! the difference between a status code and a corrupted hierarchy.
          status = FK_VMM_E_BIG_PAGE
          return
       else
          nxt = iand(e, FK_PTE_ADDR)
       end if
       tbl = nxt
       sh  = sh - 9_c_int32_t
    end do
  end subroutine walk

  function vmm_map_page(virt, phys, flags) result(status) &
       bind(c, name="vmm_map_page")
    implicit none
    integer(c_int64_t), intent(in), value :: virt, phys, flags
    integer(c_int32_t) :: status
    integer(c_int64_t), pointer :: t(:)
    integer(c_int64_t) :: tbl

    if (pml4_phys == 0_c_int64_t) then
       status = FK_VMM_E_NOT_READY
       return
    end if
    if (iand(ior(virt, phys), FK_VMM_PAGE_SIZE - 1_c_int64_t) /= 0_c_int64_t) then
       status = FK_VMM_E_UNALIGNED
       return
    end if

    call walk(virt, 12_c_int32_t, tbl, status)
    if (status /= FK_VMM_OK) return

    call table_at(tbl, t)
    t(idx(virt, 12_c_int32_t)) = ior(iand(phys, FK_PTE_ADDR), ior(flags, FK_PTE_P))

    ! The entry may be REPLACING one the CPU has already cached, and a stale
    ! TLB entry outlives the table write that invalidated it.
    call fk_invlpg(virt)
    status = FK_VMM_OK
  end function vmm_map_page

  ! 2 MiB leaf at the page-directory level.  Used for the two windows that
  ! cover whole gigabytes -- the linear map and the transient identity one --
  ! where 4 KiB entries would cost 512 times the tables for no permission
  ! granularity anybody needs.
  function vmm_map_2m(virt, phys, flags) result(status)
    implicit none
    integer(c_int64_t), intent(in) :: virt, phys, flags
    integer(c_int32_t) :: status
    integer(c_int64_t), pointer :: t(:)
    integer(c_int64_t) :: tbl

    if (pml4_phys == 0_c_int64_t) then
       status = FK_VMM_E_NOT_READY
       return
    end if
    if (iand(ior(virt, phys), FK_VMM_SIZE_2M - 1_c_int64_t) /= 0_c_int64_t) then
       status = FK_VMM_E_UNALIGNED
       return
    end if

    call walk(virt, 21_c_int32_t, tbl, status)
    if (status /= FK_VMM_OK) return

    call table_at(tbl, t)
    t(idx(virt, 21_c_int32_t)) = &
         ior(iand(phys, FK_PTE_ADDR), ior(ior(flags, FK_PTE_P), FK_PTE_PS))
    call fk_invlpg(virt)
    status = FK_VMM_OK
  end function vmm_map_2m

  ! --- reading the tables back ----------------------------------------------

  ! The leaf entry that describes VIRT, or 0 if nothing does.  Zero is
  ! unambiguous: a present entry always has bit 0 set.
  ! The leaf entry AND the level it was found at.  vmm_phys_of needs the level:
  ! a PS entry is 2 MiB at the page-directory level and 1 GiB one level up, and
  ! masking the wrong number of bits out of VIRT would answer with an address up
  ! to a gigabyte low.  Nothing in this tree creates a 1 GiB page today -- the
  ! only PS writer is vmm_map_2m -- so that is a latent wrong answer rather than
  ! a live one, and it is cheaper to make impossible than to remember.
  subroutine walk_leaf(virt, entry, sh)
    implicit none
    integer(c_int64_t), intent(in)  :: virt
    integer(c_int64_t), intent(out) :: entry
    integer(c_int32_t), intent(out) :: sh
    integer(c_int64_t), pointer :: t(:)
    integer(c_int64_t) :: tbl

    entry = 0_c_int64_t
    sh    = 12_c_int32_t
    if (pml4_phys == 0_c_int64_t) return

    tbl = pml4_phys
    sh  = 39_c_int32_t
    do while (sh >= 12_c_int32_t)
       call table_at(tbl, t)
       entry = t(idx(virt, sh))
       if (iand(entry, FK_PTE_P) == 0_c_int64_t) then
          entry = 0_c_int64_t
          return
       end if
       if (sh == 12_c_int32_t) return
       ! Bit 7 is PS below the top level and RESERVED in a PML4 entry, so the
       ! test is suppressed there rather than trusted to be clear.
       if (sh < 39_c_int32_t .and. iand(entry, FK_PTE_PS) /= 0_c_int64_t) return
       tbl = iand(entry, FK_PTE_ADDR)
       sh  = sh - 9_c_int32_t
    end do
  end subroutine walk_leaf

  function vmm_translate(virt) result(entry) bind(c, name="vmm_translate")
    implicit none
    integer(c_int64_t), intent(in), value :: virt
    integer(c_int64_t) :: entry
    integer(c_int32_t) :: sh

    call walk_leaf(virt, entry, sh)
  end function vmm_translate

  ! Physical address VIRT resolves to, or -1 if it resolves to nothing.  -1 and
  ! not 0: physical zero is a real frame, and the one the PMM reserves.
  function vmm_phys_of(virt) result(phys) bind(c, name="vmm_phys_of")
    implicit none
    integer(c_int64_t), intent(in), value :: virt
    integer(c_int64_t) :: phys, e, page
    integer(c_int32_t) :: sh

    call walk_leaf(virt, e, sh)
    if (e == 0_c_int64_t) then
       phys = -1_c_int64_t
       return
    end if
    ! The leaf's own size, from the level it was found at: 4 KiB, 2 MiB or
    ! 1 GiB.  Never assumed.
    page = ishft(1_c_int64_t, sh)
    phys = ior(round_down(iand(e, FK_PTE_ADDR), page), iand(virt, page - 1_c_int64_t))
  end function vmm_phys_of

  function vmm_pml4_phys() result(v) bind(c, name="vmm_pml4_phys")
    implicit none
    integer(c_int64_t) :: v

    v = pml4_phys
  end function vmm_pml4_phys

  function vmm_table_frames() result(v) bind(c, name="vmm_table_frames")
    implicit none
    integer(c_int64_t) :: v

    v = table_count
  end function vmm_table_frames

  function vmm_physmap_top() result(v) bind(c, name="vmm_physmap_top")
    implicit none
    integer(c_int64_t) :: v

    v = map_top
  end function vmm_physmap_top

  function vmm_nx_enabled() result(v) bind(c, name="vmm_nx_enabled")
    implicit none
    integer(c_int32_t) :: v

    v = merge(1_c_int32_t, 0_c_int32_t, nx_on)
  end function vmm_nx_enabled

  ! What the CPU is holding, not what this module believes it wrote.
  function vmm_read_cr3() result(v) bind(c, name="vmm_read_cr3")
    implicit none
    integer(c_int64_t) :: v

    v = fk_read_cr3()
  end function vmm_read_cr3

  ! --- building the kernel's own map ----------------------------------------

  ! The guard page is the one ADDRESS in the image deliberately left with no
  ! translation, so it is skipped here rather than unmapped afterwards: an
  ! unmap-after-map leaves a window in which a stack overflow is silent.  Its
  ! FRAME is still reachable through the linear map, like every other frame --
  ! what the guard protects is the address a falling stack pointer walks into,
  ! and that resolves to nothing.
  function map_range(vstart, vend, flags) result(status)
    implicit none
    integer(c_int64_t), intent(in) :: vstart, vend, flags
    integer(c_int32_t) :: status
    integer(c_int64_t) :: v, last

    v      = round_down(vstart, FK_VMM_PAGE_SIZE)
    last   = round_up(vend, FK_VMM_PAGE_SIZE)
    status = FK_VMM_OK
    do while (v < last)
       if (v /= guard_page) then
          status = vmm_map_page(v, v - kernel_vma, flags)
          if (status /= FK_VMM_OK) return
       end if
       v = v + FK_VMM_PAGE_SIZE
    end do
  end function map_range

  ! Section flags.  NX is dropped wholesale when the CPU has no NX bit to set,
  ! because a set bit 63 without EFER.NXE is a RESERVED bit: it does not forbid
  ! execution, it faults on every access there is.
  function perm(writable, executable) result(f)
    implicit none
    logical, intent(in) :: writable, executable
    integer(c_int64_t) :: f

    f = FK_PTE_P
    if (writable) f = ior(f, FK_PTE_RW)
    if (nx_on .and. .not. executable) f = ior(f, FK_PTE_NX)
  end function perm

  ! Called by vmm_init once nx_on is known.  The order of the rows is the order
  ! linker.ld lays the sections down, and src/boot/fk_kmain.f90 names them in
  ! the same order when it prints the table.
  subroutine build_section_table()
    implicit none

    guard_page = fk_boot_stack_guard()

    ! The Multiboot2 header's own page: read by the loader, executed by nobody.
    sec_start(1) = fk_kernel_start();  sec_end(1) = fk_text_start()
    sec_flags(1) = perm(.false., .false.)
    sec_start(2) = fk_text_start();    sec_end(2) = fk_text_end()
    sec_flags(2) = perm(.false., .true.)
    sec_start(3) = fk_rodata_start();  sec_end(3) = fk_rodata_end()
    sec_flags(3) = perm(.false., .false.)
    sec_start(4) = fk_data_start();    sec_end(4) = fk_data_end()
    sec_flags(4) = perm(.true., .false.)
    sec_start(5) = fk_bss_start();     sec_end(5) = fk_bss_end()
    sec_flags(5) = perm(.true., .false.)
    ! The boot stub's own tables.  Dead the moment CR3 changes, but inside the
    ! image extent the PMM has locked, so leaving them unmapped would put a hole
    ! in the one range every gate checks is completely covered.
    sec_start(6) = fk_bootpt_start();  sec_end(6) = fk_bootpt_end()
    sec_flags(6) = perm(.true., .false.)
  end subroutine build_section_table

  function vmm_section_start(i) result(v) bind(c, name="vmm_section_start")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (i >= 1_c_int32_t .and. i <= FK_VMM_SECTIONS) v = sec_start(i)
  end function vmm_section_start

  function vmm_section_end(i) result(v) bind(c, name="vmm_section_end")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (i >= 1_c_int32_t .and. i <= FK_VMM_SECTIONS) v = sec_end(i)
  end function vmm_section_end

  function vmm_section_flags(i) result(v) bind(c, name="vmm_section_flags")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (i >= 1_c_int32_t .and. i <= FK_VMM_SECTIONS) v = sec_flags(i)
  end function vmm_section_flags

  function vmm_guard_page() result(v) bind(c, name="vmm_guard_page")
    implicit none
    integer(c_int64_t) :: v

    v = guard_page
  end function vmm_guard_page

  function map_image() result(status)
    implicit none
    integer(c_int32_t) :: status
    integer(c_int32_t) :: i

    status = FK_VMM_OK
    do i = 1_c_int32_t, FK_VMM_SECTIONS
       status = map_range(sec_start(i), sec_end(i), sec_flags(i))
       if (status /= FK_VMM_OK) return
    end do
  end function map_image

  ! --- verification ---------------------------------------------------------

  ! Walks the hierarchy that is about to be loaded into CR3 and counts the pages
  ! that do not say what they were asked to say.  Runs BEFORE the switch on
  ! purpose: a kernel that maps its own .text wrong does not report it, it
  ! triple-faults, and a machine that reboots says nothing at all.
  function vmm_verify_image() result(bad) bind(c, name="vmm_verify_image")
    implicit none
    integer(c_int64_t) :: bad
    integer(c_int32_t) :: i

    bad = 0_c_int64_t
    do i = 1_c_int32_t, FK_VMM_SECTIONS
       bad = bad + check_span(sec_start(i), sec_end(i), sec_flags(i))
    end do

    ! And the one page that must NOT resolve.
    if (vmm_translate(guard_page) /= 0_c_int64_t) bad = bad + 1_c_int64_t
  end function vmm_verify_image

  function check_span(vstart, vend, flags) result(bad)
    implicit none
    integer(c_int64_t), intent(in) :: vstart, vend, flags
    integer(c_int64_t) :: bad, v, last, e

    bad   = 0_c_int64_t
    v     = round_down(vstart, FK_VMM_PAGE_SIZE)
    last  = round_up(vend, FK_VMM_PAGE_SIZE)
    do while (v < last)
       if (v /= guard_page) then
          e = vmm_translate(v)
          ! The permission bits AND the frame: a page mapped read-only to the
          ! wrong physical address passes a flags-only check.
          if (e == 0_c_int64_t) then
             bad = bad + 1_c_int64_t
          else if (iand(e, ior(ior(FK_PTE_P, FK_PTE_RW), FK_PTE_NX)) /= flags) then
             bad = bad + 1_c_int64_t
          else if (iand(e, FK_PTE_ADDR) /= v - kernel_vma) then
             bad = bad + 1_c_int64_t
          end if
       end if
       v = v + FK_VMM_PAGE_SIZE
    end do
  end function check_span

  ! Every byte of RAM the loader reported, at FK_VMM_PHYSMAP + its physical
  ! address.  The extent follows the machine rather than a constant: a fixed
  ! 64 GiB window would cost 32768 page-directory entries on a 4 GiB box.
  function map_physmap() result(status)
    implicit none
    integer(c_int32_t) :: status
    integer(c_int64_t) :: top, e, p
    integer(c_int32_t) :: i

    top = 0_c_int64_t
    do i = 1_c_int32_t, pmm_region_count()
       if (pmm_region_type(i) /= FK_PMM_TYPE_AVAILABLE) cycle
       e = pmm_region_base(i) + pmm_region_len(i)
       if (e > top) top = e
    end do
    if (top > FK_PMM_MAX_PHYS) top = FK_PMM_MAX_PHYS
    top = round_up(top, FK_VMM_SIZE_2M)
    map_top = top

    status = FK_VMM_OK
    p = 0_c_int64_t
    do while (p < top)
       ! A 2 MiB page that overlaps a device aperture is LEFT UNMAPPED, not
       ! mapped and later fixed: the aperture gets its own write-combining
       ! mapping at FK_VMM_MMIO, and a write-back alias of the same frames is
       ! undefined behaviour rather than a performance question.  The cost is
       ! a hole in the linear map over memory that was never RAM.
       if (.not. hits_hole(p)) then
          status = vmm_map_2m(FK_VMM_PHYSMAP + p, p, perm(.true., .false.))
          if (status /= FK_VMM_OK) return
       end if
       p = p + FK_VMM_SIZE_2M
    end do
  end function map_physmap

  pure function hits_hole(p) result(hit)
    implicit none
    integer(c_int64_t), intent(in) :: p
    logical :: hit
    integer(c_int32_t) :: i

    hit = .false.
    do i = 1_c_int32_t, hole_count
       if (hole_bytes(i) > 0_c_int64_t .and. &
           p < hole_base(i) + hole_bytes(i) .and. &
           p + FK_VMM_SIZE_2M > hole_base(i)) then
          hit = .true.
          return
       end if
    end do
  end function hits_hole

  !> Declare a physical span the linear map must not cover.  MUST be called
  !! before vmm_init; afterwards the tables already exist.
  subroutine vmm_reserve_mmio(phys, bytes) bind(c, name="vmm_reserve_mmio")
    implicit none
    integer(c_int64_t), intent(in), value :: phys, bytes

    if (bytes <= 0_c_int64_t) return
    ! Refusing beyond the last slot is deliberate: a dropped reservation is a
    ! write-back alias nothing would report, which is the defect this list was
    ! introduced to remove.  vmm_reserved_holes() is what a caller checks.
    if (hole_count >= FK_VMM_MAX_HOLES) return
    hole_count = hole_count + 1_c_int32_t
    hole_base(hole_count)  = round_down(phys, FK_VMM_SIZE_2M)
    hole_bytes(hole_count) = round_up(phys + bytes, FK_VMM_SIZE_2M) &
                             - hole_base(hole_count)
  end subroutine vmm_reserve_mmio

  ! Remove linear-map coverage for a device aperture discovered AFTER the map
  ! was built.  vmm_reserve_mmio is the same idea for an aperture known BEFORE
  ! vmm_init, and an address that comes out of an ACPI table cannot use it:
  ! reading that table needs the very map the reservation would have holed.
  !
  ! REFUSES a range overlapping reported RAM.  Two memory types for one
  ! physical page is undefined (SDM Vol.3 11.12.4), and when firmware claims a
  ! device aperture inside RAM the answer is to believe neither of them, not to
  ! quietly unmap memory the allocator is already handing out.
  !
  ! Whole 2 MiB pages, because that is the granularity map_physmap built the
  ! window at; a range that shares a large page with RAM is refused by the test
  ! above rather than shattered, which walk() will not do either.
  function vmm_punch_physmap(phys, bytes) result(status) &
       bind(c, name="vmm_punch_physmap")
    implicit none
    integer(c_int64_t), intent(in), value :: phys, bytes
    integer(c_int32_t) :: status
    integer(c_int64_t) :: lo, hi, p, e, entry, tbl
    integer(c_int64_t), pointer :: t(:)
    integer(c_int32_t) :: i, sh

    status = FK_VMM_OK
    if (bytes <= 0_c_int64_t) return
    if (pml4_phys == 0_c_int64_t) then
       status = FK_VMM_E_NOT_READY
       return
    end if

    lo = round_down(phys, FK_VMM_SIZE_2M)
    hi = round_up(phys + bytes, FK_VMM_SIZE_2M)

    do i = 1_c_int32_t, pmm_region_count()
       if (pmm_region_type(i) /= FK_PMM_TYPE_AVAILABLE) cycle
       e = pmm_region_base(i) + pmm_region_len(i)
       if (lo < e .and. hi > pmm_region_base(i)) then
          status = FK_VMM_E_IS_RAM
          return
       end if
    end do

    p = lo
    do while (p < hi)
       if (p < map_top) then
          call walk_leaf(FK_VMM_PHYSMAP + p, entry, sh)
          ! Only a 2 MiB leaf that is actually there.  walk() below descends
          ! rather than builds, because walk_leaf just proved every level
          ! above it exists -- so a punch never allocates a frame.
          if (entry /= 0_c_int64_t .and. sh == 21_c_int32_t) then
             call walk(FK_VMM_PHYSMAP + p, 21_c_int32_t, tbl, status)
             if (status /= FK_VMM_OK) return
             call table_at(tbl, t)
             t(idx(FK_VMM_PHYSMAP + p, 21_c_int32_t)) = 0_c_int64_t
             call fk_invlpg(FK_VMM_PHYSMAP + p)
          end if
       end if
       p = p + FK_VMM_SIZE_2M
    end do
  end function vmm_punch_physmap

  function vmm_reserved_holes() result(n) bind(c, name="vmm_reserved_holes")
    implicit none
    integer(c_int32_t) :: n

    n = hole_count
  end function vmm_reserved_holes

  !> Map BYTES of physical device memory at VIRT, 4 KiB at a time.  Page
  !! granularity rather than 2 MiB: an aperture is rarely a whole number of
  !! large pages, and rounding one up would map whatever sits behind it.
  function vmm_map_mmio(virt, phys, bytes, flags) result(status) &
       bind(c, name="vmm_map_mmio")
    implicit none
    integer(c_int64_t), intent(in), value :: virt, phys, bytes, flags
    integer(c_int32_t) :: status
    integer(c_int64_t) :: off, last

    status = FK_VMM_OK
    if (bytes <= 0_c_int64_t) return
    last = round_up(bytes, FK_VMM_PAGE_SIZE)
    off  = 0_c_int64_t
    do while (off < last)
       status = vmm_map_page(virt + off, phys + off, flags)
       if (status /= FK_VMM_OK) return
       off = off + FK_VMM_PAGE_SIZE
    end do
  end function vmm_map_mmio

  !> IA32_PAT, so that FK_PTE_PWT means write-combining.  Returns 0 on success.
  function vmm_pat_arm() result(s) bind(c, name="vmm_pat_arm")
    implicit none
    integer(c_int32_t) :: s

    s = fk_pat_arm()
    ! Retire every TLB entry cached under the old meaning of PAT index 1.  No
    ! mapping selects PWT yet, so this is cheap insurance rather than the SDM's
    ! full cache-disable ritual; see boot/mmu.S.
    if (s == 0_c_int32_t .and. pml4_phys /= 0_c_int64_t) call fk_write_cr3(pml4_phys)
  end function vmm_pat_arm

  function vmm_read_pat() result(v) bind(c, name="vmm_read_pat")
    implicit none
    integer(c_int64_t) :: v

    v = fk_read_pat()
  end function vmm_read_pat

  ! The identity window, rebuilt in the NEW hierarchy and thrown away by
  ! vmm_drop_identity.  It exists for exactly as long as the handoff: the
  ! descriptor tables are reloaded while it is live, and pmm_init has already
  ! read the loader's structure through the boot stub's copy of it.
  function map_identity() result(status)
    implicit none
    integer(c_int32_t) :: status
    integer(c_int64_t) :: p

    status = FK_VMM_OK
    p = 0_c_int64_t
    do while (p < FK_PMM_IDMAP_BYTES)
       status = vmm_map_2m(p, p, perm(.true., .false.))
       if (status /= FK_VMM_OK) return
       p = p + FK_VMM_SIZE_2M
    end do
  end function map_identity


  ! --- bring-up and handoff -------------------------------------------------

  function vmm_init() result(status) bind(c, name="vmm_init")
    implicit none
    integer(c_int32_t) :: status

    ! Derived, never duplicated: KERNEL_VMA already exists as a constant in
    ! linker.ld and again in boot/boot.S, and a third copy in Fortran would be
    ! a third thing that can silently disagree with the other two.
    kernel_vma  = fk_kernel_start() - fk_kernel_phys_start()
    table_count = 0_c_int64_t
    physmap_on  = .false.

    ! CR0.WP and EFER.NXE, before a single entry carrying NX is written and
    ! long before one is loaded into CR3.
    nx_on = (fk_mmu_arm() == 0_c_int32_t)
    call build_section_table()

    call new_table(pml4_phys, status)
    if (status /= FK_VMM_OK) then
       pml4_phys = 0_c_int64_t
       return
    end if

    status = map_image()
    if (status /= FK_VMM_OK) return
    status = map_physmap()
    if (status /= FK_VMM_OK) return
    status = map_identity()
  end function vmm_init

  ! Step (c) and (d) of the handoff.  The descriptor tables are reloaded while
  ! the identity window is still live, which is the ordering roadmap 1.2b spells
  ! out: GDTR and IDTR already hold higher-half bases -- fk_gdt_m and fk_idt_m
  ! build them from c_loc of a kernel object -- but the far return inside
  ! gdt_reload is what discards the hidden segment state the boot stub's
  ! physically-based descriptor left in CS.
  subroutine vmm_activate() bind(c, name="vmm_activate")
    implicit none

    call fk_write_cr3(pml4_phys)
    physmap_on = .true.
    call gdt_reload()
    call idt_reload()
  end subroutine vmm_activate

  ! Step (e) and (f).  Zeroing the entry is not enough on its own: the CPU
  ! caches translations, so the window stays usable until CR3 is reloaded and
  ! every non-global TLB entry goes with it.
  subroutine vmm_drop_identity() bind(c, name="vmm_drop_identity")
    implicit none
    integer(c_int64_t), pointer :: t(:)

    call table_at(pml4_phys, t)
    t(1) = 0_c_int64_t
    call fk_write_cr3(pml4_phys)
  end subroutine vmm_drop_identity

end module fk_vmm_m
