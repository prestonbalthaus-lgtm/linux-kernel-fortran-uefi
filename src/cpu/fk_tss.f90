! SPDX-License-Identifier: GPL-2.0
! 64-bit TSS and the Interrupt Stack Table (roadmap 3.2.5).  Long mode never
! task-switches through a TSS; the only thing this one exists for is IST1, the
! stack the CPU loads unconditionally when it delivers a #DF.  Without it a
! double fault caused by an unusable RSP is delivered ON that RSP, faults a
! third time, and the machine resets with nothing on the wire.
module fk_tss_m
  use, intrinsic :: iso_c_binding, only: c_int16_t, c_int32_t, c_int64_t, &
                                         c_loc, c_sizeof
  use fk_gdt_m, only: FK_GDT_SEL_TSS, gdt_set_tss
  implicit none
  private
  public :: FK_TSS_IST_DF, FK_TSS_IST_NMI, tss_init, tss_on_df_stack, &
            tss_on_nmi_stack, tss_set_rsp0

  ! The IST index the #DF gate descriptor carries.  1..7 select ist1..ist7; 0
  ! means "keep the faulting stack", which for #DF is the one thing that must
  ! not happen.
  integer(c_int32_t), parameter :: FK_TSS_IST_DF = 1_c_int32_t

  ! IST2, for NMI (roadmap 3.3).  An NMI can arrive on any instruction --
  ! including inside a handler that is mid-way through building a frame --
  ! so it needs a stack that is known-good regardless of what RSP held.
  ! Nothing raises one today; the LAPIC is what makes that stop being true.
  integer(c_int32_t), parameter :: FK_TSS_IST_NMI = 2_c_int32_t

  ! The TSS, in 32-bit halves.  NOT one field per architectural quadword: RSP0
  ! sits at offset 4, and the C struct rules that bind(c) follows would align a
  ! c_int64_t there to offset 8 and shift every field after it by four bytes.
  ! Measured on gfortran 16.1.1 rather than assumed.  All-32-bit fields have
  ! nothing to pad, so this type IS the hardware layout: IST1 at 0x24, the I/O
  ! map base at 0x66, 104 bytes -- read back out of the linked image by
  ! tools/linkscript-test.sh, which is where a regression would be caught.
  type, bind(c) :: fk_tss_t
    integer(c_int32_t) :: reserved0
    integer(c_int32_t) :: rsp0_lo, rsp0_hi
    integer(c_int32_t) :: rsp1_lo, rsp1_hi
    integer(c_int32_t) :: rsp2_lo, rsp2_hi
    integer(c_int32_t) :: reserved1_lo, reserved1_hi
    integer(c_int32_t) :: ist1_lo, ist1_hi
    integer(c_int32_t) :: ist2_lo, ist2_hi
    integer(c_int32_t) :: ist3_lo, ist3_hi
    integer(c_int32_t) :: ist4_lo, ist4_hi
    integer(c_int32_t) :: ist5_lo, ist5_hi
    integer(c_int32_t) :: ist6_lo, ist6_hi
    integer(c_int32_t) :: ist7_lo, ist7_hi
    integer(c_int32_t) :: reserved2_lo, reserved2_hi
    integer(c_int16_t) :: reserved3
    integer(c_int16_t) :: iomap_base
  end type fk_tss_t

  ! Access 0x89 = P|DPL0|S=0|type 9 (available 64-bit TSS).  The high quadword
  ! is base[63:32] and must be zero above that, so the type nibble the CPU
  ! checks there reads as 0.
  integer(c_int64_t), parameter :: FK_TSS_ACCESS = int(z'89', c_int64_t)

  ! 8 KiB.  boot/boot.S zeroes [__bss_start, __bss_end) before it calls
  ! kernel_main, so an uninitialised array here costs nothing in the image and
  ! arrives zeroed.  There is no guard page below it -- that needs the VMM at
  ! roadmap 3.5, and until then a runaway panic handler walks into whatever
  ! .bss put underneath.
  integer(c_int32_t), parameter :: FK_DF_STACK_QWORDS  = 1024_c_int32_t
  integer(c_int32_t), parameter :: FK_NMI_STACK_QWORDS = 1024_c_int32_t

  ! bind(c) on both, for the same reason fk_boot_sentinel has it: the readers
  ! that matter are OUTSIDE the program.  tools/qmp-sentinel.py compares the
  ! task register the CPU is actually holding against the address of fk_tss in
  ! the ELF, and tools/linkscript-test.sh reads the size of both back out of
  ! the linked image.  Neither can be written against a gfortran-mangled name.
  integer(c_int64_t), target, bind(c, name="fk_df_stack") :: &
       df_stack(FK_DF_STACK_QWORDS)
  integer(c_int64_t), target, bind(c, name="fk_nmi_stack") :: &
       nmi_stack(FK_NMI_STACK_QWORDS)
  type(fk_tss_t), target, bind(c, name="fk_tss") :: tss

  ! Bounds of the stack IST1 points into, kept for tss_on_df_stack.
  integer(c_int64_t), save :: df_lo = 0_c_int64_t
  integer(c_int64_t), save :: df_hi = 0_c_int64_t
  integer(c_int64_t), save :: nmi_lo = 0_c_int64_t
  integer(c_int64_t), save :: nmi_hi = 0_c_int64_t

  interface
    ! LTR.  boot/gdt_flush.S: needs the GDT loaded and the descriptor already
    ! written, and marks that descriptor BUSY, so it runs exactly once.
    subroutine tss_flush(sel) bind(c, name="tss_flush")
      import :: c_int16_t
      implicit none
      integer(c_int16_t), intent(in), value :: sel
    end subroutine tss_flush
  end interface

