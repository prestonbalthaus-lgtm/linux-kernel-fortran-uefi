# Roadmap 5.1, second half -- the controller

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close 5.1. Reset the controller, build the data structures it reads by DMA, run it, and get a command through it -- proved by the completion event the controller itself wrote into RAM, and by the MSI-X message arriving at the handler the route half installed.

**Architecture:** `fk_xhci_m` is a driver over `fk_xhci_types_m`'s layouts. Every register access is `fk_readl`/`fk_writel` at a byte offset, because a Fortran pointer to a device register is what 3.3 banned. The rings go through the same accessors even though they are RAM: they are RAM a bus master writes, and gfortran narrows a load from them exactly as it narrowed one from an APIC register. The rings come from `pmm_alloc_contiguous`, one four-page run carved into DCBAA, command ring, event ring and ERST, so there is one physical base for the host to check and page alignment satisfies every alignment the specification asks for.

**Tech Stack:** Fortran 2018 (`gfortran`, free form, `iso_c_binding`), C test drivers against `tests/harness/fk_test.h`, Python 3 + QMP, podman dev container `fortran-kernel-dev:f44`.

## Measured facts this plan is built on

Taken off the running controller with QEMU's monitor, not recalled:

- `qemu-xhci`: CAPLENGTH **0x40**, HCIVERSION **0x0100**, **64 slots**, 16 interrupters, 8 ports, **ERSTMax = 2^0 = ONE segment**, **zero scratchpad buffers**, AC64 set, CSZ clear (32-byte contexts), PAGESIZE 4096, RTSOFF 0x1000, DBOFF 0x2000.
- **CNR is never set by this model.** HCRST completes inside the MMIO write. The wait is still written, because real hardware does set it and the only legal register until it clears is USBSTS.
- **There is no USB Legacy Support capability**, so no BIOS handoff is possible or needed here.
- **A NO-OP completion raises the MSI-X message synchronously**, inside the doorbell write: `xhci_doorbell_write -> xhci_process_commands -> xhci_event -> xhci_intr_raise -> msix_notify`. Six conditions must all hold or it is dropped silently: bus master, R/S, USBCMD.INTE, IMAN.IE, ERDP.EHB clear, and MSI-X enabled with entry 0 unmasked.
- **SeaBIOS has already driven the controller**: CRCR 0x7FFDFC01, DCBAAP 0x7FFDFD80, ERSTBA 0x7FFDFD40, ERSTSZ 1. Those point into firmware memory the PMM is about to re-issue, which is what the reset is for -- and what makes "the pointers look plausible" a worthless assertion.

## Order, and what each step is load bearing for

1. **Halt, then HCRST.** Resetting a running controller is undefined. Then two waits: HCRST is self-clearing, and USBSTS.CNR must read 0 before any operational register other than USBSTS may be touched.
2. **CONFIG.MaxSlotsEn**, then the DCBAA, zeroed, its physical address into DCBAAP. Entry 0 is the scratchpad array pointer when the controller asks for buffers and 0 when it does not.
3. **Command ring:** zeroed, a LINK TRB in the last slot pointing back at the base with **Toggle Cycle** set. CRCR gets the base with **RCS = 1**, matching the cycle the TRBs are written with.
4. **Event ring:** segment zeroed, one ERST entry naming it and its length in TRBs, **ERSTSZ = 1 because it counts SEGMENTS**, then ERSTBA, then ERDP at the segment base with EHB cleared.
5. **Both interrupt gates:** IMAN.IE and USBCMD.INTE. Either one clear and the event is posted with no message sent and nothing to show for it.
6. **R/S.** Only then does a doorbell mean anything.
7. **NO-OP, doorbell 0, poll.** The completion's parameter is the PHYSICAL address of the command TRB, bits 63:4.

## File Structure

