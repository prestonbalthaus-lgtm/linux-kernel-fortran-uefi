! SPDX-License-Identifier: GPL-2.0
! NVM Express controller registers and queue entries.  NVM Express Base
! Specification 2.0 section 3.1; the 1.4 register set is the baseline, CRTO
! (0x68) is the 2.0 addition.  All fields little-endian.
!
! ACCESS WIDTH: each register is accessed at its declared width and natural
! alignment only -- no byte or 16-bit access to a 32-bit register.  CAP, ASQ,
! ACQ, BPMBL and CMBMSC are 64-bit: one aligned 64-bit access, or two 32-bit
! halves low first (pci.c:2391,3220).  Doorbells 32-bit only.
!
! fk_nvme_regs_t and fk_nvme_pmr_t overlay MMIO: the driver that maps them
! must declare its pointer VOLATILE.  Queue entries are host DRAM, not MMIO.
!
! Bit fields are POS (0-based lsb) + LEN for ibits(reg, POS, LEN); single bits
! are _BIT indices for btest/ibset.  No masks.  POS is relative to the whole
! named register unless a comment on the group says otherwise.
!
! Offsets cross-checked against vendor/linux-7.1.8/include/linux/nvme.h
! lines 132-275, 956-959, 1074-1098, 1306-1335, 2252-2265.  Citations below
! name upstream files by basename: nvme.h is include/linux/nvme.h, pci.c is
! drivers/nvme/host/pci.c, core.c is drivers/nvme/host/core.c and pci-epf.c is
! drivers/nvme/target/pci-epf.c, all under vendor/linux-7.1.8/.
module fk_nvme_types_m
  use, intrinsic :: iso_c_binding, only: c_int8_t, c_int16_t, c_int32_t, &
                                         c_int64_t
  implicit none
  private
  public :: fk_nvme_regs_t, fk_nvme_pmr_t, fk_nvme_sqe_t, fk_nvme_cqe_t

  public :: FK_NVME_PMR_BASE, FK_NVME_DB_BASE, FK_NVME_DB_STRIDE, &
            FK_NVME_DB_PAIR, FK_NVME_DB_SQ, FK_NVME_DB_CQ

  public :: FK_NVME_CAP_MQES_POS, FK_NVME_CAP_MQES_LEN, FK_NVME_CAP_CQR_BIT, &
            FK_NVME_CAP_AMS_POS, FK_NVME_CAP_AMS_LEN, &
            FK_NVME_CAP_TO_POS, FK_NVME_CAP_TO_LEN, &
            FK_NVME_CAP_DSTRD_POS, FK_NVME_CAP_DSTRD_LEN, &
            FK_NVME_CAP_NSSRS_BIT, FK_NVME_CAP_CSS_POS, FK_NVME_CAP_CSS_LEN, &
            FK_NVME_CAP_BPS_BIT, FK_NVME_CAP_CPS_POS, FK_NVME_CAP_CPS_LEN, &
            FK_NVME_CAP_MPSMIN_POS, FK_NVME_CAP_MPSMIN_LEN, &
            FK_NVME_CAP_MPSMAX_POS, FK_NVME_CAP_MPSMAX_LEN, &
            FK_NVME_CAP_PMRS_BIT, FK_NVME_CAP_CMBS_BIT, FK_NVME_CAP_NSSS_BIT, &
            FK_NVME_CAP_CRWMS_BIT, FK_NVME_CAP_CRIMS_BIT, &
            FK_NVME_CAP_CSS_NVM_BIT, FK_NVME_CAP_CSS_CSI_BIT

  public :: FK_NVME_CC_EN_BIT, FK_NVME_CC_CSS_POS, FK_NVME_CC_CSS_LEN, &
            FK_NVME_CC_MPS_POS, FK_NVME_CC_MPS_LEN, &
            FK_NVME_CC_AMS_POS, FK_NVME_CC_AMS_LEN, &
            FK_NVME_CC_SHN_POS, FK_NVME_CC_SHN_LEN, &
            FK_NVME_CC_IOSQES_POS, FK_NVME_CC_IOSQES_LEN, &
            FK_NVME_CC_IOCQES_POS, FK_NVME_CC_IOCQES_LEN, &
            FK_NVME_CC_CRIME_BIT, FK_NVME_CC_CSS_NVM, FK_NVME_CC_CSS_CSI, &
            FK_NVME_CC_SHN_NONE, FK_NVME_CC_SHN_NORMAL, &
            FK_NVME_CC_SHN_ABRUPT, FK_NVME_CC_IOSQES_NVM, FK_NVME_CC_IOCQES_NVM

  public :: FK_NVME_CSTS_RDY_BIT, FK_NVME_CSTS_CFS_BIT, &
            FK_NVME_CSTS_SHST_POS, FK_NVME_CSTS_SHST_LEN, &
            FK_NVME_CSTS_NSSRO_BIT, FK_NVME_CSTS_PP_BIT, FK_NVME_CSTS_ST_BIT, &
            FK_NVME_CSTS_SHST_NORMAL, FK_NVME_CSTS_SHST_OCCUR, &
            FK_NVME_CSTS_SHST_CMPLT

  public :: FK_NVME_AQA_ASQS_POS, FK_NVME_AQA_ASQS_LEN, &
            FK_NVME_AQA_ACQS_POS, FK_NVME_AQA_ACQS_LEN

  public :: FK_NVME_SQE_CDW0_OPC_POS, FK_NVME_SQE_CDW0_OPC_LEN, &
            FK_NVME_SQE_CDW0_FUSE_POS, FK_NVME_SQE_CDW0_FUSE_LEN, &
            FK_NVME_SQE_CDW0_PSDT_POS, FK_NVME_SQE_CDW0_PSDT_LEN, &
            FK_NVME_SQE_CDW0_CID_POS, FK_NVME_SQE_CDW0_CID_LEN, &
            FK_NVME_SQE_FLAGS_FUSE_POS, FK_NVME_SQE_FLAGS_FUSE_LEN, &
            FK_NVME_SQE_FLAGS_PSDT_POS, FK_NVME_SQE_FLAGS_PSDT_LEN

  public :: FK_NVME_CQE_STATUS_P_BIT, &
            FK_NVME_CQE_STATUS_SC_POS, FK_NVME_CQE_STATUS_SC_LEN, &
            FK_NVME_CQE_STATUS_SCT_POS, FK_NVME_CQE_STATUS_SCT_LEN, &
            FK_NVME_CQE_STATUS_CRD_POS, FK_NVME_CQE_STATUS_CRD_LEN, &
            FK_NVME_CQE_STATUS_M_BIT, FK_NVME_CQE_STATUS_DNR_BIT

  public :: FK_NVME_ADMIN_DELETE_SQ, FK_NVME_ADMIN_CREATE_SQ, &
            FK_NVME_ADMIN_DELETE_CQ, FK_NVME_ADMIN_CREATE_CQ, &
            FK_NVME_ADMIN_IDENTIFY, FK_NVME_ADMIN_SET_FEATURES, &
            FK_NVME_IO_FLUSH, FK_NVME_IO_WRITE, FK_NVME_IO_READ

  ! roadmap 5.3
  public :: FK_NVME_REG_CAP_OFF, FK_NVME_REG_VS_OFF, FK_NVME_REG_INTMS_OFF, &
            FK_NVME_REG_INTMC_OFF, FK_NVME_REG_CC_OFF, FK_NVME_REG_CSTS_OFF, &
            FK_NVME_REG_AQA_OFF, FK_NVME_REG_ASQ_OFF, FK_NVME_REG_ACQ_OFF
  public :: FK_NVME_SQE_BYTES, FK_NVME_CQE_BYTES, FK_NVME_QUEUE_ALIGN
  public :: FK_NVME_ID_CNS_NS, FK_NVME_ID_CNS_CTRL
  public :: FK_NVME_Q_PHYS_CONTIG_BIT, FK_NVME_CQ_IRQ_ENABLED_BIT
  public :: FK_NVME_CQID_POS, FK_NVME_CQID_LEN, FK_NVME_QSIZE_POS, &
            FK_NVME_QSIZE_LEN, FK_NVME_QFLAGS_POS, FK_NVME_QFLAGS_LEN, &
            FK_NVME_IV_POS, FK_NVME_IV_LEN, FK_NVME_SQ_CQID_POS, &
            FK_NVME_SQ_CQID_LEN
  public :: FK_NVME_RW_NLB_POS, FK_NVME_RW_NLB_LEN
  public :: FK_NVME_IDNS_NSZE_OFF, FK_NVME_IDNS_NLBAF_OFF, &
            FK_NVME_IDNS_FLBAS_OFF, FK_NVME_IDNS_LBAF_OFF, &
            FK_NVME_LBAF_BYTES, FK_NVME_LBAF_DS_OFF, &
            FK_NVME_FLBAS_IDX_POS, FK_NVME_FLBAS_IDX_LEN

  ! Byte offsets from BAR0.  nvme.h:132-163.
  integer(c_int32_t), parameter :: FK_NVME_PMR_BASE = int(z'0E00', c_int32_t)
  integer(c_int32_t), parameter :: FK_NVME_DB_BASE = int(z'1000', c_int32_t)
  ! Doorbells are an array, not a struct: stride bytes =
  ! ishft(FK_NVME_DB_STRIDE, CAP.DSTRD), SQ y tail at FK_NVME_DB_BASE +
  ! (FK_NVME_DB_PAIR*y + FK_NVME_DB_SQ)*stride, CQ y head with FK_NVME_DB_CQ.
  ! pci.c:346-354, 3224-3225.
  integer(c_int32_t), parameter :: FK_NVME_DB_STRIDE = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_DB_PAIR = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_DB_SQ = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_DB_CQ = 1_c_int32_t

  ! Controller registers, BAR0 offset 0.  nvme.h:131-163.
  type, bind(c) :: fk_nvme_regs_t
    integer(c_int64_t) :: cap
    integer(c_int32_t) :: vs
    integer(c_int32_t) :: intms
    integer(c_int32_t) :: intmc
    integer(c_int32_t) :: cc
    ! 0x18 is reserved; it is what puts csts at 0x1c and not at 0x18.
    integer(c_int32_t) :: rsvd_18
    integer(c_int32_t) :: csts
    integer(c_int32_t) :: nssr
    integer(c_int32_t) :: aqa
    integer(c_int64_t) :: asq
    integer(c_int64_t) :: acq
    integer(c_int32_t) :: cmbloc
    integer(c_int32_t) :: cmbsz
    integer(c_int32_t) :: bpinfo
    integer(c_int32_t) :: bprsel
    integer(c_int64_t) :: bpmbl
    integer(c_int64_t) :: cmbmsc
    ! cmbsts 0x58, cmbebs 0x5c, cmbswtp 0x60, nssd 0x64: NVMe 2.0 section 3.1.3,
    ! absent from nvme.h, which brackets them with cmbmsc 0x50 and crto 0x68.
    integer(c_int32_t) :: cmbsts
    integer(c_int32_t) :: cmbebs
    integer(c_int32_t) :: cmbswtp
    integer(c_int32_t) :: nssd
    integer(c_int32_t) :: crto
    ! Tail pad to alignment 8.  0x6c up to FK_NVME_PMR_BASE is all reserved.
    integer(c_int32_t) :: rsvd_6c
  end type fk_nvme_regs_t   ! 0x70

  ! Persistent memory region block; offsets are relative to FK_NVME_PMR_BASE.
  ! nvme.h:153-162 through pmrswtp, pmrmscl/pmrmscu from NVMe 2.0 section 3.1.3.
  type, bind(c) :: fk_nvme_pmr_t
    integer(c_int32_t) :: pmrcap
    integer(c_int32_t) :: pmrctl
    integer(c_int32_t) :: pmrsts
    integer(c_int32_t) :: pmrebs
    integer(c_int32_t) :: pmrswtp
    integer(c_int32_t) :: pmrmscl
    integer(c_int32_t) :: pmrmscu
  end type fk_nvme_pmr_t   ! 0x1c

  ! Submission queue entry.  nvme.h:1082-1098.  cdw carries the specification's
  ! own dword numbering as its bounds, so cdw(12) is CDW12.
  type, bind(c) :: fk_nvme_sqe_t
    integer(c_int8_t)  :: opcode
    integer(c_int8_t)  :: flags
    integer(c_int16_t) :: command_id
    integer(c_int32_t) :: nsid
    integer(c_int32_t) :: cdw2
    integer(c_int32_t) :: cdw3
    ! metadata 0x10, prp1 0x18, prp2 0x20: all three 64-bit and 8-aligned.
    integer(c_int64_t) :: metadata
    integer(c_int64_t) :: prp1
    integer(c_int64_t) :: prp2
    integer(c_int32_t) :: cdw(10:15)
  end type fk_nvme_sqe_t   ! 0x40

  ! Completion queue entry.  nvme.h:2252-2265.  res is the widest arm of the
  ! result union, 8 bytes at offset 0.
  type, bind(c) :: fk_nvme_cqe_t
    integer(c_int64_t) :: res
    integer(c_int16_t) :: sq_head
    integer(c_int16_t) :: sq_id
    integer(c_int16_t) :: command_id
    integer(c_int16_t) :: status
  end type fk_nvme_cqe_t   ! 0x10

  ! CAP at 0x00.  nvme.h:165-172, 265-275; pci-epf.c:1997-2012.
  ! MQES is a 0-based count: usable entries = MQES + 1.
  integer(c_int32_t), parameter :: FK_NVME_CAP_MQES_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_MQES_LEN = 16_c_int32_t
  ! CQR 16, AMS 18:17, BPS 45, CPS 47:46, PMRS 56 and NSSS 58 are NVMe 2.0
  ! section 3.1.3 only; nvme.h names none.
  integer(c_int32_t), parameter :: FK_NVME_CAP_CQR_BIT = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_AMS_POS = 17_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_AMS_LEN = 2_c_int32_t
  ! TO is in units of 500 ms (core.c:2753, 2783 halves it to seconds).
  integer(c_int32_t), parameter :: FK_NVME_CAP_TO_POS = 24_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_TO_LEN = 8_c_int32_t
  ! DSTRD is a shift: doorbell stride bytes = ishft(4, DSTRD).
  integer(c_int32_t), parameter :: FK_NVME_CAP_DSTRD_POS = 32_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_DSTRD_LEN = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_NSSRS_BIT = 36_c_int32_t
  ! CSS is a bitmap of supported I/O sets, one bit per set.
  integer(c_int32_t), parameter :: FK_NVME_CAP_CSS_POS = 37_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_CSS_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_BPS_BIT = 45_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_CPS_POS = 46_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_CPS_LEN = 2_c_int32_t
  ! MPSMIN/MPSMAX are shifts: page bytes = 2**(12 + value).  core.c:2719.
  integer(c_int32_t), parameter :: FK_NVME_CAP_MPSMIN_POS = 48_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_MPSMIN_LEN = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_MPSMAX_POS = 52_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_MPSMAX_LEN = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_PMRS_BIT = 56_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_CMBS_BIT = 57_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_NSSS_BIT = 58_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_CRWMS_BIT = 59_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_CRIMS_BIT = 60_c_int32_t

  ! Positions WITHIN the 8-bit CAP.CSS field, not within CAP.  nvme.h:269-270.
  integer(c_int32_t), parameter :: FK_NVME_CAP_CSS_NVM_BIT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CAP_CSS_CSI_BIT = 6_c_int32_t

  ! CC at 0x14.  nvme.h:205-249.
  integer(c_int32_t), parameter :: FK_NVME_CC_EN_BIT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CC_CSS_POS = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CC_CSS_LEN = 3_c_int32_t
  ! MPS is a shift: host page bytes = 2**(12 + MPS).
  integer(c_int32_t), parameter :: FK_NVME_CC_MPS_POS = 7_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CC_MPS_LEN = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CC_AMS_POS = 11_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CC_AMS_LEN = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CC_SHN_POS = 14_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CC_SHN_LEN = 2_c_int32_t
  ! IOSQES/IOCQES are exponents: queue entry bytes = 2**value.
  integer(c_int32_t), parameter :: FK_NVME_CC_IOSQES_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CC_IOSQES_LEN = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CC_IOCQES_POS = 20_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CC_IOCQES_LEN = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CC_CRIME_BIT = 24_c_int32_t

  ! Unshifted field values for the CC groups above.  nvme.h:199-200, 215-216,
  ! 232-234.  2**6 = 0x40 = fk_nvme_sqe_t, 2**4 = 0x10 = fk_nvme_cqe_t.
  integer(c_int32_t), parameter :: FK_NVME_CC_CSS_NVM = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CC_CSS_CSI = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CC_SHN_NONE = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CC_SHN_NORMAL = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CC_SHN_ABRUPT = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CC_IOSQES_NVM = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CC_IOCQES_NVM = 4_c_int32_t

  ! CSTS at 0x1c.  nvme.h:251-260.
  integer(c_int32_t), parameter :: FK_NVME_CSTS_RDY_BIT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CSTS_CFS_BIT = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CSTS_SHST_POS = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CSTS_SHST_LEN = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CSTS_NSSRO_BIT = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CSTS_PP_BIT = 5_c_int32_t
  ! ST bit 6 is NVMe 2.0 section 3.1.3.6 only; nvme.h's CSTS enum stops at PP.
  integer(c_int32_t), parameter :: FK_NVME_CSTS_ST_BIT = 6_c_int32_t
  ! Unshifted SHST values.
  integer(c_int32_t), parameter :: FK_NVME_CSTS_SHST_NORMAL = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CSTS_SHST_OCCUR = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CSTS_SHST_CMPLT = 2_c_int32_t

  ! AQA at 0x24.  ASQS and ACQS are both 0-based counts: the value written is
  ! queue depth - 1 (pci.c:2387-2390).  NVMe 2.0 section 3.1.3.9.
  integer(c_int32_t), parameter :: FK_NVME_AQA_ASQS_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_AQA_ASQS_LEN = 12_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_AQA_ACQS_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_AQA_ACQS_LEN = 12_c_int32_t

  ! Submission entry dword 0 taken as ONE 32-bit dword (NVMe 2.0 section
  ! 3.3.3.1); fk_nvme_sqe_t splits it into opcode byte 0, flags byte 1,
  ! command_id 2-3.
  integer(c_int32_t), parameter :: FK_NVME_SQE_CDW0_OPC_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_SQE_CDW0_OPC_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_SQE_CDW0_FUSE_POS = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_SQE_CDW0_FUSE_LEN = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_SQE_CDW0_PSDT_POS = 14_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_SQE_CDW0_PSDT_LEN = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_SQE_CDW0_CID_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_SQE_CDW0_CID_LEN = 16_c_int32_t

  ! The same two fields relative to the 8-bit flags component, which is what
  ! fk_nvme_sqe_t exposes: dword-0 position minus 8.  nvme.h:1074-1079.
  integer(c_int32_t), parameter :: FK_NVME_SQE_FLAGS_FUSE_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_SQE_FLAGS_FUSE_LEN = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_SQE_FLAGS_PSDT_POS = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_SQE_FLAGS_PSDT_LEN = 2_c_int32_t

  ! Completion entry status, relative to the 16-bit status component, which is
  ! the spec's dword 3 bits 31:16 -- subtract 16 from dword-3 numbering.  The
  ! phase tag is bit 0 of the component (pci.c:1543); nvme.h:2241-2247 states
  ! the rest against status shifted right by 1, which agrees with these.
  integer(c_int32_t), parameter :: FK_NVME_CQE_STATUS_P_BIT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CQE_STATUS_SC_POS = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CQE_STATUS_SC_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CQE_STATUS_SCT_POS = 9_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CQE_STATUS_SCT_LEN = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CQE_STATUS_CRD_POS = 12_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CQE_STATUS_CRD_LEN = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CQE_STATUS_M_BIT = 14_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CQE_STATUS_DNR_BIT = 15_c_int32_t

  ! Admin opcodes, for fk_nvme_sqe_t%opcode.  nvme.h:1306-1335.
  integer(c_int8_t), parameter :: FK_NVME_ADMIN_DELETE_SQ = int(z'00', c_int8_t)
  integer(c_int8_t), parameter :: FK_NVME_ADMIN_CREATE_SQ = int(z'01', c_int8_t)
  integer(c_int8_t), parameter :: FK_NVME_ADMIN_DELETE_CQ = int(z'04', c_int8_t)
  integer(c_int8_t), parameter :: FK_NVME_ADMIN_CREATE_CQ = int(z'05', c_int8_t)
  integer(c_int8_t), parameter :: FK_NVME_ADMIN_IDENTIFY = int(z'06', c_int8_t)
  integer(c_int8_t), parameter :: FK_NVME_ADMIN_SET_FEATURES = int(z'09', c_int8_t)

  ! NVM I/O opcodes.  nvme.h:956-959.
  integer(c_int8_t), parameter :: FK_NVME_IO_FLUSH = int(z'00', c_int8_t)
  integer(c_int8_t), parameter :: FK_NVME_IO_WRITE = int(z'01', c_int8_t)
  integer(c_int8_t), parameter :: FK_NVME_IO_READ = int(z'02', c_int8_t)

  ! ---- byte offsets of the registers the driver actually touches (5.3) ------
  ! The type above describes the block; nothing may reach a device register
  ! through a Fortran pointer, so the offsets have to exist as numbers too --
  ! the same reason fk_xhci_types gives.
  integer(c_int32_t), parameter :: FK_NVME_REG_CAP_OFF   = int(z'00', c_int32_t)
  integer(c_int32_t), parameter :: FK_NVME_REG_VS_OFF    = int(z'08', c_int32_t)
  integer(c_int32_t), parameter :: FK_NVME_REG_INTMS_OFF = int(z'0C', c_int32_t)
  integer(c_int32_t), parameter :: FK_NVME_REG_INTMC_OFF = int(z'10', c_int32_t)
  integer(c_int32_t), parameter :: FK_NVME_REG_CC_OFF    = int(z'14', c_int32_t)
  ! 0x18 is reserved.  CSTS is at 0x1C and a driver that assumes the registers
  ! are contiguous reads the reserved dword instead and never sees RDY.
  integer(c_int32_t), parameter :: FK_NVME_REG_CSTS_OFF  = int(z'1C', c_int32_t)
  integer(c_int32_t), parameter :: FK_NVME_REG_AQA_OFF   = int(z'24', c_int32_t)
  integer(c_int32_t), parameter :: FK_NVME_REG_ASQ_OFF   = int(z'28', c_int32_t)
  integer(c_int32_t), parameter :: FK_NVME_REG_ACQ_OFF   = int(z'30', c_int32_t)

  ! CC.IOSQES and CC.IOCQES are the log2 of these, and the pair is what makes
  ! the controller's stride agree with the driver's.
  integer(c_int32_t), parameter :: FK_NVME_SQE_BYTES = 64_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CQE_BYTES = 16_c_int32_t
  ! A queue base is a PRP: page aligned, and its low twelve bits are reserved.
  integer(c_int32_t), parameter :: FK_NVME_QUEUE_ALIGN = 4096_c_int32_t

  ! Identify CNS, CDW10 bits 7:0.  nvme.h:561-562.
  integer(c_int32_t), parameter :: FK_NVME_ID_CNS_NS = int(z'00', c_int32_t)
  integer(c_int32_t), parameter :: FK_NVME_ID_CNS_CTRL = int(z'01', c_int32_t)

  ! Create CQ / Create SQ queue flags, nvme.h:1369-1374.  PHYS_CONTIG is not
  ! optional when CAP.CQR is set, which it is on every controller this has met.
  integer(c_int32_t), parameter :: FK_NVME_Q_PHYS_CONTIG_BIT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CQ_IRQ_ENABLED_BIT = 1_c_int32_t

  ! Create CQ: CDW10 is qsize:cqid, CDW11 is irq_vector:cq_flags.
  ! Create SQ: CDW10 is qsize:sqid, CDW11 is cqid:sq_flags.
  ! Upstream spells both as four __le16 in struct nvme_create_cq/sq
  ! (nvme.h:1306-1335); here they are fields of the generic cdw array, so the
  ! positions are written out.  QSIZE IS ZERO-BASED -- a queue of n entries
  ! puts n-1 here, and putting n asks for one more entry than the memory holds.
  integer(c_int32_t), parameter :: FK_NVME_CQID_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_CQID_LEN = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_QSIZE_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_QSIZE_LEN = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_QFLAGS_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_QFLAGS_LEN = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_IV_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_IV_LEN = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_SQ_CQID_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_SQ_CQID_LEN = 16_c_int32_t

  ! Read/Write: SLBA is the 64 bits at CDW10/11 and NLB is CDW12 15:0.
  ! NLB IS ZERO-BASED: 0 is one block.  Writing the block count there reads one
  ! block too many, which on a disk whose next sector differs is visible and on
  ! one whose next sector is zeros is not.
  integer(c_int32_t), parameter :: FK_NVME_RW_NLB_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_RW_NLB_LEN = 16_c_int32_t

  ! Identify Namespace, byte offsets into the 4096-byte result.  nvme.h's
  ! struct nvme_id_ns: nsze at 0, nlbaf at 25, flbas at 26, lbaf[] at 128.
  ! Each LBA format is four bytes (ms, ds, rp) and DS IS AN EXPONENT: the block
  ! size is 2**ds bytes.
  integer(c_int32_t), parameter :: FK_NVME_IDNS_NSZE_OFF = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_IDNS_NLBAF_OFF = 25_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_IDNS_FLBAS_OFF = 26_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_IDNS_LBAF_OFF = 128_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_LBAF_BYTES = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_LBAF_DS_OFF = 2_c_int32_t
  ! FLBAS bits 3:0 index lbaf[].  Bits 6:4 extend it above 16 formats, which
  ! nothing this driver has met uses; the low nibble is taken and the guard is
  ! that nlbaf bounds it.
  integer(c_int32_t), parameter :: FK_NVME_FLBAS_IDX_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_FLBAS_IDX_LEN = 4_c_int32_t

end module fk_nvme_types_m
