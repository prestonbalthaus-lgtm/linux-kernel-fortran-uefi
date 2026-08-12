#!/usr/bin/env python3
"""The project spec: EVERY module, program, subroutine and function must
explicitly start with `implicit none`. Fortran lets a contained procedure
inherit it from the host, so gfortran accepts its absence -- the spec does not.
This inserts it in the one legal position: after the procedure statement and
after any USE statements, but BEFORE the first declaration."""
import re, glob, sys

START = re.compile(r'^\s*(?:(?:pure|elemental|recursive|module)\s+)*'
                   r'(?:[\w()*,: =]+\s+)?(function|subroutine)\s+\w+', re.I)
END   = re.compile(r'^\s*end\s+(function|subroutine|module|interface)\b', re.I)
USE   = re.compile(r'^\s*use\b', re.I)
IMP   = re.compile(r'^\s*implicit\s+none\b', re.I)
MOD   = re.compile(r'^\s*module\s+\w', re.I)

def fix(path):
    lines = open(path).read().splitlines()
    out, i, added = [], 0, 0
    while i < len(lines):
        ln = lines[i]
        out.append(ln)
        if END.match(ln) or MOD.match(ln) or not START.match(ln):
            i += 1; continue
        # procedure statement: scan forward past USE lines
        j, pend = i + 1, []
        while j < len(lines) and (USE.match(lines[j]) or not lines[j].strip()
                                  or lines[j].lstrip().startswith('!')):
            pend.append(lines[j]); j += 1
        if j < len(lines) and IMP.match(lines[j]):
            i += 1; continue                       # already compliant
        indent = re.match(r'\s*', ln).group(0) + '  '
        out.extend(pend)
        out.append(f'{indent}implicit none')
        added += 1
        i = j
    if added:
        open(path, 'w').write('\n'.join(out) + '\n')
    return added

total = 0
for f in sorted(glob.glob('src/**/fk_*.f90', recursive=True)):
    n = fix(f)
    total += n
    print(f"  {f:44s} +{n} implicit none")
print(f"inserted {total}")
