# Does the GOP renderer's test actually catch bugs?

Same question as `HARNESS-VALIDATION.md` asked of Phase 1, asked again because the
Phase 2 test is a *different kind* of test. Phase 1 compared a Fortran function
against the C function it was translated from. `fk_gop_renderer.f90` has no C
original — nothing in `lib/` draws pixels — so its renderer half is checked against
a **reference model written from the GOP contract** in the test driver itself.

That is a weaker guarantee than a real oracle, and it fails in a specific way: if the
model and the module share a misconception, they agree and the test passes. The
mutations below are the evidence that they do not.

Only the font half has a true oracle: all 4096 bytes are compared against
`font_vga_8x16`, compiled from the kernel's own `lib/fonts/font_8x16.c`.

## Mutations

Each defect was injected alone into a known-good module; the suite must fail.
Reproduce by `sed`-ing the module, `./tools/run.sh build/run-gop_renderer`, restoring.

| # | Injected defect | Detected? | How it surfaced |
|---|---|---|---|
| 1 | `btest(bits, 7-dx)` → `btest(bits, dx)` (glyphs read LSB-first) | **yes** | `byte 3200 (row 10, col 0) fortran=0x0C model=0x13`. Every glyph mirrored. Note this lights the *same number of pixels*, so a test that counted lit pixels or spot-checked would have passed. |
| 2 | offset uses `fb_width` instead of `fb_stride` | **yes** | `byte 256 (row 0, col 64)` — writes land in the scanline slack. Correct on row 0, shears further with every row. |
| 3 | right-edge clip removed | **yes** | `byte 256 (row 0, col 64) fortran=0x00 model=0xAA` |
| 4 | bottom-edge clip removed | **yes** | 68 mismatches, reported as `OVERRUN ... wrote N bytes PAST the framebuffer`. See "guard regions" below — this one escaped until they were added. |
| 5 | `fb(off+1)` → `fb(off+2)` (off-by-one) | **yes** | `byte 0 (row 0, col 0) fortran=0xAA model=0x06` |
| 6 | one font byte replaced | **yes** | `MISMATCH font_row: C=0x7C F=0x7D`, and independently in rendered output. A **single bit flipped out of 32768** is caught — this is what makes a 4096-byte hardcoded table trustworthy. |
| 7 | `pitch mod 4` validation removed | **yes** | `MISMATCH init pitch%4: C=-3 F=0` |
| 8 | renderer not disarmed on failed init | **yes** | `inert after failed re-init: byte 0 fortran=0xFF model=0x20` |
| 9 | pitch guard narrowed back to int32 | **yes** | the review finding below; caught by the overflow regression block |
| 10 | `vga_fill_rect` y-clamp removed | **yes** | `byte 640 (row 2, col 0) fortran=0x06 model=0x0C` |
| 11 | `vga_fill_rect` x-clamp removed | **yes** | `byte 8 (row 0, col 2) fortran=0x06 model=0x09` |
| 12 | `VOLATILE` removed from the framebuffer pointer | **NO — escaped** | see below |
| 13 | `vga_print_string` x advance narrowed back to int32 | **NO — escaped** | see below |

## What an adversarial review found that this table did not

Nineteen agents reviewed the module along four lenses (unsigned/ABI, freestanding,
render logic, font provenance); fifteen candidate findings, ten confirmed after an
adversarial refutation pass. The suite above was **passing at 184,336 checks / 0
mismatches** the entire time. Confirmed defects, all now fixed and pinned by regressions:

1. **`pitch_bytes < width * 4_c_int32_t` overflowed in 32 bits** (found independently by
   all four lenses). For `width >= 2**29` the product wrapped non-positive, so the
   comparison was false for *every* pitch and the guard **failed open** — precisely the
   garbage handoff it exists to reject. `width=INT32_MAX` gave `width*4 == -4`, init
   returned 0, and the renderer armed with `fb_width=2147483647` against a 1920-word
   stride. It also admitted a **negative** pitch, which `shiftr(pitch,2)` then turned
   into a ~1e9-word stride. Fixed by comparing in 64 bits.
2. **`vga_fill_rect`'s loop bounds overflowed** — `do py = y, y + h - 1` computes the
   bound in int32, so a large `h` wrapped negative and the fill silently drew **nothing**.
   Fixed by clamping to the visible area in 64-bit before looping.
