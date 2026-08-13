! SPDX-License-Identifier: GPL-2.0
!> UEFI GOP software renderer -- roadmap items 2.2 (framebuffer mapping) and
!! 2.4 (software renderer).  The 8x16 font itself (2.3) is fk_font_8x16.f90;
!! this module walks it through vga_font_row() and owns no glyph data.
!!
!! TARGET REALITY.  This is a 64-bit UEFI machine.  There is no 0xB8000 text
!! mode, no BIOS int 10h and no VGA hardware to program: the firmware hands the
!! bootloader a linear Graphics Output Protocol framebuffer and everything on
!! screen is a pixel this module wrote.  The `vga_` symbol names are the
!! project's chosen console-facing names (roadmap 2.4) and are historical only
!! -- nothing here touches a VGA register.
!!
!! MEMORY MODEL.  vga_init_framebuffer() takes the framebuffer base as a raw
!! address and maps a Fortran pointer onto it with C_F_POINTER.  POINTER is used
!! deliberately and is not a libgfortran dependency: the target is firmware MMIO
!! that already exists, nothing is allocated, and the pointer is rank-1
!! explicit-shape so no array descriptor is ever handed across the C boundary.
!! `nm -u` on this object is empty (tools/linktest.sh), which is the property
!! the plan's "no libgfortran" rule actually asserts.
!!
!! PHYSICAL vs VIRTUAL -- THE CALLER'S CONTRACT, AND A REBOOT WAITING TO HAPPEN.
!! This module performs NO address translation. It stores to whatever address it
!! is handed, and it cannot tell a physical address from a virtual one. That is
!! the right division of labour -- a renderer is not a memory manager -- but it
!! makes the caller responsible for something easy to get fatally wrong:
!!
!!   THE ADDRESS PASSED TO vga_init_framebuffer MUST ALREADY BE MAPPED AND
!!   WRITABLE IN THE PAGE TABLES THAT ARE LIVE WHEN vga_plot_pixel RUNS.
!!
!! Long mode cannot run with paging off, so by the time any of this executes
!! SOME page table is active -- the bootloader's. GRUB/Multiboot2 hands over an
!! identity map (virtual == physical) that typically covers only the low 1-4 GiB.
!! On modern hardware the GOP framebuffer is a PCI BAR mapped ABOVE 4 GiB, so
!! the address the firmware reports is very often NOT in that identity map.
!!
!! Writing to it then takes a page fault. Roadmap 3.2 (the IDT) does not exist,
!! so there is no page-fault handler; the fault escalates to a double fault,
!! then a triple fault, and the machine silently reboots. That failure looks
!! exactly like "the kernel crashed" while being purely an unmapped-address bug.
!!
!! Order of operations, once the pieces exist:
!!   before 3.5 (VMM):  the boot stub must guarantee the framebuffer range is
!!                      identity-mapped -- for a >4 GiB BAR it must ADD that
!!                      mapping, not assume it.
!!   after  3.5:        the VMM maps the framebuffer's physical range and the
!!                      VIRTUAL address it returns is what gets passed here.
!!
!! Cache attributes matter too: a framebuffer mapped write-back cached renders
!! erratically. GOP wants write-combining (PAT/MTRR). That is the VMM's job, not
!! this module's -- but it is why VOLATILE below is not negotiable.
!!
!! Nothing in this module has ever executed outside a host test against ordinary
!! malloc'd memory, which is mapped by construction. None of the above is
!! therefore proven -- it is the contract the caller will have to meet.
!!
!! WHY VOLATILE, STATED HONESTLY.  The framebuffer is written and never read
!! back, so in principle every store into it is dead.  In practice it is not
!! eliminated today: gfortran cannot prove the target is unobserved, because the
!! address arrives opaquely through C_F_POINTER.  Removing VOLATILE was measured
!! (gfortran 16.1.1, -O2, kernel flags) and the store survives in every routine --
!! the only change is that descriptor fields get folded into memory operands
!! instead of being materialised in registers.
!!
!! It is kept anyway, for the same reason the Makefile keeps -fwrapv: the
!! property is one the compiler currently *chooses* to provide, not one it
!! *owes* us.  VOLATILE is what actually buys the guarantee that each assignment
!! is one real memory access, not merged with its neighbours, not hoisted out of
!! the glyph loop, and not cached across a call -- which starts to matter the
!! moment the framebuffer is mapped write-combining.
!!
!! Note the limit of the evidence: the differential test CANNOT catch VOLATILE's
!! removal, because a host test reads the buffer back and so makes every store
!! observable by construction.  See docs/HARNESS-VALIDATION-PHASE2.md, mutation
!! 12 -- it is recorded there as an escape, not quietly dropped.
!!
!! WHY BYTES-PER-SCANLINE IS NOT WIDTH.  GOP reports PixelsPerScanLine, which is
!! routinely larger than the visible width (1920 visible on a 1024-aligned 2048
!! stride is common).  Addressing by `y*width + x` therefore produces a picture
!! that shears progressively down the screen.  The stride is carried separately
!! and every offset uses it.
!!
!! UNSIGNED-SAFETY / ABI NOTES (house rules, see docs plan Global Constraints):
!!   * The framebuffer base is a physical u64.  It is carried in
!!     integer(c_int64_t) as a BIT PATTERN and converted with TRANSFER, never
!!     with arithmetic -- an address at or above 2**63 looks negative and any
!!     signed comparison on it would be wrong.  No comparison is performed on
!!     it; it is transferred to C_PTR and used only as a base.
!!   * Pixel offsets are computed in c_int64_t.  A 32-bit offset overflows at
!!     2**31 bytes, which a 7680x4320 framebuffer approaches; the widening is
!!     not defensive padding.
!!   * The colour word is passed through verbatim as a 32-bit pattern.  Channel
!!     order is whatever the firmware reports (GOP is normally BGRx on x86);
!!     this module does no conversion, so the caller's 0x00RRGGBB or 0x00BBGGRR
!!     reaches memory unchanged.
!!   * Font bytes are stored pre-biased in c_int8_t (0xFF -> -1) and unmasked
!!     with IAND(..., 255) by vga_font_row(), exactly as fk_bcd does for u8;
!!     this module only ever sees the unbiased 0..255 result.
!!   * Every store into the framebuffer is a SCALAR store.  An array-section
!!     assignment (fb(a:b) = colour) would let gfortran emit a memset/memcpy
!!     call, which is an undefined symbol in a freestanding object and fails
!!     tools/linktest.sh gate (c).
!!
!! CLIPPING.  Every entry point validates against the initialised geometry and
!! silently drops out-of-range work.  The kernel panic handler is roadmap 1.4
!! and does not exist yet, so there is nothing safe to call on error; a driver
!! that scribbles past the framebuffer before the memory manager exists is a
!! far worse outcome than a dropped pixel.
module fk_gop_renderer_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t, c_size_t, &
                                         c_char, c_ptr, c_f_pointer, c_null_char
  ! The font is DATA and lives in its own module. Only the accessor is used
  ! here, never the array: gfortran materialises a PARAMETER array into the
  ! .rodata of every object that indexes it, so indexing FONT_8X16 from this
  ! module too would put a second 4096-byte copy in the kernel image. See the
  ! header of fk_font_8x16.f90.
  use fk_font_8x16_m, only: FONT_W, FONT_H, vga_font_row
  use fk_string_m,    only: fk_memmove
  implicit none
  private
  public :: vga_init_framebuffer, vga_plot_pixel, vga_print_char, &
            vga_print_string, vga_fill_rect, vga_scroll_up, &
            vga_width, vga_height

  ! --- Framebuffer state, established by vga_init_framebuffer -------------
  ! Module variables are implicitly SAVE.  They live in .bss and need no
  ! runtime initialiser, so they cost nothing at link time.
  !
  ! VOLATILE: see the header.  Without it the plotting loops are dead stores.
  integer(c_int32_t), pointer, volatile :: fb(:) => null()
  integer(c_int32_t) :: fb_width  = 0_c_int32_t   ! visible pixels per row
  integer(c_int32_t) :: fb_height = 0_c_int32_t   ! visible rows
  integer(c_int64_t) :: fb_stride = 0_c_int64_t   ! 32-bit words per scanline
  logical            :: fb_ready  = .false.

  ! The base as an INTEGER as well as a pointer.  vga_scroll_up hands scanline
  ! addresses to fk_memmove, which takes c_ptr; deriving them arithmetically
  ! from the value that arrived is the same transfer c_f_pointer already did,
  ! and avoids C_LOC on a VOLATILE pointer target.
  integer(c_int64_t) :: fb_addr   = 0_c_int64_t


