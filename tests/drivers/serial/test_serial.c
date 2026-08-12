/* Differential + behavioural test for src/drivers/serial/fk_serial.f90
 *
 * WHY THIS TEST EXISTS AT ALL. A serial driver is the one piece of a headless
 * kernel that cannot be debugged by the thing it is supposed to make
 * debuggable. If serial_init() programs the divisor latch with DLAB clear, the
 * only symptom is a silent COM1 -- indistinguishable from "the kernel died
 * before reaching Fortran", which is exactly the question the console was added
 * to answer. Everything below exists so that failure has a name and a line
 * number on the host, hours before anyone stares at an empty QEMU serial log.
 *
 * TWO ORACLES, because there are two independent ways to be wrong.
 *
 * (1) THE REGISTER NUMBERS ARE A TRANSLATION. Offsets 0..5 and the bit masks
 *     0x80/0x03/0xC7/0x1E/0x0F are not this project's inventions; they are the
 *     8250/16450/16550 programming interface as Linux itself spells it in
 *     include/uapi/linux/serial_reg.h. That header is #included here STRAIGHT
 *     OUT OF THE VENDOR TREE (see mk/serial.mk), and every expected byte in the
 *     init trace below is built from UART_* macros -- never from a literal.
 *     So the Fortran driver's constants are diffed against the kernel's own
 *     definitions rather than against a second hand-copied table that nobody
 *     ever checked against the first. A transposed FCR mask (0x7C for 0xC7) is
 *     the kind of slip that survives every amount of re-reading and produces a
 *     UART that works right up until the FIFO matters.
 *
 *     The Fortran parameters are not exported symbols -- they are named
 *     constants inside a module and have no ABI -- so they cannot be compared
 *     directly. They are compared through their only externally visible
 *     consequence: the exact sequence of bytes the driver pushes at the port.
 *
 * (2) THE DRIVER ITSELF IS NOT A TRANSLATION. There is no C original to diff
 *     against; a driver written from a hardware datasheet has no single
 *     upstream function that was ported. (test_gop_renderer.c documents the
 *     same situation for the renderer half of Phase 2.) So the driver is
 *     checked against a MOCK 16550 written here: a device model that records
 *     every port access in order and pushes back the way real silicon does.
 *     The mock supplies the fk_outb/fk_inb that boot/io.S supplies in the
 *     kernel, which is what makes a bare-metal driver testable in a process.
 *
 * THE FAILURE MODES THIS IS BUILT TO CATCH, and what each looks like on real
 * hardware:
 *
 *   * DLAB left set (or never set). The mock routes offset 0/1 through the
 *     divisor latch exactly as the chip does, so writing the divisor without
 *     DLAB lands the byte in the transmit register instead, and writing the
 *     probe with DLAB still set lands it in DLL. On hardware: a port at the
 *     wrong baud rate, i.e. a terminal full of garbage, or total silence.
 *   * An LSR poll that reads once and hopes. The mock has a settable "THRE
 *     asserts after N polls" delay, so the wait is exercised rather than
 *     trivially satisfied. On hardware: characters dropped under load, which
 *     shows up as a boot log with holes in it that nobody trusts.
 *   * An UNBOUNDED LSR poll. The dead-UART case below proves the driver gives
 *     up after exactly FK_SERIAL_TX_SPINS = 65535 reads. On hardware: a kernel
 *     that hangs at the first printed character on any machine whose firmware
 *     did not leave a UART at 0x3F8 -- a hang with no output, which is the
 *     worst possible failure for a debug console.
 *   * Sign extension through iachar()/fk_outb. Bytes 0x80..0xFF are the whole
 *     of the box-drawing and high-ASCII range; a signed char that reaches the
 *     port as -1 instead of 255 is invisible for plain text and mangles
 *     everything else. The mock records the RAW, UNMASKED int32 it was handed
 *     and asserts it lies in 0..255, precisely so masking cannot hide this.
 *   * A hardcoded 0x3F8. Every access is checked against [base, base+7], and
 *     one case drives 0x2F8 and asserts 0x3F8 is never touched.
 *   * A missing NUL. A 5000-byte unterminated buffer must produce exactly 4096
 *     bytes and stop. On hardware the alternative is a walk through kernel
 *     memory printing it out until something faults -- with no IDT (roadmap
 *     3.2) that fault is a triple fault and a silent reboot.
 *
 * WHAT THIS TEST CANNOT CATCH, stated honestly:
 *
 *   * That a REAL 16550 accepts this sequence. The mock is a model of the
 *     datasheet written by the same hand as the expectations, so it certifies
 *     internal consistency, not silicon. Only tools/qemu-boot-test.sh grepping
 *     the guest's serial output for the banner shows the sequence working
 *     end to end, and only hardware shows it working on hardware.
 *   * Timing. There is no notion of baud rate here; the divisor is checked to
 *     have landed in the latch (DLL=1, DLM=0 => 115200), not to have produced
 *     115200 baud on a wire.
 *   * Anything about boot/io.S. fk_outb/fk_inb are REPLACED here. Whether the
 *     real ones truncate to %di/%sil and zero-extend into EAX correctly is
 *     asserted by nothing in this file; it is a property of the assembly and,
 *     transitively, of the QEMU boot gate.
 *   * Concurrency. The driver has no locking and this test is single-threaded.
 *     Two CPUs printing at once will interleave bytes; that is a known and
 *     unaddressed property, not something asserted here either way.
 */
#include <linux/serial_reg.h>
#include <stdlib.h>
#include <string.h>
#include "fk_test.h"

/* Fortran bind(c) exports -- the C view of the roadmap 2.1 interface. */
int32_t serial_init(int32_t port);
void    serial_print_char(char c);
void    serial_print_string(const char *s);

/* The two symbols the Fortran module imports. In the kernel these are
 * boot/io.S; here they are the mock below, which is the entire reason a
 * driver whose only effect is on the ISA bus can be tested in a process. */
