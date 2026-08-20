---
title: Brush-Hosted Erosion and Landform Relief
aliases: [Brush Erosion, Host Profile, DLA Relief, Sediment Transport]
tags: [pasture3d, terrain, erosion, sim, relief, mound, spec]
updated: 2026-08-20
---

# Pasture3D Brush Erosion Spec (`Pasture3DMound.erosion`, and four things it needs)

**Status:** Drafted 2026-08-20 from a design interview after four months of using the shipped relief and
Sim systems. **PHASES 1 AND 2 BUILT 2026-08-20** (§4, §5) — gates BM–BQ pass headless in
[bench/HostProfileGate.tscn](project/bench/HostProfileGate.gd), and `bench/PlowReliefCheck.tscn` and
`bench/MoundReliefCheck.tscn` both re-run at 0 failures, which is the migration evidence.
**Phase 1 user-verified in the editor 2026-08-20** (Strata banding a Mound's own profile); phase 2 is
headless-only so far. Gates BR–BU pass in [bench/SedimentGate.tscn](project/bench/SedimentGate.gd),
and all twelve existing Sim gate suites re-run at 0 failures. Phases 3–6 are NOT BUILT.
Target: Godot 4.7, Pasture3D `main`.

> **One departure from §4.2, decided during the build.** The Host Profile divisor is the **measured peak
> of the profile grid**, not the brush's `height` property. `height` is not the crest in two shipped
> configurations — an uncapped slope ("cone") derives its height from geometry and never reads `height`,
> and a capped mound whose `falloff_width` exceeds its half-width never reaches full profile — and in both
> a `height` divisor would put every authored band somewhere other than where it was put. The peak is
> still a deterministic function of the loop and the shape properties, so the non-drifting argument is
> unchanged.

**Goal (user, 2026-08-20):** *"The reason I added reliefs and erosion is to increase the brush quality…
what I would like is a system that iterates over the brush output."* A `Pasture3DMound` should be able to
erode **itself**, without a second node and a second spline describing an area its own loop already
describes, and it must work on a mountain 1 km tall and 2–3 km long.

**Builds on:** [PASTURE3D_SIM_NODE_SPEC.md](PASTURE3D_SIM_NODE_SPEC.md) (the solver, the manager, the pass
chain), [PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md](PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md) (the op program
and its GDScript oracle), and [PASTURE3D_MOUND_RELIEF_SPEC.md](PASTURE3D_MOUND_RELIEF_SPEC.md) (the second
host for relief materials).

**Supersedes:** the *"phase 8 — NOT YET SPECCED"* row in
[PASTURE3D_SIM_NODE_SPEC.md](PASTURE3D_SIM_NODE_SPEC.md) §14, and closes §15.10. **Phase 1 below is that
phase**, specced as its author asked ("spec it after phase 7") and widened, because the same missing field
turns out to fix the strata/terraces complaint as well.

**Does not supersede `Pasture3DSim`.** The standalone node stays exactly as it is. It is the right tool
for eroding authored terrain across many brushes and for blending; this spec adds a second host, the same
way the Mound relief spec added a second host for relief materials.

---

## 1. The four complaints this answers

From use, 2026-08-20. Each row is a real report, then what is actually wrong underneath it.

| Reported | What is actually wrong |
|---|---|
| *"Erosion requiring its own spline and node increases the clutter in the editor"* | A `Pasture3DSim` is a `Pasture3DTerrainBrush` with its own loop. When the thing you want eroded is a Mound, that loop **duplicates the Mound's loop** and the two must be kept in agreement by hand. The area is already authored; the Sim re-authors it |
| *"The system does not work on realistic sized mountains or terrain features"* | A 3 km × 2 km area at 1 m spacing is **6M cells** against the 581k the solver was profiled at, and 61 % of that solve is a memory-bound priority-flood. Linear extrapolation is ~35 s per build and it will be worse than linear once the working set leaves cache |
| *"Terrace and strata reliefs are applied over random noise when they should be applied over the terrain input"* | `TERRACE` and `STRATIFY` band `acc`, the relief accumulator, which **never contains the host's shape**. `Base Amount` exists only to give them something to band, and that something is a fractal. So a Mound gets strata across noise, floating over the hill, instead of benches cut into it |
| *"No sediment transport"* (agreed, 2026-08-20) | The solver is detachment-limited: it removes and never redeposits. `Pasture3DSimResult.deposition` is a near-empty channel, and the landscape reads as **cut** rather than weathered |

**The through-line:** relief and Sim were both added to raise *brush* quality, and both ended up as things
that live beside a brush rather than in it.

---

## 2. Decisions (from the design interview, 2026-08-20)

| Question | Decision | Consequence |
|---|---|---|
| Erosion model on a brush | **Erode the finished dome.** The Mound's baked profile is the solver's input surface | Keeps §2's `U = 0`. `erosion_solve` is reused unchanged (modulo phase 2), and the brush's `height` stays literal |
| The uplift-domain alternative | **Deferred, not rejected.** Revisit as an `Uplift` mode once brush-hosted erosion is working | Schott 2023 grows mountains by simulating stream power over an uplift field, which produces emergent ridgelines rather than grooves cut into a dome. It is the stronger mountain look and a real departure — see §9.1 |
| Reaching km scale | **Multi-resolution amplification only, this round** | `fill_every`, GPU flow routing and a sparse grid are all live options and all deferred (§9.2). The stated goal is *"get the plugin in a usable state for me to build a level"*, and amplification is the one that reuses machinery already here |
| Manager ↔ brush membership | **A registry on the manager** — an exported list of participating brushes | Brushes stay where the artist put them in the scene tree. The manager remains the one place that knows build order, which is the property §19.2 chose the scene tree for. See §6 |
| Sediment transport | **Early — phase 2, before the scale work** | Amplification's whole deliverable is a *calibration constant*, and calibrating against a solver you are about to replace means calibrating twice |
| DLA | **A baked field, delivered like `op_luts`** | Grown once per bake in GDScript, passed into the program as a float block, bilinear-sampled by both evaluators. One implementation, so oracle parity is free rather than maintained. See §8 |
| Which brushes host erosion | **Mound only, this round** | Same call the Mound relief spec made for the same reason: the refactor Mound forces is what makes Ridge and Trough cheap later. Plow is a stamp, not a landform, and is not a candidate |

---

## 3. Out of scope

- Erosion on `Pasture3DPlow`, `Pasture3DRidge`, `Pasture3DTrough`, `Pasture3DSplat`.
- Any change to `Pasture3DSim`, `Pasture3DSimPass`, or the existing pass chain, beyond the registry in §6.
- Runtime erosion. This is an authoring tool, as §3 of the Sim spec already says.
- Glacial, coastal and aeolian erosion.
- The uplift domain (§9.1) and every scale lever except amplification (§9.2).

---

## 4. Phase 1 — the host profile field

**The missing field.** `relief_eval` receives a `ReliefSample` carrying `altitude`, `slope_deg`,
`curvature` and the gradients — all derived from `base_below`, the composite of layers *beneath* this
brush's layer. That is what stops a brush gating on its own output and drifting, and for a Plow over
existing terrain it is exactly right. For a Mound it is the whole problem: the ground below a Mound is
whatever it was placed on, usually flat, so `slope ≡ 0`, `curvature ≡ 0`, `altitude ≡` one constant, and
every filter type returns the same uniform weight.

**Add a second field source: `base_own`, the brush's own generated profile before relief.**

In [`stamp_mound_loop`](src/pasture_3d_brush_raster.cpp:566) this value already exists as a local. The
cell loop computes

```cpp
amp = sign * height * profile;      // <- the host profile, in metres
if (noise.is_valid())  amp += noise_strength * ...;
if (has_relief)        amp += relief_strength * relief_eval(...);
```

so the profile is in hand *before* the noise and relief terms are added to it. Phase 1 captures it into a
grid alongside `base_below`, derives the same five fields from it, and lets a selector or a profile op ask
for it by name.

**It cannot drift, and that is the point.** The mound profile is a deterministic function of the loop and
the shape parameters — `height`, `capped`, `invert`, `falloff_width`, the cone settings — and is
*independent of the relief*. A selector keyed on it therefore cannot feed its own output back into its own
mask, which is the property `base_below` was chosen for in the first place. The two-pass structure the
cell loop already has (profile first, relief second) is what makes this true rather than merely intended.

### 4.1 Node surface

On `Pasture3DReliefSelector`:

```gdscript
@export_enum("Below Layer", "Host Profile") var field_source: int = 0
```

Default `Below Layer` — **every existing selector reads exactly the grid it always read**, and gate BQ
pins that bitwise. `Host Profile` is meaningless on a Plow (its "profile" is its stamp, which *is* its
output); the Plow raises a configuration warning and falls back to `Below Layer` rather than silently
gating on garbage.

### 4.2 Band source on `TERRACE` and `STRATIFY` — the strata complaint

The two profile ops gain a band source, carried in the op's existing `flags` word (bits 2–3, which are
free) so `RELIEF_OP_STRIDE` does not change:

| Band source | Bands across | Use |
|---|---|---|
| `Accumulator` | `acc`, −1…+1 | **Today's behaviour, and the default.** Terracing another Stack layer's output |
| `Host Profile` | the brush's own shape, normalised by the brush's `height` | **The one this complaint is about.** Benches cut into the hill at constant elevation, following the hill |
| `Ground Altitude` | `base_below`, normalised by an authored range | Strata that continue across several brushes at one geological elevation |

**The divisor is stored, not printed.** `Host Profile` normalises by the host brush's `height`, which the
brush already owns and serialises; `Ground Altitude` normalises by an exported `Vector2` band on the
material, because there is no terrain-wide height the material could infer. A normalised field whose
divisor is not stored beside it is not an interface, and this is the third place in the codebase that
rule has come up.

`Base Amount` on `Pasture3DReliefStrata` / `Pasture3DReliefTerraces` keeps its current meaning and its
current default. Under `Host Profile` it is the wrong thing to have on — the hill *is* the base — so the
brush warns when a `Host Profile` band ships with a non-zero `Base Amount`, in the same sentence the
guide's "single most common mistake" callout already uses.

### 4.3 Cost

One extra `gw × gh` float grid and one extra fields build, and **only when a selector or a band source
asks for it**. `need_fields` already gates the existing fields build the same way; this extends the same
predicate. A Mound with no relief, or with relief that never names `Host Profile`, allocates nothing and
runs the loop it runs today.

---

## 5. Phase 2 — sediment transport

