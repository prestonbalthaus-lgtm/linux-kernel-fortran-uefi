/* SPDX-License-Identifier: GPL-2.0 */
/*
 * boot/gdt_flush.S -- load the GDT built by src/cpu/fk_gdt.f90.
 *
 *     void gdt_flush(const void *desc, uint16_t code_sel, uint16_t data_sel);
 *     desc RDI, code_sel SI, data_sel DX
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

	.section .note.GNU-stack, "", @progbits
