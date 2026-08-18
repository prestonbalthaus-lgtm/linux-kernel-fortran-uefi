# Roadmap 3.3 -- IOAPIC Routing and 8259 Pacification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take the timer off the legacy 8259 pair and route it through the IOAPIC the MADT found, so the preemptive scheduler goes on ticking with both PICs fully masked.

**Architecture:** Three moving parts and one new primitive. The primitive is `vmm_punch_physmap(phys, bytes)`: the IOAPIC's address is only known after ACPI has been parsed, which is after the linear map is already built, so the write-back alias over `0xFEC00000` has to be REMOVED rather than reserved in advance -- `vmm_reserve_mmio` runs before `vmm_init` and is unreachable this late. The three parts are `fk_ioapic_m` (IOREGSEL/IOWIN access plus pure redirection-entry encode/decode), `pic_disable()`, and an EOI switch in `fk_idt_m` -- because once GSI 2 delivers through the IOAPIC, the acknowledgement belongs to the LAPIC and an `outb` to a masked 8259 acknowledges nothing.

**Tech Stack:** Fortran 2018 (`gfortran`, free form, `iso_c_binding`), GNU as for one interrupt stub, C test driver against `tests/harness/fk_test.h`, Python 3 + QMP, podman dev container `fortran-kernel-dev:f44`.

## Global Constraints

- Branch: `phase3/ioapic-routing`, cut from `master`. One PR. Merge this BEFORE `phase4/pcie-ecam` -- that branch consumes `vmm_punch_physmap`.
- EVERY build runs in the container: `./tools/run.sh <target>`.
- `tools/compliance.sh` rules, all six: SPDX line 1; `implicit none` per program unit; no `goto`/`common`/`equivalence`; every public procedure `bind(c, name=...)` (public `parameter`s exempt); `use, intrinsic :: iso_c_binding`; no line starting with exactly five spaces then non-space. Derived-type components indent FOUR.
- No Fortran I/O anywhere in `src/`.
- The QEMU machine stays the default (i440FX) for this branch. `info pic` already dumps the IOAPIC's full 24-entry redirection table on it -- verified.
- Gates green before the PR: `compliance.sh`, `linktest.sh`, `linkscript-test.sh`, `gate-selftest.sh`, `run.sh test`, `run.sh bootgate`, `run.sh iso`, `qemu-boot-test.sh`. Baseline 171/0 and 27/0.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/mm/fk_vmm.f90` (modify) | `vmm_punch_physmap(phys, bytes)` -- drop linear-map coverage for a late-discovered aperture. |
| `src/drivers/pic/fk_pic.f90` (modify) | `pic_disable()` -- mask every line on both chips, readback-verified. |
| `src/cpu/fk_ioapic.f90` (create) | IOREGSEL/IOWIN register access, pure redirection-entry encode/decode, routing and masking. |
| `boot/interrupts.S` (modify) | `fk_spurious_stub` -- count and IRETQ, no EOI. |
| `src/cpu/fk_idt.f90` (modify) | `idt_set_eoi_lapic(base)`, `fk_lapic_spurious`, the spurious gate at vector 255, and the EOI branch in `irq_handler`. |
| `src/boot/fk_kmain.f90` (modify) | `ioapic_bringup()` and its verdicts. |
| `tests/cpu/test_ioapic.c` (create) | Reference-model test for the encode/decode half. |
| `mk/ioapic.mk` (create) | Wire that test into `./tools/run.sh test`. |
| `tools/qmp-sentinel.py` (modify) | Assert GSI 2's redirection entry and both IMRs from the device models. |
| `tools/qemu-boot-test.sh` (modify) | New serial expectations; `--master-imr` default moves to 0xFF. |
| `roadmap.md` (modify) | Tick 3.3. |

---

### Task 1: Punch a hole in the linear map

**Files:**
- Modify: `src/mm/fk_vmm.f90`

**Interfaces:**
- Consumes: `pml4_phys`, `map_top`, `walk_leaf`, `table_at`, `idx`, `round_down`, `round_up`, `FK_VMM_SIZE_2M`, `FK_VMM_PHYSMAP`, `fk_invlpg`, and `pmm_region_*` (already imported).
- Produces: `vmm_punch_physmap(phys, bytes) -> int32` status, and `FK_VMM_E_IS_RAM = 7_c_int32_t`.

- [ ] **Step 1: Write it**

Add `vmm_punch_physmap` and `FK_VMM_E_IS_RAM` to `public ::`, then:

```fortran
  ! Remove linear-map coverage for a device aperture discovered AFTER the map
  ! was built.  vmm_reserve_mmio is the same idea for apertures known before
  ! vmm_init; an address that comes out of an ACPI table cannot use it, because
  ! reading that table needs the map this would have punched.
  !
  ! REFUSES a range that overlaps reported RAM.  Two memory types for one
  ! physical page is undefined (SDM Vol.3 11.12.4), and the resolution when
  ! firmware claims an aperture inside RAM is to believe neither, not to
  ! silently unmap memory something else is using.
  function vmm_punch_physmap(phys, bytes) result(status) &
       bind(c, name="vmm_punch_physmap")
    implicit none
    integer(c_int64_t), intent(in), value :: phys, bytes
    integer(c_int32_t) :: status
    integer(c_int64_t) :: lo, hi, p, e
    integer(c_int64_t), pointer :: t(:)
    integer(c_int64_t) :: tbl, entry
    integer(c_int32_t) :: i, sh

    status = FK_VMM_OK
    if (bytes <= 0_c_int64_t) return
    if (pml4_phys == 0_c_int64_t) then
       status = FK_VMM_E_NOT_READY
       return
    end if

    lo = round_down(phys, FK_VMM_SIZE_2M)
    hi = round_up(phys + bytes, FK_VMM_SIZE_2M)

    do i = 1_c_int32_t, pmm_region_count()
       if (pmm_region_type(i) /= FK_PMM_TYPE_AVAILABLE) cycle
       e = pmm_region_base(i) + pmm_region_len(i)
       if (lo < e .and. hi > pmm_region_base(i)) then
          status = FK_VMM_E_IS_RAM
          return
       end if
    end do

    p = lo
    do while (p < hi)
       if (p < map_top) then
          call walk_leaf(FK_VMM_PHYSMAP + p, entry, sh)
          if (entry /= 0_c_int64_t .and. sh == 21_c_int32_t) then
             call walk(FK_VMM_PHYSMAP + p, 21_c_int32_t, tbl, status)
             if (status /= FK_VMM_OK) return
             call table_at(tbl, t)
             t(idx(FK_VMM_PHYSMAP + p, 21_c_int32_t)) = 0_c_int64_t
             call fk_invlpg(FK_VMM_PHYSMAP + p)
          end if
       end if
       p = p + FK_VMM_SIZE_2M
    end do
  end function vmm_punch_physmap
