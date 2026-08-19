# Does the UART driver's test actually catch bugs?

The same question `HARNESS-VALIDATION.md` asked of Phase 1 and
`HARNESS-VALIDATION-PHASE2.md` asked of the GOP renderer, asked a third time
because roadmap 2.1 is a *third* kind of test again.

* Phase 1 compared a Fortran function against **the C function it was translated
  from**.
* The GOP renderer had no C original, so it was checked against a **reference
  model written from the specification**.
* The UART driver has no C original *and* its correctness is not a value it
  returns — it is a **sequence of side effects on hardware**. Nothing can be
  compared byte for byte after the fact, because after the fact there is nothing
  left to look at.

So `tests/drivers/serial/test_serial.c` asserts the **trace**: it supplies its own
`fk_outb`/`fk_inb`, models a 16550 well enough to be answerable, and compares the
recorded (op, port, value) sequence against the contract. Register offsets and bit
masks are diffed against the kernel's own `include/uapi/linux/serial_reg.h`,
included straight from the vendor tree — that header is this translation's oracle,
and it is why `mk/serial.mk` declares no `ORACLE_serial`.

Two things follow, and both are why this file exists:

1. A trace test can be **vacuously true**. It asserts what the driver did, using a
   mock that the same change set wrote. If the mock and the driver share a
   misconception they agree, and the suite is green.
2. `boot/io.S` **is not in the host suite at all** — the test supplies its own
   `fk_outb`/`fk_inb` in C, so the real assembly is never linked into it. Only the
   QEMU boot gate and the layout gate can see that file.

The mutations below are the evidence.

## Mutations

Each defect was injected **alone** into a known-good tree, the gate was run, and
the tree restored. A mutation that the gate accepts is an ESCAPE and is recorded as
one. Driver: `mutate.py` (see "Reproducing" below).

Three gates are involved, and which one catches a defect is itself informative:

| gate | invocation | what it can see |
|---|---|---|
| **host** | `./tools/run.sh test` → `build/run-serial` | the port trace, via the C mock. Cannot see `boot/io.S`. |
| **boot** | `./tools/run.sh iso && tools/qemu-boot-test.sh` | a real 16550A device model, real `OUT` instructions, real bytes on COM1. |
| **layout** | `./tools/run.sh linkscript` | the linked image: where symbols landed, and one white-box check on `fk_inb`. |

### Host suite — the register trace

| # | Injected defect | Gate | Caught? | How it surfaced |
|---|---|---|---|---|
| M1 | `UART_FCR_ENABLE_FIFO` `0x01` → `0x00` (FIFOs never enabled) | host | **yes** | FCR write is `0xC6`, expected `0xC7`. Roadmap 2.1 names FIFO enable explicitly; without the trace assertion nothing else would notice, since a 16550 transmits fine with FIFOs off. |
| M2 | `UART_FCR_TRIGGER_14` `0xC0` → `0x80` | host | **yes** | FCR write `0x87` ≠ `0xC7`. Diffed against `serial_reg.h:87`. |
| M3 | divisor `1` → `3` (38400 baud, not 115200) | host | **yes** | DLL write `3` ≠ `1`. On real hardware this is the classic "output is garbage on the terminal" bug; here it is an equality failure. |
| M4 | `FK_SERIAL_TX_SPINS` `65535` → `65534` | host | **yes** | dead-UART case counts 65534 LSR reads, expected 65535. Pins the bound to Linux's own `0xffff` (`arch/x86/boot/tty.c:30`). |
| M5 | `FK_SERIAL_MAX_STRING` `4096` → `4095` | host | **yes** | unterminated-string case emits 4095 bytes, expected 4096. |
| M6 | `iachar(c)` → `iand(iachar(c), 127)` (high bit stripped) | host | **yes** | high-byte case: `0x80..0xFF` arrive as `0x00..0x7F`. This is the sign-extension bug the `int32_t` carriage exists to prevent, and it is invisible to any ASCII-only test. |
| M7 | `LCR ← UART_LCR_DLAB` → `LCR ← UART_LCR_WLEN8` (DLAB never set) | host | **yes** | the divisor is written to TX/IER instead of the latch. The mock models DLAB routing precisely so this is visible; without that, the trace would look plausible and the port would run at the wrong rate. |
| M8 | LSR/THRE poll deleted from `serial_print_char` | host | **yes** | the "waits K polls" case sees 0 LSR reads before the TX write. On real hardware this drops characters under load and looks like a flaky cable. |
| M9 | loopback self-test always reports success | host | **yes** | absent-port and wrong-echo cases expect status 1, get 0. |
| M10 | `FK_MCR_LIVE` loses `UART_MCR_DTR` | host | **yes** | final MCR write `0x0E` ≠ `0x0F`. |
| M11 | loopback left ON after init (`MCR ← 0x1E`) | host | **yes** | final MCR write is `0x1E`; the wire capture is empty because every byte is swallowed by the chip. The failure a reader would otherwise debug as "the UART is dead". |
| M12 | `serial_print_char` no longer a no-op before init | host | **yes** | the pre-init case writes to port `0x0` — which on a PC is the DMA controller's address register, not nowhere. |

