# Pasture3D Plow Relief Material Spec (`Pasture3DReliefMaterial`)

**Status:** **PHASES 1 AND 2 IMPLEMENTED 2026-08-08.**
Phase 1 (user-verified in-editor): base class + wire format, ops `CONST`/`FBM`/`RIDGED`/`BILLOW`/`WARP`/
`CRATER`, the `Fractal`/`Crater`/`Stack` materials, `TILE`/`FIT` mapping with loop orientation, the C++
evaluator, and the placement-default hook.
Phase 2 (user-verified in-editor): ops `DUNES`/`FURROWS`/`TERRACE`/`STRATIFY`/`CLAMP`/`CURVE`, the
`Dunes`/`Furrows`/`Terraces`/`Strata` materials, `SCATTER` mapping, `output_curve` on the base, FIT for
the `TEXTURE`/`MATERIAL` sources, eight presets in `demo/data/relief/`, and the resolution guard in §5.1.
Phase 3 (headless-verified only): the selector table, `Pasture3DReliefSelector` (slope / altitude /
curvature), terrain fields derived from the below-layer heights, the `SCREE` op and
`Pasture3DReliefScree`, and two more presets.
All fourteen gates in §13 pass headless (`bench/PlowReliefCheck.tscn`), including exact native↔GDScript
parity and **zero re-bake drift with a slope-gated material** — the property §7 exists to guarantee.
All three phases are now built. Target: Godot 4.7, Pasture3D `main`.

**Authoring guide:** [PASTURE3D_RELIEF_MATERIALS_GUIDE.md](PASTURE3D_RELIEF_MATERIALS_GUIDE.md) — setup,
every setting, tuning order, and a symptom→cause table. That is the document to read to *use* this; this
one explains why it is built the way it is.

**Goal:** modular, saveable "dynamic materials" for `Pasture3DPlow` that add *landform* detail — craggy
sections, strata, dunes, furrows, and **individually placed craters** — with live re-bake in the editor.

**Scope boundary:** landform detail only. Detail finer than ~2 × `vertex_spacing` (default `1.0` m,
[pasture_3d.h:94](src/pasture_3d.h:94)) cannot be expressed in the height map and belongs to the terrain
surface shader. That track is explicitly **out of scope here**.

**Builds on:** [plow.gd](project/addons/pasture_3d/connectors/plow.gd),
[plow_material.gd](project/addons/pasture_3d/connectors/plow_material.gd),
`Pasture3DData::stamp_plow_loop` ([pasture_3d_brush_raster.cpp:1125](src/pasture_3d_brush_raster.cpp:1125)),
and the base [terrain_brush.gd](project/addons/pasture_3d/connectors/terrain_brush.gd).
Supersedes nothing — it *adds* a fourth source alongside the existing three.

---

## 1. Decisions (from the design interview, 2026-08-07)

| Question | Decision | Consequence for this spec |
|---|---|---|
| Detail scope | **Landform only** | No shader/normal-map work. Everything lands in the height map at `vertex_spacing`. |
| Engine rebuild | **Acceptable** | The op program is evaluated in C++; the native + GPU-field fast path is preserved. |
| Relationship to existing sources | **Sits alongside; new material becomes the default** | `Source` gains `RELIEF = 3`. `NOISE`/`TEXTURE`/`MATERIAL` and `Pasture3DPlowMaterial` are **untouched**. See the default-change hazard in §11. |
| Extensibility | **New specialised materials added later without C++ changes** | Materials compile to a flat **op program** over a fixed op catalogue; new materials are new GDScript resources that emit existing ops. A material needing a genuinely new primitive adds one op to §5. |
| Terrain-aware selectors (slope/altitude/curvature) | **Designed in now, built in phase 3** | The op header reserves a `selector_id` field; the selector table ships empty in phases 1–2. |
| Default-source migration | **Declared default stays `NOISE`; the placement tool sets `RELIEF` explicitly on newly created nodes** (user, 2026-08-07) | Existing scenes are untouched *by construction* — no version int, no load-time migration. One hook, in `_instantiate_placement_brush()`. See §11. |
| Simulation (`Pasture3DSim`) | **Separate spec, built last** | Must produce artifacts that satisfy this contract, so it needs no plow-side plumbing. Not specified here. |

---

## 2. What stays identical (the interface contract)

1. **The orchestration is untouched.** `_refresh_owner_rect`, dirty-rect clipping, `clear_layer_in_area`,
   surface-snap, `_defer_composite` + one `composite_area`, undo, layer sharing — all unchanged.
2. **The call site keeps its shape.** `_paint_spline` still calls
   `terrain.data.stamp_plow_loop(_layer_id, poly, _clip_aabb, params, lut, data)`. The new source rides in
   the existing `params` Dictionary plus two new packed arrays; **no new bound method.**
3. **The existing three sources behave bit-identically.** `NOISE`, `TEXTURE`, `MATERIAL` take the same code
   path they do today. Regression gate in §13.
4. **The GDScript fallback stays an exact A/B oracle.** As with `_blur_grid`/`nan_blur` and `_ramp`/
   `raster_ramp`, every op is implemented **twice** and must agree. `force_gdscript_raster` selects the
   reference path.

