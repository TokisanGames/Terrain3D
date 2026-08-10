# Pasture3D Brush Performance — Round 3 Spec: Faster Compositing

Status: **A IS BUILT** (`_composite_height_region` accumulates per layer into a rect buffer via
`_accumulate_height`, resolving each tile once — [pasture_3d_data.cpp:1329](src/pasture_3d_data.cpp:1329)).
**B and C remain unbuilt**; `_reads_base_height` does not exist anywhere in the tree. The original status
line below said the whole round was unstarted, which was stale by at least one landing and misled a later
piece of work into planning to build A a second time — corrected 2026-08-09.

Both remaining parts are now **less urgent** than the ratio in §0 suggests: the full-refresh bake used to
call `composite_region` on a 1×1 rect per cell, and no longer does
(`PASTURE3D_POND_LARGE_LAKE_SPEC.md` §3), so the composite they optimise is a great deal cheaper than
when this was written. The "clear 64 + composite 86 + paint 54" split was measured on a ~205 ms bake.

Original status: design agreed 2026-06-20, branch `perf/compositing-round3`. After Round 2 the rasterisation
(`paint`) is no longer the bottleneck; **compositing the box area (clear + composite_area) now dominates**
a bake (big-mound bake ~205 ms = clear 64 + composite 86 + paint 54). Round 3 attacks compositing via
three changes: **A raw/cached-tile composite** (core), **C per-region layer culling** (cheap add-on),
**B drop the redundant pre-paint composite** when no brush reads `get_height`. (Box-size shrink **D** is a
separate later round — `PASTURE3D_BRUSH_PERPOINT_SPEC.md`.)

## 0. Why compositing is slow (measured + code)

`_composite_height_region` (and control/color) walks **every pixel × every layer**, calling the layer's
`get_weight()` and `get_value()` per pixel ([pasture_3d_layer.cpp:155](src/pasture_3d_layer.cpp:155)).
Each does a **Dictionary tile lookup** (`_get_tile_ptr`: region → tiles → tile_coord) **plus** an
`Image::get_pixelv` decode. So **2 dict lookups + 2 pixel decodes per pixel per layer**, even though the
tile is constant across a 64×64 block. For a 384² box × ~4 layers that's ~1.2M dict lookups + ~1.2M
decodes **per composite**, and the partial bake composites the box **twice** (clear + composite_area).

## A. Raw/cached-tile composite (core)

Restructure the per-region composite from "per-pixel, walk all layers (each re-looking-up its tile)" to
**per-layer accumulation into a rect-sized buffer, with the tile resolved once per tile-block**:

1. `_composite_height_region(region, loc, rect)` allocates `acc` (rect_w × rect_h `real_t`), init NaN.
2. For each height layer bottom→top (visible, TYPE_HEIGHT): call a new
   `Pasture3DLayer::accumulate_height(acc, acc_origin, acc_stride, loc, rect)` that:
   - iterates the **tiles** overlapping `rect` (not pixels); for each tile, resolves the tile `Image*`
     **once**, then for each pixel in `tile ∩ rect` reads value+weight directly and blends into
     `acc[px]` using the layer's blend mode + opacity + base-covered rule (the exact switch currently in
     `_composite_height_region`, moved into the layer where the tiles live).
3. Write `acc` back into the region height map (only non-NaN pixels), as today.

This removes the per-pixel dict lookups entirely (now one per tile per layer) and lets the inner read use
the cached tile. **Further (optional):** read the tile's raw bytes once per tile (`Image::get_data()` →
`PackedByteArray`, FORMAT_RF = 4 B/px float, FORMAT_RGF = 8 B/px) and index directly instead of
`get_pixelv`, eliminating the per-pixel decode dispatch too. Do the cached-pointer version first
(bigger, safer win); add raw-byte reads if more is needed.

Same restructure applies to `_composite_control_region` (topmost-covered-wins, no arithmetic) and
`_composite_color_region` (alpha-over). Control/color only run when an overlay of that type exists, so
height-only scenes are unaffected.

**Expected:** composite ~10–30× faster (150 ms clear+composite → ~10–20 ms).

## B. Drop the redundant pre-paint composite

The dirty-rect bake composites the box **twice**: once inside `clear_layer_in_area` (so the rasterisers'
`get_height` / the moved-point snap read the cleared base) and once in `composite_area` (the result). The
first is only needed when **something in the bake reads `get_height`**: `snap_to_surface`, or any tool on
the layer with `relative_to_terrain` / `follow_spline_height` **off** is the case that DOESN'T need it…
inverted: a tool reads the base when `relative_to_terrain==true` (Mound/Plow) or
`follow_spline_height==false` (Ridge/Trough), or when `snap_to_surface` is on.

- Add `_reads_base_height() -> bool` per subclass (true when its rasterise samples `get_height`).
- In `_refresh_owner_rect`: `needs_base = snap_to_surface or any sib._reads_base_height()`. Call
  `clear_layer_in_area(layer_id, clip_box, needs_base)` — composite during clear only when needed; the
  post-paint `composite_area` is always there. Saves one box composite when no base read is required.

Lower value than A (only some configs skip it), but cheap and clean once A lands.

## C. Per-region layer culling

Before a layer's per-pixel/per-tile work, skip it entirely if it has **no tile overlapping `rect`** in
this region (`layer->has_region(loc)` + a tile-overlap check). The current code pays a per-pixel
`get_weight==0` skip for such layers; a per-region early-out removes them from the inner loop. Falls out
naturally from A's per-tile iteration (a layer with no overlapping tile contributes no tiles → no work).

## Verification

- **Byte-identical output.** Compositing is correctness-critical and has no GDScript A/B oracle, so the
  bar is: the composited region height/control/color images must be **bit-identical** before vs after
  (same blend, NaN handling, opacity, base-covered, topmost-wins). Test: composite a scene both ways and
  compare region image data (a temporary debug compare, or hash the region images).
- Re-run `log_bake_timing` on the Round 2 scenes; expect `clear` + `composite` to drop sharply while
  `paint`/`push` are unchanged.
- Exercise multi-layer overlap (shared layers, several brush tools), control (Splat) + color overlays,
  undo/redo (uses `composite_region`), and the hand-sculpt brush (also composites) — all must look the
  same and stay correct.
- Build via SCons; full editor restart after rebuild; parse-check any GDScript (B) shims.

## Risks

- **Blend fidelity.** Moving the blend switch into the layer must reproduce REPLACE/ADD/MAX/MIN + NaN +
  opacity + base-covered EXACTLY. Keep the old `_composite_*_region` reachable (or a unit test) to diff
  against until trusted.
- **`Image::get_data()` copies** the tile (once per tile — amortised over its pixels). Fine; if it ever
  matters, the cached-`get_pixelv` variant avoids the copy.
- **Tile/rect clipping** off-by-one (tile ∩ rect) — the source of subtle seams; mirror the existing
  `_tile_coord` / `_tile_local` math.
