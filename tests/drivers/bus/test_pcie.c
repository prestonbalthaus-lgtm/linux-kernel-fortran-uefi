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
 * q35, five functions, with device 0x1F multifunction and its function 1
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

int32_t fk_readl(int64_t addr);

#define EQ32(what, a, b) FK_EQ(what, (unsigned)(a), (unsigned)(b), "0x%X")
#define EQ64(what, a, b) \
	FK_EQ(what, (unsigned long long)(a), (unsigned long long)(b), "0x%llX")
#define EQI(what, a, b)  FK_EQ(what, (int)(a), (int)(b), "%d")

enum { NOT_FOUND = -1, MAX_DEV = 64, BUSES = 3, BUS_BYTES = 1 << 20 };

static uint8_t *g_space;
static int g_reads;

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
}

/* The five functions QEMU's q35 machine presents, verified against 'info pci'
 * on this project's own boot gate. */
static void place_q35(void)
{
	arena_reset();
	place(0, 0x00, 0, 0x8086, 0x29C0, 0x06, 0x00, 0x00, 0x00);
	place(0, 0x01, 0, 0x1234, 0x1111, 0x03, 0x00, 0x00, 0x00);
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
	EQI("the q35 tree has five functions", 5, pcie_scan());
	EQI("and five were kept", 5, pcie_count());
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
	EQI("the aliasing device is counted once", 6, n);
	EQI("function 0 is the one kept", 1, index_of(0, 0x02, 0) >= 0);
	EQI("function 1 is not", -1, index_of(0, 0x02, 1));
	EQI("nor function 7", -1, index_of(0, 0x02, 7));

	/* And with the multifunction bit SET, all eight are reported -- so the
	 * check above is reading the bit and not just refusing to look. */
	for (i = 0; i < 8; i++)
		place(0, 0x02, i, 0xAAAA, 0xBBBB, 0x02, 0x00, 0x00, 0x80);
	EQI("with the bit set, all eight are reported", 13, pcie_scan());
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

	/* Neither is on this machine, and "not found" must be a distinct answer
	 * from "index 0" -- which is the host bridge. */
	EQI("no xHCI on q35", NOT_FOUND, pcie_find_xhci());
	EQI("no NVMe on q35", NOT_FOUND, pcie_find_nvme());
	EQI("nor anything with an invented triple", NOT_FOUND,
	     pcie_find_class(0x77, 0x77, 0x77));

	/* Put one of each in and find them. */
	place(0, 0x03, 0, 0x1B36, 0x000D, 0x0C, 0x03, 0x30, 0x00);
	place(0, 0x04, 0, 0x1B36, 0x0010, 0x01, 0x08, 0x02, 0x00);
	pcie_scan();
	i = pcie_find_xhci();
	EQI("the xHCI is found", 1, i >= 0);
	EQ32("and it is the right one", 0x000D, pcie_devid(i));
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
	test_no_window();
	free(g_space);
	return fk_report("pcie");
}