contains

  !> Map the renderer onto a firmware-provided GOP framebuffer.
  !!
  !! base_addr   physical/identity-mapped base of the framebuffer (u64 pattern)
  !! width       visible pixels per row      (GOP HorizontalResolution)
  !! height      visible rows                (GOP VerticalResolution)
  !! pitch_bytes BYTES per scanline          (GOP PixelsPerScanLine * 4)
  !!
  !! Returns 0 on success, negative on refusal.  The renderer stays disarmed on
  !! refusal, so a bad handoff yields a black screen rather than corrupted RAM.
  function vga_init_framebuffer(base_addr, width, height, pitch_bytes) &
       result(status) bind(c, name="vga_init_framebuffer")
    implicit none
    integer(c_int64_t), intent(in), value :: base_addr
    integer(c_int32_t), intent(in), value :: width, height, pitch_bytes
    integer(c_int32_t)                    :: status
    type(c_ptr)        :: base
    integer(c_int64_t) :: words

    fb_ready = .false.

    ! Geometry must be positive and the scanline must hold the visible row.
    if (width <= 0_c_int32_t .or. height <= 0_c_int32_t) then
       status = -1_c_int32_t
       return
    end if
    ! WIDENED DELIBERATELY. `pitch_bytes < width * 4_c_int32_t` computes the
    ! product in c_int32_t and wraps for width >= 2**29, so the comparison went
    ! FALSE for every possible pitch and this guard failed OPEN on exactly the
    ! garbage handoff it exists to catch: width=INT32_MAX gave width*4 == -4,
    ! init returned 0, and the renderer armed with fb_width=2147483647 against
    ! a 1920-word stride. It also let a NEGATIVE pitch through, which the
    ! logical shift below then turns into a ~1e9-word stride. In 64 bits the
    ! product cannot wrap (max width*4 == 2**33), and since width >= 1 implies
    ! width*4 >= 4, every negative pitch is refused here too.
    if (int(pitch_bytes, c_int64_t) < int(width, c_int64_t) * 4_c_int64_t) then
       status = -2_c_int32_t
       return
    end if

    ! 32-bit pixels only.  A pitch that is not a whole number of 32-bit words
    ! cannot be addressed as an integer(c_int32_t) array at all; refuse rather
    ! than silently truncate and shear the picture.
    if (iand(pitch_bytes, 3_c_int32_t) /= 0_c_int32_t) then
       status = -3_c_int32_t
       return
    end if

    ! A null base is the signature of a bootloader that never filled the
    ! framebuffer tag in; mapping it would fault on the first store.
    if (base_addr == 0_c_int64_t) then
       status = -4_c_int32_t
       return
    end if

    fb_width  = width
    fb_height = height
    fb_stride = int(shiftr(pitch_bytes, 2), c_int64_t)

    ! The last addressable word is the last visible pixel of the last row; the
    ! trailing off-screen slack of the final scanline is deliberately excluded
    ! from the mapping so an off-by-one cannot reach past the firmware region.
    words = (int(fb_height, c_int64_t) - 1_c_int64_t) * fb_stride &
            + int(fb_width, c_int64_t)

    ! TRANSFER, not INT(): the address is a bit pattern that may have its high
    ! bit set, and no arithmetic may be performed on it.
    base    = transfer(base_addr, base)
    fb_addr = base_addr
    call c_f_pointer(base, fb, [words])

    fb_ready = .true.
    status   = 0_c_int32_t
  end function vga_init_framebuffer

  !> Write one 32-bit pixel.  Out-of-range coordinates are dropped.
  subroutine vga_plot_pixel(x, y, hex_color) bind(c, name="vga_plot_pixel")
    implicit none
    integer(c_int32_t), intent(in), value :: x, y, hex_color
    integer(c_int64_t) :: off

    if (.not. fb_ready) return
    if (x < 0_c_int32_t .or. x >= fb_width)  return
    if (y < 0_c_int32_t .or. y >= fb_height) return

    ! Offset in 32-bit words, widened before multiplying: a 32-bit product
    ! overflows on large framebuffers.  +1 converts to Fortran's 1-based index.
    off = int(y, c_int64_t) * fb_stride + int(x, c_int64_t)
    fb(off + 1_c_int64_t) = hex_color
  end subroutine vga_plot_pixel

  !> Draw one glyph with its top-left corner at (x, y).
  !!
  !! Bit 7 of each font byte is the LEFTMOST pixel -- the kernel's font tables
  !! are MSB-first, and reading them LSB-first mirrors every glyph horizontally,
  !! a defect that survives any test which only counts lit pixels.
  !!
  !! Background pixels are left untouched rather than filled, so glyphs compose
  !! over whatever is already on screen.  Callers wanting an opaque cell call
  !! vga_fill_rect first.
  subroutine vga_print_char(c, x, y, color) bind(c, name="vga_print_char")
    implicit none
    character(kind=c_char), intent(in), value :: c
    integer(c_int32_t),     intent(in), value :: x, y, color
    integer(c_int32_t) :: code, row, dx, bits

    if (.not. fb_ready) return

    ! ICHAR on a length-1 c_char is an inline byte load, not a libgfortran
    ! string call.  IAND keeps it in 0..255 whatever the host's char signedness.
    code = iand(ichar(c, c_int32_t), 255_c_int32_t)

    do row = 0_c_int32_t, FONT_H - 1_c_int32_t
       ! code is masked to 0..255 and row is bounded by the loop, so the
       ! accessor's -1 refusal is unreachable from here.
       bits = vga_font_row(code, row)
       if (bits == 0_c_int32_t) cycle          ! blank row: nothing to draw
       do dx = 0_c_int32_t, FONT_W - 1_c_int32_t
          ! MSB-first: dx=0 tests bit 7.
          if (btest(bits, 7_c_int32_t - dx)) then
             call vga_plot_pixel(x + dx, y + row, color)
          end if
       end do
    end do
  end subroutine vga_print_char

  !> Draw a NUL-terminated C string starting at (x, y), advancing 8px per glyph.
  !!
  !! The dummy is ASSUMED-SIZE, never `s(:)`.  An assumed-shape dummy makes
  !! gfortran expect a CFI_cdesc_t descriptor where C passed a bare `char *`,
  !! and the callee then reads the string bytes as a descriptor header.  See
  !! docs/AUDIT-PHASE1.md, "On hidden array descriptors".
  !!
  !! max_chars bounds the scan so a caller that loses its terminator walks a
  !! bounded distance instead of the whole address space.  Glyphs that fall off
  !! the right edge are still emitted; vga_plot_pixel clips them per pixel.
  subroutine vga_print_string(s, max_chars, x, y, color) &
       bind(c, name="vga_print_string")
    implicit none
    character(kind=c_char), intent(in)        :: s(*)
    integer(c_int32_t),     intent(in), value :: max_chars, x, y, color
    integer(c_int32_t) :: i
    integer(c_int64_t) :: gx

    if (.not. fb_ready) return
    if (max_chars <= 0_c_int32_t) return

    do i = 1_c_int32_t, max_chars
       if (s(i) == c_null_char) return

       ! 64-bit advance. `x + (i-1)*FONT_W` in c_int32_t wraps once the string
       ! is long enough (i >= 2**28), and with -fwrapv it wraps QUIETLY back to
       ! a negative x, so glyphs reappear on the left edge instead of running
       ! off the right. Once the origin is past the right edge every remaining
       ! glyph is invisible, so stop rather than walk the rest of the string.
       gx = int(x, c_int64_t) + int(i - 1_c_int32_t, c_int64_t) * int(FONT_W, c_int64_t)
       if (gx >= int(fb_width, c_int64_t)) return

       call vga_print_char(s(i), int(gx, c_int32_t), y, color)
    end do
  end subroutine vga_print_string

  !> Fill an axis-aligned rectangle, clipped to the visible framebuffer.
  !!
  !! Scalar stores only.  `fb(a:b) = color` would be the natural Fortran and is
  !! exactly what must not be written: gfortran may lower an array-section
  !! assignment to a memset call, which is an undefined symbol in a
  !! freestanding object.
  subroutine vga_fill_rect(x, y, w, h, color) bind(c, name="vga_fill_rect")
    implicit none
    integer(c_int32_t), intent(in), value :: x, y, w, h, color
    integer(c_int32_t) :: px, py
    integer(c_int64_t) :: x0, y0, x1, y1

    if (.not. fb_ready) return
    if (w <= 0_c_int32_t .or. h <= 0_c_int32_t) return

    ! CLAMP IN 64 BITS, THEN LOOP. The obvious `do py = y, y + h - 1` computes
    ! its bound in c_int32_t, so x=2 with w=INT32_MAX wraps the limit negative
    ! and the loop body never runs -- a rectangle that should have filled the
    ! screen silently drew nothing. Clamping to the visible area first also
    ! means a huge w/h costs O(visible pixels) rather than O(w*h) iterations of
    ! a per-pixel clip, which matters when this is a boot-time splash fill.
    x0 = max(int(x, c_int64_t), 0_c_int64_t)
    y0 = max(int(y, c_int64_t), 0_c_int64_t)
    x1 = min(int(x, c_int64_t) + int(w, c_int64_t) - 1_c_int64_t, &
             int(fb_width,  c_int64_t) - 1_c_int64_t)
    y1 = min(int(y, c_int64_t) + int(h, c_int64_t) - 1_c_int64_t, &
             int(fb_height, c_int64_t) - 1_c_int64_t)
    ! No `if (x1 < x0) return` guard: a Fortran DO whose upper bound is below
    ! its lower bound executes zero times, so the empty-rectangle case is
    ! already handled by the loops themselves. An explicit guard here is dead
    ! code -- removing it was verified not to change the suite's result.
    do py = int(y0, c_int32_t), int(y1, c_int32_t)
       do px = int(x0, c_int32_t), int(x1, c_int32_t)
          call vga_plot_pixel(px, py, color)
       end do
    end do
  end subroutine vga_fill_rect

  !> Visible geometry, for a console that must decide how many cells fit.
  function vga_width() result(w) bind(c, name="vga_width")
    implicit none
    integer(c_int32_t) :: w

    w = fb_width
  end function vga_width

  function vga_height() result(h) bind(c, name="vga_height")
    implicit none
    integer(c_int32_t) :: h

    h = fb_height
  end function vga_height

  !> Move the pixel band [y0, y0+h) up by DY rows and fill the DY rows it
  !! vacated with COLOR.  This is what a text console scrolls with.
  !!
  !! ONE fk_memmove PER SCANLINE, and not one call for the whole band.  The
  !! stride is routinely wider than the visible width, so a single call would
  !! copy the off-screen slack too -- including the slack of the LAST scanline,
  !! which vga_init_framebuffer deliberately left outside the mapped extent.
  !! Per-row it cannot reach past the last visible pixel, and the destination
  !! row is always above the source row, so no call overlaps itself.
  !!
  !! COST, STATED.  The framebuffer is write-combining: writes are buffered,
  !! reads are not, and every byte of a scroll is read once and written once.
  !! A full-screen scroll is therefore the most expensive thing this driver
  !! does by two orders of magnitude, and src/boot/fk_kmain.f90 prints what it
  !! measured in PIT ticks rather than leaving that as folklore.
  subroutine vga_scroll_up(y0, h, dy, color) bind(c, name="vga_scroll_up")
    implicit none
    integer(c_int32_t), intent(in), value :: y0, h, dy, color
    integer(c_int32_t) :: rows, r
    integer(c_int64_t) :: pitch, row_bytes, dst, src
    type(c_ptr) :: dp, sp

    if (.not. fb_ready) return
    if (h <= 0_c_int32_t .or. dy <= 0_c_int32_t) return
    if (y0 < 0_c_int32_t .or. y0 >= fb_height) return

    ! Clip the band to the screen before anything is moved: a caller that asks
    ! to scroll more rows than exist must not read past the last one.
    rows = min(h, fb_height - y0)
    if (dy >= rows) then
       call vga_fill_rect(0_c_int32_t, y0, fb_width, rows, color)
       return
    end if

    pitch     = fb_stride * 4_c_int64_t
    row_bytes = int(fb_width, c_int64_t) * 4_c_int64_t
    do r = 0_c_int32_t, rows - dy - 1_c_int32_t
       dst = fb_addr + int(y0 + r,      c_int64_t) * pitch
       src = fb_addr + int(y0 + r + dy, c_int64_t) * pitch
       dp  = transfer(dst, dp)
       sp  = transfer(src, sp)
       dp  = fk_memmove(dp, sp, int(row_bytes, c_size_t))
    end do
    call vga_fill_rect(0_c_int32_t, y0 + rows - dy, fb_width, dy, color)
  end subroutine vga_scroll_up

end module fk_gop_renderer_m
