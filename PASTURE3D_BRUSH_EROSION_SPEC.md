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
**Phase 3 was reshaped 2026-08-20** into a brush modifier stack (§6) before any of it was built — see
the last five rows of §2.
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
| **How erosion attaches to a brush** *(2026-08-20)* | **A modifier stack on the brush's output**, not a property block behind a bool | Erosion is a FIELD operator and cannot be a relief op, so it was always a separate stage over `vals`. One such stage means an ordered list of them — and Noise, Relief and Smoothing already are that list, hard-coded. §6.1 |
| Where the stack lives | **`@export var modifiers: Array[Pasture3DBrushModifier]`** | No new nodes, which is the point. Matches `erosion_mask: Array[Pasture3DReliefSelector]`, already on Sim. §6.2 |
| Expensive modifiers vs `auto_refresh` | **Per-modifier Live / Frozen** | Erosion caches its grid and re-solves only on Bake, so the modifiers AFTER it stay tunable live. This is what makes an expensive modifier usable at all, and it is a better answer than the first draft's. §6.3 |
| The legacy `noise` / `relief` / `smooth_passes` | **Deprecated outright — on `Pasture3DMound` only** | No shipped level uses them, so "keep them alongside" buys nothing and costs two ways to spell one thing forever. Plow is excluded because removing its `relief` forces the question "what is a Plow without a `Source`". §6.6 |
| Phase 3's shape | **Split: 3a the refactor, 3b the erosion** | 3a's claim is bitwise-identical output, which needs the legacy path alive to compare against — so deprecation is the LAST step of 3a, not the first. §6.5 |

---

## 3. Out of scope

- Erosion on `Pasture3DPlow`, `Pasture3DRidge`, `Pasture3DTrough`, `Pasture3DSplat`.
- Any change to `Pasture3DSim`, `Pasture3DSimPass`, or the existing pass chain, beyond the registry in §7.
- Removing `Pasture3DPlow`'s `Source` enum, or the legacy properties on Ridge / Trough / Splat (§6.6).
- Modifiers that change a brush's footprint or mask. They transform heights over the brush's own grid;
  the loop and its falloff stay the brush's.
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

## 6. Phase 3 — the brush modifier stack, and erosion inside it

> **Reshaped 2026-08-20, before any of it was built.** The first draft made erosion a block of exported
> properties on `Pasture3DMound` behind an `enable_erosion` bool. The user's counter-proposal — a
> modifier stack applied to the brush's output before it composites — is better, and the rest of this
> section is it. Phase 3 is now **3a**, the stack as a behaviour-preserving refactor, and **3b**, the
> Erosion modifier and the field context it publishes.

### 6.1 The stack already exists; it is just hard-coded

`stamp_mound_loop` runs this pipeline today, in this order, with no way to change it:

```
profile  ->  + noise  ->  + relief  ->  nan_blur(smooth_passes)  ->  composite
```

Noise, Relief and Smoothing **are already modifiers**. They have a fixed order, cannot repeat, and
nothing can be inserted between them. This phase makes the list explicit rather than inventing a concept.

**And it is not merely tidier — it is the only shape erosion fits into.** There are two kinds of
operation here, and they have been quietly conflated:

| | **Point operators** | **Field operators** |
|---|---|---|
| Examples | everything in `relief_eval` — FBM, CRATER, TERRACE, SCREE | erosion, blur, DLA growth |
| Sees | one cell, no neighbours | the whole grid |
| Composes via | the flat op program; a Stack costs nothing extra | **nothing, today** |

A field operator **cannot** be a relief op. That is not a preference: `relief_eval(u, v)` has no grid to
look at. So erosion was always going to be a separate stage over `vals`, and once there is one such
stage there has to be an ordered list of them.

That settles the long-term division of labour, which is worth stating because it decides where every
future feature goes: **relief materials are the point-operator language; the modifier stack is where
field operators compose.**

**BUILT 2026-08-20, and the split turned out to be load-bearing in a second way.** The rasteriser
exploits it: a maximal RUN of point modifiers is folded into one cell loop in **double precision**, and
only a field modifier materialises the float grid. `Noise → Relief → Smooth` therefore executes as one
cell loop plus one blur — the same instructions, in the same order, rounding in the same place as the
pipeline it replaced. That is what made gate BW's *bitwise* claim reachable rather than aspirational; a
naive implementation that ran each modifier as its own pass over a float grid would have rounded three
times and could only ever have claimed a tolerance.

Two consequences worth writing down, because both are easy to undo by accident:

- **The interior mask stays a double, and is never stored.** `profile` is a pure function of the signed
  distance, so the point run recomputes it (one LUT lookup) rather than keeping a float grid of it.
  Rounding it would change every product it appears in.
- **Interleaving costs one conversion, and only when it happens.** The runner tracks whether the truth
  currently lives in the delta grid or the write grid and converts only when the next step needs the
  other. A stack that alternates point and field steps pays per boundary; the common stack pays once.

### 6.2 Node surface

```gdscript
# On Pasture3DTerrainBrush, so every brush has the slot
@export var modifiers: Array[Pasture3DBrushModifier] = []
```

An exported array of Resources — **no new nodes**, which is the whole point of the exercise. It matches
`erosion_mask: Array[Pasture3DReliefSelector]`, which the Sim node already carries, so the pattern is not
new to this codebase or to its users. Each modifier is a `.tres` that can be saved and shared.

The base resource:

```gdscript
@tool class_name Pasture3DBrushModifier extends Resource
@export var enabled: bool = true
```

**`evaluation` (Live / Frozen) was NOT built in 3a — it moved to 3b with the modifier that needs it.**
The freeze machinery is a cached output grid plus a staleness hash, and its only client is erosion; a
frozen blur is a cache for something that costs microseconds. Building it against that client would have
meant shipping the surface ungated, which is what §11's own discipline forbids. §6.3 stands as written,
as 3b's design.

**Two things the build settled that the sketch above does not show:**

- **`modifiers` is surfaced through `_get_property_list`, not as an `@export`.** A base-class `@export`
  appears ABOVE every subclass property; a dynamically declared one lands after them. A pipeline should
  read in the order it runs, which is below the shape properties it consumes. It is also what lets
  `_supports_modifiers()` hide the slot entirely on the brushes whose rasterisers do not run it yet —
  shipping a control that silently does nothing is worse than not shipping it. Gate BZ measures that the
  array still round-trips through a saved scene, because a non-`@export` var that stops persisting would
  take every modifier the artist authored with it.
- **Selector ids are rebased into ONE stack-wide block.** `ReliefFields::sel_slot`, which carries the
  measured-radius grids, is keyed by selector id — and two materials each numbering their selectors from
  0 would collide in it. So the host concatenates every relief modifier's selector block and offsets its
  ops' ids into the result. One block, indexed exactly as it always was, however many materials the stack
  carries.

- **The node's property list must never be a function of a value or of a name.** `notify_property_list_changed()`
  rebuilds the whole inspector, which collapses every expanded sub-resource and destroys any text field
  being typed into — and both values and names are edited *continuously*, a slider sweeping through every
  number on its way and a name arriving one keystroke at a time. This was got wrong twice. First the Mask
  Preview dropdown followed the first **active** Relief modifier, so dragging Strength up from 0 made the
  dropdown appear and folded the modifier shut under the cursor; it now follows the first Relief modifier
  with a **material assigned**, which is also the better rule — the preview exists to show where a
  selector *would* land, which is what you want before deciding how many metres to ask for. Second, the
  rebuild trigger included the dropdown's LABEL text, which embeds a relief layer's `resource_name`, so
  renaming a layer closed the field per keystroke exactly as renaming a modifier once did. The trigger
  (`_inspector_rebuild_signature`) is now structural only: what class each entry is and whether it carries
  a selector. A renamed layer keeps stale TEXT in the dropdown until something else rebuilds it, and the
  dropdown resolves by INDEX, so nothing reads wrong. Gates CT and CU. The same defect existed on
  `Pasture3DWaterBody`, which re-hinted its wave-profile dropdown on every knob of every profile — gate CV.

Phase 3a ships three, each reproducing one step the pipeline already hard-codes:

