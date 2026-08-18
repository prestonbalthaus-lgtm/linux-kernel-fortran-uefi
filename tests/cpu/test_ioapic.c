/* Reference-model test for src/cpu/fk_ioapic.f90.
 *
 * The I/O APIC is INDEXED: a write to IOREGSEL at +0x00 names a register and
 * the next access to IOWIN at +0x10 reads or writes the one it named.  A flat
 * buffer cannot model that -- which is why this file models the REGISTER FILE
 * instead, underneath fk_readl/fk_writel.  The module reaches the chip through
 * those two and nothing else, so supplying them here makes the whole of it
 * testable on the host: the arithmetic, the sequencing, and the order in which
 * a redirection entry's two dwords are written.
 *
 * Those accessors are assembly in the kernel (boot/io.S) and that is the
 * milestone's other finding.  fk_ioapic_m used to reach IOWIN through a
 * VOLATILE Fortran pointer, and gfortran -O2 narrowed
 * ibits(reg_read(REG_VER), 16, 8) into `movzbl 0x2(%rax)` -- a ONE-BYTE read
 * of a 32-bit window.  QEMU answers that with zero, so ioapic_max_redir
 * reported 1 entry instead of 24 and every route was refused with E_GSI.
 * VOLATILE forbids eliminating and reordering an access, not narrowing one.
 *
 * There is no C oracle.  Linux reaches the same dwords through a struct of
 * bitfields whose layout is the compiler's business rather than the
 * datasheet's, so it is a second opinion and not something that can be linked
 * and diffed.  The reference is the 82093AA datasheet tables 2 and 3, written
 * out by hand below, with the register file QEMU presents as its values.
 */
#include <stdint.h>
#include <string.h>
#include "fk_test.h"

int32_t ioapic_redir_lo(int32_t vector, int32_t polarity, int32_t trigger,
			int32_t masked);
int32_t ioapic_redir_hi(int32_t apic_id);
void    ioapic_set_window(int64_t virt);
int32_t ioapic_ready(void);
int32_t ioapic_id(void);
int32_t ioapic_version(void);
int32_t ioapic_max_redir(void);
int32_t ioapic_read_lo(int32_t gsi);
int32_t ioapic_read_hi(int32_t gsi);
int32_t ioapic_route(int32_t gsi, int32_t vector, int32_t apic_id,
		     int32_t polarity, int32_t trigger);
int32_t ioapic_mask(int32_t gsi);
int32_t ioapic_unmask(int32_t gsi);

int32_t fk_readl(int64_t addr);
void    fk_writel(int64_t addr, int32_t v);

#define EQ32(what, a, b) FK_EQ(what, (unsigned)(a), (unsigned)(b), "0x%X")
#define EQI(what, a, b)  FK_EQ(what, (int)(a), (int)(b), "%d")

enum { IOAPIC_OK = 0, E_NOT_READY = 1, E_GSI = 2, E_VECTOR = 3 };
enum { PINS = 24, REG_ID = 0x00, REG_VER = 0x01, REG_REDIR = 0x10 };

/* --- the register file, as QEMU's device model presents it ---------------- */
/* The window the module is pointed at.  Not a real mapping: fk_readl below
 * decodes the offset rather than dereferencing, so nothing here needs a page. */
#define FAKE_WIN 0x0000700000000000LL

static uint32_t g_sel;                  /* the IOREGSEL latch */
static uint32_t g_redir[PINS * 2];      /* 24 entries, low dword then high */
static int g_win_reads, g_win_writes;

/* Every IOWIN write, in order, as (register, value).  ioapic_route's whole
 * safety argument is about ORDER, and order is not visible in the final state. */
#define LOG_MAX 64
static struct { uint32_t reg, val; } g_log[LOG_MAX];
static int g_log_n;

static void model_reset(void)
{
	int i;

	g_sel = 0;
	g_win_reads = g_win_writes = g_log_n = 0;
	/* Power-on state: every entry masked, everything else zero.  Bit 16 is
	 * the mask bit, and the datasheet says it comes up set. */
	for (i = 0; i < PINS; i++) {
		g_redir[i * 2] = 1u << 16;
		g_redir[i * 2 + 1] = 0;
	}
}

static uint32_t model_read(uint32_t reg)
{
	if (reg == REG_ID)
		return 0;                       /* id 0, in bits 27:24 */
	if (reg == REG_VER)
		return 0x00170011u;             /* version 0x11, 23 = PINS - 1 */
	if (reg >= REG_REDIR && reg < REG_REDIR + PINS * 2)
		return g_redir[reg - REG_REDIR];
	return 0xFFFFFFFFu;                     /* nothing there */
}

