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

# Free-form Fortran: '!' starts a comment except inside a character literal.
# No translated module contains a character literal (they are pure integer
# code), so this substitution is exact here. Revisit if that ever changes.
strip_comments() { sed 's/!.*//' "$1"; }

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
  strip_comments "$f" | fold_continuations > "$code"
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
