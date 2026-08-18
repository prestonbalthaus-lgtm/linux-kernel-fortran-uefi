# Roadmap 3.x -- The DMA Allocator's Body Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Define `pmm_alloc_contiguous(pages)`, which `f56b3ed` declared in `fk_heap_m` and left undefined, so a driver can obtain physically contiguous frames for a DMA ring.

**Architecture:** The body lives in `fk_pmm_m` beside the other bitmap allocators, not in `fk_heap_m` -- the heap only declares the boundary, the PMM owns the bitmap. It is a first-fit run scan over `fk_pmm_bitmap` that skips full words wholesale. It answers with a PHYSICAL base because that is what a bus master consumes; the CPU-side address is `vmm_phys_to_virt(phys)`, already public. Contiguity is proven twice: the host harness checks the bitmap's bookkeeping, and a new `qmp-sentinel.py dma` subcommand reads the allocated range out of guest PHYSICAL memory from outside the VM and checks a per-page tag the kernel wrote through the physmap.

**Tech Stack:** Fortran 2018 (`gfortran`, free form, `iso_c_binding`), C test driver against `tests/harness/fk_test.h`, Python 3 + QMP for the host-side assertion, podman dev container `fortran-kernel-dev:f44`.

## Global Constraints

- Branch: `phase3/dma-contiguous`, cut from `master` at `2f6fb8d`. One PR.
- EVERY build runs in the container: `./tools/run.sh <target>`. Never `make -f Makefile.boot` on the host.
- `tools/compliance.sh` rules, all six, are non-negotiable: SPDX on line 1; `implicit none` in every program unit including each contained procedure; no `goto`/`common`/`equivalence`; every public procedure `bind(c, name=...)` (public `parameter`s exempt); `use, intrinsic :: iso_c_binding`; and NO line may begin with exactly five spaces followed by non-space -- that reads as fixed form. Derived-type components indent FOUR.
- No `write`, `print`, `stop`, or any Fortran I/O in `src/`. Kernel code has no runtime.
- Comments only where the hardware or the ABI is non-obvious. No docstrings, no tutorials.
- Gates that must be green before the PR: `./tools/compliance.sh`, `./tools/linktest.sh`, `./tools/linkscript-test.sh`, `./tools/gate-selftest.sh`, `./tools/run.sh test`, `./tools/run.sh bootgate`, `./tools/run.sh iso`, `./tools/qemu-boot-test.sh`.
- Baseline counts to preserve or beat: linkscript-test 171/0, gate-selftest 27/0.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/mm/fk_pmm.f90` (modify) | Add `pmm_alloc_contiguous` and `pmm_free_contiguous` bodies + exports. |
| `tests/mm/test_pmm.c` (modify) | Reference-model checks for run allocation, refusal, and bitmap bookkeeping. |
| `src/boot/fk_kmain.f90` (modify) | `dma_bringup()`: allocate a 4-page run, tag each page through the physmap, publish `fk_dma_probe`, print verdicts. |
| `tools/qmp-sentinel.py` (modify) | `dma` subcommand: pmemsave the run at its PHYSICAL base and check every page's tag. |
| `tools/qemu-boot-test.sh` (modify) | Wire the `dma` assertion in; extend `FK_EXPECT_SERIAL`/`FK_REJECT_SERIAL` defaults. |
| `roadmap.md` (modify) | Tick 3.x, quote what the machine printed. |

---

### Task 1: The allocator body

**Files:**
- Modify: `src/mm/fk_pmm.f90`
- Test: `tests/mm/test_pmm.c`

**Interfaces:**
- Consumes: `bitmap(FK_PMM_WORDS)` (already `bind(c, name="fk_pmm_bitmap")`), `ready`, `free_count`, `FK_PMM_PAGE_SHIFT`, `FK_PMM_WORD_FULL`, `FK_PMM_MAX_PHYS`.
- Produces: `pmm_alloc_contiguous(pages) -> int64` physical base or 0; `pmm_free_contiguous(phys, pages)` returning `int32` status. Both `bind(c)` under their own names. `fk_heap_m` already declares the first with exactly this signature -- do not change that declaration.

- [ ] **Step 1: Write the failing test**

Append to `tests/mm/test_pmm.c`, and add the two prototypes beside the existing PMM ones:

```c
int64_t pmm_alloc_contiguous(int64_t pages);
int32_t pmm_free_contiguous(int64_t phys, int64_t pages);

