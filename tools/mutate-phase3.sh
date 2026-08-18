#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Drives the mutation table in docs/HARNESS-VALIDATION-PHASE3.md: injects one
# defect at a time into the roadmap 3.1/3.2/3.2b/3.2.5/3.4/3.5 code, rebuilds from clean,
# boots it and restores the tree.  The baselines must PASS; a MUTATION that
# passes is an ESCAPE, because the gate accepted a kernel with a known defect.
#
# Edits the working tree in place and restores with `git checkout`, so run it on
# a clean tree.  Needs a VM, so it runs on the host, not in the container.
#
#   tools/mutate-phase3.sh            every case
#   tools/mutate-phase3.sh M7 M10     only those
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${FK_MUTATE_OUT:-$(mktemp -d /tmp/fk-mutate.XXXXXX)}"
mkdir -p "$OUT"
echo "logs: $OUT"

# Every file any mutation below touches.  A short restore list is how a defect
# survives into the NEXT case and gets attributed to it.
# EVERY FILE ANY CASE BELOW MUTATES MUST BE IN THIS LIST. restore() rewinds
# exactly these, so a case that seds a file not named here leaves its mutation
# behind: it survives into every later case, is reported against the wrong
# defect, and -- the way it was actually discovered -- gets committed by the
# next `git add -A`. Adding a case therefore means checking this list first,
# which is why fk_heap, fk_sched and fk_console had to be added with M34-M39.
FILES="boot/interrupts.S boot/gdt_flush.S boot/faultgen.S boot/ksyms.S \
       boot/mmu.S \
       src/cpu/fk_gdt.f90 src/cpu/fk_idt.f90 src/cpu/fk_tss.f90 \
       src/cpu/fk_sched.f90 \
       src/drivers/pic/fk_pic.f90 src/drivers/pit/fk_pit.f90 \
       src/drivers/video/fk_console.f90 \
       src/mm/fk_pmm.f90 src/mm/fk_vmm.f90 src/mm/fk_heap.f90 \
       src/boot/fk_kmain.f90"

restore() { git checkout -- $FILES 2>/dev/null; }

# restore() rewinds to the INDEX, so a file that is untracked is not rewound at
# all and a file with unstaged edits loses them.  Either one turns this script
# from a measurement into a corruption: the first mutation would survive into
# every later case and be reported against the wrong defect.  Refuse instead.
for f in $FILES; do
  git ls-files --error-unmatch "$f" >/dev/null 2>&1 || {
    echo "ABORT: $f is not tracked -- 'git checkout --' cannot restore it."
    echo "       git add it first."; exit 1; }
done
# UNSTAGED edits are the fatal case, not uncommitted ones: restore() rewinds to
# the index, so anything staged survives every case unharmed.
if ! git diff --quiet -- $FILES && [ -z "${FK_MUTATE_FORCE:-}" ]; then
  echo "ABORT: unstaged changes in the files this script mutates:"
  git status --short -- $FILES | sed 's/^/       /'
  echo "       git add or stash them; the first restore would discard them."
  echo "       FK_MUTATE_FORCE=1 to override."; exit 1
fi

# The #DE build reaches the ISR_NOERR half of boot/interrupts.S; the #DF build
# reaches ISR_ERR and the IST1 stack switch.  Neither is a superset.
#
# roadmap 3.4's six verdicts ride on EVERY case, not just the PMM ones. A
# mutation is only attributable if everything it did not touch still holds, and
# these lines are printed before the deliberate fault on every build.
PMM_EXPECT=$'Fortran Kernel: PMM reserved and ACPI frames are all marked used.\nFortran Kernel: PMM locked the kernel image and the loader map out.\nFortran Kernel: PMM allocated 5 distinct, aligned frames.\nFortran Kernel: PMM freed and reclaimed the same 5 frames.\nFortran Kernel: PMM refused a double, unaligned and locked free.\nFortran Kernel: PMM rewound its scan cursor to a freed frame.'
PMM_REJECT=$'Fortran Kernel: PMM init FAILED, status 0x\nFortran Kernel: PMM reserved or ACPI frames are STILL FREE.\nFortran Kernel: PMM did NOT lock the kernel image out.\nFortran Kernel: PMM allocation FAILED: repeated or misaligned frame.\nFortran Kernel: PMM reclaim FAILED.\nFortran Kernel: PMM guard FAILED.\nFortran Kernel: PMM cursor rewind FAILED.'

# roadmap 3.5's verdicts ride on every case for the same reason 3.4's do. The
# last line of each is not a verdict at all: " R-X" and "RWX" are the W^X
# property read off the permission column of the LIVE page tables, and they
# carry no address, so they survive any relayout.
VMM_EXPECT=$'Fortran Kernel: VMM has EFER.NXE and CR0.WP, so the permissions bite.\nFortran Kernel: VMM mapped every kernel page with the asked-for permission.\nFortran Kernel: VMM left the stack guard page unmapped.\nFortran Kernel: identity window still live, [0x100000] = 0x00000000E85250D6\nFortran Kernel: PML4[0] unmapped; the identity window is dead.\nFortran Kernel: VMM mapped a frame above 4 GiB and read back what it wrote.\n R-X'
VMM_REJECT=$'Fortran Kernel: VMM init FAILED, status 0x\nFortran Kernel: VMM could not enable NX; .rodata is not no-execute.\nFortran Kernel: VMM section permissions are WRONG, pages 0x\nFortran Kernel: VMM guard page is MAPPED.\nFortran Kernel: PML4[0] is STILL MAPPED.\nFortran Kernel: VMM high-frame mapping FAILED.\nRWX'

