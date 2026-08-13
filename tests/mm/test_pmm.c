/* Behavioural + differential test for src/mm/fk_pmm.f90.
 *
 * There is no C original to diff against -- a Multiboot2 parser and a bitmap
 * allocator are a translation of a SPECIFICATION, the same situation the GOP
 * renderer and the UART driver were in.  So this file carries two oracles:
 *
 *   1. A reference bitmap built in C straight from the Multiboot2 spec's rules
 *      and from roadmap 3.4's stated ones, compared BIT FOR BIT against the
 *      Fortran module's own bitmap.  fk_pmm_bitmap is bind(c), so the
 *      comparison is against the real array and not against an accessor that
 *      could agree with a wrong bitmap.
 *   2. Behaviour the reference cannot express: what alloc returns, in what
 *      order, what free refuses, and what survives a re-init.
 *
 * WHAT THE REFERENCE MODEL IS AND IS NOT.  It is an independent
 * implementation, not an independent derivation: both it and the Fortran were
 * written from the same reading of the specification, so a misreading of the
 * spec would be duplicated rather than caught.  Mutation is what covers that
 * gap -- see docs/HARNESS-VALIDATION-PHASE3.md.
 *
 * THE MBI HAS TO LIVE BELOW 1 GiB.  pmm_init refuses an MBI outside the boot
 * stub's identity window, so a static buffer at the usual PIE address would be
 * rejected before it was ever parsed.  The image is mmap'd at a fixed low
 * address instead, which is not a workaround: it means the range check is
 * exercised for real rather than asserted around.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include "fk_test.h"

/* int64_t is `long` here, so a bare "%lld" in FK_EQ would be a format mismatch
 * on every comparison in the file.  One cast each, once. */
#define EQ64(what, a, b) FK_EQ(what, (long long)(a), (long long)(b), "%lld")
#define EQ32(what, a, b) FK_EQ(what, (int)(a), (int)(b), "%d")

/* --- the Fortran module's bind(c) surface -------------------------------- */
int32_t pmm_init(int64_t mbi_phys);
int64_t pmm_alloc_page(void);
int32_t pmm_free_page(int64_t phys);
int32_t pmm_page_is_free(int64_t phys);
int64_t pmm_total_pages(void);
int64_t pmm_free_pages(void);
int64_t pmm_used_pages(void);
int64_t pmm_ignored_bytes(void);
int32_t pmm_region_count(void);
int64_t pmm_region_base(int32_t i);
int64_t pmm_region_len(int32_t i);
int32_t pmm_region_type(int32_t i);
int64_t pmm_verify_reserved(void);
int64_t pmm_verify_kernel_locked(void);

/* The bitmap itself. bind(c) in the module for exactly this. */
extern int64_t fk_pmm_bitmap[];

/* Supplied by boot/ksyms.S in the kernel, from linker.ld's absolute symbols;
 * here they are variables so a scenario can put the "kernel image" anywhere. */
static int64_t g_kernel_lo, g_kernel_hi;
int64_t fk_kernel_phys_start(void) { return g_kernel_lo; }
int64_t fk_kernel_phys_end(void)   { return g_kernel_hi; }

/* --- constants, mirroring src/mm/fk_pmm.f90 ------------------------------ */
#define PAGE_SIZE     4096ULL
#define MAX_PHYS      (64ULL * 1024 * 1024 * 1024)
#define NPAGES        (MAX_PHYS / PAGE_SIZE)
#define NWORDS        (NPAGES / 64)
#define IDMAP_BYTES   (1024ULL * 1024 * 1024)
#define MAX_REGIONS   128
#define MBI_MAX       (16ULL * 1024 * 1024)

enum {
	PMM_OK = 0,
	E_MBI_NULL = 1, E_MBI_ALIGN = 2, E_MBI_RANGE = 3, E_MBI_SIZE = 4,
	E_TAG_OVERRUN = 5, E_NO_MMAP = 6, E_ENTRY_SIZE = 7, E_TOO_MANY = 8,
	E_NO_RAM = 9,
	E_NOT_READY = 16, E_UNALIGNED = 17, E_RANGE = 18, E_NOT_RAM = 19,
	E_DOUBLE_FREE = 20, E_LOCKED = 21,
};

