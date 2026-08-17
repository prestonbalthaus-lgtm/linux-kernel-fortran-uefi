/* Reference-model test for src/acpi/fk_madt.f90.
 *
 * There is no C original to diff against -- the MADT walker is a translation of
 * ACPI 6.5 5.2.12 -- so this file carries its own model: tables are described
 * entry by entry, laid into a poisoned arena, and every accessor is compared
 * against what was laid down.
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

#define EQ64(what, a, b) \
	FK_EQ(what, (unsigned long long)(a), (unsigned long long)(b), "0x%llX")
#define EQ32(what, a, b) \
	FK_EQ(what, (unsigned)(a), (unsigned)(b), "0x%X")
#define EQI(what, a, b)  FK_EQ(what, (int)(a), (int)(b), "%d")

/* --- the Fortran module's bind(c) surface -------------------------------- */
int32_t madt_parse(int64_t virt, int32_t len);
int64_t madt_lapic_addr(void);
int32_t madt_flags(void);
int32_t madt_pcat_compat(void);
int64_t madt_addr_override(void);
int32_t madt_cpu_count(void);
int32_t madt_cpu_enabled(void);
int32_t madt_cpu_apic_id(int32_t i);
int32_t madt_cpu_acpi_id(int32_t i);
int32_t madt_ioapic_count(void);
int32_t madt_ioapic_id(int32_t i);
int64_t madt_ioapic_addr(int32_t i);
int32_t madt_ioapic_gsi_base(int32_t i);
int32_t madt_iso_count(void);
int32_t madt_iso_bus(int32_t i);
int32_t madt_iso_src(int32_t i);
int32_t madt_iso_gsi(int32_t i);
int32_t madt_iso_flags(int32_t i);
int32_t madt_gsi_for_irq(int32_t irq);
int32_t madt_nmi_count(void);
int32_t madt_nmi_acpi_id(int32_t i);
int32_t madt_nmi_lint(int32_t i);
int32_t madt_nmi_flags(int32_t i);
int32_t madt_skipped(void);

/* --- constants, mirroring src/acpi/fk_madt.f90 --------------------------- */
enum {
	MADT_OK = 0, E_NULL = 1, E_LEN = 2, E_SIG = 3, E_CHECKSUM = 4,
	E_TRUNC = 5, E_ENTRY_ZERO = 6, E_ENTRY_OVERRUN = 7, E_ENTRY_SHORT = 8,
	E_MANY_CPU = 9, E_MANY_IOAPIC = 10, E_MANY_ISO = 11, E_MANY_NMI = 12,
};

#define MAX_CPU		256
#define MAX_IOAPIC	16
#define MAX_ISO		64
#define MAX_NMI		256
#define MIN_LEN		44
#define LEN_MAX		65536
#define BAD32		0xFFFFFFFFU
#define BAD64		0xFFFFFFFFFFFFFFFFULL

/* --- the guarded arena --------------------------------------------------- */
#define POISON		0xA5
#define GUARD		256
#define ARENA_CAP	65536
static uint8_t arena_mem[GUARD + ARENA_CAP + GUARD];
#define ARENA		(arena_mem + GUARD)

/* --- the table builder ---------------------------------------------------
 * Every write is byte-wise: the table base is usually unaligned, so the test
 * must not do what it is proving the parser must not do. */
static uint8_t *T;
static int TP;

static void w8(int off, uint32_t v)  { T[off] = (uint8_t)v; }
static void w16(int off, uint32_t v)
{
	T[off]     = (uint8_t)(v & 0xFF);
	T[off + 1] = (uint8_t)((v >> 8) & 0xFF);
}
static void w32(int off, uint32_t v)
{
	int i;

	for (i = 0; i < 4; i++)
		T[off + i] = (uint8_t)((v >> (8 * i)) & 0xFF);
}
static void w64(int off, uint64_t v)
{
	int i;

	for (i = 0; i < 8; i++)
		T[off + i] = (uint8_t)((v >> (8 * i)) & 0xFF);
}

/* The 36-byte ACPI header plus lapic_addr and flags. */
static void tb_open(uint8_t *base)
{
	int i;

	T = base;
	for (i = 0; i < MIN_LEN; i++)
		T[i] = 0;
	T[0] = 'A'; T[1] = 'P'; T[2] = 'I'; T[3] = 'C';
	T[8] = 1;			/* revision */
	memcpy(T + 10, "FKTEST", 6);	/* OEM ID */
	memcpy(T + 16, "FKMADT01", 8);	/* OEM table ID */
	TP = MIN_LEN;
}

static void tb_at(int off)
{
	memset(arena_mem, POISON, sizeof arena_mem);
	tb_open(ARENA + off);
}

static void tb_hdr(uint32_t lapic, uint32_t flags)
{
	w32(36, lapic);
	w32(40, flags);
}

static void tb_cpu(uint32_t acpi, uint32_t apic, uint32_t flags)
{
	w8(TP, 0); w8(TP + 1, 8); w8(TP + 2, acpi); w8(TP + 3, apic);
	w32(TP + 4, flags);
	TP += 8;
}

static void tb_ioapic(uint32_t id, uint32_t addr, uint32_t gsi)
{
	w8(TP, 1); w8(TP + 1, 12); w8(TP + 2, id); w8(TP + 3, 0xC3);
	w32(TP + 4, addr); w32(TP + 8, gsi);
	TP += 12;
}

static void tb_iso(uint32_t bus, uint32_t src, uint32_t gsi, uint32_t flags)
{
	w8(TP, 2); w8(TP + 1, 10); w8(TP + 2, bus); w8(TP + 3, src);
	w32(TP + 4, gsi); w16(TP + 8, flags);
	TP += 10;
}

/* flags at ODD offset 3 (ACPI 6.5 table 5.48), lint at 5. */
static void tb_nmi(uint32_t acpi, uint32_t flags, uint32_t lint)
{
	w8(TP, 4); w8(TP + 1, 6); w8(TP + 2, acpi);
	w16(TP + 3, flags); w8(TP + 5, lint);
	TP += 6;
}

static void tb_ovr(uint64_t addr)
{
	w8(TP, 5); w8(TP + 1, 12); w16(TP + 2, 0xBEEF); w64(TP + 4, addr);
	TP += 12;
}

/* An arbitrary entry: `lenbyte` is what the length field CLAIMS, `nbytes` is
 * how many bytes are physically laid down. Malformed tables need the two to
 * disagree. Payload 0xC7 is deliberate: a parser that skips an unknown entry
 * by a guessed size lands on type 0xC7 length 0xC7 and cannot pretend to
 * succeed. */
static void tb_raw(uint32_t type, uint32_t lenbyte, int nbytes, uint32_t pay)
{
	int i;

	if (nbytes > 0) w8(TP, type);
	if (nbytes > 1) w8(TP + 1, lenbyte);
	for (i = 2; i < nbytes; i++)
		w8(TP + i, pay);
	TP += nbytes;
}

