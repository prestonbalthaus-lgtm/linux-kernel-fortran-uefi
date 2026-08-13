/* Behavioural + differential test for src/mm/fk_heap.f90.
 *
 * WHAT THIS DIFFS AGAINST, SINCE IT IS NOT ONE C FUNCTION.  There is no
 * upstream original to compile into oracle-heap.o; mk/heap.mk says why.  So
 * this file carries the oracle, in the shape a block allocator makes possible:
 * a REFERENCE MODEL OF THE LIVE SET.  For every pointer kmalloc has handed out
 * and not taken back, the model remembers three things -- the address, the
 * number of bytes that were asked for, and one fill byte -- and after EVERY
 * SINGLE OPERATION it re-asserts all of them at once:
 *
 *   * every live block still holds its own fill byte, end to end.  This is the
 *     check that catches two blocks overlapping, and it is the reason the fill
 *     is per-block rather than a constant: a shared pattern agrees with an
 *     allocator that handed the same address out twice.
 *   * every pointer is 16-byte aligned, and heap_size_of() is at least what was
 *     asked for.
 *   * no two live [p, p + heap_size_of(p)) ranges intersect.
 *   * the block sizes the model can see add up to exactly the USED word the
 *     module's own walk computes -- so a block that kfree failed to release is
 *     a mismatch here rather than a leak nobody notices.
 *   * heap_check() returns 0.  That is the module's own strongest statement --
 *     the blocks tile the window EXACTLY and no two adjacent free blocks were
 *     left unmerged -- and asking it after every operation rather than at the
 *     end is what turns "the heap ended up fine" into "the heap was never not
 *     fine".
 *
 * THE WORKLOAD IS RANDOMISED, and deterministically so: fk_srand/fk_rand from
 * the harness, one constant seed, no time() and no rand().  A heap bug is a
 * bug about a SEQUENCE, and a fixed list of calls only ever finds the sequences
 * somebody already thought of.  A run that fails must fail again identically or
 * it cannot be debugged, which is why the seed is a literal.
 *
 * WHY THE FREE ORDER GETS ITS OWN THREE SCENARIOS.  The module's header says
 * the back tag exists so kfree can find the block BELOW it in constant time.
 * Deleting backward coalescing leaves a heap that still passes every ascending
 * free, because ascending frees are the case forward coalescing already
 * covers.  It is descending and scrambled order that leave N fragments, so
 * each order is run separately and each one ends with the same assertion: the
 * window is back to exactly ONE block.
 *
 * WHAT THE MODEL IS NOT.  It is not an independent derivation of a block
 * allocator -- it does not model headers, splitting or coalescing at all, and
 * it could not: it deliberately knows nothing about the layout, so it cannot
 * agree with a wrong layout.  What it knows is what a CALLER is owed, and
 * everything about the layout is checked by heap_check(), which is the
 * module's code and therefore proved capable of failing by the mutation gate
 * rather than by this file.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "fk_test.h"

/* int64_t is `long` here, so a bare "%lld" in FK_EQ would be a format mismatch
 * on every comparison in the file.  One cast each, once. */
#define EQ64(what, a, b) FK_EQ(what, (long long)(a), (long long)(b), "%lld")
#define EQ32(what, a, b) FK_EQ(what, (int)(a), (int)(b), "%d")

/* --- the Fortran module's bind(c) surface -------------------------------- */
int32_t heap_init(void);
int64_t kmalloc(int64_t n);
int64_t kzalloc(int64_t n);
void    kfree(int64_t p);
int64_t heap_check(void);
int64_t heap_size_of(int64_t p);
int64_t heap_base(void);
int64_t heap_top(void);

/* The statistics block. bind(c) in the module for exactly this, so what is
 * read here is the real array and not an accessor that could agree with wrong
 * counters.  Fortran subscripts from 1 and C does not: every index below is
 * the module's FK_HS_* minus one. */
extern int64_t fk_heap_stat[10];
enum { HS_MAGIC, HS_MAPPED, HS_USED, HS_FREE, HS_BLOCKS,
       HS_ALLOCS, HS_FREES, HS_LARGEST, HS_FAILED, HS_BADFREE, HS_WORDS };

