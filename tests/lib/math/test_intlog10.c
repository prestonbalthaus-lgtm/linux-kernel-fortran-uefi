/* Differential test: kernel's own lib/math/int_log.c :: intlog10()
 *                vs  src/lib/math/fk_intlog10.f90 :: fk_intlog10()
 *
 * intlog10() takes a u32 and returns an unsigned int, so every comparison is
 * made on the full unsigned 32-bit value: any sign-propagating shift or signed
 * modulo on the Fortran side shows up here as a mismatch.
 */
#include <linux/types.h>
#include "fk_test.h"

unsigned int intlog10(u32 value);    /* oracle: real kernel source  */
unsigned int fk_intlog10(u32 value); /* Fortran bind(c)             */

int main(void)
{
	/* --- hand-picked edge cases ------------------------------------- */
	static const u32 edge[] = {
		0,			/* special-cased: WARN_ON + return 0   */
		1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
		99, 100, 999, 1000, 1001,
		0x0000FFFFU, 0x00010000U,
		0x00231F56U,		/* the worked example in the comment   */
		0x7FFFFFFEU,
		0x7FFFFFFFU,		/* INT32_MAX                           */
		0x80000000U,		/* high bit only -- signed-negative    */
		0x80000001U,
		0xC0000000U,
		0xDEADBEEFU,
		0xFFFFFFFEU,
		0xFFFFFFFFU,		/* all ones                            */
		/* 10^k: the values the kernel doc says land on k << 24        */
		10U, 100U, 1000U, 10000U, 100000U,
		1000000U, 10000000U, 100000000U, 1000000000U,
	};

	for (size_t i = 0; i < sizeof(edge) / sizeof(*edge); i++)
		FK_EQ("intlog10", intlog10(edge[i]), fk_intlog10(edge[i]), "%u");

	/* every power of two and its immediate neighbours: exercises each
	 * possible msb, including the 31 - msb == 0 and == 31 shift ends   */
	for (int b = 0; b < 32; b++) {
		u32 p = 1U << b;
		FK_EQ("intlog10", intlog10(p), fk_intlog10(p), "%u");
		FK_EQ("intlog10", intlog10(p - 1), fk_intlog10(p - 1), "%u");
		FK_EQ("intlog10", intlog10(p + 1), fk_intlog10(p + 1), "%u");
	}

	/* small values exhaustively */
	for (u32 v = 0; v <= 4096; v++)
		FK_EQ("intlog10", intlog10(v), fk_intlog10(v), "%u");

	/* --- every logtable entry x every msb x the interpolation ends ---
	 * Reconstruct a value whose normalised significand selects table
	 * entry `le`, so entry 255 -- where logtable_next wraps to 0 and the
	 * (diff & 0xffff) correction fires -- is covered at every msb, as is
	 * the maximum interpolation error 0x7fffff.
	 */
	static const u32 tail[] = { 0x000000U, 0x000001U, 0x400000U, 0x7FFFFFU };
	for (u32 le = 0; le < 256; le++) {
		for (size_t t = 0; t < sizeof(tail) / sizeof(*tail); t++) {
			u32 sig = ((0x100U | le) << 23) | tail[t];
			for (int msb = 0; msb < 32; msb++) {
				u32 v = sig >> (31 - msb);
				FK_EQ("intlog10", intlog10(v),
				      fk_intlog10(v), "%u");
			}
		}
	}

	/* --- randomized sweep ------------------------------------------- */
	fk_srand(0xA10610FFULL);
	for (int i = 0; i < 200000; i++) {
		u32 v = (u32)fk_rand();
		FK_EQ("intlog10", intlog10(v), fk_intlog10(v), "%u");
	}

	/* second sweep biased toward small magnitudes, so low msb values and
	 * the 31 - msb == 31 shift are hit far more often than by chance    */
	fk_srand(0xBADC0FFEULL);
	for (int i = 0; i < 100000; i++) {
		u64 r = fk_rand();
		u32 v = (u32)(r >> (r & 31));
		FK_EQ("intlog10", intlog10(v), fk_intlog10(v), "%u");
	}

	return fk_report("intlog10");
}
