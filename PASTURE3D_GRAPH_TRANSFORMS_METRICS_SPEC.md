# Pasture3D Terrain Graph — Transforms, Metrics & Morphology Nodes Spec

**Status:** Phases 1-5 built and gated (2026-08-30). All thirteen nodes exist, run on native C++ or the
GPU, and are covered by gates with live controls.

**Resolved — `HydraulicSaleve` ignored its `dx`/`dy` fields on the native path (found 2026-08-30, fixed
2026-08-30).** Driving either port moved the GDScript result and left the native result bit-identical. The
cause was not the field plumbing, which was correct on both sides: `hydraulic_saleve_solve` applied its
drainage warp only when BOTH `dx` and `dy` were present, and the two evaluators disagree about what an
unwired port is — `_input_grids` hands the solver a zeros GRID, so one axis alone still warped there, while
the compiled program passes `in = -1` (absent), so one axis alone did nothing. A missing component is now a
zero component. The exclusion has been removed from `GraphAllNodeSocketsGate` section F, which sweeps all 95
parameter ports with none skipped.

**§8 amendments (Phase 5).**

* **`FloodingUniformLevel.needs_grid` is `true`, not `false`.** The spec called it a fusible cell node while
  also giving it three output ports, and those are incompatible in this codebase: the cell branch of
  `evaluate()` never populates the aux-channel array, so ports 1 and 2 of a fused node would silently read
  zeros. Any multi-output node here is a grid node — that is not a performance choice, it is what makes the
  extra ports exist at all.
* **`WaterMask`'s `height` port is dropped**, leaving `depth` and `shore_width`. The maths never used it: the
  water mask comes from the depth and the shore band from the signed distance to that mask. A port wired to
  nothing inside the node is worse than a missing one, because it tells the author a value matters when it
  does not.
* **`Mudslide.iterations` is replaced by `travel_distance` in METRES.** An iteration count is a cell-space
  quantity — a sweep advances material about one cell — so twenty iterations would mean eighty metres on a
  4 m grid and twenty on a 1 m one, and the same slide would land somewhere else at every bake resolution.
  That is exactly the class of unit error §3.6 exists to catch. The sweep count is derived from the metric
  knob and the cell size. MD is gated as `travel_distance = 0` accordingly.
* **`Mudslide`'s transport law was rewritten twice, both times because MG measured it failing.** The first
  version limited each sweep's transfer to the local height excess; that is DIFFUSION, whose spread goes as
  cell² per sweep, so the slide ran roughly half as far each time the grid was refined. The second scaled
  the per-sweep fraction by cell/travel, which fixed the thinning but made the mean advance proportional to
  the cell. The law that is invariant is a constant fraction of the mobile POOL moved one cell per sweep,
  with a per-neighbour half-drop cap as a no-inversion safety net rather than as the transport law.
* **MG's statistic is the deposit's mass distribution, not its leading edge.** An edge is found by
  thresholding, and a thinner deposit on a finer grid crosses any fixed threshold sooner, so the measure
  reported the threshold as much as the physics. MG compares the cumulative mass distributions of the two
  deposits (a Kolmogorov-Smirnov distance) against a 20% budget. That budget is calibrated, not aspirational:
  a nearest-neighbour advective sweep carries numerical diffusion proportional to the cell, the residual
  measures ~16%, and the cell-space control sits at ~50%.
* **An all-zero mask on `Mudslide` counts as NO mask.** `Pasture3DTerrainGraph` feeds an unwired port an
  n-sized grid of zeros, so by the time the array reaches the kernel an unwired mask and a deliberately blank
  one are the same bytes. Falling back to the talus gate is the reading that leaves the node useful; the
  other makes an unwired mask a silent pass-through.
* **GPU coverage is partial by design, and every uncovered case still runs compiled C++.**
  `FloodingUniformLevel` has a GPU mode. `Mudslide` has one too — written as a GATHER, since a dispatch has
  no cell order and no atomics here, which is the same algorithm as the CPU's delta accumulation and agrees
  with it to 8e-6 m — but it declines when a mask is wired, because deciding the all-zero question above
  needs a whole-buffer reduction the single-pass plan cannot do. `WaterMask` declines outright: its shore
  band runs the JFA distance transform, whose plan is built inline in the `DistanceTransform` case rather
  than as a reusable sub-plan. Both fall to the native kernel, not to GDScript.
* **One gate file covers §8.1 and §8.2** (`GraphWaterNodesGate`, FLA-FLD and WMA-WMD) because they are one
  pipeline: WaterMask's input is FloodingUniformLevel's depth channel. Mudslide keeps its own
  `GraphMudslideGate`.


**§7.1 amendment.** WB's control was specified as "a noise warp of comparable strength". It cannot be:
the `Warp` node does not resample its input at all — it ADDS a domain-warped noise field on top — so it
can never move a cone's mass whatever its settings, and it would have been a control that passes for the
wrong reason. The control is a rigid `Transform` displacement of the same 40 m instead, and the spread
measure is taken about the mass CENTROID rather than the origin, so a direction-blind translation scores
identically to the input and only genuine spreading registers.

The resample sign is worth recording because it reads correct while being backwards. A resample is a
BACKWARD map: `out(x) = in(x + d)` shifts the surface by `-d`. Sampling at the downhill point — which is
what "warp downslope" sounds like — drags the terrain UPHILL. The kernel samples UPHILL so the surface
moves downhill, and WB is what caught it.

**§7.2 amendments.**

`needs_grid` is **true**, not the false the spec proposed. "Cell, fusible" means having an `eval_cell` the
fold can inline, and an octave loop with derivative feedback is not a per-cell expression. Jordan and
Swiss claim false and are then special-cased back out of the cell path in *two* separate evaluators;
saying true is the same behaviour with one fewer place to forget. The route gate caught the omission
immediately, because the second of those two lists had not been updated.

`angle_spread` **compresses the along-strike axis** rather than jittering the feature points across
strike. The jitter reading was implemented first and does not produce parallel ridges at spread 0: a row
of feature points at a fixed `z` still gives a field that varies in `x`, and GC's anisotropy measure
correctly scored it at 1.04 against a required 2.0. Compressing the axis elongates the Voronoi cells into
strike-parallel ribbons, which does; GC then measured 36.8.

GF is measured as the **99th percentile** of the cross-resolution difference, with the maximum reported
alongside, and the fine grid is read **bilinearly**. Both are stated in the gate. The field is chaotic
exactly at Voronoi walls — a sample a hair either side picks a different winning feature point and the
feedback amplifies that through every later octave — so a thin set of cells genuinely differs between two
samplings of the same continuous field; and cell centres at `(i + 0.5)d` never coincide across
resolutions, so nearest-cell sampling contributes more than the whole budget on its own. GF also runs at a
lower frequency than the other criteria, because at the default the fourth octave is barely above Nyquist
against the coarse cell and the disagreement measured is aliasing rather than units.

GE splits into **two** parity claims. Kernel-versus-oracle with identical doubles holds to 2e-6 (measured:
exactly 0). The graph route cannot, and the reason is honest rather than a tolerance: `GraphProgram`
stores parameters as float32, so `frequency` reaches the kernel as 0.0005000000237, and in a chaotic field
that last bit is worth a few thousandths of a metre. That claim gets its own 0.1%-of-relief budget.

**Phase 3 amendments made during the build.** §6 called for three gate files, one per node. They shipped
as ONE — `project/bench/GraphTerrainMetricsGate.gd` — because all three criteria sets need the same
fixtures (the analytic ridge field, the metric ramp) and the same parity and GPU-route harness, and
three copies of those would have been three places for the definition of "50 metres" to drift. Criterion
names are unchanged: RA-RC, SA-SD, KA-KD, plus the shared parity and GPU blocks.

RC's fixture is the ridge field, not the cone §6.1 suggested. Outside a cone the plain is perfectly flat,
the node correctly returns its 0.5 "neither basin nor crest" midpoint there, and the ring where the disc
just grazes the cone base flips between 0.5 and 0 as the resolution changes — a fact about the fixture's
flat region, not about whether the radius is metric. SE/SF and KE/KF are folded into the shared parity and
resolution work rather than repeated per node.

> **Phase 1** (Transform, Falloff, Contrast) — opcodes 44/45/46, GPU shader modes 4/5.
> Gates: `GraphTransformGate`, `GraphDomainRangeGate`.
>
> **Phase 2** (DistanceTransform, ExpandShrink) — opcodes 47/48, GPU shader modes 6-11.
> Gates: `GraphDistanceTransformGate`, `GraphMorphologyGate`.
>
> The GPU criteria report NO-SIGNAL under `--headless` because there is no RenderingDevice; **run these
> four gates windowed** or they pass without having tested the GPU at all.
>
> Two decisions in §5 changed during the build and this document has been amended to match: the
> morphology kernel uses a monotonic deque rather than van Herk-Gil-Werman (NaN must be skipped, not
> folded in as an identity), and the GPU declines DistanceTransform in NORMALISED mode with no explicit
> Max Distance, because that divisor is a whole-field reduction.

