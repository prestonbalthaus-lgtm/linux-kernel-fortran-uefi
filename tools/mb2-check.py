#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Validate the Multiboot2 header of a linked kernel image (roadmap 1.2).

WHY THIS EXISTS ALONGSIDE grub2-file

`grub2-file --is-x86-multiboot2` is the mandated gate and it is genuinely
useful, but it answers exactly one question: is there a well-formed Multiboot2
header in the first 32 KiB?  It says nothing about whether the image it is
attached to can actually be ENTERED, and for a higher-half kernel that gap is
the whole problem.

THE RULE THIS FILE ENCODES, LEARNED THE EXPENSIVE WAY

A boot loader jumps to the entry point in 32-bit protected mode with paging
off, so the address it jumps to must be PHYSICAL.  The obvious conclusion --
put a physical address in e_entry -- produces an image GRUB refuses to load:

    grub_multiboot_load_elf64:237: entry point isn't in a segment

Because GRUB performs the higher-half translation itself.  It searches for the
PT_LOAD whose VIRTUAL range [p_vaddr, p_vaddr + p_memsz) contains e_entry and
re-expresses that address in the same segment's physical (p_paddr) terms.  So
e_entry must be VIRTUAL, and a Multiboot2 entry-address tag -- which is
absolute and physical -- must agree with the translation.

Both of those are checkable here, statically, and neither is checkable by
grub2-file.  The image that provoked the error above passed
`grub2-file --is-x86-multiboot2` with exit code 0.

A grep for the magic bytes would not do either.  `.set MB2_MAGIC, 0xE85250D6`
in boot.S puts an absolute symbol into .symtab whose 8-byte value begins
D6 50 52 E8 at an 8-byte-aligned offset, so a byte-grep can "find the header"
in an image whose real header has been destroyed.  Every candidate here is
therefore validated the way a loader validates it -- by its checksum.

