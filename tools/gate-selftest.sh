#!/usr/bin/env bash
# Proves the quality gates actually reject what they claim to reject.
#
# The Phase 1 audit found three gates that reported PASS on inputs they were
# supposed to fail (docs/AUDIT-PHASE1.md, A-1 and A-2). The root cause was that
# nobody had ever watched them fail. This script is the fix for that class of
# defect: every gate is fed a file that violates it and must reject it, and is
# fed the real sources and must accept them.
#
# Run it in the container:  ./tools/run.sh -f /dev/null  # (or directly)
#   podman run --rm -v "$PWD:/work:Z" -w /work fortran-kernel-dev:f44 \
#       bash tools/gate-selftest.sh
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

ok()   { printf "  \033[32mPASS\033[0m  %s\n" "$1"; pass=$((pass+1)); }
bad()  { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; fail=$((fail+1)); }

# expect_reject <name> <gate-script> <heredoc-file>
expect_reject() {
  local name=$1 gate=$2 dir=$3
  if bash "$REPO/$gate" "$dir" >/dev/null 2>&1; then
    bad "$gate should have REJECTED: $name"
  else
    ok "$gate rejects $name"
  fi
}

mkcase() {  # mkcase <dirname>  -- reads module source on stdin
  local d="$WORK/$1"; mkdir -p "$d"; cat > "$d/fk_case.f90"; echo "$d"
}

echo "=== compliance.sh: each mandatory rule rejects a violating module ==="

d=$(mkcase c_implicit <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: fk_case
contains
  function fk_case(x) result(r) bind(c, name="fk_case")
    integer(c_int32_t), intent(in), value :: x
    integer(c_int32_t) :: r
    r = x
  end function fk_case
end module fk_case_m
F90
)
expect_reject "contained procedure with no implicit none" tools/compliance.sh "$d"

d=$(mkcase c_goto <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: fk_case
contains
  function fk_case(x) result(r) bind(c, name="fk_case")
    implicit none
    integer(c_int32_t), intent(in), value :: x
    integer(c_int32_t) :: r
    if (x > 0) go to 100
    r = 0
    return
100 r = x
  end function fk_case
end module fk_case_m
F90
)
expect_reject "inline GOTO (not at column 1)" tools/compliance.sh "$d"

d=$(mkcase c_common <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: fk_case
contains
  function fk_case(x) result(r) bind(c, name="fk_case")
    implicit none
    integer(c_int32_t), intent(in), value :: x
    integer(c_int32_t) :: r
    integer :: shared
    common shared
    r = x
  end function fk_case
end module fk_case_m
F90
)
expect_reject "blank COMMON (no slash)" tools/compliance.sh "$d"

d=$(mkcase c_equiv <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: fk_case
contains
  function fk_case(x) result(r) bind(c, name="fk_case")
    implicit none
    integer(c_int32_t), intent(in), value :: x
    integer(c_int32_t) :: r
    integer :: a, b
    equivalence (a, b)
    r = x
  end function fk_case
end module fk_case_m
F90
)
expect_reject "EQUIVALENCE" tools/compliance.sh "$d"

d=$(mkcase c_bindc_comment <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: fk_case
contains
  !> this one is bind(c) -- but only in this comment
  function fk_case(x) result(r)
    implicit none
    integer(c_int32_t), intent(in), value :: x
    integer(c_int32_t) :: r
    r = x
  end function fk_case
end module fk_case_m
F90
)
expect_reject "public procedure whose bind(c) is only in a comment" tools/compliance.sh "$d"

d=$(mkcase c_bare_use <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: fk_case
contains
  function fk_case(x) result(r) bind(c, name="fk_case")
    implicit none
    integer(c_int32_t), intent(in), value :: x
    integer(c_int32_t) :: r
    r = x
  end function fk_case
end module fk_case_m
F90
)
expect_reject "bare use iso_c_binding (not intrinsic)" tools/compliance.sh "$d"

d=$(mkcase c_nospdx <<'F90'
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: fk_case
contains
  function fk_case(x) result(r) bind(c, name="fk_case")
    implicit none
    integer(c_int32_t), intent(in), value :: x
    integer(c_int32_t) :: r
    r = x
  end function fk_case
end module fk_case_m
F90
)
expect_reject "missing SPDX identifier" tools/compliance.sh "$d"

echo
echo "=== compliance.sh sees past line continuations (Phase 2 regression) ==="