3. **`vga_print_string`'s x advance overflowed** — fixed in 64-bit with an early exit
   once the origin passes the right edge.

The lesson is the same one `AUDIT-PHASE1.md` drew: **the test suite's edge-case table was
the weak part, not the code review.** Every geometry-rejection case in the original driver
used small values (`w=64, pitch=255`), entirely inside the non-overflowing regime.

## Guard regions: why byte-comparison alone was not enough

Mutation 4 initially **escaped**. Comparing every byte *of the framebuffer* cannot see a
write that lands **past** it — and that is exactly what a missing clip does. Removing the
bottom-edge clip made `vga_plot_pixel(0, fb_height)` store one word beyond the allocation:
a real heap overflow, invisible to a comparison bounded by that allocation.

Every test framebuffer is now bracketed by 4096-byte sentinel guard regions that are
verified alongside the image, so any store outside the framebuffer is a hard failure
rather than silent corruption. Worth noting the ordering: fixing `vga_fill_rect` to clamp
its rectangle *reduced* the suite's sensitivity, because out-of-bounds writes stopped
being generated by that path. A correctness fix made a test weaker — which is only
visible if mutations are re-run after every change, not once at the end.

## Mutation 13 escaped, and the reason is arithmetic

`vga_print_string`'s int32 x advance is a real overflow, but it cannot be reached by a
test. The wrap only lands **back inside the visible area** after ~2**28 glyphs:

```
i=         1  true=  2147483640  wrapped=  2147483640  visible? no
i=        64  true=  2147484144  wrapped= -2147483152  visible? no
i= 268435458  true=  4294967296  wrapped=           0  visible? YES
```

That needs a 256 MiB unterminated buffer. Below it, wrapped and unwrapped origins are
both off-screen and clip to nothing, so the framebuffer is byte-identical either way.
The fix's real value is **bounding the read**: without the early exit, a caller passing
`max_chars = INT32_MAX` with an unterminated buffer walks up to 2 GiB of memory. A
pixel-comparison test cannot observe a read.

## Mutation 12 escaped, and it cannot be made to fail

The differential test allocates the framebuffer with `malloc` and reads it back to
compare. That makes every store **observable by construction**, so the compiler has no
licence to remove one, so removing `VOLATILE` changes nothing the test can see. This is
a structural limit of host-side testing, not a gap that a better assertion would close.

What was done instead — compile both variants under the kernel flag set and read the
disassembly (gfortran 16.1.1, `-O2`):

```
volatile=yes   vga_plot_pixel 0x58   vga_fill_rect 0xe9   vga_print_char.part.0 0x99
volatile=no    vga_plot_pixel 0x52   vga_fill_rect 0xc0   vga_print_char.part.0 0x85
```

Codegen genuinely differs, but **the store survives in both** (`mov %edx,(%rcx,%rax,1)`
is present either way). The difference is only that the non-volatile build folds
descriptor fields into memory operands rather than materialising them in registers.

So the honest position is: `VOLATILE` is not currently preventing a miscompile, and any
comment claiming the screen would go black without it is wrong. It is retained for the
same reason `tools/../Makefile` retains `-fwrapv` — *"Removing it does not fail the suite
today, which is exactly why it must not be dropped casually."* The guarantee it buys
(one assignment is one memory access, not merged, hoisted, or cached across a call)
becomes load-bearing once the framebuffer is mapped write-combining, which is the normal
UEFI GOP configuration.

**Operational consequence:** `VOLATILE` on this pointer is protected by review and by
this document, not by a test. Anyone deleting it to save six instructions should be
required to re-run the disassembly comparison above.

## What is still unproven

The renderer has never drawn a pixel on real hardware, or in QEMU. Everything above is
a host-side proof of *arithmetic and memory-layout* correctness under the kernel flag
set. The claims it does **not** support:

- that the Multiboot2 framebuffer tag is requested or parsed correctly (roadmap 2.2 —
  no boot path exists yet);
- that the firmware's pixel format is BGRx rather than RGBx on any given machine (this
  module passes the colour word through unconverted by design);
- that anything is visible on the Minisforum's actual display.

Those need roadmap 0.1–0.3 and 1.2 first.
