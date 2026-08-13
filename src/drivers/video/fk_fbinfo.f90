! SPDX-License-Identifier: GPL-2.0
! Multiboot2 framebuffer tag (type 8) -- roadmap 2.2.
!
! Runs BEFORE the higher-half handoff: the MBI is a physical address and is
! readable only through the boot stub's identity window, exactly as pmm_build
! reads the memory map.  What it produces is consumed after the handoff.
!
! The tag walk is this module's own and not the PMM's.  Two walks over an
! 8-byte-aligned tag list is cheaper than a dependency that makes a video
! driver's correctness a function of the allocator's parse state.
module fk_fbinfo_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t, c_ptr, &
                                         c_f_pointer
  use fk_pmm_m, only: FK_PMM_IDMAP_BYTES
  implicit none
  private
  public :: FK_FB_WORDS, FK_FB_TAG, FK_FB_BASE, FK_FB_PITCH, FK_FB_WIDTH, &
            FK_FB_HEIGHT, FK_FB_BPP, FK_FB_TYPE, FK_FB_MASKS, FK_FB_VIRT, &
            FK_FB_BYTES, FK_FB_MAGIC, FK_FB_TYPE_RGB, &
            FK_FB_OK, FK_FB_E_MBI, FK_FB_E_NO_TAG, FK_FB_E_TAG_OVERRUN, &
            FK_FB_E_NOT_RGB, FK_FB_E_GEOMETRY, FK_FB_E_MASKS, FK_FB_E_ALIGN, &
            fk_fb_info, fb_probe, fb_pixel_pack, fb_note_mapping

  integer(c_int32_t), parameter :: FK_FB_WORDS = 10_c_int32_t

  ! Indices into fk_fb_info.  It is ONE bind(c) array rather than ten scalars
  ! so tools/qmp-sentinel.py can pmemsave the whole handoff in one read.
  integer(c_int32_t), parameter :: FK_FB_TAG    = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_FB_BASE   = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_FB_PITCH  = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_FB_WIDTH  = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_FB_HEIGHT = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_FB_BPP    = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_FB_TYPE   = 7_c_int32_t
  integer(c_int32_t), parameter :: FK_FB_MASKS  = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_FB_VIRT   = 9_c_int32_t
  integer(c_int32_t), parameter :: FK_FB_BYTES  = 10_c_int32_t

  integer(c_int64_t), parameter :: FK_FB_MAGIC = int(z'46425F49', c_int64_t)

  integer(c_int32_t), parameter :: MB2_TAG_END = 0_c_int32_t
  integer(c_int32_t), parameter :: MB2_TAG_FB  = 8_c_int32_t

  integer(c_int32_t), parameter :: FK_FB_TYPE_RGB = 1_c_int32_t

  integer(c_int32_t), parameter :: FK_FB_OK           =  0_c_int32_t
  integer(c_int32_t), parameter :: FK_FB_E_MBI        = -1_c_int32_t
  integer(c_int32_t), parameter :: FK_FB_E_NO_TAG     = -2_c_int32_t
  integer(c_int32_t), parameter :: FK_FB_E_TAG_OVERRUN= -3_c_int32_t
  integer(c_int32_t), parameter :: FK_FB_E_NOT_RGB    = -4_c_int32_t
  integer(c_int32_t), parameter :: FK_FB_E_GEOMETRY   = -5_c_int32_t
  integer(c_int32_t), parameter :: FK_FB_E_MASKS      = -6_c_int32_t
  integer(c_int32_t), parameter :: FK_FB_E_ALIGN      = -7_c_int32_t

  integer(c_int64_t), bind(c, name="fk_fb_info") :: fk_fb_info(FK_FB_WORDS) &
       = 0_c_int64_t

  ! Channel geometry, kept unpacked for fb_pixel_pack.  Written by fb_probe.
  integer(c_int32_t), save :: r_pos = 0_c_int32_t, r_size = 0_c_int32_t
  integer(c_int32_t), save :: g_pos = 0_c_int32_t, g_size = 0_c_int32_t
  integer(c_int32_t), save :: b_pos = 0_c_int32_t, b_size = 0_c_int32_t

  integer(c_int32_t), pointer :: mbi_w(:)

