/* SPDX-License-Identifier: GPL-2.0 */
/*
 * PROJECT FORTRAN-KERNEL -- boot/io.S   (roadmap 2.1)
 *
 * Eight instructions' worth of assembly -- four per function, counting the
 * RET -- and the whole reason the UART driver in
 * src/drivers/serial/fk_serial.f90 can exist at all.
 *
 * WHY THIS FILE EXISTS
 *
 * A 16550 UART is not memory-mapped on a PC.  Its registers live in the x86 I/O
 * port space -- a second, 16-bit address space that is reachable ONLY by the IN
 * and OUT instructions.  Fortran has no way to spell either one: there is no
 * gfortran equivalent of GCC's asm(), no intrinsic, no ISO_C_BINDING facility
 * and no compiler builtin that emits a port access.  This is not a stylistic
 * preference for assembly over Fortran; it is the complete absence of a Fortran
 * spelling for the operation.
 *
 * That makes port I/O the second of exactly two things in this kernel that must
 * cross into assembly.  The first is CLI/HLT -- fk_cpu_halt, at the bottom of
 * boot/boot.S -- and the direction of travel here is the same as it is there:
 * Fortran calling OUT to assembly, not assembly calling in to Fortran.  (The
 * only traffic in the other direction is kernel_main.)  ISO_C_BINDING is the
 * entire mechanism: bind(c) on the Fortran side, the System V AMD64 C calling
 * convention on this side, and nothing whatsoever in between.
 *
 * THE INTERFACE, AS C
 *
 *     void    fk_outb(int32_t port, int32_t value);
 *     int32_t fk_inb (int32_t port);
 *
 * WHY int32_t AND NOT uint16_t/uint8_t.  Fortran has no unsigned integer types
 * at all.  A u8 register value such as the FCR word 0xC7 has no positive
 * spelling in an 8-bit Fortran integer -- it would have to be written as the
 * negative int8 -57 -- and a port number in the upper half of the I/O space
 * (0x8000..0xFFFF) would be negative in an int16 for the same reason.  Every
 * UART constant in fk_serial.f90 would become a puzzle whose answer is "two's
 * complement", and a mistyped one would look exactly like a correct one.
 * Carrying both arguments in a 32-bit signed integer keeps every constant in
 * the driver positive and plainly itself -- 0x3F8 is 1016, 0xC7 is 199 -- and
 * concentrates the truncation HERE, in two instructions, where it is one
 * decision made once instead of a rule every caller has to remember.
 *
 * REGISTER MAPPING
 *
 * System V AMD64 psABI 3.2.3: INTEGER-class arguments go in rdi, rsi, rdx, rcx,
 * r8, r9 in that order; an INTEGER return value comes back in rax.
 *
 *     fk_outb    port -> EDI    value -> ESI    returns nothing
 *     fk_inb     port -> EDI                    returns EAX
 *
 * THE UPPER-BITS RULE: WHY '%di'/'%sil' ARE RIGHT AND '%edi'/'%esi' WOULD BE
 * SUBTLY WRONG
 *
 * The psABI leaves the bits of an argument register ABOVE the declared width of
 * the argument UNSPECIFIED.  A caller passing an int32_t may leave anything at
 * all in bits 63:32 of rdi; only the bits the type covers are defined, and a
 * callee that reads wider than the type reads garbage that no gate will ever
 * show it.
 *
 * Applied here, that rule turns the operand sizes below into a correctness
 * question rather than a code-size one.  Of the port argument only the low 16
 * bits are architecturally meaningful -- the x86 I/O space is 64 KiB and the
 * OUT/IN port operand is DX, a 16-bit register -- and of the value argument
 * only the low 8 ever reach the wire.  Reading %di and %sil takes exactly the
 * bits that mean something, and structurally cannot observe a bit the caller
 * was never obliged to set.
 *
 * BE PRECISE ABOUT WHAT WOULD ACTUALLY GO WRONG, BECAUSE IT IS LESS THAN IT
 * SOUNDS.  'movl %edi, %edx' in place of the movw below would behave
 * identically on the wire: OUT consumes DX, so a stray bit in EDX 31:16 is
 * never looked at, and 'movl %esi, %eax' would leave exactly the AL that
 * 'movb %sil, %al' leaves.  The truncation the hardware performs is the same
 * truncation either way.  Claiming a miscompile here would be inventing a
 * failure mode, which is the one thing this project's comments are not for.
 *
 * The narrow moves are still the right instructions, for two reasons that are
 * about the boundary rather than about the bits:
 *
 *   * They make the ABI contract legible AT the ABI boundary.  The operand
 *     size is the file saying, in the only notation the assembler has, which
 *     bits of each argument this routine is entitled to read.  A reader of
 *     'movl %edi, %edx' has to know the encoding of OUT to work out that the
 *     upper half is dead; a reader of 'movw %di, %dx' does not.
 *   * They are defence in depth against the day one of these routines grows.
 *     A future fk_outw, or an fk_outb that first range-checks its port, starts
 *     from whatever this file already put in the register -- and a wide move
 *     hands that successor 32 bits of which only 16 mean anything.
 *
 * Stated precisely, so the rule is not remembered wrongly: for an argument
 * DECLARED int32_t the System V AMD64 psABI leaves bits 63:32 undefined, not
 * bits 31:16.  A conforming caller really does define the whole of EDI and
 * ESI.  Reading %di and %sil is a statement about what the HARDWARE consumes;
 * it is not a defence against a caller that was licensed to pass garbage in
 * the bits being dropped, because it was not.
 *
 * WHY fk_inb ZERO-EXTENDS
 *
 * 'inb %dx, %al' writes AL and leaves the rest of EAX exactly as it found it.
 * The mirror image of the rule above applies on the way back: bits 31:8 of a
 * returned int32_t are the CALLEE's to define, and whatever it leaves there is
 * what the caller gets.  Left alone, a line-status poll such as
 * iand(fk_inb(base + 5), 32) would still work by accident, while a data read
 * such as serial_init's 0xAE loopback probe would compare unequal to 0xAE on a
 * UART that is behaving perfectly.
 *
 * 'xorl %eax, %eax' before the IN defines bits 31:8 as zero, so the byte comes
 * back as 0..255 and never as a negative Fortran integer -- which matters
 * because Fortran has no unsigned type to reinterpret a negative result with,
 * and a caller comparing against 0xAE = 174 would otherwise have to reason
 * about the sign extension of a type its source never mentions.  It also
 * clears RAX bits 63:32 for free, since any 32-bit write to a GPR zeroes the
 * upper half, so a 64-bit reader sees no stale data either.
 *
 * SERIALISATION, AND THE BARRIER THAT IS DELIBERATELY ABSENT
 *
 * IN and OUT are serialising with respect to the DEVICE: the instruction does
 * not retire until its bus transaction completes, so two OUTs issued in program
 * order arrive at the UART in program order, and an IN observes every OUT that
 * precedes it.  That is what lets serial_init's thirteen-step register sequence
 * mean what it reads like.  It comes from the ISA; these wrappers do nothing to
 * create it and could do nothing to weaken it.
 *
 * What they deliberately do NOT do is add a memory barrier or an I/O delay:
 *
 *   * No mfence, no lock prefix.  A barrier is needed when a port access must
 *     be ordered against an ordinary MEMORY access -- a descriptor ring written
 *     to DRAM before a doorbell OUT, say.  The 16550 driver has no such pairing:
 *     every access it makes is to the same device, through the same port space,
 *     from one CPU, and the ISA already orders those against one another.
 *   * No io_wait()/slow_down_io(), the traditional 'OUT a dummy byte to port
 *     0x80' pause.  That exists for pre-PCI ISA parts that cannot accept
 *     back-to-back accesses at CPU speed.  A 16550 is not one of them, QEMU's
 *     model certainly is not, and Linux itself reaches for the delay only
 *     through the separate _p variants of inb/outb, not the plain ones.
 *
 * There is a compiler-ordering point worth stating, because it is why
 * fk_serial.f90 needs no VOLATILE machinery of its own the way the framebuffer
 * renderer does: fk_outb and fk_inb are ORDINARY EXTERNAL CALLS, not inline
 * asm.  gfortran cannot see through them, so it may not reorder them against
 * each other, fold two of them together, or sink an assignment across one --
 * the call sequence in the Fortran source is the sequence the hardware sees.
 * The price is a real call/ret per port access, which is nothing beside the
 * ~1 us that the I/O trap itself costs on emulated hardware.
 *
 * WHAT IS NOT HERE, ON PURPOSE
 *
 * No fk_outw/fk_inw, no fk_outl/fk_inl, no io_wait().  Roadmap 2.1 needs a byte
 * write and a byte read and nothing else, and this project does not write code
 * with no caller: it cannot be tested, no gate covers it, and it is
 * indistinguishable from code that works right up until the day something
 * finally calls it.  The 16- and 32-bit forms are four lines each on the day a
 * device that needs them appears.
 *
 * ASSEMBLE-TIME AND LINK-TIME NOTES
 *
 * Capital .S: this file goes through gcc rather than as, exactly like
 * boot/boot.S, so cpp runs over it first.  Comments are therefore C block
 * syntax, and a '#' in column 1 would be read as a preprocessor directive
 * rather than as a GAS comment.  Nothing here needs a macro today -- unlike
 * boot.S, which cannot assemble at all without PHYS() -- but the extension is
 * kept identical so that one AFLAGS_KERNEL rule ('-m64 -fno-pic -Wall') covers
 * both files without a second recipe.
 *
 * Both routines are leaves.  They touch no stack, so -mno-red-zone has nothing
 * to protect here and no prologue, frame pointer or CFI is needed.  RAX and RDX
 * are both call-clobbered under the psABI, which is precisely why they are the
 * two registers used: nothing has to be saved or restored.
 *
 * EVIDENCE
 *
 * Four things cover this file, and it is worth being precise about which
 * property each one actually establishes:
 *
 *     Makefile.boot            ASRC_KERNEL names boot/io.S, so these two
 *                              functions are in the bootable image rather than
 *                              merely in the tree.
 *     tools/linktest.sh        PASS 0 assembles every boot/*.S into the set of
 *                              symbols "this tree defines", which is what lets
 *                              gate (c) accept fk_serial's undefined fk_outb
 *                              and fk_inb instead of reporting them as orphans.
 *     tools/linkscript-test.sh assembles every boot/*.S, links with linker.ld,
 *                              and asserts by name that fk_outb and fk_inb land
 *                              inside the executable, non-writable .text
 *                              segment -- not in .data, where an object with a
 *                              mis-declared section would put them.
 *     tools/qemu-boot-test.sh  boots the image and greps the captured COM1 log
 *                              for the banner in src/boot/fk_kmain.f90.
 *
 * THE LAST ONE IS THE ONLY ONE THAT EXECUTES ANYTHING HERE.  The first three
 * are statements about a file: it assembles, its symbols resolve, they are
 * placed where the linker script says.  None of them can tell a correct `outb`
 * from one that writes to the wrong port, because none of them runs an
 * instruction.  The banner arriving on COM1 is what proves these four
 * instructions actually drive a 16550 device model -- every byte of it went
 * through fk_outb, and every THRE poll that preceded it through fk_inb.
 *
 * WHAT IS STILL NOT PROVEN, AND ONE OF IT MATTERS.
 *
 *   * No instruction in this file has run on REAL hardware.  QEMU's 16550A is
 *     a faithful model, but it is a model.
 *   * The zero-extension in fk_inb is covered by ONE gate, and only by a
 *     white-box check.  No behavioural test in this tree can see it: the host
 *     differential test supplies its OWN fk_inb in C, so this file is not
 *     linked into it at all, and removing the `xorl` was measured NOT to break
 *     the boot gate -- the mutant boots completely clean, because at
 *     serial_init's probe the stale upper bits of EAX happen to be zero and
 *     0xAE still compares equal.  tools/linkscript-test.sh therefore
 *     disassembles fk_inb and requires that something other than the IN writes
 *     %eax.  That is a spelling assertion, not a semantic one, and it is
 *     labelled as such where it lives.  Recorded as mutation M15 in
 *     docs/HARNESS-VALIDATION-SERIAL.md.
 */