#define MB_AVAILABLE 1
#define MB_RESERVED  2
#define MB_ACPI      3
#define MB_NVS       4
#define MB_BADRAM    5

struct region { uint64_t base, len; uint32_t type; };

/* --- the MBI image ------------------------------------------------------- */
/* Placed low on purpose; see the header. The candidates are tried in order and
 * MAP_FIXED_NOREPLACE means a busy one is reported rather than silently
 * unmapping whatever was there. */
static uint8_t *mbi_mem;
#define MBI_CAP (256 * 1024)

static void mbi_map(void)
{
	static const uintptr_t want[] = { 0x20000000, 0x18000000, 0x10000000,
					  0x08000000, 0x04000000 };
	size_t i;

	for (i = 0; i < sizeof(want) / sizeof(want[0]); i++) {
		void *p = mmap((void *)want[i], MBI_CAP, PROT_READ | PROT_WRITE,
			       MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE,
			       -1, 0);
		if (p != MAP_FAILED && (uintptr_t)p == want[i]) {
			mbi_mem = p;
			return;
		}
		if (p != MAP_FAILED)
			munmap(p, MBI_CAP);
	}
	printf("  FATAL: no free mapping below 1 GiB for the MBI image\n");
	exit(2);
}

static void put32(size_t off, uint32_t v) { memcpy(mbi_mem + off, &v, 4); }
static void put64(size_t off, uint64_t v) { memcpy(mbi_mem + off, &v, 8); }

/* Assemble a Multiboot2 information structure.  entry_size is a parameter
 * because the specification lets a loader grow the mmap entry, and a parser
 * that assumes 24 reads every field of every entry but the first at the wrong
 * offset.  pre_tag inserts an unrelated tag ahead of the map so that tag
 * stepping -- (size + 7) & ~7 -- is exercised on a size that needs padding. */
static size_t mbi_build(const struct region *r, int n, uint32_t entry_size,
			int with_mmap, int pre_tag)
{
	size_t off = 8, mm, i;

	memset(mbi_mem, 0, MBI_CAP);

	if (pre_tag) {
		/* type 2 = bootloader name, "GRUB" + NUL: size 13, so the next
		 * tag only lands right if the walker rounds up to 16. */
		put32(off, 2);
		put32(off + 4, 13);
		memcpy(mbi_mem + off + 8, "GRUB", 5);
		off += 16;
	}

	if (with_mmap) {
		mm = off;
		put32(off, 6);
		put32(off + 8, entry_size);
		put32(off + 12, 0);
		off += 16;
		for (i = 0; i < (size_t)n; i++) {
			put64(off, r[i].base);
			put64(off + 8, r[i].len);
			put32(off + 16, r[i].type);
			put32(off + 20, 0);
			off += entry_size;
		}
		put32(mm + 4, (uint32_t)(off - mm));	/* the tag's own size */
		off = (off + 7) & ~(size_t)7;
	}

	put32(off, 0);		/* end tag */
	put32(off + 4, 8);
	off += 8;

	put32(0, (uint32_t)off);	/* total_size */
	put32(4, 0);			/* reserved */
	return off;
}

/* --- the reference bitmap ------------------------------------------------ */
static uint64_t *ref;

static void ref_set(uint64_t p)   { ref[p >> 6] |= 1ULL << (p & 63); }
static void ref_clr(uint64_t p)   { ref[p >> 6] &= ~(1ULL << (p & 63)); }
static int  ref_used(uint64_t p)  { return (ref[p >> 6] >> (p & 63)) & 1; }

/* Multiboot2 gives base+length; the managed window ends at MAX_PHYS.  Returns
 * 0 when nothing of the range is inside it. */
