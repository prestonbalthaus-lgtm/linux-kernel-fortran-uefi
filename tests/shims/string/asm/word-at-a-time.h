/* SPDX-License-Identifier: GPL-2.0 */
/* Private shim for the `string` differential test -- see mk/string.mk.
 *
 * Reproduced VERBATIM from arch/x86/include/asm/word-at-a-time.h, so the
 * oracle keeps the exact helpers an x86-64 build would compile. Only
 * load_unaligned_zeropad() is left out: it is inline asm carrying an
 * _ASM_EXTABLE_TYPE fixup that cannot exist in a user-space object, and its
 * one caller -- sized_strscpy() under CONFIG_DCACHE_WORD_ACCESS -- is neither
 * under test nor configured on here.
 */
#ifndef _FK_STRING_SHIM_WORD_AT_A_TIME_H
#define _FK_STRING_SHIM_WORD_AT_A_TIME_H
#include <linux/bitops.h>
#include <linux/wordpart.h>

struct word_at_a_time {
	const unsigned long one_bits, high_bits;
};

#define WORD_AT_A_TIME_CONSTANTS { REPEAT_BYTE(0x01), REPEAT_BYTE(0x80) }

/* Return nonzero if it has a zero */
static inline unsigned long has_zero(unsigned long a, unsigned long *bits, const struct word_at_a_time *c)
{
	unsigned long mask = ((a - c->one_bits) & ~a) & c->high_bits;
	*bits = mask;
	return mask;
}

static inline unsigned long prep_zero_mask(unsigned long a, unsigned long bits, const struct word_at_a_time *c)
{
	return bits;
}

/* Keep the initial has_zero() value for both bitmask and size calc */
#define create_zero_mask(bits) (bits)

static inline unsigned long zero_bytemask(unsigned long bits)
{
	bits = (bits - 1) & ~bits;
	return bits >> 7;
}

#define find_zero(bits) (__ffs(bits) >> 3)

#endif