contains

  ! Low 32 bits of v in the signed kind Fortran has to store them in.
  pure function u32(v) result(w)
    implicit none
    integer(c_int64_t), intent(in) :: v
    integer(c_int32_t) :: w
    integer(c_int64_t) :: bits

    bits = iand(v, int(z'FFFFFFFF', c_int64_t))
    if (bits > 2147483647_c_int64_t) bits = bits - 4294967296_c_int64_t
    w = int(bits, c_int32_t)
  end function u32

  subroutine tss_init() bind(c, name="tss_init")
    implicit none
    integer(c_int64_t) :: base, limit, lo, hi

    df_lo = transfer(c_loc(df_stack), 0_c_int64_t)
    ! One past the end -- the stack grows down -- rounded DOWN to 16.  Fortran
    ! cannot demand an alignment from the compiler, and rounding here is what
    ! makes the ABI's 16-byte requirement independent of what gfortran chose.
    df_hi = iand(df_lo + 8_c_int64_t * int(FK_DF_STACK_QWORDS, c_int64_t), &
                 not(15_c_int64_t))

    tss%ist1_lo = u32(df_hi)
    tss%ist1_hi = u32(ishft(df_hi, -32))

    nmi_lo = transfer(c_loc(nmi_stack), 0_c_int64_t)
    nmi_hi = iand(nmi_lo + 8_c_int64_t * int(FK_NMI_STACK_QWORDS, c_int64_t), &
                  not(15_c_int64_t))
    tss%ist2_lo = u32(nmi_hi)
    tss%ist2_hi = u32(ishft(nmi_hi, -32))

    ! Past the segment limit, so ring 3 gets no I/O permission bitmap and every
    ! IN/OUT it attempts faults.  Nothing runs in ring 3 until roadmap 7.1;
    ! .bss would leave this zero, which points the bitmap INTO the TSS.
    tss%iomap_base = int(c_sizeof(tss), c_int16_t)

    base  = transfer(c_loc(tss), 0_c_int64_t)
    limit = int(c_sizeof(tss), c_int64_t) - 1_c_int64_t

    lo = ior(iand(limit, 65535_c_int64_t), &
             ishft(iand(base, 65535_c_int64_t), 16))
    lo = ior(lo, ishft(iand(ishft(base, -16), 255_c_int64_t), 32))
    lo = ior(lo, ishft(FK_TSS_ACCESS, 40))
    lo = ior(lo, ishft(iand(ishft(limit, -16), 15_c_int64_t), 48))
    lo = ior(lo, ishft(iand(ishft(base, -24), 255_c_int64_t), 56))
    hi = iand(ishft(base, -32), int(z'FFFFFFFF', c_int64_t))

    call gdt_set_tss(lo, hi)
    call tss_flush(FK_GDT_SEL_TSS)
  end subroutine tss_init

  ! 1 if addr lies in the IST1 stack.  The panic handler asks this because the
  ! RSP the CPU pushed into the frame is the SMASHED one -- the address of the
  ! frame itself is the only thing that can say which stack it was built on.
  ! Signed comparison is correct: kernel addresses all have bit 63 set, so they
  ! order the same either way, and a low address fails the upper bound anyway.
  !> The stack the CPU switches to on a ring-3 -> ring-0 transition (roadmap
  !! 4.0).  The scheduler updates it on every switch: RSP0 is per-TASK, not per
  !! CPU, and a stale one delivers the next syscall or interrupt from user mode
  !! onto a stack another thread is already using.
  !!
  !! Split into two halves for the same reason every other field here is: the
  !! TSS is a packed byte layout and the type carries no 64-bit members.
  subroutine tss_set_rsp0(addr) bind(c, name="tss_set_rsp0")
    implicit none
    integer(c_int64_t), intent(in), value :: addr

    tss%rsp0_lo = u32(addr)
    tss%rsp0_hi = u32(ishft(addr, -32))
  end subroutine tss_set_rsp0

  function tss_on_nmi_stack(addr) result(inside) &
       bind(c, name="tss_on_nmi_stack")
    implicit none
    integer(c_int64_t), intent(in), value :: addr
    integer(c_int32_t) :: inside

    if (addr >= nmi_lo .and. addr < nmi_hi) then
       inside = 1_c_int32_t
    else
       inside = 0_c_int32_t
    end if
  end function tss_on_nmi_stack

  function tss_on_df_stack(addr) result(inside) bind(c, name="tss_on_df_stack")
    implicit none
    integer(c_int64_t), intent(in), value :: addr
    integer(c_int32_t) :: inside

    if (addr >= df_lo .and. addr < df_hi) then
       inside = 1_c_int32_t
    else
       inside = 0_c_int32_t
    end if
  end function tss_on_df_stack

end module fk_tss_m
