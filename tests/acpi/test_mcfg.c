/* Reference-model test for src/acpi/fk_mcfg.f90.
 *
 * There is no C original to diff against -- the MCFG decoder is a translation
 * of the PCI Firmware Specification 3.0 section 4.1.2 -- so this file carries
 * its own model: tables are described entry by entry, laid into a poisoned
 * arena, and every accessor is compared against what was laid down.
 *
 * THE ARENA IS POISONED AND THE TABLE BASE IS DELIBERATELY UNALIGNED.  On this
 * project's BIOS path the RSDT sits at 0x7FFE2525, so nothing it points at is
 * even 4-byte aligned; every table here is therefore parsed at all eight byte
 * offsets and must give bit-identical answers.  Anything outside the table
 * stays 0xA5, so a read that strays returns poison rather than plausible data.
 *
 * AND ONE TABLE IS PLACED AGAINST A PROT_NONE PAGE, ending exactly at the
 * boundary: there a read one byte past the declared length is a SIGSEGV, not a
 * silent wrong answer.
 */
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include "fk_test.h"

int32_t mcfg_parse(int64_t virt, int32_t len);
int32_t mcfg_count(void);
int64_t mcfg_base(int32_t i);
int32_t mcfg_segment(int32_t i);
int32_t mcfg_bus_start(int32_t i);
int32_t mcfg_bus_end(int32_t i);
int64_t mcfg_bytes(int32_t i);

#define EQ64(what, a, b) \
	FK_EQ(what, (unsigned long long)(a), (unsigned long long)(b), "0x%llX")
#define EQ32(what, a, b) FK_EQ(what, (unsigned)(a), (unsigned)(b), "0x%X")
#define EQI(what, a, b)  FK_EQ(what, (int)(a), (int)(b), "%d")

enum {
	MCFG_OK = 0, E_NULL = 1, E_LEN = 2, E_SIG = 3, E_CHECKSUM = 4,
	E_TRUNC = 5, E_TOO_MANY = 6, E_BUS_RANGE = 7, E_NO_ALLOC = 8,
	MAX_ALLOC = 8, MIN_LEN = 44, ENTRY_LEN = 16, OFF_ALLOC = 44
};

struct alloc {
	uint64_t base;
	uint16_t seg;
	uint8_t lo, hi;
};

#define ARENA 4096
static uint8_t arena[ARENA];

/* Build a whole MCFG table at ARENA+off and return its length.  The checksum
 * is computed last, over everything, so every other field being wrong still
 * produces a table firmware would have accepted. */
static int build(int off, const struct alloc *a, int n, int fudge_len)
{
	uint8_t *t = arena + off;
	int len = OFF_ALLOC + n * ENTRY_LEN;
	int i, sum = 0;

	memset(arena, 0xA5, sizeof arena);
	memset(t, 0, (size_t)len);
	memcpy(t, "MCFG", 4);
	t[4] = (uint8_t)(len & 0xFF);
	t[5] = (uint8_t)((len >> 8) & 0xFF);
	t[6] = (uint8_t)((len >> 16) & 0xFF);
	t[7] = (uint8_t)((len >> 24) & 0xFF);
	t[8] = 1;                       /* revision */
	memcpy(t + 10, "FKTEST", 6);    /* OEM id */
	/* Bytes 36..43 are RESERVED and stay zero here; a decoder that starts
	 * the allocation array at 36 reads its base address out of them. */
	for (i = 0; i < n; i++) {
		uint8_t *e = t + OFF_ALLOC + i * ENTRY_LEN;
		int b;

		for (b = 0; b < 8; b++)
			e[b] = (uint8_t)((a[i].base >> (8 * b)) & 0xFF);
		e[8] = (uint8_t)(a[i].seg & 0xFF);
		e[9] = (uint8_t)((a[i].seg >> 8) & 0xFF);
		e[10] = a[i].lo;
		e[11] = a[i].hi;
	}
	if (fudge_len) {
		int fl = len + fudge_len;

		t[4] = (uint8_t)(fl & 0xFF);
		t[5] = (uint8_t)((fl >> 8) & 0xFF);
		t[6] = (uint8_t)((fl >> 16) & 0xFF);
		t[7] = (uint8_t)((fl >> 24) & 0xFF);
	}
	for (i = 0; i < len; i++)
		sum += t[i];
	t[9] = (uint8_t)((-sum) & 0xFF);
	return len;
}

