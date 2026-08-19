#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Roadmap 6.2's mutation table.  Injects one defect at a time into the ext2
# driver, the block layer or the VFS miss path, rebuilds, re-runs the host
# suite, and restores.  The baseline must PASS; a MUTATION that passes is an
# ESCAPE, because the suite accepted a module with a known defect.
#
# BOTH OF tools/mutate-hostlib.sh's CORRECTIONS ARE INHERITED AT BIRTH, and
# 6.2 needs both more than 6.1 did:
#
#   * A PER-CASE TIMEOUT.  Two of the cases below are hangs and not wrong
#     answers.  M110 removes dir.c:122's minimum-rec_len refusal, which makes
#     rec_len 0 an offset that never advances; M122 removes the re-entry guard
#     in vfs_lookup, and the filler then calls vfs_add which calls vfs_lookup
#     which calls the filler until the stack is gone.  Without a timeout the
#     table stops on the first of them and reports nothing.
#
#   * RESTORE FROM HEAD, NOT FROM THE INDEX.  6.1 lost a run to a `git add -A`
#     that landed while a mutation was live: the deletion went into the index
#     and every later restore faithfully put the DEFECT back.
#
#   tools/mutate-ext2.sh            every case
#   tools/mutate-ext2.sh M110 M115  only those
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${FK_MUTATE_OUT:-$(mktemp -d /tmp/fk-mutate-ext2.XXXXXX)}"
mkdir -p "$OUT"
echo "logs: $OUT"

# EVERY FILE ANY CASE BELOW MUTATES MUST BE IN THIS LIST -- restore() rewinds
# exactly these, so a case that seds a file not named here leaves its mutation
# behind and it is reported against the next defect.
FILES="src/fs/fk_ext2.f90 src/fs/fk_ext2_types.f90 src/fs/fk_blkdev.f90 \
       src/fs/fk_vfs.f90"

restore() { git checkout HEAD -- $FILES 2>/dev/null; }

for f in $FILES; do
  git ls-files --error-unmatch "$f" >/dev/null 2>&1 || {
    echo "ABORT: $f is not tracked -- 'git checkout HEAD --' cannot restore it."
    echo "       git add and commit it first."; exit 1; }
done
if ! git diff --quiet HEAD -- $FILES && [ -z "${FK_MUTATE_FORCE:-}" ]; then
  echo "ABORT: the files this script mutates differ from HEAD:"
  git status --short -- $FILES | sed 's/^/       /'
  echo "       commit or stash them; the first restore would discard them."
  echo "       FK_MUTATE_FORCE=1 to override."; exit 1
fi

# A substitution that matched nothing is a case that silently tested the
# BASELINE and reported it as an escape.  Refuse instead.
subst() {
  local file=$1 from=$2 to=$3
  python3 - "$file" "$from" "$to" <<'PY' || { echo "SUBST FAILED in $file"; exit 1; }
import sys
path, frm, to = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if frm not in s:
    sys.exit(1)
open(path, 'w').write(s.replace(frm, to, 1))
PY
}

run_case() {
  local name=$1 target=${2:-build/run-ext2}
  local rc line
  timeout -k 10 300 ./tools/run.sh "$target" >"$OUT/$name.log" 2>&1
  rc=$?
  if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
    echo "$name: suite TIMED OUT (caught -- the defect hangs, it does not"\
         "return a wrong answer)"
    restore
    return
  fi
  line=$(grep -aE "MISMATCH|checks,|Error [0-9]" "$OUT/$name.log" \
         | head -3 | tr -d '\r' | sed 's/^ *//' | paste -sd'|')
  if [ $rc -eq 0 ]; then
    case "$name" in
    baseline*) echo "$name: suite PASSED :: $line";;
    *)         echo "$name: suite PASSED  <-- ESCAPE :: $line";;
    esac
  else                   echo "$name: suite FAILED (caught) :: $line"; fi
  restore
}

case_baseline() { run_case baseline-ext2; run_case baseline-vfs build/run-vfs; }

# ---- dir.c:118-131, one refusal per case ----------------------------------