static int tb_finish(void)
{
	int i;
	uint8_t s = 0;

	w32(4, (uint32_t)TP);
	T[9] = 0;
	for (i = 0; i < TP; i++)
		s = (uint8_t)(s + T[i]);
	T[9] = (uint8_t)(0u - s);
	return TP;
}

static int32_t parse_at(const uint8_t *p, int32_t len)
{
	return madt_parse((int64_t)(uintptr_t)p, len);
}

static void guard_check(const char *what)
{
	size_t i;
	int bad = 0;

	for (i = 0; i < GUARD; i++)
		if (arena_mem[i] != POISON ||
		    arena_mem[GUARD + ARENA_CAP + i] != POISON)
			bad = 1;
	fk_checks++;
	if (bad) {
		printf("  GUARD %s: arena guard band was modified\n", what);
		fk_fails++;
	}
}

/* --- every accessor on an index that is not in its array ------------------ */
static void check_oob(const char *what, int32_t i)
{
	static char tag[192];

	snprintf(tag, sizeof tag, "%s: cpu_apic_id(%d)", what, i);
	EQ32(tag, BAD32, (uint32_t)madt_cpu_apic_id(i));
	snprintf(tag, sizeof tag, "%s: cpu_acpi_id(%d)", what, i);
	EQ32(tag, BAD32, (uint32_t)madt_cpu_acpi_id(i));
	snprintf(tag, sizeof tag, "%s: ioapic_id(%d)", what, i);
	EQ32(tag, BAD32, (uint32_t)madt_ioapic_id(i));
	snprintf(tag, sizeof tag, "%s: ioapic_addr(%d)", what, i);
	EQ64(tag, BAD64, (uint64_t)madt_ioapic_addr(i));
	snprintf(tag, sizeof tag, "%s: ioapic_gsi_base(%d)", what, i);
	EQ32(tag, BAD32, (uint32_t)madt_ioapic_gsi_base(i));
	snprintf(tag, sizeof tag, "%s: iso_bus(%d)", what, i);
	EQ32(tag, BAD32, (uint32_t)madt_iso_bus(i));
	snprintf(tag, sizeof tag, "%s: iso_src(%d)", what, i);
	EQ32(tag, BAD32, (uint32_t)madt_iso_src(i));
	snprintf(tag, sizeof tag, "%s: iso_gsi(%d)", what, i);
	EQ32(tag, BAD32, (uint32_t)madt_iso_gsi(i));
	snprintf(tag, sizeof tag, "%s: iso_flags(%d)", what, i);
	EQ32(tag, BAD32, (uint32_t)madt_iso_flags(i));
	snprintf(tag, sizeof tag, "%s: nmi_acpi_id(%d)", what, i);
	EQ32(tag, BAD32, (uint32_t)madt_nmi_acpi_id(i));
	snprintf(tag, sizeof tag, "%s: nmi_lint(%d)", what, i);
	EQ32(tag, BAD32, (uint32_t)madt_nmi_lint(i));
	snprintf(tag, sizeof tag, "%s: nmi_flags(%d)", what, i);
	EQ32(tag, BAD32, (uint32_t)madt_nmi_flags(i));
}

/* Nothing latched: every count zero, every accessor its sentinel. */
static void check_empty(const char *what)
{
	static char tag[192];

	snprintf(tag, sizeof tag, "%s: cpu_count", what);
	EQI(tag, 0, madt_cpu_count());
	snprintf(tag, sizeof tag, "%s: cpu_enabled", what);
	EQI(tag, 0, madt_cpu_enabled());
	snprintf(tag, sizeof tag, "%s: ioapic_count", what);
	EQI(tag, 0, madt_ioapic_count());
	snprintf(tag, sizeof tag, "%s: iso_count", what);
	EQI(tag, 0, madt_iso_count());
	snprintf(tag, sizeof tag, "%s: nmi_count", what);
	EQI(tag, 0, madt_nmi_count());
	snprintf(tag, sizeof tag, "%s: skipped", what);
	EQI(tag, 0, madt_skipped());
	snprintf(tag, sizeof tag, "%s: flags", what);
	EQ32(tag, 0, (uint32_t)madt_flags());
	snprintf(tag, sizeof tag, "%s: pcat_compat", what);
	EQI(tag, 0, madt_pcat_compat());
	snprintf(tag, sizeof tag, "%s: lapic_addr", what);
	EQ64(tag, 0, (uint64_t)madt_lapic_addr());
	snprintf(tag, sizeof tag, "%s: addr_override", what);
	EQ64(tag, 0, (uint64_t)madt_addr_override());
	snprintf(tag, sizeof tag, "%s: gsi_for_irq(0) is identity", what);
	EQI(tag, 0, madt_gsi_for_irq(0));
	snprintf(tag, sizeof tag, "%s: gsi_for_irq(9) is identity", what);
	EQI(tag, 9, madt_gsi_for_irq(9));
	check_oob(what, 0);
}

/* --- GROUND TRUTH: the MADT this project measured on QEMU q35, -smp 6 ----- */
static const struct {
	uint8_t bus, src;
	uint32_t gsi;
	uint16_t flags;
} qemu_iso[5] = {
	{ 0,  0,  2, 0x0000 },
	{ 0,  5,  5, 0x000D },
	{ 0,  9,  9, 0x000D },
	{ 0, 10, 10, 0x000D },
	{ 0, 11, 11, 0x000D },
};

static int build_qemu(uint8_t *base)
{
	int i;

	tb_open(base);
	tb_hdr(0xFEE00000U, 0x1U);
	for (i = 0; i < 6; i++)
		tb_cpu((uint32_t)i, (uint32_t)i, 0x1U);
	tb_ioapic(0, 0xFEC00000U, 0);
	for (i = 0; i < 5; i++)
		tb_iso(qemu_iso[i].bus, qemu_iso[i].src, qemu_iso[i].gsi,
		       qemu_iso[i].flags);
	tb_nmi(0xFF, 0x0000, 1);
	return tb_finish();
}

