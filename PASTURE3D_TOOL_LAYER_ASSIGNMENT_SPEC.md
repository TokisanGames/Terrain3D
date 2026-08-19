# Pasture3D Tool–Layer Assignment Spec

**Status:** IMPLEMENTED 2026-06-18 (GDScript-only, no rebuild; 19/19 headless checks + ridge/trough
sanity pass; not yet user-verified in-editor). Target: Godot 4.7, Pasture3D `main`.
**Builds on:** the spline landscape brushes (`PASTURE3D_LANDSCAPE_TOOLS_SPEC.md`,
`connectors/{terrain_brush,mound,ridge,trough}.gd`) and the non-destructive Layers feature
(`PASTURE3D_LAYERS_GUIDE.md`).
**Expected scope:** GDScript-only (brush base + `layers_dock.gd`); **no engine rebuild** — confirmed
the required layer APIs (`create_owned_layer` idempotent by owner, `set_owner_id`/`get_owner_id`,
`is_reserved`/`set_reserved`, `get_layer_name`, `get_region_tile_count`, `covered_region_bounds`) are
all already bound.

---

## 1. Goal

Change how the spline tools (`Pasture3DMound`, `Pasture3DRidge`, `Pasture3DTrough`) bind to
non-destructive layers, and surface problems with tool layers. Five requirements:

1. **Auto-attach by name** — a tool should attach to an existing layer that matches its tool/layer
   name instead of always creating a brand-new layer. (Today every node makes its own layer, so three
   mounds produce three separate "Mounds" layers.)
2. **"Add New Layer" button** in the inspector (for each tool) that creates a new layer **named after
   the node** and assigns this node to it.
3. **Assign-to-layer dropdown** in the inspector so a node can be pointed at any existing tool layer.
4. **Orphaned-tool-layer notification** — the editor flags tool layers that no tool node targets.
5. **Empty-layer warning** — as a fallback / additional signal, flag layers that hold no data.

---

## 2. Current behaviour (what changes)

`Pasture3DTerrainBrush._ensure_layer()` calls
`create_owned_layer(_owner_id(), target_layer_name, blend)` where `_owner_id() = str(get_path())` —
**unique per node**. Because `create_owned_layer` is idempotent *by owner_id*, each node gets its own
reserved layer (all coincidentally named "Mounds"/"Ridges"/"Troughs"). There is no sharing, no
reassignment UI, and deleting a node silently leaves its layer behind.

---

## 3. Design

### 3.1 Layer identity = the layer name (the key idea)

Make the layer's **owner_id a pure function of the target layer name**, with a brush namespace prefix:

```
const BRUSH_OWNER_PREFIX := "pasture3d_brush:"
func _owner_id() -> String:
    return BRUSH_OWNER_PREFIX + target_layer_name
```

Because `create_owned_layer(owner_id, name, blend)` is **idempotent by owner_id**, two nodes that
share a `target_layer_name` now resolve to the **same** layer automatically — requirement 1 falls out
of the existing API with no new C++:

- Node A (`target_layer_name = "Mounds"`) → `create_owned_layer("pasture3d_brush:Mounds", "Mounds", …)`
  → creates the layer.
- Node B (`target_layer_name = "Mounds"`) → same owner_id → **returns the same layer**.

Benefits:
- **Rename-safe binding:** the binding key is the owner_id, not the displayed name. Renaming the layer
  row in the Layers dock does **not** break the tools pointing at it (owner_id is unchanged). The
  dropdown (§3.3) shows the layer's *current* display name.
- **Brush-layer tag:** any reserved layer whose `owner_id` starts with `pasture3d_brush:` is a brush
  tool layer. This distinguishes brush layers from the road connector's reserved layers (which use a
  node-path owner) and from hand-painted layers (not reserved), enabling §3.5 detection.

`_ensure_layer()` keeps the same shape, just with the new `_owner_id()`. Undo's
`find_layer_by_owner(_owner_id())` (in `_resolve_layer`) stays correct.

> **Map type:** all three tools are height layers today, so the dropdown lists height brush layers and
> sharing is unrestricted. Keep `create_owned_layer` (height); if a tool later authors control/color
> it would use `create_owned_layer_typed` and the dropdown would filter by map type.

### 3.2 `target_layer_name` is the assignment, with a live setter

`target_layer_name` becomes the single source of truth for "which layer this node paints into".
Give it a setter that **re-binds**: clear this node's contribution from the OLD layer and repaint into
the NEW one.

