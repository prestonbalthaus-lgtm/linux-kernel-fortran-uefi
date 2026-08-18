/* Reference-model test for src/drivers/usb/fk_xhci.f90.
 *
 * THE MODEL IS A CONTROLLER, NOT A REGISTER FILE, and that is the whole point.
 * A register file can check that USBCMD holds what was written to it; it
 * cannot check that the ring the controller was handed is one the controller
 * can execute. So this file implements the parts of an xHC that the bring-up
 * sequence actually talks to: HCRST is self-clearing and returns the
 * operational registers to their defaults, CNR is held for a few reads, and
 * ringing doorbell 0 EXECUTES the command ring -- follows the cycle bit,
 * follows the link TRB, toggles its own cycle state, and posts a Command
 * Completion Event onto the event ring. That is what makes the cycle bit, the
 * Toggle Cycle flag, ERDP and the two interrupt gates assertable on a host
 * with no QEMU in the room.
 *
 * PHYSICAL IS VIRTUAL HERE. The driver hands the controller PHYSICAL addresses
 * and dereferences VIRTUAL ones; the test passes the same value for both, so
 * the model can follow the pointers it is given. A driver that mixed the two
 * up would still pass here -- which is why the boot gate checks the published
 * physical addresses against QEMU's own view of the device.
 *
 * THE INTERRUPT IS MODELLED AS A CONDITION, NOT A WIRE: msi_sent counts the
 * messages an xHC would have sent, and it counts one only when IMAN.IE and
 * USBCMD.INTE are both set and ERDP.EHB is clear -- the conditions measured
 * off qemu-xhci. A driver that arms one gate and not the other posts events
 * and never interrupts, which is silent on real hardware and fails here.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "fk_test.h"

int32_t xhci_attach(int64_t virt);
int64_t xhci_op_base(void);
int64_t xhci_rt_base(void);
int64_t xhci_db_base(void);
int32_t xhci_caplength(void);
int32_t xhci_version(void);
int32_t xhci_max_slots(void);
int32_t xhci_max_intrs(void);
int32_t xhci_max_ports(void);
int32_t xhci_max_scratchpads(void);
int32_t xhci_erst_max(void);
int32_t xhci_page_size(void);
int32_t xhci_ac64(void);
int32_t xhci_csz(void);
int32_t xhci_usbcmd(void);
int32_t xhci_usbsts(void);
int32_t xhci_halted(void);
int32_t xhci_cnr(void);
int32_t xhci_error(void);
int32_t xhci_halt(void);
int32_t xhci_reset(void);
int32_t xhci_config_slots(int32_t n);
int32_t xhci_set_dcbaap(int64_t phys);
int32_t xhci_cmd_ring_init(int64_t virt, int64_t phys, int32_t trbs);
int32_t xhci_event_ring_init(int64_t seg_virt, int64_t seg_phys, int32_t trbs,
			     int64_t erst_virt, int64_t erst_phys);
int32_t xhci_intr_enable(void);
int32_t xhci_run(void);
int64_t xhci_cmd_noop(void);
void    xhci_doorbell(int32_t slot, int32_t target);
int32_t xhci_event_poll(void);
int32_t xhci_event_type(void);
int32_t xhci_event_comp(void);
int64_t xhci_event_ptr(void);
int32_t xhci_event_count(void);
int64_t xhci_crcr(void);
int64_t xhci_dcbaap(void);
int64_t xhci_erdp(void);

int32_t fk_readl(int64_t addr);
void    fk_writel(int64_t addr, int32_t v);

#define EQ32(what, a, b) FK_EQ(what, (unsigned)(a), (unsigned)(b), "0x%X")
#define EQ64(what, a, b) \
	FK_EQ(what, (unsigned long long)(a), (unsigned long long)(b), "0x%llX")
#define EQI(what, a, b)  FK_EQ(what, (int)(a), (int)(b), "%d")

enum {
	OK = 0, E_NOBASE = -1, E_HALT = -2, E_RESET = -3, E_CNR = -4,
	E_RUN = -5, E_RING = -6, E_NOEVENT = -7,
};
enum { BAR_BYTES = 16 << 10, CAPLENGTH = 0x40, RTSOFF = 0x1000,
       DBOFF = 0x2000, IR0 = RTSOFF + 0x20 };
/* Operational register offsets, from the BAR. */
enum { R_USBCMD = CAPLENGTH, R_USBSTS = CAPLENGTH + 4,
       R_PAGESIZE = CAPLENGTH + 8, R_CRCR = CAPLENGTH + 0x18,
       R_DCBAAP = CAPLENGTH + 0x30, R_CONFIG = CAPLENGTH + 0x38 };
