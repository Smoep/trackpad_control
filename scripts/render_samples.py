#!/usr/bin/env python3
"""Render every sample of the given gestures to one SVG contact sheet.

All samples share one scale (trackpad units), y is up, only the finger the
matcher uses (longest path) is drawn. Samples whose leave-one-out score against
their own siblings is below --flag (default 0.60) get a red frame.

Usage: python3 scripts/render_samples.py "Windows - C" "Open Safari" [--flag 0.6] [-o out.svg]
"""
import json, math, os, sys

sys.path.insert(0, os.path.dirname(__file__))
saved, sys.argv = sys.argv, ["x"]
import recognizer_eval as R  # noqa: E402
sys.argv = saved

CELL, PAD = 150, 12
ASPECT = 1.0  # trackpad units are already normalised 0..1 on both axes

def loo_scores(held, shapes):
    out = []
    for hi, hs in enumerate(held["samples"]):
        pts = R.sample_path(hs)
        if len(pts) < 2:
            out.append(0.0); continue
        pa = R.direction_angles(R.resample(pts)); ptn = R.count_turns(pa)
        own = 0.0
        for si, s in enumerate(held["samples"]):
            if si == hi:
                continue
            sp = R.sample_path(s)
            if len(sp) >= 2:
                own = max(own, R.score(pa, ptn, sp, pts))
        out.append(own)
    return out

def main():
    args = [a for a in saved[1:] if not a.startswith("-")]
    flag = float(saved[saved.index("--flag") + 1]) if "--flag" in saved else 0.60
    out = saved[saved.index("-o") + 1] if "-o" in saved else "/tmp/samples.svg"
    names = [a for a in args if a != out and not a.replace(".", "").isdigit()]
    d = json.load(open(R.DEFAULT_PATH))
    items = [x for x in d if isinstance(x, dict)] if isinstance(d, list) else d["gestures"]
    shapes = [g for g in items if g.get("samples") and g["name"] in names]

    # common scale: largest bbox side across all drawn samples
    span = 0.01
    for g in shapes:
        for s in g["samples"]:
            pts = R.sample_path(s)
            xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
            span = max(span, max(xs) - min(xs), max(ys) - min(ys))
    k = (CELL - 2 * PAD) / span

    rows = []
    for g in shapes:
        rows.append((g, loo_scores(g, shapes)))
    ncols = max(len(g["samples"]) for g, _ in rows)
    W = ncols * CELL; H = len(rows) * (CELL + 24)
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" font-family="Menlo" font-size="11">',
           '<rect width="100%" height="100%" fill="white"/>']
    for r, (g, scores) in enumerate(rows):
        y0 = r * (CELL + 24)
        svg.append(f'<text x="6" y="{y0+14}" font-size="13" font-weight="bold">{g["name"]}  (f{g["fingerCount"]}, scale bar = 0.10)</text>')
        for c, s in enumerate(g["samples"]):
            pts = R.sample_path(s)
            x0 = c * CELL; cy0 = y0 + 24
            xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
            cx = (min(xs) + max(xs)) / 2; cyc = (min(ys) + max(ys)) / 2
            def tx(p):
                return (x0 + CELL / 2 + (p[0] - cx) * k, cy0 + CELL / 2 - (p[1] - cyc) * k)
            low = scores[c] < flag
            svg.append(f'<rect x="{x0+2}" y="{cy0+2}" width="{CELL-4}" height="{CELL-4}" fill="none" stroke="{"red" if low else "#ccc"}" stroke-width="{3 if low else 1}"/>')
            path = " ".join(("M" if i == 0 else "L") + f"{x:.1f},{y:.1f}" for i, (x, y) in enumerate(map(tx, pts)))
            svg.append(f'<path d="{path}" fill="none" stroke="#1565c0" stroke-width="2"/>')
            sx, sy = tx(pts[0]); ex, ey = tx(pts[-1])
            svg.append(f'<circle cx="{sx:.1f}" cy="{sy:.1f}" r="4" fill="green"/>')
            svg.append(f'<circle cx="{ex:.1f}" cy="{ey:.1f}" r="4" fill="red"/>')
            svg.append(f'<line x1="{x0+PAD}" y1="{cy0+CELL-8}" x2="{x0+PAD+0.10*k:.1f}" y2="{cy0+CELL-8}" stroke="black" stroke-width="2"/>')
            svg.append(f'<text x="{x0+8}" y="{cy0+16}" fill="{"red" if low else "black"}">s{c}  own-score {scores[c]:.2f}</text>')
    svg.append("</svg>")
    open(out, "w").write("\n".join(svg))
    print("wrote", out)

if __name__ == "__main__":
    main()
