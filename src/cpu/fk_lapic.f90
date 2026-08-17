! SPDX-License-Identifier: GPL-2.0
! The boot processor's Local APIC (roadmap 3.3).
!
! The MSR half and the MMIO half are deliberately separate.  IA32_APIC_BASE
! carries the BSP's own LAPIC address with no ACPI involved, so lapic_msr_base
! and lapic_msr_enabled answer where the chip is; the kernel maps that page and
! hands the VIRTUAL address to lapic_init.  Nothing here maps, translates or
! consults the MSR to find itself, which is also what lets a host test point the
! driver at an ordinary 4 KiB buffer.
module fk_lapic_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t, c_ptr, c_f_pointer
  implicit none
  private
  public :: lapic_init, lapic_eoi, lapic_id, lapic_version, lapic_svr, &
            lapic_lint0_extint, LVT_DM_EXTINT, &
            lapic_max_lvt, &
            lapic_lvt_cmci, lapic_lvt_timer, lapic_lvt_thermal, &
            lapic_lvt_perf, lapic_lvt_lint0, lapic_lvt_lint1, lapic_lvt_error, &
            lapic_msr_base, lapic_msr_enabled

  integer(c_int32_t), parameter :: REG_ID      = int(z'020', c_int32_t)
  integer(c_int32_t), parameter :: REG_VERSION = int(z'030', c_int32_t)
  integer(c_int32_t), parameter :: REG_TPR     = int(z'080', c_int32_t)
  integer(c_int32_t), parameter :: REG_EOI     = int(z'0B0', c_int32_t)
  integer(c_int32_t), parameter :: REG_SVR     = int(z'0F0', c_int32_t)

  integer(c_int32_t), parameter :: REG_LVT_CMCI    = int(z'2F0', c_int32_t)
  integer(c_int32_t), parameter :: REG_LVT_TIMER   = int(z'320', c_int32_t)
  integer(c_int32_t), parameter :: REG_LVT_THERMAL = int(z'330', c_int32_t)
  integer(c_int32_t), parameter :: REG_LVT_PERF    = int(z'340', c_int32_t)
  integer(c_int32_t), parameter :: REG_LVT_LINT0   = int(z'350', c_int32_t)
  integer(c_int32_t), parameter :: REG_LVT_LINT1   = int(z'360', c_int32_t)
  integer(c_int32_t), parameter :: REG_LVT_ERROR   = int(z'370', c_int32_t)

  integer(c_int32_t), parameter :: SVR_ENABLE      = int(z'100', c_int32_t)
  integer(c_int32_t), parameter :: SVR_VECTOR_MASK = 255_c_int32_t

  ! Bit 16 set, delivery mode (10:8) and vector (7:0) cleared.  Written WHOLE
  ! rather than read-modify-written: firmware leaves LINT0 in ExtINT delivery
  ! mode so the 8259 reaches the CPU through the LAPIC, and only overwriting
  ! that field takes the line out of ExtINT instead of merely gating it.
  integer(c_int32_t), parameter :: LVT_MASKED = int(z'10000', c_int32_t)
  ! Delivery mode 111b in bits 10:8, mask bit clear: the 8259's INTR pin
  ! forwarded to the core.
  integer(c_int32_t), parameter :: LVT_DM_EXTINT = int(z'700', c_int32_t)

  integer(c_int32_t), parameter :: MSR_APIC_BASE  = int(z'1B', c_int32_t)
  integer(c_int32_t), parameter :: APIC_BASE_EN   = 11_c_int32_t
  ! Bits 51:12.  Masked out, never shifted down and back: bits 63:52 are
  ! reserved and a SHIFTA on the way down would drag them into the address.
  integer(c_int64_t), parameter :: APIC_BASE_MASK = &
       int(z'000FFFFFFFFFF000', c_int64_t)

  interface
    ! boot/mmu.S.  RDMSR is privileged and unspellable in Fortran.
    function fk_rdmsr(msr) result(v) bind(c, name="fk_rdmsr")
      import :: c_int32_t, c_int64_t
      implicit none
      integer(c_int32_t), intent(in), value :: msr
      integer(c_int64_t)                    :: v
    end function fk_rdmsr
  end interface