/* --- constants, mirroring src/mm/fk_heap.f90 ----------------------------- */
#define HEAP_ALIGN   16
#define HEAP_HDR     16
#define HEAP_MIN     32
#define HEAP_CHUNK   65536
#define HEAP_PAGE    4096
#define HEAP_MAX_REQ 1073741824LL
#define HEAP_MAGIC   0x4B48454150000001LL
#define HEAP_OK      0

/* One scenario runs thousands of checks and "MISMATCH heap_check" repeated
 * over names none of them.  One buffer, built per check.  NEVER pass the
 * result of L() to something that calls L() itself -- there is one buffer. */
static char fk_lbl[160];
static const char *L(const char *what, const char *field)
{
	snprintf(fk_lbl, sizeof(fk_lbl), "%s / %s", what, field);
	return fk_lbl;
}

/* --- the page supplier ---------------------------------------------------- */

/* THIS IS THE BOUNDARY THAT MAKES THE ALLOCATOR TESTABLE.  fk_heap.f90 never
 * decides where memory comes from; it calls heap_sbrk(bytes), which must map
 * that many bytes IMMEDIATELY ABOVE the window already handed out and return
 * the address, or 0.  The kernel implements it out of PMM frames and VMM
 * mappings.  Here it is one large aligned arena and a bump pointer -- and
 * because everything above the boundary is arithmetic over an address range,
 * the allocator under test on this host is byte-for-byte the one that runs in
 * the guest, not a stand-in for it.
 *
 * arena_cap is a VARIABLE and not the allocation size, because exhaustion has
 * to be reachable: shrinking it makes heap_sbrk start answering 0 in the
 * middle of a kmalloc, which is the only way to ask whether a failed growth
 * costs anything.
 */
#define ARENA_BYTES ((size_t)8 << 20)

static uint8_t *arena;
static size_t   arena_cap;	/* how much of the arena heap_sbrk may hand out */
static size_t   arena_used;
static size_t   sbrk_skew;	/* one-shot: bytes to waste before the next answer */

int64_t heap_sbrk(int64_t bytes)
{
	uint8_t *p;

	if (bytes <= 0)
		return 0;
	/* An injected discontinuity is consumed whether or not the request can
	 * then be met, exactly as a real mapping would be: a supplier does not
	 * get to un-map a range the caller went on to refuse. */
	arena_used += sbrk_skew;
	sbrk_skew   = 0;
	if (arena_used + (size_t)bytes > arena_cap)
		return 0;
	p = arena + arena_used;
	arena_used += (size_t)bytes;
	return (int64_t)(uintptr_t)p;
}

/* --- the reference model of the live set --------------------------------- */

#define MAX_LIVE   128		/* the model's capacity */
#define CHURN_LIVE  48		/* how many the random phase keeps in flight */
#define CHURN_OPS 2500

struct blk {
	int64_t p;		/* what kmalloc returned */
	int64_t n;		/* payload bytes the caller asked for */
	uint8_t fill;		/* the byte all n of them must still hold */
};

static struct blk live[MAX_LIVE];
static int        nlive;
static int64_t    m_allocs, m_frees;	/* what the model believes the counters are */
static unsigned   fill_seq;

/* 1..255: never zero, because a zeroed block must not be able to pass for a
 * painted one, and that is exactly what kzalloc's scenario turns on. */
static uint8_t next_fill(void)
{
	return (uint8_t)(1 + (fill_seq++ % 255));
}

static int find_live(int64_t p)
{
	int i;

	for (i = 0; i < nlive; i++)
		if (live[i].p == p)
			return i;
	return -1;
}

struct range { int64_t lo, hi; };

static int cmp_range(const void *a, const void *b)
{
	const struct range *x = a, *y = b;

	return x->lo < y->lo ? -1 : x->lo > y->lo ? 1 : 0;
}

static int cmp_i64(const void *a, const void *b)
{
	int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;

	return x < y ? -1 : x > y ? 1 : 0;
}