---

## 3. Class model

```
Pasture3DReliefMaterial          (Resource, abstract base — the contract)
├── Pasture3DReliefFractal       phase 1   fBm / ridged / billow + domain warp
├── Pasture3DReliefCrater        phase 1   single crater or crater field
├── Pasture3DReliefStrata        phase 2   tilted, broken rock layers
├── Pasture3DReliefTerraces      phase 2   fractal terraces
├── Pasture3DReliefDunes         phase 2   directional, asymmetric crests
├── Pasture3DReliefFurrows       phase 2   plough rows / field corrugation
├── Pasture3DReliefScree         phase 3   slope-gated talus (needs selectors)
└── Pasture3DReliefStack         phase 1   ordered list of children + per-child blend
```

`Pasture3DPlowMaterial` is **not** touched, **not** reparented, and **not** deprecated. `plow_noise.tres`
and any user `.tres` built on it keep working.

### 3.1 The base class

```gdscript
@tool class_name Pasture3DReliefMaterial extends Resource

## Multiplier on top of the brush's Height Scale, so a saved material carries its own intensity.
@export_range(0.0, 4.0, 0.01, "or_greater") var strength: float = 1.0

## Compile to the flat op program (§4). Cached; invalidated by emit_changed().
func compile() -> Array          # -> [PackedInt32Array ops, PackedFloat32Array params]

## Subclasses override this. Append ops via the _op() helper; call children for composites.
func _build(_out: Array) -> void: pass

## Does this material predominantly RAISE the ground? Drives the Add Water button's raise check
## (see PASTURE3D_WATER_BODIES_SPEC.md §7.8 and _raise_inverted below). Craters override to false.
func _raises() -> bool: return true

## Human-readable one-liner for the plow's configuration warnings when the material is misconfigured.
func _configuration_warning() -> String: return ""
```

Every exported property setter calls `emit_changed()`, which the plow is **already** wired to
([plow.gd:44](project/addons/pasture_3d/connectors/plow.gd:44)) — live re-bake comes free.

**Compile caching:** `compile()` memoises into `_program` and clears it on `emit_changed()`. The plow calls
it **once per `_paint_spline`**, never per cell.

---

## 4. The op program (the wire format)

A material compiles to an **ordered layer list**, not a scripting language: no branches, no loops, no jumps.
Each entry is one op with a fixed-size parameter block, evaluated in order.

### 4.1 Encoding

```
ops    : PackedInt32Array,   stride 4,  entry i at i*4
  [0] op_type      see §5
  [1] blend        0=ADD 1=SUB 2=MUL 3=MAX 4=MIN 5=REPLACE
  [2] selector_id  index into the selector table, or -1 for none   (RESERVED — phase 3)
  [3] flags        bit0 = negate output, bit1 = clamp acc to [-1,1] after blend

params : PackedFloat32Array, stride 12, entry i at i*12
  meaning is per-op, documented in §5. Unused slots are 0.
```

Stride 12 comfortably covers the widest op in §5 (8 used slots). Fixed stride means no offset table and
trivial indexing on both sides. A material with 6 ops costs 24 ints + 72 floats — negligible to build,
marshal, and cache.

### 4.2 Evaluation state

Per cell the evaluator carries:

| Symbol | Meaning |
|---|---|
| `u, v` | Sample position in **metres**. The current domain — `DOMAIN` ops rewrite it. |
| `nu, nv` | Same position normalised to the mapping frame's extents, in `[-1, 1]`. Radial ops use this. |
| `acc` | Signed accumulator, nominally `[-1, 1]`. |

Keeping `u,v` in metres in *every* mapping mode means an op's `frequency` always reads as **cycles per
metre** — it does not silently change meaning between TILE and FIT. `nu,nv` exists so radial ops (CRATER)
can be sized by the loop rather than by an absolute frequency.

### 4.3 Op categories

| Category | Effect | Ops |
|---|---|---|
| `GENERATOR` | computes a value and **blends it into `acc`** using the entry's blend mode | FBM, RIDGED, BILLOW, DUNES, FURROWS, CRATER, SCREE, CONST |
| `DOMAIN` | rewrites `u,v` (and `nu,nv`) for **all subsequent ops**; does not touch `acc` | WARP |
| `PROFILE` | remaps `acc` in place; ignores its blend mode | TERRACE, STRATIFY, CLAMP, CURVE |

### 4.4 Output convention

The program yields a **signed** value, nominally `[-1, 1]`. The plow applies:

```
amp = height_scale * acc * mask * material.strength
```

Note the difference from the existing sources: there is **no `height_offset` subtraction**. The existing
sources normalise to `[0,1]` and lean on `height_offset = 0.5` to recover a signed value
([plow.gd:236](project/addons/pasture_3d/connectors/plow.gd:236)). `RELIEF` is signed natively, so
`height_offset` is hidden for this source (§8).

`acc` is **not** hard-clamped by default — a stack that overshoots `[-1,1]` is legal and sometimes wanted.
Set `flags` bit1 on an op to clamp at that point.

### 4.5 Why a program rather than one C++ class per material

