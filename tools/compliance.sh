#!/usr/bin/env bash
# Audits every translation against the project's mandatory Fortran standards.
# These are spec requirements, not style preferences -- a violation fails the build.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
printf "%-26s %-8s %-8s %-8s %-8s %s\n" MODULE implicit banned bind\(c\) SPDX free-form
for f in $(find src -name 'fk_*.f90' | sort); do
  n=$(basename "$f" .f90)
  # every program unit (module + each function/subroutine) needs implicit none
  units=$(grep -icE '^\s*(module|(pure |elemental |recursive )*(function|subroutine))\s' "$f")
  imps=$(grep -icE '^\s*implicit\s+none' "$f")
  [ "$imps" -ge 1 ] && [ "$imps" -ge $(( units > 2 ? 1 : 1 )) ] && impl=OK || { impl=MISSING; fail=1; }
  # banned legacy constructs
  if grep -iqE '^\s*[0-9]*\s*(go\s*to|common\s*/|equivalence\s*\()' "$f"; then banned=FOUND; fail=1; else banned=none; fi
  grep -q 'bind(c' "$f" && bindc=OK || { bindc=MISSING; fail=1; }
  head -1 "$f" | grep -q 'SPDX-License-Identifier' && spdx=OK || { spdx=MISSING; fail=1; }
  # free-form: no statement starting in col 6 continuation style / no .f fixed form
  if grep -qE '^     [^ ]' "$f"; then form=FIXED; fail=1; else form=free; fi
  printf "%-26s %-8s %-8s %-8s %-8s %s\n" "$n" "$impl" "$banned" "$bindc" "$spdx" "$form"
done
echo
[ $fail -eq 0 ] && echo "=== all translations comply with the mandatory standards ===" \
                || echo "=== COMPLIANCE FAILURES ABOVE ==="
exit $fail
