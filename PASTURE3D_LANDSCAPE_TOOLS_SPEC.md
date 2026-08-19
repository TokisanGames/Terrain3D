# Pasture3D Landscape Tools — Mound3D, Ridge3D & Trough3D Spec

**Status:** Draft spec (2026-06-18). Target: Godot 4.7, Pasture3D `main`.
**Builds on:** the non-destructive Layers feature (`PASTURE3D_LAYERS_GUIDE.md`, phases 1–7
complete) and the road-generator integration pattern (`PASTURE3D_ROAD_CONNECTOR_GUIDE.md`,
`connectors/pasture3d_road_connector.gd`).

---

## 1. Goal

Add three spline-driven landscape authoring nodes so the user can quickly block out **hills,
mountains, valleys, plateaus, ridges, canyons and rivers** directly on a Pasture3D map, the same
way Unreal Engine 5's **Landmass** plugin does — non-destructively, into the terrain's layer
system, and editable after the fact.

- **`Pasture3DMound`** — one or more **closed-loop** splines, each filled with a hill / plateau /
  valley inside the loop, falling off to the surrounding terrain at the loop boundary.
  (UE `CustomBrush_Landmass` analogue.)
- **`Pasture3DRidge`** — one or more (usually **open**) splines that **raise** a
  hill/mountain/ridge **under and along** the spline, using the spline as the crest line.
- **`Pasture3DTrough`** — one or more (usually **open**) splines that **carve** a channel — a
  (flat) bed with banks rising back to terrain — **under and along** the spline. Pasture3D's version
  of UE's `CustomBrush_LandmassRiver`: rivers, streams, canyons, ravines, moats, sunken road cuts.

All three must:
- Paint into the terrain on a **reserved Tools layer** (non-destructive; hand-sculpting underneath
  survives; re-running is idempotent), exactly like `RoadPastureConnector`.
- Support **multiple splines sharing one node's settings** (one node = one set of shape
  parameters + one reserved layer + N child splines).
- Be **GDScript-only `@tool` nodes** in `addons/pasture_3d/` — they use the already-bound C++ Tool
  API, so **no engine rebuild is required**.

---

## 2. Research — how the reference tools do it

### 2.1 Unreal Engine 5 — Landmass plugin (the primary model)

UE5's Landmass plugin ships exactly the two brushes the user is asking for, layered
non-destructively on top of the Landscape's **Edit Layers**:

- **`CustomBrush_Landmass`** — generates a landmass from a **user-defined closed spline** plus
  effects, and stamps it onto the terrain. Key parameters:
  - **Capped vs uncapped** — capped = flat-top **plateau**; uncapped = peaked **hill/mountain**.
  - **Falloff** — slope of the transition from the shape edge to the underlying terrain, expressed
    two ways: **Angle** (steeper angle = steeper slope) or **Width** (distance over which it
    ramps; smaller = steeper).
  - **Blend mode** — like CSG/boolean ops: **Additive** (raise), **Min** (lower only where below),
    **Max** (raise only where above), **Alpha Blend** (raise *and* lower via a regular + inverted
    pass). This is what turns the same tool into hills *or* valleys.
  - **Edge offset / edge width** — expand/contract the effective boundary off the spline.
  - **Curl-noise octaves** — `Curl Strength` (amplitude) + `Curl Tiling` (frequency) to break up
    the silhouette so it doesn't look CG-perfect.
- **`CustomBrush_LandmassRiver`** — **extrudes a mesh along an (open) spline** and raises/lowers
  the terrain to match it — used for rivers and roads. The bed follows the spline's slope so water
  flows downhill. This is the structural model for our **Ridge** (the raise case) and especially
  our **Trough** (the carve-a-riverbed case). We drive the cross-section from a profile `Curve`
  rather than an extruded mesh, so no mesh asset is required.
- **Stacking** — brushes live in a stack and are **non-destructive**: editing a lower brush flows
  up through the ones above it.

The mapping to Pasture3D is direct: UE Edit Layers ⇒ our `Pasture3DLayerStack`; a Landmass brush ⇒
a `Pasture3DMound`/`Pasture3DRidge`/`Pasture3DTrough` node owning a reserved layer; brush blend
mode ⇒ our `Pasture3DLayer.BlendMode`.

### 2.2 UX references

