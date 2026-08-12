/* Private shim: WARN_ON keeps its value semantics from
 * include/asm-generic/bug.h -- it evaluates to !!(condition) -- but the
 * kernel-only taint/backtrace side effect is dropped. int_log.c uses
 * WARN_ON(1) purely for its side effect and ignores the value, so this
 * changes nothing the differential test observes.
 */
#ifndef _FK_SHIM_BUG_H
#define _FK_SHIM_BUG_H
#include <linux/kernel.h>

#define WARN_ON(condition) ({				\
	int __ret_warn_on = !!(condition);		\
	unlikely(__ret_warn_on);			\
})

#endif
