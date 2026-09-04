#!/usr/bin/env python3
"""Ladder from our matcher to GestureSign's, one factor per step, scored identically.

Metrics per variant (threshold-free first, then two decision rules):
  LOO  : leave-one-out over recorded library — top-1 correct, worst margin, #negative margins,
         own-score floor (min own score) and rival ceiling (max rival score on a correct top-1)
  LIVE : live-strokes.jsonl — labelled strokes correct (top-1 == intent),
         unlabelled fires whose top-1 changes vs the app (= risk), and verdicts under two rules
Usage: python3 scripts/matcher_ladder.py [--verbose]
"""
import json, math, os, sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(__file__))
saved, sys.argv = sys.argv, ["x"]
import recognizer_eval as base  # noqa: E402
import matcher_experiment as M   # noqa: E402
sys.argv = saved

LIVE = os.path.expanduser("~/Library/Application Support/TrackpadControl/live-strokes.jsonl")

# name -> (smooth, npts, deadband, turnpen, net, openclosed)
LADDER = {
    "A ours (baseline)":        (True,  64,  True,  True,  True,  True),
    "B  - net direction":       (True,  64,  True,  True,  False, True),
    "C  - open/closed":         (True,  64,  True,  True,  False, False),
    "D  - turn penalty":        (True,  64,  True,  False, False, False),
    "E  100 points":            (True,  100, True,  False, False, False),
    "F  - deadband (=GS+smooth)": (True, 100, False, False, False, False),
    "G  GestureSign (no smooth)": (False, 100, False, False, False, False),
}
RULES = {"ours 0.60/m0.06": (0.60, 0.06), "GS 0.80/no-margin": (0.80, 0.0)}


def prep(pts, cfg):
    sm, n, _, _, _, _ = cfg
    p = M.smooth(pts) if sm else pts
    rs = base.resample(p, n)
    return rs, base.direction_angles(rs)


def similarity(a, b, deadband):
    n = min(len(a), len(b))
    if n == 0:
        return 0.0
    tot = 0.0
    db = base.ANGULAR_DEADBAND if deadband else 0.0
    for i in range(n):
        d = abs(a[i] - b[i])
        if d > math.pi:
            d = 2 * math.pi - d
        tot += max(0.0, d - db)
    return max(0.0, 1.0 - (tot / n) / math.pi)


def score(perf, samp, cfg):
    _, _, deadband, turnpen, net, oc = cfg
    prs, pa = prep(perf, cfg); srs, sa = prep(samp, cfg)
    if not pa or not sa:
        return 0.0
    s = similarity(pa, sa, deadband)
    if turnpen:
        s *= max(0.0, 1.0 - abs(base.count_turns(pa) - base.count_turns(sa)) * 0.15)
    if net:
        s *= base.net_direction_factor(prs, srs)
    if oc:
        s *= base.open_closed_path_factor(prs, srs)
    return s


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
        res.append((g["name"], best))
    res.sort(key=lambda r: -r[1])
    return res


def verdict(res, thr, mlim):
    if not res or res[0][1] < thr:
        return "nomatch"
    second = res[1][1] if len(res) > 1 else 0.0
    return "ambiguous" if res[0][1] - second < mlim else "fire"


def main():
    verbose = "--verbose" in saved
    d = json.load(open(base.DEFAULT_PATH))
    items = [x for x in d if isinstance(x, dict)] if isinstance(d, list) else d["gestures"]
    shapes = [g for g in items if g.get("isEnabled") and g.get("inputType") not in base.SKIP_TYPES
              and g.get("samples") and not g["name"].startswith("AB")]
    recs = [json.loads(l) for l in open(LIVE) if l.strip()]
    recs = [r for r in recs if r.get("outcome") in ("fire", "ambiguous", "nomatch") and r.get("paths")]

    print(f"library: {len(shapes)} gestures, {sum(len(g['samples']) for g in shapes)} samples (AB-* excluded); live: {len(recs)} strokes, {len(M.LABELS)} labelled\n")
    hdr = f"{'variant':28} | {'LOO top1':8} {'worst mrg':9} {'neg':3} {'own floor':9} {'rival max':9} | {'label ok':8} {'top1 chg':8}"
    for rn in RULES:
        hdr += f" | {rn:18}"
    print(hdr)
    print("-" * len(hdr))
    for name, cfg in LADDER.items():
        # --- LOO
        total = correct = 0; margins = []; own_floor = 9; rival_max = 0; confusions = defaultdict(int)
        for held in shapes:
            for hi, hs in enumerate(held["samples"]):
                pts = base.sample_path(hs)
                if len(pts) < 2:
                    continue
                res = rank(pts, held["fingerCount"], shapes, cfg, exclude=(held, hi))
                dct = dict(res); own = dct.get(held["name"], 0)
                riv = max((s for n, s in res if n != held["name"]), default=0)
                total += 1
                margins.append(own - riv); own_floor = min(own_floor, own)
                if res and res[0][0] == held["name"]:
                    correct += 1; rival_max = max(rival_max, riv)
                else:
                    confusions[(held["name"], res[0][0] if res else "-")] += 1
        neg = sum(1 for m in margins if m < 0)
        # --- live
        label_ok = 0; top1_changed = []; label_detail = []; rule_counts = {rn: defaultdict(int) for rn in RULES}
        for r in recs:
            prim = r["paths"][r["primary"]] if 0 <= r["primary"] < len(r["paths"]) else max(r["paths"], key=len)
            pts = [(p[0], p[1]) for p in prim]
            if len(pts) < 2:
                continue
            res = rank(pts, r["fingers"], shapes, cfg)
            top = res[0][0] if res else ""
            truth = M.LABELS.get(r["t"])
            if truth is not None:
                label_ok += (top == truth)
                if verbose:
                    label_detail.append(f"{truth.replace('Window - ','')}: {' / '.join(f'{n.replace('Window - ','')[:9]} {s:.2f}' for n, s in res[:2])}")
            elif r["outcome"] == "fire" and r["top"] and top != r["top"][0][0]:
                top1_changed.append(f"{r['top'][0][0]} -> {top}")
            for rn, (thr, ml) in RULES.items():
                v = verdict(res, thr, ml)
                ok = (v == "fire" and (top == truth if truth is not None else True))
                rule_counts[rn]["fire" if v == "fire" else v] += 1
                if truth is not None:
                    rule_counts[rn]["lbl_fire_ok"] += ok
        line = f"{name:28} | {correct:>3}/{total:<4} {min(margins):+8.2f} {neg:>3} {own_floor:9.2f} {rival_max:9.2f} | {label_ok:>3}/{len(M.LABELS):<4} {len(top1_changed):>8}"
        for rn in RULES:
            c = rule_counts[rn]
            line += f" | fire {c['fire']:>3} amb {c['ambiguous']:>2} nm {c['nomatch']:>2} lbl {c['lbl_fire_ok']}"
        print(line)
        if verbose:
            print("      labelled:", " | ".join(label_detail))
            if confusions:
                print("      LOO confusions:", dict(confusions))
            if top1_changed:
                print("      live top-1 changed:", top1_changed[:8])

if __name__ == "__main__":
    main()
