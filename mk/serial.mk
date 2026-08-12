TESTS                 += serial
FSRC_serial           := src/drivers/serial/fk_serial.f90
DRV_serial            := tests/drivers/serial/test_serial.c

# THERE IS DELIBERATELY NO ORACLE_serial, and that is the interesting line in
# this file.
#
# Every other fragment here names a C function under $(KDIR) that its Fortran
# module was translated FROM, and the test compiles that original alongside the
# translation and diffs the two. A 16550 UART driver has no such original. It is
# a translation of a hardware programming interface -- the 8250/16450/16550
# datasheet -- and the kernel's own serial driver (drivers/tty/serial/8250/) is
# a 30-year-old multi-thousand-line PM- and IRQ-aware subsystem, not a function
# whose output could be compared against ours. Naming any part of it as the
# oracle would be theatre.
#
# So the oracle is split in two, and the -I flags below are what supply the
# first half:
#
#   * REGISTER OFFSETS AND BIT MASKS come from the REAL kernel header,
#     include/uapi/linux/serial_reg.h, included straight out of the vendor tree
#     by the test. Every expected byte in the test's init trace is built from
#     UART_LCR_DLAB, UART_FCR_TRIGGER_14, UART_MCR_LOOP and friends -- never
#     from a literal -- so the constants in fk_serial.f90 are diffed against
#     Linux's own definitions. Copying the numbers into a second table in the
#     test would have proved only that the same person typed them twice.
#     (The vendored header is self-contained: no #includes, no shim needed.
#     That is why -Itests/shims/serial has nothing in it yet -- it exists so a
#     future header that DOES need shimming has the conventional place to go,
#     and gcc silently ignores an -I that names no directory.)
#
#   * DEVICE BEHAVIOUR comes from a mock 16550 written inside the test, which
#     supplies the fk_outb/fk_inb that boot/io.S supplies in the kernel and
#     models DLAB routing, the receive FIFO, loopback and THRE latency. The
#     driver is diffed against that model access by access.
#
# tests/drivers/video/test_gop_renderer.c documents the identical situation for
# the renderer half of Phase 2: the font is a translation with a real C oracle,
# the renderer is not, so it gets a reference model instead. Serial is the same
# shape with the split drawn between the header and the code rather than
# between two modules.
#
# ORACLE_<name> is optional in ./Makefile precisely so this fragment can stay
# silent rather than name a file that does not mean anything.
#
# $(KDIR) rather than the literal vendor/linux-7.1.8: the version is declared
# once at the top of ./Makefile, and a hardcoded copy here would keep compiling
# against a tree that no longer exists after the next vendor bump.
CFLAGS_serial         := -Itests/shims/serial -I$(KDIR)/include/uapi
