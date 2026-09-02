# Pasture3D Road/Brush Performance Regression Remediation

**Document:** `PASTURE3D_ROAD_PERF_REGRESSION_SPEC.md`
**Status:** **Steps 1–2 built** (R1, R2, gates `[P]` `[Q]`; R7's `force_gdscript` oracle flag — branch `fix/road-perf-regressions-p1`, 2026-09-02); steps 3–6 unbuilt — written 2026-09-02 against `23edd083`
**Target:** Pasture3D Roads + Terrain Brush (Godot 4.7 GDExtension, C++20, GDScript)
**References:** `PASTURE3D_ROAD_BRUSH_PERF_SPEC.md`, `PASTURE3D_BRUSH_PERF_SPEC.md`, `PASTURE3D_ROAD_SYSTEM_PROPOSAL.md`, `PASTURE3D_LAYER_AND_BRUSH_PERF_SPEC.md`

---

## 1. Objective

The road-brush optimisation series `003fc2cc..23edd083` (2026-09-01) delivered the speedups
`PASTURE3D_ROAD_BRUSH_PERF_SPEC.md` asked for. Review of that diff found twelve defects, two of which
silently corrupt terrain data and four of which silently drop work the user asked for.

This spec fixes all twelve **without giving back the speedups**. That constraint is the whole design
problem: the obvious fix for the worst regression — the dirty rect no longer covering where a brush
used to be — is to revert to unioning the whole previous footprint, which is exactly the 458 ms path
`e8faa2aa` removed. Every fix below is written to preserve the narrow dirty rect and the native
rasteriser, and where it cannot, it says so.

Numbering is `R1`..`R12`, ordered by phase. Phases are ordered by blast radius, not by effort.

---

## 2. Phase 1 — Terrain data corruption (land first, alone)

These two write wrong values into the terrain and nothing reports it. Neither is visible until a user
looks at the region they damaged, by which time it is saved.

### R1 — The dirty rect no longer covers where the brush used to be ("the ghost cut")

**Where:** `project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:1417`

**Symptom.** Drag a Pasture3DRoadBrush, Ridge, Trough or Mound **node** in the 3D viewport. The brush
paints correctly at its new position and the terrain keeps a full, uncleared copy of the old cut at the
previous position. Undo does not remove it, because no undo action was recorded — the rect path is
auto-refresh only. The ghost survives to disk.

**Root cause.** `_refresh_owner_rect` used to merge two boxes per changed spline:

```gdscript
if path != null:
    ... merge _spline_footprint_aabb(path)      # where it is now
if _last_paint_aabb.has(sid):
    ... merge _last_paint_aabb[sid]             # where it was
```

The optimisation changed the second `if` to `elif`, so the previous footprint is now only consulted when
the spline is **gone**. For a spline that still exists it is dropped. That is survivable for a
control-point drag, because the replacement `_spline_dirty_aabb` (line 3315) re-derives a previous box
from `_curve_cache` for the moved indices. It is **not** survivable for the whole-spline case:

- `_on_refresh_timer` (line 856) routes a node move to `_refresh_owner_rect(owner, splines, snap_all = true)`.
- With `snap_all`, `moved` is forced empty (line 1412).
- `_spline_dirty_aabb` therefore takes its fallback branch and returns `_spline_footprint_aabb(path)` —
  the **current** footprint, with no previous component at all.
- `clip_box` is that box grown to tile bounds; `clear_layer_in_area` clears only it.

The comment on line 1403 still says "Union the previous (cached) and current footprint", which is now
false. A node move is the exact case `_moved_point_indices` cannot see, and line 1454 already documents
that ("A node move shifts every point's world XZ but leaves the local curve unchanged, so the moved-point
diff finds nothing") — the snap path was taught about it and the dirty-box path was not.

**Fix.** Do not restore the unconditional merge. Make the previous footprint part of the *fallback*
branch only, by giving `_spline_dirty_aabb` the previously painted box and letting it decide:

```gdscript
func _spline_dirty_aabb(path: Path3D, moved_indices: PackedInt32Array, p_prev_painted: AABB) -> AABB:
    if not is_instance_valid(path) or path.curve == null:
        return AABB()
    var n_pts := path.curve.point_count
    # WHOLE-SPLINE FALLBACK. Nothing here knows which part of the spline moved, so the answer has to
    # cover both where it is and where it was — the previous painted box is the only record of the
    # latter, and a node move leaves the local curve identical so no per-point diff can recover it.
    if moved_indices.is_empty() or moved_indices.size() >= n_pts or n_pts < 2:
        var whole := _spline_footprint_aabb(path)
        return whole if p_prev_painted.size == Vector3.ZERO else whole.merge(p_prev_painted)
    ... # partial path unchanged
```

and at the call site:

```gdscript
for sid in changed_ids:
    var path := _find_spline_by_id(sid)
    var prev: AABB = _last_paint_aabb.get(sid, AABB())
    if path != null:
        var moved := _moved_point_indices(path) if not snap_all else PackedInt32Array()
        var curr := _spline_dirty_aabb(path, moved, prev)
        ...
    elif prev.size != Vector3.ZERO:
        ...
```

**Why this shape and not a revert.** The partial branch already merges the previous *positions* of the
moved control points (line 3345), so a one-point drag keeps its narrow box and its 93x speedup. Only the
branch that was already returning the whole footprint pays for the union, and that branch was never
narrow. The cost of the fix is one `AABB.merge` on the path that already gave up on being narrow.

**Hardening, same function (lower priority, fold into the same change).** The current-side loop expands
by each point's `get_point_in`/`get_point_out` handles (lines 3336-3340); the previous-side loop uses
only `prev[k]` positions. `_curve_point_array` caches positions only, so previous handle extents are not
recoverable and a point dragged with long bezier handles can leave a sliver ghost inside the partial
branch. Add a parallel `_curve_handle_cache` (instance id -> `PackedVector3Array` of in/out pairs)
written wherever `_curve_cache` is written, and expand the previous-side loop by it. Do **not** widen
`_curve_point_array` itself: `_moved_point_indices` compares that array element-wise and a shape change
there would make every point read as moved.

**Gate:** `[P]` in `RoadPerfRegressionGate` (§8.1).

---

### R2 — Road surface paint writes base texture 31 where the control map is absent

**Where:** `src/pasture_3d_brush_raster.cpp:2520` (`Pasture3DData::stamp_road_surface_control`)

**Symptom.** A road painting over a region whose control map has not been created yet writes base
texture id **31** with the navigation/auto preserve bits forced on, instead of base 0 with clean flags.
It reads as "a wrong texture id", not as "a road that painted where it should not have".

**Root cause.** `Pasture3DData::get_control` returns `UINT32_MAX` when the region is missing, deleted, or
its control map is null — `pasture_3d_data.h:559` returns `UINT32_MAX` on a NaN pixel, and `get_pixel`
returns `COLOR_NAN` for all three cases. The GDScript path this function replaced normalised that
explicitly:

```gdscript
var c: int = terrain.data.get_control(at)
existing[i] = 0 if c == -1 else c        # pasture3d_road_brush.gd:773
```

The native version reads `cur` raw and decodes it. `get_base(0xFFFFFFFF)` is `0xFFFFFFFF >> 27 & 0x1F` =
31, and `cur & 0x6` is `0x6`. Both preserve bits set, base 31 written.

This is the failure `Pasture3DRoadPaint.surface_control` has an eight-line comment about
(`pasture3d_road_paint.gd:81-85`) and that `paint_surface` guards for a second time at
`pasture3d_road_brush.gd:748-751`. The guard was written twice on purpose and the native port dropped it
in the third place.

**Fix.** Normalise before decoding, at the one place that reads:

```cpp
uint32_t cur = get_control(pos);
// UINT32_MAX is get_control's "no region / no control map" answer, not a control word. Decoding it
// yields base id 31 and both preserve bits set — a road that paints the last texture slot and turns
// navigation on, for a cell that has no control data at all. Matches Pasture3DRoadPaint's -1 -> 0.
if (cur == UINT32_MAX) {
    cur = 0u;
}
const uint8_t base_id = p_preserve_base ? get_base(cur) : (uint8_t)p_texture_id;
```

**Also verify during implementation** (not a separate regression; state the answer in the PR):
`p_texture_id` is cast with `(uint8_t)` before `enc_overlay`, which masks to `0x1F` — ids above 31
silently alias rather than being refused. The function already refuses `p_texture_id < 0` at line 2494;
confirm `Pasture3DRoadType.surface_layer_id` is range-limited upstream, and if it is not, refuse
`p_texture_id > 31` at the same guard rather than aliasing.

**Gate:** `[Q]` in `RoadPerfRegressionGate` (§8.2).

---

## 3. Phase 2 — Work the user asked for, silently dropped

### R3 — The native road path returns before the stamp cache and the modifier stack

**Where:** `project/addons/pasture_3d/roads/pasture3d_road_brush.gd:467`

**Symptom, two of them.**

1. Add any second active modifier to a road brush — a `Pasture3DNodeGraph`, a noise or erosion step. It
   never runs. `_stack_forces_gdscript` no longer returns true for a stack containing a road
   (`pasture3d_terrain_brush.gd:3495`), the native branch is taken, and it `return`s at line 467 before
   `_run_modifier_stack` (line 511). The brush paints and says nothing about why the modifier did
   nothing — which is verbatim the failure the comment deleted from `_stack_forces_gdscript` warned of.
2. `_store_stamp_cache` (line 530) is never reached, so a road brush never has a `_stamp_cache` entry. In
   `_paint_into` (`pasture3d_terrain_brush.gd:1583`) the cache-hit branch can never fire for a road, so
   every layer-mate's dirty rect that touches the road forces a full native re-rasterise of it instead of
   an `apply_sim_block` replay.

**Fix.** Two independent changes; do them in this order.

**R3a — stop dropping the stack.** Restrict the native branch to the case it is actually equivalent to:
the road modifier is the *only* active modifier. Anything else takes the GDScript path, as it did before.
Put the decision in one place and make it the same place `_stack_forces_gdscript` reads:

```gdscript
## True when the native stamp_road_line is a complete answer for this stack: exactly one active
## modifier and it is the road grader. A second modifier means the native path would have to compose
## with it, which stamp_road_line has no way to do — so the whole stack goes back to GDScript rather
## than the extra modifier being dropped without a word.
func _road_native_is_complete() -> bool:
    var active := 0
    var road := 0
    for m in modifiers:
        if m != null and m.is_active():
            active += 1
            if m.op() == &"road":
                road += 1
    return active == 1 and road == 1
```

`_paint_flat_footprint` gates its fast path on `_native_raster("stamp_road_line") and road_mod != null
and _road_native_is_complete()`. `_stack_forces_gdscript` returns true for a `&"road"` op when
`_road_native_is_complete()` is false, so the two decisions cannot drift.

**R3b — populate the stamp cache on the native path.** `stamp_road_line` writes the layer directly and
never materialises a `vals` grid in GDScript, so there is nothing to hand `_store_stamp_cache`. Two
options, and the cheap one is correct:

- **Chosen:** have `stamp_road_line` return the composed `vals` block through the existing `out`
  Dictionary — it already returns six mask grids by the same mechanism
  (`pasture_3d_brush_raster.cpp:2160`). Add `out["vals"]` under a new `p_params["want_vals"]` flag so
  the non-caching callers do not pay the copy. Then the GDScript side calls
  `_store_stamp_cache(path, _compute_stamp_key(path), min_x, min_z, vs, gw, gh, out["vals"],
  _spline_footprint_aabb(path))` exactly as the GDScript path does at line 530.
- **Rejected:** skipping the cache and accepting the re-rasterise. The whole point of `_stamp_cache` is
  that a layer-mate's edit does not cost the road a bake, and roads are the most expensive brush on the
  layer — the case where the cache is worth the most is the case that currently cannot use it.

**Note on `vals` completeness.** The native path writes NaN outside `_clip_aabb`, so `out["vals"]` is a
clip-scoped block, not a whole-footprint block. The cache entry must therefore be **erased rather than
stored** when `_clip_aabb` is non-empty — a partial block replayed later as if it were the whole spline
would leave the road's outer reaches unpainted. Store only on an unclipped bake; on a clipped bake,
erase the existing entry for that spline id.

**Gate:** `[R]` and `[S]` in `RoadGraphGate` (§8.3).

---

### R4 — Editing a road type never rebuilds the ribbon

**Where:** `project/addons/pasture_3d/roads/pasture3d_road_chunk_host.gd:141`

**Symptom.** Change `lane_count`, `lane_width`, `shoulder_width`, `crown` or `surface_material` on a
`Pasture3DRoadType`. The terrain re-grades to the new carriageway. The tier-MID ribbon keeps the old
width and the old material, until something unrelated perturbs the alignment.

**Root cause.** The new rebuild-skip digest identifies the road type by `str(t.get_instance_id())`. An
instance id does not change when the resource's properties change. Nothing else in the digest covers the
cross-section either: `alignment_digest()` (`pasture3d_road_brush.gd:958-973`) hashes plan points, `ds`,
drape, `max_grade`, `design_speed` and pins — every input to the *vertical* solve and none to the
*cross-section*. So the digest is stable across exactly the edits that change the mesh.

**Fix.** Replace the instance id with the values the mesh is actually built from. The mesher consumes
`half`, `shoulder`, `crown` and the surface material, so those are what the digest owes:

```gdscript
var digest := "%s|%s|%.4f|%s|%s|%s|%.4f|%.4f|%.4f|%s" % [
    p_brush.alignment_digest(),
    p_brush.junction_digest(),
    depth_lift,
    str(collision_enabled), str(markings_enabled), str(props_enabled),
    t.half_width(p_brush.resolved_lane_count()),
    t.shoulder_width,
    t.crown,
    str(t.surface_material.get_instance_id()) if t.surface_material != null else "",
]
```

**Why values and not a resource hash.** A generic "hash every exported property of the road type" would
also churn on properties the ribbon does not read (`max_grade`, physics `surface_id`), forcing a mesh
rebuild on every vertical-only edit — which is the cost this cache exists to avoid. The digest should
name the mesh's inputs, so that adding an input to the mesher is a change that visibly has to be added
here too.

**Also.** `chunk_spans` cuts on terrain region boundaries (`pasture3d_road_mesher.gd:195`), so the region
size is a mesh input as well. Add `terrain.region_size` to the digest, or state in the PR why a
region-size change already forces a path through `_clear()`.

**Gate:** `[T]` in `RoadMeshGate` (§8.4).

---

### R5 — Junction resolve is dropped during a drag and never runs on release

**Where:** `project/addons/pasture_3d/roads/pasture3d_road_brush.gd:464` and `:715`

**Symptom.** Place a road with the Place Brush tool. It bakes, and forms no junctions with the roads it
crosses until an unrelated edit triggers a resolve.

**Root cause.** `PASTURE3D_ROAD_BRUSH_PERF_SPEC.md` §3 Phase 3 asked for resolve requests to be
"coalesced to fire on mouse release". What was built only *skips* them while the button is down:

```gdscript
if jnet != null and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
    last_junction_digest = junction_digest()
    jnet.request_resolve()
```

Nothing re-runs on release. `place_bake()` (`pasture3d_terrain_brush.gd:2881`) is called synchronously
from the Place Brush mouse-down handler with the button held, so the resolve for a newly placed road is
dropped outright.

Worse, the guard buys nothing on the path it was written for: `_on_refresh_timer` (lines 833-836) already
holds the whole bake back until the button is released, keeping the accumulated dirty state. On the timer
path these lines never see a pressed button; on every other path they only delete work.

**Fix.** Remove both `Input.is_mouse_button_pressed` guards around the resolve, and the one around the
`_widening` re-bake at `:697` (and its copy on the native path at `:418`) while you are there. `Pasture3DRoadNetwork.request_resolve` is already the
coalescing point — its own comment at `:713` says so ("coalesced on the network, so a refresh that bakes
six roads resolves once"). If per-drag coalescing is genuinely still needed after removing the guards,
add it *inside* `request_resolve` as a deferred call that collapses repeats, where it applies to every
caller and does not consult global input state.

**Why input state does not belong here.** `grade_surface` and `_paint_flat_footprint` are bake kernels.
The project's own split — stated in the `Pasture3DRoadMesher` header ("numbers can be gated without a
viewport deciding whether the road looked right") and in the grader's — is that these functions are pure
arithmetic over their arguments. A kernel whose output depends on whether a mouse button happens to be
down cannot be gated: `RoadJunctionGate` and `RoadGraphGate` would measure one thing headless and the
editor would do another, and the difference would surface as a junction that exists in the gate and not
in the scene.

**Gate:** `[U]` in `RoadJunctionGate` (§8.5).

---

## 4. Phase 3 — Native / GDScript divergence

### R6 — The native mesher ignores `alignment.s0`

**Where:** `src/pasture_3d_road_grade.cpp:620` (`road_mesh_build_chunk`), `:735` (`road_mesh_build_apron`)

**Symptom (latent).** Nothing sets `s0` non-zero today, so this does not currently misbehave. It is in
this spec because it is a new interface that silently drops a persisted field, and the failure it will
produce is the one the mesher's header says must never happen.

**Root cause.** `Pasture3DRoadAlignment.s0` is an `@export` (`pasture3d_road_alignment.gd:34`) and both
`height_at` and `index_at` subtract it. The grader threads it through as `p_align_s0`
(`pasture3d_road_grader.gd:184` -> `road_grade_grid_geom`). The new native mesher takes `align_ds` and no
`s0`, and `road_mesh_align_height_at` / `road_mesh_align_bank_at` compute `s / ds` directly. The graph
already serialises `s0` (`pasture3d_terrain_graph.gd:1736`), so the field is live in the format even
though no writer sets it.

The moment a road is solved over a sub-range, the ribbon samples `align_z`/`align_bank` shifted by
`s0 / ds` samples while the terrain under it is graded with the offset applied. Ribbon and ground stop
being the same surface — the condition `DEPTH_LIFT`'s comment calls out as the one thing that must never
be true.

**Fix.** Add `double p_align_s0` to both signatures and to the two lookup helpers, thread it from
`pasture3d_road_mesher.gd:232` and `:309` as `p_alignment.s0`, and bind the new argument with
`DEFVAL(0.0)` so existing GDScript callers are unaffected. Then the native and GDScript paths take the
same argument list, which is the property that makes the parity gate meaningful.

**Gate:** `[V]` in `RoadNativeParityGate` (§8.6).

---

### R7 — The native alignment solver stops early; the GDScript oracle does not

**Where:** `src/pasture_3d_road_grade.cpp:405`

**Symptom.** The native solver can return a different profile from the GDScript solver it replaced, on
roads where the gradient constraint binds.

**Root cause.** `road_align_solve` added a convergence break the reference does not have:

```cpp
if (it >= 20 && std::max(d1, d2) < 1e-4f) {
    break;
}
```

`d1`/`d2` measure only the SOR sweep delta, taken *before* that iteration's balance shift, pin
re-application and `project_grade`. On a profile where the road is pinned against a long hillside, the
SOR sweeps can settle below 1e-4 per pass while the alternating projection is still walking the profile
toward the constraint set — POCS convergence is not what the SOR delta measures. The native path then
stops at ~20 iterations where GDScript does 240.

Compounding it: `Pasture3DRoadAlignmentSolver.solve` now delegates to the native function whenever
`ClassDB.class_has_method` says it exists, so **the GDScript body is unreachable in any editor session
with the extension loaded**. It is no longer available as a differential oracle — a parity gate that
calls `Pasture3DRoadAlignmentSolver.solve` twice is comparing the native path to itself.

**Fix, two parts.**

1. **Decide the break on merit and record the decision.** Either delete it (240 iterations of SOR over a
   few thousand samples is not the bottleneck the profiling found — `15cfe571` attributes the 33x to
   vector reallocation, not to iteration count), or keep it and move the test to a quantity that actually
   measures the alternating projection: the maximum `|z_after_project - z_before_project|` over the
   iteration. The first is preferred; the break was not asked for by the spec and buys the least of any
   change in the series.
2. **Restore the oracle.** Add `force_gdscript: bool = false` to `solve` and `solve_with_plan` that
   bypasses the `ClassDB` check, so gates can obtain the reference profile. Without it, `[V]` below
   cannot be written at all.

**Gate:** `[V]` in `RoadNativeParityGate` (§8.6), same criterion as R6.

---

## 5. Phase 4 — Editor interaction and diagnostics

### R8 — `unproject_position` called on points behind the camera

**Where:** `project/addons/pasture_3d/roads/pasture3d_road_brush.gd:1291`,
`project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:2611`

**Symptom.** Standing on or near a road, clicks far from the road select it, and clicks on it do not.

**Root cause.** Both new pick functions skip a segment only when **both** endpoints are behind the
camera, then unproject each. `Camera3D.unproject_position` returns a mirrored, meaningless coordinate for
a point behind the near plane, so a segment straddling the camera plane is measured against a screen
segment that does not exist.

**Fix.** Skip the segment when **either** endpoint is behind:

```gdscript
if camera.is_position_behind(w1) or camera.is_position_behind(w2):
    continue
```

Clipping to the near plane instead would keep the straddling segment pickable, which is nicer but is not
what this code is for — the ground-raymarch fallback at `pasture3d_road_brush.gd:1310` already covers the
road under the cursor, which is the case a straddling segment represents.

**While here:** `world_to_screen_scale := 500.0 / maxf(cam_dist, 1.0)` (line 1300) is a magic constant
unrelated to viewport height or FOV, so the corridor-aware margin is wrong at any non-default FOV. Derive
it from the camera: `viewport_height_px / (2.0 * tan(deg_to_rad(camera.fov) * 0.5) * cam_dist)`.

**Gate:** `[W]` in `RoadRibbonPickingGate` (§8.7).

---

### R9 — The silent-road diagnostic is computed and never printed

**Where:** `project/addons/pasture_3d/roads/pasture3d_road_network.gd:905`, `:914`

**Symptom.** A bake in which every road builds nothing prints nothing at all.

**Root cause.** `silent` is still counted at line 905 but no longer appears in the format string, and the
print is gated on `rebuilt_roads > 0`. When every road returns `made == 0`, `rebuilt_roads` stays 0 and
the `if` is false. The comment immediately above (lines 908-910) justifies the print on precisely those
grounds — "every way this returns zero is a SILENT one ... exactly the state that wastes the most time" —
and that is now the only case with no output.

**Fix.**

```gdscript
if Engine.is_editor_hint() and not brushes.is_empty() and (rebuilt_roads > 0 or silent > 0):
    print("[Pasture3D] road ribbons: %d road(s) rebuilt, %d cached, %d built nothing (%d total chunk(s))"
            % [rebuilt_roads, cached_roads, silent, total])
```

The all-cached case stays quiet, which is what `f437a57e` was for; the all-silent case speaks, which is
what the comment was for.

**Gate:** none. Covered by reading the code; a gate on print output is not worth its maintenance.

---

### R10 — The gizmo rebuilds every chunk's collision mesh on every redraw

**Where:** `project/addons/pasture_3d/src/brush_gizmo.gd:126`

**Symptom.** Editor stalls on selection change and after every bake, on scenes with long roads — inside
the commit series whose stated purpose is removing editor stalls.

**Root cause.** `_redraw` copies every ribbon vertex through `node.to_local()` in GDScript, builds a
fresh `ArrayMesh` per chunk, and calls `generate_triangle_mesh()` on each — which builds a BVH. `_redraw`
fires on selection change, on transform change, and on every `update_gizmos()` after a bake. A 60-chunk
road at a few thousand verts per chunk does that work every time.

**Fix.** Cache the triangle meshes on the chunk host, keyed by the `_last_digest` R4 is fixing anyway:

- Add `var _pick_meshes: Array[TriangleMesh] = []` and `var _pick_digest: String = ""` to
  `Pasture3DRoadChunkHost`, plus `func pick_meshes(p_node: Node3D) -> Array[TriangleMesh]` that rebuilds
  only when `_pick_digest != _last_digest`, or when `p_node.global_transform` has changed since — the
  vertices are stored node-local, so a node move invalidates them independently of the digest.
- `brush_gizmo.gd` calls `host.pick_meshes(node)` and adds each with `add_collision_triangles`.

**Also.** The loop reaches into `host._chunks` and `chunk["meshes"]` directly. `pick_meshes` is the public
accessor that removes that; the gizmo should not know the host's storage shape.

**Gate:** none — a timing gate here would measure the editor, not the numbers. The fix is verified by the
digest gate `[T]` firing once per real change.

---

## 6. Phase 5 — Allocation hygiene in the paths that were optimised

### R11 — `stamp_road_line` allocates a scratch vector per cell

**Where:** `src/pasture_3d_brush_raster.cpp:2100`

`std::vector<int> scratch` is declared inside the innermost per-cell loop, so it heap-allocates and frees
once per grid cell. That is the exact cost the `r_scratch` out-parameter on `Pasture3DPathGeom::nearest`
exists to remove, and every other caller hoists it: `pasture_3d_road_grade.cpp:129-130`,
`pasture_3d_path_query.cpp:367-368` and `:439-440`, all with `scratch.reserve(32)`.

A 512x512 clip window performs roughly 260,000 malloc/free pairs per stamp, on top of the per-cell
`get_height_below`, in the function the whole native port exists to make fast.

**Fix.** Hoist above the `iz` loop with `scratch.reserve(32)`, matching the house idiom.

**Note while here (out of scope, do not fold in).** The base-height pre-pass and the mask write-back both
iterate `[iz0, iz1) x [ix0, ix1)`, but `road_grade_grid_geom` between them still scans the full
`gw x gh` grid, relying on the NaN skip at `pasture_3d_road_grade.cpp:139` to do nothing outside the
clip. That is correct but not free on a large footprint. Passing the clip row range into
`road_grade_grid_geom` as optional bounds for `parallel_for_rows` is the obvious follow-up; measure it
before writing it.

### R12 — The apron allocates a scratch vector per fan vertex

**Where:** `src/pasture_3d_road_grade.cpp:771`

Same defect, milder: `apron_point` declares `std::vector<int> scratch` inside the lambda, so it allocates
once per apron vertex — 25 times per junction by default. Hoist it to the enclosing function scope and
capture by reference, as `road_grade_grid_geom` does at line 129.

---

## 7. Invariants — what these fixes must not break

| Invariant | Guarantee & mechanism |
|---|---|
| **Dirty-rect narrowness** | R1 widens only the branch that already returned the whole footprint. A single control-point drag keeps the box `e8faa2aa` produced; `[P]`'s second criterion measures the box, not the wall clock, so a later change that widens it fails the gate. |
| **Native/GDScript parity** | R6 and R7 restore the two things parity depends on: the same argument list, and a reachable GDScript oracle. `[V]` compares against the forced-GDScript path, not against a second call to the native one. |
| **`graph_path()` completeness** | Untouched. R3 changes which stack the brush rasterises through, never what `graph_path()` returns; the Road Source contract in `PASTURE3D_ROAD_BRUSH_PERF_SPEC.md` §4 stands. |
| **No false `changed` emissions** | R4 changes the chunk-host digest only. `Pasture3DRoadNetwork._assign`'s equality checks are untouched, so downstream graph caches see no new invalidation. |
| **Stamp cache correctness** | R3b stores a cache entry only from an unclipped bake and erases the entry on a clipped one. A partial block must never be replayed as a whole-spline block. |
| **Kernels stay pure** | R5 removes the only two reads of global input state from a bake path. After it, no function under `roads/` consults `Input`. |

---

## 8. Verification & test plan

Every criterion below carries a **control** — a variant of the same measurement that must FAIL with the
fix absent or reverted. A criterion with no failing control is measuring that the code runs, not that it
is right. Every gate registers its criteria in its `CRITERIA` array so a crash before `_check` counts as
a failure rather than as silence (`RoadGraphGate._account_for_silent_criteria` is the pattern).

### 8.1 `[P]` The dirty rect covers where the brush was — `RoadPerfRegressionGate`

Bake a Ridge at x = 0 on a fresh region, record the layer's non-NaN cell set. Move the **node** (not a
curve point) to x = 200 and re-bake through `_refresh_owner_rect(owner, ids, snap_all = true)`.

- **Criterion:** no non-NaN cell remains within the original footprint. Measured on the layer, not on the
  composited height — a composite would hide the ghost behind the base.
- **Control that must fail:** the same move with the `elif` restored (equivalently, with `p_prev_painted`
  passed as `AABB()`) leaves the original footprint fully populated. Assert the control leaves **more than
  100** cells, so a fixture that flattened itself cannot pass as a clean clear.
- **Second criterion (narrowness, protects the speedup):** drag ONE control point of a 6-point spline by
  2 m and assert `clip_box` area is under 15% of the whole-spline footprint area. Control: the same drag
  with the whole previous footprint unioned in exceeds 60%.

### 8.2 `[Q]` Road paint over an absent control map — `RoadPerfRegressionGate`

Build a terrain with a region whose control map has not been created, run `paint_surface()` over it.

- **Criterion:** every written cell decodes to `base_of(control) == 0` and `control & 0x6 == 0`.
- **Control that must fail:** call `stamp_road_surface_control` with the `UINT32_MAX` normalisation
  removed and assert base id 31 appears — so the gate proves it can *see* the bug, not merely that the
  fixed code is clean.
- **Distinguishing "measured nothing":** assert the written-cell count is greater than zero first. A
  fixture where the road covers no cell would otherwise pass both criteria vacuously.

#### What step 1 actually built, and where it departed from the above

Both gates live in one new file, `project/bench/RoadPerfRegressionGate.gd`, not in `MarginSeamGate` and
`RoadPaintGate`. Neither host fitted: `MarginSeamGate` is a one-row mask fixture about the margin band with
no spline in it, and `RoadPaintGate`'s header states outright that it does not drive a real Pasture3D
terrain — true of the GDScript kernel it gates, but `[Q]` is about the *native* `stamp_road_surface_control`,
which reads the terrain back. Both criteria come from one change series, so they got one gate.

Three details of the fixtures differ from what §8.1/§8.2 assumed, each because the assumption did not hold:

- **`[P]` measures the BOX, not surviving cells.** `_spline_dirty_aabb` is what decides the clear, so a box
  that misses the old footprint leaves the ghost regardless of the rasteriser; the box is also closed form.
  The "more than 100 cells" control becomes "the fallback with no previous box misses the old footprint".
- **The `[P]` spline is 41 points over 2 km, not 6 points.** `_total_padding()` is a fixed lateral reach on
  every box, so on a short spline it swamps the ratio and a perfectly narrow partial box measures 85% of
  the whole — the 6-point fixture would have failed the narrowness criterion on correct code.
- **`[Q]`'s fixture needed a NaN control map.** The state §8.2 describes cannot be built through the
  ordinary APIs: `set_control_map(null)` sanitises a blank map straight back in, and where no region exists
  the write is dropped along with the read, so read and write normally fail together. What survives
  sanitising is a correctly sized RF map holding NaN — the engine's own no-data pixel, and what a region
  restored from a truncated `.res` carries. `[Q]` therefore gates the normalisation itself; its FIXTURE
  criteria assert the read really is `UINT32_MAX` first, so a future sanitiser change that closes this door
  fails loudly instead of passing vacuously. The control was run for real: with the normalisation compiled
  out, 256 of 256 cells came back base 31 with both preserve bits set.

`[D]` is an addition, not in §8: the `texture_id > 31` refusal R2 added must behave identically in the
native and the GDScript path, and id 31 must still paint in both, or the gate would pass on code that
refuses everything.

### 8.3 `[R]` `[S]` The native path does not drop the stack — `RoadGraphGate`

- `[R]` **Second modifier runs.** A road brush with a `Pasture3DNodeRoad` *and* an active second
  modifier. Criterion: the baked layer differs from the same brush with the second modifier disabled.
  Control: with `_road_native_is_complete()` forced true, the two bakes are identical — which is the bug.
- `[S]` **Stamp cache is populated and scoped.** After an unclipped bake, `_stamp_cache` has an entry for
  the road's spline whose `bounds` equal `_spline_footprint_aabb`. After a clipped bake, the entry is
  absent. Control: storing the clipped block anyway, then replaying it via `apply_sim_block` on a clean
  layer, leaves the road's outer reaches NaN — assert that control leaves more than 100 NaN cells inside
  the corridor.

### 8.4 `[T]` A road-type edit rebuilds the ribbon — `RoadMeshGate`

Bake a road, record `host` chunk count and surface 0's vertex positions. Change `road_type.lane_count`
from 2 to 4. Re-run `rebuild()`.

- **Criterion:** `host.last_rebuilt` is true and the carriageway width in the rebuilt mesh matches
  `t.half_width(4)`.
- **Control that must fail:** with the digest keyed on `t.get_instance_id()`, `last_rebuilt` is false and
  the vertex positions are unchanged.
- **Anti-churn criterion:** changing `road_type.max_grade` (a vertical-only input, already covered by
  `alignment_digest`) must produce `last_rebuilt == true` via the alignment digest, while changing
  `road_type.surface_id` (physics only, no mesh input) must produce `last_rebuilt == false`. That pair is
  what proves the digest names the mesh's inputs rather than hashing everything.

### 8.5 `[U]` A placed road resolves its junctions — `RoadJunctionGate`

Two crossing roads. Place the second via `place_bake()`.

- **Criterion:** `net.junctions` contains a junction at the crossing immediately after the bake, with no
  further `resolve_junctions()` call.
- **Control that must fail:** re-introducing the `Input.is_mouse_button_pressed` guard and stubbing it to
  return `true` yields zero junctions.
- **Purity criterion:** assert that the `Pasture3DRoadBrush` and `Pasture3DRoadGrader` sources contain no
  `Input.` reference. Cheap, and it is the invariant that keeps every other road gate meaningful headless.

### 8.6 `[V]` Native solver and mesher parity — `RoadNativeParityGate`

Requires R7's `force_gdscript` flag; write the flag first.

- **Solver criterion:** on a fixture where the gradient constraint binds — a road climbing a 30% slope
  with an 8% limit and two pins 3 m apart in height — the native `z` and the forced-GDScript `z` agree to
  1e-3 m at every sample, and `peak_grade`, `feasible`, `cut_volume` and `fill_volume` agree. Control: a
  straight road on flat ground agrees trivially and must NOT be the only fixture — assert the binding
  fixture's `peak_grade` is within 1e-4 of the limit, so the gate proves the constraint was actually
  active.
- **Mesher `s0` criterion:** build a chunk from an alignment with `s0 = 40.0` through both paths and
  assert the vertex Y values agree to 1e-4 m. Control: with `p_align_s0` dropped (the current signature),
  assert the disagreement exceeds 0.1 m — otherwise the fixture's `z` is too flat to detect an index
  shift, and the gate is measuring nothing.

### 8.7 `[W]` Picking across the camera plane — `RoadRibbonPickingGate`

Place the camera on the road, one control point ahead and one behind.

- **Criterion:** `pick_road_screen_distance` for a screen position 300 px away from the road's on-screen
  path returns `INF`.
- **Control that must fail:** with `and` instead of `or`, the same query returns a finite distance — the
  mirrored unprojection of the behind point.
- **Second criterion:** a screen position ON the visible road still returns a finite distance, so the fix
  did not simply make everything unpickable.

---

## 9. Landing order

1. **R1, R2** — one PR, gates `[P]` `[Q]`. These write bad data; nothing else should be in the branch.
2. **R7's `force_gdscript` flag alone** — it is a prerequisite for `[V]` and touches nothing else.
   *Built.* The flag is threaded through `solve`, `solve_with_plan`, `plan_curvature` **and**
   `superelevation`, not only the two the fix text named: a forced solve whose curvature and bank still
   came from native would be a half-oracle, and those are the two fields a banking bug lives in. Proven
   to reach the GDScript body rather than merely being accepted — perturbing `SOR_OMEGA` to 1.0 moved the
   forced profile by 1.18 m peak while leaving the native profile bit-identical. At shipped settings the
   two agree exactly (max |dz| = 0) on a 2 km road at the grade limit, which is a result for step 3 to
   push on, not yet parity across the binding-gradient case R7 predicts.
3. **R6, R7's break decision** — gate `[V]`.
4. **R3a, R3b** — gates `[R]` `[S]`. Largest behavioural change; land it with the parity gate already green.
5. **R4, R5** — gates `[T]` `[U]`.
6. **R8, R9, R10, R11, R12** — one cleanup PR, gate `[W]`. No shared surface with the above.

`PASTURE3D_ROAD_BRUSH_PERF_SPEC.md` §5.1 should gain a line pointing here once step 1 lands, so a reader
arriving at the perf spec learns that its "Implemented" header is true and incomplete at the same time.
