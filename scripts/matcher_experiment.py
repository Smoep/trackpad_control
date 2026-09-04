#!/usr/bin/env python3
"""Offline matcher experiments against the real gesture library.

Compares matcher variants on (1) leave-one-out over recorded samples and
(2) real recordings perturbed the way live failures look (second leg of an
L-shape shortened/lengthened; straight stroke given a small tail).
Read-only. Usage: python3 scripts/matcher_experiment.py [gestures.json]
"""
import json, math, sys, os
from collections import defaultdict

sys.path.insert(0, os.path.dirname(__file__))
import recognizer_eval as base  # noqa: E402

SMOOTH_WINDOW = 9  # GestureNormalizer.smoothingWindow


def smooth(pts, window=SMOOTH_WINDOW):
    if window <= 1 or len(pts) < 3:
        return pts
    half = window // 2
    out = []
    for i in range(len(pts)):
        lo, hi = max(0, i - half), min(len(pts) - 1, i + half)
        seg = pts[lo:hi + 1]
        out.append((sum(p[0] for p in seg) / len(seg), sum(p[1] for p in seg) / len(seg)))
    return out


def smoothed_angles(angles):
    w = max(3, len(angles) // 12)
    sm = []
    for i in range(len(angles)):
        s, e = max(0, i - w // 2), min(len(angles), i + w // 2 + 1)
        sx = sum(math.cos(angles[j]) for j in range(s, e))
        sy = sum(math.sin(angles[j]) for j in range(s, e))
        sm.append(math.atan2(sy / (e - s), sx / (e - s)))
    return sm


def corner_indices(angles, th_deg=40):
    """Indices (in point space) where the smoothed direction turns > th."""
    if len(angles) < 4:
        return []
    sm = smoothed_angles(angles)
    th = math.radians(th_deg)
    step, last, out = max(1, len(sm) // 16), sm[0], []
    for i in range(step, len(sm), step):
        diff = abs(sm[i] - last)
        if diff > math.pi:
            diff = 2 * math.pi - diff
        if diff > th:
            out.append(i)
            last = sm[i]
    return out


MIN_LEG_SHARE = 0.06  # legs shorter than this fraction of the path are landing wobble, not movement


def leg_normalized_resample(pts, n=base.POINT_COUNT, min_leg_share=None):
    """Split at corners, give every leg the same number of points."""
    rs = base.resample(pts, n)
    corners = corner_indices(base.direction_angles(rs))
    if min_leg_share:
        total = base.path_len(rs)
        bounds = [0] + corners + [len(rs) - 1]
        keep = []
        for k, c in enumerate(corners):
            leg_before = base.path_len(rs[bounds[k]:c + 1])
            leg_after = base.path_len(rs[c:bounds[k + 2]])
            if leg_before >= min_leg_share * total and leg_after >= min_leg_share * total:
                keep.append(c)
        corners = keep
    if not corners:
        return rs
    bounds = [0] + corners + [len(rs) - 1]
    legs = len(bounds) - 1
    per = max(2, n // legs)
    out = []
    for k in range(legs):
        seg = rs[bounds[k]:bounds[k + 1] + 1]
        if len(seg) < 2:
            continue
        r = base.resample(seg, per)
        out.extend(r if not out else r[1:])
    return out


# ---------------------------------------------------------------- variants ---

def prep(pts, variant):
    if "postsmooth" in variant:
        # Speed-independent: smooth after resampling so the window is a fixed fraction of the stroke.
        sm = smooth(base.resample(pts))
    else:
        sm = smooth(pts)
    if "aspect" in variant:
        sm = [(p[0] * ASPECT, p[1]) for p in sm]
    if "legnorm" in variant:
        rs = leg_normalized_resample(sm, min_leg_share=MIN_LEG_SHARE if "minleg" in variant else None)
    else:
        rs = base.resample(sm)
    return rs, base.direction_angles(rs)


ASPECT = 1.6


def score(perf_pts, samp_pts, variant, turn_penalty):
    prs, pa = prep(perf_pts, variant)
    srs, sa = prep(samp_pts, variant)
    if not pa or not sa:
        return 0.0
    sim = base.angular_similarity(pa, sa)
    # Turn count from the plain (non leg-normalized) points of the same preprocessing.
    if "postsmooth" in variant:
        pp = smooth(base.resample(perf_pts)); ss = smooth(base.resample(samp_pts))
    else:
        pp = smooth(perf_pts); ss = smooth(samp_pts)
    if "aspect" in variant:
        pp = [(p[0] * ASPECT, p[1]) for p in pp]; ss = [(p[0] * ASPECT, p[1]) for p in ss]
    pt = base.count_turns(base.direction_angles(base.resample(pp)))
    st = base.count_turns(base.direction_angles(base.resample(ss)))
    pen = max(0.0, 1.0 - abs(pt - st) * turn_penalty)
    net = net_direction(prs, srs, variant)
    oc = base.open_closed_path_factor(prs, srs)
    return sim * pen * net * oc * final_leg_factor(prs, srs)


FINAL_LEG_SHARE = 0.25   # last quarter of the path
FINAL_LEG_WEIGHT = 0.5   # shipped 2026-09-04; see scripts/blq_ld_options.py variant 3a


def _final_leg_vector(rs):
    if len(rs) < 4:
        return None
    i = max(0, int(len(rs) * (1 - FINAL_LEG_SHARE)))
    dx, dy = rs[-1][0] - rs[i][0], rs[-1][1] - rs[i][1]
    n = math.hypot(dx, dy)
    return None if n < 1e-9 else (dx / n, dy / n)


def final_leg_factor(a, b):
    """Where the last leg points: an L ending LEFT vs a U ending UP."""
    va, vb = _final_leg_vector(a), _final_leg_vector(b)
    if va is None or vb is None:
        return 1.0
    dot = max(-1.0, min(1.0, va[0] * vb[0] + va[1] * vb[1]))
    return max(0.0, 1.0 - FINAL_LEG_WEIGHT * (math.acos(dot) / math.pi))


NET_GATE_OPENNESS = 0.15   # below this the start->end vector is noise (there-and-back strokes)


def net_direction(a, b, variant):
    if "netgate" in variant and base.path_openness(a) < NET_GATE_OPENNESS and base.path_openness(b) < NET_GATE_OPENNESS:
        return 1.0
    if "netw1" in variant:
        saved = base.NET_DIRECTION_WEIGHT
        base.NET_DIRECTION_WEIGHT = 1.0
        try:
            return base.net_direction_factor(a, b)
        finally:
            base.NET_DIRECTION_WEIGHT = saved
    return base.net_direction_factor(a, b)


VARIANTS = {
    "baseline": ("plain", 0.15),
    "corner-tiebreak": ("plain+corner", 0.15),
    "gsign-longest": ("gsign", 0.15),
    "gsign-allfingers": ("gsign+fingers", 0.15),
}


# --- GestureSign port (PointPatternMath / PointPatternAnalyzer) --------------
GS_PRECISION = 100


def gs_angles(pts):
    rs = base.resample(pts, GS_PRECISION)
    return [math.atan2(rs[i][1] - rs[i-1][1], rs[i][0] - rs[i-1][0]) for i in range(1, len(rs))]


def gs_score(a_pts, b_pts):
    a, b = gs_angles(a_pts), gs_angles(b_pts)
    if not a or not b:
        return 0.0
    n = min(len(a), len(b))
    tot = 0.0
    for i in range(n):
        d = abs(a[i] - b[i])
        if d > math.pi:
            d = 2 * math.pi - d
        tot += d
    return 1.0 - (tot / n) / math.pi          # GestureSign probability / 100


def finger_paths(sample):
    fps = sample.get("fingerPaths") or []
    paths = [[(p["x"], p["y"]) for p in f] for f in fps if len(f) >= 2]
    return sorted(paths, key=lambda p: p[0][0])  # align fingers left-to-right


def gs_rank(perf_paths, fingers, shapes, per_finger, exclude=None):
    results = []
    for g in shapes:
        if g["fingerCount"] != fingers:
            continue
        best = 0.0
        for si, s in enumerate(g["samples"]):
            if exclude and g is exclude[0] and si == exclude[1]:
                continue
            if per_finger:
                sp = finger_paths(s)
                if len(sp) != len(perf_paths):
                    continue
                probs = [gs_score(pa, pb) for pa, pb in zip(perf_paths, sp)]
                sc = min(probs) if all(p > 0.80 for p in probs) else 0.0
            else:
                sp = base.sample_path(s)
                sc = gs_score(max(perf_paths, key=len), sp) if len(sp) >= 2 else 0.0
            best = max(best, sc)
        results.append((g["name"], best))
    results.sort(key=lambda r: -r[1])
    return results

# User-labelled intent for live strokes (2026-09-04), keyed by stroke timestamp.
LABELS = {
    1788407248.431: "Window - BLQ",
    1788423772.091: "Window - BLQ",   # app fired Close tab 0.87 — wrong
    1788423774.206: "Window - BLQ",
    1788423830.79:  "Window - TRQ",
    1788454561.131: "Window - LD",
}

TIE_MARGIN = 0.12      # only strokes this close are re-decided
TIE_LOSER_FACTOR = 0.80
CORNER_SHARP_DEG = 40  # heading change across a 15% window
CORNER_WIN = 0.15
CORNER_MIN_TAIL = 0.10 # remaining path after the corner
CORNER_MIN_HEAD = 0.10 # path before the corner (landing hooks are not legs)


def sharp_corners(pts):
    """Count real L-corners; ignores gentle curvature and start/end hooks."""
    rs = base.resample(smooth(pts)); n = len(rs); w = max(2, int(n * CORNER_WIN))
    total = base.path_len(rs) or 1e-9
    count = 0
    for c in corner_indices(base.direction_angles(rs)):
        a = rs[max(0, c - w):c + 1]; b = rs[c:min(n, c + w + 1)]
        if len(a) < 2 or len(b) < 2:
            continue
        ha = math.atan2(a[-1][1] - a[0][1], a[-1][0] - a[0][0])
        hb = math.atan2(b[-1][1] - b[0][1], b[-1][0] - b[0][0])
        d = abs(hb - ha); d = min(d, 2 * math.pi - d)
        if math.degrees(d) >= CORNER_SHARP_DEG and base.path_len(rs[c:]) / total >= CORNER_MIN_TAIL \
                and base.path_len(rs[:c + 1]) / total >= CORNER_MIN_HEAD:
            count += 1
    return count


_typical_cache = {}


def typical_turns(g):
    key = id(g)
    if key not in _typical_cache:
        ts = sorted(sharp_corners(base.sample_path(s)) for s in g["samples"] if len(base.sample_path(s)) >= 2)
        _typical_cache[key] = ts[len(ts) // 2] if ts else 0
    return _typical_cache[key]


def corner_tiebreak(results, perf_pts, shapes):
    """If the top two are close and disagree on corner count, let the live corner count decide."""
    if len(results) < 2 or results[0][1] - results[1][1] >= TIE_MARGIN:
        return results
    by_name = {g["name"]: g for g in shapes}
    a, b = results[0], results[1]
    ta, tb = typical_turns(by_name[a[0]]), typical_turns(by_name[b[0]])
    if ta == tb:
        return results
    live = sharp_corners(perf_pts)
    da, db = abs(live - ta), abs(live - tb)
    if da < db:
        results[1] = (b[0], b[1] * TIE_LOSER_FACTOR)
    elif db < da:
        results[0] = (a[0], a[1] * TIE_LOSER_FACTOR)
    results.sort(key=lambda r: -r[1])
    return results


def rank(perf_pts, fingers, shapes, variant, tp, exclude=None, perf_paths=None):
    if "gsign" in variant:
        return gs_rank(perf_paths or [perf_pts], fingers, shapes, "fingers" in variant, exclude)
    results = []
    for g in shapes:
        if g["fingerCount"] != fingers:
            continue
        best = 0.0
        for si, s in enumerate(g["samples"]):
            if exclude and g is exclude[0] and si == exclude[1]:
                continue
            sp = base.sample_path(s)
            if len(sp) >= 2:
                best = max(best, score(perf_pts, sp, variant, tp))
        results.append((g["name"], best))
    results.sort(key=lambda r: -r[1])
    if "corner" in variant:
        results = corner_tiebreak(results, perf_pts, [g for g in shapes if g["fingerCount"] == fingers])
    return results


def loo(shapes, variant, tp, thr=0.60, margin_lim=0.06):
    if "gsign" in variant:
        thr, margin_lim = 0.80, 0.0   # GestureSign: ProbabilityThreshold=80, no margin rule
    total = correct = ambiguous = below = 0
    confusion = defaultdict(int)
    for held in shapes:
        for hi, hs in enumerate(held["samples"]):
            pts = base.sample_path(hs)
            if len(pts) < 2:
                continue
            res = rank(pts, held["fingerCount"], shapes, variant, tp, exclude=(held, hi),
                       perf_paths=finger_paths(hs) or [pts])
            total += 1
            if not res:
                below += 1
                continue
            top = res[0]
            second = res[1][1] if len(res) > 1 else 0.0
            if top[0] == held["name"]:
                correct += 1
            else:
                confusion[(held["name"], top[0])] += 1
            if top[1] < thr:
                below += 1
            if top[1] - second < margin_lim:
                ambiguous += 1
    return total, correct, ambiguous, below, confusion


# ------------------------------------------------------------ perturbations ---

def split_at_corner(pts):
    rs = base.resample(smooth(pts))
    c = corner_indices(base.direction_angles(rs))
    if not c:
        return None
    return rs, c[0]


def set_second_leg_share(pts, share):
    """Rescale the part after the first corner so leg2/(leg1+leg2) == share."""
    sp = split_at_corner(pts)
    if sp is None:
        return None
    rs, c = sp
    leg1 = base.path_len(rs[:c + 1])
    leg2 = base.path_len(rs[c:])
    if leg1 <= 0 or leg2 <= 0:
        return None
    k = (share / (1 - share)) * leg1 / leg2
    cx, cy = rs[c]
    return rs[:c + 1] + [(cx + k * (p[0] - cx), cy + k * (p[1] - cy)) for p in rs[c + 1:]]


def add_tail(pts, dx, dy, n=6):
    """Append a short straight tail (e.g. a slight hook) to a stroke."""
    x, y = pts[-1]
    return pts + [(x + dx * (i + 1) / n, y + dy * (i + 1) / n) for i in range(n)]


def perturbed_report(shapes, cases):
    for label, (variant, tp) in VARIANTS.items():
        print(f"\n--- {label} ---")
        for cname, fingers, rival, gen in cases:
            g = next(x for x in shapes if x["name"] == cname and x["fingerCount"] == fingers)
            wins = 0; n = 0; margins = []; own = []
            for s in g["samples"]:
                pts = base.sample_path(s)
                p = gen(pts)
                if p is None:
                    continue
                res = rank(p, fingers, shapes, variant, tp)
                n += 1
                d = dict(res)
                own.append(d.get(cname, 0))
                margins.append(d.get(cname, 0) - d.get(rival, 0))
                if res and res[0][0] == cname and res[0][1] >= 0.60 and (len(res) < 2 or res[0][1] - res[1][1] >= 0.06):
                    wins += 1
            if n:
                print(f"  {cname:<14} vs {rival:<12} fires={wins}/{n}  own={sum(own)/n:.2f}  margin={min(margins):+.2f}..{max(margins):+.2f}")


def live_replay(shapes, live_path):
    """Replay live-strokes.jsonl: does each variant reproduce/fix the app's verdicts?"""
    recs = [json.loads(l) for l in open(live_path) if l.strip()]
    recs = [r for r in recs if r.get("outcome") in ("fire", "ambiguous", "nomatch")]
    print(f"=== Live replay: {len(recs)} discrete strokes from {live_path} ===")
    for label, (variant, tp) in VARIANTS.items():
        agree = 0; fixed = 0; broke = 0; changed = []
        for r in recs:
            paths = r["paths"]
            pi = r.get("primary", -1)
            prim = paths[pi] if 0 <= pi < len(paths) else max(paths, key=len)
            pts = [(p[0], p[1]) for p in prim]
            if len(pts) < 2:
                continue
            res = rank(pts, r["fingers"], shapes, variant, tp,
                       perf_paths=sorted(([(p[0], p[1]) for p in f] for f in paths if len(f) >= 2), key=lambda p: p[0][0]))
            top = res[0] if res else ("", 0.0)
            second = res[1][1] if len(res) > 1 else 0.0
            thr, mlim = (0.80, 0.0) if "gsign" in variant else (0.60, 0.06)
            verdict = "nomatch" if top[1] < thr else ("ambiguous" if top[1] - second < mlim else "fire")
            app_top = r["top"][0][0] if r.get("top") else ""
            truth = LABELS.get(r["t"])
            if truth is not None:
                # Ground truth known: judge against intent, not against the app.
                app_ok = r["outcome"] == "fire" and app_top == truth
                new_ok = verdict == "fire" and top[0] == truth
                if new_ok == app_ok:
                    agree += 1
                elif new_ok:
                    fixed += 1; changed.append(f"    LABEL {truth}: app {r['outcome']} {app_top} -> fire {top[0]} {top[1]:.2f}  FIXED")
                else:
                    broke += 1; changed.append(f"    LABEL {truth}: app {r['outcome']} {app_top} -> {verdict} {top[0]} {top[1]:.2f}  BROKE")
                continue
            same = verdict == r["outcome"] and (verdict != "fire" or top[0] == app_top)
            if same:
                agree += 1
            elif r["outcome"] != "fire" and verdict == "fire":
                fixed += 1; changed.append(f"    {r['outcome']:<9} -> fire {top[0]} {top[1]:.2f} (app top {app_top})")
            elif r["outcome"] == "fire" and verdict != "fire":
                broke += 1; changed.append(f"    fire {app_top} -> {verdict} ({top[0]} {top[1]:.2f})")
            elif r["outcome"] == "fire" and top[0] != app_top:
                broke += 1; changed.append(f"    fire {app_top} -> fire {top[0]} {top[1]:.2f}  ** different gesture **")
        print(f"\n--- {label}: agrees with app on {agree}/{len(recs)}; would fix {fixed}; would break {broke}")
        for c in changed[:12]:
            print(c)


def main():
    if "--live" in sys.argv:
        live = sys.argv[sys.argv.index("--live") + 1] if len(sys.argv) > sys.argv.index("--live") + 1 else \
            os.path.expanduser("~/Library/Application Support/TrackpadControl/live-strokes.jsonl")
        d = json.load(open(base.DEFAULT_PATH))
        items = [x for x in d if isinstance(x, dict)] if isinstance(d, list) else d["gestures"]
        shapes = [g for g in items if g.get("isEnabled") and g.get("inputType") not in base.SKIP_TYPES and g.get("samples")]
        live_replay(shapes, live)
        return
    path = sys.argv[1] if len(sys.argv) > 1 else base.DEFAULT_PATH
    d = json.load(open(path))
    items = [x for x in d if isinstance(x, dict)] if isinstance(d, list) else d["gestures"]
    shapes = [g for g in items if g.get("isEnabled") and g.get("inputType") not in base.SKIP_TYPES and g.get("samples")]

    print("=== Leave-one-out over recorded library (threshold 0.60, margin 0.06) ===")
    for label, (variant, tp) in VARIANTS.items():
        total, correct, amb, below, conf = loo(shapes, variant, tp)
        worst = ", ".join(f"{a}->{b} x{c}" for (a, b), c in sorted(conf.items(), key=lambda x: -x[1])[:3])
        print(f"{label:<28} top1={correct}/{total}  ambiguous={amb}  below-thr={below}  {worst}")

    print("\n=== Real recordings perturbed like the live failures ===")
    print("fires = would fire correctly (top-1, >=0.60, margin>=0.06); margin = own score - rival score")
    cases = []
    for share in (0.10, 0.12, 0.15, 0.20):
        cases.append((f"Kopy", 3, "Mission C", lambda p, s=share: set_second_leg_share(p, s)))
        cases.append((f"Window - BRQ", 4, "Close tab", lambda p, s=share: set_second_leg_share(p, s)))
    cases.append(("Kopy", 3, "Mission C", lambda p: set_second_leg_share(p, 0.55)))
    cases.append(("Window - BRQ", 4, "Close tab", lambda p: set_second_leg_share(p, 0.55)))
    # Straight strokes with a slight accidental hook must stay straight.
    cases.append(("Mission C", 3, "Kopy", lambda p: add_tail(p, 0.03, 0.0)))
    cases.append(("Close tab", 4, "Window - BRQ", lambda p: add_tail(p, 0.03, 0.0)))
    # Fast strokes: same shape, 2x / 3x fewer samples (live strokes are 25-55% faster than recordings).
    for step in (2, 3):
        for cname, f, rival in (("Kopy", 3, "Mission C"), ("Window - BRQ", 4, "Close tab"), ("Mission C", 3, "Kopy"), ("Close tab", 4, "Window - BRQ")):
            cases.append((cname, f, rival, lambda p, s=step: p[::s] if len(p) // s >= 4 else None))
    labels = [f"leg2={s:.0%}" for s in (0.10, 0.12, 0.15, 0.20)]
    for label, (variant, tp) in VARIANTS.items():
        print(f"\n--- {label} ---")
        i = 0
        for cname, fingers, rival, gen in cases:
            g = next(x for x in shapes if x["name"] == cname and x["fingerCount"] == fingers)
            wins = n = 0; margins = []; own = []
            for s in g["samples"]:
                p = gen(base.sample_path(s))
                if p is None:
                    continue
                res = rank(p, fingers, shapes, variant, tp)
                n += 1
                dd = dict(res)
                own.append(dd.get(cname, 0)); margins.append(dd.get(cname, 0) - dd.get(rival, 0))
                if res and res[0][0] == cname and res[0][1] >= 0.60 and (len(res) < 2 or res[0][1] - res[1][1] >= 0.06):
                    wins += 1
            if i < 8:
                tag = labels[i // 2]
            elif i < 10:
                tag = "leg2=55%"
            elif i < 12:
                tag = "straight+hook"
            else:
                tag = f"fast x{2 if i < 16 else 3}"
            i += 1
            if n:
                print(f"  {tag:<14} {cname:<14} vs {rival:<12} fires={wins}/{n}  own={sum(own)/n:.2f}  margin={min(margins):+.2f}..{max(margins):+.2f}")


if __name__ == "__main__":
    main()
