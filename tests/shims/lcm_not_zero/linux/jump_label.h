#ifndef _FK_SHIM_LCMNZ_JUMP_LABEL_H
#define _FK_SHIM_LCMNZ_JUMP_LABEL_H
/* Minimal stand-in for the kernel static-key machinery.
 *
 * lib/math/gcd.c does DEFINE_STATIC_KEY_TRUE(efficient_ffs_key), i.e. the key's
 * compiled-in default state is "true", so static_branch_likely() takes the
 * binary_gcd() path.  Reproducing that default is all this shim does -- no part
 * of the gcd algorithm lives here.
 */
struct static_key_true { int fk_enabled; };

#define STATIC_KEY_TRUE_INIT		{ .fk_enabled = 1 }
#define DEFINE_STATIC_KEY_TRUE(name)	\
	struct static_key_true name = STATIC_KEY_TRUE_INIT
#define DECLARE_STATIC_KEY_TRUE(name)	\
	extern struct static_key_true name
#define static_branch_likely(key)	(!!(key)->fk_enabled)
#define static_branch_unlikely(key)	(!!(key)->fk_enabled)

#endif /* _FK_SHIM_LCMNZ_JUMP_LABEL_H */