```

`FK_VMM_E_IS_RAM` must not collide with an existing code -- `FK_VMM_E_NO_NX` is already 6, so use 7.

- [ ] **Step 2: Prove the codes still gate**

Run: `./tools/compliance.sh && ./tools/linktest.sh && ./tools/linkscript-test.sh && ./tools/gate-selftest.sh && ./tools/run.sh test`
Expected: all green. There is no `mk/vmm.mk` -- the VMM is boot-gate-proven, not host-harness-proven, and this plan does not invent a harness for it. The punch is proven at Task 6 by the "no write-back alias" verdict, exactly the way the framebuffer's write-combining mapping is proven today.

- [ ] **Step 3: Commit**

```bash
git add src/mm/fk_vmm.f90
git commit -m "feat: punch the linear map for an aperture discovered after it was built"
```

---

### Task 2: Mask both 8259s

**Files:**
- Modify: `src/drivers/pic/fk_pic.f90`

**Interfaces:**
- Produces: `pic_disable() -> int32`, 0 when both IMRs read back 0xFF.

- [ ] **Step 1: Write it**

Add `pic_disable` to `public ::` and:

```fortran
  ! Every line masked on both chips, and the ANSWER IS THE CHIPS' OWN: after
  ! the ICW sequence a read of the data port returns the IMR.  Masking is not
  ! the same as the chip being gone -- PCAT_COMPAT firmware leaves both 8259s
  ! wired to LINT0 as ExtINT, and a masked chip simply never asserts.
  function pic_disable() result(status) bind(c, name="pic_disable")
    implicit none
    integer(c_int32_t) :: status

    call fk_outb(PIC1_DATA, FK_MASK_ALL)
    call fk_outb(PIC2_DATA, FK_MASK_ALL)
    status = 0_c_int32_t
    if (fk_inb(PIC1_DATA) /= FK_MASK_ALL) status = 1_c_int32_t
    if (fk_inb(PIC2_DATA) /= FK_MASK_ALL) status = 1_c_int32_t
  end function pic_disable
