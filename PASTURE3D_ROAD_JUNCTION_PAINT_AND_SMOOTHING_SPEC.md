# Pasture3D Road — Junction Ribbons & Alignment Smoothing

**Document:** `PASTURE3D_ROAD_JUNCTION_PAINT_AND_SMOOTHING_SPEC.md`
**Status:** SPEC, nothing built (2026-09-02)
**References:** `PASTURE3D_ROAD_SYSTEM_PROPOSAL.md` §6.4, §8, §10; `PASTURE3D_ROAD_BRUSH_PERF_SPEC.md`
**Phases:** proposed as **P9a** (junction paint) and **P9b** (smoothing). Both sit after P7b; neither
depends on P8, which remains the only unbuilt phase of the original plan.

---

## 1. Why these two, and why together

They are unrelated features that share one property: **both are finishing work on surfaces the road
system already computes but does not use.** The junction's lane connectors are solved, published and
consumed by the reference lane follower — and never drawn. The alignment's vertical profile is solved,
projected and graded — and never conditioned. Neither feature needs a new solver.

They are specified in one document because they land in the same two files and would otherwise be two
overlapping edits to `pasture3d_road_chunk_host.gd`.

---

## 2. Feature A — junction ribbons, markings and stop lines (P9a)

### 2.1 What exists today

Read before proposing anything, because most of this feature is already sitting in memory:

| Thing | Where | State |
|---|---|---|
| Lane connectors | `Pasture3DRoadLaneConnector.curve` | **Solved.** A `Curve3D` per legal path through the junction, in WORLD space, tangent-continuous with both lanes at its ends. Carries `turn`, the signed angle, and `allowed_override`. |
| Stop lines | `Pasture3DRoadStopLine` | **Solved.** One per incoming lane: world `point`, `heading` into the junction, `width`, and the arc length. `endpoints()` already returns the two ends of the painted bar. |
| The junction surface | `Pasture3DRoadMesher.build_apron` | **Built.** A triangle fan over the footprint disc, sampling the graded ground rather than sitting at `junction.elevation`. |
| Road markings | `Pasture3DRoadMarkings.plan` / `.build` | **Built, but only along roads.** `plan()` answers in the grader's `u` (signed metres across, positive right); the host calls it per chunk, and `Pasture3DRoadMesher.chunk_spans` explicitly **removes everything inside a junction footprint**. |

So the gap is precise: **inside a footprint there is a bare grey disc.** The carriageway's edge lines and
centre line stop dead at the trim-back boundary, every stop line is data that nothing draws, and every
connector curve is a path nothing shows.

### 2.2 The one real design decision: `u` does not exist at a junction

`Pasture3DRoadMarkings.plan()` works because a road has a single across-axis. A junction has three or
more, and no cross-section at all. **Do not try to generalise `plan()`.** The junction kernel answers in
WORLD space, and that is the difference that keeps both kernels simple.

Add `Pasture3DRoadJunctionMarkings` as a second pure kernel with the same two-stage split and the same
reason for it — everything that can be wrong is wrong in the plan, and the builder only extrudes:

```
plan_junction(junction, roads) -> Array[Primitive]     # world-space, assertable as numbers
build_junction(primitives, ground_sampler)             # triangles
```

Three primitive kinds, and no more:

- **`STOP_BAR`** — straight from `junction.stop_lines`. Zero derivation: `endpoints()` already gives the
  two ends and `width` gives the span. This is the cheapest of the three and the most visible.
- **`ARM_CONTINUATION`** — the arm's edge lines and divider, extended from the trim-back boundary to the
  footprint edge, so the carriageway does not visually stop short. The offsets come from
  `Pasture3DRoadMarkings.plan()` on that arm — **call it, do not reimplement it**, or the junction's
  lines will drift from the road's the first time a divider type changes. The divider continuation stops
  at the stop bar; edge lines run to the footprint.
