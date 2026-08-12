/* Private shim for the intlog10 differential test: only the two kernel.h
 * facilities lib/math/int_log.c actually uses.
 *   ARRAY_SIZE  -- as in include/linux/array_size.h, minus __must_be_array()
 *                  (a compile-time type assertion that adds 0 to the value).
 *   unlikely    -- as in include/linux/compiler.h; a branch hint only.
 */
#ifndef _FK_SHIM_KERNEL_H
#define _FK_SHIM_KERNEL_H
#include <linux/types.h>

#define ARRAY_SIZE(arr) (sizeof(arr) / sizeof((arr)[0]))
#define likely(x)	__builtin_expect(!!(x), 1)
#define unlikely(x)	__builtin_expect(!!(x), 0)

#endif