```

- [ ] **Step 2: Gates**

Run: `./tools/compliance.sh && ./tools/run.sh test`
Expected: green.

- [ ] **Step 3: Commit**

```bash
git add src/drivers/pic/fk_pic.f90
git commit -m "feat: pic_disable, and the chips' own answer that it took"
```

---

### Task 3: The IOAPIC module

**Files:**
- Create: `src/cpu/fk_ioapic.f90`
- Create: `tests/cpu/test_ioapic.c`
- Create: `mk/ioapic.mk`

**Interfaces:**
- Produces:
  - `ioapic_set_window(virt)` -- the mapped virtual base; nothing else in the module dereferences anything until this is set.
  - `ioapic_id() -> int32`, `ioapic_version() -> int32`, `ioapic_max_redir() -> int32` (entries = max+1).
  - `ioapic_redir_lo(vector, polarity, trigger, masked) -> int32` and `ioapic_redir_hi(apic_id) -> int32` -- PURE, no hardware, and the half this plan host-tests.
  - `ioapic_route(gsi, vector, apic_id, polarity, trigger) -> int32` status.
  - `ioapic_mask(gsi) -> int32`, `ioapic_unmask(gsi) -> int32`.
  - `ioapic_read_lo(gsi) -> int32`, `ioapic_read_hi(gsi) -> int32` -- read back what the chip holds.
  - `FK_IOAPIC_POL_HIGH = 0`, `FK_IOAPIC_POL_LOW = 1`, `FK_IOAPIC_TRIG_EDGE = 0`, `FK_IOAPIC_TRIG_LEVEL = 1`, `FK_IOAPIC_OK = 0`, `FK_IOAPIC_E_NOT_READY = 1`, `FK_IOAPIC_E_GSI = 2`, `FK_IOAPIC_E_VECTOR = 3`.

Register facts, each to be spelled in a comment beside the constant, cross-checked against `vendor/linux-7.1.8/arch/x86/include/asm/io_apic.h` and the 82093AA datasheet:
- `IOREGSEL` at offset 0x00, `IOWIN` at offset 0x10. Both 32-bit, both must be accessed as dwords.
- Register 0x00 = ID (bits 27:24). Register 0x01 = VERSION (7:0) and MAX REDIRECTION ENTRY (23:16). Register 0x02 = arbitration.
- Redirection entry `n` is the register pair `0x10 + 2*n` (low) and `0x11 + 2*n` (high).
- Low dword: vector 7:0, delivery mode 10:8, dest mode 11, delivery status 12, polarity 13 (1 = active low), remote IRR 14, trigger 15 (1 = level), mask 16.
- High dword: destination 31:24 in physical mode.

- [ ] **Step 1: Write the failing test**

`tests/cpu/test_ioapic.c` -- the encode/decode half only. The IOREGSEL/IOWIN pair is INDEXED access: a passive buffer cannot emulate write-selector-then-read-window, so the register sequencing is proven in the boot gate against the real device model, not here.

```c
/* Reference-model test for the pure half of src/cpu/fk_ioapic.f90.
 *
 * IOREGSEL/IOWIN is indexed access and a flat buffer cannot model it, so what
 * is checked here is the arithmetic: the two dwords of a redirection entry,
 * built from a vector, a destination and the polarity/trigger pair the MADT's
 * interrupt source overrides describe.  The sequencing is proven in the boot
 * gate, where QEMU's own device model prints the entry back.
 */
#include <stdint.h>
#include "fk_test.h"

int32_t ioapic_redir_lo(int32_t vector, int32_t polarity, int32_t trigger,
			int32_t masked);
int32_t ioapic_redir_hi(int32_t apic_id);

#define EQ32(what, a, b) FK_EQ(what, (unsigned)(a), (unsigned)(b), "0x%X")

