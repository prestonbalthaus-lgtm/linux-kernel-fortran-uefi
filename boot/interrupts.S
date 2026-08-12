/* SPDX-License-Identifier: GPL-2.0 */
/*
 * boot/interrupts.S -- trampolines for the 32 CPU exception vectors, and the
 * LIDT stub (roadmap 3.2).
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
 */

	.section .text, "ax", @progbits
	.code64

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
 * uint64_t fk_isr_stub(int32_t vec);   vec EDI, result RAX
 *
 * Fortran cannot reference a symbol it does not itself define, so the table of
 * stub entry points is read back through this accessor.  Callers stay inside
 * 0..31; there is nothing to bounds-check against but the table itself.
 */
	.globl fk_isr_stub
	.type fk_isr_stub, @function
fk_isr_stub:
	leaq	isr_stub_table(%rip), %rax
	movslq	%edi, %rdi		/* the ABI leaves bits 63:32 undefined */
	movq	(%rax, %rdi, 8), %rax
	ret
	.size fk_isr_stub, . - fk_isr_stub

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

	.section .rodata
	.align 8
isr_stub_table:
	.quad	isr0,  isr1,  isr2,  isr3,  isr4,  isr5,  isr6,  isr7
	.quad	isr8,  isr9,  isr10, isr11, isr12, isr13, isr14, isr15
	.quad	isr16, isr17, isr18, isr19, isr20, isr21, isr22, isr23
	.quad	isr24, isr25, isr26, isr27, isr28, isr29, isr30, isr31

	.section .note.GNU-stack, "", @progbits
