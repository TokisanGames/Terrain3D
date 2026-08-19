# Implementation Spec: Brush Placement Tool (click-to-place landscape brushes)

Status: Draft (spec only — no code changed)
Author: investigation pass, 2026-06-22
Scope: Pasture3D (Terrain3D fork, Godot 4.7 GDExtension). Editor plugin / landscape tools.
Related: `PASTURE3D_LANDSCAPE_TOOLS_SPEC.md`, `PASTURE3D_BRUSH_GIZMO_SPEC.md`, `.claude/specs/per-stroke-undo-spec.md`

---

## 1. Problem statement

### Current behavior
Landscape brushes (`Pasture3DMound` / `Pasture3DRidge` / `Pasture3DTrough`, all subclasses of
`Pasture3DTerrainBrush` — `project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd`) are non-destructive
spline nodes parented under a `Pasture3D` terrain. To add one today the user must:

1. Manually add the node in the Scene dock (or instance `project/PastureToolNodes.tscn`),
2. Reparent it under the terrain,
3. Drag the node into roughly the right spot, and
4. Edit its starter spline into place.

There is no way to drop a brush *at a point on the terrain you click*.

### Desired behavior
A viewport tool — selectable like the sculpt/paint tools — that, when active, **does not sculpt**.
Instead, **left-clicking the terrain instantiates the currently-selected brush type and places it at the
click position**, parented under the terrain and owned by the edited scene. A selector lets the user
choose *which* brush type to place (Mound / Ridge / Trough, extensible). The whole placement — the new
node **and** its initial terrain bake — must be **one** undo step: a single Ctrl+Z removes the node and
returns the terrain to exactly its pre-placement state; Ctrl+Y (redo) re-places it identically.

---

## 2. How the system works today (grounded references)

### 2.1 Tool selection & viewport input
- The toolbar (`src/toolbar.gd`) builds toggle buttons that emit
  `tool_changed(tool: Pasture3DEditor.Tool, op: Pasture3DEditor.Operation)` (`toolbar.gd:5`,
  `:153-166`). Every existing tool maps to a **C++** `Pasture3DEditor.Tool` enum value — i.e. the
  built-in tools are all terrain-editing tools driven by the native editor.
- `Pasture3DUI._on_tool_changed` (`src/ui.gd:155`) reacts to the toolbar, shows the relevant
  `tool_settings` panel rows, and pushes the active tool/operation into the C++ editor.
- Viewport input is forwarded by `EditorPlugin._forward_3d_gui_input`
  (`src/editor_plugin.gd:203-306`). The dispatch order today is:
  1. **Selected-brush branch** — `_current_brush()` (`editor_plugin.gd:310-314`) returns the selected
     `Pasture3DTerrainBrush`; if non-null, `_forward_brush_input` (`:320-375`) handles loop-point
     add/remove and **takes over input** (sculpt is skipped). This is the existing precedent for an
     editor-side, GDScript-only viewport interaction that is *not* a C++ tool.
  2. **Sculpt/paint branch** — only when `is_terrain_valid()` and no brush is selected. Ray is built
     from `project_ray_origin` / `project_ray_normal`, then `terrain.get_intersection(camera_pos,
     camera_dir, true)` gives the world hit point `mouse_global_position` (`:236-250`), and mouse
     down/drag/up drive `editor.start_operation` / `operate` / `stop_operation` (`:297-304`).

The ray→surface-hit recipe we need is already written twice — the sculpt path (`:234-250`) and the
brush-input path (`_forward_brush_input` `:338-358`). The placement tool reuses it verbatim.

### 2.2 How a brush is created / parented today
- `Pasture3DTerrainBrush.add_spline()` (`pasture3d_terrain_brush.gd:1367-1378`) is the canonical "create a child
  node and make it persist" pattern: `add_child(path)` then `path.owner = get_tree().edited_scene_root`
  so the node saves with the scene, then `refresh()`.
