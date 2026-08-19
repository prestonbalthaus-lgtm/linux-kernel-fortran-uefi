! SPDX-License-Identifier: GPL-2.0
! The block layer: one buffer, one block at a time.  Roadmap 6.2.
!
! THIS MODULE EXISTS SO THAT src/fs/fk_ext2.f90 NEVER HOLDS AN ADDRESS.  The
! filesystem asks for an LBA and then reads bytes at offsets; where those bytes
! live, and how they got there, is entirely this file's business.  That is what
! lets the SAME Fortran parse a real disk under QEMU and a `mke2fs` image on the
! host, which is the whole point -- the image is built by an independent
! implementation, so a misconception shared between a hand-written formatter and
! a hand-written parser has nowhere to hide.
!
! fk_blk_submit IS THE SEAM, and it is resolved by the LINKER rather than by a
! table of function pointers.  src/fs/fk_blkdev_nvme.f90 defines it for the
! kernel and tests/fs/test_ext2.c defines it for the host suite; neither is a
! caller of the other and neither knows the other exists.  It is the identical
! arrangement fk_readl/fk_writel already have with boot/io.S and the driver
! tests, and it is why there is no ops table here either.
!
! THE BUFFER IS READ THROUGH fk_readl.  In the kernel it is DRAM a bus master
! wrote by DMA, and src/drivers/storage/fk_nvme.f90's nvme_sector_word says why
! that must not be an ordinary load: gfortran is entitled to narrow, hoist or
! cache a load the compiler believes nothing else can write.
module fk_blkdev_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t
  implicit none
  private

  public :: FK_BLK_OK, FK_BLK_E_NOBUF, FK_BLK_E_RANGE, FK_BLK_E_IO
  public :: FK_BLK_SECTOR_BYTES
  public :: blk_attach, blk_detach, blk_read, blk_capacity, blk_reads
  public :: blk_u8, blk_le16, blk_le32, blk_le64

  integer(c_int32_t), parameter :: FK_BLK_OK = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_BLK_E_NOBUF = -1_c_int32_t
  integer(c_int32_t), parameter :: FK_BLK_E_RANGE = -2_c_int32_t
  integer(c_int32_t), parameter :: FK_BLK_E_IO = -3_c_int32_t

  ! 512 IS THE LOGICAL BLOCK, NOT AN ASSUMPTION ABOUT THE DEVICE.  The NVMe
  ! namespace reports its own formatted size and fk_blkdev_nvme.f90 refuses to
  ! attach a device that does not agree with this; ext2's own block is a
  ! multiple of it and is decoded from the superblock.
  integer(c_int32_t), parameter :: FK_BLK_SECTOR_BYTES = 512_c_int32_t

  integer(c_int64_t), save :: buf_virt = 0_c_int64_t
  integer(c_int64_t), save :: buf_phys = 0_c_int64_t
  integer(c_int32_t), save :: buf_bytes = 0_c_int32_t
  integer(c_int32_t), save :: buf_valid = 0_c_int32_t
  integer(c_int64_t), save :: capacity = 0_c_int64_t
  ! Published so a gate can assert that the filesystem did the number of reads
  ! it claims.  "The directory was read off the disk" is not provable from the
  ! answer alone -- a driver that invented the entry from a cache returns the
  ! same handle -- and this counter is what separates the two.
  integer(c_int64_t), save :: reads = 0_c_int64_t

  interface
    function fk_readl(addr) result(v) bind(c, name="fk_readl")
      import :: c_int32_t, c_int64_t
      implicit none
      integer(c_int64_t), intent(in), value :: addr
      integer(c_int32_t)                    :: v
    end function fk_readl

    ! Moves `sectors` 512-byte sectors starting at `lba` into the buffer whose
    ! PHYSICAL base is `phys`, and returns 0 on success.  Physical, because the
    ! kernel's implementation hands it to a device that masters the bus and has
    ! no idea what a page table is.
    function fk_blk_submit(lba, sectors, phys) result(status) &
         bind(c, name="fk_blk_submit")
      import :: c_int32_t, c_int64_t
      implicit none
      integer(c_int64_t), intent(in), value :: lba, phys
      integer(c_int32_t), intent(in), value :: sectors
      integer(c_int32_t)                    :: status
    end function fk_blk_submit
  end interface

