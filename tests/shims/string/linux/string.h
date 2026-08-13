/* SPDX-License-Identifier: GPL-2.0 */
/* Private shim for the `string` differential test -- see mk/string.mk.
 *
 * The real include/linux/string.h is ~600 lines of FORTIFY_SOURCE wrappers,
 * kmemdup helpers and the __HAVE_ARCH_* dispatch it inherits from
 * <asm/string.h>. lib/string.c needs none of that: it needs a declaration for
 * each function it defines, and EXPORT_SYMBOL.
 *
 * Only the functions this build actually compiles are declared. Everything
 * else is switched off by the -D__HAVE_ARCH_* list in mk/string.mk, so a
 * declaration for it would name a function that is not there.
 *
 * No algorithm is reimplemented here: this file is declarations only, so the
 * oracle object is compiled from the unmodified kernel source.
 */
#ifndef _FK_STRING_SHIM_STRING_H
#define _FK_STRING_SHIM_STRING_H
#include <linux/types.h>
#include <linux/stddef.h>
#include <linux/compiler.h>
#include <linux/export.h>

void *memset(void *s, int c, size_t count);
void *memcpy(void *dest, const void *src, size_t count);
void *memmove(void *dest, const void *src, size_t count);
int memcmp(const void *cs, const void *ct, size_t count);

/* Not guarded by any __HAVE_ARCH_*, so these compile whatever we define. */
ssize_t sized_strscpy(char *dest, const char *src, size_t count);
char *strnchrnul(const char *s, size_t count, int c);
void *memchr_inv(const void *start, int c, size_t bytes);

#endif