# Fortran statements continue across lines; the gate used to read one line at a
# time. Both cases below reported PASS before fold_continuations existed. The
# first is the dangerous one: a public procedure hidden on a continuation line
# was never checked for bind(c) at all.
d=$(mkcase c_cont_public <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: fk_case, &
            fk_hidden
contains
  function fk_case(x) result(r) bind(c, name="fk_case")
    implicit none
    integer(c_int32_t), intent(in), value :: x
    integer(c_int32_t) :: r
    r = x
  end function fk_case
  function fk_hidden(x) result(r)
    implicit none
    integer(c_int32_t), intent(in), value :: x
    integer(c_int32_t) :: r
    r = x
  end function fk_hidden
end module fk_case_m
F90
)
expect_reject "public procedure hidden on a 'public ::' continuation line" tools/compliance.sh "$d"

d=$(mkcase c_cont_goto <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: fk_case
contains
  function fk_case(x) result(r) bind(c, name="fk_case")
    implicit none
    integer(c_int32_t), intent(in), value :: x
    integer(c_int32_t) :: r
    r = 0
    if (x > 0 .and. &
        x < 99) go to 100
    return
100 r = x
  end function fk_case
end module fk_case_m
F90
)
expect_reject "banned construct reachable only after folding a continuation" tools/compliance.sh "$d"

# The mirror image: a correctly bound export whose bind(c) sits on a
# continuation line must still be ACCEPTED. Folding that only ever adds
# rejections would be its own defect -- it would make the gate unusable for the
# multi-line signatures the GOP renderer needs.
d=$(mkcase c_cont_ok <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: fk_case, &
            fk_case2
contains
  function fk_case(x, y) &
       result(r) bind(c, name="fk_case")
    implicit none
    integer(c_int32_t), intent(in), value :: x, y
    integer(c_int32_t) :: r
    r = x + y
  end function fk_case
  function fk_case2(x) result(r) bind(c, name="fk_case2")
    implicit none
    integer(c_int32_t), intent(in), value :: x
    integer(c_int32_t) :: r
    r = x
  end function fk_case2
end module fk_case_m
F90
)
if bash "$REPO/tools/compliance.sh" "$d" >/dev/null 2>&1; then
  ok "compliance.sh accepts bind(c) split across a continuation line"
else
  bad "compliance.sh rejects a correctly bound multi-line signature"
fi

echo
echo "=== linktest.sh: freestanding gates reject a runtime-dependent module ==="

d=$(mkcase l_libgfortran <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: fk_case
contains
  subroutine fk_case(x) bind(c, name="fk_case")
    implicit none
    integer(c_int32_t), intent(in), value :: x
    print *, "this needs the libgfortran runtime", x
  end subroutine fk_case
end module fk_case_m
F90
)
expect_reject "module that calls into libgfortran (print *)" tools/linktest.sh "$d"

echo
echo "=== FP/vector detector fires on an object that really contains SSE ==="
cat > "$WORK/fp.f90" <<'F90'
subroutine fpwork(a, b, n) bind(c, name="fpwork")
  use, intrinsic :: iso_c_binding, only: c_double, c_int32_t
  implicit none
  integer(c_int32_t), intent(in), value :: n
  real(c_double), intent(inout) :: a(n)
  real(c_double), intent(in)    :: b(n)
  integer :: i
  do i = 1, n
     a(i) = a(i) * b(i) + 1.0_c_double
  end do
end subroutine fpwork
F90
# built WITHOUT -mno-sse on purpose: proves the detector sees FP when present
gfortran -O2 -J"$WORK" -c -o "$WORK/fp.o" "$WORK/fp.f90" 2>/dev/null
hits=$(objdump -d "$WORK/fp.o" | grep -oE '%(x|y|z)mm[0-9]+|%mm[0-7]|[[:space:]]f(ld|st|add|mul|div|sub)[a-z]*[[:space:]]' | sort -u | wc -l)
if [ "$hits" -gt 0 ]; then ok "FP detector finds $hits distinct FP/vector operand(s)"
else bad "FP detector saw nothing in an object built with SSE enabled"; fi

echo
echo "=== both gates ACCEPT the real sources (no false positives) ==="
if bash "$REPO/tools/compliance.sh" "$REPO/src" >/dev/null 2>&1; then
  ok "compliance.sh accepts src/"; else bad "compliance.sh rejects the real src/"; fi
if bash "$REPO/tools/linktest.sh" "$REPO/src" >/dev/null 2>&1; then
  ok "linktest.sh accepts src/"; else bad "linktest.sh rejects the real src/"; fi

echo
echo "=== $pass passed, $fail failed ==="
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
