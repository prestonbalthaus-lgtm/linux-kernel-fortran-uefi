/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Image layout for the Fortran kernel proper (roadmap 0.1).
 *
 * WHAT THIS SCRIPT IS AND IS NOT
 *
 * This lays out the KERNEL, not the EFI application. The agreed boot path is
 * two-stage:
 *
 *   stage 1  BOOTX64.EFI -- a small POSITION-INDEPENDENT PE32+ image. UEFI
 *            loads it at an address of the firmware's choosing, already in
 *            long mode with paging on, so it must be PIC and is linked by
 *            gnu-efi's own script, NOT this one. It queries GOP, takes the
 *            memory map, calls ExitBootServices, maps this kernel, jumps here.
 *   stage 2  this image -- fixed load address, -fno-pic, -mcmodel=kernel.
 *
 * Keeping them separate is what lets every module already verified under
 * KFLAGS link into the kernel UNCHANGED. Building the whole kernel as an EFI
 * application would force -fPIC and invalidate the Phase 1 audit's linkability
 * evidence for all nine modules. Multiboot2 (added later) loads stage 2
 * directly after its own 32-bit trampoline, which is why the layout below is
 * deliberately bootloader-agnostic.
 *
 * WHY THE ADDRESSES ARE WHAT THEY ARE
 *
 * VMA 0xFFFFFFFF80000000 is NOT a preference. Every module in this tree is
 * compiled -mcmodel=kernel, which promises the compiler that all code and data
 * live in the top 2 GiB of the address space so it may use 32-bit
 * sign-extended RIP-relative addressing. Link this image anywhere else and the
 * relocations silently truncate. That flag is load-bearing for the whole tree
 * (Makefile KFLAGS, tools/linktest.sh), so the base follows from it.
 *
 * LMA 0x100000 (1 MiB) is where the image is actually placed in PHYSICAL
 * memory. AT() splits the two: symbols resolve higher-half, program headers
 * load low. A loader can therefore place the image with paging still off and
 * only afterwards install the mapping that makes the virtual addresses valid.
 * 1 MiB avoids the legacy sub-1 MiB hole (IVT, EBDA, VGA, option ROMs), which
 * is not reclaimable memory on any real machine.
 *
 * REQUIRED LINK FLAG: -z max-page-size=0x1000
 *
 * GNU ld defaults to a 2 MiB max page size on x86-64 and pads every PT_LOAD
 * segment to it. With three segments that is up to 6 MiB of zero padding in a
 * ~16 KiB kernel. tools/linkscript-test.sh asserts the image stays small, so
 * dropping the flag fails the gate rather than quietly bloating the image.
 *
 * SECTION ALIGNMENT IS NOT COSMETIC
 *
 * Each of .text/.rodata/.data/.bss starts on a 4 KiB boundary and lands in its
 * own PT_LOAD with distinct flags, so the VMM (roadmap 3.5) can map code
 * read-execute, constants read-only and data read-write-noexec without any
 * section sharing a page with a differently-permissioned neighbour. Sharing a
 * page would force the whole page to the most permissive setting, which is how
 * a kernel ends up with a writable .text.
 */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
/*
 * ENTRY IS THE VIRTUAL SYMBOL, AND THAT IS COUNTER-INTUITIVE ENOUGH TO SPELL
 * OUT -- getting it "right" the obvious way makes the image unbootable.
 *
 * A boot loader jumps to the entry point with paging OFF, so the address it
 * jumps to must be physical. The tempting conclusion is ENTRY(_start_phys).
 * That was tried, and GRUB refuses the image outright:
 *
 *     grub_multiboot_load_elf64:237: entry point isn't in a segment
 *     grub_loader_boot:196: you need to load the kernel first
 *
 * because GRUB does the higher-half translation ITSELF: it looks for the
 * PT_LOAD whose VIRTUAL range [p_vaddr, p_vaddr + p_memsz) contains e_entry
 * and re-expresses it in that segment's physical (p_paddr) terms. A physical
 * e_entry is inside no segment's virtual range, so the search fails and the
 * load is abandoned -- before the Multiboot2 entry-address tag is even
 * consulted, since that tag only overrides the result of a load that succeeded.
 *
 * So e_entry stays virtual and GRUB translates it; boot.S's entry-address tag
 * carries the same instruction's physical address for loaders that use the
 * tag instead. Both routes land on the same byte. _start_phys remains defined
 * below because tools/mb2-check.py asserts exactly that agreement.
 */
