#!/usr/bin/env python3
"""Offline recognizer accuracy harness.

Mirrors GestureMatcher.swift exactly (resample -> direction angles ->
angular similarity + turn penalty, best-over-samples) and runs leave-one-out
over the recorded samples in gestures.json. Reports per-gesture and overall
accuracy plus the worst confusion pairs. NO app behavior change; read-only.

Usage:
  python3 scripts/recognizer_eval.py [path-to-gestures.json] [--threshold 0.80]
"""
import json, math, sys, os
from collections import defaultdict

DEFAULT_PATH = os.path.expanduser("~/Library/Application Support/TrackpadControl/gestures.json")
POINT_COUNT = 64
TURN_PENALTY = 0.15  # per extra turn (matches GestureMatcher)
SKIP_TYPES = {"Zone Tap", "Continuous"}


def dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def path_len(pts):
    return sum(dist(pts[i - 1], pts[i]) for i in range(1, len(pts)))


def resample(points, count=POINT_COUNT):
    if len(points) < 2:
        return points
    total = path_len(points)
    if total <= 0:
        return points
    interval = total / (count - 1)
    src = [list(p) for p in points]
    out = [src[0]]
    acc = 0.0
    j = 1
    while j < len(src) and len(out) < count:
        prev, curr = src[j - 1], src[j]
        seg = dist(prev, curr)
        if acc + seg >= interval:
            r = (interval - acc) / seg if seg else 0
            nx = prev[0] + r * (curr[0] - prev[0])
            ny = prev[1] + r * (curr[1] - prev[1])
            pt = [nx, ny]
            out.append(pt)
            src.insert(j, pt)
            acc = 0.0
            j += 1
        else:
            acc += seg
            j += 1
    while len(out) < count:
        out.append(out[-1])
    return out[:count]


def direction_angles(points):
    angles = []
    for i in range(1, len(points)):
        dx = points[i][0] - points[i - 1][0]
        dy = points[i][1] - points[i - 1][1]
        a = math.atan2(dy, dx)
        if a < 0:
            a += 2 * math.pi
        angles.append(a)
    return angles


def angular_similarity(a, b):
    n = min(len(a), len(b))
    if n == 0:
        return 0.0
    total = 0.0
    for i in range(n):
        diff = abs(a[i] - b[i])
        if diff > math.pi:
            diff = 2 * math.pi - diff
        total += diff
    return max(0.0, 1.0 - (total / n) / math.pi)