static int clip(uint64_t base, uint64_t len, uint64_t *lo, uint64_t *hi)
{
	uint64_t last;

	if (len == 0 || base >= MAX_PHYS)
		return 0;
	last = base + len - 1;
	if (last < base || last >= MAX_PHYS)
		last = MAX_PHYS - 1;
	*lo = base;
	*hi = last;
	return 1;
}

/* Available memory rounds INWARD: a frame only partly usable is not usable. */
static void ref_free_inward(uint64_t base, uint64_t len)
{
	uint64_t lo, hi, first, last, p;

	if (!clip(base, len, &lo, &hi))
		return;
	first = (lo + PAGE_SIZE - 1) / PAGE_SIZE;
	last  = (hi + 1) / PAGE_SIZE;
	if (last == 0)
		return;
	last--;
	for (p = first; p <= last && p < NPAGES; p++)
		ref_clr(p);
}

/* Anything unusable rounds OUTWARD: a frame partly reserved is reserved. */
static void ref_take_outward(uint64_t base, uint64_t len)
{
	uint64_t lo, hi, p;

	if (!clip(base, len, &lo, &hi))
		return;
	for (p = lo / PAGE_SIZE; p <= hi / PAGE_SIZE && p < NPAGES; p++)
		ref_set(p);
}

static uint64_t ref_lost(uint64_t base, uint64_t len)
{
	uint64_t last;

	if (len == 0)
		return 0;
	if (base >= MAX_PHYS)
		return len;
	last = base + len - 1;
	if (last < base)
		return 0;
	return last >= MAX_PHYS ? last - (MAX_PHYS - 1) : 0;
}

/* The whole of roadmap 3.4's init contract, in the order it specifies. */
static void ref_build(const struct region *r, int n, uint64_t mbi_lo, uint64_t mbi_hi)
{
	int i;

	memset(ref, 0xFF, NWORDS * 8);
	for (i = 0; i < n; i++)
		if (r[i].type == MB_AVAILABLE)
			ref_free_inward(r[i].base, r[i].len);
	for (i = 0; i < n; i++)
		if (r[i].type != MB_AVAILABLE)
			ref_take_outward(r[i].base, r[i].len);
	ref_take_outward(g_kernel_lo, g_kernel_hi - g_kernel_lo);
	ref_take_outward(mbi_lo, mbi_hi - mbi_lo);
	ref_set(0);
}

/* Frames the reference says are usable RAM, before anything is taken back --
 * i.e. what pmm_total_pages() must report. */
static uint64_t ref_free_pages(void)
{
	uint64_t free_n = 0;
	size_t w;

	for (w = 0; w < NWORDS; w++)
		free_n += (uint64_t)__builtin_popcountll(~ref[w]);
	return free_n;
}

static uint64_t ref_ram_pages(const struct region *r, int n)
{
	int i;

	memset(ref, 0xFF, NWORDS * 8);
	for (i = 0; i < n; i++)
		if (r[i].type == MB_AVAILABLE)
			ref_free_inward(r[i].base, r[i].len);
	return ref_free_pages();
}

/* Bit-for-bit against the module's own array.  Reports the first divergence as
 * a frame number and a physical address, because "word 4711 differs" is not
 * something anybody can act on. */
static void check_bitmap(const char *what)
{
	size_t w;

	for (w = 0; w < NWORDS; w++) {
		if ((uint64_t)fk_pmm_bitmap[w] == ref[w])
			continue;
		{
			uint64_t diff = (uint64_t)fk_pmm_bitmap[w] ^ ref[w];
			int b = __builtin_ctzll(diff);
			uint64_t page = w * 64 + b;

			printf("  MISMATCH %s: frame %llu (0x%llx) F=%s C=%s\n",
			       what, (unsigned long long)page,
			       (unsigned long long)(page * PAGE_SIZE),
			       ((uint64_t)fk_pmm_bitmap[w] >> b) & 1 ? "used" : "free",
			       (ref[w] >> b) & 1 ? "used" : "free");
		}
		fk_checks++;
		fk_fails++;
		return;
	}
	fk_checks++;
}

