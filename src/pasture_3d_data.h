// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef PASTURE3D_DATA_CLASS_H
#define PASTURE3D_DATA_CLASS_H

#include "constants.h"
#include "generated_texture.h"
#include "pasture_3d_layer_stack.h"
#include "pasture_3d_region.h"

class Pasture3D;

class Pasture3DData : public Object {
	GDCLASS(Pasture3DData, Object);
	CLASS_NAME();
	friend Pasture3D;
	// Phase 5 tool-API test drives the global->region math, which normally needs a Pasture3D node to
	// set _region_size / _vertex_spacing. Friending lets the standalone test configure them directly.
	friend void test_layer_road_connector();
	friend void test_layer_subtiling(); // Phase 6 test; same descale-field access as above.
	friend void test_layer_control_color(); // Phase 7 test; same descale-field access as above.
	friend void test_layer_region_size_change(); // change_region_size x layer-stack migration test.

public: // Constants
	static inline const real_t CURRENT_DATA_VERSION = 0.93f; // Current Data format version
	static inline const int REGION_MAP_SIZE = 32;
	static inline const Vector2i REGION_MAP_VSIZE = V2I(REGION_MAP_SIZE);

	enum HeightFilter {
		HEIGHT_FILTER_NEAREST,
		HEIGHT_FILTER_MINIMUM
	};

	// SLICED writes the whole terrain as one image, cut into 16384 px tiles because that is the
	// ceiling most image formats and GPUs accept -- a terrain wider than that used to produce one
	// oversized file. PER_REGION writes one file per region, named by location.
	enum ExportMode {
		EXPORT_SLICED,
		EXPORT_PER_REGION
	};

private:
	Pasture3D *_terrain = nullptr;

	// Data Settings & flags
	int _region_size = 0; // Set by Pasture3D::set_region_size
	Vector2i _region_sizev = V2I(_region_size);
	real_t _vertex_spacing = 1.f; // Set by Pasture3D::set_vertex_spacing

	AABB _edited_area;
	Vector2 _master_height_range = V2_ZERO;

	/////////
	// Pasture3DRegions house the maps, instances, and other data for each region.
	// Regions are dual indexed:
	// 1) By `region_location:Vector2i` as the primary key. This is the only stable index
	// so should be the main index for users.
	// 2) By `region_id:int`. This index changes on every add/remove, depends on load order,
	// and is not stable. It should not be relied on by users and is primarily for internal use.

	// Private functions should be indexed by region_id or region_location
	// Public functions by region_location or global_position

	// `_regions` stores all loaded Pasture3DRegions, indexed by region_location. If marked for
	// deletion they are removed from here upon saving, however they may stay in memory if tracked
	// by the Undo system.
	Dictionary _regions; // Dict[region_location:Vector2i] -> Pasture3DRegion

	// All _active_ region maps are maintained in these secondary indices.
	// Regions are considered active if and only if they exist in `_region_locations`. The other
	// arrays are built off of this index; its order defines region_id.
	// The image arrays are converted to TextureArrays for the shader.

	TypedArray<Vector2i> _region_locations;
	TypedArray<Image> _height_maps;
	TypedArray<Image> _control_maps;
	TypedArray<Image> _color_maps;

	// Editing occurs on the Image arrays above, which are converted to Texture arrays
	// below for the shader.

	// 32x32 grid with region_id:int at its location, no region = 0, region_ids >= 1
	PackedInt32Array _region_map;
	bool _region_map_dirty = true;

	// These contain the TextureArray RIDs from the RenderingServer
	GeneratedTexture _generated_height_maps;
	GeneratedTexture _generated_control_maps;
	GeneratedTexture _generated_color_maps;

	// Optional editor-only non-destructive layer stack. Null on plain terrains; the region images
	// above remain the composited source of truth either way, so the runtime path is unchanged.
	Ref<Pasture3DLayerStack> _layer_stack;

	// GPU analytic rasteriser (PASTURE3D_BRUSH_GPU_RASTER_SPEC.md). Lazily created on the first large
	// stamp; owns a local RenderingDevice. Null until used; freed in _clear(). Plain pointer (not an
	// Object/Ref) — it is internal infrastructure, not exposed to the engine.
	class Pasture3DGPURaster *_gpu_raster = nullptr;
	// Lazily create + return the GPU rasteriser, or nullptr if GPU rasterisation is disabled
	// (gpu_raster_threshold == 0) or unavailable. Cheap to call repeatedly.
	class Pasture3DGPURaster *_ensure_gpu_raster();
	// Project-setting threshold (cells) at/above which a stamp box uses the GPU path. 0 disables GPU;
	// 1 forces GPU-always (testing). Reads `pasture_3d/performance/gpu_raster_threshold`.
	int _gpu_raster_threshold() const;

