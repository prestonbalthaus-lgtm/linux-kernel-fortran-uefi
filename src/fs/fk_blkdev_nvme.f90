! SPDX-License-Identifier: GPL-2.0
! The kernel's half of the block seam: fk_blk_submit over the NVMe controller.
! Roadmap 6.2.
!
! THIS FILE IS NOT IN THE HOST SUITE'S LINK, and that is the arrangement rather
! than an oversight.  src/fs/fk_blkdev.f90 declares fk_blk_submit and does not
! define it; this defines it for the kernel and tests/fs/test_ext2.c defines it
! over a `mke2fs` image.  One seam, resolved by the linker, exactly as
! fk_readl/fk_writel are resolved by boot/io.S on one side and a C shim on the
! other.  It is also why the ext2 parser the host suite exercises is byte for
! byte the parser that runs on the metal.
!
! THE COUNTER IS WAITED ON BY DELTA AND NOT BY VALUE, and this is the whole
! reason the file is more than a one-line forward to nvme_read.  Roadmap 5.3's
! bring-up issues ONE read and then spins until fk_nvme_irq_completions is
! greater than zero.  That test is correct exactly once.  The second read finds
! the counter already standing at 1, returns immediately, and hands the
! filesystem whatever was in the buffer from the FIRST read -- a wrong answer,
! silently, with every status code saying success.  A snapshot taken before the
! doorbell is the only thing that distinguishes "my completion arrived" from
! "somebody's completion arrived at some point".
module fk_blkdev_nvme_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t
  use fk_nvme_m, only: nvme_read, nvme_isr_owns, irq_completions, FK_NVME_OK
  implicit none
  private

  public :: FK_BLKNVME_OK, FK_BLKNVME_E_NODEV, FK_BLKNVME_E_CMD, &
            FK_BLKNVME_E_TIMEOUT
  public :: blkdev_nvme_attach, blkdev_nvme_detach, blkdev_nvme_timeouts

  integer(c_int32_t), parameter :: FK_BLKNVME_OK = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_BLKNVME_E_NODEV = -1_c_int32_t
  integer(c_int32_t), parameter :: FK_BLKNVME_E_CMD = -2_c_int32_t
  integer(c_int32_t), parameter :: FK_BLKNVME_E_TIMEOUT = -3_c_int32_t

  ! A BUDGET, AND IT IS 100x WHAT 5.3's BRING-UP USES, for a reason that was
  ! measured rather than guessed.  At 2,000,000 -- 5.3's number, inherited
  ! without thinking -- the boot gate failed roughly one run in ten, ALWAYS on
  ! a host that was running back-to-back VMs, and always as an ext2 mount that
  ! could not read its own superblock.  5.3 issues ONE read on an idle machine
  ! and that budget is ample for it; a filesystem issues fifteen while a
  ! contended host is scheduling the vCPU elsewhere, and an empty spin measures
  ! host CPU time rather than device time.
  !
  ! It is still a BOUND and not a forever loop: a controller that has stopped
  ! answering has to fail the mount, so that the console says why instead of
  ! the boot wedging before it can.  The count of expiries is published, so a
  ! future failure of this kind arrives as "the device timed out N times" and
  ! not as an unexplained parse error.
  integer(c_int32_t), parameter :: FK_BLKNVME_SPINS = 200000000_c_int32_t

  integer(c_int32_t), save :: nsid = 0_c_int32_t
  integer(c_int32_t), save :: lba_per_sector = 1_c_int32_t
  integer(c_int64_t), save :: timeouts = 0_c_int64_t

