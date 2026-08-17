! SPDX-License-Identifier: GPL-2.0
! The RSDP and the root table it names -- RSDT (ACPI v1) or XSDT (v2) -- taken
! from the copy the Multiboot2 loader placed in tag 14 / tag 15.
!
! EVERY multi-byte field is assembled byte-wise, which is forced rather than
! defensive: QEMU's BIOS path reports the RSDT at physical 0x7FFE2525, so its
! 32-bit table pointers are unaligned too, and ACPI guarantees only 4-byte
! alignment for the XSDT's 64-bit entries.  A typed array descriptor or a
! bind(c) derived type bakes in an alignment firmware does not give.
!
! Nothing here maps anything or calls the VMM.  acpi_set_window states
! virt = phys + offset and acpi_set_limit states where that window stops; every
! physical address is checked against the top BEFORE it is dereferenced, which
! is what lets a host test point the parser at an ordinary malloc'd arena.
module fk_acpi_m
  use, intrinsic :: iso_c_binding, only: c_int8_t, c_int32_t, c_int64_t, &
                                         c_size_t, c_ptr, c_loc, c_f_pointer
  use fk_string_m, only: fk_memcmp
  implicit none
  private
  public :: FK_ACPI_OK, FK_ACPI_E_MBI, FK_ACPI_E_NO_TAG, &
            FK_ACPI_E_RSDP_SIG, FK_ACPI_E_RSDP_SUM, FK_ACPI_E_RSDP_LEN, &
            FK_ACPI_E_RSDP_EXT_SUM, FK_ACPI_E_ROOT_RANGE, &
            FK_ACPI_E_ROOT_SIG, FK_ACPI_E_ROOT_SUM, FK_ACPI_E_ROOT_LEN, &
            FK_ACPI_E_TOO_MANY, &
            FK_ACPI_ROOT_NONE, FK_ACPI_ROOT_RSDT, FK_ACPI_ROOT_XSDT, &
            FK_ACPI_MAX_TABLES, FK_ACPI_ROOT_LEN_MAX, FK_ACPI_RSDP_LEN_MAX, &
            FK_ACPI_MBI_MAX, FK_ACPI_MAP_MAX, &
            acpi_set_window, acpi_set_limit, acpi_init, &
            acpi_root_kind, acpi_root_phys, acpi_revision, acpi_rsdp_phys, &
            acpi_table_count, acpi_table_phys, acpi_table_sig, acpi_find, &
            acpi_table_length, acpi_checksum_ok

  integer(c_int32_t), parameter :: FK_ACPI_OK            =  0_c_int32_t
  integer(c_int32_t), parameter :: FK_ACPI_E_MBI         =  1_c_int32_t
  integer(c_int32_t), parameter :: FK_ACPI_E_NO_TAG      =  2_c_int32_t
  integer(c_int32_t), parameter :: FK_ACPI_E_RSDP_SIG    =  3_c_int32_t
  integer(c_int32_t), parameter :: FK_ACPI_E_RSDP_SUM    =  4_c_int32_t
  integer(c_int32_t), parameter :: FK_ACPI_E_RSDP_LEN    =  5_c_int32_t
  integer(c_int32_t), parameter :: FK_ACPI_E_RSDP_EXT_SUM=  6_c_int32_t
  integer(c_int32_t), parameter :: FK_ACPI_E_ROOT_RANGE  =  7_c_int32_t
  integer(c_int32_t), parameter :: FK_ACPI_E_ROOT_SIG    =  8_c_int32_t
  integer(c_int32_t), parameter :: FK_ACPI_E_ROOT_SUM    =  9_c_int32_t
  integer(c_int32_t), parameter :: FK_ACPI_E_ROOT_LEN    = 10_c_int32_t
  integer(c_int32_t), parameter :: FK_ACPI_E_TOO_MANY    = 11_c_int32_t

  integer(c_int32_t), parameter :: FK_ACPI_ROOT_NONE = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_ACPI_ROOT_RSDT = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_ACPI_ROOT_XSDT = 2_c_int32_t

  ! Real firmware lists 5 or 6 tables.  Beyond the ceiling the list is REFUSED,
  ! never truncated: a silently shortened table list is a machine whose MADT
  ! vanished.
  integer(c_int32_t), parameter :: FK_ACPI_MAX_TABLES = 64_c_int32_t

  ! Caps that bound a read taken from a length field firmware supplied.  Each
  ! is checked BEFORE the read it bounds, which is the only order that keeps a
  ! corrupt length from walking off the window.
  integer(c_int64_t), parameter :: FK_ACPI_ROOT_LEN_MAX = 4096_c_int64_t
  integer(c_int64_t), parameter :: FK_ACPI_RSDP_LEN_MAX = 256_c_int64_t
  integer(c_int64_t), parameter :: FK_ACPI_MBI_MAX      = 1048576_c_int64_t
  integer(c_int64_t), parameter :: FK_ACPI_MAP_MAX      = 16777216_c_int64_t

  integer(c_int32_t), parameter :: MB2_TAG_END      =  0_c_int32_t
  integer(c_int32_t), parameter :: MB2_TAG_ACPI_OLD = 14_c_int32_t
  integer(c_int32_t), parameter :: MB2_TAG_ACPI_NEW = 15_c_int32_t

  integer(c_int64_t), parameter :: RSDP_V1_LEN = 20_c_int64_t
  integer(c_int64_t), parameter :: RSDP_V2_LEN = 36_c_int64_t
  integer(c_int64_t), parameter :: HDR_LEN     = 36_c_int64_t

  ! "RSDT" and "XSDT" packed little-endian, the same encoding acpi_table_sig
  ! hands back and acpi_find takes.
  integer(c_int32_t), parameter :: SIG_RSDT = int(z'54445352', c_int32_t)
  integer(c_int32_t), parameter :: SIG_XSDT = int(z'54445358', c_int32_t)

  ! "RSD PTR " -- the trailing space is part of the signature.
  integer(c_int8_t), parameter :: RSDP_SIG(8) = &
       [82_c_int8_t, 83_c_int8_t, 68_c_int8_t, 32_c_int8_t, &
        80_c_int8_t, 84_c_int8_t, 82_c_int8_t, 32_c_int8_t]

  ! SHIFTR on all-ones, never SHIFTA: an arithmetic shift leaves the operand
  ! all-ones and this mask then strips nothing.
  integer(c_int64_t), parameter :: U32_MASK = shiftr(not(0_c_int64_t), 32)

  integer(c_int64_t), save :: win    = 0_c_int64_t
  integer(c_int64_t), save :: top    = 0_c_int64_t
  integer(c_int64_t), save :: root_p = 0_c_int64_t
  integer(c_int64_t), save :: rsdp_p = 0_c_int64_t
  integer(c_int32_t), save :: root_k = FK_ACPI_ROOT_NONE
  integer(c_int32_t), save :: rev    = 0_c_int32_t
  integer(c_int32_t), save :: ntab   = 0_c_int32_t
  integer(c_int64_t), save :: tbl(0:FK_ACPI_MAX_TABLES - 1) = 0_c_int64_t

  ! The region currently under the byte accessors.  Set by attach for the
  ! duration of one parse step; no descriptor ever crosses the C boundary.
  integer(c_int8_t), pointer :: blk(:) => null()

