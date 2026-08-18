/* SPDX-License-Identifier: GPL-2.0 */
/*
 * boot/io.S -- x86 port-I/O wrappers.  IN and OUT are the only way to reach
 * the I/O port space, and gfortran can emit neither, so the UART driver calls
 * these through bind(c).  int32_t because Fortran has no unsigned types.
 *
 *     void    fk_outb(int32_t port, int32_t value);   port EDI, value ESI
 *     int32_t fk_inb (int32_t port);                  port EDI, result EAX
 *
 * And MMIO, which gfortran CAN emit and that is exactly the problem:
 *
 *     int32_t fk_readl (int64_t addr);                 addr RDI, result EAX
 *     void    fk_writel(int64_t addr, int32_t value);  addr RDI, value ESI
 *
 * WHY THESE ARE ASSEMBLY AND NOT A VOLATILE FORTRAN POINTER.  They were, and
 * gfortran narrowed them.  ibits(load, 16, 8) on a c_int32_t reached through a
 * VOLATILE pointer proves to the optimiser that only one byte of the load is
 * ever used, and -O2 emits `movzbl 0x2(%rax)` -- a ONE-BYTE read of a device
 * register.  Fortran's VOLATILE does not forbid narrowing the access, only
 * eliminating or reordering it.
 *
 * That is undefined behaviour on both parts this kernel talks to.  The SDM
 * requires every local APIC register to be read with a naturally aligned
 * 4-byte load (Vol.3 11.4.1), and the I/O APIC's IOWIN is a single 32-bit
 * window whose sub-dword behaviour the 82093AA datasheet does not define.
 * QEMU answered the narrowed reads with zero, which is how it was found:
 * lapic_max_lvt and ioapic_max_redir both read bits 23:16 and both got 0.
 *
 * A call to a function the compiler cannot see through cannot be narrowed,
 * reordered against another such call, or elided.  That is what readl() and
 * writel() are in Linux, and it is the only construct that actually carries
 * the guarantee.
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

	.section .text, "ax", @progbits
	.code64
	.globl fk_readl
	.type fk_readl, @function
fk_readl:
	movl	(%rdi), %eax
	ret
	.size fk_readl, . - fk_readl

	.section .text, "ax", @progbits
	.code64
	.globl fk_writel
	.type fk_writel, @function
fk_writel:
	movl	%esi, (%rdi)
	ret
	.size fk_writel, . - fk_writel

	.section .note.GNU-stack, "", @progbits
