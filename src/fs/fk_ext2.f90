! SPDX-License-Identifier: GPL-2.0
! The ext2 filesystem driver: a cache miss becomes a disk read.  Roadmap 6.2.
!
! WHAT THIS FILE IS FOR, in one sentence: src/fs/fk_vfs.f90's vfs_lookup used to
! answer "no such name" for anything nobody had put in the tree by hand, and now
! it answers it by reading the parent directory off the NVMe drive.
!
! ext2 RATHER THAN FAT32, and the reason is the seam and not taste.  vfs_lookup
! compares (LENGTH, BYTES) -- dcache.h's dentry_cmp -- and FAT stores short
! names uppercased and matches them case-INSENSITIVELY, so a FAT driver would
! have to either fold case inside that comparison or implement long-name
! reassembly to get a byte-exact name back.  ext2 names are byte-exact on disk
! and drop into the existing compare with nothing added.  Two lesser reasons:
! FAT32 is not legally FAT32 below 65525 clusters, which would take the gate's
! 1 MiB fixture past 33 MiB, and ext2's root is inode 2 -- a CONSTANT -- where
! FAT32's root is a cluster chain that has to be walked from the boot record.
!
! READ-ONLY, AND THAT IS STRUCTURAL RATHER THAN UNFINISHED.  Nothing here has a
! write path, so no allocation bitmap is ever consulted, no free count is ever
! updated and the s_state check below can refuse a dirty filesystem outright
! instead of replaying anything.  ro_compat features are all, by their own
! definition, safe to read.
!
! TWELVE DIRECT BLOCKS AND NO INDIRECTION.  i_block[0..11] is 12 KiB at a 1 KiB
! block, which covers every directory the gate builds and the init stub it puts
! in one.  It does NOT cover a real BusyBox, and roadmap 6.4 is where the
! singly-indirect block gets written -- named here so it is a known debt and not
! a discovered one.  A file that needs a block this driver cannot reach is
! REFUSED with -EFBIG rather than silently truncated.
!
! Citations: `ext2.h`, `dir.c`, `inode.c`, `balloc.c` and `super.c` are
! vendor/linux-7.1.8/fs/ext2/.
module fk_ext2_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t, c_int8_t, &
                                         c_size_t, c_ptr, c_associated, &
                                         c_f_pointer
  use fk_blkdev_m, only: blk_read, blk_u8, blk_le16, blk_le32, blk_capacity, &
                         FK_BLK_OK, FK_BLK_SECTOR_BYTES
  use fk_ext2_types_m, only: FK_E2_SUPER_OFF, FK_E2_SUPER_MAGIC, &
                             FK_E2_ROOT_INO, FK_E2_GOOD_OLD_REV, &
                             FK_E2_DYNAMIC_REV, FK_E2_MAX_SUPP_REV, &
                             FK_E2_GOOD_OLD_INODE_SIZE, &
                             FK_E2_GOOD_OLD_FIRST_INO, FK_E2_STATE_VALID, &
                             FK_E2_SB_INODES_COUNT, FK_E2_SB_BLOCKS_COUNT, &
                             FK_E2_SB_LOG_BLOCK_SIZE, &
                             FK_E2_SB_BLOCKS_PER_GROUP, &
                             FK_E2_SB_INODES_PER_GROUP, FK_E2_SB_MAGIC, &
                             FK_E2_SB_STATE, FK_E2_SB_REV_LEVEL, &
                             FK_E2_SB_FIRST_INO, FK_E2_SB_INODE_SIZE, &
                             FK_E2_SB_FEATURE_INCOMPAT, FK_E2_GD_INODE_TABLE, &
                             FK_E2_GD_SIZE, FK_E2_I_MODE, FK_E2_I_SIZE, &
                             FK_E2_I_LINKS_COUNT, FK_E2_I_BLOCK, &
                             FK_E2_I_SIZE_HIGH, FK_E2_NDIR_BLOCKS, &
                             FK_E2_DE_INODE, FK_E2_DE_REC_LEN, &
                             FK_E2_DE_NAME_LEN, FK_E2_DE_NAME, &
                             FK_E2_DIR_PAD, FK_E2_DIR_MIN_REC, &
                             FK_E2_INCOMPAT_SUPP, FK_E2_MIN_BLOCK_LOG, &
                             FK_E2_MAX_BLOCK_LOG
  use fk_vfs_m, only: vfs_mount, vfs_root, vfs_add, vfs_lookup, &
                      vfs_dentry_inode, vfs_is_dir, vfs_inode_priv, &
                      vfs_inode_set_priv, vfs_inode_set_meta, &
                      vfs_super_set_priv
  use fk_vfs_types_m, only: FK_VFS_NONE, FK_VFS_NAME_MAX, FK_S_IFMT, &
                            FK_S_IFDIR, FK_S_IFREG
  implicit none
  private

  public :: FK_EXT2_OK, FK_EXT2_E_IO, FK_EXT2_E_MAGIC, FK_EXT2_E_DIRTY, &
            FK_EXT2_E_REV, FK_EXT2_E_FEATURE, FK_EXT2_E_BLOCKSIZE, &
            FK_EXT2_E_GEOMETRY, FK_EXT2_E_INO, FK_EXT2_E_CORRUPT, &
            FK_EXT2_E_NOENT, FK_EXT2_E_FBIG, FK_EXT2_E_NOMOUNT, &
            FK_EXT2_E_NOTDIR, FK_EXT2_E_VFS
  public :: ext2_reset, ext2_mount, ext2_mounted_sb
  public :: ext2_block_size, ext2_inode_size, ext2_inodes_per_group, &
            ext2_blocks_per_group, ext2_inodes_count, ext2_blocks_count, &
            ext2_first_ino, ext2_group_count, ext2_inode_table
  public :: ext2_stat, ext2_stat_mode, ext2_stat_size, ext2_stat_links, &
            ext2_stat_block, ext2_first_lba

  integer(c_int32_t), parameter :: FK_EXT2_OK = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_EXT2_E_IO = -1_c_int32_t
  integer(c_int32_t), parameter :: FK_EXT2_E_MAGIC = -2_c_int32_t
  integer(c_int32_t), parameter :: FK_EXT2_E_DIRTY = -3_c_int32_t
  integer(c_int32_t), parameter :: FK_EXT2_E_REV = -4_c_int32_t
  integer(c_int32_t), parameter :: FK_EXT2_E_FEATURE = -5_c_int32_t
  integer(c_int32_t), parameter :: FK_EXT2_E_BLOCKSIZE = -6_c_int32_t
  integer(c_int32_t), parameter :: FK_EXT2_E_GEOMETRY = -7_c_int32_t
  integer(c_int32_t), parameter :: FK_EXT2_E_INO = -8_c_int32_t
  integer(c_int32_t), parameter :: FK_EXT2_E_CORRUPT = -9_c_int32_t
  integer(c_int32_t), parameter :: FK_EXT2_E_NOENT = -10_c_int32_t
  integer(c_int32_t), parameter :: FK_EXT2_E_FBIG = -11_c_int32_t
  integer(c_int32_t), parameter :: FK_EXT2_E_NOMOUNT = -12_c_int32_t
  integer(c_int32_t), parameter :: FK_EXT2_E_NOTDIR = -13_c_int32_t
  integer(c_int32_t), parameter :: FK_EXT2_E_VFS = -14_c_int32_t

  ! The superblock, decoded once at mount.  Every one of these is an UNSIGNED
  ! on-disk field held in a SIGNED 64-bit here, which is why blk_le32 returns
  ! 64 bits: roadmap 4.1's MADT walk was found reading 2 GiB below a table
  ! because a 32-bit length had gone negative, and every bound below is a
  ! comparison of exactly that shape.
  integer(c_int64_t), save :: sb_inodes_count = 0_c_int64_t
  integer(c_int64_t), save :: sb_blocks_count = 0_c_int64_t
  integer(c_int64_t), save :: sb_blocks_per_group = 0_c_int64_t
  integer(c_int64_t), save :: sb_inodes_per_group = 0_c_int64_t
  integer(c_int64_t), save :: sb_first_ino = 0_c_int64_t
  integer(c_int32_t), save :: sb_block_size = 0_c_int32_t
  integer(c_int32_t), save :: sb_inode_size = 0_c_int32_t
  integer(c_int32_t), save :: sb_sectors_per_block = 0_c_int32_t
  integer(c_int64_t), save :: sb_group_count = 0_c_int64_t
  integer(c_int64_t), save :: sb_gd_table = 0_c_int64_t
  integer(c_int64_t), save :: sb_inode_table0 = 0_c_int64_t
  integer(c_int32_t), save :: mounted_sb = FK_VFS_NONE

  ! The most recently read inode.  A single slot rather than a cache: the block
  ! buffer under it is also a single slot, so a second inode held here could
  ! never be refreshed without invalidating the first anyway.
  integer(c_int64_t), save :: st_ino = 0_c_int64_t
  integer(c_int32_t), save :: st_mode = 0_c_int32_t
  integer(c_int64_t), save :: st_size = 0_c_int64_t
  integer(c_int32_t), save :: st_links = 0_c_int32_t
  integer(c_int64_t), save :: st_block(0:FK_E2_NDIR_BLOCKS - 1) = 0_c_int64_t

