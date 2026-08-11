# Pasture3D Sim Node Spec (`Pasture3DSim`)

**Status:** **PHASES 1–5 IMPLEMENTED** (phase 1 2026-08-08, phases 2–4 2026-08-09, phase 5 2026-08-10).
**PHASE 5.5 IMPLEMENTED** (2026-08-10) — the mask preview (§18).
**Phases 6–7 DESIGNED, NOT BUILT** — the manager and pass chain (§19) and moving the solve off the main
thread (§20). Drafted 2026-08-08; **solver replaced the same
day** after a survey of Houdini, World Machine, Gaea and the large-scale-terrain literature (§16).
Target: Godot 4.7, Pasture3D `main`.

> **§17–§20 are appended after §16 on purpose.** Renumbering §1–§16 would break every `§15.n` and `§12`
> reference in the code comments and in these notes, which is the same reason the gate letters are not in
> phase order (see §14). Within §17–§20 the numbering does track phase order, because nothing outside
> this document references them yet — §18 was inserted and the two below it renumbered when the mask
> preview was specced.

Phases 1–4 ship as:

| File | What | Phase |
|---|---|---|
| [pasture_3d_erosion.h](src/pasture_3d_erosion.h) / [.cpp](src/pasture_3d_erosion.cpp) | The §4 solver, as a pure function of a heightfield — no terrain dependency at all | 1 |
| [pasture_3d_sim.cpp](src/pasture_3d_sim.cpp) | `erode_heightfield` / `resample_grid` / `sim_mask_deltas` / `apply_sim_block` / `sim_result_build` on `Pasture3DData` | 1, 2 |
| [pasture_3d_raster_util.h](src/pasture_3d_raster_util.h) | The SDF + ramp primitives Sim's loop mask shares with the spline brushes | 1 |
| [connectors/sim.gd](project/addons/pasture_3d/connectors/sim.gd) | `Pasture3DSim` — area, resolution, mask, layer and UX plumbing | 1 |
| [connectors/sim_result.gd](project/addons/pasture_3d/connectors/sim_result.gd) | `Pasture3DSimResult` — the four §8.2 channels, their extent, and how to sample them | 2 |
| [bench/SimPhase1Gate.tscn](project/bench/SimPhase1Gate.gd) | Gates A–K, all passing with their controls | 1 |
| [bench/SimPhase2Gate.tscn](project/bench/SimPhase2Gate.gd) | Gates P–X, all passing with their controls | 2 |
| [bench/SimFieldProbe.tscn](project/bench/SimFieldProbe.gd) | Hillshade diagnostic — what the solver actually produces, synthetic and on the demo terrain | 1 |
| [bench/SimResultProbe.tscn](project/bench/SimResultProbe.gd) | The same for the masks: one image per channel, plus an RGB composite showing the three occupy different ground | 2 |
| [pasture_3d_relief_ops.h](src/pasture_3d_relief_ops.h) / [.cpp](src/pasture_3d_relief_ops.cpp) | The four sim selector Kinds, the `ReliefSample` fields they read, and `relief_fields_add_sim` | 3 |
| [connectors/relief_selector.gd](project/addons/pasture_3d/connectors/relief_selector.gd) | `Kind.FLOW/EROSION/DEPOSITION/WETNESS` and the `sim_result` reference | 3 |
| [connectors/plow.gd](project/addons/pasture_3d/connectors/plow.gd) | Resolving the result off the material tree, resampling it onto the bake grid, and the four warnings | 3 |
| [demo/data/relief/channel_boulders.tres](project/demo/data/relief/channel_boulders.tres) | The demo preset: gravel that only appears where more than 2 000 m² drains through | 3 |
| [bench/SimPhase3Gate.tscn](project/bench/SimPhase3Gate.gd) | Gate L (L1–L7), all passing with their controls | 3 |
| [pasture_3d_sim.cpp](src/pasture_3d_sim.cpp) | `sim_extract_water` — the drainage tree to river links, the depression fill to shorelines | 4 |
| [connectors/sim.gd](project/addons/pasture_3d/connectors/sim.gd) | Thresholds, surface reconstruction, Preview / Add / Clear Brushes, and the generated Trough and Pond builders | 4 |
| [connectors/terrain_brush.gd](project/addons/pasture_3d/connectors/terrain_brush.gd) | `INTERNAL_CHILD_META` — a brush's own presentation/bookkeeping children do not count as a structural edit | 4 |
| [bench/SimPhase4Gate.tscn](project/bench/SimPhase4Gate.gd) | Gates M (M1–M4), N, O, Y, Z, all passing with their controls | 4 |
| [pasture_3d_sim.cpp](src/pasture_3d_sim.cpp) | `sim_mask_field` — the §17 selector-driven mask field, and the write mask inside `sim_mask_deltas` | 5 |
| [pasture_3d_relief_ops.h](src/pasture_3d_relief_ops.h) / [.cpp](src/pasture_3d_relief_ops.cpp) | `relief_selector_weight` — the selector evaluator exposed to callers outside the relief path | 5 |
| [connectors/sim.gd](project/addons/pasture_3d/connectors/sim.gd) | `erosion_mask` / `write_mask`, the field composition, and the self-reference refusal | 5 |
| [bench/SimPhase5Gate.tscn](project/bench/SimPhase5Gate.gd) | Gates AA–AG, all passing with their controls | 5 |
| [shaders/debug_views.glsl](src/shaders/debug_views.glsl) | `DEBUG_MASK_PREVIEW` — the §18 overlay, editor-only because `_apply_inserts` skips `DEBUG_*` | 5.5 |
| [pasture_3d_material.cpp](src/pasture_3d_material.cpp) | `set_mask_preview` / `clear_mask_preview` with single-owner arbitration, and `get_generated_shader_code` | 5.5 |
| [connectors/terrain_brush.gd](project/addons/pasture_3d/connectors/terrain_brush.gd) | `_show_mask_preview` / `_update_relief_mask_preview` — shared by Sim, Plow and Mound | 5.5 |
| [bench/SimPhase55Gate.tscn](project/bench/SimPhase55Gate.gd) | Gates AS–AV, all passing with their controls | 5.5 |

Sections below carry **Built:** notes wherever the implementation departed from the design, and §14
records the gate results and the criteria that were vacuous until their controls caught them.

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
| Mask storage | **One `Pasture3DSimResult` `.res` per Sim node.** | Optional, diffable, deletable. §8.2. Built: a `sim_result` property, auto-created on the first bake and rewritten on every one; the node raises a configuration warning while it has no file of its own, because an unsaved Resource is serialised *into the scene* and these are megabytes of float. |
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
>
> **Retired for the SOLVE by phase 6 (§19).** Put the loops under a `Pasture3DSimManager` and they become
> passes over one grid, so the drainage is computed continuously across what used to be a boundary — gate
> AJ measures 3.6× the catchment arriving in the downstream loop, and continuity of 1.00 against 0.27 for
> the same two as independent Sims. **The "overlap generously" half still stands**: each pass is still
> masked to its own loop through its own falloff, so loops that merely abut leave a ridge at the join
> whatever computed the drainage.

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

> **Built exactly as specified**, plus the six decisions the design left open. Each is a real fork, so
> each is recorded here rather than left to be re-derived from the code.
>
> **1 — The extent is the SIMULATED area, including the catchment margin, and the values there are
> unmasked.** The loop's falloff is *not* multiplied in. Three reasons, and they are the same reason:
> the channels feeding the loop rim are exactly where a phase-3 selector needs real numbers; the margin's
> flow and incision are physically true statements about real water; and multiplying the ramp in would
> bake the falloff's *shape* into data phase 3 reads as geology. The cost is that `erosion` in the margin
> describes ground the sim never wrote to — a consumer that wants "only where the terrain actually
> changed" must gate on its own brush area, which it already has. Said again in the resource's own
> docstring, because it is the one thing about this resource that surprises.
>
> **2 — `flow` is `log(max(A, 1 m²))`, natural log, and reading it back means `exp()`.** Floored at 1 m²
> so the stored value is never negative and a cell no result covers (stored 0) reads back as the smallest
> catchment there is rather than as a negative area. `Pasture3DSimResult.drainage_area_at()` is the
> sanctioned reader and gate V pins the convention at both ends — the control there is the sum taken
> *without* the `exp()`, which is precisely the mistake an undocumented convention invites.
>
> **3 — `erosion` and `deposition` are the two signs of ONE field: the NET `z_final − z_initial`.** Not
> deposition accumulated per iteration (a cell can gain at iteration 3 and lose it by 20). Net is one
> subtraction; accumulated needs an extra grid and a per-iteration pass. What it commits us to is worth
> stating: the two channels can never both be non-zero at the same cell, and their sum reconstructs the
> delta bit-for-bit. That is gate Q, and it is what catches a mis-indexed or duplicated channel.
>
> **4 — Several loops merge into one grid by "write beats margin".** §2 says one `SimResult` per Sim
> node, so a Sim with several loops has to merge, and where two loops' *simulated* areas overlap the
> answer is genuinely ambiguous: both solved that ground independently and to different answers (§5's
> seam warning). The rule: a cell inside a loop's write area beats a cell another loop merely simulated
> as catchment margin; ties go to the earlier loop; and the four channels always come from the *same*
> loop at a given cell, which is why the merge blits the net delta and splits the signs afterwards rather
> than blitting the two halves. **One loop is a special case with no resampling at all** — the result is
> that loop's own sim grid verbatim, so the shipped common case is bit-exact rather than "the same to
> within a bilinear tap that should have been the identity". Several loops get the union box at the mean
> sim cell size, coarsened with a warning if that would exceed `RESULT_MAX_CELLS` (two distant loops can
> easily ask for a grid far larger than anything that was solved).
>
> **5 — A Preview overwrites a build's masks, exactly as it overwrites a build's height.** The invariant
> is that the result always describes what is currently in the layer; a mask that survived the height it
> came from would be the worst of both. `source_preview` and `source_resolution` are how a reader tells
> which it got, and §6's warning applies to the masks too: a preview is a good guide to *where* and a
> poor one to *how much*. **Clear Simulation empties the masks and, if they have a file, saves the empty
> result over it** — a mask on disk describing erosion the terrain no longer has is the silent staleness
> this phase exists to prevent. Note the asymmetry: the height clear is undoable and this is not, so
> Ctrl+Z brings the erosion back with the masks still empty, and the node's "not written by this Sim's
> last bake" warning is what reports that.
>
> **6 — §15's open question 4 is taken, not deferred.** The resource records the solver settings behind
> it (`source_iterations`, `source_erosion_rate`, `source_area_exponent`, `source_diffusion`,
> `source_catchment_margin`), the node that wrote it, its loop-footprint hash and the time. The node uses
> the hash today to warn that assigned masks came from a different bake; phase 3 gets the rest for free.
>
> **Where the masks come from in the pipeline.** The node solves in chunks so a long build stays
> cancellable, and `want_diagnostics` is deliberately never set on a chunk — it copies five full-grid
> arrays out of the solver, which a chunked build would pay for on every chunk and throw away. Instead
> the masks come from **one extra routing-only pass (`iterations: 0`) over the final surface**. That is
> not only cheaper, it is more correct: the solver builds `flow` and `lake_depth` at the *top* of an
> iteration, so diagnostics taken off the last chunk would describe the network of the surface *before*
> that iteration's incision and diffusion — a mask one iteration out of step with the height shipped
> beside it. The extra pass costs one fill+route, about a thirtieth of a default solve.
>
> **Nothing in the solve ever reads the result back** (§13, gate H). Sim's input is always the surface
> below its own layer; the masks are a pure output.
>
> **What the demo terrain actually produces**, at the shipped defaults over a 500 m loop with a 128 m
> margin ([bench/SimResultProbe.tscn](project/bench/SimResultProbe.gd)):
>
> | Channel | Range | Reading |
> |---|---|---|
> | `flow` | 0 … 12.75 | `exp()` → 1 … 343 889 m² of catchment |
> | `erosion` | −55.05 … 0 m | 485 950 of 581 406 cells |
> | `deposition` | 0 … +3.66 m | 92 405 cells — real, metre-scale, about a fifteenth of the incision |
> | `wetness` | 0 … 145.9 m | 164 910 cells |
>
> Two things in that table are worth not misreading. The 55 m of drop is over the **unmasked simulated
> area**, which includes steeper margin ground and no falloff — the 26.4 m figure the phase-1 notes quote
> is the masked write grid over the loop, and the two are not the same measurement. And the **wetness is
> overwhelmingly the demo terrain's own authored basins, not lakes the sim made**: the same routing pass
> over the surface *before* a single iteration finds 150.4 m of standing water over 185 458 cells, so
> erosion slightly *drained* the map (it cuts outlets), which is what it should do. The probe prints that
> before/after pair for exactly this reason.
>
> The RGB composite the probe writes is the picture that settles it: erosion fills the escarpment gully
> networks, wetness is the one large closed basin, and deposition sits inside that basin's hollows —
> where the §4.3 submerged guard stops incision entirely and only diffusion acts. Three channels, three
> different places, each where the physics says it should be.

---

## 9. Selector integration (phase 3 — the priority payoff) — DONE

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

