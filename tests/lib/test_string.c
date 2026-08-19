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
 *
 * ROADMAP 1.1 ADDS FOUR MORE, and they need a channel the arena cannot give:
 *
 *   size_t strlen (const char *s);
 *   char  *strcpy (char *dest, const char *src);
 *   int    strcmp (const char *cs, const char *ct);
 *   int    strncmp(const char *cs, const char *ct, size_t count);
 *
 * The arena catches a WRITE outside the destination window. Every one of these
 * four can be wrong by READING too far and still return the right answer --
 * strlen that scans one byte past the terminator, strncmp that ignores its
 * count and finds the same difference anyway. So there is a second buffer:
 * two mmap'd pages with the upper one PROT_NONE, the string planted so its
 * terminator is the last readable byte, and a SIGSEGV handler that turns the
 * fault into an ordinary mismatch line. The oracle runs on the same buffer,
 * and it passing is the evidence the boundary is where this claims it is.
 *
 * strcmp's and strncmp's RETURN VALUE is -1, 0 or 1 and not a difference --
 * lib/string.c:35 is `return c1 < c2 ? -1 : 1`, which is not what memcmp two
 * functions above it does. The comparison is still on unsigned chars, so 0x80
 * against 0x00 is +1.
 */
#include <stdarg.h>
#include <setjmp.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/mman.h>
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

size_t strlen (const char *s);                     /* oracle: real kernel source */
char  *strcpy (char *dest, const char *src);
int    strcmp (const char *cs, const char *ct);
int    strncmp(const char *cs, const char *ct, size_t count);

size_t fk_strlen (const char *s);                  /* Fortran bind(c) */
char  *fk_strcpy (char *dest, const char *src);
int    fk_strcmp (const char *cs, const char *ct);
int    fk_strncmp(const char *cs, const char *ct, size_t count);

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

/* ---- roadmap 1.1: the string half ---------------------------------------
 *
 * Same arena, same three questions, one more: a string case must also control
 * where the terminator is. The arena is seeded pseudo-random, so a string
 * planted in it ends wherever the pattern's next zero byte happens to fall --
 * plant() maps those away, because a case whose name says len=17 and whose
 * string is 4 bytes long is a case that tests nothing it claims to.
 */

/* @len non-zero bytes at @off, then the terminator. */
static void plant(size_t off, size_t len, u64 salt)
{
	size_t i;

	for (i = 0; i < len; i++) {
		unsigned char b = (unsigned char)(ref[(off + i) % ASZ] ^
						  (salt >> ((i & 7) * 8)));
		ca[off + i] = b ? b : 0x5A;
	}
	ca[off + len] = 0;
}

static void chk_strlen(size_t off, size_t len, u64 salt)
{
	size_t cr, fr;

	snprintf(desc, sizeof desc, "strlen off=%zu len=%zu", off, len);
	reset();
	plant(off, len, salt);
	arm();
	cr = strlen((char *)ca + off);
	fr = fk_strlen((char *)fa + off);
	FK_EQ(lbl("%s ret", desc), (long)cr, (long)fr, "%ld");
	chk_arenas();
	/* strlen writes nothing at all, so the whole arena is the guard. */
	FK_EQ(lbl("%s guard C", desc), -1, spill(ca, 0, 0), "%d");
	FK_EQ(lbl("%s guard F", desc), -1, spill(fa, 0, 0), "%d");
}

/* The destination window is len+1 -- a strcpy that drops the terminator writes
 * one byte too few and one that copies past it writes one too many, and spill()
 * sees exactly one of those two. chk_arenas() sees the other.
 */
static void chk_strcpy(size_t doff, size_t soff, size_t len, u64 salt)
{
	char *cr, *fr;

	snprintf(desc, sizeof desc, "strcpy d=%zu s=%zu len=%zu",
		 doff, soff, len);
	reset();
	plant(soff, len, salt);
	arm();
	cr = strcpy((char *)ca + doff, (char *)ca + soff);
	fr = fk_strcpy((char *)fa + doff, (char *)fa + soff);
	chk_wrote(cr, fr, doff, len + 1);
}

/* Both operands are the same @n-byte string, then a[at] and b[at] are forced.
 * Passing 0 for av or bv shortens that operand, which is the prefix case --
 * "abc" against "abcd" -- and is where strcmp's c1==0 exit is decided.
 */