- Stacking is a first-class requirement, and a stack is exactly an ordered op list.
- New materials (phases 2–3 and anything you add later) are pure GDScript — they emit existing ops.
- One evaluator to optimise, one to keep in A/B parity with GDScript.
- No per-cell GDScript callbacks, which is the property the whole Round 2 native path exists to preserve.

---

## 5. Op catalogue v1

`P` = the entry's param block base index. Amplitude is always `P[0]`.

### GENERATOR

| id | op | params |
|---|---|---|
| 0 | `CONST` | `P0` value |
| 1 | `FBM` | `P0` amplitude, `P1` frequency (cycles/m), `P2` octaves, `P3` lacunarity, `P4` gain, `P5` seed |
| 2 | `RIDGED` | as FBM, plus `P6` sharpness |
| 3 | `BILLOW` | as FBM |
| 4 | `DUNES` | `P0` amplitude, `P1` wavelength (m), `P2` direction (rad), `P3` asymmetry, `P4` crest sharpness, `P5` wander frequency, `P6` wander amount, `P7` seed |
| 5 | `FURROWS` | `P0` amplitude, `P1` spacing (m), `P2` direction (rad), `P3` profile (0=V 1=U 2=square), `P4` wobble frequency, `P5` wobble amount, `P6` seed |
| 6 | `CRATER` | `P0` amplitude, `P1` floor depth, `P2` rim height, `P3` rim width (0–1 of radius), `P4` ejecta falloff, `P5` floor flatness, `P6` terrace steps, `P7` seed — **reserved and unused in phase 1**; the crater profile is fully deterministic, and break-up comes from stacking a fractal over it. Phase 2 spends it on rim wobble. |
| 7 | `SCREE` | `P0` amplitude, `P1` grain frequency, `P2` downslope streak (m), `P3` toe deposition, `P4` seed. Grain sampled at a point offset **downhill along the height gradient**, plus deposition proportional to positive curvature. `Pasture3DReliefScree` emits its own slope selector so it works out of the box. |

### DOMAIN

| id | op | params |
|---|---|---|
| 8 | `WARP` | `P0` amplitude (m), `P1` frequency, `P2` octaves, `P3` seed |

### PROFILE

| id | op | params |
|---|---|---|
| 9 | `TERRACE` | `P0` steps, `P1` sharpness, `P2` step jitter, `P3` seed, `P4` jitter frequency — **added during implementation**: the jitter is a noise field and needs a length scale, which the original param list omitted |
| 10 | `STRATIFY` | `P0` steps, `P1` hardness, `P2` dip angle (rad), `P3` dip direction (rad), `P4` break frequency, `P5` break amount, `P6` seed |
| 11 | `CLAMP` | `P0` min, `P1` max |
| 12 | `CURVE` | `P0` LUT slot index — remaps `acc` through a 256-entry LUT (§4 extra array, see §9.2) |

**`CURVE`'s user surface is `output_curve` on the base class.** Any material can carry one; `compile()`
emits it as a trailing op so it shapes the finished relief. Because PROFILE ops remap the *whole*
accumulator, an `output_curve` on a stack **layer** shapes everything accumulated up to and including that
layer, not that layer alone — documented on the property, and useful once understood.

**`TERRACE` and `STRATIFY` are PROFILE ops, so a material built only from one would remap an accumulator
that is still 0** — a constant, and a footgun. `Pasture3DReliefTerraces` and `Pasture3DReliefStrata`
therefore carry a `base_amount` fractal of their own (default on) so they work standalone, and the
property tells the user to zero it when the material sits above another layer in a stack.

### 5.0 Periodic ops and the resolution ceiling (found in editor testing, 2026-08-08)

§0 says the plow cannot express features below ~2 × `vertex_spacing`. That limit is soft for fractals —
octaves past it just stop contributing, which is exactly what they are supposed to do — but **hard for
periodic ops**, which produce *nothing visible* and read as a broken material.

`Pasture3DReliefFurrows` shipped with a 4 m default spacing, which on the default 1 m terrain is four
samples per cycle. Meshing and LOD ate it; the material looked dead until the spacing was raised roughly
four-fold. Three changes came out of that:

1. **Four samples per cycle is the practical floor** (`PERIOD_SAMPLES_MIN` in `plow.gd`). Two is Nyquist,
   which recovers a frequency but not a recognisable cross-section.
2. **The brush warns** when any `DUNES`/`FURROWS` op's period drops under `vertex_spacing × 4`. Only the
   brush can do this — the material has no idea what terrain it will be stamped into. Fractal ops are
   deliberately excluded. Gate J covers it, with a control proving the guard actually fires.
3. **`Furrows` was re-scoped and re-defaulted** (spacing 4 → 15 m, amplitude 0.08 → 0.35). Actual plough
   rows (~0.5 m) are not representable at any setting and belong to the surface-shader track. What *is*
   representable is the landform: medieval ridge-and-furrow runs 5–20 m crest to crest, which is exactly
   this material's range. The class documentation now says so instead of promising plough rows.

### 5.1 Noise implementation

**Use `FastNoiseLite`, not a hand-rolled noise.** One instance per noise op, constructed **once per bake**
from the op's params (never per cell). Rationale:

- It is available identically in GDScript and C++, so **A/B parity is free** rather than something we have
  to prove for a bespoke implementation.
- It natively provides `FRACTAL_FBM`, `FRACTAL_RIDGED`, and domain warp.
- It is already the dependency the plow's `NOISE` source uses
  ([pasture_3d_brush_raster.cpp:1216](src/pasture_3d_brush_raster.cpp:1216)), and the per-cell call cost
  is already proven acceptable there.

`BILLOW` is not a native FastNoiseLite fractal; implement it as `abs(fbm) * 2 - 1` over `FRACTAL_FBM`.
`RIDGED`'s `sharpness` is applied as a post-exponent on FastNoiseLite's ridged output, not by
reimplementing the fractal.

### 5.2 CRATER and mapping

`CRATER` is radial in `nu,nv` and is only meaningful under `FIT` or `SCATTER` (§6). Under `TILE` it
degrades to one crater per tile — almost certainly not what anyone wants, so the plow raises a
configuration warning for that combination rather than silently producing a crater grid.

---

## 6. Mapping modes

**This is the piece that makes "place an individual crater" possible.** The plow today only tiles:
`fposmod(x / tile_size, 1.0)` in both paths ([plow.gd:266](project/addons/pasture_3d/connectors/plow.gd:266),
[pasture_3d_brush_raster.cpp:1220](src/pasture_3d_brush_raster.cpp:1220)). There is no way to say
"one instance, fitted to this loop".

Mapping is a property of **the brush**, not the material — it describes how the loop is mapped, not what
the relief is. It applies to `RELIEF` and (for `TILE`/`FIT`) to `TEXTURE`/`MATERIAL`; it is hidden for
`NOISE`, which is world-space by definition.

| Mode | `u,v` (metres) | `nu,nv` | Use |
|---|---|---|---|
| `TILE` *(default)* | world `x,z` | position within the loop's oriented rect, `[-1,1]` | craggy sections, strata, dunes — no repeat, because ops are world-space |
| `FIT` | `x,z` relative to the loop's oriented-rect centre, rotated into its axes | `u,v` divided by the rect half-extents | **one** instance sized and oriented to the loop — a single crater |
| `SCATTER` | as `FIT`, but per instance | as `FIT`, per instance | crater fields; also the standard fix for tiled repetition |

For the existing `TEXTURE`/`MATERIAL` sources, `TILE` keeps today's exact behaviour and `FIT` maps the
image once across the oriented rect. (Phase 1 shipped this for `RELIEF` only — the LUT branch still always
tiled, silently ignoring `mapping`. Closed in phase 2 and covered by gate H.) `SCATTER` applies to
`RELIEF` alone; the other sources fall back to tiling and the brush raises a configuration warning.

### 6.1 Loop orientation

`FIT` and `SCATTER` need an oriented frame, which the current polygon → SDF path discards. Recover it in
**GDScript, once per bake**, from the already-decimated `poly`:

- centre = polygon centroid,
- axis = minimum-area enclosing rectangle (rotating callipers over the convex hull; `poly` is decimated to
  `vertex_spacing`, so this is cheap),
- half-extents = that rect's half-width and half-height.

Pass `fit_cx, fit_cz, fit_cos, fit_sin, fit_ex, fit_ez` in `params`. **No new C++ geometry code.**

Degenerate loops (near-zero extent on an axis) fall back to the AABB frame and warn.

### 6.2 Scatter instances

Placement is **GDScript, once per bake**, deterministic from a seed; C++ only evaluates. Instances are
marshalled as a `PackedFloat32Array`, stride 6:

```
[cx, cz, radius, cos_rot, sin_rot, amp_scale]
```

Plow-side scatter properties (shown only when `mapping == SCATTER`):

```gdscript
@export var scatter_count: int = 12
@export var scatter_seed: int = 0
@export var scatter_radius_min: float = 8.0
@export var scatter_radius_max: float = 24.0
@export var scatter_rotation_jitter: float = 1.0     # 0..1 of a full turn
@export var scatter_scale_jitter: float = 0.25       # amp_scale variation
@export var scatter_overlap: float = 0.0             # 0 = reject overlaps, 1 = allow freely
@export var scatter_blend := ScatterBlend.STRONGEST  # how instances combine with each other
```

**`scatter_blend` defaults to `STRONGEST` (largest magnitude wins), not `MAX`** — this resolves open
question §14 Q1. `MAX` is wrong for the primary use case: craters are negative, so `MAX` on two
overlapping craters keeps the *shallower* one. `STRONGEST` does the intuitive thing for both signs — the
deeper crater and the taller mound both win — and `ADD`/`MAX`/`MIN` remain available.

**Each instance is windowed to zero over its outer 10%** (`smoothstep(1.0, 0.9, r)`). Radial ops are
already ≈0 out there so it barely touches them, but without it a non-radial material (a fractal) would
stamp a hard-edged disc at every instance.

Placement is dart-throwing with rejection inside the loop polygon, attempts capped at `count * 32` so a
tight loop with an impossible count terminates instead of hanging.

**Per-cell cost control:** C++ buckets instances into a uniform grid sized to `scatter_radius_max`, and each
cell tests only the 3×3 neighbourhood. Without this, `SCATTER` is O(cells × instances) and would blow the
bake budget on large loops.

