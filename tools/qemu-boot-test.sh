#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# THE BOOT GATE (roadmap 1.2 AND 2.1, and the first half of 0.3).
#
# Boots build/boot/fortran-kernel.iso in a headless QEMU and makes THREE
# assertions about the guest while it is running -- two positive, one negative.
# All must hold for a pass, and the verdict reports them separately so a failure
# says which one broke instead of leaving the human to re-run the gate to find
# out.
#
#   (1) THE SENTINEL (roadmap 1.2), read out of the guest's PHYSICAL memory
#       over QMP: the four-word record src/boot/fk_kmain.f90 wrote into .data.
#       The fourth word is TAG xor magic, computed by Fortran at run time from
#       the value GRUB left in EAX, so a pass is evidence that live loader data
#       crossed the assembly -> Fortran ABI boundary -- not merely that the
#       machine did not crash.
#
#   (2) THE COM1 BANNER (roadmap 2.1), read out of the file QEMU's serial
#       chardev writes: the exact string the kernel's UART driver emits once it
#       has initialised 0x3F8. A pass is evidence that Fortran code drove a
#       REAL DEVICE MODEL -- real OUT instructions, accepted by QEMU's 16550A
#       in the order a 16550A demands.
#
#   (3) NO SELF-TEST FAILURE ON COM1 (roadmap 2.1), the one NEGATIVE assertion
#       here: the kernel must not have reported that its own UART loopback
#       probe failed. serial_init transmits 0xAE into internal loopback and
#       reads it back; when that does not match, src/boot/fk_kmain.f90 says so
#       on the console. Without this check a kernel whose read path is broken
#       still prints the banner -- transmission is unaffected -- so (1) and (2)
#       both hold while COM1 is literally reporting a fault. A gate that only
#       greps for text it WANTS cannot notice a kernel telling it something is
#       wrong.
#
# NEITHER HALF REPLACES THE OTHER, which is the entire reason both are here.
# The sentinel is a memory store: it passes unchanged on a kernel whose console
# is completely broken, because nothing about it ever leaves the CPU. The
# banner cannot be shown by any dump of guest memory, because those bytes are
# not IN guest memory -- they went out a port and into QEMU's chardev, and the
# only trace they leave is on the host side of the emulator. So "reached
# Fortran with the loader's live values but cannot talk" and "talks but never
# received a real handoff" are distinguishable failures here, and it takes both
# assertions to distinguish them.
#
# Everything before this gate (grub2-file, tools/mb2-check.py, the linker
# script's ASSERTs) checks a FILE. This is the only gate that checks a
# RUNNING CPU, and it is the only one that can catch a forgotten PHYS() in the
# 32-bit half of boot.S, a bad GDT, or a stack that is not 16-byte aligned at
# the call site.
#
# Binary parsing and the sentinel assertion itself live in
# tools/qmp-sentinel.py, because bash is the wrong tool for that. The serial
# assertion is one fixed-string grep and stays here. This script owns the VM
# lifecycle.
#
# SAFETY: the host is never modified. Nothing is installed, no bootloader is
# written, no systemd unit is created, no network device is attached. The
# guest's serial output is captured into this run's own scratch directory,
# which cleanup() removes. The only execution boundary crossed is QEMU, and the
# VM is torn down unconditionally.
#
# Usage:
#   tools/qemu-boot-test.sh              boot the ISO and assert all three:
#                                        sentinel, COM1 banner, and no
#                                        self-test failure reported
#   tools/qemu-boot-test.sh --selftest   prove the assertion logic (no QEMU)
#   tools/qemu-boot-test.sh --smoke      prove the QMP/pmemsave plumbing against
#                                        a kernel-less guest, and prove BOTH
#                                        POSITIVE assertions REFUSE it (the
#                                        negative one is vacuous with no kernel,
#                                        so it is not reported there)
#
# Environment overrides (all optional):
#   FK_ISO            path to the ISO           (default build/boot/...)
#   FK_KERNEL         path to the ELF           (default build/boot/kernel.elf)
#   FK_BOOT_WAIT      seconds before first dump (default 3)
#   FK_BOOT_DEADLINE  seconds to keep retrying  (default 45)
#   FK_POLL_INTERVAL  seconds between attempts  (default 1)
#   FK_EXPECT_SERIAL  the exact string COM1 must carry
#                     (default "Fortran Kernel: UART Serial Initialized.")
#   FK_REJECT_SERIAL  the exact string COM1 must NOT carry -- the kernel's own
#                     report that its UART self-test failed
#                     (default "Fortran Kernel: COM1 loopback self-test FAILED.")
#   FK_ACCEL          force 'kvm' or 'tcg'
#   FK_SMP / FK_MEM   override the project's mandated 6 vCPU / 24 GB allocation
set -uo pipefail
cd "$(dirname "$0")/.."

