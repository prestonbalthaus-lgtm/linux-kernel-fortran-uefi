TESTS                 += gop_renderer
ORACLE_gop_renderer   := lib/fonts/font_8x16.c
FSRC_gop_renderer     := src/drivers/video/fk_gop_renderer.f90
DRV_gop_renderer      := tests/drivers/video/test_gop_renderer.c
CFLAGS_gop_renderer   := -Itests/shims/gop_renderer
