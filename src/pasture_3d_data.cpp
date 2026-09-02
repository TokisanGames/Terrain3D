// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/editor_file_system.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/resource_saver.hpp>

#include <vector>

#include <godot_cpp/classes/project_settings.hpp>

#include "logger.h"
#include "pasture_3d_data.h"
#include "pasture_3d_gpu_raster.h"

///////////////////////////
// Private Functions
///////////////////////////

void Pasture3DData::_clear() {
	LOG(INFO, "Clearing data");
	_region_map_dirty = true;
	_region_map.clear();
	_region_map.resize(REGION_MAP_SIZE * REGION_MAP_SIZE);
	_regions.clear();
	_region_locations.clear();
	_master_height_range = V2_ZERO;
	_generated_height_maps.clear();
	_generated_control_maps.clear();
	_generated_color_maps.clear();
	_layer_stack.unref();
	if (_gpu_raster) {
		memdelete(_gpu_raster);
		_gpu_raster = nullptr;
	}
}

// --- GPU rasteriser plumbing (PASTURE3D_BRUSH_GPU_RASTER_SPEC.md) ---

int Pasture3DData::_gpu_raster_threshold() const {
	// Default ~256x256 cells; below it the C++ path wins (no readback latency). 0 disables GPU.
	ProjectSettings *ps = ProjectSettings::get_singleton();
	const int dflt = 65536; // ~256^2; crossover where GPU beats CPU rasterization
	if (!ps) {
		return dflt;
	}
	return (int)ps->get_setting("pasture_3d/performance/gpu_raster_threshold", dflt);
}

Pasture3DGPURaster *Pasture3DData::_ensure_gpu_raster() {
	if (_gpu_raster_threshold() == 0) {
		return nullptr; // GPU globally disabled.
	}
	if (!_gpu_raster) {
		_gpu_raster = memnew(Pasture3DGPURaster);
	}
	return _gpu_raster;
}

bool Pasture3DData::gpu_raster_available() {
	Pasture3DGPURaster *gpu = _ensure_gpu_raster();
	return gpu && gpu->available();
}

// Builds a one-layer stack whose dense "Base" layer aliases the loaded region height maps, so an
// existing terrain opens as a single-layer stack with no pixel copy. Called when no layer files are
// present (phase 1 has no layer persistence yet, so this always runs after load). The stack is not
// yet read by the runtime/compositor, so this introduces no behaviour change.
void Pasture3DData::_synthesize_base_layer() {
	if (_region_size <= 0) {
		LOG(DEBUG, "No region size yet; skipping base layer synthesis");
		return;
	}
	_layer_stack.instantiate();
	Ref<Pasture3DLayer> base;
	base.instantiate();
	base->set_layer_name("Base");
	base->set_map_type(TYPE_HEIGHT);
	base->set_tile_size(_region_size); // Phase 1: one tile per region == the region image
	base->set_blend_mode(Pasture3DLayer::REPLACE);
	base->set_base(true);
	Array locations = _regions.keys();
	for (const Vector2i &region_loc : locations) {
		Pasture3DRegion *region = get_region_ptr(region_loc);
		if (region && region->get_height_map().is_valid()) {
			base->set_region_image(region_loc, region->get_height_map());
		}
	}
	base->set_modified(false);
	_layer_stack->add_layer_ref(base);
	LOG(INFO, "Synthesized Base layer over ", locations.size(), " region(s)");
}

// The Base aliases the region maps when at least one of its tiles is the very same Ref<Image> as the
// region's height map. After un-aliasing none are, so this returns false and routing/live compositing
// is safe (PASTURE3D_LAYERS_GUIDE.md §5.1).
bool Pasture3DData::_is_base_aliased() const {
	if (_layer_stack.is_null()) {
		return false;
	}
	Pasture3DLayer *base = _layer_stack->get_layer_ptr(0);
	if (!base) {
		return false;
	}
	TypedArray<Vector2i> locations = base->get_region_locations();
	for (const Vector2i &loc : locations) {
		Pasture3DRegion *region = get_region_ptr(loc);
		Ref<Image> tile = base->get_tile(loc, V2I_ZERO);
		if (region && tile.is_valid() && tile == region->get_height_map()) {
			return true;
		}
	}
	return false;
}

void Pasture3DData::_unalias_base_layer() {
	if (_layer_stack.is_null()) {
		return;
	}
	Pasture3DLayer *base = _layer_stack->get_layer_ptr(0);
	if (!base) {
		return;
	}
	bool changed = false;
	TypedArray<Vector2i> locations = base->get_region_locations();
	for (const Vector2i &loc : locations) {
		Pasture3DRegion *region = get_region_ptr(loc);
		Ref<Image> tile = base->get_tile(loc, V2I_ZERO);
		if (region && tile.is_valid() && tile == region->get_height_map()) {
			// Deep copy so the Base source and the composite target are distinct buffers.
			Ref<Image> owned = Image::create_from_data(tile->get_width(), tile->get_height(), tile->has_mipmaps(), tile->get_format(), tile->get_data());
			base->set_region_image(loc, owned);
			changed = true;
		}
	}
	if (changed) {
		LOG(INFO, "Un-aliased Base layer; it now owns its source buffer");
	}
}

bool Pasture3DData::ensure_layer_stack() {
	if (_layer_stack.is_null()) {
		_synthesize_base_layer(); // Builds an empty Base when no regions exist yet; that's fine.
	}
	return _layer_stack.is_valid();
}

int Pasture3DData::layer_add(const String &p_name, const int p_blend_mode) {
	if (_layer_stack.is_null()) {
		_synthesize_base_layer(); // No stack yet (e.g. plain terrain not yet opened through a stack).
		if (_layer_stack.is_null()) {
			LOG(ERROR, "Cannot add a layer: no region data to anchor a Base layer");
			return -1;
		}
	}
	int idx = _layer_stack->add_layer(p_name, Pasture3DLayer::BlendMode(p_blend_mode));
	if (idx > 0) {
		// First non-Base layer: the Base must own its buffer so live re-compositing is correct.
		_unalias_base_layer();
	}
	if (idx >= 0) {
		emit_signal("layers_changed");
	}
	return idx;
}

int Pasture3DData::layer_duplicate(const int p_idx) {
	if (_layer_stack.is_null()) {
		return -1;
	}
	Pasture3DLayer *src = _layer_stack->get_layer_ptr(p_idx);
	if (!src) {
		LOG(ERROR, "Cannot duplicate layer ", p_idx, ": out of range");
		return -1;
	}
	Ref<Pasture3DLayer> copy = src->clone();
	copy->set_layer_name(src->get_layer_name() + " copy");
	copy->set_owner_id(String()); // A duplicate is hand-editable, never a tool-reserved layer.
	copy->set_reserved(false);
	int idx = _layer_stack->add_layer_ref(copy);
	_unalias_base_layer();
	recomposite_layer(idx);
	if (idx >= 0) {
		emit_signal("layers_changed");
	}
	return idx;
}

void Pasture3DData::layer_remove(const int p_idx) {
	if (_layer_stack.is_null() || p_idx == 0) {
		return; // The Base layer is protected.
	}
	Pasture3DLayer *layer = _layer_stack->get_layer_ptr(p_idx);
	TypedArray<Vector2i> locs = layer ? layer->get_region_locations() : TypedArray<Vector2i>();
	_layer_stack->remove_layer(p_idx);
	// Recomposite the regions the removed layer used to cover so they fall back to what is below.
	for (const Vector2i &loc : locs) {
		composite_region(loc, Rect2i(), false);
	}
	update_maps(TYPE_MAX, false, false); // The removed layer may be control/color, not just height.
	emit_signal("layers_changed");
}

void Pasture3DData::layer_move(const int p_from, const int p_to) {
	if (_layer_stack.is_null()) {
		return;
	}
	Pasture3DLayer *layer = _layer_stack->get_layer_ptr(p_from);
	TypedArray<Vector2i> locs = layer ? layer->get_region_locations() : TypedArray<Vector2i>();
	_layer_stack->move_layer(p_from, p_to);
	for (const Vector2i &loc : locs) {
		composite_region(loc, Rect2i(), false);
	}
	update_maps(TYPE_MAX, false, false);
	emit_signal("layers_changed");
}

void Pasture3DData::recomposite_layer(const int p_idx) {
	if (_layer_stack.is_null()) {
		return;
	}
	Pasture3DLayer *layer = _layer_stack->get_layer_ptr(p_idx);
	if (!layer) {
		return;
	}
	TypedArray<Vector2i> locations = layer->get_region_locations();
	for (const Vector2i &loc : locations) {
		composite_region(loc, Rect2i(), false);
	}
	update_maps(TYPE_MAX, false, false);
}

void Pasture3DData::refresh_base_alias() {
	// Only a single-layer (plain-terrain) Base is meant to alias the region maps; a multi-layer Base
	// owns its buffer and must not be disturbed by region swaps.
	if (_layer_stack.is_null() || _layer_stack->get_layer_count() != 1) {
		return;
	}
	Pasture3DLayer *base = _layer_stack->get_layer_ptr(0);
	if (!base) {
		return;
	}
	for (const Vector2i &loc : _regions.keys()) {
		Pasture3DRegion *region = get_region_ptr(loc);
		if (region && region->get_height_map().is_valid()) {
			base->set_region_image(loc, region->get_height_map());
		}
	}
	base->set_modified(false);
}

// Structured to work with do_for_regions. Should be renamed when copy_paste is expanded
void Pasture3DData::_copy_paste_dfr(const Pasture3DRegion *p_src_region, const Rect2i &p_src_rect, const Rect2i &p_dst_rect, const Pasture3DRegion *p_dst_region) {
	if (!p_src_region || !p_dst_region) {
		return;
	}
	TypedArray<Image> src_maps = p_src_region->get_maps();
	TypedArray<Image> dst_maps = p_dst_region->get_maps();
	for (int i = 0; i < dst_maps.size(); i++) {
		Image *img = cast_to<Image>(dst_maps[i]);
		if (img) {
			img->blit_rect(src_maps[i], p_src_rect, p_dst_rect.position);
		}
	}
	if (_terrain) { // Null on standalone data (unit tests).
		_terrain->get_instancer()->copy_paste_dfr(p_src_region, p_src_rect, p_dst_region);
	}
}

///////////////////////////
// Public Functions
///////////////////////////

void Pasture3DData::initialize(Pasture3D *p_terrain) {
	if (!p_terrain) {
		LOG(ERROR, "Initialization failed, p_terrain is null");
		return;
	}
	LOG(INFO, "Initializing data");
	bool prev_initialized = _terrain != nullptr;
	_terrain = p_terrain;
	_region_map.resize(REGION_MAP_SIZE * REGION_MAP_SIZE);
	_vertex_spacing = _terrain->get_vertex_spacing();
	if (!prev_initialized && !_terrain->get_data_directory().is_empty()) {
		load_directory(_terrain->get_data_directory());
	}
	_region_size = _terrain->get_region_size();
	_region_sizev = V2I(_region_size);

	// Register the GPU-raster threshold setting once so it is discoverable/tunable in Project Settings
	// (spec §5.1). Default ~256x256 cells; 0 disables GPU, 1 forces GPU-always (A/B testing). Idempotent.
	ProjectSettings *ps = ProjectSettings::get_singleton();
	if (ps && !ps->has_setting("pasture_3d/performance/gpu_raster_threshold")) {
		ps->set_setting("pasture_3d/performance/gpu_raster_threshold", 1048576);
		ps->set_initial_value("pasture_3d/performance/gpu_raster_threshold", 1048576);
		Dictionary info;
		info["name"] = "pasture_3d/performance/gpu_raster_threshold";
		info["type"] = Variant::INT;
		info["hint"] = PROPERTY_HINT_RANGE;
		info["hint_string"] = "0,16777216,1";
		ps->add_property_info(info);
	}
}

void Pasture3DData::set_region_locations(const TypedArray<Vector2i> &p_locations) {
	SET_IF_DIFF(_region_locations, p_locations);
	LOG(INFO, "Setting _region_locations with array sized: ", p_locations.size());
	_region_map_dirty = true;
	update_maps(TYPE_MAX, false, false); // only rebuild region map
}

// Returns an array of active regions, optionally a shallow or deep copy
TypedArray<Pasture3DRegion> Pasture3DData::get_regions_active(const bool p_copy, const bool p_deep) const {
	TypedArray<Pasture3DRegion> region_arr;
	for (const Vector2i &region_loc : _region_locations) {
		Ref<Pasture3DRegion> region = get_region(region_loc);
		if (region.is_valid()) {
			region_arr.push_back(p_copy ? region->duplicate(p_deep) : region);
		}
	}
	return region_arr;
}

// Calls the callback function for every region within the given (descaled) area
// The callable receives: source Pasture3DRegion, source Rect2i, dest Rect2i, (bindings)
// Used with change_region_size, dest Pasture3DRegion is bound as the 4th parameter
void Pasture3DData::do_for_regions(const Rect2i &p_area, const Callable &p_callback) {
	Rect2i location_bounds(V2I_DIVIDE_FLOOR(p_area.position, _region_size), V2I_DIVIDE_CEIL(p_area.size, _region_size));
	LOG(DEBUG, "Processing global area: ", p_area, " -> ", location_bounds);
	Point2i current_region_loc;
	for (int y = location_bounds.position.y; y < location_bounds.get_end().y; y++) {
		current_region_loc.y = y;
		for (int x = location_bounds.position.x; x < location_bounds.get_end().x; x++) {
			current_region_loc.x = x;
			const Pasture3DRegion *region = get_region_ptr(current_region_loc);
			if (region && !region->is_deleted()) {
				LOG(DEBUG, "Current region: ", current_region_loc);
				Rect2i region_area = p_area.intersection(Rect2i(current_region_loc * _region_size, _region_sizev));
				LOG(DEBUG, "Region bounds: ", Rect2i(current_region_loc * _region_size, _region_sizev));
				LOG(DEBUG, "Region area: ", region_area);
				Rect2i dst_coords(region_area.position - p_area.position, region_area.size);
				Rect2i src_coords(region_area.position - (region->get_location() * _region_sizev), dst_coords.size);
				LOG(DEBUG, "src map coords: ", src_coords);
				LOG(DEBUG, "dst map coords: ", dst_coords);
				p_callback.call(region, src_coords, dst_coords);
			}
		}
	}
}

void Pasture3DData::change_region_size(int p_new_size) {
	LOG(INFO, "Changing region size from: ", _region_size, " to ", p_new_size);
	if (!is_valid_region_size(p_new_size)) {
		LOG(ERROR, "Invalid region size: ", p_new_size, ". Must be power of 2, 64-2048");
		return;
	}
	if (p_new_size == _region_size) {
		return;
	}
	const int old_size = _region_size;

	// Snapshot each layer's tiles, then empty the layers and pre-size their tile grids for the new
	// region size. Base layers must match the new size exactly, or _adopt_region_into_bases silently
	// skips every re-added region and the stack never covers the terrain again (the "layer system
	// breaks after changing region size" bug). The snapshot (outer + inner dictionaries duplicated,
	// images shared) is re-mapped onto the new grid by _migrate_layers_region_size below.
	TypedArray<Dictionary> old_layer_tiles;
	PackedInt32Array old_layer_tile_sizes;
	if (_layer_stack.is_valid()) {
		for (int i = 0; i < _layer_stack->get_layer_count(); i++) {
			Pasture3DLayer *layer = _layer_stack->get_layer_ptr(i);
			old_layer_tiles.push_back(layer ? layer->get_tiles().duplicate(true) : Dictionary());
			old_layer_tile_sizes.push_back(layer ? layer->get_tile_size() : 0);
			if (layer) {
				layer->set_tiles(Dictionary());
				// Overlays keep their sub-tiling but can never exceed the region size.
				layer->set_tile_size(layer->is_base() ? p_new_size : MIN(layer->get_tile_size(), p_new_size));
			}
		}
	}

	// Get current region corners expressed in new region_size coordinates
	Dictionary new_region_locations;
	Array region_locations = _regions.keys();
	for (const Vector2i &region_loc : region_locations) {
		const Pasture3DRegion *region = get_region_ptr(region_loc);
		if (region && !region->is_deleted()) {
			Vector2i region_position = region->get_location() * _region_size;
			Rect2i location_bounds(V2I_DIVIDE_FLOOR(region_position, p_new_size), V2I_DIVIDE_CEIL(_region_sizev, p_new_size));
			for (int y = location_bounds.position.y; y < location_bounds.get_end().y; y++) {
				for (int x = location_bounds.position.x; x < location_bounds.get_end().x; x++) {
					new_region_locations[Vector2i(x, y)] = 1;
				}
			}
		}
	}

	// Make new regions to receive copied data
	TypedArray<Pasture3DRegion> new_regions;
	Array new_locations = new_region_locations.keys();
	for (const Vector2i &region_loc : new_locations) {
		Ref<Pasture3DRegion> new_region;
		new_region.instantiate();
		new_region->set_location(region_loc);
		new_region->set_region_size(p_new_size);
		new_region->set_vertex_spacing(_vertex_spacing);
		new_region->set_modified(true);
		new_region->sanitize_maps();

		// Copy current data from current into new region, up to new region size
		Rect2i area;
		area.position = region_loc * p_new_size;
		area.size = V2I(p_new_size);
		do_for_regions(area, callable_mp(this, &Pasture3DData::_copy_paste_dfr).bind(new_region.ptr()));
		new_regions.push_back(new_region);
	}

	// Remove old data
	if (_terrain) {
		_terrain->get_instancer()->destroy();
	}
	TypedArray<Pasture3DRegion> old_regions = get_regions_active();
	for (const Ref<Pasture3DRegion> &region : old_regions) {
		remove_region(region, false);
	}

	// Change region size
	if (_terrain) {
		_terrain->set_region_size((Pasture3D::RegionSize)p_new_size); // Also writes our _region_size.
	} else {
		_region_size = p_new_size; // Standalone data (unit tests): no node to route through.
		_region_sizev = V2I(p_new_size);
	}

	// Add new regions and rebuild. Base adoption inside add_region re-seeds every base layer from the
	// new region maps (alias for a single-layer height Base, owned copies otherwise).
	for (const Ref<Pasture3DRegion> &region : new_regions) {
		add_region(region, false);
	}

	// Restore the layer stack's pixel data onto the new grid (see _migrate_layers_region_size).
	_migrate_layers_region_size(old_size, p_new_size, old_layer_tiles, old_layer_tile_sizes);

	calc_height_range(true);
	if (_terrain) {
		update_maps(TYPE_MAX, true, true);
		_terrain->get_instancer()->update_mmis(-1, V2I_MAX, true);
	}
}

