TESTS                 += console
# ORDER IS SEMANTIC: fk_gop_renderer USEs fk_string_m (for fk_memmove, which is
# what vga_scroll_up moves scanlines with) and fk_font_8x16_m, and fk_console
# USEs both of those in turn, so each .mod must exist before the next file in
# the list compiles.
FSRC_console          := src/lib/fk_string.f90 \
                         src/drivers/video/fk_font_8x16.f90 \
                         src/drivers/video/fk_gop_renderer.f90 \
                         src/drivers/video/fk_console.f90
DRV_console           := tests/drivers/video/test_console.c

# No ORACLE_console, and the reason is a shade stronger than mk/pmm.mk's.  A
# bitmap allocator at least has one C function per operation somewhere; a
# TERMINAL EMULATOR has none.  Linux's console is drivers/tty/vt/vt.c driving
# drivers/video/fbdev/core/fbcon.c through a consw ops table -- an
# escape-sequence state machine spread over thousands of lines and several
# files, entangled with tty layer, VC state and fbdev, and nowhere in it is
# there a function that takes a character and returns the pixels that character
# puts on screen.  There is simply nothing for gcc to build into
# oracle-console.o.
#
# So the test carries its own oracle, in two layers: a reference model of the
# character grid (cursor, wrap, scroll, tabs, backspace) AND a reference model
# of the framebuffer that grid should have produced.  It links the REAL
# renderer underneath and compares every 32-bit word of a simulated
# framebuffer, because cursor state on its own would pass a console that drew
# every glyph in the wrong place -- or none at all.
