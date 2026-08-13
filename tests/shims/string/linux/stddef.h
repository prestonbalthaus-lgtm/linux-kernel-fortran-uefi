/* SPDX-License-Identifier: GPL-2.0 */
/* Private shim for the `string` differential test -- see mk/string.mk.
 *
 * ssize_t belongs in <linux/types.h>, but that name resolves to the SHARED
 * tests/shims/linux/types.h: -Itests/shims precedes -Itests/shims/string on
 * every command line, so a private copy would be dead. sized_strscpy() is the
 * only user and it is not under test.
 */
#ifndef _FK_STRING_SHIM_STDDEF_H
#define _FK_STRING_SHIM_STDDEF_H
#include <stddef.h>

#ifndef __ssize_t_defined
typedef long ssize_t;
#define __ssize_t_defined
#endif

#endif
