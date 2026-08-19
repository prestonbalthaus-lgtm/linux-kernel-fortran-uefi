#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Drives the host-suite mutation tables in docs/HARNESS-VALIDATION.md: injects
# one defect at a time into a translated library module, rebuilds and re-runs
# the differential suite, and restores the tree.  The baseline must PASS; a
# MUTATION that passes is an ESCAPE, because the suite accepted a module with a
# known defect.
#
# This is the HOST runner, not the boot runner.  tools/mutate-phase3.sh and
# tools/mutate-phase45.sh boot a VM per case and take tens of minutes;
# everything here is `make test`, so a case is seconds and the whole table is
# minutes.  A defect that only a running machine can see does not belong here.
#
# Edits the working tree in place and restores with `git checkout`, so run it
# on a clean tree.  Runs the compiler, so it goes through the container.
#
#   tools/mutate-hostlib.sh            every case
#   tools/mutate-hostlib.sh M87 M91    only those
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${FK_MUTATE_OUT:-$(mktemp -d /tmp/fk-mutate-hostlib.XXXXXX)}"
mkdir -p "$OUT"
echo "logs: $OUT"

# EVERY FILE ANY CASE BELOW MUTATES MUST BE IN THIS LIST -- restore() rewinds
# exactly these, so a case that seds a file not named here leaves its mutation
# behind and it gets reported against the next defect.
FILES="src/lib/fk_string.f90 mk/string.mk"

restore() { git checkout -- $FILES 2>/dev/null; }

# restore() rewinds to the INDEX, so a file that is untracked is not rewound at
# all and a file with unstaged edits loses them.  Either one turns this script
# from a measurement into a corruption.
for f in $FILES; do
  git ls-files --error-unmatch "$f" >/dev/null 2>&1 || {
    echo "ABORT: $f is not tracked -- 'git checkout --' cannot restore it."
    echo "       git add it first."; exit 1; }
done
if ! git diff --quiet -- $FILES && [ -z "${FK_MUTATE_FORCE:-}" ]; then
  echo "ABORT: unstaged changes in the files this script mutates:"
  git status --short -- $FILES | sed 's/^/       /'
  echo "       git add or stash them; the first restore would discard them."
  echo "       FK_MUTATE_FORCE=1 to override."; exit 1
fi

# A substitution that matched nothing is a case that silently tested the
# BASELINE and reported it as an escape.  Refuse instead.
subst() {
  local file=$1 from=$2 to=$3
  python3 - "$file" "$from" "$to" <<'PY' || { echo "SUBST FAILED in $file"; exit 1; }
import sys
path, frm, to = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if frm not in s:
    sys.exit(1)
open(path, 'w').write(s.replace(frm, to, 1))
PY
}

# TARGET is the make goal, so a case only rebuilds and runs the suite it is
# about.  A mutation to fk_string.f90 that broke the VFS suite would be a
# finding, not a nuisance -- but it would cost every case the other suite's
# runtime, and `make test` is available for that.
run_case() {
  local name=$1 target=${2:-test}
  local rc line
  ./tools/run.sh "$target" >"$OUT/$name.log" 2>&1
  rc=$?
  line=$(grep -aE "MISMATCH|checks,|Error [0-9]" "$OUT/$name.log" \
         | head -3 | tr -d '\r' | sed 's/^ *//' | paste -sd'|')
  if [ $rc -eq 0 ]; then
    if [ "$name" = baseline ]; then echo "$name: suite PASSED :: $line"
    else echo "$name: suite PASSED  <-- ESCAPE :: $line"; fi
  else                   echo "$name: suite FAILED (caught) :: $line"; fi
  restore
}

# ---- roadmap 1.1: the string half -----------------------------------------

case_baseline() { run_case baseline; }

case_M86() {
  subst src/lib/fk_string.f90 \
    $'    do while (b(n + 1_c_size_t) /= 0_c_int8_t)' \
    $'    do while (b(n + 1_c_size_t) /= 0_c_int8_t .or. n == 0_c_size_t)'
  run_case M86-strlen-counts-the-terminator
}

case_M87() {
  subst src/lib/fk_string.f90 \
    $'       d(i) = s(i)\n       if (s(i) == 0_c_int8_t) return' \
    $'       if (s(i) == 0_c_int8_t) return\n       d(i) = s(i)'
  run_case M87-strcpy-drops-the-terminator
}

