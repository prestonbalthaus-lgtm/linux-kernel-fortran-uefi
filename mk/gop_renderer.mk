TESTS                 += gop_renderer
ORACLE_gop_renderer   := lib/fonts/font_8x16.c
# ORDER IS SEMANTIC: fk_gop_renderer USEs fk_font_8x16, so the font module must
# be compiled first for its .mod to exist.
FSRC_gop_renderer     := src/drivers/video/fk_font_8x16.f90 \
                         src/drivers/video/fk_gop_renderer.f90
DRV_gop_renderer      := tests/drivers/video/test_gop_renderer.c
CFLAGS_gop_renderer   := -Itests/shims/gop_renderer
