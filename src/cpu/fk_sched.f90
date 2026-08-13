! SPDX-License-Identifier: GPL-2.0
! Task control blocks and a round-robin scheduler on the PIT tick (roadmap 4.0).
!
! THE SWITCH IS NOT IN THIS FILE and is not a routine at all.  boot/interrupts.S
! ends every IRQ with `movq %rax, %rsp; POP_GPRS; iretq`, where %rax is what
! irq_handler returned.  A task's registers are therefore saved by the PUSH_GPRS
! that every interrupt already performs, onto that task's own stack, and
! "switching" is answering the interrupt with a DIFFERENT frame address.  All
! this module does is remember where each frame is.
!
! WHICH MEANS A NEW TASK NEEDS A FRAME IT NEVER PUSHED.  sched_spawn builds one
! by hand at the top of the task's stack, byte-identical in layout to what the
! stub pushes, and IRETQ starts the task by "returning" to it.  Three fields in
! that frame are load-bearing and all three are silent when wrong:
!
!   RFLAGS = 0x202.  Bit 9 is IF.  A task started with IF clear takes no timer
!   interrupt, so it is never preempted and the round robin stops on it -- the
!   machine looks hung with every other verdict still passing.
!   Bit 1 is architecturally always 1; a zero there is a reserved-bit violation.
!
!   RSP is one quadword BELOW the top of the stack, and that quadword holds the
!   address of fk_cpu_halt.  The SysV ABI says rsp % 16 == 8 at function entry,
!   because a CALL has just pushed a return address -- but nothing called a
!   task, IRETQ jumped to it.  Placing a real return address there fixes the
!   alignment AND catches a task body that returns instead of looping.
!
!   CS/SS are the GDT's kernel selectors.  IRETQ reloads both; a zero SS is a
!   #GP the moment the first interrupt tries to push onto this stack.
!
! STACKS ARE STATIC, not kmalloc'd.  The heap is roadmap 4.0 as well, and a
! scheduler proof that fails when the allocator is wrong tells you neither of
! the two things you wanted to know.
module fk_sched_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t, c_ptr, c_loc, &
                                         c_funloc, c_funptr
  use fk_tss_m, only: tss_set_rsp0
  implicit none
  private
  public :: FK_SCHED_MAX, FK_SCHED_STACK_QWORDS, FK_SCHED_FRAME_QWORDS, &
            FK_SCHED_OK, FK_SCHED_E_FULL, FK_SCHED_E_NOT_READY, &
            fk_task_runs, fk_sched_switches, fk_sched_state, &
            FK_SS_MAGIC, FK_SS_TASKS, FK_SS_CURRENT, FK_SS_SWITCHES, &
            FK_SS_WORDS, FK_SCHED_MAGIC, &
            sched_init, sched_spawn, sched_start, sched_tick, &
            sched_current, sched_tasks, sched_task_rsp

  integer(c_int32_t), parameter :: FK_SCHED_MAX = 4_c_int32_t
  ! 16 KiB a task, the same size linker.ld reserves for the boot stack.
  integer(c_int32_t), parameter :: FK_SCHED_STACK_QWORDS = 2048_c_int32_t
  ! r15..rax, int_no, err_code, rip, cs, rflags, rsp, ss -- the layout
  ! boot/interrupts.S documents, lowest address first.
  integer(c_int32_t), parameter :: FK_SCHED_FRAME_QWORDS = 22_c_int32_t

  integer(c_int32_t), parameter :: FK_SCHED_OK          =  0_c_int32_t
  integer(c_int32_t), parameter :: FK_SCHED_E_FULL      = -1_c_int32_t
  integer(c_int32_t), parameter :: FK_SCHED_E_NOT_READY = -2_c_int32_t

  ! GDT selectors, from fk_gdt_m's decision -- restated here rather than USEd
  ! because a frame is built for a CPU, not for a module.
  integer(c_int64_t), parameter :: SEL_CODE = 8_c_int64_t
  integer(c_int64_t), parameter :: SEL_DATA = 16_c_int64_t
  ! IF (bit 9) and the reserved bit 1 that is always set.
  integer(c_int64_t), parameter :: RFLAGS_IF = int(z'202', c_int64_t)

  integer(c_int32_t), parameter :: ST_FREE     = 0_c_int32_t
  integer(c_int32_t), parameter :: ST_RUNNABLE = 1_c_int32_t

  ! Frame word offsets, 0-based from the frame's lowest address.
  integer(c_int64_t), parameter :: W_RIP    = 17_c_int64_t
  integer(c_int64_t), parameter :: W_CS     = 18_c_int64_t
  integer(c_int64_t), parameter :: W_RFLAGS = 19_c_int64_t
  integer(c_int64_t), parameter :: W_RSP    = 20_c_int64_t
  integer(c_int64_t), parameter :: W_SS     = 21_c_int64_t

  ! bind(c) and TARGET: the addresses of these stacks are what the frames are
  ! built in, and tools/qmp-sentinel.py reads the whole block back.
  integer(c_int64_t), target, bind(c, name="fk_task_stacks") :: &
       fk_task_stacks(FK_SCHED_STACK_QWORDS, FK_SCHED_MAX) = 0_c_int64_t

  ! Incremented by the TASK BODY, not by the scheduler.  A counter the
  ! scheduler bumps proves only that the scheduler chose a task; this proves
  ! the task's own instructions executed.  VOLATILE and exported as a variable
  ! for the reason fk_pit_m's header sets out.
  integer(c_int64_t), volatile, bind(c, name="fk_task_runs") :: &
       fk_task_runs(FK_SCHED_MAX) = 0_c_int64_t

  integer(c_int64_t), volatile, bind(c, name="fk_sched_switches") :: &
       fk_sched_switches = 0_c_int64_t

  integer(c_int32_t), parameter :: FK_SS_WORDS    = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_SS_MAGIC    = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_SS_TASKS    = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_SS_CURRENT  = 3_c_int32_t
  integer(c_int32_t), parameter :: FK_SS_SWITCHES = 4_c_int32_t
  integer(c_int64_t), parameter :: FK_SCHED_MAGIC = int(z'5343484544000001', c_int64_t)

  integer(c_int64_t), volatile, bind(c, name="fk_sched_state") :: &
       fk_sched_state(FK_SS_WORDS) = 0_c_int64_t

  ! The TCBs.  Parallel arrays rather than a derived type: every one of these
  ! is touched from an interrupt handler, and a bind(c) type with mixed field
  ! widths is padded by C struct rules this tree has already been bitten by.
  integer(c_int64_t), volatile, save :: tcb_rsp(FK_SCHED_MAX)   = 0_c_int64_t
  integer(c_int64_t), save :: tcb_top(FK_SCHED_MAX)   = 0_c_int64_t
  integer(c_int32_t), volatile, save :: tcb_state(FK_SCHED_MAX) = ST_FREE

  integer(c_int32_t), volatile, save :: cur     = 1_c_int32_t
  integer(c_int32_t), volatile, save :: n_tasks = 0_c_int32_t
  logical,            volatile, save :: running = .false.

  interface
    subroutine fk_cpu_halt() bind(c, name="fk_cpu_halt")
      implicit none
    end subroutine fk_cpu_halt
  end interface