static void test_contiguous(void)
{
	/* A run of four frames must come back page-aligned, must be marked
	 * used across its whole length, and the frame just past it must be
	 * untouched -- an allocator that sets one bit too many is the failure
	 * this checks for.  */
	int64_t base = pmm_alloc_contiguous(4);
	EQ64("contig base is non-zero", base != 0, 1);
	EQ64("contig base is page aligned", base & 0xFFF, 0);
	for (int i = 0; i < 4; i++)
		EQ32("contig page is used", pmm_page_is_free(base + i * 4096), 0);

	/* A second run must not overlap the first. */
	int64_t b2 = pmm_alloc_contiguous(4);
	EQ64("second run is non-zero", b2 != 0, 1);
	EQ64("second run does not overlap",
	     (b2 + 4 * 4096 <= base) || (b2 >= base + 4 * 4096), 1);

	/* Freeing hands every frame back. */
	EQ32("free_contiguous ok", pmm_free_contiguous(base, 4), 0);
	for (int i = 0; i < 4; i++)
		EQ32("freed page is free", pmm_page_is_free(base + i * 4096), 1);
	EQ32("free_contiguous ok 2", pmm_free_contiguous(b2, 4), 0);

	/* Degenerate and impossible asks are refusals, not faults. */
	EQ64("zero pages refused", pmm_alloc_contiguous(0), 0);
	EQ64("negative pages refused", pmm_alloc_contiguous(-1), 0);
	EQ64("absurd run refused", pmm_alloc_contiguous(1LL << 40), 0);
}
```

Call `test_contiguous()` from `main` after the existing allocator tests and before the report, so it runs against an initialised bitmap.

- [ ] **Step 2: Run it and watch it fail to link**

Run: `./tools/run.sh test`
Expected: FAIL -- `undefined reference to 'pmm_alloc_contiguous'`. That is the point of `f56b3ed`: the symbol was declared and never defined.

- [ ] **Step 3: Write the implementation**

In `src/mm/fk_pmm.f90`, add both names to the `public ::` list, then add to `contains`:

```fortran
  ! PAGES contiguous free frames, or 0.  First fit, scanning the bitmap as
  ! words: a full word cannot contribute to a run, so the scan restarts past
  ! it instead of testing its 64 bits.  A clear bit is by construction RAM --
  ! pmm_init marks the whole bitmap used and clears only AVAILABLE regions --
  ! so a contiguous run of clear bits is a contiguous run of usable frames and
  ! needs no second check against the region table.
  function pmm_alloc_contiguous(pages) result(phys) &
       bind(c, name="pmm_alloc_contiguous")
    implicit none
    integer(c_int64_t), intent(in), value :: pages
    integer(c_int64_t) :: phys
    integer(c_int64_t) :: page, run_start, run
    integer(c_int32_t) :: w, b

    phys = 0_c_int64_t
    if (.not. ready) return
    if (pages <= 0_c_int64_t) return
    if (pages > int(FK_PMM_PAGES, c_int64_t)) return

    run       = 0_c_int64_t
    run_start = 0_c_int64_t
    page      = 0_c_int64_t
    do w = 1_c_int32_t, FK_PMM_WORDS
       if (bitmap(w) == FK_PMM_WORD_FULL) then
          run  = 0_c_int64_t
          page = page + 64_c_int64_t
          cycle
       end if
       do b = 0_c_int32_t, 63_c_int32_t
          if (btest(bitmap(w), b)) then
             run = 0_c_int64_t
          else
             if (run == 0_c_int64_t) run_start = page
             run = run + 1_c_int64_t
             if (run == pages) then
                call mark_run(run_start, pages)
                phys = ishft(run_start, FK_PMM_PAGE_SHIFT)
                return
             end if
          end if
          page = page + 1_c_int64_t
       end do
    end do
  end function pmm_alloc_contiguous

  subroutine mark_run(first_page, count)
    implicit none
    integer(c_int64_t), intent(in) :: first_page, count
    integer(c_int64_t) :: p
    integer(c_int32_t) :: w, b

    do p = first_page, first_page + count - 1_c_int64_t
       w = int(ishft(p, -6), c_int32_t) + 1_c_int32_t
       b = int(iand(p, 63_c_int64_t), c_int32_t)
       bitmap(w) = ibset(bitmap(w), b)
    end do
    free_count = free_count - count
    ! The single-frame allocator's cursor is a "nothing free below here" hint.
    ! A run taken from below it does not invalidate that, but a run taken from
    ! above it would leave the hint pointing at frames this call just consumed.
    if (cursor > int(ishft(first_page, -6), c_int32_t) + 1_c_int32_t) &
         cursor = int(ishft(first_page, -6), c_int32_t) + 1_c_int32_t
  end subroutine mark_run

  ! Hands a run back one frame at a time through the checked single-frame path,
  ! so a caller that frees a range it never owned is refused by the same rules
  ! that refuse a stray pmm_free_page.
  function pmm_free_contiguous(phys, pages) result(status) &
       bind(c, name="pmm_free_contiguous")
    implicit none
    integer(c_int64_t), intent(in), value :: phys, pages
    integer(c_int32_t) :: status
    integer(c_int64_t) :: i

    status = FK_PMM_OK
    if (pages <= 0_c_int64_t) then
       status = FK_PMM_E_RANGE
       return
    end if
    do i = 0_c_int64_t, pages - 1_c_int64_t
       status = pmm_free_page(phys + ishft(i, FK_PMM_PAGE_SHIFT))
       if (status /= FK_PMM_OK) return
    end do
  end function pmm_free_contiguous