/* Everything the model can assert, asserted at once.  Called after EVERY
 * operation, so it is written to run at memcmp speed rather than to read
 * prettily: the fill check is "the first byte is the fill AND every byte
 * equals the next one", which is the same statement as "all n bytes are the
 * fill" and costs one library call instead of n compares.
 *
 * The counted violations collapse into one FK_EQ each on purpose.  A hundred
 * live blocks would otherwise put a hundred checks per operation into the
 * total and drown the count that matters. */
static void audit(const char *what)
{
	static struct range r[MAX_LIVE];
	int misaligned = 0, undersized = 0, dirty = 0, overlapping = 0;
	int64_t on_loan = 0;
	int i;

	for (i = 0; i < nlive; i++) {
		const uint8_t *q = (const uint8_t *)(uintptr_t)live[i].p;
		int64_t n = live[i].n;
		int64_t sz = heap_size_of(live[i].p);

		if (live[i].p & (HEAP_ALIGN - 1))
			misaligned++;
		if (sz < n)
			undersized++;
		if (q[0] != live[i].fill ||
		    (n > 1 && memcmp(q, q + 1, (size_t)n - 1) != 0))
			dirty++;

		r[i].lo = live[i].p;
		r[i].hi = live[i].p + (sz > n ? sz : n);
		on_loan += sz + HEAP_HDR;
	}
	qsort(r, (size_t)nlive, sizeof r[0], cmp_range);
	for (i = 1; i < nlive; i++)
		if (r[i].lo < r[i - 1].hi)
			overlapping++;

	EQ32(L(what, "every live pointer is 16-byte aligned"), 0, misaligned);
	EQ32(L(what, "heap_size_of covers what was asked for"), 0, undersized);
	EQ32(L(what, "every live block still holds its own fill byte"), 0, dirty);
	EQ32(L(what, "no two live blocks overlap"), 0, overlapping);

	/* heap_check() recomputes the statistics from its own walk, so it has
	 * to run before any of them is read. */
	EQ64(L(what, "heap_check"), 0, heap_check());
	EQ64(L(what, "the counters agree on allocations"), m_allocs,
	     fk_heap_stat[HS_ALLOCS]);
	EQ64(L(what, "the counters agree on frees"), m_frees,
	     fk_heap_stat[HS_FREES]);
	if (heap_base() != 0) {
		/* The block sizes the model can see, against the walk's own
		 * total.  A block kfree left marked used shows up here. */
		EQ64(L(what, "the heap and the model agree on what is on loan"),
		     on_loan, fk_heap_stat[HS_USED]);
		EQ64(L(what, "used and free tile the window"),
		     heap_top() - heap_base(),
		     fk_heap_stat[HS_USED] + fk_heap_stat[HS_FREE]);
		EQ32(L(what, "the largest free block fits in the free total"), 1,
		     fk_heap_stat[HS_LARGEST] <= fk_heap_stat[HS_FREE]);
	}
}

/* Record a block the model did not paint itself -- kzalloc's, whose whole
 * point is that the allocator supplied the bytes. */
static void model_adopt(int64_t p, int64_t n, uint8_t fill)
{
	if (nlive >= MAX_LIVE) {
		printf("  FATAL: the model's live table is full\n");
		exit(2);
	}
	live[nlive].p = p;
	live[nlive].n = n;
	live[nlive].fill = fill;
	nlive++;
	m_allocs++;
}

static int64_t model_alloc(const char *what, int64_t n)
{
	int64_t p = kmalloc(n);

	if (p != 0) {
		uint8_t f = next_fill();

		model_adopt(p, n, f);
		memset((void *)(uintptr_t)p, f, (size_t)n);
	}
	audit(what);
	return p;
}

static void model_free(const char *what, int i)
{
	kfree(live[i].p);
	live[i] = live[nlive - 1];
	nlive--;
	m_frees++;
	audit(what);
}

/* Repaint a live block, keeping the model in step.  Used where the exact bytes
 * matter to what the allocator will do with them. */
static void repaint(int i, uint8_t f)
{
	live[i].fill = f;
	memset((void *)(uintptr_t)live[i].p, f, (size_t)live[i].n);
}

static void drain(const char *what)
{
	while (nlive > 0)
		model_free(what, (int)(fk_rand() % (uint64_t)nlive));
}

/* --- fixtures ------------------------------------------------------------ */

