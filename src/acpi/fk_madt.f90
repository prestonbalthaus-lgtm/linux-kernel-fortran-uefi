! SPDX-License-Identifier: GPL-2.0
! The Multiple APIC Description Table (ACPI 6.5 5.2.12): who the CPUs are,
! where the IOAPICs are, and which legacy IRQs firmware rewired.
!
! madt_parse is handed an already-mapped VIRTUAL address and a length.  It maps
! nothing, consults no VMM and does not locate itself, which is also what lets a
! host test point it at an ordinary buffer.
!
! EVERY multi-byte field is assembled a byte at a time.  This is forced, not
! stylistic: on this project's BIOS path the RSDT sits at 0x7FFE2525, so the
! tables it points at inherit no alignment at all, and the Type 4 entry below
! puts a 16-bit field at odd offset 3 even in a perfectly aligned table.  A
! typed array descriptor over the table would bake in an alignment that is not
! there.
module fk_madt_m
  use, intrinsic :: iso_c_binding, only: c_int8_t, c_int32_t, c_int64_t, &
                                         c_size_t, c_ptr, c_loc, c_f_pointer, &
                                         c_associated
  use fk_string_m, only: fk_memcmp
  implicit none
  private
  public :: FK_MADT_OK, FK_MADT_E_NULL, FK_MADT_E_LEN, FK_MADT_E_SIG, &
            FK_MADT_E_CHECKSUM, FK_MADT_E_TRUNC, FK_MADT_E_ENTRY_ZERO, &
            FK_MADT_E_ENTRY_OVERRUN, FK_MADT_E_ENTRY_SHORT, &
            FK_MADT_E_MANY_CPU, FK_MADT_E_MANY_IOAPIC, FK_MADT_E_MANY_ISO, &
            FK_MADT_E_MANY_NMI, &
            FK_MADT_MAX_CPU, FK_MADT_MAX_IOAPIC, FK_MADT_MAX_ISO, &
            FK_MADT_MAX_NMI, FK_MADT_MIN_LEN, FK_MADT_LEN_MAX, &
            FK_MADT_BAD32, FK_MADT_BAD64, &
            madt_parse, madt_lapic_addr, madt_flags, madt_pcat_compat, &
            madt_addr_override, &
            madt_cpu_count, madt_cpu_enabled, madt_cpu_apic_id, &
            madt_cpu_acpi_id, &
            madt_ioapic_count, madt_ioapic_id, madt_ioapic_addr, &
            madt_ioapic_gsi_base, &
            madt_iso_count, madt_iso_bus, madt_iso_src, madt_iso_gsi, &
            madt_iso_flags, madt_gsi_for_irq, &
            madt_nmi_count, madt_nmi_acpi_id, madt_nmi_lint, madt_nmi_flags, &
            madt_skipped

  integer(c_int32_t), parameter :: FK_MADT_OK              =  0_c_int32_t
  integer(c_int32_t), parameter :: FK_MADT_E_NULL          =  1_c_int32_t
  integer(c_int32_t), parameter :: FK_MADT_E_LEN           =  2_c_int32_t
  integer(c_int32_t), parameter :: FK_MADT_E_SIG           =  3_c_int32_t
  integer(c_int32_t), parameter :: FK_MADT_E_CHECKSUM      =  4_c_int32_t
  integer(c_int32_t), parameter :: FK_MADT_E_TRUNC         =  5_c_int32_t
  integer(c_int32_t), parameter :: FK_MADT_E_ENTRY_ZERO    =  6_c_int32_t
  integer(c_int32_t), parameter :: FK_MADT_E_ENTRY_OVERRUN =  7_c_int32_t
  integer(c_int32_t), parameter :: FK_MADT_E_ENTRY_SHORT   =  8_c_int32_t
  integer(c_int32_t), parameter :: FK_MADT_E_MANY_CPU      =  9_c_int32_t
  integer(c_int32_t), parameter :: FK_MADT_E_MANY_IOAPIC   = 10_c_int32_t
  integer(c_int32_t), parameter :: FK_MADT_E_MANY_ISO      = 11_c_int32_t
  integer(c_int32_t), parameter :: FK_MADT_E_MANY_NMI      = 12_c_int32_t

  ! 36-byte ACPI header + lapic_addr + flags.  Entries begin here.
  integer(c_int32_t), parameter :: FK_MADT_MIN_LEN = 44_c_int32_t
  ! A MADT for 1024 x2APIC cores is about 16 KiB; real ones are ~160 bytes.
  ! The cap is defence in depth for the arithmetic below rather than a size
  ! belief: it bounds every table-controlled offset far from huge(int32).
  integer(c_int32_t), parameter :: FK_MADT_LEN_MAX = 65536_c_int32_t

  ! Overflow is REFUSED, never truncated: a CPU list this module silently
  ! shortened is a machine whose remaining cores never get an INIT-SIPI.
  integer(c_int32_t), parameter :: FK_MADT_MAX_CPU    = 256_c_int32_t
  integer(c_int32_t), parameter :: FK_MADT_MAX_IOAPIC =  16_c_int32_t
  integer(c_int32_t), parameter :: FK_MADT_MAX_ISO    =  64_c_int32_t
  integer(c_int32_t), parameter :: FK_MADT_MAX_NMI    = 256_c_int32_t

  integer(c_int32_t), parameter :: FK_MADT_BAD32 = not(0_c_int32_t)
  integer(c_int64_t), parameter :: FK_MADT_BAD64 = not(0_c_int64_t)

  integer(c_int32_t), parameter :: OFF_LEN    =  4_c_int32_t
  integer(c_int32_t), parameter :: OFF_LAPIC  = 36_c_int32_t
  integer(c_int32_t), parameter :: OFF_FLAGS  = 40_c_int32_t

  integer(c_int32_t), parameter :: T_CPU    = 0_c_int32_t
  integer(c_int32_t), parameter :: T_IOAPIC = 1_c_int32_t
  integer(c_int32_t), parameter :: T_ISO    = 2_c_int32_t
  integer(c_int32_t), parameter :: T_NMI    = 4_c_int32_t
  integer(c_int32_t), parameter :: T_OVR    = 5_c_int32_t

  integer(c_int32_t), parameter :: LEN_CPU    =  8_c_int32_t
  integer(c_int32_t), parameter :: LEN_IOAPIC = 12_c_int32_t
  integer(c_int32_t), parameter :: LEN_ISO    = 10_c_int32_t
  integer(c_int32_t), parameter :: LEN_NMI    =  6_c_int32_t
  integer(c_int32_t), parameter :: LEN_OVR    = 12_c_int32_t

  integer(c_int64_t), parameter :: U32_MASK = int(z'FFFFFFFF', c_int64_t)

  ! "APIC", as bytes, for fk_memcmp.  A variable and not a parameter: c_loc
  ! needs something with an address.
  integer(c_int8_t), target, save :: SIG_APIC(0:3) = &
       [65_c_int8_t, 80_c_int8_t, 73_c_int8_t, 67_c_int8_t]

  integer(c_int8_t),  pointer :: tab(:) => null()
  integer(c_int32_t), save    :: tlen = 0_c_int32_t

  integer(c_int32_t), save :: hdr_lapic = 0_c_int32_t
  integer(c_int32_t), save :: hdr_flags = 0_c_int32_t
  integer(c_int64_t), save :: ovr_addr  = 0_c_int64_t
  integer(c_int32_t), save :: ovr_seen  = 0_c_int32_t

  integer(c_int32_t), save :: n_cpu  = 0_c_int32_t
  integer(c_int32_t), save :: n_ioa  = 0_c_int32_t
  integer(c_int32_t), save :: n_iso  = 0_c_int32_t
  integer(c_int32_t), save :: n_nmi  = 0_c_int32_t
  integer(c_int32_t), save :: n_skip = 0_c_int32_t

  integer(c_int32_t), save :: cpu_acpi(0:FK_MADT_MAX_CPU - 1)
  integer(c_int32_t), save :: cpu_apic(0:FK_MADT_MAX_CPU - 1)
  integer(c_int32_t), save :: cpu_flag(0:FK_MADT_MAX_CPU - 1)

  integer(c_int32_t), save :: ioa_id(0:FK_MADT_MAX_IOAPIC - 1)
  integer(c_int64_t), save :: ioa_addr(0:FK_MADT_MAX_IOAPIC - 1)
  integer(c_int32_t), save :: ioa_gsi(0:FK_MADT_MAX_IOAPIC - 1)

  integer(c_int32_t), save :: iso_bus(0:FK_MADT_MAX_ISO - 1)
  integer(c_int32_t), save :: iso_src(0:FK_MADT_MAX_ISO - 1)
  integer(c_int32_t), save :: iso_gsi(0:FK_MADT_MAX_ISO - 1)
  integer(c_int32_t), save :: iso_flg(0:FK_MADT_MAX_ISO - 1)

  integer(c_int32_t), save :: nmi_acpi(0:FK_MADT_MAX_NMI - 1)
  integer(c_int32_t), save :: nmi_lnt(0:FK_MADT_MAX_NMI - 1)
  integer(c_int32_t), save :: nmi_flg(0:FK_MADT_MAX_NMI - 1)