- **Affinity Designer (pen / node tool):** click to drop nodes, drag to pull Bézier handles, node
  types (sharp / smooth / symmetric), closed vs open shapes. → We get all of this **for free** from
  Godot's built-in **Path3D editor gizmo** (each spline is a `Path3D` with a `Curve3D`: click to add
  points, drag in/out handles for Bézier curvature). No custom gizmo needed for v1.
- **Blender (curves):** proportional-editing **falloff curve**, bevel/profile swept along a path. →
  Expose a `Curve` resource for the falloff profile (Mound), the cross-section profile (Ridge) and
  the bank profile (Trough), so the user shapes the slope by dragging a curve, not guessing numbers.
- **Popular Godot addons / road-generator:** `@tool` + `class_name` to appear in the *Add Node*
  dialog with no plugin registration; `@export_tool_button` for in-inspector actions;
  `_get_configuration_warnings()` for setup hints; auto-refresh by connecting to the curve's
  `changed` signal. We mirror `pasture3d_road_connector.gd` so the feel matches the existing tool.

### 2.3 Closed loops in Godot

Godot's `Curve3D` has **no native "closed" flag** (open proposal `godot-proposals#8650`). We handle
this ourselves: a `closed` bool on the Mound, and the rasterizer connects the last baked point back
to the first to form the polygon. (Optional convenience: a "Close Loop" tool button that snaps the
last point onto the first.)

---

## 3. Architecture

### 3.1 Node layout (mirrors RoadManager → Container → Point)

```
Pasture3DMound        (Node3D, @tool, class_name)   ── owns shape settings + ONE reserved height layer
 ├─ Path3D  "Loop1"   (closed curve, native gizmo)
 ├─ Path3D  "Loop2"
 └─ Path3D  "Loop3"   …all share the node's settings, all paint into the same reserved layer

Pasture3DRidge        (Node3D, @tool, class_name)   ── same, but open splines + ridge cross-section
 ├─ Path3D  "RidgeA"
 └─ Path3D  "RidgeB"

Pasture3DTrough       (Node3D, @tool, class_name)   ── same, but open splines + carved channel section
 ├─ Path3D  "RiverMain"
 └─ Path3D  "Tributary"
```

- A node = one *style* (height, falloff, blend, noise…) + one reserved layer + N child `Path3D`
  splines → **"multiple splines sharing the node settings"** falls out naturally. Want a different
  style? Add another `Pasture3DMound`.
- Splines are discovered as **direct `Path3D` children** by default (with an optional exported
  `Array[NodePath]` override for splines that live elsewhere). A **"Add Spline"** tool button spawns
  a child `Path3D` with a sensible starter curve and selects it for editing.

### 3.2 Shared base class — `Pasture3DTerrainBrush` (abstract)

Both nodes share ~70% of `pasture3d_road_connector.gd`'s machinery; factor it into a base:

| Concern | Reused from road connector |
|---|---|
| Reserved layer plumbing | `_owner_id()` = `str(get_path())`, `_ensure_layer()` → `create_owned_layer(owner, name, blend)` with `has_method` fallback to destructive `set_height` |
| Idempotent repaint | clear the footprint AABB on the layer (`clear_layer_in_area`) then repaint; `_affected_aabb()` padding |
| Stale-trail handling | `_last_paint_aabb` cache keyed per spline so a moved spline clears its old pose; `_previous_footprints()` |
| Auto-refresh | connect to each child `Path3D.curve.changed` (+ child added/removed/transform) → debounced `_schedule_refresh()` like the road timer |
| GPU push | one `update_maps(TYPE_HEIGHT)` at the end of a refresh |
| Setup UX | `_get_configuration_warnings()`, `@export_tool_button("Refresh")`, `auto_refresh` |

Subclasses implement only **`_paint_spline(path: Path3D)`** (the rasterizer) and declare their own
shape exports.

### 3.3 Tool-API contract (already bound in C++ — no rebuild)

From `pasture_3d_data.h` "Tool API" block:

- `create_owned_layer(owner_id, name, blend_mode) -> int` — idempotent by owner; un-aliases Base.
- `set_height_on_layer(layer_id, global_pos, height, weight=1)` — absolute height (REPLACE).
- `add_height_on_layer(layer_id, global_pos, delta, weight=1)` — signed delta (ADD).
- `clear_layer_in_area(layer_id, AABB)` — sub-tile-precise clear of the footprint.
- `gc_layer(layer_id)` — free emptied tiles.
- `update_maps(TYPE_HEIGHT)` — push to GPU once per refresh.