	// Functions
	void _clear();
	void _synthesize_base_layer();
	// Whether the dense Base layer (index 0) still aliases the region height maps (same Ref<Image>).
	// Aliasing is the zero-copy load state; it is correct for a single flatten but double-applies
	// ADD/MAX/MIN under live re-compositing, so the Base must be un-aliased before per-stroke editing
	// (PASTURE3D_LAYERS_GUIDE.md §5.1). Detected by pointer identity so tests need no extra flag.
	bool _is_base_aliased() const;
	// Give the Base its own source buffer (deep copy of each aliased region tile) so the composite
	// target (region->_height_map) and the Base source become distinct. Idempotent.
	void _unalias_base_layer();
	// Convert a world position to its region location (out param) and region-local vertex pixel,
	// reusing the set_pixel math. Used by the layer-targeted tool-API writes (PASTURE3D_LAYERS_GUIDE.md §8.2).
	Vector2i _global_to_region_pixel(const Vector3 &p_global_position, Vector2i &r_region_loc) const;
	// Region-local vertex rect (clamped to [0, region_size]) covered by a world-space AABB's XZ extent,
	// for one region location. Used to scope a sub-tile clear to the footprint of a tool re-render.
	Rect2i _region_pixel_rect(const AABB &p_area, const Vector2i &p_region_loc) const;
	// Per-map-type compositing passes (Phase 7), each writing one region map over the given rect:
	//   height  — REPLACE/ADD/MAX/MIN blend (unchanged; byte-identical to pre-Phase-7).
	//   control — topmost-covered-wins; a covered overlay fully replaces the value below (no float blend).
	//   color   — alpha-over: acc.rgb = lerp(below, overlay.rgb, weight*opacity); roughness (alpha) kept.
	// control/color seed from the dense base of that map type (the hand-authored source, distinct from
	// the region map being written), so a clear + recomposite is idempotent (§5.1).
	// Blend height layers [0, p_layer_end) over p_rect into p_acc (rect_w*rect_h, row-major, indexed by
	// (y-rect.y)*rect_w + (x-rect.x); pre-filled with NaN by the caller). Shared by the full height
	// composite and composite_height_below. p_acc is a raw pointer to avoid <vector> in the header.
	void _accumulate_height(real_t *p_acc, const Vector2i &p_region_loc, const Rect2i &p_rect, const int p_layer_end);
	void _composite_height_region(Pasture3DRegion *p_region, const Vector2i &p_region_loc, const Rect2i &p_rect);
	void _composite_control_region(Pasture3DRegion *p_region, const Vector2i &p_region_loc, const Rect2i &p_rect);
	void _composite_color_region(Pasture3DRegion *p_region, const Vector2i &p_region_loc, const Rect2i &p_rect);
	// Lazily create the dense base layer for a control/color map type, seeded from the current region
	// maps (the hand-authored control/color). Idempotent; returns the base layer index or -1.
	int _ensure_typed_base(const MapType p_map_type);
	// Make every base layer (height/control/color) cover a newly added region by adopting its region map
	// (alias for a single-layer height base, an owned copy otherwise). Skipped during initial load.
	void _adopt_region_into_bases(Pasture3DRegion *p_region);
	// Re-map the layer stack's pixel data onto the new region grid at the end of change_region_size.
	// change_region_size snapshots each layer's tiles/tile size (p_old_tiles / p_old_tile_sizes) and
	// empties the layers up front, so base adoption during the region re-add works against the NEW grid;
	// this pass then restores the old pixels: base tiles are blitted back over the adopted seeds (the
	// hand-authored source must stay distinct from the composite, §5.1) and overlay tiles are re-keyed
	// to their new region/tile coordinates (global pixel positions are preserved).
	void _migrate_layers_region_size(const int p_old_size, const int p_new_size, const TypedArray<Dictionary> &p_old_tiles, const PackedInt32Array &p_old_tile_sizes);
	void _copy_paste_dfr(const Pasture3DRegion *p_src_region, const Rect2i &p_src_rect, const Rect2i &p_dst_rect, const Pasture3DRegion *p_dst_region);
	Error _save_export_image(const Ref<Image> &p_img, const String &p_path, const String &p_ext, const MapType p_map_type) const;
	Rect2i _region_bounds_px() const;

public:
	Pasture3DData() {}
	void initialize(Pasture3D *p_terrain);
	~Pasture3DData() { _clear(); }

	// Regions

	int get_region_count() const { return _region_locations.size(); }
	void set_region_locations(const TypedArray<Vector2i> &p_locations);
	TypedArray<Vector2i> get_region_locations() const { return _region_locations; }
	TypedArray<Pasture3DRegion> get_regions_active(const bool p_copy = false, const bool p_deep = false) const;
	Dictionary get_regions_all() const { return _regions; }
	PackedInt32Array get_region_map() const { return _region_map; }
	static int get_region_map_index(const Vector2i &p_region_loc);

	void do_for_regions(const Rect2i &p_area, const Callable &p_callback);
	void change_region_size(int region_size);

	Vector2i get_region_location(const Vector3 &p_global_position) const;
	int get_region_id(const Vector2i &p_region_loc) const;
	int get_region_idp(const Vector3 &p_global_position) const;

	bool has_region(const Vector2i &p_region_loc) const { return get_region_id(p_region_loc) != -1; }
	bool has_regionp(const Vector3 &p_global_position) const { return get_region_idp(p_global_position) != -1; }
	Ref<Pasture3DRegion> get_region(const Vector2i &p_region_loc) const;
	Pasture3DRegion *get_region_ptr(const Vector2i &p_region_loc) const;
	template <typename T> // Catch invalid types. See note below in implementation.
	Pasture3DRegion *get_region_ptr(const T &p_region_loc) const = delete;
	Ref<Pasture3DRegion> get_regionp(const Vector3 &p_global_position) const;

