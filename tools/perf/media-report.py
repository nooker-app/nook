#!/usr/bin/env python3
"""Correlate native display callbacks with real Magazine media/scroll windows.

Usage: media-report.py <ui-forensics.log> <directory containing frames-M3-*.csv>
The event windows overlap: this measures co-occurrence, not isolated causation.
"""

import csv
import json
import math
import re
import sys
from pathlib import Path


def merge(windows):
    result = []
    for start, end in sorted(windows):
        if result and start <= result[-1][1]:
            result[-1][1] = max(result[-1][1], end)
        else:
            result.append([start, end])
    return result


def metrics(frames, windows):
    windows = merge(windows)
    selected = [f for f in frames if any(
        f["at"] >= start and f["at"] - f["ms"] / 1000 <= end
        for start, end in windows
    )]
    times = sorted(f["ms"] for f in selected)
    if not times:
        return {"callbacks": 0}
    hitches = [f for f in selected if f["ms"] > 1.5 * f["expected"]]
    missed = sum(max(1, math.floor(f["ms"] / f["expected"]) - 1) for f in hitches)
    elapsed = sum(end - start for start, end in windows)
    return {
        "seconds": round(elapsed, 3),
        "callbacks": len(times),
        "missedPct": round(100 * missed / (len(times) + missed), 2),
        "p99Ms": round(times[min(len(times) - 1, int(len(times) * 0.99))], 2),
        "worstMs": round(times[-1], 2),
        "over50ms": sum(t >= 50 for t in times),
        "hitchMsPerSecond": round(sum(f["ms"] - f["expected"] for f in hitches) / elapsed, 2),
    }


def report(log_path, frame_directory):
    runs = []
    current = None
    scroll_start = None
    for line in Path(log_path).read_text().splitlines():
        fields = dict(re.findall(r"(\w+)=([^\s]+)", line))
        if "scenario.begin" in line:
            current = {"id": fields["id"], "rep": int(fields["rep"]), "cold": fields["cold"] == "1",
                       "events": {"thumbnailFresh": [], "thumbnailCached": [], "titleRipple": [], "summaryRipple": [], "scroll": []},
                       "start": float(line.split()[0])}
            scroll_start = None
        elif current is not None:
            at = float(line.split()[0])
            if "magazine.thumbnail " in line:
                key = "thumbnailFresh" if fields["animated"] == "1" else "thumbnailCached"
                current["events"][key].append([at, at + 0.65])
            elif "magazine.ripple " in line:
                key = "titleRipple" if fields["style"] == "headline" else "summaryRipple"
                current["events"][key].append([at, at + 0.65])
            elif "real.scroll.begin" in line:
                scroll_start = at
            elif "real.scroll.end" in line and scroll_start is not None:
                current["events"]["scroll"].append([scroll_start, at])
                scroll_start = None
            elif "scenario.stats" in line:
                path = Path(frame_directory) / f"frames-{current['id']}-{current['rep']}.csv"
                with path.open() as source:
                    frames = [{k: float(v) for k, v in row.items() if k in ("at", "ms", "expected")}
                              for row in csv.DictReader(source)]
                end = current["start"] + float(fields["activeDur"]) / 1000
                counts = {k: len(w) for k, w in current["events"].items()}
                sections = {k: metrics(frames, [[a, min(b, end)] for a, b in w if a < end])
                            for k, w in current["events"].items()}
                runs.append({"id": current["id"], "rep": current["rep"], "cold": current["cold"],
                             "events": counts, "all": metrics(frames, [[current["start"], end]]),
                             "windows": sections,
                             "translationStarted": int(fields["titleStart"]),
                             "translationDone": int(fields["titleDone"]),
                             "translationCancelled": int(fields["titleCancel"])})
                current = None
    return runs


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    print(json.dumps(report(sys.argv[1], sys.argv[2]), indent=2))