int main(void)
{
	/* PIT on vector 0x20, active high, edge, unmasked: nothing set above
	 * the vector field.  This is the entry roadmap 3.3 actually writes. */
	EQ32("pit entry", ioapic_redir_lo(0x20, 0, 0, 0), 0x20);
	/* Masked is bit 16 and nothing else. */
	EQ32("masked", ioapic_redir_lo(0x20, 0, 0, 1), 0x10020);
	/* Active low is bit 13, level is bit 15 -- a PCI line's pair. */
	EQ32("pci style", ioapic_redir_lo(0x30, 1, 1, 0), 0xA030);
	/* Both at once, masked. */
	EQ32("all three", ioapic_redir_lo(0xFF, 1, 1, 1), 0x1A0FF);
	/* Destination is physical APIC id in 31:24 and nothing else. */
	EQ32("dest 0", ioapic_redir_hi(0), 0x00000000);
	EQ32("dest 5", ioapic_redir_hi(5), 0x05000000);
	EQ32("dest 255", ioapic_redir_hi(255), 0xFF000000);
	/* A vector below 16 is not deliverable; the encoder refuses with 0. */
	EQ32("vector 0 refused", ioapic_redir_lo(0, 0, 0, 0), 0);
	EQ32("vector 15 refused", ioapic_redir_lo(15, 0, 0, 0), 0);
	return fk_report("ioapic");
}
```

`mk/ioapic.mk`:

```make
TESTS                 += ioapic
FSRC_ioapic           := src/cpu/fk_ioapic.f90
DRV_ioapic            := tests/cpu/test_ioapic.c

# No ORACLE_ioapic, for mk/madt.mk's reason: this is a translation of the
# 82093AA redirection-table layout, not of one C function.  Linux's
# io_apic.c reaches the same dwords through a struct with bitfields whose
# layout is the compiler's business rather than the datasheet's, so it is a
# second opinion and not an oracle.  The register SEQUENCING is not testable
# here at all -- IOREGSEL/IOWIN is indexed access and a buffer cannot model
# it -- and is proven in the boot gate instead.
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./tools/run.sh test`
Expected: FAIL -- no `src/cpu/fk_ioapic.f90`.

- [ ] **Step 3: Write the module**

`src/cpu/fk_ioapic.f90`, SPDX on line 1, `implicit none` in the module and in every contained procedure. The two encoders are `pure`. Register access reads and writes through an `integer(c_int32_t), pointer` obtained with `c_f_pointer` on the window, exactly as `src/cpu/fk_lapic.f90` does for the LAPIC -- copy that idiom rather than inventing one, including its `volatile`. Every read-modify-write of a redirection entry writes the HIGH dword first and the LOW dword second, because the low dword carries the mask bit and a half-written entry that is already unmasked can deliver to a destination that has not been set yet.

`ioapic_route` must mask the entry, write high, then write low with the mask bit clear -- and must refuse a `gsi` above `ioapic_max_redir()` and a `vector` below 16.

- [ ] **Step 4: Run the tests**

Run: `./tools/run.sh test`
Expected: PASS, `ioapic` reporting 0 mismatches.

- [ ] **Step 5: Static gates**

Run: `./tools/compliance.sh && ./tools/linktest.sh && ./tools/linkscript-test.sh && ./tools/gate-selftest.sh`
Expected: green. `linkscript-test.sh` and `gate-selftest.sh` discover sources with `find src -name 'fk_*.f90'`, so the new module is seen automatically; their counts may rise, and must not fall.

- [ ] **Step 6: Commit**

```bash
git add src/cpu/fk_ioapic.f90 tests/cpu/test_ioapic.c mk/ioapic.mk
git commit -m "feat: the IOAPIC's redirection table, and the half of it a host can check"
```

---

### Task 4: Move the acknowledgement

**Files:**
- Modify: `boot/interrupts.S`
- Modify: `src/cpu/fk_idt.f90`

**Interfaces:**
- Produces: `idt_set_eoi_lapic(base)` -- non-zero arms the LAPIC path, 0 (the default) keeps the 8259 path; `fk_lapic_spurious`, a `bind(c)` counter; `fk_spurious_stub`, the vector-255 entry point.

- [ ] **Step 1: Add the stub**

In `boot/interrupts.S`, beside the existing stub tables:

```asm
/* The LAPIC's spurious vector (SVR 7:0, 0xFF here).  It gets NO EOI -- the
 * local APIC does not set an in-service bit for a spurious interrupt, so an
 * EOI here would retire whatever IS in service and that interrupt would
 * never complete.  Counting and returning is the whole handler; incq
 * clobbers only RFLAGS, which IRETQ restores from the stack, so nothing
 * needs saving.  */
	.globl fk_spurious_stub
	.type fk_spurious_stub, @function
