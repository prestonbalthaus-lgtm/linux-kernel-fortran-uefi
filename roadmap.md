Here is the complete, start-to-finish roadmap formatted specifically for GitHub.

You can drop this directly into a ROADMAP.md or README.md file in your repository. It is written with explicit markdown checkboxes ([ ]) and clear validation criteria so your AI agents can read it, update it with [x], and systematically prove their progress without hallucinating skips.
🗺️ Project Fortran-Kernel: The Minisforum Roadmap

Objective: Engineer a 64-bit, UEFI-booting, bare-metal OS kernel written in modern Fortran, capable of daily-driving a Minisforum mini PC and booting a BusyBox user-space shell.

Rules of Engagement for AI Agents:

    You may not check a box until the validation criteria are met.

    Code must compile freestanding (-nostdlib, -fno-leading-underscore).

    Standard libgfortran I/O is strictly banned.

    All memory and hardware interaction must use iso_c_binding.

🏗️ Phase 0: Project Initialization & Toolchain

Before any Fortran is written, the autonomous build environment must be established.

    [ ] 0.1 Create Custom Linker Script (linker.ld)

        Validation: Script properly aligns .text, .data, and .bss sections for a 64-bit ELF kernel.

    [ ] 0.2 Write the Root Makefile

        Validation: Makefile successfully runs gfortran -ffreestanding and links with ld.

    [ ] 0.3 Configure QEMU Test Harness

        Validation: A script (run.sh) exists that packages the kernel into an ISO and launches qemu-system-x86_64 -m 24G -smp 6 -bios OVMF.fd.

⚙️ Phase 1: The Boot Layer & Bare-Metal Runtime

Bypassing Fortran's reliance on the OS and successfully handing control from UEFI to the Fortran entry point.

    [x] 1.1 The Core Library Translation (Completed)

        Validation: String manipulation and math modules exist without libgfortran.

    [ ] 1.2 Multiboot2 / EFI Assembly Stub

        Validation: Assembly code (boot.S) successfully transitions CPU to 64-bit Long Mode and jumps to kernel_main().

    [ ] 1.3 Custom Fortran Runtime Stubs

        Validation: Missing compiler intrinsics (like memcpy, memset) are implemented in Fortran using iso_c_binding to prevent linker failures.

    [ ] 1.4 The Kernel Panic Handler

        Validation: A Fortran subroutine exists to halt the CPU (hlt) safely when an unrecoverable error occurs.

🖥️ Phase 2: Modern Display & Debugging

The Minisforum has no legacy VGA text mode. The kernel must render its own pixels via UEFI GOP.

    [ ] 2.1 UART Serial Driver (Headless Debugging)

        Validation: Kernel can write strings to COM1 (0x3F8) using assembly outb wrappers. QEMU serial console outputs text.

    [ ] 2.2 UEFI GOP Framebuffer Mapping

        Validation: Multiboot2 header successfully requests the framebuffer; Fortran pointer maps to the physical video memory address.

    [ ] 2.3 Bitmap Font System

        Validation: An 8x16 hex bitmap font array is hardcoded into a Fortran module.

    [ ] 2.4 The Software Renderer

        Validation: vga_print_string() successfully iterates over the font array and plots individual colored pixels to the screen.

🧠 Phase 3: Core CPU & Memory Management

The most critical mathematical and structural phase. Setting up the brain of the OS.

    [ ] 3.1 Global Descriptor Table (GDT)

        Validation: Flat memory model is established in Fortran structures and loaded via lgdt.

    [ ] 3.2 Interrupt Descriptor Table (IDT)

        Validation: Hardware and CPU exceptions (like Page Faults) trigger specific Fortran subroutines.

    [ ] 3.3 Advanced Programmable Interrupt Controller (APIC)

        Validation: Legacy 8259 PIC is disabled. Local APIC is mapped and active.

    [ ] 3.4 Physical Memory Manager (PMM)

        Validation: Fortran parses the UEFI memory map and tracks free/used memory pages (e.g., via a bitmap).

    [ ] 3.5 Virtual Memory Manager (VMM)

        Validation: 4-level Page Tables (PML4) are constructed in Fortran, mapping virtual addresses to physical addresses.

🔌 Phase 4: The Bus & Subsystems

Discovering what hardware actually exists on the Minisforum motherboard.

    [ ] 4.1 ACPI & MADT Parsing

        Validation: Fortran parses ACPI tables to find all CPU cores and APIC addresses.

    [ ] 4.2 PCIe Bus Enumeration

        Validation: Kernel recursively scans the PCIe bus and prints a list of all connected devices (Vendor IDs / Device IDs) to the GOP display.

🛠️ Phase 5: Modern Drivers (The Crucible)

Writing complex Fortran state machines to talk to modern Minisforum silicon.

    [ ] 5.1 xHCI Controller (USB 3.0)

        Validation: Kernel initializes the xHCI controller found on the PCIe bus and establishes Ring Buffers in physical memory.

    [ ] 5.2 USB HID Keyboard Driver

        Validation: Physical keystrokes on a USB keyboard generate APIC interrupts, which Fortran translates to ASCII characters on the screen.

    [ ] 5.3 NVMe Storage Controller

        Validation: Kernel identifies the NVMe drive, establishes Submission/Completion Queues, and successfully reads Sector 0 into a Fortran array.

🌉 Phase 6: The User-Space Bridge (Distro Maker)

Preparing the kernel to host external C applications.

    [ ] 6.1 The Virtual File System (VFS)

        Validation: A Fortran tree structure can abstract drives into a standard / directory hierarchy.

    [ ] 6.2 Basic File System Driver (e.g., ext2 or FAT32)

        Validation: Kernel can read the directory structure of the NVMe drive and locate a specific file.

    [ ] 6.3 Syscall ABI Trap

        Validation: Assembly syscall instruction routes to a Fortran handler (sys_write, sys_read, sys_exit).

    [ ] 6.4 ELF Binary Loader

        Validation: Fortran reads an ELF executable file, maps its memory segments into a new Virtual Memory space, and prepares the CPU instruction pointer.

🚀 Phase 7: User-Space Execution (Victory Lap)

The final test to prove it is a real operating system.

    [ ] 7.1 Ring 3 Privilege Drop

        Validation: CPU successfully transitions from Ring 0 (Kernel) to Ring 3 (User-Space) without causing a General Protection Fault.

    [ ] 7.2 Boot /bin/init (BusyBox)

        Validation: The kernel loads a statically compiled BusyBox ELF binary.

    [ ] 7.3 Interactive Shell

        Validation: BusyBox requests input. The Fortran xHCI driver reads the keyboard, the Syscall ABI passes it to BusyBox, and BusyBox prints the output via the GOP renderer.