	void set_region_modified(const Vector2i &p_region_loc, const bool p_modified = true);
	bool is_region_modified(const Vector2i &p_region_loc) const;
	void set_region_deleted(const Vector2i &p_region_loc, const bool p_deleted = true);
	bool is_region_deleted(const Vector2i &p_region_loc) const;

	Ref<Pasture3DRegion> add_region_blankp(const Vector3 &p_global_position, const bool p_update = true);
	Ref<Pasture3DRegion> add_region_blank(const Vector2i &p_region_loc, const bool p_update = true);
	Error add_region(const Ref<Pasture3DRegion> &p_region, const bool p_update = true);
	void remove_regionp(const Vector3 &p_global_position, const bool p_update = true);
	void remove_regionl(const Vector2i &p_region_loc, const bool p_update = true);
	void remove_region(const Ref<Pasture3DRegion> &p_region, const bool p_update = true);

	// Layer stack (editor-only, optional)
	bool has_layer_stack() const { return _layer_stack.is_valid(); }
	Ref<Pasture3DLayerStack> get_layer_stack() const { return _layer_stack; }
	void set_layer_stack(const Ref<Pasture3DLayerStack> &p_stack) { _layer_stack = p_stack; }

	// True when sculpt strokes should route into the active layer instead of writing the region image
	// directly: a real layer exists above the Base (count > 1). A Base-only stack (plain terrain, or a
	// brand-new one) behaves exactly as before until the user adds a layer. By the un-alias invariant
	// count > 1 implies the Base owns its own buffer. See PASTURE3D_LAYERS_GUIDE.md §6.
	bool is_layer_routing() const { return _layer_stack.is_valid() && _layer_stack->get_layer_count() > 1; }
	// Lazily create a single "Base" layer for a terrain that has none yet (e.g. a freshly added node
	// that was never loaded from disk), so the Layers panel can show and grow the stack. Returns
	// whether a stack exists afterward.
	bool ensure_layer_stack();

	// Layer-stack management surfaced for the GDScript Layers panel. These wrap Pasture3DLayerStack
	// and additionally un-alias the Base (when the first non-Base layer appears) and recomposite the
	// affected regions so the viewport stays live (PASTURE3D_LAYERS_GUIDE.md §5.2, §6). They return the
	// new index where relevant, or -1 on failure.
	//
	// All of these — plus create_owned_layer(_typed) when it actually creates — emit `layers_changed`.
	// It exists because the Layers dock had no way to hear about a layer it did not create itself: a
	// tool node calling create_owned_layer (a brush's "Add New Layer", a road connector, the Sim) left
	// the dock showing a stale row list until the user re-selected the terrain. Structural changes only,
	// never per-sample writes, so a bake does not drag the UI along with it.
	int layer_add(const String &p_name, const int p_blend_mode);
	int layer_duplicate(const int p_idx);
	void layer_remove(const int p_idx);
	void layer_move(const int p_from, const int p_to);
	// Recomposite every region the layer covers, then push a single GPU update. Call after changing a
	// layer's visibility, opacity, blend mode, or order.
	void recomposite_layer(const int p_idx);
	// Re-point an aliased (single-layer) Base onto the current region height maps. No-op once the Base
	// is un-aliased (multi-layer). Called after undo/redo swaps region objects so a later layer_add
	// un-aliases from the live region maps rather than a stale, detached image.
	void refresh_base_alias();

	// Compositing (editor-only). Flattens the layer stack down into the region height images that
	// drive the shader/collision and ship in the runtime .res files. A no-op when no stack exists,
	// so a build with no extra layers behaves exactly as before with zero added cost.
	// p_dirty_rect is in region-local vertex coordinates [0, region_size); an empty rect means the
	// whole region. With p_update, edited regions are pushed to the GPU via update_maps(TYPE_HEIGHT).
	void composite_region(const Vector2i &p_region_loc, const Rect2i &p_dirty_rect = Rect2i(), const bool p_update = true);
	void composite_regions(); // Composite every active region fully, then a single GPU update
	// Composite the dirty rect of a world-space AABB across every region it overlaps (no GPU upload unless
	// p_update). Lets a tool composite its whole footprint ONCE after a batch of no-composite layer writes,
	// instead of paying a per-pixel composite on each write — the dirty-rect counterpart of composite_region.
	void composite_area(const AABB &p_area, const bool p_update = false);
	// Below-layer sampling (PASTURE3D_BRUSH_BELOW_LAYER_SPEC.md): a brush's base reference = the composite
	// of the layers BENEATH its own, so features stop climbing each other / their own layer.
	// composite_height_below fills a gw*gh row-major grid (aligned to min_x/min_z, step vs) with the height
	// of layers [0, below_layer_id); NaN where uncovered. get_height_below is the single-point version (snap).
	PackedFloat32Array composite_height_below(const int p_below_layer_id, const double p_min_x, const double p_min_z, const double p_vs, const int p_gw, const int p_gh);
	real_t get_height_below(const int p_below_layer_id, const Vector3 &p_global_position);

