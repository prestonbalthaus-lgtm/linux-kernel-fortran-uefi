#ifndef _FK_SHIM_LCMNZ_KERNEL_H
#define _FK_SHIM_LCMNZ_KERNEL_H
#include <linux/types.h>
#include <linux/compiler.h>

/* include/linux/minmax.h, verbatim -- kernel.h pulls minmax.h in for real. */
#define swap(a, b) \
	do { typeof(a) __tmp = (a); (a) = (b); (b) = __tmp; } while (0)

/* arch __ffs(): index of the least-significant set bit, undefined for 0
 * (arch/x86/include/asm/bitops.h uses `rep; bsf`, the generic version is a
 * de Bruijn-free binary search).  __builtin_ctzl is exactly that primitive and
 * is unaffected by -fno-builtin, which only concerns library-backed builtins. */
#define __ffs(word)	((unsigned int)__builtin_ctzl((unsigned long)(word)))

#endif /* _FK_SHIM_LCMNZ_KERNEL_H */
