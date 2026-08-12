#!/usr/bin/env bash
# Audits every translation against the project's mandatory Fortran standards
# (docs/superpowers/plans/2026-08-12-phase1-lib-fortran.md, Global Constraints).
# These are spec requirements, not style preferences -- a violation fails the build.
#
# Every check runs against a COMMENT-STRIPPED copy of the source. The previous
# version grepped raw text, so `bind(c)` appearing only inside a comment
# satisfied the gate, and a banned construct anywhere but column 1 was invisible.
# See docs/AUDIT-PHASE1.md finding A-1 for the counterexample that motivated this.
#
# Self-test: tools/gate-selftest.sh proves each check below rejects a file that
# violates it. A gate nobody has watched fail is not a gate.
set -uo pipefail
cd "$(dirname "$0")/.."

SRCDIR="${1:-src}"
fail=0

# Free-form Fortran: '!' starts a comment EXCEPT inside a character literal.
#
# This was one sed substitution, `sed 's/!.*//'`, carrying a comment that said
# no translated module contained a character literal -- they were pure integer
# code -- so cutting at the first '!' was exact, and to revisit it if that ever
# changed. Roadmap 2.1 changed it: src/boot/fk_kmain.f90:148 declares FK_BANNER
# and passes it to serial_print_string (fk_kmain.f90:233), so the stated
# precondition is gone and there is no getting it back.
#
# Today's banner reads "Fortran Kernel: UART Serial Initialized." and contains
# neither a '!' nor the words "go to", so the old sed still happens to survive
# the tree -- which is the whole problem with leaving it in place. The gate
# would be one punctuation mark away from lying, and nothing would say so. All
# three failures below were reproduced against the old sed before it was
# replaced:
#
#   character(...), parameter :: FK_PROMPT = "ready! ", FK_BANNER = "fk"
#       the cut deletes everything after the '!', so FK_BANNER never looks
#       declared, and check 3 below prints `-> unbound: FK_BANNER` about a
#       public PARAMETER that its own exemption covers. A FALSE POSITIVE on
#       correct source, which is how a gate stops being read.
#
#   character(...), parameter :: MSG = "go to the console"
#       check 2 greps the whole line for banned constructs and cannot tell
#       banner TEXT from code: `-> banned-construct` on a module with no GOTO.
#
#   if (iachar(c) == iachar("!")) go to 100
#       the cut lands INSIDE the literal and takes the real `go to` with it.
#       The old gate exited 0 on this file. A FALSE NEGATIVE, and the reason
#       this is a correctness fix and not a usability one.
#
# tools/strip-comments.awk walks each line character by character instead,
# tracking literal state (including Fortran's doubled-delimiter escape). It
# truncates at '!' only outside a literal, and it BLANKS the contents of every
# literal while keeping the delimiters, so the checks below still see a
# well-formed statement but can never read string text as code. All three
# cases above are fixtures in tools/gate-selftest.sh, each recorded there with
# what the old sed did to it.
#
# WHAT THIS DOES NOT GUARANTEE, so that nobody reads more into it later:
#   * A character literal continued across lines with '&' cannot be analysed --
#     quote state resets at end of line. This is NOT merely "the tail is not
#     recognised as literal text": on the continuation line the CLOSING quote
#     reads as an OPENING one, so real code after it is blanked and a banned
#     construct there becomes invisible. That is a FALSE NEGATIVE, and the sed
#     this replaced did not have it. The stripper therefore REFUSES such a file
#     (exit 2) rather than reporting it clean, and the branch above turns that
#     into a named failure. See tools/strip-comments.awk's header for the
#     two-line reproduction and tools/gate-selftest.sh for the fixture that
#     watches the refusal happen.
#   * Blanking erases the binding label too: `bind(c, name="serial_init")`
#     reaches check 3 as `bind(c, name="           ")`. That is structural, not
#     an oversight -- check 3 has only ever matched `bind` `(` `c`, and cannot
#     verify that a binding label agrees with the procedure it names. If that
#     ever becomes a rule it needs the raw source, not this copy.
strip_comments() { awk -f tools/strip-comments.awk "$1"; }

# Fold Fortran free-form line continuations into one logical line each, so that
# every check below sees whole statements. Without it a public procedure listed
# on a continuation line is never checked for bind(c) at all -- see the header
# of tools/fold-continuations.awk for the three shapes that hid things, and
# tools/gate-selftest.sh for the cases that prove each is now caught.
fold_continuations() { awk -f tools/fold-continuations.awk; }

printf "%-22s %-9s %-7s %-8s %-10s %-5s %s\n" \
       MODULE implicit banned "bind(c)" intrinsic SPDX form