**The change:** replace detachment-limited stream power with the Yuan et al. 2019 formulation, which adds
a deposition term while keeping the implicit, O(N), unconditionally stable structure the whole design
rests on. The scheme is a Gauss–Seidel iteration in the **upstream** direction, with a convergence rate
independent of grid size.

`erosion_solve` gains one parameter — a deposition coefficient, `G` — and `ErosionParams` gains one field.
`G = 0` must reproduce today's solver **bitwise**, which is gate BS's control and the migration story for
every scene already built.

> **The caveat, up front.** Yuan's convergence *slows sharply* as `G` rises toward the transport-limited
> end member. This is not a small effect and it is not something to discover in the editor. The
> implementation caps the inner iteration count, reports the count actually used the way
> `diffusion_substeps` already is, and raises a configuration warning when it hits the cap — the same
> shape as §4.4's diffusion sub-stepping, for the same reason: silently clamping what the artist asked for
> is worse than telling them it was not reached.

**Two existing gates are SCOPED by this phase, not invalidated — a correction to this spec's first
draft.** Both remain true at `G = 0`, which is the default and what every existing scene runs at, so
`SimPhase1Gate` and `SimPhase2Gate` pass untouched and were confirmed to.

- **Gate R** (*"with `hillslope_diffusion = 0`, deposition is IDENTICALLY zero"*) is false at `G > 0` by
  construction — a transporting solver deposits with no diffusion at all, exactly as §15.8 of the Sim
  spec predicted. It is true and useful at `G = 0`, and **BR keeps it as its own control**: the claim
  "deposition happens with D = 0" is only evidence about G if the same fixture deposits nothing when G
  is taken away.
- **Gate K** (*"with `D = 0`, no cell rises"*) is the same shape: deposition raises ground, which is the
  point. True at `G = 0`, false above it.
- **Gate S** (deposited volume against a closed-form diffused Gaussian) is a `G = 0` claim throughout and
  needed no change.

**What this buys:** alluvial fans at slope breaks, valley fill, and a `deposition` channel with something
in it — which retroactively makes the `DEPOSITION` selector filter type worth having. It also directly
serves the mountain case: a mountain with debris aprons at its foot reads as weathered, and a mountain
with only incision reads as machined.

---

## 6. Phase 3 — erosion on the brush

### 6.1 Node surface

On `Pasture3DMound`, a new inspector group. Every property is hidden while `enable_erosion` is off, so a
Mound that does not use this looks exactly like a Mound does today.

```gdscript
@export_group("Erosion")
@export var enable_erosion: bool = false
@export_range(1, 200) var erosion_iterations: int = 30
@export_range(0.0, 1.0, 0.001, "or_greater") var erosion_rate: float = 0.08
@export_range(0.0, 1.0, 0.01) var area_exponent: float = 0.45
@export_range(0.0, 10.0, 0.01, "or_greater") var hillslope_diffusion: float = 0.15
@export_range(0.0, 2.0, 0.01) var deposition: float = 0.0          # phase 2's G
@export var erodability_map: Texture2D
@export var erodability_range: Vector2 = Vector2(0.25, 2.0)
@export var erosion_mask: Array[Pasture3DReliefSelector] = []
@export_tool_button("Bake Erosion") var _bake_btn = bake_erosion
@export_tool_button("Clear Erosion") var _clear_btn = clear_erosion
```

The names and defaults are deliberately **the Sim node's**, so a value tuned on a standalone Sim transfers
by reading it off one inspector and typing it into the other. `erosion_mask` reuses the §17 machinery
unchanged, and with phase 1 in place its selectors can finally read `Host Profile` — *"erode the flanks,
leave the summit"* becomes expressible.

There is no `catchment_margin`. See §6.3.

### 6.2 Where it runs — the seam

`stamp_mound_loop` already builds the brush's entire contribution into a `vals` grid (`gw × gh`, `NaN` =
no write) and only then calls `_apply_stamp_block`. `nan_blur` for `smooth_passes` already occupies that
gap. Erosion goes in the same place, immediately before it:

```
cell loop  ->  vals[]  ->  [ERODE]  ->  nan_blur  ->  _apply_stamp_block
```

Two mechanical facts make this work, and both were checked against the code rather than assumed:

1. **The solver needs an absolute surface; `vals` in ADD mode holds a delta.** The input surface is
   `base_below + amp`, and `base_below` is already passed into the stamp and already used for
   `relative_to_terrain`. What goes back into `vals` is `eroded − base_below`. In non-ADD modes `vals`
   already holds `base_y + amp`, i.e. the absolute surface, and is handed to the solver directly.
2. **`NaN` outside the loop is the correct boundary condition, for free.** `erosion_solve` turns non-finite
   input into a fixed outlet at `zmin − 1` so water leaves the authored world rather than ponding against
   an invisible wall. For a mound that is exactly the physics wanted: the ground off the loop is where the
   mountain's water goes.

**Erosion runs before smoothing, not after.** `smooth_passes` is a finishing blur; blurring the input and
then eroding it would erase the fine structure the solve keys on, and eroding after the blur is what the
artist means by "soften the result".

### 6.3 Why there is no catchment margin

`catchment_margin` exists because a loop boundary truncates the catchment that feeds it, and drainage area
is the dominant term in the incision law. **A mountain is the drainage divide.** Nothing upstream feeds it
— the loop boundary is where its water leaves, not where water arrives. So the margin's cost, which §5
records as quadratic and which is a large part of why the standalone Sim is expensive over a big area,
simply does not apply to this host.

