#ifndef _FK_SHIM_LCMNZ_LCM_H
#define _FK_SHIM_LCMNZ_LCM_H
/* Declarations only -- mirrors vendor include/linux/lcm.h. */
#include <linux/compiler.h>

unsigned long lcm(unsigned long a, unsigned long b) __attribute_const__;
unsigned long lcm_not_zero(unsigned long a, unsigned long b) __attribute_const__;

#endif /* _FK_SHIM_LCMNZ_LCM_H */