/* A heap that has never been grown, over an arena of the stated size.  The
 * module's state is process-global, so a scenario that inherited the previous
 * one's window would pass here and fail on the second boot of a machine. */
static void fresh(const char *what, size_t cap)
{
	int nonzero = 0, i;

	arena_used = 0;
	arena_cap  = cap;
	sbrk_skew  = 0;
	nlive      = 0;
	m_allocs   = 0;
	m_frees    = 0;

	EQ32(L(what, "heap_init"), HEAP_OK, heap_init());
	EQ64(L(what, "the statistics block is stamped"), HEAP_MAGIC,
	     fk_heap_stat[HS_MAGIC]);
	for (i = HS_MAPPED; i < HS_WORDS; i++)
		if (fk_heap_stat[i] != 0)
			nonzero++;
	EQ32(L(what, "init clears every counter"), 0, nonzero);
	EQ64(L(what, "nothing is mapped until the first kmalloc"), 0, heap_base());
	EQ64(L(what, "nothing is mapped until the first kmalloc"), 0, heap_top());
	EQ64(L(what, "an unmapped heap is a consistent heap"), 0, heap_check());
}

/* The property the back tag exists for.  Everything has been given back, so
 * the window must be ONE free block -- not N adjacent ones that add up. */
static void assert_one_block(const char *what)
{
	EQ32(L(what, "nothing is still live"), 0, nlive);
	EQ64(L(what, "heap_check"), 0, heap_check());
	EQ64(L(what, "the window coalesced back to exactly one block"), 1,
	     fk_heap_stat[HS_BLOCKS]);
	EQ64(L(what, "and nothing at all is used"), 0, fk_heap_stat[HS_USED]);
	EQ64(L(what, "the one block is the whole window"),
	     heap_top() - heap_base(), fk_heap_stat[HS_FREE]);
	EQ64(L(what, "and it is what the largest-free word reports"),
	     heap_top() - heap_base(), fk_heap_stat[HS_LARGEST]);
	EQ64(L(what, "every allocation was given back"), fk_heap_stat[HS_ALLOCS],
	     fk_heap_stat[HS_FREES]);
}

/* --- scenario: randomised churn ------------------------------------------ */

/* The sizes the module's own arithmetic turns on: one below, at, and one above
 * each alignment and page boundary, plus the chunk size it grows by. */
static const int64_t EDGE_SIZES[] = {
	1, 15, 16, 17, 31, 32, 33, 63, 64, 65,
	4095, 4096, 4097, 65535, 65536, 65537, 131072,
};
#define N_EDGE_SIZES ((int)(sizeof EDGE_SIZES / sizeof EDGE_SIZES[0]))

/* Weighted so the wide sizes appear without the live set becoming megabytes
 * that every audit then has to re-read. */
static int64_t pick_size(uint64_t r)
{
	switch ((r >> 16) & 7) {
	case 0:
	case 1:
		return EDGE_SIZES[(r >> 24) % N_EDGE_SIZES];
	case 7:
		return 1 + (int64_t)((r >> 32) % 131072);
	default:
		return 1 + (int64_t)((r >> 32) % 512);
	}
}

static void scenario_churn(void)
{
	int i;

	fresh("churn", ARENA_BYTES);
	for (i = 0; i < CHURN_OPS; i++) {
		uint64_t r = fk_rand();

		if (nlive > 0 && (nlive >= CHURN_LIVE || (r & 3) == 0))
			model_free("churn", (int)((r >> 8) % (uint64_t)nlive));
		else
			model_alloc("churn", pick_size(r));
	}
	EQ32("churn: the heap actually did some work", 1,
	     fk_heap_stat[HS_ALLOCS] > 1000);
	drain("churn");
	assert_one_block("churn");
}

/* --- scenario: the order blocks are freed in ----------------------------- */

enum { ORD_ASC, ORD_DESC, ORD_SCRAMBLED };

