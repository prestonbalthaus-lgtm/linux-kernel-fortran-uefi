! SPDX-License-Identifier: GPL-2.0
! The virtual filesystem: fixed pools, a dentry tree, and a path walk.
! Roadmap 6.1.  NOT a filesystem -- there is no ext2, no FAT32 and no block
! read anywhere below.  That is 6.2, and this is the layer it plugs into.
!
! THE SEAM IS vfs_lookup AND NOTHING ELSE.  Linux dispatches a name through
! inode_operations->lookup because it has many filesystems to dispatch between;
! this tree has none, so an ops table would be indirection with one entry and a
! milestone's worth of abstract interfaces to reach it.  vfs_lookup walks the
! child list today.  6.2 is the first caller for which a MISS means "read the
! directory off the disk", and that is where the indirection earns itself.
! s_priv and i_priv are already there for the block number it will want.
!
! THE WALK IS fs/namei.c:2537-2557, the byte-at-a-time hash_name, whose loop
! condition `while (c && c != '/')` is the whole separator rule.  The
! word-at-a-time variant above it does the same thing with load_unaligned_zeropad
! and a has_zero pair; that is x86 page-safety machinery for a hot path this
! kernel does not have.
!
! A TRAILING SLASH IS NOT STRIPPED, because stripping it silently loses
! -ENOTDIR on a path like /bin/init/.  Linux does not strip it either: the
! component's length stops at the slash and lookup_last (namei.c:2782) tests the
! surviving byte.  Here the walk carries the fact as a flag instead.
module fk_vfs_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t, c_int8_t, &
                                         c_size_t, c_char, c_ptr, c_null_ptr, &
                                         c_f_pointer, c_associated
  use fk_string_m, only: fk_strlen
  use fk_vfs_types_m, only: fk_inode_t, fk_dentry_t, fk_file_t, fk_super_t, &
                            FK_VFS_NONE, FK_VFS_LIVE, FK_VFS_NAME_MAX, &
                            FK_VFS_PATH_MAX, FK_VFS_INODES, FK_VFS_DENTRIES, &
                            FK_VFS_FILES, FK_VFS_SUPERS, &
                            FK_S_IFMT, FK_S_IFDIR, FK_O_ACCMODE, FK_O_RDONLY, &
                            FK_E_BADF, FK_E_NOMEM, FK_E_EXIST, FK_E_NOTDIR, &
                            FK_E_ISDIR, FK_E_INVAL, FK_E_MFILE, FK_E_NOENT, &
                            FK_E_BUSY, FK_E_NAMETOOLONG, FK_E_NOTEMPTY
  implicit none
  private

  public :: vfs_reset, vfs_mount, vfs_root, vfs_add, vfs_remove, vfs_lookup, &
            vfs_resolve, vfs_resolve_at, vfs_open, vfs_close
  public :: vfs_dentry_parent, vfs_dentry_inode, vfs_dentry_child, &
            vfs_dentry_sib, vfs_dentry_len, vfs_dentry_name, vfs_is_dir
  public :: vfs_inode_mode, vfs_inode_size, vfs_inode_ino, vfs_inode_nlink
  public :: vfs_inode_priv, vfs_inode_set_priv, vfs_inode_set_meta
  public :: vfs_super_priv, vfs_super_set_priv, vfs_fills
  public :: vfs_file_inode, vfs_file_pos
  public :: vfs_dentries_used, vfs_inodes_used, vfs_files_used, vfs_super_magic

  integer(c_int8_t), parameter :: SLASH = 47_c_int8_t
  integer(c_int8_t), parameter :: DOT = 46_c_int8_t

  integer(c_int32_t), parameter :: COMP_NAME = 0_c_int32_t
  integer(c_int32_t), parameter :: COMP_DOT = 1_c_int32_t
  integer(c_int32_t), parameter :: COMP_DOTDOT = 2_c_int32_t

  ! Published under their C names so tests/fs/test_vfs.c can declare its own
  ! mirror structs over the same bytes and qmp-sentinel can read the tree out of
  ! a running guest.  Fortran-private because nothing outside this module has a
  ! reason to reach in; bind(c) gives external linkage regardless.
  type(fk_inode_t), save, bind(c, name="fk_vfs_inodes") :: inodes(FK_VFS_INODES)
  type(fk_dentry_t), save, bind(c, name="fk_vfs_dentries") :: &
       dentries(FK_VFS_DENTRIES)
  type(fk_file_t), save, bind(c, name="fk_vfs_files") :: files(FK_VFS_FILES)
  type(fk_super_t), save, bind(c, name="fk_vfs_supers") :: supers(FK_VFS_SUPERS)

  integer(c_int64_t), save :: next_ino = 1_c_int64_t
  integer(c_int32_t), save :: mounted = FK_VFS_NONE

  ! THE MISS PATH (roadmap 6.2), and it is resolved by the LINKER rather than
  ! by a table of function pointers.  6.1's header promised that vfs_lookup
  ! would be the one seam and that an ops table would be indirection with a
  ! single entry; this is that promise kept.  src/fs/fk_ext2.f90 defines the
  ! symbol for the kernel and tests/fs/test_ext2.c defines it for the host
  ! suite, exactly as boot/io.S and the driver tests each define fk_readl.
  !
  ! A filesystem that has not mounted returns FK_VFS_NONE and the lookup misses
  ! as it always did, which is what keeps tests/fs/test_vfs.c's 6.1 assertions
  ! true without a filesystem underneath them.
  interface
    function fk_vfs_fill(parent, name, len) result(d) &
         bind(c, name="fk_vfs_fill")
      import :: c_int32_t, c_ptr
      implicit none
      integer(c_int32_t), intent(in), value :: parent, len
      type(c_ptr), intent(in), value        :: name
      integer(c_int32_t)                    :: d
    end function fk_vfs_fill
  end interface

  ! WITHOUT THIS FLAG THE MISS PATH RECURSES FOREVER.  vfs_add calls vfs_lookup
  ! to enforce -EEXIST, and the filler's whole job is to call vfs_add; so a
  ! filler invoked from inside its own vfs_add re-enters immediately and the
  ! stack is gone.  It arrives as a HANG, not a wrong answer, which is
  ! docs/HARNESS-VALIDATION.md's oldest lesson and why the mutation runner has
  ! a per-case timeout.
  logical, save :: filling = .false.
  integer(c_int64_t), save :: fills = 0_c_int64_t

