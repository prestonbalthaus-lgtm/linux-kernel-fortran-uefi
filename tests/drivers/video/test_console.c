/* Differential + behavioural test for src/drivers/video/fk_console.f90
 *
 * WHAT THIS DIFFS AGAINST, SINCE IT IS NOT A C FUNCTION.  A terminal emulator
 * has no single original to compile and compare with -- the kernel's own
 * console is drivers/tty/vt/vt.c driving drivers/video/fbdev/core/fbcon.c
 * through a consw ops table, thousands of lines of escape-sequence state
 * machine, and nothing in it maps "a character" to "the pixels that character
 * puts on screen".  So this file carries the oracle, exactly as
 * tests/mm/test_pmm.c does: a reference model of the character grid AND of the
 * framebuffer the grid is supposed to have produced.
 *
 * IT IS THE REAL RENDERER UNDERNEATH.  fk_gop_renderer.f90 and fk_font_8x16.f90
 * are linked in and the console draws through them for real; the comparison is
 * every 32-bit word of a simulated framebuffer.  That is the whole point of the
 * exercise -- the console owns cell geometry and the renderer owns pixels, and
 * the only thing that can prove the split is honest is checking that the two
 * agree on the picture.  Cursor state alone would pass a console that put every
 * glyph in the wrong place, or drew none at all.
 *
 * The failure modes byte-exactness buys, over and above the renderer's own:
 *
 *   * off-by-one at the wrap boundary -- a console that wraps at cols-1 or at
 *     cols+1 has the same cursor arithmetic modulo one cell and lays the text
 *     out differently on every line after the first.
 *   * a transparent cell -- vga_print_char composes over what is already
 *     there, so a console that forgets its background fill leaves the old
 *     glyph showing through the new one.  Both are lit; a pixel count agrees.
 *   * a scroll that moves the wrong band -- copying from y+FONT_H when the
 *     grid says y, or one scanline too far, is invisible until text scrolls
 *     off the top, and then only as text that looks slightly wrong.
 *   * eating somebody else's pixels -- top_y exists so the boot status bar
 *     survives a screen that has wrapped many times.  The reserved band is
 *     snapshotted and memcmp'd OUTSIDE the reference model, because a model
 *     that scrolled the bar too would agree with a console that ate it.
 *
 * PITCH > WIDTH*4 EVERYWHERE, this tree's standing hazard: every framebuffer
 * below has off-screen slack at the end of each scanline, and the slack is
 * compared too, so addressing by y*width instead of y*stride is a hard failure
 * rather than a picture that shears.
 *
 * WHAT THE MODEL IS NOT.  It is an independent implementation, not an
 * independent derivation -- it and the Fortran were written from the same
 * reading of what a console does, so a shared misreading is duplicated rather
 * than caught.  What it does not share is code or arithmetic: it walks font
 * bytes with its own (b >> (7 - dx)) & 1, recomputes every offset from pitch,
 * and expresses the grid rules as a terminal contract rather than as the
 * module's control flow.
 *
 * ONE DELIBERATE AGREEMENT, STATED SO IT IS NOT MISTAKEN FOR AN OVERSIGHT.
 * vga_scroll_up takes no x range: it moves and refills the FULL framebuffer
 * width.  console_clear fills only cols*FONT_W.  So a console whose width is
 * not a whole number of cells scrolls a right-hand margin it never clears.
 * The model mirrors the composed behaviour -- that is what the code does, and
 * this test's job is to pin it, not to arbitrate it.  scenario_scroll() is
 * built so the discrepancy is visible: its framebuffer is 120px wide and its
 * console 112.
 */
#include <stdlib.h>
#include <string.h>
#include "fk_test.h"

/* ---- Fortran bind(c) exports -------------------------------------------- */

/* the renderer the console draws through -- the real one, linked in */
int32_t vga_init_framebuffer(int64_t base, int32_t w, int32_t h, int32_t pitch);
int32_t vga_font_row(int32_t ch, int32_t row);

/* the console under test */
int32_t console_init(int32_t width, int32_t height, int32_t top_y,
		     int32_t fg_color, int32_t bg_color);
void    console_putc(char c);
void    console_write(const char *s, int32_t max_chars);
void    console_print_hex(int64_t v, int32_t digits);
void    console_clear(void);
void    console_newline(void);
void    console_set_color(int32_t fg_color, int32_t bg_color);
int32_t console_cols(void);
int32_t console_rows(void);
int32_t console_x(void);
int32_t console_y(void);
int32_t console_ready(void);

/* The scroll counter is a bind(c) module VARIABLE, not an accessor, so the
 * comparison here is against the real thing. */
