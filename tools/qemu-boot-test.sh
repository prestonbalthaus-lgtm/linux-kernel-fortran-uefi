#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Boots build/boot/fortran-kernel.iso in a headless QEMU and asserts what the
# running guest did: the four-word handoff record in guest physical memory
# (read over QMP), every string COM1 must carry, no string it must not, the
# timer tick counter read TWICE while the guest runs, and -- on request -- the
# state of the task register and the two 8259s as the DEVICE MODELS report it
# rather than as the kernel claims it.
#
# Usage:
#   tools/qemu-boot-test.sh              boot the ISO and assert
#   tools/qemu-boot-test.sh --selftest   prove the assertion logic (no QEMU)
#   tools/qemu-boot-test.sh --smoke      prove the QMP plumbing against a
#                                        kernel-less guest, and that both
#                                        positive assertions refuse it
#
# Environment overrides (all optional):
#   FK_ISO            path to the ISO           (default build/boot/...)
#   FK_KERNEL         path to the ELF           (default build/boot/kernel.elf)
#   FK_BOOT_WAIT      seconds before first dump (default 3)
#   FK_BOOT_DEADLINE  seconds to keep retrying  (default 45)
#   FK_POLL_INTERVAL  seconds between attempts  (default 1)
#   FK_EXPECT_SERIAL  strings COM1 must carry, ONE PER LINE -- all must appear
#   FK_REJECT_SERIAL  strings COM1 must NOT carry, one per line -- any is fatal
#   FK_CHECK_HW       non-empty: also assert TR and the 8259s over QMP
#   FK_CHECK_FB       0 to skip the framebuffer assertion (default: on). The
#                     bar is drawn once, before the CPU parks, so it survives a
#                     panic build too.
#   FK_FB_EXPECT      'console' (default) or 'panic': which palette the console
#                     band must be carrying. Set it to panic for an
#                     FK_FAULT_MODE build -- that is what asserts the register
#                     dump reached the SCREEN and not only COM1.
#   FK_CHECK_DMA      0 to skip the DMA-run assertion (default: on). Set it to
#                     0 for a build that ends in a deliberate panic, for
#                     FK_CHECK_SCHED's reason: the run is taken during bringup
#                     and a panic build never gets that far.
#   FK_CHECK_SCHED    0 to skip the scheduler/heap assertion (default: on).
#                     Set it to 0 for a build that ends in a deliberate panic:
#                     the CPU is halted, so no thread is running to count.
#   FK_CHECK_TICKS    0 to skip the "still ticking" assertion (default: on).
#                     Set it to 0 for a build that ends in a deliberate panic:
#                     the CPU is halted with IF clear, so the counter is frozen
#                     and frozen is the CORRECT answer there.
#   FK_MACHINE        QEMU machine type (default: q35). The DEFAULT MOVED at
#                     roadmap 4.2 and the reason is not preference: the
#                     i440FX board QEMU boots by default emits four ACPI
#                     tables and none of them is MCFG, so there is no ECAM
#                     window on it and nothing for 4.2 to find. q35 emits
#                     five. FK_MACHINE=pc still reaches the no-MCFG path
#                     deliberately, and the kernel treats it as a fact about
#                     the machine rather than as a failure.
#   FK_ACCEL          force 'kvm' or 'tcg'
#   FK_SMP / FK_MEM   override the mandated 6 vCPU / 24 GB allocation
set -uo pipefail
cd "$(dirname "$0")/.."

SENTINEL="tools/qmp-sentinel.py"
# roadmap 5.2. Eight key EVENTS, not two keystrokes: shift-a proves the
# modifier byte is read, and holding 'a' down while 'b' arrives proves the
# previous report is subtracted. A trailing "+" is a press and "-" a release.
KBD_KEYS="${FK_KBD_KEYS:-shift+,a+,a-,shift-,a+,b+,b-,a-}"
KBD_CHARS="${FK_KBD_CHARS:-Aab}"
KBD_REPORT="${FK_KBD_REPORT:-0x40000}"
KBD_TIMEOUT="${FK_KBD_TIMEOUT:-30}"
ISO="${FK_ISO:-build/boot/fortran-kernel.iso}"
KERNEL="${FK_KERNEL:-build/boot/kernel.elf}"
BOOT_WAIT="${FK_BOOT_WAIT:-3}"
DEADLINE="${FK_BOOT_DEADLINE:-45}"
POLL_INTERVAL="${FK_POLL_INTERVAL:-1}"

# The defaults must stay byte-for-byte the literals in src/boot/fk_kmain.f90.
# Both are LISTS, one pattern per line: the positive one must match in full,
# the negative one must not match at all.
#
# roadmap 3.4 added six verdicts and their FAIL twins. They are DEFAULTS and
# not something a caller has to opt into, because the shipped image prints them
# on every boot: a verdict the gate does not refuse is one the kernel is free to
# get wrong. Note that each pair is one property -- the PASS line proves the
# kernel reached the check, the FAIL line proves it did not fail it, and a boot
# that crashed before the PMM ran satisfies neither.
FK_PMM_PASS_LINES=$'Fortran Kernel: PMM reserved and ACPI frames are all marked used.
Fortran Kernel: PMM locked the kernel image and the loader map out.
Fortran Kernel: PMM allocated 5 distinct, aligned frames.
Fortran Kernel: PMM freed and reclaimed the same 5 frames.
Fortran Kernel: PMM refused a double, unaligned and locked free.
Fortran Kernel: PMM rewound its scan cursor to a freed frame.'
FK_PMM_FAIL_LINES=$'Fortran Kernel: PMM init FAILED, status 0x
Fortran Kernel: PMM reserved or ACPI frames are STILL FREE.
Fortran Kernel: PMM did NOT lock the kernel image out.
Fortran Kernel: PMM allocation FAILED: repeated or misaligned frame.
Fortran Kernel: PMM reclaim FAILED.
Fortran Kernel: PMM guard FAILED.
Fortran Kernel: PMM cursor rewind FAILED.'

# roadmap 3.5 and 1.2b, on the same terms. Three of these are worth reading
# twice because they are not verdicts the kernel awards itself:
#
#   "[0x100000] = 0x00000000E85250D6" is a LOAD from physical 1 MiB performed
#   after CR3 was pointed at the VMM's own hierarchy, and the value is this
#   image's Multiboot2 header magic. It proves the new tables carried the
#   identity window, and that the read landed on this kernel rather than
#   anywhere else -- which the "identity window is dead" line immediately
#   below it then takes away.
#
#   " R-X" and the REJECTED "RWX" are the W^X property, asserted on the
#   PERMISSION COLUMN OF THE LIVE TABLES rather than on the ELF's segment
#   flags. They survive a relayout: no address appears in either pattern.
#   linkscript-test.sh asks the same question of the image; this asks it of
#   the page tables the CPU is actually walking, and those are different
#   facts -- an image with RE/R/RW segments can still be mapped writable.
FK_VMM_PASS_LINES=$'Fortran Kernel: VMM has EFER.NXE and CR0.WP, so the permissions bite.
Fortran Kernel: VMM mapped every kernel page with the asked-for permission.
Fortran Kernel: VMM left the stack guard page unmapped.
Fortran Kernel: identity window still live, [0x100000] = 0x00000000E85250D6
Fortran Kernel: PML4[0] unmapped; the identity window is dead.
Fortran Kernel: VMM mapped a frame above 4 GiB and read back what it wrote.
 R-X'
FK_VMM_FAIL_LINES=$'Fortran Kernel: VMM init FAILED, status 0x
Fortran Kernel: VMM could not enable NX; .rodata is not no-execute.
Fortran Kernel: VMM section permissions are WRONG, pages 0x
Fortran Kernel: VMM guard page is MAPPED.
Fortran Kernel: PML4[0] is STILL MAPPED.
Fortran Kernel: VMM high-frame mapping FAILED.
RWX'

# roadmap 3.2b, and the last two lines are the milestone. Two of these carry a
# value in full rather than a prefix, deliberately:
#
#   "hz/divisor 0x00000064/0x00002E9C" is 1193182 rounded over 100, computed by
#   the kernel from the crystal rate. A PIT left at the firmware's divisor still
#   ticks -- at 18.2 Hz -- so a prefix match would accept a chip nobody
#   programmed.
#
#   "8259 IMR now 0x0000FFFE" is read back off both chips. An unmask that wrote
#   to the wrong port, or to the slave, leaves this at 0xFFFF while every other
#   line in the boot still passes.
#
# The rest are prefixes because they carry an address or a live count.
# roadmap 4.1.  Every number here is the firmware's, cross-checked against an
# independent host-side walk of the same tables.  The IRQ0 override is the one
# that decides how the IOAPIC must be programmed at 4.2, and the agree line is
# the only fact in this run derived from TWO sources -- the MADT's own header
# and the IA32_APIC_BASE readback from 3.3.
FK_ACPI_PASS_LINES=$'Fortran Kernel: MADT cpus total/enabled/skipped 0x0006/0x0006/0x0000
Fortran Kernel: MADT ioapics/first-addr/gsi-base 0x0001/0x00000000FEC00000/0x00000000
Fortran Kernel: MADT overrides/IRQ0-GSI 0x0005/0x0002
Fortran Kernel: MADT NMI entries/LINT 0x0001/0x01
Fortran Kernel: MADT and IA32_APIC_BASE agree on 0x00000000FEE00000'
FK_ACPI_FAIL_LINES=$'Fortran Kernel: ACPI init FAILED, status 0x
Fortran Kernel: ACPI found no MADT.
Fortran Kernel: MADT parse FAILED, status 0x
Fortran Kernel: MADT and IA32_APIC_BASE DISAGREE.'

