/* Reference-model test for src/drivers/bus/fk_pcie.f90.
 *
 * Configuration space is ordinary memory here.  The module reaches it through
 * boot/io.S's fk_readl and nothing else, so this file supplies that accessor
 * and lays a real config space underneath it -- the same shape as
 * tests/cpu/test_ioapic.c, and for the same reason: fk_pcie_m had to stop
 * using a volatile Fortran pointer, because -O2 narrows such a load when only
 * some of its bits are used.
 *
 * THE ARENA IS POISONED TO 0xFF, which is not tidiness: a configuration read
 * of a function that is not there returns all ones on every dword, so an
 * unpopulated slot is absent BY CONSTRUCTION and a walk that strays into one
 * sees exactly what the silicon would show it.
 *
 * The reference tree is the one this project's own firmware presents -- QEMU
 * q35 with the gate's -device qemu-xhci, six functions, with device 0x1F
 * multifunction and its function 1
 * missing, which is what makes it a real test of the header-type bit and of
 * skipping a gap.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "fk_test.h"

void    pcie_set_window(int64_t virt, int32_t bus_lo, int32_t bus_hi);
int32_t pcie_ready(void);
int64_t pcie_cfg_offset(int32_t bus, int32_t dev, int32_t fn, int32_t off);
int32_t pcie_cfg_read32(int32_t bus, int32_t dev, int32_t fn, int32_t off);
int32_t pcie_cfg_read16(int32_t bus, int32_t dev, int32_t fn, int32_t off);
int32_t pcie_cfg_read8(int32_t bus, int32_t dev, int32_t fn, int32_t off);
int32_t pcie_scan(void);
int32_t pcie_count(void);
int32_t pcie_seen(void);
int32_t pcie_overflowed(void);
int32_t pcie_bdf(int32_t i);
int32_t pcie_bus(int32_t i);
int32_t pcie_device(int32_t i);
int32_t pcie_function(int32_t i);
int32_t pcie_vendor(int32_t i);
int32_t pcie_devid(int32_t i);
int32_t pcie_class(int32_t i);
int32_t pcie_subclass(int32_t i);
int32_t pcie_progif(int32_t i);
int32_t pcie_header_type(int32_t i);
int32_t pcie_multifunction(int32_t i);
int32_t pcie_find_class(int32_t cls, int32_t sub, int32_t pif);
int32_t pcie_find_xhci(void);
int32_t pcie_find_nvme(void);

int32_t pcie_cfg_write32(int32_t bus, int32_t dev, int32_t fn, int32_t off,
			 int32_t val);
int32_t pcie_command(int32_t i);
int32_t pcie_cmd_enable(int32_t i);
int32_t pcie_cmd_disable(int32_t i);
int32_t pcie_find_cap(int32_t i, int32_t cap_id);
int32_t pcie_cap_hops(void);
int32_t pcie_msix_at(int32_t i);
int32_t pcie_msix_count(int32_t i);
int32_t pcie_msix_bir(int32_t i);
int32_t pcie_msix_offset(int32_t i);
int64_t pcie_bar64(int32_t i, int32_t n);

int32_t fk_readl(int64_t addr);
void    fk_writel(int64_t addr, int32_t v);

#define EQ32(what, a, b) FK_EQ(what, (unsigned)(a), (unsigned)(b), "0x%X")
#define EQ64(what, a, b) \
	FK_EQ(what, (unsigned long long)(a), (unsigned long long)(b), "0x%llX")
#define EQI(what, a, b)  FK_EQ(what, (int)(a), (int)(b), "%d")

enum { NOT_FOUND = -1, MAX_DEV = 64, BUSES = 3, BUS_BYTES = 1 << 20 };
enum { OK = 0, E_RANGE = -2, CAP_TTL = 48 };

static uint8_t *g_space;
static int g_reads;
static int g_writes;

/* The module's only route to the hardware.  A byte-granular decode, so a
 * misaligned or out-of-window read shows up here rather than being silently
 * rounded into something plausible. */
