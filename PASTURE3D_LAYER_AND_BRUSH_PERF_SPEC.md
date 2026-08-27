# Pasture3D Layer Compositing & Brush Modifier Performance Specification

Status: Proposed (2026-08-27)
Target Components: C++ (`Pasture3DData`, `Pasture3DLayer`, `Pasture3DBrushRaster`), GDScript (`Pasture3DTerrainBrush`, `Pasture3DNodeRelief`)

---

## 1. Problem Statement & Executive Summary

Profiling of large-scale terrain editing operations revealed critical hot-path bottlenecks in the Layer Compositing subsystem and the Brush Modifier pipeline:

1. **Heap Allocation Storm during Height Accumulation**:
   `Pasture3DData::_accumulate_height()` calls `tile->get_region(...)` for every sub-tile intersection across every height layer during compositing. This instantiates hundreds of temporary Godot `Image` and `PackedByteArray` objects on the heap per pass.
2. **Dictionary & GDExtension Method Overhead in Control/Color Compositing**:
   `_composite_control_region()` and `_composite_color_region()` perform per-pixel sampling via `layer->get_weight()`, `layer->get_value()`, and `layer->get_sample()`. For a 512x512 region, this executes over 2.1 million Dictionary hash lookups, dynamic `cast_to<Image>` invocations, and GDExtension boundary calls per pass.
3. **COW Reallocation during Stamp Pixel Writing**:
   `Pasture3DData::_apply_stamp_block()` mutates tile data by retrieving `tile->get_data()` and writing back via `tile->set_data(...)`, forcing complete Godot `Image` data buffer reallocations on every stamp write.
4. **Single-Point Snapping Path Inefficiencies**:
   `Pasture3DData::get_height_below()` routes point surface snapping through `_accumulate_height()` with a 1x1 Rect, incurring the full tile-resolution and sub-region allocation overhead for each spline point.
5. **Stamp Cache Bypassing under Clipping**:
   `Pasture3DTerrainBrush._paint_into()` explicitly disables stamp cache reuse whenever `_clip_aabb` is active (`if not clipping and ...`), forcing expensive procedural re-evaluations during dirty-rect updates.
6. **Relief Modifier Drag Latency**:
   `Pasture3DNodeRelief` lacks freezing support (`_supports_freezing() = false`), forcing full CPU evaluation during interactive drags.

---

## 2. Architecture & Design

### 2.1 Layer Compositor Zero-Allocation Direct Buffer Traversal (Phase 1)

#### 2.1.1 Direct Pointer Traversal in `_accumulate_height()`
Instead of `tile->get_region(Rect2i(...))`, `_accumulate_height()` directly retrieves the raw pixel buffer via `tile->ptr()` (or `reinterpret_cast<const float *>(tile->ptr())`).
- Format `Image::FORMAT_RF`: Stride = 1 float (`value`).
- Format `Image::FORMAT_RGF`: Stride = 2 floats (`[value, weight]`).
- Coordinate offset for pixel `(x, y)` inside a tile located at `(bx, by)` with tile size `ts`:
  $$\text{index} = ((y - by) \cdot ts + (x - bx)) \cdot \text{stride}$$
- Zero heap allocations, zero temporary `Image` objects.

#### 2.1.2 Block-Based Direct Traversal for Control & Color Maps
- `_composite_control_region()`:
  - Allocate a single flat accumulator `std::vector<float> acc(rect_w * rect_h, NAN)`.
  - Seed `acc` from Base layer (if available) or existing `control_map->ptr()`.
  - Traverse active control overlay layers bottom-to-top, resolving each tile pointer once per tile block via `layer->get_tile(...)` and reading `fdata[fi]` and `fdata[fi + 1]`.
  - Overwrite `acc` where `weight > 0.0f` (topmost-covered-wins).
  - Bulk write back to `control_map->ptrw()`.
- `_composite_color_region()`:
  - Allocate a single flat accumulator `std::vector<Color> acc(rect_w * rect_h)`.
  - Seed RGB (albedo) and Alpha (roughness) from Base layer or `color_map->ptr()`.
  - Traverse active color overlay layers bottom-to-top, resolving `uint8_t` RGBA8 pointers once per tile block and blending RGB albedo via $c_{\text{acc}} = c_{\text{acc}} + (c_{\text{src}} - c_{\text{acc}}) \cdot (w \cdot \text{opacity})$ while leaving roughness untouched.
  - Bulk write back to `color_map->ptrw()`.

#### 2.1.3 In-Place Tile Mutation in `_apply_stamp_block()` & `_apply_control_block()`
- Access tile memory directly via `tile->ptrw()`:
  ```cpp
  float *f = reinterpret_cast<float *>(tile->ptrw());
  ```
- Mutate pixels in place and eliminate `tile->set_data(...)`.

---

### 2.2 Dedicated Fast-Path Surface Snapping (Phase 2)

- Add `Pasture3DData::get_height_below_point(int p_below_layer_id, const Vector2i &p_region_loc, const Vector2i &p_img_pos) -> real_t`:
  - Directly samples the layers below `p_below_layer_id` at `(p_region_loc, p_img_pos)` without creating `Rect2i`, allocating accumulator arrays, or performing bounding box intersections.
  - Evaluates layers bottom-to-top with REPLACE, ADD, MAX, MIN blend modes.
- `get_height_below()` delegates directly to `get_height_below_point()`.

---

### 2.3 Brush Modifier & Partial Stamp Cache Optimization (Phase 3)

1. **Stamp Cache Blitting under Clipping**:
   - In `Pasture3DTerrainBrush._paint_into()`, allow cached stamp blitting via `apply_sim_block()` even when `clipping` is active, provided the stamp key matches and the spline is not dirty.
2. **Freezing Support in `Pasture3DNodeRelief`**:
   - Implement `_supports_freezing() -> bool: return true`.
   - Implement `clear_cache()`, `cache_bytes()`, `cache_for()`, `store_cache()`, and `set_stale()` on `Pasture3DNodeRelief`.

---

## 3. Verification & Gate Benchmarks (Phase 4)

1. **Compilation**: SCons build with `target=template_debug dev_build=yes`.
2. **Headless Execution**:
   - `bench/BrushStackGate.tscn` (Verifies bitwise modifier stack precision and caching).
   - `bench/BrushErosionGate.tscn` (Verifies erosion modifiers and stamp application).
   - `bench/SimPhase7Gate.tscn` (Verifies threaded simulation and data consistency).
   - `bench/GraphCppParityGate.tscn` (Verifies C++ terrain graph evaluation parity).