# roadmap 3.3.  The SVR value is spelled out: 0x1FF is the spurious vector in
# bits 7:0 with bit 8, the software-enable, set -- an APIC that was mapped but
# never enabled reads 0x0FF and passes a looser pattern. LINT0 masked is the
# assertion that the legacy 8259 no longer reaches the CPU through the LAPIC.
FK_LAPIC_PASS_LINES=$'Fortran Kernel: LAPIC MSR base/enabled 0x00000000FEE00000/0x00000001
Fortran Kernel: LAPIC id/version/SVR 0x00000000/0x00050014/0x000001FF
Fortran Kernel: LAPIC LINT0/LINT1 0x00000700/0x00000400
Fortran Kernel: LAPIC software-enabled, LINT0 ExtINT, LINT1 NMI.'
FK_LAPIC_FAIL_LINES=$'Fortran Kernel: LAPIC is DISABLED in IA32_APIC_BASE; not mapped.
Fortran Kernel: LAPIC mapping FAILED, status 0x
Fortran Kernel: LAPIC FAILED its own readback.'

FK_IRQ_PASS_LINES=$'Fortran Kernel: PIT channel 0 hz/divisor 0x00000064/0x00002E9C.
Fortran Kernel: 8259 IMR now 0x0000FFFE, IRQ0 is the only line open.
Fortran Kernel: RFLAGS.IF is set, the CPU is interruptible, RFLAGS = 0x
Fortran Kernel: IRQ0 ticks before/after/spurious 0x
Fortran Kernel: the first tick interrupted kernel .text with IF set, RIP/RFLAGS 0x
Fortran Kernel: interrupts are live and the kernel is still running (roadmap 3.2b).'
FK_IRQ_FAIL_LINES=$'Fortran Kernel: PIT divisor is 0, so channel 0 was NOT programmed.
Fortran Kernel: IRQ0 is STILL MASKED after the unmask.
Fortran Kernel: RFLAGS.IF is CLEAR after STI.
Fortran Kernel: IRQ0 never reached the tick target; the timer interrupt did not arrive.
Fortran Kernel: the first tick\'s saved frame is NOT kernel .text with IF set.'

# roadmap 2.2 and 2.4. Three of these carry a value rather than a prefix:
#
#   "IA32_PAT is 0x0007010600070106" is READ BACK OFF THE CPU after the wrmsr.
#   The reset value differs from it in exactly the byte -- PA1 -- that decides
#   whether the framebuffer is write-combining or write-through, so a prefix
#   match, or a kernel that printed the constant it meant to write, would
#   accept a PAT nobody programmed.
#
#   "no write-back alias in the linear map" is the SDM 11.12.4 property. The
#   linear map covers every byte below top-of-RAM, and the framebuffer BAR is
#   under 4 GiB on this machine, so the aperture is inside it by default and
#   the hole has to be punched deliberately.
#
#   The channel line carries the packed masks in full. 0x...0810 means red at
#   bit 16 and blue at bit 0 -- BGRX -- and a kernel that assumed RGB would
#   print the same geometry line above it and draw a blue panic banner.
FK_FB_PASS_LINES=$'Fortran Kernel: GOP IA32_PAT is 0x0007010600070106, PAT index 1 is write-combining.
Fortran Kernel: GOP framebuffer PTE selects PAT index 1, write-combining.
Fortran Kernel: GOP framebuffer has no write-back alias in the linear map.
Fortran Kernel: GOP renderer armed on the mapped framebuffer (roadmap 2.4).'
FK_FB_FAIL_LINES=$'Fortran Kernel: GOP framebuffer tag REJECTED, status 0x
Fortran Kernel: GOP could NOT program the PAT; the framebuffer is not write-combining.
Fortran Kernel: GOP framebuffer mapping FAILED, status 0x
Fortran Kernel: GOP framebuffer PTE is NOT write-combining.
Fortran Kernel: GOP framebuffer is ALIASED write-back in the linear map.
Fortran Kernel: GOP renderer REFUSED the framebuffer, status 0x'

# roadmap 2.4 and 4.0. The console line carries cols/rows in full: a console
# that armed on the wrong geometry still prints "live" and then draws off the
# end of a scanline.
#
# The heap's coalescing verdict is the one worth reading twice. Every other
# heap line passes on an allocator that never merges anything -- alignment,
# non-overlap, patterns and the guards are all properties of a heap that leaks
# a fragment per free. "blocks 0x00000001" after everything is freed is the
# only line that fails on one.
FK_CON_PASS_LINES=$'Fortran Kernel: console is live on the framebuffer, cols/rows 0x00000080/0x0000002F
Fortran Kernel: console scrolled 0x'
FK_CON_FAIL_LINES=$'Fortran Kernel: console REFUSED the framebuffer geometry, status 0x
Fortran Kernel: console never scrolled.'

FK_HEAP_PASS_LINES=$'Fortran Kernel: heap returned 16-byte aligned, non-overlapping blocks.
Fortran Kernel: heap kept every block\'s contents across the other allocations.
Fortran Kernel: kzalloc returned memory that was already zero.
Fortran Kernel: heap refused a double free, a stray pointer and a wrapped size.
Fortran Kernel: heap tiles its window exactly, blocks/used/free 0x00000001/0x00000000/
Fortran Kernel: heap coalesced every freed block back into one, largest free 0x'
# roadmap 4.2. The window and device lines carry live values and are prefixes;
# the three VERDICTS are not. "no MCFG table" is a FAILURE on q35 and the
# CORRECT answer under FK_MACHINE=pc, so it is added to the reject list only
# where an MCFG is supposed to exist -- a line that is right on one machine and
# wrong on another cannot be a constant.
FK_PCIE_PASS_LINES=$'Fortran Kernel: PCIe looking for the ECAM window (roadmap 4.2).
Fortran Kernel: the ECAM window has no write-back alias in the linear map.
Fortran Kernel: the ECAM mapping selects PWT and PCD, strong uncacheable.
Fortran Kernel: the PCIe bus was walked and every function reported (roadmap 4.2).
Fortran Kernel: xHCI COMMAND firmware/cleared/enabled 0x
Fortran Kernel: xHCI decode and bus mastering were taken DOWN and put back by this kernel.
Fortran Kernel: xHCI BAR0 0x
Fortran Kernel: xHCI MSI-X cap/entries/bar/offset 0x
Fortran Kernel: xHCI BAR0 mapped strong-UC, virt/phys 0x
Fortran Kernel: xHCI MSI-X entry 0 addr/data/mask 0x
Fortran Kernel: xHCI MSI-X control/command 0x
Fortran Kernel: the xHCI has an MSI-X route to this CPU and INTx is off (roadmap 5.1).
Fortran Kernel: xHCI caplength/version/slots/scratchpads/page 0x
Fortran Kernel: xHCI cmd/event/erst 0x
Fortran Kernel: the xHCI is RUNNING, USBSTS 0x
Fortran Kernel: xHCI NO-OP trb/event/code/ptr 0x
Fortran Kernel: the xHCI executed a command and reported it complete (roadmap 5.1).
Fortran Kernel: the xHCI\'s MSI-X interrupt ARRIVED, count 0x'
FK_KBD_PASS_LINES=$'Fortran Kernel: USB looking for a HID keyboard (roadmap 5.2).
Fortran Kernel: USB port/portsc/speed 0x
Fortran Kernel: USB device/input ctx/report buffer 0x
Fortran Kernel: USB slot/address/state 0x
Fortran Kernel: USB mps0/config/interface 0x
Fortran Kernel: USB EP1 addr/maxpkt/interval 0x
Fortran Kernel: the USB keyboard is addressed, configured and polling (roadmap 5.2).'
FK_KBD_FAIL_LINES=$'Fortran Kernel: the PMM refused a contiguous run for the keyboard.
Fortran Kernel: the USB keyboard bring-up FAILED, status 0x'
# On the i440FX board there is no ECAM window, so no xHCI, so xhci_start never
# runs and neither does the keyboard it calls.  The 5.2 lines are therefore
# REJECT lines there, not missing PASS lines -- their absence is the assertion.
if [[ "${FK_MACHINE:-q35}" == pc ]]; then
  FK_KBD_FAIL_LINES="$FK_KBD_PASS_LINES"$'\n'"$FK_KBD_FAIL_LINES"
  FK_KBD_PASS_LINES=''
fi

FK_NVME_PASS_LINES=$'Fortran Kernel: NVMe looking for a storage controller (roadmap 5.3).
Fortran Kernel: NVMe BAR0 mapped strong-UC, virt/phys 0x
Fortran Kernel: NVMe cap/version/mqes/dstrd 0x
Fortran Kernel: NVMe cc/csts/aqa 0x
Fortran Kernel: NVMe asq/acq 0x
Fortran Kernel: NVMe nsid 1 blocks/lba-bytes 0x
Fortran Kernel: NVMe sector 0 [0..15] 0x
Fortran Kernel: the NVMe controller read sector 0 into memory (roadmap 5.3).'
FK_NVME_FAIL_LINES=$'Fortran Kernel: no NVMe controller on this bus.
Fortran Kernel: the NVMe register block could not be mapped, status 0x
Fortran Kernel: the PMM refused a contiguous run for the NVMe queues.
Fortran Kernel: the NVMe bring-up FAILED, status 0x'
# The i440FX board has no ECAM window, so no NVMe function is ever found and
# nvme_bringup never runs.  Its lines are REJECT lines there; their absence is
# the assertion, exactly as 5.1's and 5.2's are.
if [[ "${FK_MACHINE:-q35}" == pc ]]; then
  FK_NVME_FAIL_LINES="$FK_NVME_PASS_LINES"
  FK_NVME_PASS_LINES=''