void Pasture3DData::set_region_modified(const Vector2i &p_region_loc, const bool p_modified) {
	Pasture3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(ERROR, "Region not found at: ", p_region_loc);
		return;
	}
	return region->set_modified(p_modified);
}

bool Pasture3DData::is_region_modified(const Vector2i &p_region_loc) const {
	Pasture3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(ERROR, "Region not found at: ", p_region_loc);
		return false;
	}
	return region->is_modified();
}

void Pasture3DData::set_region_deleted(const Vector2i &p_region_loc, const bool p_deleted) {
	Pasture3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(ERROR, "Region not found at: ", p_region_loc);
		return;
	}
	return region->set_deleted(p_deleted);
}

bool Pasture3DData::is_region_deleted(const Vector2i &p_region_loc) const {
	const Pasture3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(ERROR, "Region not found at: ", p_region_loc);
		return true;
	}
	return region->is_deleted();
}

Ref<Pasture3DRegion> Pasture3DData::add_region_blankp(const Vector3 &p_global_position, const bool p_update) {
	return add_region_blank(get_region_location(p_global_position));
}

Ref<Pasture3DRegion> Pasture3DData::add_region_blank(const Vector2i &p_region_loc, const bool p_update) {
	Ref<Pasture3DRegion> region;
	region.instantiate();
	region->set_location(p_region_loc);
	region->set_region_size(_region_size);
	region->set_vertex_spacing(_vertex_spacing);
	if (add_region(region, p_update) == OK) {
		region->set_modified(true);
		return region;
	}
	return Ref<Pasture3DRegion>();
}

/** Adds a Pasture3DRegion to the terrain
 * Marks region as modified
 *	p_update - rebuild the maps if true. Set to false if bulk adding many regions.
 */
Error Pasture3DData::add_region(const Ref<Pasture3DRegion> &p_region, const bool p_update) {
	if (p_region.is_null()) {
		LOG(ERROR, "Provided region is null. Returning");
		return FAILED;
	}
	Vector2i region_loc = p_region->get_location();
	LOG(INFO, "Adding region at location ", region_loc, ", update maps: ", p_update ? "yes" : "no");

	// Check bounds and slow report errors
	if (get_region_map_index(region_loc) < 0) {
		LOG(ERROR, "Location ", region_loc, " out of bounds. Max: ",
				-REGION_MAP_SIZE / 2, " to ", REGION_MAP_SIZE / 2 - 1);
		return FAILED;
	}
	p_region->sanitize_maps();
	p_region->set_deleted(false);
	if (!_region_locations.has(region_loc)) {
		_region_locations.push_back(region_loc);
	} else {
		LOG(INFO, "Overwriting ", (_regions.has(region_loc)) ? "deleted" : "existing", " region at ", region_loc);
	}
	_regions[region_loc] = p_region;
	// If a layer stack already exists (editing, not the initial load — the stack is built after the load
	// loop), make every base layer (height + any control/color base) cover this newly added region so
	// compositing/routing include it. A single-layer height Base aliases the region map; others own a copy.
	if (_layer_stack.is_valid()) {
		_adopt_region_into_bases(p_region.ptr());
	}
	_region_map_dirty = true;
	LOG(DEBUG, "Storing region ", region_loc, " version ", vformat("%.3f", p_region->get_version()), " id: ", _region_locations.size());
	if (p_update) {
		update_maps(TYPE_MAX, true, false);
		_terrain->get_instancer()->update_mmis(-1, V2I_MAX, true);
	}
	return OK;
}

void Pasture3DData::remove_regionp(const Vector3 &p_global_position, const bool p_update) {
	Ref<Pasture3DRegion> region = get_region(get_region_location(p_global_position));
	remove_region(region, p_update);
}

void Pasture3DData::remove_regionl(const Vector2i &p_region_loc, const bool p_update) {
	Ref<Pasture3DRegion> region = get_region(p_region_loc);
	remove_region(region, p_update);
}

// Remove region marks the region for deletion, and removes it from the active arrays indexed by ID
// It remains stored in _regions and the file remains on disk until saved, when both are removed
void Pasture3DData::remove_region(const Ref<Pasture3DRegion> &p_region, const bool p_update) {
	if (p_region.is_null()) {
		LOG(ERROR, "Region not found or is null. Returning");
		return;
	}

	Vector2i region_loc = p_region->get_location();
	int region_id = _region_locations.find(region_loc);
	LOG(INFO, "Marking region ", region_loc, " for deletion. update_maps: ", p_update ? "yes" : "no");
	if (region_id < 0) {
		LOG(ERROR, "Region ", region_loc, " not found in region_locations. Returning");
		return;
	}
	p_region->set_deleted(true);
	_region_locations.remove_at(region_id);
	_region_map_dirty = true;
	LOG(DEBUG, "Removing from region_locations, new size: ", _region_locations.size());
	if (p_update) {
		LOG(DEBUG, "Updating generated maps");
		update_maps(TYPE_MAX, true, false);
		_terrain->get_instancer()->update_mmis(-1, V2I_MAX, true);
	}
}

void Pasture3DData::save_directory(const String &p_dir) {
	LOG(INFO, "Saving data files to ", p_dir);
	Array locations = _regions.keys();
	for (const Vector2i &region_loc : locations) {
		save_region(region_loc, p_dir, _terrain->get_save_16_bit());
	}
	// Persist the editor-side layer stack as pasture3d_layers*.res. The runtime region files written
	// above are the authoritative composited data and are not touched by this (see §7.2).
	save_layers(p_dir);
	if (IS_EDITOR && !EditorInterface::get_singleton()->get_resource_filesystem()->is_scanning()) {
		EditorInterface::get_singleton()->get_resource_filesystem()->scan();
	}
}

// You may need to do a file system scan to update FileSystem panel
void Pasture3DData::save_region(const Vector2i &p_region_loc, const String &p_dir, const bool p_16_bit) {
	Ref<Pasture3DRegion> region = get_region(p_region_loc);
	if (region.is_null()) {
		LOG(ERROR, "No region found at: ", p_region_loc);
		return;
	}
	String fname = Util::location_to_filename(p_region_loc);
	String path = p_dir + String("/") + fname;
	// If region marked for deletion, remove from disk and from _regions, but don't free in case stored in undo
	if (region->is_deleted()) {
		LOG(DEBUG, "Removing ", p_region_loc, " from _regions");
		_regions.erase(p_region_loc);
		LOG(DEBUG, "File to be deleted: ", path);
		if (!FileAccess::file_exists(path)) {
			LOG(INFO, "File to delete ", path, " doesn't exist. (Maybe from add, undo, save)");
			return;
		}
		Ref<DirAccess> da = DirAccess::open(p_dir);
		if (da.is_null()) {
			LOG(ERROR, "Cannot open directory for writing: ", p_dir, " error: ", DirAccess::get_open_error());
			return;
		}
		Error err = da->remove(fname);
		if (err != OK) {
			LOG(ERROR, "Could not remove file: ", fname, ", error code: ", err);
		}
		LOG(INFO, "File ", path, " deleted");
		return;
	}
	Error err = region->save(path, p_16_bit);
	if (!(err == OK || err == ERR_SKIP)) {
		LOG(ERROR, "Could not save file: ", path, ", error: ", UtilityFunctions::error_string(err), " (", err, ")");
	}
	// After a successful save under the new name, remove any legacy terrain3d_<loc>.res for this
	// location so a migrated region isn't loaded twice on the next open.
	if (err == OK) {
		String legacy_fname = fname.replace("pasture3d", "terrain3d");
		if (legacy_fname != fname) {
			Ref<DirAccess> da = DirAccess::open(p_dir);
			if (da.is_valid() && da->file_exists(legacy_fname)) {
				da->remove(legacy_fname);
				LOG(INFO, "Removed legacy region file ", legacy_fname);
			}
		}
	}
}

// Persists the editor-side layer stack alongside the runtime region files WITHOUT touching the
// pasture3d_<loc>.res data (PASTURE3D_LAYERS_GUIDE.md §7). Writes a metadata-only manifest
// (pasture3d_layers.res) plus one per-region pixel slice (pasture3d_layers_<loc>.res) holding the
// sparse tiles of the non-Base layers that fall in each region. The Base layer's pixels ARE the
// region height maps, so they are never serialized here — only re-aliased on load (see §5.1's
// aliasing caveat). A stack with just the Base layer (a plain terrain) writes nothing and removes
// any stale layer files so the feature adds zero footprint when unused.
void Pasture3DData::save_layers(const String &p_dir) {
	Ref<DirAccess> da = DirAccess::open(p_dir);
	if (da.is_null()) {
		LOG(ERROR, "Cannot open directory for writing layers: ", p_dir, " error: ", DirAccess::get_open_error());
		return;
	}

	// No stack, or only the Base layer => nothing worth persisting. Remove any stale files so a
	// terrain that lost its extra layers doesn't reload them on the next open.
	if (_layer_stack.is_null() || _layer_stack->get_layer_count() <= 1) {
		if (da->file_exists(Util::LAYER_MANIFEST_FILENAME)) {
			da->remove(Util::LAYER_MANIFEST_FILENAME);
		}
		for (const Vector2i &region_loc : _regions.keys()) {
			String slice_fname = Util::location_to_layer_filename(region_loc);
			if (da->file_exists(slice_fname)) {
				da->remove(slice_fname);
			}
		}
		return;
	}

	const int layer_count = _layer_stack->get_layer_count();

	// Manifest: a metadata-only copy of the stack. Each layer is cloned with its tiles dropped so the
	// file stays small and never carries the aliased Base pixels.
	Ref<Pasture3DLayerStack> manifest;
	manifest.instantiate();
	manifest->set_version(_layer_stack->get_version());
	TypedArray<Pasture3DLayer> meta_layers;
	for (int i = 0; i < layer_count; i++) {
		Pasture3DLayer *layer = _layer_stack->get_layer_ptr(i);
		Ref<Pasture3DLayer> meta;
		meta.instantiate();
		if (layer) {
			Dictionary d = layer->get_data();
			d.erase("tiles"); // Metadata only.
			meta->set_data(d);
		}
		meta_layers.push_back(meta);
	}
	manifest->set_layers(meta_layers);
	const String manifest_path = p_dir + String("/") + Util::LAYER_MANIFEST_FILENAME;
	Error err = ResourceSaver::get_singleton()->save(manifest, manifest_path, ResourceSaver::FLAG_COMPRESS);
	if (err != OK) {
		LOG(ERROR, "Could not save layer manifest: ", manifest_path, ", error: ", err);
		return;
	}
	manifest->take_over_path(manifest_path);

	// While the Base still aliases the region maps its pixels ARE the runtime data, so they are never
	// serialized (re-aliased on load). Once un-aliased (the moment a real layer exists) the Base owns
	// true base heights that the flattened region map no longer holds, so those must be persisted too
	// — otherwise live re-compositing after load would read the flattened map as the base (§5.1).
	const bool base_aliased = _is_base_aliased();

	// Per-region slices: for each region, an index-aligned stack whose layer i carries only that
	// region's tiles for stack layer i. Regions with no tiles to save are skipped, and any stale slice
	// file removed, to keep the layout sparse.
	for (const Vector2i &region_loc : _regions.keys()) {
		const String slice_fname = Util::location_to_layer_filename(region_loc);
		const String slice_path = p_dir + String("/") + slice_fname;
		bool has_pixels = false;
		Ref<Pasture3DLayerStack> slice;
		slice.instantiate();
		slice->set_version(_layer_stack->get_version());
		TypedArray<Pasture3DLayer> slice_layers;
		for (int i = 0; i < layer_count; i++) {
			Ref<Pasture3DLayer> slice_layer;
			slice_layer.instantiate();
			if (i > 0 || !base_aliased) { // Serialize upper layers always; Base only once un-aliased.
				Pasture3DLayer *layer = _layer_stack->get_layer_ptr(i);
				if (layer && layer->has_region(region_loc)) {
					Dictionary tiles;
					tiles[region_loc] = layer->get_tiles()[region_loc];
					slice_layer->set_tiles(tiles);
					has_pixels = true;
				}
			}
			slice_layers.push_back(slice_layer);
		}
		if (!has_pixels) {
			if (da->file_exists(slice_fname)) {
				da->remove(slice_fname);
			}
			continue;
		}
		slice->set_layers(slice_layers);
		Error serr = ResourceSaver::get_singleton()->save(slice, slice_path, ResourceSaver::FLAG_COMPRESS);
		if (serr != OK) {
			LOG(ERROR, "Could not save layer slice: ", slice_path, ", error: ", serr);
		} else {
			slice->take_over_path(slice_path);
		}
	}
	LOG(INFO, "Saved layer stack (", layer_count, " layers) to ", p_dir);
}

// Loads a previously saved layer stack (manifest + per-region slices) into _layer_stack and re-aliases
// the Base layer onto the freshly loaded region height maps (PASTURE3D_LAYERS_GUIDE.md §7.3). The
// region images are already the composited runtime data, so this does NOT re-composite: under the
// current Base-aliasing scheme a second pass would double-apply ADD/MAX/MIN deltas (see §5.1).
// Returns true if a manifest was found and loaded; false (no-op) otherwise so the caller can fall
// back to _synthesize_base_layer for plain terrains.
bool Pasture3DData::load_layers(const String &p_dir) {
	const String manifest_path = p_dir + String("/") + Util::LAYER_MANIFEST_FILENAME;
	if (!FileAccess::file_exists(manifest_path)) {
		return false;
	}
	Ref<Pasture3DLayerStack> manifest = ResourceLoader::get_singleton()->load(manifest_path, "Pasture3DLayerStack", ResourceLoader::CACHE_MODE_IGNORE);
	if (manifest.is_null()) {
		LOG(ERROR, "Cannot load layer manifest at ", manifest_path);
		return false;
	}
	const int layer_count = manifest->get_layer_count();
	if (layer_count <= 0) {
		LOG(ERROR, "Layer manifest ", manifest_path, " has no layers; falling back to Base synthesis");
		return false;
	}

	// Merge each region's saved pixel slice back into the matching (index-aligned) layers.
	for (const Vector2i &region_loc : _regions.keys()) {
		const String slice_path = p_dir + String("/") + Util::location_to_layer_filename(region_loc);
		if (!FileAccess::file_exists(slice_path)) {
			continue;
		}
		Ref<Pasture3DLayerStack> slice = ResourceLoader::get_singleton()->load(slice_path, "Pasture3DLayerStack", ResourceLoader::CACHE_MODE_IGNORE);
		if (slice.is_null()) {
			LOG(ERROR, "Cannot load layer slice at ", slice_path);
			continue;
		}
		const int slice_count = MIN(slice->get_layer_count(), layer_count);
		// i==0 (Base) carries pixels only when it was un-aliased at save time; if absent it is re-aliased below.
		for (int i = 0; i < slice_count; i++) {
			Pasture3DLayer *slice_layer = slice->get_layer_ptr(i);
			Pasture3DLayer *layer = manifest->get_layer_ptr(i);
			if (!slice_layer || !layer) {
				continue;
			}
			Dictionary slice_tiles = slice_layer->get_tiles();
			if (slice_tiles.has(region_loc)) {
				Dictionary tiles = layer->get_tiles();
				tiles[region_loc] = slice_tiles[region_loc];
				layer->set_tiles(tiles);
			}
		}
	}

	// Re-alias the Base layer (index 0) onto the loaded region maps ONLY for regions whose own base
	// pixels were not persisted (plain/legacy terrains). Regions that loaded their own un-aliased base
	// heights keep them — the flattened region map is the runtime data, the base buffer is the source.
	Pasture3DLayer *base = manifest->get_layer_ptr(0);
	if (base) {
		base->set_base(true); // Normalize pre-Phase-7 manifests whose Base predates the is_base flag.
		for (const Vector2i &region_loc : _regions.keys()) {
			if (base->has_region(region_loc)) {
				continue; // Loaded its own (un-aliased) base heights.
			}
			Pasture3DRegion *region = get_region_ptr(region_loc);
			if (region && region->get_height_map().is_valid()) {
				base->set_region_image(region_loc, region->get_height_map());
			}
		}
		base->set_modified(false);
	}
	_layer_stack = manifest;
	LOG(INFO, "Loaded layer stack (", layer_count, " layers) from ", p_dir);
	return true;
}

