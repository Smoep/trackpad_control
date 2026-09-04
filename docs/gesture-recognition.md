# Gesture Recognition — Logic & Calculations

Reference for how Trackpad Control captures and recognizes discrete shape gestures.
Last validated: 2026-06-29.

## 1. Pipeline overview

```
raw touches → capture per finger → pick path → smooth → resample → direction angles → score → fire
```

Differentiation order: **finger count first, then shape.** Two gestures with different
finger counts never compete; shape matching only happens within one finger-count bucket.

## 2. Capture (`TouchCaptureManager`)

- Reads raw multitouch frames (private MultitouchSupport framework).
- Each finger accumulates its own `PathPoint` list; all kept in `fingerPaths`.
- Gesture completes when **all fingers lift**. Staggered liftoff is bridged by a
  0.3 s completion timer; a new touch finalizes the pending gesture first.
- Layer gating: each finger count (1–5) can require a modifier key (or "Always On"),
  checked at start and re-verified at completion.

## 3. Stored sample data

Samples are **raw**, not summarized. Each sample stores:
- `fingerPaths` — full path of every finger (~85–90 pts each for a 4-finger swipe)
- `pathPoints` — combined/primary path
- `fingerCount`, `duration`, `createdAt`, `id`

The matcher uses the **longest single finger path** (centroid is not used).

## 4. Shape matching (`GestureMatcher`, `GestureNormalizer`)

1. **Smooth** — moving-average, window = 9 points (`GestureNormalizer.smooth`).
   Cancels per-finger jitter; applied to both live path and stored samples.
2. **Resample** — 64 evenly-spaced points along path length.
3. **Direction angles** — sequence of movement directions. Position/scale independent.
4. **Angular similarity** — compared index-by-index against every sample; best wins.
5. **Turn penalty** — score × (1 − 0.15 × |turnDiff|); penalizes shapes with a
   different number of direction changes.
6. **Best-of-samples** — a gesture's score = its best-scoring sample.
7. **Fire** if top score ≥ `discreteConfidence` (~0.80) and margin over #2 ≥
   `discreteAmbiguityMargin` (0.06); otherwise suppressed as ambiguous.

## 4a. The actual formulas

Let a path be points $P_0 \ldots P_{n-1}$, each $P_i=(x_i,y_i)$.

**Smoothing** (moving average, window $w=9$, half $h=4$):
$$x'_i=\frac{1}{|S|}\sum_{j\in S}x_j,\quad S=[\max(0,i-h),\,\min(n-1,i+h)]$$
(same for $y$). Timestamp preserved. No-op if $n<3$.

**Path length:**
$$L=\sum_{i=1}^{n-1}\sqrt{(x_i-x_{i-1})^2+(y_i-y_{i-1})^2}$$

**Resample** to $N=64$ points spaced $L/(N-1)$ apart. Walks segments, linearly
interpolating where the accumulated distance crosses an interval boundary, and
inserts that point back into the source so spacing stays even.

**Direction angles** (one per segment). $N=64$ points yield $M=N-1=63$ angles:
$$\theta_i=\operatorname{atan2}(y_i-y_{i-1},\,x_i-x_{i-1}),\quad i=1,\ldots,N-1,\ \ +2\pi\text{ if negative}$$

**Angular similarity** between performed $a$ and sample $b$ (both length $M$, index-aligned):
$$d_i=|a_i-b_i|,\ \text{wrapped to}\ \min(d_i,2\pi-d_i);\qquad
\bar d=\frac{1}{M}\sum_{i=1}^{M} d_i;\qquad \text{sim}=\max\!\Big(0,\,1-\tfrac{\bar d}{\pi}\Big)$$
So identical direction → 1.0, opposite → 0.0. (Code divides by the actual angle
count $M$, via `min(a.count, b.count)` — not by $N$ — so no off-by-one in scoring.)

**Turn count** (structural complexity): angles circularly smoothed (window $\approx n/12$)
via $\operatorname{atan2}(\overline{\sin},\overline{\cos})$, then a turn is counted each
time direction shifts $>40°$, sampled every $\approx n/16$ steps.