contains

  ! `lba_bytes` is the namespace's OWN formatted block size, and it is passed in
  ! rather than assumed: fk_blkdev.f90 speaks in 512-byte sectors because that
  ! is what ext2's arithmetic is expressed in, and a namespace formatted at
  ! 4096 would need four of them per device block.  Anything but 512 is refused
  ! here rather than silently divided, because this milestone has never seen
  ! one and an untested conversion is worse than a refusal.
  function blkdev_nvme_attach(ns, lba_bytes) result(status) &
       bind(c, name="blkdev_nvme_attach")
    implicit none
    integer(c_int32_t), intent(in), value :: ns, lba_bytes
    integer(c_int32_t) :: status

    nsid = 0_c_int32_t
    timeouts = 0_c_int64_t
    status = FK_BLKNVME_E_NODEV
    if (ns < 1_c_int32_t) return
    if (lba_bytes /= 512_c_int32_t) return
    nsid = ns
    lba_per_sector = 1_c_int32_t
    status = FK_BLKNVME_OK
  end function blkdev_nvme_attach

  subroutine blkdev_nvme_detach() bind(c, name="blkdev_nvme_detach")
    implicit none

    nsid = 0_c_int32_t
  end subroutine blkdev_nvme_detach

  function blkdev_nvme_timeouts() result(v) &
       bind(c, name="blkdev_nvme_timeouts")
    implicit none
    integer(c_int64_t) :: v

    v = timeouts
  end function blkdev_nvme_timeouts

  function fk_blk_submit(lba, sectors, phys) result(status) &
       bind(c, name="fk_blk_submit")
    implicit none
    integer(c_int64_t), intent(in), value :: lba, phys
    integer(c_int32_t), intent(in), value :: sectors
    integer(c_int32_t) :: status, i
    integer(c_int64_t) :: before

    status = FK_BLKNVME_E_NODEV
    if (nsid == 0_c_int32_t) return
    if (sectors < 1_c_int32_t .or. phys == 0_c_int64_t) return

    ! ONE PAGE, PAGE-ALIGNED, AND THAT IS THE CONTROLLER'S CONSTRAINT AND NOT
    ! A TIDINESS RULE.  fk_nvme.f90's submit() writes PRP1 and leaves PRP2
    ! ZERO, and its comment says why: nothing this driver submits crosses a
    ! page boundary, and a transfer that did would need a PRP LIST rather than
    ! a second entry.  A buffer that straddles two pages would have its tail
    ! written to whatever physical page happens to follow the first -- which is
    ! silent memory corruption, not an I/O error.  Refused here, where the
    ! address is known, rather than trusted from the caller.
    status = FK_BLKNVME_E_CMD
    if (iand(phys, int(z'FFF', c_int64_t)) /= 0_c_int64_t) return
    if (sectors * 512_c_int32_t > 4096_c_int32_t) return

    ! THE SNAPSHOT, TAKEN BEFORE THE DOORBELL.  Read once into a local: the
    ! comparison below must be against the value as it was, and re-reading the
    ! volatile inside the test would compare it against itself.
    before = irq_completions

    status = nvme_read(nsid, lba, sectors * lba_per_sector, phys)
    if (status /= FK_NVME_OK) then
       status = FK_BLKNVME_E_CMD
       return
    end if

    ! With the handler not armed, nvme_read has already waited and reaped; the
    ! counter is not the mechanism and waiting for it would never return.
    if (nvme_isr_owns() == 0_c_int32_t) then
       status = FK_BLKNVME_OK
       return
    end if

    ! THE VOLATILE VARIABLE, NOT THE ACCESSOR OVER IT.  fk_nvme.f90's own
    ! header records what happens otherwise: gfortran treats a cross-module
    ! getter as side-effect-free, hoists the single load out of the loop, and
    ! spins on a value that can never change.  Measured there, inherited here.
    do i = 1_c_int32_t, FK_BLKNVME_SPINS
       if (irq_completions > before) then
          status = FK_BLKNVME_OK
          return
       end if
    end do

    timeouts = timeouts + 1_c_int64_t
    status = FK_BLKNVME_E_TIMEOUT
  end function fk_blk_submit

end module fk_blkdev_nvme_m
