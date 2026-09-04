#!/usr/bin/env python3
"""End-to-end replay for 3-finger strokes: continuous lock gate + shape matcher.

For every recorded 3-finger sample (leave-one-out) and every live 3-finger stroke,
simulate stage 1 (Cycle Windows lock rule, current vs candidate) and stage 2
(angular matcher, threshold 0.60), then report per-gesture outcomes.

Usage: python3 scripts/lock_gate_experiment.py [--live] [--fingers 3|4]

--fingers 4 replays the Window Horizontal Tiling lock (CONT-SHAPE-GUARD: turn <= 2.5,
horizontal-dominant, >= 3 frames, dist > 0.025, after the 100 ms landing window).
There is no candidate rule for 4f yet; both columns show the current rule.
"""
import json, math, os, sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(__file__))
sys.argv, saved = ["x"], sys.argv
import recognizer_eval as R  # noqa: E402
sys.argv = saved

BASE = os.path.expanduser("~/Library/Application Support/TrackpadControl")
THR = 0.60
FINGERS = int(saved[saved.index("--fingers") + 1]) if "--fingers" in saved else 3
LOCK_NAME = {3: "Cycle Windows", 4: "Window - Horizontal Tiling - 4f"}[FINGERS]
# 4f candidate: 76 real tiling locks in the logs have maxOff <= 0.060 except 6 at 0.108-0.134 (turn 2.2-2.5).
TILING_MAXOFF = 0.08

def app_turn(pts):
    ang = []
    for k in range(1, len(pts)):
        dx = pts[k][0] - pts[k-1][0]; dy = pts[k][1] - pts[k-1][1]
        if math.hypot(dx, dy) >= 0.004:
            ang.append(math.atan2(dy, dx))
    t = 0.0
    for k in range(1, len(ang)):
        d = ang[k] - ang[k-1]
        while d > math.pi: d -= 2*math.pi
        while d < -math.pi: d += 2*math.pi
        t += abs(d)
    return t

def cycle_lock(pts, candidate):
    """Return frame index where Cycle Windows would lock, or None."""
    for n in range(6, len(pts)+1):
        seg = pts[:n]
        dx = seg[-1][0] - seg[0][0]; dy = seg[-1][1] - seg[0][1]
        if math.hypot(dx, dy) <= 0.04:
            continue
        on, off = abs(dx), abs(dy)
        if not (on > off*1.25 and on/max(off, 0.001) >= 1.35 and off <= 0.35):
            continue
        max_off = max(abs(p[1] - seg[0][1]) for p in seg[1:])
        if max_off > 0.38:
            continue
        if candidate and (max_off > 0.10 or app_turn(seg) > 2.0):
            continue
        return n
    return None

def tiling_lock(pts, ts, candidate, end_t=None):
    """Return frame index where 4f Window Horizontal Tiling would lock, or None.
    end_t = time the first finger lifted (app requires !anyEnded)."""
    for n in range(3, len(pts)+1):
        if ts and ts[n-1] - ts[0] < 0.10:
            continue
        if ts and end_t is not None and ts[n-1] >= end_t:
            return None
        seg = pts[:n]
        dx = seg[-1][0] - seg[0][0]; dy = seg[-1][1] - seg[0][1]
        if math.hypot(dx, dy) <= 0.025:
            continue
        if not abs(dx) > abs(dy):
            continue
        if app_turn(seg) > 2.5:
            continue
        if candidate and max(abs(p[1] - seg[0][1]) for p in seg[1:]) > TILING_MAXOFF:
            continue
        return n
    return None

def lock_frame(pts, ts, candidate, end_t=None):
    if FINGERS == 4:
        return tiling_lock(pts, ts, candidate, end_t)
    return cycle_lock(pts, candidate)

def sample_times(s):
    fps = s.get("fingerPaths") or []
    src = max(fps, key=len) if len(fps) > 1 else (s.get("pathPoints") or [])
    return [p.get("timestamp", 0.0) for p in src]

