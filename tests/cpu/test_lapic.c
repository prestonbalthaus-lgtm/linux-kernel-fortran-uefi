/* Reference-model test for src/cpu/fk_lapic.f90.
 *
 * There is no C oracle (mk/lapic.mk says why), so the model is here: two
 * 4 KiB pages of ordinary memory stand in for the LAPIC's MMIO window, every
 * word of them is predicted, and every word is compared after each operation.
 * That is what proves the driver wrote the nine registers it should have and
 * NOTHING else -- guard pages either side catch anything that leaves the 4 KiB.
 *
 * RDMSR/WRMSR are ring 0 and would SIGILL here, so IA32_APIC_BASE is modelled
 * too -- exactly as tests/drivers/serial/test_serial.c mocks fk_outb/fk_inb
 * instead of assembling boot/io.S.
 */
#include <stdlib.h>
#include <string.h>
#include "fk_test.h"

/* Fortran bind(c) exports.  base is a VIRTUAL address; the driver maps
 * nothing and reads no MSR to find it. */
void    lapic_init(int64_t base, int32_t spurious_vector);
int32_t lapic_max_lvt(int64_t base);
void    lapic_eoi(int64_t base);
int32_t lapic_id(int64_t base);
int32_t lapic_version(int64_t base);
int32_t lapic_svr(int64_t base);
int32_t lapic_lvt_cmci(int64_t base);
int32_t lapic_lvt_timer(int64_t base);
int32_t lapic_lvt_thermal(int64_t base);
int32_t lapic_lvt_perf(int64_t base);
int32_t lapic_lvt_lint0(int64_t base);
int32_t lapic_lvt_lint1(int64_t base);
int32_t lapic_lvt_error(int64_t base);
int64_t lapic_msr_base(void);
int32_t lapic_msr_enabled(void);
int32_t lapic_msi_addr(int32_t dest);
int32_t lapic_msi_data(int32_t vector);

/* Supplied by boot/mmu.S in the kernel; by the model below here. */
int64_t fk_rdmsr(int32_t msr);

/* boot/io.S's MMIO accessors.  fk_lapic_m reaches every register through these
 * rather than through a volatile Fortran pointer, because -O2 narrows such a
 * pointer's load when only some of its bits are used -- and a one-byte read of
 * a local APIC register is undefined (SDM Vol.3 11.4.1).  Supplied here for
 * the same reason fk_rdmsr is: assembling boot/io.S into a host test would
 * drag in the port-I/O instructions with it. */
int32_t fk_readl(int64_t addr);
void    fk_writel(int64_t addr, int32_t v);

int32_t fk_readl(int64_t addr)
{
	return *(volatile int32_t *)(uintptr_t)addr;
}

void fk_writel(int64_t addr, int32_t v)
{
	*(volatile int32_t *)(uintptr_t)addr = v;
}
void    fk_wrmsr(int32_t msr, int64_t value);

/* --- the modelled MSR ---------------------------------------------------- */

#define IA32_APIC_BASE	0x1B
#define APIC_BASE_BSP	(1u << 8)
#define APIC_BASE_EN	(1u << 11)

static uint64_t	     msr_apic_base;
static unsigned long msr_reads, msr_writes, msr_wrong_reg;

int64_t fk_rdmsr(int32_t msr)
{
	msr_reads++;
	if (msr != IA32_APIC_BASE)
		msr_wrong_reg++;
	return (int64_t)msr_apic_base;
}

void fk_wrmsr(int32_t msr, int64_t value)
{
	msr_writes++;
	if (msr != IA32_APIC_BASE)
		msr_wrong_reg++;
	msr_apic_base = (uint64_t)value;
}

static void msr_set(uint64_t v)
{
	msr_apic_base = v;
	msr_reads = msr_writes = msr_wrong_reg = 0;
}

/* --- the modelled register page ------------------------------------------ */

#define PAGE		4096u
#define NWORDS		(PAGE / 4u)
#define W(off)		((off) / 4u)

