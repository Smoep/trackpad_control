#!/usr/bin/env python3
"""Contact sheet of live strokes (from live-strokes.jsonl) for labelling intent.

Draws the primary finger path to a common scale, y up, green start / red end,
with the app's verdict and top-2 scores. Default selection: every non-fire stroke
plus fires whose top-2 margin is below --margin (default 0.10).

Usage: python3 scripts/render_live.py [-o /tmp/live.svg] [--margin 0.10] [--all]
"""
import json, os, sys, time

BASE = os.path.expanduser("~/Library/Application Support/TrackpadControl/live-strokes.jsonl")
CELL, PAD = 170, 12

def main():
    argv = sys.argv
    out = argv[argv.index("-o") + 1] if "-o" in argv else "/tmp/live.svg"
    margin = float(argv[argv.index("--margin") + 1]) if "--margin" in argv else 0.10
    rows = [json.loads(l) for l in open(BASE) if l.strip()]
    rows = [r for r in rows if r["outcome"] != "tap" and r.get("paths")]
    if "--t" in argv:
        want = {float(x) for x in argv[argv.index("--t") + 1].split(",")}
        rows = [r for r in rows if r["t"] in want]
    elif "--all" not in argv:
        rows = [r for r in rows if r["outcome"] != "fire"
                or (len(r["top"]) > 1 and r["top"][0][1] - r["top"][1][1] < margin)]
    pts_of = lambda r: [(p[0], p[1]) for p in r["paths"][r["primary"] if 0 <= r["primary"] < len(r["paths"]) else 0]]
    span = 0.05
    for r in rows:
        pts = pts_of(r)
        xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
        span = max(span, max(xs) - min(xs), max(ys) - min(ys))
    k = (CELL - 2 * PAD) / span
    ncols = 4
    nrows = (len(rows) + ncols - 1) // ncols
    W = ncols * CELL; H = nrows * (CELL + 30)
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" font-family="Menlo" font-size="10">',
           '<rect width="100%" height="100%" fill="white"/>']
    for i, r in enumerate(rows):
        pts = pts_of(r)
        c, rr = i % ncols, i // ncols
        x0 = c * CELL; y0 = rr * (CELL + 30)
        xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
        cx = (min(xs) + max(xs)) / 2; cy = (min(ys) + max(ys)) / 2
        tx = lambda p: (x0 + CELL / 2 + (p[0] - cx) * k, y0 + 30 + CELL / 2 - (p[1] - cy) * k)
        svg.append(f'<rect x="{x0+2}" y="{y0+30}" width="{CELL-4}" height="{CELL-4}" fill="none" stroke="#bbb"/>')
        path = " ".join(("M" if j == 0 else "L") + f"{x:.1f},{y:.1f}" for j, (x, y) in enumerate(map(tx, pts)))
        svg.append(f'<path d="{path}" fill="none" stroke="#1565c0" stroke-width="2"/>')
        sx, sy = tx(pts[0]); ex, ey = tx(pts[-1])
        svg.append(f'<circle cx="{sx:.1f}" cy="{sy:.1f}" r="4" fill="green"/><circle cx="{ex:.1f}" cy="{ey:.1f}" r="4" fill="red"/>')
        ts = time.strftime("%m-%d %H:%M", time.localtime(r["t"]))
        top = " / ".join(f'{n.replace("Window - ","").replace("Windows - ","")[:9]} {s:.2f}' for n, s in r["top"][:2]) or "(no candidates)"
        svg.append(f'<text x="{x0+6}" y="{y0+12}" font-weight="bold">#{i+1} {ts} f{r["fingers"]} {r["outcome"]}</text>')
        svg.append(f'<text x="{x0+6}" y="{y0+24}">{top}</text>')
        svg.append(f'<line x1="{x0+PAD}" y1="{y0+30+CELL-8}" x2="{x0+PAD+0.10*k:.1f}" y2="{y0+30+CELL-8}" stroke="black" stroke-width="2"/>')
    svg.append("</svg>")
    open(out, "w").write("\n".join(svg))
    print("wrote", out, "strokes:", len(rows))

if __name__ == "__main__":
    main()
