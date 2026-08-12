# Does the panic handler's test actually catch bugs?

The fourth time this question is asked, because roadmap 3.2 is a fourth kind of
thing to test.

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

So the test is a boot. `tools/qemu-boot-test.sh` greps COM1 for one line, and
`kernel_main` faults on purpose to produce it.

## The two gate invocations

    tools/qemu-boot-test.sh                       # roadmap 1.2 + 2.1, unchanged

    FK_EXPECT_SERIAL="EXCEPTION 0x00 ERR 0x0000000000000000 -- #DE Divide-by-Zero Error" \
    FK_REJECT_SERIAL="Fortran Kernel: the divide by zero did NOT trap." \
    tools/qemu-boot-test.sh                       # roadmap 3.1 + 3.2

The first still passes because the banner is printed before the fault and the
panic handler parks the CPU rather than letting it reset — the guest is alive
and its memory readable when the sentinel is dumped, exactly as before.

The second is the Phase 3 gate, and both halves of it are load-bearing:

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
| `RIP = 0xFFFFFFFF80101E9F` | the address of the `idivl` in `kernel_main` (`objdump -d`) |
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

## Mutations

Each defect was injected alone into a known-good tree, the tree was rebuilt from
clean (`./tools/run.sh clean-boot` first — see `HARNESS-VALIDATION-SERIAL.md` on
why a restored file can be newer than the object it was not built from), booted,
and restored. A mutation the gate accepts is an ESCAPE.

| # | Defect | Result |
|---|---|---|
| M1 | `ISR_NOERR` pushes no dummy error code | **caught** — headline reads `ERR 0xFFFFFFFF80101E1F`, a return address where a zero belongs |
| M2 | IDT gates installed with the present bit clear | **caught** — triple fault; QEMU exits under `-no-reboot` |
| M3 | `%rbx` and `%rbp` pushed in the wrong order | ESCAPE |
| M4 | `fk_isr_stub` returns the stub for vector n+1 | **caught** — `EXCEPTION 0x01 -- #DB Debug` |
| M5 | no `CLD` before calling into Fortran | ESCAPE |

M1 escaped on the first pass and is the reason the panic headline carries the
error code at all. With the vector alone in the grep, dropping the dummy push
shifts everything above `int_no` while `int_no` itself stays at offset 120, so
the wrong frame prints a perfectly correct-looking exception line. Moving the
error code up one line — where a real kernel prints it anyway — turned an escape
into a catch with no extra gate invocation.

**The two escapes are honest and are recorded rather than papered over.**

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

## Reproducing

    ./tools/run.sh audit                          # every static gate
    ./tools/run.sh clean-boot && ./tools/run.sh iso
    tools/qemu-boot-test.sh                       # 1.2 + 2.1
    FK_EXPECT_SERIAL="EXCEPTION 0x00 ERR 0x0000000000000000 -- #DE Divide-by-Zero Error" \
    FK_REJECT_SERIAL="Fortran Kernel: the divide by zero did NOT trap." \
    tools/qemu-boot-test.sh                       # 3.1 + 3.2

`tools/mutate-phase3.sh` drives the mutation table; it edits the tree in place
and restores it with `git checkout`, so run it on a clean tree.