enum { R_IMAN = IR0, R_ERSTSZ = IR0 + 8, R_ERSTBA = IR0 + 0x10,
       R_ERDP = IR0 + 0x18 };
enum { CMD_RS = 1u << 0, CMD_HCRST = 1u << 1, CMD_INTE = 1u << 2 };
enum { STS_HCH = 1u << 0, STS_EINT = 1u << 3, STS_CNR = 1u << 11,
       STS_HCE = 1u << 12 };
enum { TRB_LINK = 6, TRB_CMD_NOOP = 23, TRB_COMPLETION = 33, COMP_SUCCESS = 1 };
enum { CYCLE = 1u << 0, TC = 1u << 1 };

static uint8_t *g_bar;
static uint8_t *g_ram;		/* where the rings live; phys == virt */
static uint64_t g_ram_base;
static int g_cnr_reads;		/* CNR is held for this many more reads */

/* The controller's own state, which the driver never sees. */
static uint64_t hc_cmd_deq;
static int hc_cmd_ccs;
static uint64_t hc_evt_enq;
static uint64_t hc_evt_base;
static uint32_t hc_evt_trbs;
static int hc_evt_pcs;
static int hc_msi_sent;
static int hc_cmds_run;

static uint32_t rd(uint64_t off)
{
	uint32_t v;

	memcpy(&v, g_bar + off, 4);
	return v;
}

static void wr(uint64_t off, uint32_t v)
{
	memcpy(g_bar + off, &v, 4);
}

static uint64_t rd64(uint64_t off)
{
	return (uint64_t)rd(off) | ((uint64_t)rd(off + 4) << 32);
}

/* A pointer the controller was given that is not in the region it was given
 * is a DRIVER defect, and it has to surface as a failed assertion rather than
 * as a crash in the model -- a segfault says nothing about which pointer was
 * wrong. */
static uint32_t g_void[4];
static int g_stray;

/* THE ORDER OF THE RING WRITES, which neither this model nor QEMU can catch
 * by executing the ring: both only look at a TRB when the doorbell rings, by
 * which time a half-written one is whole. The cycle bit is what HANDS the TRB
 * over, so it must be written last, and the only way to assert that is to
 * watch the writes go by. */
enum { RLOG_MAX = 16 };
static struct { uint64_t off; uint32_t val; } g_rlog[RLOG_MAX];
static int g_rlogn;

static uint32_t *ram(uint64_t phys)
{
	if (phys < g_ram_base || phys + 16 > g_ram_base + (uint64_t)BAR_BYTES) {
		g_stray++;
		return g_void;
	}
	return (uint32_t *)(g_ram + (phys - g_ram_base));
}

/* An xHC posts an event and then, if and only if both gates are open and the
 * handler has acknowledged the previous one, sends its message. */
