# Roadmap 4.2 -- PCIe Bus Enumeration via ECAM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Find the ECAM window in the ACPI MCFG table, map it uncached, walk it, and print every device the machine has to the GOP console -- then prove that list against QEMU's own PCI tree from outside the guest.

**Architecture:** Legacy CF8/CFC port I/O is not implemented and will not be. `fk_mcfg_m` decodes the MCFG table `fk_acpi_m` already finds by signature; `fk_pcie_m` turns a (bus, device, function, offset) into an ECAM address using the shift constants `fk_pcie_types_m` already carries, reads config space through the mapped window, and records what it finds. The window is discovered after the linear map exists, so its write-back alias is removed with `vmm_punch_physmap` -- the primitive `phase3/ioapic-routing` lands -- and only then mapped strong-uncacheable at a fixed virtual sub-window. The boot gate moves to `-machine q35`, because the default i440FX machine has no MCFG table at all.

**Tech Stack:** Fortran 2018 (`gfortran`, free form, `iso_c_binding`), C test drivers against `tests/harness/fk_test.h`, Python 3 + QMP, podman dev container `fortran-kernel-dev:f44`.

## Global Constraints

- Branch: `phase4/pcie-ecam`, cut from `master` AFTER `phase3/ioapic-routing` has merged. It consumes `vmm_punch_physmap` and will not build without it.
- EVERY build runs in the container: `./tools/run.sh <target>`.
- `tools/compliance.sh` rules, all six: SPDX line 1; `implicit none` per program unit; no `goto`/`common`/`equivalence`; every public procedure `bind(c, name=...)` (public `parameter`s exempt); `use, intrinsic :: iso_c_binding`; no line starting with exactly five spaces then non-space. Derived-type components indent FOUR.
- No Fortran I/O anywhere in `src/`.
- `FSRC_KERNEL` in `Makefile.boot` names its sources ONE BY ONE and does not currently carry `fk_pcie_types.f90`. Adding the enumerator means adding `fk_pcie_types.f90`, `fk_mcfg.f90` and `fk_pcie.f90` in dependency order. A change that only creates files gets a link failure.
- Gates green before the PR: `compliance.sh`, `linktest.sh`, `linkscript-test.sh`, `gate-selftest.sh`, `run.sh test`, `run.sh bootgate`, `run.sh iso`, `qemu-boot-test.sh`. Baseline 171/0 and 27/0 as of `master`; `phase3/ioapic-routing` raises both, so re-baseline against the merge base rather than against these numbers.

## Measured facts this plan is built on

Taken from this machine, not from memory:

