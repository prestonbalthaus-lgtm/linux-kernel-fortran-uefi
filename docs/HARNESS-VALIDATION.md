# Does the differential harness actually catch bugs?

A test suite that passes proves nothing until you show it can fail. Before trusting
the Phase 1 harness across many translations, three deliberate defects were injected
into the known-good `fk_int_pow.f90` — one for each failure mode the Global Constraints
warn about — to confirm each is caught.

| # | Injected defect | Detected? | How it surfaced |
|---|---|---|---|
| 1 | `shiftr` → `shifta` (arithmetic instead of logical shift) | **yes** | Infinite loop. `exp = 0x80000000` sign-extends forever and never reaches 0, so the test hangs rather than mismatching. A hang is a failure signal, but note it needs a timeout to be caught in CI. |
| 2 | `base` declared `c_int32_t` instead of `c_int64_t` | **yes** | `MISMATCH int_pow: C=2147483648 F=18446744071562067968` — the high 32 bits are lost at the C ABI boundary and sign-extended back. |
| 3 | `res` initialised to `0` instead of `1` | **yes** | `MISMATCH int_pow: C=1 F=0` on the `exp == 0` case. |

The second result is the important one: it was caught by the **hand-picked edge case
`0x80000000`**, not by the 200,000 random inputs. Randomized testing alone would have
found it too, but far less directly. This is why every driver in this project is
required to carry an explicit edge-case table covering `0`, `1`, all-ones, and the
signed/unsigned boundaries — random sweeps supplement it, they do not replace it.

**Operational consequence:** defect #1 fails by hanging, not by returning a wrong
answer. Any CI runner for this project must impose a per-test timeout, or an
infinite-loop regression will look like a stalled build rather than a failed test.

Reproduce with `sed` on the module, `./tools/run.sh build/run-int_pow`, then restore.

---

# Roadmap 1.1: does the string half's test actually catch bugs?

1.3 translated the four MEMORY intrinsics and this file's method with them: a
4 KiB arena, both sides given a byte-identical copy, three questions per call
(the arenas agree, nothing outside `[dest, dest+n)` moved, both returned
`dest`). 1.1 adds `strlen`, `strcpy`, `strcmp` and `strncmp` and needs one more
channel, because the arena is blind to the way all four of them fail.

## Two channels, and what each is the only one to see

### 1. The arena, 92,760,374 checks

`build/run-string` grew from 36,747,535 checks to 92,765,576. The added cases
are the same shape as 1.3's: length edges `0,1,2,3,7,8,9,15,16,17,31,63,64,65,1024`
at an aligned and a misaligned offset, `strcmp`/`strncmp` with the first
difference forced to index 0, `n/2`, `n-1` and nowhere, eight `count` values per
pair chosen relative to BOTH the difference and the terminator, and a 1500-case
randomized sweep. Every case still ends with a full 4096-byte arena diff, so a
single wrong byte anywhere is 4096 assertions away from being missed.

The value table is explicit rather than random and one column of it is the whole
point:

    { 0x80, 0x01 }  { 0x01, 0x80 }   <- the compare is on UNSIGNED chars
    { 0xFF, 0x7F }  { 0x7F, 0xFF }
    { 0x01, 0x02 }
    { 0x00, 0x41 }  { 0x41, 0x00 }   <- one operand is a prefix of the other

`0x80` against `0x01` is `+1`. A translation comparing the bytes as Fortran
stores them -- signed -- answers `-1`, and the randomized sweep would find that
eventually. The table finds it on case one.

The eighth `count` is `(size_t)-1` and it is there because of what it found;
see M98.

### 2. The guard page, 5,202 checks, and it is the only channel that sees a read

Everything above is about the value returned and the bytes written. All four of
these functions can be wrong by **reading too far and still returning the right
answer**, and there is no arrangement of an arena that sees it.

So there is a second buffer: two pages from `mmap`, the upper one `PROT_NONE`,
and the string planted so its terminator is the **last readable byte**. One byte
further faults. A `SIGSEGV` handler and `siglongjmp` turn the fault into an
ordinary mismatch line -- `F=-1` -- rather than a dead process, so the run still
reports its total.

The oracle is run on the same buffer first, and asserted to have returned the
right answer. That is the evidence the boundary is where this claims it is: a
page mapped somewhere harmless would make every result here green and mean
nothing.

