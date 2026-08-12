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
    selftest  prove the assertion PASSES on a synthetic good dump and FAILS on
              every corrupted one -- no QEMU and no kernel required

Stdlib only. Runs on the host; never inside the guest.
"""

import argparse
import errno
import json
import socket
import struct
import sys
import time

# --- the sentinel contract (mirrors src/boot/fk_kmain.f90) -----------------
SENTINEL_SYMBOL = "fk_boot_sentinel"
SENTINEL_WORDS = 4
SENTINEL_BYTES = SENTINEL_WORDS * 4

FK_BOOT_TAG = 0x4B424F54            # "KBOT"
MB2_BOOTLOADER_MAGIC = 0x36D76289   # what a compliant loader leaves in EAX
FK_UNWRITTEN = 0x11111111           # the .data initialiser: "never ran"


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
            st_name, _info, _other, _shndx, st_value, _size = \
                struct.unpack_from("<IBBHQQ", d, p)
            end = d.index(b"\0", stroff + st_name)
            if d[stroff + st_name:end].decode() == name:
                for vaddr, paddr, memsz in loads:
                    if vaddr <= st_value < vaddr + memsz:
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