## 1. Why this batch

The graph currently has strong generators (Noise/Jordan/Swiss, five Mountain primitives, Caldera, Crater,
Dunes, Furrows, Strata, ShatteredPeak, DLA, Scree) and strong solvers (Erosion ×3, Hydraulic ×3,
LakeFlooding, StreamExtraction). What it does not have is the layer that makes those composable:

* **No domain control.** Every generator is nailed to the world origin at world orientation. `Warp` is the
  only coordinate manipulator and it can only warp *its own* noise, never an upstream subgraph.
* **No distance.** Nothing answers "how far is this cell from the water / from the ridge / from the edge".
  That single missing field is why shorelines, falloffs and mask feathering are currently hand-built out of
  Mask + Blend chains.
* **No mask hygiene.** Masks come out of `Mask` and `Curvature` speckled, and there is no dilate/erode/
  open/close to clean or grow them.
* **Thin analytic metrics.** `Mask` covers slope / altitude / curvature. Height-above-local-basin, the
  single most useful gating field for snow, vegetation and rock, is absent.

Thirteen nodes, five phases. Each phase is independently shippable and leaves the graph in a working state.

---

## 2. Licensing posture (unchanged, and it constrains this document)

Hesiod is GPLv3 and HighMap is GPLv3. **No code is copied.** This spec cites Hesiod/HighMap only for
*parameter surface and naming*, so a user who knows Hesiod finds the same knobs. Every algorithm below is
specified from its published primary source or from standard image-processing mathematics, and is to be
implemented clean-room in Pasture3D's MIT tree:

| Node | Algorithm provenance (implement from this, not from HighMap) |
|---|---|
| DistanceTransform | Jump flooding (Rong & Tan 2006) on both paths; Meijster, Roerdink & Hesselink (2000) exact transform in the gate only — see §3.7 |
| ExpandShrink / Morphology | Standard grayscale morphology (van Herk–Gil–Werman separable min/max) |
| RelativeElevation | Standard local min/max normalisation over a disc kernel |
| SmoothFill | Polynomial smooth-min/smooth-max (Quílez), applied against a box-blurred reference |
| RecastCliff | Sigmoid gain applied to a slope-gated height offset |
| Gavoronoise | Gradient-aware Voronoi (the "gavoronoise" shadertoy lineage), rederived |
| Mudslide | Depth-driven viscous mass-transport relaxation, standard diffusion form |
| everything else | Elementary maths, no provenance question |

If any implementer finds themselves reading a HighMap `.cpp` to get an implementation working, **stop** —
that is the boundary. Reading a `.hpp` for parameter names is fine and is what was done to write this doc.

---

## 3. Cross-cutting architecture

### 3.1 The coordinate-frame finding (read before Phase 1)

`Pasture3DGraphNode.eval_cell(wx, wz, inputs)` receives its inputs **already evaluated at `(wx, wz)`**. A
node therefore cannot ask its upstream for a value at a *different* coordinate. `Warp` sidesteps this by
never warping its input at all — it warps only its own internal `FastNoiseLite` sample and adds the result
to a pass-through input (`pasture3d_graph_node_warp.gd:103-128`).

This means **`Transform` cannot be a cell node.** Two designs exist:

* **(A) Grid resample — specced here.** `needs_grid() = true`. Bilinear-sample the already-evaluated input
  grid at inverse-transformed positions. Works against *any* upstream including solver output. Costs one
  grid materialisation and is band-limited by the input grid, so heavy zoom-in blurs.
* **(B) Coordinate-frame push-down — deferred.** The evaluator carries a per-node 2×3 affine and cell nodes
  are invoked at the transformed coordinate, letting the whole upstream cell fold re-evaluate analytically.
  Exact and fusible, but it is an evaluator change touching the fold, the GPU program emitter and the
  freeze/cache key.

Ship (A) in Phase 1. Revisit (B) only if zoom quality becomes a real complaint; if it does, it is its own
spec, and (A)'s node keeps its op tag and parameters so graphs do not break.

### 3.2 Per-node deliverables

Every node in this spec ships **all six** of the following (item 6 applies only where §3.7 requires a
shader). A node missing one of them is not done.

1. **Production GDScript node** — `project/addons/pasture_3d/graph/pasture3d_graph_node_<op>.gd`, following
   the `talus_projection` template exactly: `op()`, `role()`, `needs_grid()`, `input_count()`,
   `input_names()`, `input_port_types()`, `input_unwired_default()`, `eval_cell` or `eval_grid`,
   `node_warnings()`. Every `@export` setter calls `emit_changed()`.
2. **Native implementation** — `src/pasture_3d_<op>.cpp/.h`, bound as a `Pasture3DUtil` static method,
   guarded on the GDScript side by `ClassDB.class_has_method(...)` with the standard
   `"is not bound. Rebuild GDExtension."` error, and a pass-through fallback.
3. **`[Dev/GD]` oracle twin** — `pasture3d_graph_node_dev_<op>.gd`, `op()` returns `&"dev_<op>"`,
   `display_name()` returns `"[Dev/GD] <Title>"`, pure GDScript, registered in `_dev_entries()`.
   *Exception:* nodes marked **no-oracle** below are pure closed-form arithmetic where the native path and a
   GDScript path would be the same three lines; those ship without a twin, and this is stated per node.
4. **Registry entry** — `pasture3d_graph_node_registry.gd`: `const <X>Script = preload(...)` plus an
   `entries()` dictionary with `op` / `title` / `category` / `role` / `script` / `tags` / `description`.
5. **Bench gate** — `project/bench/<Name>Gate.gd` + `.tscn`, run headless. Per the project's gate
   practices: **every criterion needs a control that fails**, and the gate must distinguish "measured
   nothing" from "measured well". Parity criteria hold the native path to the oracle at the standard
   A/B tolerance (≤ 2 × 10⁻⁶ m).
6. **GPU compute path**, for the nodes §3.7 marks as requiring one — a `src/shaders/graph_*.glsl` compute
   shader plus a `<op>_solve_best` router gated on `graph_gpu_threshold`, called from *both* the
   `Pasture3DUtil` binding and `src/pasture_3d_graph_ops.cpp`. Fusible cell nodes need no shader; they
   inherit the GPU through `graph_eval_grid_best` and must simply stay fusible.

### 3.3 Port-type notes

No new `PortType` values are required. Two conventions to hold:

* Nodes that emit a normalised field (`DistanceTransform` normalised mode, `RelativeElevation`,
  `WaterMask`) declare `PortType.MASK` on output port 0, so the editor colours the slot amber and the
  unwired-input default is the mask default rather than 0.
* `DistanceTransform` in **metres** mode outputs `PortType.HEIGHT`, because its units are metres and a
  downstream Remap should read it as such. The mode switch changes the declared output type; the editor
  already re-colours slots on `emit_changed()`.

Multi-output nodes keep the established rule: **editor slots are contiguous from row 0, so port index ==
channel index.** Do not introduce a node whose channel 1 sits on row 2.

### 3.4 Grid-node margin and NaN discipline

Every grid node added here reads neighbours and therefore has a support radius. Two existing rules apply
and must be honoured, not re-invented:

* **Margins are applied once at the stack boundary** (`modifier_margin`). No node in this spec knows
  margins exist. Do not add a per-node margin parameter.
* **NaN is the brush-loop mask.** A NaN input cell propagates to a NaN output cell. Neighbour reads that
  land on NaN are *excluded from the reduction*, not treated as zero — treating them as zero pulls a
  visible dark seam along every loop rim. `Pasture3DGraphOps` should grow a shared
  `neighbour_reduce_skip_nan` helper rather than each node open-coding it.

### 3.5 Units

Every spatial parameter in this spec is in **world metres**, converted to a cell radius internally from
`p_rect` and `gw`/`gh`. No parameter is in grid cells. This is not stylistic: a grid-fraction radius
silently rescales with resolution and with the modifier margin, which is exactly the defect that had to be
fixed in the Salève node. Each grid node's gate carries a criterion that fails a grid-fraction
implementation.

### 3.6 Hesiod normalised space → Pasture3D world space

**This is the single highest-risk part of every port in this document. Read it before writing any node.**

Hesiod and HighMap operate on a **doubly normalised** space: array values sit in roughly `[0, 1]`, and the
domain is the unit square `bbox = {0, 1, 0, 1}` sampled at `shape` cells. Pasture3D operates in **metres on
both axes**, over an arbitrary world `p_rect` at an arbitrary `gw`/`gh`. Almost every HighMap parameter is
therefore in units that do not exist in this codebase, and several of them *look* dimensionless while not
being so.

#### The trap, stated concretely

Hesiod's thermal node computes its slope threshold like this:

```cpp
// Hesiod-main/Hesiod/src/model/nodes/nodes_function/thermal.cpp:102
const float talus = talus_global / float(p_out->shape.x);
```

The user-facing `talus_global` is divided by the grid width. That is correct *there*: HighMap's solver
consumes "elevation delta per cell step", and in a unit domain one cell step is `1/shape.x`, so dividing by
`shape.x` converts a rise-over-run slope into a per-cell delta. It works only because Hesiod's vertical
unit and horizontal unit are the same normalised `[0,1]`.