`BlendMode`: `REPLACE=0, ADD=1, MAX=2, MIN=3`. `MapType`: `TYPE_HEIGHT=0, TYPE_CONTROL=1,
TYPE_COLOR=2`. v1 is **height-only**; control/color (e.g. auto-paint cliff texture on steep slopes)
is a documented follow-up using the typed-layer API.

### 3.4 Blend-mode → feature matrix

| User intent | Blend mode | Height sign | Cap |
|---|---|---|---|
| Hill / mountain | `MAX` (raise-only, default) or `ADD` | + | uncapped |
| Plateau / mesa | `REPLACE` (absolute top), feathered weight | + | capped |
| Valley / basin | `MIN` (lower-only) or `ADD` | − | (uncapped) |
| River / channel / canyon (Trough) | `MIN` (carve-only) | − | flat bed |
| Pure additive bump | `ADD` | ± | either |

`MAX`/`MIN` are the safe defaults (a hill never digs below existing terrain; a river/valley never
bulges above it), matching UE's Max/Min semantics. **A blend mode pairs with how the value is
written:** `MAX`/`MIN`/`REPLACE` write an **absolute target surface height** (the desired final
ground level) via `set_height_on_layer`; `ADD` writes a **signed delta** via `add_height_on_layer`.
For `MAX`/`MIN` the layer composite then clamps that target against what's underneath, so the
feature only ever raises (MAX) or only ever lowers (MIN).

---

## 4. `Pasture3DMound` — closed-loop hill / plateau / valley

### 4.1 Exports

```gdscript
@export var terrain: Pasture3D
@export var auto_refresh := true
@export var target_layer_name := "Mounds"

@export_group("Shape")
@export var height: float = 20.0           # peak (capped: plateau top height; uncapped: peak height) above base
@export var capped: bool = false           # true = flat-top plateau; false = domed peak
@export var blend_mode: BlendMode = MAX    # MAX hill / MIN valley / ADD bump / REPLACE absolute plateau
@export var invert: bool = false           # flip sign → carve a depression with the same controls

@export_group("Falloff")
@export var flank_mode: FlankMode = FIXED_WIDTH  # FIXED_WIDTH ramps over falloff_width; SLOPE_ANGLE over height/tan(angle)
@export var falloff_width: float = 15.0     # FIXED_WIDTH: metres from the loop edge inward over which height ramps in
@export_range(1,89,0.5) var slope_angle: float = 30.0  # SLOPE_ANGLE only: grade the flank rises at (run = |height|/tan)
@export var falloff_curve: Curve            # optional; default = smoothstep. Drives the edge slope shape
@export var edge_offset: float = 0.0        # +expand / −contract the effective boundary off the spline

@export_group("Noise")          # break up the silhouette (UE curl-noise analogue)
@export var noise: FastNoiseLite
@export var noise_strength: float = 0.0     # metres of vertical jitter, scaled by interior mask so edges stay clean

@export_group("Splines")
@export var closed := true                  # connect last point → first to form the loop polygon
@export_tool_button("Refresh") var _refresh = refresh
@export_tool_button("Add Spline") var _add = add_spline
```

### 4.2 Rasterization (`_paint_spline`)

1. **Polygon** — bake the child `Path3D` curve to world points, project to XZ
   (`Vector2(x, z)`), close last→first. Apply `edge_offset` by polygon offsetting (or by
   thresholding the signed distance — see step 4).
2. **Base height** — the elevation the falloff ramps *from/to*. Default = sampled terrain height at
   each pixel (so the mound sits *on* the ground); the node's own `global_position.y` provides the
   reference plane for the peak so moving the node moves the hill vertically.
3. **AABB** — polygon bounds padded by `falloff_width + |edge_offset| + noise_strength`; snap to
   `vertex_spacing`. This is the clear/paint footprint.
