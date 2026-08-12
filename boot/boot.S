/* SPDX-License-Identifier: GPL-2.0 */
/*
 * PROJECT FORTRAN-KERNEL -- boot/boot.S   (roadmap 1.2)
 *
 * The Multiboot2 entry path and the entire non-Fortran part of the kernel:
 * everything between "GRUB just jumped to us in 32-bit protected mode" and
 * "call a SysV AMD64 function written in Fortran".
 *
 * WHAT MAKES THIS FILE DIFFERENT FROM THE TEXTBOOK VERSION
 *
 * This kernel is linked HIGHER-HALF: linker.ld places every symbol at
 * KERNEL_VMA + 1 MiB = 0xFFFFFFFF80100000, while AT() makes the loadable
 * image land at PHYSICAL 1 MiB.  That split is forced by -mcmodel=kernel,
 * which every Fortran module in this tree is compiled with and which promises
 * the compiler that code and data live in the top 2 GiB.
 *
 * The consequence for this file is absolute and unforgiving: GRUB hands
 * control over with PAGING OFF, so for the whole .code32 half of this stub
 * NO SYMBOL IN THIS IMAGE IS ADDRESSABLE BY ITS LINK-TIME VALUE.  Every
 * reference to a kernel symbol before the higher-half jump must be written
 * PHYS(sym), i.e. sym - KERNEL_VMA.
 *
 * Two failure modes hide behind that rule, and only one of them is loud:
 *
 *   movl $sym, %eax          -- forgetting PHYS() emits R_X86_64_32, whose
 *                               value 0xFFFFFFFF80... does not fit unsigned
 *                               32 bits.  The LINK FAILS.  Loud, harmless.
 *   movl %eax, sym           -- forgetting PHYS() on a memory operand emits
 *                               R_X86_64_32S, which SIGN-EXTENDS.  It links
 *                               silently, and the store goes to physical
 *                               ~2 GiB (unmapped, or somebody else's RAM).
 *                               Nothing faults here; the value simply is not
 *                               there when the 64-bit half reads it back.
 *
 * The second one is why tools/qemu-boot-test.sh exists: it reads the value
 * that actually crossed into Fortran out of guest physical memory.  A grep for
 * PHYS() cannot prove correctness, and neither can grub2-file.
 *
 * THE LADDER, IN ORDER
 *
 *   1. .multiboot_header  -- placed first in the image by linker.ld so GRUB
 *      finds it inside the mandatory first 32 KiB.
 *   2. _start, .code32    -- cli, stash GRUB's handoff registers.
 *   3. Page tables: 1 GiB identity map (2 MiB pages) AND the same 1 GiB
 *      mapped again at KERNEL_VMA.  Both are required: the code executing
 *      right after CR0.PG goes high is still running at a physical address,
 *      and the code it is about to jump to lives in the higher half.
 *   4. CR3, CR4.PAE, EFER.LME, CR0.PG  -- this order is architectural, not
 *      stylistic.
 *   5. lgdt + ljmp through an L-bit descriptor: the far jump is what actually
 *      promotes CS to 64-bit.
 *   6. .code64 at a physical address -- an absolute jump moves RIP into the
 *      higher half, which is the first instant the linker's world view and
 *      the CPU's agree.
 *   7. Zero .bss, install the stack, call kernel_main(magic, mbi).
 *
 * No CPUID long-mode probe: GRUB2 will not load a Multiboot2 ELF64 image on a
 * CPU without long mode in the first place, so the check could only fail on a
 * machine that cannot reach this code.  An unreachable failure path is a
 * liability, not a safety net.
 *
 * ASSEMBLE-TIME NOTE: this file goes through cpp (gcc -c ... boot.S, capital
 * S), so comments are C block syntax and PHYS() below is a cpp macro.  A '#'
 * in column 1 would be read as a preprocessor directive, not a GAS comment.
 */

/* ------------------------------------------------------------------------ */
/* Addressing                                                                */
/* ------------------------------------------------------------------------ */

/*
 * MUST equal KERNEL_VMA in linker.ld.  There is no way to import a linker
 * script constant into an assembler source, so it is duplicated here and
 * tools/linkscript-test.sh diffs the two values out of the two files: a
 * silent divergence would move every PHYS() by a fixed offset and produce a
 * kernel that triple-faults the instant paging comes on.
 */
