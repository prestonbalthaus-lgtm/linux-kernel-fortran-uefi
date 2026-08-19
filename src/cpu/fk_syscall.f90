! SPDX-License-Identifier: GPL-2.0
! The syscall ABI trap: SYSCALL/SYSRET enable, the four MSRs, and the Fortran
! router boot/interrupts.S branches to.  Roadmap 6.3.
!
! WHAT THIS BOX IS, precisely: a Ring 3 instruction that lands in Fortran.  It
! does not implement any system call -- sys_read, sys_write and sys_exit are
! scaffolds that record what they were asked and return -ENOSYS or a byte count
! -- and it does not drop to Ring 3, which is roadmap 7.1.  What it establishes
! is the PATH, and the path is the part that is hard to get right once.
!
! Citations name `common.c` for vendor/linux-7.1.8/arch/x86/kernel/cpu/common.c,
! `entry_64.S` for arch/x86/entry/entry_64.S, `segment.h` for
! arch/x86/include/asm/segment.h and `msr-index.h` for
! arch/x86/include/asm/msr-index.h, all under vendor/linux-7.1.8/.
!
! THE GDT CONTRACT IS CHECKED AND NOT ASSUMED.  SYSCALL loads CS from
! STAR[47:32] and SS from STAR[47:32] + 8 -- the +8 is hardwired in the
! instruction, not read from the MSR -- so the kernel code and data descriptors
! must be ADJACENT, code first.  segment.h:173-189 is the comment that says so,
! and it is why Linux's GDT puts its user data selector BETWEEN its two user
! code selectors.  src/cpu/fk_gdt.f90 happens to satisfy it (code 0x08, data
! 0x10); syscall_init refuses rather than trusting that it still does.
!
! THE SYSRET HALF OF STAR IS DELIBERATELY ZERO.  SYSRET takes CS from
! STAR[63:48] + 16 and SS from STAR[63:48] + 8, both with RPL forced to 3
! (segment.h:177-186), so a non-zero value here would name Ring 3 descriptors
! that this GDT does not contain -- a register that reads as configured and
! faults the first time it is used.  Roadmap 7.1 adds those three descriptors
! and fills this in; until then the honest value is zero, and the boot gate
! asserts that it IS zero rather than that it looks plausible.
module fk_syscall_m
  use, intrinsic :: iso_c_binding, only: c_int16_t, c_int32_t, &
                                         c_int64_t, c_ptr, c_loc
  use fk_gdt_m, only: FK_GDT_SEL_CODE, FK_GDT_SEL_DATA
  use fk_idt_m, only: fk_regs_t
  implicit none
  private

  public :: FK_SYS_OK, FK_SYS_E_GDT, FK_SYS_E_ENTRY, FK_SYS_E_STAR, &
            FK_SYS_E_LSTAR, FK_SYS_E_FMASK, FK_SYS_E_SCE, FK_SYS_E_STACK
  public :: FK_MSR_EFER, FK_MSR_STAR, FK_MSR_LSTAR, FK_MSR_CSTAR, FK_MSR_FMASK
  public :: FK_EFER_SCE_BIT, FK_SYSCALL_FMASK
  public :: FK_SYS_NR_READ, FK_SYS_NR_WRITE, FK_SYS_NR_EXIT
  public :: FK_E_NOSYS, FK_E_BADF, FK_E_FAULT
  public :: syscall_star_value, syscall_stack_top, syscall_init
  public :: syscall_star, syscall_lstar, syscall_fmask, syscall_efer
  public :: fk_syscall_handler, syscall_count, syscall_last_nr, &
            syscall_last_ret, syscall_entry_rflags, syscall_masked_flags
  public :: syscall_exit_called, syscall_exit_code, syscall_written
  public :: sys_read, sys_write, sys_exit
  public :: fk_syscall_rsp0, fk_syscall_user_rsp, fk_syscall_entry_rflags

  integer(c_int32_t), parameter :: FK_SYS_OK = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_SYS_E_GDT = -1_c_int32_t
  integer(c_int32_t), parameter :: FK_SYS_E_ENTRY = -2_c_int32_t
  integer(c_int32_t), parameter :: FK_SYS_E_STAR = -3_c_int32_t
  integer(c_int32_t), parameter :: FK_SYS_E_LSTAR = -4_c_int32_t
  integer(c_int32_t), parameter :: FK_SYS_E_FMASK = -5_c_int32_t
  integer(c_int32_t), parameter :: FK_SYS_E_SCE = -6_c_int32_t
  integer(c_int32_t), parameter :: FK_SYS_E_STACK = -7_c_int32_t

  ! msr-index.h:10-14.
  integer(c_int32_t), parameter :: FK_MSR_EFER = int(z'C0000080', c_int32_t)
  integer(c_int32_t), parameter :: FK_MSR_STAR = int(z'C0000081', c_int32_t)
  integer(c_int32_t), parameter :: FK_MSR_LSTAR = int(z'C0000082', c_int32_t)
  integer(c_int32_t), parameter :: FK_MSR_CSTAR = int(z'C0000083', c_int32_t)
  integer(c_int32_t), parameter :: FK_MSR_FMASK = int(z'C0000084', c_int32_t)

  ! msr-index.h:21,31.  With SCE clear the instruction is #UD, which is how
  ! head_64.S:384-391 puts it and how KVM's emulator enforces it
  ! (arch/x86/kvm/emulate.c:2376-2378).
  integer(c_int32_t), parameter :: FK_EFER_SCE_BIT = 0_c_int32_t

  ! common.c:2291-2300, every flag it clears, and the set is taken WHOLE rather
  ! than trimmed to the ones this kernel can currently notice:
  !
  !   CF PF AF ZF SF OF ID   the kernel enters with deterministic arithmetic
  !                          flags rather than whatever the caller left
  !   TF                     no single-stepping into kernel text; a caller with
  !                          TF set cannot make the first kernel instruction
  !                          raise #DB
  !   IF                     THE LOAD-BEARING ONE.  SYSCALL does not switch the
  !                          stack (entry_64.S:65-66), so RSP is still the
  !                          caller's when boot/interrupts.S starts work.  An
  !                          interrupt in that window would push its frame onto
  !                          a pointer the caller chose.
  !   DF                     string operations run forward without a CLD
  !                          (entry_64.S:64), and Linux additionally DEPENDS on
  !                          it for NMI nesting detection (entry_64.S:1281-1287)
  !   IOPL                   the kernel runs at IOPL 0 whatever the caller's was
  !   NT                     with NT set an IRET in the kernel attempts a TASK
  !                          SWITCH instead of an interrupt return
  !   RF                     a caller cannot suppress the next instruction
  !                          breakpoint in kernel text
  !   AC                     SMAP stays armed
  integer(c_int64_t), parameter :: FK_SYSCALL_FMASK = &
       int(z'00257FD5', c_int64_t)

  ! The three the milestone scaffolds, at their Linux x86-64 numbers.
  integer(c_int64_t), parameter :: FK_SYS_NR_READ = 0_c_int64_t
  integer(c_int64_t), parameter :: FK_SYS_NR_WRITE = 1_c_int64_t
  integer(c_int64_t), parameter :: FK_SYS_NR_EXIT = 60_c_int64_t

  integer(c_int64_t), parameter :: FK_E_NOSYS = -38_c_int64_t
  integer(c_int64_t), parameter :: FK_E_BADF = -9_c_int64_t
  integer(c_int64_t), parameter :: FK_E_FAULT = -14_c_int64_t

  ! 4096 quadwords is 32 KiB, the same order as the #DF and NMI stacks in
  ! src/cpu/fk_tss.f90 and .bss, so it costs the image no file bytes.
  integer(c_int32_t), parameter :: FK_SYSCALL_STACK_QWORDS = 4096_c_int32_t

  ! Published under their C names because boot/interrupts.S loads them: Fortran
  ! owns the storage and the assembly owns the instruction, which is the split
  ! the rest of this tree uses for the GDT, the IDT and the TSS.
  integer(c_int64_t), save, target, bind(c, name="fk_syscall_stack") :: &
       syscall_stack(FK_SYSCALL_STACK_QWORDS)
  integer(c_int64_t), volatile, save, bind(c, name="fk_syscall_rsp0") :: &
       fk_syscall_rsp0 = 0_c_int64_t
  integer(c_int64_t), volatile, save, bind(c, name="fk_syscall_user_rsp") :: &
       fk_syscall_user_rsp = 0_c_int64_t
  ! Written by the stub before its CLD, which is the only instant at which the
  ! post-FMASK RFLAGS still says what FMASK did.
  integer(c_int64_t), volatile, save, &
       bind(c, name="fk_syscall_entry_rflags") :: &
       fk_syscall_entry_rflags = 0_c_int64_t

  integer(c_int64_t), volatile, save :: calls = 0_c_int64_t
  integer(c_int64_t), save :: last_nr = -1_c_int64_t
  integer(c_int64_t), save :: last_ret = 0_c_int64_t
  integer(c_int64_t), save :: written = 0_c_int64_t
  integer(c_int64_t), save :: exit_code = 0_c_int64_t
  integer(c_int32_t), save :: exit_called = 0_c_int32_t

  interface
    function fk_rdmsr(msr) result(v) bind(c, name="fk_rdmsr")
      import :: c_int32_t, c_int64_t
      implicit none
      integer(c_int32_t), intent(in), value :: msr
      integer(c_int64_t)                    :: v
    end function fk_rdmsr

    subroutine fk_wrmsr(msr, value) bind(c, name="fk_wrmsr")
      import :: c_int32_t, c_int64_t
      implicit none
      integer(c_int32_t), intent(in), value :: msr
      integer(c_int64_t), intent(in), value :: value
    end subroutine fk_wrmsr

    function fk_syscall_entry_addr() result(v) &
         bind(c, name="fk_syscall_entry_addr")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: v
    end function fk_syscall_entry_addr
  end interface

