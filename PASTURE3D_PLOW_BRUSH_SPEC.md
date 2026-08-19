# Pasture3D Plow Brush Spec (`Pasture3DPlow`)

**Status:** **IMPLEMENTED 2026-06-19** (GDScript-only, no rebuild) — `connectors/pasture3d_plow.gd`, all three
sources (NOISE / TEXTURE / MATERIAL) per the chosen scope; layer name "Plow"; mid-grey neutral
(`height_offset = 0.5`) so relief goes up *and* down. Headless-verified: NOISE relief up+down +
idempotent + rim-flat, TEXTURE compressed→decompress LUT + baked relief, MATERIAL alpha-height LUT,
Mound height-brush regression clean (25.00). NOT yet user-verified in-editor. Target: Godot 4.7,
Pasture3D `main`.
**Expected scope:** GDScript-only — **no engine rebuild** (reuses the already-bound C++ Tool API:
`create_owned_layer_typed`, `set_height_on_layer`, `add_height_on_layer`, `clear_layer_in_area`,
`composite_region`, `update_maps`).
**Builds on:** `connectors/pasture3d_splat.gd` (closed-loop area mask + falloff + tiling), `connectors/pasture3d_mound.gd`
(height application), and the shared `connectors/pasture3d_terrain_brush.gd` base (reserved-layer plumbing, undo,
surface-snap, layer-sharing, O(cells) SDF). Sibling of `PASTURE3D_MATERIAL_BRUSH_SPEC.md`.

---

## 1. Goal

A closed-loop spline brush that **deforms the height map from a "material" (a displacement source)
within the loop**, masked by the spline's falloff. Drop it on flat ground and it stamps **small hills,
dunes, or a craggy/rocky surface**; the relief tiles inside the area and feathers back to the existing
ground at the rim so it blends seamlessly.

It is the **height-map counterpart of `Pasture3DSplat`**: where the splat paints *which texture*
shows (control map), the plow paints *how the surface is shaped* (height map). It is also the literal
analogue of how **UE5 Landmass custom brushes** work — a Landmass brush is a *material rendered into
the landscape's heightmap edit layer*. `Pasture3DPlow` brings that "material → heightmap, confined to a
spline region" idea to Pasture3D's non-destructive layers.

> Use the existing **Mound** when you want one deliberate hill/plateau from the loop shape itself; use
> **Plow** when you want the *surface texture/relief of a material* (noise, a heightmap, a material's
> displacement) stamped across the whole area.

---

## 2. Relationship to existing brushes (what is reused vs new)

| Concern | Source | Reuse |
| --- | --- | --- |
| Closed-loop spline, decimation, footprint AABB | `pasture3d_splat.gd` / `pasture3d_mound.gd` `_polygon_xz`, `_spline_footprint_aabb` | verbatim |
| Area mask + falloff (`falloff_width`, `falloff_curve`, `edge_offset`) | `pasture3d_splat.gd` / base `_signed_distance_field`, `_ramp` | verbatim |
| Height write into a reserved layer + blend (REPLACE/ADD/MAX/MIN) | base `_paint_height`, `_get_blend_mode` | verbatim |
| Map type = HEIGHT → layer-sharing, undo, **surface-snap**, dock badges | base (`_map_type()` default) | free |
| **Height-source sampler** (noise / texture / material relief) | — | **NEW (this spec)** |

So the brush body is `pasture3d_splat.gd`'s `_paint_spline` mask loop with the control-write swapped for Mound's
`_paint_height(pos, base_y + amp, amp)`, where `amp` comes from the new sampler instead of a dome
profile. Map type stays HEIGHT (the base default), so `Pasture3DPlow` is automatically part of the
height layer family and gets undo/snap/sharing with zero extra work.

---

## 3. The height source (the one new design decision)

The "material" that deforms the ground. Three modes, selected by a `source` enum; **NOISE is the
default** (robust, GDScript-only, no asset prep, exactly fits "small hills / craggy surface"):

