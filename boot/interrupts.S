/* SPDX-License-Identifier: GPL-2.0 */
/*
 * boot/interrupts.S -- trampolines for the 32 CPU exception vectors (roadmap
 * 3.2) and the 16 legacy IRQ lines (roadmap 3.2b), the LIDT stub, and the
 * instructions that control IF.
 *
 * Each stub normalises the machine's frame into the layout src/cpu/fk_idt.f90
 * declares as fk_regs_t, lowest address first:
 *
 *     r15 r14 r13 r12 r11 r10 r9 r8 rdi rsi rbp rbx rdx rcx rax
 *     int_no err_code rip cs rflags rsp ss
 *
 * The last five quadwords are pushed by the CPU (in 64-bit mode ss:rsp are
 * pushed for every exception, not only across a privilege change).  err_code is
 * pushed by the CPU on vectors 8, 10-14, 17, 21, 29 and 30 and by the stub as a
 * zero on every other one, so the Fortran catcher never has to ask which kind
 * of exception it caught.
 *
 * TWO TAILS, AND THEY ARE NOT INTERCHANGEABLE.  isr_common calls a handler that
 * does not return and parks the CPU behind it; irq_common loads the RSP its
 * handler RETURNED and executes IRETQ off that.  Resuming from a #GP is not something this kernel knows
 * how to do, and an IRQ that does not resume is not an IRQ, so which of the two
 * a vector gets is decided by the IDT and nowhere else.
 *
 * WHAT AN IRQ STUB PUSHES is the 8259 LINE NUMBER, 0-15, and not the vector.
 * The vector is FK_PIC1_VECTOR + line, and src/drivers/pic/fk_pic.f90 is the
 * only place in this tree that decides what FK_PIC1_VECTOR is; an assembler
 * constant here would be a second copy of that decision with nothing to keep
 * the two equal.  fk_idt_m installs fk_irq_stub(line) at the vector fk_pic_m
 * names.
 */

	.section .text, "ax", @progbits
	.code64

/*
 * The 15 general-purpose registers, in the order fk_regs_t declares them.
 * Macros rather than two transcriptions: the push order and the pop order are
 * one decision written twice, and where they can drift an IRQ returns with rbx
 * and rbp exchanged -- which corrupts the interrupted code and not the handler,
 * so it surfaces arbitrarily far away from the defect.
 */
	.macro PUSH_GPRS
	pushq	%rax
	pushq	%rcx
	pushq	%rdx
	pushq	%rbx
	pushq	%rbp
	pushq	%rsi
	pushq	%rdi
	pushq	%r8
	pushq	%r9
	pushq	%r10
	pushq	%r11
	pushq	%r12
	pushq	%r13
	pushq	%r14
	pushq	%r15

	/* An interrupt gate does not clear DF, and SysV requires DF=0 on entry. */
	cld
	.endm

	.macro POP_GPRS
	popq	%r15
	popq	%r14
	popq	%r13
	popq	%r12
	popq	%r11
	popq	%r10
	popq	%r9
	popq	%r8
	popq	%rdi
	popq	%rsi
	popq	%rbp
	popq	%rbx
	popq	%rdx
	popq	%rcx
	popq	%rax
	.endm

	.macro ISR_NOERR vec
	.globl isr\vec
	.type isr\vec, @function
isr\vec:
	pushq	$0
	pushq	$\vec
	jmp	isr_common
	.size isr\vec, . - isr\vec
	.endm

	.macro ISR_ERR vec
	.globl isr\vec
	.type isr\vec, @function
isr\vec:
	pushq	$\vec
	jmp	isr_common
	.size isr\vec, . - isr\vec
	.endm

	ISR_NOERR 0
	ISR_NOERR 1
	ISR_NOERR 2
	ISR_NOERR 3
	ISR_NOERR 4
	ISR_NOERR 5
	ISR_NOERR 6
	ISR_NOERR 7
	ISR_ERR   8
	ISR_NOERR 9
	ISR_ERR   10
	ISR_ERR   11
	ISR_ERR   12
	ISR_ERR   13
	ISR_ERR   14
	ISR_NOERR 15
	ISR_NOERR 16
	ISR_ERR   17
	ISR_NOERR 18
	ISR_NOERR 19
	ISR_NOERR 20
	ISR_ERR   21
	ISR_NOERR 22
	ISR_NOERR 23
	ISR_NOERR 24
	ISR_NOERR 25
	ISR_NOERR 26
	ISR_NOERR 27
	ISR_NOERR 28
	ISR_ERR   29
	ISR_ERR   30
	ISR_NOERR 31

	.type isr_common, @function