int32_t fk_readl(int64_t addr)
{
	uint64_t off = (uint64_t)addr - (uint64_t)(uintptr_t)g_space;

	g_reads++;
	if (off + 4 > (uint64_t)BUSES * BUS_BYTES)
		return -1;
	return (int32_t)(((uint32_t)g_space[off]) |
			 ((uint32_t)g_space[off + 1] << 8) |
			 ((uint32_t)g_space[off + 2] << 16) |
			 ((uint32_t)g_space[off + 3] << 24));
}

/* CONFIGURATION SPACE IS NOT MEMORY, and a model that stores what it is given
 * cannot fail for the right reason.  This is QEMU's wmask/w1cmask in one
 * function, for the one register this milestone writes: at 0x04 the low half
 * is COMMAND and takes writes, the high half is STATUS and is read-only except
 * for six error bits that a written 1 CLEARS and a written 0 leaves alone.
 *
 * Without this, writing the status half back unchanged looks harmless here and
 * destroys error state on the silicon. */
static uint32_t merge_cfg(uint32_t reg, uint32_t old, uint32_t val)
{
	const uint32_t w1c = 0xF9000000u;	/* status 8, 11..15, shifted */
	const uint32_t wmask = 0x0000FFFFu;	/* COMMAND */
	uint32_t out;

	if (reg != 0x04)
		return val;
	out = (old & ~wmask) | (val & wmask);
	return out & ~(val & w1c);
}

/* The write half, byte-granular for the same reason: a store that lands one
 * dword away from its target has to be visible here rather than absorbed. */
void fk_writel(int64_t addr, int32_t v)
{
	uint64_t off = (uint64_t)addr - (uint64_t)(uintptr_t)g_space;
	uint32_t u = (uint32_t)v;

	g_writes++;
	if (off + 4 > (uint64_t)BUSES * BUS_BYTES)
		return;
	u = merge_cfg((uint32_t)(off & 0xFFFu), (uint32_t)fk_readl(addr), u);
	g_reads--;
	g_space[off] = (uint8_t)(u & 0xFF);
	g_space[off + 1] = (uint8_t)((u >> 8) & 0xFF);
	g_space[off + 2] = (uint8_t)((u >> 16) & 0xFF);
	g_space[off + 3] = (uint8_t)((u >> 24) & 0xFF);
}

static uint8_t *fn_at(int bus, int dev, int fn)
{
	return g_space + ((uint64_t)bus << 20) + ((uint64_t)dev << 15) +
	       ((uint64_t)fn << 12);
}

static void put32(uint8_t *p, int off, uint32_t v)
{
	p[off] = (uint8_t)(v & 0xFF);
	p[off + 1] = (uint8_t)((v >> 8) & 0xFF);
	p[off + 2] = (uint8_t)((v >> 16) & 0xFF);
	p[off + 3] = (uint8_t)((v >> 24) & 0xFF);
}

/* One function: vendor/device at 0x00, revision+class triple at 0x08, header
 * type at 0x0E (byte 2 of the dword at 0x0C). */
static void place(int bus, int dev, int fn, uint16_t ven, uint16_t did,
		  uint8_t cls, uint8_t sub, uint8_t pif, uint8_t hdr)
{
	uint8_t *p = fn_at(bus, dev, fn);

	memset(p, 0, 4096);
	put32(p, 0x00, (uint32_t)ven | ((uint32_t)did << 16));
	put32(p, 0x08, ((uint32_t)cls << 24) | ((uint32_t)sub << 16) |
			((uint32_t)pif << 8));
	put32(p, 0x0C, (uint32_t)hdr << 16);
}

static void arena_reset(void)
{
	memset(g_space, 0xFF, (size_t)BUSES * BUS_BYTES);
	g_reads = 0;
	g_writes = 0;
}

/* One capability link: id and the offset of the next, 0 to end the chain. */
static void cap(uint8_t *p, int at, uint8_t id, uint8_t next)
{
	p[at] = id;
	p[at + 1] = next;
}

