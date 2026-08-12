TESTS       += gcd
ORACLE_gcd  := lib/math/gcd.c
FSRC_gcd    := src/lib/math/fk_gcd.f90
DRV_gcd     := tests/lib/math/test_gcd.c
CFLAGS_gcd  := -Itests/shims/gcd