### 3.1 `NOISE` — `FastNoiseLite` (default, recommended)
- Sample `noise.get_noise_2d(x, z)` in **world XZ** (so the relief is continuous across the area and
  independent of the node's position). `FastNoiseLite` returns roughly `[-1, 1]`.
- `amp = height_scale * noise_value * mask`. Cellular/ridged noise → craggy; Perlin/Simplex → rolling
  hills; layered via FastNoiseLite's own fractal settings.
- Zero CPU image work; trivially fast. This is the primary path and should ship first.

### 3.2 `TEXTURE` — a tiling heightmap `Texture2D`
- A user-assigned grayscale/displacement `Texture2D`, tiled across the area by `tile_size` (metres per
  repeat): `u = wrapf(x / tile_size, 0, 1)`, `v = wrapf(z / tile_size, 0, 1)`.
- Sample the **red/luminance** channel → height in `[0, 1]`.
- **CPU sampling caveat:** read the image once per bake via `tex.get_image()`. If
  `img.is_compressed()` (VRAM/BPTC), call `img.decompress()` first (`get_pixel` fails on compressed
  data). Cache the decompressed `Image` (and ideally a `PackedFloat32Array` lookup) for the whole
  bake — it is O(image) once, then O(1) per cell. Recommend the height texture be imported **Lossless
  / uncompressed** to skip the decompress; note compressed still works (one-time cost per bake).
- `amp = height_scale * (sample - height_offset) * mask` so `height_offset` (default `0`) lets you make
  it purely additive bumps, or `0.5` to make mid-grey = no change (signed up/down relief).

### 3.3 `MATERIAL` — a dedicated `Pasture3DPlowMaterial` brush material (REVISED 2026-06-19)
- **Decision (user 2026-06-19):** MATERIAL must be a *brush material assigned on the plow*, NOT the
  terrain's surface textures (reusing the landscape's materials was explicitly unwanted). The original
  "sample a terrain `Pasture3DTextureAsset`'s alpha height via a named dropdown" design was dropped.