# THE HANG.  rec_len 0 never advances the offset.  A driver without this does
# not answer wrongly; it does not answer.
case_M110() {
  subst src/fs/fk_ext2.f90 \
    $'          if (rec < FK_E2_DIR_MIN_REC) return' \
    $'          if (rec < 0_c_int32_t) return'
  run_case M110-no-minimum-rec_len-so-the-walk-never-terminates
}

case_M111() {
  subst src/fs/fk_ext2.f90 \
    $'          if (iand(rec, FK_E2_DIR_PAD - 1_c_int32_t) /= 0_c_int32_t) return\n' \
    $''
  run_case M111-an-unaligned-rec_len-is-accepted
}

case_M112() {
  subst src/fs/fk_ext2.f90 \
    $'          if (FK_E2_DE_NAME + nlen > rec) return\n' \
    $''
  run_case M112-a-name-may-run-past-its-own-record
}

case_M113() {
  subst src/fs/fk_ext2.f90 \
    $'          if (off + rec > sb_block_size) return\n' \
    $''
  run_case M113-a-record-may-span-the-end-of-the-block
}

case_M114() {
  subst src/fs/fk_ext2.f90 \
    $'          if (ino > sb_inodes_count) return\n' \
    $''
  run_case M114-a-directory-entry-may-name-an-inode-that-cannot-exist
}

# ---- the superblock -------------------------------------------------------

# THE CASE THE FIXTURE EXISTS FOR.  mke2fs formats it at 256-byte inodes on
# purpose: against a 128-byte filesystem this mutation is invisible.
case_M115() {
  subst src/fs/fk_ext2.f90 \
    $'       sb_inode_size = int(blk_le16(FK_E2_SB_INODE_SIZE), c_int32_t)' \
    $'       sb_inode_size = FK_E2_GOOD_OLD_INODE_SIZE'
  run_case M115-the-inode-size-is-hardcoded-to-the-original-128
}

case_M116() {
  subst src/fs/fk_ext2.f90 \
    $'    if (iand(incompat, not(int(FK_E2_INCOMPAT_SUPP, c_int64_t))) &\n        /= 0_c_int64_t) return' \
    $'    if (.false.) return'
  run_case M116-an-unimplemented-incompatible-feature-is-accepted
}

case_M117() {
  subst src/fs/fk_ext2.f90 \
    $'    if (iand(state, int(FK_E2_STATE_VALID, c_int64_t)) == 0_c_int64_t) return' \
    $'    if (.false.) return'
  run_case M117-a-filesystem-left-dirty-is-mounted-anyway
}

# super.c:813.  The descriptor table is one block above the superblock's, which
# at a 1 KiB block is 2 and not s_first_data_block.
case_M118() {
  subst src/fs/fk_ext2.f90 \
    $'    sb_gd_table = int(FK_E2_SUPER_OFF / sb_block_size, c_int64_t) + 1_c_int64_t' \
    $'    sb_gd_table = first_data'
  run_case M118-the-descriptor-table-is-looked-for-in-the-wrong-block
}

case_M119() {
  subst src/fs/fk_ext2.f90 \
    $'    if (ino /= int(FK_E2_ROOT_INO, c_int64_t) .and. ino < sb_first_ino) return' \
    $'    if (.false.) return'
  run_case M119-a-reserved-inode-can-be-handed-out
}

# ext2.h:344.  i_size_high is only the high half for a REGULAR file; on a
# directory the same word is i_dir_acl.
case_M120() {
  subst src/fs/fk_ext2.f90 \
    $'    if (iand(st_mode, FK_S_IFMT) == FK_S_IFREG) then\n       hi = blk_le32(off + FK_E2_I_SIZE_HIGH)' \
    $'    if (.true.) then\n       hi = blk_le32(off + FK_E2_I_SIZE_HIGH)'
  run_case M120-a-directory-joins-i_dir_acl-into-its-size
}

case_M121() {
  subst src/fs/fk_ext2.f90 \
    $'    if (blk_capacity() > 0_c_int64_t .and. &\n        sb_blocks_count * int(sb_sectors_per_block, c_int64_t) > &\n        blk_capacity()) return' \
    $'    if (.false.) return'
  run_case M121-a-filesystem-larger-than-its-device-is-mounted
}

