# Pasture3D Sim Node Spec (`Pasture3DSim`)

**Status:** **PHASE 1 IMPLEMENTED** (2026-08-08). Phases 2–4 remain design. Drafted 2026-08-08; **solver
replaced the same day** after a survey of Houdini, World Machine, Gaea and the large-scale-terrain
literature (§16). Target: Godot 4.7, Pasture3D `main`.

Phase 1 ships as:

| File | What |
|---|---|
| [pasture_3d_erosion.h](src/pasture_3d_erosion.h) / [.cpp](src/pasture_3d_erosion.cpp) | The §4 solver, as a pure function of a heightfield — no terrain dependency at all |
| [pasture_3d_sim.cpp](src/pasture_3d_sim.cpp) | `erode_heightfield` / `resample_grid` / `sim_mask_deltas` / `apply_sim_block` on `Pasture3DData` |
| [pasture_3d_raster_util.h](src/pasture_3d_raster_util.h) | The SDF + ramp primitives Sim's loop mask shares with the spline brushes |
| [connectors/sim.gd](project/addons/pasture_3d/connectors/sim.gd) | `Pasture3DSim` — area, resolution, mask, layer and UX plumbing |
| [bench/SimPhase1Gate.tscn](project/bench/SimPhase1Gate.gd) | Gates A–K, all passing with their controls |
| [bench/SimFieldProbe.tscn](project/bench/SimFieldProbe.gd) | Hillshade diagnostic — what the solver actually produces, synthetic and on the demo terrain |

Sections below carry **Built:** notes wherever the implementation departed from the design, and §14
records the gate results and the two criteria that were vacuous until their controls caught them.

**Goal:** erode large areas of terrain into something that reads as a real landscape — dendritic valley
networks, coherent watersheds, ridgelines — bake the result into a non-destructive layer, and expose the
drainage masks so the relief system can key off them. Later, turn the resulting channels and basins into
editable Pond and Trough brushes.

**Guiding priority (user, 2026-08-08):** *"eroding the landscape of large surfaces into more realistic
environments is the reason for the sim at all."*

---

## 1. The solver decision, and why it changed

The first draft of this spec specified the **Mei et al. virtual-pipe shallow-water model** — the standard
choice in games and the one most GPU erosion tutorials implement. Researching how the mature tools work
showed that is the wrong primary solver for the stated goal.

| | **Stream power** (chosen) | Pipe model (first draft) |
|---|---|---|
| Produces | Dendritic valley networks, watersheds, ridgelines | Local channels, fluid detail, alluvium |
| Numerics | Implicit, O(n), **unconditionally stable** | Explicit, **CFL-limited** |
| Iterations | ~20–50 | 500+ |
| Output topology | **Hydrologically coherent, pit-free** | Can leave pits and depressions |
| River extraction | The drainage tree **is** the working data | Threshold flow accumulation, then cope with pits |
| Lakes | Depression-fill depth, free | Requires a separate settle phase |
| Reference | Braun & Willett 2013; Cordonnier 2016; Schott 2023 | Mei 2007 |

Four consequences:

1. **A whole failure mode disappears.** Unconditional stability means no CFL clamp, no divergence, no
   NaN guard, and no gate for any of it. The first draft spent a section (§4.4) on defences against a
   problem this solver does not have.
2. **River extraction gets much easier.** Stream power routes flow over a pit-free surface as a
   precondition, so the drainage network is already a clean forest. Phase 4 traces it rather than
   reconstructing it.
3. **Lakes come free.** The depression-filling step the router needs yields *filled surface − real
   surface = standing water depth*. No fluid simulation, no settle phase.
4. **The GPU may be unnecessary for phase 1.** ~30 O(n) iterations is a very different budget from 500+
   CFL-limited steps. §11 — this needs measurement, not assertion.

**The argument that settled it:** the fine-detail layer already exists. `Scree`, `Strata`, `Furrows` and
`Fractal`, gated by slope and curvature selectors, are precisely the surface texture Gaea and World
Machine use hydraulic erosion to produce. The sim's job is the thing relief materials structurally cannot
do — large-scale drainage structure. Stream power does that and only that, so the two compose instead of
competing.

**What this gives up:** detachment-limited stream power *removes* material and does not transport it, so
there is no alluvial deposition (bars, fans). Hillslope diffusion (§4.4) recovers some deposition at slope
toes; full sediment transport is the Yuan et al. 2019 extension, deferred to §15.

---

## 2. Other decisions

