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
FILES="src/lib/fk_string.f90 mk/string.mk \
       src/fs/fk_vfs.f90 src/fs/fk_vfs_types.f90"

# REWINDS TO HEAD, NOT TO THE INDEX, and that is a correction rather than a
# preference.  tools/mutate-phase3.sh and -phase45.sh rewind to the index and
# say unstaged edits are the only fatal case; that holds only while nobody
# stages anything DURING a run.  Measured the hard way at roadmap 6.1: a
# `git add -A` in another terminal, with M106 live, put the mutation in the
# index -- and from then on every restore() faithfully restored the DEFECT.
# The baseline hung, the table stopped, and the tree looked clean the whole
# time because the worktree and the index agreed with each other.
#
# Rewinding to HEAD costs one rule -- the files below have to be COMMITTED
# before this runs -- and in exchange no concurrent `git add` can poison it.
restore() { git checkout HEAD -- $FILES 2>/dev/null; }

# A file that is not tracked is not rewound at all, and a file that differs from
# HEAD -- staged or not -- loses that difference on the first restore.  Either
# one turns this script from a measurement into a corruption.
for f in $FILES; do
  git ls-files --error-unmatch "$f" >/dev/null 2>&1 || {
    echo "ABORT: $f is not tracked -- 'git checkout HEAD --' cannot restore it."
    echo "       git add and commit it first."; exit 1; }
done
if ! git diff --quiet HEAD -- $FILES && [ -z "${FK_MUTATE_FORCE:-}" ]; then
  echo "ABORT: the files this script mutates differ from HEAD:"
  git status --short -- $FILES | sed 's/^/       /'
  echo "       commit or stash them; the first restore would discard them."
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
# TARGET is the make goal, so a case rebuilds and runs only the suite it is
# about.  `make test` would also catch a mutation that damaged an unrelated
# translation, which is a finding rather than a nuisance -- but it re-runs bcd's
# four billion checks on every case, and `make audit` is where that belongs.
# THE TIMEOUT IS NOT BELT AND BRACES.  M106 leaves a removed dentry on its
# parent's child list; the slot is then reallocated, the list closes into a
# CYCLE, and vfs_lookup walks it forever.  That is a caught defect, but it
# arrives as a hang rather than a mismatch -- docs/HARNESS-VALIDATION.md's
# first recorded lesson, from the int_pow suite, in a new costume.  Without
# this the table stops at M106 and never reports.
#
# -k gives podman ten seconds to take its container down after the TERM; a
# SIGKILL straight to the client leaves it running.
run_case() {
  local name=$1 target=${2:-test}
  local rc line
  timeout -k 10 300 ./tools/run.sh "$target" >"$OUT/$name.log" 2>&1
  rc=$?
  if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
    echo "$name: suite TIMED OUT (caught -- the defect hangs, it does not"\
         "return a wrong answer)"
    restore
    return
  fi
  line=$(grep -aE "MISMATCH|checks,|Error [0-9]" "$OUT/$name.log" \
         | head -3 | tr -d '\r' | sed 's/^ *//' | paste -sd'|')
  if [ $rc -eq 0 ]; then
    case "$name" in
    baseline*) echo "$name: suite PASSED :: $line";;
    *)         echo "$name: suite PASSED  <-- ESCAPE :: $line";;
    esac
  else                   echo "$name: suite FAILED (caught) :: $line"; fi
  restore
}

# ---- roadmap 1.1: the string half -----------------------------------------

case_baseline() { run_case baseline-string build/run-string; run_case baseline-vfs build/run-vfs; }

case_M86() {
  subst src/lib/fk_string.f90 \
    $'    do while (b(n + 1_c_size_t) /= 0_c_int8_t)' \
    $'    do while (b(n + 1_c_size_t) /= 0_c_int8_t .or. n == 0_c_size_t)'
  run_case M86-strlen-counts-the-terminator build/run-string
}

case_M87() {
  subst src/lib/fk_string.f90 \
    $'       d(i) = s(i)\n       if (s(i) == 0_c_int8_t) return' \
    $'       if (s(i) == 0_c_int8_t) return\n       d(i) = s(i)'
  run_case M87-strcpy-drops-the-terminator build/run-string
}

case_M88() {
  subst src/lib/fk_string.f90 \
    $'       d(i) = s(i)\n       if (s(i) == 0_c_int8_t) return\n       i = i + 1_c_size_t\n    end do\n  end function fk_strcpy' \
    $'       d(i) = s(i)\n       if (s(i) == 0_c_int8_t) then\n          d(i + 1_c_size_t) = 0_c_int8_t\n          return\n       end if\n       i = i + 1_c_size_t\n    end do\n  end function fk_strcpy'
  run_case M88-strcpy-writes-one-past-the-terminator build/run-string
}

