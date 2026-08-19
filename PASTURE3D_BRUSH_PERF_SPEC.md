# Pasture3D Brush Performance Spec — Threaded Painting & Partial Redraw

Status: design agreed 2026-06-19. **Ship now:** configurable threaded bake (live-drag vs on-release)
+ per-spline (dirty-rect) partial redraw. **Banked for later:** per-moved-point sub-region redraw.

Covers the spline-driven landscape brushes (`Pasture3DMound` / `Pasture3DRidge` / `Pasture3DTrough` /
`Pasture3DPlow` / `Pasture3DSplat`) that share `Pasture3DTerrainBrush`
([pasture3d_terrain_brush.gd](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd)).

---

## 0. Baseline (what exists today)

The whole paint cycle runs on the **editor main thread** in GDScript:
`refresh()` → `_refresh_owner(owner, …)` → for every tool bound to the layer: clear footprints →
(snap) → `_paint_spline` (rasterise SDF/chamfer + `set_height_on_layer` writes) → `composite_region`
(CPU) → `update_maps` (GPU push).

Two costs:
1. **Main-thread stall.** Painting already debounces to mouse-release (`_on_refresh_timer` reschedules
   while LMB is held), so the freeze you feel is the single bake *on release*, not per-frame painting.
2. **Whole-layer work.** `_refresh_owner` clears and repaints **every spline of every tool** bound to
   the layer, even when one point on one spline moved.

CPU vs GPU split (matters for threading): rasterisation (`_signed_distance_field`, `_polyline_field`,
`_chamfer*`) and `composite_region` are pure CPU; the GPU upload happens only inside `update_maps`
([pasture_3d_data.cpp:870](src/pasture_3d_data.cpp:870)). The live layer/region `Image`s are read on the
main thread by the renderer, collision, and `get_height` — so **off-thread code must never mutate them.**

---

## 1. Decisions (from the design interview)

| Question | Decision |
|---|---|
| Drag behavior | **Configurable toggle** per brush: live-while-dragging *or* bake-on-release. |
| Terrain lag | **Acceptable** — terrain may trail the spline by a frame+; responsiveness wins. |
| Layer sharing | **Overlap is common** — partial redraw must keep overlapping layer-mates correct. |
| Redraw granularity | **Per-spline (dirty-rect) ships now**; per-moved-point banked (§4). |

---

## 2. Threaded painting (ship now)

### 2.1 Compute/apply split (prerequisite for threading AND partial redraw)

Refactor each `_paint_spline` into two phases:

- **Compute (thread-safe, no engine mutation):** `_compute_spline(path, ctx) -> PaintBatch`. Does all
  the rasterisation and per-cell math against a *snapshot* of geometry+params, producing a flat buffer
  of writes: `{ layer_id, op (set/add), PackedVector3Array positions, PackedFloat32Array targets,
  PackedFloat32Array deltas }`. Reads of `terrain.data.get_height` for `relative_to_terrain` /
  `follow_spline_height` are taken into the snapshot up front (sample the needed cells on the main
  thread before dispatch, or accept that the height read is one bake stale).
- **Apply (main thread only):** consume the `PaintBatch` → `set_height_on_layer` / `add_height_on_layer`
  (or control/color equivalents) → `composite_region` over the touched rects → one `update_maps`.

`_paint_height` / `_paint_control` / `_paint_color` stay as the apply-phase primitives.

### 2.2 Worker model

- Use `WorkerThreadPool.add_task` (or a single persistent `Thread`) for the compute phase. GDScript runs
  on worker threads; the compute phase touches only local arrays + the snapshot, so no locks needed.
- **Latest-wins coalescing.** Keep at most one in-flight job + one queued "pending" snapshot. New edits
  while a job runs overwrite the pending snapshot (drop intermediates). On job completion, if pending is
  set, dispatch it. This is what makes live-drag cheap and bounded.
- **Marshal results to main thread.** Poll the task (`WorkerThreadPool.is_task_completed`) from
  `_process`, or `call_deferred` the apply phase. Never call engine mutators from the worker.
- A **generation counter** guards against stale applies (ignore a finished job whose generation is
  behind the latest committed edit).

### 2.3 `paint_mode` export

```gdscript
enum PaintMode { LIVE_DRAG, ON_RELEASE }
@export var paint_mode: PaintMode = PaintMode.ON_RELEASE   # safe default
```
- `ON_RELEASE`: today's trigger, but compute runs on the worker; only the apply hitches the main thread.
- `LIVE_DRAG`: `_schedule_refresh` no longer suppresses while LMB held; instead each curve change pushes
  a new snapshot through the latest-wins queue, so the terrain repaints continuously as you drag.