	// Tool API (PASTURE3D_LAYERS_GUIDE.md §8). Lets generator/tool nodes (RoadPastureConnector) draw
	// into a reserved layer of their own instead of writing the Base destructively, so re-running them
	// is idempotent and hand-sculpting underneath survives. The *_on_layer writes convert global_pos to
	// a region_loc + region-local pixel, set the layer sample, and dirty-scope composite that pixel back
	// into the region image (no GPU upload — the tool calls update_maps once at the end). When no stack
	// exists, set_height_on_layer falls back to set_height so plain terrains keep working (§8.3).
	int get_layer_stack_size() const { return _layer_stack.is_valid() ? _layer_stack->get_layer_count() : 0; }
	int find_layer_by_owner(const String &p_owner_id) const;
	// Find an existing reserved layer by owner_id, or create one (named p_name, blend p_blend_mode) and
	// mark it reserved+owned. Un-aliases the Base when the new layer is the first non-Base layer. Returns
	// the layer index, or -1 if a Base could not be anchored. Idempotent by owner_id.
	int create_owned_layer(const String &p_owner_id, const String &p_name, const int p_blend_mode);
	// Like create_owned_layer but for a chosen map type (Phase 7). For TYPE_CONTROL/TYPE_COLOR it first
	// ensures the dense typed base exists (capturing the current hand-authored control/color), then adds
	// the reserved overlay. Holes/texture/color tools own a control/color layer this way (§8.3, §11.4).
	int create_owned_layer_typed(const String &p_owner_id, const String &p_name, const int p_blend_mode, const int p_map_type);
	// p_composite=false writes the layer sample but SKIPS the per-pixel composite, so a tool can batch many
	// writes and composite the whole footprint once via composite_area (much cheaper for large edits).
	void set_height_on_layer(const int p_layer_id, const Vector3 &p_global_position, const real_t p_height, const real_t p_weight = 1.f, const bool p_composite = true);
	// Write a packed control uint32 (or just a hole bit) into a control overlay layer, then dirty-scope
	// composite it back into the region control map. set_hole_on_layer reads the composited control at the
	// position, sets/clears the hole bit (preserving texture/nav/etc), and stores the full value at weight 1.
	// Both fall back to the destructive set_control/set_control_hole path when no stack/invalid layer (§8.3).
	void set_control_on_layer(const int p_layer_id, const Vector3 &p_global_position, const int p_control, const real_t p_weight = 1.f, const bool p_composite = true);
	void set_hole_on_layer(const int p_layer_id, const Vector3 &p_global_position, const bool p_hole);
	// Write an RGBA albedo + coverage weight into a color overlay layer, then dirty-scope composite it
	// (alpha-over). Falls back to set_color when no stack/invalid layer.
	void set_color_on_layer(const int p_layer_id, const Vector3 &p_global_position, const Color &p_color, const real_t p_weight = 1.f, const bool p_composite = true);
	void add_height_on_layer(const int p_layer_id, const Vector3 &p_global_position, const real_t p_delta, const real_t p_weight = 1.f, const bool p_composite = true);
	real_t get_layer_height(const int p_layer_id, const Vector3 &p_global_position) const;
	// Clear the layer's tiles in every region the area (world-space AABB, XZ used) overlaps, then
	// recomposite the cleared footprint so it falls back to what is below. Sub-tile precise (phase 6):
	// only the sub-tiles overlapping the AABB are dropped, so a co-located feature in another sub-tile
	// of the same region survives (the Phase 5 partial-refresh fix). Degrades to region-granular when
	// _tile_size == region size.
	// p_composite=false drops the tiles without recompositing (a tool that follows with a batch of writes
	// + one composite_area should pass false to avoid a redundant recomposite of the cleared footprint).
	void clear_layer_in_area(const int p_layer_id, const AABB &p_area, const bool p_composite = true);

	// Native spline-brush rasterisers (Round 2 perf): port of the GDScript Pasture3DTerrainBrush per-cell
	// loops. Each builds the field (closed-loop SDF / open polyline) over the grid in `params` and writes
	// the result into the layer DEFERRED (no per-pixel composite — the tool calls composite_area once).
	// Geometry is world-space + decimated; `clip` is the tile-snapped dirty box (max-edge exclusive);
	// `params` is a Dictionary of grid (min_x/min_z/vs/gw/gh) + shape knobs; `lut` is a 0..1 ramp LUT
	// (empty => analytic default). The GDScript keeps the equivalent loop as a fallback / A/B reference.
	void stamp_mound_loop(const int p_layer_id, const PackedVector2Array &p_poly, const AABB &p_clip, const Dictionary &p_params, const PackedFloat32Array &p_lut);
	void stamp_ridge_line(const int p_layer_id, const PackedVector3Array &p_pts, const AABB &p_clip, const Dictionary &p_params, const PackedFloat32Array &p_lut);
	void stamp_trough_line(const int p_layer_id, const PackedVector3Array &p_pts, const AABB &p_clip, const Dictionary &p_params, const PackedFloat32Array &p_lut);
	void stamp_plow_loop(const int p_layer_id, const PackedVector2Array &p_poly, const AABB &p_clip, const Dictionary &p_params, const PackedFloat32Array &p_lut, const PackedFloat32Array &p_src_data);
	void stamp_splat_loop(const int p_layer_id, const PackedVector2Array &p_poly, const AABB &p_clip, const Dictionary &p_params, const PackedFloat32Array &p_lut);
	// Capability query (spec §5.3): true if a local RenderingDevice + the analytic compute pipeline could
	// be created. For tooling/tests/diagnostics; read-only, no behaviour change. Bound to GDScript.
	bool gpu_raster_available();

