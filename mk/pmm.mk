TESTS                 += pmm
FSRC_pmm              := src/mm/fk_pmm.f90
DRV_pmm               := tests/mm/test_pmm.c

# No ORACLE_pmm, for the same reason mk/serial.mk has none: a Multiboot2 parser
# and a bitmap allocator are a translation of a SPECIFICATION, not of one C
# function that could be compiled and diffed against. The test carries its own
# reference bitmap instead, and compares it against fk_pmm_bitmap directly --
# the array is bind(c) precisely so that the comparison can be with the real
# thing rather than with an accessor that might agree with a wrong bitmap.