static void hc_event(uint64_t param, uint32_t status, uint32_t control)
{
	uint32_t *t = ram(hc_evt_base + hc_evt_enq * 16);

	t[0] = (uint32_t)param;
	t[1] = (uint32_t)(param >> 32);
	t[2] = status;
	t[3] = control | (hc_evt_pcs ? CYCLE : 0);

	hc_evt_enq++;
	if (hc_evt_enq >= hc_evt_trbs) {
		hc_evt_enq = 0;
		hc_evt_pcs = !hc_evt_pcs;
	}

	wr(R_USBSTS, rd(R_USBSTS) | STS_EINT);
	wr(R_IMAN, rd(R_IMAN) | 1u);			/* IP */
	if ((rd(R_IMAN) & 2u) && (rd(R_USBCMD) & CMD_INTE) &&
	    !(rd64(R_ERDP) & 8u))
		hc_msi_sent++;
}

/* Doorbell 0: run the command ring until a TRB the controller does not own. */
static void hc_run_commands(void)
{
	int guard = 0;

	if (!(rd(R_USBCMD) & CMD_RS))
		return;
	while (guard++ < 2048) {
		uint32_t *t = ram(hc_cmd_deq);
		uint32_t ctrl = t[3];
		int type = (int)((ctrl >> 10) & 0x3F);

		if (((ctrl & CYCLE) ? 1 : 0) != hc_cmd_ccs)
			return;
		if (type == TRB_LINK) {
			hc_cmd_deq = (uint64_t)t[0] | ((uint64_t)t[1] << 32);
			if (ctrl & TC)
				hc_cmd_ccs = !hc_cmd_ccs;
			continue;
		}
		if (type == TRB_CMD_NOOP) {
			hc_cmds_run++;
			hc_event(hc_cmd_deq, COMP_SUCCESS << 24,
				 TRB_COMPLETION << 10);
		}
		hc_cmd_deq += 16;
	}
}

/* THE RINGS COME THROUGH HERE TOO. They are RAM, but RAM a bus master writes,
 * so the driver reaches them with the same opaque accessor it uses for
 * registers -- gfortran narrowed a ring load to one byte when it did not, and
 * tools/mmiocheck.sh refused the object. */
static int in_ram(uint64_t addr, uint64_t *off)
{
	uint64_t r = addr - g_ram_base;

	if (r + 4 <= (uint64_t)BAR_BYTES) {
		*off = r;
		return 1;
	}
	return 0;
}

int32_t fk_readl(int64_t addr)
{
	uint64_t off = (uint64_t)addr - (uint64_t)(uintptr_t)g_bar;
	uint32_t v;

	if (in_ram((uint64_t)addr, &off)) {
		memcpy(&v, g_ram + off, 4);
		return (int32_t)v;
	}
	off = (uint64_t)addr - (uint64_t)(uintptr_t)g_bar;
	if (off + 4 > (uint64_t)BAR_BYTES)
		return -1;
	if (off == R_USBSTS && g_cnr_reads > 0) {
		g_cnr_reads--;
		return (int32_t)(rd(off) | STS_CNR);
	}
	return (int32_t)rd(off);
}

