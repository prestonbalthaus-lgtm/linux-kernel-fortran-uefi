/* Private shim for the `lcm` differential test.
 *
 * lib/math/gcd.c needs exactly two things out of the kernel.h include chain:
 * swap() and __ffs(). __ffs() returns the bit index of the least-significant
 * set bit and is undefined for 0 -- same contract as __builtin_ctzl.
 */
#ifndef _FK_LCM_SHIM_KERNEL_H
#define _FK_LCM_SHIM_KERNEL_H

#include <linux/types.h>
#include <linux/compiler.h>

#define swap(a, b) \
	do { typeof(a) __fk_tmp = (a); (a) = (b); (b) = __fk_tmp; } while (0)

static inline unsigned long __ffs(unsigned long word)
{
	return (unsigned long)__builtin_ctzl(word);
}

#endif
