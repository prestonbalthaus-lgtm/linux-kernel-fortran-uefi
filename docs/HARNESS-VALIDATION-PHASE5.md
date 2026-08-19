# Does Phase 5's test actually catch bugs?

Roadmap 5.1 brought a USB host controller out of reset, gave it a command ring
and an event ring, ran it, executed a NO-OP, and took the first interrupt in this
kernel's history that is a **message** rather than a wire.

Every one of those claims is about a **bus master**. That is what makes this
milestone's harness different from every one before it: the kernel is no longer
the only thing writing to the memory under test. A ring is DRAM that a second
processor reads and writes, so "the kernel says it enqueued a TRB" and "a TRB is
there for the controller to fetch" are different statements, and the gate is
built to only ever make the second one.

## The five channels, and what each is the only one to see

| Channel | Sees | Cannot see |
|---|---|---|
| Host oracle suite (`build/run-xhci`, 127 checks) | register offsets, TRB field arithmetic, the two-part scratchpad count, the ERST-max exponent | a controller. There is none. |
| `tools/mmiocheck.sh` on `fk_xhci.o` | any device access narrower than a dword, read from the **object** | logic |
| The serial contract | that each stage was reached and what the kernel decoded | whether the controller agrees |
| `pmemsave` at the ring's **physical base** | what a bus master would fetch, and what one wrote | registers |
| `xp` at BAR0 | the device model's own register state | DRAM |
| `fk_msi_count` | that a message reached the IDT gate | anything about why |

**The physical-base read is the point.** `pmemsave` dumps guest DRAM at
`0x348000` — the address the guest published — with no page table anywhere in the
path. What comes back is what the controller could fetch. The command ring is
then checked as *the kernel's claim*, and the event ring as *the controller's
answer*, and the two are compared against each other:

    the TRB at 0x348000 is a NO-OP command (type 23)
    with its cycle bit set, so the controller owned it
    the controller posted a Command Completion Event (type 33)
    with cycle 1, the polarity a zeroed segment cannot fake
    completion code 1 (SUCCESS)
    naming the command TRB at 0x348000, which is the one the kernel enqueued

The cycle-bit clause carries more than it looks. A freshly allocated segment is
zeroed, and a zeroed TRB has cycle 0. An event with **cycle 1** in slot 0 cannot
be produced by a kernel that allocated memory and did nothing — it can only be
produced by something that wrote there after the zeroing, and the only thing that
writes to the event ring is the controller.

## The reset, which is not inferable from the end state

Firmware drives this controller before the kernel runs. SeaBIOS leaves CRCR,
DCBAAP and ERSTBA pointing into its own memory — memory the PMM is about to hand
out again. A kernel that skipped the reset and programmed its own rings over the
top ends up looking **identical** at the end of bring-up.

So three registers are read the instant the reset returns, before anything else
is written, and published:

    fk_xhci_state(16) = xhci_crcr()
    fk_xhci_state(17) = xhci_dcbaap()
    fk_xhci_state(18) = int(xhci_usbsts(), c_int64_t)

They are firmware's values unless the reset happened. Mutation M52 removes the
reset and the gate answers `CRCR read 0x7FFDFC01 straight after the reset` — a
real SeaBIOS pointer, quoted back.

## Mutations

`tools/mutate-phase45.sh`, same contract as Phase 3's: one defect, rebuilt from
clean, booted, restored.

| # | Injected defect | Detected? | How it surfaced |
|---|---|---|---|
| M52 | the controller is never reset | **yes** | `CRCR read 0x7FFDFC01 straight after the reset` — firmware's pointer, still there |
| M53 | ERSTSZ given the TRB count instead of the segment count | **yes** | bring-up returns −7; `the controller posted a Command Completion Event (type 0)` — it set HCE and executed nothing |
| M54 | LINK TRB written without Toggle Cycle | **yes** | `with Toggle Cycle set, which is what makes it a ring` |
| M55 | NO-OP TRB's cycle bit left clear | **yes** | bring-up returns −7; `with its cycle bit set, so the controller owned it` |
| M56 | ERDP never advanced past the consumed event | **yes** | `ERDP 0x349008 advanced one TRB past the segment base` |
| M57 | IMAN.IE never set | **yes** | `IMAN 0x00000001: the interrupter is enabled`, and `fk_msi_count is 0` |
| M58 | USBCMD.INTE never set | **yes** | `USBCMD 0x00000001: R/S and INTE are both set`, and `fk_msi_count is 0` |
| M59 | DCBAAP never written | **yes, after a fix** | escaped first. See below. |
| M60 | MSI-X entry not masked while it is written | **NO — escaped** | structural; see below |
| M61 | INTx never disabled | **yes** | `and INTx is disabled, so the legacy wire is gone` — and the route check refuses, so bring-up never runs and the state block stays zero |
| M62 | doorbell never rung | **yes** | bring-up returns −7 and `the controller posted a Command Completion Event (type 0)` — slot 0 of the event ring is still the zeros it was allocated with |
| M63 | TRB's cycle bit published **first**, before its payload | **NO — escaped** | structural; see below |
| M64 | USBCMD.R/S never set | **yes** | same shape as M62 — the controller stays halted, so nothing is fetched and slot 0 of the event ring never changes |