void fk_writel(int64_t addr, int32_t v)
{
	uint64_t off = (uint64_t)addr - (uint64_t)(uintptr_t)g_bar;
	uint32_t u = (uint32_t)v;

	if (in_ram((uint64_t)addr, &off)) {
		if (g_rlogn < RLOG_MAX) {
			g_rlog[g_rlogn].off = off;
			g_rlog[g_rlogn].val = u;
			g_rlogn++;
		}
		memcpy(g_ram + off, &u, 4);
		return;
	}
	off = (uint64_t)addr - (uint64_t)(uintptr_t)g_bar;
	if (off + 4 > (uint64_t)BAR_BYTES)
		return;

	if (off == R_USBSTS) {
		/* Write-1-to-clear, every bit of it. */
		wr(off, rd(off) & ~u);
		return;
	}
	if (off == R_IMAN) {
		uint32_t ip = rd(off) & 1u;

		if (u & 1u)
			ip = 0;
		wr(off, (u & ~1u) | ip);
		return;
	}
	if (off == R_ERDP) {
		/* EHB is write-1-to-clear and lives in the low dword. */
		uint32_t ehb = (uint32_t)(rd64(R_ERDP) & 8u);

		if (u & 8u)
			ehb = 0;
		wr(off, (u & ~8u) | ehb);
		return;
	}
	if (off == R_USBCMD) {
		if (u & CMD_HCRST) {
			/* Self-clearing, and it returns the operational
			 * registers to their defaults -- which is the whole
			 * reason a driver must reset a controller firmware
			 * has already programmed. */
			wr(R_CRCR, 0);
			wr(R_CRCR + 4, 0);
			wr(R_DCBAAP, 0);
			wr(R_DCBAAP + 4, 0);
			wr(R_CONFIG, 0);
			wr(R_ERSTSZ, 0);
			wr(R_ERSTBA, 0);
			wr(R_ERSTBA + 4, 0);
			wr(R_ERDP, 0);
			wr(R_ERDP + 4, 0);
			wr(R_IMAN, 0);
			wr(R_USBSTS, STS_HCH);
			wr(off, u & ~CMD_HCRST);
			hc_cmd_deq = 0;
			hc_cmd_ccs = 1;
			hc_evt_enq = 0;
			hc_evt_pcs = 1;
			return;
		}
		wr(off, u);
		if (u & CMD_RS)
			wr(R_USBSTS, rd(R_USBSTS) & ~STS_HCH);
		else
			wr(R_USBSTS, rd(R_USBSTS) | STS_HCH);
		return;
	}
	/* A 64-bit register arrives as TWO dword writes, and the controller
	 * latches on the SECOND. Latching on the first would take a pointer
	 * whose high half is still the old value -- which is exactly the
	 * hazard that makes the order matter, and exactly what a model that
	 * latches early turns into a crash instead of a wrong answer. */
	if (off == R_CRCR || off == R_CRCR + 4) {
		wr(off, u);
		if (off == R_CRCR + 4) {
			hc_cmd_deq = rd64(R_CRCR) & ~0x3FULL;
			hc_cmd_ccs = (int)(rd(R_CRCR) & 1u);
		}
		return;
	}
	if (off == R_ERSTBA) {
		wr(off, u);
		return;
	}
	if (off == R_ERSTBA + 4) {
		uint64_t erst;

		wr(off, u);
		/* HCSPARAMS2 says ERSTMax = 2**0 = ONE segment. A driver that
		 * writes the SEGMENT's TRB count here instead of the table's
		 * entry count declares 256 segments, and a real controller
		 * answers that with HCE and executes nothing -- measured on
		 * qemu-xhci, where this model previously said nothing at all. */
		if (rd(R_ERSTSZ) != 1) {
			wr(R_USBSTS, rd(R_USBSTS) | STS_HCE);
			return;
		}
		erst = rd64(R_ERSTBA) & ~0x3FULL;
		if (erst) {
			uint32_t *e = ram(erst);

			hc_evt_base = (uint64_t)e[0] | ((uint64_t)e[1] << 32);
			hc_evt_trbs = e[2];
			hc_evt_enq = 0;
			hc_evt_pcs = 1;
		}
		return;
	}
	if (off >= DBOFF && off < DBOFF + 256) {
		wr(off, u);
		if (off == DBOFF)
			hc_run_commands();
		return;
	}
	wr(off, u);
}

/* HCSPARAMS2: scratchpad count is split, high five bits at 21 and low five at
 * 27, and the total is HI*32 + LO. */
static uint32_t hcs2(uint32_t scratchpads, uint32_t erst_max_exp)
{
	return ((scratchpads >> 5) << 21) | ((scratchpads & 0x1F) << 27) |
	       (erst_max_exp << 4);
}