contains

  ! Address of element (i, t) of the stack block.
  function slot_addr(i, t) result(a)
    implicit none
    integer(c_int32_t), intent(in) :: i, t
    integer(c_int64_t) :: a

    a = transfer(c_loc(fk_task_stacks(i, t)), 0_c_int64_t)
  end function slot_addr

  ! Store V at byte address A, which must lie inside task T's stack.  Written
  ! through the array rather than through a raw pointer so an index that walks
  ! out of the stack is a subscript error and not a store into the next task's.
  subroutine poke(t, a, v)
    implicit none
    integer(c_int32_t), intent(in) :: t
    integer(c_int64_t), intent(in) :: a, v
    integer(c_int64_t) :: i

    i = (a - slot_addr(1_c_int32_t, t)) / 8_c_int64_t + 1_c_int64_t
    if (i < 1_c_int64_t .or. i > int(FK_SCHED_STACK_QWORDS, c_int64_t)) return
    fk_task_stacks(int(i, c_int32_t), t) = v
  end subroutine poke

  !> Reset the scheduler and adopt the CALLER as task 1.
  !!
  !! The boot thread already has a stack, a RIP and a live register set; it
  !! becomes a task by being written down, not by being created.  Its saved RSP
  !! stays 0 until the first interrupt switches away from it and the router
  !! hands over the frame it pushed.
  function sched_init() result(status) bind(c, name="sched_init")
    implicit none
    integer(c_int32_t) :: status
    integer(c_int32_t) :: i

    running = .false.
    do i = 1_c_int32_t, FK_SCHED_MAX
       tcb_state(i) = ST_FREE
       tcb_rsp(i)   = 0_c_int64_t
       tcb_top(i)   = 0_c_int64_t
       fk_task_runs(i) = 0_c_int64_t
    end do
    fk_sched_switches = 0_c_int64_t

    tcb_state(1) = ST_RUNNABLE
    ! Task 1 runs on the boot stack, which the TSS already describes; leaving
    ! tcb_top(1) at 0 makes sched_tick skip the rsp0 update for it rather than
    ! program a zero.
    cur     = 1_c_int32_t
    n_tasks = 1_c_int32_t

    fk_sched_state(FK_SS_MAGIC)    = FK_SCHED_MAGIC
    fk_sched_state(FK_SS_TASKS)    = 1_c_int64_t
    fk_sched_state(FK_SS_CURRENT)  = 1_c_int64_t
    fk_sched_state(FK_SS_SWITCHES) = 0_c_int64_t
    status = FK_SCHED_OK
  end function sched_init

  !> Create a kernel thread that starts at ENTRY.  Returns its task id, or a
  !! negative status.  ENTRY is an address; the thread must never return, and
  !! if it does it lands in fk_cpu_halt rather than in whatever follows.
  function sched_spawn(entry) result(id) bind(c, name="sched_spawn")
    implicit none
    integer(c_int64_t), intent(in), value :: entry
    integer(c_int32_t) :: id
    integer(c_int32_t) :: t, i
    integer(c_int64_t) :: base, top, ret, frame

    if (n_tasks == 0_c_int32_t) then
       id = FK_SCHED_E_NOT_READY
       return
    end if
    if (n_tasks >= FK_SCHED_MAX) then
       id = FK_SCHED_E_FULL
       return
    end if

    t    = n_tasks + 1_c_int32_t
    base = slot_addr(1_c_int32_t, t)
    ! Rounded DOWN to 16: gfortran's alignment for this array is a property of
    ! the compiler, and the ABI's requirement is not.
    top   = iand(base + int(FK_SCHED_STACK_QWORDS, c_int64_t) * 8_c_int64_t, &
                 not(15_c_int64_t))
    ret   = top - 8_c_int64_t
    frame = ret - int(FK_SCHED_FRAME_QWORDS, c_int64_t) * 8_c_int64_t

    call poke(t, ret, transfer(c_funloc(fk_cpu_halt), 0_c_int64_t))
    do i = 0_c_int32_t, FK_SCHED_FRAME_QWORDS - 1_c_int32_t
       call poke(t, frame + int(i, c_int64_t) * 8_c_int64_t, 0_c_int64_t)
    end do
    call poke(t, frame + W_RIP    * 8_c_int64_t, entry)
    call poke(t, frame + W_CS     * 8_c_int64_t, SEL_CODE)
    call poke(t, frame + W_RFLAGS * 8_c_int64_t, RFLAGS_IF)
    call poke(t, frame + W_RSP    * 8_c_int64_t, ret)
    call poke(t, frame + W_SS     * 8_c_int64_t, SEL_DATA)

    tcb_rsp(t)   = frame
    tcb_top(t)   = ret
    tcb_state(t) = ST_RUNNABLE
    n_tasks      = t
    fk_sched_state(FK_SS_TASKS) = int(t, c_int64_t)
    id = t
  end function sched_spawn

  !> Arm preemption.  Separate from sched_spawn so every task exists before any
  !! switch can happen: a tick between two spawns would otherwise schedule a
  !! task whose frame is half built.
  subroutine sched_start() bind(c, name="sched_start")
    implicit none

    if (n_tasks >= 2_c_int32_t) running = .true.
  end subroutine sched_start

  !> Called from the IRQ router with the frame the CPU is parked on; returns
  !! the frame to resume from.  Returning the argument means "no switch", which
  !! is what makes this safe to call before anything is set up.
  function sched_tick(rsp) result(next) bind(c, name="sched_tick")
    implicit none
    integer(c_int64_t), intent(in), value :: rsp
    integer(c_int64_t) :: next
    integer(c_int32_t) :: i, nxt

    next = rsp
    if (.not. running) return
    if (n_tasks < 2_c_int32_t) return

    ! The outgoing task's registers are ALREADY on its stack -- PUSH_GPRS put
    ! them there before this handler was called -- so recording where is the
    ! whole of "saving" a context.
    tcb_rsp(cur) = rsp

    nxt = cur
    do i = 1_c_int32_t, n_tasks
       nxt = nxt + 1_c_int32_t
       if (nxt > n_tasks) nxt = 1_c_int32_t
       if (tcb_state(nxt) == ST_RUNNABLE) exit
    end do
    if (nxt == cur) return

    cur = nxt
    ! The stack a ring-3 -> ring-0 transition would land on, kept correct per
    ! task.  Nothing runs in ring 3 yet, so this is the mechanism being put in
    ! place rather than a mechanism being used; task 1 keeps the boot stack the
    ! TSS was initialised with.
    if (tcb_top(cur) /= 0_c_int64_t) call tss_set_rsp0(tcb_top(cur))

    fk_sched_switches = fk_sched_switches + 1_c_int64_t
    fk_sched_state(FK_SS_CURRENT)  = int(cur, c_int64_t)
    fk_sched_state(FK_SS_SWITCHES) = fk_sched_switches
    next = tcb_rsp(cur)
  end function sched_tick

  function sched_current() result(v) bind(c, name="sched_current")
    implicit none
    integer(c_int32_t) :: v
    v = cur
  end function sched_current

  function sched_tasks() result(v) bind(c, name="sched_tasks")
    implicit none
    integer(c_int32_t) :: v
    v = n_tasks
  end function sched_tasks

  function sched_task_rsp(id) result(v) bind(c, name="sched_task_rsp")
    implicit none
    integer(c_int32_t), intent(in), value :: id
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (id >= 1_c_int32_t .and. id <= FK_SCHED_MAX) v = tcb_rsp(id)
  end function sched_task_rsp

end module fk_sched_m