static void model_write(uint32_t reg, uint32_t val)
{
	if (reg >= REG_REDIR && reg < REG_REDIR + PINS * 2)
		g_redir[reg - REG_REDIR] = val;
}

int32_t fk_readl(int64_t addr)
{
	int64_t off = addr - FAKE_WIN;

	if (off == 0x00)
		return (int32_t)g_sel;
	if (off == 0x10) {
		g_win_reads++;
		return (int32_t)model_read(g_sel);
	}
	return -1;
}

void fk_writel(int64_t addr, int32_t v)
{
	int64_t off = addr - FAKE_WIN;

	if (off == 0x00) {
		g_sel = (uint32_t)v;
		return;
	}
	if (off == 0x10) {
		g_win_writes++;
		if (g_log_n < LOG_MAX) {
			g_log[g_log_n].reg = g_sel;
			g_log[g_log_n].val = (uint32_t)v;
			g_log_n++;
		}
		model_write(g_sel, (uint32_t)v);
	}
}

/* --- the reference encoder, from the datasheet and not from the Fortran ---- */
static uint32_t ref_lo(int vec, int pol, int trig, int masked)
{
	uint32_t v;

	if (vec < 16 || vec > 255)
		return 0;
	v = (uint32_t)vec & 0xFF;
	if (pol)
		v |= 1u << 13;
	if (trig)
		v |= 1u << 15;
	if (masked)
		v |= 1u << 16;
	return v;
}

static void test_encoders(void)
{
	int vec, pol, trig, msk, i;

	/* The entry roadmap 3.3 actually writes: the PIT on vector 0x20,
	 * active high, edge, unmasked.  Nothing set above the vector field. */
	EQ32("the PIT's own entry", 0x20, ioapic_redir_lo(0x20, 0, 0, 0));
	EQ32("masked is bit 16 and nothing else", 0x10020,
	     ioapic_redir_lo(0x20, 0, 0, 1));
	EQ32("a PCI line's polarity and trigger", 0xA030,
	     ioapic_redir_lo(0x30, 1, 1, 0));
	EQ32("all three at once", 0x1A0FF, ioapic_redir_lo(0xFF, 1, 1, 1));

	for (vec = 0; vec < 256; vec++)
		for (pol = 0; pol < 2; pol++)
			for (trig = 0; trig < 2; trig++)
				for (msk = 0; msk < 2; msk++)
					EQ32("low dword",
					     ref_lo(vec, pol, trig, msk),
					     ioapic_redir_lo(vec, pol, trig, msk));

	/* A vector the CPU owns is REFUSED, not encoded.  Vectors 0..31 are the
	 * architectural exceptions; one delivered from an I/O APIC raises a
	 * fault whose stack frame lies about where it came from. */
	for (vec = 0; vec < 16; vec++)
		EQ32("a vector below 16 is refused", 0,
		     ioapic_redir_lo(vec, 0, 0, 0));
	EQ32("vector 16 is the first accepted", 0x10,
	     ioapic_redir_lo(16, 0, 0, 0));
	EQ32("a vector above 255 is refused", 0, ioapic_redir_lo(256, 0, 0, 0));
	EQ32("a negative vector is refused", 0, ioapic_redir_lo(-1, 0, 0, 0));

	EQ32("destination 0", 0x00000000, ioapic_redir_hi(0));
	EQ32("destination 255", 0xFF000000, ioapic_redir_hi(255));
	for (i = 0; i < 256; i++)
		EQ32("destination", (uint32_t)i << 24, ioapic_redir_hi(i));
	/* Bits above the field are dropped rather than carried into nothing. */
	EQ32("an id wider than the field is truncated", 0x00000000,
	     ioapic_redir_hi(256));
	EQ32("and so is one just above it", 0x01000000, ioapic_redir_hi(257));
}

static void test_no_window(void)
{
	/* WITH NO WINDOW SET, NOTHING IS DEREFERENCED.  Every accessor answers
	 * a refusal, which is what lets this file link at all. */
	ioapic_set_window(0);
	EQI("no window means not ready", 0, ioapic_ready());
	EQ32("id with no window", 0, ioapic_id());
	EQ32("version with no window", 0, ioapic_version());
	EQ32("max_redir with no window", 0, ioapic_max_redir());
	EQ32("read_lo with no window", 0, ioapic_read_lo(2));
	EQ32("read_hi with no window", 0, ioapic_read_hi(2));
	EQ32("route with no window", E_NOT_READY, ioapic_route(2, 0x20, 0, 0, 0));
	EQ32("mask with no window", E_NOT_READY, ioapic_mask(2));
	EQ32("unmask with no window", E_NOT_READY, ioapic_unmask(2));
	EQI("and nothing reached the window", 0, g_win_reads + g_win_writes);
}