static void model_reset(uint32_t scratchpads)
{
	memset(g_bar, 0, BAR_BYTES);
	memset(g_ram, 0, BAR_BYTES);
	g_cnr_reads = 0;
	hc_cmd_deq = 0;
	hc_cmd_ccs = 1;
	hc_evt_enq = 0;
	hc_evt_base = 0;
	hc_evt_trbs = 0;
	hc_evt_pcs = 1;
	hc_msi_sent = 0;
	hc_cmds_run = 0;
	g_stray = 0;
	g_rlogn = 0;

	wr(0x00, (0x0100u << 16) | CAPLENGTH);
	wr(0x04, (8u << 24) | (16u << 8) | 64u);	/* 8 ports, 16 intr, 64 slots */
	wr(0x08, hcs2(scratchpads, 0));
	wr(0x10, 0x00087001u);				/* AC64, CSZ=0 */
	wr(0x14, DBOFF);
	wr(0x18, RTSOFF);
	wr(R_PAGESIZE, 1);				/* 4 KiB */
	wr(R_USBSTS, STS_HCH);

	/* FIRMWARE HAS ALREADY DRIVEN THIS CONTROLLER, which is true on the
	 * gate machine: SeaBIOS leaves these pointing into its own memory. A
	 * driver that skips the reset inherits them. */
	wr(R_CRCR, 0x0FFDFC01u);
	wr(R_DCBAAP, 0x0FFDFD80u);
	wr(R_CONFIG, 0x40u);
	wr(R_ERSTSZ, 1);
	wr(R_ERSTBA, 0x0FFDFD40u);
	wr(R_ERDP, 0x0FFDFA00u);
}

/* The four structures, carved out of one contiguous run the way kmain does. */
enum { P_DCBAA = 0, P_CMD = 4096, P_EVT = 8192, P_ERST = 12288 };
enum { CMD_TRBS = 256, EVT_TRBS = 256 };

static int64_t at(uint64_t off)
{
	return (int64_t)(g_ram_base + off);
}

static void bringup(void)
{
	EQI("attach", OK, xhci_attach((int64_t)(uintptr_t)g_bar));
	EQI("reset", OK, xhci_reset());
	EQI("slots configured", OK, xhci_config_slots(xhci_max_slots()));
	EQI("DCBAAP", OK, xhci_set_dcbaap(at(P_DCBAA)));
	EQI("command ring", OK,
	    xhci_cmd_ring_init(at(P_CMD), at(P_CMD), CMD_TRBS));
	EQI("event ring", OK,
	    xhci_event_ring_init(at(P_EVT), at(P_EVT), EVT_TRBS, at(P_ERST),
				 at(P_ERST)));
	EQI("interrupter", OK, xhci_intr_enable());
	EQI("run", OK, xhci_run());
}

static void test_attach(void)
{
	model_reset(0);
	EQI("a null base is refused", E_NOBASE, xhci_attach(0));
	EQI("attach", OK, xhci_attach((int64_t)(uintptr_t)g_bar));
	EQ32("CAPLENGTH", 0x40, xhci_caplength());
	EQ32("HCIVERSION", 0x0100, xhci_version());
	EQ64("the operational block is CAPLENGTH past the BAR",
	     (uint64_t)(uintptr_t)g_bar + CAPLENGTH, xhci_op_base());
	EQ64("the runtime block is where RTSOFF says",
	     (uint64_t)(uintptr_t)g_bar + RTSOFF, xhci_rt_base());
	EQ64("and the doorbells where DBOFF says",
	     (uint64_t)(uintptr_t)g_bar + DBOFF, xhci_db_base());

	EQI("max slots", 64, xhci_max_slots());
	EQI("max interrupters", 16, xhci_max_intrs());
	EQI("max ports", 8, xhci_max_ports());
	EQI("ERST max is 2**0", 1, xhci_erst_max());
	EQI("page size", 4096, xhci_page_size());
	EQI("64-bit addressing", 1, xhci_ac64());
	EQI("32-byte contexts", 0, xhci_csz());

	/* THE SPLIT FIELD. 33 is hi=1 lo=1: an implementation that reads only
	 * the low field says 1, only the high says 32, and both are plausible
	 * array sizes the controller will run off the end of. */
	model_reset(33);
	xhci_attach((int64_t)(uintptr_t)g_bar);
	EQI("scratchpads are HI*32 + LO", 33, xhci_max_scratchpads());
	model_reset(1023);
	xhci_attach((int64_t)(uintptr_t)g_bar);
	EQI("and the maximum is 1023", 1023, xhci_max_scratchpads());
	model_reset(0);
	xhci_attach((int64_t)(uintptr_t)g_bar);
	EQI("zero means no array at all", 0, xhci_max_scratchpads());
}