contains

  ! ---- pools ----------------------------------------------------------------

  ! A LINEAR SCAN, not a free list, and 64 entries is why.  fk_heap_m's header
  ! explains what a free list threaded through freed storage costs when a
  ! use-after-free corrupts it; at this size the scan is not worth that.
  function alloc_inode() result(h)
    implicit none
    integer(c_int32_t) :: h

    do h = 1_c_int32_t, FK_VFS_INODES
       if (inodes(h)%i_flags == FK_VFS_NONE) then
          inodes(h)%i_flags = FK_VFS_LIVE
          inodes(h)%i_ino = next_ino
          next_ino = next_ino + 1_c_int64_t
          inodes(h)%i_nlink = 0_c_int32_t
          inodes(h)%i_size = 0_c_int64_t
          inodes(h)%i_priv = 0_c_int64_t
          inodes(h)%i_uid = 0_c_int32_t
          inodes(h)%i_gid = 0_c_int32_t
          return
       end if
    end do
    h = FK_VFS_NONE
  end function alloc_inode

  function alloc_dentry() result(h)
    implicit none
    integer(c_int32_t) :: h
    integer(c_int32_t) :: k

    do h = 1_c_int32_t, FK_VFS_DENTRIES
       if (dentries(h)%d_flags == FK_VFS_NONE) then
          dentries(h)%d_flags = FK_VFS_LIVE
          dentries(h)%d_parent = FK_VFS_NONE
          dentries(h)%d_inode = FK_VFS_NONE
          dentries(h)%d_sb = FK_VFS_NONE
          dentries(h)%d_child = FK_VFS_NONE
          dentries(h)%d_sib = FK_VFS_NONE
          dentries(h)%d_len = 0_c_int32_t
          do k = 1_c_int32_t, FK_VFS_NAME_MAX + 1_c_int32_t
             dentries(h)%d_name(k) = achar(0)
          end do
          return
       end if
    end do
    h = FK_VFS_NONE
  end function alloc_dentry

  function dentry_ok(h) result(ok)
    implicit none
    integer(c_int32_t), intent(in), value :: h
    logical :: ok

    ok = .false.
    if (h < 1_c_int32_t .or. h > FK_VFS_DENTRIES) return
    ok = dentries(h)%d_flags == FK_VFS_LIVE
  end function dentry_ok

  function inode_ok(h) result(ok)
    implicit none
    integer(c_int32_t), intent(in), value :: h
    logical :: ok

    ok = .false.
    if (h < 1_c_int32_t .or. h > FK_VFS_INODES) return
    ok = inodes(h)%i_flags == FK_VFS_LIVE
  end function inode_ok

  subroutine unlink_child(parent, child)
    implicit none
    integer(c_int32_t), intent(in), value :: parent, child
    integer(c_int32_t) :: c, prev

    prev = FK_VFS_NONE
    c = dentries(parent)%d_child
    do while (c /= FK_VFS_NONE)
       if (c == child) then
          if (prev == FK_VFS_NONE) then
             dentries(parent)%d_child = dentries(c)%d_sib
          else
             dentries(prev)%d_sib = dentries(c)%d_sib
          end if
          dentries(c)%d_sib = FK_VFS_NONE
          return
       end if
       prev = c
       c = dentries(c)%d_sib
    end do
  end subroutine unlink_child

  ! ---- construction ---------------------------------------------------------

  subroutine vfs_reset() bind(c, name="vfs_reset")
    implicit none
    integer(c_int32_t) :: h, k

    do h = 1_c_int32_t, FK_VFS_INODES
       inodes(h)%i_flags = FK_VFS_NONE
       inodes(h)%i_mode = 0_c_int32_t
       inodes(h)%i_nlink = 0_c_int32_t
       inodes(h)%i_ino = 0_c_int64_t
       inodes(h)%i_size = 0_c_int64_t
       inodes(h)%i_priv = 0_c_int64_t
       inodes(h)%i_uid = 0_c_int32_t
       inodes(h)%i_gid = 0_c_int32_t
       inodes(h)%i_sb = FK_VFS_NONE
    end do
    do h = 1_c_int32_t, FK_VFS_DENTRIES
       dentries(h)%d_flags = FK_VFS_NONE
       dentries(h)%d_parent = FK_VFS_NONE
       dentries(h)%d_inode = FK_VFS_NONE
       dentries(h)%d_sb = FK_VFS_NONE
       dentries(h)%d_child = FK_VFS_NONE
       dentries(h)%d_sib = FK_VFS_NONE
       dentries(h)%d_len = 0_c_int32_t
       do k = 1_c_int32_t, FK_VFS_NAME_MAX + 1_c_int32_t
          dentries(h)%d_name(k) = achar(0)
       end do
    end do
    do h = 1_c_int32_t, FK_VFS_FILES
       files(h)%f_state = FK_VFS_NONE
       files(h)%f_pos = 0_c_int64_t
       files(h)%f_dentry = FK_VFS_NONE
       files(h)%f_inode = FK_VFS_NONE
       files(h)%f_flags = 0_c_int32_t
    end do
    do h = 1_c_int32_t, FK_VFS_SUPERS
       supers(h)%s_root = FK_VFS_NONE
       supers(h)%s_magic = 0_c_int64_t
       supers(h)%s_blocksize = 0_c_int64_t
       supers(h)%s_priv = 0_c_int64_t
       supers(h)%s_dev = 0_c_int32_t
       supers(h)%s_ninodes = 0_c_int32_t
       supers(h)%s_flags = FK_VFS_NONE
    end do
    next_ino = 1_c_int64_t
    mounted = FK_VFS_NONE
    filling = .false.
    fills = 0_c_int64_t
  end subroutine vfs_reset

  ! Creates the superblock AND its root, because a superblock with no root is a
  ! state nothing can use and every caller would have to undo.
  function vfs_mount(magic, blocksize, dev) result(sb) bind(c, name="vfs_mount")
    implicit none
    integer(c_int64_t), intent(in), value :: magic, blocksize
    integer(c_int32_t), intent(in), value :: dev
    integer(c_int32_t) :: sb
    integer(c_int32_t) :: d, i

    sb = -FK_E_NOMEM
    do sb = 1_c_int32_t, FK_VFS_SUPERS
       if (supers(sb)%s_flags == FK_VFS_NONE) exit
    end do
    if (sb > FK_VFS_SUPERS) then
       sb = -FK_E_NOMEM
       return
    end if

    d = alloc_dentry()
    if (d == FK_VFS_NONE) then
       sb = -FK_E_NOMEM
       return
    end if
    i = alloc_inode()
    if (i == FK_VFS_NONE) then
       dentries(d)%d_flags = FK_VFS_NONE
       sb = -FK_E_NOMEM
       return
    end if

    supers(sb)%s_flags = FK_VFS_LIVE
    supers(sb)%s_magic = magic
    supers(sb)%s_blocksize = blocksize
    supers(sb)%s_priv = 0_c_int64_t
    supers(sb)%s_dev = dev
    supers(sb)%s_ninodes = 1_c_int32_t
    supers(sb)%s_root = d

    ! IS_ROOT is dcache.h:31, `(x) == (x)->d_parent`, and it is what makes
    ! ".." at the root answer the root rather than walking off the tree.
    dentries(d)%d_parent = d
    dentries(d)%d_inode = i
    dentries(d)%d_sb = sb
    dentries(d)%d_len = 0_c_int32_t

    inodes(i)%i_mode = ior(FK_S_IFDIR, int(o'755', c_int32_t))
    inodes(i)%i_nlink = 2_c_int32_t
    inodes(i)%i_sb = sb
    mounted = sb
  end function vfs_mount

  function vfs_root(sb) result(d) bind(c, name="vfs_root")
    implicit none
    integer(c_int32_t), intent(in), value :: sb
    integer(c_int32_t) :: d

    d = FK_VFS_NONE
    if (sb < 1_c_int32_t .or. sb > FK_VFS_SUPERS) return
    if (supers(sb)%s_flags /= FK_VFS_LIVE) return
    d = supers(sb)%s_root
  end function vfs_root

  function vfs_is_dir(d) result(yes) bind(c, name="vfs_is_dir")
    implicit none
    integer(c_int32_t), intent(in), value :: d
    integer(c_int32_t) :: yes
    integer(c_int32_t) :: i

    yes = 0_c_int32_t
    if (.not. dentry_ok(d)) return
    i = dentries(d)%d_inode
    if (.not. inode_ok(i)) return
    if (iand(inodes(i)%i_mode, FK_S_IFMT) == FK_S_IFDIR) yes = 1_c_int32_t
  end function vfs_is_dir

  function vfs_add(parent, name, len, mode, size) result(d) &
       bind(c, name="vfs_add")
    implicit none
    integer(c_int32_t), intent(in), value :: parent, len, mode
    type(c_ptr), intent(in), value :: name
    integer(c_int64_t), intent(in), value :: size
    integer(c_int32_t) :: d
    integer(c_int8_t), pointer :: nb(:)
    integer(c_int32_t) :: i, k, byte

    d = -FK_E_INVAL
    if (.not. c_associated(name)) return
    if (len < 1_c_int32_t) return
    if (len > FK_VFS_NAME_MAX) then
       d = -FK_E_NAMETOOLONG
       return
    end if
    if (.not. dentry_ok(parent)) return
    if (vfs_is_dir(parent) == 0_c_int32_t) then
       d = -FK_E_NOTDIR
       return
    end if

    call c_f_pointer(name, nb, [int(len, c_size_t)])
    ! A component may contain neither a separator nor a terminator.  Accepting
    ! one would put a name in the tree that no path could ever resolve to.
    do k = 1_c_int32_t, len
       byte = iand(int(nb(k), c_int32_t), 255_c_int32_t)
       if (byte == 0_c_int32_t .or. byte == 47_c_int32_t) return
    end do

    if (vfs_lookup(parent, name, len) /= FK_VFS_NONE) then
       d = -FK_E_EXIST
       return
    end if

    d = alloc_dentry()
    if (d == FK_VFS_NONE) then
       d = -FK_E_NOMEM
       return
    end if
    i = alloc_inode()
    if (i == FK_VFS_NONE) then
       dentries(d)%d_flags = FK_VFS_NONE
       d = -FK_E_NOMEM
       return
    end if

    do k = 1_c_int32_t, len
       dentries(d)%d_name(k) = achar(iand(int(nb(k), c_int32_t), 255_c_int32_t))
    end do
    dentries(d)%d_name(len + 1_c_int32_t) = achar(0)
    dentries(d)%d_len = len
    dentries(d)%d_parent = parent
    dentries(d)%d_inode = i
    dentries(d)%d_sb = dentries(parent)%d_sb

    dentries(d)%d_sib = dentries(parent)%d_child
    dentries(parent)%d_child = d

    inodes(i)%i_mode = mode
    inodes(i)%i_sb = dentries(parent)%d_sb
    ! A directory starts at two links -- its own name and its "." -- and adds
    ! one to its parent for the ".." that now points there.  ext2 and every
    ! other on-disk filesystem count them this way and 6.2 has to agree.
    if (iand(mode, FK_S_IFMT) == FK_S_IFDIR) then
       inodes(i)%i_nlink = 2_c_int32_t
       inodes(dentries(parent)%d_inode)%i_nlink = &
            inodes(dentries(parent)%d_inode)%i_nlink + 1_c_int32_t
       inodes(i)%i_size = 0_c_int64_t
    else
       inodes(i)%i_nlink = 1_c_int32_t
       inodes(i)%i_size = size
    end if
    if (dentries(d)%d_sb /= FK_VFS_NONE) then
       supers(dentries(d)%d_sb)%s_ninodes = &
            supers(dentries(d)%d_sb)%s_ninodes + 1_c_int32_t
    end if
  end function vfs_add

  function vfs_remove(d) result(status) bind(c, name="vfs_remove")
    implicit none
    integer(c_int32_t), intent(in), value :: d
    integer(c_int32_t) :: status
    integer(c_int32_t) :: i, p, k

    status = -FK_E_INVAL
    if (.not. dentry_ok(d)) then
       status = -FK_E_BADF
       return
    end if
    p = dentries(d)%d_parent
    if (p == d) then
       status = -FK_E_BUSY
       return
    end if
    if (dentries(d)%d_child /= FK_VFS_NONE) then
       status = -FK_E_NOTEMPTY
       return
    end if

    i = dentries(d)%d_inode
    call unlink_child(p, d)

    if (inode_ok(i)) then
       if (iand(inodes(i)%i_mode, FK_S_IFMT) == FK_S_IFDIR) then
          inodes(i)%i_nlink = inodes(i)%i_nlink - 2_c_int32_t
          if (inode_ok(dentries(p)%d_inode)) then
             inodes(dentries(p)%d_inode)%i_nlink = &
                  inodes(dentries(p)%d_inode)%i_nlink - 1_c_int32_t
          end if
       else
          inodes(i)%i_nlink = inodes(i)%i_nlink - 1_c_int32_t
       end if
       if (inodes(i)%i_nlink <= 0_c_int32_t) then
          inodes(i)%i_flags = FK_VFS_NONE
          if (inodes(i)%i_sb /= FK_VFS_NONE) then
             supers(inodes(i)%i_sb)%s_ninodes = &
                  supers(inodes(i)%i_sb)%s_ninodes - 1_c_int32_t
          end if
       end if
    end if

    dentries(d)%d_flags = FK_VFS_NONE
    dentries(d)%d_inode = FK_VFS_NONE
    dentries(d)%d_parent = FK_VFS_NONE
    dentries(d)%d_len = 0_c_int32_t
    do k = 1_c_int32_t, FK_VFS_NAME_MAX + 1_c_int32_t
       dentries(d)%d_name(k) = achar(0)
    end do
    status = 0_c_int32_t
  end function vfs_remove

  ! ---- the seam -------------------------------------------------------------

  ! Compares (LENGTH, BYTES), which is what dcache.h's dentry_cmp does and what
  ! tokenisation hands over for free.  strcmp is the wrong tool: a path
  ! component is terminated by a slash or by the end of the path, not by a NUL,
  ! so there is nothing for it to stop at.
  function vfs_lookup(parent, name, len) result(d) bind(c, name="vfs_lookup")
    implicit none
    integer(c_int32_t), intent(in), value :: parent, len
    type(c_ptr), intent(in), value :: name
    integer(c_int32_t) :: d
    integer(c_int8_t), pointer :: nb(:)
    integer(c_int32_t) :: c, k
    logical :: same

    d = FK_VFS_NONE
    if (.not. c_associated(name)) return
    if (len < 1_c_int32_t .or. len > FK_VFS_NAME_MAX) return
    if (.not. dentry_ok(parent)) return
    call c_f_pointer(name, nb, [int(len, c_size_t)])

    c = dentries(parent)%d_child
    do while (c /= FK_VFS_NONE)
       if (dentries(c)%d_len == len) then
          same = .true.
          do k = 1_c_int32_t, len
             if (iachar(dentries(c)%d_name(k)) /= &
                 iand(int(nb(k), c_int32_t), 255_c_int32_t)) then
                same = .false.
                exit
             end if
          end do
          if (same) then
             d = c
             return
          end if
       end if
       c = dentries(c)%d_sib
    end do

    ! THE CACHE MISS, and this is the whole of 6.2's wiring into 6.1.  A name
    ! that is not in the tree is not yet an answer: it is a question for the
    ! filesystem, which reads the parent's directory off the disk and calls
    ! vfs_add.  Only a name that is on neither is FK_VFS_NONE.
    !
    ! A DIRECTORY IS THE ONLY THING WORTH ASKING ABOUT.  Filling from a
    ! non-directory would hand the filesystem a parent whose i_priv is a file's
    ! inode number and let it parse a file's contents as directory entries.
    if (filling) return
    if (vfs_is_dir(parent) == 0_c_int32_t) return
    filling = .true.
    c = fk_vfs_fill(parent, name, len)
    filling = .false.
    fills = fills + 1_c_int64_t
    ! vfs_lookup's contract is "a handle, or FK_VFS_NONE" -- every caller in
    ! this file tests it against FK_VFS_NONE and nothing tests its sign.  A
    ! filler's negative errno is therefore FLATTENED here rather than leaked
    ! into a walk that would treat -ENOENT as a live dentry.
    if (c > FK_VFS_NONE) then
       if (dentry_ok(c)) d = c
    end if
  end function vfs_lookup

  function vfs_fills() result(v) bind(c, name="vfs_fills")
    implicit none
    integer(c_int64_t) :: v

    v = fills
  end function vfs_fills

  ! ---- the walk -------------------------------------------------------------

  function vfs_resolve(path) result(d) bind(c, name="vfs_resolve")
    implicit none
    type(c_ptr), intent(in), value :: path
    integer(c_int32_t) :: d

    d = vfs_resolve_at(vfs_root(mounted), path)
  end function vfs_resolve

  function vfs_resolve_at(base, path) result(d) bind(c, name="vfs_resolve_at")
    implicit none
    integer(c_int32_t), intent(in), value :: base
    type(c_ptr), intent(in), value :: path
    integer(c_int32_t) :: d
    integer(c_int8_t), pointer :: p(:)
    integer(c_size_t) :: n, i, start, clen, addr
    integer(c_int32_t) :: cur, nxt, kind
    logical :: trailing, last
    type(c_ptr) :: comp

    d = -FK_E_INVAL
    if (.not. c_associated(path)) return
    if (.not. dentry_ok(base)) return

    n = fk_strlen(path)
    if (n >= int(FK_VFS_PATH_MAX, c_size_t)) then
       d = -FK_E_NAMETOOLONG
       return
    end if
    if (n == 0_c_size_t) then
       d = -FK_E_NOENT
       return
    end if
    call c_f_pointer(path, p, [n])
    addr = transfer(path, 0_c_size_t)

    i = 1_c_size_t
    cur = base
    if (p(1_c_size_t) == SLASH) then
       cur = vfs_root(dentries(base)%d_sb)
       if (cur == FK_VFS_NONE) return
       ! namei.c:2583-2587: every leading slash, not just the first.
       do
          if (i > n) exit
          if (p(i) /= SLASH) exit
          i = i + 1_c_size_t
       end do
       ! namei.c:2588-2591: "/" alone is the root and the walk is over.
       if (i > n) then
          d = cur
          return
       end if
    end if

    ! A relative path can only be walked from a directory.  Every later
    ! component is guaranteed one by the non-last check at the bottom.
    if (vfs_is_dir(cur) == 0_c_int32_t) then
       d = -FK_E_NOTDIR
       return
    end if

    do
       start = i
       ! namei.c:2548, `while (c && c != '/')` -- one test for both terminators.
       do
          if (i > n) exit
          if (p(i) == SLASH) exit
          i = i + 1_c_size_t
       end do
       clen = i - start
       if (clen > int(FK_VFS_NAME_MAX, c_size_t)) then
          d = -FK_E_NAMETOOLONG
          return
       end if

       ! namei.c:2635-2637.  Whether any slash followed is the trailing-slash
       ! fact, and it is carried rather than discarded.
       trailing = .false.
       do
          if (i > n) exit
          if (p(i) /= SLASH) exit
          i = i + 1_c_size_t
          trailing = .true.
       end do
       last = i > n

       ! namei.c:2607-2627's switch(lastword), without the packed word: a
       ! component is ".", ".." or a name, and the first two never reach a
       ! lookup.  Linux compares a big-endian word against 0x2e / 0x2e2e; at
       ! this scale the length and two bytes say the same thing.
       kind = COMP_NAME
       if (clen == 1_c_size_t) then
          if (p(start) == DOT) kind = COMP_DOT
       else if (clen == 2_c_size_t) then
          if (p(start) == DOT .and. p(start + 1_c_size_t) == DOT) &
               kind = COMP_DOTDOT
       end if

       if (kind == COMP_DOTDOT) then
          ! namei.c:2217-2220: the root's parent is itself, so this stops.
          cur = dentries(cur)%d_parent
       else if (kind == COMP_NAME) then
          comp = transfer(addr + start - 1_c_size_t, c_null_ptr)
          nxt = vfs_lookup(cur, comp, int(clen, c_int32_t))
          if (nxt == FK_VFS_NONE) then
             d = -FK_E_NOENT
             return
          end if
          cur = nxt
       end if
       ! COMP_DOT stays put: namei.c:2258, handle_dots falls to `return NULL`
       ! with the walk state untouched.

       if (last) then
          ! namei.c:2782: the surviving slash is what forces LOOKUP_DIRECTORY.
          if (trailing .and. vfs_is_dir(cur) == 0_c_int32_t) then
             d = -FK_E_NOTDIR
             return
          end if
          exit
       end if
       ! namei.c:2662-2667, and it is checked on the RESULT rather than before
       ! the lookup: /file/.. has to be -ENOTDIR, not the root.
       if (vfs_is_dir(cur) == 0_c_int32_t) then
          d = -FK_E_NOTDIR
          return
       end if
    end do

    d = cur
  end function vfs_resolve_at

  ! ---- open files -----------------------------------------------------------

  function vfs_open(d, flags) result(f) bind(c, name="vfs_open")
    implicit none
    integer(c_int32_t), intent(in), value :: d, flags
    integer(c_int32_t) :: f

    f = -FK_E_BADF
    if (.not. dentry_ok(d)) return
    if (.not. inode_ok(dentries(d)%d_inode)) return
    if (vfs_is_dir(d) == 1_c_int32_t .and. &
        iand(flags, FK_O_ACCMODE) /= FK_O_RDONLY) then
       f = -FK_E_ISDIR
       return
    end if

    do f = 1_c_int32_t, FK_VFS_FILES
       if (files(f)%f_state == FK_VFS_NONE) then
          files(f)%f_state = FK_VFS_LIVE
          files(f)%f_pos = 0_c_int64_t
          files(f)%f_dentry = d
          files(f)%f_inode = dentries(d)%d_inode
          files(f)%f_flags = flags
          return
       end if
    end do
    f = -FK_E_MFILE
  end function vfs_open

  function vfs_close(f) result(status) bind(c, name="vfs_close")
    implicit none
    integer(c_int32_t), intent(in), value :: f
    integer(c_int32_t) :: status

    status = -FK_E_BADF
    if (f < 1_c_int32_t .or. f > FK_VFS_FILES) return
    if (files(f)%f_state /= FK_VFS_LIVE) return
    files(f)%f_state = FK_VFS_NONE
    files(f)%f_dentry = FK_VFS_NONE
    files(f)%f_inode = FK_VFS_NONE
    files(f)%f_pos = 0_c_int64_t
    files(f)%f_flags = 0_c_int32_t
    status = 0_c_int32_t
  end function vfs_close

  ! ---- accessors ------------------------------------------------------------

  function vfs_dentry_parent(d) result(v) bind(c, name="vfs_dentry_parent")
    implicit none
    integer(c_int32_t), intent(in), value :: d
    integer(c_int32_t) :: v

    v = FK_VFS_NONE
    if (dentry_ok(d)) v = dentries(d)%d_parent
  end function vfs_dentry_parent

  function vfs_dentry_inode(d) result(v) bind(c, name="vfs_dentry_inode")
    implicit none
    integer(c_int32_t), intent(in), value :: d
    integer(c_int32_t) :: v

    v = FK_VFS_NONE
    if (dentry_ok(d)) v = dentries(d)%d_inode
  end function vfs_dentry_inode

  function vfs_dentry_child(d) result(v) bind(c, name="vfs_dentry_child")
    implicit none
    integer(c_int32_t), intent(in), value :: d
    integer(c_int32_t) :: v

    v = FK_VFS_NONE
    if (dentry_ok(d)) v = dentries(d)%d_child
  end function vfs_dentry_child

  function vfs_dentry_sib(d) result(v) bind(c, name="vfs_dentry_sib")
    implicit none
    integer(c_int32_t), intent(in), value :: d
    integer(c_int32_t) :: v

    v = FK_VFS_NONE
    if (dentry_ok(d)) v = dentries(d)%d_sib
  end function vfs_dentry_sib

  function vfs_dentry_len(d) result(v) bind(c, name="vfs_dentry_len")
    implicit none
    integer(c_int32_t), intent(in), value :: d
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (dentry_ok(d)) v = dentries(d)%d_len
  end function vfs_dentry_len

  ! The k-th name byte, 1-based.  A c_ptr into the pool would be the obvious
  ! shape and is deliberately not offered: the name is storage this module owns
  ! and a caller holding a pointer to it survives the dentry being freed.
  function vfs_dentry_name(d, k) result(v) bind(c, name="vfs_dentry_name")
    implicit none
    integer(c_int32_t), intent(in), value :: d, k
    integer(c_int32_t) :: v

    v = -1_c_int32_t
    if (.not. dentry_ok(d)) return
    if (k < 1_c_int32_t .or. k > FK_VFS_NAME_MAX + 1_c_int32_t) return
    v = iachar(dentries(d)%d_name(k))
  end function vfs_dentry_name

  function vfs_inode_mode(i) result(v) bind(c, name="vfs_inode_mode")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (inode_ok(i)) v = inodes(i)%i_mode
  end function vfs_inode_mode

  function vfs_inode_size(i) result(v) bind(c, name="vfs_inode_size")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (inode_ok(i)) v = inodes(i)%i_size
  end function vfs_inode_size

  function vfs_inode_ino(i) result(v) bind(c, name="vfs_inode_ino")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (inode_ok(i)) v = inodes(i)%i_ino
  end function vfs_inode_ino

  function vfs_inode_nlink(i) result(v) bind(c, name="vfs_inode_nlink")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (inode_ok(i)) v = inodes(i)%i_nlink
  end function vfs_inode_nlink

  ! i_priv AND s_priv, WRITTEN AT LAST (roadmap 6.2).  6.1 declared both and
  ! read neither, and said so; the filesystem driver is the caller they were
  ! declared for.  i_priv carries the ext2 inode NUMBER and s_priv the block
  ! that group 0's inode table starts at.  Neither meaning is known here, and
  ! that is the point of an opaque field.
  function vfs_inode_priv(i) result(v) bind(c, name="vfs_inode_priv")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (inode_ok(i)) v = inodes(i)%i_priv
  end function vfs_inode_priv

  function vfs_inode_set_priv(i, v) result(status) &
       bind(c, name="vfs_inode_set_priv")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t), intent(in), value :: v
    integer(c_int32_t) :: status

    status = -FK_E_BADF
    if (.not. inode_ok(i)) return
    inodes(i)%i_priv = v
    status = 0_c_int32_t
  end function vfs_inode_set_priv

  ! vfs_add DERIVES mode and size for a directory -- it forces size to 0 and
  ! nlink to 2, because a tree built in memory has no other source for them.
  ! A tree read off a disk does, so this overwrites both with what the on-disk
  ! inode says.  It deliberately does NOT touch i_nlink: vfs_add's link
  ! accounting is what keeps vfs_remove correct, and a disk's count includes
  ! entries this tree has not read.
  function vfs_inode_set_meta(i, mode, size) result(status) &
       bind(c, name="vfs_inode_set_meta")
    implicit none
    integer(c_int32_t), intent(in), value :: i, mode
    integer(c_int64_t), intent(in), value :: size
    integer(c_int32_t) :: status

    status = -FK_E_BADF
    if (.not. inode_ok(i)) return
    status = -FK_E_INVAL
    ! The file TYPE is fixed when the dentry is created, because vfs_add's
    ! nlink accounting and every is-a-directory test downstream already
    ! branched on it.  Changing it here would leave the tree describing a
    ! directory whose parent was never credited with its "..".
    if (iand(mode, FK_S_IFMT) /= iand(inodes(i)%i_mode, FK_S_IFMT)) return
    if (size < 0_c_int64_t) return
    inodes(i)%i_mode = mode
    inodes(i)%i_size = size
    status = 0_c_int32_t
  end function vfs_inode_set_meta

  function vfs_super_priv(sb) result(v) bind(c, name="vfs_super_priv")
    implicit none
    integer(c_int32_t), intent(in), value :: sb
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (sb < 1_c_int32_t .or. sb > FK_VFS_SUPERS) return
    if (supers(sb)%s_flags /= FK_VFS_LIVE) return
    v = supers(sb)%s_priv
  end function vfs_super_priv

  function vfs_super_set_priv(sb, v) result(status) &
       bind(c, name="vfs_super_set_priv")
    implicit none
    integer(c_int32_t), intent(in), value :: sb
    integer(c_int64_t), intent(in), value :: v
    integer(c_int32_t) :: status

    status = -FK_E_BADF
    if (sb < 1_c_int32_t .or. sb > FK_VFS_SUPERS) return
    if (supers(sb)%s_flags /= FK_VFS_LIVE) return
    supers(sb)%s_priv = v
    status = 0_c_int32_t
  end function vfs_super_set_priv

  function vfs_file_inode(f) result(v) bind(c, name="vfs_file_inode")
    implicit none
    integer(c_int32_t), intent(in), value :: f
    integer(c_int32_t) :: v

    v = FK_VFS_NONE
    if (f < 1_c_int32_t .or. f > FK_VFS_FILES) return
    if (files(f)%f_state /= FK_VFS_LIVE) return
    v = files(f)%f_inode
  end function vfs_file_inode

  function vfs_file_pos(f) result(v) bind(c, name="vfs_file_pos")
    implicit none
    integer(c_int32_t), intent(in), value :: f
    integer(c_int64_t) :: v

    v = -1_c_int64_t
    if (f < 1_c_int32_t .or. f > FK_VFS_FILES) return
    if (files(f)%f_state /= FK_VFS_LIVE) return
    v = files(f)%f_pos
  end function vfs_file_pos

  function vfs_super_magic(sb) result(v) bind(c, name="vfs_super_magic")
    implicit none
    integer(c_int32_t), intent(in), value :: sb
    integer(c_int64_t) :: v

    v = 0_c_int64_t
    if (sb < 1_c_int32_t .or. sb > FK_VFS_SUPERS) return
    if (supers(sb)%s_flags /= FK_VFS_LIVE) return
    v = supers(sb)%s_magic
  end function vfs_super_magic

  function vfs_dentries_used() result(v) bind(c, name="vfs_dentries_used")
    implicit none
    integer(c_int32_t) :: v
    integer(c_int32_t) :: h

    v = 0_c_int32_t
    do h = 1_c_int32_t, FK_VFS_DENTRIES
       if (dentries(h)%d_flags == FK_VFS_LIVE) v = v + 1_c_int32_t
    end do
  end function vfs_dentries_used

  function vfs_inodes_used() result(v) bind(c, name="vfs_inodes_used")
    implicit none
    integer(c_int32_t) :: v
    integer(c_int32_t) :: h

    v = 0_c_int32_t
    do h = 1_c_int32_t, FK_VFS_INODES
       if (inodes(h)%i_flags == FK_VFS_LIVE) v = v + 1_c_int32_t
    end do
  end function vfs_inodes_used

  function vfs_files_used() result(v) bind(c, name="vfs_files_used")
    implicit none
    integer(c_int32_t) :: v
    integer(c_int32_t) :: h

    v = 0_c_int32_t
    do h = 1_c_int32_t, FK_VFS_FILES
       if (files(h)%f_state == FK_VFS_LIVE) v = v + 1_c_int32_t
    end do
  end function vfs_files_used

end module fk_vfs_m
