# Upgrading the Pasture3D Road Connector to the "Guarded" Version

> **Status:** Not needed yet. The current connector
> ([`pasture3d_road_connector.gd`](project/addons/pasture_3d/connectors/pasture3d_road_connector.gd))
> uses the **hard-dependency** approach and works correctly. Keep this guide on
> hand; follow it **only if** you later need the Pasture3D addon to load cleanly
> in a project where **godot-road-generator is NOT installed**.

---

## 1. When you actually need this

Follow this guide when **any** of these becomes true:

- You want to ship/distribute the Pasture3D addon to users who may **not** have
  godot-road-generator installed.
- You see editor error spam like *"Could not resolve class RoadManager"* /
  *"Could not load script road_segment.gd"* in a project without road-generator.
- You want the Pasture3D addon to enable cleanly regardless of whether the roads
  addon is present.

If road-generator is always installed alongside Pasture3D in your projects (your
current situation), you do **not** need this. The hard-dependency version is
simpler and is the proven code path.

---

## 2. Why the current version errors without road-generator

GDScript resolves these at **parse time** (when Godot builds its global class
list at editor start). If road-generator is missing, the script fails to compile
and Godot logs errors. The current connector has two kinds of hard references:

1. **`preload(...)` constants** — fail immediately if the target path is missing:
   ```gdscript
   const RoadSegment = preload("res://addons/road-generator/nodes/road_segment.gd")
   const IntersectionNGon = preload("res://addons/road-generator/procgen/intersection_ngon.gd")
   ```
2. **Global `class_name` type references** — `RoadManager`, `RoadContainer`,
   `RoadIntersection`, `RoadPoint` (used in `@export`, typed params, typed arrays,
   `is`, and `as`). These resolve to road-generator's global class names.

> Note: `RoadSegment` and `IntersectionNGon` in the current file refer to the
> **local `const` preloads**, not global class names. `RoadManager`,
> `RoadContainer`, `RoadIntersection`, and `RoadPoint` are the **global class
> names** with no local const. The guarded version removes the parse-time
> coupling for **all** of them.

The fix has three parts:
1. Replace `preload` constants with **runtime `load()`** (guarded by existence).
2. Replace road-generator **type annotations** with `Node`/untyped.
3. Replace `is` / `as` road-generator casts with **`is_instance_of(obj, script_ref)`**.

---

## 3. Reference: exact road-generator script paths in this project

Verified present under `project/addons/road-generator/`:

| Symbol | Script path |
|---|---|
| `RoadManager` | `res://addons/road-generator/nodes/road_manager.gd` |
| `RoadContainer` | `res://addons/road-generator/nodes/road_container.gd` |
| `RoadSegment` | `res://addons/road-generator/nodes/road_segment.gd` |
| `RoadIntersection` | `res://addons/road-generator/nodes/road_intersection.gd` |
| `RoadPoint` | `res://addons/road-generator/nodes/road_point.gd` |
| `IntersectionNGon` | `res://addons/road-generator/procgen/intersection_ngon.gd` |

---

## 4. Step-by-step conversion

### Step 4.1 — Replace the preload constants with guarded runtime loads

**Remove** these two lines near the top:
```gdscript
const RoadSegment = preload("res://addons/road-generator/nodes/road_segment.gd")
const IntersectionNGon = preload("res://addons/road-generator/procgen/intersection_ngon.gd")
```

**Add** a script-reference block plus a presence flag. Put this right after the
`enum Flatten_terrain_option { ... }` block:

```gdscript
# --- Guarded road-generator dependency -------------------------------------
# These scripts live in the (optional) godot-road-generator addon. We load them
# at runtime so this connector still PARSES when that addon is absent.
const _RG_PATHS := {
	"RoadManager": "res://addons/road-generator/nodes/road_manager.gd",
	"RoadContainer": "res://addons/road-generator/nodes/road_container.gd",
	"RoadSegment": "res://addons/road-generator/nodes/road_segment.gd",
	"RoadIntersection": "res://addons/road-generator/nodes/road_intersection.gd",
	"RoadPoint": "res://addons/road-generator/nodes/road_point.gd",
	"IntersectionNGon": "res://addons/road-generator/procgen/intersection_ngon.gd",
}

# Cached Script references; null when road-generator is not installed.
static var _RoadSegmentScript: Script = _try_load("RoadSegment")
static var _RoadIntersectionScript: Script = _try_load("RoadIntersection")
static var _IntersectionNGonScript: Script = _try_load("IntersectionNGon")

static func _try_load(key: String) -> Script:
	var path: String = _RG_PATHS[key]
	if ResourceLoader.exists(path):
		return load(path) as Script
	return null

## True only when the godot-road-generator addon is available.
static func has_road_generator() -> bool:
	return _RoadIntersectionScript != null and _RoadSegmentScript != null
# ---------------------------------------------------------------------------
```