static void test_reset(void)
{
	model_reset(0);
	xhci_attach((int64_t)(uintptr_t)g_bar);

	EQI("the controller starts halted", 1, xhci_halted());
	EQ64("with firmware's command ring still programmed", 0x0FFDFC01ULL,
	     xhci_crcr());

	/* CNR held for three reads: the driver must WAIT, not sample once. */
	g_cnr_reads = 3;
	EQI("reset", OK, xhci_reset());
	EQI("and it waited out CNR", 0, g_cnr_reads);
	EQI("HCRST self-cleared", 0, (xhci_usbcmd() >> 1) & 1);
	EQ64("firmware's command ring is GONE", 0, xhci_crcr());
	EQ64("and its DCBAAP", 0, xhci_dcbaap());
	EQ32("CONFIG is back to its default", 0, (unsigned)(xhci_usbcmd() & 0));
	EQI("still halted after reset", 1, xhci_halted());
	EQI("and no error", 0, xhci_error());
}

static void test_program(void)
{
	model_reset(0);
	xhci_attach((int64_t)(uintptr_t)g_bar);
	xhci_reset();

	EQI("more slots than the controller has is refused", E_RING,
	    xhci_config_slots(65));
	EQI("a negative count is refused", E_RING, xhci_config_slots(-1));
	EQI("slots configured", OK, xhci_config_slots(64));
	EQ32("MaxSlotsEn", 64, rd(R_CONFIG) & 0xFF);

	EQI("an unaligned DCBAAP is refused", E_RING,
	    xhci_set_dcbaap(at(P_DCBAA) + 8));
	EQI("DCBAAP", OK, xhci_set_dcbaap(at(P_DCBAA)));
	EQ64("and both halves of it landed", (uint64_t)at(P_DCBAA),
	     xhci_dcbaap());

	EQI("a two-TRB minimum on the command ring", E_RING,
	    xhci_cmd_ring_init(at(P_CMD), at(P_CMD), 1));
	EQI("an unaligned command ring is refused", E_RING,
	    xhci_cmd_ring_init(at(P_CMD), at(P_CMD) + 8, CMD_TRBS));
	EQI("command ring", OK,
	    xhci_cmd_ring_init(at(P_CMD), at(P_CMD), CMD_TRBS));

	/* The link TRB is what makes it a RING. Without Toggle Cycle the
	 * controller wraps without flipping its own cycle state and the ring
	 * goes silent after exactly one lap, with no error anywhere. */
	{
		uint32_t *last = ram((uint64_t)at(P_CMD)) +
				 (CMD_TRBS - 1) * 4;

		EQ32("the last TRB is a LINK", TRB_LINK,
		     (last[3] >> 10) & 0x3F);
		EQI("with Toggle Cycle set", 1, (last[3] >> 1) & 1);
		EQI("and the producer's cycle", 1, last[3] & 1);
		EQ64("pointing back at the ring's base",
		     (uint64_t)at(P_CMD),
		     (uint64_t)last[0] | ((uint64_t)last[1] << 32));
	}
	EQ64("CRCR carries the ring and RCS", (uint64_t)at(P_CMD) | 1,
	     xhci_crcr());

	EQI("event ring", OK,
	    xhci_event_ring_init(at(P_EVT), at(P_EVT), EVT_TRBS, at(P_ERST),
				 at(P_ERST)));
	{
		uint32_t *e = ram((uint64_t)at(P_ERST));

		EQ64("the ERST entry names the segment", (uint64_t)at(P_EVT),
		     (uint64_t)e[0] | ((uint64_t)e[1] << 32));
		EQ32("and its size in TRBs", EVT_TRBS, e[2]);
	}
	/* ONE SEGMENT, and the 256 is the segment's own length above. */
	EQ32("ERSTSZ counts segments, not TRBs", 1, rd(R_ERSTSZ));
	EQI("and the controller reports no error", 0, xhci_error());
	EQ64("ERSTBA", (uint64_t)at(P_ERST), rd64(R_ERSTBA));
	EQ64("ERDP starts at the segment with EHB clear",
	     (uint64_t)at(P_EVT), rd64(R_ERDP));

	EQI("interrupter", OK, xhci_intr_enable());
	EQI("IMAN.IE is set", 1, (rd(R_IMAN) >> 1) & 1);
	EQI("IMAN.IP was acknowledged", 0, rd(R_IMAN) & 1);
	EQI("USBCMD.INTE is set", 1, (xhci_usbcmd() >> 2) & 1);

	EQI("run", OK, xhci_run());
	EQI("and it is no longer halted", 0, xhci_halted());
}