```

Check `pmm_free_page`'s real signature before writing this and match it exactly -- if it is a subroutine, drop the `status =` and set `status` from whatever it reports.

- [ ] **Step 4: Run the tests**

Run: `./tools/run.sh test`
Expected: PASS, and `test_pmm` reports a check count larger than the baseline with 0 mismatches.

- [ ] **Step 5: Run the static gates**

Run: `./tools/compliance.sh && ./tools/linktest.sh && ./tools/linkscript-test.sh && ./tools/gate-selftest.sh`
Expected: all green; linkscript-test 171/0, gate-selftest 27/0.

- [ ] **Step 6: Commit**

```bash
git add src/mm/fk_pmm.f90 tests/mm/test_pmm.c
git commit -m "feat: the DMA allocator's body, and the run scan behind it (roadmap 3.x)"
```

---

### Task 2: The runtime proof

**Files:**
- Modify: `src/boot/fk_kmain.f90`
- Modify: `tools/qmp-sentinel.py`
- Modify: `tools/qemu-boot-test.sh`

**Interfaces:**
- Consumes: `pmm_alloc_contiguous` from Task 1. Import it from `fk_pmm_m` ONLY -- `fk_kmain` already `use`s both `fk_pmm_m` and `fk_heap_m`, and `fk_heap_m` carries an `interface` declaration of the same name. Two `only:` clauses naming it is an ambiguous reference.
- Produces: `fk_dma_probe(0:3)` -- `[magic, phys base, pages, tag stride]` -- read from outside the guest.

- [ ] **Step 1: Add the kernel side**

In `src/boot/fk_kmain.f90`, beside `fk_acpi_topo`:

```fortran
  ! roadmap 3.x.  [0] magic  [1] phys base  [2] pages  [3] tag seed.
  ! The pages themselves carry the proof; this only says where to look.
  integer(c_int64_t), parameter :: FK_DMA_MAGIC = int(z'444D4143', c_int64_t)
  integer(c_int64_t), volatile, save, bind(c, name="fk_dma_probe") :: &
       fk_dma_probe(0:3)