def sample_end(s):
    fps = s.get("fingerPaths") or []
    ends = [fp[-1]["timestamp"] for fp in fps if fp and "timestamp" in fp[-1]]
    return min(ends) if ends else None

def match(pts, shapes, held=None, held_idx=None):
    pa = R.direction_angles(R.resample(pts)); ptn = R.count_turns(pa)
    res = []
    for g in shapes:
        if g["fingerCount"] != FINGERS:
            continue
        best = 0.0
        for si, s in enumerate(g["samples"]):
            if g is held and si == held_idx:
                continue
            sp = R.sample_path(s)
            if len(sp) >= 2:
                best = max(best, R.score(pa, ptn, sp, pts))
        res.append((g["name"], best))
    res.sort(key=lambda r: -r[1])
    return res

def outcome(pts, shapes, candidate, held=None, held_idx=None, ts=None, end_t=None):
    if lock_frame(pts, ts, candidate, end_t) is not None:
        return LOCK_NAME, None
    res = match(pts, shapes, held, held_idx)
    if res and res[0][1] >= THR:
        return res[0][0], res[0][1]
    return "NOMATCH", res[0][1] if res else None

def main():
    d = json.load(open(os.path.join(BASE, "gestures.json")))
    items = [x for x in d if isinstance(x, dict)] if isinstance(d, list) else d["gestures"]
    shapes = [g for g in items if g.get("isEnabled") and g.get("inputType") not in R.SKIP_TYPES
              and g.get("samples") and g["fingerCount"] == FINGERS]
    probe = [g for g in items if g["name"] == "Probe CW"]

    print(f"=== recordings (leave-one-out, {FINGERS} fingers, lock={LOCK_NAME}, threshold {THR}) ===")
    print(f"{'gesture':22} {'current: correct / stolen / other':36} {'candidate: correct / stolen / other'}")
    for g in shapes + probe:
        want = LOCK_NAME if g["name"] == "Probe CW" else g["name"]
        tally = {False: [0, 0, 0], True: [0, 0, 0]}
        for hi, hs in enumerate(g["samples"]):
            pts = R.sample_path(hs)
            if len(pts) < 2:
                continue
            for cand in (False, True):
                got, _ = outcome(pts, shapes, cand, g, hi, ts=sample_times(hs), end_t=sample_end(hs))
                if got == want: tally[cand][0] += 1
                elif got == LOCK_NAME: tally[cand][1] += 1
                else: tally[cand][2] += 1
        a, b = tally[False], tally[True]
        print(f"{g['name'][:22]:22} {a[0]:>3} / {a[1]:>3} / {a[2]:>3}{'':22} {b[0]:>3} / {b[1]:>3} / {b[2]:>3}")

    if "--live" in saved:
        rows = [json.loads(l) for l in open(os.path.join(BASE, "live-strokes.jsonl"))]
        rows = [r for r in rows if r["fingers"] == FINGERS and r["outcome"] != "tap"]
        changed = 0; stolen_now = 0
        for r in rows:
            pp = r["paths"][r["primary"]]
            pts = [(p[0], p[1]) for p in pp]; ts = [p[2] for p in pp] if len(pp[0]) > 2 else None
            end_t = min(path[-1][2] for path in r["paths"] if path) if ts else None
            a = lock_frame(pts, ts, False, end_t); b = lock_frame(pts, ts, True, end_t)
            if a is not None:
                stolen_now += 1
                print("  live stroke model says STOLEN (but it reached the matcher):", r["t"], r["outcome"], r["top"][:1], "frame", a)
            if (a is None) != (b is None):
                changed += 1
                print("  live stroke changed:", r["t"], r["top"][:2])
        print(f"\n=== live {FINGERS}-finger strokes: {len(rows)}; model-stolen under current rule: {stolen_now} (should be 0); lock decision changed by candidate: {changed} ===")

if __name__ == "__main__":
    main()
