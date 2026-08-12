/* Private shim for the int_sqrt differential test -- userspace stand-in for
 * the kernel's <linux/bitops.h>. Provides ONLY what lib/math/int_sqrt.c uses;
 * the square-root algorithm itself is never touched here.
 */
#ifndef _FK_SHIM_INT_SQRT_BITOPS_H
#define _FK_SHIM_INT_SQRT_BITOPS_H
#include <linux/types.h>

/* Kernel gets this via <asm/bitsperlong.h>, which bitops.h pulls in. This
 * MUST be defined: in `#if BITS_PER_LONG < 64` an undefined identifier
 * evaluates to 0, which would switch on the int_sqrt64 branch that the
 * 64-bit build never compiles.
 */
#define BITS_PER_LONG 64

/* __fls(word): 0-based index of the most significant set bit. Undefined for
 * word == 0, exactly like the arch primitive it stands in for.
 */
#define __fls(x) ((unsigned long)(63 - __builtin_clzl((unsigned long)(x))))

#endif