This is the strongest structural argument for hosting erosion on the brush rather than beside it, and it
is worth stating as a claim that can be wrong: **gate CA measures it**, by comparing a brush-hosted bake
against the same mound eroded by a standalone Sim with a generous margin. If they disagree by more than
the falloff can explain, this reasoning is wrong and the margin comes back as a property.

### 6.4 Editing clears the erosion

Per the interview: *"If the brush was edited it would clear the erosion sim."*

The Sim node already has this machinery — `_baked_hash` records the loop footprint at bake time and
`_get_configuration_warnings()` reports *"area changed since the last simulation"* when it drifts. The
Mound reuses it, with one difference in severity: a Sim **warns** and leaves the stale layer alone,
because re-running it is expensive and the artist may be mid-comparison. A Mound **clears**, because the
Mound re-bakes on every edit anyway and a stale erosion delta sitting under a moved dome is not a state
worth preserving.

The hash covers the loop footprint **and** the shape parameters (`height`, `capped`, `invert`,
`falloff_width`, the cone settings) — changing the mound's height changes the surface the solve ran on
just as surely as moving a spline point does.

> **The failure mode this creates, named so it can be designed against:** a Mound that clears its erosion
> on every edit is a Mound you cannot tune interactively, because every parameter change throws away a
> multi-second solve. That is why phase 5 exists and why it is not optional. Until amplification lands,
> the honest workflow is: shape the mound, then bake erosion, then stop editing the shape.

### 6.5 Undo, and the layer

Brush-hosted erosion writes **nothing new**. The eroded surface goes into `vals`, which goes into the
brush's own layer through `_apply_stamp_block` exactly as an un-eroded mound does. There is no `Erosion`
layer, no second write, and no new undo action — a re-bake is a re-bake.

The consequence worth stating: **an eroded Mound's contribution is not separable from the Mound.** You
cannot toggle the erosion off and keep the bake, because the bake *is* the eroded surface. `Clear Erosion`
sets `enable_erosion = false` and re-bakes, which is a different operation from the Sim's `Clear
Simulation` and should not be named as if it were the same.

---

## 7. Phase 4 — the registry and Bake All Brushes

**The complaint:** *"the user doesn't have to track down all the brushes to resim them."*

`Pasture3DSimManager.passes()` collects **direct children** that are `Pasture3DSim` or
`Pasture3DSimPass`. Erosion-enabled brushes cannot join that way without being dragged under the manager,
which is the editor-clutter complaint from the other direction.

```gdscript
# On Pasture3DSimManager
@export var eroding_brushes: Array[NodePath] = []
@export_tool_button("Bake All Brushes") var _bake_all_btn = bake_all_brushes
@export_tool_button("Register Eroding Brushes") var _scan_btn = scan_for_eroding_brushes
```

- **Explicit and diffable.** The list is serialised into the scene, so what will bake is readable without
  running anything, and the manager stays the single place that knows the order.
- **`Register Eroding Brushes`** scans the terrain's subtree for brushes with `enable_erosion` on and
  appends the ones not already listed. Discovery without making membership implicit — you press it, you
  see what it added, and you can reorder or remove.
- **Stale paths are reported, never silently dropped.** A `NodePath` to a deleted brush produces a
  configuration warning naming the path. Dropping it quietly is how a build silently stops including
  something.

**`Bake All Brushes` is a loop, not a chain.** Each brush erodes its own surface independently — there is
no shared grid, no clustering, and no pass semantics. That is the honest description of what it does, and
it is deliberately *not* the manager's existing chain: chained passes exist because pass 2 reads pass 1's
output, and two mountains on opposite sides of a map do not.

The whole run is **one undo action**. Cancel joins the worker between brushes, so cancelling mid-run
leaves the brushes baked so far baked, and the node reports how many of how many completed.

---

## 8. Phase 5 — multi-resolution amplification

**The problem, in numbers.** Profiled: 762² = 581k cells, 3.2 s, of which the priority-flood is 61 % and
is memory-bound. A 3 km × 2 km mountain at 1 m spacing is **6M cells** — 10× the cells, and worse than 10×
the time once the working set leaves cache.

**The approach.** [Schott et al. 2024](https://dl.acm.org/doi/10.1145/3658200) amplifies a low-resolution
terrain into a high-resolution, hydrologically consistent one by simulating at several scales rather than
one. Pasture3D already has both halves of this — `preview_resolution` and `build_resolution` — but as
*alternatives*. Amplification makes them a **sequence**:

```
solve N iterations at ÷8   ->  upsample  ->  solve M iterations at ÷1
   (3 km mountain = 375²,        bilinear      (structure is already there;
    ~0.2 s: the structural         delta        these iterations refine it)
    reorganisation)
