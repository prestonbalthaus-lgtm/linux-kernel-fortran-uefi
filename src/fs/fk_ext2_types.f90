! SPDX-License-Identifier: GPL-2.0
! ext2 on-disk layout: superblock, group descriptor, inode, directory entry.
! Roadmap 6.2.  Every field is LITTLE-ENDIAN on disk and this kernel only ever
! runs on x86-64, so no byte swap appears anywhere -- but the records are still
! read at explicit BYTE OFFSETS rather than mapped with a bind(c) struct,
! because a struct would put gfortran's padding rules between this tree and the
! disk.  `struct ext2_dir_entry_2` is the case that settles it: its name follows
! a one-byte field and is a flexible array, so no derived type describes it.
!
! Offsets are byte counts from the start of the record, obtained by summing the
! declared widths of the vendor's members in order.  THREE OF THEM HAVE AN
! IN-TREE ORACLE and it is worth naming: ext2.h:611-616's verify_offsets() is a
! BUILD_BUG_ON that s_magic, s_blocks_count and s_log_block_size sit at 0x38,
! 0x04 and 0x18 (ext2_fs.h:30-32).  The rest are checked the same way, one layer
! out: tests/fs/test_ext2.c includes the vendor's own header and diffs every
! constant below against offsetof, which is the channel tests/fs/test_vfs.c
! already uses against the uapi headers.
!
! Citations: `ext2.h` is vendor/linux-7.1.8/fs/ext2/ext2.h, `ext2_fs.h` is
! vendor/linux-7.1.8/include/linux/ext2_fs.h, `dir.c`, `inode.c`, `balloc.c` and
! `super.c` are that release's fs/ext2/.
module fk_ext2_types_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private

  public :: FK_E2_SUPER_OFF, FK_E2_SUPER_MAGIC, FK_E2_ROOT_INO
  public :: FK_E2_GOOD_OLD_REV, FK_E2_DYNAMIC_REV, FK_E2_MAX_SUPP_REV
  public :: FK_E2_GOOD_OLD_INODE_SIZE, FK_E2_GOOD_OLD_FIRST_INO
  public :: FK_E2_STATE_VALID
  public :: FK_E2_SB_INODES_COUNT, FK_E2_SB_BLOCKS_COUNT, &
            FK_E2_SB_FIRST_DATA_BLOCK, FK_E2_SB_LOG_BLOCK_SIZE, &
            FK_E2_SB_BLOCKS_PER_GROUP, FK_E2_SB_INODES_PER_GROUP, &
            FK_E2_SB_MAGIC, FK_E2_SB_STATE, FK_E2_SB_REV_LEVEL, &
            FK_E2_SB_FIRST_INO, FK_E2_SB_INODE_SIZE, &
            FK_E2_SB_FEATURE_COMPAT, FK_E2_SB_FEATURE_INCOMPAT, &
            FK_E2_SB_FEATURE_RO_COMPAT
  public :: FK_E2_GD_BLOCK_BITMAP, FK_E2_GD_INODE_BITMAP, &
            FK_E2_GD_INODE_TABLE, FK_E2_GD_FREE_BLOCKS, &
            FK_E2_GD_FREE_INODES, FK_E2_GD_USED_DIRS, FK_E2_GD_SIZE
  public :: FK_E2_I_MODE, FK_E2_I_UID, FK_E2_I_SIZE, FK_E2_I_LINKS_COUNT, &
            FK_E2_I_BLOCKS, FK_E2_I_FLAGS, FK_E2_I_BLOCK, FK_E2_I_SIZE_HIGH
  public :: FK_E2_N_BLOCKS, FK_E2_NDIR_BLOCKS, FK_E2_IND_BLOCK, &
            FK_E2_DIND_BLOCK, FK_E2_TIND_BLOCK
  public :: FK_E2_DE_INODE, FK_E2_DE_REC_LEN, FK_E2_DE_NAME_LEN, &
            FK_E2_DE_FILE_TYPE, FK_E2_DE_NAME
  public :: FK_E2_DIR_PAD, FK_E2_DIR_MIN_REC, FK_E2_MAX_REC_LEN
  public :: FK_E2_INCOMPAT_FILETYPE, FK_E2_INCOMPAT_SUPP
  public :: FK_E2_MIN_BLOCK_LOG, FK_E2_MAX_BLOCK_LOG

  ! super.c:933-937.  The superblock is at BYTE 1024, not at a block number:
  ! `logic_sb_block = (sb_block * BLOCK_SIZE) / blocksize` with sb_block 1 and
  ! BLOCK_SIZE 1024.  At a 1 KiB block that is block 1 and at 4 KiB it is
  ! inside block 0, which is why this is the one structure the driver locates
  ! before it knows the block size.
  integer(c_int32_t), parameter :: FK_E2_SUPER_OFF = 1024_c_int32_t

  ! uapi/linux/magic.h:24.
  integer(c_int32_t), parameter :: FK_E2_SUPER_MAGIC = int(z'EF53', c_int32_t)

  ! ext2.h:162.  A CONSTANT, and it is half the reason ext2 was chosen over
  ! FAT32: the root directory is found by arithmetic, not by walking an
  ! allocation chain out of a boot record.
  integer(c_int32_t), parameter :: FK_E2_ROOT_INO = 2_c_int32_t

  ! ext2.h:494-495, 498, 500, 167.
  integer(c_int32_t), parameter :: FK_E2_GOOD_OLD_REV = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_DYNAMIC_REV = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_MAX_SUPP_REV = FK_E2_DYNAMIC_REV
  integer(c_int32_t), parameter :: FK_E2_GOOD_OLD_INODE_SIZE = 128_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_GOOD_OLD_FIRST_INO = 11_c_int32_t

  ! ext2.h:358, EXT2_VALID_FS.  A filesystem left dirty is REFUSED rather than
  ! read: there is no fsck here and no journal to replay, and a half-written
  ! directory block is precisely the input that turns a rec_len walk into an
  ! endless loop.
  integer(c_int32_t), parameter :: FK_E2_STATE_VALID = 1_c_int32_t

  ! --- struct ext2_super_block, ext2.h:410-454 -------------------------------
  integer(c_int32_t), parameter :: FK_E2_SB_INODES_COUNT = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_SB_BLOCKS_COUNT = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_SB_FIRST_DATA_BLOCK = 20_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_SB_LOG_BLOCK_SIZE = 24_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_SB_BLOCKS_PER_GROUP = 32_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_SB_INODES_PER_GROUP = 40_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_SB_MAGIC = 56_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_SB_STATE = 58_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_SB_REV_LEVEL = 76_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_SB_FIRST_INO = 84_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_SB_INODE_SIZE = 88_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_SB_FEATURE_COMPAT = 92_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_SB_FEATURE_INCOMPAT = 96_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_SB_FEATURE_RO_COMPAT = 100_c_int32_t

  ! ext2.h:539.  The ONLY incompatible feature this driver implements, and it
  ! changes the SHAPE of a directory entry: with FILETYPE set, name_len is one
  ! byte and the byte above it is file_type; without it, name_len is 16 bits.
  ! A driver that assumes the wrong one reads garbage names off the other, and
  ! on a little-endian disk it does so SILENTLY for every name under 256 bytes,
  ! because the high half of a 16-bit name_len reads as a zero file_type.
  integer(c_int32_t), parameter :: FK_E2_INCOMPAT_FILETYPE = &
       int(z'0002', c_int32_t)

  ! ext2.h:545-546's EXT2_FEATURE_INCOMPAT_SUPP is FILETYPE | META_BG; this
  ! driver supports FILETYPE alone and REFUSES every other bit, META_BG
  ! included -- META_BG moves the descriptor table off the fixed location
  ! super.c:813 computes, which is the one piece of geometry read_super does
  ! not read from the disk.
  ! An allowlist on purpose, for the reason src/fs/fk_vfs.f90 gives about array
  ! element types: widening what is understood has to come back through here,
  ! rather than a new feature quietly changing what the existing parse means.
  !
  ! ro_compat is deliberately NOT checked.  Every ro_compat bit is by
  ! definition safe to READ -- that is what the name means -- and nothing here
  ! writes.  ext2.h:552's UNSUPPORTED mask is the incompat set only.
  integer(c_int32_t), parameter :: FK_E2_INCOMPAT_SUPP = FK_E2_INCOMPAT_FILETYPE

  ! --- struct ext2_group_desc, ext2.h:191-201 --------------------------------
  integer(c_int32_t), parameter :: FK_E2_GD_BLOCK_BITMAP = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_GD_INODE_BITMAP = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_GD_INODE_TABLE = 8_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_GD_FREE_BLOCKS = 12_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_GD_FREE_INODES = 14_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_GD_USED_DIRS = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_GD_SIZE = 32_c_int32_t

  ! --- struct ext2_inode, ext2.h:290-316 -------------------------------------
  ! i_size is 32 bits and ext2.h:344 aliases i_size_high onto i_dir_acl at
  ! +108, which is the high half for a regular file.  Both are read and joined,
  ! so a file above 4 GiB reports its true size -- it will still be REFUSED for
  ! mapping, because twelve direct blocks is the whole of what 6.2 implements.
  integer(c_int32_t), parameter :: FK_E2_I_MODE = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_I_UID = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_I_SIZE = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_I_LINKS_COUNT = 26_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_I_BLOCKS = 28_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_I_FLAGS = 32_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_I_BLOCK = 40_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_I_SIZE_HIGH = 108_c_int32_t

  ! ext2.h:214-218.
  integer(c_int32_t), parameter :: FK_E2_NDIR_BLOCKS = 12_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_IND_BLOCK = FK_E2_NDIR_BLOCKS
  integer(c_int32_t), parameter :: FK_E2_DIND_BLOCK = &
       FK_E2_IND_BLOCK + 1_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_TIND_BLOCK = &
       FK_E2_DIND_BLOCK + 1_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_N_BLOCKS = &
       FK_E2_TIND_BLOCK + 1_c_int32_t

  ! --- struct ext2_dir_entry_2, ext2.h:591-597 -------------------------------
  integer(c_int32_t), parameter :: FK_E2_DE_INODE = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_DE_REC_LEN = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_DE_NAME_LEN = 6_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_DE_FILE_TYPE = 7_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_DE_NAME = 8_c_int32_t

  ! ext2.h:604-607.  EXT2_DIR_REC_LEN(n) = (n + 8 + 3) & ~3, so the shortest
  ! record any formatter can emit is EXT2_DIR_REC_LEN(1) = 12.  dir.c:118 uses
  ! that same value as its loop bound and dir.c:122 as its first refusal.
  integer(c_int32_t), parameter :: FK_E2_DIR_PAD = 4_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_DIR_MIN_REC = 12_c_int32_t

  ! ext2.h:608.
  integer(c_int32_t), parameter :: FK_E2_MAX_REC_LEN = 65535_c_int32_t

  ! s_log_block_size is an EXPONENT over 1024 (ext2.h:179,
  ! EXT2_MIN_BLOCK_LOG_SIZE = 10), so a block is 1024 << s_log_block_size.  The
  ! ceiling is THIS DRIVER's and not the format's: the block buffer is one
  ! 4 KiB page, and a block larger than the buffer is refused rather than read
  ! short and parsed as if it were whole.
  integer(c_int32_t), parameter :: FK_E2_MIN_BLOCK_LOG = 10_c_int32_t
  integer(c_int32_t), parameter :: FK_E2_MAX_BLOCK_LOG = 12_c_int32_t

end module fk_ext2_types_m