SENTINEL="tools/qmp-sentinel.py"
ISO="${FK_ISO:-build/boot/fortran-kernel.iso}"
KERNEL="${FK_KERNEL:-build/boot/kernel.elf}"
BOOT_WAIT="${FK_BOOT_WAIT:-3}"
DEADLINE="${FK_BOOT_DEADLINE:-45}"
POLL_INTERVAL="${FK_POLL_INTERVAL:-1}"

# The string the kernel's UART driver must put on COM1 (roadmap 2.1). It is
# overridable because this gate outlives any single banner text, but the
# DEFAULT is deliberately the exact literal in src/boot/fk_kmain.f90: if the
# two ever drift apart the gate must fail loudly and be looked at, not be
# quietly retuned to whatever the kernel happens to say today.
#
# Matched with grep -F, so the trailing '.' is a period and not a regex
# "any character". A gate that would also accept "Initialized!" is not
# asserting the string it says it is asserting.
EXPECT_SERIAL="${FK_EXPECT_SERIAL:-Fortran Kernel: UART Serial Initialized.}"

# -smp 6 -m 24G is the project's mandated hard resource allocation (roadmap
# 0.3). QEMU does not preallocate, so the 24 GB is address space, not resident
# memory -- but the VM is still killed unconditionally below, because a stray
# guest holding that reservation is exactly the kind of thing that is only
# noticed the next time something else needs the machine.
SMP="${FK_SMP:-6}"
MEM="${FK_MEM:-24G}"

# The help text IS the header comment above: one copy, so the documentation
# cannot drift away from the script the way a hand-maintained second copy does.
#
# The block is delimited by the first non-comment line rather than by a
# hardcoded line range. The range this replaces ('3,45p') had already outlived
# its header and was printing 'set -uo pipefail' plus two lines of shell as
# though they were documentation; adding the 2.1 half above would have pushed
# it further out still. A line number that has to be hand-updated on every edit
# is a comment that is wrong by default.
usage() { sed -n '3,${/^#/!q;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }

MODE=gate
case "${1:-}" in
  --selftest) exec python3 "$SENTINEL" selftest ;;
  --smoke)    MODE=smoke ;;
  -h|--help)  usage; exit 0 ;;
  "")         ;;
  *)          echo "qemu-boot-test: unknown option '$1' (try --help)" >&2; exit 2 ;;
esac

rule() { printf '%s\n' "======================================================================"; }
say()  { printf '%s\n' "$*"; }

[[ -r "$SENTINEL" ]] || { say "FAIL: missing $SENTINEL -- the assertion lives there"; exit 1; }

rule
say "PROJECT FORTRAN-KERNEL :: BOOT GATE (roadmap 1.2 + 2.1)"
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
  # The address is read out of the ELF, never hardcoded: linker.ld decides it.
  if ! ADDR_OUT=$(python3 "$SENTINEL" addr "$KERNEL" 2>&1 >/dev/null); then
    say "FAIL: cannot locate the sentinel symbol in $KERNEL"; say "$ADDR_OUT"; exit 1
  fi
  say "sentinel   : ${ADDR_OUT#\# }"
else
  say "image      : NONE (--smoke: kernel-less guest; BOTH assertions MUST refuse it)"
  [[ -f "$KERNEL" ]] || { say "FAIL: --smoke still needs $KERNEL for the symbol address"; exit 1; }
  DEADLINE=0
fi
# Printed in both modes and quoted, because the two ways this half of the gate
# goes wrong are invisible otherwise: a banner that differs from the kernel's
# by one character, and an FK_EXPECT_SERIAL override still in the environment
# from a previous experiment.
say "banner     : \"$EXPECT_SERIAL\""