# roadmap 3.2b's verdicts ride on EVERY case for the reason 3.4's and 3.5's do:
# irq_bringup runs before the deliberate fault in every build, so a mutation is
# only attributable if these still hold. The HEADLINE is not in this list --
# "the kernel is still running" is only printed by the no-fault build, and every
# other one deliberately ends in a panic.
IRQ_EXPECT=$'Fortran Kernel: PIT channel 0 hz/divisor 0x00000064/0x00002E9C.\nFortran Kernel: 8259 IMR now 0x0000FFFE, IRQ0 is the only line open.\nFortran Kernel: RFLAGS.IF is set, the CPU is interruptible, RFLAGS = 0x\nFortran Kernel: IRQ0 ticks before/after/spurious 0x\nFortran Kernel: the first tick interrupted kernel .text with IF set, RIP/RFLAGS 0x'
IRQ_REJECT=$'Fortran Kernel: PIT divisor is 0, so channel 0 was NOT programmed.\nFortran Kernel: IRQ0 is STILL MASKED after the unmask.\nFortran Kernel: RFLAGS.IF is CLEAR after STI.\nFortran Kernel: IRQ0 never reached the tick target; the timer interrupt did not arrive.\nFortran Kernel: the first tick\'s saved frame is NOT kernel .text with IF set.'

# roadmap 2.2/2.4 and 3.6 ride on every case for the reason 3.4's and 3.5's do:
# all of it runs before the deliberate fault in every build, so a mutation is
# only attributable if everything it did not touch still holds.
#
# The two lines that carry the milestone are the PAT one and the alias one. A
# framebuffer mapped write-back renders IDENTICALLY -- no picture, no pixel
# dump and no console line would differ -- and a framebuffer aliased in the
# linear map has no symptom at all until the day the two memory types disagree.
# Both are decoded from the LIVE page-table entry.
GOP_EXPECT=$'Fortran Kernel: GOP IA32_PAT is 0x0007010600070106, PAT index 1 is write-combining.\nFortran Kernel: GOP framebuffer PTE selects PAT index 1, write-combining.\nFortran Kernel: GOP framebuffer has no write-back alias in the linear map.\nFortran Kernel: GOP renderer armed on the mapped framebuffer (roadmap 2.4).\nFortran Kernel: console is live on the framebuffer, cols/rows 0x00000080/0x0000002F'
GOP_REJECT=$'Fortran Kernel: GOP framebuffer tag REJECTED, status 0x\nFortran Kernel: GOP could NOT program the PAT; the framebuffer is not write-combining.\nFortran Kernel: GOP framebuffer PTE is NOT write-combining.\nFortran Kernel: GOP framebuffer mapping FAILED, status 0x\nFortran Kernel: GOP framebuffer is ALIASED write-back in the linear map.\nFortran Kernel: GOP renderer REFUSED the framebuffer, status 0x\nFortran Kernel: console REFUSED the framebuffer geometry, status 0x'

# roadmap 3.6. "blocks 0x00000001" after everything is freed is the only one of
# these a heap that never coalesces fails; the rest pass on a fragmented one.
HEAP_EXPECT=$'Fortran Kernel: heap returned 16-byte aligned, non-overlapping blocks.\nFortran Kernel: kzalloc returned memory that was already zero.\nFortran Kernel: heap refused a double free, a stray pointer and a wrapped size.\nFortran Kernel: heap tiles its window exactly, blocks/used/free 0x00000001/0x00000000/\nFortran Kernel: heap coalesced every freed block back into one, largest free 0x'
HEAP_REJECT=$'Fortran Kernel: heap could not get memory from the PMM/VMM.\nFortran Kernel: heap blocks are misaligned or OVERLAP.\nFortran Kernel: heap blocks OVERWROTE each other.\nFortran Kernel: kzalloc returned DIRTY memory.\nFortran Kernel: heap ACCEPTED a free it should have refused.\nFortran Kernel: heap did NOT coalesce; it is fragmented, blocks 0x\nFortran Kernel: heap FAILED its own consistency walk, faults 0x'

# roadmap 3.7. NOT on the fault builds: kernel_main raises its deliberate fault
# before sched_bringup on none of them -- it raises it after -- so these do ride
# on every case, and a panic build that halts simply stops the threads later.
SCHED_EXPECT=$'Fortran Kernel: scheduler tasks/current 0x00000003/0x00000001\nFortran Kernel: preemption is on; the timer now switches tasks.\nFortran Kernel: both threads ran, switches/A/B 0x'
SCHED_REJECT=$'Fortran Kernel: scheduler could NOT spawn a thread, status 0x\nFortran Kernel: a spawned thread NEVER ran; the switch did not happen.'