**Turn penalty + final score:**
$$\text{score}=\text{sim}\times\max\!\big(0,\,1-0.15\cdot|\,\text{turns}_a-\text{turns}_b|\big)$$

**Gesture score** = max over its samples. **Fire** if best $\ge 0.80$ and
(best − second) $\ge 0.06$.

## 5. Key parameters

| Parameter | Value | Where |
|---|---|---|
| smoothing window | 9 | `GestureNormalizer.smoothingWindow` |
| resample points | 64 | `GestureNormalizer.defaultPointCount` |
| turn penalty | 0.15 / turn | `GestureMatcher` |
| discrete confidence | 0.80 | `RecognitionSettings` |
| ambiguity margin | 0.06 | `RecognitionSettings` |

## 6. Measured accuracy (leave-one-out, offline harness)

`scripts/recognizer_eval.py`, natural gestures (AB family excluded):

| Change | Accuracy |
|---|---|
| baseline (sparse samples) | 66.7% |
| + more samples per gesture | 86.9% (97% natural) |
| + smoothing window 9 | **100% natural / 94.5% all** |

Notes: confused pairs were BRQ↔Close tab and Max↔TRQ — both fixed by smoothing.
Whole-shape "cloud" prototype scored worse (64%); angular matcher retained.
Sample counts and smoothing were the proven levers; centroid not adopted.

## 7. Live-stroke corpus (added 2026-09-03) — evaluate against real strokes, not recordings

Leave-one-out over the *recorded* library reached 98.3% while live use still showed
~10% failures (46 no-match, 22 ambiguous in 601 fires). The library is clean; the
failures are the tail of live variation (e.g. Kopy = up-then-right with the right leg
at 12–18% of the path instead of the recorded ~30%). Synthetic perturbations of
recordings were **misleading**: a corner-first (leg-normalized) matcher looked like a
clear win on them, yet scored a real live BRQ at 0.57 where the app scored 0.845.

With diagnostics on, every discrete/tap stroke is appended to
`~/Library/Application Support/TrackpadControl/live-strokes.jsonl`:
`{t, fingers, outcome: fire|ambiguous|nomatch|tap, primary, top:[[name,score]…], paths:[[[x,y,t]…]…]}`.

- Replay any matcher variant: `python3 scripts/matcher_experiment.py --live`
  (reports agree / would-fix / would-break per variant; harness scores match the app within ~0.02).
- Rule: a matcher change ships only if it fixes real failures in the corpus without
  breaking real fires. Never from LOO or perturbation results alone.

Other verified facts from that investigation:
- Trackpad aspect (~1.6) is not the problem; correcting for it made things worse.
- Stroke speed (2–3× fewer samples) is handled fine by the current smoothing.
- Thumbnails previously stretched X and Y independently (`autoFit`), making every
  L look equal-legged; now uniform scale.
- The scroll "bleed" behind 3-finger gestures was macOS **momentum** after lift, not
  the active phase; measured with `scripts/scroll_listener.swift` (listen-only tap
  downstream of the app). Fixed by swallowing a blocked sequence through momentum end.

## 8. 2026-09-04 investigation — circles not recognised, matcher ladder, GestureSign

Status: **all findings below are offline-validated; nothing is built or shipped yet.**

### 8.1 Circles (Open Safari / Open Chrome, 3 fingers) — cause is stage 1, not the matcher
- The recordings are fine and distinct (opposite rotation; LOO Safari 0.86–0.97, Chrome
  0.65–0.82, never confused with each other; one Safari take is a double loop at 0.54).
- Live, 20 of 37 three-finger touches were claimed by the continuous **Cycle Windows**
  gesture ~120–400 ms in (`NAV-LOCK … accepted=true`, then `[WINCYCLE]` cycling). The
  matcher never saw them. Replaying the lock rule on the 10 recordings: **all 10 would be
  stolen** at 0.21–0.43 s.
- Cycle Windows lock rule is far looser than other nav controls
  (`ratio ≥ 1.35, maxOff ≤ 0.38` vs `ratio ≥ 2.0, maxOff ≤ 0.12`,
  TouchCaptureManager ~L739) and the CONT-SHAPE-GUARD is skipped for navigation controls.
