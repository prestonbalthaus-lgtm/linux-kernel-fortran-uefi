TESTS                 += lapic
FSRC_lapic            := src/cpu/fk_lapic.f90
DRV_lapic             := tests/cpu/test_lapic.c

# No ORACLE_lapic, for mk/serial.mk's reason: the Local APIC is a translation of
# a register specification, not of one C function that could be compiled and
# diffed against it.  Nothing under $(KDIR) answers "what should offset 0x350
# hold after bring-up" -- arch/x86/kernel/apic/apic.c is a live driver that
# needs a real chip, an IDT and a mapped page to say anything at all.
#
# The test carries its own reference model of the 4 KiB register page instead,
# and compares every 32-bit word of it after each operation.
#
# No CFLAGS_lapic either: the driver includes only tests/harness/fk_test.h,
# which the top-level -Itests/harness already covers.  RDMSR/WRMSR are
# privileged, so the driver supplies its own fk_rdmsr/fk_wrmsr rather than
# assembling boot/mmu.S -- exactly as tests/drivers/serial/test_serial.c
# supplies fk_outb/fk_inb instead of assembling boot/io.S.
