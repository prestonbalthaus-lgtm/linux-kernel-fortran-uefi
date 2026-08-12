/* Private shim for the intlog2 differential test -- tests/shims/intlog2/.
 * Prototypes only, matching vendor include/linux/int_log.h. */
#ifndef _FK_SHIM_INTLOG2_INT_LOG_H
#define _FK_SHIM_INTLOG2_INT_LOG_H
#include <linux/types.h>
extern unsigned int intlog2(u32 value);
extern unsigned int intlog10(u32 value);
#endif
