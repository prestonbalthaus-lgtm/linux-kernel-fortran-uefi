TESTS                 += acpi
# fk_string.f90 FIRST: fk_acpi_m USEs it for fk_memcmp, and gfortran emits the
# .mod as a side effect of the object.
FSRC_acpi             := src/lib/fk_string.f90 src/acpi/fk_acpi.f90
DRV_acpi              := tests/acpi/test_acpi.c

# No ORACLE_acpi, for the reason mk/serial.mk and mk/lapic.mk have none: the
# RSDP/RSDT/XSDT walk is a translation of the ACPI specification, not of one C
# function that could be compiled and diffed against it.  drivers/acpi/ under
# $(KDIR) is a live subsystem that needs ACPICA, an allocator and real firmware
# to say anything at all.
#
# The test carries its own reference model instead: it builds the whole table
# tree -- MBI, RSDP, root, stub tables -- inside a guarded arena and points the
# parser at it with acpi_set_window/acpi_set_limit, which is also the only way
# to place a root at an offset congruent to 5 mod 8 the way real firmware does.