for f in $(find "$SRCDIR" -name 'fk_*.f90' | sort); do
  n=$(basename "$f" .f90)
  code=$(mktemp) || exit 1
  stripped=$(mktemp) || exit 1
  strerr=$(mktemp) || exit 1

  # THE STRIP IS ITS OWN STEP, NOT THE HEAD OF A PIPELINE, so that its exit
  # status can be read. tools/strip-comments.awk exits 2 when a line ends with a
  # character literal still open -- the one input it cannot analyse -- and a
  # `strip | fold > code` pipeline reports only the FOLDER's status, so the
  # refusal would be discarded and every check below would then run against a
  # copy the stripper had already disclaimed. Failing open on the input a gate
  # admits it cannot read is the same defect as A-1 in docs/AUDIT-PHASE1.md,
  # arrived at from the other direction.
  if ! strip_comments "$f" > "$stripped" 2>"$strerr"; then
    printf "%-22s %s\n" "$n" "REFUSED -- source could not be analysed"
    sed 's/^/                       /' "$strerr"
    fail=1
    rm -f "$code" "$stripped" "$strerr"
    continue
  fi
  fold_continuations < "$stripped" > "$code"
  rm -f "$stripped" "$strerr"
  notes=""

  # --- 1. implicit none in EVERY program unit, not merely once per file -----
  read -r units imps < <(awk '
    /^[[:space:]]*end([[:space:]]|$)/                            { next }
    /^[[:space:]]*(module|program)[[:space:]]+[A-Za-z]/          { u++ }
    /(^|[[:space:]])(function|subroutine)[[:space:]]+[A-Za-z]/   { u++ }
    /^[[:space:]]*implicit[[:space:]]+none([[:space:]]|$)/       { i++ }
    END { print u+0, i+0 }' "$code")
  if [ "$units" -gt 0 ] && [ "$imps" -ge "$units" ]; then
    impl="$imps/$units"
  else
    impl="$imps/$units"; fail=1; notes="$notes implicit-none-per-unit"
  fi

  # --- 2. banned legacy constructs, anywhere on the line -------------------
  if grep -iqE '(^|[^A-Za-z_])(go[[:space:]]*to|common|equivalence)([^A-Za-z_]|$)' "$code"; then
    banned=FOUND; fail=1; notes="$notes banned-construct"
  else
    banned=none
  fi

  # --- 3. EVERY public procedure is bind(c, name=...) ----------------------
  # NB: strip blanks per-line with sed, never `tr -d '[:space:]'` -- that would
  # delete the newlines too and fuse `public :: a, b` into a single token.
  pubs=$(grep -hE '^[[:space:]]*public[[:space:]]*::' "$code" \
         | sed 's/^[^:]*:://' | tr ',&' '\n\n' | sed 's/[[:blank:]]//g' | grep -v '^$')
  #
  # SCOPE OF THIS RULE. It exists because everything this project exports
  # crosses into C or assembly, where gfortran's name mangling and calling
  # conventions are not the contract. That applies to PROCEDURES and to module
  # VARIABLES, both of which become real symbols.
  #
  # It does NOT apply to a public PARAMETER: a Fortran named constant is a
  # compile-time value that produces no symbol, has no calling convention and
  # has nothing to name across an ABI. FONT_W/FONT_H in fk_font_8x16 are the
  # case in point -- they are the font's geometry, USEd by the renderer at
  # compile time. Requiring bind(c) on them would be requiring a C binding for
  # the number 8. The exemption is deliberately narrow: it fires only when the
  # name really is declared PARAMETER in this file, so a public module variable
  # is still held to the rule.
  missing=""
  for p in $pubs; do
    grep -qE "(function|subroutine)[[:space:]]+${p}[[:space:]]*\(.*bind[[:space:]]*\([[:space:]]*c" "$code" \
      && continue
    grep -qiE "^[[:space:]]*[^!]*,[[:space:]]*parameter[[:space:]]*::.*(^|[^A-Za-z0-9_])${p}([^A-Za-z0-9_]|$)" "$code" \
      && continue
    missing="$missing $p"
  done
  if [ -z "$pubs" ]; then
    bindc=NO-PUBLIC; fail=1; notes="$notes no-public-export"
  elif [ -n "$missing" ]; then
    bindc=MISSING; fail=1; notes="$notes unbound:$missing"
  else
    bindc=OK
  fi

  # --- 4. ISO_C_BINDING must be the INTRINSIC module -----------------------
  if grep -qE '^[[:space:]]*use[[:space:]]+iso_c_binding' "$code"; then
    intr=BARE; fail=1; notes="$notes bare-use-iso-c-binding"
  elif grep -qE '^[[:space:]]*use,[[:space:]]*intrinsic[[:space:]]*::[[:space:]]*iso_c_binding' "$code"; then
    intr=OK
  else
    intr=ABSENT; fail=1; notes="$notes no-iso-c-binding"
  fi

  # --- 5. SPDX on line 1 ---------------------------------------------------
  head -1 "$f" | grep -q 'SPDX-License-Identifier' && spdx=OK || { spdx=MISSING; fail=1; }

  # --- 6. free-form only (checked on RAW source) ---------------------------
  if grep -qE '^     [^ ]' "$f"; then form=FIXED; fail=1; else form=free; fi

  printf "%-22s %-9s %-7s %-8s %-10s %-5s %s\n" \
         "$n" "$impl" "$banned" "$bindc" "$intr" "$spdx" "$form"
  [ -n "$notes" ] && printf "%-22s   ->%s\n" "" "$notes"
  rm -f "$code"
done

echo
if [ $fail -eq 0 ]; then
  echo "=== all translations comply with the mandatory standards ==="
else
  echo "=== COMPLIANCE FAILURES ABOVE ==="
fi
exit $fail
