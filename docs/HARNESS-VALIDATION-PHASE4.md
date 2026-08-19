# Does the ACPI and PCIe work's test actually catch bugs?

The same question `HARNESS-VALIDATION.md` asked of Phase 1 and
`HARNESS-VALIDATION-PHASE3.md` asked of the panic handler, asked of roadmap 4.1
(ACPI, the MADT) and 4.2 (MCFG, the ECAM window, the bus walk).

Phase 4 is the first milestone where the kernel's job is to **read a description
of the machine and believe it**. That makes the failure mode different from
anything before it: a parser that gets an offset wrong does not crash, it
returns a plausible number. Every channel below exists because some *other*
channel cannot tell a plausible wrong answer from a right one.

## The channels, and what each is the only one to see

| Channel | Sees | Cannot see |
|---|---|---|
| Host oracle suites (`build/run-acpi` 554, `run-madt` 25133, `run-mcfg` 98, `run-pcie` 166 checks) | field assembly, bounds, malformed input, arithmetic overflow | anything about the real machine — every table is a fixture |
| The boot gate's serial contract | that the kernel reached each stage and what it decoded | whether the decode is *true*; the kernel is the only witness |
| `qmp-sentinel.py pci` — the guest's list against QEMU's `info pci` **as sets** | a function missed, and a function invented | anything about a machine QEMU does not model |
| `tools/mmiocheck.sh` on `fk_pcie.o` | a device register reached narrower than a dword | logic; it reads the object, not the meaning |

**The set comparison is the load-bearing idea in 4.2** and it is worth stating
why it is a set and not a count. A single-function device aliased across all
eight functions looks like eight perfectly plausible devices, and a containment
test — "everything the guest found is real" — waves it straight through.
Comparing sets makes a *missed* function and an *invented* function both fatal,
and the ECAM shift mutations below are caught by exactly one of those halves
each: M45 by MISSED, M46 by both at once.

## What the boot proves that the host suite does not

The host suites feed the parsers fixtures. Everything they establish is about
arithmetic. Booting on q35 adds four facts a fixture cannot carry:

    Fortran Kernel: ACPI root/rev/tables 0x000000007FFE2525/0x00/0x0005
    Fortran Kernel: MADT ioapics/first-addr/gsi-base 0x0001/0x00000000FEC00000/0x00000000
    Fortran Kernel: MADT overrides/IRQ0-GSI 0x0005/0x0002
    Fortran Kernel: ECAM base/segment/buses/bytes 0x00000000B0000000/0x0000/0x00/0xFF/0x0000000010000000

The IRQ0-to-GSI-2 override is the one that later became load bearing: roadmap
3.3 routes the timer on that number, and the machine still ticks with both 8259s
masked. That is the MADT being *believed*, not merely parsed.

**The machine changed at this milestone and it was not preference.** The default
i440FX board emits four ACPI tables and no MCFG, so there is no ECAM window on it
at all and nothing for 4.2 to find. The boot gate's machine is `q35`, which emits
five. `FK_MACHINE=pc` still reaches the no-MCFG path deliberately, and the kernel
treats it as a fact about the machine rather than as a failure — which is itself
asserted, by a second expected-line set that *rejects* the 4.2 lines.

## Mutations

`tools/mutate-phase45.sh` injects one defect at a time into the 4.1/4.2 code,
rebuilds from clean, boots it and restores the tree. The baseline must PASS; a
mutation that passes is an **escape**, because the gate accepted a kernel with a
known defect.

    tools/mutate-phase45.sh            every case
    tools/mutate-phase45.sh M45 M46    only those

| # | Injected defect | Detected? | How it surfaced |
|---|---|---|---|
| M40 | RSDP checksum never verified | **NO — escaped** | structural; see below |
| M41 | a MADT entry shorter than its own type/length pair admitted | **NO — escaped** | structural; see below |
| M42 | ISO entry's GSI read from offset 8 instead of 4 | **yes** | `IOAPIC pin 2 delivers vector 0 (want 32)`, and the pin is not unmasked. The timer never reaches the CPU. |
| M43 | entry-overrun guard removed from the walk | **NO — escaped** | structural; see below |
| M44 | IOAPIC GSI base read from the address field | **yes, after a fix** | escaped first. See "the hole this suite found". |
| M45 | ECAM device shift 15 → 16 | **yes** | `the guest MISSED 00:02.0, 00:1f.0, 00:1f.2, 00:1f.3`, and `00:01.0 guest says 1b36:000d, QEMU says 1234:1111` |
| M46 | ECAM function shift 12 → 11 | **yes** | `MISSED 00:1f.2, 00:1f.3` **and** `INVENTED 00:1f.4, 00:1f.6` — the aliasing case, caught by the half a containment test does not have |
| M47 | capability pointer's low two bits kept | **NO — escaped** | structural; see below |
| M48 | MSI-X table offset keeps its BIR bits | **NO — escaped** | structural; see below |
| M49 | BAR0's low flag bits not masked off | **yes** | `BAR0 is 0xFEBF0004, a decoded memory address` — and the route fails behind it |
| M50 | COMMAND never taken down before being set | **yes** | `COMMAND went 0x0107 -> 0x0107 with decode and mastering cleared` |
| M51 | COMMAND enable never actually written | **yes** | `and back to 0x0101 with memory-space decode set` |

