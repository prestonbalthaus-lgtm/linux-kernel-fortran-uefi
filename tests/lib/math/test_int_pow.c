/* Differential test: kernel's own lib/math/int_pow.c  vs  fk_int_pow.f90 */
#include <linux/types.h>
#include "fk_test.h"

u64 int_pow(u64 base, unsigned int exp);      /* oracle: real kernel source */
u64 fk_int_pow(u64 base, unsigned int exp);   /* Fortran bind(c) */

int main(void)
{
	/* --- edge cases: the values most likely to expose a signedness bug --- */
	static const u64 bases[] = {
		0, 1, 2, 3, 10, 0x7FFFFFFFULL, 0x80000000ULL, 0xFFFFFFFFULL,
		0x7FFFFFFFFFFFFFFFULL,          /* INT64_MAX  */
		0x8000000000000000ULL,          /* high bit only -- signed-negative */
		0xFFFFFFFFFFFFFFFFULL,          /* all ones                        */
		0xDEADBEEFCAFEBABEULL,
	};
	static const unsigned int exps[] = {
		0, 1, 2, 3, 7, 31, 32, 63, 64, 65, 127, 255,
		0x7FFFFFFFU,
		0x80000000U,     /* high bit set: an arithmetic shift loops forever */
		0xFFFFFFFFU,
	};

	for (size_t i = 0; i < sizeof(bases)/sizeof(*bases); i++)
		for (size_t j = 0; j < sizeof(exps)/sizeof(*exps); j++)
			FK_EQ("int_pow", int_pow(bases[i], exps[j]),
			      fk_int_pow(bases[i], exps[j]), "%llu");

	/* --- randomized sweep --- */
	fk_srand(0x5EED1234ULL);
	for (int i = 0; i < 200000; i++) {
		u64 b = fk_rand();
		unsigned int e = (unsigned int)fk_rand();
		FK_EQ("int_pow", int_pow(b, e), fk_int_pow(b, e), "%llu");
	}
	return fk_report("int_pow");
}