4. **Grid walk** (step = `terrain.vertex_spacing`) over the AABB. For each `(x, z)`:
   - `d` = **signed distance** to the (offset) polygon boundary, positive inside.
     `Geometry2D.is_point_in_polygon` for inside/outside + distance-to-nearest-edge for magnitude
     (reuse `_distance_to_polygon_boundary_2d` from the road connector).
   - Skip if `d < -|edge_offset|` clearly outside the falloff band.
   - **Edge factor** `t` (0 at the outer falloff edge → 1 fully inside):
     `t = clamp(d / ramp, 0, 1)`, shaped by `falloff_curve` (default smoothstep). `ramp` is
     `falloff_width` in FIXED_WIDTH mode, or (CAPPED + SLOPE_ANGLE) `|height| / tan(slope_angle)`.
   - **SLOPE_ANGLE + UNCAPPED ("cone")** is a special case that bypasses the profile entirely: the
     height rises freely at the grade, `h = tan(slope_angle) * d`, NOT limited by `height` — clamped only
     to a region-sized safety ceiling (`region_size * vertex_spacing`) so a steep angle over a big loop
     can't author a runaway peak. `t` (= `d / max_interior_d`) is reused solely to mask the noise.
   - **Profile**:
     - *capped* → `profile = t` (ramp up to a flat top at `height`).
     - *uncapped* → dome via the normalized distance transform:
       `profile = curve(min(d / max_interior_d, 1))` so the centre of the loop reaches `height` and
       it eases to 0 at the rim. (`max_interior_d` = max `d` over the loop, computed once per spline.)
   - **Noise** (optional): `h += noise_strength * noise.get_noise_2d(x, z) * interior_mask`
     (mask = the same `profile`/`t` so the rim stays crisp).
   - **Target surface** `h = base_y + sign * height * profile (+ noise)` (`sign = invert ? -1 : +1`).
   - **Write** per blend mode (the node's `blend_mode` is passed to `create_owned_layer`, so the
     layer composite applies it):
     - `REPLACE` → `set_height_on_layer(layer, pos, h, weight = profile)` (feathered absolute — for
       plateaus).
     - `MAX`/`MIN` → `set_height_on_layer(layer, pos, h, weight = 1)` — write the **absolute target
       surface** `h`; the layer's max/min clamps it against the terrain below (rim eases out because
       `profile → 0` makes `h → base_y`). MAX = hill, MIN = basin.
     - `ADD` → `add_height_on_layer(layer, pos, delta = sign*height*profile + noise, weight = 1)`.

### 4.3 Multiple loops

Painting is additive across the node's child splines because they all write the same reserved layer
and the layer's blend mode composites them. Two overlapping loops with `MAX` merge into one larger
hill; with `ADD` they sum. Clearing uses the **union AABB** of all child splines (full Refresh) or
the per-spline footprint (auto-refresh of one moved spline), reusing the road connector's
overlap-rescan so a neighbour loop sharing the cleared tiles is repainted.

---

## 5. `Pasture3DRidge` — spline-as-crest hill / mountain / canyon

### 5.1 Exports

```gdscript
@export var terrain: Pasture3D
@export var auto_refresh := true
@export var target_layer_name := "Ridges"

@export_group("Shape")
@export var crest_height: float = 30.0      # height of the ridge crest above the base
@export var width: float = 25.0             # half-width: lateral distance from centreline to skirt edge
@export var blend_mode: BlendMode = MAX     # MAX mountain / MIN canyon-river / ADD
@export var invert: bool = false            # carve a valley/river instead of raising a ridge
@export var profile: Curve                  # cross-section: crest (left, =1) → skirt (right, =0). Default rounded

@export_group("Crest line")
@export var follow_spline_height := true    # crest Y from the spline's own Y; else = terrain height + crest_height
@export var taper_ends: float = 0.0         # metres at each end over which crest_height eases to 0 (blends into ground)

@export_group("Noise")
@export var noise: FastNoiseLite
@export var noise_strength: float = 0.0     # ridgeline jitter (mountain-range feel)

@export_group("Falloff")
@export var falloff: float = 10.0           # extra skirt beyond `width` that feathers into terrain
@export_tool_button("Refresh") var _refresh = refresh
@export_tool_button("Add Spline") var _add = add_spline
```

### 5.2 Rasterization (`_paint_spline`)

This is the road-flatten algorithm with a **cross-section profile** instead of a flat road, and
raise/carve instead of level. Reuse `flatten_terrain_via_roadsegment_approx`'s structure:

1. Bake the spline to a world polyline. AABB = polyline bounds padded by `width + falloff +
   noise_strength`; snap to grid; clear footprint on the layer.
2. Grid walk. For each `(x, z)`:
   - Find the **closest point** on the spline (`Curve3D.get_closest_offset` →
     `sample_baked`/`sample_baked_with_rotation`) and the **lateral distance** `L` from the
     centreline (XZ).
   - Skip if `L > width + falloff`.
   - **Along-curve taper** `e` near the two ends (within `taper_ends` of offset 0 or baked_length).
   - **Crest base Y** = `follow_spline_height ? sample.y : terrain.data.get_height(pos)`.
   - **Cross-section factor** `p`: `L <= width` → `profile(L / width)` (1 at crest, falling to the
     skirt); `width < L <= width+falloff` → feather `profile`'s edge value → 0 by `falloff`.
   - **Target surface** `h = base_y + sign * crest_height * p * e (+ noise * p)`.
   - **Write** like the Mound: `MAX`/`MIN`/`REPLACE` write the absolute `h` (weight `1`, or `p*e`
     for REPLACE feathering); `ADD` writes the delta `sign*crest_height*p*e`. Default `MAX` = a
     mountain ridge that never digs below the terrain.

Ridge3D is the **raise** tool. For carving a channel/river along a spline use the dedicated
**`Pasture3DTrough`** (§6) instead of `Ridge + invert` — Trough adds a flat bed, bank run, and
carve-only defaults that a single-profile inverted ridge lacks.

---

## 6. `Pasture3DTrough` — spline-as-channel river / canyon / road-cut (LandmassRiver analogue)

Trough3D is the dedicated **carve-only** channel cutter — Pasture3D's version of UE5's
`CustomBrush_LandmassRiver`. Where Ridge3D *raises* a crest along the spline, Trough3D *lowers* a
channel **under** the spline: an (optionally flat) **bed** flanked by **banks** that rise back up to
the surrounding terrain. Use it for rivers, streams, canyons, ravines, moats, and sunken road cuts.

Why a separate node and not "Ridge3D + invert": Trough3D defaults to **MIN** (it can only dig, never
bulge above the ground), and its cross-section has three distinct zones a single inverted ridge
profile can't express — a **flat bed** (riverbed floor), a separate **bank** run with its own
profile/width, and an outer **falloff** feather. Its bed also **follows the spline's own Y** so you
author a flowing river simply by drawing the spline downhill (matching LandmassRiver).

### 6.1 Exports

```gdscript
@export var terrain: Pasture3D
@export var auto_refresh := true
@export var target_layer_name := "Troughs"

@export_group("Channel")
@export var depth: float = 8.0              # how far below the bed reference the channel floor sits
@export var bed_half_width: float = 4.0     # half-width of the (flat) channel floor, centred on the spline
@export var flat_bed: bool = true           # true = flat floor; false = V/U bottom shaped by `bed_profile`
@export var bed_profile: Curve              # optional floor shape when flat_bed = false (centre =1 deep → bed edge =0)
@export var blend_mode: BlendMode = MIN     # MIN = carve-only (default, never raises); REPLACE/ADD available

@export_group("Banks")
@export var bank_width: float = 10.0        # lateral run from bed edge up to terrain level (the bank slope length)
@export var bank_profile: Curve             # bed edge (=0, deep) → bank top (=1, terrain). Default = smoothstep
@export var falloff: float = 6.0            # extra feather beyond the bank top into surrounding terrain

@export_group("Bed line")
@export var follow_spline_height := true    # bed reference = spline Y (author flow by drawing downhill);
                                            # else = per-pixel terrain height (uniform-depth ditch)
@export var taper_ends: float = 0.0         # metres at each end over which depth eases to 0 (mouth/source blend)

@export_group("Noise")
@export var noise: FastNoiseLite
@export var noise_strength: float = 0.0     # lateral/vertical jitter on the banks for a natural edge

@export_tool_button("Refresh") var _refresh = refresh
@export_tool_button("Add Spline") var _add = add_spline
```

### 6.2 Rasterization (`_paint_spline`)

Same closest-point sweep as Ridge3D, but the cross-section is an **inverted, three-zone channel** and
the write is carve-only:

1. Bake the spline to a world polyline. AABB = bounds padded by
   `bed_half_width + bank_width + falloff + noise_strength`; snap to grid; clear the footprint.
2. Grid walk. For each `(x, z)`:
   - Closest point on the spline (`get_closest_offset` → `sample_baked`) + lateral distance `L`.
   - Skip if `L > bed_half_width + bank_width + falloff`.
   - **Along-curve taper** `e` near both ends (within `taper_ends`).
   - **Bank-top reference** `top_y = follow_spline_height ? sample.y : terrain.data.get_height(pos)`.
     **Bed floor** `bed_y = top_y - depth * e`.
   - **Cross-section** → target surface `h`:
     - `L <= bed_half_width` → **bed**: `h = bed_y` (flat), or `lerp(bed_y, top_y, 1 - bed_profile(L/bed_half_width))`
       for a V/U floor (deepest at centre).
     - `bed_half_width < L <= bed_half_width + bank_width` → **bank**:
       `h = lerp(bed_y, top_y, bank_profile((L - bed_half_width) / bank_width))` — rises from floor to terrain.
     - else (within `falloff`) → feather the bank-top value into `top_y` so the cut blends out cleanly.
   - **Noise** (optional): jitter `h` toward `top_y` near the banks (mask by closeness to the bank zone
     so the bed stays smooth and the cut never spikes above terrain).
   - **Write**: `set_height_on_layer(layer, pos, h, weight = e)` with the layer created `MIN` → the
     composite carves down to `h` only where `h` is below the existing terrain, so banks above ground
     never add material. (`REPLACE`/`ADD` available for special cases, same convention as §3.4.)

### 6.3 River flow / downhill helper

Because the bed follows the spline's Y (`follow_spline_height`), drawing the spline monotonically
downhill produces a channel that descends along its length — exactly how LandmassRiver makes water
flow. Optional follow-up: a **"Make Descend"** tool button that clamps each curve point's Y to be
`≤` the previous point's, so a hand-drawn river never accidentally runs uphill.

---

## 7. Editor interaction & UX

- **Spline editing:** select a child `Path3D` → Godot's native curve gizmo handles add/move/Bézier.
  No custom gizmo in v1.
- **Live feedback:** `auto_refresh` re-paints (debounced) on `curve.changed`, child add/remove, and
  node transform — same timer/mutex pattern as the road connector so dragging a point updates the
  hill in near-real-time without thrashing.
- **Footprint preview (optional, v1.1):** a thin `EditorNode3DGizmoPlugin` that draws the loop
  polygon (Mound) / centreline + skirt edges (Ridge) and the outer falloff boundary, so the user
  sees the affected area before painting. Not required for function.
- **Config warnings:** missing/empty `terrain`, no regions yet, a spline with < 3 points (Mound) /
  < 2 points (Ridge, Trough), `auto_refresh` off (hint to press Refresh).
- **Discoverability:** `@tool` + `class_name Pasture3DMound`/`Pasture3DRidge`/`Pasture3DTrough` →
  they appear in *Add Node* with no `editor_plugin.gd` change (same as `RoadPastureConnector`). Place
  the scripts in `addons/pasture_3d/connectors/` (or a new `tools/`) next to `pasture3d_road_connector.gd`.

---

## 8. Non-destructive / idempotency guarantees (inherited from Layers)

- Each node owns exactly **one** reserved height layer (`create_owned_layer(owner_id, name, blend)`),
  keyed by `str(get_path())` so it survives reloads and re-refreshes.
- A refresh = **clear the footprint AABB → repaint** → idempotent; hand-sculpted Base underneath is
  untouched; deleting the node + `gc_layer` frees the tiles.
- Persists via the existing `pasture3d_layers*.res` files — **runtime `pasture3d_<loc>.res` is never
  touched** and there is **zero runtime/VRAM cost** (layers flatten on save).
- **Fallback:** on a build/terrain without the layers Tool API (`has_method` guard), all three nodes
  fall back to destructive `set_height`, so they still work (non-idempotent) — mirrors the road connector.

---

## 9. Caveats / open questions

