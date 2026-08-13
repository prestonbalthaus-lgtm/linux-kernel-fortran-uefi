/* SPDX-License-Identifier: GPL-2.0 */
/* Differential test: kernel's own lib/string.c  vs  src/lib/fk_string.f90
 *
 *   void *memset (void *s, int c, size_t n);
 *   void *memcpy (void *dest, const void *src, size_t n);
 *   void *memmove(void *dest, const void *src, size_t n);
 *   int   memcmp (const void *cs, const void *ct, size_t n);
 *
 * The oracle keeps the kernel's own symbol names -- mk/string.mk selects these
 * four out of lib/string.c with that file's own __HAVE_ARCH_* guards -- so the
 * memset/memcpy calls gcc emits for this driver's own array copies also land
 * on the oracle. Harmless, but it is why nothing here treats the C library as
 * a second reference.
 *
 * Both sides work inside a 4 KiB arena seeded with a fixed pseudo-random
 * pattern. Three things are checked per call: the two arenas agree byte for
 * byte, neither side moved a byte outside [dest, dest+n), and both returned
 * dest.
 *
 * memcmp's SIGN is load-bearing: lib/string.c returns the difference of two
 * UNSIGNED chars, so 0x80 against 0x00 is +128 and not -128. The exact int is
 * compared, not its sign.
 */
#include <stdarg.h>
#include <linux/types.h>
#include "fk_test.h"

void *memset(void *s, int c, size_t n);            /* oracle: real kernel source */
void *memcpy(void *dest, const void *src, size_t n);
void *memmove(void *dest, const void *src, size_t n);
int   memcmp(const void *cs, const void *ct, size_t n);

void *fk_memset(void *s, int c, size_t n);         /* Fortran bind(c) */
void *fk_memcpy(void *dest, const void *src, size_t n);
void *fk_memmove(void *dest, const void *src, size_t n);
int   fk_memcmp(const void *cs, const void *ct, size_t n);

#define ASZ	4096u
#define NODIFF	((size_t)-1)		/* chk_memcmp: leave the operands equal */

static unsigned char ref[ASZ];		/* seeded pattern, never mutated */
static unsigned char pre[ASZ];		/* the armed baseline of this case  */
static unsigned char ca[ASZ], fa[ASZ];	/* oracle arena, Fortran arena      */
static char desc[96];			/* this case, for the mismatch line */

static const char *lbl(const char *fmt, ...)
{
	static char buf[112];
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(buf, sizeof buf, fmt, ap);
	va_end(ap);
	return buf;
}

static void reset(void)
{
	unsigned i;

	for (i = 0; i < ASZ; i++)
		ca[i] = ref[i];
}

/* Snapshot the case's starting state and give both sides the same arena. */
static void arm(void)
{
	unsigned i;

	for (i = 0; i < ASZ; i++)
		pre[i] = fa[i] = ca[i];
}

/* First byte outside [off, off+n) that moved since arm(), or -1. */
static int spill(const unsigned char *a, size_t off, size_t n)
{
	unsigned i;

	for (i = 0; i < ASZ; i++)
		if ((i < off || i >= off + n) && a[i] != pre[i])
			return (int)i;
	return -1;
}

static void chk_arenas(void)
{
	unsigned i;

	for (i = 0; i < ASZ; i++)
		FK_EQ(ca[i] == fa[i] ? desc : lbl("%s byte %u", desc, i),
		      (int)ca[i], (int)fa[i], "%d");
}

static void chk_wrote(const void *cr, const void *fr, size_t off, size_t n)
{
	chk_arenas();
	FK_EQ(lbl("%s guard C", desc), -1, spill(ca, off, n), "%d");
	FK_EQ(lbl("%s guard F", desc), -1, spill(fa, off, n), "%d");
	FK_EQ(lbl("%s ret", desc), cr == ca + off, fr == fa + off, "%d");
}

static void chk_memset(size_t off, int c, size_t n)
{
	void *cr, *fr;

	snprintf(desc, sizeof desc, "memset off=%zu c=%d n=%zu", off, c, n);
	reset();
	arm();
	cr = memset(ca + off, c, n);
	fr = fk_memset(fa + off, c, n);
	chk_wrote(cr, fr, off, n);
}

static void chk_memcpy(size_t doff, size_t soff, size_t n)
{
	void *cr, *fr;

	snprintf(desc, sizeof desc, "memcpy d=%zu s=%zu n=%zu", doff, soff, n);
	reset();
	arm();
	cr = memcpy(ca + doff, ca + soff, n);
	fr = fk_memcpy(fa + doff, fa + soff, n);
	chk_wrote(cr, fr, doff, n);
}

static void chk_memmove(size_t doff, size_t soff, size_t n)
{
	void *cr, *fr;

	snprintf(desc, sizeof desc, "memmove d=%zu s=%zu n=%zu", doff, soff, n);
	reset();
	arm();
	cr = memmove(ca + doff, ca + soff, n);
	fr = fk_memmove(fa + doff, fa + soff, n);
	chk_wrote(cr, fr, doff, n);
}

