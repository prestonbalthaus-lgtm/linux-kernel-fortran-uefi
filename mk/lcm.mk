TESTS           += lcm
ORACLE_lcm      := lib/math/lcm.c
FSRC_lcm        := src/lib/math/fk_lcm.f90
DRV_lcm         := tests/lib/math/test_lcm.c
CFLAGS_lcm      := -Itests/shims/lcm
