/* SPDX-License-Identifier: GPL-2.0 */
/* Test for src/cpu/fk_syscall.f90: roadmap 6.3's syscall ABI trap.
 *
 * THIS FILE MUST NOT EXECUTE WRMSR AND DOES NOT, which is the constraint that
 * shapes everything below. A host test that programmed the real MSR_LSTAR
 * would point THIS MACHINE's system calls at a Fortran routine inside a test
 * binary. So fk_rdmsr and fk_wrmsr are supplied here as a MODEL MSR FILE -- an
 * array with the same read/write semantics -- which turns out to be worth more
 * than the instruction would be: a model can be made to REFUSE a write, and
 * that is the only way to check that syscall_init notices.
 *
 * THREE CHANNELS:
 *
 *   (1) THE CONSTANTS ARE THE KERNEL'S, and unusually they are all of them.
 *       asm/msr-index.h and uapi/asm/processor-flags.h both compile standalone
 *       out of the vendor tree, so every MSR number, EFER_SCE, and every one of
 *       the fourteen flags in FMASK is spelled with the kernel's own name.
 *       FK_SYSCALL_FMASK is diffed against the OR of that list rather than
 *       against 0x257FD5 written out again.
 *
 *   (2) THE INIT SEQUENCE IS RUN AGAINST THE MODEL, including its failure
 *       paths. A register that silently does not take its value is the defect
 *       boot/mmu.S's PAT routine exists to catch, and the read-back here is
 *       tested by making the model drop a write.
 *
 *   (3) THE ROUTER IS ORDINARY CODE OVER A FRAME, so this file builds one by
 *       hand and calls the handler. That covers the one thing about this ABI
 *       that a register-passing router would get wrong -- argument 4 arrives
 *       in R10, because SYSCALL destroys RCX -- and it covers it by reading
 *       the slot rather than by asserting a comment.
 *
 * What is NOT here, and is in the boot gate instead: that the four registers
 * really took the values, that a real SYSCALL instruction lands in the
 * handler, and that FMASK cleared what it names -- which needs a real caller
 * to set the flags and a real instruction to clear them.
 */
#include <stdint.h>
#include <string.h>
#include <asm/msr-index.h>
#include <asm/processor-flags.h>
#include "fk_test.h"

/* fk_regs_t, field for field with src/cpu/fk_idt.f90. */
struct fk_regs {
	int64_t r15, r14, r13, r12, r11, r10, r9, r8;
	int64_t rdi, rsi, rbp, rbx, rdx, rcx, rax;
	int64_t int_no, err_code;
	int64_t rip, cs, rflags, rsp, ss;
};

/* ---- the model MSR file --------------------------------------------------- */
#define MSR_SLOTS 8
static struct { uint32_t nr; int64_t v; int present; } msrs[MSR_SLOTS];
static uint32_t drop_writes_to;   /* an MSR whose writes are silently lost */
static long wr_count;
static uint32_t wr_order[MSR_SLOTS * 4];
static int wr_order_n;

static int slot(uint32_t nr)
{
	int i;

	for (i = 0; i < MSR_SLOTS; i++)
		if (msrs[i].present && msrs[i].nr == nr)
			return i;
	for (i = 0; i < MSR_SLOTS; i++)
		if (!msrs[i].present) {
			msrs[i].present = 1;
			msrs[i].nr = nr;
			msrs[i].v = 0;
			return i;
		}
	return 0;
}

int64_t fk_rdmsr(int32_t nr) { return msrs[slot((uint32_t)nr)].v; }

void fk_wrmsr(int32_t nr, int64_t v)
{
	wr_count++;
	if (wr_order_n < (int)(sizeof wr_order / sizeof wr_order[0]))
		wr_order[wr_order_n++] = (uint32_t)nr;
	/* A REGISTER THAT DOES NOT TAKE ITS VALUE is the whole reason
	 * syscall_init reads all four back. Nothing else in this suite could
	 * tell a wrmsr that executed from one that did not. */
	if ((uint32_t)nr == drop_writes_to)
		return;
	msrs[slot((uint32_t)nr)].v = v;
}

