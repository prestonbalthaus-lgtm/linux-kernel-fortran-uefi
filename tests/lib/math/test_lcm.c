/* Differential test: kernel's own lib/math/lcm.c  vs  fk_lcm.f90
 *
 * LINK NOTE: the build template compiles exactly one oracle .c per test, but
 * lcm.c calls gcd(). Rather than reimplement gcd (which would make the oracle
 * dishonest), the real kernel lib/math/gcd.c is pulled in here verbatim; the
 * macros it needs come from the private shims in tests/shims/lcm/linux/.
 */
#include <linux/types.h>
#include "fk_test.h"

#include "../../../vendor/linux-7.1.8/lib/math/gcd.c"

unsigned long lcm(unsigned long a, unsigned long b);      /* oracle: real kernel source */
unsigned long fk_lcm(unsigned long a, unsigned long b);   /* Fortran bind(c) */

/* Values chosen to break a signed divide, a signed compare or an arithmetic
 * shift. Note that a plain signed `/` survives the easy cases: when gcd(a,b)
 * is a power of two the two quotients differ by exactly 2^64/gcd and the
 * final `* b` wraps that difference away. It only shows up when gcd(a,b) has
 * an odd factor > 1 and `a` has bit 63 set -- e.g. a=0xC000000000000000, b=3,
 * where unsigned gives 0xC000000000000000 and signed gives 0xC000000000000001.
 * Both flavours are present below.
 */
static const unsigned long edge[] = {
	0UL, 1UL, 2UL, 3UL, 4UL, 5UL, 6UL, 7UL, 8UL, 12UL, 15UL, 16UL, 100UL,
	0xFFUL, 0xFFFFUL,
	3037000493UL,                    /* prime near sqrt(2^63)              */
	0x7FFFFFFFUL,                    /* INT32_MAX                          */
	0x80000000UL,                    /* 2^31                               */
	0xFFFFFFFFUL,                    /* UINT32_MAX                         */
	0x100000000UL,                   /* 2^32                               */
	0x5555555555555555UL,
	0x7FFFFFFFFFFFFFFEUL,
	0x7FFFFFFFFFFFFFFFUL,            /* INT64_MAX                          */
	0x8000000000000000UL,            /* high bit only -- signed-negative   */
	0x8000000000000001UL,
	0xAAAAAAAAAAAAAAAAUL,
	0xC000000000000000UL,            /* 3 * 2^62: odd gcd factor + bit 63  */
	0xDEADBEEFCAFEBABEUL,
	0xFFFFFFFFFFFFFFFEUL,
	0xFFFFFFFFFFFFFFFFUL,            /* all ones                           */
};
#define N_EDGE (sizeof(edge) / sizeof(*edge))

static void sweep(void)
{
	size_t i, j;
	int k;

	/* (a) every ordered pair of the hand-picked edge values */
	for (i = 0; i < N_EDGE; i++)
		for (j = 0; j < N_EDGE; j++)
			FK_EQ("lcm", lcm(edge[i], edge[j]),
			      fk_lcm(edge[i], edge[j]), "%lu");

	/* (b1) fully random 64-bit pairs -- half of these have bit 63 set */
	fk_srand(0x1CD5EEDA5A5A5A5ULL);
	for (k = 0; k < 100000; k++) {
		unsigned long a = fk_rand();
		unsigned long b = fk_rand();
		FK_EQ("lcm", lcm(a, b), fk_lcm(a, b), "%lu");
	}

	/* (b2) pairs built to share a large gcd, so `a / gcd(a,b)` is a real
	 *      division by something bigger than 1 (and often odd).
	 */
	fk_srand(0xBEEF0123ULL);
	for (k = 0; k < 50000; k++) {
		unsigned long f  = fk_rand() >> 32;
		unsigned long a  = f * (fk_rand() >> 32);
		unsigned long b  = f * (fk_rand() >> 32);
		FK_EQ("lcm", lcm(a, b), fk_lcm(a, b), "%lu");
	}

	/* (b3) random values truncated to a random bit width 0..64, which packs
	 *      the small-operand and power-of-two-heavy cases.
	 */
	fk_srand(0x0DDBA11ULL);
	for (k = 0; k < 50000; k++) {
		unsigned int wa = fk_rand() % 65, wb = fk_rand() % 65;
		unsigned long a = wa ? (fk_rand() >> (64 - wa)) : 0UL;
		unsigned long b = wb ? (fk_rand() >> (64 - wb)) : 0UL;
		FK_EQ("lcm", lcm(a, b), fk_lcm(a, b), "%lu");
	}
}

int main(void)
{
	/* lib/math/gcd.c has two kernel-reachable implementations selected by
	 * efficient_ffs_key. Run the whole sweep against each so the Fortran is
	 * proved against both, not just the default.
	 */
	efficient_ffs_key = 1;   /* binary_gcd()  -- the DEFINE_STATIC_KEY_TRUE default */
	sweep();
	efficient_ffs_key = 0;   /* the even/odd normalisation loop */
	sweep();

	return fk_report("lcm");
}
