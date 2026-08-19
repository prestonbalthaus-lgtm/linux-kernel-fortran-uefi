#!/usr/bin/env bash
# Feeds every gate a file that violates it and must be rejected, plus the real
# sources that must be accepted.
# Run in the container:
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

# Both fixtures below are only reachable after continuations are folded.
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

d=$(mkcase c_cont_comment <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: fk_case, &
  ! a comment is legal between continuation lines, and comments are stripped
  ! BEFORE folding, so this reaches the folder as a blank line
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
expect_reject "public procedure hidden past a COMMENT inside a continuation" tools/compliance.sh "$d"

# The continuation line has exactly five leading spaces: fixed-form's column 6.
d=$(mkcase c_fixedform <<'F90'
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
    r = x + &
     0
  end function fk_case
end module fk_case_m
F90
)
expect_reject "fixed-form layout (non-blank in continuation column 6)" tools/compliance.sh "$d"

# Folding must not add rejections: a bind(c) split across lines stays accepted.
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

# The bind(c) rule exempts public PARAMETERs; these two cases fix that boundary.
d=$(mkcase c_param_ok <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: FK_WIDTH, fk_case
  integer(c_int32_t), parameter :: FK_WIDTH = 8_c_int32_t
contains
  function fk_case(x) result(r) bind(c, name="fk_case")
    implicit none
    integer(c_int32_t), intent(in), value :: x
    integer(c_int32_t) :: r
    r = x * FK_WIDTH
  end function fk_case
end module fk_case_m
F90
)
if bash "$REPO/tools/compliance.sh" "$d" >/dev/null 2>&1; then
  ok "compliance.sh accepts a public PARAMETER with no bind(c)"
else
  bad "compliance.sh rejects a public PARAMETER -- a named constant has no ABI"
fi

d=$(mkcase c_pubvar <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: fk_counter, fk_case
  integer(c_int32_t) :: fk_counter = 0_c_int32_t
contains
  subroutine fk_case(x) bind(c, name="fk_case")
    implicit none
    integer(c_int32_t), intent(in), value :: x
    fk_counter = x
  end subroutine fk_case
end module fk_case_m
F90
)
expect_reject "public module VARIABLE exported without bind(c)" tools/compliance.sh "$d"

echo
echo "=== compliance.sh reads character literals as text, not as code (2.1) ==="


# The '!' inside FK_PROMPT must not hide the FK_BANNER declared after it.
d=$(mkcase c_lit_bang <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_char, c_int32_t
  implicit none
  private
  public :: FK_BANNER, fk_case
  character(kind=c_char, len=*), parameter :: MSG = "hi! there"
  character(kind=c_char, len=*), parameter :: FK_PROMPT = "ready! ", FK_BANNER = "fk"
contains
  function fk_case(x) result(r) bind(c, name="fk_case")
    implicit none
    integer(c_int32_t), intent(in), value :: x
    integer(c_int32_t) :: r
    r = x + len(MSG) + len(FK_PROMPT) + len(FK_BANNER)
  end function fk_case
end module fk_case_m
F90
)
if bash "$REPO/tools/compliance.sh" "$d" >/dev/null 2>&1; then
  ok "compliance.sh accepts a '!' inside banner text"
else
  bad "compliance.sh treats a '!' inside a character literal as a comment"
fi

d=$(mkcase c_lit_goto_text <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_char, c_int32_t
  implicit none
  private
  public :: fk_case
  character(kind=c_char, len=*), parameter :: MSG = "go to the console"
contains
  function fk_case(x) result(r) bind(c, name="fk_case")
    implicit none
    integer(c_int32_t), intent(in), value :: x
    integer(c_int32_t) :: r
    r = x + len(MSG)
  end function fk_case
end module fk_case_m
F90
)
if bash "$REPO/tools/compliance.sh" "$d" >/dev/null 2>&1; then
  ok "compliance.sh accepts the words 'go to' inside banner text"
else
  bad "compliance.sh reads 'go to' in a character literal as a banned construct"
fi

# "" is Fortran's escaped quote: mis-reading it inverts quote state for the line.
d=$(mkcase c_lit_dquote <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_char, c_int32_t
  implicit none
  private
  public :: FK_TAIL, fk_case
  character(kind=c_char, len=*), parameter :: FK_QUOTED = "say ""hi""! now", FK_TAIL = "."
contains
  function fk_case(x) result(r) bind(c, name="fk_case")
    implicit none
    integer(c_int32_t), intent(in), value :: x
    integer(c_int32_t) :: r
    r = x + len(FK_QUOTED) + len(FK_TAIL)
  end function fk_case
end module fk_case_m
F90
)
if bash "$REPO/tools/compliance.sh" "$d" >/dev/null 2>&1; then
  ok "compliance.sh accepts a doubled quote inside a literal"
else
  bad "compliance.sh mis-tracks Fortran's doubled-delimiter escape"
fi

d=$(mkcase c_lit_real_goto <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_char, c_int32_t
  implicit none
  private
  public :: fk_case
contains
  function fk_case(c) result(r) bind(c, name="fk_case")
    implicit none
    character(kind=c_char), intent(in), value :: c
    integer(c_int32_t) :: r
    if (iachar(c) == iachar("!")) go to 100
    r = 0_c_int32_t
    return
100 r = 1_c_int32_t
  end function fk_case
end module fk_case_m
F90
)
expect_reject "inline GOTO hidden behind a character literal on the same line" tools/compliance.sh "$d"

d=$(mkcase c_lit_unbound <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_char, c_int32_t
  implicit none
  private
  public :: fk_case, fk_unbound
  character(kind=c_char, len=*), parameter :: MSG = "boot! ok"
contains
  function fk_case(x) result(r) bind(c, name="fk_case")
    implicit none
    integer(c_int32_t), intent(in), value :: x
    integer(c_int32_t) :: r
    r = x + len(MSG)
  end function fk_case
  function fk_unbound(x) result(r)
    implicit none
    integer(c_int32_t), intent(in), value :: x
    integer(c_int32_t) :: r
    r = x
  end function fk_unbound
end module fk_case_m
F90
)
expect_reject "public procedure with no bind(c) in a file containing literals" tools/compliance.sh "$d"

# Rejected because the stripper refuses (exit 2) a line that ends inside a literal.
d=$(mkcase c_cont_literal <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_int32_t, c_char
  implicit none
  private
  public :: fk_case
contains
  function fk_case(x) result(r) bind(c, name="fk_case")
    implicit none
    integer(c_int32_t), intent(in), value :: x
    integer(c_int32_t) :: r
    character(kind=c_char, len=11) :: msg
    r = 0
    msg = "hello &
         &world" ; if (x > 0) go to 100
    return
100 r = x
  end function fk_case
end module fk_case_m
F90
)
expect_reject "GOTO hidden past a line-CONTINUED character literal" tools/compliance.sh "$d"

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

# Undefined symbols are tolerated only when something else in the tree defines them.
d=$(mkcase l_orphan <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: fk_case
  interface
    subroutine fk_no_such_primitive() bind(c, name="fk_no_such_primitive")
      implicit none
    end subroutine fk_no_such_primitive
  end interface
contains
  subroutine fk_case(x) bind(c, name="fk_case")
    implicit none
    integer(c_int32_t), intent(in), value :: x
    if (x > 0_c_int32_t) call fk_no_such_primitive()
  end subroutine fk_case
end module fk_case_m
F90
)
expect_reject "call to an external nothing in the tree defines" tools/linktest.sh "$d"

# roadmap 5.2.  A module of nothing but PARAMETERs compiles to an object with
# no symbols at all -- every constant is folded at the use site -- so linktest
# exempts it from needing an entry point.  BOTH HALVES OF THAT EXEMPTION ARE
# TESTED HERE, because an exemption nothing has watched refuse is a hole:
# constants-only is accepted, and no-text-but-undefined is still rejected.
d=$(mkcase l_constants <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: FK_CASE_ONE
  integer(c_int32_t), parameter :: FK_CASE_ONE = 1_c_int32_t
end module fk_case_m
F90
)
if bash "$REPO/tools/linktest.sh" "$d" >/dev/null 2>&1; then
  ok "linktest.sh accepts a module that is nothing but parameters"
else
  bad "linktest.sh rejects a parameters-only module (nothing to link is not a failure)"
fi

d=$(mkcase l_no_text_undef <<'F90'
! SPDX-License-Identifier: GPL-2.0
module fk_case_m
  use, intrinsic :: iso_c_binding, only: c_int32_t
  implicit none
  private
  public :: fk_case_ptr
  interface
    subroutine fk_no_such_primitive() bind(c, name="fk_no_such_primitive")
      implicit none
    end subroutine fk_no_such_primitive
  end interface
  procedure(fk_no_such_primitive), pointer :: fk_case_ptr => fk_no_such_primitive
end module fk_case_m
F90
)
expect_reject "an object with no text but an undefined symbol -- the exemption does NOT cover it" tools/linktest.sh "$d"

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
# No -mno-sse here: the object must really contain FP for the detector to find.
gfortran -O2 -J"$WORK" -c -o "$WORK/fp.o" "$WORK/fp.f90" 2>/dev/null
hits=$(objdump -d "$WORK/fp.o" | grep -oE '%(x|y|z)mm[0-9]+|%mm[0-7]|[[:space:]]f(ld|st|add|mul|div|sub)[a-z]*[[:space:]]' | sort -u | wc -l)
if [ "$hits" -gt 0 ]; then ok "FP detector finds $hits distinct FP/vector operand(s)"
else bad "FP detector saw nothing in an object built with SSE enabled"; fi


echo
echo "=== linktest.sh: a boot/*.S that does not assemble fails the run (2.1) ==="
# The repo's own boot/*.S all assemble, so FK_BOOTDIR is the only way to test this.
bad_boot="$WORK/bootdir_broken"
mkdir -p "$bad_boot"
cat > "$bad_boot/broken.S" <<'ASM'
	.text
	.globl fk_bogus
fk_bogus:
	this_is_not_an_x86_instruction %rax, %rbx
	ret
ASM
if FK_BOOTDIR="$bad_boot" bash "$REPO/tools/linktest.sh" "$REPO/src" >/dev/null 2>&1; then
  bad "linktest.sh passed with a boot/*.S that does not assemble"
else
  ok "linktest.sh rejects a boot/*.S that does not assemble"
fi
# An unmatched *.S glob must stay a quiet no-op; the cases above depend on it.
empty_boot="$WORK/bootdir_empty"
empty_src="$WORK/srcdir_empty"
mkdir -p "$empty_boot" "$empty_src"
if FK_BOOTDIR="$empty_boot" bash "$REPO/tools/linktest.sh" "$empty_src" >/dev/null 2>&1; then
  ok "linktest.sh tolerates a boot directory with no assembly in it"
else
  bad "linktest.sh errors on an empty boot directory (unmatched glob leaked)"
fi

echo
echo "=== both gates ACCEPT the real sources (no false positives) ==="
if bash "$REPO/tools/compliance.sh" "$REPO/src" >/dev/null 2>&1; then
  ok "compliance.sh accepts src/"; else bad "compliance.sh rejects the real src/"; fi
if bash "$REPO/tools/linktest.sh" "$REPO/src" >/dev/null 2>&1; then
  ok "linktest.sh accepts src/"; else bad "linktest.sh rejects the real src/"; fi

echo
echo "=== $pass passed, $fail failed ==="
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