/* --- scenarios ----------------------------------------------------------- */

/* What QEMU -m 24G actually reports, read off the boot gate's own console.
 * Keeping the real thing here means the host suite and the VM are looking at
 * the same map, and the >4 GiB region is the one that catches a 32-bit
 * truncation anywhere in the parse. */
static const struct region MAP_QEMU24[] = {
	{ 0x0000000000000000ULL, 0x000000000009FC00ULL, MB_AVAILABLE },
	{ 0x000000000009FC00ULL, 0x0000000000000400ULL, MB_RESERVED  },
	{ 0x00000000000F0000ULL, 0x0000000000010000ULL, MB_RESERVED  },
	{ 0x0000000000100000ULL, 0x00000000BFEE0000ULL, MB_AVAILABLE },
	{ 0x00000000BFFE0000ULL, 0x0000000000020000ULL, MB_RESERVED  },
	{ 0x00000000FEFFC000ULL, 0x0000000000004000ULL, MB_RESERVED  },
	{ 0x00000000FFFC0000ULL, 0x0000000000040000ULL, MB_RESERVED  },
	{ 0x0000000100000000ULL, 0x0000000540000000ULL, MB_AVAILABLE },
};

/* Every awkward shape in one map: an available region whose ends are both
 * mid-frame, a zero-length entry, a type the specification does not name, RAM
 * that runs off the top of the managed window, and -- the two that matter most
 * -- a RESERVED and an ACPI region each sitting INSIDE an available one.
 *
 * Those last two sit at 16 MiB and NOT next to the kernel image, and that is
 * the whole point.  An earlier version of this fixture put the overlap at
 * 2.5 MiB, inside [g_kernel_lo, g_kernel_hi); the kernel span marked those
 * frames used anyway, so deleting pmm_init's entire second pass changed
 * nothing and the suite passed a module that let entry ORDER decide whether
 * reserved memory was allocatable.  See H6 in
 * docs/HARNESS-VALIDATION-PHASE3.md.
 */
static const struct region MAP_AWKWARD[] = {
	{ 0x0000000000000000ULL, 0x0000000000100000ULL, MB_AVAILABLE },
	{ 0x0000000000100800ULL, 0x000000000007F000ULL, MB_AVAILABLE },
	{ 0x0000000000200000ULL, 0x0000000000100000ULL, MB_AVAILABLE },
	{ 0x0000000000400000ULL, 0x0000000000000000ULL, MB_AVAILABLE },
	{ 0x0000000000500000ULL, 0x0000000000010000ULL, 7            },
	{ 0x0000000000600000ULL, 0x0000000000010000ULL, MB_NVS       },
	{ 0x0000000000700000ULL, 0x0000000000010000ULL, MB_BADRAM    },
	/* available, then two unusable regions strictly inside it */
	{ 0x0000000001000000ULL, 0x0000000000100000ULL, MB_AVAILABLE },
	{ 0x0000000001040000ULL, 0x0000000000010000ULL, MB_RESERVED  },
	{ 0x0000000001080000ULL, 0x0000000000008000ULL, MB_ACPI      },
	/* and one sharing a frame with usable RAM rather than whole frames */
	{ 0x00000000010F0800ULL, 0x0000000000000800ULL, MB_ACPI      },
	{ 0x0000000FFFFF0000ULL, 0x0000000000030000ULL, MB_AVAILABLE },
};

static const struct region MAP_TINY[] = {
	{ 0x0000000000000000ULL, 0x0000000000010000ULL, MB_AVAILABLE },
	{ 0x0000000000010000ULL, 0x0000000000010000ULL, MB_RESERVED  },
};

/* Runs a map through both implementations and asserts everything that can be
 * asserted without allocating.  Returns pmm_init's status. */