/* The stub's address. A higher-half-looking constant, because syscall_init
 * refuses a non-canonical or low-half LSTAR and this file has no real one. */
static int64_t entry_addr = (int64_t)0xFFFFFFFF80101234ULL;
int64_t fk_syscall_entry_addr(void) { return entry_addr; }

/* fk_idt_m drags these in through its own dependencies. THE ROUTER UNDER TEST
 * REACHES NONE OF THEM -- fk_syscall_handler calls only the three scaffolds --
 * so they are stubs rather than a reference model. Their presence is what
 * makes the link possible; if any were ever reached, the assertions below
 * would be describing a different program than the kernel runs. */
int32_t fk_readl(int64_t a) { (void)a; return 0; }
void    fk_writel(int64_t a, int32_t v) { (void)a; (void)v; }
void    fk_outb(int16_t p, int8_t v) { (void)p; (void)v; }
int8_t  fk_inb(int16_t p) { (void)p; return 0; }
void    fk_io_wait(void) { }
void    fk_cpu_halt(void) { }
uint64_t fk_read_rflags(void) { return 0; }
void    fk_irq_enable(void) { }
void    fk_irq_disable(void) { }
void    idt_flush(const void *d) { (void)d; }
int64_t fk_isr_stub(int32_t v) { (void)v; return 0; }
int64_t fk_irq_stub(int32_t l) { (void)l; return 0; }
int64_t fk_spurious_stub_addr(void) { return 0; }
void    gdt_flush(const void *d, int16_t c, int16_t s) { (void)d; (void)c; (void)s; }
void    fk_ltr(int16_t s) { (void)s; }
int16_t fk_str(void) { return 0; }
void    tss_flush(int16_t s) { (void)s; }
int64_t fk_read_cr2(void) { return 0; }
void    console_write(const char *s, int32_t n) { (void)s; (void)n; }
void    console_print_hex(int64_t v, int32_t n) { (void)v; (void)n; }
void    console_set_color(int32_t f, int32_t b) { (void)f; (void)b; }
int32_t console_ready(void) { return 0; }
void    lapic_eoi(int64_t b) { (void)b; }
int32_t nvme_isr(void) { return 0; }
int32_t usbkbd_isr(void) { return 0; }
int64_t sched_tick(int64_t f) { return f; }

/* ---- the Fortran under test ----------------------------------------------- */
int32_t syscall_init(void);
int64_t syscall_star_value(void);
int64_t syscall_stack_top(void);
int64_t syscall_star(void);
int64_t syscall_lstar(void);
int64_t syscall_fmask(void);
int64_t syscall_efer(void);
void    fk_syscall_handler(struct fk_regs *regs);
int64_t syscall_count(void);
int64_t syscall_last_nr(void);
int64_t syscall_last_ret(void);
int64_t syscall_written(void);
int32_t syscall_exit_called(void);
int64_t syscall_exit_code(void);
int64_t syscall_entry_rflags(void);
int64_t syscall_masked_flags(void);
int64_t sys_read(int64_t fd, int64_t buf, int64_t count);
int64_t sys_write(int64_t fd, int64_t buf, int64_t count);
int64_t sys_exit(int64_t code);

extern int64_t fk_syscall_rsp0;
extern int64_t fk_syscall_user_rsp;
extern int64_t fk_syscall_entry_rflags;
extern int64_t fk_syscall_stack[4096];

#define SYS_OK       0
#define SYS_E_GDT   -1
#define SYS_E_ENTRY -2
#define SYS_E_STAR  -3
#define SYS_E_LSTAR -4
#define SYS_E_FMASK -5
#define SYS_E_SCE   -6
#define SYS_E_STACK -7

#define NR_READ  0
#define NR_WRITE 1
#define NR_EXIT  60
#define E_NOSYS  -38
#define E_BADF   -9
#define E_FAULT  -14

