/* Private shim for the `lcm` differential test: the interface of lib/math/gcd.c
 * exactly as include/linux/gcd.h declares it.
 */
#ifndef _FK_LCM_SHIM_GCD_H
#define _FK_LCM_SHIM_GCD_H

#include <linux/compiler.h>
#include <linux/jump_label.h>

DECLARE_STATIC_KEY_TRUE(efficient_ffs_key);

unsigned long gcd(unsigned long a, unsigned long b) __attribute_const__;

#endif
