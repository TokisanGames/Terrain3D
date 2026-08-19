# Pasture3D Material Brush (Splat3D) Spec

**Status:** IMPLEMENTED 2026-06-18 (GDScript-only, no rebuild; 9/9 headless checks incl. height-brush
regression; not yet user-verified in-editor). Color-tint (§4 optional) not built. Target: Godot 4.7,
Pasture3D `main`.
**Builds on:** the spline brushes (`PASTURE3D_LANDSCAPE_TOOLS_SPEC.md` — base class, SDF mask,
tool-layer assignment, surface snap) and the typed control/color layers (`PASTURE3D_LAYERS_GUIDE.md` §7).
`connectors/{terrain_brush,mound}.gd`.
**Expected scope:** GDScript-only — **no engine rebuild**. Confirmed bound: `create_owned_layer_typed`,
`set_control_on_layer`, `set_color_on_layer`, `get_control`, `update_maps(map_type)`,
`Pasture3DUtil.enc_base/enc_overlay/enc_blend/enc_uv_scale/enc_uv_rotation` (+ `get_*` decoders),
`Pasture3DAssets.get_texture_count/get_texture_list`.

---

## 1. Goal

A spline **material/texture** brush — the splat-map analogue of the height brushes. A closed-loop
spline defines an **area mask with falloff**; inside it the brush applies a chosen terrain material
(texture), which tiles naturally and feathers out at the spline edge. It paints into a non-destructive
**control** layer (which texture, how much), so it's reversible, idempotent, and stacks above the
existing height brush layers — ideal for *quickly adding texture variation/detail over an area* (a
patch of rock, sand, a worn path interior, snow caps) without hand-painting.

Working name **`Pasture3DSplat`** (colloquial *Splat3D*); `Pasture3DPaint` / `Pasture3DPatch` are
alternatives — user's call.

---

## 2. Feasibility — YES, pure GDScript

Pasture3D's layers already support **typed** (control/color) non-destructive layers and a tool API to
paint them, all bound:
- `create_owned_layer_typed(owner, name, blend, map_type)` — make a TYPE_CONTROL (=1) reserved layer.
- `get_control(global) -> int` — the composited control uint32 under a point (read the base to preserve).
- `set_control_on_layer(layer_id, global, control, weight)` — write a control value into the layer.
- `set_color_on_layer(layer_id, global, Color, weight)` — optional albedo tint (alpha-over).
- `update_maps(TYPE_CONTROL, …)` — push the control map to the GPU once per refresh.
- `Pasture3DUtil.enc_base/enc_overlay/enc_blend/enc_uv_scale/enc_uv_rotation` + `get_*` — build/read the
  packed control uint32 from GDScript (texture ids, the 8-bit blend, uv tiling/rotation).
- `terrain.assets.get_texture_count()/get_texture_list()` — populate the material picker.

The brush reuses the **base class's O(cells) signed distance field** (`_signed_distance_field`) for the
area mask + falloff — the same machinery Mound uses — so the only new logic is "write control instead
of height." Snapshot/restore (undo), footprint clear, tool-layer sharing, and orphan/empty dock badges
are all **map-type agnostic** and work unchanged.

### Why the falloff lives in the control `blend` field
The control map encodes a **base** texture id, an **overlay** texture id, and an 8-bit **blend** (0–255)
that the shader uses to mix base→overlay. Control layers composite **topmost-covered-wins (REPLACE)**,
not arithmetically — so a *soft* material edge can't come from layer coverage. Instead it comes from the
`blend` field: inside the loop `blend = 255` (full material), feathering to `0` at the rim (underlying
base texture shows). This is exactly how the built-in texture-paint tool ramps a material in
(`pasture_3d_editor.cpp`: `enc_overlay(asset_id) | enc_blend(blend*255)`).

---

## 3. Inspiration (other painting software) — and the Godot fit

