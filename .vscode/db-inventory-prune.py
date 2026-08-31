#!/usr/bin/env python3
"""Reconcile the CloudSQL/AlloyDB connections doc against a live instance list.

Removes rows for instances that no longer exist, leaves "no proxy target"
external-primary placeholder rows alone, and reports additions that still
need to be documented by hand. Read-only w.r.t. GCP; only rewrites the doc.
"""
import re
import sys
from collections import defaultdict
from datetime import date

TOP_SECTION_RE = {
    "cloudsql": re.compile(r"^## CloudSQL instances"),
    "alloydb": re.compile(r"^## AlloyDB"),
}
ANY_TOP_HEADING_RE = re.compile(r"^## ")
PROJECT_HEADING_RE = re.compile(r"^### ")
PROJECT_ID_RE = re.compile(r"vz-inscape-portfolio-[a-z]+")
BACKTICK_RE = re.compile(r"`([^`]+)`")
VERIFIED_RE = re.compile(r"(Inventory last verified: )[0-9-]+")


def parse_doc(lines):
    """Return {project: [(name, line_index), ...]} for CloudSQL/AlloyDB table rows."""
    entries = defaultdict(list)
    top_section = None
    project = None
    for i, line in enumerate(lines):
        if ANY_TOP_HEADING_RE.match(line):
            top_section = next((k for k, r in TOP_SECTION_RE.items() if r.match(line)), None)
            continue
        if PROJECT_HEADING_RE.match(line):
            m = PROJECT_ID_RE.search(line)
            if m:
                project = m.group(0)
            continue
        if top_section is None or not line.startswith("|"):
            continue
        if "no proxy target" in line.lower():
            continue  # external-primary placeholder row, never treated as drift
        tokens = BACKTICK_RE.findall(line)
        if not tokens:
            continue  # header/separator rows
        name = tokens[0] if top_section == "cloudsql" else (tokens[1] if len(tokens) >= 2 else tokens[0])
        if project:
            entries[project].append((name, i))
    return entries


def main():
    argv = sys.argv[1:]
    report_only = "--report-only" in argv
    argv = [a for a in argv if a != "--report-only"]
    doc_path, live_path = argv[0], argv[1]
    projects = argv[2:]

    with open(doc_path) as f:
        lines = f.read().splitlines(keepends=True)

    live_map = defaultdict(set)
    inaccessible = set()
    with open(live_path) as f:
        for row in f:
            row = row.rstrip("\n")
            if not row:
                continue
            proj, name = row.split("\t", 1)
            if name == "__INACCESSIBLE__":
                inaccessible.add(proj)
            else:
                live_map[proj].add(name)

    doc_map = parse_doc(lines)

    to_delete = set()
    drift = False
    removed_total = 0
    report = []
    for project in projects:
        if project in inaccessible:
            report.append(f"### {project}\n    [SKIP] project not accessible\n")
            continue
        doc_entries = doc_map.get(project, [])
        doc_names = {n for n, _ in doc_entries}
        live_names = live_map.get(project, set())
        new_live = sorted(live_names - doc_names)
        gone = sorted(doc_names - live_names)

        lines_out = [f"### {project}"]
        if not new_live and not gone:
            lines_out.append(f"    \u2705 inventory in sync ({len(live_names)} instances)")
        else:
            drift = True
            for n in new_live:
                lines_out.append(f"    \u2795 live but NOT documented: {n}")
            for n in gone:
                if report_only:
                    lines_out.append(f"    \u2796 documented but NOT live: {n}")
                else:
                    lines_out.append(f"    \u2796 removed from inventory (no longer live): {n}")
                    removed_total += 1
                    for name, idx in doc_entries:
                        if name == n:
                            to_delete.add(idx)
        report.append("\n".join(lines_out) + "\n")

    if to_delete and not report_only:
        lines = [ln for i, ln in enumerate(lines) if i not in to_delete]
        text = "".join(lines)
        text = VERIFIED_RE.sub(rf"\g<1>{date.today().isoformat()}", text, count=1)
        with open(doc_path, "w") as f:
            f.write(text)

    print("\n".join(report))
    if removed_total:
        print(f"==> Pruned {removed_total} stale instance row(s) from {doc_path} and bumped 'Inventory last verified'.")
    elif report_only and drift:
        print("==> Drift detected (report-only — no doc edits made).")
    elif drift:
        print("==> New live instances found that aren't documented yet — add them by hand.")
    else:
        print("==> Inventory is up to date.")


if __name__ == "__main__":
    main()