fi

# Roadmap 6.1.  These run on EVERY machine, unlike 4.2's and 5.x's: the VFS
# touches no bus and no device, so there is no board on which it does not come
# up.  That is the point of a scaffold and it is asserted rather than assumed.
FK_VFS_PASS_LINES=$'Fortran Kernel: mounting the VFS root (roadmap 6.1).
Fortran Kernel: VFS sb/root/bin/init 0x
Fortran Kernel: /bin/init ino/size/mode 0x
Fortran Kernel: VFS dentries/inodes in use 0x
Fortran Kernel: the VFS resolved /bin/init and refused /bin/init/ (roadmap 6.1).'
FK_VFS_FAIL_LINES=$'Fortran Kernel: the VFS bring-up FAILED, status 0x'

FK_PCIE_FAIL_LINES=$'Fortran Kernel: the ECAM window is STILL mapped write-back in the linear map.
Fortran Kernel: the xHCI REFUSED a COMMAND write; decode or bus mastering did not move.
Fortran Kernel: the xHCI declares NO MSI-X capability; 5.1 has no route.
Fortran Kernel: the xHCI register block could not be mapped, status 0x
Fortran Kernel: the xHCI MSI-X route did NOT read back; the controller has no interrupt.
Fortran Kernel: the xHCI bring-up FAILED, status 0x
Fortran Kernel: the PMM refused a contiguous run for the xHCI rings.
Fortran Kernel: the xHCI never completed the NO-OP; no event arrived.
Fortran Kernel: the xHCI completed its command but sent NO interrupt.
Fortran Kernel: the ECAM mapping is CACHED.
Fortran Kernel: the MCFG table would not parse, status 0x
Fortran Kernel: the ECAM window could not be taken out of the linear map, status 0x
Fortran Kernel: the ECAM window could not be mapped, status 0x
Fortran Kernel: the PCIe list is TRUNCATED; the machine has more functions than slots.'
if [[ "${FK_MACHINE:-q35}" == pc ]]; then
  FK_PCIE_PASS_LINES=$'Fortran Kernel: PCIe looking for the ECAM window (roadmap 4.2).
Fortran Kernel: no MCFG table; this machine has no ECAM window.'
  FK_PCIE_FAIL_LINES=$'Fortran Kernel: the PCIe bus was walked and every function reported (roadmap 4.2).
Fortran Kernel: xHCI COMMAND firmware/cleared/enabled 0x
Fortran Kernel: the xHCI REFUSED a COMMAND write; decode or bus mastering did not move.
Fortran Kernel: the xHCI has an MSI-X route to this CPU and INTx is off (roadmap 5.1).
Fortran Kernel: the xHCI is RUNNING, USBSTS 0x
Fortran Kernel: the xHCI executed a command and reported it complete (roadmap 5.1).'
else
  FK_PCIE_FAIL_LINES="$FK_PCIE_FAIL_LINES
Fortran Kernel: no MCFG table; this machine has no ECAM window."
fi

# roadmap 3.3. The chip/gsi lines carry live values and are prefixes; the three
# VERDICTS are not, and they are what the gate asserts. "still ticks with both
# 8259s masked" is the milestone: it is printed only after fk_tick_count has
# been watched advancing on a machine where the legacy pair can no longer
# deliver anything at all.
FK_IOA_PASS_LINES=$'Fortran Kernel: IOAPIC taking the timer off the 8259s (roadmap 3.3).
Fortran Kernel: the IOAPIC page has no write-back alias in the linear map.
Fortran Kernel: both 8259s report every line masked.
Fortran Kernel: the timer still ticks with both 8259s masked (roadmap 3.3).'
FK_IOA_FAIL_LINES=$'Fortran Kernel: the MADT declared no IOAPIC; the 8259s keep the timer.
Fortran Kernel: the IOAPIC page is STILL mapped write-back in the linear map.
Fortran Kernel: an 8259 REFUSED to mask.
Fortran Kernel: the IOAPIC redirection entry did NOT read back as written.
Fortran Kernel: the timer STOPPED once the 8259s were masked.
Fortran Kernel: the IOAPIC did not accept the redirection entry, status 0x
Fortran Kernel: the IOAPIC page could not be taken out of the linear map, status 0x
Fortran Kernel: the IOAPIC page could not be mapped, status 0x'
# roadmap 3.x. The phys/pages line is a prefix -- the address is whatever the
# allocator happened to return -- so what is asserted here is the VERDICT, and
# the frames themselves are checked over QMP.
FK_DMA_PASS_LINES=$'Fortran Kernel: DMA asking the PMM for a contiguous run (roadmap 3.x).
Fortran Kernel: every frame of the run translates to the next physical page.'
FK_DMA_FAIL_LINES=$'Fortran Kernel: the DMA run is NOT contiguous in physical memory.
Fortran Kernel: pmm_alloc_contiguous refused the run.'
# roadmap 4.0's scheduler. "switches/A/B" carries three live counts, so it is
# a prefix -- but the line only prints after the boot thread has watched BOTH
# spawned threads' own counters pass 2, which no single switch can produce.
FK_SCHED_PASS_LINES=$'Fortran Kernel: scheduler tasks/current 0x00000003/0x00000001
Fortran Kernel: preemption is on; the timer now switches tasks.
Fortran Kernel: both threads ran, switches/A/B 0x'
FK_SCHED_FAIL_LINES=$'Fortran Kernel: scheduler could NOT spawn a thread, status 0x
Fortran Kernel: a spawned thread NEVER ran; the switch did not happen.'

FK_HEAP_FAIL_LINES=$'Fortran Kernel: heap could not get memory from the PMM/VMM.
Fortran Kernel: heap blocks are misaligned or OVERLAP.
Fortran Kernel: heap blocks OVERWROTE each other.
Fortran Kernel: kzalloc returned DIRTY memory.
Fortran Kernel: heap ACCEPTED a free it should have refused.
Fortran Kernel: heap did NOT coalesce; it is fragmented, blocks 0x
Fortran Kernel: heap FAILED its own consistency walk, faults 0x'

# THE UEFI PATH HAS NO FRAMEBUFFER, and this is stated here rather than left to
# be discovered as a failing assertion.  GRUB's EFI video driver answers
# "no suitable video mode found" under OVMF, so Multiboot2 tag 8 is absent and
# fk_fbinfo correctly REJECTS the probe -- the kernel is behaving properly and
# the screen simply does not exist on this path.  The video assertions are
# therefore dropped for FK_FIRMWARE=uefi, and dropping them is announced: a gate
# that silently narrows what it checks reads exactly like one that passed.
# EVERYTHING is asserted on the UEFI path exactly as it is on the BIOS one --
# the video assertions included, since roadmap 2.2's second half.
if [[ "${FK_FIRMWARE:-bios}" == uefi ]]; then
  # roadmap 0.3: the assertion that the SECOND front end is the one that ran.
  # Tag 17 exists only where the loader came up on UEFI, so this line is what
  # separates "booted through OVMF" from "parsed the EFI map".
  FK_PMM_PASS_LINES="$FK_PMM_PASS_LINES
Fortran Kernel: PMM front end is the UEFI GetMemoryMap array (Multiboot2 tag 17).
Fortran Kernel: ACPI root is the XSDT (Multiboot2 tag 15)."
  # roadmap 2.2's second half. THESE ASSERTIONS USED TO BE DELETED HERE, and
  # the deletion was the danger: the UEFI gate was GREEN with no framebuffer
  # at all, so it would have stayed green whether or not one ever appeared.
  # `insmod all_video` in the ISO's grub.cfg is what changed -- GRUB loads a
  # video DRIVER under OVMF, sets the mode the kernel's header tag 5 asks for,
  # and hands over a real tag 8. The lines below are therefore asserted on
  # BOTH firmware paths now, and the only thing that differs is the base:
  # 0xFD000000 on SeaBIOS, 0x80000000 under OVMF, which is why neither is
  # written down anywhere.
  : "${FK_CHECK_FB:=1}"
  export FK_CHECK_FB
fi

[[ "${FK_FIRMWARE:-bios}" == uefi ]] || FK_PMM_PASS_LINES="$FK_PMM_PASS_LINES
Fortran Kernel: PMM front end is the Multiboot2 memory map (tag 6).
Fortran Kernel: ACPI root is the RSDT (Multiboot2 tag 14)."

EXPECT_SERIAL="${FK_EXPECT_SERIAL:-Fortran Kernel: UART Serial Initialized.
$FK_PMM_PASS_LINES
$FK_VMM_PASS_LINES
$FK_FB_PASS_LINES
$FK_CON_PASS_LINES
$FK_HEAP_PASS_LINES
$FK_DMA_PASS_LINES
$FK_SCHED_PASS_LINES
$FK_LAPIC_PASS_LINES
$FK_ACPI_PASS_LINES
$FK_IRQ_PASS_LINES
$FK_IOA_PASS_LINES
$FK_PCIE_PASS_LINES
$FK_KBD_PASS_LINES
$FK_NVME_PASS_LINES
$FK_VFS_PASS_LINES}"
REJECT_SERIAL="${FK_REJECT_SERIAL:-Fortran Kernel: COM1 loopback self-test FAILED.
$FK_PMM_FAIL_LINES
$FK_VMM_FAIL_LINES
$FK_FB_FAIL_LINES
$FK_CON_FAIL_LINES
$FK_HEAP_FAIL_LINES
$FK_DMA_FAIL_LINES
$FK_SCHED_FAIL_LINES
$FK_LAPIC_FAIL_LINES
$FK_ACPI_FAIL_LINES
$FK_IRQ_FAIL_LINES
$FK_IOA_FAIL_LINES
$FK_PCIE_FAIL_LINES
$FK_KBD_FAIL_LINES
$FK_NVME_FAIL_LINES
$FK_VFS_FAIL_LINES}"