| Question | Decision | Consequence |
|---|---|---|
| Is Sim a relief *source*? | **No — a transform.** | Erosion reads the existing heightfield and modifies it; relief materials are point generators. Sim writes a delta into its own layer, like a brush. |
| How does it integrate? | **Through selectors.** | Sim's masks are more per-cell fields of the shape `ReliefSample` already carries. Four new Kinds. §9. |
| Water source | **Sim seeds its own.** No coupling to authored `Pasture3DPool` / `Stream`. | Authored water is untouched. Sim can instead *generate* bodies (§10). |
| Uplift | **None — `U = 0`.** | Cordonnier and Schott author *in the uplift domain*, growing mountains from scratch. Pasture3D already has brushes for the big shapes; Sim erodes what is there. This is a real departure from the papers and simplifies the model. |
| Live or explicit? | **Explicit bake only.** | §12. |
| Resolution | **Separate preview and build resolutions.** | World Machine's loop. §6. |
| Erodability | **Spatially varying, phase 1.** | Houdini masks nearly every parameter; Gaea calls it Rock Softness. Highest-value directability input. §7. |
| CPU reference implementation | **N/A — the solver is CPU by default.** | The first draft's GPU/CPU parity question dissolves. §11. Built: C++, ~3 s for a 500 m loop at 1 m over 30 iterations. |
| Mask storage | **One `Pasture3DSimResult` `.res` per Sim node.** | Optional, diffable, deletable. §8.2. |
| Generated brush layers | **Dedicated `Generated Rivers` / `Generated Lakes`.** | Clearing cannot disturb authored work. §10. |
| Generated Trough behaviour | **Shallow — hosts water, does not re-carve.** | The sim already cut the channel. §10.3. |
| Clear Brushes | **Removes every generated brush, edited or not, one undo.** | Predictable; Ctrl+Z restores. §10.4. |

> [!] **Two earlier claims of mine, corrected.** (1) I said Sim "needs no plow-side plumbing because it
> outputs something satisfying the material contract" — wrong; erosion is not a point-evaluated
> generator, and the layer is the right output. (2) I specified the pipe model as primary — wrong for
> large-surface realism, for the reasons in §1.

---

## 3. Out of scope