Stdlib only; no pyelftools.  Usage: tools/mb2-check.py <image> [--quiet]
"""
import struct
import sys

MB2_MAGIC = 0xE85250D6
MB2_SEARCH_LIMIT = 32768        # the specification's scan window
MB2_ARCH_I386 = 0
TAG_END, TAG_ENTRY_ADDR = 0, 3
PT_LOAD = 1
U32 = 1 << 32


class Report:
    """PASS/FAIL accumulator. Every check prints; the exit code is the verdict."""

    def __init__(self, quiet=False):
        self.quiet, self.passed, self.failed = quiet, 0, 0

    def ok(self, msg):
        self.passed += 1
        if not self.quiet:
            print(f"  \033[32mPASS\033[0m  {msg}")

    def bad(self, msg, *detail):
        self.failed += 1
        print(f"  \033[31mFAIL\033[0m  {msg}")
        for d in detail:
            print(f"        {d}")

    def check(self, cond, good, bad, *detail):
        self.ok(good) if cond else self.bad(bad, *detail)
        return bool(cond)


def parse_elf64(data, r):
    """Return (e_entry, [PT_LOAD segments]) or None if this is not our ELF."""
    if len(data) < 64 or data[:4] != b"\x7fELF":
        r.bad("not an ELF file")
        return None
    if data[4] != 2 or data[5] != 1:
        r.bad("not a little-endian 64-bit ELF (a Multiboot2 kernel here is ELF64 LSB)")
        return None
    e_type, _mach = struct.unpack_from("<HH", data, 16)
    r.check(e_type == 2, "ELF type is EXEC",
            f"ELF type is {e_type}, expected 2 (EXEC) -- a PIE or REL image "
            "has no fixed load address for a loader to honour")
    e_entry, e_phoff = struct.unpack_from("<QQ", data, 24)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 54)
    segs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if off + 56 > len(data):
            break
        p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz = \
            struct.unpack_from("<IIQQQQQ", data, off)
        if p_type == PT_LOAD:
            segs.append(dict(offset=p_offset, vaddr=p_vaddr, paddr=p_paddr,
                             filesz=p_filesz, memsz=p_memsz, flags=p_flags))
    r.check(bool(segs), f"{len(segs)} PT_LOAD segment(s) present",
            "no PT_LOAD segments: nothing would be loaded")
    return e_entry, segs


def find_header(data, r):
    """Locate the one header candidate whose checksum is valid."""
    window = data[:MB2_SEARCH_LIMIT]
    needle = struct.pack("<I", MB2_MAGIC)
    found_any = found_aligned = False
    pos = window.find(needle)
    while pos != -1:
        found_any = True
        if pos % 8 == 0 and pos + 16 <= len(window):
            found_aligned = True
            magic, arch, length, cksum = struct.unpack_from("<4I", window, pos)
            if (magic + arch + length + cksum) % U32 == 0:
                r.ok(f"Multiboot2 header at file offset {pos} "
                     f"(< {MB2_SEARCH_LIMIT}, 8-byte aligned, checksum valid)")
                return pos, length
        pos = window.find(needle, pos + 1)

    if not found_any:
        r.bad("no Multiboot2 magic (D6 50 52 E8) in the first 32 KiB",
              "GRUB would reject this image outright.",
              "Check the .multiboot_header section placement in linker.ld --",
              "it must be the first output section -- and that KEEP() is on it.")
    elif not found_aligned:
        r.bad("Multiboot2 magic present but never 8-byte aligned",
              "The specification requires 8-byte alignment.",
              "Add ALIGN(8) to the .multiboot_header output section.")
    else:
        r.bad("aligned magic found, but no candidate has a valid checksum",
              "magic + architecture + header_length + checksum must be 0 mod 2^32.",
              "The only hits are stale constants (e.g. the MB2_MAGIC absolute",
              "symbol in .symtab), not a real header.")
    return None, None


def parse_tags(data, hdr_off, length, r):
    """Walk the tag list. Returns {type: (size, payload_offset)}."""
    tags, p, end = {}, hdr_off + 16, hdr_off + length
    r.check(length >= 24, f"header_length = {length} bytes",
            f"header_length = {length}: too small to hold even an end tag")
    saw_end = False
    while p + 8 <= end:
        t, flags, size = struct.unpack_from("<HHI", data, p)
        if size < 8:
            r.bad(f"tag at +{p - hdr_off} declares size {size} (minimum is 8)")
            return tags
        if p % 8 != 0:
            r.bad(f"tag of type {t} at +{p - hdr_off} is not 8-byte aligned",
                  "every tag must start on an 8-byte boundary; the padding after",
                  "an odd-sized tag is the caller's responsibility (.align 8)")
        tags[t] = (size, p + 8)
        if t == TAG_END:
            saw_end = size == 8 and p + 8 == end
            r.check(size == 8, "end tag has size 8",
                    f"end tag has size {size}, must be 8")
            r.check(p + 8 == end, "end tag is the last thing in the header",
                    f"end tag ends at +{p + 8 - hdr_off} but header_length is {length}")
            break
        p += (size + 7) // 8 * 8      # tags are padded up to 8-byte alignment
    r.check(saw_end or TAG_END in tags, "tag list is terminated by a type-0 tag",
            "the tag list has no type-0/size-8 terminator: a loader would walk "
            "off the end of the header")
    return tags


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("-")]
    quiet = "--quiet" in argv[1:]
    if len(args) != 1:
        print(__doc__)
        return 2
    path = args[0]
    with open(path, "rb") as fh:
        data = fh.read()

    r = Report(quiet)
    if not quiet:
        print(f"=== Multiboot2 conformance: {path} ({len(data)} bytes) ===")

    elf = parse_elf64(data, r)
    hdr_off, length = find_header(data, r)

    if hdr_off is not None and elf is not None:
        e_entry, segs = elf
        _magic, arch, _length, _cks = struct.unpack_from("<4I", data, hdr_off)
        r.check(arch == MB2_ARCH_I386, "architecture = 0 (32-bit i386)",
                f"architecture = {arch}: only 0 (i386) is meaningful for an "
                "x86 kernel entered in protected mode")

        tags = parse_tags(data, hdr_off, length, r)

        # The header must live inside a segment that is actually loaded --
        # a header sitting in a section the loader never maps is decoration.
        in_load = any(s["offset"] <= hdr_off < s["offset"] + s["filesz"] for s in segs)
        r.check(in_load, "the header lies inside a PT_LOAD segment",
                "the header is in the file but outside every PT_LOAD: it would "
                "be found by a scan and then never loaded")

        # --- the checks grub2-file cannot make ---------------------------
        # GRUB's own rule, reproduced exactly (multiboot_elfxx.c): find the
        # PT_LOAD whose VIRTUAL range contains e_entry. No match is the
        # "entry point isn't in a segment" refusal.
        home = [s for s in segs
                if s["vaddr"] <= e_entry < s["vaddr"] + s["memsz"]]
        entered = r.check(
            bool(home),
            f"e_entry 0x{e_entry:016X} is inside a PT_LOAD's VIRTUAL range "
            f"(0x{home[0]['vaddr']:X}..0x{home[0]['vaddr'] + home[0]['memsz']:X})"
            if home else "",
            f"e_entry 0x{e_entry:016X} is inside no PT_LOAD's virtual range",
            "This is verbatim what GRUB rejects with",
            "  grub_multiboot_load_elf64: entry point isn't in a segment",
            "e_entry must be the VIRTUAL address (ENTRY(_start), not a physical",
            "alias): GRUB translates it into physical terms itself.")

        phys_entry = None
        if home:
            seg = home[0]
            phys_entry = e_entry - seg["vaddr"] + seg["paddr"]
            r.check(phys_entry < U32,
                    f"the translated entry 0x{phys_entry:08X} is a 32-bit "
                    "physical address",
                    f"the translated entry 0x{phys_entry:X} does not fit in 32 bits",
                    "the loader jumps here in 32-bit protected mode")
            r.check(e_entry - seg["vaddr"] < seg["filesz"],
                    "the entry point is inside the segment's FILE-backed part",
                    "the entry point is in the zero-filled tail of its segment: "
                    "the loader would jump into memory nothing was written to")
            r.check(seg["flags"] & 1, "the entry segment is executable",
                    "the segment containing the entry point is not marked "
                    "executable")

        if r.check(TAG_ENTRY_ADDR in tags, "entry address tag (type 3) present",
                   "no entry address tag: loaders that do not translate e_entry "
                   "themselves have no physical address to jump to"):
            size, payload = tags[TAG_ENTRY_ADDR]
            r.check(size == 12, "entry address tag has size 12",
                    f"entry address tag has size {size}, must be 12")
            entry_addr = struct.unpack_from("<I", data, payload)[0]
            if entered and phys_entry is not None:
                r.check(entry_addr == phys_entry,
                        f"entry_addr 0x{entry_addr:08X} agrees with the "
                        f"translation of e_entry",
                        f"entry_addr 0x{entry_addr:08X} != translated e_entry "
                        f"0x{phys_entry:08X}",
                        "the tag and the ELF header name different instructions;",
                        "which one runs depends on the loader, so one of the two",
                        "is a latent triple fault")

    if not quiet:
        print(f"=== {r.passed} passed, {r.failed} failed ===")
    elif r.failed:
        print(f"mb2-check: {r.failed} failure(s) in {path}")
    return 1 if r.failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
