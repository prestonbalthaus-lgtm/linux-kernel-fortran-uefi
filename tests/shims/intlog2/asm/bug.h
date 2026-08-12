/* Private shim for the intlog2 differential test -- tests/shims/intlog2/.
 * WARN_ON in the kernel prints a backtrace and evaluates to the condition;
 * userspace differential testing only cares about the returned value. */
#ifndef _FK_SHIM_INTLOG2_BUG_H
#define _FK_SHIM_INTLOG2_BUG_H
#define WARN_ON(c)	({ int __c = !!(c); (void)__c; 0; })
#endif