# KVM if we can have it, TCG otherwise. Say which -- a TCG boot is far slower
# and that changes how a timeout should be read.
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
# Everything the guest puts on COM1 lands here; see the -serial argument below
# for why this is a file and not stdio. It is inside $TMP, so the same cleanup()
# that kills the VM also removes it -- a boot gate leaves nothing behind.
SERIAL_LOG="$TMP/serial.log"
QPID=""

# Kill the VM unconditionally -- on success, on assertion failure, on Ctrl-C,
# on an unexpected error.
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

# Sleep as a background child and wait on it: bash defers trap handlers until
# the current FOREGROUND child exits, so a plain `sleep 45` would leave the VM
# alive for up to 45s after a SIGTERM.
nap() { sleep "$1" & wait $! 2>/dev/null || true; }
qemu_alive() { [[ -n "$QPID" ]] && kill -0 "$QPID" 2>/dev/null; }
show_qemu_log() {
  say ""; say "--- QEMU output ---"
  if [[ -s "$QEMU_LOG" ]]; then sed 's/^/  /' "$QEMU_LOG"; else say "  (QEMU said nothing)"; fi
}

# Is the banner on the wire YET? Re-reads the capture from scratch every time,
# because the guest keeps writing to it while this script polls: an answer of
# "no" one second ago says nothing about now. Cheap enough to run on every
# iteration -- it is a grep over a file that is normally a few hundred bytes.
#
#   -F  the banner is a LITERAL. Its trailing '.' must be a period, not a
#       regex wildcard that would also accept "Initialized!".
#   -a  never let one stray control byte from the firmware make grep decide the
#       file is binary and change what it reports about a match.
#   --  the expected string is user-overridable and could begin with '-'.
serial_has_banner() {
  [[ -s "$SERIAL_LOG" ]] && grep -aFq -- "$EXPECT_SERIAL" "$SERIAL_LOG"
}

# The NEGATIVE assertion, and the only one in this gate with that shape.
#
# src/boot/fk_kmain.f90 prints REJECT_SERIAL when serial_init's loopback probe
# does not read back the byte it wrote. A gate that only ever greps for text it
# WANTS cannot notice a kernel that is actively reporting a fault -- the banner
# would still be there, the sentinel would still be correct, and the run would
# be green while COM1 said the UART was broken.
#
# WHAT IT DOES NOT COVER, stated because the obvious guess is wrong and was
# measured. This assertion was expected to also catch a broken fk_inb: strip the
# `xorl %eax, %eax` from boot/io.S and the loopback probe should read back a byte
# with stale upper bits and compare unequal. It does not. That mutant was built
# and booted, and the run is clean -- at that call site the stale bits happen to
# be zero. boot/io.S's zero-extension is covered by the white-box check in
# tools/linkscript-test.sh instead. See docs/HARNESS-VALIDATION-SERIAL.md, M15.
#
# What it does cover is a UART that genuinely does not answer -- absent port
# floating to 0xFF, a mis-decoded port, loopback that never engages -- each of
# which would otherwise present as a green run.
REJECT_SERIAL="${FK_REJECT_SERIAL:-Fortran Kernel: COM1 loopback self-test FAILED.}"
serial_has_failure() {
  [[ -s "$SERIAL_LOG" ]] && grep -aFq -- "$REJECT_SERIAL" "$SERIAL_LOG"
}

# Show the bytes the guest actually emitted, not just the assertion's verdict
# on them: a banner that is wrong by one character is only diagnosable if the
# human can see it. CRs are stripped FOR DISPLAY ONLY (the file itself is what
# serial_has_banner greps) -- a UART driver that ends lines with CRLF would
# otherwise walk the terminal cursor back over the two-space indent and make
# correct output look mangled.
show_serial_log() {
  say ""; say "--- COM1 output (captured from the guest's serial port) ---"
  if [[ -s "$SERIAL_LOG" ]]; then
    tr -d '\r' < "$SERIAL_LOG" | sed 's/^/  /'
  else
    say "  (the guest wrote nothing to COM1)"
  fi
}