/* The GDT this kernel actually has. Written here so that the selector contract
 * below is a comparison of two independently-stated facts and not of a value
 * with itself. */
#define KERNEL_CS 0x08
#define KERNEL_DS 0x10

static void reset_msrs(void)
{
	memset(msrs, 0, sizeof msrs);
	drop_writes_to = 0;
	wr_count = 0;
	wr_order_n = 0;
}

/* ---- (1) the constants ----------------------------------------------------- */
static void test_constants(void)
{
	/* THE VENDOR'S OWN LIST, ORed here rather than a hex literal repeated.
	 * common.c:2291-2300 names exactly these fourteen. */
	int64_t want = X86_EFLAGS_CF | X86_EFLAGS_PF | X86_EFLAGS_AF |
		       X86_EFLAGS_ZF | X86_EFLAGS_SF | X86_EFLAGS_TF |
		       X86_EFLAGS_IF | X86_EFLAGS_DF | X86_EFLAGS_OF |
		       X86_EFLAGS_IOPL | X86_EFLAGS_NT | X86_EFLAGS_RF |
		       X86_EFLAGS_AC | X86_EFLAGS_ID;

	reset_msrs();
	FK_EQ("syscall_init succeeds against the model", SYS_OK,
	      syscall_init(), "%d");
	FK_EQ("FMASK is the kernel's own flag list", (long long)want,
	      (long long)syscall_fmask(), "%lld");
	/* IF IS IN IT, and it is the one that makes the software stack switch
	 * in boot/interrupts.S safe: SYSCALL does not switch the stack, so
	 * there is a window in which RSP is still the caller's. */
	FK_EQ("and IF is one of them", (long long)X86_EFLAGS_IF,
	      (long long)(syscall_fmask() & X86_EFLAGS_IF), "%lld");
	FK_EQ("as is DF", (long long)X86_EFLAGS_DF,
	      (long long)(syscall_fmask() & X86_EFLAGS_DF), "%lld");
	FK_EQ("as is TF", (long long)X86_EFLAGS_TF,
	      (long long)(syscall_fmask() & X86_EFLAGS_TF), "%lld");
	FK_EQ("as is NT", (long long)X86_EFLAGS_NT,
	      (long long)(syscall_fmask() & X86_EFLAGS_NT), "%lld");
	/* VM, VIF and VIP are NOT masked; they have no meaning in 64-bit mode
	 * and Linux leaves them out. A blanket 0x3FFFFF would pass every check
	 * above and this is what refuses it. */
	FK_EQ("and VM is not", 0LL,
	      (long long)(syscall_fmask() & X86_EFLAGS_VM), "%lld");
	FK_EQ("nor VIF", 0LL,
	      (long long)(syscall_fmask() & X86_EFLAGS_VIF), "%lld");
	FK_EQ("nor bit 1, which is architecturally always set", 0LL,
	      (long long)(syscall_fmask() & 2), "%lld");
}