ENTRY(_start)

KERNEL_VMA      = 0xFFFFFFFF80000000;
KERNEL_LMA      = 0x0000000000100000;
BOOT_STACK_SIZE = 0x4000;              /* 16 KiB, 16-byte aligned per SysV */

PHDRS
{
    text   PT_LOAD FLAGS(5);   /* R-X */
    rodata PT_LOAD FLAGS(4);   /* R-- */
    data   PT_LOAD FLAGS(6);   /* RW- */
}

SECTIONS
{
    . = KERNEL_VMA + KERNEL_LMA;
    __kernel_start = .;

    /*
     * The Multiboot2 header (roadmap 1.2), FIRST in the image.
     *
     * The specification lets a boot loader give up after scanning 32 KiB, and
     * requires 8-byte alignment. Being the first output section puts the
     * header at file offset 0x1000 (the ELF and program headers are all that
     * precede it), which satisfies both with three orders of magnitude to
     * spare -- and, unlike a "it happens to be early" arrangement, it stays
     * true as .text grows.
     *
     * KEEP() is not decoration: nothing in the image references this section,
     * so --gc-sections would discard it as garbage by every ordinary
     * heuristic, and GRUB would then report "no multiboot header found" on an
     * image that builds cleanly.
     *
     * .multiboot is accepted as well as .multiboot_header so that an object
     * written against the older name still lands here rather than in an
     * orphan section at an address the linker picks by itself.
     */
    .multiboot_header ALIGN(8) : AT(ADDR(.multiboot_header) - KERNEL_VMA)
    {
        KEEP(*(.multiboot_header))
        KEEP(*(.multiboot_header.*))
        KEEP(*(.multiboot))
        KEEP(*(.multiboot.*))
    } :text
    __multiboot_end = .;

    .text ALIGN(4096) : AT(ADDR(.text) - KERNEL_VMA)
    {
        __text_start = .;
        *(.text.boot)          /* entry stub first, if it asks to be */
        *(.text .text.*)
        __text_end = .;
    } :text

    .rodata ALIGN(4096) : AT(ADDR(.rodata) - KERNEL_VMA)
    {
        __rodata_start = .;
        *(.rodata .rodata.*)   /* the 4 KiB 8x16 font lands here */
        __rodata_end = .;
    } :rodata

    .data ALIGN(4096) : AT(ADDR(.data) - KERNEL_VMA)
    {
        __data_start = .;
        *(.data .data.*)
        __data_end = .;
    } :data

    /*
     * NOLOAD: .bss occupies no space in the file. Nothing zeroes it for us --
     * the entry stub must clear __bss_start..__bss_end before calling any
     * Fortran, because module variables (fb_ready, fb_width, the framebuffer
     * pointer) live here and are assumed zero on entry. That clear is roadmap
     * 1.3's memset; these two symbols are the contract it works against.
     */
    .bss ALIGN(4096) (NOLOAD) : AT(ADDR(.bss) - KERNEL_VMA)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)

        . = ALIGN(16);
        __boot_stack_bottom = .;
        . += BOOT_STACK_SIZE;
        __boot_stack_top = .;      /* stack grows DOWN from here */

        /*
         * boot.S clears this region with `rep stosq`, 8 bytes at a time, and
         * computes the count as (__bss_end - __bss_start) >> 3. A size that
         * is not a multiple of 8 would leave the last 1..7 bytes UNCLEARED --
         * a Fortran module variable holding boot-time garbage, which is the
         * kind of defect that reproduces once a week. The ASSERT at the end
         * of this file makes the arithmetic exact rather than lucky.
         */
        . = ALIGN(8);
        __bss_end = .;
    } :data

    /*
     * BOOT PAGE TABLES -- deliberately NOT in .bss.
     *
     * boot.S zeroes [__bss_start, __bss_end) in 64-bit mode, which is AFTER
     * CR0.PG has gone high and the CPU is walking these tables on every
     * instruction fetch. Had they been left in .bss (where an entry stub
     * normally puts them) that clear would erase the live PML4 hierarchy and
     * the very next fetch would fault, double-fault and triple-fault -- a
     * silent reboot with no diagnostic, and no obvious connection to the
     * memset that caused it.
     *
     * Giving them their own NOLOAD section is what makes the bss clear and
     * the page tables independent facts instead of an ordering constraint
     * somebody has to remember. NOLOAD keeps all 16 KiB out of the file; the
     * stub writes every entry it uses and zeroes the three tables it only
     * partially fills.
     */
    .bootpt ALIGN(4096) (NOLOAD) : AT(ADDR(.bootpt) - KERNEL_VMA)
    {
        __bootpt_start = .;
        KEEP(*(.bootpt))
        KEEP(*(.bootpt.*))
        __bootpt_end = .;
    } :data

    . = ALIGN(4096);
    __kernel_end = .;

    /* Physical extent, for the PMM (roadmap 3.4) to mark these pages in use. */
    __kernel_phys_start = __kernel_start - KERNEL_VMA;
    __kernel_phys_end   = __kernel_end   - KERNEL_VMA;

    /*
     * Physical alias of the entry point, for ENTRY() above. Defined here
     * rather than at the top because _start is not known until the input
     * sections have been placed.
     */
    _start_phys = _start - KERNEL_VMA;

    /DISCARD/ :
    {
        *(.comment)
        *(.note .note.*)          /* .note.GNU-stack, .note.gnu.property */
        *(.eh_frame .eh_frame_hdr)
        *(.gnu.hash)
        *(.gnu_debuglink)
        *(.interp)
    }
}

