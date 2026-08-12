/* Differential + behavioural test for src/drivers/video/fk_gop_renderer.f90
 *
 * TWO INDEPENDENT ORACLES, because this module has two independent ways to be
 * silently wrong.
 *
 * (1) THE FONT IS A TRANSLATION, so it gets the same treatment as every other
 *     translation in this project: all 4096 bytes of the Fortran table are
 *     compared against font_vga_8x16, compiled here from the kernel's own
 *     lib/fonts/font_8x16.c. A single transcription slip in a 4096-byte table
 *     is invisible to inspection and would show up on screen only as one
 *     malformed glyph nobody happens to type.
 *
 * (2) THE RENDERER IS NOT A TRANSLATION -- there is no C original to diff
 *     against -- so it is checked against a reference model written here from
 *     the GOP specification, and the check is EVERY BYTE of the framebuffer,
 *     not a sample. Byte-exact comparison is what catches the failure modes
 *     that a "did some pixels light up" test cannot:
 *
 *       * horizontal mirroring   -- reading font bytes LSB-first instead of
 *         MSB-first lights the same NUMBER of pixels, so any count-based or
 *         spot-check test passes while every glyph on screen is backwards.
 *       * pitch vs width         -- addressing by y*width+x instead of
 *         y*stride+x is correct for the first scanline and shears
 *         progressively down the screen. The framebuffers below therefore all
 *         use pitch > width*4, which is the normal case on real UEFI GOP.
 *       * off-by-one / clipping  -- the untouched slack bytes at the end of
 *         every scanline are verified to still hold the 0xAA sentinel, so a
 *         one-pixel overrun is a hard failure rather than an invisible one.
 *
 * The reference model deliberately does NOT share code with the module under
 * test: it recomputes offsets from pitch and reads bits with an explicit
 * (b >> (7 - dx)) & 1, so a shared misconception cannot cancel out.
 */
#include <linux/font.h>
#include <stdlib.h>
#include <string.h>
#include "fk_test.h"

/* oracle: compiled from vendor/linux-*/
extern const struct font_desc font_vga_8x16;

/* Fortran bind(c) exports */
int32_t vga_init_framebuffer(int64_t base, int32_t w, int32_t h, int32_t pitch);
void    vga_plot_pixel(int32_t x, int32_t y, int32_t color);
void    vga_print_char(char c, int32_t x, int32_t y, int32_t color);
void    vga_print_string(const char *s, int32_t max_chars,
			 int32_t x, int32_t y, int32_t color);
void    vga_fill_rect(int32_t x, int32_t y, int32_t w, int32_t h, int32_t color);
int32_t vga_font_row(int32_t ch, int32_t row);

#define SENTINEL 0xAA
#define GLYPH_W  8
#define GLYPH_H  16

/* Guard regions bracketing every test framebuffer.
 *
 * Byte-comparing only the framebuffer itself cannot see a write that lands
 * PAST it -- and that is precisely what a missing clip does. Removing the
 * bottom-edge clip made vga_plot_pixel(0, fb_height) store one word beyond the
 * allocation: a real heap overflow, invisible to a comparison bounded by the
 * allocation. With guards, any store outside the framebuffer is a hard
 * failure instead of silent corruption (or a malloc-metadata crash later). */
#define GUARD 4096

/* ---- reference model: an independent implementation of the same contract -- */

struct fbref {
	uint8_t *base;	/* allocation start: GUARD, framebuffer, GUARD */
	uint8_t *px;	/* the real framebuffer handed to Fortran */
	uint8_t *sh;	/* the shadow the reference model draws into */
	int32_t  w, h;	/* visible geometry */
	int32_t  pitch;	/* BYTES per scanline, deliberately > w*4 */
	size_t   bytes;
};

static void ref_plot(struct fbref *f, int32_t x, int32_t y, int32_t color)
{
	if (x < 0 || x >= f->w || y < 0 || y >= f->h)
		return;
	memcpy(f->sh + (size_t)y * f->pitch + (size_t)x * 4, &color, 4);
}

