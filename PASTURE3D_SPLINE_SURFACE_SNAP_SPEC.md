# Pasture3D Spline Surface-Snap Spec

**Status:** A + B IMPLEMENTED 2026-06-18 (GDScript-only, headless-verified; not yet user-verified
in-editor). C (click-to-draw) + D (slope tilt) remain future work. Target: Godot 4.7, Pasture3D `main`.
**Builds on:** the spline landscape brushes (`PASTURE3D_LANDSCAPE_TOOLS_SPEC.md`,
`connectors/{terrain_brush,mound,ridge,trough}.gd`) and the editor plugin
(`project/addons/pasture_3d/src/editor_plugin.gd`).
**Expected scope:** GDScript-only — **no engine rebuild**. The needed APIs are already bound:
`Pasture3DData.get_height(global)`, `get_normal(global)`, and `Pasture3D.get_intersection(origin, dir)`
(the heightmap ray-march the sculpt tool already uses in `_forward_3d_gui_input`).

---

## 1. Problem

When authoring a `Pasture3DRidge` / `Pasture3DTrough` spline, the `Path3D` control points are placed on
the node's plane (Y ≈ 0), **not on the terrain surface** (spec image 1: points float over the hills).
Because Ridge/Trough default to `follow_spline_height = true`, the generated crest/bed follows those
floating points, so the result is detached from the ground and jagged (spec image 2). The user wants
the **spline points to snap to the terrain surface** while authoring.

Two distinct things are involved — the spec addresses both but they are separable:
- **Authoring (the ask):** the *visible* control points should sit on the terrain so you can see and
  place the spline on the ground.
- **Generated result:** even today, setting `follow_spline_height = false` makes the crest/bed sample
  the **per-pixel terrain height** and drape on the surface regardless of point Y — so that one
  checkbox already fixes the *bad terrain* in image 2. Snapping additionally makes
  `follow_spline_height = true` (author the exact crest height by curve Y) look right, and is the real
  fix for the *authoring* experience.

---

## 2. Feasibility — YES

Everything needed is already in the build:
- `Pasture3DData.get_height(Vector3 global) -> float` — surface height at an XZ (NaN if no region).
- `Pasture3DData.get_normal(Vector3 global) -> Vector3` — surface normal (for optional point tilt).
- `Pasture3D.get_intersection(Vector3 origin, Vector3 dir, bool) -> Vector3` — ray-marches the
  heightmap and returns the world hit; used today by `editor_plugin.gd::_forward_3d_gui_input`
  (line ~217) for sculpt picking. **No physics collider is required.**
- `editor_plugin.gd` already implements `_handles()` + `_forward_3d_gui_input()` and tracks the active
  `terrain`, mouse ray, and viewport — the exact plumbing a "draw on surface" mode needs.