```

This works because the network reorganisation that produces dendritic structure happens in the **early**
iterations — §4.5's progressive capture — while the later ones deepen a network that has already chosen
its shape. Running the choosing cheap and the deepening expensive is the trade.

### 8.1 The blocker, and it must be fixed first

§6 of the Sim spec measured and honestly recorded the thing that stops this working today:

> *the preview erodes **DEEPER** than the build — 1.28× the delta RMS on the synthetic fixture, and 2.5× at
> the probe point of a small (120 m) demo loop. A coarse cell's receiver is four times further down the
> hill, so channel slopes are measured over a longer baseline and the incision is less self-limiting.*

and then declined to ship a fix: *"a per-resolution calibration factor would be a fudge, and phase 1 does
not ship one."*

**That judgement was right for phase 1 and is wrong for this phase.** The difference is that phase 1 used
the coarse solve as a *preview* — something looked at and discarded — where amplification uses it as an
*input*, and an input whose depth is 1.28–2.5× wrong propagates into everything downstream.

**So phase 5 begins with a measurement, not an implementation:**

1. Sweep resolution divisor against delta RMS on fixtures that span the regimes — a synthetic bowl, a
   Y-catchment, the demo terrain, and a km-scale mound.
2. Establish whether the ratio is a **function of the divisor alone** (in which case it is a calibration
   curve) or also of terrain relief and `erosion_rate` (in which case it is not, and amplification needs
   a different correction — most likely matching the coarse solve's *slope baseline* rather than scaling
   its output).
3. **Store the constant on the result and on the brush, never print it.** A normalised or rescaled field
   whose divisor lives only in a log line is not an interface. This is the same rule §4.2 applies to band
   sources and the same one the Sim spec's §15.9 blocked a whole feature on.

If step 2 says the ratio is not a clean function of the divisor, **that is a real result and the phase
changes shape** — it does not become a fudge factor fitted to the demo terrain. Gate CG is written to fail
in exactly that case.

### 8.2 Node surface

```gdscript
@export_range(1, 16) var coarse_divisor: int = 8
@export_range(0, 200) var coarse_iterations: int = 24   # 0 disables amplification entirely
@export_range(0, 200) var fine_iterations: int = 6
```

`coarse_iterations = 0` runs the single-resolution solve that exists today, which is both the migration
path and gate CF's control.

---

## 9. Phase 6 — DLA relief

**What it is.** [Diffusion-limited aggregation](https://en.wikipedia.org/wiki/Diffusion-limited_aggregation)
grows a cluster by random-walking particles until they stick to it, producing a dendritic branching
structure. As a heightmap it reads as mountain ridges, because a ridge network is the topological dual of
a drainage network — DLA arrives at the same branching statistics erosion produces, without simulating
anything.

The [standard recipe](http://voxels.blogspot.com/2014/01/procedural-terrain-heightmap-generation.html) is
three steps: grow the cluster, drawing each new point back to its parent with random midpoint displacement
on the connecting line; blur copies of the result at exponentially increasing radii; sum them weighted and
normalise. The stronger variant grows at low resolution, upscales, subdivides the edges, and grows again —
which is what produces a *hierarchy* of major ridges and minor spurs rather than one scale of branching.

### 9.1 It cannot be an ordinary op, and `op_luts` is the precedent

`relief_eval` is point-evaluated and branch-free: it answers "what is the height at `(u,v)`" with no
global state. **A DLA cluster cannot answer that** — there is no closed form for whether a point is on the
cluster without having grown the whole thing.

The op catalogue already contains something with this shape. `RELIEF_OP_CURVE` does not evaluate a
`Curve`; it samples a **baked LUT** that GDScript wrote into `op_luts` at compile time. A DLA field is the
same thing with two dimensions.

```
Pasture3DReliefDLA (GDScript)
  -> grows the cluster once per bake, at a capped working resolution
  -> writes it into the program's `op_fields` block
  -> RELIEF_OP_DLA bilinear-samples that block in nu,nv