static void check_qemu(const char *what)
{
	static char tag[192];
	int i;

	snprintf(tag, sizeof tag, "%s: lapic_addr", what);
	EQ64(tag, 0xFEE00000ULL, (uint64_t)madt_lapic_addr());
	snprintf(tag, sizeof tag, "%s: no address override", what);
	EQ64(tag, 0, (uint64_t)madt_addr_override());
	snprintf(tag, sizeof tag, "%s: flags", what);
	EQ32(tag, 0x1U, (uint32_t)madt_flags());
	snprintf(tag, sizeof tag, "%s: PCAT_COMPAT", what);
	EQI(tag, 1, madt_pcat_compat());

	snprintf(tag, sizeof tag, "%s: cpu_count", what);
	EQI(tag, 6, madt_cpu_count());
	snprintf(tag, sizeof tag, "%s: cpu_enabled", what);
	EQI(tag, 6, madt_cpu_enabled());
	for (i = 0; i < 6; i++) {
		snprintf(tag, sizeof tag, "%s: cpu[%d] apic_id", what, i);
		EQ32(tag, (uint32_t)i, (uint32_t)madt_cpu_apic_id(i));
		snprintf(tag, sizeof tag, "%s: cpu[%d] acpi_id", what, i);
		EQ32(tag, (uint32_t)i, (uint32_t)madt_cpu_acpi_id(i));
	}

	snprintf(tag, sizeof tag, "%s: ioapic_count", what);
	EQI(tag, 1, madt_ioapic_count());
	snprintf(tag, sizeof tag, "%s: ioapic id", what);
	EQ32(tag, 0, (uint32_t)madt_ioapic_id(0));
	snprintf(tag, sizeof tag, "%s: ioapic addr", what);
	EQ64(tag, 0xFEC00000ULL, (uint64_t)madt_ioapic_addr(0));
	snprintf(tag, sizeof tag, "%s: ioapic gsi_base", what);
	EQ32(tag, 0, (uint32_t)madt_ioapic_gsi_base(0));

	snprintf(tag, sizeof tag, "%s: iso_count", what);
	EQI(tag, 5, madt_iso_count());
	for (i = 0; i < 5; i++) {
		snprintf(tag, sizeof tag, "%s: iso[%d] bus", what, i);
		EQ32(tag, qemu_iso[i].bus, (uint32_t)madt_iso_bus(i));
		snprintf(tag, sizeof tag, "%s: iso[%d] src", what, i);
		EQ32(tag, qemu_iso[i].src, (uint32_t)madt_iso_src(i));
		snprintf(tag, sizeof tag, "%s: iso[%d] gsi", what, i);
		EQ32(tag, qemu_iso[i].gsi, (uint32_t)madt_iso_gsi(i));
		snprintf(tag, sizeof tag, "%s: iso[%d] flags", what, i);
		EQ32(tag, qemu_iso[i].flags, (uint32_t)madt_iso_flags(i));
	}

	snprintf(tag, sizeof tag, "%s: nmi_count", what);
	EQI(tag, 1, madt_nmi_count());
	snprintf(tag, sizeof tag, "%s: nmi acpi_id is 0xFF", what);
	EQ32(tag, 0xFFU, (uint32_t)madt_nmi_acpi_id(0));
	snprintf(tag, sizeof tag, "%s: nmi is on LINT1", what);
	EQ32(tag, 1, (uint32_t)madt_nmi_lint(0));
	snprintf(tag, sizeof tag, "%s: nmi flags", what);
	EQ32(tag, 0x0000U, (uint32_t)madt_nmi_flags(0));

	snprintf(tag, sizeof tag, "%s: nothing skipped", what);
	EQI(tag, 0, madt_skipped());

	/* The reason the ISO list exists: the PIT's IRQ 0 is GSI 2 here. */
	snprintf(tag, sizeof tag, "%s: gsi_for_irq(0) is 2", what);
	EQI(tag, 2, madt_gsi_for_irq(0));
	for (i = 0; i < 5; i++) {
		snprintf(tag, sizeof tag, "%s: gsi_for_irq(%d)", what,
			 qemu_iso[i].src);
		EQI(tag, (int)qemu_iso[i].gsi,
		    madt_gsi_for_irq((int32_t)qemu_iso[i].src));
	}
	/* No override for these: identity, including 2 -- which is a GSI some
	 * other IRQ was moved to and NOT an overridden source. */
	{
		static const int plain[] = { 1, 2, 3, 4, 6, 7, 8, 12, 13, 14,
					     15, 16, 23, 24, 100, 255 };
		size_t k;

		for (k = 0; k < sizeof plain / sizeof plain[0]; k++) {
			snprintf(tag, sizeof tag,
				 "%s: gsi_for_irq(%d) is identity", what,
				 plain[k]);
			EQI(tag, plain[k], madt_gsi_for_irq(plain[k]));
		}
	}
	snprintf(tag, sizeof tag, "%s: gsi_for_irq(-1) is identity", what);
	EQI(tag, -1, madt_gsi_for_irq(-1));
	snprintf(tag, sizeof tag, "%s: gsi_for_irq(INT32_MAX) is identity", what);
	EQI(tag, INT32_MAX, madt_gsi_for_irq(INT32_MAX));

	check_oob(what, -1);
	check_oob(what, 6);
	check_oob(what, INT32_MAX);
	check_oob(what, INT32_MIN);
}

/* --- a C model, for randomly generated tables ---------------------------- */
struct model {
	uint32_t lapic, flags;
	uint64_t ovr;
	int ovr_seen;
	int ncpu, nioa, niso, nnmi, nskip;
	uint32_t cpu_acpi[MAX_CPU], cpu_apic[MAX_CPU], cpu_flags[MAX_CPU];
	uint32_t ioa_id[MAX_IOAPIC], ioa_gsi[MAX_IOAPIC];
	uint64_t ioa_addr[MAX_IOAPIC];
	uint32_t iso_bus[MAX_ISO], iso_src[MAX_ISO], iso_gsi[MAX_ISO],
		 iso_flags[MAX_ISO];
	uint32_t nmi_acpi[MAX_NMI], nmi_lint[MAX_NMI], nmi_flags[MAX_NMI];
};

static int model_gsi(const struct model *m, int32_t irq)
{
	int i;

	for (i = 0; i < m->niso; i++)
		if ((int32_t)m->iso_src[i] == irq)
			return (int32_t)m->iso_gsi[i];
	return irq;
}