void Pasture3DData::load_directory(const String &p_dir) {
	if (p_dir.is_empty()) {
		LOG(ERROR, "Specified directory name is blank");
		return;
	}

	LOG(INFO, "Loading region files from ", p_dir);
	PackedStringArray files = Util::get_files(p_dir, "pasture3d*.res");
	// Also load legacy Terrain3D region files so pre-rebrand maps still open. They are migrated to
	// Pasture3DRegion in memory and rewritten as pasture3d_*.res on the next save (old file removed).
	files.append_array(Util::get_files(p_dir, "terrain3d*.res"));
	if (files.size() == 0) {
		LOG(INFO, "No Pasture3D region files found in: ", p_dir);
		return;
	}

	_clear();
	for (const String &fname : files) {
		// Skip layer manifest/slice files (pasture3d_layers*.res); they are handled by load_layers,
		// not parsed as regions. The "pasture3d*.res" glob above otherwise sweeps them up.
		if (fname.begins_with(Util::LAYER_FILE_PREFIX)) {
			continue;
		}
		String path = p_dir + String("/") + fname;
		LOG(DEBUG, "Loading region from ", path);
		Vector2i loc = Util::filename_to_location(fname);
		if (loc.x == INT32_MAX) {
			LOG(ERROR, "Cannot get region location from file name: ", fname);
			continue;
		}
		// pasture3d files are scanned first; skip a legacy file for an already-loaded location.
		if (_regions.has(loc)) {
			LOG(DEBUG, "Region ", loc, " already loaded; skipping legacy file ", fname);
			continue;
		}
		const bool legacy = fname.begins_with("terrain3d");
		Ref<Pasture3DRegion> region = ResourceLoader::get_singleton()->load(path, "Pasture3DRegion", ResourceLoader::CACHE_MODE_IGNORE);
		if (region.is_null()) {
			LOG(ERROR, "Cannot load region at ", path);
			continue;
		}
		if (legacy) {
			// Re-class the legacy Terrain3DRegion as a real Pasture3DRegion and mark it modified so
			// the next save writes pasture3d_<loc>.res and removes the old terrain3d_<loc>.res.
			Ref<Pasture3DRegion> migrated;
			migrated.instantiate();
			migrated->set_data(region->get_data());
			region = migrated;
			region->set_modified(true);
		}
		LOG(INFO, "Loaded region: ", loc, " size: ", region->get_region_size());
		if (_regions.is_empty()) {
			_terrain->set_region_size((Pasture3D::RegionSize)region->get_region_size());
		} else {
			if (_terrain->get_region_size() != (Pasture3D::RegionSize)region->get_region_size()) {
				LOG(ERROR, "Region size mismatch. First loaded: ", _terrain->get_region_size(), " next: ",
						region->get_region_size(), " in file: ", path);
				return;
			}
		}
		if (!legacy) {
			region->take_over_path(path);
		}
		region->set_location(loc);
		region->set_version(CURRENT_DATA_VERSION); // Sends upgrade warning if old version
		add_region(region, false);
	}
	update_maps(TYPE_MAX, true, false);
	// If a saved layer stack exists, load it and re-alias the Base onto the loaded region maps.
	// Otherwise every terrain opens as a single-layer stack whose Base aliases those region maps.
	if (!load_layers(p_dir)) {
		_synthesize_base_layer();
	}
}

//TODO have load_directory call load_region, or make a load_file that loads a specific path
void Pasture3DData::load_region(const Vector2i &p_region_loc, const String &p_dir, const bool p_update) {
	LOG(INFO, "Loading region from location ", p_region_loc);
	String path = p_dir + String("/") + Util::location_to_filename(p_region_loc);
	bool legacy = false;
	if (!FileAccess::file_exists(path)) {
		// Fall back to a legacy Terrain3D region file for this location.
		String legacy_path = p_dir + String("/") + Util::location_to_filename(p_region_loc).replace("pasture3d", "terrain3d");
		if (FileAccess::file_exists(legacy_path)) {
			path = legacy_path;
			legacy = true;
		} else {
			LOG(ERROR, "File ", path, " doesn't exist");
			return;
		}
	}
	Ref<Pasture3DRegion> region = ResourceLoader::get_singleton()->load(path, "Pasture3DRegion", ResourceLoader::CACHE_MODE_IGNORE);
	if (region.is_null()) {
		LOG(ERROR, "Cannot load region at ", path);
		return;
	}
	if (legacy) {
		// Re-class to Pasture3DRegion and mark modified so the next save migrates the file name.
		Ref<Pasture3DRegion> migrated;
		migrated.instantiate();
		migrated->set_data(region->get_data());
		region = migrated;
		region->set_modified(true);
	}
	if (_regions.is_empty()) {
		_terrain->set_region_size((Pasture3D::RegionSize)region->get_region_size());
	} else {
		if (_terrain->get_region_size() != (Pasture3D::RegionSize)region->get_region_size()) {
			LOG(ERROR, "Region size mismatch. First loaded: ", _terrain->get_region_size(), " next: ",
					region->get_region_size(), " in file: ", path);
			return;
		}
	}
	if (!legacy) {
		region->take_over_path(path);
	}
	region->set_location(p_region_loc);
	region->set_version(CURRENT_DATA_VERSION); // Sends upgrade warning if old version
	add_region(region, p_update);
}

TypedArray<Image> Pasture3DData::get_maps(const MapType p_map_type) const {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return TypedArray<Image>();
	}
	switch (p_map_type) {
		case TYPE_HEIGHT:
			return get_height_maps();
			break;
		case TYPE_CONTROL:
			return get_control_maps();
			break;
		case TYPE_COLOR:
			return get_color_maps();
			break;
		default:
			break;
	}
	return TypedArray<Image>();
}

void Pasture3DData::update_maps(const MapType p_map_type, const bool p_all_regions, const bool p_generate_mipmaps) {
	// Generate region color mipmaps
	if (p_generate_mipmaps && (p_map_type == TYPE_COLOR || p_map_type == TYPE_MAX)) {
		LOG(EXTREME, "Regenerating color mipmaps");
		for (const Vector2i &region_loc : _regions.keys()) {
			Pasture3DRegion *region = get_region_ptr(region_loc);
			// Generate all or only those marked edited
			if (region && !region->is_deleted() && (p_all_regions || region->is_edited())) {
				region->get_color_map()->generate_mipmaps();
			}
		}
	}

	// Mark texture arrays dirty for rebuilding
	if (p_all_regions) {
		LOG(EXTREME, "Marking dirty maps of type: ", p_map_type);
		switch (p_map_type) {
			case TYPE_HEIGHT:
				_generated_height_maps.clear();
				break;
			case TYPE_CONTROL:
				_generated_control_maps.clear();
				break;
			case TYPE_COLOR:
				_generated_color_maps.clear();
				break;
			default:
				_generated_height_maps.clear();
				_generated_control_maps.clear();
				_generated_color_maps.clear();
				_region_map_dirty = true;
				break;
		}
	}

	bool any_changed = false;

	// Rebuild region map if dirty
	if (_region_map_dirty) {
		LOG(EXTREME, "Regenerating ", REGION_MAP_VSIZE, " region map array from active regions");
		_region_map.clear();
		_region_map.resize(REGION_MAP_SIZE * REGION_MAP_SIZE);
		_region_map_dirty = false;
		_region_locations = TypedArray<Vector2i>(); // enforce new pointer
		int region_id = 0;
		for (const Vector2i &region_loc : _regions.keys()) {
			const Pasture3DRegion *region = get_region_ptr(region_loc);
			if (region && !region->is_deleted()) {
				region_id += 1; // Begin at 1 since 0 = no region
				int map_index = get_region_map_index(region_loc);
				if (map_index >= 0) {
					_region_map[map_index] = region_id;
					_region_locations.push_back(region_loc);
				}
			}
		}
		any_changed = true;
		LOG(DEBUG, "Emitting region_map_changed");
		emit_signal("region_map_changed");
	}

	// Rebuild height maps if dirty
	if (_generated_height_maps.is_dirty()) {
		LOG(EXTREME, "Regenerating height texture array from regions");
		_height_maps.clear();
		for (const Vector2i &region_loc : _region_locations) {
			const Pasture3DRegion *region = get_region_ptr(region_loc);
			if (region) {
				_height_maps.push_back(region->get_height_map());
			} else {
				LOG(ERROR, "Can't find region ", region_loc, ", _regions: ", _regions,
						", locations: ", _region_locations, ". Please report this error.");
				return;
			}
		}
		_generated_height_maps.create(_height_maps);
		calc_height_range();
		any_changed = true;
		LOG(DEBUG, "Emitting height_maps_changed");
		emit_signal("height_maps_changed");
	}

	// Rebulid control maps if dirty
	if (_generated_control_maps.is_dirty()) {
		LOG(EXTREME, "Regenerating control texture array from regions");
		_control_maps.clear();
		for (const Vector2i &region_loc : _region_locations) {
			const Pasture3DRegion *region = get_region_ptr(region_loc);
			if (region) {
				_control_maps.push_back(region->get_control_map());
			}
		}
		_generated_control_maps.create(_control_maps);
		any_changed = true;
		LOG(DEBUG, "Emitting control_maps_changed");
		emit_signal("control_maps_changed");
	}

	// Rebulid color maps if dirty
	if (_generated_color_maps.is_dirty()) {
		LOG(EXTREME, "Regenerating color texture array from regions");
		_color_maps.clear();
		for (const Vector2i &region_loc : _region_locations) {
			const Pasture3DRegion *region = get_region_ptr(region_loc);
			if (region) {
				_color_maps.push_back(region->get_color_map());
			}
		}
		_generated_color_maps.create(_color_maps);
		any_changed = true;
		LOG(DEBUG, "Emitting color_maps_changed");
		emit_signal("color_maps_changed");
	}

	// If no maps have been rebuilt, update only individual regions in the array.
	// Regions marked Edited have been changed by Pasture3DEditor::_operate_map or undo / redo processing.
	if (!any_changed) {
		for (const Vector2i &region_loc : _region_locations) {
			const Pasture3DRegion *region = get_region_ptr(region_loc);
			if (region && region->is_edited()) {
				int region_id = get_region_id(region_loc);
				switch (p_map_type) {
					case TYPE_HEIGHT:
						_generated_height_maps.update(region->get_height_map(), region_id);
						LOG(DEBUG, "Emitting height_maps_changed");
						emit_signal("height_maps_changed");
						break;
					case TYPE_CONTROL:
						_generated_control_maps.update(region->get_control_map(), region_id);
						LOG(DEBUG, "Emitting control_maps_changed");
						emit_signal("control_maps_changed");
						break;
					case TYPE_COLOR:
						_generated_color_maps.update(region->get_color_map(), region_id);
						LOG(DEBUG, "Emitting color_maps_changed");
						emit_signal("color_maps_changed");
						break;
					default:
						_generated_height_maps.update(region->get_height_map(), region_id);
						_generated_control_maps.update(region->get_control_map(), region_id);
						_generated_color_maps.update(region->get_color_map(), region_id);
						LOG(DEBUG, "Emitting height_maps_changed");
						emit_signal("height_maps_changed");
						LOG(DEBUG, "Emitting control_maps_changed");
						emit_signal("control_maps_changed");
						LOG(DEBUG, "Emitting color_maps_changed");
						emit_signal("color_maps_changed");
						break;
				}
			}
		}
	}
	if (any_changed) {
		LOG(DEBUG, "Emitting maps_changed");
		emit_signal("maps_changed");
		if (_terrain) { // Null on standalone data (unit tests).
			_terrain->snap();
		}
	}
}

// Flattens the layer stack down into one region's height image, dirty-scoped to p_dirty_rect.
// For each pixel it walks the layers bottom->top, skipping hidden layers and uncovered (weight 0)
// samples, applying the layer's blend with a = weight * opacity (see PASTURE3D_LAYERS_GUIDE.md §5.1).
// All-uncovered pixels are left untouched: the Base layer is always covered wherever terrain exists,
// so the accumulator is defined everywhere a height exists. Holes/control stay on the composited
// control map for v1 (height-only). No stack => no-op, leaving the runtime path unchanged.
void Pasture3DData::composite_region(const Vector2i &p_region_loc, const Rect2i &p_dirty_rect, const bool p_update) {
	if (_layer_stack.is_null()) {
		return; // Plain terrain: the region images already are the source of truth.
	}
	Pasture3DRegion *region = get_region_ptr(p_region_loc);
	if (!region || region->is_deleted()) {
		return;
	}
	Ref<Image> height_map = region->get_height_map();
	if (height_map.is_null()) {
		LOG(ERROR, "Region ", p_region_loc, " has no height map to composite into");
		return;
	}
	// An empty dirty rect means "the whole region". Clamp to the region image bounds either way.
	Rect2i region_rect(V2I_ZERO, height_map->get_size());
	Rect2i rect = p_dirty_rect.has_area() ? p_dirty_rect.intersection(region_rect) : region_rect;
	if (!rect.has_area()) {
		return;
	}

	// Height always composites (the stack carries the dense height Base). Control/color only run when an
	// overlay of that type exists, so height-only terrains stay byte-identical and pay zero extra cost.
	const bool do_control = _layer_stack->has_overlay_of_type(TYPE_CONTROL);
	const bool do_color = _layer_stack->has_overlay_of_type(TYPE_COLOR);
	_composite_height_region(region, p_region_loc, rect);
	if (do_control) {
		_composite_control_region(region, p_region_loc, rect);
	}
	if (do_color) {
		_composite_color_region(region, p_region_loc, rect);
	}
	region->set_edited(true);
	if (p_update) {
		// Reuse the is_edited() fast path: only edited regions are pushed to the GPU.
		update_maps(TYPE_HEIGHT, false, false);
		if (do_control) {
			update_maps(TYPE_CONTROL, false, false);
		}
		if (do_color) {
			update_maps(TYPE_COLOR, false, false);
		}
	}
}

// Blend height layers [0, p_layer_end) over p_rect into p_acc (rect-relative, NaN-prefilled). Shared by
// the full height composite and composite_height_below: resolve each tile once and read only its
// box-overlap raw (see _composite_height_region for the rationale).
void Pasture3DData::_accumulate_height(real_t *p_acc, const Vector2i &p_region_loc, const Rect2i &p_rect, const int p_layer_end) {
	const int rect_x = p_rect.position.x;
	const int rect_y = p_rect.position.y;
	const int rect_w = p_rect.size.x;
	const int rect_h = p_rect.size.y;
	for (int i = 0; i < p_layer_end; i++) {
		const Pasture3DLayer *layer = _layer_stack->get_layer_ptr(i);
		if (!layer || !layer->is_visible() || layer->get_map_type() != TYPE_HEIGHT) {
			continue;
		}
		if (!layer->has_region(p_region_loc)) {
			continue; // (C) per-region cull.
		}
		const int ts = layer->get_tile_size();
		const real_t op = layer->get_opacity();
		const int bm = (int)layer->get_blend_mode();
		const int tx0 = rect_x / ts;
		const int tx1 = (rect_x + rect_w - 1) / ts;
		const int ty0 = rect_y / ts;
		const int ty1 = (rect_y + rect_h - 1) / ts;
		for (int ty = ty0; ty <= ty1; ty++) {
			for (int tx = tx0; tx <= tx1; tx++) {
				Ref<Image> tile = layer->get_tile(p_region_loc, Vector2i(tx, ty));
				if (tile.is_null()) {
					continue;
				}
				const bool rf = tile->get_format() == Image::FORMAT_RF;
				const int stride = rf ? 1 : 2;
				const bool always_covered = layer->is_base() || rf;
				const int bx = tx * ts;
				const int by = ty * ts;
				const int x0 = MAX(rect_x, bx);
				const int x1 = MIN(rect_x + rect_w, bx + ts);
				const int y0 = MAX(rect_y, by);
				const int y1 = MIN(rect_y + rect_h, by + ts);
				if (x0 >= x1 || y0 >= y1) {
					continue;
				}
				const float *fdata = reinterpret_cast<const float *>(tile->ptr());
				if (!fdata) {
					continue;
				}
				for (int y = y0; y < y1; y++) {
					real_t *acc_row = &p_acc[(y - rect_y) * rect_w];
					const float *trow = fdata + (size_t)(y - by) * ts * stride;
					for (int x = x0; x < x1; x++) {
						const int fi = (x - bx) * stride;
						const real_t w = always_covered ? 1.f : trow[fi + 1];
						if (w == 0.f) {
							continue;
						}
						const real_t v = trow[fi];
						if (std::isnan(v)) {
							continue;
						}
						const real_t a = w * op;
						real_t &dst = acc_row[x - rect_x];
						switch (bm) {
							case Pasture3DLayer::REPLACE:
								dst = std::isnan(dst) ? v : dst + (v - dst) * a;
								break;
							case Pasture3DLayer::ADD:
								dst = (std::isnan(dst) ? 0.f : dst) + v * a;
								break;
							case Pasture3DLayer::MAX: {
								const real_t blended = std::isnan(dst) ? v : dst + (v - dst) * a;
								dst = std::isnan(dst) ? blended : MAX(dst, blended);
								break;
							}
							case Pasture3DLayer::MIN: {
								const real_t blended = std::isnan(dst) ? v : dst + (v - dst) * a;
								dst = std::isnan(dst) ? blended : MIN(dst, blended);
								break;
							}
							default:
								break;
						}
					}
				}
			}
		}
	}
}

// Composite the height of layers [0, p_below_layer_id) over a brush grid (origin min_x/min_z, step vs,
// gw*gh). Returns row-major heights, NaN where no lower layer covers, so a brush samples the ground
// beneath its own layer instead of the full terrain (features stop climbing each other).
PackedFloat32Array Pasture3DData::composite_height_below(const int p_below_layer_id, const double p_min_x, const double p_min_z, const double p_vs, const int p_gw, const int p_gh) {
	PackedFloat32Array out;
	if (p_gw < 1 || p_gh < 1) {
		return out;
	}
	out.resize(p_gw * p_gh);
	real_t *optr = out.ptrw();
	for (int i = 0; i < p_gw * p_gh; i++) {
		optr[i] = NAN;
	}
	if (_layer_stack.is_null() || p_below_layer_id <= 0) {
		return out; // Nothing below -> all NaN (caller falls back to plane / live height).
	}
	const int ox = (int)Math::round(p_min_x / p_vs); // grid origin in global vertex units
	const int oz = (int)Math::round(p_min_z / p_vs);
	const int rsz = _region_size;
	const Vector2i loc_min = get_region_location(Vector3(p_min_x, 0.0, p_min_z));
	const Vector2i loc_max = get_region_location(Vector3(p_min_x + (p_gw - 1) * p_vs, 0.0, p_min_z + (p_gh - 1) * p_vs));
	std::vector<real_t> acc;
	for (int ry = loc_min.y; ry <= loc_max.y; ry++) {
		for (int rx = loc_min.x; rx <= loc_max.x; rx++) {
			const Vector2i loc(rx, ry);
			Pasture3DRegion *region = get_region_ptr(loc);
			if (!region || region->is_deleted()) {
				continue;
			}
			// Grid columns/rows that fall in this region: global vertex (ox+ix) in [rx*rsz, (rx+1)*rsz).
			const int ix0 = MAX(0, rx * rsz - ox);
			const int ix1 = MIN(p_gw, (rx + 1) * rsz - ox);
			const int iz0 = MAX(0, ry * rsz - oz);
			const int iz1 = MIN(p_gh, (ry + 1) * rsz - oz);
			if (ix0 >= ix1 || iz0 >= iz1) {
				continue;
			}
			const int rw = ix1 - ix0;
			const int rh = iz1 - iz0;
			const Rect2i rect(ox + ix0 - rx * rsz, oz + iz0 - ry * rsz, rw, rh);
			acc.assign((size_t)rw * rh, NAN);
			_accumulate_height(acc.data(), loc, rect, p_below_layer_id);
			for (int j = 0; j < rh; j++) {
				const int iz = iz0 + j;
				for (int k = 0; k < rw; k++) {
					optr[iz * p_gw + (ix0 + k)] = acc[(size_t)j * rw + k];
				}
			}
		}
	}
	return out;
}

