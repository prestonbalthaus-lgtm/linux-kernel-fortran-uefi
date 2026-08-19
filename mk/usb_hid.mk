TESTS                 += usb_hid
FSRC_usb_hid          := src/drivers/usb/fk_usb_hid.f90
DRV_usb_hid           := tests/drivers/usb/test_usb_hid.c
CFLAGS_usb_hid        := -I$(BUILD)

# No ORACLE_usb_hid, and the reason is sharper than "there is no C original".
# Linux maps a HID usage to a KEYCODE; keycode to CHARACTER is a userspace
# keymap, so no function in the kernel tree answers the question this module
# answers and none could be linked and diffed against it.
#
# What the tree does have is usb_kbd_keycode[256] in
# drivers/hid/usbhid/usbkbd.c, and it is a real oracle for two relations rather
# than for the values: which usages are keys at all, and which distinct usages
# are the SAME key. tools/gen-hid-oracle.py extracts it -- DERIVED, not
# transcribed, because a hand copy of a 256-entry table is a copy that drifts
# and this one is being used as evidence. usbkbd.c cannot be compiled
# standalone (it needs a HID core, an input device and a URB), which is why the
# array is lifted instead of linked.
$(BUILD)/hid-oracle.h: $(KDIR)/drivers/hid/usbhid/usbkbd.c \
                       tools/gen-hid-oracle.py | $(BUILD)
	python3 tools/gen-hid-oracle.py $< $@

$(BUILD)/drv-usb_hid.o: $(BUILD)/hid-oracle.h