Port that line literally and the threshold becomes a function of grid resolution and of the modifier
margin — the same class of defect that had to be fixed in the Salève node. **A division by `shape.x`,
`shape.y`, `gw` or `gh` appearing anywhere in a ported routine is a defect until proven otherwise.**

#### The conversion table

| HighMap / Hesiod quantity | Its actual unit | Pasture3D parameter | Conversion |
|---|---|---|---|
| array value `z` | normalised, ~`[0,1]` | metres | multiply by the intended height range; never assume `[0,1]` |
| `bbox` | unit square | `p_rect` | `cell_x = rect.size.x / (gw - 1)`, `cell_y = rect.size.y / (gh - 1)` |
| `kw` (wavenumber) | cycles per unit domain | `frequency` | `frequency = kw / domain_size_m` (cycles per metre, what `FastNoiseLite` wants) |
| `ir` (filter radius) | **grid cells** (HighMap docs say "in pixels") | `radius` in metres | `ir = round(radius_m / cell_x)`, clamped ≥ 1 |
| `talus_global` | normalised rise per unit run | `talus_angle_deg` | user gives degrees; internal threshold per neighbour step = `tan(deg) * step_distance_m` |
| `talus` (solver-internal) | normalised Δz per cell | Δz in metres per cell | `tan(deg) * step_distance_m`, where the step distance differs for orthogonal vs diagonal neighbours |
| `k` (smooth-min sharpness) | normalised height | metres | scales with the height range, not with the grid |
| `amplitude`, `depth`, `z_cut_*` | normalised height | metres | direct, once a height range is chosen |
| `gain`, `gamma`, exponents | dimensionless | dimensionless | unchanged — these are the only genuinely safe direct ports |

#### The two rules

1. **Slopes are angles at the interface, and metric deltas internally.** Every node here that thresholds on
   steepness exposes `*_angle_deg` to the user, never a raw slope scalar. Internally it uses
   `tan(angle)` against the **metric** distance to each neighbour — `cell_x` for a horizontal step,
   `cell_y` for a vertical one, `sqrt(cell_x² + cell_y²)` for a diagonal. Diagonals are not the same
   distance as orthogonals and must not share a threshold.

2. **Heights are metres, so nothing may assume a `[0,1]` range.** Any HighMap routine containing `pow()`,
   `log()`, `sqrt()` or a hardcoded constant against a raw array value is assuming normalisation. Each one
   needs either an explicit height window (as `Contrast` §4.3 does) or a scale-invariant reformulation.
   Negative heights are legal in Pasture3D and are what turn a naive `pow()` into NaN.

#### The reference implementation already in the tree

`godot::talus_projection_solve` in `src/pasture_3d_erosion_thermal.cpp:149-180` already does this correctly
and is the model to copy:

```cpp
const double dx = (double)p_rect.size.x / std::max((double)(p_gw - 1), 1.0);
const double dz = (double)p_rect.size.y / std::max((double)(p_gh - 1), 1.0);
const double diag_d  = std::sqrt(dx * dx + dz * dz);
const double tan_talus = std::tan(deg_to_rad(p_talus_angle_deg));
// ...per-neighbour offsets each carry their own metric distance
```

Degrees at the interface, `tan()` internally, metric distances from `p_rect`, per-offset step distances,
no division by `gw`. New nodes match this or they are wrong.

#### Which nodes in this spec are exposed

| Node | Exposed quantity | Risk |
|---|---|---|
| RecastCliff §6.3 | `talus_angle_deg`, `radius`, `amplitude` | **high** — slope threshold + height offset + cell radius, all three trap classes at once |
| Mudslide §8.3 | `talus_angle_deg`, `depth`, `viscosity_power` | **high** — slope threshold plus a normalised-depth exponent |
| ExpandShrink §5.2 | `radius` | medium — pure `ir` conversion |
| SmoothFill §6.2 | `radius`, `k` | medium — `k` is a height quantity and scales with the terrain's amplitude |
| RelativeElevation §6.1 | `radius` | medium — pure `ir` conversion |
| WarpDownslope §7.1 | `displacement`, `radius` | medium — both metric |
| Gavoronoise §7.2 | `frequency`, `amplitude`, `z_cut_*` | medium — `kw` → cycles/metre, and the `z_cut` window is normalised-height |
| DistanceTransform §5.1 | output units | medium — covered by §5.1's own NORMALISED caveat |
| Contrast §4.3 | height window | covered explicitly in §4.3 |
| Transform, Falloff, FloodingUniformLevel, WaterMask | metric by construction | low |

#### Gate obligation

Every node in the table above with medium or high risk carries a **resolution-invariance criterion** in its
gate: run the identical world fixture at two grid resolutions (129² and 257² over the same `p_rect`) and
assert the results agree within one cell size. A grid-fraction implementation fails it; a metric one passes.
Where a node's gate below already lists such a criterion (DB, EC, RC, WC, WMB) that is this obligation being
discharged — the remaining nodes need one added. **This is the criterion that catches a bad normalisation
port, and it is the only one that catches it cheaply**, because a wrongly-scaled parameter still produces a
plausible-looking terrain at whatever resolution it was authored at.

---

### 3.7 GPU acceleration

**Requirement: every operation Hesiod runs on the GPU must run on the GPU in Pasture3D.** This section
records which those are, what Pasture3D already gives for free, and the one place where matching Hesiod's
GPU algorithm conflicts with this project's parity rule.

#### What each side already has

Hesiod accelerates through OpenCL, in `hmap::gpu`. Pasture3D accelerates through `RenderingDevice` compute
in `src/pasture_3d_graph_gpu.cpp` (1104 lines, a persistent local `RenderingDevice`, shaders in
`src/shaders/graph_*.glsl`). Pasture3D's existing routers are `graph_eval_grid_best`,
`erosion_hydraulic_solve_best`, and one per mountain primitive, each gated on
`pasture_3d/performance/graph_gpu_threshold` (default 65536 cells = 256²), falling back to the CPU kernel
below the threshold or on any GPU failure.

**Correction to an earlier draft of this section: there is no "free" GPU path.** `Pasture3DGraphGPU::eval_grid`
implements exactly six ops — `INPUT`, `NOISE`, `CONST`, `BLEND`, `SMOOTH`, `OUTPUT` — and its switch ends in
`default: return fail()` (`src/pasture_3d_graph_gpu.cpp:310-370`). `NOISE` and `CONST` are evaluated
host-side into buffers; only `BLEND` and `SMOOTH` are real dispatches, through a four-mode kernel
(`COPY`, `BLEND`, `SMOOTH_H`, `SMOOTH_V`) in `GRAPH_GRID_GLSL`.

Two consequences, and the second one is the one that matters:

1. `needs_grid() = false` buys **nothing** on the GPU by itself. Even `Terrace`, op 4 and fusible, has no
   GPU path today.
2. **`fail()` drops the *whole graph* to the CPU, not just the unsupported node.** So shipping a node
   without a GPU path does not leave it merely unaccelerated — it de-accelerates every graph that contains
   it. Adding `Falloff` without shader support would make a Noise→Falloff→Smooth graph *slower than it is
   today*.

Therefore every node in this spec that can appear in a cell/grid program needs its op handled in
`eval_grid`, either host-side (like `NOISE`) or as a new kernel mode. "Keep it fusible" is still the right
instruction — gate criterion **FD** in §4.2 still enforces it — but fusibility is about the CPU fold and
about *eligibility* for the GPU program, not a free ride on it.

#### Per-node GPU obligation

| Node | Hesiod GPU? | Pasture3D path | Obligation |
|---|---|---|---|
| Transform §4.1 | partial (`gpu::rotate`) | dedicated shader | **new** `graph_transform.glsl` + `transform_solve_best` |
| Falloff §4.2 | no | **new kernel mode** | mode 4 in `GRAPH_GRID_GLSL` + host-side param upload; without it the whole graph falls back |
| Contrast §4.3 | no (only `gamma_correction_local`) | **new kernel mode** | mode 5 in `GRAPH_GRID_GLSL` |
| DistanceTransform §5.1 | **yes** — `gpu::distance_transform_jfa`, `gpu::signed_distance_transform` | dedicated shader | **new** `graph_distance_jfa.glsl` — see the algorithm conflict below |
| ExpandShrink §5.2 | **yes** — `gpu::dilation`, `erosion`, `opening`, `closing`, `morphological_gradient`, `expand`, `shrink` | dedicated shader | **new** `graph_morphology.glsl` + `expand_shrink_solve_best` |
| RelativeElevation §6.1 | **yes** — `gpu::relative_elevation`, `local_min`, `local_max` | dedicated shader | shares `graph_morphology.glsl` (it is the same min/max kernel) |
| SmoothFill §6.2 | **yes** — `gpu::smooth_fill`, `smooth_fill_holes`, `smooth_fill_smear_peaks` | dedicated shader | **new** `graph_smooth_fill.glsl` + `smooth_fill_solve_best` |
| RecastCliff §6.3 | no | dedicated shader | **new**, and worth doing anyway — gradient + blur + sigmoid is ideal GPU work |
| WarpDownslope §7.1 | no (`gpu::warp` exists, not the downslope variant) | dedicated shader | **new**, shares the gradient pass with RecastCliff |
| Gavoronoise §7.2 | **yes** — `gpu::gavoronoise` | host-side buffer | evaluate into a buffer host-side exactly as `GRAPH_OP_NOISE` does, or a generator kernel mode if profiling wants one |
| FloodingUniformLevel §8.1 | no | **new kernel mode** | pointwise, cheapest possible mode |
| WaterMask §8.2 | no | dedicated shader | reuses the distance-transform shader |
| Mudslide §8.3 | **yes** — `gpu::mudslide` | dedicated shader | **new** `graph_solver_mudslide.glsl` + `mudslide_solve_best` |