# Both halves, printed in EVERY verdict path. "FAIL" on its own would make the
# human re-run a 45-second gate just to learn which assertion broke.
assertion_summary() {
  local sent ser
  if   (( SENTINEL_OK == 1 )); then sent="PASS  the four-word handoff record is present and correct"
  elif (( GOT_DUMP    == 0 )); then sent="FAIL  guest memory never became readable, so it was never asserted"
  else                              sent="FAIL  read back, but not the record src/boot/fk_kmain.f90 promises"
  fi
  if (( SERIAL_OK == 1 )); then ser="PASS  the expected string appeared on COM1"
  else                          ser="FAIL  the expected string never appeared on COM1"
  fi
  say "  sentinel   (1.2) : $sent"
  say "  COM1 banner(2.1) : $ser"
  # Reported only in gate mode: --smoke runs a guest with no kernel, so "the
  # kernel did not report a self-test failure" is trivially true there and
  # printing it would read as evidence when it is an absence of evidence.
  if [[ "$MODE" == gate ]]; then
    local slf
    if serial_has_failure; then
      slf="FAIL  the kernel itself reported the COM1 loopback probe FAILED"
    else
      slf="PASS  the kernel did not report a UART self-test failure"
    fi
    say "  UART self-test   : $slf"
  fi
}

# --- launch ----------------------------------------------------------------
# -display none : headless.
# -no-reboot    : a triple fault EXITS QEMU instead of silently resetting
#                 forever, which turns an unbootable kernel into a diagnosable
#                 failure rather than a timeout.
# -serial file: : capture COM1 into $TMP, which is what the 2.1 half asserts
#                 against. Deliberately NOT stdio, for two reasons. First, this
#                 gate is scripted: it prints its own structured verdict, and
#                 guest bytes interleaved into that same stream would corrupt
#                 it -- a guest emitting a bare CR would overwrite the gate's
#                 own line, and a guest emitting nothing would be
#                 indistinguishable from a gate that forgot to look. Second, a
#                 file can be RE-READ on every poll iteration; a consumed
#                 stream cannot, and the poll loop below depends on asking the
#                 same question repeatedly. file: is also output-only, so
#                 nothing on the host's stdin can be steered into the guest --
#                 the VM gains no new reach over the host from this change.
# -nic none     : no network device at all. Without it QEMU attaches a default
#                 e1000 on user-mode slirp, and a guest that fails to boot the
#                 ISO falls through to iPXE and gets outbound egress through
#                 the host's network stack. A boot gate has no business
#                 touching the network.
QEMU_ARGS=(
  -smp "$SMP" -m "$MEM"
  -display none
  -no-reboot
  -serial "file:$SERIAL_LOG"
  -nic none
  -qmp "unix:$SOCK,server,nowait"
  -accel "$ACCEL"
)
[[ "$MODE" == gate ]] && QEMU_ARGS+=( -cdrom "$ISO" )

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

# --- poll for BOTH proofs --------------------------------------------------
# Retrying beats one fixed sleep: a pass breaks out immediately, while a slow
# GRUB menu or a TCG boot still gets the full deadline before being called dead.
#
# The two proofs live in SEPARATE flags and neither is ever allowed to stand in
# for the other, because they do not land at the same instant: the banner
# appears whenever the UART driver is first called, the sentinel store happens
# somewhere else in kernel_main, and pmemsave can only be issued once the QMP
# monitor answers. Treating either as implying the other would let this gate
# report a pass on evidence it never collected -- so the loop keeps going until
# BOTH hold, or the deadline expires. ATTEMPT therefore counts POLL ITERATIONS,
# not pmemsave calls: after the sentinel is satisfied the loop keeps spinning on
# the cheap half alone, and reading it as "the dumper needed 40 tries" would be
# wrong.
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
  # Checked first, and on every iteration: it costs one grep over a few hundred
  # bytes, and it has to keep being checked after the sentinel is satisfied.
  if (( SERIAL_OK == 0 )) && serial_has_banner; then SERIAL_OK=1; fi
  # Once the sentinel holds there is nothing further to learn from pmemsave,
  # and re-running it would overwrite the passing dump the verdict prints back.
  if (( SENTINEL_OK == 0 )); then
    if python3 "$SENTINEL" dump --qmp "$SOCK" --elf "$KERNEL" --out "$DUMP" \
         --timeout 10 --no-quit 2>"$TMP/dump.err"; then
      GOT_DUMP=1
      if python3 "$SENTINEL" check "$DUMP" --quiet >/dev/null 2>&1; then
        SENTINEL_OK=1
      fi
      # --smoke wants exactly one look at a guest that can never satisfy either
      # assertion. There is nothing to wait for, so do not wait.
      [[ "$MODE" == smoke ]] && break
    fi
  fi
  (( SENTINEL_OK == 1 && SERIAL_OK == 1 )) && break
  (( SECONDS - START >= DEADLINE )) && break
  nap "$POLL_INTERVAL"