```

and a bringup routine, called from `kernel_main` immediately after `heap_bringup()` and before `sched_bringup()`:

```fortran
  subroutine dma_bringup()
    implicit none
    integer(c_int64_t) :: phys, virt, i
    integer(c_int64_t), pointer :: w(:)
    type(c_ptr) :: cp
    integer(c_int32_t) :: ok

    fk_dma_probe = 0_c_int64_t
    call serial_print_string(FK_DMA_START)
    phys = pmm_alloc_contiguous(FK_DMA_PAGES)
    if (phys == 0_c_int64_t) then
       call serial_print_string(FK_DMA_FAILED)
       return
    end if

    ! Every frame in the run gets a word derived from its own index, written
    ! through the linear map.  A host-side read at the PHYSICAL base then sees
    ! those words in order only if the frames really are adjacent in DRAM --
    ! which is the one thing the bitmap cannot testify to.
    virt = vmm_phys_to_virt(phys)
    cp   = transfer(virt, cp)
    call c_f_pointer(cp, w, [FK_DMA_PAGES * 512_c_int64_t])
    do i = 0_c_int64_t, FK_DMA_PAGES - 1_c_int64_t
       w(i * 512_c_int64_t + 1_c_int64_t) = FK_DMA_SEED + i
    end do

    ok = 1_c_int32_t
    do i = 0_c_int64_t, FK_DMA_PAGES - 1_c_int64_t
       if (vmm_phys_of(virt + ishft(i, 12)) /= phys + ishft(i, 12)) &
            ok = 0_c_int32_t
    end do

    call serial_print_string(FK_DMA_BASE)
    call serial_print_hex(phys, 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(FK_DMA_PAGES, 4_c_int32_t)
    call serial_print_string(FK_NL)
    if (ok == 1_c_int32_t) then
       call serial_print_string(FK_DMA_WALK_OK)
    else
       call serial_print_string(FK_DMA_WALK_BAD)
    end if

    fk_dma_probe(0) = FK_DMA_MAGIC
    fk_dma_probe(1) = phys
    fk_dma_probe(2) = FK_DMA_PAGES
    fk_dma_probe(3) = FK_DMA_SEED
  end subroutine dma_bringup
```

with `FK_DMA_PAGES = 4_c_int64_t`, `FK_DMA_SEED = int(z'D0A1D0A100000000', c_int64_t)` and these literals beside the other message parameters:

```fortran
  character(kind=c_char, len=*), parameter :: FK_DMA_START = &
       "Fortran Kernel: DMA asking the PMM for a contiguous run (roadmap 3.x)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_DMA_BASE = &
       "Fortran Kernel: DMA run phys/pages 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_DMA_WALK_OK = &
       "Fortran Kernel: every frame in the run translates to the next physical page." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_DMA_WALK_BAD = &
       "Fortran Kernel: the DMA run is NOT contiguous in physical memory." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_DMA_FAILED = &
       "Fortran Kernel: pmm_alloc_contiguous refused the run." // &
       FK_CRLF // c_null_char
```

Add `vmm_phys_of` and `vmm_phys_to_virt` to the `use fk_vmm_m, only:` list if they are not already there, and `pmm_alloc_contiguous` to `use fk_pmm_m, only:`.

- [ ] **Step 2: Add the host-side assertion**

In `tools/qmp-sentinel.py`, add a `dma` subcommand alongside `hwstate`. It:
1. resolves `fk_dma_probe`'s physical address with the existing symbol machinery,
2. `pmemsave`s 32 bytes there and unpacks four little-endian u64s,
3. asserts word 0 is `0x444D4143`,
4. `pmemsave`s `pages * 4096` bytes at word 1 -- the PHYSICAL base, read with no reference to any page table -- and asserts the first u64 of page `i` equals `word3 + i` for every `i`,
5. prints one PASS/FAIL line per property in the style of `hwstate`.

Extend the existing `selftest` subcommand with the matching cases: a good buffer PASSES, and each of {bad magic, one page's tag wrong, a short dump} FAILS. `gate-selftest.sh` counts these; the count going up is expected, the count going down is not.

- [ ] **Step 3: Wire it into the boot gate**

In `tools/qemu-boot-test.sh` add `FK_CHECK_DMA` (default on, 0 to skip, and 0 for every `FK_FAULT_MODE` build the way `FK_CHECK_SCHED` is), call the new subcommand where `sched` is called, and append to the `FK_EXPECT_SERIAL` default list:

```
Fortran Kernel: DMA asking the PMM for a contiguous run (roadmap 3.x).
Fortran Kernel: every frame in the run translates to the next physical page.
```

and to `FK_REJECT_SERIAL`:

```
Fortran Kernel: the DMA run is NOT contiguous in physical memory.
Fortran Kernel: pmm_alloc_contiguous refused the run.
```

- [ ] **Step 4: Build and boot**

Run: `./tools/run.sh bootgate && ./tools/run.sh iso && ./tools/qemu-boot-test.sh`
Expected: PASS, with the two new serial lines present and the `dma` block printing the physical base it read from outside the guest.

- [ ] **Step 5: Re-run every gate**

Run: `./tools/compliance.sh && ./tools/linktest.sh && ./tools/linkscript-test.sh && ./tools/gate-selftest.sh && ./tools/run.sh test`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add src/boot/fk_kmain.f90 tools/qmp-sentinel.py tools/qemu-boot-test.sh
git commit -m "test: read the DMA run out of guest physical memory, page by page (roadmap 3.x)"
```

---

### Task 3: Record it

**Files:**
- Modify: `roadmap.md`

- [ ] **Step 1: Tick 3.x**

Mark the DMA allocator done in `roadmap.md` and quote the machine's own lines verbatim -- the phys/pages line and the translation verdict -- plus the host-side line proving the tags were read at the physical base with no page table involved. Say plainly what is NOT done: no 64 KiB-boundary guarantee, and no IOMMU.

- [ ] **Step 2: Commit and open the PR**

```bash
git add roadmap.md
git commit -m "docs: tick 3.x, and quote the run the host read back"
git push -u origin phase3/dma-contiguous
gh pr create --title "roadmap 3.x: the DMA allocator's body" --body "$(cat <<'EOF'
pmm_alloc_contiguous, declared in f56b3ed and undefined until now.

Proven twice: the host harness checks the bitmap's bookkeeping, and
qmp-sentinel reads the allocated range at its PHYSICAL base from outside
the guest and checks a per-page tag. The second is the one that proves
contiguity -- a bitmap can only testify about itself.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