extern int64_t fk_console_scrolls;

/* ---- the three symbols boot/interrupts.S supplies in the kernel ---------- */
/* The console's lock()/unlock() call these; boot/ is assembly and is not
 * linked into a host test, so they are mocked here -- and the mock counts, so
 * "one critical section per console_write" and "restore IF, never blanket STI"
 * become assertions rather than comments. */
static int64_t       g_rflags = 0x202;	/* IF (bit 9) set: the ordinary caller */
static unsigned long g_cli, g_sti;

int64_t fk_read_rflags(void) { return g_rflags; }
void    fk_irq_disable(void) { g_cli++; }
void    fk_irq_enable(void)  { g_sti++; }

/* ---- constants, mirroring the two modules ------------------------------- */

#define FONT_W            8
#define FONT_H            16
#define FK_CON_TAB        8
#define FK_CON_OK         0
#define FK_CON_E_GEOMETRY (-1)

#define SENTINEL 0xAA
#define GUARD    4096		/* see test_gop_renderer.c: a store PAST the
				 * framebuffer is invisible to a comparison
				 * bounded by the allocation */

#define EQ32(what, c, f) FK_EQ(what, (int)(c), (int)(f), "%d")
#define EQ64(what, c, f) FK_EQ(what, (long long)(c), (long long)(f), "%lld")
#define EQU(what, c, f)  FK_EQ(what, (unsigned long)(c), (unsigned long)(f), "%lu")

/* A scenario runs dozens of checks and "MISMATCH 4-row band" twelve times over
 * names none of them.  One buffer, built per failing check. */
static char fk_lbl[160];
static const char *L(const char *what, const char *field)
{
	snprintf(fk_lbl, sizeof(fk_lbl), "%s / %s", what, field);
	return fk_lbl;
}

/* ---- the framebuffer, and the shadow the model draws into ---------------- */

struct fbref {
	uint8_t *base;	/* allocation start: GUARD, framebuffer, GUARD */
	uint8_t *px;	/* the real framebuffer handed to Fortran */
	uint8_t *sh;	/* the shadow the reference model draws into */
	int32_t  w, h;	/* visible geometry */
	int32_t  pitch;	/* BYTES per scanline, deliberately > w*4 */
	size_t   bytes;
};

static struct fbref F;

static void fb_new(int32_t w, int32_t h, int32_t stride_px)
{
	F.w = w;
	F.h = h;
	F.pitch = stride_px * 4;
	F.bytes = (size_t)F.pitch * h;
	F.base = malloc(F.bytes + 2 * GUARD);
	F.sh = malloc(F.bytes);
	if (!F.base || !F.sh) {
		printf("  ALLOC FAILED\n");
		exit(2);
	}
	memset(F.base, SENTINEL, F.bytes + 2 * GUARD);
	memset(F.sh, SENTINEL, F.bytes);
	F.px = F.base + GUARD;	/* Fortran only ever learns this address */
}

static void fb_free(void)
{
	free(F.base);
	free(F.sh);
	F.base = F.px = F.sh = NULL;
}

static int64_t addr_of(const void *p)
{
	return (int64_t)(uintptr_t)p;
}

/* Put a picture on screen the way the boot stub already has -- straight into
 * the real buffer AND the shadow, behind the renderer's back.  It is then
 * common ground both implementations inherit rather than something either of
 * them drew, which is what makes "untouched" mean anything. */
static void fb_paint(int32_t x, int32_t y, int32_t w, int32_t h, uint32_t color)
{
	int32_t px, py;

	for (py = y; py < y + h; py++)
		for (px = x; px < x + w; px++) {
			size_t o = (size_t)py * F.pitch + (size_t)px * 4;

			memcpy(F.px + o, &color, 4);
			memcpy(F.sh + o, &color, 4);
		}
}

/* Every 32-bit word, including the off-screen slack at the end of each
 * scanline, plus the guard pages either side.  Reports the FIRST divergence as
 * a pixel coordinate and the two words: "word 8213 differs" is not something
 * anybody can act on. */
