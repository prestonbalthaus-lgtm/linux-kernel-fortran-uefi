/* Private shim for the `lcm` differential test -- see mk/lcm.mk.
 * Only the attribute spellings lib/math/lcm.c and lib/math/gcd.c actually
 * reference. `__attribute_const__` is dropped rather than mapped onto
 * __attribute__((const)) so that gcc cannot CSE away oracle calls: the test
 * gets strictly more real invocations, never fewer.
 */
#ifndef _FK_LCM_SHIM_COMPILER_H
#define _FK_LCM_SHIM_COMPILER_H

/* glibc's <sys/cdefs.h> also defines this; the kernel's own compiler.h
 * defines it unconditionally, so undef first and match that behaviour.
 */
#undef  __attribute_const__
#define __attribute_const__
#define likely(x)   (x)
#define unlikely(x) (x)

#endif