/* The window QEMU's q35 machine declares, which is what the boot gate meets. */
static const struct alloc Q35 = { 0xB0000000ULL, 0, 0, 255 };

static void test_good(void)
{
	int off, len;

	/* Every byte offset, because nothing an ACPI table points at is
	 * aligned and the answers must not depend on where it landed. */
	for (off = 0; off < 8; off++) {
		len = build(off, &Q35, 1, 0);
		EQ32("q35 table parses", MCFG_OK,
		     mcfg_parse((int64_t)(uintptr_t)(arena + off), len));
		EQI("one allocation", 1, mcfg_count());
		EQ64("the ECAM base", 0xB0000000ULL, mcfg_base(0));
		EQ32("segment group 0", 0, mcfg_segment(0));
		EQ32("first bus", 0, mcfg_bus_start(0));
		EQ32("last bus", 255, mcfg_bus_end(0));
		EQ64("the window is 256 MiB", 0x10000000ULL, mcfg_bytes(0));
	}

	/* THE 64-BIT BASE, READ WHOLE.  A decoder that takes a u32 answers 0
	 * for this and looks perfectly healthy on QEMU for ever. */
	{
		struct alloc high = { 0x0000000180000000ULL, 0, 0, 15 };

		len = build(3, &high, 1, 0);
		EQ32("a base above 4 GiB parses", MCFG_OK,
		     mcfg_parse((int64_t)(uintptr_t)(arena + 3), len));
		EQ64("and comes back whole", 0x180000000ULL, mcfg_base(0));
		EQ64("sixteen buses is 16 MiB", 0x1000000ULL, mcfg_bytes(0));
	}
	/* And one with bit 31 set in the LOW half, which is where a
	 * sign-extended intermediate would put an address 4 GiB away. */
	{
		struct alloc signbit = { 0x00000000F0000000ULL, 0, 0, 0 };

		len = build(5, &signbit, 1, 0);
		EQ32("a base with bit 31 set parses", MCFG_OK,
		     mcfg_parse((int64_t)(uintptr_t)(arena + 5), len));
		EQ64("and is not sign-extended", 0xF0000000ULL, mcfg_base(0));
		EQ64("one bus is 1 MiB", 0x100000ULL, mcfg_bytes(0));
	}

	/* Two segment groups, each with its own window and bus range. */
	{
		struct alloc two[2] = {
			{ 0xB0000000ULL, 0, 0, 127 },
			{ 0xC0000000ULL, 1, 128, 255 },
		};

		len = build(1, two, 2, 0);
		EQ32("a two-entry table parses", MCFG_OK,
		     mcfg_parse((int64_t)(uintptr_t)(arena + 1), len));
		EQI("two allocations", 2, mcfg_count());
		EQ64("entry 0 base", 0xB0000000ULL, mcfg_base(0));
		EQ64("entry 1 base", 0xC0000000ULL, mcfg_base(1));
		EQ32("entry 1 segment", 1, mcfg_segment(1));
		EQ32("entry 1 first bus", 128, mcfg_bus_start(1));
		EQ64("entry 0 is 128 MiB", 0x8000000ULL, mcfg_bytes(0));
	}

	/* Out-of-range indices answer zero rather than reading past the array. */
	len = build(0, &Q35, 1, 0);
	EQ32("refresh", MCFG_OK, mcfg_parse((int64_t)(uintptr_t)arena, len));
	EQ64("index 1 of a one-entry table", 0, mcfg_base(1));
	EQ64("index -1", 0, mcfg_base(-1));
	EQ32("segment of index 1", 0, mcfg_segment(1));
	EQ64("bytes of index 1", 0, mcfg_bytes(1));
}

static void expect_refusal(const char *what, int off, int len, int want)
{
	FK_EQ(what, (unsigned)want,
	      (unsigned)mcfg_parse((int64_t)(uintptr_t)(arena + off), len),
	      "%u");
	/* A refused table must leave NOTHING behind: a caller that ignores the
	 * status has to read zeros and not the last table that parsed. */
	EQI("a refused table leaves no count", 0, mcfg_count());
}