static void scenario_order(const char *what, int order)
{
	int64_t ptr[MAX_LIVE];
	int n = 0, i;

	fresh(what, ARENA_BYTES);
	for (i = 0; i < 3 * N_EDGE_SIZES && n < MAX_LIVE; i++) {
		int64_t p = model_alloc(what, EDGE_SIZES[i % N_EDGE_SIZES]);

		if (p == 0)
			break;
		ptr[n++] = p;
	}
	EQ32(L(what, "the fixture filled the heap"), 1, n == 3 * N_EDGE_SIZES);

	qsort(ptr, (size_t)n, sizeof ptr[0], cmp_i64);
	if (order == ORD_DESC) {
		for (i = 0; i < n / 2; i++) {
			int64_t t = ptr[i];

			ptr[i] = ptr[n - 1 - i];
			ptr[n - 1 - i] = t;
		}
	} else if (order == ORD_SCRAMBLED) {
		for (i = n - 1; i > 0; i--) {
			int j = (int)(fk_rand() % (uint64_t)(i + 1));
			int64_t t = ptr[i];

			ptr[i] = ptr[j];
			ptr[j] = t;
		}
	}

	for (i = 0; i < n; i++)
		model_free(what, find_live(ptr[i]));
	assert_one_block(what);
}

/* --- scenario: splitting ------------------------------------------------- */

static void scenario_split(void)
{
	int64_t big, small, follow, top, blocks;

	fresh("split", ARENA_BYTES);

	/* One 40000-byte request grows the window by a whole 64 KiB chunk, so
	 * once it is given back the window is a single free block far larger
	 * than anything that follows needs. */
	big = model_alloc("split", 40000);
	EQ32("split: the large request was served", 1, big != 0);
	model_free("split", find_live(big));
	assert_one_block("split: the large block came back whole");

	blocks = fk_heap_stat[HS_BLOCKS];
	small  = model_alloc("split", 64);
	EQ64("split: a small request cuts the free block in two", blocks + 1,
	     fk_heap_stat[HS_BLOCKS]);

	/* The remainder is only a real block if something can be allocated out
	 * of it.  heap_top() before and after is the whole assertion: a heap
	 * that dropped the remainder on the floor would have to grow. */
	top    = heap_top();
	follow = model_alloc("split", 1000);
	EQ32("split: the remainder served the next request", 1, follow != 0);
	EQ64("split: and the heap did not grow to serve it", top, heap_top());
	EQ64("split: the two blocks are adjacent, in that order",
	     small + heap_size_of(small) + HEAP_HDR, follow);

	drain("split");
	assert_one_block("split");
}

/* --- scenario: the remainder that is too small to be a block ------------- */

static void scenario_no_split(void)
{
	int64_t a, b, p, top, blocks;

	fresh("no split", ARENA_BYTES);

	/* 192 bytes is a 208-byte block, and the 64-byte block behind it is a
	 * guard: with a used neighbour above and nothing below, giving the
	 * first one back leaves a hole of EXACTLY 208 bytes that no coalesce
	 * can enlarge. */
	a = model_alloc("no split", 192);
	b = model_alloc("no split", 64);
	EQ32("no split: the fixture was served", 1, a != 0 && b != 0);
	EQ64("no split: the hole will be 208 bytes of block", 192, heap_size_of(a));
	model_free("no split", find_live(a));

	top    = heap_top();
	blocks = fk_heap_stat[HS_BLOCKS];

	/* 176 bytes needs 192 of block, leaving 16 of the 208 -- below the
	 * header plus one alignment unit that the smallest block costs.  There
	 * is no block to be made of the remainder, so the whole 208 goes to the
	 * caller as slack rather than being left as a fragment nothing fits. */
	p = model_alloc("no split", 176);
	EQ64("no split: the hole was reused", a, p);
	EQ64("no split: and no fragment was left behind", blocks,
	     fk_heap_stat[HS_BLOCKS]);
	EQ64("no split: the caller is told the LARGER size", 192, heap_size_of(p));
	EQ64("no split: and the heap did not grow", top, heap_top());

	/* The contrast, out of the same 208-byte hole: a remainder of 80 is a
	 * block, so this one does split and the caller is told the exact size. */
	model_free("no split", find_live(p));
	blocks = fk_heap_stat[HS_BLOCKS];
	p = model_alloc("no split", 100);
	EQ64("no split: a remainder of 80 DOES become a block", blocks + 1,
	     fk_heap_stat[HS_BLOCKS]);
	EQ64("no split: and that caller is told the exact size", 112,
	     heap_size_of(p));

	drain("no split");
	assert_one_block("no split");
	(void)b;
}

