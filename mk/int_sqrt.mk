TESTS            += int_sqrt
ORACLE_int_sqrt  := lib/math/int_sqrt.c
FSRC_int_sqrt    := src/lib/math/fk_int_sqrt.f90
DRV_int_sqrt     := tests/lib/math/test_int_sqrt.c
CFLAGS_int_sqrt  := -Itests/shims/int_sqrt
