# Fold Fortran free-form line continuations into one logical line each.
#
# Used by tools/compliance.sh, which is otherwise line-based while Fortran is
# not. Kept in its own file rather than inlined: the program needs both single
# and double quotes, and embedding it in a shell function is how the first
# attempt at this silently produced "awk: unterminated string" on every module
# while the gate still printed a table and exited 0.
#
# Three things a continued statement can do, all of which hid something real:
#
#   public :: a, b, &        the gate saw only a and b -- c was never checked
#             c              for bind(c) at all.
#
#   function f(x) &          the gate saw a first line with no bind(c) and
#        result(r) bind(c)   reported MISSING on a correctly bound export.
#
#   public :: a, &           a COMMENT is legal between continuation lines.
#   ! explanation            Comments are stripped before folding, so this
#             b              arrives as a BLANK line; joining the blank ends
#                            the fold early and b escapes again.
#
# The third is why blank lines are skipped while a fold is open.
{
    line = $0
    sub(/[ \t]+$/, "", line)

    # A blank line inside an open continuation is a stripped comment (or a
    # legal blank continuation line). Skip it and keep folding.
    if (buf != "" && line ~ /^[ \t]*$/)
        next

    if (buf != "") {
        sub(/^[ \t]*&/, "", line)   # optional leading '&' on the continued line
        line = buf " " line
        buf = ""
    }

    if (line ~ /&$/) {
        sub(/&[ \t]*$/, "", line)
        buf = line
        next
    }

    print line
}
END { if (buf != "") print buf }
