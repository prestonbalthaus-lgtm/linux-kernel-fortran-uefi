/* Private shim for the int_sqrt differential test -- userspace stand-in for
 * the kernel's <linux/limits.h>. int_sqrt.c only reaches for ULONG_MAX inside
 * the `#if BITS_PER_LONG < 64` block, which is compiled out at 64 bits, but
 * the #include still has to resolve.
 */
#ifndef _FK_SHIM_INT_SQRT_LIMITS_H
#define _FK_SHIM_INT_SQRT_LIMITS_H
#define UINT_MAX   (~0U)
#define ULONG_MAX  (~0UL)
#define ULLONG_MAX (~0ULL)
#endif