- Ground truth for a real cycle swipe = "Probe CW" (7 recordings, disabled, still in the
  library): 0.22–0.43 s, ~0.18 left, peak off-axis ≤ 0.018, app-turn ≤ 0.52, locks at
  0.09–0.18 s. Circles at the lock moment: off-axis 0.13–0.22, turn 2.2–5.7.
- **Candidate fix** (replayed in `scripts/lock_gate_experiment.py --live`): add
  `maxOffAxis ≤ 0.10 && cumulativeTurn ≤ 2.0` to the cycleWindows lock. Result on all
  3-finger recordings: 29/40 → 39/40 correct end-to-end; circles 0/10 → 9/10; Probe CW
  locks at the same frame (no latency cost); 0 of 52 live 3-finger strokes change.
  Unreachable for 1/2/4/5 fingers (candidates are filtered by finger count).
- Radial (3f) is up-then-left, an L — not curved. Earlier "curved" claim was wrong.

### 8.2 Intent labels for live strokes (user, 2026-09-04)
Stored in `scripts/matcher_experiment.py` `LABELS` (keyed by stroke `t`):
#1 10:47 BLQ (app ambiguous), #5 15:22:52 **BLQ — app fired Close tab 0.87, wrong**,
#6 15:22:54 BLQ (app right), #7 15:23:50 TRQ (app ambiguous), #10 23:56 LD (app ambiguous).
#2/#3 (tiny) were a continuous attempt, #8 (up-down-up) is not a gesture. All real failures
are "L read as too straight". Sheet: `scripts/render_live.py` → SVG → `qlmanage -t`.

### 8.3 Matcher findings
- **Net-direction factor** (weight 2.0, start→end vector) zeroes there-and-back strokes:
  Windows-C takes score 0.00 against each other (14 zeros in the 6×6 matrix) because the
  0.01–0.06 net vector points randomly. Same factor drops Safari s4 to 0.54. It is NOT
  simply bad: removing it flips two live BRQ fires to LD (unlabelled — ask). `netgate`
  (skip the factor when both paths have openness < 0.15) repairs Windows-C/Safari s4 with
  zero change on the live corpus.
- **Corner tie-break**: only when top-2 within 0.12 and their typical corner counts differ
  (Close tab 0, BLQ 1, TRQ 1, Max 0, Kopy 1, Mission C 0, LD 3–4); live corner count decides,
  loser ×0.80. "Corner" = heading change ≥ 40° over a 15% window with ≥ 10% of path after it
  (two Close-tab takes have a 1–4° curve/hook that must not count). Result: 4/4 wrong
  labelled strokes fixed, #6 unchanged, 0 of the other 114 live strokes change, LOO
  ambiguous 3 → 0, no new confusion.
