/* Minimal <linux/font.h> for building lib/fonts/font_8x16.c as an oracle.
 *
 * The vendored include/linux/font.h cannot be used directly: its inline
 * helpers need DIV_ROUND_UP from the real <linux/math.h>, and the shared
 * tests/shims/linux/math.h deliberately does not provide it. Only the two
 * declarations the font file actually instantiates are reproduced here, with
 * layout identical to the kernel's (vendor include/linux/font.h:122).
 */
#ifndef _FK_SHIM_GOP_FONT_H
#define _FK_SHIM_GOP_FONT_H
#include <linux/types.h>

struct console_font;

typedef const unsigned char font_data_t;

static inline const unsigned char *font_data_buf(font_data_t *fd)
{
	return (const unsigned char *)fd;
}

struct font_desc {
	int idx;
	const char *name;
	unsigned int width, height;
	unsigned int charcount;
	font_data_t *data;
	int pref;
};
#endif