Thirteen cases, eleven refused. **M57 and M58 are the pair worth noticing**: they
are two different gates on the same message, and either one clear posts the event
with no interrupt sent and no error reported anywhere. Nothing on the console
distinguishes them from success. Only `fk_msi_count`, read out of guest memory,
does — which is why "the controller completed its command" and "the controller
sent an interrupt" are two separate assertions and not one.

## The three holes this milestone's own suite found

### 1. `check_xhci_rings` had no self-test at all

`check_pci` was covered by `qmp-sentinel.py selftest`. The ring checker was not.
Every green `xHCI controller : PASS` therefore rested on assertions **nothing had
ever watched refuse** — the exact thing this repository's rule about gates exists
to prevent. Thirty cases added, one per assertion, each feeding the checker a
correct fixture with one field wrong. Selftest 103 → 132, 0 failed.

### 2. M59: DCBAAP was never checked, because a NO-OP does not need it

The Device Context Base Address Array pointer was written by the kernel and read
back by nobody. `xhci_set_dcbaap` could be removed entirely and every assertion
still passed, because **a NO-OP command touches no slot** and the controller runs
it correctly with the array pointer at zero. Measured, not assumed: the mutation
was run and the gate stayed green.

`do_xhci` now reads DCBAAP off the device model through `xp` alongside CRCR and
ERDP, and asserts it holds the kernel's own array. The mutation now refuses:

    FAIL  DCBAAP 0x0 holds the kernel's device-context base array at 0x347000

Roadmap 5.2's device contexts are the first thing that needs that pointer to be
real, which is why the hole was invisible for a whole milestone and would have
been expensive in the next one.

### 3. Writing the self-test found a gate that crashes instead of failing

A fixture publishing a TRB address outside its own command ring made
`trb_at` unpack at a **negative offset** and the checker died with a Python
traceback. A gate that crashes reports nothing — it is indistinguishable from a
harness bug, and the natural response to it is to fix the harness rather than the
kernel. The offset is now bounded and an out-of-ring TRB is a stated failure.

## The two escapes, and why neither is a hole

**M60 — the MSI-X entry is not masked while it is written.** The entry is written
during bring-up, before MSI-X is enabled in the capability and before the
controller has any reason to send anything. There is no window to lose, so
nothing observable changes. The mask/unmask is protection against reprogramming a
*live* entry, which nothing in this tree does yet.

**M63 — the cycle bit is published before the TRB's payload instead of after.**
This is the ordering the entire ring protocol rests on: the cycle bit is what
hands a TRB to the controller, and a controller that sees it before the rest of
the TRB is in memory executes a half-written command. It cannot be refuted here,
and the reason is structural: **QEMU's xHCI model fetches the TRB when the
doorbell is written**, synchronously, long after all four dwords have landed. The
race needs a controller that is polling DMA concurrently, which is to say real
hardware.

This is the same shape as `HARNESS-VALIDATION-PHASE2.md`'s mutation 12, and it
gets the same treatment rather than a fake assertion: **the ordering in
`trb_write` is protected by review and by this document, not by a test.** What
can be said is what the code does — the four writes go through `fk_writel`, an
opaque call the compiler cannot reorder against, so the *source* order is the
*emitted* order. Anyone reordering those four lines to save a register should be
required to say why against this paragraph.

## Roadmap 5.2: the keyboard


5.1's device was the controller itself. 5.2's is a keyboard on the other end of
it, and that changes what the harness has to do: for the first time the gate
must **cause** something from outside the guest and see the guest react.

### The channels 5.2 adds

| Channel | Sees | Cannot see |
|---|---|---|
| `build/run-usb_hid`, 4348 checks | the usage-to-ASCII decode, against Linux's `usb_kbd_keycode` for two relations and a reference model for the rest | anything about USB |
| QMP `input-send-event` | nothing — it is the *cause*, not a channel | — |
| `fk_usbkbd_state` by `pmemsave` | what the kernel decided | whether the controller agreed |
| the **device context** in DRAM, at its physical base | the slot state and device address the CONTROLLER wrote | anything the kernel wrote |
| `DCBAA[slot]` in DRAM | that the array the controller reads points at that context | — |