/* ---- (2) the init sequence ------------------------------------------------- */
static void test_star(void)
{
	int64_t star;

	reset_msrs();
	FK_EQ("init succeeds", SYS_OK, syscall_init(), "%d");
	star = syscall_star();

	/* THE SYSCALL HALF. common.c:2306 puts __KERNEL_CS in bits 47:32; the
	 * CPU then loads CS from it and SS from it PLUS EIGHT, which is why the
	 * two descriptors have to be adjacent. */
	FK_EQ("STAR[47:32] is the kernel code selector", (long long)KERNEL_CS,
	      (long long)((star >> 32) & 0xFFFF), "%lld");
	FK_EQ("so the SS the CPU derives is the kernel data selector",
	      (long long)KERNEL_DS,
	      (long long)(((star >> 32) & 0xFFFC) + 8), "%lld");
	FK_EQ("and the CS it derives has RPL 0", 0LL,
	      (long long)((star >> 32) & 3), "%lld");

	/* THE LEGACY HALF IS ZERO. STAR[31:0] is the 32-bit SYSCALL target and
	 * long mode never reads it; common.c:2306 passes 0 for exactly this. */
	FK_EQ("STAR[31:0] is zero -- the 32-bit target is never used", 0LL,
	      (long long)(star & 0xFFFFFFFF), "%lld");

	/* THE SYSRET HALF IS ZERO ON PURPOSE. SYSRET derives its CS from
	 * STAR[63:48] + 16 and its SS from + 8, both at RPL 3, so any non-zero
	 * value here names Ring 3 descriptors this GDT does not have -- a
	 * register that reads as configured and faults on first use. Roadmap
	 * 7.1 adds them; until then zero is the honest value and this row is
	 * what stops it being filled in speculatively. */
	FK_EQ("STAR[63:48] is zero -- there are no Ring 3 descriptors yet", 0LL,
	      (long long)((star >> 48) & 0xFFFF), "%lld");

	FK_EQ("syscall_star_value agrees with what was programmed",
	      (long long)syscall_star_value(), (long long)star, "%lld");
	FK_EQ("LSTAR is the entry stub", (long long)entry_addr,
	      (long long)syscall_lstar(), "%lld");
	FK_EQ("EFER.SCE is set", (long long)EFER_SCE,
	      (long long)(syscall_efer() & EFER_SCE), "%lld");
	FK_EQ("exactly four registers were written", 4L, wr_count, "%ld");
	/* EFER LAST. With SCE set before LSTAR holds an address, a SYSCALL
	 * arriving in the gap jumps to whatever the register was left at. */
	FK_EQ("and EFER was the last of them", (long long)MSR_EFER,
	      (long long)wr_order[wr_order_n - 1], "%lld");
	FK_EQ("MSR_CSTAR is left alone -- there is no compat entry point", 0LL,
	      (long long)syscall_efer() * 0 + fk_rdmsr(MSR_CSTAR), "%lld");
}

/* THE READ-BACK, and this is what the model exists for. boot/mmu.S's PAT
 * routine states the rule: a wrmsr that never executed is otherwise
 * indistinguishable from one that did. */
static void test_readback(void)
{
	reset_msrs();
	drop_writes_to = MSR_STAR;
	FK_EQ("a STAR that does not take is caught", SYS_E_STAR,
	      syscall_init(), "%d");

	reset_msrs();
	drop_writes_to = MSR_LSTAR;
	FK_EQ("an LSTAR that does not take is caught", SYS_E_LSTAR,
	      syscall_init(), "%d");

	reset_msrs();
	drop_writes_to = MSR_SYSCALL_MASK;
	FK_EQ("an FMASK that does not take is caught", SYS_E_FMASK,
	      syscall_init(), "%d");

	reset_msrs();
	drop_writes_to = MSR_EFER;
	FK_EQ("an EFER whose SCE bit does not take is caught", SYS_E_SCE,
	      syscall_init(), "%d");

	reset_msrs();
	FK_EQ("and with none of them dropped it succeeds", SYS_OK,
	      syscall_init(), "%d");
}

static void test_entry_and_stack(void)
{
	int64_t save = entry_addr;

	reset_msrs();
	entry_addr = 0;
	FK_EQ("a zero entry point is refused", SYS_E_ENTRY, syscall_init(),
	      "%d");
	/* LSTAR IS LOADED INTO RIP. A low-half address is not where this kernel
	 * lives, and a non-canonical one faults at the first syscall rather
	 * than at the write -- arbitrarily far from the cause. */
	entry_addr = 0x101234;
	FK_EQ("a low-half entry point is refused", SYS_E_ENTRY, syscall_init(),
	      "%d");
	entry_addr = save;
	FK_EQ("and the higher-half one is accepted", SYS_OK, syscall_init(),
	      "%d");

	/* The stack the stub switches to. 22 quadwords is 176 bytes, a multiple
	 * of 16, so RSP is 16-aligned at the call if and only if it is aligned
	 * here -- which is what the SysV ABI requires AT a call. */
	FK_EQ("the syscall stack top is 16-byte aligned", 0LL,
	      (long long)(syscall_stack_top() & 15), "%lld");
	FK_EQ("it is one past the end of the stack, rounded down", 1,
	      syscall_stack_top() <= (int64_t)(uintptr_t)&fk_syscall_stack[4096]
	      && syscall_stack_top() >
		 (int64_t)(uintptr_t)&fk_syscall_stack[4095], "%d");
	FK_EQ("and init published it for the stub to load",
	      (long long)syscall_stack_top(), (long long)fk_syscall_rsp0,
	      "%lld");
}