static int32_t scenario(const char *name, const struct region *r, int n,
			uint32_t entry_size, int pre_tag)
{
	size_t total = mbi_build(r, n, entry_size, 1, pre_tag);
	uint64_t mlo = (uint64_t)(uintptr_t)mbi_mem;
	int32_t st;
	uint64_t want_ram, want_free, lost = 0;
	int i;

	st = pmm_init((int64_t)mlo);
	EQ32(name, PMM_OK, st);
	if (st != PMM_OK)
		return st;

	want_ram = ref_ram_pages(r, n);
	ref_build(r, n, mlo, mlo + total);
	want_free = ref_free_pages();

	check_bitmap(name);
	EQ64(name, want_ram, pmm_total_pages());
	EQ64(name, want_free, pmm_free_pages());
	EQ64(name, want_ram - want_free, pmm_used_pages());
	EQ32(name, n, pmm_region_count());

	for (i = 0; i < n; i++)
		lost += ref_lost(r[i].base, r[i].len);
	EQ64(name, lost, pmm_ignored_bytes());

	/* The table is display data, so it must be the loader's numbers and not
	 * the clipped ones the bitmap was built from. */
	for (i = 0; i < n; i++) {
		EQ64(name, r[i].base, pmm_region_base(i + 1));
		EQ64(name, r[i].len,  pmm_region_len(i + 1));
		EQ32(name, r[i].type, pmm_region_type(i + 1));
	}
	/* Out of range answers zero rather than reading past the array. */
	EQ64(name, 0, pmm_region_base(0));
	EQ64(name, 0, pmm_region_base(n + 1));

	/* roadmap 3.4's safety clause, from the module's own mouth. */
	EQ64(name, 0, pmm_verify_reserved());
	EQ64(name, 0, pmm_verify_kernel_locked());
	return st;
}

/* --- malformed input ----------------------------------------------------- */
/* Each of these must be REFUSED with its own status, and -- the property that
 * matters more -- must leave an allocator that hands out nothing.  A parser
 * that gives up halfway through a map has a bitmap describing a machine that
 * does not exist. */
static void expect_refusal(const char *what, int64_t mbi, int32_t want)
{
	int32_t st = pmm_init(mbi);

	EQ32(what, want, st);
	EQ64(what, 0, pmm_alloc_page());
	EQ64(what, 0, pmm_total_pages());
	EQ64(what, 0, pmm_free_pages());
	EQ32(what, 0, pmm_region_count());
}