void    fk_outb(int32_t port, int32_t value);
int32_t fk_inb(int32_t port);

#define COM1        0x3F8
#define COM2        0x2F8
#define PROBE_BYTE  0xAE	/* the loopback self-test byte, contract step 9 */

/* The bound the driver must honour. Named here rather than spelled 65535 at
 * the use site because the number IS the assertion: it is Linux's own timeout
 * in arch/x86/boot/tty.c:30 ("unsigned timeout = 0xffff") around the identical
 * LSR/XMTRDY poll, and the driver cites the same source. If the driver ever
 * quietly changes its bound, this is the line that fails. */
#define TX_SPINS    65535

/* The truncation bound in serial_print_string. */
#define MAX_STRING  4096

/* Trace capacity. Sized for the pathological case, not the typical one: a
 * serial_init() against a UART whose LSR never asserts anything can legally
 * spin BOTH bounded polls, i.e. 2 * 65535 reads plus the ten writes, and a
 * trace that silently wrapped there would turn a real overrun into a passing
 * test. Recording saturates instead of wrapping, and the counters that matter
 * (lsr_reads, oob) are kept OUTSIDE the trace so saturation can never corrupt
 * an assertion. 140000 * 12 bytes is 1.6 MB of BSS, which costs nothing. */
#define TRACE_MAX   140000

enum { ACC_W = 0, ACC_R = 1 };

struct acc {
	int32_t op;	/* ACC_W or ACC_R */
	int32_t port;	/* absolute port number, as the driver named it */
	int32_t val;	/* RAW int32 written, or the byte read back */
};

/* ---- the mock 16550 ----------------------------------------------------- */

/* A model of the chip, not a stub. The distinction matters: a stub that
 * accepts every write and returns 0x60 from LSR makes the init trace test
 * pass for a driver that never sets DLAB, never leaves loopback, and reads
 * its own probe out of thin air. Every register below exists because getting
 * it wrong is a bug the driver could actually have. */
static struct {
	int32_t base;		/* where this port is assumed to live */

	/* device modes, all off by default */
	int absent;		/* no card on the bus: every read floats to 0xFF */
	int dead;		/* LSR always reads 0x00: nothing ever ready */
	int32_t echo_byte;	/* what loopback delivers; -1 = the byte written */

	/* transmit readiness. thre_left is the number of further LSR reads
	 * that must report NOT-ready before THRE asserts, re-armed to
	 * thre_delay after every byte accepted. thre_delay = 0 models an idle
	 * UART that is always ready, which is what QEMU behaves like. */
	int32_t thre_delay;
	int32_t thre_left;

	/* programmable state, all written by the driver */
	int32_t ier, fcr, lcr, mcr, dll, dlm;

	/* the receive FIFO. A real 16550 has 16 bytes; the driver only ever
	 * round-trips one, but the depth is modelled so that UART_FCR_CLEAR_RCVR
	 * has something real to clear. */
	uint8_t rx[16];
	int rx_len;

	/* the wire: bytes that left the chip with loopback OFF. This is what
	 * the string tests compare against -- the actual output of the console,
	 * not a count of writes. */
	uint8_t out[8192];
	size_t out_len;

	/* evidence, kept independent of the trace on purpose (see TRACE_MAX) */
	unsigned long lsr_reads;	/* LSR reads since the last trace_clear */
	unsigned long oob;		/* accesses outside [base, base+7] */
	unsigned long dropped;		/* trace records lost to saturation */

	struct acc trace[TRACE_MAX];
	size_t ntrace;
} mock;

/* Full power-on reset of the modelled device at a given base port.
 *
 * NOTE, and it is the reason several cases below look redundant: the FORTRAN
 * module's state (serial_base, serial_ready) is process-global and is NOT
 * reset by this function -- nothing in C can reach a private module variable.
 * serial_init() is the only thing that re-arms the driver, so any case that
 * needs a known driver state has to call it. That asymmetry is also why the
 * "silent before init" case has to run first: once anything has called
 * serial_init(), serial_ready is true for the rest of the process and the
 * pre-init behaviour can never be observed again. */
static void mock_reset(int32_t base)
{
	memset(&mock, 0, sizeof(mock));
	mock.base = base;
	mock.echo_byte = -1;		/* faithful loopback */
}

/* Drop the trace and the derived counters, leaving the DEVICE alone.
 * Used between phases of a case so that, say, the bytes of a string can be
 * examined without the thirteen accesses of init in front of them. */
static void trace_clear(void)
{
	mock.ntrace = 0;
	mock.dropped = 0;
	mock.lsr_reads = 0;
	mock.oob = 0;
	mock.out_len = 0;
}

static void trace_add(int32_t op, int32_t port, int32_t val)
{
	if (port < mock.base || port > mock.base + 7)
		mock.oob++;
	if (mock.ntrace < TRACE_MAX)
		mock.trace[mock.ntrace++] = (struct acc){ op, port, val };
	else
		mock.dropped++;
}

static void rx_push(uint8_t b)
{
	if (mock.rx_len < (int)sizeof(mock.rx))
		mock.rx[mock.rx_len++] = b;
	/* a full FIFO drops the byte and would set LSR_OE; the driver never
	 * gets near 16 bytes in flight, so overrun is modelled as a drop */
}

static uint8_t rx_pop(void)
{
	uint8_t b;
	int i;

	if (mock.rx_len == 0)
		return 0x00;		/* an empty RX register reads as 0 */
	b = mock.rx[0];
	for (i = 1; i < mock.rx_len; i++)
		mock.rx[i - 1] = mock.rx[i];
	mock.rx_len--;
	return b;
}

/* THRE and TEMT are reported TOGETHER.
 *
 * That is faithful to the chip when the shift register is idle, and it is
 * deliberately hostile to one specific bug: a driver that waits with
 * `if (lsr == UART_LSR_THRE)` instead of `if (iand(lsr, THRE) /= 0)` passes
 * against a model that returns a bare 0x20 and hangs forever against real
 * silicon, which sets 0x60 the instant the transmitter drains. Modelling only
 * the bit the driver cares about would certify the wrong thing. */