```
@export var target_layer_name := "Mounds":
    set(v):
        if v == target_layer_name: return
        var old := target_layer_name
        target_layer_name = v
        _rebind_layer(old)      # refresh old layer (now without us) + bake into the new one
```

`_rebind_layer(old_name)` (editor only): trigger a refresh of the old layer's remaining tools (so our
footprint is cleared from it) and a normal refresh of this node into the new layer (§3.4).

### 3.3 Inspector: assign-to-layer dropdown + "Add New Layer" button

**Dropdown (requirement 3).** Surface `target_layer_name` as a **string ENUM** whose options are the
live brush-layer names, via `_get_property_list()` on the base:

```
func _get_property_list() -> Array:
    var names := _existing_brush_layer_names()        # scan stack: reserved + owner prefix
    if not target_layer_name in names: names.append(target_layer_name)  # keep current value valid
    return [{
        "name": "target_layer_name",
        "type": TYPE_STRING,
        "hint": PROPERTY_HINT_ENUM,
        "hint_string": ",".join(names),
        "usage": PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR,
    }]
```

(Drop the plain `@export` on `target_layer_name` so it isn't declared twice; the backing `var`
remains and Godot get/sets it by name. The setter in §3.2 still runs.) Selecting a different layer
reassigns + re-bakes.

**"Add New Layer" button (requirement 2).** A tool button on each subclass:

```
@export_tool_button("Add New Layer") var _add_layer_btn = add_new_layer

func add_new_layer() -> void:
    target_layer_name = _unique_brush_layer_name(name)   # node's name, de-duplicated
    # setter → _rebind_layer → creates "pasture3d_brush:<name>" and bakes into it
```

- Uses the **node's name** (`name`) for the new layer.
- `_unique_brush_layer_name(base)` appends ` 2`, ` 3`, … if a brush layer with that name already
  exists, so the button always makes a *new* layer (otherwise it would silently share an existing one).
- Assignment happens through the §3.2 setter, so the node is immediately bound + painted into the new
  layer, and the old layer is cleaned of this node.

### 3.4 Shared-layer painting correctness (refresh becomes layer-granular)

Today `_do_paint()` clears **this node's** footprints and repaints **this node's** splines. With
multiple nodes on one layer, node A's clear would wipe node B's overlapping contribution (the road
connector's "partial refresh" hazard). Fix: **refresh at layer granularity.**

- Add brush nodes to an editor group on enter-tree: `add_to_group("pasture3d_brush")`.
- `_layer_siblings()` = nodes in that group (within the edited scene) with the same
  `target_layer_name` (including self).
- A refresh of the layer = clear the **union** of all siblings' current + cached footprints, then
  repaint **every** sibling's splines, then one `update_maps`. So editing one mound repaints all
  mounds on that layer. With the O(cells) rasteriser (now ~0.06–0.23 s per bake) this is cheap for the
  handful of tools a layer realistically holds.
- Single-node layers degrade to exactly today's behaviour (siblings = {self}).

**Undo:** unchanged in mechanism — `_snapshot_layer`/`_restore_layer` already snapshot the **whole**
reserved layer's tiles, so a layer-granular refresh's before/after snapshot captures the combined
state and undo restores the whole layer correctly (§ existing undo design).

> Implementation note: factor the existing `_do_paint` into `_paint_node_into_layer(node)` and a
> `_refresh_layer()` that loops the siblings. `refresh(record_undo)` calls `_refresh_layer()`.

### 3.5 Orphaned & empty tool-layer detection (requirements 4 & 5)

Surface problems in the **Layers dock** (`layers_dock.gd`), which already has the layer list and access
to `EditorInterface.get_edited_scene_root()`.

Compute, per layer row:
- **Is a brush tool layer?** `layer.is_reserved()` and `layer.get_owner_id().begins_with("pasture3d_brush:")`.
- **Orphaned (req 4):** it's a brush tool layer **and no** `Pasture3DTerrainBrush` in the edited scene
  has `target_layer_name == layer.get_layer_name()` (search the scene root recursively, or the
  `pasture3d_brush` group). → leftover layer from deleted tools.
- **Empty (req 5):** the layer holds no data — `get_region_tile_count` is 0 across its regions
  (equivalently `covered_region_bounds` is empty). Applies to any non-base layer.

UI:
- A **warning badge** (⚠ icon + tooltip) on the affected dock row:
  - orphaned → *"Tool layer with no tools assigned — safe to delete, or assign a tool to it."*
  - empty (and not orphaned) → *"Layer is empty (nothing painted into it yet)."*
- Recompute on dock `refresh()` and when the scene tree / selection changes (the dock already
  refreshes on those hooks).

Because orphan detection **is** feasible here, requirement 4 is the primary signal and the empty-layer
check (req 5) is the documented fallback/secondary, exactly as requested.

> **Also surface on the terrain node (optional, nice-to-have):** add orphaned/empty brush-layer notes
> to `Pasture3D`'s (or a small manager's) `_get_configuration_warnings()` so the yellow ⚠ also appears
> in the Scene dock, not only in the Layers panel. Pure addition; skip if it complicates the terrain node.