- Could also be a single project-wide setting; per-brush export chosen for flexibility.

### 2.4 Undo under threading

Async bakes are **not individually undoable** — only the settled state is, exactly as auto-refresh
already behaves (the gizmo edit is the undoable cause; auto-refresh re-fires on undo). The manual
**Refresh button** still records its bake action synchronously (it's an explicit, settled bake). Do not
register undo actions from worker completions.

### 2.5 Snap interaction

`snap_to_surface` mutates curve points and must stay on the main thread (it edits `Curve3D`). Run the
snap in the apply phase *after* the box is cleared (as today, §B comment in `_refresh_owner`), then feed
snapped points into the next compute. In live-drag this means snap lags one bake — acceptable.

---

## 3. Per-spline partial redraw / dirty-rect (ship now)

### 3.1 Trigger → dirty rect

When a spline `S` changes, the unit of work is **`dirty = prev_footprint(S) ∪ curr_footprint(S)`**
(world XZ AABB, padded by the brush reach via `_padding`). `prev_footprint` comes from
`_last_paint_aabb[S]`; `curr_footprint` from `_spline_footprint_aabb(S)`. Track per-spline which spline
changed (connect `curve.changed` with a bind to the owning `Path3D`) instead of the current
layer-wide repaint.

### 3.2 Overlap-correct repaint inside the box

`_refresh_owner_rect(owner, dirty: AABB)`:
1. `clear_layer_in_area(layer_id, dirty)` — clears **only** the box (already composites the box CPU-side
   so subsequent `get_height` reads the correct base).
2. Repaint **every** spline of **every** tool on `owner` whose footprint **intersects `dirty`**, with
   the compute clipped to `dirty` (write only cells inside the box). Non-overlapping splines/tools are
   skipped entirely. This is what preserves overlapping layer-mates: any contributor to a shared cell in
   the box is re-applied, so shared cells end up correct; cells outside the box are never touched.
3. `composite_region` only for the region rects the box covers; one `update_maps`.

Clip plumbing: `_compute_spline` takes an optional `clip: AABB`; the rasteriser intersects its grid box
with `clip` so it only emits writes for in-box cells (cheap — it already iterates a grid box).

### 3.3 Footprint cache update

After a dirty-rect bake, set `_last_paint_aabb[S] = curr_footprint(S)` for the changed spline only.
Other splines' cached footprints are unchanged (they weren't moved). Adding/removing a spline, rebinding
layers, switching terrain, blend-mode/param changes that affect the whole footprint → **fall back to a
full `_refresh_owner`** (whole-layer), since the affected area isn't a single point's neighbourhood.

### 3.4 When to fall back to full refresh

- Param change on the brush (height/width/falloff/blend/etc.) → whole footprint dirty → full refresh.
- Node transform change → whole footprint moves → full refresh (or dirty = old∪new whole footprint).
- Spline added/removed, layer rebind, terrain switch, undo/redo restore → full refresh.
- Only a **point move / handle drag on an existing spline** takes the dirty-rect path.

---

## 4. Per-moved-point sub-region (BANKED — future)

Refinement of §3: instead of the whole changed spline's footprint, the dirty rect is the neighbourhood
of just the moved point(s): `prev_pos ∪ new_pos` of the moved control point, expanded by the brush
reach (`_padding`) and by enough arc to cover the two **adjacent baked segments** (a moved point shifts
the two edges meeting it). For a closed `Pasture3DMound` loop the SDF is global in principle but local in
effect — only cells near the moved edges change — so the same neighbourhood box bounds the change.