#define KERNEL_VMA 0xFFFFFFFF80000000

/* Physical (== pre-paging, == identity-mapped) address of a kernel symbol. */
#define PHYS(sym)  ((sym) - KERNEL_VMA)

	.set MB2_MAGIC,       0xE85250D6	/* Multiboot2 header magic       */
	.set MB2_ARCH_I386,   0			/* architecture 0 = 32-bit i386  */
	.set MB2_TAG_ENTRY,   3			/* entry address tag             */
	.set MB2_TAG_END,     0			/* required list terminator      */

	.set CR4_PAE,         (1 << 5)		/* physical address extension    */
	.set CR0_PE,          (1 << 0)		/* protected mode (GRUB set it)  */
	.set CR0_PG,          (1 << 31)		/* paging enable                 */

	.set MSR_EFER,        0xC0000080	/* extended feature enable MSR   */
	.set EFER_LME,        (1 << 8)		/* long mode enable              */

	/* Page-table entry flags. P = present, RW = writable, PS = 2 MiB page. */
	.set PTE_P,           (1 << 0)
	.set PTE_RW,          (1 << 1)
	.set PTE_PS,          (1 << 7)
	.set PTE_TABLE,       (PTE_P | PTE_RW)		/* points at next level */
	.set PTE_2M_PAGE,     (PTE_P | PTE_RW | PTE_PS)	/* maps a 2 MiB frame   */

	.set PAGE_SIZE,       4096
	.set PD_ENTRIES,      512	/* 512 * 2 MiB = exactly 1 GiB       */
	.set SIZE_2M,         0x200000

	/*
	 * Paging-structure indices for KERNEL_VMA = 0xFFFFFFFF80000000:
	 *   PML4 index = bits 47:39 = 511
	 *   PDPT index = bits 38:30 = 510
	 * The PD itself is SHARED with the identity map -- both windows show
	 * the same first 1 GiB of physical memory, which is exactly the
	 * property the higher-half jump in step 6 depends on.
	 */
	.set PML4_IDX_HIGH,   511
	.set PDPT_IDX_HIGH,   510

	.set GDT_SEL_CODE64,  0x08	/* byte offset of the 64-bit code desc */
	.set GDT_SEL_DATA,    0x10	/* byte offset of the flat data desc   */

/* ------------------------------------------------------------------------ */
/* 1. Multiboot2 header                                                      */
/*                                                                           */
/* linker.ld emits .multiboot_header as the first output section of the      */
/* image, so it sits at file offset ~0x1000 -- comfortably inside the 32 KiB */
/* window the specification allows a boot loader to scan.  The header and    */
/* every tag inside it must be 8-byte aligned.                               */
/* ------------------------------------------------------------------------ */

	.section .multiboot_header, "a", @progbits
	.align 8
	.globl mb2_header_start
mb2_header_start:
	.long	MB2_MAGIC
	.long	MB2_ARCH_I386
	.long	mb2_header_end - mb2_header_start	/* header_length */
	/*
	 * Checksum.  The specification requires
	 *     magic + architecture + header_length + checksum == 0  (mod 2^32)
	 * so the field is the two's complement of the other three.  GAS
	 * truncates the .long to 32 bits, which is precisely the modulus
	 * wanted; writing this as a positive constant is the classic way to
	 * produce a header GRUB silently refuses.
	 */
	.long	-(MB2_MAGIC + MB2_ARCH_I386 + (mb2_header_end - mb2_header_start))

	/*
	 * Entry address tag (type 3).  THIS TAG IS NOT OPTIONAL FOR A
	 * HIGHER-HALF KERNEL, and it is the one thing grub2-file cannot check.
	 *
	 * ELF e_entry is a VIRTUAL address, and ours is 0xFFFFFFFF80100xxx.
	 * GRUB jumps to the entry point in 32-bit protected mode with paging
	 * off, where that value is meaningless.  This tag hands GRUB the
	 * PHYSICAL address instead.  linker.ld additionally sets
	 * ENTRY(_start_phys) so e_entry carries the same physical value: the
	 * two paths agree, and it does not matter which one the loader takes.
	 */
	.align 8
