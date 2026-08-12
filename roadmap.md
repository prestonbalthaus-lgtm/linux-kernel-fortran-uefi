
## 🏗️ Phase 0: Project Initialization & Toolchain

Before any Fortran is written, the autonomous build environment must be established.

  *  [x] 0.1 Create Custom Linker Script (linker.ld)

        Validation: Script properly aligns .text, .data, and .bss sections for a 64-bit ELF kernel.

        DONE: `linker.ld`. Proven, not asserted -- `tools/linkscript-test.sh` links the
        REAL nine modules under KFLAGS and checks 25 properties (`make linkscript`, also
        part of `make audit`). .text/.rodata/.data/.bss each start on a 4 KiB boundary in
        their own PT_LOAD (RE / R / RW), so the VMM (3.5) can set per-section permissions
        without two sections sharing a page. VMA 0xFFFFFFFF80100000 is forced by
        -mcmodel=kernel; LMA 0x100000 via AT(). Exports `__bss_start`/`__bss_end` for
        1.3's zeroing, a 16 KiB boot stack, and `__kernel_phys_start`/`_end` for 3.4's
        PMM. 9 injected layout defects were all rejected by the gate.

  *  [ ] 0.2 Write the Root Makefile

        Validation: Makefile successfully runs gfortran -ffreestanding and links with ld.

        SUBSTANTIALLY DONE by 1.2, not ticked because the box is the Lead Architect's
        to close. `Makefile.boot` builds and links a real kernel image
        (`./tools/run.sh kernel`, or `iso`, `bootgate`), separate from ./Makefile so the
        Phase 1 differential harness cannot be disturbed by boot work. It passes
        `-z max-page-size=0x1000`, without which GNU ld pads every PT_LOAD to 2 MiB and
        the 19 KiB kernel becomes multi-megabyte.

        One deviation from the wording: `-ffreestanding` is NOT passed. It is a C-only
        flag; f951 does not accept it. The property it stands for -- no libc, no
        libgfortran -- is enforced directly instead, by `make symcheck-boot` and
        tools/linktest.sh, which fail on any undefined symbol this tree does not itself
        define. KFLAGS now lives in `mk/kflags.mk` so the harness, the kernel build and
        the layout gate cannot drift apart.

  *  [ ] 0.3 Configure QEMU Test Harness

        Validation: A script (run.sh) exists that packages the kernel into an ISO and launches qemu-system-x86_64 -m 24G -smp 6 -bios OVMF.fd.

        HALF DONE by 1.2. `tools/qemu-boot-test.sh` packages the kernel into a GRUB
        rescue ISO and launches `qemu-system-x86_64 -smp 6 -m 24G` headless, then asserts
        the boot in guest physical memory over QMP (see 1.2). The name collision was
        heeded: `tools/run.sh` is untouched and still the podman wrapper.

        The MISSING half is `-bios OVMF.fd`. Today's harness boots the BIOS/GRUB path,
        which is what Multiboot2 is; the UEFI path that the Minisforum actually uses is a
        different first stage (linker.ld's header describes it) and is not exercised by
        anything yet. Do not read the current PASS as evidence about UEFI.

## ⚙️ Phase 1: The Boot Layer & Bare-Metal Runtime

Bypassing Fortran's reliance on the OS and successfully handing control from UEFI to the Fortran entry point.

  *  [x] 1.1 The Core Library Translation (Completed)

        Validation: String manipulation and math modules exist without libgfortran.

        CAUTION -- THIS BOX IS OVER-TICKED. Only the MATH half was delivered:
        `src/lib/math/` has 7 modules plus `src/lib/fk_bcd.f90`. There are ZERO string
        handlers -- no strlen, strcpy, memcmp, memcpy. `docs/AUDIT-PHASE1.md` flagged this
        already: "Phase 1 delivered no string handlers ... any Phase 2 planning that
        assumes lib/string.c is already translated is working from a wrong inventory."
        Anything downstream needing string ops (the ELF loader at 6.4, VFS paths at 6.1)
        must translate lib/string.c first. Note 1.3 below needs memcpy/memset anyway, so
        that is where the debt gets paid.

  *  [x] 1.2 Multiboot2 / EFI Assembly Stub  (Multiboot2 half only)

        Validation: Assembly code (boot.S) successfully transitions CPU to 64-bit Long Mode and jumps to kernel_main().

        DONE for the MULTIBOOT2 path, and proven on a running CPU rather than asserted:
        `tools/qemu-boot-test.sh` boots the ISO headless (-smp 6 -m 24G) and reads the
        four-word sentinel back out of guest physical memory over QMP. Word 3 is
        TAG xor magic, computed by Fortran at run time from the value GRUB left in EAX,
        so a pass is evidence that LIVE loader data crossed the asm -> Fortran ABI --
        not merely that the machine failed to crash.

        `grub2-file --is-x86-multiboot2` exits 0 (Fedora prefixes the GRUB binaries with
        "grub2-"; it is the tool the spec calls grub-file). That gate is necessary and
        NOT sufficient: tools/mb2-selftest.sh injects seven defects and five of them --
        including a boot-fatal entry point -- are accepted by grub2-file and caught only
        by tools/mb2-check.py.

        THE ONE THAT COST A BOOT: e_entry must stay VIRTUAL. GRUB's ELF64 loader finds
        the PT_LOAD whose [p_vaddr, p_vaddr+p_memsz) contains e_entry and translates it
        into that segment's physical terms itself. ENTRY(_start_phys) -- the obvious
        "the loader jumps with paging off, so give it a physical address" reading -- is
        refused with "entry point isn't in a segment", BEFORE the Multiboot2 entry-address
        tag is consulted. Both are now emitted and must agree; the gate asserts it.

        The EFI half of this box is NOT done. There is no BOOTX64.EFI, and the framebuffer
        tag is deliberately absent (see 2.2).

  *  [ ] 1.2b Long-mode entry hardening (deferred, not started)

        The identity map built by boot.S covers the low 1 GiB only, and PML4[0] is left
        mapped after the higher-half jump because GDTR still holds a physical base. Both
        are 3.5's to clean up: unmapping the identity window requires reloading GDTR with
        the higher-half address first.

  *  [ ] 1.3 Custom Fortran Runtime Stubs

        Validation: Missing compiler intrinsics (like memcpy, memset) are implemented in Fortran using iso_c_binding to prevent linker failures.

  *  [ ] 1.4 The Kernel Panic Handler

        Validation: A Fortran subroutine exists to halt the CPU (hlt) safely when an unrecoverable error occurs.

## 🖥️ Phase 2: Modern Display & Debugging

The Minisforum has no legacy VGA text mode. The kernel must render its own pixels via UEFI GOP.

  *  [ ] 2.1 UART Serial Driver (Headless Debugging)

        Validation: Kernel can write strings to COM1 (0x3F8) using assembly outb wrappers. QEMU serial console outputs text.

  *  [ ] 2.2 UEFI GOP Framebuffer Mapping

        Validation: Multiboot2 header successfully requests the framebuffer; Fortran pointer maps to the physical video memory address.

        STILL HALF DONE. The Fortran side is finished and tested (`vga_init_framebuffer`
        maps the pointer via c_f_pointer and validates the geometry). The Multiboot2
        header now EXISTS (1.2) but deliberately does NOT request a framebuffer: tag
        type 5 switches GRUB into a graphics mode, and the address it then reports is
        routinely outside the 1 GiB the boot stub identity-maps. boot/boot.S carries the
        exact tag to add and the mapping work that must land with it.

        HAZARD FOR WHOEVER DOES 1.2: the GOP framebuffer is a PCI BAR that on modern
        hardware sits ABOVE 4 GiB, while a bootloader identity map usually covers only the
        low 1-4 GiB. Passing the firmware's reported address straight to
        `vga_init_framebuffer` will page-fault with no IDT (3.2) installed -> double ->
        triple fault -> silent reboot, which reads as "the kernel crashed" but is purely
        an unmapped address. The stub must map the framebuffer range explicitly, and after
        3.5 the VMM must hand over the VIRTUAL address with write-combining attributes.

  *  [x] 2.3 Bitmap Font System

        Validation: An 8x16 hex bitmap font array is hardcoded into a Fortran module.

        DONE, and since moved: the table lives in its own module,
        `src/drivers/video/fk_font_8x16.f90` (`FONT_8X16`, 4096 bytes in .rodata), with
        `vga_font_row()` as its only interface. The renderer USEs it and carries no glyph
        data at all. The accessor is not decoration: a Fortran PARAMETER array is
        materialised into the .rodata of every object that indexes it, so a renderer that
        indexed the array directly would put a SECOND 4 KiB copy in the kernel image.
        Verified: one `MOD_font_8x16` symbol, in .rodata, `nm` on the renderer object
        shows only an undefined `vga_font_row`.

        Previously: `src/drivers/video/fk_gop_renderer.f90`, `FONT_8X16`, 4096 bytes in .rodata.
        Generated from the kernel's own `lib/fonts/font_8x16.c` by `tools/gen-font-8x16.py`
        (re-running it yields a zero diff), and all 4096 bytes are diffed against the
        compiled `font_vga_8x16` oracle by the test suite. A single flipped bit is caught.

  *  [ ] 2.4 The Software Renderer

        Validation: vga_print_string() successfully iterates over the font array and plots individual colored pixels to the screen.

        CODE COMPLETE, not ticked: `vga_print_string`/`vga_print_char`/`vga_plot_pixel` are
        written and verified byte-exact against a reference model on a simulated
        framebuffer with pitch > width (248,853 checks, 0 mismatches, holds under the real
        kernel flag set). But "to the screen" has never happened -- no boot path exists.
        Tick this after QEMU (0.3) shows the pixels.

## 🧠 Phase 3: Core CPU & Memory Management

The most critical mathematical and structural phase. Setting up the brain of the OS.

  *  [ ] 3.1 Global Descriptor Table (GDT)

        Validation: Flat memory model is established in Fortran structures and loaded via lgdt.

  *  [ ] 3.2 Interrupt Descriptor Table (IDT)

        Validation: Hardware and CPU exceptions (like Page Faults) trigger specific Fortran subroutines.

  *  [ ] 3.3 Advanced Programmable Interrupt Controller (APIC)

        Validation: Legacy 8259 PIC is disabled. Local APIC is mapped and active.

  *  [ ] 3.4 Physical Memory Manager (PMM)

        Validation: Fortran parses the UEFI memory map and tracks free/used memory pages (e.g., via a bitmap).

  *  [ ] 3.5 Virtual Memory Manager (VMM)

        Validation: 4-level Page Tables (PML4) are constructed in Fortran, mapping virtual addresses to physical addresses.

## 🔌 Phase 4: The Bus & Subsystems

Discovering what hardware actually exists on the Minisforum motherboard.

   * [ ] 4.1 ACPI & MADT Parsing

        Validation: Fortran parses ACPI tables to find all CPU cores and APIC addresses.

   * [ ] 4.2 PCIe Bus Enumeration

        Validation: Kernel recursively scans the PCIe bus and prints a list of all connected devices (Vendor IDs / Device IDs) to the GOP display.

## 🛠️ Phase 5: Modern Drivers (The Crucible)

Writing complex Fortran state machines to talk to modern Minisforum silicon.

   * [ ] 5.1 xHCI Controller (USB 3.0)

        Validation: Kernel initializes the xHCI controller found on the PCIe bus and establishes Ring Buffers in physical memory.

   * [ ] 5.2 USB HID Keyboard Driver

        Validation: Physical keystrokes on a USB keyboard generate APIC interrupts, which Fortran translates to ASCII characters on the screen.

   * [ ] 5.3 NVMe Storage Controller

        Validation: Kernel identifies the NVMe drive, establishes Submission/Completion Queues, and successfully reads Sector 0 into a Fortran array.

## 🌉 Phase 6: The User-Space Bridge (Distro Maker)

Preparing the kernel to host external C applications.

   * [ ] 6.1 The Virtual File System (VFS)

        Validation: A Fortran tree structure can abstract drives into a standard / directory hierarchy.

   * [ ] 6.2 Basic File System Driver (e.g., ext2 or FAT32)

        Validation: Kernel can read the directory structure of the NVMe drive and locate a specific file.

   * [ ] 6.3 Syscall ABI Trap

        Validation: Assembly syscall instruction routes to a Fortran handler (sys_write, sys_read, sys_exit).

   * [ ] 6.4 ELF Binary Loader

        Validation: Fortran reads an ELF executable file, maps its memory segments into a new Virtual Memory space, and prepares the CPU instruction pointer.

## 🚀 Phase 7: User-Space Execution (Victory Lap)

The final test to prove it is a real operating system.

   * [ ] 7.1 Ring 3 Privilege Drop

        Validation: CPU successfully transitions from Ring 0 (Kernel) to Ring 3 (User-Space) without causing a General Protection Fault.

   * [ ] 7.2 Boot /bin/init (BusyBox)

        Validation: The kernel loads a statically compiled BusyBox ELF binary.

   * [ ] 7.3 Interactive Shell

        Validation: BusyBox requests input. The Fortran xHCI driver reads the keyboard, the Syscall ABI passes it to BusyBox, and BusyBox prints the output via the GOP renderer.
