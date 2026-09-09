#!/usr/bin/env python3
"""Reconcile the CloudSQL/AlloyDB connections doc against a live instance list.

Any name returned by `gcloud sql instances list` or `gcloud alloydb instances
list` is treated as live. Doc rows are matched by name only — no special
casing for "external primary", "no proxy target", or similar annotations.
Stale rows are removed, missing rows are inserted. Read-only w.r.t. GCP; only
rewrites the doc.

Input TSV (from db-inventory-check.sh) is one row per line:
  <project>\tcloudsql\t<name>\t<version>\t<region>\t<connName>\t<avail>\t<tier>\t<master>
  <project>\talloydb\t<region>\t<cluster>\t<instance>\t<type>\t<cpus>\t<avail>\t<version>\t<state>
  <project>\t__INACCESSIBLE__
"""
import re
import sys
from collections import defaultdict
from datetime import date

TOP_SECTION_RE = {
    "cloudsql": re.compile(r"^## CloudSQL instances"),
    "alloydb":  re.compile(r"^## AlloyDB"),
}
ANY_TOP_HEADING_RE = re.compile(r"^## ")
PROJECT_HEADING_RE = re.compile(r"^### ")
PROJECT_ID_RE      = re.compile(r"vz-inscape-portfolio-[a-z]+")
BACKTICK_RE        = re.compile(r"`([^`]+)`")
VERIFIED_RE        = re.compile(r"(Inventory last verified: )[0-9-]+")

# Per-project suggested local proxy ports (must match section headers in the doc).
PG_PORT    = {"vz-inscape-portfolio-dev": 5432, "vz-inscape-portfolio-qa": 5433,
              "vz-inscape-portfolio-stage": 5434, "vz-inscape-portfolio-prod": 5435}
MYSQL_PORT = {"vz-inscape-portfolio-dev": 3306, "vz-inscape-portfolio-qa": 3307,
              "vz-inscape-portfolio-stage": 3308, "vz-inscape-portfolio-prod": 3307}
ALLOY_PORT = {"vz-inscape-portfolio-dev": 5442, "vz-inscape-portfolio-qa": 5443,
              "vz-inscape-portfolio-stage": 5444, "vz-inscape-portfolio-prod": 5445}


def parse_doc(lines):
    """Return entries[(section, project)] -> [(name, line_index), ...] for every
    documented CloudSQL/AlloyDB table row (header/separator rows excluded)."""
    entries = defaultdict(list)
    top = None
    project = None
    for i, line in enumerate(lines):
        if ANY_TOP_HEADING_RE.match(line):
            top = next((k for k, r in TOP_SECTION_RE.items() if r.match(line)), None)
            project = None
            continue
        if top is None:
            continue
        if PROJECT_HEADING_RE.match(line):
            m = PROJECT_ID_RE.search(line)
            project = m.group(0) if m else None
            continue
        if not project or not line.startswith("|"):
            continue
        tokens = BACKTICK_RE.findall(line)
        if not tokens:
            continue  # header/separator rows
        name = tokens[0] if top == "cloudsql" else (tokens[1] if len(tokens) >= 2 else tokens[0])
        entries[(top, project)].append((name, i))
    return entries


def find_insert_line(lines, top_section, project):
    """Return index at which new rows for (top_section, project) should be inserted,
    or None if the section/project has no table anchor to insert into."""
    top_match_re = TOP_SECTION_RE[top_section]
    in_top = False
    in_project = False
    last_pipe = None
    for i, line in enumerate(lines):
        if ANY_TOP_HEADING_RE.match(line):
            if in_project:
                break
            in_top = top_match_re.match(line) is not None
            in_project = False
            continue
        if not in_top:
            continue
        if PROJECT_HEADING_RE.match(line):
            if in_project:
                break  # reached next project heading in same top section
            m = PROJECT_ID_RE.search(line)
            if m and m.group(0) == project:
                in_project = True
                last_pipe = None
            continue
        if in_project and line.startswith("|"):
            last_pipe = i
    return (last_pipe + 1) if last_pipe is not None else None


def format_cloudsql_row(project, rec):
    name, engine, region, conn, avail, tier, master = rec
    if engine.startswith("POSTGRES"):
        port = PG_PORT.get(project, "?")
    elif engine.startswith("MYSQL") or engine.startswith("SQLSERVER"):
        port = MYSQL_PORT.get(project, "?")
    else:
        port = "?"
    ha = "**REGIONAL (HA)**" if avail == "REGIONAL" else "ZONAL"
    notes = f"{ha}, {tier}" if tier else ha
    if master:
        notes = f"{notes}; replica of `{master.split(':')[-1]}`"
    return f"| `{name}` | {engine} | {region} | `{conn}` | {port} | {notes} |\n"


def format_alloydb_row(project, rec):
    _region, cluster, instance, itype, cpu, avail, ver, state = rec
    notes = ", ".join(p for p in (ver, avail, state) if p)
    return f"| `{cluster}` | `{instance}` | {itype} | {cpu} | {notes} |\n"


