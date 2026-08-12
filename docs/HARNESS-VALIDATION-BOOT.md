# Does the boot gate actually catch a kernel that does not boot?

Same question `HARNESS-VALIDATION.md` and `HARNESS-VALIDATION-PHASE2.md` asked of the
Phase 1 and Phase 2 suites, asked of roadmap 1.2 — and it needs asking harder here,
because a boot failure has almost no observable surface. A kernel that triple-faults on
its first instruction and a kernel that reaches Fortran correctly look identical from
outside the VM: both produce a machine that sits there doing nothing.

There is no console to print to at this milestone. The UEFI target has no 0xB8000 text
mode, the serial driver is roadmap 2.1, and the framebuffer handover is 2.2. So the
proof is a **four-word sentinel** that `src/boot/fk_kmain.f90` writes into `.data` at a
link-time-fixed address, read back out of the *running guest's physical memory* over QMP:

| word | value | what it proves |
|---|---|---|
| 0 | `0x4B424F54` "KBOT" | `kernel_main` executed at all |
| 1 | `0x36D76289` | GRUB's Multiboot2 magic survived the whole ladder into a Fortran argument |
| 2 | MBI pointer, non-zero | the second SysV argument arrived too |
| 3 | `TAG xor magic` = `0x7D952DDD` | **computed by Fortran at run time** from a value it never sees at compile time |

Word 3 is the one that makes this a proof rather than a plausibility argument. Words 0–2
could in principle be produced by code that stores constants; word 3 could not.

## The gate stack, and what each layer can and cannot see

| Gate | Runs on | Catches |
|---|---|---|
| `linker.ld` ASSERTs | link | header not at the image base, misaligned sections, page tables inside the `.bss` clear, `.bss` size not a multiple of 8 |
| `grub2-file --is-x86-multiboot2` | file | a malformed or missing Multiboot2 header |
| `tools/mb2-check.py` | file | everything about whether the image can be **entered** |
| `tools/linkscript-test.sh` | link | the layout, `KERNEL_VMA` agreement between `linker.ld` and `boot.S`, page-table placement |
| `tools/qemu-boot-test.sh` | **running CPU** | a forgotten `PHYS()`, a bad GDT, a misaligned stack at the call site — everything above is static |

## Mutations: can the header gate fail?

`tools/mb2-selftest.sh` injects each defect alone into a copy of the real image and
requires the gate to reject it. It also records **which** checker caught it.

| Injected defect | `grub2-file` | `mb2-check.py` |
|---|---|---|
| one bit flipped in the header checksum | rejects | rejects |
| header magic zeroed | rejects | rejects |
| architecture field set to 4 (MIPS) | rejects | rejects |
| tag list terminator is type 9, not type 0 | **accepts** | rejects |
| entry address tag removed (type 3 → 1) | **accepts** | rejects |
| `e_entry` replaced by its physical alias | **accepts** | rejects |
| entry tag and `e_entry` disagree by 0x1000 | **accepts** | rejects |
| `e_entry` points into a segment's zero-filled tail | **accepts** | rejects |

Five of eight defects are accepted by `grub2-file`, and at least two of those five produce
a kernel that cannot boot. This is not a criticism of the tool: it validates a *header*,
and in those five images the header is valid. It is the reason
`grub-file --is-x86-multiboot2 → exit 0` is recorded here as a **necessary and not
sufficient** condition, and why the QEMU gate exists.

The assertion logic itself is self-tested without any VM: `tools/qemu-boot-test.sh
--selftest` proves the sentinel contract accepts a correct record and rejects eight wrong
ones — including the interesting case where every static word is right but word 3 was
derived from the *wrong* magic, which is exactly what a kernel storing constants would
produce. `--smoke` proves the QMP/pmemsave plumbing works against a kernel-less guest and
that the assertion refuses it.

## The defect this gate actually caught

The first boot attempt failed with the sentinel still reading its `.data` initialiser
`0x11111111` — image loaded, `kernel_main` never called, and no triple fault. Reading the
guest's VGA text buffer over the same QMP channel produced GRUB's own words:

```
error: ../../grub-core/loader/multiboot_elfxx.c:grub_multiboot_load_elf64:237:
       entry point isn't in a segment.
error: ../../grub-core/commands/boot.c:grub_loader_boot:196:
       you need to load the kernel first.
```

**Root cause.** GRUB's ELF64 loader resolves the entry point by finding the `PT_LOAD`
whose *virtual* range `[p_vaddr, p_vaddr + p_memsz)` contains `e_entry`, then re-expresses
that address in the same segment's physical (`p_paddr`) terms. It does the higher-half
translation itself. `ENTRY(_start_phys)` — the obvious reading of "the loader jumps with
paging off, so hand it a physical address" — puts a value in `e_entry` that is inside no
segment's virtual range, so the search fails and the load is abandoned *before* the
Multiboot2 entry-address tag is ever consulted.

**Fix.** `ENTRY(_start)` (virtual, GRUB translates it) *and* an entry-address tag carrying
the physical address, for loaders that use the tag instead. `mb2-check.py` now encodes
GRUB's rule verbatim and asserts the two agree, so this defect is caught statically, in
under a second, instead of by a 45-second VM timeout.

Note what the file-level gates said about that image: `grub2-file --is-x86-multiboot2`
exited **0**.

## What is still NOT proven

* **UEFI.** The harness boots the BIOS/GRUB path. `-bios OVMF.fd` (roadmap 0.3) is not
  wired up, and the EFI stage-1 described in `linker.ld` does not exist. Nothing here is
  evidence about the Minisforum's actual firmware path.
* **Real hardware.** KVM on one host CPU model.
* **The framebuffer.** No framebuffer is requested (roadmap 2.2), so the renderer has
  still never put a pixel on a screen.
* **`-smp 6` is a resource allocation, not a claim.** Only CPU 0 is ever brought up;
  the other five are parked by firmware. SMP bring-up is roadmap 4.1.
* **The identity map is still live** after the higher-half jump, because GDTR holds a
  physical base. Unmapping `PML4[0]` is roadmap 3.5 work and must reload GDTR first.