static void test_malformed(void)
{
	int len;

	EQ32("a null pointer is refused", E_NULL, mcfg_parse(0, 64));

	len = build(0, &Q35, 1, 0);
	expect_refusal("a length below the minimum", 0, MIN_LEN - 1, E_LEN);
	expect_refusal("a negative length", 0, -1, E_LEN);
	expect_refusal("an absurd length", 0, 1 << 20, E_LEN);

	len = build(0, &Q35, 1, 0);
	arena[0] = 'X';
	expect_refusal("a wrong signature", 0, len, E_SIG);

	len = build(0, &Q35, 1, 0);
	arena[9] ^= 0xFF;
	expect_refusal("a bad checksum", 0, len, E_CHECKSUM);

	/* The header claims more bytes than the caller mapped. */
	len = build(0, &Q35, 1, 16);
	expect_refusal("a header longer than the mapping", 0, len, E_TRUNC);

	/* A header length that leaves no room for an allocation entry.  The
	 * checksum has to be recomputed over the SHORTER table: a length that
	 * moved and a checksum that did not is a checksum failure, and would
	 * have this case passing for the wrong reason. */
	{
		uint8_t *t = arena;
		int i, sum = 0;

		len = build(0, &Q35, 1, 0);
		t[4] = MIN_LEN;
		t[5] = t[6] = t[7] = 0;
		t[9] = 0;
		for (i = 0; i < MIN_LEN; i++)
			sum += t[i];
		t[9] = (uint8_t)((-sum) & 0xFF);
		expect_refusal("a table declaring no allocations", 0, len,
			       E_NO_ALLOC);
	}

	/* More entries than the module will hold. */
	{
		struct alloc many[MAX_ALLOC + 1];
		int i;

		for (i = 0; i <= MAX_ALLOC; i++) {
			many[i].base = 0xB0000000ULL + (uint64_t)i * 0x10000000ULL;
			many[i].seg = (uint16_t)i;
			many[i].lo = 0;
			many[i].hi = 15;
		}
		len = build(0, many, MAX_ALLOC + 1, 0);
		expect_refusal("more allocations than the module holds", 0, len,
			       E_TOO_MANY);
		/* And exactly MAX_ALLOC is accepted -- the boundary in the
		 * other direction, so the refusal above is a limit and not an
		 * off-by-one. */
		len = build(0, many, MAX_ALLOC, 0);
		EQ32("exactly the maximum is accepted", MCFG_OK,
		     mcfg_parse((int64_t)(uintptr_t)arena, len));
		EQI("and all of them are kept", MAX_ALLOC, mcfg_count());
	}

	/* A bus range that runs backwards. */
	{
		struct alloc back = { 0xB0000000ULL, 0, 200, 100 };

		len = build(0, &back, 1, 0);
		expect_refusal("a bus range that ends before it starts", 0, len,
			       E_BUS_RANGE);
	}
}

/* A table ending exactly at a PROT_NONE page: a read one byte past its
 * declared length is a SIGSEGV rather than a silent wrong answer. */
static void test_guarded(void)
{
	long ps = sysconf(_SC_PAGESIZE);
	uint8_t *map, *t;
	int len = OFF_ALLOC + ENTRY_LEN, i, sum = 0;

	map = mmap(NULL, (size_t)ps * 2, PROT_READ | PROT_WRITE,
		   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (map == MAP_FAILED)
		return;
	if (mprotect(map + ps, (size_t)ps, PROT_NONE) != 0) {
		munmap(map, (size_t)ps * 2);
		return;
	}
	t = map + ps - len;
	memset(t, 0, (size_t)len);
	memcpy(t, "MCFG", 4);
	t[4] = (uint8_t)len;
	t[8] = 1;
	for (i = 0; i < 8; i++)
		t[OFF_ALLOC + i] = (uint8_t)((0xB0000000ULL >> (8 * i)) & 0xFF);
	t[OFF_ALLOC + 11] = 255;
	for (i = 0; i < len; i++)
		sum += t[i];
	t[9] = (uint8_t)((-sum) & 0xFF);

	EQ32("a table against a guard page parses", MCFG_OK,
	     mcfg_parse((int64_t)(uintptr_t)t, len));
	EQ64("and reads its base without straying", 0xB0000000ULL, mcfg_base(0));
	EQ32("and its last bus", 255, mcfg_bus_end(0));
	munmap(map, (size_t)ps * 2);
}

int main(void)
{
	test_good();
	test_malformed();
	test_guarded();
	return fk_report("mcfg");
}
