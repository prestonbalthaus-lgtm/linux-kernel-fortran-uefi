
# PROPOSED NEXT MILESTONE -- AWAITING LEAD ARCHITECT APPROVAL

Updated 2026-08-18. **4.1, 3.x, 3.3 and 4.2 have LANDED, are ticked, and are
MERGED** -- PRs #16, #17 and #18 went in bottom-up at 17:19Z and master is
76e6619, so nothing below is waiting on a branch. 3.x gave the DMA allocator
declared in 3.6 a body and a host-side proof of contiguity;
3.3 closed the 8259 half by routing IRQ0 through the I/O APIC, and found that
both APIC modules had been reading device registers ONE BYTE AT A TIME through
a pointer declared VOLATILE -- gfortran narrows such a load, and the LAPIC had
been getting away with it since it landed. `boot/io.S` grew fk_readl/fk_writel
and `tools/mmiocheck.sh` now refuses the narrow form in the object file. 4.2
then found the ECAM window and walked the bus, and moved the boot gate to
`-machine q35` because the default board has no MCFG table to find.

Landing earlier, from a separate branch: the PCIe, xHCI and NVMe REGISTER
LAYOUTS -- types only, no procedures and no driver logic, recorded in 4.2, 5.1
and 5.3 rather than given boxes of their own. That change ticks no driver box
and does not pretend to.

That grep now answers differently, which is the whole of the milestone:

    $ grep -rl "MADT" src/ | sort
    src/acpi/fk_acpi.f90
    src/acpi/fk_madt.f90
    src/boot/fk_kmain.f90

**THE NUMBER 4.1 EXISTS FOR, off real firmware on both boot paths:**

    Fortran Kernel: MADT overrides/IRQ0-GSI 0x0005/0x0002

IRQ0 is overridden to GSI 2. No IOAPIC redirection entry for the timer can be
written without it, and 3.3 is where it gets used.

**Next, in order, with what each is really waiting on:**

| # | milestone | why now | really blocked on |
|---|---|---|---|
| 6.1 | the VFS | all three hardware pillars are up: 2.2 draws, 5.2 reads keys, 5.3 reads blocks | `strlen`/`strcpy`/`strcmp`, which 1.1 still owes and which nothing else is waiting on |
| 1.1 | the string half of the core library | unchanged and still owed | nothing; 6.1 and 6.4 cannot start without it |

**WHAT 5.1 NEEDED BEFORE IT COULD TOUCH THE CONTROLLER, AND IT IS PAID.** 4.2
read configuration space and never wrote it, so the COMMAND register could not
be read-modify-written, and a controller that cannot master the bus cannot read
a ring wherever it is put; and there was no capability-list walk, which is how
MSI-X is found before anything can enable it. Neither was xHCI work and both
were 5.1's to pay. They are now in `fk_pcie.f90`, off the running machine:

    Fortran Kernel: xHCI COMMAND firmware/cleared/enabled 0x0107/0x0101/0x0107
    Fortran Kernel: xHCI MSI-X cap/entries/bar/offset 0x90/0x0010/0x0/0x00003000

**AND THE MIDDLE NUMBER IS WHY THAT TOOK TWO ATTEMPTS.** SeaBIOS leaves this
controller at COMMAND 0x0107 -- decode and mastering already on -- so a kernel
that writes nothing reads back what a working one reads back. The obvious
assertion was watched STAYING GREEN with the enable mutated away. The kernel
now takes both bits DOWN and puts them back, and 0x0101 is a reading only this
kernel could have caused.

**THE GATE GREW A DEVICE, AND THE SCANNER GREW A DISTINCTION.** q35 has no xHCI
unless the boot gate adds `-device qemu-xhci`, which takes the machine from
five PCI functions to six. 4.2's check needed NO change for that, and the
earlier claim here that the device and the expectation had to land together was
wrong: `check_pci` reads `info pci` off the LIVE monitor and diffs it against
the guest's list AS SETS, so both sides grew at once and neither a missed
function nor an invented one can hide. What was hardcoded to five was
qmp-sentinel's own SELF-TEST fixture, and it moved with the device.
`mmiocheck-boot` now names fk_pcie.o as well, which forced the harder half: a
module that talks to hardware AND keeps a table narrows a load of its own .bss,
correctly. The discriminator comes out of the object rather than out of a name
-- the module's own storage carries a relocation, a device register never does
-- and the self-test proves both directions. An xHCI object joins that list
when it exists.

**TWO THINGS 4.1 CONFIRMED THAT HAD ONLY BEEN REASONED.** Type 4 of the MADT
puts NMI on LINT1 for every processor -- which is exactly what 3.3 configured,
by argument, after an injected NMI went nowhere. And MADT flags bit 0,
PCAT_COMPAT, is SET: firmware stating that the 8259s are present and must be
disabled before the IOAPIC is used, which is the sentence 3.3's box was open on.
Two milestones reasoned their way to a conclusion and the tables then agreed.

**WHAT 4.1 COST, and this is the pattern the last three milestones share.**
Six independent adversarial lenses over two modules found a REAL DEFECT that
the implementer's own 25133-check suite did not: the MADT entry-walk guards
were `off + elen > hlen` in signed 32-bit, and with a length near huge(int32)
the sum wraps NEGATIVE under -fwrapv, the guard passes, and the walk reads
about 2 GiB BELOW the table. Two lenses found it independently and both
reproduced it as a SIGSEGV. They also proved THREE TEST GAPS by mutation --
including that no fixture sat above 4 GiB, so truncating the RSDP's 64-bit
XsdtAddress to 32 bits passed the whole suite, which is the entire reason tag
15 is preferred over tag 14. A suite that passes is not a suite that can fail.

**AND THE STANDARD THAT MADE 4.1's NUMBERS EVIDENCE.** Every value the kernel
prints was FIRST read out of guest memory by an independent host-side walk of
the same tables, written in Python and sharing no code with the Fortran. Two
implementations agreeing is worth more than one implementation asserting. The
same argument the PMM makes by booting at a different -m, 4.1 makes by booting
at -smp 2: two CPUs and a 128-byte MADT instead of six and 160.

**Corrections made in this post-merge sweep**, most of it staleness the merge
created, plus older drift and one original miscount the same pass turned up.
3.3's closing block still handed the IOAPIC's doing to 4.2 and still said
`lapic_eoi` had never been called; 5.1 still listed three blockers, two of which
the merge discharged; 3.2.5 still called the guard page pending and 3.5 still
called the framebuffer unmapped; 4.1 and this header pointed IRQ0's GSI-2
override at 4.2, when 3.3 is what programs it; 4.2 conflated the kept device
list (64) with the 32 kmain publishes over QMP. The numbers moved too, and every
replacement was MEASURED rather than copied out of a commit message: the layout
gate links 36 modules and makes 175 checks, `build/run-pmm` makes 746, the boot
gate asserts six PMM verdicts each with a FAIL twin out of seven FAIL lines in
all, mb2-selftest injects eight defects and five of them still get past
grub2-file, and the image `-z max-page-size` protects is 68 KiB.

**Corrections made in the 4.1 pass**: 3.3's "WHAT IS NOT DONE, and
4.1 owns most of it" -- 4.1 has landed, and what remained was 3.3's own doing
rather than 4.1's parsing; and 3.6's "DMA memory ... is still not smuggled into
this box" -- its interface is declared there now, and 3.x has since defined it
in the PMM.

**Corrections made in the pass before 4.1**, kept because they are why several
boxes read the way they do: 0.3's "NOTHING here has ever booted that way";
0.3's "the MISSING half is `-bios OVMF.fd`"; 1.4's "there is no general
`panic(message)`"; 3.2.5's "ist2..ist7 are zero"; 3.3's "it is not mapped";
3.5's "the LAPIC ... falls inside [0, top) by accident". And the header's
numbering should be read literally: the Lead Architect's directive calls the
framebuffer work "Phase 3.3" and the heap/scheduler work "Phase 4.0"; in THIS
file those are 2.2 + 2.4 and 3.6 + 3.7.

---

## 🏗️ Phase 0: Project Initialization & Toolchain

