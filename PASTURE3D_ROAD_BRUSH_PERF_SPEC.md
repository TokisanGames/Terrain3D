# Pasture3D Road Brush Performance Specification — Section-Aware Recalculation & Native Acceleration

**Document:** `PASTURE3D_ROAD_BRUSH_PERF_SPEC.md`  
**Status:** **Implemented** — 2026-09-01  
**Target:** Pasture3D Roads Subsystem (Godot 4.7 GDExtension, C++20, GDScript)  
**References:** `PASTURE3D_BRUSH_PERF_SPEC.md`, `PASTURE3D_BRUSH_PERF_ROUND2_SPEC.md`, `PASTURE3D_ROAD_SYSTEM_PROPOSAL.md`, `PASTURE3D_GRAPH_GEOMETRY_PORTS_SPEC.md`

---

## 1. Objective & Background

`Pasture3DRidge` and `Pasture3DTrough` achieve sub-millisecond, responsive interactive authoring in the editor by leveraging:
1. **Section/Spline-level dirty rect scheduling** (`_schedule_spline_refresh` / `_refresh_owner_rect`).
2. **Tile-bounded clearing and footprint caching** (`_stamp_cache` + `apply_sim_block`).
3. **Native C++ polyline rasterization** (`stamp_ridge_line` / `stamp_trough_line`) with AABB segment pruning and cell clipping (`_clip_aabb`).

Previously, `Pasture3DRoadBrush` and its modifier `Pasture3DNodeRoad` lacked these optimizations. An edit on a single control point triggered a global flattening of all child splines (`_plan_points`), an unclipped $O(\text{cells} \times N_{\text{segments}})$ GDScript nested loop over the entire road bounding box (`_paint_flat_footprint`), whole-road alignment relaxation (240 iterations across all samples), intermediate Float64 array allocations, and cascading widening/resolve triggers.

This specification details the architecture and phased implementation to equip `Pasture3DRoadBrush` with section-level recalculations, dirty-rect clipping, stamp caching, and native C++ rasterization while strictly preserving compatibility with `Pasture3DGraphNodeRoadSource` (Road Source) in the Terrain Node Graph.

---

## 2. Architecture: Ridge Brush Baseline vs. Road Brush Deficiencies

### 2.1 The Ridge Brush Pattern (The Target Standard)
- **Dirty Bounds**: A single spline edit marks only `_dirty_splines[path.get_instance_id()] = true`.
- **Tile-Snapped Clip Box**: `_refresh_owner_rect` computes `dirty = curr_footprint(path) ∪ prev_footprint(path)` snapped to terrain tile boundaries.
- **Layer Clear**: Only tiles within `clip_box` are cleared on the layer.
- **Stamp Caching**: Sibling splines on the same layer that overlap `clip_box` but whose curves did not change are served instantly from `_stamp_cache` via `terrain.data.apply_sim_block(...)`.
- **C++ Native Rasterisation**: `stamp_ridge_line` receives `_clip_aabb` and skips un-clipped rows/columns in constant time. It prunes distant segments via AABB tests and writes directly to layer tiles (`_apply_stamp_block`) with `composite = false`.
- **Single Composite**: `terrain.data.composite_area(clip_box, false)` and `update_maps(TYPE_HEIGHT, false, false)` push only touched regions to the GPU.

### 2.2 Diagnosed Road Brush Bottlenecks
1. **Unclipped GDScript Pre-Pass**: `_paint_flat_footprint` iterated over all $gw \times gh$ cells in GDScript calling `nearest_on_plan` without checking `_clip_aabb` or segment bounding boxes ($O(\text{cells} \times N_{\text{segments}})$ interpreted cost).
2. **Monolithic Spline Concatenation**: `_plan_points()` concatenated and tessellated all child splines under the brush, invalidating the entire road when a single vertex changed.
3. **Absence of Native C++ Road Stamp (`stamp_road_line`)**: The road brush fell back to the interpreted modifier stack (`_run_modifier_stack`), marshaling multiple Float64/Float32 arrays.
4. **Global Alignment Solving**: `Pasture3DRoadAlignmentSolver.solve` performed 240 SOR relaxation passes across the entire road length for every interactive mouse movement.
5. **Re-entrant Refreshes**: `grade_surface` triggered a second full bake via `_schedule_refresh()` during corridor widening, and `jnet.request_resolve()` executed on every drag tick.

---

## 3. Detailed Technical Design

### Phase 1: GDScript Partial Redraw & Spatial Pruning
1. **Clip `_paint_flat_footprint` to `_clip_aabb`**:
   - Determine active row/column bounds:
     $$\text{ix}_0 = \max\left(0, \left\lfloor\frac{\text{clip.min\_x} - \text{min\_x}}{\text{vs}}\right\rfloor\right), \quad \text{ix}_1 = \min\left(gw - 1, \left\lceil\frac{\text{clip.max\_x} - \text{min\_x}}{\text{vs}}\right\rceil\right)$$
     $$\text{iz}_0 = \max\left(0, \left\lfloor\frac{\text{clip.min\_z} - \text{min\_z}}{\text{vs}}\right\rfloor\right), \quad \text{iz}_1 = \min\left(gh - 1, \left\lceil\frac{\text{clip.max\_z} - \text{min\_z}}{\text{vs}}\right\rceil\right)$$
   - Only iterate cells within $[\text{iz}_0, \text{iz}_1] \times [\text{ix}_0, \text{ix}_1]$. Cells outside the clip box retain their previous values or remain untouched.
