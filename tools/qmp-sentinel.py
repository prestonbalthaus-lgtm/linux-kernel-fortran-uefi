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
