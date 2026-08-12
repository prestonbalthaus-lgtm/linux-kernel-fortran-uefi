! SPDX-License-Identifier: GPL-2.0
!> Provisional Fortran entry point for the Multiboot2 boot path (roadmap 1.2).
!!
!! WHAT THIS IS, AND WHAT IT IS NOT
!!
!! This is the placeholder kernel_main that roadmap 1.2 needs in order to be
!! testable at all: boot.S has to call SOMETHING, and the linker has to resolve
!! it. It is not the real kernel entry point -- that arrives with 1.4 (panic
!! handler), 2.1 (serial) and 2.2 (framebuffer handover), each of which needs
!! machinery that does not exist yet.
!!
!! It deviates from "just an infinite loop" in exactly two deliberate ways, and
!! both are what make the boot path PROVABLE rather than merely plausible:
!!
!!   1. It records its arguments into fk_boot_sentinel, a four-word structure
!!      in .data at a fixed, known physical address. tools/qemu-boot-test.sh
!!      reads those sixteen bytes back out of the running guest's physical
!!      memory over QMP. Without them, a kernel that triple-faults on the first
!!      instruction and a kernel that reaches Fortran correctly look identical
!!      from outside: both produce a machine that sits there doing nothing.
!!
!!   2. It parks the CPU with fk_cpu_halt (CLI; HLT) instead of spinning. A
!!      Fortran spin loop is functionally correct but pins a core at 100%
!!      forever -- with the project's -smp 6, six of them.
!!
!! WHY A SENTINEL AND NOT A PRINTED BANNER
!!
!! Printing needs a console, and this milestone has none: the UEFI target has
!! no 0xB8000 text mode, the GOP renderer needs a framebuffer address that the
!! Multiboot2 header does not yet request (see boot.S, roadmap 2.2), and the
!! serial driver is 2.1. A sentinel in memory needs nothing at all, and it is
!! strictly better evidence than a screenshot: sixteen bytes that either carry
!! the loader's live handoff values or do not.
!!
!! THE FOURTH WORD IS THE POINT. Words 1..3 could in principle be produced by
!! any code that stores constants. Word 4 is TAG xor magic, computed here at
!! run time from a value this module never sees at compile time. Asserting it
!! is what proves that live data crossed the assembly -> Fortran ABI boundary,
!! rather than that some plausible-looking bytes happen to be in memory.
!!
!! FREESTANDING CONSTRAINTS OBSERVED HERE
!!   * Every element of the sentinel is assigned SCALARLY. An array-section
!!     assignment (sentinel(:) = 0) lets gfortran emit a memset call, which is
!!     an undefined symbol in a kernel with no libc -- roadmap 1.3's debt, and
!!     the reason tools/linktest.sh greps for exactly that.
!!   * VOLATILE, because the only reader of this variable is outside the
!!     program: a debugger, or QEMU's pmemsave. Nothing in the image ever loads
!!     it back, so the stores are dead by every rule the compiler knows, and
!!     the routine that follows them never returns. This is one of the few
!!     places where VOLATILE is not belt-and-braces but load-bearing.
module fk_kmain_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t
  implicit none
  private
  public :: kernel_main

  !> "KBOT" in ASCII: the tag that says the words below were written by this
  !! routine and are not uninitialised memory that happens to look plausible.
  integer(c_int32_t), parameter :: FK_BOOT_TAG = int(z'4B424F54', c_int32_t)

  !> The value a Multiboot2-compliant loader is required to leave in EAX.
  integer(c_int32_t), parameter :: MB2_BOOTLOADER_MAGIC = int(z'36D76289', c_int32_t)

  !> Value the sentinel holds if kernel_main never ran. Chosen so that "never
  !! written", "written with zeros" and "written correctly" are three
  !! distinguishable outcomes in the dump -- a sentinel initialised to zero
  !! cannot tell the first two apart.
  integer(c_int32_t), parameter :: FK_UNWRITTEN = int(z'11111111', c_int32_t)

  !> The handoff record, at a fixed physical address (.data, so it is in the
  !! file image and its address is a link-time constant):
  !!   (1) FK_BOOT_TAG
  !!   (2) the magic the loader passed          -- expect 0x36D76289
  !!   (3) the low 32 bits of the MBI pointer   -- expect non-zero
  !!   (4) FK_BOOT_TAG xor magic, computed here at run time
  integer(c_int32_t), volatile, bind(c, name="fk_boot_sentinel") :: &
       fk_boot_sentinel(4) = [FK_UNWRITTEN, FK_UNWRITTEN, FK_UNWRITTEN, FK_UNWRITTEN]

  interface
    !> Park this CPU permanently (CLI; HLT). Implemented in boot/boot.S,
    !! because a privileged CPU-control instruction has no Fortran spelling.
    !! Never returns -- which Fortran cannot express, so the caller's dead
    !! code after it is unreachable rather than ill-formed.
    !!
    !! (Indented four spaces, not five: a line with exactly five leading
    !! spaces followed by a non-blank is the fixed-form continuation column,
    !! and tools/compliance.sh rejects the file as fixed-form source.)
    subroutine fk_cpu_halt() bind(c, name="fk_cpu_halt")
      ! An interface body is its own scoping unit and gets its own IMPLICIT
      ! NONE -- the rule is per program unit, not per file.
      implicit none
    end subroutine fk_cpu_halt
  end interface

contains

  !> Entry point called by boot/boot.S once the CPU is in 64-bit long mode.
  !!
  !! magic  the value the boot loader left in EAX (0x36D76289 for Multiboot2)
  !! mbi    physical address of the Multiboot information structure
  !!
  !! Both arrive BY VALUE per the SysV AMD64 C ABI: magic in EDI, mbi in RSI.
  !! mbi is taken as an integer rather than a TYPE(C_PTR) on purpose -- nothing
  !! here dereferences it, and carrying it as a bit pattern keeps this routine
  !! honest about the fact that it is an unmapped-until-3.5 physical address.
  !!
  !! DOES NOT RETURN. boot.S has a `jmp fk_cpu_halt` after the call site as a
  !! second line of defence, since a return would pop a return address that was
  !! never pushed by anything meaningful.
  subroutine kernel_main(magic, mbi) bind(c, name="kernel_main")
    implicit none
    integer(c_int32_t), intent(in), value :: magic
    integer(c_int64_t), intent(in), value :: mbi

    ! Scalar stores, in this order: the tag last would let a dump taken
    ! mid-write look like a complete record. Written first, it only ever
    ! claims "this routine started", which is exactly what it means.
    fk_boot_sentinel(1) = FK_BOOT_TAG
    fk_boot_sentinel(2) = magic
    ! IAND against the low 32 bits: mbi is a 64-bit pattern and the sentinel
    ! word is 32 bits. GRUB's MBI always sits below 4 GiB, so nothing is lost;
    ! INT() alone on a value with bit 31 set would be a range violation.
    fk_boot_sentinel(3) = int(iand(mbi, int(z'FFFFFFFF', c_int64_t)), c_int32_t)
    ! The computed word. IEOR is an inline machine instruction, not a runtime
    ! call -- see tools/linktest.sh, which fails the build if any Fortran
    ! object here references libgfortran.
    fk_boot_sentinel(4) = ieor(FK_BOOT_TAG, magic)

    call fk_cpu_halt()
  end subroutine kernel_main

end module fk_kmain_m