# Blank lines are dropped, and NOT because they are untidy: an empty pattern
# matches every file, so one stray newline would turn an assertion into a
# no-op that passes on any input whatsoever.
readarray -t EXPECTS < <(printf '%s\n' "$EXPECT_SERIAL" | grep -v '^[[:space:]]*$')
readarray -t REJECTS < <(printf '%s\n' "$REJECT_SERIAL" | grep -v '^[[:space:]]*$')
if (( ${#EXPECTS[@]} == 0 )); then
  echo "qemu-boot-test: FK_EXPECT_SERIAL is empty -- there is nothing to assert" >&2
  exit 2
fi

# The project's mandated allocation; QEMU does not preallocate the 24G.
SMP="${FK_SMP:-6}"
MEM="${FK_MEM:-24G}"

# --help prints the header block above.
usage() { sed -n '3,${/^#/!q;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }

MODE=gate
case "${1:-}" in
  --selftest) MODE=selftest ;;
  --smoke)    MODE=smoke ;;
  -h|--help)  usage; exit 0 ;;
  "")         ;;
  *)          echo "qemu-boot-test: unknown option '$1' (try --help)" >&2; exit 2 ;;
esac

rule() { printf '%s\n' "======================================================================"; }
say()  { printf '%s\n' "$*"; }

[[ -r "$SENTINEL" ]] || { say "FAIL: missing $SENTINEL -- the assertion lives there"; exit 1; }

rule
say "PROJECT FORTRAN-KERNEL :: BOOT GATE (1.2 + 1.2b + 2.1 + 3.2b + 3.4 + 3.5)"
rule

if [[ "$MODE" == gate ]]; then
  for f in "$ISO" "$KERNEL"; do
    [[ -f "$f" ]] && continue
    say "FAIL: missing $f"
    say ""
    say "      Build it first (inside the container, as everything is built):"
    say "        ./tools/run.sh iso"
    say ""
    say "      To exercise the gate without a kernel:"
    say "        tools/qemu-boot-test.sh --selftest   (assertion logic)"
    say "        tools/qemu-boot-test.sh --smoke      (QMP plumbing, real QEMU)"
    exit 1
  done
  say "image      : $ISO ($(stat -c %s "$ISO") bytes)"
  say "kernel     : $KERNEL"
  if ! ADDR_OUT=$(python3 "$SENTINEL" addr "$KERNEL" 2>&1 >/dev/null); then
    say "FAIL: cannot locate the sentinel symbol in $KERNEL"; say "$ADDR_OUT"; exit 1
  fi
  say "sentinel   : ${ADDR_OUT#\# }"
elif [[ "$MODE" == smoke ]]; then
  say "image      : NONE (--smoke: kernel-less guest; BOTH assertions MUST refuse it)"
  [[ -f "$KERNEL" ]] || { say "FAIL: --smoke still needs $KERNEL for the symbol address"; exit 1; }
  DEADLINE=0
fi
for pat in "${EXPECTS[@]}"; do say "must carry : \"$pat\""; done
for pat in "${REJECTS[@]}"; do say "must not   : \"$pat\""; done
[[ -n "${FK_CHECK_HW:-}" ]] && say "hw check   : task register and both 8259s, over QMP"
# Defined here rather than beside QEMU_ARGS: the PCI switch below reads it, and
# QEMU_ARGS is not built until after every announcement has been printed.
MACHINE="${FK_MACHINE:-q35}"
CHECK_TICKS="${FK_CHECK_TICKS:-1}"
[[ "$CHECK_TICKS" != 0 ]] && say "tick check : fk_tick_count read twice from the running guest"
CHECK_SCHED="${FK_CHECK_SCHED:-1}"
[[ "$CHECK_SCHED" != 0 ]] && say "sched check: fk_task_runs and fk_heap_stat, read twice while it runs"
CHECK_DMA="${FK_CHECK_DMA:-1}"
[[ "$CHECK_DMA" != 0 ]] && say "dma check  : the contiguous run, read at the physical base it published"
# roadmap 5.1. Off on the pc machine for the same reason the PCI check is:
# that board has no ECAM window, so no controller was ever found.
CHECK_XHCI="${FK_CHECK_XHCI:-1}"
[[ "$MACHINE" == pc ]] && CHECK_XHCI=0
[[ "$CHECK_XHCI" != 0 ]] && say "xhci check : the command and event rings, read where the controller wrote them"
CHECK_VFS="${FK_CHECK_VFS:-1}"
[[ "$CHECK_VFS" != 0 ]] && say "vfs check  : the dentry tree and the path walk, read out of guest memory"
CHECK_NVME="${FK_CHECK_NVME:-1}"
[[ "$MACHINE" == pc ]] && CHECK_NVME=0
[[ "$CHECK_NVME" != 0 ]] && say "nvme check : sector 0, read at its physical base and diffed against the image"
CHECK_KBD="${FK_CHECK_KBD:-1}"
[[ "$MACHINE" == pc ]] && CHECK_KBD=0
[[ "$CHECK_KBD" != 0 ]] && say "kbd check  : key presses injected over QMP, decoded and rendered by the guest"
CHECK_PCI="${FK_CHECK_PCI:-1}"
[[ "$MACHINE" == pc ]] && CHECK_PCI=0
[[ "$CHECK_PCI" != 0 ]] && say "pci check  : the guest's own enumeration against QEMU's info pci, as sets"
CHECK_FB="${FK_CHECK_FB:-1}"
[[ "$CHECK_FB" != 0 ]] && say "fb check   : fk_fb_info, then the pixels at the base it names (${FK_FB_EXPECT:-console} palette)"

if [[ -n "${FK_ACCEL:-}" ]]; then ACCEL="$FK_ACCEL"
elif [[ -r /dev/kvm && -w /dev/kvm ]]; then ACCEL=kvm
else ACCEL=tcg; fi
say "accelerator: $ACCEL$([[ $ACCEL == tcg ]] && echo '  (no usable /dev/kvm -- slower boot)')"

# The QMP socket MUST live on a short path: AF_UNIX sun_path is ~107 bytes and
# a long scratch directory silently breaks bind().
TMP="$(mktemp -d /tmp/fk-boot-test.XXXXXX)"
SOCK="$TMP/qmp.sock"
DUMP="$TMP/sentinel.bin"
QEMU_LOG="$TMP/qemu.log"
SERIAL_LOG="$TMP/serial.log"
QPID=""