---

## 7. Selectors (reserved — phase 3)

Terrain-aware masking is designed in now and built in phase 3. The design point that makes it correct:

**Selectors must read the surface *below this brush's own layer*, never the final composite.** The
rasteriser already receives exactly that as `base_below`
([plow.gd:209](project/addons/pasture_3d/connectors/plow.gd:209) →
[pasture_3d_brush_raster.cpp:1180](src/pasture_3d_brush_raster.cpp:1180)), over the same grid, at the same
resolution. Slope and curvature are a 3×3 finite difference over that grid — computed per bake, not cached.

A cached global slope map would be a **correctness regression**: it would feed a plow's own relief back
into its own slope mask and drift on every re-bake, which is the same class of bug as the climbing issue
`base_below` was introduced to fix.

Phase 3 adds a selector table alongside `ops`/`params`:

```
selectors : PackedFloat32Array, stride 8
  [0] kind        0=SLOPE 1=ALTITUDE 2=CURVATURE
  [1] min         [2] max          band, in degrees / metres / 1/m
  [3] falloff_lo  [4] falloff_hi   soft edges
  [5] invert      [6] strength     [7] reserved
```

An op with `selector_id >= 0` multiplies its contribution by that selector's value.

### 7.1 As built (2026-08-08)

- **`Pasture3DReliefSelector`** is the user surface: `kind`, `range_min`/`range_max`, `falloff_low`/
  `falloff_high`, `invert`, and `strength`. `strength` lerps between ungated (1.0) and the band value, so
  a selector fades a material out rather than deleting it — and `strength = 0` is the natural control for
  any gate test.
- **Every material has an optional `selector`.** `compile()` assigns it to each GENERATOR op the material
  emitted that does not already carry one, so a material like `Scree` can gate one op specifically and
  still accept an outer selector on top.
- **Every op is gated, by category.** A GENERATOR scales its contribution by the selector; a DOMAIN op
  scales its displacement; a PROFILE op **lerps between the un-remapped and remapped accumulator**. So
  `selector == 0` always means "this op did nothing", smoothly, whatever the op is.
  > This spec originally said only GENERATOR ops should be gated, on the reasoning that gating a remap
  > would create a discontinuity. That was wrong twice. The lerp is perfectly smooth, and gating
  > generators alone produced a real bug found in editor testing: `Strata` gated its fractal base to zero
  > and then ran `STRATIFY` on that zero — whose tilted, noise-broken band function is **not** zero.
  > Fully excluded ground came out stepped by up to `0.43 × height_scale` (≈3.4 m at the default).
  > Fixed 2026-08-08; gate N locks it down.
- **Terrain fields** (`altitude`, `slope_deg`, `curvature` = Laplacian with positive meaning hollow, and
  the `grad_x`/`grad_z` gradient that `SCREE` streaks along) are derived **once per bake** in C++ from
  `base_below`, with a `get_height` fallback for NaN cells. The GDScript oracle mirrors the formula.
  `Pasture3DPlow` sends `base_below` whenever `relative_to_terrain` **or** the program needs fields, and
  sets `need_fields` so a material that ignores the ground pays nothing.
- **The stack remaps selector ids** when splicing a child's program, exactly as it does LUT slots. Gate M
  puts two different selectors in one stack specifically to catch that offset being wrong.

> **Designed, not built — the mask preview.** A selector is tuned blind today: you set a band, bake, look
> at the result, and adjust. `PASTURE3D_SIM_NODE_SPEC.md` §18 specs a red terrain overlay of the
> selector's weight, live, as a `DEBUG_` shader insert. It is specced there because the Sim's §17 masks
> raised it, but **it belongs to the selector**, so a Plow or Mound gets it on the same footing — and the
> unresolved question is this file's: a `Pasture3DReliefStack` has one selector per layer, so "preview
> the mask" means either the composite of every layer's gate or one named layer's, and those are
> different APIs. See §18.6.

---

## 8. Plow changes

```gdscript
enum Source { NOISE, TEXTURE, MATERIAL, RELIEF }     # RELIEF appended — existing ids unchanged
enum Mapping { TILE, FIT, SCATTER }

@export var source: Source = Source.NOISE            # declared default UNCHANGED — see §11
@export var relief: Pasture3DReliefMaterial          # shown only when source == RELIEF
@export var mapping: Mapping = Mapping.TILE          # hidden when source == NOISE
```

`_validate_property` additions:

| Property | Hidden when |
|---|---|
| `relief` | `source != RELIEF` |
| `mapping` | `source == NOISE` |
| `height_offset` | `source == RELIEF` (output is signed, §4.4) |
| `tile_size` | `source == NOISE`, **or** `source == RELIEF` (ops carry their own frequency), **or** `mapping != TILE` |
| `scatter_*` | `mapping != SCATTER` |

`_raise_inverted()` ([plow.gd:115](project/addons/pasture_3d/connectors/plow.gd:115)) currently only knows
about `MATERIAL`. It must also return `true` for `source == RELIEF and relief != null and not relief._raises()`,
so the Add Water button keeps working with a crater material.