static void test_noop(void)
{
	int64_t trb;

	model_reset(0);
	bringup();

	EQI("nothing has completed yet", E_NOEVENT, xhci_event_poll());

	g_rlogn = 0;
	trb = xhci_cmd_noop();
	EQ64("the NO-OP is the ring's first TRB", (uint64_t)at(P_CMD),
	     (uint64_t)trb);

	/* Four dwords, and the CONTROL one carrying the cycle bit is last. A
	 * controller that sees the cycle bit set before the rest of the TRB is
	 * in memory executes a command that is half the previous one. */
	EQI("four dwords were written", 4, g_rlogn);
	EQI("and the cycle-bit dword was the LAST of them", 1,
	    g_rlogn == 4 && g_rlog[3].off == P_CMD + 12 &&
	    (g_rlog[3].val & 1) == 1);
	EQI("the other three went down before it", 1,
	    g_rlogn == 4 && g_rlog[0].off == P_CMD + 0 &&
	    g_rlog[1].off == P_CMD + 4 && g_rlog[2].off == P_CMD + 8);
	EQI("and the controller has not run it yet", 0, hc_cmds_run);

	xhci_doorbell(0, 0);
	EQI("the doorbell ran it", 1, hc_cmds_run);
	EQI("and the message was sent", 1, hc_msi_sent);

	EQI("the completion is there", OK, xhci_event_poll());
	EQI("it is a Command Completion Event", TRB_COMPLETION,
	    xhci_event_type());
	EQI("with completion code SUCCESS", COMP_SUCCESS, xhci_event_comp());
	EQ64("naming the TRB that completed", (uint64_t)trb, xhci_event_ptr());
	EQI("one event seen", 1, xhci_event_count());

	EQ64("ERDP advanced past it", (uint64_t)at(P_EVT) + 16, rd64(R_ERDP));
	EQI("EHB was acknowledged", 0, (int)(rd64(R_ERDP) & 8));
	EQI("and there is nothing else", E_NOEVENT, xhci_event_poll());
}

/* THE LAP-TWO TRAP. An implementation that always writes cycle 1 works
 * perfectly for one lap and then goes silent: the controller wraps, flips its
 * own cycle on Toggle Cycle, and no longer owns anything software writes. */
