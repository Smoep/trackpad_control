#!/usr/bin/env python3
"""Decision table for the BLQ-read-as-LD misfire (2026-09-04).

Diagnosis: BLQ wins on shape (sim .974 vs .880) and net direction (.970 vs .939) but
loses 15% to the turn-count penalty because the live stroke has one extra turn.

Option 2 variants attack the turn penalty itself.
Option 3 variants add a final-leg direction factor: LD is a U whose last leg goes UP,
BLQ is an L whose last leg goes LEFT — the distinguishing feature lives in the tail,
which the index-by-index matcher weights the same as everything else.

Usage: python3 scripts/blq_ld_options.py
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
TARGET = 1788540200.981    # reported: intended BLQ, fired LD
SANDY = 1788539396.999     # earlier fix: intended TRQ, had fired Sandy-Right
FIRE_THRESHOLD, AMBIGUITY_MARGIN = 0.60, 0.06

# name -> (turn_penalty, min_turn_delta, final_leg_weight, net_weight)
VARIANTS = {
    "0  shipped (no leg)":     (0.15, 1, 0.0, 2.0),
    "3  finalleg 0.20":        (0.15, 1, 0.20, 2.0),
    "3  finalleg 0.25":        (0.15, 1, 0.25, 2.0),
    "3  finalleg 0.30":        (0.15, 1, 0.30, 2.0),
    "3  finalleg 0.40":        (0.15, 1, 0.40, 2.0),
    "3a finalleg 0.50":        (0.15, 1, 0.50, 2.0),
    "3b finalleg 1.00":        (0.15, 1, 1.00, 2.0),
}
FINAL_LEG_SHARE = 0.25


def final_leg_vector(rs):
    if len(rs) < 4:
        return None
    i = max(0, int(len(rs) * (1 - FINAL_LEG_SHARE)))
    dx, dy = rs[-1][0] - rs[i][0], rs[-1][1] - rs[i][1]
    n = math.hypot(dx, dy)
    return None if n < 1e-9 else (dx / n, dy / n)


def final_leg_factor(a, b, weight):
    if weight <= 0:
        return 1.0
    va, vb = final_leg_vector(a), final_leg_vector(b)
    if va is None or vb is None:
        return 1.0
    dot = max(-1.0, min(1.0, va[0] * vb[0] + va[1] * vb[1]))
    return max(0.0, 1.0 - weight * (math.acos(dot) / math.pi))


def score(perf, samp, cfg):
    turn_pen, min_delta, leg_w, net_w = cfg
    prs, srs = base.resample(M.smooth(perf)), base.resample(M.smooth(samp))
    pa, sa = base.direction_angles(prs), base.direction_angles(srs)
    if not pa or not sa:
        return 0.0
    s = base.angular_similarity(pa, sa)
    delta = abs(base.count_turns(pa) - base.count_turns(sa))
    if delta >= min_delta:
        s *= max(0.0, 1.0 - delta * turn_pen)
    saved = base.NET_DIRECTION_WEIGHT
    base.NET_DIRECTION_WEIGHT = net_w
    try:
        s *= base.net_direction_factor(prs, srs)
    finally:
        base.NET_DIRECTION_WEIGHT = saved
    s *= base.open_closed_path_factor(prs, srs)
    return s * final_leg_factor(prs, srs, leg_w)


def rank(perf, fingers, shapes, cfg, exclude=None):
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
                best = max(best, score(perf, sp, cfg))
        res.append([g["name"], best, g])
    res.sort(key=lambda r: -r[1])
    _corner_tie_break(res, perf)
    return [(r[0], r[1]) for r in res]


_typical = {}


def _typical_corners(g):
    key = id(g)
    if key not in _typical:
        cs = [M.sharp_corners(base.sample_path(s)) for s in g["samples"]]
        _typical[key] = int(statistics.median(cs)) if cs else 0
    return _typical[key]


def _corner_tie_break(res, perf):
    """Shipped GestureMatcher.cornerTieBreak — the baseline must include it or the
    table compares against behaviour the app never had."""
    if len(res) < 2 or res[0][1] - res[1][1] >= M.TIE_MARGIN:
        return
    ta, tb = _typical_corners(res[0][2]), _typical_corners(res[1][2])
    if ta == tb:
        return
    live = M.sharp_corners(perf)
    loser = 1 if abs(live - ta) < abs(live - tb) else 0
    res[loser][1] *= M.TIE_LOSER_FACTOR
    res.sort(key=lambda r: -r[1])


def main():
    d = json.load(open(base.DEFAULT_PATH))
    items = [x for x in d if isinstance(x, dict)] if isinstance(d, list) else d["gestures"]
    shapes = [g for g in items if g.get("isEnabled") and g.get("inputType") not in base.SKIP_TYPES
              and g.get("samples") and not g["name"].startswith("AB")]
    recs = [json.loads(l) for l in open(LIVE) if l.strip()]
    recs = [r for r in recs if r.get("outcome") in ("fire", "ambiguous", "nomatch") and r.get("paths")]
    print(f"library {len(shapes)} gestures / {sum(len(g['samples']) for g in shapes)} samples; "
          f"live {len(recs)} strokes; labelled {len(M.LABELS)}\n")
    hdr = (f"{'variant':24} | {'LOO':9} {'worst mrg':9} | {'lbl':5} | "
           f"{'chg':>4} {'amb':>4} {'nm':>4} | {'target (want BLQ)':22} | sandy")
    print(hdr)
    print("-" * len(hdr))

    baseline = None
    for name, cfg in VARIANTS.items():
        correct = total = 0
        margins = []
        for held in shapes:
            for hi, hs in enumerate(held["samples"]):
                pts = base.sample_path(hs)
                if len(pts) < 2:
                    continue
                res = rank(pts, held["fingerCount"], shapes, cfg, exclude=(held, hi))
                dct = dict(res)
                own = dct.get(held["name"], 0)
                riv = max((s for n, s in res if n != held["name"]), default=0)
                margins.append(own - riv)
                total += 1
                correct += (res and res[0][0] == held["name"])

        tops, target, sandy, amb, nm, lbl_ok = {}, "", "", 0, 0, 0
        for r in recs:
            prim = r["paths"][r["primary"]] if 0 <= r["primary"] < len(r["paths"]) else max(r["paths"], key=len)
            pts = [(p[0], p[1]) for p in prim]
            if len(pts) < 2:
                continue
            res = rank(pts, r["fingers"], shapes, cfg)
            top = res[0][0] if res else ""
            tops[r["t"]] = top
            second = res[1][1] if len(res) > 1 else 0.0
            if not res or res[0][1] < FIRE_THRESHOLD:
                nm += 1
            elif res[0][1] - second < AMBIGUITY_MARGIN:
                amb += 1
            truth = M.LABELS.get(r["t"])
            if truth is not None:
                lbl_ok += (top == truth)
            if abs(r["t"] - TARGET) < 0.01:
                target = " / ".join(f"{n.replace('Window - ', '')}={s:.2f}" for n, s in res[:2])
            if abs(r["t"] - SANDY) < 0.01:
                sandy = top.replace("Window - ", "")
        changed = 0 if baseline is None else sum(1 for t, v in tops.items() if baseline.get(t) != v)
        if baseline is None:
            baseline = tops
        print(f"{name:24} | {correct:>3}/{total:<5} {min(margins):+8.2f} | {lbl_ok}/{len(M.LABELS):<3} | "
              f"{changed:>4} {amb:>4} {nm:>4} | {target:22} | {sandy}")


if __name__ == "__main__":
    main()
