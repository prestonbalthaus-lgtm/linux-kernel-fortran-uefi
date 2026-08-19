#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Read the kernel's boot sentinel out of a running guest, and assert it.

THE PROBLEM THIS SOLVES

A kernel that triple-faults on its first instruction and a kernel that reaches
Fortran correctly look identical from outside the VM: both produce a machine
that sits there doing nothing. This milestone has no console to print to -- the
UEFI target has no 0xB8000 text mode, the serial driver is roadmap 2.1 and the
framebuffer handover is 2.2 -- so the boot must be proven some other way.

src/boot/fk_kmain.f90 writes four 32-bit words into .data at a link-time-fixed
address. This tool talks QMP to a RUNNING QEMU, pulls those sixteen bytes out
of guest PHYSICAL memory with the HMP 'pmemsave' command, and asserts all four.

The fourth word is what makes this a proof rather than a plausibility argument:
it is TAG xor magic, computed by Fortran at run time from a value the Fortran
side never sees at compile time. Constant stores cannot fake it, and neither
can a stale dump from a previous run.

It launches nothing. tools/qemu-boot-test.sh owns the VM lifecycle; this owns
the wire protocol and the assertion. The QmpClient below is carried over from
the sibling tree's tools/qmp-vga-dump.py, including its two hard-won gotchas
(interleaved async events, and the HMP argument parser eating '/' in paths).

Subcommands
    addr      print the PHYSICAL address of a symbol in the kernel ELF
    dump      connect to a QMP socket, pmemsave the sentinel to a file
    quit      shut the guest down gracefully
    check     assert the sentinel contract against a 16-byte dump
    hwstate   assert the TASK REGISTER and the two 8259s against the device
              models, via 'info registers' and 'info pic'
    ticks     read fk_tick_count out of the running guest TWICE and assert it
              advanced in between (roadmap 3.2b)
    dma       read the contiguous run at the PHYSICAL base the kernel
              published, and assert every frame carries its own tag
              (roadmap 3.x)
    pci       compare the guest's own enumeration against 'info pci', as
              SETS, so a device missed and a device invented both fail
              (roadmap 4.2)
    selftest  prove every assertion PASSES on synthetic good input and FAILS on
              every corrupted one -- no QEMU and no kernel required

WHY hwstate EXISTS SEPARATELY FROM THE SERIAL GREP

The kernel's own console can only report what the kernel believes. A PIC whose
ICW2 was never written is invisible to it -- the mask readback still says 0xFF,
because masking works whatever the vector base is -- and so is a task register
loaded with the wrong selector, up until the #DF that needs it. QEMU's monitor
reports what the i8259 and the CPU's hidden descriptor cache actually hold, so
those two facts are asserted there and not on COM1.

WHY ticks EXISTS SEPARATELY FROM EITHER

The kernel prints a tick count it read itself, which proves an interrupt was
taken and returned from at some point BEFORE that line was printed. It cannot
prove the machine is still doing it, because a kernel that printed the line and
then wedged looks identical on COM1. Two reads of the same guest memory, taken
from outside while the guest runs, is the only form that assertion can take --
and the counter has to be advancing under a CPU that is parked in HLT, which
means an interrupt woke it, a handler ran, and IRETQ put it back to sleep.