contains

  ! STAR[47:32] = kernel CS, STAR[31:0] = 0, STAR[63:48] = 0.
  !
  ! common.c:2306 writes `wrmsr(MSR_STAR, 0, (__USER32_CS << 16) | __KERNEL_CS)`
  ! -- low half zero because it is the 32-bit legacy SYSCALL target and long
  ! mode never uses it, high half packing the two selector bases.  The sysret
  ! base is zero here for the reason this module's header gives.
  function syscall_star_value() result(v) bind(c, name="syscall_star_value")
    implicit none
    integer(c_int64_t) :: v

    v = shiftl(iand(int(FK_GDT_SEL_CODE, c_int64_t), &
                    int(z'FFFF', c_int64_t)), 32)
  end function syscall_star_value

  ! The stack SYSCALL runs on, top-down: the last quadword's address plus
  ! eight, which is one past the end and where a full-descending stack starts.
  !
  ! ROUNDED DOWN TO 16, NOT ASSERTED TO BE 16-ALIGNED.  The frame the stub
  ! pushes is 22 quadwords -- 176 bytes, a multiple of 16 -- so RSP is aligned
  ! at the call if and only if it was aligned here, which is what the SysV ABI
  ! requires AT a call and what gfortran's own generated code assumes.  Nothing
  ! guarantees the alignment of a .bss array beyond its element type, so this
  ! rounds instead of refusing: giving up at most eight bytes of a 32 KiB stack
  ! is not a trade worth failing a boot over.
  function syscall_stack_top() result(v) bind(c, name="syscall_stack_top")
    implicit none
    integer(c_int64_t) :: v
    type(c_ptr) :: p

    p = c_loc(syscall_stack(FK_SYSCALL_STACK_QWORDS))
    v = transfer(p, 0_c_int64_t) + 8_c_int64_t
    v = iand(v, not(15_c_int64_t))
  end function syscall_stack_top

  ! PROGRAMS FOUR REGISTERS AND THEN READS ALL FOUR BACK.  boot/mmu.S's PAT
  ! routine states the rule this follows: a wrmsr that never executed is
  ! otherwise indistinguishable from one that did, so the only evidence that
  ! the CPU accepted a value is the CPU handing it back.
  function syscall_init() result(status) bind(c, name="syscall_init")
    implicit none
    integer(c_int32_t) :: status
    integer(c_int64_t) :: entry, star, efer, top

    ! segment.h:173-189.  The +8 is the instruction's, not the MSR's, so a GDT
    ! whose data selector is not eight bytes above its code selector cannot be
    ! described by any value of STAR.  Refused rather than programmed.
    status = FK_SYS_E_GDT
    if (int(FK_GDT_SEL_DATA, c_int32_t) /= &
        int(FK_GDT_SEL_CODE, c_int32_t) + 8_c_int32_t) return
    ! An RPL in either selector would put a non-zero CPL request in a value the
    ! instruction forces to zero, which is a lie in a register rather than a
    ! fault.
    if (iand(int(FK_GDT_SEL_CODE, c_int32_t), 3_c_int32_t) /= 0_c_int32_t) &
         return

    status = FK_SYS_E_ENTRY
    entry = fk_syscall_entry_addr()
    if (entry == 0_c_int64_t) return
    ! LSTAR IS LOADED INTO RIP WITHOUT A CANONICALITY CHECK AT WRMSR TIME on
    ! some parts and with #GP on others; either way a non-canonical entry point
    ! is a fault at the first syscall rather than at the write.  This kernel is
    ! in the higher half, so bit 63 must be set.
    if (entry >= 0_c_int64_t) return

    status = FK_SYS_E_STACK
    top = syscall_stack_top()
    if (top == 0_c_int64_t) return
    if (iand(top, 15_c_int64_t) /= 0_c_int64_t) return
    fk_syscall_rsp0 = top
    fk_syscall_user_rsp = 0_c_int64_t
    fk_syscall_entry_rflags = 0_c_int64_t

    star = syscall_star_value()
    call fk_wrmsr(FK_MSR_STAR, star)
    call fk_wrmsr(FK_MSR_LSTAR, entry)
    call fk_wrmsr(FK_MSR_FMASK, FK_SYSCALL_FMASK)

    ! EFER LAST, and the order is the point: with SCE set before LSTAR holds an
    ! address, a SYSCALL arriving in the gap jumps to whatever the register was
    ! left at.  Nothing here issues one, but the ordering costs nothing and the
    ! opposite ordering is a fault that would be very hard to read.
    efer = fk_rdmsr(FK_MSR_EFER)
    call fk_wrmsr(FK_MSR_EFER, ibset(efer, FK_EFER_SCE_BIT))

    status = FK_SYS_E_STAR
    if (fk_rdmsr(FK_MSR_STAR) /= star) return
    status = FK_SYS_E_LSTAR
    if (fk_rdmsr(FK_MSR_LSTAR) /= entry) return
    status = FK_SYS_E_FMASK
    if (fk_rdmsr(FK_MSR_FMASK) /= FK_SYSCALL_FMASK) return
    status = FK_SYS_E_SCE
    if (.not. btest(fk_rdmsr(FK_MSR_EFER), FK_EFER_SCE_BIT)) return

    status = FK_SYS_OK
  end function syscall_init

  ! ---- the router -----------------------------------------------------------

  ! THE FRAME IS READ, NOT THE REGISTERS, and that is what makes the R10
  ! problem disappear instead of needing a shuffle.  The Linux syscall ABI puts
  ! argument 4 in R10 rather than RCX because SYSCALL destroys RCX with the
  ! return address; a router that took its arguments in registers would have to
  ! know that and move them.  This one reads slots out of the fk_regs_t that
  ! boot/interrupts.S pushed, so R10 is simply the field called r10.
  !
  ! THE RESULT GOES BACK IN THE FRAME'S RAX, not in this function's result:
  ! POP_GPRS is what puts it in the register, so writing the field IS returning
  ! the value.  A subroutine, therefore, and not a function.
  subroutine fk_syscall_handler(regs) bind(c, name="fk_syscall_handler")
    implicit none
    type(fk_regs_t), intent(inout) :: regs
    integer(c_int64_t) :: nr, ret

    calls = calls + 1_c_int64_t
    nr = regs%rax
    last_nr = nr

    if (nr == FK_SYS_NR_READ) then
       ret = sys_read(regs%rdi, regs%rsi, regs%rdx)
    else if (nr == FK_SYS_NR_WRITE) then
       ret = sys_write(regs%rdi, regs%rsi, regs%rdx)
    else if (nr == FK_SYS_NR_EXIT) then
       ret = sys_exit(regs%rdi)
    else
       ! -ENOSYS AND NOT A PANIC.  An unknown number is a caller's mistake and
       ! Linux answers it this way; halting the kernel on one would make every
       ! future libc probe fatal.
       ret = FK_E_NOSYS
    end if

    last_ret = ret
    regs%rax = ret
  end subroutine fk_syscall_handler

  ! ---- the three scaffolds --------------------------------------------------
  ! Each one RECORDS what it was asked and returns a value with the right
  ! shape.  None of them touches user memory, because there is no user memory
  ! until roadmap 7.1 and a scaffold that dereferenced a caller's pointer would
  ! be the first thing to fault when there is.

  function sys_read(fd, buf, count) result(ret) bind(c, name="sys_read")
    implicit none
    integer(c_int64_t), intent(in), value :: fd, buf, count
    integer(c_int64_t) :: ret

    ret = FK_E_BADF
    if (fd < 0_c_int64_t) return
    ret = FK_E_FAULT
    if (buf == 0_c_int64_t) return
    ! Nothing is readable yet: roadmap 6.4 loads a binary and 7.3 gives it a
    ! keyboard.  0 is END OF FILE, which is the honest answer for a descriptor
    ! with nothing behind it, and is what a caller can actually cope with.
    ret = 0_c_int64_t
    if (count == 0_c_int64_t) ret = 0_c_int64_t
  end function sys_read

  function sys_write(fd, buf, count) result(ret) bind(c, name="sys_write")
    implicit none
    integer(c_int64_t), intent(in), value :: fd, buf, count
    integer(c_int64_t) :: ret

    ret = FK_E_BADF
    if (fd < 0_c_int64_t) return
    ret = FK_E_FAULT
    if (buf == 0_c_int64_t) return
    if (count < 0_c_int64_t) then
       ret = FK_E_FAULT
       return
    end if
    written = written + count
    ret = count
  end function sys_write

  function sys_exit(code) result(ret) bind(c, name="sys_exit")
    implicit none
    integer(c_int64_t), intent(in), value :: code
    integer(c_int64_t) :: ret

    exit_called = exit_called + 1_c_int32_t
    exit_code = code
    ! IT RETURNS, and at 6.3 it must.  There is no task to destroy and no
    ! scheduler entry to remove; the caller is the kernel's own boot thread and
    ! taking it down would end the boot in the middle of a milestone that has
    ! not finished proving itself.  Roadmap 7.1 is where this stops returning.
    ret = 0_c_int64_t
  end function sys_exit

  ! ---- accessors ------------------------------------------------------------

  function syscall_star() result(v) bind(c, name="syscall_star")
    implicit none
    integer(c_int64_t) :: v

    v = fk_rdmsr(FK_MSR_STAR)
  end function syscall_star

  function syscall_lstar() result(v) bind(c, name="syscall_lstar")
    implicit none
    integer(c_int64_t) :: v

    v = fk_rdmsr(FK_MSR_LSTAR)
  end function syscall_lstar

  function syscall_fmask() result(v) bind(c, name="syscall_fmask")
    implicit none
    integer(c_int64_t) :: v

    v = fk_rdmsr(FK_MSR_FMASK)
  end function syscall_fmask

  function syscall_efer() result(v) bind(c, name="syscall_efer")
    implicit none
    integer(c_int64_t) :: v

    v = fk_rdmsr(FK_MSR_EFER)
  end function syscall_efer

  function syscall_count() result(v) bind(c, name="syscall_count")
    implicit none
    integer(c_int64_t) :: v

    v = calls
  end function syscall_count

  function syscall_last_nr() result(v) bind(c, name="syscall_last_nr")
    implicit none
    integer(c_int64_t) :: v

    v = last_nr
  end function syscall_last_nr

  function syscall_last_ret() result(v) bind(c, name="syscall_last_ret")
    implicit none
    integer(c_int64_t) :: v

    v = last_ret
  end function syscall_last_ret

  function syscall_entry_rflags() result(v) &
       bind(c, name="syscall_entry_rflags")
    implicit none
    integer(c_int64_t) :: v

    v = fk_syscall_entry_rflags
  end function syscall_entry_rflags

  ! WHICH MASKED FLAGS SURVIVED, which is the whole FMASK assertion in one
  ! number and must be ZERO.  Every bit FK_SYSCALL_FMASK names was supposed to
  ! be cleared by the instruction itself; any that is still set is a bit the
  ! CPU did not clear, which means it was not in the value that was written.
  function syscall_masked_flags() result(v) &
       bind(c, name="syscall_masked_flags")
    implicit none
    integer(c_int64_t) :: v

    v = iand(fk_syscall_entry_rflags, FK_SYSCALL_FMASK)
  end function syscall_masked_flags

  function syscall_written() result(v) bind(c, name="syscall_written")
    implicit none
    integer(c_int64_t) :: v

    v = written
  end function syscall_written

  function syscall_exit_called() result(v) &
       bind(c, name="syscall_exit_called")
    implicit none
    integer(c_int32_t) :: v

    v = exit_called
  end function syscall_exit_called

  function syscall_exit_code() result(v) bind(c, name="syscall_exit_code")
    implicit none
    integer(c_int64_t) :: v

    v = exit_code
  end function syscall_exit_code

end module fk_syscall_m
