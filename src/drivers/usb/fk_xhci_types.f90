! SPDX-License-Identifier: GPL-2.0
! xHCI host controller register blocks, TRBs and Event Ring Segment Table.
! eXtensible Host Controller Interface for USB, revision 1.2, chapters 5 and 6.
!
! ACCESS WIDTH: every register described here is read and written with 32-bit or
! wider accesses only (xHCI 1.2 section 5.1, and xhci.h:280-282 for the runtime
! block).  The one exception is the capability block, where CAPLENGTH is a byte
! at 0x00 and HCIVERSION a word at 0x02.  A 64-bit register may be issued as two
! dword accesses, low half first (xhci.h:20, io-64-nonatomic-lo-hi.h).
!
! VOLATILE: these types describe MMIO.  The driver that maps a block must declare
! its pointer target VOLATILE; nothing in this module implies it.
!
! ENDIAN: all register and TRB fields are little-endian (__le32/__le64 upstream);
! on x86-64 that is the native layout and needs no swap.
!
! BIT FIELDS: FK_..._POS and FK_..._LEN give a field least significant bit and
! width, for ibits(); FK_..._BIT gives a single flag index, for btest/ibset.
! No masks are emitted.  POS is relative to the whole register unless a comment
! on the group says otherwise.
!
! Offsets cross-checked against vendor/linux-7.1.8/drivers/usb/host/xhci.h,
! xhci-caps.h, xhci-port.h, xhci-ext-caps.h and xhci-ring.c.
module fk_xhci_types_m
  use, intrinsic :: iso_c_binding, only: c_int8_t, c_int16_t, c_int32_t, c_int64_t
  implicit none
  private

  public :: fk_xhci_cap_t, fk_xhci_op_t, fk_xhci_port_t
  public :: fk_xhci_rt_t, fk_xhci_intr_t, fk_xhci_erst_t
  public :: fk_xhci_trb_t, fk_xhci_trb_xfer_t, fk_xhci_trb_setup_t
  public :: fk_xhci_trb_link_t, fk_xhci_trb_xfer_event_t
  public :: fk_xhci_trb_cmd_event_t, fk_xhci_trb_psc_event_t

  public :: FK_XHCI_OP_PORT_BASE, FK_XHCI_PORT_STRIDE, FK_XHCI_RT_IR_BASE, &
            FK_XHCI_RT_IR_STRIDE, FK_XHCI_DB_STRIDE, FK_XHCI_HCCPARAMS1_OFF, &
            FK_XHCI_DBOFF_PTR_POS, FK_XHCI_RTSOFF_PTR_POS
  public :: FK_XHCI_CAP_LENGTH_OFF, FK_XHCI_CAP_HCS1_OFF, &
            FK_XHCI_CAP_HCS2_OFF, FK_XHCI_CAP_HCS3_OFF, &
            FK_XHCI_CAP_DBOFF_OFF, FK_XHCI_CAP_RTSOFF_OFF, &
            FK_XHCI_CAP_HCC2_OFF
  public :: FK_XHCI_OP_USBCMD_OFF, FK_XHCI_OP_USBSTS_OFF, &
            FK_XHCI_OP_PAGESIZE_OFF, FK_XHCI_OP_DNCTRL_OFF, &
            FK_XHCI_OP_CRCR_OFF, FK_XHCI_OP_DCBAAP_OFF, FK_XHCI_OP_CONFIG_OFF
  public :: FK_XHCI_IR_IMAN_OFF, FK_XHCI_IR_IMOD_OFF, FK_XHCI_IR_ERSTSZ_OFF, &
            FK_XHCI_IR_ERSTBA_OFF, FK_XHCI_IR_ERDP_OFF
  public :: FK_XHCI_TRB_SIZE, FK_XHCI_TRB_DWORDS, FK_XHCI_ERST_ENTRY_SIZE, &
            FK_XHCI_RING_ALIGN
  public :: FK_XHCI_MAX_SLOTS, FK_XHCI_MAX_PORTS, FK_XHCI_MAX_INTRS

  public :: FK_XHCI_CAPLENGTH_POS, FK_XHCI_CAPLENGTH_LEN, &
            FK_XHCI_HCIVERSION_POS, FK_XHCI_HCIVERSION_LEN
  public :: FK_XHCI_HCS1_MAX_SLOTS_POS, FK_XHCI_HCS1_MAX_SLOTS_LEN, &
            FK_XHCI_HCS1_MAX_INTRS_POS, FK_XHCI_HCS1_MAX_INTRS_LEN, &
            FK_XHCI_HCS1_MAX_PORTS_POS, FK_XHCI_HCS1_MAX_PORTS_LEN
  public :: FK_XHCI_HCS2_IST_VALUE_POS, FK_XHCI_HCS2_IST_VALUE_LEN, &
            FK_XHCI_HCS2_IST_UNIT_BIT, FK_XHCI_HCS2_ERST_MAX_POS, &
            FK_XHCI_HCS2_ERST_MAX_LEN, FK_XHCI_HCS2_MAX_SP_HI_POS, &
            FK_XHCI_HCS2_MAX_SP_HI_LEN, FK_XHCI_HCS2_SPR_BIT, &
            FK_XHCI_HCS2_MAX_SP_LO_POS, FK_XHCI_HCS2_MAX_SP_LO_LEN
  public :: FK_XHCI_HCS3_U1_LATENCY_POS, FK_XHCI_HCS3_U1_LATENCY_LEN, &
            FK_XHCI_HCS3_U2_LATENCY_POS, FK_XHCI_HCS3_U2_LATENCY_LEN
  public :: FK_XHCI_HCC1_AC64_BIT, FK_XHCI_HCC1_BNC_BIT, FK_XHCI_HCC1_CSZ_BIT, &
            FK_XHCI_HCC1_PPC_BIT, FK_XHCI_HCC1_PIND_BIT, FK_XHCI_HCC1_LHRC_BIT, &
            FK_XHCI_HCC1_LTC_BIT, FK_XHCI_HCC1_NSS_BIT, FK_XHCI_HCC1_PAE_BIT, &
            FK_XHCI_HCC1_SPC_BIT, FK_XHCI_HCC1_SEC_BIT, FK_XHCI_HCC1_CFC_BIT, &
            FK_XHCI_HCC1_MAXPSA_POS, FK_XHCI_HCC1_MAXPSA_LEN, &
            FK_XHCI_HCC1_XECP_POS, FK_XHCI_HCC1_XECP_LEN
  public :: FK_XHCI_HCC2_U3C_BIT, FK_XHCI_HCC2_CMC_BIT, FK_XHCI_HCC2_FSC_BIT, &
            FK_XHCI_HCC2_CTC_BIT, FK_XHCI_HCC2_LEC_BIT, FK_XHCI_HCC2_CIC_BIT, &
            FK_XHCI_HCC2_ETC_BIT, FK_XHCI_HCC2_ETC_TSC_BIT, FK_XHCI_HCC2_GSC_BIT, &
            FK_XHCI_HCC2_VTC_BIT

  public :: FK_XHCI_USBCMD_RS_BIT, FK_XHCI_USBCMD_HCRST_BIT, &
            FK_XHCI_USBCMD_INTE_BIT, FK_XHCI_USBCMD_HSEE_BIT, &
            FK_XHCI_USBCMD_LHCRST_BIT, FK_XHCI_USBCMD_CSS_BIT, &
            FK_XHCI_USBCMD_CRS_BIT, FK_XHCI_USBCMD_EWE_BIT, &
            FK_XHCI_USBCMD_EU3S_BIT, FK_XHCI_USBCMD_ETE_BIT
  public :: FK_XHCI_USBSTS_HCH_BIT, FK_XHCI_USBSTS_HSE_BIT, &
            FK_XHCI_USBSTS_EINT_BIT, FK_XHCI_USBSTS_PCD_BIT, &
            FK_XHCI_USBSTS_SSS_BIT, FK_XHCI_USBSTS_RSS_BIT, &
            FK_XHCI_USBSTS_SRE_BIT, FK_XHCI_USBSTS_CNR_BIT, FK_XHCI_USBSTS_HCE_BIT
  public :: FK_XHCI_PAGESIZE_POS, FK_XHCI_PAGESIZE_LEN, &
            FK_XHCI_DNCTRL_NOTIFY_POS, FK_XHCI_DNCTRL_NOTIFY_LEN, &
            FK_XHCI_DNCTRL_NOTIFY_FWAKE_BIT
  public :: FK_XHCI_CRCR_RCS_BIT, FK_XHCI_CRCR_CS_BIT, FK_XHCI_CRCR_CA_BIT, &
            FK_XHCI_CRCR_CRR_BIT, FK_XHCI_CRCR_PTR_POS
  public :: FK_XHCI_DCBAAP_PTR_POS, FK_XHCI_CONFIG_MAXSLOTSEN_POS, &
            FK_XHCI_CONFIG_MAXSLOTSEN_LEN, FK_XHCI_CONFIG_U3E_BIT, &
            FK_XHCI_CONFIG_CIE_BIT

  public :: FK_XHCI_PORTSC_CCS_BIT, FK_XHCI_PORTSC_PED_BIT, &
            FK_XHCI_PORTSC_OCA_BIT, FK_XHCI_PORTSC_PR_BIT, FK_XHCI_PORTSC_PLS_POS, &
            FK_XHCI_PORTSC_PLS_LEN, FK_XHCI_PORTSC_PP_BIT, FK_XHCI_PORTSC_SPEED_POS, &
            FK_XHCI_PORTSC_SPEED_LEN, FK_XHCI_PORTSC_PIC_POS, FK_XHCI_PORTSC_PIC_LEN, &
            FK_XHCI_PORTSC_LWS_BIT, FK_XHCI_PORTSC_CSC_BIT, FK_XHCI_PORTSC_PEC_BIT, &
            FK_XHCI_PORTSC_WRC_BIT, FK_XHCI_PORTSC_OCC_BIT, FK_XHCI_PORTSC_PRC_BIT, &
            FK_XHCI_PORTSC_PLC_BIT, FK_XHCI_PORTSC_CEC_BIT, FK_XHCI_PORTSC_CAS_BIT, &
            FK_XHCI_PORTSC_WCE_BIT, FK_XHCI_PORTSC_WDE_BIT, FK_XHCI_PORTSC_WOE_BIT, &
            FK_XHCI_PORTSC_DR_BIT, FK_XHCI_PORTSC_WPR_BIT
  public :: FK_XHCI_PLS_U0, FK_XHCI_PLS_U1, FK_XHCI_PLS_U2, FK_XHCI_PLS_U3, &
            FK_XHCI_PLS_DISABLED, FK_XHCI_PLS_RXDETECT, FK_XHCI_PLS_INACTIVE, &
            FK_XHCI_PLS_POLLING, FK_XHCI_PLS_RECOVERY, FK_XHCI_PLS_HOT_RESET, &
            FK_XHCI_PLS_COMP_MODE, FK_XHCI_PLS_TEST_MODE, FK_XHCI_PLS_RESUME
  public :: FK_XHCI_SPEED_FS, FK_XHCI_SPEED_LS, FK_XHCI_SPEED_HS, &
            FK_XHCI_SPEED_SS, FK_XHCI_SPEED_SSP

  public :: FK_XHCI_IMAN_IP_BIT, FK_XHCI_IMAN_IE_BIT, FK_XHCI_IMOD_IMODI_POS, &
            FK_XHCI_IMOD_IMODI_LEN, FK_XHCI_IMOD_IMODC_POS, FK_XHCI_IMOD_IMODC_LEN
  public :: FK_XHCI_ERSTSZ_POS, FK_XHCI_ERSTSZ_LEN, FK_XHCI_ERSTBA_PTR_POS, &
            FK_XHCI_ERDP_DESI_POS, FK_XHCI_ERDP_DESI_LEN, FK_XHCI_ERDP_EHB_BIT, &
            FK_XHCI_ERDP_PTR_POS
  public :: FK_XHCI_ERST_SEG_SIZE_POS, FK_XHCI_ERST_SEG_SIZE_LEN, &
            FK_XHCI_ERST_ALIGN, FK_XHCI_ERST_SEG_ALIGN
  public :: FK_XHCI_DB_TARGET_POS, FK_XHCI_DB_TARGET_LEN, &
            FK_XHCI_DB_STREAM_ID_POS, FK_XHCI_DB_STREAM_ID_LEN, FK_XHCI_DB_HOST_TARGET

  public :: FK_XHCI_TRB_TYPE_NORMAL, FK_XHCI_TRB_TYPE_SETUP, &
            FK_XHCI_TRB_TYPE_DATA, FK_XHCI_TRB_TYPE_STATUS, FK_XHCI_TRB_TYPE_ISOCH, &
            FK_XHCI_TRB_TYPE_LINK, FK_XHCI_TRB_TYPE_EVENT_DATA, &
            FK_XHCI_TRB_TYPE_TR_NOOP
  public :: FK_XHCI_TRB_TYPE_ENABLE_SLOT, FK_XHCI_TRB_TYPE_DISABLE_SLOT, &
            FK_XHCI_TRB_TYPE_ADDR_DEV, FK_XHCI_TRB_TYPE_CONFIG_EP, &
            FK_XHCI_TRB_TYPE_EVAL_CONTEXT, FK_XHCI_TRB_TYPE_RESET_EP, &
            FK_XHCI_TRB_TYPE_STOP_RING, FK_XHCI_TRB_TYPE_SET_DEQ, &
            FK_XHCI_TRB_TYPE_RESET_DEV, FK_XHCI_TRB_TYPE_FORCE_EVENT, &
            FK_XHCI_TRB_TYPE_NEG_BANDWIDTH, FK_XHCI_TRB_TYPE_SET_LT, &
            FK_XHCI_TRB_TYPE_GET_BW, FK_XHCI_TRB_TYPE_FORCE_HEADER, &
            FK_XHCI_TRB_TYPE_CMD_NOOP
  public :: FK_XHCI_TRB_TYPE_TRANSFER, FK_XHCI_TRB_TYPE_COMPLETION, &
            FK_XHCI_TRB_TYPE_PORT_STATUS, FK_XHCI_TRB_TYPE_BANDWIDTH_EVENT, &
            FK_XHCI_TRB_TYPE_DOORBELL, FK_XHCI_TRB_TYPE_HC_EVENT, &
            FK_XHCI_TRB_TYPE_DEV_NOTE, FK_XHCI_TRB_TYPE_MFINDEX_WRAP, &
            FK_XHCI_TRB_TYPE_VENDOR_LOW

  public :: FK_XHCI_TRB_CTRL_CYCLE_BIT, FK_XHCI_TRB_CTRL_ENT_BIT, &
            FK_XHCI_TRB_CTRL_ISP_BIT, FK_XHCI_TRB_CTRL_NS_BIT, &
            FK_XHCI_TRB_CTRL_CHAIN_BIT, FK_XHCI_TRB_CTRL_IOC_BIT, &
            FK_XHCI_TRB_CTRL_IDT_BIT, FK_XHCI_TRB_CTRL_BEI_BIT, &
            FK_XHCI_TRB_CTRL_TC_BIT, FK_XHCI_TRB_CTRL_DIR_IN_BIT, &
            FK_XHCI_TRB_CTRL_BSR_BIT, FK_XHCI_TRB_CTRL_DC_BIT, &
            FK_XHCI_TRB_CTRL_TSP_BIT, FK_XHCI_TRB_CTRL_TYPE_POS, &
            FK_XHCI_TRB_CTRL_TYPE_LEN
  public :: FK_XHCI_TRB_TRT_POS, FK_XHCI_TRB_TRT_LEN, FK_XHCI_TRB_TRT_NO_DATA, &
            FK_XHCI_TRB_TRT_OUT, FK_XHCI_TRB_TRT_IN, FK_XHCI_TRB_SETUP_XFER_BYTES
  public :: FK_XHCI_TRB_XFER_LEN_POS, FK_XHCI_TRB_XFER_LEN_LEN, &
            FK_XHCI_TRB_TD_SIZE_POS, FK_XHCI_TRB_TD_SIZE_LEN, &
            FK_XHCI_TRB_INTR_TARGET_POS, FK_XHCI_TRB_INTR_TARGET_LEN
  public :: FK_XHCI_TRB_SIA_BIT, FK_XHCI_TRB_FRAME_ID_POS, &
            FK_XHCI_TRB_FRAME_ID_LEN, FK_XHCI_TRB_TBC_POS, FK_XHCI_TRB_TBC_LEN, &
            FK_XHCI_TRB_TLBPC_POS, FK_XHCI_TRB_TLBPC_LEN
  public :: FK_XHCI_TRB_LINK_PTR_POS, FK_XHCI_TRB_XEVT_LEN_POS, &
            FK_XHCI_TRB_XEVT_LEN_LEN, FK_XHCI_TRB_XEVT_COMP_POS, &
            FK_XHCI_TRB_XEVT_COMP_LEN, FK_XHCI_TRB_XEVT_ED_BIT, &
            FK_XHCI_TRB_XEVT_EP_ID_POS, FK_XHCI_TRB_XEVT_EP_ID_LEN, &
            FK_XHCI_TRB_XEVT_SLOT_ID_POS, FK_XHCI_TRB_XEVT_SLOT_ID_LEN
  public :: FK_XHCI_TRB_CEVT_PARAM_POS, FK_XHCI_TRB_CEVT_PARAM_LEN, &
            FK_XHCI_TRB_CEVT_COMP_POS, FK_XHCI_TRB_CEVT_COMP_LEN, &
            FK_XHCI_TRB_CEVT_VF_ID_POS, FK_XHCI_TRB_CEVT_VF_ID_LEN, &
            FK_XHCI_TRB_CEVT_SLOT_ID_POS, FK_XHCI_TRB_CEVT_SLOT_ID_LEN, &
            FK_XHCI_TRB_CEVT_PTR_POS
  public :: FK_XHCI_TRB_PSC_PORT_ID_POS, FK_XHCI_TRB_PSC_PORT_ID_LEN, &
            FK_XHCI_TRB_PSC_COMP_POS, FK_XHCI_TRB_PSC_COMP_LEN

  public :: FK_XHCI_COMP_INVALID, FK_XHCI_COMP_SUCCESS, &
            FK_XHCI_COMP_DATA_BUFFER_ERROR, FK_XHCI_COMP_BABBLE_DETECTED_ERROR, &
            FK_XHCI_COMP_USB_TRANSACTION_ERROR, FK_XHCI_COMP_TRB_ERROR, &
            FK_XHCI_COMP_STALL_ERROR, FK_XHCI_COMP_RESOURCE_ERROR, &
            FK_XHCI_COMP_BANDWIDTH_ERROR, FK_XHCI_COMP_NO_SLOTS_AVAILABLE_ERROR, &
            FK_XHCI_COMP_INVALID_STREAM_TYPE_ERROR, &
            FK_XHCI_COMP_SLOT_NOT_ENABLED_ERROR, &
            FK_XHCI_COMP_ENDPOINT_NOT_ENABLED_ERROR, FK_XHCI_COMP_SHORT_PACKET, &
            FK_XHCI_COMP_RING_UNDERRUN, FK_XHCI_COMP_RING_OVERRUN, &
            FK_XHCI_COMP_VF_EVENT_RING_FULL_ERROR, FK_XHCI_COMP_PARAMETER_ERROR
  public :: FK_XHCI_COMP_BANDWIDTH_OVERRUN_ERROR, &
            FK_XHCI_COMP_CONTEXT_STATE_ERROR, FK_XHCI_COMP_NO_PING_RESPONSE_ERROR, &
            FK_XHCI_COMP_EVENT_RING_FULL_ERROR, &
            FK_XHCI_COMP_INCOMPATIBLE_DEVICE_ERROR, &
            FK_XHCI_COMP_MISSED_SERVICE_ERROR, FK_XHCI_COMP_COMMAND_RING_STOPPED, &
            FK_XHCI_COMP_COMMAND_ABORTED, FK_XHCI_COMP_STOPPED, &
            FK_XHCI_COMP_STOPPED_LENGTH_INVALID, FK_XHCI_COMP_STOPPED_SHORT_PACKET, &
            FK_XHCI_COMP_MAX_EXIT_LATENCY_TOO_LARGE_ERROR, &
            FK_XHCI_COMP_ISOCH_BUFFER_OVERRUN, FK_XHCI_COMP_EVENT_LOST_ERROR, &
            FK_XHCI_COMP_UNDEFINED_ERROR, FK_XHCI_COMP_INVALID_STREAM_ID_ERROR, &
            FK_XHCI_COMP_SECONDARY_BANDWIDTH_ERROR, &
            FK_XHCI_COMP_SPLIT_TRANSACTION_ERROR

  public :: FK_XHCI_XECP_ID_POS, FK_XHCI_XECP_ID_LEN, FK_XHCI_XECP_NEXT_POS, &
            FK_XHCI_XECP_NEXT_LEN, FK_XHCI_XECP_VAL_POS, FK_XHCI_XECP_VAL_LEN, &
            FK_XHCI_XECP_PTR_SHIFT
  public :: FK_XHCI_XECP_ID_LEGACY, FK_XHCI_XECP_ID_PROTOCOL, &
            FK_XHCI_XECP_ID_PM, FK_XHCI_XECP_ID_VIRT, FK_XHCI_XECP_ID_ROUTE, &
            FK_XHCI_XECP_ID_DEBUG
  public :: FK_XHCI_XECP_LEGSUP_OFF, FK_XHCI_XECP_LEGCTLSTS_OFF, &
            FK_XHCI_XECP_LEG_BIOS_OWNED_BIT, FK_XHCI_XECP_LEG_OS_OWNED_BIT
  public :: FK_XHCI_XECP_PROTO_MINOR_POS, FK_XHCI_XECP_PROTO_MINOR_LEN, &
            FK_XHCI_XECP_PROTO_MAJOR_POS, FK_XHCI_XECP_PROTO_MAJOR_LEN, &
            FK_XHCI_XECP_PROTO_NAME_OFF, FK_XHCI_XECP_PROTO_PORTS_OFF, &
            FK_XHCI_XECP_PROTO_PORT_OFF_POS, FK_XHCI_XECP_PROTO_PORT_OFF_LEN, &
            FK_XHCI_XECP_PROTO_PORT_CNT_POS, FK_XHCI_XECP_PROTO_PORT_CNT_LEN, &
            FK_XHCI_XECP_PROTO_PSIC_POS, FK_XHCI_XECP_PROTO_PSIC_LEN

  ! ---- block geometry, in bytes ----------------------------------------------
  ! The operational block base is CAPLENGTH, the doorbell array base DBOFF and
  ! the runtime block base RTSOFF, all read at run time (xHCI 1.2 5.3.1/5.3.7/
  ! 5.3.8); only the offsets WITHIN a block are constants.
  integer(c_int32_t), parameter :: FK_XHCI_OP_PORT_BASE = int(z'0400', c_int32_t)
  integer(c_int32_t), parameter :: FK_XHCI_PORT_STRIDE = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_RT_IR_BASE = int(z'0020', c_int32_t)
  integer(c_int32_t), parameter :: FK_XHCI_RT_IR_STRIDE = 32_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_DB_STRIDE = 4_c_int32_t
  ! xECP walking starts from HCCPARAMS1 at the PCI BAR base (xhci-ext-caps.h:17).
  integer(c_int32_t), parameter :: FK_XHCI_HCCPARAMS1_OFF = int(z'0010', c_int32_t)

  ! THE SAME LAYOUTS AS BYTE OFFSETS.  The types above describe the blocks, but
  ! nothing may reach a device register through a Fortran pointer -- gfortran
  ! narrows such a load and tools/mmiocheck.sh refuses the result -- so every
  ! access is fk_readl(base + offset) and the offsets have to exist as numbers.
  integer(c_int32_t), parameter :: FK_XHCI_CAP_LENGTH_OFF = int(z'0000', c_int32_t)
  integer(c_int32_t), parameter :: FK_XHCI_CAP_HCS1_OFF   = int(z'0004', c_int32_t)
  integer(c_int32_t), parameter :: FK_XHCI_CAP_HCS2_OFF   = int(z'0008', c_int32_t)
  integer(c_int32_t), parameter :: FK_XHCI_CAP_HCS3_OFF   = int(z'000C', c_int32_t)
  integer(c_int32_t), parameter :: FK_XHCI_CAP_DBOFF_OFF  = int(z'0014', c_int32_t)
  integer(c_int32_t), parameter :: FK_XHCI_CAP_RTSOFF_OFF = int(z'0018', c_int32_t)
  integer(c_int32_t), parameter :: FK_XHCI_CAP_HCC2_OFF   = int(z'001C', c_int32_t)

  integer(c_int32_t), parameter :: FK_XHCI_OP_USBCMD_OFF   = int(z'0000', c_int32_t)
  integer(c_int32_t), parameter :: FK_XHCI_OP_USBSTS_OFF   = int(z'0004', c_int32_t)
  integer(c_int32_t), parameter :: FK_XHCI_OP_PAGESIZE_OFF = int(z'0008', c_int32_t)
  integer(c_int32_t), parameter :: FK_XHCI_OP_DNCTRL_OFF   = int(z'0014', c_int32_t)
  integer(c_int32_t), parameter :: FK_XHCI_OP_CRCR_OFF     = int(z'0018', c_int32_t)
  integer(c_int32_t), parameter :: FK_XHCI_OP_DCBAAP_OFF   = int(z'0030', c_int32_t)
  integer(c_int32_t), parameter :: FK_XHCI_OP_CONFIG_OFF   = int(z'0038', c_int32_t)

  integer(c_int32_t), parameter :: FK_XHCI_IR_IMAN_OFF   = int(z'0000', c_int32_t)
  integer(c_int32_t), parameter :: FK_XHCI_IR_IMOD_OFF   = int(z'0004', c_int32_t)
  integer(c_int32_t), parameter :: FK_XHCI_IR_ERSTSZ_OFF = int(z'0008', c_int32_t)
  integer(c_int32_t), parameter :: FK_XHCI_IR_ERSTBA_OFF = int(z'0010', c_int32_t)
  integer(c_int32_t), parameter :: FK_XHCI_IR_ERDP_OFF   = int(z'0018', c_int32_t)

  integer(c_int32_t), parameter :: FK_XHCI_TRB_SIZE   = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_DWORDS = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_ERST_ENTRY_SIZE = 16_c_int32_t
  ! CRCR, DCBAAP and ERSTBA all carry their pointer in bits 63:6.
  integer(c_int32_t), parameter :: FK_XHCI_RING_ALIGN = 64_c_int32_t
  ! DBOFF holds its offset in bits 31:2 and RTSOFF in bits 31:5; the bits below
  ! PTR_POS are reserved and must be masked off before use (xhci-caps.h:85-92).
  integer(c_int32_t), parameter :: FK_XHCI_DBOFF_PTR_POS = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_RTSOFF_PTR_POS = 5_c_int32_t
  ! Architectural maxima: slots xHCI 1.2 section 6.1, ports and interrupters
  ! section 5.3.3, whose ranges 1..255 and 1..1024 are quoted at xhci.h:39-41
  ! and :44-46.  MAX_HC_PORTS 127 and MAX_HC_INTRS 128 in xhci.h are Linux
  ! policy caps, not architectural limits.
  integer(c_int32_t), parameter :: FK_XHCI_MAX_SLOTS = 256_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_MAX_PORTS = 255_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_MAX_INTRS = 1024_c_int32_t

  ! ---- capability registers, xHCI 1.2 section 5.3 (xhci.h:66-76) -------------
  ! Upstream folds CAPLENGTH and HCIVERSION into one __le32 hc_capbase; the
  ! specification defines them as an 8-bit and a 16-bit register, and byte 0x01
  ! between them is reserved.  This is the ONLY block in this file where an 8- or
  ! 16-bit access is architecturally legal.
  type, bind(c) :: fk_xhci_cap_t
    integer(c_int8_t)  :: caplength
    integer(c_int8_t)  :: rsvd_01
    integer(c_int16_t) :: hciversion
    integer(c_int32_t) :: hcsparams1
    integer(c_int32_t) :: hcsparams2
    integer(c_int32_t) :: hcsparams3
    integer(c_int32_t) :: hccparams1
    integer(c_int32_t) :: dboff
    integer(c_int32_t) :: rtsoff
    integer(c_int32_t) :: hccparams2
  end type fk_xhci_cap_t   ! 0x20

  ! POS/LEN below are relative to the 32-bit hc_capbase dword upstream reads,
  ! not to the byte-wide and word-wide registers this module declares.
  integer(c_int32_t), parameter :: FK_XHCI_CAPLENGTH_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_CAPLENGTH_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCIVERSION_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCIVERSION_LEN = 16_c_int32_t

  ! HCSPARAMS1, xhci-caps.h:16-23.  Bits 23:19, between MAX_INTRS and
  ! MAX_PORTS, carry no field this module defines.
  integer(c_int32_t), parameter :: FK_XHCI_HCS1_MAX_SLOTS_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCS1_MAX_SLOTS_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCS1_MAX_INTRS_POS = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCS1_MAX_INTRS_LEN = 11_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCS1_MAX_PORTS_POS = 24_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCS1_MAX_PORTS_LEN = 8_c_int32_t

  ! HCSPARAMS2, xhci-caps.h:25-46.  IST is in microframes unless IST_UNIT is
  ! set, in which case it is in frames.  ERST_MAX is a power: entries =
  ! 2**ERST_MAX.  Max scratchpad buffers = (MAX_SP_HI * 32) + MAX_SP_LO, split
  ! across the dword.  Bits 20:8, between ERST_MAX and MAX_SP_HI, carry no field
  ! this module defines.
  integer(c_int32_t), parameter :: FK_XHCI_HCS2_IST_VALUE_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCS2_IST_VALUE_LEN = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCS2_IST_UNIT_BIT = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCS2_ERST_MAX_POS = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCS2_ERST_MAX_LEN = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCS2_MAX_SP_HI_POS = 21_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCS2_MAX_SP_HI_LEN = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCS2_SPR_BIT = 26_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCS2_MAX_SP_LO_POS = 27_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCS2_MAX_SP_LO_LEN = 5_c_int32_t

  ! HCSPARAMS3, xhci-caps.h:48-53.  U1 and U2 exit latencies are in
  ! microseconds.  Bits 15:8, between them, carry no field this module defines.
  integer(c_int32_t), parameter :: FK_XHCI_HCS3_U1_LATENCY_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCS3_U1_LATENCY_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCS3_U2_LATENCY_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCS3_U2_LATENCY_LEN = 16_c_int32_t

  ! HCCPARAMS1, xhci-caps.h:55-82.  CSZ set means 64-byte contexts, clear 32-byte.
  ! MAXPSA is a power: primary stream array max = 2**(MAXPSA+1).
  ! XECP is in 32-bit dwords from the PCI BAR base; byte offset = XECP * 4.
  integer(c_int32_t), parameter :: FK_XHCI_HCC1_AC64_BIT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC1_BNC_BIT = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC1_CSZ_BIT = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC1_PPC_BIT = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC1_PIND_BIT = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC1_LHRC_BIT = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC1_LTC_BIT = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC1_NSS_BIT = 7_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC1_PAE_BIT = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC1_SPC_BIT = 9_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC1_SEC_BIT = 10_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC1_CFC_BIT = 11_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC1_MAXPSA_POS = 12_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC1_MAXPSA_LEN = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC1_XECP_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC1_XECP_LEN = 16_c_int32_t

  ! HCCPARAMS2, xhci-caps.h:94-119
  integer(c_int32_t), parameter :: FK_XHCI_HCC2_U3C_BIT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC2_CMC_BIT = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC2_FSC_BIT = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC2_CTC_BIT = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC2_LEC_BIT = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC2_CIC_BIT = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC2_ETC_BIT = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC2_ETC_TSC_BIT = 7_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC2_GSC_BIT = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_HCC2_VTC_BIT = 9_c_int32_t

  ! ---- operational registers, xHCI 1.2 section 5.4 (xhci.h:105-120) ----------
  ! The two reserved dwords at 0x0C and the four at 0x20 are load bearing: they
  ! put CRCR at 0x18 and DCBAAP at 0x30.  rsvd_3c pads the type to 0x40, which is
  ! also a multiple of its own 8-byte alignment, so the ABI adds no tail padding.
  ! Everything from the end of CONFIG to 0x3FF is reserved; the port register
  ! sets begin at FK_XHCI_OP_PORT_BASE and are not part of this type.
  type, bind(c) :: fk_xhci_op_t
    integer(c_int32_t) :: usbcmd
    integer(c_int32_t) :: usbsts
    integer(c_int32_t) :: pagesize
    integer(c_int32_t) :: rsvd_0c(0:1)
    integer(c_int32_t) :: dnctrl
    integer(c_int64_t) :: crcr
    integer(c_int32_t) :: rsvd_20(0:3)
    integer(c_int64_t) :: dcbaap
    integer(c_int32_t) :: config
    integer(c_int32_t) :: rsvd_3c
  end type fk_xhci_op_t   ! 0x40

  ! USBCMD, xHCI 1.2 section 5.4.1 (xhci.h:122-149).  Bits 6:4 and 13:12 carry
  ! no field this module defines.
  integer(c_int32_t), parameter :: FK_XHCI_USBCMD_RS_BIT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_USBCMD_HCRST_BIT = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_USBCMD_INTE_BIT = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_USBCMD_HSEE_BIT = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_USBCMD_LHCRST_BIT = 7_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_USBCMD_CSS_BIT = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_USBCMD_CRS_BIT = 9_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_USBCMD_EWE_BIT = 10_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_USBCMD_EU3S_BIT = 11_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_USBCMD_ETE_BIT = 14_c_int32_t

  ! USBSTS, xHCI 1.2 section 5.4.2 (xhci.h:155-175).  Bit 1 and bits 7:5 carry
  ! no field this module defines.
  integer(c_int32_t), parameter :: FK_XHCI_USBSTS_HCH_BIT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_USBSTS_HSE_BIT = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_USBSTS_EINT_BIT = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_USBSTS_PCD_BIT = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_USBSTS_SSS_BIT = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_USBSTS_RSS_BIT = 9_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_USBSTS_SRE_BIT = 10_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_USBSTS_CNR_BIT = 11_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_USBSTS_HCE_BIT = 12_c_int32_t

  ! PAGESIZE, xhci.h:96-99 and 209-210: bit n set means the controller supports a
  ! page size of 2**(n+12) bytes.  Minimum supported page size is 4 KiB.
  integer(c_int32_t), parameter :: FK_XHCI_PAGESIZE_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PAGESIZE_LEN = 16_c_int32_t

  ! DNCTRL, xhci.h:177-186: bit n enables device notification type n.  FWAKE is
  ! indexed in register bits; NOTIFY is based at bit 0, so that is also its
  ! index within the NOTIFY field.
  integer(c_int32_t), parameter :: FK_XHCI_DNCTRL_NOTIFY_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_DNCTRL_NOTIFY_LEN = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_DNCTRL_NOTIFY_FWAKE_BIT = 1_c_int32_t

  ! CRCR, xhci.h:188-198.  POS values index the 64-bit register, not a dword: the
  ! ring pointer occupies bits 63:6, so the ring is 64-byte aligned.
  integer(c_int32_t), parameter :: FK_XHCI_CRCR_RCS_BIT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_CRCR_CS_BIT = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_CRCR_CA_BIT = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_CRCR_CRR_BIT = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_CRCR_PTR_POS = 6_c_int32_t

  ! DCBAAP bits 63:6 are the pointer; bits 5:0 are RsvdZ, so the array is
  ! 64-byte aligned (xHCI 1.2 section 5.4.6).
  integer(c_int32_t), parameter :: FK_XHCI_DCBAAP_PTR_POS = 6_c_int32_t

  ! CONFIG, xhci.h:200-206
  integer(c_int32_t), parameter :: FK_XHCI_CONFIG_MAXSLOTSEN_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_CONFIG_MAXSLOTSEN_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_CONFIG_U3E_BIT = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_CONFIG_CIE_BIT = 9_c_int32_t

  ! ---- port register set, xHCI 1.2 section 5.4.8 (xhci.h:85-90) --------------
  ! Set n lives at FK_XHCI_OP_PORT_BASE + n*FK_XHCI_PORT_STRIDE within the
  ! operational block, for n in 0..MaxPorts-1 read from HCSPARAMS1.
  type, bind(c) :: fk_xhci_port_t
    integer(c_int32_t) :: portsc
    integer(c_int32_t) :: portpmsc
    integer(c_int32_t) :: portli
    integer(c_int32_t) :: porthlpmc
  end type fk_xhci_port_t   ! 0x10

  ! PORTSC, xhci-port.h:3-119.  Bit 2 and bits 29:28 are reserved.
  ! The change bits (CSC..CEC) are write-1-to-clear.
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_CCS_BIT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_PED_BIT = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_OCA_BIT = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_PR_BIT = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_PLS_POS = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_PLS_LEN = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_PP_BIT = 9_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_SPEED_POS = 10_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_SPEED_LEN = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_PIC_POS = 14_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_PIC_LEN = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_LWS_BIT = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_CSC_BIT = 17_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_PEC_BIT = 18_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_WRC_BIT = 19_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_OCC_BIT = 20_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_PRC_BIT = 21_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_PLC_BIT = 22_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_CEC_BIT = 23_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_CAS_BIT = 24_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_WCE_BIT = 25_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_WDE_BIT = 26_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_WOE_BIT = 27_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_DR_BIT = 30_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PORTSC_WPR_BIT = 31_c_int32_t

  ! PLS field values, already shifted down to the field (xhci-port.h:17-30).
  integer(c_int32_t), parameter :: FK_XHCI_PLS_U0 = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PLS_U1 = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PLS_U2 = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PLS_U3 = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PLS_DISABLED = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PLS_RXDETECT = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PLS_INACTIVE = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PLS_POLLING = 7_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PLS_RECOVERY = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PLS_HOT_RESET = 9_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PLS_COMP_MODE = 10_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PLS_TEST_MODE = 11_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_PLS_RESUME = 15_c_int32_t

  ! Port Speed ID values, already shifted down to the field (xhci-port.h:42-47).
  integer(c_int32_t), parameter :: FK_XHCI_SPEED_FS = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_SPEED_LS = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_SPEED_HS = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_SPEED_SS = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_SPEED_SSP = 5_c_int32_t

  ! ---- runtime registers, xHCI 1.2 section 5.5 (xhci.h:284-288) --------------
  ! Header only: interrupter n lives at FK_XHCI_RT_IR_BASE +
  ! n*FK_XHCI_RT_IR_STRIDE within the runtime block.
  type, bind(c) :: fk_xhci_rt_t
    integer(c_int32_t) :: mfindex
    integer(c_int32_t) :: rsvd_04(0:6)
  end type fk_xhci_rt_t   ! 0x20

  ! Interrupter register set, xHCI 1.2 section 5.5.2 (xhci.h:228-235).
  ! rsvd_0c is load bearing: it puts ERSTBA at 0x10 and ERDP at 0x18.
  type, bind(c) :: fk_xhci_intr_t
    integer(c_int32_t) :: iman
    integer(c_int32_t) :: imod
    integer(c_int32_t) :: erstsz
    integer(c_int32_t) :: rsvd_0c
    integer(c_int64_t) :: erstba
    integer(c_int64_t) :: erdp
  end type fk_xhci_intr_t   ! 0x20

  ! IMAN, xhci.h:237-241.  IP is write-1-to-clear.
  integer(c_int32_t), parameter :: FK_XHCI_IMAN_IP_BIT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_IMAN_IE_BIT = 1_c_int32_t
  ! IMOD, xhci.h:243-251.  Both fields count in 250 ns units.
  integer(c_int32_t), parameter :: FK_XHCI_IMOD_IMODI_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_IMOD_IMODI_LEN = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_IMOD_IMODC_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_IMOD_IMODC_LEN = 16_c_int32_t
  ! ERSTSZ counts ERST entries, xhci.h:253-255.
  integer(c_int32_t), parameter :: FK_XHCI_ERSTSZ_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_ERSTSZ_LEN = 16_c_int32_t
  ! ERSTBA and ERDP POS values index the 64-bit register (xhci.h:257-273).
  integer(c_int32_t), parameter :: FK_XHCI_ERSTBA_PTR_POS = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_ERDP_DESI_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_ERDP_DESI_LEN = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_ERDP_EHB_BIT = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_ERDP_PTR_POS = 4_c_int32_t

  ! ---- Event Ring Segment Table entry, xHCI 1.2 section 6.5 (xhci.h:1386-1392)
  type, bind(c) :: fk_xhci_erst_t
    integer(c_int64_t) :: seg_base
    integer(c_int32_t) :: seg_size
    integer(c_int32_t) :: rsvd_0c
  end type fk_xhci_erst_t   ! 0x10

  ! Ring Segment Size counts TRBs, not bytes, and must be 16..4096.
  integer(c_int32_t), parameter :: FK_XHCI_ERST_SEG_SIZE_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_ERST_SEG_SIZE_LEN = 16_c_int32_t
  ! Alignment in bytes required of the table itself and of each segment it names.
  integer(c_int32_t), parameter :: FK_XHCI_ERST_ALIGN = 64_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_ERST_SEG_ALIGN = 64_c_int32_t

  ! ---- doorbell array, xHCI 1.2 section 5.6 (xhci.h:290-304) -----------------
  ! Doorbell n is a dword at DBOFF + n*FK_XHCI_DB_STRIDE; bits 15:8 are RsvdZ.
  integer(c_int32_t), parameter :: FK_XHCI_DB_TARGET_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_DB_TARGET_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_DB_STREAM_ID_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_DB_STREAM_ID_LEN = 16_c_int32_t
  ! Target 0 on doorbell 0 rings the command ring (xhci.h:304).
  integer(c_int32_t), parameter :: FK_XHCI_DB_HOST_TARGET = 0_c_int32_t

  ! ---- Transfer Request Blocks, xHCI 1.2 chapter 6 (xhci.h:1084-1093) --------
  ! Every variant is 16 bytes.  These types are overlaid on DMA memory obtained
  ! from the contiguous allocator, never declared as static arrays, so the
  ! alignment of the type is not what makes a ring legal: segment alignment and
  ! the 64 KiB boundary rule come from the allocation, not from these
  ! declarations.  All variants but fk_xhci_trb_setup_t carry an 8-byte-aligned
  ! first quadword; the setup stage TRB holds the USB device request there
  ! instead of a pointer and is therefore 4-aligned (xHCI 1.2 section 6.4.1.2.1,
  ! xhci-ring.c:3833-3856).

  ! Generic TRB: the decomposition every variant shares.  A command ring TRB
  ! (Enable Slot, Address Device, Configure Endpoint and the rest) uses this
  ! parameter/status/control layout unchanged and is distinguished only by the
  ! TRB type field in the control dword, so this module defines no per-command
  ! types.
  type, bind(c) :: fk_xhci_trb_t
    integer(c_int64_t) :: parm
    integer(c_int32_t) :: status
    integer(c_int32_t) :: control
  end type fk_xhci_trb_t   ! 0x10

  ! Normal, Data Stage and Isoch TRBs, xHCI 1.2 sections 6.4.1.1/6.4.1.2.2.
  ! data_buf holds immediate data instead of a pointer when the IDT bit is set.
  type, bind(c) :: fk_xhci_trb_xfer_t
    integer(c_int64_t) :: data_buf
    integer(c_int32_t) :: xfer_info
    integer(c_int32_t) :: control
  end type fk_xhci_trb_xfer_t   ! 0x10

  ! Setup Stage TRB, xHCI 1.2 section 6.4.1.2.1.  The first 8 bytes are the USB
  ! device request itself, not a pointer.
  type, bind(c) :: fk_xhci_trb_setup_t
    integer(c_int8_t)  :: bmrequesttype
    integer(c_int8_t)  :: brequest
    integer(c_int16_t) :: wvalue
    integer(c_int16_t) :: windex
    integer(c_int16_t) :: wlength
    integer(c_int32_t) :: xfer_info
    integer(c_int32_t) :: control
  end type fk_xhci_trb_setup_t   ! 0x10

  ! Link TRB, xHCI 1.2 section 6.4.4.1 (xhci.h:950-955).
  type, bind(c) :: fk_xhci_trb_link_t
    integer(c_int64_t) :: seg_ptr
    integer(c_int32_t) :: link_info
    integer(c_int32_t) :: control
  end type fk_xhci_trb_link_t   ! 0x10

  ! Transfer Event TRB, xHCI 1.2 section 6.4.2.1 (xhci.h:809-814).
  type, bind(c) :: fk_xhci_trb_xfer_event_t
    integer(c_int64_t) :: trb_ptr
    integer(c_int32_t) :: xfer_status
    integer(c_int32_t) :: control
  end type fk_xhci_trb_xfer_event_t   ! 0x10

  ! Command Completion Event TRB, xHCI 1.2 section 6.4.2.2 (xhci.h:961-966).
  type, bind(c) :: fk_xhci_trb_cmd_event_t
    integer(c_int64_t) :: cmd_trb_ptr
    integer(c_int32_t) :: cmd_status
    integer(c_int32_t) :: control
  end type fk_xhci_trb_cmd_event_t   ! 0x10

  ! Port Status Change Event TRB, xHCI 1.2 section 6.4.2.3.  The first quadword
  ! carries only the Port ID in its low dword and is kept as one 64-bit
  ! component so every event variant aligns identically (xhci-ring.c:2004-2008).
  type, bind(c) :: fk_xhci_trb_psc_event_t
    integer(c_int64_t) :: port_info
    integer(c_int32_t) :: psc_status
    integer(c_int32_t) :: control
  end type fk_xhci_trb_psc_event_t   ! 0x10

  ! TRB type IDs, xhci.h:1099-1169.  Transfer ring types first.
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_NORMAL = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_SETUP = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_DATA = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_STATUS = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_ISOCH = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_LINK = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_EVENT_DATA = 7_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_TR_NOOP = 8_c_int32_t
  ! Command ring types.
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_ENABLE_SLOT = 9_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_DISABLE_SLOT = 10_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_ADDR_DEV = 11_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_CONFIG_EP = 12_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_EVAL_CONTEXT = 13_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_RESET_EP = 14_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_STOP_RING = 15_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_SET_DEQ = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_RESET_DEV = 17_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_FORCE_EVENT = 18_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_NEG_BANDWIDTH = 19_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_SET_LT = 20_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_GET_BW = 21_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_FORCE_HEADER = 22_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_CMD_NOOP = 23_c_int32_t
  ! Event ring types.  IDs 24-31 and 40-47 are reserved.
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_TRANSFER = 32_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_COMPLETION = 33_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_PORT_STATUS = 34_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_BANDWIDTH_EVENT = 35_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_DOORBELL = 36_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_HC_EVENT = 37_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_DEV_NOTE = 38_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_MFINDEX_WRAP = 39_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TYPE_VENDOR_LOW = 48_c_int32_t

  ! Control dword bits, xhci.h:972-978 and 1020-1068.  Aliased indices, each
  ! meaningful only on the TRB type named: bit 1 is ENT on transfer TRBs and TC
  ! on the Link TRB; bit 9 is BEI on transfer TRBs, BSR on Address Device, DC on
  ! Configure Endpoint and TSP on Stop Endpoint (TYPE_STOP_RING); bit 16 is
  ! DIR_IN on the Data and Status Stage TRBs, the base of TRT on the Setup Stage
  ! TRB and the base of TLBPC on the Isoch TRB.
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CTRL_CYCLE_BIT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CTRL_ENT_BIT = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CTRL_TC_BIT = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CTRL_ISP_BIT = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CTRL_NS_BIT = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CTRL_CHAIN_BIT = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CTRL_IOC_BIT = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CTRL_IDT_BIT = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CTRL_BEI_BIT = 9_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CTRL_BSR_BIT = 9_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CTRL_DC_BIT = 9_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CTRL_TSP_BIT = 9_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CTRL_DIR_IN_BIT = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CTRL_TYPE_POS = 10_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CTRL_TYPE_LEN = 6_c_int32_t

  ! Setup Stage TRB, xHCI 1.2 section 6.4.1.2.1.  TRT is in the control dword; the
  ! transfer length in the status dword is always 8 (xhci-ring.c:3841-3856).
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TRT_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TRT_LEN = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TRT_NO_DATA = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TRT_OUT = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TRT_IN = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_SETUP_XFER_BYTES = 8_c_int32_t

  ! Status dword of Normal/Data/Setup/Isoch TRBs, xhci.h:1029-1039.
  integer(c_int32_t), parameter :: FK_XHCI_TRB_XFER_LEN_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_XFER_LEN_LEN = 17_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TD_SIZE_POS = 17_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TD_SIZE_LEN = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_INTR_TARGET_POS = 22_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_INTR_TARGET_LEN = 10_c_int32_t

  ! Isoch TRB extras, xhci.h:1070-1078.  SIA, FRAME_ID, TBC and TLBPC live in the
  ! control dword; TBC is RsvdZ when Extended TBC is enabled.
  integer(c_int32_t), parameter :: FK_XHCI_TRB_SIA_BIT = 31_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_FRAME_ID_POS = 20_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_FRAME_ID_LEN = 11_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TBC_POS = 7_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TBC_LEN = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TLBPC_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_TLBPC_LEN = 4_c_int32_t

  ! Link TRB: the segment pointer is bits 63:4 of the 64-bit first quadword.
  integer(c_int32_t), parameter :: FK_XHCI_TRB_LINK_PTR_POS = 4_c_int32_t

  ! Transfer Event TRB, xhci.h:818-838.  LEN and COMP are in the status dword,
  ! ED, EP_ID and SLOT_ID in the control dword.
  integer(c_int32_t), parameter :: FK_XHCI_TRB_XEVT_LEN_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_XEVT_LEN_LEN = 24_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_XEVT_COMP_POS = 24_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_XEVT_COMP_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_XEVT_ED_BIT = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_XEVT_EP_ID_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_XEVT_EP_ID_LEN = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_XEVT_SLOT_ID_POS = 24_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_XEVT_SLOT_ID_LEN = 8_c_int32_t

  ! Command Completion Event TRB, xhci.h:961-969 and 1004-1005.  PARAM and COMP
  ! are in the status dword, VF_ID and SLOT_ID in the control dword; PTR_POS
  ! indexes the 64-bit command TRB pointer.
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CEVT_PARAM_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CEVT_PARAM_LEN = 24_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CEVT_COMP_POS = 24_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CEVT_COMP_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CEVT_VF_ID_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CEVT_VF_ID_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CEVT_SLOT_ID_POS = 24_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CEVT_SLOT_ID_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_CEVT_PTR_POS = 4_c_int32_t

  ! Port Status Change Event TRB.  PORT_ID_POS is relative to the LOW dword of
  ! port_info, which for a little-endian quadword is the same bit index in the
  ! quadword; COMP is in the status dword (xhci-ring.c:2004-2008).
  integer(c_int32_t), parameter :: FK_XHCI_TRB_PSC_PORT_ID_POS = 24_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_PSC_PORT_ID_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_PSC_COMP_POS = 24_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_TRB_PSC_COMP_LEN = 8_c_int32_t

  ! Completion codes, xHCI 1.2 section 6.4.5 (xhci.h:833-868).  Code 30 and codes
  ! 37-191 are reserved; 192-223 are vendor defined errors, 224-255 vendor
  ! defined information.
  integer(c_int32_t), parameter :: FK_XHCI_COMP_INVALID = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_SUCCESS = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_DATA_BUFFER_ERROR = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_BABBLE_DETECTED_ERROR = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_USB_TRANSACTION_ERROR = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_TRB_ERROR = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_STALL_ERROR = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_RESOURCE_ERROR = 7_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_BANDWIDTH_ERROR = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_NO_SLOTS_AVAILABLE_ERROR = 9_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_INVALID_STREAM_TYPE_ERROR = 10_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_SLOT_NOT_ENABLED_ERROR = 11_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_ENDPOINT_NOT_ENABLED_ERROR = 12_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_SHORT_PACKET = 13_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_RING_UNDERRUN = 14_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_RING_OVERRUN = 15_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_VF_EVENT_RING_FULL_ERROR = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_PARAMETER_ERROR = 17_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_BANDWIDTH_OVERRUN_ERROR = 18_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_CONTEXT_STATE_ERROR = 19_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_NO_PING_RESPONSE_ERROR = 20_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_EVENT_RING_FULL_ERROR = 21_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_INCOMPATIBLE_DEVICE_ERROR = 22_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_MISSED_SERVICE_ERROR = 23_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_COMMAND_RING_STOPPED = 24_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_COMMAND_ABORTED = 25_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_STOPPED = 26_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_STOPPED_LENGTH_INVALID = 27_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_STOPPED_SHORT_PACKET = 28_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_MAX_EXIT_LATENCY_TOO_LARGE_ERROR = 29_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_ISOCH_BUFFER_OVERRUN = 31_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_EVENT_LOST_ERROR = 32_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_UNDEFINED_ERROR = 33_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_INVALID_STREAM_ID_ERROR = 34_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_SECONDARY_BANDWIDTH_ERROR = 35_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_COMP_SPLIT_TRANSACTION_ERROR = 36_c_int32_t

  ! ---- extended capabilities, xHCI 1.2 section 7 (xhci-ext-caps.h:31-52) -----
  ! The list head is HCCPARAMS1 bits 31:16.  Both that pointer and the NEXT field
  ! of every header count 32-bit dwords, so a byte step is value * 4; NEXT = 0
  ! ends the walk.
  integer(c_int32_t), parameter :: FK_XHCI_XECP_ID_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_ID_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_NEXT_POS = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_NEXT_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_VAL_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_VAL_LEN = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_PTR_SHIFT = 2_c_int32_t

  ! Capability IDs, xhci-ext-caps.h:35-42.  ID 0 and IDs 6-9 are reserved.
  integer(c_int32_t), parameter :: FK_XHCI_XECP_ID_LEGACY = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_ID_PROTOCOL = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_ID_PM = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_ID_VIRT = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_ID_ROUTE = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_ID_DEBUG = 10_c_int32_t

  ! USB Legacy Support, xHCI 1.2 sections 7.1.1 and 7.1.2 (xhci-ext-caps.h:46-56).
  ! Offsets are from the start of the capability, not from the MMIO base.
  integer(c_int32_t), parameter :: FK_XHCI_XECP_LEGSUP_OFF = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_LEGCTLSTS_OFF = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_LEG_BIOS_OWNED_BIT = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_LEG_OS_OWNED_BIT = 24_c_int32_t

  ! Supported Protocol, xHCI 1.2 section 7.2 (xhci-ext-caps.h:95-105).  MAJOR and
  ! MINOR are in the header dword; NAME_OFF and PORTS_OFF are byte offsets from
  ! the start of the capability, and the port fields are read from the dword at
  ! PORTS_OFF.
  integer(c_int32_t), parameter :: FK_XHCI_XECP_PROTO_MINOR_POS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_PROTO_MINOR_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_PROTO_MAJOR_POS = 24_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_PROTO_MAJOR_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_PROTO_NAME_OFF = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_PROTO_PORTS_OFF = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_PROTO_PORT_OFF_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_PROTO_PORT_OFF_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_PROTO_PORT_CNT_POS = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_PROTO_PORT_CNT_LEN = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_PROTO_PSIC_POS = 28_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_XECP_PROTO_PSIC_LEN = 4_c_int32_t

end module fk_xhci_types_m