| Modifier | Replaces | Notes |
|---|---|---|
| `Pasture3DModNoise` | `noise` / `noise_strength` | A `FastNoiseLite` and an amplitude, masked by the profile exactly as now |
| `Pasture3DModRelief` | `relief` / `relief_strength` | Holds a `Pasture3DReliefMaterial` and a metres scale. **The relief system is untouched** — this is a host for it, the same way the Mound became a second host in PASTURE3D_MOUND_RELIEF_SPEC.md |
| `Pasture3DModSmooth` | `smooth_passes` | The existing NaN-aware blur |

### 6.3 Live and Frozen — the thing that makes expensive modifiers usable *(3b)*

> **BUILT 2026-08-20 (gate BY).** Three things the build settled that the design below left open:
>
> - **The cache is IN MEMORY ONLY.** The baked heights already persist — they are in the terrain's own
>   layer data — so a cache does not have to survive a reload for the landscape to. Persisting it would
>   buy skipping one solve after reopening a scene and cost tens of megabytes of float grid inside a
>   `.tscn`. Reopening and then tweaking a downstream modifier costs one solve; that is the whole price.
> - **The staleness key is a hash of the SURFACE HANDED TO THE SOLVER**, not an enumeration of what fed
>   it. That is what makes the detection complete: the spline, the shape properties and every modifier
>   above are all in the grid, and none of them can move without moving the hash. Folded with the solver
>   settings, which the grid does not capture. The native and GDScript paths deliberately do NOT agree
>   on the key — each only compares keys it wrote itself, and switching rasterisers costs one re-solve.
> - **One rule, applied to everything.** While Frozen, ANY change — upstream or to the modifier's own
>   sliders — leaves the cached solve in place and warns, until Bake Erosion. The alternative (own
>   parameters re-solve, upstream goes stale) reads better on a small brush and is exactly wrong on a big
>   one, where dragging `erosion_rate` would lock the editor per step.
>
> Cached per GRID EXTENT, so a brush with several loops caches one solve per loop instead of thrashing
> one slot. And a cached surface alone is not enough to serve: if a modifier below it now reads the
> published channels and the entry does not carry them, the entry is unusable however well its key
> matches — adding a flow-gated modifier does not change the solver's input, so the key WOULD still
> match and the new modifier would quietly read zeros.

`auto_refresh` defaults to on, and every spline drag re-bakes the brush. An erosion solve per drag is
unusable, and the first draft's answer to that (shape the mound, bake, then stop editing) was weak.

**Each modifier declares whether it recomputes on every refresh.** Noise, Relief and Smooth are Live.
Erosion defaults to **Frozen**: it caches its output grid and re-solves only on an explicit **Bake**.

The consequence is the real prize, and it is a better workflow than the first draft could offer:
**freeze the erosion and keep tuning the modifiers after it live.** Iterating on a flow-gated detail pass
no longer costs a re-solve. The stack is not just a tidier way to spell erosion — it is what makes an
expensive modifier tunable at all.

**The cost is a cached grid per frozen modifier**, at 4 bytes a cell: 36 MB for a 3000² brush. Real, and
it must be visible — the brush reports its total frozen-cache size the way `Plan Clusters` reports mask
memory (§21.3 of the Sim spec), because a number nobody sees is not a budget.

A frozen modifier whose cache does not match the current stack is **stale, and says so** rather than
silently serving old data or silently re-solving. Same rule, same wording, as a stale `SimResult`.

### 6.4 What a modifier may read — the invariant

The whole selector design rests on a brush being unable to gate on its own output. The stack generalises
that rather than weakening it:

> **A modifier may read fields produced at or before its own position. Never its own output, never a
> later modifier's.**

Strictly ordered, therefore acyclic, therefore every modifier's input is fixed before it runs. The
phase-1 host profile and `base_below` are simply position 0 in the same scheme. Re-bakes stay idempotent
because the stack re-runs from the profile every time — nothing accumulates.

### 6.5 Phase 3a is a refactor, and is gated as one

The stack must bake **bitwise** what the hard-coded pipeline bakes. That is the whole of 3a's claim, it is
gate BW, and it is the same de-risking move PASTURE3D_MOUND_RELIEF_SPEC.md used when it re-ran the
14-gate Plow suite unchanged to prove a shared refactor was behaviour-preserving.

**Which means the legacy path must still exist while 3a is verified.** There is nothing to compare
against otherwise. So deprecation is the *last* step of 3a, not the first:

1. Build the stack alongside. Legacy properties still work and still drive the bake.
2. **Gate BW:** a stack of `Noise → Relief → Smooth` reproduces the legacy bake to the byte, over the
   shipped `demo/data/relief/` presets and the existing suites' fixtures.
3. Convert the demo scenes and the Mound-driven gate suites to the stack.
4. Delete the legacy properties.

**DONE 2026-08-20, and here is the measurement, because after step 4 it cannot be taken again.**

> `Noise(3 m) → Relief(4 m) → Smooth(2)` against `noise` + `relief` + `smooth_passes` set identically, on
> a 100 m loop at height 40, over **2401 probes on the terrain's own vertex lattice**, comparing baked
> floats with `==` and not with a tolerance:
>
> **12 of 12 cases bitwise identical** — the eleven shipped presets in `demo/data/relief/`, plus a bare
> noise-and-smoothing configuration carrying no relief at all.
>
> Floor: two identical bakes agreed bitwise over all 2401 probes first, so the probe could answer a
> bitwise question. Controls: reordering to `Noise → Smooth → Relief` moved the bake 2.41 m, and
> disabling the Relief modifier moved it 3.27 m while reading bitwise identical to removing it.

Then step 4 deleted the pipeline — both cell loops and the five properties. **Keeping both alive to
re-prove a finished migration would have been the wrong trade**: the legacy arm is a whole cell loop, not
a thirty-line switch like `ErosionParams::legacy_flood`, and every future change to the profile or relief
evaluation would have had to be mirrored into code nothing calls. What replaced it as the standing
criterion is in `bench/BrushStackGate.tscn`: the native and GDScript implementations of the stack agree
to within the dome's own pre-existing divergence (it **adds −0.000004 m**), every shipped preset still
stamps, and re-baking is bitwise stable.

#### Two things the first build got wrong in the editor, reported from use

- **Every value edit collapsed the modifier.** The brush's `changed` handler called
  `notify_property_list_changed()` unconditionally; a rebuild folds every expanded sub-resource shut, so
  dragging one slider inside a modifier closed the modifier under the cursor once per step. Only two
  things the inspector shows are DERIVED from the stack — the modifier row labels and the Mask Preview
  Source list — so the handler now compares those and rebuilds only when one of them actually moves.
- **`label` on `Pasture3DBrushModifier`**, because a stack of three `Pasture3DModRelief` rows is
  unreadable. It is a view onto `resource_name`, which is what Godot's resource picker already draws in
  preference to the class name — so the storage and the wiring both existed, buried at the bottom of the
  built-in Resource section. `PROPERTY_USAGE_EDITOR` only, so there is no second string to drift.

**And the first fix for the label was backwards.** Rebuilding on a rename so the row would relabel is
wrong for a TEXT field: its setter fires once per character, so the field it was rebuilding was the one
being typed into, and the name closed after the first keystroke. A rename now rebuilds nothing — the
inspector re-reads `resource_name` on its own refresh, and forcing it costs the field its focus. The
same early return also keeps a rename from re-rastering the brush per keystroke: a name is not geometry.

All of it is measured on the node's own `property_list_changed` signal — 0 emissions for value edits, 0
for five keystrokes of renaming, ≥1 for a material swap, with the swap as the control so "nothing ever
rebuilds" cannot pass. "The inspector collapsed" regresses without anyone noticing until they are editing.

**The erosion family's gizmo and nameplate are dark blue** (`Pasture3DSimBase.EROSION_COLOR`). The default
neon purple washes out against the pale blue-grey a wet or checkered terrain renders as, which is exactly
the terrain a sim is usually aimed at. The colour is the BRUSH's decision — `_gizmo_color()` and
`_label_colors()` on `Pasture3DTerrainBrush` — and the gizmo plugin interns a material per distinct colour
asked for, so a new family declares a colour and nothing else. The nameplate is outlined near-white
rather than black, because a dark fill on a dark outline is a smudge at distance.