static void fb_verify(const char *what)
{
	size_t stride_w = (size_t)F.pitch / 4;
	size_t nwords = F.bytes / 4;
	size_t i, bad = 0;
	unsigned long before = fk_fails;

	for (i = 0; i < GUARD; i++) {
		fk_checks += 2;
		if (F.base[i] != SENTINEL) {
			if (fk_fails - before < 2)
				printf("  OVERRUN %s: wrote %zu bytes BEFORE the "
				       "framebuffer (0x%02X)\n",
				       what, (size_t)GUARD - i, F.base[i]);
			fk_fails++;
		}
		if (F.px[F.bytes + i] != SENTINEL) {
			if (fk_fails - before < 2)
				printf("  OVERRUN %s: wrote %zu bytes PAST the "
				       "framebuffer (0x%02X)\n",
				       what, i + 1, F.px[F.bytes + i]);
			fk_fails++;
		}
	}

	for (i = 0; i < nwords; i++) {
		uint32_t got, want;

		fk_checks++;
		memcpy(&got, F.px + i * 4, 4);
		memcpy(&want, F.sh + i * 4, 4);
		if (got == want)
			continue;
		if (!bad)
			printf("  MISMATCH %s: first differing pixel x=%zu y=%zu  "
			       "fortran=0x%08X model=0x%08X%s\n",
			       what, i % stride_w, i / stride_w, got, want,
			       (i % stride_w) >= (size_t)F.w
					? "   (off-screen scanline slack)" : "");
		bad++;
		fk_fails++;
	}
	if (bad > 1)
		printf("  MISMATCH %s: %zu differing pixels in all\n", what, bad);
}

/* ---- reference model, layer 1: the renderer's contract ------------------- */

static void ref_plot(int32_t x, int32_t y, int32_t color)
{
	if (x < 0 || x >= F.w || y < 0 || y >= F.h)
		return;
	memcpy(F.sh + (size_t)y * F.pitch + (size_t)x * 4, &color, 4);
}

/* Bounds in int64 on purpose; see test_gop_renderer.c's ref_rect. */
static void ref_rect(int32_t x, int32_t y, int32_t w, int32_t h, int32_t color)
{
	int64_t px, py;

	if (w <= 0 || h <= 0)
		return;
	for (py = y; py < (int64_t)y + h; py++)
		for (px = x; px < (int64_t)x + w; px++)
			ref_plot((int32_t)px, (int32_t)py, color);
}

/* The glyph, walked MSB-first out of the font accessor.  vga_font_row is the
 * font's only interface and its 4096 bytes already have a real oracle --
 * test_gop_renderer.c diffs every one against the kernel's compiled
 * font_vga_8x16 -- so reading the table through it here borrows that proof
 * instead of duplicating it.  The bit walk is this file's own. */
static void ref_char(int ch, int32_t x, int32_t y, int32_t color)
{
	int r, dx;

	for (r = 0; r < FONT_H; r++) {
		int bits = vga_font_row(ch, r);

		for (dx = 0; dx < FONT_W; dx++)
			if ((bits >> (FONT_W - 1 - dx)) & 1)	/* MSB is LEFT */
				ref_plot(x + dx, y + r, color);
	}
}

/* vga_scroll_up's contract: move the band [y0, y0+h) up by dy and fill what it
 * vacated.  NOTE THE ABSENT X RANGE -- the whole scanline moves, all F.w of
 * it, which is the agreement the file header calls out. */
static void ref_scroll_up(int32_t y0, int32_t h, int32_t dy, int32_t color)
{
	int32_t band, r;

	if (h <= 0 || dy <= 0)
		return;
	if (y0 < 0 || y0 >= F.h)
		return;
	band = h < F.h - y0 ? h : F.h - y0;	/* clip before moving anything */
	if (dy >= band) {
		ref_rect(0, y0, F.w, band, color);
		return;
	}
	for (r = 0; r < band - dy; r++)
		memmove(F.sh + (size_t)(y0 + r) * F.pitch,
			F.sh + (size_t)(y0 + r + dy) * F.pitch,
			(size_t)F.w * 4);
	ref_rect(0, y0 + band - dy, F.w, dy, color);
}

/* ---- reference model, layer 2: the character grid ------------------------ */

struct conref {
	int32_t cols, rows, cx, cy, org_y, fg, bg;
	int     armed;
};

static struct conref C;

/* fk_console_scrolls is never reset -- console_init does not zero it -- so the
 * expectation is cumulative over the whole process, not per fixture. */
static int64_t g_scrolls;

static void cref_clear(void)
{
	ref_rect(0, C.org_y, C.cols * FONT_W, C.rows * FONT_H, C.bg);
	C.cx = 0;
	C.cy = 0;
}

static int32_t cref_init(int32_t w, int32_t h, int32_t top,
			 int32_t fg, int32_t bg)
{
	C.armed = 0;
	/* The reserved band must lie inside a screen that exists, and what is
	 * left below it must hold at least one whole character cell. */
	if (w <= 0 || h <= 0 || top < 0 || top >= h)
		return FK_CON_E_GEOMETRY;
	if (w / FONT_W < 1 || (h - top) / FONT_H < 1)
		return FK_CON_E_GEOMETRY;

	C.cols = w / FONT_W;
	C.rows = (h - top) / FONT_H;
	C.org_y = top;
	C.fg = fg;
	C.bg = bg;
	C.armed = 1;
	cref_clear();
	return FK_CON_OK;
}