**The device context is the load-bearing one.** Slot Context dword 3 carries the
slot state and the USB address, and both are the controller's to write — a
kernel that filled in its own input context and never issued Address Device
cannot put `Addressed` there, and one that never issued Configure Endpoint
cannot put `Configured` there. Everything else in that structure is the
kernel's own writing read back.

### Causing a keystroke, and why `sendkey` was abandoned

The first version used HMP `sendkey`, which presses and releases a whole
combination on QEMU's own timing. That is a **race**: which reports the guest's
8ms poll actually samples is not determined, and `shift-a` was observed
decoding as `a` because the modifier had already been released by the time a
report was sampled. Three consecutive gate runs disagreed with each other.

Every key is now an explicit down and up through `input-send-event`, with a gap
between them, so the sequence of reports is a fact rather than a hope. It also
buys the one thing `sendkey` cannot do at all: **hold a key**.

    shift down, a down, a up, shift up      ->  A
    a down, b down, b up, a up              ->  a b

That second line is the whole reason it matters. A boot report's six usage slots
are a **set**, not a queue: a key held down reappears in every report until it
is released, so a driver that does not subtract the previous report renders it
again on each one. With press-and-release only, no two consecutive reports ever
share a usage — and mutation M74 removing the subtraction left the gate green.
Measured, then fixed, then measured again.

### Mutations

| # | Injected defect | Detected? | How it surfaced |
|---|---|---|---|
| M65 | the port is never reset | **yes** | `PED is set, which only a port reset produces` fails, and a change bit is left unacknowledged (`0x20000`) |
| M66 | PORTSC written read-modify-write | **NO — escaped** | QEMU-specific; see below |
| M67 | `DCBAA[slot]` never written | **yes** | Address Device fails outright; the bring-up never reaches its own next line |
| M68 | Context Entries left at 1 with EP1 added | **NO — escaped** | QEMU-specific; see below |
| M69 | Add flag A3 not set on Configure Endpoint | **yes** | the endpoint is never configured and no report ever arrives |
| M70 | doorbell rung at DCI 1 instead of 3 | **NO — escaped** | QEMU-specific; see below |
| M71 | IMAN.IP never cleared in the handler | **NO — escaped** | QEMU-specific, and it cost an assertion; see below |
| M72 | `SET_PROTOCOL` removed | **NO — escaped** | predicted in the plan; see below |
| M73 | the modifier byte ignored | **yes** | `the decoded characters are aab (want Aab)` |
| M74 | the previous report not subtracted | **yes**, after the injection was strengthened | `aba` instead of `Aab` |
| M75 | the handler drains before it owns the ring | **yes** | `the xHCI never completed the NO-OP` — 5.1's completion, eaten |

Eleven cases, six refused. **M75 is not hypothetical**: it is the bug the first
version of this milestone actually shipped, and the gate reported it as 5.1
regressing, with the completion event visibly correct in DRAM.

### The five escapes, and the one that cost an assertion

M66, M68, M70, M71 and M72 all escape for the same reason, and it is a
different reason from Phase 4's: **QEMU's device model is more permissive than
the specification.** These are not guards against malformed input; they are
requirements a real controller enforces and this one does not.

- **M66** — PORTSC is written read-modify-write. PED is write-1-to-**disable**,
  so the second write (the one acknowledging the reset) hands back a 1 in PED
  on a port that is now enabled. On this model the port stays enabled anyway.
- **M68** — Context Entries left at 1 while EP1 IN is added at DCI 3. The
  specification has the controller answer that with a parameter error; here
  Configure Endpoint returns SUCCESS and the endpoint works.
- **M70** — the doorbell for EP1 is rung at DCI 1. The endpoint still runs.
- **M71** — the interrupter's IP bit is never cleared.

**M71 is the one worth dwelling on, because it falsified an assertion rather
than merely escaping.** Two keystrokes are injected precisely because a handler
that leaves IP set should deliver exactly one message and then go silent, and
the gate's assertion said so in as many words: *"more than one, so IMAN.IP is
being cleared and messages keep coming."* The mutation removed the IP clear and
the count did not move. So the causal claim was **wrong on this machine**, and
an assertion that states a reason the evidence does not support is worse than
one that states less. It now says what it can support — the endpoint keeps
delivering — and the IP clear is kept on xHCI 1.2 5.5.2.1's authority rather
than this gate's.

The two-key injection is kept anyway. It is right for the specification, it
costs nothing, and the failure mode it guards against is the one M33 has
already caught this project out with once.

