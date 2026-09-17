#!/usr/bin/env python3
"""Summarize RDS Proxy metrics and highlight suspicious 1-min windows."""
import json
import os
from datetime import datetime, timezone

MDIR = os.path.join(os.path.dirname(__file__), "metrics")
OUT_CSV = os.path.join(os.path.dirname(__file__), "proxy-metrics-1min.csv")
OUT_SUM = os.path.join(os.path.dirname(__file__), "proxy-metrics-summary.md")

# incident anchors (UTC)
SPIKE = datetime(2026, 9, 11, 22, 38, tzinfo=timezone.utc)
FAILOVER = datetime(2026, 9, 12, 0, 14, 55, tzinfo=timezone.utc)


def load(metric: str):
    with open(os.path.join(MDIR, f"{metric}.json")) as f:
        d = json.load(f)
    pts = {}
    for p in d.get("Datapoints", []):
        ts = datetime.fromisoformat(p["Timestamp"].replace("Z", "+00:00"))
        pts[ts] = p
    return d.get("Unit", ""), pts


METRICS = [
    "ClientConnections",
    "ClientConnectionsReceived",
    "ClientConnectionsClosed",
    "ClientConnectionsSetupSucceeded",
    "ClientConnectionsSetupFailedAuth",
    "DatabaseConnections",
    "DatabaseConnectionsCurrentlyBorrowed",
    "DatabaseConnectionsCurrentlySessionPinned",
    "DatabaseConnectionsBorrowLatency",
    "DatabaseConnectionRequests",
    "MaxDatabaseConnectionsAllowed",
    "QueryDatabaseResponseLatency",
    "QueryRequests",
]

data = {m: load(m) for m in METRICS}
all_ts = sorted({t for _, pts in data.values() for t in pts})

# CSV
with open(OUT_CSV, "w") as f:
    hdr = ["timestamp_utc"] + [f"{m}_avg" for m in METRICS] + [f"{m}_max" for m in METRICS]
    f.write(",".join(hdr) + "\n")
    for ts in all_ts:
        row = [ts.strftime("%Y-%m-%d %H:%M:%S")]
        for m in METRICS:
            _, pts = data[m]
            p = pts.get(ts, {})
            row.append(f"{p.get('Average', ''):.4f}" if "Average" in p else "")
        for m in METRICS:
            _, pts = data[m]
            p = pts.get(ts, {})
            row.append(f"{p.get('Maximum', ''):.4f}" if "Maximum" in p else "")
        f.write(",".join(row) + "\n")

# Summary stats per metric
def stat(metric):
    unit, pts = data[metric]
    if not pts:
        return None
    avgs = [p.get("Average") for p in pts.values() if "Average" in p]
    maxs = [p.get("Maximum") for p in pts.values() if "Maximum" in p]
    sums = [p.get("Sum") for p in pts.values() if "Sum" in p]
    return {
        "unit": unit,
        "n": len(pts),
        "peak": max(maxs) if maxs else None,
        "avg": sum(avgs) / len(avgs) if avgs else None,
        "sum": sum(sums) if sums else None,
        "first_ts": min(pts.keys()) if pts else None,
        "last_ts": max(pts.keys()) if pts else None,
    }


with open(OUT_SUM, "w") as f:
    f.write("# RDS Proxy metric summary — account-db-prod-proxy-us-west-2\n\n")
    f.write("Window: 2026-09-11 22:00 UTC → 2026-09-12 01:00 UTC (1-min)\n\n")
    f.write("| Metric | Unit | Points | Peak | Avg | Sum |\n")
    f.write("|---|---|---|---|---|---|\n")
    for m in METRICS:
        s = stat(m)
        if not s:
            f.write(f"| {m} | (no data) |  |  |  |  |\n")
            continue
        peak = f"{s['peak']:.2f}" if s['peak'] is not None else ""
        avg = f"{s['avg']:.2f}" if s['avg'] is not None else ""
        summ = f"{s['sum']:.0f}" if s['sum'] is not None else ""
        f.write(f"| {m} | {s['unit']} | {s['n']} | {peak} | {avg} | {summ} |\n")

    # Coverage
    f.write("\n## Coverage\n\n")
    for m in METRICS:
        s = stat(m)
        if s and s["first_ts"]:
            f.write(f"- **{m}**: {s['n']} points, {s['first_ts']:%Y-%m-%d %H:%M} → {s['last_ts']:%Y-%m-%d %H:%M} UTC\n")
        else:
            f.write(f"- **{m}**: NO DATAPOINTS in window\n")

    # Print samples around key moments
    def sample(ts_target):
        # find nearest ts within 90s
        nearest = None
        for ts in all_ts:
            if abs((ts - ts_target).total_seconds()) <= 90:
                if nearest is None or abs((ts - ts_target).total_seconds()) < abs((nearest - ts_target).total_seconds()):
                    nearest = ts
        return nearest

    f.write("\n## Snapshot at incident anchors\n\n")
    for label, ts_target in [
        ("22:35 UTC (pre-spike)", datetime(2026, 9, 11, 22, 35, tzinfo=timezone.utc)),
        ("22:38 UTC (spike)", datetime(2026, 9, 11, 22, 38, tzinfo=timezone.utc)),
        ("22:45 UTC", datetime(2026, 9, 11, 22, 45, tzinfo=timezone.utc)),
        ("23:00 UTC (1st page)", datetime(2026, 9, 11, 23, 0, tzinfo=timezone.utc)),
        ("23:30 UTC (2nd page)", datetime(2026, 9, 11, 23, 30, tzinfo=timezone.utc)),
        ("00:10 UTC (CS cut off)", datetime(2026, 9, 12, 0, 10, tzinfo=timezone.utc)),
        ("00:14 UTC (pre-failover)", datetime(2026, 9, 12, 0, 14, tzinfo=timezone.utc)),
        ("00:15 UTC (post-failover)", datetime(2026, 9, 12, 0, 15, tzinfo=timezone.utc)),
        ("00:20 UTC (recovered)", datetime(2026, 9, 12, 0, 20, tzinfo=timezone.utc)),
    ]:
        ts = sample(ts_target)
        f.write(f"\n### {label} (nearest sample: {ts})\n\n")
        if ts is None:
            f.write("_no datapoint within 90s_\n")
            continue
        f.write("| Metric | Avg | Max |\n|---|---|---|\n")
        for m in METRICS:
            _, pts = data[m]
            p = pts.get(ts)
            if not p:
                f.write(f"| {m} |  |  |\n")
            else:
                a = f"{p.get('Average', 0):.2f}" if "Average" in p else ""
                x = f"{p.get('Maximum', 0):.2f}" if "Maximum" in p else ""
                f.write(f"| {m} | {a} | {x} |\n")

print("CSV  ->", OUT_CSV)
print("MD   ->", OUT_SUM)
