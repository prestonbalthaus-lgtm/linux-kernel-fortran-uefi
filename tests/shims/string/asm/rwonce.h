/* SPDX-License-Identifier: GPL-2.0 */
/* Private shim for the `string` differential test -- see mk/string.mk.
 * read_word_at_a_time() keeps its body from include/asm-generic/rwonce.h -- a
 * plain `*(unsigned long *)addr` load -- and drops the kasan_check_read() and
 * kcsan_check_read() instrumentation hooks, which have no meaning off-kernel.
 */
#ifndef _FK_STRING_SHIM_RWONCE_H
#define _FK_STRING_SHIM_RWONCE_H

static inline unsigned long read_word_at_a_time(const void *addr)
{
	return *(unsigned long *)addr;
}

#endif