/* Copies the operand at @aoff over @boff so the two are equal, then forces
 * a[at]=av, b[at]=bv so the first difference sits at a known index.
 */
static void chk_memcmp(size_t aoff, size_t boff, size_t n, size_t at,
		       int av, int bv)
{
	size_t i;
	int cr, fr;

	snprintf(desc, sizeof desc,
		 "memcmp a=%zu b=%zu n=%zu at=%ld av=%d bv=%d",
		 aoff, boff, n, (long)at, av, bv);
	reset();
	for (i = 0; i < n; i++)
		ca[boff + i] = ca[aoff + i];
	if (at < n) {
		ca[aoff + at] = (unsigned char)av;
		ca[boff + at] = (unsigned char)bv;
	}
	arm();
	cr = memcmp(ca + aoff, ca + boff, n);
	fr = fk_memcmp(fa + aoff, fa + boff, n);
	FK_EQ(lbl("%s ret", desc), cr, fr, "%d");
	chk_arenas();
	FK_EQ(lbl("%s guard C", desc), -1, spill(ca, 0, 0), "%d");
	FK_EQ(lbl("%s guard F", desc), -1, spill(fa, 0, 0), "%d");
}

int main(void)
{
	/* 1024 is the large case; the arena is four times that, so the offset
	 * pairs below keep source and destination apart and still leave guard
	 * bytes outside every destination. */
	static const size_t n_edges[] = { 0, 1, 2, 7, 8, 9, 15, 16, 17,
					  63, 64, 65, 1024 };
	static const int c_vals[] = { 0, 1, 0x7F, 0x80, 0xFF,
				      0x100,		/* truncates to 0     */
				      -1, -128, -129 };	/* and negative c     */
	static const size_t cmp_off[][2] = { { 0, 1536 }, { 1541, 3 } };
	static const int cmp_val[][2] = {
		{ 0x80, 0x00 },	{ 0x00, 0x80 },	/* sign: unsigned difference */
		{ 0xFF, 0x7F },	{ 0x7F, 0xFF },
		{ 0x01, 0x00 },	{ 0x00, 0xFF },
	};
	unsigned i, j, k, m;

	fk_srand(0x5721C0FFEEULL);
	for (i = 0; i < ASZ; i++)
		ref[i] = (unsigned char)fk_rand();

	for (j = 0; j < sizeof n_edges / sizeof *n_edges; j++) {
		size_t n = n_edges[j];
		long half = (long)(n / 2);

		/* --- (a) memset: every c against every n, aligned and not -- */
		for (k = 0; k < sizeof c_vals / sizeof *c_vals; k++) {
			chk_memset(1536, c_vals[k], n);
			chk_memset(1541, c_vals[k], n);
		}

		/* --- (b) memcpy: non-overlapping, both directions ---------- */
		chk_memcpy(1536, 0, n);
		chk_memcpy(1536, 3072, n);
		chk_memcpy(0, 1536, n);
		chk_memcpy(3072, 1536, n);
		chk_memcpy(1537, 3, n);
		chk_memcpy(3, 1537, n);

		/* --- (c) memmove: dest<src, dest>src, dest==src, disjoint -- */
		{
			const long d[] = { 0, 1, -1, 3, -3, 7, -7, 8, -8,
					   half, -half, 1536, -1536 };

			for (k = 0; k < sizeof d / sizeof *d; k++)
				chk_memmove(1536, (size_t)(1536 + d[k]), n);
		}

		/* --- (d) memcmp: equal, first / middle / last byte --------- */
		for (k = 0; k < 2; k++) {
			const size_t at[] = { 0, n / 2, n ? n - 1 : 0, NODIFF };

			for (m = 0; m < sizeof at / sizeof *at; m++) {
				unsigned v;

				for (v = 0; v < sizeof cmp_val / sizeof *cmp_val; v++)
					chk_memcmp(cmp_off[k][0], cmp_off[k][1],
						   n, at[m],
						   cmp_val[v][0], cmp_val[v][1]);
			}
		}
	}

	/* --- (e) randomized sweep ------------------------------------- */
	fk_srand(0xDEADBEEF5747C0FFULL);
	for (i = 0; i < 2000; i++) {
		u64 r = fk_rand();
		size_t n = (size_t)(r % 257);
		size_t d = (size_t)((r >> 16) % (ASZ - 257));
		size_t s = (size_t)((r >> 40) % (ASZ - 257));
		int c = (int)(fk_rand() & 0x1FF) - 128;
		size_t at = (size_t)(fk_rand() % (n + 1));

		chk_memset(d, c, n);
		chk_memmove(d, s, n);
		chk_memcmp(d, s, n, at, 0x80, 0x00);
		if (d + n <= s || s + n <= d)
			chk_memcpy(d, s, n);
	}

	return fk_report("string");
}
