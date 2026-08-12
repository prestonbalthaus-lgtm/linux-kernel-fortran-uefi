/* Differential test: kernel's own lib/math/gcd.c  vs  fk_gcd.f90
 *
 * The oracle is compiled with static_branch_likely() forced true (see
 * tests/shims/gcd/linux/gcd.h), so it runs the binary_gcd() path -- the same
 * path fk_gcd.f90 translates.
 */
#include <linux/types.h>
#include "fk_test.h"

unsigned long gcd(unsigned long a, unsigned long b);    /* oracle: real kernel source */
unsigned long fk_gcd(unsigned long a, unsigned long b); /* Fortran bind(c) */

#define CHECK(a, b) FK_EQ("gcd", gcd((a), (b)), fk_gcd((a), (b)), "%lu")

int main(void)
{
	/* --- edge cases: the values most likely to expose a signedness bug --- */
	static const unsigned long vals[] = {
		0UL,				/* !a / !b early return          */
		1UL,				/* b == 1 fast path              */
		2UL, 3UL, 4UL, 5UL, 6UL, 7UL, 8UL, 12UL, 18UL,
		0x7FFFFFFFUL,			/* INT32_MAX                     */
		0x80000000UL,			/* 32-bit high bit               */
		0xFFFFFFFFUL,			/* 32-bit all ones               */
		0x100000000UL,
		3UL << 40,			/* deep __ffs count              */
		0x5555555555555555UL,
		0xAAAAAAAAAAAAAAAAUL,		/* even, high bit set            */
		0x7FFFFFFFFFFFFFFFUL,		/* INT64_MAX                     */
		0x8000000000000000UL,		/* high bit only: r & -r wraps   */
		0x8000000000000001UL,		/* ODD and signed-negative: the
						   value that breaks a signed
						   `a < b` compare               */
		0x8000000000000003UL,
		0xC000000000000001UL,
		0xFFFFFFFFFFFFFFFFUL,		/* all ones                      */
		0xFFFFFFFFFFFFFFFEUL,
		0xDEADBEEFCAFEBABEUL,
		0xDEADBEEFCAFEBABFUL,
	};
	const size_t n = sizeof(vals) / sizeof(*vals);

	/* full cross product, both orders (a<b and a>b hit different branches) */
	for (size_t i = 0; i < n; i++)
		for (size_t j = 0; j < n; j++)
			CHECK(vals[i], vals[j]);

	/* a == b exactly, incl. gcd(2**63, 2**63) which forces the `r & -r`
	   negation of 0x8000000000000000 to wrap the same way C's does */
	for (size_t i = 0; i < n; i++)
		CHECK(vals[i], vals[i]);

	/* every single-bit value against a few awkward partners */
	for (int s = 0; s < 64; s++) {
		unsigned long bit = 1UL << s;
		CHECK(bit, bit);
		CHECK(bit, 1UL);
		CHECK(1UL, bit);
		CHECK(bit, 0xFFFFFFFFFFFFFFFFUL);
		CHECK(0xFFFFFFFFFFFFFFFFUL, bit);
		CHECK(bit, 0x8000000000000001UL);
		CHECK(0x8000000000000001UL, bit);
		CHECK(bit, 3UL << (s / 2));
		CHECK(bit, ~bit);
		CHECK(~bit, bit);
	}

	/* --- randomized sweep: uniform 64-bit --- */
	fk_srand(0x9CD1234567890ABCULL);
	for (int i = 0; i < 150000; i++) {
		unsigned long a = (unsigned long)fk_rand();
		unsigned long b = (unsigned long)fk_rand();
		CHECK(a, b);
	}

	/* --- randomized sweep: small values, so the loop runs many
	       iterations and a == b / non-trivial gcds actually happen --- */
	for (int i = 0; i < 100000; i++) {
		unsigned long a = (unsigned long)(fk_rand() & 0xFFFF);
		unsigned long b = (unsigned long)(fk_rand() & 0xFFFF);
		CHECK(a, b);
	}

	/* --- randomized sweep: shifted values, exercising deep __ffs counts,
	       the `a << __ffs(r)` return and high-bit-set operands --- */
	for (int i = 0; i < 100000; i++) {
		unsigned long a = (unsigned long)fk_rand() << (fk_rand() % 64);
		unsigned long b = (unsigned long)fk_rand() << (fk_rand() % 64);
		CHECK(a, b);
	}

	/* --- randomized sweep: shared random factor, so the answer is large
	       and the algorithm terminates through the a == b branch --- */
	for (int i = 0; i < 100000; i++) {
		unsigned long g = (unsigned long)fk_rand() >> (fk_rand() % 40);
		unsigned long a = g * (unsigned long)(fk_rand() & 0xFF);
		unsigned long b = g * (unsigned long)(fk_rand() & 0xFF);
		CHECK(a, b);
	}

	return fk_report("gcd");
}