- Default QEMU machine (i440FX): ACPI root is the RSDT with **4 tables**. No MCFG. There is no ECAM window to find.
- `-machine q35`: **5 tables**, the fifth being MCFG. Same ISO, same SeaBIOS, boots identically -- verified.
- `physmap-top` is `0x680000000` (26 GiB) on q35 with `-m 24G`, so a `0xB0000000` ECAM window is INSIDE the linear map and its write-back alias is real. It must be punched.
- q35's PCI tree, from `info pci`, is exactly five functions:

  | BDF | Vendor:Device | What |
  |---|---|---|
  | 00:00.0 | 8086:29c0 | Host bridge |
  | 00:01.0 | 1234:1111 | VGA controller |
  | 00:1f.0 | 8086:2918 | ISA bridge |
  | 00:1f.2 | 8086:2922 | SATA controller |
  | 00:1f.3 | 8086:2930 | SMBus |

  Device `0x1f` is multifunction with functions 0, 2 and 3 present and function 1 absent -- which is what makes it a real test of the header-type multifunction bit and of skipping gaps.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/acpi/fk_mcfg.f90` (create) | Decode the MCFG table: ECAM base, segment, start/end bus, per allocation entry. |
| `src/drivers/bus/fk_pcie.f90` (create) | ECAM addressing, config-space reads, the enumeration walk, and the device table it fills. |
| `tests/acpi/test_mcfg.c` (create) | Reference-model test: a hand-built MCFG plus every malformed one. |
| `tests/drivers/bus/test_pcie.c` (create) | Reference-model test: a synthetic config space in ordinary memory. |
| `mk/mcfg.mk`, `mk/pcie.mk` (create) | Wire both into `./tools/run.sh test`. |
| `Makefile.boot` (modify) | Add the three modules to `FSRC_KERNEL` in dependency order. |
| `src/mm/fk_vmm.f90` (modify) | `FK_VMM_ECAM` sub-window constant. |
| `src/boot/fk_kmain.f90` (modify) | `pcie_bringup()`, its verdicts, and `fk_pcie_devs`. |
| `tools/qmp-sentinel.py` (modify) | `pci` subcommand: `info pci` versus the guest's own table. |
| `tools/qemu-boot-test.sh` (modify) | `-machine q35`, `FK_MACHINE` override, new expectations. |
| `roadmap.md` (modify) | Tick 4.2. |

---

### Task 1: The MCFG decoder

**Files:**
- Create: `src/acpi/fk_mcfg.f90`
- Create: `tests/acpi/test_mcfg.c`
- Create: `mk/mcfg.mk`

**Interfaces:**
- Consumes: `fk_memcmp` from `fk_string_m` -- the signature check, exactly as `fk_madt_m` does it. `fk_string.f90` must come FIRST in `FSRC_mcfg` or `fk_string_m.mod` will not exist when this compiles.
- Produces: `mcfg_parse(virt, len) -> int32`; `mcfg_count() -> int32`; `mcfg_base(i) -> int64`; `mcfg_segment(i) -> int32`; `mcfg_bus_start(i) -> int32`; `mcfg_bus_end(i) -> int32`; `mcfg_bytes(i) -> int64`; and `FK_MCFG_OK = 0`, `FK_MCFG_E_NULL = 1`, `FK_MCFG_E_LEN = 2`, `FK_MCFG_E_SIG = 3`, `FK_MCFG_E_CHECKSUM = 4`, `FK_MCFG_E_TRUNC = 5`, `FK_MCFG_E_TOO_MANY = 6`, `FK_MCFG_E_BUS_RANGE = 7`, `FK_MCFG_MAX_ALLOC = 8`, `FK_MCFG_MIN_LEN = 44`.

The table's layout, from the PCI Firmware Specification 3.0 section 4.1.2, cross-checked against `vendor/linux-7.1.8/drivers/acpi/pci_mcfg.c` and `include/acpi/actbl1.h`, with the file and line beside each offset in the source:
- Bytes 0..35: the standard ACPI description header. Signature `"MCFG"`, length at offset 4, checksum at offset 9 -- the whole table must sum to zero mod 256.
- Bytes 36..43: 8 reserved bytes. **This gap is the whole trap.** A decoder that starts the entries at 36 reads the base address out of the reserved field and gets 0.
- From byte 44, an array of 16-byte allocation entries: base address (u64 at +0), PCI segment group (u16 at +8), start bus (u8 at +10), end bus (u8 at +11), reserved (u32 at +12).
- `mcfg_bytes(i)` is `(bus_end - bus_start + 1) << 20`.

- [ ] **Step 1: Write the failing test**

`tests/acpi/test_mcfg.c`, modelled on `tests/acpi/test_madt.c` -- read that file first and copy its shape, including the poisoned arena, the eight unaligned base addresses, and the PROT_NONE guard page. The reference table is the one q35 hands over: one allocation entry, base `0xB0000000`, segment 0, buses 0 to 255.

Checks that must be present:
- A good one-entry table parses, `mcfg_count()` is 1, `mcfg_base(0)` is `0xB0000000`, `mcfg_bus_start(0)` is 0, `mcfg_bus_end(0)` is 255, `mcfg_bytes(0)` is `0x10000000`.
- Bit-identical answers at all eight byte offsets. This is not decoration: on the BIOS path the RSDT sits at `0x7FFE2525`, so nothing it points at is even 4-byte aligned.
- The base address is read as a full 64 bits. Build an entry with base `0x1_0000_0000` and assert it comes back whole -- a decoder that reads a u32 answers 0 and looks fine on QEMU forever.
- A two-entry table gives two distinct entries.
- Malformed tables are REFUSED, each with its own code: null pointer, length below `FK_MCFG_MIN_LEN`, wrong signature, bad checksum, a length that claims more entries than the bytes hold, more than `FK_MCFG_MAX_ALLOC` entries, and `bus_end < bus_start`.
- A table ending exactly at the PROT_NONE boundary parses without reading past its declared length. A read one byte over is a SIGSEGV, which is the point.

`mk/mcfg.mk`:

```make
TESTS                 += mcfg
# ORDER IS SEMANTIC: mcfg_parse checks the "MCFG" signature with fk_memcmp,
# so fk_string_m.mod must exist before src/acpi/fk_mcfg.f90 compiles.
FSRC_mcfg             := src/lib/fk_string.f90 src/acpi/fk_mcfg.f90
DRV_mcfg              := tests/acpi/test_mcfg.c

