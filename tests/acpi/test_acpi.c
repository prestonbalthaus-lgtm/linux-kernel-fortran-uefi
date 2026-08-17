/* Reference-model test for src/acpi/fk_acpi.f90.
 *
 * There is no C oracle (mk/acpi.mk says why), so the model is here: the whole
 * table tree -- MBI, RSDP, root table, stub tables -- is laid into a guarded
 * arena of ordinary memory, and acpi_set_window/acpi_set_limit tell the parser
 * that the arena IS physical memory at a chosen fake base.  The module maps
 * nothing, so nothing has to be mapped for this to run.
 *
 * THE HEADLINE CASE IS THE UNALIGNED ROOT.  QEMU's BIOS path reports the RSDT
 * at physical 0x7FFE2525 -- offset 5 mod 8 -- so its 32-bit table pointers are
 * unaligned too, and the XSDT's 64-bit entries land at offset 1 mod 8.  Both
 * roots below sit at exactly that offset, and section (2b) proves the trap has
 * teeth: a word-indexed read of the first pointer returns something else.
 *
 * Two fake bases are used.  0x7FFE0000 reproduces the measured BIOS address
 * exactly; 0xFFF00000 puts bit 31 in every physical address, so a field
 * assembled without a per-byte mask sign-extends and the address stops being
 * reachable.  A checksum cannot catch that -- sum mod 256 is identical for
 * signed and unsigned bytes -- which is why the fixtures, not the checksums,
 * carry the bytes >= 0x80.
 *
 * The arena is poisoned outside what a fixture wrote, and guard bands either
 * side catch a write where only reads belong.
 */
#include <stdint.h>
#include <string.h>
#include <stddef.h>
#include "fk_test.h"

#define EQ64(what, a, b) \
	FK_EQ(what, (unsigned long long)(a), (unsigned long long)(b), "0x%llX")
#define EQ32(what, a, b) \
	FK_EQ(what, (unsigned)(a), (unsigned)(b), "0x%X")
#define EQI(what, a, b)  FK_EQ(what, (int)(a), (int)(b), "%d")

/* --- the Fortran module's bind(c) surface -------------------------------- */
void    acpi_set_window(int64_t offset);
void    acpi_set_limit(int64_t top);
int32_t acpi_init(int64_t mbi_virt, int64_t mbi_len);
int32_t acpi_root_kind(void);
int64_t acpi_root_phys(void);
int32_t acpi_revision(void);
int64_t acpi_rsdp_phys(void);
int32_t acpi_table_count(void);
int64_t acpi_table_phys(int32_t i);
int32_t acpi_table_sig(int32_t i);
int64_t acpi_find(int32_t sig_packed);
int64_t acpi_table_length(int64_t phys);
int32_t acpi_checksum_ok(int64_t phys, int64_t len);

/* --- constants, mirroring src/acpi/fk_acpi.f90 --------------------------- */
enum {
	ACPI_OK = 0, E_MBI = 1, E_NO_TAG = 2, E_RSDP_SIG = 3, E_RSDP_SUM = 4,
	E_RSDP_LEN = 5, E_RSDP_EXT_SUM = 6, E_ROOT_RANGE = 7, E_ROOT_SIG = 8,
	E_ROOT_SUM = 9, E_ROOT_LEN = 10, E_TOO_MANY = 11,
};
enum { ROOT_NONE = 0, ROOT_RSDT = 1, ROOT_XSDT = 2 };

#define MAX_TABLES	64
#define ROOT_LEN_MAX	4096
#define RSDP_LEN_MAX	256
#define MBI_MAX		1048576
#define HDR		36

/* Signatures are compared as bytes and reported packed little-endian. */
static uint32_t sig4(const char *s)
{
	return (uint32_t)(uint8_t)s[0] | ((uint32_t)(uint8_t)s[1] << 8) |
	       ((uint32_t)(uint8_t)s[2] << 16) | ((uint32_t)(uint8_t)s[3] << 24);
}

/* --- the guarded arena --------------------------------------------------- */
#define POISON		0xA5
#define GUARD		256
#define ARENA_CAP	0x40000
static uint8_t arena_mem[GUARD + ARENA_CAP + GUARD] __attribute__((aligned(4096)));
#define ARENA		(arena_mem + GUARD)

#define MBI_CAP		4096
static uint8_t mbi_mem[GUARD + MBI_CAP + GUARD] __attribute__((aligned(4096)));
#define MBI		(mbi_mem + GUARD)
static uint32_t mbi_len;

/* The fake physical base the arena stands at, and the window that follows. */
static uint64_t phys_base;

static void world(uint64_t base)
{
	phys_base = base;
	acpi_set_window((int64_t)(uintptr_t)ARENA - (int64_t)base);
	acpi_set_limit((int64_t)(base + ARENA_CAP));
}

static uint64_t P(size_t off)	 { return phys_base + off; }
static uint8_t *AT(uint64_t phys) { return ARENA + (size_t)(phys - phys_base); }

static void put32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static void put64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }
static uint32_t get32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }

static uint8_t sum8(const uint8_t *p, size_t n)
{
	uint8_t s = 0;

	while (n--)
		s = (uint8_t)(s + *p++);
	return s;
}

static void arena_reset(void) { memset(arena_mem, POISON, sizeof arena_mem); }

static void guard_check(const char *what)
{
	size_t i;
	int bad = 0;

	for (i = 0; i < GUARD; i++)
		if (arena_mem[i] != POISON ||
		    arena_mem[GUARD + ARENA_CAP + i] != POISON ||
		    mbi_mem[i] != POISON ||
		    mbi_mem[GUARD + MBI_CAP + i] != POISON)
			bad = 1;
	fk_checks++;
	if (bad) {
		printf("  GUARD %s: a guard band was modified\n", what);
		fk_fails++;
	}
}

/* --- the Multiboot2 information structure -------------------------------- */
struct tag {
	uint32_t type;
	uint32_t paylen;
	const uint8_t *pay;
};

#define MAX_TAGS 8
static size_t tag_off[MAX_TAGS];	/* where mbi_build put each tag */