mb2_tag_entry:
	.short	MB2_TAG_ENTRY		/* type  = 3                          */
	.short	0			/* flags = 0 -> required, not optional */
	.long	12			/* size  = 12 bytes                    */
	.long	PHYS(_start)		/* entry_addr, 32-bit physical         */
	/* size 12 is not a multiple of 8; the .align 8 below is the padding. */

	/*
	 * DELIBERATELY ABSENT: the framebuffer tag (type 5), which roadmap 2.2
	 * needs and which is the next thing to add here.  It is left out now
	 * because it changes the boot mode -- GRUB switches to a graphics mode
	 * and the text-mode assumptions of this milestone stop holding -- and
	 * because the framebuffer GOP reports on real hardware is frequently a
	 * PCI BAR above 4 GiB, outside the 1 GiB identity map built below.
	 * Requesting it before the map covers it produces a page fault with no
	 * IDT (roadmap 3.2), i.e. a triple fault and a silent reboot.
	 *
	 * When 2.2 lands, the tag is:
	 *     .align 8
	 *     .short 5 ; .short 0 ; .long 20
	 *     .long <width> ; .long <height> ; .long <depth>
	 * and the identity map below must be widened to cover the reported
	 * framebuffer before vga_init_framebuffer() is handed the address.
	 */

	/* Required list terminator: type 0, flags 0, size 8. */
	.align 8
mb2_tag_end:
	.short	MB2_TAG_END
	.short	0
	.long	8
	.globl mb2_header_end
mb2_header_end:

/* ------------------------------------------------------------------------ */
/* 2. 32-bit entry point                                                     */
/* ------------------------------------------------------------------------ */

	.section .text.boot, "ax", @progbits
	.code32
	.globl _start
	.type _start, @function
_start:
	/*
	 * GRUB hands control over already in 32-bit protected mode with a flat
	 * GDT, A20 enabled and paging off.  No real mode, no .code16, ever.
	 *
	 * Handoff state that matters:
	 *     eax = 0x36D76289  (Multiboot2 "I am a compliant loader" magic)
	 *     ebx = physical address of the Multiboot information structure
	 */
	cli				/* no IDT exists; an IRQ here is fatal */

	/*
	 * Stash the handoff registers in .data immediately.
	 *
	 * They cannot simply stay in registers: the page-table zeroing below
	 * uses "rep stosl", which destroys edi, ecx and eax.  Memory is the
	 * only storage that provably survives the whole ladder, and .data
	 * rather than .bss so it is immune to the bss clear in step 7.
	 *
	 * Note PHYS() on a STORE DESTINATION -- this is the R_X86_64_32S case
	 * from the file header, the one that would link cleanly and be wrong.
	 */
	movl	%eax, PHYS(saved_magic)
	movl	%ebx, PHYS(saved_mbi)

	/* ---------------------------------------------------------------- */
	/* 3. Build the paging hierarchy                                     */
	/*                                                                   */
	/*   PML4[0]   -> pdpt_low  -> [0]   -> pd_table   (identity)        */
	/*   PML4[511] -> pdpt_high -> [510] -> pd_table   (higher half)     */
	/*   pd_table[i] = i * 2 MiB, present, writable, PS                  */
	/*                                                                   */
	/* One PD serves both windows: 512 * 2 MiB = 1 GiB of physical       */
	/* memory, which contains this kernel at 1 MiB and the legacy VGA    */
	/* aperture at 0xB8000.  The identity map is what keeps the          */
	/* instruction stream valid across the CR0.PG store; the higher-half */
	/* map is what makes every linker-assigned address valid afterwards. */
	/* ---------------------------------------------------------------- */

	/*
	 * Zero PML4, pdpt_low and pdpt_high.  Only one entry of each is
	 * meaningful, but the other 511 must not hold garbage: the MMU walks
	 * whatever is there the moment a stray address is touched, and a
	 * present-looking bogus entry becomes an unexplainable triple fault.
	 * (pd_table is written in full by the loop below and needs no clear.)
	 *
	 * .bootpt is a NOLOAD section, so nothing in the file backs it and
	 * GRUB's zero-fill of the segment tail is the only other thing that
	 * would have cleared it -- not a property worth depending on.
	 */
	cld
	xorl	%eax, %eax
	movl	$PHYS(pml4_table), %edi
	movl	$((3 * PAGE_SIZE) / 4), %ecx	/* three tables, in dwords */
	rep stosl

	/* PML4[0] = pdpt_low | present | writable   (identity window) */
	movl	$PHYS(pdpt_low), %eax
	orl	$PTE_TABLE, %eax
	movl	%eax, PHYS(pml4_table)

	/* PML4[511] = pdpt_high | present | writable  (higher-half window) */
	movl	$PHYS(pdpt_high), %eax
	orl	$PTE_TABLE, %eax
	movl	%eax, PHYS(pml4_table) + PML4_IDX_HIGH * 8

	/* pdpt_low[0] = pd_table | present | writable */
	movl	$PHYS(pd_table), %eax
	orl	$PTE_TABLE, %eax
	movl	%eax, PHYS(pdpt_low)

	/* pdpt_high[510] = pd_table | present | writable  -- the SAME PD */
	movl	%eax, PHYS(pdpt_high) + PDPT_IDX_HIGH * 8

	/*
	 * pd_table[i] = (i * 2 MiB) | present | writable | PS.
	 *
	 * esi = index, eax = running physical frame address.  Each entry is 8
	 * bytes; the upper dword stays zero because 1 GiB needs no bits above
	 * 32, and because the NX bit must stay clear -- we execute out of this
	 * map.
	 */
	movl	$PHYS(pd_table), %edi		/* base, in a register: a  */
						/* parenthesised PHYS() as */
						/* a displacement in front */
						/* of (,%esi,8) is not     */
						/* AT&T-parsable          */
	xorl	%esi, %esi			/* i = 0 */
	movl	$PTE_2M_PAGE, %eax		/* frame 0 + flags */