**M72 was predicted before it was run.** The plan said `SET_PROTOCOL` might not
be refutable because QEMU's keyboard may report the same eight bytes in both
protocols, and that if so it would be labelled QEMU-specific rather than
counted as coverage. It was not refutable. It is labelled.

## Roadmap 5.3: the NVMe controller, and sector 0

5.1's device was a controller, 5.2's was a keyboard on the end of one. 5.3's is
a **disk**, and that gives this milestone something the other two never had: an
answer that exists outside the machine before the machine is switched on.

### The disk is the oracle

Every other assertion in this project compares the guest against QEMU's device
model, against the guest's own earlier reading, or against a reference model
written from a specification. The sector read is different: **the bytes are on
the host, in a file, before the kernel boots.**

    tools/qemu-boot-test.sh generates build/boot/nvme-disk.img
      sector 0   00 01 02 ... 0f, then zeros, then 55 AA
      sector 1   "FORTRAN-KERNEL!!"

The checker `pmemsave`s the guest's DMA landing zone at its physical base and
compares it against that file, **read at check time**. There is no second copy
of the expected bytes anywhere, so a changed fixture cannot drift away from its
own assertion — which is the failure mode a hardcoded `00 01 02 ...` in the
checker would have had.

The image is **generated, not committed**. A binary fixture in git is one
nobody can read a diff of.

### Sector 1 exists to catch an off-by-one, and it did

`Read`'s NLB field is **zero-based**: 0 means one block. Two of the ten
mutations are off-by-one in exactly that arithmetic, and the second sector's
ASCII signature is what makes them visible rather than plausible:

    M83 (SLBA 1 instead of 0)   the 512 bytes at 0x35D000 are ...
                                (first 16: 464f525452414e2d4b45524e454c2121)

`464f...` is `FORTRAN-KERNEL!!`. A disk of zeros would have made that mutation
a comparison of zeros against zeros.

### The guard region, and the mutation that forced it

**M82 escaped the first time it was run.** Writing the block *count* into NLB
instead of count-1 reads TWO blocks — and the first of them is still sector 0,
so a checker that compares the 512 bytes it asked for sees nothing wrong.

This is `HARNESS-VALIDATION-PHASE2.md`'s mutation 4 in a new costume: a
comparison bounded by the region of interest cannot see a write **past** it.
The fix is the same one the framebuffer needed. The kernel now zeroes the whole
page before the read, the checker reads 1024 bytes, and the second 512 are a
guard region that a one-block read has no business touching:

    the 512 bytes ABOVE the sector are still zero, so the read was one block
    and not two (first 16: 464f525452414e2d4b45524e454c2121)

### Two-entry queues, because a phase tag that never wraps is not tested

A completion queue entry belongs to the controller until its phase bit differs
from the consumer's expectation, and the consumer flips its expectation every
time it wraps. **With a 64-entry queue and four admin commands the wrap never
runs**, so a driver with inverted flip logic would pass every gate that could
be built on it — the M33 shape exactly.

The admin queues are therefore **two entries**, the specification's minimum, so
the ordinary bring-up wraps them twice with no artificial padding command. The
gate reads the head and phase back:

    the admin completion queue's phase is 1 after wrapping, head at 0

Phase 1 with head 0 after four commands is two full laps. M80 removes the flip
and the bring-up spins out.

### The interrupt claim is narrow, because the vector is shared

There is one MSI vector and the xHCI already owns it; `irq_handler` calls both
drains and each answers nothing for an interrupt that was not its. So "an
interrupt arrived" says nothing about NVMe.

What the gate asserts instead is a counter incremented **only inside
`nvme_isr`, and only when a completion was actually consumed there**. M85 makes
the read complete by polling instead, and that counter stays at zero.

### Mutations

| # | Injected defect | Detected? | How it surfaced |
|---|---|---|---|
| M76 | CC.EN never set | **yes** | bring-up returns −3; `CSTS 0x00000000: the controller is READY` fails |
| M77 | CC.IOSQES and IOCQES left zero | **yes** | bring-up returns **−6** — the controller rejected Create I/O SQ two commands after the bad enable, and the gate names the cause: `CC.IOSQES is 0` |
| M78 | AQA written with the entry count, not count−1 | **yes** | `AQA 0x00020002: both admin queues are 2 entries, written zero-based` |
| M79 | ASQ and ACQ swapped | **yes** | bring-up returns −5; the controller fetches commands from the completion queue and nothing ever completes |
| M80 | the phase tag never flipped on wrap | **yes** | bring-up returns −5 after the first lap; zero completions in interrupt context |
| M81 | the CQ head doorbell never rung | **yes** | bring-up returns −5 once the queue is full |
| M82 | NLB written as the block count | **yes**, after the guard region | escaped first; see above |
| M83 | reads LBA 1 instead of LBA 0 | **yes** | sector 1's signature where sector 0's bytes belong |
| M84 | PRP1's low half left zero | **yes** | bring-up returns −7; Identify writes nowhere useful and the LBA format decodes to nothing |
| M85 | the completion polled rather than taken by interrupt | **yes** | `0 completion(s) were consumed IN INTERRUPT CONTEXT` |