Stdlib only. Runs on the host; never inside the guest.
"""

import argparse
import errno
import json
import os
import re
import socket
import struct
import sys
import tempfile
import time

# --- the sentinel contract (mirrors src/boot/fk_kmain.f90) -----------------
SENTINEL_SYMBOL = "fk_boot_sentinel"
SENTINEL_WORDS = 4
SENTINEL_BYTES = SENTINEL_WORDS * 4

FK_BOOT_TAG = 0x4B424F54            # "KBOT"
MB2_BOOTLOADER_MAGIC = 0x36D76289   # what a compliant loader leaves in EAX
FK_UNWRITTEN = 0x11111111           # the .data initialiser: "never ran"

# --- the hardware contract (mirrors src/cpu/fk_tss.f90 and fk_pic.f90) ------
TSS_SYMBOL = "fk_tss"               # bind(c), so the name survives gfortran
DF_STACK_SYMBOL = "fk_df_stack"     # likewise; its st_size gives the IST1 top
TSS_LIMIT = 0x67                    # 104 bytes - 1, the architectural minimum
GDT_LIMIT = 0x27                    # 5 slots: null, code, data, TSS lo, TSS hi

# roadmap 3.2b. bind(c) in src/drivers/pit/fk_pit.f90, so the name survives.
TICK_SYMBOL = "fk_tick_count"
TICK_BYTES = 8
# Every line masked on BOTH chips, and as of roadmap 3.3 that is the milestone
# rather than the absence of one. 3.2b moved the master to 0xFE because a
# masked-everything chip meant the timer had never been let through; 3.3 gives
# the timer to the IOAPIC instead, so 0xFF is once again the correct answer --
# and this time it is asserted alongside an unmasked IOAPIC redirection entry
# and a tick counter that is still advancing, which is what tells the two
# states apart.
MASTER_IMR = 0xFF
SLAVE_IMR = 0xFF

# roadmap 4.2. bind(c) in src/boot/fk_kmain.f90.
# [0] magic [1] ECAM phys [2] bus range lo<<8|hi [3] kept [4] seen
# then one packed word per function: bdf<<48 | vendor<<32 | device<<16 |
# class<<8 | subclass.
PCI_SYMBOL = "fk_pcie_devs"
PCI_SLOTS = 32
# 5 header words, the function slots, then roadmap 4.2's debt paid for 5.1:
# the xHCI's BDF, the COMMAND it read back after the enable, the MSI-X triple
# and BAR0.
PCI_W_XHCI = PCI_SLOTS + 5
PCI_WORDS = PCI_SLOTS + 12
# COMMAND bits: memory-space decode and bus master (pci_regs.h:42-43).
PCI_CMD_MEMORY = 1 << 1
PCI_CMD_MASTER = 1 << 2
PCI_CMD_INTX_DISABLE = 1 << 10
# Message control, in the high half of the dword at the capability.
PCI_MSIX_ENABLE = 1 << 31
PCI_MSIX_MASKALL = 1 << 30
# roadmap 5.1: what the kernel programs into entry 0.
MSI_ADDR_CPU0 = 0xFEE00000
MSI_VECTOR = 0x30
XHCI_CLASS_TEXT = "USB controller"
PCI_MAGIC = 0x5043494501

# roadmap 3.3. 'info pic' prints the IOAPIC's whole 24-entry redirection table
# above the two pic lines, on the default machine and on q35 alike:
#   pin 2  0x0000000000000020 dest=0 vec=32  active-hi edge   fixed  physical
# The GSI the PIT was overridden to, and the vector the IDT installed for it.
IOAPIC_GSI = 2
IOAPIC_VECTOR = 0x20

# roadmap 2.2/2.4. bind(c) in src/drivers/video/fk_fbinfo.f90: ten u64 words
# describing the framebuffer the LOADER reported and the mapping the VMM built.
FB_SYMBOL = "fk_fb_info"
FB_WORDS = 10
FB_BYTES = FB_WORDS * 8
FB_MAGIC = 0x46425F49               # "FB_I", written only on a clean probe
FB_VIRT_WANT = 0xFFFF808000000000   # FK_VMM_MMIO in src/mm/fk_vmm.f90
FB_BAR_H = 16                       # FK_FB_BAR_H in src/boot/fk_kmain.f90
FB_BLOCK = 64                       # the width of one primary in the bar
FONT_H = 16                         # FONT_H in src/drivers/video/fk_font_8x16.f90
# The console's own colours, from src/boot/fk_kmain.f90. Carried as RGB and
# packed here through the loader's masks, exactly as the kernel packs them --
# a literal pixel word would agree with a kernel that ignored the masks.
CON_FG_RGB = (208, 224, 208)
CON_BG_RGB = (0, 16, 32)
# How many lit glyph pixels a row of text must contain before it counts as
# text. One would be satisfied by a stray write; a whole line of 8x16 glyphs
# lights hundreds.
CON_MIN_GLYPH_PX = 64
# How many text rows at the bottom of the screen the panic assertion reads.
# TWO, not one: every line the handler prints ends in CRLF, so the cursor is
# always parked on a freshly cleared row and the bottom line of a finished
# panic is blank by construction.
PANIC_TAIL_ROWS = 2
# roadmap 2.4's glyph-identity check. The kernel draws this string into the
# status bar at a fixed cell, in yellow, and never scrolls it. The expected
# pixels are rendered here from the kernel's OWN font table, read out of guest
# memory -- so this compares what the renderer drew against what the font says,
# and not against a picture somebody transcribed.
FONT_SYMBOL = "__fk_font_8x16_m_MOD_font_8x16"
FONT_BYTES = 4096
FONT_W = 8
FB_SIG = b"FK-GOP 2.4"
FB_SIG_X = 256
FB_SIG_RGB = (255, 255, 0)

# roadmap 4.0. bind(c) in src/cpu/fk_sched.f90 and src/mm/fk_heap.f90.
SCHED_SYMBOL = "fk_sched_state"
SCHED_WORDS = 4
RUNS_SYMBOL = "fk_task_runs"
RUNS_TASKS = 4
SCHED_MAGIC = 0x5343484544000001
HEAP_SYMBOL = "fk_heap_stat"
HEAP_WORDS = 10
HEAP_MAGIC = 0x4B48454150000001
STACKS_SYMBOL = "fk_task_stacks"
SCHED_STACK_QWORDS = 2048            # FK_SCHED_STACK_QWORDS in fk_sched.f90

# roadmap 3.x. bind(c) in src/boot/fk_kmain.f90.
# [0] magic  [1] phys base  [2] pages  [3] tag seed
DMA_SYMBOL = "fk_dma_probe"
DMA_WORDS = 4

# roadmap 5.1.
XHCI_SYMBOL = "fk_xhci_state"
XHCI_WORDS = 19
MSI_SYMBOL = "fk_msi_count"
XHCI_MAGIC = 0x584843490501
KBD_SYMBOL = "fk_usbkbd_state"
KBD_WORDS = 24
KBD_MAGIC = 0x55534B420502
SLOT_STATE_ADDRESSED = 2
SLOT_STATE_CONFIGURED = 3
# usb-kbd on qemu-xhci enumerates at high speed -- measured off `info usb`,
# 480 Mb/s -- so PORTSC speed id 3 and a 64-byte EP0. Super speed is allowed
# because the code allows it; full and low speed are refused by the kernel.
KBD_SPEEDS = {3: 64, 4: 512, 5: 512}
TRB_TYPE_CMD_NOOP = 23
TRB_TYPE_COMPLETION = 33
COMP_SUCCESS = 1
DMA_MAGIC = 0x444D4143
DMA_PAGE = 4096
DMA_MAX_PAGES = 64                   # a sanity ceiling on what will be read
# The panic colours, from src/cpu/fk_idt.f90 by way of idt_set_panic_colors.
PANIC_FG_RGB = (255, 255, 255)
PANIC_BG_RGB = (170, 0, 0)


class QmpError(Exception):
    """Anything that went wrong on the QMP wire or in the guest monitor."""


class QmpClient:
    """Newline-delimited-JSON QMP client with a hard overall deadline.

    Nothing here assumes one recv() yields one whole message, or that the reply
    to a command is the next message to arrive -- QEMU interleaves asynchronous
    events (RESET, SHUTDOWN, ...) with command replies, so every command is
    id-tagged and non-matching messages are skipped.
    """

    def __init__(self, path, deadline):
        self.path = path
        self.deadline = deadline          # absolute time.monotonic() value
        self.sock = None
        self.buf = b""
        self._next_id = 0

    def _remaining(self, what):
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise QmpError(f"timed out ({what}): guest is hung or never opened "
                           "the QMP socket")
        return left

    def connect(self):
        """Retry until the socket exists AND accepts -- 'server,nowait' means
        QEMU creates it asynchronously, so an early connect legitimately fails
        with ENOENT/ECONNREFUSED."""
        while True:
            self._remaining(f"connecting to {self.path}")
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                s.settimeout(min(2.0, max(0.1, self.deadline - time.monotonic())))
                s.connect(self.path)
                self.sock = s
                return
            except OSError as exc:
                s.close()
                if exc.errno not in (errno.ENOENT, errno.ECONNREFUSED,
                                     errno.EAGAIN, errno.EINTR):
                    raise QmpError(f"cannot connect to {self.path}: {exc}")
                time.sleep(0.1)

    def close(self):
        if self.sock is not None:
            try:
                self.sock.close()
            finally:
                self.sock = None

    def recv_message(self):
        """One JSON object, or None on clean EOF."""
        while True:
            nl = self.buf.find(b"\n")
            if nl >= 0:
                line, self.buf = self.buf[:nl], self.buf[nl + 1:]
                line = line.strip()
                if not line:
                    continue
                try:
                    return json.loads(line.decode("utf-8", "replace"))
                except ValueError as exc:
                    raise QmpError(f"malformed JSON from QMP: {line[:200]!r} ({exc})")
            self.sock.settimeout(self._remaining("waiting for a QMP message"))
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                raise QmpError("timed out waiting for a QMP message (guest hung?)")
            if not chunk:
                tail, self.buf = self.buf.strip(), b""
                if tail:
                    try:
                        return json.loads(tail.decode("utf-8", "replace"))
                    except ValueError:
                        pass
                return None
            self.buf += chunk

    def send(self, obj):
        data = (json.dumps(obj) + "\r\n").encode("utf-8")
        self.sock.settimeout(self._remaining("sending a QMP command"))
        self.sock.sendall(data)

    def execute(self, command, arguments=None):
        self._next_id += 1
        cid = f"fk-{self._next_id}"
        req = {"execute": command, "id": cid}
        if arguments:
            req["arguments"] = arguments
        self.send(req)
        while True:
            msg = self.recv_message()
            if msg is None:
                raise QmpError(f"QMP connection closed while awaiting the reply "
                               f"to {command!r}")
            if "event" in msg or msg.get("id") != cid:
                continue                          # async event / someone else's
            if "error" in msg:
                err = msg["error"]
                raise QmpError(f"QMP command {command!r} failed: "
                               f"{err.get('class', '?')}: {err.get('desc', '?')}")
            return msg.get("return")

    def handshake(self):
        msg = self.recv_message()
        if msg is None or "QMP" not in msg:
            raise QmpError(f"no QMP greeting (got {msg!r}) -- is this really a "
                           "QMP socket?")
        self.execute("qmp_capabilities")

    def hmp(self, command_line):
        """Run a human-monitor command.

        GOTCHA: HMP errors do NOT come back as QMP errors. The command succeeds
        at the QMP level and the human-readable complaint arrives as the
        'return' STRING. Silently ignoring a non-empty return here is how a gate
        ends up asserting against a stale dump file.
        """
        out = self.execute("human-monitor-command", {"command-line": command_line})
        out = out or ""
        if out.strip():
            raise QmpError(f"monitor command {command_line!r} reported: {out.strip()}")
        return out

    def hmp_query(self, command_line):
        """Run a human-monitor command whose OUTPUT is the point.

        hmp() above treats any non-empty return as a failure, which is correct
        for a command that only ever speaks to complain (pmemsave) and exactly
        wrong for one whose whole job is to print. The two are separate methods
        rather than one flag so that no caller can get the distinction wrong.
        """
        return self.execute("human-monitor-command",
                            {"command-line": command_line}) or ""

    def pmemsave(self, addr, size, path):
        """Dump guest PHYSICAL memory to a host file.

        GOTCHA (verified empirically on QEMU 10.2): the HMP argument parser
        evaluates unquoted arguments as arithmetic expressions, and '/' is the
        division operator -- so an absolute path comes back as
            invalid char 't' in expression        ("/tmp/..." -> '/' then 't')
        Quoting routes it through the monitor's string parser instead. The
        unquoted form is retried anyway so this gate is not hostage to one
        QEMU's parser.
        """
        if any(c in path for c in '"\\\n\r') or not path.strip():
            raise QmpError("refusing to pmemsave to a path containing quotes, "
                           f"backslashes or newlines: {path!r}")
        try:
            return self.hmp(f'pmemsave 0x{addr:x} {size} "{path}"')
        except QmpError as first:
            try:
                return self.hmp(f'pmemsave 0x{addr:x} {size} {path}')
            except QmpError:
                raise first

    def quit(self):
        """Ask the guest to exit. EOF instead of a reply is normal here."""
        try:
            self.execute("quit")
        except QmpError as exc:
            if "closed" not in str(exc):
                raise


# st_size of whatever symbol_phys_addr last resolved. The ELF carries it and
# the reader was already unpacking it; the IST1 assertion needs it to know
# where the top of the emergency stack is.
SYMBOL_SIZE = {}


# --- ELF: symbol -> physical address ---------------------------------------
def symbol_phys_addr(elf_path, name):
    """Physical address of a symbol in a higher-half kernel image.

    Deliberately derived from the PT_LOAD that contains the symbol rather than
    from a hardcoded KERNEL_VMA: the VMA-to-LMA relationship is a property of
    linker.ld, and reading it back out of the image is what makes this tool
    tell the truth if that script ever changes.
    """
    d = open(elf_path, "rb").read()
    if d[:4] != b"\x7fELF" or d[4] != 2:
        raise SystemExit(f"{elf_path}: not an ELF64 image")
    e_shoff, = struct.unpack_from("<Q", d, 40)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", d, 58)
    e_phoff, = struct.unpack_from("<Q", d, 32)
    e_phentsize, e_phnum = struct.unpack_from("<HH", d, 54)

    loads = []
    for i in range(e_phnum):
        p_type, _fl, _off, vaddr, paddr, filesz, memsz = struct.unpack_from(
            "<IIQQQQQ", d, e_phoff + i * e_phentsize)
        if p_type == 1:
            loads.append((vaddr, paddr, memsz))

    sections = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        sh_name, sh_type, _flags, _addr, sh_offset, sh_size, sh_link, _info, \
            _align, sh_entsize = struct.unpack_from("<IIQQQQIIQQ", d, off)
        sections.append((sh_name, sh_type, sh_offset, sh_size, sh_link, sh_entsize))

    for sh_name, sh_type, sh_offset, sh_size, sh_link, sh_entsize in sections:
        if sh_type != 2:                       # SHT_SYMTAB
            continue
        stroff = sections[sh_link][2]
        for p in range(sh_offset, sh_offset + sh_size, sh_entsize or 24):
            st_name, _info, _other, _shndx, st_value, st_size = \
                struct.unpack_from("<IBBHQQ", d, p)
            end = d.index(b"\0", stroff + st_name)
            if d[stroff + st_name:end].decode() == name:
                for vaddr, paddr, memsz in loads:
                    if vaddr <= st_value < vaddr + memsz:
                        SYMBOL_SIZE[name] = st_size
                        return st_value, st_value - vaddr + paddr
                raise SystemExit(f"{name} is at 0x{st_value:X}, outside every "
                                 "PT_LOAD -- it will not exist in guest memory")
    raise SystemExit(f"{name} not found in {elf_path}: is the boot object linked in?")


# --- the assertion ---------------------------------------------------------
def decode(data):
    if len(data) != SENTINEL_BYTES:
        raise SystemExit(f"sentinel dump is {len(data)} bytes, expected {SENTINEL_BYTES}")
    return list(struct.unpack("<4I", data))


def check_sentinel(words):
    """Return a list of (ok, description) -- the whole contract, in order."""
    tag, magic, mbi, computed = words
    expect_xor = (FK_BOOT_TAG ^ MB2_BOOTLOADER_MAGIC) & 0xFFFFFFFF
    never_ran = all(w == FK_UNWRITTEN for w in words)
    return [
        (not never_ran,
         "kernel_main ran at all (sentinel is not still the .data initialiser "
         f"0x{FK_UNWRITTEN:08X})"),
        (tag == FK_BOOT_TAG,
         f"word 0 is the boot tag 0x{FK_BOOT_TAG:08X} 'KBOT'  (got 0x{tag:08X})"),
        (magic == MB2_BOOTLOADER_MAGIC,
         f"word 1 is the Multiboot2 loader magic 0x{MB2_BOOTLOADER_MAGIC:08X}  "
         f"(got 0x{magic:08X})"),
        (mbi not in (0, FK_UNWRITTEN),
         f"word 2 is a plausible MBI pointer, non-zero  (got 0x{mbi:08X})"),
        (computed == expect_xor,
         f"word 3 is TAG xor magic = 0x{expect_xor:08X}, computed by Fortran at "
         f"run time  (got 0x{computed:08X})"),
    ]


def report(words, quiet=False):
    results = check_sentinel(words)
    failed = [d for ok, d in results if not ok]
    if not quiet:
        print("  sentinel words: " + " ".join(f"0x{w:08X}" for w in words))
        for ok, desc in results:
            print(f"  {'\033[32mPASS\033[0m' if ok else '\033[31mFAIL\033[0m'}  {desc}")
    if failed and quiet:
        for d in failed:
            print(f"  FAIL  {d}")
    return not failed



# --- hardware state: what the DEVICE MODELS hold, not what the kernel says ---
# Formats verified against QEMU 10.2.2 output, not against documentation:
#   TR =0018 ffffffff80105020 00000067 00008b00 DPL=0 TSS64-busy
#   GDT=     ffffffff80104020 00000027
#   pic0: irr=01 imr=ff isr=00 hprio=0 irq_base=20 rr_sel=0 elcr=00 fnm=0
TR_RE = re.compile(r"^TR =([0-9a-fA-F]+) ([0-9a-fA-F]+) ([0-9a-fA-F]+) "
                   r"([0-9a-fA-F]+)(.*)$", re.M)
GDT_RE = re.compile(r"^GDT=\s+([0-9a-fA-F]+) ([0-9a-fA-F]+)", re.M)
PIC_RE = re.compile(r"^pic([01]):.*?\bimr=([0-9a-fA-F]{2})\b.*?"
                    r"\birq_base=([0-9a-fA-F]{2})\b", re.M)
#   pin 2  0x0000000000010000 dest=0 vec=0   active-hi edge  masked fixed  physical
# The tail is free-form words; "masked" is present exactly when the entry is.
IOAPIC_PIN_RE = re.compile(r"^\s*pin\s+(\d+)\s+0x([0-9a-fA-F]+)\s+"
                           r"dest=(\d+)\s+vec=(\d+)\s*(.*)$", re.M)


def check_hwstate(regs_text, pic_text, tss_vaddr, tss_bytes=None,
                  ist1_want=None,
                  tr_sel=0x18, tss_limit=TSS_LIMIT, gdt_limit=GDT_LIMIT,
                  master=0x20, slave=0x28,
                  master_imr=MASTER_IMR, slave_imr=SLAVE_IMR,
                  ioapic_gsi=IOAPIC_GSI, ioapic_vector=IOAPIC_VECTOR):
    """Assert the CPU's and the 8259s' state. Returns [(ok, description)].

    Every check names the value it SAW, because a gate that only says which
    assertion failed sends the reader back to the monitor to find out why.
    """
    out = []

    m = TR_RE.search(regs_text)
    if not m:
        out.append((False, "'info registers' printed no TR line at all"))
    else:
        sel, base, limit, tail = (int(m.group(1), 16), int(m.group(2), 16),
                                  int(m.group(3), 16), m.group(5))
        out.append((sel == tr_sel,
                    f"task register selector is 0x{sel:04X} "
                    f"(want 0x{tr_sel:04X}) -- LTR ran"))
        out.append((base == tss_vaddr,
                    f"TR base 0x{base:016X} is the address of {TSS_SYMBOL} "
                    f"in the ELF (0x{tss_vaddr:016X})"))
        out.append((limit == tss_limit,
                    f"TR limit is 0x{limit:X} (want 0x{tss_limit:X}, "
                    f"i.e. {tss_limit + 1} bytes of TSS)"))
        # LTR flips the descriptor's type from 9 (available) to B (busy), so
        # this word is also evidence that the load happened rather than that
        # the table merely contains something plausible.
        out.append(("TSS64-busy" in tail,
                    f"the descriptor TR loaded reads as a busy 64-bit TSS "
                    f"({tail.strip() or 'nothing printed'})"))

    m = GDT_RE.search(regs_text)
    if not m:
        out.append((False, "'info registers' printed no GDT line at all"))
    else:
        limit = int(m.group(2), 16)
        out.append((limit == gdt_limit,
                    f"GDT limit is 0x{limit:X} (want 0x{gdt_limit:X}) -- the "
                    f"table is long enough for a 16-byte TSS descriptor"))

    # The TSS BODY, read out of guest memory. 'info registers' reports the
    # descriptor -- base, limit, type -- and says nothing about the 104 bytes it
    # points at. iomap_base is the field with no other witness: nothing in ring
    # 0 consults it, so a wrong value is invisible until the first ring-3
    # process (roadmap 7.1) gets an I/O permission bitmap made of whatever the
    # TSS's own bytes happen to say.
    if tss_bytes is not None:
        if len(tss_bytes) != TSS_LIMIT + 1:
            out.append((False, f"read {len(tss_bytes)} bytes of TSS, "
                               f"expected {TSS_LIMIT + 1}"))
        else:
            iomap, = struct.unpack_from("<H", tss_bytes, 0x66)
            out.append((iomap == TSS_LIMIT + 1,
                        f"TSS I/O map base is 0x{iomap:04X} (want "
                        f"0x{TSS_LIMIT + 1:04X}: past the limit, so ring 3 gets "
                        f"no bitmap)"))
            ist1, = struct.unpack_from("<Q", tss_bytes, 0x24)
            if ist1_want is None:
                out.append((ist1 != 0,
                            f"TSS IST1 at offset 0x24 holds 0x{ist1:016X}"))
            else:
                # Exactly the top, not merely "somewhere sensible": IST1 aimed
                # at the BOTTOM of the same array is a plausible-looking value
                # that makes the CPU push into whatever .bss put underneath.
                out.append((ist1 == ist1_want,
                            f"TSS IST1 is 0x{ist1:016X}, the top of "
                            f"fk_df_stack (0x{ist1_want:016X})"))

    pics = {int(g[0]): (int(g[1], 16), int(g[2], 16))
            for g in PIC_RE.findall(pic_text)}
    for idx, want_base, want_imr, who in ((0, master, master_imr, "master"),
                                          (1, slave, slave_imr, "slave")):
        if idx not in pics:
            out.append((False, f"'info pic' printed no pic{idx} line at all"))
            continue
        imr, base = pics[idx]
        out.append((base == want_base,
                    f"8259 {who} vector base is 0x{base:02X} "
                    f"(want 0x{want_base:02X})"))
        out.append((imr == want_imr,
                    f"8259 {who} IMR is 0x{imr:02X} (want 0x{want_imr:02X})"))

    # roadmap 3.3. The kernel's own console can say it wrote a redirection
    # entry, and an IOAPIC that ignored the write says exactly the same thing.
    # This is the device model's answer.
    pins = {int(g[0]): (int(g[1], 16), int(g[2]), int(g[3]), g[4])
            for g in IOAPIC_PIN_RE.findall(pic_text)}
    if not pins:
        out.append((False, "'info pic' printed no IOAPIC redirection table"))
    elif ioapic_gsi not in pins:
        out.append((False, f"'info pic' printed no pin {ioapic_gsi} "
                           f"(saw {len(pins)} pins)"))
    else:
        raw, dest, vec, tail = pins[ioapic_gsi]
        out.append((vec == ioapic_vector,
                    f"IOAPIC pin {ioapic_gsi} delivers vector {vec} "
                    f"(want {ioapic_vector} = 0x{ioapic_vector:02X}, the IDT's "
                    f"IRQ0 stub)"))
        out.append((dest == 0,
                    f"IOAPIC pin {ioapic_gsi} is aimed at APIC id {dest} "
                    "(want 0: the bootstrap processor)"))
        out.append(("masked" not in tail,
                    f"IOAPIC pin {ioapic_gsi} is unmasked ({tail.strip()})"))
        # EVERY OTHER PIN, and not as tidiness: an IOAPIC left with a second
        # line open delivers a vector nothing installed a gate for, and the
        # CPU's answer to that is a fault raised from inside delivery.
        loose = [n for n, (_r, _d, _v, t) in sorted(pins.items())
                 if n != ioapic_gsi and "masked" not in t]
        out.append((not loose,
                    f"every other IOAPIC pin is masked ({len(pins)} pins)"
                    if not loose else
                    f"IOAPIC pin(s) {loose} are unmasked and nothing routed them"))
    return out


# roadmap 3.2b. Two reads of one 64-bit counter, taken while the guest runs.
def check_ticks(first, second, min_delta=2):
    """Assert the guest is STILL taking timer interrupts. [(ok, description)]."""
    out = []
    out.append((first > 0,
                f"the guest had taken {first} timer interrupts when it was "
                f"first read"))
    # Not >= first: a counter that is merely not going backwards is what a
    # wedged kernel produces too. The delta is the whole assertion.
    out.append((second - first >= min_delta,
                f"it took {second - first} more between the two reads "
                f"(want >= {min_delta}) -- the CPU is still returning from "
                f"them"))
    return out


def report_hwstate(results, quiet=False):
    failed = [d for ok, d in results if not ok]
    for ok, desc in results:
        if quiet and ok:
            continue
        tag = "\033[32mPASS\033[0m" if ok else "\033[31mFAIL\033[0m"
        print(f"  {tag}  {desc}")
    return not failed


# --- subcommands -----------------------------------------------------------
# --- roadmap 2.2/2.4: the framebuffer, read out of the guest ---------------

def fb_decode(data):
    if len(data) != FB_BYTES:
        raise SystemExit(f"fb_info dump is {len(data)} bytes, expected {FB_BYTES}")
    w = list(struct.unpack("<10Q", data))
    masks = w[7]
    return {
        "tag": w[0], "base": w[1], "pitch": w[2], "width": w[3],
        "height": w[4], "bpp": w[5], "type": w[6], "virt": w[8], "bytes": w[9],
        "r_pos": masks & 0xFF, "r_size": (masks >> 8) & 0xFF,
        "g_pos": (masks >> 16) & 0xFF, "g_size": (masks >> 24) & 0xFF,
        "b_pos": (masks >> 32) & 0xFF, "b_size": (masks >> 40) & 0xFF,
    }


def fb_pack(info, r, g, b):
    """The host's own model of fb_pixel_pack(), from the masks the LOADER gave.

    Deliberately not a constant: the point of the assertion is that the kernel
    packed the channels the way the firmware asked for, and a hardcoded
    0x00FF0000 would agree with a kernel that ignored the masks and got lucky
    on this machine.
    """
    def chan(v, pos, siz):
        if siz <= 0:
            return 0
        return ((v & 0xFF) >> (8 - siz)) << pos
    return (chan(r, info["r_pos"], info["r_size"])
            | chan(g, info["g_pos"], info["g_size"])
            | chan(b, info["b_pos"], info["b_size"])) & 0xFFFFFFFF


FB_BAR = [("red", (255, 0, 0)), ("green", (0, 255, 0)),
          ("blue", (0, 0, 255)), ("white", (255, 255, 255))]


def check_signature(info, band, font):
    """Compare the status-bar signature against the kernel's own font table.

    The renderer walks each font byte MSB FIRST -- bit 7 is the leftmost pixel
    -- and composes the glyph over whatever is already there, so a clear bit
    means "unchanged", never "background". Reading the table LSB-first mirrors
    every glyph, which is a defect no lit-pixel count can see.
    """
    if font is None or len(font) < FONT_BYTES:
        return [(False, "the kernel's font table could not be read back")]
    fg = fb_pack(info, *FB_SIG_RGB)
    lit = 0
    wrong = None
    for i, ch in enumerate(FB_SIG):
        for row in range(FONT_H):
            bits = font[ch * FONT_H + row]
            for dx in range(FONT_W):
                on = (bits >> (7 - dx)) & 1
                x = FB_SIG_X + i * FONT_W + dx
                got, = struct.unpack_from("<I", band, row * info["pitch"] + x * 4)
                # BOTH directions. Checking only the lit bits accepts a solid
                # block of the signature colour, which is what a renderer that
                # filled the cell instead of walking the font would leave --
                # and any glyph whose bits are a superset of the right ones.
                if on:
                    lit += 1
                    if got != fg and wrong is None:
                        wrong = (chr(ch), x, row, got, "lit")
                elif got == fg and wrong is None:
                    wrong = (chr(ch), x, row, got, "clear")
    if wrong is not None:
        c, x, y, got, kind = wrong
        return [(False, f"the bar signature is not the font's glyphs: "
                        f"'{c}' wants a {kind} pixel at ({x},{y}) and the "
                        f"framebuffer holds 0x{got:08X} (fg 0x{fg:08X})")]
    return [(True, f"all {lit} lit pixels of \"{FB_SIG.decode()}\" in the "
                   "status bar match the kernel's own font table, glyph for "
                   "glyph")]


def _row(band, info, y):
    off = y * info["pitch"]
    return band[off:off + info["width"] * 4]


def check_framebuffer(info, band, tail=None, font=None, expect="console"):
    """Return a list of (ok, description) -- the whole framebuffer contract.

    BAND is guest memory from the framebuffer base covering the status bar and
    the FIRST row of console text; TAIL is the LAST row of console text.

    Which of the two carries the evidence depends on the build, and not
    arbitrarily.  In the shipped image the console has scrolled several screens,
    so the top row holds text that was pushed up there and the first row is the
    honest place to look.  A panic dump is 26 lines on a 47-row screen: it
    CANNOT reach the top, and asserting there would fail on a kernel whose
    panic handler works perfectly.  The newest output is always at the bottom.
    """
    out = []
    out.append((info["tag"] == FB_MAGIC,
                f"fb_info magic is 0x{info['tag']:08X} "
                f"(want 0x{FB_MAGIC:08X}: the tag-8 probe completed)"))
    out.append((info["type"] == 1 and info["bpp"] == 32,
                f"framebuffer is RGB/32bpp (type {info['type']}, "
                f"bpp {info['bpp']})"))
    out.append((info["width"] > 0 and info["height"] > 0
                and info["pitch"] >= info["width"] * 4,
                f"geometry {info['width']}x{info['height']} pitch "
                f"{info['pitch']} is self-consistent"))
    out.append((info["virt"] == FB_VIRT_WANT,
                f"the VMM mapped it at 0x{info['virt']:016X} "
                f"(want 0x{FB_VIRT_WANT:016X})"))
    out.append((info["base"] != 0 and info["base"] % 4096 == 0,
                f"the loader's base 0x{info['base']:X} is page-aligned"))

    if band is None:
        out.append((False, "no pixels were read back from the framebuffer"))
        return out
    need = (FB_BAR_H + FONT_H) * info["pitch"]
    if len(band) < need:
        out.append((False, f"the pixel dump is {len(band)} bytes, want "
                           f"{need} to cover the bar and one text row"))
        return out

    # Every primary, not just one: a renderer that reached memory but packed
    # the channels wrong writes four DIFFERENT wrong words, and a single-colour
    # check passes on any of them that happens to collide.
    #
    # Row 0 AND the last row of the bar. The console lives immediately below
    # and has scrolled several times by the time this runs, so the bottom row
    # is where a scroll that reached one row too high would show up -- and it
    # would show up as ordinary text, not as corruption.
    for y in (0, FB_BAR_H - 1):
        row = _row(band, info, y)
        for i, (name, rgb) in enumerate(FB_BAR):
            got, = struct.unpack_from("<I", row, (i * FB_BLOCK) * 4)
            want = fb_pack(info, *rgb)
            out.append((got == want,
                        f"pixel ({i * FB_BLOCK},{y}) is 0x{got:08X} "
                        f"(want 0x{want:08X}, {name} packed r@{info['r_pos']} "
                        f"g@{info['g_pos']} b@{info['b_pos']})"))

    out.extend(check_signature(info, band, font))

    # roadmap 2.4: the console drew GLYPHS below the bar, in the colours it was
    # given. Counting foreground pixels rather than "not background" is what
    # separates rendered text from a band the renderer merely filled.
    #
    # A panic build is asserted on the PANIC palette instead. That is the whole
    # point of the mode: the handler repaints in white on red, so a register
    # dump that only reached COM1 leaves the band in the console's own green
    # and is caught here rather than passing as 'there is text on screen'.
    if expect == "panic":
        fg, bg = fb_pack(info, *PANIC_FG_RGB), fb_pack(info, *PANIC_BG_RGB)
        where, src, base_y, span = "the last", tail, 0, PANIC_TAIL_ROWS
    else:
        fg, bg = fb_pack(info, *CON_FG_RGB), fb_pack(info, *CON_BG_RGB)
        where, src, base_y, span = "the first", band, FB_BAR_H, 1

    if src is None or len(src) < (base_y + span * FONT_H) * info["pitch"]:
        out.append((False, f"{where} console text row was not read back"))
        return out

    lit = 0
    ink = 0
    for y in range(base_y, base_y + span * FONT_H):
        row = _row(src, info, y)
        for word, in struct.iter_unpack("<I", row):
            if word == fg:
                lit += 1
            elif word == bg:
                ink += 1
    out.append((lit >= CON_MIN_GLYPH_PX,
                f"{where} console text row has {lit} {expect}-palette "
                f"foreground pixels (want >= {CON_MIN_GLYPH_PX}: glyphs, not a "
                "filled band)"))
    out.append((ink > lit,
                f"and {ink} {expect}-palette background pixels around them "
                "(text on a cleared cell, not a solid block)"))
    return out


def do_framebuffer(sock_path, elf, timeout, quiet, expect="console"):
    _vaddr, info_paddr = symbol_phys_addr(elf, FB_SYMBOL)
    _fv, font_paddr = symbol_phys_addr(elf, FONT_SYMBOL)
    tmp = tempfile.NamedTemporaryFile(prefix="fk-fb.", suffix=".bin",
                                      delete=False)
    tmp.close()
    client = QmpClient(sock_path, time.monotonic() + timeout)
    client.connect()
    try:
        client.handshake()
        client.pmemsave(info_paddr, FB_BYTES, tmp.name)
        info = fb_decode(open(tmp.name, "rb").read())
        band = None
        tail = None
        font = None
        try:
            # The RUNNING kernel's font, not the ELF's copy of it: the two
            # agree only if the image in memory is the image on disk.
            client.pmemsave(font_paddr, FONT_BYTES, tmp.name)
            font = open(tmp.name, "rb").read()
        except QmpError:
            font = None
        # The framebuffer's PHYSICAL address comes from the guest's own handoff
        # block, so nothing here hardcodes where a PCI BAR landed.
        if info["base"] and info["pitch"]:
            try:
                client.pmemsave(info["base"],
                                (FB_BAR_H + FONT_H) * info["pitch"], tmp.name)
                band = open(tmp.name, "rb").read()
            except QmpError:
                band = None
        if info["base"] and info["pitch"] \
                and info["height"] > PANIC_TAIL_ROWS * FONT_H:
            try:
                last = info["base"] + (info["height"] - PANIC_TAIL_ROWS * FONT_H) \
                       * info["pitch"]
                client.pmemsave(last, PANIC_TAIL_ROWS * FONT_H * info["pitch"],
                                tmp.name)
                tail = open(tmp.name, "rb").read()
            except QmpError:
                tail = None
    finally:
        client.close()
        os.unlink(tmp.name)
    results = check_framebuffer(info, band, tail=tail, font=font, expect=expect)
    if not report_hwstate(results, quiet):
        print(f"        {FB_SYMBOL} at guest physical 0x{info_paddr:X}, "
              f"framebuffer at 0x{info['base']:X}")
        return 1
    return 0


# --- roadmap 4.0: the scheduler and the heap, read out of the guest --------

def sched_stack_top(stacks_vaddr, task):
    """The RSP0 sched_spawn programs for TASK (1-based), from the ELF's own
    symbol.  Mirrors the arithmetic in sched_spawn exactly: Fortran lays the
    2-D array out column-major, the top is rounded DOWN to 16, and one quadword
    below it holds the fake return address, which is where RSP starts."""
    base = stacks_vaddr + (task - 1) * SCHED_STACK_QWORDS * 8
    return ((base + SCHED_STACK_QWORDS * 8) & ~0xF) - 8


def check_sched(first, second, heap, tss=None, stacks_vaddr=None, tasks=0):
    """Return a list of (ok, description).

    FIRST and SECOND are (state, runs) pairs read a moment apart while the
    guest keeps running.  Two reads and not one: a counter that is non-zero
    proves a thread ran ONCE, which a scheduler that switches away and never
    comes back also produces -- and that kernel looks identical on COM1,
    because the boot thread printed its verdict before it was switched out.
    """
    out = []
    st1, runs1 = first
    st2, runs2 = second

    out.append((st1[0] == SCHED_MAGIC,
                f"fk_sched_state magic is 0x{st1[0]:016X} "
                f"(want 0x{SCHED_MAGIC:016X}: sched_init ran)"))
    out.append((st1[1] >= 3,
                f"the scheduler has {st1[1]} tasks (want >= 3: the boot thread "
                "and two spawned ones)"))
    out.append((st2[3] > st1[3],
                f"context switches grew {st1[3]} -> {st2[3]} between the two "
                "reads"))
    # EVERY spawned task, not the pair as a whole: a round robin that got stuck
    # on one of them still advances a total.
    for t in range(1, RUNS_TASKS):
        if runs1[t] == 0 and runs2[t] == 0:
            continue
        out.append((runs2[t] > runs1[t],
                    f"task {t + 1} ran {runs1[t]} -> {runs2[t]} times "
                    "(its own loop counter, not the scheduler's)"))
    live = sum(1 for t in range(1, RUNS_TASKS) if runs2[t] > 0)
    out.append((live >= 2,
                f"{live} spawned threads have executed (want >= 2)"))

    # roadmap 4.0's TSS half.  RSP0 is the stack a ring-3 -> ring-0 transition
    # lands on, and it is per-TASK: a scheduler that never updates it delivers
    # the next trap from user mode onto a stack another thread is using.
    # Nothing runs in ring 3 yet, so this assertion is the ONLY thing that
    # would notice tss_set_rsp0 never being called.
    if tss is not None and stacks_vaddr is not None:
        if len(tss) < 12:
            out.append((False, "the TSS could not be read back"))
        else:
            rsp0, = struct.unpack_from("<Q", tss, 4)
            wanted = {sched_stack_top(stacks_vaddr, t): t
                      for t in range(2, max(tasks, 1) + 1)}
            out.append((rsp0 in wanted,
                        f"TSS RSP0 is 0x{rsp0:016X}, the top of spawned task "
                        f"{wanted.get(rsp0, '?')}'s stack "
                        f"(candidates {', '.join(f'0x{a:X}' for a in wanted)})"))

    if heap is not None:
        out.append((heap[0] == HEAP_MAGIC,
                    f"fk_heap_stat magic is 0x{heap[0]:016X} "
                    f"(want 0x{HEAP_MAGIC:016X}: heap_init ran)"))
        out.append((heap[4] == 1 and heap[2] == 0,
                    f"the heap came back to {heap[4]} block(s) with "
                    f"{heap[2]} bytes in use -- everything freed coalesced"))
        out.append((heap[5] > 0 and heap[6] > 0,
                    f"it served {heap[5]} allocations and {heap[6]} frees"))
        out.append((heap[9] >= 3,
                    f"and refused {heap[9]} bad frees (want >= 3: the double "
                    "free, the stray pointer and the interior pointer)"))
    return out


def do_sched(sock_path, elf, timeout, quiet, interval=0.25):
    _v, st_paddr = symbol_phys_addr(elf, SCHED_SYMBOL)
    _v, runs_paddr = symbol_phys_addr(elf, RUNS_SYMBOL)
    _v, heap_paddr = symbol_phys_addr(elf, HEAP_SYMBOL)
    _v, tss_paddr = symbol_phys_addr(elf, TSS_SYMBOL)
    stacks_vaddr, _ = symbol_phys_addr(elf, STACKS_SYMBOL)
    tmp = tempfile.NamedTemporaryFile(prefix="fk-sched.", suffix=".bin",
                                      delete=False)
    tmp.close()

    def read_words(client, paddr, n):
        client.pmemsave(paddr, n * 8, tmp.name)
        raw = open(tmp.name, "rb").read()
        if len(raw) != n * 8:
            raise QmpError(f"pmemsave wrote {len(raw)} bytes, expected {n * 8}")
        return list(struct.unpack(f"<{n}Q", raw))

    client = QmpClient(sock_path, time.monotonic() + timeout)
    client.connect()
    try:
        client.handshake()
        first = (read_words(client, st_paddr, SCHED_WORDS),
                 read_words(client, runs_paddr, RUNS_TASKS))
        heap = read_words(client, heap_paddr, HEAP_WORDS)
        client.pmemsave(tss_paddr, TSS_LIMIT + 1, tmp.name)
        tss = open(tmp.name, "rb").read()
        time.sleep(interval)
        second = (read_words(client, st_paddr, SCHED_WORDS),
                  read_words(client, runs_paddr, RUNS_TASKS))
    finally:
        client.close()
        os.unlink(tmp.name)
    results = check_sched(first, second, heap, tss=tss,
                          stacks_vaddr=stacks_vaddr, tasks=int(second[0][1]))
    if not report_hwstate(results, quiet):
        print(f"        {SCHED_SYMBOL} at 0x{st_paddr:X}, {RUNS_SYMBOL} at "
              f"0x{runs_paddr:X}, {HEAP_SYMBOL} at 0x{heap_paddr:X}")
        return 1
    return 0


# --- roadmap 4.2: the guest's PCI list against QEMU's ----------------------

#   Bus  0, device  31, function 2:
#     SATA controller: PCI device 8086:2922
PCI_FN_RE = re.compile(r"^\s*Bus\s+(\d+),\s*device\s+(\d+),\s*function\s+(\d+):",
                       re.M)
PCI_ID_RE = re.compile(r"PCI device ([0-9a-fA-F]{4}):([0-9a-fA-F]{4})")


def parse_info_pci(text):
    """QEMU's own view: {(bus, dev, fn): (vendor, device)}.

    The vendor:device line belongs to the header above it, so the text is
    walked in order rather than scanned with one regex -- a device with no
    'PCI device' line at all must go missing here rather than silently pick up
    its neighbour's identity.
    """
    out = {}
    key = None
    for line in text.splitlines():
        m = PCI_FN_RE.match(line)
        if m:
            key = (int(m.group(1)), int(m.group(2)), int(m.group(3)))
            continue
        if key is None:
            continue
        m = PCI_ID_RE.search(line)
        if m:
            out[key] = (int(m.group(1), 16), int(m.group(2), 16))
            key = None
    return out


def parse_guest_pci(words):
    """The kernel's own list: {(bus, dev, fn): (vendor, device)}."""
    out = {}
    kept = words[3]
    for i in range(min(kept, PCI_SLOTS)):
        w = words[5 + i]
        bdf = (w >> 48) & 0xFFFF
        out[((bdf >> 8) & 0xFF, (bdf >> 3) & 0x1F, bdf & 0x07)] = (
            (w >> 32) & 0xFFFF, (w >> 16) & 0xFFFF)
    return out


