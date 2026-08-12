#ifndef _FK_SHIM_LCMNZ_GCD_H
#define _FK_SHIM_LCMNZ_GCD_H
/* Declarations only -- mirrors vendor include/linux/gcd.h. */
#include <linux/compiler.h>
#include <linux/jump_label.h>

DECLARE_STATIC_KEY_TRUE(efficient_ffs_key);

unsigned long gcd(unsigned long a, unsigned long b) __attribute_const__;

#endif /* _FK_SHIM_LCMNZ_GCD_H */
