# Project Fortran-Kernel — Phase 1 Implementation Plan (`lib/` pure functions)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Translate the self-contained, purely computational functions in the Linux
kernel's `lib/` tree into modern Fortran modules that are bit-for-bit identical to the
original C and linkable into kernel space.

**Architecture:** Each translated function becomes a Fortran `module` exporting one
`bind(c)` procedure. Correctness is not asserted by hand-written expected values — it is
established *differentially*: the kernel's own `.c` file is compiled unmodified (against
minimal header shims) as an oracle, and a C driver calls both implementations over edge
cases and >100k randomized inputs, requiring bit-identical results. A second gate checks
`nm -u` on each Fortran object to prove it has no `libgfortran` runtime dependency, which
is what makes the object kernel-linkable rather than merely correct.

**Tech Stack:** GNU Fortran 16.1.1 (`-std` free-form, F2008 bit intrinsics), GCC 16.1.1,
GNU Make, rootless Podman (Fedora 44 image), linux-7.1.8 source tarball from cdn.kernel.org.

## Scope

Phase 1 covers `lib/` pure functions **only**. Memory management, the scheduler, VFS and
the network stack are explicitly out of scope and belong to later, separate plans — each
of those is its own multi-week subsystem and would violate the "one plan produces working,
testable software" rule if folded in here.

**What Phase 1 does not and cannot deliver:** a bootable all-Fortran kernel. Fortran has no
inline assembly, no way to express the linker-script and section-attribute machinery the
kernel entry path depends on, and no equivalent of the `asm goto` / per-CPU / memory-barrier
primitives used throughout the core. The realistic and honest ceiling for this project is a
growing set of *leaf* routines — pure computation with a C ABI — that a real kernel build
could link against in place of their C originals. That is what this plan builds, and every
translated function is proven against the real thing rather than assumed.

## Global Constraints

Every task's requirements implicitly include this section.

- **Fortran standard:** modern free-form only (`.f90`), Fortran 90/2003/2008/2018.
- **`implicit none` in every single program unit** — every `module`, `program`,
  `subroutine`, and `function`. No exceptions.
- **Banned outright:** `GOTO`, `COMMON` blocks, `EQUIVALENCE`, fixed-form/72-column layout.
- **C interoperability:** `ISO_C_BINDING` everywhere. Every exported procedure is
  `bind(c, name="fk_<symbol>")`.
- **No `libgfortran` dependency.** No `print`/`write`, no `allocate`, no I/O, no string
  intrinsics inside translated modules. `nm -u <obj>.o` must print nothing.
- **Unsigned arithmetic rule.** Fortran has no unsigned integers. Carry the bit pattern in
  a signed integer of matching width (`u8`→`c_int8_t` … `u64`→`c_int64_t`) and use only
  operations that are bit-identical to the unsigned C ones:
  `>>`→`SHIFTR` (never `SHIFTA`), `<<`→`SHIFTL`, `& | ^ ~`→`IAND/IOR/IEOR/NOT`,
  unsigned comparison→`BLT/BLE/BGT/BGE` (never `<`/`>`). A signed divide or `MOD` on a
  value that can exceed the signed maximum is a defect.
- **Array lower bounds.** A C table indexed `0..N-1` must be declared `(0:N-1)` in Fortran.
  Fortran defaults to 1-based; this is the second most common failure mode after signedness.