DE_EXPECT="EXCEPTION 0x00 ERR 0x0000000000000000 -- #DE Divide-by-Zero Error"$'\n'"$PMM_EXPECT"$'\n'"$VMM_EXPECT"$'\n'"$IRQ_EXPECT"$'\n'"$GOP_EXPECT"$'\n'"$HEAP_EXPECT"$'\n'"$SCHED_EXPECT"
DF_EXPECT=$'EXCEPTION 0x08 ERR 0x0000000000000000 -- #DF Double Fault\n*** #DF ENTERED ON IST1 -- THE EMERGENCY STACK HELD ***\n'"$PMM_EXPECT"$'\n'"$VMM_EXPECT"$'\n'"$IRQ_EXPECT"$'\n'"$GOP_EXPECT"$'\n'"$HEAP_EXPECT"$'\n'"$SCHED_EXPECT"
# The OOM build's proof is three facts: the allocator refused, it said so, and
# the panic that followed came from the CPU with a full register dump.
OOM_EXPECT=$'*** PMM OUT OF MEMORY ***\nEXCEPTION 0x03 ERR 0x0000000000000000 -- #BP Breakpoint\n*** HALTED -- CLI/HLT ***\n'"$PMM_EXPECT"$'\n'"$VMM_EXPECT"$'\n'"$IRQ_EXPECT"$'\n'"$GOP_EXPECT"$'\n'"$HEAP_EXPECT"$'\n'"$SCHED_EXPECT"
COMMON_REJECT=$'Fortran Kernel: the deliberate fault did NOT trap.\nFortran Kernel: 8259 PIC mask readback FAILED.\n'"$PMM_REJECT"$'\n'"$VMM_REJECT"$'\n'"$IRQ_REJECT"$'\n'"$GOP_REJECT"$'\n'"$HEAP_REJECT"$'\n'"$SCHED_REJECT"

# roadmap 3.5's two page-fault builds. The CR2 line is the whole assertion: both
# faults are vector 14 with error code 0, so without it the two cases are
# indistinguishable and either would satisfy the other's expectation.
PF_EXPECT=$'EXCEPTION 0x0E ERR 0x0000000000000000 -- #PF Page Fault\n*** HALTED -- CLI/HLT ***\n'"$PMM_EXPECT"$'\n'"$VMM_EXPECT"$'\n'"$IRQ_EXPECT"$'\n'"$GOP_EXPECT"$'\n'"$HEAP_EXPECT"$'\n'"$SCHED_EXPECT"
DF_REJECT="*** #DF ENTERED ON THE FAULTING STACK -- NO IST SWITCH ***"$'\n'"$COMMON_REJECT"

# roadmap 3.2b's build is the DEFAULT now, because it is what ships. It is the
# only one whose kernel_main does not end in a register dump, so it is also the
# only one where the tick counter must still be moving when the gate reads it.
NONE_EXPECT="$IRQ_EXPECT"$'\nFortran Kernel: interrupts are live and the kernel is still running (roadmap 3.2b).\n'"$PMM_EXPECT"$'\n'"$VMM_EXPECT"$'\n'"$GOP_EXPECT"$'\n'"$HEAP_EXPECT"$'\n'"$SCHED_EXPECT"
NONE_REJECT=$'*** FORTRAN KERNEL PANIC ***\n'"$COMMON_REJECT"

# The shipped build's settings, and the per-case defaults reset before every
# mutation. A case that forgets to call fault_build gets these.
EXPECT="$NONE_EXPECT"; REJECT="$NONE_REJECT"
CHECK_TICKS=1; CHECK_SCHED=1; FB_EXPECT=console

# subst <file> <old> <new> -- and ABORT the run if the text was not there.
# A sed that quietly matches nothing rebuilds the pristine kernel, the gate
# passes, and the table records an escape that never happened.
subst() {
  python3 - "$@" <<'PY' || exit 1
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if old not in s:
    sys.exit("  MUTATION DID NOT APPLY: %r not found in %s" % (old[:70], path))
open(path, 'w').write(s.replace(old, new, 1))
PY
}

# EVERY mode_* below switches kernel_main away from the shipped no-fault build,
# so every one of them also turns the tick assertion OFF: the panic handler
# halts with IF clear, and a frozen counter is the CORRECT answer there.
#
# roadmap 4.0 added two more assertions that are wrong for a halted CPU, and
# they are switched together with the tick one by fault_build() below:
#
#   FK_CHECK_SCHED reads fk_task_runs TWICE while the guest runs. With the CPU
#   parked in a panic no thread is running, both reads are equal, and the gate
#   would report a scheduling failure for every panic build -- a false alarm
#   that would make the whole mutation table unreadable.
#
#   FK_FB_EXPECT goes from console to panic. The console band is repainted
#   white on red by the handler, so demanding the console palette there would
#   fail on a kernel whose panic screen works, and demanding nothing would stop
#   asserting the panic reached the screen at all.
#
# Rebuild kernel_main's deliberate fault as the #DF that was the default until
# roadmap 3.2b -- the only build that exercises the IST1 stack switch.
# What every fault build shares: a halted CPU, and a screen the panic owns.
fault_build() {
  CHECK_TICKS=0; CHECK_SCHED=0; FB_EXPECT=panic
}