	// ---- Pasture3DSim (PASTURE3D_SIM_NODE_SPEC.md) ----
	// The stream-power solver, exposed as a PURE function of a heightfield: no terrain is read or written,
	// so the phase-1 gates can drive it on synthetic fields. `z` is gw*gh row-major with NaN for no-data;
	// `params` carries the ErosionParams keys (see pasture_3d_erosion.h). Returns a Dictionary with "z"
	// (and, when params.want_diagnostics, "flow" / "lake_depth" / "receiver" / "stack" / "boundary").
	Dictionary erode_heightfield(const PackedFloat32Array &p_z, const Dictionary &p_params, const PackedFloat32Array &p_erodability);
	// NaN-aware corner-aligned grid resample: box-averages when shrinking a dimension, bilinear when
	// growing. Both grids span the same world rect, so sample (0,0) and (w-1,h-1) coincide. This is the
	// §6 preview/build bridge — heights DOWN onto the sim grid, deltas back UP onto the terrain grid.
	PackedFloat32Array resample_grid(const PackedFloat32Array &p_src, const int p_sw, const int p_sh, const int p_dw, const int p_dh);
	// Take a sim-resolution delta field to a terrain-resolution write grid through the loop's falloff
	// mask (§5 "simulate wide, write narrow"). Cells outside the mask come back NaN so apply_sim_block
	// never touches them — the catchment margin is computed over but never written. Pass the pre-solve
	// surface as params["baseline"] to hand `deltas` the POST-solve surface and difference it here.
	// §17: the per-cell erosion/write mask over a sim grid, from a stack of relief selectors (and,
	// optionally, the erodability texture composed in). Empty when there is nothing to mask with.
	PackedFloat32Array sim_mask_field(const PackedFloat32Array &p_z, const Dictionary &p_params, const PackedFloat32Array &p_selectors, const Dictionary &p_sim_result);
	PackedFloat32Array sim_mask_deltas(const PackedFloat32Array &p_deltas, const PackedVector2Array &p_poly, const Dictionary &p_params, const PackedFloat32Array &p_lut);
	// §8.1 — batched delta write, the same raw-tile path the stamp_* rasterisers use. Deltas are gw*gh
	// row-major with NaN = skip, anchored at vertex round(min_x/vs), round(min_z/vs). Deferred: the
	// caller composites the box and pushes to the GPU once.
	void apply_sim_block(const int p_layer_id, const double p_min_x, const double p_min_z, const double p_vs,
			const int p_gw, const int p_gh, const PackedFloat32Array &p_deltas, const int p_blend);
	// §8.2 — the four Pasture3DSimResult channels. Each entry of `parts` is one solved loop
	// {sw, sh, min_x, min_z, cell, z0, z1, flow, lake, write_min_x/z, write_max_x/z}; `target` is the
	// grid they are merged onto {min_x, min_z, cell_size, width, height}. Returns
	// {ok, flow, erosion, deposition, wetness, parts}. `flow` is log-scaled (exp() it to get m²), and
	// erosion/deposition are the negative and positive halves of one net delta field, never both.
	Dictionary sim_result_build(const Array &p_parts, const Dictionary &p_target);
	// §10 — rivers and lakes off ONE routing pass over an already-eroded surface. `params` carries the
	// grid ({gw, gh, cell_size, min_x, min_z}) and the thresholds ({river_area_threshold,
	// min_river_length, curve_tolerance, lake_depth_threshold, min_lake_area, lake_depth_percentile}).
	// Returns {ok, rivers, lakes, channel_cells, lake_cells}, where each river is
	// {points, areas, length, cells} — one polyline per link between confluences, already
	// Douglas-Peucker simplified — and each lake is {contour, level, depth, area, cells}.
	Dictionary sim_extract_water(const PackedFloat32Array &p_z, const Dictionary &p_params);
	// Per-cell write used by the native rasterisers. When p_composite, defers to the per-pixel composite
	// API (full-refresh path). Otherwise writes the sample directly into p_layer, caching the resolved
	// region in r_loc/r_region so a run of cells in the same region skips the per-cell layer+region
	// lookups (the bottleneck for write-heavy brushes like Trough). r_value is the target (set) or the
	// delta (add). Not bound — internal helper for stamp_*.
	void _stamp_write(class Pasture3DLayer *p_layer, const int p_layer_id, const bool p_composite,
			Vector2i &r_loc, Pasture3DRegion *&r_region, const Vector3 &p_pos, const real_t p_value, const int p_blend);
	// Batched raw-tile apply for the native rasterisers (PASTURE3D_BRUSH_GPU_RASTER_SPEC.md Phase 1b). Writes
	// a box-grid of values (gw*gh, row-major, NaN = skip) into a non-base RGF overlay layer, resolving each
	// tile ONCE (get_data/set_data) and applying the same-layer blend per cell — replacing the per-cell
	// _stamp_write (tile dict-lookup + set_pixelv) that dominated terrain-scale bakes. The box grid is
	// anchored at vertex (p_min_px, p_min_pz) = round(min_x/vs), round(min_z/vs). Caller-provided values
	// already include base height + noise. Deferred-composite path only (orchestration composites the box).
	void _apply_stamp_block(class Pasture3DLayer *p_layer, const int p_min_px, const int p_min_pz,
			const int p_gw, const int p_gh, const float *p_vals, const int p_blend);
	// Splat's Phase 1d analogue: batched control apply. Writes packed uint32 control words (where
	// p_mask != 0) into the TYPE_CONTROL overlay's RGF tiles (R = control bits as float, G = weight 1),
	// resolving each tile once. Control is REPLACE (no numeric blend); the skip mask is separate from the
	// data because any uint32 bit pattern is a valid R value (so NaN can't double as a sentinel).
	void _apply_control_block(class Pasture3DLayer *p_layer, const int p_min_px, const int p_min_pz,
			const int p_gw, const int p_gh, const uint32_t *p_ctrl, const uint8_t *p_mask);
	// Garbage-collect a layer's fully-uncovered tiles (frees memory after erasing/moving a feature).
	void gc_layer(const int p_layer_id);
	void set_active_layer(const int p_layer_id);
	int get_active_layer() const { return _layer_stack.is_valid() ? _layer_stack->get_active_layer() : -1; }