static void chk_strcmp(size_t aoff, size_t boff, size_t n, size_t at,
		       int av, int bv, u64 salt)
{
	size_t i;
	int cr, fr;

	snprintf(desc, sizeof desc,
		 "strcmp a=%zu b=%zu n=%zu at=%ld av=%d bv=%d",
		 aoff, boff, n, (long)at, av, bv);
	reset();
	plant(aoff, n, salt);
	for (i = 0; i <= n; i++)
		ca[boff + i] = ca[aoff + i];
	if (at < n) {
		ca[aoff + at] = (unsigned char)av;
		ca[boff + at] = (unsigned char)bv;
	}
	arm();
	cr = strcmp((char *)ca + aoff, (char *)ca + boff);
	fr = fk_strcmp((char *)fa + aoff, (char *)fa + boff);
	FK_EQ(lbl("%s ret", desc), cr, fr, "%d");
	chk_arenas();
	FK_EQ(lbl("%s guard C", desc), -1, spill(ca, 0, 0), "%d");
	FK_EQ(lbl("%s guard F", desc), -1, spill(fa, 0, 0), "%d");
}

static void chk_strncmp(size_t aoff, size_t boff, size_t n, size_t at,
			int av, int bv, size_t count, u64 salt)
{
	size_t i;
	int cr, fr;

	snprintf(desc, sizeof desc,
		 "strncmp a=%zu b=%zu n=%zu at=%ld av=%d bv=%d cnt=%zu",
		 aoff, boff, n, (long)at, av, bv, count);
	reset();
	plant(aoff, n, salt);
	for (i = 0; i <= n; i++)
		ca[boff + i] = ca[aoff + i];
	if (at < n) {
		ca[aoff + at] = (unsigned char)av;
		ca[boff + at] = (unsigned char)bv;
	}
	arm();
	cr = strncmp((char *)ca + aoff, (char *)ca + boff, count);
	fr = fk_strncmp((char *)fa + aoff, (char *)fa + boff, count);
	FK_EQ(lbl("%s ret", desc), cr, fr, "%d");
	chk_arenas();
	FK_EQ(lbl("%s guard C", desc), -1, spill(ca, 0, 0), "%d");
	FK_EQ(lbl("%s guard F", desc), -1, spill(fa, 0, 0), "%d");
}

/* ---- the guard page ------------------------------------------------------
 *
 * The arena above answers "did it write outside the window". It cannot answer
 * "did it READ outside the string", and for these four that is the failure
 * mode that returns the right answer anyway. Two pages, the upper one
 * PROT_NONE, the terminator on the last readable byte: one byte further is a
 * fault, and the fault is caught rather than fatal so the run still reports.
 *
 * The oracle is run on the same buffer first. It NOT faulting is the evidence
 * the boundary is where this file says it is -- otherwise a green result here
 * would only mean the page was somewhere harmless.
 */
static unsigned char *gpage;		/* [gpage, gpage+gpsz) is readable   */
static size_t gpsz;			/* [gpage+gpsz, +gpsz) faults        */
static sigjmp_buf gjmp;
static volatile sig_atomic_t garmed;

static void gsegv(int sig)
{
	(void)sig;
	if (garmed)
		siglongjmp(gjmp, 1);
	_exit(3);			/* a fault outside a guarded call */
}