`_get_configuration_warnings()` gains: no `relief` assigned under `RELIEF`; `CRATER` op present under `TILE`
mapping (§5.2); degenerate loop under `FIT`/`SCATTER` (§6.1); `scatter_count` unreachable after the attempt
cap (§6.2).

---

## 9. Engine changes

### 9.1 `stamp_plow_loop`

Signature is unchanged. New keys in `params`:

```
"ops"            PackedInt32Array
"op_params"      PackedFloat32Array
"op_luts"        PackedFloat32Array     # concatenated 256-entry LUTs for CURVE ops
"selectors"      PackedFloat32Array     # empty until phase 3
"mapping"        int
"fit_cx" "fit_cz" "fit_cos" "fit_sin" "fit_ex" "fit_ez"   float
"instances"      PackedFloat32Array     # SCATTER only, stride 6
"scatter_blend"  int
```

`source == 3` selects the new branch. The existing `source == 0/1/2` branches at
[pasture_3d_brush_raster.cpp:1215](src/pasture_3d_brush_raster.cpp:1215) are left byte-for-byte alone.

### 9.2 New file: `src/pasture_3d_relief_ops.{h,cpp}`

Holds the evaluator, kept out of the rasteriser so the two stay independently testable:

```cpp
struct ReliefProgram {                 // built once per bake from the params dict
    PackedInt32Array ops;
    PackedFloat32Array params, luts, selectors;
    std::vector<Ref<FastNoiseLite>> noises;   // one per noise op, constructed at build time
};
bool relief_build(const Dictionary &p, ReliefProgram &out);
float relief_eval(const ReliefProgram &prg, double u, double v, double nu, double nv);
```

`relief_eval` is a flat switch over `op_type` with no allocation. It is the only new hot-path code.

### 9.3 Threading

Leave the per-cell loop single-threaded in v1, matching every existing rasteriser. `relief_eval` is pure and
stateless given a `ReliefProgram`, so it parallelises later without a redesign — but that is not this spec.

---

## 10. GDScript parity path

Every op is implemented twice: `relief_eval` in C++ and `_relief_eval` in
`connectors/relief_material.gd`. `force_gdscript_raster` selects the reference path. This is the same
discipline `_blur_grid`/`nan_blur` and `_ramp`/`raster_ramp` already follow, and it is what makes the A/B
gate in §13 meaningful.

Parity tolerance: `1e-4` metres on the final `amp`. `FastNoiseLite` is the same implementation on both
sides, so the only expected divergence is float-vs-double accumulation order — which must be matched
deliberately (both sides accumulate in the declared op order, single precision at the same points).

---

## 11. Migration and compatibility hazards

**The hazard.** Godot omits default-valued properties when serialising. `Pasture3DPlow2` in
[sculpting_2.tscn:495](project/sculpting_2.tscn:495) does **not** serialise `source` — it relies on the
declared default being `NOISE = 0`. Moving the *declared* default to `RELIEF` would silently repoint that
node, and every user scene in the same position, at an unset material.

**Decision (user, 2026-08-07): the declared default stays `NOISE`; the placement flow sets `RELIEF`
explicitly on nodes it creates.** Because the value is then non-default, it serialises, and existing
scenes are correct *by construction* — no version int, no load-time migration, nothing to get wrong.

The hook is a single line in `_instantiate_placement_brush()`
([editor_plugin.gd:497](project/addons/pasture_3d/src/editor_plugin.gd:497)), which is the one
instantiation site for the toolbar brush flow (`Plow` is registered at
[toolbar.gd:37](project/addons/pasture_3d/src/toolbar.gd:37)):

```gdscript
# Newly placed brushes get the modern defaults. Set explicitly rather than by moving the script's
# declared default, so the value serialises and pre-existing scenes — which omit `source` because it
# matched the old default — keep the behaviour they were authored with. See spec §11.
if node is Pasture3DPlow:
    (node as Pasture3DPlow).source = Pasture3DPlow.Source.RELIEF
```

Generalise it to a `_apply_placement_defaults(node)` helper if a second brush ever needs the same
treatment; one `if` is not worth a framework yet.

**Do NOT set this in `_init()`.** It looks equivalent and is not: a legacy scene omits `source` precisely
*because* it equals the declared default, so nothing is applied after `_init()` and the `_init()` value
would survive — silently converting exactly the nodes this decision is meant to protect.

**Known limitation:** a `Pasture3DPlow` added through Godot's own **Create Node** dialog bypasses the
placement flow entirely and gets `NOISE`. That path can't be hooked without moving the declared default,
which is the thing we're avoiding. The toolbar is the intended creation route; the fallback is that the
user picks `RELIEF` in the inspector. Worth a line in the user guide, not worth engineering around.

Other compatibility notes:

- `Pasture3DPlowMaterial`, `plow_noise.tres`, and the `NOISE`/`TEXTURE`/`MATERIAL` paths: unchanged.
- Adding `RELIEF = 3` at the **end** of the enum keeps every serialised `source` int valid.
- New `Resource` subclasses need no `plugin.gd` registration — `@tool` + `class_name` is sufficient, as it
  already is for `Pasture3DPlowMaterial`.

---

## 12. Build order