- **Compiler flags:** `-fwrapv` (makes the two's-complement wrap defined rather than UB),
  `-fno-underscoring`, `-O2`. Note `-ffreestanding` is a C-only flag and is rejected by
  `f951` — do not add it to `FFLAGS`.
- **Isolation (safety protocol).** All compilation and testing runs inside the rootless
  Podman container via `./tools/run.sh`. Never `make install`, never write `/boot`, never
  modify grub/systemd, never touch the host's running kernel. No pull request, patch, or
  commit is ever sent to `torvalds/linux`.

## File Structure

| Path | Responsibility |
|---|---|
| `tools/Containerfile` | Fedora 44 + gcc + gfortran + binutils. The only build environment. |
| `tools/run.sh` | Wraps every `make` call in `podman run`. The isolation boundary. |
| `Makefile` | Generic pattern rules. Never edited when adding a function. |
| `mk/<name>.mk` | Per-function build fragment (4 variables). Keeps parallel work conflict-free. |
| `src/lib/<subdir>/fk_<name>.f90` | One Fortran module per function, mirroring the kernel's layout. |
| `tests/lib/<subdir>/test_<name>.c` | Differential driver for that function. |
| `tests/harness/fk_test.h` | Shared `FK_EQ` assert macro + splitmix64 PRNG. Shared, do not edit per-function. |
| `tests/shims/linux/*.h` | Shared minimal kernel headers (`types.h`, `export.h`, `math.h`). |
| `tests/shims/<name>/linux/*.h` | Per-function private shims. Prevents header collisions between concurrent agents. |
| `vendor/linux-7.1.8/` | Read-only reference source. Git-ignored (1.7 GB). |

The `mk/` fragment indirection is the load-bearing decision: it means N functions can be
translated concurrently by N independent workers with zero shared-file contention.

---

### Task 1: Provision the isolated toolchain

**Files:**
- Create: `tools/Containerfile`
- Create: `tools/run.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: image `fortran-kernel-dev:f44`; `./tools/run.sh <target>` runs `make <target>`
  inside it with the repo bind-mounted at `/work`.

- [ ] **Step 1: Write the Containerfile**

```dockerfile
FROM fedora:44
RUN dnf -y install --setopt=install_weak_deps=False \
        gcc gcc-gfortran make binutils diffutils findutils \
    && dnf clean all
WORKDIR /work
```

- [ ] **Step 2: Build the image**

Run: `podman build -t fortran-kernel-dev:f44 -f tools/Containerfile .`
Expected: `Successfully tagged localhost/fortran-kernel-dev:f44`

Rootless Podman is required. Docker on Fedora needs group membership this project does not
assume; do not request sudo for it.

- [ ] **Step 3: Write the runner**

```bash
#!/usr/bin/env bash
# Every compile/test runs inside the rootless podman container.
# The host toolchain and host kernel are never touched.
set -euo pipefail
cd "$(dirname "$0")/.."
exec podman run --rm -v "$PWD:/work:Z" -w /work fortran-kernel-dev:f44 \
     make "$@"
```

Then: `chmod +x tools/run.sh`

- [ ] **Step 4: Verify gfortran emits a clean C-ABI symbol**

Run:
```bash
podman run --rm fortran-kernel-dev:f44 bash -c '
cat > /tmp/t.f90 <<EOF
module m_smoke
  use iso_c_binding, only: c_int32_t
  implicit none
contains
  integer(c_int32_t) function fk_smoke(a) bind(c, name="fk_smoke")
    integer(c_int32_t), intent(in), value :: a
    fk_smoke = ieor(a, 1_c_int32_t)
  end function
end module
EOF
gfortran -c -O2 -fno-underscoring -o /tmp/t.o /tmp/t.f90 && nm -u /tmp/t.o && nm -g --defined-only /tmp/t.o'
```
Expected: no undefined symbols; exactly `T fk_smoke` defined.

- [ ] **Step 5: Fetch the kernel source**

Run:
```bash
mkdir -p vendor && cd vendor
curl -O https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.1.8.tar.xz
tar -xJf linux-7.1.8.tar.xz
```
Expected: `vendor/linux-7.1.8/Makefile` reports `VERSION = 7 / PATCHLEVEL = 1 / SUBLEVEL = 8`.

- [ ] **Step 6: Commit**

```bash
git add tools/ .gitignore && git commit -m "build: rootless podman fortran toolchain"
```

---

### Task 2: Build the differential harness and shared shims

**Files:**
- Create: `tests/shims/linux/types.h`, `tests/shims/linux/export.h`, `tests/shims/linux/math.h`
- Create: `tests/harness/fk_test.h`
- Create: `Makefile`

**Interfaces:**
- Consumes: the container from Task 1.
- Produces: `FK_EQ(what, c_val, f_val, fmt)`, `fk_srand(u64)`, `fk_rand() -> u64`,
  `fk_report(name) -> int`; and make targets `test`, `symcheck`, `list`, `clean`.
  A function is registered by dropping `mk/<name>.mk` defining `TESTS +=`,
  `ORACLE_<name>`, `FSRC_<name>`, `DRV_<name>`, and optionally `CFLAGS_<name>`.

- [ ] **Step 1: Write the type shims**

The oracle must be the kernel's *real* `.c` file. Shims supply only types and no-op macros
so it compiles standalone — a shim must never reimplement the algorithm, or the test
degenerates into comparing Fortran against a fake.

```c
/* tests/shims/linux/types.h */
#ifndef _FK_SHIM_TYPES_H
#define _FK_SHIM_TYPES_H
#include <stdint.h>
#include <stddef.h>
typedef uint8_t  u8;   typedef int8_t  s8;
typedef uint16_t u16;  typedef int16_t s16;
typedef uint32_t u32;  typedef int32_t s32;
typedef uint64_t u64;  typedef int64_t s64;
typedef u8  __u8;  typedef u16 __u16; typedef u32 __u32; typedef u64 __u64;
typedef _Bool bool;
#define true 1
#define false 0
#endif
```

```c
/* tests/shims/linux/export.h */
#ifndef _FK_SHIM_EXPORT_H
#define _FK_SHIM_EXPORT_H
#define EXPORT_SYMBOL(x)
#define EXPORT_SYMBOL_GPL(x)
#endif
```

```c
/* tests/shims/linux/math.h */
#ifndef _FK_SHIM_MATH_H
#define _FK_SHIM_MATH_H
#include <linux/types.h>
#endif
```

- [ ] **Step 2: Write the harness header**

`splitmix64` is used rather than `rand()` so runs are reproducible and the generator mixes
high bits well — a weak PRNG that rarely sets bit 63 would hide exactly the signedness bugs
this harness exists to catch.

```c
/* tests/harness/fk_test.h */
#ifndef _FK_TEST_H
#define _FK_TEST_H
#include <stdio.h>
#include <stdint.h>

static unsigned long fk_checks, fk_fails;

static uint64_t fk_rng_state;
static inline void     fk_srand(uint64_t s) { fk_rng_state = s; }
static inline uint64_t fk_rand(void)
{
	uint64_t z = (fk_rng_state += 0x9E3779B97F4A7C15ULL);
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
	return z ^ (z >> 31);
}

#define FK_EQ(what, c_val, f_val, fmt)                                       \
	do {                                                                 \
		fk_checks++;                                                 \
		if ((c_val) != (f_val)) {                                    \
			if (fk_fails < 10)                                   \
				printf("  MISMATCH %s: C=" fmt " F=" fmt "\n", \
				       (what), (c_val), (f_val));            \
			fk_fails++;                                          \
		}                                                            \
	} while (0)

static inline int fk_report(const char *name)
{
	printf("%-24s %8lu checks, %lu mismatches  [%s]\n",
	       name, fk_checks, fk_fails, fk_fails ? "FAIL" : "PASS");
	return fk_fails ? 1 : 0;
}
#endif
```

- [ ] **Step 3: Write the generic Makefile**

```make
KDIR   := vendor/linux-7.1.8
BUILD  := build
CFLAGS := -O2 -std=gnu11 -Wall -Itests/shims -Itests/harness -fno-builtin
FFLAGS := -O2 -fwrapv -fno-underscoring -Wall -Jbuild

TESTS :=
include $(sort $(wildcard mk/*.mk))

.PHONY: test symcheck clean list
test: $(addprefix $(BUILD)/run-,$(TESTS))
	@echo "=== all $(words $(TESTS)) translation(s) matched the C oracle ==="

define TEST_template
$(BUILD)/oracle-$(1).o: $(KDIR)/$(ORACLE_$(1)) | $(BUILD)
	gcc $(CFLAGS) $(CFLAGS_$(1)) -c -o $$@ $$<
$(BUILD)/fk_$(1).o: $(FSRC_$(1)) | $(BUILD)
	gfortran $(FFLAGS) -c -o $$@ $$<
$(BUILD)/drv-$(1).o: $(DRV_$(1)) | $(BUILD)
	gcc $(CFLAGS) $(CFLAGS_$(1)) -c -o $$@ $$<
$(BUILD)/run-$(1): $(BUILD)/oracle-$(1).o $(BUILD)/fk_$(1).o $(BUILD)/drv-$(1).o
	gcc -o $$@ $$^
	@./$$@
endef
$(foreach t,$(TESTS),$(eval $(call TEST_template,$(t))))

symcheck: $(addprefix $(BUILD)/fk_,$(addsuffix .o,$(TESTS)))
	@fail=0; for o in $^; do \
	  if nm -u $$o | grep -q '_gfortran_'; then \
	    echo "  FAIL $$o depends on libgfortran:"; nm -u $$o | grep '_gfortran_'; fail=1; \
	  else echo "  OK   $$o  ($$(nm -u $$o | wc -l) undefined symbols)"; fi; \
	done; exit $$fail

list:
	@echo $(TESTS)
$(BUILD):
	@mkdir -p $(BUILD)
clean:
	rm -rf $(BUILD)
```

`-fno-builtin` matters: without it GCC may replace a call to the oracle with its own
constant-folded builtin, and the differential test would silently compare Fortran against
the compiler rather than against the kernel.

- [ ] **Step 4: Verify the harness builds nothing yet without erroring**

Run: `./tools/run.sh list`
Expected: prints an empty line (no `mk/` fragments exist yet).

- [ ] **Step 5: Commit**

```bash
git add Makefile tests/ && git commit -m "test: differential harness + minimal kernel shims"
```

---

### Task 3: Reference translation — `int_pow` (the pattern every later task copies)

**Files:**
- Create: `src/lib/math/fk_int_pow.f90`
- Create: `tests/lib/math/test_int_pow.c`
- Create: `mk/int_pow.mk`
- Reference (read-only): `vendor/linux-7.1.8/lib/math/int_pow.c`

**Interfaces:**
- Consumes: `FK_EQ`/`fk_srand`/`fk_rand`/`fk_report` from Task 2.
- Produces: C-callable `u64 fk_int_pow(u64 base, unsigned int exp)`.

The C original:

```c
u64 int_pow(u64 base, unsigned int exp)
{
	u64 result = 1;

	while (exp) {
		if (exp & 1)
			result *= base;
		exp >>= 1;
		base *= base;
	}
	return result;
}
```

Two hazards hide in those six lines. `exp >>= 1` on an `unsigned int` is a *logical* shift —
translating it as `SHIFTA` makes the loop never terminate for any `exp` with bit 31 set.
And `result *= base` wraps modulo 2⁶⁴, which is only defined behaviour under `-fwrapv`.

- [ ] **Step 1: Write the failing test**

```c
/* tests/lib/math/test_int_pow.c */
#include <linux/types.h>
#include "fk_test.h"

u64 int_pow(u64 base, unsigned int exp);      /* oracle: real kernel source */
u64 fk_int_pow(u64 base, unsigned int exp);   /* Fortran bind(c) */

int main(void)
{
	static const u64 bases[] = {
		0, 1, 2, 3, 10, 0x7FFFFFFFULL, 0x80000000ULL, 0xFFFFFFFFULL,
		0x7FFFFFFFFFFFFFFFULL,          /* INT64_MAX  */
		0x8000000000000000ULL,          /* high bit only -- signed-negative */
		0xFFFFFFFFFFFFFFFFULL,          /* all ones                        */
		0xDEADBEEFCAFEBABEULL,
	};
	static const unsigned int exps[] = {
		0, 1, 2, 3, 7, 31, 32, 63, 64, 65, 127, 255,
		0x7FFFFFFFU,
		0x80000000U,     /* high bit set: an arithmetic shift loops forever */
		0xFFFFFFFFU,
	};

	for (size_t i = 0; i < sizeof(bases)/sizeof(*bases); i++)
		for (size_t j = 0; j < sizeof(exps)/sizeof(*exps); j++)
			FK_EQ("int_pow", int_pow(bases[i], exps[j]),
			      fk_int_pow(bases[i], exps[j]), "%llu");

	fk_srand(0x5EED1234ULL);
	for (int i = 0; i < 200000; i++) {
		u64 b = fk_rand();
		unsigned int e = (unsigned int)fk_rand();
		FK_EQ("int_pow", int_pow(b, e), fk_int_pow(b, e), "%llu");
	}
	return fk_report("int_pow");
}
```

```make
# mk/int_pow.mk
TESTS           += int_pow
ORACLE_int_pow  := lib/math/int_pow.c
FSRC_int_pow    := src/lib/math/fk_int_pow.f90
DRV_int_pow     := tests/lib/math/test_int_pow.c
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `./tools/run.sh build/run-int_pow`
Expected: FAIL — `src/lib/math/fk_int_pow.f90: No such file or directory`.

- [ ] **Step 3: Write the Fortran module**

```fortran
module fk_int_pow_m
  use iso_c_binding, only: c_int64_t, c_int32_t
  implicit none
  private
  public :: fk_int_pow

contains

  function fk_int_pow(base, exp) result(res) bind(c, name="fk_int_pow")
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t), intent(in), value :: exp
    integer(c_int64_t)                    :: res
    integer(c_int64_t)                    :: b
    integer(c_int32_t)                    :: e

    res = 1_c_int64_t
    b   = base
    e   = exp

    do while (e /= 0_c_int32_t)
       if (iand(e, 1_c_int32_t) /= 0_c_int32_t) res = res * b
       e = shiftr(e, 1)
       b = b * b
    end do
  end function fk_int_pow

end module fk_int_pow_m
```

Note the dummy arguments are copied into local `b`/`e` before mutation: the C original
mutates its by-value parameters, but a `value` dummy in Fortran should not be relied on as
scratch space. Note also `shiftr`, not `shifta`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `./tools/run.sh build/run-int_pow`
Expected: `int_pow                    200180 checks, 0 mismatches  [PASS]`

- [ ] **Step 5: Verify the object is kernel-linkable**

Run: `./tools/run.sh symcheck`
Expected: `OK   build/fk_int_pow.o  (0 undefined symbols)`

A non-empty `nm -u` here means the module reached for the Fortran runtime — almost always a
stray `print`, an `allocate`, or a string intrinsic — and the object could not be linked
into a kernel.

- [ ] **Step 6: Commit**

```bash
git add src/lib/math/fk_int_pow.f90 tests/lib/math/test_int_pow.c mk/int_pow.mk
git commit -m "feat: translate lib/math/int_pow.c to Fortran"
```

---

### Task 4 and beyond: one task per surveyed function

Tasks 4..N each translate a single `lib/` function and are structurally identical to
Task 3 — only the source file, the signature, and the edge-case table change. For each,
the steps are: write the driver with edge cases + ≥100k randomized inputs, run it and watch
it fail, write the Fortran module, run it until it passes, run `symcheck`, commit.

The concrete function list, with per-function hazards and feasibility ratings, is produced
by the survey pass and recorded in `docs/PHASE1-RESULTS.md`. Each entry there names the
kernel source path, the exported symbol, and the specific signedness or indexing hazard
that function presents.

Per-function requirements that recur:

- **Lookup tables** (the CRC family): declare with an explicit `(0:N-1)` bound and
  transcribe entries from the kernel's table verbatim. If the kernel *generates* its table
  at build time via `gen_crc32table.c`, that generation step must be reproduced or the
  table transcribed — flag it rather than inventing values.
- **Callback parameters** (`bsearch`, `sort`, `list_sort`): the C signature takes a
  function pointer, so the Fortran side takes `type(c_funptr), value` and converts with
  `c_f_procpointer` to an `abstract interface` matching the callback's exact C prototype.
  Rate these moderate, not easy.
- **Private shims:** anything the oracle needs beyond `types.h`/`export.h`/`math.h` goes in
  `tests/shims/<name>/linux/*.h` with `CFLAGS_<name> := -Itests/shims/<name>`, never in the
  shared `tests/shims/linux/`. This is what lets several functions be worked concurrently.

---

## Phase 2 preview (separate plan, not this one)

Data structures (`lib/list_sort.c`, red-black trees, hash tables) and a virtual UART
console driver. Phase 2 is where the harness stops being sufficient — a driver has side
effects on device registers, so the differential approach needs a mock MMIO region shared
between the C and Fortran implementations rather than a pure return-value comparison. That
design belongs in the Phase 2 plan.

QEMU is deliberately unused in Phase 1: nothing boots yet, so there is nothing for it to
run. When Phase 2 produces a linkable object worth booting, the mandated invocation is
`qemu-system-x86_64 -smp 6 -m 24G` per the project's resource allocation.