/* ---- (3) the router --------------------------------------------------------- */
static struct fk_regs mk(int64_t nr, int64_t a1, int64_t a2, int64_t a3)
{
	struct fk_regs r;

	memset(&r, 0, sizeof r);
	r.rax = nr;
	r.rdi = a1;
	r.rsi = a2;
	r.rdx = a3;
	r.int_no = -1;
	return r;
}

static void test_router(void)
{
	struct fk_regs r;
	int64_t before;
	char buf[8];
	int64_t p = (int64_t)(uintptr_t)buf;

	reset_msrs();
	syscall_init();

	before = syscall_count();
	r = mk(NR_WRITE, 1, p, 5);
	fk_syscall_handler(&r);
	FK_EQ("the router counted the call", before + 1,
	      (long long)syscall_count(), "%lld");
	FK_EQ("it recorded the number", (long long)NR_WRITE,
	      (long long)syscall_last_nr(), "%lld");
	/* THE RESULT GOES BACK IN THE FRAME'S RAX, because POP_GPRS is what
	 * puts it in the register. A handler that returned it as a function
	 * result would compile, run, and deliver nothing to the caller. */
	FK_EQ("and wrote the result into the frame's rax", 5LL,
	      (long long)r.rax, "%lld");
	FK_EQ("which is also what it recorded", 5LL,
	      (long long)syscall_last_ret(), "%lld");

	r = mk(NR_READ, 0, p, 8);
	fk_syscall_handler(&r);
	FK_EQ("read from a descriptor with nothing behind it is EOF", 0LL,
	      (long long)r.rax, "%lld");

	r = mk(NR_EXIT, 42, 0, 0);
	before = syscall_exit_called();
	fk_syscall_handler(&r);
	FK_EQ("exit was called", before + 1, (long long)syscall_exit_called(),
	      "%d");
	FK_EQ("with its code", 42LL, (long long)syscall_exit_code(), "%lld");
	/* IT RETURNS, and at 6.3 it must: the caller is the kernel's own boot
	 * thread and there is no task to destroy. 7.1 is where it stops. */
	FK_EQ("and it returned rather than ending the thread", 0LL,
	      (long long)r.rax, "%lld");

	/* -ENOSYS AND NOT A PANIC. An unknown number is a caller's mistake, and
	 * halting on one would make every future libc probe fatal. */
	r = mk(9999, 0, 0, 0);
	fk_syscall_handler(&r);
	FK_EQ("an unknown number is -ENOSYS", (long long)E_NOSYS,
	      (long long)r.rax, "%lld");
	r = mk(-1, 0, 0, 0);
	fk_syscall_handler(&r);
	FK_EQ("and so is a negative one", (long long)E_NOSYS,
	      (long long)r.rax, "%lld");

	/* THE R10 SLOT, and this row is the reason the router reads a FRAME.
	 * The Linux syscall ABI puts argument 4 in R10 rather than RCX because
	 * SYSCALL destroys RCX with the return address; a register-passing
	 * router would receive RCX and have to know to look elsewhere. Reading
	 * the frame makes R10 simply the field called r10 -- and it makes RCX
	 * and R11 visibly the clobbered values they are. */
	r = mk(NR_WRITE, 1, p, 3);
	r.r10 = 0x1010101010101010LL;
	r.rcx = 0xDEADBEEFDEADBEEFLL;   /* SYSCALL put the return RIP here */
	r.r11 = 0x0000000000000202LL;   /* and the caller's RFLAGS here */
	fk_syscall_handler(&r);
	FK_EQ("a call with r10, rcx and r11 set still writes 3 bytes", 3LL,
	      (long long)r.rax, "%lld");
	FK_EQ("r10 is untouched by the router", 0x1010101010101010LL,
	      (long long)r.r10, "%lld");
	FK_EQ("and so is the return RIP SYSCALL left in rcx",
	      (long long)0xDEADBEEFDEADBEEFLL, (long long)r.rcx, "%lld");
	FK_EQ("and the caller's RFLAGS in r11", 0x202LL, (long long)r.r11,
	      "%lld");
	FK_EQ("the frame's int_no marks it as not a vector", -1LL,
	      (long long)r.int_no, "%lld");
}