| Phase | Contents | Rebuild? |
|---|---|---|
| **1** ✅ | Base class + `compile()` + wire format (§4); ops `CONST`, `FBM`, `RIDGED`, `BILLOW`, `WARP`, `CRATER`; `Pasture3DReliefFractal`, `Pasture3DReliefCrater`, `Pasture3DReliefStack`; mapping `TILE`/`FIT` + orientation (§6.1); C++ evaluator; GDScript oracle; the placement-default hook (§11) | yes |
| **2** ✅ | `SCATTER` (§6.2); ops `TERRACE`, `STRATIFY`, `DUNES`, `FURROWS`, `CLAMP`, `CURVE`; `Strata`, `Terraces`, `Dunes`, `Furrows` materials; `output_curve`; FIT for the LUT sources; eight demo `.tres` presets | **yes** — this row originally said "no C++ beyond the new op cases", which was wrong: SCATTER needs the instance table, the uniform-grid bucketing and `relief_scatter_eval`, and CURVE needs the `op_luts` array threaded through `ReliefProgram` |
| **3** ✅ | Selector table (§7); slope/altitude/curvature from `base_below`; `SCREE`; selector-gated ops; `talus_slope` and `weathered_cliff` presets | yes |

Phase 1 alone delivers both stated goals: "make this section craggy" (`ReliefFractal` under `TILE`) and
"place an individual crater" (`ReliefCrater` under `FIT`).

---

## 13. Verification gates

Each criterion needs a **control that fails**, and each must distinguish "measured nothing" from "measured
correctly" — a gate that passes on an empty region is not a gate.

Phase-1 gates live in [PlowReliefCheck.gd](project/bench/PlowReliefCheck.gd):

```bash
"G:/LaughingRooster/GodotVersions/Godot_v4.7-stable_win64/Godot_v4.7-stable_win64_console.exe" --headless --path project bench/PlowReliefCheck.tscn
```

Last run 2026-08-08, all nine gates: **PASS, 0 failures.**

| Gate | Result |
|---|---|
| F declared default | `source == NOISE` on a fresh node |
| A NOISE regression | −1.1557 m |
| B fractal / TILE | interior +5.5771 m, outside-loop exactly 0.0000, re-bake drift 0.00000, `strength=0` → 0.00000 |
| C crater / FIT | centre −8.0000 m; long axis −7.8131 vs short +0.7836, inverting to +0.9795 / −7.8131 on swap |
| D parity | worst 0.00000000 m over 25 probes carrying 3.8956 m of relief |
| E SCATTER | 9/9 placed, 9.8736 m of relief, same-seed drift 0.00000000 m, reseed moves 9.8736 m and carries 8.7945 m of its own |
| G phase-2 ops | worst 0.00000000 m over 25 probes carrying 8.0000 m of relief |
| H FIT for TEXTURE | FIT differs from TILE by 2.4786 m; reshaping the loop moves FIT 2.7528 m vs TILE 0.1541 m |
| I presets | all 8 compile to non-empty programs with non-constant output |
| J resolution guard | shipped Furrows default (15 m on a 1 m terrain) does not warn; 2 m does; a fractal material does not |
| K slope selector | over 225 probes (146 steep / 49 flat): gated relief 3.0788 m steep vs **0.0000 flat**; **re-bake drift 0.00000000 m**; ungated control 3.0788 steep vs 3.3264 flat |
| L SCREE | 1.0653 m steep vs 0.0000 flat; streak 0→10 m moves output 3.4365 m; opening the gate brings flat to 1.0762 m |
| M phase-3 parity | worst 0.00000000 m over 49 probes carrying 6.3754 m of relief, with two different selectors in one stack |
| N PROFILE ops are gated | gated Strata on flat ground: worst output 0.000000 (control on steep: 1.0000); baked, 16 flat probes get 0.000000 m |

Gate K's **re-bake drift line is the phase-3 result that matters**. If a selector read the finished
composite instead of the below-layer surface, the relief it just wrote would change the slope it reads
next time and the bake would creep on every refresh. Zero drift is the evidence that §7's central design
constraint actually holds in the built code, not just in the prose.

Gate I also had to change in phase 3: it evaluated presets with a zeroed terrain sample, which gates every
terrain-aware material to nothing and would have failed `talus_slope` and `weathered_cliff` for doing
exactly what they are configured to do. It now sweeps altitude, slope, curvature and gradient alongside
the position.

Two controls needed tightening after the first green run, and both are worth keeping in mind when
extending the suite. **Gate E's reseed check** originally only asserted "the field changed" — which a
placement failure satisfies just as well as a placement move, so it now also asserts the reseeded field
carries relief of its own. **Gate H's TILE control** is not expected to be perfectly still: reshaping the
loop reshapes the falloff *mask* too, which moves edge probes under any mapping. The gate asserts a ratio
(FIT must move >3× the mask-only baseline) rather than TILE ≈ 0, which the measured 2.75 vs 0.15 clears
comfortably.