fk_spurious_stub:
	incq	fk_lapic_spurious(%rip)
	iretq
	.size fk_spurious_stub, . - fk_spurious_stub
```

`fk_lapic_spurious` is defined on the Fortran side, so this file only references it.

Add an accessor next to `fk_isr_stub`/`fk_irq_stub` returning its address, following their exact shape:

```asm
	.globl fk_spurious_stub_addr
	.type fk_spurious_stub_addr, @function
fk_spurious_stub_addr:
	leaq	fk_spurious_stub(%rip), %rax
	ret
	.size fk_spurious_stub_addr, . - fk_spurious_stub_addr
```

- [ ] **Step 2: Add the Fortran side**

In `src/cpu/fk_idt.f90`:

```fortran
  integer(c_int64_t), volatile, bind(c, name="fk_lapic_spurious") :: &
       fk_lapic_spurious = 0_c_int64_t
```

added to `public ::` along with `idt_set_eoi_lapic`, plus a module variable and its setter:

```fortran
  integer(c_int64_t), save :: eoi_lapic = 0_c_int64_t

  ! Which chip retires an interrupt.  0 is the 8259 pair, which is correct
  ! until the IOAPIC is routed; anything else is the LAPIC's mapped base, and
  ! it is passed in rather than named here because fk_vmm_m holds the one
  ! definition of that address and is compiled AFTER this module.
  subroutine idt_set_eoi_lapic(base) bind(c, name="idt_set_eoi_lapic")
    implicit none
    integer(c_int64_t), intent(in), value :: base
    eoi_lapic = base
  end subroutine idt_set_eoi_lapic
```

`lapic_eoi` is reached through an `interface` block, NOT `use fk_lapic_m`: `fk_idt.f90` is compiled before `fk_lapic.f90` in `FSRC_KERNEL`, and reordering the chain to satisfy a `use` would move every module after it. This is the idiom `fk_heap_m` already uses for `pmm_alloc_contiguous`.

```fortran
    subroutine lapic_eoi(base) bind(c, name="lapic_eoi")
      import :: c_int64_t
      implicit none
      integer(c_int64_t), intent(in), value :: base
    end subroutine lapic_eoi
```

In `idt_init`, after the IRQ stub loop:

```fortran
    call idt_set_gate(FK_VECTOR_SPURIOUS, fk_spurious_stub_addr())
```

with `FK_VECTOR_SPURIOUS = 255_c_int32_t` and a comment saying it must equal `SVR` bits 7:0 in `fk_lapic.f90`, which is 0xFF.

In `irq_handler`, replace the unconditional `call pic_eoi(line)` and guard the 8259 spurious check:

```fortran
    ! The 8259 spurious check is the 8259's; with both chips masked no line
    ! reaches the CPU through them at all, and pic_isr() would be reading a
    ! chip that is not delivering.  The LAPIC's own spurious interrupt is
    ! vector 255 and never arrives here.
    if (eoi_lapic == 0_c_int64_t) then
       ... existing spurious block, unchanged ...
    end if
```

and

```fortran
    if (eoi_lapic /= 0_c_int64_t) then
       call lapic_eoi(eoi_lapic)
    else
       call pic_eoi(line)
    end if
