#!/usr/bin/env bash
# Every fk_*.f90 is a derivative work of a specific kernel .c file and must carry
# THAT FILE'S license -- the kernel's lib/ is not uniformly GPL-2.0-only
# (int_log.c is LGPL-2.1-or-later, siphash.c is dual GPL/BSD). This reads each
# translation's ORACLE_<name> from its mk/ fragment, looks up the upstream SPDX
# tag, and prepends a matching header. Idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."
KDIR=vendor/linux-7.1.8

for frag in mk/*.mk; do
  name=$(basename "$frag" .mk)
  oracle=$(grep -oP "^ORACLE_${name}\s*:=\s*\K.*" "$frag" | tr -d ' ')
  fsrc=$(grep -oP "^FSRC_${name}\s*:=\s*\K.*" "$frag" | tr -d ' ')
  [ -n "${oracle:-}" ] && [ -n "${fsrc:-}" ] && [ -f "$fsrc" ] || { echo "  SKIP $name (incomplete fragment)"; continue; }
  [ -f "$KDIR/$oracle" ] || { echo "  SKIP $name (oracle $oracle not found)"; continue; }

  tag=$(head -5 "$KDIR/$oracle" | grep -o 'SPDX-License-Identifier: .*' | head -1 | sed 's/SPDX-License-Identifier: //')
  if [ -z "$tag" ]; then
    echo "  WARN $name: upstream $oracle carries NO SPDX tag -- needs manual review"
    continue
  fi
  if head -1 "$fsrc" | grep -q 'SPDX-License-Identifier'; then
    cur=$(head -1 "$fsrc" | sed 's/.*SPDX-License-Identifier: //')
    [ "$cur" = "$tag" ] && echo "  OK   $name ($tag)" || echo "  DIFF $name: has '$cur', upstream says '$tag'"
    continue
  fi
  tmp=$(mktemp)
  { echo "! SPDX-License-Identifier: $tag"
    echo "!"
    echo "! Derived from Linux $( [ -f $KDIR/Makefile ] && awk -F' = ' '/^VERSION/{v=$2}/^PATCHLEVEL/{p=$2}/^SUBLEVEL/{s=$2}END{print v"."p"."s}' $KDIR/Makefile ) $oracle"
    echo "! Original C authors retain copyright; this is a translation, not new work."
    cat "$fsrc"
  } > "$tmp"
  mv "$tmp" "$fsrc"
  echo "  ADD  $name ($tag)  <- $oracle"
done