mode_df() {
  subst src/boot/fk_kmain.f90 \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = -5_c_int32_t" \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = 8_c_int32_t"
  EXPECT="$DF_EXPECT"; REJECT="$DF_REJECT"; fault_build
}

# ...or as a #DE instead.
mode_de() {
  subst src/boot/fk_kmain.f90 \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = -5_c_int32_t" \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = 0_c_int32_t"
  EXPECT="$DE_EXPECT"; REJECT="$COMMON_REJECT"; fault_build
}

# ...or as roadmap 3.4's out-of-memory panic: drain the PMM, then INT3.
mode_oom() {
  subst src/boot/fk_kmain.f90 \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = -5_c_int32_t" \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = -1_c_int32_t"
  EXPECT="$OOM_EXPECT"; REJECT="$COMMON_REJECT"; fault_build
}

# The guard page, whose address is READ OUT OF THE IMAGE that was just built
# rather than written down here -- the whole point is that the fault lands on
# the page linker.ld reserved, and a constant would still match after a
# relayout moved it. bash arithmetic is signed 64-bit, so 0xFFFFFFFF... wraps
# negative; printf %X prints the bit pattern, which is what is wanted.
mode_guard() {
  subst src/boot/fk_kmain.f90 \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = -5_c_int32_t" \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = -2_c_int32_t"
  EXPECT="$PF_EXPECT"; REJECT="$COMMON_REJECT"; fault_build; POST_BUILD=guard_cr2
}
guard_cr2() {
  local b cr2
  b=$(nm build/boot/kernel.elf | awk '$3=="__boot_stack_bottom"{print $1}')
  [ -n "$b" ] || { echo "  (cannot read __boot_stack_bottom)"; return; }
  cr2=$(printf '%016X' $(( 0x$b - 8 )))
  echo "  guard probe: __boot_stack_bottom 0x$b, expecting CR2 0x$cr2"
  EXPECT="$EXPECT"$'\n'"CR2     = 0x$cr2"
}

# ...and the write to .text that only CR0.WP refuses. ERR 0x3 is the assertion,
# not the vector: bit 0 says the page was PRESENT and bit 1 says the access was
# a WRITE, i.e. a protection violation rather than a missing page. A not-present
# page would report 0x2 and would prove nothing about the write bit.
mode_wp() {
  subst src/boot/fk_kmain.f90 \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = -5_c_int32_t" \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = -4_c_int32_t"
  EXPECT=$'EXCEPTION 0x0E ERR 0x0000000000000003 -- #PF Page Fault\n*** HALTED -- CLI/HLT ***\n'"$PMM_EXPECT"$'\n'"$VMM_EXPECT"$'\n'"$IRQ_EXPECT"$'\n'"$GOP_EXPECT"$'\n'"$HEAP_EXPECT"$'\n'"$SCHED_EXPECT"
  REJECT="$COMMON_REJECT"; fault_build; POST_BUILD=wp_cr2
}
wp_cr2() {
  local t
  t=$(nm build/boot/kernel.elf | awk '$3=="__text_start"{print $1}')
  [ -n "$t" ] || { echo "  (cannot read __text_start)"; return; }
  echo "  wp probe: writing to __text_start 0x$t"
  EXPECT="$EXPECT"$'\n'"CR2     = 0x$(printf '%016X' $(( 0x$t )))"
}

# ...and physical 1 MiB, which needs no lookup: it is where linker.ld puts this
# image, and it resolved a few lines of console output earlier.
mode_idmap() {
  subst src/boot/fk_kmain.f90 \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = -5_c_int32_t" \
    "integer(c_int32_t), parameter :: FK_FAULT_MODE = -3_c_int32_t"
  EXPECT="$PF_EXPECT"$'\n'"CR2     = 0x0000000000100000"
  REJECT="$COMMON_REJECT"; fault_build
}

