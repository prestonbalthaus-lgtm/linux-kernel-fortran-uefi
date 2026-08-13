/* SPDX-License-Identifier: GPL-2.0 */
/* Private shim for the `string` differential test -- see mk/string.mk.
 * sized_strscpy() bounds its count against INT_MAX; the host header's value
 * is the same 2**31-1 the kernel's own <linux/limits.h> defines.
 */
#ifndef _FK_STRING_SHIM_LIMITS_H
#define _FK_STRING_SHIM_LIMITS_H
#include <limits.h>
#endif
