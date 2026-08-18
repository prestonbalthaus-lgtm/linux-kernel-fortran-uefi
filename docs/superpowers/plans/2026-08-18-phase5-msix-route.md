# Roadmap 5.1, first half -- the MSI-X route

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the xHCI an interrupt route it can actually use. 4.2's debt paid the configuration-space half; this is the half that lives in DEVICE memory. The controller itself is still untouched: no reset, no rings, no doorbells.

**Architecture:** An MSI-X table entry is not configuration space. It sits behind BAR0, so the BAR is taken out of the linear map with `vmm_punch_physmap` and mapped strong-UC at `FK_VMM_XHCI` -- the same treatment the LAPIC, the I/O APIC and the ECAM window get, and for the same reason. The entry is then written through `fk_readl`/`fk_writel` like every other device register in this tree. The message itself is architectural rather than PCI: `lapic_msi_addr`/`lapic_msi_data` build the SDM Vol.3 11.11 address and data, and they live in `fk_lapic_m` because that is where this kernel keeps its knowledge of the APIC.

**Tech Stack:** Fortran 2018 (`gfortran`, free form, `iso_c_binding`), C test drivers against `tests/harness/fk_test.h`, Python 3 + QMP, podman dev container `fortran-kernel-dev:f44`.

## Global Constraints

- Branch: `phase5/msix-route`, cut from `master` at `508d777`.
- EVERY build runs in the container: `./tools/run.sh <target>`.
- `tools/compliance.sh` rules, all six. No Fortran I/O in `src/`.
- Gates green before the PR: `compliance.sh`, `run.sh test`, `linkscript`, `selftest`, `bootgate`, `qmp-sentinel.py selftest`, and `qemu-boot-test.sh` on q35, under `FK_MACHINE=pc` and under `FK_FIRMWARE=uefi`.

## Measured facts this plan is built on

Taken from the running machine, not from memory:

- `qemu-xhci` on this gate's q35 lands at **00:02.0**, `1b36:000d`, BAR0 `0xFEBF0000`, MSI-X capability at **0x90**, **16** entries, BAR **0**, table offset **0x3000**.
- QEMU's monitor can read all of it from OUTSIDE the guest. `xp` goes through the memory API, so it dispatches to device models exactly as a guest access would:
  - configuration space through the ECAM window (`xp /4xw 0xB0018000` -> `0x000d1b36 0x00100107 ...`),
  - the MSI-X capability (`xp /4xw 0xB0018090` -> `0x000fa011 0x00003000 0x00003800`),
  - and the table itself (`xp /4xw 0xFEBF3000` -> `0 0 0 1`, the reset state: masked).
- A BAR whose memory-space decode is off answers `Cannot access memory`. That is not a monitor limitation; it is the BAR genuinely not being mapped, and it makes "is the decode really on" checkable from the host.

## The order, and why every step of it is load bearing

1. **The IDT gate exists first.** `idt_init` installs `FK_VECTOR_MSI` unconditionally, exactly as 3.3 installs the spurious vector, and for the same reason: a vector the IDT does not describe is a #GP during delivery the instant the first message lands.
2. **Map the BAR**, punch its write-back alias, strong-UC.
3. **Write the entry MASKED**, address and data, then clear the mask LAST. PCI 3.0 6.8.3.5: an entry may only be changed while masked. An entry unmasked halfway through can send a message built from two different routes.
4. **Set MSIX_ENABLE and clear MASKALL in one write.** A programmed table behind a set function mask is a device with a route it cannot use.
5. **Disable INTx LAST.** A controller with neither a wire nor a working message raises nothing at all, which is a hang rather than a diagnostic.

## File Structure

| File | Responsibility |
|---|---|
| `src/cpu/fk_lapic.f90` (modify) | `lapic_msi_addr`, `lapic_msi_data` -- the SDM message format. |
| `src/drivers/bus/fk_pcie.f90` (modify) | `pcie_msix_entry_set/read/addr`, `pcie_msix_enable`, `pcie_msix_ctrl`, `pcie_intx_disable`. |
| `boot/interrupts.S` (modify) | `IRQ 16` -- a stub that is not a line. |
| `src/cpu/fk_idt.f90` (modify) | `FK_VECTOR_MSI`, `FK_MSI_LINE`, `fk_msi_count`, the install and the handler branch. |
| `src/mm/fk_vmm.f90` (modify) | `FK_VMM_XHCI`. |
| `src/boot/fk_kmain.f90` (modify) | `xhci_route`, its verdicts, two more published words. |
| `tests/cpu/test_lapic.c`, `tests/drivers/bus/test_pcie.c` (modify) | The message format; the route, including WRITE ORDER. |
| `tools/qmp-sentinel.py` (modify) | Read the route out of QEMU's device model and diff it against the guest's. |
| `tools/qemu-boot-test.sh` (modify) | The new verdict lines and their FAIL twins. |

