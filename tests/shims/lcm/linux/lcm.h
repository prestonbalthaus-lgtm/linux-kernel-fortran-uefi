/* Private shim for the `lcm` differential test: the interface of lib/math/lcm.c
 * exactly as include/linux/lcm.h declares it.
 */
#ifndef _FK_LCM_SHIM_LCM_H
#define _FK_LCM_SHIM_LCM_H

#include <linux/compiler.h>

unsigned long lcm(unsigned long a, unsigned long b) __attribute_const__;
unsigned long lcm_not_zero(unsigned long a, unsigned long b) __attribute_const__;

#endif
