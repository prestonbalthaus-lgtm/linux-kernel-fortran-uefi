TESTS            += intlog10
ORACLE_intlog10  := lib/math/int_log.c
FSRC_intlog10    := src/lib/math/fk_intlog10.f90
DRV_intlog10     := tests/lib/math/test_intlog10.c
CFLAGS_intlog10  := -Itests/shims/intlog10
