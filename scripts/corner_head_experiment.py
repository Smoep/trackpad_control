#!/usr/bin/env python3
"""Does ignoring corners in the first N% of a stroke fix the Sandy-Right/TRQ misfire
without breaking anything else?

The corner detector already ignores end hooks (CORNER_MIN_TAIL) but counts a hook at
the START, which inflated a TRQ stroke to 3 corners and let the tie-break pick
Sandy-Right (typical 4) over TRQ (typical 1). 2026-09-04.

Usage: python3 scripts/corner_head_experiment.py
"""
import json
import math
import os
import statistics
import sys

sys.argv = ["x"]
sys.path.insert(0, os.path.dirname(__file__))
import matcher_experiment as M  # noqa: E402
import recognizer_eval as base  # noqa: E402

LIVE = os.path.expanduser("~/Library/Application Support/TrackpadControl/live-strokes.jsonl")
HEADS = [0.0, 0.05, 0.10, 0.15]
VARIANT = "plain+netgate"   # what v1.2.0 ships
TURN_PENALTY = 0.15


def sharp_corners(pts, head):
    rs = base.resample(M.smooth(pts))
    n = len(rs)
    w = max(2, int(n * M.CORNER_WIN))
    total = base.path_len(rs) or 1e-9
    count = 0
    for c in M.corner_indices(base.direction_angles(rs)):
        a, b = rs[max(0, c - w):c + 1], rs[c:min(n, c + w + 1)]
        if len(a) < 2 or len(b) < 2:
            continue
        ha = math.atan2(a[-1][1] - a[0][1], a[-1][0] - a[0][0])
        hb = math.atan2(b[-1][1] - b[0][1], b[-1][0] - b[0][0])
        d = abs(hb - ha)
        d = min(d, 2 * math.pi - d)
        if math.degrees(d) < M.CORNER_SHARP_DEG:
            continue
        if base.path_len(rs[c:]) / total < M.CORNER_MIN_TAIL:
            continue
        if base.path_len(rs[:c + 1]) / total < head:
            continue
        count += 1
    return count


def rank(perf, fingers, shapes, exclude=None):
    res = []
    for g in shapes:
        if g["fingerCount"] != fingers:
            continue
        best = 0.0
        for si, s in enumerate(g["samples"]):
            if exclude and g is exclude[0] and si == exclude[1]:
                continue
            sp = base.sample_path(s)
            if len(sp) >= 2:
                best = max(best, M.score(perf, sp, VARIANT, TURN_PENALTY))
        res.append([g["name"], best, g])
    res.sort(key=lambda r: -r[1])
    return res


def apply_tiebreak(res, perf, typical, head):
    """Same rule as GestureMatcher.cornerTieBreak, with the head guard applied."""
    if len(res) < 2 or res[0][1] - res[1][1] >= M.TIE_MARGIN:
        return res, None
    ta, tb = typical(res[0][2]), typical(res[1][2])
    if ta == tb:
        return res, None
    live = sharp_corners(perf, head)
    winner = 0 if abs(live - ta) < abs(live - tb) else 1
    loser = 1 - winner
    res[loser][1] *= M.TIE_LOSER_FACTOR
    res.sort(key=lambda r: -r[1])
    return res, live


def main():
    d = json.load(open(base.DEFAULT_PATH))
    items = [x for x in d if isinstance(x, dict)] if isinstance(d, list) else d["gestures"]
    shapes = [g for g in items if g.get("isEnabled") and g.get("inputType") not in base.SKIP_TYPES
              and g.get("samples") and not g["name"].startswith("AB")]
    recs = [json.loads(l) for l in open(LIVE) if l.strip()]
    recs = [r for r in recs if r.get("outcome") in ("fire", "ambiguous", "nomatch") and r.get("paths")]
    print(f"library {len(shapes)} gestures, live {len(recs)} strokes\n")
    print(f"{'head':>6} | {'LOO top1':9} | {'live top1 changed vs head=0':>28} | Sandy stroke -> ")
    print("-" * 78)

    baseline_live = None
    for head in HEADS:
        cache = {}

        def typical(g, head=head, cache=cache):
            key = (id(g), head)
            if key not in cache:
                cache[key] = int(statistics.median([sharp_corners(base.sample_path(s), head)
                                                    for s in g["samples"]] or [0]))
            return cache[key]

        correct = total = 0
        for held in shapes:
            for hi, hs in enumerate(held["samples"]):
                pts = base.sample_path(hs)
                if len(pts) < 2:
                    continue
                res = rank(pts, held["fingerCount"], shapes, exclude=(held, hi))
                res, _ = apply_tiebreak(res, pts, typical, head)
                total += 1
                correct += (res and res[0][0] == held["name"])

        live_top = {}
        sandy = ""
        for r in recs:
            prim = r["paths"][r["primary"]] if 0 <= r["primary"] < len(r["paths"]) else max(r["paths"], key=len)
            pts = [(p[0], p[1]) for p in prim]
            if len(pts) < 2:
                continue
            res = rank(pts, r["fingers"], shapes)
            res, live = apply_tiebreak(res, pts, typical, head)
            live_top[r["t"]] = res[0][0] if res else ""
            if abs(r["t"] - 1788539396.999) < 0.01:
                sandy = f"{res[0][0]} {res[0][1]:.2f} (corners={live})"

        if baseline_live is None:
            baseline_live = live_top
            changed = 0
        else:
            changed = sum(1 for t, v in live_top.items() if baseline_live.get(t) != v)
        print(f"{head:>6.2f} | {correct:>4}/{total:<4} | {changed:>28} | {sandy}")


if __name__ == "__main__":
    main()