static void test_malformed(void)
{
	struct region *big;
	uint64_t mlo = (uint64_t)(uintptr_t)mbi_mem;
	size_t total;
	int i;

	mbi_build(MAP_TINY, 2, 24, 1, 0);
	expect_refusal("mbi null", 0, E_MBI_NULL);

	mbi_build(MAP_TINY, 2, 24, 1, 0);
	expect_refusal("mbi misaligned", (int64_t)mlo + 4, E_MBI_ALIGN);

	/* Above the boot stub's identity window: the read would page-fault in
	 * the kernel, so it must never be attempted. */
	expect_refusal("mbi above the identity map", (int64_t)IDMAP_BYTES, E_MBI_RANGE);
	expect_refusal("mbi negative", (int64_t)-4096, E_MBI_RANGE);

	total = mbi_build(MAP_TINY, 2, 24, 1, 0);
	put32(0, 8);
	expect_refusal("total_size too small", (int64_t)mlo, E_MBI_SIZE);
	put32(0, (uint32_t)MBI_MAX + 8);
	expect_refusal("total_size implausible", (int64_t)mlo, E_MBI_SIZE);
	put32(0, (uint32_t)total);

	/* A zero-size tag is the one malformed input that turns the walk into an
	 * infinite loop rather than a wrong answer. */
	mbi_build(MAP_TINY, 2, 24, 1, 0);
	put32(12, 0);
	expect_refusal("tag with size 0", (int64_t)mlo, E_TAG_OVERRUN);

	mbi_build(MAP_TINY, 2, 24, 1, 0);
	put32(12, 0x7FFFFF);
	expect_refusal("tag runs past total_size", (int64_t)mlo, E_TAG_OVERRUN);

	mbi_build(MAP_TINY, 2, 24, 0, 0);
	expect_refusal("no memory-map tag", (int64_t)mlo, E_NO_MMAP);

	mbi_build(MAP_TINY, 2, 24, 1, 0);
	put32(16, 16);
	expect_refusal("entry_size below the spec minimum", (int64_t)mlo, E_ENTRY_SIZE);
	mbi_build(MAP_TINY, 2, 24, 1, 0);
	put32(16, 28);
	expect_refusal("entry_size not a multiple of 8", (int64_t)mlo, E_ENTRY_SIZE);

	/* More regions than the table holds.  FATAL, deliberately: truncating
	 * would leave a table that free() and verify_reserved consult as if it
	 * were the whole map. */
	big = calloc(MAX_REGIONS + 4, sizeof(*big));
	for (i = 0; i < MAX_REGIONS + 4; i++) {
		big[i].base = (uint64_t)(i + 1) * 0x100000ULL;
		big[i].len  = 0x1000;
		big[i].type = MB_AVAILABLE;
	}
	mbi_build(big, MAX_REGIONS + 4, 24, 1, 0);
	expect_refusal("more regions than the table holds", (int64_t)mlo, E_TOO_MANY);
	/* One fewer than the cap must still be accepted. */
	mbi_build(big, MAX_REGIONS, 24, 1, 0);
	EQ32("exactly MAX_REGIONS entries", PMM_OK, pmm_init((int64_t)mlo));
	EQ32("exactly MAX_REGIONS entries", MAX_REGIONS, pmm_region_count());
	free(big);

	{
		struct region none[] = {
			{ 0x100000, 0x100000, MB_RESERVED },
			{ 0x300000, 0x100000, MB_ACPI     },
		};
		mbi_build(none, 2, 24, 1, 0);
		expect_refusal("a map with no usable RAM at all", (int64_t)mlo, E_NO_RAM);
	}
}