### Boot gate — a real device model

| # | Injected defect | Gate | Caught? | How it surfaced |
|---|---|---|---|---|
| M13 | banner text: `Initialized` → `Initialised` (one character) | boot | **yes** | `grep -F` finds nothing on COM1. The fixed-string match is load-bearing: a regex would have accepted a trailing `.` as "any character". |
| M14 | `status = serial_init(...)` call deleted | boot | **yes** | `serial_ready` stays `.false.`, so `serial_print_string` returns silently and COM1 is empty — while the **sentinel still passes**. This is the mutation that shows the two halves of the boot gate are independent rather than redundant. |
| M16 | `fk_outb` reads its port from `%si` instead of `%di` | boot | **yes** | every register write lands at a port derived from the *value* argument. Nothing reaches the UART; COM1 is silent. Note this defect lives in `boot/io.S` and is therefore invisible to the entire host suite. |

### Layout gate — the one defect no black-box test can reach

| # | Injected defect | Gate | Caught? | How it surfaced |
|---|---|---|---|---|
| M15 | `xorl %eax, %eax` deleted from `fk_inb` (no zero-extension) | layout | **yes**, but only by a white-box check | `fk_inb writes only AL` — see below. |

M15 is the interesting one and it is recorded in full because it *escaped two
gates before it was caught by a third*:

* **Host suite: structurally blind.** `test_serial.c` defines its own `fk_inb` in
  C. `boot/io.S` is not linked into `build/run-serial` at all.
* **Boot gate: measured, not assumed — it escapes.** The mutated kernel was built
  and booted. The run is *completely clean*: banner present, no self-test failure
  reported, sentinel correct. `in (%dx),%al` writes only `AL`, so the returned
  `int32_t` carries whatever the previous occupant of `EAX` left in bits 31:8 —
  and at that call site those bits **happen to be zero**, so the `0xAE` loopback
  probe still compares equal.

  "Happen to be zero" is the whole point. It is a property of today's register
  allocation, not of the code. The day it changes, `serial_init` reports broken
  hardware on a UART that is working perfectly — the worst kind of self-test.
* **Layout gate: catches it.** `tools/linkscript-test.sh` disassembles `fk_inb` and
  requires that some instruction other than the `IN` writes `%eax`.

That check is **white-box and is labelled as such in the script**: it asserts a
spelling, not a semantics. `movzbl %al,%eax` after the `IN` would satisfy it and be
correct; an instruction that wrote `EAX` and then clobbered it would satisfy it and
not be. At 2.1 it was a tripwire on a property no behavioural test in this tree could
reach, and it was worth having for exactly that reason — but it should not be read as
proof. SUPERSEDED AT 3.2b: `pic_imr` ors two full-width `fk_inb` results and the kernel
prints all eight nibbles of the answer, which the boot gate matches as the fixed string
`0x0000FFFE`. The property is behavioural now, on a line the gate already asserts.