/* --- scenario: kzalloc -------------------------------------------------- */

static void scenario_kzalloc(void)
{
	int64_t a, b, q, sz;
	int nonzero = 0, i;

	fresh("kzalloc", ARENA_BYTES);

	/* 4090 asks for a 4112-byte block, so heap_size_of is 4096 and six
	 * bytes of it are slack -- the module clears to the BLOCK end, not to
	 * the request, and the slack is where that shows. */
	a = model_alloc("kzalloc", 4090);
	b = model_alloc("kzalloc", 64);		/* guard: keeps a's block off the free tail */
	EQ32("kzalloc: the fixture was served", 1, a != 0 && b != 0);
	sz = heap_size_of(a);
	EQ64("kzalloc: the fixture block has slack in it", 4096, sz);

	/* Fill the WHOLE block, slack included, with a byte that is not zero.
	 * Without this the scenario proves nothing: fresh pages from the
	 * supplier are already zero, so a kzalloc that cleared nothing would
	 * pass. */
	memset((void *)(uintptr_t)a, 0xA5, (size_t)sz);
	repaint(find_live(a), 0xA5);
	model_free("kzalloc", find_live(a));

	q = kzalloc(4090);
	EQ64("kzalloc takes the block that was just freed", a, q);
	EQ64("kzalloc: and all of it", sz, heap_size_of(q));
	for (i = 0; i < sz; i++)
		if (((const uint8_t *)(uintptr_t)q)[i] != 0)
			nonzero++;
	EQ32("kzalloc clears every byte of a block that was full of 0xA5", 0,
	     nonzero);
	model_adopt(q, 4090, 0);
	audit("kzalloc");

	/* kzalloc refuses exactly what kmalloc refuses, and counts it once. */
	{
		int64_t failed = fk_heap_stat[HS_FAILED];

		EQ64("kzalloc(0) is refused", 0, kzalloc(0));
		EQ64("kzalloc(0) is counted once", failed + 1,
		     fk_heap_stat[HS_FAILED]);
	}
	audit("kzalloc");

	drain("kzalloc");
	assert_one_block("kzalloc");
}

/* --- scenario: what kfree refuses ---------------------------------------- */

/* Every refusal must cost exactly one badfree and change nothing else.  A heap
 * that corrupts itself on a bad free reports the defect somewhere else
 * entirely, so "the heap is still consistent" is the half of this that
 * matters. */
static void expect_badfree(const char *what, int64_t p)
{
	int64_t badfree = fk_heap_stat[HS_BADFREE];
	int64_t frees   = fk_heap_stat[HS_FREES];
	int64_t top     = heap_top();
	int64_t base    = heap_base();

	kfree(p);
	EQ64(L(what, "is counted exactly once"), badfree + 1,
	     fk_heap_stat[HS_BADFREE]);
	EQ64(L(what, "is not counted as a free"), frees, fk_heap_stat[HS_FREES]);
	EQ64(L(what, "does not move the window"), base, heap_base());
	EQ64(L(what, "does not resize the window"), top, heap_top());
	audit(what);
}