static void test_ring_wrap(void)
{
	int i, ok = 1;
	int64_t trb = 0;

	model_reset(0);
	bringup();

	/* Fill the ring exactly to the link TRB, one lap. */
	for (i = 0; i < CMD_TRBS - 1; i++) {
		trb = xhci_cmd_noop();
		if (!trb)
			ok = 0;
		xhci_doorbell(0, 0);
	}
	EQI("a full lap enqueued", 1, ok);
	EQI("and every one of them ran", CMD_TRBS - 1, hc_cmds_run);

	/* Now past the link: the second lap must be written with cycle 0. */
	trb = xhci_cmd_noop();
	EQ64("the ring wrapped to its base", (uint64_t)at(P_CMD),
	     (uint64_t)trb);
	{
		uint32_t *first = ram((uint64_t)at(P_CMD));

		EQI("and lap two is written with cycle 0", 0, first[3] & 1);
	}
	xhci_doorbell(0, 0);
	EQI("the controller still executes on lap two", CMD_TRBS, hc_cmds_run);

	/* Drain the events the ring produced and check the ring's own wrap. */
	i = 0;
	while (xhci_event_poll() == OK)
		i++;
	EQI("every command produced an event", CMD_TRBS, i);
	EQI("and the controller was never sent outside its rings", 0, g_stray);
}

/* Both gates, and neither alone. */
static void test_interrupt_gates(void)
{
	model_reset(0);
	bringup();

	wr(R_IMAN, rd(R_IMAN) & ~2u);
	xhci_cmd_noop();
	xhci_doorbell(0, 0);
	EQI("with IMAN.IE clear the event is posted", 1, hc_cmds_run);
	EQI("and no message is sent", 0, hc_msi_sent);

	model_reset(0);
	bringup();
	wr(R_USBCMD, rd(R_USBCMD) & ~CMD_INTE);
	xhci_cmd_noop();
	xhci_doorbell(0, 0);
	EQI("with USBCMD.INTE clear, still no message", 0, hc_msi_sent);

	model_reset(0);
	bringup();
	xhci_cmd_noop();
	xhci_doorbell(0, 0);
	EQI("with both, one message", 1, hc_msi_sent);
}

static void test_halted_controller(void)
{
	model_reset(0);
	xhci_attach((int64_t)(uintptr_t)g_bar);
	xhci_reset();
	xhci_config_slots(64);
	xhci_set_dcbaap(at(P_DCBAA));
	xhci_cmd_ring_init(at(P_CMD), at(P_CMD), CMD_TRBS);
	xhci_event_ring_init(at(P_EVT), at(P_EVT), EVT_TRBS, at(P_ERST),
			     at(P_ERST));
	xhci_intr_enable();

	/* R/S never set: the doorbell is ignored outright. */
	xhci_cmd_noop();
	xhci_doorbell(0, 0);
	EQI("a halted controller ignores the doorbell", 0, hc_cmds_run);
	EQI("so there is no event", E_NOEVENT, xhci_event_poll());

	EQI("run", OK, xhci_run());
	xhci_doorbell(0, 0);
	EQI("and once running it executes what was already there", 1,
	    hc_cmds_run);
	EQI("the completion arrives", OK, xhci_event_poll());
}

int main(void)
{
	/* PAGE ALIGNED, not malloc-aligned: the driver refuses a ring whose
	 * physical address is not 64-byte aligned, which is the specification's
	 * rule and the reason a 16-byte-aligned malloc is not good enough. */
	g_bar = aligned_alloc(4096, BAR_BYTES);
	g_ram = aligned_alloc(4096, BAR_BYTES);
	if (!g_bar || !g_ram) {
		printf("  FATAL: cannot allocate the model\n");
		return 2;
	}
	g_ram_base = (uint64_t)(uintptr_t)g_ram;

	test_attach();
	test_reset();
	test_program();
	test_noop();
	test_ring_wrap();
	test_interrupt_gates();
	test_halted_controller();

	free(g_bar);
	free(g_ram);
	return fk_report("xhci");
}
