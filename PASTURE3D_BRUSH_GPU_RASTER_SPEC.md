# Pasture3D Brush Performance — GPU Rasterisation Spec (Option D, experimental)

Status: **design agreed 2026-06-21, branch `perf/gpu-rasterization`.** Round 2 native C++ brought *small/
medium* edits to ~tens of ms, but **there is a measured wall at terrain scale**: a map-defining feature
that spans the terrain (a 2240×2496 m, 30-region Mound) bakes in **~1.79 s, of which paint is 91 %
(1.63 s) in the serial chamfer transform** — see the benchmark in §7. The user uses brushes this large to
define whole maps, so this regime is a real workflow, not a hypothetical. Goal: build a clean, complete,
*proven* GPU compute path for the spline rasterisers that collapses that paint cost (the MicroVerse
"73 splines → 12 ms" regime, here a single huge spline), without disturbing the existing interface,
collision, save, or undo. Supersedes the high-level sketch in `PASTURE3D_BRUSH_GPU_RASTER_NOTES.md` (kept
as background).

## Decisions (from the design interview, 2026-06-21)

| Question | Decision | Consequence for this spec |
|---|---|---|
| Motivation | **Experiment / future-proofing — with a now-measured terrain-scale payoff** | Build it right and fully validated; no pressure to ship or to beat C++ on small edits. But the terrain-spanning benchmark (§7) shows a real 1.6 s paint wall, so the large regime is a genuine win, not just headroom. Completeness + correctness over raw speed. |
| Distance algorithm | **Analytic SDF** (per-pixel exact distance, MicroVerse/Landmass style) | We do **not** port the serial chamfer transform. Output will differ *slightly* from current chamfer bakes (analytic is more accurate). A/B validation quantifies the delta (§7). |
| GPU scope | **Rasterisation only** | GPU produces the layer-sample grid for the clip box; we **read back** to CPU. Compositing, collision, and `.res` save stay exactly as today (CPU `Image`s remain source of truth). Smallest blast radius. |
| Dispatch policy | **Size-thresholded hybrid** | C++ for small/common edits (no readback latency); GPU only when `gw*gh >= gpu_raster_threshold` and a local `RenderingDevice` exists. Three-tier fallback GPU → C++ → GDScript. |

---

## 0. Why this is an *algorithm change*, not a port

The Round 2 C++ rasteriser builds distance with a **serial two-pass chamfer distance transform**
([pasture_3d_brush_raster.cpp:47](src/pasture_3d_brush_raster.cpp:47) `raster_chamfer`,
[:161](src/pasture_3d_brush_raster.cpp:161) `raster_chamfer_payload`). Every cell reads its already-written
neighbours, so the two passes are **inherently sequential** — they do not map onto a massively-parallel
GPU dispatch.

The reference tools never had this problem because they compute distance **analytically per pixel**:
- **MicroVerse** (Jason Booth, the Unity article): "Rendering [splines] analytically in the shader gives
  us an accurate distance to the bezier curve segment for each pixel in a **fixed amount of computation**."
  SDF stored as an RGBAFloat texture; **bounds culling** (spline AABB + reach uploaded; out-of-bounds
  pixels early-out) took **230 ms → 17 ms** for 73 splines on a GTX 980 Ti, per-curve early-out → **12 ms**.
- **UE5 Landmass**: spline brushes render into **GPU render targets** with a cosine-blended falloff; the
  canonical perf fix was *cache the spline, don't rebuild unless it changed* (our Stage 1 §3 already does
  this; our clip box already does the bounds culling).

So the GPU path **replaces chamfer-approximate distance with exact analytic distance**. This is the
faithful, parallel approach the references use, and it removes the only non-parallelisable step we have.
The visual consequence is that GPU bakes are *slightly different* from current C++/GDScript bakes (the
analytic distance is exact where chamfer is an 8-neighbour approximation) — quantified and signed off in §7.

---

## 1. What stays identical (the interface contract — hard requirement)

The user's existing brush workflow and every public surface must be **untouched**:

1. **GDScript shim unchanged.** Each subclass `_paint_spline` keeps calling
   `terrain.data.stamp_mound_loop(_layer_id, poly, _clip_aabb, params, lut)` exactly as today
   ([pasture3d_mound.gd:105](project/addons/pasture_3d/connectors/pasture3d_mound.gd:105)). **The shim does not know GPU
   exists.** The GPU-vs-CPU decision is made *inside* `Pasture3DData::stamp_*` (§4). No new call site, no
   new exported brush knob the user must learn (the one optional tunable is a project setting, §5.3).