static void scenario_guards(void)
{
	int64_t a, big, badfree, frees;

	fresh("guards", ARENA_BYTES);

	/* a is the first block in the window -- no predecessor, and a used
	 * successor -- so giving it back leaves its header exactly where it
	 * was.  That is what makes the double free's outcome a property of the
	 * guard rather than of which way a coalesce happened to go. */
	a   = model_alloc("guards", 64);
	(void)model_alloc("guards", 64);
	big = model_alloc("guards", 4096);
	(void)model_alloc("guards", 64);
	EQ32("guards: the fixture was served", 1, a != 0 && big != 0);

	model_free("guards", find_live(a));
	EQ64("a freed pointer reports no size", 0, heap_size_of(a));
	expect_badfree("a double free", a);

	expect_badfree("a pointer at heap_base()", heap_base());
	expect_badfree("a pointer below heap_base()", heap_base() - HEAP_PAGE);
	expect_badfree("a pointer at heap_top()", heap_top());
	expect_badfree("a pointer above heap_top()", heap_top() + HEAP_PAGE);

	/* An interior pointer has no header of its own, so what the allocator
	 * reads as a size word is whatever the CALLER last wrote there.  Paint
	 * the block with 0xAB and that word is 0xABABABABABABABAB: masked to a
	 * size it is still negative as a signed quadword, which is below the
	 * minimum block size and refused.  Every other repeated non-zero byte
	 * lands on one of the other two arms of the same guard -- the used bit
	 * clear, or a block claiming to end past the top of the window -- and
	 * an all-zero payload gives a size of 0.  There is no fill for which
	 * this is accepted, which is the point; 0xAB is chosen so the arm that
	 * fires is stated rather than assumed. */
	repaint(find_live(big), 0xAB);
	audit("guards");
	expect_badfree("an interior pointer, one byte in", big + 1);
	expect_badfree("an interior pointer, sixteen bytes into a large block",
		       big + HEAP_HDR);
	expect_badfree("a misaligned pointer", big + 8);
	expect_badfree("a pointer misaligned by one", big - 1);

	/* free(NULL) has been a no-op since C89 and this one is too.  It must
	 * not be counted: a kernel that frees an optional pointer on every
	 * error path would otherwise report thousands of bad frees. */
	badfree = fk_heap_stat[HS_BADFREE];
	frees   = fk_heap_stat[HS_FREES];
	kfree(0);
	EQ64("kfree(0) is not a bad free", badfree, fk_heap_stat[HS_BADFREE]);
	EQ64("kfree(0) is not a free either", frees, fk_heap_stat[HS_FREES]);
	audit("kfree(0)");

	drain("guards");
	assert_one_block("guards");
}

/* --- scenario: what kmalloc refuses -------------------------------------- */

static void expect_refused(const char *what, int64_t n)
{
	int64_t failed = fk_heap_stat[HS_FAILED];
	int64_t top    = heap_top();

	EQ64(L(what, "is refused"), 0, kmalloc(n));
	EQ64(L(what, "is counted exactly once"), failed + 1,
	     fk_heap_stat[HS_FAILED]);
	EQ64(L(what, "does not grow the heap"), top, heap_top());
	audit(what);
}

static void scenario_refusals(void)
{
	fresh("refusals", ARENA_BYTES);
	(void)model_alloc("refusals", 64);	/* a window to refuse things against */

	expect_refused("kmalloc(0)", 0);
	expect_refused("kmalloc(-1)", -1);
	/* n is a signed quadword carrying an unsigned request: a caller that
	 * wrapped must not have n + header wrap back into something small
	 * enough for a first-fit scan to satisfy. */
	expect_refused("kmalloc(INT64_MIN)", INT64_MIN);
	expect_refused("kmalloc(-16)", -16);
	expect_refused("kmalloc over the 1 GiB cap", HEAP_MAX_REQ + 1);
	expect_refused("kmalloc far over the cap", HEAP_MAX_REQ * 4);
	/* The cap itself is a legitimate request that no supplier here can
	 * meet: refused by the growth, not by the bound, and counted the same. */
	expect_refused("kmalloc of the cap itself", HEAP_MAX_REQ);

	EQ32("refusals: nothing was handed out", 1, nlive == 1);
	drain("refusals");
	assert_one_block("refusals");
}

/* --- scenario: the supplier runs out ------------------------------------- */