static uint8_t lsr_value(void)
{
	uint8_t v = 0;

	if (mock.dead)
		return 0x00;	/* wedged transmitter: nothing is ever ready */
	if (mock.thre_left > 0)
		mock.thre_left--;
	else
		v |= UART_LSR_THRE | UART_LSR_TEMT;
	if (mock.rx_len)
		v |= UART_LSR_DR;
	return v;
}

void fk_outb(int32_t port, int32_t value)
{
	int32_t off = port - mock.base;

	trace_add(ACC_W, port, value);		/* RAW value: see the sign-extension note */
	if (mock.absent || off < 0 || off > 7)
		return;				/* writes to nothing go nowhere */

	switch (off) {
	case 0:
		if (mock.lcr & UART_LCR_DLAB) {
			/* DLAB routes offset 0 to the divisor latch, NOT to the
			 * transmitter. Modelling this is what makes "wrote the
			 * divisor without setting DLAB" a visible failure
			 * (the byte appears on the wire) instead of a silent one. */
			mock.dll = value & 0xFF;
		} else {
			uint8_t b = (uint8_t)(value & 0xFF);
			uint8_t d = mock.echo_byte < 0 ? b
						       : (uint8_t)mock.echo_byte;

			if (mock.mcr & UART_MCR_LOOP)
				rx_push(d);	/* internal loopback */
			else if (mock.out_len < sizeof(mock.out))
				mock.out[mock.out_len++] = b;
			mock.thre_left = mock.thre_delay;	/* re-arm the wait */
		}
		break;
	case 1:
		if (mock.lcr & UART_LCR_DLAB)
			mock.dlm = value & 0xFF;
		else
			mock.ier = value & 0xFF;
		break;
	case 2:
		mock.fcr = value & 0xFF;
		if (value & UART_FCR_CLEAR_RCVR)
			mock.rx_len = 0;
		if (value & UART_FCR_CLEAR_XMIT)
			mock.thre_left = 0;	/* a cleared TX FIFO is empty */
		break;
	case 3:
		mock.lcr = value & 0xFF;
		break;
	case 4:
		mock.mcr = value & 0xFF;
		break;
	default:
		/* 5 (LSR), 6 (MSR) and 7 (SCR): LSR and MSR are read-only on the
		 * chip and the driver has no business writing any of them. The
		 * write is recorded, so the trace diff reports it. */
		break;
	}
}

int32_t fk_inb(int32_t port)
{
	int32_t off = port - mock.base;
	int32_t v;

	if (mock.absent || off < 0 || off > 7) {
		/* An ISA port with nothing behind it floats high. This is the
		 * realistic "there is no UART here" case, and it is nastier
		 * than returning zero: 0xFF has both THRE and DR set, so every
		 * poll succeeds instantly and only the probe read-back can tell
		 * the driver that the port is imaginary. */
		v = 0xFF;
		trace_add(ACC_R, port, v);
		if (off == UART_LSR)
			mock.lsr_reads++;
		return v;
	}

	switch (off) {
	case UART_RX:  v = rx_pop();				break;
	case UART_IER: v = (mock.lcr & UART_LCR_DLAB) ? mock.dlm : mock.ier; break;
	case UART_IIR: v = UART_IIR_NO_INT |
			   ((mock.fcr & UART_FCR_ENABLE_FIFO) ? 0xC0 : 0x00); break;
	case UART_LCR: v = mock.lcr;				break;
	case UART_MCR: v = mock.mcr;				break;
	case UART_LSR: v = lsr_value(); mock.lsr_reads++;	break;
	default:       v = 0x00;	/* MSR, SCR: not modelled, never used */
	}
	trace_add(ACC_R, port, v);
	return v;
}

/* ---- expected-trace construction and diffing ---------------------------- */

/* Expected accesses are built from UART_* macros and PORT OFFSETS; the base is
 * added at compare time, so the same expectation is reused for 0x3F8 and
 * 0x2F8 and a driver that hardcoded one of them cannot satisfy both. */
static struct acc expect[64];
static size_t nexpect;

static void exp_reset(void) { nexpect = 0; }

static void exp_add(int32_t op, int32_t off, int32_t val)
{
	expect[nexpect++] = (struct acc){ op, off, val };
}

static const char *opname(int32_t op) { return op == ACC_W ? "OUT" : "IN " ; }

/* Print both sequences side by side. A bare "trace mismatch" on a thirteen-step
 * register dance is nearly useless to debug; the offending step, and what the
 * device saw instead, is the whole value of the assertion. */
static void trace_dump(const char *what, const struct acc *got, size_t ngot)
{
	size_t i, n = ngot > nexpect ? ngot : nexpect;

	printf("  TRACE MISMATCH %s (expected %zu accesses, saw %zu)\n",
	       what, nexpect, ngot);
	for (i = 0; i < n && i < 32; i++) {
		printf("   %2zu  ", i);
		if (i < nexpect)
			printf("want %s port+%d = 0x%02X",
			       opname(expect[i].op), expect[i].port,
			       (unsigned)expect[i].val);
		else
			printf("want (nothing)              ");
		if (i < ngot)
			printf("   got %s 0x%03X    = 0x%02X\n",
			       opname(got[i].op), (unsigned)got[i].port,
			       (unsigned)got[i].val);
		else
			printf("   got (nothing)\n");
	}
	if (n > 32)
		printf("   ... %zu more\n", n - 32);
}

/* Compare the recorded trace against `expect`, element by element.
 *
 * `writes_only` filters the trace down to its OUT accesses. That mode exists
 * for the cases where the number of LSR reads is a property of the mock's
 * configured delay rather than of the driver: the ten writes of the init
 * sequence must be identical whether the UART answers on the first poll or
 * the ninth, and asserting that separately from the poll counts keeps a
 * timing change from being reported as a register-programming bug. */
