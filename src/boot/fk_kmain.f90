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
                                         c_null_char, c_funloc
  use fk_serial_m, only: FK_SERIAL_COM1, serial_init, serial_print_string, &
                         serial_print_hex
  use fk_gdt_m,    only: gdt_init
  use fk_tss_m,    only: tss_init
  use fk_idt_m,    only: idt_init, fk_irq_spurious, idt_set_panic_colors
  use fk_pic_m,    only: pic_remap, pic_unmask, pic_imr
  use fk_pit_m,    only: FK_PIT_HZ, FK_PIT_IRQ, pit_init, fk_tick_count, &
                         fk_first_rip, fk_first_rflags
  use fk_pmm_m,    only: FK_PMM_PAGE_SIZE, FK_PMM_OK, FK_PMM_E_UNALIGNED, &
                         FK_PMM_E_LOCKED, FK_PMM_E_DOUBLE_FREE, &
                         pmm_init, pmm_alloc_page, pmm_free_page, &
                         pmm_total_pages, pmm_free_pages, pmm_ignored_bytes, &
                         pmm_region_count, pmm_region_base, pmm_region_len, &
                         pmm_region_type, pmm_verify_reserved, &
                         pmm_verify_kernel_locked, pmm_alloc_page_from
  use fk_fbinfo_m, only: FK_FB_OK, FK_FB_BASE, FK_FB_PITCH, FK_FB_WIDTH, &
                         FK_FB_HEIGHT, FK_FB_BPP, FK_FB_MASKS, FK_FB_BYTES, &
                         fk_fb_info, fb_probe, fb_pixel_pack, fb_note_mapping
  use fk_gop_renderer_m, only: vga_init_framebuffer, vga_fill_rect, &
                         vga_width, vga_height, vga_print_string
  use fk_console_m, only: FK_CON_OK, console_init, console_write, &
                         console_print_hex, console_cols, console_rows, &
                         console_ready, fk_console_scrolls
  use fk_vmm_m,    only: FK_VMM_OK, FK_VMM_SECTIONS, FK_VMM_SCRATCH, &
                         FK_PTE_P, FK_PTE_RW, FK_PTE_NX, &
                         vmm_init, vmm_activate, vmm_drop_identity, &
                         vmm_map_page, vmm_translate, vmm_phys_of, &
                         vmm_pml4_phys, vmm_table_frames, vmm_physmap_top, &
                         vmm_nx_enabled, vmm_verify_image, vmm_read_cr3, &
                         vmm_section_start, vmm_section_end, vmm_section_flags, &
                         vmm_guard_page, vmm_phys_to_virt, &
                         FK_VMM_MMIO, FK_VMM_HEAP, FK_VMM_WC, &
                         vmm_reserve_mmio, vmm_map_mmio, vmm_pat_arm, &
                         vmm_read_pat
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
       "Fortran Kernel: PMM allocated 5 contiguous frames." // &
       FK_CRLF // c_null_char
  character(kind=c_char, len=*), parameter :: FK_PMM_ALLOC_BAD = &
       "Fortran Kernel: PMM allocation is NOT contiguous." // &
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
    integer(c_int32_t) :: i, n, t
    integer(c_int64_t) :: b, l, base
    integer(c_int64_t) :: pg(FK_PMM_TEST_PAGES), again(FK_PMM_TEST_PAGES)
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
       if (pg(i) == 0_c_int64_t) ok = .false.
       if (i > 1_c_int32_t) then
          if (pg(i) /= pg(i - 1_c_int32_t) + FK_PMM_PAGE_SIZE) ok = .false.
       end if
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
    base = pmm_alloc_page()
    if (base == 0_c_int64_t) ok = .false.
    do i = 2_c_int32_t, FK_PMM_CURSOR_PAGES
       if (pmm_alloc_page() == 0_c_int64_t) ok = .false.
    end do
    if (pmm_free_page(base) /= FK_PMM_OK) ok = .false.
    if (pmm_alloc_page() /= base) ok = .false.
    ! Hand the block back.  The addresses are computed rather than remembered:
    ! they are contiguous, which the verdict above has already established, and
    ! if they are not then these frees refuse and this verdict fails too.
    do i = 0_c_int32_t, FK_PMM_CURSOR_PAGES - 1_c_int32_t
       if (pmm_free_page(base + int(i, c_int64_t) * FK_PMM_PAGE_SIZE) &
           /= FK_PMM_OK) ok = .false.
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
       call console_write(mark, 2_c_int32_t)
       call serial_print_string(mark)
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
    if (fk_fb_info(FK_FB_BASE) == 0_c_int64_t) return

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
    status = irq_bringup()

    ! Needs a running clock, so it comes after the timer is live.
    call console_scroll_probe()

    ! roadmap 4.0.  After the VMM (it maps pages) and after the PMM (it takes
    ! frames), and with interrupts already live so the allocator is exercised
    ! on a machine that is being interrupted rather than a quiet one.
    heap_next = FK_VMM_HEAP
    status = heap_bringup()

    ! roadmap 4.0's second half.  Last, because from here on this routine is
    ! one of three threads rather than the only one, and everything above
    ! wanted a machine that was not being switched out from under it.
    status = sched_bringup()

    ! How the boot ends.  The default raises nothing at all; every other value
    ! raises one fault, from the CPU and never simulated by a call.
    if (FK_FAULT_MODE == FK_FAULT_NONE) then
       ! Earned, not announced: irq_bringup has already printed a FAIL line for
       ! whichever property did not hold, and this one must not appear under it.
       if (status == 0_c_int32_t) call serial_print_string(FK_IRQ_ALIVE)
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
