TESTS                 += madt
FSRC_madt             := src/lib/fk_string.f90 src/acpi/fk_madt.f90
DRV_madt              := tests/acpi/test_madt.c

# No ORACLE_madt, for mk/serial.mk's and mk/efi_mmap.mk's reason: the MADT
# walker is a translation of ACPI 6.5 5.2.12, not of one C function that could
# be compiled and diffed against it. drivers/acpi/tables.c and
# arch/x86/kernel/acpi/boot.c are live subsystem code that needs an initialised
# ACPI namespace, an ioremap and a real machine to say anything at all.
#
# The test carries its own reference model instead: the MADT measured from this
# project's own firmware (QEMU q35, -smp 6), rebuilt entry by entry into a
# guarded arena at deliberately unaligned base addresses, plus the malformed
# tables no real firmware would hand over.
#
# fk_string.f90 comes first and is not incidental: madt_parse verifies the
# "APIC" signature with fk_memcmp, and gfortran needs fk_string_m.mod on disk
# before src/acpi/fk_madt.f90 will compile.
