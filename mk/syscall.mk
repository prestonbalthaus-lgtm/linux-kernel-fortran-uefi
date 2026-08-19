# SPDX-License-Identifier: GPL-2.0
TESTS         += syscall
# ORDER IS SEMANTIC. fk_syscall USEs fk_gdt for the selector contract and
# fk_idt for fk_regs_t, so both .mod files must exist first; fk_idt in turn
# drags in the four modules its own router talks to.
FSRC_syscall  := src/drivers/serial/fk_serial.f90 \
                 src/cpu/fk_gdt.f90 \
                 src/cpu/fk_tss.f90 \
                 src/drivers/pic/fk_pic.f90 \
                 src/drivers/pit/fk_pit.f90 \
                 src/cpu/fk_idt.f90 \
                 src/cpu/fk_syscall.f90
DRV_syscall   := tests/cpu/test_syscall.c

# NO ORACLE_syscall, and unusually the reason is not that Linux's version is
# entangled -- syscall_init() in arch/x86/kernel/cpu/common.c is nearly
# standalone. It is that the function's whole content is four WRMSRs, an
# instruction this suite cannot execute and must not: a host test that
# programmed the machine's real MSR_LSTAR would point the HOST's system calls
# at a Fortran routine in a test binary.
#
# So the split is by what can be established where, and it is a clean one:
#
#   HERE, on the host      the VALUES -- STAR's composition from the GDT
#                          selectors, FMASK's bit set against the vendor's own
#                          list -- and the ROUTER, which is ordinary code over
#                          a frame this file can build by hand. That includes
#                          the R10 argument, which is the one thing about this
#                          ABI a register-passing router would get wrong.
#
#   IN THE BOOT GATE       that the four registers actually took the values,
#                          read back with RDMSR; that a real SYSCALL lands in
#                          fk_syscall_handler; and that FMASK cleared what it
#                          names, which needs flags set by a real caller and a
#                          real instruction to clear them.
# UAPI FIRST, AND THE ORDER IS THE WHOLE POINT.  Both directories provide an
# asm/processor-flags.h: the uapi one is the flag definitions and nothing else,
# and the internal one includes linux/mem_encrypt.h and will not compile
# outside a kernel build.  The second path is only for asm/msr-index.h, which
# has no uapi twin and does compile standalone.  Measured: with the paths the
# other way round this test does not build at all.
CFLAGS_syscall := -Ivendor/linux-7.1.8/arch/x86/include/uapi \
                  -Ivendor/linux-7.1.8/arch/x86/include