Six operations are GPU in Hesiod (DistanceTransform, ExpandShrink, RelativeElevation, SmoothFill,
Gavoronoise, Mudslide). All six are GPU here. **Every other node in this spec also needs an `eval_grid`
case**, not for parity with Hesiod but because of consequence 2 above — an unhandled op costs the whole
graph its acceleration.

#### The rule that makes GPU parity tractable

Pasture3D holds every node to CPU↔GPU agreement. That is only achievable if the two paths are
**numerically equivalent, not merely visually similar**, so the algorithm choice on each side is
constrained:

* **Prefer algorithm pairs that agree exactly.** ExpandShrink is the clean case: the CPU path uses the
  sequential van Herk–Gil–Werman running min/max and the GPU path uses a tiled separable min/max. Different
  algorithms, *identical* results, because both compute an exact min over the same window.
* **Accumulate deltas, never update in place.** An iterative solver that writes into the height field as it
  scans is order-dependent, and a GPU dispatch has no defined cell order — so the CPU and GPU results
  diverge and no tolerance will save them. `godot::talus_projection_solve` already demonstrates the correct
  shape: fill a `delta` buffer for every cell, then apply it in a second pass. **Mudslide (§8.3) must be
  written this way from the start.** This is not an optimisation detail; it is the difference between a
  solver that can be GPU-accelerated and one that cannot.
* **Threshold and fall back like the existing routers.** Every `_best` router added here gates on
  `graph_gpu_threshold` and falls back to the CPU kernel when the grid is small or the GPU path fails.
  Per the acceleration guide §3.2.4, `src/pasture_3d_graph_ops.cpp` must call the **same** `_best` router
  as the `Pasture3DUtil` binding — a node routed through the GPU from the Inspector but through the CPU
  during a whole-graph bake is the exact defect that guide rule exists to prevent.

#### The one real conflict: DistanceTransform

This needs a decision, because "match Hesiod's GPU" and "hold CPU↔GPU parity" pull in opposite directions
here.

§5.1 specs the exact Meijster transform. Meijster is a **sequential lower-envelope scan** — a poor GPU fit.
Hesiod's GPU path is therefore a *different algorithm*: `distance_transform_jfa`, jump flooding, which is
**approximate**. Ship both as specced and the CPU and GPU paths disagree by more than the 2 × 10⁻⁶ m
tolerance, on a field that feeds WaterMask and every shore effect downstream.

**Resolution — use JFA on both paths.** The CPU kernel, the GPU shader and the `[Dev/GD]` oracle all
implement jump flooding, so all three agree by construction and the standard parity tolerance holds
unchanged. Exact Meijster is then implemented **once, in the gate only**, as the ground truth that bounds
JFA's error:

* Amend §5.1's algorithm provenance from "Meijster exact" to "jump flooding (Rong & Tan 2006), with
  Meijster retained as the gate's reference".
* Add gate criterion **DF**: JFA output is within one cell size of the exact Meijster result across the
  whole field. *Control:* a JFA run truncated to too few passes must fail it. JFA+1 (one extra pass at
  step 1) is the cheap accuracy improvement if DF is marginal.
* Criterion **DA** (the single-seed exactness test) still holds — JFA is exact for a single seed; it is
  multi-seed configurations where it can err.

The alternative — exact on CPU, JFA on GPU, with a widened tolerance for this one node — is rejected. It
makes a node's output depend on which path ran, and the GPU path is threshold-gated, so the same graph
would produce different terrain at 256² than at 128². That is precisely the class of resolution-dependent
behaviour §3.6 exists to eliminate.

#### Gate obligation

Every node above with a dedicated shader carries a **GPU parity criterion** in its gate, matching the
existing `GraphGpuParityGate.gd` pattern: run the same fixture through the CPU kernel and through the GPU
shader and assert agreement within 2 × 10⁻⁶ m. Force the GPU path by setting `graph_gpu_threshold` to 1
rather than by growing the fixture, so the criterion is cheap enough to run every time. A gate that only
ever exercises the CPU path because its fixture sits below the default 65536-cell threshold is measuring
nothing — and per the project's gate practices, it must report NO-SIGNAL rather than PASS in that case.

---

## 4. Phase 1 — Domain & Range Foundations

*Three nodes. No new algorithms; this phase is about making the existing library placeable and shapeable.
Do it first because Phases 3–5 all want a Falloff in their test graphs.*

### 4.1 `Transform` — `op = &"transform"`

* **Class:** `Pasture3DGraphNodeTransform` · **Role:** FILTER · **needs_grid:** `true` (see §3.1)
* **Replaces:** Hesiod `Translate` + `Rotate` + `Zoom`, deliberately fused into one node. Three nodes for
  one affine is three grid resamples and three chances to blur.
* **Ports:** `in` (HEIGHT), `offset` (VECTOR), `rotation` (FLOAT, degrees), `scale` (FLOAT), `amount` (MASK)
* **Parameters:** `offset: Vector2 = (0,0)` metres · `rotation_deg: float = 0.0` ·
  `scale: float = 1.0` (>0, uniform) · `pivot: Vector2 = (0,0)` world metres ·
  `edge_mode: {CLAMP, ZERO, WRAP} = CLAMP` · `amount: float = 1.0`
* **Maths:** build the forward affine `M = T(pivot) · R(rotation) · S(scale) · T(-pivot) · T(offset)`.
  For each output cell at world `(wx, wz)`, sample the input grid at `M⁻¹ · (wx, wz)` with bilinear
  interpolation. Out-of-grid reads follow `edge_mode`. Result is `lerp(input, resampled, amount)`.
* **Native:** `Pasture3DUtil.transform_grid(in, gw, gh, rect, offset, rot_deg, scale, pivot, edge_mode, amount)`
* **Oracle:** yes — bilinear plus inverse-affine is exactly where an off-by-half-a-texel creeps in.
* **Gate — `GraphTransformGate.gd`:**
  * **TA** identity: `offset=0, rot=0, scale=1` reproduces the input bit-for-bit. *Control:* `offset=(5,0)`
    must fail it.
  * **TB** round-trip: transform by `M` then by `M⁻¹` returns to the input within resample tolerance,
    measured on the grid interior only (edges are `edge_mode` territory). *Control:* a single transform
    must fail.
  * **TC** rotation is about `pivot`, not about the grid origin — a feature at the pivot does not move.
    *Control:* pivot at a corner must move it.
  * **TD** NaN in ⇒ NaN out, and no finite cell is contaminated by a NaN neighbour through the bilinear tap.
  * **TE** "measured nothing" guard: the fixture's height range must exceed 1 m, else the gate reports
    NO-SIGNAL rather than PASS.

### 4.2 `Falloff` — `op = &"falloff"`

* **Class:** `Pasture3DGraphNodeFalloff` · **Role:** FILTER · **needs_grid:** `false` (cell node, fusible)
* **Hesiod:** `Falloff` / `ZeroedEdges`
* **Ports:** `in` (HEIGHT), `strength` (FLOAT), `radius` (FLOAT), `noise` (HEIGHT — perturbs the distance)
* **Parameters:** `shape: {RADIAL, SQUARE, AXIS_X, AXIS_Z} = RADIAL` ·
  `centre: Vector2 = (0,0)` world metres · `radius: float = 500.0` m · `feather: float = 200.0` m ·
  `strength: float = 1.0` · `invert: bool = false` · `distance_noise: float = 0.0` m
* **Maths:** per cell, `d = shape_distance(wx - cx, wz - cz) + distance_noise * noise_in`. Attenuation
  `a = 1 - smoothstep(radius, radius + feather, d)`, inverted if `invert`, mixed by `strength`:
  `out = in * lerp(1, a, strength)`. `RADIAL` uses Euclidean distance, `SQUARE` uses Chebyshev, the axis
  modes use single-axis absolute distance. (This is Hesiod's `distance_function` enum, renamed to something
  a level designer can read.)
* **Native:** folds into the existing cell-node program emitter — a new opcode in
  `pasture_3d_graph_ops.cpp`, not a standalone `.cpp`.
