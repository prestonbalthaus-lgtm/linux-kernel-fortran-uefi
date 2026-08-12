/* Private shim standing in for include/linux/gcd.h + include/linux/jump_label.h.
 * CONFIG_JUMP_LABEL off, key defined TRUE => static_branch_likely() is taken,
 * i.e. the oracle runs the binary_gcd() path.
 */
#ifndef _FK_SHIM_GCD_GCD_H
#define _FK_SHIM_GCD_GCD_H

#define DECLARE_STATIC_KEY_TRUE(name)	extern int name
#define DEFINE_STATIC_KEY_TRUE(name)	int name = 1
#define static_branch_likely(x)		1

DECLARE_STATIC_KEY_TRUE(efficient_ffs_key);

unsigned long gcd(unsigned long a, unsigned long b);

#endif
