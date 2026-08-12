# NOT a translation fragment -- this file declares no test.
#
# KFLAGS is the flag set the Linux kernel actually builds x86_64 with, mirrored
# from $(KDIR)/arch/x86/Makefile. It lives in its own file because THREE
# different things must compile kernel objects with byte-identical flags, and a
# copy that drifts is a copy that lies:
#
#   Makefile          `make kflags-test` -- the oracle comparison re-run under
#                     the real kernel flags
#   Makefile.boot     the actual kernel image (roadmap 1.2)
#   tools/linkscript-test.sh
#                     the layout gate; it reads this file back through make
#                     rather than keeping a fourth copy
#
# -fwrapv is CORRECTNESS-CRITICAL, not an optimisation preference: every
# translation carries u32/u64 bit patterns in signed integers and relies on
# two's-complement wrap being DEFINED rather than UB. See docs/AUDIT-PHASE1.md,
# A-4. The -mno-sse/-mno-80387 family keeps the compiler out of FPU and vector
# state that the long-mode entry path in boot/boot.S never initialises.
KFLAGS := -O2 -fwrapv -fno-underscoring \
          -mcmodel=kernel -mno-red-zone -fno-pic -fno-stack-protector \
          -fno-asynchronous-unwind-tables -fno-common -fno-strict-aliasing \
          -mno-sse -mno-mmx -mno-sse2 -mno-3dnow -mno-avx -mno-sse4a \
          -mno-80387 -mno-fp-ret-in-387