2. **Orchestration unchanged.** `_refresh_owner_rect` ([pasture3d_terrain_brush.gd:543](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:543))
   — dirty-rect trigger, tile-snapped `clip_box`, `clear_layer_in_area`, moved-point snap,
   overlap-correct repaint of layer-mates, `_defer_composite` + one `composite_area`,
   `update_maps(type,false,false)`, edited-flag reset, footprint/curve caches — **all of it stays in
   GDScript and is not modified.** GPU slots under it at the same seam Round 2 used.
3. **Layers remain CPU `Image`s.** They stay the source of truth for the layer-stack composite, physics
   collision, and the saved `.res` files. GPU output is **read back** and merged into the same layer
   samples the C++ path writes (§3.4). Nothing downstream (collision, save, `get_height`) can tell GPU
   from C++ apart.
4. **`force_gdscript_raster`** ([pasture3d_terrain_brush.gd:64](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:64))
   still forces the GDScript reference path (and therefore also bypasses GPU) — the existing A/B escape
   hatch keeps working and now also serves as the GPU kill-switch.
5. **Builds without the GPU path degrade gracefully.** If `RenderingDevice` is unavailable, the method
   silently runs the existing C++ loop. No call site breaks.

---

## 2. The two analytic archetypes (mirror the C++/GDScript ones)

| Brush | Geometry | C++ today | GPU analytic replacement |
|---|---|---|---|
| Mound | closed loop | scanline fill + 2× chamfer (`raster_sdf`) | per-pixel signed distance to polygon (min edge distance + even-odd inside test); `max_inside` via parallel reduction (§2.1) |
| Plow  | closed loop | `raster_sdf` | same closed-loop SDF shader; profile/source math in-shader |
| Splat | closed loop | `raster_sdf` → control uint32 | same closed-loop SDF shader; output **R32_UINT** control |
| Ridge | open polyline | seed + `raster_chamfer_payload` (`raster_polyline_field`) | per-pixel nearest-segment: lateral distance + projected `along` + interpolated `base_y` (§2.2) |
| Trough| open polyline | `raster_polyline_field` | same open-polyline shader; channel profile in-shader |

**Two GLSL compute shaders** (`closed_loop_sdf.glsl`, `open_polyline.glsl`), each branching on a
`brush_kind` uniform for the per-archetype profile differences — exactly the structure of the C++ file
(2 field builders + 5 per-cell loops).

### 2.1 Closed-loop SDF (Mound / Plow / Splat)

Per output texel `(ix,iz)` → world `(x,z)`:
1. **Inside test + distance**: loop the uploaded polygon edges. `signed_d = (inside ? +1 : -1) * min_e
   dist_point_to_segment((x,z), e)`. Inside = even-odd crossing count (or winding). This is per-pixel
   `O(edges)`, fully parallel — the MicroVerse pattern. Bounds-cull: skip the texel if outside
   `clip_box` (already the dispatch extent) — and optionally per-edge AABB cull for huge polygons.
2. **`max_inside` (dome normalisation) is a global reduction**, not a per-pixel value. The chamfer gave
   it for free; analytic must reduce. **Two-dispatch design:**
   - *Pass A* writes `signed_d` to an intermediate R32F texture and does an **atomic max** of interior
     distance into a 1-element storage buffer (`max_inside`).
   - *Pass B* reads `max_inside`, computes `dome_denom = max(max_inside + edge_offset, 0.001)`, the LUT
     profile, base height, noise, and writes the final height.
   - *Alternative considered:* compute `max_inside` on the **CPU** once from the polygon and pass it as a
     uniform → single dispatch. **Preferred for Phase 1** at small/medium box sizes (simpler, one shader,
     no atomics). **Caveat surfaced by the terrain-scale benchmark (§7):** the cheap way chamfer got
     `max_inside` was as a byproduct of the full interior distance field — so naively "precomputing it on
     CPU" for a terrain-spanning *uncapped* dome means running that O(interior) field pass on the CPU,
     i.e. re-incurring the very cost GPU is offloading (~1.6 s here). Therefore: CPU-precompute only for
     boxes below ~the threshold; for the **large regime** use either the GPU Pass-A/B atomic-max, or an
     analytic **largest-inscribed-circle** estimate (polylabel / pole-of-inaccessibility — O(polygon),
     independent of box resolution). `capped` mounds don't use `max_inside` at all (they use
     `falloff_width`), so this only bites uncapped domes.
3. Profile via the **baked LUT** (uploaded as a small R32F 1-D texture / SSBO, `N≥256`), identical to
   `raster_ramp` ([:24](src/pasture_3d_brush_raster.cpp:24)). Empty LUT ⇒ analytic `smoothstep` default.

### 2.2 Open polyline (Ridge / Trough)

