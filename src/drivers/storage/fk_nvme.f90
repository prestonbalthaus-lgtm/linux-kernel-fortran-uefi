! SPDX-License-Identifier: GPL-2.0
! The NVMe controller: reset, admin queues, an I/O queue pair, and sector 0
! (roadmap 5.3).
!
! TWO KINDS OF MEMORY, the same split fk_xhci_m's header describes.  The
! REGISTERS are device memory behind BAR0, reached with fk_readl/fk_writel a
! whole dword at a time.  The QUEUES are ordinary RAM that a bus master reads
! and writes, so they go through the same accessors -- not because they are
! registers but because a bus master's writes are exactly what the compiler
! must not be allowed to narrow, reorder or cache across a doorbell.
!
! Every address the controller is GIVEN is PHYSICAL; every address this module
! dereferences is VIRTUAL.
!
! There is no 64-bit accessor in boot/io.S, so CAP, ASQ and ACQ are two dwords,
! low half first.  ASQ and ACQ are only ever written while the controller is
! DISABLED, so the intermediate state is not visible to it.
!
! THE PHASE TAG IS THE WHOLE COMPLETION PROTOCOL.  A completion queue entry
! belongs to the controller until its phase bit differs from the consumer's
! expectation; the consumer flips its expectation every time it wraps.  A
! zeroed queue reads as phase 0, so the first lap expects 1.
module fk_nvme_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t
  use fk_nvme_types_m, only: FK_NVME_REG_CAP_OFF, FK_NVME_REG_VS_OFF, &
                             FK_NVME_REG_CC_OFF, FK_NVME_REG_CSTS_OFF, &
                             FK_NVME_REG_AQA_OFF, FK_NVME_REG_ASQ_OFF, &
                             FK_NVME_REG_ACQ_OFF, FK_NVME_REG_INTMC_OFF, &
                             FK_NVME_DB_BASE, FK_NVME_DB_STRIDE, &
                             FK_NVME_DB_PAIR, FK_NVME_DB_SQ, FK_NVME_DB_CQ, &
                             FK_NVME_CAP_MQES_POS, FK_NVME_CAP_MQES_LEN, &
                             FK_NVME_CAP_DSTRD_POS, FK_NVME_CAP_DSTRD_LEN, &
                             FK_NVME_CAP_TO_POS, FK_NVME_CAP_TO_LEN, &
                             FK_NVME_CAP_MPSMIN_POS, FK_NVME_CAP_MPSMIN_LEN, &
                             FK_NVME_CC_EN_BIT, FK_NVME_CC_CSS_POS, &
                             FK_NVME_CC_CSS_LEN, FK_NVME_CC_MPS_POS, &
                             FK_NVME_CC_MPS_LEN, FK_NVME_CC_IOSQES_POS, &
                             FK_NVME_CC_IOSQES_LEN, FK_NVME_CC_IOCQES_POS, &
                             FK_NVME_CC_IOCQES_LEN, FK_NVME_CC_CSS_NVM, &
                             FK_NVME_CC_IOSQES_NVM, FK_NVME_CC_IOCQES_NVM, &
                             FK_NVME_CSTS_RDY_BIT, FK_NVME_CSTS_CFS_BIT, &
                             FK_NVME_AQA_ASQS_POS, FK_NVME_AQA_ASQS_LEN, &
                             FK_NVME_AQA_ACQS_POS, FK_NVME_AQA_ACQS_LEN, &
                             FK_NVME_SQE_BYTES, FK_NVME_CQE_BYTES, &
                             FK_NVME_QUEUE_ALIGN, &
                             FK_NVME_SQE_CDW0_OPC_POS, &
                             FK_NVME_SQE_CDW0_OPC_LEN, &
                             FK_NVME_SQE_CDW0_CID_POS, &
                             FK_NVME_SQE_CDW0_CID_LEN, &
                             FK_NVME_CQE_STATUS_P_BIT, &
                             FK_NVME_CQE_STATUS_SC_POS, &
                             FK_NVME_CQE_STATUS_SC_LEN, &
                             FK_NVME_CQE_STATUS_SCT_POS, &
                             FK_NVME_CQE_STATUS_SCT_LEN, &
                             FK_NVME_ADMIN_CREATE_SQ, FK_NVME_ADMIN_CREATE_CQ, &
                             FK_NVME_ADMIN_IDENTIFY, FK_NVME_IO_READ, &
                             FK_NVME_ID_CNS_NS, FK_NVME_ID_CNS_CTRL, &
                             FK_NVME_Q_PHYS_CONTIG_BIT, &
                             FK_NVME_CQ_IRQ_ENABLED_BIT, &
                             FK_NVME_CQID_POS, FK_NVME_CQID_LEN, &
                             FK_NVME_QSIZE_POS, FK_NVME_QSIZE_LEN, &
                             FK_NVME_QFLAGS_POS, FK_NVME_QFLAGS_LEN, &
                             FK_NVME_IV_POS, FK_NVME_IV_LEN, &
                             FK_NVME_SQ_CQID_POS, FK_NVME_SQ_CQID_LEN, &
                             FK_NVME_RW_NLB_POS, FK_NVME_RW_NLB_LEN, &
                             FK_NVME_IDNS_NSZE_OFF, FK_NVME_IDNS_NLBAF_OFF, &
                             FK_NVME_IDNS_FLBAS_OFF, FK_NVME_IDNS_LBAF_OFF, &
                             FK_NVME_LBAF_BYTES, FK_NVME_LBAF_DS_OFF, &
                             FK_NVME_FLBAS_IDX_POS, FK_NVME_FLBAS_IDX_LEN
  implicit none
  private

  public :: FK_NVME_OK, FK_NVME_E_NOBASE, FK_NVME_E_DISABLE, FK_NVME_E_ENABLE, &
            FK_NVME_E_QUEUE, FK_NVME_E_CMD, FK_NVME_E_STATUS, FK_NVME_E_LBA, &
            FK_NVME_SPIN_MAX
  public :: nvme_attach, nvme_cap, nvme_version, nvme_cc, nvme_csts, &
            nvme_mqes, nvme_dstrd, nvme_timeout, nvme_mpsmin, nvme_ready
  public :: nvme_disable, nvme_admin_queues, nvme_enable
  public :: nvme_identify, nvme_create_cq, nvme_create_sq, nvme_read
  public :: nvme_isr, nvme_owner_isr, nvme_irq_completions, irq_completions
  public :: nvme_last_status, nvme_last_cid, nvme_aqa, nvme_asq, nvme_acq
  public :: nvme_ns_size, nvme_lba_bytes, nvme_admin_head, nvme_admin_phase
  public :: nvme_ns_decode, nvme_sector_word, nvme_set_sector_buf

  integer(c_int32_t), parameter :: FK_NVME_OK        = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_E_NOBASE  = -1_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_E_DISABLE = -2_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_E_ENABLE  = -3_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_E_QUEUE   = -4_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_E_CMD     = -5_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_E_STATUS  = -6_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_E_LBA     = -7_c_int32_t

  ! No timer is usable in this path, so every wait is a bounded spin.  CAP.TO
  ! says 7.5 seconds on this controller; a bound that is reached is a
  ! diagnostic, never a hang.
  integer(c_int32_t), parameter :: FK_NVME_SPIN_MAX = 4000000_c_int32_t

  ! TWO ENTRIES, and it is the whole reason the phase tag is testable.  A
  ! sixty-four deep queue never wraps in a bring-up that issues four commands,
  ! so a driver with inverted wrap logic would pass every gate that could be
  ! built on it.  Two is the specification's minimum and it makes the ordinary
  ! path wrap the admin queue twice.
  integer(c_int32_t), parameter :: FK_NVME_ADMIN_ENTRIES = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_IO_ENTRIES = 2_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_ADMIN_QID = 0_c_int32_t
  integer(c_int32_t), parameter :: FK_NVME_IO_QID = 1_c_int32_t

  integer(c_int64_t), save :: reg_base = 0_c_int64_t
  integer(c_int32_t), save :: db_shift = 0_c_int32_t

  ! One queue pair's state.  Index 1 is admin, 2 is I/O.
  integer(c_int32_t), parameter :: NQ = 2_c_int32_t
  integer(c_int64_t), save :: sq_virt(NQ) = 0_c_int64_t
  integer(c_int64_t), save :: sq_phys(NQ) = 0_c_int64_t
  integer(c_int64_t), save :: cq_virt(NQ) = 0_c_int64_t
  integer(c_int64_t), save :: cq_phys(NQ) = 0_c_int64_t
  integer(c_int32_t), save :: q_depth(NQ) = 0_c_int32_t
  integer(c_int32_t), save :: sq_tail(NQ) = 0_c_int32_t
  integer(c_int32_t), save :: cq_head(NQ) = 0_c_int32_t
  integer(c_int32_t), save :: cq_phase(NQ) = 1_c_int32_t
  integer(c_int32_t), save :: qid_of(NQ) = 0_c_int32_t

  integer(c_int32_t), save :: next_cid = 1_c_int32_t
  integer(c_int32_t), save :: last_status = 0_c_int32_t
  integer(c_int32_t), save :: last_cid = 0_c_int32_t
  integer(c_int64_t), save :: ns_size = 0_c_int64_t
  integer(c_int32_t), save :: lba_bytes = 0_c_int32_t
  ! VOLATILE and bind(c), for the reason fk_pit_m and fk_console_m both state:
  ! a cross-module accessor over an ordinary save variable is side-effect-free
  ! as far as gfortran is concerned, so a caller spinning on it gets ONE load
  ! hoisted out of the loop and waits forever on a stale value.  Measured here,
  ! not inherited: the read completed, the interrupt arrived, the counter moved
  ! -- and the bring-up spun out anyway.  Readers outside the program want it
  ! too; qmp-sentinel finds it by name.
  integer(c_int64_t), volatile, bind(c, name="fk_nvme_irq_completions") :: &
       irq_completions = 0_c_int64_t
  logical,            save :: isr_owns = .false.
  integer(c_int64_t), save :: sector_virt = 0_c_int64_t

  interface
    function fk_readl(addr) result(v) bind(c, name="fk_readl")
      import :: c_int32_t, c_int64_t
      implicit none
      integer(c_int64_t), intent(in), value :: addr
      integer(c_int32_t)                    :: v
    end function fk_readl

    subroutine fk_writel(addr, v) bind(c, name="fk_writel")
      import :: c_int32_t, c_int64_t
      implicit none
      integer(c_int64_t), intent(in), value :: addr
      integer(c_int32_t), intent(in), value :: v
    end subroutine fk_writel
  end interface

