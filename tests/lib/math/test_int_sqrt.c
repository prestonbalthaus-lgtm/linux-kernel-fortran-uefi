/* Differential test: kernel's own lib/math/int_sqrt.c  vs  fk_int_sqrt.f90 */
#include <linux/types.h>
#include "fk_test.h"

unsigned long int_sqrt(unsigned long x);      /* oracle: real kernel source */
unsigned long fk_int_sqrt(unsigned long x);   /* Fortran bind(c) */

int main(void)
{
	/* --- hand-picked edge cases ---------------------------------------
	 * 0 and 1 are the special-cased early return; everything with the
	 * high bit set is where a signed compare (<= / >=) diverges.
	 */
	static const unsigned long edges[] = {
		0, 1, 2, 3, 4, 5, 8, 9, 10, 15, 16, 17, 24, 25, 26,
		0xFFUL, 0x100UL, 0x101UL,
		0xFFFFUL, 0x10000UL, 0x10001UL,
		0x7FFFFFFFUL,                   /* INT32_MAX                   */
		0x80000000UL,                   /* INT32_MAX + 1               */
		0x80000001UL,
		0xFFFFFFFFUL,                   /* UINT32_MAX                  */
		0x100000000UL,
		0x7FFFFFFFFFFFFFFFUL,           /* INT64_MAX                   */
		0x8000000000000000UL,           /* high bit only: signed-neg   */
		0x8000000000000001UL,
		0xFFFFFFFFFFFFFFFFUL,           /* all ones                    */
		0xFFFFFFFFFFFFFFFEUL,
		0xDEADBEEFCAFEBABEUL,
		0x4000000000000000UL,           /* 2**62, exact square         */
		0x3FFFFFFFFFFFFFFFUL,
		0x4000000000000001UL,
		0xFFFFFFFE00000001UL,           /* (2**32 - 1)**2              */
		0xFFFFFFFE00000000UL,           /* (2**32 - 1)**2 - 1          */
		0xFFFFFFFE00000002UL,           /* (2**32 - 1)**2 + 1          */
	};

	for (size_t i = 0; i < sizeof(edges) / sizeof(*edges); i++)
		FK_EQ("int_sqrt", int_sqrt(edges[i]), fk_int_sqrt(edges[i]), "%lu");

	/* --- every power of two, and its neighbours: each one moves __fls --- */
	for (int s = 0; s < 64; s++) {
		unsigned long p = 1UL << s;
		FK_EQ("int_sqrt", int_sqrt(p - 1), fk_int_sqrt(p - 1), "%lu");
		FK_EQ("int_sqrt", int_sqrt(p), fk_int_sqrt(p), "%lu");
		FK_EQ("int_sqrt", int_sqrt(p + 1), fk_int_sqrt(p + 1), "%lu");
	}

	/* --- perfect squares and their straddles: floor() off-by-ones live
	 * exactly at k*k-1 / k*k / k*k+1. Small k densely, then every root
	 * magnitude up to the 2**32 ceiling.
	 */
	for (unsigned long k = 0; k < 4096; k++) {
		unsigned long sq = k * k;
		FK_EQ("int_sqrt", int_sqrt(sq), fk_int_sqrt(sq), "%lu");
		if (sq) {
			FK_EQ("int_sqrt", int_sqrt(sq - 1), fk_int_sqrt(sq - 1), "%lu");
			FK_EQ("int_sqrt", int_sqrt(sq + 1), fk_int_sqrt(sq + 1), "%lu");
		}
	}
	for (int s = 0; s < 32; s++) {
		for (int d = -2; d <= 2; d++) {
			unsigned long k = (1UL << s) + (unsigned long)(long)d;
			unsigned long sq = k * k;
			if (k > 0xFFFFFFFFUL)
				continue;
			FK_EQ("int_sqrt", int_sqrt(sq), fk_int_sqrt(sq), "%lu");
			if (sq) {
				FK_EQ("int_sqrt", int_sqrt(sq - 1), fk_int_sqrt(sq - 1), "%lu");
				FK_EQ("int_sqrt", int_sqrt(sq + 1), fk_int_sqrt(sq + 1), "%lu");
			}
		}
	}
	/* squares of large roots, right under the 64-bit ceiling */
	for (unsigned long k = 0xFFFFFFFFUL; k > 0xFFFFFFFFUL - 4096; k--) {
		unsigned long sq = k * k;
		FK_EQ("int_sqrt", int_sqrt(sq), fk_int_sqrt(sq), "%lu");
		FK_EQ("int_sqrt", int_sqrt(sq - 1), fk_int_sqrt(sq - 1), "%lu");
		FK_EQ("int_sqrt", int_sqrt(sq + 1), fk_int_sqrt(sq + 1), "%lu");
	}

	/* --- randomized sweep: full-width values ... --- */
	fk_srand(0x5EED1234ULL);
	for (int i = 0; i < 100000; i++) {
		unsigned long x = (unsigned long)fk_rand();
		FK_EQ("int_sqrt", int_sqrt(x), fk_int_sqrt(x), "%lu");
	}
	/* ... and width-varied values, so small/mid magnitudes get real
	 * coverage instead of only 63-64 bit inputs.
	 */
	for (int i = 0; i < 100000; i++) {
		unsigned long r = (unsigned long)fk_rand();
		unsigned int sh = (unsigned int)(fk_rand() & 63);
		unsigned long x = r >> sh;
		FK_EQ("int_sqrt", int_sqrt(x), fk_int_sqrt(x), "%lu");
	}
	/* ... and randoms nudged onto perfect-square boundaries. */
	for (int i = 0; i < 100000; i++) {
		unsigned long k = (unsigned long)fk_rand() >> 32;   /* 0..2**32-1 */
		unsigned long sq = k * k;
		unsigned long x = sq + (unsigned long)(fk_rand() % 3) - 1;
		FK_EQ("int_sqrt", int_sqrt(x), fk_int_sqrt(x), "%lu");
	}

	return fk_report("int_sqrt");
}
