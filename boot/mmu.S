/* SPDX-License-Identifier: GPL-2.0 */
/*
 * boot/mmu.S -- the paging control registers (roadmap 3.5).  MOV to and from
 * CR0/CR2/CR3, INVLPG, RDMSR/WRMSR and CPUID are all privileged or otherwise
 * unspellable in Fortran, which is the boundary this glue layer exists to cover.
 *
 *     void     fk_write_cr3(uint64_t phys);   phys RDI  -- also flushes the TLB
 *     uint64_t fk_read_cr3(void);
 *     uint64_t fk_read_cr2(void);             the faulting address after a #PF
 *     void     fk_invlpg(uint64_t virt);      virt RDI
 *     int32_t  fk_mmu_arm(void);              0 = NX usable, 1 = not
 */

	.set	CR0_WP,     (1 << 16)
	.set	MSR_EFER,   0xC0000080
	.set	EFER_NXE,   (1 << 11)
	.set	CPUID_EXT,  0x80000001
	.set	CPUID_NX,   20		/* CPUID.80000001H:EDX.NX */

	.section .text, "ax", @progbits
	.code64

	.globl	fk_write_cr3
	.type	fk_write_cr3, @function
fk_write_cr3:
	movq	%rdi, %cr3
	ret
	.size	fk_write_cr3, . - fk_write_cr3

	.globl	fk_read_cr3
	.type	fk_read_cr3, @function
fk_read_cr3:
	movq	%cr3, %rax
	ret
	.size	fk_read_cr3, . - fk_read_cr3

	.globl	fk_read_cr2
	.type	fk_read_cr2, @function
fk_read_cr2:
	movq	%cr2, %rax
	ret
	.size	fk_read_cr2, . - fk_read_cr2

	.globl	fk_invlpg
	.type	fk_invlpg, @function
fk_invlpg:
	invlpg	(%rdi)
	ret
	.size	fk_invlpg, . - fk_invlpg

/*
 * CR0.WP AND EFER.NXE, and both are load-bearing rather than hardening.
 *
 * With WP clear, a ring-0 store IGNORES the read-only bit in a PTE entirely --
 * so .text and .rodata mapped read-only would still be writable from the only
 * ring this kernel has, and the permissions the VMM installs would be a
 * decoration that no gate could tell from the real thing.
 *
 * With NXE clear, bit 63 of a PTE is RESERVED, not "no execute": setting it
 * does not forbid execution, it makes every access to that page a
 * reserved-bit page fault.  So NX must be enabled BEFORE any table carrying it
 * is loaded into CR3, and the VMM must be told when it could not be -- hence
 * the return value rather than a silent best effort.
 *
 * CPUID clobbers RBX, which SysV makes callee-saved.
 */
	.globl	fk_mmu_arm
	.type	fk_mmu_arm, @function
fk_mmu_arm:
	pushq	%rbx

	movq	%cr0, %rax
	orq	$CR0_WP, %rax
	movq	%rax, %cr0

	/* The extended leaf has to EXIST before EDX.20 means anything. */
	movl	$0x80000000, %eax
	cpuid
	cmpl	$CPUID_EXT, %eax
	jb	1f
	movl	$CPUID_EXT, %eax
	cpuid
	btl	$CPUID_NX, %edx
	jnc	1f

	movl	$MSR_EFER, %ecx
	rdmsr				/* EFER -> edx:eax */
	orl	$EFER_NXE, %eax
	wrmsr
	xorl	%eax, %eax
	popq	%rbx
	ret
1:
	movl	$1, %eax
	popq	%rbx
	ret
	.size	fk_mmu_arm, . - fk_mmu_arm

	.section .note.GNU-stack, "", @progbits
