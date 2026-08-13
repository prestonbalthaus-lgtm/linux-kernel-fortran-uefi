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
# The master's line 0 is open and every other line on both chips is masked.
# NOT 0xFF any more, and the change is the milestone: before 3.2b this kernel
# could not have survived an interrupt, so masking everything was the only safe
# state. A master IMR of 0xFF now means the timer was never let through.
MASTER_IMR = 0xFE
SLAVE_IMR = 0xFF

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


def check_hwstate(regs_text, pic_text, tss_vaddr, tss_bytes=None,
                  ist1_want=None,
                  tr_sel=0x18, tss_limit=TSS_LIMIT, gdt_limit=GDT_LIMIT,
                  master=0x20, slave=0x28,
                  master_imr=MASTER_IMR, slave_imr=SLAVE_IMR):
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

def check_sched(first, second, heap):
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
        time.sleep(interval)
        second = (read_words(client, st_paddr, SCHED_WORDS),
                  read_words(client, runs_paddr, RUNS_TASKS))
    finally:
        client.close()
        os.unlink(tmp.name)
    results = check_sched(first, second, heap)
    if not report_hwstate(results, quiet):
        print(f"        {SCHED_SYMBOL} at 0x{st_paddr:X}, {RUNS_SYMBOL} at "
              f"0x{runs_paddr:X}, {HEAP_SYMBOL} at 0x{heap_paddr:X}")
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
HW_PIC_OK = (
    "pic1: irr=00 imr=ff isr=00 hprio=0 irq_base=28 rr_sel=0 elcr=0c fnm=0\n"
    "pic0: irr=00 imr=fe isr=00 hprio=0 irq_base=20 rr_sel=0 elcr=00 fnm=0\n"
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
              spoil(HW_PIC_OK, "imr=fe isr=00 hprio=0 irq_base=20",
                    "imr=00 isr=00 hprio=0 irq_base=20"),
              "a master that was remapped but never masked is rejected")
    # roadmap 3.2b's, and the direction is the opposite one: fully masked was
    # the CORRECT state until this milestone, so a gate that still accepts it
    # would pass a kernel whose timer interrupt can never be delivered.
    expect_hw(False, HW_REGS_OK,
              spoil(HW_PIC_OK, "imr=fe isr=00 hprio=0 irq_base=20",
                    "imr=ff isr=00 hprio=0 irq_base=20"),
              "a master with IRQ0 still masked -- the pre-3.2b state -- is "
              "rejected")
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