/* The xHCI the gate now hands QEMU with -device qemu-xhci, and the parts of it
 * this milestone reads.  QEMU puts it at 00:02.0 and this model puts it at
 * 00:03.0, because 00:02 is where the aliasing-device fixture lives; the
 * device number is the one thing here that is not the machine's.  Everything here is wrong-by-construction under a
 * naive decode: the status half carries SET write-1-to-clear error bits, the
 * capability chain is three links deep, the MSI-X table has a non-zero BIR and
 * a non-zero offset, its size is encoded N-1, and BAR0 is a 64-bit BAR whose
 * high dword is not zero. */
static void place_xhci(void)
{
	uint8_t *p = fn_at(0, 0x03, 0);

	place(0, 0x03, 0, 0x1B36, 0x000D, 0x0C, 0x03, 0x30, 0x00);
	/* COMMAND = I/O space only; STATUS = CAP_LIST plus two W1C error bits
	 * that must still be set after anything writes COMMAND. */
	put32(p, 0x04, 0x0001u | (0xC010u << 16));
	/* BAR0/1: 64-bit prefetchable at 0x1_E000_0000.  BAR2: I/O space, which
	 * has no 64-bit form and must be refused.  BAR4: where MSI-X lives. */
	put32(p, 0x10, 0xE000000Cu);
	put32(p, 0x14, 0x00000001u);
	put32(p, 0x18, 0x0000C001u);
	put32(p, 0x20, 0xF0000000u);
	p[0x34] = 0x80;
	cap(p, 0x80, 0x01, 0x90);	/* power management */
	cap(p, 0x90, 0x10, 0xA0);	/* PCI Express */
	cap(p, 0xA0, 0x11, 0x00);	/* MSI-X, last */
	/* Table Size 7 means EIGHT entries; table pointer 0x3000 in BAR 4. */
	put32(p, 0xA0, 0x11u | (0x00u << 8) | (0x0007u << 16));
	put32(p, 0xA4, 0x00003000u | 4u);
	/* Sentinels either side of the scratch dword the write test uses. */
	put32(p, 0x4C, 0xDEADBEEFu);
	put32(p, 0x54, 0xFEEDFACEu);
}

/* The functions QEMU's q35 machine presents with the gate's -device qemu-xhci,
 * verified against 'info pci' on this project's own boot gate. */
static void place_q35(void)
{
	arena_reset();
	place(0, 0x00, 0, 0x8086, 0x29C0, 0x06, 0x00, 0x00, 0x00);
	place(0, 0x01, 0, 0x1234, 0x1111, 0x03, 0x00, 0x00, 0x00);
	place_xhci();
	/* Device 0x1F is multifunction with 0, 2 and 3 present and 1 ABSENT. */
	place(0, 0x1F, 0, 0x8086, 0x2918, 0x06, 0x01, 0x00, 0x80);
	place(0, 0x1F, 2, 0x8086, 0x2922, 0x01, 0x06, 0x01, 0x00);
	place(0, 0x1F, 3, 0x8086, 0x2930, 0x0C, 0x05, 0x00, 0x00);
}

static int index_of(int bus, int dev, int fn)
{
	int want = (bus << 8) | (dev << 3) | fn, i;

	for (i = 0; i < pcie_count(); i++)
		if (pcie_bdf(i) == want)
			return i;
	return -1;
}

static void test_offsets(void)
{
	/* The arithmetic on its own, before anything is dereferenced. */
	EQ64("bus 1 is one MiB in", 1LL << 20, pcie_cfg_offset(1, 0, 0, 0));
	EQ64("device 1 is 32 KiB in", 1LL << 15, pcie_cfg_offset(0, 1, 0, 0));
	EQ64("function 1 is 4 KiB in", 1LL << 12, pcie_cfg_offset(0, 0, 1, 0));
	EQ64("00:1f.3", (31LL << 15) | (3LL << 12), pcie_cfg_offset(0, 0x1F, 3, 0));
	EQ64("an offset within the function", 0x10, pcie_cfg_offset(0, 0, 0, 0x10));
	EQ64("the last bus", 255LL << 20, pcie_cfg_offset(255, 0, 0, 0));
	/* All four fields at once, and none of them overlapping. */
	EQ64("everything at once", (255LL << 20) | (31LL << 15) | (7LL << 12) | 0xFFC,
	     pcie_cfg_offset(255, 31, 7, 0xFFC));
}