/* --- allocation --------------------------------------------------------- */
static void test_alloc_free(void)
{
	uint64_t mlo = (uint64_t)(uintptr_t)mbi_mem;
	size_t total;
	int64_t first[5], again[5], a, before, n;
	int i;

	total = mbi_build(MAP_QEMU24, 8, 24, 1, 0);
	EQ32("alloc fixture", PMM_OK, pmm_init((int64_t)mlo));
	before = pmm_free_pages();

	for (i = 0; i < 5; i++) {
		first[i] = pmm_alloc_page();
		EQ64("alloc is page aligned", 0, first[i] & (int64_t)(PAGE_SIZE - 1));
		EQ32("alloc is not the OOM answer", 1, first[i] != 0);
		EQ32("alloc marks the frame used", 0, pmm_page_is_free(first[i]));
		if (i)
			EQ64("alloc runs contiguous",
			     first[i - 1] + (int64_t)PAGE_SIZE, first[i]);
	}
	EQ64("five allocations cost five frames", before - 5, pmm_free_pages());
	EQ64("used and free still add up", pmm_total_pages(),
	     pmm_free_pages() + pmm_used_pages());

	for (i = 0; i < 5; i++)
		EQ32("free accepts what alloc returned", PMM_OK, pmm_free_page(first[i]));
	EQ64("five frees give five frames back", before, pmm_free_pages());
	EQ32("a freed frame reads free", 1, pmm_page_is_free(first[0]));

	/* The same five addresses, in the same order.  A free that clears the
	 * bit but leaves the scan cursor above it passes every check but this. */
	for (i = 0; i < 5; i++) {
		again[i] = pmm_alloc_page();
		EQ64("reclaim returns the same frame", first[i], again[i]);
	}

	/* Every refusal free() knows how to make. */
	EQ32("double free: the first one works", PMM_OK, pmm_free_page(again[0]));
	EQ32("double free is refused", E_DOUBLE_FREE, pmm_free_page(again[0]));
	EQ32("unaligned free is refused", E_UNALIGNED, pmm_free_page(again[1] + 8));
	EQ32("free past the managed window", E_RANGE, pmm_free_page((int64_t)MAX_PHYS));
	EQ32("negative free", E_RANGE, pmm_free_page(-(int64_t)PAGE_SIZE));
	EQ32("free of the kernel image", E_LOCKED, pmm_free_page(g_kernel_lo));
	EQ32("free of the loader structure", E_LOCKED,
	     pmm_free_page((int64_t)(mlo & ~(PAGE_SIZE - 1))));
	/* 0xF0000 is inside a RESERVED region of MAP_QEMU24, so it is not RAM and
	 * freeing it would put an address the firmware owns into the pool. */
	EQ32("free of reserved memory", E_NOT_RAM, pmm_free_page(0xF0000));
	/* A hole no region describes at all. */
	EQ32("free of an address in no region", E_NOT_RAM, pmm_free_page(0xD0000000));
	/* And none of that moved the accounting. */
	EQ64("refused frees change nothing", before - 4, pmm_free_pages());

	for (i = 1; i < 5; i++)
		EQ32("tidy up", PMM_OK, pmm_free_page(again[i]));

	/* Drain.  The count must be exactly what init said was free, every
	 * address must be a frame the reference model also calls free, and the
	 * allocator must keep refusing afterwards rather than wrapping. */
	EQ32("drain fixture", PMM_OK, pmm_init((int64_t)mlo));
	ref_build(MAP_QEMU24, 8, mlo, mlo + total);
	before = pmm_free_pages();
	n = 0;
	{
		int bad_frame = 0, out_of_order = 0;
		int64_t prev = -1;
		/* BOUNDED, and that is not defensive padding.  An allocator that
		 * computes an address but forgets to set the bit hands out the
		 * same frame for ever: `while (alloc() != 0)` then spins at 100%
		 * with no output, which is not a test failure but a hung suite
		 * somebody has to debug.  It cost an afternoon to learn that
		 * here -- see HE in docs/HARNESS-VALIDATION-PHASE3.md -- and it
		 * is the same reason pmm_drain_to_oom in src/boot/fk_kmain.f90
		 * counts its iterations. */
		int64_t cap = before + 16;

		while (n < cap && (a = pmm_alloc_page()) != 0) {
			uint64_t page = (uint64_t)a >> 12;

			if (ref_used(page))
				bad_frame++;
			if (a <= prev)
				out_of_order++;
			prev = a;
			ref_set(page);
			n++;
		}
		EQ32("drain never hands out a used frame", 0, bad_frame);
		EQ32("drain hands out ascending addresses", 0, out_of_order);
		EQ32("drain terminated on its own", 1, n < cap);
	}
	EQ64("drain count equals the free count", before, n);
	EQ64("drained allocator reports zero free", 0, pmm_free_pages());
	EQ64("OOM is sticky", 0, pmm_alloc_page());
	EQ64("OOM is sticky", 0, pmm_alloc_page());

	/* Reserved memory survived the drain: this is roadmap 3.4's "the PMM must
	 * not touch ACPI or Reserved regions", asked after the allocator has taken
	 * everything it believes it may. */
	EQ64("nothing reserved was handed out", 0, pmm_verify_reserved());
	EQ64("the kernel survived the drain", 0, pmm_verify_kernel_locked());

	/* And one frame back is one frame out again. */
	EQ32("free after OOM", PMM_OK, pmm_free_page(first[0]));
	EQ64("alloc after OOM", first[0], pmm_alloc_page());
}

/* --- the assertions must be capable of failing --------------------------- */
/* pmm_verify_reserved and pmm_verify_kernel_locked return 0 on every good map
 * above, which on its own is equally consistent with their being stubs.  The
 * bitmap is bind(c), so a defect can be injected straight into it. */
