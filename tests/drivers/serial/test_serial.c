/* Behavioural + differential test for src/drivers/serial/fk_serial.f90:
 * mocks fk_outb/fk_inb with a 16550 device model, asserts the exact port
 * trace of serial_init/serial_print_char/serial_print_string, and diffs
 * the driver's constants against Linux's include/uapi/linux/serial_reg.h.
 */
#include <linux/serial_reg.h>
#include <stdlib.h>
#include <string.h>
#include "fk_test.h"

/* Fortran bind(c) exports. */
int32_t serial_init(int32_t port);
void    serial_print_char(char c);
void    serial_print_string(const char *s);

/* Supplied by boot/io.S in the kernel; by the mock below here. */
void    fk_outb(int32_t port, int32_t value);
int32_t fk_inb(int32_t port);

#define COM1        0x3F8
#define COM2        0x2F8
#define PROBE_BYTE  0xAE	/* loopback self-test byte */

#define TX_SPINS    65535	/* Linux: arch/x86/boot/tty.c:30 */

#define MAX_STRING  4096

/* Sized for 2 * 65535 LSR reads plus the writes; recording saturates,
 * never wraps, and lsr_reads/oob are kept outside the trace. */
#define TRACE_MAX   140000

enum { ACC_W = 0, ACC_R = 1 };

struct acc {
	int32_t op;
	int32_t port;	/* absolute port */
	int32_t val;	/* raw int32 written, or the byte read back */
};

static struct {
	int32_t base;

	int absent;		/* no card: reads float to 0xFF */
	int dead;		/* LSR always reads 0x00 */
	int32_t echo_byte;	/* loopback payload; -1 = the byte written */

	/* LSR reads that must report not-ready before THRE asserts; re-armed
	 * after each accepted byte. thre_delay = 0 is an always-ready UART. */
	int32_t thre_delay;
	int32_t thre_left;

	int32_t ier, fcr, lcr, mcr, dll, dlm;

	uint8_t rx[16];
	int rx_len;

	/* bytes that left the chip with loopback off */
	uint8_t out[8192];
	size_t out_len;

	unsigned long lsr_reads;	/* since the last trace_clear */
	unsigned long oob;		/* accesses outside [base, base+7] */
	unsigned long dropped;		/* records lost to saturation */

	struct acc trace[TRACE_MAX];
	size_t ntrace;
} mock;

/* Full power-on reset of the modelled device. The Fortran module's own state
 * (serial_base, serial_ready) is process-global and is NOT reset here; only
 * serial_init() re-arms the driver. */
static void mock_reset(int32_t base)
{
	memset(&mock, 0, sizeof(mock));
	mock.base = base;
	mock.echo_byte = -1;
}

/* Drop the trace and derived counters, leaving the device state alone. */
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
	/* a full FIFO drops the byte; the driver never has 16 in flight */
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

/* THRE and TEMT assert together, as the chip does once the shift register
 * drains. */
