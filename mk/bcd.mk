TESTS      += bcd
ORACLE_bcd := lib/bcd.c
FSRC_bcd   := src/lib/fk_bcd.f90
DRV_bcd    := tests/lib/test_bcd.c
CFLAGS_bcd := -Itests/shims/bcd
