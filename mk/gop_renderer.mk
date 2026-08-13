TESTS                 += gop_renderer
ORACLE_gop_renderer   := lib/fonts/font_8x16.c
# ORDER IS SEMANTIC: fk_gop_renderer USEs fk_font_8x16 and fk_string_m (for
# fk_memmove), so both modules must be compiled first for their .mods to exist.
FSRC_gop_renderer     := src/lib/fk_string.f90 \
                         src/drivers/video/fk_font_8x16.f90 \
                         src/drivers/video/fk_gop_renderer.f90
DRV_gop_renderer      := tests/drivers/video/test_gop_renderer.c
CFLAGS_gop_renderer   := -Itests/shims/gop_renderer