- On entering the tree a brush **auto-targets its terrain** and **auto-binds a layer**:
  - `_ready` (`pasture3d_terrain_brush.gd:128-162`): joins `BRUSH_GROUP`, and if `terrain == null` walks up to the
    nearest `Pasture3D` ancestor and assigns it (`:141-144`). `_layer_owner` defaults to
    `"pasture3d_brush:" + _default_layer_name()` (`:129-130`) — e.g. `"Mounds"` (`pasture3d_mound.gd:49-50`),
    so a freshly placed brush auto-shares the type's layer.
  - `NOTIFICATION_PARENTED` → `_auto_assign_terrain()` (`:173-178`, `:183-188`) follows a reparent.
- Painting is **non-destructive and deterministic**: a brush's terrain contribution is a pure function
  of its splines (curve + `global_transform`) + params + its layer-mates. `refresh()`
  (`pasture3d_terrain_brush.gd:482-485`) repaints; auto-refresh (`_schedule_refresh`, debounced
  `REFRESH_DELAY = 0.1s`, `:410-445`) fires on edits.
- `_detach_from_current()` (`pasture3d_terrain_brush.gd:204-211`) **lifts this brush's contribution off its layer
  and repaints the overlapping layer-mates** so no hole is punched. It is the existing, tested inverse
  of a bake. (Today it is called on terrain re-assignment / reparent only — see §6.1.)

### 2.3 Undo/redo facilities available
- The plugin exposes the editor undo manager via `get_undo_redo()` → `EditorUndoRedoManager`
  (used by the wrappers `create_undo_action`/`add_*_method`/`commit_action`, `editor_plugin.gd:604-621`).
  Brushes use `EditorInterface.get_editor_undo_redo()` directly (`pasture3d_terrain_brush.gd:981-984`).
- The brush bake records its own undo when (and only when) asked: the **Refresh** button calls
  `refresh(true)` which snapshots the layer tiles before/after and registers
  `_restore_owner(owner, before/after)` as the undo/do (`pasture3d_terrain_brush.gd:478-539`,
  `_snapshot_owner`/`_restore_owner` `:988-1009`). Auto-refresh deliberately does **not** record undo
  because its *cause* (a gizmo/inspector edit) is already undoable and re-triggers auto-refresh on undo.
- Node add/remove with undo is the standard `EditorUndoRedoManager` pattern: `add_do_method(parent,
  "add_child", node)` + `add_do_reference(node)` + `add_undo_method(parent, "remove_child", node)`.
  `add_do_reference` keeps the detached node alive while the action sits in the undone state.

---

## 3. Design

### 3.1 The placement tool is a plugin-side pseudo-tool (not a C++ `Pasture3DEditor.Tool`)
Placement never touches the native sculpt pipeline, so — exactly like the selected-brush loop-point
editing — it lives entirely in GDScript and is gated **before** the sculpt branch in
`_forward_3d_gui_input`. We add a plugin flag rather than a new C++ enum value:

```gdscript
# editor_plugin.gd
var placement_mode: bool = false            # true while the Place-Brush tool is active
var placement_brush_type: String = "Pasture3DMound"  # class_name of the brush to place
```

When `placement_mode` is on we also force the native editor to a no-op tool so a stray click can never
sculpt: `editor.set_tool(Pasture3DEditor.TOOL_MAX)` (mirrors `_clear()` at `editor_plugin.gd:188`).

### 3.2 Brush-type registry (the "which brush" selector)
A small ordered registry, defined once so the UI and the placement code agree, and easy to extend when
new `Pasture3DTerrainBrush` subclasses are added:

```gdscript
# A label, the class_name, and the icon already shipped for that brush.
const PLACEABLE_BRUSHES := [
    { "label": "Mound",  "class": "Pasture3DMound",  "icon": "res://addons/pasture_3d/icons/brush_mound.svg" },
    { "label": "Ridge",  "class": "Pasture3DRidge",  "icon": "res://addons/pasture_3d/icons/brush_ridge.svg" },
    { "label": "Trough", "class": "Pasture3DTrough", "icon": "res://addons/pasture_3d/icons/brush_trough.svg" },
]
```

Each entry's icon is the one already declared with `@icon(...)` on the class (e.g. `pasture3d_mound.gd:11`), so the
toolbar/selector are visually consistent with the Scene dock. Instantiation uses
`ClassDB.instantiate(entry["class"])` (the brushes are `@tool class_name` GDExtension-registered scripts,
so `ClassDB` knows them) — falling back to `load(<script path>).new()` if a registry entry is data-driven
rather than ClassDB-registered.