2. **Spatial Indexing for Plan Distance Queries**:
   - In `Pasture3DRoadGrader.nearest_on_plan`, maintain a list of 2D segment bounding boxes expanded by `corridor_half_width`.
   - Skip segment projection for cells outside a segment's bounding box.
3. **Spline Stamp Caching**:
   - Store generated footprint blocks in `_stamp_cache` keyed by spline instance ID and curve point hash.
   - Sibling splines intersecting `_clip_aabb` are served via `apply_sim_block` when unchanged.

### Phase 2: Native C++ Road Stamp (`stamp_road_line`)
1. **Engine Entry Point in `Pasture3DData`**:
   ```cpp
   void Pasture3DData::stamp_road_line(
       const int p_layer_id,
       const PackedVector2Array &p_plan,
       const double p_align_ds,
       const double p_align_s0,
       const PackedFloat32Array &p_align_z,
       const PackedFloat32Array &p_align_bank,
       const PackedFloat32Array &p_half_width,
       const PackedFloat32Array &p_shoulder,
       const PackedFloat32Array &p_verge,
       const PackedByteArray &p_suppress,
       const AABB &p_clip,
       const Dictionary &p_params
   );
   ```
2. **Fused Execution Pass**:
   - Construct `Pasture3DPathGeom` from `p_plan` (utilizing existing C++ spatial indexing).
   - Evaluate corridor containment and grading within a single parallel loop via `Pasture3DThreadPool::parallel_for_rows`.
   - Write directly into `Pasture3DLayer` via `_apply_stamp_block` with deferred compositing.

### Phase 3: Alignment Solver & Resolve Decoupling
1. **Interactive Drag Coalescing**:
   - Gate corridor widening re-bakes (`_widening`) so they do not trigger during active mouse drag (`Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)`). Execute widening once on mouse release.
   - Coalesce junction network resolve requests (`jnet.request_resolve()`) to fire on mouse release.

---

## 4. Road Source & Terrain Node Graph Integration Invariants

`Pasture3DGraphNodeRoadSource` imports roads into the Terrain Node Graph as `PortType.PATH`. The optimization guarantees zero breakage across all graph consumers:

| Invariant | Guarantee & Mechanism |
|---|---|
| **`graph_path()` Completeness** | `Pasture3DRoadBrush.graph_path()` always returns the full-length `Pasture3DGraphPath` with points, half-widths, heights, and complete sample arrays. Dirty-rect clipping is purely internal to layer rasterization. |
| **Brush vs. Graph Parity** | `stamp_road_line` in C++ shares the exact same mathematical grading formulas as `Pasture3DUtil.road_grade_grid` / `Pasture3DGraphNodeRoadGrade`, maintaining bitwise parity ($0.0000\text{ m}$ drift). |
| **Downstream Cache Protection** | `Pasture3DRoadNetwork._assign` equality checks (`old.points == new.points`, `old.heights == new.heights`) prevent false `changed` emissions and protect downstream graph node caches (erosion, noise, etc.). |
| **State Persistence** | `alignment_digest()` remains deterministic across loads, preventing false "needs bake" alerts. |
| **Unresolved State Handling** | Empty or unbaked road sources safely produce empty paths without throwing errors or corrupting queries. |

---

## 5. Verification & Test Plan

> **The "Implemented" header above is true and incomplete at the same time.** The speedups landed; the
> series also left twelve correctness regressions behind, catalogued and now remediated in
> `PASTURE3D_ROAD_PERF_REGRESSION_SPEC.md` (all six steps built, 2026-09-02, gates `[P]`-`[W]`). Read
> that before treating the gate list below as the whole story: several of those gates postdate this
> document, and two of the regressions -- the ghost cut and the texture 31 write -- were writing bad
> data while this header already said "Implemented".

### 5.1 Automated Gate Suite Verification
1. **`project/bench/RoadGraphGate.tscn`**:
   - `[E]` Unresolved path reads far away.
   - `[F]` Path travels down the graph wire.
   - `[G]` Cache invalidation on real move; cache preservation on identical re-resolve.
   - `[H]` Road resolves into graph via `road_key` and default host.
   - `[J]` Path mask follows road half-width.
   - `[K]` Graph cuts the SAME road the brush does ($\le 0.001\text{ m}$ drift, 0 roadbed diff cells).
2. **`project/bench/RoadNativeParityGate.tscn`**:
   - Verifies native C++ path queries and grading against GDScript reference oracles.
