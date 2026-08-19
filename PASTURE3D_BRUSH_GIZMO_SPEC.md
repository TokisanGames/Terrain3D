# Pasture3D Brush Gizmo & Surface-Snap Climbing-Fix Spec

**Status:** §2 **Fix A IMPLEMENTED 2026-06-18** (headless-verified: a snapped point holds on the base
across repeated refreshes; ridge still paints its crest). **§3 gizmo work (preview / draw-on-surface /
preview-apply) is NOT planned** — with Fix A the snap is robust and, with the O(cells) perf, the tool
is fast enough that a preview is unnecessary (user decision 2026-06-18). Kept here for reference only.
Target: Godot 4.7, Pasture3D `main`.
**Builds on:** the spline brushes (`PASTURE3D_LANDSCAPE_TOOLS_SPEC.md` §6 preview gizmo) and the
surface-snap feature (`PASTURE3D_SPLINE_SURFACE_SNAP_SPEC.md`; A + B shipped, C/D deferred).
`connectors/{terrain_brush,mound,ridge,trough}.gd`, `project/addons/pasture_3d/src/editor_plugin.gd`.
**Expected scope:** GDScript-only — **no engine rebuild**. APIs already bound: `get_height`,
`get_normal`, `Pasture3D.get_intersection` (heightmap ray-march), `EditorNode3DGizmoPlugin`,
`EditorPlugin._forward_3d_gui_input`, `EditorUndoRedoManager`.

---

## 1. Goal

1. **Fix the "points climb their own ridge" bug** in the surface-snap toggle.
2. Implement the previously-deferred **brush gizmo work**: a footprint/result **preview**, **draw-on-
   surface** point placement, and a **snap-before-apply** workflow that makes the climbing structurally
   impossible.

---

## 2. The climbing bug

### 2.1 Cause

`Pasture3DTerrainBrush._apply_surface_snap()` snaps every point's Y to `terrain.data.get_height(world)`.
`get_height` returns the **composited** surface, which already includes this tool's own painted ridge.
So:
- A snapped point sits on top of the ridge it created → the next bake puts the crest `crest_height`
  *above that* → the point climbs by ~`crest_height` every refresh (runaway, see the bug screenshot).
- It snaps **all** points each refresh, so adding/moving one point re-lifts every other point too.

The fix in every form below is the same principle: **snap to the surface with this tool's own
influence removed** (the "base" the ridge should sit on), and don't re-lift points that are already
placed.

### 2.2 Fix A — snap against the cleared influence (recommended, minimal)

The refresh already **clears** this tool's layer footprint (which recomposites the region) *before* it
repaints. Move the auto-snap to run **after the clear, before the repaint**, so `get_height` reads the
base beneath (this tool's contribution is momentarily gone; other layers/tools remain):

```
# in _refresh_owner, inside the `layer_id >= 0` branch:
clear extra_clears
for s in sibs: clear s footprints; s._last_paint_aabb.clear()
for s in sibs:                       # influence now cleared → get_height == base
    if s.snap_to_surface: s._apply_surface_snap()
for s in sibs: s._paint_into(layer_id, blend)
```

- Snapping changes **Y only**; the footprint is XZ-based, so the already-cleared area stays valid.
- `_surface_snap_edits()` already **skips points whose snapped position is unchanged**
  (`is_equal_approx`), so once a point sits on the base, subsequent refreshes are no-ops → **idempotent,
  no climbing, no churn.**
- Fallback (no layers API): snap against `get_height` directly (there is no own-layer to subtract; the
  destructive path overwrites base anyway).

This is the smallest change and fully resolves the runaway. It is "clear the influence, then snap."

### 2.3 Fix B — only snap the point that was added/moved (churn reduction)

Complementary to A: rather than re-evaluating every point, snap **only the point the user just changed**.

- Cache a per-spline copy of the last-seen point positions; on `curve.changed`, diff to find the
  changed/added index and snap just that one.
- Benefit: untouched points never move, even if A's idempotency guard ever drifts; matches the user's
  "as simple as only snapping the new/moved point."
- A alone is sufficient for correctness; B is a UX refinement. Ship A first; add B if churn or
  surprise-movement is still felt.

### 2.4 How the gizmo workflow removes it structurally (§3.3)

With the snap-before-apply preview, the tool's influence is **not baked** while you author — the
preview is a gizmo overlay. So `get_height` is always the true base and points can never climb their
own (un-baked) ridge. Apply bakes once at the end. This is the elegant end state; Fix A is the
immediate patch for the current always-bake toggle.

---

## 3. Gizmo work

The editor plugin (`editor_plugin.gd`, an `EditorPlugin`) hosts everything; register a gizmo plugin in
`_enter_tree` and forward 3D input as the sculpt tool already does.

### 3.1 Preview gizmo (`EditorNode3DGizmoPlugin`)

A gizmo for `Pasture3DTerrainBrush` nodes that draws the affected area **before/while** editing, so the
user sees what will change without reading the baked terrain:

- **Mound:** the closed loop (baked curve points) + the falloff boundary (loop offset by
  `falloff_width`/`edge_offset`), drawn at the terrain surface height along XZ.
- **Ridge / Trough:** the centreline + the two lateral edges (centreline ± `width`/`bed_half_width`+
  `bank_width`, using per-point perpendiculars — reuse the road connector's `curve_2d_to_boundingbox`
  perpendicular math) + the outer falloff edges.
- **Result preview (optional):** a polyline of the crest (Ridge) / bed (Trough) at the computed height
  following the surface, so you see the ridge top / channel floor before baking. Full translucent mesh
  is a later nicety; lines are enough for v1.
- Implementation: `_has_gizmo(node)` → node is a brush; `_redraw(gizmo)` builds the line lists with
  `gizmo.add_lines(points, material)`; materials via `create_material`/`get_material`. Redraw on
  `curve.changed` / property change (`update_gizmos()`).

### 3.2 Draw-on-surface (click to place points on the terrain)

Extend `editor_plugin.gd`:
- `_handles()` also returns true for a `Pasture3DTerrainBrush` (or a `Path3D` child of one).
- In `_forward_3d_gui_input`, when a **draw mode** is active and a brush spline is selected, ray-march
  `terrain.get_intersection(camera_pos, camera_dir, true)` (already used for sculpt picking) and:
  - click empty → append a curve point at the hit (on the surface),
  - drag a handle → move the point to the hit XZ at surface height.
- **Coexist with Godot's built-in Path3D gizmo:** only intercept under an explicit modifier or a
  "Draw on Surface" toggle (a brush tool button or a small plugin toolbar); otherwise return
  `AFTER_GUI_INPUT_PASS` so normal Path3D editing still works. Mirror the sculpt tool's `_input_mode`
  gating.
- Every add/move is an `EditorUndoRedoManager` action (`add_point` / `set_point_position`).

### 3.3 Snap-before-apply preview ("clear the influence", author, then apply)

The workflow the user described, which prevents climbing by construction:

1. On entering draw/edit for a brush, **clear the tool's layer contribution** (or simply don't bake)
   so the surface shown is the true base.