isr_common:
	PUSH_GPRS

	/*
	 * The CPU aligns rsp to 16 before pushing its half of the frame, and the
	 * whole frame is 22 quadwords -- 176 bytes, a multiple of 16 -- so rsp is
	 * already 16-byte aligned here, which is what the ABI demands AT a call.
	 */
	movq	%rsp, %rdi
	call	isr_handler

	/* isr_handler is a panic handler and does not return.  If it ever does,
	   park the CPU rather than popping a frame nobody restored. */
	jmp	fk_cpu_halt
	.size isr_common, . - isr_common

/*
 * The legacy IRQ lines (roadmap 3.2b).  No line delivers an error code -- the
 * CPU pushes one only for the exceptions listed above -- so every stub pushes
 * the dummy, and irq_common builds the identical 22-quadword frame isr_common
 * does.  One layout, so one Fortran type describes both.
 */
	.macro IRQ line
	.globl irq\line
	.type irq\line, @function
irq\line:
	pushq	$0
	pushq	$\line
	jmp	irq_common
	.size irq\line, . - irq\line
	.endm

	IRQ 0
	IRQ 1
	IRQ 2
	IRQ 3
	IRQ 4
	IRQ 5
	IRQ 6
	IRQ 7
	IRQ 8
	IRQ 9
	IRQ 10
	IRQ 11
	IRQ 12
	IRQ 13
	IRQ 14
	IRQ 15

/*
 * ONE MORE, AND IT IS NOT A LINE (roadmap 5.1).  A message-signalled interrupt
 * has no 8259 line and no I/O APIC pin: the device WRITES to the APIC's
 * message address and the vector is whatever the MSI-X table entry says.  It
 * still needs a stub, because a vector the IDT does not describe is a #GP the
 * instant the first message lands.
 *
 * It pushes 16 -- one past the last real line -- so irq_handler can tell the
 * two apart without a second entry point or a second frame layout.  The 8259
 * spurious-line logic is indexed by line number and must not see this one.
 */
	IRQ 16

	.type irq_common, @function
irq_common:
	PUSH_GPRS

	movq	%rsp, %rdi
	call	irq_handler

	/*
	 * THE CONTEXT SWITCH, and it is one instruction (roadmap 4.0).
	 *
	 * irq_handler returns the address of the frame to resume on.  With no
	 * scheduler that is the frame it was handed, so this is a no-op and the
	 * interrupted thread continues.  With one, it is a frame the scheduler
	 * saved on ANOTHER task's stack the last time that task was
	 * interrupted -- identical in layout, because every task's first frame
	 * is built to look exactly like one this stub pushed.  POP_GPRS then
	 * restores that task's registers and IRETQ returns to its RIP with its
	 * RSP and RFLAGS.
	 *
	 * Nothing is saved here: the outgoing task's registers are ALREADY on
	 * its own stack, pushed by PUSH_GPRS above, and its RSP is the value
	 * that was in %rdi.  The scheduler wrote that down before answering.
	 */
	movq	%rax, %rsp

	POP_GPRS

	/*
	 * The line number and the dummy error code.  The CPU did not push them and
	 * IRETQ will not skip them: without this, IRETQ reads the line number as the
	 * return RIP and jumps to address 0-15.
	 */
	addq	$16, %rsp
	iretq
	.size irq_common, . - irq_common

