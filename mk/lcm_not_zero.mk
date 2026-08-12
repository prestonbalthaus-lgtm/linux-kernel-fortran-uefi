TESTS               += lcm_not_zero
ORACLE_lcm_not_zero := lib/math/lcm.c
FSRC_lcm_not_zero   := src/lib/math/fk_lcm_not_zero.f90
DRV_lcm_not_zero    := tests/lib/math/test_lcm_not_zero.c
CFLAGS_lcm_not_zero := -Itests/shims/lcm_not_zero
