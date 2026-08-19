#!/usr/bin/env bash
# Builds the two things tests/fs/test_ext2.c cannot make for itself, and both
# of them exist so that this tree is never both the author and the judge of the
# same fact.  Roadmap 6.2.
#
#   1. build/ext2-vendor.h -- the four on-disk structs EXTRACTED VERBATIM from
#      vendor/linux-7.1.8/fs/ext2/ext2.h, plus the constants named below.  Not
#      transcribed: the text is cut out of the vendor file by line range, so a
#      vendor bump that moves a field moves this too and the offsetof assertions
#      in the test go red.  ext2.h itself cannot be included -- it pulls in
#      linux/fs.h, linux/mm.h and linux/highmem.h -- and this is the smallest
#      thing that gets its LAYOUT without its dependencies.
#
#   2. build/ext2-fixture.img and build/ext2-fixture.h -- an ext2 filesystem
#      built by MKE2FS, and the expected answers read back out of it by DEBUGFS.
#      Neither program shares a line of code with this kernel.  If the Fortran
#      driver and the fixture agreed because they shared a misconception, that
#      misconception would have to be e2fsprogs'.
#
# Usage: tools/gen-ext2-oracle.sh <builddir>
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD="${1:-build}"
EXT2_H="vendor/linux-7.1.8/fs/ext2/ext2.h"
OUT_H="$BUILD/ext2-vendor.h"
IMG="$BUILD/ext2-fixture.img"
FIX_H="$BUILD/ext2-fixture.h"

for t in mke2fs debugfs; do
  command -v "$t" >/dev/null 2>&1 || {
    echo "gen-ext2-oracle: $t is not installed. The ext2 suite has no oracle" >&2
    echo "                 without it; add e2fsprogs to tools/Containerfile." >&2
    exit 1
  }
done
[ -r "$EXT2_H" ] || { echo "gen-ext2-oracle: $EXT2_H is missing" >&2; exit 1; }

mkdir -p "$BUILD"

# --- 1. the vendor structs ---------------------------------------------------
# Cut from `^struct <name>` to the first `^};`.  awk rather than sed -n '/,/p'
# so that a struct which fails to appear is an ERROR rather than an empty range
# that silently produces a header with nothing in it.
extract_struct() {
  awk -v name="$1" '
    $0 ~ "^struct[ \t]+" name "([ \t]|$|\\{)" { inside = 1 }
    inside { print; found = 1 }
    inside && /^};/ { inside = 0; exit }
    END { if (!found) { print "MISSING" > "/dev/stderr"; exit 3 } }
  ' "$EXT2_H"
}

# Only names whose definition is a plain literal or an expression over other
# names in this list.  Anything referring to EXT2_SB() or a struct pointer is a
# kernel accessor, not an on-disk constant, and would not compile here.
# A CONTINUATION-JOINING PASS, and it is not tidiness.  EXT2_DIR_REC_LEN is
# split across two lines with a trailing backslash, and a grep that takes the
# first line alone emits a #define whose replacement list ends in `\` -- which
# is a compile error in the generated header, and would have been caught, but
# the same grep silently dropped every TAB-separated #define in the file
# because "[ \t]" inside double quotes reaches grep as backslash-t and not as a
# tab.  Two thirds of this list went missing without a word.  [[:blank:]] is
# the spelling that cannot be got wrong.
extract_defines() {
  awk -v names="$CONSTS" '
    { line = $0 }
    # Join a backslash continuation before deciding anything about the line.
    /\\$/ { sub(/\\$/, "", line); acc = acc line; next }
    { line = acc line; acc = "" }
    line ~ ("^#define[[:blank:]]+(" names ")[[:blank:]]") { print line }
    line ~ "^#define[[:blank:]]+EXT2_DIR_REC_LEN\\(" { print line }
  ' "$EXT2_H"
}

CONSTS='EXT2_ROOT_INO|EXT2_BAD_INO|EXT2_GOOD_OLD_FIRST_INO|EXT2_GOOD_OLD_REV|EXT2_DYNAMIC_REV|EXT2_MAX_SUPP_REV|EXT2_GOOD_OLD_INODE_SIZE|EXT2_MIN_BLOCK_SIZE|EXT2_MAX_BLOCK_SIZE|EXT2_MIN_BLOCK_LOG_SIZE|EXT2_MAX_BLOCK_LOG_SIZE|EXT2_VALID_FS|EXT2_ERROR_FS|EXT2_NDIR_BLOCKS|EXT2_IND_BLOCK|EXT2_DIND_BLOCK|EXT2_TIND_BLOCK|EXT2_N_BLOCKS|EXT2_DIR_PAD|EXT2_DIR_ROUND|EXT2_MAX_REC_LEN|EXT2_FEATURE_INCOMPAT_COMPRESSION|EXT2_FEATURE_INCOMPAT_FILETYPE|EXT2_FEATURE_INCOMPAT_META_BG|EXT2_FEATURE_RO_COMPAT_SPARSE_SUPER|EXT2_FEATURE_RO_COMPAT_LARGE_FILE'

