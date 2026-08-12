/* Private shim for the intlog2 differential test -- tests/shims/intlog2/. */
#ifndef _FK_SHIM_INTLOG2_KERNEL_H
#define _FK_SHIM_INTLOG2_KERNEL_H
#include <linux/types.h>
#define ARRAY_SIZE(a)	(sizeof(a) / sizeof((a)[0]))
#define likely(x)	__builtin_expect(!!(x), 1)
#define unlikely(x)	__builtin_expect(!!(x), 0)
#endif
