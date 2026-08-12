! SPDX-License-Identifier: GPL-2.0
!> 16550 UART console on COM1 -- roadmap item 2.1.  The two port-I/O
!! primitives this module is built on, fk_outb and fk_inb, are in boot/io.S:
!! IN and OUT are privileged instructions with no Fortran spelling, exactly
!! like the CLI/HLT pair that boot/boot.S exports as fk_cpu_halt.  This module
!! is the Fortran half of that boundary and owns every decision above it.
!!
!! WHY A SERIAL DRIVER ON A MACHINE THAT HAS NO SERIAL PORT
!!
!! The target Minisforum has no DB9 header and no 16550 behind one, so nothing
!! here will ever drive a wire on the real box.  That is not what it is for.
!! QEMU emulates a 16550 at 0x3F8 and will pipe that device straight to a
!! file, a pty or stdout, and today that is the ONLY channel out of this
!! kernel:
!!
!!   * no framebuffer.  Roadmap 2.2 is open and the Multiboot2 header in
!!     boot/boot.S deliberately does NOT request one (tag type 5 switches GRUB
!!     into a graphics mode and reports an address routinely outside the 1 GiB
!!     the boot stub identity-maps).  fk_gop_renderer is finished and has
!!     nothing to map.
!!   * no VGA text mode.  This is a 64-bit UEFI machine; there is no 0xB8000
!!     aperture to poke and no BIOS int 10h to call.
!!   * no interrupts.  There is no IDT until roadmap 3.2, so there is no
!!     console that could be driven by an IRQ even in principle.
!!
!! What roadmap 1.2 left behind is a boot gate that reads sixteen bytes out of
!! guest physical memory over QMP.  That is proof of life and nothing more: it
!! cannot carry a value, a name or a reason, and it is read once, after the
!! CPU has already parked.  A kernel with no console can only communicate by
!! crashing.  This module is therefore the first thing kernel_main does, and
!! every later phase -- PMM page counts, ACPI table walks, PCI enumeration --
!! is debugged through it.  It is the instrument, not a feature.
!!
!! THE DIVISOR IS 1, AND THAT IS NOT A SHORTCUT
!!
!! The 16550's reference clock is 1.8432 MHz and the transmitter divides it by
!! 16, so the fastest bit rate the part can produce is 1843200/16 = 115200
!! baud.  The divisor latch (DLL:DLM, reachable only while LCR.DLAB is set)
!! holds 115200/baud -- Linux writes that arithmetic out literally in
!! arch/x86/boot/early_serial_console.c:36, `divisor = 115200 / baud;`.
!!
!! So a divisor of 1 is not "the simplest value that works", it IS 115200
!! baud, and 115200 is the fastest standard rate precisely because it is the
!! rate at which the divisor bottoms out.  There is no arithmetic to perform
!! and nothing to compute: roadmap 2.1 specifies serial_init(port), with no
!! baud argument, so a divisor of 1 is written directly as DLL=1, DLM=0.
!! (Divisor 0 is not a faster option -- it is illegal, and a chip handed 0
!! either divides by 65536 or stops clocking, depending on the part.)
!!
!! Fastest is also the right choice rather than merely an available one: this
!! console is polled, and serial_print_char busy-waits ~87 us per character at
!! 115200.  At 9600 baud -- Linux's DEFAULT_BAUD for earlyprintk -- the same
!! character costs ~1.04 ms, and a forty-character banner would spend 42 ms of
!! boot time spinning in a poll loop.
!!
!! THE SELF-TEST, AND EXACTLY WHAT IT DOES NOT PROVE
!!
!! Step 7 sets UART_MCR_LOOP, which wires the transmit shift register back
!! into the receiver INSIDE the chip; step 9 writes 0xAE and step 11 reads it
!! back.  A match proves the port address decodes to something, that the
!! something implements the divisor-latch/FIFO/LSR protocol, and that a byte
!! survives a round trip through it.
!!
!! It does NOT prove there is a cable, a receiver, a terminal or anyone
!! listening: while LOOP is set, nothing leaves the package by construction.
!! On QEMU it proves less still -- it proves that QEMU's 16550 device model
!! implements loopback, which it does because it was written to.  The honest
!! reading of `status == 0` is "something answered at this port address", and
!! the honest reading of `status == 1` is "do not trust what you read on this
!! line", not "the console is dead".  It is reported to the caller and acted
!! on nowhere in this file.
!!
!! WHY POLLING, NOT INTERRUPTS
!!
!! An interrupt-driven UART is not merely more complex here, it is impossible:
!! roadmap 3.2 (the IDT) does not exist, IDTR is null, and the first IRQ4 this
!! chip raised would take the CPU through a null descriptor to a double fault,
!! then a triple fault, then a silent reboot.  That is also why step 1 of
!! serial_init writes 0 to IER before touching anything else, ahead of the
!! line settings: a real 16550 comes out of reset with its interrupts masked,
!! but "whatever ran before us left it that way" is not a property worth
!! betting the boot on, and the window between power-on and this write is the
!! one window in which a stray enable bit is fatal.
!!
!! FREESTANDING TRAPS, CONCRETELY
!!
!!   * NO I/O STATEMENT MAY APPEAR HERE.  A single `print *` pulls in
!!     _gfortran_st_write and the whole libgfortran unit-table machinery, and
!!     tools/linktest.sh gate (c) fails the build on it.  This module is a
!!     console driver that cannot itself print; the only way a byte leaves is
!!     fk_outb.
!!   * CHARACTERS ARE COMPARED AS INTEGERS.  `s(i) == c_null_char` is the
!!     obvious Fortran and is exactly what must not be written: gfortran
!!     lowers a character relational to a _gfortran_compare_string call, which
!!     is a libgfortran symbol.  serial_print_string tests
!!     `iachar(s(i)) == 0` instead, which is an inline byte load and a compare.
!!   * IACHAR, NOT ICHAR.  iachar is defined against ASCII regardless of the
!!     processor's collating sequence, and it yields 0..255, so the value
!!     handed to fk_outb is never negative -- see the ABI note below.
!!   * NO ARRAY-SECTION ASSIGNMENT anywhere; gfortran may lower one to memset.
!!     Nothing in this module has an array to assign, which is the cheapest
!!     way to satisfy that rule.
!!
!! ABI NOTE: EVERYTHING IS A SIGNED 32-BIT INTEGER
!!
!! Fortran has no unsigned types.  Carrying a port number as u16 and a datum
!! as u8 would force constants like 0xC7 and 0xAE to be written as the
!! negative int8s -57 and -82, which is unreadable and one sign-extension bug
!! away from silence.  Every value here is therefore an integer(c_int32_t)
!! holding a small positive number, and boot/io.S truncates: fk_outb uses %di
!! and %sil, fk_inb ZERO-extends its result into EAX.  That zero-extension is
!! load-bearing for the self-test -- a sign-extending read of 0xAE would
!! arrive as -82, never compare equal to 174, and report a failure on a
!! perfectly healthy chip.
!!
!! WHAT IS PROVEN, AND WHAT IS NOT
!!
!! Checked by the host test (tests/drivers/serial/): the exact ordered trace
!! of fk_outb/fk_inb operations serial_init performs against a fake 16550, the
!! byte stream serial_print_string produces for a given C string (including
!! that it stops at the NUL and truncates rather than runs on without one),
!! and that both spin loops terminate when the fake UART never raises THRE.
!!
!! NOT checked there, and not checkable there: that a REAL device model
!! accepts this ordering.  The host test's fake UART is written from the same
!! reading of the same datasheet as this driver, so a shared misconception
!! cancels out cleanly and silently.  Only booting the ISO under QEMU with the
!! serial port redirected can catch that class, and as of this commit that has
!! not been done -- nothing in this file has executed on any CPU, emulated or
!! real.  Do not read a green host suite as "the console works".
module fk_serial_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_char
  implicit none
  private
  public :: FK_SERIAL_COM1, serial_init, serial_print_char, &
            serial_print_string

  !> Base I/O port of COM1 / ttyS0.  The same constant Linux calls
  !! DEFAULT_SERIAL_PORT in arch/x86/boot/early_serial_console.c:8, and the
  !! port QEMU's default -serial device answers on.  PUBLIC because the caller
  !! chooses the port, not this module: COM2 at 0x2F8 needs no code change
  !! here (see "base + offset" below).
  integer(c_int32_t), parameter :: FK_SERIAL_COM1 = int(z'3F8', c_int32_t)

  ! --- 16550 register offsets -------------------------------------------
  !
  ! Every one of these is checked against the kernel's own
  ! include/uapi/linux/serial_reg.h, named per constant, because a UART
  ! bring-up written from memory is how a driver ends up writing the divisor
  ! into the interrupt-enable register.  Offsets 0 and 1 name three registers
  ! each: which one a given access reaches depends on LCR.DLAB, which is the
  ! single most important piece of state in the sequence below.
  integer(c_int32_t), parameter :: UART_TX  = 0_c_int32_t  ! serial_reg.h:22
  integer(c_int32_t), parameter :: UART_RX  = 0_c_int32_t  ! serial_reg.h:21
  integer(c_int32_t), parameter :: UART_DLL = 0_c_int32_t  ! serial_reg.h:166
  integer(c_int32_t), parameter :: UART_IER = 1_c_int32_t  ! serial_reg.h:24
  integer(c_int32_t), parameter :: UART_DLM = 1_c_int32_t  ! serial_reg.h:167
  integer(c_int32_t), parameter :: UART_FCR = 2_c_int32_t  ! serial_reg.h:54 (W)
  integer(c_int32_t), parameter :: UART_IIR = 2_c_int32_t  ! serial_reg.h:34 (R)
  integer(c_int32_t), parameter :: UART_LCR = 3_c_int32_t  ! serial_reg.h:105
  integer(c_int32_t), parameter :: UART_MCR = 4_c_int32_t  ! serial_reg.h:128
  integer(c_int32_t), parameter :: UART_LSR = 5_c_int32_t  ! serial_reg.h:139

  ! UART_IIR is declared and never used, deliberately.  It is the READ side of
  ! offset 2 whose WRITE side is UART_FCR, and a reader checking this table
  ! against serial_reg.h needs to see that offset 2 is two different registers
  ! before concluding that reading back what FCR was set to is possible.  It
  ! is not.  (gfortran's -Wall does not warn on an unused PARAMETER; only
  ! -Wunused-parameter does, and nothing in this project passes it.)

  ! --- Register bits, all from include/uapi/linux/serial_reg.h -----------
  integer(c_int32_t), parameter :: UART_LCR_DLAB  = int(z'80', c_int32_t) ! :110
  integer(c_int32_t), parameter :: UART_LCR_WLEN8 = int(z'03', c_int32_t) ! :119

  integer(c_int32_t), parameter :: UART_FCR_ENABLE_FIFO = int(z'01', c_int32_t) ! :55
  integer(c_int32_t), parameter :: UART_FCR_CLEAR_RCVR  = int(z'02', c_int32_t) ! :56
  integer(c_int32_t), parameter :: UART_FCR_CLEAR_XMIT  = int(z'04', c_int32_t) ! :57
  integer(c_int32_t), parameter :: UART_FCR_TRIGGER_14  = int(z'C0', c_int32_t) ! :87

  integer(c_int32_t), parameter :: UART_MCR_DTR  = int(z'01', c_int32_t) ! :137
  integer(c_int32_t), parameter :: UART_MCR_RTS  = int(z'02', c_int32_t) ! :136
  integer(c_int32_t), parameter :: UART_MCR_OUT1 = int(z'04', c_int32_t) ! :135
  integer(c_int32_t), parameter :: UART_MCR_OUT2 = int(z'08', c_int32_t) ! :134
  integer(c_int32_t), parameter :: UART_MCR_LOOP = int(z'10', c_int32_t) ! :133

  integer(c_int32_t), parameter :: UART_LSR_DR   = int(z'01', c_int32_t) ! :147
  integer(c_int32_t), parameter :: UART_LSR_THRE = int(z'20', c_int32_t) ! :142

  ! --- Composed register values -----------------------------------------
  !
  ! IOR of named constants in a PARAMETER initialiser is an initialization
  ! expression: it is folded at compile time into the single byte named in the
  ! trailing comment, so this costs nothing at run time and the magic number a
  ! trace shows can be read back to the bits that produced it.

  !> FCR: FIFOs on, both FIFOs flushed, receive trigger at 14 bytes.  0xC7.
  !! The two CLEAR bits are self-clearing one-shots, which is why the same
  !! value is written twice in serial_init -- once to start clean, once to
  !! discard the loopback probe.
  integer(c_int32_t), parameter :: FK_FCR_SETUP = &
       ior(ior(UART_FCR_ENABLE_FIFO, UART_FCR_CLEAR_RCVR), &
           ior(UART_FCR_CLEAR_XMIT,  UART_FCR_TRIGGER_14))

  !> MCR during the self-test: LOOP|OUT2|OUT1|RTS.  0x1E.  DTR is absent on
  !! purpose -- asserting "terminal ready" to a line that is looped back on
  !! itself would be a claim about the outside world made while deliberately
  !! disconnected from it.
  integer(c_int32_t), parameter :: FK_MCR_SELFTEST = &
       ior(ior(UART_MCR_LOOP, UART_MCR_OUT2), &
           ior(UART_MCR_OUT1, UART_MCR_RTS))

  !> MCR once the port is live: DTR|RTS|OUT1|OUT2.  0x0F.  LOOP is cleared,
  !! which is the write that actually connects the transmitter to the wire.
  !! OUT2 is not decoration on a PC: it gates the UART's interrupt line onto
  !! the 8259 input.  Harmless today (IER is 0 and there is no IDT), and set
  !! now so that 3.2/3.3 do not have to come back and find out why an
  !! otherwise correct IRQ4 handler never fires.
  integer(c_int32_t), parameter :: FK_MCR_LIVE = &
       ior(ior(UART_MCR_OUT2, UART_MCR_OUT1), &
           ior(UART_MCR_RTS,  UART_MCR_DTR))

  !> Divisor 1 == 115200 baud.  See the file header for why there is no
  !! division to perform.
  integer(c_int32_t), parameter :: FK_DIVISOR_LO = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_DIVISOR_HI = 0_c_int32_t

  !> The loopback probe byte.  0xAE is 10101110b -- alternating enough that a
  !! stuck-high or stuck-low data line, or a chip that returns the last value
  !! written to a DIFFERENT register, does not accidentally match.  0x00 and
  !! 0xFF are the two values that would.
  integer(c_int32_t), parameter :: FK_PROBE_BYTE = int(z'AE', c_int32_t)

  !> Iterations to spin waiting on a line-status bit before giving up.
  !!
  !! 65535 is not a round number picked for comfort: it is the exact bound
  !! Linux itself uses around the identical LSR/XMTRDY poll in
  !! arch/x86/boot/tty.c:30, `unsigned timeout = 0xffff;` (the loop is
  !! tty.c:32).  Matching it means this driver inherits a bound that has been
  !! shipped on every x86 machine for two decades rather than one invented
  !! here.
  !!
  !! The arithmetic that makes it safe in both directions: one character at
  !! 115200 baud with 8N1 framing is 10 bit times, ~87 us.  Every iteration of
  !! the poll costs at least one port-I/O access -- ~1 us trapped out to a
  !! device model under QEMU, and on the order of 1 us on real ISA-speed
  !! hardware -- so roughly 87 iterations cover a full character time and
  !! 65535 is a ~750x margin.  No healthy UART can be starved by this bound.
  !! WHICH ABSENT-PORT FAILURE THIS BOUND ACTUALLY COVERS -- because it is not
  !! the one people expect, and getting it backwards sends a person debugging a
  !! silent console to the wrong place.
  !!
  !!   LSR reads 0xFF  (the classic floating ISA bus).  UART_LSR_THRE is 0x20,
  !!                   so IAND(0xFF, 0x20) is NON-zero and lsr_wait returns
  !!                   .true. on its FIRST read.  The bound is never reached,
  !!                   nothing is delayed, and every byte is written to a port
  !!                   nothing decodes.  The ONLY thing that detects this case
  !!                   is serial_init's 0xAE probe read-back, which reads 0xFF
  !!                   and reports status 1 -- which is precisely why the probe
  !!                   exists and why 0xFF was excluded when the probe byte was
  !!                   chosen (see FK_PROBE_BYTE).
  !!   LSR reads 0x00, or a real UART wedges with THRE stuck low.  THIS is the
  !!                   case the bound is for: the poll runs to 65535 and the
  !!                   byte is dropped.
  !!
  !! The bound COMPOSES, which is worth stating because the per-character figure
  !! invites the wrong mental model: serial_print_string's worst case is
  !! FK_SERIAL_MAX_STRING * FK_SERIAL_TX_SPINS port accesses, i.e. ~268 million,
  !! not 65535.  Still bounded, still terminating, and still the right trade --
  !! but "the console costs at most one poll bound" is false, and a person
  !! waiting on a wedged UART should know the wait is proportional to the string.
  !! No figure in wall-clock time is quoted here: it would be a guess about a
  !! device model's trap cost, and nothing in this tree has measured it.
  !!
  !! The name says TX because that is the poll roadmap 2.1 specifies it for and
  !! the one Linux's 0xffff came from, but serial_init's DATA-READY wait shares
  !! it.  That is deliberate rather than reuse for its own sake: in loopback the
  !! byte that satisfies DR is the byte this driver just transmitted, so the two
  !! waits are bounded by the same character time and a second constant would be
  !! the same number with a second chance to drift.
  integer(c_int32_t), parameter :: FK_SERIAL_TX_SPINS = 65535_c_int32_t

  !> Longest string serial_print_string will emit.
  !!
  !! The bound is what converts a caller that lost its NUL terminator from "a
  !! walk through kernel memory until something faults" -- with no IDT, that
  !! is a triple fault and a silent reboot -- into a visibly truncated line.
  !! 4096 is one page: long enough that no banner or panic dump this kernel
  !! will produce before 3.2 can reach it, short enough that the failure mode
  !! is bounded at ~356 ms of transmission at 115200 baud.
  integer(c_int32_t), parameter :: FK_SERIAL_MAX_STRING = 4096_c_int32_t

  ! --- Private driver state ----------------------------------------------
  !
  ! Module variables are implicitly SAVE and live in .bss, which boot/boot.S
  ! zeroes before calling kernel_main -- so the initialisers below are the
  ! documentation of the pre-init state, not the mechanism that establishes
  ! it.  Both are PRIVATE: they are ordinary Fortran globals with a gfortran
  ! mangled name, and a public module variable would have to be bind(c) to
  ! satisfy tools/compliance.sh.  Nothing outside this file has any business
  ! knowing which port the console landed on.
  !
  ! NOT volatile, unlike the framebuffer in fk_gop_renderer and the sentinel
  ! in fk_kmain: those are written for an observer outside the program, and
  ! every store into them is dead by the compiler's rules.  These two are read
  ! back by this module on the very next call, so the reads keep the writes
  ! alive with no annotation.
  integer(c_int32_t) :: serial_base  = 0_c_int32_t
  logical            :: serial_ready = .false.

  interface
    !> Write one byte to an x86 I/O port.  boot/io.S.
    !!
    !!     void fk_outb(int32_t port, int32_t value);
    !!
    !! Only the low 16 bits of port and the low 8 bits of value are
    !! architecturally meaningful -- OUT takes its port in DX, and one byte is
    !! all that reaches the wire -- so the assembly reads %di and %sil and drops
    !! the rest.
    !!
    !! NOT because the caller is allowed to pass garbage in the discarded bits.
    !! These arguments are declared int32_t, so a conforming caller defines the
    !! whole of EDI and ESI; the psABI leaves bits 63:32 undefined, not 31:16,
    !! and `movl %edi, %edx` would be equally correct.  The narrow moves are a
    !! statement about which bits the HARDWARE consumes, made at the boundary
    !! where that is the interesting question.  The full argument lives in one
    !! place, boot/io.S under REGISTER MAPPING; this note exists so that whoever
    !! writes fk_outw does not infer a rule about the upper half that is not
    !! there and start masking pointers with it.
    subroutine fk_outb(port, val) bind(c, name="fk_outb")
      ! An interface body does not see its host's entities: without IMPORT,
      ! c_int32_t is undefined here even though the module USEs it.  And an
      ! interface body is its own program unit, so it needs its own IMPLICIT
      ! NONE -- tools/compliance.sh counts units, not files.
      import :: c_int32_t
      implicit none
      integer(c_int32_t), intent(in), value :: port, val
    end subroutine fk_outb

    !> Read one byte from an x86 I/O port.  boot/io.S.
    !!
    !!     int32_t fk_inb(int32_t port);
    !!
    !! The result is ZERO-extended into EAX, so what arrives here is always
    !! 0..255 and never a negative number.  A FUNCTION rather than a
    !! subroutine with an intent(out): the value is the whole point of the
    !! call, and `iand(fk_inb(p), MASK)` reads as the hardware test it is.
    function fk_inb(port) result(val) bind(c, name="fk_inb")
      import :: c_int32_t
      implicit none
      integer(c_int32_t), intent(in), value :: port
      integer(c_int32_t)                    :: val
    end function fk_inb
  end interface

