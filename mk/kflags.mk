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
#                     the layout gate
#   tools/linktest.sh the per-module freestanding gate
#
# The last two read this file back through make rather than transcribing it.
# linktest.sh did keep its own copy until roadmap 3.4, and it drifted the first
# time a flag was added here: it reported the PMM's bitmap fill as a libc
# dependency in a module the real build links clean.
#
# -fwrapv is CORRECTNESS-CRITICAL, not an optimisation preference: every
# translation carries u32/u64 bit patterns in signed integers and relies on
# two's-complement wrap being DEFINED rather than UB. See docs/AUDIT-PHASE1.md,
# A-4. The -mno-sse/-mno-80387 family keeps the compiler out of FPU and vector
# state that the long-mode entry path in boot/boot.S never initialises.
#
# -fno-tree-loop-distribute-patterns WAS here from roadmap 3.4 until 1.3: gcc's
# loop-distribution pass rewrites a DO loop that fills or copies an array into a
# call to memset or memcpy, which was an undefined symbol in a kernel with no
# libc. src/lib/fk_string_abi.f90 now defines those symbols, so the pass is
# allowed to fire and the link resolves it -- which is what Linux does, and the
# reason Linux can pass the flag and still get a working memset either way.
# The intrinsics themselves cannot recurse into the pass: c_f_pointer builds a
# run-time-strided descriptor that it does not recognise (measured, 16.1.1).
KFLAGS := -O2 -fwrapv -fno-underscoring \
          -mcmodel=kernel -mno-red-zone -fno-pic -fno-stack-protector \
          -fno-asynchronous-unwind-tables -fno-common -fno-strict-aliasing \
          -mno-sse -mno-mmx -mno-sse2 -mno-3dnow -mno-avx -mno-sse4a \
          -mno-80387 -mno-fp-ret-in-387