contains

  ! Every LAPIC register is 32 bits wide and the chip's behaviour under any
  ! other access width is undefined, so the mapping is onto a c_int32_t scalar:
  ! one whole-register load or store, never a 64-bit one.
  function reg_read(base, off) result(v)
    implicit none
    integer(c_int64_t), intent(in) :: base
    integer(c_int32_t), intent(in) :: off
    integer(c_int32_t) :: v
    integer(c_int32_t), volatile, pointer :: r
    type(c_ptr) :: p

    p = transfer(base + int(off, c_int64_t), p)
    call c_f_pointer(p, r)
    v = r
  end function reg_read

  subroutine reg_write(base, off, v)
    implicit none
    integer(c_int64_t), intent(in) :: base
    integer(c_int32_t), intent(in) :: off, v
    integer(c_int32_t), volatile, pointer :: r
    type(c_ptr) :: p

    p = transfer(base + int(off, c_int64_t), p)
    call c_f_pointer(p, r)
    r = v
  end subroutine reg_write

  ! base is the already-mapped virtual address of the LAPIC page.  Order is
  ! load-bearing: priority is dropped and every LVT is masked BEFORE the
  ! software-enable bit in SVR makes any of them able to deliver.
  subroutine lapic_init(base, spurious_vector) bind(c, name="lapic_init")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t), intent(in), value :: spurious_vector

    call reg_write(base, REG_TPR, 0_c_int32_t)

    ! CMCI exists only where Max LVT Entry (VERSION bits 23:16) is at least 6.
    ! QEMU reports 5 and tolerates the write; a real part is not obliged to, and
    ! an MMIO write to a register that is not there is not a no-op by contract.
    if (lapic_max_lvt(base) >= 6_c_int32_t) &
         call reg_write(base, REG_LVT_CMCI, LVT_MASKED)
    call reg_write(base, REG_LVT_TIMER,   LVT_MASKED)
    call reg_write(base, REG_LVT_THERMAL, LVT_MASKED)
    call reg_write(base, REG_LVT_PERF,    LVT_MASKED)
    call reg_write(base, REG_LVT_LINT0,   LVT_MASKED)
    call reg_write(base, REG_LVT_LINT1,   LVT_MASKED)
    call reg_write(base, REG_LVT_ERROR,   LVT_MASKED)

    call reg_write(base, REG_SVR, &
         ior(iand(spurious_vector, SVR_VECTOR_MASK), SVR_ENABLE))
  end subroutine lapic_init

  ! The written value is ignored by the chip; only the write matters.  Nothing
  ! else on the page is touched, which is what makes it safe inside a gate.
  subroutine lapic_eoi(base) bind(c, name="lapic_eoi")
    implicit none
    integer(c_int64_t), intent(in), value :: base

    call reg_write(base, REG_EOI, 0_c_int32_t)
  end subroutine lapic_eoi

  ! Bits 31:24 of the ID register.  SHIFTR and never SHIFTA: bit 31 would
  ! otherwise sign-extend across the whole result.
  function lapic_id(base) result(v) bind(c, name="lapic_id")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t) :: v

    v = shiftr(reg_read(base, REG_ID), 24)
  end function lapic_id

  ! Raw: bits 7:0 are the version and bits 23:16 the highest LVT entry this
  ! part implements, which is the caller's only way to know whether LVT CMCI
  ! exists at all.
  function lapic_version(base) result(v) bind(c, name="lapic_version")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t) :: v

    v = reg_read(base, REG_VERSION)
  end function lapic_version

  ! The seven readbacks below exist so the kernel can report what the chip
  ! holds rather than what this module intended to put there.
  ! Put LINT0 back into ExtINT, UNMASKED.  Once SVR bit 8 is set the CPU no
  ! longer takes the 8259's INTR pin directly -- it arrives through LINT0 -- so
  ! a masked LINT0 on a kernel whose only interrupt source is the 8259 silently
  ! stops the timer, and a scheduler driven by that timer simply stops.  Linux
  ! leaves the BSP's LINT0 as ExtINT for the same window, until the IOAPIC takes
  ! over at roadmap 4.1.
  subroutine lapic_lint0_extint(base) bind(c, name="lapic_lint0_extint")
    implicit none
    integer(c_int64_t), intent(in), value :: base

    call reg_write(base, REG_LVT_LINT0, LVT_DM_EXTINT)
  end subroutine lapic_lint0_extint

  function lapic_max_lvt(base) result(n) bind(c, name="lapic_max_lvt")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t) :: n

    n = iand(shiftr(reg_read(base, REG_VERSION), 16), 255_c_int32_t)
  end function lapic_max_lvt

  function lapic_svr(base) result(v) bind(c, name="lapic_svr")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t) :: v

    v = reg_read(base, REG_SVR)
  end function lapic_svr

  function lapic_lvt_cmci(base) result(v) bind(c, name="lapic_lvt_cmci")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t) :: v

    v = reg_read(base, REG_LVT_CMCI)
  end function lapic_lvt_cmci

  function lapic_lvt_timer(base) result(v) bind(c, name="lapic_lvt_timer")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t) :: v

    v = reg_read(base, REG_LVT_TIMER)
  end function lapic_lvt_timer

  function lapic_lvt_thermal(base) result(v) bind(c, name="lapic_lvt_thermal")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t) :: v

    v = reg_read(base, REG_LVT_THERMAL)
  end function lapic_lvt_thermal

  function lapic_lvt_perf(base) result(v) bind(c, name="lapic_lvt_perf")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t) :: v

    v = reg_read(base, REG_LVT_PERF)
  end function lapic_lvt_perf

  function lapic_lvt_lint0(base) result(v) bind(c, name="lapic_lvt_lint0")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t) :: v

    v = reg_read(base, REG_LVT_LINT0)
  end function lapic_lvt_lint0

  function lapic_lvt_lint1(base) result(v) bind(c, name="lapic_lvt_lint1")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t) :: v

    v = reg_read(base, REG_LVT_LINT1)
  end function lapic_lvt_lint1

  function lapic_lvt_error(base) result(v) bind(c, name="lapic_lvt_error")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t) :: v

    v = reg_read(base, REG_LVT_ERROR)
  end function lapic_lvt_error

  ! The PHYSICAL base out of IA32_APIC_BASE, bits 51:12.  Call this, map the
  ! page uncached, then pass the virtual address to lapic_init.
  function lapic_msr_base() result(v) bind(c, name="lapic_msr_base")
    implicit none
    integer(c_int64_t) :: v

    v = iand(fk_rdmsr(MSR_APIC_BASE), APIC_BASE_MASK)
  end function lapic_msr_base

  ! Bit 11, the global enable.  Clearing it on a P6 is irreversible until
  ! reset, so the kernel checks rather than assumes.
  function lapic_msr_enabled() result(v) bind(c, name="lapic_msr_enabled")
    implicit none
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (btest(fk_rdmsr(MSR_APIC_BASE), APIC_BASE_EN)) v = 1_c_int32_t
  end function lapic_msr_enabled

end module fk_lapic_m
