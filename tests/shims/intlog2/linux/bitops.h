/* Private shim for the intlog2 differential test -- tests/shims/intlog2/.
 * Provides only what lib/math/int_log.c needs from <linux/bitops.h>.
 * fls() keeps the exact generic_fls() contract from
 * include/asm-generic/bitops/fls.h: fls(0)=0, fls(1)=1, fls(0x80000000)=32.
 * No part of the intlog2 algorithm lives here. */
#ifndef _FK_SHIM_INTLOG2_BITOPS_H
#define _FK_SHIM_INTLOG2_BITOPS_H
#include <linux/types.h>
static inline int fls(unsigned int x)
{
	return x ? 32 - __builtin_clz(x) : 0;
}
#endif