// Single-point version of composite_height_below (moved-point surface snap). NaN if no lower layer covers.
real_t Pasture3DData::get_height_below(const int p_below_layer_id, const Vector3 &p_global_position) {
	if (_layer_stack.is_null() || p_below_layer_id <= 0) {
		return NAN;
	}
	Vector2i region_loc;
	const Vector2i img_pos = _global_to_region_pixel(p_global_position, region_loc);
	return get_height_below_point(p_below_layer_id, region_loc, img_pos);
}

real_t Pasture3DData::get_height_below_point(const int p_below_layer_id, const Vector2i &p_region_loc, const Vector2i &p_img_pos) {
	if (_layer_stack.is_null() || p_below_layer_id <= 0) {
		return NAN;
	}
	Pasture3DRegion *region = get_region_ptr(p_region_loc);
	if (!region || region->is_deleted()) {
		return NAN;
	}
	if (p_img_pos.x < 0 || p_img_pos.x >= _region_size || p_img_pos.y < 0 || p_img_pos.y >= _region_size) {
		return NAN;
	}
	real_t dst = NAN;
	const int end = MIN(p_below_layer_id, _layer_stack->get_layer_count());
	for (int i = 0; i < end; i++) {
		const Pasture3DLayer *layer = _layer_stack->get_layer_ptr(i);
		if (!layer || !layer->is_visible() || layer->get_map_type() != TYPE_HEIGHT || !layer->has_region(p_region_loc)) {
			continue;
		}
		const int ts = layer->get_tile_size();
		const Vector2i tile_coord(p_img_pos.x / ts, p_img_pos.y / ts);
		Ref<Image> tile = layer->get_tile(p_region_loc, tile_coord);
		if (tile.is_null()) {
			continue;
		}
		const bool rf = tile->get_format() == Image::FORMAT_RF;
		const int stride = rf ? 1 : 2;
		const bool always_covered = layer->is_base() || rf;
		const int lx = p_img_pos.x - tile_coord.x * ts;
		const int ly = p_img_pos.y - tile_coord.y * ts;
		const float *fdata = reinterpret_cast<const float *>(tile->ptr());
		if (!fdata) {
			continue;
		}
		const int fi = (ly * ts + lx) * stride;
		const real_t w = always_covered ? 1.f : fdata[fi + 1];
		if (w == 0.f) {
			continue;
		}
		const real_t v = fdata[fi];
		if (std::isnan(v)) {
			continue;
		}
		const real_t a = w * layer->get_opacity();
		const int bm = (int)layer->get_blend_mode();
		switch (bm) {
			case Pasture3DLayer::REPLACE:
				dst = std::isnan(dst) ? v : dst + (v - dst) * a;
				break;
			case Pasture3DLayer::ADD:
				dst = (std::isnan(dst) ? 0.f : dst) + v * a;
				break;
			case Pasture3DLayer::MAX: {
				const real_t blended = std::isnan(dst) ? v : dst + (v - dst) * a;
				dst = std::isnan(dst) ? blended : MAX(dst, blended);
				break;
			}
			case Pasture3DLayer::MIN: {
				const real_t blended = std::isnan(dst) ? v : dst + (v - dst) * a;
				dst = std::isnan(dst) ? blended : MIN(dst, blended);
				break;
			}
			default:
				break;
		}
	}
	return dst;
}

// Height pass — walks only the height layers (the dense Base + height overlays) bottom->top and blends
// REPLACE/ADD/MAX/MIN exactly as before. Filtering by map type is a no-op for pre-Phase-7 stacks (all
// layers were height), so the output stays byte-identical.
void Pasture3DData::_composite_height_region(Pasture3DRegion *p_region, const Vector2i &p_region_loc, const Rect2i &p_rect) {
	Ref<Image> height_map = p_region->get_height_map();
	if (height_map.is_null()) {
		return;
	}
	// Round 3 compositing: accumulate per-layer into a rect-sized buffer, resolving each layer's tile ONCE
	// per tile-block instead of a Dictionary lookup + image decode PER PIXEL PER LAYER (the old hot path).
	const int rect_x = p_rect.position.x;
	const int rect_y = p_rect.position.y;
	const int rect_w = p_rect.size.x;
	const int rect_h = p_rect.size.y;
	if (rect_w <= 0 || rect_h <= 0) {
		return;
	}
	std::vector<real_t> acc(rect_w * rect_h, NAN); // Undefined until the first covered layer (Base) writes.
	_accumulate_height(acc.data(), p_region_loc, p_rect, _layer_stack->get_layer_count());
	// Write back via an ISOLATED box image + blit_rect, not set_pixelv per pixel (each a GDExtension
	// boundary call — the real cost) and NOT set_data on the shared region image (that hung the editor).
	// Seed the box from the existing region pixels so all-uncovered (NaN) cells pass through unchanged,
	// overlay the composited values, then blit the box back in one in-place copy.
	const Rect2i box_rect(rect_x, rect_y, rect_w, rect_h);
	Ref<Image> box_img = height_map->get_region(box_rect);
	if (box_img.is_valid()) {
		PackedByteArray bdata = box_img->get_data();
		float *bptr = reinterpret_cast<float *>(bdata.ptrw());
		for (int y = 0; y < rect_h; y++) {
			const real_t *acc_row = &acc[y * rect_w];
			float *brow = bptr + (size_t)y * rect_w;
			for (int x = 0; x < rect_w; x++) {
				const real_t v = acc_row[x];
				if (!std::isnan(v)) {
					brow[x] = (float)v;
				}
			}
		}
		box_img->set_data(rect_w, rect_h, false, Image::FORMAT_RF, bdata);
		height_map->blit_rect(box_img, Rect2i(0, 0, rect_w, rect_h), Vector2i(rect_x, rect_y));
	}
}

// Control pass — topmost-covered-wins (PASTURE3D_LAYERS_GUIDE.md §5.1). Control is a packed uint32 (a
// float bit pattern in the R channel), NOT float-blendable, so there is no arithmetic mix: the seed is
// the dense control base (the hand-authored control map captured into its own buffer), and each covered
// control overlay, walked bottom->top, fully replaces the accumulated value. The last (topmost) covered
// overlay wins. Uncovered pixels keep the hand-authored base, so clearing a control layer restores it.
void Pasture3DData::_composite_control_region(Pasture3DRegion *p_region, const Vector2i &p_region_loc, const Rect2i &p_rect) {
	Ref<Image> control_map = p_region->get_control_map();
	if (control_map.is_null()) {
		return;
	}
	const int rect_x = p_rect.position.x;
	const int rect_y = p_rect.position.y;
	const int rect_w = p_rect.size.x;
	const int rect_h = p_rect.size.y;
	if (rect_w <= 0 || rect_h <= 0) {
		return;
	}
	const int base_idx = _layer_stack->find_base_layer(TYPE_CONTROL);
	const Pasture3DLayer *base = base_idx >= 0 ? _layer_stack->get_layer_ptr(base_idx) : nullptr;
	std::vector<float> acc(rect_w * rect_h, NAN);

	// Seed accumulator from base layer (if present and has region) or fallback to current control_map
	const float *ctrl_ptr = reinterpret_cast<const float *>(control_map->ptr());
	const int rsz = _region_size;

	if (base && base->has_region(p_region_loc)) {
		const int ts = base->get_tile_size();
		const int tx0 = rect_x / ts;
		const int tx1 = (rect_x + rect_w - 1) / ts;
		const int ty0 = rect_y / ts;
		const int ty1 = (rect_y + rect_h - 1) / ts;
		for (int ty = ty0; ty <= ty1; ty++) {
			for (int tx = tx0; tx <= tx1; tx++) {
				Ref<Image> tile = base->get_tile(p_region_loc, Vector2i(tx, ty));
				if (tile.is_null()) {
					continue;
				}
				const bool rf = tile->get_format() == Image::FORMAT_RF;
				const int stride = rf ? 1 : 2;
				const int bx = tx * ts;
				const int by = ty * ts;
				const int x0 = MAX(rect_x, bx);
				const int x1 = MIN(rect_x + rect_w, bx + ts);
				const int y0 = MAX(rect_y, by);
				const int y1 = MIN(rect_y + rect_h, by + ts);
				if (x0 >= x1 || y0 >= y1) {
					continue;
				}
				const float *fdata = reinterpret_cast<const float *>(tile->ptr());
				if (!fdata) {
					continue;
				}
				for (int y = y0; y < y1; y++) {
					float *acc_row = &acc[(y - rect_y) * rect_w];
					const float *trow = fdata + (size_t)(y - by) * ts * stride;
					for (int x = x0; x < x1; x++) {
						acc_row[x - rect_x] = trow[(x - bx) * stride];
					}
				}
			}
		}
	} else if (ctrl_ptr) {
		for (int y = 0; y < rect_h; y++) {
			float *acc_row = &acc[y * rect_w];
			const float *crow = ctrl_ptr + (size_t)(rect_y + y) * rsz;
			for (int x = 0; x < rect_w; x++) {
				acc_row[x] = crow[rect_x + x];
			}
		}
	}

	// Walk overlays bottom->top (topmost wins)
	const int layer_count = _layer_stack->get_layer_count();
	for (int i = 0; i < layer_count; i++) {
		const Pasture3DLayer *layer = _layer_stack->get_layer_ptr(i);
		if (!layer || layer->is_base() || !layer->is_visible() || layer->get_map_type() != TYPE_CONTROL || !layer->has_region(p_region_loc)) {
			continue;
		}
		const int ts = layer->get_tile_size();
		const int tx0 = rect_x / ts;
		const int tx1 = (rect_x + rect_w - 1) / ts;
		const int ty0 = rect_y / ts;
		const int ty1 = (rect_y + rect_h - 1) / ts;
		for (int ty = ty0; ty <= ty1; ty++) {
			for (int tx = tx0; tx <= tx1; tx++) {
				Ref<Image> tile = layer->get_tile(p_region_loc, Vector2i(tx, ty));
				if (tile.is_null()) {
					continue;
				}
				const int bx = tx * ts;
				const int by = ty * ts;
				const int x0 = MAX(rect_x, bx);
				const int x1 = MIN(rect_x + rect_w, bx + ts);
				const int y0 = MAX(rect_y, by);
				const int y1 = MIN(rect_y + rect_h, by + ts);
				if (x0 >= x1 || y0 >= y1) {
					continue;
				}
				const float *fdata = reinterpret_cast<const float *>(tile->ptr());
				if (!fdata) {
					continue;
				}
				const bool rf = tile->get_format() == Image::FORMAT_RF;
				const int stride = rf ? 1 : 2;
				for (int y = y0; y < y1; y++) {
					float *acc_row = &acc[(y - rect_y) * rect_w];
					const float *trow = fdata + (size_t)(y - by) * ts * stride;
					for (int x = x0; x < x1; x++) {
						const int fi = (x - bx) * stride;
						const float w = rf ? 1.f : trow[fi + 1];
						if (w > 0.f) {
							acc_row[x - rect_x] = trow[fi];
						}
					}
				}
			}
		}
	}

	// Write back to control_map
	float *dst_ptr = reinterpret_cast<float *>(control_map->ptrw());
	if (dst_ptr) {
		for (int y = 0; y < rect_h; y++) {
			const float *acc_row = &acc[y * rect_w];
			float *dst_row = dst_ptr + (size_t)(rect_y + y) * rsz;
			for (int x = 0; x < rect_w; x++) {
				const float v = acc_row[x];
				if (!std::isnan(v)) {
					dst_row[rect_x + x] = v;
				}
			}
		}
	}
}

// Color pass — alpha-over by weight. The seed is the dense color base (the hand-authored color map,
// RGBA8, carrying albedo in RGB and roughness in A). Each covered color overlay (walked bottom->top)
// blends its albedo over the accumulator by weight*opacity; the roughness (alpha) channel is preserved
// from the base, since color overlays author albedo + coverage, not roughness.
void Pasture3DData::_composite_color_region(Pasture3DRegion *p_region, const Vector2i &p_region_loc, const Rect2i &p_rect) {
	Ref<Image> color_map = p_region->get_color_map();
	if (color_map.is_null()) {
		return;
	}
	const int rect_x = p_rect.position.x;
	const int rect_y = p_rect.position.y;
	const int rect_w = p_rect.size.x;
	const int rect_h = p_rect.size.y;
	if (rect_w <= 0 || rect_h <= 0) {
		return;
	}
	const int base_idx = _layer_stack->find_base_layer(TYPE_COLOR);
	const Pasture3DLayer *base = base_idx >= 0 ? _layer_stack->get_layer_ptr(base_idx) : nullptr;
	const int rsz = _region_size;

	struct AccumColor {
		float r = 0.f;
		float g = 0.f;
		float b = 0.f;
		float a = 1.f; // roughness preserved from base
	};
	std::vector<AccumColor> acc(rect_w * rect_h);

	const uint8_t *col_ptr = color_map->ptr();

	// Seed accumulator from base layer (if present and has region) or fallback to current color_map
	if (base && base->has_region(p_region_loc)) {
		const int ts = base->get_tile_size();
		const int tx0 = rect_x / ts;
		const int tx1 = (rect_x + rect_w - 1) / ts;
		const int ty0 = rect_y / ts;
		const int ty1 = (rect_y + rect_h - 1) / ts;
		for (int ty = ty0; ty <= ty1; ty++) {
			for (int tx = tx0; tx <= tx1; tx++) {
				Ref<Image> tile = base->get_tile(p_region_loc, Vector2i(tx, ty));
				if (tile.is_null()) {
					continue;
				}
				const int bx = tx * ts;
				const int by = ty * ts;
				const int x0 = MAX(rect_x, bx);
				const int x1 = MIN(rect_x + rect_w, bx + ts);
				const int y0 = MAX(rect_y, by);
				const int y1 = MIN(rect_y + rect_h, by + ts);
				if (x0 >= x1 || y0 >= y1) {
					continue;
				}
				const uint8_t *tptr = tile->ptr();
				if (!tptr) {
					continue;
				}
				for (int y = y0; y < y1; y++) {
					AccumColor *acc_row = &acc[(y - rect_y) * rect_w];
					const uint8_t *trow = tptr + (size_t)(y - by) * ts * 4;
					for (int x = x0; x < x1; x++) {
						const int fi = (x - bx) * 4;
						AccumColor &dst = acc_row[x - rect_x];
						dst.r = trow[fi] / 255.f;
						dst.g = trow[fi + 1] / 255.f;
						dst.b = trow[fi + 2] / 255.f;
						dst.a = trow[fi + 3] / 255.f;
					}
				}
			}
		}
	} else if (col_ptr) {
		for (int y = 0; y < rect_h; y++) {
			AccumColor *acc_row = &acc[y * rect_w];
			const uint8_t *crow = col_ptr + (size_t)(rect_y + y) * rsz * 4;
			for (int x = 0; x < rect_w; x++) {
				const int fi = (rect_x + x) * 4;
				AccumColor &dst = acc_row[x];
				dst.r = crow[fi] / 255.f;
				dst.g = crow[fi + 1] / 255.f;
				dst.b = crow[fi + 2] / 255.f;
				dst.a = crow[fi + 3] / 255.f;
			}
		}
	}

	// Walk overlays bottom->top (blend RGB by weight * opacity; roughness in A remains untouched)
	const int layer_count = _layer_stack->get_layer_count();
	for (int i = 0; i < layer_count; i++) {
		const Pasture3DLayer *layer = _layer_stack->get_layer_ptr(i);
		if (!layer || layer->is_base() || !layer->is_visible() || layer->get_map_type() != TYPE_COLOR || !layer->has_region(p_region_loc)) {
			continue;
		}
		const real_t op = layer->get_opacity();
		const int ts = layer->get_tile_size();
		const int tx0 = rect_x / ts;
		const int tx1 = (rect_x + rect_w - 1) / ts;
		const int ty0 = rect_y / ts;
		const int ty1 = (rect_y + rect_h - 1) / ts;
		for (int ty = ty0; ty <= ty1; ty++) {
			for (int tx = tx0; tx <= tx1; tx++) {
				Ref<Image> tile = layer->get_tile(p_region_loc, Vector2i(tx, ty));
				if (tile.is_null()) {
					continue;
				}
				const int bx = tx * ts;
				const int by = ty * ts;
				const int x0 = MAX(rect_x, bx);
				const int x1 = MIN(rect_x + rect_w, bx + ts);
				const int y0 = MAX(rect_y, by);
				const int y1 = MIN(rect_y + rect_h, by + ts);
				if (x0 >= x1 || y0 >= y1) {
					continue;
				}
				const uint8_t *tptr = tile->ptr();
				if (!tptr) {
					continue;
				}
				for (int y = y0; y < y1; y++) {
					AccumColor *acc_row = &acc[(y - rect_y) * rect_w];
					const uint8_t *trow = tptr + (size_t)(y - by) * ts * 4;
					for (int x = x0; x < x1; x++) {
						const int fi = (x - bx) * 4;
						const float w = (trow[fi + 3] / 255.f) * (float)op;
						if (w <= 0.f) {
							continue;
						}
						AccumColor &dst = acc_row[x - rect_x];
						const float cr = trow[fi] / 255.f;
						const float cg = trow[fi + 1] / 255.f;
						const float cb = trow[fi + 2] / 255.f;
						dst.r = dst.r + (cr - dst.r) * w;
						dst.g = dst.g + (cg - dst.g) * w;
						dst.b = dst.b + (cb - dst.b) * w;
					}
				}
			}
		}
	}

	// Write back to color_map
	uint8_t *dst_ptr = color_map->ptrw();
	if (dst_ptr) {
		for (int y = 0; y < rect_h; y++) {
			const AccumColor *acc_row = &acc[y * rect_w];
			uint8_t *dst_row = dst_ptr + (size_t)(rect_y + y) * rsz * 4;
			for (int x = 0; x < rect_w; x++) {
				const int fi = (rect_x + x) * 4;
				const AccumColor &src = acc_row[x];
				dst_row[fi] = (uint8_t)CLAMP(Math::round(src.r * 255.f), 0, 255);
				dst_row[fi + 1] = (uint8_t)CLAMP(Math::round(src.g * 255.f), 0, 255);
				dst_row[fi + 2] = (uint8_t)CLAMP(Math::round(src.b * 255.f), 0, 255);
				dst_row[fi + 3] = (uint8_t)CLAMP(Math::round(src.a * 255.f), 0, 255);
			}
		}
	}
}

