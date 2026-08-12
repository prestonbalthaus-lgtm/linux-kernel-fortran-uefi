# Phase 1 Bare-Metal Audit

**Audited revision:** `a352905` (branch `master`, local working tree)
**Date:** 2026-08-12
**Scope:** the 8 Fortran translations under `src/`, plus the gates that certify them.

## Provenance note

The audit order specified "commit 62490db from github/linux-fortran-kernel". That object does
not exist in this repository (`git cat-file -t 62490db` → *Not a valid object name*) and no git
remote is configured (`git remote -v` is empty), so nothing could be fetched. This audit covers
local `HEAD` = `a352905`, which is the tip of the Phase 1 work.

One scope correction: Phase 1 delivered **no string handlers**. `src/` contains `lib/bcd.c` plus
seven `lib/math/` functions. Any Phase 2 planning that assumes `lib/string.c` is already
translated is working from a wrong inventory.

---

## Verdict

**The Fortran source is clean. The gates that certify it are not.**

All three checklist areas pass on the code itself, with exactly one mechanical violation
(now fixed). Every finding of consequence is in the verification harness: three of the project's
own quality gates report PASS on inputs they are supposed to reject. The code is bare-metal-safe;
the *evidence* that it is bare-metal-safe was weaker than the commit messages claim.