1:
	movl	%eax, (%edi, %esi, 8)		/* low  dword */
	movl	$0, 4(%edi, %esi, 8)		/* high dword */
	addl	$SIZE_2M, %eax
	incl	%esi
	cmpl	$PD_ENTRIES, %esi
	jb	1b

	/* ---------------------------------------------------------------- */
	/* 4. PAE, long mode, paging -- in that order, as the ISA mandates   */
	/* ---------------------------------------------------------------- */

	movl	$PHYS(pml4_table), %eax
	movl	%eax, %cr3			/* CR3 takes a PHYSICAL address */

	movl	%cr4, %eax
	orl	$CR4_PAE, %eax
	movl	%eax, %cr4

	movl	$MSR_EFER, %ecx			/* EFER = MSR 0xC0000080     */
	rdmsr					/* -> edx:eax (clobbers both) */
	orl	$EFER_LME, %eax
	wrmsr

	movl	%cr0, %eax
	orl	$(CR0_PG | CR0_PE), %eax	/* PE is already on; assert it */
	movl	%eax, %cr0
	/*
	 * Paging is now on and long mode is active, but CS still describes a
	 * 32-bit segment: this is IA-32e COMPATIBILITY mode, still decoding
	 * 32-bit instructions.  The next instruction fetch resolves through
	 * the identity map, which is why that map is not optional.
	 */

	/* ---------------------------------------------------------------- */
	/* 5. Load the 64-bit GDT and far-jump into it                       */
	/* ---------------------------------------------------------------- */

	lgdt	PHYS(gdt64_pointer)
	ljmp	$GDT_SEL_CODE64, $PHYS(long_mode_entry)
	.size _start, . - _start

/* ------------------------------------------------------------------------ */
/* 6. 64-bit land, still executing at a physical address                     */
/* ------------------------------------------------------------------------ */

	.section .text.boot, "ax", @progbits
	.code64
	.type long_mode_entry, @function
long_mode_entry:
	/*
	 * Reload every data segment register with the flat data selector.  In
	 * 64-bit mode segmentation is mostly inert, but the stale 32-bit
	 * selectors GRUB left behind are still architecturally live in
	 * ss/ds/es/fs/gs and must not be trusted.
	 */
	movw	$GDT_SEL_DATA, %ax
	movw	%ax, %ds
	movw	%ax, %es
	movw	%ax, %fs
	movw	%ax, %gs
	movw	%ax, %ss

	/*
	 * Move RIP into the higher half.  This is the moment the CPU's view
	 * and the linker's view finally coincide; from here on, symbols are
	 * used at their link-time addresses and PHYS() must NOT appear.
	 *
	 * An absolute indirect jump is required: a direct "jmp higher_half"
	 * assembles to a RIP-relative 32-bit displacement, and the distance
	 * from ~1 MiB to ~0xFFFFFFFF80100000 does not fit in one.
	 */
	movabsq	$higher_half, %rax
	jmpq	*%rax
	.size long_mode_entry, . - long_mode_entry

	.section .text.boot, "ax", @progbits
	.code64
	.type higher_half, @function
