! SPDX-License-Identifier: GPL-2.0
! IDT and the kernel panic handler (roadmap 3.2).  The 32 CPU exception vectors
! are routed through the trampolines in boot/interrupts.S to isr_handler below,
! which dumps the captured machine state over COM1 and parks the CPU.
module fk_idt_m
  use, intrinsic :: iso_c_binding, only: c_int8_t, c_int16_t, c_int32_t, &
                                         c_int64_t, c_char, c_null_char, c_loc
  use fk_gdt_m,    only: FK_GDT_SEL_CODE
  use fk_serial_m, only: serial_print_byte, serial_print_string
  implicit none
  private
  public :: idt_init, isr_handler

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

  ! IST 0 keeps the faulting stack.  A dedicated stack for #DF needs a TSS,
  ! which is roadmap 3.3 work.
  integer(c_int8_t), parameter :: FK_IDT_IST_NONE = 0_c_int8_t

  type(fk_idt_entry_t), target, save :: idt(0:FK_IDT_ENTRIES - 1)

  ! LIDT takes the same packed 16-bit limit + 64-bit base LGDT does; see the
  ! same declaration in fk_gdt_m for why it cannot be a bind(c) derived type.
  integer(c_int16_t), save :: idtr(5)

  character(kind=c_char, len=*), parameter :: FK_CRLF = achar(13) // achar(10)

  character(kind=c_char, len=*), parameter :: FK_PANIC_HDR = &
       FK_CRLF // "*** FORTRAN KERNEL PANIC ***" // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_EXC    = "EXCEPTION 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_DASH   = " -- " // c_null_char
  character(kind=c_char, len=*), parameter :: FK_EQUALS = " = 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_NL     = FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_HALTED = &
       "*** HALTED -- CLI/HLT ***" // FK_CRLF // c_null_char
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

    subroutine idt_flush(desc) bind(c, name="idt_flush")
      import :: c_int16_t
      implicit none
      integer(c_int16_t), intent(in) :: desc(*)
    end subroutine idt_flush

    subroutine fk_cpu_halt() bind(c, name="fk_cpu_halt")
      implicit none
    end subroutine fk_cpu_halt
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
    idt(vec)%ist      = FK_IDT_IST_NONE
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

  subroutine idt_init() bind(c, name="idt_init")
    implicit none
    integer(c_int32_t) :: v
    integer(c_int64_t) :: base

    do v = 0_c_int32_t, FK_IDT_ENTRIES - 1_c_int32_t
       if (v < FK_IDT_VECTORS) then
          call idt_set_gate(v, fk_isr_stub(v))
       else
          call idt_clear_gate(v)
       end if
    end do

    base = transfer(c_loc(idt), 0_c_int64_t)
    idtr(1) = u16(int(16 * FK_IDT_ENTRIES - 1, c_int64_t))
    do v = 0_c_int32_t, 3_c_int32_t
       idtr(2 + v) = u16(ishft(base, -16 * v))
    end do

    call idt_flush(idtr)
  end subroutine idt_init

  subroutine print_hex(v, nibbles)
    implicit none
    integer(c_int64_t), intent(in) :: v
    integer(c_int32_t), intent(in) :: nibbles
    integer(c_int32_t) :: i, d

    ! 48 = '0', 55 = 'A' - 10.  Bytes, not characters: see serial_print_byte.
    do i = nibbles - 1_c_int32_t, 0_c_int32_t, -1_c_int32_t
       d = int(iand(ishft(v, -4 * i), 15_c_int64_t), c_int32_t)
       if (d < 10_c_int32_t) then
          call serial_print_byte(48 + d)
       else
          call serial_print_byte(55 + d)
       end if
    end do
  end subroutine print_hex

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
    call serial_print_string(FK_EQUALS)
    call print_hex(v, 16_c_int32_t)
    call serial_print_string(FK_NL)
  end subroutine print_reg

  ! The catcher.  Called by every trampoline in boot/interrupts.S with the
  ! address of the register frame it just built.  Does not return.
  subroutine isr_handler(regs) bind(c, name="isr_handler")
    implicit none
    type(fk_regs_t), intent(in) :: regs

    call serial_print_string(FK_PANIC_HDR)

    call serial_print_string(FK_EXC)
    call print_hex(regs%int_no, 2_c_int32_t)
    call serial_print_string(FK_DASH)
    if (regs%int_no >= 0_c_int64_t .and. regs%int_no < int(FK_IDT_VECTORS, c_int64_t)) then
       call serial_print_string(FK_FAULT_NAME(int(regs%int_no, c_int32_t)))
    else
       call serial_print_string(FK_UNKNOWN)
    end if
    call serial_print_string(FK_NL)

    call print_reg("ERRCODE", regs%err_code)
    call print_reg("RIP    ", regs%rip)
    call print_reg("CS     ", regs%cs)
    call print_reg("RFLAGS ", regs%rflags)
    call print_reg("RSP    ", regs%rsp)
    call print_reg("SS     ", regs%ss)

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

    call serial_print_string(FK_HALTED)
    call fk_cpu_halt()
  end subroutine isr_handler

end module fk_idt_m