// Convenience: composite every active region in full, then a single GPU update for all edits.
void Pasture3DData::composite_regions() {
	if (_layer_stack.is_null()) {
		return;
	}
	Array locations = _regions.keys();
	for (const Vector2i &region_loc : locations) {
		composite_region(region_loc, Rect2i(), false);
	}
	update_maps(TYPE_MAX, false, false);
}

void Pasture3DData::composite_area(const AABB &p_area, const bool p_update) {
	if (_layer_stack.is_null()) {
		return; // Plain terrain: region images already are the source of truth.
	}
	const Vector2i loc_min = get_region_location(p_area.position);
	const Vector2i loc_max = get_region_location(p_area.position + p_area.size);
	for (int y = loc_min.y; y <= loc_max.y; y++) {
		for (int x = loc_min.x; x <= loc_max.x; x++) {
			const Vector2i loc(x, y);
			Pasture3DRegion *region = get_region_ptr(loc);
			if (!region || region->is_deleted()) {
				continue;
			}
			// composite_region clamps the rect to the region; an empty rect would mean the whole region, so
			// skip a region the area only grazes to a zero-width pixel rect (nothing to composite there).
			const Rect2i px_rect = _region_pixel_rect(p_area, loc);
			if (px_rect.has_area()) {
				composite_region(loc, px_rect, p_update);
			}
		}
	}
}

int Pasture3DData::_ensure_typed_base(const MapType p_map_type) {
	if (_layer_stack.is_null() || (p_map_type != TYPE_CONTROL && p_map_type != TYPE_COLOR)) {
		return -1;
	}
	int idx = _layer_stack->find_base_layer(p_map_type);
	if (idx >= 0) {
		return idx;
	}
	// Create the dense base seeded from each region's current (hand-authored) control/color map. The base
	// owns its own buffer so the composite target (the region map) and the seed are distinct (§5.1).
	Ref<Pasture3DLayer> base;
	base.instantiate();
	base->set_layer_name(p_map_type == TYPE_CONTROL ? "Control Base" : "Color Base");
	base->set_map_type(p_map_type);
	base->set_tile_size(_region_size);
	base->set_blend_mode(Pasture3DLayer::REPLACE);
	base->set_base(true);
	base->set_reserved(true); // Internal; not a user-editable layer.
	for (const Vector2i &region_loc : _regions.keys()) {
		Pasture3DRegion *region = get_region_ptr(region_loc);
		if (!region || region->is_deleted()) {
			continue;
		}
		Ref<Image> src = region->get_map_ptr(p_map_type);
		if (src.is_valid() && src->get_width() == _region_size && src->get_height() == _region_size) {
			base->set_region_image(region_loc, Image::create_from_data(src->get_width(), src->get_height(), src->has_mipmaps(), src->get_format(), src->get_data()));
		}
	}
	base->set_modified(true);
	idx = _layer_stack->add_layer_ref(base);
	// A non-Base layer now exists, so the height Base must own its buffer too (live-recomposite safety).
	_unalias_base_layer();
	return idx;
}

void Pasture3DData::_adopt_region_into_bases(Pasture3DRegion *p_region) {
	if (_layer_stack.is_null() || !p_region) {
		return;
	}
	const Vector2i loc = p_region->get_location();
	const int layer_count = _layer_stack->get_layer_count();
	for (int i = 0; i < layer_count; i++) {
		Pasture3DLayer *base = _layer_stack->get_layer_ptr(i);
		if (!base || !base->is_base() || base->has_region(loc)) {
			continue;
		}
		Ref<Image> src = p_region->get_map_ptr(base->get_map_type());
		if (src.is_null()) {
			continue;
		}
		if (src->get_width() != base->get_tile_size() || src->get_height() != base->get_tile_size()) {
			// A base synthesized before a region-size change carries a stale tile size (e.g. a stack
			// saved by an older build). An empty base can simply be re-sized to match; one with pixel
			// data can't be fixed here, and silently skipping would leave the region uncovered forever —
			// warn so the mismatch is visible.
			if (base->get_region_locations().is_empty()) {
				base->set_tile_size(src->get_width());
			} else {
				LOG(WARN, "Base layer '", base->get_layer_name(), "' tile size ", base->get_tile_size(),
						" != region size ", src->get_width(), "; region ", loc, " not adopted into the stack");
				continue;
			}
		}
		// A single-layer height Base aliases the region map (zero copy); any other base owns a copy so the
		// composite target and the base source stay distinct (the un-alias invariant, §5.1 / §10.4).
		if (base->get_map_type() == TYPE_HEIGHT && layer_count <= 1) {
			base->set_region_image(loc, src);
		} else {
			base->set_region_image(loc, Image::create_from_data(src->get_width(), src->get_height(), src->has_mipmaps(), src->get_format(), src->get_data()));
		}
	}
}

// Re-map the layer stack's pixel data onto the new region grid (called by change_region_size; see the
// header comment). At this point every layer was emptied and re-sized up front, and base adoption
// during the region re-add seeded each base with a copy of the new region maps — i.e. the flattened
// composite. Two passes over the old snapshot restore the true sources:
//   Bases: blit the old hand-authored base pixels back over the adopted seeds, so the base stays
//     distinct from the composite where overlays cover (the idempotency requirement, §5.1). Areas the
//     old grid never covered keep the seed (sanitized defaults there — correct). A single-layer stack
//     is exempt: its Base aliases the region maps and IS the composite by definition.
//   Overlays: tiles re-key exactly. Every size in play is a power of two, so an old tile lands
//     tile-aligned in the new grid — either 1:1 (tile size unchanged) or split into aligned sub-tiles
//     (the tile size was capped to the new region size).
void Pasture3DData::_migrate_layers_region_size(const int p_old_size, const int p_new_size, const TypedArray<Dictionary> &p_old_tiles, const PackedInt32Array &p_old_tile_sizes) {
	if (_layer_stack.is_null() || p_old_size <= 0) {
		return;
	}
	const int layer_count = _layer_stack->get_layer_count();
	for (int i = 0; i < layer_count && i < p_old_tiles.size(); i++) {
		Pasture3DLayer *layer = _layer_stack->get_layer_ptr(i);
		const Dictionary old_tiles = p_old_tiles[i];
		if (!layer || old_tiles.is_empty()) {
			continue; // Nothing to migrate; an empty base was already covered by adoption.
		}
		const bool is_base = layer->is_base();
		if (is_base && layer_count == 1) {
			// Aliased single-layer Base: adoption re-aliased it onto the new maps, which carry the old
			// (composited == base) heights verbatim. Nothing to restore.
			layer->set_modified(false);
			continue;
		}
		const int ts_old = (int)p_old_tile_sizes[i];
		const int ts_new = layer->get_tile_size();
		if (ts_old <= 0) {
			continue;
		}
		const int chunk = MIN(ts_old, ts_new);
		Dictionary new_tiles = layer->get_tiles(); // Shared ref: base blits land in the layer directly.
		for (const Vector2i &old_loc : old_tiles.keys()) {
			const Dictionary tmap = old_tiles[old_loc];
			for (const Vector2i &tc : tmap.keys()) {
				const Ref<Image> img = tmap[tc];
				if (img.is_null() || img->get_width() != ts_old || img->get_height() != ts_old) {
					continue;
				}
				for (int cy = 0; cy < ts_old; cy += chunk) {
					for (int cx = 0; cx < ts_old; cx += chunk) {
						const Vector2i g = old_loc * p_old_size + tc * ts_old + Vector2i(cx, cy);
						const Vector2i new_loc = V2I_DIVIDE_FLOOR(g, p_new_size);
						const Vector2i local = g - new_loc * p_new_size;
						Dictionary ntmap = new_tiles.get(new_loc, Dictionary());
						if (is_base) {
							// Overwrite the composite-derived seed with the old hand-authored base pixels. No
							// seed here means no active region at this location (e.g. an old deleted region).
							Ref<Image> dst = ntmap.get(V2I_ZERO, Ref<Image>());
							if (dst.is_valid() && dst->get_format() == img->get_format()) {
								dst->blit_rect(img, Rect2i(cx, cy, chunk, chunk), local);
							}
						} else {
							// chunk == ts_new for overlays and both grids align, so a chunk IS one new tile.
							ntmap[local / ts_new] = (chunk == ts_old) ? img : img->get_region(Rect2i(cx, cy, chunk, chunk));
							new_tiles[new_loc] = ntmap;
						}
					}
				}
			}
		}
		if (!is_base) {
			layer->set_tiles(new_tiles);
			layer->gc(); // Split tiles may be fully uncovered; reclaim them.
		}
		layer->set_modified(true);
	}
	LOG(INFO, "Migrated layer stack pixel data from region size ", p_old_size, " to ", p_new_size);
}

///////////////////////////
// Tool API (PASTURE3D_LAYERS_GUIDE.md §8)
///////////////////////////

Vector2i Pasture3DData::_global_to_region_pixel(const Vector3 &p_global_position, Vector2i &r_region_loc) const {
	r_region_loc = get_region_location(p_global_position);
	Vector2i global_offset = r_region_loc * _region_size;
	Vector3 descaled_pos = p_global_position / _vertex_spacing;
	Vector2i img_pos = Vector2i(descaled_pos.x - global_offset.x, descaled_pos.z - global_offset.y);
	return img_pos.clamp(V2I_ZERO, V2I(_region_size - 1));
}

int Pasture3DData::find_layer_by_owner(const String &p_owner_id) const {
	return _layer_stack.is_valid() ? _layer_stack->find_layer_by_owner(p_owner_id) : -1;
}

int Pasture3DData::create_owned_layer(const String &p_owner_id, const String &p_name, const int p_blend_mode) {
	return create_owned_layer_typed(p_owner_id, p_name, p_blend_mode, TYPE_HEIGHT);
}

int Pasture3DData::create_owned_layer_typed(const String &p_owner_id, const String &p_name, const int p_blend_mode, const int p_map_type) {
	if (!ensure_layer_stack()) {
		LOG(ERROR, "Cannot create owned layer '", p_name, "': no region data to anchor a Base layer");
		return -1;
	}
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Invalid map type ", p_map_type, " for owned layer '", p_name, "'");
		return -1;
	}
	// Idempotent: re-use the existing reserved layer for this owner if it is already present.
	int existing = _layer_stack->find_layer_by_owner(p_owner_id);
	if (existing >= 0) {
		return existing;
	}
	// Control/color overlays need a dense base of their type so compositing has a hand-authored source
	// distinct from the region map it writes (the idempotency requirement, §5.1).
	if (p_map_type == TYPE_CONTROL || p_map_type == TYPE_COLOR) {
		_ensure_typed_base((MapType)p_map_type);
	}
	int idx = _layer_stack->add_layer(p_name, Pasture3DLayer::BlendMode(p_blend_mode));
	if (idx < 0) {
		return -1;
	}
	Pasture3DLayer *layer = _layer_stack->get_layer_ptr(idx);
	if (layer) {
		layer->set_map_type((MapType)p_map_type); // Before any tiles: picks the tile format (RGF / RGBA8).
		layer->set_owner_id(p_owner_id);
		layer->set_reserved(true); // Tool-owned: user sculpt strokes are blocked (§6).
	}
	if (idx > 0) {
		// First non-Base layer: the Base must own its buffer so live re-compositing stays idempotent.
		_unalias_base_layer();
	}
	// Only reached when a layer was genuinely created — the idempotent "owner already has one" path
	// returned above. A tool bakes constantly, so firing this on every _ensure_layer_for would rebuild
	// the Layers dock's rows continuously (and eat a rename in progress).
	emit_signal("layers_changed");
	return idx;
}

void Pasture3DData::set_height_on_layer(const int p_layer_id, const Vector3 &p_global_position, const real_t p_height, const real_t p_weight, const bool p_composite) {
	Pasture3DLayer *layer = _layer_stack.is_valid() ? _layer_stack->get_layer_ptr(p_layer_id) : nullptr;
	if (!layer) {
		// Backward-compat: no stack / invalid layer => write the region image directly (§8.3).
		set_height(p_global_position, p_height);
		return;
	}
	Vector2i region_loc;
	Vector2i img_pos = _global_to_region_pixel(p_global_position, region_loc);
	Pasture3DRegion *region = get_region_ptr(region_loc);
	if (!region || region->is_deleted()) {
		return; // No region here; skip silently (the tool may sweep beyond the terrain bounds).
	}
	layer->set_sample(region_loc, img_pos, p_height, p_weight);
	if (p_composite) {
		composite_region(region_loc, Rect2i(img_pos, V2I(1)), false);
	}
	region->set_modified(true); // The composited runtime image changed; persist it on save.
}

void Pasture3DData::add_height_on_layer(const int p_layer_id, const Vector3 &p_global_position, const real_t p_delta, const real_t p_weight, const bool p_composite) {
	Pasture3DLayer *layer = _layer_stack.is_valid() ? _layer_stack->get_layer_ptr(p_layer_id) : nullptr;
	if (!layer) {
		set_height(p_global_position, get_height(p_global_position) + p_delta);
		return;
	}
	Vector2i region_loc;
	Vector2i img_pos = _global_to_region_pixel(p_global_position, region_loc);
	Pasture3DRegion *region = get_region_ptr(region_loc);
	if (!region || region->is_deleted()) {
		return;
	}
	// Accumulate within this layer (uncovered reads as 0); the blend mode decides how it stacks below.
	real_t current = layer->get_weight(region_loc, img_pos) > 0.f ? layer->get_value(region_loc, img_pos) : 0.f;
	layer->set_sample(region_loc, img_pos, current + p_delta, p_weight);
	if (p_composite) {
		composite_region(region_loc, Rect2i(img_pos, V2I(1)), false);
	}
	region->set_modified(true);
}

real_t Pasture3DData::get_layer_height(const int p_layer_id, const Vector3 &p_global_position) const {
	Pasture3DLayer *layer = _layer_stack.is_valid() ? _layer_stack->get_layer_ptr(p_layer_id) : nullptr;
	if (!layer) {
		return NAN;
	}
	Vector2i region_loc;
	Vector2i img_pos = _global_to_region_pixel(p_global_position, region_loc);
	return layer->get_value(region_loc, img_pos);
}

void Pasture3DData::set_control_on_layer(const int p_layer_id, const Vector3 &p_global_position, const int p_control, const real_t p_weight, const bool p_composite) {
	Pasture3DLayer *layer = _layer_stack.is_valid() ? _layer_stack->get_layer_ptr(p_layer_id) : nullptr;
	if (!layer || layer->get_map_type() != TYPE_CONTROL) {
		// Backward-compat: no stack / wrong layer => write the region control map directly (§8.3).
		set_control(p_global_position, uint32_t(p_control));
		return;
	}
	Vector2i region_loc;
	Vector2i img_pos = _global_to_region_pixel(p_global_position, region_loc);
	Pasture3DRegion *region = get_region_ptr(region_loc);
	if (!region || region->is_deleted()) {
		return;
	}
	// Control is a packed uint32 stored as float bits in the R channel (same encoding as the region map).
	layer->set_sample(region_loc, img_pos, as_float(uint32_t(p_control)), p_weight);
	if (p_composite) {
		composite_region(region_loc, Rect2i(img_pos, V2I(1)), false);
	}
	region->set_modified(true);
}

void Pasture3DData::set_hole_on_layer(const int p_layer_id, const Vector3 &p_global_position, const bool p_hole) {
	Pasture3DLayer *layer = _layer_stack.is_valid() ? _layer_stack->get_layer_ptr(p_layer_id) : nullptr;
	if (!layer || layer->get_map_type() != TYPE_CONTROL) {
		set_control_hole(p_global_position, p_hole); // Fallback: destructive carve into the region map.
		return;
	}
	// Author the FULL control value (the composited control here, with the hole bit set) so the
	// topmost-covered-wins composite preserves texture/nav/etc and only flips the hole bit. Reading the
	// live composite picks up the hand-authored base (no hole), so a clear + repaint is idempotent.
	uint32_t control = get_control(p_global_position);
	if (control == UINT32_MAX) {
		control = 0; // No data here yet; start from an empty control word.
	}
	control = (control & ~(0x1 << 2)) | enc_hole(p_hole);
	set_control_on_layer(p_layer_id, p_global_position, int(control), 1.f);
}

