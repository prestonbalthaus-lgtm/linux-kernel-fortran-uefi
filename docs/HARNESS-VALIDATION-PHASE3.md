# Does the panic handler's test actually catch bugs?

The fifth time this question is asked, because roadmap 3.2 and 3.2.5 are the
fourth and fifth kinds of thing this tree has had to test.

* Phase 1 compared a Fortran function against **the C function it was translated
  from**.
* The GOP renderer had no C original, so it was checked against a **reference
  model written from the specification**.
* The UART driver's correctness was a **sequence of side effects**, so its test
  asserts the trace.
* The IDT's correctness is **what a machine says after it has already crashed**.
  There is no return value, no trace to compare, and no second chance: the code
  under test runs on a CPU whose last instruction faulted, on a stack frame the
  CPU built and the assembly rearranged.
* Roadmap 3.4 added a sixth: **a data structure derived from something the
  kernel did not write**. The memory map comes from GRUB, it is different on
  every machine, and the PMM's answer is 2 MiB of bits nobody can read off a
  console. That one is testable in a way none of the others were — the bitmap
  is `bind(c)`, so a host test can build its own from the same map and diff
  them bit for bit.
* Roadmap 3.2.5 added a fifth kind, and it is the awkward one: **state the
  kernel cannot report on itself**. A PIC whose ICW2 never reached the chip is
  invisible from inside — masking works whatever the vector base is, so the
  console still prints "remapped and masked" and means it. That is not a bug in
  the message; it is the limit of asking the defendant.

So the test is a boot, and since 3.2.5 the boot is interrogated on **three**
channels: guest memory over QMP, the bytes COM1 carried, and the state of the
CPU and the 8259s as the **device models** report them.

## The gate invocations

    tools/qemu-boot-test.sh                       # roadmap 1.2 + 2.1, unchanged

    FK_EXPECT_SERIAL=$'EXCEPTION 0x08 ERR 0x0000000000000000 -- #DF Double Fault\n*** #DF ENTERED ON IST1 -- THE EMERGENCY STACK HELD ***' \
    FK_REJECT_SERIAL=$'*** #DF ENTERED ON THE FAULTING STACK -- NO IST SWITCH ***\nFortran Kernel: the deliberate fault did NOT trap.\nFortran Kernel: 8259 PIC mask readback FAILED.' \
    FK_CHECK_HW=1 tools/qemu-boot-test.sh         # roadmap 3.2.5, the shipped image

    # roadmap 3.1 + 3.2, which needs the #DE build:
    sed -i 's/FK_FAULT_MODE = 8_c_int32_t/FK_FAULT_MODE = 0_c_int32_t/' src/boot/fk_kmain.f90
    ./tools/run.sh clean-boot && ./tools/run.sh iso
    FK_EXPECT_SERIAL="EXCEPTION 0x00 ERR 0x0000000000000000 -- #DE Divide-by-Zero Error" \
    FK_REJECT_SERIAL="Fortran Kernel: the deliberate fault did NOT trap." \
    FK_CHECK_HW=1 tools/qemu-boot-test.sh

`FK_EXPECT_SERIAL` and `FK_REJECT_SERIAL` are LISTS, one pattern per line: all of
the first must appear, none of the second may. That is not tidiness. The #DF
milestone's claim is two facts — the CPU reported a #DF, AND it did so on the
emergency stack — and a single-pattern gate lets the second one be dropped
silently, because the headline a #DF prints on a broken stack is identical right
up until the push that kills it. `tools/qemu-boot-test.sh --selftest` includes
that exact case: headline present, IST1 line absent, matcher must refuse.

Empty lines are stripped from both lists, because an empty pattern matches every
file and one stray newline would turn an assertion into a no-op that passes on
anything.

## Why there are two builds and not one

`kernel_main` raises exactly one deliberate fault, chosen by the `FK_FAULT_MODE`
PARAMETER, and both builds are needed:

* **#DF** (the default, and what ships) is the only way to reach the IST1 stack
  switch. But #DF carries a CPU error code, so it only ever enters the `ISR_ERR`
  half of `boot/interrupts.S`.
* **#DE** carries no error code, so it is the only way to reach the `ISR_NOERR`
  half — the dummy push that M1 below removes.

A PARAMETER rather than a variable so the branch not taken is folded out of the
image instead of shipped as dead code. `tools/mutate-phase3.sh` rebuilds for
each; it does not try to prove both from one boot, because it cannot.

The first still passes because the banner is printed before the fault and the
panic handler parks the CPU rather than letting it reset — the guest is alive
and its memory readable when the sentinel is dumped, exactly as before.

The #DE gate's two halves are load-bearing:

* `FK_EXPECT_SERIAL` carries the **error code on the headline**, not just the
  vector. That is not cosmetic; see M1 below.