contains

  subroutine ext2_reset() bind(c, name="ext2_reset")
    implicit none
    integer(c_int32_t) :: k

    sb_inodes_count = 0_c_int64_t
    sb_blocks_count = 0_c_int64_t
    sb_blocks_per_group = 0_c_int64_t
    sb_inodes_per_group = 0_c_int64_t
    sb_first_ino = 0_c_int64_t
    sb_block_size = 0_c_int32_t
    sb_inode_size = 0_c_int32_t
    sb_sectors_per_block = 0_c_int32_t
    sb_group_count = 0_c_int64_t
    sb_gd_table = 0_c_int64_t
    sb_inode_table0 = 0_c_int64_t
    mounted_sb = FK_VFS_NONE
    st_ino = 0_c_int64_t
    st_mode = 0_c_int32_t
    st_size = 0_c_int64_t
    st_links = 0_c_int32_t
    do k = 0_c_int32_t, FK_E2_NDIR_BLOCKS - 1_c_int32_t
       st_block(k) = 0_c_int64_t
    end do
  end subroutine ext2_reset

  ! ---- the superblock -------------------------------------------------------

  ! THE ONE STRUCTURE LOCATED WITHOUT KNOWING THE BLOCK SIZE, because it is at
  ! an absolute byte offset (super.c:933-937).  1024 / 512 is sector 2, and two
  ! sectors is the whole superblock however the filesystem is formatted.
  function read_super() result(status)
    implicit none
    integer(c_int32_t) :: status
    integer(c_int64_t) :: magic, state, rev, incompat, logbs, first_data

    status = FK_EXT2_E_IO
    if (blk_read(int(FK_E2_SUPER_OFF / FK_BLK_SECTOR_BYTES, c_int64_t), &
                 FK_E2_SUPER_OFF / FK_BLK_SECTOR_BYTES) /= FK_BLK_OK) return

    magic = blk_le16(FK_E2_SB_MAGIC)
    if (magic < 0_c_int64_t) return
    status = FK_EXT2_E_MAGIC
    if (magic /= int(FK_E2_SUPER_MAGIC, c_int64_t)) return

    ! ext2.h:358.  Refused, not repaired: a dirty filesystem is the input that
    ! makes every bound below untrustworthy, and there is no fsck here.
    state = blk_le16(FK_E2_SB_STATE)
    status = FK_EXT2_E_DIRTY
    if (iand(state, int(FK_E2_STATE_VALID, c_int64_t)) == 0_c_int64_t) return

    rev = blk_le32(FK_E2_SB_REV_LEVEL)
    status = FK_EXT2_E_REV
    if (rev < 0_c_int64_t .or. rev > int(FK_E2_MAX_SUPP_REV, c_int64_t)) return

    ! ext2.h:437-448.  s_first_ino, s_inode_size and the three feature words
    ! EXIST ONLY IN A DYNAMIC_REV SUPERBLOCK.  Reading them off a rev-0 disk
    ! reads whatever the format put there instead, which for s_inode_size is a
    ! byte pair that is not 128 and makes every inode after the first land at
    ! the wrong offset.
    if (rev >= int(FK_E2_DYNAMIC_REV, c_int64_t)) then
       sb_first_ino = blk_le32(FK_E2_SB_FIRST_INO)
       sb_inode_size = int(blk_le16(FK_E2_SB_INODE_SIZE), c_int32_t)
       incompat = blk_le32(FK_E2_SB_FEATURE_INCOMPAT)
    else
       sb_first_ino = int(FK_E2_GOOD_OLD_FIRST_INO, c_int64_t)
       sb_inode_size = FK_E2_GOOD_OLD_INODE_SIZE
       incompat = 0_c_int64_t
    end if
    if (sb_first_ino < 0_c_int64_t .or. incompat < 0_c_int64_t) then
       status = FK_EXT2_E_IO
       return
    end if

    ! ext2.h:552.  An ALLOWLIST: any incompatible bit this driver does not
    ! implement means the parse below would be describing a layout it is not
    ! looking at, and the format says so in as many words.
    status = FK_EXT2_E_FEATURE
    if (iand(incompat, not(int(FK_E2_INCOMPAT_SUPP, c_int64_t))) &
        /= 0_c_int64_t) return

    logbs = blk_le32(FK_E2_SB_LOG_BLOCK_SIZE)
    status = FK_EXT2_E_BLOCKSIZE
    if (logbs < 0_c_int64_t) return
    if (logbs > int(FK_E2_MAX_BLOCK_LOG - FK_E2_MIN_BLOCK_LOG, c_int64_t)) &
         return
    sb_block_size = shiftl(1_c_int32_t, FK_E2_MIN_BLOCK_LOG + &
                                        int(logbs, c_int32_t))
    sb_sectors_per_block = sb_block_size / FK_BLK_SECTOR_BYTES

    ! super.c:1043-1045, all three of its conditions: at least the original
    ! 128, a power of two, and no larger than a block.  The power-of-two clause
    ! is the one that is easy to leave out and it is what keeps an inode from
    ! straddling a block boundary that ext2_stat's index arithmetic assumes it
    ! never crosses.
    status = FK_EXT2_E_GEOMETRY
    if (sb_inode_size < FK_E2_GOOD_OLD_INODE_SIZE) return
    if (sb_inode_size > sb_block_size) return
    if (iand(sb_inode_size, sb_inode_size - 1_c_int32_t) /= 0_c_int32_t) return

    sb_inodes_count = blk_le32(FK_E2_SB_INODES_COUNT)
    sb_blocks_count = blk_le32(FK_E2_SB_BLOCKS_COUNT)
    sb_blocks_per_group = blk_le32(FK_E2_SB_BLOCKS_PER_GROUP)
    sb_inodes_per_group = blk_le32(FK_E2_SB_INODES_PER_GROUP)
    first_data = blk_le32(20_c_int32_t)
    if (sb_inodes_count < 0_c_int64_t .or. sb_blocks_count < 0_c_int64_t .or. &
        sb_blocks_per_group < 0_c_int64_t .or. &
        sb_inodes_per_group < 0_c_int64_t .or. first_data < 0_c_int64_t) then
       status = FK_EXT2_E_IO
       return
    end if

    ! EVERY ONE OF THESE IS A DIVISOR OR A BOUND BELOW.  Zero inodes per group
    ! is a divide by zero in read_inode; zero blocks per group is one in the
    ! group count.  A geometry that does not describe the device it was found
    ! on is refused here rather than discovered as a read past the end.
    if (sb_inodes_per_group <= 0_c_int64_t) return
    if (sb_blocks_per_group <= 0_c_int64_t) return
    if (sb_inodes_count <= 0_c_int64_t .or. sb_blocks_count <= 0_c_int64_t) &
         return
    if (sb_inodes_count > sb_inodes_per_group * &
        ((sb_blocks_count + sb_blocks_per_group - 1_c_int64_t) / &
         sb_blocks_per_group)) return
    if (blk_capacity() > 0_c_int64_t .and. &
        sb_blocks_count * int(sb_sectors_per_block, c_int64_t) > &
        blk_capacity()) return

    ! super.c:813, descriptor_loc() with nr = 0: the descriptor table starts in
    ! the block AFTER the one the superblock lives in, and that block is
    ! 1024/blocksize -- 1 at a 1 KiB block, 0 at anything larger.
    sb_gd_table = int(FK_E2_SUPER_OFF / sb_block_size, c_int64_t) + 1_c_int64_t
    sb_group_count = (sb_blocks_count - first_data + sb_blocks_per_group - &
                      1_c_int64_t) / sb_blocks_per_group
    if (sb_group_count <= 0_c_int64_t) return

    status = FK_EXT2_OK
  end function read_super

  ! ---- inodes ---------------------------------------------------------------

  ! balloc.c:56-57.  The descriptor table is an array of 32-byte records that
  ! spans as many blocks as it needs, so the group's index is split into a
  ! block and an offset rather than assumed to fit in the first one.
  function read_group_desc(group, table) result(status)
    implicit none
    integer(c_int64_t), intent(in), value :: group
    integer(c_int64_t), intent(out) :: table
    integer(c_int32_t) :: status
    integer(c_int64_t) :: byte_off, blk, v

    table = 0_c_int64_t
    status = FK_EXT2_E_GEOMETRY
    if (group < 0_c_int64_t .or. group >= sb_group_count) return

    byte_off = group * int(FK_E2_GD_SIZE, c_int64_t)
    blk = sb_gd_table + byte_off / int(sb_block_size, c_int64_t)
    status = read_block(blk)
    if (status /= FK_EXT2_OK) return

    v = blk_le32(int(mod(byte_off, int(sb_block_size, c_int64_t)), &
                     c_int32_t) + FK_E2_GD_INODE_TABLE)
    if (v <= 0_c_int64_t .or. v >= sb_blocks_count) then
       status = FK_EXT2_E_CORRUPT
       return
    end if
    table = v
    status = FK_EXT2_OK
  end function read_group_desc

  ! inode.c:1328-1346, and the validity test is that function's own:
  ! `(ino != EXT2_ROOT_INO && ino < EXT2_FIRST_INO(sb)) || ino > s_inodes_count`.
  ! The middle clause is the one worth keeping -- inodes 1 and 3..10 are
  ! RESERVED, they exist in the table and they are not files, so a driver that
  ! only bounds-checks will happily hand back inode 1's contents.
  function ext2_stat(ino) result(status) bind(c, name="ext2_stat")
    implicit none
    integer(c_int64_t), intent(in), value :: ino
    integer(c_int32_t) :: status
    integer(c_int64_t) :: group, index, byte_off, table, blk, lo, hi
    integer(c_int32_t) :: off, k

    status = FK_EXT2_E_NOMOUNT
    if (sb_block_size == 0_c_int32_t) return

    status = FK_EXT2_E_INO
    if (ino <= 0_c_int64_t .or. ino > sb_inodes_count) return
    if (ino /= int(FK_E2_ROOT_INO, c_int64_t) .and. ino < sb_first_ino) return

    group = (ino - 1_c_int64_t) / sb_inodes_per_group
    index = mod(ino - 1_c_int64_t, sb_inodes_per_group)
    status = read_group_desc(group, table)
    if (status /= FK_EXT2_OK) return
    if (group == 0_c_int64_t) sb_inode_table0 = table

    byte_off = index * int(sb_inode_size, c_int64_t)
    blk = table + byte_off / int(sb_block_size, c_int64_t)
    status = read_block(blk)
    if (status /= FK_EXT2_OK) return
    off = int(mod(byte_off, int(sb_block_size, c_int64_t)), c_int32_t)

    st_mode = int(blk_le16(off + FK_E2_I_MODE), c_int32_t)
    st_links = int(blk_le16(off + FK_E2_I_LINKS_COUNT), c_int32_t)
    lo = blk_le32(off + FK_E2_I_SIZE)
    if (st_mode < 0_c_int32_t .or. st_links < 0_c_int32_t .or. &
        lo < 0_c_int64_t) then
       status = FK_EXT2_E_IO
       return
    end if

    ! ext2.h:344.  i_size_high is the high half FOR A REGULAR FILE ONLY -- on a
    ! directory the same word is i_dir_acl, and joining it would report a
    ! directory whose size has an ACL block number in its top 32 bits.
    st_size = lo
    if (iand(st_mode, FK_S_IFMT) == FK_S_IFREG) then
       hi = blk_le32(off + FK_E2_I_SIZE_HIGH)
       if (hi < 0_c_int64_t) then
          status = FK_EXT2_E_IO
          return
       end if
       st_size = ior(lo, shiftl(hi, 32))
    end if

    do k = 0_c_int32_t, FK_E2_NDIR_BLOCKS - 1_c_int32_t
       st_block(k) = blk_le32(off + FK_E2_I_BLOCK + k * 4_c_int32_t)
       if (st_block(k) < 0_c_int64_t) then
          status = FK_EXT2_E_IO
          return
       end if
       ! A block number past the end of the filesystem is corruption, and it is
       ! checked HERE rather than at the read, because read_block's own refusal
       ! cannot tell it apart from a caller asking for the wrong thing.  Zero
       ! is legal: ext2 spells a hole that way.
       if (st_block(k) >= sb_blocks_count) then
          status = FK_EXT2_E_CORRUPT
          return
       end if
    end do

    st_ino = ino
    status = FK_EXT2_OK
  end function ext2_stat

  function read_block(blk) result(status)
    implicit none
    integer(c_int64_t), intent(in), value :: blk
    integer(c_int32_t) :: status

    status = FK_EXT2_E_CORRUPT
    if (blk <= 0_c_int64_t .or. blk >= sb_blocks_count) return
    status = FK_EXT2_E_IO
    if (blk_read(blk * int(sb_sectors_per_block, c_int64_t), &
                 sb_sectors_per_block) /= FK_BLK_OK) return
    status = FK_EXT2_OK
  end function read_block

  ! ---- the directory walk ---------------------------------------------------

  ! dir.c:118-131's ext2_check_folio, entry by entry rather than block by
  ! block.  FIVE REFUSALS AND THEY ARE ALL ITS, in its order:
  !
  !   rec_len < EXT2_DIR_REC_LEN(1)     dir.c:122, "rec_len is smaller than
  !                                     minimal" -- and it is THIS ONE that
  !                                     makes the loop terminate.  rec_len 0 is
  !                                     an offset that never advances, so a
  !                                     driver without this check does not
  !                                     return a wrong answer, it HANGS.
  !   rec_len & 3                       dir.c:124, "unaligned directory entry"
  !   rec_len < EXT2_DIR_REC_LEN(nlen)  dir.c:126, "rec_len is too small for
  !                                     name_len" -- without it a name is read
  !                                     out of the NEXT entry's bytes
  !   entry crosses the block           dir.c:128, "directory entry across
  !                                     blocks"
  !   inode > s_inodes_count            dir.c:130, "inode out of bounds"
  !
  ! A corrupt entry ABANDONS THE BLOCK rather than skipping to the next record.
  ! Once a rec_len is not trustworthy there is no next record to skip to; the
  ! offset that would find it came from the field that just failed.
  function dir_find(nb, len, found) result(status)
    implicit none
    integer(c_int8_t), intent(in) :: nb(*)
    integer(c_int32_t), intent(in), value :: len
    integer(c_int64_t), intent(out) :: found
    integer(c_int32_t) :: status
    integer(c_int32_t) :: off, rec, nlen, k, bi
    integer(c_int64_t) :: ino, want_blocks, b, dir_size
    integer(c_int64_t) :: blocks(0:FK_E2_NDIR_BLOCKS - 1)
    logical :: same

    found = 0_c_int64_t
    dir_size = st_size
    do bi = 0_c_int32_t, FK_E2_NDIR_BLOCKS - 1_c_int32_t
       blocks(bi) = st_block(bi)
    end do

    ! A directory bigger than twelve direct blocks is REFUSED, not truncated.
    ! Walking the blocks that are reachable and reporting -ENOENT would be a
    ! lie of exactly the shape roadmap 6.4 must not inherit: the name is there
    ! and this driver cannot see it.
    want_blocks = (dir_size + int(sb_block_size, c_int64_t) - 1_c_int64_t) / &
                  int(sb_block_size, c_int64_t)
    status = FK_EXT2_E_FBIG
    if (want_blocks > int(FK_E2_NDIR_BLOCKS, c_int64_t)) return

    do bi = 0_c_int32_t, FK_E2_NDIR_BLOCKS - 1_c_int32_t
       if (int(bi, c_int64_t) >= want_blocks) exit
       b = blocks(bi)
       ! A hole in a directory is legal and carries no entries.
       if (b == 0_c_int64_t) cycle
       status = read_block(b)
       if (status /= FK_EXT2_OK) return

       off = 0_c_int32_t
       do while (off <= sb_block_size - FK_E2_DIR_MIN_REC)
          ino = blk_le32(off + FK_E2_DE_INODE)
          rec = blk_le16(off + FK_E2_DE_REC_LEN)
          nlen = blk_u8(off + FK_E2_DE_NAME_LEN)
          status = FK_EXT2_E_CORRUPT
          if (ino < 0_c_int64_t .or. rec < 0_c_int32_t .or. &
              nlen < 0_c_int32_t) return
          if (rec < FK_E2_DIR_MIN_REC) return
          if (iand(rec, FK_E2_DIR_PAD - 1_c_int32_t) /= 0_c_int32_t) return
          if (FK_E2_DE_NAME + nlen > rec) return
          if (off + rec > sb_block_size) return
          if (ino > sb_inodes_count) return

          ! ino 0 is an entry that has been deleted in place; the record still
          ! holds its space and must still be stepped over.
          if (ino /= 0_c_int64_t .and. nlen == len) then
             same = .true.
             do k = 1_c_int32_t, len
                if (blk_u8(off + FK_E2_DE_NAME + k - 1_c_int32_t) /= &
                    iand(int(nb(k), c_int32_t), 255_c_int32_t)) then
                   same = .false.
                   exit
                end if
             end do
             if (same) then
                found = ino
                status = FK_EXT2_OK
                return
             end if
          end if
          off = off + rec
       end do
    end do

    status = FK_EXT2_E_NOENT
  end function dir_find

  ! ---- the seam -------------------------------------------------------------

  ! CALLED BY src/fs/fk_vfs.f90's vfs_lookup WHEN THE DENTRY TREE MISSES, and
  ! it is the only entry point 6.2 adds to a path walk.  Nothing else in the
  ! kernel calls it; vfs_resolve reaches it by missing.
  !
  ! The name arrives as (pointer, length) rather than a C string for the reason
  ! vfs_lookup's own header gives: a path component is terminated by a slash or
  ! by the end of the path, so there is no NUL for strcmp to stop at.
  function fk_vfs_fill(parent, name, len) result(d) bind(c, name="fk_vfs_fill")
    implicit none
    integer(c_int32_t), intent(in), value :: parent, len
    type(c_ptr), intent(in), value :: name
    integer(c_int32_t) :: d
    ! CONTIGUOUS IS NOT DECORATION, it is a kernel-linkability requirement.
    ! Without it gfortran cannot know this pointer's target is contiguous, so
    ! passing it to dir_find's assumed-size dummy emits a call to
    ! _gfortran_internal_pack -- a libgfortran symbol, which is exactly what
    ! `make symcheck` refuses and what would fail the kernel link.  c_f_pointer
    ! always produces a contiguous target, so the assertion is true as well as
    ! necessary.
    integer(c_int8_t), pointer, contiguous :: nb(:)
    integer(c_int64_t) :: parent_ino, child_ino
    integer(c_int32_t) :: pi, ci, status, mode
    integer(c_int64_t) :: size

    d = FK_VFS_NONE
    if (mounted_sb == FK_VFS_NONE) return
    if (.not. c_associated(name)) return
    if (len < 1_c_int32_t .or. len > FK_VFS_NAME_MAX) return
    if (vfs_is_dir(parent) == 0_c_int32_t) return

    pi = vfs_dentry_inode(parent)
    parent_ino = vfs_inode_priv(pi)
    ! A dentry whose i_priv is zero belongs to no ext2 inode -- it was put in
    ! the tree by hand, which is what every 6.1 test does.  Filling from it
    ! would parse whichever inode number happens to be zero-adjacent.
    if (parent_ino <= 0_c_int64_t) return

    call c_f_pointer(name, nb, [int(len, c_size_t)])

    if (ext2_stat(parent_ino) /= FK_EXT2_OK) return
    if (iand(st_mode, FK_S_IFMT) /= FK_S_IFDIR) return
    if (dir_find(nb, len, child_ino) /= FK_EXT2_OK) return

    ! THE PARENT'S BLOCK BUFFER IS GONE AFTER THIS, and it does not matter:
    ! everything still needed from the directory is in child_ino.
    if (ext2_stat(child_ino) /= FK_EXT2_OK) return
    mode = st_mode
    size = st_size

    ! vfs_add MAINTAINS THE CHILD LIST, and it is called rather than the list
    ! being linked here on purpose.  Mutation M106 removed a dentry without
    ! unlinking it, the slot was reused, the list closed into a cycle and
    ! vfs_lookup walked it forever; every invariant that prevents it lives in
    ! that function and nowhere else.
    d = vfs_add(parent, name, len, mode, size)
    if (d <= FK_VFS_NONE) then
       d = FK_VFS_NONE
       return
    end if

    ci = vfs_dentry_inode(d)
    status = vfs_inode_set_priv(ci, child_ino)
    if (status == 0_c_int32_t) status = vfs_inode_set_meta(ci, mode, size)
    if (status /= 0_c_int32_t) d = FK_VFS_NONE
  end function fk_vfs_fill

  ! ---- mount ----------------------------------------------------------------

  ! Creates the VFS superblock AND populates its root from inode 2, so that the
  ! tree a caller resolves against is the disk's from the first component
  ! rather than from the second.
  function ext2_mount(dev) result(sb) bind(c, name="ext2_mount")
    implicit none
    integer(c_int32_t), intent(in), value :: dev
    integer(c_int32_t) :: sb
    integer(c_int32_t) :: status, root, ri

    mounted_sb = FK_VFS_NONE
    status = read_super()
    if (status /= FK_EXT2_OK) then
       sb = status
       return
    end if

    status = ext2_stat(int(FK_E2_ROOT_INO, c_int64_t))
    if (status /= FK_EXT2_OK) then
       sb = status
       return
    end if
    sb = FK_EXT2_E_NOTDIR
    if (iand(st_mode, FK_S_IFMT) /= FK_S_IFDIR) return

    sb = vfs_mount(int(FK_E2_SUPER_MAGIC, c_int64_t), &
                   int(sb_block_size, c_int64_t), dev)
    if (sb <= FK_VFS_NONE) then
       sb = FK_EXT2_E_VFS
       return
    end if

    root = vfs_root(sb)
    ri = vfs_dentry_inode(root)
    status = vfs_inode_set_priv(ri, int(FK_E2_ROOT_INO, c_int64_t))
    if (status == 0_c_int32_t) status = vfs_inode_set_meta(ri, st_mode, st_size)
    if (status == 0_c_int32_t) status = vfs_super_set_priv(sb, sb_inode_table0)
    if (status /= 0_c_int32_t) then
       sb = FK_EXT2_E_VFS
       return
    end if

    mounted_sb = sb
  end function ext2_mount

  ! ---- accessors ------------------------------------------------------------

  ! THE STARTING LBA, and it is recomputed off the disk rather than cached at
  ! fill time.  A cached value proves that a number was written down once; this
  ! proves the inode is still there and still says the same thing, which is the
  ! claim roadmap 6.2's validation actually makes.
  function ext2_first_lba(inode_h) result(v) bind(c, name="ext2_first_lba")
    implicit none
    integer(c_int32_t), intent(in), value :: inode_h
    integer(c_int64_t) :: v
    integer(c_int64_t) :: ino

    v = -1_c_int64_t
    ino = vfs_inode_priv(inode_h)
    if (ino <= 0_c_int64_t) return
    if (ext2_stat(ino) /= FK_EXT2_OK) return
    if (st_block(0) == 0_c_int64_t) return
    v = st_block(0) * int(sb_sectors_per_block, c_int64_t)
  end function ext2_first_lba

  function ext2_mounted_sb() result(v) bind(c, name="ext2_mounted_sb")
    implicit none
    integer(c_int32_t) :: v

    v = mounted_sb
  end function ext2_mounted_sb

  function ext2_block_size() result(v) bind(c, name="ext2_block_size")
    implicit none
    integer(c_int32_t) :: v

    v = sb_block_size
  end function ext2_block_size

  function ext2_inode_size() result(v) bind(c, name="ext2_inode_size")
    implicit none
    integer(c_int32_t) :: v

    v = sb_inode_size
  end function ext2_inode_size

  function ext2_inodes_per_group() result(v) &
       bind(c, name="ext2_inodes_per_group")
    implicit none
    integer(c_int64_t) :: v

    v = sb_inodes_per_group
  end function ext2_inodes_per_group

  function ext2_blocks_per_group() result(v) &
       bind(c, name="ext2_blocks_per_group")
    implicit none
    integer(c_int64_t) :: v

    v = sb_blocks_per_group
  end function ext2_blocks_per_group

  function ext2_inodes_count() result(v) bind(c, name="ext2_inodes_count")
    implicit none
    integer(c_int64_t) :: v

    v = sb_inodes_count
  end function ext2_inodes_count

  function ext2_blocks_count() result(v) bind(c, name="ext2_blocks_count")
    implicit none
    integer(c_int64_t) :: v

    v = sb_blocks_count
  end function ext2_blocks_count

  function ext2_first_ino() result(v) bind(c, name="ext2_first_ino")
    implicit none
    integer(c_int64_t) :: v

    v = sb_first_ino
  end function ext2_first_ino

  function ext2_group_count() result(v) bind(c, name="ext2_group_count")
    implicit none
    integer(c_int64_t) :: v

    v = sb_group_count
  end function ext2_group_count

  function ext2_inode_table() result(v) bind(c, name="ext2_inode_table")
    implicit none
    integer(c_int64_t) :: v

    v = sb_inode_table0
  end function ext2_inode_table

  function ext2_stat_mode() result(v) bind(c, name="ext2_stat_mode")
    implicit none
    integer(c_int32_t) :: v

    v = st_mode
  end function ext2_stat_mode

  function ext2_stat_size() result(v) bind(c, name="ext2_stat_size")
    implicit none
    integer(c_int64_t) :: v

    v = st_size
  end function ext2_stat_size

  function ext2_stat_links() result(v) bind(c, name="ext2_stat_links")
    implicit none
    integer(c_int32_t) :: v

    v = st_links
  end function ext2_stat_links

  function ext2_stat_block(k) result(v) bind(c, name="ext2_stat_block")
    implicit none
    integer(c_int32_t), intent(in), value :: k
    integer(c_int64_t) :: v

    v = -1_c_int64_t
    if (k < 0_c_int32_t .or. k >= FK_E2_NDIR_BLOCKS) return
    v = st_block(k)
  end function ext2_stat_block

end module fk_ext2_m