/*
 * Gates. A linker script that silently produced a wrong layout would be
 * discovered on hardware, by a machine that reboots. These fail the build.
 */
ASSERT(__kernel_start == 0xFFFFFFFF80100000,
       "kernel base moved: -mcmodel=kernel requires the top 2 GiB")
ASSERT(__multiboot_end - __kernel_start <= 32768,
       "Multiboot2 header must lie within the first 32 KiB of the image")
ASSERT((__text_start   & 0xFFF) == 0, ".text is not 4 KiB aligned")
ASSERT((__rodata_start & 0xFFF) == 0, ".rodata is not 4 KiB aligned")
ASSERT((__data_start   & 0xFFF) == 0, ".data is not 4 KiB aligned")
ASSERT((__bss_start    & 0xFFF) == 0, ".bss is not 4 KiB aligned")
ASSERT(__boot_stack_top - __boot_stack_bottom == BOOT_STACK_SIZE,
       "boot stack was resized without updating BOOT_STACK_SIZE")
ASSERT((__bss_end - __bss_start) % 8 == 0,
       "bss size must be a multiple of 8: boot.S clears it with rep stosq")
ASSERT((__bootpt_start & 0xFFF) == 0,
       "boot page tables must be 4 KiB aligned -- CR3 and every table it walks")
ASSERT(__bootpt_start >= __bss_end,
       "boot page tables are inside the region boot.S zeroes: that clear would \
erase the live PML4 and triple-fault on the next instruction fetch")
/*
 * DEFINED() guards keep this script usable for a link that has no boot stub in
 * it (tools/linkscript-test.sh links the Fortran modules alone to check the
 * layout in isolation). When boot.S IS present, these are the two properties
 * the Multiboot2 specification actually cares about.
 */
ASSERT(!DEFINED(mb2_header_start) || mb2_header_start == __kernel_start,
       "the Multiboot2 header must be at the very beginning of the image")
ASSERT(!DEFINED(mb2_header_start) || (mb2_header_start & 7) == 0,
       "the Multiboot2 header must be 8-byte aligned")