- **Performance (SOLVED in GDScript — no C++ needed):** the first cut was per-pixel
  `is_point_in_polygon` + boundary distance (Mound) / closest-point-on-polyline (Ridge/Trough), i.e.
  **O(cells × baked-edges)**. Because `Curve3D` bakes at ~0.2 m, a simple loop became 1400–4900 edges
  on a 1 m grid, so a 5-point loop froze the editor for **4–164 s** (measured). Replaced with
  rasterisation that is **O(cells)**:
  - **Mound** → decimate the loop to grid resolution, scanline-fill an inside mask, then a two-pass
    **chamfer signed distance field** (`_signed_distance_field` + `_chamfer`); the dome's max-interior
    falls out of the same field (no second pass).
  - **Ridge / Trough** → a **polyline feature field** (`_polyline_field` + `_chamfer_payload`): a
    chamfer DT that also propagates the nearest point's crest/bed **Y** and **arc length**, so the
    paint loop reads distance + base-Y + taper from arrays instead of scanning every segment per pixel.
  - Measured after: Mound **164 s → 0.23 s**, Ridge **9.6 s → 0.06 s**, Trough **7.7 s → 0.06 s**
    (region 256, large brushes). Inspired by image-editor SDF falloff + Krita's dirty-rect/LOD ideas.
  - Remaining bounded cost: `clear_layer_in_area` recomposites whole touched regions on each re-bake
    (≈0.1 s at region 256; grows with `region_size`) — shared with the road connector, not brush-specific.
    C++ `paint_*` Data methods remain a *possible* future win but are no longer needed for usability.
- **Undo/redo:** curve-point edits undo via Godot's Path3D gizmo; the *terrain repaint* is a derived
  effect and is **not** wired into `EditorUndoRedoManager` in v1 (same limitation the road connector
  documents). Pressing Refresh always reconverges. Full undo integration = follow-up.
- **Closed-loop ergonomics:** until `godot-proposals#8650` lands, the loop close is logical (in our
  rasterizer), not visual in the gizmo. The "Close Loop" button mitigates.
- **Mound base reference:** decide whether the peak is measured from the node's `global_position.y`,
  from the average terrain height under the loop, or from per-pixel terrain height. Spec default =
  per-pixel terrain height for the ramp + node Y as the peak plane; revisit after first in-editor test.
- **Stacking order between nodes:** two different brush nodes = two layers; their order in the
  `Pasture3DLayerStack` (Layers dock) decides who wins — already user-controllable. A common stack:
  Mounds/Ridges (raise) below, Troughs (carve) above, so a river cuts through a hill it crosses.

---

## 10. Suggested build order

1. **`Pasture3DTerrainBrush` base** — extract the reserved-layer + clear/repaint + auto-refresh
   plumbing from `pasture3d_road_connector.gd` (shared, tested once).
2. **`Pasture3DMound`** — closed-loop fill; start with `capped`/`MAX`, then uncapped dome, then
   falloff curve, then noise, then multi-spline.
3. **`Pasture3DRidge`** — adapt the road approx-flatten path with the profile curve, raise (`MAX`).
4. **`Pasture3DTrough`** — same closest-point sweep as Ridge, three-zone channel section + `MIN`
   carve; reuses almost all of Ridge (largely a different `_paint_spline` cross-section + defaults).
5. **Polish** — `_get_configuration_warnings`, "Add Spline"/"Close Loop"/"Make Descend" buttons,
   optional preview gizmo.
6. **Verify in-editor** on the demo project (4.7), then optional C++ acceleration if painting is slow.

---

## 11. Sources

- [Landscape Blueprint Brushes — Unreal Engine 5 docs](https://dev.epicgames.com/documentation/unreal-engine/landscape-blueprint-brushes-in-unreal-engine?lang=en-US)
- [Landscape Blueprint Brushes — UE 4.27 docs](https://docs.unrealengine.com/4.27/en-US/BuildingWorlds/Landscape/Editing/SculptMode/Blueprint)
- [Path3D — Godot Engine docs](https://docs.godotengine.org/en/stable/classes/class_path3d.html)
- [Path3D "closed curve" proposal — godot-proposals#8650](https://github.com/godotengine/godot-proposals/issues/8650)
- Internal: `PASTURE3D_LAYERS_GUIDE.md` (§8 Tool API), `PASTURE3D_ROAD_CONNECTOR_GUIDE.md`,
  `connectors/pasture3d_road_connector.gd`, `src/pasture_3d_data.h` (Tool API), `src/pasture_3d_layer.h` (BlendMode).
</content>
</invoke>