# No ORACLE_mcfg, for mk/madt.mk's reason: this is a translation of the PCI
# Firmware Specification 3.0 section 4.1.2, not of one C function.  Linux's
# pci_mcfg.c needs an initialised ACPI namespace to say anything at all.
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./tools/run.sh test`
Expected: FAIL -- no `src/acpi/fk_mcfg.f90`.

- [ ] **Step 3: Write the module**

`src/acpi/fk_mcfg.f90`, following `src/acpi/fk_madt.f90` line for line in structure: SPDX first, `use, intrinsic :: iso_c_binding`, a module-level `integer(c_int8_t), pointer :: tab(:)` set from `c_f_pointer` on the virtual address, every multi-byte field assembled BYTE BY BYTE from that array rather than by pointer-casting a wider type, because nothing about an ACPI table is aligned.

Take the u64 base with an explicit 8-byte assembly. `ishft` on a `c_int64_t` with a byte promoted from `c_int8_t` needs the sign masked off at every step -- `iand(int(tab(k), c_int64_t), 255_c_int64_t)` -- or a byte with bit 7 set poisons every higher byte. That is the exact class of bug the 4.1 review caught twice.

- [ ] **Step 4: Run the tests**

Run: `./tools/run.sh test`
Expected: PASS, `mcfg` with 0 mismatches.

- [ ] **Step 5: Static gates**

Run: `./tools/compliance.sh && ./tools/linktest.sh && ./tools/linkscript-test.sh && ./tools/gate-selftest.sh`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add src/acpi/fk_mcfg.f90 tests/acpi/test_mcfg.c mk/mcfg.mk
git commit -m "feat: the MCFG table, and the eight reserved bytes that hide the base (roadmap 4.2)"
```

---

### Task 2: ECAM addressing and the walk

**Files:**
- Create: `src/drivers/bus/fk_pcie.f90`
- Create: `tests/drivers/bus/test_pcie.c`
- Create: `mk/pcie.mk`

**Interfaces:**
- Consumes: `FK_PCI_ECAM_BUS_SHIFT`, `FK_PCI_ECAM_DEV_SHIFT`, `FK_PCI_ECAM_FUNC_SHIFT`, `FK_PCI_ECAM_FUNC_BYTES`, `FK_PCI_VENDOR_INVALID`, `FK_PCI_HDR_TYPE_POS/LEN/MFD_BIT`, `FK_PCI_HDR_TYPE_BRIDGE`, `FK_PCI_XHCI_*`, `FK_PCI_NVME_*` from `fk_pcie_types_m`.
- Produces:
  - `pcie_set_window(virt, base_phys, bus_start, bus_end)` -- takes the MAPPED virtual base and the bus range it covers; nothing dereferences anything until this is called.
  - `pcie_cfg_offset(bus, dev, fn, off) -> int64` -- PURE, the address arithmetic on its own, and the half a host can check.
  - `pcie_cfg_read32(bus, dev, fn, off) -> int32`, `pcie_cfg_read16`, `pcie_cfg_read8`.
  - `pcie_scan() -> int32` -- the walk; returns the number of functions found.
  - `pcie_count() -> int32`, and per index: `pcie_bdf(i) -> int32` (bus<<8 | dev<<3 | fn), `pcie_vendor(i) -> int32`, `pcie_device(i) -> int32`, `pcie_class(i) -> int32`, `pcie_subclass(i) -> int32`, `pcie_progif(i) -> int32`, `pcie_header_type(i) -> int32`.
  - `pcie_find_class(class, subclass, progif) -> int32` -- the index of the first match or -1. This is what 5.1 and 5.3 will call to find the xHCI and the NVMe.
  - `FK_PCIE_MAX_DEV = 64`, `FK_PCIE_OK = 0`, `FK_PCIE_E_NOT_READY = 1`, `FK_PCIE_E_RANGE = 2`.

