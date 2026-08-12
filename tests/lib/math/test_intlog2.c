/* Differential test: kernel's own lib/math/int_log.c  vs  fk_intlog2.f90 */
#include <linux/types.h>
#include "fk_test.h"

unsigned int intlog2(u32 value);      /* oracle: real kernel source */
unsigned int fk_intlog2(u32 value);   /* Fortran bind(c) */

int main(void)
{
	/* --- hand-picked edge cases ------------------------------------ */
	static const u32 edge[] = {
		0,			/* special-cased: WARN_ON + return 0     */
		1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 16, 17, 100, 1000,
		0x00231f56U,		/* the worked example in the C comment   */
		0x7FFFFFFFU,		/* INT32_MAX                             */
		0x80000000U,		/* high bit only -- signed-negative      */
		0x80000001U,
		0xFFFFFFFEU,
		0xFFFFFFFFU,		/* all ones                              */
		0xFF800000U,		/* significand top-9 = 1_11111111 -> 255 */
		0xFF7FFFFFU,		/* one below that boundary               */
		0x80800000U,		/* logentry 1 at msb 31                  */
		0xDEADBEEFU, 0xCAFEBABEU, 0x5EED1234U,
	};
	for (size_t i = 0; i < sizeof(edge)/sizeof(*edge); i++)
		FK_EQ("intlog2", intlog2(edge[i]), fk_intlog2(edge[i]), "%u");

	/* powers of two and their neighbours: every possible msb, and the
	 * fls()/leadz() boundary at each bit position.                    */
	for (int k = 0; k < 32; k++) {
		u32 p = 1U << k;
		FK_EQ("intlog2", intlog2(p),     fk_intlog2(p),     "%u");
		FK_EQ("intlog2", intlog2(p - 1), fk_intlog2(p - 1), "%u");
		FK_EQ("intlog2", intlog2(p + 1), fk_intlog2(p + 1), "%u");
		FK_EQ("intlog2", intlog2(~p),    fk_intlog2(~p),    "%u");
	}

	/* structured sweep: hit EVERY one of the 256 log-table entries at
	 * EVERY msb, with the interpolation remainder at its extremes.
	 * significand is reconstructed with bit 31 set (as the algorithm
	 * guarantees) then shifted back down to recover the input value.
	 * This deliberately includes logentry == 255, where the C computes
	 * logtable[0] - logtable[255] as a NEGATIVE int before masking.   */
	static const u32 lowbits[] = { 0x000000U, 0x000001U, 0x400000U,
				       0x7FFFFEU, 0x7FFFFFU };
	for (int msb = 0; msb < 32; msb++)
		for (unsigned e = 0; e < 256; e++)
			for (size_t l = 0; l < sizeof(lowbits)/sizeof(*lowbits); l++) {
				u32 sig = ((0x100U | e) << 23) | lowbits[l];
				u32 v   = sig >> (31 - msb);
				FK_EQ("intlog2", intlog2(v), fk_intlog2(v), "%u");
			}

	/* --- randomized sweep ------------------------------------------ */
	fk_srand(0x109109109ULL);
	for (int i = 0; i < 500000; i++) {
		u32 v = (u32)fk_rand();
		FK_EQ("intlog2", intlog2(v), fk_intlog2(v), "%u");
	}
	/* random values biased to small magnitudes (low msb, where the
	 * left shift 31-msb is largest) */
	for (int i = 0; i < 200000; i++) {
		u64 r = fk_rand();
		u32 v = (u32)(r >> (r & 31));
		FK_EQ("intlog2", intlog2(v), fk_intlog2(v), "%u");
	}
	return fk_report("intlog2");
}