/* Down one row, or -- when there is no row below -- scroll the band and stay
 * on the last one.  The column goes to 0 either way: this console's LF is a
 * newline, not an index-down. */
static void cref_nl(void)
{
	C.cx = 0;
	if (++C.cy < C.rows)
		return;
	C.cy = C.rows - 1;
	ref_scroll_up(C.org_y, C.rows * FONT_H, FONT_H, C.bg);
	g_scrolls++;
}

static void cref_put(int code)
{
	int32_t stop;

	switch (code) {
	case 13:				/* CR: column 0, same row */
		C.cx = 0;
		return;
	case 10:				/* LF */
		cref_nl();
		return;
	case 8:					/* BS: never past column 0 */
		if (C.cx > 0)
			C.cx--;
		return;
	case 9:					/* HT: the next tab stop, and
						 * off the end is a wrap */
		stop = (C.cx / FK_CON_TAB + 1) * FK_CON_TAB;
		if (stop < C.cols)
			C.cx = stop;
		else
			cref_nl();
		return;
	default:
		break;
	}
	if (code < 0x20)			/* no glyph, no motion */
		return;

	/* An opaque cell: background first, then the glyph over it. */
	ref_rect(C.cx * FONT_W, C.org_y + C.cy * FONT_H, FONT_W, FONT_H, C.bg);
	ref_char(code, C.cx * FONT_W, C.org_y + C.cy * FONT_H, C.fg);
	if (++C.cx >= C.cols)			/* wrap the moment the last
						 * column is filled */
		cref_nl();
}

/* ---- drive both implementations from one call --------------------------- */

static int32_t init_both(int32_t w, int32_t h, int32_t top,
			 int32_t fg, int32_t bg)
{
	int32_t got = console_init(w, h, top, fg, bg);
	int32_t want = cref_init(w, h, top, fg, bg);

	EQ32("console_init status", want, got);
	return got;
}

static void putc_both(int code)
{
	console_putc((char)code);
	if (C.armed)
		cref_put(code);
}

static void puts_both(const char *s)
{
	while (*s)
		putc_both((unsigned char)*s++);
}

static void write_both(const char *s, int32_t max_chars)
{
	int32_t i;

	console_write(s, max_chars);
	if (!C.armed || max_chars <= 0)
		return;
	for (i = 0; i < max_chars; i++) {
		if (s[i] == '\0')
			return;
		cref_put((unsigned char)s[i]);
	}
}

/* Most significant nibble first.  The shift is UNSIGNED here on purpose: it is
 * the independent statement of what the module's ISHFT-with-a-negative-count
 * must do, and an arithmetic shift would smear the sign bit of a high address
 * across every digit above the top nibble. */
static void hex_both(int64_t v, int32_t digits)
{
	static const char H[] = "0123456789ABCDEF";
	int32_t i;

	console_print_hex(v, digits);
	if (!C.armed || digits <= 0 || digits > 16)
		return;
	for (i = digits - 1; i >= 0; i--)
		cref_put(H[((uint64_t)v >> (4 * i)) & 15]);
}

static void nl_both(void)
{
	console_newline();
	if (C.armed)
		cref_nl();
}

static void clear_both(void)
{
	console_clear();
	if (C.armed)
		cref_clear();
}

/* console_set_color does not consult `armed` and takes no lock; the model
 * follows it rather than guessing. */
static void color_both(int32_t fg, int32_t bg)
{
	console_set_color(fg, bg);
	C.fg = fg;
	C.bg = bg;
}

/* Pixels first, then everything the module will tell us about its own state. */
static void verify(const char *what)
{
	fb_verify(what);
	EQ32(L(what, "cursor x"), C.cx, console_x());
	EQ32(L(what, "cursor y"), C.cy, console_y());
	EQ32(L(what, "cols"), C.cols, console_cols());
	EQ32(L(what, "rows"), C.rows, console_rows());
	EQ64(L(what, "scroll count"), g_scrolls, fk_console_scrolls);
}

static void fixture(int32_t w, int32_t h, int32_t stride_px)
{
	fb_new(w, h, stride_px * 1);
	EQ32("vga_init_framebuffer", 0,
	     (int)vga_init_framebuffer(addr_of(F.px), w, h, stride_px * 4));
}

/* ---- scenario: text, wrapping, control codes, hex, strings --------------- */

/* 136x96 visible on a 170-pixel stride.  cols is 17 DELIBERATELY: the second
 * tab stop is column 16, which is the LAST column, and the third would be
 * column 24, which is off the end -- both tab edges the module documents, in
 * one geometry. */
