TESTS                 += mcfg
# ORDER IS SEMANTIC: mcfg_parse checks the "MCFG" signature with fk_memcmp, so
# fk_string_m.mod has to exist before src/acpi/fk_mcfg.f90 compiles.
FSRC_mcfg             := src/lib/fk_string.f90 src/acpi/fk_mcfg.f90
DRV_mcfg              := tests/acpi/test_mcfg.c

# No ORACLE_mcfg, for mk/madt.mk's reason: this is a translation of the PCI
# Firmware Specification 3.0 section 4.1.2, not of one C function that could be
# compiled and diffed against it.  Linux's drivers/acpi/pci_mcfg.c needs an
# initialised ACPI namespace to say anything at all.
#
# The reference model is the table this project's own firmware hands over --
# QEMU q35, one allocation, base 0xB0000000, buses 0 through 255 -- rebuilt
# field by field into a poisoned arena at eight different byte offsets, plus
# the malformed tables no real firmware would emit.