* `FK_REJECT_SERIAL` is the line `kernel_main` prints if the divide by zero
  returns. It cost a debugging cycle to learn that it can: gcc rewrites `1/x`
  into a compare against ±1 and emits no DIV at all, so the first build faulted
  nowhere and said so. Both operands are `volatile` now, and
  `objdump -d --disassemble=kernel_main build/boot/kernel.elf | grep idiv`
  is the check to run before believing any boot result.

## What the boot proves that a grep does not

The gate matches one line. These were checked by hand against the image and are
the reason the pass means something:

| Field reported | Cross-check |
|---|---|
| `RIP = 0xFFFFFFFF80101E5F` | the address of the `idivl` in `kernel_main` (`objdump -d`; it moves whenever the image does, so re-derive it rather than trusting this number) |
| `CS = 0x08`, `SS = 0x10` | the selectors `fk_gdt_m` defines, i.e. the LRETQ in `gdt_flush.S` ran |
| `ERR = 0x0` on #DE | the stub's dummy push, since #DE carries no error code |
| `ERR = 0x2` on #PF | the CPU's own code (write, not-present) — the other branch |
| `RAX = 0x1` | the dividend the CPU was holding at the fault |
| `R8 = 0xFFFF` | the UART spin counter from the line printed before the fault |

The #PF row comes from a **throwaway build** that wrote to an unmapped 4 GiB
address instead of dividing. It is the only way to reach the `ISR_ERR` half of
the trampoline, and without it half the error-code normalisation would be
untested. A null dereference would not have done it: `boot/boot.S` identity-maps
the first 1 GiB, so address 0 is present and writable in this kernel.

## What the #DF boot proves, and the one line that carries it

    EXCEPTION 0x08 ERR 0x0000000000000000 -- #DF Double Fault
    *** #DF ENTERED ON IST1 -- THE EMERGENCY STACK HELD ***
    RIP     = 0xFFFFFFFF8010123B
    RSP     = 0x0000400000000000
    FRAME   = 0xFFFFFFFF80108110

| Field | Cross-check against the image |
|---|---|
| `RIP` | `fk_smash_stack` is at 0xFFFFFFFF80101231 and is 0x11 bytes; 0x123B is the `pushq $0` inside it |
| `RSP` | the value `movabsq` put there — the fault happened with a stack pointer that could not take a frame |
| `FRAME` | `fk_df_stack` is 8192 bytes at 0xFFFFFFFF801061C0, exclusive top 0xFFFFFFFF801081C0; 0x801081C0 − 0x80108110 = **176**, one 22-quadword frame |
| `ERR = 0x0` | #DF's error code is architecturally zero, and it is a CPU push, not the stub's dummy — the `ISR_ERR` half |

**`FRAME` is a new line in the dump and it exists for one reason.** `regs%rsp` is
the RSP the fault happened *with*, so on a #DF it is always the broken pointer;
it can never show which stack the handler is standing on. The address of the
frame can, and `fk_tss_m` owns the bounds check (`tss_on_df_stack`), so the
`ENTERED ON IST1` verdict is computed from the stack the CPU actually chose
rather than from the fact that the handler got far enough to print.

The verdict is printed **before** the register dump, not after: it is the one
fact a panic on a doubtful stack might not survive long enough to reach.

## The third channel: asking the hardware instead of the kernel

`FK_CHECK_HW=1` runs `tools/qmp-sentinel.py hwstate`, which reads QEMU's own
`info registers` and `info pic` and pulls the 104 TSS bytes out of guest memory
with `pmemsave`. Eleven assertions, all of them about state the kernel has no
way to report on itself:

    PASS  task register selector is 0x0018 (want 0x0018) -- LTR ran
    PASS  TR base 0xFFFFFFFF801081C0 is the address of fk_tss in the ELF (0xFFFFFFFF801081C0)
    PASS  TR limit is 0x67 (want 0x67, i.e. 104 bytes of TSS)
    PASS  the descriptor TR loaded reads as a busy 64-bit TSS (DPL=0 TSS64-busy)
    PASS  GDT limit is 0x27 (want 0x27) -- the table is long enough for a 16-byte TSS descriptor
    PASS  TSS I/O map base is 0x0068 (want 0x0068: past the limit, so ring 3 gets no bitmap)
    PASS  TSS IST1 is 0xFFFFFFFF801081C0, the top of fk_df_stack (0xFFFFFFFF801081C0)
    PASS  8259 master vector base is 0x20 (want 0x20)
    PASS  8259 master IMR is 0xFF (want 0xFF: every legacy IRQ masked)
    PASS  8259 slave vector base is 0x28 (want 0x28)
    PASS  8259 slave IMR is 0xFF (want 0xFF: every legacy IRQ masked)