- **Substance Painter** — a stack of material layers, each with a **mask** you paint; the mask decides
  where the material shows. → Our spline is a *procedural mask with feather*; the material layer is a
  Pasture3D control layer. ([masks for multilayer material](https://assettocorsamods.net/threads/masks-for-multilayer-material-with-substance.2304/))
- **World Machine / Gaea** — terrain **selectors/masks** (height, slope, area) feed a *Splat Converter*
  that weights the splatmap. → Our area-spline is an authored selector for a splat material.
  ([World Machine splat workflow](http://www.world-machine.com/learn.php?page=workflow&workflow=wfunity))
- **Photoshop / Krita / Affinity** — a **clipping mask + feathered selection + pattern fill**: a shape
  masks a tiling fill with a soft edge. → spline = vector mask with feather; material = the tiling fill.
- **Terrain3D paint tool** — the overlay-id + blend control encoding we reuse.

**Godot paradigm:** ship it as a `@tool class_name` node that paints a non-destructive typed layer via
the bound Tool API — identical in shape to Mound/Ridge/Trough, picking the material from the project's
`Pasture3DAssets`. No new editor singletons, no rebuild — consistent with everything already built.

---

## 4. Design

### 4.1 Node `Pasture3DSplat` (closed-loop spline, like Mound)

Extends `Pasture3DTerrainBrush`; closed loops (`_min_points() = 3`); reuses Mound's polygon + SDF setup
(factor `_polygon_xz` + the SDF grid boilerplate into a shared base helper, or duplicate the ~10 lines).
Default layer name `"Detail"`; map type **TYPE_CONTROL**.

```gdscript
@export_group("Material")
@export var material: int = 0            # overlay texture id to apply (picker: see §4.4)
@export var strength: float = 1.0        # max blend at the centre (0..1 -> blend 0..255)
@export var uv_scale: int = 0            # control uv-scale bucket (texture tiling density), 0 = default
@export var uv_rotation: int = 0         # control uv-rotation bucket
@export var preserve_base := true        # feather to the underlying base texture (vs to `material` itself)

@export_group("Mask")
@export var falloff_width: float = 10.0  # metres from the loop edge over which the material fades in
@export var falloff_curve: Curve         # optional; default smoothstep
@export var edge_offset: float = 0.0     # expand/contract the masked area
@export var noise: FastNoiseLite         # optional break-up of the mask edge (natural patches)
@export var noise_strength: float = 0.0

@export_group("Tint (optional)")
@export var paint_color := false         # also write an albedo tint into a COLOR layer
@export var color := Color(1,1,1,1)
```

### 4.2 Rasterisation (`_paint_spline`)

Same SDF as Mound, but writing control instead of height:
1. Decimate the loop, build the **signed distance field** (`_signed_distance_field`) over the footprint
   grid (O(cells)). Positive inside = metres from the edge.
2. For each cell with `signed_d + edge_offset > 0`:
   - `t = clamp((signed_d + edge_offset) / falloff_width, 0, 1)`, shaped by `falloff_curve`
     (+ optional `noise` jitter on `t`).
   - `blend_int = int(round(clamp(t * strength, 0, 1) * 255))`; skip if 0.
   - Read the underlying control after the clear: `cur = terrain.data.get_control(pos)`.
   - `base_id = preserve_base ? Pasture3DUtil.get_base(cur) : material`.
   - `ctrl = enc_base(base_id) | enc_overlay(material) | enc_blend(blend_int)
            | enc_uv_scale(uv_scale) | enc_uv_rotation(uv_rotation)` (preserve hole/nav/auto bits from `cur`).
   - `terrain.data.set_control_on_layer(layer_id, pos, ctrl, 1.0)` (coverage 1; the *gradient* is in
     `blend_int`).
   - If `paint_color`: `terrain.data.set_color_on_layer(color_layer_id, pos, color, t)` (alpha-over feather).

`get_control` reads the **composited** control; because the base refresh **clears this layer's footprint
first** (region recomposited), the read returns the *underlying* control — so re-baking is idempotent
and the feather always melts into what's actually beneath, not into the brush's own previous paint
(the same "read after clear" principle as the height climbing fix).

### 4.3 Base-class generalisation (small)

`Pasture3DTerrainBrush` is currently height-only in three spots — generalise by map type:
- Add `func _map_type() -> int: return PASTURE_3D_MAPTYPE_HEIGHT` (height subclasses keep the default;
  Splat returns `TYPE_CONTROL = 1`).
- `_ensure_layer_for` → `create_owned_layer_typed(owner, name, blend, _map_type())` (height delegates
  fine; the existing `create_owned_layer` is just the height shortcut).
- `update_maps(...)` calls → `update_maps(_map_type())`.
- Add base helpers `_paint_control(pos, control, weight)` / `_paint_color(pos, color, weight)` mirroring
  `_paint_height` (fall back to destructive `set_control`/`set_color` when no layer).
- Snapshot/restore, `clear_layer_in_area`, tool-layer sharing, surface-snap, and the dock badges already
  ignore map type → no change.

(If `paint_color`, Splat owns a *second* reserved COLOR layer, `owner_id + "#color"`, exactly as the
road connector owns a separate control "holes" layer.)

### 4.4 Material picker (inspector)

Expose `material` as a dropdown of texture names via `_get_property_list` (same pattern as the
`tool_layer` dropdown): read `terrain.assets.get_texture_list()` for names; an INT enum mapping to the
texture id. Falls back to a plain int spinner if assets are unset.

---

## 5. Caveats & notes

- **REPLACE compositing:** writing the overlay replaces any *underlying overlay* the terrain had there;
  v1 preserves the **base** texture and feathers base→material via `blend`. Blending against an existing
  *overlay* (true 3-way) is out of scope (the control map only holds base+overlay+blend).
- **Tiling:** the material tiles via the shader's UV; `uv_scale`/`uv_rotation` set the tiling bucket per
  pixel — "tiles within the bounds" is automatic, the spline only masks *where*.
- **Layer stacking:** control layers are independent of height layers (different map type), so a Splat
  layer composites over hand-painted control and other splat layers by stack order (topmost-covered-wins).
- **Sharing & health:** Splat layers are brush-owned reserved layers, so tool-layer sharing-by-name,
  layer-granular refresh, and the orphaned/empty dock badges all apply unchanged.
- **Auto-shader bit:** if the terrain uses auto-shader, decide whether painting clears the auto bit on
  touched pixels (recommended: clear it so the manual material shows) — preserve/clear is a one-line
  choice on the encoded value.
- **Performance:** identical to Mound (O(cells) SDF); `get_control` per painted cell is one bound call,
  bounded by the footprint, same order as the height brushes' `get_height`.

---

## 6. Files touched (anticipated)

- `connectors/pasture3d_terrain_brush.gd` — `_map_type()` virtual; `_ensure_layer_for` via
  `create_owned_layer_typed`; `update_maps(_map_type())`; `_paint_control`/`_paint_color` helpers;
  (optionally) factor Mound's polygon+SDF setup into a shared `_loop_sdf(path)` helper.
- new `connectors/pasture3d_splat.gd` — `Pasture3DSplat` (closed-loop control painter), reusing the SDF.
- No C++ changes.

---

## 7. Suggested build order

1. **Base map-type generalisation** (`_map_type`, typed layer, `update_maps`, `_paint_control`) — verify
   the three height brushes are byte-identical after (regression).
2. **`Pasture3DSplat` control painting** — material id + falloff via the `blend` field; verify a loop
   paints the overlay with a feathered edge and re-bakes idempotently.
3. **Material picker dropdown** (assets texture list).
4. **Optional color tint** (second COLOR layer) and **noise** edge break-up.
5. Verify in-editor: tool-layer sharing, undo, orphan/empty badges with the new control layers.

---

## 8. Sources

- Internal: `src/pasture_3d_util.cpp` (bound `enc_*`/`get_*` control encoders), `src/pasture_3d_data.cpp`
  (`create_owned_layer_typed`, `set_control_on_layer`, `set_color_on_layer`, `get_control`,
  `update_maps`), `src/pasture_3d_editor.cpp` (texture-paint control encoding to mirror),
  `PASTURE3D_LAYERS_GUIDE.md` §7 (typed layers), `connectors/pasture3d_mound.gd` (SDF loop to reuse).
- [Substance multilayer material masks](https://assettocorsamods.net/threads/masks-for-multilayer-material-with-substance.2304/)
- [World Machine splatmap workflow](http://www.world-machine.com/learn.php?page=workflow&workflow=wfunity)
- [Frostbite procedural shader splatting (terrain material masking)](https://www.slideshare.net/slideshow/terrain-rendering-in-frostbite-using-procedural-shader-splatting-presentation/916086)
</content>
