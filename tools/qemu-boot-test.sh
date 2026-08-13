#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Boots build/boot/fortran-kernel.iso in a headless QEMU and asserts what the
# running guest did: the four-word handoff record in guest physical memory
# (read over QMP), every string COM1 must carry, no string it must not, and --
# on request -- the state of the task register and the two 8259s as the DEVICE
# MODELS report it rather than as the kernel claims it.
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
Fortran Kernel: PMM allocated 5 contiguous frames.
Fortran Kernel: PMM freed and reclaimed the same 5 frames.
Fortran Kernel: PMM refused a double, unaligned and locked free.
Fortran Kernel: PMM rewound its scan cursor to a freed frame.'
FK_PMM_FAIL_LINES=$'Fortran Kernel: PMM init FAILED, status 0x
Fortran Kernel: PMM reserved or ACPI frames are STILL FREE.
Fortran Kernel: PMM did NOT lock the kernel image out.
Fortran Kernel: PMM allocation is NOT contiguous.
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

EXPECT_SERIAL="${FK_EXPECT_SERIAL:-Fortran Kernel: UART Serial Initialized.
$FK_PMM_PASS_LINES
$FK_VMM_PASS_LINES}"
REJECT_SERIAL="${FK_REJECT_SERIAL:-Fortran Kernel: COM1 loopback self-test FAILED.
$FK_PMM_FAIL_LINES
$FK_VMM_FAIL_LINES}"

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
say "PROJECT FORTRAN-KERNEL :: BOOT GATE (roadmap 1.2 + 1.2b + 2.1 + 3.4 + 3.5)"
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

if (( SENTINEL_OK == 1 )) && (( SERIAL_OK == 1 )) && (( SELFTEST_BAD == 0 )) \
   && (( QEMU_DIED == 0 )) && (( HW_BAD == 0 )); then
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