# ---- the block layer ------------------------------------------------------

# A FAILED READ THAT LEAVES THE OLD BLOCK ADDRESSABLE is how a filesystem
# parses the block it wanted out of the block it got.
case_M122() {
  subst src/fs/fk_blkdev.f90 \
    $'    buf_valid = 0_c_int32_t\n    status = FK_BLK_E_NOBUF' \
    $'    status = FK_BLK_E_NOBUF'
  run_case M122-a-failed-read-leaves-the-previous-block-readable
}

# blk_u8 must distinguish "the byte is zero" from "there is no such byte":
# both are legal things to find on a disk and every caller branches on it.
case_M123() {
  subst src/fs/fk_blkdev.f90 \
    $'    v = -1_c_int32_t\n    if (off < 0_c_int32_t .or. off >= buf_valid) return' \
    $'    v = 0_c_int32_t\n    if (off < 0_c_int32_t .or. off >= buf_valid) return'
  run_case M123-an-offset-past-the-block-reads-as-zero-not-as-absent
}

# The 32-bit fields on disk are UNSIGNED counts. Truncating blk_le32 to a
# signed 32-bit is roadmap 4.1's MADT defect in a new module.
case_M124() {
  subst src/fs/fk_blkdev.f90 \
    $'    v = ior(int(lo, c_int64_t), shiftl(int(hi, c_int64_t), 16))' \
    $'    v = int(int(ior(lo, shiftl(hi, 16)), c_int32_t), c_int64_t)'
  run_case M124-a-32-bit-on-disk-count-is-read-signed
}

# ---- the seam -------------------------------------------------------------

# THE SECOND HANG.  vfs_add calls vfs_lookup to enforce -EEXIST and the filler
# calls vfs_add, so without the guard the two recurse until the stack is gone.
case_M125() {
  subst src/fs/fk_vfs.f90 \
    $'    if (filling) return\n' \
    $''
  run_case M125-the-miss-path-can-re-enter-itself build/run-ext2
}

# Filling from a non-directory hands the parser a file's bytes to read as
# directory records.
case_M126() {
  subst src/fs/fk_vfs.f90 \
    $'    if (vfs_is_dir(parent) == 0_c_int32_t) return\n    filling = .true.' \
    $'    filling = .true.'
  run_case M126-a-file-is-asked-for-its-directory-entries
}

# A negative errno leaked out of the filler would be read as a live dentry
# handle by every caller in fk_vfs.f90.
case_M127() {
  subst src/fs/fk_vfs.f90 \
    $'    if (c > FK_VFS_NONE) then\n       if (dentry_ok(c)) d = c\n    end if' \
    $'    d = c'
  run_case M127-the-fillers-errno-is-returned-as-a-dentry
}

# The starting LBA is a BLOCK number scaled by the sectors in a block. Handing
# back the block number is off by a factor of two at a 1 KiB block and reads
# the wrong half of the disk.
case_M128() {
  subst src/fs/fk_ext2.f90 \
    $'    v = st_block(0) * int(sb_sectors_per_block, c_int64_t)' \
    $'    v = st_block(0)'
  run_case M128-the-starting-LBA-is-a-block-number-not-a-sector-number
}

# Searching the twelve direct blocks and reporting -ENOENT is a LIE: the name
# is there and this driver cannot see it. 6.4 owns the indirect block.
case_M129() {
  subst src/fs/fk_ext2.f90 \
    $'    status = FK_EXT2_E_FBIG\n    if (want_blocks > int(FK_E2_NDIR_BLOCKS, c_int64_t)) return' \
    $'    if (.false.) return'
  run_case M129-a-directory-needing-indirection-is-truncated-not-refused
}

CASES="baseline M110 M111 M112 M113 M114 M115 M116 M117 M118 M119 M120 \
       M121 M122 M123 M124 M125 M126 M127 M128 M129"

SELECT="$*"
want_case() {
  [ -z "$SELECT" ] && return 0
  case " $SELECT " in *" $1 "*) return 0;; esac
  return 1
}

trap 'restore' EXIT INT TERM
for c in $CASES; do
  want_case "$c" || continue
  restore
  "case_${c}"
done
restore