Three of those are not redundant with anything on COM1:

* **TR base compared against the ELF.** "LTR loaded *a* TSS" is not the claim;
  "LTR loaded *this* TSS" is. `fk_tss` is `bind(c)`, so the symbol name survives
  gfortran's mangling and the comparison can be written at all. The busy bit is
  the same argument from the other side: type 0x9 becomes 0xB only when LTR
  executes, so 0x8b is evidence of the instruction and not of the table.
* **The vector bases.** This is the assertion M10 exists for; see below.
* **The I/O map base.** Nothing in ring 0 consults it, so a wrong value is
  invisible until the first ring-3 process (roadmap 7.1) is handed an I/O
  permission bitmap made of the TSS's own bytes. It has no other witness, in
  this kernel or in any test that could be written today.

### The descriptor itself, read out of the running guest

Not a gate — a one-off cross-check, done because the descriptor-packing
arithmetic in `tss_init` is the kind of code that is either exactly right or
quietly wrong. The 40 GDT bytes were `pmemsave`d out of the live guest and
decoded:

    slot 0  0x0000000000000000
    slot 1  0x00AF9B000000FFFF
    slot 2  0x00CF93000000FFFF
    TSS descriptor lo 0x80008B1081C00067  hi 0x00000000FFFFFFFF
      limit   = 0x67 (103)
      base    = 0xFFFFFFFF801081C0
      access  = 0x8B  (P=1 DPL=0 S=0 type=0xB)
      flags   = 0x0 (G=0)
      hi[63:32] reserved = 0x00000000

`G=0`, so the limit is in bytes and 103 means 104. `S=0` marks it a system
descriptor, which is what makes it sixteen bytes rather than eight. Type `0xB`
is **busy** — `fk_tss.f90` writes `0x89`, type 9, and only LTR turns 9 into B.
The reserved upper dword is zero, which is required: bits 8-12 there are checked
by the CPU.

Slots 1 and 2 are worth a second look too. `fk_gdt_m` defines them as `...9A00...`
and `...9200...`; they read back `9B` and `93`. That is the ACCESSED bit, set by
the CPU when the selector was loaded — the descriptors are not merely present,
they have been used.

The parser is a pure function over the monitor's text, and
`tools/qmp-sentinel.py selftest` feeds it **real captured output** — including
the `pic0: ... irq_base=08 imr=b8` that this same VM printed before this
milestone — and requires every corrupted variant to be refused. 23 checks.

## Mutations

Each defect was injected alone into a known-good tree, the tree was rebuilt from
clean (`./tools/run.sh clean-boot` first — see `HARNESS-VALIDATION-SERIAL.md` on
why a restored file can be newer than the object it was not built from), booted,
and restored. A mutation the gate accepts is an ESCAPE. M1-M5 run against the
#DE build (the `ISR_NOERR` path), M6-M13 against the #DF build that ships;
`tools/mutate-phase3.sh` switches `FK_FAULT_MODE` and rebuilds for each.

| # | Defect | Result |
|---|---|---|
| M1 | `ISR_NOERR` pushes no dummy error code | **caught** — headline reads `ERR 0xFFFFFFFF80101E1F`, a return address where a zero belongs |
| M2 | IDT gates installed with the present bit clear | **caught** — triple fault; QEMU exits under `-no-reboot` |
| M3 | `%rbx` and `%rbp` pushed in the wrong order | ESCAPE |
| M4 | `fk_isr_stub` returns the stub for vector n+1 | **caught** — `EXCEPTION 0x01 ERR 0x0000000000000000 -- #DB Debug` |
| M5 | no `CLD` before calling into Fortran | ESCAPE |
| M6 | TSS descriptor written as 8 bytes, high half dropped | **caught** — triple fault: the base loses bits 63:32, so #DF delivery reads IST1 from an unmapped address |
| M7 | the #DF gate carries IST index 0 | **caught** — triple fault: the #DF is delivered on the RSP that caused it |
| M8 | IST1 points at the BOTTOM of the emergency stack | **caught three ways** — `FAIL TSS IST1 is 0xFFFFFFFF801061C0, the top of fk_df_stack (0xFFFFFFFF801081C0)`, the `ENTERED ON IST1` line missing, and the `ON THE FAULTING STACK` line present |
| M9 | LTR never executed | **caught** — triple fault; TR is still 0 when the #DF arrives |
| M10 | master ICW2 left at 0x08 | **caught ONLY by the hardware channel** — `FAIL 8259 master vector base is 0x08 (want 0x20)`. COM1 said "remapped to 0x20/0x28, all IRQs masked" and every serial assertion passed |
| M11 | the two 0xFF mask writes removed | **caught twice** — `FAIL 8259 master IMR is 0x00` and the kernel's own `8259 PIC mask readback FAILED.` |
| M12 | `iomap_base` left at zero | **caught only by reading the TSS body** — `FAIL TSS I/O map base is 0x0000 (want 0x0068)`. It ESCAPED the first run; see below |
| M13 | the TSS type's first field widened to `c_int64_t` | **caught by BOTH gates** — `fk_tss is 112 bytes, not 104` statically, and a triple fault when booted |