- **`CONNECTOR_GUIDE`** — a dashed line along `connector.curve`, emitted only for connectors whose
  `turn` is `LEFT` or `RIGHT` **and** which cross opposing traffic (`junction.conflicts` already says
  which). A guide on every connector paints a junction solid white; the conflict list is what makes the
  set small enough to read.

`allowed_override == OFF` emits nothing for that connector, and no guide. A connector that is not legal
must not be painted as an invitation.

### 2.3 Ribbons from connector curves

The user's framing — "use our intersection curves to build ribbons" — is buildable directly:
`Pasture3DRoadMesher.ring()` is a pure function of a plan polyline plus cumulative arc length, and a
`Curve3D` tessellates to exactly that. So a connector ribbon is `ring()` driven off
`curve.tessellate_even_length()` with a one-lane cross-section.

**Recommendation: overlay, do not replace.** Keep the apron as the surface and lay connector ribbons on
it at `DEPTH_LIFT`, rather than replacing the disc with a union of ribbons. Three reasons, in order of
how much they cost to learn the hard way:

1. A union of ribbons has holes wherever no connector runs — the corners of a crossroads — and the
   terrain shows through. The apron has no holes by construction.
2. Overlay is the pattern P5a already proved works for tier FAR paint (overlay-not-base is recorded as
   the reason its edges work).
3. It is reversible. A connector ribbon that looks wrong can be switched off without leaving a hole.

The cost is overdraw across the footprint, bounded by the number of connectors, and NEAR-tier only.

### 2.4 Where it lives, and LOD

`Pasture3DRoadChunkHost` already builds one `MeshInstance3D` per junction (`Junction_<id>`, see the
apron loop) and already owns the tier mapping. Junction paint is one more mesh per junction from the
same loop, at **tier NEAR only**, matching P5c: markings are unreadable at MID and absent at FAR, where
the road is terrain paint anyway.

Lift: `MARKING_LIFT` **on top of** the ribbon's lift, never instead of it — the same rule the road
markings follow, and for the same reason (coplanar geometry is decided by float precision, not by draw
order).

### 2.5 Gate — `RoadJunctionPaintGate`

Every criterion below is decidable from numbers; none needs a rendered frame.

| # | Claim | Control that must fail |
|---|---|---|
| A | A 4-arm crossroads emits exactly one `STOP_BAR` per incoming lane. | Make one arm one-way outbound: its bars disappear and the count drops by exactly its lane count. |
| B | Each bar's midpoint equals its `stop_line.point` to 1e-4 m, and its normal is `heading`. | Change `radius_override`: the trim-back moves and every bar moves with it. A bar that stayed put is reading the wrong boundary. |
| C | A one-way arm gets **no divider continuation** (no opposing traffic), but still gets edge lines. | Flip it two-way; the divider appears. |
| D | Continuation offsets equal `Pasture3DRoadMarkings.plan()` on that arm, exactly. | Change `divider_type`; both move together. Asserting a literal offset here would drift with a copied formula — compare against the kernel. |
| E | Guides are emitted only for turning connectors that appear in `junction.conflicts`. | A T-junction whose left turn conflicts with nothing emits no guide; adding the opposing arm makes one appear. |
| F | `allowed_override = OFF` removes that connector's ribbon **and** its guide. | INHERIT restores both. |
| G | A connector ribbon's ends are tangent-continuous with the arm ribbons they meet, compared for **exact** float equality at the shared arc length. | The P5b lesson: an accumulated `s` agrees to six decimals, passes any tolerance, and cracks. |

---

## 3. Feature B — alignment smoothing (P9b)

### 3.1 Where it goes — the user's guess is right, with one correction

The pipeline in `pasture3d_road_brush.gd` is:

```
_resample_plan(...) -> solve_with_plan(...) -> alignment.z -> "align_z" -> native grader -> terrain
                                              ^^^^^^^^^^^^
                                              here
```

Smoothing `alignment.z` after the solve and before the grade is exactly "after grading the curve, before
the landscape deformation" as asked.