#define R_ID		0x020u
#define R_VERSION	0x030u
#define R_TPR		0x080u
#define R_EOI		0x0B0u
#define R_SVR		0x0F0u
#define R_LVT_CMCI	0x2F0u
#define R_LVT_TIMER	0x320u
#define R_LVT_THERMAL	0x330u
#define R_LVT_PERF	0x340u
#define R_LVT_LINT0	0x350u
#define R_LVT_LINT1	0x360u
#define R_LVT_ERROR	0x370u

#define LVT_MASKED	0x00010000u	/* bit 16 */
#define LVT_DM_MASK	0x00000700u	/* bits 10:8 */
#define LVT_DM_EXTINT	0x00000700u	/* what firmware leaves in LINT0 */
#define SVR_ENABLE	0x00000100u	/* bit 8 */

#define SPURIOUS	0xFFu		/* bit 7 set: exercises the high vector bit */

/* guard | pageA | guard | pageB | guard, all 4 KiB, the whole slab aligned. */
#define SLAB_PAGES	5u
#define GUARD_BYTE	0x5A

static unsigned char *slab;
static uint32_t      *pageA, *pageB;
static int64_t	      BASE_A, BASE_B;
static uint32_t	      model[NWORDS];

static const unsigned guard_at[3] = { 0u, 2u * PAGE, 4u * PAGE };

static void page_fill(uint32_t *p, uint32_t tag)
{
	unsigned i;

	/* Distinct and non-zero in every word: a register the driver must NOT
	 * touch cannot pass by accident, and "TPR is zero" means something. */
	for (i = 0; i < NWORDS; i++)
		p[i] = tag | i;
}

static void model_sync(void) { memcpy(model, pageA, PAGE); }

static void slab_reset(void)
{
	unsigned g;

	for (g = 0; g < 3; g++)
		memset(slab + guard_at[g], GUARD_BYTE, PAGE);
	page_fill(pageA, 0xA5000000u);
	page_fill(pageB, 0x5C000000u);
	model_sync();
}

static void guard_check(const char *what)
{
	unsigned g, i;
	unsigned long bad = 0;

	for (g = 0; g < 3; g++)
		for (i = 0; i < PAGE; i++)
			if (slab[guard_at[g] + i] != GUARD_BYTE)
				bad++;
	fk_checks++;
	if (bad) {
		printf("  GUARD %s: %lu byte(s) written outside the 4 KiB page\n",
		       what, bad);
		fk_fails++;
	}
}

static void page_check(const char *what)
{
	unsigned i;
	unsigned long before = fk_fails;

	for (i = 0; i < NWORDS; i++) {
		fk_checks++;
		if (pageA[i] != model[i]) {
			if (fk_fails - before < 8)
				printf("  PAGE %s: +0x%03X is 0x%08X, model 0x%08X\n",
				       what, i * 4u, pageA[i], model[i]);
			fk_fails++;
		}
	}
	guard_check(what);
}

/* The nine registers lapic_init is allowed to write, and nothing else. */
static void model_init(uint32_t vector, uint32_t max_lvt)
{
	model[W(R_TPR)]		= 0u;
	/* CMCI exists only where VERSION bits 23:16 report at least 6 LVT
	 * entries.  Below that the register is absent and must not be written. */
	if (max_lvt >= 6u)
		model[W(R_LVT_CMCI)] = LVT_MASKED;
	model[W(R_LVT_TIMER)]	= LVT_MASKED;
	model[W(R_LVT_THERMAL)]	= LVT_MASKED;
	model[W(R_LVT_PERF)]	= LVT_MASKED;
	model[W(R_LVT_LINT0)]	= LVT_MASKED;
	model[W(R_LVT_LINT1)]	= LVT_MASKED;
	model[W(R_LVT_ERROR)]	= LVT_MASKED;
	model[W(R_SVR)]		= (vector & 0xFFu) | SVR_ENABLE;
}

struct lvt_reg {
	const char *name;
	uint32_t    off;
	int32_t   (*read)(int64_t);
};