static void check_model(const char *what, const struct model *m)
{
	static char tag[192];
	int i;

	snprintf(tag, sizeof tag, "%s: lapic_addr", what);
	EQ64(tag, m->ovr_seen ? m->ovr : (uint64_t)m->lapic,
	     (uint64_t)madt_lapic_addr());
	snprintf(tag, sizeof tag, "%s: addr_override", what);
	EQ64(tag, m->ovr_seen ? m->ovr : 0ULL, (uint64_t)madt_addr_override());
	snprintf(tag, sizeof tag, "%s: flags", what);
	EQ32(tag, m->flags, (uint32_t)madt_flags());
	snprintf(tag, sizeof tag, "%s: pcat_compat", what);
	EQI(tag, (int)(m->flags & 1U), madt_pcat_compat());
	snprintf(tag, sizeof tag, "%s: skipped", what);
	EQI(tag, m->nskip, madt_skipped());

	snprintf(tag, sizeof tag, "%s: cpu_count", what);
	EQI(tag, m->ncpu, madt_cpu_count());
	{
		int en = 0;

		for (i = 0; i < m->ncpu; i++)
			if (m->cpu_flags[i] & 1U)
				en++;
		snprintf(tag, sizeof tag, "%s: cpu_enabled", what);
		EQI(tag, en, madt_cpu_enabled());
	}
	for (i = 0; i < m->ncpu; i++) {
		snprintf(tag, sizeof tag, "%s: cpu[%d] acpi", what, i);
		EQ32(tag, m->cpu_acpi[i], (uint32_t)madt_cpu_acpi_id(i));
		snprintf(tag, sizeof tag, "%s: cpu[%d] apic", what, i);
		EQ32(tag, m->cpu_apic[i], (uint32_t)madt_cpu_apic_id(i));
	}

	snprintf(tag, sizeof tag, "%s: ioapic_count", what);
	EQI(tag, m->nioa, madt_ioapic_count());
	for (i = 0; i < m->nioa; i++) {
		snprintf(tag, sizeof tag, "%s: ioapic[%d] id", what, i);
		EQ32(tag, m->ioa_id[i], (uint32_t)madt_ioapic_id(i));
		snprintf(tag, sizeof tag, "%s: ioapic[%d] addr", what, i);
		EQ64(tag, m->ioa_addr[i], (uint64_t)madt_ioapic_addr(i));
		snprintf(tag, sizeof tag, "%s: ioapic[%d] gsi_base", what, i);
		EQ32(tag, m->ioa_gsi[i], (uint32_t)madt_ioapic_gsi_base(i));
	}

	snprintf(tag, sizeof tag, "%s: iso_count", what);
	EQI(tag, m->niso, madt_iso_count());
	for (i = 0; i < m->niso; i++) {
		snprintf(tag, sizeof tag, "%s: iso[%d] bus", what, i);
		EQ32(tag, m->iso_bus[i], (uint32_t)madt_iso_bus(i));
		snprintf(tag, sizeof tag, "%s: iso[%d] src", what, i);
		EQ32(tag, m->iso_src[i], (uint32_t)madt_iso_src(i));
		snprintf(tag, sizeof tag, "%s: iso[%d] gsi", what, i);
		EQ32(tag, m->iso_gsi[i], (uint32_t)madt_iso_gsi(i));
		snprintf(tag, sizeof tag, "%s: iso[%d] flags", what, i);
		EQ32(tag, m->iso_flags[i], (uint32_t)madt_iso_flags(i));
	}

	snprintf(tag, sizeof tag, "%s: nmi_count", what);
	EQI(tag, m->nnmi, madt_nmi_count());
	for (i = 0; i < m->nnmi; i++) {
		snprintf(tag, sizeof tag, "%s: nmi[%d] acpi", what, i);
		EQ32(tag, m->nmi_acpi[i], (uint32_t)madt_nmi_acpi_id(i));
		snprintf(tag, sizeof tag, "%s: nmi[%d] lint", what, i);
		EQ32(tag, m->nmi_lint[i], (uint32_t)madt_nmi_lint(i));
		snprintf(tag, sizeof tag, "%s: nmi[%d] flags", what, i);
		EQ32(tag, m->nmi_flags[i], (uint32_t)madt_nmi_flags(i));
	}

	for (i = -2; i < 40; i++) {
		snprintf(tag, sizeof tag, "%s: gsi_for_irq(%d)", what, i);
		EQI(tag, model_gsi(m, i), madt_gsi_for_irq(i));
	}
	check_oob(what, -1);
	check_oob(what, 300);
}

/* Random tables in random entry order, every field a random bit pattern.  The
 * point is the interleaving: a parser that assumes QEMU's grouping, or that
 * indexes its arrays by entry number rather than by per-type count, breaks
 * here and nowhere else. */
static void fuzz_model(int rounds)
{
	static char tag[64];
	struct model m;
	int r, k, n, i;

	fk_srand(0x4D414454ULL);
	for (r = 0; r < rounds; r++) {
		int plan[96], np = 0;

		memset(&m, 0, sizeof m);
		tb_at((int)(fk_rand() % 8));
		m.lapic = (uint32_t)fk_rand();
		m.flags = (uint32_t)fk_rand();
		tb_hdr(m.lapic, m.flags);

		n = (int)(fk_rand() % 40) + 1;
		for (k = 0; k < n && np < 96; k++)
			plan[np++] = (int)(fk_rand() % 7);

		for (k = 0; k < np; k++) {
			uint64_t x = fk_rand();

			switch (plan[k]) {
			case 0:
				if (m.ncpu >= MAX_CPU) break;
				m.cpu_acpi[m.ncpu]  = (uint32_t)(x & 0xFF);
				m.cpu_apic[m.ncpu]  = (uint32_t)((x >> 8) & 0xFF);
				m.cpu_flags[m.ncpu] = (uint32_t)(x >> 32);
				tb_cpu(m.cpu_acpi[m.ncpu], m.cpu_apic[m.ncpu],
				       m.cpu_flags[m.ncpu]);
				m.ncpu++;
				break;
			case 1:
				if (m.nioa >= MAX_IOAPIC) break;
				m.ioa_id[m.nioa]   = (uint32_t)(x & 0xFF);
				m.ioa_addr[m.nioa] = (uint32_t)(x >> 32);
				m.ioa_gsi[m.nioa]  = (uint32_t)(x >> 16);
				tb_ioapic(m.ioa_id[m.nioa],
					  (uint32_t)m.ioa_addr[m.nioa],
					  m.ioa_gsi[m.nioa]);
				m.nioa++;
				break;
			case 2:
				if (m.niso >= MAX_ISO) break;
				m.iso_bus[m.niso]   = (uint32_t)(x & 0xFF);
				m.iso_src[m.niso]   = (uint32_t)((x >> 8) & 0xFF);
				m.iso_gsi[m.niso]   = (uint32_t)(x >> 32);
				m.iso_flags[m.niso] = (uint32_t)((x >> 16) & 0xFFFF);
				tb_iso(m.iso_bus[m.niso], m.iso_src[m.niso],
				       m.iso_gsi[m.niso], m.iso_flags[m.niso]);
				m.niso++;
				break;
			case 3:
				if (m.nnmi >= MAX_NMI) break;
				m.nmi_acpi[m.nnmi]  = (uint32_t)(x & 0xFF);
				m.nmi_flags[m.nnmi] = (uint32_t)((x >> 16) & 0xFFFF);
				m.nmi_lint[m.nnmi]  = (uint32_t)((x >> 8) & 0xFF);
				tb_nmi(m.nmi_acpi[m.nnmi], m.nmi_flags[m.nnmi],
				       m.nmi_lint[m.nnmi]);
				m.nnmi++;
				break;
			case 4:
				m.ovr = x;
				m.ovr_seen = 1;	/* last one wins */
				tb_ovr(m.ovr);
				break;
			default:
				/* Types this module does not decode, at a
				 * length only their own header states. */
				tb_raw((uint32_t)(0x40 + (x & 0x3F)),
				       (uint32_t)(2 + (x % 21)),
				       (int)(2 + (x % 21)), 0xC7);
				m.nskip++;
				break;
			}
		}
		i = tb_finish();
		snprintf(tag, sizeof tag, "fuzz[%d]: parse", r);
		EQI(tag, MADT_OK, parse_at(T, i));
		snprintf(tag, sizeof tag, "fuzz[%d]", r);
		check_model(tag, &m);
	}
	guard_check("fuzz");
}