higher_half:
	/* ---------------------------------------------------------------- */
	/* 7. Clear .bss, install the stack, hand over to Fortran            */
	/* ---------------------------------------------------------------- */

	/*
	 * Zero [__bss_start, __bss_end).  linker.ld documents this as the
	 * entry stub's contract, and the Fortran side depends on it: module
	 * variables (fb_ready, fb_width, the framebuffer pointer) live there
	 * and are assumed zero on entry.
	 *
	 * GRUB does zero-fill the memsz tail of a PT_LOAD, so today this loop
	 * is belt and braces -- but the UEFI stage-1 path in linker.ld's header
	 * comment makes no such promise, and a kernel whose correctness rests
	 * on which loader started it is a kernel with a latent bug.
	 *
	 * NO STACK IS USED HERE: rsp is still whatever GRUB left behind, and
	 * the boot stack this code is about to install lives INSIDE the region
	 * being zeroed.  Clearing first and setting rsp afterwards is the only
	 * order that does not shoot through its own frame.
	 *
	 * The page tables are NOT in this range -- linker.ld puts them in
	 * .bootpt, outside [__bss_start, __bss_end).  Zeroing the live CR3
	 * hierarchy here would triple-fault on the very next instruction
	 * fetch, and that is exactly what happens if .bootpt is ever moved
	 * back inside .bss.
	 */
	movabsq	$__bss_start, %rdi
	movabsq	$__bss_end, %rcx
	subq	%rdi, %rcx
	shrq	$3, %rcx			/* bytes -> quadwords (8-aligned
						   by an ALIGN(8) in linker.ld) */
	xorl	%eax, %eax
	cld
	rep stosq

	/*
	 * ---- STACK ALIGNMENT, the most common cause of mysterious crashes ----
	 *
	 * The SysV AMD64 ABI requires rsp % 16 == 0 AT THE CALL SITE.  CALL
	 * then pushes the 8-byte return address, so the callee sees
	 * rsp % 16 == 8, which is what gfortran's prologue is compiled to
	 * expect.  __boot_stack_top is 16-byte aligned by construction
	 * (linker.ld: ALIGN(16) then a 16 KiB reservation), and nothing is
	 * pushed between here and the call, so the requirement holds.
	 */
	movabsq	$__boot_stack_top, %rsp

	/*
	 * Break the frame-pointer chain so a debugger or a future stack walker
	 * stops here instead of chasing garbage out of the boot stack.
	 */
	xorq	%rbp, %rbp

	/*
	 * Marshal the arguments for
	 *     void kernel_main(uint32_t magic, void *mbi);
	 * SysV AMD64 puts the first integer argument in edi/rdi and the second
	 * in rsi.
	 *
	 * saved_mbi holds a 32-bit physical pointer from GRUB; MOVL
	 * zero-extends it into the whole of rsi, which is the correct widening
	 * for an address below 4 GiB.  A sign-extending 64-bit load would be
	 * wrong for any address at or above 2 GiB.
	 *
	 * RIP-relative here, absolute-physical in the .code32 half: the SAME
	 * two variables, reached two different ways, because the address space
	 * changed underneath them.
	 */
	movl	saved_magic(%rip), %edi
	movl	saved_mbi(%rip), %esi

	call	kernel_main

	/*
	 * Safety net.  The contract says kernel_main never returns; if it ever
	 * does, park the CPU rather than executing whatever follows in memory.
	 */
	jmp	fk_cpu_halt
	.size higher_half, . - higher_half

