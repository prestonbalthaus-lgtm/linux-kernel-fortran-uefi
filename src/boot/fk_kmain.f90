! SPDX-License-Identifier: GPL-2.0
! Fortran entry point for the Multiboot2 boot path.  boot/boot.S calls
! kernel_main once the CPU is in 64-bit long mode; it records the loader handoff
! in fk_boot_sentinel, brings COM1 up, installs the GDT, TSS and IDT, pacifies
! the legacy 8259s, brings the PMM up against the loader's memory map and puts
! it through pmm_verify below, hands off to the higher half, opens IRQ0 and
! sets IF -- and then, in the shipped image, keeps running.
!
! FK_FAULT_MODE decides how the boot ENDS, and as of roadmap 3.2b its default
! is not a fault at all: the CPU parks in fk_cpu_idle with interrupts on and
! goes on servicing the timer.  Every other value raises one deliberate
! exception so the catcher has something to catch, which is what every boot
! this project has taken did before 3.2b.
! tools/qemu-boot-test.sh reads the sentinel back over QMP and greps the
! captured COM1 log.
module fk_kmain_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_int64_t, c_char, &
                                         c_null_char, c_funloc, c_ptr, &
                                         c_f_pointer, c_loc
  use fk_serial_m, only: FK_SERIAL_COM1, serial_init, serial_print_string, &
                         serial_print_hex
  use fk_panic_m,  only: panic_code
  use fk_acpi_m,   only: FK_ACPI_OK, FK_ACPI_ROOT_XSDT, acpi_set_window, &
                         acpi_set_limit, acpi_init, acpi_root_kind, &
                         acpi_root_phys, acpi_revision, acpi_table_count, &
                         acpi_find, acpi_table_length
  use fk_mcfg_m,   only: FK_MCFG_OK, mcfg_parse, mcfg_count, mcfg_base, &
                         mcfg_segment, mcfg_bus_start, mcfg_bus_end, mcfg_bytes
  use fk_pcie_m,   only: FK_PCIE_NOT_FOUND, pcie_set_window, pcie_scan, &
                         pcie_count, pcie_seen, pcie_overflowed, &
                         pcie_bus, pcie_device, pcie_function, &
                         pcie_vendor, pcie_devid, pcie_class, pcie_subclass, &
                         pcie_progif, pcie_find_xhci, pcie_find_nvme, &
                         pcie_cmd_enable, pcie_cmd_disable, pcie_command, &
                         pcie_msix_at, pcie_msix_count, &
                         pcie_msix_bir, pcie_msix_offset, pcie_bar64, &
                         pcie_msix_entry_set, pcie_msix_entry_read, &
                         pcie_msix_enable, pcie_msix_ctrl, pcie_intx_disable, &
                         FK_PCI_MSIX_E_ADDR_LO, FK_PCI_MSIX_E_DATA, &
                         FK_PCI_MSIX_E_VCTRL, FK_PCIE_OK
  use fk_xhci_m,   only: FK_XHCI_OK, xhci_attach, xhci_reset, &
                         xhci_config_slots, xhci_set_dcbaap, &
                         xhci_cmd_ring_init, xhci_event_ring_init, &
                         xhci_intr_enable, xhci_run, xhci_cmd_noop, &
                         xhci_doorbell, xhci_cmd_wait, xhci_event_type, &
                         xhci_event_comp, xhci_event_ptr, xhci_caplength, &
                         xhci_version, xhci_max_slots, xhci_max_scratchpads, &
                         xhci_usbsts, xhci_crcr, xhci_erdp, xhci_dcbaap, &
                         xhci_halted, &
                         xhci_page_size
  use fk_usb_kbd_m, only: usbkbd_bringup, fk_usbkbd_state
  use fk_nvme_m,    only: FK_NVME_OK, nvme_attach, nvme_disable, &
                          nvme_admin_queues, nvme_enable, nvme_identify, &
                          nvme_ns_decode, nvme_create_cq, nvme_create_sq, &
                          nvme_read, nvme_owner_isr, nvme_irq_completions, &
                          nvme_cap, nvme_version, nvme_cc, nvme_csts, &
                          nvme_aqa, nvme_asq, nvme_acq, nvme_mqes, &
                          nvme_dstrd, nvme_ns_size, nvme_lba_bytes, &
                          nvme_last_status, nvme_admin_head, nvme_admin_phase, &
                          nvme_sector_word, nvme_set_sector_buf, &
                          fk_nvme_irq_completions => irq_completions, &
                          FK_NVME_E_CMD, FK_NVME_E_NOBASE, FK_NVME_E_QUEUE
  use fk_nvme_types_m, only: FK_NVME_ID_CNS_CTRL, FK_NVME_ID_CNS_NS
  use fk_pcie_types_m, only: FK_PCI_CMD_MEMORY_BIT, FK_PCI_CMD_MASTER_BIT, &
                             FK_PCI_CMD_INTX_DISABLE_BIT, &
                             FK_PCI_MSIX_CTRL_ENABLE_BIT, &
                             FK_PCI_MSIX_CTRL_MASKALL_BIT
  use fk_madt_m,   only: FK_MADT_OK, madt_parse, madt_lapic_addr, &
                         madt_pcat_compat, madt_cpu_count, madt_cpu_enabled, &
                         madt_cpu_apic_id, madt_ioapic_count, &
                         madt_ioapic_addr, madt_ioapic_gsi_base, &
                         madt_iso_count, madt_iso_src, madt_iso_gsi, &
                         madt_iso_flags, &
                         madt_gsi_for_irq, madt_nmi_count, madt_nmi_lint, &
                         madt_skipped
  use fk_lapic_m,  only: lapic_init, lapic_msr_base, lapic_msr_enabled, &
                         lapic_lint0_extint, lapic_lint1_nmi, &
                         LVT_DM_EXTINT, LVT_DM_NMI, &
                         lapic_id, lapic_version, lapic_svr, &
                         lapic_lvt_lint0, lapic_lvt_lint1, &
                         lapic_msi_addr, lapic_msi_data
  use fk_gdt_m,    only: gdt_init
  use fk_tss_m,    only: tss_init
  use fk_idt_m,    only: idt_init, fk_irq_spurious, idt_set_panic_colors, &
                         idt_set_eoi_lapic, fk_lapic_spurious, &
                         FK_VECTOR_SPURIOUS, FK_VECTOR_MSI, fk_msi_count
  use fk_ioapic_m, only: FK_IOAPIC_OK, FK_IOAPIC_POL_HIGH, FK_IOAPIC_POL_LOW, &
                         FK_IOAPIC_TRIG_EDGE, FK_IOAPIC_TRIG_LEVEL, &
                         ioapic_set_window, ioapic_id, ioapic_version, &
                         ioapic_max_redir, ioapic_route, ioapic_mask, &
                         ioapic_read_lo, ioapic_read_hi
  use fk_pic_m,    only: pic_remap, pic_unmask, pic_imr, pic_disable, &
                         FK_PIC1_VECTOR
  use fk_pit_m,    only: FK_PIT_HZ, FK_PIT_IRQ, pit_init, fk_tick_count, &
                         fk_first_rip, fk_first_rflags
  use fk_pmm_m,    only: FK_PMM_FRONT_EFI, pmm_front_end, &
                         FK_PMM_PAGE_SIZE, FK_PMM_OK, FK_PMM_E_UNALIGNED, &
                         FK_PMM_E_LOCKED, FK_PMM_E_DOUBLE_FREE, &
                         pmm_init, pmm_alloc_page, pmm_free_page, &
                         pmm_total_pages, pmm_free_pages, pmm_ignored_bytes, &
                         pmm_region_count, pmm_region_base, pmm_region_len, &
                         pmm_region_type, pmm_verify_reserved, &
                         pmm_verify_kernel_locked, pmm_alloc_page_from, &
                         pmm_alloc_contiguous
  use fk_fbinfo_m, only: FK_FB_OK, FK_FB_BASE, FK_FB_PITCH, FK_FB_WIDTH, &
                         FK_FB_HEIGHT, FK_FB_BPP, FK_FB_MASKS, FK_FB_BYTES, &
                         FK_FB_TAG, FK_FB_MAGIC, &
                         fk_fb_info, fb_probe, fb_pixel_pack, fb_note_mapping
  use fk_gop_renderer_m, only: vga_init_framebuffer, vga_fill_rect, &
                         vga_width, vga_height, vga_print_string
  use fk_vfs_m, only: vfs_reset, vfs_mount, vfs_root, vfs_add, vfs_resolve, &
                      vfs_dentry_inode, vfs_inode_ino, vfs_inode_size, &
                      vfs_inode_mode, vfs_dentries_used, vfs_inodes_used
  use fk_vfs_types_m, only: FK_S_IFDIR, FK_S_IFREG, FK_E_NOTDIR
  use fk_console_m, only: FK_CON_OK, console_init, console_write, &
                         console_print_hex, console_cols, console_rows, &
                         console_ready, fk_console_scrolls
  use fk_vmm_m,    only: FK_VMM_OK, FK_VMM_SECTIONS, FK_VMM_SCRATCH, &
                         FK_PTE_P, FK_PTE_RW, FK_PTE_NX, FK_PTE_PWT, &
                         FK_PTE_PCD, &
                         vmm_init, vmm_activate, vmm_drop_identity, &
                         vmm_map_page, vmm_translate, vmm_phys_of, &
                         vmm_pml4_phys, vmm_table_frames, vmm_physmap_top, &
                         vmm_nx_enabled, vmm_verify_image, vmm_read_cr3, &
                         vmm_section_start, vmm_section_end, vmm_section_flags, &
                         vmm_guard_page, vmm_phys_to_virt, &
                         FK_VMM_MMIO, FK_VMM_HEAP, FK_VMM_WC, &
                         FK_VMM_UC, FK_VMM_LAPIC, vmm_reserved_holes, &
                         vmm_physmap_top, FK_VMM_PHYSMAP, &
                         vmm_reserve_mmio, vmm_map_mmio, vmm_pat_arm, &
                         vmm_read_pat, vmm_punch_physmap, FK_VMM_E_IS_RAM, &
                         FK_VMM_IOAPIC, FK_VMM_ECAM, FK_VMM_XHCI, FK_VMM_NVME
  use fk_sched_m,  only: FK_SCHED_MAX, fk_task_runs, fk_sched_switches, &
                         sched_init, sched_spawn, sched_start, sched_current, &
                         sched_tasks
  use fk_heap_m,   only: FK_HEAP_OK, FK_HEAP_ALIGN, FK_HEAP_HDR, &
                         FK_HS_MAPPED, FK_HS_USED, FK_HS_FREE, FK_HS_BLOCKS, &
                         FK_HS_ALLOCS, FK_HS_FREES, FK_HS_LARGEST, &
                         FK_HS_FAILED, FK_HS_BADFREE, fk_heap_stat, &
                         heap_init, kmalloc, kzalloc, kfree, heap_check, &
                         heap_base, heap_top, heap_size_of
  implicit none
  private
  public :: kernel_main

  ! "KBOT": marks the sentinel as written here rather than left uninitialised.
  integer(c_int32_t), parameter :: FK_BOOT_TAG = int(z'4B424F54', c_int32_t)

  ! The value a Multiboot2-compliant loader is required to leave in EAX.
  integer(c_int32_t), parameter :: MB2_BOOTLOADER_MAGIC = int(z'36D76289', c_int32_t)

  ! Not zero, so "never written" and "written with zeros" stay distinguishable.
  integer(c_int32_t), parameter :: FK_UNWRITTEN = int(z'11111111', c_int32_t)

  ! Handoff record: (1) FK_BOOT_TAG, (2) the loader's magic, (3) the low 32
  ! bits of the MBI pointer, (4) tag xor magic computed at run time.  VOLATILE:
  ! the only reader is outside the program -- QMP, after the CPU has parked.
  integer(c_int32_t), volatile, bind(c, name="fk_boot_sentinel") :: &
       fk_boot_sentinel(4) = [FK_UNWRITTEN, FK_UNWRITTEN, FK_UNWRITTEN, FK_UNWRITTEN]

  ! CR LF, never a bare LF: a raw serial line does no newline translation.
  character(kind=c_char, len=*), parameter :: FK_CRLF = achar(13) // achar(10)

  ! tools/qemu-boot-test.sh greps the COM1 log for this text exactly.  The
  ! concatenation is constant-folded into one .rodata string only because these
  ! are PARAMETERs; in executable code gfortran may lower // to a memmove call.
  character(kind=c_char, len=*), parameter :: FK_BANNER = &
       "Fortran Kernel: UART Serial Initialized." // FK_CRLF // c_null_char

  ! Printed when serial_init's loopback probe failed; qemu-boot-test.sh asserts
  ! this string is ABSENT from the log.
  character(kind=c_char, len=*), parameter :: FK_SELFTEST_FAILED = &
       "Fortran Kernel: COM1 loopback self-test FAILED." // FK_CRLF // c_null_char

  character(kind=c_char, len=*), parameter :: FK_GDT_READY = &
       "Fortran Kernel: GDT loaded, flat 64-bit model." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_TSS_READY = &
       "Fortran Kernel: TSS loaded, IST1 armed for #DF." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IDT_READY = &
       "Fortran Kernel: IDT loaded, 32 CPU exceptions armed." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PIC_READY = &
       "Fortran Kernel: 8259 PIC remapped to 0x20/0x28, all IRQs masked." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PIC_FAILED = &
       "Fortran Kernel: 8259 PIC mask readback FAILED." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_TRIGGER_DE = &
       "Fortran Kernel: dividing by zero on purpose (roadmap 3.2)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_TRIGGER_DF = &
       "Fortran Kernel: smashing RSP to force a #DF (roadmap 3.2.5)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_NO_FAULT = &
       "Fortran Kernel: the deliberate fault did NOT trap." // FK_CRLF // c_null_char

  ! roadmap 3.4.  Every one of these is greppable by tools/qemu-boot-test.sh,
  ! and each PASS line has a FAIL twin that the gate REJECTS -- a verdict the
  ! gate does not refuse is a verdict the kernel is free to get wrong.
  character(kind=c_char, len=*), parameter :: FK_NL = FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_FRONT_EFI_MSG = &
       "Fortran Kernel: PMM front end is the UEFI GetMemoryMap array " // &
       "(Multiboot2 tag 17)." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_FRONT_MB2_MSG = &
       "Fortran Kernel: PMM front end is the Multiboot2 memory map (tag 6)." // &
       FK_CRLF // c_null_char
  ! The spurious vector is fk_idt_m's FK_VECTOR_SPURIOUS and is no longer named
  ! twice.  It used to be a local 255 here with a comment saying it was NOT
  ! installed in the IDT, which was true until roadmap 3.3: idt_init now puts
  ! fk_spurious_stub on it, because the LAPIC starts delivering the moment SVR's
  ! enable bit is set and a spurious interrupt into a cleared descriptor is a
  ! #GP raised from inside delivery.  Two copies of the number would be two
  ! things that can drift, and the gate and the stub would then disagree about
  ! which vector they are talking about.
  ! roadmap 4.1.  Read out of guest memory by tools/qmp-sentinel.py, for the
  ! reason fk_panic_state and fk_boot_sentinel are: a console line is the
  ! kernel's opinion of itself, and the topology is the one thing here that a
  ! second, independent source (the MADT) can be checked against.
  ! [0] magic  [1] root kind  [2] root phys   [3] MADT phys
  ! [4] cpus   [5] ioapic0    [6] overrides   [7] GSI for IRQ0
  integer(c_int64_t), parameter :: FK_ACPI_MAGIC = int(z'4143504954', c_int64_t)
  integer(c_int64_t), volatile, save, bind(c, name="fk_acpi_topo") :: &
       fk_acpi_topo(0:7)

  ! roadmap 3.x.  [0] magic  [1] phys base  [2] pages  [3] tag seed.
  ! The PAGES carry the proof and this only says where to look: every frame in
  ! the run gets a word derived from its own index, written through the linear
  ! map, and tools/qmp-sentinel.py reads them back at the PHYSICAL base with no
  ! page table involved.  A bitmap can only testify about itself.
  integer(c_int64_t), parameter :: FK_DMA_MAGIC = int(z'444D4143', c_int64_t)
  integer(c_int64_t), parameter :: FK_DMA_PAGES = 4_c_int64_t
  integer(c_int64_t), parameter :: FK_DMA_SEED  = &
       int(z'0DA10DA100000000', c_int64_t)
  integer(c_int64_t), volatile, save, bind(c, name="fk_dma_probe") :: &
       fk_dma_probe(0:3)

  ! roadmap 3.3.  [0] magic  [1] IOAPIC phys  [2] gsi  [3] vector
  ! [4] the redirection entry's low dword READ BACK  [5] both IMRs
  integer(c_int64_t), parameter :: FK_IOA_MAGIC = int(z'494F4150494301', c_int64_t)
  integer(c_int64_t), volatile, save, bind(c, name="fk_ioapic_state") :: &
       fk_ioapic_state(0:5)

  ! roadmap 4.2.  [0] magic  [1] ECAM phys  [2] bus range packed lo:hi
  ! [3] functions kept  [4] functions seen  then one packed word per function:
  ! bdf<<48 | vendor<<32 | device<<16 | class<<8 | subclass.  Prog-if is left
  ! out on purpose -- 'info pci' does not print it, so a comparison against
  ! QEMU cannot use it and a field nothing checks is a field nothing checks.
  integer(c_int64_t), parameter :: FK_PCIE_MAGIC = int(z'5043494501', c_int64_t)
  integer(c_int32_t), parameter :: FK_PCIE_SLOTS = 32_c_int32_t
  ! 0 magic, 1 ECAM base, 2 bus range, 3 kept, 4 seen, then FK_PCIE_SLOTS
  ! functions, then what 5.1 needs off the xHCI: its BDF, the COMMAND it read
  ! back after the enable, the MSI-X triple and BAR0.
  integer(c_int64_t), volatile, save, bind(c, name="fk_pcie_devs") :: &
       fk_pcie_devs(0:FK_PCIE_SLOTS + 11)
  integer(c_int32_t), parameter :: FK_PCIE_W_XHCI = FK_PCIE_SLOTS + 5_c_int32_t
  integer(c_int32_t), parameter :: FK_PCIE_W_CMD  = FK_PCIE_SLOTS + 6_c_int32_t
  integer(c_int32_t), parameter :: FK_PCIE_W_MSIX = FK_PCIE_SLOTS + 7_c_int32_t
  integer(c_int32_t), parameter :: FK_PCIE_W_TBL  = FK_PCIE_SLOTS + 8_c_int32_t
  integer(c_int32_t), parameter :: FK_PCIE_W_BAR  = FK_PCIE_SLOTS + 9_c_int32_t
  integer(c_int32_t), parameter :: FK_PCIE_W_MSG = FK_PCIE_SLOTS + 10_c_int32_t
  integer(c_int32_t), parameter :: FK_PCIE_W_CTRL = FK_PCIE_SLOTS + 11_c_int32_t

  ! 64 KiB covers every xHCI register block this kernel will meet: qemu-xhci
  ! decodes 16 KiB and the specification's capability, operational, runtime and
  ! doorbell regions fit inside that on real parts too.  Mapping the BAR's own
  ! reported size needs BAR SIZING, which 4.2 does not do.
  integer(c_int64_t), parameter :: FK_XHCI_WINDOW_BYTES = 65536_c_int64_t

  ! roadmap 5.1.  [0] magic  [1] BAR0 phys  [2] the contiguous run  [3] command
  ! ring  [4] event ring  [5] ERST  [6] the NO-OP TRB  [7] event type<<32|code
  ! [8] the command pointer the event named  [9] USBSTS  [10] CRCR  [11] ERDP
  ! [12] MSI-X interrupts taken  [13] caplength<<32|version  [14] slots<<32|
  ! scratchpads  [15] the sequence's status  [16] CRCR and [17] DCBAAP and
  ! [18] USBSTS as they read IMMEDIATELY AFTER THE RESET, before this kernel
  ! programs anything -- firmware leaves all three non-zero, so a kernel that
  ! skipped the reset publishes firmware's values and is refused
  integer(c_int64_t), parameter :: FK_XHCIS_MAGIC = &
       int(z'584843490501', c_int64_t)
  integer(c_int64_t), volatile, save, bind(c, name="fk_xhci_state") :: &
       fk_xhci_state(0:18)

  ! Four pages, carved: DCBAA, command ring, event ring, ERST.  One run rather
  ! than four allocations because one physical base is one thing for the host
  ! to check, and page alignment already satisfies every alignment the
  ! specification asks for here (64 bytes) plus the 64 KiB boundary rule.
  integer(c_int64_t), parameter :: FK_XHCI_RING_PAGES = 4_c_int64_t
  integer(c_int32_t), parameter :: FK_XHCI_RING_TRBS = 256_c_int32_t

  ! 'MCFG' packed little-endian, built the way FK_SIG_APIC is.
  integer(c_int32_t), parameter :: FK_SIG_MCFG = &
       ior(ior(iachar('M', c_int32_t), shiftl(iachar('C', c_int32_t), 8)), &
           ior(shiftl(iachar('F', c_int32_t), 16), &
               shiftl(iachar('G', c_int32_t), 24)))

  ! 'APIC' packed little-endian, built rather than written down.
  integer(c_int32_t), parameter :: FK_SIG_APIC = &
       ior(ior(iachar('A', c_int32_t), shiftl(iachar('P', c_int32_t), 8)), &
           ior(shiftl(iachar('I', c_int32_t), 16), &
               shiftl(iachar('C', c_int32_t), 24)))

  character(kind=c_char, len=*), parameter :: FK_ACPI_START = &
       "Fortran Kernel: ACPI parsing the loader's RSDP tag (roadmap 4.1)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_ACPI_ROOT = &
       "Fortran Kernel: ACPI root/rev/tables 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_ACPI_XSDT = &
       "Fortran Kernel: ACPI root is the XSDT (Multiboot2 tag 15)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_ACPI_RSDT = &
       "Fortran Kernel: ACPI root is the RSDT (Multiboot2 tag 14)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_ACPI_INIT_BAD = &
       "Fortran Kernel: ACPI init FAILED, status 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_ACPI_NO_MADT = &
       "Fortran Kernel: ACPI found no MADT." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_MADT_BAD = &
       "Fortran Kernel: MADT parse FAILED, status 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_MADT_AT = &
       "Fortran Kernel: MADT at/len 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_MADT_CPUS = &
       "Fortran Kernel: MADT cpus total/enabled/skipped 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_MADT_IOAPIC = &
       "Fortran Kernel: MADT ioapics/first-addr/gsi-base 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_MADT_ISO = &
       "Fortran Kernel: MADT overrides/IRQ0-GSI 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_MADT_NMI = &
       "Fortran Kernel: MADT NMI entries/LINT 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_MADT_AGREE = &
       "Fortran Kernel: MADT and IA32_APIC_BASE agree on 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_MADT_DISAGREE = &
       "Fortran Kernel: MADT and IA32_APIC_BASE DISAGREE." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_MADT_PCAT = &
       "Fortran Kernel: MADT says PCAT_COMPAT: the 8259s are present and " // &
       "must be disabled before the IOAPIC is used." // FK_CRLF // c_null_char

  character(kind=c_char, len=*), parameter :: FK_LAPIC_START = &
       "Fortran Kernel: LAPIC bring-up from IA32_APIC_BASE (roadmap 3.3)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_LAPIC_MSR = &
       "Fortran Kernel: LAPIC MSR base/enabled 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_LAPIC_OFF = &
       "Fortran Kernel: LAPIC is DISABLED in IA32_APIC_BASE; not mapped." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_LAPIC_MAP_BAD = &
       "Fortran Kernel: LAPIC mapping FAILED, status 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_LAPIC_HOLES = &
       "Fortran Kernel: MMIO apertures punched out of the linear map, " // &
       "holes 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_LAPIC_LIVE = &
       "Fortran Kernel: LAPIC id/version/SVR 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_LAPIC_LINT = &
       "Fortran Kernel: LAPIC LINT0/LINT1 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_LAPIC_MASKED = &
       "Fortran Kernel: LAPIC software-enabled, LINT0 ExtINT, LINT1 NMI." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_LAPIC_BAD = &
       "Fortran Kernel: LAPIC FAILED its own readback." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_START = &
       "Fortran Kernel: PMM parsing the Multiboot2 memory map (roadmap 3.4)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_INIT_FAILED = &
       "Fortran Kernel: PMM init FAILED, status 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_HEADER = &
       "PMM  ID BASE               END                TYPE" // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_ROW    = "PMM  " // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_SP     = " " // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_0X     = "0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_ALLOC  = "ALLOC 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_TOTALS = &
       "Fortran Kernel: PMM frames total/free/unmanaged-bytes 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_SLASH  = "/0x" // c_null_char

  character(kind=c_char, len=*), parameter :: FK_PCIE_START = &
       "Fortran Kernel: PCIe looking for the ECAM window (roadmap 4.2)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_NO_MCFG = &
       "Fortran Kernel: no MCFG table; this machine has no ECAM window." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_MCFG_BAD = &
       "Fortran Kernel: the MCFG table would not parse, status 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_WINDOW = &
       "Fortran Kernel: ECAM base/segment/buses/bytes 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_PUNCH_BAD = &
       "Fortran Kernel: the ECAM window could not be taken out of the linear map, status 0x" // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_MAP_BAD = &
       "Fortran Kernel: the ECAM window could not be mapped, status 0x" // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_ALIAS_OK = &
       "Fortran Kernel: the ECAM window has no write-back alias in the linear map." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_ALIAS_BAD = &
       "Fortran Kernel: the ECAM window is STILL mapped write-back in the linear map." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_UC_OK = &
       "Fortran Kernel: the ECAM mapping selects PWT and PCD, strong uncacheable." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_UC_BAD = &
       "Fortran Kernel: the ECAM mapping is CACHED." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_COUNT = &
       "Fortran Kernel: PCIe functions kept/seen 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_TRUNC = &
       "Fortran Kernel: the PCIe list is TRUNCATED; the machine has more functions than slots." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_DEV = &
       "Fortran Kernel: PCIe 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_DOT = "." // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_SP = " 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_NONE_YET = &
       "Fortran Kernel: no xHCI and no NVMe on this bus (roadmap 5.1, 5.3)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_CMD = &
       "Fortran Kernel: xHCI COMMAND firmware/cleared/enabled 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_CMD_OK = &
       "Fortran Kernel: xHCI decode and bus mastering were taken DOWN and put back by this kernel." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_CMD_BAD = &
       "Fortran Kernel: the xHCI REFUSED a COMMAND write; decode or bus mastering did not move." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_BAR = &
       "Fortran Kernel: xHCI BAR0 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_MSIX = &
       "Fortran Kernel: xHCI MSI-X cap/entries/bar/offset 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_NO_MSIX = &
       "Fortran Kernel: the xHCI declares NO MSI-X capability; 5.1 has no route." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_MAP_BAD = &
       "Fortran Kernel: the xHCI register block could not be mapped, status 0x" // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_WINDOW = &
       "Fortran Kernel: xHCI BAR0 mapped strong-UC, virt/phys 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_ROUTE = &
       "Fortran Kernel: xHCI MSI-X entry 0 addr/data/mask 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_ROUTE_OK = &
       "Fortran Kernel: the xHCI has an MSI-X route to this CPU and INTx is off (roadmap 5.1)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_ROUTE_BAD = &
       "Fortran Kernel: the xHCI MSI-X route did NOT read back; the controller has no interrupt." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_CTRL = &
       "Fortran Kernel: xHCI MSI-X control/command 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_START = &
       "Fortran Kernel: xHCI bringing the controller up (roadmap 5.1)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_NOMEM = &
       "Fortran Kernel: the PMM refused a contiguous run for the xHCI rings." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_SEQ_BAD = &
       "Fortran Kernel: the xHCI bring-up FAILED, status 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_CAPS = &
       "Fortran Kernel: xHCI caplength/version/slots/scratchpads/page 0x" // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_RINGS = &
       "Fortran Kernel: xHCI cmd/event/erst 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_RUNNING = &
       "Fortran Kernel: the xHCI is RUNNING, USBSTS 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_NOOP = &
       "Fortran Kernel: xHCI NO-OP trb/event/code/ptr 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_DONE = &
       "Fortran Kernel: the xHCI executed a command and reported it complete (roadmap 5.1)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_NOEVENT = &
       "Fortran Kernel: the xHCI never completed the NO-OP; no event arrived." // &
       FK_CRLF // c_null_char
  ! roadmap 5.3
  character(kind=c_char, len=*), parameter :: FK_NVME_START = &
       "Fortran Kernel: NVMe looking for a storage controller (roadmap 5.3)." // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_NVME_NONE = &
       "Fortran Kernel: no NVMe controller on this bus." // c_null_char
  character(kind=c_char, len=*), parameter :: FK_NVME_MAP_BAD = &
       "Fortran Kernel: the NVMe register block could not be mapped, status 0x" // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_NVME_NOMEM = &
       "Fortran Kernel: the PMM refused a contiguous run for the NVMe queues." // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_NVME_CAPS = &
       "Fortran Kernel: NVMe cap/version/mqes/dstrd 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_NVME_WINDOW = &
       "Fortran Kernel: NVMe BAR0 mapped strong-UC, virt/phys 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_NVME_READY = &
       "Fortran Kernel: NVMe cc/csts/aqa 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_NVME_QUEUES = &
       "Fortran Kernel: NVMe asq/acq 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_NVME_NS = &
       "Fortran Kernel: NVMe nsid 1 blocks/lba-bytes 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_NVME_SECTOR = &
       "Fortran Kernel: NVMe sector 0 [0..15] 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_NVME_DONE = &
       "Fortran Kernel: the NVMe controller read sector 0 into memory (roadmap 5.3)." // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_NVME_BAD = &
       "Fortran Kernel: the NVMe bring-up FAILED, status 0x" // c_null_char

  ! Six pages, one run: admin SQ and CQ, I/O SQ and CQ, the identify buffer
  ! and the sector buffer.  One physical base for the host to check, 5.1's
  ! argument unchanged.
  integer(c_int64_t), parameter :: FK_NVME_PAGES = 6_c_int64_t
  ! [0] magic [1] BAR0 [2] run [3] cap [4] version [5] cc [6] csts [7] aqa
  ! [8] asq [9] acq [10] identify buf phys [11] sector buf phys [12] ns blocks
  ! [13] lba bytes [14] last status [15] completions taken IN INTERRUPT CONTEXT
  ! [16] the first eight bytes of sector 0 [17] the next eight
  ! [18] admin cq head [19] admin cq phase [20] sequence status
  integer(c_int64_t), parameter :: FK_NVMES_MAGIC = &
       int(z'4E564D450503', c_int64_t)
  integer(c_int64_t), volatile, save, bind(c, name="fk_nvme_state") :: &
       fk_nvme_state(0:20)

  ! roadmap 6.1
  character(kind=c_char, len=*), parameter :: FK_VFS_START = &
       "Fortran Kernel: mounting the VFS root (roadmap 6.1)." // FK_CRLF // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_VFS_TREE = &
       "Fortran Kernel: VFS sb/root/bin/init 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VFS_NODE = &
       "Fortran Kernel: /bin/init ino/size/mode 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VFS_POOLS = &
       "Fortran Kernel: VFS dentries/inodes in use 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VFS_DONE = &
       "Fortran Kernel: the VFS resolved /bin/init and refused /bin/init/ (roadmap 6.1)." // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_VFS_BAD = &
       "Fortran Kernel: the VFS bring-up FAILED, status 0x" // c_null_char

  ! The paths are PARAMETERs so gfortran folds the concatenation into one
  ! .rodata string; in executable code it may lower // to a memmove call.
  character(kind=c_char, len=*), parameter :: FK_VFS_P_INIT = &
       "/bin/init" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VFS_P_SLASH = &
       "/bin/init/" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VFS_N_BIN = "bin" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VFS_N_ETC = "etc" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VFS_N_INIT = "init" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VFS_N_FSTAB = &
       "fstab" // c_null_char

  ! [0] magic [1] sb [2] root [3] /bin [4] /bin/init [5] its inode number
  ! [6] its size [7] its mode [8] dentries in use [9] inodes in use
  ! [10] what /bin/init/ answered, which must be -ENOTDIR [11] sequence status
  ! Longest string path_copy is asked to carry is "/bin/init/" plus its NUL.
  integer(c_int32_t), parameter :: FK_VFS_PBUF = 16_c_int32_t
  integer(c_int64_t), parameter :: FK_VFSS_MAGIC = &
       int(z'5646530601', c_int64_t)
  integer(c_int64_t), volatile, save, bind(c, name="fk_vfs_state") :: &
       fk_vfs_state(0:11)

  ! roadmap 5.2
  character(kind=c_char, len=*), parameter :: FK_KBD_START = &
       "Fortran Kernel: USB looking for a HID keyboard (roadmap 5.2)." // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_KBD_NOMEM = &
       "Fortran Kernel: the PMM refused a contiguous run for the keyboard." // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_KBD_PORT = &
       "Fortran Kernel: USB port/portsc/speed 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_KBD_SLOT = &
       "Fortran Kernel: USB slot/address/state 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_KBD_DEV = &
       "Fortran Kernel: USB mps0/config/interface 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_KBD_EP = &
       "Fortran Kernel: USB EP1 addr/maxpkt/interval 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_KBD_CTX = &
       "Fortran Kernel: USB device/input ctx/report buffer 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_KBD_OK = &
       "Fortran Kernel: the USB keyboard is addressed, configured and polling (roadmap 5.2)." // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_KBD_BAD = &
       "Fortran Kernel: the USB keyboard bring-up FAILED, status 0x" // &
       c_null_char

  ! Six pages, one run: device context, input context, EP0's transfer ring,
  ! EP1's, the descriptor buffer and the report buffer.  One physical base is
  ! one thing for the host to check, which is 5.1's argument unchanged.
  integer(c_int64_t), parameter :: FK_KBD_PAGES = 6_c_int64_t

  character(kind=c_char, len=*), parameter :: FK_XHCI_IRQ = &
       "Fortran Kernel: the xHCI's MSI-X interrupt ARRIVED, count 0x" // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_XHCI_NOIRQ = &
       "Fortran Kernel: the xHCI completed its command but sent NO interrupt." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PCIE_WALKED = &
       "Fortran Kernel: the PCIe bus was walked and every function reported (roadmap 4.2)." // &
       FK_CRLF // c_null_char

  character(kind=c_char, len=*), parameter :: FK_IOA_START = &
       "Fortran Kernel: IOAPIC taking the timer off the 8259s (roadmap 3.3)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_NONE = &
       "Fortran Kernel: the MADT declared no IOAPIC; the 8259s keep the timer." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_PUNCH_BAD = &
       "Fortran Kernel: the IOAPIC page could not be taken out of the linear map, status 0x" // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_MAP_BAD = &
       "Fortran Kernel: the IOAPIC page could not be mapped, status 0x" // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_ALIAS_OK = &
       "Fortran Kernel: the IOAPIC page has no write-back alias in the linear map." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_ALIAS_BAD = &
       "Fortran Kernel: the IOAPIC page is STILL mapped write-back in the linear map." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_CHIP = &
       "Fortran Kernel: IOAPIC id/version/entries 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_PIC_OFF = &
       "Fortran Kernel: both 8259s report every line masked." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_PIC_ON = &
       "Fortran Kernel: an 8259 REFUSED to mask." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_ROUTED = &
       "Fortran Kernel: IOAPIC gsi/vector/readback 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_ROUTE_BAD = &
       "Fortran Kernel: the IOAPIC did not accept the redirection entry, status 0x" // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_READBACK_BAD = &
       "Fortran Kernel: the IOAPIC redirection entry did NOT read back as written." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_TICKING = &
       "Fortran Kernel: the timer still ticks with both 8259s masked (roadmap 3.3)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IOA_STOPPED = &
       "Fortran Kernel: the timer STOPPED once the 8259s were masked." // &
       FK_CRLF // c_null_char

  character(kind=c_char, len=*), parameter :: FK_DMA_START = &
       "Fortran Kernel: DMA asking the PMM for a contiguous run (roadmap 3.x)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_DMA_BASE = &
       "Fortran Kernel: DMA run phys/pages 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_DMA_WALK_OK = &
       "Fortran Kernel: every frame of the run translates to the next physical page." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_DMA_WALK_BAD = &
       "Fortran Kernel: the DMA run is NOT contiguous in physical memory." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_DMA_REFUSED = &
       "Fortran Kernel: pmm_alloc_contiguous refused the run." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_TAKEN  = &
       "Fortran Kernel: PMM handed out 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_BEFORE = &
       " frames before it refused." // FK_CRLF // c_null_char

  character(kind=c_char, len=*), parameter :: FK_PMM_RSVD_OK = &
       "Fortran Kernel: PMM reserved and ACPI frames are all marked used." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_RSVD_BAD = &
       "Fortran Kernel: PMM reserved or ACPI frames are STILL FREE." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_LOCK_OK = &
       "Fortran Kernel: PMM locked the kernel image and the loader map out." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_LOCK_BAD = &
       "Fortran Kernel: PMM did NOT lock the kernel image out." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_ALLOC_OK = &
       "Fortran Kernel: PMM allocated 5 distinct, aligned frames." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_ALLOC_BAD = &
       "Fortran Kernel: PMM allocation FAILED: repeated or misaligned frame." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_RECLAIM_OK = &
       "Fortran Kernel: PMM freed and reclaimed the same 5 frames." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_RECLAIM_BAD = &
       "Fortran Kernel: PMM reclaim FAILED." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_GUARD_OK = &
       "Fortran Kernel: PMM refused a double, unaligned and locked free." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_GUARD_BAD = &
       "Fortran Kernel: PMM guard FAILED." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_CURSOR_OK = &
       "Fortran Kernel: PMM rewound its scan cursor to a freed frame." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_CURSOR_BAD = &
       "Fortran Kernel: PMM cursor rewind FAILED." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_OOM_HDR = &
       FK_CRLF // "*** PMM OUT OF MEMORY ***" // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_DRAIN = &
       "Fortran Kernel: draining the PMM to force an OOM panic (roadmap 3.4)." // &
       FK_CRLF // c_null_char

  ! roadmap 3.5 and 1.2b.  Same discipline as 3.4's: every verdict printed here
  ! has a FAIL twin the boot gate REJECTS, and the numbers beside it are read
  ! back out of the live page tables rather than remembered from what was asked
  ! for.
  character(kind=c_char, len=*), parameter :: FK_VMM_START = &
       "Fortran Kernel: VMM building 4-level page tables (roadmap 3.5)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VMM_INIT_FAILED = &
       "Fortran Kernel: VMM init FAILED, status 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VMM_HDR = &
       "VMM  SECTION  VIRT               PHYS               PERM" // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VMM_ROW   = "VMM  " // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VMM_ARROW = " " // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VMM_TOTALS = &
       "Fortran Kernel: VMM PML4/table-frames/physmap-top 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VMM_NX_ON = &
       "Fortran Kernel: VMM has EFER.NXE and CR0.WP, so the permissions bite." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VMM_NX_OFF = &
       "Fortran Kernel: VMM could not enable NX; .rodata is not no-execute." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VMM_MAP_OK = &
       "Fortran Kernel: VMM mapped every kernel page with the asked-for " // &
       "permission." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VMM_MAP_BAD = &
       "Fortran Kernel: VMM section permissions are WRONG, pages 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VMM_GUARD_OK = &
       "Fortran Kernel: VMM left the stack guard page unmapped." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VMM_GUARD_BAD = &
       "Fortran Kernel: VMM guard page is MAPPED." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VMM_CR3 = &
       "Fortran Kernel: higher-half handoff done, CR3 = 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VMM_ID_LIVE = &
       "Fortran Kernel: identity window still live, [0x100000] = 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VMM_ID_DEAD_OK = &
       "Fortran Kernel: PML4[0] unmapped; the identity window is dead." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VMM_ID_DEAD_BAD = &
       "Fortran Kernel: PML4[0] is STILL MAPPED." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VMM_HIGH_OK = &
       "Fortran Kernel: VMM mapped a frame above 4 GiB and read back what it " // &
       "wrote." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VMM_HIGH_BAD = &
       "Fortran Kernel: VMM high-frame mapping FAILED." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_VMM_HIGH_NONE = &
       "Fortran Kernel: this machine reports no RAM above 4 GiB; high-frame " // &
       "probe skipped." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_TRIGGER_GUARD = &
       "Fortran Kernel: reading the guard page below the boot stack " // &
       "(roadmap 3.5)." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_TRIGGER_IDMAP = &
       "Fortran Kernel: reading physical 0x100000 with no identity map " // &
       "(roadmap 1.2b)." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PANIC_REASON = &
       "unrecoverable: roadmap 1.4 software panic path" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_TRIGGER_WP = &
       "Fortran Kernel: writing to .text, which only CR0.WP refuses " // &
       "(roadmap 3.5)." // FK_CRLF // c_null_char

  ! roadmap 3.2b.  Six properties, six FAIL twins, and not one of them is a
  ! restatement of another: the chip was programmed, the line was opened, the
  ! CPU became interruptible, the handler ran more than once, it ran on top of
  ! kernel code, and the kernel outlived it.
  ! "." CR LF: the tail of every line above that ends in a hex field.
  character(kind=c_char, len=*), parameter :: FK_DOT_NL = &
       "." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PIT_READY = &
       "Fortran Kernel: PIT channel 0 hz/divisor 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PIT_FAILED = &
       "Fortran Kernel: PIT divisor is 0, so channel 0 was NOT programmed." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IRQ_OPEN = &
       "Fortran Kernel: 8259 IMR now 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IRQ_OPEN_TAIL = &
       ", IRQ0 is the only line open." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IRQ_OPEN_BAD = &
       "Fortran Kernel: IRQ0 is STILL MASKED after the unmask." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IF_ON = &
       "Fortran Kernel: RFLAGS.IF is set, the CPU is interruptible, RFLAGS = 0x" &
       // c_null_char
  character(kind=c_char, len=*), parameter :: FK_IF_OFF = &
       "Fortran Kernel: RFLAGS.IF is CLEAR after STI." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_TICKS_OK = &
       "Fortran Kernel: IRQ0 ticks before/after/spurious 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_TICKS_NONE = &
       "Fortran Kernel: IRQ0 never reached the tick target; the timer " // &
       "interrupt did not arrive." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_TICK_RIP = &
       "Fortran Kernel: the first tick interrupted kernel .text with IF set, " // &
       "RIP/RFLAGS 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_TICK_RIP_BAD = &
       "Fortran Kernel: the first tick's saved frame is NOT kernel .text with " // &
       "IF set." // FK_CRLF // c_null_char
  ! The headline, and the line no boot in this tree's history could have
  ! printed: reaching it means an interrupt was taken and RETURNED FROM.
  character(kind=c_char, len=*), parameter :: FK_IRQ_ALIVE = &
       "Fortran Kernel: interrupts are live and the kernel is still running " // &
       "(roadmap 3.2b)." // FK_CRLF // c_null_char

  ! roadmap 2.2 and 2.4.  The framebuffer geometry is printed as the LOADER
  ! reported it, not as boot.S asked for it: GRUB answers with the mode it
  ! could set, and a kernel that printed its own request would describe a
  ! screen it is not drawing on.
  character(kind=c_char, len=*), parameter :: FK_FB_START = &
       "Fortran Kernel: GOP probing the Multiboot2 framebuffer tag (roadmap 2.2)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_FB_PROBE_BAD = &
       "Fortran Kernel: GOP framebuffer tag REJECTED, status 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_FB_GEOM = &
       "Fortran Kernel: GOP framebuffer base/pitch/w/h/bpp 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_FB_CHAN = &
       "Fortran Kernel: GOP channel r/g/b pos:size packed 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_FB_PAT_OK = &
       "Fortran Kernel: GOP IA32_PAT is 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_FB_PAT_TAIL = &
       ", PAT index 1 is write-combining." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_FB_PAT_BAD = &
       "Fortran Kernel: GOP could NOT program the PAT; the framebuffer is " // &
       "not write-combining." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_FB_MAP_BAD = &
       "Fortran Kernel: GOP framebuffer mapping FAILED, status 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_FB_WC_OK = &
       "Fortran Kernel: GOP framebuffer PTE selects PAT index 1, " // &
       "write-combining." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_FB_WC_BAD = &
       "Fortran Kernel: GOP framebuffer PTE is NOT write-combining." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_FB_ALIAS_OK = &
       "Fortran Kernel: GOP framebuffer has no write-back alias in the " // &
       "linear map." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_FB_ALIAS_BAD = &
       "Fortran Kernel: GOP framebuffer is ALIASED write-back in the linear map." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_FB_PTE = &
       "Fortran Kernel: GOP framebuffer virt/phys/PTE 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_FB_ARMED = &
       "Fortran Kernel: GOP renderer armed on the mapped framebuffer (roadmap 2.4)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_FB_ARM_BAD = &
       "Fortran Kernel: GOP renderer REFUSED the framebuffer, status 0x" // c_null_char

  character(kind=c_char, len=*), parameter :: FK_CON_READY = &
       "Fortran Kernel: console is live on the framebuffer, cols/rows 0x" // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_CON_BAD = &
       "Fortran Kernel: console REFUSED the framebuffer geometry, status 0x" // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_CON_SCROLL = &
       "Fortran Kernel: console scrolled 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_CON_SCROLL_TAIL = &
       " times, costing 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_CON_SCROLL_TICKS = &
       " PIT ticks for the last one." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_CON_SCROLL_BAD = &
       "Fortran Kernel: console never scrolled." // FK_CRLF // c_null_char

  ! Printed to the SCREEN, not to COM1.  It is the only line in the boot whose
  ! evidence is a pixel, so it says so.
  character(kind=c_char, len=*), parameter :: FK_SCREEN_BANNER = &
       "PROJECT FORTRAN-KERNEL -- this line is glyphs, not a serial byte." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_SCREEN_GEOM = &
       "console " // c_null_char
  character(kind=c_char, len=*), parameter :: FK_SCREEN_X = "x" // c_null_char

  ! roadmap 4.0.  Frames are staged here before any of them is mapped, so a
  ! growth that cannot be completed costs nothing.  512 pages = 2 MiB, which is
  ! also the largest single kmalloc this kernel serves.
  integer(c_int32_t), parameter :: FK_SBRK_MAX_PAGES = 512_c_int32_t
  integer(c_int64_t), save :: sbrk_frames(FK_SBRK_MAX_PAGES) = 0_c_int64_t
  integer(c_int64_t), save :: heap_next = 0_c_int64_t

  integer(c_int32_t), parameter :: FK_HEAP_PROBES = 8_c_int32_t
  ! Sizes that straddle the allocator's boundaries: under the header, exactly a
  ! block, one over an alignment unit, and past the 64 KiB growth chunk.
  integer(c_int64_t), parameter :: FK_HEAP_SIZES(FK_HEAP_PROBES) = &
       [ 1_c_int64_t, 16_c_int64_t, 17_c_int64_t, 64_c_int64_t, &
         4095_c_int64_t, 4096_c_int64_t, 65536_c_int64_t, 131072_c_int64_t ]
  integer(c_int64_t), parameter :: FK_HEAP_PATTERN = int(z'5A5AA5A500C0FFEE', c_int64_t)

  ! The virtual address the framebuffer is mapped at, and the width of the
  ! test bar the harness looks for in a pmemsave of the framebuffer.
  integer(c_int32_t), parameter :: FK_FB_BAR_H = 16_c_int32_t

  ! A string drawn in the status bar at a FIXED cell, in a colour nothing else
  ! uses, and never scrolled.  tools/qmp-sentinel.py renders the same glyphs
  ! from the kernel's OWN font table -- read out of guest memory -- and
  ! compares them pixel for pixel.  Counting lit pixels proves the renderer
  ! reached video memory; this proves it drew the RIGHT glyphs, which is the
  ! only thing that catches a character arriving at vga_print_char mangled.
  character(kind=c_char, len=*), parameter :: FK_FB_SIG = &
       "FK-GOP 2.4" // c_null_char
  integer(c_int32_t), parameter :: FK_FB_SIG_X = 256_c_int32_t

  ! roadmap 4.0, the scheduler.
  character(kind=c_char, len=*), parameter :: FK_SCHED_START = &
       "Fortran Kernel: scheduler spawning two kernel threads (roadmap 4.0)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_SCHED_SPAWNED = &
       "Fortran Kernel: scheduler tasks/current 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_SCHED_SPAWN_BAD = &
       "Fortran Kernel: scheduler could NOT spawn a thread, status 0x" // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_SCHED_LIVE = &
       "Fortran Kernel: preemption is on; the timer now switches tasks." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_SCHED_RAN = &
       "Fortran Kernel: both threads ran, switches/A/B 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_SCHED_STUCK = &
       "Fortran Kernel: a spawned thread NEVER ran; the switch did not " // &
       "happen." // FK_CRLF // c_null_char

  ! What the two threads put on screen.  Single characters, because the proof
  ! is that they INTERLEAVE: a long string from each would be indistinguishable
  ! from one thread running to completion and then the other.
  character(kind=c_char, len=*), parameter :: FK_THREAD_A = "A" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_THREAD_B = "B" // c_null_char

  ! Ticks a thread waits between characters.  10 ms each at 100 Hz, so the two
  ! threads produce a few characters a second and a boot's worth of output is
  ! bounded.
  integer(c_int64_t), parameter :: FK_THREAD_PERIOD = 5_c_int64_t

  ! How long the boot thread waits for the other two before calling it stuck.
  ! Generous: three thread periods plus slack, so a slow emulator does not
  ! produce a failure that looks like a scheduling bug.
  integer(c_int64_t), parameter :: FK_SCHED_WAIT_TICKS = 200_c_int64_t

  ! Console colours, packed once the loader's channel layout is known.
  integer(c_int32_t), parameter :: FK_CON_FG_R = 208_c_int32_t
  integer(c_int32_t), parameter :: FK_CON_FG_G = 224_c_int32_t
  integer(c_int32_t), parameter :: FK_CON_FG_B = 208_c_int32_t
  integer(c_int32_t), parameter :: FK_CON_BG_R =   0_c_int32_t
  integer(c_int32_t), parameter :: FK_CON_BG_G =  16_c_int32_t
  integer(c_int32_t), parameter :: FK_CON_BG_B =  32_c_int32_t

  ! roadmap 4.0, the heap.
  character(kind=c_char, len=*), parameter :: FK_HEAP_START = &
       "Fortran Kernel: heap bringing up kmalloc/kfree (roadmap 4.0)." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_HEAP_BASE = &
       "Fortran Kernel: heap base/top/mapped 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_HEAP_SBRK_BAD = &
       "Fortran Kernel: heap could not get memory from the PMM/VMM." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_HEAP_ALIGN_OK = &
       "Fortran Kernel: heap returned 16-byte aligned, non-overlapping blocks." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_HEAP_ALIGN_BAD = &
       "Fortran Kernel: heap blocks are misaligned or OVERLAP." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_HEAP_PATTERN_OK = &
       "Fortran Kernel: heap kept every block's contents across the other " // &
       "allocations." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_HEAP_PATTERN_BAD = &
       "Fortran Kernel: heap blocks OVERWROTE each other." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_HEAP_ZERO_OK = &
       "Fortran Kernel: kzalloc returned memory that was already zero." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_HEAP_ZERO_BAD = &
       "Fortran Kernel: kzalloc returned DIRTY memory." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_HEAP_COAL_OK = &
       "Fortran Kernel: heap coalesced every freed block back into one, " // &
       "largest free 0x" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_HEAP_COAL_BAD = &
       "Fortran Kernel: heap did NOT coalesce; it is fragmented, blocks 0x" // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_HEAP_GUARD_OK = &
       "Fortran Kernel: heap refused a double free, a stray pointer and a " // &
       "wrapped size." // FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_HEAP_GUARD_BAD = &
       "Fortran Kernel: heap ACCEPTED a free it should have refused." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_HEAP_CHECK_OK = &
       "Fortran Kernel: heap tiles its window exactly, blocks/used/free 0x" // &
       c_null_char
  character(kind=c_char, len=*), parameter :: FK_HEAP_CHECK_BAD = &
       "Fortran Kernel: heap FAILED its own consistency walk, faults 0x" // &
       c_null_char

  ! Same order as fk_vmm_m's section table, which is the order linker.ld lays
  ! them down.  A mismatch here mislabels a row and nothing else, which is
  ! exactly why the row carries the addresses too.
  character(kind=c_char, len=8), parameter :: FK_VMM_SEC_NAME(FK_VMM_SECTIONS) = &
       [ character(kind=c_char, len=8) :: &
         ".mbhdr " // c_null_char, ".text  " // c_null_char, &
         ".rodata" // c_null_char, ".data  " // c_null_char, &
         ".bss   " // c_null_char, ".bootpt" // c_null_char ]

  ! Physical 1 MiB: the first byte of this image, and the Multiboot2 header
  ! magic, so the value read back through the identity window is checkable by
  ! eye rather than merely non-zero.
  integer(c_int64_t), parameter :: FK_PHYS_1MIB = 1048576_c_int64_t

  ! The floor for the high-frame probe, and the value written through it.
  integer(c_int64_t), parameter :: FK_VMM_HIGH_FLOOR = 4294967296_c_int64_t
  integer(c_int64_t), parameter :: FK_VMM_MAGIC = int(z'564D4D50524F4F46', c_int64_t)

  ! Decoded from the LIVE entry, so "RW-" in a row means the CPU will refuse to
  ! execute there, not that somebody asked for that.
  character(kind=c_char, len=*), parameter :: FK_PERM_RWX  = "RWX" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PERM_RW   = "RW-" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PERM_RX   = "R-X" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PERM_RO   = "R--" // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PERM_NONE = "unmapped" // c_null_char

  ! Where the deliberate loads land.  VOLATILE and at module scope so the value
  ! is stored to memory somebody could read: a result nothing consumes is a
  ! result gcc may decide not to produce.
  integer(c_int64_t), volatile :: fk_probe = 0_c_int64_t

  ! Multiboot2 3.6 types, indexed by the type code; 0 catches anything the
  ! specification does not name, all of which is treated as reserved.
  character(kind=c_char, len=16), parameter :: FK_MEM_TYPE_NAME(0:5) = &
       [ character(kind=c_char, len=16) :: &
         "UNKNOWN"      // c_null_char, &
         "AVAILABLE"    // c_null_char, &
         "RESERVED"     // c_null_char, &
         "ACPI-RECLAIM" // c_null_char, &
         "ACPI-NVS"     // c_null_char, &
         "BADRAM"       // c_null_char ]

  ! How many frames the verification subroutine takes and gives back.
  integer(c_int32_t), parameter :: FK_PMM_TEST_PAGES = 5_c_int32_t

  ! Enough to push the scan cursor out of the bitmap word the first frame is
  ! in.  64 frames to a word, so anything over 64 crosses at least one boundary
  ! from any start; 96 leaves margin without costing a visible amount of boot.
  integer(c_int32_t), parameter :: FK_PMM_CURSOR_PAGES = 96_c_int32_t

  ! WHICH fault kernel_main raises once the tables are up.  8 = #DF, which is
  ! the milestone: it is the only way to exercise the IST1 stack switch.  0 =
  ! #DE, which is NOT redundant -- #DF arrives with a CPU error code and so
  ! only reaches the ISR_ERR half of boot/interrupts.S, leaving the dummy-push
  ! half that roadmap 3.2's M1 mutation targets unexercised.  -1 is roadmap
  ! 3.4's: not a vector at all, but "drain the PMM until it refuses", which is
  ! the only way to watch the out-of-memory panic actually fire.  A PARAMETER,
  ! so the branches not taken are folded away rather than shipped;
  ! tools/mutate-phase3.sh seds this line and rebuilds to run the other gates.
  integer(c_int32_t), parameter :: FK_FAULT_MODE = -5_c_int32_t
  integer(c_int32_t), parameter :: FK_FAULT_PMM_OOM = -1_c_int32_t
  ! roadmap 3.5's two.  Both are page faults, and they are NOT one test twice:
  ! the guard page proves an address INSIDE the image resolves to nothing, and
  ! the identity probe proves an address that resolved a moment ago no longer
  ! does.  CR2 in the panic dump is what tells them apart.
  integer(c_int32_t), parameter :: FK_FAULT_GUARD = -2_c_int32_t
  integer(c_int32_t), parameter :: FK_FAULT_IDMAP = -3_c_int32_t
  ! And the one that took an adversarial reading to notice was missing. CR0.WP
  ! is the bit that makes a read-only PTE mean anything to the only ring this
  ! kernel has, and it fails SILENTLY: delete the store in fk_mmu_arm and .text
  ! is still mapped R-X, vmm_verify_image still returns 0, the permission column
  ! still reads R-X, and a kernel store to .text simply succeeds. Every other
  ! half of the permission model announces its own failure -- a set NX bit
  ! without EFER.NXE faults on the first access -- so this is the only one that
  ! needed a fault of its own. ERR 0x3 is the whole assertion: bit 0 present,
  ! bit 1 write, i.e. a PROTECTION violation and not a missing page.
  integer(c_int32_t), parameter :: FK_FAULT_WP = -4_c_int32_t
  ! roadmap 3.2b's, and the SHIPPED one: raise nothing, park in fk_cpu_idle with
  ! IF set and go on servicing the timer.  It is the only value of this
  ! parameter under which kernel_main does not end in a register dump, which is
  ! the entire content of the milestone.
  integer(c_int32_t), parameter :: FK_FAULT_NONE = -5_c_int32_t

  ! Roadmap 1.4: a SOFTWARE panic.  Every other value here reaches the dump
  ! by making the CPU fault, because a register dump is only evidence if the
  ! registers are real.  This one deliberately does not: it is the path a
  ! subsystem takes when it has nothing to report but a reason.
  integer(c_int32_t), parameter :: FK_FAULT_PANIC = -6_c_int32_t

  ! How many ticks past the starting count the proof loop waits for.  ONE would
  ! be satisfied by a kernel that never sends an EOI: the 8259 delivers a first
  ! interrupt and then holds its in-service bit forever, so "it ticked once" and
  ! "the interrupt controller is wedged" are the same observation.
  integer(c_int64_t), parameter :: FK_TICK_TARGET = 3_c_int64_t

  ! And a bound on the wait, so a kernel that never ticks says so instead of
  ! hanging.  At 100 Hz the target is 30 ms; this is several seconds of spinning
  ! under KVM, i.e. two orders of magnitude of slack.
  integer(c_int64_t), parameter :: FK_TICK_SPIN_LIMIT = 2000000000_c_int64_t

  ! RFLAGS bit 9.
  integer(c_int64_t), parameter :: FK_RFLAGS_IF = 512_c_int64_t

  ! BOTH operands are volatile, and that is not belt and braces: with a literal
  ! numerator gcc rewrites 1/x into a compare against +-1 and emits no DIV at
  ! all, so the fault this milestone exists to raise never happens.  Module
  ! scope keeps the values inspectable in guest memory.
  integer(c_int32_t), volatile :: fk_dividend = 1_c_int32_t
  integer(c_int32_t), volatile :: fk_divisor  = 0_c_int32_t
  integer(c_int32_t), volatile :: fk_quotient = 0_c_int32_t

  interface
    ! Parks this CPU permanently (CLI; HLT) and never returns.  In boot/boot.S,
    ! because a privileged CPU-control instruction has no Fortran spelling.
    subroutine fk_cpu_halt() bind(c, name="fk_cpu_halt")
      implicit none
    end subroutine fk_cpu_halt

    ! Points RSP at nothing and pushes.  boot/faultgen.S.  Never returns: the
    ! next thing to execute is the #DF gate.
    subroutine fk_smash_stack() bind(c, name="fk_smash_stack")
      implicit none
    end subroutine fk_smash_stack

    ! INT3.  boot/faultgen.S.  Vector 3 is installed, so this reaches the same
    ! catcher every hardware fault does and the register dump is the machine's.
    subroutine fk_raise_bp() bind(c, name="fk_raise_bp")
      implicit none
    end subroutine fk_raise_bp

    ! A load and a store the optimiser is not allowed to see.  boot/faultgen.S.
    function fk_peek64(addr) result(v) bind(c, name="fk_peek64")
      import :: c_int64_t
      implicit none
      integer(c_int64_t), intent(in), value :: addr
      integer(c_int64_t) :: v
    end function fk_peek64

    subroutine fk_poke64(addr, v) bind(c, name="fk_poke64")
      import :: c_int64_t
      implicit none
      integer(c_int64_t), intent(in), value :: addr, v
    end subroutine fk_poke64

    ! linker.ld's __boot_stack_bottom; boot/ksyms.S.  The guard page is the
    ! frame directly below it, so this is where the deliberate #PF aims.
    function fk_boot_stack_bottom() result(a) bind(c, name="fk_boot_stack_bottom")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_boot_stack_bottom

    function fk_text_start() result(a) bind(c, name="fk_text_start")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_text_start

    function fk_text_end() result(a) bind(c, name="fk_text_end")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: a
    end function fk_text_end

    ! STI, and RFLAGS read back afterwards rather than assumed.  boot/interrupts.S.
    subroutine fk_irq_enable() bind(c, name="fk_irq_enable")
      implicit none
    end subroutine fk_irq_enable

    function fk_read_rflags() result(v) bind(c, name="fk_read_rflags")
      import :: c_int64_t
      implicit none
      integer(c_int64_t) :: v
    end function fk_read_rflags

    ! fk_cpu_halt's opposite: parks the CPU with IF SET, so the timer goes on
    ! firing and a reader outside the guest can watch fk_tick_count advance.
    subroutine fk_cpu_idle() bind(c, name="fk_cpu_idle")
      implicit none
    end subroutine fk_cpu_idle
  end interface

contains

  ! roadmap 3.4's verification subroutine.  Prints the map the loader reported,
  ! then exercises the allocator and prints one verdict per property.  Each
  ! verdict is a line tools/qemu-boot-test.sh greps for, and each has a FAIL
  ! twin in the gate's reject list -- printing a verdict nobody refuses would
  ! only move the assertion inside the thing being asserted.
  !
  ! mbi is taken as an argument for the locked-free probe below: freeing the
  ! frame the loader's own structure sits in must be REFUSED, and this is the
  ! one such address kernel_main already holds.
  subroutine pmm_verify(mbi)
    implicit none
    integer(c_int64_t), intent(in) :: mbi
    integer(c_int32_t) :: i, j, n, t
    integer(c_int64_t) :: b, l, base
    integer(c_int64_t) :: pg(FK_PMM_TEST_PAGES), again(FK_PMM_TEST_PAGES)
    integer(c_int64_t) :: held(FK_PMM_CURSOR_PAGES)
    logical :: ok

    call serial_print_string(FK_PMM_HEADER)
    n = pmm_region_count()
    do i = 1_c_int32_t, n
       b = pmm_region_base(i)
       l = pmm_region_len(i)
       t = pmm_region_type(i)
       call serial_print_string(FK_PMM_ROW)
       call serial_print_hex(int(i, c_int64_t), 2_c_int32_t)
       call serial_print_string(FK_PMM_SP)
       call serial_print_string(FK_PMM_0X)
       call serial_print_hex(b, 16_c_int32_t)
       call serial_print_string(FK_PMM_SP)
       call serial_print_string(FK_PMM_0X)
       ! END, not length: the specification reports a length, but every question
       ! asked of a map -- does it hold this frame, does it abut the next region
       ! -- is asked about the end.
       call serial_print_hex(b + l, 16_c_int32_t)
       call serial_print_string(FK_PMM_SP)
       if (t >= 1_c_int32_t .and. t <= 5_c_int32_t) then
          call serial_print_string(FK_MEM_TYPE_NAME(t))
       else
          call serial_print_string(FK_MEM_TYPE_NAME(0))
       end if
       call serial_print_string(FK_NL)
    end do

    call serial_print_string(FK_PMM_TOTALS)
    call serial_print_hex(pmm_total_pages(), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(pmm_free_pages(), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(pmm_ignored_bytes(), 16_c_int32_t)
    call serial_print_string(FK_NL)

    ! roadmap 3.4's "safety & boundaries": nothing the loader called reserved,
    ! ACPI, NVS or defective may be free, and neither may this kernel's own
    ! image or the loader's structure.
    if (pmm_verify_reserved() == 0_c_int64_t) then
       call serial_print_string(FK_PMM_RSVD_OK)
    else
       call serial_print_string(FK_PMM_RSVD_BAD)
    end if

    if (pmm_verify_kernel_locked() == 0_c_int64_t) then
       call serial_print_string(FK_PMM_LOCK_OK)
    else
       call serial_print_string(FK_PMM_LOCK_BAD)
    end if

    ! Five frames.  Contiguity is not a promise the interface makes -- it is
    ! what a first-fit scan over a bitmap with no holes in it yet MUST produce,
    ! so its absence says the scan or the bit-setting is wrong.
    ok = .true.
    do i = 1_c_int32_t, FK_PMM_TEST_PAGES
       pg(i) = pmm_alloc_page()
       call serial_print_string(FK_PMM_ROW)
       call serial_print_string(FK_PMM_ALLOC)
       call serial_print_hex(pg(i), 16_c_int32_t)
       call serial_print_string(FK_NL)
       ! WHAT THE ALLOCATOR ACTUALLY PROMISES: a distinct, page-aligned frame
       ! that was free.  NOT contiguity -- first-fit returns adjacent frames
       ! only where the map leaves adjacent frames free, which is a fact about
       ! the firmware and not about pmm_alloc_page.  The UEFI map puts
       ! LoaderData at 0x1000 and again across 0x3000..0xC000, so the first five
       ! frames it yields are 2, 12, 13, 14, 15 -- correct, and not contiguous.
       if (pg(i) == 0_c_int64_t) ok = .false.
       if (iand(pg(i), FK_PMM_PAGE_SIZE - 1_c_int64_t) /= 0_c_int64_t) &
            ok = .false.
       do j = 1_c_int32_t, i - 1_c_int32_t
          if (pg(j) == pg(i)) ok = .false.
       end do
    end do
    if (ok) then
       call serial_print_string(FK_PMM_ALLOC_OK)
    else
       call serial_print_string(FK_PMM_ALLOC_BAD)
    end if

    ! Give them back and take them again.  The SAME five addresses is the
    ! evidence: a free that clears the bit but leaves the scan cursor above it
    ! reports success and never hands the frame out again.
    ok = .true.
    do i = 1_c_int32_t, FK_PMM_TEST_PAGES
       if (pmm_free_page(pg(i)) /= FK_PMM_OK) ok = .false.
    end do
    do i = 1_c_int32_t, FK_PMM_TEST_PAGES
       again(i) = pmm_alloc_page()
       if (again(i) /= pg(i)) ok = .false.
    end do
    if (ok) then
       call serial_print_string(FK_PMM_RECLAIM_OK)
    else
       call serial_print_string(FK_PMM_RECLAIM_BAD)
    end if

    ! The three refusals, then hand everything back so the allocator is left
    ! exactly as pmm_init produced it.
    ok = .true.
    if (pmm_free_page(again(1)) /= FK_PMM_OK)            ok = .false.
    if (pmm_free_page(again(1)) /= FK_PMM_E_DOUBLE_FREE) ok = .false.
    if (pmm_free_page(again(2) + 8_c_int64_t) /= FK_PMM_E_UNALIGNED) ok = .false.
    ! The frame the loader's structure lives in.  Rounded down because the MBI
    ! is 8-byte aligned and nothing more; an unaligned address would be refused
    ! for the wrong reason and prove nothing about the lock.
    if (pmm_free_page(iand(mbi, not(FK_PMM_PAGE_SIZE - 1_c_int64_t))) &
        /= FK_PMM_E_LOCKED) ok = .false.
    do i = 2_c_int32_t, FK_PMM_TEST_PAGES
       if (pmm_free_page(again(i)) /= FK_PMM_OK) ok = .false.
    end do
    if (ok) then
       call serial_print_string(FK_PMM_GUARD_OK)
    else
       call serial_print_string(FK_PMM_GUARD_BAD)
    end if

    ! THE CHECK THE FIVE-FRAME TEST ABOVE CANNOT MAKE, and it took a mutation
    ! that survived the gate to notice.  Five consecutive frames all live in
    ! ONE 64-bit bitmap word, so the scan cursor never leaves it: a free that
    ! forgets to rewind the cursor still finds them, and "reclaimed the same 5
    ! frames" prints PASS.  Take enough frames to move the cursor into another
    ! word first, and only then ask for the first one back.
    ok = .true.
    held(1) = pmm_alloc_page()
    base = held(1)
    if (base == 0_c_int64_t) ok = .false.
    do i = 2_c_int32_t, FK_PMM_CURSOR_PAGES
       held(i) = pmm_alloc_page()
       if (held(i) == 0_c_int64_t) ok = .false.
    end do
    if (pmm_free_page(base) /= FK_PMM_OK) ok = .false.
    if (pmm_alloc_page() /= base) ok = .false.
    ! The addresses are REMEMBERED, not computed from base.  A first-fit walk
    ! over 96 frames is contiguous only where the map leaves 96 free frames in
    ! a row: the UEFI map fragments the low region, so a computed address lands
    ! on a locked frame and the free refuses -- failing a verdict about the
    ! scan cursor for a reason that has nothing to do with the cursor.
    do i = 1_c_int32_t, FK_PMM_CURSOR_PAGES
       if (pmm_free_page(held(i)) /= FK_PMM_OK) ok = .false.
    end do
    if (ok) then
       call serial_print_string(FK_PMM_CURSOR_OK)
    else
       call serial_print_string(FK_PMM_CURSOR_BAD)
    end if
  end subroutine pmm_verify

  ! Take frames until the allocator refuses, then panic through a real INT3 so
  ! the register dump in fk_idt_m is the machine's own.  Only reachable when
  ! FK_FAULT_MODE is FK_FAULT_PMM_OOM; the shipped image folds it away.
  subroutine pmm_drain_to_oom()
    implicit none
    integer(c_int64_t) :: addr, taken, bound

    call serial_print_string(FK_PMM_DRAIN)
    taken = 0_c_int64_t
    ! Bounded, not `do forever`: an allocator that computes an address but
    ! forgets to set the bit hands out the same frame for ever, and an
    ! unbounded loop turns that into a machine that says nothing at all
    ! instead of a gate that fails.  It cost an afternoon on the host suite
    ! to learn that -- see HE in docs/HARNESS-VALIDATION-PHASE3.md.
    bound = pmm_total_pages() + 1_c_int64_t
    do while (taken < bound)
       addr = pmm_alloc_page()
       if (addr == 0_c_int64_t) exit
       taken = taken + 1_c_int64_t
    end do

    call serial_print_string(FK_PMM_OOM_HDR)
    call serial_print_string(FK_PMM_TAKEN)
    call serial_print_hex(taken, 16_c_int32_t)
    call serial_print_string(FK_PMM_BEFORE)
    call serial_print_string(FK_PMM_TOTALS)
    call serial_print_hex(pmm_total_pages(), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(pmm_free_pages(), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(pmm_ignored_bytes(), 16_c_int32_t)
    call serial_print_string(FK_NL)
    call fk_raise_bp()
  end subroutine pmm_drain_to_oom

  subroutine print_perm(e)
    implicit none
    integer(c_int64_t), intent(in) :: e

    if (e == 0_c_int64_t) then
       call serial_print_string(FK_PERM_NONE)
    else if (iand(e, FK_PTE_RW) /= 0_c_int64_t) then
       if (iand(e, FK_PTE_NX) /= 0_c_int64_t) then
          call serial_print_string(FK_PERM_RW)
       else
          call serial_print_string(FK_PERM_RWX)
       end if
    else if (iand(e, FK_PTE_NX) /= 0_c_int64_t) then
       call serial_print_string(FK_PERM_RO)
    else
       call serial_print_string(FK_PERM_RX)
    end if
  end subroutine print_perm

  ! roadmap 3.5's verification, and it runs BEFORE anything reaches CR3.  Every
  ! address and every permission below is read back out of the hierarchy that
  ! is about to become live, so a row states what the CPU will do rather than
  ! what this kernel asked for -- and a kernel that mapped its own .text wrong
  ! gets to SAY so, instead of triple-faulting into a silent reboot.
  subroutine vmm_report()
    implicit none
    integer(c_int32_t) :: i
    integer(c_int64_t) :: v, bad

    call serial_print_string(FK_VMM_HDR)
    do i = 1_c_int32_t, FK_VMM_SECTIONS
       v = vmm_section_start(i)
       call serial_print_string(FK_VMM_ROW)
       call serial_print_string(FK_VMM_SEC_NAME(i))
       call serial_print_string(FK_PMM_SP)
       call serial_print_string(FK_PMM_0X)
       call serial_print_hex(v, 16_c_int32_t)
       call serial_print_string(FK_PMM_SP)
       call serial_print_string(FK_PMM_0X)
       call serial_print_hex(vmm_phys_of(v), 16_c_int32_t)
       call serial_print_string(FK_PMM_SP)
       call print_perm(vmm_translate(v))
       call serial_print_string(FK_NL)
    end do

    call serial_print_string(FK_VMM_TOTALS)
    call serial_print_hex(vmm_pml4_phys(), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(vmm_table_frames(), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(vmm_physmap_top(), 16_c_int32_t)
    call serial_print_string(FK_NL)

    if (vmm_nx_enabled() /= 0_c_int32_t) then
       call serial_print_string(FK_VMM_NX_ON)
    else
       call serial_print_string(FK_VMM_NX_OFF)
    end if

    ! Every page of the image, not just the first of each section: a section
    ! whose second page was skipped has a perfectly good first row above.
    bad = vmm_verify_image()
    if (bad == 0_c_int64_t) then
       call serial_print_string(FK_VMM_MAP_OK)
    else
       call serial_print_string(FK_VMM_MAP_BAD)
       call serial_print_hex(bad, 16_c_int32_t)
       call serial_print_string(FK_NL)
    end if

    if (vmm_translate(vmm_guard_page()) == 0_c_int64_t) then
       call serial_print_string(FK_VMM_GUARD_OK)
    else
       call serial_print_string(FK_VMM_GUARD_BAD)
    end if
  end subroutine vmm_report

  ! roadmap 1.2b, in the one order that works: CR3, then the descriptor-table
  ! reload while the identity window is still live, then the unmap, then the
  ! TLB flush that makes the unmap take effect.  The read of physical 1 MiB in
  ! the middle is the evidence the window WAS live in the new hierarchy -- the
  ! value is this image's own Multiboot2 magic -- so the verdict below it is a
  ! before-and-after and not just an absence.
  subroutine vmm_handoff()
    implicit none
    integer(c_int64_t) :: hi, back, flags
    integer(c_int32_t) :: st

    call vmm_activate()

    call serial_print_string(FK_VMM_CR3)
    call serial_print_hex(vmm_read_cr3(), 16_c_int32_t)
    call serial_print_string(FK_NL)

    call serial_print_string(FK_VMM_ID_LIVE)
    call serial_print_hex(fk_peek64(FK_PHYS_1MIB), 16_c_int32_t)
    call serial_print_string(FK_NL)

    call vmm_drop_identity()
    if (vmm_translate(FK_PHYS_1MIB) == 0_c_int64_t) then
       call serial_print_string(FK_VMM_ID_DEAD_OK)
    else
       call serial_print_string(FK_VMM_ID_DEAD_BAD)
    end if

    ! roadmap 3.4's closing debt: a frame the old 1 GiB window could not reach,
    ! mapped at a scratch address and then read back through the linear map at
    ! a DIFFERENT one.  Two virtual addresses agreeing on one physical frame is
    ! what makes this a mapping rather than a store to whatever was there.
    hi = pmm_alloc_page_from(FK_VMM_HIGH_FLOOR)
    if (hi == 0_c_int64_t) then
       call serial_print_string(FK_VMM_HIGH_NONE)
       return
    end if
    call serial_print_string(FK_VMM_ROW)
    call serial_print_string(FK_PMM_ALLOC)
    call serial_print_hex(hi, 16_c_int32_t)
    call serial_print_string(FK_NL)

    ! The verdict below says "above 4 GiB", so the FLOOR is checked rather than
    ! assumed. pmm_alloc_page_from is the newest code in the PMM; if its first
    ! word/bit arithmetic were off by anything it would return a low frame, the
    ! round trip would still succeed, and this kernel would print a true
    ! sentence about the wrong frame.
    if (hi < FK_VMM_HIGH_FLOOR) then
       call serial_print_string(FK_VMM_HIGH_BAD)
       return
    end if

    flags = ior(FK_PTE_P, FK_PTE_RW)
    if (vmm_nx_enabled() /= 0_c_int32_t) flags = ior(flags, FK_PTE_NX)
    st = vmm_map_page(FK_VMM_SCRATCH, hi, flags)
    if (st /= FK_VMM_OK) then
       call serial_print_string(FK_VMM_HIGH_BAD)
       return
    end if

    call fk_poke64(FK_VMM_SCRATCH, FK_VMM_MAGIC)
    back = fk_peek64(vmm_phys_to_virt(hi))
    if (back == FK_VMM_MAGIC .and. vmm_phys_of(FK_VMM_SCRATCH) == hi) then
       call serial_print_string(FK_VMM_HIGH_OK)
    else
       call serial_print_string(FK_VMM_HIGH_BAD)
    end if
  end subroutine vmm_handoff

  ! roadmap 3.2b.  Everything above this point ran with IF clear, because until
  ! now nothing could survive an interrupt: there were 32 trampolines, all of
  ! them ending in a panic, and no IRETQ anywhere in the tree.
  !
  ! The order below is the only safe one.  Program the chip that will generate
  ! the interrupt, open the line on the chip that will deliver it, and set IF
  ! last -- and all three strictly after vmm_handoff, which rewrites CR3 and
  ! reloads the IDTR.  An interrupt taken in the middle of that would be
  ! delivered through whichever of the two tables the CPU had got to.
  !
  ! Returns 0 only if all four properties held.  kernel_main's headline is
  ! conditional on that, because "interrupts are live and the kernel is still
  ! running" is a VERDICT and not an announcement: printed unconditionally it
  ! appeared underneath this routine's own three FAIL lines in mutation M31,
  ! which is a kernel contradicting itself in the same log.
  ! --- roadmap 4.0: two kernel threads ---------------------------------------

  ! The thread bodies.  bind(c) so their addresses are ordinary symbols the
  ! scheduler can put in a frame's RIP, and they NEVER RETURN: a task that
  ! returns lands on the fake return address sched_spawn planted, which is
  ! fk_cpu_halt.
  !
  ! Each waits on fk_tick_count rather than spinning a counter, so what it is
  ! waiting for is the same clock that preempts it, and the two threads
  ! interleave at a rate a human reading COM1 can follow.
  subroutine thread_a() bind(c, name="thread_a")
    implicit none
    call thread_body(1_c_int32_t, FK_THREAD_A)
  end subroutine thread_a

  subroutine thread_b() bind(c, name="thread_b")
    implicit none
    call thread_body(2_c_int32_t, FK_THREAD_B)
  end subroutine thread_b

  subroutine thread_body(slot, mark)
    implicit none
    integer(c_int32_t), intent(in) :: slot
    character(kind=c_char, len=*), intent(in) :: mark
    integer(c_int64_t) :: due

    do
       due = fk_tick_count + FK_THREAD_PERIOD
       ! A plain spin, and it is deliberate: this is the loop the timer
       ! interrupt has to preempt for any of this to work, so replacing it with
       ! HLT would hide the very thing being demonstrated.
       do while (fk_tick_count < due)
       end do

       ! The counter is bumped by the THREAD, so it is evidence the thread's
       ! own instructions executed and not that the scheduler chose it.
       fk_task_runs(slot + 1_c_int32_t) = fk_task_runs(slot + 1_c_int32_t) + 1_c_int64_t
       ! THE CONSOLE AND NOT COM1, and that is not a preference.  console_write
       ! runs with IF clear, so two threads cannot interleave inside it; the
       ! serial driver has no such bracket, and the boot thread is using it.
       ! A thread byte landing in the middle of a line the boot gate greps for
       ! would be a flake nobody could reproduce.
       call console_write(mark, 2_c_int32_t)
    end do
  end subroutine thread_body

  ! roadmap 4.0's verification.  It runs on task 1 -- the boot thread -- and the
  ! two counters it waits on are incremented by the other two, so the wait can
  ! only end if a context switch really happened and really came back.
  function sched_bringup() result(status)
    implicit none
    integer(c_int32_t) :: status
    integer(c_int32_t) :: a, b
    integer(c_int64_t) :: deadline

    call serial_print_string(FK_SCHED_START)
    status = sched_init()
    if (status /= 0_c_int32_t) return

    a = sched_spawn(transfer(c_funloc(thread_a), 0_c_int64_t))
    b = sched_spawn(transfer(c_funloc(thread_b), 0_c_int64_t))
    if (a < 0_c_int32_t .or. b < 0_c_int32_t) then
       call serial_print_string(FK_SCHED_SPAWN_BAD)
       call serial_print_hex(int(min(a, b), c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
       status = -1_c_int32_t
       return
    end if

    call serial_print_string(FK_SCHED_SPAWNED)
    call serial_print_hex(int(sched_tasks(), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(sched_current(), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_NL)

    call sched_start()
    call serial_print_string(FK_SCHED_LIVE)

    ! Wait for BOTH to have run at least twice.  Once each would be satisfied
    ! by a scheduler that switches away and never comes back -- this thread
    ! would still be running to print the verdict, but only because the timer
    ! kept returning to it by luck of the round robin.
    deadline = fk_tick_count + FK_SCHED_WAIT_TICKS
    do while (fk_tick_count < deadline)
       if (fk_task_runs(2) >= 2_c_int64_t .and. fk_task_runs(3) >= 2_c_int64_t) exit
    end do

    if (fk_task_runs(2) >= 2_c_int64_t .and. fk_task_runs(3) >= 2_c_int64_t) then
       call serial_print_string(FK_SCHED_RAN)
       call serial_print_hex(fk_sched_switches, 8_c_int32_t)
       call serial_print_string(FK_PMM_SLASH)
       call serial_print_hex(fk_task_runs(2), 8_c_int32_t)
       call serial_print_string(FK_PMM_SLASH)
       call serial_print_hex(fk_task_runs(3), 8_c_int32_t)
       call serial_print_string(FK_NL)
       status = 0_c_int32_t
    else
       call serial_print_string(FK_SCHED_STUCK)
       status = -1_c_int32_t
    end if
  end function sched_bringup

  ! --- roadmap 4.0: the heap ------------------------------------------------

  ! Where the heap's pages come from.  fk_heap_m calls this and knows nothing
  ! else about the machine: it asks for BYTES immediately above what it already
  ! has, and gets back the address they landed at or 0.
  !
  ! TWO PHASES, AND THE REASON IS THAT THERE IS NO vmm_unmap.  Allocating a
  ! frame and mapping it one page at a time would, on a mid-way failure, leave
  ! pages mapped that the heap never learns about and frames the PMM has handed
  ! out that nothing can return -- while still reporting failure.  Every frame
  ! is therefore taken first, and only a complete set is mapped.
  function heap_sbrk(bytes) result(virt) bind(c, name="heap_sbrk")
    implicit none
    integer(c_int64_t), intent(in), value :: bytes
    integer(c_int64_t) :: virt
    integer(c_int64_t) :: pages, i
    integer(c_int32_t) :: st

    virt = 0_c_int64_t
    if (bytes <= 0_c_int64_t) return
    pages = (bytes + FK_PMM_PAGE_SIZE - 1_c_int64_t) / FK_PMM_PAGE_SIZE
    ! The staging array is the cap, stated rather than discovered: a kmalloc
    ! bigger than FK_SBRK_MAX_PAGES pages is refused instead of half-served.
    if (pages > int(FK_SBRK_MAX_PAGES, c_int64_t)) return

    do i = 1_c_int64_t, pages
       sbrk_frames(int(i, c_int32_t)) = pmm_alloc_page()
       if (sbrk_frames(int(i, c_int32_t)) == 0_c_int64_t) then
          ! Give back what was taken.  A failed growth must cost nothing.
          call sbrk_unwind(i - 1_c_int64_t)
          return
       end if
    end do

    do i = 1_c_int64_t, pages
       st = vmm_map_page(heap_next + (i - 1_c_int64_t) * FK_PMM_PAGE_SIZE, &
                         sbrk_frames(int(i, c_int32_t)), &
                         ior(ior(FK_PTE_P, FK_PTE_RW), FK_PTE_NX))
       if (st /= FK_VMM_OK) then
          ! The frames are still ours to give back; the pages already mapped
          ! are left mapped and simply not advertised, because unmapping is a
          ! roadmap 3.5 operation that does not exist.
          call sbrk_unwind(pages)
          return
       end if
    end do

    virt      = heap_next
    heap_next = heap_next + pages * FK_PMM_PAGE_SIZE
  end function heap_sbrk

  subroutine sbrk_unwind(n)
    implicit none
    integer(c_int64_t), intent(in) :: n
    integer(c_int64_t) :: i
    integer(c_int32_t) :: st

    do i = 1_c_int64_t, n
       st = pmm_free_page(sbrk_frames(int(i, c_int32_t)))
    end do
  end subroutine sbrk_unwind

  ! roadmap 4.0's verification, on the same terms as pmm_verify: every property
  ! is checked against the heap's own structure after the fact, and each PASS
  ! line has a FAIL twin the boot gate refuses.
  function heap_bringup() result(status)
    implicit none
    integer(c_int32_t) :: status
    integer(c_int32_t) :: i, j, bad
    integer(c_int64_t) :: p(FK_HEAP_PROBES), sz, before_bad, v

    call serial_print_string(FK_HEAP_START)
    status = heap_init()
    if (status /= FK_HEAP_OK) return

    ! Sizes that straddle every interesting boundary: below the minimum block,
    ! exactly one alignment unit, one byte over, and past the growth chunk.
    do i = 1_c_int32_t, FK_HEAP_PROBES
       p(i) = kmalloc(FK_HEAP_SIZES(i))
    end do
    if (p(1) == 0_c_int64_t) then
       call serial_print_string(FK_HEAP_SBRK_BAD)
       status = -1_c_int32_t
       return
    end if

    call serial_print_string(FK_HEAP_BASE)
    call serial_print_hex(heap_base(), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(heap_top(), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(fk_heap_stat(FK_HS_MAPPED), 16_c_int32_t)
    call serial_print_string(FK_NL)

    ! Alignment, and that no two live blocks overlap.  Overlap is checked
    ! against the size the ALLOCATOR reports for each pointer, not against the
    ! size that was asked for: a block rounded up and then handed out twice
    ! passes a request-sized comparison.
    bad = 0_c_int32_t
    do i = 1_c_int32_t, FK_HEAP_PROBES
       if (p(i) == 0_c_int64_t) then
          bad = bad + 1_c_int32_t
          cycle
       end if
       if (iand(p(i), FK_HEAP_ALIGN - 1_c_int64_t) /= 0_c_int64_t) &
            bad = bad + 1_c_int32_t
       if (heap_size_of(p(i)) < FK_HEAP_SIZES(i)) bad = bad + 1_c_int32_t
       do j = i + 1_c_int32_t, FK_HEAP_PROBES
          if (p(j) == 0_c_int64_t) cycle
          if (p(i) < p(j) + heap_size_of(p(j)) .and. &
              p(j) < p(i) + heap_size_of(p(i))) bad = bad + 1_c_int32_t
       end do
    end do
    if (bad == 0_c_int32_t) then
       call serial_print_string(FK_HEAP_ALIGN_OK)
    else
       call serial_print_string(FK_HEAP_ALIGN_BAD)
    end if

    ! Fill each block with a value derived from its index, then read them all
    ! back AFTER every write: a block that overlaps its neighbour holds the
    ! neighbour's pattern by the time the last one is written.
    do i = 1_c_int32_t, FK_HEAP_PROBES
       call fk_poke64(p(i), FK_HEAP_PATTERN + int(i, c_int64_t))
       sz = heap_size_of(p(i))
       if (sz >= 16_c_int64_t) &
            call fk_poke64(p(i) + sz - 8_c_int64_t, FK_HEAP_PATTERN - int(i, c_int64_t))
    end do
    bad = 0_c_int32_t
    do i = 1_c_int32_t, FK_HEAP_PROBES
       if (fk_peek64(p(i)) /= FK_HEAP_PATTERN + int(i, c_int64_t)) &
            bad = bad + 1_c_int32_t
       sz = heap_size_of(p(i))
       if (sz >= 16_c_int64_t) then
          if (fk_peek64(p(i) + sz - 8_c_int64_t) /= &
              FK_HEAP_PATTERN - int(i, c_int64_t)) bad = bad + 1_c_int32_t
       end if
    end do
    if (bad == 0_c_int32_t) then
       call serial_print_string(FK_HEAP_PATTERN_OK)
    else
       call serial_print_string(FK_HEAP_PATTERN_BAD)
    end if

    ! kzalloc, into a block that was just freed and is therefore full of the
    ! pattern above -- which is the only way this test means anything.
    call kfree(p(2))
    v   = kzalloc(FK_HEAP_SIZES(2))
    bad = 0_c_int32_t
    if (v == 0_c_int64_t) then
       bad = 1_c_int32_t
    else
       do i = 0_c_int32_t, int(min(FK_HEAP_SIZES(2), 64_c_int64_t) / 8_c_int64_t, c_int32_t) - 1_c_int32_t
          if (fk_peek64(v + int(i, c_int64_t) * 8_c_int64_t) /= 0_c_int64_t) &
               bad = bad + 1_c_int32_t
       end do
    end if
    if (bad == 0_c_int32_t) then
       call serial_print_string(FK_HEAP_ZERO_OK)
    else
       call serial_print_string(FK_HEAP_ZERO_BAD)
    end if
    p(2) = v

    ! The guards.  A double free, a pointer that was never in the heap and a
    ! size that wrapped negative must all be REFUSED and COUNTED -- an
    ! allocator that quietly accepts any of them corrupts itself and reports
    ! the damage in an unrelated call.
    before_bad = fk_heap_stat(FK_HS_BADFREE)
    call kfree(p(1))
    call kfree(p(1))
    call kfree(heap_base() - 4096_c_int64_t)
    call kfree(p(3) + 1_c_int64_t)
    if (fk_heap_stat(FK_HS_BADFREE) == before_bad + 3_c_int64_t .and. &
        kmalloc(-1_c_int64_t) == 0_c_int64_t .and. &
        kmalloc(0_c_int64_t) == 0_c_int64_t) then
       call serial_print_string(FK_HEAP_GUARD_OK)
    else
       call serial_print_string(FK_HEAP_GUARD_BAD)
    end if
    p(1) = 0_c_int64_t

    ! Free everything still live, in an order that is not the allocation order,
    ! and require the heap to come back to ONE free block.  Freeing in order
    ! only ever exercises forward coalescing.
    do i = FK_HEAP_PROBES, 1_c_int32_t, -2_c_int32_t
       call kfree(p(i))
       p(i) = 0_c_int64_t
    end do
    do i = 1_c_int32_t, FK_HEAP_PROBES, 2_c_int32_t
       call kfree(p(i))
       p(i) = 0_c_int64_t
    end do

    if (heap_check() /= 0_c_int64_t) then
       call serial_print_string(FK_HEAP_CHECK_BAD)
       call serial_print_hex(heap_check(), 8_c_int32_t)
       call serial_print_string(FK_NL)
       status = -1_c_int32_t
       return
    end if
    call serial_print_string(FK_HEAP_CHECK_OK)
    call serial_print_hex(fk_heap_stat(FK_HS_BLOCKS), 8_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(fk_heap_stat(FK_HS_USED), 8_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(fk_heap_stat(FK_HS_FREE), 8_c_int32_t)
    call serial_print_string(FK_NL)

    if (fk_heap_stat(FK_HS_BLOCKS) == 1_c_int64_t .and. &
        fk_heap_stat(FK_HS_USED) == 0_c_int64_t) then
       call serial_print_string(FK_HEAP_COAL_OK)
       call serial_print_hex(fk_heap_stat(FK_HS_LARGEST), 16_c_int32_t)
       call serial_print_string(FK_NL)
    else
       call serial_print_string(FK_HEAP_COAL_BAD)
       call serial_print_hex(fk_heap_stat(FK_HS_BLOCKS), 8_c_int32_t)
       call serial_print_string(FK_NL)
    end if

    status = 0_c_int32_t
  end function heap_bringup

  ! roadmap 2.2 + 2.4.  Runs AFTER the higher-half handoff, because everything
  ! it does needs the VMM's hierarchy: the PAT write, the write-combining
  ! mapping and the alias check are all statements about tables the boot stub
  ! never built.  fb_probe already ran, before the identity window closed.
  !
  ! Returns 0 only if the renderer is armed on a real mapping.
  function fb_bringup() result(status)
    implicit none
    integer(c_int32_t) :: status
    integer(c_int64_t) :: base, bytes, entry
    integer(c_int32_t) :: st

    status = -1_c_int32_t
    ! THE MAGIC, NOT THE BASE.  fb_probe fills base, pitch, geometry and the
    ! masks BEFORE it validates them, and returns early on a mode it refuses --
    ! a non-RGB one, a depth that is not 32, a pitch narrower than the width --
    ! so a rejected framebuffer leaves a NON-ZERO base behind.  The magic is
    ! written last and only on acceptance, which is the only thing that means
    ! "the probe agreed to this".  Nothing hit it while the UEFI path had no
    ! tag 8 at all; the moment that path produces one, this is what stands
    ! between a refused mode and a renderer armed on it.
    if (fk_fb_info(FK_FB_TAG) /= FK_FB_MAGIC) return

    base  = fk_fb_info(FK_FB_BASE)
    bytes = fk_fb_info(FK_FB_BYTES)

    if (vmm_pat_arm() == 0_c_int32_t) then
       call serial_print_string(FK_FB_PAT_OK)
       call serial_print_hex(vmm_read_pat(), 16_c_int32_t)
       call serial_print_string(FK_FB_PAT_TAIL)
    else
       call serial_print_string(FK_FB_PAT_BAD)
    end if

    st = vmm_map_mmio(FK_VMM_MMIO, base, bytes, FK_VMM_WC)
    if (st /= FK_VMM_OK) then
       call serial_print_string(FK_FB_MAP_BAD)
       call serial_print_hex(int(st, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
       return
    end if
    call fb_note_mapping(FK_VMM_MMIO)

    ! Read back the LIVE entry rather than the flags that were asked for: PWT
    ! is what selects write-combining, and a mapping that lost it is a
    ! framebuffer nobody would notice was slow.
    entry = vmm_translate(FK_VMM_MMIO)
    call serial_print_string(FK_FB_PTE)
    call serial_print_hex(FK_VMM_MMIO, 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(vmm_phys_of(FK_VMM_MMIO), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(entry, 16_c_int32_t)
    call serial_print_string(FK_NL)

    ! The memory type, decoded from the LIVE entry rather than from the flags
    ! that were requested.  The addresses in the line above are machine
    ! specific and cannot be asserted; this is one bit and it is the bit that
    ! decides whether every glyph is a read-modify-write of a cache line
    ! nothing ever reads.
    if (iand(entry, FK_PTE_PWT) /= 0_c_int64_t .and. &
        iand(entry, FK_PTE_PCD) == 0_c_int64_t) then
       call serial_print_string(FK_FB_WC_OK)
    else
       call serial_print_string(FK_FB_WC_BAD)
    end if

    ! The aperture must be reachable ONE way.  A linear-map entry over the same
    ! frames would be write-back, and two memory types for one physical page is
    ! undefined behaviour, not a slow path.
    if (vmm_translate(vmm_phys_to_virt(base)) == 0_c_int64_t) then
       call serial_print_string(FK_FB_ALIAS_OK)
    else
       call serial_print_string(FK_FB_ALIAS_BAD)
    end if

    st = vga_init_framebuffer(FK_VMM_MMIO, &
                              int(fk_fb_info(FK_FB_WIDTH),  c_int32_t), &
                              int(fk_fb_info(FK_FB_HEIGHT), c_int32_t), &
                              int(fk_fb_info(FK_FB_PITCH),  c_int32_t))
    if (st /= 0_c_int32_t) then
       call serial_print_string(FK_FB_ARM_BAD)
       call serial_print_hex(int(st, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
       return
    end if
    call fb_test_bar()
    call serial_print_string(FK_FB_ARMED)

    ! The panic handler is told what white and red ARE on this framebuffer
    ! before anything can panic on it; it packs no channels of its own.
    call idt_set_panic_colors( &
         fb_pixel_pack(255_c_int32_t, 255_c_int32_t, 255_c_int32_t), &
         fb_pixel_pack(170_c_int32_t, 0_c_int32_t, 0_c_int32_t))

    status = console_bringup()
  end function fb_bringup

  ! roadmap 2.4's terminal.  The console owns every pixel row BELOW the status
  ! bar and scrolls only inside that band, so the four primaries the harness
  ! asserts survive a screen that has wrapped many times.
  function console_bringup() result(status)
    implicit none
    integer(c_int32_t) :: status

    status = console_init(vga_width(), vga_height(), FK_FB_BAR_H, &
                          fb_pixel_pack(FK_CON_FG_R, FK_CON_FG_G, FK_CON_FG_B), &
                          fb_pixel_pack(FK_CON_BG_R, FK_CON_BG_G, FK_CON_BG_B))
    if (status /= FK_CON_OK) then
       call serial_print_string(FK_CON_BAD)
       call serial_print_hex(int(status, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
       return
    end if

    call serial_print_string(FK_CON_READY)
    call serial_print_hex(int(console_cols(), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(console_rows(), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_NL)

    call console_write(FK_SCREEN_BANNER, 128_c_int32_t)
    call console_write(FK_SCREEN_GEOM, 32_c_int32_t)
    call console_print_hex(int(console_cols(), c_int64_t), 4_c_int32_t)
    call console_write(FK_SCREEN_X, 4_c_int32_t)
    call console_print_hex(int(console_rows(), c_int64_t), 4_c_int32_t)
    call console_write(FK_NL, 4_c_int32_t)

    status = 0_c_int32_t
  end function console_bringup

  ! Fill the console past its last row so it HAS to scroll, and price the last
  ! scroll in PIT ticks.  A write-combining framebuffer is read uncached, and a
  ! full-screen scroll reads and writes every visible byte -- so this is the
  ! most expensive thing the driver does, and the number is measured rather
  ! than asserted.  Runs after irq_bringup, which is what makes the clock run.
  subroutine console_scroll_probe()
    implicit none
    integer(c_int32_t) :: i, n
    integer(c_int64_t) :: t0, t1, before

    if (console_ready() == 0_c_int32_t) return

    before = fk_console_scrolls
    ! One more line than the console has rows, so the last one must scroll
    ! however far down the cursor already was.
    n = console_rows() + 1_c_int32_t
    do i = 1_c_int32_t, n
       call console_write(FK_SCREEN_GEOM, 32_c_int32_t)
       call console_print_hex(int(i, c_int64_t), 4_c_int32_t)
       call console_write(FK_NL, 4_c_int32_t)
    end do

    t0 = fk_tick_count
    call console_write(FK_NL, 4_c_int32_t)
    t1 = fk_tick_count

    if (fk_console_scrolls > before) then
       call serial_print_string(FK_CON_SCROLL)
       call serial_print_hex(fk_console_scrolls, 8_c_int32_t)
       call serial_print_string(FK_CON_SCROLL_TAIL)
       call serial_print_hex(t1 - t0, 8_c_int32_t)
       call serial_print_string(FK_CON_SCROLL_TICKS)
    else
       call serial_print_string(FK_CON_SCROLL_BAD)
    end if
  end subroutine console_scroll_probe

  ! The status bar, and the only thing on screen whose exact pixel values are
  ! known before a single glyph is drawn.  Four primaries rather than one
  ! colour: a renderer that reached memory but packed the channels wrong writes
  ! four DIFFERENT wrong words, and tools/qmp-sentinel.py recomputes all four
  ! from the masks the loader reported and compares them against a pmemsave.
  !
  ! Rows 0..FK_FB_BAR_H-1 belong to this bar for the life of the boot; the
  ! console (roadmap 2.4) starts below it and never scrolls through it.
  subroutine fb_test_bar()
    implicit none
    integer(c_int32_t) :: w, i
    integer(c_int32_t), parameter :: BLK = 64_c_int32_t

    w = int(fk_fb_info(FK_FB_WIDTH), c_int32_t)
    call vga_fill_rect(0_c_int32_t, 0_c_int32_t, w, FK_FB_BAR_H, &
                       fb_pixel_pack(0_c_int32_t, 0_c_int32_t, 0_c_int32_t))
    i = 255_c_int32_t
    call vga_fill_rect(0_c_int32_t,       0_c_int32_t, BLK, FK_FB_BAR_H, &
                       fb_pixel_pack(i, 0_c_int32_t, 0_c_int32_t))
    call vga_fill_rect(BLK,               0_c_int32_t, BLK, FK_FB_BAR_H, &
                       fb_pixel_pack(0_c_int32_t, i, 0_c_int32_t))
    call vga_fill_rect(2_c_int32_t * BLK, 0_c_int32_t, BLK, FK_FB_BAR_H, &
                       fb_pixel_pack(0_c_int32_t, 0_c_int32_t, i))
    call vga_fill_rect(3_c_int32_t * BLK, 0_c_int32_t, BLK, FK_FB_BAR_H, &
                       fb_pixel_pack(i, i, i))
    call vga_print_string(FK_FB_SIG, 16_c_int32_t, FK_FB_SIG_X, 0_c_int32_t, &
                          fb_pixel_pack(i, i, 0_c_int32_t))
  end subroutine fb_test_bar

  ! roadmap 3.3.  The base comes from IA32_APIC_BASE and NOT from the MADT:
  ! bits 51:12 carry it and bit 11 is the global enable, with no ACPI involved
  ! for the boot processor's own LAPIC.
  ! roadmap 4.1.  Runs AFTER the higher-half handoff, deliberately: the
  ! tables live in ACPI-reclaim memory, which the linear map covers, so no
  ! window has to be built and torn down for them.  Everything below the
  ! physmap top is reachable and anything at or above it is REFUSED rather
  ! than dereferenced -- on a 2 GiB machine the tables sit ~7 KiB under that
  ! top, so the check is load-bearing and not decoration.
  ! roadmap 3.x.  Takes a run, tags every frame in it through the linear map,
  ! and publishes where it is.  AFTER the heap, because heap_bringup wants the
  ! allocator in the state pmm_verify left it, and before the scheduler, for the
  ! reason everything else here runs before the scheduler: nothing in the PMM
  ! takes a lock.
  ! One function's identity, to COM1 and to the framebuffer.  The roadmap's
  ! validation sentence names the GOP display specifically, so the console copy
  ! is the deliverable and the serial one is what the gate greps.
  subroutine pcie_report(i)
    implicit none
    integer(c_int32_t), intent(in) :: i

    call serial_print_string(FK_PCIE_DEV)
    call serial_print_hex(int(pcie_bus(i), c_int64_t), 2_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(pcie_device(i), c_int64_t), 2_c_int32_t)
    call serial_print_string(FK_PCIE_DOT)
    call serial_print_hex(int(pcie_function(i), c_int64_t), 1_c_int32_t)
    call serial_print_string(FK_PCIE_SP)
    call serial_print_hex(int(pcie_vendor(i), c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(pcie_devid(i), c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PCIE_SP)
    call serial_print_hex(int(pcie_class(i), c_int64_t), 2_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(pcie_subclass(i), c_int64_t), 2_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(pcie_progif(i), c_int64_t), 2_c_int32_t)
    call serial_print_string(FK_NL)

    call console_print_hex(int(pcie_bus(i), c_int64_t), 2_c_int32_t)
    call console_print_hex(int(pcie_device(i), c_int64_t), 2_c_int32_t)
    call console_print_hex(int(pcie_function(i), c_int64_t), 1_c_int32_t)
    call console_print_hex(int(pcie_vendor(i), c_int64_t), 4_c_int32_t)
    call console_print_hex(int(pcie_devid(i), c_int64_t), 4_c_int32_t)
  end subroutine pcie_report

  ! roadmap 4.2.  AFTER acpi_bringup, which is what can find the table, and
  ! after ioapic_bringup, which lands the punch primitive this needs.
  subroutine pcie_bringup()
    implicit none
    integer(c_int64_t) :: mcfg_phys, mcfg_len, base, bytes, pte
    integer(c_int32_t) :: st, i, n

    fk_pcie_devs = 0_c_int64_t
    call serial_print_string(FK_PCIE_START)

    mcfg_phys = acpi_find(FK_SIG_MCFG)
    ! NOT A FAILURE.  A machine with no MCFG has no ECAM window, which is a
    ! fact about the machine: QEMU's default i440FX board emits four ACPI
    ! tables and none of them is this one.
    if (mcfg_phys == 0_c_int64_t) then
       call serial_print_string(FK_PCIE_NO_MCFG)
       return
    end if

    mcfg_len = acpi_table_length(mcfg_phys)
    st = mcfg_parse(vmm_phys_to_virt(mcfg_phys), int(mcfg_len, c_int32_t))
    if (st /= FK_MCFG_OK) then
       call serial_print_string(FK_PCIE_MCFG_BAD)
       call serial_print_hex(int(st, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
       return
    end if

    base  = mcfg_base(0_c_int32_t)
    bytes = mcfg_bytes(0_c_int32_t)
    call serial_print_string(FK_PCIE_WINDOW)
    call serial_print_hex(base, 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(mcfg_segment(0_c_int32_t), c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(mcfg_bus_start(0_c_int32_t), c_int64_t), 2_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(mcfg_bus_end(0_c_int32_t), c_int64_t), 2_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(bytes, 16_c_int32_t)
    call serial_print_string(FK_NL)

    st = vmm_punch_physmap(base, bytes)
    if (st /= FK_VMM_OK) then
       call serial_print_string(FK_PCIE_PUNCH_BAD)
       call serial_print_hex(int(st, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
       return
    end if

    ! 4 KiB at a time and there is no other option: vmm_map_page has no large
    ! page path and walk() refuses to shatter one.  256 MiB is 65536 entries
    ! and about 512 KiB of page tables out of a 24 GiB machine.
    st = vmm_map_mmio(FK_VMM_ECAM, base, bytes, FK_VMM_UC)
    if (st /= FK_VMM_OK) then
       call serial_print_string(FK_PCIE_MAP_BAD)
       call serial_print_hex(int(st, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
       return
    end if

    if (vmm_translate(FK_VMM_PHYSMAP + base) == 0_c_int64_t) then
       call serial_print_string(FK_PCIE_ALIAS_OK)
    else
       call serial_print_string(FK_PCIE_ALIAS_BAD)
    end if

    ! "Mapped" and "mapped UNCACHED" are different claims and the second is the
    ! one that matters: a cached mapping of configuration space reads a stale
    ! line for every device after the first.
    pte = vmm_translate(FK_VMM_ECAM)
    if (iand(pte, FK_PTE_PWT) /= 0_c_int64_t .and. &
        iand(pte, FK_PTE_PCD) /= 0_c_int64_t) then
       call serial_print_string(FK_PCIE_UC_OK)
    else
       call serial_print_string(FK_PCIE_UC_BAD)
    end if

    call pcie_set_window(FK_VMM_ECAM, mcfg_bus_start(0_c_int32_t), &
                         mcfg_bus_end(0_c_int32_t))
    n = pcie_scan()

    call serial_print_string(FK_PCIE_COUNT)
    call serial_print_hex(int(pcie_count(), c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(pcie_seen(), c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_NL)
    if (pcie_overflowed() /= 0_c_int32_t) &
         call serial_print_string(FK_PCIE_TRUNC)

    do i = 0_c_int32_t, pcie_count() - 1_c_int32_t
       call pcie_report(i)
    end do

    if (pcie_find_xhci() == FK_PCIE_NOT_FOUND .and. &
        pcie_find_nvme() == FK_PCIE_NOT_FOUND) &
         call serial_print_string(FK_PCIE_NONE_YET)

    fk_pcie_devs(0) = FK_PCIE_MAGIC
    fk_pcie_devs(1) = base
    fk_pcie_devs(2) = ior(shiftl(int(mcfg_bus_start(0_c_int32_t), c_int64_t), 8), &
                          int(mcfg_bus_end(0_c_int32_t), c_int64_t))
    fk_pcie_devs(3) = int(pcie_count(), c_int64_t)
    fk_pcie_devs(4) = int(pcie_seen(), c_int64_t)
    do i = 0_c_int32_t, min(pcie_count(), FK_PCIE_SLOTS) - 1_c_int32_t
       fk_pcie_devs(5 + i) = &
            ior(ior(shiftl(ior(ior(shiftl(int(pcie_bus(i), c_int64_t), 8), &
                                   shiftl(int(pcie_device(i), c_int64_t), 3)), &
                               int(pcie_function(i), c_int64_t)), 48), &
                    shiftl(int(pcie_vendor(i), c_int64_t), 32)), &
                ior(shiftl(int(pcie_devid(i), c_int64_t), 16), &
                    ior(shiftl(int(pcie_class(i), c_int64_t), 8), &
                        int(pcie_subclass(i), c_int64_t))))
    end do

    call xhci_bringup()
    call nvme_bringup()

    if (n > 0_c_int32_t) call serial_print_string(FK_PCIE_WALKED)
  end subroutine pcie_bringup

  ! Roadmap 4.2's debt, paid where 5.1 needs it: the controller cannot answer a
  ! register read without memory-space decode and cannot fetch a ring without
  ! bus mastering, and neither bit is set by firmware that never had a driver.
  !
  ! The COMMAND printed is the one READ BACK afterwards, not the one written --
  ! a device that refuses a bit must not be reported as having taken it.  INTx
  ! is deliberately left alone: disabling it before an MSI-X route exists
  ! leaves a controller that can raise nothing at all.
  subroutine xhci_bringup()
    implicit none
    integer(c_int32_t) :: i, cmd, fw, down, cap, cnt, bir, off
    integer(c_int64_t) :: bar

    i = pcie_find_xhci()
    if (i == FK_PCIE_NOT_FOUND) return

    fk_pcie_devs(FK_PCIE_W_XHCI) = &
         ior(ior(shiftl(int(pcie_bus(i), c_int64_t), 8), &
                 shiftl(int(pcie_device(i), c_int64_t), 3)), &
             int(pcie_function(i), c_int64_t))

    ! FIRMWARE HAS ALREADY DONE THIS ON THIS MACHINE.  SeaBIOS leaves the
    ! controller at COMMAND 0x0107, so a kernel that writes nothing reads back
    ! what a kernel that works reads back.  The two bits are therefore taken
    ! DOWN first and put back: a cleared bit is one only this kernel could
    ! have cleared, and the three values below are the whole proof.
    fw = pcie_command(i)
    down = pcie_cmd_disable(i)
    cmd = pcie_cmd_enable(i)
    fk_pcie_devs(FK_PCIE_W_CMD) = &
         ior(ior(int(iand(fw, int(z'FFFF', c_int32_t)), c_int64_t), &
                 shiftl(int(iand(down, int(z'FFFF', c_int32_t)), c_int64_t), 16)), &
             shiftl(int(iand(cmd, int(z'FFFF', c_int32_t)), c_int64_t), 32))

    call serial_print_string(FK_XHCI_CMD)
    call serial_print_hex(int(fw, c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(down, c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(cmd, c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_NL)

    if (.not. btest(down, FK_PCI_CMD_MEMORY_BIT) .and. &
        .not. btest(down, FK_PCI_CMD_MASTER_BIT) .and. &
        btest(cmd, FK_PCI_CMD_MEMORY_BIT) .and. &
        btest(cmd, FK_PCI_CMD_MASTER_BIT)) then
       call serial_print_string(FK_XHCI_CMD_OK)
    else
       call serial_print_string(FK_XHCI_CMD_BAD)
    end if

    bar = pcie_bar64(i, 0_c_int32_t)
    fk_pcie_devs(FK_PCIE_W_BAR) = bar
    call serial_print_string(FK_XHCI_BAR)
    call serial_print_hex(bar, 16_c_int32_t)
    call serial_print_string(FK_NL)

    cap = pcie_msix_at(i)
    if (cap == FK_PCIE_NOT_FOUND) then
       call serial_print_string(FK_XHCI_NO_MSIX)
       return
    end if
    cnt = pcie_msix_count(i)
    bir = pcie_msix_bir(i)
    off = pcie_msix_offset(i)
    fk_pcie_devs(FK_PCIE_W_MSIX) = &
         ior(ior(int(cap, c_int64_t), shiftl(int(cnt, c_int64_t), 16)), &
             shiftl(int(bir, c_int64_t), 32))
    fk_pcie_devs(FK_PCIE_W_TBL) = int(off, c_int64_t)

    call serial_print_string(FK_XHCI_MSIX)
    call serial_print_hex(int(cap, c_int64_t), 2_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(cnt, c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(bir, c_int64_t), 1_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(off, c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_NL)

    call xhci_route(i, bar, off)
  end subroutine xhci_bringup

  ! THE ROUTE (roadmap 5.1).  An MSI-X table entry is not configuration space:
  ! it lives in the device's own memory behind BAR0, so the BAR has to be taken
  ! out of the linear map and mapped strong-UC first -- the same treatment the
  ! LAPIC, the IOAPIC and the ECAM window get, and for the same reason.
  !
  ! ORDER, and every step of it is load bearing.  The IDT gate for the vector
  ! is already installed by idt_init, BEFORE anything here can be unmasked.
  ! Then: map, write the entry masked, unmask it, set MSIX_ENABLE, and only
  ! then take INTx away.  Reversing the last two leaves a window with no wire
  ! and no message.
  subroutine xhci_route(idx, bar, tbl_off)
    implicit none
    integer(c_int32_t), intent(in) :: idx, tbl_off
    integer(c_int64_t), intent(in) :: bar
    integer(c_int64_t) :: tbl
    integer(c_int32_t) :: st, addr, data, rb_addr, rb_data, rb_mask, ctrl, cmd

    if (bar == 0_c_int64_t) return

    st = vmm_punch_physmap(bar, FK_XHCI_WINDOW_BYTES)
    if (st == FK_VMM_OK) &
         st = vmm_map_mmio(FK_VMM_XHCI, bar, FK_XHCI_WINDOW_BYTES, FK_VMM_UC)
    if (st /= FK_VMM_OK) then
       call serial_print_string(FK_XHCI_MAP_BAD)
       call serial_print_hex(int(st, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
       return
    end if

    call serial_print_string(FK_XHCI_WINDOW)
    call serial_print_hex(FK_VMM_XHCI, 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(bar, 16_c_int32_t)
    call serial_print_string(FK_NL)

    tbl  = FK_VMM_XHCI + int(tbl_off, c_int64_t)
    addr = lapic_msi_addr(lapic_id(FK_VMM_LAPIC))
    data = lapic_msi_data(FK_VECTOR_MSI)
    st   = pcie_msix_entry_set(tbl, 0_c_int32_t, addr, 0_c_int32_t, data)
    if (st /= FK_PCIE_OK) return

    ! READ BACK OFF THE DEVICE, not out of what was written.  These are the
    ! first reads this kernel has ever taken from a BAR.
    rb_addr = pcie_msix_entry_read(tbl, 0_c_int32_t, FK_PCI_MSIX_E_ADDR_LO)
    rb_data = pcie_msix_entry_read(tbl, 0_c_int32_t, FK_PCI_MSIX_E_DATA)
    rb_mask = pcie_msix_entry_read(tbl, 0_c_int32_t, FK_PCI_MSIX_E_VCTRL)

    call serial_print_string(FK_XHCI_ROUTE)
    call serial_print_hex(int(rb_addr, c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(rb_data, c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(rb_mask, c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_NL)

    ctrl = pcie_msix_enable(idx)
    cmd  = pcie_intx_disable(idx)
    ! The entry as the DEVICE holds it: address in 31:0, data in 47:32, the
    ! mask bit in 48.  The host reads the same four dwords straight out of the
    ! device model and the two have to agree.
    fk_pcie_devs(FK_PCIE_W_MSG) = &
         ior(iand(int(rb_addr, c_int64_t), int(z'FFFFFFFF', c_int64_t)), &
             ior(shiftl(iand(int(rb_data, c_int64_t), &
                             int(z'FFFF', c_int64_t)), 32), &
                 shiftl(iand(int(rb_mask, c_int64_t), 1_c_int64_t), 48)))
    fk_pcie_devs(FK_PCIE_W_CTRL) = &
         ior(int(iand(ctrl, int(z'FFFF', c_int32_t)), c_int64_t), &
             shiftl(int(iand(cmd, int(z'FFFF', c_int32_t)), c_int64_t), 16))

    call serial_print_string(FK_XHCI_CTRL)
    call serial_print_hex(int(ctrl, c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(cmd, c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_NL)

    if (rb_addr == addr .and. rb_data == data .and. &
        rb_mask == 0_c_int32_t .and. &
        btest(ctrl, FK_PCI_MSIX_CTRL_ENABLE_BIT) .and. &
        .not. btest(ctrl, FK_PCI_MSIX_CTRL_MASKALL_BIT) .and. &
        btest(cmd, FK_PCI_CMD_INTX_DISABLE_BIT)) then
       call serial_print_string(FK_XHCI_ROUTE_OK)
       call xhci_start(bar)
    else
       call serial_print_string(FK_XHCI_ROUTE_BAD)
    end if
  end subroutine xhci_route

  ! THE CONTROLLER (roadmap 5.1).  Reset it -- firmware has already driven it
  ! and left CRCR, DCBAAP and ERSTBA pointing into memory the PMM is about to
  ! hand out -- then give it a command ring, an event ring and a reason to
  ! interrupt, and ask it to do the one thing that needs none of USB: a NO-OP.
  subroutine xhci_start(bar)
    implicit none
    integer(c_int64_t), intent(in) :: bar
    integer(c_int64_t) :: run, run_virt, dcbaa, cmd, evt, erst, trb, i
    integer(c_int32_t) :: st, slots, spads, msi0
    integer(c_int32_t), pointer :: dc(:)
    type(c_ptr) :: cp

    fk_xhci_state = 0_c_int64_t
    fk_xhci_state(0) = FK_XHCIS_MAGIC
    call serial_print_string(FK_XHCI_START)

    st = xhci_attach(FK_VMM_XHCI)
    if (st /= FK_XHCI_OK) then
       call seq_failed(st)
       return
    end if

    slots = xhci_max_slots()
    spads = xhci_max_scratchpads()
    call serial_print_string(FK_XHCI_CAPS)
    call serial_print_hex(int(xhci_caplength(), c_int64_t), 2_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(xhci_version(), c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(slots, c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(spads, c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(xhci_page_size(), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_NL)

    run = pmm_alloc_contiguous(FK_XHCI_RING_PAGES)
    if (run == 0_c_int64_t) then
       call serial_print_string(FK_XHCI_NOMEM)
       return
    end if
    run_virt = vmm_phys_to_virt(run)
    dcbaa = run
    cmd   = run + FK_PMM_PAGE_SIZE
    evt   = run + 2_c_int64_t * FK_PMM_PAGE_SIZE
    erst  = run + 3_c_int64_t * FK_PMM_PAGE_SIZE

    ! The DCBAA is the driver's to zero: entry 0 is the scratchpad array
    ! pointer when the controller asks for buffers, and 0 when it does not.
    ! THIS MACHINE ASKS FOR NONE -- qemu-xhci reports zero scratchpad buffers
    ! -- so the array is left zeroed and the buffer path is not exercised here.
    cp = transfer(run_virt, cp)
    call c_f_pointer(cp, dc, [FK_PMM_PAGE_SIZE / 4_c_int64_t])
    do i = 1_c_int64_t, FK_PMM_PAGE_SIZE / 4_c_int64_t
       dc(i) = 0_c_int32_t
    end do

    st = xhci_reset()
    ! THE RESET IS THE ASSERTION, and it has to be read before anything else
    ! is written or it cannot be told apart from a kernel that skipped it: the
    ! values below are firmware's until the reset clears them, and this
    ! kernel's a moment later.
    fk_xhci_state(16) = xhci_crcr()
    fk_xhci_state(17) = xhci_dcbaap()
    fk_xhci_state(18) = int(xhci_usbsts(), c_int64_t)
    if (st == FK_XHCI_OK) st = xhci_config_slots(slots)
    if (st == FK_XHCI_OK) st = xhci_set_dcbaap(dcbaa)
    if (st == FK_XHCI_OK) &
         st = xhci_cmd_ring_init(vmm_phys_to_virt(cmd), cmd, FK_XHCI_RING_TRBS)
    if (st == FK_XHCI_OK) &
         st = xhci_event_ring_init(vmm_phys_to_virt(evt), evt, &
                                   FK_XHCI_RING_TRBS, vmm_phys_to_virt(erst), &
                                   erst)
    if (st == FK_XHCI_OK) st = xhci_intr_enable()
    if (st == FK_XHCI_OK) st = xhci_run()
    if (st /= FK_XHCI_OK) then
       call seq_failed(st)
       return
    end if

    call serial_print_string(FK_XHCI_RINGS)
    call serial_print_hex(cmd, 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(evt, 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(erst, 16_c_int32_t)
    call serial_print_string(FK_NL)

    call serial_print_string(FK_XHCI_RUNNING)
    call serial_print_hex(int(xhci_usbsts(), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_NL)

    msi0 = int(fk_msi_count, c_int32_t)
    trb = xhci_cmd_noop()
    call xhci_doorbell(0_c_int32_t, 0_c_int32_t)

    ! A bounded spin, not a sleep: there is no clock in this path.  The event
    ! is posted by DMA and the interrupt arrives through the LAPIC, so neither
    ! is guaranteed to have landed by the instruction after the doorbell.
    !
    ! AND IT WAITS FOR *THIS* TRB, not for the first event on the ring.  With a
    ! device attached the controller also posts Port Status Change events, and
    ! a loop that took whatever arrived first read one of those as a failed
    ! command -- intermittently, which is the worst way to find out.  Before
    ! roadmap 5.2 there was no device and nothing else to arrive.
    st = xhci_cmd_wait(trb)

    fk_xhci_state(0) = FK_XHCIS_MAGIC
    fk_xhci_state(1) = bar
    fk_xhci_state(2) = run
    fk_xhci_state(3) = cmd
    fk_xhci_state(4) = evt
    fk_xhci_state(5) = erst
    fk_xhci_state(6) = trb
    fk_xhci_state(7) = ior(shiftl(int(xhci_event_type(), c_int64_t), 32), &
                           int(xhci_event_comp(), c_int64_t))
    fk_xhci_state(8) = xhci_event_ptr()
    fk_xhci_state(9) = int(xhci_usbsts(), c_int64_t)
    fk_xhci_state(10) = xhci_crcr()
    fk_xhci_state(11) = xhci_erdp()
    fk_xhci_state(13) = ior(shiftl(int(xhci_caplength(), c_int64_t), 32), &
                            int(xhci_version(), c_int64_t))
    fk_xhci_state(14) = ior(shiftl(int(slots, c_int64_t), 32), &
                            int(spads, c_int64_t))
    fk_xhci_state(15) = int(st, c_int64_t)

    call serial_print_string(FK_XHCI_NOOP)
    call serial_print_hex(trb, 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(xhci_event_type(), c_int64_t), 2_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(xhci_event_comp(), c_int64_t), 2_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(xhci_event_ptr(), 16_c_int32_t)
    call serial_print_string(FK_NL)

    if (st == FK_XHCI_OK .and. xhci_event_comp() == 1_c_int32_t .and. &
        xhci_event_ptr() == trb .and. trb /= 0_c_int64_t) then
       call serial_print_string(FK_XHCI_DONE)
    else
       call serial_print_string(FK_XHCI_NOEVENT)
    end if

    ! The interrupt is a SEPARATE claim from the completion: the controller can
    ! post an event and send no message, which is what an unarmed IMAN.IE or
    ! USBCMD.INTE produces and what nothing on the console would otherwise show.
    do i = 1_c_int64_t, 100000_c_int64_t
       if (int(fk_msi_count, c_int32_t) /= msi0) exit
    end do
    fk_xhci_state(12) = fk_msi_count
    if (int(fk_msi_count, c_int32_t) /= msi0) then
       call serial_print_string(FK_XHCI_IRQ)
       call serial_print_hex(fk_msi_count, 8_c_int32_t)
       call serial_print_string(FK_NL)
    else
       call serial_print_string(FK_XHCI_NOIRQ)
    end if

    ! roadmap 5.2.  The DCBAA is 5.1's, at the base of its run; everything
    ! else the keyboard needs is a run of its own.
    call usbkbd_start(run_virt)
  end subroutine xhci_start

  ! THE KEYBOARD (roadmap 5.2).  5.1 left a running controller and a NO-OP that
  ! completed; this is a slot, a device context, an address, four control
  ! transfers and an interrupt endpoint whose reports reach the screen.
  subroutine usbkbd_start(dcbaa_virt)
    implicit none
    integer(c_int64_t), intent(in) :: dcbaa_virt
    integer(c_int64_t) :: run
    integer(c_int32_t) :: st

    call serial_print_string(FK_KBD_START)
    call serial_print_string(FK_NL)

    run = pmm_alloc_contiguous(FK_KBD_PAGES)
    if (run == 0_c_int64_t) then
       call serial_print_string(FK_KBD_NOMEM)
       return
    end if

    st = usbkbd_bringup(run, vmm_phys_to_virt(run), dcbaa_virt, &
                        FK_PMM_PAGE_SIZE)

    call serial_print_string(FK_KBD_PORT)
    call serial_print_hex(fk_usbkbd_state(1), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(fk_usbkbd_state(2), 8_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(fk_usbkbd_state(3), 2_c_int32_t)
    call serial_print_string(FK_NL)

    call serial_print_string(FK_KBD_CTX)
    call serial_print_hex(fk_usbkbd_state(5), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(fk_usbkbd_state(6), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(fk_usbkbd_state(10), 16_c_int32_t)
    call serial_print_string(FK_NL)

    if (st /= FK_XHCI_OK) then
       call serial_print_string(FK_KBD_BAD)
       call serial_print_hex(int(st, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
       return
    end if

    call serial_print_string(FK_KBD_SLOT)
    call serial_print_hex(fk_usbkbd_state(4), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(fk_usbkbd_state(12), 2_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(fk_usbkbd_state(13), 2_c_int32_t)
    call serial_print_string(FK_NL)

    call serial_print_string(FK_KBD_DEV)
    call serial_print_hex(fk_usbkbd_state(14), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(iand(fk_usbkbd_state(15), &
                               int(z'FFFFFFFF', c_int64_t)), 2_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(shiftr(fk_usbkbd_state(15), 32), 2_c_int32_t)
    call serial_print_string(FK_NL)

    call serial_print_string(FK_KBD_EP)
    call serial_print_hex(fk_usbkbd_state(16), 2_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(shiftr(fk_usbkbd_state(17), 32), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(iand(fk_usbkbd_state(17), &
                               int(z'FFFFFFFF', c_int64_t)), 2_c_int32_t)
    call serial_print_string(FK_NL)

    call serial_print_string(FK_KBD_OK)
    call serial_print_string(FK_NL)
  end subroutine usbkbd_start

  ! THE DRIVE (roadmap 5.3).  Everything 5.1 did for the xHCI -- enable the
  ! function, map the BAR strong-UC, route MSI-X -- and then the controller's
  ! own sequence: disable, admin queues, enable, identify, an I/O queue pair,
  ! and one 512-byte read of LBA 0 that lands in DRAM by DMA.
  subroutine nvme_bringup()
    implicit none
    integer(c_int64_t) :: bar, run, run_virt, asq, acq, iosq, iocq, idbuf, sec
    integer(c_int64_t) :: pte
    integer(c_int32_t) :: i, st, fw, down, cmd, cap, cnt, bir, off

    fk_nvme_state = 0_c_int64_t
    fk_nvme_state(0) = FK_NVMES_MAGIC

    i = pcie_find_nvme()
    if (i == FK_PCIE_NOT_FOUND) then
       call serial_print_string(FK_NVME_NONE)
       return
    end if
    call serial_print_string(FK_NVME_START)

    fw   = pcie_command(i)
    down = pcie_cmd_disable(i)
    cmd  = pcie_cmd_enable(i)
    if (btest(down, FK_PCI_CMD_MEMORY_BIT) .or. &
        .not. btest(cmd, FK_PCI_CMD_MEMORY_BIT) .or. &
        .not. btest(cmd, FK_PCI_CMD_MASTER_BIT)) then
       call nvme_failed(FK_NVME_E_NOBASE)
       return
    end if

    bar = pcie_bar64(i, 0_c_int32_t)
    fk_nvme_state(1) = bar
    if (bar == 0_c_int64_t) then
       call nvme_failed(FK_NVME_E_NOBASE)
       return
    end if

    ! The BAR sits ABOVE top-of-RAM on this machine, so the punch finds nothing
    ! in the linear map and correctly does nothing.  It is still called: a
    ! controller whose BAR firmware placed below top-of-RAM would need it, and
    ! which side of that line a machine falls on is not this code's to assume.
    st = vmm_punch_physmap(bar, FK_XHCI_WINDOW_BYTES)
    if (st == FK_VMM_OK) &
         st = vmm_map_mmio(FK_VMM_NVME, bar, FK_XHCI_WINDOW_BYTES, FK_VMM_UC)
    if (st /= FK_VMM_OK) then
       call serial_print_string(FK_NVME_MAP_BAD)
       call serial_print_hex(int(st, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
       return
    end if
    call serial_print_string(FK_NVME_WINDOW)
    call serial_print_hex(FK_VMM_NVME, 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(bar, 16_c_int32_t)
    call serial_print_string(FK_NL)

    ! The route, exactly as 5.1 builds the xHCI's, and onto the SAME vector.
    ! MSI-X has no line to share, so two devices on one vector is two drains in
    ! the handler and no arbitration anywhere.
    cap = pcie_msix_at(i)
    if (cap /= FK_PCIE_NOT_FOUND) then
       cnt = pcie_msix_count(i)
       bir = pcie_msix_bir(i)
       off = pcie_msix_offset(i)
       if (cnt > 0_c_int32_t .and. bir == 0_c_int32_t) then
          st = pcie_msix_entry_set(FK_VMM_NVME + int(off, c_int64_t), &
                                   0_c_int32_t, &
                                   lapic_msi_addr(lapic_id(FK_VMM_LAPIC)), &
                                   0_c_int32_t, lapic_msi_data(FK_VECTOR_MSI))
          if (st == FK_PCIE_OK) then
             st = pcie_msix_enable(i)
             st = pcie_intx_disable(i)
          end if
       end if
    end if

    st = nvme_attach(FK_VMM_NVME)
    if (st /= FK_NVME_OK) then
       call nvme_failed(st)
       return
    end if

    fk_nvme_state(3) = nvme_cap()
    fk_nvme_state(4) = int(nvme_version(), c_int64_t)
    call serial_print_string(FK_NVME_CAPS)
    call serial_print_hex(nvme_cap(), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(nvme_version(), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(nvme_mqes(), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(nvme_dstrd(), c_int64_t), 2_c_int32_t)
    call serial_print_string(FK_NL)

    run = pmm_alloc_contiguous(FK_NVME_PAGES)
    if (run == 0_c_int64_t) then
       call serial_print_string(FK_NVME_NOMEM)
       return
    end if
    run_virt = vmm_phys_to_virt(run)
    fk_nvme_state(2) = run
    asq   = run
    acq   = run + FK_PMM_PAGE_SIZE
    iosq  = run + 2_c_int64_t * FK_PMM_PAGE_SIZE
    iocq  = run + 3_c_int64_t * FK_PMM_PAGE_SIZE
    idbuf = run + 4_c_int64_t * FK_PMM_PAGE_SIZE
    sec   = run + 5_c_int64_t * FK_PMM_PAGE_SIZE
    fk_nvme_state(10) = idbuf
    fk_nvme_state(11) = sec
    call nvme_set_sector_buf(run_virt + 5_c_int64_t * FK_PMM_PAGE_SIZE, &
                             int(FK_PMM_PAGE_SIZE, c_int32_t))

    st = nvme_disable()
    if (st == FK_NVME_OK) &
         st = nvme_admin_queues(run_virt, asq, &
                                run_virt + FK_PMM_PAGE_SIZE, acq)
    if (st == FK_NVME_OK) st = nvme_enable()
    if (st /= FK_NVME_OK) then
       call nvme_failed(st)
       return
    end if

    fk_nvme_state(5) = int(nvme_cc(), c_int64_t)
    fk_nvme_state(6) = int(nvme_csts(), c_int64_t)
    fk_nvme_state(7) = int(nvme_aqa(), c_int64_t)
    fk_nvme_state(8) = nvme_asq()
    fk_nvme_state(9) = nvme_acq()
    call serial_print_string(FK_NVME_READY)
    call serial_print_hex(int(nvme_cc(), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(nvme_csts(), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(nvme_aqa(), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_NL)
    call serial_print_string(FK_NVME_QUEUES)
    call serial_print_hex(nvme_asq(), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(nvme_acq(), 16_c_int32_t)
    call serial_print_string(FK_NL)

    st = nvme_identify(FK_NVME_ID_CNS_CTRL, 0_c_int32_t, idbuf)
    if (st == FK_NVME_OK) &
         st = nvme_identify(FK_NVME_ID_CNS_NS, 1_c_int32_t, idbuf)
    if (st == FK_NVME_OK) &
         st = nvme_ns_decode(run_virt + 4_c_int64_t * FK_PMM_PAGE_SIZE)
    if (st /= FK_NVME_OK) then
       call nvme_failed(st)
       return
    end if
    fk_nvme_state(12) = nvme_ns_size()
    fk_nvme_state(13) = int(nvme_lba_bytes(), c_int64_t)
    call serial_print_string(FK_NVME_NS)
    call serial_print_hex(nvme_ns_size(), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(nvme_lba_bytes(), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_NL)

    ! THE COMPLETION QUEUE BEFORE THE SUBMISSION QUEUE.  Create I/O SQ names
    ! the CQ it completes into, so a controller asked for the pair in the other
    ! order rejects the SQ for referring to a queue that does not exist.
    st = nvme_create_cq(run_virt + 3_c_int64_t * FK_PMM_PAGE_SIZE, iocq, &
                        1_c_int32_t, 2_c_int32_t, 0_c_int32_t)
    if (st == FK_NVME_OK) &
         st = nvme_create_sq(run_virt + 2_c_int64_t * FK_PMM_PAGE_SIZE, iosq, &
                             run_virt + 3_c_int64_t * FK_PMM_PAGE_SIZE, iocq, &
                             1_c_int32_t, 2_c_int32_t)
    if (st /= FK_NVME_OK) then
       call nvme_failed(st)
       return
    end if
    fk_nvme_state(18) = int(nvme_admin_head(), c_int64_t)
    fk_nvme_state(19) = int(nvme_admin_phase(), c_int64_t)

    ! THE HANDOVER, and its order is 5.2's lesson repeated: the flag goes up
    ! inside nvme_owner_isr BEFORE the controller's interrupts are unmasked, so
    ! there is no instant where a completion is taken by a handler that does
    ! not own the queue.
    st = nvme_owner_isr()
    if (st == FK_NVME_OK) st = nvme_read(1_c_int32_t, 0_c_int64_t, &
                                         1_c_int32_t, sec)
    if (st /= FK_NVME_OK) then
       call nvme_failed(st)
       return
    end if

    ! The read completes by INTERRUPT now, so this waits on the counter the
    ! handler moves rather than on the queue it no longer owns.
    ! THE VOLATILE VARIABLE, not the accessor over it.  An accessor is
    ! side-effect-free to gfortran, so this loop would load once and spin on a
    ! value that can never change -- which is exactly what it did.
    do i = 1_c_int32_t, 2000000_c_int32_t
       if (fk_nvme_irq_completions > 0_c_int64_t) exit
    end do
    fk_nvme_state(15) = fk_nvme_irq_completions
    fk_nvme_state(14) = int(nvme_last_status(), c_int64_t)
    if (fk_nvme_irq_completions == 0_c_int64_t) then
       call nvme_failed(FK_NVME_E_CMD)
       return
    end if

    fk_nvme_state(16) = nvme_sector_word(0_c_int32_t)
    fk_nvme_state(17) = nvme_sector_word(1_c_int32_t)
    call serial_print_string(FK_NVME_SECTOR)
    call serial_print_hex(fk_nvme_state(16), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(fk_nvme_state(17), 16_c_int32_t)
    call serial_print_string(FK_NL)

    pte = vmm_translate(FK_VMM_NVME)
    if (iand(pte, FK_PTE_PWT) == 0_c_int64_t .or. &
        iand(pte, FK_PTE_PCD) == 0_c_int64_t) then
       call nvme_failed(FK_NVME_E_QUEUE)
       return
    end if

    fk_nvme_state(20) = 0_c_int64_t
    call serial_print_string(FK_NVME_DONE)
    call serial_print_string(FK_NL)
    call console_write(FK_NVME_SECTOR, 64_c_int32_t)
    call console_print_hex(fk_nvme_state(16), 16_c_int32_t)
    call console_newline()
  end subroutine nvme_bringup

  subroutine nvme_failed(st)
    implicit none
    integer(c_int32_t), intent(in) :: st

    call serial_print_string(FK_NVME_BAD)
    call serial_print_hex(int(st, c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_NL)
    fk_nvme_state(20) = int(st, c_int64_t)
  end subroutine nvme_failed

  subroutine seq_failed(st)
    implicit none
    integer(c_int32_t), intent(in) :: st

    call serial_print_string(FK_XHCI_SEQ_BAD)
    call serial_print_hex(int(st, c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_NL)
    fk_xhci_state(0) = FK_XHCIS_MAGIC
    fk_xhci_state(15) = int(st, c_int64_t)
  end subroutine seq_failed

  ! The MADT's interrupt source override flags for one ISA IRQ, decoded into
  ! the IOAPIC's own polarity and trigger encodings.  ACPI 6.5 table 5.26: bits
  ! 1:0 are polarity (0 conforms, 1 active high, 3 active low) and bits 3:2 are
  ! trigger (0 conforms, 1 edge, 3 level).  CONFORMS on the ISA bus means
  ! active high and edge triggered, which is what the zero default gives -- so
  ! the two "conforms" cases need no branch of their own, and hardcoding
  ! edge/high for every line would be wrong the moment a level-triggered
  ! override appears.
  subroutine iso_decode(irq, polarity, trigger)
    implicit none
    integer(c_int32_t), intent(in)  :: irq
    integer(c_int32_t), intent(out) :: polarity, trigger
    integer(c_int32_t) :: i, f

    polarity = FK_IOAPIC_POL_HIGH
    trigger  = FK_IOAPIC_TRIG_EDGE
    do i = 0_c_int32_t, madt_iso_count() - 1_c_int32_t
       if (madt_iso_src(i) /= irq) cycle
       f = madt_iso_flags(i)
       if (ibits(f, 0_c_int32_t, 2_c_int32_t) == 3_c_int32_t) &
            polarity = FK_IOAPIC_POL_LOW
       if (ibits(f, 2_c_int32_t, 2_c_int32_t) == 3_c_int32_t) &
            trigger = FK_IOAPIC_TRIG_LEVEL
       return
    end do
  end subroutine iso_decode

  ! roadmap 3.3.  AFTER irq_bringup, which proves the timer works through the
  ! 8259s and leaves IRQ0 the only open line; this takes that same timer away
  ! from them and proves it again on the other path, in the same boot.
  subroutine ioapic_bringup()
    implicit none
    integer(c_int64_t) :: phys, t0, spins
    integer(c_int32_t) :: st, gsi, vector, pol, trig, lo, want, imr

    fk_ioapic_state = 0_c_int64_t
    call serial_print_string(FK_IOA_START)

    if (madt_ioapic_count() == 0_c_int32_t) then
       call serial_print_string(FK_IOA_NONE)
       return
    end if
    phys = madt_ioapic_addr(0_c_int32_t)

    ! The linear map already covers this page write-back: the address came out
    ! of an ACPI table, which could not be read until the map existed, so
    ! vmm_reserve_mmio -- which runs before vmm_init -- was never reachable for
    ! it.  Two memory types for one physical page is undefined (SDM Vol.3
    ! 11.12.4), so the write-back one is removed before the uncached one is
    ! made.
    st = vmm_punch_physmap(phys, FK_PMM_PAGE_SIZE)
    if (st /= FK_VMM_OK) then
       call serial_print_string(FK_IOA_PUNCH_BAD)
       call serial_print_hex(int(st, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
       return
    end if

    st = vmm_map_mmio(FK_VMM_IOAPIC, phys, FK_PMM_PAGE_SIZE, FK_VMM_UC)
    if (st /= FK_VMM_OK) then
       call serial_print_string(FK_IOA_MAP_BAD)
       call serial_print_hex(int(st, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
       return
    end if

    ! What the punch was FOR, asserted rather than assumed: the linear map's
    ! entry for this frame is gone.  A punch that silently did nothing leaves
    ! every other line in this routine true.
    if (vmm_translate(FK_VMM_PHYSMAP + phys) == 0_c_int64_t) then
       call serial_print_string(FK_IOA_ALIAS_OK)
    else
       call serial_print_string(FK_IOA_ALIAS_BAD)
    end if

    call ioapic_set_window(FK_VMM_IOAPIC)
    call serial_print_string(FK_IOA_CHIP)
    call serial_print_hex(int(ioapic_id(), c_int64_t), 2_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(ioapic_version(), c_int64_t), 2_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(ioapic_max_redir(), c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_NL)

    gsi    = madt_gsi_for_irq(FK_PIT_IRQ)
    vector = FK_PIC1_VECTOR + FK_PIT_IRQ
    call iso_decode(FK_PIT_IRQ, pol, trig)

    ! BEFORE the route and not after it.  A line live on the 8259 and on the
    ! IOAPIC at the same time is delivered twice, and the second delivery is
    ! acknowledged at whichever chip the handler has been told about -- so the
    ! other one holds an in-service bit for ever.
    if (pic_disable() == 0_c_int32_t) then
       call serial_print_string(FK_IOA_PIC_OFF)
    else
       call serial_print_string(FK_IOA_PIC_ON)
    end if

    st = ioapic_route(gsi, vector, lapic_id(FK_VMM_LAPIC), pol, trig)
    if (st /= FK_IOAPIC_OK) then
       call serial_print_string(FK_IOA_ROUTE_BAD)
       call serial_print_hex(int(st, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
       return
    end if

    ! The acknowledgement moves LAST.  Until this call the handler is still
    ! EOIing the 8259s, which is correct for every interrupt that arrived
    ! before the route above and wrong for every one after it; the window
    ! between the two is one instruction wide and interrupts are on.
    call idt_set_eoi_lapic(FK_VMM_LAPIC)

    lo   = ioapic_read_lo(gsi)
    want = ior(iand(vector, 255_c_int32_t), 0_c_int32_t)
    call serial_print_string(FK_IOA_ROUTED)
    call serial_print_hex(int(gsi, c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(vector, c_int64_t), 2_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(lo, c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_NL)
    if (ibits(lo, 0_c_int32_t, 8_c_int32_t) /= want .or. &
        btest(lo, 16_c_int32_t)) &
         call serial_print_string(FK_IOA_READBACK_BAD)

    ! The whole milestone in one property.  Both chips are masked, so a tick
    ! from here on can only have come through the IOAPIC -- and it has to have
    ! been RETURNED from, or this loop is where the boot ends.
    t0    = fk_tick_count
    spins = 0_c_int64_t
    do while (fk_tick_count < t0 + FK_TICK_TARGET .and. &
              spins < FK_TICK_SPIN_LIMIT)
       spins = spins + 1_c_int64_t
    end do
    if (fk_tick_count >= t0 + FK_TICK_TARGET) then
       call serial_print_string(FK_IOA_TICKING)
    else
       call serial_print_string(FK_IOA_STOPPED)
    end if

    imr = pic_imr()
    fk_ioapic_state(0) = FK_IOA_MAGIC
    fk_ioapic_state(1) = phys
    fk_ioapic_state(2) = int(gsi, c_int64_t)
    fk_ioapic_state(3) = int(vector, c_int64_t)
    fk_ioapic_state(4) = int(lo, c_int64_t)
    fk_ioapic_state(5) = int(imr, c_int64_t)

    call console_print_hex(int(gsi, c_int64_t), 4_c_int32_t)
    call console_print_hex(int(vector, c_int64_t), 2_c_int32_t)
    call console_print_hex(int(imr, c_int64_t), 8_c_int32_t)
  end subroutine ioapic_bringup

  subroutine dma_bringup()
    implicit none
    integer(c_int64_t) :: phys, virt, i
    integer(c_int64_t), pointer :: w(:)
    type(c_ptr) :: cp
    integer(c_int32_t) :: ok

    fk_dma_probe = 0_c_int64_t
    call serial_print_string(FK_DMA_START)

    phys = pmm_alloc_contiguous(FK_DMA_PAGES)
    if (phys == 0_c_int64_t) then
       call serial_print_string(FK_DMA_REFUSED)
       return
    end if

    call serial_print_string(FK_DMA_BASE)
    call serial_print_hex(phys, 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(FK_DMA_PAGES, 4_c_int32_t)
    call serial_print_string(FK_NL)

    ! One word per frame, derived from that frame's own index.  Read back at
    ! the PHYSICAL base from outside the guest, they appear in order only if
    ! the frames really are adjacent in DRAM.
    virt = vmm_phys_to_virt(phys)
    cp   = transfer(virt, cp)
    call c_f_pointer(cp, w, [FK_DMA_PAGES * 512_c_int64_t])
    do i = 0_c_int64_t, FK_DMA_PAGES - 1_c_int64_t
       w(i * 512_c_int64_t + 1_c_int64_t) = FK_DMA_SEED + i
    end do

    ! And the kernel's own half of the same claim, which the host cannot make:
    ! the page tables agree that each frame's virtual address translates to the
    ! next physical page.
    ok = 1_c_int32_t
    do i = 0_c_int64_t, FK_DMA_PAGES - 1_c_int64_t
       if (vmm_phys_of(virt + ishft(i, 12)) /= phys + ishft(i, 12)) &
            ok = 0_c_int32_t
    end do
    if (ok == 1_c_int32_t) then
       call serial_print_string(FK_DMA_WALK_OK)
    else
       call serial_print_string(FK_DMA_WALK_BAD)
    end if

    fk_dma_probe(0) = FK_DMA_MAGIC
    fk_dma_probe(1) = phys
    fk_dma_probe(2) = FK_DMA_PAGES
    fk_dma_probe(3) = FK_DMA_SEED
  end subroutine dma_bringup

  ! roadmap 6.1.  A tree built in memory, not read off the disk: 6.2 is the
  ! filesystem driver and this is the layer it plugs into.  What the boot adds
  ! over the host suite is that the walk runs against the REAL fk_strlen, under
  ! KFLAGS, on a machine that is taking timer interrupts while it does it.
  subroutine vfs_bringup()
    implicit none
    integer(c_int32_t) :: sb, root, bin, etc_d, init_d, ino_h, probe
    character(kind=c_char), target :: pbuf(FK_VFS_PBUF)

    fk_vfs_state = 0_c_int64_t
    call serial_print_string(FK_VFS_START)
    call vfs_reset()

    sb = vfs_mount(FK_VFSS_MAGIC, 4096_c_int64_t, 1_c_int32_t)
    if (sb <= 0_c_int32_t) then
       call vfs_failed(sb)
       return
    end if
    root = vfs_root(sb)

    call path_copy(FK_VFS_N_BIN, pbuf)
    bin = vfs_add(root, c_loc(pbuf(1)), 3_c_int32_t, &
                  ior(FK_S_IFDIR, int(o'755', c_int32_t)), 0_c_int64_t)
    if (bin <= 0_c_int32_t) then
       call vfs_failed(bin)
       return
    end if
    call path_copy(FK_VFS_N_ETC, pbuf)
    etc_d = vfs_add(root, c_loc(pbuf(1)), 3_c_int32_t, &
                    ior(FK_S_IFDIR, int(o'755', c_int32_t)), 0_c_int64_t)
    if (etc_d <= 0_c_int32_t) then
       call vfs_failed(etc_d)
       return
    end if
    call path_copy(FK_VFS_N_INIT, pbuf)
    init_d = vfs_add(bin, c_loc(pbuf(1)), 4_c_int32_t, &
                     ior(FK_S_IFREG, int(o'755', c_int32_t)), 4096_c_int64_t)
    if (init_d <= 0_c_int32_t) then
       call vfs_failed(init_d)
       return
    end if
    call path_copy(FK_VFS_N_FSTAB, pbuf)
    if (vfs_add(etc_d, c_loc(pbuf(1)), 5_c_int32_t, &
                ior(FK_S_IFREG, int(o'644', c_int32_t)), 64_c_int64_t) &
        <= 0_c_int32_t) then
       call vfs_failed(-1_c_int32_t)
       return
    end if

    ! The whole point of the milestone, and it is resolved by NAME rather than
    ! compared against the handle vfs_add returned by luck: the walk has to
    ! tokenise the path, find "bin" in the root's child list and "init" in
    ! bin's, and arrive at the same dentry.
    call path_copy(FK_VFS_P_INIT, pbuf)
    if (vfs_resolve(c_loc(pbuf(1))) /= init_d) then
       call vfs_failed(-2_c_int32_t)
       return
    end if

    ! And the refusal, which is the half a resolver is most likely to get
    ! wrong: /bin/init is a file, so a trailing slash is -ENOTDIR.
    call path_copy(FK_VFS_P_SLASH, pbuf)
    probe = vfs_resolve(c_loc(pbuf(1)))
    if (probe /= -FK_E_NOTDIR) then
       call vfs_failed(-3_c_int32_t)
       return
    end if

    ino_h = vfs_dentry_inode(init_d)

    call serial_print_string(FK_VFS_TREE)
    call serial_print_hex(int(sb, c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(root, c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(bin, c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(init_d, c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_NL)

    call serial_print_string(FK_VFS_NODE)
    call serial_print_hex(vfs_inode_ino(ino_h), 8_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(vfs_inode_size(ino_h), 8_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(vfs_inode_mode(ino_h), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_NL)

    call serial_print_string(FK_VFS_POOLS)
    call serial_print_hex(int(vfs_dentries_used(), c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(vfs_inodes_used(), c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_NL)

    fk_vfs_state(0) = FK_VFSS_MAGIC
    fk_vfs_state(1) = int(sb, c_int64_t)
    fk_vfs_state(2) = int(root, c_int64_t)
    fk_vfs_state(3) = int(bin, c_int64_t)
    fk_vfs_state(4) = int(init_d, c_int64_t)
    fk_vfs_state(5) = vfs_inode_ino(ino_h)
    fk_vfs_state(6) = vfs_inode_size(ino_h)
    fk_vfs_state(7) = int(vfs_inode_mode(ino_h), c_int64_t)
    fk_vfs_state(8) = int(vfs_dentries_used(), c_int64_t)
    fk_vfs_state(9) = int(vfs_inodes_used(), c_int64_t)
    fk_vfs_state(10) = int(probe, c_int64_t)
    fk_vfs_state(11) = 0_c_int64_t

    call serial_print_string(FK_VFS_DONE)
    call serial_print_string(FK_NL)
  end subroutine vfs_bringup

  subroutine vfs_failed(st)
    implicit none
    integer(c_int32_t), intent(in) :: st

    call serial_print_string(FK_VFS_BAD)
    call serial_print_hex(int(st, c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_NL)
    fk_vfs_state(0) = FK_VFSS_MAGIC
    fk_vfs_state(11) = int(st, c_int64_t)
  end subroutine vfs_failed

  ! A parameter string copied into storage whose address can be taken.  c_loc
  ! needs a TARGET and a named constant is not one; a character SCALAR with a
  ! length parameter is not interoperable either, so the copy lands in an array
  ! of c_char and the caller takes the address of its first element.
  subroutine path_copy(s, buf)
    implicit none
    character(kind=c_char, len=*), intent(in) :: s
    character(kind=c_char), intent(out) :: buf(:)
    integer(c_int32_t) :: k, n

    n = min(int(len(s), c_int32_t), int(size(buf), c_int32_t))
    do k = 1_c_int32_t, n
       buf(k) = s(k:k)
    end do
  end subroutine path_copy

  subroutine acpi_bringup(mbi)
    implicit none
    integer(c_int64_t), intent(in) :: mbi
    integer(c_int32_t) :: st
    integer(c_int64_t) :: mbi_virt, mbi_len, madt_phys, madt_len

    call serial_print_string(FK_ACPI_START)

    call acpi_set_window(FK_VMM_PHYSMAP)
    call acpi_set_limit(vmm_physmap_top())

    mbi_virt = vmm_phys_to_virt(mbi)
    ! total_size is the MBI's first word; read through the assembly peek so no
    ! optimiser may assume anything about a pointer this kernel just computed.
    mbi_len = iand(fk_peek64(mbi_virt), int(z'FFFFFFFF', c_int64_t))

    st = acpi_init(mbi_virt, mbi_len)
    if (st /= FK_ACPI_OK) then
       call serial_print_string(FK_ACPI_INIT_BAD)
       call serial_print_hex(int(st, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
       return
    end if

    if (acpi_root_kind() == FK_ACPI_ROOT_XSDT) then
       call serial_print_string(FK_ACPI_XSDT)
    else
       call serial_print_string(FK_ACPI_RSDT)
    end if
    call serial_print_string(FK_ACPI_ROOT)
    call serial_print_hex(acpi_root_phys(), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(acpi_revision(), c_int64_t), 2_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(acpi_table_count(), c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_NL)

    madt_phys = acpi_find(FK_SIG_APIC)
    if (madt_phys == 0_c_int64_t) then
       call serial_print_string(FK_ACPI_NO_MADT)
       return
    end if
    madt_len = acpi_table_length(madt_phys)

    call serial_print_string(FK_MADT_AT)
    call serial_print_hex(madt_phys, 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(madt_len, 8_c_int32_t)
    call serial_print_string(FK_NL)

    st = madt_parse(vmm_phys_to_virt(madt_phys), int(madt_len, c_int32_t))
    if (st /= FK_MADT_OK) then
       call serial_print_string(FK_MADT_BAD)
       call serial_print_hex(int(st, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
       return
    end if

    call serial_print_string(FK_MADT_CPUS)
    call serial_print_hex(int(madt_cpu_count(), c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(madt_cpu_enabled(), c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(madt_skipped(), c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_NL)

    call serial_print_string(FK_MADT_IOAPIC)
    call serial_print_hex(int(madt_ioapic_count(), c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(madt_ioapic_addr(0_c_int32_t), 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    ! EIGHT DIGITS, not four.  A GSI base read from the wrong offset picks up
    ! the IOAPIC's own address, 0xFEC00000, whose low sixteen bits are zero --
    ! so at four digits a wrong answer printed exactly like the right one and
    ! mutation M44 walked through the gate.
    call serial_print_hex(int(madt_ioapic_gsi_base(0_c_int32_t), c_int64_t), &
                          8_c_int32_t)
    call serial_print_string(FK_NL)

    call serial_print_string(FK_MADT_ISO)
    call serial_print_hex(int(madt_iso_count(), c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(madt_gsi_for_irq(0_c_int32_t), c_int64_t), &
                          4_c_int32_t)
    call serial_print_string(FK_NL)

    call serial_print_string(FK_MADT_NMI)
    call serial_print_hex(int(madt_nmi_count(), c_int64_t), 4_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(madt_nmi_lint(0_c_int32_t), c_int64_t), &
                          2_c_int32_t)
    call serial_print_string(FK_NL)

    ! TWO INDEPENDENT SOURCES FOR ONE FACT, which is the only line here that
    ! could not be produced by a parser agreeing with itself: the MADT's
    ! header address against the value 3.3 read out of IA32_APIC_BASE.
    if (madt_lapic_addr() == lapic_msr_base()) then
       call serial_print_string(FK_MADT_AGREE)
       call serial_print_hex(madt_lapic_addr(), 16_c_int32_t)
       call serial_print_string(FK_NL)
    else
       call serial_print_string(FK_MADT_DISAGREE)
    end if

    if (madt_pcat_compat() /= 0_c_int32_t) &
         call serial_print_string(FK_MADT_PCAT)

    ! The same topology on the SCREEN, per the 4.1 directive.  console_write is
    ! a no-op until console_init has run, so this costs nothing on a boot that
    ! never got a framebuffer -- which is every UEFI boot today (see 2.2).
    if (acpi_root_kind() == FK_ACPI_ROOT_XSDT) then
       call console_write(FK_ACPI_XSDT, 128_c_int32_t)
    else
       call console_write(FK_ACPI_RSDT, 128_c_int32_t)
    end if
    call console_write(FK_MADT_AT, 64_c_int32_t)
    call console_print_hex(madt_phys, 16_c_int32_t)
    call console_write(FK_PMM_SLASH, 4_c_int32_t)
    call console_print_hex(madt_len, 8_c_int32_t)
    call console_write(FK_NL, 4_c_int32_t)
    call console_write(FK_MADT_CPUS, 64_c_int32_t)
    call console_print_hex(int(madt_cpu_count(), c_int64_t), 4_c_int32_t)
    call console_write(FK_PMM_SLASH, 4_c_int32_t)
    call console_print_hex(int(madt_cpu_enabled(), c_int64_t), 4_c_int32_t)
    call console_write(FK_PMM_SLASH, 4_c_int32_t)
    call console_print_hex(int(madt_skipped(), c_int64_t), 4_c_int32_t)
    call console_write(FK_NL, 4_c_int32_t)
    call console_write(FK_MADT_IOAPIC, 64_c_int32_t)
    call console_print_hex(int(madt_ioapic_count(), c_int64_t), 4_c_int32_t)
    call console_write(FK_PMM_SLASH, 4_c_int32_t)
    call console_print_hex(madt_ioapic_addr(0_c_int32_t), 16_c_int32_t)
    call console_write(FK_PMM_SLASH, 4_c_int32_t)
    call console_print_hex(int(madt_ioapic_gsi_base(0_c_int32_t), c_int64_t), &
                           4_c_int32_t)
    call console_write(FK_NL, 4_c_int32_t)
    call console_write(FK_MADT_ISO, 64_c_int32_t)
    call console_print_hex(int(madt_iso_count(), c_int64_t), 4_c_int32_t)
    call console_write(FK_PMM_SLASH, 4_c_int32_t)
    call console_print_hex(int(madt_gsi_for_irq(0_c_int32_t), c_int64_t), &
                           4_c_int32_t)
    call console_write(FK_NL, 4_c_int32_t)

    fk_acpi_topo(0) = FK_ACPI_MAGIC
    fk_acpi_topo(1) = int(acpi_root_kind(), c_int64_t)
    fk_acpi_topo(2) = acpi_root_phys()
    fk_acpi_topo(3) = madt_phys
    fk_acpi_topo(4) = int(madt_cpu_count(), c_int64_t)
    fk_acpi_topo(5) = madt_ioapic_addr(0_c_int32_t)
    fk_acpi_topo(6) = int(madt_iso_count(), c_int64_t)
    fk_acpi_topo(7) = int(madt_gsi_for_irq(0_c_int32_t), c_int64_t)
  end subroutine acpi_bringup

  subroutine lapic_bringup()
    implicit none
    integer(c_int64_t) :: base
    integer(c_int32_t) :: st

    call serial_print_string(FK_LAPIC_START)
    base = lapic_msr_base()
    call serial_print_string(FK_LAPIC_MSR)
    call serial_print_hex(base, 16_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(lapic_msr_enabled(), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_NL)

    if (lapic_msr_enabled() == 0_c_int32_t) then
       call serial_print_string(FK_LAPIC_OFF)
       return
    end if

    st = vmm_map_mmio(FK_VMM_LAPIC, base, FK_PMM_PAGE_SIZE, FK_VMM_UC)
    if (st /= FK_VMM_OK) then
       call serial_print_string(FK_LAPIC_MAP_BAD)
       call serial_print_hex(int(st, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
       return
    end if

    call serial_print_string(FK_LAPIC_HOLES)
    call serial_print_hex(int(vmm_reserved_holes(), c_int64_t), 2_c_int32_t)
    call serial_print_string(FK_NL)

    call lapic_init(FK_VMM_LAPIC, FK_VECTOR_SPURIOUS)

    ! Every number below is READ BACK OFF THE CHIP through the uncached
    ! mapping, not remembered from what was written -- the same rule fk_pic_m
    ! applies to the IMR.
    call serial_print_string(FK_LAPIC_LIVE)
    call serial_print_hex(int(lapic_id(FK_VMM_LAPIC), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(lapic_version(FK_VMM_LAPIC), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(lapic_svr(FK_VMM_LAPIC), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_NL)

    ! AND PUT LINT0 BACK, deliberately.  Software-enabling the LAPIC moves the
    ! 8259 off the CPU's own INTR pin and onto LINT0, so the masked LINT0 that
    ! lapic_init leaves behind stops IRQ0 dead -- the timer stops, and with it
    ! the scheduler.  Until an IOAPIC exists (roadmap 4.1) this kernel's only
    ! interrupt source is the 8259, so ExtINT is the correct state and not a
    ! concession.  Found by booting: the gate caught the hang.
    call lapic_lint0_extint(FK_VMM_LAPIC)

    ! And LINT1 as NMI, for the reason 3.2.5 armed an IST at all: a masked
    ! NMI line makes IST2 unreachable, and an NMI that is never delivered
    ! looks exactly like hardware that never raised one.
    call lapic_lint1_nmi(FK_VMM_LAPIC)

    call serial_print_string(FK_LAPIC_LINT)
    call serial_print_hex(int(lapic_lvt_lint0(FK_VMM_LAPIC), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_PMM_SLASH)
    call serial_print_hex(int(lapic_lvt_lint1(FK_VMM_LAPIC), c_int64_t), 8_c_int32_t)
    call serial_print_string(FK_NL)

    ! LINT1 masked is still the assertion; LINT0 must now read ExtINT.
    if (iand(lapic_svr(FK_VMM_LAPIC), 256_c_int32_t) /= 0_c_int32_t .and. &
        lapic_lvt_lint0(FK_VMM_LAPIC) == LVT_DM_EXTINT .and. &
        lapic_lvt_lint1(FK_VMM_LAPIC) == LVT_DM_NMI) then
       call serial_print_string(FK_LAPIC_MASKED)
    else
       call serial_print_string(FK_LAPIC_BAD)
    end if
  end subroutine lapic_bringup

  function irq_bringup() result(status)
    implicit none
    integer(c_int32_t) :: status
    integer(c_int32_t) :: divisor, imr
    integer(c_int64_t) :: t0, t1, spins, rflags, rip, saved

    status = 0_c_int32_t

    divisor = pit_init(FK_PIT_HZ)
    if (divisor == 0_c_int32_t) then
       call serial_print_string(FK_PIT_FAILED)
       status = 1_c_int32_t
    else
       call serial_print_string(FK_PIT_READY)
       call serial_print_hex(int(FK_PIT_HZ, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_PMM_SLASH)
       call serial_print_hex(int(divisor, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_DOT_NL)
    end if

    ! The IMR is READ BACK, not assumed: masking works whatever else is wrong,
    ! so an unmask that went to the wrong port looks identical from here unless
    ! the chip is asked.  Slave in bits 15:8, master in 7:0.
    call pic_unmask(FK_PIT_IRQ)
    imr = pic_imr()
    if (btest(imr, FK_PIT_IRQ)) then
       call serial_print_string(FK_IRQ_OPEN_BAD)
       status = 1_c_int32_t
    else
       call serial_print_string(FK_IRQ_OPEN)
       call serial_print_hex(int(imr, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_IRQ_OPEN_TAIL)
    end if

    call fk_irq_enable()
    rflags = fk_read_rflags()
    if (iand(rflags, FK_RFLAGS_IF) == 0_c_int64_t) then
       call serial_print_string(FK_IF_OFF)
       status = 1_c_int32_t
    else
       call serial_print_string(FK_IF_ON)
       call serial_print_hex(rflags, 16_c_int32_t)
       call serial_print_string(FK_NL)
    end if

    ! THE WAIT.  fk_tick_count is read DIRECTLY and never through an accessor:
    ! it is VOLATILE in fk_pit_m and the attribute travels through use
    ! association, so every turn of this loop reloads it from memory.  Written
    ! as a call to a getter in another module it does not -- gfortran 16.1.1
    ! deleted this entire loop and reused one result for both reads, which is
    ! the same class of fold that cost roadmap 3.2 a boot.  Disassembled, not
    ! assumed: there must be a `cmpq ..., fk_tick_count(%rip)` INSIDE the loop.
    t0    = fk_tick_count
    spins = 0_c_int64_t
    do while (fk_tick_count < t0 + FK_TICK_TARGET .and. spins < FK_TICK_SPIN_LIMIT)
       spins = spins + 1_c_int64_t
    end do
    t1 = fk_tick_count

    if (t1 < t0 + FK_TICK_TARGET) then
       call serial_print_string(FK_TICKS_NONE)
       status = 1_c_int32_t
    else
       call serial_print_string(FK_TICKS_OK)
       call serial_print_hex(t0, 8_c_int32_t)
       call serial_print_string(FK_PMM_SLASH)
       call serial_print_hex(t1, 8_c_int32_t)
       call serial_print_string(FK_PMM_SLASH)
       call serial_print_hex(fk_irq_spurious, 8_c_int32_t)
       call serial_print_string(FK_DOT_NL)
    end if

    ! WHERE it was interrupted, out of the frame the CPU pushed.  A tick count
    ! says a handler ran; this says the machine was executing this kernel's own
    ! instructions with interrupts on when it did, which is the half that says
    ! IRETQ had a real place to go back to.
    rip   = fk_first_rip
    saved = fk_first_rflags
    if (rip >= fk_text_start() .and. rip < fk_text_end() .and. &
        iand(saved, FK_RFLAGS_IF) /= 0_c_int64_t) then
       call serial_print_string(FK_TICK_RIP)
       call serial_print_hex(rip, 16_c_int32_t)
       call serial_print_string(FK_PMM_SLASH)
       call serial_print_hex(saved, 16_c_int32_t)
       call serial_print_string(FK_DOT_NL)
    else
       call serial_print_string(FK_TICK_RIP_BAD)
       status = 1_c_int32_t
    end if
  end function irq_bringup

  ! Entry point called by boot/boot.S once the CPU is in 64-bit long mode.
  ! Does not return.  magic and mbi arrive by value per the SysV AMD64 C ABI,
  ! in EDI and RSI.
  subroutine kernel_main(magic, mbi) bind(c, name="kernel_main")
    implicit none
    integer(c_int32_t), intent(in), value :: magic
    integer(c_int64_t), intent(in), value :: mbi
    integer(c_int32_t) :: status
    ! SEPARATE from `status`, which every bring-up after 3.2b overwrites.  The
    ! headline below is irq_bringup's verdict and nobody else's.
    integer(c_int32_t) :: irq_status

    ! Scalar stores, not an array assignment: gfortran may lower that to a
    ! memset call, which is an undefined symbol in a kernel with no libc.
    fk_boot_sentinel(1) = FK_BOOT_TAG
    fk_boot_sentinel(2) = magic
    ! Masked to 32 bits because the sentinel word is; INT() alone on a value
    ! with bit 31 set would be a range violation.
    fk_boot_sentinel(3) = int(iand(mbi, int(z'FFFFFFFF', c_int64_t)), c_int32_t)
    fk_boot_sentinel(4) = ieor(FK_BOOT_TAG, magic)

    ! After the sentinel: the stores are the evidence this routine ran, and
    ! must not be sequenced behind a driver that touches hardware.
    status = serial_init(FK_SERIAL_COM1)

    ! Sequence association (F2018 15.5.2.11): FK_BANNER is a character scalar
    ! and the dummy is character(kind=c_char) :: s(*), so the call passes the
    ! address of the .rodata literal and copies nothing.
    call serial_print_string(FK_BANNER)

    if (status /= 0_c_int32_t) call serial_print_string(FK_SELFTEST_FAILED)

    call gdt_init()
    call serial_print_string(FK_GDT_READY)

    ! Before the IDT: idt_init points vector 8 at an IST slot, and a #DF taken
    ! before LTR has run finds a null task register and triple-faults.
    call tss_init()
    call serial_print_string(FK_TSS_READY)

    call idt_init()
    call serial_print_string(FK_IDT_READY)

    if (pic_remap() == 0_c_int32_t) then
       call serial_print_string(FK_PIC_READY)
    else
       call serial_print_string(FK_PIC_FAILED)
    end if

    ! The PMM (roadmap 3.4).  After the IDT so a malformed map that faults is
    ! reported instead of resetting the machine, and after the PIC so a
    ! spurious IRQ during the long bitmap walk cannot arrive as an exception
    ! vector.  Before the deliberate fault, which never returns.
    call serial_print_string(FK_PMM_START)
    status = pmm_init(mbi)
    if (status == FK_PMM_OK) then
       if (pmm_front_end() == FK_PMM_FRONT_EFI) then
          call serial_print_string(FK_PMM_FRONT_EFI_MSG)
       else
          call serial_print_string(FK_PMM_FRONT_MB2_MSG)
       end if
       call pmm_verify(mbi)
    else
       call serial_print_string(FK_PMM_INIT_FAILED)
       call serial_print_hex(int(status, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
    end if

    ! roadmap 2.2, and it must run HERE: fb_probe dereferences the loader's
    ! structure at a physical address, which only the identity window makes
    ! readable, and its answer decides which 2 MiB pages the linear map below
    ! must leave out.  Nothing is mapped or drawn yet.
    call serial_print_string(FK_FB_START)
    status = fb_probe(mbi)
    if (status == FK_FB_OK) then
       call serial_print_string(FK_FB_GEOM)
       call serial_print_hex(fk_fb_info(FK_FB_BASE), 16_c_int32_t)
       call serial_print_string(FK_PMM_SLASH)
       call serial_print_hex(fk_fb_info(FK_FB_PITCH), 8_c_int32_t)
       call serial_print_string(FK_PMM_SLASH)
       call serial_print_hex(fk_fb_info(FK_FB_WIDTH), 8_c_int32_t)
       call serial_print_string(FK_PMM_SLASH)
       call serial_print_hex(fk_fb_info(FK_FB_HEIGHT), 8_c_int32_t)
       call serial_print_string(FK_PMM_SLASH)
       call serial_print_hex(fk_fb_info(FK_FB_BPP), 2_c_int32_t)
       call serial_print_string(FK_NL)
       call serial_print_string(FK_FB_CHAN)
       call serial_print_hex(fk_fb_info(FK_FB_MASKS), 16_c_int32_t)
       call serial_print_string(FK_NL)
       call vmm_reserve_mmio(fk_fb_info(FK_FB_BASE), fk_fb_info(FK_FB_BYTES))
    else
       call serial_print_string(FK_FB_PROBE_BAD)
       call serial_print_hex(int(status, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
    end if

    ! The LAPIC page must come out of the linear map BEFORE the linear map is
    ! built, for the reason the framebuffer did: 0xFEE00000 is below top-of-RAM
    ! on this machine, so the physmap would otherwise cover it write-back and
    ! two memory types for one physical page is undefined (SDM Vol.3 11.12.4).
    ! Only the reservation happens here; the mapping needs the tables to exist.
    call vmm_reserve_mmio(lapic_msr_base(), FK_PMM_PAGE_SIZE)

    ! The VMM (roadmap 3.5) and the higher-half handoff (roadmap 1.2b).  AFTER
    ! the PMM, which dereferences the loader's structure through the identity
    ! window this step takes away, and after pmm_verify, which hands the
    ! allocator back exactly as pmm_init produced it.
    call serial_print_string(FK_VMM_START)
    status = vmm_init()
    if (status == FK_VMM_OK) then
       call vmm_report()
       call vmm_handoff()
    else
       call serial_print_string(FK_VMM_INIT_FAILED)
       call serial_print_hex(int(status, c_int64_t), 8_c_int32_t)
       call serial_print_string(FK_NL)
       ! Not a fall-through: every fault below is raised at an address whose
       ! mapping this kernel no longer knows anything about.
       call fk_cpu_halt()
    end if

    ! roadmap 2.2 + 2.4, after the handoff: the PAT write, the write-combining
    ! mapping and the first pixels all belong to the VMM's hierarchy.
    status = fb_bringup()

    ! roadmap 3.2b.  After the handoff, and before the deliberate fault: every
    ! FK_FAULT_MODE build runs with interrupts live from here on, so the tick
    ! proof rides on all of them the way 3.4's and 3.5's verdicts do.
    call lapic_bringup()

    call acpi_bringup(mbi)

    irq_status = irq_bringup()

    call ioapic_bringup()

    call pcie_bringup()

    ! Needs a running clock, so it comes after the timer is live.
    call console_scroll_probe()

    ! roadmap 4.0.  After the VMM (it maps pages) and after the PMM (it takes
    ! frames), and with interrupts already live so the allocator is exercised
    ! on a machine that is being interrupted rather than a quiet one.
    ! NOT PREEMPTION-SAFE, and it runs before the scheduler for that reason.
    ! Nothing in fk_heap_m takes a lock, so kmalloc from an interrupt handler
    ! or from two threads at once will corrupt the block list.  No open roadmap
    ! box owns that; today the rule is that only this thread allocates, and it
    ! stops allocating before sched_start.
    heap_next = FK_VMM_HEAP
    status = heap_bringup()

    call dma_bringup()

    call vfs_bringup()

    ! roadmap 4.0's second half.  Last, because from here on this routine is
    ! one of three threads rather than the only one, and everything above
    ! wanted a machine that was not being switched out from under it.
    status = sched_bringup()

    ! How the boot ends.  The default raises nothing at all; every other value
    ! raises one fault, from the CPU and never simulated by a call.
    if (FK_FAULT_MODE == FK_FAULT_NONE) then
       ! Earned, not announced: irq_bringup has already printed a FAIL line for
       ! whichever property did not hold, and this one must not appear under it.
       if (irq_status == 0_c_int32_t) call serial_print_string(FK_IRQ_ALIVE)
       ! Parks with IF SET, so the timer goes on firing and fk_tick_count can be
       ! watched advancing from outside the guest.  Never returns.
       call fk_cpu_idle()
    else if (FK_FAULT_MODE == FK_FAULT_PMM_OOM) then
       call pmm_drain_to_oom()
    else if (FK_FAULT_MODE == FK_FAULT_GUARD) then
       call serial_print_string(FK_TRIGGER_GUARD)
       fk_probe = fk_peek64(fk_boot_stack_bottom() - 8_c_int64_t)
    else if (FK_FAULT_MODE == FK_FAULT_IDMAP) then
       call serial_print_string(FK_TRIGGER_IDMAP)
       fk_probe = fk_peek64(FK_PHYS_1MIB)
    else if (FK_FAULT_MODE == FK_FAULT_PANIC) then
       call panic_code(FK_PANIC_REASON, int(z'1400', c_int64_t))
    else if (FK_FAULT_MODE == FK_FAULT_WP) then
       call serial_print_string(FK_TRIGGER_WP)
       call fk_poke64(fk_text_start(), 0_c_int64_t)
    else if (FK_FAULT_MODE == 8_c_int32_t) then
       call serial_print_string(FK_TRIGGER_DF)
       call fk_smash_stack()
    else
       call serial_print_string(FK_TRIGGER_DE)
       fk_dividend = 1_c_int32_t
       fk_divisor  = 0_c_int32_t
       fk_quotient = fk_dividend / fk_divisor
    end if

    ! Reached only if the fault returned, which no gate installed here does.
    call serial_print_string(FK_NO_FAULT)
    call fk_cpu_halt()
  end subroutine kernel_main

end module fk_kmain_m