**It ships NATIVE.** Road editing is already slow next to comparable tools, and this pass runs on every
drag of every spline point — a GDScript filter over a 2 km road at a 1 m step is 2000 samples times
three box passes times a re-projection loop, per interactive bake, and it would be paid by every road
whether or not the feature is switched on. There is no reason to pay it: `Pasture3DUtil` already
exposes `road_align_solve` and `road_align_solve_with_plan`, both of which take an **`opts` Dictionary**.
`smooth_radius` goes in `opts`, so this needs no new binding signature and no new entry point — the
native solver grows a final stage and the existing call site passes one more key.

This does mean the pass exists twice, in C++ and in the GDScript solver. That is not the R7 trap; it is
the arrangement R7 established. `force_gdscript` is already threaded through `solve`,
`solve_with_plan`, `plan_curvature` and `superelevation` precisely so the GDScript body can serve as an
independent oracle, and the smoothing pass must be threaded the same way or a forced solve returns a
half-oracle — a profile smoothed by neither implementation, which would compare equal to nothing.

What would have been the R7 trap is putting the smoothing in `pasture_3d_road_grade.cpp` instead of the
solver: the grader is downstream of the projections, so a smoothing pass there could not re-apply pins
or the gradient limit without duplicating them too. It belongs in the solver, on both sides.

**The correction:** the solver's output is not a free-standing curve. It is the output of alternating
projection — pins applied, then the gradient limit. A plain filter over `z` violates both:

- It **moves pinned samples.** A bridge deck or a junction elevation slides, silently, and the junction
  resolve loop then re-pins and re-solves against a road that moved. Pins winning is the solver's whole
  documented contract.
- It can **breach the gradient limit** near a pin, where the filter pulls a sample toward a neighbour the
  pin is holding away.

So smoothing is not a post-filter. It is **a filter followed by re-projection**, reusing the solver's own
`_apply_pins` and `_project_grade` rather than new copies of them. Structurally that argues for it living
as a final stage of the solver — `road_align_solve_with_plan` natively, and
`Pasture3DRoadAlignmentSolver.solve_with_plan` in the oracle — rather than in the brush:

```
smooth pass  ->  _apply_pins  ->  _project_grade (to convergence)  ->  _fill_diagnostics
```

`_fill_diagnostics` must run **after** smoothing, or `peak_grade` and `feasible` describe a profile that
is no longer the one being graded.

### 3.2 Why not just raise `w_smooth`

The obvious question, and it deserves an answer here rather than a rediscovery later. `w_smooth` trades
against the **earth** term globally: raising it makes the road stop paying for cut and fill, so it floats
off the ground and imports material everywhere. That is a different road, not a smoother one. The request
is to remove bumps at the elevation the solver already chose — a conditioning pass on the result, not a
reweighting of the objective.

### 3.3 The parameter

The request — "smooths larger bumps the higher it is raised" — is a **scale** knob, not an amplitude one.
A wider kernel removes longer wavelengths; that is the behaviour asked for and it falls out of the kernel
width directly.

```gdscript
## Removes bumps shorter than roughly this along the road, metres. 0 disables smoothing entirely.
@export_range(0.0, 200.0, 0.5, "or_greater", "suffix:m") var smooth_radius: float = 0.0
```

**In METRES, not samples.** `alignment_step` is authorable, so a sample-count parameter would silently
change every road the moment the step changed — the same class of bug as measuring in grid fractions
instead of metres. The kernel half-width is `int(round(smooth_radius / ds))`, and a radius below one
sample is a no-op rather than an error.

**Kernel: three box passes**, not a Gaussian. Three iterated boxes approximate a Gaussian closely enough
that nothing downstream can tell, cost O(n) per pass with a running sum, and — unlike a truncated
Gaussian — have an exactly stated support, which is what makes criterion B below assertable.

Ends are clamped (extend the end sample), not wrapped and not zero-padded: a road is not periodic, and
zero-padding would drag both ends toward zero elevation.

### 3.4 What must not be forgotten

