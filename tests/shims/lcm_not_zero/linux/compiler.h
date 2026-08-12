#ifndef _FK_SHIM_LCMNZ_COMPILER_H
#define _FK_SHIM_LCMNZ_COMPILER_H
/* Private shim for the lcm_not_zero differential test.
 * Only the attribute spellings the oracle sources actually use. */
#ifndef __attribute_const__
#define __attribute_const__	__attribute__((__const__))
#endif
#ifndef __always_inline
#define __always_inline		inline __attribute__((__always_inline__))
#endif
#ifndef likely
#define likely(x)		(x)
#define unlikely(x)		(x)
#endif
#endif /* _FK_SHIM_LCMNZ_COMPILER_H */