static void test_reads(void)
{
	place_q35();
	pcie_set_window((int64_t)(uintptr_t)g_space, 0, BUSES - 1);
	EQI("a window makes it ready", 1, pcie_ready());

	EQ32("vendor/device of the host bridge", 0x29C08086,
	     (unsigned)pcie_cfg_read32(0, 0, 0, 0x00));
	EQ32("the vendor id alone", 0x8086, pcie_cfg_read16(0, 0, 0, 0x00));
	EQ32("the device id alone", 0x29C0, pcie_cfg_read16(0, 0, 0, 0x02));
	EQ32("the class byte", 0x06, pcie_cfg_read8(0, 0, 0, 0x0B));
	EQ32("the subclass byte", 0x00, pcie_cfg_read8(0, 0, 0, 0x0A));
	EQ32("the header type of a multifunction device", 0x80,
	     pcie_cfg_read8(0, 0x1F, 0, 0x0E));

	/* An unpopulated function reads as all ones on every width. */
	EQ32("an absent function, dword", 0xFFFFFFFF,
	     (unsigned)pcie_cfg_read32(0, 0x05, 0, 0x00));
	EQ32("an absent function, word", 0xFFFF, pcie_cfg_read16(0, 0x05, 0, 0x00));
	EQ32("an absent function, byte", 0xFF, pcie_cfg_read8(0, 0x05, 0, 0x00));

	/* OUT OF RANGE IS A REFUSAL AND NOT A READ.  A bus past the window is
	 * an address past the mapping, which on the real machine is a page
	 * fault rather than an absent device. */
	g_reads = 0;
	EQ32("a bus past the window", 0xFFFFFFFF,
	     (unsigned)pcie_cfg_read32(BUSES, 0, 0, 0));
	EQ32("a device past 31", 0xFFFFFFFF, (unsigned)pcie_cfg_read32(0, 32, 0, 0));
	EQ32("a function past 7", 0xFFFFFFFF, (unsigned)pcie_cfg_read32(0, 0, 8, 0));
	EQ32("a negative bus", 0xFFFFFFFF, (unsigned)pcie_cfg_read32(-1, 0, 0, 0));
	EQI("and none of them touched the window", 0, g_reads);
}

static void test_scan(void)
{
	int i;

	place_q35();
	pcie_set_window((int64_t)(uintptr_t)g_space, 0, BUSES - 1);
	EQI("the q35 tree has six functions", 6, pcie_scan());
	EQI("and six were kept", 6, pcie_count());
	EQI("nothing overflowed", 0, pcie_overflowed());

	i = index_of(0, 0x00, 0);
	EQI("the host bridge is there", 1, i >= 0);
	EQ32("its vendor", 0x8086, pcie_vendor(i));
	EQ32("its device", 0x29C0, pcie_devid(i));
	EQ32("its class", 0x06, pcie_class(i));
	EQI("and it is not multifunction", 0, pcie_multifunction(i));

	i = index_of(0, 0x01, 0);
	EQ32("the VGA controller's vendor", 0x1234, pcie_vendor(i));
	EQ32("and device", 0x1111, pcie_devid(i));
	EQ32("and class", 0x03, pcie_class(i));

	i = index_of(0, 0x1F, 0);
	EQ32("the ISA bridge", 0x2918, pcie_devid(i));
	EQI("which IS multifunction", 1, pcie_multifunction(i));
	EQ32("and whose header type has the bit stripped", 0x00,
	     pcie_header_type(i));

	i = index_of(0, 0x1F, 2);
	EQ32("the SATA controller", 0x2922, pcie_devid(i));
	EQ32("its class", 0x01, pcie_class(i));
	EQ32("its subclass", 0x06, pcie_subclass(i));
	EQ32("its prog-if", 0x01, pcie_progif(i));
	EQI("its bus", 0, pcie_bus(i));
	EQI("its device", 0x1F, pcie_device(i));
	EQI("its function", 2, pcie_function(i));

	EQ32("the SMBus controller", 0x2930, pcie_devid(index_of(0, 0x1F, 3)));

	/* THE GAP.  Function 1 of a multifunction device is absent and must
	 * not be reported -- a walk that stops at the first missing function
	 * would also lose functions 2 and 3, which are there. */
	EQI("function 1 of 00:1f is not reported", -1, index_of(0, 0x1F, 1));

	/* Nothing on bus 1, which is inside the window and entirely poison. */
	for (i = 0; i < pcie_count(); i++)
		EQI("every function found is on bus 0", 0, pcie_bus(i));
}