case_M88() {
  subst src/lib/fk_string.f90 \
    $'       d(i) = s(i)\n       if (s(i) == 0_c_int8_t) return\n       i = i + 1_c_size_t\n    end do\n  end function fk_strcpy' \
    $'       d(i) = s(i)\n       if (s(i) == 0_c_int8_t) then\n          d(i + 1_c_size_t) = 0_c_int8_t\n          return\n       end if\n       i = i + 1_c_size_t\n    end do\n  end function fk_strcpy'
  run_case M88-strcpy-writes-one-past-the-terminator
}

# The C standard permits this and lib/string.c does not do it.  If this escapes,
# the suite is testing a weaker contract than the kernel's.
case_M89() {
  subst src/lib/fk_string.f90 \
    $'       if (c1 /= c2) then\n          if (c1 < c2) then\n             r = -1_c_int32_t\n          else\n             r = 1_c_int32_t\n          end if\n          return\n       end if\n       if (c1 == 0_c_int32_t) return\n       i = i + 1_c_size_t\n    end do\n  end function fk_strcmp' \
    $'       if (c1 /= c2) then\n          r = c1 - c2\n          return\n       end if\n       if (c1 == 0_c_int32_t) return\n       i = i + 1_c_size_t\n    end do\n  end function fk_strcmp'
  run_case M89-strcmp-returns-the-difference
}

# The 0x80-against-0x00 trap, in strcmp's costume.
case_M90() {
  subst src/lib/fk_string.f90 \
    $'       c1 = ubyte(a(i))\n       c2 = ubyte(b(i))\n       if (c1 /= c2) then\n          if (c1 < c2) then\n             r = -1_c_int32_t\n          else\n             r = 1_c_int32_t\n          end if\n          return\n       end if\n       if (c1 == 0_c_int32_t) return\n       i = i + 1_c_size_t\n    end do\n  end function fk_strcmp' \
    $'       c1 = int(a(i), c_int32_t)\n       c2 = int(b(i), c_int32_t)\n       if (c1 /= c2) then\n          if (c1 < c2) then\n             r = -1_c_int32_t\n          else\n             r = 1_c_int32_t\n          end if\n          return\n       end if\n       if (c1 == 0_c_int32_t) return\n       i = i + 1_c_size_t\n    end do\n  end function fk_strcmp'
  run_case M90-strcmp-compares-signed-bytes
}

# Removes the equal-and-terminated exit.  Both strings run off their ends, so
# this is the guard page's case and nothing in the arena can see it.
case_M91() {
  subst src/lib/fk_string.f90 \
    $'       if (c1 == 0_c_int32_t) return\n       i = i + 1_c_size_t\n    end do\n  end function fk_strcmp' \
    $'       i = i + 1_c_size_t\n    end do\n  end function fk_strcmp'
  run_case M91-strcmp-never-stops-at-the-terminator
}

case_M92() {
  subst src/lib/fk_string.f90 \
    $'    left = count\n    do while (left /= 0_c_size_t)' \
    $'    left = count\n    do while (.true.)'
  run_case M92-strncmp-ignores-count
}

# ESCAPES, AND IT IS RIGHT TO.  lib/string.c spends the count after testing for
# the terminator; this swaps them.  Both forms return immediately and neither
# reads `left` or `i` afterwards, so the two are equivalent for every input and
# there is no test that could separate them.  Kept in the table because an
# escape nobody can explain and an escape with a proof look identical in a
# summary line, and only one of them is a hole.
case_M93() {
  subst src/lib/fk_string.f90 \
    $'       if (c1 == 0_c_int32_t) return\n       i = i + 1_c_size_t\n       left = left - 1_c_size_t\n    end do\n  end function fk_strncmp' \
    $'       i = i + 1_c_size_t\n       left = left - 1_c_size_t\n       if (c1 == 0_c_int32_t) return\n    end do\n  end function fk_strncmp'
  run_case M93-strncmp-spends-count-before-the-terminator-test
}