```

**This makes oracle parity free rather than maintained.** Every other op is implemented twice — once in
C++ and once in the GDScript oracle they must agree to within 1e-4 — and a C++-side DLA would have forced
RNG parity across two languages, which is a genuinely bad thing to have to guarantee. Here there is one
implementation, in GDScript, and both evaluators sample the same bytes.

**The working resolution is capped**, mirroring `_load_height_lut`'s 256² cap on erodability: a ridge
skeleton is a broad structure and the blur stack dominates its final appearance, so more resolution buys
detail the vertex spacing cannot represent anyway. The cap is a property, defaulted at 512², with the
memory cost stated in the tooltip.

### 9.2 Mapping, and the warning it needs

DLA is sized by the loop, exactly like `CRATER`, so:

- **`FIT` and `SCATTER` are correct.** The cluster maps once onto the loop's oriented rectangle.
- **`TILE` is wrong** and produces a grid of identical mountains. The brush raises the configuration
  warning `CRATER` already has, in the same words.

### 9.3 What it composes with

| Combination | Result |
|---|---|
| DLA × host profile (phase 1) | A dome whose mass follows a ridge network — the "make this Mound a mountain" case, and the reason this phase is in this spec |
| DLA, then erosion (phase 3) | Erosion cuts drainage into the valleys DLA's ridges already imply, instead of into a smooth surface. The two agree structurally, which is why they reinforce rather than fight |
| DLA as an erodability map | Hard ridges, soft valleys, driven by the same field. Free once §7's *"accept a selector as an erodability source"* note is generalised to accept a field |

---

## 10. Build order

| Phase | Contents | Gates | Depends on |
|---|---|---|---|
| **1 — BUILT** | Host profile field; `field_source` on the selector; band source on `TERRACE`/`STRATIFY`; the measured divisor | BM–BQ ✅ | nothing |
| **2 — BUILT** | Yuan 2019 deposition in `erosion_solve`; `deposition` on the node; the sweep cap, its report and its warning | BR–BU ✅, BV deferred | nothing |
| **3** | `enable_erosion` on `Pasture3DMound`; the solve in the stamp seam; clear-on-edit | BW–CB | 1 (for masks worth writing), 2 (so the constants are set once) |
| **4** | The manager registry; `Bake All Brushes`; `Register Eroding Brushes`; stale-path warnings | CC–CE | 3 |
| **5** | The resolution-calibration measurement, **then** coarse→fine amplification | CF–CJ | 2, 3 |
| **6** | `Pasture3DReliefDLA` as a baked field op | CK–CN | 1 (to multiply by the host profile) |

**Phases 1 and 6 are independent of the erosion chain** and can be pulled forward if a visible win is
wanted sooner — phase 1 in particular is the cheapest item here and fixes a complaint on its own.

**Phase 3 does not reach the km case without phase 5.** It is testable and useful at a few hundred metres,
and phase 5 is what lifts it to the stated 2–3 km target. Anyone reading this order as "phase 3 ships the
mountain" has read it wrong.

---

## 11. Gates

Same discipline as the rest of the repo: **every criterion needs a control that fails**, and each must be
able to tell "measured nothing" from "measured correctly". Letters run **BM onward** — A–Z, AA–AZ and
BA–BL are consumed, and the rule of taking the free letters rather than the next ones is the one §14 of
the Sim spec already established.

| # | Criterion | Control that must fail |
|---|---|---|
| BM ✅ | *(1)* **The host profile field carries the shape and none of the relief.** A hard ALTITUDE band on the host profile shuts relief off at a fixed height up the dome; tripling `relief_strength` must not move that boundary. **Probe 13 at 3 m and probe 13 at 9 m.** | Tripling the strength must triple the relief inside the band — **0.696 m → 2.087 m** — or a bake stamping nothing at all would report two identical boundaries and pass. |
| BN ✅ | *(1)* **A Host Profile slope band separates flank from crown.** On a capped Mound, **crown 0.000 m, flank 1.231 m**. | The **same selector on `Below Layer`** must fail to separate them, and the statistic is the SEPARATION rather than either mean — which is what makes the control independent of what the demo ground happens to be doing. It reads the terrain under the Mound, which knows nothing about where this dome's crown is: **0.050 m against 1.231 m**. Plus `strength = 0`, which must cover the crown — **1.278 m, up from 0.000**. |
| BO | *(1)* **`Host Profile` banding follows the hill.** A square loop's signed distance is symmetric through its centre, so mirrored probe pairs sit at the same height up the dome and must land on the **same bench** — measured at **0.79 m against a 2.00 m riser**. | Band source `Accumulator` with its Base Relief, i.e. today's behaviour, which must scatter the same pairs across different benches — **3.51 m**, nearly two risers. **Plus a diagnostic that decides what the headline number means**: with `hardness = 0` the op is a pass-through, so the disagreement measures the FIELD, and it is not zero — the chamfer SDF is a few per cent lopsided through the centre and a field that IS the dome inherits exactly that. The criterion is therefore that the two lopsidednesses are the SAME one, scaled by `2 × strength / height`: **0.284 m measured against 0.327 m predicted from the dome's own 1.090 m**. A field derived from anything else would not track it. |
| BP ✅ | *(1)* **The historical band source and field source are the defaults**, on fresh resources and on every shipped preset — **5 settings across `demo/data/relief/`, all historical**. A default that drifts silently re-shapes every scene that ever loaded one. | One preset switched to `Host Profile`, which must move the ground — **6.86 m**. A migration gate that cannot detect a change is not testing migration. |
| BQ ✅ | *(1)* **The C++ evaluator and the GDScript oracle agree** on all three new paths at once — a host-profile SLOPE selector with a `measure_radius`, a `Host Profile` band, and a `Ground Altitude` band. Measured as the gap the new paths ADD over a dome-only baseline, because the dome term carries a pre-existing float-against-double divergence that scales with amplitude: **+0.00003 m against a 0.0001 m tolerance**, on a fixture deforming the ground **38.0 m**. | The dome-only baseline itself (**0.00032 m**), which is what separates a divergence this phase introduced from one it merely made visible. Plus the deformation, which must dwarf the tolerance or two nearly flat surfaces are being compared. |
| BR ✅ | *(2)* **Deposition happens with hillslope diffusion at zero**, and lands where the physics says: on a slope-break fixture at `G = 0.5`, **927 cells gain material, 559 m of it below the break against 105 m above**. | `G = 0` on the same fixture must deposit **identically** zero — old gate R, preserved as this one's control, and it reads **0 cells**. Plus the fixture must erode at all (**174 660 m removed**), or "deposited below the break" is about nothing. |
| BS ✅ | *(2)* **`G = 0` never enters the iterative path.** The solver reports **0 Gauss-Seidel sweeps**, two runs are bitwise identical, and a params dict with no `deposition` key at all — what every already-authored scene sends — is bitwise an explicit `0`. | `G = 0.5` must run sweeps and move the ground: **8 sweeps, 14.95 m**. Without it, a solver that ignored `deposition` entirely would pass every agreement above. |
| BT ✅ | *(2)* **G puts material back, and never more than it took.** Across a sweep `G = 0 … 0.75`, net erosion falls monotonically **by 38 %** and net deposition rises monotonically **0 → 1238 m**, with deposition never exceeding erosion. **The measurement is on net erosion, not on the retained fraction**, and that is the point: §8.2 decision 3 defines the two channels as the two signs of one *net* field, so a channel cell that gains 0.3 m and loses 0.5 m in the same step reports as erosion — net deposition comes out near 1 % while the material actually moving is tens of per cent. That is §15.8's open question, not a defect here. | `G = 0` must deposit exactly zero, and the sweep must span a real range — **38 %** — or "monotonic" is four near-equal numbers in a row. |
| BU ✅ | *(2)* **The sweep count tracks `G`, is reported, and is bounded.** **4 sweeps at `G = 0.1`, 7 at 0.4, 10 at 0.7, 12 at 0.95** — the published 1-to-20 shape — and never above the ceiling of 50. | A moderate `G = 0.3` must converge **under** the ceiling and report `capped = false`, which it does. A cap that is always hit is not a cap, and a flag that is always true tells nobody anything. |
| BV ⏸ | *(2)* **Cost stays close to linear in cell count.** Solve time across 64²/128²/256² at fixed `G`. **Written but NOT RUN — perf gates need the user's go-ahead on this machine**, so `_gate_bv_cost(false)` skips it and prints what it would do. | `G` raised toward the transport-limited end, where the published behaviour is that convergence degrades. If that does *not* show up, the gate is not measuring convergence. |
| BW | *(3)* **A brush-hosted bake erodes.** The eroded Mound differs from the un-eroded one by a measurable delta, concentrated in channels rather than spread uniformly (drainage area is heavy-tailed, as gate E measures). | `enable_erosion = false`, which must reproduce today's Mound bake **bitwise**. |
| BX | *(3)* **The delta written is `eroded − base_below`.** The layer's contribution, read back through `get_height`, equals the eroded absolute surface minus the ground beneath the layer, on every cell inside the loop. | The same comparison against `eroded − 0`, i.e. forgetting the base — which must be wrong by the ground height, and on flat ground at y=0 would not be, so the fixture sits on sloped, non-zero terrain. |
| BY | *(3)* **Editing clears.** Moving a spline point, and separately changing `height`, each invalidate the hash and clear the erosion. | A change to a property that does **not** affect the solved surface (the node's name, its relief material's `output_curve`), which must **not** clear — otherwise the hash is over-broad and the workflow is unusable for a different reason. |
| BZ | *(3)* **Water leaves at the loop edge.** No standing water accumulates against the rim: `lake_depth` at the boundary ring is zero, while an interior basin in the same fixture ponds. | The same mound with the no-data outlet suppressed, which must pond at the rim — otherwise the fixture has no water reaching the edge and the claim is empty. |
| CA | *(3)* **The no-margin claim holds (§6.3).** A brush-hosted bake and a standalone Sim over the same mound *with* a generous catchment margin agree within what the falloff explains. | The same comparison on a mound placed **downslope of a large hill**, i.e. a landform that genuinely does receive upstream flow — which must **disagree**. That is the case §6.3's reasoning does not cover, and the gate exists to find its edge, not to confirm the happy path. |
| CB | *(3)* **Idempotent and deterministic.** Two identical bakes are bitwise identical; a re-bake does not drift. | The full composite read instead of `composite_height_below` — the mistake gate H already guards for the Sim, applied to the new host. |
| CC | *(4)* **Bake All bakes exactly the registered set, in list order.** Registered brushes change; unregistered erosion-enabled brushes in the same scene do not. | An unregistered brush with `enable_erosion` on, which must be untouched — otherwise the registry is decorative and the manager is scanning. |
| CD | *(4)* **A stale path warns and does not drop.** A `NodePath` to a deleted node produces a configuration warning naming it, and the remaining brushes still bake. | The same run with every path valid, which must warn nothing. |
| CE | *(4)* **One undo restores everything.** After Bake All over N brushes, a single Ctrl+Z returns every layer to its prior state. | Cancel mid-run, which must leave the completed brushes baked and report the partial count — a gate that only tests the clean path does not test the interesting one. |
| CF | *(5)* **Amplification matches a full-resolution solve on large-scale structure**, at the correlation §6 already established as the honest claim (≥0.86 on the low-frequency delta), and is measurably faster. | `coarse_iterations = 0` — today's single-resolution solve — which must be slower and must correlate at 1.00 with itself. |
| CG | *(5)* **The depth-calibration constant is a function of the divisor alone.** The measured RMS ratio across fixtures spanning terrain relief and `erosion_rate` collapses onto one curve within tolerance. | The **same sweep across relief and rate**, which is the control *and* the criterion: if the ratios do not collapse, this gate **fails and phase 5 changes shape** (§8.1). It is written to be capable of rejecting the approach, not of confirming it. |
| CH | *(5)* **The constant is stored, not printed.** The factor used is serialised on the brush and on any result written, and a bake reloaded from disk reproduces its surface without re-deriving it. | Clear the stored value and re-bake, which must produce a *different* surface — otherwise nothing is reading it and storing it is theatre. |
| CI | *(5)* **The km case completes in budget.** A 3 km × 2 km mound at the terrain's spacing bakes within a stated wall-clock target. **Perf gate — needs the user's go-ahead before running.** | The same case with `coarse_iterations = 0`, which must be dramatically slower — the number this phase exists to move. |
| CJ | *(5)* **Amplified output is still hydrologically coherent.** The router on the amplified surface is a valid forest with no pits — gate A's criterion, re-run on the new path. | The upsample without the fine iterations, which must leave interpolation artefacts the forest test detects. |
| CK | *(6)* **The DLA field is deterministic from its seed.** Two bakes at one seed are bitwise identical; two seeds differ. | A fixed seed with the RNG reseeded from time, which must differ between runs. |
| CL | *(6)* **It is dendritic, not noise.** Branch-count and mass distribution against the heavy-tailed statistic gate E already uses for drainage networks. | White noise blurred through the same blur stack, which must fail the statistic — a blur stack alone produces something smooth and plausible, and that is precisely the null hypothesis. |
| CM | *(6)* **Both evaluators sample the same bytes.** The C++ op and the GDScript oracle agree to 1e-4 by construction; the gate asserts it rather than trusting the argument. | The oracle sampling a field grown at a different resolution, which must disagree. |
| CN | *(6)* **`TILE` warns.** A DLA material under `Mapping = TILE` raises the configuration warning, as `CRATER` does. | `FIT`, which must not warn. |

---

## 12. Open questions

1. **The uplift domain.** [Schott et al. 2023](https://dl.acm.org/doi/10.1145/3592787) sets aside the
   elevation domain and authors in the **uplift** domain: you specify where ground rises, and stream power
   grows the mountain — ridges, spurs and watersheds emerge rather than being cut into a shape that was
   already there. For a Mound, *"the dome is the uplift field"* is a natural reframing and produces a
   materially different, and probably better, mountain. **Deferred by decision, revisit once §6 works.**
   It would arrive as an `Erosion Mode` enum (`Incise` / `Uplift`), not as a replacement — and it makes
   the brush's `height` emergent rather than literal, which is the reason it is a phase and not a flag.
2. **The other three scale levers**, all deferred with amplification chosen over them:
   - **`fill_every`** — implemented, unexposed, projected **3.1×**. A quality trade (the network is stale
     four iterations in five), not an optimisation, which is why it needs a labelled property and not a
     default.
   - **GPU flow routing.** [FastFlow (Jain et al. 2024)](https://onlinelibrary.wiley.com/doi/10.1111/cgf.15243)
     computes flow accumulation in **O(log n)** parallel iterations and routes depressions in
     **O(log² n)**, replacing both the priority-flood and the sequential topological sort — i.e. the 84 %
     of the solve that is fill+route+accumulate. `Pasture3DGPURaster` is the compute host §11 already
     reserved. Highest ceiling, largest project, and **every gate baseline is re-derived rather than
     re-tuned** if it lands.
   - **A sparse or adaptive grid** — full resolution only where flow concentrates. Attractive on paper,
     but drainage area is a global quantity and I would want a prototype before committing. **This one is
     not known to work.**
3. **Erosion on `Pasture3DRidge` and `Pasture3DTrough`.** The Mound refactor is what makes them cheap, in
   the same way the Mound relief spec's refactor did. A Ridge's host profile is its crest section; a
   Trough's is its channel. Neither is specced.
4. **A rainfall multiplier on drainage area** (Sim spec §15.2) — still a one-line change with a large
   effect, and now more interesting, because a brush-hosted mountain is exactly the case where orographic
   bias (wet windward face, dry lee) is visible.
5. **Does an eroded Mound want its own `Pasture3DSimResult`?** §6.5 writes no separate layer, so there is
   nothing to key relief off — a `FLOW`-gated scree material on the mountain it was just eroded from is
   not expressible. The four channels exist during the solve and are discarded. Storing them costs four
   float grids per brush and §21.3's argument about what a result may honestly describe applies here
   unchanged: for a single brush over a single grid, all four channels *are* attributable, so unlike the
   pass case there is no half-lie. Probably wanted; deliberately not specced until §6 has been used.
6. **What `Clear Erosion` should mean on a brush that has been edited since.** §6.4 clears on edit, so by
   the time you press it there may be nothing to clear. Harmless, but it means the button is sometimes a
   no-op with no feedback.

---

## 13. Sources

- Braun & Willett 2013 — the O(n) implicit stream-power scheme the solver already uses.
- Barnes et al. 2014 — priority-flood, and the `+epsilon` variant `zf_route` depends on.
- [Yuan et al. 2019, *A New Efficient Method to Solve the Stream Power Law Model Taking Into Account Sediment Deposition*](https://agupubs.onlinelibrary.wiley.com/doi/full/10.1029/2018JF004867) — phase 2. O(N), implicit, Gauss–Seidel upstream; **convergence degrades toward the transport-limited end**, which §5 designs around.
- [Schott et al. 2023, *Large-scale Terrain Authoring through Interactive Erosion Simulation*](https://dl.acm.org/doi/10.1145/3592787) — the uplift domain (§12.1). Code: [H-Schott/StreamPowerErosion](https://github.com/H-Schott/StreamPowerErosion).
- [Schott et al. 2024, *Terrain Amplification using Multi-Scale Erosion*](https://dl.acm.org/doi/10.1145/3658200) — phase 5's approach.
- [Jain et al. 2024, *FastFlow: GPU Acceleration of Flow and Depression Routing*](https://onlinelibrary.wiley.com/doi/10.1111/cgf.15243) — §12.2's deferred GPU lever.
- [Diffusion-limited aggregation](https://en.wikipedia.org/wiki/Diffusion-limited_aggregation), and the [heightmap recipe](http://voxels.blogspot.com/2014/01/procedural-terrain-heightmap-generation.html) phase 6 follows.