**A pre-existing bug surfaced on the way**, because the collapse fix put `_preview_selector_sources` in
the hot path: it duck-typed on `"layers" in relief` to find a `Pasture3DReliefStack`, and
`Pasture3DReliefStrata.layers` is an **int** — the band count. Any brush carrying a Strata material threw
on every inspector rebuild. Now tested by class.

**One finding about the gate itself, recorded because the spec proposed the wrong control.** The reorder
control was written as `Relief → Noise → Smooth`. That does not discriminate: Noise and Relief are both
POINT operators, they land in the same run, and both only ADD metres — swapping them changes nothing but
the order of two double additions. The reorder that tests the claim moves the **field** operator, because
where the blur sits relative to the relief is a genuinely different surface.

### 6.6 Deprecating the legacy properties — Mound only, this round

**DECIDED (user, 2026-08-20): deprecate outright rather than keep them alongside.** No shipped level uses
them, so the transition cost the "keep them as an implicit prefix" option was buying is not worth its
permanent cost — two ways to spell one thing, forever.

**But scoped to `Pasture3DMound`**, because the blast radius outside it is a different project:

| Brush | Legacy properties | This round |
|---|---|---|
| `Pasture3DMound` | `noise`, `noise_strength`, `relief`, `relief_strength`, `smooth_passes` | **Removed** |
| `Pasture3DPlow` | `source` (**an enum with 4 values**), `noise`, `relief`, … | Keeps them; gets the stack slot |
| `Pasture3DRidge` / `Trough` / `Splat` | `noise`, `noise_strength` | Keep them; get the stack slot |

`Pasture3DPlow` is excluded for a specific reason: its identity **is** `Source` — NOISE / TEXTURE /
MATERIAL / RELIEF. Removing `relief` there forces the question "what is a Plow without a Source", which is
a redesign with its own decisions and its own migration, not a side effect of this one. Deferred to its
own phase.

**The measured blast radius**, which is why this is affordable now:

| Suite | Drives | Needs converting |
|---|---|---|
| `MoundReliefCheck`, `HostProfileGate` | Mound | **yes** |
| `BakeIdentityProbe` | both | **no** — its only relief case drives a Plow |
| `PlowReliefCheck` + `PreviewSimDiag` + `SimPhase3Gate` + `SimPhase55Gate` + `SimPhase65SelectorGate` + `SimPreviewGate` | Plow | no |

Two suites, not nine — `BakeIdentityProbe`'s relief case turned out to be a Plow, so the "partly" in the
first estimate was wrong in the safe direction. That is the whole reason Mound-only is the right cut.

**DONE 2026-08-20. Both suites converted (0 failures each), and all six Plow-driven suites re-run
UNTOUCHED at 0 failures** — plus the seven other Sim suites and `SedimentGate`, which the cut said should
not be affected and were not.

#### The migration shim, which was not in the plan and had to be

"No shipped level uses them" is true of the user's levels and false of the repo: `sculpting_2.tscn` and
`big_regions.tscn` both carry Mounds with `relief` / `relief_strength` / `smooth_passes`. Deleting the
properties without more would have dropped their relief on load without a word — the exact failure mode
that makes a deprecation feel like a bug.

So `Pasture3DMound` carries a **one-way load-time migration**: `_set` stashes the removed keys during
scene load and `_ready` turns them into the `Noise → Relief → Smooth` stack they describe, warning that
the scene should be saved. It is deliberately not a second spelling of the same thing —

- there is no getter, and the names are absent from `_get_property_list`, so nothing re-saves them;
- assigning one **after** the node is in the tree is a `push_error`, not a quiet no-op, because a script
  still writing to a property that no longer exists is exactly the silence this exists to prevent;
- a node that already declares `modifiers` keeps it and warns, rather than being overwritten by stale keys.

Gate BZ measures it through a bake: the migrated stack is **bitwise identical** to the hand-built one.
Delete the block once the repo's scenes have been opened and saved.

### 6.7 Phase 3b — `Pasture3DModErosion`

> **BUILT 2026-08-20.** Gates CA, CB, CC, BX, BY, CE in `bench/BrushErosionGate.tscn`.
>
> `erosion_mask` was NOT built and is deferred: the brush's own footprint and the modifier's position in
> the stack already bound where it acts, and a selector mask is a further axis with its own failure modes
> and its own gate. Everything else in the sketch below shipped as written.
>
> Both paths call the SAME `erosion_solve` — C++ directly from the stack runner, GDScript through the
> existing `erode_heightfield` binding — so there is no second implementation of the solver to keep in
> step, and the A/B question is only about the grids handed to it.

```gdscript
@tool class_name Pasture3DModErosion extends Pasture3DBrushModifier
@export_range(1, 200) var iterations: int = 30
@export_range(0.0, 1.0, 0.001, "or_greater") var erosion_rate: float = 0.08
@export_range(0.0, 1.0, 0.01) var area_exponent: float = 0.45
@export_range(0.0, 10.0, 0.01, "or_greater") var hillslope_diffusion: float = 0.15
@export_range(0.0, 1.0, 0.01) var deposition: float = 0.0          # phase 2's G
@export var erodability_map: Texture2D
@export var erodability_range: Vector2 = Vector2(0.25, 2.0)
@export var erosion_mask: Array[Pasture3DReliefSelector] = []
@export var publish_fields: bool = true
```

Names and defaults are deliberately `Pasture3DSim`'s, so a value tuned on a standalone Sim transfers by
reading one inspector and typing into another.

**`publish_fields` is the half that makes the user's workflow work.** With it on, the modifier writes its
four channels — flow, erosion, deposition, wetness — into the stack's field context, where **any later
modifier's selectors can read them directly, in memory, with no `Pasture3DSimResult` on disk and no
`sim_result` reference to wire up.**

That is the node count actually falling:

| | Today | With the stack |
|---|---|---|
| Nodes | Mound + `Pasture3DSim` + a detail brush | Mound |
| Splines | 3 | 1 |
| Resource files | a `Pasture3DSimResult` | none |
| Constraints | the detail brush must sit on a layer **above** the Mound | none |

The `FLOW` / `EROSION` / `DEPOSITION` / `WETNESS` filter types gain a third source alongside "a
`SimResult`" and "nothing": **"the erosion modifier above me in this stack"**, which is where they should
have been able to look all along.

### 6.8 Where it runs, and why there is still no catchment margin

The seam is unchanged from the first draft and was checked against the code rather than assumed.
`stamp_mound_loop` already builds the brush's whole contribution into a `vals` grid (`gw × gh`, NaN = no
write) and only then calls `_apply_stamp_block`; `nan_blur` already occupies that gap. The stack replaces
that single blur call.

Two mechanical facts still hold:

1. **The solver needs an absolute surface; `vals` in ADD mode holds a delta.** The input is
   `base_below + vals`, and `base_below` is already passed in for `relative_to_terrain`. What goes back is
   `eroded − base_below`.
2. **`NaN` outside the loop is the correct boundary condition, for free.** `erosion_solve` turns non-finite
   input into a fixed outlet at `zmin − 1`, which for a mound is exactly right: the ground off the loop is
   where the mountain's water goes.

**A mountain is the drainage divide**, so nothing upstream feeds it and `catchment_margin` — quadratic,
and a large part of why the standalone Sim is expensive over a big area — does not apply to this host.
That is the strongest structural argument for hosting erosion on the brush, so it is stated as a claim
that can be wrong and **gate CD measures it**, with a control designed to break it.

> **MEASURED 2026-08-20, and the claim holds.** Solving the same landform in its own box with NaN outside,
> against a box expanded by half a loop on every side with the real surface everywhere, changed a
> self-draining dome's core by **1.4% of its own cut**. The control — the same footprint below a 300 m
> hill, which genuinely does receive upstream flow — changed by **42.3%**. So the no-margin result is not
> a gate that could not tell the difference: it is sensitive by a factor of thirty, and §6.8's reasoning
> is right about the shape it describes and wrong about the shape it says it does not cover.