| # | Criterion | Control that must fail |
|---|---|---|
| A | Existing sources unchanged: bake the `sculpting_2.tscn` plows on `NOISE`/`TEXTURE`/`MATERIAL`, compare height grids to a pre-change capture, exact match | corrupt one LUT entry → mismatch |
| B | `RELIEF` + `ReliefFractal` under `TILE` changes interior heights, leaves the rim flat, and is idempotent across two bakes | `strength = 0` → no interior change, gate reports "measured nothing" rather than passing |
| C | `RELIEF` + `ReliefCrater` under `FIT` produces exactly one depression, centred within 1 cell of the loop centroid, with a raised rim | rotate the loop 90° → the crater must rotate with it; an AABB-framed implementation fails this |
| D | A/B parity: `force_gdscript_raster` vs native, max abs delta ≤ 1e-4 m over the whole footprint | perturb one op's gain in the C++ path only → delta exceeds tolerance |
| E | `SCATTER` determinism: same seed → identical grid; different seed → different grid | same seed producing different grids means the placement RNG leaked global state |
| F | Migration, legacy direction: load `sculpting_2.tscn` post-change, `Pasture3DPlow2` still reports `source == NOISE` and bakes relief identical to §A's capture | set `source = RELIEF` in `_init()` instead of the placement hook → this gate must fail, proving it detects the §11 trap rather than passing vacuously |
| F2 | Migration, new-node direction: place a Plow from the toolbar, save the scene, and confirm the `.tscn` contains an explicit `source = 3` line | a node created via Create Node has no `source` line and reports `NOISE` — expected, and documents the §11 limitation |
| G | Mound/Splat/Ridge/Trough regression suite unchanged | — |

**Perf gates require the user's go-ahead before running** — benchmarks on this machine are not to be run
unattended. When approved, the budget is: a `RELIEF` bake with a 6-op program over a 200×200 m loop stays
within ~1.3× the same loop's `NOISE` bake, and `SCATTER` with 32 instances stays within ~2×.

---

## 14. Open questions

*Resolved: the default-source migration (2026-08-07, §1 and §11); `scatter_blend` (2026-08-08 — `MAX` is
wrong for negative relief, so the default is `STRONGEST`, §6.2); stack recursion (2026-08-08 — a
`_building` re-entry guard on the base warns and returns an empty program, so no depth cap is needed).*

1. **Op count cap** — a hard cap (say 32 ops post-flattening) would make the hot loop's cost predictable
   and give a clear error instead of a mysterious slow bake. Still unbuilt; no preset comes close (the
   largest ships 2 ops), so there is no pressure yet.
2. **`CLAMP` has no inspector surface.** The op is implemented and parity-tested on both paths, but no
   material emits it — `output_curve` covers the same ground more expressively. Left available for
   phase-3 materials rather than given a redundant knob.
3. **`SCATTER`'s inspector surface is still unexercised by gates.** Eight properties and a placement
   shortfall warning; gate E drives the bake, not the editor UI.
4. **Phase 3 is headless-verified only**, like phase 2 was. Worth a look in-editor: a `weathered_cliff`
   over a steep mound should put strata on the faces and talus at the foot, with nothing on the flats.
5. **`ALTITUDE` and `CURVATURE` selectors have no dedicated gate.** Both are exercised — `ALTITUDE`
   through gate M's stack, `CURVATURE` through `SCREE`'s toe deposition — but only `SLOPE` gets the
   binned steep-vs-flat treatment of gate K. Curvature in particular has no obviously right default
   range, since the Laplacian's magnitude scales with vertex spacing.

---

## 15. Sources

**Internal:** [plow.gd](project/addons/pasture_3d/connectors/plow.gd),
[plow_material.gd](project/addons/pasture_3d/connectors/plow_material.gd),
[pasture_3d_brush_raster.cpp:1125](src/pasture_3d_brush_raster.cpp:1125),
[pasture_3d_gpu_raster.h:25](src/pasture_3d_gpu_raster.h:25),
[terrain_brush.gd](project/addons/pasture_3d/connectors/terrain_brush.gd),
`PASTURE3D_PLOW_BRUSH_SPEC.md`, `PASTURE3D_BRUSH_PERF_ROUND2_SPEC.md`,
`PASTURE3D_BRUSH_GPU_RASTER_SPEC.md`, `PASTURE3D_WATER_BODIES_SPEC.md`.

**External:**
- [Landscape Blueprint Brushes (Epic)](https://dev.epicgames.com/documentation/en-us/unreal-engine/landscape-blueprint-brushes-in-unreal-engine)
  — the material-into-heightmap-edit-layer model, falloff + two octaves of curl noise, blend modes.
- [Gaea FractalTerraces](https://docs.quadspinner.com/Reference/Profile/FractalTerraces.html) and
  [Stratify](https://docs.quadspinner.com/Reference/Erosion/Stratify.html) — the parameter model for the
  `TERRACE` / `STRATIFY` ops (edge shape, uniformity, rock hardness; broken strata in confined local zones).
- [World Creator](https://www.world-creator.com/en/features.phtml) — slope/height/curvature as procedural
  selectors, the model for §7.
- [Red Blob Games — terrain from noise](https://www.redblobgames.com/maps/terrain-from-noise/) and
  [procedural noise for terrain](https://ithy.com/article/innovations-procedural-noise-terrain-35cvalyh)
  — ridged multifractal, billow, domain warping.
