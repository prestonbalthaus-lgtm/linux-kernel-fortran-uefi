
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

        2.1 EXTENDED IT, still without closing it: the harness now also attaches a
        serial chardev (`-serial file:`) and asserts what COM1 carried, so the VM is
        interrogated on two independent channels rather than one. `-bios OVMF.fd` is
        untouched by that, and remains what this box is waiting on.

        The MISSING half is `-bios OVMF.fd`. Today's harness boots the BIOS/GRUB path,
        which is what Multiboot2 is; the UEFI path that the Minisforum actually uses is a
        different first stage (linker.ld's header describes it) and is not exercised by
        anything yet. Do not read the current PASS as evidence about UEFI.

## ⚙️ Phase 1: The Boot Layer & Bare-Metal Runtime

Bypassing Fortran's reliance on the OS and successfully handing control from UEFI to the Fortran entry point.

  *  [ ] 1.1 The Core Library Translation (Completed)

        Validation: String manipulation and math modules exist without libgfortran.

        CAUTION -- THIS BOX IS OVER-TICKED. Only the MATH half was delivered:
        `src/lib/math/` has 7 modules plus `src/lib/fk_bcd.f90`. There are ZERO string
        handlers -- no strlen, strcpy, memcmp, memcpy. `docs/AUDIT-PHASE1.md` flagged this
        already: "Phase 1 delivered no string handlers ... any Phase 2 planning that
        assumes lib/string.c is already translated is working from a wrong inventory."
        Anything downstream needing string ops (the ELF loader at 6.4, VFS paths at 6.1)
        must translate lib/string.c first. Note 1.3 below needs memcpy/memset anyway, so
        that is where the debt gets paid.

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

  *  [x] 2.1 UART Serial Driver (Headless Debugging)

        Validation: Kernel can write strings to COM1 (0x3F8) using assembly outb wrappers. QEMU serial console outputs text.

        DONE, and the validation was met literally: the bytes were read coming out of
        QEMU's virtual COM1, not inferred from a gate's exit status.

            00000000  46 6f 72 74 72 61 6e 20  4b 65 72 6e 65 6c 3a 20  |Fortran Kernel: |
            00000010  55 41 52 54 20 53 65 72  69 61 6c 20 49 6e 69 74  |UART Serial Init|
            00000020  69 61 6c 69 7a 65 64 2e  0d 0a                    |ialized...|

        `boot/io.S` -- `fk_outb`/`fk_inb`, SysV AMD64, four instructions each. Port I/O
        is the SECOND of exactly two things in this kernel that must be assembly (the
        first is CLI/HLT): IN and OUT reach a separate 16-bit address space that no
        Fortran expression can name. Both carry `int32_t` rather than `uint16_t`/`uint8_t`
        because Fortran has no unsigned types -- 0xC7 in an int8 would have to be written
        -57 -- so the truncation is concentrated in two instructions instead of becoming
        a rule every caller has to remember.

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
        port trace byte for byte. `tools/qemu-boot-test.sh`: now asserts THREE things --
        the 1.2 sentinel, the banner on COM1, and the ABSENCE of the self-test failure
        line. `--smoke` shows both positive halves refusing a kernel-less guest.
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

        WHAT IT DOES NOT PROVE. IST1 only; ist2..ist7 are zero and no other vector
        asks for one, so NMI and #MC still arrive on the faulting stack -- fine
        while nothing raises them, and 3.3's problem the moment the APIC is live.
        There is no guard page below the emergency stack; that needs the VMM at
        3.5, and until then a runaway panic handler walks into whatever .bss put
        underneath.

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

        SUPERSEDED BY 3.4, AND ONLY BY LUCK. The PMM's 2 MiB bitmap is now the
        object directly below the boot stack -- with ZERO bytes of slack -- so an
        overflow corrupts the allocator instead of the TSS, and IST1 survives to
        catch the fault the overflow causes. That is strictly better and it is
        nobody's design: it is what the link order happens to be this week, which
        is exactly why linkscript-test.sh PRINTS the neighbour instead of
        asserting one. The guard page at 3.5 is still the fix. `tools/linkscript-test.sh` prints the neighbour and the slack
        on every run rather than asserting a link order. And the ONE boot exercises one IST index on one vector: see
        `docs/HARNESS-VALIDATION-PHASE3.md` for the mutation table, including the
        defects that got past it.

        A NOTE ON THE COMMITTED IMAGE. `kernel_main` raises exactly one deliberate
        fault, chosen by the `FK_FAULT_MODE` PARAMETER. 8 (#DF) is the default and
        the milestone. 0 (#DE) is NOT redundant: #DF carries a CPU error code and
        so only ever reaches the `ISR_ERR` half of `boot/interrupts.S`, leaving the
        dummy-push half that 3.2's M1 mutation targets unexercised. Both gates are
        driven from `tools/mutate-phase3.sh`, which rebuilds for each.

  *  [ ] 3.3 Advanced Programmable Interrupt Controller (APIC)

        Validation: Legacy 8259 PIC is disabled. Local APIC is mapped and active.

        HALF DONE by 3.2.5. The legacy 8259s are remapped clear of the exception
        range and fully masked, which is the "disabled" half and is asserted from
        the device model (`pic0/pic1: imr=ff irq_base=20/28`). Masking is not the
        same as the ICW3-less shutdown a system with a working IOAPIC does, and
        that is deliberate: it is reversible, and nothing yet exists to take the
        interrupts instead.

        The MISSING half is the Local APIC: it is not mapped, its spurious-vector
        register is untouched, and `info lapic` still shows LVT0 as ExtINT. That
        needs the MADT (4.1) to find the APIC base, and an IST for NMI before any
        of it is safe to unmask.

  *  [x] 3.4 Physical Memory Manager (PMM)

        Validation: Fortran parses the UEFI memory map and tracks free/used memory pages (e.g., via a bitmap).

        DONE for the MULTIBOOT2 map, which is the map this kernel is handed
        today; the UEFI wording is 0.3's outstanding half, not this box's. On
        COM1, from the shipped image with the mandated 6 vCPU / 24 GB VM:

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
            Fortran Kernel: PMM allocated 5 contiguous frames.
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
        docs/HARNESS-VALIDATION-PHASE3.md. `build/run-pmm`: 390 checks against a
        reference bitmap built from the specification, compared BIT FOR BIT
        against fk_pmm_bitmap itself -- the array is bind(c) so the diff is with
        the real thing and not with an accessor that could agree with a wrong
        bitmap. 16 injected defects, 16 refused. `linkscript-test.sh`: 7 new
        static checks. The boot gate: five verdict lines, each with a FAIL twin
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

  *  [ ] 3.5 Virtual Memory Manager (VMM)

        Validation: 4-level Page Tables (PML4) are constructed in Fortran, mapping virtual addresses to physical addresses.

        WHAT 3.4 HANDS IT, AND WHAT IT OWES 3.4 BACK. `pmm_alloc_page()` is the
        page-table allocator: every PML4/PDPT/PD/PT this milestone builds comes
        out of it. In return the VMM has to unblock three things 3.4 wrote down
        as limits -- a mapping for frames above the 1 GiB identity window, so an
        allocation up there becomes memory rather than a number; a guard page
        below the boot stack, which now abuts the PMM bitmap with zero slack; and
        the unmapping of PML4[0], after which `pmm_init` can no longer read the
        MBI at its physical address (it must run first, and it checks that it
        can).

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
