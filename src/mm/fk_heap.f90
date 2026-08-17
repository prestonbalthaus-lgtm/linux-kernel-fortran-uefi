! SPDX-License-Identifier: GPL-2.0
! Kernel heap: kmalloc/kfree over a contiguous virtual window (roadmap 4.0).
!
! WHERE THE MEMORY COMES FROM IS NOT THIS MODULE'S DECISION.  It calls
! heap_sbrk(bytes), which must map that many bytes IMMEDIATELY ABOVE the window
! it has already been given and return the address it mapped at, or 0.  The
! kernel implements it out of PMM frames and VMM mappings; a host test
! implements it out of one large allocation.  That boundary is what makes a
! block allocator testable at all -- everything below is arithmetic.
!
! IMPLICIT LIST WITH BOUNDARY TAGS, and the second tag is the point.  Every
! block carries its own size and its PREDECESSOR's size, so kfree can find the
! block below it in constant time and coalesce both ways.  Without the back
! tag, freeing in ascending address order leaves the heap in N fragments that
! no later allocation can merge, and a fragmented kernel heap fails long after
! the code that caused it has returned.
!
! A free LIST would be faster to search.  It is not here on purpose: a list
! threads pointers through free blocks, so a use-after-free corrupts the
! allocator's own structure and the failure lands in an unrelated kmalloc.  The
! implicit walk keeps every pointer inside the header, where heap_check() can
! verify the whole heap tiles exactly -- which it does on every boot.
module fk_heap_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t, c_ptr, &
                                         c_f_pointer
  implicit none
  private
  public :: FK_HEAP_ALIGN, FK_HEAP_HDR, FK_HEAP_MIN, FK_HEAP_CHUNK, &
            FK_HEAP_OK, FK_HEAP_E_SBRK, FK_HEAP_E_NONCONTIG, &
            FK_HEAP_MAGIC, FK_HEAP_WORDS, &
            FK_HS_MAGIC, FK_HS_MAPPED, FK_HS_USED, FK_HS_FREE, FK_HS_BLOCKS, &
            FK_HS_ALLOCS, FK_HS_FREES, FK_HS_LARGEST, FK_HS_FAILED, &
            FK_HS_BADFREE, &
            fk_heap_stat, heap_init, kmalloc, kfree, kzalloc, heap_check, &
            heap_base, heap_top, heap_size_of, pmm_alloc_contiguous

  ! SysV AMD64's max_align_t is 16, and the header is one alignment unit, so a
  ! payload is aligned exactly when the block is.
  integer(c_int64_t), parameter :: FK_HEAP_ALIGN = 16_c_int64_t
  integer(c_int64_t), parameter :: FK_HEAP_HDR   = 16_c_int64_t
  ! Header plus one alignment unit.  A remainder smaller than this cannot hold
  ! a block, so a split that would produce one is not performed.
  integer(c_int64_t), parameter :: FK_HEAP_MIN   = 32_c_int64_t
  ! How much to ask heap_sbrk for when a small allocation does not fit.  64 KiB
  ! rather than one page: a page per growth turns a loop of small kmallocs into
  ! a loop of page-table walks.
  integer(c_int64_t), parameter :: FK_HEAP_CHUNK = 65536_c_int64_t
  integer(c_int64_t), parameter :: FK_HEAP_PAGE  = 4096_c_int64_t
  ! Nothing in a kernel legitimately asks for a gigabyte in one call, and the
  ! bound is what stops a wrapped size computation from looking satisfiable.
  integer(c_int64_t), parameter :: FK_HEAP_MAX_REQ = 1073741824_c_int64_t

  integer(c_int32_t), parameter :: FK_HEAP_OK          =  0_c_int32_t
  integer(c_int32_t), parameter :: FK_HEAP_E_SBRK      = -2_c_int32_t
  integer(c_int32_t), parameter :: FK_HEAP_E_NONCONTIG = -3_c_int32_t

  ! Bit 0 of the size word.  Sizes are multiples of 16, so the low four bits
  ! are free for flags and the size is recovered by masking, never by shifting.
  integer(c_int64_t), parameter :: BLK_USED = 1_c_int64_t
  integer(c_int64_t), parameter :: BLK_SIZE = not(15_c_int64_t)

  integer(c_int32_t), parameter :: FK_HEAP_WORDS = 10_c_int32_t
  integer(c_int32_t), parameter :: FK_HS_MAGIC   =  1_c_int32_t
  integer(c_int32_t), parameter :: FK_HS_MAPPED  =  2_c_int32_t
  integer(c_int32_t), parameter :: FK_HS_USED    =  3_c_int32_t
  integer(c_int32_t), parameter :: FK_HS_FREE    =  4_c_int32_t
  integer(c_int32_t), parameter :: FK_HS_BLOCKS  =  5_c_int32_t
  integer(c_int32_t), parameter :: FK_HS_ALLOCS  =  6_c_int32_t
  integer(c_int32_t), parameter :: FK_HS_FREES   =  7_c_int32_t
  integer(c_int32_t), parameter :: FK_HS_LARGEST =  8_c_int32_t
  integer(c_int32_t), parameter :: FK_HS_FAILED  =  9_c_int32_t
  integer(c_int32_t), parameter :: FK_HS_BADFREE = 10_c_int32_t

  integer(c_int64_t), parameter :: FK_HEAP_MAGIC = int(z'4B48454150000001', c_int64_t)

  ! The statistics block, read from OUTSIDE the guest over QMP -- so "the heap
  ! served N allocations and still tiles exactly" is a fact about a running
  ! machine, not a line the kernel printed about itself.
  integer(c_int64_t), bind(c, name="fk_heap_stat") :: &
       fk_heap_stat(FK_HEAP_WORDS) = 0_c_int64_t

  integer(c_int64_t), save :: lo = 0_c_int64_t   ! first block address
  integer(c_int64_t), save :: hi = 0_c_int64_t   ! one past the last block
  logical,            save :: ready = .false.

  ! The window as an array of quadwords.  Re-pointed on every growth; the
  ! header fields are read and written through it and nothing else.
  integer(c_int64_t), pointer :: w(:)

  interface
    ! Map BYTES immediately above the current window and return the address it
    ! landed at, or 0.  The heap REFUSES a non-contiguous answer rather than
    ! trying to stitch two windows together.
    function heap_sbrk(bytes) result(virt) bind(c, name="heap_sbrk")
      import :: c_int64_t
      implicit none
      integer(c_int64_t), intent(in), value :: bytes
      integer(c_int64_t) :: virt
    end function heap_sbrk
  end interface

  ! DMA memory, which the block allocator above cannot serve and does not try
  ! to.  PAGES contiguous 4 KiB frames, or 0.  It answers with the PHYSICAL
  ! base because that is the address the DEVICE uses: a bus master does not
  ! walk the CPU's page tables, and the ring an xHCI controller reads is
  ! described to it by physical address alone.
  !
  ! A frame is 4096-byte aligned, so a run of them satisfies every alignment
  ! these structures ask for -- 64 bytes for an xHCI ring segment, its DCBAA
  ! and its ERST, one page for an NVMe queue.  What page granularity does NOT
  ! promise is a run clear of a 64 KiB boundary, which a TRB's data buffer may
  ! not cross (vendor/linux-7.1.8/drivers/usb/host/xhci.h:1265); a caller that
  ! needs that must ask for the size that guarantees it.
  !
  ! DECLARED HERE, DEFINED NOWHERE YET (roadmap 3.x debt, the PMM's to fill).
  ! An interface with no caller emits no reference, so the tree still links
  ! today, and the first driver to call it fails at LINK time rather than by
  ! reading a page of firmware leftovers.
  interface
    function pmm_alloc_contiguous(pages) result(phys) &
         bind(c, name="pmm_alloc_contiguous")
      import :: c_int64_t
      implicit none
      integer(c_int64_t), intent(in), value :: pages
      integer(c_int64_t) :: phys
    end function pmm_alloc_contiguous
  end interface

contains

  pure function round_up(v, g) result(r)
    implicit none
    integer(c_int64_t), intent(in) :: v, g
    integer(c_int64_t) :: r

    r = iand(v + g - 1_c_int64_t, not(g - 1_c_int64_t))
  end function round_up

  ! 1-based quadword index of byte address A.  Every header access goes through
  ! this, so an address outside the window is an out-of-range subscript rather
  ! than a store into whatever follows.
  pure function ix(a) result(i)
    implicit none
    integer(c_int64_t), intent(in) :: a
    integer(c_int64_t) :: i

    i = (a - lo) / 8_c_int64_t + 1_c_int64_t
  end function ix

  function bsize(a) result(v)
    implicit none
    integer(c_int64_t), intent(in) :: a
    integer(c_int64_t) :: v
    v = iand(w(ix(a)), BLK_SIZE)
  end function bsize

  function bused(a) result(v)
    implicit none
    integer(c_int64_t), intent(in) :: a
    logical :: v
    v = iand(w(ix(a)), BLK_USED) /= 0_c_int64_t
  end function bused

  function bprev(a) result(v)
    implicit none
    integer(c_int64_t), intent(in) :: a
    integer(c_int64_t) :: v
    v = w(ix(a) + 1_c_int64_t)
  end function bprev

  subroutine bset(a, size, used, prev)
    implicit none
    integer(c_int64_t), intent(in) :: a, size, prev
    logical, intent(in) :: used

    if (used) then
       w(ix(a)) = ior(size, BLK_USED)
    else
       w(ix(a)) = size
    end if
    w(ix(a) + 1_c_int64_t) = prev
  end subroutine bset

  ! Re-point the quadword view over [lo, hi).  Called after every growth: the
  ! bound is what turns a corrupted header into a subscript error instead of a
  ! walk off the end of the mapping.
  subroutine remap()
    implicit none
    type(c_ptr) :: p

    p = transfer(lo, p)
    call c_f_pointer(p, w, [(hi - lo) / 8_c_int64_t])
  end subroutine remap

  !> Reset the heap.  Nothing is mapped until the first kmalloc asks for it.
  function heap_init() result(status) bind(c, name="heap_init")
    implicit none
    integer(c_int32_t) :: status
    integer(c_int32_t) :: i

    lo    = 0_c_int64_t
    hi    = 0_c_int64_t
    ready = .true.
    do i = 1_c_int32_t, FK_HEAP_WORDS
       fk_heap_stat(i) = 0_c_int64_t
    end do
    fk_heap_stat(FK_HS_MAGIC) = FK_HEAP_MAGIC
    status = FK_HEAP_OK
  end function heap_init

  ! Ask for BYTES more and append them as one free block.  The new block is
  ! coalesced with the old last block if that one was free, so a heap that
  ! grows repeatedly does not accumulate a boundary per growth.
  function grow(bytes) result(status)
    implicit none
    integer(c_int64_t), intent(in) :: bytes
    integer(c_int32_t) :: status
    integer(c_int64_t) :: want, got, old_hi, prev_sz, blk

    want = round_up(max(bytes, FK_HEAP_CHUNK), FK_HEAP_PAGE)
    got  = heap_sbrk(want)
    if (got == 0_c_int64_t) then
       status = FK_HEAP_E_SBRK
       return
    end if

    if (lo == 0_c_int64_t) then
       ! First growth: the window starts wherever the supplier put it, and it
       ! must be aligned or every payload in the heap is misaligned.
       if (iand(got, FK_HEAP_ALIGN - 1_c_int64_t) /= 0_c_int64_t) then
          status = FK_HEAP_E_NONCONTIG
          return
       end if
       lo = got
       hi = got + want
       call remap()
       call bset(lo, want, .false., 0_c_int64_t)
       fk_heap_stat(FK_HS_BLOCKS) = 1_c_int64_t
    else
       if (got /= hi) then
          status = FK_HEAP_E_NONCONTIG
          return
       end if
       old_hi = hi
       hi     = hi + want
       call remap()
       ! prev_size of the new block is the size of whatever ended at old_hi,
       ! which the previous last block's own back tag lets us find.
       prev_sz = last_size(old_hi)
       blk     = old_hi
       call bset(blk, want, .false., prev_sz)
       fk_heap_stat(FK_HS_BLOCKS) = fk_heap_stat(FK_HS_BLOCKS) + 1_c_int64_t
       call coalesce_back(blk)
    end if

    fk_heap_stat(FK_HS_MAPPED) = hi - lo
    status = FK_HEAP_OK
  end function grow

  ! Size of the block that ends at END_ADDR.  Walking from lo is O(n) and this
  ! runs once per growth, which is rare; the alternative is a third tag.
  function last_size(end_addr) result(sz)
    implicit none
    integer(c_int64_t), intent(in) :: end_addr
    integer(c_int64_t) :: sz, a

    sz = 0_c_int64_t
    a  = lo
    do while (a < end_addr)
       sz = bsize(a)
       if (sz < FK_HEAP_MIN) return
       a = a + sz
    end do
  end function last_size

  subroutine coalesce_back(a)
    implicit none
    integer(c_int64_t), intent(in) :: a
    integer(c_int64_t) :: p, nxt

    if (bprev(a) == 0_c_int64_t) return
    p = a - bprev(a)
    if (p < lo) return
    if (bused(p)) return

    call bset(p, bsize(p) + bsize(a), .false., bprev(p))
    fk_heap_stat(FK_HS_BLOCKS) = fk_heap_stat(FK_HS_BLOCKS) - 1_c_int64_t
    nxt = p + bsize(p)
    if (nxt < hi) call bset(nxt, bsize(nxt), bused(nxt), bsize(p))
  end subroutine coalesce_back

  subroutine coalesce_fwd(a)
    implicit none
    integer(c_int64_t), intent(in) :: a
    integer(c_int64_t) :: n, nn

    n = a + bsize(a)
    if (n >= hi) return
    if (bused(n)) return

    call bset(a, bsize(a) + bsize(n), .false., bprev(a))
    fk_heap_stat(FK_HS_BLOCKS) = fk_heap_stat(FK_HS_BLOCKS) - 1_c_int64_t
    nn = a + bsize(a)
    if (nn < hi) call bset(nn, bsize(nn), bused(nn), bsize(a))
  end subroutine coalesce_fwd

  !> Allocate N bytes, 16-byte aligned.  Returns 0 on refusal, and 0 is never
  !! a valid heap address: the window is in the upper half.
  function kmalloc(n) result(addr) bind(c, name="kmalloc")
    implicit none
    integer(c_int64_t), intent(in), value :: n
    integer(c_int64_t) :: addr
    integer(c_int64_t) :: need
    integer(c_int32_t) :: st

    addr = 0_c_int64_t
    if (.not. ready) return
    ! n is a SIGNED quadword carrying an unsigned request.  A negative value is
    ! a caller that wrapped, and n + HDR must not be allowed to wrap back into
    ! a small positive number that then satisfies a first-fit scan.
    if (n <= 0_c_int64_t .or. n > FK_HEAP_MAX_REQ) then
       fk_heap_stat(FK_HS_FAILED) = fk_heap_stat(FK_HS_FAILED) + 1_c_int64_t
       return
    end if

    need = round_up(n + FK_HEAP_HDR, FK_HEAP_ALIGN)
    if (need < FK_HEAP_MIN) need = FK_HEAP_MIN

    addr = take(need)
    if (addr /= 0_c_int64_t) return

    st = grow(need)
    if (st /= FK_HEAP_OK) then
       fk_heap_stat(FK_HS_FAILED) = fk_heap_stat(FK_HS_FAILED) + 1_c_int64_t
       return
    end if
    addr = take(need)
    if (addr == 0_c_int64_t) &
         fk_heap_stat(FK_HS_FAILED) = fk_heap_stat(FK_HS_FAILED) + 1_c_int64_t
  end function kmalloc

  ! First fit, splitting when the remainder can hold a block.  FIRST fit and
  ! not best fit: best fit walks the whole heap on every call for a fragmentation
  ! difference that boundary-tag coalescing already removes most of.
  function take(need) result(addr)
    implicit none
    integer(c_int64_t), intent(in) :: need
    integer(c_int64_t) :: addr, a, sz, rest, nxt

    addr = 0_c_int64_t
    if (lo == 0_c_int64_t) return
    a = lo
    do while (a < hi)
       sz = bsize(a)
       ! A zero or unaligned size is a corrupted header, and continuing the
       ! walk would loop forever or step into the middle of a block.
       if (sz < FK_HEAP_MIN .or. iand(sz, FK_HEAP_ALIGN - 1_c_int64_t) /= 0_c_int64_t) return
       if (.not. bused(a) .and. sz >= need) then
          rest = sz - need
          if (rest >= FK_HEAP_MIN) then
             call bset(a, need, .true., bprev(a))
             call bset(a + need, rest, .false., need)
             nxt = a + need + rest
             if (nxt < hi) call bset(nxt, bsize(nxt), bused(nxt), rest)
             fk_heap_stat(FK_HS_BLOCKS) = fk_heap_stat(FK_HS_BLOCKS) + 1_c_int64_t
          else
             ! The remainder cannot hold a block, so it is handed to the
             ! caller as slack rather than left as a fragment nothing can use.
             call bset(a, sz, .true., bprev(a))
          end if
          fk_heap_stat(FK_HS_ALLOCS) = fk_heap_stat(FK_HS_ALLOCS) + 1_c_int64_t
          fk_heap_stat(FK_HS_USED)   = fk_heap_stat(FK_HS_USED) + bsize(a)
          addr = a + FK_HEAP_HDR
          return
       end if
       a = a + sz
    end do
  end function take

  !> Allocate N bytes and clear them.  Separate from kmalloc rather than a flag:
  !! a caller that must have zeroed memory should not be able to forget.
  function kzalloc(n) result(addr) bind(c, name="kzalloc")
    implicit none
    integer(c_int64_t), intent(in), value :: n
    integer(c_int64_t) :: addr
    integer(c_int64_t) :: i, first, last

    addr = kmalloc(n)
    if (addr == 0_c_int64_t) return
    ! Whole quadwords through the same view the headers use, so the clear
    ! cannot run past the block: bsize is the allocator's own answer.
    first = ix(addr)
    last  = ix(addr - FK_HEAP_HDR) + bsize(addr - FK_HEAP_HDR) / 8_c_int64_t - 1_c_int64_t
    do i = first, last
       w(i) = 0_c_int64_t
    end do
  end function kzalloc

  !> Release a pointer kmalloc returned.  A null pointer is a no-op, as free's
  !! contract has been since C89; anything else that is not a live block is
  !! COUNTED and ignored, because a heap that corrupts itself on a bad free
  !! reports the defect somewhere else entirely.
  subroutine kfree(p) bind(c, name="kfree")
    implicit none
    integer(c_int64_t), intent(in), value :: p
    integer(c_int64_t) :: a, sz

    if (p == 0_c_int64_t) return
    if (.not. ready .or. lo == 0_c_int64_t) return
    if (p < lo + FK_HEAP_HDR .or. p >= hi) then
       fk_heap_stat(FK_HS_BADFREE) = fk_heap_stat(FK_HS_BADFREE) + 1_c_int64_t
       return
    end if
    if (iand(p, FK_HEAP_ALIGN - 1_c_int64_t) /= 0_c_int64_t) then
       fk_heap_stat(FK_HS_BADFREE) = fk_heap_stat(FK_HS_BADFREE) + 1_c_int64_t
       return
    end if

    a  = p - FK_HEAP_HDR
    sz = bsize(a)
    if (sz < FK_HEAP_MIN .or. a + sz > hi .or. .not. bused(a)) then
       fk_heap_stat(FK_HS_BADFREE) = fk_heap_stat(FK_HS_BADFREE) + 1_c_int64_t
       return
    end if

    call bset(a, sz, .false., bprev(a))
    fk_heap_stat(FK_HS_USED)  = fk_heap_stat(FK_HS_USED) - sz
    fk_heap_stat(FK_HS_FREES) = fk_heap_stat(FK_HS_FREES) + 1_c_int64_t

    ! Forward first: coalesce_back may move the block, and merging into the
    ! predecessor after the successor is already absorbed is one operation.
    call coalesce_fwd(a)
    call coalesce_back(a)
  end subroutine kfree

  !> The payload size a pointer was given, or 0 if it is not a live block.
  function heap_size_of(p) result(n) bind(c, name="heap_size_of")
    implicit none
    integer(c_int64_t), intent(in), value :: p
    integer(c_int64_t) :: n, a

    n = 0_c_int64_t
    if (p < lo + FK_HEAP_HDR .or. p >= hi) return
    a = p - FK_HEAP_HDR
    if (.not. bused(a)) return
    n = bsize(a) - FK_HEAP_HDR
  end function heap_size_of

  !> Walk the whole heap and count everything that does not add up.  Returns 0
  !! on a consistent heap and refreshes the statistics block from the walk
  !! rather than from the counters, so a counter that drifted is visible.
  function heap_check() result(bad) bind(c, name="heap_check")
    implicit none
    integer(c_int64_t) :: bad
    integer(c_int64_t) :: a, sz, prev, blocks, used, free_b, largest

    bad     = 0_c_int64_t
    blocks  = 0_c_int64_t
    used    = 0_c_int64_t
    free_b  = 0_c_int64_t
    largest = 0_c_int64_t
    if (lo == 0_c_int64_t) return

    a    = lo
    prev = 0_c_int64_t
    do while (a < hi)
       sz = bsize(a)
       if (sz < FK_HEAP_MIN .or. iand(sz, FK_HEAP_ALIGN - 1_c_int64_t) /= 0_c_int64_t &
           .or. a + sz > hi) then
          bad = bad + 1_c_int64_t
          exit
       end if
       ! The back tag must name the block that really precedes this one.
       if (bprev(a) /= prev) bad = bad + 1_c_int64_t
       ! Two adjacent free blocks mean a coalesce did not happen, which is a
       ! defect even though nothing is corrupt: the heap will fail an
       ! allocation it has the memory for.
       if (.not. bused(a) .and. prev /= 0_c_int64_t) then
          if (.not. bused(a - prev)) bad = bad + 1_c_int64_t
       end if
       blocks = blocks + 1_c_int64_t
       if (bused(a)) then
          used = used + sz
       else
          free_b = free_b + sz
          if (sz > largest) largest = sz
       end if
       prev = sz
       a    = a + sz
    end do
    ! The blocks must tile the window EXACTLY.  A walk that overshoots or stops
    ! short is a heap whose next allocation lands somewhere arbitrary.
    if (a /= hi) bad = bad + 1_c_int64_t

    fk_heap_stat(FK_HS_BLOCKS)  = blocks
    fk_heap_stat(FK_HS_USED)    = used
    fk_heap_stat(FK_HS_FREE)    = free_b
    fk_heap_stat(FK_HS_LARGEST) = largest
    fk_heap_stat(FK_HS_MAPPED)  = hi - lo
  end function heap_check

  function heap_base() result(v) bind(c, name="heap_base")
    implicit none
    integer(c_int64_t) :: v
    v = lo
  end function heap_base

  function heap_top() result(v) bind(c, name="heap_top")
    implicit none
    integer(c_int64_t) :: v
    v = hi
  end function heap_top

end module fk_heap_m