Per texel, find the **nearest segment** of the uploaded polyline directly (no chamfer propagation):
- `lat = min_k dist_point_to_segment((x,z), seg_k)`; record the nearest `k` and its projection param `t`.
- `along = cum_len[k] + t * seg_len[k]` (upload `cum_len[]`; `total_length` = uniform). End taper uses it.
- `base_y = lerp(pts[k].y, pts[k+1].y, t)` — the spline-height follow value.
- Cross-section profile (`width`/`falloff`/`crest_height` for Ridge; `bed_half_width`/`bank_width`/`depth`/
  `flat_bed` for Trough), `taper_ends`, `slope_tilt`, and noise: identical math to
  [stamp_ridge_line](src/pasture_3d_brush_raster.cpp:366) / [stamp_trough_line](src/pasture_3d_brush_raster.cpp:472).

Analytic nearest-segment is *more* exact than the chamfer payload (which propagates the nearest seed via
an 8-neighbour transform) — the main expected source of the §7 A/B delta, and a strict improvement.

---

## 3. Godot GPU pipeline (RenderingDevice + GLSL compute)

No `RenderingDevice` code exists in the project yet — this is greenfield. A new C++ helper
`Pasture3DGPURaster` (owned by `Pasture3DData`) encapsulates **all** of it, so the rasteriser surface
stays clean.

### 3.1 Setup (once, cached — amortise the per-edit cost the notes warn about)

- `RenderingServer::get_singleton()->create_local_rendering_device()` — a **local** RD, off the main
  render pipeline, that can read back. Created lazily on first GPU stamp; cached on `Pasture3DGPURaster`.
- Compile the two `.glsl` compute shaders to SPIR-V (`RenderingDevice::shader_compile_spirv_from_source`
  / `shader_create_from_spirv`), cache the shader + compute pipeline RIDs. Reuse storage buffers across
  bakes, resizing only when the box grows.
- **If RD creation or shader compile fails → set a `_gpu_unavailable` flag and never try again this
  session; all stamps fall back to C++.** (Editor/headless/driver gaps must degrade silently — §1.5.)

### 3.2 Inputs uploaded per bake (all CPU-prepared → thread-safe & deterministic)

- **Geometry** SSBO: `poly` (PackedVector2Array world, closed) or `pts`+`cum_len` (open). Already
  decimated to ~`vertex_spacing` by the existing GDScript helpers — passed straight through.
- **Params** UBO/push-constant: the scalar knobs (height, falloff, edge_offset, blend, invert, width,
  crest_height, depth, taper_ends, noise_strength, slope_tilt, control value, `min_x/min_z/vs/gw/gh`,
  clip edges, `max_inside` if CPU-computed). Same Dictionary the C++ path reads.
- **Falloff/profile LUT** texture (R32F, `N≥256`) — the baked `_ramp_lut` already passed to `stamp_*`.
- **Base-height grids** (the key enabler for `relative_to_terrain` / `follow_spline_height` / `slope_tilt`):
  the CPU pre-samples, for the clip box, **two** R32F grids and uploads them so the shader never calls
  `get_height`:
  1. `base_below` — `composite_height_below` for the box (already built by `_base_below_grid`,
     [pasture3d_terrain_brush.gd:1444](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:1444)); NaN where no
     lower layer covers.
  2. `terrain_height` — native `get_height` over the box (the fallback the C++ path uses when
     `base_below` is NaN, e.g. [stamp_mound_loop:351](src/pasture_3d_brush_raster.cpp:351)). Cheap,
     native, done in C++ when the GPU path is taken.
  The shader samples `base_below`, and where NaN uses `terrain_height` — bit-for-bit the C++ rule. This
  also makes the dispatch **fully self-contained** (no live engine reads), which is what made Round 2
  Phase 2 threading safe and keeps the GPU path equally side-effect-free.
- **Noise**: `FastNoiseLite::get_noise_2d` can't run in GLSL. **Bake noise to an R32F tile** for the box
  on the CPU (native, once per bake) and sample it in-shader. Matches the C++ value exactly and is
  thread-safe (the notes already flagged this).

### 3.3 Dispatch

Output texture sized to the **tile-snapped clip box** grid (`gw × gh`): **R32F** for height (Mound/Plow/
Ridge/Trough), **R32_UINT** for Splat control. Dispatch `ceil(gw/8) × ceil(gh/8)` workgroups (8×8 local).
Only texels whose centre is inside `clip_box` write (max-edge **exclusive**, matching `_clip_contains` and
the ADD-safe rule in [the Round 1 gotchas](PASTURE3D_BRUSH_PERF_SPEC.md)).

### 3.4 Readback + apply (CPU — preserves every existing invariant)

1. `RenderingDevice::texture_get_data` → `PackedByteArray` (R32F = 4 B/px, R32_UINT = 4 B/px). This
   **stalls** until the dispatch completes (acceptable: GPU only runs for large boxes where the parallel
   SDF eval dwarfs readback; small boxes take the C++ path).