M1 escaped on the first pass and is the reason the panic headline carries the
error code at all. With the vector alone in the grep, dropping the dummy push
shifts everything above `int_no` while `int_no` itself stays at offset 120, so
the wrong frame prints a perfectly correct-looking exception line. Moving the
error code up one line — where a real kernel prints it anyway — turned an escape
into a catch with no extra gate invocation.

**M10 is why the hardware channel exists.** It is the mutation that a console
cannot catch on principle: masking works whatever the vector base is, so the
kernel's readback still returns 0xFF and its report is sincere and wrong. Every
serial assertion passed. Only `info pic` disagreed. Any future milestone that
programs a device and then describes it on COM1 has the same hole.

**M12 escaped the first run and that is recorded rather than quietly fixed.**
`iomap_base = 0` is invisible in ring 0 — nothing consults the I/O permission
bitmap while CPL ≤ IOPL — so the first table had it as an honest escape. It was
closed by having `hwstate` `pmemsave` the 104 TSS bytes and assert the field
directly, which also strengthened the IST1 check from "non-zero" to "exactly the
top of `fk_df_stack`, computed from the ELF". That is what turned M8 from one
catch into three.

**M11 is worse than it looks and the number says so.** The IMR reads back `0x00`,
not the firmware's `0xb8`: ICW1 CLEARS the mask register, so a remap without the
mask write leaves every legacy IRQ *unmasked* — strictly more dangerous than
never having touched the chip. The mask write is not tidying up after the remap;
it is the half that makes the remap safe to have done.

**The two remaining escapes are honest and are recorded rather than papered over.**

* **M3** cannot be caught by this crash. `RBX` and `RBP` are both zero when
  `kernel_main` divides by zero, so a swap is invisible in the dump. Catching it
  needs a fault raised with known sentinel values in every register, which is an
  assembly test harness this tree does not have.
* **M5** is insurance, not a live bug: nothing between the boot stub and the
  fault sets DF, so the direction flag is already clear. It stays because the
  first Fortran routine that gets a `memmove`-shaped lowering in the panic path
  would depend on it, and by then the failure would be a corrupted dump rather
  than an obvious one.

Both escapes bound what the boot gate proves. Frame *layout* is proven by the
cross-check table above, not by the grep.

**What no mutation here covers.** IST1 only: `ist2..ist7` are zero and no other
vector asks for a stack, so NMI and #MC still arrive on the faulting stack. And
every result above is QEMU's device model, not silicon — `elcr`, real 8259
timing, and a real TSS-descriptor cache are all unexercised.

**The one an adversarial review found and no gate did.** `fk_tss` ends at
`0xFFFFFFFF80108228`; `__boot_stack_bottom` is `0xFFFFFFFF80108230`, eight bytes
above it. `linker.ld` emits `*(.bss .bss.*)` and `*(COMMON)` and only then
reserves the 16 KiB boot stack, so the stack grows **down towards the TSS** and
there is no guard page until roadmap 3.5 — a boot-stack overflow destroys IST1
before the #DF that would have used it. It is a bound rather than a live bug
(nothing recurses, and 16 KiB is a long way), and `tools/linkscript-test.sh` now
prints the neighbour and the slack on every run:

    NOTE  directly below __boot_stack_bottom (0xffffffff8010a2b0): fk_tss, ending 0xffffffff8010a2a8
          8 byte(s) of slack, and no guard page until roadmap 3.5 --
          a boot-stack overflow lands in it

Printed and not asserted, deliberately: asserting a particular neighbour would
freeze an arbitrary link order without making the overflow any less fatal.

**And one of the new checks is an invariant, not a test.** "the #DF stack is
disjoint from the boot stack" cannot be made to fail by any layout the current
`linker.ld` can produce, because no symbol can land inside an inline `. +=
BOOT_STACK_SIZE` reservation. It is labelled as such in the script. It is kept
for the day the boot stack becomes an ordinary `.bss` array — which is how most
kernels end up spelling it — but by this tree's own standard it is not evidence
today.

## The static gate: the stub table

Only vectors 0 and 14 have ever fired. `boot/interrupts.S` ends with 32
hand-typed `.quad`s, and a duplicated or transposed one boots perfectly green
while mis-routing an exception nobody has raised yet — the failure would surface
in roadmap 3.3 as an unrelated mystery.