Rules the walk must follow, each earning a comment:
- Iterate buses over the window's OWN declared range, devices 0..31, functions 0..7.
- Vendor ID `0xFFFF` means nothing is there. On a nonexistent function the whole dword reads as all-ones.
- Function 0 is probed first. If its header type does NOT have `FK_PCI_HDR_TYPE_MFD_BIT` set, functions 1..7 are SKIPPED -- a single-function device may alias function 0 across all eight and would otherwise be reported eight times.
- Header type is masked with `FK_PCI_HDR_TYPE_POS`/`LEN` before comparison; the multifunction bit is not part of the type.
- The walk is exhaustive over the declared bus range and therefore covers every device a recursive bridge walk would reach, without needing to read secondary bus numbers. Say so in the header, because the roadmap text says "recursively".
- Stop recording at `FK_PCIE_MAX_DEV` but KEEP COUNTING, and expose the overflow so a truncated list can never read as a complete one.

- [ ] **Step 1: Write the failing test**

`tests/drivers/bus/test_pcie.c`. Config space is ordinary memory here: allocate `1 MiB` (one bus), poison it to `0xFF` so every unpopulated function reads as absent by construction, and write the five q35 functions into it at their real offsets. Then `pcie_set_window(buf, 0xB0000000, 0, 0)` and check:

- `pcie_cfg_offset` arithmetic on its own, before any dereference: `(1,0,0,0)` is `1<<20`; `(0,31,3,0)` is `(31<<15) | (3<<12)`; `(0,0,0,0x10)` is `0x10`.
- `pcie_scan()` finds exactly 5.
- Each of the five BDFs is present with the right vendor and device: `0000:8086:29c0`, `0008:1234:1111`, `00f8:8086:2918`, `00fa:8086:2922`, `00fb:8086:2930`.
- Function `00:1f.1` is NOT reported -- the gap inside a multifunction device.
- A single-function device that aliases itself across all eight functions is reported ONCE. Build one at `00:02.0` with the multifunction bit CLEAR and the same bytes at functions 1..7, and assert `pcie_count()` did not grow by eight.
- `pcie_find_class` returns -1 for xHCI and for NVMe on this tree, and the index of the SATA controller for `(0x01, 0x06, 0x01)`.
- Overflow: fill the arena with more than `FK_PCIE_MAX_DEV` functions and assert the recorded count clamps while the returned total does not.

`mk/pcie.mk`:

```make
TESTS                 += pcie
# ORDER IS SEMANTIC: fk_pcie USEs fk_pcie_types_m for the ECAM shifts and the
# class triples, so that .mod has to exist first.
FSRC_pcie             := src/drivers/bus/fk_pcie_types.f90 src/drivers/bus/fk_pcie.f90
DRV_pcie              := tests/drivers/bus/test_pcie.c

# No ORACLE_pcie: Linux's probe.c walks a live bus through an ioremap and a
# pci_host_bridge, so it is a second opinion on the layout and not a function
# that can be linked and diffed.  The reference model is the config space this
# project's own firmware presents, written into a poisoned arena.
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./tools/run.sh test`
Expected: FAIL -- no `src/drivers/bus/fk_pcie.f90`.

- [ ] **Step 3: Write the module**