static void ref_char(struct fbref *f, const unsigned char *font,
		     int ch, int32_t x, int32_t y, int32_t color)
{
	int r, dx;

	for (r = 0; r < GLYPH_H; r++) {
		unsigned b = font[ch * GLYPH_H + r];

		for (dx = 0; dx < GLYPH_W; dx++)
			if ((b >> (7 - dx)) & 1)	/* MSB is the LEFT pixel */
				ref_plot(f, x + dx, y + r, color);
	}
}

static void ref_string(struct fbref *f, const unsigned char *font,
		       const char *s, int32_t max_chars,
		       int32_t x, int32_t y, int32_t color)
{
	int32_t i;

	for (i = 0; i < max_chars; i++) {
		int64_t gx = (int64_t)x + (int64_t)i * GLYPH_W;	/* int64: see ref_rect */

		if (s[i] == '\0')
			return;
		if (gx >= f->w)		/* wholly past the right edge */
			return;
		ref_char(f, font, (unsigned char)s[i], (int32_t)gx, y, color);
	}
}

/* Bounds computed in int64 ON PURPOSE. Written the obvious way, `py < y + h`
 * overflows in int32 for large h and the model draws nothing -- which is
 * exactly what the module used to do, so the two agreed and the test passed
 * while both were wrong. A reference model that shares the bug certifies
 * nothing, so this one is widened and the module has to meet it. */
static void ref_rect(struct fbref *f, int32_t x, int32_t y,
		     int32_t w, int32_t h, int32_t color)
{
	int64_t px, py;

	if (w <= 0 || h <= 0)
		return;
	for (py = y; py < (int64_t)y + h; py++) {
		if (py < 0 || py >= f->h)
			continue;
		for (px = x; px < (int64_t)x + w; px++)
			ref_plot(f, (int32_t)px, (int32_t)py, color);
	}
}

/* ---- helpers ------------------------------------------------------------ */

static void fb_new(struct fbref *f, int32_t w, int32_t h, int32_t pitch)
{
	f->w = w;
	f->h = h;
	f->pitch = pitch;
	f->bytes = (size_t)pitch * h;
	f->base = malloc(f->bytes + 2 * GUARD);
	f->sh = malloc(f->bytes);
	if (!f->base || !f->sh) {
		printf("  ALLOC FAILED\n");
		exit(2);
	}
	memset(f->base, SENTINEL, f->bytes + 2 * GUARD);
	memset(f->sh, SENTINEL, f->bytes);
	f->px = f->base + GUARD;	/* Fortran only ever learns this address */
}

static void fb_free(struct fbref *f)
{
	free(f->base);
	free(f->sh);
}

/* Compare every byte, including the off-screen slack at the end of each
 * scanline and the whole of any row past the mapped region. */
static void fb_verify(struct fbref *f, const char *what)
{
	size_t i;
	unsigned long before = fk_fails;

	/* nothing may have been written outside the framebuffer at all */
	for (i = 0; i < GUARD; i++) {
		fk_checks++;
		if (f->base[i] != SENTINEL) {
			if (fk_fails - before < 3)
				printf("  OVERRUN %s: wrote %zu bytes BEFORE the "
				       "framebuffer (0x%02X)\n",
				       what, GUARD - i, f->base[i]);
			fk_fails++;
		}
		fk_checks++;
		if (f->px[f->bytes + i] != SENTINEL) {
			if (fk_fails - before < 3)
				printf("  OVERRUN %s: wrote %zu bytes PAST the "
				       "framebuffer (0x%02X)\n",
				       what, i + 1, f->px[f->bytes + i]);
			fk_fails++;
		}
	}

	for (i = 0; i < f->bytes; i++) {
		fk_checks++;
		if (f->px[i] != f->sh[i]) {
			if (fk_fails - before < 6)
				printf("  MISMATCH %s: byte %zu (row %zu, col %zu) "
				       "fortran=0x%02X model=0x%02X\n",
				       what, i, i / f->pitch,
				       (i % f->pitch) / 4,
				       f->px[i], f->sh[i]);
			fk_fails++;
		}
	}
}

