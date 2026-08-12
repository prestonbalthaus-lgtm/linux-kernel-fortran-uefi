#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Prove the Multiboot2 header gate can FAIL before trusting the fact that it
# passes.
#
# A gate that has never rejected anything is not evidence, it is decoration.
# This takes the real linked image, injects one defect at a time into a copy,
# and requires the gate to reject every one of them -- then requires the
# untouched image to pass, so that a gate which rejects everything is caught
# too.
#
# It also measures the thing the project actually needs to know: WHICH of the
# two checkers catches which defect. Two of the mutations below are accepted by
# grub2-file and produce a kernel that cannot be entered. That is not a
# criticism of grub2-file -- it validates a header, and the header is valid --
# it is the reason tools/mb2-check.py exists.
#
# Usage: tools/mb2-selftest.sh <kernel.elf>       (runs inside the container)
set -uo pipefail
cd "$(dirname "$0")/.."

IMG="${1:-build/boot/kernel.elf}"
[[ -f "$IMG" ]] || { echo "  FAIL  no image at $IMG"; exit 1; }

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf "  \033[32mPASS\033[0m  %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; fail=$((fail+1)); }
note() { printf "        %s\n" "$1"; }

# mutate <out> <name> -- byte surgery on a copy of the image.
mutate() {
  cp "$IMG" "$1"
  python3 - "$1" "$2" <<'PY'
import struct, sys
path, what = sys.argv[1], sys.argv[2]
d = bytearray(open(path, 'rb').read())

# Locate the real header the same way a loader does: aligned magic with a
# valid checksum. The mutations are then applied relative to it, so this
# script does not hardcode a file offset that a linker change would move.
MAGIC = 0xE85250D6
hdr = None
for p in range(0, min(len(d), 32768) - 16, 8):
    m, a, l, c = struct.unpack_from('<4I', d, p)
    if m == MAGIC and (m + a + l + c) % 2**32 == 0:
        hdr = p
        break
if hdr is None:
    sys.exit("selftest: cannot find a valid header in the control image")
length = struct.unpack_from('<I', d, hdr + 8)[0]

def tag_at(want):
    p = hdr + 16
    while p + 8 <= hdr + length:
        t, _f, sz = struct.unpack_from('<HHI', d, p)
        if t == want:
            return p
        if t == 0 or sz < 8:
            return None
        p += (sz + 7) // 8 * 8
    return None

if what == 'checksum':
    d[hdr + 12] ^= 0x01                       # one bit of the checksum word
elif what == 'magic':
    struct.pack_into('<I', d, hdr, 0)         # header no longer findable
elif what == 'arch':
    struct.pack_into('<I', d, hdr + 4, 4)     # architecture 4 = MIPS
elif what == 'endtag':
    p = tag_at(0)
    if p is None:
        sys.exit("selftest: control image has no end tag to corrupt")
    struct.pack_into('<H', d, p, 9)           # terminator is no longer type 0
elif what == 'entrytag':
    p = tag_at(3)
    if p is None:
        sys.exit("selftest: control image has no entry address tag to remove")
    struct.pack_into('<H', d, p, 1)           # type 3 -> 1: tag is gone
elif what == 'physentry':
    # The higher-half trap, exactly as it bit this project: ENTRY(_start_phys)
    # puts a PHYSICAL address in e_entry, which is inside no segment's VIRTUAL
    # range, and GRUB refuses the image with "entry point isn't in a segment".
    e_entry = struct.unpack_from('<Q', d, 24)[0]
    struct.pack_into('<Q', d, 24, (e_entry - 0xFFFFFFFF80000000) % 2**64)
elif what == 'entrymismatch':
    p = tag_at(3)
    if p is None:
        sys.exit("selftest: control image has no entry address tag to skew")
    cur = struct.unpack_from('<I', d, p + 8)[0]
    struct.pack_into('<I', d, p + 8, cur + 0x1000)   # tag and e_entry disagree
elif what == 'entryinbss':
    # e_entry moved into the zero-filled tail of the last segment: inside a
    # PT_LOAD by virtual address, but pointing at memory no byte of the file
    # backs. GRUB accepts it and jumps into zeros.
    segs = []
    e_phoff = struct.unpack_from('<Q', d, 32)[0]
    e_phentsize, e_phnum = struct.unpack_from('<HH', d, 54)
    for i in range(e_phnum):
        t, _f, _o, va, _pa, fsz, msz = struct.unpack_from('<IIQQQQQ', d, e_phoff + i * e_phentsize)
        if t == 1 and msz > fsz:
            struct.pack_into('<Q', d, 24, va + fsz + 8)
            break
    else:
        sys.exit('selftest: no segment with a zero-filled tail to aim at')
else:
    sys.exit(f"selftest: unknown mutation {what}")
open(path, 'wb').write(d)
PY
}

# verdict <image> -> prints "grub=<0|1> mb2=<0|1>"
grub_says() { grub2-file --is-x86-multiboot2 "$1" >/dev/null 2>&1 && echo 0 || echo 1; }
mb2_says()  { python3 tools/mb2-check.py "$1" --quiet >/dev/null 2>&1 && echo 0 || echo 1; }

echo "=== control: the real image must PASS both checkers ==="
g=$(grub_says "$IMG"); m=$(mb2_says "$IMG")
[[ "$g" == 0 ]] && ok "grub2-file accepts the unmutated image" \
                || bad "grub2-file REJECTS the unmutated image -- the gate rejects everything"
[[ "$m" == 0 ]] && ok "mb2-check accepts the unmutated image" \
                || bad "mb2-check REJECTS the unmutated image"

echo
echo "=== mutations: each must be REJECTED by the gate as a whole ==="
# name|description
MUTATIONS=(
  "checksum|one bit flipped in the header checksum"
  "magic|header magic zeroed"
  "arch|architecture field set to 4 (MIPS)"
  "endtag|tag list terminator is type 9, not type 0"
  "entrytag|entry address tag removed (type 3 -> 1)"
  "physentry|e_entry replaced by its physical alias (GRUB: not in a segment)"
  "entrymismatch|entry tag and e_entry disagree by 0x1000"
  "entryinbss|e_entry points into a segment's zero-filled tail"
)
escaped_grub=()
for spec in "${MUTATIONS[@]}"; do
  name="${spec%%|*}"; desc="${spec#*|}"
  img="$WORK/$name.elf"
  if ! mutate "$img" "$name"; then bad "$name: could not inject the mutation"; continue; fi
  g=$(grub_says "$img"); m=$(mb2_says "$img")
  if [[ "$g" == 1 || "$m" == 1 ]]; then
    ok "rejected: $desc"
    if [[ "$g" == 0 ]]; then
      note "grub2-file ACCEPTED this image; only mb2-check caught it"
      escaped_grub+=("$desc")
    fi
  else
    bad "NOT rejected: $desc"
    note "both checkers passed an image carrying this defect -- the gate is blind to it"
  fi
done

echo
if (( ${#escaped_grub[@]} > 0 )); then
  echo "=== ${#escaped_grub[@]} defect(s) got past grub2-file and were caught only by mb2-check ==="
  for d in "${escaped_grub[@]}"; do note "* $d"; done
  note "This is why 'grub-file --is-x86-multiboot2 exits 0' is a necessary"
  note "condition for booting and not a sufficient one."
else
  echo "=== grub2-file caught every injected defect on its own ==="
  note "mb2-check added no coverage on this run. Keep it anyway (it asserts"
  note "properties GRUB is not obliged to check) but update its header comment."
fi

echo
echo "=== $pass passed, $fail failed ==="
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