static void test_single_function_alias(void)
{
	int i, n;

	/* A SINGLE-FUNCTION DEVICE THAT ALIASES ITSELF ACROSS ALL EIGHT.  Real
	 * hardware does this, and a walk that probes functions 1..7 regardless
	 * of the header-type bit reports one device eight times. */
	place_q35();
	for (i = 0; i < 8; i++)
		place(0, 0x02, i, 0xAAAA, 0xBBBB, 0x02, 0x00, 0x00, 0x00);
	pcie_set_window((int64_t)(uintptr_t)g_space, 0, BUSES - 1);
	n = pcie_scan();
	EQI("the aliasing device is counted once", 7, n);
	EQI("function 0 is the one kept", 1, index_of(0, 0x02, 0) >= 0);
	EQI("function 1 is not", -1, index_of(0, 0x02, 1));
	EQI("nor function 7", -1, index_of(0, 0x02, 7));

	/* And with the multifunction bit SET, all eight are reported -- so the
	 * check above is reading the bit and not just refusing to look. */
	for (i = 0; i < 8; i++)
		place(0, 0x02, i, 0xAAAA, 0xBBBB, 0x02, 0x00, 0x00, 0x80);
	EQI("with the bit set, all eight are reported", 14, pcie_scan());
}

static void test_find(void)
{
	int i;

	place_q35();
	pcie_set_window((int64_t)(uintptr_t)g_space, 0, BUSES - 1);
	pcie_scan();

	i = pcie_find_class(0x01, 0x06, 0x01);
	EQI("the SATA controller is found by class", 1, i >= 0);
	EQ32("and it is the right one", 0x2922, pcie_devid(i));

	/* The xHCI is on this machine and is NOT index 0 -- "found" and "the
	 * first entry" have to be distinguishable answers, and index 0 is the
	 * host bridge. */
	i = pcie_find_xhci();
	EQI("the xHCI is found", 1, i > 0);
	EQ32("and it is the right one", 0x000D, pcie_devid(i));

	/* No NVMe here, and "not found" must be distinct from index 0 too. */
	EQI("no NVMe on q35", NOT_FOUND, pcie_find_nvme());
	EQI("nor anything with an invented triple", NOT_FOUND,
	     pcie_find_class(0x77, 0x77, 0x77));

	place(0, 0x04, 0, 0x1B36, 0x0010, 0x01, 0x08, 0x02, 0x00);
	pcie_scan();
	i = pcie_find_nvme();
	EQI("the NVMe is found", 1, i >= 0);
	EQ32("and it is the right one", 0x0010, pcie_devid(i));
}