	// File I/O
	void save_directory(const String &p_dir);
	void save_region(const Vector2i &p_region_loc, const String &p_dir, const bool p_16_bit = false);
	void load_directory(const String &p_dir);
	void load_region(const Vector2i &p_region_loc, const String &p_dir, const bool p_update = true);

	// Editor-only layer persistence (PASTURE3D_LAYERS_GUIDE.md §7). Save/load the layer stack as
	// pasture3d_layers*.res alongside the runtime region files, which are never touched. Called by
	// save_directory/load_directory; exposed so tools and tests can drive them directly.
	void save_layers(const String &p_dir);
	bool load_layers(const String &p_dir); // Returns true if a manifest was found and loaded.

	// Maps
	TypedArray<Image> get_height_maps() const { return _height_maps; }
	TypedArray<Image> get_control_maps() const { return _control_maps; }
	TypedArray<Image> get_color_maps() const { return _color_maps; }
	TypedArray<Image> get_maps(const MapType p_map_type) const;
	void update_maps(const MapType p_map_type = TYPE_MAX, const bool p_all_regions = true, const bool p_generate_mipmaps = false);
	RID get_height_maps_rid() const { return _generated_height_maps.get_rid(); }
	RID get_control_maps_rid() const { return _generated_control_maps.get_rid(); }
	RID get_color_maps_rid() const { return _generated_color_maps.get_rid(); }

	void set_pixel(const MapType p_map_type, const Vector3 &p_global_position, const Color &p_pixel);
	Color get_pixel(const MapType p_map_type, const Vector3 &p_global_position) const;
	void set_height(const Vector3 &p_global_position, const real_t p_height);
	real_t get_height(const Vector3 &p_global_position) const;
	void set_color(const Vector3 &p_global_position, const Color &p_color);
	Color get_color(const Vector3 &p_global_position) const;
	void set_control(const Vector3 &p_global_position, const uint32_t p_control);
	uint32_t get_control(const Vector3 &p_global_position) const;
	void set_roughness(const Vector3 &p_global_position, const real_t p_roughness);
	real_t get_roughness(const Vector3 &p_global_position) const;

	// Control Map
	void set_control_base_id(const Vector3 &p_global_position, const uint8_t p_base);
	uint32_t get_control_base_id(const Vector3 &p_global_position) const;
	void set_control_overlay_id(const Vector3 &p_global_position, const uint8_t p_overlay);
	uint32_t get_control_overlay_id(const Vector3 &p_global_position) const;
	void set_control_blend(const Vector3 &p_global_position, const real_t p_blend);
	real_t get_control_blend(const Vector3 &p_global_position) const;
	void set_control_angle(const Vector3 &p_global_position, const real_t p_angle);
	real_t get_control_angle(const Vector3 &p_global_position) const;
	void set_control_scale(const Vector3 &p_global_position, const real_t p_scale);
	real_t get_control_scale(const Vector3 &p_global_position) const;
	void set_control_hole(const Vector3 &p_global_position, const bool p_hole);
	bool get_control_hole(const Vector3 &p_global_position) const;
	void set_control_navigation(const Vector3 &p_global_position, const bool p_navigation);
	bool get_control_navigation(const Vector3 &p_global_position) const;
	void set_control_auto(const Vector3 &p_global_position, const bool p_auto);
	bool get_control_auto(const Vector3 &p_global_position) const;

	Vector3 get_normal(const Vector3 &p_global_position) const;
	bool is_in_slope(const Vector3 &p_global_position, const Vector2 &p_slope_range, const Vector3 &p_normal = V3_ZERO) const;
	Vector3 get_texture_id(const Vector3 &p_global_position) const;
	Vector3 get_mesh_vertex(const int32_t p_lod, const HeightFilter p_filter, const Vector3 &p_global_position) const;

	void add_edited_area(const AABB &p_area);
	void clear_edited_area() { _edited_area = AABB(); }
	AABB get_edited_area() const { return _edited_area; }

	Vector2 get_height_range() const { return _master_height_range; }
	void update_master_height(const real_t p_height);
	void update_master_heights(const Vector2 &p_low_high);
	void calc_height_range(const bool p_recursive = false);

	void import_images(const TypedArray<Image> &p_images, const Vector3 &p_global_position = V3_ZERO,
			const real_t p_offset = 0.f, const real_t p_scale = 1.f);
	Error export_image(const String &p_file_name, const MapType p_map_type = TYPE_HEIGHT, const ExportMode p_mode = EXPORT_SLICED) const;
	Ref<Image> layered_to_image(const MapType p_map_type, const Rect2i &p_bounds = Rect2i()) const;