def main():
    argv = sys.argv[1:]
    report_only = "--report-only" in argv
    argv = [a for a in argv if a != "--report-only"]
    doc_path, live_path = argv[0], argv[1]
    projects = argv[2:]

    with open(doc_path) as f:
        lines = f.read().splitlines(keepends=True)

    live_cs = defaultdict(list)   # project -> [(name, ver, region, conn, avail, tier, master), ...]
    live_ad = defaultdict(list)   # project -> [(region, cluster, instance, type, cpus, avail, ver, state), ...]
    inaccessible = set()
    with open(live_path) as f:
        for row in f:
            row = row.rstrip("\n")
            if not row:
                continue
            parts = row.split("\t")
            proj = parts[0]
            kind = parts[1] if len(parts) > 1 else ""
            if kind == "__INACCESSIBLE__":
                inaccessible.add(proj)
            elif kind == "cloudsql":
                pad = parts + [""] * (9 - len(parts))
                live_cs[proj].append(tuple(pad[2:9]))
            elif kind == "alloydb":
                pad = parts + [""] * (10 - len(parts))
                live_ad[proj].append(tuple(pad[2:10]))

    entries = parse_doc(lines)

    to_delete   = set()             # original-line indices to remove
    insertions  = defaultdict(list) # original-line index -> [new row text, ...]
    report      = []
    added     = 0
    removed   = 0
    refreshed = 0
    drift     = False

    for project in projects:
        section = [f"### {project}"]

        if project in inaccessible:
            section.append("    [SKIP] project not accessible")
            report.append("\n".join(section) + "\n")
            continue

        for kind, doc_key, live_map_all, formatter in (
            ("cloudsql", ("cloudsql", project), live_cs, format_cloudsql_row),
            ("alloydb",  ("alloydb",  project), live_ad, format_alloydb_row),
        ):
            doc_rows   = entries.get(doc_key, [])
            doc_names  = {n for n, _ in doc_rows}
            if kind == "cloudsql":
                live_by_name = {rec[0]: rec for rec in live_map_all.get(project, [])}
            else:
                live_by_name = {rec[2]: rec for rec in live_map_all.get(project, [])}
            live_names = set(live_by_name)

            new_rows = sorted(live_names - doc_names)
            gone     = sorted(doc_names - live_names)
            matched  = sorted(live_names & doc_names)

            # Row-refresh: doc row for a live instance whose body no longer
            # matches the canonical formatter output gets rewritten.
            stale = []
            for name, idx in doc_rows:
                if name not in live_by_name:
                    continue
                expected = formatter(project, live_by_name[name])
                if lines[idx] != expected:
                    stale.append((name, idx, expected))

            if not (new_rows or gone or stale):
                continue
            drift = True

            insert_at = find_insert_line(lines, kind, project)
            for n in new_rows:
                if report_only or insert_at is None:
                    tail = "" if insert_at is not None else "  (no table anchor)"
                    section.append(f"    \u2795 [{kind}] live but NOT documented: {n}{tail}")
                else:
                    insertions[insert_at].append(formatter(project, live_by_name[n]))
                    section.append(f"    \u2795 [{kind}] added: {n}")
                    added += 1
            for n in gone:
                if report_only:
                    section.append(f"    \u2796 [{kind}] documented but NOT live: {n}")
                else:
                    section.append(f"    \u2796 [{kind}] removed (no longer live): {n}")
                    removed += 1
                    for name, idx in doc_rows:
                        if name == n:
                            to_delete.add(idx)
            for name, idx, expected in stale:
                if report_only:
                    section.append(f"    \U0001F504 [{kind}] doc row stale, would refresh: {name}")
                else:
                    to_delete.add(idx)
                    insertions[idx].append(expected)
                    section.append(f"    \U0001F504 [{kind}] refreshed: {name}")
                    refreshed += 1

        if len(section) == 1:
            total = len(live_cs.get(project, [])) + len(live_ad.get(project, []))
            section.append(f"    \u2705 inventory in sync ({total} instances)")

        report.append("\n".join(section) + "\n")

    if not report_only and (to_delete or insertions):
        # Delete + insert in one pass: mark deletions on the original array,
        # then insert new rows at original indices, then drop marker lines.
        DEL = "\x00__DELETE__\x00"
        marked = [DEL if i in to_delete else ln for i, ln in enumerate(lines)]
        for idx in sorted(insertions.keys(), reverse=True):
            for row in reversed(insertions[idx]):
                marked.insert(idx, row)
        text = "".join(ln for ln in marked if ln != DEL)
        text = VERIFIED_RE.sub(rf"\g<1>{date.today().isoformat()}", text, count=1)
        with open(doc_path, "w") as f:
            f.write(text)

    print("\n".join(report))
    parts = []
    if added:     parts.append(f"added {added} row(s)")
    if removed:   parts.append(f"removed {removed} row(s)")
    if refreshed: parts.append(f"refreshed {refreshed} row(s)")
    if parts:
        print(f"==> Reconciled inventory: {', '.join(parts)} in {doc_path}; 'Inventory last verified' bumped.")
    elif report_only and drift:
        print("==> Drift detected (report-only \u2014 no doc edits made).")
    elif drift:
        print("==> Drift detected but no rows could be reconciled (missing table anchors).")
    else:
        print("==> Inventory is up to date.")


if __name__ == "__main__":
    main()