static void test_overflow(void)
{
	int bus, dev, want = 0;

	/* More functions than the table holds.  The COUNT must clamp and the
	 * SEEN must not -- a truncated list that reads as complete is the
	 * failure this exists to prevent. */
	arena_reset();
	for (bus = 0; bus < BUSES; bus++)
		for (dev = 0; dev < 32; dev++) {
			place(bus, dev, 0, 0xC0DE, (uint16_t)(dev + bus * 32),
			      0x02, 0x00, 0x00, 0x00);
			want++;
		}
	pcie_set_window((int64_t)(uintptr_t)g_space, 0, BUSES - 1);
	EQI("the walk saw every function", want, pcie_scan());
	EQI("and says so", want, pcie_seen());
	EQI("but kept only what fits", MAX_DEV, pcie_count());
	EQI("and admits it truncated", 1, pcie_overflowed());
	EQ32("an index past the kept list answers zero", 0, pcie_vendor(MAX_DEV));
	EQ32("and a negative one", 0, pcie_vendor(-1));
}

/* Every write assertion checks TWO things: the target dword became what was
 * written, and the dwords either side of it did not move.  A store that lands
 * one dword away is the failure this exists to refuse. */
static void test_writes(void)
{
	int i;

	place_q35();
	pcie_set_window((int64_t)(uintptr_t)g_space, 0, BUSES - 1);
	pcie_scan();
	i = index_of(0, 0x03, 0);

	EQI("a write is accepted", OK, pcie_cfg_write32(0, 0x03, 0, 0x50,
							(int32_t)0xA5A5A5A5));
	EQ32("and lands", 0xA5A5A5A5, (unsigned)pcie_cfg_read32(0, 0x03, 0, 0x50));
	EQ32("the dword below is untouched", 0xDEADBEEF,
	     (unsigned)pcie_cfg_read32(0, 0x03, 0, 0x4C));
	EQ32("and the dword above", 0xFEEDFACE,
	     (unsigned)pcie_cfg_read32(0, 0x03, 0, 0x54));

	/* An unaligned offset writes the dword it is inside, the same way the
	 * read path reads it. */
	EQI("an unaligned write is accepted", OK,
	    pcie_cfg_write32(0, 0x03, 0, 0x52, (int32_t)0x5A5A5A5A));
	EQ32("and lands on the aligned dword", 0x5A5A5A5A,
	     (unsigned)pcie_cfg_read32(0, 0x03, 0, 0x50));

	/* OUT OF RANGE WRITES NOTHING.  A dropped write that reads back as
	 * success is worse than a refused one, so each of these is a status
	 * AND a store that never happened. */
	g_writes = 0;
	EQI("a bus past the window", E_RANGE,
	    pcie_cfg_write32(BUSES, 0, 0, 0, 0));
	EQI("a device past 31", E_RANGE, pcie_cfg_write32(0, 32, 0, 0, 0));
	EQI("a function past 7", E_RANGE, pcie_cfg_write32(0, 0, 8, 0, 0));
	EQI("a negative bus", E_RANGE, pcie_cfg_write32(-1, 0, 0, 0, 0));
	EQI("an offset past the function's config space", E_RANGE,
	    pcie_cfg_write32(0, 0x03, 0, 0x100, 0));
	EQI("and none of them stored anything", 0, g_writes);

	pcie_set_window(0, 0, 0);
	g_writes = 0;
	EQI("a write with no window", E_RANGE, pcie_cfg_write32(0, 0, 0, 0, 0));
	EQI("stores nothing either", 0, g_writes);
	(void)i;
}

/* THE ASSERTION THIS WHOLE DECISION EXISTS FOR: the status half of 0x04 holds
 * write-1-to-clear error bits, and enabling COMMAND must not clear them. A
 * read-modify-write that echoes the status it just read passes every other
 * check in this file and silently destroys error state. */
