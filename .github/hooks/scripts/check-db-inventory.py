#!/usr/bin/env python3
"""SessionStart hook: verify the documented DB inventory is still up to date.

Runs at the start of every agent session (i.e. each time VS Code is restarted
and the agent is first used). It enumerates the live CloudSQL and AlloyDB
instances across the Inscape portfolio projects and compares them to the
inventory recorded in
``.github/instructions/cloudsql-connections.instructions.md``.

If reality has drifted from the doc (instances added or removed), it injects a
``systemMessage`` telling the agent the reference is stale and should be
refreshed. When everything matches — or when gcloud isn't authenticated yet —
it stays silent so it never nags.

Contract: read the SessionStart JSON payload on stdin (unused), emit optional
JSON with ``systemMessage`` on stdout, always exit 0 (non-blocking, advisory).
"""

import json
import os
import re
import subprocess
import sys

PROJECTS = [
    "vz-inscape-portfolio-dev",
    "vz-inscape-portfolio-qa",
    "vz-inscape-portfolio-stage",
]

INSTRUCTIONS_REL = ".github/instructions/cloudsql-connections.instructions.md"

# Per-gcloud-call wall-clock cap so a slow/hung API can't stall session start.
GCLOUD_TIMEOUT = 20


def emit(message: str | None) -> None:
    """Emit the hook result and exit. Silent (no message) => just continue."""
    out: dict = {"continue": True}
    if message:
        out["systemMessage"] = message
    sys.stdout.write(json.dumps(out))
    sys.exit(0)


def progress(msg: str) -> None:
    """Print a live progress line to stderr so it's visible at session start.

    stdout is reserved for the JSON hook contract, so all human-facing progress
    goes to stderr, which the tooling surfaces in the hook execution output.
    """
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def run(cmd: list[str]) -> str | None:
    """Run a gcloud command, returning stdout or None on any failure."""
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=GCLOUD_TIMEOUT,
        )
    except Exception:
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout


def parse_documented(path: str) -> set[tuple[str, str, str]] | None:
    """Parse (project, engine, instance) tuples out of the instructions doc.

    Relies on the well-defined table layout: ``### `project``` subsection
    headers, a CloudSQL section where the instance is the first backticked cell,
    and an AlloyDB section where the instance is the second backticked cell.
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return None

    documented: set[tuple[str, str, str]] = set()
    section: str | None = None  # 'cloudsql' | 'alloydb' | None
    project: str | None = None

    def backtick(cell: str) -> str | None:
        m = re.match(r"`([^`]+)`", cell.strip())
        return m.group(1) if m else None

    for line in lines:
        if line.startswith("## CloudSQL instances"):
            section, project = "cloudsql", None
            continue
        if line.startswith("## AlloyDB"):
            section, project = "alloydb", None
            continue
        if line.startswith("## Credentials"):
            section = None
            continue

        header = re.match(r"### `([^`]+)`", line)
        if header:
            project = header.group(1)
            continue

        if section and project and line.lstrip().startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if not cells or cells[0].startswith("---"):
                continue
            if cells[0] in ("Instance", "Cluster"):  # header row
                continue
            if section == "cloudsql":
                name = backtick(cells[0])
                if name:
                    documented.add((project, "cloudsql", name))
            else:  # alloydb: Cluster | Instance | Type | ...
                if len(cells) >= 2:
                    name = backtick(cells[1])
                    if name:
                        documented.add((project, "alloydb", name))

    return documented


def live_inventory() -> set[tuple[str, str, str]] | None:
    """Enumerate live (project, engine, instance) tuples. None => can't tell."""
    live: set[tuple[str, str, str]] = set()
    saw_any_success = False

    for project in PROJECTS:
        # CloudSQL
        progress(f"  {project}: listing CloudSQL instances\u2026")
        out = run(
            [
                "gcloud", "sql", "instances", "list",
                "--project", project,
                "--format", "value(name)",
            ]
        )
        if out is not None:
            saw_any_success = True
            names = list(filter(None, (n.strip() for n in out.splitlines())))
            for name in names:
                live.add((project, "cloudsql", name))
            progress(f"  {project}: found {len(names)} CloudSQL instance(s).")
        else:
            progress(f"  {project}: CloudSQL unavailable \u2014 skipped.")

        # AlloyDB clusters (full resource path so we can parse the region)
        progress(f"  {project}: listing AlloyDB clusters\u2026")
        clusters_out = run(
            [
                "gcloud", "alloydb", "clusters", "list",
                "--project", project,
                "--region", "-",
                "--format", "value(name)",
            ]
        )
        if clusters_out is None:
            progress(f"  {project}: AlloyDB unavailable \u2014 skipped.")
            continue
        saw_any_success = True
        alloy_count = 0
        for cluster_path in filter(None, (c.strip() for c in clusters_out.splitlines())):
            m = re.search(r"/locations/([^/]+)/clusters/([^/]+)", cluster_path)
            if not m:
                continue
            region, cluster = m.group(1), m.group(2)
            inst_out = run(
                [
                    "gcloud", "alloydb", "instances", "list",
                    "--project", project,
                    "--region", region,
                    "--cluster", cluster,
                    "--format", "value(name.basename())",
                ]
            )
            if inst_out is None:
                continue
            for name in filter(None, (n.strip() for n in inst_out.splitlines())):
                live.add((project, "alloydb", name))
                alloy_count += 1
        progress(f"  {project}: found {alloy_count} AlloyDB instance(s).")

    # If every gcloud call failed (e.g. not authenticated yet), we can't judge.
    return live if saw_any_success else None


