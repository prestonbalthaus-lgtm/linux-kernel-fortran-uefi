/* SPDX-License-Identifier: GPL-2.0 */
/*
 * boot/faultgen.S -- raise a fault on purpose (roadmap 3.2.5, 3.4).
 *
 *     void     fk_smash_stack(void);      never returns
 *     void     fk_raise_bp(void);         never returns in this kernel
 *     uint64_t fk_peek64(uint64_t addr);  returns, unless the address faults
 *     void     fk_poke64(uint64_t addr, uint64_t v);
 *
 * All three exist because this tree's rule is that a fault is delivered by the
 * CPU and never simulated by a call: the register dump is only evidence if the
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

/*
 * fk_peek64 -- read eight bytes from an address chosen at run time (3.5).
 *
 * The two page faults this milestone has to prove are both a LOAD from an
 * address that must have no translation: the guard page below the boot stack,
 * and physical 1 MiB once PML4[0] is gone.  Written in Fortran the load is
 * removable -- the value is unused, the address is a constant, and gcc is
 * entitled to delete the whole thing, which is exactly how roadmap 3.2's
 * divide-by-zero managed to fault nowhere.  An instruction the optimiser never
 * sees cannot be folded away.
 */
	.globl fk_peek64
	.type fk_peek64, @function
fk_peek64:
	movq	(%rdi), %rax
	ret
	.size fk_peek64, . - fk_peek64

/*
 * fk_poke64 -- and its partner, for the same reason.  The proof that a frame
 * above the old identity window became memory is a store through one virtual
 * address and a load through a DIFFERENT one that must alias it; written in
 * Fortran, an optimiser that cannot see the aliasing is entitled to keep the
 * value in a register and never touch either page.
 */
	.globl fk_poke64
	.type fk_poke64, @function
fk_poke64:
	movq	%rsi, (%rdi)
	ret
	.size fk_poke64, . - fk_poke64

	.section .note.GNU-stack, "", @progbits