### 3.3 UI
Two pieces, both following existing patterns:

1. **Toolbar button** — add a new separator group "Landscape Brushes" in `toolbar.gd:_ready` with a
   single toggle button "Place Brush". Because placement is not a C++ tool, this button must **not** go
   through the normal `Tool`/`Operation` meta path; instead it emits a distinct signal (e.g.
   `placement_toggled(enabled: bool)`) that the UI/plugin routes to `placement_mode`. The button shares
   the `add_tool_group` `ButtonGroup` so selecting it visually deselects the sculpt tools (and vice
   versa — selecting a sculpt tool turns `placement_mode` off).
2. **Brush-type selector** — an `OptionButton` populated from `PLACEABLE_BRUSHES` (label + icon), shown
   in the `tool_settings` bottom panel only while the Place-Brush tool is active (the panel already
   shows/hides contextual rows per tool — `ui.gd:163-276`). Selecting an entry sets
   `plugin.placement_brush_type`. Default = first entry (Mound). Persist the last choice in editor
   settings (`plugin.set_setting("pasture3d/config/placement_brush_type", ...)`, mirroring
   `setup_editor_settings` `editor_plugin.gd:569-579`) so it survives editor restarts.

> Minimal alternative (if toolbar wiring proves awkward): expose placement entirely from the
> `tool_settings` panel — a "Place Brush" checkbox + the type `OptionButton` — and skip the toolbar
> button. The input-handling and undo design below are identical either way.

### 3.4 Viewport interaction
Add a branch at the **top** of `_forward_3d_gui_input` (after `mouse_in_main = true`, alongside the
existing `_current_brush()` branch at `editor_plugin.gd:208-210`):

```gdscript
if placement_mode and is_terrain_valid():
    return _forward_placement_input(p_viewport_camera, p_event)
```

`_forward_placement_input`:
- Ignore anything that isn't a **left mouse button press** (let camera nav / RMB pass through →
  `AFTER_GUI_INPUT_PASS`), matching `_forward_brush_input`'s gating (`editor_plugin.gd:332-333`).
- Build the ray in the camera's (possibly half-resolution) viewport space exactly as
  `_forward_brush_input` does (`:338-356`): `vp.get_mouse_position()`, halve if
  `stretch_shrink == 2`, `project_ray_origin` / `project_ray_normal`.
- `var hit := terrain.get_intersection(from, dir, true)`; bail on the miss sentinel
  (`hit.z > 3.4e38 or is_nan(hit.y)`) → `AFTER_GUI_INPUT_PASS` (same check as `:357`, `:248`).
- On a valid hit, call `place_brush_at(hit)` (§4) and return `AFTER_GUI_INPUT_STOP` so the editor
  doesn't also select/deselect on that click. Placement does **not** change the editor selection, so the
  terrain stays selected and the user can drop several brushes in a row.
- Optional polish: drive `ui.update_decal()` / a ghost preview so the user sees where the brush will
  land (out of scope for v1; note in §8).