> **Built.** Four Kinds, four `ReliefSample` fields, one bilinear sample — as designed, and with no
> change to the op program, the wire format or the material contract. What the design did not say:
>
> **The reference is on the SELECTOR, as specified, but a bake takes ONE result.** The brush resolves it
> by walking the compiled material tree (`Pasture3DReliefMaterial.sim_results()`, which the stack
> overrides). Several layers gated on several *different* sims is coherent to want and disproportionate
> to support — it would mean a set of sampled grids per bake indexed by selector id, for a case nobody
> has asked for — so the first wins and the brush warns, naming the count.
>
> **Both unit conversions happen on the way IN, once per cell, not per gated op.** `ReliefSample` carries
> the *area* in m² (the resource stores its log) and erosion as a *positive depth* (the resource stores a
> negative delta), so the evaluator stays a plain comparison and an artist's band reads "more than 2 000
> m² drains through" and "5 to 50 m stripped". The cost is that the conversion now exists in two places
> that must agree — `Pasture3DPlow._sim_fields` and `relief_fields_add_sim` — which is what gate L6 is
> for.
>
> **`_needs_terrain_fields` already covers the sim Kinds**, since a sim selector is still a selector; the
> sim grids are added to the same `ReliefFields` the slope and curvature grids live in, and are built
> only when a sim Kind is actually present. Four extra float grids over the bake area is not a cost to
> pay for a slope gate.
>
> **Four configuration warnings**, because §9's "silent garbage here would be very hard to diagnose" is
> the whole risk of this phase: a sim Kind in use with no result assigned; a result that is empty (the
> Sim was never run, or was cleared); a result that does not cover the brush's whole loop; and several
> different results in one material. "The material stamped nothing" and "the mask is missing" look
> identical on the terrain and have completely different fixes.
>
> **The demo preset** (§14's phase-3 line) is `demo/data/relief/channel_boulders.tres`: a fine craggy
> fractal gated `FLOW` at 2 000 m² with a 1 500 m² fade-in, so gravel appears in the channels the sim
> cut and nowhere else. It ships with `sim_result` null — a preset cannot reference a project's own
> masks — so assigning that one property is the whole workflow.

> **What phase 2 leaves phase 3, and the three things it must not get wrong.**
> 1. **`FLOW` is log-scaled** (§8.2). The GDScript side has `drainage_area_at()`, which is `exp()` of a
>    bilinear sample; the C++ selector will need the same. A selector band expressed in m² of catchment
>    is the artist-meaningful control — "boulders where more than 10 000 m² drains through" — and that
>    means the *band* is un-logged, not the field.
> 2. **The extent runs out to the edge of the catchment margin, and the values there are unmasked**, so
>    `EROSION` is non-zero over ground the sim never wrote to. A relief material keyed on it will paint
>    stripped bedrock outside the loop unless it is also gated by its own brush area.
> 3. `Pasture3DSimResult.sample()` and `covers()` already do the defined-0-outside behaviour this note
>    demands; `is_valid()` distinguishes an empty result from a missing one, which is what the
>    configuration warning should read.

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

> **Built as designed**, with eight things the design left open — the last three added after using the
> node in the editor, where the four defects in §14's phase-4 notes turned up.
>
> **1 — Extraction does not re-solve, and does not store the elevation.** Add Brushes has to work after a
> reload, without the multi-second cost of the solver and without a fifth mask channel (§8.2 is explicit
> that adding one later means re-running every simulation in the project). So the surface the sim
> finished with is **reconstructed**: `composite_height_below(sim layer) + (erosion + deposition)`. That
> is exact by construction, because those two channels *are* the net delta against exactly that ground.
> It is also independent of anything ABOVE Sim's layer, so a flow-gated relief material stamped on top
> does not move the rivers. What it is sensitive to is a change to a layer BELOW Sim's, which moves the
> reconstruction without moving the masks — but that invalidates the erosion just as much, and pressing
> Simulate fixes both. Gate Z measures the reconstruction against the sim's own stored `flow`.
>
> **2 — One routing pass serves both extractions**, and it is the *solver's* own zero-iteration mode
> rather than a second private priority-flood. That is what makes the extracted network the network the
> sim actually produced, and it is why the lake fill costs nothing extra.
>
> **3 — Rivers are a stream-link decomposition.** A channel cell's receiver is always a channel cell
> (drainage area only grows downstream), so the channel set is a forest; cutting it at every cell with
> zero channel donors (a head) or two or more (a confluence) gives exactly §10.1's "one polyline per
> segment between junctions". A junction belongs to every link that touches it, so the polylines *meet*
> rather than leaving a one-cell gap at every confluence.
>
> **4 — Lake components are FOUR-connected, and the shoreline is chained cell edges rather than marching
> squares.** Eight-connected regions can touch at a corner, and a contour traced round one of those is
> not a simple loop — it pinches to a point, and a Pond's polygon fill behaves unpredictably there.
> Four-connectivity costs a couple of extra lakes where a channel narrows to a diagonal and buys a
> boundary that is always a clean ring. The ring itself is built by emitting the cell edges that have dry
> ground on the far side, consistently wound, and chaining them head to tail; the longest ring is the
> shore and any others are islands, which a Pond has no way to express. This runs on cell boundaries
> rather than at the sub-cell waterline the design asked for — the difference is half a cell, and the
> Pond's own falloff is wider than that.
>
> **5 — The marker is metadata, and the water is synchronous.** §10.4's "stored-but-hidden
> `_generated_by_sim` flag" is a `set_meta`, which needs no new exported property on Trough or Pond —
> those are ordinary brushes that know nothing about the sim and should stay that way. Generated brushes
> are found by walking the Sim's whole subtree for that marker, so a rename does not orphan one and
> neither does dragging it out of the `Generated` folder. And both kinds get `add_pool_now()` called on
> them explicitly: a Pond would otherwise seed its own water on the next idle frame, which is one frame
> in which Add Brushes has produced a dry lake.
>
> **6 — A generated brush is PLACED, at the centre of its own feature.** The extractor answers in world
> coordinates and a `Curve3D`'s points are local to their `Path3D`, so a brush parented under a Sim that
> is not at the origin lands offset by the Sim's transform unless something places it. The points are
> stored relative to the feature's centroid and the node is moved there, which also puts the gizmo *on*
> the river — grabbing a generated one to nudge it works the way grabbing an authored one does. The
> placement is one-shot (a `PLACE_META` consumed by the first attach) so that undo, which re-attaches the
> same node instance, leaves a brush the user has since dragged exactly where they dragged it.
>
> **7 — Nothing the Sim parents to itself may look like a structural edit.** `Pasture3DTerrainBrush`
> schedules a refresh on any new child, and a refresh of a Sim clears its own footprint (§12) — so simply
> creating the `Generated` folder deleted the erosion the brushes were extracted from. Both the folder
> and the preview overlay carry `INTERNAL_CHILD_META`, which the base class exempts alongside its own
> nameplate. And Preview Water Features now *draws*: an unowned, unshaded line overlay of the extracted
> network, cleared by the next solve, Add Brushes or Clear Brushes. Thresholds are the one part of this
> workflow tuned by eye, and a preview whose only output was a line in the Output dock was
> indistinguishable from a button that did nothing.
>
> **8 — Extraction is clipped to the WRITE area, not the simulated one.** The masks span the loop plus its
> catchment margin (§5, §8.2), so the drainage tree runs out into ground the sim solved but never wrote.
> Features are cut to the loop polygons before any brush is built, which means Preview and Add Brushes
> agree and neither offers a river that is not in the terrain. Rivers are trimmed *at* the boundary — the
> crossing point is interpolated, so a trunk leaving the area still reaches the edge instead of stopping
> at whichever vertex the simplification happened to leave inside — and each surviving run is re-tested
> against `min_river_length`, because a clipped stub is still a stub. Lakes must be **entirely** inside:
> a Pond is one closed loop with no way to express a clipped shore, and half a lake carved past the
> boundary is exactly what this prevents. A basin that straddles the edge is therefore dropped rather
> than half-built, which is the conservative choice and the one that keeps generated work inside the area
> the user drew.

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

> **Built — where each warning lives.** The Sim's own are on `Pasture3DSim`; the sim-selector ones are on
> `Pasture3DPlow`, because it is the brush that resolves the reference and knows whether the result
> covers its loop (§9's Built note lists all four). Phase 2 added two more to the Sim: masks with no file
> of their own, and masks that were not written by this Sim's last bake.

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
> 64 m, not merely intersecting. Give each Sim its own layer, or press Simulate on both.
>
> **Built in phase 2 — this is now warned about** (§15's open question 7, which the section assigned to
> phase 2's bookkeeping). `_get_configuration_warnings()` names the other Sim. The check compares
> *tile-snapped* footprints, not the loops, because that is the box the clear actually drops. It is a
> configuration warning with no gate behind it: the behaviour it reports is the layer clear's, which
> gate G already covers, and what is new here is only the wording.

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
> **Built in phase 2 — the masks do not change any of this.** `sim_result` is an output only: it is
> written after the height commit and never read by a solve, so re-running still reproduces the surface
> exactly and gate H still measures 0.000000 m of drift. The one place the masks touch node state is the
> configuration warnings (§8.2 decision 6).
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
| **2 — DONE** | `Pasture3DSimResult` with all four channels, written on every Preview and Simulate; the multi-loop merge; source-parameter recording (§15.4); the shared-layer overlap warning (§15.7) |
| **3 — DONE** | Selector Kinds `FLOW` / `EROSION` / `DEPOSITION` / `WETNESS`; the unit conversions that make their bands artist-readable; four configuration warnings; `channel_boulders.tres`, a demo preset pairing an eroded area with a flow-gated relief material |
| **4 — DONE** | River + lake extraction; Add / Clear Brushes; preview counts; generated layers |
| **5 — DONE** | Masking: a stack of `Pasture3DReliefSelector`s driving the per-cell erodability field, plus a separate write mask. Reuses phase 3's Kinds, units and falloff semantics; no solver change |
| **5.5 — DONE** | Mask preview: a red overlay on the terrain showing the selector weight, so a band is tuned by eye instead of by baking and inspecting. A `DEBUG_` shader insert, not geometry. Shared with the Plow/Mound relief selectors, so it is not a Sim feature |
| **6 — DONE** | `Pasture3DSimManager`: child Sims become ordered **passes** over one shared grid, chained in memory, committed as one delta to one layer. Clustered by margin-grown loop boxes, with a cell budget that REFUSES rather than coarsening; per-pass mask re-evaluation; one `SimResult`; one water extraction. Retires §5's seam limitation **for the solve** — adjacent loops must still overlap, or the per-pass falloff leaves a ridge at the join (§19) |
| **6.5 — DESIGNED (§21)** | `Pasture3DSimPass`, a container grouping several Sims into ONE pass whose members all read the same input surface; **per-pass Sim Results**, so a chain can be tuned a step at a time instead of only as a whole; build-through (`Simulate To Here`); per-Kind selector presets; and the `CURVATURE` unit fix + measurement radius. Everything §19 got wrong for the act of *tuning* a chain rather than running one |
| **7 — DESIGNED (§20)** | The pure half of the solve moves onto a worker thread. **Gated on profiling first** — if the commit dominates the build, this buys much less than it appears to (§11, §20.6) |
| **8 — NOT YET SPECCED** | Let a landform brush's relief selectors read its OWN generated profile. Today a Mound's selector reads the ground *under* the Mound, so on flat ground every Kind returns one constant and "craggy on the flanks, smooth on top" cannot be expressed. Surfaced by the §18 preview; see §15.10. **Spec it after phase 7** |

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
| L | *(phase 3)* **Sim selectors gate.** Seven criteria, because one claim about a gate is not seven. **L1** a `FLOW`-gated material appears in channels, not on ridges. **L2** each Kind reads its OWN channel. **L3** a `FLOW` band is in m², not log units. **L4** an `EROSION` band is a positive depth. **L5** outside the extent the gate is a defined 0. **L6** the two raster paths agree. **L7** a sim-gated bake does not drift. | L1 selector `strength = 0` → covers everything. L2 the band predicted from each channel's own distribution — relief off those cells is a failure. L3 a band of plausible LOG values, which must not light the channels. L4 the resource's own negative sign, which must select nothing. L5 the same brush inside the extent. L6 the relief is not flat. L7 L1 already proved the bake is not a no-op. |
| M | *(phase 4)* **The node-level bookkeeping gate.** **M1** Clear removes exactly the generated set; a hand-placed Pond and Trough survive. **M2** every generated river arrives with water on it. **M3** a generated brush is placed ON the feature it came from — node at the feature's centre, spline retracing the channel in XZ. **M4** everything the Sim parents to itself is exempt from the structural-edit refresh, and Preview Water Features draws one line strip per extracted feature. **M5** no generated brush reaches outside the loop the Sim writes. | M1 identify generated nodes by name → the authored ones are destroyed. M2 the authored Trough must be dry, or "generated rivers have water" is not measuring the pool path. M3 the same points read as if unplaced, which must be hundreds of metres out — otherwise the site is at the origin and placement is untestable there. M4 the Sim's own spline, which must NOT be exempt, or the exemption is blanket. M5 the extraction before the clip, which must reach outside — otherwise the site has no margin drainage and the claim is empty. Containment is answered with `Geometry2D`, not with the Sim's own predicate. |
| N | *(phase 4)* **Confluences split.** A synthetic Y-shaped catchment yields three segments, and they PARTITION the channel — summed cell counts exceed the channel cell count only by the junction. | The total a source-to-outlet walk would have produced, computed from the measured trunk length. The count alone is not enough: source-to-outlet also yields three here. |
| O | *(phase 4)* **Extraction is monotonic.** Raising `river_area_threshold` never increases the channel cell count or the link count. | The counts must actually move across the sweep, or monotonicity is trivially true. |
| Y | *(phase 4)* **Lakes come off the depression fill at the right size and depth.** A paraboloid bowl in a FLAT plain floods to `πR²(1 − threshold/depth)` and its 90th-percentile depth is `0.9 × depth`; the shoreline encloses the bowl. | No bowl → no lakes. And `min_lake_area` raised above the bowl → it is filtered out. |
| Z | *(phase 4)* **The eroded surface is reconstructed exactly** from the masks, so extraction never re-solves and stores no fifth channel. Routing the reconstruction reproduces the sim's own `flow`. | Route the un-eroded ground instead — the mistake a reconstruction that forgot the delta would make. |
| P | *(phase 2)* **The masks are at SIM resolution over the SIMULATED area.** `cell_size` is `vertex_spacing × divisor`, the extent covers the loop plus its catchment margin, all four channels are `width × height`, the source parameters describe the solve that ran, and a Clear empties them. | The same node with margin 0 at build resolution, where the sim grid and the write grid coincide — it must match the write grid, or the fixture above was not separating the two. |
| Q | *(phase 2)* **`erosion` and `deposition` are the two signs of one field.** No cell carries both, and their sum reconstructs the net delta exactly. | `deposition := \|erosion\|` — a duplicated channel. Both halves of the criterion must fail. |
| R | *(phase 2)* **With `hillslope_diffusion = 0`, deposition is IDENTICALLY zero.** Not small — 0.0 on every cell. | Diffusion on → cells deposit, so an exact zero is not vacuous. |
| S | *(phase 2)* **The deposited volume matches a closed form.** A Gaussian bump on a flat plain with `K = 0` diffuses to a known Gaussian, so the deposited ring's volume is computable; and with the bump far from the boundary, Σdeposition must equal Σerosion. | The same bump with `D = 0` (deposits nothing), **and** the criterion re-run against a doubled field, which must fail — otherwise the tolerance is decoration. |
| T | *(phase 2)* **Deposition lands in concavities.** All of the deposited volume sits where the initial Laplacian is positive; the convex crown gains exactly nothing; the deposition centroid is the bump's own cell. | The same tests against the Laplacian rolled half a domain. It must fail the share test and correlate at zero. |
| U | *(phase 2)* **The masks register with the terrain through their own extent.** Looked up via `min_x` / `min_z` / `cell_size` where the falloff is 1, `erosion + deposition` equals the height the layer actually gained. | The same lookup displaced by one catchment margin → disagreement. |
| V | *(phase 2)* **`flow` is log-scaled and un-logs to drainage area.** Σ`exp(flow)` at the outlets is the domain area — gate C's conservation carried through the log round trip. | The same sum without the `exp()` → wildly short. |
| W | *(phase 2)* **`wetness` carries the depression fill, and only it.** On a zero-iteration solve over a bowl, wetness is the analytic spill depth while erosion and deposition are exactly 0. | A basin-free plane → all zero, so the gate reports "measured nothing". |
| X | *(phase 2)* **Several loops merge by the documented precedence rule.** Two overlapping parts of known constant value: a cell inside a loop's write area takes that loop's value, a margin-only overlap goes to the earlier loop, and all four channels come from the same loop at a given cell. | One part alone, which must claim the shared cell — otherwise the gate cannot tell the two parts apart and the precedence result means nothing. |

> **The lettering runs A–K, L, M–O, P–X and is not in phase order.** L–O were reserved for phases 3–4
> when the table was first written, and phase 2's criteria were added afterwards; renumbering would have
> broken every reference to a gate letter in the code and in these notes. Read the *(phase n)* tags, not
> the alphabet.
>
> **A–Z is now fully consumed**, so later phases letter their criteria **AA onward**: phase 5 AA–AG
> (§17.8), phase 6 AH–AN (§19.8), phase 7 AO–AR (§20.7), phase **5.5 AS–AY** (§18.7) and phase **6.5
> AZ–BH** (§21.9). Phase 5.5 was specced after 6 and 7, and 6.5 after all of them; each takes the letters
> that were free rather than displacing theirs — the same rule that left A–Z out of phase order, applied
> again. Read the *(phase n)* tags, not the alphabet.
> Same reason: a single-letter scheme that has run out is not worth a renumbering that invalidates every
> existing reference.

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

### Gate results (phase 2, all passing)

`bench/SimPhase2Gate.tscn`, headless, ~4 s. Phase 1's gates were re-run unchanged afterwards and still
pass with identical numbers.

| # | Measured | Control |
|---|---|---|
| P | Preview at 1/2 over a 40 m margin: 103² @ 2.00 m spanning X 198…402, against a write grid of 125 @ 1.00 m spanning 238…362. Channels alive: 32.5 m incision, 0.20 m deposition, 29 704 m² largest catchment. Clear leaves them empty | Margin 0 at build resolution → 125² @ 1.00 m spanning 238…362, i.e. exactly the write grid |
| Q | 0 of 16 384 cells carry both signs; reconstruction error **0.000000000 m**; 15 477 eroded and 399 deposited, so both halves exist | `deposition := \|erosion\|` → 15 477 cells carry both, reconstruction error 20.63 m |
| R | **0 cells deposited, max +0.000000 m**, against 22.0 m of incision | Diffusion on → 513 cells deposited |
| S | Deposited 37 272 m³ against a closed form of 37 367 — **−0.25%**. Conservation: 37 391 m³ eroded vs 37 272 deposited, −0.32%. The sampled bump matches its own analytic volume to 0.00% | `D = 0` → exactly 0 m³ deposited; the doubled field → +99.5% off, well outside the 3% tolerance |
| T | **0.0000%** of the deposited volume on non-concave ground; the crown deposits exactly 0; centroid at cell (48.01, 40.12) for a bump placed at (48, 40) | Laplacian rolled half a domain → 7.5% of the volume on non-concave ground (fails the 0.1% criterion by 75×) and correlation +0.000 against the real +0.329 |
| U | 25 probes over a 30.5 m height change; worst \|mask − terrain\| **0.0000 m** | The lookup displaced by one 40 m margin → worst 20.88 m |
| V | Σ`exp(flow)` at the outlets = 262 144.0 m² against a domain of 262 144.0 (rel err 2e-7) | The same sum read linearly → 2 016.5 m², 99.2% short |
| W | Wetness 24.800 m at the bowl centre against an analytic spill level of 25.000; erosion and deposition both exactly 0 on the same zero-iteration solve | No basin → max wetness 0.000000 m |
| X | Write areas take their own loop's value (−1, −2); the margin-only overlap goes to the earlier loop (−1); wetness follows the same cell-by-cell choice | The later part alone claims the shared cell (−2), so the parts are distinguishable |

**Three deliberate breaks were introduced into shipping code to check the gates bite.** This is the part
worth keeping, because two of the three are exactly the failure modes §8.2 predicted.

1. **Swapping the sign split in `sim_result_build`.** Q, R, T, X and U all failed — and **S passed.**
   That is not a defect in S: on a pure-diffusion fixture the eroded and deposited volumes are equal by
   conservation, so a sign flip is invisible to *any* magnitude criterion. It is the whole reason T
   exists, and it is the concrete evidence that "the deposited volume is right" is not a test of the
   deposition channel on its own.
2. **Building the result on the masked write grid instead of the sim grid** — the mistake that produces a
   mask which is non-zero, roughly in the right places, and wrong only in extent and resolution. **P
   failed and U passed**, because the data and the header agreed with each other; they were just both the
   wrong grid. Neither gate catches this alone.
3. **A header that lies about the extent** (`min_x` shifted 8 m with the data left in place). **U failed
   at 21.68 m** and P failed on the extent. This is the complement of break 2, and the pair is why both
   gates are needed: P checks the grid the header *claims*, U checks that the data agrees with it.

### Gate results (phase 3, all passing)

`bench/SimPhase3Gate.tscn`, headless, ~30 s, on a 300 m eroded area over the demo terrain.
`bench/PlowReliefCheck.tscn` was re-run too and still passes: phase 3 touches the relief evaluator on
both paths.

| # | Measured | Control |
|---|---|---|
| L1 | Mean \|relief\| 2.69 m in the channel bin, **0.0000 m** on the ridges | `strength = 0` → ridges back to 2.68 m |
| L2 | Each Kind's own band selects its own 30 predicted cells (2.4–2.7 m) and stamps **0.0000 m** on the other 1 651 | Cross-wiring one Kind to another channel → 1.10 m on the predicted cells and 0.053 m off them |
| L3 | An `m²` band of 184…1e9 gives 2.69 m in the channels | The same numbers read as log units (8…13) → **0.0000 m** in the channels while still stamping 0.41 m elsewhere, so the band is live and simply selecting the wrong population |
| L4 | A band of 2…1e9 m removed gives 2.36 m | The resource's own sign, −1e9…−2 → 0.0000 m |
| L5 | A brush clear of the extent stamps **0.000000 m** | The same brush and band inside it → 2.59 m |
| L6 | Worst \|native − GDScript\| **0.00000000 m** over 1 681 probes, with 3 m sim cells against a 1 m bake grid | Max \|relief\| 6.98 m, so the comparison is not of two flat fields |
| L7 | Re-bake drift **0.00000000 m** after a 7.59 m first bake | — |

**Two of these criteria were vacuous in their first form, and both were caught by disbelieving a clean
result rather than by a control.** The pattern from phase 1 repeated exactly.

1. **L2's first form** baked each Kind with a band admitting everything, then one admitting nothing, and
   required the two to differ. All four Kinds returned *byte-identical* numbers — which is the tell:
   "admit everything" is the ungated material whatever it reads. It passes for a Kind wired to the wrong
   channel, and it passes for a Kind wired to a channel that is **constantly zero** — and at the site the
   gate first used, `DEPOSITION` and `WETNESS` were exactly that, so half the criterion was measuring a
   field of zeros and reporting success. The fix was to read each channel out of the resource in the
   gate, take the band from *that channel's own distribution*, and require the relief to land on the
   predicted cells and nowhere else. The site moved to one where all four channels are alive, which took
   raising `hillslope_diffusion` to 2.0 — at the shipped 0.15 the deposition channel over a small steep
   loop is identically zero, exactly as §8.2 says it is.
2. **L6's first form** ran against the build-resolution result, where the sim grid and the bake grid are
   both 1 m and corner-aligned. Every lookup landed exactly on a sample, both bilinear implementations
   reduced to picking one cell, and the parity came back at exactly 0.00000000 without either
   interpolator having been asked a question. It now runs against a **preview-resolution** result (3 m
   cells against a 1 m bake grid), where the grids do not align. The number is still exactly zero — the
   two implementations really are arithmetically identical — but it is now a measurement.

**Two deliberate breaks confirmed the gate bites**, and the first is worth keeping because of how it
failed. Dropping the `exp()` from the native path only — one line — flipped L3 into its mirror image:
the m² band selected **nothing** while the log band lit up the channels, which is precisely the
inversion the criterion was built around. It took L1, L2's FLOW row, L6 and L7 with it. Cross-wiring
`DEPOSITION` to the wetness channel failed L2's deposition row alone, leaving the other three passing —
the per-Kind discrimination the first form never had.

### Gate results (phase 4, all passing)

`bench/SimPhase4Gate.tscn`, headless, ~25 s. N, O and Y drive `sim_extract_water` directly on synthetic
fields whose answer is known by construction; M and Z drive a real Sim on the demo terrain.

| # | Measured | Control |
|---|---|---|
| N | 149 channel cells → **3 links** (two tributaries of 44 cells, a trunk of 64); 152 cells across the links, **+3** of overlap — the junction, which all three touch | Source-to-outlet would total 213 cells, +64 of overlap |
| O | 1 000 → 32 000 m²: channel cells 991 → 54, links 70 → 2, never rising at any step | The count moved 70 → 2 across the sweep |
| Y | One lake: area 10 896 m² against an analytic 11 108 (**−1.9%**), depth 25.51 m against an analytic p90 of 25.20 (the bowl's *max* is 28.00), 60-point shoreline centred on the bowl to 0.0 m | No bowl → 0 lakes, 0 flooded cells. `min_lake_area` above the bowl → 0 lakes |
| Z | Worst \|log(rebuilt area) − stored flow\| = **4.8e-7** over 231 842 cells | Routing the un-eroded ground → worst 11.0, 208 276 cells past tolerance |
| M | 9 rivers + 1 lake generated, **all 10 arriving with water**; Clear removed exactly 10 and both authored brushes survived; every node origin within **0.0000 m** of its feature's centre and all 62 spline points on the channel to **0.0000 m** in XZ; **0 of 62** points outside the loop, the clip having kept 9 of 11 rivers and 1 of 2 lakes; Preview drew 10 line strips for 10 features and the Sim's only unmarked direct child is its spline | A name-based collector matches **12** — it would take the authored pair too. The authored Trough is dry, so the water criterion is not vacuous. The same points read as if unplaced are 221.1 m (origin) and 469.2 m (spline) out. Before the clip, 3 of 13 features reached outside the loop |

**Two deliberate breaks confirmed the gates bite, and the first shows why N needed two criteria.**
Removing the junction stop from the river walk — so segments run source-to-outlet — still produced
**exactly three links**, because the heads still start segments. The count was unchanged and only the
partition test saw it: 278 cells across the links against 149 channel cells, +129 of overlap. A gate that
had only counted segments, as the original criterion did, would have passed a scheme that carves every
shared trunk once per tributary. Making `collect_generated()` match on name instead of the marker failed
M as designed: `authored Pond alive false, Trough alive false`.

**Two fixture faults were found the same way as in phase 3 — by disbelieving a result.** Gate Z first
compared drainage areas directly and reported 87 758 of 116 281 cells "differing", all by at most
0.018 m²: the stored channel is a float32 *logarithm*, so `exp()`ing it back carries ~1e-7 of relative
error, which on a 100 000 m² trunk looks alarming and means nothing. Routing is topological, so the
comparison belongs in log space, where the real signal is 10.8 and the noise is 5e-7. And gate M's first
site produced **no lakes at all**, so the entire Pond half of §10 was passing untested; the fixture moved
to a site with a basin in it and now requires both kinds. A third fault was in the fixture's own
adversary: an authored brush named `River` dropped beside a generated `River` is silently renamed by
Godot, which quietly removed the naming conflict the control depends on — the authored pair is now
parented one level up, where it can keep the exact name.

**Four defects shipped past this gate and were found by using the node in the editor.** All four are
worth recording, because each says something about what the suite could not see.

1. **Every generated brush was displaced by the Sim's own transform.** The extractor answers in world
   coordinates; a `Curve3D`'s points are local to their `Path3D`. Nothing placed the node, so a Sim at
   (512, 0, 200) — which is this very gate's site — produced brushes 550 m from their rivers. M passed
   anyway, because counts, markers, water and layer assignment are all invariant to position: **not one
   criterion in the entire suite mentioned where anything was.** M3 is that criterion, and re-breaking
   the placement fails M3 and *only* M3, which is the evidence it was previously unguarded. The fix is
   `PLACE_META`, stamped at build and consumed by the first attach, so undo re-attaching a brush the user
   has since dragged leaves it where they dragged it.
2. **Creating the `Generated` folder wiped the erosion.** `Pasture3DTerrainBrush` treats any new child as
   a structural edit and schedules a refresh, and a refresh of a Sim clears its own footprint (§12) — so
   Add Brushes deleted the erosion the brushes had just been extracted from. This one is invisible to
   *any* headless gate: `_can_auto_refresh()` requires `Engine.is_editor_hint()`, so neither the bug nor
   the fix has an observable consequence outside the editor, and a criterion phrased over the refresh
   flag would read identically either way. M4 therefore gates the mechanism — the `INTERNAL_CHILD_META`
   exemption, with the Sim's own spline as the control that must not be exempt — and says plainly that
   it is not gating the symptom.
3. **Preview Water Features created nothing to look at.** It reported to the Output dock and to a
   configuration warning, neither of which is where you are while tuning a threshold, which makes it
   indistinguishable from a broken button. It now draws the extracted network as an unowned line overlay;
   M4 asserts one line strip per extracted feature.
4. **Rivers and lakes were generated out in the catchment margin.** §5 simulates wide and writes narrow,
   §8.2 stores the masks over the whole simulated extent, and extraction reads the masks — so it returned
   drainage that is real in the solve and *absent from the terrain*, because the margin is never written.
   On the demo scene that put Troughs a hundred metres outside the loop, carving ground the sim had not
   touched. Every existing criterion was blind to it for the same reason M3 was: a brush in the margin is
   still generated, still marked, still wet, and — after fix 1 — still placed exactly on the channel it
   came from. Extraction now clips to the loop polygons (grown by `edge_offset`), trimming rivers at the
   boundary and re-testing each surviving run against `min_river_length`. M5 is the criterion, with the
   pre-clip extraction as the control that must reach outside; the gate's own site had to grow from a
   240 m loop to a 380 m one first, because at 240 m the site's only lake was itself in the margin and
   clipping it away left the whole Pond half of §10 untested again.

`bench/SimResultProbe.tscn` is phase 2's picture, the counterpart to `SimFieldProbe` for the height: one
greyscale image per channel over a real demo bake, an RGB composite of erosion/deposition/wetness, and
the before/after standing-water pair that shows how much of the `wetness` channel is the demo terrain's
own authored basins rather than anything the sim made. The channel table in §8.2 comes from its output.

---

## 15. Open questions

1. **Sediment transport.** Yuan et al. 2019 extends the stream power law with deposition while keeping the
   implicit O(n) structure. It would make `deposition` a real channel and add alluvial fans and valley
   fill. The natural phase 5, and the single biggest quality addition after phase 1.
2. **Rainfall multiplier on drainage area.** `A` currently counts cells; weighting by a rainfall map (or
   by altitude, for orographic bias) is a one-line change with a large effect on which valleys dominate.
3. **Base level.** The margin edge is currently the outlet. Should sea level or a `Pasture3DPool` surface
   act as base level instead, so rivers grade to the water they actually reach?
4. ~~**`SimResult` recording its source parameters,** so the UI can warn that a mask is stale relative to
   the node's current settings.~~ **Done in phase 2** — the resource carries the solver settings, the
   writing node's name, the loop-footprint hash and the write time (§8.2, decision 6). The node warns
   today when an assigned result's hash does not match its last bake; the numeric settings are recorded
   for phase 3, which is the consumer that actually needs to say "this mask predates your current rate".
5. ~~**Does phase 4 want `Pasture3DStream` as well as `Trough`** for long thin rivers? Easier to judge
   once phase 1 output exists.~~ **Answered by building it: no, and it already gets one.** A generated
   Trough is handed to `add_pool_now()`, and that path decides what kind of water to build from the
   CURVE, not from the brush class — an open curve becomes a river ribbon. So a generated river carries
   the Trough for the editable spline and the shallow bed, and the ribbon comes free. Gate M asserts
   every generated river arrives with water on it.
6. **A channel-initiation threshold.** *(Raised by phase 1.)* Stream power is applied to every cell,
   hillslopes included, so at high `erosion_rate` the result develops fine parallel gullies at roughly
   one-cell spacing — visible in the probe's `demo_r05_d015` hillshade. Real landscape-evolution models
   suppress this with a threshold drainage area below which only diffusion acts. Diffusion already
   competes with it (§4.4) but wins only at low rates. A cheap addition, and the single biggest
   improvement to how the output looks at aggressive settings.
7. ~~**Warn when two Sim nodes share a layer and overlap.** §12 records the behaviour; the check needs the
   tile-snapped clear box, so it belongs with phase 2's bookkeeping rather than bolted on here.~~
   **Done in phase 2** — `Pasture3DSim._overlapping_sim_on_layer()`, compared on tile-snapped footprints
   and named in the configuration warning. See the §12 note.
8. **Should `deposition` accumulate rather than net?** *(Raised by phase 2.)* §8.2 decision 3 takes the
   net positive part of `z_final − z_initial`, which makes the two channels one field and gives gate Q
   something exact to measure. A cell that gains material at iteration 3 and loses it by 20 therefore
   reports nothing. That is the right answer for "where is there silt now" and the wrong one for "where
   has material passed through", and only the second is affected by the §15.1 sediment-transport
   extension — which would also invalidate gate R's exact-zero control, since a transporting solver
   deposits with no diffusion at all. Re-derive R, do not re-tune it.
9. **A relief material as a mask source.** *(Raised by phase 5, §17.)* A `Pasture3DReliefSelector` gates on
   what the ground is *doing*; it cannot say "erode harder in these patches" from a noise field, which is
   table stakes in Houdini's erosion workflow. A `Pasture3DReliefMaterial` evaluated as a scalar would give
   exactly that, and the op programs already exist. The blocker is normalisation: a relief program emits
   metres, a mask needs 0→1, and **a normalised field is meaningless unless its divisor is stored beside
   it** — printing the constant is not an interface. Decide the normalisation before building this, not
   after.
10. **A landform brush's selector cannot see the landform.** *(Raised by the first editor test of §18 —
    intended as phase 8, after §20.)* A relief selector reads the surface **below** this brush's own layer,
    which is what keeps it from feeding its own relief into its own mask and drifting (§13,
    `relief_selector.gd`). For a Plow over existing terrain that is exactly right. For a **Mound**, the
    ground below its layer is whatever it was placed on — often flat — so slope ≡ 0, curvature ≡ 0 and
    altitude ≡ one constant, every Kind returns the same uniform weight, and *"craggy on the flanks,
    smooth on top"* — the most natural thing to want on a hill — is not expressible at all.

    The mask preview is what made this visible: a uniform red wash over a Mound is the overlay correctly
    reporting that the selector has nothing to grip. Before §18 it just looked like the relief was
    behaving oddly.

    **The fix is well-defined and would not drift**: let a landform brush's selectors read its OWN
    generated profile — the mound surface before relief is applied. That is a deterministic function of
    the loop and the shape parameters, *independent of the relief*, so a selector keyed on it cannot feed
    itself. It needs a decision about which surface each brush exposes (Mound's profile, Ridge's crest
    section, Plow's stamp) and a new field source alongside `base_below`, so it is a phase and not a
    patch. Spec it after phase 7.
11. **Masking hillslope diffusion.** *(Raised by phase 5, §17.3.)* The rate mask is free because the
    erodability field already exists; `D` has no per-cell field, so masking it means a second array through
    `erosion_solve`. Wanted for "smooth the plateau, leave the escarpment sharp", which today can only be
    approximated by splitting into two passes (§19).

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

---

## 17. Masking (phase 5) — DONE

Houdini's erode node says that *"most parameters in this node can vary spatially if a supplementary mask
layer is provided"*, and §7 already took Erodability from it. Phase 5 finishes the thought: the same
per-cell control, driven by **what the ground is doing** rather than by a hand-painted texture.

> **Built as designed, and the "no solver change" claim held literally** — `pasture_3d_erosion.cpp` is
> untouched. Three departures, all small:
>
> 1. **The exports live in a `Masking` group, not `Masks`.** §17.7 said `Masks`, but that group already
>    exists and holds `sim_result` — the *output* masks. Two groups called Masks, one for what goes in and
>    one for what comes out, is a worse inspector than one extra group name.
> 2. **`relief_selector_value` was file-local**, inside an anonymous namespace in
>    `pasture_3d_relief_ops.cpp`. It is now reachable through a one-line `relief_selector_weight` wrapper
>    rather than moved: the point of reusing the evaluator is that a SLOPE band gates a Sim exactly as it
>    gates a Plow, and two copies of that arithmetic would eventually disagree.
> 3. **Mask changes do not trigger the "area changed" warning.** `_area_hash()` covers the loops and the
>    catchment margin, and neither `erosion_rate` nor `iterations` nor `hillslope_diffusion` is in it
>    either — solver settings have never been. Masks are consistent with that, not exempt from it. Editing
>    a mask and not re-simulating leaves stale erosion in the layer with no warning, exactly as editing
>    the rate always has.

### 17.1 The insertion point already exists

The solver samples the erodability field by **normalised (u,v) with bilinear interpolation**
([pasture_3d_erosion.cpp:153](src/pasture_3d_erosion.cpp:153)), so it accepts a field at any resolution —
including exactly the sim grid. `_erodability_lut()` is currently its only producer, from a `Texture2D`.

**A selector-driven mask is a second producer of that same field, and needs no solver change at all.**
That is the whole reason masking is a small phase rather than a large one, and it is why it goes *before*
the manager (§19) rather than after.

### 17.2 What a mask is

An **array** of `Pasture3DReliefSelector`, combined by **multiply**, and multiplied again into whatever
`erodability_map` contributes. Reusing the phase-3 resource verbatim means the Kinds, the units, the
`falloff_low` / `falloff_high` band edges, `invert` and `strength` all mean here exactly what they mean on
a Plow or a Mound, and `to_params()`
([relief_selector.gd:116](project/addons/pasture_3d/connectors/relief_selector.gd:116)) is already the
wire format the evaluator reads.

**Why an array and not one slot.** A relief material gets its compositional power from stacking ops; a Sim
pass has a single mask input. Real masks are conjunctions — *"steep AND above the treeline"*, *"concave
AND not already wet"* — and one selector cannot say that. Multiply is the right combiner because each
selector already returns a 0→1 weight with a soft band, so the product is another soft 0→1 weight and no
new semantics are introduced. A `strength = 0` selector contributes 1.0 and drops out, which keeps
"disable this one" free.

### 17.3 Two masks, not one

The three things a mask could multiply are genuinely different, and collapsing them would be the design
error here:

| Property | Multiplies | Cost | Phase |
|---|---|---|---|
| `erosion_mask` | The per-cell erodability field → the incision rate `K` | Free (§17.1) | **5** |
| `write_mask` | The committed delta, alongside the loop falloff in `sim_mask_deltas` | One more per-cell multiply in an existing pass | **5** |
| *(diffusion)* | `D`, the hillslope term | Needs a second per-cell array through `erosion_solve` | §15.10, **not phase 5** |

`erosion_mask` changes **what the sim solves**: masked-out ground still routes water and still receives
sediment, it just resists incision. `write_mask` changes **what the sim commits**: the solve is untouched,
so drainage stays continuous across the whole area, and only the delta inside the band lands in the layer.

That second one is how you say *"erode the whole hill, but keep only the gullies on the north face"*
without the network re-routing around the part you excluded. They are not interchangeable and gate AD
exists to prove the implementation knows it.

### 17.4 What a mask reads, and at what resolution

**The surface below the Sim's own layer**, the same rule the relief selectors already follow and for the
same reason: reading the finished composite feeds a bake's own output into its own mask and drifts every
run (§13).

**Fields are built at sim resolution, in C++.** `_terrain_fields`
([terrain_brush.gd:2351](project/addons/pasture_3d/connectors/terrain_brush.gd:2351)) is GDScript and
O(cells) over the bake grid; a sim grid plus a 128 m margin is larger than any brush footprint, and
`ERODABILITY_LUT_MAX = 256` exists precisely because that path is too slow to run at full size. Phase 6
then re-evaluates the mask **once per pass** (§19.5), so a GDScript field builder would be run N times.
Build it natively from the start:

```
sim_mask_field(z, cell_size, min_x, min_z, gw, gh, selectors, sim_fields) -> PackedFloat32Array
```

reusing the slope / curvature / altitude derivations the relief evaluator already has and the
`relief_fields_add_sim` conversions for the four sim Kinds. The alternative — capping the mask at 256²
like the erodability LUT — is the fallback if the native work slips, and it must then say in the tooltip
that a `SLOPE` mask so capped measures steepness over multi-metre baselines and under-reports fine slope.

### 17.5 Preview and build diverge a second way

§6 already documents that Preview is a good guide to *where* the valleys go and a poor one to *how deep*.
Masking adds an independent source of the same divergence, and its direction is predictable: slope and
curvature are computed by central differences over the grid spacing, so on a 4× coarser preview grid they
are measured over 4× longer baselines. **A "steep only" mask therefore passes less ground on Preview than
on the build**, and a curvature mask smooths out. Say so in the tooltip; do not add a per-resolution
correction factor, which would be the same fudge §6 already declined.

### 17.6 The sim Kinds on a standalone Sim

`FLOW` / `EROSION` / `DEPOSITION` / `WETNESS` read a `Pasture3DSimResult`. Three cases, and only one of
them is a bug:

- **Pointing a Sim's mask at another Sim's result** — legitimate, allowed, and useful: *"erode here only
  where the upstream sim put water"*.
- **Pointing a Sim's mask at its own result** — this is reading your own output, the exact drift class
  `composite_height_below` exists to prevent. Refuse it, with a configuration warning that names the
  node. Gate AG.
- **Pass 2 masked by pass 1's flow field** — the strongest idiom in the whole feature, and it is *not*
  self-reference because pass 1's fields are a deterministic function of the same below-layer read.
  Phase 6 delivers it (§19.5); phase 5 cannot, and its warning should say which one is missing rather
  than implying the combination is illegal.

  > **Built, and the refusal now knows about the manager.** Under a `Pasture3DSimManager`,
  > `_self_references` returns false: there is nothing to refuse, because a pass's sim Kinds read the
  > previous pass's live fields rather than any resource, and this node's own `sim_result` is ignored
  > entirely (§19.9 departure 4). The phase-5 warning above now points at the manager instead of at a
  > future phase. Gate AL measures the idiom working; gate AG still measures the refusal for a standalone
  > Sim, and the break test confirms the manager did not disable it there.

### 17.7 Node surface

| Property | Group | Meaning |
|---|---|---|
| `erosion_mask: Array[Pasture3DReliefSelector]` | Masks | Multiplied into the erodability field |
| `write_mask: Array[Pasture3DReliefSelector]` | Masks | Multiplied into the committed delta |
| *(existing)* `erodability_map`, `erodability_range` | Erodability | Unchanged; the texture and the mask stack multiply |

Empty arrays reproduce today's behaviour exactly, which makes "unset the masks" a free control for every
gate below and keeps every existing scene byte-identical.

### 17.8 Gates (phase 5)

Lettering continues at **AA** (§14).

| # | Criterion | Control that must fail |
|---|---|---|
| AA | **The rate mask gates incision.** A `SLOPE`-masked bake differs from the unmasked bake *only* where the band passes; inside the band the delta is scaled by the mask weight. | `strength = 0` → bitwise identical to unmasked. And the unmasked-vs-masked pair must differ at all, or the fixture has no ground inside the band and the criterion is empty. |
| AB | **Each Kind reads its own field.** Mirrors L2: a band predicted from each Kind's own distribution over the fixture. | Relief drawn from any *other* Kind's cells is a failure, exactly as in L2. |
| AC | **Selectors combine by product.** Two selectors together gate the intersection, scaled as the product of their weights. | Either selector alone, which must NOT reproduce the pair — otherwise the combiner is `min`, `last-wins`, or ignoring one. |
| AD | **The write mask does not change the solve.** With the same selector on `write_mask`, the `flow` field is bitwise identical to the unmasked run while the committed delta is not. | The same selector moved to `erosion_mask`, where `flow` MUST change. This is the criterion that proves §17.3's two properties are actually two. |
| AE | **Masking is idempotent.** Gate H re-run with both masks populated: re-running reproduces the surface to 0.000000 m. | H's own control — seed from the finished composite and it drifts. |
| AF | **Mask fields register with the terrain.** A `SLOPE` band over a synthetic ramp of known angle gates exactly the cells whose true slope is in the band, at sim resolution. | The same band displaced by one catchment margin → disagreement, the mistake an off-by-one grid origin would make. |
| AG | **Self-reference is refused.** A Sim whose mask points at its own `sim_result` warns and applies no mask. | The same mask pointed at a *different* Sim's result, which must apply — otherwise the refusal is blanket and the useful case was banned too. |

### Gate results (phase 5, all passing)

`bench/SimPhase5Gate.tscn`, headless, ~12 s. AA–AC and AF drive `sim_mask_field` and `erode_heightfield`
directly on synthetic grids; AD, AE and AG drive a real `Pasture3DSim` on the demo terrain, because all
three are claims about the node rather than about the arithmetic.

**The gate computes slope, altitude and curvature itself**, from its own fixture, with its own central
differences. It never asks `sim_mask_field` what the ground is doing and then checks the mask against that
answer.

| # | Measured | Control |
|---|---|---|
| AA | Band splits the fixture 49/51. Mean \|delta\| **outside** the band falls from 20.63 m unmasked to **0.38 m** masked; **inside** it holds at 29.34 → 29.47 m | `strength = 0` reproduces the unmasked solve to **0.000000000 m** — bitwise. Masked vs unmasked differ by 60.86 m, so the criterion is not comparing two identical runs |
| AB | All seven Kinds: **100.0%** of the passing cells are in that Kind's own top decile | Best impostor scores 0.0–11.6% against the owner's 100%. `FLOW`'s best impostor scores 0.0% |
| AC | max \|AB − A·B\| = **8.0e-8** over 16 384 cells, 5 919 of them at partial weight | \|AB − A\| 0.82, \|AB − B\| 1.00, **\|AB − min(A,B)\| 0.24** — the last is what rules out `min` |
| AD | `write_mask`: flow field **0.000000000** different, heights moved **7.14 m** | The same selector on `erosion_mask` moves the flow field by 10.06 — so the two masks are demonstrably not the same thing |
| AE | Both stacks populated, bands split the site at its own median altitude. Bake moves 10.22 m; re-run drift **0.000000000 m** | Clearing the mask moves the surface 21.92 m |
| AF | Passing X span 160.0–236.0 m against a strip at 160.0–240.0 m (one cell of quantisation) | Origin displaced by one margin → the span moves to 120.0–196.0 m |
| AG | Warning present; surface **0.000000000 m** from the unmasked bake | The same band on another Sim's result moves the surface 26.60 m |

**Break tests — each new mechanism disabled in turn, to prove its criterion is the only thing that
catches it:**

| Broken | Fails |
|---|---|
| `_self_references` returns false | AG only, **both** legs |
| The node never composes the erosion mask | AD's control, AE's control, AG's control — the three that guard the node wiring, and nothing else |
| Selectors combined by `min` | AC only, both legs |
| `relief_fields_add_sim` never called | AB's four sim Kinds and AF — and none of the ground Kinds |
| `write_mask` ignored in `sim_mask_deltas` | AD only |

> **Two criteria were vacuous and the break tests found them, not the pass.** AG's "the surface is
> unchanged" leg passed with the refusal *disabled*: the band was `EROSION >= 0.05 m` against the Sim's
> own real masks, which passes essentially every eroded cell, so the composed field came out 1.0
> everywhere and the bake was identical whether or not the mask applied. AG's control had already failed
> for the same reason on the first run — the criterion and its control shared one bad fixture. Both now
> use a synthetic half-domain erosion channel, which gates half the area regardless of the ground.
>
> AE had a milder version: `SLOPE 10–90` and an altitude band a million metres wide both passed almost
> everything, so "idempotent with masks" was barely distinguishable from gate H and the control moved
> 0.22 m of a 21.8 m bake. Bands are now derived from the site's own median height, and the control moves
> 21.92 m.
>
> Phases 1–4 and `PlowReliefCheck` were re-run against the phase-5 build: **all passing, 0 failures.**

---

## 18. Mask preview (phase 5.5) — DONE

A red overlay on the terrain showing where a mask will take effect, live, so a band is tuned **by eye
against the ground** instead of by baking and inspecting the result. Phase 5 shipped the masks; nothing
shipped that lets you see one before committing several seconds of solve to it.

> **Built as designed. Four departures, and one open question answered by reading the code:**
>
> 1. **§18.6's stack question resolved: preview the material's own `selector`.**
>    `Pasture3DReliefMaterial.selector` gates *every op the material emits*, a `Pasture3DReliefStack`
>    included, so the overlay is exact and unambiguous for any material. What it does not cover is a
>    stack's per-**layer** selectors, which gate only their own layer's ops — there is no single field
>    that describes those, and a "composite" would have drawn a mask the bake never applies. Plow and
>    Mound therefore ship a plain `mask_preview` bool, not a path into the material tree.
> 2. **No `Engine.is_editor_hint()` guard.** The first version had one and it made the whole feature
>    invisible to a headless gate — the phase-4 lesson repeating itself. It is also *inconsistent*: every
>    other debug view on this material (`set_show_heightmap` and the rest) works at runtime. The preview
>    now behaves like its neighbours, and the `DEBUG_` insert naming is what keeps it out of a shipped
>    shader.
> 3. **`get_generated_shader_code()` added to `Pasture3DMaterial`.** Needed to gate AV, and useful on its
>    own — see the note below on why the obvious alternative does not work.
> 4. **`sim_mask_field` renamed `selector_mask_field`**, as §18.2 asked. Nothing in it was ever
>    sim-specific.
>
> **A trap worth recording: `RenderingServer.get_shader_parameter_list()` cannot see a removal.** It
> looked like the natural way to ask whether a `DEBUG_` insert is compiled in, and it answers the *add*
> direction correctly — but it caches per shader RID and never purges uniforms that disappear. Verified
> against the shipped `set_show_heightmap(false)`, which leaves `heightmap_black_height` in the list
> exactly the same way. Gate AV would have passed on a preview that never uninstalled itself. Read the
> generated source instead.

**This is not a Sim feature.** `Pasture3DReliefSelector` is the same resource that gates Plow and Mound
relief materials (`PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md` §7), so the preview belongs to the *selector*,
and it lives on the material plus a shared brush-side helper. A Sim-only version would have to be written
twice.

### 18.1 Where it hooks, and why not the three easier options

The terrain is a clipmap of raw `RenderingServer` instances
([pasture_3d_mesher.cpp:128](src/pasture_3d_mesher.cpp:128)) — there are no `MeshInstance3D` nodes, so
`GeometryInstance3D.material_overlay`, the obvious answer, does not exist here.

| Option | Rejected because |
|---|---|
| A `Decal` node | Projects along one axis, so it smears on steep ground — which is exactly where a `SLOPE` mask matters most. It would be least trustworthy precisely where it is most needed |
| An overlay `MeshInstance3D` hugging the surface | A second surface to generate, keep in sync with every bake, and fight for depth. The water-feature overlay gets away with this because it draws *lines*, not a field |
| Painting into a control/color layer | Destructive-adjacent, persists in the data, and would have to be undone. A preview must leave nothing behind |

**Use the shader-insert system**, which is already there for exactly this class of thing:
`//INSERT: NAME` blocks in `src/shaders/`, injected by name, with a `_SETUP` variant declaring the
uniforms. Two reasons it is the right hook and not merely an available one:

- `_apply_inserts` **skips every `DEBUG_*` and `EDITOR_*` insert** unless a toggle explicitly pushes its
  name ([pasture_3d_material.cpp:131](src/pasture_3d_material.cpp:131)). Naming the pair
  `DEBUG_MASK_PREVIEW` / `DEBUG_MASK_PREVIEW_SETUP` therefore makes it **editor-only for free** — the
  shipped shader never contains it, so the cost in a game build is exactly zero.
- `v_vertex` is in scope at the injection point (`DEBUG_HEIGHTMAP` already reads `v_vertex.y`), so the
  world XZ needed to look the mask up is already there.

Cost when on: one texture sample and a `mix` into `ALBEDO`, in a variant nobody ships.

### 18.2 The data path, and the one rule that makes it worth having

1. The brush builds the weight field with `sim_mask_field` — the **same call the bake makes**.
2. Packs it to an `Image` (single channel, `FORMAT_RF`) → `ImageTexture`.
3. Hands the material the texture and the field's world rect.
4. The insert samples it at `v_vertex.xz`, mapped through that rect, and mixes red into `ALBEDO` by the
   weight.

> **The preview must call the function the bake calls.** A second implementation — a GDScript
> approximation, a coarser field, a different source surface — would mean tuning a band against a mask
> that will never run, which is worse than having no preview at all. This is the same rule the gates
> follow in reverse: there, the gate must *not* ask the code under test; here, the preview must ask
> nothing else.
>
> `sim_mask_field` is already general enough — it takes a height grid and a selector block, and nothing
> in it is sim-specific. Only the **name** is wrong for the wider scope. Rename it to
> `selector_mask_field` as part of this phase rather than growing a second entry point beside it.

### 18.3 What it draws

**Weight, not a binary.** `falloff_low` and `falloff_high` are the parameters this feature most exists to
serve, and a hard red/not-red would hide precisely them: the soft shoulder of a band is invisible in a
two-colour view. Alpha is proportional to weight.

- `mask_preview_color`, default a red at moderate alpha, so the underlying material still reads through.
- An optional brighter line at weight 0.5, so the nominal band edge is locatable rather than merely
  implied by a gradient.
- **Outside the field's rect, draw nothing.** A clamped sampler paints the horizon with the edge value
  and reads as "this mask covers the world"; the insert must test the rect and leave `ALBEDO` alone.

**At build resolution, not preview resolution.** §17.5 records that slope and curvature are measured over
the grid spacing, so a `÷4` field gates differently from the one a build will use. A preview at preview
resolution would show a *different mask* — the exact failure this feature exists to prevent. The field is
cheap (derivation plus N selector evaluations, no solver iterations), so it is affordable to be honest.

**Clipped to where the brush ACTS, not to the grid it is computed on.** The selector weight is defined
over the whole grid, but a brush only applies it inside its own loop, so the raw weight paints the
footprint *rectangle* and overstates the affected area — corners included.

> **Found in the editor on the first build**, where a Mound's red square dwarfed the Mound. Gate AW
> exists because of it, and none of AS–AV would have caught it: they all checked the preview was the
> *selector's* field and none checked it was the *brush's*.

The clip is the brush's own area mask, and where that mask is reachable it is the real one rather than a
copy: `Pasture3DSim` gets `sim_mask_deltas` fed a delta of all ones, which returns the loop mask itself
with edge offset, falloff width and falloff curve applied. The base-class default for the stamp brushes
is the loop **polygon**, a hard edge — deliberately not a reimplementation of each subclass's falloff
ramp, because Mound alone has two flank modes and a curve and a second copy of that arithmetic would
drift from the real one and start lying. So on a stamp brush the overlay shows *where* the mask applies,
not how strongly the brush feathers there.

### 18.4 One preview at a time

`Pasture3DMaterial` belongs to the terrain, so there is exactly one set of preview uniforms. Two brushes
cannot both own it.

Make that explicit rather than letting them fight: the material records the **owner** of the current
preview, and enabling a preview anywhere disables the previous one and tells the previous owner so its
toggle goes back to Off. Two masks painted red at once would be unreadable anyway, so the constraint and
the desirable UX agree.

### 18.5 Clearing it

The same discipline the water-feature overlay follows, and for the same reason: **a stale preview is
worse than none, because it looks authoritative.** Clear on any of —

- the owning node baking, refreshing, or clearing;
- the mask stack, band, or any selector property changing (rebuild, do not leave the old field up);
- the node being deselected, leaving the tree, or losing its terrain;
- the terrain's own layers changing underneath it (the field is built from `composite_height_below`).

**And it must be LIVE.** A `Pasture3DReliefSelector` is a `Resource`: the inspector mutates it in place
and fires `changed`, so a node that does not listen only ever redraws when the toggle is flipped — which
is how the first build shipped, and it makes the overlay useless for the one job it has. Every selector in
a previewed stack is connected, plus the relief material's own `changed` for Plow and Mound, plus the
dirty-rect refresh path so the overlay follows a spline handle as it is dragged.

Rebuilds are **coalesced to the end of the frame**, not debounced on a timer: a slider drag emits about
one change per frame, so a timer would add latency to the one thing that has to feel immediate, while
coalescing costs nothing and collapses a burst of edits into one rebuild. An explicit toggle or a stack
assignment rebuilds *synchronously* — that is a direct instruction, not a burst.

The rebuild has to be cheap enough to run every frame, which rules out two obvious shapes: the area clip
is multiplied in by `selector_mask_field` rather than by a GDScript loop over the grid, and the texture is
packed with `Image.create_from_data` off `PackedFloat32Array.to_byte_array()` — `FORMAT_RF` is one
little-endian float32 per texel, so that is a memcpy instead of `gw*gh` `set_pixel` calls.

**And it must not create anything to show itself.** Resolve the brush's layer, never `_ensure_layer_for`:
a brush that has never baked would otherwise grow a layer just by being looked at. When there is no layer
yet, "below" is the **whole stack** — the brush will be appended at the top on its first bake, so
everything currently in the stack is what it will sit on. Passing `-1` makes `composite_height_below`
return all-NaN and the preview comes back blank on exactly the brushes a first-time user is most likely
to point it at.

### 18.6 Node surface

The toggle lives on the **node**, never on the selector: a `Pasture3DReliefSelector` is a `Resource` with
no terrain, no footprint and no way to draw itself.

| Node | Control |
|---|---|
| `Pasture3DSim` | `mask_preview: {Off, Erosion Mask, Write Mask}` — an enum, not two bools, because the two are mutually exclusive by §18.4 anyway |
| `Pasture3DPlow` / `Pasture3DMound` | `mask_preview: bool`, plus `mask_preview_source` — a dropdown over the material's own selector and each stack layer's |

> **`Pasture3DReliefStack` — settled by editor use, not by the guess above.** The first build previewed
> the material's own `selector` only, on the reasoning that it gates every op the material emits and is
> therefore exact. That is true and it was the wrong call: a stack's own selector is usually empty and
> the ones that matter are on its LAYERS, so the toggle drew nothing, in silence, on the most common
> stack there is. Reported as *"why isn't mask preview working here?"*.
>
> There is still no honest composite — each layer's selector gates only that layer's ops, and no single
> field describes them — so the answer is to **choose** rather than to combine. `mask_preview_source` is
> a dropdown rebuilt from the live material: entry 0 is the material's own selector, then one per layer.
> Per-layer selectors are where a stack gets its power, and they are now the thing you can actually look
> at.
>
> **One level deep.** A layer that is itself a stack contributes its own selector, not its children's;
> listing a whole tree would need a path rather than an index. The node says so in a configuration
> warning instead of letting a nested selector look reachable.
>
> **Two things the dropdown got wrong on its first build, both editor-only and both now gated.**
> `PROPERTY_HINT_ENUM` treats `,` as the entry separator *and* `:` as an explicit value assignment, so a
> label like `Layer 0: Fractal` collapsed the whole list into one unusable entry — the dropdown existed
> and offered nothing to choose between. Labels are sanitised of both characters, and gate AY inspects
> the hint string the inspector will actually parse rather than the source array behind it.
>
> And a property appended by `_get_property_list` always lands *after* the script's own `@export`s, so a
> toggle declared beside `relief` and a dropdown declared dynamically ended up in different sections of
> the inspector. Both are declared dynamically now, under one `Mask Preview` group, which is the only way
> to keep them adjacent.
>
> **And an empty source must say so.** Drawing nothing with no explanation is indistinguishable from a
> broken button — the same defect Preview Water Features shipped with in phase 4, repeated here. The
> warning names the chosen source and lists the ones that do carry a selector.

### 18.7 Gates (phase 5.5)

Lettering continues at **AS** (§14). AW, AX and AY were all added after editor testing, not designed up front — which is most of what §18 learned.

Most of this phase is a visual editor feature and is **headless-blind**, the same accommodation gates M4
and AO make. But the claim that actually matters — *what you see is what will bake* — is fully gateable
without a viewport, and that is where the criteria go. The gate must say in its output that the red
pixels themselves are ungated, rather than letting four green lines imply a rendering test happened.

| # | Criterion | Control that must fail |
|---|---|---|
| AS | **The preview is the bake's own mask.** The texture handed to the material is bitwise `selector_mask_field`'s output over the same grid the bake uses — same extent, same resolution, same source surface. | The same field built at `preview_resolution`, which must DIFFER on a slope band — otherwise the fixture is flat and "same resolution" is an untested claim. |
| AT | **The rect registers.** The world rect handed to the material maps the texture onto the footprint the mask covers, checked by sampling the preview's own mapping at known world points. | The rect displaced by one catchment margin, which must land different cells — the mistake §17.8's AF already caught once in the field lookup. |
| AU | **One owner.** Enabling a preview on a second brush disables the first, and the first node reports Off. | Enable on one brush only, which must stay on — otherwise "exclusive" is indistinguishable from "always off". |
| AV | **It leaves nothing behind.** After disabling, the material carries no preview insert and no preview texture, and the terrain data is unchanged — no layer, no control map, nothing written. | A snapshot taken WITH the preview on, which must differ from the off state, or AV is comparing two identical no-ops. |
| AW | **It shows where the BRUSH acts, not the whole grid.** The lit fraction matches the loop's share of the grid, and previewing creates no layer. | The unclipped field, which must light cells the clipped one does not — if the loop already filled its bounding box there is nothing to clip and the criterion is empty. |
| AX | **Editing a selector rebuilds the overlay.** Mutating a band in place, as the inspector does, leaves the preview equal to the field that band produces. | The edit must be one that actually changes the field, computed independently — nudging a band that gates the same cells either way would make "the texture changed" impossible to fail. |
| AY | **A stack layer's selector can be chosen and previewed**, and an empty source warns instead of drawing nothing. | The two sources must produce different fields (or the index is ignored), and the empty source must warn (or a dead toggle stays indistinguishable from a broken one). |

### Gate results (phase 5.5, all passing)

`bench/SimPhase55Gate.tscn`, headless, ~6 s. **The rendered overlay is ungated** — headless has no
viewport, so nothing here proves the terrain is tinted, that the tint tracks the weight, or that the 0.5
band line is drawn. The gate says so in its own output rather than letting four green lines imply a
rendering test happened. What it does test is the claim the feature rests on: *what you see is what will
bake.*

| # | Measured | Control |
|---|---|---|
| AS | Preview grid 205×205 at 1.00 m, weights spanning 0.000–1.000. **max \|preview − bake\| = 0.000000000** over 42 025 cells — float32 exact through the `FORMAT_RF` round trip, not merely close. The reference is the selector field **times the loop's area mask**, both assembled from the bake's own functions | The same band at ¼ resolution gates differently (mean weight 0.7145 vs 0.7035), compared unclipped against unclipped so the difference is resolution and not the clip |
| AT | **0.000000 texels** of centre error at four corners and an interior point — the half-cell widening lands world samples exactly on texel centres | The origin displaced by one catchment margin moves the lookup 40.0 texels |
| AU | A enables and owns it; B enables, A loses it and B holds it; A turning *itself* off leaves B's preview alone | One brush enabled alone must stay the owner — otherwise "exclusive" is indistinguishable from "never turns on" |
| AV | With it on: owner set, source carries the insert. Off: owner 0, insert gone. Terrain height moved **0.000000000 m** across the whole cycle | The on-state readings, which must differ from the off-state — otherwise AV compares two identical no-ops |
| AW | 14 042 of 42 025 cells lit (**33.4%**) against a loop covering ~36% of the grid; layer count 2 before and 2 after | The unclipped field lights all 42 025 — so there was something for the clip to do |
| AX | Unchanged in the edit's own frame, then **0.000000000** from the expected field one frame later | The edit moves the field by 1.0000, so "the overlay followed" is a claim that could have failed |
| AY | Dropdown offers `Material Selector, Layer 0 (Fractal)` and the inspector hint splits into **2** entries with no colon in either; selecting layer 0 gives a field spanning 0.000–1.000 over 15 625 cells | The empty `Material Selector` warns and claims no overlay; a second layer banded to pass nothing differs from layer 0 by 1.0000 |

**Break tests — each fails only its own criterion:**

| Broken | Fails |
|---|---|
| Half-cell rect correction dropped | AT only |
| Preview built at ¼ resolution instead of the bake's | AS only (both legs: size mismatch, and AT's registration follows from the changed grid) |
| `clear_mask_preview` ignores the owner | AU only, on the "A took down B's preview" leg |
| The insert left compiled in after disabling | AV only |
| The area clip removed | AS and AW — the preview stops being what the bake applies, and starts painting the bounding box |
| The preview creating its layer with `_ensure_layer_for` | AW only |
| The selector's `changed` never connected | AX only |
| `mask_preview_source` ignored (always the material's own selector) | AY only |
| An empty source warning suppressed | AY only |
| Hint-string labels not sanitised of `,` and `:` | AY only — the entry count still parses, but the colon check fires |

> Phases 1–5, `PlowReliefCheck` and `PondBrushCheck` were re-run against the phase-5.5 build: **all
> passing, 0 failures.**

---

## 19. The manager and the pass chain (phase 6) — DONE

```gdscript
@tool class_name Pasture3DSimManager extends Pasture3DSimBase
```

Child `Pasture3DSim` nodes become **ordered passes** over one shared grid. Scene-dock order is stack
order, top to bottom.

> **Built as designed.** The model (§19.2), the clustering and the refusing budget (§19.4), the per-pass
> mask re-evaluation (§19.5) and the mode split (§19.7) are all as written. Eleven departures, recorded in
> §19.9 with their reasons — the two that change what the design *says* are the shared base class the
> extends line above already shows, and one `Pasture3DSimResult` for the manager rather than one per
> cluster.
>
> **The usage note §19.2 did not have, and it will bite:** *overlap adjacent loops.* Step 3 masks every
> pass to its own loop through its own falloff, so two loops that merely ABUT leave a band at the join
> where neither gate reaches 1 and the original ground stands proud as a ridge. The solve is one grid and
> the drainage AREA is continuous — but the routing pass runs over the *written* surface, and it finds a
> divide sitting on the join. The first AJ fixture was built that way and measured 546 m² of catchment
> arriving at the seam and 13 m² leaving it. This is §5's own advice — "overlap generously and let the
> falloff blend" — applying to passes exactly as it applied to Sims, and the manager does not repeal it.
> It only makes the *solve* seamless, which is what it claimed.

### 19.1 Why, and it is not layer sharing

Layer sharing is the *symptom*. Today `_commit` clears the layer over the tile-snapped box before writing
([sim.gd:1376](project/addons/pasture_3d/connectors/sim.gd:1376)), and a layer-mate Sim cannot be
repainted afterwards because `_paint_spline()` is a no-op (§12) — so two Sims on one layer wipe each
other, which is what `_overlapping_sim_on_layer()` warns about. A manager with **one writer** removes the
problem rather than coordinating it.

The reason actually worth building it is **§5's seam limitation**, which today says outright not to tile a
large map from many small loops: neighbouring loops compute drainage independently and disagree at their
shared edge. One grid means water routes continuously across what used to be a boundary. That is a
documented limitation being deleted, and gate AJ is the one that proves it.

### 19.2 The model

1. **One read.** `composite_height_below(manager_layer, …)` over the cluster grid (§19.4) → `z0`.
2. **Chain in memory.** `z0 → pass₁ → pass₂ → … → z_N`. `erode_heightfield` is already a pure `z → z`
   function ([pasture_3d_sim.cpp:201](src/pasture_3d_sim.cpp:201)), so chaining costs nothing to build and
   nothing round-trips through a layer.
3. **Each pass is masked to its own loop**, through the existing §5 polygon + falloff mask.
4. **One write.** The total delta `z_N − z0`, committed to the manager's single layer.

Step 3 is what makes "passes" and "regions" the same mechanism: a pass whose loop spans everything is a
global pass, two passes with disjoint loops are the side-by-side case, and partial overlap is the blend
the falloff already handles. **Passes is the primary reading** — the ordering is meaningful and pass 2
erodes pass 1's output — and non-overlapping children are the degenerate case, not a second feature.

**Idempotency (§13) is preserved and is arguably cleaner than today's**: one read below the manager's own
layer, a deterministic chain, one write into that layer. Nothing in the chain reads the finished
composite. Gate AM re-runs H against it.

### 19.3 What belongs to a pass and what belongs to the manager

| Per pass (the child) | Manager-wide |
|---|---|
| The loop(s) and their falloff | `catchment_margin` |
| `iterations` | `preview_resolution` / `build_resolution` |
| `erosion_rate`, `area_exponent`, `hillslope_diffusion` | The layer binding |
| `erodability_map`, `erodability_range` | `sim_result` |
| `erosion_mask`, `write_mask` (§17) | The water-feature thresholds (§10) |

The split is not arbitrary: **margin and resolution define the grid**, and the grid is shared, so they
cannot vary per pass. Everything else is an argument to one `erode_heightfield` call, and each pass *is*
one call, so all of it varies freely — including `iterations`, which a single-grid "one solve, per-cell
parameters" design could not have offered.

### 19.4 The grid, and the cost risk this introduces

**This is the part most likely to go wrong.** A naive union of five loops spread across a scene solves a
bounding box that is mostly ground nobody asked about — potentially far more expensive than the five
independent Sims it replaces. `RESULT_MAX_CELLS` already exists because a multi-loop union box gets huge
(§8.2).

- **Cluster, do not union blindly.** Group children whose margin-grown boxes overlap (connected
  components), and solve one grid per cluster. Two landforms 2 km apart stay two solves; two that share a
  catchment become one. A pass whose loop reaches into several clusters runs once per cluster.
- **A cell budget refuses, it does not silently coarsen.** §8.2 coarsens the *masks* when they get too
  big, which is a lossy output. Coarsening the *solve* changes the result, and §6 has already measured
  that a coarser grid erodes deeper — so a manager that quietly dropped resolution would hand back a
  different landscape with no indication. Refuse, name the cluster, and say what to split.
- **Cost is unmeasured.** §11 profiling still has not been done and needs the user's go-ahead. No
  performance claim in this section has a number behind it.

### 19.5 Per-pass mask re-evaluation — the reason to chain

Each pass's masks (§17) are evaluated against **that pass's input surface**, not once up front. Pass 1
cuts valleys; pass 2's `CURVATURE` mask then sees the hollows pass 1 just made and can fill them. That is
the Houdini idiom and it is the entire argument for ordering the children.

**This is not the drift bug, and it will look like it.** Nothing reads the finished composite; every
pass's input is a deterministic function of one below-layer read, so a re-run reproduces the whole chain
exactly. Gate AM measures it; gate AL proves the re-evaluation is really happening, with "evaluate once up
front" as the control.

**The sim Kinds read the previous pass's live fields**, from the zero-iteration routing pass `_diagnose()`
already performs, not from a `.res` on disk. Pass 1 has no predecessor: its sim Kinds read a defined 0
everywhere and the manager warns, exactly as §9 does outside a result's extent. Nothing is invented.

**Not per iteration.** Re-evaluating inside the solve would be the fully coupled version — slope changes
every iteration — and it belongs in C++ if it is ever wanted. Per pass is a deliberate granularity choice,
not an omission.

### 19.6 Outputs

- **One `Pasture3DSimResult` per cluster**, built from the final surface. This falls out unchanged:
  `_diagnose()` already routes the *final* z in a separate zero-iteration pass precisely so the masks are
  not one iteration out of step (§8.2). One result over the whole area also retires a real phase-3
  limitation — today a Plow spanning two Sims can only reference one of their results.
- **One water extraction over the union.** A river crossing what used to be a boundary comes out as one
  Trough instead of two, and a lake spanning it becomes one Pond instead of two halves. Gate AK.
- **One undo action** for the whole build, instead of one per child.

### 19.7 Managed children

A child under a manager stops being a node that bakes and becomes a pass description. Its **Simulate**,
**Preview** and **Add Brushes** buttons delegate upward; its layer binding and `sim_result` are ignored in
favour of the manager's; its configuration warnings say *"this Sim is a pass of `<manager>`"* so the
ignored properties do not read as broken.

This is a mode split inside one class, and it is the ugliest part of the design. It is still preferable to
a second class: a standalone Sim that is later dragged under a manager must keep working, and duplicating
every export onto a `Pasture3DSimPass` guarantees the two drift apart. **Standalone `Pasture3DSim` remains
fully supported and unchanged** — the manager is opt-in, and phases 1–5 do not depend on it.

Composes with a `target_brush` reference (a Sim whose loop tracks a landscape brush's, offset outward):
N children each tracking a landform, one solve, continuous drainage running between them.

### 19.8 Gates (phase 6)

| # | Criterion | Control that must fail |
|---|---|---|
| AH | **The chain feeds forward.** Pass 2's input surface is bitwise pass 1's output, and the committed delta is `z_N − z0`. | Reverse the pass order → the result must differ. If it does not, the passes are being summed independently and the chain is decorative. |
| AI | **One writer.** After a build exactly one layer holds a delta; no child has written to a layer of its own. | Two of today's standalone Sims on one shared layer, which must show the mutual wipe §19.1 describes — otherwise the fixture never had the collision the manager claims to fix. |
| AJ | **The seam is gone.** Two adjacent loops whose catchments cross their shared edge: under one manager, drainage area is continuous across the boundary. | The same two as independent Sims, which must show the discontinuity. If they agree, the fixture has no cross-boundary drainage and the claim is empty. |
| AK | **Features cross the former boundary intact.** A river spanning both loops extracts as one Trough; a lake spanning both as one Pond. | The same site as independent Sims → two Troughs, two half-Ponds. |
| AL | **Masks re-evaluate per pass.** A `CURVATURE` mask on pass 2 gates on the hollows pass 1 cut, not on the original ground. | Evaluate the mask once against `z0` → it gates elsewhere, measurably. |
| AM | **The chain is idempotent.** Gate H against the manager: re-running reproduces the surface to 0.000000 m. | H's own control. |
| AN | **Clustering, and the budget refuses.** Two loops further apart than their margins solve as two grids; moved within a margin they become one. A cluster over the cell budget is refused by name, not coarsened. | Assert the grid *count* changes across the move — a manager that always unions and one that always splits both pass a single-configuration test. And the over-budget case must produce a refusal, not a smaller grid. |

Note AI, AJ and AK all depend on a fixture with real cross-boundary drainage. Assert that property of the
fixture directly and report it, rather than inferring it from the criteria passing.

### Gate results (phase 6, all passing)

`bench/SimPhase6Gate.tscn`, headless, ~7 s. Every criterion is a claim about the NODE, so there is no
"drive the arithmetic directly" family here — a pass chain over a clustered grid *is* the plumbing.

**The fixture is synthetic and its key property is asserted, not assumed.** AI, AJ and AK need real
drainage across the boundary between two loops, and "the demo terrain probably slopes that way here" is
not a fixture. The gate writes its own surface — a plane tilted 0.15 in +X, coherent noise at a gradient
the tilt dominates, and one narrow 120 m basin straddling the seam — into a **REPLACE layer created below
every manager's layer**, then verifies the write landed (worst |terrain − formula| **0.000039 m** over 20
probes) and measures the drainage direction itself, by steepest descent over its own analytic surface:
**100.0%** of the seam column over the band AJ measures runs downhill into loop B, 57.3% over the whole
column (the remainder is the basin's own catchment, which drains inward by design).

| # | Measured | Control |
|---|---|---|
| AH | Pass 2's **solver input** is bitwise pass 1's output: **0 of 36 099** cells differ. Pass 1 moved the chain 93.22 m and pass 2 moved it a further 28.49 m, so the handover carries something. Committed delta vs `z_N − z0` over 81 probes: worst difference **0.000000 m** | Passes reversed → the surface moves **23.21 m** |
| AI | After a build and an auto-refresh on each pass: manager layer 7, both passes at **−1**. The manager's layer contributes all 11.68 m of the 11.68 m that moved. The catchment margin, simulated but never written, sits **0.000035 m** from the untouched fixture | Two standalone Sims on one shared layer: Sim 1 eroded its probes by 19.41 m, and after Sim 2 baked **0.0000 m** of it remained — the §19.1 wipe, at probes inside Sim 1's loop, outside Sim 2's, and inside the tiles Sim 2's clear drops |
| AJ | Trunk catchment crossing x = 402, just past the seam: manager **16 553 m²**, independent **4 648 m²**. Continuity across the seam (x 382 → 402): manager **1.00** | The same two as independent Sims: **0.27** — the independent field loses three quarters of its catchment at a boundary the fixture crosses at 100% |
| AK | Manager: 25 river runs, **1** of them reaching both X 352–367 and X 417–432; 3 lakes, **1** of them the basin (at 391, 392 — 3 578 m², 67.5 m deep) | Independent: 36 runs before clipping, 27 after, **0** reaching both windows; 2 lakes before clipping, **0** on the basin |
| AL | The gate's own curvature band holds 1 853 cells over `z0` and 6 917 over pass 1's output. The mask pass 2 **used**: **100.0%** of its passing cells are in the post-pass-1 band, 21.5% in the pre-pass-1 band | Evaluated once against `z0` → 1 853 cells, agreeing with only 21.5% of the real mask. And only 21.5% of the post-pass-1 band was already in the pre-pass-1 band, so the two are genuinely different questions |
| AM | Two passes, one of them masked, so the §19.5 re-evaluation is inside what is being called idempotent. First run moved 83.65 m; re-run drift **0.000000000 m** | H's own control — the same chain seeded from the finished composite — drifts **38.14 m** |
| AN | Loop edges 240 m apart with a 40 m margin → **2** grids; moved to 40 m apart → **1**, spanning 284 m and listing both passes. Over budget: `ok=false`, the reason names both passes | The cluster **count changes** across the move, so neither an always-union nor an always-split manager passes. The refused plan still reports the full 285 × 165 grid, not a smaller one, and the build wrote **0.000000 m** |

**AJ's loose ceiling, reported and not asserted.** An independent Sim's grid cannot route more than
everything upstream of the probe inside its own extent — 16 815 m² here — so "the manager exceeds that"
would be an assumption-free proof that catchment crossed the boundary. It landed **262 m² short**.
Clearing it needs one trunk to carry 25% of the whole domain's upstream area, which is a fact about how
many parallel channels the fixture grows, not about the manager. The number is printed every run;
tightening the fixture until it cleared would have been tuning the gate to its answer.

**Break tests — each mechanism disabled in turn:**

| Broken | Fails |
|---|---|
| Every pass re-seeded from `z0` (the chain cut outright) | AH only |
| Passes folded in without their loop gate | AI only, the margin leg |
| Masks evaluated once against `z0` | AL only, all three legs |
| Clustering always unions | AN only, both cluster-count legs |
| The budget never refuses | AN only, all three budget legs |
| A managed child may reserve its own layer | AI only |
| The chain seeded from the finished composite | AM only |

> **Two criteria were vacuous and the break tests found them, not the pass.**
>
> **AH passed with the chain cut outright.** The capture it compared was taken in `_start_pass`, off the
> chain's own bookkeeping — so it recorded what the chain *intended* to hand over, which stayed correct
> even when every pass was re-seeded from `z0` and the handover meant nothing. It now captures the array
> `erode_heightfield` actually receives, at the call site, where it cannot be anything else.
>
> **AI passed with its guard deleted.** Driving a manager through `simulate_now` never reaches
> `_ensure_layer_for` on a child at all, so "no pass reserved a layer" was true whether or not anything
> prevented it. The gate now pokes each pass down `_refresh_owner` — the path a spline-handle drag takes —
> before looking, and deleting the guard fails it.
>
> **Three measurements were wrong before AJ was right**, and the sequence is worth keeping. A *mean* over
> part of the column measures whether the sampling landed on a channel: drainage area is violently
> concentrated, and it read 24 m² one side of the seam and 1 267 m² the other. The *sum* over the whole
> column looks conserved and is not — a channel meandering in X crosses the same column repeatedly and its
> whole accumulated area counts at each crossing, inflating the two runs by 2.4× and 4.4× and destroying
> the ratio it was meant to predict. The *median* has a closed form on a tilted plane, but the surface
> being routed is the *eroded* one, and on dissected ground the median cell sits near a local divide and
> reads 8 m² whatever is upstream. The **maximum** — the trunk — needs none of that.
>
> Phases 1–5.5, `PlowReliefCheck` and `PondBrushCheck` were re-run against the phase-6 build: **all
> passing, 0 failures.**

### 19.9 Departures from the design

| # | Departure | Why |
|---|---|---|
| 1 | **`Pasture3DSimBase`, a new shared base class**, and the manager extends it rather than `Pasture3DTerrainBrush` | Everything downstream of "there is a `SimResult` and an eroded surface" — §10's extraction, the generated brushes, the layer commit, the `.res` bookkeeping — is identical for both front ends. The exports stay on the subclasses and the base reads them through four hooks, because Godot lists a base script's exports FIRST and moving `sim_result` and the water thresholds up would push `Pasture3DSim`'s Simulation group below its own outputs — a visible change to a node §19.7 promises stays unchanged |
| 2 | **One `Pasture3DSimResult` for the manager, not one per cluster** (§19.6) | The node has one `sim_result` slot, and one resource is what makes the phase-3 limitation §19.6 retires actually retired — a selector points at one thing. Several clusters merge through the same union-box path a multi-loop Sim already uses, coarsened past `RESULT_MAX_CELLS` with a warning. One cluster, the case the design is really about, is bit-exact with no resampling. **The solve is never coarsened; only this output** |
| 3 | **Two new C++ functions**, `sim_chain_blend` and `sim_chain_write` | §19.2's "chaining costs nothing to build" is true of the solve and not of the plumbing around it: the per-pass fold and the final upsample are each O(cells) and would have been GDScript loops over millions of them. Both reuse what exists — the loop gate is `sim_mask_deltas` fed a field of ones, so a pass gates its contribution through the bake's own masker; the upsample uses the same `grid_bilinear` tap |
| 4 | **Sim Kinds under a manager ignore an explicitly assigned `sim_result`** | §19.5 says they read the previous pass's live fields; it did not say what happens to a selector that also names a resource. Live fields always win, and the child warns that the pointer is ignored. The cost is that a managed pass cannot use §17.6's legitimate "point at another Sim's result" case |
| 5 | **A refused cluster refuses the WHOLE build** | §19.4 says refuse and name the cluster; it did not say whether the others still build. Nothing is written at all — a partial build would commit a landscape missing part of its chain and report success |
| 6 | **A multi-loop pass composes overlapping loops as `1 − (1−g₁)(1−g₂)`** | Two overlapping loops on one standalone Sim ADD their deltas (two `apply_sim_block` calls with ADD blend). In the chain each loop folds in sequentially, so the combined weight saturates at 1 instead of doubling the cut. Different from standalone, and better |
| 7 | **`_ensure_layer_for` returns −1 for a managed child** | §19.7 says the layer binding is "ignored"; this makes it structural. A pass cannot reserve a layer by any path, including the auto-refresh a spline drag triggers — and the break test showed the difference is real, not decorative |
| 8 | **`max_cluster_cells` is a new export**, default 4 194 304 | §19.4 required a budget and named no property |
| 9 | **`capture_chain` / `last_chain`**, off by default | AH and AL need the intermediate surfaces. It holds two full grids per pass alive, so it is not exported |
| 10 | **A managed child's spline edit does not clear the manager's layer** | A standalone Sim's auto-refresh clears its own footprint (§12); a pass is on a different layer owner, so a loop drag leaves the erosion in place and only trips the "the passes have changed" warning. Different from standalone, and better — no silent wipe |
| 11 | **The manager's `SimResult` source fields summarise the chain** | §8.2 decision 6 records one value per solver setting and a chain has one per pass. Iterations SUM, because the passes ran in sequence over one grid; the rates record the strongest any pass used; `source_node` names the manager. A sentinel — a negated rate meaning "several" — was the first attempt and is exactly the undocumented convention §8.2's own `flow` note warns about |

> **Superseded in part by phase 6.5 (§21).** Everything above is what the chain DOES and still holds; what
> it does not do is let you tune one. Four days of use produced a container that groups several Sims into
> one pass, per-pass Sim Results, build-through, and the selector fixes that make a sim Kind usable at
> all. Read §21 before building anything on top of this section.

**§19.8's predicted control for AK was wrong in a way worth recording.** It expected two independent Sims
to produce "two half-Ponds" for a lake spanning their boundary. They produce **none**: a Pond is one closed
loop with no way to express a clipped shore, so `_clip_to_write_area` drops a lake whose contour leaves the
write area *whole*. The feature is not halved, it is lost — which is worse, and which is why the control
asserts the lakes existed **before** clipping (2 of them) rather than merely that none survived.

---

## 20. Off the main thread (phase 7)

### 20.1 What actually freezes today, and what does not

**The solve is already chunked.** `_simulate_interactive` yields a frame every `CHUNK_ITERATIONS = 5`
([sim.gd:404](project/addons/pasture_3d/connectors/sim.gd:404)), so the editor is not frozen for the
duration of a build. What is unchunked and on the main thread is everything around it:

| Stage | Work | Chunked today |
|---|---|---|
| `_prepare_solve` | `composite_height_below` + `resample_grid` over the sim box; `erodability_map.get_image()` | no |
| the solve | `erode_heightfield` × `iterations` | **yes**, every 5 |
| `_diagnose` | a full fill + route pass over the final surface | no |
| `_finish_solve` | `sim_mask_deltas` | no |
| `_commit` | `clear_layer_in_area`, `apply_sim_block`, `composite_area`, `update_maps` | no |
| `_write_result` | `sim_result_build`, `ResourceSaver.save` (disk I/O) | no |

So phase 7 is not "move the sim to a thread". It is **move the pure half off and keep the terrain-touching
half on**, and then shorten what remains.

### 20.2 The split, and the seam it uses

`_begin` / `_solve_chunk` / `_finish` was built as a state machine specifically so there could be two
drivers over identical work — straight-through for gates, frame-yielding for the button (§ the bake
comment in `sim.gd`). **A third, threaded driver fits the same seam with no restructuring.** That is the
design paying off, and it is why this phase is small.

| Stage | Thread | Why |
|---|---|---|
| `_begin` | main | Reads terrain regions and a `Texture2D` image |
| the solve loop | **worker** | `erode_heightfield` copies its input into a `std::vector`, calls `erosion_solve`, and copies out — no region access, no servers ([pasture_3d_sim.cpp:201](src/pasture_3d_sim.cpp:201)). **Pure by construction, therefore thread-safe by construction.** |
| `_diagnose` | **worker** | The same call |
| the §17 mask field | **worker** | Pure over `z` |
| `sim_mask_deltas` | **worker** | Confirm purity before moving it; it takes `z`, a polygon and params |
| `_commit` | main | Layer writes, `composite_area`, and `update_maps` touches the RenderingServer |
| `_write_result` | main | `ResourceSaver.save` in-editor is not worth threading for a once-per-bake write |
| the undo action | main | `EditorUndoRedoManager` is main-thread only |

Worth doing while here: `erosion_solve` is already free of `Pasture3DData`. Exposing the worker entry as a
free function rather than a bound method would mean the thread never touches a Godot `Object` at all,
which removes the question rather than answering it.

### 20.3 Keep the chunking on the worker

Chunk on the worker exactly as the main thread chunks today, so **Cancel still lands at a chunk boundary**
and §4.5's guarantee — *N chunks of k iterations is the same solve as one call of N·k* — carries over
untouched. The alternative, an atomic cancel flag checked inside the C++ iteration loop, is a new C++
contract bought for nothing.

### 20.4 Lifetime — the part that will bite

Every one of these is reachable in an editor, and none of them exists on the current synchronous path:

- **The node leaves the tree mid-solve.** Already checked in `_simulate_interactive`; threaded, it also
  needs a join in `NOTIFICATION_PREDELETE` so the worker cannot outlive the node whose arrays it holds.
- **The scene is closed, or the editor reloads, mid-solve.** Same join, from the tree-exit path.
- **`@tool` script hot-reload with a live worker is a crash.** The `_running` flag already blocks a second
  press; it must also survive being asked to reload.
- **Progress printing.** `print` from a worker goes through `call_deferred`, not directly.
- **Several solves at once.** The manager (§19) makes this normal. Passes are sequential by definition and
  cannot be parallelised, but independent **clusters** can — which is the only actual speedup threading
  buys, and only with a manager.

Use `WorkerThreadPool` rather than a raw `Thread`: it is the engine's own pool, it has group tasks for the
cluster case, and it does not leak a thread per node.

### 20.5 Node surface

None. Phase 7 changes no property and no button — Simulate, Preview and Cancel behave as they do now, and
Cancel gains nothing except a shorter wait. A phase that shows up in the inspector has misunderstood the
assignment.

### 20.6 What this does not do — and why it should be profiled first

- **It does not make the solve faster.** The chain is sequential; per-cluster parallelism is the only
  speedup, and it needs §19.
- **It does not remove the commit.** `clear_layer_in_area`, `composite_area` and `update_maps` stay on the
  main thread and are the part felt at the *end* of a build.
- **Nobody has measured which of the two dominates.** §11's incidental wall-clock numbers cover the solve
  only, and the one question §11 actually poses — whether depression filling dominates — is still
  unanswered. **If the commit dominates a full-resolution build, phase 7 buys much less than it looks
  like**, and the right work would be `fill_every` (§11) or a cheaper composite instead.

> **Recommendation: profile before building phase 7.** This is the one phase in this document whose value
> is a measurement nobody has taken. Benchmarks need the user's go-ahead (§11, §14).

### 20.7 Gates (phase 7)

| # | Criterion | Control that must fail |
|---|---|---|
| AO | **The editor stays responsive.** Frame time during a threaded build stays under a stated budget for the whole solve. | The same build on the synchronous path must exceed it — otherwise the fixture is too small to freeze anything and the criterion is measuring nothing. |
| AP | **The threaded result is bitwise identical to the synchronous one.** Gate I extended across drivers, not just across runs. | I's own control — a hash-ordered iteration, which must differ. |
| AQ | **Cancel joins.** Cancelling mid-solve joins the worker, writes nothing to the layer, and leaves the node able to run again. | Assert the solve had *not* finished when Cancel landed, or "cancel worked" is indistinguishable from "the solve completed first". |
| AR | **Teardown is safe.** Freeing the node and closing the scene mid-solve leave no orphan worker and no crash. | A run where the solve completes normally, to show the teardown path is what is being exercised. |

AO and AR are **editor-path criteria and headless-blind**, the same accommodation gate M4 makes: a
headless gate can assert the join and the absence of an orphan task, but the frame-time claim needs an
editor. Say so in the gate output rather than letting a green line imply more than was measured.

---

## 21. Pass containers, per-pass masks and selector presets (phase 6.5) — DESIGNED

Phase 6 shipped a chain that is correct and a workflow that is not usable. This is the addendum that
makes it usable. It is **6.5 rather than 8** because none of it is new capability — every item below is
something §19 either got wrong for practice or left implicit, found by the first person to try to build
a landscape with it rather than a gate.

Placed after §20 because renumbering would invalidate every existing reference to §20.x, and lettering
its gates **AZ onward** for the same reason §14 already records: the free letters, not the next ones.

### 21.1 What phase 6 got wrong, from four days of use

| Reported | What is actually wrong |
|---|---|
| *"I can only iterate over curve"* | A pass is one `Pasture3DSim`, so everything except the loop — rate, diffusion, iterations, falloff, masks — is shared across every loop that pass owns. Several areas that need different **settings** can only be expressed as several **passes**, which forces a chain order onto things that were never meant to be ordered |
| *"the Sim Result is empty, it never fills"* | Partly fixed already (the slot is hidden on a pass now), but the real complaint is underneath it: there is **one** result, at the manager, describing the whole chain. Nothing describes what pass 2 did |
| *"the material preview does not work"* | Very likely downstream of the two above rather than its own defect — see §21.8, which says how to tell before anything is built |
| *"the defaults are good for Slope but not for erosion"* | True, and worse for `CURVATURE`, whose documented range is simply wrong (§21.6) |

The through-line is that **§19 designed for the finished build and not for the act of tuning one.** A
chain you cannot inspect between its steps is a chain you can only tune by running the whole thing and
guessing which pass moved what. §19.5 is the strongest thing in the feature and it is exactly the thing
that makes single-shot tuning impossible: pass 2 reads pass 1's output, so pass 2's behaviour is not a
function of pass 2's settings alone.

### 21.2 `Pasture3DSimPass`, the container

```gdscript
@tool class_name Pasture3DSimPass extends Node3D
```

One pass, many Sims. The manager's stack becomes:

```
Pasture3DSimManager
├── Pasture3DSim              ← pass 1, a pass of one (still valid, still the common case)
├── Pasture3DSimPass          ← pass 2
│   ├── Pasture3DSim          ← member
│   └── Pasture3DSim          ← member
└── Pasture3DSim              ← pass 3
```

`passes()` returns direct children that are **either** kind, in dock order. A bare `Pasture3DSim` child
is a pass of one — every scene built against phase 6 keeps working untouched, and gate BD pins that.

**Not a `Pasture3DTerrainBrush`.** It owns no layer, draws no spline, has no footprint and never paints.
Extending the brush base would inherit a layer binding, an Add Spline button and an Add Water button that
all have to be suppressed again — the manager already pays that tax (§19.9 departure 1) and one node
paying it is enough. It extends `Node3D` and holds the two things a pass genuinely owns: its masks
(§21.3) and its calibration buttons (§21.4).

**One level, no nesting.** A `Pasture3DSimPass` inside a `Pasture3DSimPass` is not a pass of passes, it is
a second way to spell the same thing, and the dock would stop showing the stack order at a glance — the
property §19.2 chose the scene tree for in the first place.

**Every member reads the same input surface.** This is what makes it one pass rather than a folder:

```
z_out = z_in + Σ  gate_i · ( solve_i(z_in) − z_in )
```

Members do not see each other; the next pass sees all of them. Two consequences worth stating because
both are load-bearing:

- **A pass is ORDER-INDEPENDENT.** Shuffling the members of a container must be bitwise identical, which
  gate BA asserts and which the sum above guarantees. That is the whole difference between a member and a
  pass, and it is why the dock order of members means nothing while the dock order of passes means
  everything.
- **Overlapping members ADD.** Where two members' loops overlap their deltas sum, so overlapping loops cut
  deeper. That is what two overlapping stamp brushes on one ADD layer have always done in this codebase,
  and the falloff is the control. Note this is deliberately *not* the `1 − (1−g1)(1−g2)` saturating
  combine a single Sim's own multiple loops use (§19.9 departure 6): that one exists because those loops
  share one solved surface, and these do not.

### 21.3 Per-pass masks — and why per-SIM masks cannot exist

The request was "each sim saves the mask data for its pass, or failing that the container does". **The
fallback is the only coherent option, and it is worth being precise about why**, because the reason is
not implementation difficulty.

| Channel | Attributable to one member? |
|---|---|
| `flow` | **No.** Drainage area accumulates across the entire cluster grid. The area draining through a cell is a property of the whole routed surface; there is no member it belongs to |
| `wetness` | **No.** Standing water comes from a global priority-flood depression fill. A basin can be fed by one member's channel and dammed by another's |
| `erosion` / `deposition` | Yes — each member's masked delta is its own |

A per-Sim `Pasture3DSimResult` would therefore be **half a lie**: two channels global, two local, in one
resource whose docstring says it describes one Sim. §8.2 decision 3 already commits to erosion and
deposition being the two signs of one field, and that field would be a different field from the one flow
and wetness describe. Refuse it.

**So the pass owns the masks, and the rule is: whichever node IS the pass holds them.** A container holds
its pass's result; a bare `Pasture3DSim` that is a direct manager child holds its own again — which means
narrowing the rule that currently hides `sim_result` on every managed Sim from "managed" to "inside a
container". One rule, both shapes, nothing to remember.

**Where they come from is already built.** The manager runs a zero-iteration routing pass between passes
whenever a later pass wants sim Kinds (`_live_fields`, §19.5) and builds the four channels through
`sim_result_build`, the same code the manager's own result uses. Phase 6.5 makes that unconditional when
storage is on, and writes the result to the pass rather than only handing it forward.

**The cost is real and must be visible.** One extra fill+route per pass — about a thirtieth of a solve —
plus four float grids per pass. A 2048² cluster is **64 MB per pass**.

**DECIDED — on by default, in memory; written to disk only on demand.**

- `store_masks` on each pass, default **on**: tuning is the entire point of this phase, and an opt-in
  default would recreate the discoverability trap the `Save Masks` work just closed.
- After a build the masks live on the pass and are immediately inspectable. **Nothing is written to disk
  that was not asked for** — a `Save Masks` button per pass, sharing the §21.3 implementation the manager
  already has, gives that pass's result a `.res` when you want one. Auto-saving N files per Preview into
  the terrain data directory was the alternative and it is a lot of churn for a resource you are still
  iterating on.
- **Plan Clusters reports the total mask memory the current stack would allocate** alongside the cell
  counts it already prints. A number nobody sees until the editor swaps is not a budget.

The manager keeps its own whole-chain result unchanged (§19.6). Per-pass masks are additional, not a
replacement: a relief material keyed on the finished landscape still wants the finished flow field.

### 21.4 Calibrating a pass: build-through, not solo

The stated workflow is "calibrate each pass, then run at the manager level". **A solo button would not
deliver it**, and this is the one place the request needs pushing back on: pass 2's input is pass 1's
output, so pass 2 solved against `z0` is not pass 2. Tuning it in isolation calibrates something that
never runs.

What the workflow actually needs is **build-through**: run passes 1…N, stop, commit, and store pass N's
masks.

- `Simulate To Here` / `Preview To Here` on `Pasture3DSimPass`, and on a bare Sim that is a pass.
- `Pasture3DSimManager.simulate_now(scale, record_undo, up_to_pass := -1)`; −1 keeps today's meaning.
- The manager's `_baked_hash` records the truncation, so a partial build reads as a partial build and the
  node says *"the layer holds passes 1–2 of 4"* rather than looking like a finished bake.

Everything downstream — the clustering, the one write, the undo action — is untouched: this truncates the
pass list and changes nothing else, which is why it is cheap.

### 21.5 Selector presets per Kind

`Pasture3DReliefSelector` defaults to `range_min 25, range_max 90, falloff 10/10` — a `SLOPE` band in
degrees, applied to every Kind. On `EROSION` (metres, 0–55 measured) it passes nothing. On `FLOW` (m²,
1–343 889 measured) it passes a sliver of headwater. The Kind is a units change and the band should
follow it.

**The audit.** Every Kind was measured against its own field over one bake at the SHIPPED defaults
(`erosion_rate` 0.08, `hillslope_diffusion` 0.15, 30 iterations, a 200 m loop with the default 128 m
margin), on a 461 × 461 m grid at 1 m. "Selects" is what the out-of-the-box 25–90 band actually passes:

| Kind | Field range | Median | p90 | Default band selects | Verdict |
|---|---|---|---|---|---|
| `SLOPE` | 0.07 – 75.9 ° | 44.05 | 59.49 | **93.7%** | Units right, band nearly a no-op on steep ground |
| `ALTITUDE` | 1.05 – 365.6 m | 117.87 | 269.73 | 37.7% | Units right, band meaningless without the terrain (§21.10) |
| `CURVATURE` | −2.60 – 3.30 | −0.0031 | 0.203 | **0.0%** | **Broken** — see §21.6 |
| `FLOW` | 1 – 48 503 m² | 12.0 | 73.0 | 29.5% | **Broken — INVERTED**, see below |
| `EROSION` | 0 – 54.7 m | 0.0 | 8.05 | 1.9% | Units right, band an order of magnitude high |
| `DEPOSITION` | 0 – 0 m | 0.0 | 0.0 | 0.0% | Units right; the FIELD is empty here, see below |
| `WETNESS` | 0 – 29.8 m | 0.0 | 0.0 | 0.0% | Units right, band ~50× too high |

**`FLOW`'s default band is worse than useless — it is backwards.** The band is 25–90, and it has an upper
edge, so it selects cells draining 25–90 m² and **excludes every real channel**, which drain thousands.
Someone who picks `FLOW` because they want channels gets mid-hillslope and not the channels. Nothing about
that is visible: the mask is populated, the preview shows red, it is simply red in the wrong places. This
is the strongest argument in §21.5 and it is a stronger one than curvature's, because curvature at least
fails loudly by selecting nothing.

**`DEPOSITION` is empty here, and that is the solver, not the selector.** Measured across a rate/diffusion
sweep on the same site: rate 0.08 / diffusion 0.15 over a smaller loop gives 1 230 deposition cells peaking
at 9.36 m, diffusion 2.0 gives 5 293, and **rate 0.20 gives exactly zero** at any diffusion. §13 already
records that `erosion_rate` is not scale-free; the consequence nobody wrote down is that on steep ground
with a large catchment, incision outruns diffusion everywhere and the deposition channel is identically
zero. A `DEPOSITION` selector then has nothing to gate on and looks broken. **Say so in the tooltip** — it
is the single most likely "this Kind does not work" report after this phase ships.

**Not found, worth recording as clean:** the unit conversions match on both paths — `relief_fields_add_sim`
(C++) and `_sim_fields` (GDScript) both `exp()` the log flow, flip erosion to a positive depth, and clamp
deposition and wetness at zero, so gate L6's parity claim holds for the sim Kinds. `SLOPE` and `ALTITUDE`
are honest in their stated units.

**One gap that is not a Kind:** there is **no validation anywhere that `range_min <= range_max`**. Invert
them and the evaluator's `min(rise, fall)` yields 0 everywhere — the selector silently gates nothing, with
no warning, on any Kind. The Sim already warns about `river_width_min > river_width_max`; this deserves the
same and is a two-line fix.

**Presets, from the audit above and the numbers §8.2 already measured** rather than invented:

| Kind | Range | Falloff | Reading |
|---|---|---|---|
| `SLOPE` | 25 – 90 | 10 / 10 | unchanged |
| `ALTITUDE` | *terrain-derived* | 10% of span | See §21.10 — a constant is wrong here |
| `CURVATURE` | 0.25 – 100 | 0.1 / 0 | Hollows deeper than 0.25 m over the 8 m `measure_radius` its preset also sets |
| `FLOW` | 5000 – 1e9 | 2500 / 0 | The river extractor's own default threshold: "a channel" |
| `EROSION` | 2 – 1000 | 1 / 0 | Where the sim actually cut, against a 0–55 m range |
| `DEPOSITION` | 0.25 – 100 | 0.1 / 0 | Against a 0–3.66 m range — deposition is small and a metre band misses it |
| `WETNESS` | 0.5 – 1000 | 0.25 / 0 | Matches `lake_depth_threshold`: "standing water, not a film" |

**The rule that makes this safe: a preset only applies when the current band is still the OUTGOING Kind's
preset.** Change Kind on an untouched selector and the band follows; change Kind on one you have tuned and
your numbers survive. Silently overwriting an edited band would be worse than useless defaults, because
useless defaults are at least visible. Gate BE asserts both halves.

Also retune the `@export_range` hints per Kind through `_validate_property` — a 0–90 slider on a `FLOW`
falloff measured in square metres is actively misleading, even though the value is `or_greater` and
accepts more.

### 21.6 Curvature: a documentation bug and a missing baseline

Two defects. An earlier draft of this section claimed the documented −1…+1 range was simply false; the
audit says otherwise and the claim is withdrawn. Measured range at 1 m vertex spacing is **−2.60 … +3.30**
with a median of −0.0031 — so "roughly −1 to +1" is the right order of magnitude *at that spacing*. The
real problems are subtler and both still hold.

**1 — The scale is resolution-dependent and presented as if it were absolute.** The code computes the raw
Laplacian in **1/m**:

```
curvature = (z[x+1] + z[x-1] + z[z+1] + z[z-1] − 4·z) / vs²
```

([pasture_3d_relief_ops.cpp:354](src/pasture_3d_relief_ops.cpp:354)). That `1/vs²` means **the same landform
reads 16× smaller on a 4× coarser grid** — so a band tuned on a build does not survive a Preview, and a band
tuned on a 1 m terrain does not survive on a 2 m one. §17.5 documents the effect in general terms; the
docstring quotes −1…+1 as though it were a property of ground rather than of cell size. `relief_scree`
inherits the same assumption, clamping curvature to 0…1 for its toe deposition
([pasture_3d_relief_ops.cpp:189](src/pasture_3d_relief_ops.cpp:189)), which saturates on the upper third of
the measured range.

**The distribution is the practical problem.** Median −0.0031, p90 0.203, extremes past ±2.6: the signal is
a thin spike around zero with rare large values, so a usable band is a fraction of a unit wide and the
shipped 25–90 selects **0.0%** of anything, ever.

**2 — There is no measurement baseline.** It is a one-cell Laplacian, so at 1 m vertex spacing it measures
curvature over 1 m: fine noise, not landform. §17.5 already documents the same effect as the reason a
`CURVATURE` mask reads differently on preview and build. An artist asking for "hollows" means hollows at
some scale, and there is nowhere to say which.

**The fix, in the free slot. DECIDED — metres of deviation, breaking, no compatibility flag.**
`to_params()` already returns a stride-8 block whose **eighth float is unused**
([relief_selector.gd:130](project/addons/pasture_3d/connectors/relief_selector.gd:130)), so the new
parameter costs no stride change and no wire-format break.

**The definition**, which is simpler than "Laplacian × r²" and means the same thing:

```
curvature = mean( height of the sample ring at radius r ) − height at the centre       [metres]
```

Positive is a hollow, negative a ridge, and the number is *how far this cell sits below its surroundings,
in metres, measured over r*. Resolution-independent, the same unit `EROSION` / `DEPOSITION` / `WETNESS`
already use, and "hollows deeper than 0.25 m over 8 m" is a sentence an artist can write. At r = one cell
it reduces to `(Σ4 neighbours − 4·z) / 4`, i.e. the old Laplacian × vs²/4 — so the two are the same
measurement in different units, not a different measurement.

`relief_scree`'s 0…1 clamp is retuned to match, and the docstring corrected.

**DECIDED — the radius applies to `SLOPE` as well** (`measure_radius`, not `curvature_radius`), so a band
can say "steep over 20 m" rather than "steep between two adjacent vertices", which is what you want on
noisy ground. One parameter, two Kinds, one stencil.

> **`measure_radius` defaults to 0, meaning "one cell" — and that is load-bearing.** A default of 8 m
> would silently change the meaning of every `SLOPE` band already authored, which is a second breaking
> change nobody asked for. At 0 the slope computation is bit-for-bit what it is today. `CURVATURE`'s
> preset sets it to 8 m, and curvature is already breaking on the unit change, so it pays that cost once
> rather than dragging slope along with it.

**This breaks existing curvature bands**, including `channel_boulders.tres`. That is the cost of the unit
being wrong; the alternative — a `legacy_curvature_units` flag defaulting to the old behaviour — leaves
every consumer with two conventions and makes the wrong one the default. The demo preset is re-tuned in
the same commit and §21.10 carries the migration note.

### 21.7 The rename, and its real scope

`sim.gd` → `pasture3d_sim.gd`. Two honest observations before doing it:

- **There is no functional collision to fix.** GDScript resolves scripts by path, so
  `res://addons/pasture_3d/connectors/sim.gd` cannot collide with another addon's `sim.gd`, and the global
  identifier is already `Pasture3DSim`. The risk being avoided is theoretical.
- **The consistency argument is real, and it is folder-wide.** `mound.gd`, `plow.gd`, `pond.gd`,
  `pool.gd`, `ridge.gd`, `splat.gd`, `stream.gd`, `trough.gd` and `water_body.gd` are all equally generic,
  and the C++ half of the same features is already `pasture_3d_*.cpp`. **Renaming one file leaves the
  folder half-converted, which is worse than either end state.**

**DECIDED — one folder-wide migration, in its own commit, separate from phase 6.5's behaviour work** so a
bisect can tell a rename from a regression. Every connector takes the `pasture3d_` prefix, matching the
C++ half. What it touches:

1. Every `.gd` keeps its **`.uid` file** so scenes resolve by uid across the rename.
2. `toolbar.gd`'s `PLACEABLE_BRUSHES` references `connectors/sim.gd` **by path** and must be updated.
3. Scenes carry both `uid=` and `path=`; `sculpting_2.tscn` — the live working scene — references
   `connectors/sim.gd` by path and must be resaved.
4. `.godot/global_script_class_cache.cfg` regenerates on the next editor start.

### 21.8 Diagnose the preview before building anything for it

*"The material preview does not work"* has no fix in this spec on purpose, because the likeliest
explanation is that it never had a chance to work:

- A selector with a sim Kind and a **null `sim_result`** reads a defined 0 everywhere and previews blank
  ([terrain_brush.gd:1176](project/addons/pasture_3d/connectors/terrain_brush.gd:1176)) — and until the
  `Save Masks` commit there was no reachable populated result to point it at.
- A sim-Kind band left at the `SLOPE` defaults of 25–90 passes almost nothing (§21.5).

Both are addressed by other parts of this spec. **Re-test with a populated result and a Kind-appropriate
band before speccing a fix**, and if it still fails, that is its own investigation with its own gate — not
a line item folded into this one.

### 21.9 Gates (phase 6.5)

Lettering continues at **AZ** (§14).

| # | Criterion | Control that must fail |
|---|---|---|
| AZ | **A pass's members all read the same input surface.** Every member of a container is handed the identical `z_in`, bitwise, and none of them sees another's output. | Feed member 2 member 1's output → the surface differs. And the members must each MOVE the ground, or "they read the same input" is a claim about two no-ops. |
| BA | **A pass is order-independent.** Shuffling a container's members reproduces the surface to 0.000000 m. | Shuffling the **passes** at manager level, which MUST change it (gate AH's control, re-run one level up). If both are stable the container is not composing anything. |
| BB | **Per-pass masks describe that pass's own output.** The result stored on pass N routes the surface after N, not after N−1 or after the whole chain. | The same comparison against pass N−1's stored masks, which must differ measurably — and the flow field must be non-trivial over the cluster, or the two are both empty. |
| BC | **Build-through truncates and nothing else.** Simulating to pass N gives bitwise the same surface as a full chain whose passes after N are deleted. | The full untruncated chain, which must differ — otherwise the later passes were doing nothing and truncation is untestable here. |
| BD | **A bare Sim under a manager is still a pass of one.** A phase-6 scene reproduces its phase-6 surface to 0.000000 m after the container exists. | The same scene with that Sim moved inside a container, which must be identical too — a container of one is not a different feature. |
| BE | **Kind presets apply to untouched bands and never to edited ones.** Changing Kind on a default selector re-defaults the band; changing it on one with an edited `range_min` leaves every field alone. | Edit a field to the *incoming* Kind's preset value and change Kind — it must still be treated as edited, or "untouched" is being decided by comparing against the wrong Kind. |
| BF | **Curvature is metres of deviation over its radius, and `measure_radius` reaches SLOPE too.** An analytic dome of known geometry reads the deviation the maths says at two different radii, and a slope band over a noisy ramp of known mean grade widens as the radius grows. | The same ground at radius 0 (one cell) vs 16 m, which must differ by the ratio the formula predicts — a radius that changes nothing is a parameter in name only. And `measure_radius = 0` must reproduce today's SLOPE field BITWISE, or the default silently broke every band already authored. |
| BG | **Every Kind's preset selects a useful fraction of real ground.** Each Kind's shipped band, over one bake at shipped solver defaults, selects between 2% and 60% of the simulated area — not 0% and not everything. | The 25–90 band this phase replaces, which must fail for `CURVATURE`, `WETNESS` and `DEPOSITION` (0.0%) and for `SLOPE` (93.7%). This is the audit in §21.5 turned into a standing check, so the presets cannot rot silently. |
| BH | **An inverted band is refused, not silently empty.** `range_min > range_max` raises a configuration warning on the brush that owns the selector. | The same selector with the range the right way round, which must NOT warn — and must gate something, or the warning is the only thing being tested. |

**BB and BC both need a chain whose passes visibly disagree**, the same fixture requirement §19.8 records
for AI/AJ/AK. Assert that the passes moved the ground by different amounts and report it, rather than
inferring it from the criteria passing.

### 21.10 Open questions

1. **The `ALTITUDE` preset cannot be a constant.** A 0–1000 m band is meaningless on a 50 m map and on a
   4 km one. Options: derive from the terrain's actual height range when the Kind is set (needs the
   selector to reach a terrain, which a `Resource` cannot), have the *brush* offer a "fit to terrain"
   action, or leave `ALTITUDE` alone and document that it is the one Kind you always set by hand. The
   third is the honest default until someone wants the second.
2. **Curvature's unit change breaks authored bands** (§21.6) — decided and accepted. Still to do at
   implementation time: sweep the project for `Pasture3DReliefSelector` resources with `kind = 2` and
   re-tune each, not only `channel_boulders.tres`, and say in the commit which ones moved.
3. **Per-pass mask memory at 1× over a large cluster** is the one number that could make the on-by-default
   decision wrong. §11 profiling is still not done and §19.4 still says so; measuring it needs the user's
   go-ahead.
4. **Does a container need its own falloff or edge offset?** Currently every member carries its own and the
   container carries none. If passes routinely want one feathered edge around a *group* of loops, that is
   a real gap — but it is a union-of-polygons problem, not a container property, and it should wait until
   someone hits it.