/* ------------------------------------------------------------------------ */
/* fk_outb -- write one byte to an I/O port.  Exported to Fortran.           */
/*                                                                           */
/*     void fk_outb(int32_t port, int32_t value);                            */
/*     port in EDI, value in ESI, nothing returned.                          */
/*                                                                           */
/* DX IS NOT A CONVENIENCE.  OUT has two encodings: an immediate form that    */
/* carries the port in a single byte and can therefore only reach ports       */
/* 0x00..0xFF, and this register form, which is the only one that can address */
/* the full 64 KiB I/O space.  COM1 is 0x3F8.  The register form is mandatory */
/* here, not preferred.                                                       */
/*                                                                           */
/* The two truncations ARE the wrapper.  Bits 31:16 of the port and 31:8 of   */
/* the value are dropped silently, which is exactly what lets the Fortran     */
/* caller carry an unsigned byte such as 0xC7 in a positive int32.  A caller  */
/* that passes 0x1C7 by mistake gets 0xC7 and no diagnostic: a routine that   */
/* returns void has no channel to report on, and adding a status code to      */
/* every register write would cost more in caller complexity -- thirteen      */
/* checks in serial_init alone -- than the class of typo it could catch.      */
/*                                                                           */
/* No #GP is possible from here.  The I/O permission check is skipped         */
/* entirely when CPL <= IOPL, and the boot GDT in boot.S defines exactly one  */
/* code segment, at ring 0.  A ring-3 caller would fault, which is the        */
/* correct outcome and not this file's problem to prevent.                    */
/* ------------------------------------------------------------------------ */

	.section .text, "ax", @progbits
	.code64
	.globl fk_outb
	.type fk_outb, @function
