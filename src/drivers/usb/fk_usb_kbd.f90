! SPDX-License-Identifier: GPL-2.0
! The USB HID boot keyboard: enumeration, and a character on the screen.
! Roadmap 5.2.
!
! THE EVENT RING HAS ONE CONSUMER AT A TIME and this module owns the handover.
! Enumeration needs to wait for a completion after every command, which is not
! something an interrupt handler can do, so the interrupter is taken DOWN for
! the whole of it and every completion is polled.  IMAN.IE goes back up only
! once EP1 is armed, and from that instant the handler owns the ring.
!
! DESCRIPTORS ARE READ WITH fk_readl, like the rings and for the ring's reason:
! they are memory a bus master wrote.  A Fortran pointer walk over a descriptor
! is the load gfortran narrows and tools/mmiocheck.sh refuses.
module fk_usb_kbd_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t, c_char
  use fk_xhci_m,       only: FK_XHCI_OK, FK_XHCI_E_SPEED, FK_XHCI_E_SLOT, &
                             FK_XHCI_E_PORT, FK_XHCI_E_CMD, &
                             xhci_port_find, xhci_port_reset, xhci_portsc, &
                             xhci_port_speed, xhci_intr_disable, &
                             xhci_cmd_enable_slot, xhci_cmd_address_device, &
                             xhci_cmd_config_ep, xhci_cmd_wait, &
                             xhci_event_slot, xhci_event_epid, &
                             xhci_doorbell, xhci_ctx_zero, xhci_ictx_flags, &
                             xhci_ictx_config, xhci_slot_ctx_init, &
                             xhci_ep_ctx_init, xhci_dev_ctx_slot_state, &
                             xhci_dev_ctx_address, xhci_dcbaa_set, &
                             xhci_tr_init, xhci_tr_control, xhci_tr_normal, &
                             xhci_tr_phys, xhci_drain, xhci_evt_owner_isr
  use fk_xhci_types_m, only: FK_XHCI_SPEED_HS, FK_XHCI_SPEED_SS, &
                             FK_XHCI_SPEED_SSP, FK_XHCI_CTX_ENTRIES, &
                             FK_XHCI_ICTX_ENTRIES, FK_XHCI_EP_TYPE_CONTROL, &
                             FK_XHCI_EP_TYPE_INT_IN, &
                             FK_XHCI_SLOT_STATE_ADDRESSED, &
                             FK_XHCI_SLOT_STATE_CONFIGURED
  use fk_usb_types_m,  only: FK_USB_DIR_IN, FK_USB_TYPE_CLASS, &
                             FK_USB_RECIP_INTERFACE, &
                             FK_USB_REQ_GET_DESCRIPTOR, &
                             FK_USB_REQ_SET_CONFIGURATION, &
                             FK_HID_REQ_SET_PROTOCOL, FK_HID_BOOT_PROTOCOL, &
                             FK_USB_DT_DEVICE, FK_USB_DT_CONFIG, &
                             FK_USB_DT_INTERFACE, FK_USB_DT_ENDPOINT, &
                             FK_USB_DESC_LEN_OFF, FK_USB_DESC_TYPE_OFF, &
                             FK_USB_DEV_MAXPKT0_OFF, FK_USB_DEV_LEN, &
                             FK_USB_CFG_TOTLEN_OFF, FK_USB_CFG_VALUE_OFF, &
                             FK_USB_CFG_LEN, FK_USB_IF_NUMBER_OFF, &
                             FK_USB_IF_CLASS_OFF, FK_USB_IF_SUBCLASS_OFF, &
                             FK_USB_IF_PROTO_OFF, FK_USB_EP_ADDR_OFF, &
                             FK_USB_EP_ATTR_OFF, FK_USB_EP_MAXPKT_OFF, &
                             FK_USB_EP_INTERVAL_OFF, FK_USB_EP_ADDR_IN_BIT, &
                             FK_USB_EP_XFER_POS, FK_USB_EP_XFER_LEN, &
                             FK_USB_EP_XFER_INT, FK_USB_CLASS_HID, &
                             FK_USB_SUBCLASS_BOOT, FK_USB_PROTO_KEYBOARD, &
                             FK_USB_HID_REPORT_BYTES, FK_USB_HID_MOD_OFF, &
                             FK_USB_HID_KEY_OFF, FK_USB_HID_KEYS
  use fk_usb_hid_m,    only: hid_ascii, FK_HID_USAGE_CAPS
  use fk_console_m,    only: console_putc
  implicit none
  private

  public :: usbkbd_bringup, usbkbd_isr, fk_usbkbd_state
  public :: FK_USBKBD_WORDS, FK_USBKBD_MAGIC
  public :: FK_USBKBD_E_NODEV, FK_USBKBD_E_DESC, FK_USBKBD_E_NOTKBD, &
            FK_USBKBD_E_NOEP, FK_USBKBD_E_MEM

  integer(c_int32_t), parameter :: FK_USBKBD_E_NODEV  = -20_c_int32_t
  integer(c_int32_t), parameter :: FK_USBKBD_E_DESC   = -21_c_int32_t
  integer(c_int32_t), parameter :: FK_USBKBD_E_NOTKBD = -22_c_int32_t
  integer(c_int32_t), parameter :: FK_USBKBD_E_NOEP   = -23_c_int32_t
  integer(c_int32_t), parameter :: FK_USBKBD_E_MEM    = -24_c_int32_t

  ! EP0 is DCI 1 and EP1 IN is DCI 3: the index is endpoint*2 + direction, so
  ! an interrupt IN endpoint numbered 1 is not DCI 1 and a doorbell rung at 1
  ! rings the control endpoint instead.
  integer(c_int32_t), parameter :: DCI_EP0 = 1_c_int32_t
  integer(c_int32_t), parameter :: DCI_EP1_IN = 3_c_int32_t
  integer(c_int32_t), parameter :: TR_EP0 = 1_c_int32_t
  integer(c_int32_t), parameter :: TR_EP1 = 2_c_int32_t
  integer(c_int32_t), parameter :: TR_TRBS = 256_c_int32_t
  integer(c_int32_t), parameter :: DESC_BYTES = 256_c_int32_t

  ! [0] magic [1] port [2] PORTSC after reset [3] speed [4] slot [5] device
  ! ctx [6] input ctx [7] EP0 ring [8] EP1 ring [9] descriptor buf [10] report
  ! buf [11] slot state after Address Device [12] the address the CONTROLLER
  ! assigned [13] slot state after Configure Endpoint [14] bMaxPacketSize0
  ! [15] interface<<32|bConfigurationValue [16] EP1 bEndpointAddress
  ! [17] wMaxPacketSize<<32|bInterval [18] transfer events taken [19] the last
  ! report, all eight bytes [20] characters rendered [21] the last eight of
  ! them, most recent in the low byte [22] ARMED [23] status
  integer(c_int32_t), parameter :: FK_USBKBD_WORDS = 24_c_int32_t
  integer(c_int64_t), parameter :: FK_USBKBD_MAGIC = &
       int(z'55534B420502', c_int64_t)

  integer(c_int64_t), volatile, save, bind(c, name="fk_usbkbd_state") :: &
       fk_usbkbd_state(0:FK_USBKBD_WORDS - 1)

  integer(c_int64_t), save :: dctx_virt = 0_c_int64_t
  integer(c_int64_t), save :: ictx_virt = 0_c_int64_t
  integer(c_int64_t), save :: desc_virt = 0_c_int64_t
  integer(c_int64_t), save :: rpt_virt  = 0_c_int64_t
  integer(c_int64_t), save :: rpt_phys  = 0_c_int64_t
  integer(c_int32_t), save :: slot_id   = 0_c_int32_t
  integer(c_int64_t), save :: prev_rpt  = 0_c_int64_t
  integer(c_int32_t), save :: caps_on   = 0_c_int32_t
  logical,            save :: armed     = .false.

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

  function buf_byte(base, off) result(v)
    implicit none
    integer(c_int64_t), intent(in) :: base
    integer(c_int32_t), intent(in) :: off
    integer(c_int32_t) :: v

    v = ibits(fk_readl(base + int((off / 4_c_int32_t) * 4_c_int32_t, &
                                  c_int64_t)), &
              mod(off, 4_c_int32_t) * 8_c_int32_t, 8_c_int32_t)
  end function buf_byte

  function buf_word(base, off) result(v)
    implicit none
    integer(c_int64_t), intent(in) :: base
    integer(c_int32_t), intent(in) :: off
    integer(c_int32_t) :: v

    v = ior(buf_byte(base, off), shiftl(buf_byte(base, off + 1_c_int32_t), 8))
  end function buf_word

  subroutine buf_zero(base, bytes)
    implicit none
    integer(c_int64_t), intent(in) :: base
    integer(c_int32_t), intent(in) :: bytes
    integer(c_int32_t) :: i

    do i = 0_c_int32_t, bytes / 4_c_int32_t - 1_c_int32_t
       call fk_writel(base + int(i * 4_c_int32_t, c_int64_t), 0_c_int32_t)
    end do
  end subroutine buf_zero

  ! One control transfer on EP0, enqueued and waited for.  wLength travels in
  ! the setup packet AND as the data stage's length; passing one without the
  ! other is a transfer the device answers and the controller never reports.
  function ctrl(rtype, req, value, index, buf, wlength, dir_in) result(status)
    implicit none
    integer(c_int32_t), intent(in) :: rtype, req, value, index, wlength, dir_in
    integer(c_int64_t), intent(in) :: buf
    integer(c_int32_t) :: status, lo, hi
    integer(c_int64_t) :: trb

    lo = 0_c_int32_t
    call mvbits(rtype, 0_c_int32_t, 8_c_int32_t, lo, 0_c_int32_t)
    call mvbits(req,   0_c_int32_t, 8_c_int32_t, lo, 8_c_int32_t)
    call mvbits(value, 0_c_int32_t, 16_c_int32_t, lo, 16_c_int32_t)
    hi = 0_c_int32_t
    call mvbits(index,   0_c_int32_t, 16_c_int32_t, hi, 0_c_int32_t)
    call mvbits(wlength, 0_c_int32_t, 16_c_int32_t, hi, 16_c_int32_t)

    trb = xhci_tr_control(TR_EP0, lo, hi, buf, wlength, dir_in)
    status = FK_XHCI_E_CMD
    if (trb == 0_c_int64_t) return
    call xhci_doorbell(slot_id, DCI_EP0)
    status = xhci_cmd_wait(trb)
  end function ctrl

  ! Max packet size for endpoint 0, from the port's speed.  AN ALLOWLIST, not a
  ! default: full and low speed put a frame COUNT in bInterval where high and
  ! super speed put an exponent, so a device at those speeds would be given an
  ! interrupt period out by orders of magnitude and poll almost never.  Nothing
  ! here has been tested against one, so nothing here pretends to handle one.
  function mps0_for(speed) result(v)
    implicit none
    integer(c_int32_t), intent(in) :: speed
    integer(c_int32_t) :: v

    select case (speed)
    case (FK_XHCI_SPEED_HS)
       v = 64_c_int32_t
    case (FK_XHCI_SPEED_SS, FK_XHCI_SPEED_SSP)
       v = 512_c_int32_t
    case default
       v = 0_c_int32_t
    end select
  end function mps0_for

  ! Walk the configuration blob for the boot-keyboard interface and its
  ! interrupt IN endpoint.  bLength is trusted for the step, so a zero length
  ! is refused rather than looped on.
  function walk_config(totlen, iface, ep_addr, ep_mps, ep_ival) result(status)
    implicit none
    integer(c_int32_t), intent(in) :: totlen
    integer(c_int32_t), intent(out) :: iface, ep_addr, ep_mps, ep_ival
    integer(c_int32_t) :: status, off, dlen, dtype, cur_if, hit_if

    iface = -1_c_int32_t
    ep_addr = -1_c_int32_t
    ep_mps = 0_c_int32_t
    ep_ival = 0_c_int32_t
    cur_if = -1_c_int32_t
    hit_if = 0_c_int32_t
    status = FK_USBKBD_E_DESC

    off = FK_USB_CFG_LEN
    do while (off + 2_c_int32_t <= totlen)
       dlen  = buf_byte(desc_virt, off + FK_USB_DESC_LEN_OFF)
       dtype = buf_byte(desc_virt, off + FK_USB_DESC_TYPE_OFF)
       if (dlen < 2_c_int32_t) return
       if (off + dlen > totlen) return

       if (dtype == FK_USB_DT_INTERFACE) then
          cur_if = buf_byte(desc_virt, off + FK_USB_IF_NUMBER_OFF)
          if (buf_byte(desc_virt, off + FK_USB_IF_CLASS_OFF) == &
                 FK_USB_CLASS_HID .and. &
              buf_byte(desc_virt, off + FK_USB_IF_SUBCLASS_OFF) == &
                 FK_USB_SUBCLASS_BOOT .and. &
              buf_byte(desc_virt, off + FK_USB_IF_PROTO_OFF) == &
                 FK_USB_PROTO_KEYBOARD) then
             iface = cur_if
             hit_if = 1_c_int32_t
          else
             hit_if = 0_c_int32_t
          end if
       else if (dtype == FK_USB_DT_ENDPOINT .and. hit_if == 1_c_int32_t) then
          if (ep_addr < 0_c_int32_t) then
             if (btest(buf_byte(desc_virt, off + FK_USB_EP_ADDR_OFF), &
                       FK_USB_EP_ADDR_IN_BIT) .and. &
                 ibits(buf_byte(desc_virt, off + FK_USB_EP_ATTR_OFF), &
                       FK_USB_EP_XFER_POS, FK_USB_EP_XFER_LEN) == &
                 FK_USB_EP_XFER_INT) then
                ep_addr = buf_byte(desc_virt, off + FK_USB_EP_ADDR_OFF)
                ep_mps  = buf_word(desc_virt, off + FK_USB_EP_MAXPKT_OFF)
                ep_ival = buf_byte(desc_virt, off + FK_USB_EP_INTERVAL_OFF)
             end if
          end if
       end if
       off = off + dlen
    end do

    if (iface < 0_c_int32_t) then
       status = FK_USBKBD_E_NOTKBD
    else if (ep_addr < 0_c_int32_t) then
       status = FK_USBKBD_E_NOEP
    else
       status = FK_XHCI_OK
    end if
  end function walk_config

  ! RUN is the physical base of a six-page contiguous run and RUN_VIRT its
  ! mapping; DCBAA_VIRT is 5.1's device context base array.
  function usbkbd_bringup(run, run_virt, dcbaa_virt, page) result(status) &
       bind(c, name="usbkbd_bringup")
    implicit none
    integer(c_int64_t), intent(in), value :: run, run_virt, dcbaa_virt, page
    integer(c_int32_t) :: status, port, speed, mps0, iface, cfgval
    integer(c_int32_t) :: ep_addr, ep_mps, ep_ival, totlen, ival
    integer(c_int64_t) :: dctx_phys, ictx_phys, ep0_phys, ep1_phys, desc_phys
    integer(c_int64_t) :: trb

    fk_usbkbd_state = 0_c_int64_t
    fk_usbkbd_state(0) = FK_USBKBD_MAGIC
    armed = .false.

    status = FK_USBKBD_E_MEM
    if (run == 0_c_int64_t .or. run_virt == 0_c_int64_t) return
    if (dcbaa_virt == 0_c_int64_t) return

    dctx_phys = run
    ictx_phys = run + page
    ep0_phys  = run + 2_c_int64_t * page
    ep1_phys  = run + 3_c_int64_t * page
    desc_phys = run + 4_c_int64_t * page
    rpt_phys  = run + 5_c_int64_t * page

    dctx_virt = run_virt
    ictx_virt = run_virt + page
    desc_virt = run_virt + 4_c_int64_t * page
    rpt_virt  = run_virt + 5_c_int64_t * page

    fk_usbkbd_state(5) = dctx_phys
    fk_usbkbd_state(6) = ictx_phys
    fk_usbkbd_state(7) = ep0_phys
    fk_usbkbd_state(8) = ep1_phys
    fk_usbkbd_state(9) = desc_phys
    fk_usbkbd_state(10) = rpt_phys

    ! THE INTERRUPTER GOES DOWN FIRST.  Everything below polls.
    status = xhci_intr_disable()
    if (status /= FK_XHCI_OK) return

    port = xhci_port_find()
    status = FK_USBKBD_E_NODEV
    if (port == 0_c_int32_t) return
    fk_usbkbd_state(1) = int(port, c_int64_t)

    status = xhci_port_reset(port)
    fk_usbkbd_state(2) = int(xhci_portsc(port), c_int64_t)
    if (status /= FK_XHCI_OK) return

    speed = xhci_port_speed(port)
    fk_usbkbd_state(3) = int(speed, c_int64_t)
    mps0 = mps0_for(speed)
    status = FK_XHCI_E_SPEED
    if (mps0 == 0_c_int32_t) return

    trb = xhci_cmd_enable_slot()
    call xhci_doorbell(0_c_int32_t, 0_c_int32_t)
    status = xhci_cmd_wait(trb)
    if (status /= FK_XHCI_OK) return
    slot_id = xhci_event_slot()
    status = FK_XHCI_E_SLOT
    if (slot_id < 1_c_int32_t) return
    fk_usbkbd_state(4) = int(slot_id, c_int64_t)

    call xhci_ctx_zero(dctx_virt, FK_XHCI_CTX_ENTRIES)
    call xhci_ctx_zero(ictx_virt, FK_XHCI_ICTX_ENTRIES)
    call buf_zero(desc_virt, DESC_BYTES)
    call buf_zero(rpt_virt, FK_USB_HID_REPORT_BYTES)
    call xhci_dcbaa_set(dcbaa_virt, slot_id, dctx_phys)

    status = xhci_tr_init(TR_EP0, run_virt + 2_c_int64_t * page, ep0_phys, &
                          TR_TRBS)
    if (status /= FK_XHCI_OK) return
    status = xhci_tr_init(TR_EP1, run_virt + 3_c_int64_t * page, ep1_phys, &
                          TR_TRBS)
    if (status /= FK_XHCI_OK) return

    ! A0 | A1: the slot context and EP0.  Context Entries is 1 because EP0 is
    ! the last valid endpoint at this point; it becomes 3 below.
    call xhci_ictx_flags(ictx_virt, 3_c_int32_t, 0_c_int32_t)
    call xhci_slot_ctx_init(ictx_virt, speed, port, DCI_EP0)
    call xhci_ep_ctx_init(ictx_virt, DCI_EP0, FK_XHCI_EP_TYPE_CONTROL, mps0, &
                          0_c_int32_t, xhci_tr_phys(TR_EP0))

    trb = xhci_cmd_address_device(ictx_phys, slot_id)
    call xhci_doorbell(0_c_int32_t, 0_c_int32_t)
    status = xhci_cmd_wait(trb)
    if (status /= FK_XHCI_OK) return
    fk_usbkbd_state(11) = int(xhci_dev_ctx_slot_state(dctx_virt), c_int64_t)
    fk_usbkbd_state(12) = int(xhci_dev_ctx_address(dctx_virt), c_int64_t)
    status = FK_USBKBD_E_DESC
    if (xhci_dev_ctx_slot_state(dctx_virt) /= FK_XHCI_SLOT_STATE_ADDRESSED) &
         return

    status = ctrl(ior(FK_USB_DIR_IN, 0_c_int32_t), FK_USB_REQ_GET_DESCRIPTOR, &
                  shiftl(FK_USB_DT_DEVICE, 8), 0_c_int32_t, desc_phys, &
                  FK_USB_DEV_LEN, 1_c_int32_t)
    if (status /= FK_XHCI_OK) return
    fk_usbkbd_state(14) = int(buf_byte(desc_virt, FK_USB_DEV_MAXPKT0_OFF), &
                              c_int64_t)

    ! The nine-byte header first, because wTotalLength is inside it and the
    ! blob's real length is not knowable before it is read.
    status = ctrl(ior(FK_USB_DIR_IN, 0_c_int32_t), FK_USB_REQ_GET_DESCRIPTOR, &
                  shiftl(FK_USB_DT_CONFIG, 8), 0_c_int32_t, desc_phys, &
                  FK_USB_CFG_LEN, 1_c_int32_t)
    if (status /= FK_XHCI_OK) return
    totlen = buf_word(desc_virt, FK_USB_CFG_TOTLEN_OFF)
    status = FK_USBKBD_E_DESC
    if (totlen < FK_USB_CFG_LEN .or. totlen > DESC_BYTES) return

    status = ctrl(ior(FK_USB_DIR_IN, 0_c_int32_t), FK_USB_REQ_GET_DESCRIPTOR, &
                  shiftl(FK_USB_DT_CONFIG, 8), 0_c_int32_t, desc_phys, &
                  totlen, 1_c_int32_t)
    if (status /= FK_XHCI_OK) return
    cfgval = buf_byte(desc_virt, FK_USB_CFG_VALUE_OFF)

    status = walk_config(totlen, iface, ep_addr, ep_mps, ep_ival)
    if (status /= FK_XHCI_OK) return
    fk_usbkbd_state(15) = ior(shiftl(int(iface, c_int64_t), 32), &
                              int(cfgval, c_int64_t))
    fk_usbkbd_state(16) = int(ep_addr, c_int64_t)
    fk_usbkbd_state(17) = ior(shiftl(int(ep_mps, c_int64_t), 32), &
                              int(ep_ival, c_int64_t))

    status = ctrl(0_c_int32_t, FK_USB_REQ_SET_CONFIGURATION, cfgval, &
                  0_c_int32_t, 0_c_int64_t, 0_c_int32_t, 0_c_int32_t)
    if (status /= FK_XHCI_OK) return

    ! BOOT PROTOCOL, and it is what makes this milestone small: the report is
    ! then a fixed eight bytes and no report descriptor has to be parsed.
    status = ctrl(ior(FK_USB_TYPE_CLASS, FK_USB_RECIP_INTERFACE), &
                  FK_HID_REQ_SET_PROTOCOL, FK_HID_BOOT_PROTOCOL, iface, &
                  0_c_int64_t, 0_c_int32_t, 0_c_int32_t)
    if (status /= FK_XHCI_OK) return

    ! bInterval on a high or super speed interrupt endpoint is a one-based
    ! exponent of 125us microframes; the context field is zero-based.
    ival = ep_ival - 1_c_int32_t
    if (ival < 0_c_int32_t) ival = 0_c_int32_t

    ! A0 | A3, and Context Entries moves to 3.  Leaving it at 1 is a Configure
    ! Endpoint the controller answers with a parameter error; leaving A3 clear
    ! is one it answers with SUCCESS and an endpoint it never looks at.
    call xhci_ictx_flags(ictx_virt, ior(1_c_int32_t, shiftl(1_c_int32_t, &
                                                            DCI_EP1_IN)), &
                         0_c_int32_t)
    call xhci_slot_ctx_init(ictx_virt, speed, port, DCI_EP1_IN)
    call xhci_ep_ctx_init(ictx_virt, DCI_EP1_IN, FK_XHCI_EP_TYPE_INT_IN, &
                          ep_mps, ival, xhci_tr_phys(TR_EP1))
    call xhci_ictx_config(ictx_virt, cfgval, iface)

    trb = xhci_cmd_config_ep(ictx_phys, slot_id)
    call xhci_doorbell(0_c_int32_t, 0_c_int32_t)
    status = xhci_cmd_wait(trb)
    if (status /= FK_XHCI_OK) return
    fk_usbkbd_state(13) = int(xhci_dev_ctx_slot_state(dctx_virt), c_int64_t)
    status = FK_USBKBD_E_DESC
    if (xhci_dev_ctx_slot_state(dctx_virt) /= FK_XHCI_SLOT_STATE_CONFIGURED) &
         return

    ! ARMED BEFORE IMAN.IE GOES UP.  A message arriving in the other order is
    ! taken by a handler that does not own the ring, does not clear IP, and
    ! therefore ends interrupts permanently after the first one.
    prev_rpt = 0_c_int64_t
    armed = .true.
    call rearm()
    status = xhci_evt_owner_isr()
    if (status /= FK_XHCI_OK) return

    fk_usbkbd_state(22) = 1_c_int64_t
    fk_usbkbd_state(23) = int(status, c_int64_t)
  end function usbkbd_bringup

  subroutine rearm()
    implicit none
    integer(c_int64_t) :: trb

    trb = xhci_tr_normal(TR_EP1, rpt_phys, FK_USB_HID_REPORT_BYTES)
    if (trb == 0_c_int64_t) return
    call xhci_doorbell(slot_id, DCI_EP1_IN)
  end subroutine rearm

  function report_word() result(v)
    implicit none
    integer(c_int64_t) :: v

    v = ior(iand(int(fk_readl(rpt_virt), c_int64_t), &
                 int(z'FFFFFFFF', c_int64_t)), &
            shiftl(iand(int(fk_readl(rpt_virt + 4_c_int64_t), c_int64_t), &
                        int(z'FFFFFFFF', c_int64_t)), 32))
  end function report_word

  function rpt_byte(w, i) result(v)
    implicit none
    integer(c_int64_t), intent(in) :: w
    integer(c_int32_t), intent(in) :: i
    integer(c_int32_t) :: v

    v = int(iand(shiftr(w, i * 8_c_int32_t), 255_c_int64_t), c_int32_t)
  end function rpt_byte

  ! The six usage slots are a rollover SET, not a queue: a key held down is in
  ! every report until it is released.  A keystroke is therefore a usage that
  ! is in this report and was not in the last one, which is why the previous
  ! report has to be kept.
  function held(w, usage) result(yes)
    implicit none
    integer(c_int64_t), intent(in) :: w
    integer(c_int32_t), intent(in) :: usage
    logical :: yes
    integer(c_int32_t) :: i

    yes = .false.
    if (usage == 0_c_int32_t) return
    do i = 0_c_int32_t, FK_USB_HID_KEYS - 1_c_int32_t
       if (rpt_byte(w, FK_USB_HID_KEY_OFF + i) == usage) then
          yes = .true.
          return
       end if
    end do
  end function held

  subroutine render(w)
    implicit none
    integer(c_int64_t), intent(in) :: w
    integer(c_int32_t) :: i, usage, mods, ch

    mods = rpt_byte(w, FK_USB_HID_MOD_OFF)
    do i = 0_c_int32_t, FK_USB_HID_KEYS - 1_c_int32_t
       usage = rpt_byte(w, FK_USB_HID_KEY_OFF + i)
       if (usage == 0_c_int32_t) cycle
       if (held(prev_rpt, usage)) cycle
       if (usage == FK_HID_USAGE_CAPS) then
          caps_on = 1_c_int32_t - caps_on
          cycle
       end if
       ch = hid_ascii(usage, mods, caps_on)
       if (ch == 0_c_int32_t) cycle
       call console_putc(achar(ch, c_char))
       fk_usbkbd_state(20) = fk_usbkbd_state(20) + 1_c_int64_t
       fk_usbkbd_state(21) = ior(shiftl(fk_usbkbd_state(21), 8), &
                                 int(ch, c_int64_t))
    end do
  end subroutine render

  ! Called from the MSI-X handler with interrupts off.  Everything expensive
  ! here is a memory access; the console's own critical section is what makes
  ! putc safe from this side.
  subroutine usbkbd_isr() bind(c, name="usbkbd_isr")
    implicit none
    integer(c_int32_t) :: n, i
    integer(c_int64_t) :: w

    ! THE OWNERSHIP TEST COMES FIRST, and it is not defensive: 5.1's NO-OP
    ! completion is polled by the bring-up while this handler is already
    ! installed, so a drain here before EP1 is armed CONSUMES that event and
    ! the poll spins out.  Measured -- the boot gate reported the NO-OP never
    ! completing, with the completion event visibly correct in DRAM.
    if (.not. armed) return

    n = xhci_drain()
    if (n == 0_c_int32_t) return

    do i = 1_c_int32_t, n
       if (xhci_event_epid() /= DCI_EP1_IN) cycle
       w = report_word()
       fk_usbkbd_state(18) = fk_usbkbd_state(18) + 1_c_int64_t
       ! The last report with a key in it, not the last report: releasing a key
       ! sends an all-zero report and that is the CORRECT final state, so
       ! publishing it unconditionally leaves nothing to assert against.
       if (iand(w, not(255_c_int64_t)) /= 0_c_int64_t) fk_usbkbd_state(19) = w
       call render(w)
       prev_rpt = w
       call rearm()
    end do
  end subroutine usbkbd_isr

end module fk_usb_kbd_m