def _bdf(k):
    return f"{k[0]:02x}:{k[1]:02x}.{k[2]}"


def check_pci(words, pci_text, dev=None):
    """Return a list of (ok, description).

    THE TWO LISTS ARE COMPARED AS SETS, not with one containing the other. A
    device QEMU reports and the kernel missed is a hole in the walk; a device
    the kernel reports and QEMU does not is a ghost, which is what a
    multifunction check that ignores the header-type bit produces -- a
    single-function device aliased across all eight functions and counted
    eight times. A containment test would let the second one through.
    """
    out = []
    out.append((words[0] == PCI_MAGIC,
                f"fk_pcie_devs magic is 0x{words[0]:016X} "
                f"(want 0x{PCI_MAGIC:016X}: pcie_bringup ran)"))
    out.append((words[1] != 0,
                f"the ECAM window is at 0x{words[1]:X} "
                "(0 would mean no MCFG was found)"))
    out.append((words[3] == words[4],
                f"the list is complete: {words[3]} kept of {words[4]} seen"))

    host = parse_info_pci(pci_text)
    guest = parse_guest_pci(words)
    out.append((bool(host), f"'info pci' reported {len(host)} function(s)"))

    missing = sorted(set(host) - set(guest))
    extra = sorted(set(guest) - set(host))
    out.append((not missing,
                f"the guest found every function QEMU reports ({len(host)})"
                if not missing else
                "the guest MISSED " + ", ".join(_bdf(k) for k in missing)))
    out.append((not extra,
                "and reported none QEMU does not"
                if not extra else
                "the guest INVENTED " + ", ".join(_bdf(k) for k in extra)))

    wrong = [k for k in sorted(set(host) & set(guest)) if host[k] != guest[k]]
    out.append((not wrong,
                f"every vendor:device matches ({len(set(host) & set(guest))} "
                "function(s) compared)"
                if not wrong else
                "; ".join(f"{_bdf(k)} guest says "
                          f"{guest[k][0]:04x}:{guest[k][1]:04x}, QEMU says "
                          f"{host[k][0]:04x}:{host[k][1]:04x}" for k in wrong[:4])))
    if missing or extra:
        out.append((False, "  QEMU : " + " ".join(_bdf(k) for k in sorted(host))))
        out.append((False, "  guest: " + " ".join(_bdf(k) for k in sorted(guest))))
    out.extend(check_xhci(words, host))
    out.extend(check_device_msix(dev))
    out.extend(check_guest_agrees(words, dev))
    return out


def check_guest_agrees(words, dev):
    """The two witnesses against each other.

    The kernel prints what it read back off the device; `xp` reads what the
    device model holds. A kernel that never wrote and printed the value it
    meant to write passes its own check and fails this one.
    """
    out = []
    if dev is None or dev.get("unmapped") or not words[PCI_W_XHCI]:
        return out
    msg = words[PCI_W_XHCI + 5]
    g_lo = msg & 0xFFFFFFFF
    g_data = (msg >> 32) & 0xFFFF
    g_mask = (msg >> 48) & 1
    lo, _hi, data, vctrl = dev["entry0"]
    out.append((g_lo == lo and g_data == data and g_mask == (vctrl & 1),
                f"the guest's read-back of entry 0 agrees with QEMU's device "
                f"model (0x{g_lo:08X}/0x{g_data:02X}/{g_mask} against "
                f"0x{lo:08X}/0x{data:02X}/{vctrl & 1})"))
    ctrl = words[PCI_W_XHCI + 6] & 0xFFFF
    out.append((((dev["cap0"] >> 16) & 0xFFFF) == ctrl,
                f"and its message control 0x{ctrl:04X} is the one the device "
                "holds"))
    return out


def parse_bar0(pci_text):
    """BAR0 of the USB controller, as QEMU reports it.

    Taken from the monitor rather than from the guest, because it is the
    address the DEVICE decodes: if the two disagree, the kernel mapped
    something that is not the controller.
    """
    blk = [b for b in pci_text.split("Bus  0, device") if "USB controller" in b]
    if not blk:
        return None
    m = re.search(r"BAR0: 64 bit memory at 0x([0-9a-f]+)", blk[0])
    return int(m.group(1), 16) if m else None


def xp_words(client, addr, count):
    """`xp` reads guest PHYSICAL addresses through the memory API, so it
    dispatches to device models the way a guest access does -- which is how
    this reads a device's MSI-X table and its configuration space rather than
    RAM. An undecoded address answers "Cannot access memory", and that is a
    real answer: a BAR whose memory-space decode is off is not mapped at all.
    """
    text = client.hmp_query(f"xp /{count}xw 0x{addr:X}")
    if "Cannot access memory" in text:
        return None
    return [int(w, 16) for w in re.findall(r"0x([0-9a-f]{8})", text)]