	// Utility
	void dump(const bool verbose = false) const;

protected:
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Pasture3DData::HeightFilter);
VARIANT_ENUM_CAST(Pasture3DData::ExportMode);

// Inline Region Functions

// Verifies the location is within the bounds of the _region_map array and
// the world, returning the _region_map index, which contains the region_id.
// Valid region locations are -16, -16 to 15, 15, or when offset: 0, 0 to 31, 31
// If any bits other than 0x1F are set, it's out of bounds and returns -1
inline int Pasture3DData::get_region_map_index(const Vector2i &p_region_loc) {
	// Offset world to positive values only
	Vector2i loc = p_region_loc + (REGION_MAP_VSIZE / 2);
	// Catch values > 31
	if ((uint32_t(loc.x | loc.y) & uint32_t(~0x1F)) > 0) {
		return -1;
	}
	return loc.y * REGION_MAP_SIZE + loc.x;
}

// Returns a region location given a global position. No bounds checking nor data access.
inline Vector2i Pasture3DData::get_region_location(const Vector3 &p_global_position) const {
	Vector2 descaled_position = v3v2(p_global_position) / _vertex_spacing;
	return Vector2i((descaled_position / real_t(_region_size)).floor());
}

// Returns id of any active region. -1 if out of bounds or no region, or region id
inline int Pasture3DData::get_region_id(const Vector2i &p_region_loc) const {
	int map_index = get_region_map_index(p_region_loc);
	if (map_index >= 0) {
		int region_id = _region_map[map_index] - 1; // 0 = no region
		if (region_id >= 0 && region_id < _region_locations.size()) {
			return region_id;
		}
	}
	return -1;
}

inline int Pasture3DData::get_region_idp(const Vector3 &p_global_position) const {
	return get_region_id(get_region_location(p_global_position));
}

// This function is slower than the version below, but safer when interacting with Godot, which requires
// References. This includes backing up regions in the UndoRedoManager.
// Ref<> has a pointer constructor, so a reference can be created with Ref<>(ptr). Godot detects the
// pointer is already tracked and increments the reference counter.
// Passing the pointer to a function with a Ref<> parameter works, and there's an implicit conversion to Ref.
// However, let's require explicit conversions for clarity, so wrap a Ref around it:
// eg. backup_region(Ref<Pasture3D>(raw_ptr));
// Should be used for most functions in Editor and Instancer.
inline Ref<Pasture3DRegion> Pasture3DData::get_region(const Vector2i &p_region_loc) const {
	return _regions.get(p_region_loc, Ref<Pasture3DRegion>());
}

// Using the raw pointer is faster than creating a Ref<>. It can also safely be converted to a Ref as needed
// with Ref<>(ptr). Use this function when retreiving regions frequently, eg looping over get_pixel().
// Should be used for most data processing in Data, but not region handling.
// Re overloaded template
// get_region_ptr(region_locs[i]) worked with an implicit conversion of Variant::Vector2i to Vector2i.
// However it also worked for Variant::Object, which silently sent invalid data.
// The overloaded template was added to catch this. Pulling out of a dictionary/array gives a Variant,
// so now explicit conversion is required, eg. get_region_ptr(Vector2i(locs[i])).
inline Pasture3DRegion *Pasture3DData::get_region_ptr(const Vector2i &p_region_loc) const {
	if (_regions.has(p_region_loc)) {
		return cast_to<Pasture3DRegion>(_regions[p_region_loc]);
	}
	return nullptr;
}

inline Ref<Pasture3DRegion> Pasture3DData::get_regionp(const Vector3 &p_global_position) const {
	return _regions.get(get_region_location(p_global_position), Ref<Pasture3DRegion>());
}

// Inline Map Functions

inline void Pasture3DData::set_height(const Vector3 &p_global_position, const real_t p_height) {
	set_pixel(TYPE_HEIGHT, p_global_position, Color(p_height, 0.f, 0.f, 1.f));
}

inline void Pasture3DData::set_color(const Vector3 &p_global_position, const Color &p_color) {
	Color clr = p_color;
	clr.a = get_roughness(p_global_position);
	set_pixel(TYPE_COLOR, p_global_position, clr);
}

inline Color Pasture3DData::get_color(const Vector3 &p_global_position) const {
	Color clr = get_pixel(TYPE_COLOR, p_global_position);
	clr.a = 1.0f;
	return clr;
}

inline void Pasture3DData::set_control(const Vector3 &p_global_position, const uint32_t p_control) {
	set_pixel(TYPE_CONTROL, p_global_position, Color(as_float(p_control), 0.f, 0.f, 1.f));
}

inline uint32_t Pasture3DData::get_control(const Vector3 &p_global_position) const {
	real_t val = get_pixel(TYPE_CONTROL, p_global_position).r;
	return (std::isnan(val)) ? UINT32_MAX : as_uint(val);
}

inline void Pasture3DData::set_control_base_id(const Vector3 &p_global_position, const uint8_t p_base) {
	uint32_t control = get_control(p_global_position);
	uint8_t base = CLAMP(p_base, uint8_t(0), uint8_t(31));
	set_control(p_global_position, (control & ~(0x1F << 27)) | enc_base(base));
}

inline uint32_t Pasture3DData::get_control_base_id(const Vector3 &p_global_position) const {
	uint32_t control = get_control(p_global_position);
	return control == UINT32_MAX ? UINT32_MAX : get_base(control);
}

