# Roadmap 4.2 debt -- PCIe configuration WRITES, the capability walk, and MSI-X discovery

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pay the three things 4.2 left on its WHAT IS NOT DONE list that 5.1 cannot start without: configuration-space WRITES, a COMMAND-register read-modify-write that turns on memory-space decode and bus mastering, and a capability-list walk that finds the MSI-X block and decodes where its table lives. Find, enable, report. No controller register is touched and no ring exists yet.

**Architecture:** `fk_pcie_m` gains a write path that is a WHOLE DWORD and nothing else, for the same reason its read path is: `tools/mmiocheck.sh` refuses a sub-dword access to a device register, and its regex covers `movb`/`movw` stores as well as narrowed loads. Every register this milestone writes is therefore written as a dword whose bits outside the target field are chosen so the write is inert -- see the two decisions below, which are the whole of the hardware risk here. The capability walk is a bounded pointer chase through the function's own configuration space, and MSI-X discovery ends at a (BAR index, byte offset, table size) triple. Mapping that table and programming an entry is 5.1's, not this.

**Tech Stack:** Fortran 2018 (`gfortran`, free form, `iso_c_binding`), C test drivers against `tests/harness/fk_test.h`, Python 3 + QMP, podman dev container `fortran-kernel-dev:f44`.

## Global Constraints

- Branch: `phase4/pcie-config-writes`, cut from `master` at `0b9b81e`.
- EVERY build runs in the container: `./tools/run.sh <target>`. Never `make -f Makefile.boot` on the host.
- `tools/compliance.sh` rules, all six: SPDX line 1; `implicit none` per program unit; no `goto`/`common`/`equivalence`; every public procedure `bind(c, name=...)` (public `parameter`s exempt); `use, intrinsic :: iso_c_binding`; no line starting with exactly five spaces then non-space.
- No Fortran I/O anywhere in `src/`.
- Gates green before the PR: `compliance.sh`, `linktest.sh`, `linkscript-test.sh`, `gate-selftest.sh`, `run.sh test`, `run.sh bootgate`, `run.sh iso`, `qemu-boot-test.sh` on q35 and under `FK_MACHINE=pc`. Baseline at the merge base: linkscript-test 175/0, gate-selftest 27/0, bootgate 10/0 + mmiocheck 2/0, qmp-sentinel selftest 84/0, pcie host suite as `run.sh test` reports it.

## Measured facts this plan is built on

Taken from this tree at `0b9b81e`, not from memory:

- `fk_pcie.f90` has read entry points only. `grep -n 'cfg_write\|pcie_write' src/` is empty.
- `boot/io.S` already exports `fk_writel` (`movl %esi,(%rdi)`; ret) and nothing in `src/` calls it yet outside the APIC modules.
- `tools/mmiocheck.sh`'s `BAD_RE` matches `movz[bw][lq]?` **and** `mov[bw]` with a parenthesised operand, so it polices narrow STORES too. `mmiocheck-boot` names `fk_lapic.o` and `fk_ioapic.o` explicitly; `fk_pcie.o` is not on that list and must be added by this change.
- `check_pci` in `tools/qmp-sentinel.py` parses `info pci` off the LIVE monitor and diffs it against the guest's published list AS SETS. Adding a device to the gate grows both sides at once. The only hardcoded five-function tree is `Q35_FNS`/`Q35_PCI` inside the sentinel's own `--selftest`, which exists to prove the comparison refuses a missed and an invented function.
- `fk_pcie_types_m` already carries every constant this needs: `FK_PCI_CMD_MEMORY_BIT` (1), `FK_PCI_CMD_MASTER_BIT` (2), `FK_PCI_STATUS_CAP_LIST_BIT` (4), `FK_PCI_CAP_PTR_POS/LEN`, `FK_PCI_CAP_ID_MSIX` (0x11), `FK_PCI_MSIX_CTRL_QSIZE_POS/LEN`, `FK_PCI_MSIX_BIR_POS/LEN`, `FK_PCI_MSIX_OFFSET_POS`, `FK_PCI_BAR_MEM_TYPE_64`, `FK_PCI_BAR_MEM_ADDR_POS`. Nothing new belongs in that file.

