/* Private shim for the gcd differential test -- only what lib/math/gcd.c
 * actually uses out of <linux/kernel.h>'s transitive includes.
 * Nothing here reimplements any part of the algorithm.
 */
#ifndef _FK_SHIM_GCD_KERNEL_H
#define _FK_SHIM_GCD_KERNEL_H
#include <linux/types.h>

/* verbatim from include/linux/minmax.h */
#define swap(a, b) \
	do { typeof(a) __tmp = (a); (a) = (b); (b) = __tmp; } while (0)

/* arch/x86/include/asm/bitops.h defines __ffs() as tzcnt on a variable and
 * (unsigned long)__builtin_ctzl() on a constant -- the same operation.
 * Undefined for 0, exactly like the kernel's.
 */
#define __ffs(word)	((unsigned long)__builtin_ctzl(word))

#endif
