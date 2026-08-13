/* SPDX-License-Identifier: GPL-2.0 */
/* Private shim for the `string` differential test -- see mk/string.mk.
 * Deliberately empty: the only users of <linux/ctype.h> in lib/string.c are
 * strncasecmp() and strcasecmp(), and both are excluded by __HAVE_ARCH_*.
 * The header still has to resolve, because the #include is unconditional.
 */
#ifndef _FK_STRING_SHIM_CTYPE_H
#define _FK_STRING_SHIM_CTYPE_H
#endif