# EVERY NAME MUST BE FOUND, and the count is checked rather than assumed.  The
# first draft of this script lost nine of these twenty-six to a "[ \t]" that
# reached grep as backslash-t, and the generated header looked perfectly
# healthy: the missing constants simply were not asserted on, so the suite
# stayed green while proving less than it claimed.  A silent partial extraction
# is the same defect class as roadmap 1.1's oracle falling through to glibc.
extract_defines > "$BUILD/ext2-defines.tmp"
want=$(printf '%s\n' "$CONSTS" | tr '|' '\n' | wc -l)
for n in $(printf '%s' "$CONSTS" | tr '|' ' '); do
  grep -qE "^#define[[:blank:]]+$n[[:blank:]]" "$BUILD/ext2-defines.tmp" || {
    echo "gen-ext2-oracle: $n was not extracted from $EXT2_H" >&2; exit 1; }
done
grep -qE "^#define[[:blank:]]+EXT2_DIR_REC_LEN\(" "$BUILD/ext2-defines.tmp" || {
  echo "gen-ext2-oracle: EXT2_DIR_REC_LEN was not extracted" >&2; exit 1; }
got=$(grep -c '^#define' "$BUILD/ext2-defines.tmp")
[ "$got" -eq "$((want + 1))" ] || {
  echo "gen-ext2-oracle: extracted $got #defines, wanted $((want + 1))" >&2
  exit 1; }

{
  echo "/* SPDX-License-Identifier: GPL-2.0 */"
  echo "/* GENERATED by tools/gen-ext2-oracle.sh from $EXT2_H -- do not edit."
  echo " * Every line below this comment was CUT OUT of the vendor's header."
  echo " */"
  echo "#ifndef FK_EXT2_VENDOR_H"
  echo "#define FK_EXT2_VENDOR_H"
  echo "#include <stdint.h>"
  echo "typedef uint8_t  __u8;"
  echo "typedef uint16_t __u16;"
  echo "typedef uint32_t __u32;"
  echo "typedef uint16_t __le16;"
  echo "typedef uint32_t __le32;"
  echo
  cat "$BUILD/ext2-defines.tmp"
  echo
  extract_struct ext2_group_desc
  echo
  extract_struct ext2_inode
  echo
  extract_struct ext2_super_block
  echo
  extract_struct ext2_dir_entry_2
  echo
  grep -E "^#define[[:blank:]]+i_size_high" "$EXT2_H"
  echo "#endif"
} > "$OUT_H.tmp"
mv "$OUT_H.tmp" "$OUT_H"

# --- 2. the fixture ----------------------------------------------------------
# 2048 sectors, matching the 5.3 disk exactly, because the boot gate serves ONE
# image to both milestones.  1024-byte blocks: one block is two LBAs, the
# superblock is block 1, and the whole filesystem is a single block group.
STAGE="$BUILD/ext2-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/etc" "$STAGE/deep/a/b"

# The contents are the assertion.  A fixed byte pattern of a known length means
# the size the driver reports has one correct value and the gate knows it
# without asking the driver.
printf 'FORTRAN-KERNEL INIT STUB v1\n' > "$STAGE/bin/init"
printf 'root=/dev/nvme0n1 ro\n'        > "$STAGE/etc/fstab"
printf 'deep\n'                        > "$STAGE/deep/a/b/leaf"

# A name at exactly EXT2_NAME_LEN, so the walk's -ENAMETOOLONG boundary is
# exercised from the DISK side and not only from the caller's.
LONG=$(printf 'n%.0s' $(seq 1 255))
printf 'long\n' > "$STAGE/$LONG"

rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=512 count=2048 status=none

# -O ^resize_inode,^dir_index,^ext_attr: this driver implements FILETYPE and
# refuses every other incompatible feature, and dir_index is an htree whose
# blocks are NOT a linear array of records.  Dropping it here is not hiding
# from it -- the driver would refuse such a filesystem at mount, which is the
# behaviour the test asserts separately.
# -I 256 is mke2fs's own default at this size and is stated rather than left
# implicit: a driver that hardcodes the original 128 must FAIL, and it only
# fails if the fixture is not 128.
mke2fs -q -t ext2 -b 1024 -I 256 -O ^resize_inode,^dir_index,^ext_attr \
       -E root_owner=0:0 -d "$STAGE" -F "$IMG" 2>/dev/null

# THE 5.3 MARKERS GO BACK ON TOP, and they collide with nothing: ext2 reserves
# the first 1024 bytes for a boot block and puts its superblock at byte 1024,
# so all three of these live in space the filesystem does not use.  That is
# what lets ONE disk carry roadmap 5.3's sector-0 assertions and roadmap 6.2's
# filesystem at the same time.
python3 - "$IMG" <<'PYSPLICE'
import sys
p = sys.argv[1]
d = bytearray(open(p, 'rb').read())
assert not any(d[0:1024]), "ext2 put something in the boot block"
d[0:16]     = bytes(range(16))
d[510:512]  = b"\x55\xaa"
d[512:528]  = b"FORTRAN-KERNEL!!"
open(p, 'wb').write(bytes(d))
PYSPLICE

