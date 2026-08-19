! SPDX-License-Identifier: GPL-2.0
! The VFS primitives: superblock, inode, dentry, file.  Roadmap 6.1.
!
! HANDLES, NOT POINTERS, and it is the decision the rest of the module is built
! on.  Linux links these four with `struct dentry *`; this kernel's heap is
! single threaded, not preemption safe and stops allocating before sched_start,
! so a tree that outlives bring-up cannot live in it, and 03-guidelines.md
! forbids a dynamically allocated array without explicit lifecycle management
! anyway.  Every link below is therefore a 1-BASED INDEX into a fixed pool, and
! FK_VFS_NONE = 0 is the null.  The structs are still bind(c) -- an int32 handle
! is a C field, and what makes a struct C-compatible is its layout.
!
! Sizes: inode 48, dentry 284, file 24, super 40.  All four are laid out so C's
! natural alignment inserts no padding, which is what lets tests/fs/test_vfs.c
! declare its own mirror and write through it.
!
! The constants are the kernel's own.  tests/fs/test_vfs.c includes
! vendor/linux-7.1.8/include/uapi/{asm-generic/errno.h,linux/stat.h,
! linux/limits.h} DIRECTLY and diffs every value below against them, so nothing
! here is transcribed on trust.
module fk_vfs_types_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t, c_char
  implicit none
  private

  public :: FK_VFS_NONE, FK_VFS_NAME_MAX, FK_VFS_PATH_MAX
  public :: FK_VFS_INODES, FK_VFS_DENTRIES, FK_VFS_FILES, FK_VFS_SUPERS
  public :: FK_VFS_LIVE
  public :: FK_S_IFMT, FK_S_IFDIR, FK_S_IFREG, FK_S_IFLNK
  public :: FK_S_IRWXU, FK_S_IRWXG, FK_S_IRWXO
  public :: FK_O_RDONLY, FK_O_WRONLY, FK_O_RDWR, FK_O_ACCMODE
  public :: FK_E_BADF, FK_E_NOMEM, FK_E_EXIST, FK_E_NOTDIR, FK_E_ISDIR, &
            FK_E_INVAL, FK_E_MFILE, FK_E_NOENT, FK_E_BUSY, &
            FK_E_NAMETOOLONG, FK_E_NOTEMPTY
  public :: fk_inode_t, fk_dentry_t, fk_file_t, fk_super_t

  ! Handle 0 is the null, so the pools are 1-based and a zeroed pool is empty.
  integer(c_int32_t), parameter :: FK_VFS_NONE = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_VFS_LIVE = 1_c_int32_t

  ! uapi/linux/limits.h:12-13.
  integer(c_int32_t), parameter :: FK_VFS_NAME_MAX = 255_c_int32_t
  integer(c_int32_t), parameter :: FK_VFS_PATH_MAX = 4096_c_int32_t

  integer(c_int32_t), parameter :: FK_VFS_INODES = 64_c_int32_t
  integer(c_int32_t), parameter :: FK_VFS_DENTRIES = 64_c_int32_t
  integer(c_int32_t), parameter :: FK_VFS_FILES = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_VFS_SUPERS = 4_c_int32_t

  ! uapi/linux/stat.h:9-14, 29/34/39.
  integer(c_int32_t), parameter :: FK_S_IFMT = int(o'170000', c_int32_t)
  integer(c_int32_t), parameter :: FK_S_IFDIR = int(o'40000', c_int32_t)
  integer(c_int32_t), parameter :: FK_S_IFREG = int(o'100000', c_int32_t)
  integer(c_int32_t), parameter :: FK_S_IFLNK = int(o'120000', c_int32_t)
  integer(c_int32_t), parameter :: FK_S_IRWXU = int(o'700', c_int32_t)
  integer(c_int32_t), parameter :: FK_S_IRWXG = int(o'70', c_int32_t)
  integer(c_int32_t), parameter :: FK_S_IRWXO = int(o'7', c_int32_t)

  ! uapi/asm-generic/fcntl.h:19-22.
  integer(c_int32_t), parameter :: FK_O_RDONLY = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_O_WRONLY = 1_c_int32_t
  integer(c_int32_t), parameter :: FK_O_RDWR = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_O_ACCMODE = 3_c_int32_t

  ! uapi/asm-generic/errno-base.h and errno.h.  Every one of these is returned
  ! NEGATED, which is how a handle-returning function says "not a handle":
  ! handles are positive and FK_VFS_NONE is 0, so the sign is unambiguous.
  integer(c_int32_t), parameter :: FK_E_BADF = 9_c_int32_t
  integer(c_int32_t), parameter :: FK_E_NOMEM = 12_c_int32_t
  integer(c_int32_t), parameter :: FK_E_EXIST = 17_c_int32_t
  integer(c_int32_t), parameter :: FK_E_BUSY = 16_c_int32_t
  integer(c_int32_t), parameter :: FK_E_NOTDIR = 20_c_int32_t
  integer(c_int32_t), parameter :: FK_E_ISDIR = 21_c_int32_t
  integer(c_int32_t), parameter :: FK_E_INVAL = 22_c_int32_t
  integer(c_int32_t), parameter :: FK_E_MFILE = 24_c_int32_t
  integer(c_int32_t), parameter :: FK_E_NOENT = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_E_NAMETOOLONG = 36_c_int32_t
  integer(c_int32_t), parameter :: FK_E_NOTEMPTY = 39_c_int32_t

  ! i_priv is s_fs_info's per-inode twin: the block number an ext2 or FAT32
  ! driver stores at 6.2.  Nothing in 6.1 reads it, and that is the point --
  ! it is the seam, declared, rather than a layer built for a caller that does
  ! not exist yet.
  type, bind(c) :: fk_inode_t
    integer(c_int32_t) :: i_mode
    integer(c_int32_t) :: i_nlink
    integer(c_int64_t) :: i_ino
    integer(c_int64_t) :: i_size
    integer(c_int64_t) :: i_priv
    integer(c_int32_t) :: i_uid
    integer(c_int32_t) :: i_gid
    integer(c_int32_t) :: i_sb
    integer(c_int32_t) :: i_flags
  end type fk_inode_t

  ! d_child is the head of this dentry's child list and d_sib is this dentry's
  ! own link in its parent's, which is dcache.h:123-124's hlist_head/hlist_node
  ! pair with the pointers replaced by handles.
  !
  ! THE NAME IS INLINE AT NAME_MAX, and that is a deliberate deviation.
  ! dcache.h:72-87 inlines 40 bytes on 64-bit and allocates externally for
  ! anything longer; there is nothing here to allocate from, so the limit a
  ! caller meets is the vendor's 255 rather than an artefact at 40.  64 dentries
  ! is 18 KiB of .bss, which is NOBITS and costs the image no file bytes.
  type, bind(c) :: fk_dentry_t
    integer(c_int32_t) :: d_parent
    integer(c_int32_t) :: d_inode
    integer(c_int32_t) :: d_sb
    integer(c_int32_t) :: d_child
    integer(c_int32_t) :: d_sib
    integer(c_int32_t) :: d_len
    integer(c_int32_t) :: d_flags
    character(kind=c_char) :: d_name(FK_VFS_NAME_MAX + 1_c_int32_t)
  end type fk_dentry_t

  type, bind(c) :: fk_file_t
    integer(c_int64_t) :: f_pos
    integer(c_int32_t) :: f_dentry
    integer(c_int32_t) :: f_inode
    integer(c_int32_t) :: f_flags
    integer(c_int32_t) :: f_state
  end type fk_file_t

  type, bind(c) :: fk_super_t
    integer(c_int64_t) :: s_magic
    integer(c_int64_t) :: s_blocksize
    integer(c_int64_t) :: s_priv
    integer(c_int32_t) :: s_root
    integer(c_int32_t) :: s_dev
    integer(c_int32_t) :: s_ninodes
    integer(c_int32_t) :: s_flags
  end type fk_super_t

end module fk_vfs_types_m