```

keeping it BEFORE the `sched_tick` call, for the reason already written there.

- [ ] **Step 3: Build and boot unchanged**

Run: `./tools/run.sh bootgate && ./tools/run.sh iso && ./tools/qemu-boot-test.sh`
Expected: PASS, byte-for-byte the same verdicts as before -- nothing has called `idt_set_eoi_lapic` yet, so the 8259 path is still the live one. That is the point of this step: the switch lands green before it is thrown.

- [ ] **Step 4: Commit**

```bash
git add boot/interrupts.S src/cpu/fk_idt.f90
git commit -m "feat: an EOI that can go to either chip, and a spurious vector that goes to neither"
```

---

### Task 5: Throw the switch

**Files:**
- Modify: `src/boot/fk_kmain.f90`

**Interfaces:**
- Consumes: `vmm_punch_physmap`, `pic_disable`, everything from `fk_ioapic_m`, `idt_set_eoi_lapic`, `madt_ioapic_addr`, `madt_ioapic_gsi_base`, `madt_gsi_for_irq`, `madt_iso_count`, `madt_iso_src`, `madt_iso_flags`, `madt_pcat_compat`, `FK_PIT_IRQ`.
- Produces: `fk_ioapic_state(0:5)` -- `[magic, ioapic phys, gsi, vector, redir lo readback, pic imr]`.

- [ ] **Step 1: Add `ioapic_bringup()`**

Called from `kernel_main` immediately after `acpi_bringup(mbi)` and BEFORE `irq_bringup()`, so the timer is routed before anything asserts that it ticks. It must, in this order:

1. Return early with a printed line if `madt_ioapic_count()` is 0.
2. `vmm_punch_physmap(madt_ioapic_addr(0), FK_PMM_PAGE_SIZE)`. A non-zero status is fatal to this routine and prints which one -- `FK_VMM_E_IS_RAM` means firmware put the IOAPIC inside reported RAM and nothing further is safe.
3. `vmm_map_mmio(FK_VMM_IOAPIC, madt_ioapic_addr(0), FK_PMM_PAGE_SIZE, FK_VMM_UC)`, with `FK_VMM_IOAPIC = FK_VMM_MMIO + int(z'21000000', c_int64_t)` added to `fk_vmm.f90`'s public parameters -- one page past the LAPIC's sub-window and derived from `FK_VMM_MMIO` rather than written out.
4. Assert no write-back alias survives: `vmm_translate(FK_VMM_PHYSMAP + madt_ioapic_addr(0))` must now be 0. Print the verdict either way. This is what proves Task 1 did anything.
5. `ioapic_set_window(FK_VMM_IOAPIC)`, then print id/version/max-redir read from the chip.
6. Resolve the timer's GSI: `gsi = madt_gsi_for_irq(FK_PIT_IRQ)`. Resolve polarity and trigger from `madt_iso_flags` for that override -- bits 1:0 are polarity (0 = conforms, 1 = active high, 3 = active low) and bits 3:2 are trigger (0 = conforms, 1 = edge, 3 = level). CONFORMS on an ISA line means active high and edge; do not hardcode past the conforms case.
7. `pic_disable()`, and print its readback verdict. Before the route, not after: a line that is live on both chips at once is a double delivery.
8. `ioapic_route(gsi, FK_PIC1_VECTOR + FK_PIT_IRQ, lapic_id(), polarity, trigger)`.
9. `idt_set_eoi_lapic(FK_VMM_LAPIC)` -- last, because from this instruction on the 8259 path is gone.
10. Read the entry BACK with `ioapic_read_lo(gsi)` and print it. Publish `fk_ioapic_state`.

The verdict lines, matching the file's existing voice:

```fortran
  character(kind=c_char, len=*), parameter :: FK_IOA_START = &
       "Fortran Kernel: IOAPIC taking the timer off the 8259s (roadmap 3.3)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_ALIAS_OK = &
       "Fortran Kernel: the IOAPIC page has no write-back alias in the linear map." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_ALIAS_BAD = &
       "Fortran Kernel: the IOAPIC page is STILL mapped write-back in the linear map." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_PIC_OFF = &
       "Fortran Kernel: both 8259s report every line masked." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_PIC_ON = &
       "Fortran Kernel: an 8259 REFUSED to mask." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_ROUTED = &
       "Fortran Kernel: IOAPIC gsi/vector/readback 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_ROUTE_BAD = &
       "Fortran Kernel: the IOAPIC did not accept the redirection entry." // &
       FK_CRLF // c_null_char
