#!/usr/bin/env python3
"""Pad every pipe-table in a markdown file so columns line up perfectly.

- Detects contiguous blocks of pipe lines (header | separator | body)
- Preserves left/right/center alignment from the separator row (:--, --:, :--:)
- Skips fenced code blocks (``` ... ```)
"""
import re, sys, unicodedata
from pathlib import Path

PATH = Path("PromptScriptsOutput/rds-memspike-twodb-20260623T155503Z/REPORT.md")

def visible_len(s: str) -> int:
    # Treat double-wide chars as 2; everything else 1
    n = 0
    for c in s:
        if unicodedata.east_asian_width(c) in ("W", "F"):
            n += 2
        else:
            n += 1
    return n

def split_row(line: str):
    s = line.strip()
    if s.startswith("|"): s = s[1:]
    if s.endswith("|"):   s = s[:-1]
    return [c.strip() for c in s.split("|")]

def is_pipe_line(line: str) -> bool:
    return "|" in line and line.strip().startswith("|")

def is_separator(cells):
    if not cells: return False
    # Accept any cell of the form -, :-, -:, :-: with 1+ dashes (CommonMark spec).
    # Output side always re-emits 3+ dashes via the width=max(w,3) floor.
    pat = re.compile(r"^:?-+:?$")
    return all(pat.match(c.strip()) for c in cells) and any("-" in c for c in cells)

def align_of(cell: str) -> str:
    c = cell.strip()
    left = c.startswith(":")
    right = c.endswith(":")
    if left and right: return "center"
    if right: return "right"
    return "left"

def pad(cell: str, width: int, alignment: str) -> str:
    cur = visible_len(cell)
    n = max(0, width - cur)
    if alignment == "right":  return " " * n + cell
    if alignment == "center":
        l = n // 2; r = n - l
        return " " * l + cell + " " * r
    return cell + " " * n  # left

def format_table(block):
    rows = [split_row(l) for l in block]
    if len(rows) < 2 or not is_separator(rows[1]):
        return block  # not a real table — leave alone
    ncols = max(len(r) for r in rows)
    for r in rows:
        while len(r) < ncols: r.append("")
    alignments = [align_of(c) for c in rows[1]]
    # widths: max(visible_len) of every non-separator row, plus min 3
    widths = [3] * ncols
    for i, r in enumerate(rows):
        if i == 1: continue
        for j, c in enumerate(r):
            widths[j] = max(widths[j], visible_len(c))
    # rebuild — separator dash count must equal data cell width (w),
    # so that " | ".join produces identical pipe-to-pipe spans on every row.
    out = []
    for i, r in enumerate(rows):
        if i == 1:
            cells = []
            for j in range(ncols):
                w = max(widths[j], 3)
                if alignments[j] == "center":
                    cells.append(":" + "-"*(w-2) + ":")
                elif alignments[j] == "right":
                    cells.append("-"*(w-1) + ":")
                else:
                    cells.append("-"*w)
            out.append("| " + " | ".join(cells) + " |")
        else:
            cells = [pad(r[j], widths[j], alignments[j]) for j in range(ncols)]
            out.append("| " + " | ".join(cells) + " |")
    return out

def reformat(md: str) -> str:
    lines = md.splitlines()
    out = []
    i = 0
    in_fence = False
    while i < len(lines):
        ln = lines[i]
        if ln.lstrip().startswith("```"):
            in_fence = not in_fence
            out.append(ln); i += 1; continue
        if in_fence:
            out.append(ln); i += 1; continue
        # detect table start
        if is_pipe_line(ln):
            block = [ln]; j = i + 1
            while j < len(lines) and is_pipe_line(lines[j]):
                block.append(lines[j]); j += 1
            out.extend(format_table(block))
            i = j
        else:
            out.append(ln); i += 1
    return "\n".join(out) + ("\n" if md.endswith("\n") else "")

txt = PATH.read_text()
PATH.write_text(reformat(txt))
print(f"Reformatted {PATH}")
