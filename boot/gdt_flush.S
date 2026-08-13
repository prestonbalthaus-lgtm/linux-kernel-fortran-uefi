/* SPDX-License-Identifier: GPL-2.0 */
/*
 * boot/gdt_flush.S -- load the descriptor tables built in src/cpu/.
 *
 *     void gdt_flush(const void *desc, uint16_t code_sel, uint16_t data_sel);
 *     desc RDI, code_sel SI, data_sel DX
 *     void tss_flush(uint16_t sel);                          sel DI
 */

	.section .text, "ax", @progbits
	.code64
	.globl gdt_flush
	.type gdt_flush, @function
gdt_flush:
	lgdt	(%rdi)

	/*
	 * A far JMP with an immediate pointer does not exist in 64-bit mode, so
	 * CS is reloaded by faking a far return: selector first, then the target
	 * RIP.  LRETQ, not LRET -- REX.W is what makes it pop 64-bit slots.
	 * MOVZWL because the SysV ABI leaves bits 63:16 of a 16-bit argument
	 * register undefined.
	 */
	movzwl	%si, %eax
	pushq	%rax
	leaq	1f(%rip), %rax
	pushq	%rax
	lretq
1:
	movw	%dx, %ax
	movw	%ax, %ds
	movw	%ax, %es
	movw	%ax, %fs
	movw	%ax, %gs
	movw	%ax, %ss
	ret
	.size gdt_flush, . - gdt_flush

/*
 * LTR.  Requires the GDT already loaded and the 16-byte TSS descriptor already
 * written -- and it MARKS that descriptor BUSY, so running it twice on one TSS
 * raises #GP rather than reloading anything.
 */
	.section .text, "ax", @progbits
	.code64
	.globl tss_flush
	.type tss_flush, @function
tss_flush:
	ltr	%di
	ret
	.size tss_flush, . - tss_flush

	.section .note.GNU-stack, "", @progbits