`src/drivers/bus/fk_pcie.f90`. Config reads go through an `integer(c_int32_t), pointer` obtained with `c_f_pointer`, declared `volatile` -- the compiler must not cache a device register or hoist a read out of the walk. Byte and word reads are a dword read plus `ibits`, never a narrower pointer: ECAM permits byte and word access but a dword read is the one form every device answers identically, and it is what `fk_pcie_types_m`'s header already says the driver path does.

- [ ] **Step 4: Run the tests**

Run: `./tools/run.sh test`
Expected: PASS, `pcie` with 0 mismatches.

- [ ] **Step 5: Static gates**

Run: `./tools/compliance.sh && ./tools/linktest.sh && ./tools/linkscript-test.sh && ./tools/gate-selftest.sh`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add src/drivers/bus/fk_pcie.f90 tests/drivers/bus/test_pcie.c mk/pcie.mk
git commit -m "feat: ECAM addressing and the walk over it (roadmap 4.2)"
```

---

### Task 3: Move the boot gate to q35

**Files:**
- Modify: `tools/qemu-boot-test.sh`

This is its own commit and its own step BEFORE any kernel change, so that a regression is attributable to the machine or to the code but never to both at once.

- [ ] **Step 1: Add the knob and flip the default**

Add `FK_MACHINE` (default `q35`) and pass `-machine "$FK_MACHINE"` on the BIOS path. The UEFI path already hardcodes `-machine q35`; make it use the same variable so there is one definition. Document in the header comment that `FK_MACHINE=pc` reaches the no-MCFG path deliberately.

- [ ] **Step 2: Prove the WHOLE suite on q35, not a sample**

Run: `./tools/run.sh bootgate && ./tools/run.sh iso && ./tools/qemu-boot-test.sh`
Expected: PASS -- and specifically the `hwstate`, `fb`, `sched` and `ticks` blocks, none of which have ever run on q35. If any of them fails, that failure is the milestone's first finding and gets fixed here, in this commit, before a line of PCIe code exists.

Then: `./tools/qemu-boot-test.sh --selftest && ./tools/qemu-boot-test.sh --smoke && ./tools/mutate-phase3.sh`
Expected: green. The mutation harness asserts kernel behaviour and has never seen q35 either.

Then the UEFI path, which is the same machine and should be unaffected: `FK_FIRMWARE=uefi ./tools/qemu-boot-test.sh`

- [ ] **Step 3: Commit**

```bash
git add tools/qemu-boot-test.sh
git commit -m "test: boot the gate on q35, because i440FX has no MCFG to find"
```

---

### Task 4: Wire it into the image and bring it up

**Files:**
- Modify: `Makefile.boot`
- Modify: `src/mm/fk_vmm.f90`
- Modify: `src/boot/fk_kmain.f90`

**Interfaces:**
- Consumes: `vmm_punch_physmap` (from `phase3/ioapic-routing`), `vmm_map_mmio`, `vmm_translate`, `FK_VMM_UC`, `acpi_find`, `acpi_table_length`, `vmm_phys_to_virt`, and everything from `fk_mcfg_m` and `fk_pcie_m`.
- Produces: `FK_VMM_ECAM = FK_VMM_MMIO + int(z'40000000', c_int64_t)` in `fk_vmm.f90`'s public parameters -- 1 GiB into the MMIO window, clear of the LAPIC at `+0x20000000` and the IOAPIC at `+0x21000000`, with room for a 256 MiB aperture. `fk_pcie_devs(0:15)` in `fk_kmain.f90`: `[magic, count, then one packed u64 per device]`.

- [ ] **Step 1: Add the three modules to `FSRC_KERNEL`**

In dependency order, and `fk_pcie_types.f90` must precede `fk_pcie.f90`:

```make
               src/acpi/fk_madt.f90 \
               src/acpi/fk_mcfg.f90 \
               src/drivers/bus/fk_pcie_types.f90 \
               src/drivers/bus/fk_pcie.f90 \
               src/cpu/fk_sched.f90 \