# --- 3. what debugfs says is in it -------------------------------------------
# THE SECOND OPINION.  Every expected value in the generated header below came
# out of e2fsprogs reading the image, not out of this kernel and not out of a
# constant somebody typed.
e2_ino()  { debugfs -R "stat $1" "$IMG" 2>/dev/null | sed -n 's/^Inode: \([0-9]*\).*/\1/p'; }
e2_size() { debugfs -R "stat $1" "$IMG" 2>/dev/null | sed -n 's/.*Size: \([0-9]*\).*/\1/p' | head -1; }
e2_blk()  { debugfs -R "stat $1" "$IMG" 2>/dev/null | sed -n 's/^(0):\([0-9]*\).*/\1/p' | head -1; }
e2_mode() { debugfs -R "stat $1" "$IMG" 2>/dev/null | sed -n 's/.*Mode: *0*\([0-7]*\).*/\1/p' | head -1; }

sb_field() { dumpe2fs -h "$IMG" 2>/dev/null | sed -n "s/^$1: *//p" | head -1; }

INIT_INO=$(e2_ino /bin/init);   INIT_SIZE=$(e2_size /bin/init)
INIT_BLK=$(e2_blk /bin/init);   INIT_MODE=$(e2_mode /bin/init)
BIN_INO=$(e2_ino /bin);         BIN_BLK=$(e2_blk /bin)
ROOT_BLK=$(e2_blk /);           LEAF_INO=$(e2_ino /deep/a/b/leaf)
LEAF_SIZE=$(e2_size /deep/a/b/leaf)
FSTAB_INO=$(e2_ino /etc/fstab); FSTAB_SIZE=$(e2_size /etc/fstab)
LONG_INO=$(e2_ino "/$LONG")

ITAB=$(dumpe2fs "$IMG" 2>/dev/null | sed -n 's/.*Inode table at \([0-9]*\).*/\1/p' | head -1)
INODE_SIZE=$(sb_field "Inode size")
BLOCK_COUNT=$(sb_field "Block count")
INODE_COUNT=$(sb_field "Inode count")
IPG=$(sb_field "Inodes per group")
BPG=$(sb_field "Blocks per group")
FIRST_INO=$(sb_field "First inode")

for v in INIT_INO INIT_SIZE INIT_BLK BIN_INO ROOT_BLK LEAF_INO ITAB \
         INODE_SIZE BLOCK_COUNT INODE_COUNT IPG BPG FIRST_INO; do
  [ -n "${!v}" ] || { echo "gen-ext2-oracle: debugfs gave no $v" >&2; exit 1; }
done

{
  echo "/* SPDX-License-Identifier: GPL-2.0 */"
  echo "/* GENERATED by tools/gen-ext2-oracle.sh -- do not edit."
  echo " * Every value here was read out of $IMG by e2fsprogs (debugfs and"
  echo " * dumpe2fs), which shares no code with anything in src/."
  echo " */"
  echo "#ifndef FK_EXT2_FIXTURE_H"
  echo "#define FK_EXT2_FIXTURE_H"
  echo "#define FIX_IMAGE          \"$IMG\""
  echo "#define FIX_SECTORS        2048"
  echo "#define FIX_BLOCK_SIZE     1024"
  echo "#define FIX_INODE_SIZE     $INODE_SIZE"
  echo "#define FIX_BLOCK_COUNT    $BLOCK_COUNT"
  echo "#define FIX_INODE_COUNT    $INODE_COUNT"
  echo "#define FIX_IPG            $IPG"
  echo "#define FIX_BPG            $BPG"
  echo "#define FIX_FIRST_INO      $FIRST_INO"
  echo "#define FIX_INODE_TABLE    $ITAB"
  echo "#define FIX_INIT_INO       $INIT_INO"
  echo "#define FIX_INIT_SIZE      $INIT_SIZE"
  echo "#define FIX_INIT_BLOCK     $INIT_BLK"
  echo "#define FIX_INIT_MODE      0$INIT_MODE"
  echo "#define FIX_INIT_LBA       ($INIT_BLK * (FIX_BLOCK_SIZE / 512))"
  echo "#define FIX_BIN_INO        $BIN_INO"
  echo "#define FIX_BIN_BLOCK      $BIN_BLK"
  echo "#define FIX_ROOT_BLOCK     $ROOT_BLK"
  echo "#define FIX_LEAF_INO       $LEAF_INO"
  echo "#define FIX_LEAF_SIZE      $LEAF_SIZE"
  echo "#define FIX_FSTAB_INO      $FSTAB_INO"
  echo "#define FIX_FSTAB_SIZE     $FSTAB_SIZE"
  echo "#define FIX_LONG_INO       $LONG_INO"
  echo "#define FIX_LONG_NAME      \"$LONG\""
  echo "#endif"
} > "$FIX_H.tmp"
mv "$FIX_H.tmp" "$FIX_H"

echo "  OK    ext2 oracle: vendor structs -> $OUT_H, e2fsprogs fixture -> $IMG"
