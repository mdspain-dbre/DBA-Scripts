#!/usr/bin/env python3
"""Per-day metric summary and same-weekday Saturday compare for both instances."""
import json, statistics
from pathlib import Path
from datetime import datetime, timezone

out = Path(open('.last_memspike_out').read().strip())

def load(inst):
    j = json.load(open(out/inst/"metrics_raw.json"))
    series = {}
    for r in j["MetricDataResults"]:
        ts = [datetime.fromisoformat(t.replace('Z','+00:00')) for t in r["Timestamps"]]
        vals = r["Values"]
        # sort ascending
        pts = sorted(zip(ts, vals))
        series[r["Id"]] = pts
    return series

def daily_rollup(pts):
    by_day = {}
    for t, v in pts:
        day = t.strftime("%Y-%m-%d %a")
        by_day.setdefault(day, []).append(v)
    return by_day

def saturday_window(pts):
    """Extract Sat-only data points, broken out by date."""
    by_sat = {}
    for t, v in pts:
        if t.weekday() == 5:  # Sat
            day = t.strftime("%Y-%m-%d")
            by_sat.setdefault(day, []).append(v)
    return by_sat

# Note: 2026-06-06, 2026-06-13, 2026-06-20 (all Saturdays in window)
for inst in ("stage","qa"):
    s = load(inst)
    print(f"\n========= {inst.upper()} — daily rollup =========")
    print(f"{'date':<16} {'cpu_avg':>8} {'cpu_max':>8} {'fm_min_GiB':>10} {'fm_avg_GiB':>10} {'conn_avg':>9} {'conn_max':>9}")
    cpu_by_day = daily_rollup(s["cpu"])
    fm_by_day  = daily_rollup(s["freemem"])
    cn_by_day  = daily_rollup(s["conn"])
    days = sorted(set(cpu_by_day) & set(fm_by_day) & set(cn_by_day))
    for d in days:
        cpu = cpu_by_day[d]; fm = fm_by_day[d]; cn = cn_by_day[d]
        print(f"{d:<16} {statistics.mean(cpu):>8.2f} {max(cpu):>8.2f} "
              f"{min(fm)/1024**3:>10.2f} {statistics.mean(fm)/1024**3:>10.2f} "
              f"{statistics.mean(cn):>9.1f} {max(cn):>9.0f}")

    print(f"\n--- {inst.upper()} — Saturday CPU compare (same-weekday) ---")
    print(f"{'sat_date':<14} {'samples':>8} {'cpu_avg':>8} {'cpu_max':>8} {'cpu_p95':>8} {'fm_min_GiB':>10}")
    cpu_sat = saturday_window(s["cpu"])
    fm_sat  = saturday_window(s["freemem"])
    for d in sorted(cpu_sat):
        c = cpu_sat[d]
        c_sorted = sorted(c)
        p95 = c_sorted[int(0.95*len(c_sorted))-1] if c_sorted else 0
        fmgib = min(fm_sat.get(d, [0]))/1024**3 if fm_sat.get(d) else 0
        print(f"{d:<14} {len(c):>8} {statistics.mean(c):>8.2f} {max(c):>8.2f} {p95:>8.2f} {fmgib:>10.2f}")

    # Find peak CPU minute for narrative
    cpu_pts = s["cpu"]
    top5 = sorted(cpu_pts, key=lambda kv: -kv[1])[:5]
    print(f"\n--- {inst.upper()} — Top 5 CPU minutes in window ---")
    for t,v in top5:
        print(f"  {t.strftime('%Y-%m-%d %a %H:%M UTC')}  cpu={v:.2f}%")

    fm_pts = s["freemem"]
    bot5 = sorted(fm_pts, key=lambda kv: kv[1])[:5]
    print(f"--- {inst.upper()} — Bottom 5 FreeableMemory minutes ---")
    for t,v in bot5:
        print(f"  {t.strftime('%Y-%m-%d %a %H:%M UTC')}  fm={v/1024**3:.2f} GiB")