2. Author points; they snap to the **base** surface via the gizmo preview (using §3.1 lines), not to a
   baked ridge. The preview shows the would-be crest/bed.
3. **Apply** (a button, or automatically on mouse-release / deselect) bakes the layer once.

Because nothing is baked during authoring, `get_height` is always the base → points never climb. This
is the gizmo-grade version of Fix A. Gate it behind the draw mode so the normal toggle behaviour
(now correct via Fix A) is unaffected.

### 3.4 Optional: tilt points to the slope (`get_normal`)

When snapping/placing, optionally set each curve point's **tilt** from `get_normal` at the location so
the cross-section banks with the hillside. Off by default; pure polish.

---

## 4. Edge cases & notes

- **Coexistence:** the brush's child `Path3D` keeps its native gizmo for normal editing; our gizmo
  only *draws* (preview) and our input handler only acts under the draw toggle/modifier — never both
  grabbing the same drag.
- **Undo:** draw/move actions register with `EditorUndoRedoManager`; the preview/clear-influence step
  is transient (re-baked on apply), so it needs no undo of its own — apply is the undoable result.
- **NaN / outside regions:** `get_height`/`get_intersection` return NaN / a miss off the terrain —
  skip the snap / ignore the click there (matches the shipped A+B behaviour).
- **Transforms:** snap/draw in world space, convert back with `path.to_local(world)`.
- **Performance:** preview lines are cheap; redraw is throttled by `update_gizmos()` on change. The
  bake on apply uses the existing O(cells) rasteriser.
- **Selecting the right spline for draw:** when a brush has several child `Path3D`s, draw targets the
  currently-selected child (or the last-edited one); appending starts a new point on that curve.

---

## 5. Files touched (anticipated)

- `connectors/pasture3d_terrain_brush.gd` — **Fix A** (reorder the auto-snap after the clear in `_refresh_owner`);
  optionally **Fix B** (changed-point tracking); a "Draw on Surface" / "Apply" toggle+button for §3.3.
- `project/addons/pasture_3d/src/editor_plugin.gd` — register the gizmo plugin; extend `_handles` +
  `_forward_3d_gui_input` for draw-on-surface; manage draw mode.
- new `connectors/brush_gizmo.gd` (or `src/`) — the `EditorNode3DGizmoPlugin`.
- No C++ changes.

---

## 6. Suggested build order

1. **Fix A** — reorder auto-snap to after the clear. Tiny, fixes the reported bug immediately;
   verify headless that repeated refreshes don't raise an already-snapped point.
2. **Preview gizmo** (§3.1) — footprint + crest/bed lines (the most-requested visual aid).
3. **Draw-on-surface** (§3.2) — click to place points on the terrain, gated by a draw toggle.
4. **Snap-before-apply preview** (§3.3) — clear-influence preview + Apply; the structural climbing fix.
5. **Fix B** (changed-point-only snap) and **slope tilt** (§3.4) as refinements if still wanted.

---

## 7. Sources

- Internal: `PASTURE3D_SPLINE_SURFACE_SNAP_SPEC.md` (A+B shipped; C/D were deferred — this spec
  supersedes them), `PASTURE3D_LANDSCAPE_TOOLS_SPEC.md` §6 (preview gizmo), `editor_plugin.gd`
  (`_forward_3d_gui_input` ray-march, `_handles`), `connectors/pasture3d_road_connector.gd`
  (`curve_2d_to_boundingbox` perpendicular/edge math to reuse for footprint lines).
- [Godot Path3D snap-to-colliders PR #102085](https://github.com/godotengine/godot/pull/102085) /
  [proposal #11650](https://github.com/godotengine/godot-proposals/issues/11650) — same idea,
  collider-based; ours uses the heightmap ray-march (collider-free).
- [EditorNode3DGizmoPlugin docs](https://docs.godotengine.org/en/stable/classes/class_editornode3dgizmoplugin.html)
</content>