`NVME_BAD` reaches the gate's verdict expression and **M83 is the proof**: it
fails on the sector comparison alone, and the run exits non-zero. That check was
worth making explicitly -- 5.1 shipped a gate whose `XHCI_BAD` was computed and
never reached the verdict, so the summary said FAIL and the gate exited 0.

**Ten cases, ten refused** — the first phase in this project with no escapes,
and the reason is worth naming: this milestone's assertions are mostly about
**arithmetic the controller checks**, not about behaviour QEMU is free to be
lenient over. A controller that is handed a bad AQA or a bad PRP does not
quietly work anyway.

### A defect mmiocheck caught in code that had already booted

`fk_nvme.o` was refused on its first pass through the gate:

    REFUSED  build/boot/fk_nvme.o -- sub-dword access to a device register
      <__fk_nvme_m_MOD_submit.constprop.0>:  1b3: movzbl (%r15),%esi

`submit`'s `opcode` dummy was by-reference, so it lived in memory, and its
value feeds an 8-bit `mvbits` field — **gfortran narrowed the load to a byte.**
That is 3.3's bug in a new place, and the memory in question happened to be a
stack temporary rather than a device register, so it was harmless.

It was still refused, and the refusal is correct: `mmiocheck` reads the object
and cannot tell a stack temporary from a BAR. Every internal helper in the
module now takes its scalars by `value`, so there is no load to narrow. **The
kernel had already booted and read the disk correctly before this was found** —
the gate caught something a working boot could not.

### What 5.3 does NOT claim

- **`fk_nvme.f90` has no host suite.** The other five drivers in this tree have
  one; this does not. A host test would need a controller model of the kind
  `tests/drivers/usb/test_xhci.c` implements — one that executes the submission
  queue when a doorbell is written — and that is real work, not a stub. Until
  it exists, the driver's logic is covered by the boot gate and ten mutations
  and by nothing that runs in two seconds on the host.
- **The disable path is unexercised.** CC.EN is already 0 on this model when
  the kernel first sees it, so "clear EN, poll RDY to 0" returns immediately
  and proves nothing. It is still done, because the machine where firmware HAS
  driven the controller is the one where skipping it corrupts memory the PMM is
  about to hand out.
- **One PRP entry, no PRP list.** Every transfer here is one page-aligned
  buffer, so PRP2 is always zero. A transfer crossing a page boundary needs a
  PRP list and there is not one.
- **One namespace, one I/O queue pair, no writes.** Nothing deletes a queue,
  nothing shuts the controller down, and nothing has ever written a byte to the
  disk.
- **The 2048-block image is smaller than any real drive.** Nothing here has met
  a namespace whose block count needs more than 32 bits, or an LBA format other
  than 512 bytes.

## What is NOT claimed

- **The scratchpad-buffer path in `xhci_start` has never run.** `qemu-xhci`
  reports zero scratchpad buffers, so the DCBAA's entry 0 is left zeroed and the
  allocation path behind it is written and unexercised. The first controller with
  a non-zero count will be the first time it executes.
- **No USB device has been enumerated.** There is no slot, no device context, no
  address-device command, no transfer ring and no port reset. 5.1 deliberately
  built the one thing that needs none of USB.
- **Interrupts are proven to arrive once.** One message reached the handler. A
  handler that clears IMAN.IP so a *second* message can be sent is not exercised
  by a single NO-OP, and the failure mode — exactly one interrupt ever, then
  silence — is precisely the shape M33 has already caught this project out with
  once. Repeated delivery is 5.2's to prove, and it needs at least two events to
  prove it.
- **The command ring has never wrapped in anger.** The link TRB's Toggle Cycle is
  asserted statically, in DRAM, and M54 proves the assertion refuses — but 256
  TRBs is a long way and one NO-OP does not get there.
- **`FK_MACHINE=pc` reaches none of this.** The i440FX board has no ECAM window,
  so it has no xHCI, and the gate turns the xHCI and PCI checks off there rather
  than pretending. That path asserts the *absence* of the 5.1 lines instead.