# Both gates, because they see different things: the static one reads the
# linked image (a TSS that grew from 104 bytes to 112 is visible there and
# nowhere else), the boot one reads a running CPU.  Which one caught a defect
# is part of the result, not an implementation detail.
run_case() {
  local name=$1 static=clean
  ./tools/run.sh clean-boot >/dev/null 2>&1
  ./tools/run.sh linkscript >"$OUT/$name.static" 2>&1 || static=CAUGHT
  if ! ./tools/run.sh iso >"$OUT/$name.build" 2>&1; then
    echo "$name: static=$static, BUILD FAILED (caught at build time)"
    return
  fi
  # A case whose expectation depends on an address only the fresh image knows.
  [ -n "${POST_BUILD:-}" ] && "$POST_BUILD"
  FK_EXPECT_SERIAL="$EXPECT" FK_REJECT_SERIAL="$REJECT" FK_CHECK_HW=1 \
    FK_CHECK_TICKS="$CHECK_TICKS" FK_CHECK_SCHED="$CHECK_SCHED" \
    FK_FB_EXPECT="$FB_EXPECT" tools/qemu-boot-test.sh >"$OUT/$name.log" 2>&1
  local rc=$? line
  # The CAUSE, not the gate's echo of what it was looking for: the header lines
  # quote every expected string, so a grep for those matches on every run.
  line=$(sed 's/\x1b\[[0-9;]*m//g' "$OUT/$name.log" \
         | grep -aE "^(QEMU EXITED|THE HARDWARE|COM1 CARRIED|Sentinel assertion)|^  FAIL  |^      (MISSING|PRESENT)  :" \
         | head -3 | tr -d '\r' | sed 's/^ *//' | paste -sd'|')
  if [ $rc -eq 0 ]; then echo "$name: static=$static, boot gate PASSED :: $line"
  else                   echo "$name: static=$static, boot gate FAILED :: $line"; fi
}

SELECT="$*"
want_case() { [ -z "$SELECT" ] && return 0; case " $SELECT " in *" $1 "*) return 0;; esac; return 1; }

case_baseline_none() { run_case baseline-no-fault; }
case_baseline_df()  { mode_df; run_case baseline-df; }
case_baseline_de()  { mode_de;  run_case baseline-de; }
case_baseline_oom()   { mode_oom;   run_case baseline-oom; }
case_baseline_guard() { mode_guard; run_case baseline-guard-page; }
case_baseline_idmap() { mode_idmap; run_case baseline-identity-dead; }
case_baseline_wp()    { mode_wp;    run_case baseline-text-readonly; }

# --- the #DE build: roadmap 3.2's frame normalisation ------------------------
case_M1() {
  mode_de
  subst boot/interrupts.S $'isr\\vec:\n\tpushq\t$0\n\tpushq\t$\\vec' $'isr\\vec:\n\tpushq\t$\\vec'
  run_case M1-no-dummy-errcode
}
case_M2() {
  mode_de
  subst src/cpu/fk_idt.f90 "FK_IDT_ATTR_INTR = int(z'8E', c_int8_t)" \
                           "FK_IDT_ATTR_INTR = int(z'0E', c_int8_t)"
  run_case M2-gate-not-present
}
case_M3() {
  mode_de
  subst boot/interrupts.S $'\tpushq\t%rbx\n\tpushq\t%rbp' $'\tpushq\t%rbp\n\tpushq\t%rbx'
  run_case M3-swapped-gprs
}
case_M4() {
  mode_de
  subst boot/interrupts.S \
    $'\tmovslq\t%edi, %rdi\t\t/* the ABI leaves bits 63:32 undefined */' \
    $'\tmovslq\t%edi, %rdi\n\taddq\t$1, %rdi'
  run_case M4-stub-off-by-one
}
case_M5() {
  mode_de
  subst boot/interrupts.S \
    $'\t/* An interrupt gate does not clear DF, and SysV requires DF=0 on entry. */\n\tcld\n' ''
  run_case M5-no-cld
}

# --- the #DF build: roadmap 3.2.5's TSS, IST and PIC -------------------------
case_M6() {
  mode_df
  subst src/cpu/fk_gdt.f90 $'    gdt(FK_GDT_TSS_SLOT)     = lo\n    gdt(FK_GDT_TSS_SLOT + 1) = hi' \
                           $'    gdt(FK_GDT_TSS_SLOT)     = lo'
  run_case M6-tss-descriptor-8-bytes
}
case_M7() {
  mode_df
  subst src/cpu/fk_idt.f90 "idt(vec)%ist   = int(FK_TSS_IST_DF, c_int8_t)" \
                           "idt(vec)%ist   = FK_IDT_IST_NONE"
  run_case M7-df-gate-no-ist
}
case_M8() {
  mode_df
  subst src/cpu/fk_tss.f90 $'    tss%ist1_lo = u32(df_hi)\n    tss%ist1_hi = u32(ishft(df_hi, -32))' \
                           $'    tss%ist1_lo = u32(df_lo)\n    tss%ist1_hi = u32(ishft(df_lo, -32))'
  run_case M8-ist1-at-stack-bottom
}
case_M9() {
  mode_df
  subst src/cpu/fk_tss.f90 "    call tss_flush(FK_GDT_SEL_TSS)" \
                           "    if (df_lo == 1_c_int64_t) call tss_flush(FK_GDT_SEL_TSS)"
  run_case M9-no-ltr
}
case_M10() {
  mode_df
  subst src/drivers/pic/fk_pic.f90 "FK_PIC1_VECTOR = int(z'20', c_int32_t)" \
                                   "FK_PIC1_VECTOR = int(z'08', c_int32_t)"
  run_case M10-master-not-remapped
}
case_M11() {
  mode_df
  subst src/drivers/pic/fk_pic.f90 \
    $'    call pic_out(PIC1_DATA, FK_MASK_ALL)\n    call pic_out(PIC2_DATA, FK_MASK_ALL)' ''
  run_case M11-irqs-never-masked
}
case_M12() {
  mode_df
  subst src/cpu/fk_tss.f90 "    tss%iomap_base = int(c_sizeof(tss), c_int16_t)" \
                           "    tss%iomap_base = 0_c_int16_t"
  run_case M12-iomap-base-zero
}
case_M13() {
  mode_df
  # The exact trap the 32-bit-halves layout exists to avoid: one c_int64_t at
  # the head of the type and C alignment moves IST1 from 0x24 to 0x28.
  subst src/cpu/fk_tss.f90 "    integer(c_int32_t) :: reserved0" \
                           "    integer(c_int64_t) :: reserved0"
  run_case M13-tss-c-padding
}

