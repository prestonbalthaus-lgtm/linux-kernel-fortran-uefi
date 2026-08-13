/* SPDX-License-Identifier: GPL-2.0 */
/*
 * boot/ksyms.S -- linker-script symbols, made readable from Fortran (3.4).
 *
 *     uint64_t fk_kernel_phys_start(void);
 *     uint64_t fk_kernel_phys_end(void);
 *
 * linker.ld defines __kernel_phys_start/_end as ABSOLUTE symbols: the VALUE of
 * the symbol is the address, and there is nothing stored at that address to
 * read. Fortran cannot name such a thing. A bind(c) module variable DEFINES a
 * symbol rather than importing one, so it would either collide with the
 * script's definition or -- worse -- quietly allocate storage and hand the PMM
 * the address of four bytes of .bss instead of the base of the kernel image.
 *
 * So the value is moved into RAX as an immediate, which is the one place an
 * absolute symbol can be used for what it is. movabsq rather than movl: the
 * symbol is 32-bit today (0x100000) but the whole point of returning it as a
 * uint64_t is that nothing downstream has to know that.
 *
 * tools/linkscript-test.sh reads the immediate back out of the linked image and
 * compares it against the linker's own value for the symbol -- an accessor that
 * returns the wrong constant is otherwise invisible: the PMM would happily mark
 * the wrong pages used and every verdict it prints would still say PASS.
 */

	.section .text, "ax", @progbits
	.code64

	.globl fk_kernel_phys_start
	.type fk_kernel_phys_start, @function
fk_kernel_phys_start:
	movabsq	$__kernel_phys_start, %rax
	ret
	.size fk_kernel_phys_start, . - fk_kernel_phys_start

	.globl fk_kernel_phys_end
	.type fk_kernel_phys_end, @function
fk_kernel_phys_end:
	movabsq	$__kernel_phys_end, %rax
	ret
	.size fk_kernel_phys_end, . - fk_kernel_phys_end

	.section .note.GNU-stack, "", @progbits