Before any Fortran is written, the autonomous build environment must be established.

  *  [x] 0.1 Create Custom Linker Script (linker.ld)

        Validation: Script properly aligns .text, .data, and .bss sections for a 64-bit ELF kernel.

        DONE: `linker.ld`. Proven, not asserted -- `tools/linkscript-test.sh` links the
        REAL 36 modules under KFLAGS and checks 175 properties (`make linkscript`, also
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
        the 68 KiB kernel becomes multi-megabyte.

        One deviation from the wording: `-ffreestanding` is NOT passed. It is a C-only
        flag; f951 does not accept it. The property it stands for -- no libc, no
        libgfortran -- is enforced directly instead, by `make symcheck-boot` and
        tools/linktest.sh, which fail on any undefined symbol this tree does not itself
        define. KFLAGS now lives in `mk/kflags.mk` so the harness, the kernel build and
        the layout gate cannot drift apart.

  *  [x] 0.3 Configure QEMU Test Harness

        Validation: A script (run.sh) exists that packages the kernel into an ISO and launches qemu-system-x86_64 -m 24G -smp 6 -bios OVMF.fd.

        DONE, and the half this box waited on for four milestones is the half that
        landed: the kernel BOOTS UNDER UEFI. `tools/qemu-boot-test.sh` takes
        `FK_FIRMWARE=uefi` and runs the same assertions against OVMF that it runs
        against SeaBIOS. Both are gated on every run.

        ONE WORDING DEVIATION, and it is the modern spelling rather than a
        shortcut: `-bios OVMF.fd` is not passed. OVMF arrives as two pflash
        drives -- CODE read-only, VARS as a writable copy, because the packaged
        VARS file is not writable and OVMF writes to it. `-bios` with OVMF is the
        deprecated form and gives the firmware nowhere to keep its variables.

        WHAT MADE IT TRACTABLE, and it is the architectural decision of this
        milestone: a loader that came up on UEFI passes the EFI memory map
        THROUGH, as Multiboot2 tag 17. So the UEFI path needed no `BOOTX64.EFI`
        of its own. `grub2-mkrescue` writes a HYBRID ISO -- one El Torito entry
        for BIOS and one for UEFI -- once `grub2-efi-x64-modules` is in the dev
        container, so the firmware is chosen at BOOT time and not at build time,
        and the two paths are comparable by construction rather than by argument.

        THE SECOND FRONT END IS PAID, which is what this box warned would be the
        expensive part. `src/mm/fk_efi_mmap.f90` decodes the
        EFI_MEMORY_DESCRIPTOR array (1222 checks) and `fk_pmm` gained
        `collect_efi`/`collect_mb2` either side of ONE shared region table -- the
        two front ends differ only in how they read firmware's map; the
        asymmetric rounding, the accounting, the reserved-wins pass and the three
        locks stay one decision. Tag 17 wins where both exist: tag 6 is GRUB's
        summary of the EFI map and the EFI map is the original.

        THE NUMBER THAT JUSTIFIES THE WHOLE DESIGN, read out of a running guest
        rather than out of a specification: `descriptor_size` is 48 against 40
        bytes of fields. A parser that used `sizeof(descriptor)` desynchronises
        on descriptor 1 and reads the Pad word as a type. The stride is read.

        ONLY EfiConventionalMemory IS FREE. LoaderData holds the kernel and the
        boot info; BootServices memory is reclaimable in principle and not by a
        kernel that never called ExitBootServices itself. That conservatism is
        visible in the count: free comes back at total-1 on the UEFI path,
        because the kernel's own frames were never released and locking them
        flips no bits. Frame 0 is the only change.

        WHAT THIS IS NOT. It is not a native EFI entry stub -- GRUB is the EFI
        application here and this kernel is its Multiboot2 payload. That remains
        1.2's open half, and whether it is worth writing at all is now a real
        question rather than an assumed requirement.

        AND THE UEFI PATH HAS NO SCREEN. GRUB answers "no suitable video mode
        found" under OVMF, so tag 8 is absent and `fk_fbinfo` correctly REJECTS
        the probe. Explicit `-vga std`, `-device VGA` and `-device virtio-vga`
        do not change it. The video assertions are dropped for that firmware and
        the gate ANNOUNCES that it dropped them, because a gate that silently
        narrows what it checks reads exactly like one that passed. See 2.2.

## ⚙️ Phase 1: The Boot Layer & Bare-Metal Runtime

Bypassing Fortran's reliance on the OS and successfully handing control from UEFI to the Fortran entry point.

  *  [x] 1.1 The Core Library Translation

        Validation: String manipulation and math modules exist without libgfortran.

        DONE at last, on 2026-08-19, and it took three passes to get there. This box was
        ticked when Phase 1 closed and it should not have been: only the MATH half existed
        -- `src/lib/math/` has 7 modules plus `src/lib/fk_bcd.f90` -- and
        `docs/AUDIT-PHASE1.md` said so at the time: "Phase 1 delivered no string handlers
        ... any Phase 2 planning that assumes lib/string.c is already translated is working
        from a wrong inventory." That audit is dated 2026-08-12 and stays as written.

        PAID BY 1.3 (2026-08-13): the four MEMORY intrinsics -- memset, memcpy, memmove
        and memcmp.

        PAID IN FULL (2026-08-19): the STRING half. `fk_strlen`, `fk_strcpy`, `fk_strcmp`
        and `fk_strncmp` in `src/lib/fk_string.f90`, with the C spellings forwarded from
        `src/lib/fk_string_abi.f90`. The oracle side was FOUR DELETIONS: `mk/string.mk`
        already selected functions out of the vendor file with that file's own
        `__HAVE_ARCH_*` guards, so dropping `_STRLEN`, `_STRCPY`, `_STRCMP` and `_STRNCMP`
        brought exactly those bodies in -- zero warnings, zero undefined symbols, measured
        before a line was written. 92,765,576 checks, 0 mismatches.

        TWO THINGS IT FOUND THAT ARE WORTH MORE THAN THE FUNCTIONS.

        The oracle was GLIBC for one run. `build/oracle-string.o` depended on
        `lib/string.c` and nothing else, so deleting the four guards did not rebuild it:
        the symbols were absent, the link fell through to the C library, and every case
        was diffing Fortran against libc. It went red only because `lib/string.c` returns
        the SIGN (`c1 < c2 ? -1 : 1`, :285) and glibc returns the DIFFERENCE -- a
        translation that happened to return the difference would have gone GREEN against
        the wrong oracle. `Makefile` now carries `MKDEPS := $(MAKEFILE_LIST)` so every
        object depends on the fragments, and `chk_oracle_identity()` asserts the sign
        convention before any case runs.

        And a real bug in the translation: Fortran's `c_size_t` is a SIGNED int64 while
        C's `size_t` is unsigned, so `strncmp(a, b, SIZE_MAX)` arrived negative and
        `count <= 0` returned 0 without comparing anything. The test's `(size_t)-1` column
        is the only thing that sees it. The same signedness is UNTESTABLE in 1.3's four
        intrinsics -- an `n` of `SIZE_MAX` makes the oracle read 16 exabytes and the
        process dies before it can disagree -- and is deliberately left alone.

        THE GUARD PAGE IS THE OTHER HALF OF THE SUITE. The arena catches a WRITE outside
        the destination window and is blind to a READ past the terminator, which is how
        all four of these fail while still returning the right answer. Two mmap'd pages,
        the upper one `PROT_NONE`, the terminator on the last readable byte, and a SIGSEGV
        handler that turns the fault into a mismatch line. `strncmp` with `count == 0`
        runs against a pointer into the UNMAPPED page. Measured rather than argued: with
        the page's section removed, a `strlen` that reads one byte past the terminator
        passes 89,317,214 assertions; with it back it is caught on the first case.
        `docs/HARNESS-VALIDATION.md` carries the table.

  *  [ ] 1.2 Multiboot2 / EFI Assembly Stub  (Multiboot2 half only)

        Validation: Assembly code (boot.S) successfully transitions CPU to 64-bit Long Mode and jumps to kernel_main().

        DONE for the MULTIBOOT2 path, and proven on a running CPU rather than asserted:
        `tools/qemu-boot-test.sh` boots the ISO headless (-smp 6 -m 24G) and reads the
        four-word sentinel back out of guest physical memory over QMP. Word 3 is
        TAG xor magic, computed by Fortran at run time from the value GRUB left in EAX,
        so a pass is evidence that LIVE loader data crossed the asm -> Fortran ABI --
        not merely that the machine failed to crash.

        `grub2-file --is-x86-multiboot2` exits 0 (Fedora prefixes the GRUB binaries with
        "grub2-"; it is the tool the spec calls grub-file). That gate is necessary and
        NOT sufficient: tools/mb2-selftest.sh injects eight defects and five of them --
        including a boot-fatal entry point -- are accepted by grub2-file and caught only
        by tools/mb2-check.py.

        THE ONE THAT COST A BOOT: e_entry must stay VIRTUAL. GRUB's ELF64 loader finds
        the PT_LOAD whose [p_vaddr, p_vaddr+p_memsz) contains e_entry and translates it
        into that segment's physical terms itself. ENTRY(_start_phys) -- the obvious
        "the loader jumps with paging off, so give it a physical address" reading -- is
        refused with "entry point isn't in a segment", BEFORE the Multiboot2 entry-address
        tag is consulted. Both are now emitted and must agree; the gate asserts it.

        The EFI half of this box is STILL NOT DONE, and 0.3 changed what that
        sentence means rather than closing it. There is no BOOTX64.EFI: the
        kernel now boots under UEFI, but GRUB is the EFI application and this
        image is its Multiboot2 payload, entered through the SAME `_start` the
        BIOS path uses. Nothing in boot/ knows what firmware it came from.

        So the open question is no longer "when do we write the EFI stub" but
        "is one wanted at all". What a native stub would buy is a handover that
        does not depend on GRUB and access to boot services before
        ExitBootServices -- notably GOP, which is exactly what the UEFI path is
        missing (see 2.2). What it costs is a PE32+ image, a second entry path
        and a second set of gates. That is a Lead Architect call and this box is
        where it should be recorded.

        The framebuffer tag is no longer absent -- 2.2 added it. On the UEFI
        path GRUB declines to satisfy it; see that box.

  *  [x] 1.2b Long-mode entry hardening

        DONE, with 3.5, and the ordering hazard this box was opened for turned out to be
        already paid for. GDTR does NOT still hold a physical base by the time it matters:
        `gdt_init` builds the pseudo-descriptor from `c_loc(gdt)` of a Fortran module
        variable, so it has held a higher-half base since roadmap 3.1, and `idt_init` the
        same since 3.2. Only boot.S's throwaway `gdt64_pointer` is physical, and nothing
        reads it after the first LGDT.

        The sequence `vmm_activate` / `vmm_drop_identity` runs anyway, in this order:
        CR3, then LGDT + the far return in `gdt_flush`, then LIDT, then zero PML4[0],
        then reload CR3. The far return is the part that is not belt-and-braces -- it is
        what makes the CPU discard the hidden segment state loaded from the boot stub's
        physically-based descriptor, and it is cheap enough that proving it unnecessary
        was not worth a triple fault.

        The identity window is no longer boot.S's. `vmm_init` rebuilds it inside the new
        hierarchy, so it exists for exactly the length of the handoff and dies by having
        one quadword zeroed. What replaces it for every other purpose is the linear map
        at 0xFFFF800000000000 -- see 3.5.

        PROVEN BY FAULTING: a build with `FK_FAULT_MODE = -3` reads physical 0x100000
        after the unmap and the CPU answers

            EXCEPTION 0x0E ERR 0x0000000000000000 -- #PF Page Fault
            CR2     = 0x0000000000100000

        The same address is READ SUCCESSFULLY a few lines earlier, in the same boot, and
        the console carries the value: `[0x100000] = 0x00000000E85250D6`, which is this
        image's own Multiboot2 header magic. Before and after, on one machine, from one
        hierarchy.

  *  [x] 1.3 Custom Fortran Runtime Stubs

        Validation: Missing compiler intrinsics (like memcpy, memset) are implemented in Fortran using iso_c_binding to prevent linker failures.

        DONE. `src/lib/fk_string.f90` translates memset, memcpy, memmove and memcmp from
        vendor `lib/string.c`, and `mk/kflags.mk` no longer carries
        `-fno-tree-loop-distribute-patterns`: gcc's loop-distribution pass is now allowed
        to rewrite an array fill into a call to memset, and the link resolves it. `nm`
        on the built objects shows the whole mechanism working -- `fk_pmm.o` has
        `U memset` for its 262144-word bitmap fill, and the image has `T memset`.

        THE ONE THAT WOULD HAVE BEEN AN INFINITE LOOP, looked for before it was written
        rather than after: gcc is entitled to rewrite the byte loop INSIDE memset into a
        call to memset. Linux avoids it by compiling lib/string.c `-ffreestanding`
        (lib/Makefile). Measured on gfortran 16.1.1, the Fortran version does not need
        that: `c_f_pointer` builds an array descriptor whose stride is a run-time value,
        which the pass does not recognise as a fill, and the objects come out with zero
        undefined symbols with the pass both on and off.

        WHY THERE ARE TWO FILES. The differential harness links the Fortran against the C
        original in one binary, so the Fortran cannot define `memset` -- the oracle
        already does. Renaming the ORACLE instead does not work either: lib/string.c
        contains `#undef memcmp`, which defeats a -D on the command line. So
        `fk_string.f90` exports fk_memset..fk_memcmp and is the file under test, and
        `fk_string_abi.f90` -- kernel-image only -- exports the four C names and forwards.

        `tests/lib/test_string.c` diffs them against the vendor source over a guarded
        arena, and the same count under `kflags-test`. It was 36747535 checks at this
        milestone; roadmap 1.1 added the string half to the SAME test and it now prints
        92765576. `mk/string.mk` selects the functions out of lib/string.c using that
        file's OWN `__HAVE_ARCH_*` guards -- 27 defined and four left alone at 1.3, 23 and
        eight since 1.1 -- so the bodies being diffed are untouched vendor code. The test checks the returned
        pointer and the bytes OUTSIDE [dest, dest+n) as well as the copy itself, and
        memcmp's exact int rather than its sign, because lib/string.c returns the
        difference of two UNSIGNED chars: 0x80 against 0x00 is +128.

        1.3 needed the four MEMORY intrinsics and delivered those; the string half was
        still open when this box closed and stayed open until 2026-08-19. See 1.1.

  *  [x] 1.4 The Kernel Panic Handler

        Validation: A Fortran subroutine exists to halt the CPU (hlt) safely when an unrecoverable error occurs.

        DONE, and ticked on the harder reading rather than the wording. The
        wording was satisfied at 3.2; what this box was actually open on was
        stated in it: "there is no general `panic(message)` any Fortran caller
        can reach ... a subsystem cannot report 'this is unrecoverable and here
        is why' without inventing a fault." `src/cpu/fk_panic.f90` is that
        route. The PMM's out-of-memory path keeps its INT3 deliberately -- it
        WANTS a register dump and the only honest way to get real registers is
        to make the CPU push them.

        WHAT A PANIC DOES, which is the part of this box that was never a
        subroutine but a policy. Five stages, and the ORDER is the content:

          quiesce   `fk_cli` -- new, and separate from `fk_cpu_halt` on purpose.
                    The panic path must mask interrupts and then still run far
                    enough to report, which the existing CLI/HLT park cannot do.
          latch     `fk_panic_state`, a bind(c) volatile record in .bss: magic,
                    nesting depth, the caller's code, and the first 8 message
                    bytes. Written BEFORE anything that can itself fault.
          guard     depth > 1 halts immediately. A panic raised by the reporting
                    path must not re-enter it; the second report faults in the
                    same place and recurses until the stack walks through 3.5's
                    guard page. The depth is latched first, so the record still
                    carries how deep it got.
          report    both consoles, reached through bind(c) names rather than USE
                    for the reason fk_idt already documents.
          park      `fk_cpu_halt`.

        THE LATCH IS THE POINT, and it is this tree's own argument applied to
        the panic path: every line the reporter prints stops being evidence the
        moment the thing being reported IS the console. Read out of a running
        guest over QMP, from `FK_FAULT_MODE = -6`:

            magic = 0x00000050414E4943   ("PANIC")
            depth = 1
            code  = 0x0000000000001400
            head  = 'unrecove'

        while COM1 independently carried the banner, the message and the code.
        A panic that reached neither console would still be provable from
        outside.

        WHAT IS NOT DONE. There is no reboot policy, no crash-dump, and nothing
        survives the halt -- the record lives in RAM and is readable only while
        the machine is stopped. Nothing here unwinds or attempts recovery, which
        is correct for a kernel with one address space and no supervisor.

## 🖥️ Phase 2: Modern Display & Debugging

The Minisforum has no legacy VGA text mode. The kernel must render its own pixels via UEFI GOP.

  *  [x] 2.1 UART Serial Driver (Headless Debugging)

        Validation: Kernel can write strings to COM1 (0x3F8) using assembly outb wrappers. QEMU serial console outputs text.

        DONE, and the validation was met literally: the bytes were read coming out of
        QEMU's virtual COM1, not inferred from a gate's exit status.

            00000000  46 6f 72 74 72 61 6e 20  4b 65 72 6e 65 6c 3a 20  |Fortran Kernel: |
            00000010  55 41 52 54 20 53 65 72  69 61 6c 20 49 6e 69 74  |UART Serial Init|
            00000020  69 61 6c 69 7a 65 64 2e  0d 0a                    |ialized...|

        `boot/io.S` -- `fk_outb`/`fk_inb`, SysV AMD64, four instructions each. Port I/O
        is the SECOND of what were then exactly two things in this kernel that must be
        assembly (the first is CLI/HLT): IN and OUT reach a separate 16-bit address
        space that no Fortran expression can name. Both carry `int32_t` rather than
        `uint16_t`/`uint8_t` because Fortran has no unsigned types -- 0xC7 in an int8
        would have to be written -57 -- so the truncation is concentrated in two
        instructions instead of becoming a rule every caller has to remember.

        NO LONGER A COUNT OF TWO. 3.3 put `fk_readl`/`fk_writel` in this same file for
        the opposite reason: gfortran CAN emit an MMIO access, and NARROWS it, so that
        guarantee has to be bought in assembly here too.

        `src/drivers/serial/fk_serial.f90` -- 115200 8N1, FIFOs on, interrupts off (there
        is no IDT; one UART IRQ would be a triple fault), plus an internal-loopback
        self-test. Every register offset and bit mask is diffed against the kernel's own
        `include/uapi/linux/serial_reg.h`, included straight from the vendor tree -- that
        header is this translation's oracle, which is why `mk/serial.mk` is the first
        fragment with no ORACLE (a driver written against a hardware specification has no
        single C original). The TX spin bound is 65535, Linux's own `0xffff` from
        `arch/x86/boot/tty.c:30` around the identical LSR/XMTRDY poll; an absent UART
        drops a byte instead of hanging the one instrument that could explain the hang.

        THE ONE DESIGN DECISION WORTH ARGUING WITH: a failed self-test does NOT disable
        the console. It arms anyway and says so on COM1. A debug console that refuses to
        speak because it doubts itself is worse than one that speaks into a void.

        PROVEN, at three levels. `build/run-serial`: 4742 checks against a modelled 16550
        (DLAB routing, FIFO clears, loopback, floating-bus 0xFF), asserting the 13-step
        port trace byte for byte. `tools/qemu-boot-test.sh`: asserted THREE things when
        this box landed -- the 1.2 sentinel, the banner on COM1, and the ABSENCE of the
        self-test failure line -- and every milestone since has added its own verdicts
        to the same gate. `--smoke` shows both positive halves refusing a kernel-less guest.
        16 injected defects, 16 caught -- `docs/HARNESS-VALIDATION-SERIAL.md`, which also
        records what none of it can catch (no real silicon; timing is asserted as a count,
        never a duration).

        ONE ESCAPE, FOUND AND CLOSED RATHER THAN ASSUMED AWAY. Deleting the zero-extension
        from `fk_inb` boots completely clean: the host suite supplies its own `fk_inb` in
        C so it never sees `boot/io.S` at all, and on the boot gate the stale upper bits
        of EAX happen to be zero, so the loopback probe still matches. It is caught now by
        a white-box check in `tools/linkscript-test.sh`, labelled there as a spelling
        assertion rather than a semantic one. See M15.

        Wording deviation, same pattern as 0.2's `-ffreestanding` note: the spec says
        `-fno-leading-underscore`. gfortran spells it `-fno-underscoring`, and it was
        already in `mk/kflags.mk`.

        A GATE DEFECT THIS WORK INTRODUCED AND THEN FIXED, recorded because the tree's
        standard is that gates get watched failing. Character literals arrived in `src/`
        for the first time, so `tools/compliance.sh`'s `sed 's/!.*//'` had to become
        quote-aware (`tools/strip-comments.awk`). The first version removed two false
        positives and bought a FALSE NEGATIVE: on a line-continued literal the closing
        quote reads as an opening one and a real `go to` after it is blanked -- something
        the old sed caught. It now REFUSES source it cannot analyse instead of guessing,
        with a fixture in `tools/gate-selftest.sh` (27 checks, up from 24).

  *  [x] 2.2 UEFI GOP Framebuffer Mapping

        Validation: Multiboot2 header successfully requests the framebuffer; Fortran pointer maps to the physical video memory address.

        DONE ON BOTH FIRMWARE PATHS, and the UEFI half was one line of
        grub.cfg. The kernel had always ASKED for a mode -- header tag 5,
        flags 0, required -- and under OVMF GRUB answered on COM1 with

            error: ../../grub-core/video/video.c:grub_video_set_mode:761:no suitable video mode found.

        and handed over an MBI with no tag 8 in it. The cause was not the
        request and not the firmware: the EFI core `grub2-mkrescue` builds
        embeds the video FRAMEWORK and no video DRIVER, while the drivers sit
        unused on the ISO it just wrote. `insmod all_video` before the
        `multiboot2` line loads them -- efi_gop/efi_uga/video_bochs/
        video_cirrus on x86_64-efi, vbe/vga/video_bochs/video_cirrus on
        i386-pc, which is why one line covers both halves of the hybrid image.

            Fortran Kernel: GOP framebuffer base/pitch/w/h/bpp 0x0000000080000000/0x00001000/0x00000400/0x00000300/0x20
            Fortran Kernel: GOP framebuffer PTE selects PAT index 1, write-combining.
            Fortran Kernel: GOP renderer armed on the mapped framebuffer (roadmap 2.4).
            Fortran Kernel: console is live on the framebuffer, cols/rows 0x00000080/0x0000002F

        Same geometry, same masks (0x0000080008080810) and same console as
        SeaBIOS; only the base moves, 0xFD000000 to 0x80000000, which is why
        neither is written down in a gate.

        THE GATE WAS THE REAL WORK, because it was GREEN BEFORE ANY OF THIS.
        `tools/qemu-boot-test.sh` used to blank FK_FB_PASS_LINES,
        FK_CON_PASS_LINES and both FAIL lists under FK_FIRMWARE=uefi and set
        FK_CHECK_FB=0 -- an opt-out that would have stayed green whether or not
        a framebuffer ever appeared, which is the same shape as a gate that
        passes before its feature exists. The video assertions now apply on
        BOTH paths.

        AND THE ISO DID NOT DEPEND ON THE RECIPE THAT WROTE ITS grub.cfg.
        `$(ISO): $(KERNEL)` only, so removing the insmod line moved no file
        make was watching and the previous image was reused -- measured, the
        UEFI gate stayed green against an ISO that still carried the line. The
        rule now depends on Makefile.boot, and `isocheck-boot` greps the
        generated grub.cfg and the built ISO in the container, because a
        missing GRUB module is SILENT: the loader reports it and carries on.

        ONE LATENT DEFECT FELL OUT OF IT. `fb_bringup` keyed on the base
        being non-zero, and `fb_probe` writes the base BEFORE it validates the
        mode and returns early on one it refuses -- so a rejected framebuffer
        left a non-zero base behind. Nothing hit it while the UEFI path had no
        tag 8 at all. Forced with a probe that refuses the loader's depth, the
        old guard maps `phys 0xFFFFFFFFFFFFFFFF` with a zero PTE and arms the
        renderer on it, AFTER printing that it rejected the tag; the guard now
        keys on the magic, which is written last and only on acceptance.

        `boot/boot.S` carries the framebuffer tag (type 5, 1024x768x32)
        and `src/drivers/video/fk_fbinfo.f90` reads back the tag 8 the loader
        answers with -- through the identity window, before 1.2b's handoff
        closes it, because the reply decides which pages the linear map must
        leave out. The boot prints what it parsed:

            GOP framebuffer base/pitch/w/h/bpp 0xFD000000/0x1000/0x400/0x300/0x20
            GOP channel r/g/b pos:size packed 0x0000080008080810
            GOP IA32_PAT is 0x0007010600070106, PAT index 1 is write-combining.
            GOP framebuffer virt/phys/PTE 0xFFFF808000000000/0xFD000000/0x80000000FD00000B

        THREE THINGS IN THERE ARE NOT THE TEXTBOOK VERSION.

        The colour-info OFFSET. `multiboot2.h` ends the framebuffer tag's
        common header with a `u16 reserved`; the specification's PROSE says
        `u8`. Reading it the prose's way shifts every channel byte one position
        and produces a red channel at bit 0 of nothing. The packed masks above
        -- red at 16, green at 8, blue at 0, all 8 bits wide, i.e. BGRX -- are
        the header's version confirmed against a real GRUB.

        PAT, not the PCD/PWT pair. `boot/mmu.S` programs IA32_PAT with
        write-combining at index 1, so PWT ALONE selects it; the third selector
        bit is PTE bit 7 on a 4 KiB page and bit 12 on a 2 MiB one, and staying
        below index 4 means the VMM cannot select the wrong memory type by
        mapping at the wrong granularity. The MSR is READ BACK off the CPU and
        printed, because a wrmsr that never executed is otherwise
        indistinguishable from one that did -- the reset value differs from the
        wanted one in exactly the byte that decides this.

        THE APERTURE IS UNMAPPED FROM THE LINEAR MAP BEFORE IT IS MAPPED
        WRITE-COMBINING. `vmm_reserve_mmio` punches the 2 MiB pages covering the
        BAR out of the physmap. Two memory types for one physical page is
        undefined behaviour (SDM Vol.3 11.12.4), not a slow path, and on this
        machine the BAR is at 0xFD000000 -- inside the linear map by default,
        because 3.5's physmap covers everything below top-of-RAM. The boot
        asserts the hole:

            GOP framebuffer has no write-back alias in the linear map.

        AND THERE IS NO FRAMEBUFFER AT ALL ON THE UEFI PATH, which 0.3 found and
        which this box now owns. Booted through OVMF, GRUB answers
        "no suitable video mode found" and emits no tag 8, so `fb_probe`
        correctly REJECTS the probe and the kernel runs headless but for COM1.
        `-vga std`, `-device VGA` and `-device virtio-vga` change nothing: the
        mode is GRUB's to set and it declines. Two ways out, neither taken yet --
        get GRUB's video modules into the EFI half of the ISO, or read GOP out
        of the EFI system table directly, which is Multiboot2 tag 12 and IS
        present on that boot. The boot gate drops its video assertions for
        FK_FIRMWARE=uefi and SAYS SO on every run.

        The above-4-GiB hazard this box used to describe is gone rather than
        avoided: `vmm_map_mmio` maps an arbitrary physical range at a virtual
        address the kernel chooses, so a BAR above 4 GiB needs no new code.
        FK_VMM_MMIO is PML4[257], the slot after the linear map.

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

  *  [x] 2.4 The Software Renderer

        Validation: vga_print_string() successfully iterates over the font array and plots individual colored pixels to the screen.

        DONE, and "to the screen" finally happened. The renderer was already
        verified byte-exact against a reference model on a simulated
        framebuffer with pitch > width (248,853 checks); what 2.2 added was a
        real one. `fb_test_bar` draws four primaries and a signature string,
        `tools/qmp-sentinel.py` pmemsaves the framebuffer at the physical
        address the GUEST's own handoff block names, and compares.

        THE COMPARISON IS AGAINST COLOURS THE HOST PACKED FROM THE LOADER'S
        MASKS, not against constants. A renderer that ignores the reported
        channel positions and hardcodes RGB draws a bar that is non-black,
        correct-looking and rejected. The signature goes further and is
        compared GLYPH FOR GLYPH against the kernel's own font table, read out
        of guest memory:

            all 267 lit pixels of "FK-GOP 2.4" in the status bar match the
            kernel's own font table, glyph for glyph

        Both directions -- a lit font bit must be foreground AND a clear one
        must not be -- so a cell that was filled rather than rendered fails.

        AND A TERMINAL ON TOP OF IT. `src/drivers/video/fk_console.f90` is cell
        geometry and a cursor: wrap, tab stops, backspace, CR/LF, and scrolling
        via `fk_memmove`, ONE call per scanline because the stride is wider than
        the visible width and a single call would copy the off-screen slack that
        `vga_init_framebuffer` deliberately leaves outside the mapped extent. A
        full-screen scroll on write-combining memory costs under one PIT tick,
        measured and printed rather than assumed. `tests/drivers/video/test_console.c`
        drives it against a C reference model of both the character grid and the
        expected pixels: 937,980 checks, 0 mismatches.

        The panic handler (1.4) now writes to BOTH consoles, reaching
        `console_write` through a bind(c) interface rather than USE association
        so that a call which must work whether or not there is a screen does not
        order the whole video stack ahead of the IDT. The gate asserts the panic
        screen by its PALETTE: `FK_FB_EXPECT=panic` requires the last text rows
        to be white on red, so a register dump that reached only COM1 is caught.

        A DEFECT THE HOST TEST FOUND AND THE BOOT DID NOT, recorded because it
        is the fourth instance of a trap this tree already tracks.
        `call vga_print_char(achar(code, c_char), ...)` passes a FUNCTION-RESULT
        expression to a bind(c) character dummy with VALUE; gfortran 16.1.1
        materialises a temporary and passes its ADDRESS while the callee reads
        the low byte of RDI. Every glyph on screen became the same CP437 symbol
        -- the low byte of a stack address, constant per call site -- while
        cursor motion, wrapping and scrolling stayed perfectly correct. The
        boot passed. Assigning to a local first fixes it; the glyph-identity
        check above is what would now catch it from outside the guest.

## 🧠 Phase 3: Core CPU & Memory Management

The most critical mathematical and structural phase. Setting up the brain of the OS.

  *  [x] 3.1 Global Descriptor Table (GDT)

        Validation: Flat memory model is established in Fortran structures and loaded via lgdt.

        DONE. `src/cpu/fk_gdt.f90` holds the three descriptors -- null, 0x00AF9A00...
        (P|S|code|read, G|L set: the L bit is the entire point) and 0x00CF9200...
        (P|S|data|write) -- and `boot/gdt_flush.S` loads them. This REPLACES the
        table boot.S carries: that one is .rodata with a 32-bit LGDT operand built
        for pre-paging addresses, this one is kernel data with a 64-bit one.

        Two things are not what a textbook shows, both deliberate. The pseudo-
        descriptor is an `integer(c_int16_t) :: gdtr(5)` and NOT a `bind(c)` derived
        type: LGDT wants a packed 16-bit limit followed by a 64-bit base, and C
        struct rules would pad that base out to offset 8, so the type system would
        produce a descriptor the CPU reads as garbage. An array of an intrinsic type
        is packed by the standard. And the selector values are ARGUMENTS to
        gdt_flush rather than constants inside it, so `fk_gdt_m` is the only place
        in the tree that decides what 0x08 and 0x10 mean.

        The far jump is an LRETQ. A far JMP with an immediate pointer does not exist
        in 64-bit mode, so CS is reloaded by pushing selector and target and faking
        a far return -- the panic dump below reports `CS = 0x08`, `SS = 0x10`, which
        is that sequence having worked.

  *  [x] 3.2 Interrupt Descriptor Table (IDT)

        Validation: Hardware and CPU exceptions (like Page Faults) trigger specific Fortran subroutines.

        DONE, and validated by faulting on purpose rather than by argument. A
        deliberate divide by zero in `kernel_main` produced this on COM1:

            *** FORTRAN KERNEL PANIC ***
            EXCEPTION 0x00 ERR 0x0000000000000000 -- #DE Divide-by-Zero Error
            RIP     = 0xFFFFFFFF80101E5F
            CS      = 0x0000000000000008
            RFLAGS  = 0x0000000000010086
            RSP     = 0xFFFFFFFF80109100
            SS      = 0x0000000000000010
            RAX     = 0x0000000000000001
            ... RBX through R15 ...
            *** HALTED -- CLI/HLT ***

        That RIP is not approximately right, it is the address of the `idivl` in the
        image (`objdump -d --disassemble=kernel_main`). RAX is the dividend the CPU
        was holding. R8 = 0xFFFF is the UART spin counter left over from the line
        printed immediately before -- i.e. the trampoline preserved state the fault
        did not touch.

        `boot/interrupts.S` -- isr0..isr31. Vectors 8, 10-14, 17, 21, 29 and 30
        arrive with an error code from the CPU and the rest do not, so the rest push
        a zero in its place: the Fortran side must not have to know which kind it
        caught. Then the interrupt number, then all 15 general-purpose registers,
        then CLD (an interrupt gate does not clear DF and SysV requires DF=0 on
        entry), then RSP into RDI and `call isr_handler`. The frame is 22 quadwords
        and the CPU aligns RSP to 16 before pushing its five, so RSP is 16-byte
        aligned AT the call, which is what the ABI asks for.

        `src/cpu/fk_idt.f90` -- the catcher. `fk_regs_t` is a `bind(c)` type of 22
        quadwords that mirrors that push order exactly; the gate descriptor is a
        second `bind(c)` type whose fields C rules place at 0, 2, 4, 5, 6, 8 and 12,
        which happens to be the hardware format with no padding at all. Vectors
        32-255 are installed with the present bit CLEAR, so an unexpected vector
        raises #GP rather than jumping to a zeroed offset.

        THE PROOF THE DIVIDE BY ZERO CANNOT GIVE: #DE carries no error code, so it
        only exercises the dummy-push branch. A throwaway build that wrote to an
        unmapped 4 GiB address instead reported `EXCEPTION 0x0E ERR 0x0000000000000002
        -- #PF Page Fault`, and 0x2 is the CPU's own code for a write to a
        not-present page. Both branches of the normalisation are therefore observed,
        not assumed. (A null dereference would NOT have worked: boot.S identity-maps
        the first 1 GiB, so address 0 is present and writable.)

        WHAT THIS MILESTONE COST, both found by booting and neither by any gate:
        gcc rewrites `1/x` into a compare against +-1 and emits no DIV, so the first
        build never faulted; and gfortran 16.1 passes a `character(kind=c_char),
        VALUE` dummy by ADDRESS at some call sites while the callee reads it as a
        value, so every byte the panic printer emitted was the low half of a
        pointer. `fk_serial_m` now exports `serial_print_byte`, taking an integer;
        `serial_print_char` keeps its C signature because the 2.1 oracle test is
        written against it and C callers were never affected. See
        `docs/HARNESS-VALIDATION-PHASE3.md`.

        NOT DONE HERE, and 3.3's problem: no TSS, so no IST -- a #DF arrives on the
        faulting stack. No 8259 remap, so the IRQ vectors still collide with the
        exception range and interrupts stay masked.

        BOTH OF THOSE ARE NOW CLOSED BY 3.2.5 BELOW.

  *  [x] 3.2.5 TSS, IST and PIC pacification (the hardware safety patch)

        Validation: a #DF raised by a deliberately smashed RSP is delivered on a
        known-good stack and prints a Fortran panic, and the legacy 8259s answer
        on 0x20/0x28 with every line masked.

        DONE, and both halves were read back out of the DEVICE MODELS rather than
        believed from the console. On COM1:

            Fortran Kernel: TSS loaded, IST1 armed for #DF.
            Fortran Kernel: 8259 PIC remapped to 0x20/0x28, all IRQs masked.
            Fortran Kernel: smashing RSP to force a #DF (roadmap 3.2.5).

            *** FORTRAN KERNEL PANIC ***
            EXCEPTION 0x08 ERR 0x0000000000000000 -- #DF Double Fault
            *** #DF ENTERED ON IST1 -- THE EMERGENCY STACK HELD ***
            RIP     = 0xFFFFFFFF8010123B
            RSP     = 0x0000400000000000
            FRAME   = 0xFFFFFFFF80108110
            ...
            *** HALTED -- CLI/HLT ***

        Read those three numbers together, because separately none of them proves
        anything. RIP is the PUSH in `boot/faultgen.S`. RSP is the pointer that
        push was made through -- the smashed one, so the fault really did happen
        on a stack that could not take a frame. FRAME is where the frame ACTUALLY
        landed. `fk_df_stack` is 8192 bytes at 0xFFFFFFFF801061C0, so its
        exclusive top is 0xFFFFFFFF801081C0, and 0x801081C0 - 0x80108110 = 176 --
        one 22-quadword frame, the exact size `boot/interrupts.S` builds. The CPU
        loaded RSP from IST1 and pushed once. It switched stacks.

        The register dump cannot show this on its own, which is why the FRAME line
        was added: `regs%rsp` is the RSP the fault happened WITH, so on a #DF it is
        always the broken one. The address of the frame is the only thing that
        says which stack the handler is standing on.

        `fk_tss` happens to sit at 0xFFFFFFFF801081C0 -- immediately above the
        stack, so the stack's exclusive top IS the TSS's address. That is safe
        because the CPU decrements RSP before it writes, so the first byte stored
        is at top-8; it is recorded because an inclusive top would corrupt the TSS
        with the frame of the fault it is there to handle.

        And from QEMU's monitor, which reports silicon state and not the kernel's
        opinion of it:

            TR =0018 ffffffff801081c0 00000067 00008b00 DPL=0 TSS64-busy
            GDT=     ffffffff80104020 00000027
            pic0: irr=01 imr=ff isr=00 hprio=0 irq_base=20 rr_sel=0 elcr=00 fnm=0
            pic1: irr=00 imr=ff isr=00 hprio=0 irq_base=28 rr_sel=0 elcr=0c fnm=0

        0xffffffff801081c0 is the address of `fk_tss` in the ELF; 0x67 is 104-1;
        type 0xB is BUSY, which only LTR sets. Before this milestone the same VM
        printed `TR =0000`, `GDT= ... 00000017`, and -- the reason this box exists
        -- `pic0: ... irq_base=08`. The master really was answering in the CPU
        exception range, so a spurious IRQ0 would have arrived as vector 8 and the
        panic handler would have reported a #DF that never happened.

        `src/cpu/fk_tss.f90` -- the TSS, an 8 KiB emergency stack in .bss, the
        16-byte descriptor, LTR. THE ONE THING THAT IS NOT A TEXTBOOK STRUCT: the
        TSS is a `bind(c)` type of 25 32-BIT fields and a closing pair of 16-bit
        ones, not one field per architectural quadword. RSP0 sits at offset 4, and bind(c) means C struct
        rules, so a `c_int64_t` declared there is aligned up to offset 8 -- which
        moves IST1 from 0x24 to 0x28 and every field after it. Measured on
        gfortran 16.1.1 before a line was written, not assumed. `tools/
        linkscript-test.sh` reads the size back out of the linked image and fails
        at anything but 104 bytes, and mutation M13 confirms it catches the
        widening.

        This is the same trap `fk_gdt_m`'s pseudo-descriptor comment describes,
        arrived at from the other direction: there the answer was an array of an
        intrinsic type, here it is a struct with nothing left to pad.

        The GDT grew from three slots to five, because a TSS descriptor in 64-bit
        mode is SIXTEEN bytes -- `FK_GDT_TSS_SLOT` is derived from the selector so
        the two cannot drift. `boot/gdt_flush.S` gained `tss_flush`; the IST index
        lives in `fk_tss_m` and `fk_idt_m` asks for it by name, so the slot the TSS
        fills in and the slot the #DF gate selects are one decision.

        `src/drivers/pic/fk_pic.f90` -- ICW1..ICW4, master 0x20, slave 0x28, then
        0xFF into both data ports, then a READBACK: once the ICW sequence has
        completed the data port reads the IMR, so the kernel's "all IRQs masked"
        line is the chip's answer rather than the driver's intention.

        `boot/faultgen.S` -- `fk_smash_stack`. 0x0000400000000000 is canonical and
        mapped by nothing, so the push takes a #PF and the CPU's attempt to push
        the #PF frame on the same broken RSP is the second fault. CR2 read back
        0x00003ffffffffff8 afterwards, which is that push's target address.

        WHAT THIS COST: nothing, on the first boot -- which is worth recording
        only because the two traps that made 3.2 expensive were both looked for in
        advance this time. The struct layout was measured before the module was
        written, and the fault trigger is assembly precisely so no optimiser can
        fold it away the way it folded `1/x`.

        WHAT IT DOES NOT PROVE. IST1 only, when this was written. SUPERSEDED IN
        PART BY 3.3: IST2 is armed for NMI now, with its own 8 KiB stack, and an
        injected NMI has been observed landing on it. ist3..ist7 are still zero,
        so #MC continues to arrive on the faulting stack -- fine while nothing
        raises one, and the next entry in this list to be paid.
        There is still no guard page below the EMERGENCY stacks -- the one page
        3.5 reserved is the boot stack's -- so a runaway panic handler on IST1 or
        IST2 walks into whatever .bss put underneath, and no open box owns it.

        AND THE SHARPER VERSION OF THAT, found by review rather than by a gate:
        `fk_tss` ends at 0xFFFFFFFF80108228 and `__boot_stack_bottom` is
        0xFFFFFFFF80108230 -- EIGHT BYTES above it. linker.ld lays the Fortran
        .bss objects down first and reserves the 16 KiB boot stack after them, so
        the stack grows DOWN towards the TSS. A boot-stack overflow therefore
        destroys the TSS, IST1 included, BEFORE the #DF that would have used it.
        Nothing recurses today and 16 KiB is a long way, so this is a bound and
        not a live bug -- but it is the specific way this milestone's safety net
        fails, and it is the one thing 3.5 must fix before anything deepens the
        call stack.

        SUPERSEDED BY 3.4, AND ONLY BY LUCK -- THEN FIXED BY 3.5. The PMM's 2 MiB
        bitmap became the object directly below the boot stack -- with ZERO bytes
        of slack -- so an overflow corrupted the allocator instead of the TSS, and
        IST1 survived to catch the fault the overflow caused. That was strictly
        better and it was nobody's design: it was what the link order happened to
        be that week, which is exactly why linkscript-test.sh PRINTS the neighbour
        instead of asserting one. The guard page at 3.5 was the fix and it has
        landed: linker.ld reserves `__boot_stack_guard`, a 4 KiB frame of its own
        directly below the boot stack, and the VMM leaves it unmapped, so the
        overflow faults on the guard instead of reaching whatever the link order
        left beneath it -- which is no longer the bitmap. And the
        ONE boot exercises one IST index on one vector: see
        `docs/HARNESS-VALIDATION-PHASE3.md` for the mutation table, including the
        defects that got past it.

        A NOTE ON THE COMMITTED IMAGE, AS IT WAS AT THIS MILESTONE. `kernel_main`
        raised exactly one deliberate fault, chosen by the `FK_FAULT_MODE`
        PARAMETER, and 8 (#DF) was the default here and is the milestone. Since
        3.2b the default is -5, which raises nothing at all. 0 (#DE) is NOT redundant: #DF carries a CPU error code and
        so only ever reaches the `ISR_ERR` half of `boot/interrupts.S`, leaving the
        dummy-push half that 3.2's M1 mutation targets unexercised. Both gates are
        driven from `tools/mutate-phase3.sh`, which rebuilds for each.

  *  [x] 3.2b Interrupts that RETURN (the deferred half of 3.2)

        Validation: the CPU takes a hardware interrupt, a Fortran handler runs, and
        execution RESUMES at the instruction that was interrupted. A tick counter
        advances while the kernel keeps running.

        DONE. On COM1, from the shipped image, and these five lines are the whole
        milestone:

            Fortran Kernel: PIT channel 0 hz/divisor 0x00000064/0x00002E9C.
            Fortran Kernel: 8259 IMR now 0x0000FFFE, IRQ0 is the only line open.
            Fortran Kernel: RFLAGS.IF is set, the CPU is interruptible, RFLAGS = 0x0000000000000282
            Fortran Kernel: IRQ0 ticks before/after/spurious 0x00000000/0x00000003/0x00000000.
            Fortran Kernel: the first tick interrupted kernel .text with IF set, RIP/RFLAGS 0xFFFFFFFF80104976/0x0000000000000206.
            Fortran Kernel: interrupts are live and the kernel is still running (roadmap 3.2b).

        READ THE RIP. 0xFFFFFFFF80104976 is not approximately inside kernel_main:
        it is the exact address of the `cmpq fk_tick_count(%rip)` that the wait
        loop executes, disassembled out of the image that printed it. The timer
        interrupted the loop on its own compare, a Fortran handler ran, IRETQ put
        the CPU back on that instruction, and the loop went round again.

        ONLY BIT 9 OF THAT RFLAGS IS THE ASSERTION. 0x206 and 0x202 are both
        observed across runs and both are correct: the low bits are the arithmetic
        flags the interrupted CMP happened to leave, and they depend on where in
        the loop the timer landed. The kernel tests bit 9 and prints the whole
        register, so what it asserted and what it saw are both on the line.

        AND THE COUNT IS THREE, NOT ONE, which is a separate fact. An 8259 that is
        never acknowledged delivers exactly one interrupt and then holds its
        in-service bit forever -- so "it ticked" and "the interrupt controller is
        wedged" are the same observation. Waiting for three is what tells them
        apart, and it is why M30 (EOI deleted) is caught.

        THE PROOF THAT IS NOT ON THE CONSOLE AT ALL. `fk_tick_count` is a bind(c)
        volatile module variable, so `tools/qmp-sentinel.py ticks` pmemsaves it out
        of the running guest TWICE, a quarter of a second apart, and asserts it
        grew. Every line above is something the kernel says about itself and stops
        being true the moment the kernel wedges; that one is asked of guest memory
        while the CPU is parked in `sti; hlt` and can only be answered by a machine
        that is still taking interrupts and returning from them right now.

        WHAT WAS BUILT.

        `boot/interrupts.S` -- a SECOND TAIL. `isr_common` is unchanged and still
        ends in `jmp fk_cpu_halt`; the new `irq_common` restores the 15 registers,
        drops the two quadwords the stub pushed and executes IRETQ. The two are
        deliberately not one routine with a flag: resuming from a #GP is not
        something this kernel knows how to do, and which tail a vector gets is
        decided by the IDT and nowhere else. The 15 pushes and the 15 pops are
        macros because they are one decision written twice, and a tree where they
        can drift is a tree where an IRQ returns with rbx and rbp exchanged --
        which corrupts the interrupted code, not the handler.

        The stubs push the 8259 LINE NUMBER, 0-15, and not the vector. The vector
        is FK_PIC1_VECTOR + line and `fk_pic_m` is the only place that decides what
        FK_PIC1_VECTOR is, so an assembler constant here would be a second copy of
        that decision with nothing keeping the two equal -- the same rule 3.1
        applied to the GDT selectors.

        `src/drivers/pic/fk_pic.f90` -- EOI, mask, unmask, and both readbacks.
        `pic_eoi` sends the slave's first and the master's second, and only the
        master's for a line below 8. `pic_unmask` on a slave line also clears the
        master's IRQ2, because a slave line behind a masked cascade is still
        silent. `pic_isr` reads the in-service register through OCW3, which is the
        one thing that distinguishes a spurious IRQ7 or IRQ15 from a real one --
        the chip never set the bit, so a handler that EOIs on the vector alone
        cancels whatever IS in service.

        `src/drivers/pit/fk_pit.f90` -- channel 0, mode 3, binary, 100 Hz. The
        divisor is COMPUTED from the 1193182 Hz crystal rate and printed, so the
        console line carries a number the kernel derived rather than a claim it
        made.

        `src/cpu/fk_idt.f90` -- vectors FK_PIC1_VECTOR..+15 installed present, and
        the router. The install loop now clears all 256 gates FIRST and fills in
        the two blocks after, so "every vector this kernel does not handle raises
        #GP" is true by construction rather than by a range test somebody has to
        keep correct.

        WHAT IT COST, and it is the fifth entry in this tree's list of gfortran
        traps -- the first four are in 3.2, 3.2.5 and 3.4:

            A PUBLIC MODULE FUNCTION WHOSE BODY IS A VOLATILE LOAD IS TREATED AS
            SIDE-EFFECT-FREE BY A CALLER IN ANOTHER TRANSLATION UNIT.

        The wait loop was first written as `do while (pit_ticks() < t0 + 3 ...)`.
        Compiled, there was no loop: gcc had deleted it and printed the "before"
        and "after" counts out of the same register. Measured both ways round with
        a throwaway -- inside ONE translation unit the getter is inlined, the
        volatility is visible and the code is correct; across two it is a plain
        call, the caller has only the .mod, and the volatile is inside the body it
        cannot see. The tell in the disassembly was `cmp $0x7ffffffffffffffc,%rbx`,
        which is gcc asking whether `t0 + 3` overflows -- only a question if t1 IS
        t0.

        The rule this tree now follows: state an interrupt handler writes is
        exported as a VOLATILE module VARIABLE and read by use association, never
        returned by an accessor. The attribute does travel through the .mod and the
        load is then emitted in the reader. `fk_tick_count`, `fk_first_rip`,
        `fk_first_rflags` and `fk_irq_spurious` are all exported that way, all
        bind(c), and `tools/compliance.sh` rule 3 was extended to accept a public
        module variable that names itself -- before this milestone the tree had no
        such export and the rule could only be satisfied by a procedure.

        THE SHIPPED IMAGE NO LONGER PANICS. `FK_FAULT_MODE` gained `-5`, which
        raises nothing and parks in `fk_cpu_idle` (`sti; hlt; jmp`), and that is
        now the default. Every fault build -- #DF, #DE, the PMM's out-of-memory
        INT3, and 3.5's three page faults -- is something `tools/mutate-phase3.sh`
        seds IN. The tick assertion is off for all of them, because a panic handler
        halts with IF clear and a frozen counter is the correct answer there.

        WHAT THIS DOES NOT PROVE, stated rather than implied:

          * Only line 0 has ever fired. The slave path, the cascade EOI and the
            spurious-IRQ15 branch are written and reviewed and have never been
            executed -- nothing in this machine drives a slave line yet.
          * The spurious counter has only ever read zero. That is the correct
            value on this hardware; it is not evidence the check works.
          * Nothing NESTS. Every gate is an interrupt gate, so IF is clear inside
            the handler and the non-specific EOI can only be clearing the line
            being serviced. The moment a trap gate or an explicit STI appears in a
            handler, that reasoning expires.
          * The PIT's reload value cannot be read back -- the 8253 has no such
            command -- so `M33-pit-never-programmed` ESCAPES: delete the three OUTs
            and the chip keeps the firmware's divisor and still ticks, at 18.2 Hz,
            with every console line still passing. Closing it needs a timing
            assertion nobody has written. Recorded in
            `docs/HARNESS-VALIDATION-PHASE3.md` rather than quietly left out.
          * IRQ0 is now unmasked for the whole life of the kernel, so every module
            variable written outside a handler is written with an interrupt able to
            arrive between any two instructions. Nothing shares state with the tick
            handler today. That is a fact about how small this kernel is, not a
            property anything enforces.

  *  [x] 3.3 Advanced Programmable Interrupt Controller (APIC)

        Validation: Legacy 8259 PIC is disabled. Local APIC is mapped and active.

        BOTH HALVES ARE DONE. The 8259s are masked and the timer reaches the CPU
        through the I/O APIC instead. The kernel's own lines:

            Fortran Kernel: IOAPIC id/version/entries 0x00/0x11/0x0018
            Fortran Kernel: the IOAPIC page has no write-back alias in the linear map.
            Fortran Kernel: both 8259s report every line masked.
            Fortran Kernel: IOAPIC gsi/vector/readback 0x0002/0x20/0x00000020
            Fortran Kernel: the timer still ticks with both 8259s masked (roadmap 3.3).

        and the same facts as QEMU's device models hold them, which is the half
        no console line can establish:

            PASS  8259 master IMR is 0xFF (want 0xFF)
            PASS  IOAPIC pin 2 delivers vector 32 (want 32 = 0x20, the IDT's IRQ0 stub)
            PASS  IOAPIC pin 2 is unmasked (active-hi edge  fixed  physical)
            PASS  every other IOAPIC pin is masked (24 pins)

        THE PROOF IS NOT THE NEW LINES. It is that the `ticks` and `sched`
        assertions STILL PASS with imr=ff on both chips -- fk_tick_count read
        twice from outside the guest and growing, on a machine where the legacy
        pair can no longer deliver anything. GSI 2 is the number 4.1 measured;
        routing IRQ0 to GSI 0 would produce every line above and no ticks.

        WHAT THE MILESTONE ACTUALLY COST, AND IT WAS NOT THE IOAPIC. Both APIC
        modules reached their registers through a VOLATILE Fortran pointer.
        `lapic_max_lvt` is `ibits(reg_read(base, REG_VERSION), 16, 8)`, and
        gfortran -O2 proved only one byte of that load is ever used and emitted

            movzbl 0x2(%rax),%eax

        a ONE-BYTE read of a device register, through a pointer declared
        VOLATILE. Fortran's VOLATILE forbids ELIMINATING and REORDERING an
        access. It does not forbid NARROWING one, and neither does C's.

        Both parts forbid it: the SDM requires a naturally aligned 4-byte access
        to every local APIC register (Vol.3 11.4.1), and the I/O APIC's IOWIN is
        a single 32-bit window with no defined sub-dword behaviour. The LAPIC's
        narrowed read happened to return the right byte on QEMU -- 0x00050014
        has 0x05 at offset 2 -- so it had been passing every gate in this tree
        since the LAPIC landed. The IOAPIC's did not: QEMU answers a one-byte
        read of IOWIN+2 with ZERO, `ioapic_max_redir` reported 1 entry instead
        of 24, and every route was refused with E_GSI. That is how it was found,
        and it would have been found on the Minisforum box instead.

        `fk_readl`/`fk_writel` in `boot/io.S` are the fix -- a call the compiler
        cannot see through can be neither narrowed nor reordered against the
        next one, which an indexed register pair needs anyway. `tools/mmiocheck.sh`
        runs in `bootgate`, reads the OBJECT rather than the source because the
        source that gets this wrong looks right, and compiles the bad form first
        to prove this toolchain still emits the narrowed access.

        ORDER INSIDE ioapic_bringup IS THE DESIGN: punch, map, assert the alias
        is gone, read the chip, `pic_disable`, route, and only then hand the EOI
        to the LAPIC. Masking before routing is not tidiness -- a line live on an
        8259 and the IOAPIC at once is delivered twice, and the second is
        acknowledged at whichever chip the handler was told about, leaving the
        other holding an in-service bit for ever.

        `vmm_punch_physmap` is new and 4.2 needs it too. `vmm_reserve_mmio` runs
        BEFORE `vmm_init`, which is unreachable for an address that comes out of
        an ACPI table: reading that table needs the linear map the reservation
        would have holed. So the write-back page is REMOVED afterwards instead,
        and the routine refuses a range overlapping reported RAM -- firmware
        claiming a device aperture inside memory is not something to quietly
        unmap.

        The LAPIC's spurious vector is now installed rather than merely chosen.
        `fk_spurious_stub` counts and IRETQs in two instructions and never enters
        Fortran; it gets NO EOI, because the local APIC sets no in-service bit
        for a spurious interrupt and retiring one would retire whatever really
        is in service. kmain's own duplicate `FK_LAPIC_SPURIOUS = 255` is gone --
        the compiler found it, as a name clash against fk_idt_m's counter.

        WHAT IS NOT DONE: only IOAPIC 0 is programmed, only GSI 2 is routed,
        every other pin stays masked, and there is no MSI or MSI-X path. LINT0
        is still ExtINT and is left that way deliberately -- inert with both
        chips masked, and changing it would churn assertions for nothing.

        `src/cpu/fk_lapic.f90` (10322 checks). Off the running chip, through the
        mapping, and not remembered from what was written:

            Fortran Kernel: LAPIC MSR base/enabled 0x00000000FEE00000/0x00000001
            Fortran Kernel: LAPIC id/version/SVR 0x00000000/0x00050014/0x000001FF
            Fortran Kernel: LAPIC LINT0/LINT1 0x00000700/0x00000400
            Fortran Kernel: LAPIC software-enabled, LINT0 ExtINT, LINT1 NMI.

        SVR 0x1FF is the assertion: vector 0xFF in bits 7:0 AND bit 8, the
        software enable. An APIC that was mapped but never enabled reads 0x0FF
        and passes any looser pattern.

        NO ACPI, and this box's earlier correction was right: `IA32_APIC_BASE`
        (MSR 0x1B) carries the base in bits 51:12 and the enable in bit 11. The
        MADT is needed for the IOAPIC, the other five cores and the interrupt
        source overrides -- none of which is the BSP's own LAPIC. `boot/mmu.S`
        gained `fk_rdmsr`/`fk_wrmsr`; nothing was waited on.

        THE MAPPING IS STRONG UC AND THE ALIAS IS PUNCHED OUT. `FK_VMM_LAPIC`
        with `FK_VMM_UC` -- PAT index 3, PCD and PWT together, which boot/mmu.S
        leaves at 0x00. UC- at index 2 would let an MTRR promote it to something
        weaker. And `vmm_reserve_mmio` takes 0xFEE00000 out of the linear map
        BEFORE the physmap is built, because on this 24 GiB machine it is below
        top-of-RAM and would otherwise be covered write-back -- two memory types
        for one physical page, SDM Vol.3 11.12.4, the same trade 2.2 made for the
        framebuffer.

        THE IST SLOT THIS BOX ASKED FOR IS ARMED AND IS REACHED. `FK_TSS_IST_NMI`
        is IST2 with its own 8 KiB stack, and vector 2's gate selects it. Proven
        by QMP `inject-nmi` against the SHIPPED image -- no mutation build:

            *** NMI ENTERED ON IST2 -- THE EMERGENCY STACK HELD ***
            RSP     = 0xFFFFFFFF80118110
            FRAME   = 0xFFFFFFFF80123150

        `fk_nmi_stack` ends at 0xFFFFFFFF80123200, so the frame is 0xB0 below its
        top -- one 22-quadword frame, the exact size boot/interrupts.S builds --
        while RSP was still on the interrupted stack. Read them together, as
        3.2.5 says: separately neither proves a stack switch.

        WHY THE 8259 WAS STILL ALIVE WHEN THIS WAS WRITTEN, AND WHY THAT WAS THE
        RIGHT ANSWER THEN. Once SVR bit 8 is set the CPU no longer takes the 8259
        on its own INTR pin -- the chip arrives through LINT0. So `lapic_init`'s
        masked LINT0 stopped IRQ0 dead, the timer stopped, and the scheduler
        stopped with it; the kernel hung after "preemption is on" and the boot
        gate caught it. LINT0 is deliberately put BACK into ExtINT, which is what
        Linux does for the BSP over exactly this window. Until the IOAPIC was
        brought up in this same box the 8259 was the only interrupt source this
        kernel had, and disabling it would have been disabling interrupts.

        AND LINT1 IS THE NMI SOURCE for the same class of reason, found the same
        way: masking every LVT made 3.2.5's own IST slot unreachable, and
        `inject-nmi` produced nothing at all. A blocked NMI is indistinguishable
        from hardware that never raised one, so only a live injection finds it.
        The rule the two together produced, and which this module now follows:
        `lapic_init` masks what nothing is ready to take, and every line this
        kernel DOES depend on is programmed back BY NAME afterwards.

        WHAT WAS NOT DONE WHEN THE LAPIC HALF LANDED, and has been since. 4.1
        answered the table half: the IOAPIC's address is KNOWN (0xFEC00000, GSI
        base 0), IRQ0's override to GSI 2 is known, and the MADT's PCAT_COMPAT
        bit is firmware AGREEING that the 8259s must be disabled before the
        IOAPIC is used. The doing was this box's own and it is done: the page is
        punched out of the physmap, mapped strong-UC and written, GSI 2 carries
        IRQ0, the spurious vector 0xFF is installed in the IDT unconditionally,
        and `lapic_eoi` -- armed by `idt_set_eoi_lapic` -- retires every
        interrupt the IOAPIC delivers. What is still not done: no LAPIC timer,
        so the 8254 still drives preemption; no IPIs and no second core. The
        rest is under WHAT IS NOT DONE above.

        ONE HAZARD FOUND AND CLOSED. `lapic_init` wrote CMCI (0x2F0)
        unconditionally; that register exists only where VERSION bits 23:16
        report at least 6 LVT entries, and this machine reports 5. QEMU tolerates
        the write and a real part need not. Guarded on `lapic_max_lvt`, and the
        guard was watched failing: removing it produces 2 mismatches.

  *  [x] 3.4 Physical Memory Manager (PMM)

        Validation: Fortran parses the UEFI memory map and tracks free/used memory pages (e.g., via a bitmap).

        DONE for BOTH maps as of 0.3. This box's own wording -- "parses the UEFI
        memory map" -- is satisfied literally now: `collect_efi` reads the
        EFI_MEMORY_DESCRIPTOR array and feeds the same bitmap this box's
        Multiboot2 path always did, through the same region table and the same
        asymmetric rounding. The trace below is the tag-6 path on the BIOS boot;
        the tag-17 path prints the same shape with a different map and reports
        which front end ran. On COM1, from the shipped image with the mandated
        6 vCPU / 24 GB VM:

            PMM  ID BASE               END                TYPE
            PMM  01 0x0000000000000000 0x000000000009FC00 AVAILABLE
            PMM  02 0x000000000009FC00 0x00000000000A0000 RESERVED
            PMM  03 0x00000000000F0000 0x0000000000100000 RESERVED
            PMM  04 0x0000000000100000 0x00000000BFFE0000 AVAILABLE
            PMM  05 0x00000000BFFE0000 0x00000000C0000000 RESERVED
            PMM  06 0x00000000FEFFC000 0x00000000FF000000 RESERVED
            PMM  07 0x00000000FFFC0000 0x0000000100000000 RESERVED
            PMM  08 0x0000000100000000 0x0000000640000000 AVAILABLE
            Fortran Kernel: PMM frames total/free/unmanaged-bytes 0x5FFF7F/0x5FFD6C/0x0
            Fortran Kernel: PMM reserved and ACPI frames are all marked used.
            Fortran Kernel: PMM locked the kernel image and the loader map out.
            PMM  ALLOC 0x0000000000001000 ... 0x0000000000005000
            Fortran Kernel: PMM allocated 5 distinct, aligned frames.
            Fortran Kernel: PMM freed and reclaimed the same 5 frames.
            Fortran Kernel: PMM refused a double, unaligned and locked free.
            Fortran Kernel: PMM rewound its scan cursor to a freed frame.

        THE NUMBERS ARE THE PROOF, AND THEY ARE LIVE. 159 + 786144 + 5505024 =
        6291327 = 0x5FFF7F frames, which is the three AVAILABLE regions rounded
        INWARD. The 531 used are the kernel's 530 -- 0x100000 to 0x312000
        rounded OUTWARD, frames 256 to 785 -- plus frame 0. Booting the SAME
        IMAGE at -m 4G gives 0x0FFF7F, and at -m 2G gives 0x07FF7F and SEVEN
        regions rather than eight -- QEMU emits no above-4 GiB entry at all. A
        table of constants cannot do that; this is 1.2's "word 3 is computed at
        run time" argument, for a data structure instead of a scalar.

        `src/mm/fk_pmm.f90`. One bit per 4 KiB frame, 0 = free, 1 = used, in a
        2 MiB .bss array covering 64 GiB. STATIC and not placed in discovered
        RAM, which is what a real kernel does: placing it needs a writable
        mapping for an arbitrary physical address, and that is 3.5. The price is
        a ceiling, and memory above it is COUNTED and REPORTED
        (`pmm_ignored_bytes`) rather than silently dropped -- a PMM that quietly
        forgets a third of the machine is indistinguishable from one that works.
        NOLOAD, so it costs zero image bytes and one rep-stosq in boot.S; the
        static gate reads the sizes back out of the linked ELF and asserts the
        last PT_LOAD carries it as MemSiz and not FileSiz.

        THE INIT ORDER IS THE SAFETY PROPERTY, and every step of it is a
        mutation in docs/HARNESS-VALIDATION-PHASE3.md:

          1. EVERY BIT SET. .bss arrives zeroed, which for this array means "the
             whole address space is free RAM" -- ACPI tables, MMIO apertures and
             the holes between them. The safe default has to be established, not
             inherited, and before any path that can return early.
          2. clear the type-1 regions, rounding INWARD.
          3. set every OTHER region, rounding OUTWARD. A separate pass, strictly
             after 2: maps with overlapping entries exist, and one pass would let
             entry ORDER decide whether reserved memory is allocatable.
          4. set [__kernel_phys_start, __kernel_phys_end).
          5. set the MBI's own extent -- it is in memory GRUB reported as
             AVAILABLE, correctly, and the parser is still reading it.
          6. set frame 0, so 0 is an unambiguous out-of-memory answer and never
             also a valid address.

        The rounding is ASYMMETRIC and that is the whole point: available rounds
        inward, unusable rounds outward, so both directions err towards not
        allocating. A symmetric rule has to be wrong in one of them.

        WHAT GRUB DID THAT NO PLAN ANTICIPATED. The MBI came back at physical
        0x103540 -- INSIDE the kernel's own span, in the 0xB10-byte alignment gap
        between the first and second PT_LOAD. The relocator tucked its structure
        into a hole in the middle of the loaded image. Reserving the file-backed
        ranges instead of the whole __kernel_phys_start..__kernel_phys_end span
        would have handed out the frame holding the memory map being parsed. It
        also bounds what the boot gate proves: step 5 is masked on this hardware
        and only the host suite tests it independently.

        `boot/ksyms.S` -- fk_kernel_phys_start/_end. linker.ld's symbols are
        ABSOLUTE: the VALUE is the address and there is nothing stored there to
        read. Fortran cannot name such a thing -- a bind(c) module variable
        DEFINES a symbol rather than importing one, and would hand the PMM the
        address of four bytes of .bss. So the value is moved into RAX as an
        immediate, and linkscript-test.sh disassembles the accessor and compares
        that immediate against nm. Nothing else can: a wrong constant marks the
        wrong frames used and every console verdict still prints PASS.

        THE OUT-OF-MEMORY PANIC IS RAISED BY THE CPU. `pmm_alloc_page` returns 0
        and the caller decides; kernel_main prints the allocator's state and then
        executes INT3 in boot/faultgen.S, so vector 3 reaches the same catcher
        every hardware fault does and the register dump is the machine's own.
        FK_FAULT_MODE = -1 drains the PMM to prove it, and does so:

            Fortran Kernel: PMM handed out 0x5FFD6C frames before it refused.
            *** PMM OUT OF MEMORY ***
            EXCEPTION 0x03 ERR 0x0000000000000000 -- #BP Breakpoint
            RBX = 0x00000000005FFD6C   RBP = 0x00000000005FFF7F

        0x5FFD6C is exactly the free count printed at init, and it is in a
        register because the CPU was holding it.

        WHAT IT COST. gcc's loop-distribution pass rewrites a DO loop that stores
        one value across an array into a call to MEMSET -- an undefined symbol
        until 1.3. Measured, not guessed: the 262144-word bitmap fill emits
        `U memset` at -O2 and nothing with -fno-tree-loop-distribute-patterns,
        which is now in mk/kflags.mk. It is the Fortran half of what
        -ffreestanding does for C. Every earlier fill in this tree was four
        elements long, which is why it took until now.

        And it exposed a gate carrying a stale fourth copy of KFLAGS:
        tools/linktest.sh transcribed the flag list instead of reading
        mk/kflags.mk, so it missed the new flag and reported the PMM as
        libc-dependent in a module the real build links clean. It reads the file
        now, the way linkscript-test.sh already did.

        PROVEN, at four levels, and the mutation tables are in
        docs/HARNESS-VALIDATION-PHASE3.md. `build/run-pmm`: 746 checks against a
        reference bitmap built from the specification, compared BIT FOR BIT
        against fk_pmm_bitmap itself -- the array is bind(c) so the diff is with
        the real thing and not with an accessor that could agree with a wrong
        bitmap. 16 injected defects, 16 refused. `linkscript-test.sh`: 7 new
        static checks. The boot gate: six verdict lines, each with a FAIL twin
        the gate REJECTS. `mutate-phase3.sh`: M14-M20.

        THREE ESCAPES OF THE FIXTURES, RECORDED BECAUSE THEY WERE MINE, and
        all three are the same mistake wearing different clothes -- a test whose
        interesting case was masked by something else being right.

          * H6: the overlapping-reserved region sat inside the kernel image
            span, so the kernel marking covered it and deleting the ENTIRE
            reserved-wins pass changed nothing. The fixture moved to 16 MiB.
          * M18: the five-frame reclaim test allocates frames 1-5, which share
            ONE 64-bit bitmap word, so the scan cursor never moves and a free()
            that never rewinds it still passes. kernel_main now takes 96 frames
            first and asks for the first one back, under its own verdict.
          * HE: an allocator that forgets to set the bit made an unbounded drain
            loop spin for ever instead of failing. Both drains are bounded now,
            here and in the host suite.

        And one mis-aimed mutation, which is the same class again: M16's
        substitution matched pmm_init's CLEANUP fill instead of pmm_build's,
        because the two are byte-identical for six lines and the cleanup comes
        first in the file. It reported an escape that did not exist. The anchor
        now reaches as far as `cursor`.

        AND ONE DEFECT NO BOOT CAN SEE, which is why boot/ksyms.S has a static
        check of its own. M20 replaces the accessor's immediate with 0: the
        locked span becomes [0, __kernel_phys_end), which covers MORE than the
        real one, so nothing reserved becomes allocatable, first-fit simply
        starts higher, and all six verdicts print PASS on a running machine.
        Only the disassembly disagrees. This is 3.2.5's M10 again -- the kernel
        can only report what it believes.

        WHAT THIS DOES NOT PROVE. The reserved-wins pass has no boot-gate
        coverage at all: QEMU's map has no region of one type inside a region of
        another, so it flips no bits on this machine and is host-proven only.
        Nothing is ever WRITTEN to an allocated frame -- the PMM hands out
        addresses, and 0x100000000 is a perfectly good answer that this kernel
        cannot map until 3.5. And no page is a page yet: these are frame numbers
        until the VMM gives them virtual addresses.

  *  [x] 3.5 Virtual Memory Manager (VMM)

        Validation: 4-level Page Tables (PML4) are constructed in Fortran, mapping virtual addresses to physical addresses.

        WHAT 3.4 HANDED IT, AND WHAT IT OWED 3.4 BACK. `pmm_alloc_page()` is the
        page-table allocator: every PML4/PDPT/PD/PT this milestone builds comes
        out of it. In return the VMM had to unblock three things 3.4 wrote down
        as limits -- a mapping for frames above the 1 GiB identity window, so an
        allocation up there becomes memory rather than a number; a guard page
        below the boot stack, which abutted the PMM bitmap with zero slack; and
        the unmapping of PML4[0], after which `pmm_init` can no longer read the
        MBI at its physical address (it must run first, and it checks that it
        can). All three are paid.

        DONE. `src/mm/fk_vmm.f90`, and this is what the machine printed off its
        own tables before it loaded one of them into CR3:

            VMM  SECTION  VIRT               PHYS               PERM
            VMM  .mbhdr  0xFFFFFFFF80100000 0x0000000000100000 R--
            VMM  .text   0xFFFFFFFF80101000 0x0000000000101000 R-X
            VMM  .rodata 0xFFFFFFFF80105000 0x0000000000105000 R--
            VMM  .data   0xFFFFFFFF80107000 0x0000000000107000 RW-
            VMM  .bss    0xFFFFFFFF80108000 0x0000000000108000 RW-
            VMM  .bootpt 0xFFFFFFFF80311000 0x0000000000311000 RW-
            Fortran Kernel: VMM PML4/table-frames/physmap-top 0x1000/0x21/0x640000000

        Every field in that table is read back out of the hierarchy by
        `vmm_translate`, not remembered from what was asked for, and the PERM
        column is decoded from the live entry's RW and NX bits. 0x21 = 33 frames
        is not a round number, it is the exact one: 1 PML4, plus 1 PDPT + 1 PD +
        2 PTs for a 2.08 MiB image that straddles one 2 MiB boundary, plus 1 PDPT
        + 25 PDs for a 25 GiB linear map, plus 1 PDPT + 1 PD for the transient
        identity window. Boot the same image at a different -m and the 25 moves.

        THE PERMISSIONS BITE, and that is a separate fact from setting them.
        CR0.WP is what makes a read-only PTE mean anything to ring 0 -- without
        it a kernel store ignores the bit entirely and .text mapped R-X is
        decoration. EFER.NXE is what makes bit 63 mean no-execute rather than
        RESERVED; set the bit without the MSR and every access to .rodata faults,
        which is mutation M25 and which triple-faults the machine. `boot/mmu.S`
        does both, checks CPUID.80000001H:EDX.NX first, and RETURNS whether it
        managed -- the VMM drops NX from every section rather than set a bit it
        was not promised.

        THE TWO HALVES FAIL DIFFERENTLY, AND THAT IS WHY THERE ARE THREE FAULT
        BUILDS AND NOT TWO. A broken NXE announces itself: the bit is reserved,
        so the first `.rodata` read faults and the machine dies at the handoff.
        A broken WP announces NOTHING. `.text` is still mapped R-X,
        `vmm_verify_image` still returns 0, the permission column still reads
        R-X, and a kernel store to `.text` simply succeeds. `fk_mmu_arm`'s return
        value only ever described the NX half, so the console line claiming
        CR0.WP was, until this was noticed, a claim with no witness anywhere in
        the tree. `FK_FAULT_MODE = -4` is the witness:

            Fortran Kernel: writing to .text, which only CR0.WP refuses (roadmap 3.5).
            EXCEPTION 0x0E ERR 0x0000000000000003 -- #PF Page Fault
            CR2     = 0xFFFFFFFF80101000

        `ERR 0x3` is the assertion and not the vector: bit 0 says the page was
        PRESENT and bit 1 says the access was a WRITE, so that is a protection
        violation and not a missing page. CR2 is `__text_start`. Mutation M27
        deletes the CR0 store and the write succeeds instead.

        WHY THERE IS A LINEAR MAP. A page table is written through a VIRTUAL
        address and the PMM hands out physical ones. While the boot stub's
        identity window is live that distinction does not exist; the instant
        PML4[0] is zeroed, a VMM with no other window can never touch a page
        table again -- it maps one set of pages, once, and is then bricked.
        FK_VMM_PHYSMAP at 0xFFFF800000000000 covers every byte of RAM the loader
        reported, in 2 MiB pages, and `vmm_phys_to_virt` is the single place that
        knows which window is current. It is also 3.4's debt closing: a frame at
        0x100000000 is allocated, mapped at a scratch address with
        `vmm_map_page`, written through THAT address and read back through the
        LINEAR one. Two virtual addresses agreeing on one physical frame is a
        mapping; one address agreeing with itself is a store.

        THE GUARD PAGE IS RESERVED IN linker.ld, not carved out of a neighbour,
        and 3.2.5's note about the PMM bitmap being "strictly better and nobody's
        design" is why: there was no slack to carve. `__boot_stack_guard` is a
        4 KiB frame of its own directly below the boot stack -- the object under
        the guard is whatever the link order leaves last, which is why the gate
        PRINTS that neighbour -- and `tools/linkscript-test.sh` asserts that no
        .bss object overlaps it --
        the one property a linker script cannot check about itself.

        PROVEN BY FAULTING, with the address taken from the ELF rather than
        written down. A build with `FK_FAULT_MODE = -2` reads
        `__boot_stack_bottom - 8`:

            Fortran Kernel: reading the guard page below the boot stack (roadmap 3.5).
            EXCEPTION 0x0E ERR 0x0000000000000000 -- #PF Page Fault
            CR2     = 0xFFFFFFFF8030CFF8

        `tools/mutate-phase3.sh` computes that CR2 with `nm` on the image it just
        built, so a relayout moves the expectation with the guard rather than
        turning the assertion into a comparison of two stale constants. CR2 is in
        the panic dump for this milestone; before 3.5 the dump could name the
        instruction that faulted but not the address it faulted on.

        VERIFIED BEFORE IT WAS TRUSTED. `vmm_verify_image` walks every page of
        the image in the hierarchy that is about to become live and compares
        BOTH the permission bits and the frame -- a page mapped read-only to the
        wrong physical address passes a flags-only check. It runs before CR3 is
        touched, because a kernel that maps its own .text wrong does not report
        it, it triple-faults, and a machine that reboots says nothing at all.

        THE ALIAS, WHICH IS PERMANENT AND IS NOT WHAT THE PERM COLUMN SAYS.
        The linear map covers every byte of RAM the loader reported, and the
        kernel's own frames are RAM -- so this image is mapped TWICE for the life
        of the kernel: strictly at KERNEL_VMA, and RW+NX at
        FK_VMM_PHYSMAP + phys. `.text` is therefore writable through the linear
        alias, permanently. The W^X lines the boot gate asserts are true of the
        six rows it prints and of nothing else; they say no page of the KERNEL
        WINDOW is both writable and executable, not that no alias of those frames
        is writable. This is the same trade Linux's direct map makes, and the
        same one it later had to spend `set_memory_ro` on. Narrowing it means
        either excluding the image from the linear map or re-mapping its frames
        there read-only, and neither is this pass.

        Two smaller costs. During the handoff -- the four console lines between
        `vmm_activate` and `vmm_drop_identity` -- there is a THIRD mapping, the
        transient identity window, also writable. And the two frames that window
        costs (its PDPT and PD) are never returned to the PMM when PML4[0] is
        zeroed; there is no unmap path to return them with.

        WHAT THIS DOES NOT PROVE. The linear map's extent follows the highest
        AVAILABLE region the loader reported, so MMIO ABOVE the top of RAM is in
        no window at all once PML4[0] is gone. THE LAPIC IS NO LONGER AN EXAMPLE
        OF THIS: 3.3 reserves 0xFEE00000 out of the physmap before it is built
        and maps it strong-UC at FK_VMM_LAPIC, so it is deliberate rather than
        accidental on any size of machine. THE IOAPIC IS NO LONGER ONE EITHER,
        and 3.3 had to reach it the other way round: its address comes out of an
        ACPI table, too late for `vmm_reserve_mmio`, so the page is PUNCHED out
        of the physmap after the map exists and mapped strong-UC, for exactly
        the reason the LAPIC did.

        AND vmm_reserve_mmio HELD ONLY ONE SPAN UNTIL 3.3, which is a defect
        this box shipped and did not know about. The framebuffer was the sole
        aperture, so one was enough; the LAPIC is the second caller and silently
        OVERWROTE the first, leaving a write-back alias of whichever device lost.
        It is a list of four now, refusing beyond the last slot rather than
        dropping one silently, and the boot prints how many holes were punched. The same map covers the PCI hole and the VGA aperture as
        write-back 2 MiB pages; on real hardware the MTRRs mark those UC and UC
        wins, so it is very likely benign, but nothing here states it as a
        requirement.

        The boot gate's "frame above 4 GiB" line also makes the mandated -m 24G
        allocation load-bearing: on a smaller machine `pmm_alloc_page_from`
        returns 0, the kernel prints the "no RAM above 4 GiB" line instead, and
        the gate fails a kernel that is behaving correctly.

        Nothing runs in ring 3, so the U/S bit is
        clear everywhere and untested. CR4.PGE is off and no entry is global, so
        the "reload CR3 flushes everything" assumption is currently exact and
        would stop being so the day global pages arrive. `vmm_map_page` REFUSES
        to shatter a large page rather than doing it, so nothing may be mapped at
        4 KiB inside the linear map's 2 MiB range. There is no unmap and no
        reference counting: a page table, once allocated, is never freed. The
        framebuffer was not mapped by THIS milestone -- 2.2 asked for
        write-combining attributes and 3.5 deliberately did not touch it; 2.2 has
        since mapped it with `vmm_map_mmio` at FK_VMM_MMIO, write-combining, with
        its write-back alias punched out. And the
        linear map covers MMIO holes as ordinary write-back memory because it
        maps [0, top) rather than the AVAILABLE regions; nothing dereferences
        those addresses today, and the day something does, it wants PCD/PWT.

  *  [x] 3.6 The Kernel Heap

        Validation: a Fortran allocator hands out arbitrary-sized blocks of kernel
        memory and takes them back, on top of the PMM's frames and the VMM's
        mappings.

        DONE. `src/mm/fk_heap.f90` is an implicit list with BOUNDARY TAGS: every
        block carries its own size and its PREDECESSOR's, so kfree finds the
        block below it in constant time and coalesces both ways. Without the
        back tag, freeing in ascending address order leaves the heap in N
        fragments no later allocation can merge -- and a fragmented kernel heap
        fails long after the code that caused it has returned.

        A FREE LIST WOULD BE FASTER TO SEARCH and is deliberately absent: a list
        threads pointers through free blocks, so a use-after-free corrupts the
        allocator's own structure and the failure lands in an unrelated kmalloc.
        The implicit walk keeps every pointer inside the header, which is what
        lets `heap_check()` verify the whole heap TILES ITS WINDOW EXACTLY --
        and it runs on every boot, not only in the test.

        WHERE THE PAGES COME FROM IS NOT THE ALLOCATOR'S DECISION. It calls
        `heap_sbrk(bytes)`, which must map that many bytes immediately above the
        window it already has and return the address, or 0. The kernel
        implements it out of PMM frames and VMM mappings at FK_VMM_HEAP
        (PML4[258]); a host test implements it out of one large allocation.
        That boundary is what makes a block allocator testable at all.

        AND IT STAGES EVERY FRAME BEFORE MAPPING ANY OF THEM, because there is
        no `vmm_unmap`: a growth that failed halfway would otherwise leave pages
        mapped that the heap never learns about and frames the PMM has handed
        out that nothing can return, while still reporting failure. The staging
        array is also the cap -- 512 pages, so 2 MiB is the largest single
        kmalloc this kernel serves, stated rather than discovered.

        The boot exercises eight sizes straddling every boundary, checks
        alignment and non-overlap against the size the ALLOCATOR reports (not
        the size that was asked for), writes a per-block pattern and reads every
        block back after all of them are written, frees in an order that is not
        the allocation order, and requires:

            heap tiles its window exactly, blocks/used/free 0x00000001/0x00000000/0x00042000
            heap coalesced every freed block back into one, largest free 0x0000000000042000

        That "blocks 0x00000001" is the line worth reading twice. Every other
        heap verdict -- alignment, non-overlap, patterns, the guards -- passes
        on an allocator that never merges anything.

        NOT PREEMPTION-SAFE, and 3.7 runs after it for that reason. Nothing here
        takes a lock, so kmalloc from an interrupt handler or from two threads
        at once will corrupt the block list. Today the rule is that only the
        boot thread allocates and it stops before `sched_start`; a real lock is
        still owed, and belongs to whatever first allocates outside the boot path.

        NOT THE SAME PROBLEM AS DMA MEMORY, which 5.1 and 5.3 need and which this
        box declares rather than solves as a heap. An xHCI ring and an NVMe submission
        queue must be PHYSICALLY CONTIGUOUS, aligned, and known by their
        physical address to a device that does not use the CPU's page tables. A
        general heap gives none of those three. What 3.5 made easy is the
        conversion -- the linear map means virtual-to-physical for any heap
        address is a subtraction -- so the DMA allocator is a thin thing over
        `pmm_alloc_page`, not a second heap.

        ITS INTERFACE IS NOW DECLARED HERE, AND ONLY DECLARED.
        `pmm_alloc_contiguous(pages)` answers with a physical base or 0, and it
        sits beside `heap_sbrk` because that is the other boundary this file
        draws and fk_heap_m is the module a driver already USEs when it wants
        memory. Page granularity is the whole alignment argument: a frame is
        4096-byte aligned and every structure that will ask for this wants less
        -- 64 bytes for an xHCI ring segment, its DCBAA and its ERST, one page
        for an NVMe queue. What it does NOT promise is a run clear of a 64 KiB
        boundary, which a TRB's data buffer may not cross
        (vendor/linux-7.1.8/drivers/usb/host/xhci.h:1265).

        IT IS NOW DEFINED, in the PMM, because the bitmap is the PMM's. First
        fit scanned as WORDS: a full word cannot contribute to a run, so it is
        skipped rather than having its 64 bits tested. A clear bit is by
        construction usable RAM -- pmm_init marks the whole bitmap used and
        clears only AVAILABLE regions -- so a contiguous run of clear bits is a
        contiguous run of frames and needs no second check against the region
        table. It still answers with a PHYSICAL base; `vmm_phys_to_virt` was
        already public and is the one call that gives the CPU-side address, so
        nothing new was needed to get it. `pmm_free_contiguous` hands a run back
        through the checked single-frame path and refuses at the FIRST bad
        frame, which leaves the rest allocated rather than half-released.

        THE TEST IS WHERE THE MILESTONE ACTUALLY WAS. Its first version passed
        against five deliberate defects, because on a freshly initialised bitmap
        every free frame is adjacent to the next and almost any wrong answer is
        accidentally right. Five mutations were run and five survived. Three
        cases fixed it:

            fragmented pool  sixteen frames taken and every other one given
                             back, so no run of four exists in that region at
                             all -- kills an implementation that never restarts
                             its run counter (9 mismatches).
            exact gap        a hole of EXACTLY twenty frames with used frames on
                             both sides and nothing before it that could hold
                             the run, so the correct answer is one address and
                             not a range -- kills an allocator that answers with
                             the run's END and marks forward from there, which
                             every other check tolerates because past the end
                             the frames happen to be free too (1 mismatch).
            full word        ten free frames ending at a bitmap word boundary, a
                             whole used word after it, ten more free beyond, and
                             a request for fifteen -- kills a scan that skips a
                             full word without breaking the run, joining the
                             frames on either side of sixty-four used ones (2
                             mismatches).

        A sixth mutation, removing a cursor update inside mark_run, changed
        nothing -- and that was correct: the cursor is a lower bound on where a
        free frame can be, marking frames USED can only make that bound more
        true, and a run cannot start below it. The line and its confident
        comment were deleted.

        AND THE BITMAP IS NOT THE PROOF. It can only testify about itself.
        dma_bringup writes one word into each frame of a four-frame run, derived
        from that frame's own index, through the linear map; `qmp-sentinel.py
        dma` then pmemsaves pages*4096 bytes at the PHYSICAL base the kernel
        published, with no page table consulted to reach it:

            PASS  the run's physical base is 0x6E000
            PASS  all 4 frames carry their own tag at the physical base

        That gate was made to refuse before it was trusted to pass. dma_bringup
        was mutated to write the same four tags at a stride of two frames and
        the whole boot test exited 1, with frame 1 reading a fragment of the
        framebuffer's leftovers and frame 3 reading zeros -- which is what a
        wrong physical address looks like from outside a guest.

        STILL NOT PROMISED, and the caller's problem: a run clear of a 64 KiB
        boundary.

  *  [x] 3.7 Tasks, context switching and a round-robin scheduler

        Validation: two kernel threads run alternately, switched by the 8254
        timer, and both are observed running from outside the guest.

        NOT PREVIOUSLY A BOX. The Lead Architect's directive numbers this "4.0";
        it is filed in Phase 3 because it is CPU state management and has
        nothing to do with Phase 4's buses. The roadmap's own 3.3 remains the
        Local APIC and was not touched.

        THE CONTEXT SWITCH IS ONE INSTRUCTION. `irq_handler` now RETURNS an RSP
        and `irq_common` loads it before POP_GPRS. A task's registers are
        already saved -- PUSH_GPRS put them on that task's own stack before the
        handler ran -- so switching is answering the interrupt with a DIFFERENT
        frame address. There is no save routine, no restore routine and no
        second code path: a switch is the ordinary path with a different answer.

        WHICH MEANS A NEW TASK NEEDS A FRAME IT NEVER PUSHED. `sched_spawn`
        builds one by hand at the top of a static per-task stack, byte-identical
        in layout to what the stub pushes. Three fields are load-bearing and all
        three are silent when wrong:

          RFLAGS = 0x202. Bit 9 is IF; a task started with it clear takes no
          timer interrupt, is never preempted, and the round robin stops on it
          -- the machine looks hung with every other verdict still passing.
          Bit 1 is architecturally always 1.

          RSP is one quadword BELOW the top, and that quadword holds the address
          of `fk_cpu_halt`. SysV wants rsp % 16 == 8 at function entry because a
          CALL has just pushed a return address -- but nothing called a task,
          IRETQ jumped to it. A real return address there fixes the alignment
          AND catches a task body that returns.

          CS/SS are the kernel selectors. IRETQ reloads both; a zero SS is a #GP
          on the first interrupt that tries to push onto this stack.

        STACKS ARE STATIC, NOT kmalloc'd, and that is a testing decision: a
        scheduler proof that fails when the allocator is wrong tells you neither
        of the two things you wanted to know.

        THE TSS IS THE OTHER HALF. `tss_set_rsp0` is called on every switch,
        because RSP0 is per-TASK: a stale one delivers the next trap from user
        mode onto a stack another thread is using. Nothing runs in ring 3 yet,
        so this is the mechanism being put in place rather than one being used
        -- and it is therefore the one thing here that is silent when broken,
        which is why the gate reads RSP0 back out of the TSS over QMP and
        requires it to equal the top of a SPAWNED task's stack, computed from
        the `fk_task_stacks` symbol in the ELF.

        RING 3 ITSELF IS NOT DONE and is not claimed. There are no user
        segment descriptors in the GDT and nothing to run there; adding them
        without a userspace would be untestable code.

        THE PROOF IS NOT THE CONSOLE OUTPUT. Two threads print alternating
        characters to the GOP renderer, but the assertion is two counters that
        only the THREADS increment, read TWICE while the guest runs:

            task 2 ran 49 -> 53 times (its own loop counter, not the scheduler's)
            task 3 ran 48 -> 53 times

        A scheduler that switches away once and then sticks produces non-zero
        counters, prints every serial verdict in this box, and fails that.

## 🔌 Phase 4: The Bus & Subsystems

Discovering what hardware actually exists on the Minisforum motherboard.

   * [x] 4.1 ACPI & MADT Parsing

        Validation: Fortran parses ACPI tables to find all CPU cores and APIC addresses.

        DONE, on both firmware paths, and the milestone exists for one number:

            Fortran Kernel: MADT overrides/IRQ0-GSI 0x0005/0x0002

        IRQ0 IS overridden, to GSI 2. Nothing can program an IOAPIC redirection
        entry for the timer without knowing that, and 3.3 is where it gets used.

        `src/acpi/fk_acpi.f90` (554 checks) finds the RSDP in Multiboot2 tag 15
        and falls back to tag 14, validates both checksums, and walks the XSDT
        or the RSDT. `src/acpi/fk_madt.f90` (25133 checks) decodes entry types
        0, 1, 2, 4 and 5, COUNTS what it skips rather than ignoring it, and
        answers `madt_gsi_for_irq`. Neither locates itself: both take a VIRTUAL
        address and read through it, which is the split that made fk_lapic
        testable at 3.3 and lets the host suite point them at ordinary memory.

        The whole topology, and the root differs by firmware exactly the way the
        PMM's front end does:

            ACPI root is the RSDT (Multiboot2 tag 14).   BIOS, 0x7FFE2525, rev 0
            ACPI root is the XSDT (Multiboot2 tag 15).   UEFI, 0x7FB7D0E8, rev 2
            MADT cpus total/enabled/skipped 0x0006/0x0006/0x0000
            MADT ioapics/first-addr/gsi-base 0x0001/0x00000000FEC00000/0x0000
            MADT overrides/IRQ0-GSI 0x0005/0x0002
            MADT NMI entries/LINT 0x0001/0x01
            MADT and IA32_APIC_BASE agree on 0x00000000FEE00000

        THAT LAST LINE IS THE ONLY ONE HERE THAT IS NOT THE KERNEL AGREEING WITH
        ITSELF: one address out of the MADT's header, one out of the MSR 3.3
        reads, checked against each other.

        AND TWO THINGS THE TABLES CONFIRMED THAT WERE ONLY REASONED BEFORE.
        Type 4 puts NMI on LINT1 for every processor -- which is exactly what
        3.3 configured, by argument, after an injected NMI went nowhere. And
        MADT flags bit 0, PCAT_COMPAT, is SET: firmware's own statement that the
        8259s are present and must be disabled before the IOAPIC is used, which
        is the sentence 3.3's box closed on.

        NO TEMPORARY MAPPING, which is a deviation from the directive and a
        simplification rather than a shortcut. 3.5's linear map already covers
        every byte of RAM the loader reported and the tables sit inside it on
        every configuration measured, so `acpi_init` reads through
        `vmm_phys_to_virt` and REFUSES anything at or above `vmm_physmap_top()`.
        That refusal is load-bearing and not decoration: at -m 2G the RSDT lands
        about 7 KiB below the top. It also avoids inventing an unmap path the
        VMM does not have.

        EVERY MULTI-BYTE FIELD IS ASSEMBLED BYTE-WISE, and that is forced.
        On the BIOS path the RSDT sits at physical 0x7FFE2525 -- not even
        4-byte aligned -- so its 32-bit table pointers are unaligned too, and
        MADT type 4 carries a u16 at ODD OFFSET 3. A typed array descriptor or a
        bind(c) derived type bakes in alignment that is not there. ACPI itself
        promises only 4-byte alignment for the XSDT's 64-bit entries.

        WHAT ADVERSARIAL REVIEW COST, six independent lenses over two modules:

          * A REAL DEFECT in fk_madt, found by TWO of them independently and
            reproduced as a SIGSEGV. The entry-walk guards were
            `off + elen > hlen` in signed 32-bit; hlen was accepted up to
            huge(int32), so the sum wrapped NEGATIVE under -fwrapv, the guard
            passed, and off indexed about 2 GiB BELOW the table. The guards
            SUBTRACT now -- off < hlen is the loop condition, so hlen - off is
            positive and no sum is formed -- and a 64 KiB length cap keeps every
            table-controlled offset far from the wrap point.
          * THREE TEST GAPS, each proved by a mutant that passed the suite
            unchanged: acpi_find's skip-past-an-unreachable-entry was never
            exercised, because every far pointer sat AFTER the last findable
            table; the ACCEPT side of the window bound was never checked, so
            widening the test from > to >= passed; and no fixture sat above
            4 GiB, so truncating the RSDP's 64-bit XsdtAddress to 32 bits
            passed -- which is the entire reason tag 15 is preferred over tag
            14. All three now fail on the mutant that used to pass.

        WHY THE NUMBERS ARE EVIDENCE. Every value above was FIRST read out of
        guest memory by an independent host-side walk of the same tables,
        written in Python and sharing no code with the Fortran: same roots, same
        MADT, same six CPUs, same IOAPIC, same five overrides, same type-4 NMI.
        Two implementations agreeing is worth more than one asserting.

        AND THE TABLES ARE LIVE. The same image at -smp 2 reports two CPUs and a
        128-byte MADT rather than six and 160 -- this is read, not remembered.
        `fk_acpi_topo` is a bind(c) record, so the topology is checkable from
        OUTSIDE the guest too: magic 'ACPIT', root 0x7FFE2525, 6 cpus, IOAPIC
        0xFEC00000, GSI-for-IRQ0 2, read back over QMP.

        WHAT IS NOT DONE. Nothing is programmed: this box ends at parse, store
        and print. The IOAPIC is not mapped or written here -- that was 3.3's
        doing, and it is what let 3.3 close. Only the FADT's signature is
        seen; nothing reads it. There is no AML interpreter and no _PRT, so PCI
        interrupt routing at 5.1 has only the ISO table to work from.

   * [x] 4.2 PCIe Bus Enumeration

        Validation: Kernel recursively scans the PCIe bus and prints a list of all connected devices (Vendor IDs / Device IDs) to the GOP display.

        THE BUS IS WALKED. `src/acpi/fk_mcfg.f90` (98 checks) finds the window
        and `src/drivers/bus/fk_pcie.f90` (74 checks) walks it. On q35:

            Fortran Kernel: the ECAM window has no write-back alias in the linear map.
            Fortran Kernel: the ECAM mapping selects PWT and PCD, strong uncacheable.
            Fortran Kernel: PCIe functions kept/seen 0x0005/0x0005
            Fortran Kernel: PCIe 0x00/0x00.0 0x8086/0x29C0 0x06/0x00/0x00
            Fortran Kernel: PCIe 0x00/0x01.0 0x1234/0x1111 0x03/0x00/0x00
            Fortran Kernel: PCIe 0x00/0x1F.0 0x8086/0x2918 0x06/0x01/0x00
            Fortran Kernel: PCIe 0x00/0x1F.2 0x8086/0x2922 0x01/0x06/0x01
            Fortran Kernel: PCIe 0x00/0x1F.3 0x8086/0x2930 0x0C/0x05/0x00

        AND THE LIST IS CHECKED AGAINST QEMU'S, AS SETS. Not containment:

            PASS  the guest found every function QEMU reports (5)
            PASS  and reported none QEMU does not

        A function QEMU reports and the guest missed is a hole in the walk. A
        function the guest reports and QEMU does not is a GHOST, and that is the
        one containment waves through -- a single-function device may alias
        function 0 across all eight, so a walk that ignores the header-type
        multifunction bit reports one device eight times and each looks
        entirely plausible. Device 0x1F is the case in the other direction: it
        is multifunction with functions 0, 2 and 3 present and 1 ABSENT, so a
        walk that stops at the first gap loses two real devices.

        THE GATE NOW BOOTS q35, and that is part of the milestone rather than a
        setting. QEMU's default i440FX board emits four ACPI tables and none of
        them is MCFG -- there is no ECAM window on it and there was nothing here
        to find. q35 emits five. `FK_MACHINE=pc` still reaches that path and the
        kernel treats it as a fact about the machine: it prints "no MCFG table;
        this machine has no ECAM window" and carries on. Both are gated, in
        opposite directions.

        THE EIGHT RESERVED BYTES ARE THE TRAP. PCI Firmware Specification 3.0
        section 4.1.2: the allocation array starts at offset 44 and not at 36,
        because `acpi_table_mcfg` puts a `u8 reserved[8]` after the standard
        header. A decoder that starts at 36 reads the base out of the reserved
        field, gets 0, and fails somewhere a long way from the cause. The base
        is a full u64 assembled byte by byte with the sign masked at every step:
        0xB0000000 has bit 31 set, and a widening that sign-extends puts the
        window 4 GiB away from where it is.

        NO BRIDGE RECURSION, and the validation sentence's word "recursively"
        is answered rather than dodged: the scan covers every bus the MCFG
        allocation declares, which is a SUPERSET of what walking secondary bus
        numbers reaches. Recursion would add code and no devices.

        `vmm_punch_physmap` does here what it did for the IOAPIC at 3.3 and for
        the same reason -- the window's address comes out of an ACPI table, and
        reading that table needs the linear map a reservation would have holed.
        4 KiB at a time, because `vmm_map_page` has no large-page path and
        `walk` refuses to shatter one: 65536 entries and about 512 KiB of page
        tables for a 256 MiB window.

        "MAPPED" AND "MAPPED UNCACHED" ARE TWO CLAIMS and both are asserted. The
        second is the one that matters: a cached mapping of configuration space
        reads a stale line for every device after the first, and would enumerate
        perfectly on the first boot and never again.

        ELEVEN MUTATIONS, ELEVEN CAUGHT. Against the decoder: entries at offset
        36 (37 mismatches), the base read as a u32 (1), the sign mask dropped
        (13), a backwards bus range accepted (2), the range treated as exclusive
        (11). Against the walk: all eight functions probed regardless of the
        header-type bit (3), stopping at the first absent function (13), the
        multifunction bit left in the header type (1), the device shift confused
        with the function shift (29), truncation hidden by clamping the seen
        count (3), the window bound check removed (1).

        THE DEBT THIS BOX LEFT IS PART PAID, and 5.1 is what came to collect.
        Configuration space is now WRITTEN as well as read -- one width, a
        whole dword, because `tools/mmiocheck.sh` refuses a narrow store as
        well as a narrow load. There is deliberately no write16: a 16-bit
        field written as a dword read-modify-write echoes the other half back,
        and at 0x04 that half is STATUS, whose error bits are write-1-to-clear.
        `pcie_cmd_enable` therefore writes the dword with the status half
        ZEROED, which a read-only bit ignores and a W1C bit is defined not to
        act on. `pcie_find_cap` walks the capability chain -- STATUS bit 4
        first, low two bits of every pointer dropped, an offset inside the
        64-byte header refused, and the chase bounded at 48 hops, because a
        chain that points at itself is a hung boot rather than a wrong answer.
        MSI-X is DECODED off that: capability offset, table size (encoded
        N-1), the BAR it lives in and its byte offset inside it.

        WHAT IS NOT DONE: no BAR sizing or assignment, no bridge secondary-bus
        programming, no MSI or MSI-X ENABLEMENT, and one segment group only.
        The kept list is capped at 64 (FK_PCIE_MAX_DEV) and
        `pcie_overflowed` says so rather than letting a truncated list read
        as a complete one; the copy kmain publishes over QMP carries the first
        32 of that list and no more.

        THE LAYOUTS THAT CAME FIRST. `src/drivers/bus/fk_pcie_types.f90`
        carries the Type 0 and Type 1 configuration headers, the capability list
        header, the MSI-X capability and one table entry, the ECAM shifts, BAR
        decode, and the class/subclass/prog-if triples that identify an xHCI and
        an NVMe. No procedures and no module state of its own: the scan is
        fk_pcie.f90's, and 4.2 landed it.

        Those offsets are a fact rather than a claim -- each taken from the
        specification, cross-checked against vendor/linux-7.1.8's pci_regs.h
        with the path and line beside it, and then MEASURED: a generated probe
        takes c_loc of every component of every type, subtracts the address of
        the type and diffs against the hand-computed table. Every reserved gap
        is a NAMED component, because padding the compiler chooses is padding
        the hardware does not have.

        STILL TRUE, and it is 5.1's and 5.2's problem now: interrupt routing for
        whatever is found has only 4.1's ISO table to work from. There is no AML
        interpreter and therefore no _PRT, so a PCI line's GSI cannot be looked
        up -- MSI or MSI-X is the way round it, and neither is written.

## 🛠️ Phase 5: Modern Drivers (The Crucible)

Writing complex Fortran state machines to talk to modern Minisforum silicon.

   * [x] 5.1 xHCI Controller (USB 3.0)

        Validation: Kernel initializes the xHCI controller found on the PCIe bus and establishes Ring Buffers in physical memory.

        THE REGISTER BLOCKS ARE IN, THE CONTROLLER IS UNTOUCHED.
        `src/drivers/usb/fk_xhci_types.f90` carries the capability, operational,
        port, runtime and interrupter blocks, the Event Ring Segment Table
        entry, and the 16-byte TRB in its generic form plus the six variants
        whose fields decompose differently. A command TRB IS the generic one --
        only the type field in the control dword distinguishes it -- so there
        are deliberately no per-command types. Measured the same way 4.2's were.

        Bit fields are POS/LEN pairs and single _BIT indices, never masks:
        `ibits(reg, POS, LEN)` already does the job, and a mask literal wide
        enough to cover bit 31 does not fit the signed c_int32_t the value is
        carried in. That is the unsigned rule this tree has applied since 1.1,
        arrived at from the register side.

        BLOCKED ON THREE THINGS WHEN THE LAYOUTS LANDED, AND ALL THREE ARE NOW
        PAYABLE. 4.2 finds the controller (`pcie_find_xhci`), 3.x defined the
        DMA allocator a ring needs, because a ring is read by a bus master that
        does not walk the CPU's page tables (`pmm_alloc_contiguous`, in the PMM
        -- see 3.6), and 4.2's debt has since been paid where this box needs
        it: the controller's memory-space decode and bus mastering are turned
        on by this kernel, and its MSI-X capability is found and decoded.

            Fortran Kernel: xHCI COMMAND firmware/cleared/enabled 0x0107/0x0101/0x0107
            Fortran Kernel: xHCI BAR0 0x00000000FEBF0000
            Fortran Kernel: xHCI MSI-X cap/entries/bar/offset 0x90/0x0010/0x0/0x00003000

        THE MIDDLE NUMBER IS THE MILESTONE, and it exists because the obvious
        assertion was measured ESCAPING. SeaBIOS leaves this controller at
        COMMAND 0x0107 -- decode and mastering already on -- so a kernel that
        writes nothing reads back exactly what a working one reads back, and a
        gate asserting "both bits are set" stayed GREEN with the enable call
        mutated away. The kernel therefore takes the two bits DOWN and puts
        them back, and 0x0101 is a reading only this kernel could have caused.
        The same mutation now fails twice: the sentinel sees 0x0107 -> 0x0107
        and the kernel prints its own REFUSED line, which is on the gate's
        reject list.

        THE ROUTE IS NOW WRITTEN TOO, and it is the first thing this kernel
        has ever put into a device's own memory rather than its configuration
        space. BAR0 is punched out of the linear map and mapped strong-UC at
        FK_VMM_XHCI; entry 0 of the MSI-X table is written MASKED, address then
        data, and unmasked LAST, which is PCI 3.0 6.8.3.5 and not style -- an
        entry unmasked halfway through sends a message built from two routes.
        Then MSIX_ENABLE with MASKALL cleared in the same write, and INTx off
        last, because a controller with neither a wire nor a message raises
        nothing at all.

            Fortran Kernel: xHCI BAR0 mapped strong-UC, virt/phys 0xFFFF808022000000/0x00000000FEBF0000
            Fortran Kernel: xHCI MSI-X entry 0 addr/data/mask 0xFEE00000/0x00000030/0x00000000
            Fortran Kernel: xHCI MSI-X control/command 0x800F/0x0507

        AND THE DEVICE AGREES, read from outside the guest. `xp` goes through
        QEMU's memory API, so it reaches configuration space through the ECAM
        window and the table through the BAR exactly as a guest access would --
        it is the device model's state, not the guest's account of it:

            PASS  QEMU's own COMMAND for the device is 0x0507: decode and bus mastering are on
            PASS  the capability reads 0x800F: MSI-X is ENABLED
            PASS  table entry 0 addresses 0xFEE00000, the APIC of CPU 0
            PASS  carries vector 0x30, and is UNMASKED (vector control 0x00000000)
            PASS  the guest's read-back agrees with QEMU's device model

        A BAR whose decode is off answers `Cannot access memory`, which is why
        that is an assertion here rather than a limitation.

        NO INTERRUPT HAS ARRIVED, AND NONE CAN YET. The controller has not been
        reset, its interrupter is not enabled and R/S is clear, so it has
        nothing to signal; `fk_msi_count` is 0 and no gate pretends otherwise.
        The vector is nevertheless installed BEFORE the route is unmasked --
        `idt_init` puts FK_VECTOR_MSI (0x30) in the IDT unconditionally, the
        same rule 3.3 applied to the spurious vector, because a vector the IDT
        does not describe is a #GP during delivery.

        AND THE CONTROLLER IS NOW UP, which is what this box was open on.
        `src/drivers/usb/fk_xhci.f90` resets it, gives it a Device Context Base
        Address Array, a command ring, an event ring and an ERST out of ONE
        contiguous run from 3.x's allocator, arms both interrupt gates, sets
        R/S, enqueues a NO-OP and reads the completion out of the event ring:

            Fortran Kernel: xHCI caplength/version/slots/scratchpads/page 0x40/0x0100/0x0040/0x0000/0x00001000
            Fortran Kernel: xHCI cmd/event/erst 0x0000000000348000/0x0000000000349000/0x000000000034A000
            Fortran Kernel: the xHCI is RUNNING, USBSTS 0x00000000
            Fortran Kernel: xHCI NO-OP trb/event/code/ptr 0x0000000000348000/0x21/0x01/0x0000000000348000
            Fortran Kernel: the xHCI executed a command and reported it complete (roadmap 5.1).
            Fortran Kernel: the xHCI's MSI-X interrupt ARRIVED, count 0x00000001

        Event type 0x21 is a Command Completion Event, code 0x01 is SUCCESS,
        and the pointer it carries is the address of the TRB that was
        enqueued. THE LAST LINE IS THE ONE THAT HAD NEVER HAPPENED BEFORE:
        every interrupt this kernel had taken until now came off a wire, and
        that one is a message the controller WROTE to the APIC's address.

        THE NUMBER THAT COST THE MOST WAS ERSTSZ. It counts SEGMENTS, and the
        first version wrote the segment's length in TRBs into it -- 256 on a
        controller whose HCSPARAMS2 allows one. The answer was not a refused
        write or a diagnostic: USBSTS came back 0x00001000, HCE, the host
        controller error bit, and nothing executed. The host suite had not
        caught it because the model read the segment's size from the ERST
        entry, which was right, and never looked at ERSTSZ at all; it does
        now, and refuses with the same HCE the silicon used.

        WHAT THE HOST SUITE IS, and it is not a register file. `test_xhci.c`
        implements the parts of an xHC the bring-up talks to: HCRST is
        self-clearing and returns the operational registers to their defaults,
        CNR is held for three reads, and ringing doorbell 0 EXECUTES the ring
        -- follows the cycle bit, follows the link TRB, toggles its own cycle
        state and posts a completion event. That is what makes the lap-two
        wrap assertable at all: a producer that never flips its cycle bit
        works perfectly for 255 commands and then goes silent, with no error
        anywhere, and only a model that wraps can see it.

        RINGS GO THROUGH fk_readl/fk_writel TOO. They are RAM, not registers
        -- but RAM a BUS MASTER writes, and gfortran narrowed the event TRB's
        control dword to a one-byte load the first time they were reached
        through a Fortran pointer. `tools/mmiocheck.sh` refused the object,
        correctly, and fk_xhci.o is on its list.

        NOT DONE, and none of it is in the way of 5.2: no slots are enabled,
        no device contexts, no transfer rings, no port reset and nothing on
        the wire. The scratchpad path is WRITTEN BUT UNEXERCISED -- qemu-xhci
        reports zero scratchpad buffers, so the array is never allocated on
        the machine the gate runs, and that is stated rather than hidden.

   * [x] 5.2 USB HID Keyboard Driver

        Validation: Physical keystrokes on a USB keyboard generate APIC interrupts, which Fortran translates to ASCII characters on the screen.

        DONE, and the validation line is satisfied on every clause. Keys are
        pressed from OUTSIDE the guest over QMP, arrive as MSI-X messages, and
        the characters come out of guest memory:

            USB port/portsc/speed 0x0005/0x00000E03/0x03
            USB slot/address/state 0x0001/0x01/0x03
            USB mps0/config/interface 0x0040/0x01/0x00
            USB EP1 addr/maxpkt/interval 0x81/0x0008/0x07

        MEASURED BEFORE IT WAS BUILT, and both measurements changed the design:
        usb-kbd on qemu-xhci lands on PORT 5 -- the USB3 ports are presented
        first -- and it enumerates at HIGH speed, so EP0's max packet is 64.
        A hardcoded port 1 finds nothing.

        WHAT IS NOT DONE. One device, one endpoint, one slot, and no hub: the
        route string is zero because nothing is behind a hub, and a second
        device would need a second slot the code does not allocate. Full and
        low speed are REFUSED rather than guessed at -- their bInterval is a
        frame count where high and super speed carry an exponent. There is no
        key repeat, no LED report and no SET_IDLE.

        AND THE BUG IT FOUND IN 5.1, which had nothing to do with the keyboard:
        the NO-OP poll took the FIRST event off the ring rather than the one
        naming its own TRB. With a device attached the controller also posts
        Port Status Change events, so that loop read a PSC event as a failed
        command -- intermittently, which is the worst way to find out. Before
        this milestone there was no device and nothing else to arrive.

   * [x] 5.3 NVMe Storage Controller

        Validation: Kernel identifies the NVMe drive, establishes Submission/Completion Queues, and successfully reads Sector 0 into a Fortran array.

        DONE, and the disk is the first ORACLE this project has had that exists
        outside the machine before the machine is switched on:

            NVMe cap/version/mqes/dstrd 0x004008200F0107FF/0x00010400/0x00000800/0x00
            NVMe cc/csts/aqa 0x00460001/0x00000001/0x00010001
            NVMe nsid 1 blocks/lba-bytes 0x0000000000000800/0x00000200
            NVMe sector 0 [0..15] 0x0706050403020100/0x0F0E0D0C0B0A0908

        The gate reads those 512 bytes at their PHYSICAL base and diffs them
        against the image file on the host, read at check time -- so there is no
        second copy of the expected bytes to drift.

        MEASURED FIRST: the controller is at 00:03.0 with class 01/08/02, which
        pcie_find_nvme already matched, and its BAR0 is at 0x680000000 -- ABOVE
        top-of-RAM. vmm_punch_physmap only punches below map_top and refuses
        anything overlapping RAM, so a high BAR needed no special case at all.
        THE PCI FUNCTION SET GREW FROM SIX TO SEVEN AND THE LIVE GATE DID NOT
        CHANGE: it compares the guest's list against `info pci` as SETS, so both
        sides grew together. Only qmp-sentinel's hardcoded fixture moved.

        THE ADMIN QUEUES ARE TWO ENTRIES ON PURPOSE. A completion queue's phase
        tag flips when the consumer wraps, and with a 64-deep queue and four
        admin commands the wrap NEVER RUNS -- a driver with inverted flip logic
        would pass every gate built on it. Two is the minimum the specification
        allows and it makes the ordinary bring-up wrap twice.

        WHAT IS NOT DONE: no host suite for fk_nvme (it needs a controller model
        of the kind tests/drivers/usb/test_xhci.c implements), no PRP list, no
        writes, one namespace, one I/O queue pair, and the disable path is
        unexercised because CC.EN is already 0 when the kernel first looks.

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