> If you reference `IntersectionNGon` only in one `is` check, you can drop its
> cached var and load it inline. The set above is complete and harmless.

### Step 4.2 — Detype the exported `road_manager`

```gdscript
# before
@export var road_manager:RoadManager:
# after
@export var road_manager:Node: # RoadManager (godot-road-generator); detyped so this file parses without that addon
```

The setter body is unchanged. `terrain:Pasture3D` stays typed — Pasture3D is
always present.

### Step 4.3 — Detype road-generator local arrays

```gdscript
# before
var _container_unset_geo: Array[RoadContainer] = []
# after
var _container_unset_geo: Array = [] # of RoadContainer

# before (inside do_full_refresh)
var restart_geo_off: Array[RoadContainer] = []
# after
var restart_geo_off: Array = [] # of RoadContainer
```

### Step 4.4 — Detype road-generator function parameters

Change every signature that names a road-generator class to `Node` (keep the old
type in a trailing comment for clarity). Affected functions:

```gdscript
func _on_container_transform(container:RoadContainer) -> void:        # -> container:Node
func flatten_terrain_via_roadsegment_raycast(segment: RoadSegment):   # -> segment:Node
func flatten_terrain_via_intersection(inter: RoadIntersection):       # -> inter:Node
func intersection_adjacent_segments(inter: RoadIntersection) -> Array:# -> inter:Node
func flatten_terrain_via_roadsegment_approx(segment: RoadSegment):    # -> segment:Node
func cull_terrain_via_roadsegment(segment: RoadSegment) -> void:      # -> segment:Node
func get_road_width(point: RoadPoint) -> float:                       # -> point:Node
func validate_segment(segment: RoadSegment) -> bool:                  # -> segment:Node
```

Example:
```gdscript
# before
func flatten_terrain_via_roadsegment_approx(segment: RoadSegment) -> void:
# after
func flatten_terrain_via_roadsegment_approx(segment: Node) -> void: # segment: RoadSegment
```

The bodies use **duck typing** (`segment.road_mesh`, `segment.curve`,
`segment.start_point`, etc.), which keeps working unchanged because the real
runtime objects still have those members.

### Step 4.5 — Replace `as RoadContainer` casts

`as` with a missing class name is a parse error. Since the cast is only a
type hint here, **drop it** (the variable is used via duck typing):

```gdscript
# before (do_full_refresh and bake_holes)
_container = _container as RoadContainer
# after
# _container is a RoadContainer (cast removed; used via duck typing)
```
There are two occurrences (in `do_full_refresh` and `bake_holes`). In
`_on_container_transform`, the parameter was already detyped in 4.4, so no `as`
cast exists there.

### Step 4.6 — Replace `is` / `as` checks in `refresh_roads`

This is the key behavioral block. Replace the global-class checks with
`is_instance_of` against the cached script refs:

```gdscript
# before
		if _seg is RoadIntersection:
			var inter := _seg as RoadIntersection
			...
		elif _seg is RoadSegment:
			segs.append(_seg)
# after
		if _RoadIntersectionScript and is_instance_of(_seg, _RoadIntersectionScript):
			var inter: Node = _seg
			...
		elif _RoadSegmentScript and is_instance_of(_seg, _RoadSegmentScript):
			segs.append(_seg)
```

And lower in the same function:
```gdscript
# before
		_seg = _seg as RoadSegment
		if not _seg:
			continue
# after
		# _seg is a RoadSegment (cast removed; used via duck typing)
		if not is_instance_valid(_seg):
			continue
```

### Step 4.7 — Replace the `IntersectionNGon` check