## The two hardware decisions, and why each write is inert outside its field

**COMMAND is written as the dword at 0x04 with the STATUS half ZEROED, never echoed back.** COMMAND is the low 16 bits of that dword and STATUS is the high 16. STATUS bits are read-only or RW1C. Writing 0 to an RW1C bit is defined as no effect, and a read-only bit ignores a write entirely -- so a dword write carrying zeros above bit 15 changes COMMAND and nothing else. Reading the dword and writing it back UNCHANGED would be the bug: any error bit that happened to be set gets a 1 written to it and is silently cleared. This is why there is no general `pcie_cfg_write16`. A dword-RMW write16 aimed at any register whose other half is RW1C destroys state, and one exists at 0x04 on every function in the machine.

**The MSI-X message-control write, when 5.1 makes it, is the dword at cap+0 with the ID/next half echoed.** `cap_id` and `cap_next` are read-only, so echoing them back is inert, and message control occupies bits 31:16 of that dword. This plan does not write it; the reasoning is recorded here because the decode it lands is what 5.1 will write through.

## File Structure

| File | Responsibility |
|---|---|
| `src/drivers/bus/fk_pcie.f90` (modify) | `pcie_cfg_write32`, `pcie_cmd_enable`, `pcie_command`, `pcie_find_cap`, `pcie_msix_*`, `pcie_bar64`. |
| `tests/drivers/bus/test_pcie.c` (modify) | Supply `fk_writel` into the arena; fixtures for the cap chain, the malformed chains, MSI-X and a 64-bit BAR. |
| `Makefile.boot` (modify) | `fk_pcie.o` onto `mmiocheck-boot`'s explicit list. |
| `src/boot/fk_kmain.f90` (modify) | Enable the xHCI's decode and mastering, walk its caps, report, publish over QMP. |
| `tools/qemu-boot-test.sh` (modify) | `-device qemu-xhci`; the new PASS/FAIL verdict lines; the five-function prose. |
| `tools/qmp-sentinel.py` (modify) | Assert COMMAND read-back and the MSI-X triple; grow the self-test fixture to six functions. |
| `roadmap.md` (modify) | Move these three off 4.2's NOT DONE list; leave BAR sizing and bridge programming on it. |

---

### Task 1: The write path

- [ ] `pcie_cfg_write32(bus, dev, fn, off, val)`: same four bounds checks as `pcie_cfg_read32`, same `iand(off, not(3))` alignment, `fk_writel` through the window. A rejected access writes NOTHING and returns a status, because a silently dropped write to a device is worse than a refused one.
- [ ] No `pcie_cfg_write16`, no `pcie_cfg_write8`. The reason goes in the comment above `pcie_cfg_write32`, in two lines.

### Task 2: COMMAND

- [ ] `pcie_command(i)` -- read the current 16-bit COMMAND of recorded device `i`.
- [ ] `pcie_cmd_enable(i)` -- read dword 0x04, set `FK_PCI_CMD_MEMORY_BIT` and `FK_PCI_CMD_MASTER_BIT` in its low half, write it back with the high half ZERO, then read COMMAND again and return the read-back rather than the value written. A device that refuses a bit must not be reported as having taken it.
- [ ] INTx disable (`FK_PCI_CMD_INTX_DISABLE_BIT`) is NOT set here. It belongs with the MSI-X enable in 5.1, and setting it before a message route exists leaves a device that can raise nothing at all.

### Task 3: The capability walk

- [ ] `pcie_find_cap(i, cap_id)` -> byte offset or `FK_PCIE_NOT_FOUND`.
- [ ] Refuse before walking if `FK_PCI_STATUS_CAP_LIST_BIT` is clear in STATUS: a function without the bit has no chain and whatever is at 0x34 is not a pointer.
- [ ] Mask each pointer with `FK_PCI_CAP_PTR_POS/LEN` semantics (low two bits are reserved and read as zero on real parts, not guaranteed on all).
- [ ] Reject an offset below 0x40 -- the header itself -- and one above 0xFF.
- [ ] TTL-bound the chase at 48 hops, the same bound Linux uses, so a chain that points at itself terminates instead of hanging the boot.
- [ ] `pcie_cap_hops(i)` exposes the hop count for the test to assert against, because a walk that finds the right capability by accident on the first hop proves nothing about the chase.