static void test_command(void)
{
	int i, cmd;

	place_q35();
	pcie_set_window((int64_t)(uintptr_t)g_space, 0, BUSES - 1);
	pcie_scan();
	i = index_of(0, 0x03, 0);

	EQ32("COMMAND starts with I/O space only", 0x0001, pcie_command(i));
	EQ32("STATUS starts with CAP_LIST and two W1C error bits", 0xC010,
	     pcie_cfg_read16(0, 0x03, 0, 0x06));

	cmd = pcie_cmd_enable(i);
	EQI("memory space decode is set", 1, (cmd >> 1) & 1);
	EQI("bus mastering is set", 1, (cmd >> 2) & 1);
	EQI("the I/O bit that was already there survives", 1, cmd & 1);
	EQ32("and the read-back is what COMMAND now holds", (unsigned)cmd,
	     (unsigned)pcie_command(i));
	EQ32("THE W1C STATUS BITS ARE STILL SET", 0xC010,
	     pcie_cfg_read16(0, 0x03, 0, 0x06));

	/* DOWN AND BACK UP. Firmware has usually already set both bits, so the
	 * only writes this suite can prove are the ones that CLEAR them. */
	cmd = pcie_cmd_disable(i);
	EQI("memory space decode is cleared", 0, (cmd >> 1) & 1);
	EQI("bus mastering is cleared", 0, (cmd >> 2) & 1);
	EQI("and the I/O bit is still not this function's business", 1, cmd & 1);
	EQ32("STILL not clearing the W1C status bits", 0xC010,
	     pcie_cfg_read16(0, 0x03, 0, 0x06));
	cmd = pcie_cmd_enable(i);
	EQI("and both come back", 3, (cmd >> 1) & 3);

	EQI("enabling an index that was never walked", NOT_FOUND,
	    pcie_cmd_enable(pcie_count()));
	EQI("disabling one", NOT_FOUND, pcie_cmd_disable(-1));
	EQI("or a negative one", NOT_FOUND, pcie_cmd_enable(-1));
	EQI("and COMMAND of one", NOT_FOUND, pcie_command(-1));
}

static void test_caps(void)
{
	uint8_t *p;
	int i, k;

	place_q35();
	pcie_set_window((int64_t)(uintptr_t)g_space, 0, BUSES - 1);
	pcie_scan();
	i = index_of(0, 0x03, 0);

	EQ32("MSI-X is the third link", 0xA0, pcie_find_cap(i, 0x11));
	EQI("and three hops got there", 3, pcie_cap_hops());
	EQ32("PCI Express is the second", 0x90, pcie_find_cap(i, 0x10));
	EQI("in two hops", 2, pcie_cap_hops());
	EQ32("power management is the first", 0x80, pcie_find_cap(i, 0x01));
	EQI("in one", 1, pcie_cap_hops());

	/* A capability that is not on the chain walks the WHOLE chain and then
	 * says so, rather than stopping early and reporting absence. */
	EQI("MSI is not on this device", NOT_FOUND, pcie_find_cap(i, 0x05));
	EQI("and the whole chain was walked to find that out", 3,
	    pcie_cap_hops());

	/* A function whose STATUS says there is no capability list. Whatever is
	 * at 0x34 on it is not a pointer and must not be followed. */
	k = index_of(0, 0x00, 0);
	EQ32("the host bridge has CAP_LIST clear", 0,
	     (pcie_cfg_read16(0, 0, 0, 0x06) >> 4) & 1);
	EQI("so no capability is found on it", NOT_FOUND,
	    pcie_find_cap(k, 0x11));
	EQI("and nothing was chased", 0, pcie_cap_hops());

	/* A pointer INTO THE HEADER. 0x34 itself is inside the 64 bytes every
	 * function has, so following it walks the header as if it were a
	 * capability. */
	p = fn_at(0, 0x03, 0);
	p[0x34] = 0x20;
	EQI("a pointer below 0x40 is refused", NOT_FOUND,
	    pcie_find_cap(i, 0x11));
	EQI("without a hop", 0, pcie_cap_hops());

	/* A CHAIN THAT POINTS AT ITSELF. Without the bound this does not return
	 * a wrong answer, it hangs the boot. */
	p[0x34] = 0x80;
	cap(p, 0x80, 0x01, 0x80);
	EQI("a self-pointing chain terminates", NOT_FOUND,
	    pcie_find_cap(i, 0x11));
	EQI("at the bound", CAP_TTL, pcie_cap_hops());

	/* A chain longer than the bound, with the wanted capability past it. A
	 * walk that finds it is a walk that is not bounded. */
	for (k = 0; k < 60; k++)
		cap(p, 0x40 + 4 * k, 0x01, (uint8_t)(0x40 + 4 * (k + 1)));
	cap(p, 0x40 + 4 * 60, 0x11, 0x00);
	p[0x34] = 0x40;
	EQI("a chain longer than the bound gives up", NOT_FOUND,
	    pcie_find_cap(i, 0x11));
	EQI("having taken exactly the bound", CAP_TTL, pcie_cap_hops());
}

