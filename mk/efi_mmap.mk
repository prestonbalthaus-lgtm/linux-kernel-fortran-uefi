TESTS                 += efi_mmap
FSRC_efi_mmap         := src/mm/fk_efi_mmap.f90
DRV_efi_mmap          := tests/mm/test_efi_mmap.c

# No ORACLE_efi_mmap, for the reason mk/serial.mk and mk/pmm.mk have none: an
# EFI_MEMORY_DESCRIPTOR walker is a translation of the UEFI specification, not
# of one C function that could be compiled and diffed against it. The test
# carries its own reference model and builds its own descriptor arenas -- at
# three different firmware strides, which is the property no oracle would have
# checked anyway.