static void trace_check(const char *what, int writes_only)
{
	static struct acc filt[TRACE_MAX];	/* static: 1.6 MB is not a stack frame */
	const struct acc *got = mock.trace;
	size_t ngot = mock.ntrace, i;
	unsigned long before = fk_fails;

	if (writes_only) {
		size_t n = 0;

		for (i = 0; i < mock.ntrace; i++)
			if (mock.trace[i].op == ACC_W)
				filt[n++] = mock.trace[i];
		got = filt;
		ngot = n;
	}

	fk_checks++;
	if (ngot != nexpect)
		fk_fails++;
	for (i = 0; i < nexpect && i < ngot; i++) {
		fk_checks++;
		if (got[i].op != expect[i].op ||
		    got[i].port != mock.base + expect[i].port ||
		    got[i].val != expect[i].val)
			fk_fails++;
	}
	if (fk_fails != before)
		trace_dump(what, got, ngot);
}

/* Every access must land inside the eight-port window the driver was given.
 * A driver that computed base+8 for LSR would still "work" on a machine where
 * the next port happens to float high, and would corrupt whatever device owns
 * that address on a machine where it does not. */
static void check_ports(const char *what)
{
	fk_checks++;
	if (mock.oob) {
		printf("  OUT OF RANGE %s: %lu access(es) outside [0x%03X,0x%03X]\n",
		       what, mock.oob, (unsigned)mock.base, (unsigned)mock.base + 7);
		fk_fails++;
	}
	fk_checks++;
	if (mock.dropped) {
		printf("  TRACE SATURATED %s: %lu record(s) dropped\n",
		       what, mock.dropped);
		fk_fails++;
	}
}

/* Compare the captured wire against the bytes the console was asked to emit.
 * Byte for byte, and the length first, because "emitted a prefix" and
 * "emitted the terminator too" are both failures a spot check would pass. */
static void wire_check(const char *what, const uint8_t *want, size_t nwant)
{
	size_t i;
	unsigned long before = fk_fails;

	fk_checks++;
	if (mock.out_len != nwant) {
		printf("  WIRE %s: emitted %zu bytes, expected %zu\n",
		       what, mock.out_len, nwant);
		fk_fails++;
	}
	for (i = 0; i < nwant && i < mock.out_len; i++) {
		fk_checks++;
		if (mock.out[i] != want[i]) {
			if (fk_fails - before < 6)
				printf("  WIRE %s: byte %zu is 0x%02X, expected 0x%02X\n",
				       what, i, mock.out[i], want[i]);
			fk_fails++;
		}
	}
}

/* The bytes the driver handed to fk_outb must already be 0..255.
 *
 * This is the sign-extension assertion and it has to look at the RAW int32,
 * because every later stage of the model masks with 0xFF and would launder the
 * bug away. Fortran has no unsigned types; if the driver reaches the port via
 * ichar() on a signed char, or lets a c_char sign-extend anywhere on the path,
 * 0xFF arrives as -1. The contract's answer is iachar(), which is defined
 * against ASCII and returns 0..255 -- this checks that answer was used. */
static void raw_range_check(const char *what)
{
	size_t i;
	unsigned long before = fk_fails;

	for (i = 0; i < mock.ntrace; i++) {
		if (mock.trace[i].op != ACC_W)
			continue;
		fk_checks++;
		if (mock.trace[i].val < 0 || mock.trace[i].val > 255) {
			if (fk_fails - before < 6)
				printf("  RAW %s: access %zu wrote %d (0x%08X), "
				       "which is not a byte\n",
				       what, i, mock.trace[i].val,
				       (unsigned)mock.trace[i].val);
			fk_fails++;
		}
	}
}

/* The ten writes of the init sequence, in order, entirely in Linux's terms.
 * Not one literal appears on the right-hand side of these calls except the
 * divisor (1, 0) and the probe byte, which are this project's choices and not
 * the chip's. That is what makes the register table a translation with an
 * oracle instead of a list someone typed once. */
static void exp_init_writes(void)
{
	exp_add(ACC_W, UART_IER, 0x00);
	exp_add(ACC_W, UART_LCR, UART_LCR_DLAB);
	exp_add(ACC_W, UART_DLL, 0x01);
	exp_add(ACC_W, UART_DLM, 0x00);
	exp_add(ACC_W, UART_LCR, UART_LCR_WLEN8);
	exp_add(ACC_W, UART_FCR, UART_FCR_ENABLE_FIFO | UART_FCR_CLEAR_RCVR |
				 UART_FCR_CLEAR_XMIT | UART_FCR_TRIGGER_14);
	exp_add(ACC_W, UART_MCR, UART_MCR_LOOP | UART_MCR_OUT2 |
				 UART_MCR_OUT1 | UART_MCR_RTS);
	exp_add(ACC_W, UART_TX,  PROBE_BYTE);
	exp_add(ACC_W, UART_FCR, UART_FCR_ENABLE_FIFO | UART_FCR_CLEAR_RCVR |
				 UART_FCR_CLEAR_XMIT | UART_FCR_TRIGGER_14);
	exp_add(ACC_W, UART_MCR, UART_MCR_DTR | UART_MCR_RTS |
				 UART_MCR_OUT1 | UART_MCR_OUT2);
}