---

### Task 1: The message format

- [ ] `lapic_msi_addr(dest)`: 0FEEh in 31:20, destination APIC id in 19:12, redirection hint and destination mode zero -- physical, this exact APIC.
- [ ] `lapic_msi_data(vector)`: vector in 7:0, delivery mode and trigger left zero (FIXED, EDGE).
- [ ] Host assertions including destination 256, which must NOT climb into the fixed prefix.

### Task 2: The table

- [ ] `pcie_msix_entry_addr` -- 16-byte stride, exposed so the test can assert it rather than infer it.
- [ ] `pcie_msix_entry_set` -- mask, address, data, unmask, in that order, four dwords, no wider access.
- [ ] `pcie_msix_entry_read` -- one of the four fields, anything else refused.
- [ ] The host test must assert the ORDER, not just the contents: final contents cannot show it.

### Task 3: The enable, and INTx

- [ ] `pcie_msix_enable` -- dword RMW at the capability, ENABLE set and MASKALL cleared together. `cap_id`/`cap_next` in the low half are read-only, so echoing them is inert.
- [ ] `pcie_intx_disable` -- COMMAND bit 10, status half zeroed like every other COMMAND write.

### Task 4: The vector

- [ ] `IRQ 16` in `boot/interrupts.S`: a stub pushing one past the last real line.
- [ ] `FK_VECTOR_MSI = 0x30`, above the 8259's range and below the spurious vector.
- [ ] `irq_handler` branches on `FK_MSI_LINE` BEFORE the 8259 spurious logic, which is indexed by line number and must not see it. Count, EOI at the LAPIC, return. No `sched_tick`.
- [ ] `fk_msi_count` is `bind(c)` so the host can read it. It will be ZERO until the controller is started, and nothing may claim otherwise.

### Task 5: The proof, from outside the guest

- [ ] `xp_words` in the sentinel: read guest physical addresses through the memory API.
- [ ] Read COMMAND and the MSI-X capability through ECAM, and entry 0 through BAR0.
- [ ] Assert against the DEVICE's state: decode and mastering on, INTx off, MSI-X enabled, function mask clear, entry 0 addressed at CPU 0's APIC, carrying the vector, unmasked.
- [ ] Diff that against what the guest published. A kernel that printed the value it MEANT to write passes its own check and fails this one.
- [ ] Selftest fixtures for each failure: masked entry, unwritten entry, wrong vector, non-zero high half, MSI-X disabled, function mask set, INTx still on, BAR not decoded, and guest-versus-device disagreement.

### Task 6: Mutations, run and stated

- [ ] Host: unmask before the address; stride 8 instead of 16; enable that sets MASKALL; the destination shifted by 8.
- [ ] In-guest: the final unmask removed; `pcie_msix_enable` never called; INTx never disabled. Each must take the boot gate to exit 1, and the failing assertion is to be quoted.

### Task 7: Documentation

- [ ] `roadmap.md`: 5.1's box keeps its unticked checkbox -- the CONTROLLER is untouched, and the box's validation line is about rings, not routes.
- [ ] `04-state.md` at the end, per CLAUDE.md.

## What this milestone deliberately does not do

**No interrupt has been observed arriving, and none can be yet.** The controller has not been reset, its interrupter is not enabled and R/S is clear, so it has nothing to signal. `fk_msi_count` is therefore 0 and the gate does not assert otherwise. Making one arrive is the controller's half of 5.1: reset, DCBAA, the command ring, the event ring and ERST, then a NO-OP command whose completion is polled. 5.1's own validation line is satisfiable by polling; an interrupt actually firing belongs to 5.2.

The MSI-X entry overlay in `fk_pcie_types.f90` still carries a comment saying the overlay must be VOLATILE. It predates 3.3, which proved VOLATILE does not forbid NARROWING, and the table is reached through `fk_readl`/`fk_writel` like everything else. Correcting that comment belongs with the next change that touches the type.