static void scenario_text(void)
{
	const int32_t FG = 0x00E8E8E8, BG = 0x00102030;
	int i;

	fixture(136, 96, 170);
	EQ32("init 136x96", FK_CON_OK, init_both(136, 96, 0, FG, BG));
	EQ32("armed", 1, console_ready());
	EQ32("cols from width/FONT_W", 17, console_cols());
	EQ32("rows from height/FONT_H", 6, console_rows());
	verify("a cleared console");

	/* --- plain text, nowhere near a boundary --- */
	puts_both("Hello");
	EQ32("plain text: cursor advanced one cell per glyph", 5, console_x());
	verify("plain text, no wrap");

	/* --- an opaque cell.  A '.' over an 'M' leaves the M showing unless the
	 * background is filled first, and a SPACE over an 'M' is the same test
	 * run at the control-code boundary: 0x20 is the first code that draws,
	 * and what it draws is a cell of pure background. --- */
	putc_both('\r');
	puts_both("MMMMM");
	putc_both('\r');
	puts_both(".. ..");
	verify("a glyph, and a space, drawn over an existing glyph");

	/* --- the wrap boundary.  Exactly cols glyphs fill one row and leave the
	 * cursor at the START OF THE NEXT, not at column cols. --- */
	clear_both();
	for (i = 0; i < 17; i++)
		putc_both('0' + i % 10);
	EQ32("exactly cols glyphs: x", 0, console_x());
	EQ32("exactly cols glyphs: y", 1, console_y());
	verify("exact wrap at column cols");

	putc_both('#');
	EQ32("one past the wrap: x", 1, console_x());
	EQ32("one past the wrap: y", 1, console_y());
	verify("the first glyph of the wrapped row");

	/* --- CR, LF, CRLF --- */
	clear_both();
	write_both("abc\rX", 8);
	EQ32("CR alone: back to column 0, SAME row", 1, console_x());
	EQ32("CR alone: row unchanged", 0, console_y());
	verify("CR without LF");

	write_both("\ndown", 8);
	EQ32("LF alone: column 0 of the next row", 4, console_x());
	EQ32("LF alone: one row down", 1, console_y());
	verify("LF without CR");

	write_both("tail\r\nnext", 16);
	EQ32("CRLF: x", 4, console_x());
	EQ32("CRLF: y", 2, console_y());
	verify("CRLF");

	/* --- backspace.  At column 0 it must not move: a negative cx would put
	 * the next cell's background fill at a negative x. --- */
	clear_both();
	putc_both('\b');
	putc_both('\b');
	putc_both('\b');
	EQ32("backspace at column 0 does not go negative", 0, console_x());
	EQ32("backspace at column 0 does not change row", 0, console_y());
	verify("backspace at column 0 draws nothing");

	puts_both("ABCD");
	putc_both('\b');
	EQ32("backspace mid-line", 3, console_x());
	putc_both('!');			/* overwrites the D, opaquely */
	EQ32("and the next glyph lands there", 4, console_x());
	verify("backspace mid-line, then an overwrite");

	/* --- tab stops every 8 columns --- */
	clear_both();
	putc_both('\t');
	EQ32("tab from column 0", 8, console_x());
	putc_both('\t');
	EQ32("tab onto the last column", 16, console_x());
	putc_both('X');
	EQ32("filling the last column wraps: x", 0, console_x());
	EQ32("filling the last column wraps: y", 1, console_y());
	verify("tab onto the last column, then a wrap");

	puts_both("abcdefghijklmnop");	/* 16 glyphs: column 16, no wrap yet */
	EQ32("sixteen glyphs reach the last column", 16, console_x());
	putc_both('\t');		/* stop 24 is off the end: a wrap */
	EQ32("tab past the last column: x", 0, console_x());
	EQ32("tab past the last column: y", 2, console_y());
	verify("a tab past the last column is a wrap");

	puts_both("xyz");
	putc_both('\t');
	EQ32("tab from a column that is not a stop", 8, console_x());
	verify("tab from mid-stop");

	/* --- every control code below 0x20 that is not CR/LF/TAB/BS.  Cells
	 * 0x01..0x1F of this font are NOT blank -- they are CP437's smileys and
	 * arrows -- so a missing guard here is loud on screen. --- */
	clear_both();
	puts_both("mark");
	for (i = 0; i < 0x20; i++) {
		if (i == '\r' || i == '\n' || i == '\t' || i == '\b')
			continue;
		putc_both(i);
	}
	EQ32("control codes leave the column alone", 4, console_x());
	EQ32("control codes leave the row alone", 0, console_y());
	verify("control codes below 0x20 draw nothing");

	/* --- hex.  The high bit set is the case that matters. --- */
	clear_both();
	hex_both((int64_t)0x8000000000000000LL, 16);
	EQ32("print_hex 16 digits emits 16 glyphs", 16, console_x());
	verify("print_hex 0x8000000000000000: no sign smear");

	clear_both();
	hex_both((int64_t)-1, 16);
	hex_both((int64_t)0x1234, 2);	/* narrower than the value: low digits */
	hex_both((int64_t)0, 1);
	verify("print_hex widths");

	/* Refused widths draw nothing AND take no lock: the guard sits ahead of
	 * lock(), so getting that order wrong shows in the counters even though
	 * it leaves no mark on screen. */
	{
		unsigned long cli = g_cli, sti = g_sti;

		hex_both((int64_t)0xDEAD, 0);
		hex_both((int64_t)0xDEAD, 17);
		hex_both((int64_t)0xDEAD, -1);
		EQU("a refused print_hex takes no lock", cli, g_cli);
		EQU("a refused print_hex releases none", sti, g_sti);
	}
	verify("refused print_hex widths");

	/* --- console_write's two termination rules --- */
	clear_both();
	write_both("short\0GARBAGE", 13);
	EQ32("write stops at the NUL, not at max_chars", 5, console_x());
	verify("write: a NUL inside max_chars");

	nl_both();
	{
		char raw[6];

		memset(raw, 'Z', sizeof(raw));	/* no terminator at all */
		write_both(raw, 6);
	}
	EQ32("write bounded by max_chars", 6, console_x());
	verify("write: no terminator inside max_chars");

	{
		unsigned long cli = g_cli;

		write_both("ignored", 0);
		write_both("ignored", -3);
		EQU("write with max_chars <= 0 takes no lock", cli, g_cli);
	}
	verify("write: max_chars <= 0");

	/* --- ONE critical section for a whole string, not one per character:
	 * the module's stated reason for holding the lock across the loop is
	 * that a line half-printed by two threads is what it exists to
	 * prevent, and per-character locking would still pass every pixel
	 * check above. --- */
	{
		unsigned long cli = g_cli, sti = g_sti;

		write_both("0123456789", 10);
		EQU("console_write disables interrupts exactly once", cli + 1, g_cli);
		EQU("console_write restores them exactly once", sti + 1, g_sti);
	}
	verify("one critical section per write");

	/* --- colour changes take effect from the next glyph and leave drawn
	 * pixels alone; clear() then repaints the band in the new one --- */
	clear_both();
	puts_both("old");
	color_both(0x0000FF00, 0x00202020);
	puts_both("new");
	verify("set_color mid-line");
	clear_both();
	verify("clear repaints in the new background");

	fb_free();
}