def check_device_msix(dev):
    """The route as the DEVICE MODEL holds it, not as the guest reports it.

    Every reading here comes back through `xp`, so it is QEMU's own state for
    the controller: the guest could publish anything it liked and these would
    still disagree with it.
    """
    out = []
    if dev is None:
        return out
    if dev.get("unmapped"):
        out.append((False, "the xHCI's BAR0 is not decoded: memory-space "
                           "decode is off and the register block, MSI-X table "
                           "included, is not mapped at all"))
        return out

    cmd = dev["cmd"] & 0xFFFF
    out.append((bool(cmd & PCI_CMD_MEMORY) and bool(cmd & PCI_CMD_MASTER),
                f"QEMU's own COMMAND for the device is 0x{cmd:04X}: decode "
                "and bus mastering are on"))
    out.append((bool(cmd & PCI_CMD_INTX_DISABLE),
                "and INTx is disabled, so the legacy wire is gone"))

    ctrl = dev["cap0"]
    out.append((bool(ctrl & PCI_MSIX_ENABLE),
                f"the capability reads 0x{(ctrl >> 16) & 0xFFFF:04X}: MSI-X is "
                "ENABLED"))
    out.append((not (ctrl & PCI_MSIX_MASKALL),
                "and the function-wide mask is clear"))

    lo, hi, data, vctrl = dev["entry0"]
    out.append((lo == MSI_ADDR_CPU0,
                f"table entry 0 addresses 0x{lo:08X}, the APIC of CPU 0"))
    out.append((hi == 0, f"with a zero high half (0x{hi:08X})"))
    out.append((data == MSI_VECTOR,
                f"carries vector 0x{data:02X}"))
    out.append((vctrl == 0,
                f"and is UNMASKED (vector control 0x{vctrl:08X})"))
    return out


def check_xhci(words, host):
    """Roadmap 4.2's debt, checked from outside the guest.

    The kernel does not get to be the only witness that it enabled anything:
    QEMU says where the xHCI is, and the guest's published BDF has to be that
    same function, with the two COMMAND bits actually set in the read-back it
    took from the device rather than in the value it wrote.
    """
    out = []
    bdf = words[PCI_W_XHCI] & 0xFFFF
    if not bdf and not words[PCI_W_XHCI + 1]:
        return out

    key = ((bdf >> 8) & 0xFF, (bdf >> 3) & 0x1F, bdf & 0x07)
    out.append((key in host,
                f"the xHCI the guest enabled, {_bdf(key)}, is a function "
                "QEMU reports"))

    # THE ESCAPE THIS SHAPE EXISTS FOR. SeaBIOS already leaves this machine's
    # xHCI at COMMAND 0x0107, so "both bits are set" passes on a kernel that
    # never wrote anything -- measured, by mutating the enable away and
    # watching the gate stay green. The kernel therefore takes the two bits
    # DOWN and puts them back, and the CLEARED reading is the assertion: only
    # this kernel could have cleared them.
    w = words[PCI_W_XHCI + 1]
    fw, down, cmd = w & 0xFFFF, (w >> 16) & 0xFFFF, (w >> 32) & 0xFFFF
    out.append((not (down & (PCI_CMD_MEMORY | PCI_CMD_MASTER)),
                f"the kernel's write MOVED the device: COMMAND went "
                f"0x{fw:04X} -> 0x{down:04X} with decode and mastering "
                f"cleared"))
    out.append((bool(cmd & PCI_CMD_MEMORY),
                f"and back to 0x{cmd:04X} with memory-space decode set"))
    out.append((bool(cmd & PCI_CMD_MASTER),
                f"and with bus mastering set"))
    out.append(((down & ~(PCI_CMD_MEMORY | PCI_CMD_MASTER)) ==
                (fw & ~(PCI_CMD_MEMORY | PCI_CMD_MASTER)),
                "no other COMMAND bit moved while those two did"))

    msix = words[PCI_W_XHCI + 2]
    cap, count, bir = msix & 0xFFFF, (msix >> 16) & 0xFFFF, (msix >> 32) & 0xFF
    table = words[PCI_W_XHCI + 3]
    out.append((cap >= 0x40,
                f"MSI-X is at capability offset 0x{cap:02X}, past the header"))
    out.append((count > 0,
                f"and declares {count} table entr(ies)"))
    out.append((table % 8 == 0,
                f"its table is at 0x{table:X} in BAR {bir}, 8-byte aligned"))

    bar = words[PCI_W_XHCI + 4]
    out.append((bar != 0 and bar % 16 == 0,
                f"BAR0 is 0x{bar:X}, a decoded memory address"))
    return out


def read_device_msix(client, words, pci_text):
    """Read the controller's configuration space and MSI-X table out of QEMU.

    ECAM is a memory region like any other, so `xp` reaches configuration space
    through it, and the table through the BAR the device decodes. Nothing here
    asks the guest anything except WHERE to look.
    """
    bdf = words[PCI_W_XHCI] & 0xFFFF
    if not bdf:
        return None
    ecam = words[1]
    cap = words[PCI_W_XHCI + 2] & 0xFFFF
    if not ecam or cap < 0x40:
        return None
    cfg = ecam + ((bdf >> 8) << 20) + (((bdf >> 3) & 0x1F) << 15) + \
        ((bdf & 7) << 12)

    cmd = xp_words(client, cfg + 0x04, 1)
    cap0 = xp_words(client, cfg + cap, 2)
    if cmd is None or cap0 is None:
        return None

    bar = parse_bar0(pci_text)
    tbl_off = cap0[1] & ~7
    if bar is None:
        return {"unmapped": True, "cmd": cmd[0], "cap0": cap0[0]}
    entry = xp_words(client, bar + tbl_off, 4)
    if entry is None:
        return {"unmapped": True, "cmd": cmd[0], "cap0": cap0[0]}
    return {"cmd": cmd[0], "cap0": cap0[0], "entry0": entry, "bar": bar,
            "tbl_off": tbl_off}


def do_pci(sock_path, elf, timeout, quiet):
    _v, paddr = symbol_phys_addr(elf, PCI_SYMBOL)
    tmp = tempfile.NamedTemporaryFile(prefix="fk-pci.", suffix=".bin",
                                      delete=False)
    tmp.close()
    client = QmpClient(sock_path, time.monotonic() + timeout)
    client.connect()
    try:
        client.handshake()
        client.pmemsave(paddr, PCI_WORDS * 8, tmp.name)
        raw = open(tmp.name, "rb").read()
        if len(raw) != PCI_WORDS * 8:
            raise QmpError(f"pmemsave wrote {len(raw)} bytes for {PCI_SYMBOL}")
        words = list(struct.unpack(f"<{PCI_WORDS}Q", raw))
        pci_text = client.hmp_query("info pci")
        dev = read_device_msix(client, words, pci_text)
    finally:
        client.close()
        os.unlink(tmp.name)
    results = check_pci(words, pci_text, dev)
    if not report_hwstate(results, quiet):
        print(f"        {PCI_SYMBOL} at 0x{paddr:X}")
        return 1
    return 0


# --- roadmap 3.x: the DMA run, read at its PHYSICAL base ------------------

def check_dma(probe, pages_raw):
    """Return a list of (ok, description).

    PROBE is the four-word fk_dma_probe.  PAGES_RAW is what pmemsave pulled
    out of guest PHYSICAL memory starting at the base the kernel published --
    an address no page table was consulted to reach.

    THIS IS THE ONLY FORM THE CONTIGUITY ASSERTION CAN TAKE.  The kernel's
    bitmap can say a run of frames is adjacent, and a bitmap that is simply
    wrong says exactly the same thing.  The kernel wrote one word into each
    frame of the run, derived from that frame's own index, through the linear
    map.  Reading them back in order at a single physical base means the
    frames really are adjacent in DRAM -- there is no mapping in the way that
    could be making them look adjacent when they are not.
    """
    out = []
    magic, base, pages, seed = probe

    out.append((magic == DMA_MAGIC,
                f"fk_dma_probe magic is 0x{magic:016X} "
                f"(want 0x{DMA_MAGIC:016X}: dma_bringup ran)"))
    out.append((base != 0,
                f"the run's physical base is 0x{base:X} "
                "(0 would mean pmm_alloc_contiguous refused)"))
    out.append((base % DMA_PAGE == 0,
                f"the base is frame aligned (0x{base:X} & 0xFFF == "
                f"0x{base % DMA_PAGE:X})"))
    out.append((0 < pages <= DMA_MAX_PAGES,
                f"the run is {pages} pages (want 1..{DMA_MAX_PAGES})"))

    want = pages * DMA_PAGE
    if len(pages_raw) != want:
        out.append((False,
                    f"read {len(pages_raw)} bytes of the run, expected {want}"))
        return out

    # Every frame, not a sample: a run that is contiguous for its first three
    # frames and jumps on the fourth is exactly what a broken scan produces.
    bad = []
    for i in range(pages):
        got = struct.unpack_from("<Q", pages_raw, i * DMA_PAGE)[0]
        if got != (seed + i) & 0xFFFFFFFFFFFFFFFF:
            bad.append((i, got))
    out.append((not bad,
                f"all {pages} frames carry their own tag at the physical base"
                if not bad else
                "frame(s) " + ", ".join(
                    f"{i} reads 0x{g:016X} (want 0x{(seed + i) & 0xFFFFFFFFFFFFFFFF:016X})"
                    for i, g in bad[:4])))
    return out


def trb_at(blob, off):
    """One 16-byte TRB out of a dump: parameter, status, control."""
    parm, status, control = struct.unpack_from("<QII", blob, off)
    return parm, status, control


def check_xhci_rings(words, cmd_blob, evt_blob, regs, msi):
    """The controller's own work, read where the CONTROLLER wrote it.

    The command ring and the event ring are read by pmemsave AT THEIR PHYSICAL
    BASE -- no page table in the path -- so what appears here is what a bus
    master put in DRAM, not what the guest says it put there. The registers
    come back through xp, which is the device model's state.
    """
    out = []
    out.append((words[0] == XHCI_MAGIC,
                f"fk_xhci_state magic is 0x{words[0]:012X} "
                f"(want 0x{XHCI_MAGIC:012X}: the bring-up ran)"))
    if words[0] != XHCI_MAGIC:
        return out

    st = words[15]
    out.append((st == 0, f"the bring-up sequence returned {st}"))

    # THE RESET, AND IT IS NOT INFERABLE FROM THE END STATE. Firmware drives
    # this controller before the kernel runs -- SeaBIOS leaves CRCR, DCBAAP
    # and ERSTBA pointing into its own memory -- and a kernel that programs
    # its own rings over the top ends up looking identical. These three were
    # read the instant the reset returned and before anything was programmed,
    # so they are firmware's values unless the reset actually happened.
    out.append((words[16] == 0,
                f"CRCR read 0x{words[16]:X} straight after the reset "
                "(firmware's pointer is gone)"))
    out.append((words[17] == 0,
                f"DCBAAP read 0x{words[17]:X} there too"))
    out.append((bool(words[18] & 1) and not (words[18] & (1 << 11)),
                f"and USBSTS 0x{words[18]:X}: halted, and CNR clear"))

    cmd_phys, evt_phys, trb_phys = words[3], words[4], words[6]
    ev_type, ev_comp = (words[7] >> 32) & 0xFFFFFFFF, words[7] & 0xFFFFFFFF
    out.append((cmd_phys and evt_phys and words[5],
                f"rings at cmd 0x{cmd_phys:X}, event 0x{evt_phys:X}, "
                f"ERST 0x{words[5]:X}"))
    out.append((cmd_phys % 64 == 0 and evt_phys % 64 == 0 and
                words[5] % 64 == 0,
                "and every one of them is 64-byte aligned"))

    # THE COMMAND RING, in DRAM. The kernel says it enqueued a NO-OP; this is
    # the TRB a bus master would fetch.
    if cmd_blob:
        off = trb_phys - cmd_phys
        if not 0 <= off <= len(cmd_blob) - 16:
            out.append((False,
                        f"the TRB the kernel published, 0x{trb_phys:X}, is "
                        f"not inside its own command ring at 0x{cmd_phys:X}"))
            return out
        parm, status, control = trb_at(cmd_blob, off)
        out.append((((control >> 10) & 0x3F) == TRB_TYPE_CMD_NOOP,
                    f"the TRB at 0x{trb_phys:X} is a NO-OP command "
                    f"(type {(control >> 10) & 0x3F})"))
        out.append((control & 1 == 1,
                    "with its cycle bit set, so the controller owned it"))
        out.append((parm == 0 and status == 0,
                    "and the rest of it zeroed, as 4.11.1.1 requires"))
        link = trb_at(cmd_blob, (256 - 1) * 16)
        out.append((((link[2] >> 10) & 0x3F) == 6,
                    "the ring's last TRB is a LINK"))
        out.append(((link[2] >> 1) & 1 == 1,
                    "with Toggle Cycle set, which is what makes it a ring"))
        out.append((link[0] == cmd_phys,
                    f"pointing back at 0x{link[0]:X}"))

    # THE EVENT RING, also in DRAM, and this one the CONTROLLER wrote.
    if evt_blob:
        parm, status, control = trb_at(evt_blob, 0)
        out.append((((control >> 10) & 0x3F) == TRB_TYPE_COMPLETION,
                    f"the controller posted a Command Completion Event "
                    f"(type {(control >> 10) & 0x3F})"))
        out.append((control & 1 == 1,
                    "with cycle 1, the polarity a zeroed segment cannot fake"))
        out.append((((status >> 24) & 0xFF) == COMP_SUCCESS,
                    f"completion code {(status >> 24) & 0xFF} (SUCCESS)"))
        out.append((parm & ~0xF == trb_phys,
                    f"naming the command TRB at 0x{parm & ~0xF:X}, which is "
                    f"the one the kernel enqueued"))

    out.append((ev_type == TRB_TYPE_COMPLETION and ev_comp == COMP_SUCCESS and
                (words[8] & ~0xF) == trb_phys,
                "and the guest's own reading of that event agrees"))

    if regs:
        usbsts, usbcmd, crcr, erdp, iman, dcbaap = regs
        out.append((not (usbsts & 1),
                    f"USBSTS 0x{usbsts:08X}: the controller is NOT halted"))
        out.append((not (usbsts & (1 << 12)),
                    "and reports no host controller error"))
        out.append((bool(usbcmd & 1) and bool(usbcmd & 4),
                    f"USBCMD 0x{usbcmd:08X}: R/S and INTE are both set"))
        out.append((bool(iman & 2),
                    f"IMAN 0x{iman:08X}: the interrupter is enabled"))
        # QEMU-SPECIFIC, and labelled: xHCI 1.2 5.4.5 says CRCR's pointer
        # field reads as zero on real hardware.
        out.append(((crcr & ~0x3F) == cmd_phys,
                    f"CRCR holds the kernel's command ring (QEMU reads it "
                    f"back; real hardware returns 0)"))
        # WEAKENED AT ROADMAP 5.2, and the reason is written down rather than
        # quietly absorbed. Until 5.2 exactly one event was ever posted, so
        # "ERDP is one TRB past the base" was an exact equality. Enumeration
        # consumes a dozen and a keystroke consumes one more, so the exact
        # index is a moving target and comparing it against a separately-read
        # guest word is a race, not an assertion. What survives is what cannot
        # move: the pointer is inside its own segment, on a TRB boundary, and
        # STRICTLY PAST the base -- which is still what refuses a kernel that
        # never advances it, because that one leaves ERDP exactly at the base.
        # No alignment assertion goes with this: ERDP's low four bits are DESI
        # and EHB rather than address, so the masked pointer is 16-byte aligned
        # by construction and a check on it could never refuse anything.
        seg_end = evt_phys + 256 * 16
        out.append((evt_phys < (erdp & ~0xF) < seg_end,
                    f"ERDP 0x{erdp:X} is inside the event ring segment "
                    f"[0x{evt_phys:X}, 0x{seg_end:X}) and past its base, so "
                    "events were consumed"))
        # A NO-OP touches no slot, so the controller runs it correctly with
        # DCBAAP still zero -- which is exactly how a kernel that never wrote
        # it passed this gate until mutation M59 was run. Device contexts are
        # the first thing that needs the array to be real.
        out.append(((dcbaap & ~0x3F) == words[2],
                    f"DCBAAP 0x{dcbaap:X} holds the kernel's device-context "
                    f"base array at 0x{words[2]:X}"))

    out.append((msi >= 1,
                f"fk_msi_count is {msi}: the controller's MSI-X message "
                "reached the handler"))
    return out