### Task 4: MSI-X discovery and the 64-bit BAR

- [ ] `pcie_msix_at(i)` -> the capability offset, or NOT_FOUND.
- [ ] `pcie_msix_count(i)` -> table size, decoded as `QSIZE + 1` (the field is N-1, and an off-by-one here is an entry the driver never programs).
- [ ] `pcie_msix_bir(i)`, `pcie_msix_offset(i)` -> which BAR the table lives in and its byte offset inside it. The offset field is bits 31:3 and is ALREADY a byte offset; it is not shifted.
- [ ] `pcie_bar64(i, n)` -> the firmware-assigned 64-bit address of BAR `n`, combining `n` and `n+1` when the memory-type field is `FK_PCI_BAR_MEM_TYPE_64`, masking with `FK_PCI_BAR_MEM_ADDR_POS`, and refusing an I/O-space BAR.
- [ ] BAR SIZING IS NOT IN THIS MILESTONE. Writing all ones and reading back the size stays on 4.2's NOT DONE list; the firmware has already assigned these and the kernel is a consumer of that assignment.

### Task 5: The host test, and the defects it must refuse

- [ ] The arena gains `fk_writel`. Every write assertion checks TWO things: the target dword became what was written, AND the dwords either side of it are still 0xFF poison. A write that lands one dword off is the failure worth refusing.
- [ ] COMMAND: enable on a function whose STATUS half carries set RW1C bits, and assert those bits SURVIVE. This is the assertion the whole "zero the high half" decision exists for.
- [ ] Cap chain fixtures: a normal three-link chain ending in MSI-X; a function with the CAP_LIST status bit CLEAR; a chain whose first pointer is below 0x40; a chain that points back at itself; a chain longer than the TTL.
- [ ] MSI-X: a table size of 8 encoded as 7, a non-zero BIR, and a non-zero table offset -- all three wrong-by-construction if the decode is naive.
- [ ] A 64-bit BAR whose high dword is non-zero, so a 32-bit-only decode is visibly wrong rather than accidentally right.
- [ ] Mutations to be RUN and shown failing, with their numbers stated: (a) `pcie_cmd_enable` echoing the status half instead of zeroing it; (b) the TTL removed; (c) MSI-X count returning QSIZE rather than QSIZE+1; (d) `pcie_bar64` ignoring the high dword.

### Task 6: The gate

- [ ] `-device qemu-xhci` in `QEMU_ARGS`. The PCI set check needs no change -- it is live on both sides -- and that is stated in the gate's header rather than assumed.
- [ ] `Q35_FNS`/`Q35_PCI` in the sentinel's `--selftest` grow to six functions so the fixture still mirrors the machine the gate runs.
- [ ] `fk_pcie.o` added to `mmiocheck-boot`.
- [ ] New verdict lines, each with a FAIL twin the gate rejects: the xHCI was found; memory-space and bus-master decode read back SET; the MSI-X capability was found at its offset with N entries in BAR b.
- [ ] The sentinel asserts the COMMAND read-back and the MSI-X triple out of `fk_pcie_devs`, from outside the guest, against `info pci`'s own view of the device.

### Task 7: Documentation

- [ ] `roadmap.md`: 4.2's WHAT IS NOT DONE loses the capability walk and gains nothing; 5.1's blocker list loses the config writes. BAR sizing, bridge secondary-bus programming and one-segment-group stay exactly where they are.
- [ ] `04-state.md` at the end, per CLAUDE.md.

## What this milestone deliberately does not do

MSI-X is DECODED, not ENABLED: no table mapping, no message address or data written, no vector allocated, INTx left alone. Enabling a route the kernel cannot yet service would be a device raising an interrupt into an IDT entry that does nothing. That is 5.1's first task and it is the point at which the MSI-X entry overlay in `fk_pcie_types.f90` -- whose comment still says "the overlay must be VOLATILE", written before 3.3 proved VOLATILE does not forbid narrowing -- gets `fk_readl`/`fk_writel` and a corrected comment.