- Tectonic uplift authoring (the papers' main contribution; Pasture3D has brushes for that).
- Full sediment transport / alluvial deposition — see §15.
- Rock-hardness *layering* in depth (erodability is a 2D map, not a stack).
- Coastal, glacial, or aeolian erosion.
- Any runtime simulation. This is an authoring tool.
- A `Pasture3DSplat` consumer for the masks — its own spec, though §8.2 is designed ready.
- A paintable rainfall map. Drainage area already encodes where water concentrates; a rainfall multiplier
  is a small later addition (§15).

---

## 4. The algorithm

State is one array: elevation `z`. Everything else is derived per iteration.

### 4.1 Flow routing and depression handling

1. **Fill depressions** (priority-flood). Produces `z_filled`, guaranteeing every cell has a downhill path
   to a domain edge.
   **`lake_depth = z_filled − z`** — this is the standing-water map, obtained as a byproduct.
2. **D8 receivers.** On `z_filled`, each cell's receiver is its steepest-descent neighbour. The result is
   a forest of trees rooted at the domain boundary.

### 4.2 Drainage area

Topologically order the forest (Braun & Willett's stack construction), then accumulate cell area from
leaves to roots. `A[i]` = total upstream area draining through `i`. O(n).

### 4.3 Implicit stream-power incision

With `n = 1` the implicit update is analytic, which is the whole reason this is fast and stable. Walking
the stack **downstream-first**, for each cell `i` with receiver `r` at distance `L`:

```
K'      = Δt · K · erodability[i] · A[i]^m / L
z[i]   := (z[i] + K' · z[r]) / (1 + K')
```

`z[r]` is already updated when `i` is visited — that is what makes the scheme implicit and
unconditionally stable. Typical `m ≈ 0.45`, `n = 1`.

Elevation is clamped so a cell never incises below its receiver (no inversion).

> **Built — the fill runs twice, into two surfaces.** Priority-flood needs Barnes et al.'s `+epsilon`
> variant or a filled lake surface is exactly flat and *no cell in it has a downhill receiver*, which
> breaks the forest gate A guards. But an epsilon on the filled surface would also show up in
> `lake_depth`. So the same traversal fills two arrays: `zf_route` with the epsilon (what D8 routes on)
> and `zf_true` without (what `lake_depth` measures). Cost is one extra array, and `lake_depth` stays
> physically exact.
>
> **Built — no-data is an outlet.** `composite_height_below` returns NaN where no region covers. Those
> cells become fixed boundary at the field minimum − 1 m, so water that reaches the edge of the authored
> world leaves rather than ponding against an invisible wall, and they come back out of the solver as
> NaN rather than as that synthetic level.

> **Built — two guards on the incision step, both to stop it RAISING ground.** A cell routed across a
> filled basin has a receiver that is *above* it in the real surface, and the implicit update would pull
> it up toward that receiver. So: a cell whose `lake_depth > 0` does not incise at all (standing water
> traps sediment, it does not cut bedrock), and a cell whose receiver is not below it in the real
> surface is skipped. Together with the no-inversion clamp these make incision monotone by
> construction, which is what gate K measures.

### 4.4 Hillslope diffusion

`dz/dt = D · ∇²z`, one explicit Laplacian pass per iteration. Rounds ridges, produces talus slopes, and
supplies the only deposition this model has (material moves into concavities). Without it the output is
recognisably knife-edged.

> **Built — this is the one conditionally stable part, and §1's "unconditionally stable" does not cover
> it.** The claim belongs to the implicit fluvial step; an explicit Laplacian has the usual FTCS limit
> `D·Δt/Δx² ≤ 0.25`. Rather than silently clamping `D` — which would quietly ignore what the artist
> asked for — the pass **sub-steps** to stay at 0.2 of the limit, capped at 64 sub-steps so an absurd
> setting costs a bounded amount of time instead of hanging the editor. Hitting that cap raises a
> configuration warning; nothing else about it is visible.
>
> **Built — diffusion competes with incision, and losing that competition is the failure mode.** Too
> much `D` fills the channels faster than stream power cuts them and the area comes back *smoother*
> than it went in. Rule of thumb, now in the tooltip: diffusion erases detail finer than roughly
> `7.5·√(D · iterations)` metres. The `D/K` ratio is what sets drainage density.

### 4.5 Iteration

Repeat 4.1–4.4 `iterations` times (default ~30). The network *reorganises* between iterations — that
progressive capture is what produces dendritic structure, so a single large timestep is not equivalent to
many small ones even though each step is stable.

---

## 5. Area, boundary, and the catchment margin

Water arrives from upslope, and a loop boundary cuts off the catchment that feeds it. **Simulate wide,
write narrow:**

- Simulate over the loop's bounds expanded by `catchment_margin` metres.
- Write only inside the loop, through the standard falloff mask.
- Treat the outer edge of the margin as the drainage outlet (base level).

`catchment_margin` is artist-meaningful: *how much upstream catchment feeds your area*. Default 128 m —
larger than the pipe model needed, because drainage area is the dominant term in the incision law and a
truncated catchment directly under-incises the channels near the rim. Cost is quadratic; say so in the
tooltip.

> **Known limitation — seams between adjacent Sim areas.** Two neighbouring loops compute drainage
> independently and will not agree at their shared edge. World Machine documents the same problem for
> tiled builds and its answer is the same as ours: overlap generously and let the falloff blend. Do not
> expect to tile a large map from many small Sim loops; use few large ones.

---

## 6. Preview and build resolution

Two settings, following World Machine's interactive-preview-then-build loop:

| Setting | Default | Use |
|---|---|---|
| `preview_resolution` | 4× coarser than `vertex_spacing` | The **Preview** button. ~16× cheaper. For tuning erodability, strength and iteration count. |
| `build_resolution` | 1× | The **Simulate** button. Final commit. |

Both write to the same layer, so Preview is visible in the viewport and directly comparable to the build;
it is simply coarser. Input heights are downsampled onto the sim grid and the delta is bilinearly
upsampled on write.

Drainage area is resolution-dependent (`A` is in m², so it is consistent), but D8 routing on a coarse grid
finds slightly different channels. Preview is therefore *representative, not identical* — gate J tests
that they agree on large-scale structure, which is the claim actually being made.

> **Built — measured, and the news is mixed.** On structure the claim holds well: the correlation between
> the preview's delta and the build's rises from 0.86 at full resolution to 0.88 at 32 m features and
> 0.91 at 64 m. But **the preview erodes DEEPER than the build** — 1.28× the delta RMS on the synthetic
> fixture, and 2.5× at the probe point of a small (120 m) demo loop. A coarse cell's receiver is four
> times further down the hill, so channel slopes are measured over a longer baseline and the incision
> is less self-limiting.
>
> So Preview is a good guide to *where* the valleys go and a poor guide to *how deep*. Tune the area,
> the margin and the erodability map on a preview; tune `erosion_rate` on a build. This is a real
> limitation of the design, not a defect in the implementation — a per-resolution calibration factor
> would be a fudge, and phase 1 does not ship one.
>
> **Built — the grids are corner-aligned, and the cell size follows from that.** Both grids span the
> same world rect exactly, so sample (0,0) and (w−1,h−1) coincide and a 1× build resamples to a bitwise
> copy. The sim cell size therefore comes *out* of the grid dimensions rather than being assumed to be
> `vertex_spacing × divisor`. Downsampling area-averages (NaN-aware, so an unregioned corner stays a
> hole instead of smearing into real ground); upsampling is bilinear.

---

## 7. Erodability

```gdscript
@export var erodability_map: Texture2D     # null = uniform 1.0
@export var erodability_range: Vector2 = Vector2(0.25, 2.0)   # maps texture 0..1
```

Sampled across the sim area (FIT-style, like the plow's mapping), remapped into `erodability_range`, and
multiplied into `K` per cell in §4.3. Soft valleys, hard granite ridges, a resistant sill that forces the
river around it — this is the single highest-value directability control, and both Houdini and Gaea treat
spatially varying hardness as fundamental rather than optional.

> Natural later addition: accept a `Pasture3DReliefSelector` as an erodability source, so hardness can be
> derived from slope or altitude rather than painted. The selector machinery already produces exactly the
> 0–1 value this needs.

> **Built.** The texture is read once per bake into a luminance LUT capped at 256×256 (mirroring
> `Pasture3DPlow._load_height_lut` — rock hardness is a broad field and more resolution buys nothing),
> handed to the solver, and sampled bilinearly across the **whole simulated area including the catchment
> margin**, not just the loop. Sampling only the loop would put a hardness discontinuity exactly at the
> rim, where the incoming channels are. Built once per solve rather than per iteration.

---

## 8. Outputs

### 8.1 Height → the `Erosion` layer

```cpp
void apply_sim_block(int layer_id, double min_x, double min_z, double vs, int gw, int gh,
                     const PackedFloat32Array &deltas, int blend);
```

Same shape as the internal `_apply_stamp_block` the `stamp_*` rasterisers use, inheriting batched
raw-tile application and the deferred-composite path. Blend `ADD` — Sim writes a delta, never an absolute.

> **Built exactly as specified**, plus the three calls around it, all on `Pasture3DData`:
>
> ```cpp
> Dictionary        erode_heightfield(const PackedFloat32Array &z, const Dictionary &params,
>                                     const PackedFloat32Array &erodability);
> PackedFloat32Array resample_grid(const PackedFloat32Array &src, int sw, int sh, int dw, int dh);
> PackedFloat32Array sim_mask_deltas(const PackedFloat32Array &field, const PackedVector2Array &poly,
>                                    const Dictionary &params, const PackedFloat32Array &lut);
> ```
>
> `erode_heightfield` is deliberately a **pure function of a heightfield** — it reads no terrain and
> writes none — which is what lets gates A–F, I–K drive the solver directly on a synthetic bowl, plane
> and hillside instead of only through a bake. `sim_mask_deltas` does the §5 mask and the §6 upsample in
> one pass, returning NaN outside the mask so `apply_sim_block` never touches those cells.
>
> **`sim_mask_deltas` takes `params["baseline"]` and differences in C++.** The node solves in chunks so a
> long build stays cancellable, so what comes back is an absolute surface, not a delta; without this the
> subtraction would be an O(cells) GDScript loop over up to a million cells. This is also where the one
> genuinely dangerous bug of phase 1 lived — see §14.

> **Blend `ADD` is checked, not assumed.** If the resolved layer's blend mode is not `ADD` (a shared
> layer another brush set to `REPLACE`), the node raises a configuration warning: Sim's delta would
> overwrite the ground instead of eroding it.

### 8.2 Masks → `Pasture3DSimResult`

```gdscript
@tool class_name Pasture3DSimResult extends Resource
@export var min_x: float
@export var min_z: float
@export var cell_size: float        # sim resolution, NOT necessarily terrain vertex_spacing
@export var width: int
@export var height: int
@export var flow: PackedFloat32Array        # drainage area, m² (store log-scaled; range spans decades)
@export var erosion: PackedFloat32Array     # material removed, metres (negative delta)
@export var deposition: PackedFloat32Array  # material gained, metres (positive delta, from diffusion)
@export var wetness: PackedFloat32Array     # standing water depth from depression filling
```

> **Be honest about `deposition` in phase 1–2.** Detachment-limited stream power removes material without
> transporting it, so the only deposition is hillslope diffusion into concavities. The channel is real but
> small until the sediment-transport extension (§15) lands. Ship all four channels anyway — retrofitting
> one later means re-running every simulation in the project.

---

## 9. Selector integration (phase 3 — the priority payoff)

`Pasture3DReliefSelector.Kind` gains:

| Kind | Reads | Enables |
|---|---|---|
| `FLOW` | `SimResult.flow` | Boulders and roughness only in channels; scales with catchment size. |
| `EROSION` | `SimResult.erosion` | Expose bedrock strata where material was stripped. |
| `DEPOSITION` | `SimResult.deposition` | Silt relief on valley floors. |
| `WETNESS` | `SimResult.wetness` | Basin bottoms and lakebeds treated differently from dry ground. |

The selector gains a `sim_result: Pasture3DSimResult` reference, used only for these Kinds. The plow
samples it in world space — the resource carries its own extent and cell size, so it resamples
independently of the terrain grid — and adds the value to `ReliefSample`, which already exists and
already reaches both evaluators.

**No change to the op program, the wire format, or the material contract:** four enum values, four struct
fields, one bilinear sample.

> Outside the result's extent, or with no resource assigned, these Kinds must return a **defined 0** and
> the plow must raise a configuration warning. Silent garbage here would be very hard to diagnose.

---

## 10. Water feature generation (phase 4)

The workflow: **iterate on the sim → like the result → one click makes editable Ponds and Rivers → need
to re-sim → clear them → repeat.** Authored ponds and rivers are never touched.

### 10.1 Rivers, from the drainage tree

The router already produced a pit-free forest with drainage areas, so extraction is a traversal, not a
reconstruction:

1. Channel cells are those with `A > river_area_threshold` (an *area* threshold in m² — physically
   meaningful, unlike an arbitrary flow number).
2. Walk downstream from each channel head, **splitting at confluences** — one polyline per segment
   between junctions. One-per-source-to-outlet would overlap and double-carve shared trunks.
3. Discard segments shorter than `min_river_length`.
4. Douglas-Peucker simplify to `curve_tolerance`; sample Y from the eroded surface.
5. Emit a `Pasture3DTrough` per segment, `width_curve` populated from `A^0.5` along the segment so rivers
   widen downstream. `make_descend` cleans up residual non-monotonic Y.

### 10.2 Lakes, from the depression fill

1. Cells with `lake_depth > lake_depth_threshold`.
2. Connected components → individual lakes; discard those below `min_lake_area`.
3. Marching-squares contour at the waterline; simplify to a closed `Curve3D`.
4. Emit a `Pasture3DPond` per lake, depth from a high percentile of the component's fill depth (not the
   max — one deep sinkhole should not make the whole lake that deep).

### 10.3 How generated brushes are configured

Generated Troughs are **shallow by default** — the sim already cut the channel, so the Trough hosts the
water surface and provides an editable spline rather than carving again. `depth` starts near zero and is
exposed. Water comes from the existing pool path (`add_pool_now()` / `_build_pool_for`).

Both types paint into **dedicated layers** — `Generated Rivers`, `Generated Lakes` — so clearing can never
disturb authored work, and the whole generated set gets one visibility toggle.

### 10.4 Bookkeeping

- Generated nodes are parented under a `Generated` `Node3D` child of the Sim **and** carry a
  stored-but-hidden `_generated_by_sim` flag. Never identify them by name — a rename would orphan them.
- **Preview** is a read-only inspector line: *"3 lakes, 12 rivers at current thresholds"*.
- **Add Brushes** clears the existing generated set, then creates the new one, as **one undoable action**
  (matching `place_brush_at`'s `add_do_reference` pattern).
- **Clear Brushes** removes every generated brush, edited or not, one undo, reporting the count first.

---

## 11. Where it runs

**CPU first.** The solver is O(n) per iteration with a small constant; ~30 iterations over a
preview-resolution grid is trivially fast, and over a full-resolution large area is plausibly a second or
two in C++. That is a completely different budget from the pipe model's 500+ CFL-limited steps, which is
what forced GPU into the first draft's phase 1.

**The one part that needs watching is depression filling**, which is O(n log n) with a priority queue and
runs every iteration. If profiling shows it dominating, in order of preference: re-fill every *k*
iterations rather than every one; adopt an O(n) priority-flood variant; or move the whole solver to GPU.

**This must be measured, not assumed — and benchmarks need the user's go-ahead before running.** The
escape hatch is intact: `Pasture3DGPURaster` can still be generalised into a shared compute host later
(the first draft's §10 describes how), and nothing in this design forecloses it.

> **Built on CPU, and no profiling has been done.** The numbers below are wall-clock times incidental to
> the gate and probe runs, not a profiling pass and not a comparative benchmark — those still need the
> user's go-ahead, and in particular **nothing has yet measured whether depression filling dominates**,
> which is the one question §11 actually poses.
>
> | Case | Sim grid | Time |
> |---|---|---|
> | 500 m loop + 128 m margin, 1 m cells, 30 iterations | 756² ≈ 570k cells | **≈ 3.2 s** |
> | 120 m loop + 40 m margin, 1 m cells, 30 iterations | 205² ≈ 42k cells | ≈ 0.18 s |
> | The same 120 m loop at preview resolution (÷4) | 52² ≈ 2.7k cells | ≈ 0.016 s |
>
> So a full-resolution build over a large loop is a few seconds rather than "a second or two", and
> Preview is ~11× faster wall-clock on the small case (the grid is 15.5× smaller). That is inside the
> budget the design assumed, and it is why nothing was moved to the GPU.
>
> **`fill_every` exists in the solver parameters but is not exposed on the node,** and defaults to 1.
> Exposing an escape hatch before the profiling that would justify it is how a knob nobody understands
> ends up in an inspector. Note it is implemented as freezing the WHOLE flow network for k iterations,
> not just the fill: reusing a filled surface under a `z` that incision has since lowered would leave
> cells routing to neighbours that are no longer downhill.

---

## 12. Editor UX

- **Preview**, **Simulate**, **Clear Simulation**, and (phase 4) **Add Brushes** / **Clear Brushes**
  buttons in the brush button block.
- `_paint_spline()` is a **no-op** — Sim must never run on the auto-refresh path. Moving a spline point
  therefore re-runs the *clear* and empties the layer without re-simulating, which reads as a bug unless
  the UI says so. `_get_configuration_warnings()` reports *"area changed since the last simulation"*
  whenever the loop's footprint hash differs from the one recorded at bake time.
- Long runs report progress and are cancellable; the repo has form on editor freezes
  ([PASTURE3D_TAB_SWITCH_FREEZE_SPEC.md](PASTURE3D_TAB_SWITCH_FREEZE_SPEC.md)).
- Warnings: area changed since last bake · no regions under the loop · a sim selector Kind is in use with
  no `SimResult` assigned · erodability map assigned but the area has no regions to map it onto.

> **Built — how progress and cancellation actually work.** The solve is a state machine
> (`_begin` / `_solve_chunk` / `_finish`), not one function with an `await` in it, driven two ways:
> `simulate_now()` runs straight through and is **not** a coroutine, so scripts and the gates get a
> report Dictionary back; `_simulate_interactive()` yields a frame every 5 iterations, prints progress,
> and lets Cancel land. Putting the `await` in a shared implementation made *both* paths coroutines, and
> that only surfaced when a caller held a typed `Pasture3DSim` reference — an untyped one compiles
> silently and returns a signal object.
>
> **Nothing is written until every loop has finished solving.** The solve is seconds and the write is
> milliseconds, so a cancel never leaves a half-eroded layer and the undo action wraps one atomic write.
> Cancel is therefore free: it simply abandons, and the terrain is untouched.
>
> **Built — the "no simulation in the layer" warning, and how it survives a refresh.** `_paint_spline()`
> is a no-op as specified, but the base class's paint cycle still CLEARS Sim's footprint before calling
> it. So Sim overrides `_paint_into()` to notice that its recorded bake has just been wiped and clear
> `_baked_hash`, which turns the warning from "area changed" into "no simulation in the layer — press
> Simulate". Without that override the layer would empty with the warning still saying everything was
> fine, which is exactly the reading-as-a-bug the section exists to prevent.
>
> **Known limitation — two Sim nodes on one layer wipe each other.** A brush layer-mate is repainted from
> its spline when someone else bakes the layer; Sim cannot be, because repainting it means re-solving.
> Baking one Sim therefore clears any overlapping Sim's contribution from the shared `Erosion` layer and
> does not put it back. Note the clear drops whole layer *tiles*, so "overlapping" means within about
> 64 m, not merely intersecting. Give each Sim its own layer, or press Simulate on both. Not warned about
> yet — the check needs the tile-snapped box, and it belongs with the phase-2 bookkeeping.

---

## 13. Node model

```gdscript
@tool class_name Pasture3DSim extends Pasture3DTerrainBrush
```

Extending the brush base brings the closed-loop spline, area mask with falloff, `_ensure_layer_for`,
reserved layers, undo, dirty-rect orchestration and `composite_height_below`.

| Hook | Value |
|---|---|
| `_map_type()` | HEIGHT (default) |
| `_default_layer_name()` | `"Erosion"` |
| `_get_blend_mode()` | `ADD` |
| `_min_points()` | 3 |
| `_spline_basename()` | `"Area"` |
| `_paint_spline()` | no-op (§12) |

**Idempotency** works as it does for brushes and phase-3 selectors: the initial `z` comes from
`composite_height_below(sim_layer_id, …)` — the surface **below** Sim's own layer — and the delta goes
into that layer. Re-running clears and rewrites onto the same result. Reading the finished composite would
make Sim erode its own erosion and creep every run, the same bug class `base_below` already prevents.

> **Built exactly as above**, all six hooks, and gate H measures 0.000000 m of drift across a re-run
> while its control — the same pipeline seeded from the finished composite, with the previous bake still
> in the layer — drifts 18.9 m.
>
> Unlike the stamp brushes, **Sim has no destructive fallback.** A brush without the layers Tool API can
> still `set_height` and be useful-but-not-idempotent; Sim cannot, because without a layer stack there is
> no "below" to read and the very first re-run would erode its own output. It refuses and says so.
>
> **Shipped defaults**, calibrated against the demo terrain's own hillshade with
> [bench/SimFieldProbe.tscn](project/bench/SimFieldProbe.gd):
>
> | Property | Default | Why this number |
> |---|---|---|
> | `iterations` | 30 | Enough reorganisation for branching; the network captures between iterations |
> | `erosion_rate` (K) | 0.08 | 26 m of incision into the demo's escarpments over a 500 m loop. 0.02 is barely visible; 0.5 turns the same slopes into badlands |
> | `area_exponent` (m) | 0.45 | The literature value |
> | `hillslope_diffusion` (D) | 0.15 | Smooths below ~16 m at 30 iterations. At 2.0 it fills the channels faster than they are cut and the area comes back rounder than it started |
> | `catchment_margin` | 128 m | As designed (§5) |
> | `falloff_width` | 24 m | Wide enough that a 26 m cut feathers out without a step |
> | `preview_resolution` / `build_resolution` | 4 / 1 | As designed (§6) |
>
> `erosion_rate` is **not scale-free** — the cut per iteration is `K·A^m·slope`, so an area with a much
> larger catchment erodes much harder at the same setting. The tooltip says so and points at Preview.
>
> **Where the erosion goes is worth knowing before tuning:** incision follows slope as well as area, so on
> the demo the smooth plateau interior barely moves while the escarpments beside it grow dendritic gully
> networks. That is correct stream-power behaviour, and it is not what "erode this area" sounds like it
> should do.

`Pasture3DSim` is also registered in `toolbar.gd`'s `PLACEABLE_BRUSHES`, so the Place Brush tool can drop
one. Offset 0, like Pond: Sim only ever erodes the ground it lands on.

---

## 14. Build order and gates

| Phase | Contents |
|---|---|
| **1 — DONE** | Flow routing + depression fill + drainage area + implicit incision + hillslope diffusion; erodability map; preview/build resolutions; catchment margin + mask; `apply_sim_block`; Preview / Simulate / Clear UX |
| **2** | `Pasture3DSimResult` with all four channels |
| **3** | Selector Kinds `FLOW` / `EROSION` / `DEPOSITION` / `WETNESS`; a demo preset pairing an eroded area with a flow-gated relief material |
| **4** | River + lake extraction; Add / Clear Brushes; preview counts; generated layers |

### Gates

Same discipline as `bench/PlowReliefCheck.tscn`: every criterion needs a **control that fails**, and each
must distinguish "measured nothing" from "measured correctly".

| # | Criterion | Control that must fail |
|---|---|---|
| A | **The router is a valid forest.** Every cell has exactly one receiver; no cycles; every path terminates at the boundary. | Skip depression filling → pits create cells with no downhill receiver, and the gate finds them. |
| B | **Depression fill equals basin depth.** On a synthetic bowl, `lake_depth` at the centre matches the bowl's depth to tolerance. | Fill a terrain with no basins → all zero; gate reports "measured nothing". |
| C | **Drainage area is conservative.** Total area accumulated at the outlets equals the cell count × cell area. | Break the topological order → totals disagree. |
| D | **Incision follows the law.** On a uniform slope, incision scales with `A^m` — doubling upstream area increases incision by `2^m`. | `K = 0` → no incision anywhere. |
| E | **Networks are dendritic.** Drainage area is heavy-tailed: a small fraction of cells carry most of the area. | 1 iteration on flat-ish input → near-uniform, so the gate separates "valleys formed" from "everything lowered slightly". |
| F | **Erodability varies erosion spatially.** A soft stripe erodes measurably more than a hard stripe. | Uniform map → both erode equally; the gate distinguishes the mask working from the sim merely running. |
| G | **The boundary is clean.** Delta is exactly 0 outside the loop; the catchment margin is never written. | Bypass the mask → non-zero outside. |
| H | **Idempotent.** Re-running with identical params reproduces the surface. | Read the full composite instead of `composite_height_below` → drifts each run. |
| I | **Deterministic.** Two runs, same params → bitwise identical. | Introduce a set iteration order dependent on hash ordering → differs. |
| J | **Preview agrees with build on large-scale structure.** Low-frequency delta matches within tolerance. | Compare high-frequency content → they differ, as expected; the gate must test the claim actually made. |
| K | **Erosion is monotone where diffusion is off.** With `D = 0`, no cell rises. | Enable diffusion → some cells rise, confirming the gate is sensitive to the thing it measures. |
| L | *(phase 3)* **Sim selectors gate.** A `FLOW`-gated relief material appears in channels, not on ridges. | Selector `strength = 0` → covers everything. |
| M | *(phase 4)* **Clear removes exactly the generated set.** A hand-placed Pond and Trough survive. | Identify generated nodes by name → the authored ones are destroyed. |
| N | *(phase 4)* **Confluences split.** A synthetic Y-shaped catchment yields three segments, not two overlapping paths. | — |
| O | *(phase 4)* **Extraction is monotonic.** Raising `river_area_threshold` never increases the river count. | — |

> **Perf gates need the user's go-ahead before running.** When approved, the number that matters is
> whether a full-resolution build over a large loop stays inside a few seconds, and whether depression
> filling dominates (§11).

### Gate results (phase 1, all passing)

`bench/SimPhase1Gate.tscn`, headless, ~25 s. A–F and I–K drive the solver directly on synthetic fields;
G and H drive a real `Pasture3DSim` on the demo terrain, because masking and idempotency are claims about
the layer and not about the maths.

| # | Measured | Control |
|---|---|---|
| A | 0 orphan roots, 0 non-terminating walks, stack = all 16 384 cells | Fill off → 1 orphan root |
| B | `lake_depth` 24.80 m at the bowl centre vs an analytic spill level of 25.00 m | No basin → max fill 0.00000 m |
| C | Σ at outlets = domain area to 0 relative error | Wrong traversal order → 96% short |
| D | Incision ratio 1.3665 for a doubling of area (2^0.45 = 1.3660) | K = 0 → exactly 0 |
| E1 | Largest catchment = 0.557 of the domain | Uniform plane → 0.0078, one column's worth |
| E2 | Slope–area exponent +0.015 before → −0.308 after (theory −0.45) | Uniform plane, 1 iteration → −0.023 |
| F | Soft stripe erodes 3.72× the hard stripe | Uniform map → ratio 1.000 |
| G | Delta −0.43 m inside, **exactly 0** outside | Unmasked `apply_sim_block` → −1.0 m outside; **and** a K=0/D=0 solve → exactly 0 everywhere |
| H | Re-run drift 0.000000 m | Seeded from the full composite → 18.9 m drift |
| I | 0 of 16 384 elevations and 0 stack entries differ across two runs | One cell nudged 1 mm → 4 elevations differ |
| J | Delta correlation 0.882 at 32 m features (0.905 at 64 m); the node's Preview really does solve 15.5× fewer cells | High-pass residual → 0.639 |
| K | 0 cells rose; deepest incision 22.0 m | Diffusion on → 513 cells rose |

**Three criteria were vacuous and their controls caught it.** Worth recording, because each failed in a
different way:

1. **E's first form** measured the *growth* of the largest catchment under erosion. A noisy hillside
   already carries a random confluence network before a single iteration runs — 0.47 of the domain in one
   trunk on this fixture — so the growth was ×1.01 and the statistic was reading the fixture, not the
   solver.
2. **E's second form** compared mean incision in channel cells against ridge cells and came out
   *negative*. With no uplift, the hillslopes start furthest above their graded profile and so lose the
   most material; that says nothing about whether a valley exists. Both forms reported "no valleys" on a
   run whose hillshade is unmistakably a dendritic valley network. The fix was to stop measuring how much
   came off and start measuring the shape left behind — the slope–area scaling.
3. **J's first form** used relative RMS. It sat near 1.0 at every feature scale and reported total
   disagreement, while the actual spatial correlation was climbing 0.74 → 0.95: it was measuring the
   preview's *magnitude* gap (§6) and calling it a *structural* one. Its "control" was a full-resolution
   comparison, which still contains all the low frequencies and so proved nothing either way; the real
   control is the high-pass residual.

**And one gate control found a real bug in shipping code.** `sim_mask_deltas` was writing the post-solve
*elevation* instead of elevation minus baseline, so every run stamped absolute heights — a 173 m "delta"
on a solve that changed nothing — into an ADD-blend layer. Every gate still passed: they all assert that
something moved, and something certainly had. The criterion that catches it is now gate G's second
control, a null solve with `K = 0` and `D = 0`, which must leave the layer untouched **inside** the loop
as well as outside.

`bench/SimFieldProbe.tscn` is the companion diagnostic: it writes hillshades of the eroded surface, the
log drainage area and the incision field, synthetic and on the demo terrain. Every threshold in E, J and
K was set by looking at those images first and picking numbers that agree with them — two of the three
vacuous criteria above were only recognisable as vacuous because the picture disagreed with the number.

---

## 15. Open questions

1. **Sediment transport.** Yuan et al. 2019 extends the stream power law with deposition while keeping the
   implicit O(n) structure. It would make `deposition` a real channel and add alluvial fans and valley
   fill. The natural phase 5, and the single biggest quality addition after phase 1.
2. **Rainfall multiplier on drainage area.** `A` currently counts cells; weighting by a rainfall map (or
   by altitude, for orographic bias) is a one-line change with a large effect on which valleys dominate.
3. **Base level.** The margin edge is currently the outlet. Should sea level or a `Pasture3DPool` surface
   act as base level instead, so rivers grade to the water they actually reach?
4. **`SimResult` recording its source parameters,** so the UI can warn that a mask is stale relative to
   the node's current settings.
5. **Does phase 4 want `Pasture3DStream` as well as `Trough`** for long thin rivers? Easier to judge once
   phase 1 output exists.
6. **A channel-initiation threshold.** *(Raised by phase 1.)* Stream power is applied to every cell,
   hillslopes included, so at high `erosion_rate` the result develops fine parallel gullies at roughly
   one-cell spacing — visible in the probe's `demo_r05_d015` hillshade. Real landscape-evolution models
   suppress this with a threshold drainage area below which only diffusion acts. Diffusion already
   competes with it (§4.4) but wins only at low rates. A cheap addition, and the single biggest
   improvement to how the output looks at aggressive settings.
7. **Warn when two Sim nodes share a layer and overlap.** §12 records the behaviour; the check needs the
   tile-snapped clear box, so it belongs with phase 2's bookkeeping rather than bolted on here.

---

## 16. Sources

**Internal:** [pasture_3d_gpu_raster.h](src/pasture_3d_gpu_raster.h),
[pasture_3d_brush_raster.cpp](src/pasture_3d_brush_raster.cpp),
[terrain_brush.gd](project/addons/pasture_3d/connectors/terrain_brush.gd),
[trough.gd](project/addons/pasture_3d/connectors/trough.gd) (`width_curve`, `make_descend`),
[pond.gd](project/addons/pasture_3d/connectors/pond.gd),
[PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md](PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md) (§7 selectors, §13 gate
discipline), `PASTURE3D_LAYERS_GUIDE.md`, `PASTURE3D_WATER_BODIES_SPEC.md`,
`PASTURE3D_TAB_SWITCH_FREEZE_SPEC.md`.

**The solver:**
- Braun & Willett, *A very efficient O(n), implicit and parallel method to solve the stream power equation
  governing fluvial incision and landscape evolution*, Geomorphology 2013 —
  [ScienceDirect](https://www.sciencedirect.com/science/article/abs/pii/S0169555X12004618) ·
  [FastScape](https://fastscape.org/fastscapelib-fortran/). The implicit, unconditionally stable scheme
  §4.3 implements.
- Cordonnier et al., *Large Scale Terrain Generation from Tectonic Uplift and Fluvial Erosion*, CGF 2016 —
  [PDF](https://www.cs.purdue.edu/cgvlab/www/resources/papers/Cordonnier-Computer_Graphics_Forum-2016-Large_Scale_Terrain_Generation_from_Tectonic_Uplift_and_Fluvial_.pdf).
  Brought stream power into graphics; the source of the "high-level control over dendritic structure"
  claim.
- Schott et al., *Large-scale Terrain Authoring through Interactive Erosion Simulation*, ACM TOG 2023 —
  [HAL](https://hal.science/hal-04049125v1) · [project page](https://h-schott.github.io/publications/uplift/publi_uplift.html).
  Interactive stream power at scale, with public code.
- Yuan et al., *A New Efficient Method to Solve the Stream Power Law Model Taking Into Account Sediment
  Deposition*, 2019 — [PDF](https://gfzpublic.gfz.de/rest/items/item_4140893_5/component/file_4636888/content).
  The deposition extension in §15.
- Barnes, Lehman & Mulla, *Priority-flood: an optimal depression-filling and watershed-labeling algorithm
  for digital elevation models*, Computers & Geosciences 2014 —
  [arXiv](https://arxiv.org/abs/1511.04463). The §4.1 fill, and specifically the `+epsilon` variant that
  makes a filled lake surface drain instead of being exactly flat.

**Tool survey:**
- [Houdini HeightField Erode](https://www.sidefx.com/docs/houdini/nodes/sop/heightfield_erode.html) —
  separate `height` / `sediment` / `debris` / `flow` / `flowdir` layers; *"most parameters in this node
  can vary spatially if a supplementary mask layer is provided"*, including Erodability. The source of §7.
- [World Machine](https://www.world-machine.com/features.php) ·
  [render extents & project setup](https://help.world-machine.com/topic/render-extents-and-project-setup/)
  — interactive low-res preview then explicit high-res build; memory conservation; tiled builds needing
  blending where variance is high. The source of §6 and the §5 seam warning.
- [Gaea Erosion2](https://docs.gaea.app/node-reference/nodes/simulate/erosion2) — the artist parameter
  vocabulary (downcutting, deposition, inhibition, Rock Softness).
- Mei, Decaudin & Hu, *Fast Hydraulic Erosion Simulation and Visualization on GPU*, PG 2007 —
  [PDF](http://www-evasion.imag.fr/Publications/2007/MDH07/FastErosion_PG07.pdf). The rejected
  alternative, retained here because it remains the right choice if fine fluid detail ever becomes the
  priority.
