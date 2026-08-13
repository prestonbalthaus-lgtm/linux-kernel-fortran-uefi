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
 *     int32_t  fk_pat_arm(void);              0 = PAT programmed, 1 = absent
 *     uint64_t fk_read_pat(void);             IA32_PAT as the CPU holds it
 */

	.set	CR0_WP,     (1 << 16)
	.set	MSR_EFER,   0xC0000080
	.set	EFER_NXE,   (1 << 11)
	.set	CPUID_EXT,  0x80000001
	.set	CPUID_NX,   20		/* CPUID.80000001H:EDX.NX */
	.set	CPUID_PAT,  16		/* CPUID.01H:EDX.PAT      */
	.set	MSR_PAT,    0x277

	/*
	 * IA32_PAT, one memory type per byte, PA0 in bits 7:0.
	 *
	 *     PA0 = 06 WB   PA1 = 01 WC   PA2 = 07 UC-  PA3 = 00 UC
	 *     PA4 = 06 WB   PA5 = 01 WC   PA6 = 07 UC-  PA7 = 00 UC
	 *
	 * Only PA1 differs from the reset value, where it is WT.  The point of
	 * putting WC at index 1 rather than at 4-7 is that indices 0-3 are
	 * selected by PWT and PCD ALONE: the third selector bit is PTE bit 7 on
	 * a 4 KiB page and PTE bit 12 on a 2 MiB one, and bit 7 on a 2 MiB
	 * entry is PS.  Staying below index 4 means one flag -- PWT -- means WC
	 * at every page size, so the VMM cannot select the wrong memory type by
	 * mapping at the wrong granularity.
	 */
	.set	PAT_VALUE_LO, 0x00070106
	.set	PAT_VALUE_HI, 0x00070106

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

/*
 * Program IA32_PAT so that PWT alone selects write-combining.
 *
 * ORDER MATTERS AND IS NOT THE SDM's FULL RITUAL.  Intel's documented
 * procedure for changing PAT on a running system disables the cache, flushes
 * it, flushes the TLB, writes the MSR and undoes all of that -- because a page
 * already cached under the old memory type would otherwise be left with two.
 * This runs before the kernel has created a single mapping that selects PWT,
 * so no page's type is being CHANGED and there is nothing cached under the old
 * meaning of index 1.  The caller reloads CR3 before the first write-combining
 * mapping is used, which is what retires the TLB entries.
 *
 * Returns 1 without touching the MSR if the CPU has no PAT: writing MSR 0x277
 * on such a part is a #GP, and this kernel would take it before the IDT could
 * say anything useful about it.
 */
	.globl	fk_pat_arm
	.type	fk_pat_arm, @function
fk_pat_arm:
	pushq	%rbx			/* CPUID clobbers RBX, SysV saves it */
	movl	$1, %eax
	cpuid
	btl	$CPUID_PAT, %edx
	jnc	1f

	movl	$MSR_PAT, %ecx
	movl	$PAT_VALUE_LO, %eax
	movl	$PAT_VALUE_HI, %edx
	wrmsr
	xorl	%eax, %eax
	popq	%rbx
	ret
1:
	movl	$1, %eax
	popq	%rbx
	ret
	.size	fk_pat_arm, . - fk_pat_arm

/*
 * IA32_PAT read back off the CPU.  The kernel prints this rather than the
 * constant it wrote: a wrmsr that never executed is otherwise indistinguishable
 * from one that did, and the reset value differs from the wanted one in exactly
 * the byte that decides whether the framebuffer is write-combining.
 */
	.globl	fk_read_pat
	.type	fk_read_pat, @function
fk_read_pat:
	pushq	%rbx
	movl	$1, %eax
	cpuid
	btl	$CPUID_PAT, %edx
	jnc	1f
	movl	$MSR_PAT, %ecx
	rdmsr
	shlq	$32, %rdx
	orq	%rdx, %rax
	popq	%rbx
	ret
1:
	xorl	%eax, %eax
	popq	%rbx
	ret
	.size	fk_read_pat, . - fk_read_pat

	.section .note.GNU-stack, "", @progbits
