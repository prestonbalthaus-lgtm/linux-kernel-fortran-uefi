/* SPDX-License-Identifier: GPL-2.0 */
/*
 * boot/faultgen.S -- raise a double fault on purpose (roadmap 3.2.5).
 *
 *     void fk_smash_stack(void);   never returns
 *
 * 0x0000400000000000 is canonical and mapped by nothing: boot.S identity-maps
 * the low 1 GiB and linker.ld maps the kernel at -2 GiB.  So the PUSH takes a
 * #PF, and the CPU's attempt to push the #PF frame on the same broken RSP is
 * the second fault -- which is what a #DF is.  Nothing is saved first; the
 * only thing that runs after this is the panic handler, on IST1.
 */

	.section .text, "ax", @progbits
	.code64
	.globl fk_smash_stack
	.type fk_smash_stack, @function
fk_smash_stack:
	movabsq	$0x0000400000000000, %rsp
	pushq	$0
	/* Unreachable: the PUSH above cannot retire.  Park rather than run on. */
	jmp	fk_cpu_halt
	.size fk_smash_stack, . - fk_smash_stack

	.section .note.GNU-stack, "", @progbits
