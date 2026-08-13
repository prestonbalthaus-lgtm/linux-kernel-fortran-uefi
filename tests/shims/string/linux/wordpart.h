/* SPDX-License-Identifier: GPL-2.0 */
/* Private shim for the `string` differential test -- see mk/string.mk.
 * REPEAT_BYTE reproduced VERBATIM from include/linux/wordpart.h; the
 * word-at-a-time constants are built out of it.
 */
#ifndef _FK_STRING_SHIM_WORDPART_H
#define _FK_STRING_SHIM_WORDPART_H

#define REPEAT_BYTE(x)	((~0ul / 0xff) * (x))

#endif
