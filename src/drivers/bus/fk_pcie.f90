! SPDX-License-Identifier: GPL-2.0
! PCIe configuration space through ECAM, and the walk over it (roadmap 4.2).
!
! Legacy port I/O (0xCF8/0xCFC) is not implemented and will not be: it reaches
! only the first 256 bytes of a function's configuration space and only one
! segment group, and every device this kernel is being written for is behind
! the memory-mapped mechanism.
!
! An ECAM address is base + bus<<20 + device<<15 + function<<12 + offset (PCIe
! 5.0 section 7.2.2 table 7-1), and the three shifts come from fk_pcie_types_m
! rather than being written again here.
!
! EVERY ACCESS IS A WHOLE DWORD, through boot/io.S's fk_readl and never through
! a volatile Fortran pointer.  gfortran narrows such a pointer's load when only
! some of its bits are used -- ibits(load, 16, 8) becomes a one-byte read --
! and while ECAM does permit byte and word accesses, a dword read is the form
! every device answers identically and it is what fk_pcie_types_m's header
! already says the driver path does.  tools/mmiocheck.sh enforces it.
!
! It takes a VIRTUAL address and reads through it, so a host test can point it
! at ordinary memory: the split that made fk_madt_m and fk_ioapic_m testable.
module fk_pcie_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t
  use fk_pcie_types_m, only: FK_PCI_ECAM_BUS_SHIFT, FK_PCI_ECAM_DEV_SHIFT, &
                             FK_PCI_ECAM_FUNC_SHIFT, &
                             FK_PCI_HDR_TYPE_POS, FK_PCI_HDR_TYPE_LEN, &
                             FK_PCI_HDR_TYPE_MFD_BIT, &
                             FK_PCI_XHCI_CLASS, FK_PCI_XHCI_SUBCLASS, &
                             FK_PCI_XHCI_PROGIF, &
                             FK_PCI_NVME_CLASS, FK_PCI_NVME_SUBCLASS, &
                             FK_PCI_NVME_PROGIF
  implicit none
  private
  public :: FK_PCIE_MAX_DEV, FK_PCIE_ABSENT, FK_PCIE_NOT_FOUND, &
            pcie_set_window, pcie_ready, pcie_cfg_offset, &
            pcie_cfg_read32, pcie_cfg_read16, pcie_cfg_read8, &
            pcie_scan, pcie_count, pcie_seen, pcie_overflowed, &
            pcie_bdf, pcie_bus, pcie_device, pcie_function, &
            pcie_vendor, pcie_devid, pcie_class, pcie_subclass, &
            pcie_progif, pcie_header_type, pcie_multifunction, &
            pcie_find_class, pcie_find_xhci, pcie_find_nvme

  ! A configuration read of a function that is not there returns all ones on
  ! every dword, so the vendor id is the probe.
  integer(c_int32_t), parameter :: FK_PCIE_ABSENT    = int(z'FFFF', c_int32_t)
  integer(c_int32_t), parameter :: FK_PCIE_NOT_FOUND = -1_c_int32_t
  integer(c_int32_t), parameter :: FK_PCIE_MAX_DEV   = 64_c_int32_t

  integer(c_int32_t), parameter :: OFF_VENDOR   = int(z'00', c_int32_t)
  integer(c_int32_t), parameter :: OFF_REVCLASS = int(z'08', c_int32_t)
  ! 0x0E and not 0x0C: the dword at 0x0C is cache line size, latency timer,
  ! HEADER TYPE, BIST -- in that order.
  integer(c_int32_t), parameter :: OFF_HDRTYPE  = int(z'0E', c_int32_t)

  integer(c_int32_t), parameter :: DEVS_PER_BUS = 32_c_int32_t
  integer(c_int32_t), parameter :: FNS_PER_DEV  =  8_c_int32_t

  integer(c_int64_t), save :: win  = 0_c_int64_t
  integer(c_int32_t), save :: bus_lo = 0_c_int32_t
  integer(c_int32_t), save :: bus_hi = 0_c_int32_t

  integer(c_int32_t), save :: n_dev = 0_c_int32_t
  integer(c_int32_t), save :: n_seen = 0_c_int32_t
  integer(c_int32_t), save :: d_bdf(0:FK_PCIE_MAX_DEV - 1)  = 0_c_int32_t
  integer(c_int32_t), save :: d_ven(0:FK_PCIE_MAX_DEV - 1)  = 0_c_int32_t
  integer(c_int32_t), save :: d_did(0:FK_PCIE_MAX_DEV - 1)  = 0_c_int32_t
  integer(c_int32_t), save :: d_cls(0:FK_PCIE_MAX_DEV - 1)  = 0_c_int32_t
  integer(c_int32_t), save :: d_sub(0:FK_PCIE_MAX_DEV - 1)  = 0_c_int32_t
  integer(c_int32_t), save :: d_pif(0:FK_PCIE_MAX_DEV - 1)  = 0_c_int32_t
  integer(c_int32_t), save :: d_hdr(0:FK_PCIE_MAX_DEV - 1)  = 0_c_int32_t
  integer(c_int32_t), save :: d_mfd(0:FK_PCIE_MAX_DEV - 1)  = 0_c_int32_t

  interface
    function fk_readl(addr) result(v) bind(c, name="fk_readl")
      import :: c_int32_t, c_int64_t
      implicit none
      integer(c_int64_t), intent(in), value :: addr
      integer(c_int32_t)                    :: v
    end function fk_readl
  end interface

