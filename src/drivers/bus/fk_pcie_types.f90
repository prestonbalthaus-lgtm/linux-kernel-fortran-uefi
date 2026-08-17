! SPDX-License-Identifier: GPL-2.0
! PCI/PCIe configuration space: Type 0 and Type 1 headers, capability list,
! MSI-X.  Layout from PCI Local Bus 3.0 chapter 6 and PCI Express Base 5.0
! chapter 7.
!
! ACCESS WIDTH: legacy CF8/CFC configuration access is DWORD-ONLY -- a driver on
! that path reads FK_PCI_HDR_DWORDS dwords and transfer()s them into the type.
! ECAM (memory-mapped) permits byte, word and dword accesses; the c_int8_t and
! c_int16_t components exist for that path and must not be touched from CF8/CFC.
!
! An ECAM window or an MSI-X table overlay is MMIO: the driver that maps one
! declares its pointer VOLATILE.  Nothing here is volatile on its own.
!
! NAMING: every symbol keeps the FK_PCI_ prefix because the layout is PCI's
! configuration space, and the PCIe-only additions (ECAM addressing, extended
! capabilities) stay in that one namespace deliberately.
!
! All fields are little-endian; on x86-64 that is the native layout and needs
! no swap.  Bit fields are POS/LEN (least-significant bit, width) for ibits, or
! a single _BIT index for btest/ibset/ibclr.  No masks are emitted.  POS is
! relative to the named register, not to the containing dword, unless a comment
! on the group says otherwise.
!
! Every offset cross-checked against vendor/linux-7.1.8/include/uapi/linux/
! pci_regs.h, class codes against include/linux/pci_ids.h, ECAM shifts against
! include/linux/pci-ecam.h.
module fk_pcie_types_m
  use, intrinsic :: iso_c_binding, only: c_int8_t, c_int16_t, c_int32_t
  implicit none
  private
  public :: fk_pci_hdr0_t, fk_pci_hdr1_t, fk_pci_cap_hdr_t, &
            fk_pci_msix_cap_t, fk_pci_msix_entry_t

  public :: FK_PCI_BAR_COUNT, FK_PCI_HDR_BYTES, FK_PCI_HDR_DWORDS
  public :: FK_PCI_VENDOR_INVALID

  public :: FK_PCI_HDR_TYPE_POS, FK_PCI_HDR_TYPE_LEN, FK_PCI_HDR_TYPE_MFD_BIT
  public :: FK_PCI_HDR_TYPE_NORMAL, FK_PCI_HDR_TYPE_BRIDGE, &
            FK_PCI_HDR_TYPE_CARDBUS

  public :: FK_PCI_CMD_IO_BIT, FK_PCI_CMD_MEMORY_BIT, FK_PCI_CMD_MASTER_BIT, &
            FK_PCI_CMD_SPECIAL_BIT, FK_PCI_CMD_INVALIDATE_BIT, &
            FK_PCI_CMD_VGA_PALETTE_BIT, FK_PCI_CMD_PARITY_BIT, &
            FK_PCI_CMD_WAIT_BIT, FK_PCI_CMD_SERR_BIT, &
            FK_PCI_CMD_FAST_BACK_BIT, FK_PCI_CMD_INTX_DISABLE_BIT

  public :: FK_PCI_STATUS_IMM_READY_BIT, FK_PCI_STATUS_INTERRUPT_BIT, &
            FK_PCI_STATUS_CAP_LIST_BIT, FK_PCI_STATUS_66MHZ_BIT, &
            FK_PCI_STATUS_UDF_BIT, FK_PCI_STATUS_FAST_BACK_BIT, &
            FK_PCI_STATUS_PARITY_BIT, FK_PCI_STATUS_DEVSEL_POS, &
            FK_PCI_STATUS_DEVSEL_LEN, FK_PCI_STATUS_SIG_TARGET_ABORT_BIT, &
            FK_PCI_STATUS_REC_TARGET_ABORT_BIT, &
            FK_PCI_STATUS_REC_MASTER_ABORT_BIT, &
            FK_PCI_STATUS_SIG_SYSTEM_ERROR_BIT, &
            FK_PCI_STATUS_DETECTED_PARITY_BIT

  public :: FK_PCI_BAR_SPACE_BIT
  public :: FK_PCI_BAR_MEM_TYPE_POS, FK_PCI_BAR_MEM_TYPE_LEN, &
            FK_PCI_BAR_MEM_TYPE_32, FK_PCI_BAR_MEM_TYPE_1M, &
            FK_PCI_BAR_MEM_TYPE_64, FK_PCI_BAR_PREFETCH_BIT, &
            FK_PCI_BAR_MEM_ADDR_POS, FK_PCI_BAR_IO_ADDR_POS

  public :: FK_PCI_ROM_ENABLE_BIT, FK_PCI_ROM_ADDR_POS

  public :: FK_PCI_CAP_ID_MSI, FK_PCI_CAP_ID_EXP, FK_PCI_CAP_ID_MSIX

  public :: FK_PCI_CAP_PTR_POS, FK_PCI_CAP_PTR_LEN

  public :: FK_PCI_MSIX_CTRL_QSIZE_POS, FK_PCI_MSIX_CTRL_QSIZE_LEN, &
            FK_PCI_MSIX_CTRL_MASKALL_BIT, FK_PCI_MSIX_CTRL_ENABLE_BIT, &
            FK_PCI_MSIX_BIR_POS, FK_PCI_MSIX_BIR_LEN, FK_PCI_MSIX_OFFSET_POS

  public :: FK_PCI_MSIX_VCTRL_MASK_BIT, FK_PCI_MSIX_VCTRL_ST_POS, &
            FK_PCI_MSIX_VCTRL_ST_LEN, FK_PCI_MSIX_ENTRY_STRIDE

  public :: FK_PCI_EXT_CAP_BASE, FK_PCI_EXT_CAP_ID_POS, FK_PCI_EXT_CAP_ID_LEN, &
            FK_PCI_EXT_CAP_VER_POS, FK_PCI_EXT_CAP_VER_LEN, &
            FK_PCI_EXT_CAP_NEXT_POS, FK_PCI_EXT_CAP_NEXT_LEN

  public :: FK_PCI_ECAM_BUS_SHIFT, FK_PCI_ECAM_DEV_SHIFT, &
            FK_PCI_ECAM_FUNC_SHIFT, FK_PCI_ECAM_FUNC_BYTES

  public :: FK_PCI_XHCI_CLASS, FK_PCI_XHCI_SUBCLASS, FK_PCI_XHCI_PROGIF
  public :: FK_PCI_NVME_CLASS, FK_PCI_NVME_SUBCLASS, FK_PCI_NVME_PROGIF

  ! pci_regs.h:38-128.  class/subclass/prog_if are the three bytes of the
  ! 0x08 dword above the revision: prog_if 0x09, subclass 0x0a, class 0x0b.
  type, bind(c) :: fk_pci_hdr0_t
    integer(c_int16_t) :: vendor_id
    integer(c_int16_t) :: device_id
    integer(c_int16_t) :: command
    integer(c_int16_t) :: status
    integer(c_int8_t)  :: revision_id
    integer(c_int8_t)  :: prog_if
    integer(c_int8_t)  :: subclass
    integer(c_int8_t)  :: class_code
    integer(c_int8_t)  :: cache_line_size
    integer(c_int8_t)  :: latency_timer
    integer(c_int8_t)  :: header_type
    integer(c_int8_t)  :: bist
    integer(c_int32_t) :: bar(0:5)
    integer(c_int32_t) :: cardbus_cis
    integer(c_int16_t) :: subsystem_vendor_id
    integer(c_int16_t) :: subsystem_id
    integer(c_int32_t) :: rom_address
    integer(c_int8_t)  :: cap_ptr
    integer(c_int8_t)  :: rsvd_35(0:2)
    integer(c_int32_t) :: rsvd_38
    integer(c_int8_t)  :: interrupt_line
    integer(c_int8_t)  :: interrupt_pin
    integer(c_int8_t)  :: min_gnt
    integer(c_int8_t)  :: max_lat
  end type fk_pci_hdr0_t   ! 0x40

  ! pci_regs.h:130-173.  DIVERGENCE FROM TYPE 0: identical only through 0x0f.
  ! From 0x10 on there are two BARs, not six; 0x18-0x33 is the bridge window
  ! set; and the expansion ROM base moves from 0x30 to 0x38 (PCI_ROM_ADDRESS1,
  ! pci_regs.h:164), where Type 0 keeps a reserved dword.
  type, bind(c) :: fk_pci_hdr1_t
    integer(c_int16_t) :: vendor_id
    integer(c_int16_t) :: device_id
    integer(c_int16_t) :: command
    integer(c_int16_t) :: status
    integer(c_int8_t)  :: revision_id
    integer(c_int8_t)  :: prog_if
    integer(c_int8_t)  :: subclass
    integer(c_int8_t)  :: class_code
    integer(c_int8_t)  :: cache_line_size
    integer(c_int8_t)  :: latency_timer
    integer(c_int8_t)  :: header_type
    integer(c_int8_t)  :: bist
    integer(c_int32_t) :: bar(0:1)
    integer(c_int8_t)  :: primary_bus
    integer(c_int8_t)  :: secondary_bus
    integer(c_int8_t)  :: subordinate_bus
    integer(c_int8_t)  :: sec_latency_timer
    integer(c_int8_t)  :: io_base
    integer(c_int8_t)  :: io_limit
    integer(c_int16_t) :: sec_status
    integer(c_int16_t) :: memory_base
    integer(c_int16_t) :: memory_limit
    integer(c_int16_t) :: pref_memory_base
    integer(c_int16_t) :: pref_memory_limit
    integer(c_int32_t) :: pref_base_upper32
    integer(c_int32_t) :: pref_limit_upper32
    integer(c_int16_t) :: io_base_upper16
    integer(c_int16_t) :: io_limit_upper16
    integer(c_int8_t)  :: cap_ptr
    integer(c_int8_t)  :: rsvd_35(0:2)
    integer(c_int32_t) :: rom_address
    integer(c_int8_t)  :: interrupt_line
    integer(c_int8_t)  :: interrupt_pin
    integer(c_int16_t) :: bridge_control
  end type fk_pci_hdr1_t   ! 0x40

  ! pci_regs.h:218-241.  cap_next is a byte offset from the start of this
  ! function's configuration space, not from this capability.
  type, bind(c) :: fk_pci_cap_hdr_t
    integer(c_int8_t) :: cap_id
    integer(c_int8_t) :: cap_next
  end type fk_pci_cap_hdr_t   ! 0x02

  ! pci_regs.h:331-343 (PCI_CAP_MSIX_SIZEOF = 12).
  type, bind(c) :: fk_pci_msix_cap_t
    integer(c_int8_t)  :: cap_id
    integer(c_int8_t)  :: cap_next
    integer(c_int16_t) :: msg_control
    integer(c_int32_t) :: table
    integer(c_int32_t) :: pba
  end type fk_pci_msix_cap_t   ! 0x0c

  ! pci_regs.h:345-352.  Lives in device memory mapped by a BAR, not in
  ! configuration space: dword accesses, and the overlay must be VOLATILE.
  type, bind(c) :: fk_pci_msix_entry_t
    integer(c_int32_t) :: msg_addr_lo
    integer(c_int32_t) :: msg_addr_hi
    integer(c_int32_t) :: msg_data
    integer(c_int32_t) :: vector_ctrl
  end type fk_pci_msix_entry_t   ! 0x10

  ! pci_regs.h:36-37.
  integer(c_int32_t), parameter :: FK_PCI_HDR_BYTES = 64_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_HDR_DWORDS = 16_c_int32_t

  ! BARs in a Type 0 header.
  integer(c_int32_t), parameter :: FK_PCI_BAR_COUNT = 6_c_int32_t

  ! An absent function returns all-ones on every byte: drivers/pci/probe.c:2581
  ! (PCI_POSSIBLE_ERROR, include/linux/pci.h:172-174), PCIe 5.0 section 2.3.2.
  ! No #define in pci_regs.h names it; the bit pattern is 0xFFFF.
  integer(c_int16_t), parameter :: FK_PCI_VENDOR_INVALID = int(z'FFFF', c_int16_t)

  ! header_type, the 8-bit register at 0x0e.  pci_regs.h:78-83.  The
  ! multifunction flag is bit 7 beside the 7-bit type field, not inside it.
  integer(c_int32_t), parameter :: FK_PCI_HDR_TYPE_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_HDR_TYPE_LEN = 7_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_HDR_TYPE_MFD_BIT = 7_c_int32_t
  integer(c_int8_t), parameter :: FK_PCI_HDR_TYPE_NORMAL = 0_c_int8_t
  integer(c_int8_t), parameter :: FK_PCI_HDR_TYPE_BRIDGE = 1_c_int8_t
  integer(c_int8_t), parameter :: FK_PCI_HDR_TYPE_CARDBUS = 2_c_int8_t

  ! command, the 16-bit register at 0x04.  pci_regs.h:41-51.
  integer(c_int32_t), parameter :: FK_PCI_CMD_IO_BIT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_CMD_MEMORY_BIT = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_CMD_MASTER_BIT = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_CMD_SPECIAL_BIT = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_CMD_INVALIDATE_BIT = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_CMD_VGA_PALETTE_BIT = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_CMD_PARITY_BIT = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_CMD_WAIT_BIT = 7_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_CMD_SERR_BIT = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_CMD_FAST_BACK_BIT = 9_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_CMD_INTX_DISABLE_BIT = 10_c_int32_t

  ! status, the 16-bit register at 0x06.  pci_regs.h:54-69.  A CF8/CFC driver
  ! reads command and status as one dword at 0x04: add 16 to every position
  ! below before applying it to that dword.
  integer(c_int32_t), parameter :: FK_PCI_STATUS_IMM_READY_BIT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_STATUS_INTERRUPT_BIT = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_STATUS_CAP_LIST_BIT = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_STATUS_66MHZ_BIT = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_STATUS_UDF_BIT = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_STATUS_FAST_BACK_BIT = 7_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_STATUS_PARITY_BIT = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_STATUS_DEVSEL_POS = 9_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_STATUS_DEVSEL_LEN = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_STATUS_SIG_TARGET_ABORT_BIT = 11_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_STATUS_REC_TARGET_ABORT_BIT = 12_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_STATUS_REC_MASTER_ABORT_BIT = 13_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_STATUS_SIG_SYSTEM_ERROR_BIT = 14_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_STATUS_DETECTED_PARITY_BIT = 15_c_int32_t

  ! bar(n), a 32-bit register.  pci_regs.h:102-112.  _SPACE_BIT set is I/O
  ! space, clear is memory space (pci_regs.h:96-98).  _MEM_TYPE_* are the values
  ! of the two-bit field AFTER ibits, not the raw register encodings.
  integer(c_int32_t), parameter :: FK_PCI_BAR_SPACE_BIT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_BAR_MEM_TYPE_POS = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_BAR_MEM_TYPE_LEN = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_BAR_MEM_TYPE_32 = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_BAR_MEM_TYPE_1M = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_BAR_MEM_TYPE_64 = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_BAR_PREFETCH_BIT = 3_c_int32_t
  ! Where the base address itself starts: memory bits 31:4, I/O bits 31:2.
  integer(c_int32_t), parameter :: FK_PCI_BAR_MEM_ADDR_POS = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_BAR_IO_ADDR_POS = 2_c_int32_t

  ! rom_address, at 0x30 in Type 0 and 0x38 in Type 1.  pci_regs.h:118-120.
  integer(c_int32_t), parameter :: FK_PCI_ROM_ENABLE_BIT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_ROM_ADDR_POS = 11_c_int32_t

  ! pci_regs.h:223, 234-235.
  integer(c_int8_t), parameter :: FK_PCI_CAP_ID_MSI = int(z'05', c_int8_t)
  integer(c_int8_t), parameter :: FK_PCI_CAP_ID_EXP = int(z'10', c_int8_t)
  integer(c_int8_t), parameter :: FK_PCI_CAP_ID_MSIX = int(z'11', c_int8_t)

  ! cap_ptr and cap_next, 8-bit: bits 1:0 reserved, so the usable offset is
  ! bits 7:2 scaled by 4.  PCI 3.0 section 6.7.
  integer(c_int32_t), parameter :: FK_PCI_CAP_PTR_POS = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_CAP_PTR_LEN = 6_c_int32_t

  ! msg_control, the 16-bit field at offset 2 of fk_pci_msix_cap_t.
  ! pci_regs.h:332-341.  Table Size is encoded N-1.
  integer(c_int32_t), parameter :: FK_PCI_MSIX_CTRL_QSIZE_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_MSIX_CTRL_QSIZE_LEN = 11_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_MSIX_CTRL_MASKALL_BIT = 14_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_MSIX_CTRL_ENABLE_BIT = 15_c_int32_t
  ! table and pba, 32-bit each.  The offset field is bits 31:3 and is already
  ! the byte offset: it is not shifted, its low 3 bits read as zero.
  integer(c_int32_t), parameter :: FK_PCI_MSIX_BIR_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_MSIX_BIR_LEN = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_MSIX_OFFSET_POS = 3_c_int32_t

  ! vector_ctrl, the 32-bit field at offset 0x0c of a table entry.
  ! pci_regs.h:346-352.
  integer(c_int32_t), parameter :: FK_PCI_MSIX_VCTRL_MASK_BIT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_MSIX_VCTRL_ST_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_MSIX_VCTRL_ST_LEN = 16_c_int32_t

  ! MSI-X table stride, in bytes.
  integer(c_int32_t), parameter :: FK_PCI_MSIX_ENTRY_STRIDE = 16_c_int32_t

  ! Extended capabilities start where the 256-byte legacy space ends and are
  ! reachable only through ECAM.  pci_regs.h:29-30, 722-724.  The header is one
  ! dword; Linux additionally clears bits 1:0 of the next pointer, which the
  ! specification requires to be zero.
  integer(c_int32_t), parameter :: FK_PCI_EXT_CAP_BASE = 256_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_EXT_CAP_ID_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_EXT_CAP_ID_LEN = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_EXT_CAP_VER_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_EXT_CAP_VER_LEN = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_EXT_CAP_NEXT_POS = 20_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_EXT_CAP_NEXT_LEN = 12_c_int32_t

  ! ECAM address = window_base + ishft(bus,20) + ishft(dev,15) + ishft(fn,12)
  ! + offset.  PCIe 5.0 section 7.2.2 table 7-1.  pci-ecam.h:23-24 gives bus 20
  ! and devfn 12; devfn is dev*8+fn, so dev is 15 and fn is 12.
  integer(c_int32_t), parameter :: FK_PCI_ECAM_BUS_SHIFT = 20_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_ECAM_DEV_SHIFT = 15_c_int32_t
  integer(c_int32_t), parameter :: FK_PCI_ECAM_FUNC_SHIFT = 12_c_int32_t
  ! Bytes per function: 1 shifted left by FK_PCI_ECAM_FUNC_SHIFT.
  integer(c_int32_t), parameter :: FK_PCI_ECAM_FUNC_BYTES = 4096_c_int32_t

  ! pci_ids.h:123, PCI_CLASS_SERIAL_USB_XHCI = 0x0c0330.
  integer(c_int8_t), parameter :: FK_PCI_XHCI_CLASS = int(z'0C', c_int8_t)
  integer(c_int8_t), parameter :: FK_PCI_XHCI_SUBCLASS = int(z'03', c_int8_t)
  integer(c_int8_t), parameter :: FK_PCI_XHCI_PROGIF = int(z'30', c_int8_t)

  ! pci_ids.h:27, PCI_CLASS_STORAGE_EXPRESS = 0x010802.
  integer(c_int8_t), parameter :: FK_PCI_NVME_CLASS = int(z'01', c_int8_t)
  integer(c_int8_t), parameter :: FK_PCI_NVME_SUBCLASS = int(z'08', c_int8_t)
  integer(c_int8_t), parameter :: FK_PCI_NVME_PROGIF = int(z'02', c_int8_t)
end module fk_pcie_types_m
