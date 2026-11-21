#!/usr/bin/env python3
"""Recount the @@ hunk headers of a unified diff after hand edits.

  tools/patch-recount.py xnu/patches/NNNN-name.patch      (rewrites in place)

Old start lines are kept; new start lines move by the lines added or removed
in earlier hunks of the same file.
"""
import re
import sys

HUNK = re.compile(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$')


def recount(lines):
    out, i, shift = [], 0, 0
    while i < len(lines):
        line = lines[i]
        if line.startswith('--- '):
            shift = 0
        m = HUNK.match(line)
        if not m:
            out.append(line)
            i += 1
            continue
        old_start, new_start, tail = int(m.group(1)), int(m.group(3)), m.group(5)
        j, old, new = i + 1, 0, 0
        while j < len(lines):
            l = lines[j]
            if l.startswith('@@') or l.startswith('diff ') or l.startswith('--- ') or l.startswith('-- \n'):
                break
            if l.startswith('+'):
                new += 1
            elif l.startswith('-'):
                old += 1
            elif l.startswith(' ') or l == '\n':
                old += 1
                new += 1
            elif l.startswith('\\'):
                pass
            else:
                break
            j += 1
        orig_old = int(m.group(2) if m.group(2) is not None else 1)
        orig_new = int(m.group(4) if m.group(4) is not None else 1)
        ns = new_start + shift if new_start else 0
        out.append('@@ -%d,%d +%d,%d @@%s\n' % (old_start, old, ns, new, tail))
        shift += (new - old) - (orig_new - orig_old)
        out.extend(lines[i + 1:j])
        i = j
    return out


if __name__ == '__main__':
    for path in sys.argv[1:]:
        with open(path) as f:
            lines = f.readlines()
        new = recount(lines)
        if new != lines:
            with open(path, 'w') as f:
                f.writelines(new)
            print('recounted', path)
