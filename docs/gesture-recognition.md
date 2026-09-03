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