/*
 * THE SYSCALL TRAP (roadmap 6.3).  Not a vector: the CPU reaches this because
 * MSR_LSTAR holds its address, and no IDT entry describes it.
 *
 * WHAT SYSCALL HAS ALREADY DONE, and every line below depends on it
 * (arch/x86/entry/entry_64.S:62-66):
 *
 *      rcx    <- the RIP of the instruction after SYSCALL
 *      r11    <- RFLAGS, snapshotted AFTER RF was cleared
 *      rflags <- rflags & ~MSR_SYSCALL_MASK
 *      cs     <- STAR[47:32], RPL forced to 0
 *      ss     <- STAR[47:32] + 8, RPL forced to 0
 *      rip    <- MSR_LSTAR
 *
 * and, the entry that shapes this whole stub:
 *
 *      rsp    <- UNCHANGED.  "SYSCALL does not save anything on the stack and
 *                does not change rsp" (entry_64.S:65-66).
 *
 * SO THE STACK SWITCH IS SOFTWARE'S, and it is why IF is in FMASK.  Between
 * arriving here and having a kernel stack there is a window in which RSP still
 * points wherever the caller left it; an interrupt taken in that window would
 * push its frame there.  FMASK clears IF as part of the instruction, so the
 * window cannot be interrupted -- that is the mechanism, not a comment about
 * hygiene, and dropping IF from FMASK is a mutation the boot gate refuses.
 *
 * NO SWAPGS, and that is a property of this kernel rather than a shortcut.
 * Linux swaps GS because its stack pointer lives in per-CPU memory addressed
 * through it; nothing in this tree uses a GS base for anything (boot.S:367 and
 * gdt_flush.S:34 load %gs with a data selector and never touch its base), so
 * the kernel stack is loaded from an ordinary global.  A swapgs here would
 * corrupt the base rather than switch it, and it is the FIRST thing 7.1 has to
 * revisit if per-CPU state ever arrives.
 *
 * ONE FRAME SHAPE FOR ALL THREE ENTRY PATHS.  The pushes below rebuild exactly
 * the 22-quadword fk_regs_t that isr_common and irq_common build, so one
 * Fortran type describes an exception, an interrupt and a system call.  int_no
 * is -1: an unmistakable "not a vector", needing no constant shared between
 * this file and Fortran -- which is the mistake WHAT AN IRQ STUB PUSHES above
 * exists to avoid.
 */
	.globl fk_syscall_entry
	.type fk_syscall_entry, @function
fk_syscall_entry:
	/* The caller's RSP, stashed before it is overwritten.  A single global
	   rather than a per-CPU slot: this kernel takes syscalls on one CPU and
	   a handler that itself executed SYSCALL would clobber it, which is why
	   nothing below is allowed to. */
	movq	%rsp, fk_syscall_user_rsp(%rip)
	movq	fk_syscall_rsp0(%rip), %rsp

	/*
	 * THE RFLAGS THE KERNEL WAS ENTERED WITH, captured here and nowhere
	 * else.  This is the only instant at which it can be read: it is after
	 * the stack switch, so PUSHFQ has somewhere safe to push, and it is
	 * before PUSH_GPRS, whose CLD would clear DF and hide half of what
	 * FMASK is supposed to have done.
	 *
	 * `popq m64` keeps this to two instructions and clobbers NO register,
	 * which matters more than it looks: every general-purpose register
	 * still holds a syscall argument, and RAX still holds the number.
	 */
	pushfq
	popq	fk_syscall_entry_rflags(%rip)

	/*
	 * fk_regs_t, highest field first: ss, rsp, rflags, cs, rip, err_code,
	 * int_no.
	 *
	 * NOT ONE GENERAL-PURPOSE REGISTER IS TOUCHED, and the first draft of
	 * this stub got it wrong in the way that matters most: it read %ss and
	 * %cs through %rax, which is where SYSCALL's caller puts the SYSTEM
	 * CALL NUMBER.  Every call would have dispatched on a segment selector.
	 * A segment register can be stored straight to memory, so the slot is
	 * reserved, zeroed and then written 16 bits wide.
	 *
	 * ss and cs are whatever SYSCALL just loaded -- the KERNEL pair, from
	 * STAR[47:32] and STAR[47:32]+8 -- and that is what returns a ring-0
	 * caller to ring 0.  Roadmap 7.1 replaces these two with the user pair
	 * and nothing else in this stub changes.
	 */
	pushq	$0
	movw	%ss, (%rsp)
	pushq	fk_syscall_user_rsp(%rip)
	pushq	%r11			/* the caller's RFLAGS, per SYSCALL */
	pushq	$0
	movw	%cs, (%rsp)
	pushq	%rcx			/* the caller's RIP, per SYSCALL */
	pushq	$0			/* err_code: no such thing here */
	pushq	$-1			/* int_no: not a vector */

	PUSH_GPRS

	/* 22 quadwords is 176 bytes, a multiple of 16, and fk_syscall_rsp0 is
	   16-byte aligned, so RSP is aligned here -- which is what the ABI
	   requires AT a call. */
	movq	%rsp, %rdi
	call	fk_syscall_handler

	POP_GPRS
	addq	$16, %rsp		/* int_no and err_code */

	/*
	 * IRETQ AND NOT SYSRETQ, and this is roadmap 6.3's one deliberate
	 * deviation from what a finished kernel does.
	 *
	 * SYSRET forces CPL 3: its CS comes from STAR[63:48]+16 and its SS from
	 * STAR[63:48]+8, both with RPL hardwired to 3 (segment.h:177-186).
	 * There is no encoding of it that returns to CPL 0, so it cannot return
	 * the only caller 6.3 has -- kernel code testing that the trap routes.
	 * Linux has the same problem from the other side and answers it the
	 * same way: every kernel-to-kernel return in entry_64.S is IRETQ.
	 *
	 * In 64-bit mode IRETQ ALWAYS pops SS:RSP, privilege change or not, so
	 * this one instruction serves ring 0 now and ring 3 at 7.1 -- the frame
	 * it reads is the frame that was pushed, and only the two selectors in
	 * it need to change.
	 */
	iretq
	.size fk_syscall_entry, . - fk_syscall_entry