contains

  subroutine acpi_set_window(offset) bind(c, name="acpi_set_window")
    implicit none
    integer(c_int64_t), intent(in), value :: offset

    win = offset
  end subroutine acpi_set_window

  subroutine acpi_set_limit(limit) bind(c, name="acpi_set_limit")
    implicit none
    integer(c_int64_t), intent(in), value :: limit

    top = limit
  end subroutine acpi_set_limit

  ! --- byte-wise reads over the attached region ----------------------------

  subroutine attach(virt, n)
    implicit none
    integer(c_int64_t), intent(in) :: virt, n
    type(c_ptr) :: p

    p = transfer(virt, p)
    call c_f_pointer(p, blk, [int(n, c_int32_t)])
  end subroutine attach

  ! The gate. n is a length taken from firmware or from a caller, so it is
  ! bounded with BGT before anything derived from it is narrowed or added.
  ! phys == 0 is refused: it is this module's "absent" sentinel everywhere else.
  function reach(phys, n) result(ok)
    implicit none
    integer(c_int64_t), intent(in) :: phys, n
    logical :: ok

    ok = .false.
    if (phys == 0_c_int64_t .or. n == 0_c_int64_t) return
    if (bgt(n, FK_ACPI_MAP_MAX)) return
    if (blt(top, n)) return
    ! top - n cannot wrap after the line above, so this one comparison refuses
    ! both a base at or past the top and a span that crosses it.
    if (bgt(phys, top - n)) return
    call attach(phys + win, n)
    ok = .true.
  end function reach

  function db(off) result(v)
    implicit none
    integer(c_int64_t), intent(in) :: off
    integer(c_int32_t) :: v

    ! c_int8_t is signed, so 0xFE arrives as -2.
    v = iand(int(blk(off + 1_c_int64_t), c_int32_t), 255_c_int32_t)
  end function db

  function d32(off) result(v)
    implicit none
    integer(c_int64_t), intent(in) :: off
    integer(c_int32_t) :: v

    v = ior(ior(db(off), shiftl(db(off + 1_c_int64_t), 8)), &
            ior(shiftl(db(off + 2_c_int64_t), 16), &
                shiftl(db(off + 3_c_int64_t), 24)))
  end function d32

  function u32(off) result(v)
    implicit none
    integer(c_int64_t), intent(in) :: off
    integer(c_int64_t) :: v

    ! Mask after widening: int() on a pattern with bit 31 set sign-extends it
    ! across the whole upper half.
    v = iand(int(d32(off), c_int64_t), U32_MASK)
  end function u32

  function u64(off) result(v)
    implicit none
    integer(c_int64_t), intent(in) :: off
    integer(c_int64_t) :: v

    v = ior(u32(off), shiftl(u32(off + 4_c_int64_t), 32))
  end function u64

  ! Sum mod 256 over the attached region. Identical for signed and unsigned
  ! bytes -- which is exactly why a checksum cannot vouch for field assembly.
  function sum_zero(off, n) result(ok)
    implicit none
    integer(c_int64_t), intent(in) :: off, n
    logical :: ok
    integer(c_int64_t) :: i
    integer(c_int32_t) :: acc

    acc = 0_c_int32_t
    do i = 0_c_int64_t, n - 1_c_int64_t
       acc = iand(acc + db(off + i), 255_c_int32_t)
    end do
    ok = acc == 0_c_int32_t
  end function sum_zero

  ! 0..255 into the signed kind that holds it.
  function i8(v) result(b)
    implicit none
    integer(c_int32_t), intent(in) :: v
    integer(c_int8_t) :: b

    b = int(iand(v, 255_c_int32_t) - shiftl(iand(v, 128_c_int32_t), 1), c_int8_t)
  end function i8

  function mem_eq(virt, n, want) result(ok)
    implicit none
    integer(c_int64_t), intent(in) :: virt
    integer(c_int32_t), intent(in) :: n
    integer(c_int8_t), intent(in), target :: want(n)
    logical :: ok
    type(c_ptr) :: p

    p = transfer(virt, p)
    ok = fk_memcmp(c_loc(want(1)), p, int(n, c_size_t)) == 0_c_int32_t
  end function mem_eq

  ! The four signature bytes at a table's base, compared where they lie.
  function sig_eq(virt, packed) result(ok)
    implicit none
    integer(c_int64_t), intent(in) :: virt
    integer(c_int32_t), intent(in) :: packed
    logical :: ok
    integer(c_int8_t), target :: want(4)
    integer(c_int32_t) :: k

    do k = 1_c_int32_t, 4_c_int32_t
       want(k) = i8(iand(shiftr(packed, 8 * (k - 1_c_int32_t)), 255_c_int32_t))
    end do
    ok = mem_eq(virt, 4_c_int32_t, want)
  end function sig_eq

  ! --- the parse -----------------------------------------------------------

  function acpi_init(mbi_virt, mbi_len) result(status) bind(c, name="acpi_init")
    implicit none
    integer(c_int64_t), intent(in), value :: mbi_virt, mbi_len
    integer(c_int32_t) :: status
    integer(c_int64_t) :: off, tsize, ttype, t14, t14n, t15, t15n
    integer(c_int64_t) :: r_phys, r_rev
    integer(c_int32_t) :: r_kind

    root_p = 0_c_int64_t
    rsdp_p = 0_c_int64_t
    root_k = FK_ACPI_ROOT_NONE
    rev    = 0_c_int32_t
    ntab   = 0_c_int32_t

    if (mbi_virt == 0_c_int64_t) then
       status = FK_ACPI_E_MBI
       return
    end if
    if (blt(mbi_len, 8_c_int64_t) .or. bgt(mbi_len, FK_ACPI_MBI_MAX)) then
       status = FK_ACPI_E_MBI
       return
    end if
    call attach(mbi_virt, mbi_len)

    ! Tags start after the MBI's own 8-byte header and each is padded up to 8.
    ! A size below 8 or running past the end is FATAL: it is the input that
    ! turns this walk into an infinite loop or a read past the structure.  Both
    ! tags are recorded, because 15 may appear after 14.
    t14 = -1_c_int64_t
    t15 = -1_c_int64_t
    t14n = 0_c_int64_t
    t15n = 0_c_int64_t
    off = 8_c_int64_t
    do while (off + 8_c_int64_t <= mbi_len)
       ttype = u32(off)
       tsize = u32(off + 4_c_int64_t)
       if (tsize < 8_c_int64_t .or. off + tsize > mbi_len) then
          status = FK_ACPI_E_MBI
          return
       end if
       if (ttype == int(MB2_TAG_END, c_int64_t)) exit
       if (ttype == int(MB2_TAG_ACPI_OLD, c_int64_t)) then
          t14  = off
          t14n = tsize - 8_c_int64_t
       end if
       if (ttype == int(MB2_TAG_ACPI_NEW, c_int64_t)) then
          t15  = off
          t15n = tsize - 8_c_int64_t
       end if
       off = off + iand(tsize + 7_c_int64_t, not(7_c_int64_t))
    end do

    ! Tag 15 wins where both exist: the v2 RSDP names the XSDT, whose 64-bit
    ! entries can reach tables the RSDT's 32-bit ones cannot.  A tag 15 that is
    ! present but malformed is fatal and does NOT fall back to tag 14 --
    ! quietly using the v1 root would hide firmware that is lying about itself.
    if (t15 >= 0_c_int64_t) then
       call parse_rsdp(mbi_virt, t15 + 8_c_int64_t, t15n, .true., &
                       status, r_phys, r_kind, r_rev)
    else if (t14 >= 0_c_int64_t) then
       call parse_rsdp(mbi_virt, t14 + 8_c_int64_t, t14n, .false., &
                       status, r_phys, r_kind, r_rev)
    else
       status = FK_ACPI_E_NO_TAG
       return
    end if
    if (status /= FK_ACPI_OK) return

    status = parse_root(r_phys, r_kind)
    if (status /= FK_ACPI_OK) then
       ntab = 0_c_int32_t
       return
    end if

    root_p = r_phys
    root_k = r_kind
    rev    = int(r_rev, c_int32_t)
  end function acpi_init

  ! The RSDP lies inside the tag, so blk is still the MBI throughout: nothing
  ! here re-attaches.  payload is the tag's bytes after its 8-byte header, and
  ! it bounds the extended checksum -- a `length` larger than the tag is a read
  ! off the end of the structure, cap or no cap.
  subroutine parse_rsdp(base_virt, off, payload, v2, status, r_phys, r_kind, r_rev)
    implicit none
    integer(c_int64_t), intent(in) :: base_virt, off, payload
    logical, intent(in) :: v2
    integer(c_int32_t), intent(out) :: status, r_kind
    integer(c_int64_t), intent(out) :: r_phys, r_rev
    integer(c_int8_t), target :: want(8)
    integer(c_int64_t) :: rlen

    r_phys = 0_c_int64_t
    r_kind = FK_ACPI_ROOT_NONE
    r_rev  = 0_c_int64_t

    if (v2) then
       if (payload < RSDP_V2_LEN) then
          status = FK_ACPI_E_MBI
          return
       end if
    else
       if (payload < RSDP_V1_LEN) then
          status = FK_ACPI_E_MBI
          return
       end if
    end if

    want = RSDP_SIG
    if (.not. mem_eq(base_virt + off, 8_c_int32_t, want)) then
       status = FK_ACPI_E_RSDP_SIG
       return
    end if
    if (.not. sum_zero(off, RSDP_V1_LEN)) then
       status = FK_ACPI_E_RSDP_SUM
       return
    end if

    r_rev = int(db(off + 15_c_int64_t), c_int64_t)

    if (v2) then
       rlen = u32(off + 20_c_int64_t)
       if (blt(rlen, RSDP_V2_LEN) .or. bgt(rlen, FK_ACPI_RSDP_LEN_MAX) .or. &
           bgt(rlen, payload)) then
          status = FK_ACPI_E_RSDP_LEN
          return
       end if
       if (.not. sum_zero(off, rlen)) then
          status = FK_ACPI_E_RSDP_EXT_SUM
          return
       end if
       r_phys = u64(off + 24_c_int64_t)
       r_kind = FK_ACPI_ROOT_XSDT
    else
       r_phys = u32(off + 16_c_int64_t)
       r_kind = FK_ACPI_ROOT_RSDT
    end if
    status = FK_ACPI_OK
  end subroutine parse_rsdp

  function parse_root(phys, kind) result(status)
    implicit none
    integer(c_int64_t), intent(in) :: phys
    integer(c_int32_t), intent(in) :: kind
    integer(c_int32_t) :: status
    integer(c_int64_t) :: rlen, psize, n, i

    psize = 4_c_int64_t
    if (kind == FK_ACPI_ROOT_XSDT) psize = 8_c_int64_t

    if (.not. reach(phys, HDR_LEN)) then
       status = FK_ACPI_E_ROOT_RANGE
       return
    end if
    if (kind == FK_ACPI_ROOT_XSDT) then
       if (.not. sig_eq(phys + win, SIG_XSDT)) then
          status = FK_ACPI_E_ROOT_SIG
          return
       end if
    else
       if (.not. sig_eq(phys + win, SIG_RSDT)) then
          status = FK_ACPI_E_ROOT_SIG
          return
       end if
    end if

    ! Length before any read of that many bytes, and a pointer array that is
    ! not a whole number of pointers is refused rather than rounded down.
    rlen = u32(4_c_int64_t)
    if (blt(rlen, HDR_LEN) .or. bgt(rlen, FK_ACPI_ROOT_LEN_MAX)) then
       status = FK_ACPI_E_ROOT_LEN
       return
    end if
    if (mod(rlen - HDR_LEN, psize) /= 0_c_int64_t) then
       status = FK_ACPI_E_ROOT_LEN
       return
    end if
    if (.not. reach(phys, rlen)) then
       status = FK_ACPI_E_ROOT_RANGE
       return
    end if
    if (.not. sum_zero(0_c_int64_t, rlen)) then
       status = FK_ACPI_E_ROOT_SUM
       return
    end if

    n = (rlen - HDR_LEN) / psize
    if (n > int(FK_ACPI_MAX_TABLES, c_int64_t)) then
       status = FK_ACPI_E_TOO_MANY
       return
    end if

    do i = 0_c_int64_t, n - 1_c_int64_t
       if (psize == 8_c_int64_t) then
          tbl(int(i, c_int32_t)) = u64(HDR_LEN + i * psize)
       else
          tbl(int(i, c_int32_t)) = u32(HDR_LEN + i * psize)
       end if
    end do
    ntab = int(n, c_int32_t)
    status = FK_ACPI_OK
  end function parse_root

  ! --- accessors ------------------------------------------------------------

  function acpi_root_kind() result(v) bind(c, name="acpi_root_kind")
    implicit none
    integer(c_int32_t) :: v

    v = root_k
  end function acpi_root_kind

  function acpi_root_phys() result(v) bind(c, name="acpi_root_phys")
    implicit none
    integer(c_int64_t) :: v

    v = root_p
  end function acpi_root_phys

  function acpi_revision() result(v) bind(c, name="acpi_revision")
    implicit none
    integer(c_int32_t) :: v

    v = rev
  end function acpi_revision

  ! 0 on this path, always: Multiboot2 hands over a COPY of the RSDP and never
  ! says where firmware's own lives.
  function acpi_rsdp_phys() result(v) bind(c, name="acpi_rsdp_phys")
    implicit none
    integer(c_int64_t) :: v

    v = rsdp_p
  end function acpi_rsdp_phys

  function acpi_table_count() result(v) bind(c, name="acpi_table_count")
    implicit none
    integer(c_int32_t) :: v

    v = ntab
  end function acpi_table_count

  function acpi_table_phys(i) result(v) bind(c, name="acpi_table_phys")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (i >= 0_c_int32_t .and. i < ntab) v = tbl(i)
  end function acpi_table_phys

  ! Read where the table lies, not cached: a pointer the root listed may name
  ! memory outside the window, and that is the gate's answer to give.
  function acpi_table_sig(i) result(v) bind(c, name="acpi_table_sig")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (i < 0_c_int32_t .or. i >= ntab) return
    if (.not. reach(tbl(i), 4_c_int64_t)) return
    v = d32(0_c_int64_t)
  end function acpi_table_sig

  function acpi_find(sig_packed) result(phys) bind(c, name="acpi_find")
    implicit none
    integer(c_int32_t), intent(in), value :: sig_packed
    integer(c_int64_t) :: phys
    integer(c_int32_t) :: i

    phys = 0_c_int64_t
    do i = 0_c_int32_t, ntab - 1_c_int32_t
       if (.not. reach(tbl(i), 4_c_int64_t)) cycle
       if (sig_eq(tbl(i) + win, sig_packed)) then
          phys = tbl(i)
          return
       end if
    end do
  end function acpi_find

  function acpi_table_length(phys) result(v) bind(c, name="acpi_table_length")
    implicit none
    integer(c_int64_t), intent(in), value :: phys
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (.not. reach(phys, HDR_LEN)) return
    v = u32(4_c_int64_t)
  end function acpi_table_length

  function acpi_checksum_ok(phys, length) result(v) bind(c, name="acpi_checksum_ok")
    implicit none
    integer(c_int64_t), intent(in), value :: phys, length
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (.not. reach(phys, length)) return
    if (sum_zero(0_c_int64_t, length)) v = 1_c_int32_t
  end function acpi_checksum_ok

end module fk_acpi_m
