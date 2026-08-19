# Fortran Kernel

A 64-bit x86 operating system kernel written in modern Fortran.

It is not Linux and not a fork of Linux. It is an original kernel whose library
and driver code is *translated* from Linux 7.1.8 C sources into Fortran
(90/2003/2008/2018) and then diff-tested against those originals, which act as
oracles. Assembly is used only for the handful of things Fortran cannot express:
the long-mode boot stub, port I/O, `cli`/`hlt`, the interrupt stubs, and the
descriptor/control-register instructions.

**On the name:** the kernel boots today through **Multiboot2 / GRUB**, and the
same hybrid ISO comes up on both firmwares — SeaBIOS, and OVMF since roadmap
0.3. GRUB is the EFI application; there is no `BOOTX64.EFI` of our own.

## What works today

- Multiboot2 boot into 64-bit long mode, higher-half at `0xFFFFFFFF80100000`
- 16550 UART serial driver on COM1
- GDT, TSS with an IST emergency stack, and an IDT with a Fortran panic handler
  that prints a full register dump
- 8259 PIC remapped and masked; 8254 PIT at 100 Hz; interrupts that return
- Physical memory manager — bitmap allocator over the Multiboot2 memory map
  (tag 6), or the UEFI GetMemoryMap array (tag 17) on the UEFI path
- Virtual memory manager — 4-level paging, per-section W^X + NX, a linear map
  of physical RAM, and a guard page under the boot stack
- Kernel heap — implicit free list with boundary tags, coalescing both ways
- Preemptive round-robin scheduler running two kernel threads off the timer
- GOP framebuffer, 8x16 bitmap font, software renderer, and a scrolling console,
  on both firmware paths
- Local APIC and I/O APIC — IRQ0 routed through the IOAPIC to GSI 2 with both
  8259s masked, and EOI at the LAPIC
- ACPI: RSDP, RSDT/XSDT, the MADT, and the MCFG that gives PCIe its ECAM window
- PCIe enumeration through ECAM, configuration reads and writes, the capability
  walk, and MSI-X discovery
- An xHCI controller brought up from reset: command and event rings in
  physically contiguous memory, a NO-OP command executed, and its MSI-X
  interrupt delivered
- `memset` / `memcpy` / `memmove` / `memcmp` and 7 integer-math routines,
  all translated from Linux and byte-compared against it

## Not done yet

A USB keyboard driver, NVMe, a VFS, syscalls, an ELF loader, and ring 3.
See `roadmap.md` for the full plan.

## Building

Everything compiles inside a rootless Podman container so the host toolchain and
host kernel are never touched. Build the image once:

```sh
podman build -t fortran-kernel-dev:f44 -f tools/Containerfile .
```

Then use the wrapper, which runs `make` inside that container:

```sh
./tools/run.sh kernel     # build build/boot/kernel.elf
./tools/run.sh iso        # build a bootable GRUB rescue ISO
./tools/run.sh bootgate   # build it and run every static gate
```

To actually boot it, from the host (needs QEMU):

```sh
tools/qemu-boot-test.sh                    # SeaBIOS, q35, headless
FK_FIRMWARE=uefi tools/qemu-boot-test.sh   # the same ISO through OVMF
FK_MACHINE=pc tools/qemu-boot-test.sh      # the board with no ECAM window
```

It boots the ISO headless and asserts guest state over QMP: the framebuffer's
pixels against the kernel's own font table, the PCIe bus against QEMU's `info
pci`, the DMA run at its physical base, the xHCI's rings where the controller
wrote them, and the timer still ticking between two reads.

## Testing

The differential test suite compares each Fortran module against the C function
it was translated from. It needs the Linux 7.1.8 source tree unpacked at
`vendor/linux-7.1.8/` (gitignored, and not required to build the kernel itself):

```sh
./tools/run.sh test       # run every differential test
./tools/run.sh audit      # tests + compliance, link and layout gates
```

## Layout

| Path | Contents |
|---|---|
| `src/` | Fortran kernel sources — boot, cpu, mm, lib, drivers |
| `boot/` | The assembly that Fortran cannot replace |
| `tests/` | C test drivers and the headers they shim |
| `mk/` | Per-module test fragments and the shared kernel flag set |
| `tools/` | Build wrapper, container definition, and verification gates |
| `docs/` | Audit and harness-validation notes |
| `linker.ld` | Kernel memory layout |
| `Makefile` | Differential test harness |
| `Makefile.boot` | The bootable kernel image |
| `roadmap.md` | Detailed status of every milestone |

## License

GPL-2.0, per the SPDX headers on each file.
