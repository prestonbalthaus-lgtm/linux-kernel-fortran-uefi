/* SPDX-License-Identifier: GPL-2.0 */
/* Private shim for the `string` differential test -- see mk/string.mk.
 * WARN_ON_ONCE keeps its value semantics from include/asm-generic/bug.h --
 * it evaluates to !!(condition) -- and drops the kernel-only taint/backtrace
 * side effect. Its one caller, sized_strscpy(), is not under test.
 */
#ifndef _FK_STRING_SHIM_BUG_H
#define _FK_STRING_SHIM_BUG_H
#include <linux/compiler.h>

#define WARN_ON_ONCE(condition)	unlikely(!!(condition))

#endif