```

`fk_mcfg` after `fk_madt` (both need `fk_string_m`, already earlier in the chain); `fk_pcie` after `fk_pcie_types`.

- [ ] **Step 2: Add `pcie_bringup()`**

Called from `kernel_main` after `acpi_bringup(mbi)` and after `ioapic_bringup()`, before `heap_bringup()`. In this order:

1. `mcfg_phys = acpi_find(FK_SIG_MCFG)` with `FK_SIG_MCFG` built the same way `FK_SIG_APIC` is -- `ior`/`shiftl` over `iachar`, not a written-down hex literal.
2. If it is 0, print `FK_PCIE_NO_MCFG` and RETURN. This is the correct outcome on i440FX and must not be a failure.
3. `mcfg_parse(vmm_phys_to_virt(mcfg_phys), len)`; print the status and return on error.
4. Print base/segment/bus-range for allocation 0.
5. `vmm_punch_physmap(mcfg_base(0), mcfg_bytes(0))`. On `FK_VMM_E_IS_RAM`, print and return -- firmware claiming an ECAM window inside reported RAM is not something to map over.
6. `vmm_map_mmio(FK_VMM_ECAM, mcfg_base(0), mcfg_bytes(0), FK_VMM_UC)`.
7. Assert the alias is gone: `vmm_translate(FK_VMM_PHYSMAP + mcfg_base(0))` must be 0, and `vmm_translate(FK_VMM_ECAM)` must have both `FK_PTE_PWT` and `FK_PTE_PCD` set. Print both verdicts. The second is the one that says "strong UC" rather than "mapped".
8. `pcie_set_window(FK_VMM_ECAM, mcfg_base(0), mcfg_bus_start(0), mcfg_bus_end(0))`, then `pcie_scan()`.
9. Print the count, then one line per device to COM1 AND to the GOP console -- `bus:dev.fn vendor:device class/subclass/progif`. The roadmap's validation sentence names the GOP display specifically, so the console path is the deliverable and the serial copy is what the gate greps.
10. Publish `fk_pcie_devs`.

Mapping 256 MiB at 4 KiB granularity is 65536 PTEs and 128 page tables, about 512 KiB of frames from the PMM. `vmm_map_page` has no 2 MiB path and `walk` refuses to shatter an existing large page, so this is the only form available; say so in the comment rather than leaving the cost unexplained.

Verdict literals, in the file's voice:

```fortran
  character(kind=c_char, len=*), parameter :: FK_PCIE_START = &
       "Fortran Kernel: PCIe looking for the ECAM window (roadmap 4.2)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_NO_MCFG = &
       "Fortran Kernel: no MCFG table; this machine has no ECAM window." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_WINDOW = &
       "Fortran Kernel: ECAM base/segment/buses 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_ALIAS_OK = &
       "Fortran Kernel: the ECAM window has no write-back alias in the linear map." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_ALIAS_BAD = &
       "Fortran Kernel: the ECAM window is STILL mapped write-back in the linear map." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_UC_OK = &
       "Fortran Kernel: the ECAM mapping selects PWT and PCD, strong uncacheable." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_UC_BAD = &
       "Fortran Kernel: the ECAM mapping is CACHED." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_COUNT = &
       "Fortran Kernel: PCIe functions found 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_DEV = &
       "Fortran Kernel: PCIe " // c_null_char