### 6.9 Editing, and what a frozen modifier does about it

The Sim node already has this machinery: `_baked_hash` records the footprint at bake time and the node
warns when it drifts. A frozen modifier reuses it, hashing the loop footprint **and** everything upstream
of it in the stack — because a change to the Noise modifier above it changes the surface it solved just as
surely as moving a spline point does.

**A frozen modifier whose hash has drifted goes stale; it does not clear and does not silently re-solve.**
That is a change from the first draft, which cleared on edit, and it is better: clearing throws away a
multi-second solve at the exact moment you were mid-comparison, and it is what made the first draft's
workflow untunable. Stale data plus a warning is recoverable; deleted data is not.

Everything downstream of a stale modifier still evaluates, against the stale cache, so the brush keeps
rendering something rather than collapsing to bare profile while you work.

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
- **`Register Eroding Brushes`** scans the terrain's subtree for brushes carrying an enabled
  `Pasture3DModErosion` in their stack (§6.7) and
  appends the ones not already listed. Discovery without making membership implicit — you press it, you
  see what it added, and you can reorder or remove.
- **Stale paths are reported, never silently dropped.** A `NodePath` to a deleted brush produces a
  configuration warning naming the path. Dropping it quietly is how a build silently stops including
  something.

> **BUILT 2026-08-20.** Gates CF, CG, CH and CW in `bench/BrushRegistryGate.tscn`.
>
> **Three things the build settled that the sketch above does not say:**
>
> - **Bake All CLEARS THE FROZEN SOLVES FIRST.** Erosion defaults to Frozen (§6.3), so a bake that did
>   not clear would serve the cached answer and the button would do visibly nothing on exactly the
>   brushes it exists for. Clearing is what makes "Bake All" mean "re-solve". It happens per layer inside
>   the loop rather than up front, so a cancel leaves the brushes it never reached exactly as they were,
>   stale warnings included. Removing the clear fails five criteria across three gates.
> - **The unit of work is a LAYER OWNER, not a brush.** `_refresh_owner` clears a tool layer and repaints
>   every tool bound to it, so baking two registered brushes that share a layer one after the other would
>   do the same work twice. List order survives as: owners run in the order their first registered brush
>   appears in the list. The visible consequence, which gate CF measures rather than assumes, is that an
>   UNREGISTERED brush sharing a layer with a registered one **is** re-stamped — it has to be, or clearing
>   the layer would wipe it — and its frozen cache is what keeps its contribution bitwise unchanged.
> - **Staleness is detected at BAKE time, not at edit time.** The flag is raised when the host serves a
>   cached entry whose key no longer matches. In the editor `auto_refresh` supplies that bake on the very
>   edit that invalidates it, so the warning appears immediately; headless nothing does, and CF's first
>   draft asserted a staleness nothing had yet had a chance to notice.
>
> Also built beyond the sketch: `foreign` (a registered brush on another `Pasture3D`, which this manager's
> snapshots cannot resolve) and `unarmed` (a registered brush with no enabled erosion modifier) are both
> reported and neither is dropped. `last_bake_report` puts a CANCELLED run's partial count on the node as
> a configuration warning, rather than only in the Output log where a partial bake would be forgotten.

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

> **MEASURED 2026-08-20. The answer to step 2 is NO, and the phase changes shape as §8.1 provided for.**
> `bench/ResolutionCalibrationProbe.tscn` is the sweep — four fixtures (a smooth bowl, a Y-catchment, the
> demo terrain, a km-scale dome) crossed with two relief amplitudes, three erosion rates and two base cell
> sizes, at divisors 1/2/4/8: 144 points. `bench/ResolutionCalibrationGate.tscn` is gate CK, the standing
> subset.
>
> **1. The ratio is NOT a function of the divisor alone.** Across the sweep the divisor explains **10.2 %**
> of the variance in ln(ratio) against **3.4 %** for the same statistic with the labels shuffled — 22.0 %
> against 5.3 % once flattened fixtures are excluded. Put as two spreads: the mean ratio moves **1.26×**
> from divisor 2 to divisor 8, while **changing only `erosion_rate` at a fixed divisor moves it 2.07×**.
> The confound is bigger than the signal.
>
> **2. Relief is exactly neutral — and that is the harness's positive control.** The ratio is invariant to
> relief amplitude to **1.0037×** across three fixtures and three divisors. This is not luck: linear
> stream power is homogeneous in z, so scaling a surface scales every slope, every incision rate and the
> whole solution with it, and the ratio must cancel *exactly*. It is an analytic property of the equation
> being solved, which makes it the one number here that a broken measurement could not produce — a
> misaligned upsample, a boundary a cell out, or an RMS over the wrong cells all destroy it. Gate CK checks
> it first for that reason. It also settles one of §8.1's own worries: relief is not a confound.
>
> **3. The obvious recast — that the governing parameter is the incision budget `K·N` — was tested and
> does not rescue it.** K and the iteration count are not independent (each iteration incises in
> proportion to K), so the first sweep, which varied K at a fixed N = 60, could not tell K from K·N. That
> was tested properly, by varying N and asking whether one budget spent three ways gives one ratio — a
> prediction on data the hypothesis was not formed from, rather than a curve fitted to the data that
> suggested it. It looked convincing at first: 1.068× median within a budget against 1.421× between.
>
> **It does not survive its own saturation check.** Most of that separation came from arms in which the
> solve had *flattened the fixture*. At `K·N = 16.2` the bowl's ratio is **1.000 with 0 % of its relief
> still standing**; at `K·N = 1.8` it is **2.625 with 92 % standing**. A solve that has removed the
> landscape has no structure left for a resolution to disagree about, so its ratio is 1.000 by
> construction — an agreement between two ruins. Restricted to budgets that leave a landscape standing,
> within-budget spread (**1.040×** median) and between-budget spread (**1.138×** median) are comparable
> and the recast explains little.
>
> **What this means for the phase.** §8.1's own fallback is the route: **match the coarse solve's slope
> baseline rather than scale its output.** That is a change to how the coarse stage *measures slope* — over
> a fixed physical distance rather than to its D8 receiver, whose distance is a cell size — and not a
> factor applied to what it produces. It is a bigger change than a stored constant, and it is the one the
> measurement supports.
>
> **What is NOT yet known, and decides whether any of this matters.** Amplification does not need the
> coarse *depth* to be right; it needs the coarse *structure* to be right, because the fine stage then
> re-deepens it. That is gate CJ's correlation criterion, and it has not been run. It is possible that a
> coarse stage with a wrong depth still amplifies correctly — in which case the slope-baseline work is
> unnecessary and the phase gets simpler. **CJ HAS NOW BEEN RUN, and the answer is that the correction IS needed** — for a stronger
> reason than depth. `bench/AmplificationGate.tscn`. The pipeline was built with no correction at all
> (coarse solve at ÷8, upsample the DELTA, refine at full resolution) and compared against a
> single-resolution solve on gate J's statistic. Measured against a per-fixture null — two independent
> solves of the same landform through the identical filter, which is the floor two arms sharing one `z0`
> start from — the margins are **+0.016 (bowl), −0.092 (Y-catchment), −0.044 (demo terrain)** against
> **+0.125 of available headroom**. On two of three fixtures the amplified result agrees with the
> reference *less well than two unrelated solves do*.
>
> **The mechanism is routing, not magnitude.** The coarse stage commits to a drainage network; the fine
> stage does not re-route it, it incises it. So the error is written into the surface and inherited. The
> split sweep shows the direction plainly: the closer a split gets to *not amplifying*, the closer it
> gets to the reference (24/36 → −0.005 at 1.65× cheaper; 48/12 → −0.092 at 4.69×). That refutes
> §8's premise as stated — "structure is chosen early, deepened late" — for THIS solver: the choosing is
> what the coarse grid gets wrong, and later iterations deepen the wrong choice.
>
> **The cost case is real and is not the problem**: 4.69× fewer cell-iterations at the 48/12 split, and
> the pipeline with `coarse_iterations = 0` reproduces the single-resolution solve **bitwise**, so the
> migration path is exact. What is missing is a coarse stage whose channels land where the fine solve's
> would — which is §8.1's slope-baseline correction, now the whole of the remaining work.

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
changes shape** — it does not become a fudge factor fitted to the demo terrain. **Gate CK** is written
to fail in exactly that case. (Earlier drafts of this section said "gate CG" and "gate CF"; those letters
belong to phase 4 — the phase-5 gates are CJ–CN.)

