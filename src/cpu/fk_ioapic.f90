! SPDX-License-Identifier: GPL-2.0
! The I/O APIC's redirection table (roadmap 3.3).
!
! Two registers on the page and nothing else: IOREGSEL at +0x00 selects, IOWIN
! at +0x10 reads or writes whatever was selected.  Every register is 32 bits
! wide and the part's behaviour under any other access width is undefined, so
! both are mapped onto a c_int32_t scalar the way fk_lapic_m maps the LAPIC's.
!
! INDEXED ACCESS IS WHY HALF OF THIS FILE IS NOT HOST-TESTABLE.  A flat buffer
! cannot model write-selector-then-read-window, so tests/cpu/test_ioapic.c
! checks the redirection entry's ARITHMETIC -- the two dwords built from a
! vector, a destination and a polarity/trigger pair -- and the sequencing is
! asserted in the boot gate, where QEMU's device model prints the entry back
! through 'info pic'.
!
! Register numbers and field positions are the 82093AA datasheet's, tables 2
! and 3, cross-checked against vendor/linux-7.1.8/arch/x86/include/asm/io_apic.h
! and drivers/irqchip.  Every one carries its source beside it.
module fk_ioapic_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t
  implicit none
  private
  public :: FK_IOAPIC_OK, FK_IOAPIC_E_NOT_READY, FK_IOAPIC_E_GSI, &
            FK_IOAPIC_E_VECTOR, &
            FK_IOAPIC_POL_HIGH, FK_IOAPIC_POL_LOW, &
            FK_IOAPIC_TRIG_EDGE, FK_IOAPIC_TRIG_LEVEL, &
            FK_IOAPIC_VECTOR_MIN, FK_IOAPIC_MAX_GSI, &
            ioapic_set_window, ioapic_ready, &
            ioapic_id, ioapic_version, ioapic_max_redir, &
            ioapic_redir_lo, ioapic_redir_hi, &
            ioapic_route, ioapic_mask, ioapic_unmask, &
            ioapic_read_lo, ioapic_read_hi

  ! io_apic.h:26-27.  The window is at +0x10 and not at +0x04: the two
  ! registers are a cache line apart so that a read of one cannot be satisfied
  ! from a fill of the other.
  integer(c_int32_t), parameter :: OFF_IOREGSEL = int(z'00', c_int32_t)
  integer(c_int32_t), parameter :: OFF_IOWIN    = int(z'10', c_int32_t)

  ! io_apic.h:31-33.
  integer(c_int32_t), parameter :: REG_ID   = int(z'00', c_int32_t)
  integer(c_int32_t), parameter :: REG_VER  = int(z'01', c_int32_t)
  integer(c_int32_t), parameter :: REG_REDIR_BASE = int(z'10', c_int32_t)

  ! ID is bits 27:24 of register 0; VERSION is 7:0 of register 1 and MAX
  ! REDIRECTION ENTRY is 23:16 of the same register.  ENTRIES is that plus one.
  integer(c_int32_t), parameter :: ID_POS  = 24_c_int32_t
  integer(c_int32_t), parameter :: ID_LEN  =  4_c_int32_t
  integer(c_int32_t), parameter :: VER_POS =  0_c_int32_t
  integer(c_int32_t), parameter :: VER_LEN =  8_c_int32_t
  integer(c_int32_t), parameter :: MRE_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: MRE_LEN =  8_c_int32_t

  ! The low dword of a redirection entry, datasheet table 3.  Delivery mode
  ! 000 is FIXED and destination mode 0 is PHYSICAL; both are left at zero
  ! here, so neither has a constant of its own -- a named zero that is never
  ! written is a constant nothing checks.
  integer(c_int32_t), parameter :: LO_VECTOR_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: LO_VECTOR_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: LO_POLARITY_BIT = 13_c_int32_t
  integer(c_int32_t), parameter :: LO_TRIGGER_BIT  = 15_c_int32_t
  integer(c_int32_t), parameter :: LO_MASK_BIT     = 16_c_int32_t

  ! The high dword: physical destination in 31:24 and nothing else defined.
  integer(c_int32_t), parameter :: HI_DEST_POS = 24_c_int32_t
  integer(c_int32_t), parameter :: HI_DEST_LEN =  8_c_int32_t

  integer(c_int32_t), parameter :: FK_IOAPIC_POL_HIGH  = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_IOAPIC_POL_LOW   = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_IOAPIC_TRIG_EDGE  = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_IOAPIC_TRIG_LEVEL = 1_c_int32_t

  ! Vectors 0..31 are the CPU's own exceptions.  An IOAPIC programmed to
  ! deliver one of them raises a #GP-looking fault out of nowhere, with a
  ! stack frame that says the wrong thing about where it came from, so the
  ! encoder refuses rather than encoding it.
  integer(c_int32_t), parameter :: FK_IOAPIC_VECTOR_MIN = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_IOAPIC_MAX_GSI    = 239_c_int32_t

  integer(c_int32_t), parameter :: FK_IOAPIC_OK          = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_IOAPIC_E_NOT_READY = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_IOAPIC_E_GSI       = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_IOAPIC_E_VECTOR    = 3_c_int32_t

  integer(c_int64_t), save :: win = 0_c_int64_t

  ! boot/io.S.  NOT a volatile Fortran pointer: gfortran narrows a load whose
  ! result feeds ibits, and `movzbl 0x2(%rax)` on IOWIN is a one-byte read of a
  ! 32-bit window the datasheet does not define sub-dword behaviour for.  A
  ! call it cannot see through can be neither narrowed nor reordered against
  ! the other one, which is what an indexed register pair needs.
  interface
    function fk_readl(addr) result(v) bind(c, name="fk_readl")
      import :: c_int32_t, c_int64_t
      implicit none
      integer(c_int64_t), intent(in), value :: addr
      integer(c_int32_t)                    :: v
    end function fk_readl
    subroutine fk_writel(addr, v) bind(c, name="fk_writel")
      import :: c_int32_t, c_int64_t
      implicit none
      integer(c_int64_t), intent(in), value :: addr
      integer(c_int32_t), intent(in), value :: v
    end subroutine fk_writel
  end interface