int main(void)
{
	static uint8_t want[8192];
	static char big[5000];
	int i;

	/* ================================================================
	 * (1) SILENCE BEFORE INIT -- and this MUST be the first executable
	 * statement in the process that touches the driver.
	 *
	 * serial_ready is a private module variable with static storage; once
	 * serial_init() has run it stays true for the life of the process, so
	 * there is exactly one opportunity to observe the uninitialised state
	 * and it is here. The property matters because kernel_main may grow a
	 * panic path that prints before the console exists: writing to an
	 * unprogrammed 0x3F8 is at best garbage on the wire and at worst a
	 * poll against an LSR that never answers.
	 * ================================================================ */
	mock_reset(COM1);
	serial_print_char('X');
	serial_print_string("this must not appear");
	FK_EQ("pre-init: no port access", 0UL, (unsigned long)mock.ntrace, "%lu");
	FK_EQ("pre-init: nothing on the wire", 0UL, (unsigned long)mock.out_len, "%lu");

	/* ================================================================
	 * (2) THE REGISTER-DEFINITION ORACLE, layer A.
	 *
	 * The init trace below is built entirely from UART_* macros, so it
	 * already diffs the driver against Linux. These checks pin the OTHER
	 * side: that Linux's macros still hold the values the roadmap 2.1
	 * contract writes down. Without them, a vendor kernel bump that
	 * renumbered a register would surface as "the serial driver broke",
	 * with no hint that nothing in this repository changed. With them the
	 * failure names itself.
	 * ================================================================ */
	FK_EQ("UART_TX  offset", 0, (int)UART_TX,  "%d");
	FK_EQ("UART_RX  offset", 0, (int)UART_RX,  "%d");
	FK_EQ("UART_DLL offset", 0, (int)UART_DLL, "%d");
	FK_EQ("UART_IER offset", 1, (int)UART_IER, "%d");
	FK_EQ("UART_DLM offset", 1, (int)UART_DLM, "%d");
	FK_EQ("UART_FCR offset", 2, (int)UART_FCR, "%d");
	FK_EQ("UART_IIR offset", 2, (int)UART_IIR, "%d");
	FK_EQ("UART_LCR offset", 3, (int)UART_LCR, "%d");
	FK_EQ("UART_MCR offset", 4, (int)UART_MCR, "%d");
	FK_EQ("UART_LSR offset", 5, (int)UART_LSR, "%d");

	FK_EQ("UART_LCR_DLAB",        0x80, (int)UART_LCR_DLAB,        "0x%02X");
	FK_EQ("UART_LCR_WLEN8",       0x03, (int)UART_LCR_WLEN8,       "0x%02X");
	FK_EQ("UART_FCR_ENABLE_FIFO", 0x01, (int)UART_FCR_ENABLE_FIFO, "0x%02X");
	FK_EQ("UART_FCR_CLEAR_RCVR",  0x02, (int)UART_FCR_CLEAR_RCVR,  "0x%02X");
	FK_EQ("UART_FCR_CLEAR_XMIT",  0x04, (int)UART_FCR_CLEAR_XMIT,  "0x%02X");
	FK_EQ("UART_FCR_TRIGGER_14",  0xC0, (int)UART_FCR_TRIGGER_14,  "0x%02X");
	FK_EQ("UART_MCR_DTR",         0x01, (int)UART_MCR_DTR,         "0x%02X");
	FK_EQ("UART_MCR_RTS",         0x02, (int)UART_MCR_RTS,         "0x%02X");
	FK_EQ("UART_MCR_OUT1",        0x04, (int)UART_MCR_OUT1,        "0x%02X");
	FK_EQ("UART_MCR_OUT2",        0x08, (int)UART_MCR_OUT2,        "0x%02X");
	FK_EQ("UART_MCR_LOOP",        0x10, (int)UART_MCR_LOOP,        "0x%02X");
	FK_EQ("UART_LSR_DR",          0x01, (int)UART_LSR_DR,          "0x%02X");
	FK_EQ("UART_LSR_THRE",        0x20, (int)UART_LSR_THRE,        "0x%02X");

	/* the composite masks the contract spells out, as Linux composes them */
	FK_EQ("FCR init word", 0xC7,
	      (int)(UART_FCR_ENABLE_FIFO | UART_FCR_CLEAR_RCVR |
		    UART_FCR_CLEAR_XMIT | UART_FCR_TRIGGER_14), "0x%02X");
	FK_EQ("MCR loopback word", 0x1E,
	      (int)(UART_MCR_LOOP | UART_MCR_OUT2 | UART_MCR_OUT1 | UART_MCR_RTS),
	      "0x%02X");
	FK_EQ("MCR live word", 0x0F,
	      (int)(UART_MCR_DTR | UART_MCR_RTS | UART_MCR_OUT1 | UART_MCR_OUT2),
	      "0x%02X");

	/* ================================================================
	 * (3) THE INIT SEQUENCE, ACCESS BY ACCESS.
	 *
	 * With thre_delay = 0 the device is ready on the first poll, so the
	 * contract's thirteen steps produce exactly thirteen accesses and the
	 * whole trace -- reads included, with the values the device returned --
	 * can be asserted. The two LSR values are not arbitrary: 0x60 is
	 * THRE|TEMT on an idle transmitter and 0x61 is the same with the
	 * looped-back probe waiting in the RX FIFO.
	 * ================================================================ */
	mock_reset(COM1);
	FK_EQ("init: status OK", 0, (int)serial_init(COM1), "%d");

	exp_reset();
	exp_add(ACC_W, UART_IER, 0x00);
	exp_add(ACC_W, UART_LCR, UART_LCR_DLAB);
	exp_add(ACC_W, UART_DLL, 0x01);
	exp_add(ACC_W, UART_DLM, 0x00);
	exp_add(ACC_W, UART_LCR, UART_LCR_WLEN8);
	exp_add(ACC_W, UART_FCR, UART_FCR_ENABLE_FIFO | UART_FCR_CLEAR_RCVR |
				 UART_FCR_CLEAR_XMIT | UART_FCR_TRIGGER_14);
	exp_add(ACC_W, UART_MCR, UART_MCR_LOOP | UART_MCR_OUT2 |
				 UART_MCR_OUT1 | UART_MCR_RTS);
	exp_add(ACC_R, UART_LSR, UART_LSR_THRE | UART_LSR_TEMT);
	exp_add(ACC_W, UART_TX,  PROBE_BYTE);
	exp_add(ACC_R, UART_LSR, UART_LSR_THRE | UART_LSR_TEMT | UART_LSR_DR);
	exp_add(ACC_R, UART_RX,  PROBE_BYTE);
	exp_add(ACC_W, UART_FCR, UART_FCR_ENABLE_FIFO | UART_FCR_CLEAR_RCVR |
				 UART_FCR_CLEAR_XMIT | UART_FCR_TRIGGER_14);
	exp_add(ACC_W, UART_MCR, UART_MCR_DTR | UART_MCR_RTS |
				 UART_MCR_OUT1 | UART_MCR_OUT2);
	trace_check("init(0x3F8)", 0);
	check_ports("init(0x3F8)");
	raw_range_check("init(0x3F8)");
	FK_EQ("init: exactly 13 accesses", 13UL, (unsigned long)mock.ntrace, "%lu");

	/* Post-conditions on the DEVICE, which are what the driver was for.
	 * These are separate from the trace on purpose: the trace says the
	 * right bytes were sent, these say the chip ended up in the right
	 * state -- and only the device model can tell you that the divisor
	 * reached the latch rather than the transmitter. */
	FK_EQ("init: divisor low  = 1", 1, (int)mock.dll, "%d");
	FK_EQ("init: divisor high = 0", 0, (int)mock.dlm, "%d");
	FK_EQ("init: every interrupt source off", 0, (int)mock.ier, "%d");
	FK_EQ("init: 8N1 selected, DLAB clear", (int)UART_LCR_WLEN8, (int)mock.lcr, "0x%02X");
	FK_EQ("init: FIFO enabled and cleared", 0xC7, (int)mock.fcr, "0x%02X");
	FK_EQ("init: port left live, loopback off", 0x0F, (int)mock.mcr, "0x%02X");
	FK_EQ("init: loopback really off", 0, (int)(mock.mcr & UART_MCR_LOOP), "%d");
	/* Step 12's FCR write is the one that matters here: without it the
	 * probe byte sits in the RX FIFO and the first thing any future
	 * receive path reads is 0xAE, not user data. */
	FK_EQ("init: probe discarded from RX FIFO", 0, mock.rx_len, "%d");
	/* And the probe must never have reached the wire -- it was written
	 * while loopback was on. A 0xAE at the head of the boot log is the
	 * symptom of setting MCR live before the self-test rather than after. */
	FK_EQ("init: probe never hit the wire", 0UL, (unsigned long)mock.out_len, "%lu");

	/* ================================================================
	 * (3b) THE SAME INIT AGAINST A SLOW UART.
	 *
	 * thre_delay = 0 never exercises the two waits in steps 8 and 10 -- the
	 * device is ready before the driver asks. Repeat with a delay so the
	 * polls actually loop, and assert that the TEN WRITES are byte for
	 * byte identical. If register programming is coupled to how quickly the
	 * chip answers, this is where it shows.
	 * ================================================================ */
	mock_reset(COM1);
	mock.thre_delay = 9;
	mock.thre_left = 9;
	FK_EQ("init(slow): status OK", 0, (int)serial_init(COM1), "%d");
	exp_reset();
	exp_init_writes();
	trace_check("init(0x3F8) with 9-poll THRE delay", 1);
	check_ports("init(0x3F8) slow");
	FK_EQ("init(slow): divisor low  = 1", 1, (int)mock.dll, "%d");
	FK_EQ("init(slow): port left live", 0x0F, (int)mock.mcr, "0x%02X");

	/* ================================================================
	 * (4) serial_print_char WAITS FOR THRE.
	 *
	 * With a delay of K the driver must read LSR exactly K+1 times -- K
	 * reads that say "not yet" and one that says "go" -- and then perform
	 * exactly one write, of the byte, to the transmit register. This is the
	 * assertion that separates a driver that polls from one that reads LSR
	 * once and writes anyway; the latter is correct on an idle emulated
	 * UART and drops characters on real hardware under load.
	 * ================================================================ */
	mock_reset(COM1);
	FK_EQ("prechar: init OK", 0, (int)serial_init(COM1), "%d");
	{
		const int K = 12;

		mock.thre_delay = K;
		mock.thre_left = K;
		trace_clear();
		serial_print_char('Z');
		FK_EQ("print_char: K+1 LSR reads", (unsigned long)(K + 1),
		      mock.lsr_reads, "%lu");
		FK_EQ("print_char: K+2 accesses total", (unsigned long)(K + 2),
		      (unsigned long)mock.ntrace, "%lu");
		FK_EQ("print_char: last access is a write", ACC_W,
		      mock.ntrace ? mock.trace[mock.ntrace - 1].op : -1, "%d");
		FK_EQ("print_char: written to TX", (int)(COM1 + UART_TX),
		      mock.ntrace ? mock.trace[mock.ntrace - 1].port : -1, "0x%03X");
		FK_EQ("print_char: wrote 'Z'", (int)'Z',
		      mock.ntrace ? mock.trace[mock.ntrace - 1].val : -1, "0x%02X");
		check_ports("print_char with delay");

		/* Each character re-arms the wait, so n characters cost
		 * n*(K+1) polls. A driver that waited once and then blasted a
		 * whole string would pass the single-character test above. */
		mock.thre_left = K;
		trace_clear();
		serial_print_string("abcd");
		FK_EQ("print_string: waits per character",
		      (unsigned long)(4 * (K + 1)), mock.lsr_reads, "%lu");
		wire_check("print_string with delay", (const uint8_t *)"abcd", 4);
	}

	/* ================================================================
	 * (5) A DEAD UART CANNOT HANG THE KERNEL.
	 *
	 * The single most important assertion in this file. If the poll in
	 * serial_print_char is unbounded, a machine whose firmware left no UART
	 * at 0x3F8 hangs at the FIRST character of the boot banner, with no
	 * output at all -- a kernel that appears to die before Fortran, caused
	 * entirely by the code that was supposed to prove it did not.
	 *
	 * The number is asserted exactly, not as "at most a lot": 65535 is the
	 * bound Linux uses in arch/x86/boot/tty.c:30 and the contract requires
	 * it, so a driver that silently spins 2**31 times is a failure here
	 * even though it also terminates.
	 *
	 * Note the ordering: init runs against a HEALTHY device (the driver
	 * has to be armed at all), and the UART dies afterwards -- which is
	 * also the realistic sequence for a hot-unplugged USB serial adapter.
	 * ================================================================ */
	mock_reset(COM1);
	FK_EQ("dead: init OK first", 0, (int)serial_init(COM1), "%d");
	mock.dead = 1;
	trace_clear();
	serial_print_char('!');
	FK_EQ("dead UART: exactly 65535 LSR reads", (unsigned long)TX_SPINS,
	      mock.lsr_reads, "%lu");
	FK_EQ("dead UART: byte dropped, not written", (unsigned long)TX_SPINS,
	      (unsigned long)mock.ntrace, "%lu");
	FK_EQ("dead UART: nothing on the wire", 0UL,
	      (unsigned long)mock.out_len, "%lu");
	check_ports("dead UART");
	mock.dead = 0;

	/* ================================================================
	 * (6) STRINGS: the terminator stops the loop and is not transmitted.
	 * ================================================================ */
	mock_reset(COM1);
	FK_EQ("string: init OK", 0, (int)serial_init(COM1), "%d");
	trace_clear();
	{
		/* The real banner from fk_kmain.f90, and its length taken from
		 * sizeof rather than typed in: a hand-counted length that is one
		 * short turns "the driver dropped the final byte" into a passing
		 * test, which is the exact bug this case is here to find. */
		static const char banner[] =
			"Fortran Kernel: UART Serial Initialized.\r\n";

		serial_print_string(banner);
		wire_check("banner", (const uint8_t *)banner, sizeof(banner) - 1);
	}
	check_ports("banner");
	raw_range_check("banner");

	/* A NUL in the middle ends the string there. The trailing bytes are
	 * real, readable memory, so a driver that walked past the terminator
	 * would emit them without faulting and only ever be caught here. */
	trace_clear();
	serial_print_string("Hi\0HIDDEN");
	wire_check("embedded NUL stops the string", (const uint8_t *)"Hi", 2);

	/* The empty string is one NUL and no bytes: zero accesses, not even an
	 * LSR poll, because the loop must terminate before the first wait. */
	trace_clear();
	serial_print_string("");
	FK_EQ("empty string: no port access", 0UL, (unsigned long)mock.ntrace, "%lu");
	FK_EQ("empty string: nothing on the wire", 0UL,
	      (unsigned long)mock.out_len, "%lu");

	/* ================================================================
	 * (7) TRUNCATION AT 4096 -- the missing-terminator bound.
	 *
	 * Built at run time and deliberately NOT NUL-terminated within the
	 * region the driver may read. Without FK_SERIAL_MAX_STRING the driver
	 * walks kernel memory emitting it a byte at a time until it hits an
	 * unmapped page; with no IDT (roadmap 3.2) that page fault escalates to
	 * a triple fault and the machine reboots with an empty console. A
	 * truncated line is an incomparably better outcome, and this asserts
	 * the driver chose it.
	 *
	 * The buffer is 5000 bytes so that the first 4096 are legitimately
	 * readable: the point is to prove the driver STOPS at 4096, not to
	 * catch it reading out of bounds (which is ASan's job, not this
	 * file's). The 4097th byte is non-NUL, so stopping there can only be
	 * the bound and not an accidental terminator.
	 * ================================================================ */
	for (i = 0; i < (int)sizeof(big); i++)
		big[i] = (char)('A' + (i % 26));	/* never 0 */
	trace_clear();
	serial_print_string(big);
	for (i = 0; i < MAX_STRING; i++)
		want[i] = (uint8_t)big[i];
	wire_check("unterminated 5000-byte string truncates at 4096", want, MAX_STRING);
	FK_EQ("truncation: 4097th byte is not a NUL", 0,
	      big[MAX_STRING] == '\0', "%d");
	check_ports("truncation");

	/* ================================================================
	 * (8) HIGH-BIT BYTES SURVIVE.
	 *
	 * char is signed on x86-64, so (char)0xFF is -1 all the way to the
	 * Fortran dummy argument. iachar() is specified to return 0..255 and
	 * the contract requires it over ichar() for exactly this reason. Both
	 * halves are checked: the byte that reached the wire, and the RAW
	 * int32 that reached fk_outb -- the second is the one that catches
	 * sign extension, because the first is masked and would show 0xFF
	 * either way.
	 * ================================================================ */
	trace_clear();
	for (i = 0x80; i <= 0xFF; i++)
		serial_print_char((char)i);
	for (i = 0; i < 128; i++)
		want[i] = (uint8_t)(0x80 + i);
	wire_check("high-bit bytes 0x80..0xFF", want, 128);
	raw_range_check("high-bit bytes");
	{
		size_t t, w = 0;

		for (t = 0; t < mock.ntrace; t++) {
			if (mock.trace[t].op != ACC_W)
				continue;
			FK_EQ("high-bit raw value", (int)(0x80 + w),
			      mock.trace[t].val, "0x%02X");
			w++;
		}
		FK_EQ("high-bit: 128 writes", 128UL, (unsigned long)w, "%lu");
	}

	/* ================================================================
	 * (9) THE SELF-TEST ACTUALLY TESTS SOMETHING.
	 *
	 * serial_init returns 1 -- not 0 -- whenever the loopback does not
	 * hand back the probe. The two cases below are the two real ones:
	 * a UART that is present but broken (echoes the wrong byte), and a
	 * port with nothing behind it at all (every read floats to 0xFF, which
	 * is the nasty case because 0xFF has THRE and DR set, so both polls
	 * succeed instantly and only the read-back can tell).
	 *
	 * In BOTH cases the driver must still arm itself: the contract says
	 * serial_base/serial_ready are set unconditionally, because a debug
	 * console that refuses to speak because it doubts itself is strictly
	 * worse than one that speaks into a void. That is asserted after each
	 * failure by checking that print still drives the port.
	 * ================================================================ */
	mock_reset(COM1);
	mock.echo_byte = 0x55;		/* present, but the loopback lies */
	FK_EQ("self-test: wrong echo => status 1", 1, (int)serial_init(COM1), "%d");
	/* A failed self-test changes the STATUS, not the sequence. The contract's
	 * thirteen steps still run -- in particular step 13, without which the
	 * port would be left in loopback and every subsequent character would
	 * vanish into the chip instead of going out on the wire. */
	exp_reset();
	exp_init_writes();
	trace_check("init with a lying loopback", 1);
	check_ports("self-test wrong echo");
	mock.echo_byte = -1;
	trace_clear();
	serial_print_char('k');
	wire_check("armed anyway after a failed self-test",
		   (const uint8_t *)"k", 1);

	mock_reset(COM1);
	mock.absent = 1;		/* nothing on the bus: reads float high */
	FK_EQ("self-test: absent port => status 1", 1, (int)serial_init(COM1), "%d");
	exp_reset();
	exp_init_writes();
	trace_check("init against an absent port", 1);
	check_ports("self-test absent port");
	/* THE ABSENT PORT MUST NOT SPIN, and this is the assertion that says so.
	 *
	 * What was here before -- FK_EQ(..., 0UL, mock.out_len) -- could not fail:
	 * fk_outb() returns at the `mock.absent` guard above BEFORE the branch that
	 * appends to mock.out, so out_len is structurally 0 for this phase whatever
	 * the driver does. A driver that transmitted 4096 bytes would have scored
	 * the same pass. It consumed a check and asserted nothing.
	 *
	 * The property that IS falsifiable here is the access COUNT, and it happens
	 * to be the one thing about a floating bus that is easy to get backwards.
	 * A missing port reads 0xFF, and 0xFF has UART_LSR_THRE (0x20) and
	 * UART_LSR_DR (0x01) both set -- so both of serial_init's polls are
	 * satisfied by their FIRST read and the spin bound is never approached.
	 * The whole bring-up is therefore exactly the fixed 13 accesses of the
	 * contract sequence: 10 writes, plus one LSR read per poll, plus the probe
	 * read-back. A driver that polled in a loop, re-read a register, or
	 * retried the probe would land on a different number, and 65535-deep
	 * spinning would be unmissable.
	 *
	 * This also pins the claim fk_serial.f90 makes at FK_SERIAL_TX_SPINS: the
	 * bound does NOT cover the 0xFF case, the 0xAE probe read-back does. Two
	 * files, one asserted fact. */
	FK_EQ("absent port: bring-up costs exactly the 13 contract accesses, no spin",
	      13UL, (unsigned long)mock.ntrace, "%lu");

	/* A UART whose LSR never answers must not hang serial_init either --
	 * and must report failure. The exact trace is deliberately NOT
	 * asserted here: the contract fixes the status ("1 if r differs OR
	 * either poll timed out") but does NOT say whether steps 9..13 still
	 * run after the step-8 timeout, so an exact-sequence assertion would
	 * be encoding this test's guess as a requirement. What is asserted is
	 * everything the contract does fix: it terminates, it stays inside its
	 * eight ports, and it says so. */
	mock_reset(COM1);
	mock.dead = 1;
	FK_EQ("self-test: dead LSR => status 1", 1, (int)serial_init(COM1), "%d");
	check_ports("self-test dead LSR");
	FK_EQ("dead init: bounded, no runaway",
	      1, mock.lsr_reads <= 2UL * TX_SPINS, "%d");
	FK_EQ("dead init: nothing on the wire", 0UL,
	      (unsigned long)mock.out_len, "%lu");

	/* ================================================================
	 * (10) THE BASE PORT IS AN ARGUMENT, NOT A CONSTANT.
	 *
	 * COM2 is 0x2F8. Everything must move with it, and 0x3F8 must not be
	 * touched even once -- a driver that took `port` for init and then
	 * printed to a hardcoded 0x3F8 would pass every case above, because
	 * every case above used COM1. On the target machine a stray write to
	 * 0x3F8 is not harmless: it is whatever device the firmware actually
	 * put there.
	 * ================================================================ */
	mock_reset(COM2);
	FK_EQ("COM2: status OK", 0, (int)serial_init(COM2), "%d");
	exp_reset();
	exp_init_writes();
	trace_check("init(0x2F8)", 1);
	check_ports("init(0x2F8)");
	{
		size_t t;
		unsigned long stray = 0;

		for (t = 0; t < mock.ntrace; t++)
			if (mock.trace[t].port >= COM1 && mock.trace[t].port <= COM1 + 7)
				stray++;
		FK_EQ("COM2 init: never touched 0x3F8", 0UL, stray, "%lu");
	}

	trace_clear();
	serial_print_string("com2\r\n");
	wire_check("COM2 print", (const uint8_t *)"com2\r\n", 6);
	check_ports("COM2 print");
	{
		size_t t;
		unsigned long stray = 0;

		for (t = 0; t < mock.ntrace; t++)
			if (mock.trace[t].port >= COM1 && mock.trace[t].port <= COM1 + 7)
				stray++;
		FK_EQ("COM2 print: never touched 0x3F8", 0UL, stray, "%lu");
	}

	/* Leave the module pointed back at COM1, which is where roadmap 2.1
	 * says the console lives. Nothing after this depends on it, but a
	 * process that exits with the driver aimed at a port no caller expects
	 * is a trap for whoever appends the next case. */
	mock_reset(COM1);
	FK_EQ("re-init back to COM1", 0, (int)serial_init(COM1), "%d");

	return fk_report("serial");
}