static uint8_t lsr_value(void)
{
	uint8_t v = 0;

	if (mock.dead)
		return 0x00;
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

	trace_add(ACC_W, port, value);		/* raw, unmasked: raw_range_check needs it */
	if (mock.absent || off < 0 || off > 7)
		return;

	switch (off) {
	case 0:
		if (mock.lcr & UART_LCR_DLAB) {
			/* DLAB routes offset 0 to the divisor latch, not
			 * to the transmitter. */
			mock.dll = value & 0xFF;
		} else {
			uint8_t b = (uint8_t)(value & 0xFF);
			uint8_t d = mock.echo_byte < 0 ? b
						       : (uint8_t)mock.echo_byte;

			if (mock.mcr & UART_MCR_LOOP)
				rx_push(d);	/* loopback: never reaches the wire */
			else if (mock.out_len < sizeof(mock.out))
				mock.out[mock.out_len++] = b;
			mock.thre_left = mock.thre_delay;
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
		/* LSR and MSR are read-only on the chip; the write is still traced. */
		break;
	}
}

int32_t fk_inb(int32_t port)
{
	int32_t off = port - mock.base;
	int32_t v;

	if (mock.absent || off < 0 || off > 7) {
		/* A floating ISA port reads 0xFF, which has both THRE and DR set. */
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
	default:       v = 0x00;	/* MSR, SCR: not modelled */
	}
	trace_add(ACC_R, port, v);
	return v;
}

/* Expectations hold port OFFSETS; the base is added at compare time. */
static struct acc expect[64];
static size_t nexpect;

static void exp_reset(void) { nexpect = 0; }

static void exp_add(int32_t op, int32_t off, int32_t val)
{
	expect[nexpect++] = (struct acc){ op, off, val };
}

static const char *opname(int32_t op) { return op == ACC_W ? "OUT" : "IN " ; }

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

/* writes_only filters the trace down to its OUT accesses, so the init writes
 * are asserted independently of how many polls the mock's delay produced. */
static void trace_check(const char *what, int writes_only)
{
	static struct acc filt[TRACE_MAX];	/* static: too large for a stack frame */
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

/* Checks the RAW int32 handed to fk_outb: every later stage masks with 0xFF and
 * would launder a sign-extended byte away. iachar() returns 0..255 where
 * ichar() on a signed char delivers 0xFF as -1. */
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

/* The ten init writes, in order, in Linux's UART_* terms. */
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

	/* (1) Silent before init. Must run first: serial_ready is a private
	 * module variable that stays true for the rest of the process once
	 * serial_init() has run. */
	mock_reset(COM1);
	serial_print_char('X');
	serial_print_string("this must not appear");
	FK_EQ("pre-init: no port access", 0UL, (unsigned long)mock.ntrace, "%lu");
	FK_EQ("pre-init: nothing on the wire", 0UL, (unsigned long)mock.out_len, "%lu");

	/* (2) Linux's macros still hold the values the driver's constants assume. */
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

	FK_EQ("FCR init word", 0xC7,
	      (int)(UART_FCR_ENABLE_FIFO | UART_FCR_CLEAR_RCVR |
		    UART_FCR_CLEAR_XMIT | UART_FCR_TRIGGER_14), "0x%02X");
	FK_EQ("MCR loopback word", 0x1E,
	      (int)(UART_MCR_LOOP | UART_MCR_OUT2 | UART_MCR_OUT1 | UART_MCR_RTS),
	      "0x%02X");
	FK_EQ("MCR live word", 0x0F,
	      (int)(UART_MCR_DTR | UART_MCR_RTS | UART_MCR_OUT1 | UART_MCR_OUT2),
	      "0x%02X");

	/* (3) Init trace, access by access. thre_delay = 0 means ready on the
	 * first poll; LSR 0x60 is THRE|TEMT idle, 0x61 the same with the probe. */
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

	FK_EQ("init: divisor low  = 1", 1, (int)mock.dll, "%d");
	FK_EQ("init: divisor high = 0", 0, (int)mock.dlm, "%d");
	FK_EQ("init: every interrupt source off", 0, (int)mock.ier, "%d");
	FK_EQ("init: 8N1 selected, DLAB clear", (int)UART_LCR_WLEN8, (int)mock.lcr, "0x%02X");
	FK_EQ("init: FIFO enabled and cleared", 0xC7, (int)mock.fcr, "0x%02X");
	FK_EQ("init: port left live, loopback off", 0x0F, (int)mock.mcr, "0x%02X");
	FK_EQ("init: loopback really off", 0, (int)(mock.mcr & UART_MCR_LOOP), "%d");
	FK_EQ("init: probe discarded from RX FIFO", 0, mock.rx_len, "%d");
	/* The probe was written under loopback, so it must not reach the wire. */
	FK_EQ("init: probe never hit the wire", 0UL, (unsigned long)mock.out_len, "%lu");

	/* (3b) The ten writes must not depend on how fast the chip answers. */
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

	/* (4) With a THRE delay of K: K+1 LSR reads, then exactly one write. */
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

		/* Each character re-arms the wait: n characters cost n*(K+1) polls. */
		mock.thre_left = K;
		trace_clear();
		serial_print_string("abcd");
		FK_EQ("print_string: waits per character",
		      (unsigned long)(4 * (K + 1)), mock.lsr_reads, "%lu");
		wire_check("print_string with delay", (const uint8_t *)"abcd", 4);
	}

	/* (5) A dead UART must give up rather than spin forever. */
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

	/* (6) Strings: the terminator stops the loop and is not transmitted. */
	mock_reset(COM1);
	FK_EQ("string: init OK", 0, (int)serial_init(COM1), "%d");
	trace_clear();
	{
		static const char banner[] =
			"Fortran Kernel: UART Serial Initialized.\r\n";

		serial_print_string(banner);
		wire_check("banner", (const uint8_t *)banner, sizeof(banner) - 1);
	}
	check_ports("banner");
	raw_range_check("banner");

	trace_clear();
	serial_print_string("Hi\0HIDDEN");
	wire_check("embedded NUL stops the string", (const uint8_t *)"Hi", 2);

	trace_clear();
	serial_print_string("");
	FK_EQ("empty string: no port access", 0UL, (unsigned long)mock.ntrace, "%lu");
	FK_EQ("empty string: nothing on the wire", 0UL,
	      (unsigned long)mock.out_len, "%lu");

	/* (7) big[4096] is non-NUL, so stopping there can only be the bound. */
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

	/* (8) char is signed, so (char)0xFF reaches Fortran as -1 without iachar(). */
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

	/* (9) A failed loopback self-test returns 1 but must still arm the driver. */
	mock_reset(COM1);
	mock.echo_byte = 0x55;		/* present, but echoes the wrong byte */
	FK_EQ("self-test: wrong echo => status 1", 1, (int)serial_init(COM1), "%d");
	/* The sequence is unchanged; step 13 must still leave loopback off. */
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
	/* 0xFF satisfies both polls on the first read, so nothing spins. */
	FK_EQ("absent port: bring-up costs exactly the 13 contract accesses, no spin",
	      13UL, (unsigned long)mock.ntrace, "%lu");

	/* Steps 9..13 after a step-8 timeout are unspecified: no trace assert. */
	mock_reset(COM1);
	mock.dead = 1;
	FK_EQ("self-test: dead LSR => status 1", 1, (int)serial_init(COM1), "%d");
	check_ports("self-test dead LSR");
	FK_EQ("dead init: bounded, no runaway",
	      1, mock.lsr_reads <= 2UL * TX_SPINS, "%d");
	FK_EQ("dead init: nothing on the wire", 0UL,
	      (unsigned long)mock.out_len, "%lu");

	/* (10) The base port is an argument: 0x3F8 must not be touched. */
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

	/* Leave the module pointed back at COM1. */
	mock_reset(COM1);
	FK_EQ("re-init back to COM1", 0, (int)serial_init(COM1), "%d");

	return fk_report("serial");
}
