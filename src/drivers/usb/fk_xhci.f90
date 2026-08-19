! SPDX-License-Identifier: GPL-2.0
! The xHCI host controller: reset, the rings, and a command that completes
! (roadmap 5.1).
!
! TWO KINDS OF MEMORY, and confusing them is the whole difficulty.  The
! REGISTERS are device memory behind BAR0, reached with fk_readl/fk_writel a
! whole dword at a time -- tools/mmiocheck.sh refuses anything narrower and a
! volatile Fortran pointer is exactly what it exists to refuse.  The RINGS are
! ordinary RAM that a bus master reads, so they are written through a Fortran
! pointer like any other array, and every address the controller is GIVEN is
! PHYSICAL while every address this module dereferences is VIRTUAL.
!
! THE RINGS GO THROUGH fk_readl/fk_writel TOO, and not because they are
! device registers -- they are RAM.  They are RAM a BUS MASTER writes, which
! gives the compiler exactly the freedom it must not have: gfortran narrowed
! the event TRB's control dword to a one-byte load the first time this was
! written through a Fortran pointer, and tools/mmiocheck.sh refused the
! object.  An opaque call can be neither narrowed nor reordered against the
! doorbell that follows it, which is the ordering the ring protocol needs.
!
! There is no 64-bit MMIO accessor in boot/io.S, so CRCR, DCBAAP, ERSTBA and
! ERDP are written as two dwords, low half first.  That intermediate state is
! visible to the controller, which is why every one of them is written while
! it is HALTED -- except ERDP, whose two halves are only ever advanced within
! one segment, so the high half never changes after the ring is armed.
module fk_xhci_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t
  use fk_xhci_types_m, only: FK_XHCI_CAP_LENGTH_OFF, FK_XHCI_CAP_HCS1_OFF, &
                             FK_XHCI_CAP_HCS2_OFF, FK_XHCI_CAP_DBOFF_OFF, &
                             FK_XHCI_CAP_RTSOFF_OFF, FK_XHCI_HCCPARAMS1_OFF, &
                             FK_XHCI_CAPLENGTH_POS, FK_XHCI_CAPLENGTH_LEN, &
                             FK_XHCI_HCIVERSION_POS, FK_XHCI_HCIVERSION_LEN, &
                             FK_XHCI_DBOFF_PTR_POS, FK_XHCI_RTSOFF_PTR_POS, &
                             FK_XHCI_HCS1_MAX_SLOTS_POS, &
                             FK_XHCI_HCS1_MAX_SLOTS_LEN, &
                             FK_XHCI_HCS1_MAX_INTRS_POS, &
                             FK_XHCI_HCS1_MAX_INTRS_LEN, &
                             FK_XHCI_HCS1_MAX_PORTS_POS, &
                             FK_XHCI_HCS1_MAX_PORTS_LEN, &
                             FK_XHCI_HCS2_ERST_MAX_POS, &
                             FK_XHCI_HCS2_ERST_MAX_LEN, &
                             FK_XHCI_HCS2_MAX_SP_HI_POS, &
                             FK_XHCI_HCS2_MAX_SP_HI_LEN, &
                             FK_XHCI_HCS2_MAX_SP_LO_POS, &
                             FK_XHCI_HCS2_MAX_SP_LO_LEN, &
                             FK_XHCI_HCC1_AC64_BIT, FK_XHCI_HCC1_CSZ_BIT, &
                             FK_XHCI_OP_USBCMD_OFF, FK_XHCI_OP_USBSTS_OFF, &
                             FK_XHCI_OP_PAGESIZE_OFF, FK_XHCI_OP_CRCR_OFF, &
                             FK_XHCI_OP_DCBAAP_OFF, FK_XHCI_OP_CONFIG_OFF, &
                             FK_XHCI_PAGESIZE_POS, FK_XHCI_PAGESIZE_LEN, &
                             FK_XHCI_USBCMD_RS_BIT, FK_XHCI_USBCMD_HCRST_BIT, &
                             FK_XHCI_USBCMD_INTE_BIT, FK_XHCI_USBSTS_HCH_BIT, &
                             FK_XHCI_USBSTS_CNR_BIT, FK_XHCI_USBSTS_HCE_BIT, &
                             FK_XHCI_CONFIG_MAXSLOTSEN_POS, &
                             FK_XHCI_CONFIG_MAXSLOTSEN_LEN, &
                             FK_XHCI_CRCR_RCS_BIT, &
                             FK_XHCI_RT_IR_BASE, FK_XHCI_IR_IMAN_OFF, &
                             FK_XHCI_IR_ERSTSZ_OFF, FK_XHCI_IR_ERSTBA_OFF, &
                             FK_XHCI_IR_ERDP_OFF, FK_XHCI_IMAN_IE_BIT, &
                             FK_XHCI_IMAN_IP_BIT, FK_XHCI_ERDP_EHB_BIT, &
                             FK_XHCI_DB_STRIDE, FK_XHCI_TRB_DWORDS, &
                             FK_XHCI_TRB_SIZE, &
                             FK_XHCI_TRB_CTRL_CYCLE_BIT, &
                             FK_XHCI_TRB_CTRL_TC_BIT, &
                             FK_XHCI_TRB_CTRL_TYPE_POS, &
                             FK_XHCI_TRB_CTRL_TYPE_LEN, &
                             FK_XHCI_TRB_TYPE_LINK, FK_XHCI_TRB_TYPE_CMD_NOOP, &
                             FK_XHCI_TRB_CEVT_COMP_POS, &
                             FK_XHCI_TRB_CEVT_COMP_LEN, &
                             FK_XHCI_OP_PORT_BASE, FK_XHCI_PORT_STRIDE, &
                             FK_XHCI_PORTSC_CCS_BIT, FK_XHCI_PORTSC_PED_BIT, &
                             FK_XHCI_PORTSC_PR_BIT, FK_XHCI_PORTSC_PRC_BIT, &
                             FK_XHCI_PORTSC_CSC_BIT, FK_XHCI_PORTSC_SPEED_POS, &
                             FK_XHCI_PORTSC_SPEED_LEN, &
                             FK_XHCI_PORTSC_PRESERVE, &
                             FK_XHCI_CTX_ENTRY_BYTES, &
                             FK_XHCI_ICTX_DROP_OFF, FK_XHCI_ICTX_ADD_OFF, &
                             FK_XHCI_ICTX_CFG_OFF, &
                             FK_XHCI_ICTX_CFG_VALUE_POS, &
                             FK_XHCI_ICTX_CFG_VALUE_LEN, &
                             FK_XHCI_ICTX_CFG_IFACE_POS, &
                             FK_XHCI_ICTX_CFG_IFACE_LEN, &
                             FK_XHCI_SLOT_SPEED_POS, FK_XHCI_SLOT_SPEED_LEN, &
                             FK_XHCI_SLOT_CTXENT_POS, FK_XHCI_SLOT_CTXENT_LEN, &
                             FK_XHCI_SLOT_RHPORT_POS, FK_XHCI_SLOT_RHPORT_LEN, &
                             FK_XHCI_SLOT_ADDR_POS, FK_XHCI_SLOT_ADDR_LEN, &
                             FK_XHCI_SLOT_STATE_POS, FK_XHCI_SLOT_STATE_LEN, &
                             FK_XHCI_EP_CERR_POS, FK_XHCI_EP_CERR_LEN, &
                             FK_XHCI_EP_TYPE_POS, FK_XHCI_EP_TYPE_LEN, &
                             FK_XHCI_EP_MAXPKT_POS, FK_XHCI_EP_MAXPKT_LEN, &
                             FK_XHCI_EP_INTERVAL_POS, FK_XHCI_EP_INTERVAL_LEN, &
                             FK_XHCI_EP_DCS_BIT, &
                             FK_XHCI_EP_AVGTRB_POS, FK_XHCI_EP_AVGTRB_LEN, &
                             FK_XHCI_EP_ESIT_LO_POS, FK_XHCI_EP_ESIT_LO_LEN, &
                             FK_XHCI_EP_TYPE_CONTROL, FK_XHCI_EP_TYPE_INT_IN, &
                             FK_XHCI_TRB_TYPE_ENABLE_SLOT, &
                             FK_XHCI_TRB_TYPE_ADDR_DEV, &
                             FK_XHCI_TRB_TYPE_CONFIG_EP, &
                             FK_XHCI_TRB_TYPE_NORMAL, FK_XHCI_TRB_TYPE_SETUP, &
                             FK_XHCI_TRB_TYPE_DATA, FK_XHCI_TRB_TYPE_STATUS, &
                             FK_XHCI_TRB_TYPE_TRANSFER, &
                             FK_XHCI_TRB_TYPE_COMPLETION, &
                             FK_XHCI_TRB_TYPE_PORT_STATUS, &
                             FK_XHCI_TRB_CTRL_IOC_BIT, &
                             FK_XHCI_TRB_CTRL_IDT_BIT, &
                             FK_XHCI_TRB_CTRL_ISP_BIT, &
                             FK_XHCI_TRB_CTRL_DIR_IN_BIT, &
                             FK_XHCI_TRB_TRT_POS, FK_XHCI_TRB_TRT_LEN, &
                             FK_XHCI_TRB_TRT_NO_DATA, FK_XHCI_TRB_TRT_OUT, &
                             FK_XHCI_TRB_TRT_IN, &
                             FK_XHCI_TRB_SLOT_ID_POS, FK_XHCI_TRB_SLOT_ID_LEN, &
                             FK_XHCI_TRB_EP_ID_POS, FK_XHCI_TRB_EP_ID_LEN, &
                             FK_XHCI_TRB_XEVT_LEN_POS, FK_XHCI_TRB_XEVT_LEN_LEN, &
                             FK_XHCI_COMP_SUCCESS, FK_XHCI_COMP_SHORT_PACKET, &
                             FK_XHCI_SPEED_HS, FK_XHCI_SPEED_SS, &
                             FK_XHCI_SPEED_SSP, FK_XHCI_MAX_SLOTS, &
                             FK_XHCI_ICTX_CTRL_IDX, &
                             FK_XHCI_ICTX_SLOT_IDX, &
                             FK_XHCI_TRB_SETUP_XFER_BYTES
  implicit none
  private
  public :: FK_XHCI_OK, FK_XHCI_E_NOBASE, FK_XHCI_E_HALT, FK_XHCI_E_RESET, &
            FK_XHCI_E_CNR, FK_XHCI_E_RUN, FK_XHCI_E_RING, FK_XHCI_E_NOEVENT, &
            FK_XHCI_SPIN_MAX
  public :: xhci_attach, xhci_op_base, xhci_rt_base, xhci_db_base
  public :: xhci_caplength, xhci_version, xhci_max_slots, xhci_max_intrs, &
            xhci_max_ports, xhci_max_scratchpads, xhci_erst_max, &
            xhci_page_size, xhci_ac64, xhci_csz
  public :: xhci_usbcmd, xhci_usbsts, xhci_halted, xhci_cnr, xhci_error
  public :: xhci_halt, xhci_reset, xhci_config_slots, xhci_set_dcbaap
  public :: xhci_cmd_ring_init, xhci_event_ring_init, xhci_intr_enable, &
            xhci_run
  public :: xhci_cmd_noop, xhci_doorbell, xhci_event_poll
  public :: xhci_event_type, xhci_event_comp, xhci_event_ptr, xhci_event_count
  public :: xhci_crcr, xhci_dcbaap, xhci_erdp

  ! roadmap 5.2
  public :: FK_XHCI_E_PORT, FK_XHCI_E_SPEED, FK_XHCI_E_CMD, FK_XHCI_E_XFER, &
            FK_XHCI_E_SLOT
  public :: xhci_ctx_stride, xhci_port_find, xhci_portsc, xhci_port_speed, &
            xhci_port_enabled, xhci_port_reset
  public :: xhci_intr_disable, xhci_evt_deq, xhci_evt_owner_isr
  public :: xhci_event_slot, xhci_event_epid, xhci_event_len
  public :: xhci_cmd_enable_slot, xhci_cmd_address_device, xhci_cmd_config_ep, &
            xhci_cmd_wait
  public :: xhci_ctx_zero, xhci_ictx_flags, xhci_ictx_config, &
            xhci_slot_ctx_init, xhci_ep_ctx_init, xhci_dev_ctx_slot_state, &
            xhci_dev_ctx_address
  public :: xhci_tr_init, xhci_tr_control, xhci_tr_normal, xhci_tr_phys, &
            xhci_drain, xhci_dcbaa_set

  integer(c_int32_t), parameter :: FK_XHCI_OK        = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_E_NOBASE  = -1_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_E_HALT    = -2_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_E_RESET   = -3_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_E_CNR     = -4_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_E_RUN     = -5_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_E_RING    = -6_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_E_NOEVENT = -7_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_E_PORT    = -8_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_E_SPEED   = -9_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_E_CMD     = -10_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_E_XFER    = -11_c_int32_t
  integer(c_int32_t), parameter :: FK_XHCI_E_SLOT    = -12_c_int32_t

  ! Two transfer rings: 1 is EP0's control ring, 2 is EP1 IN's.  Indexed rather
  ! than named because everything done to one is done to the other.
  integer(c_int32_t), parameter :: FK_XHCI_TR_MAX = 2_c_int32_t

  ! There is no timer in this path -- 3.7's tick is the only clock and it is
  ! not usable inside boot -- so every wait is a bounded spin on a register
  ! read.  A bound that is reached is a diagnostic, never a hang.
  integer(c_int32_t), parameter :: FK_XHCI_SPIN_MAX = 1000000_c_int32_t

  integer(c_int64_t), save :: cap_base = 0_c_int64_t
  integer(c_int64_t), save :: op_base  = 0_c_int64_t
  integer(c_int64_t), save :: rt_base  = 0_c_int64_t
  integer(c_int64_t), save :: db_base  = 0_c_int64_t

  integer(c_int64_t), save :: cmd_virt = 0_c_int64_t
  integer(c_int64_t), save :: cmd_phys = 0_c_int64_t
  integer(c_int32_t), save :: cmd_trbs = 0_c_int32_t
  integer(c_int32_t), save :: cmd_enq  = 0_c_int32_t
  integer(c_int32_t), save :: cmd_cyc  = 1_c_int32_t

  integer(c_int64_t), save :: evt_virt = 0_c_int64_t
  integer(c_int64_t), save :: evt_phys = 0_c_int64_t
  integer(c_int32_t), save :: evt_trbs = 0_c_int32_t
  integer(c_int32_t), save :: evt_deq  = 0_c_int32_t
  integer(c_int32_t), save :: evt_cyc  = 1_c_int32_t

  integer(c_int32_t), save :: ev_type = 0_c_int32_t
  integer(c_int32_t), save :: ev_comp = 0_c_int32_t
  integer(c_int64_t), save :: ev_ptr  = 0_c_int64_t
  integer(c_int32_t), save :: ev_seen = 0_c_int32_t
  integer(c_int32_t), save :: ev_slot = 0_c_int32_t
  integer(c_int32_t), save :: ev_epid = 0_c_int32_t
  integer(c_int32_t), save :: ev_len  = 0_c_int32_t

  integer(c_int64_t), save :: tr_virt(FK_XHCI_TR_MAX) = 0_c_int64_t
  integer(c_int64_t), save :: tr_phys(FK_XHCI_TR_MAX) = 0_c_int64_t
  integer(c_int32_t), save :: tr_trbs(FK_XHCI_TR_MAX) = 0_c_int32_t
  integer(c_int32_t), save :: tr_enq(FK_XHCI_TR_MAX)  = 0_c_int32_t
  integer(c_int32_t), save :: tr_cyc(FK_XHCI_TR_MAX)  = 1_c_int32_t

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

  ! VIRT is the mapped base of BAR0.  CAPLENGTH, DBOFF and RTSOFF are the only
  ! way to find the other three blocks: their positions are not architectural.
  function xhci_attach(virt) result(status) bind(c, name="xhci_attach")
    implicit none
    integer(c_int64_t), intent(in), value :: virt
    integer(c_int32_t) :: status, dw

    status = FK_XHCI_E_NOBASE
    cap_base = 0_c_int64_t
    if (virt == 0_c_int64_t) return

    dw = fk_readl(virt + int(FK_XHCI_CAP_LENGTH_OFF, c_int64_t))
    if (ibits(dw, FK_XHCI_CAPLENGTH_POS, FK_XHCI_CAPLENGTH_LEN) == 0) return

    cap_base = virt
    op_base = virt + int(ibits(dw, FK_XHCI_CAPLENGTH_POS, &
                               FK_XHCI_CAPLENGTH_LEN), c_int64_t)
    ! DBOFF and RTSOFF are offsets whose low bits are reserved, not shifts.
    rt_base = virt + int(iand(fk_readl(virt + &
                              int(FK_XHCI_CAP_RTSOFF_OFF, c_int64_t)), &
                              not(shiftl(1_c_int32_t, &
                                         FK_XHCI_RTSOFF_PTR_POS) - 1)), &
                         c_int64_t)
    db_base = virt + int(iand(fk_readl(virt + &
                              int(FK_XHCI_CAP_DBOFF_OFF, c_int64_t)), &
                              not(shiftl(1_c_int32_t, &
                                         FK_XHCI_DBOFF_PTR_POS) - 1)), &
                         c_int64_t)
    status = FK_XHCI_OK
  end function xhci_attach

  function xhci_op_base() result(v) bind(c, name="xhci_op_base")
    implicit none
    integer(c_int64_t) :: v

    v = op_base
  end function xhci_op_base

  function xhci_rt_base() result(v) bind(c, name="xhci_rt_base")
    implicit none
    integer(c_int64_t) :: v

    v = rt_base
  end function xhci_rt_base

  function xhci_db_base() result(v) bind(c, name="xhci_db_base")
    implicit none
    integer(c_int64_t) :: v

    v = db_base
  end function xhci_db_base

  function cap_dw(off) result(v)
    implicit none
    integer(c_int32_t), intent(in) :: off
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (cap_base == 0_c_int64_t) return
    v = fk_readl(cap_base + int(off, c_int64_t))
  end function cap_dw

  function op_dw(off) result(v)
    implicit none
    integer(c_int32_t), intent(in) :: off
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (op_base == 0_c_int64_t) return
    v = fk_readl(op_base + int(off, c_int64_t))
  end function op_dw

  function ir0(off) result(a)
    implicit none
    integer(c_int32_t), intent(in) :: off
    integer(c_int64_t) :: a

    a = rt_base + int(FK_XHCI_RT_IR_BASE, c_int64_t) + int(off, c_int64_t)
  end function ir0

  function xhci_caplength() result(v) bind(c, name="xhci_caplength")
    implicit none
    integer(c_int32_t) :: v

    v = ibits(cap_dw(FK_XHCI_CAP_LENGTH_OFF), FK_XHCI_CAPLENGTH_POS, &
              FK_XHCI_CAPLENGTH_LEN)
  end function xhci_caplength

  function xhci_version() result(v) bind(c, name="xhci_version")
    implicit none
    integer(c_int32_t) :: v

    v = ibits(cap_dw(FK_XHCI_CAP_LENGTH_OFF), FK_XHCI_HCIVERSION_POS, &
              FK_XHCI_HCIVERSION_LEN)
  end function xhci_version

  function xhci_max_slots() result(v) bind(c, name="xhci_max_slots")
    implicit none
    integer(c_int32_t) :: v

    v = ibits(cap_dw(FK_XHCI_CAP_HCS1_OFF), FK_XHCI_HCS1_MAX_SLOTS_POS, &
              FK_XHCI_HCS1_MAX_SLOTS_LEN)
  end function xhci_max_slots

  function xhci_max_intrs() result(v) bind(c, name="xhci_max_intrs")
    implicit none
    integer(c_int32_t) :: v

    v = ibits(cap_dw(FK_XHCI_CAP_HCS1_OFF), FK_XHCI_HCS1_MAX_INTRS_POS, &
              FK_XHCI_HCS1_MAX_INTRS_LEN)
  end function xhci_max_intrs

  function xhci_max_ports() result(v) bind(c, name="xhci_max_ports")
    implicit none
    integer(c_int32_t) :: v

    v = ibits(cap_dw(FK_XHCI_CAP_HCS1_OFF), FK_XHCI_HCS1_MAX_PORTS_POS, &
              FK_XHCI_HCS1_MAX_PORTS_LEN)
  end function xhci_max_ports

  ! TWO FIELDS, NOT ADJACENT, and the high one is the more significant five
  ! bits: N = HI*32 + LO.  Reading either half alone gives a plausible small
  ! number and an array the controller will run off the end of.
  function xhci_max_scratchpads() result(v) &
       bind(c, name="xhci_max_scratchpads")
    implicit none
    integer(c_int32_t) :: v, dw

    dw = cap_dw(FK_XHCI_CAP_HCS2_OFF)
    v = shiftl(ibits(dw, FK_XHCI_HCS2_MAX_SP_HI_POS, &
                     FK_XHCI_HCS2_MAX_SP_HI_LEN), 5) + &
        ibits(dw, FK_XHCI_HCS2_MAX_SP_LO_POS, FK_XHCI_HCS2_MAX_SP_LO_LEN)
  end function xhci_max_scratchpads

  ! The FIELD is an exponent: the ERST may hold 2**value entries.
  function xhci_erst_max() result(v) bind(c, name="xhci_erst_max")
    implicit none
    integer(c_int32_t) :: v

    v = shiftl(1_c_int32_t, ibits(cap_dw(FK_XHCI_CAP_HCS2_OFF), &
                                  FK_XHCI_HCS2_ERST_MAX_POS, &
                                  FK_XHCI_HCS2_ERST_MAX_LEN))
  end function xhci_erst_max

  ! PAGESIZE is a BITMAP of supported sizes, not a size.  Bit n means 2**(n+12).
  function xhci_page_size() result(v) bind(c, name="xhci_page_size")
    implicit none
    integer(c_int32_t) :: v, bits, i

    v = 0_c_int32_t
    bits = ibits(op_dw(FK_XHCI_OP_PAGESIZE_OFF), FK_XHCI_PAGESIZE_POS, &
                 FK_XHCI_PAGESIZE_LEN)
    do i = 0_c_int32_t, FK_XHCI_PAGESIZE_LEN - 1_c_int32_t
       if (btest(bits, i)) then
          v = shiftl(1_c_int32_t, i + 12_c_int32_t)
          return
       end if
    end do
  end function xhci_page_size

  function xhci_ac64() result(v) bind(c, name="xhci_ac64")
    implicit none
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (btest(cap_dw(FK_XHCI_HCCPARAMS1_OFF), FK_XHCI_HCC1_AC64_BIT)) &
         v = 1_c_int32_t
  end function xhci_ac64

  function xhci_csz() result(v) bind(c, name="xhci_csz")
    implicit none
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (btest(cap_dw(FK_XHCI_HCCPARAMS1_OFF), FK_XHCI_HCC1_CSZ_BIT)) &
         v = 1_c_int32_t
  end function xhci_csz

  function xhci_usbcmd() result(v) bind(c, name="xhci_usbcmd")
    implicit none
    integer(c_int32_t) :: v

    v = op_dw(FK_XHCI_OP_USBCMD_OFF)
  end function xhci_usbcmd

  function xhci_usbsts() result(v) bind(c, name="xhci_usbsts")
    implicit none
    integer(c_int32_t) :: v

    v = op_dw(FK_XHCI_OP_USBSTS_OFF)
  end function xhci_usbsts

  function xhci_halted() result(v) bind(c, name="xhci_halted")
    implicit none
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (btest(xhci_usbsts(), FK_XHCI_USBSTS_HCH_BIT)) v = 1_c_int32_t
  end function xhci_halted

  function xhci_cnr() result(v) bind(c, name="xhci_cnr")
    implicit none
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (btest(xhci_usbsts(), FK_XHCI_USBSTS_CNR_BIT)) v = 1_c_int32_t
  end function xhci_cnr

  function xhci_error() result(v) bind(c, name="xhci_error")
    implicit none
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (btest(xhci_usbsts(), FK_XHCI_USBSTS_HCE_BIT)) v = 1_c_int32_t
  end function xhci_error

  ! USBCMD IS READ-MODIFY-WRITTEN and USBSTS is NEVER: the status register's
  ! HSE, EINT, PCD and SRE bits are write-1-to-clear, so writing back what was
  ! read acknowledges conditions nothing has looked at.
  subroutine cmd_set(bit, on)
    implicit none
    integer(c_int32_t), intent(in) :: bit
    logical, intent(in) :: on
    integer(c_int32_t) :: v

    v = op_dw(FK_XHCI_OP_USBCMD_OFF)
    if (on) then
       v = ibset(v, bit)
    else
       v = ibclr(v, bit)
    end if
    call fk_writel(op_base + int(FK_XHCI_OP_USBCMD_OFF, c_int64_t), v)
  end subroutine cmd_set

  function xhci_halt() result(status) bind(c, name="xhci_halt")
    implicit none
    integer(c_int32_t) :: status, i

    status = FK_XHCI_E_NOBASE
    if (op_base == 0_c_int64_t) return

    call cmd_set(FK_XHCI_USBCMD_RS_BIT, .false.)
    status = FK_XHCI_E_HALT
    do i = 1_c_int32_t, FK_XHCI_SPIN_MAX
       if (xhci_halted() == 1_c_int32_t) then
          status = FK_XHCI_OK
          return
       end if
    end do
  end function xhci_halt

  ! THE CONTROLLER MUST BE HALTED FIRST.  Resetting a running controller is
  ! undefined, and this one has already been driven by firmware: SeaBIOS
  ! leaves CRCR, DCBAAP, ERSTBA and ERDP pointing into memory the PMM is about
  ! to hand out again, which is exactly what the reset is for.
  !
  ! Two waits, in this order: HCRST is self-clearing, and until USBSTS.CNR
  ! reads 0 no operational register other than USBSTS may be touched.
  function xhci_reset() result(status) bind(c, name="xhci_reset")
    implicit none
    integer(c_int32_t) :: status, i

    status = FK_XHCI_E_NOBASE
    if (op_base == 0_c_int64_t) return
    if (xhci_halted() /= 1_c_int32_t) then
       status = xhci_halt()
       if (status /= FK_XHCI_OK) return
    end if

    call cmd_set(FK_XHCI_USBCMD_HCRST_BIT, .true.)

    status = FK_XHCI_E_RESET
    do i = 1_c_int32_t, FK_XHCI_SPIN_MAX
       if (.not. btest(op_dw(FK_XHCI_OP_USBCMD_OFF), &
                       FK_XHCI_USBCMD_HCRST_BIT)) then
          status = FK_XHCI_OK
          exit
       end if
    end do
    if (status /= FK_XHCI_OK) return

    status = FK_XHCI_E_CNR
    do i = 1_c_int32_t, FK_XHCI_SPIN_MAX
       if (xhci_cnr() == 0_c_int32_t) then
          status = FK_XHCI_OK
          return
       end if
    end do
  end function xhci_reset

  function xhci_config_slots(n) result(status) &
       bind(c, name="xhci_config_slots")
    implicit none
    integer(c_int32_t), intent(in), value :: n
    integer(c_int32_t) :: status, v

    status = FK_XHCI_E_NOBASE
    if (op_base == 0_c_int64_t) return
    if (n < 0_c_int32_t .or. n > xhci_max_slots()) then
       status = FK_XHCI_E_RING
       return
    end if
    v = op_dw(FK_XHCI_OP_CONFIG_OFF)
    call mvbits(n, 0_c_int32_t, FK_XHCI_CONFIG_MAXSLOTSEN_LEN, v, &
                FK_XHCI_CONFIG_MAXSLOTSEN_POS)
    call fk_writel(op_base + int(FK_XHCI_OP_CONFIG_OFF, c_int64_t), v)
    status = FK_XHCI_OK
  end function xhci_config_slots

  ! A 64-bit register, low half first, and never a read-modify-write: on real
  ! hardware CRCR's pointer field READS AS ZERO, so an RMW writes back a null
  ! pointer.  On this model it reads back what firmware left, which is how
  ! that mistake survives a gate.  The value is composed from scratch.
  subroutine write64(addr, v)
    implicit none
    integer(c_int64_t), intent(in) :: addr, v

    call fk_writel(addr, int(iand(v, int(z'FFFFFFFF', c_int64_t)), c_int32_t))
    call fk_writel(addr + 4_c_int64_t, &
                   int(iand(shiftr(v, 32), int(z'FFFFFFFF', c_int64_t)), &
                       c_int32_t))
  end subroutine write64

  function read64(addr) result(v)
    implicit none
    integer(c_int64_t), intent(in) :: addr
    integer(c_int64_t) :: v

    v = ior(iand(int(fk_readl(addr), c_int64_t), int(z'FFFFFFFF', c_int64_t)), &
            shiftl(iand(int(fk_readl(addr + 4_c_int64_t), c_int64_t), &
                        int(z'FFFFFFFF', c_int64_t)), 32))
  end function read64

  function xhci_set_dcbaap(phys) result(status) &
       bind(c, name="xhci_set_dcbaap")
    implicit none
    integer(c_int64_t), intent(in), value :: phys
    integer(c_int32_t) :: status

    status = FK_XHCI_E_NOBASE
    if (op_base == 0_c_int64_t) return
    if (iand(phys, 63_c_int64_t) /= 0_c_int64_t) then
       status = FK_XHCI_E_RING
       return
    end if
    call write64(op_base + int(FK_XHCI_OP_DCBAAP_OFF, c_int64_t), phys)
    status = FK_XHCI_OK
  end function xhci_set_dcbaap

  function trb_at(base, idx) result(a)
    implicit none
    integer(c_int64_t), intent(in) :: base
    integer(c_int32_t), intent(in) :: idx
    integer(c_int64_t) :: a

    a = base + int(idx, c_int64_t) * int(FK_XHCI_TRB_SIZE, c_int64_t)
  end function trb_at

  subroutine trb_write(base, idx, plo, phi, sts, ctrl)
    implicit none
    integer(c_int64_t), intent(in) :: base
    integer(c_int32_t), intent(in) :: idx, plo, phi, sts, ctrl
    integer(c_int64_t) :: a

    a = trb_at(base, idx)
    call fk_writel(a, plo)
    call fk_writel(a + 4_c_int64_t, phi)
    call fk_writel(a + 8_c_int64_t, sts)
    ! THE CYCLE BIT LAST, and through a call the compiler cannot see past: it
    ! is what hands the TRB to the controller, and a controller that sees it
    ! before the rest of the TRB is in memory executes a half-written command.
    call fk_writel(a + 12_c_int64_t, ctrl)
  end subroutine trb_write

  subroutine trb_zero(base, trbs)
    implicit none
    integer(c_int64_t), intent(in) :: base
    integer(c_int32_t), intent(in) :: trbs
    integer(c_int32_t) :: i

    do i = 0_c_int32_t, trbs - 1_c_int32_t
       call trb_write(base, i, 0_c_int32_t, 0_c_int32_t, 0_c_int32_t, &
                      0_c_int32_t)
    end do
  end subroutine trb_zero

  ! ZEROED, then a LINK TRB in the last slot pointing back at the start with
  ! Toggle Cycle set.  Without TC the controller wraps without flipping its own
  ! cycle state, believes it owns nothing, and the ring goes silent after
  ! exactly one lap -- with no error anywhere.
  function xhci_cmd_ring_init(virt, phys, trbs) result(status) &
       bind(c, name="xhci_cmd_ring_init")
    implicit none
    integer(c_int64_t), intent(in), value :: virt, phys
    integer(c_int32_t), intent(in), value :: trbs
    integer(c_int32_t) :: status, ctrl

    status = FK_XHCI_E_RING
    if (virt == 0_c_int64_t .or. trbs < 2_c_int32_t) return
    if (iand(phys, 63_c_int64_t) /= 0_c_int64_t) return
    if (op_base == 0_c_int64_t) then
       status = FK_XHCI_E_NOBASE
       return
    end if

    call trb_zero(virt, trbs)

    cmd_virt = virt
    cmd_phys = phys
    cmd_trbs = trbs
    cmd_enq  = 0_c_int32_t
    cmd_cyc  = 1_c_int32_t

    ctrl = ior(shiftl(int(FK_XHCI_TRB_TYPE_LINK, c_int32_t), &
                      FK_XHCI_TRB_CTRL_TYPE_POS), &
               ibset(0_c_int32_t, FK_XHCI_TRB_CTRL_TC_BIT))
    ctrl = ibset(ctrl, FK_XHCI_TRB_CTRL_CYCLE_BIT)
    call trb_write(virt, trbs - 1_c_int32_t, &
                   int(iand(phys, int(z'FFFFFFFF', c_int64_t)), c_int32_t), &
                   int(shiftr(phys, 32), c_int32_t), 0_c_int32_t, ctrl)

    ! RCS must match the cycle the ring's TRBs are written with, or the
    ! controller believes every TRB belongs to software and executes nothing.
    call write64(op_base + int(FK_XHCI_OP_CRCR_OFF, c_int64_t), &
                 ior(phys, ibset(0_c_int64_t, FK_XHCI_CRCR_RCS_BIT)))
    status = FK_XHCI_OK
  end function xhci_cmd_ring_init

  ! THE EVENT RING HAS NO LINK TRB.  Its extent is the ERST entry's size and
  ! nothing else; a link TRB in it is just an event-shaped TRB the controller
  ! will overwrite.
  !
  ! ERSTSZ before ERSTBA: the controller may begin using the table the moment
  ! its base is written, and a base with a stale size is a table of the wrong
  ! length.
  function xhci_event_ring_init(seg_virt, seg_phys, trbs, erst_virt, &
                                erst_phys) result(status) &
       bind(c, name="xhci_event_ring_init")
    implicit none
    integer(c_int64_t), intent(in), value :: seg_virt, seg_phys, erst_virt, &
                                             erst_phys
    integer(c_int32_t), intent(in), value :: trbs
    integer(c_int32_t) :: status

    status = FK_XHCI_E_RING
    if (seg_virt == 0_c_int64_t .or. erst_virt == 0_c_int64_t) return
    if (trbs < 16_c_int32_t) return
    if (iand(seg_phys, 63_c_int64_t) /= 0_c_int64_t) return
    if (iand(erst_phys, 63_c_int64_t) /= 0_c_int64_t) return
    if (rt_base == 0_c_int64_t) then
       status = FK_XHCI_E_NOBASE
       return
    end if

    call trb_zero(seg_virt, trbs)

    ! The ERST entry is the same 16 bytes in the same order, so the TRB writer
    ! lays it down: segment base, its length in TRBs, reserved.
    call trb_write(erst_virt, 0_c_int32_t, &
                   int(iand(seg_phys, int(z'FFFFFFFF', c_int64_t)), c_int32_t), &
                   int(shiftr(seg_phys, 32), c_int32_t), trbs, 0_c_int32_t)

    evt_virt = seg_virt
    evt_phys = seg_phys
    evt_trbs = trbs
    evt_deq  = 0_c_int32_t
    evt_cyc  = 1_c_int32_t
    ev_seen  = 0_c_int32_t

    ! ERSTSZ COUNTS SEGMENTS, NOT TRBs.  The segment's length in TRBs is the
    ! ERST entry's own field, written above; putting it here instead declares
    ! a table of 256 segments on a controller whose HCSPARAMS2 allows one, and
    ! this one answers that by setting USBSTS.HCE and executing nothing.
    call fk_writel(ir0(FK_XHCI_IR_ERSTSZ_OFF), 1_c_int32_t)
    call write64(ir0(FK_XHCI_IR_ERSTBA_OFF), erst_phys)
    ! ERDP starts at the segment's base.  EHB is write-1-to-clear and is
    ! cleared here so the first event can raise an interrupt.
    call write64(ir0(FK_XHCI_IR_ERDP_OFF), &
                 ior(seg_phys, ibset(0_c_int64_t, FK_XHCI_ERDP_EHB_BIT)))
    status = FK_XHCI_OK
  end function xhci_event_ring_init

  ! BOTH GATES, and they are not the same one.  IMAN.IE arms this interrupter;
  ! USBCMD.INTE arms the controller's interrupts as a whole.  Either one clear
  ! and the event is posted with no message sent and no error reported.
  function xhci_intr_enable() result(status) bind(c, name="xhci_intr_enable")
    implicit none
    integer(c_int32_t) :: status, v

    status = FK_XHCI_E_NOBASE
    if (rt_base == 0_c_int64_t .or. op_base == 0_c_int64_t) return

    v = fk_readl(ir0(FK_XHCI_IR_IMAN_OFF))
    ! IP is write-1-to-clear and is cleared here deliberately: a pending bit
    ! left over from firmware suppresses the next message on some models.
    v = ibset(v, FK_XHCI_IMAN_IE_BIT)
    v = ibset(v, FK_XHCI_IMAN_IP_BIT)
    call fk_writel(ir0(FK_XHCI_IR_IMAN_OFF), v)

    call cmd_set(FK_XHCI_USBCMD_INTE_BIT, .true.)
    status = FK_XHCI_OK
  end function xhci_intr_enable

  function xhci_run() result(status) bind(c, name="xhci_run")
    implicit none
    integer(c_int32_t) :: status, i

    status = FK_XHCI_E_NOBASE
    if (op_base == 0_c_int64_t) return

    call cmd_set(FK_XHCI_USBCMD_RS_BIT, .true.)
    status = FK_XHCI_E_RUN
    do i = 1_c_int32_t, FK_XHCI_SPIN_MAX
       if (xhci_halted() == 0_c_int32_t) then
          status = FK_XHCI_OK
          return
       end if
    end do
  end function xhci_run

  subroutine xhci_doorbell(slot, target) bind(c, name="xhci_doorbell")
    implicit none
    integer(c_int32_t), intent(in), value :: slot, target

    if (db_base == 0_c_int64_t) return
    call fk_writel(db_base + int(slot * FK_XHCI_DB_STRIDE, c_int64_t), target)
  end subroutine xhci_doorbell

  ! Returns the PHYSICAL address of the TRB it enqueued, which is what the
  ! completion event will name, or 0.
  function cmd_push(plo, phi, sts, ttype, extra) result(trb_phys)
    implicit none
    integer(c_int32_t), intent(in) :: plo, phi, sts, ttype, extra
    integer(c_int64_t) :: trb_phys
    integer(c_int32_t) :: ctrl, link_ctrl

    trb_phys = 0_c_int64_t
    if (cmd_virt == 0_c_int64_t) return
    ! The last slot is the link TRB and is never a command.
    if (cmd_enq >= cmd_trbs - 1_c_int32_t) return

    ctrl = ior(shiftl(ttype, FK_XHCI_TRB_CTRL_TYPE_POS), extra)
    if (cmd_cyc == 1_c_int32_t) ctrl = ibset(ctrl, FK_XHCI_TRB_CTRL_CYCLE_BIT)
    call trb_write(cmd_virt, cmd_enq, plo, phi, sts, ctrl)

    trb_phys = trb_at(cmd_phys, cmd_enq)
    cmd_enq = cmd_enq + 1_c_int32_t

    ! At the link TRB the producer hands the ring back to itself: the link's
    ! own cycle bit is republished with the current state, then the state
    ! flips, because the controller flips its own on Toggle Cycle.
    if (cmd_enq == cmd_trbs - 1_c_int32_t) then
       link_ctrl = ior(shiftl(int(FK_XHCI_TRB_TYPE_LINK, c_int32_t), &
                              FK_XHCI_TRB_CTRL_TYPE_POS), &
                       ibset(0_c_int32_t, FK_XHCI_TRB_CTRL_TC_BIT))
       if (cmd_cyc == 1_c_int32_t) &
            link_ctrl = ibset(link_ctrl, FK_XHCI_TRB_CTRL_CYCLE_BIT)
       call trb_write(cmd_virt, cmd_trbs - 1_c_int32_t, &
                      int(iand(cmd_phys, int(z'FFFFFFFF', c_int64_t)), &
                          c_int32_t), &
                      int(shiftr(cmd_phys, 32), c_int32_t), 0_c_int32_t, &
                      link_ctrl)
       cmd_enq = 0_c_int32_t
       cmd_cyc = 1_c_int32_t - cmd_cyc
    end if
  end function cmd_push

  function xhci_cmd_noop() result(trb_phys) bind(c, name="xhci_cmd_noop")
    implicit none
    integer(c_int64_t) :: trb_phys

    trb_phys = cmd_push(0_c_int32_t, 0_c_int32_t, 0_c_int32_t, &
                        int(FK_XHCI_TRB_TYPE_CMD_NOOP, c_int32_t), 0_c_int32_t)
  end function xhci_cmd_noop

  ! One event, or FK_XHCI_E_NOEVENT.  The cycle bit is the whole protocol: a
  ! TRB whose cycle does not match the consumer's state has not been written
  ! by the controller yet, and on the first lap of a zeroed segment that is
  ! indistinguishable from an empty ring -- which is correct, because it is.
  function xhci_event_poll() result(status) bind(c, name="xhci_event_poll")
    implicit none
    integer(c_int32_t) :: status, ctrl
    integer(c_int64_t) :: a

    status = FK_XHCI_E_RING
    if (evt_virt == 0_c_int64_t) return

    a = trb_at(evt_virt, evt_deq)
    ctrl = fk_readl(a + 12_c_int64_t)

    status = FK_XHCI_E_NOEVENT
    if (btest(ctrl, FK_XHCI_TRB_CTRL_CYCLE_BIT)) then
       if (evt_cyc /= 1_c_int32_t) return
    else
       if (evt_cyc /= 0_c_int32_t) return
    end if

    ev_type = ibits(ctrl, FK_XHCI_TRB_CTRL_TYPE_POS, FK_XHCI_TRB_CTRL_TYPE_LEN)
    ev_comp = ibits(fk_readl(a + 8_c_int64_t), FK_XHCI_TRB_CEVT_COMP_POS, &
                    FK_XHCI_TRB_CEVT_COMP_LEN)
    ev_ptr = ior(iand(int(fk_readl(a), c_int64_t), &
                      int(z'FFFFFFFF', c_int64_t)), &
                 shiftl(iand(int(fk_readl(a + 4_c_int64_t), c_int64_t), &
                             int(z'FFFFFFFF', c_int64_t)), 32))
    ! roadmap 5.2.  Slot and endpoint live in the CONTROL dword of a transfer
    ! or command completion event, and the residual length in the status dword
    ! next to the completion code.  A command completion has no endpoint, so
    ! ev_epid is 0 there and the caller has the event type to tell them apart.
    ev_slot = ibits(ctrl, FK_XHCI_TRB_SLOT_ID_POS, FK_XHCI_TRB_SLOT_ID_LEN)
    ev_epid = ibits(ctrl, FK_XHCI_TRB_EP_ID_POS, FK_XHCI_TRB_EP_ID_LEN)
    ev_len = ibits(fk_readl(a + 8_c_int64_t), FK_XHCI_TRB_XEVT_LEN_POS, &
                   FK_XHCI_TRB_XEVT_LEN_LEN)
    ev_seen = ev_seen + 1_c_int32_t

    evt_deq = evt_deq + 1_c_int32_t
    if (evt_deq >= evt_trbs) then
       evt_deq = 0_c_int32_t
       evt_cyc = 1_c_int32_t - evt_cyc
    end if

    ! EHB is written as 1 to CLEAR it -- write-1-to-clear -- and the pointer
    ! must ADVANCE, which is why this is composed rather than read-modified.
    call write64(ir0(FK_XHCI_IR_ERDP_OFF), &
                 ior(trb_at(evt_phys, evt_deq), &
                     ibset(0_c_int64_t, FK_XHCI_ERDP_EHB_BIT)))
    status = FK_XHCI_OK
  end function xhci_event_poll

  function xhci_event_type() result(v) bind(c, name="xhci_event_type")
    implicit none
    integer(c_int32_t) :: v

    v = ev_type
  end function xhci_event_type

  function xhci_event_comp() result(v) bind(c, name="xhci_event_comp")
    implicit none
    integer(c_int32_t) :: v

    v = ev_comp
  end function xhci_event_comp

  ! Bits 63:4 -- the low four are not address bits.
  function xhci_event_ptr() result(v) bind(c, name="xhci_event_ptr")
    implicit none
    integer(c_int64_t) :: v

    v = iand(ev_ptr, not(15_c_int64_t))
  end function xhci_event_ptr

  function xhci_event_count() result(v) bind(c, name="xhci_event_count")
    implicit none
    integer(c_int32_t) :: v

    v = ev_seen
  end function xhci_event_count

  function xhci_crcr() result(v) bind(c, name="xhci_crcr")
    implicit none
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (op_base == 0_c_int64_t) return
    v = read64(op_base + int(FK_XHCI_OP_CRCR_OFF, c_int64_t))
  end function xhci_crcr

  function xhci_dcbaap() result(v) bind(c, name="xhci_dcbaap")
    implicit none
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (op_base == 0_c_int64_t) return
    v = read64(op_base + int(FK_XHCI_OP_DCBAAP_OFF, c_int64_t))
  end function xhci_dcbaap

  function xhci_erdp() result(v) bind(c, name="xhci_erdp")
    implicit none
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (rt_base == 0_c_int64_t) return
    v = read64(ir0(FK_XHCI_IR_ERDP_OFF))
  end function xhci_erdp

  ! ==== roadmap 5.2 ==========================================================

  function xhci_ctx_stride() result(v) bind(c, name="xhci_ctx_stride")
    implicit none
    integer(c_int32_t) :: v

    v = shiftl(FK_XHCI_CTX_ENTRY_BYTES, xhci_csz())
  end function xhci_ctx_stride

  function port_addr(port) result(a)
    implicit none
    integer(c_int32_t), intent(in) :: port
    integer(c_int64_t) :: a

    a = op_base + int(FK_XHCI_OP_PORT_BASE, c_int64_t) + &
        int((port - 1_c_int32_t) * FK_XHCI_PORT_STRIDE, c_int64_t)
  end function port_addr

  function xhci_portsc(port) result(v) bind(c, name="xhci_portsc")
    implicit none
    integer(c_int32_t), intent(in), value :: port
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (op_base == 0_c_int64_t) return
    if (port < 1_c_int32_t .or. port > xhci_max_ports()) return
    v = fk_readl(port_addr(port))
  end function xhci_portsc

  ! NEVER A READ-MODIFY-WRITE.  PORTSC carries seven write-1-to-clear change
  ! bits and PED, which is write-1-to-DISABLE, interleaved with ordinary state.
  ! Writing back what was read therefore disables the port and acknowledges
  ! every change nobody has looked at.  This composes instead: the preserved
  ! bits, plus exactly the bits the caller asked for.
  subroutine portsc_write(port, bits)
    implicit none
    integer(c_int32_t), intent(in) :: port, bits

    call fk_writel(port_addr(port), &
                   ior(iand(fk_readl(port_addr(port)), &
                            FK_XHCI_PORTSC_PRESERVE), bits))
  end subroutine portsc_write

  ! The first port reporting a device.  The number is NOT known in advance:
  ! qemu-xhci presents its USB3 ports first, so a full-speed or high-speed
  ! device lands part way up the array and a hardcoded port 1 finds nothing.
  function xhci_port_find() result(port) bind(c, name="xhci_port_find")
    implicit none
    integer(c_int32_t) :: port, i

    port = 0_c_int32_t
    if (op_base == 0_c_int64_t) return
    do i = 1_c_int32_t, xhci_max_ports()
       if (btest(xhci_portsc(i), FK_XHCI_PORTSC_CCS_BIT)) then
          port = i
          return
       end if
    end do
  end function xhci_port_find

  function xhci_port_speed(port) result(v) bind(c, name="xhci_port_speed")
    implicit none
    integer(c_int32_t), intent(in), value :: port
    integer(c_int32_t) :: v

    v = ibits(xhci_portsc(port), FK_XHCI_PORTSC_SPEED_POS, &
              FK_XHCI_PORTSC_SPEED_LEN)
  end function xhci_port_speed

  function xhci_port_enabled(port) result(v) bind(c, name="xhci_port_enabled")
    implicit none
    integer(c_int32_t), intent(in), value :: port
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (btest(xhci_portsc(port), FK_XHCI_PORTSC_PED_BIT)) v = 1_c_int32_t
  end function xhci_port_enabled

  ! A USB2 port comes up Connected but NOT Enabled -- it sits in Polling until
  ! it is reset, and no transfer of any kind works before that.  The reset is
  ! what moves it to Enabled, and PED is the controller's answer, not ours: it
  ! is read-only to software in the direction that matters here.
  function xhci_port_reset(port) result(status) bind(c, name="xhci_port_reset")
    implicit none
    integer(c_int32_t), intent(in), value :: port
    integer(c_int32_t) :: status, i

    status = FK_XHCI_E_NOBASE
    if (op_base == 0_c_int64_t) return
    status = FK_XHCI_E_PORT
    if (port < 1_c_int32_t .or. port > xhci_max_ports()) return
    if (.not. btest(xhci_portsc(port), FK_XHCI_PORTSC_CCS_BIT)) return

    call portsc_write(port, ibset(0_c_int32_t, FK_XHCI_PORTSC_PR_BIT))

    do i = 1_c_int32_t, FK_XHCI_SPIN_MAX
       if (btest(xhci_portsc(port), FK_XHCI_PORTSC_PRC_BIT)) exit
    end do

    ! Acknowledge the reset and the connect, and ONLY those two: a write of 1
    ! to a change bit clears it, and the preserve mask keeps PED out of the
    ! value so this does not disable the port it has just enabled.
    call portsc_write(port, ior(ibset(0_c_int32_t, FK_XHCI_PORTSC_PRC_BIT), &
                                ibset(0_c_int32_t, FK_XHCI_PORTSC_CSC_BIT)))

    status = FK_XHCI_E_PORT
    if (xhci_port_enabled(port) == 1_c_int32_t) status = FK_XHCI_OK
  end function xhci_port_reset

  ! The mirror of xhci_intr_enable, and 5.2's first act.  Enumeration polls the
  ! event ring; the handler drains it once EP1 is armed.  One consumer at every
  ! instant, and the ring has no way to arbitrate between two.
  function xhci_intr_disable() result(status) bind(c, name="xhci_intr_disable")
    implicit none
    integer(c_int32_t) :: status, v

    status = FK_XHCI_E_NOBASE
    if (rt_base == 0_c_int64_t) return

    v = fk_readl(ir0(FK_XHCI_IR_IMAN_OFF))
    v = ibclr(v, FK_XHCI_IMAN_IE_BIT)
    v = ibset(v, FK_XHCI_IMAN_IP_BIT)
    call fk_writel(ir0(FK_XHCI_IR_IMAN_OFF), v)
    status = FK_XHCI_OK
  end function xhci_intr_disable

  function xhci_evt_deq() result(v) bind(c, name="xhci_evt_deq")
    implicit none
    integer(c_int32_t) :: v

    v = evt_deq
  end function xhci_evt_deq

  function xhci_event_slot() result(v) bind(c, name="xhci_event_slot")
    implicit none
    integer(c_int32_t) :: v

    v = ev_slot
  end function xhci_event_slot

  function xhci_event_epid() result(v) bind(c, name="xhci_event_epid")
    implicit none
    integer(c_int32_t) :: v

    v = ev_epid
  end function xhci_event_epid

  function xhci_event_len() result(v) bind(c, name="xhci_event_len")
    implicit none
    integer(c_int32_t) :: v

    v = ev_len
  end function xhci_event_len

  function xhci_cmd_enable_slot() result(trb_phys) &
       bind(c, name="xhci_cmd_enable_slot")
    implicit none
    integer(c_int64_t) :: trb_phys

    trb_phys = cmd_push(0_c_int32_t, 0_c_int32_t, 0_c_int32_t, &
                        int(FK_XHCI_TRB_TYPE_ENABLE_SLOT, c_int32_t), &
                        0_c_int32_t)
  end function xhci_cmd_enable_slot

  function slot_field(slot) result(v)
    implicit none
    integer(c_int32_t), intent(in) :: slot
    integer(c_int32_t) :: v

    v = shiftl(iand(slot, shiftl(1_c_int32_t, FK_XHCI_TRB_SLOT_ID_LEN) - 1), &
               FK_XHCI_TRB_SLOT_ID_POS)
  end function slot_field

  function xhci_cmd_address_device(ictx_phys, slot) result(trb_phys) &
       bind(c, name="xhci_cmd_address_device")
    implicit none
    integer(c_int64_t), intent(in), value :: ictx_phys
    integer(c_int32_t), intent(in), value :: slot
    integer(c_int64_t) :: trb_phys

    trb_phys = 0_c_int64_t
    if (iand(ictx_phys, 15_c_int64_t) /= 0_c_int64_t) return
    ! BSR is deliberately CLEAR: this kernel wants the controller to issue
    ! SET_ADDRESS on the bus, not merely to move the slot to Default.
    trb_phys = cmd_push( &
         int(iand(ictx_phys, int(z'FFFFFFFF', c_int64_t)), c_int32_t), &
         int(shiftr(ictx_phys, 32), c_int32_t), 0_c_int32_t, &
         int(FK_XHCI_TRB_TYPE_ADDR_DEV, c_int32_t), slot_field(slot))
  end function xhci_cmd_address_device

  function xhci_cmd_config_ep(ictx_phys, slot) result(trb_phys) &
       bind(c, name="xhci_cmd_config_ep")
    implicit none
    integer(c_int64_t), intent(in), value :: ictx_phys
    integer(c_int32_t), intent(in), value :: slot
    integer(c_int64_t) :: trb_phys

    trb_phys = 0_c_int64_t
    if (iand(ictx_phys, 15_c_int64_t) /= 0_c_int64_t) return
    trb_phys = cmd_push( &
         int(iand(ictx_phys, int(z'FFFFFFFF', c_int64_t)), c_int32_t), &
         int(shiftr(ictx_phys, 32), c_int32_t), 0_c_int32_t, &
         int(FK_XHCI_TRB_TYPE_CONFIG_EP, c_int32_t), slot_field(slot))
  end function xhci_cmd_config_ep

  ! Spin until the event naming THIS TRB arrives.  Anything else on the ring is
  ! consumed and discarded, and there will be something else: resetting a port
  ! while the controller is running posts a Port Status Change event, and a
  ! waiter that treats the first event it sees as its answer reads a PSC event
  ! as a failed command.
  function xhci_cmd_wait(want) result(status) bind(c, name="xhci_cmd_wait")
    implicit none
    integer(c_int64_t), intent(in), value :: want
    integer(c_int32_t) :: status, st, i

    status = FK_XHCI_E_CMD
    if (want == 0_c_int64_t) return

    do i = 1_c_int32_t, FK_XHCI_SPIN_MAX
       st = xhci_event_poll()
       if (st /= FK_XHCI_OK) cycle
       if (ev_type /= FK_XHCI_TRB_TYPE_COMPLETION .and. &
           ev_type /= FK_XHCI_TRB_TYPE_TRANSFER) cycle
       if (xhci_event_ptr() /= want) cycle
       if (ev_comp == FK_XHCI_COMP_SUCCESS .or. &
           ev_comp == FK_XHCI_COMP_SHORT_PACKET) then
          status = FK_XHCI_OK
       else
          status = FK_XHCI_E_XFER
       end if
       return
    end do
  end function xhci_cmd_wait

  ! ---- contexts --------------------------------------------------------------
  ! An entry is 32 << CSZ bytes and every offset below is a dword INDEX within
  ! one, which is the same for both sizes.  Written through fk_writel like the
  ! rings, and for the ring's reason: this is memory a bus master reads.

  function ctx_addr(base, idx, dw) result(a)
    implicit none
    integer(c_int64_t), intent(in) :: base
    integer(c_int32_t), intent(in) :: idx, dw
    integer(c_int64_t) :: a

    a = base + int(idx * xhci_ctx_stride(), c_int64_t) + &
        int(dw * 4_c_int32_t, c_int64_t)
  end function ctx_addr

  subroutine xhci_ctx_zero(base, entries) bind(c, name="xhci_ctx_zero")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t), intent(in), value :: entries
    integer(c_int32_t) :: i, dw

    if (base == 0_c_int64_t) return
    do i = 0_c_int32_t, entries - 1_c_int32_t
       do dw = 0_c_int32_t, xhci_ctx_stride() / 4_c_int32_t - 1_c_int32_t
          call fk_writel(ctx_addr(base, i, dw), 0_c_int32_t)
       end do
    end do
  end subroutine xhci_ctx_zero

  ! Bit n of either word names DCI n, so bit 0 is the slot context and bit 1 is
  ! EP0.  An endpoint added without its bit set is an endpoint the controller
  ! does not look at, and Configure Endpoint returns success anyway.
  subroutine xhci_ictx_flags(base, add, drop) bind(c, name="xhci_ictx_flags")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t), intent(in), value :: add, drop

    call fk_writel(ctx_addr(base, FK_XHCI_ICTX_CTRL_IDX, &
                            FK_XHCI_ICTX_DROP_OFF), drop)
    call fk_writel(ctx_addr(base, FK_XHCI_ICTX_CTRL_IDX, &
                            FK_XHCI_ICTX_ADD_OFF), add)
  end subroutine xhci_ictx_flags

  subroutine xhci_ictx_config(base, value, iface) &
       bind(c, name="xhci_ictx_config")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t), intent(in), value :: value, iface
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    call mvbits(value, 0_c_int32_t, FK_XHCI_ICTX_CFG_VALUE_LEN, v, &
                FK_XHCI_ICTX_CFG_VALUE_POS)
    call mvbits(iface, 0_c_int32_t, FK_XHCI_ICTX_CFG_IFACE_LEN, v, &
                FK_XHCI_ICTX_CFG_IFACE_POS)
    call fk_writel(ctx_addr(base, FK_XHCI_ICTX_CTRL_IDX, &
                            FK_XHCI_ICTX_CFG_OFF), v)
  end subroutine xhci_ictx_config

  ! Context Entries is the index of the LAST valid endpoint, not a count of
  ! them, so a device with EP1 IN at DCI 3 puts 3 here.  Route string is zero:
  ! this device is on a root hub port, not behind one.
  subroutine xhci_slot_ctx_init(base, speed, port, ctxent) &
       bind(c, name="xhci_slot_ctx_init")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t), intent(in), value :: speed, port, ctxent
    integer(c_int32_t) :: dw0, dw1

    dw0 = 0_c_int32_t
    call mvbits(speed, 0_c_int32_t, FK_XHCI_SLOT_SPEED_LEN, dw0, &
                FK_XHCI_SLOT_SPEED_POS)
    call mvbits(ctxent, 0_c_int32_t, FK_XHCI_SLOT_CTXENT_LEN, dw0, &
                FK_XHCI_SLOT_CTXENT_POS)
    dw1 = 0_c_int32_t
    call mvbits(port, 0_c_int32_t, FK_XHCI_SLOT_RHPORT_LEN, dw1, &
                FK_XHCI_SLOT_RHPORT_POS)

    call fk_writel(ctx_addr(base, FK_XHCI_ICTX_SLOT_IDX, 0_c_int32_t), dw0)
    call fk_writel(ctx_addr(base, FK_XHCI_ICTX_SLOT_IDX, 1_c_int32_t), dw1)
    call fk_writel(ctx_addr(base, FK_XHCI_ICTX_SLOT_IDX, 2_c_int32_t), &
                   0_c_int32_t)
    call fk_writel(ctx_addr(base, FK_XHCI_ICTX_SLOT_IDX, 3_c_int32_t), &
                   0_c_int32_t)
  end subroutine xhci_slot_ctx_init

  ! DCI n lives at INPUT context entry n+1: the input control context is entry
  ! 0 and the slot context entry 1, so EP0 (DCI 1) is entry 2 and EP1 IN
  ! (DCI 3) is entry 4.
  subroutine xhci_ep_ctx_init(base, dci, eptype, maxpkt, interval, ring_phys) &
       bind(c, name="xhci_ep_ctx_init")
    implicit none
    integer(c_int64_t), intent(in), value :: base, ring_phys
    integer(c_int32_t), intent(in), value :: dci, eptype, maxpkt, interval
    integer(c_int32_t) :: dw0, dw1, dw2, dw4, idx

    idx = dci + 1_c_int32_t
    dw0 = 0_c_int32_t
    call mvbits(interval, 0_c_int32_t, FK_XHCI_EP_INTERVAL_LEN, dw0, &
                FK_XHCI_EP_INTERVAL_POS)
    dw1 = 0_c_int32_t
    ! Three retries before the controller gives up on a transaction.  Zero
    ! means "no limit" and is only legal for isochronous.
    call mvbits(3_c_int32_t, 0_c_int32_t, FK_XHCI_EP_CERR_LEN, dw1, &
                FK_XHCI_EP_CERR_POS)
    call mvbits(eptype, 0_c_int32_t, FK_XHCI_EP_TYPE_LEN, dw1, &
                FK_XHCI_EP_TYPE_POS)
    call mvbits(maxpkt, 0_c_int32_t, FK_XHCI_EP_MAXPKT_LEN, dw1, &
                FK_XHCI_EP_MAXPKT_POS)
    ! Bit 0 of the dequeue pointer is the Dequeue Cycle State, not an address
    ! bit: it tells the controller which polarity the producer is writing, and
    ! a fresh ring's producer writes 1.
    dw2 = ibset(int(iand(ring_phys, int(z'FFFFFFFF', c_int64_t)), c_int32_t), &
                FK_XHCI_EP_DCS_BIT)
    dw4 = 0_c_int32_t
    call mvbits(maxpkt, 0_c_int32_t, FK_XHCI_EP_AVGTRB_LEN, dw4, &
                FK_XHCI_EP_AVGTRB_POS)
    call mvbits(maxpkt, 0_c_int32_t, FK_XHCI_EP_ESIT_LO_LEN, dw4, &
                FK_XHCI_EP_ESIT_LO_POS)

    call fk_writel(ctx_addr(base, idx, 0_c_int32_t), dw0)
    call fk_writel(ctx_addr(base, idx, 1_c_int32_t), dw1)
    call fk_writel(ctx_addr(base, idx, 2_c_int32_t), dw2)
    call fk_writel(ctx_addr(base, idx, 3_c_int32_t), &
                   int(shiftr(ring_phys, 32), c_int32_t))
    call fk_writel(ctx_addr(base, idx, 4_c_int32_t), dw4)
  end subroutine xhci_ep_ctx_init

  ! Read out of the DEVICE context, which is the controller's copy: it writes
  ! the slot state and the address it assigned, and neither can be faked by a
  ! kernel that only wrote its input context.
  function xhci_dev_ctx_slot_state(base) result(v) &
       bind(c, name="xhci_dev_ctx_slot_state")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t) :: v

    v = ibits(fk_readl(ctx_addr(base, 0_c_int32_t, 3_c_int32_t)), &
              FK_XHCI_SLOT_STATE_POS, FK_XHCI_SLOT_STATE_LEN)
  end function xhci_dev_ctx_slot_state

  function xhci_dev_ctx_address(base) result(v) &
       bind(c, name="xhci_dev_ctx_address")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t) :: v

    v = ibits(fk_readl(ctx_addr(base, 0_c_int32_t, 3_c_int32_t)), &
              FK_XHCI_SLOT_ADDR_POS, FK_XHCI_SLOT_ADDR_LEN)
  end function xhci_dev_ctx_address

  ! ---- transfer rings --------------------------------------------------------

  function xhci_tr_init(i, virt, phys, trbs) result(status) &
       bind(c, name="xhci_tr_init")
    implicit none
    integer(c_int32_t), intent(in), value :: i, trbs
    integer(c_int64_t), intent(in), value :: virt, phys
    integer(c_int32_t) :: status, ctrl

    status = FK_XHCI_E_RING
    if (i < 1_c_int32_t .or. i > FK_XHCI_TR_MAX) return
    if (virt == 0_c_int64_t .or. trbs < 2_c_int32_t) return
    if (iand(phys, 63_c_int64_t) /= 0_c_int64_t) return

    call trb_zero(virt, trbs)
    tr_virt(i) = virt
    tr_phys(i) = phys
    tr_trbs(i) = trbs
    tr_enq(i)  = 0_c_int32_t
    tr_cyc(i)  = 1_c_int32_t

    ctrl = ior(shiftl(int(FK_XHCI_TRB_TYPE_LINK, c_int32_t), &
                      FK_XHCI_TRB_CTRL_TYPE_POS), &
               ibset(0_c_int32_t, FK_XHCI_TRB_CTRL_TC_BIT))
    ctrl = ibset(ctrl, FK_XHCI_TRB_CTRL_CYCLE_BIT)
    call trb_write(virt, trbs - 1_c_int32_t, &
                   int(iand(phys, int(z'FFFFFFFF', c_int64_t)), c_int32_t), &
                   int(shiftr(phys, 32), c_int32_t), 0_c_int32_t, ctrl)
    status = FK_XHCI_OK
  end function xhci_tr_init

  function xhci_tr_phys(i) result(v) bind(c, name="xhci_tr_phys")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (i >= 1_c_int32_t .and. i <= FK_XHCI_TR_MAX) v = tr_phys(i)
  end function xhci_tr_phys

  function tr_push(i, plo, phi, sts, ttype, extra) result(trb_phys)
    implicit none
    integer(c_int32_t), intent(in) :: i, plo, phi, sts, ttype, extra
    integer(c_int64_t) :: trb_phys
    integer(c_int32_t) :: ctrl, link_ctrl

    trb_phys = 0_c_int64_t
    if (tr_virt(i) == 0_c_int64_t) return
    if (tr_enq(i) >= tr_trbs(i) - 1_c_int32_t) return

    ctrl = ior(shiftl(ttype, FK_XHCI_TRB_CTRL_TYPE_POS), extra)
    if (tr_cyc(i) == 1_c_int32_t) ctrl = ibset(ctrl, FK_XHCI_TRB_CTRL_CYCLE_BIT)
    call trb_write(tr_virt(i), tr_enq(i), plo, phi, sts, ctrl)

    trb_phys = trb_at(tr_phys(i), tr_enq(i))
    tr_enq(i) = tr_enq(i) + 1_c_int32_t

    if (tr_enq(i) == tr_trbs(i) - 1_c_int32_t) then
       link_ctrl = ior(shiftl(int(FK_XHCI_TRB_TYPE_LINK, c_int32_t), &
                              FK_XHCI_TRB_CTRL_TYPE_POS), &
                       ibset(0_c_int32_t, FK_XHCI_TRB_CTRL_TC_BIT))
       if (tr_cyc(i) == 1_c_int32_t) &
            link_ctrl = ibset(link_ctrl, FK_XHCI_TRB_CTRL_CYCLE_BIT)
       call trb_write(tr_virt(i), tr_trbs(i) - 1_c_int32_t, &
                      int(iand(tr_phys(i), int(z'FFFFFFFF', c_int64_t)), &
                          c_int32_t), &
                      int(shiftr(tr_phys(i), 32), c_int32_t), 0_c_int32_t, &
                      link_ctrl)
       tr_enq(i) = 0_c_int32_t
       tr_cyc(i) = 1_c_int32_t - tr_cyc(i)
    end if
  end function tr_push

  ! A control transfer is up to three TRBs and only the LAST carries IOC, so
  ! one transfer event answers the whole thing and names the status TRB.  That
  ! address is the return value and it is what xhci_cmd_wait is given.
  !
  ! The setup packet travels IN THE TRB, not through a buffer: IDT means the
  ! parameter field IS the eight bytes.  The status stage runs in the OPPOSITE
  ! direction to the data stage, and IN when there is no data stage at all.
  function xhci_tr_control(i, setup_lo, setup_hi, buf_phys, wlength, dir_in) &
       result(trb_phys) bind(c, name="xhci_tr_control")
    implicit none
    integer(c_int32_t), intent(in), value :: i, setup_lo, setup_hi, wlength, &
                                             dir_in
    integer(c_int64_t), intent(in), value :: buf_phys
    integer(c_int64_t) :: trb_phys, ignored
    integer(c_int32_t) :: ctrl, trt

    trb_phys = 0_c_int64_t
    if (i < 1_c_int32_t .or. i > FK_XHCI_TR_MAX) return

    trt = FK_XHCI_TRB_TRT_NO_DATA
    if (wlength > 0_c_int32_t) then
       if (dir_in /= 0_c_int32_t) then
          trt = FK_XHCI_TRB_TRT_IN
       else
          trt = FK_XHCI_TRB_TRT_OUT
       end if
    end if

    ctrl = ibset(0_c_int32_t, FK_XHCI_TRB_CTRL_IDT_BIT)
    call mvbits(trt, 0_c_int32_t, FK_XHCI_TRB_TRT_LEN, ctrl, FK_XHCI_TRB_TRT_POS)
    ignored = tr_push(i, setup_lo, setup_hi, FK_XHCI_TRB_SETUP_XFER_BYTES, &
                      int(FK_XHCI_TRB_TYPE_SETUP, c_int32_t), ctrl)
    if (ignored == 0_c_int64_t) return

    if (wlength > 0_c_int32_t) then
       ctrl = ibset(0_c_int32_t, FK_XHCI_TRB_CTRL_ISP_BIT)
       if (dir_in /= 0_c_int32_t) &
            ctrl = ibset(ctrl, FK_XHCI_TRB_CTRL_DIR_IN_BIT)
       ignored = tr_push(i, &
            int(iand(buf_phys, int(z'FFFFFFFF', c_int64_t)), c_int32_t), &
            int(shiftr(buf_phys, 32), c_int32_t), wlength, &
            int(FK_XHCI_TRB_TYPE_DATA, c_int32_t), ctrl)
       if (ignored == 0_c_int64_t) return
    end if

    ctrl = ibset(0_c_int32_t, FK_XHCI_TRB_CTRL_IOC_BIT)
    if (wlength == 0_c_int32_t .or. dir_in == 0_c_int32_t) &
         ctrl = ibset(ctrl, FK_XHCI_TRB_CTRL_DIR_IN_BIT)
    trb_phys = tr_push(i, 0_c_int32_t, 0_c_int32_t, 0_c_int32_t, &
                       int(FK_XHCI_TRB_TYPE_STATUS, c_int32_t), ctrl)
  end function xhci_tr_control

  function xhci_tr_normal(i, buf_phys, length) result(trb_phys) &
       bind(c, name="xhci_tr_normal")
    implicit none
    integer(c_int32_t), intent(in), value :: i, length
    integer(c_int64_t), intent(in), value :: buf_phys
    integer(c_int64_t) :: trb_phys
    integer(c_int32_t) :: ctrl

    trb_phys = 0_c_int64_t
    if (i < 1_c_int32_t .or. i > FK_XHCI_TR_MAX) return

    ctrl = ior(ibset(0_c_int32_t, FK_XHCI_TRB_CTRL_IOC_BIT), &
               ibset(0_c_int32_t, FK_XHCI_TRB_CTRL_ISP_BIT))
    trb_phys = tr_push(i, &
         int(iand(buf_phys, int(z'FFFFFFFF', c_int64_t)), c_int32_t), &
         int(shiftr(buf_phys, 32), c_int32_t), length, &
         int(FK_XHCI_TRB_TYPE_NORMAL, c_int32_t), ctrl)
  end function xhci_tr_normal

  ! The handler's half of the event ring.  IMAN.IP IS CLEARED FIRST and that
  ! ordering is the whole of it: IP is write-1-to-clear, the controller sends
  ! no further message while it is set, and clearing it after the drain loses
  ! any event that lands in between.  Clearing it before costs at worst a
  ! spurious interrupt with an empty ring, which this routine reports as zero.
  !
  ! Returns the number of TRANSFER events consumed.  Anything else on the ring
  ! -- a port status change, a command completion nobody is waiting for -- is
  ! consumed and dropped, because leaving it there stalls the ring.
  function xhci_drain() result(n) bind(c, name="xhci_drain")
    implicit none
    integer(c_int32_t) :: n, v, st, i

    n = 0_c_int32_t
    if (rt_base == 0_c_int64_t .or. evt_virt == 0_c_int64_t) return

    v = fk_readl(ir0(FK_XHCI_IR_IMAN_OFF))
    v = ibset(v, FK_XHCI_IMAN_IP_BIT)
    call fk_writel(ir0(FK_XHCI_IR_IMAN_OFF), v)

    do i = 1_c_int32_t, FK_XHCI_TR_MAX * 64_c_int32_t
       st = xhci_event_poll()
       if (st /= FK_XHCI_OK) return
       if (ev_type == FK_XHCI_TRB_TYPE_TRANSFER) n = n + 1_c_int32_t
    end do
  end function xhci_drain

  ! Arms the handler as the event ring's consumer.  The ORDER matters: the
  ! caller must be ready to drain before IMAN.IE goes back up, or a message
  ! arriving in the gap is counted by a handler that does not clear IP, and
  ! then no further message is ever sent.
  function xhci_evt_owner_isr() result(status) bind(c, name="xhci_evt_owner_isr")
    implicit none
    integer(c_int32_t) :: status

    status = xhci_intr_enable()
  end function xhci_evt_owner_isr

  subroutine xhci_dcbaa_set(dcbaa_virt, slot, ctx_phys) &
       bind(c, name="xhci_dcbaa_set")
    implicit none
    integer(c_int64_t), intent(in), value :: dcbaa_virt, ctx_phys
    integer(c_int32_t), intent(in), value :: slot

    if (dcbaa_virt == 0_c_int64_t) return
    if (slot < 1_c_int32_t .or. slot > FK_XHCI_MAX_SLOTS) return
    call write64(dcbaa_virt + int(slot, c_int64_t) * 8_c_int64_t, ctx_phys)
  end subroutine xhci_dcbaa_set

end module fk_xhci_m