# count == 0 must read NOTHING, which only the unmapped-page case can say.
case_M94() {
  subst src/lib/fk_string.f90 \
    $'    if (count == 0_c_size_t) return\n    if (.not. c_associated(cs)) return\n    if (.not. c_associated(ct)) return\n    call c_f_pointer(cs, a, [SCAN_MAX])\n    call c_f_pointer(ct, b, [SCAN_MAX])\n    i = 1_c_size_t\n    left = count' \
    $'    if (.not. c_associated(cs)) return\n    if (.not. c_associated(ct)) return\n    call c_f_pointer(cs, a, [SCAN_MAX])\n    call c_f_pointer(ct, b, [SCAN_MAX])\n    if (count == 0_c_size_t) then\n       r = ubyte(a(1_c_size_t)) - ubyte(b(1_c_size_t))\n       return\n    end if\n    i = 1_c_size_t\n    left = count'
  run_case M94-strncmp-reads-a-byte-with-count-zero
}

# The test M93 turned out not to be.  With count past the terminator both
# operands run on into unrelated arena bytes, and on the guard page they run
# into the unmapped one.
case_M96() {
  subst src/lib/fk_string.f90 \
    $'       if (c1 == 0_c_int32_t) return\n       i = i + 1_c_size_t\n       left = left - 1_c_size_t\n    end do\n  end function fk_strncmp' \
    $'       i = i + 1_c_size_t\n       left = left - 1_c_size_t\n    end do\n  end function fk_strncmp'
  run_case M96-strncmp-never-stops-at-the-terminator
}

# THE BUG THAT WAS IN THE FILE.  Fortran's c_size_t is a SIGNED int64 and C's
# size_t is unsigned, so a count with the top bit set arrives negative: `<= 0`
# returns 0 without comparing anything while lib/string.c compares to the
# terminator.  Only the (size_t)-1 column in the count table sees it, which is
# why that column exists.
case_M98() {
  subst src/lib/fk_string.f90 \
    $'    if (count == 0_c_size_t) return' \
    $'    if (count <= 0_c_size_t) return'
  subst src/lib/fk_string.f90 \
    $'    do while (left /= 0_c_size_t)' \
    $'    do while (left > 0_c_size_t)'
  run_case M98-strncmp-treats-count-as-signed
}

# THE CASE THE GUARD PAGE EXISTS FOR.  This strlen returns the exactly correct
# length for every input and reads one byte past the terminator on its way out.
# The arena cannot see it -- nothing was written, and the answer is right -- so
# if the page is not there, this is a silent pass.  `peek` is a VOLATILE local
# because an ordinary one would be dead and gfortran would delete the load,
# which would make the mutation a no-op rather than a defect.
case_M97() {
  subst src/lib/fk_string.f90 \
    $'    integer(c_int8_t), pointer :: b(:)\n\n    n = 0_c_size_t\n    if (.not. c_associated(s)) return\n    call c_f_pointer(s, b, [SCAN_MAX])\n    do while (b(n + 1_c_size_t) /= 0_c_int8_t)\n       n = n + 1_c_size_t\n    end do\n  end function fk_strlen' \
    $'    integer(c_int8_t), pointer :: b(:)\n    integer(c_int8_t), volatile :: peek\n\n    n = 0_c_size_t\n    if (.not. c_associated(s)) return\n    call c_f_pointer(s, b, [SCAN_MAX])\n    do while (b(n + 1_c_size_t) /= 0_c_int8_t)\n       n = n + 1_c_size_t\n    end do\n    peek = b(n + 2_c_size_t)\n  end function fk_strlen'
  run_case M97-strlen-reads-one-byte-past-the-terminator
}

# Not a defect in the module: a defect in the HARNESS, restoring the guard that
# keeps strcmp out of the oracle object.  The suite must notice it is diffing
# against glibc rather than against lib/string.c.
case_M95() {
  subst mk/string.mk \
    '-D__HAVE_ARCH_STRNCPY \' \
    '-D__HAVE_ARCH_STRNCPY -D__HAVE_ARCH_STRCMP \'
  run_case M95-oracle-falls-through-to-glibc
}

CASES="baseline M86 M87 M88 M89 M90 M91 M92 M93 M94 M96 M98 M97 M95"

SELECT="$*"
want_case() {
  [ -z "$SELECT" ] && return 0
  case " $SELECT " in *" $1 "*) return 0;; esac
  return 1
}

trap 'restore' EXIT INT TERM
for c in $CASES; do
  want_case "$c" || continue
  restore
  "case_${c}"
done
restore
