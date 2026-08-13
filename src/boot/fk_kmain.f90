! SPDX-License-Identifier: GPL-2.0
! Fortran entry point for the Multiboot2 boot path.  boot/boot.S calls
! kernel_main once the CPU is in 64-bit long mode; it records the loader handoff
! in fk_boot_sentinel, brings COM1 up, installs the GDT, TSS and IDT, pacifies
! the legacy 8259s, brings the PMM up against the loader's memory map and puts
! it through pmm_verify below, and then faults on purpose so the catcher has
! something to catch.
! tools/qemu-boot-test.sh reads the sentinel back over QMP and greps the
! captured COM1 log.
module fk_kmain_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t, c_char, &
                                         c_null_char
  use fk_serial_m, only: FK_SERIAL_COM1, serial_init, serial_print_string, &
                         serial_print_hex
  use fk_gdt_m,    only: gdt_init
  use fk_tss_m,    only: tss_init
  use fk_idt_m,    only: idt_init
  use fk_pic_m,    only: pic_remap
  use fk_pmm_m,    only: FK_PMM_PAGE_SIZE, FK_PMM_OK, FK_PMM_E_UNALIGNED, &
                         FK_PMM_E_LOCKED, FK_PMM_E_DOUBLE_FREE, &
                         pmm_init, pmm_alloc_page, pmm_free_page, &
                         pmm_total_pages, pmm_free_pages, pmm_ignored_bytes, &
                         pmm_region_count, pmm_region_base, pmm_region_len, &
                         pmm_region_type, pmm_verify_reserved, &
                         pmm_verify_kernel_locked
  implicit none
  private
  public :: kernel_main

  ! "KBOT": marks the sentinel as written here rather than left uninitialised.
  integer(c_int32_t), parameter :: FK_BOOT_TAG = int(z'4B424F54', c_int32_t)

  ! The value a Multiboot2-compliant loader is required to leave in EAX.
  integer(c_int32_t), parameter :: MB2_BOOTLOADER_MAGIC = int(z'36D76289', c_int32_t)

  ! Not zero, so "never written" and "written with zeros" stay distinguishable.
  integer(c_int32_t), parameter :: FK_UNWRITTEN = int(z'11111111', c_int32_t)

  ! Handoff record: (1) FK_BOOT_TAG, (2) the loader's magic, (3) the low 32
  ! bits of the MBI pointer, (4) tag xor magic computed at run time.  VOLATILE:
  ! the only reader is outside the program -- QMP, after the CPU has parked.
  integer(c_int32_t), volatile, bind(c, name="fk_boot_sentinel") :: &
       fk_boot_sentinel(4) = [FK_UNWRITTEN, FK_UNWRITTEN, FK_UNWRITTEN, FK_UNWRITTEN]

  ! CR LF, never a bare LF: a raw serial line does no newline translation.
  character(kind=c_char, len=*), parameter :: FK_CRLF = achar(13) // achar(10)

  ! tools/qemu-boot-test.sh greps the COM1 log for this text exactly.  The
  ! concatenation is constant-folded into one .rodata string only because these
  ! are PARAMETERs; in executable code gfortran may lower // to a memmove call.
  character(kind=c_char, len=*), parameter :: FK_BANNER = &
       "Fortran Kernel: UART Serial Initialized." // FK_CRLF // c_null_char

  ! Printed when serial_init's loopback probe failed; qemu-boot-test.sh asserts
  ! this string is ABSENT from the log.
  character(kind=c_char, len=*), parameter :: FK_SELFTEST_FAILED = &
       "Fortran Kernel: COM1 loopback self-test FAILED." // FK_CRLF // c_null_char

  character(kind=c_char, len=*), parameter :: FK_GDT_READY = &
       "Fortran Kernel: GDT loaded, flat 64-bit model." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_TSS_READY = &
       "Fortran Kernel: TSS loaded, IST1 armed for #DF." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IDT_READY = &
       "Fortran Kernel: IDT loaded, 32 CPU exceptions armed." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PIC_READY = &
       "Fortran Kernel: 8259 PIC remapped to 0x20/0x28, all IRQs masked." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PIC_FAILED = &
       "Fortran Kernel: 8259 PIC mask readback FAILED." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_TRIGGER_DE = &
       "Fortran Kernel: dividing by zero on purpose (roadmap 3.2)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_TRIGGER_DF = &
       "Fortran Kernel: smashing RSP to force a #DF (roadmap 3.2.5)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_NO_FAULT = &
       "Fortran Kernel: the deliberate fault did NOT trap." // FK_CRLF // c_null_char

  ! roadmap 3.4.  Every one of these is greppable by tools/qemu-boot-test.sh,
  ! and each PASS line has a FAIL twin that the gate REJECTS -- a verdict the
  ! gate does not refuse is a verdict the kernel is free to get wrong.
  character(kind=c_char, len=*), parameter :: FK_NL = FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_START = &
       "Fortran Kernel: PMM parsing the Multiboot2 memory map (roadmap 3.4)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_INIT_FAILED = &
       "Fortran Kernel: PMM init FAILED, status 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_HEADER = &
       "PMM  ID BASE               END                TYPE" // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_ROW    = "PMM  " // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_SP     = " " // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_0X     = "0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_ALLOC  = "ALLOC 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_TOTALS = &
       "Fortran Kernel: PMM frames total/free/unmanaged-bytes 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_SLASH  = "/0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_TAKEN  = &
       "Fortran Kernel: PMM handed out 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_BEFORE = &
       " frames before it refused." // FK_CRLF // c_null_char

  character(kind=c_char, len=*), parameter :: FK_PMM_RSVD_OK = &
       "Fortran Kernel: PMM reserved and ACPI frames are all marked used." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_RSVD_BAD = &
       "Fortran Kernel: PMM reserved or ACPI frames are STILL FREE." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_LOCK_OK = &
       "Fortran Kernel: PMM locked the kernel image and the loader map out." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_LOCK_BAD = &
       "Fortran Kernel: PMM did NOT lock the kernel image out." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_ALLOC_OK = &
       "Fortran Kernel: PMM allocated 5 contiguous frames." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_ALLOC_BAD = &
       "Fortran Kernel: PMM allocation is NOT contiguous." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_RECLAIM_OK = &
       "Fortran Kernel: PMM freed and reclaimed the same 5 frames." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_RECLAIM_BAD = &
       "Fortran Kernel: PMM reclaim FAILED." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_GUARD_OK = &
       "Fortran Kernel: PMM refused a double, unaligned and locked free." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_GUARD_BAD = &
       "Fortran Kernel: PMM guard FAILED." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_CURSOR_OK = &
       "Fortran Kernel: PMM rewound its scan cursor to a freed frame." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_CURSOR_BAD = &
       "Fortran Kernel: PMM cursor rewind FAILED." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_OOM_HDR = &
       FK_CRLF // "*** PMM OUT OF MEMORY ***" // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_DRAIN = &
       "Fortran Kernel: draining the PMM to force an OOM panic (roadmap 3.4)." // &
       FK_CRLF // c_null_char

  ! Multiboot2 3.6 types, indexed by the type code; 0 catches anything the
  ! specification does not name, all of which is treated as reserved.
  character(kind=c_char, len=16), parameter :: FK_MEM_TYPE_NAME(0:5) = &
       [ character(kind=c_char, len=16) :: &
         "UNKNOWN"      // c_null_char, &
         "AVAILABLE"    // c_null_char, &
         "RESERVED"     // c_null_char, &
         "ACPI-RECLAIM" // c_null_char, &
         "ACPI-NVS"     // c_null_char, &
         "BADRAM"       // c_null_char ]

  ! How many frames the verification subroutine takes and gives back.
  integer(c_int32_t), parameter :: FK_PMM_TEST_PAGES = 5_c_int32_t

  ! Enough to push the scan cursor out of the bitmap word the first frame is
  ! in.  64 frames to a word, so anything over 64 crosses at least one boundary
  ! from any start; 96 leaves margin without costing a visible amount of boot.
  integer(c_int32_t), parameter :: FK_PMM_CURSOR_PAGES = 96_c_int32_t

  ! WHICH fault kernel_main raises once the tables are up.  8 = #DF, which is
  ! the milestone: it is the only way to exercise the IST1 stack switch.  0 =
  ! #DE, which is NOT redundant -- #DF arrives with a CPU error code and so
  ! only reaches the ISR_ERR half of boot/interrupts.S, leaving the dummy-push
  ! half that roadmap 3.2's M1 mutation targets unexercised.  -1 is roadmap
  ! 3.4's: not a vector at all, but "drain the PMM until it refuses", which is
  ! the only way to watch the out-of-memory panic actually fire.  A PARAMETER,
  ! so the branches not taken are folded away rather than shipped;
  ! tools/mutate-phase3.sh seds this line and rebuilds to run the other gates.
  integer(c_int32_t), parameter :: FK_FAULT_MODE = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_FAULT_PMM_OOM = -1_c_int32_t

  ! BOTH operands are volatile, and that is not belt and braces: with a literal
  ! numerator gcc rewrites 1/x into a compare against +-1 and emits no DIV at
  ! all, so the fault this milestone exists to raise never happens.  Module
  ! scope keeps the values inspectable in guest memory.
  integer(c_int32_t), volatile :: fk_dividend = 1_c_int32_t
  integer(c_int32_t), volatile :: fk_divisor  = 0_c_int32_t
  integer(c_int32_t), volatile :: fk_quotient = 0_c_int32_t

  interface
    ! Parks this CPU permanently (CLI; HLT) and never returns.  In boot/boot.S,
    ! because a privileged CPU-control instruction has no Fortran spelling.
    subroutine fk_cpu_halt() bind(c, name="fk_cpu_halt")
      implicit none
    end subroutine fk_cpu_halt

    ! Points RSP at nothing and pushes.  boot/faultgen.S.  Never returns: the
    ! next thing to execute is the #DF gate.
    subroutine fk_smash_stack() bind(c, name="fk_smash_stack")
      implicit none
    end subroutine fk_smash_stack

    ! INT3.  boot/faultgen.S.  Vector 3 is installed, so this reaches the same
    ! catcher every hardware fault does and the register dump is the machine's.
    subroutine fk_raise_bp() bind(c, name="fk_raise_bp")
      implicit none
    end subroutine fk_raise_bp
  end interface

contains

  ! roadmap 3.4's verification subroutine.  Prints the map the loader reported,
  ! then exercises the allocator and prints one verdict per property.  Each
  ! verdict is a line tools/qemu-boot-test.sh greps for, and each has a FAIL
  ! twin in the gate's reject list -- printing a verdict nobody refuses would
  ! only move the assertion inside the thing being asserted.
  !
  ! mbi is taken as an argument for the locked-free probe below: freeing the
  ! frame the loader's own structure sits in must be REFUSED, and this is the
  ! one such address kernel_main already holds.
  subroutine pmm_verify(mbi)
    implicit none
    integer(c_int64_t), intent(in) :: mbi
    integer(c_int32_t) :: i, n, t
    integer(c_int64_t) :: b, l, base
    integer(c_int64_t) :: pg(FK_PMM_TEST_PAGES), again(FK_PMM_TEST_PAGES)
    logical :: ok

    call serial_print_string(FK_PMM_HEADER)
    n = pmm_region_count()
    do i = 1_c_int32_t, n
       b = pmm_region_base(i)
       l = pmm_region_len(i)
       t = pmm_region_type(i)
       call serial_print_string(FK_PMM_ROW)
       call serial_print_hex(int(i, c_int64_t), 2_c_int32_t)
       call serial_print_string(FK_PMM_SP)
       call serial_print_string(FK_PMM_0X)
       call serial_print_hex(b, 16_c_int32_t)
       call serial_print_string(FK_PMM_SP)
       call serial_print_string(FK_PMM_0X)
       ! END, not length: the specification reports a length, but every question
       ! asked of a map -- does it hold this frame, does it abut the next region
       ! -- is asked about the end.
       call serial_print_hex(b + l, 16_c_int32_t)
       call serial_print_string(FK_PMM_SP)
       if (t >= 1_c_int32_t .and. t <= 5_c_int32_t) then
          call serial_print_string(FK_MEM_TYPE_NAME(t))
       else
          call serial_print_string(FK_MEM_TYPE_NAME(0))
       end if
       call serial_print_string(FK_NL)
    end do

    call serial_print_string(FK_PMM_TOTALS)
    call serial_print_hex(pmm_total_pages(), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(pmm_free_pages(), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(pmm_ignored_bytes(), 16_c_int32_t)
    call serial_print_string(FK_NL)

    ! roadmap 3.4's "safety & boundaries": nothing the loader called reserved,
    ! ACPI, NVS or defective may be free, and neither may this kernel's own
    ! image or the loader's structure.
    if (pmm_verify_reserved() == 0_c_int64_t) then
       call serial_print_string(FK_PMM_RSVD_OK)
    else
       call serial_print_string(FK_PMM_RSVD_BAD)
    end if

    if (pmm_verify_kernel_locked() == 0_c_int64_t) then
       call serial_print_string(FK_PMM_LOCK_OK)
    else
       call serial_print_string(FK_PMM_LOCK_BAD)
    end if

    ! Five frames.  Contiguity is not a promise the interface makes -- it is
    ! what a first-fit scan over a bitmap with no holes in it yet MUST produce,
    ! so its absence says the scan or the bit-setting is wrong.
    ok = .true.
    do i = 1_c_int32_t, FK_PMM_TEST_PAGES
       pg(i) = pmm_alloc_page()
       call serial_print_string(FK_PMM_ROW)
       call serial_print_string(FK_PMM_ALLOC)
       call serial_print_hex(pg(i), 16_c_int32_t)
       call serial_print_string(FK_NL)
       if (pg(i) == 0_c_int64_t) ok = .false.
       if (i > 1_c_int32_t) then
          if (pg(i) /= pg(i - 1_c_int32_t) + FK_PMM_PAGE_SIZE) ok = .false.
       end if
    end do
    if (ok) then
       call serial_print_string(FK_PMM_ALLOC_OK)
    else
       call serial_print_string(FK_PMM_ALLOC_BAD)
    end if

    ! Give them back and take them again.  The SAME five addresses is the
    ! evidence: a free that clears the bit but leaves the scan cursor above it
    ! reports success and never hands the frame out again.
    ok = .true.
    do i = 1_c_int32_t, FK_PMM_TEST_PAGES
       if (pmm_free_page(pg(i)) /= FK_PMM_OK) ok = .false.
    end do
    do i = 1_c_int32_t, FK_PMM_TEST_PAGES
       again(i) = pmm_alloc_page()
       if (again(i) /= pg(i)) ok = .false.
    end do
    if (ok) then
       call serial_print_string(FK_PMM_RECLAIM_OK)
    else
       call serial_print_string(FK_PMM_RECLAIM_BAD)
    end if

    ! The three refusals, then hand everything back so the allocator is left
    ! exactly as pmm_init produced it.
    ok = .true.
    if (pmm_free_page(again(1)) /= FK_PMM_OK)            ok = .false.
    if (pmm_free_page(again(1)) /= FK_PMM_E_DOUBLE_FREE) ok = .false.
    if (pmm_free_page(again(2) + 8_c_int64_t) /= FK_PMM_E_UNALIGNED) ok = .false.
    ! The frame the loader's structure lives in.  Rounded down because the MBI
    ! is 8-byte aligned and nothing more; an unaligned address would be refused
    ! for the wrong reason and prove nothing about the lock.
    if (pmm_free_page(iand(mbi, not(FK_PMM_PAGE_SIZE - 1_c_int64_t))) &
        /= FK_PMM_E_LOCKED) ok = .false.
    do i = 2_c_int32_t, FK_PMM_TEST_PAGES
       if (pmm_free_page(again(i)) /= FK_PMM_OK) ok = .false.
    end do
    if (ok) then
       call serial_print_string(FK_PMM_GUARD_OK)
    else
       call serial_print_string(FK_PMM_GUARD_BAD)
    end if

    ! THE CHECK THE FIVE-FRAME TEST ABOVE CANNOT MAKE, and it took a mutation
    ! that survived the gate to notice.  Five consecutive frames all live in
    ! ONE 64-bit bitmap word, so the scan cursor never leaves it: a free that
    ! forgets to rewind the cursor still finds them, and "reclaimed the same 5
    ! frames" prints PASS.  Take enough frames to move the cursor into another
    ! word first, and only then ask for the first one back.
    ok = .true.
    base = pmm_alloc_page()
    if (base == 0_c_int64_t) ok = .false.
    do i = 2_c_int32_t, FK_PMM_CURSOR_PAGES
       if (pmm_alloc_page() == 0_c_int64_t) ok = .false.
    end do
    if (pmm_free_page(base) /= FK_PMM_OK) ok = .false.
    if (pmm_alloc_page() /= base) ok = .false.
    ! Hand the block back.  The addresses are computed rather than remembered:
    ! they are contiguous, which the verdict above has already established, and
    ! if they are not then these frees refuse and this verdict fails too.
    do i = 0_c_int32_t, FK_PMM_CURSOR_PAGES - 1_c_int32_t
       if (pmm_free_page(base + int(i, c_int64_t) * FK_PMM_PAGE_SIZE) &
           /= FK_PMM_OK) ok = .false.
    end do
    if (ok) then
       call serial_print_string(FK_PMM_CURSOR_OK)
    else
       call serial_print_string(FK_PMM_CURSOR_BAD)
    end if
  end subroutine pmm_verify

  ! Take frames until the allocator refuses, then panic through a real INT3 so
  ! the register dump in fk_idt_m is the machine's own.  Only reachable when
  ! FK_FAULT_MODE is FK_FAULT_PMM_OOM; the shipped image folds it away.
  subroutine pmm_drain_to_oom()
    implicit none
    integer(c_int64_t) :: addr, taken, bound

    call serial_print_string(FK_PMM_DRAIN)
    taken = 0_c_int64_t
    ! Bounded, not `do forever`: an allocator that computes an address but
    ! forgets to set the bit hands out the same frame for ever, and an
    ! unbounded loop turns that into a machine that says nothing at all
    ! instead of a gate that fails.  It cost an afternoon on the host suite
    ! to learn that -- see HE in docs/HARNESS-VALIDATION-PHASE3.md.
    bound = pmm_total_pages() + 1_c_int64_t
    do while (taken < bound)
       addr = pmm_alloc_page()
       if (addr == 0_c_int64_t) exit
       taken = taken + 1_c_int64_t
    end do

    call serial_print_string(FK_PMM_OOM_HDR)
    call serial_print_string(FK_PMM_TAKEN)
    call serial_print_hex(taken, 16_c_int32_t)
    call serial_print_string(FK_PMM_BEFORE)
    call serial_print_string(FK_PMM_TOTALS)
    call serial_print_hex(pmm_total_pages(), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(pmm_free_pages(), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(pmm_ignored_bytes(), 16_c_int32_t)
    call serial_print_string(FK_NL)
    call fk_raise_bp()
  end subroutine pmm_drain_to_oom

  ! Entry point called by boot/boot.S once the CPU is in 64-bit long mode.
  ! Does not return.  magic and mbi arrive by value per the SysV AMD64 C ABI,
  ! in EDI and RSI.
  subroutine kernel_main(magic, mbi) bind(c, name="kernel_main")
    implicit none
    integer(c_int32_t), intent(in), value :: magic
    integer(c_int64_t), intent(in), value :: mbi
    integer(c_int32_t) :: status

    ! Scalar stores, not an array assignment: gfortran may lower that to a
    ! memset call, which is an undefined symbol in a kernel with no libc.
    fk_boot_sentinel(1) = FK_BOOT_TAG
    fk_boot_sentinel(2) = magic
    ! Masked to 32 bits because the sentinel word is; INT() alone on a value
    ! with bit 31 set would be a range violation.
    fk_boot_sentinel(3) = int(iand(mbi, int(z'FFFFFFFF', c_int64_t)), c_int32_t)
    fk_boot_sentinel(4) = ieor(FK_BOOT_TAG, magic)

    ! After the sentinel: the stores are the evidence this routine ran, and
    ! must not be sequenced behind a driver that touches hardware.
    status = serial_init(FK_SERIAL_COM1)

    ! Sequence association (F2018 15.5.2.11): FK_BANNER is a character scalar
    ! and the dummy is character(kind=c_char) :: s(*), so the call passes the
    ! address of the .rodata literal and copies nothing.
    call serial_print_string(FK_BANNER)

    if (status /= 0_c_int32_t) call serial_print_string(FK_SELFTEST_FAILED)

    call gdt_init()
    call serial_print_string(FK_GDT_READY)

    ! Before the IDT: idt_init points vector 8 at an IST slot, and a #DF taken
    ! before LTR has run finds a null task register and triple-faults.
    call tss_init()
    call serial_print_string(FK_TSS_READY)

    call idt_init()
    call serial_print_string(FK_IDT_READY)

    if (pic_remap() == 0_c_int32_t) then
       call serial_print_string(FK_PIC_READY)
    else
       call serial_print_string(FK_PIC_FAILED)
    end if

    ! The PMM (roadmap 3.4).  After the IDT so a malformed map that faults is
    ! reported instead of resetting the machine, and after the PIC so a
    ! spurious IRQ during the long bitmap walk cannot arrive as an exception
    ! vector.  Before the deliberate fault, which never returns.
    call serial_print_string(FK_PMM_START)
    status = pmm_init(mbi)
    if (status == FK_PMM_OK) then
       call pmm_verify(mbi)
    else
       call serial_print_string(FK_PMM_INIT_FAILED)
       call serial_print_hex(int(status, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
    end if

    ! The deliberate fault.  Raised by the CPU, never simulated by a call.
    if (FK_FAULT_MODE == FK_FAULT_PMM_OOM) then
       call pmm_drain_to_oom()
    else if (FK_FAULT_MODE == 8_c_int32_t) then
       call serial_print_string(FK_TRIGGER_DF)
       call fk_smash_stack()
    else
       call serial_print_string(FK_TRIGGER_DE)
       fk_dividend = 1_c_int32_t
       fk_divisor  = 0_c_int32_t
       fk_quotient = fk_dividend / fk_divisor
    end if

    ! Reached only if the fault returned, which no gate installed here does.
    call serial_print_string(FK_NO_FAULT)
    call fk_cpu_halt()
  end subroutine kernel_main

end module fk_kmain_m
