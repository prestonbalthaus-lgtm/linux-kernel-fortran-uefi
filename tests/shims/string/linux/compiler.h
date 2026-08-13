/* SPDX-License-Identifier: GPL-2.0 */
/* Private shim for the `string` differential test -- see mk/string.mk.
 * Only the attribute and branch-hint spellings lib/string.c references.
 * `__visible` is dropped rather than mapped onto __attribute__((externally_visible)):
 * that attribute only means anything under -flto, which this build does not use.
 */
#ifndef _FK_STRING_SHIM_COMPILER_H
#define _FK_STRING_SHIM_COMPILER_H

#define __visible
#define __packed	__attribute__((__packed__))
#define likely(x)	(x)
#define unlikely(x)	(x)

#endif