contains

  ! VIRT is the already-mapped base of the window.  BUS_START and BUS_END are
  ! the window's OWN range, from the MCFG allocation entry, and the walk never
  ! looks outside them -- an address past the mapping is a page fault, not an
  ! absent device.  The window's PHYSICAL base is not carried here: the caller
  ! got it from mcfg_base and keeping a second copy is a second thing that can
  ! disagree with the mapping actually in force.
  subroutine pcie_set_window(virt, bus_start, bus_end) &
       bind(c, name="pcie_set_window")
    implicit none
    integer(c_int64_t), intent(in), value :: virt
    integer(c_int32_t), intent(in), value :: bus_start, bus_end

    win    = virt
    bus_lo = bus_start
    bus_hi = bus_end
    n_dev  = 0_c_int32_t
    n_seen = 0_c_int32_t
  end subroutine pcie_set_window

  function pcie_ready() result(r) bind(c, name="pcie_ready")
    implicit none
    integer(c_int32_t) :: r

    r = 0_c_int32_t
    if (win /= 0_c_int64_t .and. bus_hi >= bus_lo) r = 1_c_int32_t
  end function pcie_ready

  ! PURE, and the arithmetic on its own.  The offset is from the window's base
  ! rather than from bus_lo's: MCFG's base address already names the address of
  ! bus bus_lo, so a window starting at bus 0 and one starting at bus 64 are
  ! both indexed by the absolute bus number.  Getting that backwards puts every
  ! read 64 MiB away on the second kind of machine and nowhere at all on the
  ! first, which is why it is stated here rather than assumed.
  pure function pcie_cfg_offset(bus, dev, fn, off) result(a) &
       bind(c, name="pcie_cfg_offset")
    implicit none
    integer(c_int32_t), intent(in), value :: bus, dev, fn, off
    integer(c_int64_t) :: a

    a = ior(ior(shiftl(int(bus, c_int64_t), FK_PCI_ECAM_BUS_SHIFT), &
                shiftl(int(dev, c_int64_t), FK_PCI_ECAM_DEV_SHIFT)), &
            ior(shiftl(int(fn, c_int64_t), FK_PCI_ECAM_FUNC_SHIFT), &
                int(off, c_int64_t)))
  end function pcie_cfg_offset

  function pcie_cfg_read32(bus, dev, fn, off) result(v) &
       bind(c, name="pcie_cfg_read32")
    implicit none
    integer(c_int32_t), intent(in), value :: bus, dev, fn, off
    integer(c_int32_t) :: v

    v = not(0_c_int32_t)
    if (win == 0_c_int64_t) return
    if (bus < bus_lo .or. bus > bus_hi) return
    if (dev < 0_c_int32_t .or. dev >= DEVS_PER_BUS) return
    if (fn < 0_c_int32_t .or. fn >= FNS_PER_DEV) return
    v = fk_readl(win + pcie_cfg_offset(bus, dev, fn, iand(off, not(3_c_int32_t))))
  end function pcie_cfg_read32

  ! A dword read and then a shift, never a narrower load.  ECAM permits word
  ! and byte accesses, but a device is only obliged to answer a dword one
  ! identically -- and tools/mmiocheck.sh refuses the narrow form anyway.
  function pcie_cfg_read16(bus, dev, fn, off) result(v) &
       bind(c, name="pcie_cfg_read16")
    implicit none
    integer(c_int32_t), intent(in), value :: bus, dev, fn, off
    integer(c_int32_t) :: v

    v = ibits(pcie_cfg_read32(bus, dev, fn, off), &
              8_c_int32_t * iand(off, 2_c_int32_t), 16_c_int32_t)
  end function pcie_cfg_read16

  function pcie_cfg_read8(bus, dev, fn, off) result(v) &
       bind(c, name="pcie_cfg_read8")
    implicit none
    integer(c_int32_t), intent(in), value :: bus, dev, fn, off
    integer(c_int32_t) :: v

    v = ibits(pcie_cfg_read32(bus, dev, fn, off), &
              8_c_int32_t * iand(off, 3_c_int32_t), 8_c_int32_t)
  end function pcie_cfg_read8

  subroutine record(bus, dev, fn, ven, dw2, hdr)
    implicit none
    integer(c_int32_t), intent(in) :: bus, dev, fn, ven, dw2, hdr

    n_seen = n_seen + 1_c_int32_t
    ! Counting past the array is deliberate: a list that stops at 64 and a
    ! machine that has exactly 64 devices look identical otherwise, and a
    ! truncated list that reads as complete is the failure this avoids.
    if (n_dev >= FK_PCIE_MAX_DEV) return
    d_bdf(n_dev) = ior(ior(shiftl(bus, 8), shiftl(dev, 3)), fn)
    d_ven(n_dev) = ibits(ven, 0_c_int32_t, 16_c_int32_t)
    d_did(n_dev) = ibits(ven, 16_c_int32_t, 16_c_int32_t)
    d_pif(n_dev) = ibits(dw2, 8_c_int32_t, 8_c_int32_t)
    d_sub(n_dev) = ibits(dw2, 16_c_int32_t, 8_c_int32_t)
    d_cls(n_dev) = ibits(dw2, 24_c_int32_t, 8_c_int32_t)
    d_hdr(n_dev) = ibits(hdr, FK_PCI_HDR_TYPE_POS, FK_PCI_HDR_TYPE_LEN)
    d_mfd(n_dev) = 0_c_int32_t
    if (btest(hdr, FK_PCI_HDR_TYPE_MFD_BIT)) d_mfd(n_dev) = 1_c_int32_t
    n_dev = n_dev + 1_c_int32_t
  end subroutine record

  ! Every bus the window declares, every device, every function.  Exhaustive
  ! over the declared range and therefore a superset of what a recursive walk
  ! down bridge secondary-bus numbers would reach -- so there is no recursion
  ! here, and none is missing.
  !
  ! FUNCTION 0 DECIDES.  If its header type has the multifunction bit clear,
  ! functions 1..7 are not probed: a single-function device is permitted to
  ! alias function 0 across all eight, and probing them reports one device
  ! eight times.
  function pcie_scan() result(found) bind(c, name="pcie_scan")
    implicit none
    integer(c_int32_t) :: found
    integer(c_int32_t) :: bus, dev, fn, ven, dw2, hdr, last_fn

    found  = 0_c_int32_t
    n_dev  = 0_c_int32_t
    n_seen = 0_c_int32_t
    if (pcie_ready() == 0_c_int32_t) return

    do bus = bus_lo, bus_hi
       do dev = 0_c_int32_t, DEVS_PER_BUS - 1_c_int32_t
          ven = pcie_cfg_read32(bus, dev, 0_c_int32_t, OFF_VENDOR)
          if (ibits(ven, 0_c_int32_t, 16_c_int32_t) == FK_PCIE_ABSENT) cycle
          hdr = pcie_cfg_read8(bus, dev, 0_c_int32_t, OFF_HDRTYPE)
          dw2 = pcie_cfg_read32(bus, dev, 0_c_int32_t, OFF_REVCLASS)
          call record(bus, dev, 0_c_int32_t, ven, dw2, hdr)
          last_fn = 0_c_int32_t
          if (btest(hdr, FK_PCI_HDR_TYPE_MFD_BIT)) last_fn = FNS_PER_DEV - 1_c_int32_t
          do fn = 1_c_int32_t, last_fn
             ven = pcie_cfg_read32(bus, dev, fn, OFF_VENDOR)
             if (ibits(ven, 0_c_int32_t, 16_c_int32_t) == FK_PCIE_ABSENT) cycle
             hdr = pcie_cfg_read8(bus, dev, fn, OFF_HDRTYPE)
             dw2 = pcie_cfg_read32(bus, dev, fn, OFF_REVCLASS)
             call record(bus, dev, fn, ven, dw2, hdr)
          end do
       end do
    end do
    found = n_seen
  end function pcie_scan

  function pcie_count() result(n) bind(c, name="pcie_count")
    implicit none
    integer(c_int32_t) :: n

    n = n_dev
  end function pcie_count

  ! What the walk SAW, which is not what it kept if the machine has more
  ! functions than the table holds.
  function pcie_seen() result(n) bind(c, name="pcie_seen")
    implicit none
    integer(c_int32_t) :: n

    n = n_seen
  end function pcie_seen

  function pcie_overflowed() result(r) bind(c, name="pcie_overflowed")
    implicit none
    integer(c_int32_t) :: r

    r = 0_c_int32_t
    if (n_seen > n_dev) r = 1_c_int32_t
  end function pcie_overflowed

  function pcie_bdf(i) result(v) bind(c, name="pcie_bdf")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (i < 0_c_int32_t .or. i >= n_dev) return
    v = d_bdf(i)
  end function pcie_bdf

  function pcie_bus(i) result(v) bind(c, name="pcie_bus")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = ibits(pcie_bdf(i), 8_c_int32_t, 8_c_int32_t)
  end function pcie_bus

  function pcie_device(i) result(v) bind(c, name="pcie_device")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = ibits(pcie_bdf(i), 3_c_int32_t, 5_c_int32_t)
  end function pcie_device

  function pcie_function(i) result(v) bind(c, name="pcie_function")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = ibits(pcie_bdf(i), 0_c_int32_t, 3_c_int32_t)
  end function pcie_function

  function pcie_vendor(i) result(v) bind(c, name="pcie_vendor")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (i < 0_c_int32_t .or. i >= n_dev) return
    v = d_ven(i)
  end function pcie_vendor

  function pcie_devid(i) result(v) bind(c, name="pcie_devid")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (i < 0_c_int32_t .or. i >= n_dev) return
    v = d_did(i)
  end function pcie_devid

  function pcie_class(i) result(v) bind(c, name="pcie_class")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (i < 0_c_int32_t .or. i >= n_dev) return
    v = d_cls(i)
  end function pcie_class

  function pcie_subclass(i) result(v) bind(c, name="pcie_subclass")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (i < 0_c_int32_t .or. i >= n_dev) return
    v = d_sub(i)
  end function pcie_subclass

  function pcie_progif(i) result(v) bind(c, name="pcie_progif")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (i < 0_c_int32_t .or. i >= n_dev) return
    v = d_pif(i)
  end function pcie_progif

  ! The type WITHOUT the multifunction bit: bit 7 says how many functions the
  ! device has and says nothing about what kind of header this one is.
  function pcie_header_type(i) result(v) bind(c, name="pcie_header_type")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (i < 0_c_int32_t .or. i >= n_dev) return
    v = d_hdr(i)
  end function pcie_header_type

  function pcie_multifunction(i) result(v) bind(c, name="pcie_multifunction")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (i < 0_c_int32_t .or. i >= n_dev) return
    v = d_mfd(i)
  end function pcie_multifunction

  ! The index of the first match, or FK_PCIE_NOT_FOUND.  This is what 5.1 and
  ! 5.3 will call.
  function pcie_find_class(cls, sub, pif) result(i) &
       bind(c, name="pcie_find_class")
    implicit none
    integer(c_int32_t), intent(in), value :: cls, sub, pif
    integer(c_int32_t) :: i, k

    i = FK_PCIE_NOT_FOUND
    do k = 0_c_int32_t, n_dev - 1_c_int32_t
       if (d_cls(k) /= cls) cycle
       if (d_sub(k) /= sub) cycle
       if (d_pif(k) /= pif) cycle
       i = k
       return
    end do
  end function pcie_find_class

  function pcie_find_xhci() result(i) bind(c, name="pcie_find_xhci")
    implicit none
    integer(c_int32_t) :: i

    i = pcie_find_class(int(FK_PCI_XHCI_CLASS, c_int32_t), &
                        int(FK_PCI_XHCI_SUBCLASS, c_int32_t), &
                        int(FK_PCI_XHCI_PROGIF, c_int32_t))
  end function pcie_find_xhci

  function pcie_find_nvme() result(i) bind(c, name="pcie_find_nvme")
    implicit none
    integer(c_int32_t) :: i

    i = pcie_find_class(int(FK_PCI_NVME_CLASS, c_int32_t), &
                        int(FK_PCI_NVME_SUBCLASS, c_int32_t), &
                        int(FK_PCI_NVME_PROGIF, c_int32_t))
  end function pcie_find_nvme

end module fk_pcie_m
