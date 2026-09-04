#!/usr/bin/env python3
"""Full validation of the SHIPPED matcher config against the gesture database.

Mirrors what the app does end to end: smooth -> resample -> angular similarity with
deadband, turn penalty, netgate, open/closed, final-leg factor, then the corner
tie-break, then the confidence threshold and ambiguity margin.

Usage: python3 scripts/validate_library.py [--all]   (--all includes AB-* experiments)
"""
import json
import os
import statistics
import sys
from collections import Counter

argv = sys.argv[:]
sys.argv = ["x"]
sys.path.insert(0, os.path.dirname(__file__))
import matcher_experiment as M  # noqa: E402
import recognizer_eval as base  # noqa: E402

LIVE = os.path.expanduser("~/Library/Application Support/TrackpadControl/live-strokes.jsonl")
VARIANT, TURN_PENALTY = "plain+netgate", 0.15
FIRE_THRESHOLD, AMBIGUITY_MARGIN = 0.60, 0.06

_typical = {}


def typical_corners(g):
    if id(g) not in _typical:
        cs = [M.sharp_corners(base.sample_path(s)) for s in g["samples"]]
        _typical[id(g)] = int(statistics.median(cs)) if cs else 0
    return _typical[id(g)]


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
    if len(res) >= 2 and res[0][1] - res[1][1] < M.TIE_MARGIN:
        ta, tb = typical_corners(res[0][2]), typical_corners(res[1][2])
        if ta != tb:
            live = M.sharp_corners(perf)
            loser = 1 if abs(live - ta) < abs(live - tb) else 0
            res[loser][1] *= M.TIE_LOSER_FACTOR
            res.sort(key=lambda r: -r[1])
    return res


def verdict(res):
    if not res or res[0][1] < FIRE_THRESHOLD:
        return "nomatch"
    second = res[1][1] if len(res) > 1 else 0.0
    return "ambiguous" if res[0][1] - second < AMBIGUITY_MARGIN else "fire"


def main():
    include_ab = "--all" in argv
    d = json.load(open(base.DEFAULT_PATH))
    items = [x for x in d if isinstance(x, dict)] if isinstance(d, list) else d["gestures"]
    shapes = [g for g in items if g.get("isEnabled") and g.get("inputType") not in base.SKIP_TYPES
              and g.get("samples")]
    if not include_ab:
        shapes = [g for g in shapes if not g["name"].startswith("AB")]
    n_samples = sum(len(g["samples"]) for g in shapes)
    print(f"library: {len(shapes)} gestures, {n_samples} samples"
          f"{'' if include_ab else ' (AB-* excluded; pass --all to include)'}\n")

    # ---- leave-one-out over every recorded sample
    rows, confusions, total, correct, fires = [], Counter(), 0, 0, 0
    for g in shapes:
        own_ok = own_scores = 0
        worst = 1.0
        for i, s in enumerate(g["samples"]):
            pts = base.sample_path(s)
            if len(pts) < 2:
                continue
            res = rank(pts, g["fingerCount"], shapes, exclude=(g, i))
            top = res[0][0] if res else ""
            own = dict((r[0], r[1]) for r in res).get(g["name"], 0.0)
            rival = max((r[1] for r in res if r[0] != g["name"]), default=0.0)
            total += 1
            own_scores += 1
            if top == g["name"]:
                correct += 1
                own_ok += 1
                fires += (verdict(res) == "fire")
            else:
                confusions[(g["name"], top)] += 1
            worst = min(worst, own - rival)
        rows.append((g["name"], g["fingerCount"], own_ok, own_scores, worst))

    print(f"LEAVE-ONE-OUT: top-1 {correct}/{total} = {100*correct/total:.1f}%   "
          f"would fire confidently: {fires}/{total} = {100*fires/total:.1f}%")
    print()
    print(f"{'gesture':26} {'f':>2} {'top1':>8} {'worst margin':>13}")
    print("-" * 54)
    for name, f, ok, tot, worst in sorted(rows, key=lambda r: (r[4], r[0])):
        flag = "  <-- check" if ok < tot or worst < 0.05 else ""
        print(f"{name:26} {f:>2} {ok:>4}/{tot:<3} {worst:>+13.3f}{flag}")
    if confusions:
        print("\nconfusions:")
        for (a, b), n in confusions.most_common():
            print(f"  {a} -> {b}  x{n}")

    # ---- live corpus
    if not os.path.exists(LIVE):
        return
    recs = [json.loads(l) for l in open(LIVE) if l.strip()]
    recs = [r for r in recs if r.get("outcome") in ("fire", "ambiguous", "nomatch") and r.get("paths")]
    counts, lbl_ok, changed = Counter(), 0, []
    for r in recs:
        prim = r["paths"][r["primary"]] if 0 <= r["primary"] < len(r["paths"]) else max(r["paths"], key=len)
        pts = [(p[0], p[1]) for p in prim]
        if len(pts) < 2:
            continue
        res = rank(pts, r["fingers"], shapes)
        v = verdict(res)
        counts[v] += 1
        truth = M.LABELS.get(r["t"])
        if truth is not None:
            lbl_ok += (res and res[0][0] == truth)
        if r["outcome"] == "fire" and r.get("top") and res and res[0][0] != r["top"][0][0]:
            changed.append((r["t"], r["top"][0][0], res[0][0], v))
    print(f"\nLIVE CORPUS ({len(recs)} strokes): "
          + "  ".join(f"{k}={counts[k]}" for k in ("fire", "ambiguous", "nomatch")))
    print(f"labelled strokes correct: {lbl_ok}/{len(M.LABELS)}")
    print(f"top-1 differs from what the app did at the time: {len(changed)}")
    for t, was, now, v in changed[-12:]:
        print(f"  t={t:.3f}  app {was} -> {now} ({v})")


if __name__ == "__main__":
    main()