/*
 * uint64_t fk_syscall_entry_addr(void);   result RAX
 *
 * MSR_LSTAR is programmed from Fortran, which cannot take the address of a
 * symbol it does not define -- the same reason fk_spurious_stub_addr exists.
 */
	.globl fk_syscall_entry_addr
	.type fk_syscall_entry_addr, @function
fk_syscall_entry_addr:
	leaq	fk_syscall_entry(%rip), %rax
	ret
	.size fk_syscall_entry_addr, . - fk_syscall_entry_addr

/*
 * void fk_do_syscall(void);
 *
 * Executes SYSCALL from wherever it is called, which at roadmap 6.3 is Ring 0.
 * It exists because Fortran has no spelling for the instruction, and it is a
 * TEST AFFORDANCE that is honest about being one: 7.2 issues syscalls from a
 * user-space binary and this routine is then dead.
 *
 * RCX AND R11 ARE DESTROYED BY THE INSTRUCTION ITSELF, which is exactly why
 * the kernel ABI puts syscall argument 3 in R10 and not in RCX.  They are
 * therefore listed as clobbered here rather than saved: the SysV ABI already
 * makes both caller-saved, so a Fortran caller has nothing to lose.
 */
	.globl fk_do_syscall
	.type fk_do_syscall, @function
fk_do_syscall:
	syscall
	ret
	.size fk_do_syscall, . - fk_do_syscall

/*
 * uint64_t fk_syscall1(int64_t nr, int64_t a1, int64_t a2, int64_t a3);
 *          nr RDI, a1 RSI, a2 RDX, a3 RCX -> result RAX
 *
 * The SysV C ABI and the Linux SYSCALL ABI are NOT the same ABI, and this is
 * the shuffle between them.  Both put arg1 in RDI and arg2 in RSI, but the C
 * ABI's third argument is RDX and its fourth is RCX, while the syscall ABI
 * takes the number in RAX, arg3 in RDX and arg4 in R10 -- R10 rather than RCX
 * precisely because SYSCALL overwrites RCX with the return address.
 *
 * So: nr moves to RAX, a1 to RDI, a2 to RSI, a3 to RDX.  Done in an order that
 * never overwrites a register before it has been read.
 */
	.globl fk_syscall1
	.type fk_syscall1, @function
fk_syscall1:
	movq	%rdi, %rax		/* nr */
	movq	%rsi, %rdi		/* a1 */
	movq	%rdx, %rsi		/* a2 */
	movq	%rcx, %rdx		/* a3 */
	syscall
	ret
	.size fk_syscall1, . - fk_syscall1

/*
 * The LAPIC's spurious vector, SVR bits 7:0, which is 0xFF here.
 *
 * IT GETS NO EOI, and that is the whole reason it is not an irq_stub entry.
 * The local APIC does not set an in-service bit for a spurious interrupt, so
 * an EOI here would retire whatever IS in service and that interrupt would
 * never complete -- the same defect the 8259 spurious check in irq_handler
 * exists to prevent, arriving by a different road.
 *
 * Counting and returning is the entire handler.  incq writes memory and
 * clobbers RFLAGS, which IRETQ restores from the stack, so nothing needs
 * saving and there is no C frame to build.
 */
	.globl fk_spurious_stub
	.type fk_spurious_stub, @function
