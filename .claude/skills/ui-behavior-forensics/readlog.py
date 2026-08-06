#!/usr/bin/env python3
"""Read a GeometryLog file with arithmetic instead of adjectives.

    readlog.py <log> --transitions origin docH
        Which phase → phase pair changes a field, and how often. This is what
        localises the cause: 125 of 232 changes moved `docH` at exactly
        `change.restyle → bounds`, which named the culprit in one line of output.

    readlog.py <log> --per will-change --field origin --by kind
        Group the log into one event per occurrence of a phase, and report how much
        a field wobbled inside each group, split by a classification in the extra
        text. This is what separated "space and delete move it" from "everything
        moves it".

    readlog.py <log> --trail will-change --limit 3
        Print whole groups verbatim. Read these before believing any summary: the
        answer here was visible in one group, as three numbers that added up.
"""
import argparse
import collections
import re
import sys

LINE = re.compile(
    r"(?P<t>[\d.]+) (?P<phase>\S+)\s+"
    r"(?:origin\s+(?P<origin>[-\d.]+)\s+)?"
    r"(?:docH\s+(?P<docH>[-\d.]+)\s+)?"
    r"(?:docW\s+(?P<docW>[-\d.]+)\s+)?"
    r"(?:visH\s+(?P<visH>[-\d.]+)\s+)?"
    r"(?:inset\s+(?P<inset>[-\d.]+)\s*)?"
    r"(?P<extra>.*)"
)


def parse(path):
    rows = []
    for raw in open(path):
        m = LINE.match(raw)
        if not m:
            continue
        row = {"phase": m.group("phase"), "extra": m.group("extra").strip(), "raw": raw.rstrip()}
        for field in ("t", "origin", "docH", "docW", "visH", "inset"):
            value = m.group(field)
            row[field] = float(value) if value is not None else None
        rows.append(row)
    return rows


def transitions(rows, fields, threshold):
    for field in fields:
        counts = collections.Counter()
        for a, b in zip(rows, rows[1:]):
            if a[field] is None or b[field] is None:
                continue
            if abs(b[field] - a[field]) > threshold:
                counts[f"{a['phase']} → {b['phase']}"] += 1
        print(f"{field} changes at:")
        for pair, count in counts.most_common(10):
            print(f"  {count:5}  {pair}")
        print()


def group(rows, start):
    groups = []
    for row in rows:
        if row["phase"] == start:
            groups.append([row])
        elif groups:
            groups[-1].append(row)
    return groups


def per_event(rows, start, field, by, threshold):
    groups = group(rows, start)
    stats = collections.defaultdict(lambda: {"n": 0, "moved": 0, "worst": 0.0})
    for g in groups:
        key = "all"
        if by:
            m = re.search(rf"{by}=(\S+)", g[0]["extra"])
            key = m.group(1) if m else "?"
        values = [r[field] for r in g if r[field] is not None]
        if not values:
            continue
        spread = max(values) - min(values)
        s = stats[key]
        s["n"] += 1
        if spread > threshold:
            s["moved"] += 1
        s["worst"] = max(s["worst"], spread)
    print(f"{len(groups)} events grouped from '{start}', field '{field}'")
    print(f"  {'group':16} {'n':>5} {'wobbled':>9} {'worst':>10}")
    for key, s in sorted(stats.items(), key=lambda kv: -kv[1]["n"]):
        print(f"  {key:16} {s['n']:>5} {s['moved']:>9} {s['worst']:>9.1f}")


def trail(rows, start, limit):
    groups = group(rows, start)
    for g in groups[-limit:]:
        for row in g:
            print(row["raw"])
        print()


def main():
    parser = argparse.ArgumentParser(add_help=True, description=__doc__)
    parser.add_argument("log")
    parser.add_argument("--transitions", nargs="*", metavar="FIELD")
    parser.add_argument("--per", metavar="PHASE")
    parser.add_argument("--field", default="origin")
    parser.add_argument("--by", default="kind")
    parser.add_argument("--trail", metavar="PHASE")
    parser.add_argument("--limit", type=int, default=3)
    # Half a point: below that is rounding, not movement.
    parser.add_argument("--threshold", type=float, default=0.5)
    args = parser.parse_args()

    rows = parse(args.log)
    if not rows:
        sys.exit(f"no GeometryLog lines in {args.log}")
    print(f"{len(rows)} lines, phases: "
          f"{', '.join(f'{p}×{n}' for p, n in collections.Counter(r['phase'] for r in rows).most_common())}\n")

    if args.transitions is not None:
        transitions(rows, args.transitions or ["origin", "docH"], args.threshold)
    if args.per:
        per_event(rows, args.per, args.field, args.by, args.threshold)
    if args.trail:
        trail(rows, args.trail, args.limit)


if __name__ == "__main__":
    main()