**Go / no-go for linking to the bootloader:** the code is a **go**. Treating the gate output as
proof of kernel-safety was a **no-go** until A-1 and A-2 were fixed — now done, see
[Gate patches](#gate-patches--applied).

To be precise about what is and is not caught: a translation that added `print *` **would** be
caught, by `symcheck` and by `linktest.sh`'s line-18 `nm -u` emptiness check — both of which
work. What a future translation could add today and still be reported clean is SSE/x87 code (no
flag forbids it — A-3), an inline `go to`, a contained procedure with no `implicit none`, or a
`bind(c)` that exists only in a comment (all three proven in A-1).

---

## Checklist verdicts

### 1. The `libgfortran` purge — **PASS**

| Construct | Occurrences in code |
|---|---|
| `print *`, `write(`, `read(`, `open(`, `close(`, `format` | 0 |
| `allocate` / `deallocate` / `allocatable` / `pointer` | 0 |
| `save`, `stop` | 0 |

Confirmed at the object level, which is the claim that actually matters:

```
$ ./tools/run.sh symcheck
  OK   build/fk_bcd.o  (0 undefined symbols)
  ... all 8 ...
```

Zero undefined symbols — not merely "no `_gfortran_*`". Nothing dynamic is allocated; every
routine uses only scalar locals and one `parameter` lookup table per log module, which lands in
`.rodata`. There is no heap dependency to remove.

### 2. C-binding & ABI compatibility — **PASS after one fix**

Every exported procedure carries `bind(c, name="fk_...")` and every dummy argument is a scalar
with `VALUE`, matching the C-by-value convention exactly. Widths check out against the kernel
prototypes: `u8`→`c_int8_t`, `u32`→`c_int32_t`, `u64`→`c_int64_t`/`c_long`.

**Violation found and fixed (A-6):** all 8 modules used bare `use iso_c_binding` rather than
`use, intrinsic :: iso_c_binding`. Without the `intrinsic` keyword the compiler will silently
prefer a *user-defined* module of the same name if one ever appears on the include path — which
in a kernel tree with hundreds of modules is a real, if unlikely, hazard. Fixed in all 8 files.

### 3. Fortran purity & safety — **PASS**

`implicit none` is present in **every** program unit, not just once per file:

| Module | Program units | `implicit none` |
|---|---|---|
| fk_bcd | 3 | 3 |
| fk_gcd | 2 | 2 |
| fk_int_pow | 2 | 2 |
| fk_int_sqrt | 2 | 2 |
| fk_intlog2 | 2 | 2 |
| fk_intlog10 | 3 | 3 |
| fk_lcm | 4 | 4 |
| fk_lcm_not_zero | 6 | 6 |

No `GOTO`, no `COMMON`, no `EQUIVALENCE`, no fixed-form layout — 0 occurrences of each.

**On hidden array descriptors:** moot here, and the premise needs correcting. No procedure in
Phase 1 takes an array dummy argument at all — every argument is a scalar passed by value, so no
descriptor is constructed anywhere. Mechanically, a descriptor is emitted for *assumed-shape*
(`x(:)`), `allocatable`, and `pointer` dummies; *explicit-shape* (`x(n)`) and *assumed-size*
(`x(*)`) pass a bare address like C. And the failure mode is an **ABI mismatch** — the callee
reads a pointer where the caller passed a `CFI_cdesc_t` struct — which yields garbage or a fault.
It is not a distinct "panic mechanism". This becomes live in Phase 2, where string handlers will
take buffers: those dummies must be explicit-shape or assumed-size, never `x(:)`.

---

## Findings, ranked

### A-1 — `compliance.sh` passes files that violate four mandatory rules · **HIGH**

All five gates can be fooled. Proven with a counterexample module that has no `implicit none` in
its contained function, `bind(c)` only inside a comment, an inline `go to`, and a blank `COMMON`:

```
MODULE                     implicit banned   bind(c)  SPDX     free-form
fk_evil                    OK       none     OK       OK       free
=== all translations comply with the mandatory standards ===
  compliance.sh EXIT=0   <-- every gate fooled
```

Root causes, per gate:

- **`implicit none`** (`tools/compliance.sh:13`) — the threshold is
  `$(( units > 2 ? 1 : 1 ))`, which evaluates to `1` on both branches. The check therefore only
  requires *one* `implicit none` anywhere in the file, despite the comment above it saying
  "every program unit ... needs implicit none" and the Phase 1 plan making that mandatory.
- **`bind(c)`** (`:16`) — `grep -q 'bind(c'` matches comment text. It also never checks that
  *every* exported procedure is bound, only that the string appears once.
- **banned constructs** (`:15`) — the regex anchors at line start, so `if (x) go to 100` is
  missed; and `common\s*/` requires a slash, so blank `COMMON` is missed.
- Neither `use, intrinsic ::` nor the plan's unsigned-operation rules are checked at all.

The current all-OK output on the real sources is correct by luck, not by verification.

### A-2 — `linktest.sh` does not perform the freestanding link it reports · **HIGH**

`tools/linktest.sh:22` runs `ld -r`, which produces a *relocatable* object and by design does
not resolve undefined symbols. It cannot fail the way the script's comment ("freestanding link:
no libc, no crt, no libgfortran available at all") and commit `4652039` ("link -nostdlib")
claim. Demonstrated with a module that calls into libgfortran:

```
  nm -u /tmp/dirty.o ->
      U _gfortran_st_write
      U _gfortran_st_write_done
      U _gfortran_transfer_character_write
      U _gfortran_transfer_integer_write
  >>> ld -r SUCCEEDED on an object that calls libgfortran <<<

  contrast, a real freestanding link:
      ld -nostdlib FAILED as it should:
        undefined reference to `_gfortran_st_write'
```

The genuine gate is the `nm -u` empty-output check on line 18, which already precedes it and
does hold. The `ld -r` step contributes nothing; the claim attached to it should be downgraded
or the command replaced with a real `ld -nostdlib` link.

### A-3 — kernel FP/vector-prevention flags are absent from `KFLAGS` · **MEDIUM**

`tools/linktest.sh:8` builds with `-mcmodel=kernel -mno-red-zone -fno-pic -fno-stack-protector
-fno-asynchronous-unwind-tables -fno-common`, but omits the entire family the kernel uses
specifically to stop the compiler touching FP state. From the vendored tree:

```
vendor/linux-7.1.8/arch/x86/Makefile:71  # Prevent GCC from generating any FP code by mistake.
vendor/linux-7.1.8/arch/x86/Makefile:76  KBUILD_CFLAGS += -mno-sse -mno-mmx -mno-sse2 -mno-3dnow -mno-avx -mno-sse4a
vendor/linux-7.1.8/arch/x86/Makefile:152 KBUILD_CFLAGS += -mno-80387
vendor/linux-7.1.8/arch/x86/Makefile:153 KBUILD_CFLAGS += -mno-fp-ret-in-387
```

This matters because kernel code may not use SSE/x87 registers outside
`kernel_fpu_begin()`/`kernel_fpu_end()` — doing so silently corrupts user FPU state.

**Current emission is clean** — 0 FP/vector instructions across all 8 objects under the existing
flags, as expected for integer-only scalar code:

```
  fk_bcd               FP/vector insns: 0
  ... all 8: 0 ...
```

So this is a latent gap, not a live defect: nothing is wrong today, but the gate does not
*forbid* it, and Phase 2 code with loops over buffers is exactly where GCC starts vectorising.

The hardening is free: gfortran accepts every one of these flags (verified individually), and
rebuilding all 8 modules under the **complete** recommended set — the existing `KFLAGS` plus
`-fno-strict-aliasing -mno-sse -mno-mmx -mno-sse2 -mno-3dnow -mno-avx -mno-sse4a -mno-80387
-mno-fp-ret-in-387` — leaves the entire differential suite green, including the 4.3-billion-check
exhaustive `bcd` sweep. There is no cost to adopting it.

### A-4 — `-fwrapv` is a correctness dependency enforced only by this Makefile · **MEDIUM**

Every module's header comments lean on `-fwrapv` to make two's-complement wrap defined rather
than UB. That reasoning is sound, but the flag lives only in `Makefile:10` and
`tools/linktest.sh:8`. A real Kbuild integration would not add it, and nothing in the source
fails loudly without it.

Measured: rebuilding all 8 without `-fwrapv` still passes the entire differential suite under
GCC 16.1.1 at `-O2`. That means the dependency is currently **latent, not live** — it is
insurance against a future optimiser, not a bug being masked today. It should be pinned
somewhere the kernel build would honour rather than left to a test-only Makefile.

### A-5 — the tested object and the kernel-flag object are different builds · **LOW-MEDIUM**

`make test` compiles with `FFLAGS` (`-O2 -fwrapv -fno-underscoring -Wall`); `linktest.sh`
recompiles from scratch with `KFLAGS`. Correctness is therefore proven for one binary and
linkability for a different one. Nothing currently diverges — running the differential suite
under the *full* kernel flag set (including all of A-3's flags) passes all 8 — but that
equivalence is untested in CI and should be, since `-mcmodel=kernel` and the FP flags do change
codegen.

### A-6 — bare `use iso_c_binding` · **LOW — FIXED**

See checklist item 2. Fixed in all 8 modules.

---

## Non-findings worth recording

These were examined and are **correct**; they are noted so the next auditor does not re-litigate
them.

- **`fk_lcm.f90:126 u64_div`** — the 65th-bit `carry` handling is right. Invariant `r < d` gives
  `2r+bit < 2d`, so when `carry` is set the truncated `r - d` is congruent to the true
  `(2r+bit) - d` mod 2⁶⁴ *and* in range. Correct across the full u64 domain.
- **`fk_lcm_not_zero.f90:92 fk_udiv64`** — peeling off `d ≥ 2⁶³` (quotient is exactly 1) is what
  keeps the running remainder from overflowing in the main loop. Sound.
- **`fk_gcd.f90`** — mirrors the `CONFIG_CPU_NO_EFFICIENT_FFS=n` / `static_branch_likely` path,
  which is the path the oracle build actually compiles. Deliberately not translating the dead
  fallback is the right call.
- **`fk_intlog2` vs `fk_intlog10`** — the interpolation is computed in 64-bit-then-masked in one
  and in wrapping 32-bit in the other. Both reproduce the C `unsigned int` result; the product
  peaks at `0x7FFFFF * 0x171 = 0xB87FFE8F`, which has bit 31 set but does not exceed 32 bits, so
  the two forms agree.
- **Both log tables use an explicit `logtable(0:255)` lower bound**, so the C index arithmetic
  transcribes literally. This is the failure mode the plan calls second-most-common; it was
  handled.
- **`fk__bcd2bin`** masks its `c_int8_t` argument with `255` before use, so it is correct
  regardless of whether the caller sign- or zero-extends the byte into the register slot.

Style observations, deliberately **not** changed (no checklist violation, and every edited line
is retest risk): `fk_lcm.f90` uses `c_int64_t` where `fk_lcm_not_zero.f90` uses `c_long`;
`fk_intlog10.f90`'s table entries use default-kind `int(z'...')` where `fk_intlog2.f90`'s are
explicitly kinded; the 256-entry log table is duplicated across the two modules; loop counters
`sh` and `i` are default-kind `integer` rather than `c_int` (they are locals, never crossing the
ABI boundary).

---

## Differential coverage at the audited revision

| Translation | Checks | Result |
|---|---:|---|
| bcd | 4,295,267,612 | PASS — **exhaustive** over both full input domains |
| intlog2 | 741,116 | PASS |
| gcd | 451,396 | PASS |
| lcm | 401,800 | PASS |
| lcm_not_zero | 346,096 | PASS |
| intlog10 | 336,997 | PASS |
| int_sqrt | 325,277 | PASS |
| int_pow | 200,180 | PASS |

Every driver carries an explicit edge-case table alongside its random sweep, which
`docs/HARNESS-VALIDATION.md` shows empirically is what catches ABI-width defects.

---

## Independent semantic re-derivation

Because the differential harness only *samples* the u64 domains (everything except `bcd`), the
translations were additionally re-derived from scratch by 8 independent reviewers — one per
translation — each given the Fortran and the vendored C and instructed adversarially: find a
concrete input on which the two differ. Each reviewer read both sources and ran its own
arithmetic checks (3–14 independent computations apiece).

**Result: 0 candidate divergences across all 8 translations.**

Stated precisely, so this is not over-read: the intended second stage — independent skeptics
attempting to *refute* each claimed divergence — never executed, because no reviewer produced a
claim to refute. So the evidence here is "eight independent re-derivations found nothing",
which is corroboration of the differential suite, **not** an exhaustive proof over the u64
domains. `bcd` remains the only translation proven exhaustively, by its 4.3-billion-check sweep.

## Gate patches — APPLIED

> **Status:** applied on branch `audit/harden-phase1-gates`. The findings above describe the
> state at `a352905`, which is the revision this audit examined; they are kept as the
> point-in-time record. A-1 through A-5 are closed by that branch, and `make audit` now runs
> every gate in one command.
>
> The most important addition is `tools/gate-selftest.sh`. The root cause of A-1 and A-2 was not
> a bad regex — it was that **nobody had ever watched those gates fail**. The self-test feeds
> each gate a file that violates it and requires rejection, then feeds it the real sources and
> requires acceptance. It immediately earned its place: it caught a parsing bug in the very
> `bind(c)` check written to close A-1 (`tr -d '[:space:]'` deleted the newlines separating
> public names, fusing `public :: a, b` into one token, so `fk_bcd` alone was wrongly rejected).
> That bug would otherwise have shipped as a new false positive.

Each patch below is small and each closes a proven hole.

**1. `tools/linktest.sh:8` — adopt the kernel's real flag set:**

```sh
KFLAGS="-O2 -fwrapv -fno-underscoring -mcmodel=kernel -mno-red-zone -fno-pic \
        -fno-stack-protector -fno-asynchronous-unwind-tables -fno-common \
        -fno-strict-aliasing \
        -mno-sse -mno-mmx -mno-sse2 -mno-3dnow -mno-avx -mno-sse4a \
        -mno-80387 -mno-fp-ret-in-387"
```

**2. `tools/linktest.sh:22` — make the link claim true**, replacing `ld -r`.

The obvious patch does **not** work, and was caught only by testing it — the same mistake this
finding is about. `--no-undefined` is a final-link option; under `-r` it is silently ignored:

```
=== CANDIDATE A:  ld -nostdlib -r --no-undefined ===
  dirty.o  -> SUCCEEDED  *** BAD: recommendation would NOT gate ***
```

A real link with an entry symbol does gate correctly — it rejects the libgfortran-dependent
object and accepts all 8 real modules. Derive the entry symbol so the script stays generic:

```sh
  ent=$(nm --defined-only -g "/tmp/$n.ko.o" | awk '$2=="T"{print $3; exit}')
  if [ -n "$ent" ] && ld -nostdlib -e "$ent" -o /dev/null "/tmp/$n.ko.o" 2>/dev/null; then
```

Verified:

```
  dirty.o          -> FAIL (correct: it needs libgfortran)
  fk_bcd.o .. fk_lcm_not_zero.o -> PASS  (all 8)
```

Also add an objdump assertion that no `%xmm/%ymm/%mm/fld/fst` appears, so A-3 is enforced rather
than merely hoped for.

**3. `tools/compliance.sh` — strip comments before every grep**, require one `implicit none` per
program unit (drop the `? 1 : 1` no-op), require `bind(c` on each `public` procedure, drop the
`^` anchor on the banned-construct regex, catch blank `COMMON`, and add a `use, intrinsic ::`
check.

**4. `Makefile`** — pin `-fwrapv` with a comment marking it correctness-critical, and add a CI
job running the differential suite under the full `KFLAGS` so A-5 stops being an assumption.

---

## Post-fix verification

Run in the project container after the 8 `intrinsic` edits:

```
$ ./tools/run.sh test        →  all 8 translations matched the C oracle
$ ./tools/run.sh symcheck    →  8/8 OK, 0 undefined symbols
$ bash tools/linktest.sh     →  8/8 OK under kernel flags
$ bash tools/compliance.sh   →  8/8 comply
```

Phase 2 remains blocked pending review of this report.