static void test_verifiers_can_fail(void)
{
	uint64_t mlo = (uint64_t)(uintptr_t)mbi_mem;
	uint64_t page;

	mbi_build(MAP_QEMU24, 8, 24, 1, 0);
	EQ32("verifier fixture", PMM_OK, pmm_init((int64_t)mlo));
	EQ64("verifier fixture is clean", 0, pmm_verify_reserved());

	/* 0xF0000 is inside MAP_QEMU24's second reserved region. */
	page = 0xF0000 / PAGE_SIZE;
	fk_pmm_bitmap[page >> 6] &= ~(1LL << (page & 63));
	EQ64("a freed reserved frame is reported", 1, pmm_verify_reserved());
	fk_pmm_bitmap[page >> 6] |= 1LL << (page & 63);
	EQ64("and the report goes away again", 0, pmm_verify_reserved());

	page = (uint64_t)g_kernel_lo / PAGE_SIZE;
	fk_pmm_bitmap[page >> 6] &= ~(1LL << (page & 63));
	EQ64("a freed kernel frame is reported", 1, pmm_verify_kernel_locked());
	fk_pmm_bitmap[page >> 6] |= 1LL << (page & 63);

	page = ((uint64_t)mlo & ~(PAGE_SIZE - 1)) / PAGE_SIZE;
	fk_pmm_bitmap[page >> 6] &= ~(1LL << (page & 63));
	EQ64("a freed loader-map frame is reported", 1, pmm_verify_kernel_locked());
	fk_pmm_bitmap[page >> 6] |= 1LL << (page & 63);
	EQ64("clean again", 0, pmm_verify_kernel_locked());
}

/* --- state must not survive a re-init ------------------------------------ */
/* Module variables are process-global; the serial suite records the same trap.
 * A scenario that inherited the previous one's cursor or region table would
 * pass here and fail on the second boot of a machine that resized its RAM. */
static void test_reinit(void)
{
	uint64_t mlo = (uint64_t)(uintptr_t)mbi_mem;
	size_t total;
	int i;

	mbi_build(MAP_QEMU24, 8, 24, 1, 0);
	EQ32("reinit: first map", PMM_OK, pmm_init((int64_t)mlo));
	for (i = 0; i < 1000; i++)
		pmm_alloc_page();

	total = mbi_build(MAP_TINY, 2, 24, 1, 0);
	EQ32("reinit: second map", PMM_OK, pmm_init((int64_t)mlo));
	ref_build(MAP_TINY, 2, mlo, mlo + total);
	check_bitmap("reinit leaves no trace of the previous map");
	EQ32("reinit resets the region table", 2, pmm_region_count());
	EQ64("reinit resets the cursor", PAGE_SIZE, pmm_alloc_page());
}

int main(void)
{
	mbi_map();
	ref = malloc(NWORDS * 8);
	if (!ref) {
		printf("  FATAL: cannot allocate the reference bitmap\n");
		return 2;
	}

	/* A kernel image where linker.ld puts one: 1 MiB, a couple of hundred
	 * KiB long, ending mid-frame so the outward rounding is exercised. */
	g_kernel_lo = 0x100000;
	g_kernel_hi = 0x312800;

	scenario("qemu -m 24G", MAP_QEMU24, 8, 24, 0);
	scenario("qemu -m 24G, tag padding", MAP_QEMU24, 8, 24, 1);
	scenario("qemu -m 24G, entry_size 32", MAP_QEMU24, 8, 32, 1);
	scenario("awkward edges", MAP_AWKWARD, 12, 24, 0);
	scenario("awkward edges, entry_size 40", MAP_AWKWARD, 12, 40, 1);
	scenario("tiny map", MAP_TINY, 2, 24, 0);

	/* The kernel somewhere other than 1 MiB: the marking must follow the
	 * linker's symbols and not a constant that happens to match them. */
	g_kernel_lo = 0x00220000;
	g_kernel_hi = 0x00241000;
	scenario("kernel image moved", MAP_QEMU24, 8, 24, 0);
	g_kernel_lo = 0x100000;
	g_kernel_hi = 0x312800;

	test_malformed();
	test_alloc_free();
	test_verifiers_can_fail();
	test_reinit();

	free(ref);
	return fk_report("pmm");
}
