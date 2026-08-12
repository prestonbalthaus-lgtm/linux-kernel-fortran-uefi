#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Boots build/boot/fortran-kernel.iso in a headless QEMU and asserts three
# things about the running guest: the four-word handoff record in guest
# physical memory (read over QMP), the banner the kernel puts on COM1, and the
# absence of the kernel's own report that its UART self-test failed.
#
# Usage:
#   tools/qemu-boot-test.sh              boot the ISO and assert all three
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
#   FK_EXPECT_SERIAL  the exact string COM1 must carry
#   FK_REJECT_SERIAL  the exact string COM1 must NOT carry
#   FK_ACCEL          force 'kvm' or 'tcg'
#   FK_SMP / FK_MEM   override the mandated 6 vCPU / 24 GB allocation
set -uo pipefail
cd "$(dirname "$0")/.."

SENTINEL="tools/qmp-sentinel.py"
ISO="${FK_ISO:-build/boot/fortran-kernel.iso}"
KERNEL="${FK_KERNEL:-build/boot/kernel.elf}"
BOOT_WAIT="${FK_BOOT_WAIT:-3}"
DEADLINE="${FK_BOOT_DEADLINE:-45}"
POLL_INTERVAL="${FK_POLL_INTERVAL:-1}"

# The default must stay byte-for-byte the literal in src/boot/fk_kmain.f90.
EXPECT_SERIAL="${FK_EXPECT_SERIAL:-Fortran Kernel: UART Serial Initialized.}"

# The project's mandated allocation; QEMU does not preallocate the 24G.
SMP="${FK_SMP:-6}"
MEM="${FK_MEM:-24G}"

# --help prints the header block above.
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
  if ! ADDR_OUT=$(python3 "$SENTINEL" addr "$KERNEL" 2>&1 >/dev/null); then
    say "FAIL: cannot locate the sentinel symbol in $KERNEL"; say "$ADDR_OUT"; exit 1
  fi
  say "sentinel   : ${ADDR_OUT#\# }"
else
  say "image      : NONE (--smoke: kernel-less guest; BOTH assertions MUST refuse it)"
  [[ -f "$KERNEL" ]] || { say "FAIL: --smoke still needs $KERNEL for the symbol address"; exit 1; }
  DEADLINE=0
fi
say "banner     : \"$EXPECT_SERIAL\""

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

#   -F  the banner is a literal, so its trailing '.' is not a regex wildcard
#   -a  a stray control byte must not make grep treat the capture as binary
#   --  the expected string is overridable and could begin with '-'
serial_has_banner() {
  [[ -s "$SERIAL_LOG" ]] && grep -aFq -- "$EXPECT_SERIAL" "$SERIAL_LOG"
}

# The negative assertion: src/boot/fk_kmain.f90 prints this when serial_init's
# loopback probe does not read back the byte it wrote.
REJECT_SERIAL="${FK_REJECT_SERIAL:-Fortran Kernel: COM1 loopback self-test FAILED.}"
serial_has_failure() {
  [[ -s "$SERIAL_LOG" ]] && grep -aFq -- "$REJECT_SERIAL" "$SERIAL_LOG"
}

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
  if (( SERIAL_OK == 1 )); then ser="PASS  the expected string appeared on COM1"
  else                          ser="FAIL  the expected string never appeared on COM1"
  fi
  say "  sentinel   (1.2) : $sent"
  say "  COM1 banner(2.1) : $ser"
# --smoke boots no kernel, so the negative assertion is vacuous there.
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

# -display none : headless.
# -no-reboot    : a triple fault exits QEMU instead of resetting forever.
# -serial file: : a file can be re-read on every poll; a consumed stream cannot.
# -nic none     : without it QEMU attaches a default e1000 on user-mode slirp.
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
if (( SENTINEL_OK == 1 )) && (( SERIAL_OK == 1 )) && (( SELFTEST_BAD == 0 )) \
   && (( QEMU_DIED == 0 )); then
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