- **GestureSign** (TransposonY, C#): resample to 100 segments, mean heading delta,
  probability = 1 − delta/π, fire top-1 if ≥ 0.80, no margin, no smoothing, no turn/net/
  open-closed factors; multi-finger = each finger vs its own path. Ported into
  `matcher_experiment.py` (`gsign-*`) and stepped in `scripts/matcher_ladder.py` (A→G).
  On our data: bare scoring ranks L-shapes slightly better but compresses scores to
  0.75–0.98, so junk strokes (#2, #3, up-down-up) score 0.82–0.90 and would FIRE (tiny #3 →
  TRQ). Our extras are what push junk to ≤ 0.56. No bare variant reaches 5/5 labels without
  a cost. Conclusion: **do not swap to GestureSign; keep ours + netgate + corner tie-break.**
- Thumbnails show only the first sample, auto-fitted, no start/end marker — a 0.06
  end-height shift or a bounce is invisible. `scripts/render_samples.py "Name" …` renders
  every sample to one scale with red frames on low own-score takes.

### 8.4 Build 2026-09-04 16:24 (approved, deployed, awaiting live validation)
Owner asked "which build gives the highest matching numbers" — measured end-to-end with
`scripts/pipeline_eval.py` (lock rule → matcher, recordings LOO 3f+4f = 110 samples incl.
7 real cycle swipes; live corpus 123 3f+4f strokes):

```
locks      matcher          | REC ok  stolen wrong amb nomatch | LIVE agree fix break
current    baseline (was)   |  93/110   15     0    1    1     | 122/123   0   1
candidate  baseline         | 106/110    0     0    2    2     | 122/123   0   1
candidate  +netgate+corner  | 109/110    0     0    0    1     | 118/123   4   1
```
Lock guards recover all 15 stolen recordings; netgate + tie-break add 3 recordings and the
4 labelled live misses; nothing in one half undoes the other. The single "break" is the same
in every row incl. baseline: the one live Safari circle the app fired at 0.68 scores 0.57 in
the Python port (harness/app gap, not a regression). Shipped as ONE build:
1. `TouchCaptureManager` Cycle Windows lock: `&& maxOffAxis <= 0.10 && turn <= 2.0`;
   `NAV-LOCK` gains `turn=`.
2. `TouchCaptureManager` tiling lock: `offAxisLimit = 0.08` (was ∞), turn ≤ 2.5 kept.
3. `GestureMatcher.netDirectionFactor`: return 1.0 when both paths have openness < 0.15.
4. `GestureMatcher` corner tie-break on the full ranking before threshold filtering
   (`evaluate()` → `Evaluation{all, confident, tieBreak}`; `match`/`matchAll` are wrappers).
   `DISCRETE-FIRE|NOMATCH|AMBIGUOUS` gain `corners=<n> tiebreak=<winner>><loser>` or
   `tiebreak=-`.
Each change carries a dated comment in the code with the numbers above. Verified: binary
hash match, new PID, `TCM-START` logged. What to watch live: circles fire Safari/Chrome;
RD/LD no longer tile; straight tiling swipes still lock; L-shapes with short second leg fire.
Dropped: the 09-03 15:24 / 23:57 intent question (too long ago to answer — ask about
strokes within minutes, or render the stroke, `render_live.py --t <epoch>`).

### 8.5 4-finger tiling lock steals RD/LD (2026-09-04, replayed, user-confirmed)
`lock_gate_experiment.py --live --fingers 4` models `CONT-SHAPE-GUARD` for Window
Horizontal Tiling (horizontal-dominant, ≥ 3 frames, dist > 0.025, turn ≤ 2.5, after the
100 ms landing window, no frame after the first lift). Model vs app on the 68 live 4f
strokes: 66 agree; the 2 disagreements are the model stealing where the app did not (the
app's turn at lock was 2.85 on a jittery slow swipe; corpus points are rounded to 4 dp), so
"stolen" counts are an upper bound.
- Recordings: **Windows - RD 3/7 and Window - LD 1/6 would be taken by tiling** before the
  matcher. Both are U/J-shapes (down, curve, up) — the first 100–200 ms is a horizontal
  arc with ~0.1 vertical excursion. Owner confirms RD/LD sometimes tile instead.
- The 76 accepted tiling locks in both logs: 70 have `maxOff ≤ 0.060`; the other 6 sit
  at 0.108–0.134 with turn 2.2–2.5 — the RD/LD signature, not straight swipes.
- Candidate: add `maxOffAxis ≤ 0.08` to the tiling branch (turn ≤ 2.5 stays).
  Replay: RD 3→6 correct, LD 5→6, every other 4f gesture unchanged, 0 live strokes
  change (the one flagged "changed" is the LD fire the model mis-stole under the current
  rule). Real tiling swipes in the logs all pass.
- 5 fingers: only Vol/Bright continuous, no discrete shapes → nothing for a lock to steal.
- Windows - C 2/6 correct here is the there-and-back / net-direction issue of 8.2, not the lock.
- The two model/app disagreements, rendered (`render_live.py --t <t1,t2>`): 09-03 23:55 is a
  clean wide U = LD, fired LD 0.65 correctly (the model mis-stole it because the corpus
  `primary` differs from the app's longest-at-lock finger). 09-04 13:04 is a **dead-straight
  0.17-wide slow left swipe** — a tiling swipe the app rejected with `turn=2.85` (jitter on a
  slow stroke inflates the turn sum) and the matcher then nomatched. One case; note that
  `turn ≤ 2.5` is jitter-sensitive on slow swipes. Not addressed by the maxOff candidate.