| File | Responsibility |
|---|---|
| `src/drivers/usb/fk_xhci_types.f90` (modify) | Per-register byte offsets; the layouts alone cannot be used for MMIO. |
| `src/drivers/usb/fk_xhci.f90` (create) | The driver. |
| `tests/drivers/usb/test_xhci.c` (create) | A CONTROLLER model, not a register file. |
| `mk/xhci.mk` (create) | Wire it into `run.sh test`. |
| `Makefile.boot` (modify) | Both modules into `FSRC_KERNEL`; `fk_xhci.o` onto `mmiocheck-boot`. |
| `src/boot/fk_kmain.f90` (modify) | `xhci_start`, the ring allocation, the verdicts, `fk_xhci_state`. |
| `tools/qmp-sentinel.py` (modify) | An `xhci` subcommand reading both rings at their physical bases. |
| `tools/qemu-boot-test.sh` (modify) | The check, its verdict lines, and the pc-machine rejects. |
| `roadmap.md` (modify) | Tick 5.1. |

---

### Task 1: Offsets and the driver

- [ ] Byte offsets for the capability, operational and interrupter registers.
- [ ] `xhci_attach` -- CAPLENGTH, DBOFF and RTSOFF are the only way to find the other blocks.
- [ ] Capability decode, including scratchpads as **HI*32 + LO** across two non-adjacent fields.
- [ ] `xhci_halt`, `xhci_reset` with both waits, bounded spins throughout -- there is no clock in this path.
- [ ] The ring builders, the two enables, `xhci_run`, `xhci_cmd_noop`, `xhci_doorbell`, `xhci_event_poll`.
- [ ] 64-bit registers as two dwords, low half first, composed from scratch and never read-modify-written: CRCR's pointer reads as 0 on real hardware, so an RMW writes back a null pointer.

### Task 2: The host model

- [ ] Registers with behaviour: HCRST self-clears and restores defaults, CNR held for three reads, USBSTS write-1-to-clear, IMAN.IP and ERDP.EHB write-1-to-clear.
- [ ] Firmware's leftovers programmed in at reset time, so "did the driver reset it" is answerable.
- [ ] A doorbell that EXECUTES the ring, follows the link, toggles its own cycle, posts a completion event.
- [ ] ERSTSZ policed against ERSTMax, answering a wrong value with HCE the way the silicon did.
- [ ] `msi_sent` counted only when both gates are open and EHB is clear.
- [ ] A write LOG over ring memory, because the "cycle bit last" rule cannot be caught by executing the ring -- neither this model nor QEMU looks at a TRB until the doorbell.
- [ ] A stray-pointer counter, so a driver that hands the controller an address outside its rings fails an assertion instead of crashing the model.

### Task 3: The proof from outside

- [ ] `fk_xhci_state`, published: BAR, the run, all four structures, the NO-OP TRB, the event, USBSTS/CRCR/ERDP, the MSI count, and **CRCR/DCBAAP/USBSTS as read immediately after the reset and before anything is programmed**.
- [ ] The sentinel pmemsaves both rings AT THEIR PHYSICAL BASES and checks: the NO-OP TRB's type and cycle, the link TRB's Toggle Cycle and back-pointer, the completion event's type, cycle, code and command pointer.
- [ ] Registers through `xp`, and `fk_msi_count` read from its symbol.
- [ ] The post-reset snapshot is the assertion that the reset happened: firmware's values are non-zero and a kernel that skips the reset publishes them.

### Task 4: Mutations, run and stated

- [ ] Host: ERSTSZ counting TRBs; the link TRB without Toggle Cycle; a producer cycle that never flips; CRCR without RCS; an ERDP that never advances; the CNR wait removed; INTE never set; the cycle bit written first.
- [ ] In-guest: IMAN.IE never set; the reset skipped; ERSTSZ counting TRBs. Each must take the boot gate to exit 1.

## What this milestone deliberately does not do

No slots are enabled, no device contexts exist, there are no transfer rings, no port is reset and nothing goes on the wire. The scratchpad path is written and NOT exercised, because this controller asks for zero buffers. 5.2 is the keyboard; it needs slots, contexts and a transfer ring, and none of that is here.
