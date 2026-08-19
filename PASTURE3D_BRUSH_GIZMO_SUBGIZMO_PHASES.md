# Pasture3D Brush Gizmo — Subgizmo Build-Out Phases

**Goal (user, 2026-06-20):** build the brush gizmo out so a brush's child loops can be
selected and edited *using the same gizmo interface* while the **brush** stays selected —
"all the features of the loop gizmo," to dramatically cut the clicks needed to author maps.
Drag/snap behaviour is governed by the brush's existing **Snap to Surface** + **Surface Offset**.

Files: `project/addons/pasture_3d/src/brush_gizmo.gd` (the `EditorNode3DGizmoPlugin`),
`project/addons/pasture_3d/src/editor_plugin.gd` (input forwarding), `connectors/pasture3d_terrain_brush.gd`
(editor add/remove helpers). GDScript-only — no engine rebuild.

Loop points are exposed as **subgizmos** (not handles), so clicking one shows Godot's standard
move/rotate/scale gizmo while the brush keeps its selection.

---

## Phase 1 — point select → transform gizmo move  ✅ DONE (committed)
Each loop control point is a subgizmo: `_subgizmos_intersect_ray` (screen-space nearest within
`PICK_RADIUS`), `_subgizmos_intersect_frustum` (box-select), `_get/_set_subgizmo_transform`
(translation; Y snapped via `brush._base_height_below()` + `surface_offset` when Snap to Surface),
`_commit_subgizmos` (undoable via `curve.set_point_position`). User-verified.

## Phase 2 — in-place add / remove  ✅ DONE (commit 16d5956)
Plugin forwards 3D input while a brush is selected (`_handles` true for brush; `_edit` keeps the
terrain context live and populates the Layers dock from the brush's parent terrain):
Ctrl-click (Cmd on macOS) inserts a point on the nearest loop segment (snapped); right-click on a
point removes it (refuses below `_min_points()`). Both undoable. User-verified.

## Phase 3 — curve tangents (bezier in/out handles)  ✅ DONE (user-verified)
Expose each point's **in** and **out** tangents as additional subgizmos so loop curvature is
editable in the brush gizmo. Handle-id encodes `kind` (0=position, 1=in, 2=out): `id = gpi*3 + kind`.
Zero-length tangents are drawn/picked at a short outward **stub** so they're grabbable; dragging a
stub grows the tangent from zero (no jump — drag is applied as a delta from the stub start, with the
true pre-drag offset captured for clean undo back to zero). Tangents kept level (offset Y = 0) when
Snap to Surface is on, so the loop stays planar with the surface. Frustum/box-select still moves
**positions only**. Undo via `curve.set_point_in/out`.

**Declutter:** tangent handles are drawn only for the **selected loop point** (tracked in
`_subgizmos_intersect_ray`; a click in empty space clears it). A **"Toggle Tangents"** tool button
(static `Pasture3DTerrainBrush._show_all_tangents`, mirroring "Toggle Labels") shows every point's
tangents at once.

## Phase 4 — niceties
GDScript trio ✅ DONE (user-verified), all no-rebuild:
- **Auto-smooth point** — double-click a loop point toggles it between a smooth curve (seeds mirrored
  in/out tangents at ¼ of the shorter adjacent segment) and a sharp corner. `pasture3d_terrain_brush.gd`
  `editor_smooth_point`/`_smooth_handle`; wired in `editor_plugin.gd` `_forward_brush_input` on
  left double-click.
- **Mirror tangents** — on an already-smooth point, dragging one tangent mirrors the opposite (equal
  length, opposite dir); **Shift** breaks symmetry. Partner handle folded into the same undo.
  `brush_gizmo.gd` `_set_subgizmo_transform` + `_is_smooth` + `_smooth_drag`.
- **Delete-key remove** — Delete/Backspace removes the selected loop point (only when one is selected,
  else the brush deletes normally). Gizmo `selected_point`/`clear_point_selection` + plugin key handler.

**Slope tilt — DEFERRED to Phase 5** (not GDScript-only): the ridge/trough rasterizer
(`stamp_ridge_line` + GDScript fallback) applies a flat XZ cross-section and ignores curve tilt /
surface normal, so banking to the hillside needs rasterizer (C++) work + a rebuild.
Other still-open: close/open-loop toggle.

## Phase 5 — refinements & backlog
- **Paint-stroke undo on landscape HEIGHT does not undo** — ✅ DONE (commit 875c570, built into the
  live DLL in bd51cca). The shallow-copy aliasing defect diagnosed in
  `.claude/specs/per-stroke-undo-spec.md` is fixed: `_store_undo` now deep-isolates the tile payloads
  via `Pasture3DLayer::clone_tile_snapshot` (editor.cpp ~683-695) and both the undo and redo payloads
  use `.duplicate()`, so `stop_operation`'s `clear()` no longer empties committed history. Integration
  test added in `unit_testing.cpp`. The hidden-layer paint guard landed in the same commit.
- "Moving layers cleared the paint layer" — suspected GPU re-push gap in `layer_move` (push all
  affected regions, not just the moved layer's). Needs the Refresh-restores-it confirmation.
- **Slope tilt** (moved from Phase 4) — bank ridge/trough cross-sections to the surface normal; needs
  the rasterizer (`stamp_ridge_line` + GDScript fallback) to rotate the cross-section. C++ + rebuild.
- Brush-specific settings defaults (user to supply the per-brush values they kept re-setting).
- Eraser brush for the hand-paint tool (clear a section to reveal layers underneath).
- Fix B (changed-point-only snap) / slope tilt, if still wanted.
