/* SPDX-License-Identifier: GPL-2.0 */
/*
 * boot/io.S -- x86 port-I/O wrappers.  IN and OUT are the only way to reach
 * the I/O port space, and gfortran can emit neither, so the UART driver calls
 * these through bind(c).  int32_t because Fortran has no unsigned types.
 *
 *     void    fk_outb(int32_t port, int32_t value);   port EDI, value ESI
 *     int32_t fk_inb (int32_t port);                  port EDI, result EAX
 */

	.section .text, "ax", @progbits
	.code64
	.globl fk_outb
	.type fk_outb, @function
fk_outb:
	/* OUT's port operand is DX; the register form is required for ports > 0xFF. */
	movw	%di, %dx
	movb	%sil, %al
	outb	%al, %dx
	ret
	.size fk_outb, . - fk_outb

	.section .text, "ax", @progbits
	.code64
	.globl fk_inb
	.type fk_inb, @function
fk_inb:
	movw	%di, %dx
	/* IN writes only AL, so EAX is zeroed first to define bits 31:8. */
	xorl	%eax, %eax
	inb	%dx, %al
	ret
	.size fk_inb, . - fk_inb

	.section .note.GNU-stack, "", @progbits
