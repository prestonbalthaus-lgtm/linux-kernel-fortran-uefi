/* SPDX-License-Identifier: GPL-2.0 */
/*
 * boot/faultgen.S -- raise a fault on purpose (roadmap 3.2.5, 3.4).
 *
 *     void fk_smash_stack(void);   never returns
 *     void fk_raise_bp(void);      never returns in this kernel
 *
 * Both exist because this tree's rule is that a panic is delivered by the CPU
 * and never simulated by a call: the register dump is only evidence if the
 * registers are the ones the machine was actually holding.  They are in
 * assembly for the same reason -- an optimiser cannot fold away an instruction
 * it is not allowed to see, which is the trap that cost roadmap 3.2 a boot.
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

/*
 * fk_raise_bp -- the PMM's out-of-memory panic (roadmap 3.4).
 *
 * A failed page allocation is a software condition, not a machine fault, so
 * there is no exception for it.  INT3 borrows one: vector 3 is installed and
 * present, the trampoline builds the same 22-quadword frame every other vector
 * does, and src/cpu/fk_idt.f90's catcher prints the full register dump and
 * parks the CPU.  0xCC rather than `int $3` -- the one-byte form is the
 * breakpoint opcode proper, and the two-byte form is a different encoding that
 * some hypervisors intercept differently.
 *
 * The RET is unreachable while the catcher halts.  It is here so that this is a
 * well-formed function rather than one that falls into whatever the linker
 * placed next, which is what would actually happen the day a debugger-style
 * handler resumes from #BP.
 */
	.globl fk_raise_bp
	.type fk_raise_bp, @function
fk_raise_bp:
	int3
	ret
	.size fk_raise_bp, . - fk_raise_bp

	.section .note.GNU-stack, "", @progbits