fk_outb:
	/* Port: the low 16 bits, which is all the OUT port operand can hold. */
	movw	%di, %dx

	/*
	 * Value: the low 8 bits.  In 64-bit mode %sil is encodable only with a
	 * REX prefix -- the same ModRM encoding WITHOUT REX means %dh, a
	 * different register whose contents here are undefined.  GAS emits the
	 * prefix; nothing in this file has to ask for it.
	 */
	movb	%sil, %al

	outb	%al, %dx
	ret
	.size fk_outb, . - fk_outb

/* ------------------------------------------------------------------------ */
/* fk_inb -- read one byte from an I/O port.  Exported to Fortran.           */
/*                                                                           */
/*     int32_t fk_inb(int32_t port);                                         */
/*     port in EDI, the byte returned ZERO-EXTENDED in EAX.                  */
/*                                                                           */
/* The XOR is neither dead nor an optimisation; see the file header.  IN      */
/* writes AL only, so without it bits 31:8 of the returned int32_t would be   */
/* whatever the last user of EAX happened to leave behind, and serial_init's  */
/* comparison of the loopback byte against 0xAE would fail on a UART that is  */
/* working perfectly -- a self-test that reports broken hardware because the  */
/* test itself is broken, which is the worst kind of self-test there is.      */
/*                                                                           */
/* It must PRECEDE the IN: zeroing afterwards would erase the byte just read. */
/* 'movzbl %al, %eax' after the IN would be equally correct.  The XOR is      */
/* chosen because it breaks the dependency on EAX's previous value before the */
/* bus transaction rather than after it, and because it puts the reason (bits */
/* 31:8 must be defined by this routine) ahead of the instruction that would  */
/* otherwise look as though it had defined them.                             */
/* ------------------------------------------------------------------------ */

	.section .text, "ax", @progbits
	.code64
	.globl fk_inb
	.type fk_inb, @function
fk_inb:
	/* Port: the low 16 bits, for the same reason as in fk_outb. */
	movw	%di, %dx

	/*
	 * Define bits 31:8 of the result as zero -- and RAX bits 63:32 for free,
	 * since any 32-bit write to a GPR clears the upper half.
	 */
	xorl	%eax, %eax

	inb	%dx, %al
	ret
	.size fk_inb, . - fk_inb

	/*
	 * No executable stack is required.  Without this note GNU ld cannot tell
	 * whether the object wants one and marks the whole image accordingly;
	 * boot.S ends with the same directive for the same reason.
	 */
	.section .note.GNU-stack, "", @progbits