> **A caveat CJ raises for gate J in `PASTURE3D_SIM_NODE_SPEC.md` §6.** J's 0.86–0.91 correlations
> have the same shape as CJ's — preview and build both erode one `z0` — and carry no null. Measured here, two
> *unrelated* solves of one landform correlate **0.875–0.954** through the identical filter. J's verdict
> stands (its high-pass control does discriminate), but its NUMBER should not be read as "88 % of the
> structure agrees": most of it is the shared landform. Any future use of that statistic wants a null.

### 8.2 Node surface

> **CJ HAS RUN AND THESE THREE ARE NOT ENOUGH.** They describe the pipeline, and the pipeline works: it
> is 4.69× cheaper and `coarse_iterations = 0` is bitwise the solve it replaces. What they do not describe
> is the correction the coarse stage needs, which §8.1 now establishes is a change to how that stage
> MEASURES SLOPE — over a fixed physical distance rather than to a D8 receiver whose distance is a cell
> size — and not a knob on this node. Ship none of these until that lands: a fast pipeline that moves the
> channels is worse than no pipeline.

```gdscript
@export_range(1, 16) var coarse_divisor: int = 8
@export_range(0, 200) var coarse_iterations: int = 24   # 0 disables amplification entirely
@export_range(0, 200) var fine_iterations: int = 6
```

`coarse_iterations = 0` runs the single-resolution solve that exists today, which is both the migration
path and gate CJ's control.

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

### 9.4 BUILT (2026-08-20), and what measuring it changed

`connectors/pasture3d_relief_dla.gd`, op id 13, gates CP ✅ CQ ✅ CR ✅ CS ✅
(`bench/DLAGate.tscn`). The `op_fields` mechanism landed as designed: a `PackedFloat32Array` of
concatenated blocks plus an `op_field_meta` stride-3 header `[offset, w, h]` per slot, `_bake_field` /
`_sample_field` on the base material, `relief_sample_field` in C++, and a stack that rebases BOTH the
slot in the op's params and the offsets inside the child's headers. `compile()` went from four elements
to six; `_program()` appends the noise table at the end so every index it already defined still holds.

**Six things about the GROWTH were wrong on the first attempt and only measurement found them.** They
are recorded because each produced a plausible-looking field, and four of the six produced a picture
that would have shipped:

| Symptom | Cause | Fix |
|---|---|---|
| 1 057 nodes at 512², five rounds of nothing | An upscale doubles the cluster AND the grid, so a fixed extent fraction leaves the cluster already at its limit the moment the grid doubles | Ramp the allowed reach per level (0.7 → 1.0); coarse levels decide the trunk inside a smaller disc |
| Growth stopped dead at every level | Hitting the limit broke the particle loop, and a displaced midpoint can push the reach past the ramp's headroom on its own | Reject the one out-of-limit particle instead, and keep filling in behind the envelope |
| The massif never reached its loop | A FLAT particle budget per level. A cluster's cell count scales as r^1.7 while an upscale only doubles its node count, so every round must ADD about what it inherited | `particles` is the count at the FINAL grid; coarser rounds scale by n/res |
| A HOLLOW massif — a ring of ridges round an empty middle, which is a crater | Pure DLA is tip-dominated: a particle launched on the envelope meets the outside first, so once the cluster touches its limit all remaining mass piles into a shell | Alternate: half the particles launch on the envelope, half anywhere inside it |
| One spike, with the branches invisible | Weighting each branch by its SUBTREE MASS. That range spans four decades, so under any remapping the trunk swamps everything | Binary raster. The massing is what the blur stack already does for free — a cell surrounded by dense cluster gets a high value from the wide blurs without being told to |
| Glowing thin lines on black, no massing at all | Summing raw blurred copies. A box blur of a one-cell skeleton divides its amplitude by roughly the radius, far faster than any weight ramp can lift it, so the sum is the NARROWEST blur every time | Renormalise each level to its own peak before weighting, which is also what makes `blur_growth` mean anything |

**The border invariant is exact, not approximate.** Growth reaches `GROW_EXTENT` (0.30) and the blur can
carry material at most `BLUR_SUPPORT` (0.18) further, so the outer 5 % of the field is still zero and a
FIT-mapped DLA fades out inside its own loop instead of stepping at the boundary. When the budget cannot
afford the widest blur level the LEVEL is dropped rather than the radius shrunk — giving up one scale
of massing is better than giving up the invariant.

**Cost**: about 2 s at 512² and 0.5 s at 256², paid once per change to a GROWTH property, not once per
bake. `strength`, `blend`, `selector` and `output_curve` all invalidate the compiled program without
touching a cell of the cluster, so the field is memoised on the growth inputs alone and dragging a
strength slider does not regrow a mountain.

**One finding about A/B parity that is not about DLA.** CR measured the modifier-relief path's residual
as a fixed RELATIVE quantity: ~1e-5 of the relief amplitude, unchanged by the amplitude, by where the
brush sits (x=180 against x=780), or by the field's resolution (512 against 128) — so it is neither
positional round-off nor the field's gradient. A shipped point-evaluated FBM measured the same way sits
at 5e-6, within a factor of 1.67. The consequence for the plugin's 1e-4 m tolerance is that it holds to
roughly **10 m of relief on the modifier path**, on every op, and the DLA is not what breaks it.

### 9.5 What the editor found, and the two controls it produced

Reported after the first day of use: *the DLA does not cover the whole brush, and I was struggling to
increase the area or the size of detail when tuning.* Both true, and the second was the cause of the
first.

**Measured before the fix**: the design ALLOWED an outer radius of 0.96 of the loop's half-extent; the
massif actually reached **0.67**, with 95 % of its mass inside 0.48. The only lever that moved it was
`particles`, and it barely did — **4× the particles bought 0.67 → 0.72** — while changing the texture at
the same time. Two causes, both found by measuring rather than by reading:

1. Half the particles launch inside the cluster to stop it coming out hollow, and that radius was drawn
   **uniformly**, which over-weights the middle by 1/r. Drawing it uniformly over the DISC instead moved
   the mean node radius from 0.23 to 0.30 of the half-extent.
2. The reach was decided by the BUDGET rather than by the design. Growth now runs outward until it
   arrives (capped at 70 % of the level's particles, so an unreachable limit still leaves something to
   fill the middle with) and only then alternates with the interior fill.

**The controls are now `coverage` and `detail_size`, and they are deliberately independent.** The raw
particle count could not be either of them: at a fixed 2 000 it gave a saturated featureless blob at
coverage 0.5 and a spindly wireframe at 0.98. Sizing a mountain must not restyle it. So the count is
DERIVED, and the exponent is not a guess — box-counting a cluster of radius R at branch spacing s gives
(R/s)^1.7 occupied boxes carrying about s cells of branch each, so the cell count goes as R^1.7 × s^-0.7,
and with s = detail_size × R that is **linear in R and detail_size^-0.7**. The first attempt used ^1.7 on
both — the exponent for the cluster's MASS, not for the budget that builds it — and starved the coarse
end visibly: at detail 0.30 the cluster arrived at 71 % of its allowed radius.

**The blur is reserved, not deducted.** Taking the blur's share out of the cluster's reach coupled the
two controls straight back together: mass sits where the CLUSTER is (a blur redistributes it, it does not
carry it far), so a coarse Detail Size shrank the mountain by 26 %. The cluster's reach is now a function
of `coverage` alone and the blur spends its width INSIDE a reserved margin — which is also what keeps the
border exactly zero. Gate CX holds all three claims.

**And one control that did nothing at all.** `Pasture3DReliefMaterial.blend` was reported as having no
effect. Measured across all six modes: it works on a non-first layer of a `Pasture3DReliefStack`, and is
**byte-identical output** everywhere else — on a material assigned to a `Pasture3DModRelief`, a Mound or a
Plow, and on a stack's own top-level blend. A host evaluates one material into an accumulator that starts
at 0 and adds the result; nothing reads the property. It is now hidden where it cannot act, under
`Pasture3DBrushModifier`'s existing rule for `Evaluation` — *shipping a control that silently does nothing
is worse than not shipping it* — and a stack now warns about the mirror-image trap, a first layer set to
Mul or Min blending against a zero accumulator.