def fmt(items: set[tuple[str, str, str]]) -> str:
    return ", ".join(
        f"{proj}/{engine}:{name}"
        for proj, engine, name in sorted(items)
    )


def main() -> None:
    sys.stdin.read()  # drain payload; not needed

    workspace = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    doc_path = os.path.join(workspace, INSTRUCTIONS_REL)

    progress("[db-inventory] Validating documented DB inventory against live GCP\u2026")

    documented = parse_documented(doc_path)
    if documented is None:
        progress("[db-inventory] Reference doc not found/readable \u2014 skipping validation.")
        emit(None)  # can't find/read the doc — stay silent
    progress(
        f"[db-inventory] Parsed {len(documented)} documented instance(s) from the reference doc."
    )

    live = live_inventory()
    if live is None:
        progress(
            "[db-inventory] gcloud unavailable/unauthenticated \u2014 skipping validation "
            "(the folderOpen auth login may still be running)."
        )
        emit(None)  # gcloud unavailable/unauthenticated — stay silent

    added = live - documented       # exists in cloud, missing from the doc
    removed = documented - live      # in the doc, no longer in the cloud

    if not added and not removed:
        progress(f"[db-inventory] In sync \u2014 {len(live)} live instance(s) match the doc.")
        emit(
            f"DB inventory validated at startup: {len(live)} live CloudSQL/AlloyDB "
            f"instance(s) across {len(PROJECTS)} project(s) match "
            f"`{INSTRUCTIONS_REL}`. Reference is current."
        )

    progress(
        f"[db-inventory] DRIFT detected \u2014 {len(added)} undocumented, "
        f"{len(removed)} stale."
    )

    parts = [
        "DB inventory drift detected: the live CloudSQL/AlloyDB instances no "
        f"longer match `{INSTRUCTIONS_REL}`."
    ]
    if added:
        parts.append(f"NOT in the doc (new/undocumented): {fmt(added)}.")
    if removed:
        parts.append(f"In the doc but NO LONGER live (removed/renamed): {fmt(removed)}.")
    parts.append(
        "Refresh that reference file (re-run the discovery commands documented "
        "in it) and tell the user before relying on it for a health check."
    )
    emit(" ".join(parts))


if __name__ == "__main__":
    main()
