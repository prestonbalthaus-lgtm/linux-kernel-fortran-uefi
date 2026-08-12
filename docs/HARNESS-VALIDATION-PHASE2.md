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
| 1 | `btest(bits, 7-dx)` → `btest(bits, dx)` (glyphs read LSB-first) | **yes** | `byte 1484 (row 2, col 89) fortran=0x0C model=0xAA`. Every glyph mirrored horizontally. Note this lights the *same number of pixels*, so any test that counted lit pixels or spot-checked a few would have passed. |
| 2 | offset uses `fb_width` instead of `fb_stride` | **yes** | `byte 256 (row 0, col 64)` — writes land in the scanline slack. Correct on row 0, shears further with every row. |
| 3 | right-edge clip removed | **yes** | writes into the off-screen slack, which is mapped memory — corrupts silently on real hardware rather than faulting. |
| 4 | bottom-edge clip removed | **yes** | writes past the mapped region. |
| 5 | `fb(off+1)` → `fb(off+2)` (off-by-one) | **yes** | `byte 0 (row 0, col 0) fortran=0xAA model=0x06` — whole image shifted one pixel. |
| 6 | font block 00 duplicated over block 01 (256 bytes wrong) | **yes** | `MISMATCH font_row: C=0x00 F=0x80` |
| 7 | **one bit flipped in one font byte** (1 bit of 32768) | **yes** | `MISMATCH font_row: C=0x7C F=0x7D`, and independently in the rendered output at `byte 37816`. This is the check that makes a 4096-byte hardcoded table trustworthy. |
| 8 | `pitch mod 4` validation removed | **yes** | `MISMATCH init pitch%4: C=-3 F=0` |
| 9 | renderer not disarmed on failed init | **yes** | `inert after failed re-init: byte 0 fortran=0xFF model=0x20` — a rejected geometry left the old mapping live. |
| 10 | `VOLATILE` removed from the framebuffer pointer | **NO — escaped** | see below |

## Mutation 10 escaped, and it cannot be made to fail

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
