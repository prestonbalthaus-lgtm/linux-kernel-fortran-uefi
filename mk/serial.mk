TESTS                 += serial
FSRC_serial           := src/drivers/serial/fk_serial.f90
DRV_serial            := tests/drivers/serial/test_serial.c

# No ORACLE_serial: this driver targets the 8250/16550 register interface, not a
# single C function that could be compiled and diffed against it.
# Second -I: the test includes the kernel's real <linux/serial_reg.h> from $(KDIR).
CFLAGS_serial         := -Itests/shims/serial -I$(KDIR)/include/uapi
