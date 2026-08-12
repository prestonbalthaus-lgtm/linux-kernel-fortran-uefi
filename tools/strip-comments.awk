# Quote-aware Fortran comment strip for tools/compliance.sh: truncates at a '!'
# outside a character literal, and blanks literal CONTENTS while keeping the
# delimiters, so the line stays a whole statement no grep can read as code.
# Kept in its own file because the program has to name both the single and the
# double quote character, which no shell quoting survives.
# Exits 2 on a line that ends inside a literal: quote state resets at end of
# line, so a continued literal cannot be tracked, and is refused not guessed.
{
    out = ""                     # rewritten line
    q   = ""                     # "" outside a literal, else the opening delimiter
    n   = length($0)
    i   = 1

    while (i <= n) {
        c = substr($0, i, 1)

        if (q == "") {
            if (c == "!")
                break
            out = out c
            if (c == "'" || c == "\"")
                q = c            # opened a literal
            i++
        } else if (c == q) {
            if (substr($0, i + 1, 1) == q) {
                # Doubled delimiter: Fortran's escaped quote, both are content.
                out = out "  "
                i += 2
            } else {
                out = out c      # the real closing delimiter, kept
                q = ""
                i++
            }
        } else {
            out = out " "
            i++
        }
    }

    # A whole-line comment must still print an EMPTY line: fold-continuations.awk
    # keeps a fold open across a comment only if the line survives.
    print out

    # Counted, not exited here: `exit` in a main rule would skip the rest of the
    # file, and the caller is owed every offending line.
    if (q != "") {
        printf "strip-comments: %s:%d: character literal is still open at end of" \
               " line -- this gate cannot analyse a continued literal, so it" \
               " refuses to certify the file\n", FILENAME, FNR > "/dev/stderr"
        unterminated++
    }
}
END { if (unterminated > 0) exit 2 }