```

Also print the same summary through `console_print_*` the way `acpi_bringup` does, so it reaches the GOP display and not only COM1.

- [ ] **Step 2: Update the boot gate's expectations**

In `tools/qemu-boot-test.sh`:
- Append to `FK_EXPECT_SERIAL`: the start line, `FK_IOA_ALIAS_OK` and `FK_IOA_PIC_OFF`.
- Append to `FK_REJECT_SERIAL`: `FK_IOA_ALIAS_BAD`, `FK_IOA_PIC_ON`, `FK_IOA_ROUTE_BAD`.
- **`MASTER_IMR` moves from 0xFE to 0xFF.** This is the same commit as the kmain change, not a follow-up -- the gate asserts a byte-for-byte literal and the two must move together.
- The kernel's own `"8259 IMR now 0x0000FFFE, IRQ0 is the only line open."` line is printed by `irq_bringup` BEFORE this routine runs and stays true at the moment it is printed. Leave it. If `irq_bringup` is moved after `ioapic_bringup` for any reason, that literal changes too.

- [ ] **Step 3: Boot it**

Run: `./tools/run.sh bootgate && ./tools/run.sh iso && ./tools/qemu-boot-test.sh`
Expected: PASS. The load-bearing part is not the new lines -- it is that `ticks` and `sched` STILL PASS. `fk_tick_count` advancing twice with both 8259s masked is the only thing that proves the interrupt arrived through the IOAPIC.

- [ ] **Step 4: Commit**

```bash
git add src/boot/fk_kmain.f90 tools/qemu-boot-test.sh src/mm/fk_vmm.f90
git commit -m "feat: route IRQ0 to its GSI and mask the 8259s (roadmap 3.3)"
```

---

### Task 6: Ask the device model

**Files:**
- Modify: `tools/qmp-sentinel.py`

- [ ] **Step 1: Extend `hwstate`**

`info pic` already prints the IOAPIC's whole 24-entry redirection table above the two `pic0:`/`pic1:` lines the parser reads today -- verified on this QEMU, on both the default machine and q35. Parse it and add three assertions, taking the GSI from a new `--gsi` argument (default 2) and the vector from `--pit-vector` (default 0x20):

- `pin <gsi>` carries `vec=32`, `dest=0`, and is NOT `masked`.
- Every other pin IS `masked`.
- `pic0: ... imr=ff` and `pic1: ... imr=ff`.

This is the assertion the milestone exists for: the kernel's own console can say it wrote a redirection entry, and a chip that ignored the write says exactly the same thing. `info pic` reports what the device model holds.

- [ ] **Step 2: Extend the selftest**

Add PASS-on-good and FAIL-on-each-corruption cases to `qmp-sentinel.py selftest` for all three, mirroring how the existing 8259 cases are written. `gate-selftest.sh`'s count rises; it must not fall.

- [ ] **Step 3: Run everything**

Run: `./tools/compliance.sh && ./tools/linktest.sh && ./tools/linkscript-test.sh && ./tools/gate-selftest.sh && ./tools/run.sh test && ./tools/run.sh bootgate && ./tools/run.sh iso && ./tools/qemu-boot-test.sh`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add tools/qmp-sentinel.py
git commit -m "test: assert GSI 2's redirection entry as the device model holds it"
```

---

### Task 7: Record it

**Files:**
- Modify: `roadmap.md`

- [ ] **Step 1: Tick 3.3 and quote the machine**

Quote the routed line, the alias verdict, the masked-8259 verdict, and the `info pic` pin-2 line the host read. State what is NOT done: only IOAPIC 0 is programmed, only GSI 2 is routed, every other pin stays masked, there is no MSI/MSI-X path, and LINT0 is still ExtINT -- inert with both chips masked, and left alone deliberately.

- [ ] **Step 2: Commit and open the PR**

```bash
git add roadmap.md
git commit -m "docs: tick 3.3, and quote the pin the device model printed back"
git push -u origin phase3/ioapic-routing
gh pr create --title "roadmap 3.3: IOAPIC routing and 8259 pacification" --body "$(cat <<'EOF'
IRQ0 now reaches the CPU through the IOAPIC at the GSI the MADT named,
with both 8259s fully masked and the acknowledgement moved to the LAPIC.

The proof is not the new console lines. It is that the ticks and sched
assertions still pass with imr=ff on both chips -- fk_tick_count read
twice from outside the guest, advancing, on a machine where the legacy
path can no longer deliver anything.

Also lands vmm_punch_physmap, which phase4/pcie-ecam needs for the same
reason this did: an aperture whose address comes out of an ACPI table
cannot be reserved before the linear map that reads the table exists.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
