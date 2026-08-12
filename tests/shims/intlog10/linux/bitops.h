/* Private shim for the intlog10 differential test.
 * fls() is reproduced VERBATIM from the kernel's own generic implementation,
 * vendor/linux-7.1.8/include/asm-generic/bitops/fls.h, so the oracle keeps
 * the kernel's exact semantics: fls(0) = 0, fls(1) = 1, fls(0x80000000) = 32.
 */
#ifndef _FK_SHIM_BITOPS_H
#define _FK_SHIM_BITOPS_H

static inline int generic_fls(unsigned int x)
{
	int r = 32;

	if (!x)
		return 0;
	if (!(x & 0xffff0000u)) {
		x <<= 16;
		r -= 16;
	}
	if (!(x & 0xff000000u)) {
		x <<= 8;
		r -= 8;
	}
	if (!(x & 0xf0000000u)) {
		x <<= 4;
		r -= 4;
	}
	if (!(x & 0xc0000000u)) {
		x <<= 2;
		r -= 2;
	}
	if (!(x & 0x80000000u)) {
		x <<= 1;
		r -= 1;
	}
	return r;
}

#define fls(x) generic_fls(x)

#endif