/* ------------------------------------------------------------------------ */
/* fk_cpu_halt -- park this CPU permanently.  Exported to Fortran.           */
/*                                                                           */
/* Fortran has no inline-assembly extension, so CLI/HLT -- a privileged      */
/* CPU-control operation -- cannot be expressed in Fortran at all.  This is  */
/* precisely the boundary the assembly glue layer exists to cover, and       */
/* ISO_C_BINDING is how Fortran reaches across it.  Note the direction:      */
/* kernel_main is asm calling INTO Fortran; this is Fortran calling back     */
/* OUT to asm.                                                              */
/*                                                                          */
/* HLT rather than a Fortran spin loop: a spin loop is functionally correct  */
/* but pins a core at 100% forever.  CLI has masked interrupts, so the park  */
/* is permanent.  Never returns.                                            */
/* ------------------------------------------------------------------------ */

	.section .text, "ax", @progbits
	.code64
	.globl fk_cpu_halt
	.type fk_cpu_halt, @function
fk_cpu_halt:
	cli
1:	hlt
	jmp	1b			/* an NMI/SMI can wake HLT; re-park */
	.size fk_cpu_halt, . - fk_cpu_halt

/* ------------------------------------------------------------------------ */
/* Read-only data: the 64-bit GDT                                            */
/* ------------------------------------------------------------------------ */

	.section .rodata
	.align 16
gdt64:
	/* 0x00 -- the mandatory null descriptor. */
	.quad	0x0000000000000000
	/*
	 * 0x08 -- 64-bit code segment.
	 *   0x00AF9A000000FFFF
	 *        ^^  ^^
	 *        ||  ++-- access = 0x9A: P=1, DPL=0, S=1, type=1010 (code,
	 *        ||                      execute/read, non-conforming)
	 *        ++------ flags  = 0xA:  G=1, D/B=0, L=1 (64-bit), AVL=0
	 * The L bit is the entire point of this descriptor: the ljmp above
	 * uses it to switch CS into 64-bit mode.  D/B must be 0 when L is 1.
	 */
	.quad	0x00AF9A000000FFFF
	/*
	 * 0x10 -- flat data segment.  access = 0x92: P=1, DPL=0, S=1,
	 * type=0010 (data, read/write).  Base and limit are ignored in 64-bit
	 * mode, but ss/ds/es must still reference a present descriptor.
	 */
	.quad	0x00CF92000000FFFF
gdt64_end:

	/*
	 * The pseudo-descriptor consumed by LGDT.  It is loaded while the CPU
	 * still decodes 32-bit instructions, so the operand format is the
	 * 32-bit one: a 16-bit limit followed by a 32-bit base.  The base must
	 * therefore be the PHYSICAL address of the table -- valid because
	 * paging is on and the identity map covers it.  Entering long mode
	 * zero-extends the stored base to 64 bits and GDTR is never reloaded,
	 * so the identity map must remain live for as long as the descriptor
	 * cache is trusted; unmapping PML4[0] is a roadmap 3.5 decision and
	 * requires reloading GDTR with the higher-half address first.
	 *
	 * Limit is size-1, i.e. the offset of the last valid byte.
	 */
	.align 8
gdt64_pointer:
	.word	gdt64_end - gdt64 - 1
	.long	PHYS(gdt64)

/* ------------------------------------------------------------------------ */
/* Initialised data: GRUB's handoff values                                   */
/*                                                                           */
/* .data, not .bss, deliberately: these are written in .code32 and read back */
/* in .code64 across the bss clear, which would otherwise erase them.        */
/* ------------------------------------------------------------------------ */

	.section .data
	.align 8
	.globl saved_magic
saved_magic:
	.long	0			/* eax at entry: expect 0x36D76289 */
	.globl saved_mbi
saved_mbi:
	.long	0			/* ebx at entry: MBI physical addr */

/* ------------------------------------------------------------------------ */
/* Boot page tables                                                          */
/*                                                                           */
/* .bootpt is a NOLOAD section that linker.ld places OUTSIDE                 */
/* [__bss_start, __bss_end).  See the bss clear in step 7 for why that       */
/* separation is load-bearing rather than tidy.                              */
/* ------------------------------------------------------------------------ */

	.section .bootpt, "aw", @nobits
	.align PAGE_SIZE		/* hardware requires 4 KiB alignment */
	.globl pml4_table
pml4_table:
	.skip	PAGE_SIZE
	.globl pdpt_low
pdpt_low:
	.skip	PAGE_SIZE
	.globl pdpt_high
pdpt_high:
	.skip	PAGE_SIZE
	.globl pd_table
pd_table:
	.skip	PAGE_SIZE

	/* Nothing here is executable; tell the linker so it stops warning. */
	.section .note.GNU-stack, "", @progbits