# --- roadmap 3.4: the PMM ----------------------------------------------------
# Every one of these is ALREADY caught by the host suite (H1..HG in
# docs/HARNESS-VALIDATION-PHASE3.md). They are re-run on a real machine because
# the host suite feeds the parser a memory map this file wrote, and the boot
# gate feeds it one GRUB wrote -- and the two disagree about where things are.
case_M14() {
  subst src/boot/fk_kmain.f90 "    status = pmm_init(mbi)" \
                              "    status = pmm_init(0_c_int64_t)"
  run_case M14-mbi-pointer-lost
}
case_M15() {
  subst src/mm/fk_pmm.f90 $'    if (span_outward(kern_lo, kern_hi - kern_lo, first, last)) &\n         free_count = free_count - bits_set(first, last)\n\n    ! The loader\'s own structure.' \
                          $'    ! The loader\'s own structure.'
  run_case M15-kernel-image-allocatable
}
case_M16() {
  # The anchor MUST reach as far as `cursor`: pmm_init's cleanup path carries a
  # byte-identical fill loop and the same first five resets, appears earlier in
  # the file, and would be the one substituted -- which mutates a path this gate
  # never exercises and reports a spurious escape.  It did, once.
  subst src/mm/fk_pmm.f90 $'    do w = 1_c_int32_t, FK_PMM_WORDS\n       bitmap(w) = FK_PMM_WORD_FULL\n    end do\n    ready      = .false.\n    reg_count  = 0_c_int32_t\n    ram_pages  = 0_c_int64_t\n    free_count = 0_c_int64_t\n    ignored    = 0_c_int64_t\n    cursor     = 1_c_int32_t' \
                          $'    ready      = .false.\n    reg_count  = 0_c_int32_t\n    ram_pages  = 0_c_int64_t\n    free_count = 0_c_int64_t\n    ignored    = 0_c_int64_t\n    cursor     = 1_c_int32_t'
  run_case M16-bitmap-never-filled
}
case_M17() {
  subst src/mm/fk_pmm.f90 $'       b = trailz(not(bitmap(w)))\n       bitmap(w) = ibset(bitmap(w), b)' \
                          $'       b = trailz(not(bitmap(w)))'
  run_case M17-alloc-never-marks
}
case_M18() {
  subst src/mm/fk_pmm.f90 "    if (w < cursor) cursor = w" "    continue"
  run_case M18-free-never-rewinds
}
case_M19() {
  subst src/mm/fk_pmm.f90 $'    if (in_span(phys, kern_lo, kern_hi) .or. in_span(phys, mbi_lo, mbi_hi)) then\n       status = FK_PMM_E_LOCKED\n       return\n    end if' \
                          "    continue"
  run_case M19-free-ignores-locked
}
# The one that only a linked image can catch: boot/ksyms.S hands Fortran the
# value of an absolute linker symbol, and a wrong constant marks the wrong
# frames used while every console verdict still prints PASS.
case_M20() {
  # roadmap 3.5 turned seventeen near-identical accessors into one KSYM macro,
  # so the defect is now injected into the macro BODY and every accessor in the
  # image returns zero at once. printf builds both strings: the anchor contains
  # tabs, a '$' immediate and a '\sym' macro parameter, and no bash quoting
  # style leaves all three alone.
  subst boot/ksyms.S "$(printf '\tmovabsq\t$\\sym, %%rax')" \
                     "$(printf '\tmovabsq\t$0x0, %%rax')"
  run_case M20-ksyms-wrong-constant
}

