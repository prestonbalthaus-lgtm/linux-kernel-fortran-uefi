/* Differential test: kernel's own lib/math/lcm.c :: lcm_not_zero()
 *                    vs  src/lib/math/fk_lcm_not_zero.f90
 *
 * The build template links exactly one oracle object, but lcm.c calls gcd(),
 * which lives in lib/math/gcd.c.  Rather than hand-write a stand-in (that would
 * make the "oracle" our own code and the comparison worthless), we pull in the
 * REAL kernel gcd.c verbatim right here, compiled against the same private
 * shims.  Nothing about the gcd or lcm algorithms is reimplemented anywhere in
 * this test -- the C side is 100% vendor source.
 */
#include "../../../vendor/linux-7.1.8/lib/math/gcd.c"

#include <linux/types.h>
#include <linux/lcm.h>
#include "fk_test.h"

/* oracle: real kernel source, lib/math/lcm.c (declared by <linux/lcm.h>) */
unsigned long fk_lcm_not_zero(unsigned long a, unsigned long b); /* Fortran */

#define ULONG_ALL_ONES	0xFFFFFFFFFFFFFFFFUL
#define HIGH_BIT	0x8000000000000000UL

static const unsigned long edge[] = {
	0UL, 1UL, 2UL, 3UL, 4UL, 5UL, 6UL, 7UL, 8UL, 9UL, 12UL, 16UL, 24UL,
	17UL, 255UL, 256UL, 1000003UL,			/* odd/even, prime-ish   */
	0x7FFFFFFFUL,					/* INT32_MAX             */
	0x80000000UL,					/* 32-bit high bit       */
	0xFFFFFFFFUL,					/* UINT32_MAX            */
	0x100000000UL,					/* 2**32                 */
	0x7FFFFFFFFFFFFFFFUL,				/* INT64_MAX (odd)       */
	HIGH_BIT,					/* 2**63, signed-negative*/
	HIGH_BIT | 1UL,					/* high bit + odd        */
	0xC000000000000000UL,				/* 3 * 2**62             */
	0xE000000000000000UL,				/* 7 * 2**61             */
	0x4000000000000000UL,				/* 2**62                 */
	ULONG_ALL_ONES,					/* UINT64_MAX            */
	ULONG_ALL_ONES - 1UL,
	0x5555555555555555UL,
	0xAAAAAAAAAAAAAAAAUL,
	0xDEADBEEFCAFEBABEUL,
	0x0123456789ABCDEFUL,
	0xFFFFFFFF00000000UL,
	0x00000000FFFFFFFFUL,
	0x8000000000000001UL,
	0x9E3779B97F4A7C15UL,				/* odd, high bit set     */
	0xBF58476D1CE4E5B9UL,
};
#define NEDGE (sizeof(edge) / sizeof(*edge))

static void check(unsigned long a, unsigned long b)
{
	FK_EQ("lcm_not_zero", lcm_not_zero(a, b), fk_lcm_not_zero(a, b), "%lu");
}

int main(void)
{
	size_t i, j;
	int k;

	/* (a) full cross product of the hand-picked edge values ------------ */
	for (i = 0; i < NEDGE; i++)
		for (j = 0; j < NEDGE; j++)
			check(edge[i], edge[j]);

	/* zero handling is the whole point of the `(b ? : a)` fallback */
	for (i = 0; i < NEDGE; i++) {
		check(0UL, edge[i]);
		check(edge[i], 0UL);
	}

	/* powers of two against powers of two: exercises __ffs / r & -r and
	 * drives the unsigned divide with a high-bit-set dividend.          */
	for (k = 0; k < 64; k++) {
		unsigned long p = 1UL << k;
		int m;

		for (m = 0; m < 64; m++) {
			unsigned long q = 1UL << m;

			check(p, q);
			check(p | 1UL, q);
			check(p, q | 1UL);
			check(~p, q);
			check(p, ~q);
			check(ULONG_ALL_ONES << k, 1UL << m);
		}
	}

	/* (b) randomized sweep --------------------------------------------- */
	fk_srand(0x1CB0BADCAFEULL);
	for (k = 0; k < 60000; k++) {
		unsigned long a = (unsigned long)fk_rand();
		unsigned long b = (unsigned long)fk_rand();

		check(a, b);
	}

	/* randomized with a planted common factor, so that a / gcd(a, b) is a
	 * real multi-bit unsigned division of a high-bit-set dividend rather
	 * than the trivial quotient-1 case.                                  */
	for (k = 0; k < 60000; k++) {
		unsigned long g = (unsigned long)fk_rand();
		unsigned long x = (unsigned long)fk_rand();
		unsigned long y = (unsigned long)fk_rand();

		check(g * x, g * y);
		check(g | HIGH_BIT, x);
		check(x, g | HIGH_BIT);
	}

	/* randomized small/sparse operands: short gcd loops, many zeros */
	for (k = 0; k < 40000; k++) {
		unsigned long a = (unsigned long)fk_rand() >> (fk_rand() & 63);
		unsigned long b = (unsigned long)fk_rand() >> (fk_rand() & 63);

		check(a, b);
		check(a, b << (fk_rand() & 63));
	}

	return fk_report("lcm_not_zero");
}