---

## 4. Migration

Existing scenes (e.g. the demo bakes) currently have **per-node** layers owned by node paths. After
this change a node resolves to a name-owned layer instead, so the old path-owned layers become
**orphaned** — which the new §3.5 detection will immediately flag in the dock with a "safe to delete"
hint. No data is lost (the old layers still hold their bake until the user deletes them). No automatic
migration is required; the warning is the migration path. Optionally provide a one-click
"Reassign tools / clean up" later if it proves tedious.

---

## 5. Edge cases & open questions

- **Duplicate display names:** two distinct brush layers can share a display name only if their
  owner_ids differ, which under §3.1 can't happen for two brush layers (owner = prefix+name). A
  hand-painted (non-reserved) layer named "Mounds" is *not* hijacked — the tool creates its own
  `pasture3d_brush:Mounds` reserved layer; they coexist (two rows named "Mounds", one reserved one
  not). Acceptable; the dock badge/tag distinguishes them. Could disambiguate the brush layer's
  display name if confusing.
- **Renaming a brush layer in the dock (DECIDED):** **bind by owner_id, display the live name.** The
  node stores `_layer_owner` (`pasture3d_brush:<slug>`) as the stable binding; the inspector dropdown
  shows each brush layer's *current* display name and maps a selection back to its owner_id. Renaming a
  layer in the dock therefore never breaks the tools pointing at it, and the dropdown follows the new
  name. `_layer_owner` is the single source of truth; the old `target_layer_name` export is removed.
- **Reassign during a drag / auto-refresh storm:** the setter triggers a rebind refresh; debounce as
  the existing `_schedule_refresh` already does.
- **Cross-tool sharing:** a Mound assigned to the "Ridges" layer is allowed (both height). The dropdown
  lists all brush height layers. Fine; note in docs.
- **Group lifetime:** ensure nodes leave `pasture3d_brush` on exit-tree so deleted/cut nodes don't
  count as "assigned" for orphan detection.

---

## 6. Files touched (anticipated)

- `connectors/pasture3d_terrain_brush.gd` — `_owner_id()` → name-based; `target_layer_name` setter +
  `_get_property_list` dropdown; `_rebind_layer`; group membership; `_layer_siblings()`;
  `_refresh_layer()` (split out of `_do_paint`); `_existing_brush_layer_names`,
  `_unique_brush_layer_name`.
- `connectors/{mound,ridge,trough}.gd` — `@export_tool_button("Add New Layer") … add_new_layer`
  (or inherit a base `add_new_layer`); remove the now-superseded plain `target_layer_name` export.
- `src/layers_dock.gd` — orphaned/empty badges + tooltip; scene scan for assigned tool names.
- (optional) `Pasture3D` configuration-warning addition.
- No C++ changes expected.

---

## 7. Suggested build order

1. **Identity + sharing** (§3.1): `_owner_id()` name-based; verify two same-named tools share one layer
   and that undo still resolves. (Headless check, as in the perf/undo work.)
2. **Layer-granular refresh** (§3.4): group + siblings + `_refresh_layer`; verify two overlapping
   mounds on one layer both survive an edit of one.
3. **Dropdown + setter** (§3.2/§3.3 dropdown): `_get_property_list`; reassign re-bakes old + new.
4. **Add New Layer button** (§3.3): node-name + de-dup; immediate bake.
5. **Dock warnings** (§3.5): orphaned (primary) + empty (fallback) badges.
6. Verify in-editor on the demo scene (orphan warning should surface the old per-node layers from §4).

---

## 8. Sources / references

- Internal: `PASTURE3D_LANDSCAPE_TOOLS_SPEC.md` (brushes + the O(cells) perf rewrite + undo/blend),
  `PASTURE3D_LAYERS_GUIDE.md` (§8 Tool API), `src/pasture_3d_data.h` (`create_owned_layer` idempotent
  by owner), `src/pasture_3d_layer.cpp` (bound `set_owner_id`/`is_reserved`/`get_region_tile_count`/…),
  `project/addons/pasture_3d/src/layers_dock.gd` (existing dock + `EditorInterface.get_edited_scene_root`).
</content>