static void scenario_exhaustion(void)
{
	int64_t p = 0, freed, top, failed;
	int served = 0, i;

	/* Three chunks exactly: heap_sbrk answers three times and then starts
	 * answering 0, in the middle of a kmalloc rather than at a tidy
	 * boundary. */
	fresh("exhaustion", 3 * (size_t)HEAP_CHUNK);

	failed = fk_heap_stat[HS_FAILED];
	for (i = 0; i < MAX_LIVE; i++) {
		p = model_alloc("exhaustion", 4000);
		if (p == 0)
			break;
		served++;
	}
	EQ32("exhaustion: the heap did run out", 1, p == 0);
	EQ32("exhaustion: after serving what it could", 1, served > 40);
	EQ64("exhaustion: and the refusal was counted once", failed + 1,
	     fk_heap_stat[HS_FAILED]);
	EQ64("exhaustion: the window is the whole arena", 3 * (int64_t)HEAP_CHUNK,
	     heap_top() - heap_base());

	/* A FAILED GROWTH MUST COST NOTHING.  Everything that was live before
	 * the refusal is still live and still intact -- audit() has just said
	 * so -- and the hole from one kfree serves the same request again out
	 * of the window the heap already has. */
	freed = live[0].p;
	top   = heap_top();
	model_free("exhaustion", 0);
	p = model_alloc("exhaustion", 4000);
	EQ32("exhaustion: a returned block is servable again", 1, p != 0);
	EQ64("exhaustion: out of the hole it left", freed, p);
	EQ64("exhaustion: without growing", top, heap_top());

	drain("exhaustion");
	assert_one_block("exhaustion");
}

/* --- scenario: a supplier that answers somewhere else --------------------- */

static void scenario_noncontiguous(void)
{
	int64_t base, top, failed;

	/* The first growth is the only one with no window to be contiguous
	 * with, so the only thing it can refuse is a misaligned answer -- and
	 * it must, because the header is one alignment unit and every payload
	 * in the heap would otherwise be misaligned. */
	fresh("a misaligned first window", ARENA_BYTES);
	sbrk_skew = 8;
	failed = fk_heap_stat[HS_FAILED];
	EQ64("a misaligned first window is refused", 0, kmalloc(64));
	EQ64("a misaligned first window is counted once", failed + 1,
	     fk_heap_stat[HS_FAILED]);
	EQ64("a misaligned first window maps nothing", 0, heap_base());
	EQ64("a misaligned first window leaves a consistent heap", 0, heap_check());

	/* Once the skew is in the arena every later answer inherits it, so the
	 * contiguity test starts from a clean supplier. */
	fresh("non-contiguous growth", ARENA_BYTES);
	(void)model_alloc("non-contiguous growth", 64);
	base = heap_base();
	top  = heap_top();
	EQ32("the aligned first window was accepted", 1, base != 0);

	/* A page too high: aligned, plausible, and not where the window ends.
	 * It must be REFUSED rather than stitched -- a heap that accepted it
	 * would have a hole in the middle of its implicit list that every walk
	 * from then on would step straight into. */
	sbrk_skew = HEAP_PAGE;
	failed = fk_heap_stat[HS_FAILED];
	EQ64("a non-contiguous growth is refused", 0, kmalloc(100000));
	EQ64("a non-contiguous growth is counted once", failed + 1,
	     fk_heap_stat[HS_FAILED]);
	EQ64("a non-contiguous growth does not move the window", base, heap_base());
	EQ64("a non-contiguous growth does not extend the window", top, heap_top());
	EQ64("a non-contiguous growth leaves a consistent heap", 0, heap_check());
	audit("non-contiguous growth");

	/* And the window it already had still works. */
	EQ32("what fits is still served afterwards", 1,
	     model_alloc("non-contiguous growth", 64) != 0);
	drain("non-contiguous growth");
	assert_one_block("non-contiguous growth");
}

int main(void)
{
	arena = aligned_alloc(HEAP_PAGE, ARENA_BYTES);
	if (!arena) {
		printf("  FATAL: cannot allocate the %zu-byte arena\n", ARENA_BYTES);
		return 2;
	}
	/* Not zero: a supplier that handed back pages of zeroes would make
	 * kzalloc's scenario, and any "the header was written" assertion,
	 * agree with a module that wrote nothing. */
	memset(arena, 0x5C, ARENA_BYTES);

	fk_srand(0x4B48454150ULL);	/* "KHEAP" -- constant, so a failure repeats */

	scenario_churn();
	scenario_order("free in ascending address order", ORD_ASC);
	scenario_order("free in descending address order", ORD_DESC);
	scenario_order("free in scrambled address order", ORD_SCRAMBLED);
	scenario_split();
	scenario_no_split();
	scenario_kzalloc();
	scenario_guards();
	scenario_refusals();
	scenario_exhaustion();
	scenario_noncontiguous();

	free(arena);
	return fk_report("heap");
}