### 3.5 Placement geometry
The brush node's **origin** is placed at the hit point; its starter spline is authored in *local* space
around the origin (e.g. Mound's `_make_starter_curve` is a ±20 m square, `pasture3d_mound.gd:71-78`), so the loop
lands centred on the click. Set `node.global_position = hit` **before** the first bake.

- For `snap_to_surface` brushes (Mound default ON — `pasture3d_terrain_brush.gd:80`, the base `_init` default),
  the points re-seat onto the surface on the first refresh anyway; placing the origin at `hit` is
  correct.
- For brushes that default `snap_to_surface = OFF` (Ridge/Trough — see memory "Ridge/Trough: default
  snap_to_surface OFF", commit c56fb59), the origin Y at `hit.y` is the right starting reference; the
  user adjusts height afterward.

---

## 4. Undo/redo design (the crux)

### 4.1 Why the naive approach is wrong
If placement only records node add/remove (`add_do_method(parent,"add_child")` /
`add_undo_method(parent,"remove_child")`), then:
- **Do:** node enters tree → auto-targets terrain → auto-refresh **bakes a footprint into the layer**
  (debounced, *not* part of the recorded action).
- **Undo:** `remove_child` fires, but nothing clears the layer → **the baked dome/ridge is stranded on
  the terrain.** `NOTIFICATION_EXIT_TREE` only does `remove_from_group` (`pasture3d_terrain_brush.gd:171-172`); it
  does **not** lift the contribution.

So the node-only action desyncs node-state from terrain-state — the same class of bug catalogued in
`.claude/specs/per-stroke-undo-spec.md`.

### 4.2 Recommended approach: one composite action, each direction a single encapsulated method
We do **not** need to snapshot layer pixels. A brush's contribution is a deterministic function of its
node state, and the codebase already has both halves of the round trip:
- **bake forward** = `node.refresh()` (synchronous, repaints the whole shared layer),
- **bake inverse** = `node._detach_from_current()` (lifts this node's footprint, repaints layer-mates).

Encapsulate each *direction* in a single plugin method so the internal ordering (add-then-bake /
detach-then-remove) is guaranteed regardless of `EditorUndoRedoManager`'s method-execution order:

```gdscript
# editor_plugin.gd
func place_brush_at(world_pos: Vector3) -> void:
    var t := get_terrain()
    if t == null:
        return
    var node := _instantiate_placement_brush()   # ClassDB.instantiate(placement_brush_type)
    if node == null:
        return
    var root := get_tree().edited_scene_root
    var ur := get_undo_redo()
    ur.create_action("Place %s" % _placement_label(), UndoRedo.MERGE_DISABLE, t)
    ur.add_do_reference(node)                                  # keep alive while undone
    ur.add_do_method(self, "_do_place_brush", t, node, root, world_pos)
    ur.add_undo_method(self, "_undo_place_brush", node)
    ur.commit_action(true)   # execute the do-method now → performs the initial placement+bake

func _do_place_brush(t: Pasture3D, node: Node3D, root: Node, world_pos: Vector3) -> void:
    if node.get_parent() == null:
        t.add_child(node)
        node.owner = root                       # persist with the scene (matches add_spline)
    node.terrain = t                            # deterministic bind (don't rely on ancestor walk)
    node.global_position = world_pos
    if node.has_method("refresh"):
        node.refresh()                          # synchronous bake into the shared layer
    # NOTE: do NOT change the editor selection here. Selecting the placed brush would hide the
    # Pasture3D toolbar (is_selected() only counts the terrain) and drop placement mode after one
    # click. Keeping the terrain selected lets the user drop several brushes in a row; they click the
    # brush (or its gizmo) afterward to edit it.

func _undo_place_brush(node: Node3D) -> void:
    if not is_instance_valid(node):
        return
    if node.has_method("_detach_from_current"):
        node._detach_from_current()             # lift footprint + repaint layer-mates (no hole)
    var p := node.get_parent()
    if p:
        p.remove_child(node)                    # add_do_reference keeps it alive for redo
```

Properties of this design:
- **Single Ctrl+Z** reverts both node and terrain: `_undo_place_brush` detaches (terrain restored) then
  removes the node. **Single Ctrl+Y** re-runs `_do_place_brush` (re-add + re-bake) — identical because
  the bake is deterministic from the node's curve/transform/params.
- **No pixel snapshots**, so it composes correctly with later edits to the same layer by *other*
  brushes (each brush re-bakes from its own state; `_detach_from_current`/`refresh` already repaint
  shared layer-mates — `pasture3d_terrain_brush.gd:204-211`, `492-539`).
- Reuses only **existing, tested** methods (`refresh`, `_detach_from_current`, `add_node`,
  `edit_node`).

### 4.3 The auto-refresh race, and how to neutralize it
`_do_place_brush` calls `refresh()` synchronously, but `add_child`/`_ready` also **queues** a debounced
auto-refresh (`_schedule_refresh`, `pasture3d_terrain_brush.gd:410-414`). The queued bake fires ~0.1 s later and
is **idempotent** (same shape → same layer), so it is *harmless* but does redundant work and could, in
theory, land after an immediate undo. Two safe options (pick A):

- **(A) Suppress auto-refresh around the scripted bake.** Set `node._suspend_auto = true` before
  `add_child`, restore after the explicit `refresh()`. `_suspend_auto` already exists for exactly this
  purpose — "Blocks auto-refresh while we mutate curves programmatically" (`pasture3d_terrain_brush.gd:110`,
  honoured by `_can_auto_refresh` `:404-405`). Note `_ready` may re-enable scheduling paths, so set it
  again immediately after `add_child` returns and clear it only after the manual `refresh()`.
- **(B) Do nothing** and rely on idempotency. Acceptable, but a stray late bake after a fast undo is a
  (benign) repaint of an empty layer. Prefer (A).

### 4.4 Interaction with the latent "delete strands footprint" bug (recommended companion fix)
The undo path above relies on `_detach_from_current()` being the correct inverse of a bake. The same
gap that makes naive undo wrong **also affects plain node deletion**: pressing Delete on a placed brush
(or cutting it) removes the node via `EXIT_TREE`, which today does **not** lift its contribution
(`pasture3d_terrain_brush.gd:171-172`) — so the footprint is stranded until the next full layer refresh.

Recommended companion change (small, general): in `Pasture3DTerrainBrush`, lift the contribution when
the node is **deleted** (not merely reparented). Reparent is an EXIT+ENTER pair and must *not* clear, so
key off predelete rather than EXIT_TREE:
```gdscript
func _notification(what):
    ...
    elif what == NOTIFICATION_PREDELETE:
        if Engine.is_editor_hint() and is_configured():
            _detach_from_current()
```
This makes Delete behave like undo-of-placement and keeps the layer consistent. It is **optional** for
the placement feature (the placement undo handles its own case explicitly) but closes the same desync
for hand-deletion. Verify it does not double-fire with the placement undo path (predelete on a node that
was already detached + removed is a no-op because `is_inside_tree()` is false — `_detach_from_current`
guards on `is_inside_tree()` at `:205`).

---

## 5. Detailed implementation steps (ordered)

1. **`editor_plugin.gd`** — add `placement_mode`, `placement_brush_type`, the `PLACEABLE_BRUSHES`
   registry (§3.2), and `_instantiate_placement_brush()` / `_placement_label()` helpers.
2. **`editor_plugin.gd` `_forward_3d_gui_input`** — add the placement branch at the top (§3.4) and
   implement `_forward_placement_input` (ray → hit → `place_brush_at`).
3. **`editor_plugin.gd`** — implement `place_brush_at`, `_do_place_brush`, `_undo_place_brush` (§4.2),
   with auto-refresh suppression (§4.3 option A).
4. **`toolbar.gd`** — add the "Landscape Brushes" separator + "Place Brush" toggle button and a
   `placement_toggled` signal (§3.3 item 1); ensure it joins `add_tool_group` so it is mutually
   exclusive with sculpt tools.
5. **`ui.gd`** — route `toolbar.placement_toggled` to `plugin.placement_mode` (and force
   `editor.set_tool(TOOL_MAX)` while on); in `_on_tool_changed`, when a normal tool is chosen, set
   `plugin.placement_mode = false`. Add the brush-type `OptionButton` to `tool_settings` and show it
   only for the Place-Brush tool (§3.3 item 2); wire its selection to `plugin.placement_brush_type` +
   editor-settings persistence.
6. **(Optional companion)** `pasture3d_terrain_brush.gd` `_notification` — add the `NOTIFICATION_PREDELETE`
   detach (§4.4).
7. **Icons/strings** — reuse the per-class `@icon` svgs already in `icons/`.

No C++ changes. No save/load format changes.

---

## 6. Edge cases

- **No terrain / no regions.** `place_brush_at` bails if `get_terrain()` is null. If the terrain has no
  regions, `get_intersection` returns the miss sentinel and the click is ignored — same as sculpt. The
  brush's own `_get_configuration_warnings` (`pasture3d_terrain_brush.gd:214-227`) then prompts the user.
- **Click misses the terrain** (sky / hole). Sentinel check → `AFTER_GUI_INPUT_PASS`, no node created,
  no empty undo entry committed.
- **Layer sharing.** A placed Mound auto-binds the `"Mounds"` layer and shares it with existing mounds
  (`_tools_on_owner` `:725-733`). `refresh()`/`_detach_from_current()` already repaint shared
  layer-mates, so placement/undo near another brush does not wipe the neighbour (the road-connector
  partial-refresh hazard is handled by the existing layer-granular refresh).
- **Undo ordering.** Each direction is a single method call (`_do_place_brush` / `_undo_place_brush`),
  so we never depend on `EditorUndoRedoManager`'s do-/undo-method execution order. `add_do_reference`
  keeps the removed node alive between undo and redo.
- **Scene ownership / save.** `node.owner = edited_scene_root` (matches `add_spline` `:1373-1376`) so
  the placed brush persists on save. Undo removes it from the tree before any save would capture it.
- **Multi-camera / split-screen & half-resolution viewport.** The ray uses the forwarded
  `p_viewport_camera` and the `stretch_shrink == 2` halving, identical to the sculpt and brush-input
  paths, so placement works in every editor viewport.
- **Placement while a brush is already selected.** The existing `_current_brush()` branch runs first
  and would intercept Ctrl-click as loop-point add. Decide precedence: recommended — when
  `placement_mode` is on, it wins (check it *before* `_current_brush()`), and a normal left-click
  places a new brush rather than editing the selected one. Document this so the two don't surprise each
  other.
- **Redo after editing the placed brush, then undoing past the placement.** Standard
  `EditorUndoRedoManager` semantics: editing the brush (gizmo/inspector) creates later actions; undoing
  back through them and then through the placement removes the node cleanly because each later action's
  own undo runs first.
- **Rapid repeated placement.** Each click is its own committed action (MERGE_DISABLE), so N clicks =
  N separate undo steps. Acceptable and expected.

---

## 7. Testing / verification plan

### 7.1 Manual (in-editor) — definitive
1. Open `project/demo/sculpting_demo.tscn` (or any scene with a `Pasture3D` that has regions). Select
   the terrain so the Pasture3D UI is visible.
2. Activate **Place Brush**; pick **Mound** in the type selector. Left-click the terrain → a
   `Pasture3DMound` appears centred on the click, parented under the terrain, with a baked dome.
3. **Ctrl+Z once** → the node disappears **and** the terrain returns to flat/base (no stranded dome).
   **Ctrl+Y once** → the node and the identical dome return.
4. Place a second Mound overlapping the first. Undo the second → the first's dome must remain intact
   (layer-mate repaint). Redo → both present.
5. Switch the selector to **Ridge**, then **Trough**; place each; confirm the correct class is created
   (Scene dock) and the right starter shape/defaults (Ridge/Trough `snap_to_surface` OFF).
6. Select a placed brush → confirm the gizmo + loop-point Ctrl-click/right-click editing still work
   (placement mode hands off to the selected-brush path once the user switches tools).
7. **Delete** a placed brush with the Delete key → terrain footprint is removed (validates §4.4 if
   adopted; if not adopted, document that a manual layer Refresh is needed).
8. Save the scene, reload → placed brushes persist with their bakes; undo history is fresh (expected).
9. Switch to a sculpt tool → confirm `placement_mode` turns off and clicking sculpts again (no
   accidental placement).

### 7.2 Smoke (headless, optional)
A headless script can exercise the non-UI core: build a `Pasture3DData` with a region, call
`place_brush_at`-equivalent logic (instantiate brush, add under terrain, `refresh()`), assert the layer
gained tiles; call `_undo_place_brush`, assert the layer tiles return to empty and the node is detached.
This mirrors the project's existing headless test path (memory: `python -m SCons platform=windows
target=editor`, run the test scene headless).

Acceptance: one placement = one undo step that restores node + terrain exactly; redo re-creates an
identical brush + bake; overlapping/adjacent brushes are never wiped by a neighbour's place/undo.

---

## 8. Out of scope / follow-ups
- **Live ghost preview** of the brush footprint under the cursor before clicking (decal/outline).
- **Drag-to-size** on placement (click-drag to set initial radius/length instead of the fixed starter
  curve).
- **Rotation on placement** (align starter spline to camera or to slope).
- **Custom scene placement** — placing a saved `.tscn` brush preset (e.g. from `PastureToolNodes.tscn`)
  rather than a default-configured class; the registry in §3.2 can carry a `scene` path variant later.
- Adopting the §4.4 predelete detach project-wide for all `Pasture3DTerrainBrush` deletions.

---

## 8b. Revision — in-editor feedback (2026-06-22)
First in-editor pass worked; these refinements followed:
- **Brush-type picker moved to the bottom tool-settings bar** (not the left toolbar). Built in
  `tool_settings.gd` (`build_placement_selector` reads `toolbar.PLACEABLE_BRUSHES`), kept out of the
  `settings` dict so the normal show/hide/get flow ignores it; shown only while Place Brush is active.
- **Unique node names**: placed brushes are named `Mound`, `Mound1`, `Mound2`… via
  `_unique_child_name(terrain, label)` set before `add_child(node, true)` (the `true` =
  force_readable_name, so a collision no longer falls back to `@Node3D@<id>`).
- **Auto starter spline**: `_do_place_brush` calls the brush's `add_spline()` on first placement (guarded
  by "has no spline yet" so redo doesn't add a second one — a detached node keeps its children).
- **New Select Brush tool** below Place Brush: a toggle that, on click, picks the nearest brush by
  screen distance to its origin (`_pick_brush_screen` over the `pasture3d_brush` group), selects it via
  `EditorInterface.edit_node`, and turns itself off so the brush's loop points are immediately editable.
- **Accurate surface placement (raycast fix)**: placement/loop-add now call `get_intersection(from, dir,
  false)` — the **CPU raymarch** — instead of `true` (GPU). The GPU path renders a SubViewport
  `UPDATE_ONCE` and reads it the *same* frame, so a one-shot click read stale depth and the brush landed
  far from the cursor and tens of metres below ground. The raymarch is synchronous/exact; placement then
  pins the origin Y to `data.get_height(hit.xz)` so the brush sits exactly on the surface.
- **Cursor crosshair**: while Place Brush is active, mouse motion shows a reticle-only decal at the
  surface point under the cursor (`ui.show_placement_decal`, mirroring the picking decal: `part=[false,
  true]`). Placement skips the normal `update_decal` path, so it pushes the shader params itself.
- **No C++ tool parking**: the mode flags are checked ahead of both the sculpt path and `update_decal`,
  so an intercepted click can't sculpt and the old decal isn't refreshed — parking was removed to avoid
  fighting `set_active_operation`. Place/Select share a `ButtonGroup` with `allow_unpress = true`; the
  exit-to-sculpt path is guarded to fire only when neither mode is active (a Place↔Select switch emits a
  stray `toggled(false)` on the deselected button).
- **Plow + Splat added** to `PLACEABLE_BRUSHES` (now Mound/Ridge/Trough/Plow/Splat), each with their
  existing connector script + `brush_*.svg` icon.
- **Per-type vertical (Y) offset**: each `PLACEABLE_BRUSHES` entry carries an `offset` default (Ridge 20,
  Trough -10, Mound/Plow/Splat 0). The bottom-bar selector row now has a `Y Offset` `EditorSpinSlider`
  next to the type picker; switching brush type resets it to that type's default (`placement_offset_changed`
  → `plugin.placement_y_offset`). `place_brush_at` adds the offset to the surface hit's Y *before* the undo
  action is created, so it's baked into the captured world position and undo/redo restore it cleanly.

## 9. Files & key integration points
- `project/addons/pasture_3d/src/editor_plugin.gd` — `_forward_3d_gui_input` dispatch (`:203-306`),
  new placement state + `place_brush_at` / `_do_place_brush` / `_undo_place_brush`, undo via
  `get_undo_redo()` (`:604-621`).
- `project/addons/pasture_3d/src/toolbar.gd` — new toggle button + `placement_toggled` signal
  (`_ready` `:34-101`, `add_tool_button` `:104-139`).
- `project/addons/pasture_3d/src/ui.gd` — tool-change routing (`_on_tool_changed` `:155-279`),
  `tool_settings` selector row.
- `project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd` — reused: `refresh` (`:482`),
  `_detach_from_current` (`:204`), `_suspend_auto` (`:110`), `add_spline` ownership pattern (`:1367`);
  optional `_notification` predelete detach (`:164`).
- No changes to C++ (`src/`), the layer/compositor, or the save format.
