TESTS           += intlog2
ORACLE_intlog2  := lib/math/int_log.c
FSRC_intlog2    := src/lib/math/fk_intlog2.f90
DRV_intlog2     := tests/lib/math/test_intlog2.c
CFLAGS_intlog2  := -Itests/shims/intlog2