contains

  function reg32(off) result(v)
    implicit none
    integer(c_int32_t), intent(in), value :: off
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (reg_base == 0_c_int64_t) return
    v = fk_readl(reg_base + int(off, c_int64_t))
  end function reg32

  subroutine wr32(off, v)
    implicit none
    integer(c_int32_t), intent(in), value :: off, v

    if (reg_base == 0_c_int64_t) return
    call fk_writel(reg_base + int(off, c_int64_t), v)
  end subroutine wr32

  subroutine wr64(off, v)
    implicit none
    integer(c_int32_t), intent(in), value :: off
    integer(c_int64_t), intent(in), value :: v

    call wr32(off, int(iand(v, int(z'FFFFFFFF', c_int64_t)), c_int32_t))
    call wr32(off + 4_c_int32_t, int(shiftr(v, 32), c_int32_t))
  end subroutine wr64

  function rd64(off) result(v)
    implicit none
    integer(c_int32_t), intent(in), value :: off
    integer(c_int64_t) :: v

    v = ior(iand(int(reg32(off), c_int64_t), int(z'FFFFFFFF', c_int64_t)), &
            shiftl(iand(int(reg32(off + 4_c_int32_t), c_int64_t), &
                        int(z'FFFFFFFF', c_int64_t)), 32))
  end function rd64

  function nvme_attach(virt) result(status) bind(c, name="nvme_attach")
    implicit none
    integer(c_int64_t), intent(in), value :: virt
    integer(c_int32_t) :: status

    status = FK_NVME_E_NOBASE
    reg_base = 0_c_int64_t
    if (virt == 0_c_int64_t) return
    reg_base = virt
    ! CAP reading as all ones is a BAR that decodes nothing, which is what an
    ! unmapped window or a device with memory-space decode off looks like.
    if (nvme_cap() == -1_c_int64_t) then
       reg_base = 0_c_int64_t
       return
    end if
    ! DSTRD is a SHIFT, not a stride: doorbell bytes = 4 << DSTRD.
    db_shift = ibits(int(shiftr(nvme_cap(), FK_NVME_CAP_DSTRD_POS), c_int32_t), &
                     0_c_int32_t, FK_NVME_CAP_DSTRD_LEN)
    status = FK_NVME_OK
  end function nvme_attach

  function nvme_cap() result(v) bind(c, name="nvme_cap")
    implicit none
    integer(c_int64_t) :: v

    v = rd64(FK_NVME_REG_CAP_OFF)
  end function nvme_cap

  function nvme_version() result(v) bind(c, name="nvme_version")
    implicit none
    integer(c_int32_t) :: v

    v = reg32(FK_NVME_REG_VS_OFF)
  end function nvme_version

  function nvme_cc() result(v) bind(c, name="nvme_cc")
    implicit none
    integer(c_int32_t) :: v

    v = reg32(FK_NVME_REG_CC_OFF)
  end function nvme_cc

  function nvme_csts() result(v) bind(c, name="nvme_csts")
    implicit none
    integer(c_int32_t) :: v

    v = reg32(FK_NVME_REG_CSTS_OFF)
  end function nvme_csts

  function nvme_aqa() result(v) bind(c, name="nvme_aqa")
    implicit none
    integer(c_int32_t) :: v

    v = reg32(FK_NVME_REG_AQA_OFF)
  end function nvme_aqa

  function nvme_asq() result(v) bind(c, name="nvme_asq")
    implicit none
    integer(c_int64_t) :: v

    v = rd64(FK_NVME_REG_ASQ_OFF)
  end function nvme_asq

  function nvme_acq() result(v) bind(c, name="nvme_acq")
    implicit none
    integer(c_int64_t) :: v

    v = rd64(FK_NVME_REG_ACQ_OFF)
  end function nvme_acq

  ! MQES is a 0-based count: usable entries are MQES + 1.
  function nvme_mqes() result(v) bind(c, name="nvme_mqes")
    implicit none
    integer(c_int32_t) :: v

    v = ibits(int(nvme_cap(), c_int32_t), FK_NVME_CAP_MQES_POS, &
              FK_NVME_CAP_MQES_LEN) + 1_c_int32_t
  end function nvme_mqes

  function nvme_dstrd() result(v) bind(c, name="nvme_dstrd")
    implicit none
    integer(c_int32_t) :: v

    v = db_shift
  end function nvme_dstrd

  ! CAP.TO is in units of 500 ms.
  function nvme_timeout() result(v) bind(c, name="nvme_timeout")
    implicit none
    integer(c_int32_t) :: v

    v = ibits(int(shiftr(nvme_cap(), FK_NVME_CAP_TO_POS), c_int32_t), &
              0_c_int32_t, FK_NVME_CAP_TO_LEN)
  end function nvme_timeout

  ! MPSMIN is a shift: the smallest page the controller supports is
  ! 2**(12 + MPSMIN) bytes, and CC.MPS is expressed in the same units.
  function nvme_mpsmin() result(v) bind(c, name="nvme_mpsmin")
    implicit none
    integer(c_int32_t) :: v

    v = ibits(int(shiftr(nvme_cap(), FK_NVME_CAP_MPSMIN_POS), c_int32_t), &
              0_c_int32_t, FK_NVME_CAP_MPSMIN_LEN)
  end function nvme_mpsmin

  function nvme_ready() result(v) bind(c, name="nvme_ready")
    implicit none
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    if (btest(nvme_csts(), FK_NVME_CSTS_RDY_BIT)) v = 1_c_int32_t
  end function nvme_ready

  ! CC.EN cleared, then RDY polled to 0.  On a controller firmware never
  ! enabled this returns immediately and proves nothing; it is still done,
  ! because the machine that HAS been touched by firmware is the one where
  ! skipping it corrupts memory the PMM is about to hand out.
  function nvme_disable() result(status) bind(c, name="nvme_disable")
    implicit none
    integer(c_int32_t) :: status, i, v

    status = FK_NVME_E_NOBASE
    if (reg_base == 0_c_int64_t) return

    v = ibclr(nvme_cc(), FK_NVME_CC_EN_BIT)
    call wr32(FK_NVME_REG_CC_OFF, v)

    status = FK_NVME_E_DISABLE
    do i = 1_c_int32_t, FK_NVME_SPIN_MAX
       if (nvme_ready() == 0_c_int32_t) then
          status = FK_NVME_OK
          return
       end if
    end do
  end function nvme_disable

  ! AQA, ASQ and ACQ are written while the controller is DISABLED, which is
  ! what makes a 64-bit register written as two dwords safe here.
  !
  ! AQA'S TWO FIELDS ARE ZERO-BASED.  A queue of n entries puts n-1 in each,
  ! and putting n asks the controller for one entry more than the page holds.
  function nvme_admin_queues(sq_v, sq_p, cq_v, cq_p) result(status) &
       bind(c, name="nvme_admin_queues")
    implicit none
    integer(c_int64_t), intent(in), value :: sq_v, sq_p, cq_v, cq_p
    integer(c_int32_t) :: status, v

    status = FK_NVME_E_QUEUE
    if (sq_v == 0_c_int64_t .or. cq_v == 0_c_int64_t) return
    if (iand(sq_p, int(FK_NVME_QUEUE_ALIGN - 1_c_int32_t, c_int64_t)) /= &
        0_c_int64_t) return
    if (iand(cq_p, int(FK_NVME_QUEUE_ALIGN - 1_c_int32_t, c_int64_t)) /= &
        0_c_int64_t) return
    if (reg_base == 0_c_int64_t) then
       status = FK_NVME_E_NOBASE
       return
    end if

    call queue_init(1_c_int32_t, FK_NVME_ADMIN_QID, sq_v, sq_p, cq_v, cq_p, &
                    FK_NVME_ADMIN_ENTRIES)

    v = 0_c_int32_t
    call mvbits(FK_NVME_ADMIN_ENTRIES - 1_c_int32_t, 0_c_int32_t, &
                FK_NVME_AQA_ASQS_LEN, v, FK_NVME_AQA_ASQS_POS)
    call mvbits(FK_NVME_ADMIN_ENTRIES - 1_c_int32_t, 0_c_int32_t, &
                FK_NVME_AQA_ACQS_LEN, v, FK_NVME_AQA_ACQS_POS)
    call wr32(FK_NVME_REG_AQA_OFF, v)
    call wr64(FK_NVME_REG_ASQ_OFF, sq_p)
    call wr64(FK_NVME_REG_ACQ_OFF, cq_p)
    status = FK_NVME_OK
  end function nvme_admin_queues

  ! CC IS COMPOSED IN FULL, not read-modify-written, and IOSQES/IOCQES are the
  ! reason.  They are the log2 of the entry sizes, and a controller enabled
  ! with them at zero accepts the enable and then rejects Create I/O SQ with an
  ! invalid queue size -- two commands away from the mistake.
  function nvme_enable() result(status) bind(c, name="nvme_enable")
    implicit none
    integer(c_int32_t) :: status, i, v

    status = FK_NVME_E_NOBASE
    if (reg_base == 0_c_int64_t) return

    v = 0_c_int32_t
    call mvbits(FK_NVME_CC_CSS_NVM, 0_c_int32_t, FK_NVME_CC_CSS_LEN, v, &
                FK_NVME_CC_CSS_POS)
    ! CC.MPS is in the same units as CAP.MPSMIN and the host page is 4 KiB,
    ! which is what MPSMIN 0 means; a controller wanting more would need the
    ! PMM to hand out bigger frames, so it is refused rather than fudged.
    call mvbits(0_c_int32_t, 0_c_int32_t, FK_NVME_CC_MPS_LEN, v, &
                FK_NVME_CC_MPS_POS)
    call mvbits(FK_NVME_CC_IOSQES_NVM, 0_c_int32_t, FK_NVME_CC_IOSQES_LEN, v, &
                FK_NVME_CC_IOSQES_POS)
    call mvbits(FK_NVME_CC_IOCQES_NVM, 0_c_int32_t, FK_NVME_CC_IOCQES_LEN, v, &
                FK_NVME_CC_IOCQES_POS)
    v = ibset(v, FK_NVME_CC_EN_BIT)
    call wr32(FK_NVME_REG_CC_OFF, v)

    status = FK_NVME_E_ENABLE
    do i = 1_c_int32_t, FK_NVME_SPIN_MAX
       if (btest(nvme_csts(), FK_NVME_CSTS_CFS_BIT)) return
       if (nvme_ready() == 1_c_int32_t) then
          status = FK_NVME_OK
          return
       end if
    end do
  end function nvme_enable

  subroutine queue_init(q, qid, sv, sp, cv, cp, depth)
    implicit none
    integer(c_int32_t), intent(in), value :: q, qid, depth
    integer(c_int64_t), intent(in), value :: sv, sp, cv, cp
    integer(c_int32_t) :: i

    sq_virt(q) = sv
    sq_phys(q) = sp
    cq_virt(q) = cv
    cq_phys(q) = cp
    q_depth(q) = depth
    sq_tail(q) = 0_c_int32_t
    cq_head(q) = 0_c_int32_t
    ! A zeroed completion queue reads as phase 0, so the first lap expects 1.
    cq_phase(q) = 1_c_int32_t
    qid_of(q) = qid

    do i = 0_c_int32_t, depth * FK_NVME_SQE_BYTES / 4_c_int32_t - 1_c_int32_t
       call fk_writel(sv + int(i * 4_c_int32_t, c_int64_t), 0_c_int32_t)
    end do
    do i = 0_c_int32_t, depth * FK_NVME_CQE_BYTES / 4_c_int32_t - 1_c_int32_t
       call fk_writel(cv + int(i * 4_c_int32_t, c_int64_t), 0_c_int32_t)
    end do
  end subroutine queue_init

  function db_addr(qid, which) result(a)
    implicit none
    integer(c_int32_t), intent(in), value :: qid, which
    integer(c_int64_t) :: a

    a = reg_base + int(FK_NVME_DB_BASE, c_int64_t) + &
        int(shiftl((FK_NVME_DB_PAIR * qid + which) * FK_NVME_DB_STRIDE, &
                   db_shift), c_int64_t)
  end function db_addr

  ! One 64-byte submission queue entry, written dword by dword with the
  ! doorbell after it.  The command's own dwords are laid down before the tail
  ! is published, which is what stops the controller fetching a half-written
  ! command; fk_writel is opaque, so the compiler cannot move the doorbell up.
  ! BY VALUE, all of them, and it is not a micro-optimisation.  A by-reference
  ! dummy lives in memory, and gfortran narrows a load when only some of its
  ! bits are used -- opcode feeds an 8-bit mvbits field, so the load became a
  ! movzbl.  Harmless here, because the temporary is stack and not a device
  ! register, but tools/mmiocheck.sh cannot tell those apart and refusing the
  ! object is exactly its job.  In a register there is no load to narrow.
  function submit(q, opcode, nsid, prp1, prp2, cdw10, cdw11, cdw12) &
       result(cid)
    implicit none
    integer(c_int32_t), intent(in), value :: q, opcode, nsid, cdw10, cdw11, &
                                             cdw12
    integer(c_int64_t), intent(in), value :: prp1, prp2
    integer(c_int32_t) :: cid, i
    integer(c_int64_t) :: e

    cid = 0_c_int32_t
    if (sq_virt(q) == 0_c_int64_t) return

    cid = next_cid
    next_cid = next_cid + 1_c_int32_t
    if (next_cid > int(z'FFFF', c_int32_t)) next_cid = 1_c_int32_t

    e = sq_virt(q) + int(sq_tail(q) * FK_NVME_SQE_BYTES, c_int64_t)
    do i = 0_c_int32_t, FK_NVME_SQE_BYTES / 4_c_int32_t - 1_c_int32_t
       call fk_writel(e + int(i * 4_c_int32_t, c_int64_t), 0_c_int32_t)
    end do

    call fk_writel(e, dword0(opcode, cid))
    call fk_writel(e + 4_c_int64_t, nsid)
    ! PRP1 at 0x18 and PRP2 at 0x20.  Both are page-aligned buffers here and
    ! PRP2 is zero: nothing this driver submits crosses a page boundary, and a
    ! transfer that did would need a PRP list rather than a second entry.
    call fk_writel(e + int(z'18', c_int64_t), &
                   int(iand(prp1, int(z'FFFFFFFF', c_int64_t)), c_int32_t))
    call fk_writel(e + int(z'1C', c_int64_t), &
                   int(shiftr(prp1, 32), c_int32_t))
    call fk_writel(e + int(z'20', c_int64_t), &
                   int(iand(prp2, int(z'FFFFFFFF', c_int64_t)), c_int32_t))
    call fk_writel(e + int(z'24', c_int64_t), &
                   int(shiftr(prp2, 32), c_int32_t))
    call fk_writel(e + int(z'28', c_int64_t), cdw10)
    call fk_writel(e + int(z'2C', c_int64_t), cdw11)
    call fk_writel(e + int(z'30', c_int64_t), cdw12)

    sq_tail(q) = sq_tail(q) + 1_c_int32_t
    if (sq_tail(q) >= q_depth(q)) sq_tail(q) = 0_c_int32_t
    call fk_writel(db_addr(qid_of(q), FK_NVME_DB_SQ), sq_tail(q))
  end function submit

  function dword0(opcode, cid) result(v)
    implicit none
    integer(c_int32_t), intent(in), value :: opcode, cid
    integer(c_int32_t) :: v

    v = 0_c_int32_t
    call mvbits(opcode, 0_c_int32_t, FK_NVME_SQE_CDW0_OPC_LEN, v, &
                FK_NVME_SQE_CDW0_OPC_POS)
    call mvbits(cid, 0_c_int32_t, FK_NVME_SQE_CDW0_CID_LEN, v, &
                FK_NVME_SQE_CDW0_CID_POS)
  end function dword0

  ! One completion, or E_CMD.  THE PHASE TAG IS THE OWNERSHIP TEST: an entry
  ! whose phase differs from the consumer's expectation has not been written by
  ! the controller yet, and on the first lap of a zeroed queue that is
  ! indistinguishable from an empty queue -- correctly, because it is one.
  function reap(q) result(status)
    implicit none
    integer(c_int32_t), intent(in), value :: q
    integer(c_int32_t) :: status, dw3, p
    integer(c_int64_t) :: e

    status = FK_NVME_E_CMD
    if (cq_virt(q) == 0_c_int64_t) return

    e = cq_virt(q) + int(cq_head(q) * FK_NVME_CQE_BYTES, c_int64_t)
    dw3 = fk_readl(e + 12_c_int64_t)
    p = 0_c_int32_t
    if (btest(dw3, FK_NVME_CQE_STATUS_P_BIT + 16_c_int32_t)) p = 1_c_int32_t
    if (p /= cq_phase(q)) return

    ! Status and command id live in the top dword: cid in 15:0, status in
    ! 31:16, and the phase bit is bit 0 OF THE STATUS FIELD, which is why the
    ! test above is at bit 16 of the dword.
    last_cid = iand(dw3, int(z'FFFF', c_int32_t))
    last_status = iand(shiftr(dw3, 16), int(z'FFFF', c_int32_t))

    cq_head(q) = cq_head(q) + 1_c_int32_t
    if (cq_head(q) >= q_depth(q)) then
       cq_head(q) = 0_c_int32_t
       ! THE FLIP, and it belongs with the wrap and nowhere else.  The
       ! controller flips its own phase every lap; a consumer that does not
       ! flip with it sees the second lap as an empty queue forever.
       cq_phase(q) = 1_c_int32_t - cq_phase(q)
    end if
    call fk_writel(db_addr(qid_of(q), FK_NVME_DB_CQ), cq_head(q))

    status = FK_NVME_OK
  end function reap

  ! Spin for the completion of ONE command id.  Anything else consumed on the
  ! way is a completion for a command nobody is waiting on, which cannot happen
  ! in this strictly serialised bring-up but costs one comparison to survive.
  function wait_for(q, cid) result(status)
    implicit none
    integer(c_int32_t), intent(in), value :: q, cid
    integer(c_int32_t) :: status, i

    status = FK_NVME_E_CMD
    if (cid == 0_c_int32_t) return
    do i = 1_c_int32_t, FK_NVME_SPIN_MAX
       if (reap(q) /= FK_NVME_OK) cycle
       if (last_cid /= cid) cycle
       ! SC in 8:1 and SCT in 11:9 of the status field; both zero is success.
       if (ibits(last_status, FK_NVME_CQE_STATUS_SC_POS, &
                 FK_NVME_CQE_STATUS_SC_LEN) == 0_c_int32_t .and. &
           ibits(last_status, FK_NVME_CQE_STATUS_SCT_POS, &
                 FK_NVME_CQE_STATUS_SCT_LEN) == 0_c_int32_t) then
          status = FK_NVME_OK
       else
          status = FK_NVME_E_STATUS
       end if
       return
    end do
  end function wait_for

  function nvme_identify(cns, nsid, buf_phys) result(status) &
       bind(c, name="nvme_identify")
    implicit none
    integer(c_int32_t), intent(in), value :: cns, nsid
    integer(c_int64_t), intent(in), value :: buf_phys
    integer(c_int32_t) :: status, cid

    status = FK_NVME_E_QUEUE
    if (buf_phys == 0_c_int64_t) return
    cid = submit(1_c_int32_t, int(FK_NVME_ADMIN_IDENTIFY, c_int32_t), nsid, &
                 buf_phys, 0_c_int64_t, cns, 0_c_int32_t, 0_c_int32_t)
    status = wait_for(1_c_int32_t, cid)
  end function nvme_identify

  ! QSIZE IS ZERO-BASED in both Create commands, like AQA.  IEN and the
  ! interrupt vector go in CDW11 beside the flags; PC is mandatory here because
  ! CAP.CQR is set on every controller this has met.
  function nvme_create_cq(cq_v, cq_p, qid, entries, vector) result(status) &
       bind(c, name="nvme_create_cq")
    implicit none
    integer(c_int64_t), intent(in), value :: cq_v, cq_p
    integer(c_int32_t), intent(in), value :: qid, entries, vector
    integer(c_int32_t) :: status, cid, cdw10, cdw11

    status = FK_NVME_E_QUEUE
    if (cq_v == 0_c_int64_t) return
    if (iand(cq_p, int(FK_NVME_QUEUE_ALIGN - 1_c_int32_t, c_int64_t)) /= &
        0_c_int64_t) return

    cdw10 = 0_c_int32_t
    call mvbits(qid, 0_c_int32_t, FK_NVME_CQID_LEN, cdw10, FK_NVME_CQID_POS)
    call mvbits(entries - 1_c_int32_t, 0_c_int32_t, FK_NVME_QSIZE_LEN, cdw10, &
                FK_NVME_QSIZE_POS)
    cdw11 = 0_c_int32_t
    call mvbits(ior(ibset(0_c_int32_t, FK_NVME_Q_PHYS_CONTIG_BIT), &
                    ibset(0_c_int32_t, FK_NVME_CQ_IRQ_ENABLED_BIT)), &
                0_c_int32_t, FK_NVME_QFLAGS_LEN, cdw11, FK_NVME_QFLAGS_POS)
    call mvbits(vector, 0_c_int32_t, FK_NVME_IV_LEN, cdw11, FK_NVME_IV_POS)

    cid = submit(1_c_int32_t, int(FK_NVME_ADMIN_CREATE_CQ, c_int32_t), &
                 0_c_int32_t, cq_p, 0_c_int64_t, cdw10, cdw11, 0_c_int32_t)
    status = wait_for(1_c_int32_t, cid)
  end function nvme_create_cq

  function nvme_create_sq(sq_v, sq_p, cq_v, cq_p, qid, entries) result(status) &
       bind(c, name="nvme_create_sq")
    implicit none
    integer(c_int64_t), intent(in), value :: sq_v, sq_p, cq_v, cq_p
    integer(c_int32_t), intent(in), value :: qid, entries
    integer(c_int32_t) :: status, cid, cdw10, cdw11

    status = FK_NVME_E_QUEUE
    if (sq_v == 0_c_int64_t) return
    if (iand(sq_p, int(FK_NVME_QUEUE_ALIGN - 1_c_int32_t, c_int64_t)) /= &
        0_c_int64_t) return

    cdw10 = 0_c_int32_t
    call mvbits(qid, 0_c_int32_t, FK_NVME_CQID_LEN, cdw10, FK_NVME_CQID_POS)
    call mvbits(entries - 1_c_int32_t, 0_c_int32_t, FK_NVME_QSIZE_LEN, cdw10, &
                FK_NVME_QSIZE_POS)
    cdw11 = 0_c_int32_t
    call mvbits(ibset(0_c_int32_t, FK_NVME_Q_PHYS_CONTIG_BIT), 0_c_int32_t, &
                FK_NVME_QFLAGS_LEN, cdw11, FK_NVME_QFLAGS_POS)
    call mvbits(qid, 0_c_int32_t, FK_NVME_SQ_CQID_LEN, cdw11, &
                FK_NVME_SQ_CQID_POS)

    cid = submit(1_c_int32_t, int(FK_NVME_ADMIN_CREATE_SQ, c_int32_t), &
                 0_c_int32_t, sq_p, 0_c_int64_t, cdw10, cdw11, 0_c_int32_t)
    status = wait_for(1_c_int32_t, cid)
    if (status /= FK_NVME_OK) return
    call queue_init(2_c_int32_t, qid, sq_v, sq_p, cq_v, cq_p, entries)
  end function nvme_create_sq

  ! The namespace's block size, decoded from Identify Namespace.  FLBAS's low
  ! nibble indexes lbaf[], each entry four bytes, and DS is an EXPONENT: the
  ! block is 2**DS bytes.  NLBAF bounds the index, so a controller reporting a
  ! format it does not have is refused rather than read past.
  function nvme_ns_decode(buf_virt) result(status) &
       bind(c, name="nvme_ns_decode")
    implicit none
    integer(c_int64_t), intent(in), value :: buf_virt
    integer(c_int32_t) :: status, flbas, nlbaf, idx, ds
    integer(c_int64_t) :: e

    status = FK_NVME_E_LBA
    ns_size = 0_c_int64_t
    lba_bytes = 0_c_int32_t
    if (buf_virt == 0_c_int64_t) return

    ns_size = ior(iand(int(fk_readl(buf_virt + &
                           int(FK_NVME_IDNS_NSZE_OFF, c_int64_t)), c_int64_t), &
                       int(z'FFFFFFFF', c_int64_t)), &
                  shiftl(iand(int(fk_readl(buf_virt + &
                              int(FK_NVME_IDNS_NSZE_OFF + 4_c_int32_t, &
                                  c_int64_t)), c_int64_t), &
                              int(z'FFFFFFFF', c_int64_t)), 32))

    flbas = byte_at(buf_virt, FK_NVME_IDNS_FLBAS_OFF)
    nlbaf = byte_at(buf_virt, FK_NVME_IDNS_NLBAF_OFF)
    idx = ibits(flbas, FK_NVME_FLBAS_IDX_POS, FK_NVME_FLBAS_IDX_LEN)
    if (idx > nlbaf) return

    e = buf_virt + int(FK_NVME_IDNS_LBAF_OFF + idx * FK_NVME_LBAF_BYTES, &
                       c_int64_t)
    ds = byte_at(e, FK_NVME_LBAF_DS_OFF)
    if (ds < 9_c_int32_t .or. ds > 16_c_int32_t) return
    lba_bytes = shiftl(1_c_int32_t, ds)
    status = FK_NVME_OK
  end function nvme_ns_decode

  function byte_at(base, off) result(v)
    implicit none
    integer(c_int64_t), intent(in), value :: base
    integer(c_int32_t), intent(in), value :: off
    integer(c_int32_t) :: v

    v = ibits(fk_readl(base + int((off / 4_c_int32_t) * 4_c_int32_t, &
                                  c_int64_t)), &
              mod(off, 4_c_int32_t) * 8_c_int32_t, 8_c_int32_t)
  end function byte_at

  ! NLB IS ZERO-BASED: blocks-1 goes in CDW12, so one block is 0.  A driver
  ! that writes the count reads one block too many, which is invisible on a
  ! disk whose next sector is zeros.
  function nvme_read(nsid, slba, blocks, buf_phys) result(status) &
       bind(c, name="nvme_read")
    implicit none
    integer(c_int32_t), intent(in), value :: nsid, blocks
    integer(c_int64_t), intent(in), value :: slba, buf_phys
    integer(c_int32_t) :: status, cid, cdw12

    status = FK_NVME_E_QUEUE
    if (buf_phys == 0_c_int64_t .or. blocks < 1_c_int32_t) return
    if (sq_virt(2) == 0_c_int64_t) return

    cdw12 = 0_c_int32_t
    call mvbits(blocks - 1_c_int32_t, 0_c_int32_t, FK_NVME_RW_NLB_LEN, cdw12, &
                FK_NVME_RW_NLB_POS)

    cid = submit(2_c_int32_t, int(FK_NVME_IO_READ, c_int32_t), nsid, &
                 buf_phys, 0_c_int64_t, &
                 int(iand(slba, int(z'FFFFFFFF', c_int64_t)), c_int32_t), &
                 int(shiftr(slba, 32), c_int32_t), cdw12)
    if (isr_owns) then
       status = FK_NVME_OK
       return
    end if
    status = wait_for(2_c_int32_t, cid)
  end function nvme_read

  ! Arms the handler as the I/O queue's consumer, and unmasks the controller's
  ! interrupts.  The ORDER is 5.2's lesson verbatim: the flag goes up before
  ! the mask comes down, or a completion arriving in the gap is taken by a
  ! handler that does not own the queue.
  function nvme_owner_isr() result(status) bind(c, name="nvme_owner_isr")
    implicit none
    integer(c_int32_t) :: status

    status = FK_NVME_E_NOBASE
    if (reg_base == 0_c_int64_t) return
    isr_owns = .true.
    ! INTMC is write-1-to-CLEAR-a-mask: writing a set bit unmasks that vector.
    call wr32(FK_NVME_REG_INTMC_OFF, 1_c_int32_t)
    status = FK_NVME_OK
  end function nvme_owner_isr

  ! Called from the shared MSI-X handler.  The vector is shared with the xHCI,
  ! so this returns 0 for an interrupt that was not the controller's -- which
  ! is exactly what an empty completion queue looks like, and needs no other
  ! test.  The count it keeps is the only NVMe-specific claim the shared vector
  ! permits: it moves only when a completion was consumed HERE.
  function nvme_isr() result(n) bind(c, name="nvme_isr")
    implicit none
    integer(c_int32_t) :: n, i

    n = 0_c_int32_t
    if (.not. isr_owns) return
    if (cq_virt(2) == 0_c_int64_t) return

    do i = 1_c_int32_t, 64_c_int32_t
       if (reap(2_c_int32_t) /= FK_NVME_OK) exit
       n = n + 1_c_int32_t
       irq_completions = irq_completions + 1_c_int64_t
    end do
  end function nvme_isr

  function nvme_irq_completions() result(v) &
       bind(c, name="nvme_irq_completions")
    implicit none
    integer(c_int64_t) :: v

    v = irq_completions
  end function nvme_irq_completions

  ! The sector buffer is DRAM the controller wrote by DMA, so it is read back
  ! through fk_readl for the reason the queues are: a bus master's writes are
  ! what the compiler must not narrow or cache.
  ! Records the landing zone AND ZEROES IT, and the zeroing is an assertion
  ! rather than hygiene.  A one-block read must write 512 bytes and not 1024;
  ! comparing only the 512 that were asked for cannot see a write PAST them,
  ! which is how a zero-based NLB written as a count escapes.  The bytes above
  ! the sector are left as a guard region for the gate to check, exactly as
  ! HARNESS-VALIDATION-PHASE2.md's mutation 4 forced for the framebuffer.
  subroutine nvme_set_sector_buf(virt, bytes) &
       bind(c, name="nvme_set_sector_buf")
    implicit none
    integer(c_int64_t), intent(in), value :: virt
    integer(c_int32_t), intent(in), value :: bytes
    integer(c_int32_t) :: i

    sector_virt = virt
    if (virt == 0_c_int64_t) return
    do i = 0_c_int32_t, bytes / 4_c_int32_t - 1_c_int32_t
       call fk_writel(virt + int(i * 4_c_int32_t, c_int64_t), 0_c_int32_t)
    end do
  end subroutine nvme_set_sector_buf

  function nvme_sector_word(i) result(v) bind(c, name="nvme_sector_word")
    implicit none
    integer(c_int32_t), intent(in), value :: i
    integer(c_int64_t) :: v, a

    v = 0_c_int64_t
    if (sector_virt == 0_c_int64_t) return
    a = sector_virt + int(i, c_int64_t) * 8_c_int64_t
    v = ior(iand(int(fk_readl(a), c_int64_t), int(z'FFFFFFFF', c_int64_t)), &
            shiftl(iand(int(fk_readl(a + 4_c_int64_t), c_int64_t), &
                        int(z'FFFFFFFF', c_int64_t)), 32))
  end function nvme_sector_word

  function nvme_last_status() result(v) bind(c, name="nvme_last_status")
    implicit none
    integer(c_int32_t) :: v

    v = last_status
  end function nvme_last_status

  function nvme_last_cid() result(v) bind(c, name="nvme_last_cid")
    implicit none
    integer(c_int32_t) :: v

    v = last_cid
  end function nvme_last_cid

  function nvme_ns_size() result(v) bind(c, name="nvme_ns_size")
    implicit none
    integer(c_int64_t) :: v

    v = ns_size
  end function nvme_ns_size

  function nvme_lba_bytes() result(v) bind(c, name="nvme_lba_bytes")
    implicit none
    integer(c_int32_t) :: v

    v = lba_bytes
  end function nvme_lba_bytes

  ! Published so the gate can see that the admin queue WRAPPED: with two
  ! entries and four commands the head returns to 0 twice and the phase flips
  ! with it, which is the one thing a deeper queue would hide.
  function nvme_admin_head() result(v) bind(c, name="nvme_admin_head")
    implicit none
    integer(c_int32_t) :: v

    v = cq_head(1)
  end function nvme_admin_head

  function nvme_admin_phase() result(v) bind(c, name="nvme_admin_phase")
    implicit none
    integer(c_int32_t) :: v

    v = cq_phase(1)
  end function nvme_admin_phase

end module fk_nvme_m
