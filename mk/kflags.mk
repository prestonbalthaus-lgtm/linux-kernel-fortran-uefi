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
# -fno-tree-loop-distribute-patterns is the Fortran half of what -ffreestanding
# does for C, and it is here because roadmap 3.4 arrived: gcc's loop-distribution
# pass rewrites a DO loop that stores one value across an array into a call to
# memset, which is an undefined symbol until roadmap 1.3 supplies one. Measured
# on gfortran 16.1.1 -- the PMM's 262144-word bitmap fill emits `U memset`
# without this flag and nothing at all with it. Linux passes the same flag for
# the same reason and gets away with the pass only because it defines its own
# memset. Small loops escaped the pass, which is why the tree got this far
# without it; see the scalar-stores comment in src/boot/fk_kmain.f90.
KFLAGS := -O2 -fwrapv -fno-underscoring \
          -mcmodel=kernel -mno-red-zone -fno-pic -fno-stack-protector \
          -fno-asynchronous-unwind-tables -fno-common -fno-strict-aliasing \
          -fno-tree-loop-distribute-patterns \
          -mno-sse -mno-mmx -mno-sse2 -mno-3dnow -mno-avx -mno-sse4a \
          -mno-80387 -mno-fp-ret-in-387