def check_usbkbd(words, xwords, dcbaa_blob, dctx_blob, stride, want_chars,
                 want_report):
    """Roadmap 5.2, and the two witnesses are on opposite sides of the bus.

    What the kernel published is in `words`. What the CONTROLLER wrote is in
    `dcbaa_blob` and `dctx_blob`, read by pmemsave at their physical bases with
    no page table in the path -- and the slot state and device address in there
    are fields the controller owns, so no kernel can put them there by writing
    its own input context.
    """
    out = []
    out.append((words[0] == KBD_MAGIC,
                f"fk_usbkbd_state magic is 0x{words[0]:012X} "
                f"(want 0x{KBD_MAGIC:012X}: the bring-up ran)"))
    if words[0] != KBD_MAGIC:
        return out

    st = words[23]
    out.append((st == 0, f"the keyboard bring-up returned {st}"))

    port, portsc, speed = words[1], words[2], words[3]
    out.append((port >= 1, f"a device was found on root hub port {port}"))
    out.append((bool(portsc & 1),
                f"PORTSC 0x{portsc:08X}: the port still reports a connection"))
    # THE ASSERTION THE RESET EXISTS FOR. A USB2 port comes up Connected and
    # NOT Enabled; only a port reset moves it to Enabled, and PED is the
    # controller's answer rather than anything the kernel can write.
    out.append((bool(portsc & 2),
                "and PED is set, which only a port reset produces"))
    out.append((not (portsc & 0x00FE0000),
                f"with every change bit acknowledged (0x{portsc & 0x00FE0000:X})"))
    out.append((speed in KBD_SPEEDS,
                f"the port reports speed id {speed}"))

    slot = words[4]
    out.append((slot >= 1, f"the controller assigned slot {slot}"))
    out.append((words[12] != 0,
                f"and device address {words[12]}, which the CONTROLLER wrote "
                "into the device context"))
    out.append((words[11] == SLOT_STATE_ADDRESSED,
                f"slot state after Address Device is {words[11]} (Addressed)"))
    out.append((words[13] == SLOT_STATE_CONFIGURED,
                f"and {words[13]} (Configured) after Configure Endpoint"))

    if speed in KBD_SPEEDS:
        out.append((words[14] == KBD_SPEEDS[speed],
                    f"bMaxPacketSize0 is {words[14]}, what speed id {speed} "
                    "requires"))

    ep_addr = words[16]
    out.append((bool(ep_addr & 0x80),
                f"EP1's bEndpointAddress is 0x{ep_addr:02X}, an IN endpoint"))
    out.append(((ep_addr & 0x0F) == 1,
                "and it is endpoint 1, so its DCI is 3 and not 1"))
    ep_mps, ep_ival = words[17] >> 32, words[17] & 0xFFFFFFFF
    out.append((ep_mps == 8,
                f"its wMaxPacketSize is {ep_mps}: a boot-protocol report"))
    out.append((ep_ival >= 1, f"and its bInterval is {ep_ival}"))

    # DCBAA[slot], read out of DRAM at the array's own physical base.
    if dcbaa_blob and slot >= 1 and (slot + 1) * 8 <= len(dcbaa_blob):
        entry = struct.unpack_from("<Q", dcbaa_blob, slot * 8)[0]
        out.append(((entry & ~0x3F) == words[5],
                    f"DCBAA[{slot}] holds 0x{entry & ~0x3F:X}, the device "
                    f"context the kernel allocated at 0x{words[5]:X}"))

    # The device context itself, in DRAM. Slot context dword 3 is the
    # controller's: it carries the state and the address it assigned.
    if dctx_blob and len(dctx_blob) >= stride:
        dw3 = struct.unpack_from("<I", dctx_blob, 12)[0]
        out.append(((dw3 >> 27) == SLOT_STATE_CONFIGURED,
                    f"the device context in DRAM says slot state "
                    f"{dw3 >> 27} (Configured), written by the controller"))
        out.append(((dw3 & 0xFF) == words[12],
                    f"and device address {dw3 & 0xFF}, the same one the guest "
                    "read back"))

    # THE KEYSTROKES. Two, deliberately: a handler that never clears the
    # interrupter's IP bit delivers exactly one and then goes silent forever,
    # and one keystroke is indistinguishable from a working keyboard.
    # NOT "so IMAN.IP is being cleared". Mutation M71 removed the IP clear and
    # this count did not move: QEMU's xHCI does not gate further messages on
    # it, so repeated delivery is evidence of repeated delivery and nothing
    # more. The IP clear is required by xHCI 1.2 5.5.2.1 and is kept on the
    # specification's authority, not this gate's -- see
    # HARNESS-VALIDATION-PHASE5.md.
    out.append((words[18] >= 2,
                f"{words[18]} transfer events arrived on EP1: the endpoint "
                "keeps delivering, not just once"))
    out.append((words[20] >= len(want_chars),
                f"{words[20]} character(s) were rendered to the console"))
    got = words[21] & ((1 << (8 * len(want_chars))) - 1)
    want = 0
    for c in want_chars:
        want = (want << 8) | ord(c)
    out.append((got == want,
                f"the decoded characters are {_chars(got, len(want_chars))} "
                f"(want {_chars(want, len(want_chars))}) -- injected with "
                "sendkey, decoded by the guest from the wire"))
    # THE EIGHT BYTES OFF THE WIRE, not the character they decoded to. The
    # injection ends with 'b' released while 'a' is STILL HELD, so the last
    # report carrying a key is {a} with no modifier -- which is also the proof
    # that a held key really does reappear in a later report, since 'a' was
    # pressed two reports earlier.
    out.append((words[19] == want_report,
                f"the last boot report with a key in it is "
                f"0x{words[19]:016X} (want 0x{want_report:016X}: modifier "
                f"0x{want_report & 0xFF:02X}, usage "
                f"0x{(want_report >> 16) & 0xFF:02X})"))
    return out


def _chars(packed, n):
    return "".join(chr((packed >> (8 * i)) & 0xFF) for i in range(n - 1, -1, -1))


def do_xhci(sock_path, elf, timeout, quiet):
    _v, state_paddr = symbol_phys_addr(elf, XHCI_SYMBOL)
    _v, msi_paddr = symbol_phys_addr(elf, MSI_SYMBOL)
    tmp = tempfile.NamedTemporaryFile(prefix="fk-xhci.", suffix=".bin",
                                      delete=False)
    tmp.close()
    client = QmpClient(sock_path, time.monotonic() + timeout)
    client.connect()
    cmd_blob = evt_blob = b""
    regs = None
    try:
        client.handshake()
        client.pmemsave(state_paddr, XHCI_WORDS * 8, tmp.name)
        words = list(struct.unpack(f"<{XHCI_WORDS}Q",
                                   open(tmp.name, "rb").read()))
        client.pmemsave(msi_paddr, 8, tmp.name)
        msi = struct.unpack("<Q", open(tmp.name, "rb").read())[0]

        if words[0] == XHCI_MAGIC and words[3] and words[4]:
            client.pmemsave(words[3], 4096, tmp.name)
            cmd_blob = open(tmp.name, "rb").read()
            client.pmemsave(words[4], 4096, tmp.name)
            evt_blob = open(tmp.name, "rb").read()
            bar = words[1]
            if bar:
                cap = xp_words(client, bar, 1)
                caplen = (cap[0] & 0xFF) if cap else 0
                op = bar + caplen
                rt = bar + 0x1000
                r = xp_words(client, op, 2)
                c = xp_words(client, op + 0x18, 2)
                d = xp_words(client, rt + 0x38, 2)
                i = xp_words(client, rt + 0x20, 1)
                b = xp_words(client, op + 0x30, 2)
                if r and c and d and i and b:
                    regs = (r[1], r[0],
                            c[0] | (c[1] << 32), d[0] | (d[1] << 32), i[0],
                            b[0] | (b[1] << 32))
    finally:
        client.close()
        os.unlink(tmp.name)
    results = check_xhci_rings(words, cmd_blob, evt_blob, regs, msi)
    if not report_hwstate(results, quiet):
        print(f"        {XHCI_SYMBOL} at 0x{state_paddr:X}")
        return 1
    return 0


# EVERY KEY IS AN EXPLICIT DOWN AND UP, and sendkey is not used at all.
# sendkey presses and releases a whole combination on its own timing, so which
# reports the guest's poll actually samples is a race -- observed, more than
# once: shift-a decoding as 'a' because the modifier had already been released
# by the time the report was sampled. Separate events with a gap between them
# make the sequence of reports a fact rather than a hope, and they are the only
# way to HOLD one key while another arrives, which is what the rollover
# subtraction needs to be exercised at all.
DEFAULT_KEYS = (("shift", True), ("a", True), ("a", False), ("shift", False),
                ("a", True), ("b", True), ("b", False), ("a", False))


def do_usbkbd(sock_path, elf, timeout, quiet, keys=DEFAULT_KEYS,
              chars="Aab", report=0x0000000000040000):
    """Wait for the guest to arm EP1, inject keys, and assert what it did.

    THE WAIT IS NOT POLITENESS. Injecting before the endpoint is armed sends
    the keystroke into a controller with no transfer TRB to put it in, and the
    test would fail on a correct kernel -- a flaky gate, which is worse than no
    gate. fk_usbkbd_state[22] is the guest saying it is ready.
    """
    _v, kbd_paddr = symbol_phys_addr(elf, KBD_SYMBOL)
    _v, xhci_paddr = symbol_phys_addr(elf, XHCI_SYMBOL)
    tmp = tempfile.NamedTemporaryFile(prefix="fk-kbd.", suffix=".bin",
                                      delete=False)
    tmp.close()
    client = QmpClient(sock_path, time.monotonic() + timeout)
    client.connect()
    dcbaa_blob = dctx_blob = b""
    stride = 32
    try:
        client.handshake()

        def state():
            client.pmemsave(kbd_paddr, KBD_WORDS * 8, tmp.name)
            return list(struct.unpack(f"<{KBD_WORDS}Q",
                                      open(tmp.name, "rb").read()))

        words = state()
        deadline = time.monotonic() + timeout
        while words[22] != 1 and time.monotonic() < deadline:
            time.sleep(0.2)
            words = state()
        if words[22] != 1:
            print("  \033[31mFAIL\033[0m  the guest never armed EP1 "
                  f"(fk_usbkbd_state[22] = {words[22]}, status {words[23]})")
            return 1

        # 'a' is still held when 'b' arrives, which is what makes the
        # report's six usage slots behave as the SET they are: a driver that
        # does not subtract the previous report renders the held key again on
        # every one. Measured -- with press-and-release only, mutating the
        # subtraction away left the gate green.
        for code, down in keys:
            client.execute("input-send-event", {"events": [
                {"type": "key", "data": {"down": down,
                                         "key": {"type": "qcode",
                                                 "data": code}}}]})
            time.sleep(0.3)

        deadline = time.monotonic() + timeout
        words = state()
        while words[20] < len(chars) and time.monotonic() < deadline:
            time.sleep(0.2)
            words = state()

        client.pmemsave(xhci_paddr, XHCI_WORDS * 8, tmp.name)
        xwords = list(struct.unpack(f"<{XHCI_WORDS}Q",
                                    open(tmp.name, "rb").read()))
        if xwords[1]:
            cap = xp_words(client, xwords[1] + 0x10, 1)
            if cap:
                stride = 32 << ((cap[0] >> 2) & 1)
        if xwords[2]:
            client.pmemsave(xwords[2], 4096, tmp.name)
            dcbaa_blob = open(tmp.name, "rb").read()
        if words[5]:
            client.pmemsave(words[5], stride, tmp.name)
            dctx_blob = open(tmp.name, "rb").read()
    finally:
        client.close()
        os.unlink(tmp.name)
    results = check_usbkbd(words, xwords, dcbaa_blob, dctx_blob, stride, chars,
                           report)
    if not report_hwstate(results, quiet):
        print(f"        {KBD_SYMBOL} at 0x{kbd_paddr:X}")
        return 1
    return 0


def do_dma(sock_path, elf, timeout, quiet):
    _v, probe_paddr = symbol_phys_addr(elf, DMA_SYMBOL)
    tmp = tempfile.NamedTemporaryFile(prefix="fk-dma.", suffix=".bin",
                                      delete=False)
    tmp.close()
    client = QmpClient(sock_path, time.monotonic() + timeout)
    client.connect()
    try:
        client.handshake()
        client.pmemsave(probe_paddr, DMA_WORDS * 8, tmp.name)
        raw = open(tmp.name, "rb").read()
        if len(raw) != DMA_WORDS * 8:
            raise QmpError(f"pmemsave wrote {len(raw)} bytes for {DMA_SYMBOL}")
        probe = list(struct.unpack(f"<{DMA_WORDS}Q", raw))
        pages_raw = b""
        # The run itself is only read when the header is plausible: pmemsave of
        # a bogus length at a bogus address is a monitor error, not a verdict.
        if probe[0] == DMA_MAGIC and probe[1] != 0 \
           and 0 < probe[2] <= DMA_MAX_PAGES:
            client.pmemsave(probe[1], probe[2] * DMA_PAGE, tmp.name)
            pages_raw = open(tmp.name, "rb").read()
    finally:
        client.close()
        os.unlink(tmp.name)
    results = check_dma(probe, pages_raw)
    if not report_hwstate(results, quiet):
        print(f"        {DMA_SYMBOL} at 0x{probe_paddr:X}")
        return 1
    return 0


def do_dump(sock_path, elf, out_path, timeout, send_quit):
    _vaddr, paddr = symbol_phys_addr(elf, SENTINEL_SYMBOL)
    client = QmpClient(sock_path, time.monotonic() + timeout)
    client.connect()
    try:
        client.handshake()
        # A stale file from an earlier attempt must not be mistaken for this
        # attempt's dump: pmemsave truncates, but only if it runs at all.
        open(out_path, "wb").close()
        client.pmemsave(paddr, SENTINEL_BYTES, out_path)
        got = open(out_path, "rb").read()
        if len(got) != SENTINEL_BYTES:
            raise QmpError(f"pmemsave wrote {len(got)} bytes, expected "
                           f"{SENTINEL_BYTES}")
        if send_quit:
            client.quit()
    finally:
        client.close()
    return 0


def do_hwstate(sock_path, elf, timeout, quiet, **want):
    tss_vaddr, tss_paddr = symbol_phys_addr(elf, TSS_SYMBOL)
    stack_vaddr, _ = symbol_phys_addr(elf, DF_STACK_SYMBOL)
    # The same rounding tss_init does: the array is exclusive-topped and the
    # top is masked down to 16 for the ABI.
    ist1_want = (stack_vaddr + SYMBOL_SIZE[DF_STACK_SYMBOL]) & ~0xF
    tmp = tempfile.NamedTemporaryFile(prefix="fk-tss.", suffix=".bin",
                                      delete=False)
    tmp.close()
    client = QmpClient(sock_path, time.monotonic() + timeout)
    client.connect()
    try:
        client.handshake()
        regs_text = client.hmp_query("info registers")
        pic_text = client.hmp_query("info pic")
        try:
            client.pmemsave(tss_paddr, TSS_LIMIT + 1, tmp.name)
            tss_bytes = open(tmp.name, "rb").read()
        except QmpError:
            tss_bytes = b""
    finally:
        client.close()
        os.unlink(tmp.name)
    results = check_hwstate(regs_text, pic_text, tss_vaddr,
                            tss_bytes=tss_bytes, ist1_want=ist1_want, **want)
    if not report_hwstate(results, quiet):
        # The monitor's own words, so the failure can be read without a rerun.
        for line in regs_text.splitlines():
            if line.startswith(("TR =", "GDT=")):
                print(f"        {line.strip()}")
        for line in pic_text.splitlines():
            if line.startswith("pic"):
                print(f"        {line.strip()}")
        return 1
    return 0


def do_ticks(sock_path, elf, timeout, quiet, interval=0.25, min_delta=2):
    _vaddr, paddr = symbol_phys_addr(elf, TICK_SYMBOL)
    tmp = tempfile.NamedTemporaryFile(prefix="fk-ticks.", suffix=".bin",
                                      delete=False)
    tmp.close()

    def read_once(client):
        client.pmemsave(paddr, TICK_BYTES, tmp.name)
        raw = open(tmp.name, "rb").read()
        if len(raw) != TICK_BYTES:
            raise QmpError(f"pmemsave wrote {len(raw)} bytes, expected "
                           f"{TICK_BYTES}")
        return struct.unpack("<Q", raw)[0]

    client = QmpClient(sock_path, time.monotonic() + timeout)
    client.connect()
    try:
        client.handshake()
        first = read_once(client)
        # The guest keeps running through this: nothing here stops the CPU.
        time.sleep(interval)
        second = read_once(client)
    finally:
        client.close()
        os.unlink(tmp.name)
    results = check_ticks(first, second, min_delta=min_delta)
    if not report_hwstate(results, quiet):
        print(f"        {TICK_SYMBOL} at guest physical 0x{paddr:X}: "
              f"{first} then {second}, {interval}s apart")
        return 1
    return 0


def do_quit(sock_path, timeout):
    client = QmpClient(sock_path, time.monotonic() + timeout)
    client.connect()
    try:
        client.handshake()
        client.quit()
    finally:
        client.close()
    return 0


def synth(tag=FK_BOOT_TAG, magic=MB2_BOOTLOADER_MAGIC, mbi=0x00009500,
          computed=None):
    if computed is None:
        computed = (tag ^ magic) & 0xFFFFFFFF
    return [tag, magic, mbi, computed]


# Real QEMU 10.2.2 output, copied from a run rather than composed: the good
# text is from the roadmap 3.2b image, and the two BAD pic values below are the
# ones the SAME VM printed before roadmap 3.2.5 -- irq_base=08 is the master
# colliding with the CPU exception range, imr=b8 is SeaBIOS's mask.
#
# pic0's imr=fe is the 3.2b change, and it is the only line in this fixture
# whose value is an ASSERTION rather than scenery: the master's line 0 is open
# because the timer is running through it.
HW_TSS_VADDR = 0xFFFFFFFF8010BDA0
HW_REGS_OK = (
    "LDT=0000 0000000000000000 0000ffff 00008200 DPL=0 LDT\n"
    "TR =0018 ffffffff8010bda0 00000067 00008b00 DPL=0 TSS64-busy\n"
    "GDT=     ffffffff80107020 00000027\n"
    "IDT=     ffffffff801080e0 00000fff\n"
)
HW_REGS_NO_TSS = (
    "TR =0000 0000000000000000 0000ffff 00008b00 DPL=0 TSS64-busy\n"
    "GDT=     ffffffff80107020 00000027\n"
)
# 'info pic' as QEMU 10.2.2 prints it: the IOAPIC's whole redirection table
# first, then the two 8259s.  Built rather than pasted, because roadmap 3.3's
# failure cases are all "one pin differs" and a 26-line literal per case would
# hide which line that was.
def _hw_ioapic(routed=IOAPIC_GSI, vec=IOAPIC_VECTOR, dest=0, also_open=None,
               pins=24):
    out = ["ioapic0: ver=0x11 id=0x00 sel=0x00"]
    for n in range(pins):
        if n == routed:
            out.append(f"  pin {n:<2} 0x{vec:016X} dest={dest} vec={vec:<3} "
                       "active-hi edge   fixed  physical")
        elif n == also_open:
            out.append(f"  pin {n:<2} 0x0000000000000030 dest=0 vec=48  "
                       "active-hi edge   fixed  physical")
        else:
            out.append(f"  pin {n:<2} 0x0000000000010000 dest=0 vec=0   "
                       "active-hi edge  masked fixed  physical")
    out += ["  IRR      (none)", "  Remote IRR (none)"]
    return "\n".join(out) + "\n"