External confirmation: Godot core is adding a Path3D *snap-to-colliders* option
([PR #102085](https://github.com/godotengine/godot/pull/102085),
[proposal #11650](https://github.com/godotengine/godot-proposals/issues/11650)) that snaps added/moved
points to a raycast hit instead of the camera plane — the same idea, but collider-based and requiring
gizmo work. Our heightmap ray-march is a simpler, collider-free equivalent.

---

## 3. Design

Three layers of capability, increasing in UX quality and effort. Recommend shipping **A + B** first
(small, robust, fully in the brush scripts) and treating **C** as the premium follow-up.

Shared additions on `Pasture3DTerrainBrush` (so all three tools get them):
```gdscript
@export_group("Surface")
@export var snap_to_surface: bool = false   # keep points glued to the terrain as you edit (B)
@export var surface_offset: float = 0.0     # metres above the surface to sit the points at
@export_tool_button("Snap Points to Surface") var _snap_btn = snap_points_to_surface  # (A)
```

### 3.A "Snap Points to Surface" button (on-demand)

A tool button that drops every control point of every child spline onto the terrain (+ `surface_offset`).
Mirrors the existing `Make Descend` (Trough) pattern, so it is undoable and re-bakes once:

```gdscript
func snap_points_to_surface() -> void:
    var edits := []  # [curve, index, new_local_pos]
    for path in _get_splines():
        var c := path.curve
        if c == null: continue
        for i in range(c.point_count):
            var world := path.global_transform * c.get_point_position(i)
            var h := terrain.data.get_height(Vector3(world.x, 0.0, world.z))
            if not is_finite(h): continue          # point is outside any region — leave it
            world.y = h + surface_offset
            edits.append([c, i, path.to_local(world)])
    # register as ONE undo action via the existing _set_curve_points_and_repaint do/undo helper
```

- Reuses `_set_curve_points_and_repaint(points)` (already the do/undo body for Make Descend) so the
  curve change **and** the terrain repaint live in one undoable action.
- Skips points with no region beneath them (`get_height` returns NaN there).
- Works for Mound loops too (visual clarity), Ridge/Trough crest lines (functional).

### 3.B `snap_to_surface` toggle (auto, while editing)

When enabled, the brush re-snaps points to the surface whenever the curve changes — so dragging a
point in the viewport slides it **along** the terrain (Y follows the ground) instead of floating.

- Hook the existing `curve.changed` path: in the debounced refresh, if `snap_to_surface`, run the
  same snap pass **before** painting. Guard the programmatic `set_point_position` writes with the
  existing `_suspend_auto` flag so they don't recurse into another refresh.
- Trade-off: the user gives up manual Y control on the curve handles (that is the intent); they get a
  fixed lift via `surface_offset`. Leaving the toggle off preserves today's free-Y behaviour.
- Pairs naturally with `follow_spline_height = true`: snapped points + crest-from-curve-Y = the crest
  sits exactly `crest_height` above the ground, authored where you see the points.

### 3.C Click-to-draw on the surface (premium authoring)

Extend the editor plugin so that, with a brush (or its active `Path3D`) selected and a **draw mode**
engaged, clicking the terrain adds/moves the active spline's point at the ray-march hit:

- `editor_plugin.gd::_handles()` also returns true for `Pasture3DTerrainBrush` / its `Path3D` child.
- In `_forward_3d_gui_input`, when draw mode is active and a brush spline is selected, compute the hit
  with the existing `terrain.get_intersection(camera_pos, camera_dir, true)` and:
  - **click on empty** → append a point at the hit (on the surface),
  - **drag a handle** → move the point to the hit's XZ at surface height.
  - Register each via `EditorUndoRedoManager` (`add_point` / `set_point_position`) for undo.
- **Must coexist with Godot's built-in Path3D gizmo.** Only intercept under an explicit modifier or a
  toolbar toggle (e.g. a "Draw on Surface" button in the brush, or Ctrl+Click); otherwise return
  `AFTER_GUI_INPUT_PASS` so normal Path3D point editing still works. Mirror the `_input_mode` / tool
  gating the sculpt tool already uses.
- This is the "draw the spline directly on the hills" experience and removes the floating-point
  problem at the source.

### 3.D Optional: tilt points to the slope (`get_normal`)

For Ridge/Trough banking, optionally set each curve point's **tilt** from `get_normal` at the snap
location so the cross-section leans with the hillside. Pure nicety; off by default. (Curve3D supports
per-point tilt; `sample_baked_with_rotation` already exists if we later want true oriented sampling.)

---

## 4. Edge cases & notes

- **No terrain / point outside regions:** `get_height` returns NaN there — skip those points (button)
  or skip the snap that frame (toggle). Guard `terrain`/`terrain.data` null.
- **Path3D / brush transforms:** snap in world space then convert back with `path.to_local(world)`
  (= `global_transform.affine_inverse() * world`), so a rotated/scaled brush still snaps correctly.
- **Feedback loops:** the toggle's programmatic point writes emit `curve.changed`; gate them with the
  existing `_suspend_auto` flag (already used by Make Descend) so they don't trigger a second refresh.
- **Undo:** A and C register `EditorUndoRedoManager` actions (A via `_set_curve_points_and_repaint`,
  C via `add_point`/`set_point_position`). B's snap is part of an auto-refresh, whose undoable cause is
  the user's own gizmo edit — consistent with how auto-refresh already works.
- **`get_intersection` accuracy:** it ray-marches the heightmap (the sculpt tool relies on it), so it
  reflects the *composited* surface including other layers — points snap to what the user sees.
- **Mound:** snapping helps visualize the loop but Mound height comes from `relative_to_terrain`, so
  snapping is cosmetic there; still useful and harmless.

---

## 5. Files touched (anticipated)

- `connectors/pasture3d_terrain_brush.gd` — `snap_to_surface` + `surface_offset` exports, the
  `snap_points_to_surface()` button, and the toggle hook in the refresh path (A + B).
- `connectors/{ridge,trough,mound}.gd` — nothing required (inherit the base button/exports); maybe a
  doc note that Ridge/Trough benefit most.
- (C only) `project/addons/pasture_3d/src/editor_plugin.gd` — extend `_handles` + `_forward_3d_gui_input`
  with a brush draw mode; a "Draw on Surface" toggle on the brush or a plugin toolbar button.
- No C++ changes.

---

## 6. Suggested build order

1. **A — Snap button** (smallest, immediately fixes authoring on demand; reuses Make Descend's undo).
2. **B — auto toggle + offset** (glues points while editing; one hook in the refresh path).
3. Re-verify Ridge/Trough look correct with snapped points + `follow_spline_height = true` (and note
   that `follow_spline_height = false` already drapes the result for users who don't snap).
4. **C — click-to-draw on surface** (the premium UX; editor-plugin work, coexist with Path3D's gizmo).
5. **D — slope tilt** (optional polish).

---

## 7. Sources

- Internal: `editor_plugin.gd` (`_forward_3d_gui_input` ray-march via `terrain.get_intersection`,
  `get_height`), `src/pasture_3d_data.cpp` (bound `get_height`/`get_normal`), `connectors/pasture3d_trough.gd`
  (`make_descend` / `_set_curve_points_and_repaint` undo pattern to reuse).
- [Godot Path3D snap-to-colliders — PR #102085](https://github.com/godotengine/godot/pull/102085)
- [Path3D snap-to-colliders — proposal #11650](https://github.com/godotengine/godot-proposals/issues/11650)
- [godot-road-generator Terrain3D connector (inverse: terrain→spline)](https://github.com/TheDuckCow/godot-road-generator/wiki/Using-the-Terrain3D-Connector)
</content>