# The C standard permits this and lib/string.c does not do it.  If this escapes,
# the suite is testing a weaker contract than the kernel's.
case_M89() {
  subst src/lib/fk_string.f90 \
    $'       if (c1 /= c2) then\n          if (c1 < c2) then\n             r = -1_c_int32_t\n          else\n             r = 1_c_int32_t\n          end if\n          return\n       end if\n       if (c1 == 0_c_int32_t) return\n       i = i + 1_c_size_t\n    end do\n  end function fk_strcmp' \
    $'       if (c1 /= c2) then\n          r = c1 - c2\n          return\n       end if\n       if (c1 == 0_c_int32_t) return\n       i = i + 1_c_size_t\n    end do\n  end function fk_strcmp'
  run_case M89-strcmp-returns-the-difference build/run-string
}

# The 0x80-against-0x00 trap, in strcmp's costume.
case_M90() {
  subst src/lib/fk_string.f90 \
    $'       c1 = ubyte(a(i))\n       c2 = ubyte(b(i))\n       if (c1 /= c2) then\n          if (c1 < c2) then\n             r = -1_c_int32_t\n          else\n             r = 1_c_int32_t\n          end if\n          return\n       end if\n       if (c1 == 0_c_int32_t) return\n       i = i + 1_c_size_t\n    end do\n  end function fk_strcmp' \
    $'       c1 = int(a(i), c_int32_t)\n       c2 = int(b(i), c_int32_t)\n       if (c1 /= c2) then\n          if (c1 < c2) then\n             r = -1_c_int32_t\n          else\n             r = 1_c_int32_t\n          end if\n          return\n       end if\n       if (c1 == 0_c_int32_t) return\n       i = i + 1_c_size_t\n    end do\n  end function fk_strcmp'
  run_case M90-strcmp-compares-signed-bytes build/run-string
}

# Removes the equal-and-terminated exit.  Both strings run off their ends, so
# this is the guard page's case and nothing in the arena can see it.
case_M91() {
  subst src/lib/fk_string.f90 \
    $'       if (c1 == 0_c_int32_t) return\n       i = i + 1_c_size_t\n    end do\n  end function fk_strcmp' \
    $'       i = i + 1_c_size_t\n    end do\n  end function fk_strcmp'
  run_case M91-strcmp-never-stops-at-the-terminator build/run-string
}

case_M92() {
  subst src/lib/fk_string.f90 \
    $'    left = count\n    do while (left /= 0_c_size_t)' \
    $'    left = count\n    do while (.true.)'
  run_case M92-strncmp-ignores-count build/run-string
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
  run_case M93-strncmp-spends-count-before-the-terminator-test build/run-string
}

# count == 0 must read NOTHING, which only the unmapped-page case can say.
case_M94() {
  subst src/lib/fk_string.f90 \
    $'    if (count == 0_c_size_t) return\n    if (.not. c_associated(cs)) return\n    if (.not. c_associated(ct)) return\n    call c_f_pointer(cs, a, [SCAN_MAX])\n    call c_f_pointer(ct, b, [SCAN_MAX])\n    i = 1_c_size_t\n    left = count' \
    $'    if (.not. c_associated(cs)) return\n    if (.not. c_associated(ct)) return\n    call c_f_pointer(cs, a, [SCAN_MAX])\n    call c_f_pointer(ct, b, [SCAN_MAX])\n    if (count == 0_c_size_t) then\n       r = ubyte(a(1_c_size_t)) - ubyte(b(1_c_size_t))\n       return\n    end if\n    i = 1_c_size_t\n    left = count'
  run_case M94-strncmp-reads-a-byte-with-count-zero build/run-string
}

# The test M93 turned out not to be.  With count past the terminator both
# operands run on into unrelated arena bytes, and on the guard page they run
# into the unmapped one.
case_M96() {
  subst src/lib/fk_string.f90 \
    $'       if (c1 == 0_c_int32_t) return\n       i = i + 1_c_size_t\n       left = left - 1_c_size_t\n    end do\n  end function fk_strncmp' \
    $'       i = i + 1_c_size_t\n       left = left - 1_c_size_t\n    end do\n  end function fk_strncmp'
  run_case M96-strncmp-never-stops-at-the-terminator build/run-string
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
  run_case M98-strncmp-treats-count-as-signed build/run-string
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
  run_case M97-strlen-reads-one-byte-past-the-terminator build/run-string
}

# Not a defect in the module: a defect in the HARNESS, restoring the guard that
# keeps strcmp out of the oracle object.  The suite must notice it is diffing
# against glibc rather than against lib/string.c.
case_M95() {
  subst mk/string.mk \
    '-D__HAVE_ARCH_STRNCPY \' \
    '-D__HAVE_ARCH_STRNCPY -D__HAVE_ARCH_STRCMP \'
  run_case M95-oracle-falls-through-to-glibc build/run-string
}

# ---- roadmap 6.1: the VFS -------------------------------------------------

