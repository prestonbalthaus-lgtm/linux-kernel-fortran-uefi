#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# THE BOOT GATE (roadmap 1.2, and the first half of 0.3).
#
# Boots build/boot/fortran-kernel.iso in a headless QEMU, reaches into the
# running guest's PHYSICAL memory over QMP, and asserts the four-word boot
# sentinel that src/boot/fk_kmain.f90 wrote there. The fourth word is TAG xor
# magic, computed by Fortran at run time from the value GRUB left in EAX, so a
# pass is evidence that live loader data crossed the assembly -> Fortran ABI
# boundary -- not merely that the machine did not crash.
#
# Everything before this gate (grub2-file, tools/mb2-check.py, the linker
# script's ASSERTs) checks a FILE. This is the only gate that checks a
# RUNNING CPU, and it is the only one that can catch a forgotten PHYS() in the
# 32-bit half of boot.S, a bad GDT, or a stack that is not 16-byte aligned at
# the call site.
#
# Binary parsing and the assertion itself live in tools/qmp-sentinel.py,
# because bash is the wrong tool for that. This script owns only the VM
# lifecycle.
#
# SAFETY: the host is never modified. Nothing is installed, no bootloader is
# written, no systemd unit is created, no network device is attached. The only
# execution boundary crossed is QEMU, and the VM is torn down unconditionally.
#
# Usage:
#   tools/qemu-boot-test.sh              boot the ISO and assert the sentinel
#   tools/qemu-boot-test.sh --selftest   prove the assertion logic (no QEMU)
#   tools/qemu-boot-test.sh --smoke      prove the QMP/pmemsave plumbing against
#                                        a kernel-less guest, and prove the
#                                        assertion REFUSES it
#
# Environment overrides (all optional):
#   FK_ISO            path to the ISO           (default build/boot/...)
#   FK_KERNEL         path to the ELF           (default build/boot/kernel.elf)
#   FK_BOOT_WAIT      seconds before first dump (default 3)
#   FK_BOOT_DEADLINE  seconds to keep retrying  (default 45)
#   FK_POLL_INTERVAL  seconds between attempts  (default 1)
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

# -smp 6 -m 24G is the project's mandated hard resource allocation (roadmap
# 0.3). QEMU does not preallocate, so the 24 GB is address space, not resident
# memory -- but the VM is still killed unconditionally below, because a stray
# guest holding that reservation is exactly the kind of thing that is only
# noticed the next time something else needs the machine.
SMP="${FK_SMP:-6}"
MEM="${FK_MEM:-24G}"

MODE=gate
case "${1:-}" in
  --selftest) exec python3 "$SENTINEL" selftest ;;
  --smoke)    MODE=smoke ;;
  -h|--help)  sed -n '3,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")         ;;
  *)          echo "qemu-boot-test: unknown option '$1' (try --help)" >&2; exit 2 ;;
esac

rule() { printf '%s\n' "======================================================================"; }
say()  { printf '%s\n' "$*"; }

[[ -r "$SENTINEL" ]] || { say "FAIL: missing $SENTINEL -- the assertion lives there"; exit 1; }

rule
say "PROJECT FORTRAN-KERNEL :: BOOT GATE (roadmap 1.2)"
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
  say "image      : NONE (--smoke: kernel-less guest; the sentinel MUST be absent)"
  [[ -f "$KERNEL" ]] || { say "FAIL: --smoke still needs $KERNEL for the symbol address"; exit 1; }
  DEADLINE=0
fi

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

