/* SPDX-License-Identifier: GPL-2.0 */
/* Private shim for the `string` differential test -- see mk/string.mk.
 *
 * Reached the way the kernel reaches it: -include linux/kconfig.h, mirroring
 * KBUILD_CPPFLAGS in the top-level Makefile. The real IS_ENABLED() expands to
 * 0 for any CONFIG that is neither builtin nor a module; the only option
 * lib/string.c queries is CONFIG_KMSAN, which this build does not set.
 */
#ifndef _FK_STRING_SHIM_KCONFIG_H
#define _FK_STRING_SHIM_KCONFIG_H

#define IS_ENABLED(option)	0

#endif