done
ELAPSED=$(( SECONDS - START ))

# One last look before the verdict. Bytes can land between the final poll and
# the moment the loop broke, and that matters most on the QEMU_DIED path:
# "printed the banner, THEN triple-faulted" is a completely different bug
# report from "never said anything at all". The capture is a host-side file, so
# it stays readable long after the guest is gone.
if (( SERIAL_OK == 0 )) && serial_has_banner; then SERIAL_OK=1; fi

if qemu_alive; then
  python3 "$SENTINEL" quit --qmp "$SOCK" --timeout 5 >/dev/null 2>&1 || true
fi

# --- verdict ---------------------------------------------------------------
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

# QEMU_DIED == 0 is part of the pass condition, not decoration. Before the 2.1
# half existed the loop broke the instant the sentinel held, so "both proofs
# collected" and "the guest is still alive" could not come apart. Waiting for a
# second, later proof re-opens that gap: the sentinel can pass at second 4, the
# guest can triple-fault at second 9, and the final re-read of the capture can
# still find a banner the guest printed before it died. Both assertions would
# then be true of a kernel that crashed, and this gate would call it a pass.
#
# SELFTEST_BAD is the third condition, and it is a NEGATIVE one: the kernel must
# not have reported its own UART self-test as failed. Everything else this gate
# checks is "did the thing I hoped for appear"; this one is "did the thing I
# dread appear". Without it, a kernel whose loopback probe reads back garbage
# still prints the banner (the transmitter works; only the read path is broken),
# so both positive assertions hold and the gate goes green while COM1 is
# literally saying the UART is not right. What it does NOT cover is fk_inb's
# zero-extension -- that was measured and escapes; see serial_has_failure above.
SELFTEST_BAD=0
if serial_has_failure; then SELFTEST_BAD=1; fi

rule
if (( SENTINEL_OK == 1 )) && (( SERIAL_OK == 1 )) && (( SELFTEST_BAD == 0 )) \
   && (( QEMU_DIED == 0 )); then
  python3 "$SENTINEL" check "$DUMP" | sed 's/^/  /'
  # The actual bytes, not merely "the assertion held". This is the only part of
  # the output that can reveal a banner which matched but arrived mangled,
  # duplicated, or wrapped in garbage from a half-configured divisor latch.
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
  rule
  exit 0
fi

# Reported before every failure branch, so the first thing on screen is which
# half broke -- not a bare FAIL that costs another 45-second run to interpret.
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
  # Whatever reached COM1 before the fault is the guest's last words, and on a
  # kernel that prints before it crashes they are the most specific evidence
  # available about how far it got.
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
  # The banner line in the summary above still stands on its own here: a kernel
  # that talks but stores a wrong sentinel is a different bug from one that
  # does neither, and this branch must not hide that.
elif (( SELFTEST_BAD == 1 )); then
  say "THE KERNEL REPORTED ITS OWN UART SELF-TEST AS FAILED -- ${ELAPSED}s,"
  say "$ATTEMPT attempt(s)."
  say ""
  say "  Both positive assertions held: the handoff record is correct and the"
  say "  banner reached COM1. This is a fail anyway, and it is the most useful"
  say "  failure this gate produces, because the kernel diagnosed itself:"
  say "  serial_init put the port in internal loopback, transmitted 0xAE and"
  say "  did NOT read 0xAE back."
  say ""
  say "  That the banner still appeared narrows it sharply. Transmission works,"
  say "  so the WRITE path -- fk_outb, the port space, LCR/DLAB, the divisor --"
  say "  is fine. What failed is the read side or the loopback itself:"
  say "    * boot/io.S fk_inb not zero-extending EAX, so the probe comes back"
  say "      with the previous EAX's upper bits attached and compares unequal"
  say "      to 0xAE on a UART that is behaving perfectly"
  say "    * fk_inb reading the wrong port (%si rather than %di)"
  say "    * MCR loopback (0x1E) not actually taking effect before the probe"
  say "    * a FIFO flush ordered after the probe instead of before it, so the"
  say "      byte read back is a stale one"
  say "    * genuinely absent hardware: an unassigned port floats to 0xFF, and"
  say "      0xFF is not 0xAE -- which is exactly what the probe is for"
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