* **Oracle:** **no-oracle** — closed-form arithmetic, covered by the fold parity gate.
* **Gate — folded into `GraphDomainRangeGate.gd`:**
  * **FA** `strength=0` is a pass-through. *Control:* `strength=1` must differ.
  * **FB** at `d > radius + feather` the output is 0 (within 1e-6 m); at `d = 0` it equals the input.
  * **FC** `invert` produces exactly `1 - a` attenuation. *Control:* comparing against `a` must fail.
  * **FD** the node participates in the cell fold — assert it is fused, not grid-materialised, by checking
    the compiled program's node count. This is the criterion that stops it silently regressing into a grid
    node.

### 4.3 `Contrast` — `op = &"contrast"`

* **Class:** `Pasture3DGraphNodeContrast` · **Role:** FILTER · **needs_grid:** `false`
* **Hesiod:** `Gain` + `GammaCorrection`, fused. Both are one-line pointwise curves on a normalised value;
  two palette entries for that is clutter.
* **Ports:** `in` (HEIGHT), `amount` (FLOAT), `mask` (MASK)
* **Parameters:** `mode: {GAIN, GAMMA} = GAIN` · `amount: float = 1.0` (gain factor / gamma exponent,
  1.0 = identity in both modes) · `range_min / range_max: float` — the height window mapped to [0,1]
  before the curve and back after · `mask_amount: float = 1.0`
* **Maths:** `t = clamp((in - range_min) / (range_max - range_min), 0, 1)`.
  * GAIN (Schlick bias/gain): `t < 0.5 ? 0.5*pow(2t, k) : 1 - 0.5*pow(2-2t, k)` with `k = amount`.
  * GAMMA: `pow(t, amount)`.

  Then `out = lerp(in, range_min + t' * (range_max - range_min), mask * mask_amount)`.
* **Why the explicit window:** Hesiod operates on `[0,1]` heightmaps. Pasture3D heights are **metres**, so
  a bare `pow()` on a metre value is meaningless and negative heights produce NaN. The window is not
  optional polish — it is what makes this node correct in this codebase. Emit a `node_warnings()` entry
  when `range_max <= range_min`.
* **Native:** cell-fold opcode. **no-oracle.**
* **Gate:** **CA** `amount=1` is identity in both modes (control: `amount=2` differs); **CB** values outside
  `[range_min, range_max]` pass through unchanged; **CC** no NaN is produced for negative input heights —
  *this is the criterion that catches the naive `pow()` port.*

---

## 5. Phase 2 — Distance & Morphology

*Two nodes, both grid. This is the phase that unlocks the most downstream, and DistanceTransform is a
dependency of the Phase 5 water masks, so it lands before them.*

### 5.1 `DistanceTransform` — `op = &"distance_transform"`

* **Class:** `Pasture3DGraphNodeDistanceTransform` · **Role:** FILTER · **needs_grid:** `true`
* **Hesiod:** `DistanceTransform`
* **Ports:** `in` (MASK), `threshold` (FLOAT)
* **Parameters:** `threshold: float = 0.5` — cells above this are "inside" ·
  `direction: {OUTSIDE, INSIDE, SIGNED} = OUTSIDE` ·
  `metric: {EUCLIDEAN, MANHATTAN, CHEBYSHEV} = EUCLIDEAN` ·
  `output_units: {METRES, NORMALISED} = METRES` · `max_distance: float = 0.0` (0 = unbounded; otherwise
  clamps, and is the divisor in NORMALISED mode)
* **Maths:** jump flooding (§3.7). Seed each "inside" cell with its own coordinate, then run
  `log2(max(gw, gh))` passes at halving step sizes, each cell adopting the nearest seed among its eight
  step-offset neighbours; the distance is the metric distance to the adopted seed. Chosen over the exact
  Meijster transform because it is the algorithm that parallelises, so the CPU kernel, the GPU shader and
  the oracle can all run it and agree by construction. `SIGNED` computes both directions and returns
  `d_out - d_in`. **Distances are in metres**, so each pass is scaled by the
  cell size derived from `p_rect` and `gw`/`gh` — *not* in grid cells (§3.5).
* **NORMALISED caveat, and it must be honoured:** if `max_distance = 0` in NORMALISED mode the divisor is
  the field's own maximum, which makes the output **resolution- and content-dependent**. Per the project's
  calibration rule, the node must expose the divisor it used — store it as a read-only
  `last_normalisation_divisor` and surface it in `node_warnings()`. A normalised field whose divisor is only
  printed is not an interface.
* **Native:** `Pasture3DUtil.distance_transform_grid(mask, gw, gh, rect, threshold, direction, metric, units, max_distance)`
* **Oracle:** yes — the parabola-envelope pass is the most error-prone routine in this spec.
* **Gate — `GraphDistanceTransformGate.gd`:**
  * **DA** a single interior seed cell yields a field whose value at offset `(i,j)` equals
    `cell_size * sqrt(i² + j²)` within 1e-6 m. *Control:* a Manhattan implementation must fail this.
  * **DB** metric independence: the same fixture at 129² and 257² over the same world rect yields the same
    *metre* distances within one cell size. *Control:* a grid-cell implementation must fail. This criterion
    exists specifically to catch the Salève bug class.
  * **DC** SIGNED changes sign exactly at the threshold contour.
  * **DD** native ↔ oracle parity ≤ 2e-6 m on a random mask.
  * **DE** NO-SIGNAL guard: if the input mask is uniformly above or below threshold, report NO-SIGNAL — an
    all-zero distance field is not a passing measurement.
  * **DF** JFA accuracy: the output is within one cell size of an exact Meijster transform computed in the
    gate as ground truth. *Control:* a JFA run truncated to too few passes must fail. Use JFA+1 (an extra
    pass at step 1) if this criterion comes out marginal.
  * **DG** GPU parity: CPU kernel vs compute shader. **Amended during the build in two ways.** The
    tolerance is 1e-3 (`GraphGpuParityGate.TOL`), not 2e-6: the shader accumulates in float32, so a field
    of hundreds of metres already carries ~1e-5 m of rounding, and holding it to the double-vs-double
    budget would fail on arithmetic. And the route is proven by calling `graph_eval_grid_gpu` DIRECTLY —
    it returns an empty array when it bails — rather than by forcing `graph_gpu_threshold`, which cannot
    distinguish a GPU run from a second CPU run. The GPU deliberately DECLINES NORMALISED mode with
    Max Distance 0, since that divisor is a whole-field reduction; DG asserts that bail.

### 5.2 `ExpandShrink` — `op = &"expand_shrink"`

* **Class:** `Pasture3DGraphNodeExpandShrink` · **Role:** FILTER · **needs_grid:** `true`
* **Hesiod:** `ExpandShrink`, `Dilation`, `Erosion`, `Opening`, `Closing`, `MorphologicalGradient` — six
  nodes fused into one with a mode enum, because they are the same separable min/max kernel.
* **Ports:** `in` (HEIGHT or MASK — untyped pass-through), `radius` (FLOAT), `amount` (MASK)
* **Parameters:** `mode: {EXPAND, SHRINK, OPEN, CLOSE, GRADIENT} = EXPAND` ·
  `radius: float = 5.0` **metres** · `kernel: {DISC, SQUARE} = DISC` · `iterations: int = 1` ·
  `amount: float = 1.0`
* **Maths:** grayscale dilation (local max) and erosion (local min) over the kernel. `OPEN` = erode then
  dilate, `CLOSE` = dilate then erode, `GRADIENT` = dilate − erode. Use the van Herk–Gil–Werman running
  min/max for the `SQUARE` kernel (O(1) per cell regardless of radius); `DISC` uses the standard
  decomposition into a small set of separable passes. NaN neighbours are skipped, never treated as ±∞.
  **Amended during the build:** vHGW was replaced by a monotonic deque. vHGW's prefix/suffix block scan
  assumes every sample participates, which is incompatible with skipping NaN — a NaN folded in as −∞
  under a max is invisible, and as +∞ under a min it swallows the window. The deque only ever holds
  indices of finite samples and is still O(1) amortised. The disc is defined ONCE, as the offsets inside
  the unit ellipse in cell space, and all three implementations (CPU row decomposition, GPU 2D gather,
  oracle offset walk) must reproduce exactly that set — a floor-vs-round slip in the per-row half-width
  is invisible everywhere except criterion ED.
* **Naming note:** the mode is called **SHRINK**, not "Erosion". The graph already has five nodes with
  "Erosion" in the name and they are all geological simulations. A morphological erosion sharing that word
  in the palette would be a genuine usability trap.
* **Native:** `Pasture3DUtil.expand_shrink_grid(in, mask, gw, gh, rect, mode, radius_m, kernel, iterations, amount)`
* **Oracle:** yes — a naive O(r²) GDScript reference is fine, and is exactly what the running-min/max
  implementation needs checking against.
* **Gate — `GraphMorphologyGate.gd`:** **EA** dilate then erode at the same radius is idempotent on a binary
  mask with no features smaller than the radius (control: a mask with a 1-cell speckle must fail); **EB**
  `OPEN` removes speckle smaller than the radius and leaves larger features untouched; **EC** radius is
  metric — the same world radius at two grid resolutions grows the mask by the same world distance; **ED**
  native ↔ oracle parity; **EE** `radius = 0` is a pass-through.