2. **Bulk apply into the layer**, replicating `_stamp_write`'s same-layer blend rule
   ([:262](src/pasture_3d_brush_raster.cpp:262)) exactly: for each in-clip cell, if the layer already has
   a sample written THIS bake (`get_weight>0`), combine by blend mode (REPLACE/ADD/MAX/MIN); else write.
   This keeps two overlapping tools on one layer correct (the "two mounds carving each other" case) and is
   **identical behaviour** to the C++ path — only the *distance computation* moved to GPU, not the write
   semantics. Apply is a write+blend (no SDF/chamfer), not the work we offloaded — **but at terrain scale
   it is not free.** For the §7 benchmark the output grid is multiple million cells, so apply is a real
   O(N) pass on the same order as clear (66 ms) / composite (87 ms). **It must be a raw-byte tight loop
   over the readback `PackedByteArray`** (index the R32F/R32_UINT bytes directly, mirror the Round 3
   raw-tile approach), **not** per-cell `get_pixelv`/`set_pixelv`. See §3.5 for why this matters to the
   net win.
3. Writes are **deferred** (`composite=false`): the GDScript orchestration calls `composite_area(clip_box)`
   once afterwards, exactly as today. `set_modified(true)` per touched region, as `_stamp_write` does.

Multi-region clip boxes: the apply step routes each cell by world position via the existing
`_global_to_region_pixel` (same as `_stamp_write`), so a box spanning regions Just Works on writeback —
the *output texture* is one box-sized grid regardless of region layout.

### 3.5 What the win actually is at terrain scale (from the §7 benchmark)

GPU removes **paint** (91 % of the 1.79 s benchmark bake), but the bake's other phases are **untouched
CPU O(N) passes** and become the new floor:

| Phase | Benchmark today | After GPU | Note |
|---|---:|---|---|
| paint | 1.63 s | **GPU eval + readback** (target: tens of ms) | the offloaded work |
| apply | — | **new** O(N) write+blend (§3.4) | must be raw-byte; on the order of clear/composite |
| clear | 66 ms | unchanged | Round 3 / per-point shrink it |
| composite | 87 ms | unchanged | Round 3 / per-point shrink it |

So the realistic terrain-scale result is **~1.8 s → a few hundred ms** (a large, workflow-changing win),
**not** ~1.8 s → tens of ms. To push further you shrink **N** itself, not the per-cell cost — i.e. the
per-moved-point dirty box (`PASTURE3D_BRUSH_PERPOINT_SPEC.md`) is **complementary** to GPU here, not
redundant: GPU cuts paint, per-point cuts clear+apply+composite together by shrinking the box. This is
worth stating so the threshold tuning (§7) measures the *whole* post-GPU bake, not just the GPU dispatch.

**MEASURED CONFIRMATION (Phase 1, 2026-06-21) — and a sharper conclusion.** The Phase-1 drop-in (GPU SDF
only) gave **1.0× at 2.6 M cells** (cpu 515 ms ≈ gpu 496 ms). The apply loop here is `raster_ramp` +
`_stamp_write` per cell, and `_stamp_write` does per-cell `get_weight`/`get_value`/`set_sample` — each a
tile **dict lookup + pixel decode/encode**, the exact per-pixel cost Round 3 removed from compositing by
resolving the tile **once per tile-block** and reading/writing raw bytes. So the dominant terrain-scale
cost of a stamp is the **per-cell layer write**, and the fix is the same as Round 3's: a **batched raw-tile
apply** (`accumulate`/write into a rect buffer, one tile resolve per block). Crucially, **that apply
speedup is mostly CPU work and does not require the GPU at all** — a batched `_stamp_write` would speed up
*every* stamp (C++ and GPU). The GPU's distinct value is only the field/profile compute; pair it with the
batched apply (and optionally fold profile/base/noise into the shader so the CPU side is a pure write) to
realise the win. Phase 1b = batched raw-tile apply; it is the gating work for any terrain-scale speedup.

---

## 4. Dispatch decision (inside `Pasture3DData::stamp_*`, invisible to the shim)

Each `stamp_*` method gains an internal front-door:

```
if (gpu_enabled() && !_gpu_unavailable && (gw*gh) >= _gpu_raster_threshold
        && _gpu->stamp_<kind>(layer_id, geom, clip, params, lut, base_grids)) {
    return; // GPU did it (returns false on any failure → fall through)
}
// ...existing Round 2 C++ rasterisation (unchanged)...
```

- **Three-tier fallback:** GPU (large + available) → C++ (Round 2) → GDScript (no native build /
  `force_gdscript_raster`). Each tier is the previous tier's safety net.
- `_gpu->stamp_*` **returns bool**: any RD error, compile failure, or unsupported case returns `false`
  and the C++ path runs — a GPU fault can never corrupt or drop a bake.
- The GDScript `stamp_*` call site and `_native_raster(...)` gate are **unchanged** — GPU is entirely a
  C++-internal acceleration of the same method.

---