static void test_identity(void)
{
	model_reset();
	ioapic_set_window(FAKE_WIN);
	EQI("a window makes it ready", 1, ioapic_ready());

	/* THE READ THAT WAS BROKEN.  0x00170011: version in 7:0, and the
	 * highest redirection index in 23:16, which is PINS - 1.  A narrowed
	 * one-byte read of this register is what reported 1 entry. */
	EQ32("the chip id", 0x00, ioapic_id());
	EQ32("the chip version", 0x11, ioapic_version());
	EQI("the entry count, from bits 23:16 plus one", PINS, ioapic_max_redir());
}

static void test_routing(void)
{
	int i, gsi = 2, vec = 0x20;

	model_reset();
	ioapic_set_window(FAKE_WIN);

	EQ32("routing GSI 2 to vector 0x20", IOAPIC_OK,
	     ioapic_route(gsi, vec, 0, 0, 0));
	EQ32("the entry reads back as written", 0x20, ioapic_read_lo(gsi));
	EQ32("aimed at the BSP", 0x00000000, ioapic_read_hi(gsi));

	/* Every OTHER entry is untouched and still masked.  A route that wrote
	 * the wrong register index leaves this false. */
	for (i = 0; i < PINS; i++) {
		if (i == gsi)
			continue;
		EQ32("another entry is untouched", 1u << 16,
		     (unsigned)ioapic_read_lo(i));
	}

	/* THE ORDER, which the final state cannot show.  The mask bit lives in
	 * the LOW dword, so an entry written low-first is briefly unmasked with
	 * a destination that has not been set yet -- and a line that asserts in
	 * that window is delivered to whatever the high dword happened to hold.
	 * Three window writes, and the unmasked one is LAST. */
	EQI("routing took three window writes", 3, g_log_n);
	EQ32("first write is the low dword, MASKED", 1u << 16,
	     g_log[0].val & (1u << 16));
	EQ32("and it is the low register", (unsigned)(REG_REDIR + 2 * gsi),
	     g_log[0].reg);
	EQ32("second write is the HIGH register",
	     (unsigned)(REG_REDIR + 2 * gsi + 1), g_log[1].reg);
	EQ32("third write is the low register again",
	     (unsigned)(REG_REDIR + 2 * gsi), g_log[2].reg);
	EQ32("and only that one clears the mask", 0,
	     g_log[2].val & (1u << 16));

	/* Mask and unmask move exactly one bit and leave the rest alone. */
	EQ32("mask succeeds", IOAPIC_OK, ioapic_mask(gsi));
	EQ32("the entry is masked and otherwise unchanged", 0x10020,
	     (unsigned)ioapic_read_lo(gsi));
	EQ32("unmask succeeds", IOAPIC_OK, ioapic_unmask(gsi));
	EQ32("and back", 0x20, (unsigned)ioapic_read_lo(gsi));

	/* Polarity and trigger reach the chip. */
	EQ32("a level-triggered active-low route", IOAPIC_OK,
	     ioapic_route(11, 0x30, 5, 1, 1));
	EQ32("with both bits set", 0xA030, (unsigned)ioapic_read_lo(11));
	EQ32("and its destination", 0x05000000, (unsigned)ioapic_read_hi(11));
}

static void test_refusals(void)
{
	int before;

	model_reset();
	ioapic_set_window(FAKE_WIN);

	/* A GSI past the last entry the chip reports.  This is the refusal the
	 * narrowed read was producing for GSI 2, on a chip with 24 entries. */
	EQ32("a GSI past the last entry", E_GSI, ioapic_route(PINS, 0x20, 0, 0, 0));
	EQ32("the last entry itself is fine", IOAPIC_OK,
	     ioapic_route(PINS - 1, 0x20, 0, 0, 0));
	EQ32("a negative GSI", E_GSI, ioapic_route(-1, 0x20, 0, 0, 0));
	EQ32("mask past the end", E_GSI, ioapic_mask(PINS));
	EQ32("unmask past the end", E_GSI, ioapic_unmask(PINS));
	EQ32("read_lo past the end answers zero", 0, ioapic_read_lo(PINS));
	EQ32("read_hi past the end answers zero", 0, ioapic_read_hi(PINS));

	/* A vector the CPU owns is refused, and NOTHING is written -- a route
	 * that validated after its first write would leave a half-built entry. */
	before = g_log_n;
	EQ32("a vector below 16 is refused", E_VECTOR,
	     ioapic_route(3, 0x02, 0, 0, 0));
	EQI("and nothing was written", before, g_log_n);
	EQ32("the entry it would have touched is still masked", 1u << 16,
	     (unsigned)ioapic_read_lo(3));
}

int main(void)
{
	test_encoders();
	test_no_window();
	test_identity();
	test_routing();
	test_refusals();
	return fk_report("ioapic");
}