Twelve cases: seven refused, five structural escapes. M44 is in the seven only
because this suite found the reason it was not.

## The hole this suite found, and watched fail

**M44 read the IOAPIC's GSI base out of the entry's *address* field** — offset 4
instead of offset 8 — and the gate stayed green. The reason is not that nothing
checked it. The reason is the **print width**:

    call serial_print_hex(int(madt_ioapic_gsi_base(0_c_int32_t), c_int64_t), &
                          4_c_int32_t)

The wrong value is `0xFEC00000`, whose low sixteen bits are zero. At four hex
digits a wrong answer printed byte for byte like the right one, so the expected
line matched and the gate passed. Widened to eight digits, and the mutation now
refuses:

    MISSING  : "Fortran Kernel: MADT ioapics/first-addr/gsi-base
                0x0001/0x00000000FEC00000/0x00000000"

This is the same lesson `HARNESS-VALIDATION-PHASE3.md` drew from M33 and worth
restating in its general form: **an assertion is only as wide as the value it
prints.** A field truncated to the digits that happen to agree is not an
assertion about that field at all.

## The five escapes, and why none of them is a hole

M40, M41, M43, M47 and M48 all escape for one reason, and it is structural
rather than a gap a better assertion would close: **q35's firmware tables are
well formed.** Every one of those mutations removes or loosens a guard against
*malformed* input, and there is no malformed input on this machine to trip it.

- M40 — QEMU's RSDP checksums correctly, so a kernel that never verifies the
  checksum reaches exactly the same table.
- M41, M43 — QEMU emits no zero-length and no overrunning MADT entry.
- M47 — every capability pointer q35 emits is already dword aligned. The xHCI's
  MSI-X capability is at `0x90`; masking its low two bits is the identity.
- M48 — the MSI-X table offset is `0x00003000` with BIR 0, so the three bits the
  mask removes are already zero.

**These guards are covered, and covered better than a boot could cover them, by
the host suites** — 25133 checks against the MADT alone, whose fixtures include
the malformed tables q35 will never produce. The honest statement is not "the
gate misses these"; it is **"the boot gate is the wrong channel for them, and
the right channel already has them."** The mutation table records the escape
rather than quietly dropping the case, because the day a guard is deleted the
question asked will be "what would have caught it", and the answer has to be on
paper.

There is one thing to watch. `run-madt`'s own coverage was the weak part once
before: roadmap 4.1's notes record that the entry-walk guard admitted a sum that
wraps **negative** under `-fwrapv`, and that the 25133-check suite did not catch
it. Fixture count is not fixture coverage.

## What is NOT claimed

- **Nothing here proves the kernel reads a real machine's ACPI tables.** Every
  table it has ever parsed was written by SeaBIOS, OVMF or QEMU. Real firmware
  emits vendor tables, revision-2 RSDPs with an XSDT, and MADT entry types this
  kernel skips rather than decodes.
- **There is no AML interpreter**, so there is no `_PRT`, so a PCI interrupt
  line's GSI cannot be looked up at all. MSI-X is the way round it and that is
  roadmap 5.1's business, not a gap in this one.
- **The bus walk is bus 0 only.** q35 has no bridge behind which to recurse, so
  the recursion has never run because it does not exist.
- **BAR sizing is not done.** `pcie_bar64` reads a BAR; it never writes all-ones
  to discover the window's length. The xHCI's register block is mapped at a
  hardcoded 64 KiB for that reason.
- Configuration **writes** are exercised on exactly one register of exactly one
  function — the xHCI's COMMAND — and the MSI-X control word. Nothing else in
  the tree writes configuration space.
