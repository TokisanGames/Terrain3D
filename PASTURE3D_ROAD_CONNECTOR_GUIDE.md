# Pasture3D Road Connector — Investigation & Implementation Guide

> Goal: Let users of **[godot-road-generator](https://github.com/TheDuckCow/godot-road-generator)**
> flatten/cut **Pasture3D** terrain under generated roads, by shipping a
> **Pasture3D Road Connector** node inside the Pasture3D addon that can be used in
> place of the road-generator's bundled `RoadTerrain3DConnector`.

---

## 1. How the Road Generator's Terrain3D connector works

Source studied: `addons/road-generator/connectors/terrain3d_road_connector.gd`
(`@tool class_name RoadTerrain3DConnector extends Node`).

### 1.1 Role
It is a **bridge node**. It holds a reference to:
- a **`RoadManager`** (from the road-generator addon), and
- a **terrain** node (typed loosely as `Node3D`, but expected to be a `Terrain3D`).

When roads change, it edits the terrain heightmap so the ground conforms to the
road surface (and, optionally, punches collision/render holes under the road
with "Bake Holes").

It is **not** registered via `add_custom_type`. It becomes available in the
editor's *Create New Node* dialog purely because it declares a global
`class_name`. Users add it to their scene, then assign the two `@export`
references in the inspector.

### 1.2 Exported configuration
| Export | Type | Purpose |
|---|---|---|
| `terrain` | `Node3D` (really Terrain3D) | the terrain to flatten; setter re-wires signals |
| `road_manager` | `RoadManager` | source of road update signals |
| `auto_refresh` | `bool` | live-update terrain while editing roads |
| `offset` | `float` (-0.25) | vertical sink to avoid z-fighting (road sits above terrain) |
| `edge_margin` | `float` (0.5) | extra flattening beyond road edge, in meters |
| `edge_falloff` | `float` (2) | smoothing distance from margin back to natural terrain |
| `flatten_terrain_method` | enum | `APPROXIMATE` / `RAYCAST` / `BOTH` |
| `raycast_layer` | physics layer flags | layer used for editor raycasting of the road mesh |

### 1.3 Event/refresh flow
1. `configure_road_update_signal()` connects to `RoadManager` signals
   `on_road_updated(segments)` and `on_container_transformed(container)`
   (only when `auto_refresh` and only in the editor — `Engine.is_editor_hint()`).
2. `_on_manager_road_updated` / `_on_container_transform` accumulate affected
   `RoadSegment`/`RoadIntersection` nodes into `_pending_updates`, debounced by a
   `SceneTreeTimer` (`refresh_timer = 0.05s`). Updates pause while LMB is held
   (user is dragging a gizmo).
3. Pending parents are moved to `_next_refresh_parents`, then consumed in
   `_physics_process` (raycasts must run on the physics thread) which calls
   `refresh_roads()`.
4. `refresh_roads()` flattens intersections first, then road segments, then calls
   `terrain.data.update_maps(HEIGHT)` once.
5. `do_full_refresh()` (button) rebuilds geometry on every container and refreshes
   all segments. `bake_holes()` (button) carves holes via `set_control_hole`.

### 1.4 The flattening math (terrain-agnostic vs terrain-specific)
Most of the file is **pure geometry** and depends only on the road-generator API
(`RoadSegment.curve`, `RoadPoint.lane_width`, `Curve3D`, `AABB`, `Geometry2D`,
physics raycasts). That logic is **reused verbatim** for Pasture3D.

The **only** places that touch the terrain are these calls — this is the entire
coupling surface we must satisfy:

| Terrain call used by connector | Meaning |
|---|---|
| `terrain.data` | the data/storage resource (`Terrain3DData`) |
| `terrain.data.region_locations` | `Array[Vector2i]`; empty ⇒ no regions yet |
| `terrain.vertex_spacing` | float grid spacing; iteration step over X/Z |
| `terrain.data.set_height(Vector3 global, float h)` | write a vertex height |
| `terrain.data.get_height(Vector3 global) -> float` | read current height (can be NaN) |
| `terrain.data.update_maps(map_type)` | push edits to GPU/regions |
| `terrain.data.set_control_hole(Vector3 global, bool)` | hole carving for bake |

Map-type ints are hardcoded in the connector (no enum import):
`TERRAIN_3D_MAPTYPE_HEIGHT = 0`, `TERRAIN_3D_MAPTYPE_CONTROL = 1`.

---

## 2. Why this is almost trivial for Pasture3D

**Pasture3D is a fork of Terrain3D** (see [pasture3d-project] memory). The C++ API
surface the connector depends on is preserved 1:1 — only the class names changed
from `Terrain3D*` to `Pasture3D*`. Verified in this repo:

| Connector needs | Pasture3D binding | Location |
|---|---|---|
| `Terrain3D` node + `.data` | class `Pasture3D`; `data` property → `get_data()` returns `Pasture3DData` | `src/pasture_3d.cpp:1592`, `:1417` |
| `vertex_spacing` | `get_vertex_spacing` / `set_vertex_spacing` | `src/pasture_3d.cpp:1477-1478` |
| `data.region_locations` | `region_locations` property + getter | `src/pasture_3d_data.cpp:1241-1242`, `:1328` |
| `data.set_height` / `get_height` | bound identically | `src/pasture_3d_data.cpp:1288-1289` |
| `data.update_maps(map_type,…)` | bound (extra optional args, defaulted) | `src/pasture_3d_data.cpp:1281` |
| `data.set_control_hole` | bound identically | `src/pasture_3d_data.cpp:1307` |

Map-type enum values match (`TYPE_HEIGHT = 0`, `TYPE_CONTROL = 1`), so the
hardcoded `0`/`1` constants remain correct.

**Conclusion:** A Pasture3D connector is the Terrain3D connector with the terrain
class references re-pointed at `Pasture3D`. No math changes. The work is mostly
packaging, naming, and graceful-dependency handling.

> Note: Pasture3D also registers legacy aliases `Terrain3DRegion/Material/Assets/
> MeshAsset/TextureAsset` (`src/register_types.cpp:31-35`) for *resource* load
> compatibility — but **not** a `Terrain3D` node alias. So the upstream
> `RoadTerrain3DConnector` will **not** transparently accept a `Pasture3D` node as
> its `terrain` (the duck-typed `.data`/`.vertex_spacing` calls would actually
> work at runtime, but the inspector typing, warnings, and class-name discovery
> are Terrain3D-specific). Shipping our own connector is the clean path.

---

## 3. Design: `RoadPastureConnector`

### 3.1 Placement & naming
- File: `project/addons/pasture_3d/connectors/pasture3d_road_connector.gd`
- Global name: `class_name RoadPastureConnector` (proposed; avoids collision with
  upstream `RoadTerrain3DConnector`). Alternative: `PastureRoadConnector`.
- `@tool extends Node` — identical base.
- Add `pasture3d_road_connector.gd.uid` will be generated by Godot on first import.

### 3.2 Dependencies (important)
This node bridges **two addons**. It references road-generator classes
(`RoadManager`, `RoadContainer`, `RoadSegment`, `RoadIntersection`, `RoadPoint`)
and preloads two road-generator scripts:
```gdscript
const RoadSegment = preload("res://addons/road-generator/nodes/road_segment.gd")
const IntersectionNGon = preload("res://addons/road-generator/procgen/intersection_ngon.gd")
```
Therefore the connector **only functions when road-generator is also installed**.

Decision needed (see checklist): hard `preload` (script fails to load without
road-generator present, polluting the editor with errors for Pasture3D users who
don't use roads) **vs** guarded `load()` with a `_get_configuration_warnings()`
message. **Recommended:** keep the connector script *out* of the always-loaded
addon path or guard the road-generator preloads so a Pasture3D-only project does
not error. Simplest robust approach: ship it as an **opt-in** file users copy/enable,
or load road-generator scripts at runtime with existence checks.

### 3.3 What changes vs. the upstream file
1. `class_name RoadTerrain3DConnector` → `class_name RoadPastureConnector`.
2. `@export var terrain:Node3D` → `@export var terrain:Pasture3D`
   (Pasture3D's node class is available since the connector lives in its addon).
   Keeping it strongly typed gives inspector filtering + clearer warnings.
3. Comments referencing Terrain3D updated to Pasture3D.
4. Everything else (the geometry, signal wiring, refresh scheduling, hole baking)
   stays byte-for-byte equivalent. The `terrain.data.*` and `terrain.vertex_spacing`
   calls work unchanged against `Pasture3DData`.
5. Keep the hardcoded map-type ints (still 0/1) **or** switch to
   `Pasture3DData.TYPE_HEIGHT` / `TYPE_CONTROL` if those enum constants are bound
   to GDScript (verify before using; the safe, dependency-free choice is the ints).

### 3.4 Editor warnings (`_get_configuration_warnings`)
Update text and add a road-generator-presence check:
- "Road manager not assigned for terrain flattening"
- "Pasture3D terrain not assigned for terrain flattening"
- "No Pasture3D regions defined yet, add regions in Pasture3D first"
  (uses `terrain.data.region_locations.size() == 0`)
- NEW: "godot-road-generator addon not found — this connector requires it"

### 3.5 Discovery in the editor
Because it declares `class_name`, it auto-appears in *Create New Node*. Optionally
also register it through the Pasture3D `EditorPlugin`
(`project/addons/pasture_3d/src/editor_plugin.gd`) via
`add_custom_type("RoadPastureConnector", "Node", script, icon)` for an icon +
category grouping. Not required for function.

### 3.6 Godot 4.4+ tool buttons
Upstream leaves `@export_tool_button("Refresh"/"Bake Holes", …)` commented out
because it supports older Godot. Pasture3D targets **Godot 4.6** (see
[pasture3d-project]), so we can **enable** the `@export_tool_button` lines to give
inspector "Refresh" and "Bake Holes" buttons wired to `do_full_refresh` /
`bake_holes`. Verify the exact 4.6 `@export_tool_button` signature when enabling.

---

## 4. Implementation checklist

### Investigation (done)
- [x] Read upstream `terrain3d_road_connector.gd` end-to-end.
- [x] Catalog the exact terrain API the connector depends on (§1.4).
- [x] Confirm Pasture3D binds every required method/property (§2 table).
- [x] Confirm map-type ints (0/1) still valid.
- [x] Note that no `Terrain3D` *node* alias exists in Pasture3D (only resources).

### Build the connector node
- [ ] Create `project/addons/pasture_3d/connectors/pasture3d_road_connector.gd`.
- [ ] Start from a copy of upstream `terrain3d_road_connector.gd`.
- [ ] Rename `class_name` → `RoadPastureConnector`; update header/comments.
- [ ] Re-type `@export var terrain` → `Pasture3D`.
- [ ] Decide & implement road-generator dependency strategy (hard preload vs.
      guarded load + config warning). Add the "road-generator missing" warning.
- [ ] Update `_get_configuration_warnings()` / `is_configured()` text to "Pasture3D".
- [ ] Keep map-type constants as ints **or** switch to verified enum constants.
- [ ] (Optional, 4.6) Enable `@export_tool_button` Refresh / Bake Holes buttons.

### Editor integration (optional but recommended)
- [ ] In `editor_plugin.gd`, `add_custom_type(...)` for the connector with a 16px
      icon; remove it in the plugin's exit/`_disable_plugin`.
- [ ] Add an icon asset (e.g. `connectors/road_connector_icon.svg`).

### Validation
- [ ] Project with **both** addons enabled: add `RoadPastureConnector`, assign a
      `RoadManager` and a `Pasture3D` node.
- [ ] Add Pasture3D regions; build a road; confirm terrain flattens under it
      (test all three `flatten_terrain_method` values).
- [ ] Toggle `auto_refresh`; edit road points and confirm live updates + the
      LMB-drag pause behavior.
- [ ] Test `offset`, `edge_margin`, `edge_falloff` visually.
- [ ] Run "Bake Holes" / `bake_holes()`; confirm `set_control_hole` carves holes
      and `update_maps(CONTROL)` refreshes.
- [ ] Multi-region + region-boundary roads (heights cross regions correctly).
- [ ] **Pasture3D-only** project (road-generator NOT installed): confirm the addon
      still loads with no script errors (validates the dependency strategy).
- [ ] Undo/redo of road edits does not desync terrain.
- [ ] Runtime (non-editor) play: confirm signals are correctly *not* connected
      (`Engine.is_editor_hint()` guard) and nothing errors.

### Packaging / docs
- [ ] Add a short doc page (e.g. `doc/docs/road_generator.md`) + link from the
      docs index, mirroring upstream connector usage but for Pasture3D.
- [ ] Note the road-generator version tested against.
- [ ] Update `PASTURE3D_IMPLEMENTATION_PROGRESS.md` with this feature.
- [ ] Consider upstreaming: offer the connector to road-generator as a sibling of
      `terrain3d_road_connector.gd`, or keep it Pasture3D-side.

---

## 5. Key risks / open questions
1. **Cross-addon coupling.** The connector hard-references road-generator scripts.
   Must not break Pasture3D-only projects. This is the single most important design
   decision (§3.2).
2. **Enum constants.** Prefer hardcoded `0`/`1` map types unless
   `Pasture3DData.TYPE_HEIGHT`/`TYPE_CONTROL` are confirmed bound to GDScript.
3. **`update_maps` signature.** Pasture3D binds `update_maps(map_type, all_regions=true,
   generate_mipmaps=false)` — calling with a single arg is fine (defaults apply).
4. **`@export_tool_button` availability.** Confirm the 4.6 API before enabling the
   inspector buttons; otherwise expose Refresh/Bake via a small dock or leave them
   as callable methods.
5. **No `Terrain3D` node alias.** Don't assume the upstream connector "just works"
   with a Pasture3D node in the inspector — ship our own typed node.

---

## 6. Reference: minimal diff summary
> The full ~600-line connector is reused. The functional delta from upstream is small:

```gdscript
# was:
@tool
class_name RoadTerrain3DConnector
extends Node
...
@export var terrain:Node3D:   # Terrain3D

# becomes:
@tool
class_name RoadPastureConnector
extends Node
...
@export var terrain:Pasture3D:

# plus: guarded road-generator preloads, updated warning strings,
#       optional add_custom_type registration, optional 4.6 tool buttons.
# unchanged: all flatten_*/cull_*/refresh_*/curve_*/get_road_* geometry,
#            and every terrain.data.* / terrain.vertex_spacing call.
```

[pasture3d-project]: ./PASTURE3D_PLUGIN_FORK_GUIDE.md