/* ---- scenario: all 256 glyphs, and a tab stop landing exactly on cols ---- */

/* 128x256 on a 141-pixel stride: 16 columns by 16 rows.  The stride is odd and
 * not a multiple of the glyph width on purpose, so anywhere stride and width
 * are confused misaligns immediately. */
static void scenario_glyphs(void)
{
	int ch;

	fixture(128, 256, 141);
	EQ32("init 16x16", FK_CON_OK,
	     init_both(128, 256, 0, 0x00FFFFFF, 0x00000040));
	EQ32("cols", 16, console_cols());
	EQ32("rows", 16, console_rows());

	/* cols is 16 here, so the second tab stop is column 16 -- one PAST the
	 * last column, not on it.  That is a wrap, and the cursor must not be
	 * left sitting outside the grid. */
	putc_both('\t');
	EQ32("tab to stop 8", 8, console_x());
	putc_both('\t');
	EQ32("a tab stop at exactly cols wraps: x", 0, console_x());
	EQ32("a tab stop at exactly cols wraps: y", 1, console_y());
	verify("tab stop landing exactly on cols");

	/* 0x20..0xFF: 224 glyphs, 14 full rows, no scroll.  The upper half is
	 * the reason this exists -- the console reaches the font through
	 * achar(code, c_char) for code up to 255, a Fortran-integer-to-character
	 * conversion the renderer's own test never exercises because it passes C
	 * chars in from the other side. */
	clear_both();
	for (ch = 0x20; ch <= 0xFF; ch++)
		putc_both(ch);
	EQ32("224 glyphs end at column 0", 0, console_x());
	EQ32("224 glyphs fill exactly 14 rows", 14, console_y());
	verify("every glyph 0x20..0xFF, including the high half");

	fb_free();
}

/* ---- scenario: scrolling under a reserved band --------------------------- */