# roadmap 3.3's end state: GSI 2 carrying vector 0x20 to the BSP, every other
# pin masked, and BOTH 8259s fully masked -- which before 3.3 would have meant
# the timer was never let through and now means it goes somewhere else.
HW_PIC_OK = (
    _hw_ioapic() +
    "pic1: irr=00 imr=ff isr=00 hprio=0 irq_base=28 rr_sel=0 elcr=0c fnm=0\n"
    "pic0: irr=00 imr=ff isr=00 hprio=0 irq_base=20 rr_sel=0 elcr=00 fnm=0\n"
)
# 104 bytes with IST1 at 0x24 and iomap_base 0x0068 at 0x66, as fk_tss.f90
# builds it; the IST1 value is fk_df_stack + its st_size in the same image.
# The two bad variants below are exactly mutations M12 and M8.
def _hw_tss(ist1=0xFFFFFFFF8010BDA0, iomap=0x68):
    b = bytearray(104)
    struct.pack_into("<Q", b, 0x24, ist1)
    struct.pack_into("<H", b, 0x66, iomap)
    return bytes(b)


HW_PIC_UNREMAPPED = (
    _hw_ioapic() +
    "pic1: irr=00 imr=8e isr=00 hprio=0 irq_base=70 rr_sel=0 elcr=0c fnm=0\n"
    "pic0: irr=11 imr=b8 isr=00 hprio=0 irq_base=08 rr_sel=0 elcr=00 fnm=0\n"
)


