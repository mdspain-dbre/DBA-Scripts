#!/usr/bin/env python3
"""Hourly rollup for both RDS instances, designed to surface any sharp transitions
(e.g. the user-reported 'spike went away on Saturday 2026-06-20')."""
import json
from pathlib import Path
import datetime as dt

OUT = Path(open('.last_memspike_out').read().strip())
INST_MEM_GIB = 32.0  # db.r6i.xlarge

for inst in ("stage", "qa"):
    raw = json.load(open(OUT / inst / "metrics_raw.json"))
    series = {m["Id"]: m for m in raw["MetricDataResults"]}
    n = min(len(s["Timestamps"]) for s in series.values())

    by_hour = {}
    for i in range(n):
        ts = series["cpu"]["Timestamps"][i]
        hr = ts[:13]
        d = by_hour.setdefault(hr, {k: [] for k in ("cpu","fm","swap","conn","ri","wi","nrx","ntx")})
        for k_src, k_dst in [("cpu","cpu"),("freemem","fm"),("swap","swap"),("conn","conn"),
                             ("riops","ri"),("wiops","wi"),("netrx","nrx"),("nettx","ntx")]:
            try:
                v = series[k_src]["Values"][i]
                if v is not None:
                    d[k_dst].append(v)
            except IndexError:
                pass

    print(f"\n========== {inst.upper()}: per-hour rollup (UTC) ==========")
    hdr = (f"{'hour(UTC)':<14} {'dow':<4} {'CPUavg':>7} {'CPUmax':>7} "
           f"{'FMmin(GiB)':>11} {'FMavg(GiB)':>11} {'Connavg':>8} {'Connmax':>8} "
           f"{'WIOPSmax':>9} {'RIOPSmax':>9} {'NETRXmax(MiB/s)':>16} {'NETTXmax(MiB/s)':>16}")
    print(hdr)
    print('-' * len(hdr))
    prev_fm = None
    last_dow = None
    for hr in sorted(by_hour):
        d = by_hour[hr]
        if not d["cpu"]:
            continue
        dow = dt.datetime.strptime(hr, '%Y-%m-%dT%H').strftime('%a')
        if last_dow and dow != last_dow:
            print('-' * len(hdr))  # day separator
        last_dow = dow
        fm_min = min(d["fm"]) / 1024**3 if d["fm"] else float('nan')
        fm_avg = (sum(d["fm"]) / len(d["fm"])) / 1024**3 if d["fm"] else float('nan')
        cpu_avg = sum(d["cpu"]) / len(d["cpu"])
        cpu_max = max(d["cpu"])
        conn_avg = sum(d["conn"]) / len(d["conn"]) if d["conn"] else 0
        conn_max = max(d["conn"]) if d["conn"] else 0
        wi_max = max(d["wi"]) if d["wi"] else 0
        ri_max = max(d["ri"]) if d["ri"] else 0
        nrx = (max(d["nrx"]) / 1024**2) if d["nrx"] else 0
        ntx = (max(d["ntx"]) / 1024**2) if d["ntx"] else 0
        change = ""
        if prev_fm is not None:
            delta = fm_avg - prev_fm
            if abs(delta) >= 0.04:
                change = f"  ΔFM={delta:+.3f}GiB"
        prev_fm = fm_avg
        flag = ""
        if cpu_max >= 50:
            flag += " *CPU"
        if fm_min <= 4.10:
            flag += " *FMlow"
        print(f"{hr:<14} {dow:<4} {cpu_avg:>6.2f}% {cpu_max:>6.2f}% "
              f"{fm_min:>11.3f} {fm_avg:>11.3f} {conn_avg:>8.1f} {conn_max:>8.0f} "
              f"{wi_max:>9.0f} {ri_max:>9.0f} {nrx:>16.2f} {ntx:>16.2f}{change}{flag}")