/* 120x80 on a 150-pixel stride, with a 16px status bar reserved at the top and
 * a console only 112px wide -- one cell narrower than the screen, so the
 * clear-vs-scroll width asymmetry the file header describes is in view. */
static void scenario_scroll(void)
{
	const int32_t TOP = 16, BG = 0x00000030;
	uint8_t *band, *before;
	size_t band_bytes;
	int64_t s0;
	int i, r, y, bad;

	fixture(120, 80, 150);

	/* A boot status bar, and a distinct colour under it, both already on
	 * screen before the console takes over. */
	fb_paint(0, 0, 120, TOP, 0x00FF3300);
	fb_paint(0, TOP, 120, 80 - TOP, 0x00003300);

	EQ32("init below a 16px bar", FK_CON_OK,
	     init_both(112, 80, TOP, 0x00FFFFFF, BG));
	EQ32("cols", 14, console_cols());
	EQ32("rows", 4, console_rows());
	verify("cleared, without touching the bar");

	/* The bar, kept OUTSIDE the reference model on purpose: a model that
	 * scrolled it too would agree with a console that ate it. */
	band_bytes = (size_t)TOP * F.pitch;
	band = malloc(band_bytes);
	if (!band) {
		printf("  ALLOC FAILED\n");
		exit(2);
	}
	memcpy(band, F.px, band_bytes);
	s0 = fk_console_scrolls;

	/* Four rows exactly fill the band and must not scroll. */
	for (r = 0; r < 4; r++) {
		if (r)
			nl_both();
		write_both("row", 4);
		putc_both('0' + r);
	}
	EQ64("four rows do not scroll", s0, fk_console_scrolls);
	EQ32("and the cursor is on the last one", 3, console_y());
	verify("four rows fill the band");

	/* --- the fifth line.  Asserted against a snapshot as well as against
	 * the model, so "moved up by exactly FONT_H" is checked directly rather
	 * than inferred from two implementations agreeing. --- */
	before = malloc(F.bytes);
	if (!before) {
		printf("  ALLOC FAILED\n");
		exit(2);
	}
	memcpy(before, F.px, F.bytes);

	nl_both();
	EQ64("the fifth line scrolls once", s0 + 1, fk_console_scrolls);
	EQ32("the cursor stays on the last row", 3, console_y());
	EQ32("at column 0", 0, console_x());
	verify("after one scroll");

	bad = 0;
	for (y = TOP; y < TOP + 3 * FONT_H; y++)
		if (memcmp(F.px + (size_t)y * F.pitch,
			   before + (size_t)(y + FONT_H) * F.pitch,
			   (size_t)F.w * 4))
			bad++;
	EQ32("the band moved up by exactly FONT_H pixel rows", 0, bad);

	/* The vacated row, over the FULL framebuffer width -- vga_scroll_up
	 * takes no x range, so the 8px margin the console never claimed is
	 * refilled along with the cells. */
	bad = 0;
	for (y = TOP + 3 * FONT_H; y < TOP + 4 * FONT_H; y++) {
		int x;

		for (x = 0; x < F.w; x++) {
			uint32_t w;

			memcpy(&w, F.px + (size_t)y * F.pitch + (size_t)x * 4, 4);
			if (w != (uint32_t)BG)
				bad++;
		}
	}
	EQ32("the vacated row is background", 0, bad);
	free(before);

	/* --- several more screens.  Each line is distinct, so a scroll that
	 * copied the wrong source row leaves the wrong text behind rather than
	 * a plausible screen. --- */
	for (i = 0; i < 23; i++) {
		char line[6];

		line[0] = 'L';
		line[1] = (char)('0' + (i / 10) % 10);
		line[2] = (char)('0' + i % 10);
		line[3] = '\r';
		line[4] = '\n';
		line[5] = '\0';
		write_both(line, 6);
	}
	EQ64("twenty-three more lines, twenty-three more scrolls",
	     s0 + 24, fk_console_scrolls);
	verify("five screens of scrolling");

	/* THE property: the reserved band never moved, bit for bit. */
	EQ32("the reserved band is bit-for-bit untouched", 0,
	     memcmp(band, F.px, band_bytes));
	free(band);

	fb_free();
}

/* ---- scenario: a console exactly one row tall ---------------------------- */

/* rows == 1 asks vga_scroll_up to move a one-cell band up by one whole cell:
 * dy >= band, so there is nothing to copy and the row is refilled instead.  An
 * implementation that copied anyway would read the row below the console. */
