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

	.section .note.GNU-stack, "", @progbits
