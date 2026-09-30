#!/usr/bin/env python3
"""Compute per-hour recording coverage for one station on one day.

Reads `rclone lsjson` output on stdin, prints a one-line human report to
stdout, and exits 1 if any hour in the window is below the threshold.

Coverage is measured as real time intervals, not by bucketing filenames:
each object's start time comes from its name and its duration from its size
(the QA profile is CBR, so bytes / bytes_per_sec is exact). This stays correct
when segments are not hour-aligned - a mid-hour restart, or an ffmpeg build
where -segment_atclocktime drifts after the first cut.
"""
import argparse, json, re, sys

def intervals(objs, station, day, bytes_per_sec):
    pat = re.compile(rf"{re.escape(station)}_{re.escape(day)}_(\d{{2}})(\d{{2}})(\d{{2}})_CT\.")
    out = []
    for o in objs:
        m = pat.match(o.get("Name", ""))
        if not m:
            continue
        start = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
        out.append((start, start + o.get("Size", 0) / bytes_per_sec))
    return sorted(out)

def merge(iv):
    merged = []
    for a, b in iv:
        if merged and a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    return merged

def coverage(merged, start_h, end_h):
    rows = []
    for h in range(start_h, end_h):
        lo, hi = h * 3600, (h + 1) * 3600
        cov = sum(max(0, min(hi, b) - max(lo, a)) for a, b in merged)
        rows.append((h, cov / 3600))
    return rows

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--station", required=True)
    p.add_argument("--day", required=True)
    p.add_argument("--start-hour", type=int, required=True)
    p.add_argument("--end-hour", type=int, required=True)
    p.add_argument("--bytes-per-sec", type=float, required=True)
    p.add_argument("--threshold", type=float, default=0.95)
    a = p.parse_args()

    try:
        objs = json.load(sys.stdin) or []
    except (json.JSONDecodeError, ValueError):
        objs = []

    iv = intervals(objs, a.station, a.day, a.bytes_per_sec)
    rows = coverage(merge(iv), a.start_hour, a.end_hour)
    bad = [(h, c) for h, c in rows if c < a.threshold]

    line = f"{len(rows) - len(bad)}/{len(rows)} hours OK ({len(iv)} files)"
    if bad:
        line += "  GAPS: " + " ".join(f"{h:02d}:00={int(c * 100)}%" for h, c in bad)
    print(line)
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