```

- [ ] **Step 3: Update the gate's expectations**

Append to `FK_EXPECT_SERIAL`:

```
Fortran Kernel: PCIe looking for the ECAM window (roadmap 4.2).
Fortran Kernel: the ECAM window has no write-back alias in the linear map.
Fortran Kernel: the ECAM mapping selects PWT and PCD, strong uncacheable.
```

and to `FK_REJECT_SERIAL`:

```
Fortran Kernel: the ECAM window is STILL mapped write-back in the linear map.
Fortran Kernel: the ECAM mapping is CACHED.
Fortran Kernel: no MCFG table; this machine has no ECAM window.
```

The last one is rejected because the gate now runs on q35, where an MCFG exists. Under `FK_MACHINE=pc` it is the CORRECT line, so guard it: only add it to the reject list when `FK_MACHINE` is q35.

- [ ] **Step 4: Build and boot**

Run: `./tools/run.sh bootgate && ./tools/run.sh iso && ./tools/qemu-boot-test.sh`
Expected: PASS, with the device list on COM1.

Then the no-MCFG path: `FK_MACHINE=pc ./tools/qemu-boot-test.sh`
Expected: PASS -- the kernel prints `no MCFG table` and carries on. A machine without an ECAM window is not a broken kernel.

- [ ] **Step 5: Commit**

```bash
git add Makefile.boot src/mm/fk_vmm.f90 src/boot/fk_kmain.f90 tools/qemu-boot-test.sh
git commit -m "feat: map the ECAM window uncached and walk it (roadmap 4.2)"
```

---

### Task 5: Check the list against QEMU's

**Files:**
- Modify: `tools/qmp-sentinel.py`

- [ ] **Step 1: Add the `pci` subcommand**

It:
1. resolves `fk_pcie_devs` and `pmemsave`s it, asserting the magic,
2. unpacks the guest's own list into `(bdf, vendor, device, class, subclass, progif)` tuples,
3. runs HMP `info pci` and parses `Bus B, device D, function F:` plus the `PCI device VVVV:DDDD` line under it,
4. asserts the two SETS are equal -- not that one contains the other. A device QEMU reports and the kernel missed is a hole in the walk; a device the kernel reports and QEMU does not is a ghost from a bad multifunction check, and the second is the failure a containment test would let through.

Print the two sorted lists side by side on mismatch, so the diff is readable without a rerun.

- [ ] **Step 2: Extend the selftest**

`qmp-sentinel.py selftest` gains PASS-on-good and FAIL-on-each-corruption for: bad magic, a missing device, an extra device, a wrong vendor id, and a count larger than the array. `gate-selftest.sh`'s total rises and must not fall.

- [ ] **Step 3: Wire it in**

Add `FK_CHECK_PCI` (default on, 0 for `FK_FAULT_MODE` builds and for `FK_MACHINE=pc`) and call it beside the `sched` assertion.

- [ ] **Step 4: Run every gate**

Run: `./tools/compliance.sh && ./tools/linktest.sh && ./tools/linkscript-test.sh && ./tools/gate-selftest.sh && ./tools/run.sh test && ./tools/run.sh bootgate && ./tools/run.sh iso && ./tools/qemu-boot-test.sh && ./tools/qemu-boot-test.sh --selftest && ./tools/qemu-boot-test.sh --smoke && ./tools/mutate-phase3.sh && FK_MACHINE=pc ./tools/qemu-boot-test.sh && FK_FIRMWARE=uefi ./tools/qemu-boot-test.sh`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add tools/qmp-sentinel.py tools/qemu-boot-test.sh
git commit -m "test: the guest's PCI list against QEMU's, as sets (roadmap 4.2)"
```

---

### Task 6: Record it

**Files:**
- Modify: `roadmap.md`

- [ ] **Step 1: Tick 4.2 and quote the machine**

Quote the ECAM base/bus-range line, both alias verdicts, and the five device lines. Quote the host-side line that says the two sets matched. State what is NOT done: no BAR sizing or assignment, no bridge secondary-bus programming, no capability-list walk, no MSI/MSI-X enablement, and one segment group only. Note that the walk is exhaustive over the declared bus range and therefore covers what a recursive walk would, which is why there is no bridge recursion.

- [ ] **Step 2: Commit and open the PR**

```bash
git add roadmap.md
git commit -m "docs: tick 4.2, and quote the five functions the machine found"
git push -u origin phase4/pcie-ecam
gh pr create --title "roadmap 4.2: PCIe enumeration via ECAM" --body "$(cat <<'EOF'
The MCFG table, the ECAM window mapped strong-uncacheable with its
write-back alias punched out of the linear map, and a walk over it.

The gate moves to -machine q35 in its own commit, because the default
i440FX machine has no MCFG table at all -- there was nothing to find.
FK_MACHINE=pc still reaches that path deliberately, and the kernel
treats it as a fact about the machine rather than as a failure.

The proof is not the console list. qmp-sentinel reads the kernel's own
table out of guest memory and compares it as a SET against QEMU's
info pci -- so a device missed and a device invented both fail.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