static void scenario_single_row(void)
{
	fixture(64, 48, 80);
	EQ32("init one row", FK_CON_OK,
	     init_both(64, 48, 32, 0x00CCCCCC, 0x00330000));
	EQ32("cols", 8, console_cols());
	EQ32("rows", 1, console_rows());
	verify("a one-row console");

	puts_both("abcdefgh");		/* exactly cols: wraps, so it scrolls */
	EQ32("the only row wraps onto itself: x", 0, console_x());
	EQ32("the only row wraps onto itself: y", 0, console_y());
	verify("a one-row console scrolls itself clean");

	puts_both("ij");
	verify("and keeps printing afterwards");

	fb_free();
}

/* ---- scenario: refused geometry, and the disarm that follows ------------- */

static void expect_refused(const char *what, int32_t w, int32_t h, int32_t top)
{
	unsigned long cli = g_cli, sti = g_sti;

	EQ32(what, FK_CON_E_GEOMETRY, init_both(w, h, top, 0x00FFFFFF, 0x00123456));
	EQ32(L(what, "not ready"), 0, console_ready());

	/* A console that refused its geometry must be inert -- and must not even
	 * take the lock, because the panic handler reaches these entry points
	 * before anything has been initialised. */
	console_putc('X');
	console_write("XXXX", 4);
	console_print_hex((int64_t)0x1234, 4);
	console_newline();
	console_clear();
	EQU(L(what, "takes no lock"), cli, g_cli);
	EQU(L(what, "releases no lock"), sti, g_sti);
	fb_verify(L(what, "inert"));
}

static void scenario_geometry(void)
{
	fixture(64, 48, 80);

	/* Arm it first and put something on screen: every refusal below must
	 * leave exactly this picture, which also proves a failed re-init
	 * DISARMS an already-armed console rather than leaving it drawing. */
	EQ32("init 8x3", FK_CON_OK, init_both(64, 48, 0, 0x00FFFFFF, 0x00001020));
	puts_both("armed");
	verify("armed before the refusals");

	expect_refused("width 0", 0, 48, 0);
	expect_refused("width negative", -8, 48, 0);
	expect_refused("height 0", 64, 0, 0);
	expect_refused("height negative", 64, -48, 0);
	expect_refused("top_y negative", 64, 48, -1);
	expect_refused("top_y == height", 64, 48, 48);
	expect_refused("top_y past height", 64, 48, 100);
	/* Positive geometry that still cannot hold one whole cell. */
	expect_refused("width below one glyph", 7, 48, 0);
	expect_refused("height below one glyph", 64, 15, 0);
	expect_refused("band below one glyph", 64, 48, 33);
	expect_refused("band one pixel short", 64, 48, 47);

	/* And it can be armed again afterwards. */
	EQ32("re-armed after the refusals", FK_CON_OK,
	     init_both(64, 48, 0, 0x00FFFFFF, 0x00001020));
	EQ32("ready again", 1, console_ready());
	verify("re-armed");

	fb_free();
}

/* ---- scenario: the interrupt discipline --------------------------------- */

/* unlock() RESTORES the caller's IF rather than issuing a blanket STI, because
 * the panic handler calls in here with interrupts already off and must not
 * have them turned back on underneath it.  Nothing on screen can show that;
 * only the mock can. */
static void scenario_interrupt_discipline(void)
{
	unsigned long cli, sti;

	fixture(64, 48, 80);
	EQ32("init", FK_CON_OK, init_both(64, 48, 0, 0x00FFFFFF, 0x00002000));

	cli = g_cli;
	sti = g_sti;
	g_rflags = 0x002;			/* RFLAGS.IF (bit 9) clear */
	putc_both('!');
	EQU("IF clear: interrupts are disabled once", cli + 1, g_cli);
	EQU("IF clear: and are NOT re-enabled", sti, g_sti);

	nl_both();
	clear_both();
	EQU("IF clear: still never re-enabled", sti, g_sti);

	g_rflags = 0x202;			/* IF set: the ordinary caller */
	putc_both('?');
	EQU("IF set: disabled once", cli + 4, g_cli);
	EQU("IF set: and restored", sti + 1, g_sti);
	verify("interrupt discipline");

	/* The getters are pure reads and must not touch the flag at all. */
	cli = g_cli;
	sti = g_sti;
	(void)console_cols();
	(void)console_rows();
	(void)console_x();
	(void)console_y();
	(void)console_ready();
	console_set_color(0x00FFFFFF, 0x00002000);
	EQU("the getters take no lock", cli, g_cli);
	EQU("the getters release none", sti, g_sti);

	fb_free();
}

int main(void)
{
	scenario_text();
	scenario_glyphs();
	scenario_scroll();
	scenario_single_row();
	scenario_geometry();
	scenario_interrupt_discipline();

	return fk_report("console");
}