static const struct lvt_reg LVTS[] = {
	{ "LVT CMCI",	 R_LVT_CMCI,	lapic_lvt_cmci	  },
	{ "LVT timer",	 R_LVT_TIMER,	lapic_lvt_timer	  },
	{ "LVT thermal", R_LVT_THERMAL,	lapic_lvt_thermal },
	{ "LVT perfmon", R_LVT_PERF,	lapic_lvt_perf	  },
	{ "LVT LINT0",	 R_LVT_LINT0,	lapic_lvt_lint0	  },
	{ "LVT LINT1",	 R_LVT_LINT1,	lapic_lvt_lint1	  },
	{ "LVT error",	 R_LVT_ERROR,	lapic_lvt_error	  },
};
#define NLVT (sizeof(LVTS) / sizeof(LVTS[0]))

int main(void)
{
	unsigned i;

	slab = aligned_alloc(PAGE, SLAB_PAGES * PAGE);
	if (!slab) {
		printf("  aligned_alloc failed\n");
		return 1;
	}
	pageA  = (uint32_t *)(slab + 1u * PAGE);
	pageB  = (uint32_t *)(slab + 3u * PAGE);
	BASE_A = (int64_t)(uintptr_t)pageA;
	BASE_B = (int64_t)(uintptr_t)pageB;

	/* (1) IA32_APIC_BASE.  The MSR half is separate from the MMIO half on
	 * purpose: the kernel calls these, maps the page, and only then hands a
	 * virtual address to lapic_init. */
	msr_set(0xFEE00000ULL | APIC_BASE_EN | APIC_BASE_BSP);
	FK_EQ("msr: conventional base 0xFEE00000", 0xFEE00000ULL,
	      (unsigned long long)lapic_msr_base(), "0x%016llX");
	FK_EQ("msr: enable bit 11 set", 1, (int)lapic_msr_enabled(), "%d");
	FK_EQ("msr: only IA32_APIC_BASE was read", 0UL, msr_wrong_reg, "%lu");
	FK_EQ("msr: base cost one RDMSR each", 2UL, msr_reads, "%lu");

	msr_set(0xFEE00000ULL | APIC_BASE_BSP);
	FK_EQ("msr: enable bit clear", 0, (int)lapic_msr_enabled(), "%d");
	FK_EQ("msr: base survives a disabled APIC", 0xFEE00000ULL,
	      (unsigned long long)lapic_msr_base(), "0x%016llX");

	/* Bit 51 is the top of the 51:12 field: the mask itself carries it. */
	msr_set(0x0008000000000000ULL | 0xFEE00000ULL | APIC_BASE_EN | APIC_BASE_BSP);
	FK_EQ("msr: bit 51 of the base survives", 0x00080000FEE00000ULL,
	      (unsigned long long)lapic_msr_base(), "0x%016llX");

	/* Bits 63:52 are reserved.  This is the case that separates SHIFTR from
	 * SHIFTA: with the sign bit set, an arithmetic shift smears the reserved
	 * bits over the whole address. */
	msr_set(0xFFF0000000000000ULL | 0xFEE00000ULL | APIC_BASE_EN | APIC_BASE_BSP);
	FK_EQ("msr: reserved bits 63:52 masked off, not sign-extended",
	      0x00000000FEE00000ULL, (unsigned long long)lapic_msr_base(),
	      "0x%016llX");
	FK_EQ("msr: enable bit still readable with the sign bit set", 1,
	      (int)lapic_msr_enabled(), "%d");

	/* Bits 11:0 are flags, never address. */
	msr_set(0x0000000FEE00FFFULL);
	FK_EQ("msr: low 12 bits are not part of the base", 0x0000000FEE00000ULL,
	      (unsigned long long)lapic_msr_base(), "0x%016llX");

	msr_set(0xFFFFFFFFFFFFFFFFULL);
	FK_EQ("msr: every base bit set", 0x000FFFFFFFFFF000ULL,
	      (unsigned long long)lapic_msr_base(), "0x%016llX");

	/* fk_wrmsr's ABI, round-tripped through the same model. */
	msr_set(0ULL);
	fk_wrmsr(IA32_APIC_BASE, (int64_t)(0xFEE00000ULL | APIC_BASE_EN));
	FK_EQ("msr: one WRMSR recorded", 1UL, msr_writes, "%lu");
	FK_EQ("msr: WRMSR value read back", 0xFEE00000ULL,
	      (unsigned long long)lapic_msr_base(), "0x%016llX");
	FK_EQ("msr: WRMSR named IA32_APIC_BASE", 0UL, msr_wrong_reg, "%lu");

	/* (2) Bring-up.  LINT0 is preloaded with the ExtINT delivery mode the
	 * firmware leaves there -- the path the masked 8259 still reaches the
	 * CPU through -- so a driver that fails to overwrite it is visible. */
	slab_reset();
	pageA[W(R_LVT_LINT0)] = LVT_DM_EXTINT;
	pageA[W(R_VERSION)]   = 0x00060014u;	/* Max LVT 6: CMCI present */
	model_sync();
	FK_EQ("pre-init: LINT0 really is ExtINT", LVT_DM_EXTINT,
	      pageA[W(R_LVT_LINT0)] & LVT_DM_MASK, "0x%08X");

	msr_set(0xFEE00000ULL | APIC_BASE_EN);
	lapic_init(BASE_A, (int32_t)SPURIOUS);
	model_init(SPURIOUS, 6u);
	page_check("lapic_init");

	/* The architectural split, asserted rather than assumed. */
	FK_EQ("init: read no MSR", 0UL, msr_reads, "%lu");
	FK_EQ("init: wrote no MSR", 0UL, msr_writes, "%lu");

	/* (3) SVR: vector in 7:0 AND the software-enable bit. */
	FK_EQ("init: SVR whole register", SPURIOUS | SVR_ENABLE,
	      pageA[W(R_SVR)], "0x%08X");
	FK_EQ("init: SVR spurious vector in bits 7:0", SPURIOUS,
	      pageA[W(R_SVR)] & 0xFFu, "0x%02X");
	FK_EQ("init: SVR bit 8, APIC software enable", SVR_ENABLE,
	      pageA[W(R_SVR)] & SVR_ENABLE, "0x%08X");

	/* (4) TPR: nothing blocked by priority. */
	FK_EQ("init: TPR zeroed", 0u, pageA[W(R_TPR)], "0x%08X");

	/* (5) Every LVT, one at a time. */
	FK_EQ("init: LVT CMCI    masked", LVT_MASKED, pageA[W(R_LVT_CMCI)],    "0x%08X");
	FK_EQ("init: LVT timer   masked", LVT_MASKED, pageA[W(R_LVT_TIMER)],   "0x%08X");
	FK_EQ("init: LVT thermal masked", LVT_MASKED, pageA[W(R_LVT_THERMAL)], "0x%08X");
	FK_EQ("init: LVT perfmon masked", LVT_MASKED, pageA[W(R_LVT_PERF)],    "0x%08X");
	FK_EQ("init: LVT LINT0   masked", LVT_MASKED, pageA[W(R_LVT_LINT0)],   "0x%08X");
	FK_EQ("init: LVT LINT1   masked", LVT_MASKED, pageA[W(R_LVT_LINT1)],   "0x%08X");
	FK_EQ("init: LVT error   masked", LVT_MASKED, pageA[W(R_LVT_ERROR)],   "0x%08X");

	for (i = 0; i < NLVT; i++) {
		FK_EQ(LVTS[i].name, LVT_MASKED,
		      pageA[W(LVTS[i].off)] & LVT_MASKED, "0x%08X");
		FK_EQ(LVTS[i].name, 0u,
		      pageA[W(LVTS[i].off)] & LVT_DM_MASK, "0x%08X");
	}

	/* LINT0 specifically: masked AND no longer delivering as ExtINT. */
	FK_EQ("init: LINT0 mask bit 16 set", LVT_MASKED,
	      pageA[W(R_LVT_LINT0)] & LVT_MASKED, "0x%08X");
	FK_EQ("init: LINT0 out of ExtINT delivery mode", 0u,
	      pageA[W(R_LVT_LINT0)] & LVT_DM_MASK, "0x%08X");
	FK_EQ("init: LINT0 overwritten whole, not read-modify-written",
	      LVT_MASKED, pageA[W(R_LVT_LINT0)], "0x%08X");

	/* (6) Readback accessors report the page, and reading changes nothing. */
	FK_EQ("readback: SVR", pageA[W(R_SVR)], (uint32_t)lapic_svr(BASE_A), "0x%08X");
	for (i = 0; i < NLVT; i++)
		FK_EQ(LVTS[i].name, pageA[W(LVTS[i].off)],
		      (uint32_t)LVTS[i].read(BASE_A), "0x%08X");
	page_check("readback accessors are read-only");

	/* A second vector, to prove the vector is the argument and not a
	 * constant that happened to match. */
	slab_reset();
	pageA[W(R_VERSION)] = 0x00060014u;
	model_sync();
	lapic_init(BASE_A, 0x20);
	model_init(0x20u, 6u);
	page_check("lapic_init(vector 0x20)");
	FK_EQ("init: SVR carries the caller's vector", 0x20u | SVR_ENABLE,
	      pageA[W(R_SVR)], "0x%08X");

	/* Only bits 7:0 of the vector reach the register; bit 8 is the enable. */
	slab_reset();
	pageA[W(R_VERSION)] = 0x00060014u;
	model_sync();
	lapic_init(BASE_A, (int32_t)0xFFFFFF7Fu);
	model_init(0x7Fu, 6u);
	page_check("lapic_init(vector with high bits set)");
	FK_EQ("init: vector truncated to 8 bits", 0x7Fu | SVR_ENABLE,
	      pageA[W(R_SVR)], "0x%08X");

	/* Max LVT 5 -- what QEMU's LAPIC actually reports, and what the
	 * Minisforum's may.  CMCI does not exist there, so init must LEAVE IT
	 * ALONE: an MMIO write to an absent register is not a no-op by
	 * contract.  The poison the reset left behind is what proves it. */
	slab_reset();
	pageA[W(R_VERSION)]  = 0x00050014u;
	pageA[W(R_LVT_CMCI)] = 0xDEADBEEFu;
	model_sync();
	lapic_init(BASE_A, (int32_t)SPURIOUS);
	model_init(SPURIOUS, 5u);
	page_check("lapic_init(Max LVT 5: CMCI absent)");
	FK_EQ("init: Max LVT read from VERSION bits 23:16", 5,
	      lapic_max_lvt(BASE_A), "%d");
	FK_EQ("init: CMCI untouched when the register does not exist",
	      0xDEADBEEFu, pageA[W(R_LVT_CMCI)], "0x%08X");
	FK_EQ("init: the other LVTs are still masked", LVT_MASKED,
	      pageA[W(R_LVT_TIMER)], "0x%08X");

	/* (7) EOI: zero to 0x0B0 and not one other byte of the page. */
	slab_reset();
	pageA[W(R_EOI)] = 0xDEADBEEFu;
	model_sync();
	lapic_eoi(BASE_A);
	model[W(R_EOI)] = 0u;
	page_check("lapic_eoi");
	FK_EQ("eoi: zero written to +0x0B0", 0u, pageA[W(R_EOI)], "0x%08X");

	/* Repeated EOI is what an interrupt gate actually does. */
	for (i = 0; i < 64; i++)
		lapic_eoi(BASE_A);
	page_check("lapic_eoi x64");

	/* (8) ID and VERSION, from preloaded values with bit 31 set.  The ID is
	 * bits 31:24: SHIFTA there would return 0xFFFFFF87 for 0x87654321. */
	slab_reset();
	pageA[W(R_ID)]	    = 0x87654321u;
	pageA[W(R_VERSION)] = 0x80050014u;
	model_sync();
	FK_EQ("id: bits 31:24 of 0x87654321, no sign extension", 0x87u,
	      (uint32_t)lapic_id(BASE_A), "0x%08X");
	FK_EQ("version: raw register with bit 31 set", 0x80050014u,
	      (uint32_t)lapic_version(BASE_A), "0x%08X");

	pageA[W(R_ID)]	    = 0xFF000000u;
	pageA[W(R_VERSION)] = 0x00050014u;
	model_sync();
	FK_EQ("id: 0xFF is the largest xAPIC ID", 0xFFu,
	      (uint32_t)lapic_id(BASE_A), "0x%08X");
	FK_EQ("version: max LVT entry 5, version 0x14", 0x00050014u,
	      (uint32_t)lapic_version(BASE_A), "0x%08X");

	pageA[W(R_ID)]	    = 0x00000000u;
	pageA[W(R_VERSION)] = 0xFFFFFFFFu;
	model_sync();
	FK_EQ("id: BSP is APIC ID 0", 0x00u, (uint32_t)lapic_id(BASE_A), "0x%08X");
	FK_EQ("version: all bits set comes back whole", 0xFFFFFFFFu,
	      (uint32_t)lapic_version(BASE_A), "0x%08X");

	pageA[W(R_ID)] = 0x0F123456u;
	model_sync();
	FK_EQ("id: low 24 bits are not the ID", 0x0Fu,
	      (uint32_t)lapic_id(BASE_A), "0x%08X");
	page_check("id/version reads are read-only");

	/* (9) The base is an ARGUMENT, not module state: the same accessors on a
	 * second page must answer from that page, and bringing it up must leave
	 * the first alone. */
	slab_reset();
	pageA[W(R_ID)]	    = 0x11000000u;
	pageB[W(R_ID)]	    = 0x22000000u;
	pageA[W(R_VERSION)] = 0x00050014u;
	pageB[W(R_VERSION)] = 0x00060015u;
	model_sync();
	FK_EQ("two bases: ID from page A", 0x11u, (uint32_t)lapic_id(BASE_A), "0x%08X");
	FK_EQ("two bases: ID from page B", 0x22u, (uint32_t)lapic_id(BASE_B), "0x%08X");
	FK_EQ("two bases: VERSION from page A", 0x00050014u,
	      (uint32_t)lapic_version(BASE_A), "0x%08X");
	FK_EQ("two bases: VERSION from page B", 0x00060015u,
	      (uint32_t)lapic_version(BASE_B), "0x%08X");

	lapic_init(BASE_B, 0x30);
	FK_EQ("two bases: init(B) wrote B's SVR", 0x30u | SVR_ENABLE,
	      pageB[W(R_SVR)], "0x%08X");
	FK_EQ("two bases: init(B) masked B's LINT0", LVT_MASKED,
	      pageB[W(R_LVT_LINT0)], "0x%08X");
	page_check("init(B) left page A untouched");
	lapic_eoi(BASE_B);
	page_check("eoi(B) left page A untouched");

	/* THE MESSAGE, and it is an address a device WRITES rather than a wire
	 * it pulls. Nothing here touches the chip: it is bit layout, and the
	 * two ways to get it wrong are shifting the destination into 19:12 by
	 * the wrong amount and letting a destination above 255 climb into the
	 * fixed 0FEEh prefix that makes the write land on the APIC bus at
	 * all. */
	FK_EQ("MSI address for CPU 0", 0xFEE00000u,
	      (uint32_t)lapic_msi_addr(0), "0x%08X");
	FK_EQ("CPU 1 is bit 12, not bit 0", 0xFEE01000u,
	      (uint32_t)lapic_msi_addr(1), "0x%08X");
	FK_EQ("CPU 5, the last of this machine's six", 0xFEE05000u,
	      (uint32_t)lapic_msi_addr(5), "0x%08X");
	FK_EQ("CPU 255 fills the field exactly", 0xFEEFF000u,
	      (uint32_t)lapic_msi_addr(255), "0x%08X");
	FK_EQ("and 256 does NOT reach the 0FEEh prefix", 0xFEE00000u,
	      (uint32_t)lapic_msi_addr(256), "0x%08X");

	FK_EQ("the data word is the vector", 0x30u,
	      (uint32_t)lapic_msi_data(0x30), "0x%08X");
	FK_EQ("delivery mode and trigger stay zero -- FIXED, EDGE", 0xFFu,
	      (uint32_t)lapic_msi_data(0xFF), "0x%08X");
	FK_EQ("nothing above the vector byte survives", 0x30u,
	      (uint32_t)lapic_msi_data(0x8730), "0x%08X");

	free(slab);
	return fk_report("lapic");
}
