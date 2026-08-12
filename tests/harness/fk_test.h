/* Tiny differential-test harness shared by every Phase 1 test driver. */
#ifndef _FK_TEST_H
#define _FK_TEST_H
#include <stdio.h>
#include <stdint.h>

static unsigned long fk_checks, fk_fails;

/* splitmix64: deterministic, seedable, good bit-mixing. Reproducible runs. */
static uint64_t fk_rng_state;
static inline void     fk_srand(uint64_t s) { fk_rng_state = s; }
static inline uint64_t fk_rand(void)
{
	uint64_t z = (fk_rng_state += 0x9E3779B97F4A7C15ULL);
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
	return z ^ (z >> 31);
}

#define FK_EQ(what, c_val, f_val, fmt)                                       \
	do {                                                                 \
		fk_checks++;                                                 \
		if ((c_val) != (f_val)) {                                    \
			if (fk_fails < 10)                                   \
				printf("  MISMATCH %s: C=" fmt " F=" fmt "\n", \
				       (what), (c_val), (f_val));            \
			fk_fails++;                                          \
		}                                                            \
	} while (0)

static inline int fk_report(const char *name)
{
	printf("%-24s %8lu checks, %lu mismatches  [%s]\n",
	       name, fk_checks, fk_fails, fk_fails ? "FAIL" : "PASS");
	return fk_fails ? 1 : 0;
}
#endif