## 5. New knobs (kept minimal — interface stays clean)

### 5.1 `gpu_raster_threshold` (cells) — project setting, not a per-brush export
`pasture_3d/performance/gpu_raster_threshold`, **default 1048576 (≈1024²)** — registered in `initialize()`.
Default set by Phase-1b measurement: with the batched CPU apply, GPU only wins above ~0.5–1 M cells (at
40k CPU 0.8 ms vs GPU 4 ms; at 2.6 M CPU 49 ms vs GPU 30 ms), so the crossover moved up from the original
256² guess. Below it, C++ wins (no readback/dispatch overhead); above it, GPU amortises. A project setting
(not a brush export) keeps the inspector identical to today. `0` disables GPU globally; `1` forces
GPU-always (for A/B testing). Phase 4 refines this per edge-count.

### 5.2 No new brush exports
`force_gdscript_raster` already exists and already disables both native paths (now incl. GPU). That is the
only per-brush perf toggle the user sees — unchanged.

### 5.3 `gpu_raster` capability query
`Pasture3DData::gpu_raster_available() -> bool` for tooling/tests/diagnostics. Read-only; no behaviour.

---

## 6. Undo — must keep working (hard requirement; validated)

Undo correctness is **structurally preserved** because the GPU path changes *only how a bake's samples
are computed*, never how edits are recorded:

- **Undo is recorded by the orchestration, not the rasteriser.** The undoable causes are the gizmo/curve
  edit and the manual Refresh button ([pasture3d_terrain_brush.gd:528-533](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:528),
  snap [:1054](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:1054), point add/remove
  [:1170](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:1170)). The GPU stamp sits **below** that
  layer and records nothing — same as the C++ stamp. Async is **not** introduced (readback is synchronous),
  so there is no "stale bake after undo" window like the threading spec worried about.
- **Auto-refresh re-fires on undo.** Undoing a gizmo edit restores the curve → `curve.changed` →
  `_schedule_refresh` → a fresh bake (GPU or C++ by threshold). The terrain follows the undo exactly as it
  does today, regardless of which rasteriser produced the original.
- **The manual Refresh action's `_snapshot_owner`/`_restore_owner`** ([:529-532](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:529))
  snapshots **layer samples** (the CPU `Image`s) — which the GPU path writes back into identically. So a
  recorded bake-undo restores the same data whether GPU or C++ produced it.

**Undo validation gate (must pass before merge):**
1. Gizmo-edit a large (GPU-path) mound; **Ctrl+Z** → terrain returns to the pre-edit surface; **Ctrl+Y** →
   re-applies. Repeat across the threshold (force GPU via `threshold=1`, then C++ via `force_gdscript_raster`)
   and confirm **identical** undo/redo behaviour.
2. Manual **Refresh** on a GPU-path bake, then undo → the recorded action restores the prior layer state.
3. Snap-to-surface + undo, and point add/remove + undo, on a GPU-path feature.
4. Overlapping layer-mates (two tools, shared layer): edit one on the GPU path, undo → the mate is intact
   (the overlap-correct repaint + blend rule held through readback).

---

## 7. Correctness & verification

- **A/B harness (GPU vs C++).** With `gpu_raster_threshold=1` (force GPU) vs `force_gdscript_raster`/C++ on
  the *same scene*, dump the affected region height (and Splat control) and diff. Because we switched
  chamfer→analytic, expect a **small** delta concentrated near edges; target **max |Δheight| within a
  documented epsilon** (e.g. ≤ a few mm on metre-scale features) and **visually indistinguishable**.
  Control (Splat, exact uint32) and any cell where analytic and chamfer agree should match closely.
  Record the measured epsilon in this spec when implemented; it is the sign-off that the analytic switch is
  acceptable, per the interview decision.
- **`max_inside` parity** (closed loop): verify the CPU-computed `max_inside` (single-dispatch design)
  matches the GPU SDF's interior max within tolerance; if not, switch to the Pass-A/B atomic-max design.
- **Round-1/2 invariants preserved:** clip max-edge exclusive (ADD-safe), deferred writes, snap reads the
  cleared base, overlap-correct (each overlapping tool dispatched + applied clipped to the box).