contains

  function u32(off) result(v)
    implicit none
    integer(c_int32_t), intent(in) :: off
    integer(c_int64_t) :: v

    v = iand(int(mbi_w(off / 4_c_int32_t + 1_c_int32_t), c_int64_t), &
             int(z'FFFFFFFF', c_int64_t))
  end function u32

  function u64(off) result(v)
    implicit none
    integer(c_int32_t), intent(in) :: off
    integer(c_int64_t) :: v

    v = ior(u32(off), ishft(u32(off + 4_c_int32_t), 32))
  end function u64

  ! Byte OFF of the structure, unsigned.  The colour-info fields are u8 and the
  ! int32 view is the only one this module maps.
  function u8(off) result(v)
    implicit none
    integer(c_int32_t), intent(in) :: off
    integer(c_int32_t) :: v

    v = int(iand(ishft(u32(iand(off, not(3_c_int32_t))), &
                       -8_c_int32_t * iand(off, 3_c_int32_t)), &
                 255_c_int64_t), c_int32_t)
  end function u8

  !> Locate and validate the Multiboot2 framebuffer tag.  MBI_PHYS is a
  !! PHYSICAL address and is dereferenced through the boot stub's identity
  !! window, so this must run before vmm_drop_identity.
  function fb_probe(mbi_phys) result(status) bind(c, name="fb_probe")
    implicit none
    integer(c_int64_t), intent(in), value :: mbi_phys
    integer(c_int32_t) :: status
    type(c_ptr) :: p
    integer(c_int64_t) :: total, base
    integer(c_int32_t) :: off, fb_off, tag_type, tag_size, i

    do i = 1_c_int32_t, FK_FB_WORDS
       fk_fb_info(i) = 0_c_int64_t
    end do

    if (mbi_phys == 0_c_int64_t .or. iand(mbi_phys, 7_c_int64_t) /= 0_c_int64_t &
        .or. mbi_phys < 0_c_int64_t &
        .or. mbi_phys > FK_PMM_IDMAP_BYTES - 8_c_int64_t) then
       status = FK_FB_E_MBI
       return
    end if

    p = transfer(mbi_phys, p)
    call c_f_pointer(p, mbi_w, [2])
    total = u32(0_c_int32_t)
    if (total < 16_c_int64_t .or. mbi_phys + total > FK_PMM_IDMAP_BYTES) then
       status = FK_FB_E_MBI
       return
    end if
    call c_f_pointer(p, mbi_w, [int((total + 3_c_int64_t) / 4_c_int64_t, c_int32_t)])

    fb_off = -1_c_int32_t
    off = 8_c_int32_t
    do while (int(off, c_int64_t) + 8_c_int64_t <= total)
       tag_type = int(u32(off), c_int32_t)
       tag_size = int(u32(off + 4_c_int32_t), c_int32_t)
       if (tag_size < 8_c_int32_t .or. &
           int(off, c_int64_t) + int(tag_size, c_int64_t) > total) then
          status = FK_FB_E_TAG_OVERRUN
          return
       end if
       if (tag_type == MB2_TAG_END) exit
       if (tag_type == MB2_TAG_FB) fb_off = off
       off = off + iand(tag_size + 7_c_int32_t, not(7_c_int32_t))
    end do

    if (fb_off < 0_c_int32_t) then
       status = FK_FB_E_NO_TAG
       return
    end if

    ! The common header is 32 bytes: type, size, addr(u64), pitch, width,
    ! height, bpp(u8), fb_type(u8), reserved(u16).  The reserved field is u16
    ! in multiboot2.h -- the prose in the specification says u8, and reading it
    ! that way shifts every colour-mask byte one position and yields a red
    ! channel at bit 0 of nothing.  38 bytes is the smallest RGB tag.
    if (int(u32(fb_off + 4_c_int32_t), c_int32_t) < 38_c_int32_t) then
       status = FK_FB_E_TAG_OVERRUN
       return
    end if

    base = u64(fb_off + 8_c_int32_t)
    fk_fb_info(FK_FB_BASE)   = base
    fk_fb_info(FK_FB_PITCH)  = u32(fb_off + 16_c_int32_t)
    fk_fb_info(FK_FB_WIDTH)  = u32(fb_off + 20_c_int32_t)
    fk_fb_info(FK_FB_HEIGHT) = u32(fb_off + 24_c_int32_t)
    fk_fb_info(FK_FB_BPP)    = int(u8(fb_off + 28_c_int32_t), c_int64_t)
    fk_fb_info(FK_FB_TYPE)   = int(u8(fb_off + 29_c_int32_t), c_int64_t)

    r_pos  = u8(fb_off + 32_c_int32_t)
    r_size = u8(fb_off + 33_c_int32_t)
    g_pos  = u8(fb_off + 34_c_int32_t)
    g_size = u8(fb_off + 35_c_int32_t)
    b_pos  = u8(fb_off + 36_c_int32_t)
    b_size = u8(fb_off + 37_c_int32_t)
    fk_fb_info(FK_FB_MASKS) = ior(ior(ior(int(r_pos, c_int64_t), &
         ishft(int(r_size, c_int64_t),  8)), &
         ior(ishft(int(g_pos, c_int64_t), 16), &
             ishft(int(g_size, c_int64_t), 24))), &
         ior(ishft(int(b_pos, c_int64_t), 32), &
             ishft(int(b_size, c_int64_t), 40)))

    if (fk_fb_info(FK_FB_TYPE) /= int(FK_FB_TYPE_RGB, c_int64_t)) then
       status = FK_FB_E_NOT_RGB
       return
    end if
    ! 32 bits per pixel only: the renderer addresses the framebuffer as an
    ! array of int32, so 24bpp would shear the picture one byte per pixel.
    if (fk_fb_info(FK_FB_BPP) /= 32_c_int64_t) then
       status = FK_FB_E_NOT_RGB
       return
    end if
    if (fk_fb_info(FK_FB_WIDTH) <= 0_c_int64_t .or. &
        fk_fb_info(FK_FB_HEIGHT) <= 0_c_int64_t .or. &
        fk_fb_info(FK_FB_PITCH) < fk_fb_info(FK_FB_WIDTH) * 4_c_int64_t .or. &
        iand(fk_fb_info(FK_FB_PITCH), 3_c_int64_t) /= 0_c_int64_t) then
       status = FK_FB_E_GEOMETRY
       return
    end if
    if (.not. chan_ok(r_pos, r_size) .or. .not. chan_ok(g_pos, g_size) .or. &
        .not. chan_ok(b_pos, b_size)) then
       status = FK_FB_E_MASKS
       return
    end if
    ! A BAR that is not page-aligned cannot be mapped without an offset the
    ! renderer would then have to carry; no firmware produces one.
    if (base == 0_c_int64_t .or. iand(base, 4095_c_int64_t) /= 0_c_int64_t) then
       status = FK_FB_E_ALIGN
       return
    end if

    fk_fb_info(FK_FB_BYTES) = fk_fb_info(FK_FB_PITCH) * fk_fb_info(FK_FB_HEIGHT)
    fk_fb_info(FK_FB_TAG)   = FK_FB_MAGIC
    status = FK_FB_OK
  end function fb_probe

  pure function chan_ok(pos, siz) result(ok)
    implicit none
    integer(c_int32_t), intent(in) :: pos, siz
    logical :: ok

    ok = siz >= 1_c_int32_t .and. siz <= 8_c_int32_t .and. &
         pos >= 0_c_int32_t .and. pos + siz <= 32_c_int32_t
  end function chan_ok

  !> Pack an 8-bit-per-channel colour into the firmware's pixel layout.
  !!
  !! The renderer stores whatever word this returns.  Channel positions are
  !! read from the tag rather than assumed: BGRX (blue at bit 0) is what x86
  !! firmware reports in practice, and a kernel that hardcodes it draws a red
  !! panic banner in blue on the machine that does not.
  function fb_pixel_pack(r, g, b) result(px) bind(c, name="fb_pixel_pack")
    implicit none
    integer(c_int32_t), intent(in), value :: r, g, b
    integer(c_int32_t) :: px

    px = ior(ior(chan(r, r_pos, r_size), chan(g, g_pos, g_size)), &
             chan(b, b_pos, b_size))
  end function fb_pixel_pack

  ! An 8-bit sample narrowed to SIZ bits and shifted into place.  Narrowing is
  ! a right shift, not a scale: it is what the hardware's own DAC does.
  pure function chan(v, pos, siz) result(w)
    implicit none
    integer(c_int32_t), intent(in) :: v, pos, siz
    integer(c_int32_t) :: w

    if (siz <= 0_c_int32_t) then
       w = 0_c_int32_t
       return
    end if
    w = ishft(ishft(iand(v, 255_c_int32_t), siz - 8_c_int32_t), pos)
  end function chan

  !> Record the virtual address the VMM gave the framebuffer, so the handoff
  !! block read from outside the guest describes the mapping that exists.
  subroutine fb_note_mapping(virt) bind(c, name="fb_note_mapping")
    implicit none
    integer(c_int64_t), intent(in), value :: virt

    fk_fb_info(FK_FB_VIRT) = virt
  end subroutine fb_note_mapping

end module fk_fbinfo_m