void Pasture3DData::set_color_on_layer(const int p_layer_id, const Vector3 &p_global_position, const Color &p_color, const real_t p_weight, const bool p_composite) {
	Pasture3DLayer *layer = _layer_stack.is_valid() ? _layer_stack->get_layer_ptr(p_layer_id) : nullptr;
	if (!layer || layer->get_map_type() != TYPE_COLOR) {
		set_color(p_global_position, p_color); // Backward-compat: write the region color map directly.
		return;
	}
	Vector2i region_loc;
	Vector2i img_pos = _global_to_region_pixel(p_global_position, region_loc);
	Pasture3DRegion *region = get_region_ptr(region_loc);
	if (!region || region->is_deleted()) {
		return;
	}
	layer->set_sample_color(region_loc, img_pos, p_color, p_weight);
	if (p_composite) {
		composite_region(region_loc, Rect2i(img_pos, V2I(1)), false);
	}
	region->set_modified(true);
}

Rect2i Pasture3DData::_region_pixel_rect(const AABB &p_area, const Vector2i &p_region_loc) const {
	Vector3 mn = p_area.position / _vertex_spacing;
	Vector3 mx = (p_area.position + p_area.size) / _vertex_spacing;
	Vector2i region_offset = p_region_loc * _region_size;
	// Floor the min and ceil the max so a tile is dropped even on partial coverage.
	Vector2i local_min(Math::floor(mn.x) - region_offset.x, Math::floor(mn.z) - region_offset.y);
	Vector2i local_max(Math::ceil(mx.x) - region_offset.x, Math::ceil(mx.z) - region_offset.y);
	local_min = local_min.clamp(V2I_ZERO, V2I(_region_size));
	local_max = local_max.clamp(V2I_ZERO, V2I(_region_size));
	return Rect2i(local_min, local_max - local_min);
}

void Pasture3DData::clear_layer_in_area(const int p_layer_id, const AABB &p_area, const bool p_composite) {
	Pasture3DLayer *layer = _layer_stack.is_valid() ? _layer_stack->get_layer_ptr(p_layer_id) : nullptr;
	if (!layer) {
		return; // No stack / invalid layer: nothing to clear (plain-terrain writes go to the Base image).
	}
	// A layer tiled at region granularity has one tile per region; sub-tile clearing then degrades to
	// clearing that whole tile. Sub-tiled layers (the default) drop only the tiles the AABB overlaps.
	const bool region_granular = layer->get_tile_size() >= _region_size;
	const int ts = layer->get_tile_size();
	Vector3 mn = p_area.position;
	Vector3 mx = p_area.position + p_area.size;
	Vector2i loc_min = get_region_location(mn);
	Vector2i loc_max = get_region_location(mx);
	bool any = false;
	for (int y = loc_min.y; y <= loc_max.y; y++) {
		for (int x = loc_min.x; x <= loc_max.x; x++) {
			const Vector2i loc(x, y);
			if (!layer->has_region(loc)) {
				continue;
			}
			Pasture3DRegion *region = get_region_ptr(loc);
			if (!region || region->is_deleted()) {
				continue;
			}
			bool cleared = false;
			const Rect2i px_rect = region_granular ? Rect2i() : _region_pixel_rect(p_area, loc);
			if (region_granular) {
				layer->clear_region(loc);
				cleared = true;
			} else {
				cleared = layer->clear_tiles_in_rect(loc, px_rect);
			}
			if (cleared) {
				if (p_composite) {
					// Recomposite ONLY the dropped tiles' span (the pixel rect grown to tile boundaries),
					// not the whole region — the whole-region recomposite was the dirty-rect bottleneck.
					// Tiles NOT overlapping the AABB (e.g. a co-located feature in another sub-tile) keep
					// their existing composite. An empty rect (region-granular) means the whole region.
					Rect2i comp_rect; // empty => whole region
					if (!region_granular && px_rect.has_area()) {
						const int x0 = (px_rect.position.x / ts) * ts;
						const int y0 = (px_rect.position.y / ts) * ts;
						const int x1 = ((px_rect.position.x + px_rect.size.x + ts - 1) / ts) * ts;
						const int y1 = ((px_rect.position.y + px_rect.size.y + ts - 1) / ts) * ts;
						comp_rect = Rect2i(x0, y0, x1 - x0, y1 - y0);
					}
					composite_region(loc, comp_rect, false);
				}
				region->set_modified(true);
				any = true;
			}
		}
	}
	if (any) {
		LOG(DEBUG, "Cleared layer ", p_layer_id, " in regions overlapping ", p_area);
	}
}

void Pasture3DData::gc_layer(const int p_layer_id) {
	Pasture3DLayer *layer = _layer_stack.is_valid() ? _layer_stack->get_layer_ptr(p_layer_id) : nullptr;
	if (layer) {
		layer->gc();
	}
}

void Pasture3DData::set_active_layer(const int p_layer_id) {
	if (_layer_stack.is_valid()) {
		_layer_stack->set_active_layer(p_layer_id);
	}
}

void Pasture3DData::set_pixel(const MapType p_map_type, const Vector3 &p_global_position, const Color &p_pixel) {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return;
	}
	Vector2i region_loc = get_region_location(p_global_position);
	Pasture3DRegion *region = get_region_ptr(region_loc);
	if (!region) {
		LOG(ERROR, "No active region found at: ", p_global_position);
		return;
	}
	if (region->is_deleted()) {
		LOG(ERROR, "No active region found at: ", p_global_position);
		return;
	}
	Vector2i global_offset = region_loc * _region_size;
	Vector3 descaled_pos = p_global_position / _vertex_spacing;
	Vector2i img_pos = Vector2i(descaled_pos.x - global_offset.x, descaled_pos.z - global_offset.y);
	img_pos = img_pos.clamp(V2I_ZERO, V2I(_region_size - 1));
	Image *map = region->get_map_ptr(p_map_type);
	if (map) {
		map->set_pixelv(img_pos, p_pixel);
		region->set_modified(true);
	}
}

Color Pasture3DData::get_pixel(const MapType p_map_type, const Vector3 &p_global_position) const {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return COLOR_NAN;
	}
	Vector2i region_loc = get_region_location(p_global_position);
	const Pasture3DRegion *region = get_region_ptr(region_loc);
	if (!region) {
		return COLOR_NAN;
	}
	if (region->is_deleted()) {
		return COLOR_NAN;
	}
	Vector2i global_offset = region_loc * _region_size;
	Vector3 descaled_pos = p_global_position / _vertex_spacing;
	Vector2i img_pos = Vector2i(descaled_pos.x - global_offset.x, descaled_pos.z - global_offset.y);
	img_pos = img_pos.clamp(V2I_ZERO, V2I(_region_size - 1));
	Image *map = region->get_map_ptr(p_map_type);
	if (map) {
		return map->get_pixelv(img_pos);
	} else {
		return COLOR_NAN;
	}
}

real_t Pasture3DData::get_height(const Vector3 &p_global_position) const {
	if (is_hole(get_control(p_global_position))) {
		return NAN;
	}
	Vector3 pos = p_global_position;
	const real_t &step = _vertex_spacing;
	pos.y = 0.f;
	// Round to nearest vertex
	Vector3 pos_round = pos.snapped(Vector3(step, 0.f, step));
	// If requested position is close to a vertex, return its height
	if ((pos - pos_round).length_squared() < 0.0001f) {
		return get_pixel(TYPE_HEIGHT, pos).r;
	} else {
		// Otherwise, bilinearly interpolate 4 surrounding vertices
		Vector3 pos00 = Vector3(floor(pos.x / step) * step, 0.f, floor(pos.z / step) * step);
		real_t ht00 = get_pixel(TYPE_HEIGHT, pos00).r;
		Vector3 pos01 = pos00 + Vector3(0.f, 0.f, step);
		real_t ht01 = get_pixel(TYPE_HEIGHT, pos01).r;
		Vector3 pos10 = pos00 + Vector3(step, 0.f, 0.f);
		real_t ht10 = get_pixel(TYPE_HEIGHT, pos10).r;
		Vector3 pos11 = pos00 + Vector3(step, 0.f, step);
		real_t ht11 = get_pixel(TYPE_HEIGHT, pos11).r;
		return bilerp(ht00, ht01, ht10, ht11, pos00, pos11, pos);
	}
}

Vector3 Pasture3DData::get_normal(const Vector3 &p_global_position) const {
	if (get_region_idp(p_global_position) < 0 || is_hole(get_control(p_global_position))) {
		return V3_NAN;
	}
	real_t height = get_height(p_global_position);
	real_t u = height - get_height(p_global_position + Vector3(_vertex_spacing, 0.0f, 0.0f));
	real_t v = height - get_height(p_global_position + Vector3(0.f, 0.f, _vertex_spacing));
	Vector3 normal = Vector3(u, _vertex_spacing, v);
	normal.normalize();
	return normal;
}

bool Pasture3DData::is_in_slope(const Vector3 &p_global_position, const Vector2 &p_slope_range, const Vector3 &p_normal) const {
	// If slope is full range, nothing to do here
	const Vector2 slope_range = CLAMP(p_slope_range, V2_ZERO, V2(90.f));
	if (slope_range.y - slope_range.x > 89.99f) {
		return true;
	}

	// Use custom normal if provided
	Vector3 slope_normal = p_normal;
	if (!slope_normal.is_zero_approx()) {
		slope_normal.normalize();
	} else {
		// Else, compute terrain normal
		if (get_region_idp(p_global_position) < 0) {
			return false;
		}
		// Adapted from get_height() to work with holes
		auto get_height = [&](Vector3 pos) -> real_t {
			real_t step = _terrain->get_vertex_spacing();
			// Round to nearest vertex
			Vector3 pos_round = pos.snapped(Vector3(step, 0.f, step));
			real_t height = get_pixel(TYPE_HEIGHT, pos_round).r;
			return std::isnan(height) ? 0.f : height;
		};

		const real_t vertex_spacing = _terrain->get_vertex_spacing();
		const real_t height = get_height(p_global_position);
		const real_t u = height - get_height(p_global_position + Vector3(vertex_spacing, 0.0f, 0.0f));
		const real_t v = height - get_height(p_global_position + Vector3(0.f, 0.f, vertex_spacing));
		slope_normal = Vector3(u, vertex_spacing, v);
		slope_normal.normalize();
	}

	// angle_to() rather than acos(dot()): the dot of two normalized vectors can land a hair
	// above 1.0 through float error on a flat cell, and acos() of that is NaN, which makes
	// every comparison below false -- a perfectly flat point silently failing a 0-degree
	// slope test. angle_to() is atan2(cross.length(), dot), which has no such domain edge.
	const real_t slope_angle = slope_normal.angle_to(V3_UP);
	const real_t slope_angle_degrees = Math::rad_to_deg(slope_angle);
	return (slope_range.x <= slope_angle_degrees) && (slope_angle_degrees <= slope_range.y);
}

/**
 * Returns:
 * X = base index
 * Y = overlay index
 * Z = percentage blend between X and Y. Limited to the fixed values in RANGE.
 * Interpretation of this data is up to the gamedev. Unfortunately due to blending, this isn't
 * pixel perfect. I would have your player print this location as you walk around to see how the
 * blending values look, then consider that the overlay texture is visible starting at a blend
 * value of .3-.5, otherwise it's the base texture.
 **/
Vector3 Pasture3DData::get_texture_id(const Vector3 &p_global_position) const {
	// Verify in a region
	int region_id = get_region_idp(p_global_position);
	if (region_id < 0) {
		return V3_NAN;
	}

	// Verify not in a hole
	float src = get_pixel(TYPE_CONTROL, p_global_position).r; // 32-bit float, not double/real
	if (is_hole(src)) {
		return V3_NAN;
	}

	// If material available, autoshader enabled, and pixel set to auto
	if (_terrain) {
		Ref<Pasture3DMaterial> t_material = _terrain->get_material();
		bool auto_enabled = t_material->get_auto_shader_enabled();
		bool control_auto = is_auto(src);
		if (auto_enabled && control_auto) {
			real_t auto_slope = real_t(t_material->get_shader_param("auto_slope"));
			real_t auto_height_reduction = real_t(t_material->get_shader_param("auto_height_reduction"));
			real_t height = get_height(p_global_position);
			Vector3 normal = get_normal(p_global_position);
			uint32_t base_id = t_material->get_shader_param("auto_base_texture");
			uint32_t overlay_id = t_material->get_shader_param("auto_overlay_texture");
			real_t blend = CLAMP((auto_slope * 2.f * (normal.y - 1.f) + 1.f) - auto_height_reduction * .01f * height, 0.f, 1.f);
			return Vector3(real_t(base_id), real_t(overlay_id), blend);
		}
	}

	// Else, just get textures from control map
	uint32_t base_id = get_base(src);
	uint32_t overlay_id = get_overlay(src);
	real_t blend = real_t(get_blend(src)) / 255.0f;
	return Vector3(real_t(base_id), real_t(overlay_id), blend);
}

/**
 * Returns the location of a terrain vertex at a certain LOD. If there is a hole at the position, it returns
 * NAN in the vector's Y coordinate.
 * p_lod (0-8): Determines how many heights around the given global position will be sampled.
 * p_filter:
 *  HEIGHT_FILTER_NEAREST: Samples the height map at the exact coordinates given.
 *  HEIGHT_FILTER_MINIMUM: Samples (1 << p_lod) ** 2 heights around the given coordinates and returns the lowest.
 * p_global_position: X and Z coordinates of the vertex. Heights will be sampled around these coordinates.
 */
Vector3 Pasture3DData::get_mesh_vertex(const int32_t p_lod, const HeightFilter p_filter, const Vector3 &p_global_position) const {
	LOG(INFO, "Calculating vertex location");
	int32_t step = 1 << CLAMP(p_lod, 0, 8);
	real_t height = 0.0f;

	switch (p_filter) {
		case HEIGHT_FILTER_NEAREST: {
			if (is_hole(get_control(p_global_position))) {
				height = NAN;
			} else {
				height = get_height(p_global_position);
			}
		} break;
		case HEIGHT_FILTER_MINIMUM: {
			height = get_height(p_global_position);
			for (int32_t dx = -step / 2; dx < step / 2; dx += 1) {
				for (int32_t dz = -step / 2; dz < step / 2; dz += 1) {
					Vector3 position = p_global_position + Vector3(dx, 0.f, dz) * _vertex_spacing;
					if (is_hole(get_control(position))) {
						height = NAN;
						break;
					}
					real_t h = get_height(position);
					if (h < height) {
						height = h;
					}
				}
			}
		} break;
	}
	return Vector3(p_global_position.x, height, p_global_position.z);
}

void Pasture3DData::add_edited_area(const AABB &p_area) {
	if (_edited_area.has_surface()) {
		_edited_area = _edited_area.merge(p_area);
	} else {
		_edited_area = p_area;
	}
	LOG(DEBUG, "Emitting maps_edited");
	emit_signal("maps_edited", p_area);
}

// Recalculates master height range from all active regions current height ranges
// Recursive mode has all regions to recalculate from each heightmap pixel
void Pasture3DData::calc_height_range(const bool p_recursive) {
	_master_height_range = V2_ZERO;
	for (const Vector2i &region_loc : _region_locations) {
		Pasture3DRegion *region = get_region_ptr(region_loc);
		if (!region) {
			continue;
		}
		if (p_recursive) {
			region->calc_height_range();
		}
		update_master_heights(region->get_height_range());
	}
	LOG(EXTREME, "Accumulated height range for all regions: ", _master_height_range);
}

/**
 * Imports an Image set (Height, Control, Color) into Pasture3DData
 * It does NOT normalize values to 0-1. You must do that using get_min_max() and adjusting scale and offset.
 * Parameters:
 *	p_images - MapType.TYPE_MAX sized array of Images for Height, Control, Color. Images can be blank or null
 *	p_global_position - X,0,Z location on the region map. Valid range is ~ (+/-8192, +/-8192)
 *	p_offset - Add this factor to all height values, can be negative
 *	p_scale - Scale all height values by this factor (applied after offset)
 */