def do_selftest():
    """The assertion must accept a correct sentinel and reject every wrong one.

    A gate that has never rejected anything proves nothing about the run where
    it passes.
    """
    pass_n = fail_n = 0

    def expect(ok_wanted, words, what):
        nonlocal pass_n, fail_n
        got = all(ok for ok, _ in check_sentinel(words))
        if got == ok_wanted:
            print(f"  \033[32mPASS\033[0m  {what}")
            pass_n += 1
        else:
            print(f"  \033[31mFAIL\033[0m  {what} -- assertion said "
                  f"{'accept' if got else 'reject'}")
            fail_n += 1

    print("=== sentinel assertion self-test (no QEMU, no kernel) ===")
    expect(True, synth(), "a correct sentinel is accepted")
    expect(False, [FK_UNWRITTEN] * 4,
           "an untouched sentinel (kernel_main never ran) is rejected")
    expect(False, [0, 0, 0, 0], "an all-zero sentinel is rejected")
    expect(False, synth(tag=FK_BOOT_TAG ^ 1), "a wrong boot tag is rejected")
    expect(False, synth(magic=0x2BADB002),
           "the Multiboot *1* magic in word 1 is rejected")
    expect(False, synth(mbi=0), "a null MBI pointer is rejected")
    expect(False, synth(computed=0),
           "a zero computed word is rejected")
    # The one that matters: everything static is right, but the computed word
    # was not derived from the magic. This is what a kernel that stores four
    # constants -- rather than reading its arguments -- would produce.
    expect(False, synth(computed=(FK_BOOT_TAG ^ 0x2BADB002) & 0xFFFFFFFF),
           "a computed word derived from the WRONG magic is rejected")

    def expect_hw(ok_wanted, regs, pic, what, tss=None, **want):
        nonlocal pass_n, fail_n
        if tss is None:
            tss = _hw_tss()
        got = all(ok for ok, _ in
                  check_hwstate(regs, pic, HW_TSS_VADDR, tss_bytes=tss, **want))
        if got == ok_wanted:
            print(f"  \033[32mPASS\033[0m  {what}")
            pass_n += 1
        else:
            print(f"  \033[31mFAIL\033[0m  {what} -- assertion said "
                  f"{'accept' if got else 'reject'}")
            fail_n += 1

    # Every corrupted fixture below is built by substitution, and a substitution
    # that matches NOTHING hands the assertion the GOOD text -- so the case
    # passes, reports that a defect was rejected, and has tested nothing. That
    # is not hypothetical: the TR-base case here went quiet the moment roadmap
    # 3.2b added a module and moved fk_tss. Refuse instead.
    def spoil(text, old, new):
        if old not in text:
            raise AssertionError(f"self-test fixture is stale: {old!r} is no "
                                 f"longer in the monitor text it corrupts")
        return text.replace(old, new)

    print("=== hardware-state assertion self-test (no QEMU, no kernel) ===")
    expect_hw(True, HW_REGS_OK, HW_PIC_OK,
              "the real roadmap 3.2b monitor output is accepted")
    expect_hw(False, HW_REGS_NO_TSS, HW_PIC_OK,
              "a null task register (LTR never ran) is rejected")
    expect_hw(False, HW_REGS_OK, HW_PIC_UNREMAPPED,
              "the 8259 state this VM boots with -- master on 0x08 -- is "
              "rejected")
    expect_hw(False, HW_REGS_OK,
              spoil(HW_PIC_OK, "imr=ff isr=00 hprio=0 irq_base=20",
                    "imr=00 isr=00 hprio=0 irq_base=20"),
              "a master that was remapped but never masked is rejected")
    # roadmap 3.3 INVERTS 3.2b's case. Until 3.3 a master IMR of 0xFE was the
    # correct state and 0xFF meant the timer could never be delivered; now the
    # IOAPIC carries it and 0xFE means the line is live on BOTH chips at once,
    # which is a double delivery whose second half is acknowledged at whichever
    # chip the handler was told about -- leaving the other holding an
    # in-service bit for ever.
    expect_hw(False, HW_REGS_OK,
              spoil(HW_PIC_OK, "imr=ff isr=00 hprio=0 irq_base=20",
                    "imr=fe isr=00 hprio=0 irq_base=20"),
              "a master with IRQ0 STILL open beside the IOAPIC is rejected")

    # roadmap 3.3's own five. Every one of these is a machine on which the
    # kernel's console prints exactly the same lines it prints when the
    # routing worked.
    expect_hw(False, HW_REGS_OK,
              "pic1: irr=00 imr=ff isr=00 hprio=0 irq_base=28 rr_sel=0 "
              "elcr=0c fnm=0\n"
              "pic0: irr=00 imr=ff isr=00 hprio=0 irq_base=20 rr_sel=0 "
              "elcr=00 fnm=0\n",
              "monitor output with no IOAPIC table at all is rejected")
    expect_hw(False, HW_REGS_OK,
              _hw_ioapic(routed=99) +
              "pic1: irr=00 imr=ff isr=00 hprio=0 irq_base=28 rr_sel=0 "
              "elcr=0c fnm=0\n"
              "pic0: irr=00 imr=ff isr=00 hprio=0 irq_base=20 rr_sel=0 "
              "elcr=00 fnm=0\n",
              "an IOAPIC with every pin still masked -- the route never "
              "landed -- is rejected")
    expect_hw(False, HW_REGS_OK,
              spoil(HW_PIC_OK, "vec=32 ", "vec=33 "),
              "a routed pin delivering the WRONG vector is rejected")
    expect_hw(False, HW_REGS_OK,
              spoil(HW_PIC_OK, "dest=0 vec=32", "dest=3 vec=32"),
              "a routed pin aimed at a processor that is not the BSP is "
              "rejected")
    expect_hw(False, HW_REGS_OK,
              _hw_ioapic(also_open=11) +
              "pic1: irr=00 imr=ff isr=00 hprio=0 irq_base=28 rr_sel=0 "
              "elcr=0c fnm=0\n"
              "pic0: irr=00 imr=ff isr=00 hprio=0 irq_base=20 rr_sel=0 "
              "elcr=00 fnm=0\n",
              "a SECOND pin left unmasked is rejected: it delivers a vector "
              "no gate was installed for")
    expect_hw(False, HW_REGS_OK,
              spoil(HW_PIC_OK, "pic1: irr=00 imr=ff", "pic1: irr=00 imr=fe"),
              "a SLAVE with a line unmasked is rejected: nothing drives one")
    expect_hw(False, spoil(HW_REGS_OK, "ffffffff8010bda0", "ffffffff80108000"),
              HW_PIC_OK,
              "a TR base that is not where fk_tss actually is, is rejected")
    expect_hw(False, spoil(HW_REGS_OK, "00000067", "0000ffff"), HW_PIC_OK,
              "a TSS limit of 0xFFFF (a 16-bit descriptor) is rejected")
    expect_hw(False, spoil(HW_REGS_OK, "00000027", "00000017"), HW_PIC_OK,
              "a GDT still only 3 slots long is rejected")
    expect_hw(False, spoil(HW_REGS_OK, "TSS64-busy", "TSS64-avl"), HW_PIC_OK,
              "a descriptor LTR never marked busy is rejected")
    expect_hw(False, "", HW_PIC_OK,
              "monitor output with no TR line at all is rejected")
    expect_hw(False, HW_REGS_OK, "", "monitor output with no pic lines is "
              "rejected")
    expect_hw(False, HW_REGS_OK, HW_PIC_OK,
              "a TSS whose I/O map base is 0 -- a ring-3 bitmap made of the "
              "TSS's own bytes -- is rejected", tss=_hw_tss(iomap=0))
    expect_hw(False, HW_REGS_OK, HW_PIC_OK,
              "a TSS whose IST1 field was never filled in is rejected",
              tss=_hw_tss(ist1=0))
    expect_hw(True, HW_REGS_OK, HW_PIC_OK,
              "IST1 exactly at the top of the emergency stack is accepted",
              tss=_hw_tss(ist1=0xFFFFFFFF8010BDA0), ist1_want=0xFFFFFFFF8010BDA0)
    expect_hw(False, HW_REGS_OK, HW_PIC_OK,
              "IST1 at the BOTTOM of the emergency stack is rejected",
              tss=_hw_tss(ist1=0xFFFFFFFF80109DA0), ist1_want=0xFFFFFFFF8010BDA0)
    expect_hw(False, HW_REGS_OK, HW_PIC_OK,
              "a short read of the TSS is rejected rather than ignored",
              tss=b"")

    def expect_ticks(ok_wanted, first, second, what, **kw):
        nonlocal pass_n, fail_n
        got = all(ok for ok, _ in check_ticks(first, second, **kw))
        if got == ok_wanted:
            print(f"  \033[32mPASS\033[0m  {what}")
            pass_n += 1
        else:
            print(f"  \033[31mFAIL\033[0m  {what} -- assertion said "
                  f"{'accept' if got else 'reject'}")
            fail_n += 1

    print("=== tick-advance assertion self-test (no QEMU, no kernel) ===")
    expect_ticks(True, 41, 66, "a counter that grew between the two reads is "
                 "accepted")
    expect_ticks(False, 0, 0, "a counter that never moved off zero -- no "
                 "interrupt ever arrived -- is rejected")
    # The one this assertion exists for. A kernel that takes exactly one
    # interrupt and never acknowledges the 8259 leaves a NON-ZERO counter that
    # never grows again, which every console line in the boot is consistent
    # with.
    expect_ticks(False, 1, 1, "a non-zero counter that stopped growing -- one "
                 "interrupt, then no EOI -- is rejected")
    expect_ticks(False, 41, 42, "a single tick between reads is rejected at "
                 "min_delta 2")
    expect_ticks(False, 41, 12, "a counter that went BACKWARDS is rejected")

    # --- roadmap 2.2/2.4 -----------------------------------------------------
    # BGRX8888 as GRUB reports it on this hardware: blue at bit 0, red at 16.
    FB_INFO_OK = dict(tag=FB_MAGIC, base=0xFD000000, pitch=4096, width=1024,
                      height=768, bpp=32, type=1, virt=FB_VIRT_WANT,
                      bytes=4096 * 768, r_pos=16, r_size=8, g_pos=8, g_size=8,
                      b_pos=0, b_size=8)

    # A font in which every glyph is solid: enough to render a signature the
    # checker accepts, and small enough to state in one line.
    FONT_SOLID = bytes([0xFF]) * FONT_BYTES
    FONT_MIRROR = bytes([0x0F]) * FONT_BYTES

    def fb_band(info, colours=None, pitch=4096, glyph_px=400, bar_h=FB_BAR_H,
                text=True, sig_font=FONT_SOLID):
        """A synthetic band: the bar the kernel draws, then a row of text."""
        buf = bytearray(pitch * (FB_BAR_H + FONT_H))
        for y in range(bar_h):
            for i, (_name, rgb) in enumerate(colours or FB_BAR):
                word = fb_pack(info, *rgb)
                for x in range(i * FB_BLOCK, (i + 1) * FB_BLOCK):
                    struct.pack_into("<I", buf, y * pitch + x * 4, word)
        if sig_font is not None:
            sig = fb_pack(info, *FB_SIG_RGB)
            for i, ch in enumerate(FB_SIG):
                for row in range(FONT_H):
                    bits = sig_font[ch * FONT_H + row]
                    for dx in range(FONT_W):
                        if (bits >> (7 - dx)) & 1:
                            x = FB_SIG_X + i * FONT_W + dx
                            struct.pack_into("<I", buf, row * pitch + x * 4, sig)
        if text:
            fg = fb_pack(info, *CON_FG_RGB)
            bg = fb_pack(info, *CON_BG_RGB)
            for y in range(FB_BAR_H, FB_BAR_H + FONT_H):
                for x in range(info["width"]):
                    struct.pack_into("<I", buf, y * pitch + x * 4, bg)
            for n in range(glyph_px):
                y = FB_BAR_H + (n % FONT_H)
                x = n // FONT_H
                struct.pack_into("<I", buf, y * pitch + x * 4, fg)
        return bytes(buf)

    def expect_fb(ok_wanted, info, scanline, what, *, font=FONT_SOLID):
        nonlocal pass_n, fail_n
        got = all(ok for ok, _ in check_framebuffer(info, scanline, font=font))
        if got == ok_wanted:
            print(f"  \033[32mPASS\033[0m  {what}")
            pass_n += 1
        else:
            print(f"  \033[31mFAIL\033[0m  {what} -- assertion said "
                  f"{'accept' if got else 'reject'}")
            fail_n += 1

    print("=== framebuffer assertion self-test (no QEMU, no kernel) ===")
    expect_fb(True, FB_INFO_OK, fb_band(FB_INFO_OK),
              "the bar packed per the loader's masks, with text below it, is "
              "accepted")
    expect_fb(False, dict(FB_INFO_OK, tag=0), fb_band(FB_INFO_OK),
              "an fb_info block the probe never completed is rejected")
    expect_fb(False, dict(FB_INFO_OK, virt=0), fb_band(FB_INFO_OK),
              "a framebuffer the VMM never mapped is rejected")
    expect_fb(False, FB_INFO_OK, bytes(4096 * (FB_BAR_H + FONT_H)),
              "a framebuffer that is still all black is rejected")
    expect_fb(False, FB_INFO_OK, None,
              "a framebuffer that could not be read back at all is rejected")
    # THE ONE THIS EXISTS FOR. A renderer that ignores the reported masks and
    # hardcodes RGB draws every block with red and blue exchanged. Both are
    # non-black, both are 'a bar', and only the per-channel comparison sees it.
    RGB = dict(FB_INFO_OK, r_pos=0, b_pos=16)
    expect_fb(False, FB_INFO_OK, fb_band(RGB),
              "a bar packed RGB where the loader asked for BGR is rejected")
    expect_fb(False, FB_INFO_OK,
              fb_band(FB_INFO_OK, colours=[("red", (255, 0, 0))] * 4),
              "four blocks of the SAME colour are rejected")
    expect_fb(False, FB_INFO_OK, fb_band(FB_INFO_OK)[:64],
              "a truncated pixel dump is rejected rather than ignored")
    # roadmap 2.4. A console that cleared its band and drew nothing looks
    # exactly like a working one from the bar's point of view.
    expect_fb(False, FB_INFO_OK, fb_band(FB_INFO_OK, glyph_px=0),
              "a console band that was cleared but never written to is rejected")
    expect_fb(False, FB_INFO_OK, fb_band(FB_INFO_OK, text=False),
              "a console band still holding the power-on contents is rejected")
    # And the reverse: a band filled solid with the foreground colour is not
    # text either, however many 'glyph' pixels it counts.
    solid = bytearray(fb_band(FB_INFO_OK))
    fgw = fb_pack(FB_INFO_OK, *CON_FG_RGB)
    for y in range(FB_BAR_H, FB_BAR_H + FONT_H):
        for x in range(FB_INFO_OK["width"]):
            struct.pack_into("<I", solid, y * 4096 + x * 4, fgw)
    expect_fb(False, FB_INFO_OK, bytes(solid),
              "a console band filled SOLID with the foreground colour is "
              "rejected")
    # The scroll that reached one row too high: the bar's bottom row now holds
    # console background instead of the bar's own primaries.
    ate_bar = bytearray(fb_band(FB_INFO_OK))
    bgw = fb_pack(FB_INFO_OK, *CON_BG_RGB)
    for x in range(FB_INFO_OK["width"]):
        struct.pack_into("<I", ate_bar, (FB_BAR_H - 1) * 4096 + x * 4, bgw)
    expect_fb(False, FB_INFO_OK, bytes(ate_bar),
              "a console that scrolled one row INTO the status bar is rejected")
    # THE GLYPH-IDENTITY CASES. A renderer that draws a plausible bar and then
    # the WRONG character passes every pixel-count check there is.
    expect_fb(False, FB_INFO_OK, fb_band(FB_INFO_OK, sig_font=None),
              "a status bar with no signature drawn in it is rejected")
    expect_fb(False, FB_INFO_OK, fb_band(FB_INFO_OK, sig_font=FONT_MIRROR),
              "a signature rendered LSB-first -- every glyph mirrored -- is "
              "rejected")
    expect_fb(False, FB_INFO_OK, fb_band(FB_INFO_OK),
              "and a font read back that disagrees with the pixels is rejected, "
              "whichever of the two is wrong", font=FONT_MIRROR)
    expect_fb(False, FB_INFO_OK, fb_band(FB_INFO_OK),
              "a font table that could not be read at all is rejected",
              font=None)

    def expect_fb_panic(ok_wanted, info, band, tail, what):
        nonlocal pass_n, fail_n
        got = all(ok for ok, _ in check_framebuffer(info, band, tail=tail,
                                                    font=FONT_SOLID,
                                                    expect="panic"))
        if got == ok_wanted:
            print(f"  \033[32mPASS\033[0m  {what}")
            pass_n += 1
        else:
            print(f"  \033[31mFAIL\033[0m  {what} -- assertion said "
                  f"{'accept' if got else 'reject'}")
            fail_n += 1

    # The LAST text row of the screen, which is where a panic dump too short to
    # reach the top always ends up.
    # Two rows, glyphs in the UPPER one only -- the shape a finished panic
    # always leaves behind, and the shape a one-row assertion would fail on.
    def text_row(info, fg_rgb, bg_rgb, glyph_px=400, pitch=4096):
        buf = bytearray(pitch * FONT_H * PANIC_TAIL_ROWS)
        fgw, bgw = fb_pack(info, *fg_rgb), fb_pack(info, *bg_rgb)
        for y in range(FONT_H * PANIC_TAIL_ROWS):
            for x in range(info["width"]):
                struct.pack_into("<I", buf, y * pitch + x * 4, bgw)
        for n in range(glyph_px):
            struct.pack_into("<I", buf,
                             (n % FONT_H) * pitch + (n // FONT_H) * 4, fgw)
        return bytes(buf)

    panic_tail = text_row(FB_INFO_OK, PANIC_FG_RGB, PANIC_BG_RGB)
    console_tail = text_row(FB_INFO_OK, CON_FG_RGB, CON_BG_RGB)
    expect_fb_panic(True, FB_INFO_OK, fb_band(FB_INFO_OK), panic_tail,
                    "a last text row in white on red is accepted as a panic, "
                    "even though the top of the screen is untouched")
    # THE ONE THE PANIC MODE EXISTS FOR: the register dump went to COM1 only.
    # Every serial assertion in that build passes and the screen never changed.
    expect_fb_panic(False, FB_INFO_OK, fb_band(FB_INFO_OK), console_tail,
                    "a panic that never reached the screen -- the last row is "
                    "still in the console palette -- is rejected")
    expect_fb_panic(False, FB_INFO_OK, fb_band(FB_INFO_OK), None,
                    "a panic whose last text row could not be read is rejected")

    # --- roadmap 4.0 ---------------------------------------------------------
    SCHED_OK = ([SCHED_MAGIC, 3, 2, 17], [0, 9, 8, 0])
    SCHED_ON = ([SCHED_MAGIC, 3, 3, 31], [0, 11, 10, 0])
    HEAP_OK = [HEAP_MAGIC, 0x42000, 0, 0x42000, 1, 41, 41, 0x42000, 0, 3]
    SCHED_OK_, SCHED_ON_, HEAP_OK_ = SCHED_OK, SCHED_ON, HEAP_OK

    def expect_sched(ok_wanted, first, second, heap, what):
        nonlocal pass_n, fail_n
        got = all(ok for ok, _ in check_sched(first, second, heap))
        if got == ok_wanted:
            print(f"  \033[32mPASS\033[0m  {what}")
            pass_n += 1
        else:
            print(f"  \033[31mFAIL\033[0m  {what} -- assertion said "
                  f"{'accept' if got else 'reject'}")
            fail_n += 1

    # A stack block at a plausible kernel address, and the RSP0 sched_spawn
    # would program for task 2 out of it.
    STACKS_VA = 0xFFFFFFFF80120000
    RSP0_T2 = sched_stack_top(STACKS_VA, 2)
    RSP0_T3 = sched_stack_top(STACKS_VA, 3)

    def tss_with(rsp0):
        b = bytearray(TSS_LIMIT + 1)
        struct.pack_into("<Q", b, 4, rsp0)
        return bytes(b)

    def expect_rsp0(ok_wanted, tss, what):
        nonlocal pass_n, fail_n
        got = all(ok for ok, _ in check_sched(SCHED_OK_, SCHED_ON_, HEAP_OK_,
                                              tss=tss, stacks_vaddr=STACKS_VA,
                                              tasks=3))
        if got == ok_wanted:
            print(f"  \033[32mPASS\033[0m  {what}")
            pass_n += 1
        else:
            print(f"  \033[31mFAIL\033[0m  {what} -- assertion said "
                  f"{'accept' if got else 'reject'}")
            fail_n += 1

    print("=== scheduler assertion self-test (no QEMU, no kernel) ===")
    expect_sched(True, SCHED_OK, SCHED_ON, HEAP_OK,
                 "two threads whose own counters both grew, with the switch "
                 "count growing too, is accepted")
    expect_sched(False, SCHED_OK, SCHED_OK, HEAP_OK,
                 "a machine where nothing moved between the two reads is "
                 "rejected")
    # THE ONE THIS EXISTS FOR. The kernel switched away from the boot thread
    # once, both threads ran once, and then the round robin stuck. Every serial
    # line in that boot is printed BEFORE the sticking and every one passes.
    expect_sched(False, ([SCHED_MAGIC, 3, 2, 2], [0, 1, 1, 0]),
                 ([SCHED_MAGIC, 3, 2, 2], [0, 1, 1, 0]), HEAP_OK,
                 "a scheduler that ran each thread once and then stopped is "
                 "rejected")
    expect_sched(False, ([SCHED_MAGIC, 3, 2, 17], [0, 9, 8, 0]),
                 ([SCHED_MAGIC, 3, 3, 31], [0, 11, 8, 0]), HEAP_OK,
                 "a round robin stuck on ONE of the two threads is rejected, "
                 "even though the total advanced")
    expect_sched(False, ([0, 3, 2, 17], [0, 9, 8, 0]), SCHED_ON, HEAP_OK,
                 "a scheduler state block sched_init never wrote is rejected")
    expect_sched(False, ([SCHED_MAGIC, 1, 1, 17], [0, 9, 8, 0]), SCHED_ON,
                 HEAP_OK, "a kernel that never spawned anything is rejected")
    expect_sched(False, SCHED_OK, SCHED_ON,
                 [HEAP_MAGIC, 0x42000, 0x1050, 0x30FB0, 7, 41, 38, 0x30FB0, 0, 3],
                 "a heap left fragmented -- 7 blocks and bytes still in use -- "
                 "is rejected")
    expect_sched(False, SCHED_OK, SCHED_ON,
                 [HEAP_MAGIC, 0x42000, 0, 0x42000, 1, 41, 41, 0x42000, 0, 0],
                 "a heap that ACCEPTED the three bad frees is rejected")

    expect_rsp0(True, tss_with(RSP0_T2),
                "TSS RSP0 at the top of task 2's stack is accepted")
    expect_rsp0(True, tss_with(RSP0_T3),
                "and task 3's, since either may be the one running")
    # THE ONE THIS EXISTS FOR: tss_set_rsp0 never called. Nothing in ring 0
    # reads RSP0, so every other verdict in the boot is unaffected.
    expect_rsp0(False, tss_with(0),
                "an RSP0 the scheduler never wrote is rejected")
    # The boot stack: right for task 1, wrong once a spawned task is running.
    expect_rsp0(False, tss_with(0xFFFFFFFF8010BDA0),
                "an RSP0 still pointing at the BOOT stack is rejected")
    expect_rsp0(False, tss_with(RSP0_T2 + 8),
                "an RSP0 one quadword above the frame -- the top rather than "
                "the fake return address -- is rejected")

    def dma_run(base=0x6E000, pages=4, seed=0x0DA10DA100000000,
                magic=DMA_MAGIC, corrupt=None, short=False):
        raw = bytearray(b"\x00" * (pages * DMA_PAGE))
        for i in range(pages):
            struct.pack_into("<Q", raw, i * DMA_PAGE,
                             (seed + i) & 0xFFFFFFFFFFFFFFFF)
        if corrupt is not None:
            struct.pack_into("<Q", raw, corrupt * DMA_PAGE, 0xA5A5A5A5A5A5A5A5)
        if short:
            raw = raw[:-8]
        return [magic, base, pages, seed], bytes(raw)

    def expect_dma(ok_wanted, probe, raw, what):
        nonlocal pass_n, fail_n
        got = all(ok for ok, _ in check_dma(probe, raw))
        if got == ok_wanted:
            print(f"  \033[32mPASS\033[0m  {what}")
            pass_n += 1
        else:
            print(f"  \033[31mFAIL\033[0m  {what} -- assertion said "
                  f"{'accept' if got else 'reject'}")
            fail_n += 1

    expect_dma(True, *dma_run(), "a tagged four-frame run is accepted")
    expect_dma(False, *dma_run(magic=0),
               "a run whose probe magic was never written is rejected")
    expect_dma(False, *dma_run(base=0),
               "a base of 0 -- the allocator refused -- is rejected")
    expect_dma(False, *dma_run(base=0x6E800),
               "a base that is not frame aligned is rejected")
    expect_dma(False, *dma_run(pages=0),
               "a run of zero pages is rejected")
    # THE ONE THIS EXISTS FOR: three frames adjacent and the fourth somewhere
    # else. The first three tags land where they should and only the fourth
    # reads as whatever was already in that frame.
    expect_dma(False, *dma_run(corrupt=3),
               "a run whose LAST frame is not where it claims is rejected")
    expect_dma(False, *dma_run(corrupt=1),
               "a run whose second frame is not where it claims is rejected")
    expect_dma(False, *dma_run(short=True),
               "a short read of the run is rejected")

    # roadmap 4.2. The q35 tree this project's own gate meets.
    Q35_PCI = (
        "  Bus  0, device   0, function 0:\n"
        "    Host bridge: PCI device 8086:29c0\n"
        "  Bus  0, device   1, function 0:\n"
        "    VGA controller: PCI device 1234:1111\n"
        "  Bus  0, device  31, function 0:\n"
        "    ISA bridge: PCI device 8086:2918\n"
        "  Bus  0, device  31, function 2:\n"
        "    SATA controller: PCI device 8086:2922\n"
        "  Bus  0, device  31, function 3:\n"
        "    SMBus: PCI device 8086:2930\n"
        "  Bus  0, device   2, function 0:\n"
        "    USB controller: PCI device 1b36:000d\n"
    )
    Q35_FNS = [(0, 0, 0, 0x8086, 0x29C0), (0, 1, 0, 0x1234, 0x1111),
               (0, 2, 0, 0x1B36, 0x000D),
               (0, 31, 0, 0x8086, 0x2918), (0, 31, 2, 0x8086, 0x2922),
               (0, 31, 3, 0x8086, 0x2930)]
    # What the kernel publishes about the xHCI after enabling it: 00:02.0,
    # COMMAND with decode and mastering set beside the I/O bit firmware left,
    # MSI-X at 0x90 with 16 entries in BAR 0, table at 0x3000, BAR0 decoded.
    XHCI_CMD_OK = 0x0107 | (0x0101 << 16) | (0x0107 << 32)
    # ... the entry it read back off the device, and the control/command pair.
    XHCI_MSG_OK = 0xFEE00000 | (0x30 << 32) | (0 << 48)
    XHCI_OK = [0x0010, XHCI_CMD_OK, 0x90 | (16 << 16) | (0 << 32), 0x3000,
               0xFEBF0000, XHCI_MSG_OK, 0x800F | (0x0507 << 16)]
    # What QEMU's device model holds, read back through xp: COMMAND, the
    # capability dword, and the four dwords of table entry 0.
    DEV_OK = {"cmd": 0x00100507, "cap0": 0x800F0011,
              "entry0": [0xFEE00000, 0, 0x30, 0], "bar": 0xFEBF0000,
              "tbl_off": 0x3000}

    def dev(**kw):
        d = dict(DEV_OK)
        d["entry0"] = list(DEV_OK["entry0"])
        for k, v in kw.items():
            if k.startswith("e"):
                d["entry0"][int(k[1:])] = v
            else:
                d[k] = v
        return d

    def pci_words(fns=None, magic=PCI_MAGIC, base=0xB0000000, seen=None,
                  xhci=None):
        fns = Q35_FNS if fns is None else fns
        w = [magic, base, (0 << 8) | 255, len(fns),
             len(fns) if seen is None else seen] + [0] * (PCI_WORDS - 5)
        for i, (b, d, f, ven, dev) in enumerate(fns):
            bdf = (b << 8) | (d << 3) | f
            w[5 + i] = (bdf << 48) | (ven << 32) | (dev << 16)
        w = w[:PCI_WORDS]
        for i, v in enumerate(XHCI_OK if xhci is None else xhci):
            w[PCI_W_XHCI + i] = v
        return w

    def expect_pci(ok_wanted, words, text, what, device=None):
        nonlocal pass_n, fail_n
        got = all(ok for ok, _ in check_pci(words, text, device))
        if got == ok_wanted:
            print(f"  \033[32mPASS\033[0m  {what}")
            pass_n += 1
        else:
            print(f"  \033[31mFAIL\033[0m  {what} -- assertion said "
                  f"{'accept' if got else 'reject'}")
            fail_n += 1

    print("=== PCI enumeration self-test (no QEMU, no kernel) ===")
    expect_pci(True, pci_words(), Q35_PCI,
               "the q35 tree, enumerated exactly, is accepted")
    expect_pci(False, pci_words(magic=0), Q35_PCI,
               "a list whose magic was never written is rejected")
    expect_pci(False, pci_words(base=0), Q35_PCI,
               "an ECAM base of 0 -- no MCFG was found -- is rejected")
    expect_pci(False, pci_words(seen=9), Q35_PCI,
               "a list that kept 5 of 9 seen is rejected as truncated")
    # THE TWO THAT MATTER, and they fail in opposite directions.
    expect_pci(False, pci_words(Q35_FNS[:-1]), Q35_PCI,
               "a guest that MISSED a function QEMU reports is rejected")
    expect_pci(False,
               pci_words(Q35_FNS + [(0, 31, 1, 0x8086, 0x2918)]), Q35_PCI,
               "a guest that INVENTED 00:1f.1 -- the multifunction bit "
               "ignored -- is rejected")
    expect_pci(False,
               pci_words([(b, d, f, ven ^ 1, dev) for b, d, f, ven, dev
                          in Q35_FNS]), Q35_PCI,
               "a guest whose vendor ids do not match QEMU's is rejected")
    expect_pci(False, pci_words(), "", "monitor output with no PCI tree is "
               "rejected")
    # A function QEMU printed a header for and no identity line under: it must
    # go missing rather than inherit the next one's vendor:device.
    expect_pci(False, pci_words(),
               "  Bus  0, device   0, function 0:\n"
               "    Host bridge: PCI device 8086:29c0\n"
               "  Bus  0, device   1, function 0:\n"
               "  Bus  0, device  31, function 0:\n"
               "    ISA bridge: PCI device 8086:2918\n",
               "a QEMU function with no identity line does not inherit one")

    # roadmap 4.2's debt. Each of these is a controller the kernel would have
    # reported as ready and that cannot do the job.
    # THE ONE THAT ESCAPED A WEAKER GATE: firmware left both bits set and the
    # kernel wrote nothing, so the final reading is perfect and the cleared
    # one never happened.
    expect_pci(False, pci_words(xhci=[0x0010, 0x0107 | (0x0107 << 16) |
                                      (0x0107 << 32), XHCI_OK[2], 0x3000,
                                      0xFEBF0000]), Q35_PCI,
               "an xHCI the kernel never actually wrote to -- firmware had "
               "already set both bits -- is rejected")
    expect_pci(False, pci_words(xhci=[0x0010, 0x0107 | (0x0101 << 16) |
                                      (0x0105 << 32), XHCI_OK[2], 0x3000,
                                      0xFEBF0000]), Q35_PCI,
               "one that came back up WITHOUT bus mastering is rejected")
    expect_pci(False, pci_words(xhci=[0x0010, 0x0107 | (0x0101 << 16) |
                                      (0x0103 << 32), XHCI_OK[2], 0x3000,
                                      0xFEBF0000]), Q35_PCI,
               "one that came back up without memory-space decode is rejected")
    expect_pci(False, pci_words(xhci=[0x0010, 0x0107 | (0x0001 << 16) |
                                      (0x0107 << 32), XHCI_OK[2], 0x3000,
                                      0xFEBF0000]), Q35_PCI,
               "a write that also cleared SERR -- the status half echoed back "
               "as a mask -- is rejected")
    # 0x28 is 00:05.0, an empty slot on this machine. A guest that enabled
    # something there enabled nothing.
    expect_pci(False, pci_words(xhci=[0x0028, XHCI_CMD_OK, XHCI_OK[2], 0x3000,
                                      0xFEBF0000]), Q35_PCI,
               "one published at a BDF QEMU has no function at is rejected")
    expect_pci(False, pci_words(xhci=[0x0010, XHCI_CMD_OK, 0x90, 0x3000,
                                      0xFEBF0000]), Q35_PCI,
               "an MSI-X table of zero entries -- the N-1 encoding taken "
               "literally -- is rejected")
    expect_pci(False, pci_words(xhci=[0x0010, XHCI_CMD_OK, 0x20 | (16 << 16),
                                      0x3000, 0xFEBF0000]), Q35_PCI,
               "a capability offset inside the 64-byte header is rejected")
    expect_pci(False, pci_words(xhci=[0x0010, XHCI_CMD_OK, XHCI_OK[2], 0x600,
                                      0xFEBF0000 | 4]), Q35_PCI,
               "a BAR0 with its type bits left in is rejected")
    expect_pci(True, pci_words(xhci=[0, 0, 0, 0, 0, 0, 0]), Q35_PCI,
               "a machine with no xHCI published skips the xHCI checks")

    # roadmap 5.1, and these are the ones the guest cannot talk its way out
    # of: every reading comes out of QEMU's device model through xp.
    print("--- the route, as the DEVICE holds it ---")
    expect_pci(True, pci_words(), Q35_PCI,
               "a device whose table entry 0 is programmed and unmasked is "
               "accepted", DEV_OK)
    expect_pci(False, pci_words(), Q35_PCI,
               "one whose entry is STILL MASKED is rejected -- a route the "
               "device will never use", dev(e3=1))
    expect_pci(False, pci_words(), Q35_PCI,
               "one whose entry was never written is rejected", dev(e0=0))
    expect_pci(False, pci_words(), Q35_PCI,
               "one carrying a vector nothing installed is rejected",
               dev(e2=0x99))
    expect_pci(False, pci_words(), Q35_PCI,
               "one whose high address half is not zero is rejected",
               dev(e1=0xDEADBEEF))
    expect_pci(False, pci_words(), Q35_PCI,
               "one with MSI-X still disabled in its capability is rejected",
               dev(cap0=0x000F0011))
    expect_pci(False, pci_words(), Q35_PCI,
               "one with the function-wide mask still set is rejected",
               dev(cap0=0xC00F0011))
    expect_pci(False, pci_words(), Q35_PCI,
               "one whose INTx is still enabled is rejected",
               dev(cmd=0x00100107))
    expect_pci(False, pci_words(), Q35_PCI,
               "a BAR that is not decoded at all is rejected", 
               {"unmapped": True, "cmd": 0, "cap0": 0})

    # THE TWO WITNESSES AGAINST EACH OTHER.
    expect_pci(False, pci_words(xhci=XHCI_OK[:5] + [XHCI_MSG_OK, 0x800F |
                                                    (0x0507 << 16)]),
               Q35_PCI,
               "a guest that reports a route the device does not hold is "
               "rejected", dev(e2=0x31))

    # roadmap 5.1's ring checker, which had NO self-test until the phase-4/5
    # mutation sweep went looking for one. check_pci was covered; this was not,
    # so every green "xHCI controller : PASS" rested on an assertion nothing
    # had ever watched refuse.
    print("--- the rings, as the CONTROLLER left them in DRAM ---")

    RING_CMD, RING_EVT, RING_ERST = 0x348000, 0x349000, 0x34A000
    RING_DCBAA, RING_TRB = 0x347000, 0x348000

    def trb(parm=0, status=0, control=0):
        return struct.pack("<QII", parm, status, control)

    def rings_cmd(noop_ctrl=(TRB_TYPE_CMD_NOOP << 10) | 1, noop_parm=0,
                  noop_status=0, link_ctrl=(6 << 10) | 2 | 1,
                  link_parm=RING_CMD):
        b = bytearray(4096)
        b[0:16] = trb(noop_parm, noop_status, noop_ctrl)
        b[255 * 16:256 * 16] = trb(link_parm, 0, link_ctrl)
        return bytes(b)

    def rings_evt(ctrl=(TRB_TYPE_COMPLETION << 10) | 1, comp=COMP_SUCCESS,
                  parm=RING_TRB):
        b = bytearray(4096)
        b[0:16] = trb(parm, comp << 24, ctrl)
        return bytes(b)

    def rings_words(**kw):
        w = [0] * XHCI_WORDS
        w[0] = XHCI_MAGIC
        w[1] = 0xFEBF0000
        w[2] = RING_DCBAA
        w[3], w[4], w[5] = RING_CMD, RING_EVT, RING_ERST
        w[6] = RING_TRB
        w[7] = (TRB_TYPE_COMPLETION << 32) | COMP_SUCCESS
        w[8] = RING_TRB
        w[15] = 0
        w[16], w[17] = 0, 0
        w[18] = 1                      # halted, CNR clear
        for k, v in kw.items():
            w[int(k[1:])] = v
        return w

    # usbsts, usbcmd, crcr, erdp, iman, dcbaap
    REGS_OK = (0x00000008, 0x00000005, RING_CMD, RING_EVT + 16, 0x00000002,
               RING_DCBAA)

    def regs(**kw):
        names = ["usbsts", "usbcmd", "crcr", "erdp", "iman", "dcbaap"]
        r = list(REGS_OK)
        for k, v in kw.items():
            r[names.index(k)] = v
        return tuple(r)

    def expect_rings(ok_wanted, what, words=None, cmd=None, evt=None,
                     rg=None, msi=1):
        nonlocal pass_n, fail_n
        got = all(ok for ok, _ in check_xhci_rings(
            rings_words() if words is None else words,
            rings_cmd() if cmd is None else cmd,
            rings_evt() if evt is None else evt,
            REGS_OK if rg is None else rg, msi))
        if got == ok_wanted:
            print(f"  \033[32mPASS\033[0m  {what}")
            pass_n += 1
        else:
            print(f"  \033[31mFAIL\033[0m  {what} "
                  f"(wanted {ok_wanted}, got {got})")
            fail_n += 1

    expect_rings(True, "a complete, correct bring-up is accepted")
    expect_rings(False, "a state block with no magic is rejected",
                 words=rings_words(w0=0))
    expect_rings(False, "a non-zero bring-up status is rejected",
                 words=rings_words(w15=0xFFFFFFFFFFFFFFF9))
    # THE RESET, and the three readings that are firmware's unless it ran.
    expect_rings(False, "a CRCR that still holds firmware's pointer straight "
                        "after the reset is rejected",
                 words=rings_words(w16=0x7FFDFC01))
    expect_rings(False, "a DCBAAP that still holds firmware's is rejected",
                 words=rings_words(w17=0x7FFDFD80))
    expect_rings(False, "a controller that was not halted at that moment is "
                        "rejected", words=rings_words(w18=0))
    expect_rings(False, "one whose CNR was still set is rejected",
                 words=rings_words(w18=1 | (1 << 11)))
    expect_rings(False, "a ring that is not 64-byte aligned is rejected",
                 words=rings_words(w3=RING_CMD + 8, w6=RING_TRB + 8))
    expect_rings(False, "a published TRB outside its own ring is rejected "
                        "rather than crashing the gate",
                 words=rings_words(w6=RING_CMD - 0x1000))
    # THE COMMAND RING, in DRAM.
    expect_rings(False, "a command TRB that is not a NO-OP is rejected",
                 cmd=rings_cmd(noop_ctrl=(1 << 10) | 1))
    expect_rings(False, "a NO-OP whose cycle bit is clear is rejected -- the "
                        "controller never owned it",
                 cmd=rings_cmd(noop_ctrl=TRB_TYPE_CMD_NOOP << 10))
    expect_rings(False, "a NO-OP with a non-zero parameter is rejected",
                 cmd=rings_cmd(noop_parm=1))
    expect_rings(False, "a ring whose last TRB is not a LINK is rejected",
                 cmd=rings_cmd(link_ctrl=(1 << 10) | 1))
    expect_rings(False, "a LINK without Toggle Cycle is rejected -- the ring "
                        "goes silent after exactly one lap",
                 cmd=rings_cmd(link_ctrl=(6 << 10) | 1))
    expect_rings(False, "a LINK pointing somewhere other than the ring base "
                        "is rejected", cmd=rings_cmd(link_parm=RING_EVT))
    # THE EVENT RING, which the CONTROLLER wrote.
    expect_rings(False, "an event that is not a Command Completion is "
                        "rejected", evt=rings_evt(ctrl=(32 << 10) | 1))
    expect_rings(False, "an event with cycle 0 is rejected -- that is a "
                        "zeroed segment, not a posted event",
                 evt=rings_evt(ctrl=TRB_TYPE_COMPLETION << 10))
    expect_rings(False, "a completion code other than SUCCESS is rejected",
                 evt=rings_evt(comp=5))
    expect_rings(False, "an event naming a TRB the kernel did not enqueue is "
                        "rejected", evt=rings_evt(parm=RING_CMD + 0x40))
    # THE DEVICE MODEL'S OWN REGISTERS.
    expect_rings(False, "a halted controller is rejected",
                 rg=regs(usbsts=0x00000009))
    expect_rings(False, "one reporting a host controller error is rejected",
                 rg=regs(usbsts=0x00001008))
    expect_rings(False, "one with R/S clear is rejected",
                 rg=regs(usbcmd=0x00000004))
    expect_rings(False, "one with USBCMD.INTE clear is rejected",
                 rg=regs(usbcmd=0x00000001))
    expect_rings(False, "one whose interrupter is not enabled is rejected",
                 rg=regs(iman=0x00000001))
    expect_rings(False, "a CRCR holding something other than the kernel's "
                        "command ring is rejected", rg=regs(crcr=RING_EVT))
    expect_rings(False, "an ERDP that never advanced is rejected -- the event "
                        "was posted and never consumed",
                 rg=regs(erdp=RING_EVT))
    expect_rings(False, "an ERDP past the end of its own segment is rejected",
                 rg=regs(erdp=RING_EVT + 256 * 16))
    expect_rings(True, "an ERDP deep inside the segment is accepted -- "
                       "enumeration consumes many events, not one",
                 rg=regs(erdp=RING_EVT + 13 * 16))
    # THE ONE M59 FOUND. A NO-OP touches no slot, so every assertion above
    # passes with DCBAAP still zero.
    expect_rings(False, "a DCBAAP the kernel never wrote is rejected",
                 rg=regs(dcbaap=0))
    expect_rings(False, "a DCBAAP pointing somewhere other than the device "
                        "context base array is rejected",
                 rg=regs(dcbaap=RING_EVT))
    expect_rings(False, "a controller that completed its command and sent no "
                        "message is rejected", msi=0)

    print(f"=== {pass_n} passed, {fail_n} failed ===")
    return 1 if fail_n else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("addr", help="physical address of the sentinel")
    a.add_argument("elf")
    a.add_argument("--symbol", default=SENTINEL_SYMBOL)

    d = sub.add_parser("dump", help="pmemsave the sentinel via QMP")
    d.add_argument("--qmp", required=True)
    d.add_argument("--elf", required=True)
    d.add_argument("--out", required=True)
    d.add_argument("--timeout", type=float, default=10.0)
    d.add_argument("--no-quit", action="store_true")

    q = sub.add_parser("quit", help="shut the guest down")
    q.add_argument("--qmp", required=True)
    q.add_argument("--timeout", type=float, default=5.0)

    c = sub.add_parser("check", help="assert the sentinel contract")
    c.add_argument("dumpfile")
    c.add_argument("--quiet", action="store_true")

    w = sub.add_parser("hwstate", help="assert TR and the 8259s over QMP")
    w.add_argument("--qmp", required=True)
    w.add_argument("--elf", required=True)
    w.add_argument("--timeout", type=float, default=10.0)
    w.add_argument("--tr-sel", type=lambda v: int(v, 0), default=0x18)
    w.add_argument("--tss-limit", type=lambda v: int(v, 0), default=TSS_LIMIT)
    w.add_argument("--gdt-limit", type=lambda v: int(v, 0), default=GDT_LIMIT)
    w.add_argument("--master", type=lambda v: int(v, 0), default=0x20)
    w.add_argument("--slave", type=lambda v: int(v, 0), default=0x28)
    w.add_argument("--master-imr", type=lambda v: int(v, 0), default=MASTER_IMR)
    w.add_argument("--slave-imr", type=lambda v: int(v, 0), default=SLAVE_IMR)
    w.add_argument("--quiet", action="store_true")

    f = sub.add_parser("fb", help="assert the framebuffer over QMP")
    f.add_argument("--qmp", required=True)
    f.add_argument("--elf", required=True)
    f.add_argument("--timeout", type=float, default=10.0)
    f.add_argument("--quiet", action="store_true")
    f.add_argument("--expect", choices=("console", "panic"), default="console",
                   help="which palette the console band must be carrying")

    n = sub.add_parser("sched", help="assert the scheduler and heap over QMP")
    n.add_argument("--qmp", required=True)
    n.add_argument("--elf", required=True)
    n.add_argument("--timeout", type=float, default=10.0)
    n.add_argument("--interval", type=float, default=0.25)
    n.add_argument("--quiet", action="store_true")

    t = sub.add_parser("ticks", help="assert the guest is still ticking")
    t.add_argument("--qmp", required=True)
    t.add_argument("--elf", required=True)
    t.add_argument("--timeout", type=float, default=10.0)
    t.add_argument("--interval", type=float, default=0.25)
    t.add_argument("--min-delta", type=int, default=2)
    t.add_argument("--quiet", action="store_true")

    k = sub.add_parser("usbkbd", help="inject keys and assert the HID path")
    k.add_argument("--qmp", required=True)
    k.add_argument("--elf", required=True)
    k.add_argument("--timeout", type=float, default=30.0)
    k.add_argument("--quiet", action="store_true")
    k.add_argument("--keys", default="shift+,a+,a-,shift-,a+,b+,b-,a-")
    k.add_argument("--chars", default="Aab")
    k.add_argument("--report", default="0x40000")

    m = sub.add_parser("dma", help="assert the DMA run at its physical base")
    m.add_argument("--qmp", required=True)
    m.add_argument("--elf", required=True)
    m.add_argument("--timeout", type=float, default=10.0)
    m.add_argument("--quiet", action="store_true")

    x = sub.add_parser("xhci", help="the xHCI's rings, read where the "
                                     "controller wrote them")
    x.add_argument("--qmp", required=True)
    x.add_argument("--elf", required=True)
    x.add_argument("--timeout", type=float, default=10.0)
    x.add_argument("--quiet", action="store_true")

    c2 = sub.add_parser("pci", help="the guest's PCI list against QEMU's")
    c2.add_argument("--qmp", required=True)
    c2.add_argument("--elf", required=True)
    c2.add_argument("--timeout", type=float, default=10.0)
    c2.add_argument("--quiet", action="store_true")

    sub.add_parser("selftest", help="prove the assertion can fail")

    args = ap.parse_args(argv)
    try:
        if args.cmd == "addr":
            vaddr, paddr = symbol_phys_addr(args.elf, args.symbol)
            print(f"0x{paddr:X}")
            print(f"# {args.symbol}: vaddr 0x{vaddr:016X} -> paddr 0x{paddr:X}",
                  file=sys.stderr)
            return 0
        if args.cmd == "dump":
            return do_dump(args.qmp, args.elf, args.out, args.timeout,
                           not args.no_quit)
        if args.cmd == "hwstate":
            return do_hwstate(args.qmp, args.elf, args.timeout, args.quiet,
                              tr_sel=args.tr_sel, tss_limit=args.tss_limit,
                              gdt_limit=args.gdt_limit, master=args.master,
                              slave=args.slave, master_imr=args.master_imr,
                              slave_imr=args.slave_imr)
        if args.cmd == "fb":
            return do_framebuffer(args.qmp, args.elf, args.timeout, args.quiet,
                                  expect=args.expect)
        if args.cmd == "sched":
            return do_sched(args.qmp, args.elf, args.timeout, args.quiet,
                            interval=args.interval)
        if args.cmd == "pci":
            return do_pci(args.qmp, args.elf, args.timeout, args.quiet)
        if args.cmd == "dma":
            return do_dma(args.qmp, args.elf, args.timeout, args.quiet)
        if args.cmd == "xhci":
            return do_xhci(args.qmp, args.elf, args.timeout, args.quiet)
        if args.cmd == "usbkbd":
            return do_usbkbd(args.qmp, args.elf, args.timeout, args.quiet,
                             keys=tuple((k[:-1], k[-1] == "+")
                                        for k in args.keys.split(",")),
                             chars=args.chars,
                             report=int(args.report, 0))
        if args.cmd == "ticks":
            return do_ticks(args.qmp, args.elf, args.timeout, args.quiet,
                            interval=args.interval, min_delta=args.min_delta)
        if args.cmd == "quit":
            return do_quit(args.qmp, args.timeout)
        if args.cmd == "check":
            data = open(args.dumpfile, "rb").read()
            return 0 if report(decode(data), args.quiet) else 1
        if args.cmd == "selftest":
            return do_selftest()
    except QmpError as exc:
        print(f"qmp-sentinel: {exc}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
