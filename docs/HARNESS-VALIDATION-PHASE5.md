# Does the xHCI's test actually catch bugs?

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