static int64_t addr_of(const void *p)
{
	return (int64_t)(uintptr_t)p;
}

int main(void)
{
	const unsigned char *oracle = font_data_buf(font_vga_8x16.data);
	struct fbref f;
	int ch, row, i;

	/* --- (1) the font table, byte for byte, against the kernel's own --- */
	FK_EQ("font width",     (int)font_vga_8x16.width,     8,   "%d");
	FK_EQ("font height",    (int)font_vga_8x16.height,    16,  "%d");
	FK_EQ("font charcount", (int)font_vga_8x16.charcount, 256, "%d");

	for (ch = 0; ch < 256; ch++)
		for (row = 0; row < GLYPH_H; row++)
			FK_EQ("font_row", (int)oracle[ch * GLYPH_H + row],
			      (int)vga_font_row(ch, row), "0x%02X");

	/* out-of-range requests are refused, not wrapped into the table */
	FK_EQ("font_row(-1,0)",  -1, (int)vga_font_row(-1, 0),  "%d");
	FK_EQ("font_row(256,0)", -1, (int)vga_font_row(256, 0), "%d");
	FK_EQ("font_row(0,-1)",  -1, (int)vga_font_row(0, -1),  "%d");
	FK_EQ("font_row(0,16)",  -1, (int)vga_font_row(0, 16),  "%d");

	/* --- (2a) every geometry refusal, and the disarm that follows ----- */
	fb_new(&f, 64, 48, 320);	/* stride 80px, 16px of slack per row */

	FK_EQ("init null base",   -4, (int)vga_init_framebuffer(0, 64, 48, 320), "%d");
	FK_EQ("init w<=0",        -1, (int)vga_init_framebuffer(addr_of(f.px), 0, 48, 320), "%d");
	FK_EQ("init h<=0",        -1, (int)vga_init_framebuffer(addr_of(f.px), 64, 0, 320), "%d");
	FK_EQ("init pitch<w*4",   -2, (int)vga_init_framebuffer(addr_of(f.px), 64, 48, 255), "%d");
	FK_EQ("init pitch%%4",    -3, (int)vga_init_framebuffer(addr_of(f.px), 64, 48, 322), "%d");

	/* A renderer that refused its geometry must be inert. If it is not,
	 * a bad Multiboot2 handoff scribbles over firmware memory. */
	vga_plot_pixel(0, 0, 0x00FFFFFF);
	vga_print_char('A', 0, 0, 0x00FFFFFF);
	vga_print_string("hello", 5, 0, 0, 0x00FFFFFF);
	vga_fill_rect(0, 0, 64, 48, 0x00FFFFFF);
	fb_verify(&f, "inert after refused init");

	/* --- (2a2) INTEGER-OVERFLOW REGRESSIONS ---------------------------
	 * Every case below was ACCEPTED (status 0) before the guard was widened
	 * to 64 bits: `pitch_bytes < width * 4` computed the product in int32,
	 * so for width >= 2**29 it wrapped non-positive and the comparison was
	 * false for every possible pitch. The renderer then armed with a stride
	 * that could not hold one visible row, and its own per-pixel clip
	 * (x < fb_width) authorised stores far past the real framebuffer.
	 * The last case is the nastiest: a NEGATIVE pitch, reachable only
	 * through that wrap, which the logical shift turns into a stride of
	 * ~1e9 words -- the first y=1 store lands ~4 GiB from base. */
	FK_EQ("init w=2**29-1 ok-reject", -2,
	      (int)vga_init_framebuffer(addr_of(f.px), 536870911, 1080, 7680), "%d");
	FK_EQ("init w=2**29 (w*4==INT32_MIN)", -2,
	      (int)vga_init_framebuffer(addr_of(f.px), 536870912, 1080, 7680), "%d");
	FK_EQ("init w=2**30 (w*4 wraps to 0)", -2,
	      (int)vga_init_framebuffer(addr_of(f.px), 1073741824, 1080, 7680), "%d");
	FK_EQ("init w=INT32_MAX (w*4 == -4)", -2,
	      (int)vga_init_framebuffer(addr_of(f.px), 2147483647, 1080, 7680), "%d");
	FK_EQ("init negative pitch", -2,
	      (int)vga_init_framebuffer(addr_of(f.px), 536870912, 1080, -8), "%d");

	/* and nothing above may have armed the renderer or touched memory */
	vga_plot_pixel(0, 0, 0x00FFFFFF);
	vga_fill_rect(0, 0, 100, 100, 0x00FFFFFF);
	fb_verify(&f, "inert after overflow-geometry rejections");

	/* --- (2b) armed: edges, clipping, strings, rectangles ------------- */
	FK_EQ("init ok", 0, (int)vga_init_framebuffer(addr_of(f.px), 64, 48, 320), "%d");

	/* exact corners: pins the +1 index conversion and the stride */
	vga_plot_pixel(0, 0, 0x00112233);        ref_plot(&f, 0, 0, 0x00112233);
	vga_plot_pixel(63, 0, 0x00445566);       ref_plot(&f, 63, 0, 0x00445566);
	vga_plot_pixel(0, 47, 0x00778899);       ref_plot(&f, 0, 47, 0x00778899);
	vga_plot_pixel(63, 47, 0x00AABBCC);      ref_plot(&f, 63, 47, 0x00AABBCC);

	/* one pixel outside each of the four edges must write nothing --
	 * note (64,0) would land in the scanline slack, which is mapped
	 * memory, so a missing clip here corrupts silently rather than faults */
	vga_plot_pixel(-1, 0, 0x00FF0000);       ref_plot(&f, -1, 0, 0x00FF0000);
	vga_plot_pixel(64, 0, 0x00FF0000);       ref_plot(&f, 64, 0, 0x00FF0000);
	vga_plot_pixel(0, -1, 0x00FF0000);       ref_plot(&f, 0, -1, 0x00FF0000);
	vga_plot_pixel(0, 48, 0x00FF0000);       ref_plot(&f, 0, 48, 0x00FF0000);
	vga_plot_pixel(-99999, -99999, 0x00FF0000);
	ref_plot(&f, -99999, -99999, 0x00FF0000);

	/* glyphs straddling the right and bottom edges: partially drawn */
	vga_print_char('W', 60, 4, 0x0000FF00);
	ref_char(&f, oracle, 'W', 60, 4, 0x0000FF00);
	vga_print_char('M', 8, 40, 0x0000FF00);
	ref_char(&f, oracle, 'M', 8, 40, 0x0000FF00);
	vga_print_char('#', -3, 20, 0x0000FF00);
	ref_char(&f, oracle, '#', -3, 20, 0x0000FF00);

	/* NUL termination stops early; max_chars bounds an unterminated run */
	vga_print_string("Hi\0XX", 5, 0, 16, 0x00FFFFFF);
	ref_string(&f, oracle, "Hi\0XX", 5, 0, 16, 0x00FFFFFF);
	vga_print_string("ABCDEFGHIJ", 3, 16, 32, 0x00CCCCCC);
	ref_string(&f, oracle, "ABCDEFGHIJ", 3, 16, 32, 0x00CCCCCC);
	vga_print_string("ignored", 0, 0, 0, 0x00FFFFFF);
	ref_string(&f, oracle, "ignored", 0, 0, 0, 0x00FFFFFF);

	/* rectangles, including one clipped on every side at once */
	vga_fill_rect(2, 2, 5, 3, 0x00010203);   ref_rect(&f, 2, 2, 5, 3, 0x00010203);
	vga_fill_rect(-4, -4, 200, 200, 0x00040506);
	ref_rect(&f, -4, -4, 200, 200, 0x00040506);
	vga_fill_rect(10, 10, 0, 5, 0x00FF00FF); ref_rect(&f, 10, 10, 0, 5, 0x00FF00FF);
	vga_fill_rect(10, 10, -3, 5, 0x00FF00FF);ref_rect(&f, 10, 10, -3, 5, 0x00FF00FF);

	/* loop-bound overflow: `py < y + h` in int32 wrapped negative and the
	 * fill silently drew NOTHING where it should have covered the screen */
	vga_fill_rect(2, 0, 2147483647, 48, 0x00070809);
	ref_rect(&f, 2, 0, 2147483647, 48, 0x00070809);
	vga_fill_rect(0, 2, 64, 2147483647, 0x000A0B0C);
	ref_rect(&f, 0, 2, 64, 2147483647, 0x000A0B0C);
	vga_fill_rect(2147483640, 0, 64, 48, 0x000D0E0F);
	ref_rect(&f, 2147483640, 0, 64, 48, 0x000D0E0F);

	/* string x advance: `x + (i-1)*8` in int32 wraps for very long runs and
	 * (with -fwrapv, quietly) puts glyphs back on the LEFT edge */
	{
		static char longstr[64];
		memset(longstr, 'X', sizeof(longstr) - 1);
		longstr[sizeof(longstr) - 1] = '\0';
		vga_print_string(longstr, 2147483647, 0, 8, 0x00111213);
		ref_string(&f, oracle, longstr, 2147483647, 0, 8, 0x00111213);
		vga_print_string(longstr, 2147483647, 2147483640, 24, 0x00141516);
		ref_string(&f, oracle, longstr, 2147483647, 2147483640, 24, 0x00141516);
	}

	fb_verify(&f, "64x48 stride-80");
	fb_free(&f);

	/* --- (2c) every one of the 256 glyphs actually rendered ----------- */
	/* 16x16 grid of 8x16 cells == 128x256 px. Stride 141 px is deliberately
	 * odd and not a multiple of the glyph width, so any place the code
	 * confuses stride with width misaligns immediately. */
	fb_new(&f, 128, 256, 141 * 4);
	FK_EQ("init grid", 0, (int)vga_init_framebuffer(addr_of(f.px), 128, 256, 141 * 4), "%d");

	for (ch = 0; ch < 256; ch++) {
		int32_t gx = (ch % 16) * GLYPH_W;
		int32_t gy = (ch / 16) * GLYPH_H;
		int32_t colr = (int32_t)(0x00010101u * (unsigned)(ch + 1));

		vga_print_char((char)ch, gx, gy, colr);
		ref_char(&f, oracle, ch, gx, gy, colr);
	}
	fb_verify(&f, "256-glyph grid, stride 141");
	fb_free(&f);

	/* --- (2d) a re-init that FAILS must disarm an already-armed fb ---- */
	fb_new(&f, 32, 16, 160);
	FK_EQ("init small", 0, (int)vga_init_framebuffer(addr_of(f.px), 32, 16, 160), "%d");
	vga_fill_rect(0, 0, 32, 16, 0x00202020);
	ref_rect(&f, 0, 0, 32, 16, 0x00202020);
	fb_verify(&f, "armed small fb");

	FK_EQ("re-init rejected", -2,
	      (int)vga_init_framebuffer(addr_of(f.px), 32, 16, 4), "%d");
	for (i = 0; i < 32; i++)
		vga_plot_pixel(i, i % 16, 0x00FF00FF);	/* must all be dropped */
	fb_verify(&f, "inert after failed re-init");
	fb_free(&f);

	return fk_report("gop_renderer");
}