In `flatten_terrain_via_intersection`:
```gdscript
# before
	if not inter.settings is IntersectionNGon:
# after
	if not (_IntersectionNGonScript and is_instance_of(inter.settings, _IntersectionNGonScript)):
```

### Step 4.8 — Replace the `RoadPoint` cast in `intersection_adjacent_segments`

```gdscript
# before
	for _edge in inter.edge_points:
		var rp: RoadPoint = _edge as RoadPoint
		if rp.prior_seg:
# after
	for _edge in inter.edge_points:
		var rp: Node = _edge # RoadPoint
		if rp.prior_seg:
```

### Step 4.9 — Add a presence guard at the entry points

Stop early (cleanly) when road-generator is absent so duck-typed calls never run
against nothing. Add to `is_configured()` and `_get_configuration_warnings()`:

```gdscript
# in _get_configuration_warnings(), first check:
	if not has_road_generator():
		warnings.append("godot-road-generator addon not found — this connector requires it")
		return warnings

# in is_configured(), first check:
	if not has_road_generator():
		push_warning("godot-road-generator addon not found — this connector requires it")
		return false
```

Also guard `configure_road_update_signal()` so it no-ops without the addon (the
`road_manager` may be null/untyped):

```gdscript
func configure_road_update_signal() -> void:
	if not Engine.is_editor_hint():
		return
	if not has_road_generator():
		return
	if not is_instance_valid(road_manager):
		return
	...
```

---

## 5. Quick checklist

- [ ] Remove the two `preload` constants.
- [ ] Add the `_RG_PATHS` dict, cached `Script` vars, `_try_load`, `has_road_generator`.
- [ ] `road_manager` export retyped to `Node`.
- [ ] `_container_unset_geo` and `restart_geo_off` retyped to `Array`.
- [ ] All 8 function params naming road classes retyped to `Node`.
- [ ] Two `as RoadContainer` casts removed.
- [ ] `refresh_roads` `is`/`as` replaced with `is_instance_of` + cached refs.
- [ ] `IntersectionNGon` check uses `is_instance_of`.
- [ ] `RoadPoint` cast removed in `intersection_adjacent_segments`.
- [ ] Presence guards added to `is_configured`, `_get_configuration_warnings`,
      `configure_road_update_signal`.
- [ ] Grep the file for `Road` and `Intersection` to confirm **no** remaining
      bare global-class references survive in type positions (`: RoadX`,
      `as RoadX`, `is RoadX`, `Array[RoadX]`). Comments are fine.

---

## 6. Verification

1. **With road-generator installed:** repeat your original acceptance test —
   add the connector, assign a `RoadManager` + `Pasture3D`, build a road, confirm
   flattening + Bake Holes still behave identically to the hard-dependency
   version. Behavior must be unchanged.
2. **Without road-generator** (temporarily rename/move
   `project/addons/road-generator/` out of the project): reopen the editor and
   confirm:
   - No parse/compile errors for `pasture3d_road_connector.gd`.
   - The Pasture3D addon still enables.
   - A `RoadPastureConnector` node (if present in a scene) shows the
     "godot-road-generator addon not found" configuration warning instead of
     erroring.
3. Restore the road-generator folder.

---

## 7. Trade-offs to remember

- **You lose static type checking** on road-generator objects (duck typing
  instead). The code already relied heavily on duck typing for terrain members,
  so this is a modest, localized loss.
- **`is_instance_of` is a runtime check** — slightly more verbose than `is`, but
  equivalent in behavior and only runs per-segment, not per-vertex.
- The geometry/flattening math is **untouched** — this upgrade only changes how
  road-generator symbols are referenced, never how heights are computed.

---

## 8. Alternative approaches (not recommended, for reference)

- **Drop `class_name`** and attach the script manually instead of using the node
  creation dialog. Avoids parse-time global registration but hurts
  discoverability and still parses if loaded by anything.
- **Plugin-gated registration:** only `add_custom_type(...)` the connector from
  the Pasture3D `EditorPlugin` when `ResourceLoader.exists(road_manager_path)`.
  This hides the node but does **not** prevent parse errors of a standalone
  `class_name` script — so it must be combined with Section 4 anyway.

The Section 4 guarded conversion is the robust, self-contained solution.
