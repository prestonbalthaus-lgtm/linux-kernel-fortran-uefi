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
