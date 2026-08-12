/* Differential test: kernel's own lib/bcd.c  vs  src/lib/fk_bcd.f90
 *
 *   unsigned      _bcd2bin(unsigned char val)
 *   unsigned char _bin2bcd(unsigned val)
 *
 * Both functions have a finite, enumerable input domain (2**8 and 2**32), so
 * after the hand-picked edges and the randomized sweep this driver simply
 * proves equivalence EXHAUSTIVELY -- every input either function can ever be
 * given is compared.  The full sweep costs ~5 s.
 *
 * The interesting region for _bin2bcd is around val == 41698712, the first
 * input where the internal `val * 103` wraps modulo 2**32
 * (41698711*103 == 4294967233 < 2**32, 41698712*103 == 4294967336 >= 2**32).
 * It is called out explicitly below so a failure there is self-describing.
 */
#include <linux/types.h>
#include "fk_test.h"

unsigned      _bcd2bin(unsigned char val);    /* oracle: real kernel source */
unsigned char _bin2bcd(unsigned val);         /* oracle: real kernel source */

unsigned      fk__bcd2bin(unsigned char val); /* Fortran bind(c) */
unsigned char fk__bin2bcd(unsigned val);      /* Fortran bind(c) */

static void chk_bcd2bin(unsigned char v)
{
	FK_EQ("_bcd2bin", (unsigned)_bcd2bin(v), (unsigned)fk__bcd2bin(v), "%u");
}

static void chk_bin2bcd(unsigned v)
{
	FK_EQ("_bin2bcd", (unsigned)_bin2bcd(v), (unsigned)fk__bin2bcd(v), "%u");
}

int main(void)
{
	unsigned i, v;

	/* --- (a) hand-picked edges: _bcd2bin ---------------------------- */
	static const unsigned char b_edges[] = {
		0x00, 0x01, 0x09, 0x0A, 0x0F, 0x10, 0x7F,
		0x80,        /* high bit set: sign-extends if the mask is missing */
		0x81, 0x99,  /* largest valid packed BCD                          */
		0xAA, 0xF0, 0xFE, 0xFF,            /* all ones                    */
	};
	for (i = 0; i < sizeof(b_edges) / sizeof(*b_edges); i++)
		chk_bcd2bin(b_edges[i]);

	/* --- (a) hand-picked edges: _bin2bcd ---------------------------- */
	static const unsigned v_edges[] = {
		0, 1, 2, 9, 10, 11, 15, 16, 63, 99, 100, 127, 128,
		254, 255, 256, 257, 999, 1000, 65535, 65536,
		/* the 32-bit wrap frontier of (val * 103) */
		41698709U, 41698710U, 41698711U,   /* last products that fit   */
		41698712U, 41698713U, 41698714U,   /* first products that wrap */
		41698711U * 2U, 41698712U * 2U,
		/* bit-31 of (val * 103) first set here: a sign-propagating
		 * shift would diverge from a zero-fill shift from here up  */
		20849356U, 20849357U, 20849358U,
		/* signed/unsigned boundaries */
		0x0000FFFFU, 0x00FFFFFFU, 0x40000000U,
		0x7FFFFFFEU, 0x7FFFFFFFU,          /* INT32_MAX                */
		0x80000000U,                       /* high bit only            */
		0x80000001U, 0xC0000000U,
		0xFFFFFFFEU, 0xFFFFFFFFU,          /* all ones                 */
		0xDEADBEEFU, 0xCAFEBABEU, 0x55555555U, 0xAAAAAAAAU,
	};
	for (i = 0; i < sizeof(v_edges) / sizeof(*v_edges); i++)
		chk_bin2bcd(v_edges[i]);

	/* --- (b) randomized sweep over the full u32 / u8 domains -------- */
	fk_srand(0xB0DDECAFULL);
	for (i = 0; i < 150000; i++) {
		u64 r = fk_rand();
		chk_bcd2bin((unsigned char)r);
		chk_bin2bcd((unsigned)(r >> 8));
	}

	/* --- (c) exhaustive: every input in both domains ---------------- */
	for (i = 0; i < 256; i++)
		chk_bcd2bin((unsigned char)i);

	v = 0;
	do {
		chk_bin2bcd(v);
	} while (++v != 0);	/* wraps to 0 after 0xFFFFFFFF */

	return fk_report("bcd");
}