`tools/linkscript-test.sh` now reads that table back out of the linked image and
compares all 32 entries against the `isr0..isr31` symbols. Proven to fail:
duplicating `isr21` over `isr22` produces

    FAIL  isr_stub_table: entry 22 is 0xffffffff801011aa, but isr22 is at 0xffffffff801011ae

python3 rather than awk in that check, because these addresses need more than
the 53 bits awk keeps exactly — the first version of it silently compared zeros
and "passed" nothing.

## The static gate: 104 bytes

`tools/linkscript-test.sh` also reads the size of `fk_tss` back out of the
linked image and fails at anything but 104. That check is the whole reason the
TSS is spelled as 26 32-bit fields rather than one field per architectural
quadword: RSP0 sits at offset 4, `bind(c)` means C struct rules, and a
`c_int64_t` declared there is aligned up to offset 8 — which moves IST1 from
0x24 to 0x28 and every field after it. Nothing complains. The type compiles, the
descriptor loads, and the CPU reads the #DF stack pointer out of the wrong eight
bytes. M13 confirms the check fires:

    FAIL  fk_tss is 112 bytes, not 104: a field has been aligned up, so IST1 is
    FAIL       no longer at offset 0x24 and the CPU will load a #DF stack pointer
    FAIL       out of whichever eight bytes landed there instead

Alongside it: both objects are inside `[__bss_start, __bss_end)` so `boot.S`
zeroes them and they cost no image bytes, and the emergency stack is disjoint
from the boot stack — an IST1 that pointed into the stack whose corruption
caused the #DF would be decoration.

## A gate defect this milestone found, and watched fail

Not in the new code — in `Makefile.boot`'s ISO recipe, which every result in this
document depends on. It read:

    grub2-mkrescue -o $@ $(ISODIR) 2>&1 | sed 's/^/  /'
    @test -s $@ || { echo "  FAIL  grub2-mkrescue produced an empty $@"; exit 1; }

make takes a pipeline's status from its **last** command, so `sed`'s zero masked
a `grub2-mkrescue` that died. And a mkrescue that dies before opening its output
leaves the **previous** ISO in place, which `test -s` accepts because it is a
non-emptiness test and not a freshness one. `.DELETE_ON_ERROR:` never fired,
because no recipe line ever returned non-zero.

The gate downstream compounds it: `tools/qemu-boot-test.sh` boots the ISO but
derives every address it asserts — the sentinel, `fk_tss`, `fk_df_stack` — from
`kernel.elf`, a different file. A constant-only defect (M10 is exactly one) moves
no symbol, so a stale ISO satisfies every assertion including the hardware ones.

Watched failing, against the real Makefile, with a `grub2-mkrescue` shim that
exits 1 and a good ISO already on disk:

    # before
      xorriso : FAILURE : Cannot open device
      OK    build/boot/fortran-kernel.iso (6082560 bytes)
    MAKE EXIT=0 -- and the stale 6082560-byte ISO survived

    # after
      xorriso : FAILURE : Cannot open device
      FAIL  grub2-mkrescue exited 1
    make: *** [Makefile.boot:251: build/boot/fortran-kernel.iso] Error 1
    MAKE EXIT=2 -- and the ISO is gone

The fix is `rm -f $@` before the build, which turns `test -s` into a genuine
freshness test, and running mkrescue unpiped so its status survives. This is the
`docs/HARNESS-VALIDATION-SERIAL.md` stale-image class again, arriving through a
different door: there it was mtime, here it was an exit status.

## Roadmap 3.4: the PMM

Three channels again, and a fourth that is new: a host suite that can read the
kernel's own bitmap.

### 1. The host suite (`build/run-pmm`, 390 checks)

`tests/mm/test_pmm.c` assembles real Multiboot2 information structures byte by
byte, hands their address to `pmm_init`, and then compares `fk_pmm_bitmap`
against a reference bitmap built in C from the specification. Not against an
accessor — against the array, because `fk_pmm_bitmap` is `bind(c)` and an
accessor can agree with a wrong bitmap.

**The MBI is `mmap`ed at a fixed address below 1 GiB**, and that is not a
workaround for the range check — it is the range check being exercised. `pmm_init`
refuses an MBI outside the window `boot/boot.S` identity-maps, because outside it
the dereference is a page fault three files from its cause; a static buffer at
the usual PIE address would be refused before it was ever parsed.

Sixteen defects, injected one at a time, every one refused:

| # | Defect | How the suite refused it |
|---|---|---|
| H1 | `pmm_init` never fills the bitmap with ones | bitmap differs at frame 9; `.bss` arrives zeroed, so the default becomes "the whole address space is free RAM" |
| H2 | available regions rounded OUTWARD | `awkward edges` differs by one frame at a region whose base is mid-frame |
| H3 | reserved regions rounded INWARD | frame 786 (0x312000) free where the reference has it used — the kernel's own last, partial frame |
| H4 | the kernel image is never marked used | frame 256 (0x100000) free: the allocator would hand out this module's text |
| H5 | the loader's structure is never marked used | frame 131072 free — the frame holding the map being parsed |
| H6 | the reserved-wins second pass dropped | frame 4160 (0x1040000) free: a RESERVED region inside an AVAILABLE one, and entry order decides |
| H7 | frame 0 left allocatable | frame 0 free, so `0` is both a valid address and the OOM answer |
| H8 | `entry_size` assumed to be 24 | the `entry_size 32` map parses into nonsense: 786303 frames instead of 6291327 |
| H9 | tag stepping drops the `(size+7) & ~7` padding | `E_TAG_OVERRUN` (5) on the map with a 13-byte tag ahead of it |
| HA | region-table overflow truncates instead of failing | init returns OK with 5242880 frames from a map it only half read |
| HB | `free()` skips the in-RAM test | freeing an ACPI address succeeds, putting firmware memory into the pool |
| HC | `free()` skips the already-free test | double free succeeds and the free count drifts up by one per stray call |
| HD | `free()` never rewinds the scan cursor | reclaim reports success and the frame is never handed out again |
| HE | `alloc()` computes the address but never sets the bit | `alloc marks the frame used` — see below |
| HF | a failed `pmm_init` keeps its counters | a refused map still reports 128 regions |
| HG | `free()` ignores the locked span | freeing the kernel's base address returns OK instead of `E_LOCKED` |

**H6 escaped the first run, and the fixture was wrong rather than the module.**
The overlapping RESERVED region in the awkward map sat at 2.5 MiB — inside
`[__kernel_phys_start, __kernel_phys_end)`. The kernel span marked those frames
used anyway, so deleting `pmm_init`'s entire second pass changed nothing and the
suite passed a module in which entry ORDER decided whether reserved memory was
allocatable. The overlap moved to 16 MiB, clear of the kernel, and H6 has been a
catch since. The lesson is not about this map: a fixture whose interesting case
is masked by an unrelated correct behaviour tests the masking.

**HE did something worse than escape: it hung.** An allocator that computes an
address and forgets to set the bit returns the same frame for ever, and
`while (alloc() != 0)` then spins at 100% with no output — not a failing test,
a hung suite somebody has to debug. Both drains are bounded now, the host one by
`free_pages + 16` and `pmm_drain_to_oom` by `pmm_total_pages() + 1`, and HE fails
in under a second on a check that was already there.

### 2. The static gate

`tools/linkscript-test.sh` gained seven checks, and two of them cannot be made
anywhere else:

    PASS  the identity window fk_pmm assumes == the one boot.S builds = 1073741824
    PASS  PAGE_SIZE agrees between boot.S and fk_pmm.f90 = 4096
    PASS  fk_pmm_bitmap is one bit per frame of 68719476736 bytes = 2097152
    PASS  fk_pmm_bitmap is inside .bss, so boot.S zeroes it and it costs no image bytes
    PASS  the last PT_LOAD carries 2149856 bytes of NOBITS, so the bitmap is not in the file
    PASS  fk_kernel_phys_start returns __kernel_phys_start = 0x100000
    PASS  fk_kernel_phys_end returns __kernel_phys_end = 0x314000

`FK_PMM_IDMAP_BYTES` is the `KERNEL_VMA` problem again: an assembler `.set`
cannot be imported into Fortran, so the value is duplicated and diffed here. If
this one drifts, the check that refuses an unmapped MBI accepts it instead.

The last two are the only witness `boot/ksyms.S` has. It hands Fortran the VALUE
of an absolute linker symbol as a `movabsq` immediate, and a wrong constant marks
the wrong frames used while every verdict on the console still prints PASS. The
gate disassembles the accessor and compares the immediate against `nm`.

### 3. The boot gate

Six verdict lines, each with a FAIL twin in the reject list, on every build —
not opt-in, because the shipped image prints them:

    Fortran Kernel: PMM reserved and ACPI frames are all marked used.
    Fortran Kernel: PMM locked the kernel image and the loader map out.
    Fortran Kernel: PMM allocated 5 contiguous frames.
    Fortran Kernel: PMM freed and reclaimed the same 5 frames.
    Fortran Kernel: PMM refused a double, unaligned and locked free.
    Fortran Kernel: PMM rewound its scan cursor to a freed frame.

The sixth is there because of M18 below; the other five did not cover it.