- New `connectors/pasture3d_plow_material.gd` — `@tool class_name Pasture3DPlowMaterial extends Resource` holding
  `height_map: Texture2D` (grayscale relief, read by **luminance**), `invert: bool`, and `strength:
  float` (a relief multiplier on top of the brush's `height_scale`). It is a normal saveable `.tres`,
  reusable across plow brushes, and `emit_changed()` on edit so the brush re-bakes live.
- The plow exposes `@export var plow_material: Pasture3DPlowMaterial` **directly under Source** in the
  Relief group (not a collapsed subgroup); `_validate_property` shows only the active source's input
  (noise / height_texture / plow_material) and hides `tile_size` for NOISE.
- Same tiling + decompress + 256² LUT cap as §3.2 (works with compressed height maps too).
- A ready-made `demo/data/plow_noise.tres` (height map = the generated tileable noise texture) ships
  for instant testing.

---

## 4. Properties (inspector)

```gdscript
@tool class_name Pasture3DPlow extends Pasture3DTerrainBrush

@export_group("Relief")
enum Source { NOISE, TEXTURE, MATERIAL }
@export var source: Source = Source.NOISE         # which displacement source (§3)
@export var height_scale: float = 8.0             # metres of relief at full mask (× source value)
@export var height_offset: float = 0.0            # bias subtracted from TEXTURE/MATERIAL sample pre-scale
@export var tile_size: float = 16.0               # metres per repeat for TEXTURE/MATERIAL tiling
@export var relative_to_terrain: bool = true      # stamp onto existing ground (true) vs node Y plane
enum BlendMode { REPLACE, ADD, MAX, MIN }
@export var blend_mode := BlendMode.ADD           # ADD = stamp relief on top; MAX/MIN = raise/lower-only

# Source.NOISE
@export var noise: FastNoiseLite
# Source.TEXTURE
@export var height_texture: Texture2D
# Source.MATERIAL  (dropdown of terrain textures, via _validate_property/_texture_names like splat)
@export var material: int = 0

@export_group("Mask")                             # identical to splat — the area falloff
@export var falloff_width: float = 10.0
@export var falloff_curve: Curve
@export var edge_offset: float = 0.0
```

Overrides: `_map_type()` → HEIGHT (default, so omit), `_get_blend_mode()` → `int(blend_mode)`,
`_default_layer_name()` → `"Plow"` (or "Relief"), `_min_points()` → 3, `_spline_basename()` → "Area".
`_validate_property` shows `material` as the named texture dropdown **only when `source == MATERIAL`**.
All property setters call `_schedule_refresh()` (as splat/mound do) so edits re-bake live.

---

## 5. Compositing & blend semantics

- **ADD (default):** `add_height_on_layer(layer, pos, amp, 1.0)` — relief is added on top of whatever is
  beneath (other layers/brushes), so dropping a Plow over a Mound roughens the mound. With
  `relative_to_terrain`, the mask falloff guarantees `amp → 0` at the rim → seamless edges.
- **MAX / MIN:** `set_height_on_layer(pos, base_y + amp, 1.0)` (raise-only / lower-only authoring),
  matching Mound's corrected write semantics (only ADD writes a delta).
- **REPLACE:** absolute authoring — flattens the area to `base_y + amp`; mostly useful with
  `relative_to_terrain = false` for a deliberately shaped pad.
- Because the brush is HEIGHT type, **surface-snap** (base feature) and the **clear-then-snap-then-
  repaint** idempotency / climbing-fix all apply unchanged; no per-brush work.

---

## 6. Algorithm (`_paint_spline`, mirrors splat with a height write)

```
poly = _polygon_xz(path);  if poly.size() < 3: return
b = _snapped_bounds(footprint, vs);  gw, gh from b
field = _signed_distance_field(poly, ...)[0]            # area mask, O(cells)
src = _prepare_source()                                 # decompress+cache image / Float lookup once
for each cell (x, z) with signed_d = field + edge_offset > 0:
    mask = _ramp(falloff_curve, signed_d / falloff_width)
    if mask <= 0: continue
    v = _sample_source(src, x, z)                        # NOISE: noise_2d; TEXTURE/MATERIAL: tiled pixel
    amp = height_scale * (v - height_offset) * mask
    base_y = terrain.data.get_height(pos) if relative_to_terrain else global_position.y
    _paint_height(pos, base_y + amp, amp)
```

`_prepare_source()` runs **once per `_paint_spline`** (not per cell): builds the `FastNoiseLite` ref, or
decompresses the texture/material image into a cached `Image` (+ optional `PackedFloat32Array` of the
sampled channel for O(1) bilinear lookup). Per-cell cost stays O(1) → whole bake stays O(cells), same
budget as Splat/Mound.

---

## 7. Edge cases & notes

- **No source set:** NOISE with a null `noise` → no relief (skip); TEXTURE with null `height_texture`
  or MATERIAL with no terrain textures → skip + `update_configuration_warnings()` hint.
- **Compressed images:** decompress once; if `decompress()` fails (e.g. unsupported format) skip with a
  one-time `push_warning` rather than erroring per cell.
- **Tiling seams:** `tile_size` tiling can seam if the texture isn't tileable; the **Noise test
  texture** generated this session *is* tileable, and FastNoiseLite is seamless. Document that height
  textures should be tileable.
- **Material mode height availability:** if the chosen asset packs no alpha height, sampling alpha
  yields a constant → flat; fall back to luminance and warn.
- **Same-name cross-type layer collision:** default layer name "Plow" is distinct from "Detail"
  (splat) / "Mounds" / "Ridges" / "Troughs", so the owner-by-name sharing has no collision (same
  caveat already documented for splat).
- **Surface-snap interaction:** snapping moves spline-point Y; the plow reads `get_height` per cell for
  `base_y`, and the base's clear-then-snap ordering (Fix A) keeps it from climbing its own relief.

---

## 8. Files touched

- **NEW** `project/addons/pasture_3d/connectors/pasture3d_plow.gd` (`Pasture3DPlow`).
- No base changes expected — `pasture3d_terrain_brush.gd` already exposes `_paint_height`, `_signed_distance_
  field`, `_ramp`, `_map_type` (HEIGHT default), `_get_blend_mode`, and the named-texture dropdown
  helper pattern (copy `_texture_names`/`_validate_property` from `pasture3d_splat.gd`, or hoist them to the base
  if both brushes end up sharing them — a small optional refactor).
- Optional: register the new node in the tool palette / `PastureToolNodes.tscn` if brushes are listed
  there.

---

## 9. Suggested build order

1. **NOISE source** (§3.1) + the mask/height loop (§6) + ADD/MAX/MIN/REPLACE (§5). This alone delivers
   "drop on flat ground → hills / craggy surface." Verify headless: flat region + Plow loop → interior
   height changes, rim stays flat, re-bake idempotent, undo round-trips, Mound regression still raises.
2. **TEXTURE source** (§3.2) with decompress+cache + tiling.
3. **MATERIAL source** (§3.3) — asset alpha-height + named dropdown (the UE "material" parallel).
4. Polish: `height_offset` UX, optional `PackedFloat32Array` lookup for bilinear texture sampling.

---

## 10. Open questions for the user (pick before/at build)

1. **Default layer name:** "Plow" or "Relief"? (Affects the auto-created tool layer name.)
2. **Ship scope now:** NOISE only (fastest path, matches "small hills / craggy surface"), or
   NOISE + TEXTURE, or all three including MATERIAL?
3. **Signed vs additive default:** `height_offset = 0` (purely additive bumps) vs `0.5` for
   TEXTURE/MATERIAL (mid-grey = no change, relief goes up *and* down)?

---

## 11. Sources

- Internal: `connectors/pasture3d_splat.gd` (mask/tiling/dropdown), `connectors/pasture3d_mound.gd` (height write),
  `connectors/pasture3d_terrain_brush.gd` (base API: `_paint_height`, `_signed_distance_field`, `_map_type`),
  `PASTURE3D_MATERIAL_BRUSH_SPEC.md`, `PASTURE3D_LANDSCAPE_TOOLS_SPEC.md`.
- UE5: Landmass / Water custom brushes render a **material into the landscape heightmap edit layer**
  within a brush region — the "material deforms the terrain" model this brush mirrors.
- Godot: `Image.decompress()` / `Image.get_pixel`, `FastNoiseLite.get_noise_2d`,
  `_validate_property` enum hints.
```