inline void Pasture3DData::set_control_overlay_id(const Vector3 &p_global_position, const uint8_t p_overlay) {
	uint32_t control = get_control(p_global_position);
	uint8_t overlay = CLAMP(p_overlay, uint8_t(0), uint8_t(31));
	set_control(p_global_position, (control & ~(0x1F << 22)) | enc_overlay(overlay));
}

inline uint32_t Pasture3DData::get_control_overlay_id(const Vector3 &p_global_position) const {
	uint32_t control = get_control(p_global_position);
	return control == UINT32_MAX ? UINT32_MAX : get_overlay(control);
}

// Expects 0.0 to 1.0 range
inline void Pasture3DData::set_control_blend(const Vector3 &p_global_position, const real_t p_blend) {
	uint32_t control = get_control(p_global_position);
	uint8_t blend = uint8_t(CLAMP(Math::round(p_blend * 255.f), 0.f, 255.f));
	set_control(p_global_position, (control & ~(0xFF << 14)) | enc_blend(blend));
}

inline real_t Pasture3DData::get_control_blend(const Vector3 &p_global_position) const {
	uint32_t control = get_control(p_global_position);
	return control == UINT32_MAX ? NAN : real_t(get_blend(control)) / 255.f;
}

// Expects angle in degrees
inline void Pasture3DData::set_control_angle(const Vector3 &p_global_position, const real_t p_angle) {
	uint32_t control = get_control(p_global_position);
	uint8_t uvrotation = uint8_t(CLAMP(Math::round(p_angle / 22.5f), 0.f, 15.f));
	set_control(p_global_position, (control & ~(0xF << 10)) | enc_uv_rotation(uvrotation));
}

// returns angle in degrees
inline real_t Pasture3DData::get_control_angle(const Vector3 &p_global_position) const {
	uint32_t control = get_control(p_global_position);
	real_t angle = real_t(get_uv_rotation(control)) * 22.5f;
	return control == UINT32_MAX ? NAN : angle;
}

// Expects scale as a percentage modifier
inline void Pasture3DData::set_control_scale(const Vector3 &p_global_position, const real_t p_scale) {
	uint32_t control = get_control(p_global_position);
	std::array<uint32_t, 8> scale_align = { 5, 6, 7, 0, 1, 2, 3, 4 };
	uint8_t uvscale = scale_align[uint8_t(CLAMP(Math::round((p_scale + 60.f) / 20.f), 0.f, 7.f))];
	set_control(p_global_position, (control & ~(0x7 << 7)) | enc_uv_scale(uvscale));
}

inline real_t Pasture3DData::get_control_scale(const Vector3 &p_global_position) const {
	uint32_t control = get_control(p_global_position);
	std::array<real_t, 8> scale_values = { 0.0f, 20.0f, 40.0f, 60.0f, 80.0f, -60.0f, -40.0f, -20.0f };
	real_t scale = scale_values[get_uv_scale(control)]; //select from array UI return values
	return control == UINT32_MAX ? NAN : scale;
}

inline void Pasture3DData::set_control_hole(const Vector3 &p_global_position, const bool p_hole) {
	uint32_t control = get_control(p_global_position);
	set_control(p_global_position, (control & ~(0x1 << 2)) | enc_hole(p_hole));
}

inline bool Pasture3DData::get_control_hole(const Vector3 &p_global_position) const {
	uint32_t control = get_control(p_global_position);
	return control == UINT32_MAX ? false : is_hole(control);
}

inline void Pasture3DData::set_control_navigation(const Vector3 &p_global_position, const bool p_navigation) {
	uint32_t control = get_control(p_global_position);
	set_control(p_global_position, (control & ~(0x1 << 1)) | enc_nav(p_navigation));
}

inline bool Pasture3DData::get_control_navigation(const Vector3 &p_global_position) const {
	uint32_t control = get_control(p_global_position);
	return control == UINT32_MAX ? false : is_nav(control);
}

inline void Pasture3DData::set_control_auto(const Vector3 &p_global_position, const bool p_auto) {
	uint32_t control = get_control(p_global_position);
	set_control(p_global_position, (control & ~(0x1)) | enc_auto(p_auto));
}

inline bool Pasture3DData::get_control_auto(const Vector3 &p_global_position) const {
	uint32_t control = get_control(p_global_position);
	return control == UINT32_MAX ? false : is_auto(control);
}

inline void Pasture3DData::set_roughness(const Vector3 &p_global_position, const real_t p_roughness) {
	Color clr = get_pixel(TYPE_COLOR, p_global_position);
	clr.a = p_roughness;
	set_pixel(TYPE_COLOR, p_global_position, clr);
}

inline real_t Pasture3DData::get_roughness(const Vector3 &p_global_position) const {
	return get_pixel(TYPE_COLOR, p_global_position).a;
}

inline void Pasture3DData::update_master_height(const real_t p_height) {
	if (p_height < _master_height_range.x) {
		_master_height_range.x = p_height;
	} else if (p_height > _master_height_range.y) {
		_master_height_range.y = p_height;
	}
}

inline void Pasture3DData::update_master_heights(const Vector2 &p_low_high) {
	if (p_low_high.x < _master_height_range.x) {
		_master_height_range.x = p_low_high.x;
	}
	if (p_low_high.y > _master_height_range.y) {
		_master_height_range.y = p_low_high.y;
	}
}

#endif // PASTURE3D_DATA_CLASS_H
