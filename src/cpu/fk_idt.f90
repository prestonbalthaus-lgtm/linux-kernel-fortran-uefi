! SPDX-License-Identifier: GPL-2.0
! IDT, the kernel panic handler (roadmap 3.2) and the IRQ router (roadmap 3.2b).
!
! Two kinds of vector, two handlers, and the difference is the whole point.  The
! 32 CPU exception vectors reach isr_handler, which dumps the captured machine
! state over COM1 and parks the CPU -- an exception here is a bug and resuming
! from one is not something this kernel can do.  The 16 legacy IRQ vectors reach
! irq_handler, which services the line, acknowledges the 8259 and RETURNS, and
! boot/interrupts.S then executes the IRETQ that puts the interrupted code back
! where it was.
module fk_idt_m
  use, intrinsic :: iso_c_binding, only: c_int8_t, c_int16_t, c_int32_t, &
                                         c_int64_t, c_char, c_null_char, c_loc
  use fk_gdt_m,    only: FK_GDT_SEL_CODE
  use fk_tss_m,    only: FK_TSS_IST_DF, FK_TSS_IST_NMI, tss_on_df_stack, &
                         tss_on_nmi_stack
  use fk_pic_m,    only: FK_PIC1_VECTOR, FK_PIC_LINES, FK_PIC_CASCADE, &
                         pic_eoi, pic_isr
  use fk_pit_m,    only: FK_PIT_IRQ, pit_tick
  use fk_serial_m, only: serial_print_byte, serial_print_string, &
                         serial_print_hex
  implicit none
  private
  public :: idt_init, idt_reload, isr_handler, irq_handler, fk_irq_spurious, &
            idt_set_panic_colors, idt_set_eoi_lapic, fk_lapic_spurious, &
            FK_VECTOR_SPURIOUS, FK_VECTOR_MSI, FK_MSI_LINE, fk_msi_count

  ! What boot/interrupts.S leaves on the stack, lowest address first.  Every
  ! field is a quadword, so the type needs no padding and the assembly needs no
  ! knowledge of Fortran.
  type, bind(c) :: fk_regs_t
    integer(c_int64_t) :: r15, r14, r13, r12, r11, r10, r9, r8
    integer(c_int64_t) :: rdi, rsi, rbp, rbx, rdx, rcx, rax
    integer(c_int64_t) :: int_no, err_code
    integer(c_int64_t) :: rip, cs, rflags, rsp, ss
  end type fk_regs_t

  ! 64-bit gate descriptor.  C struct rules lay these fields out at 0, 2, 4, 5,
  ! 6, 8 and 12 with no padding, which is exactly the hardware format.
  type, bind(c) :: fk_idt_entry_t
    integer(c_int16_t) :: off_lo
    integer(c_int16_t) :: sel
    integer(c_int8_t)  :: ist
    integer(c_int8_t)  :: attr
    integer(c_int16_t) :: off_mid
    integer(c_int32_t) :: off_hi
    integer(c_int32_t) :: reserved
  end type fk_idt_entry_t

  integer(c_int32_t), parameter :: FK_IDT_ENTRIES = 256_c_int32_t
  integer(c_int32_t), parameter :: FK_IDT_VECTORS = 32_c_int32_t

  ! 0x8E = present, DPL 0, type 0xE (64-bit interrupt gate).  An interrupt gate
  ! rather than a trap gate: entry clears IF, so a fault cannot be re-entered by
  ! a device interrupt while the panic handler is talking to the UART.
  integer(c_int8_t), parameter :: FK_IDT_ATTR_INTR = int(z'8E', c_int8_t)

  ! IST 0 keeps the faulting stack, which is right for every vector but one.
  integer(c_int8_t), parameter :: FK_IDT_IST_NONE = 0_c_int8_t

  ! #DF is the fault whose cause may be that the stack is unusable, so it is
  ! the one exception that must not be delivered on it.  fk_tss_m owns which
  ! IST slot that is; this is only the vector that asks for it.
  integer(c_int32_t), parameter :: FK_VEC_DF  = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_VEC_NMI = 2_c_int32_t

  ! The two lines an 8259 raises when a request withdraws before the CPU
  ! acknowledges it: the master's 7, and the slave's 7 -- which is line 15.
  integer(c_int32_t), parameter :: FK_IRQ_SPURIOUS_MASTER = 7_c_int32_t
  integer(c_int32_t), parameter :: FK_IRQ_SPURIOUS_SLAVE  = 15_c_int32_t

  ! Counted rather than ignored.  A spurious interrupt is normal and harmless;
  ! a spurious interrupt this handler never noticed is an EOI sent for a line
  ! that was never in service, which cancels the NEXT real one.
  !
  ! VOLATILE and exported as a variable for the reason fk_pit_m's header sets
  ! out: an interrupt handler writes it, and a cross-module accessor function
  ! that returned it would be treated as side-effect-free by the reader.
  integer(c_int64_t), volatile, bind(c, name="fk_irq_spurious") :: &
       fk_irq_spurious = 0_c_int64_t

  ! roadmap 3.3.  Counted by boot/interrupts.S's fk_spurious_stub, which is
  ! two instructions and never enters Fortran, so this is the only place the
  ! count is visible from.
  integer(c_int64_t), volatile, bind(c, name="fk_lapic_spurious") :: &
       fk_lapic_spurious = 0_c_int64_t

  ! Must equal SVR bits 7:0 as lapic_bringup programs them in
  ! src/boot/fk_kmain.f90.  A gate installed at any other vector leaves the
  ! real spurious vector pointing at a cleared descriptor, and the CPU's answer
  ! to a not-present gate is a #GP raised from inside interrupt delivery.
  integer(c_int32_t), parameter :: FK_VECTOR_SPURIOUS = 255_c_int32_t

  ! Roadmap 5.1.  The first vector this kernel owns that is not a legacy line:
  ! 0x30 sits above the 8259's 0x20..0x2F and below the spurious 0xFF.  The
  ! stub pushes FK_MSI_LINE, one past the last real line, which is how
  ! irq_handler tells a message from a wire.
  integer(c_int32_t), parameter :: FK_VECTOR_MSI = int(z'30', c_int32_t)
  integer(c_int32_t), parameter :: FK_MSI_LINE = FK_PIC_LINES

  integer(c_int64_t), volatile, bind(c, name="fk_msi_count") :: &
       fk_msi_count = 0_c_int64_t

  ! Which chip retires an interrupt.  0 is the 8259 pair and is correct right
  ! up until the IOAPIC is routed; anything else is the LAPIC's mapped base.
  ! It is PASSED IN rather than named here because fk_vmm_m holds the one
  ! definition of that address and is compiled after this module.
  integer(c_int64_t), save :: eoi_lapic = 0_c_int64_t

  ! The console is reached through bind(c) names rather than USE association,
  ! deliberately.  A panic handler that USEd fk_console_m would drag the whole
  ! video stack -- renderer, font, memmove -- into this module's compile-time
  ! dependency graph and force Makefile.boot to build it before the IDT, for a
  ! call that must work whether or not there is a screen.  Every one of these
  ! is a no-op until console_init has run.
  interface
    subroutine console_write(s, max_chars) bind(c, name="console_write")
      import :: c_char, c_int32_t
      implicit none
      character(kind=c_char), intent(in)        :: s(*)
      integer(c_int32_t),     intent(in), value :: max_chars
    end subroutine console_write

    subroutine console_print_hex(v, digits) bind(c, name="console_print_hex")
      import :: c_int64_t, c_int32_t
      implicit none
      integer(c_int64_t), intent(in), value :: v
      integer(c_int32_t), intent(in), value :: digits
    end subroutine console_print_hex

    subroutine console_set_color(fg, bg) bind(c, name="console_set_color")
      import :: c_int32_t
      implicit none
      integer(c_int32_t), intent(in), value :: fg, bg
    end subroutine console_set_color

    function console_ready() result(v) bind(c, name="console_ready")
      import :: c_int32_t
      implicit none
      integer(c_int32_t) :: v
    end function console_ready

    ! roadmap 4.0, reached by name for the same reason the console is: the
    ! router must not have a compile-time dependency on the scheduler, or the
    ! scheduler could never call anything the router uses.
    function sched_tick(rsp) result(next) bind(c, name="sched_tick")
      import :: c_int64_t
      implicit none
      integer(c_int64_t), intent(in), value :: rsp
      integer(c_int64_t) :: next
    end function sched_tick
  end interface

  ! Bound on a panic string.  console_write stops at the NUL; this only caps how
  ! far it walks if a caller ever loses one.
  integer(c_int32_t), parameter :: FK_PANIC_MAX = 512_c_int32_t

  ! Packed pixel words, so this module needs nothing from the framebuffer's
  ! channel masks.  Set by kernel_main once the loader's layout is known; the
  ! defaults are the BGRX values x86 firmware reports, so a panic before that
  ! handoff still comes out white on red rather than black on black.
  integer(c_int32_t), save :: panic_fg = int(z'00FFFFFF', c_int32_t)
  integer(c_int32_t), save :: panic_bg = int(z'00AA0000', c_int32_t)

  type(fk_idt_entry_t), target, save :: idt(0:FK_IDT_ENTRIES - 1)

  ! LIDT takes the same packed 16-bit limit + 64-bit base LGDT does; see the
  ! same declaration in fk_gdt_m for why it cannot be a bind(c) derived type.
  integer(c_int16_t), save :: idtr(5)

  character(kind=c_char, len=*), parameter :: FK_CRLF = achar(13) // achar(10)

  character(kind=c_char, len=*), parameter :: FK_PANIC_HDR = &
       FK_CRLF // "*** FORTRAN KERNEL PANIC ***" // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_EXC    = "EXCEPTION 0x" // c_null_char
  ! The error code rides the headline, not the register dump: a boot gate greps
  ! one line, and this way that line proves the stub normalised the frame --
  ! a trampoline that forgets its dummy push reports a return address here.
  character(kind=c_char, len=*), parameter :: FK_ERR    = " ERR 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_DASH   = " -- " // c_null_char
  character(kind=c_char, len=*), parameter :: FK_EQUALS = " = 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_NL     = FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_HALTED = &
       "*** HALTED -- CLI/HLT ***" // FK_CRLF // c_null_char
  ! The #DF verdict, printed before the register dump because it is the one
  ! fact a panic on a broken stack may not survive long enough to reach.
  character(kind=c_char, len=*), parameter :: FK_DF_IST = &
       "*** #DF ENTERED ON IST1 -- THE EMERGENCY STACK HELD ***" // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_DF_NO_IST = &
       "*** #DF ENTERED ON THE FAULTING STACK -- NO IST SWITCH ***" // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_NMI_IST = &
       "*** NMI ENTERED ON IST2 -- THE EMERGENCY STACK HELD ***" // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_NMI_NO_IST = &
       "*** NMI ENTERED ON THE INTERRUPTED STACK -- NO IST SWITCH ***" // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_UNKNOWN = &
       "Unknown Exception" // c_null_char

  ! Intel SDM Vol.3 Table 6-1.  NUL-terminated inside a fixed-length element,
  ! so the trailing blanks the array constructor pads with are never printed.
  character(kind=c_char, len=40), parameter :: FK_FAULT_NAME(0:31) = &
       [ character(kind=c_char, len=40) :: &
         "#DE Divide-by-Zero Error"           // c_null_char, &
         "#DB Debug"                          // c_null_char, &
         "NMI Non-Maskable Interrupt"         // c_null_char, &
         "#BP Breakpoint"                     // c_null_char, &
         "#OF Overflow"                       // c_null_char, &
         "#BR Bound Range Exceeded"           // c_null_char, &
         "#UD Invalid Opcode"                 // c_null_char, &
         "#NM Device Not Available"           // c_null_char, &
         "#DF Double Fault"                   // c_null_char, &
         "Coprocessor Segment Overrun"        // c_null_char, &
         "#TS Invalid TSS"                    // c_null_char, &
         "#NP Segment Not Present"            // c_null_char, &
         "#SS Stack-Segment Fault"            // c_null_char, &
         "#GP General Protection Fault"       // c_null_char, &
         "#PF Page Fault"                     // c_null_char, &
         "Reserved"                           // c_null_char, &
         "#MF x87 Floating-Point Exception"   // c_null_char, &
         "#AC Alignment Check"                // c_null_char, &
         "#MC Machine Check"                  // c_null_char, &
         "#XM SIMD Floating-Point Exception"  // c_null_char, &
         "#VE Virtualization Exception"       // c_null_char, &
         "#CP Control Protection Exception"   // c_null_char, &
         "Reserved"                           // c_null_char, &
         "Reserved"                           // c_null_char, &
         "Reserved"                           // c_null_char, &
         "Reserved"                           // c_null_char, &
         "Reserved"                           // c_null_char, &
         "Reserved"                           // c_null_char, &
         "#HV Hypervisor Injection Exception" // c_null_char, &
         "#VC VMM Communication Exception"    // c_null_char, &
         "#SX Security Exception"             // c_null_char, &
         "Reserved"                           // c_null_char ]

  interface
    ! Entry point of the trampoline for vector vec.  boot/interrupts.S.
    function fk_isr_stub(vec) result(addr) bind(c, name="fk_isr_stub")
      import :: c_int32_t, c_int64_t
      implicit none
      integer(c_int32_t), intent(in), value :: vec
      integer(c_int64_t)                    :: addr
    end function fk_isr_stub

    ! Entry point of the trampoline for 8259 line n.  boot/interrupts.S.  A
    ! separate table from the exception one because it ends in IRETQ.
    function fk_spurious_stub_addr() result(addr) &
         bind(c, name="fk_spurious_stub_addr")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: addr
    end function fk_spurious_stub_addr
    ! Declared and not USEd: fk_lapic.f90 is compiled AFTER this file in
    ! FSRC_KERNEL, and reordering that chain to satisfy a use statement would
    ! move every module below it.  This is the idiom fk_heap_m already uses to
    ! reach pmm_alloc_contiguous.
    ! roadmap 5.2.  Declared rather than USEd, for the reason console_write
    ! is: fk_usb_kbd_m is built long after this module and a .mod dependency
    ! would force the whole video and USB stack in front of the IDT.
    subroutine usbkbd_isr() bind(c, name="usbkbd_isr")
      implicit none
    end subroutine usbkbd_isr

    subroutine lapic_eoi(base) bind(c, name="lapic_eoi")
      import :: c_int64_t
      implicit none
      integer(c_int64_t), intent(in), value :: base
    end subroutine lapic_eoi
    function fk_irq_stub(line) result(addr) bind(c, name="fk_irq_stub")
      import :: c_int32_t, c_int64_t
      implicit none
      integer(c_int32_t), intent(in), value :: line
      integer(c_int64_t)                    :: addr
    end function fk_irq_stub

    subroutine idt_flush(desc) bind(c, name="idt_flush")
      import :: c_int16_t
      implicit none
      integer(c_int16_t), intent(in) :: desc(*)
    end subroutine idt_flush

    subroutine fk_cpu_halt() bind(c, name="fk_cpu_halt")
      implicit none
    end subroutine fk_cpu_halt

    ! The linear address that caused a #PF.  boot/mmu.S; CR2 is not part of the
    ! frame the trampoline builds, and only the CPU has it.
    function fk_read_cr2() result(v) bind(c, name="fk_read_cr2")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: v
    end function fk_read_cr2
  end interface

contains

  ! Low 16 and low 32 bits of v in the signed kinds Fortran has to store them in.
  pure function u16(v) result(w)
    implicit none
    integer(c_int64_t), intent(in) :: v
    integer(c_int16_t) :: w
    integer(c_int64_t) :: bits

    bits = iand(v, 65535_c_int64_t)
    if (bits > 32767_c_int64_t) bits = bits - 65536_c_int64_t
    w = int(bits, c_int16_t)
  end function u16

  pure function u32(v) result(w)
    implicit none
    integer(c_int64_t), intent(in) :: v
    integer(c_int32_t) :: w
    integer(c_int64_t) :: bits

    bits = iand(v, int(z'FFFFFFFF', c_int64_t))
    if (bits > 2147483647_c_int64_t) bits = bits - 4294967296_c_int64_t
    w = int(bits, c_int32_t)
  end function u32

  ! Field-by-field, never a derived-type assignment: gfortran may lower a whole
  ! struct or array store to memcpy/memset, which is an undefined symbol here.
  subroutine idt_set_gate(vec, handler)
    implicit none
    integer(c_int32_t), intent(in) :: vec
    integer(c_int64_t), intent(in) :: handler

    idt(vec)%off_lo   = u16(handler)
    idt(vec)%sel      = FK_GDT_SEL_CODE
    if (vec == FK_VEC_DF) then
       idt(vec)%ist   = int(FK_TSS_IST_DF, c_int8_t)
    else if (vec == FK_VEC_NMI) then
       idt(vec)%ist   = int(FK_TSS_IST_NMI, c_int8_t)
    else
       idt(vec)%ist   = FK_IDT_IST_NONE
    end if
    idt(vec)%attr     = FK_IDT_ATTR_INTR
    idt(vec)%off_mid  = u16(ishft(handler, -16))
    idt(vec)%off_hi   = u32(ishft(handler, -32))
    idt(vec)%reserved = 0_c_int32_t
  end subroutine idt_set_gate

  ! attr = 0 clears the present bit, so an unhandled vector raises #GP rather
  ! than jumping to whatever address the zeroed offset fields describe.
  subroutine idt_clear_gate(vec)
    implicit none
    integer(c_int32_t), intent(in) :: vec

    idt(vec)%off_lo   = 0_c_int16_t
    idt(vec)%sel      = 0_c_int16_t
    idt(vec)%ist      = 0_c_int8_t
    idt(vec)%attr     = 0_c_int8_t
    idt(vec)%off_mid  = 0_c_int16_t
    idt(vec)%off_hi   = 0_c_int32_t
    idt(vec)%reserved = 0_c_int32_t
  end subroutine idt_clear_gate

  ! Not present first and installed second, so "every vector this kernel does
  ! not handle raises #GP rather than jumping to a zeroed offset" is true by
  ! construction rather than by a range test somebody has to keep correct.
  !
  ! Where the IRQ block goes is fk_pic_m's decision, not this file's: the 8259
  ! is what turns a line number into a vector, so the table follows the chip.
  ! NOTHING HERE ENFORCES FK_PIC1_VECTOR >= FK_IDT_VECTORS, and the consequence
  ! of breaking it is that the second loop overwrites exception gates with IRQ
  ! trampolines -- which is the RIGHT thing for the table to do, because a chip
  ! answering in the exception range is the defect and an IDT that disagreed
  ! with it would only hide where the interrupts were going.  M10 is that case.
  subroutine idt_init() bind(c, name="idt_init")
    implicit none
    integer(c_int32_t) :: v

    do v = 0_c_int32_t, FK_IDT_ENTRIES - 1_c_int32_t
       call idt_clear_gate(v)
    end do

    do v = 0_c_int32_t, FK_IDT_VECTORS - 1_c_int32_t
       call idt_set_gate(v, fk_isr_stub(v))
    end do

    do v = 0_c_int32_t, FK_PIC_LINES - 1_c_int32_t
       call idt_set_gate(FK_PIC1_VECTOR + v, fk_irq_stub(v))
    end do

    ! Installed unconditionally, and before the LAPIC is software-enabled
    ! rather than after: the vector is live from the instant SVR's enable bit
    ! is set, and a spurious interrupt into a cleared descriptor is a #GP
    ! raised during delivery, which is a much worse day than a counter.
    call idt_set_gate(FK_VECTOR_SPURIOUS, fk_spurious_stub_addr())

    ! Roadmap 5.1, and installed here for exactly the reason above: a device
    ! given an MSI-X route can write its message the moment the entry is
    ! unmasked, and a vector whose descriptor is still cleared makes that a #GP
    ! during delivery.  The gate exists before the route does.
    call idt_set_gate(FK_VECTOR_MSI, fk_irq_stub(FK_MSI_LINE))

    call idt_reload()
  end subroutine idt_init

  ! LIDT only, against the table already built.  roadmap 3.5's handoff reloads
  ! it alongside the GDT; the base is a higher-half address either way.
  subroutine idt_reload() bind(c, name="idt_reload")
    implicit none
    integer(c_int32_t) :: v
    integer(c_int64_t) :: base

    base = transfer(c_loc(idt), 0_c_int64_t)
    idtr(1) = u16(int(16 * FK_IDT_ENTRIES - 1, c_int64_t))
    do v = 0_c_int32_t, 3_c_int32_t
       idtr(2 + v) = u16(ishft(base, -16 * v))
    end do

    call idt_flush(idtr)
  end subroutine idt_reload

  ! Every panic line goes to BOTH consoles.  A machine with no serial cable
  ! shows the dump on screen; a machine whose framebuffer never came up still
  ! logs it. Neither is a fallback for the other -- the two are written in the
  ! same order so a reader can line the two transcripts up.
  subroutine emit(s)
    implicit none
    character(kind=c_char, len=*), intent(in) :: s

    call serial_print_string(s)
    call console_write(s, FK_PANIC_MAX)
  end subroutine emit

  subroutine emit_hex(v, digits)
    implicit none
    integer(c_int64_t), intent(in) :: v
    integer(c_int32_t), intent(in) :: digits

    call serial_print_hex(v, digits)
    call console_print_hex(v, digits)
  end subroutine emit_hex

  ! "<label> = 0x<16 digits>".  Labels are passed pre-padded so the dump lines
  ! up without a format string; Fortran I/O statements are banned in the kernel.
  subroutine print_reg(label, v)
    implicit none
    character(kind=c_char, len=*), intent(in) :: label
    integer(c_int64_t), intent(in) :: v
    integer(c_int32_t) :: i

    do i = 1_c_int32_t, int(len(label), c_int32_t)
       call serial_print_byte(iachar(label(i:i), c_int32_t))
    end do
    ! LEN, not FK_PANIC_MAX: a label is padded to width and carries no NUL, so
    ! a generous bound would walk it into whatever .rodata follows.
    call console_write(label, int(len(label), c_int32_t))
    call emit(FK_EQUALS)
    call emit_hex(v, 16_c_int32_t)
    call emit(FK_NL)
  end subroutine print_reg

  ! White on red for the duration of the panic.  Not decoration: the dump is
  ! about to scroll a screen of ordinary boot text off the top, and the colour
  ! is what says at a glance which of the two the reader is looking at.
  !> Tell the panic handler what "white" and "red" are on this framebuffer.
  ! Non-zero hands the acknowledgement to the LAPIC at BASE.  Called once, by
  ! ioapic_bringup, and only after the redirection entry is in place: from this
  ! instant the 8259 path is gone, and an outb to a masked chip retires nothing.
  subroutine idt_set_eoi_lapic(base) bind(c, name="idt_set_eoi_lapic")
    implicit none
    integer(c_int64_t), intent(in), value :: base

    eoi_lapic = base
  end subroutine idt_set_eoi_lapic

  subroutine idt_set_panic_colors(fg, bg) bind(c, name="idt_set_panic_colors")
    implicit none
    integer(c_int32_t), intent(in), value :: fg, bg

    panic_fg = fg
    panic_bg = bg
  end subroutine idt_set_panic_colors

  subroutine panic_screen()
    implicit none

    if (console_ready() == 0_c_int32_t) return
    call console_set_color(panic_fg, panic_bg)
  end subroutine panic_screen

  ! The catcher.  Called by every trampoline in boot/interrupts.S with the
  ! address of the register frame it just built.  Does not return.
  subroutine isr_handler(regs) bind(c, name="isr_handler")
    implicit none
    type(fk_regs_t), intent(in), target :: regs
    integer(c_int64_t) :: frame

    ! Where the frame itself sits, i.e. which stack this handler is running on.
    ! regs%rsp cannot answer that: it is the RSP the fault happened WITH.
    frame = transfer(c_loc(regs), 0_c_int64_t)

    call panic_screen()
    call emit(FK_PANIC_HDR)

    call emit(FK_EXC)
    call emit_hex(regs%int_no, 2_c_int32_t)
    call emit(FK_ERR)
    call emit_hex(regs%err_code, 16_c_int32_t)
    call emit(FK_DASH)
    if (regs%int_no >= 0_c_int64_t .and. regs%int_no < int(FK_IDT_VECTORS, c_int64_t)) then
       call emit(FK_FAULT_NAME(int(regs%int_no, c_int32_t)))
    else
       call emit(FK_UNKNOWN)
    end if
    call emit(FK_NL)

    if (regs%int_no == int(FK_VEC_DF, c_int64_t)) then
       if (tss_on_df_stack(frame) /= 0_c_int32_t) then
          call emit(FK_DF_IST)
       else
          call emit(FK_DF_NO_IST)
       end if
    end if

    ! Same question for NMI, and it needs asking separately: an NMI arrives on
    ! an arbitrary instruction, so the RSP in the frame is whatever the
    ! interrupted code held and says nothing about which stack this handler is
    ! standing on.  Only the frame address does.
    if (regs%int_no == int(FK_VEC_NMI, c_int64_t)) then
       if (tss_on_nmi_stack(frame) /= 0_c_int32_t) then
          call emit(FK_NMI_IST)
       else
          call emit(FK_NMI_NO_IST)
       end if
    end if

    call print_reg("RIP    ", regs%rip)
    ! CR2 unconditionally, not only for vector 14: it is a machine register the
    ! dump is quoting, and suppressing it for other vectors would mean a reader
    ! could not tell "no page fault" from "the handler chose not to look".
    call print_reg("CR2    ", fk_read_cr2())
    call print_reg("CS     ", regs%cs)
    call print_reg("RFLAGS ", regs%rflags)
    call print_reg("RSP    ", regs%rsp)
    call print_reg("SS     ", regs%ss)
    call print_reg("FRAME  ", frame)

    call print_reg("RAX    ", regs%rax)
    call print_reg("RBX    ", regs%rbx)
    call print_reg("RCX    ", regs%rcx)
    call print_reg("RDX    ", regs%rdx)
    call print_reg("RSI    ", regs%rsi)
    call print_reg("RDI    ", regs%rdi)
    call print_reg("RBP    ", regs%rbp)
    call print_reg("R8     ", regs%r8)
    call print_reg("R9     ", regs%r9)
    call print_reg("R10    ", regs%r10)
    call print_reg("R11    ", regs%r11)
    call print_reg("R12    ", regs%r12)
    call print_reg("R13    ", regs%r13)
    call print_reg("R14    ", regs%r14)
    call print_reg("R15    ", regs%r15)

    call emit(FK_HALTED)
    call fk_cpu_halt()
  end subroutine isr_handler

  ! The router.  Called by every IRQ trampoline in boot/interrupts.S with the
  ! address of the frame it built, and unlike isr_handler it RETURNS -- into the
  ! POP_GPRS/IRETQ tail, which is the instruction this project had never
  ! executed before roadmap 3.2b.
  !
  ! regs%int_no is the 8259 LINE, 0-15, because that is what the stub pushed;
  ! the vector it arrived on is FK_PIC1_VECTOR + line and no code here needs it.
  !
  ! IT RETURNS AN RSP, and that is roadmap 4.0's whole hook.  irq_common loads
  ! the returned value into RSP before POP_GPRS, so returning the frame it was
  ! given resumes the interrupted thread and returning a DIFFERENT frame -- one
  ! saved on another task's stack -- resumes that one instead.  A context
  ! switch is then not a special path through this routine; it is the ordinary
  ! path with a different answer.
  function irq_handler(regs) result(resume) bind(c, name="irq_handler")
    implicit none
    type(fk_regs_t), intent(in), target :: regs
    integer(c_int64_t) :: resume
    integer(c_int32_t) :: line

    ! The frame's own address: what irq_common pushed and what it will pop
    ! unless the scheduler names another one.
    resume = transfer(c_loc(regs), 0_c_int64_t)
    line   = int(regs%int_no, c_int32_t)

    ! THE SPURIOUS CHECK COMES FIRST, and it is not defensive programming: the
    ! chip did not set an in-service bit for a spurious interrupt, so the EOI at
    ! the bottom of this routine would clear the bit belonging to whatever IS in
    ! service and the interrupt that owns it never completes.  pic_isr() returns
    ! the slave in bits 15:8 and the master in 7:0, so the bit to test is the
    ! line number itself for both cases.
    !
    ! IT IS ALSO THE 8259'S OWN, and is skipped once the IOAPIC owns the line:
    ! with both chips masked nothing reaches the CPU through them, pic_isr()
    ! would be interrogating a pair that is not delivering, and the LAPIC's
    ! spurious interrupt is vector 255 and never arrives in this routine at all
    ! -- boot/interrupts.S answers it without entering Fortran.
    ! A MESSAGE, NOT A WIRE.  No 8259 line, no I/O APIC pin, nothing to ask
    ! about a spurious in-service bit and no scheduler tick to run: count it,
    ! retire it at the LAPIC, and go back.  The EOI is not optional -- a
    ! message-signalled interrupt sets an in-service bit like any other, and
    ! skipping it wedges every later interrupt at that priority.
    if (line == FK_MSI_LINE) then
       fk_msi_count = fk_msi_count + 1_c_int64_t
       ! THE DEVICE IS ACKNOWLEDGED BEFORE THE CPU IS.  usbkbd_isr clears the
       ! interrupter's IP -- write-1-to-clear, and the controller sends no
       ! further message while it is set -- and drains the event ring.  Leaving
       ! that out gives exactly one interrupt for the life of the machine, and
       ! one keystroke looks identical to a working keyboard.
       call usbkbd_isr()
       if (eoi_lapic /= 0_c_int64_t) call lapic_eoi(eoi_lapic)
       return
    end if

    if (eoi_lapic == 0_c_int64_t .and. &
        (line == FK_IRQ_SPURIOUS_MASTER .or. line == FK_IRQ_SPURIOUS_SLAVE)) then
       if (.not. btest(pic_isr(), line)) then
          fk_irq_spurious = fk_irq_spurious + 1_c_int64_t
          ! A spurious SLAVE interrupt still reached the CPU through the
          ! master's cascade line, and the master really is holding that bit.
          if (line == FK_IRQ_SPURIOUS_SLAVE) call pic_eoi(FK_PIC_CASCADE)
          return
       end if
    end if

    if (line == FK_PIT_IRQ) call pit_tick(regs%rip, regs%rflags)

    ! Before the IRETQ rather than after it: the 8259 delivers nothing further
    ! while it holds an in-service bit, so a missing EOI presents as exactly one
    ! interrupt ever arriving.
    !
    ! AND BEFORE THE CONTEXT SWITCH, which is the ordering that matters now.
    ! The switch below returns into a DIFFERENT stack and this routine is not
    ! reached again on this path; an EOI after it would be an EOI that never
    ! runs, and the timer would fire exactly once for the whole boot.
    !
    ! WHICH CHIP is roadmap 3.3's: an interrupt delivered through the IOAPIC is
    ! retired at the LAPIC, and an outb to a masked 8259 retires nothing at all.
    ! The symptom of getting this wrong is the same in both directions -- one
    ! interrupt and then silence -- which is why the switch is one branch here
    ! rather than a second copy of this routine.
    if (eoi_lapic /= 0_c_int64_t) then
       call lapic_eoi(eoi_lapic)
    else
       call pic_eoi(line)
    end if

    ! roadmap 4.0.  sched_tick returns the frame to resume on -- its own
    ! argument if there is nothing to switch to -- so a kernel with no
    ! scheduler linked behaves exactly as it did before.
    if (line == FK_PIT_IRQ) resume = sched_tick(resume)
  end function irq_handler

end module fk_idt_m
