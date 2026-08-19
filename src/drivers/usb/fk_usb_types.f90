! SPDX-License-Identifier: GPL-2.0
! USB 2.0 chapter 9: the setup packet, the standard requests, and the four
! descriptors this kernel walks.  Roadmap 5.2.
!
! Cross-checked against vendor/linux-7.1.8/include/uapi/linux/usb/ch9.h and
! include/uapi/linux/hid.h.
!
! ENDIAN: wValue, wIndex, wLength and every multi-byte descriptor field are
! little-endian on the wire (__le16 upstream); on x86-64 that is the native
! layout and needs no swap.
!
! NO OVERLAY TYPES.  A descriptor arrives in memory a bus master wrote, which is
! the case fk_xhci_m's header names: a Fortran pointer over it is what gfortran
! narrows and tools/mmiocheck.sh refuses.  Every field is a BYTE OFFSET here and
! the reader fetches it a dword at a time.
module fk_usb_types_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private

  public :: FK_USB_SETUP_BYTES, FK_USB_SETUP_RTYPE_OFF, FK_USB_SETUP_REQ_OFF, &
            FK_USB_SETUP_VALUE_OFF, FK_USB_SETUP_INDEX_OFF, &
            FK_USB_SETUP_LENGTH_OFF
  public :: FK_USB_DIR_IN, FK_USB_TYPE_STANDARD, FK_USB_TYPE_CLASS, &
            FK_USB_RECIP_DEVICE, FK_USB_RECIP_INTERFACE
  public :: FK_USB_REQ_GET_DESCRIPTOR, FK_USB_REQ_SET_CONFIGURATION, &
            FK_USB_REQ_SET_ADDRESS
  public :: FK_HID_REQ_SET_IDLE, FK_HID_REQ_SET_PROTOCOL, FK_HID_BOOT_PROTOCOL
  public :: FK_USB_DT_DEVICE, FK_USB_DT_CONFIG, FK_USB_DT_INTERFACE, &
            FK_USB_DT_ENDPOINT, FK_USB_DT_HID
  public :: FK_USB_DESC_LEN_OFF, FK_USB_DESC_TYPE_OFF
  public :: FK_USB_DEV_MAXPKT0_OFF, FK_USB_DEV_NUMCFG_OFF, FK_USB_DEV_LEN
  public :: FK_USB_CFG_TOTLEN_OFF, FK_USB_CFG_NUMIF_OFF, FK_USB_CFG_VALUE_OFF, &
            FK_USB_CFG_LEN
  public :: FK_USB_IF_NUMBER_OFF, FK_USB_IF_ALT_OFF, FK_USB_IF_NUMEP_OFF, &
            FK_USB_IF_CLASS_OFF, FK_USB_IF_SUBCLASS_OFF, FK_USB_IF_PROTO_OFF, &
            FK_USB_IF_LEN
  public :: FK_USB_EP_ADDR_OFF, FK_USB_EP_ATTR_OFF, FK_USB_EP_MAXPKT_OFF, &
            FK_USB_EP_INTERVAL_OFF, FK_USB_EP_LEN
  public :: FK_USB_EP_ADDR_NUM_POS, FK_USB_EP_ADDR_NUM_LEN, FK_USB_EP_ADDR_IN_BIT
  public :: FK_USB_EP_XFER_POS, FK_USB_EP_XFER_LEN, FK_USB_EP_XFER_CONTROL, &
            FK_USB_EP_XFER_ISOC, FK_USB_EP_XFER_BULK, FK_USB_EP_XFER_INT
  public :: FK_USB_CLASS_HID, FK_USB_SUBCLASS_BOOT, FK_USB_PROTO_KEYBOARD
  public :: FK_USB_HID_REPORT_BYTES, FK_USB_HID_MOD_OFF, FK_USB_HID_KEY_OFF, &
            FK_USB_HID_KEYS

  ! ---- the setup packet, ch9.h:214-220 ---------------------------------------
  integer(c_int32_t), parameter :: FK_USB_SETUP_BYTES = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_SETUP_RTYPE_OFF = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_SETUP_REQ_OFF = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_SETUP_VALUE_OFF = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_SETUP_INDEX_OFF = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_SETUP_LENGTH_OFF = 6_c_int32_t

  ! bmRequestType, ch9.h:48-64.
  integer(c_int32_t), parameter :: FK_USB_DIR_IN = int(z'80', c_int32_t)
  integer(c_int32_t), parameter :: FK_USB_TYPE_STANDARD = int(z'00', c_int32_t)
  integer(c_int32_t), parameter :: FK_USB_TYPE_CLASS = int(z'20', c_int32_t)
  integer(c_int32_t), parameter :: FK_USB_RECIP_DEVICE = int(z'00', c_int32_t)
  integer(c_int32_t), parameter :: FK_USB_RECIP_INTERFACE = int(z'01', c_int32_t)

  ! bRequest, ch9.h:81-85.  SET_ADDRESS is listed and never issued: on xHCI the
  ! controller owns addressing and the Address Device command sends it.
  integer(c_int32_t), parameter :: FK_USB_REQ_SET_ADDRESS = int(z'05', c_int32_t)
  integer(c_int32_t), parameter :: FK_USB_REQ_GET_DESCRIPTOR = &
       int(z'06', c_int32_t)
  integer(c_int32_t), parameter :: FK_USB_REQ_SET_CONFIGURATION = &
       int(z'09', c_int32_t)

  ! HID 1.11 section 7.2, hid.h:66-67.  SET_PROTOCOL with wValue 0 is what puts
  ! a keyboard in BOOT protocol, whose report is a fixed eight bytes -- which is
  ! the whole reason this milestone needs no report-descriptor parser.
  integer(c_int32_t), parameter :: FK_HID_REQ_SET_IDLE = int(z'0A', c_int32_t)
  integer(c_int32_t), parameter :: FK_HID_REQ_SET_PROTOCOL = int(z'0B', c_int32_t)
  integer(c_int32_t), parameter :: FK_HID_BOOT_PROTOCOL = 0_c_int32_t

  ! Descriptor types, ch9.h:241-246.
  integer(c_int32_t), parameter :: FK_USB_DT_DEVICE = int(z'01', c_int32_t)
  integer(c_int32_t), parameter :: FK_USB_DT_CONFIG = int(z'02', c_int32_t)
  integer(c_int32_t), parameter :: FK_USB_DT_INTERFACE = int(z'04', c_int32_t)
  integer(c_int32_t), parameter :: FK_USB_DT_ENDPOINT = int(z'05', c_int32_t)
  integer(c_int32_t), parameter :: FK_USB_DT_HID = int(z'21', c_int32_t)

  ! Every descriptor begins bLength, bDescriptorType.  That pair is what makes
  ! the configuration blob walkable without knowing what is in it.
  integer(c_int32_t), parameter :: FK_USB_DESC_LEN_OFF = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_DESC_TYPE_OFF = 1_c_int32_t

  ! Device descriptor, ch9.h:295-312.
  integer(c_int32_t), parameter :: FK_USB_DEV_MAXPKT0_OFF = 7_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_DEV_NUMCFG_OFF = 17_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_DEV_LEN = 18_c_int32_t

  ! Configuration descriptor, ch9.h:350-366.  wTotalLength covers the whole
  ! blob -- interfaces, endpoints and class descriptors -- not this header.
  integer(c_int32_t), parameter :: FK_USB_CFG_TOTLEN_OFF = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_CFG_NUMIF_OFF = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_CFG_VALUE_OFF = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_CFG_LEN = 9_c_int32_t

  ! Interface descriptor, ch9.h:400-414.
  integer(c_int32_t), parameter :: FK_USB_IF_NUMBER_OFF = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_IF_ALT_OFF = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_IF_NUMEP_OFF = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_IF_CLASS_OFF = 5_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_IF_SUBCLASS_OFF = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_IF_PROTO_OFF = 7_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_IF_LEN = 9_c_int32_t

  ! Endpoint descriptor, ch9.h:436-450.
  integer(c_int32_t), parameter :: FK_USB_EP_ADDR_OFF = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_EP_ATTR_OFF = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_EP_MAXPKT_OFF = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_EP_INTERVAL_OFF = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_EP_LEN = 7_c_int32_t

  integer(c_int32_t), parameter :: FK_USB_EP_ADDR_NUM_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_EP_ADDR_NUM_LEN = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_EP_ADDR_IN_BIT = 7_c_int32_t

  integer(c_int32_t), parameter :: FK_USB_EP_XFER_POS = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_EP_XFER_LEN = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_EP_XFER_CONTROL = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_EP_XFER_ISOC = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_EP_XFER_BULK = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_EP_XFER_INT = 3_c_int32_t

  ! hid.h:39-42.  A keyboard the boot protocol applies to is class 3, subclass
  ! 1, protocol 1, and all three are checked rather than assumed.
  integer(c_int32_t), parameter :: FK_USB_CLASS_HID = int(z'03', c_int32_t)
  integer(c_int32_t), parameter :: FK_USB_SUBCLASS_BOOT = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_PROTO_KEYBOARD = 1_c_int32_t

  ! The boot keyboard report, HID 1.11 appendix B.1: modifiers, one reserved
  ! byte, then six usage ids -- rollover, not a queue, so a key held down
  ! reappears in every report until it is released.
  integer(c_int32_t), parameter :: FK_USB_HID_REPORT_BYTES = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_HID_MOD_OFF = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_HID_KEY_OFF = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_USB_HID_KEYS = 6_c_int32_t

end module fk_usb_types_m
