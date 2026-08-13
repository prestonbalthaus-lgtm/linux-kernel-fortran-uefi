/* SPDX-License-Identifier: GPL-2.0 */
/* Private shim for the `string` differential test -- see mk/string.mk.
 * arch/x86/include/asm/bitops.h defines __ffs() as tzcnt on a variable and
 * (unsigned long)__builtin_ctzl() on a constant -- the same operation.
 * Undefined for 0, exactly like the kernel's.
 */
#ifndef _FK_STRING_SHIM_BITOPS_H
#define _FK_STRING_SHIM_BITOPS_H

#define __ffs(word)	((unsigned long)__builtin_ctzl(word))

#endif
