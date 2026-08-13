#!/usr/bin/env bash
# Audits every src/**/fk_*.f90 against the project's mandatory Fortran standards
# (docs/superpowers/plans/2026-08-12-phase1-lib-fortran.md, Global Constraints).
# Usage: tools/compliance.sh [srcdir]   -- srcdir defaults to src.
# Every check runs on a comment-stripped, continuation-folded copy of the source,
# so a grep sees whole statements and never reads character-literal text as code.
set -uo pipefail
cd "$(dirname "$0")/.."

SRCDIR="${1:-src}"
fail=0

strip_comments() { awk -f tools/strip-comments.awk "$1"; }

fold_continuations() { awk -f tools/fold-continuations.awk; }

printf "%-22s %-9s %-7s %-8s %-10s %-5s %s\n" \
       MODULE implicit banned "bind(c)" intrinsic SPDX form

for f in $(find "$SRCDIR" -name 'fk_*.f90' | sort); do
  n=$(basename "$f" .f90)
  code=$(mktemp) || exit 1
  stripped=$(mktemp) || exit 1
  strerr=$(mktemp) || exit 1

  # Separate step, not a pipeline head: a pipeline reports only the folder's
  # status, and the stripper's exit 2 would be lost.
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

  # --- 1. implicit none in EVERY program unit, not merely once per file
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

  # --- 2. banned legacy constructs, anywhere on the line
  if grep -iqE '(^|[^A-Za-z_])(go[[:space:]]*to|common|equivalence)([^A-Za-z_]|$)' "$code"; then
    banned=FOUND; fail=1; notes="$notes banned-construct"
  else
    banned=none
  fi

  # --- 3. EVERY public procedure is bind(c, name=...)
  # NB: strip blanks per-line with sed, never `tr -d '[:space:]'` -- that would
  # delete the newlines too and fuse `public :: a, b` into a single token.
  pubs=$(grep -hE '^[[:space:]]*public[[:space:]]*::' "$code" \
         | sed 's/^[^:]*:://' | tr ',&' '\n\n' | sed 's/[[:blank:]]//g' | grep -v '^$')
  # A public PARAMETER is exempt: a named constant produces no symbol and has
  # nothing to name across an ABI. A public module VARIABLE does, and is not --
  # it satisfies this rule the same way a procedure does, by carrying
  # bind(c, name=...) on its own declaration. roadmap 3.2b exports four of
  # those, and it exports them as variables rather than through accessor
  # functions for a codegen reason src/drivers/pit/fk_pit.f90's header states:
  # a cross-module getter whose body is a volatile load is treated as
  # side-effect-free by its caller.
  missing=""
  for p in $pubs; do
    grep -qE "(function|subroutine)[[:space:]]+${p}[[:space:]]*\(.*bind[[:space:]]*\([[:space:]]*c" "$code" \
      && continue
    grep -qiE "^[[:space:]]*[^!]*,[[:space:]]*parameter[[:space:]]*::.*(^|[^A-Za-z0-9_])${p}([^A-Za-z0-9_]|$)" "$code" \
      && continue
    grep -qE "bind[[:space:]]*\([[:space:]]*c[^)]*\)[[:space:]]*::[^!]*(^|[^A-Za-z0-9_])${p}([^A-Za-z0-9_]|$)" "$code" \
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

  # --- 4. ISO_C_BINDING must be the INTRINSIC module
  if grep -qE '^[[:space:]]*use[[:space:]]+iso_c_binding' "$code"; then
    intr=BARE; fail=1; notes="$notes bare-use-iso-c-binding"
  elif grep -qE '^[[:space:]]*use,[[:space:]]*intrinsic[[:space:]]*::[[:space:]]*iso_c_binding' "$code"; then
    intr=OK
  else
    intr=ABSENT; fail=1; notes="$notes no-iso-c-binding"
  fi

  # --- 5. SPDX on line 1
  head -1 "$f" | grep -q 'SPDX-License-Identifier' && spdx=OK || { spdx=MISSING; fail=1; }

  # --- 6. free-form only, read from the RAW file: layout is a property of the
  #        source, not of the stripped copy.
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