---

## 6. Phase 3 — Terrain Metrics & Structural Shaping

*Three nodes. The payoff phase for how terrain reads. Depends on Phase 2's separable min/max kernel — build
it once in `pasture_3d_graph_ops` and share it.*

### 6.1 `RelativeElevation` — `op = &"relative_elevation"`

* **Class:** `Pasture3DGraphNodeRelativeElevation` · **Role:** FILTER · **needs_grid:** `true`
* **Hesiod:** `RelativeElevation`
* **Ports:** `in` (HEIGHT), `radius` (FLOAT)
* **Parameters:** `radius: float = 200.0` metres · `output_units: {NORMALISED, METRES} = NORMALISED`
* **Maths:** over a disc of `radius`, compute local min `z_lo` and local max `z_hi` (reuse §5.2's kernel).
  NORMALISED: `(z - z_lo) / max(z_hi - z_lo, ε)` → MASK output, 0 on the local basin floor and 1 on the
  local crest. METRES: `z - z_lo` → HEIGHT output, i.e. height above the local basin floor.
* **Why it earns its place:** this is the correct gating field for snow, treeline, exposed rock and cliff
  vegetation. `Mask(ALTITUDE)` gates on *absolute* height, which is wrong the moment a graph has more than
  one massif — every mountain gets its snowline at the same world Y. RelativeElevation gates each landform
  against its own base.
* **Native:** `Pasture3DUtil.relative_elevation_grid(in, gw, gh, rect, radius_m, units)`
* **Oracle:** yes.
* **Gate — `GraphTerrainMetricsGate.gd`:** **RA** on a single cone the output is ~1 at the apex and ~0 at the
  base (control: a flat plane produces a uniform field and must be reported NO-SIGNAL, not PASS); **RB** two
  cones of different absolute heights both reach ~1 at their apexes — *this is the criterion that
  distinguishes it from `Mask(ALTITUDE)`, and `Mask` must fail it*; **RC** radius is metric across
  resolutions; **RD** parity.

### 6.2 `SmoothFill` — `op = &"smooth_fill"`

* **Class:** `Pasture3DGraphNodeSmoothFill` · **Role:** FILTER · **needs_grid:** `true`
* **Hesiod:** `SmoothFill`, `SmoothFillHoles`, `SmoothFillSmearPeaks` — fused via a mode enum.
* **Ports:** `in` (HEIGHT), `radius` (FLOAT), `k` (FLOAT), `mask` (MASK)
* **Parameters:** `mode: {FILL_VALLEYS, FILL_HOLES, SMEAR_PEAKS} = FILL_VALLEYS` ·
  `radius: float = 50.0` metres · `k: float = 0.1` (smoothing sharpness, > 0) · `amount: float = 1.0`
* **Outputs:** port 0 `height` (HEIGHT), port 1 `deposition` (MASK) — where and how much material was added.
* **Maths:** let `zb` be the input box-blurred at `radius`. FILL_VALLEYS uses the polynomial smooth-max
  `h = smax(z, zb, k)`, which raises concave ground toward the blurred reference while leaving convex
  ridges alone. SMEAR_PEAKS uses `smin(z, zb, k)`, the mirror. FILL_HOLES restricts FILL_VALLEYS to cells
  whose local curvature is concave in **both** principal directions, so it fills pits without filling
  valleys. `deposition = h - z`, normalised by its own max — and per the calibration rule that divisor is
  exposed on the node, not merely printed. Final `out = lerp(z, h, amount * mask)`.
* **Why it earns its place:** highest visual payoff in the batch. Raw fBm reads as noise because its valleys
  are as sharp as its ridges; real terrain has sediment in the low ground. SmoothFill is the cheap
  non-simulated way to get that asymmetry, and it composes with the erosion solvers rather than competing
  with them.
* **Native:** `Pasture3DUtil.smooth_fill_grid(in, mask, gw, gh, rect, mode, radius_m, k, amount)` returning
  the height grid, with the deposition channel returned via the established multi-output path.
* **Oracle:** yes.
* **Gate — `GraphSmoothFillGate.gd`:** **SA** ridge crests move by < 1% of their prominence while valley
  floors rise measurably — *the asymmetry is the whole point, and a symmetric blur must fail this*; **SB**
  total volume strictly increases in FILL_VALLEYS and strictly decreases in SMEAR_PEAKS; **SC** `k → 0`
  converges to a hard `max(z, zb)`; **SD** the deposition channel is non-zero exactly where the height
  changed; **SE** parity; **SF** resolution invariance (§3.6) for both `radius` and `k`.

### 6.3 `RecastCliff` — `op = &"recast_cliff"`

* **Class:** `Pasture3DGraphNodeRecastCliff` · **Role:** FILTER · **needs_grid:** `true`
* **Hesiod:** `RecastCliff`, `RecastCliffDirectional`
* **Ports:** `in` (HEIGHT), `talus` (FLOAT), `amplitude` (FLOAT), `mask` (MASK)
* **Parameters:** `talus_angle_deg: float = 40.0` — slope above which a cliff forms ·
  `radius: float = 20.0` metres (the reference-blur radius that sets cliff face width) ·
  `amplitude: float = 10.0` metres (how far the face is pushed out) · `gain: float = 2.0` (sigmoid
  sharpness) · `direction_deg: float = -1.0` (< 0 = omnidirectional; ≥ 0 = only faces whose gradient points
  within `direction_spread_deg` of this bearing) · `direction_spread_deg: float = 60.0` ·
  `amount: float = 1.0`
* **Maths:** compute the gradient magnitude in metres/metre and gate it with a `smoothstep` around
  `tan(talus_angle)`. In directional mode multiply the gate by the angular window. Take the local height
  deviation `dz = z - blur(z, radius)`, push it through the sigmoid
  `s = 1/(1 + exp(-gain * dz / amplitude))`, and add `amplitude * (s - 0.5) * gate * mask * amount`. Net
  effect: ground that is already steep is pushed to a stepped, near-vertical face; ground below the talus
  angle is untouched.
* **Composition note:** this is the vertical-axis complement to `Terrace`/`Strata`, which quantise on the
  height axis. RecastCliff quantises on the *slope* axis. Wired after `Strata` it gives banded cliffs; wired
  after `SmoothFill` it gives cliff-above-scree.
* **Native:** `Pasture3DUtil.recast_cliff_grid(in, mask, gw, gh, rect, talus_deg, radius_m, amplitude, gain, direction_deg, spread_deg, amount)`
* **Oracle:** yes.
* **Gate — `GraphRecastGate.gd`:** **KA** flat ground (slope 0) is untouched to 1e-6 m (control: setting
  `talus_angle_deg = 0` must change it); **KB** a synthetic ramp steeper than the talus angle gains slope and
  one below it does not; **KC** directional mode changes only faces within the angular window — a face
  pointing the opposite way is bit-identical; **KD** `amplitude = 0` is a pass-through; **KE** parity; **KF** resolution invariance (§3.6) — the same world fixture at 129² and 257² produces the same cliff faces within one cell size. *Control:* a `talus / gw` implementation must fail.

---

## 7. Phase 4 — Motion & Synthesis

*Two nodes. Both are "look" nodes with no downstream dependencies, so this phase can slip without blocking
Phase 5.*

### 7.1 `WarpDownslope` — `op = &"warp_downslope"`

* **Class:** `Pasture3DGraphNodeWarpDownslope` · **Role:** FILTER · **needs_grid:** `true`
* **Hesiod:** `WarpDownslope`
* **Ports:** `in` (HEIGHT), `amount` (FLOAT), `mask` (MASK)
* **Parameters:** `displacement: float = 20.0` metres · `radius: float = 20.0` metres (smoothing radius of
  the gradient used for direction) · `reverse: bool = false` (warp upslope instead) · `amount: float = 1.0`
* **Maths:** compute the gradient of the input smoothed at `radius`; the warp direction is the normalised
  downslope vector `-∇z/|∇z|`, negated when `reverse`. Resample the input bilinearly at
  `(wx, wz) + displacement * dir * amount * mask`. Cells with `|∇z|` below a small epsilon do not move.
  Reuse Transform's bilinear resampler (§4.1).
* **Why it earns its place:** noise-based `Warp` distorts terrain in directions unrelated to the terrain.
  Warping *along the gradient* is what fluvial transport actually does to a surface, so it buys a
  water-worked read for a fraction of an erosion solve — the useful middle rung between "no erosion" and
  "freeze a solver". It also reuses the gradient code already written for `Mask` and `Curvature`.
* **Native:** `Pasture3DUtil.warp_downslope_grid(in, mask, gw, gh, rect, displacement_m, radius_m, reverse, amount)`
* **Oracle:** yes.
* **Gate — `GraphWarpDownslopeGate.gd`:** **WA** a flat plane is unchanged (control: a tilted plane must
  shift); **WB** on a single cone mass moves downhill — measure the radius containing 50% of the volume and
  assert it grows, and that `reverse = true` shrinks it; **WC** displacement is metric across resolutions;
  **WD** parity; **WE** NO-SIGNAL when the fixture's gradient is everywhere below epsilon.

### 7.2 `Gavoronoise` — `op = &"gavoronoise"`

* **Class:** `Pasture3DGraphNodeGavoronoise` · **Role:** GENERATOR · **needs_grid:** `false` (cell, fusible)
* **Hesiod:** `Gavoronoise`
* **Ports:** `amplitude` (FLOAT), `angle` (FLOAT — a per-cell angle field may be wired in), `frequency` (FLOAT)
* **Parameters:** `frequency: float = 0.002` · `amplitude: float = 60.0` metres · `seed: int` ·
  `angle_deg: float = 0.0` and `angle_spread: float = 1.0` (tectonic strike direction, and how far cells
  deviate from it) · `octaves: int = 4` · `slope_strength: float = 1.0` · `branch_strength: float = 2.0` ·
  `z_cut_min: float = 0.2` / `z_cut_max: float = 1.0`
* **Maths:** a gradient-aware Voronoi. Per octave, evaluate a Voronoi/worley cell field, but instead of
  taking the raw distance, accumulate the *directional derivative* of the cell field along a strike
  direction and attenuate each subsequent octave by the accumulated slope — the same derivative-feedback
  idea already implemented in `noise_jordan`, applied to a cellular rather than a gradient-noise base.
  `branch_strength` scales the derivative feedback (higher = more dendritic branching); `z_cut_min/max`
  window the output before amplitude scaling.
* **Why it earns its place:** a genuine gap. `FastNoiseLite`'s cellular mode gives the distance field but
  not the gradient feedback, and that feedback is what produces branching ridgelines that read as eroded
  with no erosion pass. Best quality-per-millisecond generator in Hesiod's catalogue, and it is fusible.
* **Implementation reuse:** share the derivative-accumulation scaffold with `pasture_3d_noise_jordan.cpp`
  rather than duplicating it. If the two need to diverge, that is a refactor, not two copies.
* **Native:** `src/pasture_3d_gavoronoise.cpp` plus a cell-fold opcode.
* **Oracle:** yes — a fusible generator needs the fold-parity oracle, like Jordan and Swiss have.
* **Gate — `GraphGavoronoiseGate.gd`:** **GA** determinism — the field is a pure function of the seed
  (control: a different seed must differ); **GB** the field is dendritic, not a smooth blob and not white
  noise. Reuse the DLA gate's two-scalar approach: *no single scalar separates a branching field from both
  nulls*, so measure two, each against the null it exists to exclude (a ridge-connectivity measure against
  the noise null, and a spectral-slope measure against the blob null); **GC** `angle_deg` visibly rotates the
  dominant ridge orientation and `angle_spread = 0` makes ridges parallel; **GD** amplitude scales the field
  linearly; **GE** fold parity against the oracle; **GF** resolution invariance (§3.6) — `frequency` is
  cycles per metre, so the same world rect at two grid resolutions yields the same ridge spacing in metres.

---

## 8. Phase 5 — Water & Mass Wasting

*Three nodes. Last, because `WaterMask`'s shore band wants Phase 2's `DistanceTransform`, and because the
existing water system is the most integration-sensitive part of the plugin.*

### 8.1 `FloodingUniformLevel` — `op = &"flooding_uniform_level"`

* **Class:** `Pasture3DGraphNodeFloodingUniformLevel` · **Role:** FILTER · **needs_grid:** `false`
* **Hesiod:** `FloodingUniformLevel`
* **Ports:** `in` (HEIGHT), `level` (FLOAT)
* **Outputs:** port 0 `height` (HEIGHT — the input clamped up to the water level), port 1 `depth` (HEIGHT —
  `max(level - z, 0)`), port 2 `mask` (MASK — 1 where flooded)
* **Parameters:** `level: float = 0.0` metres (world Y) · `clamp_terrain: bool = true` — when false the
  height output passes through untouched and only the depth/mask channels are produced
* **Maths:** trivially pointwise. That is the point: `LakeFlooding` is a solver that has to find basins and
  spillways, and it is overkill when the author just wants a sea level. This node is the cheap path, and
  unlike `LakeFlooding` it is a **cell node**, so it fuses.
* **Integration — read this before implementing:** this node does **not** spawn `Pasture3DPond` bodies.
  `LakeFlooding` owns that relationship, and two nodes racing to spawn water bodies is a bug factory. State
  it in the node's header comment and in its registry `description`.
* **Native:** cell-fold opcode. **no-oracle.**
* **Gate:** **FLA** depth is exactly `max(level - z, 0)`; **FLB** with `clamp_terrain = false` the height
  output is bit-identical to the input (control: `true` must differ); **FLC** the mask is 1 exactly where
  depth > 0; **FLD** no pond bodies are spawned — assert the scene's pond count is unchanged. This is the
  integration mistake most likely to be made, so it gets a criterion.

### 8.2 `WaterMask` — `op = &"water_mask"`

* **Class:** `Pasture3DGraphNodeWaterMask` · **Role:** FILTER · **needs_grid:** `true`
* **Hesiod:** `WaterMask`, `WaterDepthFromMask`
* **Ports:** `depth` (HEIGHT), `height` (HEIGHT), `shore_width` (FLOAT)
* **Outputs:** port 0 `water` (MASK — submerged), port 1 `shore` (MASK — the band within `shore_width` of
  the waterline, on either side)
* **Parameters:** `depth_threshold: float = 0.01` m · `shore_width: float = 15.0` metres ·
  `shore_falloff: {LINEAR, SMOOTH} = SMOOTH`
* **Maths:** `water = depth > depth_threshold`. The shore band is built by running §5.1's
  `DistanceTransform` in SIGNED mode against the water mask and windowing `|d| < shore_width`. **Call the
  native distance routine; do not write a second distance implementation.**
* **Why it earns its place:** it is the consumer that makes `DistanceTransform` pay for itself, and it
  produces the field the material system wants for wet sand, beach shingle and shoreline vegetation.
* **Native:** `Pasture3DUtil.water_mask_grid(...)`, internally calling the distance transform.
* **Oracle:** yes.
* **Gate:** **WMA** the water mask matches a direct threshold of the depth channel; **WMB** the shore band has
  the specified metric width on both sides of the waterline (control: a band measured in grid cells must
  fail at a second resolution); **WMC** with `shore_width = 0` the shore channel is empty; **WMD** parity.

### 8.3 `Mudslide` — `op = &"mudslide"`

* **Class:** `Pasture3DGraphNodeMudslide` · **Role:** SOLVER · **needs_grid:** `true` · **FROZEN by default**
* **Hesiod:** `Mudslide`
* **Ports:** `in` (HEIGHT), `landslide_mask` (MASK), `depth` (FLOAT), `iterations` (INT)
* **Outputs:** port 0 `height` (HEIGHT), port 1 `deposition` (MASK)
* **Parameters:** `talus_angle_deg: float = 30.0` (the trigger angle when no mask is wired) ·
  `depth: float = 5.0` metres of mobile material · `iterations: int = 20` · `depth_exponent: float = 0.5` ·
  `viscosity_power: float = 1.5` · `amount: float = 1.0`
* **Maths:** initialise a mobile-depth field — either `depth * mask`, or `depth` gated to cells exceeding the
  talus angle. Iterate: at each cell, move mobile material to lower neighbours proportionally to the slope
  raised to `viscosity_power`, with the transportable fraction scaled by
  `(local_depth / depth)^depth_exponent`, conserving volume. Deposit remaining material where the slope
  falls below the angle of repose. Output the deposition delta on channel 1.
* **Relationship to what exists:** `TalusProjection` and `ErosionThermal` relax slope *everywhere*; Mudslide
  moves a *finite, maskable quantity* of material as a discrete event. It is the node for a specific scar on
  a specific hillside, not for global weathering. Keep that distinction in the description or it will be
  treated as a duplicate.
* **Freeze behaviour:** as a SOLVER it follows the established rule — FROZEN is the default, it caches its
  result, and `Bake All` clears frozen caches before re-running. It gates on the **mask/flow input**, not on
  its own output. Follow the existing solver nodes; do not invent a new pattern.
* **Write it delta-accumulated from the start (§3.7).** Each iteration fills a `delta` buffer for every
  cell and applies it in a second pass — never an in-place scatter as the scan proceeds. In-place updates
  are order-dependent, a GPU dispatch has no defined cell order, and Hesiod runs `gpu::mudslide` on the
  GPU, so an order-dependent CPU kernel would foreclose the GPU path entirely. `talus_projection_solve`
  is the model.
* **Native:** `src/pasture_3d_mudslide.cpp`.
* **Oracle:** yes.
* **Gate — `GraphMudslideGate.gd`:** **MA** volume conservation — the total height integral changes by < 0.1%
  (control: a lossy implementation must fail); **MB** material moves strictly downhill; **MC** with a mask,
  cells outside the mask are bit-identical to the input; **MD** `iterations = 0` is a pass-through; **ME**
  FROZEN holds its result across a graph revision bump and `Bake All` regrows it against the current
  upstream; **MF** parity; **MG** resolution invariance (§3.6) — the same slide at two grid resolutions moves
  the same volume the same world distance. *Control:* a `talus / gw` implementation must fail.

---

## 9. Summary table

| Phase | Node | Op tag | Role | Grid? | Fusible | Oracle | Native | GPU |
|---|---|---|---|---|---|---|---|---|
| 1 | Transform | `transform` | FILTER | ✓ | — | ✓ | `pasture_3d_transform.cpp` | new `.glsl` |
| 1 | Falloff | `falloff` | FILTER | — | ✓ | — | fold opcode | via cell fold |
| 1 | Contrast | `contrast` | FILTER | — | ✓ | — | fold opcode | via cell fold |
| 2 | Distance Transform | `distance_transform` | FILTER | ✓ | — | ✓ | `pasture_3d_distance_transform.cpp` | new `.glsl` |
| 2 | Expand / Shrink | `expand_shrink` | FILTER | ✓ | — | ✓ | `pasture_3d_morphology.cpp` | new `.glsl` |
| 3 | Relative Elevation | `relative_elevation` | FILTER | ✓ | — | ✓ | `pasture_3d_local_metrics.cpp` | shares a shader |
| 3 | Smooth Fill | `smooth_fill` | FILTER | ✓ | — | ✓ | `pasture_3d_smooth_fill.cpp` | new `.glsl` |
| 3 | Recast Cliff | `recast_cliff` | FILTER | ✓ | — | ✓ | `pasture_3d_recast.cpp` | new `.glsl` |
| 4 | Warp Downslope | `warp_downslope` | FILTER | ✓ | — | ✓ | `pasture_3d_warp_downslope.cpp` | new `.glsl` |
| 4 | Gavoronoise | `gavoronoise` | GENERATOR | — | ✓ | ✓ | `pasture_3d_gavoronoise.cpp` | via cell fold |
| 5 | Flooding (Uniform Level) | `flooding_uniform_level` | FILTER | — | ✓ | — | fold opcode | via cell fold |
| 5 | Water Mask | `water_mask` | FILTER | ✓ | — | ✓ | `pasture_3d_water_mask.cpp` | shares a shader |
| 5 | Mudslide | `mudslide` | SOLVER | ✓ | — | ✓ | `pasture_3d_mudslide.cpp` | new `.glsl` |

**Registry categories:** Transform, Falloff, Contrast, DistanceTransform, ExpandShrink, RelativeElevation,
SmoothFill, RecastCliff, WarpDownslope → `"Filters & Modifiers"`; Gavoronoise → `"Generators"`;
FloodingUniformLevel, WaterMask, Mudslide → `"Solvers & Realism"`.

**Shared code built once, used repeatedly** — this is why the phase order is what it is:

* the separable min/max kernel (§5.2) → used by RelativeElevation (§6.1)
* the box blur → used by SmoothFill (§6.2), RecastCliff (§6.3), WarpDownslope (§7.1)
* the exact distance transform (§5.1) → used by WaterMask (§8.2)
* the bilinear resampler (§4.1) → used by WarpDownslope (§7.1)
* the derivative-accumulation scaffold in `noise_jordan` → used by Gavoronoise (§7.2)

Building the phases in order means each of those exists before its second consumer needs it.

---

## 10. Explicitly out of scope

* **The `Cloud*` / `Path*` families (~40 Hesiod nodes).** They require new `PortType` values and a bridge to
  the existing spline/brush system. That is its own spec, not a batch.
* **`Voronoi` / `NoiseFbm` / `NoiseRidged` / `Voronoise`.** `FastNoiseLite` already covers these through the
  existing `Noise` node; wrappers would be palette clutter. Gavoronoise is included precisely because it is
  the one member of that family FastNoiseLite cannot express.
* **Export / colour / texture nodes.** Pasture3D's material and export paths are host-side, not graph-side.
* **The Quilting family.** High implementation complexity, narrow application.
* **Coordinate-frame push-down (§3.1 option B).** Deferred deliberately, with a migration path that keeps
  the `transform` op tag stable.

---

## 11. Open questions for the author

All three settled as of 2026-08-30; kept with the reasoning rather than deleted.

1. **`Contrast` height window.** ~~The spec requires an explicit `range_min`/`range_max` because
   Pasture3D heights are metres.~~ **Answered 2026-08-30: auto-window by default, with an Explicit
   Window checkbox.** The author chose the cheaper-to-author default over the stable one, and the
   checkbox is the escape hatch rather than the other way round.
   - **What ships.** `explicit_window` is off by default. Off, the window is the input's own finite
     min/max for that bake and `range_min`/`range_max` are ignored entirely. On, the authored metres are
     used verbatim and the node is a pure function of its input again.
   - **The cost, stated plainly.** Auto makes the output content-dependent. Two masked brush regions
     that see different extremes normalise differently, and along the edge where they meet that shows up
     as a seam. The cure is ticking Explicit Window, so the answer to a seam is one checkbox rather than
     a redesign — which is what makes the cheap default defensible.
   - **The GPU had to grow a reduction.** A height window taken from the whole grid is not something a
     pointwise kernel can compute, and declining the GPU for an auto-windowed Contrast was not an option:
     a GPU bail is *graph-wide*, so the shipped default would have dropped every node in the graph to the
     CPU. Auto therefore runs as three dispatches — a per-workgroup min/max reduction into shared memory
     (`GRAPH_GRID_GLSL` mode 22), a fold of those pairs into a single pair (mode 23), then the existing
     shaping pass reading the window from binding 3. Explicit Window still runs as one dispatch.
   - **Gated** by `GraphDomainRangeGate` section CE: auto equals a hand-pinned window at the input's
     extremes, the authored metres are provably dead while auto is on, and the GPU agrees with the CPU
     to 2e-5 m. Verified windowed — headless has no RenderingDevice and the section reports NO-SIGNAL
     there rather than passing silently.
2. **`Transform` and world-space continuity.** ~~Should it warn inside a brush graph, or is the break
   the whole point and the warning just noise?~~ **Answered 2026-08-30: warn inside a brush, stay silent
   on a full terrain.** On a full-terrain graph there is no neighbouring region to disagree with, so the
   break costs nothing and a warning there is the kind of noise users learn to ignore. Inside a brush
   there *is* a neighbour, and the break reads as a seam.
   - **How the node knows.** It does not, and deliberately. A new base hook `node_warnings_in_brush()`
     (empty by default) is collected by `Pasture3DTerrainGraph.graph_warnings(p_in_brush)`, and the
     *host* passes the flag — `Pasture3DNodeGraph` passes true. The context is an argument rather than
     state on the resource because the same `.tres` is meant to drive a landscape AND sit in a brush;
     caching it on the graph would make the warning depend on whichever host touched it last.
   - An identity Transform is exempt: it relocates nothing, so there is nothing to disagree about.
   - **Gated** by `GraphTransformGate` section TW, with the silent-on-terrain half and the identity case
     both carried as controls.
3. **`Mudslide` vs `Scree`.** ~~Both deposit loose material downslope and both output a shed/deposition
   mask. If in practice they read the same on screen, the batch is better off with twelve nodes than
   thirteen.~~ **Answered 2026-08-30: keep both.** `project/bench/GraphScreeMudslideAB.tscn` runs the A/B on
   a Gavoronoise mountainside (256² over 512 m, 2 m cells, 61 m of relief) and compares the two *deltas*,
   which is the only fair comparison — Scree's port 0 is the deposit alone, Mudslide's is the surface after
   the slide, so the outputs are not the same kind of thing to begin with. Findings:
   - **They are different operations.** Mudslide conserves exactly (net 0.0 m; half of all its movement is
     removal). Scree nets +36,560 m over the patch: most of what it lays down is material it invented. No
     parameter on either node crosses that line.
   - **They do not resemble each other**, judged against how much each node resembles itself. Scree reseeded
     against itself correlates +0.797; Mudslide at 60 m against 90 m of travel, +0.882; Scree against
     Mudslide, **+0.246**.
   - **They put material in different places.** Scree deposits on ground averaging 33.2° — the steep face its
     slope gate selects. Mudslide deposits on 29.4° and takes from 35.5°: it empties the face and builds
     below it.
   - **Texture scale does not separate them**, contrary to the expectation going in: both deltas are
     dominated by detail finer than 20 m, and Mudslide is marginally the finer of the two. Recorded because
     the measure was run; it is not part of the case.
   - **On screen** the delta maps settle it. Scree is a red-only filigree threaded along the crests; Mudslide
     is broad blue scour across the upper faces with red accumulating in the drainage network. Nobody would
     mistake one for the other.

   One tuning observation from the same run, not a defect: at a 22° talus angle on terrain this steep,
   Mudslide mobilises nearly everywhere at once and the surface reads as granular scour rather than as
   discrete lobes. Distinct slides want a talus angle above most of the terrain's slope, or a wired mask.