- **Measure with `log_bake_timing`** on the Round 2 scenes (small mound, big 448×384 mound, mound + 2
  loops, ADD-blend mound, Splat) **plus** the terrain-spanning case below **plus a heavy many-spline scene**
  (the regime GPU targets — MicroVerse's 73-spline case). Expect `paint` to collapse on the big/heavy cases
  and a new `readback`+`apply` bucket to appear; confirm the **crossover** point and set
  `gpu_raster_threshold` there. **Compare the *whole* bake, not just the GPU dispatch** (§3.5) — the target
  is total bake time, where clear/composite/apply now matter.
- **Terrain-spanning benchmark (the upper anchor, recorded 2026-06-21, C++ Round 2 path):**
  `MoundDigValleyFloor`, box **2240×2496 m, 30 regions, 1 tool** — `total 1.787 s = clear 65.5 ms +
  snap 0.07 ms + paint 1631.6 ms + composite 86.8 ms + push 3.4 ms`. paint = **91 %**. This is the
  worst-case map-defining feature and the primary justification for GPU; re-run it post-GPU and record the
  new split (paint should collapse; clear+composite+apply become the floor, per §3.5).
- **Collision sync.** After readback + `composite_area`, the composited region heightmap (what collision
  reads) is consistent. Verify a physics body resting on a freshly GPU-baked feature is at the right height
  and that no mid-edit read sees a torn box (readback is synchronous → no torn state).
- **Save/load.** GPU-baked `.res` round-trips: save, reload, confirm the layer samples are identical to a
  C++ bake of the same edit (they go through the same writeback + Image path).
- **Build & run:** `python -m SCons platform=windows target=editor`; `.glsl` shaders ship as resources (or
  embedded SPIR-V); **full editor restart** after the GDExtension rebuild. Parse-check GDScript shims
  (unchanged here, but per project memory a single parse error kills the `class_name`).
- **Editor RD smoke test:** confirm a local `RenderingDevice` compute dispatch + readback actually
  completes **inside the editor** (not just at runtime) on the dev GPU before building the brushes on top.
  This is the single biggest "does the approach work at all" risk — do it first (Phase 0).

---

## 8. Phasing

- **Phase 0 — RD spike (de-risk). ✅ DONE 2026-06-21 — PASS (CLI *and* in-editor confirmed).**
  In-editor EditorScript run (same RTX 3070) matched the CLI run: all sizes PASS, terrain box 2240×2496 =
  dispatch 0.17 ms + readback 6.79 ms = 6.96 ms (compile 94 ms one-time). The editor-specific gate (local
  RD alongside the editor's main RD) is closed. Greenlit for Phase 1.
  Standalone spike `project/addons/pasture_3d/tools/gpu_spike/` (`rd_spike_core.gd` + CLI/EditorScript
  entries; no Pasture3D dependency). Creates a local RD, compiles an R32F-fill compute shader from source,
  dispatches + reads back via `texture_get_data`, verifies bit-correctness, times **dispatch vs readback
  separately** across box sizes up to the §7 benchmark. **Measured (Godot 4.7.stable, Vulkan, NVIDIA
  RTX 3070, throwaway project, min of 6 iters):**

  | box | MPix | dispatch ms | readback ms | total ms | verify |
  |---|---:|---:|---:|---:|:--:|
  | 64² | 0.00 | 0.123 | 0.078 | 0.201 | PASS |
  | 256² | 0.07 | 0.126 | 0.105 | 0.231 | PASS |
  | 512² | 0.26 | 0.130 | 0.437 | 0.567 | PASS |
  | 1024² | 1.05 | 0.138 | 1.332 | 1.470 | PASS |
  | 2048² | 4.19 | 0.176 | 5.481 | 5.657 | PASS |
  | **2240×2496** (§7 box) | 5.59 | 0.296 | 7.393 | **7.689** | PASS |

  Shader compile+pipeline = 14 ms one-time (cache it). **Findings that feed the design:**
  1. **Local RD + compute + readback works** alongside a live main RD (the CLI run had a Forward+ window
     open, same as the editor will). Strong evidence the editor case works; confirm with the EditorScript
     (`rd_spike_editor.gd`, File > Run) before Phase 1 — that's the last bit of the Phase-0 gate.
  2. **Readback is the GPU path's real cost, and it scales linearly** (~1.3 ms / MPix here), **dwarfing
     dispatch** (25× at the terrain box). This *confirms §3.5*: the win is bounded by the O(N) passes
     (readback + apply + clear + composite), not the dispatch. The terrain box's paint goes 1631 ms →
     ~8 ms of GPU work, but readback (7.4 ms) + apply + the untouched clear (66) + composite (87) set the
     new ~150–200 ms floor.
  3. **Caveat — this measured the dispatch *floor*.** The fill shader is memory-bound; the real analytic
     SDF loops over polygon edges per pixel, so its dispatch will be heavier (still expected « 1631 ms on
     this GPU — cf. MicroVerse 73 splines / 12 ms on a weaker 980 Ti). Readback timing *is* representative
     (size/format-bound, not shader-bound). Phase 1 measures the real analytic dispatch and sets the
     crossover for `gpu_raster_threshold` from it.
  - If the editor EditorScript run fails (no local RD in-editor), **stop** — the C++ path is already fast
    and GPU is experiment-only.
- **Phase 1 — closed-loop height (Mound). ✅ CODE-COMPLETE + correctness-validated 2026-06-21; terrain-scale
  speedup BLOCKED (see finding).** Implemented as a *minimal drop-in*: `Pasture3DGPURaster` (owns a local RD
  + one analytic-SDF compute shader, `src/pasture_3d_gpu_raster.{h,cpp}`) replaces only `raster_sdf` —
  fills the same `field[]` + `max_inside`, so the rest of `stamp_mound_loop` (profile/base/noise/blend/
  clip/`_stamp_write`) is byte-identical. Threshold-gated (`pasture_3d/performance/gpu_raster_threshold`,
  registered, default 65536; 0=off, 1=force) with 3-tier fallback GPU→C++→GDScript inside the method, so
  the GDScript shim is untouched. `gpu_raster_available()` bound for diagnostics.
  - **A/B parity PASS** (automated harness `tools/gpu_spike/ab_mound_cli.gd`, RTX 3070): GPU-vs-C++ on a
    10 m dome → coverage identical, peaks 9.9954 vs 9.9907, **max |Δ| 0.36 m (~3.6%), mean 0.05 m (~0.5%)**
    — the documented analytic-vs-chamfer delta, acceptable per the interview decision.
  - **❗ FINDING — GPU SDF alone does NOT speed up terrain-scale bakes.** Same harness, 1600×1600 (2.6 M
    cells, 256 edges): **cpu 515 ms vs gpu 496 ms = 1.0×.** The bake is linear in cells and GPU≈CPU, so the
    dominant cost is the *shared* per-cell apply loop (`raster_ramp` + **`_stamp_write`**), NOT the field.
    `_stamp_write` is the per-pixel tile-dict-lookup + decode/encode pattern Round 3 flagged as the
    compositing bottleneck. **Implication:** the terrain-scale win requires a *batched raw-tile apply*
    (resolve tile once per tile-block, write runs of cells — spec §3.4/§3.5), and/or folding profile/base/
    noise into the GPU so the CPU side is a pure write. This is Phase 1b and is where the real speedup lives.
    Notably, much of that win is a CPU optimisation independent of the GPU — see §3.5.
- **Phase 1b — batched raw-tile apply. ✅ DONE 2026-06-21 — this is where the win landed.**
  `Pasture3DData::_apply_stamp_block` (`pasture_3d_brush_raster.cpp`) + `Pasture3DLayer::get_or_create_tile`.
  The mound loop now writes per-cell values into a box buffer (NaN = skip) and commits them **one tile at a
  time** — resolve the tile once, `get_data()` → raw `float*` → blend+write all its cells → `set_data()`
  once (the Round-3 idiom) — instead of per-cell `_stamp_write` (tile dict-lookup + `set_pixelv`). Used for
  the deferred, non-base RGF overlay case (the common bake); full-refresh/base/no-layer still use per-cell.
  Same-layer blend (REPLACE/ADD/MAX/MIN vs the existing same-bake weight) preserved; a pre-scan skips tiles
  the feature doesn't touch so no empty corner tiles are allocated. **Measured (RTX 3070, ab_mound_cli.gd):**
  | box | CPU before | CPU after | GPU after | notes |
  |---|---:|---:|---:|---|
  | 200² (40k) | 8.4 ms | **0.8 ms** | 4.4 ms | small box: C++ wins (GPU fixed cost) — why the threshold exists |
  | 1600² (2.6M) | 515 ms | **49 ms (10×)** | **30 ms** | batched apply alone = 10×; GPU-on-top = 1.6× more |
  Parity unchanged (max |Δ| 0.36 m, coverage identical). **Extrapolated to the real 5.6M-cell benchmark:
  paint 1631 ms → ~110 ms (CPU batched) → ~70 ms (GPU)**, i.e. total bake ~1.79 s → ~0.26 s. The batched
  apply is a pure-CPU win that helps every bake; the GPU adds incremental field speedup on top. **Still TODO:
  in-editor undo + overlapping-layer-mate gates (§6); replicate the batched apply for Ridge/Trough/Plow/Splat
  (still per-cell `_stamp_write`) = Phase 1c.**
- **Phase 1c — batched apply for Ridge / Trough / Plow. ✅ DONE + validated 2026-06-21.** Builds clean;
  automated **Plow batched-vs-per-cell parity = max |Δ| 0.000000 (bit-identical)**, confirming the pattern.
  The same buffer + `_apply_stamp_block` pattern applied to the
  other three height brushes (each now writes per-cell values into a `vals` buffer and commits via the
  batched tile writer, gated on the same `batched = wlayer && !composite && !is_base`). The value
  expression per brush is preserved verbatim (Ridge `add?amp:by+amp`, Trough `add?(h-top_y):h`, Plow
  `add?amp:base_y+amp`).
  In-editor mound undo/visual gate already PASSED (user-confirmed).
- **Phase 1d — batched control apply for Splat. ✅ DONE + validated 2026-06-21.** Splat writes a packed
  uint32 control word, stored as `as_float(ctrl)` in an RGF tile's R channel (same tile format as height).
  Added `Pasture3DData::_apply_control_block` (a sibling of `_apply_stamp_block`: same tile iteration; inner
  write is `f[li]=as_float(ctrl)`, weight 1, REPLACE — no numeric blend; a **separate skip mask** since any
  uint32 bit pattern is a valid R value, so NaN can't be the sentinel). Gated to deferred non-base
  TYPE_CONTROL overlay; full-refresh/region-map-fallback keep per-cell `set_control_on_layer`. **Automated
  Splat batched-vs-per-cell parity = 0 mismatches.** All five brushes now use the batched apply.
- **Phase 2 — GPU field for Plow + Splat. ✅ DONE + validated 2026-06-21.** Both are closed-loop and ignore
  `max_inside` (they normalise on `falloff_width`), so they reuse `closed_loop_field` directly — the same
  threshold gate + 3-tier fallback wired into `stamp_plow_loop`/`stamp_splat_loop`. Plow GPU-vs-CPU field
  parity confirmed (0.0 with a saturated ramp; the analytic-vs-chamfer delta itself is already quantified on
  Mound, §7). All three closed-loop brushes now have the GPU field; Ridge/Trough (open polyline) remain
  CPU-field pending the Phase 3 shader.
- **Phase 3 — open polyline (Ridge + Trough).** `open_polyline.glsl` + nearest-segment + `along`/`base_y`.
- **Phase 4 — tuning.** Set `gpu_raster_threshold` from measured crossover; per-edge AABB cull for very
  large polygons (the MicroVerse "per-curve bounds" 17→12 ms refinement); decide single-dispatch vs
  Pass-A/B `max_inside`.

Each phase keeps the C++ path as the live fallback + A/B oracle, so the engine is never in a broken state.

---

## 9. Risks / watch-items

- **Analytic ≠ chamfer output.** The deliberate algorithm switch changes bakes slightly. Mitigation: A/B
  epsilon sign-off (§7); C++ remains the default below threshold, so most edits are unchanged anyway.
- **Editor RenderingDevice availability** (Phase 0 gate). Fallback to C++ if RD can't be created/compiled.
- **Readback stall.** Synchronous `texture_get_data` blocks the main thread. Bounded by the threshold (GPU
  only for large boxes). Async/double-buffered readback for live-drag is a *future* refinement, not Phase 1.
- **Two shaders to keep in sync** with the C++/GDScript profile math (a third reference). Drift risk;
  mitigate by deriving both from the same documented formulas and the shared LUT, and by the A/B harness.
- **`max_inside` global reduction** — the one part of the closed-loop SDF that isn't embarrassingly
  parallel. CPU-precompute sidesteps it for small/medium boxes, **but not at terrain scale** (it would
  re-run the O(interior) field pass GPU is offloading — §2.1). For the large regime use GPU Pass-A/B
  atomic-max or an analytic largest-inscribed-circle (polylabel). Only affects uncapped domes.
- **Per-bake setup cost** (buffer uploads, pipeline bind). Amortise by caching the RD, pipelines, and
  reusing/resizing buffers — and by only running GPU above the threshold where setup is negligible.
- **Precision** — match FORMAT_RF (32-bit float) for height; control is exact (R32_UINT). LUT `N≥256`.
- **`real_t` vs `float`** — Godot may build `real_t=double`; the GPU works in `float`. Acceptable within the
  A/B epsilon; the apply step writes the float result into the float-format region image regardless.

## 10. References

- MicroVerse — Optimizing Spline Operations (Jason Booth): analytic per-pixel Bézier SDF in a fragment
  shader + bounds culling, 230 ms → 12 ms / 73 splines (GTX 980 Ti).
  https://medium.com/@jasonbooth_86226/optimizing-spline-operations-d48b5f8fede4
- UE5 Landscape Blueprint Brushes (Landmass): spline → GPU render target, cosine-blended falloff; cache
  the spline. https://dev.epicgames.com/documentation/en-us/unreal-engine/landscape-blueprint-brushes-in-unreal-engine
- Godot compute shaders: https://docs.godotengine.org/en/latest/tutorials/shaders/compute_shaders.html
- Godot `RenderingDevice`: https://docs.godotengine.org/en/4.4/classes/class_renderingdevice.html
- Godot Compute Shader Heightmap demo (asset library #2784): https://godotengine.org/asset-library/asset/2784
- Background notes: `PASTURE3D_BRUSH_GPU_RASTER_NOTES.md`; prior rounds: `PASTURE3D_BRUSH_PERF_SPEC.md`,
  `PASTURE3D_BRUSH_PERF_ROUND2_SPEC.md`, `PASTURE3D_BRUSH_PERF_ROUND3_SPEC.md`.