# dcache.h:31, IS_ROOT is `(x) == (x)->d_parent`, and it is the only thing
# stopping ".." at the root from walking off the tree.
case_M99() {
  subst src/fs/fk_vfs.f90 \
    $'    dentries(d)%d_parent = d\n    dentries(d)%d_inode = i' \
    $'    dentries(d)%d_parent = FK_VFS_NONE\n    dentries(d)%d_inode = i'
  run_case M99-root-parent-is-not-itself build/run-vfs
}

# namei.c:2635-2637 skips a RUN of separators, not one.  "//bin//" is the case.
case_M100() {
  subst src/fs/fk_vfs.f90 \
    $'       trailing = .false.\n       do\n          if (i > n) exit\n          if (p(i) /= SLASH) exit\n          i = i + 1_c_size_t\n          trailing = .true.\n       end do' \
    $'       trailing = .false.\n       if (i <= n) then\n          if (p(i) == SLASH) then\n             i = i + 1_c_size_t\n             trailing = .true.\n          end if\n       end if'
  run_case M100-only-one-separator-skipped build/run-vfs
}

# The trailing slash is the whole of -ENOTDIR on /bin/init/, and it is the one
# fact tokenisation is most tempted to throw away.
case_M101() {
  subst src/fs/fk_vfs.f90 \
    $'          i = i + 1_c_size_t\n          trailing = .true.\n       end do' \
    $'          i = i + 1_c_size_t\n       end do'
  run_case M101-trailing-slash-forgotten build/run-vfs
}

# namei.c:2662-2667 on the RESULT of a non-final component.  Without it,
# /file/.. answers the root instead of -ENOTDIR.
case_M102() {
  subst src/fs/fk_vfs.f90 \
    $'       if (vfs_is_dir(cur) == 0_c_int32_t) then\n          d = -FK_E_NOTDIR\n          return\n       end if\n    end do\n\n    d = cur' \
    $'    end do\n\n    d = cur'
  run_case M102-walks-through-a-non-directory build/run-vfs
}

# dentry_cmp compares (length, bytes).  Dropping the length makes a prefix a
# match, so /READM finds README.
case_M103() {
  subst src/fs/fk_vfs.f90 \
    $'       if (dentries(c)%d_len == len) then' \
    $'       if (dentries(c)%d_len >= len) then'
  run_case M103-name-compare-ignores-the-length build/run-vfs
}

case_M104() {
  subst src/fs/fk_vfs.f90 \
    $'       if (clen > int(FK_VFS_NAME_MAX, c_size_t)) then' \
    $'       if (clen >= int(FK_VFS_NAME_MAX, c_size_t)) then'
  run_case M104-name-max-is-off-by-one build/run-vfs
}

# The pool is a linear scan over d_flags, so not clearing it is a leak that
# only the exhaust-free-realloc sequence can see.
case_M105() {
  subst src/fs/fk_vfs.f90 \
    $'    dentries(d)%d_flags = FK_VFS_NONE\n    dentries(d)%d_inode = FK_VFS_NONE' \
    $'    dentries(d)%d_inode = FK_VFS_NONE'
  run_case M105-remove-does-not-free-the-dentry build/run-vfs
}

case_M106() {
  subst src/fs/fk_vfs.f90 \
    $'    i = dentries(d)%d_inode\n    call unlink_child(p, d)' \
    $'    i = dentries(d)%d_inode'
  run_case M106-remove-leaves-the-dentry-on-its-parents-list build/run-vfs
}

case_M107() {
  subst src/fs/fk_vfs.f90 \
    $'          if (inode_ok(dentries(p)%d_inode)) then\n             inodes(dentries(p)%d_inode)%i_nlink = &\n                  inodes(dentries(p)%d_inode)%i_nlink - 1_c_int32_t\n          end if' \
    $'          if (.false.) continue'
  run_case M107-remove-does-not-drop-the-parents-link build/run-vfs
}

case_M108() {
  subst src/fs/fk_vfs.f90 \
    $'    if (vfs_is_dir(d) == 1_c_int32_t .and. &\n        iand(flags, FK_O_ACCMODE) /= FK_O_RDONLY) then' \
    $'    if (.false.) then'
  run_case M108-a-directory-can-be-opened-for-write build/run-vfs
}

# The layout channel, and nothing else, sees this: a field inserted into the
# middle of the struct while every accessor still compiles and every behaviour
# test still passes.
case_M109() {
  subst src/fs/fk_vfs_types.f90 \
    $'    integer(c_int64_t) :: i_ino\n    integer(c_int64_t) :: i_size' \
    $'    integer(c_int64_t) :: i_ino\n    integer(c_int64_t) :: i_spare\n    integer(c_int64_t) :: i_size'
  run_case M109-an-inode-field-moves build/run-vfs
}

CASES="baseline M86 M87 M88 M89 M90 M91 M92 M93 M94 M96 M98 M97 M95 \
       M99 M100 M101 M102 M103 M104 M105 M106 M107 M108 M109"

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