**Result: 16 mutations, 16 caught, 0 escapes** — with the honest qualification that
M15 is caught by an instruction-pattern check rather than by observing wrong
behaviour, because no gate here *can* observe it.

## What these tests still cannot catch

Recorded rather than quietly omitted, in the manner of
`HARNESS-VALIDATION-PHASE2.md`'s mutation 12.

1. **That a real 16550 accepts this sequence.** Everything above ran against
   QEMU's device model. It is a faithful model, and it is a model. No instruction
   in `boot/io.S` has executed on physical silicon.
2. **Timing.** The bounded spin is asserted as a *count* (65535 LSR reads), never
   as a duration. Whether 65535 port accesses actually exceed one character time
   at 115200 baud on real hardware is an argument in a comment, not a measurement.
3. **That the mock is a correct 16550.** It models DLAB routing, FIFO clears,
   loopback and the floating-bus `0xFF` case because those are the behaviours the
   driver depends on. A register the driver never touches is not modelled, so a
   defect that depends on one cannot be seen. The `serial_reg.h` oracle bounds
   this: the *constants* are the kernel's own, whatever the mock does with them.
4. **Receive.** `fk_inb` is exercised only for line-status polling and the loopback
   probe. There is no receive path in roadmap 2.1, so nothing tests one.
5. **Concurrency.** The driver has no locking and the boot path was single-threaded
   by construction when this was written (`-smp 6` is configured, but only one CPU is
   started). Two CPUs printing at once would interleave mid-character. That is roadmap
   3.3's problem and nothing here would notice it today.

   SUPERSEDED BY 3.7: the interleave no longer needs a second CPU. One CPU now runs
   three preemptible tasks, and the spawned threads write to the CONSOLE rather than
   COM1 for exactly that reason -- `console_write` runs with IF clear and the serial
   driver has no such bracket. Still unlocked, and still nothing here would notice.

## Reproducing

The mutation driver is not checked in — it is a scratch harness, and a checked-in
one would need its own gate. It is ~90 lines of Python: for each `(file, exact
old string, new string, gate)` it backs the file up, applies the replacement,
**asserts the replacement actually applied** (a pattern that matches nothing
otherwise looks exactly like a caught mutation while testing the pristine tree —
this bit twice during the run above), invokes the gate, expects a non-zero exit,
and restores.

The check that the mutation applied is not optional. Two of the sixteen were
initially recorded as escapes and were not: one pattern matched a *comment*
containing the banner text rather than the declaration, so the kernel under test
was never modified.

**Bump the mtime after restoring, or the tree is left holding a mutated kernel.**
The obvious restore — copy the file aside, write the mutant, move the copy back —
puts the *backup's* timestamp on the restored file. That timestamp predates the
objects just built from the mutated source, so `make` considers `build/boot`
up to date and does not rebuild. Every later run then boots the last mutant.

This is not hypothetical: it happened during the run above and presented as the
boot gate suddenly failing with `COM1 never carried the banner` on unmodified
sources. `objdump -d --disassemble=fk_outb build/boot/kernel.elf` showed
`mov %si,%dx` while `boot/io.S` on disk plainly said `%di` — the last mutation,
still in the binary. The fix is one `os.utime(path, None)` after the restore;
`./tools/run.sh clean-boot` before trusting any subsequent boot gate is the
belt-and-braces version. Worth knowing generally: **a green `make` says the
objects are newer than the sources, not that they were built from them.**

```
host   : podman run --rm -v "$PWD:/work:Z" -w /work fortran-kernel-dev:f44 \
             bash -c 'rm -rf build && make -s test'
boot   : ./tools/run.sh iso && tools/qemu-boot-test.sh
layout : ./tools/run.sh linkscript
```