# --- launch ----------------------------------------------------------------
# -display none : headless.
# -no-reboot    : a triple fault EXITS QEMU instead of silently resetting
#                 forever, which turns an unbootable kernel into a diagnosable
#                 failure rather than a timeout.
# -nic none     : no network device at all. Without it QEMU attaches a default
#                 e1000 on user-mode slirp, and a guest that fails to boot the
#                 ISO falls through to iPXE and gets outbound egress through
#                 the host's network stack. A boot gate has no business
#                 touching the network.
QEMU_ARGS=(
  -smp "$SMP" -m "$MEM"
  -display none
  -no-reboot
  -serial none
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

# --- poll for the sentinel -------------------------------------------------
# Retrying beats one fixed sleep: a pass breaks out immediately, while a slow
# GRUB menu or a TCG boot still gets the full deadline before being called dead.
nap "$BOOT_WAIT"

GOT_DUMP=0; PASSED=0; QEMU_DIED=0; ATTEMPT=0; START=$SECONDS
while :; do
  ATTEMPT=$(( ATTEMPT + 1 ))
  if ! qemu_alive; then
    QEMU_DIED=1
    wait "$QPID" 2>/dev/null || true
    QPID=""
    break
  fi
  if python3 "$SENTINEL" dump --qmp "$SOCK" --elf "$KERNEL" --out "$DUMP" \
       --timeout 10 --no-quit 2>"$TMP/dump.err"; then
    GOT_DUMP=1
    if python3 "$SENTINEL" check "$DUMP" --quiet >/dev/null 2>&1; then
      PASSED=1; break
    fi
    [[ "$MODE" == smoke ]] && break
  fi
  (( SECONDS - START >= DEADLINE )) && break
  nap "$POLL_INTERVAL"
done
ELAPSED=$(( SECONDS - START ))

if qemu_alive; then
  python3 "$SENTINEL" quit --qmp "$SOCK" --timeout 5 >/dev/null 2>&1 || true
fi

# --- verdict ---------------------------------------------------------------
if [[ "$MODE" == smoke ]]; then
  rule
  if (( GOT_DUMP == 1 )) && (( PASSED == 0 )); then
    say "16 bytes actually read out of a live, kernel-less guest:"
    python3 "$SENTINEL" check "$DUMP" 2>&1 | sed 's/^/  /' || true
    rule
    say "SMOKE OK"
    say "  * QMP handshake, human-monitor-command and pmemsave all work"
    say "  * the assertion CORRECTLY REFUSED a guest that never ran the kernel"
    rule
    exit 0
  fi
  if (( GOT_DUMP == 0 )); then
    say "SMOKE FAILED: could not read guest memory over QMP."
    [[ -s "$TMP/dump.err" ]] && sed 's/^/  /' "$TMP/dump.err"
    show_qemu_log
  else
    say "SMOKE FAILED: a guest with no kernel somehow satisfied the sentinel"
    say "              assertion -- the gate is broken and cannot be trusted."
  fi
  rule; exit 1
fi

rule
if (( PASSED == 1 )); then
  python3 "$SENTINEL" check "$DUMP" | sed 's/^/  /'
  rule
  say "PASS  --  multiboot2 -> long mode -> higher half -> Fortran kernel_main,"
  say "          verified in guest physical memory after ${ELAPSED}s,"
  say "          $ATTEMPT attempt(s), accelerator $ACCEL."
  say "          Word 3 was computed at run time by Fortran from the magic GRUB"
  say "          passed in, so live data provably crossed the asm -> Fortran ABI."
  rule
  exit 0
fi

if (( QEMU_DIED == 1 )); then
  say "QEMU EXITED EARLY, after ${ELAPSED}s and $ATTEMPT attempt(s)."
  say ""
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
elif (( GOT_DUMP == 0 )); then
  say "FAIL: never managed to read the guest's memory (${ELAPSED}s, $ATTEMPT attempt(s))."
  say ""; say "--- last dumper error ---"
  [[ -s "$TMP/dump.err" ]] && sed 's/^/  /' "$TMP/dump.err" || say "  (none)"
  show_qemu_log
else
  say "Sentinel assertion FAILED after ${ELAPSED}s and $ATTEMPT attempt(s)."
  say ""
  python3 "$SENTINEL" check "$DUMP" | sed 's/^/  /' || true
  say ""
  say "The guest is alive and its memory is readable, so the machine did NOT"
  say "triple-fault: execution reached somewhere and stopped. If every word is"
  say "still 0x11111111, kernel_main was never called."
fi
rule
say "FAIL"
rule
exit 1