---

## 10. Build order

| Phase | Contents | Gates | Depends on |
|---|---|---|---|
| **1 — BUILT** | Host profile field; `field_source` on the selector; band source on `TERRACE`/`STRATIFY`; the measured divisor | BM–BQ ✅ | nothing |
| **2 — BUILT** | Yuan 2019 deposition in `erosion_solve`; `deposition` on the node; the sweep cap, its report and its warning | BR–BU ✅, BV deferred | nothing |
| **3a — BUILT** | The modifier stack; `Pasture3DModNoise` / `ModRelief` / `ModSmooth`; the Mound legacy properties deleted and migrated | BW ✅, BZ ✅ | nothing |
| **3b — BUILT** | `Pasture3DModErosion`; the field context later selectors read; Live/Frozen and frozen-cache staleness | BX ✅, BY ✅, CA–CE ✅ | 1, 2, 3a |
| **4 — BUILT** | The manager registry; `Bake All Brushes`; `Register Eroding Brushes`; stale-path warnings | CF ✅, CG ✅, CH ✅, CW ✅ | 3b |
| **5 — BLOCKED** | Both measurements are done and both came back negative: CK rejected the planned depth correction, CJ showed the uncorrected pipeline mis-routes. The pipeline itself is built and cheap; what remains is §8.1's slope-baseline correction to the coarse stage, which is a solver change | CK ✅, CJ ✅ | 2, 3b |
| **6 — BUILT** | `Pasture3DReliefDLA` as a baked field op; the `op_fields` / `op_field_meta` wire block and its stack splicing; the Plow's Tile warning generalised from a CRATER test to a loop-sized-op test | CP ✅, CQ ✅, CR ✅, CS ✅, CX ✅ | 1 (to multiply by the host profile) |

**Phases 1 and 6 were independent of the erosion chain**, and both were taken before it was finished:
phase 6 landed while phase 5 sat blocked on a solver change, and needed nothing from it. **Phase 5 is
now the only outstanding work in this spec.**

**Phase 3 does not reach the km case without phase 5.** It is testable and useful at a few hundred metres,
and phase 5 is what lifts it to the stated 2–3 km target. Anyone reading this order as "phase 3 ships the
mountain" has read it wrong.

---

## 11. Gates

Same discipline as the rest of the repo: **every criterion needs a control that fails**, and each must be
able to tell "measured nothing" from "measured correctly". Letters run **BM onward** — A–Z, AA–AZ and
BA–BV are consumed, and the rule of taking the free letters rather than the next ones is the one §14 of
the Sim spec already established.

