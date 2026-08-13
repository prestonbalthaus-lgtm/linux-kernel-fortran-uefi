/* SPDX-License-Identifier: GPL-2.0 */
/* Private shim for the `string` differential test -- see mk/string.mk.
 *
 * memcmp() reaches for get_unaligned() only under
 * CONFIG_HAVE_EFFICIENT_UNALIGNED_ACCESS, which arch/x86/Kconfig selects, so
 * this path IS the one an x86-64 build compiles.
 *
 * The kernel's own __get_unaligned_t() memcpys into a local whose type comes
 * from __unqual_scalar_typeof(), purely to strip the const off `const unsigned
 * long`. The packed struct below is the older kernel spelling of the same
 * unaligned load (include/linux/unaligned/packed_struct.h) and needs no such
 * machinery, because reading a member yields an rvalue.
 */
#ifndef _FK_STRING_SHIM_UNALIGNED_H
#define _FK_STRING_SHIM_UNALIGNED_H
#include <linux/compiler.h>

#define __get_unaligned_t(type, ptr) ({					\
	const struct { type x; } __packed *__una_ptr = (const void *)(ptr); \
	__una_ptr->x;							\
})
#define get_unaligned(ptr)	__get_unaligned_t(__typeof__(*(ptr)), (ptr))

#endif