# --- roadmap 3.5: the VMM and the higher-half handoff ------------------------
# M21 is the one that says why the boot gate rejects the string "RWX". The
# kernel's own vmm_verify_image compares the LIVE tables against the table of
# intentions it built -- so mutating the INTENTION passes that check with
# nothing to report. What it cannot do is stop the permission column from
# saying so.
case_M21() {
  subst src/mm/fk_vmm.f90 "    sec_flags(2) = perm(.false., .true.)" \
                          "    sec_flags(2) = perm(.true., .true.)"
  run_case M21-text-mapped-writable
}
case_M22() {
  subst src/mm/fk_vmm.f90 $'       if (v /= guard_page) then\n          status = vmm_map_page(v, v - kernel_vma, flags)\n          if (status /= FK_VMM_OK) return\n       end if' \
                          $'       status = vmm_map_page(v, v - kernel_vma, flags)\n       if (status /= FK_VMM_OK) return'
  run_case M22-guard-page-mapped
}
case_M23() {
  subst src/mm/fk_vmm.f90 $'    t(1) = 0_c_int64_t\n    call fk_write_cr3(pml4_phys)' \
                          $'    call fk_write_cr3(pml4_phys)'
  run_case M23-pml4-0-never-zeroed
}
# THE ONE THE DEFAULT BUILD CANNOT SEE, and the reason FK_FAULT_MODE grew a
# third value. Zeroing PML4[0] without reloading CR3 leaves the translation in
# the TLB: vmm_translate walks the tables in software and correctly reports the
# window gone, every console verdict prints PASS -- and the CPU goes on
# resolving physical addresses through a cached entry. Only a real load from
# 0x100000 disagrees, which is what the idmap build performs.
case_M24() {
  subst src/mm/fk_vmm.f90 $'    t(1) = 0_c_int64_t\n    call fk_write_cr3(pml4_phys)' \
                          $'    t(1) = 0_c_int64_t'
  mode_idmap
  run_case M24-unmap-without-tlb-flush
}
# EFER.NXE left clear while the tables still carry bit 63. That bit is then
# RESERVED rather than no-execute, so the first read of a .rodata string faults,
# the fault handler reads .rodata to say so, and the machine triple-faults.
case_M25() {
  subst boot/mmu.S "$(printf '\torl\t$EFER_NXE, %%eax\n\twrmsr')" \
                   "$(printf '\torl\t$EFER_NXE, %%eax')"
  run_case M25-nx-bits-without-nxe
}
# CR0.WP never set. This is the defect the whole -4 build exists for: it changes
# NOTHING that any other gate can see. .text is still mapped R-X, the permission
# column still says so, vmm_verify_image still returns 0, and the console still
# claims CR0.WP -- because fk_mmu_arm's return value only ever reported the NX
# half. Only a store to .text can tell, and only if the CPU refuses it.
case_M27() {
  subst boot/mmu.S "$(printf '\tmovq\t%%cr0, %%rax\n\torq\t$CR0_WP, %%rax\n\tmovq\t%%rax, %%cr0')" \
                   "$(printf '\tmovq\t%%cr0, %%rax')"
  mode_wp
  run_case M27-cr0-wp-never-set
}

# The guard accessor pointed at a different linker symbol. The static gate
# catches it on the naming convention alone; the boot gate catches it because
# the VMM then leaves a live .bss page unmapped and maps the guard.
case_M26() {
  subst boot/ksyms.S "$(printf '\tKSYM\tfk_boot_stack_guard,   __boot_stack_guard')" \
                     "$(printf '\tKSYM\tfk_boot_stack_guard,   __bss_start')"
  run_case M26-guard-accessor-wrong-symbol
}

# --- roadmap 3.2b: interrupts that return ------------------------------------
# THE ONE THE WHOLE MILESTONE IS ABOUT. Point the IRQ tail at the panic tail --
# which is what every vector in this tree did before 3.2b -- and the first timer
# interrupt is also the last instruction the kernel ever executes.
case_M28() {
  subst boot/interrupts.S "$(printf '\tiretq')" "$(printf '\tjmp\tfk_cpu_halt')"
  run_case M28-irq-tail-halts
}
# The frame is 22 quadwords and the CPU pushed only five of them. Without this
# adjustment IRETQ reads the line number the stub pushed as the return RIP.
case_M29() {
  subst boot/interrupts.S "$(printf '\taddq\t$16, %%rsp\n\tiretq')" \
                          "$(printf '\tiretq')"
  run_case M29-iretq-wrong-frame-size
}
# No EOI. The 8259 goes on holding its in-service bit, so exactly ONE interrupt
# is ever delivered -- which is why the proof loop waits for three.
case_M30() {
  subst src/cpu/fk_idt.f90 '    call pic_eoi(line)' '    continue'
  run_case M30-no-eoi
}
# The line is never opened. Everything else is correct and nothing arrives.
case_M31() {
  subst src/boot/fk_kmain.f90 $'    call pic_unmask(FK_PIT_IRQ)\n' ''
  run_case M31-irq0-never-unmasked
}
# Vectors 32-47 left not-present. The first tick raises #GP instead, which is
# 3.2's "an unhandled vector must fault rather than jump to a zeroed offset"
# arriving from the other direction.
case_M32() {
  subst src/cpu/fk_idt.f90 $'    do v = 0_c_int32_t, FK_PIC_LINES - 1_c_int32_t\n       call idt_set_gate(FK_PIC1_VECTOR + v, fk_irq_stub(v))\n    end do\n\n' ''
  run_case M32-irq-gates-not-present
}
# THE ONE THAT USED TO ESCAPE, AND NO LONGER DOES -- caught 3 runs out of 3
# since roadmap 3.3 landed. Delete the three OUTs and the chip keeps whatever
# divisor the firmware left, which on this machine still ticks, at 18.2 Hz
# instead of 100. Every console line still passes: the divisor the kernel
# prints is the one it COMPUTED, and the 8253 has no readback for the reload
# value.
#
# What closes it is FK_CHECK_SCHED, and by accident rather than by design. It
# reads the two spawned threads' own loop counters a quarter of a second apart,
# and at 18.2 Hz they do not move in that window -- context switches still grow
# (50 -> 54), so the machine is demonstrably alive; the per-thread counters are
# simply not sampled often enough to change. That IS the timing assertion this
# comment used to say nobody had written, arrived at sideways.
#
# BEING HONEST ABOUT WHAT THAT MEANS: it is a MARGIN, not a bound. A slower
# sampling interval, a faster loop body, or a machine whose firmware leaves a
# different divisor would all move it. If this starts escaping again, the fix
# is a real frequency assertion -- count ticks against a known wall-clock
# interval read from outside the guest -- and not a longer FK_SCHED interval.
case_M33() {
  subst src/drivers/pit/fk_pit.f90 $'    call fk_outb(PIT_CMD, FK_PIT_MODE)\n    call fk_outb(PIT_CH0, iand(divisor, FK_BYTE))\n    call fk_outb(PIT_CH0, iand(ishft(divisor, -8), FK_BYTE))\n' ''
  run_case M33-pit-never-programmed
}