static void gsetup(void)
{
	unsigned char *m;
	long ps = sysconf(_SC_PAGESIZE);

	gpsz = (size_t)ps;
	m = mmap(NULL, gpsz * 2, PROT_READ | PROT_WRITE,
		 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (m == MAP_FAILED)
		_exit(2);
	if (mprotect(m + gpsz, gpsz, PROT_NONE) != 0)
		_exit(2);
	gpage = m;
	signal(SIGSEGV, gsegv);
	signal(SIGBUS, gsegv);
}

/* @len non-zero bytes ending with the terminator on the LAST readable byte. */
static char *gplant(size_t len, u64 salt)
{
	unsigned char *p = gpage + gpsz - 1 - len;
	size_t i;

	for (i = 0; i < len; i++) {
		unsigned char b = (unsigned char)(ref[i % ASZ] ^
						  (salt >> ((i & 7) * 8)));
		p[i] = b ? b : 0x5A;
	}
	p[len] = 0;
	return (char *)p;
}

#define G_RUN(sink, call)			\
	do {					\
		garmed = 1;			\
		if (sigsetjmp(gjmp, 1) == 0) {	\
			(sink) = (call);	\
			garmed = 0;		\
		} else {			\
			garmed = 0;		\
			(sink) = -1;		\
		}				\
	} while (0)

static void chk_guard_strlen(size_t len)
{
	long cr, fr;
	char *s;

	snprintf(desc, sizeof desc, "guard strlen len=%zu", len);
	s = gplant(len, 0xA51CE501ULL);
	G_RUN(cr, (long)strlen(s));
	G_RUN(fr, (long)fk_strlen(s));
	FK_EQ(lbl("%s oracle stayed in the page", desc), (long)len, cr, "%ld");
	FK_EQ(lbl("%s ret", desc), cr, fr, "%ld");
}

/* Equal strings, so both sides must scan to the terminator and stop there. */
static void chk_guard_strcmp(size_t len)
{
	long cr, fr;
	char *s;
	size_t i;

	snprintf(desc, sizeof desc, "guard strcmp len=%zu", len);
	s = gplant(len, 0xB0C0FFEEULL);
	for (i = 0; i <= len; i++)
		ca[i] = (unsigned char)s[i];
	G_RUN(cr, (long)strcmp(s, (char *)ca));
	G_RUN(fr, (long)fk_strcmp(s, (char *)ca));
	FK_EQ(lbl("%s oracle stayed in the page", desc), 0L, cr, "%ld");
	FK_EQ(lbl("%s ret", desc), cr, fr, "%ld");
}

/* count == 0 against a pointer into the UNMAPPED page. The strongest statement
 * this file makes: not "it read the right number of bytes" but "it read none".
 */
static void chk_guard_strncmp_zero(void)
{
	long cr, fr;
	char *dead = (char *)gpage + gpsz;

	snprintf(desc, sizeof desc, "guard strncmp count=0 on an unmapped page");
	G_RUN(cr, (long)strncmp(dead, dead, 0));
	G_RUN(fr, (long)fk_strncmp(dead, dead, 0));
	FK_EQ(lbl("%s oracle read nothing", desc), 0L, cr, "%ld");
	FK_EQ(lbl("%s ret", desc), cr, fr, "%ld");
}

/* The strings are equal and count runs one PAST the terminator, so a
 * implementation that spends its count before testing for the terminator
 * walks into the guard page.
 */
static void chk_guard_strncmp(size_t len, size_t count)
{
	long cr, fr;
	char *s;
	size_t i;

	snprintf(desc, sizeof desc, "guard strncmp len=%zu cnt=%zu", len, count);
	s = gplant(len, 0xD15EA5EDULL);
	for (i = 0; i <= len; i++)
		ca[i] = (unsigned char)s[i];
	G_RUN(cr, (long)strncmp(s, (char *)ca, count));
	G_RUN(fr, (long)fk_strncmp(s, (char *)ca, count));
	FK_EQ(lbl("%s oracle stayed in the page", desc), 0L, cr, "%ld");
	FK_EQ(lbl("%s ret", desc), cr, fr, "%ld");
}

/* The destination's last legal write is the terminator. One byte more faults,
 * which is the write-side twin of everything above and the only place in this
 * file where a strcpy overrun is a hard stop rather than a spill() line.
 */
static void chk_guard_strcpy(size_t len)
{
	long crc, frc;
	char *d;
	size_t i;

	snprintf(desc, sizeof desc, "guard strcpy len=%zu", len);
	for (i = 0; i < len; i++) {
		unsigned char b = (unsigned char)(ref[i % ASZ] ^ 0x3C);
		ca[i] = b ? b : 0x5A;
	}
	ca[len] = 0;

	d = (char *)gpage + gpsz - 1 - len;
	G_RUN(crc, (long)(strcpy(d, (char *)ca) == d));
	FK_EQ(lbl("%s oracle stayed in the page", desc), 1L, crc, "%ld");
	for (i = 0; i <= len; i++)
		FK_EQ(lbl("%s oracle byte %zu", desc, i),
		      (long)(unsigned char)ca[i], (long)(unsigned char)d[i], "%ld");

	for (i = 0; i <= len; i++)
		d[i] = 0x7E;
	G_RUN(frc, (long)(fk_strcpy(d, (char *)ca) == d));
	FK_EQ(lbl("%s ret", desc), crc, frc, "%ld");
	for (i = 0; i <= len; i++)
		FK_EQ(lbl("%s byte %zu", desc, i),
		      (long)(unsigned char)ca[i], (long)(unsigned char)d[i], "%ld");
}

/* THE ORACLE HAS TO BE THE KERNEL'S, and this ran red before it was written.
 * build/oracle-string.o depended on lib/string.c alone, so deleting four
 * __HAVE_ARCH_* guards from mk/string.mk did not rebuild it: the four symbols
 * were absent, the link fell through to glibc, and every string case below was
 * diffing Fortran against the C library. Makefile's MKDEPS is the fix; this is
 * the assertion that says so out loud, because a dependency can rot again and
 * a wrong oracle is invisible when the two happen to agree.
 *
 * lib/string.c:285 returns `c1 < c2 ? -1 : 1`. glibc returns c1 - c2. One byte
 * pair separates them and nothing else in this file would notice.
 */
static void chk_oracle_identity(void)
{
	FK_EQ("strcmp sign convention  C=lib/string.c  F=what linked",
	      1, strcmp("\x80", "\x01"), "%d");
	FK_EQ("strcmp sign the other way (glibc would say -127)",
	      -1, strcmp("\x01", "\x80"), "%d");
	FK_EQ("strncmp sign convention, same test",
	      1, strncmp("\x80", "\x01", 1), "%d");
	FK_EQ("strncmp sign the other way",
	      -1, strncmp("\x01", "\x80", 1), "%d");
}

static void run_string_cases(void)
{
	/* 0/1/2 and either side of 8, 16 and 64: the word boundaries the
	 * oracle's own word-at-a-time paths turn on. 1024 is the large case. */
	static const size_t l_edges[] = { 0, 1, 2, 3, 7, 8, 9, 15, 16, 17,
					  31, 63, 64, 65, 1024 };
	/* aligned pair, then a pair with DIFFERENT relative misalignment. */
	static const size_t s_off[][2] = { { 0, 1536 }, { 1541, 3 } };
	/* 0 in either column shortens that operand -- the prefix case. */
	static const int s_val[][2] = {
		{ 0x80, 0x01 }, { 0x01, 0x80 },	/* the unsigned-compare trap */
		{ 0xFF, 0x7F }, { 0x7F, 0xFF },
		{ 0x01, 0x02 }, { 0x00, 0x41 },	/* a is a prefix of b        */
		{ 0x41, 0x00 },			/* b is a prefix of a        */
	};
	unsigned i, j, k, m, v;

	chk_oracle_identity();

	fk_srand(0xC0DEFACE1177ULL);

	for (j = 0; j < sizeof l_edges / sizeof *l_edges; j++) {
		size_t n = l_edges[j];

		/* --- (a) strlen: aligned and not ------------------------- */
		chk_strlen(1536, n, fk_rand());
		chk_strlen(1541, n, fk_rand());
		chk_strlen(3, n, fk_rand());

		/* --- (b) strcpy: both alignments, both directions -------- */
		chk_strcpy(1536, 0, n, fk_rand());
		chk_strcpy(0, 1536, n, fk_rand());
		chk_strcpy(1537, 3, n, fk_rand());
		chk_strcpy(3, 1537, n, fk_rand());

		/* --- (c) strcmp / strncmp: first, middle, last, none ----- */
		for (k = 0; k < 2; k++) {
			const size_t at[] = { 0, n / 2, n ? n - 1 : 0, NODIFF };

			for (m = 0; m < sizeof at / sizeof *at; m++)
				for (v = 0; v < sizeof s_val / sizeof *s_val; v++) {
					u64 salt = fk_rand();
					size_t cnts[8];
					unsigned c;

					chk_strcmp(s_off[k][0], s_off[k][1], n,
						   at[m], s_val[v][0],
						   s_val[v][1], salt);

					/* Every boundary count has to be
					 * relative to the difference AND to
					 * the terminator: 0, either side of
					 * at, either side of n. */
					cnts[0] = 0;
					cnts[1] = at[m] == NODIFF ? 1 : at[m];
					cnts[2] = cnts[1] + 1;
					cnts[3] = n;
					cnts[4] = n + 1;
					cnts[5] = n + 2;
					cnts[6] = 4096;
					/* SIZE_MAX. c_size_t is a SIGNED int64
					 * in Fortran, so a count with the top
					 * bit set is negative there and
					 * unsigned in the oracle. The
					 * terminator exits long before the
					 * count would, so this is testable
					 * where memcmp's equivalent is not. */
					cnts[7] = (size_t)-1;
					for (c = 0; c < 8; c++)
						chk_strncmp(s_off[k][0],
							    s_off[k][1], n,
							    at[m], s_val[v][0],
							    s_val[v][1],
							    cnts[c], salt);
				}
		}
	}

	/* --- (d) randomized sweep ---------------------------------------- */
	fk_srand(0x517E1EC7ULL);
	for (i = 0; i < 1500; i++) {
		u64 r = fk_rand();
		size_t n = (size_t)(r % 129);
		size_t a = (size_t)((r >> 16) % 1024);
		size_t b = (size_t)(2048 + ((r >> 40) % 1024));
		size_t at = (size_t)(fk_rand() % (n + 1));
		size_t cnt = (size_t)(fk_rand() % (n + 3));
		int av = (int)(fk_rand() & 0xFF);
		int bv = (int)(fk_rand() & 0xFF);
		u64 salt = fk_rand();

		chk_strlen(a, n, salt);
		chk_strcpy(b, a, n, salt);
		chk_strcmp(a, b, n, at, av, bv, salt);
		chk_strncmp(a, b, n, at, av, bv, cnt, salt);
	}

	/* --- (e) the guard page ------------------------------------------ */
	gsetup();
	for (i = 0; i <= 64; i++) {
		chk_guard_strlen(i);
		chk_guard_strcmp(i);
		chk_guard_strcpy(i);
		chk_guard_strncmp(i, i);
		chk_guard_strncmp(i, i + 1);
		chk_guard_strncmp(i, i + 2);
		chk_guard_strncmp(i, 4096);
	}
	chk_guard_strncmp_zero();
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

	run_string_cases();

	return fk_report("string");
}
