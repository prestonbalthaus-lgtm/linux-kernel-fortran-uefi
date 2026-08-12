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

# Check 6 (free-form layout) was the one mandatory rule with no fixture -- the
# only gate in the file nobody had ever watched fail. The continuation line
# below carries exactly five leading spaces, i.e. fixed-form's continuation
# column; everything else in the module is compliant, so this discriminates on
# check 6 alone.
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

# The bind(c) rule exempts public PARAMETERs (a named constant has no symbol
# and no ABI -- see the rule's comment in compliance.sh). These two cases fix
# the boundary of that exemption in place: a public constant is fine, a public
# module VARIABLE is not. Without the second case, "it's not a procedure" would
# have quietly become a way to export unbound data.
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

# Until roadmap 2.1 the gate stripped comments with `sed 's/!.*//'`, justified
# by a comment saying no translated module contained a character literal. The
# serial driver and the kernel banner ended that precondition, and
# tools/strip-comments.awk replaced the sed. The five fixtures below pin down
# BOTH halves of that replacement: it must stop reading string text as code
# (the three acceptances), and it must not start reading code as text (the two
# rejections). Every one of them was run against the OLD sed before being
# written down, and the verdict quoted in each comment is what that run printed.

# MUST ACCEPT. FK_PROMPT and FK_BANNER share one declaration, with a '!' inside
# FK_PROMPT's text. The old sed cut the line at that '!', so FK_BANNER was
# never seen as declared anywhere and check 3's public-PARAMETER exemption
# could not fire: the old gate exited 1 with `-> unbound: FK_BANNER`, a false
# positive about a public constant that has no ABI and never needed bind(c).
# MSG is the plain shape 2.1 actually introduces -- a banner with a '!' in it.
# On its own the old sed tolerated MSG, because the text it destroyed was text
# no check reads; the two-constant declaration is the half that discriminates.
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

# MUST ACCEPT. Check 2 greps the whole line for `go to`, and a banner that
# tells the operator where to look contains those exact two words. The old gate
# exited 1 with `-> banned-construct` on a module with no GOTO in it. The fix
# is not a smarter regex -- it is that literal CONTENTS are blanked before any
# check sees the line, so there is no banner text left to match.
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

# MUST ACCEPT. `""` inside a "..." literal is how Fortran writes a quote, and
# getting it wrong is not cosmetic: a scanner that treats the first of the pair
# as the CLOSING delimiter re-opens the literal on the second and has the
# polarity inverted for the rest of the line. The trailing '!' then looks like
# it is outside a literal, the line is cut there, and FK_TAIL disappears
# exactly as in c_lit_bang. FK_TAIL is public so that failure is visible rather
# than silent; under the old sed this file exited 1 with `-> unbound: FK_TAIL`.
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

# MUST STILL REJECT, and this is the case that matters most. A real inline
# `go to` follows a character literal on the same line, and the literal happens
# to be the '!' character. The OLD gate ACCEPTED this file -- exit 0 -- because
# the cut landed inside the literal and took the `go to` with it: a banned
# construct rendered invisible by a string earlier on the line, which is a
# false NEGATIVE and strictly worse than the noise the other fixtures describe.
# It is also the proof that blanking literal contents did not turn into
# blanking code: everything outside the delimiters must survive intact.
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

# MUST STILL REJECT. The bind(c) rule is the one a quote-aware pass could most
# easily make lenient by accident -- blank too much and every export starts
# looking bound. fk_unbound is a public procedure with no bind(c) at all, in a
# file that also carries a '!'-bearing literal so the new pass is genuinely
# exercised on it. The old gate rejected this correctly (`-> unbound:
# fk_unbound`) and the new one must keep doing so for the same reason.
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

# MUST REJECT -- and this is the fixture that pays for the quote-aware pass.
#
# A Fortran character literal may be CONTINUED across lines with '&'.
# tools/strip-comments.awk resets quote state at end of line, so on the
# continuation line the CLOSING quote reads as an OPENING one and everything
# after it is blanked as if it were string content. The real `go to` below is
# inside that blanked tail.
#
# This is a FALSE NEGATIVE the sed it replaced did not have: `sed 's/!.*//'`
# left the whole second line alone and the banned-construct grep matched it.
# Fixing two false positives had therefore quietly bought one false negative, in
# the gate whose entire job is to make "NO go to anywhere" true -- docs/AUDIT-
# PHASE1.md A-1 all over again, from the other direction.
#
# The stripper now REFUSES a line that ends inside a literal (exit 2) instead of
# guessing, and compliance.sh turns that into a named failure. So this module is
# rejected -- not because the gate understood the GOTO, but because the gate
# declined to certify source it cannot read. That distinction is the point, and
# it is why the case belongs here rather than in the "reads literals as text"
# group above: those five prove the stripper is RIGHT, this one proves it knows
# when it is not.
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

# linktest's undefined-symbol rule was relaxed from "zero undefined symbols" to
# "every undefined symbol is defined elsewhere in this tree" when roadmap 1.2
# introduced fk_kmain -> fk_cpu_halt (assembly) and fk_gop_renderer ->
# vga_font_row (the font module). This case is the proof that the relaxation
# did not turn into "any undefined symbol is fine": nothing in the tree defines
# fk_no_such_primitive, so it must still be rejected. Without it, a typo in an
# interface block would link cleanly in the gate and fail at kernel link time.
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


# linktest.sh PASS 0 assembles every boot/*.S to build the set of symbols "this
# tree defines". Roadmap 2.1 turned that from a hardcoded boot/boot.S into a
# glob, and added an arm that FAILS the run when one of them does not assemble.
# That arm replaced a `2>/dev/null && objs=...` which swallowed the error --
# and a swallowed error is not quiet, it is LOUD IN THE WRONG PLACE: every
# symbol the broken object defines vanishes from PROVIDED, so the visible
# symptom is a list of modules accused of calling things "nothing in this tree
# defines", none of which is the file that is actually broken.
#
# Nothing could watch that arm fire, because the script cd's to the repo root
# and the repo's own two .S files both assemble. FK_BOOTDIR exists so this case
# can exist; without it the branch would be exactly the untested gate that
# docs/AUDIT-PHASE1.md A-1/A-2 are about.
echo
echo "=== linktest.sh: a boot/*.S that does not assemble fails the run (2.1) ==="
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
# The mirror image: pointing FK_BOOTDIR at a directory with no .S at all must
# stay a quiet no-op, not an error. The [ -e ] unmatched-glob guard is what makes
# that true, and the synthetic single-module cases above depend on it.
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