> **Phases 4–6's letters were shifted once, on 2026-08-20, when phase 3 split into 3a and 3b.** That is
> normally forbidden — §14 of the Sim spec refuses it precisely because code comments cite gate letters.
> It was allowed exactly here because **nothing referencing CC onward existed yet**: those phases are
> unbuilt, uncommented and unreferenced outside this table. Once any of them ships, the letters freeze.

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
| BW ✅ | *(3a)* **The stack bakes bitwise what the hard-coded pipeline bakes.** A Mound whose stack is `Noise → Relief → Smooth` reproduces the legacy `noise` + `relief` + `smooth_passes` bake to the BYTE, across every shipped preset in `demo/data/relief/`. This is the whole of 3a's claim. **Measured 2026-08-20: 12 of 12 cases identical over 2401 probes** (§6.5), then the legacy path was deleted, so the criterion is historical and the suite now asserts what outlives it — native vs GDScript parity (the stack adds −0.000004 m), every preset still stamps, and re-baking is bitwise stable. | Reorder the stack, which must **differ** — otherwise the order is not being honoured and "bitwise identical" is measuring a stack that ignores its own contents. **The proposed `Relief → Noise → Smooth` does not discriminate** (both are additive point operators in one run); the reorder that does is `Noise → Smooth → Relief`, moving the FIELD operator — it moved the bake 2.41 m. Plus a disabled modifier, which read bitwise identical to removing it and 3.27 m away from leaving it in. |
| BX ✅ | *(3b)* **A modifier reads only what precedes it.** A Relief modifier gated on a field the stack does not produce until later reads that field's **defined zero** — not the value, and not a stale one from the previous bake. **Measured: the same two modifiers bake 3.1 m apart by ORDER alone.** Positional by construction, in the end: the erosion step publishes at its own place in the list, so a modifier above it has already run against the zero and nothing has to enforce the invariant. | With `publish_fields` off the two orders came back **0.000 m** apart — so the gap above is the field context and not the ordering effect the stack already had in 3a. |
| BY ✅ | *(3b)* **Frozen is a cache, not a different answer.** A Frozen modifier, freshly baked, produces bitwise what the same modifier produces Live. **Measured: bitwise identical, holding 0.06 MB.** | Change something upstream: doubling the relief under it moved Live **46.7 m** and Frozen **0.000 m**, and the brush reported the modifier stale. Then Bake Erosion brought it to **0.0000 m** of the Live answer with the warning gone — a freeze that silently keeps up is not a freeze, and one that cannot be recovered is worse. |
| BZ ✅ | *(3a)* **The legacy properties are gone from `Pasture3DMound`,** and every converted scene and suite still bakes what it did — `MoundReliefCheck` and `HostProfileGate` re-ran at 0 failures against stacks instead of properties. Extended during the build with the two things deletion actually risks: a pre-3a scene's properties **migrate** into a stack that bakes bitwise what a hand-built one bakes (§6.6), and the stack **round-trips through a saved scene** — `modifiers` is not an `@export`, and one that stopped persisting would take every modifier the artist authored with it. | `PlowReliefCheck` and the five Plow-driven Sim suites, which passed **untouched** — they are the control on the blast radius being Mound-only (§6.6). If they had needed editing, the cut was wrong. Plus a node that already declares `modifiers`, which must keep it rather than be overwritten by stale legacy keys. |
| CA ✅ | *(3b)* **A brush-hosted erosion modifier erodes, and the cut depends on where the water goes.** **Measured: mean cut 33.6 m with the drainage-area term against 9.3 m without it (3.6x).** The spec asked for "concentrated in channels"; that was measured and is FALSE of the height delta at this scale — top-decile share and connectivity both refuse to separate a routed solve from an unrouted one, and the decile share INVERTS, because slope-only erosion eats the crags and crags are peakier than channels. The heavy tail is in the drainage field, where CC measures it. See `bench/BrushErosionProbe.tscn`. | `area_exponent = 0` — same solver, same water, same iterations, with only "how much drains through here" stopped counting. Plus the modifier disabled, which reproduced the un-eroded bake **bitwise**. |
| CB ✅ | *(3b)* **The delta written is `eroded − base_below`.** **Measured through one site with two base references**, not two sites: `relative_to_terrain` changes only what the dome is measured FROM, so under ADD the stored delta is identical either way — and the two bakes came back **bitwise identical with erosion off and 63.2 m apart with it on**, which is the solver seeing the composite. (Two different SITES cannot work: the demo terrain already carries baked content and they do not start equal. And a flat site cannot work either: stream power is invariant to a CONSTANT offset.) | The erosion-off comparison is the control, and it must be exact. |
| CC ✅ | *(3b)* **A later modifier reads the erosion modifier's fields with no `SimResult` anywhere.** **Measured: flow-gated detail lands on 7% of the loop**, with `sim_result` null on every selector. **This is the workflow the phase exists for.** The band was calibrated, not guessed — the field tops out near 600 m² with a 90th percentile of 46, and the first draft asked for 2000 m² and measured 0%. | `publish_fields = false` took the same gate to **0%**. The selector's `strength = 0` took it to **78%** — not 100% because the interior profile fades the relief out toward the rim — so "nothing appeared" and "the field is missing" cannot be confused. |
| CD ✅ | *(3b)* **The no-margin claim holds (§6.8).** Measured SYNTHETICALLY, through `erode_heightfield` directly rather than by driving a `Pasture3DSim` — the Sim would add its own grid resampling and its own chunked solve, and a number that could come from any of three places is not evidence about one of them. The same landform is solved twice: once in its own box with NaN outside, exactly as the brush hands it over, and once in a box expanded by half a loop on every side with the real surface everywhere, then cropped back. **A self-draining dome's core changed by 1.4% of its own cut.** | The case the reasoning does NOT cover: the same footprint placed below a 300 m hill, so a real catchment drains through it. **42.3%** — the gate is sensitive to a missing margin by a factor of thirty, which is what makes the 1.4% mean something. |
| CE ✅ | *(3b)* **Idempotent and deterministic.** Three bakes of a stack with a flow-gated modifier downstream of the erosion — the configuration most able to feed itself — came back **bitwise identical**. | One extra solver iteration moved the bake **2.2 m**, so the probe can see a change and "identical" is evidence rather than a dead measurement. |
| CF ✅ | *(4)* **Bake All bakes exactly the registered set.** Two registered brushes, made stale by a change to the shape under them, moved **50.0 m** and **30.7 m**; an unregistered one made stale the same way came back **bitwise identical**. **In list order is measured on the PLAN, not on the surface** — Bake All is a loop and not a chain, so no ordering of independent bakes produces a different landscape and a height statistic claiming to test order would be testing nothing. Reversing the list reverses the work. | Three, because "identical" has three ways of being vacuous. The unregistered brush deliberately **shares a layer** with a registered one, so it genuinely IS re-stamped — clearing the layer would otherwise wipe it — and only its frozen cache keeps it unchanged; clearing that cache by hand and repainting the same layer moves it **73.7 m**, so the probe can see that site. All three brushes must first report themselves **stale**, or nothing needed re-solving. And the bake that makes them stale must leave the heights **bitwise identical**, or the freeze is not holding. Removing the cache clear from Bake All fails **5 criteria across 3 gates**; making the manager scan instead of read the list fails CF's headline. |
| CG ✅ | *(4)* **A stale path warns, names itself, and costs exactly itself.** After deleting a registered brush, the registry raises **1 warning containing the path**, and the run still bakes **1 of 1** with the survivor moving **50.0 m** — the dead entry is not counted as a brush to bake. | The same list with every path valid, which warns **0 times**. Silently dropping the stale entry fails only CG. |
| CH ✅ | *(4)* **One undo restores everything.** A run over two layers registers **1 action carrying 2 layers**, and applying that action's own inverse restored both **bitwise**. Exercised through the inverse rather than the editor: `EditorUndoRedoManager` does not exist headless, and the action is built from a list of `_restore_owner(owner, snapshot)` pairs that the report hands back, so the gate calls exactly what Ctrl+Z would. The action list is returned as data so its SHAPE is measurable — one action per layer would still restore correctly and is still wrong. | Cancel mid-run, driven through the interactive path: **cancelled after 1 of 2**, the layer it reached moved **60.0 m**, the layer it never reached moved **0.000 m**, and the node carries the partial count as a configuration warning rather than only in the Output log. Ignoring the cancel flag fails 3 criteria; one action per layer fails only the shape criterion. |
| CW ✅ | *(4)* **Register Eroding Brushes discovers without making membership implicit.** Scanning an empty list registered **6 of the 6** brushes in the scene carrying an enabled erosion modifier. The expected set is computed by the gate's own walk over its own fixtures — a gate that asked `erosion_modifiers()` which brushes were eroding would agree with a broken one as readily as a working one. | The two ways a brush must fail to qualify, both present: no erosion modifier, and one whose modifier is **disabled**. Plus the manager itself, which must not register itself. Pressing it twice must add **0**. And starting from a hand-made list of 1, the scan must **grow it to 6 leaving entry 0 where it was** — a scan that replaced would silently discard an order the artist chose, which is the whole difference between discovery and implicit membership. Replacing instead of appending fails 1 criterion; ignoring `enabled` fails 4. |
| CJ ✅ | *(5)* **RUN, and it says the correction IS needed.** The pipeline was built uncorrected (coarse at ÷8, upsample the DELTA so the fine terrain's own detail survives, refine at full resolution) and compared against a single-resolution solve on gate J's statistic. **Measured against a per-fixture NULL**, because both arms erode one `z0` and their low-passed deltas therefore share the landform: two independent solves of the same landform correlate **0.875–0.954** through the identical filter, so a raw 0.86 is below chance. Margins over that null: **+0.016 bowl, −0.092 Y-catchment, −0.044 demo**, against **+0.125 of headroom**. Two of three fixtures agree with the reference LESS than unrelated solves do. The mechanism is ROUTING: the coarse stage commits to a drainage network and the fine stage incises rather than re-routes it, so the split sweep runs the wrong way — 24/36 → −0.005 at 1.65× cheaper against 48/12 → −0.092 at 4.69×. That refutes §8's "structure is chosen early, deepened late" for this solver. Asserted as the measured finding (as CK is), so it FAILS the day the slope-baseline correction makes it work. | Three. **Headroom**: a perfect arm scores 1.000 against the 0.875 null, so +0.125 is winnable and "no margin" is not "nowhere to go". **`coarse_iterations = 0`**, which must be the single-resolution solve **bitwise** — asserted bitwise rather than by correlation, since a pipeline that resampled and added a near-zero delta would correlate 1.000 while moving every cell, and every authored scene would shift on its first re-bake. **Cost**, in cell-iterations rather than seconds: 4.69×, exact and machine-independent, where a stopwatch reading taken while the machine is busy would not be evidence. |
| CK ✅ | *(5)* **The planned correction is REJECTED, and this gate is where that is recorded.** 8.1 asked whether the depth ratio is a function of the divisor alone; it is not. The divisor explains **10.2 %** of the variance in ln(ratio) against **3.4 %** for shuffled labels (22.0 % vs 5.3 % excluding flattened fixtures), and as two spreads: the mean ratio moves **1.26x** across divisors while **`erosion_rate` alone moves it 2.07x at a fixed divisor**. The incision-budget recast `K·N` was tested as a prediction on new data and does not rescue it: its apparent collapse came from arms the solve had FLATTENED, and at `K·N = 16.2` the bowl reads **ratio 1.000 with 0 % of its relief standing** against **2.625 with 92 % standing** at 1.8. Restricted to live budgets, within (1.040x) and between (1.138x) are comparable. `bench/ResolutionCalibrationProbe.tscn` is the 144-point sweep. | **Relief invariance is the harness's positive control, and it is analytic rather than empirical**: linear stream power is homogeneous in z, so the ratio must cancel exactly under a relief rescale — measured **1.0037x**, which no misaligned upsample or mis-set boundary could produce, so it is checked first. Plus a floor: the divisor must move the ratio by at least 1.15x, or rate-beats-divisor is a comparison between two nothings. Plus the flattened arm's relief-left condition, without which its ratio of 1.000 would be genuine agreement and the recast would still be alive. Neutering the divisor so every ratio is 1.000 fires two of the three. |
| CL | *(5)* **The constant is stored, not printed.** The factor used is serialised on the brush and on any result written, and a bake reloaded from disk reproduces its surface without re-deriving it. | Clear the stored value and re-bake, which must produce a *different* surface — otherwise nothing is reading it and storing it is theatre. |
| CM | *(5)* **The km case completes in budget.** A 3 km × 2 km mound at the terrain's spacing bakes within a stated wall-clock target. **Perf gate — needs the user's go-ahead before running.** | The same case with `coarse_iterations = 0`, which must be dramatically slower — the number this phase exists to move. |
| CN | *(5)* **Amplified output is still hydrologically coherent.** The router on the amplified surface is a valid forest with no pits — gate A's criterion, re-run on the new path. | The upsample without the fine iterations, which must leave interpolation artefacts the forest test detects. |
| CP ✅ | *(6)* **RUN.** Two separate instances at seed 7 grow **bitwise identical** fields; seed 8 moves the surface by 0.30 of full height. Measured on separate INSTANCES on purpose — the material memoises its field on the growth inputs, so compiling one instance twice would compare a cache against itself and pass whatever the growth code did. | The spec's, and it runs through `_grow` / `_rasterise` / `_mass` rather than through some other path that happens to differ: the same growth code on a clock-seeded RNG, twice, which differs by 0.36. Plus the field must not be FLAT — two empty grids are bitwise identical too. |
| CQ ✅ | *(6)* **RUN, and it needed TWO statistics.** No single scalar separates a DLA from both plausible nulls, and finding that out is most of this gate's history. **Network share** (the largest connected component's share of a fixed-AREA superlevel set) reads **1.00**; **branch count** (the most pieces the superlevel set ever breaks into as the threshold sweeps down — one per crest, before the flanks join them up) reads **9**. Dendritic is the CONJUNCTION. Thresholding by quantile rather than by height is what makes the arms comparable: both sets then have the same area by construction, so a difference in pieces is a difference in shape. | Two, each REQUIRED TO FAIL THE HALF IT EXISTS FOR. The spec's null — white noise through the identical blur stack — scores **0.070** on share (fails) but **856** branches, so it cannot police the branch count. A smooth CONE scores **1.00** on share but **1** branch (fails), so it cannot police the share. Neither null passes both, which is the point. |
| CR ✅ | *(6)* **RUN.** There is only ONE implementation, so the claim under test is not "the two agree" but "the two READERS index the same block the same way" — a rebased slot, a transposed row order, an off-by-one in the bilinear weights all live entirely in the sampling and would survive the argument that makes parity free. At an ordinary 8 m relief the DLA's own contribution to the C++/GDScript gap is **9.2e-5 m**, inside the 1e-4 tolerance. Baseline-first, as gate BQ does it, because the Mound's dome term carries a pre-existing divergence. | Three. The spec's: the oracle pointed at a **128²** field against a **512²** native bake, which reads **5.85 m** apart — two readers that both silently returned zero would otherwise pass. The fixture must MOVE the ground (7.87 m). And a **reference op**: at 32 m, where the absolute tolerance no longer discriminates, the DLA's residual is 9.5e-6 of amplitude against a shipped FBM's 5.7e-6 — **1.67×**, the same order, which is what says the residual is shared float32 rounding rather than the sampling. See §9.4. |
| CT ✅ | *(3a fix)* **Editing a value never rebuilds the inspector.** Ten value edits across three modifier kinds — including Strength swept across 0, which is where the defect lived — caused **0 rebuilds**, counted on `property_list_changed` itself rather than on a proxy for it. | Structural edits, which must rebuild or "0" is a dead measurement: clearing the Relief Material rebuilt **1**, reassigning **1**, adding a stack layer **1**. Plus a HEIGHT delta, because decoupling the preview dropdown from `is_active()` could plausibly have reached the bake: a zero-strength Relief modifier bakes **bitwise** what no Relief modifier bakes, while the same modifier at 8 m moves the same probes **45.6 m**. Against the pre-fix code the criterion reads **5 rebuilds**. |
| CU ✅ | *(3a fix)* **Renaming never rebuilds the inspector, at either level.** Typed one character at a time, which is the only way to catch a guard that holds for a whole string: naming a modifier and naming a relief stack LAYER both cost **0 rebuilds over 7 keystrokes**. | The names must land, or the guard is being credited for a no-op — the modifier reads `Hardpan` and the dropdown reads `Layer 0 (Hardpan)`. Plus structure, which must still rebuild: swapping a layer's class **1**, giving it a Selector **1**. Against the pre-fix code the layer rename reads **7 rebuilds, the first after 'H'** — and the label-based trigger it replaced also missed the Selector control entirely. |
| CV ✅ | *(3a fix)* **The same rule, in the one other place the plugin broke it.** `Pasture3DWaterBody` re-hinted its wave-profile dropdown on `profiles_changed`, which the manager emits for every knob on every profile. Three amplitude edits now cost **0 rebuilds**. Lives in this suite because the water suites need a real rendering device and cannot run headless at all. | Two counters, not one: the manager's **3 emissions** are what separate "did not rebuild" from "was never asked". Plus the edits that MUST re-hint — renaming a profile **1**, adding one **1** — and the dropdown itself, which must still list every live profile. The stronger observable also caught a **cold-start rebuild**: the name cache is now primed where the signal is connected. Against the pre-fix code: **3 rebuilds**. |
| CS ✅ | *(6)* **RUN.** A DLA material under `Mapping = TILE` raises the loop-sized warning, in the same words `CRATER` already used. The predicate generalised from a CRATER test to a loop-sized-op test, so the gate holds BOTH halves of that change: the new material must warn and the old one must still warn. Matched on the sentence an artist reads, not on the predicate. | The spec's `FIT`, which must not warn — a predicate returning true unconditionally would pass every positive assertion here. Plus a FRACTAL, which tiles correctly and must not be warned about under either mapping. |
| CX ✅ | *(6)* **From the editor, not from the spec.** The massif reached 0.67 of a loop it was allowed 0.96 of, and `particles` — the only lever that moved it — bought 0.05 for 4× the cost while restyling the mountain on the way. Three claims now: it **ARRIVES** (99–100 % of its allowed radius at every setting), `coverage` **RESIZES** (0.50 → 0.98 grows the field **1.93×** against coverage's own 1.96×), and `detail_size` **RESTYLES WITHOUT RESIZING** (**8 %** of size drift while the branch count moves **4.8×**). Radius measured as the r98 of the mass, not as a threshold — the fringe of a blurred dendrite is faint and a threshold reads back whatever level you picked. | The border ring must be **EXACTLY zero** at all five settings. That is the invariant the whole derivation exists to protect and the first thing to break if it drifts — a massif clipped by the field's edge steps at the loop boundary on every FIT-mapped brush. Plus the "measured nothing" guard: a FLAT field would sail through the no-resize claim by never changing size at all. |

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
5. **Does an eroded Mound want its own `Pasture3DSimResult`?** §6.8 writes no separate layer, so there is
   nothing to key relief off — a `FLOW`-gated scree material on the mountain it was just eroded from is
   not expressible. The four channels exist during the solve and are discarded. Storing them costs four
   float grids per brush and §21.3's argument about what a result may honestly describe applies here
   unchanged: for a single brush over a single grid, all four channels *are* attributable, so unlike the
   pass case there is no half-lie. Probably wanted; deliberately not specced until §6 has been used.
6. ~~**What `Clear Erosion` should mean on a brush that has been edited since.**~~ **Dissolved by §6.9's
   reshape**: a frozen modifier goes STALE on an upstream edit rather than clearing, so there is no
   clear-on-edit button to be confused about. Staleness is reported and recoverable; the first draft's
   clearing was neither.

---

## 13. Sources

- Braun & Willett 2013 — the O(n) implicit stream-power scheme the solver already uses.
- Barnes et al. 2014 — priority-flood, and the `+epsilon` variant `zf_route` depends on.
- [Yuan et al. 2019, *A New Efficient Method to Solve the Stream Power Law Model Taking Into Account Sediment Deposition*](https://agupubs.onlinelibrary.wiley.com/doi/full/10.1029/2018JF004867) — phase 2. O(N), implicit, Gauss–Seidel upstream; **convergence degrades toward the transport-limited end**, which §5 designs around.
- [Schott et al. 2023, *Large-scale Terrain Authoring through Interactive Erosion Simulation*](https://dl.acm.org/doi/10.1145/3592787) — the uplift domain (§12.1). Code: [H-Schott/StreamPowerErosion](https://github.com/H-Schott/StreamPowerErosion).
- [Schott et al. 2024, *Terrain Amplification using Multi-Scale Erosion*](https://dl.acm.org/doi/10.1145/3658200) — phase 5's approach.
- [Jain et al. 2024, *FastFlow: GPU Acceleration of Flow and Depression Routing*](https://onlinelibrary.wiley.com/doi/10.1111/cgf.15243) — §12.2's deferred GPU lever.
- [Diffusion-limited aggregation](https://en.wikipedia.org/wiki/Diffusion-limited_aggregation), and the [heightmap recipe](http://voxels.blogspot.com/2014/01/procedural-terrain-heightmap-generation.html) phase 6 follows.