- **`alignment_digest` must include `smooth_radius`.** It currently hashes plan points, `ds`, drape,
  `max_grade`, `design_speed` and pins. A cached alignment that does not know the radius changed is a
  road that does not rebuild when the user drags the slider — the memoisation trap, where a stack copies
  its inputs' bytes and a changed input never says so.
- **Superelevation is unaffected, and this should be asserted rather than assumed.** `plan_curvature`
  works from the PLAN, and banking from curvature, so smoothing `z` cannot change either. If a gate ever
  shows banking moving under smoothing, something is reading `z` that should not be.
- **`smooth_radius = 0` must be bit-identical to today's output**, not merely close. That is the control
  that proves the pass is off rather than approximately off.

### 3.5 Gate — `RoadSmoothGate`

Pure arithmetic, no terrain, no scene — the same property that makes the alignment solver testable.

**Every criterion runs twice**, once native and once under `force_gdscript`, and a seventh compares the
two. A native-only run cannot tell a correct pass from one the oracle never received.

Fixture: a synthetic ground profile carrying two superimposed sinusoids — 0.3 m at 60 m wavelength (the
"small bump") and 2.0 m at 400 m (the "larger bump") — over a 2 km road.

| # | Claim | Control that must fail |
|---|---|---|
| A | `smooth_radius = 0` reproduces the current profile **bit-for-bit**. | Any non-zero radius changes it. |
| B | A radius sized to the small bump attenuates its band by >90% and the long band by <10%. Measure per band, not as a single RMS — an RMS drop is equally consistent with flattening the whole road. | Reverse the two: a radius sized to the long bump must attenuate BOTH. That is the "smooths larger bumps the higher it is raised" claim, and only the pair of measurements proves it. |
| C | Every pin is honoured **exactly** after smoothing. | Remove the `_apply_pins` re-projection and this must fail. |
| D | `peak_grade <= max_grade` after smoothing, on a profile where the pre-smoothing solve was already at the limit. | Remove the `_project_grade` re-projection and this must fail. |
| E | Banking and curvature are bit-identical with and without smoothing. | A guard: its failure means something reads `z` that should not. |
| F | `feasible` and `peak_grade` describe the SMOOTHED profile. | Move `_fill_diagnostics` above the smoothing pass and this must fail. |
| G | Native and forced-GDScript profiles agree to 1e-5 m at a non-zero radius. | Perturb the native kernel width by one sample: the two must diverge. Agreement at radius 0 proves nothing — both are doing nothing — so this must be measured with the pass ON. |

Criterion B is the one worth writing first, because it is the only one that distinguishes "measured
nothing" from "measured well": a smoothing pass that did nothing at all would pass A, C, D, E, F and G.

---

## 4. Suggested order

1. **P9b first.** It is smaller, it is pure arithmetic, its gate needs no terrain, and it changes a
   surface P9a will then be drawing on.
2. **P9a stop bars**, which are nearly free — the data is published and `endpoints()` already exists.
3. **P9a arm continuations**, which need the existing markings kernel called, not extended.
4. **P9a connector ribbons and guides**, the largest piece and the only one with a geometry question.

---

## 5. Open questions for the author

1. **Should connector ribbons be a different material to the apron?** A distinct surface reads better in
   an editor and worse in a shipped scene. Defaulting to the same material and exposing an override on
   `Pasture3DRoadNetwork` is the cheap answer, but it is a decision.
2. **Should `smooth_radius` be inheritable through the `RoadType` / `RoadGroup` / `RoadBrush` chain like
   the other road settings, or per-brush only?** Inheriting is consistent; per-brush is what "this one
   road is bumpy" actually wants. The resolve chain makes either cheap, so this is a taste call.
3. **Crosswalks and give-way triangles** are the two markings a junction wants that this spec does not
   propose. They are `plan_junction` primitives of the same shape as `STOP_BAR` and could be added later
   without reopening the kernel — noted here so the primitive list is understood as extensible rather
   than complete.