static void test_msix(void)
{
	int i, k;

	place_q35();
	pcie_set_window((int64_t)(uintptr_t)g_space, 0, BUSES - 1);
	pcie_scan();
	i = index_of(0, 0x03, 0);

	EQ32("the MSI-X capability is at 0xA0", 0xA0, pcie_msix_at(i));
	/* Encoded 7. A decode that forgets the +1 loses an entry the driver
	 * would then never program. */
	EQI("eight entries, from a field that reads 7", 8, pcie_msix_count(i));
	EQI("the table is in BAR 4", 4, pcie_msix_bir(i));
	/* Bits 31:3 are ALREADY the byte offset. Shifting them down by three
	 * lands the table an eighth of the way up the register block. */
	EQ32("at offset 0x3000 inside it", 0x3000, pcie_msix_offset(i));

	k = index_of(0, 0x1F, 3);
	EQI("a device with no MSI-X has no capability", NOT_FOUND,
	    pcie_msix_at(k));
	EQI("no count", NOT_FOUND, pcie_msix_count(k));
	EQI("no BIR", NOT_FOUND, pcie_msix_bir(k));
	EQI("and no offset", NOT_FOUND, pcie_msix_offset(k));
}

static void test_bars(void)
{
	int i;

	place_q35();
	pcie_set_window((int64_t)(uintptr_t)g_space, 0, BUSES - 1);
	pcie_scan();
	i = index_of(0, 0x03, 0);

	/* THE HIGH DWORD IS NOT ZERO. A 32-bit-only decode returns 0xE0000000
	 * here, which is a valid-looking address 7.5 GiB from the register
	 * block, and every subsequent read answers 0xFFFFFFFF. */
	EQ64("BAR0 is 64-bit and above 4 GiB", 0x1E0000000ULL, pcie_bar64(i, 0));
	EQ64("BAR4 is an ordinary 32-bit BAR", 0xF0000000ULL, pcie_bar64(i, 4));
	EQ64("an I/O-space BAR has no address here", 0, pcie_bar64(i, 2));
	EQ64("BAR6 does not exist", 0, pcie_bar64(i, 6));
	EQ64("nor BAR -1", 0, pcie_bar64(i, -1));
	EQ64("nor a BAR of an index never walked", 0, pcie_bar64(-1, 0));
}

static void test_no_window(void)
{
	pcie_set_window(0, 0, 0);
	EQI("no window means not ready", 0, pcie_ready());
	g_reads = 0;
	EQ32("a read with no window", 0xFFFFFFFF,
	     (unsigned)pcie_cfg_read32(0, 0, 0, 0));
	EQI("scan with no window finds nothing", 0, pcie_scan());
	EQI("and dereferenced nothing", 0, g_reads);
}

int main(void)
{
	g_space = malloc((size_t)BUSES * BUS_BYTES);
	if (!g_space) {
		printf("  FATAL: cannot allocate the config space arena\n");
		return 2;
	}
	test_offsets();
	test_reads();
	test_scan();
	test_single_function_alias();
	test_find();
	test_overflow();
	test_writes();
	test_command();
	test_caps();
	test_msix();
	test_bars();
	test_no_window();
	free(g_space);
	return fk_report("pcie");
}