void Pasture3DData::import_images(const TypedArray<Image> &p_images, const Vector3 &p_global_position, const real_t p_offset, const real_t p_scale) {
	IS_INIT_MESG("Data not initialized", VOID);
	if (p_images.size() != TYPE_MAX) {
		LOG(ERROR, "p_images.size() is ", p_images.size(), ". It should be ", TYPE_MAX, " even if some Images are blank or null");
		return;
	}

	Vector2i img_size = V2I_ZERO;
	for (int i = 0; i < TYPE_MAX; i++) {
		Ref<Image> img = p_images[i];
		if (img.is_valid() && !img->is_empty()) {
			LOG(INFO, "Importing image type ", TYPESTR[i], ", size: ", img->get_size(), ", format: ", img->get_format());
			if (i == TYPE_HEIGHT) {
				LOG(INFO, "Applying offset: ", p_offset, ", scale: ", p_scale);
			}
			if (img_size == V2I_ZERO) {
				img_size = img->get_size();
			} else if (img_size != img->get_size()) {
				LOG(ERROR, "Included Images in p_images have different dimensions. Aborting import");
				return;
			}
		}
	}
	if (img_size == V2I_ZERO) {
		LOG(ERROR, "All images are empty. Nothing to import");
		return;
	}

	Vector3 descaled_position = p_global_position / _vertex_spacing;
	int max_dimension = _region_size * REGION_MAP_SIZE / 2;
	if ((std::abs(descaled_position.x) > max_dimension) || (std::abs(descaled_position.z) > max_dimension)) {
		LOG(ERROR, "Specify a position within +/-", Vector3(max_dimension, 0.f, max_dimension) * _vertex_spacing);
		return;
	}
	if ((descaled_position.x + img_size.x > max_dimension) ||
			(descaled_position.z + img_size.y > max_dimension)) {
		LOG(ERROR, img_size, " image will not fit at ", p_global_position,
				". Try ", -(img_size * _vertex_spacing) / 2.f, " to center, or increase region_size");
		return;
	}

	TypedArray<Image> src_images;
	src_images.resize(TYPE_MAX);

	for (int i = 0; i < TYPE_MAX; i++) {
		Ref<Image> img = p_images[i];
		src_images[i] = img;
		if (img.is_null()) {
			continue;
		}

		// Apply scale and offsets to the heightmap and filter out invalid data
		if (i == TYPE_HEIGHT) {
			LOG(DEBUG, "Creating new temp image to adjust scale: ", p_scale, " offset: ", p_offset);
			Ref<Image> newimg = Image::create_empty(img->get_size().x, img->get_size().y, false, FORMAT[TYPE_HEIGHT]);
			for (int y = 0; y < img->get_height(); y++) {
				for (int x = 0; x < img->get_width(); x++) {
					Color clr = img->get_pixel(x, y);
					if (std::isnormal(clr.r)) {
						clr.r = (clr.r * p_scale) + p_offset;
					} else {
						clr.r = p_offset;
					}
					newimg->set_pixel(x, y, clr);
				}
			}
			src_images[i] = newimg;
		}
	}

	// Calculate regions this image will span
	int img_start_x = (int)Math::floor(descaled_position.x);
	int img_start_z = (int)Math::floor(descaled_position.z);
	int img_end_x = img_start_x + img_size.x - 1;
	int img_end_z = img_start_z + img_size.y - 1;

	int start_region_x = (int)Math::floor(real_t(img_start_x) / real_t(_region_size));
	int start_region_z = (int)Math::floor(real_t(img_start_z) / real_t(_region_size));
	int end_region_x = (int)Math::floor(real_t(img_end_x) / real_t(_region_size));
	int end_region_z = (int)Math::floor(real_t(img_end_z) / real_t(_region_size));

	// Clamp region indices to valid range
	int half_region_map = REGION_MAP_SIZE / 2;
	start_region_x = CLAMP(start_region_x, -half_region_map, half_region_map - 1);
	start_region_z = CLAMP(start_region_z, -half_region_map, half_region_map - 1);
	end_region_x = CLAMP(end_region_x, -half_region_map, half_region_map - 1);
	end_region_z = CLAMP(end_region_z, -half_region_map, half_region_map - 1);

	LOG(DEBUG, "Image spans regions (", start_region_x, ",", start_region_z, ") to (", end_region_x, ",", end_region_z, ")");

	bool generate_mipmaps = false;
	for (int rz = start_region_z; rz <= end_region_z; rz++) {
		for (int rx = start_region_x; rx <= end_region_x; rx++) {
			Vector2i region_loc = Vector2i(rx, rz);

			int region_start_x = rx * _region_size;
			int region_start_z = rz * _region_size;
			int region_end_x = region_start_x + _region_size - 1;
			int region_end_z = region_start_z + _region_size - 1;

			int overlap_start_x = MAX(region_start_x, img_start_x);
			int overlap_start_z = MAX(region_start_z, img_start_z);
			int overlap_end_x = MIN(region_end_x, img_end_x);
			int overlap_end_z = MIN(region_end_z, img_end_z);

			// Skip if no overlap
			if (overlap_end_x < overlap_start_x || overlap_end_z < overlap_start_z) {
				continue;
			}

			int copy_width = overlap_end_x - overlap_start_x + 1;
			int copy_height = overlap_end_z - overlap_start_z + 1;

			int src_x = overlap_start_x - img_start_x;
			int src_z = overlap_start_z - img_start_z;
			int dst_x = overlap_start_x - region_start_x;
			int dst_z = overlap_start_z - region_start_z;

			LOG(DEBUG, "Region ", region_loc, ": copying ", Vector2i(copy_width, copy_height),
					" from img(", src_x, ",", src_z, ") to region(", dst_x, ",", dst_z, ")");

			Ref<Pasture3DRegion> region = get_region(region_loc);
			if (region.is_null()) {
				region.instantiate();
				region->set_location(region_loc);
				region->set_region_size(_region_size);
				region->set_vertex_spacing(_vertex_spacing);
				add_region(region, false);
			} else if (region->is_deleted()) {
				region->clear();
				region->set_location(region_loc);
				region->set_region_size(_region_size);
				region->set_vertex_spacing(_vertex_spacing);
			}
			for (int i = 0; i < TYPE_MAX; i++) {
				Ref<Image> img = src_images[i];
				if (img.is_valid() && !img->is_empty()) {
					Ref<Image> region_map;

					Ref<Image> existing_map = region->get_map(static_cast<MapType>(i));
					if (existing_map.is_valid() && !existing_map->is_empty()) {
						region_map.instantiate();
						region_map->copy_from(existing_map);
						if (region_map->get_format() != img->get_format()) {
							region_map->convert(img->get_format());
						}
					} else {
						region_map = Util::get_filled_image(_region_sizev, COLOR[i], false, img->get_format());
					}
					region_map->blit_rect(img, Rect2i(src_x, src_z, copy_width, copy_height), Vector2i(dst_x, dst_z));
					region->set_map(static_cast<MapType>(i), region_map);
					if (i == TYPE_COLOR) {
						generate_mipmaps = true;
					}
				}
			}
			region->set_modified(true);
			region->sanitize_maps();
		}
	}
	update_maps(TYPE_MAX, true, generate_mipmaps);
}

/** Exports a specified map as one of r16/raw, exr, jpg, png, webp, res, tres
 * r16 or exr are recommended for roundtrip external editing
 * r16 can be edited by Krita, however you must know the dimensions and min/max before reimporting
 * res/tres stores in Godot's native format.
 */
Error Pasture3DData::export_image(const String &p_file_name, const MapType p_map_type, const ExportMode p_mode) const {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Invalid map type specified: ", p_map_type, " max: ", TYPE_MAX - 1);
		return FAILED;
	}
	if (p_file_name.is_empty()) {
		LOG(ERROR, "No file specified. Nothing to export");
		return FAILED;
	}
	if (get_region_count() == 0) {
		LOG(ERROR, "No valid regions. Nothing to export");
		return FAILED;
	}

	// Simple file name validation
	static const String bad_chars = "?*|%<>\"";
	for (int i = 0; i < bad_chars.length(); ++i) {
		for (int j = 0; j < p_file_name.length(); ++j) {
			if (bad_chars[i] == p_file_name[j]) {
				LOG(ERROR, "Invalid file path '" + p_file_name + "'");
				return FAILED;
			}
		}
	}

	// Update path delimiter
	String file_name = p_file_name.replace("\\", "/");

	// Check if p_file_name has a path and prepend "res://" if not
	bool is_simple_filename = true;
	for (int i = 0; i < file_name.length(); ++i) {
		char32_t c = file_name[i];
		if (c == '/' || c == ':') {
			is_simple_filename = false;
			break;
		}
	}
	if (is_simple_filename) {
		file_name = "res://" + file_name;
	}

	String base_path = file_name.get_basename();
	String ext = file_name.get_extension().to_lower();

	// Validate extension BEFORE touching the disk. Upstream probes for writability first, which
	// creates the file, so a rejected extension left an empty one behind.
	if (ext != "r16" && ext != "raw" && ext != "exr" && ext != "png" &&
			ext != "jpg" && ext != "webp" && ext != "res" && ext != "tres") {
		LOG(ERROR, "No recognized file type. See docs for valid extensions");
		return FAILED;
	}

	// Check the destination is writable before generating any images, which is the expensive part.
	// The probe creates the file, and neither mode below necessarily writes to that exact name --
	// per-region and multi-chunk output are both suffixed -- so remove it rather than leave a
	// zero-byte file next to the real output.
	{
		Ref<FileAccess> file_ref = FileAccess::open(file_name, FileAccess::ModeFlags::WRITE);
		if (file_ref.is_null()) {
			LOG(ERROR, "Cannot open file '" + file_name + "' for writing");
			return FAILED;
		}
		file_ref->close();
		DirAccess::remove_absolute(file_name);
	}

	const Rect2i terrain_rect = _region_bounds_px();
	if (!terrain_rect.has_area()) {
		LOG(ERROR, "No active regions. Nothing to export");
		return FAILED;
	}
	const Vector2i terrain_origin = terrain_rect.position;
	const Vector2i terrain_size = terrain_rect.size;

	LOG(MESG, "=== Pasture3D Export ===");
	LOG(MESG, "Map type: ", TYPESTR[p_map_type]);
	LOG(MESG, "Total size: ", terrain_size, " px");
	LOG(MESG, "Origin: ", terrain_origin, " px, ", Vector2(terrain_origin) * _vertex_spacing, " world");

	int files_exported = 0;
	Error last_error = OK;

	if (p_mode == EXPORT_PER_REGION) {
		LOG(MESG, "Mode: Per-Region (", _region_locations.size(), " regions)");
		LOG(MESG, "");

		for (const Vector2i &region_loc : _region_locations) {
			const Pasture3DRegion *region = get_region_ptr(region_loc);
			if (!region || region->is_deleted()) {
				continue;
			}

			String path = base_path + Util::location_to_string(region_loc) + "." + ext;
			Ref<Image> img = region->get_map(p_map_type);
			if (img.is_null() || img->is_empty()) {
				continue;
			}

			Vector2i pos_px = region_loc * _region_size;
			LOG(MESG, "Exporting: ", path);
			LOG(MESG, "  Size: ", img->get_size(), " px");
			LOG(MESG, "  Position: ", pos_px, " px, ", Vector2(pos_px) * _vertex_spacing, " world");

			Error err = _save_export_image(img, path, ext, p_map_type);
			if (err != OK) {
				last_error = err;
			} else {
				files_exported++;
			}
		}
	} else { // EXPORT_SLICED
		const int MAX_SIZE = 16384;
		int chunks_x = (terrain_size.x + MAX_SIZE - 1) / MAX_SIZE;
		int chunks_y = (terrain_size.y + MAX_SIZE - 1) / MAX_SIZE;

		LOG(MESG, "Mode: Sliced (", chunks_x, " x ", chunks_y, " chunks, max ", MAX_SIZE, " px)");
		LOG(MESG, "");

		for (int cy = 0; cy < chunks_y; cy++) {
			for (int cx = 0; cx < chunks_x; cx++) {
				Vector2i chunk_origin = terrain_origin + Vector2i(cx * MAX_SIZE, cy * MAX_SIZE);
				Vector2i chunk_size;
				chunk_size.x = MIN(MAX_SIZE, terrain_origin.x + terrain_size.x - chunk_origin.x);
				chunk_size.y = MIN(MAX_SIZE, terrain_origin.y + terrain_size.y - chunk_origin.y);

				Ref<Image> img = layered_to_image(p_map_type, Rect2i(chunk_origin, chunk_size));
				if (img.is_null() || img->is_empty()) {
					continue;
				}

				String suffix = (chunks_x == 1 && chunks_y == 1) ? "" : vformat("_%02d_%02d", cx, cy);
				String path = base_path + suffix + "." + ext;

				LOG(MESG, "Exporting: ", path);
				LOG(MESG, "  Size: ", img->get_size(), " px");
				LOG(MESG, "  Position: ", chunk_origin, " px, ", Vector2(chunk_origin) * _vertex_spacing, " world");

				Error err = _save_export_image(img, path, ext, p_map_type);
				if (err != OK) {
					last_error = err;
				} else {
					files_exported++;
				}
			}
		}
	}

	LOG(MESG, "");
	LOG(MESG, "=== Export complete: ", files_exported, " file(s) ===");
	return last_error;
}

Error Pasture3DData::_save_export_image(const Ref<Image> &p_img, const String &p_path,
		const String &p_ext, const MapType p_map_type) const {
	if (p_ext == "r16" || p_ext == "raw") {
		Ref<FileAccess> file = FileAccess::open(p_path, FileAccess::WRITE);
		if (file.is_null()) {
			return ERR_CANT_OPEN;
		}
		Vector2 minmax = Util::get_min_max(p_img);
		real_t height_min = minmax.x;
		real_t height_max = minmax.y;
		real_t hscale = 65535.0 / (height_max - height_min);
		for (int y = 0; y < p_img->get_height(); y++) {
			for (int x = 0; x < p_img->get_width(); x++) {
				int h = int((p_img->get_pixel(x, y).r - height_min) * hscale);
				h = CLAMP(h, 0, 65535);
				file->store_16(h);
			}
		}
		LOG(MESG, "  Height range: ", height_min, " to ", height_max);
		return file->get_error();
	} else if (p_ext == "exr") {
		return p_img->save_exr(p_path, (p_map_type == TYPE_HEIGHT));
	} else if (p_ext == "png") {
		return p_img->save_png(p_path);
	} else if (p_ext == "jpg") {
		return p_img->save_jpg(p_path);
	} else if (p_ext == "webp") {
		return p_img->save_webp(p_path);
	} else if (p_ext == "res" || p_ext == "tres") {
		return ResourceSaver::get_singleton()->save(p_img, p_path, ResourceSaver::FLAG_COMPRESS);
	}
	return ERR_FILE_UNRECOGNIZED;
}

// Exact pixel rect covering every active region. Empty when there are none.
//
// This used to be written inline, twice, and both copies were wrong the same two ways: the corners
// were seeded at (0,0) rather than at a region, and the min/max tests were chained with `else if`
// so a single region could only move one corner. Together those pinned the box to always contain
// the world origin. It never cropped -- the result always enclosed the true extent -- so the only
// symptom was inflation, and on the demo terrain (regions at (0,0), (0,-1), (0,-2), which really do
// straddle the origin) the wrong answer and the right one are identical. That is why it survived.
//
// The inflation was not free. Slicing is measured from this origin, so a terrain sitting far from
// (0,0) got split into several suffixed files where one unsuffixed file was correct; and the r16
// writer derives its 16-bit scale from the min/max of each tile, so the background fill padding the
// extra area dragged the height range down and cost real precision in the exported file.
//
// Deleted regions are excluded. _region_locations is normally kept clear of them -- remove_region()
// drops the entry as it sets the flag -- but set_region_deleted() is bound to GDScript and sets the
// flag alone, without touching the array or dirtying the region map. So a deleted region can sit in
// _region_locations indefinitely, and the callers of this already skip those.
Rect2i Pasture3DData::_region_bounds_px() const {
	bool found = false;
	Vector2i top_left;
	Vector2i bottom_right;
	for (const Vector2i &region_loc : _region_locations) {
		const Pasture3DRegion *region = get_region_ptr(region_loc);
		if (!region || region->is_deleted()) {
			continue;
		}
		if (!found) {
			top_left = region_loc;
			bottom_right = region_loc;
			found = true;
			continue;
		}
		top_left.x = MIN(top_left.x, region_loc.x);
		top_left.y = MIN(top_left.y, region_loc.y);
		bottom_right.x = MAX(bottom_right.x, region_loc.x);
		bottom_right.y = MAX(bottom_right.y, region_loc.y);
	}
	if (!found) {
		return Rect2i();
	}
	return Rect2i(top_left * _region_size,
			(bottom_right - top_left + Vector2i(1, 1)) * _region_size);
}

Ref<Image> Pasture3DData::layered_to_image(const MapType p_map_type, const Rect2i &p_bounds) const {
	LOG(INFO, "Generating a full sized image for all regions including empty regions");
	MapType map_type = p_map_type;
	if (map_type >= TYPE_MAX) {
		map_type = TYPE_HEIGHT;
	}
	const Rect2i terrain_rect = _region_bounds_px();
	if (!terrain_rect.has_area()) {
		LOG(ERROR, "No active regions to build an image from");
		return Ref<Image>();
	}
	LOG(DEBUG, "Full range to cover all regions: ", terrain_rect);

	Rect2i export_rect = p_bounds.has_area() ? p_bounds.intersection(terrain_rect) : terrain_rect;
	if (!export_rect.has_area()) {
		LOG(ERROR, "Export bounds don't intersect terrain");
		return Ref<Image>();
	}

	LOG(DEBUG, "Export rect: ", export_rect);
	Ref<Image> img = Util::get_filled_image(export_rect.size, COLOR[map_type], false, FORMAT[map_type]);

	for (const Vector2i &region_loc : _region_locations) {
		const Pasture3DRegion *region = get_region_ptr(region_loc);
		// Deleted regions are outside the bounds this image was sized to, so blitting one would
		// draw a region the export deliberately excluded.
		if (!region || region->is_deleted()) {
			continue;
		}
		Rect2i region_rect(region_loc * _region_size, _region_sizev);
		Rect2i overlap = region_rect.intersection(export_rect);
		if (!overlap.has_area()) {
			continue;
		}
		Rect2i src_rect(overlap.position - region_rect.position, overlap.size);
		Vector2i dst_pos = overlap.position - export_rect.position;
		LOG(DEBUG, "Region ", region_loc, ": src=", src_rect, " dst=", dst_pos);
		img->blit_rect(region->get_map(map_type), src_rect, dst_pos);
	}
	return img;
}

void Pasture3DData::dump(const bool verbose) const {
	LOG(MESG, "_region_locations (", _region_locations.size(), "): ", _region_locations);
	Array keys = _regions.keys();
	LOG(MESG, "_regions (", keys.size(), "):");
	for (const Vector2i &region_loc : keys) {
		const Pasture3DRegion *region = get_region_ptr(region_loc);
		if (!region) {
			LOG(WARN, "No region found at: ", region_loc);
			continue;
		}
		region->dump(verbose);
	}
	if (verbose) {
		for (int i = 0; i < _region_map.size(); i++) {
			if (_region_map[i]) {
				LOG(MESG, "Region map array index: ", i, " / ", _region_map.size() - 1, ", Region id: ", _region_map[i]);
			}
		}
		Util::dump_maps(_height_maps, "Height maps");
		Util::dump_gentex(_generated_height_maps, "height");
		Util::dump_maps(_control_maps, "Control maps");
		Util::dump_gentex(_generated_control_maps, "control");
		Util::dump_maps(_color_maps, "Color maps");
		Util::dump_gentex(_generated_color_maps, "color");
	}
}

///////////////////////////
// Protected Functions
///////////////////////////