contains

  subroutine blk_attach(virt, phys, bytes, sectors) bind(c, name="blk_attach")
    implicit none
    integer(c_int64_t), intent(in), value :: virt, phys, sectors
    integer(c_int32_t), intent(in), value :: bytes

    buf_virt = virt
    buf_phys = phys
    buf_bytes = bytes
    buf_valid = 0_c_int32_t
    capacity = sectors
    reads = 0_c_int64_t
  end subroutine blk_attach

  subroutine blk_detach() bind(c, name="blk_detach")
    implicit none

    buf_virt = 0_c_int64_t
    buf_phys = 0_c_int64_t
    buf_bytes = 0_c_int32_t
    buf_valid = 0_c_int32_t
    capacity = 0_c_int64_t
    reads = 0_c_int64_t
  end subroutine blk_detach

  ! buf_valid IS SET TO ZERO BEFORE THE READ AND TO THE BYTE COUNT AFTER IT,
  ! never left at its previous value.  A failed read that leaves the old
  ! contents addressable is how a filesystem parses the block it wanted out of
  ! the block it got, and the accessors below refuse an offset above buf_valid.
  function blk_read(lba, sectors) result(status) bind(c, name="blk_read")
    implicit none
    integer(c_int64_t), intent(in), value :: lba
    integer(c_int32_t), intent(in), value :: sectors
    integer(c_int32_t) :: status

    buf_valid = 0_c_int32_t
    status = FK_BLK_E_NOBUF
    if (buf_virt == 0_c_int64_t .or. buf_phys == 0_c_int64_t) return

    status = FK_BLK_E_RANGE
    if (sectors < 1_c_int32_t) return
    if (sectors > buf_bytes / FK_BLK_SECTOR_BYTES) return
    if (lba < 0_c_int64_t) return
    ! A read that runs off the end of the namespace is refused HERE rather than
    ! by the controller, because a controller answers it with an error status
    ! this layer would then have to distinguish from a real I/O failure.
    if (capacity > 0_c_int64_t .and. &
        lba + int(sectors, c_int64_t) > capacity) return

    status = fk_blk_submit(lba, sectors, buf_phys)
    if (status /= FK_BLK_OK) then
       status = FK_BLK_E_IO
       return
    end if
    buf_valid = sectors * FK_BLK_SECTOR_BYTES
    reads = reads + 1_c_int64_t
    status = FK_BLK_OK
  end function blk_read

  function blk_capacity() result(v) bind(c, name="blk_capacity")
    implicit none
    integer(c_int64_t) :: v

    v = capacity
  end function blk_capacity

  function blk_reads() result(v) bind(c, name="blk_reads")
    implicit none
    integer(c_int64_t) :: v

    v = reads
  end function blk_reads

  ! -1 FOR AN OUT-OF-RANGE OFFSET, not 0, and the distinction is load bearing:
  ! a zero byte is a legal thing to find on a disk and every caller below
  ! branches on the value it reads.  A reader that cannot tell "the byte is
  ! zero" from "there is no such byte" walks off the end of a short block.
  function blk_u8(off) result(v) bind(c, name="blk_u8")
    implicit none
    integer(c_int32_t), intent(in), value :: off
    integer(c_int32_t) :: v

    v = -1_c_int32_t
    if (off < 0_c_int32_t .or. off >= buf_valid) return
    v = ibits(fk_readl(buf_virt + int((off / 4_c_int32_t) * 4_c_int32_t, &
                                      c_int64_t)), &
              mod(off, 4_c_int32_t) * 8_c_int32_t, 8_c_int32_t)
  end function blk_u8

  function blk_le16(off) result(v) bind(c, name="blk_le16")
    implicit none
    integer(c_int32_t), intent(in), value :: off
    integer(c_int32_t) :: v
    integer(c_int32_t) :: lo, hi

    v = -1_c_int32_t
    lo = blk_u8(off)
    hi = blk_u8(off + 1_c_int32_t)
    if (lo < 0_c_int32_t .or. hi < 0_c_int32_t) return
    v = ior(lo, shiftl(hi, 8))
  end function blk_le16

  ! RETURNED AS A 64-BIT VALUE, zero-extended, because every 32-bit field this
  ! driver reads is an UNSIGNED count -- a block number, an inode count, a byte
  ! size -- and Fortran's integer(c_int32_t) is signed.  A 3 GiB filesystem's
  ! s_blocks_count read into a signed 32-bit lands negative, and every bounds
  ! check against it then passes.  That is the exact defect class roadmap 4.1
  ! found in the MADT walk.
  function blk_le32(off) result(v) bind(c, name="blk_le32")
    implicit none
    integer(c_int32_t), intent(in), value :: off
    integer(c_int64_t) :: v
    integer(c_int32_t) :: lo, hi

    v = -1_c_int64_t
    lo = blk_le16(off)
    hi = blk_le16(off + 2_c_int32_t)
    if (lo < 0_c_int32_t .or. hi < 0_c_int32_t) return
    v = ior(int(lo, c_int64_t), shiftl(int(hi, c_int64_t), 16))
  end function blk_le32

  function blk_le64(off) result(v) bind(c, name="blk_le64")
    implicit none
    integer(c_int32_t), intent(in), value :: off
    integer(c_int64_t) :: v
    integer(c_int64_t) :: lo, hi

    v = -1_c_int64_t
    lo = blk_le32(off)
    hi = blk_le32(off + 4_c_int32_t)
    if (lo < 0_c_int64_t .or. hi < 0_c_int64_t) return
    v = ior(lo, shiftl(hi, 32))
  end function blk_le64

end module fk_blkdev_m