def count_turns(angles):
    if len(angles) < 4:
        return 0
    w = max(3, len(angles) // 12)
    sm = []
    for i in range(len(angles)):
        s, e = max(0, i - w // 2), min(len(angles), i + w // 2 + 1)
        sx = sum(math.cos(angles[j]) for j in range(s, e))
        sy = sum(math.sin(angles[j]) for j in range(s, e))
        sm.append(math.atan2(sy / (e - s), sx / (e - s)))
    th = math.radians(40)
    turns, step, last = 0, max(1, len(sm) // 16), sm[0]
    for i in range(step, len(sm), step):
        diff = abs(sm[i] - last)
        if diff > math.pi:
            diff = 2 * math.pi - diff
        if diff > th:
            turns += 1
            last = sm[i]
    return turns


def sample_path(s):
    fps = s.get("fingerPaths") or []
    if len(fps) > 1:
        best = max(fps, key=len)
        return [(p["x"], p["y"]) for p in best]
    return [(p["x"], p["y"]) for p in (s.get("pathPoints") or [])]


# --- $P point-cloud recognizer (whole-shape match) ---------------------------
# Resample, scale to unit box, translate to origin centroid, then greedy
# point-cloud distance. Position/scale independent; order tolerant.

def normalize_cloud(pts, n=32):
    rs = resample(pts, n)
    xs = [p[0] for p in rs]; ys = [p[1] for p in rs]
    w = max(xs) - min(xs); h = max(ys) - min(ys)
    scale = max(w, h) or 1.0
    rs = [((p[0] - min(xs)) / scale, (p[1] - min(ys)) / scale) for p in rs]
    cx = sum(p[0] for p in rs) / len(rs); cy = sum(p[1] for p in rs) / len(rs)
    return [(p[0] - cx, p[1] - cy) for p in rs]


def cloud_distance(a, b):
    matched = [False] * len(b)
    total = 0.0
    for i, pa in enumerate(a):
        wgt = 1.0 - i / len(a)
        bestd, bestj = 1e9, -1
        for j, pb in enumerate(b):
            if matched[j]:
                continue
            d = math.hypot(pa[0] - pb[0], pa[1] - pb[1])
            if d < bestd:
                bestd, bestj = d, j
        if bestj >= 0:
            matched[bestj] = True
            total += wgt * bestd
    return total


def cloud_score(a, b):
    d = (cloud_distance(a, b) + cloud_distance(b, a)) / 2
    return max(0.0, 1.0 - d / (len(a) * 0.5))


def score(perf_angles, perf_turns, samp_pts):
    rs = resample(samp_pts)
    sa = direction_angles(rs)
    if not sa:
        return 0.0
    sim = angular_similarity(perf_angles, sa)
    pen = max(0.0, 1.0 - abs(perf_turns - count_turns(sa)) * TURN_PENALTY)
    return sim * pen


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    path = args[0] if args else DEFAULT_PATH
    thr = 0.80
    if "--threshold" in sys.argv:
        thr = float(sys.argv[sys.argv.index("--threshold") + 1])
    d = json.load(open(path))
    items = [x for x in d if isinstance(x, dict)] if isinstance(d, list) else d["gestures"]
    shapes = [g for g in items if g.get("isEnabled") and g.get("inputType") not in SKIP_TYPES and (g.get("samples"))]

    for method in ("angular", "cloud"):
        total = correct = confident = ambiguous = 0
        per = defaultdict(lambda: [0, 0])
        confusion = defaultdict(int)
        for held in shapes:
            for hi, hs in enumerate(held["samples"]):
                pts = sample_path(hs)
                if len(pts) < 2:
                    continue
                if method == "angular":
                    pa = direction_angles(resample(pts)); ptn = count_turns(pa)
                else:
                    pc = normalize_cloud(pts)
                results = []
                for g in shapes:
                    if g["fingerCount"] != held["fingerCount"]:
                        continue
                    best = 0.0
                    for si, s in enumerate(g["samples"]):
                        if g is held and si == hi:
                            continue
                        sp = sample_path(s)
                        if len(sp) < 2:
                            continue
                        if method == "angular":
                            best = max(best, score(pa, ptn, sp))
                        else:
                            best = max(best, cloud_score(pc, normalize_cloud(sp)))
                    if best > 0:
                        results.append((g["name"], best))
                results.sort(key=lambda r: -r[1])
                total += 1
                per[held["name"]][1] += 1
                if not results:
                    continue
                top = results[0]
                margin = top[1] - (results[1][1] if len(results) > 1 else 0)
                if top[1] >= thr:
                    confident += 1
                if margin < 0.06:
                    ambiguous += 1
                if top[0] == held["name"]:
                    correct += 1; per[held["name"]][0] += 1
                else:
                    confusion[(held["name"], top[0])] += 1
        print(f"\n=== method: {method} ===")
        print(f"top-1 accuracy:   {correct}/{total} = {100*correct/max(total,1):.1f}%")
        print(f"confident (>= {thr}): {confident}   ambiguous(margin<0.06): {ambiguous}")
        print("worst confusions:")
        for (truth, pred), c in sorted(confusion.items(), key=lambda x: -x[1])[:6]:
            print(f"  {truth:22} -> {pred:22} x{c}")


if __name__ == "__main__":
    main()