static void test_scaffolds(void)
{
	char buf[8];
	int64_t p = (int64_t)(uintptr_t)buf;
	int64_t before;

	FK_EQ("write to a negative fd is -EBADF", (long long)E_BADF,
	      (long long)sys_write(-1, p, 1), "%lld");
	FK_EQ("write through a null pointer is -EFAULT", (long long)E_FAULT,
	      (long long)sys_write(1, 0, 1), "%lld");
	FK_EQ("a negative count is -EFAULT", (long long)E_FAULT,
	      (long long)sys_write(1, p, -1), "%lld");
	before = syscall_written();
	FK_EQ("a good write returns its count", 7LL,
	      (long long)sys_write(1, p, 7), "%lld");
	FK_EQ("and the byte total moved by that much", before + 7,
	      (long long)syscall_written(), "%lld");
	/* A REFUSED WRITE MUST NOT COUNT. Otherwise the total says bytes were
	 * accepted that were not. */
	before = syscall_written();
	sys_write(-1, p, 100);
	sys_write(1, 0, 100);
	FK_EQ("a refused write moves nothing", before,
	      (long long)syscall_written(), "%lld");

	FK_EQ("read from a negative fd is -EBADF", (long long)E_BADF,
	      (long long)sys_read(-1, p, 1), "%lld");
	FK_EQ("read through a null pointer is -EFAULT", (long long)E_FAULT,
	      (long long)sys_read(0, 0, 1), "%lld");
	FK_EQ("a zero-length read is zero", 0LL,
	      (long long)sys_read(0, p, 0), "%lld");

	before = syscall_exit_called();
	FK_EQ("exit returns zero", 0LL, (long long)sys_exit(7), "%lld");
	FK_EQ("and was counted", before + 1, (long long)syscall_exit_called(),
	      "%d");
	FK_EQ("and kept the code", 7LL, (long long)syscall_exit_code(),
	      "%lld");
}

/* The stub writes this before its CLD and nothing on the host does, so the
 * only thing assertable here is the ARITHMETIC over it. The boot gate is where
 * a real instruction fills it in. */
static void test_masked_flags(void)
{
	fk_syscall_entry_rflags = 0x202;   /* IF set, bit 1 set */
	FK_EQ("a surviving IF is reported", (long long)X86_EFLAGS_IF,
	      (long long)syscall_masked_flags(), "%lld");
	fk_syscall_entry_rflags = 0x002;   /* only the architectural bit 1 */
	FK_EQ("and bit 1 alone is not, being outside FMASK", 0LL,
	      (long long)syscall_masked_flags(), "%lld");
	fk_syscall_entry_rflags = 0x402;   /* DF */
	FK_EQ("a surviving DF is reported", (long long)X86_EFLAGS_DF,
	      (long long)syscall_masked_flags(), "%lld");
	fk_syscall_entry_rflags = 0;
	FK_EQ("and nothing surviving is zero", 0LL,
	      (long long)syscall_masked_flags(), "%lld");
}

int main(void)
{
	test_constants();
	test_star();
	test_readback();
	test_entry_and_stack();
	test_router();
	test_scaffolds();
	test_masked_flags();
	return fk_report("syscall");
}
