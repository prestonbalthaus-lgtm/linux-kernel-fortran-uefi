/* SPDX-License-Identifier: GPL-2.0 */
/*
 * boot/ksyms.S -- linker-script symbols, made readable from Fortran (3.4, 3.5).
 *
 * linker.ld defines these as ABSOLUTE symbols: the VALUE of the symbol is the
 * address, and there is nothing stored at that address to read. Fortran cannot
 * name such a thing. A bind(c) module variable DEFINES a symbol rather than
 * importing one, so it would either collide with the script's definition or --
 * worse -- quietly allocate storage and hand the caller the address of a few
 * bytes of .bss instead of the base of the kernel image.
 *
 * So the value is moved into RAX as an immediate, which is the one place an
 * absolute symbol can be used for what it is. movabsq rather than movl: the
 * symbols are 32-bit or 64-bit depending on which side of KERNEL_VMA they name,
 * and nothing downstream should have to know which.
 *
 * tools/linkscript-test.sh reads every immediate below back out of the linked
 * image and compares it against the linker's own value for the symbol -- an
 * accessor that returns the wrong constant is otherwise invisible: the PMM
 * would mark the wrong frames used, or the VMM would map the wrong extent with
 * the wrong permissions, and every verdict either printed would still say PASS.
 */

	.macro	KSYM fn, sym
	.globl	\fn
	.type	\fn, @function
\fn:
	movabsq	$\sym, %rax
	ret
	.size	\fn, . - \fn
	.endm

	.section .text, "ax", @progbits
	.code64

	/* Physical extent, for the PMM (roadmap 3.4). */
	KSYM	fk_kernel_phys_start,  __kernel_phys_start
	KSYM	fk_kernel_phys_end,    __kernel_phys_end

	/*
	 * Virtual extent and per-section bounds, for the VMM (roadmap 3.5).
	 * KERNEL_VMA is NOT duplicated a third time in Fortran: fk_vmm_m
	 * derives it as fk_kernel_start() - fk_kernel_phys_start(), so the
	 * one thing that cannot silently diverge is the one thing every
	 * PHYS()/virt conversion in the VMM depends on.
	 */
	KSYM	fk_kernel_start,       __kernel_start
	KSYM	fk_kernel_end,         __kernel_end
	KSYM	fk_text_start,         __text_start
	KSYM	fk_text_end,           __text_end
	KSYM	fk_rodata_start,       __rodata_start
	KSYM	fk_rodata_end,         __rodata_end
	KSYM	fk_data_start,         __data_start
	KSYM	fk_data_end,           __data_end
	KSYM	fk_bss_start,          __bss_start
	KSYM	fk_bss_end,            __bss_end
	KSYM	fk_bootpt_start,       __bootpt_start
	KSYM	fk_bootpt_end,         __bootpt_end

	/* The guard page and the stack it protects. */
	KSYM	fk_boot_stack_guard,   __boot_stack_guard
	KSYM	fk_boot_stack_bottom,  __boot_stack_bottom
	KSYM	fk_boot_stack_top,     __boot_stack_top

	.section .note.GNU-stack, "", @progbits
