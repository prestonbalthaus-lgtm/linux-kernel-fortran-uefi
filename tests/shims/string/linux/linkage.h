/* SPDX-License-Identifier: GPL-2.0 */
/* Private shim for the `string` differential test -- see mk/string.mk.
 * memcmp() is declared __visible, which reaches lib/string.c through
 * <linux/linkage.h> -> <linux/compiler_types.h> in the real tree.
 */
#ifndef _FK_STRING_SHIM_LINKAGE_H
#define _FK_STRING_SHIM_LINKAGE_H
#include <linux/compiler.h>
#endif