There is a seventh build, not in the shipped image. `FK_FAULT_MODE = -1` drains
the allocator and panics through a real `INT3`, which is how the out-of-memory
path is watched firing rather than argued about:

    Fortran Kernel: PMM handed out 0x00000000005FFD6C frames before it refused.
    *** PMM OUT OF MEMORY ***
    EXCEPTION 0x03 ERR 0x0000000000000000 -- #BP Breakpoint
    RBX     = 0x00000000005FFD6C
    RBP     = 0x00000000005FFF7F
    *** HALTED -- CLI/HLT ***

0x5FFD6C is exactly the free count printed at init, 0x5FFF7F the total, and both
are in registers because the CPU was holding them when the breakpoint hit. The
panic is the SAME catcher every hardware fault reaches — `boot/faultgen.S` puts
one `int3` byte in the way rather than calling a Fortran panic routine, because
a register dump is only evidence if the registers are the machine's.

### 4. The proof the map is LIVE, which is this milestone's word-3-xor-magic

A region table is exactly the kind of output a constant could fake. It cannot
fake this — the same image, three `-m` values:

| `-m` | regions | frames total | free |
|---|---|---|---|
| 24G | 8 | 0x5FFF7F (6291327) | 0x5FFD6C |
| 4G  | 8 | 0x0FFF7F (1048447) | 0x0FFD6C |
| 2G  | **7** | 0x07FF7F (524159) | 0x07FD6C |

At 2G the map has one region FEWER — QEMU emits no above-4 GiB entry at all — and
the top of low RAM moves from `0xBFFE0000` to `0x7FFE0000`. Every number the PMM
prints tracks what the loader said, so live loader data crossed into Fortran and
was parsed, not merely received.

The 24G arithmetic checks by hand: 159 + 786144 + 5505024 = 6291327 frames. The
531 used are the kernel's 530 (0x100000-0x314000, outward) plus frame 0.

**And a finding worth more than the numbers.** The sentinel reports the MBI at
physical `0x103540` — which is *inside* `[__kernel_phys_start,
__kernel_phys_end)`, in the 0xB10-byte alignment gap between the kernel's first
and second PT_LOAD. GRUB's relocator tucked its own structure into a hole in the
middle of the loaded image. A PMM that reserved the file-backed ranges instead
of the whole `__kernel_phys_start .. __kernel_phys_end` span would have handed
out the frame holding the memory map it was reading.

That is also a limit on this channel: because the MBI is inside the kernel span
here, removing the MBI marking alone changes nothing on this hardware. Only H5
proves it, and only because the host suite can put the MBI where it likes.

### 5. Boot mutations

`M14`-`M20` re-run defects the host suite already catches, on a real machine,
because the host suite parses a map this tree wrote and the boot gate parses one
GRUB wrote.

| # | Defect | Result |
|---|---|---|
| M14 | `pmm_init` handed 0 instead of the loader's pointer | **caught** — `PMM init FAILED, status 0x00000001` and all six verdicts missing |
| M15 | the kernel image is never marked used | **caught** — `PMM did NOT lock the kernel image out.`, a line the gate forbids |
| M16 | `pmm_init` never fills the bitmap with ones | **caught** — every AVAILABLE clear flips nothing, so `ram_pages` is 0 and init returns `E_NO_RAM` |
| M17 | `alloc()` computes the address but never sets the bit | **caught** — three verdicts flip at once; the ALLOC one fails first (five identical addresses) |
| M18 | `free()` never rewinds the scan cursor | **caught, but only after the gate was strengthened** — see below |
| M19 | `free()` ignores the locked span | **caught** — `PMM guard FAILED.`, and freeing the kernel's own base returns OK |
| M20 | `boot/ksyms.S` returns 0 instead of `__kernel_phys_start` | **caught ONLY by the static gate** — see below |

**M20 is this milestone's M10, and the reason the static check was written before
the mutation existed.** The boot gate passes it completely: with `kern_lo = 0`
the locked span becomes `[0, __kernel_phys_end)`, which covers strictly MORE than
the real one, so nothing reserved becomes allocatable, `pmm_verify_kernel_locked`
is satisfied, first-fit simply starts above the span, and all six verdicts print
PASS. The kernel is not wrong about anything it can see. Only

    FAIL  fk_kernel_phys_start returns 0x0 but the linker puts __kernel_phys_start at 0x100000

disagrees, and it can only be written because the accessor is a `movabsq` whose
immediate is in the linked image. The mirror-image defect — a constant that is
too HIGH — would leave the kernel image allocatable and be caught on COM1; the
gate has to cover both, and only one of them has a console witness.

