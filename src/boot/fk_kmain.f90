! SPDX-License-Identifier: GPL-2.0
!> Provisional Fortran entry point for the Multiboot2 boot path (roadmap 1.2).
!!
!! WHAT THIS IS, AND WHAT IT IS NOT
!!
!! This is the placeholder kernel_main that roadmap 1.2 needs in order to be
!! testable at all: boot.S has to call SOMETHING, and the linker has to resolve
!! it. It is not the real kernel entry point -- that arrives with 1.4 (panic
!! handler) and 2.2 (framebuffer handover), each of which needs machinery that
!! does not exist yet. 2.1 (serial) HAS landed, and the console brought up
!! below is the first piece of the real entry point to appear here.
!!
!! It deviates from "just an infinite loop" in three deliberate ways. The first
!! two are what make the boot path PROVABLE rather than merely plausible; the
!! third is what makes everything after it DEBUGGABLE:
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
!!   3. It brings the COM1 UART up and prints a banner (roadmap 2.1) before
!!      parking. That is deliberately the first thing after the sentinel and
!!      not a decoration: every phase from here on -- the IDT, the page tables,
!!      the PCI walk -- is debugged through that console, so it has to work
!!      before there is anything interesting to say on it.
!!
!! WHY A SENTINEL *AND* A PRINTED BANNER
!!
!! This paragraph used to say that printing was impossible at this milestone,
!! and it was: no 0xB8000 text mode on a UEFI target, no framebuffer address
!! because the Multiboot2 header deliberately does not request one (boot.S,
!! roadmap 2.2), and no serial driver because that WAS 2.1. 2.1 has now landed
!! (src/drivers/serial/fk_serial.f90), so the sentinel could in principle be
!! deleted in favour of the banner.
!!
!! It is KEPT, because the two are evidence of different things and neither
!! subsumes the other:
!!
!!   the sentinel  is read out of GUEST PHYSICAL MEMORY over QMP, after the CPU
!!                 has parked, and depends on no device model, no chardev and
!!                 no redirection. It survives a console that silently drops
!!                 every byte -- which is exactly what serial_print_char does
!!                 when THRE never arrives, BY DESIGN, because hanging inside
!!                 the debug console is the worse failure. A console cannot
!!                 report that it is not working; this can.
!!
!!   the banner    is the only evidence that carries a MESSAGE. The sentinel is
!!                 four fixed words: it can say "kernel_main ran and the loader
!!                 handoff was live", and it can never say which branch was
!!                 taken or how many pages were free. It also proves the whole
!!                 chain the sentinel does not touch -- fk_outb, the port
!!                 space, the UART, the divisor -- while the machine is still
!!                 running.
!!
!! So the sentinel proves the assembly -> Fortran ABI, the banner proves the
!! console, and a boot where the sentinel is correct but the serial log is
!! empty localises the fault to fk_serial and no further. That is strictly
!! better than either gate alone, which is why tools/qemu-boot-test.sh now
!! asserts both and neither one was retired.
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
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t, c_char, &
                                         c_null_char
  ! ONLY-list, not a bare USE: this pulls in the port constant and the two
  ! entry points the boot path actually calls, and leaves fk_serial's register
  ! tables and private state where they belong. A whole-module USE would put
  ! twenty UART bit names into this scope and leave the next reader working out
  ! which of them the boot path depends on. (None of them: it depends on three.)
  use fk_serial_m, only: FK_SERIAL_COM1, serial_init, serial_print_string
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

  !> CR LF, in that order, and never a bare LF.
  !!
  !! A raw serial line performs no newline translation of any kind. A terminal
  !! handed a bare LF advances one row and keeps its column, so successive
  !! lines stair-step diagonally down the screen -- a cosmetic-looking defect
  !! that makes a multi-line panic dump genuinely hard to read. Linux applies
  !! the same translation one layer above its driver, in arch/x86/boot/tty.c's
  !! putchar() ("if (ch == '\n') putchar('\r')"), and this kernel puts it in
  !! the same place: serial_print_char is deliberately a raw byte writer with
  !! no policy of its own, so that roadmap 3.5 can send a page-table hex dump
  !! through it without the console rewriting the bytes.
  character(kind=c_char, len=*), parameter :: FK_CRLF = achar(13) // achar(10)

  !> The boot banner, NUL-terminated so it can be passed as a C `const char *`.
  !!
  !! THE TEXT IS FROZEN AT "Fortran Kernel: UART Serial Initialized."
  !! tools/qemu-boot-test.sh greps the captured COM1 log for exactly that
  !! string (FK_EXPECT_SERIAL), so a changed capital, a lost full stop or an
  !! added exclamation mark turns a passing boot gate into a failing one with
  !! no other symptom to go on.
  !!
  !! CONCATENATION IS LEGAL HERE ONLY BECAUSE THIS IS A PARAMETER. An
  !! initialisation expression is constant-folded at compile time into one
  !! .rodata string, so no code runs and nothing is copied. The identical
  !! expression in EXECUTABLE code would assemble the result into a temporary,
  !! which gfortran may lower to a memmove call -- an undefined symbol in a
  !! kernel with no libc, and exactly what `make symcheck-boot` and
  !! tools/linktest.sh gate (c) exist to reject. The rule is not "avoid //",
  !! it is "// only where the compiler can prove the answer".
  character(kind=c_char, len=*), parameter :: FK_BANNER = &
       "Fortran Kernel: UART Serial Initialized." // FK_CRLF // c_null_char

  !> Printed only when serial_init's internal loopback probe did not read back
  !! the byte it wrote.
  !!
  !! THIS LINE IS WHAT MAKES THE SELF-TEST MEAN ANYTHING. serial_init already
  !! computed a status and arms the console either way, so without somewhere for
  !! that status to GO the probe was doing work nothing could observe.
  !!
  !! WHAT IT DOES AND DOES NOT BUY, measured rather than predicted. It was added
  !! expecting it would also catch a broken fk_inb -- delete the zero-extension
  !! and the loopback probe should read back the wrong byte. It does not: that
  !! mutation was built and booted and the run is completely clean, because at
  !! that call site the stale upper bits of EAX happen to be zero and the probe
  !! still matches (docs/HARNESS-VALIDATION-SERIAL.md, M15; the white-box check
  !! in tools/linkscript-test.sh is what actually covers it).
  !!
  !! What this line does buy is the failure it was named for: a UART that really
  !! does not answer. An absent port floats to 0xFF, a mis-decoded port reads
  !! something else, loopback never engages -- and in every one of those cases
  !! the kernel now SAYS so on the console instead of the operator inferring it
  !! from silence that looks identical to a working machine with nothing
  !! attached.
  !!
  !! tools/qemu-boot-test.sh therefore asserts this string is ABSENT, which is a
  !! different and stronger shape of assertion than the banner's: the banner
  !! proves something happened, this proves something did NOT. A gate that only
  !! ever greps for text it wants cannot notice a kernel that is telling it
  !! something is wrong.
  !!
  !! It is a SEPARATE line rather than a suffix on the banner so that the banner
  !! text stays byte-stable -- FK_EXPECT_SERIAL greps for it exactly, and a
  !! banner that changed shape on failure would make the two assertions
  !! interfere.
  character(kind=c_char, len=*), parameter :: FK_SELFTEST_FAILED = &
       "Fortran Kernel: COM1 loopback self-test FAILED." // FK_CRLF // c_null_char

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
    integer(c_int32_t) :: status

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

    ! ---- roadmap 2.1: bring up the console ------------------------------
    !
    ! AFTER the sentinel, not before. The sentinel stores are the evidence
    ! that this routine ran at all, and they must not be sequenced behind a
    ! driver that talks to hardware: if the UART bring-up ever wedged the
    ! machine, ordering it first would destroy the one piece of evidence that
    ! could say how far the boot got.
    !
    ! THE STATUS IS REPORTED, NOT ACTED ON.
    !
    ! serial_init returns 1 when its internal loopback probe did not read back
    ! the byte it wrote, and it arms the console either way (see that routine's
    ! header -- a debug console that refuses to speak because it doubts itself
    ! is worse than one that speaks into a void). There is nothing here that
    ! could usefully RESPOND to a 1: roadmap 1.4's panic handler does not exist,
    ! and if it did, its first act would be to print.
    !
    ! So it is said out loud instead. That is not decoration: a status nothing
    ! observes is a test nothing runs, and this one was exactly that until the
    ! line below existed -- see FK_SELFTEST_FAILED above for the mutation it
    ! turned from an escape into a caught defect.
    !
    ! It is NOT stored into fk_boot_sentinel. That structure's four-word layout
    ! is asserted byte for byte by tools/qmp-sentinel.py, so a fifth word would
    ! fail the roadmap 1.2 gate -- to record something COM1 now says in English.
    ! The two gates stay independent.
    status = serial_init(FK_SERIAL_COM1)

    ! SEQUENCE ASSOCIATION, not an array descriptor. FK_BANNER is a character
    ! SCALAR of length 43 and the dummy is `character(kind=c_char) :: s(*)`;
    ! F2018 15.5.2.11 associates the scalar's storage sequence with the
    ! assumed-size array, so what crosses the call is the address of the
    ! .rodata literal and not one byte is copied. An assumed-shape `s(:)`
    ! dummy would instead expect a CFI_cdesc_t here and read the banner's own
    ! bytes as a descriptor header -- see docs/AUDIT-PHASE1.md, "On hidden
    ! array descriptors".
    call serial_print_string(FK_BANNER)

    ! The banner goes out FIRST, unconditionally, and the diagnosis after it.
    ! Reversing them would put the least-trusted output ahead of the line that
    ! establishes the console works at all, and a reader looking at a log that
    ! begins with a failure has no way to tell a failing self-test from a
    ! failing driver.
    if (status /= 0_c_int32_t) call serial_print_string(FK_SELFTEST_FAILED)

    call fk_cpu_halt()
  end subroutine kernel_main

end module fk_kmain_m