fk_spurious_stub:
	incq	fk_lapic_spurious(%rip)
	iretq
	.size fk_spurious_stub, . - fk_spurious_stub

/*
 * uint64_t fk_spurious_stub_addr(void);   result RAX
 *
 * Same reason as the two accessors below: Fortran cannot reference a symbol it
 * does not itself define.
 */
	.globl fk_spurious_stub_addr
	.type fk_spurious_stub_addr, @function
fk_spurious_stub_addr:
	leaq	fk_spurious_stub(%rip), %rax
	ret
	.size fk_spurious_stub_addr, . - fk_spurious_stub_addr

/*
 * uint64_t fk_isr_stub(int32_t vec);   vec EDI, result RAX
 * uint64_t fk_irq_stub(int32_t line);  line EDI, result RAX
 *
 * Fortran cannot reference a symbol it does not itself define, so the tables of
 * stub entry points are read back through these accessors.  Callers stay inside
 * 0..31 and 0..15; there is nothing to bounds-check against but the tables.
 */
	.globl fk_isr_stub
	.type fk_isr_stub, @function
fk_isr_stub:
	leaq	isr_stub_table(%rip), %rax
	movslq	%edi, %rdi		/* the ABI leaves bits 63:32 undefined */
	movq	(%rax, %rdi, 8), %rax
	ret
	.size fk_isr_stub, . - fk_isr_stub

	.globl fk_irq_stub
	.type fk_irq_stub, @function
fk_irq_stub:
	leaq	irq_stub_table(%rip), %rax
	movslq	%edi, %rdi
	movq	(%rax, %rdi, 8), %rax
	ret
	.size fk_irq_stub, . - fk_irq_stub

/*
 * void idt_flush(const void *desc);   desc RDI
 *
 * LIDT's operand is the same packed limit:base pair LGDT takes.
 */
	.globl idt_flush
	.type idt_flush, @function
idt_flush:
	lidt	(%rdi)
	ret
	.size idt_flush, . - idt_flush

/*
 * void     fk_irq_enable(void);    STI
 * void     fk_irq_disable(void);   CLI
 * uint64_t fk_read_rflags(void);
 * void     fk_cpu_idle(void);      never returns
 *
 * IF has no Fortran spelling, and fk_read_rflags is here so that "interrupts
 * are on" can be asserted from the register rather than from the fact that STI
 * was called -- the same rule the rest of this tree follows for the PIC and the
 * task register.
 *
 * fk_cpu_idle is fk_cpu_halt's opposite number: it parks the CPU with IF SET,
 * so the machine keeps taking interrupts and returning from them for as long as
 * it is left running.  STI does not take effect until after the NEXT
 * instruction, which is what makes STI;HLT race-free: an interrupt that arrives
 * in between cannot slip past the HLT and leave the CPU asleep forever.
 */
	.globl fk_irq_enable
	.type fk_irq_enable, @function
fk_irq_enable:
	sti
	ret
	.size fk_irq_enable, . - fk_irq_enable

	.globl fk_irq_disable
	.type fk_irq_disable, @function
fk_irq_disable:
	cli
	ret
	.size fk_irq_disable, . - fk_irq_disable

	.globl fk_read_rflags
	.type fk_read_rflags, @function
fk_read_rflags:
	pushfq
	popq	%rax
	ret
	.size fk_read_rflags, . - fk_read_rflags

	.globl fk_cpu_idle
	.type fk_cpu_idle, @function
fk_cpu_idle:
	sti
1:	hlt
	jmp	1b
	.size fk_cpu_idle, . - fk_cpu_idle

	.section .rodata
	.align 8
isr_stub_table:
	.quad	isr0,  isr1,  isr2,  isr3,  isr4,  isr5,  isr6,  isr7
	.quad	isr8,  isr9,  isr10, isr11, isr12, isr13, isr14, isr15
	.quad	isr16, isr17, isr18, isr19, isr20, isr21, isr22, isr23
	.quad	isr24, isr25, isr26, isr27, isr28, isr29, isr30, isr31

irq_stub_table:
	.quad	irq0,  irq1,  irq2,  irq3,  irq4,  irq5,  irq6,  irq7
	.quad	irq8,  irq9,  irq10, irq11, irq12, irq13, irq14, irq15
	.quad	irq16

	.section .note.GNU-stack, "", @progbits