static void mbi_build(const struct tag *t, int n)
{
	size_t o = 8;
	int i;

	memset(mbi_mem, POISON, sizeof mbi_mem);
	for (i = 0; i < n; i++) {
		tag_off[i] = o;
		put32(MBI + o, t[i].type);
		put32(MBI + o + 4, 8 + t[i].paylen);
		if (t[i].paylen)
			memcpy(MBI + o + 8, t[i].pay, t[i].paylen);
		o += (8 + t[i].paylen + 7) & ~(size_t)7;
	}
	put32(MBI + o, 0);		/* the end tag */
	put32(MBI + o + 4, 8);
	o += 8;
	put32(MBI + 0, (uint32_t)o);	/* total_size */
	put32(MBI + 4, 0);		/* reserved */
	mbi_len = (uint32_t)o;
}

/* --- the RSDP ------------------------------------------------------------
 * decl_len is what goes in the length field; sum_len is what the extended
 * checksum is made to balance over.  They differ only in the fixtures that
 * exist to prove length is checked BEFORE that many bytes are read. */
static void rsdp_write(uint8_t *p, int v2, uint8_t rev, uint32_t rsdt,
		       uint64_t xsdt, uint32_t decl_len, uint32_t sum_len)
{
	memcpy(p, "RSD PTR ", 8);
	p[8] = 0;
	memcpy(p + 9, "FKTEST", 6);
	p[15] = rev;
	put32(p + 16, rsdt);
	if (v2) {
		put32(p + 20, decl_len);
		put64(p + 24, xsdt);
		p[32] = 0;
		p[33] = p[34] = p[35] = 0;
	}
	p[8] = (uint8_t)-sum8(p, 20);
	if (v2)
		p[32] = (uint8_t)-sum8(p, sum_len);
}

static uint8_t rsdp_v1[20];
static uint8_t rsdp_v2[36];

/* --- ACPI tables ---------------------------------------------------------- */
static void hdr_write(uint8_t *p, const char *sig, uint32_t decl_len)
{
	memcpy(p, sig, 4);
	put32(p + 4, decl_len);
	p[8] = 1;			/* revision */
	p[9] = 0;			/* checksum, filled by the caller */
	memcpy(p + 10, "FKOEM ", 6);
	memcpy(p + 16, "FKTABLE ", 8);
	put32(p + 24, 1);
	put32(p + 28, sig4("FKCC"));
	put32(p + 32, 1);
}

/* A stub table: a real 36-byte header, a body, and a checksum that balances. */
static void table_write(uint64_t phys, const char *sig, uint32_t len)
{
	uint8_t *p = AT(phys);
	uint32_t i;

	hdr_write(p, sig, len);
	for (i = HDR; i < len; i++)
		p[i] = (uint8_t)(0x80 + i);	/* bodies carry bytes >= 0x80 */
	p[9] = (uint8_t)-sum8(p, len);
}

/* A root table.  decl_len is written into the header; the bytes actually laid
 * down are always 36 + n*psize, and the checksum balances over those. */
static void root_write(uint64_t phys, const char *sig, const uint64_t *ptrs,
		       int n, int psize, uint32_t decl_len)
{
	uint8_t *p = AT(phys);
	uint32_t real = (uint32_t)(HDR + (size_t)n * psize);
	int i;

	hdr_write(p, sig, decl_len);
	for (i = 0; i < n; i++) {
		if (psize == 4)
			put32(p + HDR + 4 * i, (uint32_t)ptrs[i]);
		else
			put64(p + HDR + 8 * i, ptrs[i]);
	}
	p[9] = (uint8_t)-sum8(p, real);	/* over what was laid down */
}

/* --- the two shapes ------------------------------------------------------ */
/* Measured on QEMU q35: the RSDT sits at 0x7FFE2525 and lists five tables. */
#define OFF_ROOT	0x2525		/* 5 mod 8 -- the whole point */
#define OFF_RSDT2	0x1000		/* the RSDT tag 15 must NOT pick */

static const char * const bios_sig[] = { "FACP", "APIC", "HPET", "MCFG", "WAET" };
static const size_t bios_off[]  = { 0x3001, 0x4000, 0x5003, 0x6006, 0x7002 };
static const uint32_t bios_len[] = { 244, 160, 56, 60, 40 };
#define BIOS_N ((int)(sizeof bios_off / sizeof bios_off[0]))

/* UEFI adds BGRT.  "APIB" is not firmware's: it is a near miss that differs
 * from "APIC" in the last byte only, so a three-byte compare would find it. */
static const char * const uefi_sig[] = { "FACP", "APIC", "HPET", "MCFG",
					 "WAET", "BGRT", "APIB" };
static const size_t uefi_off[]  = { 0x3001, 0x4000, 0x5003, 0x6006,
				    0x7002, 0x8004, 0x9007 };
static const uint32_t uefi_len[] = { 244, 160, 56, 60, 40, 56, 40 };
#define UEFI_N ((int)(sizeof uefi_off / sizeof uefi_off[0]))

/* Pointers the root lists that are NOT in the window: recorded exactly,
 * dereferenced never.  Each carries a byte >= 0x80 in a different position. */
static const uint64_t far_ptr[] = {
	0x00000000FFFFFF80ULL, 0x000000FF00000000ULL, 0xFFFFFFFFFFFFFFFFULL,
};
#define FAR_N ((int)(sizeof far_ptr / sizeof far_ptr[0]))

static uint64_t bios_ptr[BIOS_N];
static uint64_t uefi_ptr[UEFI_N + FAR_N];

/* Lay down the BIOS tree: five stub tables and an RSDT naming them. */
static void bios_tree(uint64_t base)
{
	int i;

	arena_reset();
	world(base);
	for (i = 0; i < BIOS_N; i++) {
		bios_ptr[i] = P(bios_off[i]);
		table_write(bios_ptr[i], bios_sig[i], bios_len[i]);
	}
	root_write(P(OFF_ROOT), "RSDT", bios_ptr, BIOS_N, 4,
		   (uint32_t)(HDR + 4 * BIOS_N));
}