void Pasture3DData::_bind_methods() {
	BIND_ENUM_CONSTANT(HEIGHT_FILTER_NEAREST);
	BIND_ENUM_CONSTANT(HEIGHT_FILTER_MINIMUM);

	BIND_ENUM_CONSTANT(EXPORT_SLICED);
	BIND_ENUM_CONSTANT(EXPORT_PER_REGION);

	BIND_CONSTANT(REGION_MAP_SIZE);

	ClassDB::bind_method(D_METHOD("get_region_count"), &Pasture3DData::get_region_count);
	ClassDB::bind_method(D_METHOD("set_region_locations", "region_locations"), &Pasture3DData::set_region_locations);
	ClassDB::bind_method(D_METHOD("get_region_locations"), &Pasture3DData::get_region_locations);
	ClassDB::bind_method(D_METHOD("get_regions_active", "copy", "deep"), &Pasture3DData::get_regions_active, DEFVAL(false), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("get_regions_all"), &Pasture3DData::get_regions_all);
	ClassDB::bind_method(D_METHOD("get_region_map"), &Pasture3DData::get_region_map);
	ClassDB::bind_static_method("Pasture3DData", D_METHOD("get_region_map_index", "region_location"), &Pasture3DData::get_region_map_index);

	ClassDB::bind_method(D_METHOD("do_for_regions", "area", "callback"), &Pasture3DData::do_for_regions);
	ClassDB::bind_method(D_METHOD("change_region_size", "region_size"), &Pasture3DData::change_region_size);

	ClassDB::bind_method(D_METHOD("get_region_location", "global_position"), &Pasture3DData::get_region_location);
	ClassDB::bind_method(D_METHOD("get_region_id", "region_location"), &Pasture3DData::get_region_id);
	ClassDB::bind_method(D_METHOD("get_region_idp", "global_position"), &Pasture3DData::get_region_idp);

	ClassDB::bind_method(D_METHOD("has_region", "region_location"), &Pasture3DData::has_region);
	ClassDB::bind_method(D_METHOD("has_regionp", "global_position"), &Pasture3DData::has_regionp);
	ClassDB::bind_method(D_METHOD("get_region", "region_location"), &Pasture3DData::get_region);
	ClassDB::bind_method(D_METHOD("get_regionp", "global_position"), &Pasture3DData::get_regionp);

	ClassDB::bind_method(D_METHOD("set_region_modified", "region_location", "modified"), &Pasture3DData::set_region_modified);
	ClassDB::bind_method(D_METHOD("is_region_modified", "region_location"), &Pasture3DData::is_region_modified);
	ClassDB::bind_method(D_METHOD("set_region_deleted", "region_location", "deleted"), &Pasture3DData::set_region_deleted);
	ClassDB::bind_method(D_METHOD("is_region_deleted", "region_location"), &Pasture3DData::is_region_deleted);

	ClassDB::bind_method(D_METHOD("add_region_blankp", "global_position", "update"), &Pasture3DData::add_region_blankp, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_region_blank", "region_location", "update"), &Pasture3DData::add_region_blank, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_region", "region", "update"), &Pasture3DData::add_region, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("remove_regionp", "global_position", "update"), &Pasture3DData::remove_regionp, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("remove_regionl", "region_location", "update"), &Pasture3DData::remove_regionl, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("remove_region", "region", "update"), &Pasture3DData::remove_region, DEFVAL(true));

	ClassDB::bind_method(D_METHOD("has_layer_stack"), &Pasture3DData::has_layer_stack);
	ClassDB::bind_method(D_METHOD("get_layer_stack"), &Pasture3DData::get_layer_stack);
	ClassDB::bind_method(D_METHOD("set_layer_stack", "layer_stack"), &Pasture3DData::set_layer_stack);
	ClassDB::bind_method(D_METHOD("composite_region", "region_location", "dirty_rect", "update"), &Pasture3DData::composite_region, DEFVAL(Rect2i()), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("composite_regions"), &Pasture3DData::composite_regions);
	ClassDB::bind_method(D_METHOD("composite_area", "area", "update"), &Pasture3DData::composite_area, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("composite_height_below", "below_layer_id", "min_x", "min_z", "vs", "gw", "gh"), &Pasture3DData::composite_height_below);
	ClassDB::bind_method(D_METHOD("get_height_below", "below_layer_id", "global_position"), &Pasture3DData::get_height_below);
	ClassDB::bind_method(D_METHOD("get_height_below_point", "below_layer_id", "region_location", "image_position"), &Pasture3DData::get_height_below_point);

	ClassDB::bind_method(D_METHOD("is_layer_routing"), &Pasture3DData::is_layer_routing);
	ClassDB::bind_method(D_METHOD("ensure_layer_stack"), &Pasture3DData::ensure_layer_stack);
	ClassDB::bind_method(D_METHOD("layer_add", "name", "blend_mode"), &Pasture3DData::layer_add);
	ClassDB::bind_method(D_METHOD("layer_duplicate", "index"), &Pasture3DData::layer_duplicate);
	ClassDB::bind_method(D_METHOD("layer_remove", "index"), &Pasture3DData::layer_remove);
	ClassDB::bind_method(D_METHOD("layer_move", "from", "to"), &Pasture3DData::layer_move);
	ClassDB::bind_method(D_METHOD("recomposite_layer", "index"), &Pasture3DData::recomposite_layer);

	// Tool API (PASTURE3D_LAYERS_GUIDE.md §8) — for generator nodes like RoadPastureConnector.
	ClassDB::bind_method(D_METHOD("get_layer_stack_size"), &Pasture3DData::get_layer_stack_size);
	ClassDB::bind_method(D_METHOD("find_layer_by_owner", "owner_id"), &Pasture3DData::find_layer_by_owner);
	ClassDB::bind_method(D_METHOD("create_owned_layer", "owner_id", "name", "blend_mode"), &Pasture3DData::create_owned_layer);
	ClassDB::bind_method(D_METHOD("create_owned_layer_typed", "owner_id", "name", "blend_mode", "map_type"), &Pasture3DData::create_owned_layer_typed);
	ClassDB::bind_method(D_METHOD("set_height_on_layer", "layer_id", "global_position", "height", "weight", "composite"), &Pasture3DData::set_height_on_layer, DEFVAL(1.f), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("set_control_on_layer", "layer_id", "global_position", "control", "weight", "composite"), &Pasture3DData::set_control_on_layer, DEFVAL(1.f), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("set_hole_on_layer", "layer_id", "global_position", "hole"), &Pasture3DData::set_hole_on_layer);
	ClassDB::bind_method(D_METHOD("set_color_on_layer", "layer_id", "global_position", "color", "weight", "composite"), &Pasture3DData::set_color_on_layer, DEFVAL(1.f), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_height_on_layer", "layer_id", "global_position", "delta", "weight", "composite"), &Pasture3DData::add_height_on_layer, DEFVAL(1.f), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("get_layer_height", "layer_id", "global_position"), &Pasture3DData::get_layer_height);
	ClassDB::bind_method(D_METHOD("clear_layer_in_area", "layer_id", "area", "composite"), &Pasture3DData::clear_layer_in_area, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("stamp_mound_loop", "layer_id", "poly", "clip", "params", "lut"), &Pasture3DData::stamp_mound_loop);
	ClassDB::bind_method(D_METHOD("stamp_ridge_line", "layer_id", "pts", "clip", "params", "lut"), &Pasture3DData::stamp_ridge_line);
	ClassDB::bind_method(D_METHOD("stamp_trough_line", "layer_id", "pts", "clip", "params", "lut"), &Pasture3DData::stamp_trough_line);
	ClassDB::bind_method(D_METHOD("stamp_road_line", "layer_id", "plan", "clip", "params"), &Pasture3DData::stamp_road_line);
	ClassDB::bind_method(D_METHOD("get_height_below_along_plan", "layer_id", "plan", "cum", "ds", "n_s"), &Pasture3DData::get_height_below_along_plan);
	ClassDB::bind_method(D_METHOD("stamp_road_surface_control", "layer_id", "surface", "gw", "gh", "min_x", "min_z", "vs", "texture_id", "preserve_base", "min_coverage"), &Pasture3DData::stamp_road_surface_control, DEFVAL(true), DEFVAL(0.004));
	ClassDB::bind_method(D_METHOD("stamp_plow_loop", "layer_id", "poly", "clip", "params", "lut", "src_data"), &Pasture3DData::stamp_plow_loop);
	ClassDB::bind_method(D_METHOD("stamp_splat_loop", "layer_id", "poly", "clip", "params", "lut"), &Pasture3DData::stamp_splat_loop);
	ClassDB::bind_method(D_METHOD("gpu_raster_available"), &Pasture3DData::gpu_raster_available);
	// Pasture3DSim (PASTURE3D_SIM_NODE_SPEC.md §4, §6, §8.1).
	ClassDB::bind_method(D_METHOD("erode_heightfield", "z", "params", "erodability"), &Pasture3DData::erode_heightfield, DEFVAL(PackedFloat32Array()));
	ClassDB::bind_method(D_METHOD("erosion_progress"), &Pasture3DData::erosion_progress);
	ClassDB::bind_method(D_METHOD("resample_grid", "src", "sw", "sh", "dw", "dh"), &Pasture3DData::resample_grid);
	ClassDB::bind_method(D_METHOD("selector_mask_field", "z", "params", "selectors", "sim_result"), &Pasture3DData::selector_mask_field, DEFVAL(Dictionary()));
	ClassDB::bind_method(D_METHOD("sim_mask_deltas", "deltas", "poly", "params", "lut"), &Pasture3DData::sim_mask_deltas);
	ClassDB::bind_method(D_METHOD("sim_chain_blend", "before", "after", "gate"), &Pasture3DData::sim_chain_blend);
	ClassDB::bind_method(D_METHOD("sim_chain_write", "z0", "zn", "params"), &Pasture3DData::sim_chain_write);
	ClassDB::bind_method(D_METHOD("sim_pass_accumulate", "acc", "before", "after", "gate"), &Pasture3DData::sim_pass_accumulate);
	ClassDB::bind_method(D_METHOD("sim_pass_commit", "before", "acc"), &Pasture3DData::sim_pass_commit);
	ClassDB::bind_method(D_METHOD("apply_sim_block", "layer_id", "min_x", "min_z", "vs", "gw", "gh", "deltas", "blend"), &Pasture3DData::apply_sim_block);
	ClassDB::bind_method(D_METHOD("sim_result_build", "parts", "target"), &Pasture3DData::sim_result_build);
	ClassDB::bind_method(D_METHOD("sim_extract_water", "z", "params"), &Pasture3DData::sim_extract_water);
	ClassDB::bind_method(D_METHOD("gc_layer", "layer_id"), &Pasture3DData::gc_layer);
	ClassDB::bind_method(D_METHOD("set_active_layer", "layer_id"), &Pasture3DData::set_active_layer);
	ClassDB::bind_method(D_METHOD("get_active_layer"), &Pasture3DData::get_active_layer);

	ClassDB::bind_method(D_METHOD("save_directory", "directory"), &Pasture3DData::save_directory);
	ClassDB::bind_method(D_METHOD("save_region", "region_location", "directory", "save_16_bit"), &Pasture3DData::save_region, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("load_directory", "directory"), &Pasture3DData::load_directory);
	ClassDB::bind_method(D_METHOD("load_region", "region_location", "directory", "update"), &Pasture3DData::load_region, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("save_layers", "directory"), &Pasture3DData::save_layers);
	ClassDB::bind_method(D_METHOD("load_layers", "directory"), &Pasture3DData::load_layers);

	ClassDB::bind_method(D_METHOD("get_height_maps"), &Pasture3DData::get_height_maps);
	ClassDB::bind_method(D_METHOD("get_control_maps"), &Pasture3DData::get_control_maps);
	ClassDB::bind_method(D_METHOD("get_color_maps"), &Pasture3DData::get_color_maps);
	ClassDB::bind_method(D_METHOD("get_maps", "map_type"), &Pasture3DData::get_maps);
	ClassDB::bind_method(D_METHOD("update_maps", "map_type", "all_regions", "generate_mipmaps"), &Pasture3DData::update_maps, DEFVAL(TYPE_MAX), DEFVAL(true), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("get_height_maps_rid"), &Pasture3DData::get_height_maps_rid);
	ClassDB::bind_method(D_METHOD("get_control_maps_rid"), &Pasture3DData::get_control_maps_rid);
	ClassDB::bind_method(D_METHOD("get_color_maps_rid"), &Pasture3DData::get_color_maps_rid);

	ClassDB::bind_method(D_METHOD("set_pixel", "map_type", "global_position", "pixel"), &Pasture3DData::set_pixel);
	ClassDB::bind_method(D_METHOD("get_pixel", "map_type", "global_position"), &Pasture3DData::get_pixel);
	ClassDB::bind_method(D_METHOD("set_height", "global_position", "height"), &Pasture3DData::set_height);
	ClassDB::bind_method(D_METHOD("get_height", "global_position"), &Pasture3DData::get_height);
	ClassDB::bind_method(D_METHOD("set_color", "global_position", "color"), &Pasture3DData::set_color);
	ClassDB::bind_method(D_METHOD("get_color", "global_position"), &Pasture3DData::get_color);
	ClassDB::bind_method(D_METHOD("set_control", "global_position", "control"), &Pasture3DData::set_control);
	ClassDB::bind_method(D_METHOD("get_control", "global_position"), &Pasture3DData::get_control);
	ClassDB::bind_method(D_METHOD("set_roughness", "global_position", "roughness"), &Pasture3DData::set_roughness);
	ClassDB::bind_method(D_METHOD("get_roughness", "global_position"), &Pasture3DData::get_roughness);

	ClassDB::bind_method(D_METHOD("set_control_base_id", "global_position", "texture_id"), &Pasture3DData::set_control_base_id);
	ClassDB::bind_method(D_METHOD("get_control_base_id", "global_position"), &Pasture3DData::get_control_base_id);
	ClassDB::bind_method(D_METHOD("set_control_overlay_id", "global_position", "texture_id"), &Pasture3DData::set_control_overlay_id);
	ClassDB::bind_method(D_METHOD("get_control_overlay_id", "global_position"), &Pasture3DData::get_control_overlay_id);
	ClassDB::bind_method(D_METHOD("set_control_blend", "global_position", "blend_value"), &Pasture3DData::set_control_blend);
	ClassDB::bind_method(D_METHOD("get_control_blend", "global_position"), &Pasture3DData::get_control_blend);
	ClassDB::bind_method(D_METHOD("set_control_angle", "global_position", "degrees"), &Pasture3DData::set_control_angle);
	ClassDB::bind_method(D_METHOD("get_control_angle", "global_position"), &Pasture3DData::get_control_angle);
	ClassDB::bind_method(D_METHOD("set_control_scale", "global_position", "percentage_modifier"), &Pasture3DData::set_control_scale);
	ClassDB::bind_method(D_METHOD("get_control_scale", "global_position"), &Pasture3DData::get_control_scale);
	ClassDB::bind_method(D_METHOD("set_control_hole", "global_position", "enable"), &Pasture3DData::set_control_hole);
	ClassDB::bind_method(D_METHOD("get_control_hole", "global_position"), &Pasture3DData::get_control_hole);
	ClassDB::bind_method(D_METHOD("set_control_navigation", "global_position", "enable"), &Pasture3DData::set_control_navigation);
	ClassDB::bind_method(D_METHOD("get_control_navigation", "global_position"), &Pasture3DData::get_control_navigation);
	ClassDB::bind_method(D_METHOD("set_control_auto", "global_position", "enable"), &Pasture3DData::set_control_auto);
	ClassDB::bind_method(D_METHOD("get_control_auto", "global_position"), &Pasture3DData::get_control_auto);

	ClassDB::bind_method(D_METHOD("get_normal", "global_position"), &Pasture3DData::get_normal);
	ClassDB::bind_method(D_METHOD("is_in_slope", "global_position", "slope_range", "normal"), &Pasture3DData::is_in_slope, DEFVAL(V3_ZERO));
	ClassDB::bind_method(D_METHOD("get_texture_id", "global_position"), &Pasture3DData::get_texture_id);
	ClassDB::bind_method(D_METHOD("get_mesh_vertex", "lod", "filter", "global_position"), &Pasture3DData::get_mesh_vertex);

	ClassDB::bind_method(D_METHOD("get_height_range"), &Pasture3DData::get_height_range);
	ClassDB::bind_method(D_METHOD("calc_height_range", "recursive"), &Pasture3DData::calc_height_range, DEFVAL(false));

	ClassDB::bind_method(D_METHOD("import_images", "images", "global_position", "offset", "scale"), &Pasture3DData::import_images, DEFVAL(V3_ZERO), DEFVAL(0.f), DEFVAL(1.f));
	ClassDB::bind_method(D_METHOD("export_image", "file_name", "map_type", "mode"), &Pasture3DData::export_image, DEFVAL(TYPE_HEIGHT), DEFVAL(EXPORT_SLICED));
	ClassDB::bind_method(D_METHOD("layered_to_image", "map_type", "bounds"), &Pasture3DData::layered_to_image, DEFVAL(Rect2i()));
	ClassDB::bind_method(D_METHOD("dump", "verbose"), &Pasture3DData::dump, DEFVAL(false));

	int ro_flags = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY;
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "region_locations", PROPERTY_HINT_ARRAY_TYPE, "Vector2i", ro_flags), "set_region_locations", "get_region_locations");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "height_maps", PROPERTY_HINT_ARRAY_TYPE, "Image", ro_flags), "", "get_height_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "control_maps", PROPERTY_HINT_ARRAY_TYPE, "Image", ro_flags), "", "get_control_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "color_maps", PROPERTY_HINT_ARRAY_TYPE, "Image", ro_flags), "", "get_color_maps");

	ADD_SIGNAL(MethodInfo("maps_changed"));
	ADD_SIGNAL(MethodInfo("region_map_changed"));
	ADD_SIGNAL(MethodInfo("height_maps_changed"));
	ADD_SIGNAL(MethodInfo("control_maps_changed"));
	ADD_SIGNAL(MethodInfo("color_maps_changed"));
	ADD_SIGNAL(MethodInfo("maps_edited", PropertyInfo(Variant::AABB, "edited_area")));
	ADD_SIGNAL(MethodInfo("layers_changed"));
}