`strncmp` with `count = 0` is run against a pointer into the **unmapped** page.
That is the strongest statement in the file. Not "it read the right number of
bytes" -- it read none.

## The oracle turned out to be glibc, for one run

The first run of the new cases came back with 5,201 mismatches whose shape made
no sense: `C=127 F=1` where 127 is `0x80 - 0x01`. `lib/string.c:285` returns
`c1 < c2 ? -1 : 1`. Nothing in the kernel tree returns 127.

`build/oracle-string.o` depended on `lib/string.c` and on nothing else.
`mk/string.mk` selects which functions come out of that file with its own
`__HAVE_ARCH_*` guards, and 1.1's entire oracle-side change is deleting four of
them -- which does not touch the source file, so make did not rebuild the
object. The four symbols were absent, the link fell through to the C library,
and every string case was diffing Fortran against glibc.

Two fixes, because one of them can rot again:

- `Makefile` now has `MKDEPS := $(MAKEFILE_LIST)` and every oracle, driver and
  Fortran object depends on it. A flag change rebuilds what it affects.
- `chk_oracle_identity()` asserts the sign convention before any case runs.
  glibc returns the difference and `lib/string.c` returns the sign, so one byte
  pair separates them and nothing else in the file would notice.

This went red, which is why it was found. A translation that happened to return
the difference would have gone **green against the wrong oracle**, and the
milestone would have shipped a `strcmp` the kernel does not have.

M95 is that failure injected on purpose, and it is caught by the identity
assertion by name: `strcmp sign convention  C=lib/string.c  F=what linked`.

## The idiom measurement, which is not the one 1.3 made

`fk_string.f90`'s header has claimed since 1.3 that gcc's loop-distribution pass
cannot recognise a `c_f_pointer` loop, so `memset` cannot be lowered into a call
to itself. That was measured for a **fill** loop. GCC separately recognises an
**exit-on-sentinel** loop as `strlen` or `rawmemchr`, and that is the shape all
four of these functions are built from. If it fires, `fk_string_abi.f90`'s
`strlen` calls itself and the kernel hangs on its first path lookup.

Measured on gfortran 16.1.1, all four functions:

| build | undefined symbols |
|---|---|
| `FFLAGS` (`-O2 -fwrapv`) | none |
| `KFLAGS` (`mk/kflags.mk`, the real kernel set) | none |
| `-O3 -ftree-loop-distribute-patterns` forced on | none |

No `strlen`, no `rawmemchr`, no `_gfortran_*`. `make symcheck` reports
`build/fk_string__fk_string.o (0 undefined symbols)` and `undefcheck-boot`
passes on an image that now defines the four C spellings.

## Mutations

`tools/mutate-hostlib.sh`, the host runner. A case is seconds rather than the
tens of minutes a boot case costs, so the whole table is one command.

| # | Injected defect | Detected? | How it surfaced |
|---|---|---|---|
| M86 | `strlen` counts the terminator | **yes** | `strlen off=1536 len=0 ret: C=0 F=1` |
| M87 | `strcpy` drops the terminator | **yes** | arena byte mismatch at `dest+len`, and the `guard strcpy` byte loop |
| M88 | `strcpy` writes one byte past the terminator | **yes** | `spill()` on the Fortran arena, and a fault on the guard page |
| M89 | `strcmp` returns `c1 - c2` instead of the sign | **yes** | `strcmp ... av=128 bv=1 ret: C=1 F=127` |
| M90 | `strcmp` compares the bytes signed | **yes** | `av=128 bv=1 ret: C=1 F=-1` -- the first case in the value table |
| M91 | `strcmp` never stops at the terminator | **yes** | caught in the **arena**, `n=0 ret: C=0 F=1` |
| M92 | `strncmp` ignores `count` | **yes** | `cnt=0 ret: C=0 F=1` |
| M93 | `strncmp` spends `count` before the terminator test | **NO -- escaped** | correctly; see below |
| M94 | `strncmp` reads a byte with `count == 0` | **yes** | caught in the **arena**, `cnt=0 ret: C=0 F=127` |
| M96 | `strncmp` never stops at the terminator | **yes** | caught in the **arena**, `cnt=2 ret: C=0 F=1` |
| M98 | `strncmp` treats `count` as signed | **yes** | `cnt=18446744073709551615 ret: C=1 F=0` -- the `(size_t)-1` column alone |
| M97 | `strlen` reads one byte past the terminator | **yes** | `guard strlen len=0 ret: C=0 F=-1` -- **guard page only** |
| M95 | `mk/string.mk` restores `__HAVE_ARCH_STRCMP`, so the oracle is glibc | **yes** | `strcmp sign convention  C=lib/string.c  F=what linked` |