static void uefi_tree(uint64_t base)
{
	int i;

	arena_reset();
	world(base);
	for (i = 0; i < UEFI_N; i++) {
		uefi_ptr[i] = P(uefi_off[i]);
		table_write(uefi_ptr[i], uefi_sig[i], uefi_len[i]);
	}
	for (i = 0; i < FAR_N; i++)
		uefi_ptr[UEFI_N + i] = far_ptr[i];
	root_write(P(OFF_ROOT), "XSDT", uefi_ptr, UEFI_N + FAR_N, 8,
		   (uint32_t)(HDR + 8 * (UEFI_N + FAR_N)));
	/* tag 14's RSDT, naming two tables, so "tag 15 won" is observable. */
	root_write(P(OFF_RSDT2), "RSDT", uefi_ptr, 2, 4, HDR + 8);
}

static void mbi_bios(uint64_t rsdt_phys)
{
	struct tag t[1];

	rsdp_write(rsdp_v1, 0, 0, (uint32_t)rsdt_phys, 0, 0, 0);
	t[0].type = 14; t[0].paylen = 20; t[0].pay = rsdp_v1;
	mbi_build(t, 1);
}

static void mbi_uefi(uint64_t rsdt_phys, uint64_t xsdt_phys)
{
	struct tag t[2];

	rsdp_write(rsdp_v1, 0, 0, (uint32_t)rsdt_phys, 0, 0, 0);
	rsdp_write(rsdp_v2, 1, 2, (uint32_t)rsdt_phys, xsdt_phys, 36, 36);
	t[0].type = 14; t[0].paylen = 20; t[0].pay = rsdp_v1;
	t[1].type = 15; t[1].paylen = 36; t[1].pay = rsdp_v2;
	mbi_build(t, 2);
}

static int32_t init_now(void)
{
	return acpi_init((int64_t)(uintptr_t)MBI, (int64_t)mbi_len);
}

/* Every rejection must also CLEAR whatever a previous good parse latched. */
static void expect_fail(const char *what, int32_t want)
{
	static char tag[192];

	snprintf(tag, sizeof tag, "%s: status", what);
	EQI(tag, want, init_now());
	snprintf(tag, sizeof tag, "%s: count cleared", what);
	EQI(tag, 0, acpi_table_count());
	snprintf(tag, sizeof tag, "%s: kind cleared", what);
	EQI(tag, ROOT_NONE, acpi_root_kind());
	snprintf(tag, sizeof tag, "%s: root cleared", what);
	EQ64(tag, 0, (uint64_t)acpi_root_phys());
	snprintf(tag, sizeof tag, "%s: revision cleared", what);
	EQI(tag, 0, acpi_revision());
	snprintf(tag, sizeof tag, "%s: find answers absent", what);
	EQ64(tag, 0, (uint64_t)acpi_find(sig4("APIC")));
	snprintf(tag, sizeof tag, "%s: index 0 answers absent", what);
	EQ64(tag, 0, (uint64_t)acpi_table_phys(0));
}

/* A good BIOS parse, asserted, so the refusal that follows has something to
 * clear.  Returns with the tree and the MBI freshly built. */
static void good_bios(uint64_t base)
{
	bios_tree(base);
	mbi_bios(P(OFF_ROOT));
	EQI("relatch: BIOS parse succeeds", ACPI_OK, init_now());
	EQI("relatch: five tables", BIOS_N, acpi_table_count());
}

static void check_oob_index(const char *what, int32_t i)
{
	static char tag[192];

	snprintf(tag, sizeof tag, "%s: table_phys(%d)", what, i);
	EQ64(tag, 0, (uint64_t)acpi_table_phys(i));
	snprintf(tag, sizeof tag, "%s: table_sig(%d)", what, i);
	EQ32(tag, 0, (uint32_t)acpi_table_sig(i));
}

static void oob_sweep(const char *what, int32_t n)
{
	check_oob_index(what, -1);
	check_oob_index(what, -2);
	check_oob_index(what, n);
	check_oob_index(what, n + 1);
	check_oob_index(what, 1000);
	check_oob_index(what, INT32_MAX);
	check_oob_index(what, INT32_MIN);
}