/* --- a table laid against a PROT_NONE page ------------------------------- */
static void tail_page(void)
{
	long ps = sysconf(_SC_PAGESIZE);
	uint8_t *m, *base;
	int len;

	m = mmap(NULL, (size_t)ps * 2, PROT_READ | PROT_WRITE,
		 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (m == MAP_FAILED)
		return;
	if (mprotect(m + ps, (size_t)ps, PROT_NONE) != 0) {
		munmap(m, (size_t)ps * 2);
		return;
	}
	memset(m, POISON, (size_t)ps);

	/* Ends exactly at the boundary: one byte of over-read is a SIGSEGV. */
	base = m + ps - 160;
	len = build_qemu(base);
	EQI("tail page: the real MADT is 160 bytes", 160, len);
	EQI("tail page: parse", MADT_OK, parse_at(base, len));
	check_qemu("tail page");

	/* A Type 1 that claims 8 bytes when an IOAPIC needs 12, as the LAST
	 * entry. Reading its addr field would cross the boundary; the module
	 * must refuse on the length alone. */
	memset(m, POISON, (size_t)ps);
	tb_open(m + ps - 52);
	tb_hdr(0xFEE00000U, 1);
	tb_raw(1, 8, 8, 0xC7);
	len = tb_finish();
	EQI("tail page: short trailing entry is 52 bytes", 52, len);
	EQI("tail page: short trailing entry refused without reading past",
	    E_ENTRY_SHORT, parse_at(m + ps - 52, len));
	check_empty("tail page: after short trailing entry");

	munmap(m, (size_t)ps * 2);
}

int main(void)
{
	static char tag[192];
	int off, len, i;

	/* (1) Cold. Must run first: the module's state is process-global from
	 * here on. */
	check_empty("cold");
	EQ64("cold: ioapic_addr(0)", BAD64, (uint64_t)madt_ioapic_addr(0));
	check_oob("cold", -1);
	check_oob("cold", 1);

	/* (2) THE GROUND TRUTH, at every byte alignment. The BIOS path's RSDT
	 * is at 0x7FFE2525, so no alignment is on offer and all eight must
	 * agree. */
	for (off = 0; off < 8; off++) {
		tb_at(off);
		len = build_qemu(ARENA + off);
		snprintf(tag, sizeof tag, "qemu@%d: length is the measured 160",
			 off);
		EQI(tag, 160, len);
		snprintf(tag, sizeof tag, "qemu@%d: parse", off);
		EQI(tag, MADT_OK, parse_at(ARENA + off, len));
		snprintf(tag, sizeof tag, "qemu@%d", off);
		check_qemu(tag);
		guard_check(tag);
	}

	/* (2b) The alignment trap is armed. The Type 4 entry sits at table
	 * offset 154, so its 16-bit flags field is at 157 -- odd. A parser
	 * reading through a c_int16_t array descriptor indexes 157/2 = 78,
	 * i.e. bytes 156..157, and gets acpi_id in the low half instead. */
	{
		uint16_t typed;

		tb_at(0);
		build_qemu(ARENA);
		EQ32("trap armed: type 4 entry is at offset 154",
		     4, ARENA[154]);
		EQ32("trap armed: its length is 6", 6, ARENA[155]);
		memcpy(&typed, ARENA + 156, 2);
		EQ32("trap armed: a 16-bit indexed read yields acpi_id, "
		     "not the flags", 0x00FFU, typed);
		EQI("trap armed: and that differs from the real flags",
		    1, typed != 0x0000);
	}

	/* (3) Type 4's u16 flags at ODD offset 3, with bit 15 set. Neither a
	 * sign-extended byte nor an aligned typed read survives this. Run at
	 * every base alignment so the field is at an odd ABSOLUTE address too. */
	for (off = 0; off < 8; off++) {
		static const uint32_t nf[] = { 0x8000, 0xFFFF, 0x80FF, 0xFF80,
					       0x00FF, 0x8001, 0x0000, 0x7FFF };
		int n = (int)(sizeof nf / sizeof nf[0]);

		tb_at(off);
		tb_hdr(0xFEE00000U, 0x1U);
		for (i = 0; i < n; i++)
			tb_nmi(0xFF - (uint32_t)i, nf[i], (uint32_t)(i & 1));
		len = tb_finish();
		snprintf(tag, sizeof tag, "nmi@%d: parse", off);
		EQI(tag, MADT_OK, parse_at(ARENA + off, len));
		snprintf(tag, sizeof tag, "nmi@%d: count", off);
		EQI(tag, n, madt_nmi_count());
		for (i = 0; i < n; i++) {
			snprintf(tag, sizeof tag,
				 "nmi@%d[%d]: u16 flags at odd offset 3",
				 off, i);
			EQ32(tag, nf[i], (uint32_t)madt_nmi_flags(i));
			snprintf(tag, sizeof tag, "nmi@%d[%d]: acpi_id", off, i);
			EQ32(tag, 0xFFU - (uint32_t)i,
			     (uint32_t)madt_nmi_acpi_id(i));
			snprintf(tag, sizeof tag, "nmi@%d[%d]: lint", off, i);
			EQ32(tag, (uint32_t)(i & 1), (uint32_t)madt_nmi_lint(i));
		}
		check_oob("nmi high flags", n);
	}

	/* (4) The Type 5 override supersedes the header's u32 -- including with
	 * bit 63 set, and including when it appears BEFORE the processors. */
	for (off = 0; off < 8; off++) {
		tb_at(off);
		tb_hdr(0xFEE00000U, 0x1U);
		tb_ovr(0x88000000FEE00000ULL);
		tb_cpu(0, 0, 1);
		tb_cpu(1, 1, 1);
		len = tb_finish();
		snprintf(tag, sizeof tag, "ovr@%d: parse", off);
		EQI(tag, MADT_OK, parse_at(ARENA + off, len));
		snprintf(tag, sizeof tag, "ovr@%d: lapic_addr is the override",
			 off);
		EQ64(tag, 0x88000000FEE00000ULL, (uint64_t)madt_lapic_addr());
		snprintf(tag, sizeof tag, "ovr@%d: addr_override", off);
		EQ64(tag, 0x88000000FEE00000ULL, (uint64_t)madt_addr_override());
		snprintf(tag, sizeof tag, "ovr@%d: entries after it still parse",
			 off);
		EQI(tag, 2, madt_cpu_count());
	}
	/* All-ones, and a second override that wins over the first. */
	tb_at(3);
	tb_hdr(0xFEE00000U, 0x1U);
	tb_ovr(0x1122334455667788ULL);
	tb_ovr(0xFFFFFFFFFFFFFFFFULL);
	len = tb_finish();
	EQI("ovr: parse", MADT_OK, parse_at(ARENA + 3, len));
	EQ64("ovr: all-ones override survives", BAD64,
	     (uint64_t)madt_lapic_addr());
	EQ64("ovr: the later entry wins", BAD64,
	     (uint64_t)madt_addr_override());

	/* (5) The header's u32 must not sign-extend, at either end. */
	{
		static const uint32_t la[] = { 0xFEE00000U, 0x80000000U,
					       0xFFFFFFFFU, 0x7FFFFFFFU,
					       0x00000000U, 0x00000001U };

		for (i = 0; i < (int)(sizeof la / sizeof la[0]); i++) {
			tb_at(5);
			tb_hdr(la[i], 0x80000001U);
			tb_ioapic(0xFF, la[i], la[i]);
			len = tb_finish();
			snprintf(tag, sizeof tag, "u32 widen[%d]: parse", i);
			EQI(tag, MADT_OK, parse_at(ARENA + 5, len));
			snprintf(tag, sizeof tag, "u32 widen[%d]: lapic_addr", i);
			EQ64(tag, (uint64_t)la[i], (uint64_t)madt_lapic_addr());
			snprintf(tag, sizeof tag, "u32 widen[%d]: ioapic addr", i);
			EQ64(tag, (uint64_t)la[i], (uint64_t)madt_ioapic_addr(0));
			snprintf(tag, sizeof tag, "u32 widen[%d]: ioapic gsi", i);
			EQ32(tag, la[i], (uint32_t)madt_ioapic_gsi_base(0));
			snprintf(tag, sizeof tag, "u32 widen[%d]: header flags", i);
			EQ32(tag, 0x80000001U, (uint32_t)madt_flags());
			snprintf(tag, sizeof tag,
				 "u32 widen[%d]: pcat_compat from bit 0", i);
			EQI(tag, 1, madt_pcat_compat());
		}
	}
	/* PCAT_COMPAT clear, with every other bit set. */
	tb_at(1);
	tb_hdr(0xFEE00000U, 0xFFFFFFFEU);
	len = tb_finish();
	EQI("flags: parse", MADT_OK, parse_at(ARENA + 1, len));
	EQ32("flags: kept whole", 0xFFFFFFFEU, (uint32_t)madt_flags());
	EQI("flags: PCAT_COMPAT clear", 0, madt_pcat_compat());

	/* (6) Disabled processors are COUNTED but not enabled. */
	tb_at(7);
	tb_hdr(0xFEE00000U, 1);
	tb_cpu(0, 0, 0x00000001U);
	tb_cpu(1, 1, 0x00000000U);
	tb_cpu(2, 2, 0x80000001U);
	tb_cpu(3, 3, 0x80000000U);
	tb_cpu(4, 4, 0xFFFFFFFFU);
	tb_cpu(5, 5, 0xFFFFFFFEU);
	tb_cpu(6, 6, 0x00000002U);
	tb_cpu(7, 7, 0x00000003U);
	len = tb_finish();
	EQI("enabled: parse", MADT_OK, parse_at(ARENA + 7, len));
	EQI("enabled: all 8 processors counted", 8, madt_cpu_count());
	EQI("enabled: only the 4 with bit 0 are enabled", 4, madt_cpu_enabled());
	for (i = 0; i < 8; i++) {
		snprintf(tag, sizeof tag, "enabled: cpu[%d] apic_id", i);
		EQ32(tag, (uint32_t)i, (uint32_t)madt_cpu_apic_id(i));
	}

	/* (7) Unknown entry types are skipped BY THEIR OWN LENGTH and counted.
	 * The entries after them prove the skip landed where it should. */
	tb_at(1);
	tb_hdr(0xFEE00000U, 1);
	tb_cpu(0, 0, 1);
	tb_raw(9, 16, 16, 0xC7);	/* Processor Local x2APIC */
	tb_cpu(1, 1, 1);
	tb_raw(3, 8, 8, 0x5A);		/* NMI Source */
	tb_raw(0x80, 20, 20, 0x33);	/* OEM reserved range */
	tb_raw(255, 2, 2, 0);		/* the smallest legal entry there is */
	tb_ioapic(0, 0xFEC00000U, 0);
	tb_raw(6, 16, 16, 0xC7);	/* I/O SAPIC */
	tb_iso(0, 0, 2, 0);
	len = tb_finish();
	EQI("skip: parse", MADT_OK, parse_at(ARENA + 1, len));
	EQI("skip: 5 undecoded entries counted", 5, madt_skipped());
	EQI("skip: both processors found", 2, madt_cpu_count());
	EQI("skip: the ioapic after them found", 1, madt_ioapic_count());
	EQ64("skip: and its address is right", 0xFEC00000ULL,
	     (uint64_t)madt_ioapic_addr(0));
	EQI("skip: the iso after them found", 1, madt_iso_count());
	EQI("skip: gsi_for_irq(0) still 2", 2, madt_gsi_for_irq(0));
	guard_check("skip");

	/* (8) A ZERO-LENGTH entry is fatal. If this is ever skipped instead,
	 * the walk never advances -- so reaching the next line at all is half
	 * the assertion. */
	tb_at(0);
	tb_hdr(0xFEE00000U, 1);
	tb_cpu(0, 0, 1);
	tb_raw(9, 0, 8, 0xC7);
	tb_cpu(1, 1, 1);
	len = tb_finish();
	EQI("zero-length entry refused", E_ENTRY_ZERO, parse_at(ARENA, len));
	check_empty("after zero-length entry");
	/* Length 1 is the same malformation and the same hazard. */
	tb_at(0);
	tb_hdr(0xFEE00000U, 1);
	tb_raw(9, 1, 8, 0xC7);
	len = tb_finish();
	EQI("length-1 entry refused", E_ENTRY_ZERO, parse_at(ARENA, len));
	/* Zero length on a type the module DOES decode. */
	tb_at(0);
	tb_hdr(0xFEE00000U, 1);
	tb_raw(0, 0, 8, 0);
	len = tb_finish();
	EQI("zero-length type 0 refused", E_ENTRY_ZERO, parse_at(ARENA, len));
	/* Zero length as the very last entry. */
	tb_at(0);
	tb_hdr(0xFEE00000U, 1);
	tb_cpu(0, 0, 1);
	tb_raw(4, 0, 2, 0);
	len = tb_finish();
	EQI("trailing zero-length entry refused", E_ENTRY_ZERO,
	    parse_at(ARENA, len));
	check_empty("after trailing zero-length entry");

	/* (9) An entry running past the end of the table is refused, not
	 * partially decoded. */
	tb_at(2);
	tb_hdr(0xFEE00000U, 1);
	tb_cpu(0, 0, 1);
	tb_raw(0, 8, 4, 0xC7);		/* claims 8, only 4 laid down */
	len = tb_finish();
	EQI("entry past the end refused", E_ENTRY_OVERRUN, parse_at(ARENA + 2, len));
	check_empty("after overrun");

	tb_at(2);
	tb_hdr(0xFEE00000U, 1);
	tb_cpu(0, 0, 1);
	tb_raw(9, 200, 6, 0xC7);
	len = tb_finish();
	EQI("far overrun refused", E_ENTRY_OVERRUN, parse_at(ARENA + 2, len));

	tb_at(2);
	tb_hdr(0xFEE00000U, 1);
	tb_cpu(0, 0, 1);
	tb_raw(9, 255, 2, 0);
	len = tb_finish();
	EQI("length 255 with 2 bytes left refused", E_ENTRY_OVERRUN,
	    parse_at(ARENA + 2, len));

	/* A dangling single byte: there is not even a length field to read. */
	tb_at(2);
	tb_hdr(0xFEE00000U, 1);
	tb_cpu(0, 0, 1);
	tb_raw(0, 8, 1, 0);
	len = tb_finish();
	EQI("dangling type byte refused", E_ENTRY_OVERRUN, parse_at(ARENA + 2, len));
	check_empty("after dangling byte");

	/* (10) An entry shorter than its own type demands: its tail would be
	 * read from the next entry, or from past the table. */
	{
		static const struct { uint32_t type, lenb; const char *n; }
		shorts[] = {
			{ 0, 7,  "type 0 with length 7" },
			{ 0, 2,  "type 0 with length 2" },
			{ 1, 11, "type 1 with length 11" },
			{ 1, 4,  "type 1 with length 4" },
			{ 2, 9,  "type 2 with length 9" },
			{ 4, 5,  "type 4 with length 5" },
			{ 4, 2,  "type 4 with length 2" },
			{ 5, 11, "type 5 with length 11" },
		};

		for (i = 0; i < (int)(sizeof shorts / sizeof shorts[0]); i++) {
			tb_at(4);
			tb_hdr(0xFEE00000U, 1);
			tb_cpu(0, 0, 1);
			tb_raw(shorts[i].type, shorts[i].lenb,
			       (int)shorts[i].lenb, 0xC7);
			tb_cpu(1, 1, 1);
			len = tb_finish();
			snprintf(tag, sizeof tag, "%s refused", shorts[i].n);
			EQI(tag, E_ENTRY_SHORT, parse_at(ARENA + 4, len));
			snprintf(tag, sizeof tag, "%s cleared the state",
				 shorts[i].n);
			EQI(tag, 0, madt_cpu_count());
		}
	}

	/* (11) Header rejections. */
	tb_at(0);
	tb_hdr(0xFEE00000U, 1);
	tb_cpu(0, 0, 1);
	len = tb_finish();
	EQI("sane table parses", MADT_OK, parse_at(ARENA, len));
	EQI("sane table has its cpu", 1, madt_cpu_count());

	ARENA[3] = 'Q';
	EQI("bad signature refused", E_SIG, parse_at(ARENA, len));
	check_empty("after bad signature");
	ARENA[3] = 'C';
	ARENA[0] = 'a';
	EQI("lowercase signature refused", E_SIG, parse_at(ARENA, len));
	ARENA[0] = 'X'; ARENA[1] = 'S'; ARENA[2] = 'D'; ARENA[3] = 'T';
	EQI("XSDT signature refused", E_SIG, parse_at(ARENA, len));
	ARENA[0] = 'A'; ARENA[1] = 'P'; ARENA[2] = 'I'; ARENA[3] = 'C';
	EQI("signature restored, table parses", MADT_OK, parse_at(ARENA, len));

	ARENA[9] = (uint8_t)(ARENA[9] + 1);
	EQI("bad checksum refused", E_CHECKSUM, parse_at(ARENA, len));
	check_empty("after bad checksum");
	ARENA[9] = (uint8_t)(ARENA[9] - 1);
	EQI("checksum restored, table parses", MADT_OK, parse_at(ARENA, len));
	/* Every single-byte corruption anywhere in the table must be caught. */
	for (i = 0; i < len; i += 3) {
		ARENA[i] = (uint8_t)(ARENA[i] + 1);
		snprintf(tag, sizeof tag, "checksum catches a flip at byte %d", i);
		EQI(tag, 1, parse_at(ARENA, len) != MADT_OK);
		ARENA[i] = (uint8_t)(ARENA[i] - 1);
	}
	EQI("after the corruption sweep the table still parses", MADT_OK,
	    parse_at(ARENA, len));

	/* Lengths. */
	EQI("len below 44 refused", E_LEN, parse_at(ARENA, 43));
	EQI("len 0 refused", E_LEN, parse_at(ARENA, 0));
	EQI("negative len refused", E_LEN, parse_at(ARENA, -1));
	EQI("len INT32_MIN refused", E_LEN, parse_at(ARENA, INT32_MIN));
	check_empty("after short len");
	EQI("null address refused", E_NULL, madt_parse(0, 4096));

	tb_at(0);
	tb_hdr(0xFEE00000U, 1);
	len = tb_finish();
	EQI("a 44-byte table with no entries is legal", MADT_OK,
	    parse_at(ARENA, len));
	EQI("44-byte table: no processors", 0, madt_cpu_count());
	EQ64("44-byte table: lapic_addr", 0xFEE00000ULL,
	     (uint64_t)madt_lapic_addr());

	/* The header's own length field. */
	tb_at(0);
	tb_hdr(0xFEE00000U, 1);
	tb_cpu(0, 0, 1);
	len = tb_finish();
	w32(4, 43);
	EQI("header length 43 refused", E_LEN, parse_at(ARENA, len));
	w32(4, 0);
	EQI("header length 0 refused", E_LEN, parse_at(ARENA, len));
	w32(4, 0x80000000U);
	EQI("header length with bit 31 set refused", E_LEN, parse_at(ARENA, len));
	w32(4, 0xFFFFFFFFU);
	EQI("header length all ones refused", E_LEN, parse_at(ARENA, len));
	w32(4, (uint32_t)(len + 1));
	EQI("header claiming one byte more than handed in refused", E_TRUNC,
	    parse_at(ARENA, len));
	w32(4, 4096);
	EQI("header claiming far more than handed in refused", E_TRUNC,
	    parse_at(ARENA, len));
	check_empty("after truncation refusal");
	w32(4, (uint32_t)len);
	EQI("length restored, table parses", MADT_OK, parse_at(ARENA, len));
	/* A caller that hands in MORE than the header claims is fine: the
	 * header's length is what bounds the walk. */
	EQI("extra slack past the table is ignored", MADT_OK,
	    parse_at(ARENA, len + 512));
	EQI("slack did not invent entries", 1, madt_cpu_count());

	/* (12) Ceilings: exactly the maximum is accepted, one more is REFUSED
	 * and not truncated. */
	tb_at(0);
	tb_hdr(0xFEE00000U, 1);
	for (i = 0; i < MAX_CPU; i++)
		tb_cpu((uint32_t)(i & 0xFF), (uint32_t)(i & 0xFF), 1);
	len = tb_finish();
	EQI("ceiling: 256 processors accepted", MADT_OK, parse_at(ARENA, len));
	EQI("ceiling: count is 256", MAX_CPU, madt_cpu_count());
	EQ32("ceiling: last processor", 255, (uint32_t)madt_cpu_apic_id(255));
	check_oob("ceiling cpu", MAX_CPU);
	tb_at(0);
	tb_hdr(0xFEE00000U, 1);
	for (i = 0; i <= MAX_CPU; i++)
		tb_cpu((uint32_t)(i & 0xFF), (uint32_t)(i & 0xFF), 1);
	len = tb_finish();
	EQI("ceiling: 257 processors refused", E_MANY_CPU, parse_at(ARENA, len));
	check_empty("after cpu ceiling");

	tb_at(0);
	tb_hdr(0xFEE00000U, 1);
	for (i = 0; i < MAX_IOAPIC; i++)
		tb_ioapic((uint32_t)i, 0xFEC00000U + (uint32_t)i * 0x1000U,
			  (uint32_t)(i * 24));
	len = tb_finish();
	EQI("ceiling: 16 ioapics accepted", MADT_OK, parse_at(ARENA, len));
	EQI("ceiling: ioapic count", MAX_IOAPIC, madt_ioapic_count());
	EQ64("ceiling: last ioapic addr", 0xFEC0F000ULL,
	     (uint64_t)madt_ioapic_addr(MAX_IOAPIC - 1));
	check_oob("ceiling ioapic", MAX_IOAPIC);
	tb_at(0);
	tb_hdr(0xFEE00000U, 1);
	for (i = 0; i <= MAX_IOAPIC; i++)
		tb_ioapic((uint32_t)i, 0xFEC00000U, 0);
	len = tb_finish();
	EQI("ceiling: 17 ioapics refused", E_MANY_IOAPIC, parse_at(ARENA, len));
	check_empty("after ioapic ceiling");

	tb_at(0);
	tb_hdr(0xFEE00000U, 1);
	for (i = 0; i < MAX_ISO; i++)
		tb_iso(0, (uint32_t)i, (uint32_t)(i + 100), 0x000D);
	len = tb_finish();
	EQI("ceiling: 64 isos accepted", MADT_OK, parse_at(ARENA, len));
	EQI("ceiling: iso count", MAX_ISO, madt_iso_count());
	EQI("ceiling: last iso override applies", MAX_ISO - 1 + 100,
	    madt_gsi_for_irq(MAX_ISO - 1));
	check_oob("ceiling iso", MAX_ISO);
	tb_at(0);
	tb_hdr(0xFEE00000U, 1);
	for (i = 0; i <= MAX_ISO; i++)
		tb_iso(0, (uint32_t)i, (uint32_t)i, 0);
	len = tb_finish();
	EQI("ceiling: 65 isos refused", E_MANY_ISO, parse_at(ARENA, len));
	check_empty("after iso ceiling");

	tb_at(0);
	tb_hdr(0xFEE00000U, 1);
	for (i = 0; i < MAX_NMI; i++)
		tb_nmi((uint32_t)(i & 0xFF), 0x8000U | (uint32_t)i, 1);
	len = tb_finish();
	EQI("ceiling: 256 nmis accepted", MADT_OK, parse_at(ARENA, len));
	EQI("ceiling: nmi count", MAX_NMI, madt_nmi_count());
	EQ32("ceiling: last nmi flags", 0x80FFU,
	     (uint32_t)madt_nmi_flags(MAX_NMI - 1));
	check_oob("ceiling nmi", MAX_NMI);
	tb_at(0);
	tb_hdr(0xFEE00000U, 1);
	for (i = 0; i <= MAX_NMI; i++)
		tb_nmi(0, 0, 1);
	len = tb_finish();
	EQI("ceiling: 257 nmis refused", E_MANY_NMI, parse_at(ARENA, len));
	check_empty("after nmi ceiling");
	guard_check("ceilings");

	/* (13) A failed parse must clear what a good one latched. */
	tb_at(0);
	len = build_qemu(ARENA);
	EQI("clearing: good parse first", MADT_OK, parse_at(ARENA, len));
	EQI("clearing: latched", 6, madt_cpu_count());
	ARENA[9] = (uint8_t)(ARENA[9] + 1);
	EQI("clearing: bad checksum", E_CHECKSUM, parse_at(ARENA, len));
	check_empty("clearing: after the failure");
	ARENA[9] = (uint8_t)(ARENA[9] - 1);
	EQI("clearing: re-parses", MADT_OK, parse_at(ARENA, len));
	check_qemu("clearing: restored");

	/* (14) Random tables, random entry order, random bit patterns. */
	fuzz_model(200);

	/* (15) The table against a PROT_NONE page. */
	tail_page();

	/* (16) Back to the ground truth: nothing above left state behind. */
	tb_at(5);
	len = build_qemu(ARENA + 5);
	EQI("final: parse", MADT_OK, parse_at(ARENA + 5, len));
	check_qemu("final");
	guard_check("final");


	/* REGRESSION, found by adversarial review of roadmap 4.1 and reproduced
	 * there as a SIGSEGV. The entry-walk guards were `off + elen > hlen` in
	 * signed 32-bit; hlen was accepted to huge(int32), so the sum wrapped
	 * NEGATIVE under -fwrapv, the guard passed, and off indexed ~2 GiB BELOW
	 * the table. The guards subtract now (hlen - off is positive because
	 * off < hlen is the loop condition), and a length cap keeps every
	 * table-controlled offset far from the wrap point. */
	EQI("regress: a length at huge(int32) is refused, not walked",
	    E_LEN, parse_at(ARENA, INT32_MAX));
	EQI("regress: one byte past the length cap is refused",
	    E_LEN, parse_at(ARENA, LEN_MAX + 1));
	FK_EQ("regress: exactly the cap is not refused for LENGTH alone",
	      1, parse_at(ARENA, LEN_MAX) != E_LEN, "%d");

	return fk_report("madt");
}