contains

  ! --- byte-wise readers ----------------------------------------------------

  function db(off) result(v)
    implicit none
    integer(c_int32_t), intent(in) :: off
    integer(c_int32_t) :: v

    ! c_int8_t is signed, so 0xFF arrives as -1.  Without this mask every byte
    ! from 0x80 up poisons the whole assembled field with sign bits.
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

  function d64(off) result(v)
    implicit none
    integer(c_int32_t), intent(in) :: off
    integer(c_int64_t) :: v

    v = ior(wide(d32(off)), shiftl(wide(d32(off + 4_c_int32_t)), 32))
  end function d64

  ! A u32 bit pattern widened to 64 bits.  Masked after the widening: int() on
  ! a value with bit 31 set sign-extends it across the whole upper half, and
  ! 0xFEE00000 -- the lapic address on every machine this runs on -- has it.
  function wide(v) result(w)
    implicit none
    integer(c_int32_t), intent(in) :: v
    integer(c_int64_t) :: w

    w = iand(int(v, c_int64_t), U32_MASK)
  end function wide

  subroutine reset()
    implicit none

    nullify(tab)
    tlen      = 0_c_int32_t
    hdr_lapic = 0_c_int32_t
    hdr_flags = 0_c_int32_t
    ovr_addr  = 0_c_int64_t
    ovr_seen  = 0_c_int32_t
    n_cpu     = 0_c_int32_t
    n_ioa     = 0_c_int32_t
    n_iso     = 0_c_int32_t
    n_nmi     = 0_c_int32_t
    n_skip    = 0_c_int32_t
  end subroutine reset

  ! --- parsing --------------------------------------------------------------

  function madt_parse(virt, len) result(status) bind(c, name="madt_parse")
    implicit none
    integer(c_int64_t), intent(in), value :: virt
    integer(c_int32_t), intent(in), value :: len
    integer(c_int32_t) :: status
    type(c_ptr) :: p

    ! Every failure below leaves the module in the state it starts in, so a
    ! caller that ignores the status reads sentinels rather than the table a
    ! previous call latched.
    call reset()

    ! Signed, deliberately: len is this kernel's own count of mapped bytes, so
    ! bit 31 set is a caller bug and not a 2 GiB table.
    if (len < FK_MADT_MIN_LEN .or. len > FK_MADT_LEN_MAX) then
       status = FK_MADT_E_LEN
       return
    end if

    p = transfer(virt, p)
    if (.not. c_associated(p)) then
       status = FK_MADT_E_NULL
       return
    end if

    call c_f_pointer(p, tab, [len])
    tlen = len

    status = walk(p)
    if (status /= FK_MADT_OK) call reset()
  end function madt_parse

  function walk(p) result(status)
    implicit none
    type(c_ptr), intent(in) :: p
    integer(c_int32_t) :: status, hlen, off, etype, elen, ck, i

    if (fk_memcmp(p, c_loc(SIG_APIC), 4_c_size_t) /= 0_c_int32_t) then
       status = FK_MADT_E_SIG
       return
    end if

    hlen = d32(OFF_LEN)
    ! One signed test covers both ends: a length field with bit 31 set is a
    ! negative here and is refused with the too-short ones.
    if (hlen < FK_MADT_MIN_LEN) then
       status = FK_MADT_E_LEN
       return
    end if
    if (hlen > tlen) then
       status = FK_MADT_E_TRUNC
       return
    end if

    ! Sum-mod-256 over the whole table.  Masked every step so the accumulator
    ! cannot overflow on a large table -- and note this sum is IDENTICAL for
    ! signed and unsigned bytes, so a clean checksum proves nothing about the
    ! sign handling in db().
    ck = 0_c_int32_t
    do i = 0_c_int32_t, hlen - 1_c_int32_t
       ck = iand(ck + db(i), 255_c_int32_t)
    end do
    if (ck /= 0_c_int32_t) then
       status = FK_MADT_E_CHECKSUM
       return
    end if

    hdr_lapic = d32(OFF_LAPIC)
    hdr_flags = d32(OFF_FLAGS)

    off = FK_MADT_MIN_LEN
    do while (off < hlen)
       ! SUBTRACT, NEVER ADD.  off and elen are table-controlled and hlen is
       ! accepted up to huge(0_c_int32_t); off + elen therefore wraps NEGATIVE
       ! under -fwrapv, the guard passes, and off indexes ~2 GiB below the
       ! table.  off < hlen is the loop condition, so hlen - off is positive
       ! and no sum is formed.
       if (hlen - off < 2_c_int32_t) then
          status = FK_MADT_E_ENTRY_OVERRUN
          return
       end if
       etype = db(off)
       elen  = db(off + 1_c_int32_t)
       ! Zero is the one input that makes this loop never advance; 1 is the
       ! same malformation, an entry shorter than its own type/length pair.
       if (elen < 2_c_int32_t) then
          status = FK_MADT_E_ENTRY_ZERO
          return
       end if
       if (elen > hlen - off) then
          status = FK_MADT_E_ENTRY_OVERRUN
          return
       end if
       status = take(etype, elen, off)
       if (status /= FK_MADT_OK) return
       off = off + elen
    end do

    status = FK_MADT_OK
  end function walk

  ! One entry.  An entry shorter than its own type demands is refused rather
  ! than decoded: its trailing fields would be read from the next entry, or
  ! past the end of the table when it is the last one.
  function take(etype, elen, off) result(status)
    implicit none
    integer(c_int32_t), intent(in) :: etype, elen, off
    integer(c_int32_t) :: status

    status = FK_MADT_OK
    select case (etype)
    case (T_CPU)
       if (elen < LEN_CPU) then
          status = FK_MADT_E_ENTRY_SHORT
       else if (n_cpu >= FK_MADT_MAX_CPU) then
          status = FK_MADT_E_MANY_CPU
       else
          cpu_acpi(n_cpu) = db(off + 2_c_int32_t)
          cpu_apic(n_cpu) = db(off + 3_c_int32_t)
          cpu_flag(n_cpu) = d32(off + 4_c_int32_t)
          n_cpu = n_cpu + 1_c_int32_t
       end if
    case (T_IOAPIC)
       if (elen < LEN_IOAPIC) then
          status = FK_MADT_E_ENTRY_SHORT
       else if (n_ioa >= FK_MADT_MAX_IOAPIC) then
          status = FK_MADT_E_MANY_IOAPIC
       else
          ioa_id(n_ioa)   = db(off + 2_c_int32_t)
          ioa_addr(n_ioa) = wide(d32(off + 4_c_int32_t))
          ioa_gsi(n_ioa)  = d32(off + 8_c_int32_t)
          n_ioa = n_ioa + 1_c_int32_t
       end if
    case (T_ISO)
       if (elen < LEN_ISO) then
          status = FK_MADT_E_ENTRY_SHORT
       else if (n_iso >= FK_MADT_MAX_ISO) then
          status = FK_MADT_E_MANY_ISO
       else
          iso_bus(n_iso) = db(off + 2_c_int32_t)
          iso_src(n_iso) = db(off + 3_c_int32_t)
          iso_gsi(n_iso) = d32(off + 4_c_int32_t)
          iso_flg(n_iso) = d16(off + 8_c_int32_t)
          n_iso = n_iso + 1_c_int32_t
       end if
    case (T_NMI)
       if (elen < LEN_NMI) then
          status = FK_MADT_E_ENTRY_SHORT
       else if (n_nmi >= FK_MADT_MAX_NMI) then
          status = FK_MADT_E_MANY_NMI
       else
          nmi_acpi(n_nmi) = db(off + 2_c_int32_t)
          ! ACPI 6.5 table 5.48 really does put this 16-bit field at offset 3.
          nmi_flg(n_nmi)  = d16(off + 3_c_int32_t)
          nmi_lnt(n_nmi)  = db(off + 5_c_int32_t)
          n_nmi = n_nmi + 1_c_int32_t
       end if
    case (T_OVR)
       if (elen < LEN_OVR) then
          status = FK_MADT_E_ENTRY_SHORT
       else
          ovr_addr = d64(off + 4_c_int32_t)
          ovr_seen = 1_c_int32_t
       end if
    case default
       n_skip = n_skip + 1_c_int32_t
    end select
  end function take

  ! --- header ---------------------------------------------------------------

  function madt_lapic_addr() result(v) bind(c, name="madt_lapic_addr")
    implicit none
    integer(c_int64_t) :: v

    if (ovr_seen /= 0_c_int32_t) then
       v = ovr_addr
    else
       v = wide(hdr_lapic)
    end if
  end function madt_lapic_addr

  function madt_flags() result(v) bind(c, name="madt_flags")
    implicit none
    integer(c_int32_t) :: v

    v = hdr_flags
  end function madt_flags

  function madt_pcat_compat() result(v) bind(c, name="madt_pcat_compat")
    implicit none
    integer(c_int32_t) :: v

    v = iand(hdr_flags, 1_c_int32_t)
  end function madt_pcat_compat

  function madt_addr_override() result(v) bind(c, name="madt_addr_override")
    implicit none
    integer(c_int64_t) :: v

    v = ovr_addr
  end function madt_addr_override

  ! --- processors -----------------------------------------------------------

  function madt_cpu_count() result(v) bind(c, name="madt_cpu_count")
    implicit none
    integer(c_int32_t) :: v

    v = n_cpu
  end function madt_cpu_count

  function madt_cpu_enabled() result(v) bind(c, name="madt_cpu_enabled")
    implicit none
    integer(c_int32_t) :: v, i

    v = 0_c_int32_t
    do i = 0_c_int32_t, n_cpu - 1_c_int32_t
       if (iand(cpu_flag(i), 1_c_int32_t) /= 0_c_int32_t) v = v + 1_c_int32_t
    end do
  end function madt_cpu_enabled

  function madt_cpu_apic_id(i) result(v) bind(c, name="madt_cpu_apic_id")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = FK_MADT_BAD32
    if (i >= 0_c_int32_t .and. i < n_cpu) v = cpu_apic(i)
  end function madt_cpu_apic_id

  function madt_cpu_acpi_id(i) result(v) bind(c, name="madt_cpu_acpi_id")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = FK_MADT_BAD32
    if (i >= 0_c_int32_t .and. i < n_cpu) v = cpu_acpi(i)
  end function madt_cpu_acpi_id

  ! --- IOAPICs --------------------------------------------------------------

  function madt_ioapic_count() result(v) bind(c, name="madt_ioapic_count")
    implicit none
    integer(c_int32_t) :: v

    v = n_ioa
  end function madt_ioapic_count

  function madt_ioapic_id(i) result(v) bind(c, name="madt_ioapic_id")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = FK_MADT_BAD32
    if (i >= 0_c_int32_t .and. i < n_ioa) v = ioa_id(i)
  end function madt_ioapic_id

  function madt_ioapic_addr(i) result(v) bind(c, name="madt_ioapic_addr")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t) :: v

    v = FK_MADT_BAD64
    if (i >= 0_c_int32_t .and. i < n_ioa) v = ioa_addr(i)
  end function madt_ioapic_addr

  function madt_ioapic_gsi_base(i) result(v) bind(c, name="madt_ioapic_gsi_base")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = FK_MADT_BAD32
    if (i >= 0_c_int32_t .and. i < n_ioa) v = ioa_gsi(i)
  end function madt_ioapic_gsi_base

  ! --- interrupt source overrides -------------------------------------------

  function madt_iso_count() result(v) bind(c, name="madt_iso_count")
    implicit none
    integer(c_int32_t) :: v

    v = n_iso
  end function madt_iso_count

  function madt_iso_bus(i) result(v) bind(c, name="madt_iso_bus")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = FK_MADT_BAD32
    if (i >= 0_c_int32_t .and. i < n_iso) v = iso_bus(i)
  end function madt_iso_bus

  function madt_iso_src(i) result(v) bind(c, name="madt_iso_src")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = FK_MADT_BAD32
    if (i >= 0_c_int32_t .and. i < n_iso) v = iso_src(i)
  end function madt_iso_src

  function madt_iso_gsi(i) result(v) bind(c, name="madt_iso_gsi")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = FK_MADT_BAD32
    if (i >= 0_c_int32_t .and. i < n_iso) v = iso_gsi(i)
  end function madt_iso_gsi

  function madt_iso_flags(i) result(v) bind(c, name="madt_iso_flags")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = FK_MADT_BAD32
    if (i >= 0_c_int32_t .and. i < n_iso) v = iso_flg(i)
  end function madt_iso_flags

  ! The whole point of the Type 2 entries: on this hardware the PIT's IRQ 0
  ! arrives at the IOAPIC as GSI 2, and an identity map would arm the wrong pin.
  function madt_gsi_for_irq(irq) result(v) bind(c, name="madt_gsi_for_irq")
    implicit none
    integer(c_int32_t), intent(in), value :: irq
    integer(c_int32_t) :: v, i

    v = irq
    do i = 0_c_int32_t, n_iso - 1_c_int32_t
       if (iso_src(i) == irq) then
          v = iso_gsi(i)
          return
       end if
    end do
  end function madt_gsi_for_irq

  ! --- local APIC NMI sources -----------------------------------------------

  function madt_nmi_count() result(v) bind(c, name="madt_nmi_count")
    implicit none
    integer(c_int32_t) :: v

    v = n_nmi
  end function madt_nmi_count

  function madt_nmi_acpi_id(i) result(v) bind(c, name="madt_nmi_acpi_id")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = FK_MADT_BAD32
    if (i >= 0_c_int32_t .and. i < n_nmi) v = nmi_acpi(i)
  end function madt_nmi_acpi_id

  function madt_nmi_lint(i) result(v) bind(c, name="madt_nmi_lint")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = FK_MADT_BAD32
    if (i >= 0_c_int32_t .and. i < n_nmi) v = nmi_lnt(i)
  end function madt_nmi_lint

  function madt_nmi_flags(i) result(v) bind(c, name="madt_nmi_flags")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = FK_MADT_BAD32
    if (i >= 0_c_int32_t .and. i < n_nmi) v = nmi_flg(i)
  end function madt_nmi_flags

  function madt_skipped() result(v) bind(c, name="madt_skipped")
    implicit none
    integer(c_int32_t) :: v

    v = n_skip
  end function madt_skipped

end module fk_madt_m
