/* Private shim for the `lcm` differential test.
 *
 * lib/math/gcd.c selects between binary_gcd() and the even/odd loop with a
 * static key that DEFINE_STATIC_KEY_TRUE initialises to true. Modelling the
 * key as a plain int keeps both kernel-reachable code paths compiled AND lets
 * the driver flip it at run time, so the differential sweep covers both.
 */
#ifndef _FK_LCM_SHIM_JUMP_LABEL_H
#define _FK_LCM_SHIM_JUMP_LABEL_H

#define DEFINE_STATIC_KEY_TRUE(name)   int name = 1
#define DECLARE_STATIC_KEY_TRUE(name)  extern int name

#define static_branch_likely(key)      (*(key))
#define static_branch_unlikely(key)    (*(key))

#endif