int main(void)
{
	static uint64_t many[MAX_TABLES + 1];
	static char tag[192];
	int i;

	/* (1) Nothing parsed yet, and no window set either: every accessor
	 * answers its sentinel rather than dereferencing anything. */
	EQI("cold: kind", ROOT_NONE, acpi_root_kind());
	EQ64("cold: root", 0, (uint64_t)acpi_root_phys());
	EQI("cold: revision", 0, acpi_revision());
	EQ64("cold: rsdp", 0, (uint64_t)acpi_rsdp_phys());
	EQI("cold: count", 0, acpi_table_count());
	EQ64("cold: find", 0, (uint64_t)acpi_find(sig4("APIC")));
	EQ64("cold: table_length", 0, (uint64_t)acpi_table_length(0x7FFE2525));
	EQI("cold: checksum_ok", 0, acpi_checksum_ok(0x7FFE2525, 56));
	oob_sweep("cold", 0);

	/* (2) The BIOS shape at the measured address: tag 14 only, an RSDT at
	 * physical 0x7FFE2525, five tables. */
	bios_tree(0x7FFE0000ULL);
	mbi_bios(P(OFF_ROOT));
	EQI("bios: status", ACPI_OK, init_now());
	EQI("bios: root kind is RSDT", ROOT_RSDT, acpi_root_kind());
	EQ64("bios: root is the measured 0x7FFE2525", 0x7FFE2525ULL,
	     (uint64_t)acpi_root_phys());
	EQI("bios: the root is UNALIGNED, 5 mod 8", 5,
	    (int)(acpi_root_phys() & 7));
	EQI("bios: revision 0", 0, acpi_revision());
	EQ64("bios: the RSDP came from a tag copy", 0,
	     (uint64_t)acpi_rsdp_phys());
	EQI("bios: five tables", BIOS_N, acpi_table_count());
	for (i = 0; i < BIOS_N; i++) {
		snprintf(tag, sizeof tag, "bios[%d]: phys", i);
		EQ64(tag, bios_ptr[i], (uint64_t)acpi_table_phys(i));
		snprintf(tag, sizeof tag, "bios[%d]: sig", i);
		EQ32(tag, sig4(bios_sig[i]), (uint32_t)acpi_table_sig(i));
		snprintf(tag, sizeof tag, "bios[%d]: length", i);
		EQ64(tag, bios_len[i], (uint64_t)acpi_table_length(bios_ptr[i]));
		snprintf(tag, sizeof tag, "bios[%d]: checksum", i);
		EQI(tag, 1, acpi_checksum_ok(bios_ptr[i], bios_len[i]));
		snprintf(tag, sizeof tag, "bios[%d]: find", i);
		EQ64(tag, bios_ptr[i], (uint64_t)acpi_find(sig4(bios_sig[i])));
	}
	EQ64("bios: find misses SSDT", 0, (uint64_t)acpi_find(sig4("SSDT")));
	EQ64("bios: find misses BGRT", 0, (uint64_t)acpi_find(sig4("BGRT")));
	EQ64("bios: find misses the root's own signature", 0,
	     (uint64_t)acpi_find(sig4("RSDT")));
	oob_sweep("bios", BIOS_N);
	guard_check("bios");

	/* (2b) THE TRAP IS ARMED.  The first pointer lies at 0x2549, so a
	 * parser that indexed 32-bit words -- off/4, the shape a typed array
	 * bakes in -- would read from 0x2548 and get something else.  A test
	 * that passed because the fixture was aligned would prove nothing. */
	{
		size_t p0 = OFF_ROOT + HDR;
		uint32_t word_indexed = get32(ARENA + (p0 & ~(size_t)3));

		EQI("trap armed: the pointer array is unaligned", 1,
		    (int)(p0 & 7));
		EQI("trap armed: a word-indexed read differs", 1,
		    word_indexed != (uint32_t)bios_ptr[0]);
		EQ64("trap armed: the measured RSDT length, 56", 56,
		     (uint64_t)acpi_table_length(P(OFF_ROOT)));
	}

	/* (2c) A byte of every stub table's body is >= 0x80, and the sum-mod-256
	 * checksum passes over them either way -- which is why the checksum is
	 * not evidence about field assembly. */
	{
		uint8_t *p = AT(bios_ptr[0]);

		EQI("checksum: a body byte is >= 0x80", 1, p[HDR] >= 0x80);
		p[HDR] = (uint8_t)(p[HDR] + 1);
		EQI("checksum: one flipped byte is caught", 0,
		    acpi_checksum_ok(bios_ptr[0], bios_len[0]));
		p[HDR] = (uint8_t)(p[HDR] - 1);
		EQI("checksum: restored", 1,
		    acpi_checksum_ok(bios_ptr[0], bios_len[0]));
		EQI("checksum: a short region does not balance", 0,
		    acpi_checksum_ok(bios_ptr[0], bios_len[0] - 1));
		EQI("checksum: length 0 is refused", 0,
		    acpi_checksum_ok(bios_ptr[0], 0));
		EQI("checksum: a length past the top is refused", 0,
		    acpi_checksum_ok(bios_ptr[0], ARENA_CAP));
		EQI("checksum: an all-ones length is refused", 0,
		    acpi_checksum_ok(bios_ptr[0], (int64_t)0xFFFFFFFFFFFFFFFFULL));
		EQI("checksum: a bit-63 length is refused", 0,
		    acpi_checksum_ok(bios_ptr[0], (int64_t)0x8000000000000000ULL));
		EQI("checksum: phys 0 is refused", 0, acpi_checksum_ok(0, 36));
		EQI("checksum: phys past the top is refused", 0,
		    acpi_checksum_ok((int64_t)(phys_base + ARENA_CAP), 36));
		EQ64("length: phys past the top is refused", 0,
		     (uint64_t)acpi_table_length((int64_t)(phys_base + ARENA_CAP)));
		EQ64("length: phys 0 is refused", 0,
		     (uint64_t)acpi_table_length(0));
		EQ64("length: a header crossing the top is refused", 0,
		     (uint64_t)acpi_table_length((int64_t)(phys_base + ARENA_CAP - 4)));
	}

	/* (3) The same BIOS shape with bit 31 set in every physical address.
	 * A 32-bit field assembled without a per-byte mask sign-extends here
	 * and the root stops being reachable at all. */
	bios_tree(0xFFF00000ULL);
	mbi_bios(P(OFF_ROOT));
	EQI("bit31: status", ACPI_OK, init_now());
	EQ64("bit31: the RSDT pointer survived the u32 assembly", 0xFFF02525ULL,
	     (uint64_t)acpi_root_phys());
	EQI("bit31: bit 31 really is set", 1,
	    (int)((acpi_root_phys() >> 31) & 1));
	EQI("bit31: five tables", BIOS_N, acpi_table_count());
	for (i = 0; i < BIOS_N; i++) {
		snprintf(tag, sizeof tag, "bit31[%d]: phys", i);
		EQ64(tag, bios_ptr[i], (uint64_t)acpi_table_phys(i));
		snprintf(tag, sizeof tag, "bit31[%d]: sig", i);
		EQ32(tag, sig4(bios_sig[i]), (uint32_t)acpi_table_sig(i));
		snprintf(tag, sizeof tag, "bit31[%d]: bit 31 is set", i);
		EQI(tag, 1, (int)((bios_ptr[i] >> 31) & 1));
	}
	guard_check("bit31");

	/* (4) The UEFI shape: tags 14 AND 15, and tag 15 must win -- an XSDT
	 * with 64-bit pointers at 1 mod 8, three of which point outside the
	 * window and must be reported exactly and read never. */
	uefi_tree(0xFFF00000ULL);
	mbi_uefi(P(OFF_RSDT2), P(OFF_ROOT));
	EQI("uefi: status", ACPI_OK, init_now());
	EQI("uefi: root kind is XSDT", ROOT_XSDT, acpi_root_kind());
	EQ64("uefi: tag 15 won", P(OFF_ROOT), (uint64_t)acpi_root_phys());
	EQI("uefi: tag 14's RSDT was not taken", 1,
	    acpi_root_phys() != (int64_t)P(OFF_RSDT2));
	EQI("uefi: the root is UNALIGNED, 5 mod 8", 5,
	    (int)(acpi_root_phys() & 7));
	EQI("uefi: the 64-bit entries are at 1 mod 8", 1,
	    (int)((acpi_root_phys() + HDR) & 7));
	EQI("uefi: revision 2", 2, acpi_revision());
	EQ64("uefi: the RSDP came from a tag copy", 0,
	     (uint64_t)acpi_rsdp_phys());
	EQI("uefi: table count", UEFI_N + FAR_N, acpi_table_count());
	for (i = 0; i < UEFI_N; i++) {
		snprintf(tag, sizeof tag, "uefi[%d]: phys", i);
		EQ64(tag, uefi_ptr[i], (uint64_t)acpi_table_phys(i));
		snprintf(tag, sizeof tag, "uefi[%d]: sig", i);
		EQ32(tag, sig4(uefi_sig[i]), (uint32_t)acpi_table_sig(i));
		snprintf(tag, sizeof tag, "uefi[%d]: length", i);
		EQ64(tag, uefi_len[i], (uint64_t)acpi_table_length(uefi_ptr[i]));
		snprintf(tag, sizeof tag, "uefi[%d]: checksum", i);
		EQI(tag, 1, acpi_checksum_ok(uefi_ptr[i], uefi_len[i]));
	}
	for (i = 0; i < FAR_N; i++) {
		snprintf(tag, sizeof tag, "uefi far[%d]: phys is exact", i);
		EQ64(tag, far_ptr[i], (uint64_t)acpi_table_phys(UEFI_N + i));
		snprintf(tag, sizeof tag, "uefi far[%d]: sig is refused", i);
		EQ32(tag, 0, (uint32_t)acpi_table_sig(UEFI_N + i));
		snprintf(tag, sizeof tag, "uefi far[%d]: length is refused", i);
		EQ64(tag, 0, (uint64_t)acpi_table_length((int64_t)far_ptr[i]));
	}
	/* The near miss: "APIB" differs from "APIC" in the last byte only. */
	EQ64("uefi: find APIC", uefi_ptr[1], (uint64_t)acpi_find(sig4("APIC")));
	EQ64("uefi: find APIB", uefi_ptr[6], (uint64_t)acpi_find(sig4("APIB")));
	EQI("uefi: APIC and APIB are different tables", 1,
	    acpi_find(sig4("APIC")) != acpi_find(sig4("APIB")));
	EQ64("uefi: find APID misses", 0, (uint64_t)acpi_find(sig4("APID")));
	EQ64("uefi: find BGRT", uefi_ptr[5], (uint64_t)acpi_find(sig4("BGRT")));
	EQ64("uefi: find SSDT misses", 0, (uint64_t)acpi_find(sig4("SSDT")));
	EQ64("uefi: find on a sig with bit 31 set misses", 0,
	     (uint64_t)acpi_find((int32_t)0x80808080U));
	oob_sweep("uefi", UEFI_N + FAR_N);
	guard_check("uefi");

	/* (4b) A stale slot must not leak: the BIOS shape has five tables and
	 * the UEFI one had ten, so index 5 has to answer absent afterwards. */
	good_bios(0xFFF00000ULL);
	check_oob_index("after a longer parse", BIOS_N);
	check_oob_index("after a longer parse", UEFI_N + FAR_N - 1);

	/* (5) The Multiboot2 walk itself. */
	good_bios(0x7FFE0000ULL);
	EQI("mbi: null pointer", E_MBI, acpi_init(0, 64));
	EQI("mbi: length 0", E_MBI, acpi_init((int64_t)(uintptr_t)MBI, 0));
	EQI("mbi: length 7", E_MBI, acpi_init((int64_t)(uintptr_t)MBI, 7));
	EQI("mbi: an all-ones length", E_MBI,
	    acpi_init((int64_t)(uintptr_t)MBI, (int64_t)0xFFFFFFFFFFFFFFFFULL));
	EQI("mbi: a length past the cap", E_MBI,
	    acpi_init((int64_t)(uintptr_t)MBI, MBI_MAX + 1));
	EQI("mbi: a bit-63 length", E_MBI,
	    acpi_init((int64_t)(uintptr_t)MBI, (int64_t)0x8000000000000000ULL));
	EQI("mbi: refusals cleared the parse", 0, acpi_table_count());

	good_bios(0x7FFE0000ULL);
	EQI("mbi: a header with no tags at all", E_NO_TAG,
	    acpi_init((int64_t)(uintptr_t)MBI, 8));
	EQI("mbi: no-tag cleared the parse", 0, acpi_table_count());

	/* A tag size of 0 is the input that makes the walk loop forever. */
	good_bios(0x7FFE0000ULL);
	put32(MBI + tag_off[0] + 4, 0);
	expect_fail("mbi: tag size 0", E_MBI);

	good_bios(0x7FFE0000ULL);
	put32(MBI + tag_off[0] + 4, 7);
	expect_fail("mbi: tag size 7", E_MBI);

	good_bios(0x7FFE0000ULL);
	put32(MBI + tag_off[0] + 4, mbi_len);
	expect_fail("mbi: a tag running past the end", E_MBI);

	good_bios(0x7FFE0000ULL);
	put32(MBI + tag_off[0] + 4, 0xFFFFFFFFU);
	expect_fail("mbi: an all-ones tag size", E_MBI);

	good_bios(0x7FFE0000ULL);
	mbi_len = (uint32_t)(tag_off[0] + 16);
	expect_fail("mbi: mbi_len cuts the tag in half", E_MBI);

	/* No ACPI tag at all -- a framebuffer tag is not one. */
	{
		struct tag t[1];
		static const uint8_t junk[24] = { 0 };

		bios_tree(0x7FFE0000ULL);
		t[0].type = 8; t[0].paylen = 24; t[0].pay = junk;
		mbi_build(t, 1);
		expect_fail("mbi: no ACPI tag", E_NO_TAG);
	}

	/* A tag 14 too short to hold a v1 RSDP. */
	{
		struct tag t[1];

		bios_tree(0x7FFE0000ULL);
		rsdp_write(rsdp_v1, 0, 0, (uint32_t)P(OFF_ROOT), 0, 0, 0);
		t[0].type = 14; t[0].paylen = 19; t[0].pay = rsdp_v1;
		mbi_build(t, 1);
		expect_fail("tag 14: payload 19 is too short", E_MBI);
	}

	/* (6) The RSDP. */
	good_bios(0x7FFE0000ULL);
	MBI[tag_off[0] + 8 + 7] = 'X';		/* "RSD PTRX" */
	expect_fail("rsdp: signature differs in the last byte only", E_RSDP_SIG);

	good_bios(0x7FFE0000ULL);
	MBI[tag_off[0] + 8 + 0] = 'r';
	expect_fail("rsdp: signature differs in the first byte", E_RSDP_SIG);

	good_bios(0x7FFE0000ULL);
	MBI[tag_off[0] + 8 + 8] = (uint8_t)(MBI[tag_off[0] + 8 + 8] + 1);
	expect_fail("rsdp: checksum", E_RSDP_SUM);

	good_bios(0x7FFE0000ULL);
	MBI[tag_off[0] + 8 + 19] = 0x80;	/* a reserved byte, still summed */
	expect_fail("rsdp: a byte >= 0x80 inside the summed 20", E_RSDP_SUM);

	/* (7) The v2 RSDP, and the length that bounds its extended checksum.
	 * A malformed tag 15 is FATAL: falling back to tag 14 would hide it. */
	uefi_tree(0xFFF00000ULL);
	mbi_uefi(P(OFF_RSDT2), P(OFF_ROOT));
	EQI("v2: a good parse first", ACPI_OK, init_now());

	uefi_tree(0xFFF00000ULL);
	mbi_uefi(P(OFF_RSDT2), P(OFF_ROOT));
	put32(MBI + tag_off[1] + 8 + 20, 0);
	expect_fail("v2: length 0", E_RSDP_LEN);

	uefi_tree(0xFFF00000ULL);
	mbi_uefi(P(OFF_RSDT2), P(OFF_ROOT));
	put32(MBI + tag_off[1] + 8 + 20, 35);
	expect_fail("v2: length 35", E_RSDP_LEN);

	uefi_tree(0xFFF00000ULL);
	mbi_uefi(P(OFF_RSDT2), P(OFF_ROOT));
	put32(MBI + tag_off[1] + 8 + 20, 0xFFFFFFFFU);
	expect_fail("v2: an all-ones length", E_RSDP_LEN);

	uefi_tree(0xFFF00000ULL);
	mbi_uefi(P(OFF_RSDT2), P(OFF_ROOT));
	put32(MBI + tag_off[1] + 8 + 20, RSDP_LEN_MAX + 1);
	expect_fail("v2: a length past the cap", E_RSDP_LEN);

	/* Under the cap, over the TAG: the bytes are simply not there. */
	uefi_tree(0xFFF00000ULL);
	mbi_uefi(P(OFF_RSDT2), P(OFF_ROOT));
	put32(MBI + tag_off[1] + 8 + 20, 37);
	expect_fail("v2: a length one byte past the tag payload", E_RSDP_LEN);

	uefi_tree(0xFFF00000ULL);
	mbi_uefi(P(OFF_RSDT2), P(OFF_ROOT));
	put32(MBI + tag_off[1] + 8 + 20, 100);
	expect_fail("v2: a length far past the tag payload", E_RSDP_LEN);

	uefi_tree(0xFFF00000ULL);
	mbi_uefi(P(OFF_RSDT2), P(OFF_ROOT));
	MBI[tag_off[1] + 8 + 32] = (uint8_t)(MBI[tag_off[1] + 8 + 32] + 1);
	expect_fail("v2: extended checksum", E_RSDP_EXT_SUM);

	/* The first-20 checksum is validated for v2 as well as v1. */
	uefi_tree(0xFFF00000ULL);
	mbi_uefi(P(OFF_RSDT2), P(OFF_ROOT));
	MBI[tag_off[1] + 8 + 8] = (uint8_t)(MBI[tag_off[1] + 8 + 8] + 1);
	expect_fail("v2: the first-20 checksum is checked too", E_RSDP_SUM);

	/* A tag 15 too short to hold a v2 RSDP, with a perfectly good tag 14
	 * beside it: still fatal, no fallback. */
	{
		struct tag t[2];

		uefi_tree(0xFFF00000ULL);
		rsdp_write(rsdp_v1, 0, 0, (uint32_t)P(OFF_RSDT2), 0, 0, 0);
		rsdp_write(rsdp_v2, 1, 2, (uint32_t)P(OFF_RSDT2), P(OFF_ROOT),
			   36, 36);
		t[0].type = 14; t[0].paylen = 20; t[0].pay = rsdp_v1;
		t[1].type = 15; t[1].paylen = 20; t[1].pay = rsdp_v2;
		mbi_build(t, 2);
		expect_fail("v2: a 20-byte tag 15 does not fall back to tag 14",
			    E_MBI);
	}

	/* Tag order must not matter: 15 before 14 still wins. */
	{
		struct tag t[2];

		uefi_tree(0xFFF00000ULL);
		rsdp_write(rsdp_v1, 0, 0, (uint32_t)P(OFF_RSDT2), 0, 0, 0);
		rsdp_write(rsdp_v2, 1, 2, (uint32_t)P(OFF_RSDT2), P(OFF_ROOT),
			   36, 36);
		t[0].type = 15; t[0].paylen = 36; t[0].pay = rsdp_v2;
		t[1].type = 14; t[1].paylen = 20; t[1].pay = rsdp_v1;
		mbi_build(t, 2);
		EQI("v2: tag 15 first still wins", ACPI_OK, init_now());
		EQI("v2: tag 15 first, kind", ROOT_XSDT, acpi_root_kind());
		EQ64("v2: tag 15 first, root", P(OFF_ROOT),
		     (uint64_t)acpi_root_phys());
	}

	/* A v2 RSDP whose length is 40 with a 48-byte tag: legal, and the
	 * extended checksum must balance over 40, not over 36. */
	{
		struct tag t[1];
		static uint8_t big[40];

		uefi_tree(0xFFF00000ULL);
		memset(big, 0, sizeof big);
		rsdp_write(big, 1, 2, (uint32_t)P(OFF_RSDT2), P(OFF_ROOT),
			   40, 40);
		big[36] = 0x91;			/* a byte >= 0x80 past 36 */
		big[32] = 0;
		big[32] = (uint8_t)-sum8(big, 40);
		t[0].type = 15; t[0].paylen = 40; t[0].pay = big;
		mbi_build(t, 1);
		EQI("v2: length 40 accepted", ACPI_OK, init_now());
		EQ64("v2: length 40, root", P(OFF_ROOT),
		     (uint64_t)acpi_root_phys());

		big[36] = 0x92;			/* now the sum over 40 is off */
		mbi_build(t, 1);
		expect_fail("v2: the extended sum really covers all 40",
			    E_RSDP_EXT_SUM);
	}

	/* (8) The root table. */
	bios_tree(0x7FFE0000ULL);
	mbi_bios(0);
	expect_fail("root: a null pointer", E_ROOT_RANGE);

	bios_tree(0x7FFE0000ULL);
	mbi_bios(phys_base + ARENA_CAP);
	expect_fail("root: a pointer at the top", E_ROOT_RANGE);

	bios_tree(0x7FFE0000ULL);
	mbi_bios(phys_base + ARENA_CAP + 0x1000);
	expect_fail("root: a pointer past the top", E_ROOT_RANGE);

	bios_tree(0x7FFE0000ULL);
	mbi_bios(phys_base + ARENA_CAP - 8);
	expect_fail("root: a header crossing the top", E_ROOT_RANGE);

	/* Header inside, body outside: the length check must be against the
	 * top, not against the header's own reachability. */
	bios_tree(0x7FFE0000ULL);
	root_write(P(ARENA_CAP - 64), "RSDT", bios_ptr, BIOS_N, 4, 200);
	AT(P(ARENA_CAP - 64))[9] = (uint8_t)-sum8(AT(P(ARENA_CAP - 64)), 56);
	mbi_bios(phys_base + ARENA_CAP - 64);
	expect_fail("root: a length running past the top", E_ROOT_RANGE);

	good_bios(0x7FFE0000ULL);
	AT(P(OFF_ROOT))[3] = 'X';		/* "RSDX" */
	expect_fail("root: signature differs in the last byte only", E_ROOT_SIG);

	good_bios(0x7FFE0000ULL);
	memcpy(AT(P(OFF_ROOT)), "XSDT", 4);
	expect_fail("root: an XSDT where the RSDP said RSDT", E_ROOT_SIG);

	good_bios(0x7FFE0000ULL);
	put32(AT(P(OFF_ROOT)) + 4, 35);
	expect_fail("root: length 35", E_ROOT_LEN);

	good_bios(0x7FFE0000ULL);
	put32(AT(P(OFF_ROOT)) + 4, 0);
	expect_fail("root: length 0", E_ROOT_LEN);

	good_bios(0x7FFE0000ULL);
	put32(AT(P(OFF_ROOT)) + 4, 0xFFFFFFFFU);
	expect_fail("root: an all-ones length", E_ROOT_LEN);

	good_bios(0x7FFE0000ULL);
	put32(AT(P(OFF_ROOT)) + 4, ROOT_LEN_MAX + 1);
	expect_fail("root: a length past the cap", E_ROOT_LEN);

	good_bios(0x7FFE0000ULL);
	put32(AT(P(OFF_ROOT)) + 4, HDR + 4 * BIOS_N + 2);
	expect_fail("root: a length that is not whole pointers", E_ROOT_LEN);

	/* A header of exactly 36 bytes is a root table with no tables in it. */
	bios_tree(0x7FFE0000ULL);
	root_write(P(OFF_ROOT), "RSDT", bios_ptr, 0, 4, HDR);
	mbi_bios(P(OFF_ROOT));
	EQI("root: an empty RSDT is accepted", ACPI_OK, init_now());
	EQI("root: an empty RSDT has no tables", 0, acpi_table_count());
	EQ64("root: an empty RSDT still has a root", P(OFF_ROOT),
	     (uint64_t)acpi_root_phys());
	EQ64("root: find on an empty RSDT", 0, (uint64_t)acpi_find(sig4("APIC")));
	check_oob_index("empty RSDT", 0);

	good_bios(0x7FFE0000ULL);
	AT(P(OFF_ROOT))[9] = (uint8_t)(AT(P(OFF_ROOT))[9] + 1);
	expect_fail("root: checksum", E_ROOT_SUM);

	good_bios(0x7FFE0000ULL);
	AT(P(OFF_ROOT))[HDR + 3] = (uint8_t)(AT(P(OFF_ROOT))[HDR + 3] + 1);
	expect_fail("root: a flipped pointer byte breaks the checksum",
		    E_ROOT_SUM);

	/* (9) The table-count ceiling, on both sides of it, for both roots. */
	for (i = 0; i <= MAX_TABLES; i++)
		many[i] = P(0x10000 + (size_t)i * 64);

	bios_tree(0x7FFE0000ULL);
	root_write(P(OFF_ROOT), "RSDT", many, MAX_TABLES, 4,
		   HDR + 4 * MAX_TABLES);
	mbi_bios(P(OFF_ROOT));
	EQI("ceiling: exactly 64 RSDT entries accepted", ACPI_OK, init_now());
	EQI("ceiling: count is 64", MAX_TABLES, acpi_table_count());
	for (i = 0; i < MAX_TABLES; i += 7) {
		snprintf(tag, sizeof tag, "ceiling[%d]: phys", i);
		EQ64(tag, many[i], (uint64_t)acpi_table_phys(i));
	}
	EQ64("ceiling: the last entry", many[MAX_TABLES - 1],
	     (uint64_t)acpi_table_phys(MAX_TABLES - 1));
	check_oob_index("ceiling", MAX_TABLES);

	bios_tree(0x7FFE0000ULL);
	root_write(P(OFF_ROOT), "RSDT", many, MAX_TABLES + 1, 4,
		   HDR + 4 * (MAX_TABLES + 1));
	mbi_bios(P(OFF_ROOT));
	expect_fail("ceiling: 65 RSDT entries refused, not truncated",
		    E_TOO_MANY);

	uefi_tree(0xFFF00000ULL);
	root_write(P(OFF_ROOT), "XSDT", many, MAX_TABLES + 1, 8,
		   HDR + 8 * (MAX_TABLES + 1));
	mbi_uefi(P(OFF_RSDT2), P(OFF_ROOT));
	expect_fail("ceiling: 65 XSDT entries refused, not truncated",
		    E_TOO_MANY);

	/* (10) Out-of-range indices on a parse that IS latched, and the guards
	 * one last time. */
	good_bios(0x7FFE0000ULL);
	EQ64("final: the last valid index still reads", bios_ptr[BIOS_N - 1],
	     (uint64_t)acpi_table_phys(BIOS_N - 1));
	EQ32("final: the last valid signature still reads",
	     sig4(bios_sig[BIOS_N - 1]),
	     (uint32_t)acpi_table_sig(BIOS_N - 1));
	oob_sweep("final", BIOS_N);
	guard_check("final");

	/* (11) GAPS CLOSED AFTER ADVERSARIAL REVIEW OF ROADMAP 4.1.  Each was
	 * demonstrated by a mutant that passed this suite unchanged, so each is
	 * a defect the suite previously COULD NOT fail on. */

	/* NOTE on (11a): the module's window is [0, top) -- in the kernel the
	 * offset is FK_VMM_PHYSMAP and physical 0 is the bottom, so there is no
	 * lower bound to state.  These fixtures use a NON-ZERO fake base, so a
	 * mutant that truncates a physical address below that base is outside
	 * the module's contract and faults rather than being refused.  It is
	 * still caught -- the run dies and make deletes the binary -- but the
	 * signal is a crash, not a mismatch line.
	 *
	 * (11a) A root ABOVE 4 GiB.  Both earlier bases were below it, so
	 * truncating the RSDP's 64-bit XsdtAddress to 32 bits passed -- and
	 * that field being 64 bits wide is the entire reason tag 15 is
	 * preferred over tag 14. */
	uefi_tree(0x0000000400000000ULL);
	mbi_uefi(P(OFF_RSDT2), P(OFF_ROOT));
	EQI("hi: status", ACPI_OK, init_now());
	EQI("hi: root kind is XSDT", ROOT_XSDT, acpi_root_kind());
	EQI("hi: the root really is above 4 GiB", 1,
	    (uint64_t)acpi_root_phys() > 0xFFFFFFFFULL);
	EQ64("hi: root phys keeps its upper 32 bits", P(OFF_ROOT),
	     (uint64_t)acpi_root_phys());
	EQ64("hi: entry pointers keep their upper 32 bits", uefi_ptr[0],
	     (uint64_t)acpi_table_phys(0));
	EQ64("hi: find APIC above 4 GiB", uefi_ptr[1],
	     (uint64_t)acpi_find(sig4("APIC")));
	guard_check("hi");

	/* (11b) acpi_find must SKIP an unreachable entry and keep scanning.
	 * Every far pointer sat AFTER the last findable table, so a mutant that
	 * aborted the scan at the first unreachable entry passed. */
	arena_reset();
	world(0x7FFE0000ULL);
	{
		uint64_t mix[3];

		mix[0] = far_ptr[2];			/* unreachable, FIRST */
		mix[1] = P(0x4000);
		mix[2] = P(0x5003);
		table_write(mix[1], "APIC", 160);
		table_write(mix[2], "HPET", 56);
		root_write(P(OFF_ROOT), "XSDT", mix, 3, 8, (uint32_t)(HDR + 24));
		root_write(P(OFF_RSDT2), "RSDT", mix + 1, 1, 4, HDR + 4);
		mbi_uefi(P(OFF_RSDT2), P(OFF_ROOT));
		EQI("skip: status", ACPI_OK, init_now());
		EQ64("skip: the unreachable entry is still reported exactly",
		     far_ptr[2], (uint64_t)acpi_table_phys(0));
		EQ64("skip: find walks PAST it to APIC", mix[1],
		     (uint64_t)acpi_find(sig4("APIC")));
		EQ64("skip: and on to HPET", mix[2],
		     (uint64_t)acpi_find(sig4("HPET")));
		guard_check("skip");
	}

	/* (11c) The ACCEPT side of the window bound.  Every boundary assertion
	 * here was a REFUSAL, so widening reach()'s test from > to >= -- which
	 * rejects a table ending exactly on the last byte -- passed. */
	arena_reset();
	world(0x7FFE0000ULL);
	{
		uint64_t tail = P(ARENA_CAP - 160);
		uint64_t one[1];

		table_write(tail, "APIC", 160);
		one[0] = tail;
		root_write(P(OFF_ROOT), "XSDT", one, 1, 8, (uint32_t)(HDR + 8));
		root_write(P(OFF_RSDT2), "RSDT", one, 1, 4, HDR + 4);
		mbi_uefi(P(OFF_RSDT2), P(OFF_ROOT));
		EQI("edge: status", ACPI_OK, init_now());
		EQI("edge: the table ends on the last byte under top", 1,
		    tail + 160 == phys_base + ARENA_CAP);
		EQ64("edge: its length reads", 160,
		     (uint64_t)acpi_table_length(tail));
		EQI("edge: its checksum reads", 1, acpi_checksum_ok(tail, 160));
		EQ64("edge: and find returns it", tail,
		     (uint64_t)acpi_find(sig4("APIC")));
		guard_check("edge");
	}

	return fk_report("acpi");
}
