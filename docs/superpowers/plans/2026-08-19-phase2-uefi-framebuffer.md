# Roadmap 2.2's second half -- a framebuffer on the UEFI path

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Light the screen when the machine boots through OVMF. The renderer, the console, the write-combining mapping and the host-side pixel check all exist and are gated on the BIOS path; under UEFI the kernel was handed no framebuffer at all.

**Architecture:** Nothing in the kernel changes. GRUB is made to answer the request the kernel has always sent.

## The two candidate vectors, and why one of them is impossible

**VECTOR B -- walk Multiboot2 tag 12 to the EFI System Table and find the Graphics Output Protocol -- cannot work as described.** GOP is reachable only through `BootServices->LocateProtocol`, and by the time this kernel runs the boot services are gone.

The measurement that settles it: **MBI tag 18 is absent on the UEFI path.** Its entire meaning is "boot services have NOT been terminated". Two independent tag walkers report the UEFI list as `21, 1, 2, 6, 9, 4, 12, 14, 15, 17, 0` -- no 18. The cause is in the GRUB that boots this ISO: `grub-core/loader/multiboot_mbi2.c:943` guards `grub_efi_finish_boot_services()` on `if (!keep_bs)`, and `keep_bs` is set only by Multiboot2 HEADER tag 7, which `boot/boot.S` does not emit.

Setting header tag 7 does not merely keep boot services alive: it changes the entry contract. GRUB then takes `grub_relocator64_efi_boot`, entering in **64-bit long mode** at the tag-9 entry on the FIRMWARE's CR3, GDT and IDT, with interrupts live -- the entire `.code32` ladder in `boot.S` never runs. Tags 6 and 17 both disappear, so the PMM loses both its front ends. And a probe stub built that way STILL receives no tag 8. Vector B is a second, Xen-style entry point plus an MS-x64-ABI firmware call sequence plus a rebuilt memory-map path, in exchange for a framebuffer that one line of grub.cfg already produces.

**VECTOR A wins on evidence.** Under OVMF, GRUB printed the reason on COM1 before the kernel's first byte:

    error: ../../grub-core/video/video.c:grub_video_set_mode:761:no suitable video mode found.

The EFI core `grub2-mkrescue` builds embeds the video FRAMEWORK and no video DRIVER. The drivers are already on the ISO it writes. Nothing had loaded them.

## Measured facts this plan is built on

- `insmod all_video` before the `multiboot2` line makes GRUB set **1024x768x32** through the EFI GOP and hand over a real tag 8: base `0x80000000`, pitch `0x1000`, masks `0x0000080008080810`, PAT `0x0007010600070106`, PTE `0x800000008000000B`, console `128x47`. Identical to SeaBIOS in everything but the base (`0xFD000000` there).
- `all_video` resolves to `efi_gop/efi_uga/video_bochs/video_cirrus` on x86_64-efi and `vbe/vga/video_bochs/video_cirrus` on i386-pc, so one line serves both halves of the hybrid image. Confirmed by the `FK_MACHINE=pc` cell passing.
- The UEFI gate was **green with no framebuffer**: `tools/qemu-boot-test.sh` blanked `FK_FB_PASS_LINES`, `FK_CON_PASS_LINES` and both FAIL lists and set `FK_CHECK_FB=0`.
- `$(ISO)` depended on `$(KERNEL)` only. grub.cfg is written BY that recipe, so a boot-configuration change moved no file make was watching.
- Roadmap 1.1's string work is NOT needed. Nothing here parses text.

## File Structure

| File | Responsibility |
|---|---|
| `src/boot/fk_kmain.f90` (modify) | `fb_bringup` keys on the probe's magic, not on the base. |
| `Makefile.boot` (modify) | `insmod all_video`; `$(ISO)` depends on the recipe; `isocheck-boot`. |
| `tools/qemu-boot-test.sh` (modify) | Stop excusing the UEFI path from the video assertions. |
| `roadmap.md` (modify) | 2.2's UEFI half; drop the finished rows from the next-milestone table. |

---

### Task 1: The guard, first

- [ ] `fb_bringup` guarded on `fk_fb_info(FK_FB_BASE) == 0`. `fb_probe` writes the base BEFORE validating the mode and returns early on one it refuses, so a REJECTED framebuffer leaves a non-zero base. Key on `FK_FB_TAG /= FK_FB_MAGIC`: the magic is written last and only on acceptance.
- [ ] This must land WITH the ISO change, not after it. It is inert while the UEFI path has no tag 8 and live the moment it has one.

### Task 2: The ISO

- [ ] `insmod all_video` immediately before `multiboot2 /boot/kernel.elf`.
- [ ] `$(ISO): $(KERNEL) Makefile.boot`.
- [ ] `isocheck-boot` in `bootgate`: grep the generated grub.cfg for the insmod, and the built ISO for `efi_gop.mod` via xorriso. A missing GRUB module is silent at boot -- the loader reports it and carries on -- so this refuses in the container in a second.

### Task 3: The gate stops excusing UEFI

- [ ] Delete the four blanking assignments and default `FK_CHECK_FB=1`. KEEP the tag-17 and XSDT appends: they are what separates "booted through OVMF" from "parsed the EFI map".
- [ ] Do not hardcode a base anywhere. It differs by firmware.

### Task 4: Mutations, run and stated

- [ ] Drop the insmod line: `bootgate` refuses at build time, and the UEFI gate exits 1 with GRUB's own error on the wire and `fb_info magic is 0x00000000`.
- [ ] Force `fb_probe` to refuse the loader's depth, with the new guard and with the old one, and show what the old one does with a framebuffer the probe rejected.
- [ ] The matrix: BIOS q35, `FK_FIRMWARE=uefi`, `FK_FIRMWARE=uefi FK_CHECK_HW=1`, `FK_MACHINE=pc`.

## What this milestone deliberately does not do

It does not touch the renderer, the console, the mapping or the sentinel: measured, none of them needed a line. It does not claim `efi_gop` specifically -- `all_video` loads four drivers and the gate never asserts which one GRUB chose; the honest claim is that GRUB set a 1024x768x32 linear mode under OVMF. And it proves nothing about real firmware: OVMF's pitch happens to equal width*4, so the host-side sentinel's own stride arithmetic is still unexercised by any path that has ever run.
