/* Private shim: the prototypes from include/linux/int_log.h, nothing else. */
#ifndef _FK_SHIM_INT_LOG_H
#define _FK_SHIM_INT_LOG_H
#include <linux/types.h>

extern unsigned int intlog2(u32 value);
extern unsigned int intlog10(u32 value);

#endif
