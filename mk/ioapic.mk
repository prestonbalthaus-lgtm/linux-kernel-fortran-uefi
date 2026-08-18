TESTS                 += ioapic
FSRC_ioapic           := src/cpu/fk_ioapic.f90
DRV_ioapic            := tests/cpu/test_ioapic.c

# No ORACLE_ioapic, for mk/madt.mk's reason: this is a translation of the
# 82093AA redirection-table layout, not of one C function that could be
# compiled and diffed.  Linux's io_apic.c reaches the same dwords through a
# struct of bitfields whose layout is the compiler's business rather than the
# datasheet's -- a second opinion, and not an oracle.
#
# ALL of it is reachable from here, and that is a consequence of the milestone's
# other finding.  fk_ioapic_m reaches the chip through boot/io.S's fk_readl and
# fk_writel and nothing else -- it had to stop using a VOLATILE Fortran pointer,
# because -O2 narrowed ibits(reg_read(REG_VER), 16, 8) into a ONE-BYTE read of
# the 32-bit IOWIN register.  The test supplies those two accessors itself, the
# way tests/cpu/test_lapic.c supplies fk_rdmsr, and underneath them models the
# REGISTER FILE: an IOREGSEL latch, 24 redirection entries, and a log of every
# window write in order.  So the indexed sequencing is checked here, and so is
# the one property no final state can show -- that ioapic_route writes the high
# dword before it writes the low dword with the mask bit clear.
