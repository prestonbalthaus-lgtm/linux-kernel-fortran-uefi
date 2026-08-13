/* SPDX-License-Identifier: GPL-2.0 */
/* Private shim for the `string` differential test -- see mk/string.mk.
 * The x86 4 KiB page, from arch/x86/include/asm/page_types.h. Its only user in
 * lib/string.c is sized_strscpy()'s page-crossing guard, which is not under test.
 */
#ifndef _FK_STRING_SHIM_PAGE_H
#define _FK_STRING_SHIM_PAGE_H

#define PAGE_SIZE	4096UL

#endif