## M93 escaped, and it is right to

`lib/string.c:302-317` spends the count AFTER testing for the terminator. This
milestone's first draft claimed that order was observable and said so in a
comment. It is not: both forms `return` on the spot, and neither reads `left` or
`i` again, so they produce the same value for every input. There is no test that
could separate them, and M93 passing is the measurement that says so.

The comment now states what is true -- the terminator TEST is load bearing and
the ORDER it sits in is not -- and M96 is the mutation M93 should have been.
This is 5.2's M71 again: an assertion stating a reason the evidence does not
support is worse than one stating less.

## M98 was a real bug, not a hypothetical

C's `size_t` is unsigned; Fortran's `c_size_t` is a signed `int64`. A count with
the top bit set therefore arrives NEGATIVE, and the first draft's entry test was
`if (count <= 0_c_size_t) return`. `strncmp(a, b, SIZE_MAX)` returned 0 without
comparing anything, while `lib/string.c` compared to the terminator and answered
`1`. The suite says so:

    MISMATCH strncmp a=0 b=1536 n=1 at=0 av=128 bv=1 cnt=18446744073709551615 ret: C=1 F=0

The fix is to test the bit pattern against zero -- `== 0` on entry, `/= 0` in
the loop -- which is correct across the whole unsigned domain, because the
terminator ends the loop long before a decrement from `-1` could.

The same signedness applies to 1.3's `memcmp`, `memcpy`, `memmove` and `memset`,
and there it is **not testable and not fixed**: an `n` of `SIZE_MAX` makes the
oracle read or write 16 exabytes and the process dies before it can disagree
with anything. `strncmp` is the one of the eight where the terminator gives both
sides a reason to stop, which is why this column exists here and nowhere else.

## The guard page is load bearing, and here is the measurement

Three of the read-overrun mutations -- M91, M94, M96 -- are caught by the
**arena**, not by the page. Their overruns change the answer, because past the
terminator the two operands are unrelated arena bytes.

M97 does not change the answer. It is a `strlen` that returns the exactly
correct length for every input and touches one byte past the terminator on its
way out. The control run, with the guard page's section removed and the defect
left in:

    string    89317214 checks, 0 mismatches  [PASS]

89 million assertions, and the defect walks through all of them. With the page
back:

    MISMATCH guard strlen len=0 ret: C=0 F=-1

That is the whole argument for the second channel, and it is a measurement
rather than a claim. It is also the read-side twin of PHASE2's guard-region
lesson: a comparison bounded by the region of interest cannot see what happens
outside it, and for a string function the interesting thing outside it is a
LOAD.

`peek` in M97 is a **volatile** local for a reason worth keeping. An ordinary
one is dead, gfortran deletes the load, and the mutation becomes a no-op that
would have been recorded as an escape.

## What is NOT claimed

- **The NULL guards are untestable here.** All four refuse a null pointer;
  `strlen(NULL)` in C is undefined and the oracle would fault, so no case passes
  one. The guards are defensive and unproven, stated rather than counted.
- **The descriptor extent is not a length limit and is not tested as one.**
  `SCAN_MAX` is `huge(0_c_int32_t)`; nothing here plants a string 2 GiB long. The
  contract is C's -- the object is NUL-terminated -- and an unterminated one runs
  off the end in both implementations. So the honest statement of `strncmp`'s
  domain after M98 is: the count is correct for the whole unsigned range, and it
  is EXERCISED at one value above `2^63` -- `(size_t)-1` -- against strings
  short enough for the terminator to end the loop.
- **`strcpy` with overlapping operands is not tested**, because it is undefined
  in C and the oracle is free to do anything. Every case keeps source and
  destination disjoint.
- **The guard page proves a read is inside the page, not inside the string.** A
  function that read backwards from the pointer, or that read the whole page
  before answering, would pass. What it refuses is a read past the terminator
  when the terminator is at the page's edge, which is the only overrun a caller
  can actually be hurt by.
