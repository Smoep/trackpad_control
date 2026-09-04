#!/usr/bin/env python3
"""End-to-end pipeline replay: stage-1 lock rule x stage-2 matcher variant.

Answers "which build gives the highest matching numbers?" on real data only:
  recordings (leave-one-out, 3f + 4f) and live-strokes.jsonl (3f + 4f).
Configs: locks current/candidate x matcher baseline / +netgate / +corner / +both.

Usage: python3 scripts/pipeline_eval.py [--verbose]
"""
import json, os, sys

sys.path.insert(0, os.path.dirname(__file__))
_argv = sys.argv; sys.argv = ["x"]
import recognizer_eval as base   # noqa: E402
import matcher_experiment as M   # noqa: E402
import lock_gate_experiment as L # noqa: E402
sys.argv = _argv

BASE = os.path.expanduser("~/Library/Application Support/TrackpadControl")
THR, MARGIN = 0.60, 0.06
LOCKS = {3: "Cycle Windows", 4: "Window - Horizontal Tiling - 4f"}
MATCHERS = {
    "baseline":        "plain",
    "+netgate":        "plain+netgate",
    "+corner":         "plain+corner",
    "+netgate+corner": "plain+netgate+corner",
}


def lock(fingers, pts, ts, end_t, candidate):
    if fingers == 3:
        return L.cycle_lock(pts, candidate)
    if fingers == 4:
        return L.tiling_lock(pts, ts, candidate, end_t)
    return None


def verdict(res):
    if not res:
        return "nomatch", ("", 0.0)
    top = res[0]; second = res[1][1] if len(res) > 1 else 0.0
    if top[1] < THR:
        return "nomatch", top
    if top[1] - second < MARGIN:
        return "ambiguous", top
    return "fire", top


def recordings(shapes, probe, cand_lock, variant, verbose):
    ok = stolen = wrong = amb = nm = total = 0
    lines = []
    for g in shapes + probe:
        f = g["fingerCount"]
        want = LOCKS.get(f) if g["name"] == "Probe CW" else g["name"]
        for hi, hs in enumerate(g["samples"]):
            pts = base.sample_path(hs)
            if len(pts) < 2:
                continue
            total += 1
            if lock(f, pts, L.sample_times(hs), L.sample_end(hs), cand_lock) is not None:
                got = LOCKS.get(f)
                if got == want: ok += 1
                else:
                    stolen += 1; lines.append(f"    {g['name']} #{hi}: stolen by {got}")
                continue
            if g["name"] == "Probe CW":
                wrong += 1; lines.append(f"    Probe CW #{hi}: NOT locked (reached matcher)")
                continue
            v, top = verdict(M.rank(pts, f, shapes, variant, 0.15, exclude=(g, hi)))
            if v == "fire" and top[0] == want: ok += 1
            elif v == "fire":
                wrong += 1; lines.append(f"    {g['name']} #{hi}: fired {top[0]} {top[1]:.2f}")
            elif v == "ambiguous": amb += 1
            else: nm += 1
    return dict(total=total, ok=ok, stolen=stolen, wrong=wrong, amb=amb, nm=nm), lines


def live(shapes, rows, cand_lock, variant, verbose):
    agree = fixed = broke = newly_stolen = 0
    lines = []
    for r in rows:
        f = r["fingers"]
        pp = r["paths"][r["primary"]]
        pts = [(p[0], p[1]) for p in pp]; ts = [p[2] for p in pp]
        end_t = min(path[-1][2] for path in r["paths"] if path)
        # live strokes all reached the matcher in the app; only a candidate lock can take them
        if cand_lock and lock(f, pts, ts, end_t, True) is not None and lock(f, pts, ts, end_t, False) is None:
            newly_stolen += 1; lines.append(f"    {r['t']} f{f} {r['outcome']} {r['top'][:1]} -> stolen by {LOCKS[f]}")
            continue
        v, top = verdict(M.rank(pts, f, shapes, variant, 0.15))
        app_top = r["top"][0][0] if r.get("top") else ""
        truth = M.LABELS.get(r["t"])
        if truth is not None:
            app_ok = r["outcome"] == "fire" and app_top == truth
            new_ok = v == "fire" and top[0] == truth
            if new_ok == app_ok: agree += 1
            elif new_ok: fixed += 1; lines.append(f"    LABEL {truth}: app {r['outcome']} {app_top} -> fire {top[0]} {top[1]:.2f} FIXED")
            else: broke += 1; lines.append(f"    LABEL {truth}: app {r['outcome']} {app_top} -> {v} {top[0]} {top[1]:.2f} BROKE")
            continue
        same = v == r["outcome"] and (v != "fire" or top[0] == app_top)
        if same: agree += 1
        elif r["outcome"] != "fire" and v == "fire":
            fixed += 1; lines.append(f"    {r['t']} {r['outcome']} -> fire {top[0]} {top[1]:.2f} (app top {app_top})")
        elif r["outcome"] == "fire" and v != "fire":
            broke += 1; lines.append(f"    {r['t']} fire {app_top} -> {v} ({top[0]} {top[1]:.2f})")
        elif r["outcome"] == "fire" and top[0] != app_top:
            broke += 1; lines.append(f"    {r['t']} fire {app_top} -> fire {top[0]} ** different gesture **")
        else:
            agree += 1  # nomatch<->ambiguous: neither fires
    return dict(n=len(rows), agree=agree, fixed=fixed, broke=broke, stolen=newly_stolen), lines


def main():
    verbose = "--verbose" in _argv
    d = json.load(open(os.path.join(BASE, "gestures.json")))
    items = [x for x in d if isinstance(x, dict)] if isinstance(d, list) else d["gestures"]
    shapes = [g for g in items if g.get("isEnabled") and g.get("inputType") not in base.SKIP_TYPES
              and g.get("samples") and g["fingerCount"] in (3, 4)]
    probe = [g for g in items if g["name"] == "Probe CW"]
    rows = [json.loads(l) for l in open(os.path.join(BASE, "live-strokes.jsonl")) if l.strip()]
    rows = [r for r in rows if r["fingers"] in (3, 4) and r["outcome"] != "tap" and r.get("paths")]
    n_rec = sum(1 for g in shapes + probe for s in g["samples"] if len(base.sample_path(s)) >= 2)
    print(f"recordings: {n_rec} samples (3f+4f, LOO, incl. 7 Probe CW swipes); live: {len(rows)} 3f+4f strokes")
    print(f"{'locks':10} {'matcher':16} | {'REC ok':>6} {'stolen':>6} {'wrong':>5} {'amb':>4} {'nomatch':>7} | {'LIVE agree':>10} {'fix':>4} {'break':>5} {'stolen':>6}")
    for lock_label, cand in (("current", False), ("candidate", True)):
        for m_label, variant in MATCHERS.items():
            R, rl = recordings(shapes, probe, cand, variant, verbose)
            V, vl = live(shapes, rows, cand, variant, verbose)
            print(f"{lock_label:10} {m_label:16} | {R['ok']:>3}/{R['total']:<3} {R['stolen']:>6} {R['wrong']:>5} {R['amb']:>4} {R['nm']:>7} | "
                  f"{V['agree']:>4}/{V['n']:<4} {V['fixed']:>4} {V['broke']:>5} {V['stolen']:>6}")
            if verbose:
                for x in rl + vl: print(x)


if __name__ == "__main__":
    main()