**M18 escaped the first run, and the escape was a fact about the fixture, not
about the module — the same shape as H6.** The five-frame reclaim test allocates
frames 1 to 5. All five live in the SAME 64-bit bitmap word, so the scan cursor
never leaves it, and a `free()` that forgets to rewind the cursor still finds
them: `freed and reclaimed the same 5 frames` printed PASS on a kernel that
cannot reclaim anything the cursor has moved past. The host suite caught it
(`alloc after OOM`) only because a drain moves the cursor to the end first.

The fix is in the kernel, not in the gate: `pmm_verify` now takes 96 frames —
enough to cross a word boundary from any start — frees the FIRST, and demands it
back, under its own verdict:

    Fortran Kernel: PMM rewound its scan cursor to a freed frame.

M18 now fails it on the boot gate as well. The general lesson is the one H6
taught from the other direction: **a test whose interesting case fits inside one
machine word is testing the word, not the algorithm.**


### What the boot gate cannot see, stated rather than implied

* **The reserved-wins pass (H6) has no boot-gate coverage.** QEMU's map has no
  region of one type inside a region of another, so pass B flips no bits on this
  machine. It is host-proven only. A real firmware map with an overlap would
  change that, and until one is in hand this is an assumption about QEMU.
* **The MBI lock (H5) has no independent boot-gate coverage**, for the reason
  above: GRUB put the MBI inside the kernel span.
* **Everything above 1 GiB is tracked and never touched.** The PMM hands out
  addresses; it does not write to the frames. `0x100000000` is a perfectly good
  answer from `pmm_alloc_page` on this machine and the kernel cannot yet map it.
  That is roadmap 3.5's, and until then an allocation above the identity window
  is a number, not memory.
* **64 GiB is a ceiling, not the architecture's.** Above `FK_PMM_MAX_PHYS` the
  memory is counted into `pmm_ignored_bytes` and reported. It reads 0 on every
  boot so far, which means the reporting path itself is only proven by the host
  suite's `awkward edges` map.

### A gate defect this milestone found, and fixed

`tools/linktest.sh` carried its **own fourth copy of KFLAGS**, which is precisely
what `mk/kflags.mk`'s header says must not happen. It drifted the first time a
flag was added: 3.4 put `-fno-tree-loop-distribute-patterns` in `mk/kflags.mk`,
the copy did not get it, and the gate then reported

    FAIL  fk_pmm: undefined symbols that NOTHING in this tree defines:
          memset   <- a libc that kernel space does not have

for a module the real kernel build links clean. It now reads the flags back
through make, the way `tools/linkscript-test.sh` already did.

The flag itself is the finding underneath. gcc's loop-distribution pass rewrites
a DO loop that stores one value across an array into a call to `memset` — the
Fortran half of what `-ffreestanding` does for C, and a live problem the moment a
fill loop is bigger than a handful of elements. Measured: the PMM's 262144-word
bitmap fill emits `U memset` at -O2 without the flag and nothing with it. The
tree got this far without noticing because every earlier fill was four elements
long.

## Reproducing

    ./tools/run.sh audit                          # every static gate
    tools/qemu-boot-test.sh --selftest            # both assertion self-tests, no VM
    ./tools/run.sh clean-boot && ./tools/run.sh iso
    tools/qemu-boot-test.sh                       # 1.2 + 2.1
    FK_EXPECT_SERIAL=$'EXCEPTION 0x08 ERR 0x0000000000000000 -- #DF Double Fault\n*** #DF ENTERED ON IST1 -- THE EMERGENCY STACK HELD ***' \
    FK_REJECT_SERIAL=$'*** #DF ENTERED ON THE FAULTING STACK -- NO IST SWITCH ***\nFortran Kernel: the deliberate fault did NOT trap.\nFortran Kernel: 8259 PIC mask readback FAILED.' \
    FK_CHECK_HW=1 tools/qemu-boot-test.sh         # 3.2.5

    ./tools/run.sh build/run-pmm                  # roadmap 3.4, 390 host checks
    FK_MEM=4G tools/qemu-boot-test.sh             # the map tracks -m: see above
    FK_EXPECT_SERIAL=$'*** PMM OUT OF MEMORY ***\nEXCEPTION 0x03 ERR 0x0000000000000000 -- #BP Breakpoint' \
      tools/qemu-boot-test.sh                     # after sedding FK_FAULT_MODE to -1

    tools/mutate-phase3.sh                        # the whole table, ~23 boots
    tools/mutate-phase3.sh M10 M13                # or just these

`tools/mutate-phase3.sh` edits the tree in place and restores it with
`git checkout`, so it REFUSES to run when any file it mutates is untracked or has
unstaged changes — `git checkout` rewinds to the index, so either one would mean
the first mutation survived into every later case and got reported against the
wrong defect. Each substitution also aborts the run if its text was not found:
a sed that quietly matches nothing rebuilds the pristine kernel, the gate passes,
and the table records an escape that never happened.