contains

  ! WIN is the ALREADY-MAPPED virtual address of the IOAPIC page.  Nothing in
  ! this module dereferences anything until it is set, which is what lets a
  ! host test link against the file without a page table anywhere in sight.
  subroutine ioapic_set_window(virt) bind(c, name="ioapic_set_window")
    implicit none
    integer(c_int64_t), intent(in), value :: virt

    win = virt
  end subroutine ioapic_set_window

  function ioapic_ready() result(r) bind(c, name="ioapic_ready")
    implicit none
    integer(c_int32_t) :: r

    r = 0_c_int32_t
    if (win /= 0_c_int64_t) r = 1_c_int32_t
  end function ioapic_ready

  ! Select, then touch the window.  The ORDER is the whole contract -- the
  ! window returns whatever IOREGSEL last named -- and two calls to a function
  ! the compiler cannot see through are the construct that carries it.
  function reg_read(reg) result(v)
    implicit none
    integer(c_int32_t), intent(in) :: reg
    integer(c_int32_t) :: v

    call fk_writel(win + int(OFF_IOREGSEL, c_int64_t), reg)
    v = fk_readl(win + int(OFF_IOWIN, c_int64_t))
  end function reg_read

  subroutine reg_write(reg, v)
    implicit none
    integer(c_int32_t), intent(in) :: reg, v

    call fk_writel(win + int(OFF_IOREGSEL, c_int64_t), reg)
    call fk_writel(win + int(OFF_IOWIN, c_int64_t), v)
  end subroutine reg_write

  function ioapic_id() result(v) bind(c, name="ioapic_id")
    implicit none
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (win == 0_c_int64_t) return
    v = ibits(reg_read(REG_ID), ID_POS, ID_LEN)
  end function ioapic_id

  function ioapic_version() result(v) bind(c, name="ioapic_version")
    implicit none
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (win == 0_c_int64_t) return
    v = ibits(reg_read(REG_VER), VER_POS, VER_LEN)
  end function ioapic_version

  ! ENTRIES, not the register's raw field: the part reports the highest usable
  ! index and every caller wants the count.  0 when the window is unset, so a
  ! loop over it on an unmapped IOAPIC runs zero times instead of 24.
  function ioapic_max_redir() result(n) bind(c, name="ioapic_max_redir")
    implicit none
    integer(c_int32_t) :: n

    n = 0_c_int32_t
    if (win == 0_c_int64_t) return
    n = ibits(reg_read(REG_VER), MRE_POS, MRE_LEN) + 1_c_int32_t
  end function ioapic_max_redir

  ! PURE, and the half a host can check.  0 for a vector the CPU owns, which
  ! is a refusal and not an encoding: no valid entry has a zero vector field,
  ! so the caller cannot mistake one for the other.
  pure function ioapic_redir_lo(vector, polarity, trigger, masked) result(v) &
       bind(c, name="ioapic_redir_lo")
    implicit none
    integer(c_int32_t), intent(in), value :: vector, polarity, trigger, masked
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (vector < FK_IOAPIC_VECTOR_MIN) return
    if (vector > 255_c_int32_t) return
    v = ibits(vector, LO_VECTOR_POS, LO_VECTOR_LEN)
    if (polarity /= 0_c_int32_t) v = ibset(v, LO_POLARITY_BIT)
    if (trigger  /= 0_c_int32_t) v = ibset(v, LO_TRIGGER_BIT)
    if (masked   /= 0_c_int32_t) v = ibset(v, LO_MASK_BIT)
  end function ioapic_redir_lo

  pure function ioapic_redir_hi(apic_id) result(v) &
       bind(c, name="ioapic_redir_hi")
    implicit none
    integer(c_int32_t), intent(in), value :: apic_id
    integer(c_int32_t) :: v

    v = shiftl(ibits(apic_id, 0_c_int32_t, HI_DEST_LEN), HI_DEST_POS)
  end function ioapic_redir_hi

  pure function redir_reg(gsi) result(r)
    implicit none
    integer(c_int32_t), intent(in) :: gsi
    integer(c_int32_t) :: r

    r = REG_REDIR_BASE + 2_c_int32_t * gsi
  end function redir_reg

  function ioapic_read_lo(gsi) result(v) bind(c, name="ioapic_read_lo")
    implicit none
    integer(c_int32_t), intent(in), value :: gsi
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (win == 0_c_int64_t) return
    if (gsi < 0_c_int32_t .or. gsi >= ioapic_max_redir()) return
    v = reg_read(redir_reg(gsi))
  end function ioapic_read_lo

  function ioapic_read_hi(gsi) result(v) bind(c, name="ioapic_read_hi")
    implicit none
    integer(c_int32_t), intent(in), value :: gsi
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (win == 0_c_int64_t) return
    if (gsi < 0_c_int32_t .or. gsi >= ioapic_max_redir()) return
    v = reg_read(redir_reg(gsi) + 1_c_int32_t)
  end function ioapic_read_hi

  ! MASK, THEN DESTINATION, THEN THE REST.  The mask bit lives in the LOW
  ! dword, so an entry written low-first is briefly unmasked with a
  ! destination that has not been set yet, and a line that asserts in that
  ! window is delivered to whatever the high dword happened to hold.
  function ioapic_route(gsi, vector, apic_id, polarity, trigger) &
       result(status) bind(c, name="ioapic_route")
    implicit none
    integer(c_int32_t), intent(in), value :: gsi, vector, apic_id
    integer(c_int32_t), intent(in), value :: polarity, trigger
    integer(c_int32_t) :: status
    integer(c_int32_t) :: lo

    if (win == 0_c_int64_t) then
       status = FK_IOAPIC_E_NOT_READY
       return
    end if
    if (gsi < 0_c_int32_t .or. gsi >= ioapic_max_redir()) then
       status = FK_IOAPIC_E_GSI
       return
    end if
    lo = ioapic_redir_lo(vector, polarity, trigger, 0_c_int32_t)
    if (lo == 0_c_int32_t) then
       status = FK_IOAPIC_E_VECTOR
       return
    end if

    call reg_write(redir_reg(gsi), ibset(lo, LO_MASK_BIT))
    call reg_write(redir_reg(gsi) + 1_c_int32_t, ioapic_redir_hi(apic_id))
    call reg_write(redir_reg(gsi), lo)
    status = FK_IOAPIC_OK
  end function ioapic_route

  function ioapic_mask(gsi) result(status) bind(c, name="ioapic_mask")
    implicit none
    integer(c_int32_t), intent(in), value :: gsi
    integer(c_int32_t) :: status

    if (win == 0_c_int64_t) then
       status = FK_IOAPIC_E_NOT_READY
       return
    end if
    if (gsi < 0_c_int32_t .or. gsi >= ioapic_max_redir()) then
       status = FK_IOAPIC_E_GSI
       return
    end if
    call reg_write(redir_reg(gsi), ibset(reg_read(redir_reg(gsi)), LO_MASK_BIT))
    status = FK_IOAPIC_OK
  end function ioapic_mask

  function ioapic_unmask(gsi) result(status) bind(c, name="ioapic_unmask")
    implicit none
    integer(c_int32_t), intent(in), value :: gsi
    integer(c_int32_t) :: status

    if (win == 0_c_int64_t) then
       status = FK_IOAPIC_E_NOT_READY
       return
    end if
    if (gsi < 0_c_int32_t .or. gsi >= ioapic_max_redir()) then
       status = FK_IOAPIC_E_GSI
       return
    end if
    call reg_write(redir_reg(gsi), ibclr(reg_read(redir_reg(gsi)), LO_MASK_BIT))
    status = FK_IOAPIC_OK
  end function ioapic_unmask

end module fk_ioapic_m
