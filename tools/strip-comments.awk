# Strip Fortran comments, quote-aware, and blank out character-literal CONTENTS.
#
# Used by tools/compliance.sh, which greps line-oriented patterns for things
# that Fortran only guarantees at the STATEMENT level. Kept in its own file for
# the same reason tools/fold-continuations.awk is: the program has to name both
# the single and the double quote character, and every attempt to carry that
# inside a shell function ends as `awk: unterminated string` -- which awk
# reports on stderr while the gate still prints a table and exits 0. A gate
# that fails open is worse than no gate.
#
# WHAT THIS REPLACES. Until roadmap 2.1 this was one sed substitution,
# `sed 's/!.*//'`, justified by a comment saying that no translated module
# contained a character literal, so cutting at the first '!' was exact. That
# was true of pure integer code. It stopped being true the moment a driver
# needed a banner string. Three concrete failures, all reproduced against the
# old sed before this file was written:
#
#   character(...), parameter :: FK_PROMPT = "ready! ", FK_BANNER = "fk"
#       Everything from the '!' on is deleted, so FK_BANNER never appears to be
#       declared anywhere. compliance.sh check 3 then prints
#       `-> unbound: FK_BANNER` about a public PARAMETER its own rule exempts.
#       A FALSE POSITIVE on correct source: the failure mode that teaches
#       people to stop reading the gate's output.
#
#   character(...), parameter :: MSG = "go to the console"
#       check 2 greps for banned legacy constructs anywhere on the line and
#       cannot tell banner TEXT from code: `-> banned-construct` on a module
#       with no GOTO in it. Also a false positive.
#
#   if (iachar(c) == iachar("!")) go to 100
#       The mirror image, and the dangerous one: the cut lands INSIDE the
#       literal, so the real `go to` after it is deleted and the old gate
#       accepted this file with exit 0. A FALSE NEGATIVE -- a banned construct
#       that a character literal earlier on the line made invisible.
#
# WHAT THIS DOES INSTEAD. Walk the line one character at a time, tracking
# whether we are inside a single- or double-quoted literal:
#
#   * '!' begins a comment ONLY outside a literal. There we truncate.
#   * Inside a literal every character, '!' included, is replaced by a space,
#     while the opening and closing delimiters are KEPT. Downstream still sees
#     a syntactically whole statement -- `name="fk_case"` survives as
#     `name="       "`, balanced quotes and all -- but no grep can ever read
#     string text as code. That is what fixes the first two cases above.
#   * A doubled delimiter is how Fortran writes a quote inside a literal
#     ('' within '...', "" within "..."). Both characters are content: consume
#     the pair and emit two spaces. Treating the first of them as the closing
#     delimiter would re-open the literal on the second and invert the state
#     for the rest of the line, which puts a trailing '!' back "outside" and
#     deletes the remainder of the declaration.
#   * Blanking is length-preserving (one space per consumed character) so that
#     nothing downstream that reasons about columns is disturbed. Nothing does
#     today; compliance.sh check 6 reads the RAW file precisely because
#     fixed-form layout is a property of the source, not of the stripped copy.
#
# A SIDE EFFECT WORTH NAMING. The old sed also deleted any trailing '&' that
# followed a '!'-bearing literal, so a continued statement silently stopped
# being continued and tools/fold-continuations.awk never joined it. Blanking
# keeps the '&', so those folds now happen. That is a fix, not a regression,
# but it means a statement that the gate used to see as two lines it may now
# see as one.
#
# THE ONE INPUT THIS CANNOT ANALYSE, AND WHY IT FAILS CLOSED.
#
# Quote state is reset at end of line, so a character literal CONTINUED across
# lines with '&' is mis-tracked. The first draft of this file merely noted that
# and carried on, which was not good enough: the mis-tracking is not a harmless
# under-blanking, it is a FALSE NEGATIVE strictly worse than the sed this file
# replaced. Reproduced, on two lines of legal free-form Fortran:
#
#     msg = "hello &
#          &world" ; if (x > 0) go to 100
#
# On the second line the scanner starts OUTSIDE a literal, so the '&world' tail
# reads as code and the CLOSING quote reads as an OPENING one. Everything after
# it -- including the real `go to` -- is then blanked as literal content:
#
#     old  sed 's/!.*//'    -> banned-construct grep matches, module REJECTED
#     this file, before     -> nothing matches, module ACCEPTED, exit 0
#
# So the fix that removed two false positives introduced a false negative, in a
# gate whose entire job is to make "NO go to anywhere" true. That is the exact
# shape of docs/AUDIT-PHASE1.md's A-1, and it is not acceptable to leave it
# documented rather than fixed.
#
# The repair is to REFUSE, not to guess. If the character loop ends with a
# literal still open, this file has no way to know what the next line means, so
# it says so and exits 2; tools/compliance.sh turns that into a hard failure
# naming the file and the line. A gate that cannot analyse its input must not
# report that the input is clean.
#
# Refusing is cheap here because nothing in this tree writes a continued
# literal, and a kernel has little reason to: a string long enough to need one
# is a string that wants to be assembled from named PARAMETERs. If that ever
# changes, the honest fix is to carry quote state through
# tools/fold-continuations.awk and strip afterwards -- which couples two passes
# that are deliberately independent (each is separately testable, and the
# folder's contract depends on comments having ALREADY become blank lines; see
# its header, case three). That is a real design change, and it should be made
# deliberately rather than arrived at by a gate quietly accepting a file it
# could not read. The fixture that watches this refuse is in
# tools/gate-selftest.sh.
{
    out = ""                     # the rewritten line built up character by character
    q   = ""                     # "" when outside a literal, else the delimiter that opened it
    n   = length($0)
    i   = 1

    while (i <= n) {
        c = substr($0, i, 1)

        if (q == "") {
            # Outside a literal: '!' is a comment and everything after it goes.
            if (c == "!")
                break
            out = out c
            if (c == "'" || c == "\"")
                q = c            # this character opened a literal; keep it
            i++
        } else if (c == q) {
            if (substr($0, i + 1, 1) == q) {
                # Doubled delimiter: an escaped quote, i.e. literal CONTENT.
                out = out "  "
                i += 2
            } else {
                out = out c      # the real closing delimiter; keep it
                q = ""
                i++
            }
        } else {
            # Literal content: erased, so that no downstream grep can read it
            # as a banned construct, a declaration or a bind(c) attribute.
            out = out " "
            i++
        }
    }

    # A whole-line comment leaves an EMPTY line rather than no line at all --
    # exactly what the sed this replaced produced, and what
    # tools/fold-continuations.awk relies on to keep a fold open across a
    # comment that sits between two continuation lines.
    print out

    # FAIL CLOSED. The line ended while still inside a literal, which is the one
    # shape this scanner cannot track (see the header). Report it on stderr --
    # stdout is a pipeline carrying the stripped source -- and remember it for
    # END, which is where the exit status is set: `exit` inside a main rule would
    # skip the remaining lines, and the caller is entitled to see the whole file
    # in its diagnostic.
    if (q != "") {
        printf "strip-comments: %s:%d: character literal is still open at end of" \
               " line -- this gate cannot analyse a continued literal, so it" \
               " refuses to certify the file\n", FILENAME, FNR > "/dev/stderr"
        unterminated++
    }
}
END { if (unterminated > 0) exit 2 }
