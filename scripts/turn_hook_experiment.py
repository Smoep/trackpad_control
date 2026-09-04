#!/usr/bin/env python3
"""Should the turn counter ignore start/end hooks the way the corner detector does?

2026-09-04: a clean down-then-left L (BLQ) lost to LD because a small end wobble added
one turn -> penalty 0.85 on the better match (sim 0.974/net 0.970 -> 0.803) while LD's
turn count happened to match (0.826). The corner detector already ignores such hooks.

Usage: python3 scripts/turn_hook_experiment.py
"""
import json
import math
import os
import sys

sys.argv = ["x"]
sys.path.insert(0, os.path.dirname(__file__))
import matcher_experiment as M  # noqa: E402
import recognizer_eval as base  # noqa: E402

LIVE = os.path.expanduser("~/Library/Application Support/TrackpadControl/live-strokes.jsonl")
TURN_PENALTY = 0.15
TARGET = 1788540200.981   # the reported BLQ-read-as-LD stroke
GUARDS = [0.0, 0.05, 0.10, 0.15]


def count_turns_guarded(pts, guard):
    """base.count_turns, but turns within `guard` of either end are hooks, not legs."""
    rs = base.resample(M.smooth(pts))
    angles = base.direction_angles(rs)
    if len(angles) < 4:
        return 0
    total = base.path_len(rs) or 1e-9
    # Same angle smoothing as base.count_turns.
    w = max(3, len(angles) // 12)
    sm = []
    for i in range(len(angles)):
        s, e = max(0, i - w // 2), min(len(angles), i + w // 2 + 1)
        sx = sum(math.cos(angles[j]) for j in range(s, e))
        sy = sum(math.sin(angles[j]) for j in range(s, e))
        sm.append(math.atan2(sy / (e - s), sx / (e - s)))
    th = math.radians(40)
    step = max(1, len(sm) // 16)
    last = sm[0]
    turns = 0
    for i in range(step, len(sm), step):
        diff = abs(sm[i] - last)
        if diff > math.pi:
            diff = 2 * math.pi - diff
        if diff > th:
            head = base.path_len(rs[:i + 1]) / total
            tail = base.path_len(rs[i:]) / total
            if head >= guard and tail >= guard:
                turns += 1
            last = sm[i]
    return turns


def score(perf, samp, guard):
    prs, pa = base.resample(M.smooth(perf)), None
    srs = base.resample(M.smooth(samp))
    pa, sa = base.direction_angles(prs), base.direction_angles(srs)
    if not pa or not sa:
        return 0.0
    sim = base.angular_similarity(pa, sa)
    pt, st = count_turns_guarded(perf, guard), count_turns_guarded(samp, guard)
    pen = max(0.0, 1.0 - abs(pt - st) * TURN_PENALTY)
    return sim * pen * base.net_direction_factor(prs, srs) * base.open_closed_path_factor(prs, srs)


def rank(perf, fingers, shapes, guard, exclude=None):
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
                best = max(best, score(perf, sp, guard))
        res.append((g["name"], best))
    res.sort(key=lambda r: -r[1])
    return res


def main():
    d = json.load(open(base.DEFAULT_PATH))
    items = [x for x in d if isinstance(x, dict)] if isinstance(d, list) else d["gestures"]
    shapes = [g for g in items if g.get("isEnabled") and g.get("inputType") not in base.SKIP_TYPES
              and g.get("samples") and not g["name"].startswith("AB")]
    recs = [json.loads(l) for l in open(LIVE) if l.strip()]
    recs = [r for r in recs if r.get("outcome") in ("fire", "ambiguous", "nomatch") and r.get("paths")]
    print(f"library {len(shapes)} gestures, live {len(recs)} strokes\n")
    print(f"{'guard':>6} | {'LOO top1':9} | {'live top1 changed':>17} | target stroke")
    print("-" * 72)

    baseline = None
    for guard in GUARDS:
        correct = total = 0
        for held in shapes:
            for hi, hs in enumerate(held["samples"]):
                pts = base.sample_path(hs)
                if len(pts) < 2:
                    continue
                res = rank(pts, held["fingerCount"], shapes, guard, exclude=(held, hi))
                total += 1
                correct += (res and res[0][0] == held["name"])

        tops, target = {}, ""
        for r in recs:
            prim = r["paths"][r["primary"]] if 0 <= r["primary"] < len(r["paths"]) else max(r["paths"], key=len)
            pts = [(p[0], p[1]) for p in prim]
            if len(pts) < 2:
                continue
            res = rank(pts, r["fingers"], shapes, guard)
            tops[r["t"]] = res[0][0] if res else ""
            if abs(r["t"] - TARGET) < 0.01:
                target = " / ".join(f"{n.replace('Window - ', '')}={s:.3f}" for n, s in res[:2])
        if baseline is None:
            baseline, changed = tops, 0
        else:
            changed = sum(1 for t, v in tops.items() if baseline.get(t) != v)
        print(f"{guard:>6.2f} | {correct:>4}/{total:<4} | {changed:>17} | {target}")


if __name__ == "__main__":
    main()