contains

  !> Wait for a set of bits to appear in the line status register, or give up.
  !!
  !! base  base I/O port of the UART
  !! mask  the LSR bits to wait for (UART_LSR_THRE or UART_LSR_DR here)
  !! ->    .true. if the bits were seen, .false. if the spin bound ran out
  !!
  !! ONE HELPER, TWO CALLERS, ON PURPOSE.  serial_init and serial_print_char
  !! both poll the LSR and must poll it identically -- same bound, same
  !! first-read-then-test order -- because the host test asserts the resulting
  !! port trace and a second, subtly different loop would be a second thing to
  !! get wrong.
  !!
  !! A COUNTED DO WITH AN EXIT, NEVER `do while`.  The obvious spelling,
  !! `do while (iand(fk_inb(...), mask) == 0)`, has no bound at all: a UART
  !! that is absent, wedged or (on QEMU) simply not attached to a chardev
  !! never sets the bit, and the kernel hangs in a loop that has no way to
  !! report that it is hanging.  A counted DO cannot fail to terminate.  GOTO
  !! is not an alternative -- tools/compliance.sh bans it outright.
  !!
  !! The LSR is read BEFORE the first test, which is what makes the common
  !! case -- an idle transmitter, THRE already set -- cost exactly one port
  !! access.
  !!
  !! fk_inb is called inside the loop and is NOT declared PURE, so gfortran
  !! must treat it as having unknown side effects and re-issue the `in`
  !! instruction on every iteration.  Hoisting it would turn this into an
  !! infinite loop; that it does not happen is a consequence of the interface
  !! above saying nothing that would permit it.
  function lsr_wait(base, mask) result(seen)
    implicit none
    integer(c_int32_t), intent(in) :: base, mask
    logical            :: seen
    integer(c_int32_t) :: spin

    seen = .false.
    do spin = 1_c_int32_t, FK_SERIAL_TX_SPINS
       if (iand(fk_inb(base + UART_LSR), mask) /= 0_c_int32_t) then
          seen = .true.
          exit
       end if
    end do
  end function lsr_wait

  !> Bring a 16550 up at 115200 8N1 and check that it answers.
  !!
  !! port    base I/O address of the UART; FK_SERIAL_COM1 for ttyS0
  !! ->      0 if the loopback probe read back the byte it wrote,
  !!         1 if it read back something else or either poll timed out
  !!
  !! THE ORDER OF THE THIRTEEN PORT OPERATIONS IS THE INTERFACE, not an
  !! implementation detail, and the host test compares the recorded trace byte
  !! for byte.  Every classic UART bring-up bug is an ORDERING bug, and none
  !! of them is visible in the final register state:
  !!
  !!   * writing DLL/DLM without LCR.DLAB set does not write the divisor at
  !!     all -- offsets 0 and 1 are then the transmit buffer and IER, so the
  !!     "divisor" is transmitted as a character and enables interrupts, and
  !!     the port keeps running at whatever rate it was already at.
  !!   * leaving DLAB set afterwards means every later "transmit" write lands
  !!     in the divisor latch instead, and not one byte is ever sent.  Step 5
  !!     clears it in the same write that sets 8N1, which is why the line
  !!     format and the DLAB clear are one operation and not two.
  !!   * flushing the FIFOs before the probe rather than after it leaves the
  !!     0xAE sitting in the receive FIFO, where the first real read after
  !!     boot finds it.  Hence step 12: the CLEAR bits are self-clearing
  !!     one-shots, so re-writing the same FCR value is what discards it.
  !!
  !! THE SEQUENCE ALWAYS RUNS TO COMPLETION, INCLUDING AFTER A TIMEOUT.  It
  !! would be natural to return early when the THRE poll fails, and it would
  !! be a bug: MCR still has LOOP set at that point, so the port would be left
  !! wired back into itself and every subsequent byte would be swallowed by
  !! the chip rather than reaching the wire.  A failed self-test must still
  !! end with step 13.  The reads in steps 8/10/11 are harmless on a dead
  !! port, and keeping them unconditional also keeps the trace a fixed shape.
  !!
  !! EVERY PORT NUMBER IS `port + <offset>`, NEVER A LITERAL.  A second UART
  !! at 0x2F8 (COM2), or a machine whose firmware relocates COM1, works with
  !! no edit inside any routine in this file.
  !!
  !! THE DRIVER ARMS ITSELF EVEN WHEN THE SELF-TEST FAILED.  serial_base and
  !! serial_ready are set unconditionally at the end.  This is a debug
  !! console: a console that refuses to speak because it doubts itself is
  !! strictly worse than one that speaks into a void, because the void is
  !! where an operator with a QEMU chardev is standing.  The status is
  !! REPORTED to the caller and acted on nowhere here; the one thing this
  !! routine must never do is decide, on the strength of an internal loopback
  !! test, that the human debugging the kernel does not get any output.
  function serial_init(port) result(status) bind(c, name="serial_init")
    implicit none
    integer(c_int32_t), intent(in), value :: port
    integer(c_int32_t)                    :: status
    integer(c_int32_t) :: probe
    logical            :: thre_seen, dr_seen

    ! 1. IER: every interrupt source off, first and before anything else.
    !    There is no IDT (roadmap 3.2); one UART IRQ here is a triple fault.
    call fk_outb(port + UART_IER, 0_c_int32_t)

    ! 2. LCR: DLAB=1, which swaps the divisor latch into offsets 0 and 1.
    call fk_outb(port + UART_LCR, UART_LCR_DLAB)

    ! 3-4. Divisor = 1 -> 115200 baud.  Low byte then high byte; the latch is
    !      not read by the transmitter until DLAB drops, so no intermediate
    !      value is ever used as a rate.
    call fk_outb(port + UART_DLL, FK_DIVISOR_LO)
    call fk_outb(port + UART_DLM, FK_DIVISOR_HI)

    ! 5. LCR: 8 data bits, no parity, 1 stop bit -- and DLAB back to 0 in the
    !    same write, which is what re-exposes TX/RX/IER at offsets 0 and 1.
    call fk_outb(port + UART_LCR, UART_LCR_WLEN8)

    ! 6. FCR: FIFOs on and both flushed.  0xC7.
    call fk_outb(port + UART_FCR, FK_FCR_SETUP)

    ! 7. MCR: internal loopback for the self-test that follows.  0x1E.
    call fk_outb(port + UART_MCR, FK_MCR_SELFTEST)

    ! 8-11. The probe.  Wait for the transmit holding register to be empty,
    !       write 0xAE, wait for the receiver to report data ready, read it
    !       back.  With LOOP set the byte never leaves the chip.
    thre_seen = lsr_wait(port, UART_LSR_THRE)
    call fk_outb(port + UART_TX, FK_PROBE_BYTE)
    dr_seen   = lsr_wait(port, UART_LSR_DR)
    probe     = fk_inb(port + UART_RX)

    ! 12. FCR again: discard whatever the probe left in the receive FIFO.
    call fk_outb(port + UART_FCR, FK_FCR_SETUP)

    ! 13. MCR: loopback off, DTR/RTS asserted -- the port is now live.
    call fk_outb(port + UART_MCR, FK_MCR_LIVE)

    ! An integer comparison against a zero-extended read: see the ABI note in
    ! the file header for why fk_inb must not sign-extend.
    if (thre_seen .and. dr_seen .and. probe == FK_PROBE_BYTE) then
       status = 0_c_int32_t
    else
       status = 1_c_int32_t
    end if

    serial_base  = port
    serial_ready = .true.
  end function serial_init

  !> Write one byte to the console.  Raw: no translation of any kind.
  !!
  !! c   the byte to send, BY VALUE (a length-1 c_char, i.e. a C `char`)
  !!
  !! NO NEWLINE POLICY LIVES HERE, deliberately.  Linux puts the LF -> CR LF
  !! translation one layer up, in arch/x86/boot/tty.c's putchar(), and this
  !! module does the same: the caller supplies CR LF (see FK_BANNER in
  !! src/boot/fk_kmain.f90).  A driver that rewrites the bytes it is given
  !! cannot be used to send anything that is not text, and a hex dump of a
  !! page table is the first thing roadmap 3.5 will want to send.
  !!
  !! A DROPPED BYTE IS THE FAILURE MODE, AND IT IS THE RIGHT ONE.  If THRE
  !! never appears within FK_SERIAL_TX_SPINS the character is discarded and
  !! the routine returns.  There is no error to report to -- roadmap 1.4's
  !! panic handler does not exist, and if it did, it would want to print.
  !! Losing a character of debug output is recoverable; hanging the machine
  !! inside the only instrument that could explain the hang is not.
  !!
  !! Writing while serial_ready is .false. is a silent no-op rather than a
  !! fault: at that point serial_base is 0, and `outb` to port 0x0 on a PC
  !! reaches the DMA controller's address register.
  subroutine serial_print_char(c) bind(c, name="serial_print_char")
    implicit none
    character(kind=c_char), intent(in), value :: c

    if (.not. serial_ready) return
    if (.not. lsr_wait(serial_base, UART_LSR_THRE)) return

    ! iachar, not ichar: ASCII by definition regardless of the processor's
    ! collating sequence, and 0..255 so fk_outb never receives a negative
    ! number.  Both are inline byte operations -- neither is a libgfortran
    ! call, unlike a character comparison.
    call fk_outb(serial_base + UART_TX, iachar(c, c_int32_t))
  end subroutine serial_print_char

  !> Write a NUL-terminated C string to the console.
  !!
  !! s   the string, as a C `const char *`
  !!
  !! ASSUMED-SIZE, NEVER s(:).  An assumed-shape dummy makes gfortran expect a
  !! CFI_cdesc_t descriptor where C (or a Fortran scalar passed by sequence
  !! association) supplied a bare pointer, and the callee then reads the
  !! string's own bytes as a descriptor header.  See docs/AUDIT-PHASE1.md,
  !! "On hidden array descriptors", and vga_print_string in
  !! src/drivers/video/fk_gop_renderer.f90, which is dummy-for-dummy the same
  !! shape for the same reason.
  !!
  !! THE TERMINATOR IS FOUND WITH iachar(s(i)) == 0, NOT s(i) == c_null_char.
  !! The character comparison is the obvious spelling and it is banned here:
  !! gfortran lowers character relationals to _gfortran_compare_string, a
  !! libgfortran symbol, and tools/linktest.sh gate (c) fails the build the
  !! moment one appears.  The integer compare is a byte load and a test.
  !!
  !! THE 4096 BOUND IS NOT DEFENSIVE PADDING.  Without it, a caller that lost
  !! its terminator walks memory until something faults -- and with no IDT
  !! (roadmap 3.2) a fault is a triple fault and a silent reboot, i.e. the
  !! kernel would appear to crash in the middle of printing.  With it, the
  !! same bug produces a truncated line, which is a diagnosis rather than a
  !! mystery.
  !!
  !! ASYMMETRY WITH THE SIBLING CONSOLE, stated so nobody has to wonder:
  !! vga_print_string(s, max_chars, ...) takes its bound as an argument, this
  !! one takes it as a private constant.  That is because roadmap 2.1 fixes
  !! the interface as serial_print_string(str) -- the C prototype is
  !! `void serial_print_string(const char *)`, matching every other early
  !! console -- and because every caller today is a compile-time banner whose
  !! length is known to be far under 4096.  If a caller ever needs to print a
  !! bounded slice of a buffer that may not be NUL-terminated, that wants a
  !! second entry point, not a widened one.
  subroutine serial_print_string(s) bind(c, name="serial_print_string")
    implicit none
    character(kind=c_char), intent(in) :: s(*)
    integer(c_int32_t) :: i

    if (.not. serial_ready) return

    do i = 1_c_int32_t, FK_SERIAL_MAX_STRING
       if (iachar(s(i), c_int32_t) == 0_c_int32_t) return
       call serial_print_char(s(i))
    end do
  end subroutine serial_print_string

end module fk_serial_m
