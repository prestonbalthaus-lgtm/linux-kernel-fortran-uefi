TESTS                 += xhci
# ORDER IS SEMANTIC: fk_xhci USEs fk_xhci_types_m for the register offsets and
# the TRB fields, so that .mod has to exist first.
FSRC_xhci             := src/drivers/usb/fk_xhci_types.f90 \
                         src/drivers/usb/fk_xhci.f90
DRV_xhci              := tests/drivers/usb/test_xhci.c

# No ORACLE_xhci. Linux's xhci-hcd drives a live controller through a PCI
# probe, a DMA pool and an interrupt handler, so it is a second opinion on the
# hardware rather than a function that can be linked and diffed against this
# one.
#
# The reference model is a CONTROLLER, not a register file: the test supplies
# fk_readl/fk_writel over a synthetic BAR and executes the command ring when
# doorbell 0 is rung, exactly as qemu-xhci does inside the MMIO write. That is
# what makes the cycle bit, the link TRB and the event ring assertable on the
# host at all.