# --- roadmap 2.2: the framebuffer's memory type ------------------------------
# Drop PWT from the framebuffer's flags. The mapping still works and every
# pixel still lands; it is merely WRITE-BACK, so each glyph becomes a
# read-modify-write of a cache line nothing ever reads. Nothing on screen looks
# different, which is why the PTE is decoded and printed rather than trusted.
case_M34() {
  subst src/mm/fk_vmm.f90 "ior(FK_PTE_PWT, FK_PTE_NX))" \
                          "ior(0_c_int64_t, FK_PTE_NX))"
  run_case M34-framebuffer-write-back
}
# Stop punching the aperture out of the linear map. The framebuffer is then
# reachable BOTH ways -- write-combining at FK_VMM_MMIO and write-back through
# the physmap -- which is undefined behaviour (SDM Vol.3 11.12.4) and which
# nothing on screen, on COM1 or in a pixel dump would otherwise reveal.
case_M35() {
  subst src/mm/fk_vmm.f90 "       if (.not. hits_hole(p)) then" \
                          "       if (.true.) then"
  run_case M35-framebuffer-aliased
}

# --- roadmap 3.6: the heap ---------------------------------------------------
# Backward coalescing removed. Forward coalescing alone passes every other heap
# verdict -- alignment, non-overlap, patterns, the guards -- and leaves the heap
# in a fragment per free that no later allocation can merge.
case_M36() {
  subst src/mm/fk_heap.f90 $'    call coalesce_fwd(a)\n    call coalesce_back(a)' \
                           $'    call coalesce_fwd(a)'
  run_case M36-heap-no-backward-coalesce
}

# --- roadmap 3.7: tasks ------------------------------------------------------
# A spawned task's RFLAGS with IF CLEAR. It runs, and it is never preempted
# again: the round robin stops on the first task it switches to and the boot
# thread -- the one that prints every verdict -- never runs again.
case_M37() {
  subst src/cpu/fk_sched.f90 "RFLAGS_IF = int(z'202', c_int64_t)" \
                             "RFLAGS_IF = int(z'2', c_int64_t)"
  run_case M37-task-starts-with-IF-clear
}
# THE SWITCH ITSELF. Ignore the RSP irq_handler returned and pop the frame that
# was pushed. Every task is created, the scheduler picks them in turn and
# increments its own counters, and not one instruction of either thread ever
# executes -- which is exactly why fk_task_runs is incremented by the THREAD.
case_M38() {
  subst boot/interrupts.S "$(printf '\tmovq\t%%rax, %%rsp')" "$(printf '\tnop')"
  run_case M38-irq-ignores-returned-rsp
}
# The scheduler is never armed. Identical to M38 from every serial line's point
# of view, and it is a one-word difference in the source.
case_M39() {
  subst src/boot/fk_kmain.f90 $'    call sched_start()\n' ''
  run_case M39-preemption-never-armed
}

ALL="baseline_none baseline_df baseline_de baseline_oom baseline_guard \
     baseline_idmap baseline_wp M1 M2 M3 M4 M5 M6 M7 M8 M9 M10 M11 \
     M12 M13 M14 M15 M16 M17 M18 M19 M20 M21 M22 M23 M24 M25 M26 M27 \
     M28 M29 M30 M31 M32 M33 M34 M35 M36 M37 M38 M39"
for c in $ALL; do
  want_case "$c" || continue
  echo "=== $c ==="
  EXPECT="$NONE_EXPECT"; REJECT="$NONE_REJECT"; POST_BUILD=""
  CHECK_TICKS=1; CHECK_SCHED=1; FB_EXPECT=console
  restore
  "case_$c"
  restore
done

echo "=== restoring and rebuilding the real tree ==="
restore
./tools/run.sh clean-boot >/dev/null 2>&1
./tools/run.sh iso >/dev/null 2>&1 && echo "tree restored and ISO rebuilt"
git status --short