cleanup() {
  local rc=$?
  if [[ -n "$QPID" ]] && kill -0 "$QPID" 2>/dev/null; then
    kill -TERM "$QPID" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$QPID" 2>/dev/null || break
      sleep 0.2
    done
    kill -KILL "$QPID" 2>/dev/null || true
  fi
  [[ -n "$QPID" ]] && wait "$QPID" 2>/dev/null || true
  [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP" || true
  return $rc
}
trap cleanup EXIT INT TERM

# bash defers trap handlers until the current foreground child exits, so a bare
# `sleep` would leave the VM alive for the whole nap after a SIGTERM.
nap() { sleep "$1" & wait $! 2>/dev/null || true; }
qemu_alive() { [[ -n "$QPID" ]] && kill -0 "$QPID" 2>/dev/null; }
show_qemu_log() {
  say ""; say "--- QEMU output ---"
  if [[ -s "$QEMU_LOG" ]]; then sed 's/^/  /' "$QEMU_LOG"; else say "  (QEMU said nothing)"; fi
}

#   -F  the strings are literals, so a trailing '.' is not a regex wildcard
#   -a  a stray control byte must not make grep treat the capture as binary
#   --  the expected string is overridable and could begin with '-'
#
# One assertion per LINE of FK_EXPECT_SERIAL. A milestone whose proof is two
# facts -- "the CPU reported a #DF" AND "it did so on the emergency stack" --
# must not be reducible to whichever one is easier to produce, and running the
# whole VM twice to ask two questions of one boot is worse than looping here.
# Blank lines are dropped: an empty pattern matches every file, so a stray
# newline would otherwise turn an assertion into a no-op that always passes.
serial_matches() {
  local pat
  [[ -s "$SERIAL_LOG" ]] || return 1
  for pat in "$@"; do
    grep -aFq -- "$pat" "$SERIAL_LOG" || return 1
  done
  return 0
}

serial_has_banner() { serial_matches "${EXPECTS[@]}"; }

# Any single hit is fatal. The default is the line src/boot/fk_kmain.f90 prints
# when serial_init's loopback probe does not read back the byte it wrote.
serial_has_failure() {
  local pat
  [[ -s "$SERIAL_LOG" ]] || return 1
  for pat in "${REJECTS[@]}"; do
    grep -aFq -- "$pat" "$SERIAL_LOG" && return 0
  done
  return 1
}

# Prove the matcher can FAIL before trusting the fact that it passes -- the
# same standard the sentinel half has been held to since roadmap 1.2. These
# call the REAL serial_has_banner and serial_has_failure; `local` on EXPECTS,
# REJECTS and SERIAL_LOG shadows the globals for everything they call, so
# nothing here is a reimplementation of the logic under test.
FIX_DF_HEADLINE="EXCEPTION 0x08 ERR 0x0000000000000000 -- #DF Double Fault"
FIX_DF_IST="*** #DF ENTERED ON IST1 -- THE EMERGENCY STACK HELD ***"
FIX_DF_NO_IST="*** #DF ENTERED ON THE FAULTING STACK -- NO IST SWITCH ***"

selftest_serial_matching() {
  local pass=0 fail=0 dir
  local SERIAL_LOG
  local -a EXPECTS=("$FIX_DF_HEADLINE" "$FIX_DF_IST")
  local -a REJECTS=("$FIX_DF_NO_IST" "Fortran Kernel: the deliberate fault did NOT trap.")
  dir="$(mktemp -d /tmp/fk-serial-selftest.XXXXXX)"
  SERIAL_LOG="$dir/serial.log"

  # want_banner want_reject <body> <what>
  expect_serial() {
    local want_b=$1 want_r=$2 body=$3 what=$4 gb=0 gr=0
    printf '%s' "$body" > "$SERIAL_LOG"
    serial_has_banner  && gb=1
    serial_has_failure && gr=1
    if (( gb == want_b && gr == want_r )); then
      printf "  \033[32mPASS\033[0m  %s\n" "$what"; pass=$((pass+1))
    else
      printf "  \033[31mFAIL\033[0m  %s -- banner=%d (want %d), reject=%d (want %d)\n" \
             "$what" "$gb" "$want_b" "$gr" "$want_r"; fail=$((fail+1))
    fi
  }

  say "=== COM1 assertion self-test (no QEMU, no kernel) ==="
  expect_serial 1 0 \
    "$FIX_DF_HEADLINE"$'\r\n'"$FIX_DF_IST"$'\r\n' \
    "both expected lines present -> accepted"
  # THE ONE THAT MATTERS. A single-pattern matcher passes this: the exception
  # headline is exactly what a #DF delivered on the broken stack would print
  # too, right up until the push that kills it.
  expect_serial 0 0 "$FIX_DF_HEADLINE"$'\r\n' \
    "the headline WITHOUT the IST1 line -> refused"
  expect_serial 0 0 "$FIX_DF_IST"$'\r\n' \
    "the IST1 line without the headline -> refused"
  expect_serial 1 1 \
    "$FIX_DF_HEADLINE"$'\r\n'"$FIX_DF_NO_IST"$'\r\n'"$FIX_DF_IST"$'\r\n' \
    "a log carrying BOTH verdicts -> the negative assertion still fires"
  expect_serial 0 0 "" "an empty capture -> refused"
  expect_serial 0 0 "SeaBIOS (version 1.17.0)"$'\r\n' \
    "firmware chatter alone -> refused"
  # -F, not a regex: the '***' and '#' in these lines are literal text.
  expect_serial 0 0 "EXCEPTION 0x08 ERR 0x0000000000000000 -- #DF Double Faul"$'\r\n' \
    "a truncated headline -> refused (fixed-string match, not a prefix)"

  rm -rf "$dir"
  unset -f expect_serial
  say "=== $pass passed, $fail failed ==="
  return $(( fail > 0 ))
}

if [[ "$MODE" == selftest ]]; then
  rc=0
  selftest_serial_matching || rc=1
  say ""
  python3 "$SENTINEL" selftest || rc=1
  exit $rc
fi

# CRs are stripped for display only; serial_has_banner greps the file itself.
show_serial_log() {
  say ""; say "--- COM1 output (captured from the guest's serial port) ---"
  if [[ -s "$SERIAL_LOG" ]]; then
    tr -d '\r' < "$SERIAL_LOG" | sed 's/^/  /'
  else
    say "  (the guest wrote nothing to COM1)"
  fi
}

assertion_summary() {
  local sent ser
  if   (( SENTINEL_OK == 1 )); then sent="PASS  the four-word handoff record is present and correct"
  elif (( GOT_DUMP    == 0 )); then sent="FAIL  guest memory never became readable, so it was never asserted"
  else                              sent="FAIL  read back, but not the record src/boot/fk_kmain.f90 promises"
  fi
  if (( SERIAL_OK == 1 )); then ser="PASS  every expected string appeared on COM1"
  else                          ser="FAIL  at least one expected string never appeared"
  fi
  say "  sentinel   (1.2) : $sent"
  say "  COM1 lines (2.1) : $ser"
  # Which one, when it is not all of them: with several patterns "the string
  # never appeared" no longer identifies anything.
  if (( SERIAL_OK == 0 )); then
    local pat
    for pat in "${EXPECTS[@]}"; do
      if serial_matches "$pat"; then say "      found    : \"$pat\""
      else                           say "      MISSING  : \"$pat\""
      fi
    done
  fi
# --smoke boots no kernel, so the negative assertion is vacuous there.
  if [[ "$MODE" == gate ]]; then
    if serial_has_failure; then
      say "  forbidden  lines : FAIL  COM1 carried a line it must not"
      local pat
      for pat in "${REJECTS[@]}"; do
        serial_matches "$pat" && say "      PRESENT  : \"$pat\""
      done
    else
      say "  forbidden  lines : PASS  none of them appeared on COM1"
    fi
    if [[ -n "${FK_CHECK_HW:-}" ]]; then
      if   (( HW_OK == 1 )); then say "  hardware state   : PASS  TR and both 8259s are what the kernel claims"
      elif (( HW_RAN == 0 )); then say "  hardware state   : FAIL  the guest died before it could be asked"
      else                        say "  hardware state   : FAIL  see the monitor output above"
      fi
    fi
    if [[ "$CHECK_FB" != 0 ]]; then
      if   (( FB_OK == 1 )); then  say "  framebuffer      : PASS  the bar in guest memory matches the loader's masks"
      elif (( FB_RAN == 0 )); then say "  framebuffer      : FAIL  the guest died before it could be asked"
      else                         say "  framebuffer      : FAIL  see the pixel comparison above"
      fi
    fi
    if [[ "$CHECK_PCI" != 0 ]]; then
      if   (( PCI_OK == 1 )); then  say "  PCI enumeration  : PASS  the guest's list and QEMU's are the same set"
      elif (( PCI_RAN == 0 )); then say "  PCI enumeration  : FAIL  the guest died before it could be asked"
      else                          say "  PCI enumeration  : FAIL  see the two lists above"
      fi
    fi
    if [[ "$CHECK_XHCI" != 0 ]]; then
      if   (( XHCI_OK == 1 )); then  say "  xHCI controller  : PASS  it executed a command and the interrupt arrived"
      elif (( XHCI_RAN == 0 )); then say "  xHCI controller  : FAIL  the guest died before it could be asked"
      else                           say "  xHCI controller  : FAIL  see the ring dumps above"
      fi
    fi
    if [[ "$CHECK_VFS" != 0 ]]; then
      if   (( VFS_OK == 1 )); then  say "  VFS path walk    : PASS  /bin/init resolved and /bin/init/ was refused"
      elif (( VFS_RAN == 0 )); then say "  VFS path walk    : FAIL  the guest died before it could be asked"
      else                          say "  VFS path walk    : FAIL  see the VFS assertions above"
      fi
    fi
    if [[ "$CHECK_NVME" != 0 ]]; then
      if   (( NVME_OK == 1 )); then  say "  NVMe sector 0    : PASS  the DMA read matches the disk image byte for byte"
      elif (( NVME_RAN == 0 )); then say "  NVMe sector 0    : FAIL  the guest died before it could be asked"
      else                           say "  NVMe sector 0    : FAIL  see the NVMe assertions above"
      fi
    fi
    if [[ "$CHECK_KBD" != 0 ]]; then
      if   (( KBD_OK == 1 )); then  say "  USB keyboard     : PASS  keys were pressed, decoded and rendered"
      elif (( KBD_RAN == 0 )); then say "  USB keyboard     : FAIL  the guest died before it could be asked"
      else                          say "  USB keyboard     : FAIL  see the HID assertions above"
      fi
    fi
    if [[ "$CHECK_DMA" != 0 ]]; then
      if   (( DMA_OK == 1 )); then  say "  DMA run          : PASS  every frame carried its tag at the physical base"
      elif (( DMA_RAN == 0 )); then say "  DMA run          : FAIL  the guest died before it could be asked"
      else                          say "  DMA run          : FAIL  see the frame comparison above"
      fi
    fi
    if [[ "$CHECK_SCHED" != 0 ]]; then
      if   (( SCHED_OK == 1 )); then  say "  scheduler + heap : PASS  both threads' own counters grew, heap is whole"
      elif (( SCHED_RAN == 0 )); then say "  scheduler + heap : FAIL  the guest died before it could be asked"
      else                            say "  scheduler + heap : FAIL  see the counters above"
      fi
    fi
    if [[ "$CHECK_TICKS" != 0 ]]; then
      if   (( TICK_OK == 1 )); then say "  tick advance     : PASS  fk_tick_count grew between two reads"
      elif (( TICK_RAN == 0 )); then say "  tick advance     : FAIL  the guest died before it could be asked"
      else                         say "  tick advance     : FAIL  see the counts above"
      fi
    fi
  fi
}

# -display none : headless.
# -no-reboot    : a triple fault exits QEMU instead of resetting forever.
# -serial file: : a file can be re-read on every poll; a consumed stream cannot.
# -nic none     : without it QEMU attaches a default e1000 on user-mode slirp.
QEMU_ARGS=(
  -machine "$MACHINE"
  -smp "$SMP" -m "$MEM"
  -display none
  -no-reboot
  -serial "file:$SERIAL_LOG"
  -nic none
  -qmp "unix:$SOCK,server,nowait"
  -accel "$ACCEL"
)
# roadmap 5.1. q35 has no USB controller of any kind unless one is asked for,
# so the milestone's own device is part of the machine the gate runs. It takes
# the function set from five to six; the PCI check needs no change for that,
# because it reads 'info pci' off the live monitor and diffs it against the
# guest's list as sets, so both sides grow together. What is hardcoded to five
# is qmp-sentinel's own --selftest fixture, which moves with this.
# roadmap 5.2 adds the keyboard to the controller 5.1 added. It is a USB
# device on the existing xHCI and NOT a new PCI function, so 4.2's info-pci set
# comparison needs no change for it -- checked before it was added, by booting
# the 5.1 tree with the device attached and watching every assertion hold.
[[ "$MACHINE" == pc ]] || QEMU_ARGS+=( -device qemu-xhci,id=xhci \
                                       -device usb-kbd,bus=xhci.0,id=kbd )

# roadmap 5.3. The disk is GENERATED, not committed: a binary fixture in git is
# a fixture nobody can read a diff of, and its contents are the assertion --
# sector 0 carries a known 16-byte prologue and a signature the guest has no
# way to guess. Rebuilt whenever it is missing, so the gate is self-contained.
NVME_IMG="${FK_NVME_IMG:-build/boot/nvme-disk.img}"
if [[ "$MACHINE" != pc ]]; then
  if [[ ! -f "$NVME_IMG" ]]; then
    mkdir -p "$(dirname "$NVME_IMG")"
    python3 - "$NVME_IMG" <<'PYIMG'
import sys
SECTORS, SZ = 2048, 512
d = bytearray(SECTORS * SZ)
d[0:16] = bytes(range(16))          # the prologue the guest prints
d[510:512] = b"\x55\xaa"            # a boot signature, so sector 0 looks real
d[512:528] = b"FORTRAN-KERNEL!!"    # sector 1, to catch an off-by-one LBA
open(sys.argv[1], "wb").write(bytes(d))
PYIMG
  fi
  QEMU_ARGS+=( -drive "file=$NVME_IMG,format=raw,if=none,id=nvm"
               -device nvme,drive=nvm,serial=fk1234 )
fi
[[ "$MODE" == gate ]] && QEMU_ARGS+=( -cdrom "$ISO" )

# FK_FIRMWARE=uefi boots the SAME ISO through OVMF instead of SeaBIOS (roadmap
# 0.3).  grub2-mkrescue writes a hybrid image -- one El Torito entry for BIOS
# and one for UEFI -- so the firmware is chosen here and not at build time, and
# the two paths are therefore comparable by construction.  VARS is copied
# because OVMF writes to it and the packaged file is read-only.
if [[ "${FK_FIRMWARE:-bios}" == uefi ]]; then
  OVMF_CODE="${FK_OVMF_CODE:-}"
  OVMF_VARS="${FK_OVMF_VARS:-}"
  for c in /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd; do
    [[ -z "$OVMF_CODE" && -r "$c" ]] && OVMF_CODE="$c"
  done
  for v in /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [[ -z "$OVMF_VARS" && -r "$v" ]] && OVMF_VARS="$v"
  done
  if [[ -z "$OVMF_CODE" || -z "$OVMF_VARS" ]]; then
    echo "  FAIL  FK_FIRMWARE=uefi but no OVMF firmware found."
    echo "        Set FK_OVMF_CODE and FK_OVMF_VARS, or install edk2-ovmf."
    exit 1
  fi
  VARS_COPY="$(mktemp)"
  cp "$OVMF_VARS" "$VARS_COPY"
  chmod u+w "$VARS_COPY"
  QEMU_ARGS+=(
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,file=$VARS_COPY"
  )
  say "firmware   : UEFI (OVMF) -- $OVMF_CODE"
else
  say "firmware   : BIOS (SeaBIOS)"
fi

say "machine    : $MACHINE$([[ "$MACHINE" == pc ]] && echo '  (no MCFG: the ECAM path is deliberately not exercised)')"
say "qemu       : qemu-system-x86_64 ${QEMU_ARGS[*]}"
rule

qemu-system-x86_64 "${QEMU_ARGS[@]}" >"$QEMU_LOG" 2>&1 </dev/null &
QPID=$!

# 'server,nowait' creates the socket asynchronously; wait for it to appear.
sock_deadline=$(( SECONDS + 20 ))
while [[ ! -S "$SOCK" ]]; do
  if ! qemu_alive; then
    say "FAIL: QEMU exited before it opened the QMP socket."; show_qemu_log; exit 1
  fi
  if (( SECONDS >= sock_deadline )); then
    say "FAIL: QEMU never created the QMP socket $SOCK within 20s."; show_qemu_log; exit 1
  fi
  sleep 0.1
done
say "qemu running as pid $QPID, QMP socket up"

# Poll until both proofs hold: they do not land at the same instant, and neither
# stands in for the other. ATTEMPT counts poll iterations, not pmemsave calls.
nap "$BOOT_WAIT"

GOT_DUMP=0; SENTINEL_OK=0; SERIAL_OK=0; QEMU_DIED=0; ATTEMPT=0; START=$SECONDS
while :; do
  ATTEMPT=$(( ATTEMPT + 1 ))
  if ! qemu_alive; then
    QEMU_DIED=1
    wait "$QPID" 2>/dev/null || true
    QPID=""
    break
  fi
  if (( SERIAL_OK == 0 )) && serial_has_banner; then SERIAL_OK=1; fi
# Re-running pmemsave would overwrite the passing dump the verdict prints back.
  if (( SENTINEL_OK == 0 )); then
    if python3 "$SENTINEL" dump --qmp "$SOCK" --elf "$KERNEL" --out "$DUMP" \
         --timeout 10 --no-quit 2>"$TMP/dump.err"; then
      GOT_DUMP=1
      if python3 "$SENTINEL" check "$DUMP" --quiet >/dev/null 2>&1; then
        SENTINEL_OK=1
      fi
      # --smoke wants one look at a guest that can never satisfy either assertion.
      [[ "$MODE" == smoke ]] && break
    fi
  fi
  (( SENTINEL_OK == 1 && SERIAL_OK == 1 )) && break
  (( SECONDS - START >= DEADLINE )) && break
  nap "$POLL_INTERVAL"
done
ELAPSED=$(( SECONDS - START ))

# Bytes can land between the last poll and the loop breaking, which separates
# "printed the banner, then triple-faulted" from "never said anything".
if (( SERIAL_OK == 0 )) && serial_has_banner; then SERIAL_OK=1; fi

# Asked of the DEVICE MODELS, not of the kernel, and asked while the guest is
# still up -- a PIC whose ICW2 was never written looks identical from inside
# the kernel, because masking works whatever the vector base happens to be.
HW_RAN=0; HW_OK=0
if [[ -n "${FK_CHECK_HW:-}" && "$MODE" == gate ]]; then
  if qemu_alive; then
    HW_RAN=1
    rule
    say "--- hardware state, read back over QMP ---"
    if python3 "$SENTINEL" hwstate --qmp "$SOCK" --elf "$KERNEL" --timeout 10; then
      HW_OK=1
    fi
  else
    say ""
    say "hardware state NOT asserted: the guest was already gone."
  fi
fi

# roadmap 2.2/2.4. The handoff block is read first and the framebuffer's
# physical address comes OUT of it, so this asserts the pixels at the address
# the guest itself says it mapped -- not at one this script knows.
FB_RAN=0; FB_OK=0
if [[ "$CHECK_FB" != 0 && "$MODE" == gate ]]; then
  if qemu_alive; then
    FB_RAN=1
    rule
    say "--- the framebuffer, read back out of guest memory ---"
    if python3 "$SENTINEL" fb --qmp "$SOCK" --elf "$KERNEL" --timeout 10 \
         --expect "${FK_FB_EXPECT:-console}"; then
      FB_OK=1
    fi
  else
    say ""
    say "framebuffer NOT asserted: the guest was already gone."
  fi
fi

# roadmap 4.0. Two reads, a moment apart, of counters the THREADS increment --
# so "both threads are running" is a fact about a machine that is still
# switching between them, which nothing the kernel printed can establish: the
# boot thread prints its verdict and could then never be scheduled again.
# roadmap 3.x. Read at the PHYSICAL base the kernel published, so no page
# table is consulted to reach it: the frames appear in order only if they
# really are adjacent in DRAM. The kernel's own bitmap cannot say that, and a
# bitmap that is simply wrong says it just as confidently.
# roadmap 4.2. As SETS and not as containment: a device QEMU reports and the
# guest missed is a hole in the walk, and a device the guest reports and QEMU
# does not is a ghost -- which is what a multifunction check that ignores the
# header-type bit produces, one device counted eight times.
PCI_RAN=0; PCI_OK=0
if [[ "$CHECK_PCI" != 0 && "$MODE" == gate ]]; then
  if qemu_alive; then
    PCI_RAN=1
    rule
    say "--- the guest's PCI enumeration, against QEMU's own tree ---"
    if python3 "$SENTINEL" pci --qmp "$SOCK" --elf "$KERNEL" --timeout 10; then
      PCI_OK=1
    fi
  else
    say ""
    say "PCI list NOT asserted: the guest was already gone."
  fi
fi

XHCI_RAN=0; XHCI_OK=0
if [[ "$CHECK_XHCI" != 0 && "$MODE" == gate ]]; then
  if qemu_alive; then
    XHCI_RAN=1
    rule
    say "--- the xHCI's rings, read at their physical bases ---"
    if python3 "$SENTINEL" xhci --qmp "$SOCK" --elf "$KERNEL" --timeout 10; then
      XHCI_OK=1
    fi
  fi
fi

VFS_RAN=0; VFS_OK=0
if [[ "$CHECK_VFS" != 0 && "$MODE" == gate ]]; then
  if qemu_alive; then
    VFS_RAN=1
    rule
    say "--- the VFS tree and the path walk, out of guest memory ---"
    if python3 "$SENTINEL" vfs --qmp "$SOCK" --elf "$KERNEL" --timeout 15; then
      VFS_OK=1
    fi
  fi
fi

NVME_RAN=0; NVME_OK=0
if [[ "$CHECK_NVME" != 0 && "$MODE" == gate ]]; then
  if qemu_alive; then
    NVME_RAN=1
    rule
    say "--- the NVMe read, at its physical base and against the disk ---"
    if python3 "$SENTINEL" nvme --qmp "$SOCK" --elf "$KERNEL" \
               --image "$NVME_IMG" --timeout 15; then
      NVME_OK=1
    fi
  fi
fi

KBD_RAN=0; KBD_OK=0
if [[ "$CHECK_KBD" != 0 && "$MODE" == gate ]]; then
  if qemu_alive; then
    KBD_RAN=1
    rule
    say "--- the USB keyboard: keys injected from outside, decoded inside ---"
    if python3 "$SENTINEL" usbkbd --qmp "$SOCK" --elf "$KERNEL" \
               --timeout "$KBD_TIMEOUT" --keys "$KBD_KEYS" --chars "$KBD_CHARS" \
               --report "$KBD_REPORT"
    then
      KBD_OK=1
    fi
  fi
fi

DMA_RAN=0; DMA_OK=0
if [[ "$CHECK_DMA" != 0 && "$MODE" == gate ]]; then
  if qemu_alive; then
    DMA_RAN=1
    rule
    say "--- the DMA run, read frame by frame at its physical base ---"
    if python3 "$SENTINEL" dma --qmp "$SOCK" --elf "$KERNEL" --timeout 10; then
      DMA_OK=1
    fi
  else
    say ""
    say "DMA run NOT asserted: the guest was already gone."
  fi
fi

SCHED_RAN=0; SCHED_OK=0
if [[ "$CHECK_SCHED" != 0 && "$MODE" == gate ]]; then
  if qemu_alive; then
    SCHED_RAN=1
    rule
    say "--- the scheduler and the heap, read out of guest memory twice ---"
    if python3 "$SENTINEL" sched --qmp "$SOCK" --elf "$KERNEL" --timeout 10; then
      SCHED_OK=1
    fi
  else
    say ""
    say "scheduler NOT asserted: the guest was already gone."
  fi
fi

# roadmap 3.2b. Deliberately NOT folded into the hwstate block: that one reads
# state the guest set up once, and this one reads state the guest is producing
# right now. A build whose kernel_main ends in a panic satisfies the first and
# must fail the second, which is why it has its own switch.
TICK_RAN=0; TICK_OK=0
if [[ "$CHECK_TICKS" != 0 && "$MODE" == gate ]]; then
  if qemu_alive; then
    TICK_RAN=1
    rule
    say "--- timer ticks, read out of guest memory twice while it runs ---"
    if python3 "$SENTINEL" ticks --qmp "$SOCK" --elf "$KERNEL" --timeout 10; then
      TICK_OK=1
    fi
  else
    say ""
    say "tick advance NOT asserted: the guest was already gone."
  fi
fi

if qemu_alive; then
  python3 "$SENTINEL" quit --qmp "$SOCK" --timeout 5 >/dev/null 2>&1 || true
fi

if [[ "$MODE" == smoke ]]; then
  rule
  if (( GOT_DUMP == 1 )) && (( SENTINEL_OK == 0 )) && (( SERIAL_OK == 0 )); then
    say "16 bytes actually read out of a live, kernel-less guest:"
    python3 "$SENTINEL" check "$DUMP" 2>&1 | sed 's/^/  /' || true
    show_serial_log
    rule
    say "SMOKE OK"
    say "  * QMP handshake, human-monitor-command and pmemsave all work"
    say "  * the SENTINEL assertion CORRECTLY REFUSED a guest that never ran"
    say "    the kernel"
    say "  * the SERIAL assertion CORRECTLY REFUSED it too: nothing the guest"
    say "    put on COM1 matched the expected banner"
    say ""
    say "  Both halves of the gate are therefore CAPABLE OF FAILING, which is"
    say "  the only reason a pass from either one means anything. The serial"
    say "  half is now held to exactly the standard the sentinel half already"
    say "  was: an assertion nobody has watched REFUSE a bad input is an"
    say "  assumption rather than a test (docs/AUDIT-PHASE1.md, A-1)."
    say ""
    say "  Note what is NOT claimed here: that the capture is EMPTY. Firmware"
    say "  -- SeaBIOS, in this VM -- is entitled to put its own bytes on COM1,"
    say "  and anything it wrote is printed above. The assertion is about the"
    say "  BANNER, which only kernel code can produce. It is not about silence."
    rule
    exit 0
  fi
  if (( GOT_DUMP == 0 )); then
    say "SMOKE FAILED: could not read guest memory over QMP."
    [[ -s "$TMP/dump.err" ]] && sed 's/^/  /' "$TMP/dump.err"
    show_qemu_log
  elif (( SENTINEL_OK == 1 )); then
    say "SMOKE FAILED: a guest with no kernel somehow satisfied the sentinel"
    say "              assertion -- the gate is broken and cannot be trusted."
  else
    say "SMOKE FAILED: a guest with no kernel somehow put the expected banner"
    say "              on COM1. Either FK_EXPECT_SERIAL has been overridden to"
    say "              something the FIRMWARE prints, or the match is far looser"
    say "              than the fixed-string grep it claims to be. Either way"
    say "              the serial half would pass without a kernel, so a pass"
    say "              from it proves nothing and cannot be trusted."
    show_serial_log
  fi
  rule; exit 1
fi

SELFTEST_BAD=0
if serial_has_failure; then SELFTEST_BAD=1; fi

rule
HW_BAD=0
if [[ -n "${FK_CHECK_HW:-}" && "$MODE" == gate ]] && (( HW_OK == 0 )); then HW_BAD=1; fi
TICK_BAD=0
if [[ "$CHECK_TICKS" != 0 && "$MODE" == gate ]] && (( TICK_OK == 0 )); then TICK_BAD=1; fi
FB_BAD=0
if [[ "$CHECK_FB" != 0 && "$MODE" == gate ]] && (( FB_OK == 0 )); then FB_BAD=1; fi
SCHED_BAD=0
if [[ "$CHECK_SCHED" != 0 && "$MODE" == gate ]] && (( SCHED_OK == 0 )); then SCHED_BAD=1; fi
DMA_BAD=0
if [[ "$CHECK_DMA" != 0 && "$MODE" == gate ]] && (( DMA_OK == 0 )); then DMA_BAD=1; fi
XHCI_BAD=0
if [[ "$CHECK_XHCI" != 0 && "$MODE" == gate ]] && (( XHCI_OK == 0 )); then XHCI_BAD=1; fi
KBD_BAD=0
if [[ "$CHECK_KBD" != 0 && "$MODE" == gate ]] && (( KBD_OK == 0 )); then KBD_BAD=1; fi
NVME_BAD=0
if [[ "$CHECK_NVME" != 0 && "$MODE" == gate ]] && (( NVME_OK == 0 )); then NVME_BAD=1; fi
VFS_BAD=0
if [[ "$CHECK_VFS" != 0 && "$MODE" == gate ]] && (( VFS_OK == 0 )); then VFS_BAD=1; fi
PCI_BAD=0
if [[ "$CHECK_PCI" != 0 && "$MODE" == gate ]] && (( PCI_OK == 0 )); then PCI_BAD=1; fi

if (( SENTINEL_OK == 1 )) && (( SERIAL_OK == 1 )) && (( SELFTEST_BAD == 0 )) \
   && (( QEMU_DIED == 0 )) && (( HW_BAD == 0 )) && (( TICK_BAD == 0 )) \
   && (( FB_BAD == 0 )) && (( SCHED_BAD == 0 )) && (( DMA_BAD == 0 )) \
   && (( PCI_BAD == 0 )) && (( XHCI_BAD == 0 )) && (( KBD_BAD == 0 )) \
   && (( NVME_BAD == 0 )) && (( VFS_BAD == 0 )); then
  python3 "$SENTINEL" check "$DUMP" | sed 's/^/  /'
  show_serial_log
  rule
  assertion_summary
  say ""
  say "PASS  --  multiboot2 -> long mode -> higher half -> Fortran kernel_main,"
  say "          verified in guest physical memory after ${ELAPSED}s,"
  say "          $ATTEMPT attempt(s), accelerator $ACCEL."
  say "          Word 3 was computed at run time by Fortran from the magic GRUB"
  say "          passed in, so live data provably crossed the asm -> Fortran ABI."
  say "          COM1 then carried the banner, so Fortran also drove a real"
  say "          16550A device model with real OUT instructions: those bytes"
  say "          LEFT the CPU, which no dump of guest memory could ever show."
  if [[ -n "${FK_CHECK_HW:-}" ]]; then
    say "          The task register and both 8259s were then read back out of"
    say "          the device models, so those are the machine's answers and"
    say "          not the kernel's."
  fi
  if [[ "$CHECK_FB" != 0 ]]; then
    say "          The four-primary bar was then read back out of the"
    say "          framebuffer at the physical address the guest itself"
    say "          reported, and every pixel matched a colour the HOST packed"
    say "          from the loader's channel masks -- so the renderer reached"
    say "          real video memory and packed the channels the firmware"
    say "          asked for, not the ones an x86 kernel usually gets away with."
  fi
  if [[ "$CHECK_PCI" != 0 ]]; then
    say "          The bus the guest walked was then compared against QEMU's"
    say "          own info pci AS A SET, so a function it missed and a"
    say "          function it invented both fail -- and the second is the"
    say "          one a containment test would wave through, because a"
    say "          single-function device aliased across all eight looks like"
    say "          eight perfectly plausible devices."
  fi
  if [[ "$CHECK_DMA" != 0 ]]; then
    say "          A run of physically contiguous frames was then read at the"
    say "          PHYSICAL base the guest published -- no page table was"
    say "          consulted to reach it -- and every frame carried the tag"
    say "          the kernel wrote for that frame's own index, in order. A"
    say "          bitmap can only testify about itself; this is the frames."
  fi
  if [[ "$CHECK_SCHED" != 0 ]]; then
    say "          Two counters that only the two SPAWNED threads increment"
    say "          were then read twice while the guest ran, and both had"
    say "          grown -- so the timer interrupt is switching between three"
    say "          stacks and coming back to each of them, which is the whole"
    say "          of roadmap 4.0 and cannot be inferred from any line printed"
    say "          by the thread that prints lines."
  fi
  if [[ "$CHECK_TICKS" != 0 ]]; then
    say "          And fk_tick_count was read out of guest memory TWICE, a"
    say "          quarter of a second apart, and had grown -- so the machine"
    say "          was still taking timer interrupts and RETURNING from them"
    say "          while that was being asked, which is the one thing no line"
    say "          the kernel prints about itself could establish."
  fi
  rule
  exit 0
fi

assertion_summary
say ""
if (( QEMU_DIED == 1 )); then
  say "QEMU EXITED EARLY, after ${ELAPSED}s and $ATTEMPT attempt(s)."
  say ""
  if (( SENTINEL_OK == 1 )) && (( SERIAL_OK == 1 )); then
    say "  Both assertions above were satisfied before it died, and it is STILL"
    say "  a fail. kernel_main's contract is that it never returns -- it parks"
    say "  the CPU in fk_cpu_halt forever -- so a guest that exits on its own"
    say "  under -no-reboot ran off the end of something. The kernel booted,"
    say "  took the handoff and spoke; the bug is in whatever executed after"
    say "  the banner, which is a later and more interesting failure than the"
    say "  early-boot list below rather than an absence of one."
    say ""
  fi
  say "  Launched with -no-reboot, so this is what a TRIPLE FAULT looks like."
  say "  Usual suspects, in the order they bite a higher-half kernel:"
  say "    * a symbol referenced without PHYS() in the .code32 half of boot.S"
  say "    * the higher-half mapping missing: PML4[511] -> PDPT[510] -> PD"
  say "    * long-mode ladder order: CR4.PAE, then EFER.LME, then CR0.PG"
  say "    * the far jump landing outside the 64-bit code segment"
  say "    * .bss clear erasing the live page tables (they must stay in .bootpt)"
  say "    * rsp not 16-byte aligned immediately before 'call kernel_main'"
  say "    * kernel_main RETURNING -- the contract says it never does"
  show_qemu_log
  show_serial_log
elif (( GOT_DUMP == 0 )); then
  say "FAIL: never managed to read the guest's memory (${ELAPSED}s, $ATTEMPT attempt(s))."
  say ""; say "--- last dumper error ---"
  [[ -s "$TMP/dump.err" ]] && sed 's/^/  /' "$TMP/dump.err" || say "  (none)"
  show_qemu_log
elif (( SENTINEL_OK == 0 )); then
  say "Sentinel assertion FAILED after ${ELAPSED}s and $ATTEMPT attempt(s)."
  say ""
  python3 "$SENTINEL" check "$DUMP" | sed 's/^/  /' || true
  say ""
  say "The guest is alive and its memory is readable, so the machine did NOT"
  say "triple-fault: execution reached somewhere and stopped. If every word is"
  say "still 0x11111111, kernel_main was never called."
elif (( TICK_BAD == 1 )) && (( SERIAL_OK == 1 )) && (( SELFTEST_BAD == 0 )) \
     && (( HW_BAD == 0 )); then
  say "THE GUEST IS NOT TICKING ANY MORE -- ${ELAPSED}s."
  say ""
  say "  COM1 said an interrupt was taken and returned from, and the counter"
  say "  read from outside says it is not happening now. The kernel got that"
  say "  far and then stopped. Usual causes:"
  say "    * kernel_main ended in fk_cpu_halt rather than fk_cpu_idle -- CLI"
  say "      then HLT, so the timer fires and the CPU never sees it"
  say "    * a build with a deliberate FK_FAULT_MODE: the panic handler halts"
  say "      with IF clear and the counter is correctly frozen. Pass"
  say "      FK_CHECK_TICKS=0 for those"
  say "    * the EOI stopped happening after the first few interrupts, so the"
  say "      8259 is holding an in-service bit and delivering nothing"
  show_serial_log
elif (( HW_BAD == 1 )) && (( SERIAL_OK == 1 )) && (( SELFTEST_BAD == 0 )); then
  say "THE HARDWARE STATE IS NOT WHAT THE KERNEL SAID IT WAS -- ${ELAPSED}s."
  say ""
  say "  Everything on COM1 held. This is a fail anyway, and it is the class of"
  say "  failure the console CANNOT report: the kernel can only tell you what it"
  say "  believes it wrote. The failing assertion is printed above, with the"
  say "  monitor's own line under it. Usual causes:"
  say "    * ICW2 never reached the chip -- the 0x80 delay write went to the"
  say "      command port, or the ICW order slipped, so the master is still on"
  say "      0x08 and a spurious IRQ0 would arrive as vector 8: a #DF that"
  say "      never happened"
  say "    * LTR never ran, or ran before the descriptor was written: TR = 0"
  say "    * the GDT limit still covers three slots, so the second half of the"
  say "      16-byte TSS descriptor is outside the table"
  show_serial_log
elif (( SELFTEST_BAD == 1 )); then
  say "COM1 CARRIED A LINE THE GATE FORBIDS -- ${ELAPSED}s, $ATTEMPT attempt(s)."
  say ""
  say "  The line itself is named in the summary above, and it is the most"
  say "  useful class of failure this gate produces, because the kernel"
  say "  diagnosed itself rather than merely dying."
  # The UART advice below is only correct when the UART line is the one that
  # hit; the reject list is general now and a #DF verdict can land here too.
  if serial_matches "Fortran Kernel: COM1 loopback self-test FAILED."; then
    say ""
    say "  THE UART PROBE: serial_init put the port in internal loopback,"
    say "  transmitted 0xAE and did NOT read 0xAE back."
    say ""
    say "  That the banner still appeared narrows it sharply. Transmission"
    say "  works, so the WRITE path -- fk_outb, the port space, LCR/DLAB, the"
    say "  divisor -- is fine. What failed is the read side or the loopback:"
    say "    * boot/io.S fk_inb not zero-extending EAX, so the probe comes back"
    say "      with the previous EAX's upper bits attached and compares unequal"
    say "      to 0xAE on a UART that is behaving perfectly"
    say "    * fk_inb reading the wrong port (%si rather than %di)"
    say "    * MCR loopback (0x1E) not actually taking effect before the probe"
    say "    * a FIFO flush ordered after the probe instead of before it, so"
    say "      the byte read back is a stale one"
    say "    * genuinely absent hardware: an unassigned port floats to 0xFF,"
    say "      and 0xFF is not 0xAE -- which is exactly what the probe is for"
  fi
  show_serial_log
else
  say "SENTINEL PASSED, but COM1 never carried the banner -- ${ELAPSED}s,"
  say "$ATTEMPT attempt(s)."
  say ""
  say "  The boot path itself is therefore fine: Fortran ran, and the loader's"
  say "  live values crossed the asm -> Fortran ABI. What failed is the"
  say "  CONSOLE -- the roadmap 2.1 half. Usual suspects, in the order they"
  say "  bite a freshly written UART driver:"
  say "    * serial_init was simply never called: kernel_main stores the"
  say "      sentinel and reaches fk_cpu_halt without ever touching the UART,"
  say "      which is precisely what this boot path did before 2.1 landed"
  say "    * the LSR transmit-ready poll ran out its 65535 spins and gave up."
  say "      With no COM1 behind the port an IN reads back 0xFF or 0x00, so"
  say "      THR-empty (LSR bit 5) never settles the way a real 16550A settles"
  say "      it, and a correctly written driver declines to write forever"
  say "    * the banner in src/boot/fk_kmain.f90 is not byte-for-byte what this"
  say "      gate greps for -- a missing period, a lower-case i in Initialized,"
  say "      two spaces after the colon. Both strings are printed below for"
  say "      exactly this comparison"
  say "    * the driver wrote to the wrong port. COM1 is 0x3F8; 0x2F8 (COM2)"
  say "      has no chardev attached to this VM, so those bytes go nowhere and"
  say "      the guest looks perfectly healthy while saying nothing"
  say "    * QEMU was started with no serial chardev at all -- check the"
  say "      'qemu       :' line above for -serial file:"
  show_serial_log
  say ""
  say "  expected on COM1 : \"$EXPECT_SERIAL\""
fi
rule
say "FAIL"
rule
exit 1