Extra work vs §3:
- Detect *which point* moved (diff `Curve3D` point positions against a cached copy per spline, since
  `curve.changed` doesn't say which point). Keep a `PackedVector3Array` snapshot of each curve's points;
  on change, find the changed index/indices.
- For multi-point edits in one frame (e.g. box-select drag), union all moved-point neighbourhoods.
- End-taper / arc-length fields (`_polyline_field` `along`) are global along the spline; recomputing only
  a sub-arc means re-deriving `total_length` and the `along` offset for the sub-arc. Either recompute the
  full feature field but only *emit/apply* cells in the box (cheaper apply, same rasterise cost — modest
  win), or carry per-segment arc offsets so a sub-arc field is exact (full win, more bookkeeping).
- Mound `max_inside` (dome normalisation) is a global property of the loop; a sub-region bake must reuse
  the loop-wide `max_inside` from the last full bake, not recompute it from the clipped grid.

Ship §4 only if §3 isn't fast enough in practice. §3's clip plumbing (`_compute_spline(clip)`) is the
same hook §4 uses, so §4 is mostly "shrink the dirty rect + identify the moved point," not a rewrite.

---

## 5. Risks / watch-items

- **Stale height reads.** `relative_to_terrain` / `follow_spline_height` read live `get_height`. Off-
  thread compute uses a snapshot, so a bake can be one generation stale vs the base. Acceptable per the
  lag decision; the next settled bake corrects it.
- **`WorkerThreadPool` in the editor.** Confirm tasks run and complete in the editor (not just at
  runtime) and that GDScript-on-thread is stable for this workload; fall back to a single `Thread` if not.
- **Apply still on main thread.** If `composite_region`+`update_maps` over a *large* dirty box is itself
  the hitch, partial redraw (§3) is what shrinks it — the two features compound.
- **Region boundaries.** A dirty box spanning multiple regions must clear/composite each region rect it
  covers (existing `clear_layer_in_area` already loops regions; mirror that in the composite step).
- **Plow/Splat (control/color).** Same split applies; apply-phase primitive is `_paint_control` /
  `_paint_color` and `update_maps(TYPE_CONTROL/COLOR)`.

## 6. Implementation gotchas hit during Stage 1 (must hold for Stage 4 too)

- **Tile-granular clear vs. pixel-granular clip.** `clear_layer_in_area` → `clear_tiles_in_rect` drops
  every WHOLE `tile_size`-vertex tile (default 64) the box touches, so the cleared area is the dirty box
  grown out to tile boundaries — bigger than the box. If the repaint is clipped to the un-grown box, a
  layer-mate's samples in a dropped tile *outside* the box are erased and never restored → a "cut" up to
  `tile_size * vertex_spacing` away. **Fix:** snap the box outward to the tile grid (world multiples of
  `tile_size * vertex_spacing`; region_size is a multiple of tile_size so the grid is global, no
  half-offset) and use that one box for clear, overlap test, AND clip. Make the clip max-edge EXCLUSIVE
  to match the half-open `[min, max)` tile span (else a one-vertex line double-adds for ADD brushes).
- **`update_maps` default is `all_regions=TRUE`** → rebuilds the whole height texture array every call.
  The dirty-rect bake must pass `(map_type, false, false)`, and because `update_maps` never clears the
  per-region `is_edited` flag (only the editor's sculpt flow does), clear all region edited flags at the
  start of the bake so the targeted push uploads exactly the touched regions.
- **Snap-to-self on partial.** Re-snapping every point after a partial clear lets points outside the
  cleared box read their own (uncleared) contribution and climb. Snap ONLY the moved points (diff curve
  positions vs a per-spline cache); the full path still snaps all (it clears everything first).

## 7. Stage 2 (compositing) — DONE 2026-06-20, measured

Profiling the dirty-rect bake (per-brush `log_bake_timing`) showed **compositing**, not rasterisation,
dominated normal edits: `clear_layer_in_area` recomposited the WHOLE region (~75–90 µs-thousands per
edit, size-independent) and every layer write composited one pixel. Fixed in C++:
- `clear_layer_in_area` composites only the dropped tiles' span (tile-bounded rect).
- `set/add_height_on_layer` + `set_control/color_on_layer` gained `composite=false`; the brush writes
  samples deferred and calls the new `composite_area(AABB)` once.

**Measured:** small/common edit 84 ms → **24 ms** (clear 73 → 5 ms, 14×); 2-loop 116 → 54 ms.

**Remaining bottleneck = GDScript rasterisation (not compositing).** A big 448×384 m mound edit only
went 1150 → 870 ms because `paint` (730 ms) is the SDF/chamfer + per-cell loop over a huge grid × the
overlapping tools — removing the per-pixel composite shaved only ~90 ms. Compositing is now a small
bucket everywhere. To speed large features further, the only levers are: **(a) §4 per-moved-point grid
shrink** (GDScript, no rebuild — rasterise only the moved point's neighbourhood instead of the whole
spline footprint; complex for closed-loop SDF because `max_inside`/distance are global), **(b) port the
rasterisers to C++**, or **(c) threading** (declined). The common case is already fast, so this only
matters if editing very large single features becomes a real pain point.
