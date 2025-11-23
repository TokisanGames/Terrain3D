// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/editor_file_system.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/resource_saver.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rect2i.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include "logger.h"
#include "terrain_3d_data.h"

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3DData::_clear() {
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
	_next_layer_group_id = 1;
}

// Structured to work with do_for_regions. Should be renamed when copy_paste is expanded
void Terrain3DData::_copy_paste_dfr(const Terrain3DRegion *p_src_region, const Rect2i &p_src_rect, const Rect2i &p_dst_rect, const Terrain3DRegion *p_dst_region) {
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
	_terrain->get_instancer()->copy_paste_dfr(p_src_region, p_src_rect, p_dst_region);
}

bool Terrain3DData::_find_layer_owner(const Ref<Terrain3DLayer> &p_layer, const MapType p_map_type, Terrain3DRegion **r_region, Vector2i *r_region_loc, int *r_index) const {
	if (p_layer.is_null()) {
		return false;
	}
	Array keys = _regions.keys();
	for (int i = 0; i < keys.size(); i++) {
		Vector2i region_loc = keys[i];
		Terrain3DRegion *region = get_region_ptr(region_loc);
		if (!region) {
			continue;
		}
		TypedArray<Terrain3DLayer> layers = region->get_layers(p_map_type);
		for (int j = 0; j < layers.size(); j++) {
			Ref<Terrain3DLayer> candidate = layers[j];
			if (candidate == p_layer) {
				if (r_region) {
					*r_region = region;
				}
				if (r_region_loc) {
					*r_region_loc = region_loc;
				}
				if (r_index) {
					*r_index = j;
				}
				return true;
			}
		}
	}
	return false;
}

uint64_t Terrain3DData::_allocate_layer_group_id() {
	return _next_layer_group_id++;
}

uint64_t Terrain3DData::_ensure_layer_group_id_internal(const Ref<Terrain3DLayer> &p_layer) {
	if (p_layer.is_null()) {
		return 0;
	}
	uint64_t group_id = p_layer->get_group_id();
	if (group_id == 0) {
		group_id = _allocate_layer_group_id();
		p_layer->set_group_id(group_id);
	} else if (group_id >= _next_layer_group_id) {
		_next_layer_group_id = group_id + 1;
	}
	return group_id;
}

void Terrain3DData::_ensure_region_layer_groups(const Ref<Terrain3DRegion> &p_region) {
	if (p_region.is_null()) {
		return;
	}
	for (int map_type = TYPE_HEIGHT; map_type < TYPE_MAX; map_type++) {
		TypedArray<Terrain3DLayer> layers = p_region->get_layers(MapType(map_type));
		for (int i = 0; i < layers.size(); i++) {
			_ensure_layer_group_id_internal(layers[i]);
		}
	}
}

uint64_t Terrain3DData::ensure_layer_group_id(const Ref<Terrain3DLayer> &p_layer) {
	return _ensure_layer_group_id_internal(p_layer);
}

Ref<Terrain3DLayer> Terrain3DData::_duplicate_layer_template(const Ref<Terrain3DLayer> &p_template) const {
	if (p_template.is_null()) {
		return Ref<Terrain3DLayer>();
	}
	Ref<Terrain3DLayer> clone = p_template->duplicate(true);
	if (clone.is_null()) {
		return Ref<Terrain3DLayer>();
	}
	clone->set_payload(Ref<Image>());
	clone->set_alpha(Ref<Image>());
	clone->set_coverage(Rect2i());
	clone->mark_dirty();
	clone->set_map_type(p_template->get_map_type());
	clone->set_group_id(p_template->get_group_id());
	clone->set_enabled(p_template->is_enabled());
	clone->set_intensity(p_template->get_intensity());
	clone->set_feather_radius(p_template->get_feather_radius());
	clone->set_blend_mode(p_template->get_blend_mode());
	return clone;
}

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DData::initialize(Terrain3D *p_terrain) {
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
}

void Terrain3DData::set_region_locations(const TypedArray<Vector2i> &p_locations) {
	SET_IF_DIFF(_region_locations, p_locations);
	LOG(INFO, "Setting _region_locations with array sized: ", p_locations.size());
	_region_map_dirty = true;
	update_maps(TYPE_MAX, false, false); // only rebuild region map
}

// Returns an array of active regions, optionally a shallow or deep copy
TypedArray<Terrain3DRegion> Terrain3DData::get_regions_active(const bool p_copy, const bool p_deep) const {
	TypedArray<Terrain3DRegion> region_arr;
	for (const Vector2i &region_loc : _region_locations) {
		Ref<Terrain3DRegion> region = get_region(region_loc);
		if (region.is_valid()) {
			region_arr.push_back(p_copy ? region->duplicate(p_deep) : region);
		}
	}
	return region_arr;
}

// Calls the callback function for every region within the given (descaled) area
// The callable receives: source Terrain3DRegion, source Rect2i, dest Rect2i, (bindings)
// Used with change_region_size, dest Terrain3DRegion is bound as the 4th parameter
void Terrain3DData::do_for_regions(const Rect2i &p_area, const Callable &p_callback) {
	Rect2i location_bounds(V2I_DIVIDE_FLOOR(p_area.position, _region_size), V2I_DIVIDE_CEIL(p_area.size, _region_size));
	LOG(DEBUG, "Processing global area: ", p_area, " -> ", location_bounds);
	Point2i current_region_loc;
	for (int y = location_bounds.position.y; y < location_bounds.get_end().y; y++) {
		current_region_loc.y = y;
		for (int x = location_bounds.position.x; x < location_bounds.get_end().x; x++) {
			current_region_loc.x = x;
			const Terrain3DRegion *region = get_region_ptr(current_region_loc);
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

void Terrain3DData::change_region_size(int p_new_size) {
	LOG(INFO, "Changing region size from: ", _region_size, " to ", p_new_size);
	if (!is_valid_region_size(p_new_size)) {
		LOG(ERROR, "Invalid region size: ", p_new_size, ". Must be power of 2, 64-2048");
		return;
	}
	if (p_new_size == _region_size) {
		return;
	}

	// Get current region corners expressed in new region_size coordinates
	Dictionary new_region_locations;
	Array region_locations = _regions.keys();
	for (const Vector2i &region_loc : region_locations) {
		const Terrain3DRegion *region = get_region_ptr(region_loc);
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
	TypedArray<Terrain3DRegion> new_regions;
	Array new_locations = new_region_locations.keys();
	for (const Vector2i &region_loc : new_locations) {
		Ref<Terrain3DRegion> new_region;
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
		do_for_regions(area, callable_mp(this, &Terrain3DData::_copy_paste_dfr).bind(new_region.ptr()));
		new_regions.push_back(new_region);
	}

	// Remove old data
	_terrain->get_instancer()->destroy();
	TypedArray<Terrain3DRegion> old_regions = get_regions_active();
	for (const Ref<Terrain3DRegion> &region : old_regions) {
		remove_region(region, false);
	}

	// Change region size
	_terrain->set_region_size((Terrain3D::RegionSize)p_new_size);

	// Add new regions and rebuild
	for (const Ref<Terrain3DRegion> &region : new_regions) {
		add_region(region, false);
	}

	calc_height_range(true);
	update_maps(TYPE_MAX, true, true);
	_terrain->get_instancer()->update_mmis(-1, V2I_MAX, true);
}

void Terrain3DData::set_region_modified(const Vector2i &p_region_loc, const bool p_modified) {
	Terrain3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(ERROR, "Region not found at: ", p_region_loc);
		return;
	}
	return region->set_modified(p_modified);
}

bool Terrain3DData::is_region_modified(const Vector2i &p_region_loc) const {
	Terrain3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(ERROR, "Region not found at: ", p_region_loc);
		return false;
	}
	return region->is_modified();
}

void Terrain3DData::set_region_deleted(const Vector2i &p_region_loc, const bool p_deleted) {
	Terrain3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(ERROR, "Region not found at: ", p_region_loc);
		return;
	}
	return region->set_deleted(p_deleted);
}

bool Terrain3DData::is_region_deleted(const Vector2i &p_region_loc) const {
	const Terrain3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(ERROR, "Region not found at: ", p_region_loc);
		return true;
	}
	return region->is_deleted();
}

Ref<Terrain3DRegion> Terrain3DData::add_region_blankp(const Vector3 &p_global_position, const bool p_update) {
	return add_region_blank(get_region_location(p_global_position));
}

Ref<Terrain3DRegion> Terrain3DData::add_region_blank(const Vector2i &p_region_loc, const bool p_update) {
	Ref<Terrain3DRegion> region;
	region.instantiate();
	region->set_location(p_region_loc);
	region->set_region_size(_region_size);
	region->set_vertex_spacing(_vertex_spacing);
	if (add_region(region, p_update) == OK) {
		region->set_modified(true);
		return region;
	}
	return Ref<Terrain3DRegion>();
}

/** Adds a Terrain3DRegion to the terrain
 * Marks region as modified
 *	p_update - rebuild the maps if true. Set to false if bulk adding many regions.
 */
Error Terrain3DData::add_region(const Ref<Terrain3DRegion> &p_region, const bool p_update) {
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
	_ensure_region_layer_groups(p_region);
	p_region->set_deleted(false);
	if (!_region_locations.has(region_loc)) {
		_region_locations.push_back(region_loc);
	} else {
		LOG(INFO, "Overwriting ", (_regions.has(region_loc)) ? "deleted" : "existing", " region at ", region_loc);
	}
	_regions[region_loc] = p_region;
	_region_map_dirty = true;
	LOG(DEBUG, "Storing region ", region_loc, " version ", vformat("%.3f", p_region->get_version()), " id: ", _region_locations.size());
	if (p_update) {
		update_maps(TYPE_MAX, true, false);
		_terrain->get_instancer()->update_mmis(-1, V2I_MAX, true);
	}
	return OK;
}

void Terrain3DData::remove_regionp(const Vector3 &p_global_position, const bool p_update) {
	Ref<Terrain3DRegion> region = get_region(get_region_location(p_global_position));
	remove_region(region, p_update);
}

void Terrain3DData::remove_regionl(const Vector2i &p_region_loc, const bool p_update) {
	Ref<Terrain3DRegion> region = get_region(p_region_loc);
	remove_region(region, p_update);
}

// Remove region marks the region for deletion, and removes it from the active arrays indexed by ID
// It remains stored in _regions and the file remains on disk until saved, when both are removed
void Terrain3DData::remove_region(const Ref<Terrain3DRegion> &p_region, const bool p_update) {
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

void Terrain3DData::save_directory(const String &p_dir) {
	LOG(INFO, "Saving data files to ", p_dir);
	Array locations = _regions.keys();
	for (const Vector2i &region_loc : locations) {
		save_region(region_loc, p_dir, _terrain->get_save_16_bit());
	}
	if (IS_EDITOR && !EditorInterface::get_singleton()->get_resource_filesystem()->is_scanning()) {
		EditorInterface::get_singleton()->get_resource_filesystem()->scan();
	}
}

// You may need to do a file system scan to update FileSystem panel
void Terrain3DData::save_region(const Vector2i &p_region_loc, const String &p_dir, const bool p_16_bit) {
	Ref<Terrain3DRegion> region = get_region(p_region_loc);
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
}

void Terrain3DData::load_directory(const String &p_dir) {
	if (p_dir.is_empty()) {
		LOG(ERROR, "Specified directory name is blank");
		return;
	}

	LOG(INFO, "Loading region files from ", p_dir);
	PackedStringArray files = Util::get_files(p_dir, "terrain3d*.res");
	if (files.size() == 0) {
		LOG(INFO, "No Terrain3D region files found in: ", p_dir);
		return;
	}

	_clear();
	for (const String &fname : files) {
		String path = p_dir + String("/") + fname;
		LOG(DEBUG, "Loading region from ", path);
		Vector2i loc = Util::filename_to_location(fname);
		if (loc.x == INT32_MAX) {
			LOG(ERROR, "Cannot get region location from file name: ", fname);
			continue;
		}
		Ref<Terrain3DRegion> region = ResourceLoader::get_singleton()->load(path, "Terrain3DRegion", ResourceLoader::CACHE_MODE_IGNORE);
		if (region.is_null()) {
			LOG(ERROR, "Cannot load region at ", path);
			continue;
		}
		LOG(INFO, "Loaded region: ", loc, " size: ", region->get_region_size());
		if (_regions.is_empty()) {
			_terrain->set_region_size((Terrain3D::RegionSize)region->get_region_size());
		} else {
			if (_terrain->get_region_size() != (Terrain3D::RegionSize)region->get_region_size()) {
				LOG(ERROR, "Region size mismatch. First loaded: ", _terrain->get_region_size(), " next: ",
						region->get_region_size(), " in file: ", path);
				return;
			}
		}
		region->take_over_path(path);
		region->set_location(loc);
		region->set_version(CURRENT_VERSION); // Sends upgrade warning if old version
		add_region(region, false);
	}
	update_maps(TYPE_MAX, true, false);
}

//TODO have load_directory call load_region, or make a load_file that loads a specific path
void Terrain3DData::load_region(const Vector2i &p_region_loc, const String &p_dir, const bool p_update) {
	LOG(INFO, "Loading region from location ", p_region_loc);
	String path = p_dir + String("/") + Util::location_to_filename(p_region_loc);
	if (!FileAccess::file_exists(path)) {
		LOG(ERROR, "File ", path, " doesn't exist");
		return;
	}
	Ref<Terrain3DRegion> region = ResourceLoader::get_singleton()->load(path, "Terrain3DRegion", ResourceLoader::CACHE_MODE_IGNORE);
	if (region.is_null()) {
		LOG(ERROR, "Cannot load region at ", path);
		return;
	}
	if (_regions.is_empty()) {
		_terrain->set_region_size((Terrain3D::RegionSize)region->get_region_size());
	} else {
		if (_terrain->get_region_size() != (Terrain3D::RegionSize)region->get_region_size()) {
			LOG(ERROR, "Region size mismatch. First loaded: ", _terrain->get_region_size(), " next: ",
					region->get_region_size(), " in file: ", path);
			return;
		}
	}
	region->take_over_path(path);
	region->set_location(p_region_loc);
	region->set_version(CURRENT_VERSION); // Sends upgrade warning if old version
	add_region(region, p_update);
}

TypedArray<Image> Terrain3DData::get_maps(const MapType p_map_type) const {
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

TypedArray<Terrain3DLayer> Terrain3DData::get_layers(const Vector2i &p_region_loc, const MapType p_map_type) const {
	TypedArray<Terrain3DLayer> layers;
	const Terrain3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(ERROR, "Cannot retrieve layers. Region not found at ", p_region_loc);
		return layers;
	}
	layers = region->get_layers(p_map_type);
	return layers;
}

TypedArray<Dictionary> Terrain3DData::get_layer_groups(const MapType p_map_type) {
	TypedArray<Dictionary> result;
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		return result;
	}
	Dictionary grouped;
	Array region_keys = _regions.keys();
	for (int i = 0; i < region_keys.size(); i++) {
		Vector2i region_loc = region_keys[i];
		const Terrain3DRegion *region = get_region_ptr(region_loc);
		if (!region || region->is_deleted()) {
			continue;
		}
		TypedArray<Terrain3DLayer> layers = region->get_layers(p_map_type);
		for (int layer_index = 0; layer_index < layers.size(); layer_index++) {
			Ref<Terrain3DLayer> layer = layers[layer_index];
			if (layer.is_null()) {
				continue;
			}
			uint64_t group_id = _ensure_layer_group_id_internal(layer);
			if (group_id == 0) {
				continue;
			}
			if (!grouped.has(group_id)) {
				Dictionary group_info;
				group_info["group_id"] = group_id;
				group_info["map_type"] = p_map_type;
				group_info["layers"] = Array();
				grouped[group_id] = group_info;
			}
			Dictionary group_info = grouped[group_id];
			Array slices = group_info["layers"];
			Dictionary slice_info;
			slice_info["region_location"] = region_loc;
			slice_info["layer_index"] = layer_index;
			slice_info["layer"] = layer;
			slices.push_back(slice_info);
			group_info["layers"] = slices;
			grouped[group_id] = group_info;
		}
	}
	Array grouped_keys = grouped.keys();
	grouped_keys.sort();
	for (int i = 0; i < grouped_keys.size(); i++) {
		Variant key = grouped_keys[i];
		result.push_back(grouped[key]);
	}
	return result;
}

Ref<Terrain3DLayer> Terrain3DData::add_layer(const Vector2i &p_region_loc, const MapType p_map_type, const Ref<Terrain3DLayer> &p_layer, const int p_index, const bool p_update) {
	Terrain3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(ERROR, "Cannot add layer. Region not found at ", p_region_loc);
		return Ref<Terrain3DLayer>();
	}
	if (p_layer.is_null()) {
		LOG(ERROR, "Cannot add layer. Provided layer is null");
		return Ref<Terrain3DLayer>();
	}
	_ensure_layer_group_id_internal(p_layer);
	Ref<Terrain3DLayer> layer = region->add_layer(p_map_type, p_layer, p_index);
	if (layer.is_valid()) {
		region->set_modified(true);
		region->set_edited(true);
		if (p_update) {
			update_maps(p_map_type, false, false);
		}
	}
	return layer;
}

Ref<Terrain3DStampLayer> Terrain3DData::add_stamp_layer(const Vector2i &p_region_loc, const MapType p_map_type, const Ref<Image> &p_payload, const Rect2i &p_coverage, const Ref<Image> &p_alpha, const real_t p_intensity, const real_t p_feather_radius, const Terrain3DLayer::BlendMode p_blend_mode, const int p_index, const bool p_update) {
	Ref<Terrain3DStampLayer> result;
	Terrain3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(ERROR, "Cannot add stamp layer. Region not found at ", p_region_loc);
		return result;
	}
	if (p_payload.is_null()) {
		LOG(ERROR, "Stamp layer requires a valid payload image");
		return result;
	}
	Rect2i coverage = p_coverage;
	int region_size = region->get_region_size();
	Vector2i max_bounds(region_size, region_size);
	coverage.position.x = CLAMP(coverage.position.x, 0, max_bounds.x - 1);
	coverage.position.y = CLAMP(coverage.position.y, 0, max_bounds.y - 1);
	Vector2i coverage_end = coverage.position + coverage.size;
	coverage_end.x = CLAMP(coverage_end.x, coverage.position.x + 1, max_bounds.x);
	coverage_end.y = CLAMP(coverage_end.y, coverage.position.y + 1, max_bounds.y);
	coverage.size = coverage_end - coverage.position;
	if (coverage.size.x <= 0 || coverage.size.y <= 0) {
		LOG(WARN, "Stamp coverage lies outside the region bounds; skipping layer creation");
		return result;
	}
	Ref<Image> payload = p_payload;
	Image::Format expected_format = map_type_get_format(p_map_type);
	if (payload->get_format() != expected_format) {
		payload = payload->duplicate();
		if (payload.is_valid()) {
			payload->convert(expected_format);
		}
	}
	if (payload.is_null()) {
		LOG(ERROR, "Failed to prepare stamp payload image");
		return result;
	}
	Ref<Terrain3DStampLayer> layer;
	layer.instantiate();
	layer->set_map_type(p_map_type);
	layer->set_coverage(coverage);
	layer->set_payload(payload);
	if (p_alpha.is_valid()) {
		layer->set_alpha(p_alpha);
	}
	layer->set_intensity(p_intensity);
	layer->set_feather_radius(p_feather_radius);
	layer->set_blend_mode(p_blend_mode);
	layer->set_enabled(true);
	_ensure_layer_group_id_internal(layer);
	Ref<Terrain3DLayer> stored = region->add_layer(p_map_type, layer, p_index);
	result = stored;
	if (result.is_null()) {
		result = layer;
	}
	region->set_modified(true);
	region->set_edited(true);
	if (p_update) {
		update_maps(p_map_type, false, false);
	}
	return result;
}

Ref<Terrain3DLayer> Terrain3DData::get_layer_in_group(const Vector2i &p_region_loc, const MapType p_map_type, const uint64_t p_group_id, int *r_index) {
	if (p_group_id == 0) {
		return Ref<Terrain3DLayer>();
	}
	const Terrain3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		return Ref<Terrain3DLayer>();
	}
	TypedArray<Terrain3DLayer> layers = region->get_layers(p_map_type);
	for (int i = 0; i < layers.size(); i++) {
		Ref<Terrain3DLayer> layer = layers[i];
		if (layer.is_null()) {
			continue;
		}
		uint64_t group_id = _ensure_layer_group_id_internal(layer);
		if (group_id == p_group_id) {
			if (r_index) {
				*r_index = i;
			}
			return layer;
		}
	}
	return Ref<Terrain3DLayer>();
}

Ref<Terrain3DLayer> Terrain3DData::create_layer_group_slice(const Vector2i &p_region_loc, const MapType p_map_type, const uint64_t p_group_id, const Ref<Terrain3DLayer> &p_template_layer, const bool p_update) {
	if (p_group_id == 0 || p_template_layer.is_null()) {
		return Ref<Terrain3DLayer>();
	}
	Ref<Terrain3DLayer> clone = _duplicate_layer_template(p_template_layer);
	if (clone.is_null()) {
		return Ref<Terrain3DLayer>();
	}
	clone->set_group_id(p_group_id);
	clone->set_map_type(p_map_type);
	return add_layer(p_region_loc, p_map_type, clone, -1, p_update);
}

TypedArray<Terrain3DStampLayer> Terrain3DData::add_stamp_layer_global(const Rect2i &p_global_coverage, const MapType p_map_type, const Ref<Image> &p_payload, const Ref<Image> &p_alpha, const real_t p_intensity, const real_t p_feather_radius, const Terrain3DLayer::BlendMode p_blend_mode, const bool p_auto_create_regions, const bool p_update) {
	TypedArray<Terrain3DStampLayer> created_layers;
	if (!p_global_coverage.has_area()) {
		LOG(WARN, "add_stamp_layer_global: coverage has no area");
		return created_layers;
	}
	LayerSplitResults splits = split_layer_payload_global(p_global_coverage, p_payload, p_alpha);
	if (splits.empty()) {
		return created_layers;
	}
	bool any_added = false;
	uint64_t shared_group_id = 0;
	for (const LayerSplitResult &slice : splits) {
		Terrain3DRegion *region = get_region_ptr(slice.region_location);
		if (!region && p_auto_create_regions) {
			Ref<Terrain3DRegion> new_region = add_region_blank(slice.region_location, false);
			region = new_region.is_valid() ? new_region.ptr() : nullptr;
		}
		if (!region) {
			LOG(WARN, "add_stamp_layer_global: region ", slice.region_location, " unavailable; skipping slice");
			continue;
		}
		Ref<Terrain3DStampLayer> added = add_stamp_layer(slice.region_location, p_map_type, slice.payload, slice.coverage, slice.alpha, p_intensity, p_feather_radius, p_blend_mode, -1, false);
		if (added.is_valid()) {
			if (shared_group_id == 0) {
				shared_group_id = ensure_layer_group_id(added);
			} else {
				added->set_group_id(shared_group_id);
			}
			created_layers.push_back(added);
			any_added = true;
		}
	}
	if (any_added && p_update) {
		update_maps(p_map_type, false, false);
	}
	return created_layers;
}

Terrain3DData::LayerSplitResults Terrain3DData::split_layer_payload_global(const Rect2i &p_global_coverage, const Ref<Image> &p_payload, const Ref<Image> &p_alpha) const {
	LayerSplitResults slices;
	if (!p_global_coverage.has_area()) {
		LOG(DEBUG, "split_layer_payload_global: requested coverage has no area");
		return slices;
	}
	if (p_payload.is_null()) {
		LOG(WARN, "split_layer_payload_global: payload image is null");
		return slices;
	}
	if (_region_size <= 0) {
		LOG(ERROR, "split_layer_payload_global: invalid region size ", _region_size);
		return slices;
	}
	Vector2i payload_size(p_payload->get_width(), p_payload->get_height());
	if (payload_size.x <= 0 || payload_size.y <= 0) {
		LOG(ERROR, "split_layer_payload_global: payload has invalid dimensions ", payload_size);
		return slices;
	}
	if (payload_size != p_global_coverage.size) {
		LOG(ERROR, "split_layer_payload_global: payload size ", payload_size, " does not match coverage size ", p_global_coverage.size);
		return slices;
	}
	if (p_alpha.is_valid()) {
		Vector2i alpha_size(p_alpha->get_width(), p_alpha->get_height());
		if (alpha_size != payload_size) {
			LOG(WARN, "split_layer_payload_global: alpha size ", alpha_size, " does not match payload size ", payload_size, ". Alpha will be ignored");
		}
	}
	auto floor_div = [](int value, int divisor) -> int {
		if (divisor == 0) {
			return 0;
		}
		int result = value / divisor;
		int remainder = value % divisor;
		if (remainder != 0 && ((remainder < 0) != (divisor < 0))) {
			result -= 1;
		}
		return result;
	};
	Vector2i coverage_end = p_global_coverage.get_end();
	coverage_end -= Vector2i(1, 1); // Make inclusive for region range calculation
	int min_region_x = floor_div(p_global_coverage.position.x, _region_size);
	int min_region_y = floor_div(p_global_coverage.position.y, _region_size);
	int max_region_x = floor_div(coverage_end.x, _region_size);
	int max_region_y = floor_div(coverage_end.y, _region_size);
	for (int region_y = min_region_y; region_y <= max_region_y; region_y++) {
		for (int region_x = min_region_x; region_x <= max_region_x; region_x++) {
			Vector2i region_loc(region_x, region_y);
			Rect2i region_bounds(region_loc * _region_size, Vector2i(_region_size, _region_size));
			Rect2i slice_global = region_bounds.intersection(p_global_coverage);
			if (!slice_global.has_area()) {
				continue;
			}
			Rect2i payload_rect(slice_global.position - p_global_coverage.position, slice_global.size);
			if (payload_rect.position.x < 0 || payload_rect.position.y < 0 ||
				payload_rect.get_end().x > payload_size.x || payload_rect.get_end().y > payload_size.y) {
				LOG(ERROR, "split_layer_payload_global: computed payload rect ", payload_rect,
					" falls outside payload bounds ", Rect2i(Vector2i(), payload_size));
				return slices;
			}
			Ref<Image> region_payload;
			region_payload.instantiate();
			region_payload->create(slice_global.size.x, slice_global.size.y, false, p_payload->get_format());
			region_payload->blit_rect(p_payload, payload_rect, Vector2i());
			Ref<Image> region_alpha;
			if (p_alpha.is_valid() && p_alpha->get_width() == payload_size.x && p_alpha->get_height() == payload_size.y) {
				region_alpha.instantiate();
				region_alpha->create(slice_global.size.x, slice_global.size.y, false, p_alpha->get_format());
				region_alpha->blit_rect(p_alpha, payload_rect, Vector2i());
			}
			LayerSplitResult slice;
			slice.region_location = region_loc;
			slice.coverage = Rect2i(slice_global.position - region_bounds.position, slice_global.size);
			slice.payload = region_payload;
			slice.alpha = region_alpha;
			slices.push_back(slice);
		}
	}
	return slices;
}

TypedArray<Dictionary> Terrain3DData::split_layer_payload_global_data(const Rect2i &p_global_coverage, const Ref<Image> &p_payload, const Ref<Image> &p_alpha) const {
	TypedArray<Dictionary> result;
	LayerSplitResults slices = split_layer_payload_global(p_global_coverage, p_payload, p_alpha);
	for (const LayerSplitResult &slice : slices) {
		Dictionary entry;
		entry["region_location"] = slice.region_location;
		entry["coverage"] = slice.coverage;
		if (slice.payload.is_valid()) {
			entry["payload"] = slice.payload;
		}
		if (slice.alpha.is_valid()) {
			entry["alpha"] = slice.alpha;
		}
		result.push_back(entry);
	}
	return result;
}

Dictionary Terrain3DData::get_layer_owner_info(const Ref<Terrain3DLayer> &p_layer, const MapType p_map_type) const {
	Dictionary result;
	if (p_layer.is_null()) {
		return result;
	}
	Terrain3DRegion *region = nullptr;
	Vector2i region_loc;
	int index = -1;
	if (!_find_layer_owner(p_layer, p_map_type, &region, &region_loc, &index)) {
		return result;
	}
	result["region_location"] = region_loc;
	result["index"] = index;
	result["map_type"] = p_map_type;
	return result;
}

bool Terrain3DData::set_layer_coverage(const Vector2i &p_region_loc, const MapType p_map_type, const int p_index, const Rect2i &p_coverage, const bool p_update) {
	Terrain3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(WARN, "Cannot set layer coverage. Region not found at ", p_region_loc);
		return false;
	}
	int region_size = region->get_region_size();
	if (!is_valid_region_size(region_size)) {
		Ref<Image> map = region->get_map(p_map_type);
		if (map.is_valid()) {
			region_size = MAX(map->get_width(), map->get_height());
		}
	}
	if (!is_valid_region_size(region_size)) {
		region_size = _region_size;
	}
	if (!is_valid_region_size(region_size)) {
		LOG(ERROR, "Cannot set layer coverage. Region size unresolved for ", p_region_loc);
		return false;
	}
	TypedArray<Terrain3DLayer> layers = region->get_layers(p_map_type);
	if (p_index < 0 || p_index >= layers.size()) {
		LOG(WARN, "Layer index ", p_index, " out of bounds for region ", p_region_loc);
		return false;
	}
	Ref<Terrain3DLayer> layer = layers[p_index];
	if (layer.is_null()) {
		LOG(WARN, "Layer at index ", p_index, " is null in region ", p_region_loc);
		return false;
	}
	Rect2i coverage = p_coverage;
	Vector2i coverage_size = coverage.size;
	if (coverage_size.x <= 0 || coverage_size.y <= 0) {
		Ref<Image> payload = layer->get_payload();
		if (payload.is_valid()) {
			coverage_size = payload->get_size();
		} else {
			coverage_size = Vector2i(_region_size, _region_size);
		}
		coverage.size = coverage_size;
	}
	coverage_size.x = CLAMP(coverage_size.x, 1, region_size);
	coverage_size.y = CLAMP(coverage_size.y, 1, region_size);
	int max_x = MAX(0, region_size - coverage_size.x);
	int max_y = MAX(0, region_size - coverage_size.y);
	Vector2i clamped_pos(
		CLAMP(coverage.position.x, 0, max_x),
		CLAMP(coverage.position.y, 0, max_y));
	coverage.position = clamped_pos;
	coverage.size = coverage_size;
	layer->set_coverage(coverage);
	layer->mark_dirty();
	region->mark_layers_dirty(p_map_type);
	region->set_modified(true);
	region->set_edited(true);
	if (p_update) {
		update_maps(p_map_type, false, false);
	}
	return true;
}

bool Terrain3DData::move_stamp_layer(const Ref<Terrain3DStampLayer> &p_layer, const Vector3 &p_world_position, const bool p_update) {
	if (p_layer.is_null()) {
		LOG(WARN, "Cannot move stamp layer: layer reference is null");
		return false;
	}
	MapType map_type = p_layer->get_map_type();
	Terrain3DRegion *current_region = nullptr;
	Vector2i current_loc;
	int current_index = -1;
	if (!_find_layer_owner(p_layer, map_type, &current_region, &current_loc, &current_index)) {
		LOG(WARN, "Cannot move stamp layer: owning region not located");
		return false;
	}
	LOG(DEBUG, "move_stamp_layer: request from region ", current_loc, " index ", current_index,
			" map_type ", map_type, " world ", p_world_position);
	Vector2i target_loc = get_region_location(p_world_position);
	Terrain3DRegion *target_region = get_region_ptr(target_loc);
	if (!target_region) {
		LOG(WARN, "Cannot move stamp layer: target region ", target_loc, " not available for world position ", p_world_position);
		return false;
	}
	Rect2i coverage = p_layer->get_coverage();
	Vector2i coverage_size = coverage.size;
	if (coverage_size.x <= 0 || coverage_size.y <= 0) {
		Ref<Image> payload = p_layer->get_payload();
		if (payload.is_valid()) {
			coverage_size = payload->get_size();
		} else {
			coverage_size = Vector2i(_region_size, _region_size);
		}
	}
	if (coverage_size.x <= 0 || coverage_size.y <= 0) {
		LOG(WARN, "Cannot move stamp layer: invalid coverage dimensions");
		return false;
	}
	coverage.size = coverage_size;
	Vector2 region_origin = Vector2(target_loc) * real_t(_region_size) * _vertex_spacing;
	Vector2 local = (Vector2(p_world_position.x, p_world_position.z) - region_origin) / _vertex_spacing;
	Vector2 offset = Vector2(coverage_size) * 0.5f;
	Vector2 target_pos_f = local - offset;
	Vector2i target_pos(
		int(Math::round(target_pos_f.x)),
		int(Math::round(target_pos_f.y)));
	int max_x = MAX(0, _region_size - coverage_size.x);
	int max_y = MAX(0, _region_size - coverage_size.y);
	target_pos.x = CLAMP(target_pos.x, 0, max_x);
	target_pos.y = CLAMP(target_pos.y, 0, max_y);
	Rect2i target_coverage(target_pos, coverage_size);
	LOG(DEBUG, "move_stamp_layer: target region ", target_loc, " coverage size ", coverage_size,
			" target_pos ", target_pos, " region_origin ", region_origin);
	Ref<Terrain3DStampLayer> stamp_layer = p_layer;
	if (current_region != target_region) {
		LOG(DEBUG, "move_stamp_layer: transferring layer from region ", current_loc, " to ", target_loc);
		current_region->remove_layer(map_type, current_index);
		current_region->mark_layers_dirty(map_type);
		current_region->set_modified(true);
		current_region->set_edited(true);
		Ref<Terrain3DLayer> stored = target_region->add_layer(map_type, stamp_layer);
		Ref<Terrain3DStampLayer> stored_stamp = stored;
		if (stored_stamp.is_valid()) {
			stamp_layer = stored_stamp;
		}
	}
	stamp_layer->set_coverage(target_coverage);
	stamp_layer->mark_dirty();
	target_region->mark_layers_dirty(map_type);
	target_region->set_modified(true);
	target_region->set_edited(true);
	LOG(DEBUG, "move_stamp_layer: coverage updated to ", target_coverage, " (map_type ", map_type, ")");
	if (p_update) {
		update_maps(map_type, false, false);
	}
	return true;
}

void Terrain3DData::set_layer_enabled(const Vector2i &p_region_loc, const MapType p_map_type, const int p_index, const bool p_enabled, const bool p_update) {
	Terrain3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(ERROR, "Cannot set layer enabled state. Region not found at ", p_region_loc);
		return;
	}
	TypedArray<Terrain3DLayer> layers = region->get_layers(p_map_type);
	if (p_index < 0 || p_index >= layers.size()) {
		LOG(WARN, "Layer index ", p_index, " out of bounds for region ", p_region_loc);
		return;
	}
	Ref<Terrain3DLayer> layer = layers[p_index];
	if (layer.is_null()) {
		LOG(WARN, "Layer at index ", p_index, " is null in region ", p_region_loc);
		return;
	}
	if (layer->is_enabled() == p_enabled) {
		return;
	}
	layer->set_enabled(p_enabled);
	region->mark_layers_dirty(p_map_type);
	region->set_modified(true);
	region->set_edited(true);
	if (p_update) {
		update_maps(p_map_type, false, false);
	}
}

void Terrain3DData::remove_layer(const Vector2i &p_region_loc, const MapType p_map_type, const int p_index, const bool p_update) {
	Terrain3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(ERROR, "Cannot remove layer. Region not found at ", p_region_loc);
		return;
	}
	region->remove_layer(p_map_type, p_index);
	region->set_modified(true);
	region->set_edited(true);
	if (p_update) {
		update_maps(p_map_type, false, false);
	}
}

Ref<Terrain3DCurveLayer> Terrain3DData::add_curve_layer(const Vector2i &p_region_loc, const PackedVector3Array &p_points, const real_t p_width, const real_t p_depth, const bool p_dual_groove, const real_t p_feather_radius, const bool p_update) {
	Terrain3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(ERROR, "Cannot add curve layer. Region not found at ", p_region_loc);
		return Ref<Terrain3DCurveLayer>();
	}
	if (p_points.size() < 2) {
		LOG(ERROR, "Curve layer requires at least two points");
		return Ref<Terrain3DCurveLayer>();
	}
	Ref<Image> height_map = region->get_height_map();
	bool height_map_invalid = height_map.is_null() || height_map->get_width() <= 0 || height_map->get_height() <= 0;
	if (height_map_invalid) {
		region->sanitize_maps();
		height_map = region->get_height_map();
		height_map_invalid = height_map.is_null() || height_map->get_width() <= 0 || height_map->get_height() <= 0;
	}
	if (height_map_invalid) {
		int region_size = region->get_region_size();
		if (!is_valid_region_size(region_size)) {
			region_size = _region_size;
		}
		if (is_valid_region_size(region_size)) {
			Ref<Image> new_height;
			new_height.instantiate();
			new_height->create(region_size, region_size, false, Image::FORMAT_RF);
			new_height->fill(Color(0.0f, 0.0f, 0.0f, 1.0f));
			region->set_height_map(new_height);
			LOG(WARN, "Region ", p_region_loc, " had invalid height map when adding curve layer. Created blank height map.");
		} else {
			LOG(ERROR, "Region ", p_region_loc, " has invalid region size when adding curve layer. Aborting layer creation.");
			return Ref<Terrain3DCurveLayer>();
		}
	}
	Ref<Terrain3DCurveLayer> curve_layer;
	curve_layer.instantiate();
	Vector3 region_origin = Vector3(p_region_loc.x, 0.0f, p_region_loc.y) * real_t(_region_size) * _vertex_spacing;
	PackedVector3Array local_points;
	local_points.resize(p_points.size());
	for (int i = 0; i < p_points.size(); i++) {
		Vector3 local = p_points[i];
		local.x -= region_origin.x;
		local.z -= region_origin.z;
		local_points.set(i, local);
	}
	curve_layer->set_map_type(TYPE_HEIGHT);
	curve_layer->set_points(local_points);
	curve_layer->set_width(p_width);
	curve_layer->set_depth(p_depth);
	curve_layer->set_dual_groove(p_dual_groove);
	curve_layer->set_feather_radius(p_feather_radius);
	curve_layer->set_blend_mode(Terrain3DLayer::BLEND_REPLACE);
	curve_layer->set_intensity(1.0f);
	_ensure_layer_group_id_internal(curve_layer);
	Ref<Terrain3DLayer> added = region->add_layer(TYPE_HEIGHT, curve_layer);
	Ref<Terrain3DCurveLayer> result = added;
	if (result.is_null()) {
		result = curve_layer;
	}
	region->set_modified(true);
	region->set_edited(true);
	if (p_update) {
		update_maps(TYPE_HEIGHT, false, false);
	}
	return result;
}

void Terrain3DData::update_maps(const MapType p_map_type, const bool p_all_regions, const bool p_generate_mipmaps) {
	// Generate region color mipmaps
	if (p_generate_mipmaps && (p_map_type == TYPE_COLOR || p_map_type == TYPE_MAX)) {
		LOG(EXTREME, "Regenerating color mipmaps");
		for (const Vector2i &region_loc : _region_locations) {
			Terrain3DRegion *region = get_region_ptr(region_loc);
			// Generate all or only those marked edited
			if (region && (p_all_regions || region->is_edited())) {
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
		Array locs = _regions.keys();
		int region_id = 0;
		for (const Vector2i &region_loc : locs) {
			const Terrain3DRegion *region = get_region_ptr(region_loc);
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
			const Terrain3DRegion *region = get_region_ptr(region_loc);
			if (region) {
				_height_maps.push_back(region->get_composited_map(TYPE_HEIGHT));
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
			const Terrain3DRegion *region = get_region_ptr(region_loc);
			if (region) {
				_control_maps.push_back(region->get_composited_map(TYPE_CONTROL));
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
			const Terrain3DRegion *region = get_region_ptr(region_loc);
			if (region) {
				_color_maps.push_back(region->get_composited_map(TYPE_COLOR));
			}
		}
		_generated_color_maps.create(_color_maps);
		any_changed = true;
		LOG(DEBUG, "Emitting color_maps_changed");
		emit_signal("color_maps_changed");
	}

	// If no maps have been rebuilt, update only individual regions in the array.
	// Regions marked Edited have been changed by Terrain3DEditor::_operate_map or undo / redo processing.
	if (!any_changed) {
		for (const Vector2i &region_loc : _region_locations) {
			const Terrain3DRegion *region = get_region_ptr(region_loc);
			if (region && region->is_edited()) {
				int region_id = get_region_id(region_loc);
				switch (p_map_type) {
					case TYPE_HEIGHT:
						_generated_height_maps.update(region->get_composited_map(TYPE_HEIGHT), region_id);
						LOG(DEBUG, "Emitting height_maps_changed");
						emit_signal("height_maps_changed");
						break;
					case TYPE_CONTROL:
						_generated_control_maps.update(region->get_composited_map(TYPE_CONTROL), region_id);
						LOG(DEBUG, "Emitting control_maps_changed");
						emit_signal("control_maps_changed");
						break;
					case TYPE_COLOR:
						_generated_color_maps.update(region->get_composited_map(TYPE_COLOR), region_id);
						LOG(DEBUG, "Emitting color_maps_changed");
						emit_signal("color_maps_changed");
						break;
					default:
						_generated_height_maps.update(region->get_composited_map(TYPE_HEIGHT), region_id);
						_generated_control_maps.update(region->get_composited_map(TYPE_CONTROL), region_id);
						_generated_color_maps.update(region->get_composited_map(TYPE_COLOR), region_id);
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
		_terrain->snap();
	}
}

void Terrain3DData::set_pixel(const MapType p_map_type, const Vector3 &p_global_position, const Color &p_pixel) {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return;
	}
	Vector2i region_loc = get_region_location(p_global_position);
	Terrain3DRegion *region = get_region_ptr(region_loc);
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

Color Terrain3DData::get_pixel(const MapType p_map_type, const Vector3 &p_global_position) const {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return COLOR_NAN;
	}
	Vector2i region_loc = get_region_location(p_global_position);
	const Terrain3DRegion *region = get_region_ptr(region_loc);
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
	Ref<Image> composite = region->get_composited_map(p_map_type);
	if (composite.is_valid()) {
		return composite->get_pixelv(img_pos);
	}
	Image *map = region->get_map_ptr(p_map_type);
	return map ? map->get_pixelv(img_pos) : COLOR_NAN;
}

real_t Terrain3DData::get_height(const Vector3 &p_global_position) const {
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

Vector3 Terrain3DData::get_normal(const Vector3 &p_global_position) const {
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

bool Terrain3DData::is_in_slope(const Vector3 &p_global_position, const Vector2 &p_slope_range, const Vector3 &p_normal) const {
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

	const real_t slope_angle = Math::acos(slope_normal.dot(V3_UP));
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
Vector3 Terrain3DData::get_texture_id(const Vector3 &p_global_position) const {
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
		Ref<Terrain3DMaterial> t_material = _terrain->get_material();
		bool auto_enabled = t_material->get_auto_shader();
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
Vector3 Terrain3DData::get_mesh_vertex(const int32_t p_lod, const HeightFilter p_filter, const Vector3 &p_global_position) const {
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

void Terrain3DData::add_edited_area(const AABB &p_area) {
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
void Terrain3DData::calc_height_range(const bool p_recursive) {
	_master_height_range = V2_ZERO;
	for (const Vector2i &region_loc : _region_locations) {
		Terrain3DRegion *region = get_region_ptr(region_loc);
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
 * Imports an Image set (Height, Control, Color) into Terrain3DData
 * It does NOT normalize values to 0-1. You must do that using get_min_max() and adjusting scale and offset.
 * Parameters:
 *	p_images - MapType.TYPE_MAX sized array of Images for Height, Control, Color. Images can be blank or null
 *	p_global_position - X,0,Z location on the region map. Valid range is ~ (+/-8192, +/-8192)
 *	p_offset - Add this factor to all height values, can be negative
 *	p_scale - Scale all height values by this factor (applied after offset)
 */
void Terrain3DData::import_images(const TypedArray<Image> &p_images, const Vector3 &p_global_position, const real_t p_offset, const real_t p_scale) {
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
				". Try ", -(img_size * _vertex_spacing) / 2.f, " to center");
		return;
	}

	TypedArray<Image> tmp_images;
	tmp_images.resize(TYPE_MAX);

	for (int i = 0; i < TYPE_MAX; i++) {
		Ref<Image> img = p_images[i];
		tmp_images[i] = img;
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
			tmp_images[i] = newimg;
		}
	}

	// Slice up incoming image into segments of region_size^2, and pad any remainder
	int slices_width = ceil(real_t(img_size.x) / real_t(_region_size));
	int slices_height = ceil(real_t(img_size.y) / real_t(_region_size));
	slices_width = CLAMP(slices_width, 1, REGION_MAP_SIZE);
	slices_height = CLAMP(slices_height, 1, REGION_MAP_SIZE);
	LOG(DEBUG, "Creating ", Vector2i(slices_width, slices_height), " slices for ", img_size, " images.");

	for (int y = 0; y < slices_height; y++) {
		for (int x = 0; x < slices_width; x++) {
			Vector2i start_coords = Vector2i(x * _region_size, y * _region_size);
			Vector2i end_coords = Vector2i((x + 1) * _region_size - 1, (y + 1) * _region_size - 1);
			LOG(DEBUG, "Reviewing image section ", start_coords, " to ", end_coords);

			Vector2i size_to_copy;
			if (end_coords.x <= img_size.x && end_coords.y <= img_size.y) {
				size_to_copy = _region_sizev;
			} else {
				size_to_copy.x = img_size.x - start_coords.x;
				size_to_copy.y = img_size.y - start_coords.y;
				LOG(DEBUG, "Uneven end piece. Copying padded slice ", Vector2i(x, y), " size to copy: ", size_to_copy);
			}
			LOG(DEBUG, "Copying ", size_to_copy, " sized segment");

			Vector3 global_position = Vector3(descaled_position.x + start_coords.x, 0.f, descaled_position.z + start_coords.y) * _vertex_spacing;
			Vector2i region_loc = get_region_location(global_position);
			Ref<Terrain3DRegion> region = get_region(region_loc);
			if (region.is_null()) {
				region.instantiate();
				region->set_location(region_loc);
				region->set_region_size(_region_size);
				region->set_vertex_spacing(_vertex_spacing);
				region->set_modified(true);
				add_region(region, false);
			}
			for (int i = 0; i < TYPE_MAX; i++) {
				Ref<Image> img = tmp_images[i];
				Ref<Image> img_slice;
				// If incoming map is valid, import it, overwriting
				if (img.is_valid() && !img->is_empty()) {
					img_slice = Util::get_filled_image(_region_sizev, COLOR[i], false, img->get_format());
					img_slice->blit_rect(tmp_images[i], Rect2i(start_coords, size_to_copy), V2I_ZERO);
					region->set_map(static_cast<MapType>(i), img_slice);
				}
			}
			region->sanitize_maps();
		} // for x < slices_width
	} // for y < slices_height
	update_maps(TYPE_MAX, true, false);
}

/** Exports a specified map as one of r16/raw, exr, jpg, png, webp, res, tres
 * r16 or exr are recommended for roundtrip external editing
 * r16 can be edited by Krita, however you must know the dimensions and min/max before reimporting
 * res/tres stores in Godot's native format.
 */
Error Terrain3DData::export_image(const String &p_file_name, const MapType p_map_type) const {
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

	// Update path delimeter
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

	// Check if the file can be opened for writing
	Ref<FileAccess> file_ref = FileAccess::open(file_name, FileAccess::ModeFlags::WRITE);
	if (file_ref.is_null()) {
		LOG(ERROR, "Cannot open file '" + file_name + "' for writing");
		return FAILED;
	}
	file_ref->close();

	// Filename is validated. Begin export image generation
	Ref<Image> img = layered_to_image(p_map_type);
	if (img.is_null() || img->is_empty()) {
		LOG(ERROR, "Cannot create an export image for map type: ", TYPESTR[p_map_type]);
		return FAILED;
	}

	String ext = file_name.get_extension().to_lower();
	LOG(MESG, "Saving ", img->get_size(), " sized ", TYPESTR[p_map_type],
			" map in format ", img->get_format(), " as ", ext, " to: ", file_name);
	Vector2i minmax = Util::get_min_max(img);
	LOG(MESG, "Minimum height: ", minmax.x, ", Maximum height: ", minmax.y);
	if (ext == "r16" || ext == "raw") {
		Ref<FileAccess> file = FileAccess::open(file_name, FileAccess::WRITE);
		real_t height_min = minmax.x;
		real_t height_max = minmax.y;
		real_t hscale = 65535.0 / (height_max - height_min);
		for (int y = 0; y < img->get_height(); y++) {
			for (int x = 0; x < img->get_width(); x++) {
				int h = int((img->get_pixel(x, y).r - height_min) * hscale);
				h = CLAMP(h, 0, 65535);
				file->store_16(h);
			}
		}
		return file->get_error();
	} else if (ext == "exr") {
		return img->save_exr(file_name, (p_map_type == TYPE_HEIGHT) ? true : false);
	} else if (ext == "png") {
		return img->save_png(file_name);
	} else if (ext == "jpg") {
		return img->save_jpg(file_name);
	} else if (ext == "webp") {
		return img->save_webp(file_name);
	} else if ((ext == "res") || (ext == "tres")) {
		return ResourceSaver::get_singleton()->save(img, file_name, ResourceSaver::FLAG_COMPRESS);
	}

	LOG(ERROR, "No recognized file type. See docs for valid extensions");
	return FAILED;
}

Ref<Image> Terrain3DData::layered_to_image(const MapType p_map_type) const {
	LOG(INFO, "Generating a full sized image for all regions including empty regions");
	MapType map_type = p_map_type;
	if (map_type >= TYPE_MAX) {
		map_type = TYPE_HEIGHT;
	}
	Vector2i top_left = V2I_ZERO;
	Vector2i bottom_right = V2I_ZERO;
	for (const Vector2i &region_loc : _region_locations) {
		LOG(DEBUG, "Region location: ", region_loc);
		if (region_loc.x < top_left.x) {
			top_left.x = region_loc.x;
		} else if (region_loc.x > bottom_right.x) {
			bottom_right.x = region_loc.x;
		}
		if (region_loc.y < top_left.y) {
			top_left.y = region_loc.y;
		} else if (region_loc.y > bottom_right.y) {
			bottom_right.y = region_loc.y;
		}
	}

	LOG(DEBUG, "Full range to cover all regions: ", top_left, " to ", bottom_right);
	Vector2i img_size = Vector2i(1 + bottom_right.x - top_left.x, 1 + bottom_right.y - top_left.y) * _region_size;
	LOG(DEBUG, "Image size: ", img_size);
	Ref<Image> img = Util::get_filled_image(img_size, COLOR[map_type], false, FORMAT[map_type]);

	for (const Vector2i &region_loc : _region_locations) {
		Vector2i img_location = (region_loc - top_left) * _region_size;
		LOG(DEBUG, "Region to blit: ", region_loc, " Export image coords: ", img_location);
		const Terrain3DRegion *region = get_region_ptr(region_loc);
		if (!region) {
			continue;
		}
		Ref<Image> source = region->get_composited_map(map_type);
		if (source.is_null()) {
			source = region->get_map(map_type);
		}
		if (source.is_null()) {
			continue;
		}
		Rect2i src_rect = Rect2i(V2I_ZERO, source->get_size());
		img->blit_rect(source, src_rect, img_location);
	}
	return img;
}

void Terrain3DData::dump(const bool verbose) const {
	LOG(MESG, "_region_locations (", _region_locations.size(), "): ", _region_locations);
	Array keys = _regions.keys();
	LOG(MESG, "_regions (", keys.size(), "):");
	for (const Vector2i &region_loc : keys) {
		const Terrain3DRegion *region = get_region_ptr(region_loc);
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

void Terrain3DData::_bind_methods() {
	BIND_ENUM_CONSTANT(HEIGHT_FILTER_NEAREST);
	BIND_ENUM_CONSTANT(HEIGHT_FILTER_MINIMUM);

	BIND_CONSTANT(REGION_MAP_SIZE);

	ClassDB::bind_method(D_METHOD("get_region_count"), &Terrain3DData::get_region_count);
	ClassDB::bind_method(D_METHOD("set_region_locations", "region_locations"), &Terrain3DData::set_region_locations);
	ClassDB::bind_method(D_METHOD("get_region_locations"), &Terrain3DData::get_region_locations);
	ClassDB::bind_method(D_METHOD("get_regions_active", "copy", "deep"), &Terrain3DData::get_regions_active, DEFVAL(false), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("get_regions_all"), &Terrain3DData::get_regions_all);
	ClassDB::bind_method(D_METHOD("get_region_map"), &Terrain3DData::get_region_map);
	ClassDB::bind_static_method("Terrain3DData", D_METHOD("get_region_map_index", "region_location"), &Terrain3DData::get_region_map_index);

	ClassDB::bind_method(D_METHOD("do_for_regions", "area", "callback"), &Terrain3DData::do_for_regions);
	ClassDB::bind_method(D_METHOD("change_region_size", "region_size"), &Terrain3DData::change_region_size);

	ClassDB::bind_method(D_METHOD("get_region_location", "global_position"), &Terrain3DData::get_region_location);
	ClassDB::bind_method(D_METHOD("get_region_id", "region_location"), &Terrain3DData::get_region_id);
	ClassDB::bind_method(D_METHOD("get_region_idp", "global_position"), &Terrain3DData::get_region_idp);

	ClassDB::bind_method(D_METHOD("has_region", "region_location"), &Terrain3DData::has_region);
	ClassDB::bind_method(D_METHOD("has_regionp", "global_position"), &Terrain3DData::has_regionp);
	ClassDB::bind_method(D_METHOD("get_region", "region_location"), &Terrain3DData::get_region);
	ClassDB::bind_method(D_METHOD("get_regionp", "global_position"), &Terrain3DData::get_regionp);

	ClassDB::bind_method(D_METHOD("set_region_modified", "region_location", "modified"), &Terrain3DData::set_region_modified);
	ClassDB::bind_method(D_METHOD("is_region_modified", "region_location"), &Terrain3DData::is_region_modified);
	ClassDB::bind_method(D_METHOD("set_region_deleted", "region_location", "deleted"), &Terrain3DData::set_region_deleted);
	ClassDB::bind_method(D_METHOD("is_region_deleted", "region_location"), &Terrain3DData::is_region_deleted);

	ClassDB::bind_method(D_METHOD("add_region_blankp", "global_position", "update"), &Terrain3DData::add_region_blankp, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_region_blank", "region_location", "update"), &Terrain3DData::add_region_blank, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_region", "region", "update"), &Terrain3DData::add_region, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("remove_regionp", "global_position", "update"), &Terrain3DData::remove_regionp, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("remove_regionl", "region_location", "update"), &Terrain3DData::remove_regionl, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("remove_region", "region", "update"), &Terrain3DData::remove_region, DEFVAL(true));

	ClassDB::bind_method(D_METHOD("save_directory", "directory"), &Terrain3DData::save_directory);
	ClassDB::bind_method(D_METHOD("save_region", "region_location", "directory", "save_16_bit"), &Terrain3DData::save_region, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("load_directory", "directory"), &Terrain3DData::load_directory);
	ClassDB::bind_method(D_METHOD("load_region", "region_location", "directory", "update"), &Terrain3DData::load_region, DEFVAL(true));

	ClassDB::bind_method(D_METHOD("get_height_maps"), &Terrain3DData::get_height_maps);
	ClassDB::bind_method(D_METHOD("get_control_maps"), &Terrain3DData::get_control_maps);
	ClassDB::bind_method(D_METHOD("get_color_maps"), &Terrain3DData::get_color_maps);
	ClassDB::bind_method(D_METHOD("get_maps", "map_type"), &Terrain3DData::get_maps);
	ClassDB::bind_method(D_METHOD("get_layers", "region_location", "map_type"), &Terrain3DData::get_layers);
	ClassDB::bind_method(D_METHOD("get_layer_groups", "map_type"), &Terrain3DData::get_layer_groups);
	ClassDB::bind_method(D_METHOD("ensure_layer_group_id", "layer"), &Terrain3DData::ensure_layer_group_id);
	ClassDB::bind_method(D_METHOD("add_layer", "region_location", "map_type", "layer", "index", "update"), &Terrain3DData::add_layer, DEFVAL(-1), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_stamp_layer", "region_location", "map_type", "payload", "coverage", "alpha", "intensity", "feather_radius", "blend_mode", "index", "update"), &Terrain3DData::add_stamp_layer, DEFVAL(Ref<Image>()), DEFVAL(1.0f), DEFVAL(0.0f), DEFVAL(Terrain3DLayer::BLEND_ADD), DEFVAL(-1), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_stamp_layer_global", "global_coverage", "map_type", "payload", "alpha", "intensity", "feather_radius", "blend_mode", "auto_create_regions", "update"), &Terrain3DData::add_stamp_layer_global, DEFVAL(Ref<Image>()), DEFVAL(1.0f), DEFVAL(0.0f), DEFVAL(Terrain3DLayer::BLEND_ADD), DEFVAL(true), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("split_layer_payload_global_data", "global_coverage", "payload", "alpha"), &Terrain3DData::split_layer_payload_global_data, DEFVAL(Ref<Image>()));
	ClassDB::bind_method(D_METHOD("get_layer_owner_info", "layer", "map_type"), &Terrain3DData::get_layer_owner_info);
	ClassDB::bind_method(D_METHOD("set_layer_coverage", "region_location", "map_type", "index", "coverage", "update"), &Terrain3DData::set_layer_coverage, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("move_stamp_layer", "layer", "world_position", "update"), &Terrain3DData::move_stamp_layer, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("set_layer_enabled", "region_location", "map_type", "index", "enabled", "update"), &Terrain3DData::set_layer_enabled, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("remove_layer", "region_location", "map_type", "index", "update"), &Terrain3DData::remove_layer, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_curve_layer", "region_location", "points", "width", "depth", "dual_groove", "feather_radius", "update"), &Terrain3DData::add_curve_layer, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("update_maps", "map_type", "all_regions", "generate_mipmaps"), &Terrain3DData::update_maps, DEFVAL(TYPE_MAX), DEFVAL(true), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("get_height_maps_rid"), &Terrain3DData::get_height_maps_rid);
	ClassDB::bind_method(D_METHOD("get_control_maps_rid"), &Terrain3DData::get_control_maps_rid);
	ClassDB::bind_method(D_METHOD("get_color_maps_rid"), &Terrain3DData::get_color_maps_rid);

	ClassDB::bind_method(D_METHOD("set_pixel", "map_type", "global_position", "pixel"), &Terrain3DData::set_pixel);
	ClassDB::bind_method(D_METHOD("get_pixel", "map_type", "global_position"), &Terrain3DData::get_pixel);
	ClassDB::bind_method(D_METHOD("set_height", "global_position", "height"), &Terrain3DData::set_height);
	ClassDB::bind_method(D_METHOD("get_height", "global_position"), &Terrain3DData::get_height);
	ClassDB::bind_method(D_METHOD("set_color", "global_position", "color"), &Terrain3DData::set_color);
	ClassDB::bind_method(D_METHOD("get_color", "global_position"), &Terrain3DData::get_color);
	ClassDB::bind_method(D_METHOD("set_control", "global_position", "control"), &Terrain3DData::set_control);
	ClassDB::bind_method(D_METHOD("get_control", "global_position"), &Terrain3DData::get_control);
	ClassDB::bind_method(D_METHOD("set_roughness", "global_position", "roughness"), &Terrain3DData::set_roughness);
	ClassDB::bind_method(D_METHOD("get_roughness", "global_position"), &Terrain3DData::get_roughness);

	ClassDB::bind_method(D_METHOD("set_control_base_id", "global_position", "texture_id"), &Terrain3DData::set_control_base_id);
	ClassDB::bind_method(D_METHOD("get_control_base_id", "global_position"), &Terrain3DData::get_control_base_id);
	ClassDB::bind_method(D_METHOD("set_control_overlay_id", "global_position", "texture_id"), &Terrain3DData::set_control_overlay_id);
	ClassDB::bind_method(D_METHOD("get_control_overlay_id", "global_position"), &Terrain3DData::get_control_overlay_id);
	ClassDB::bind_method(D_METHOD("set_control_blend", "global_position", "blend_value"), &Terrain3DData::set_control_blend);
	ClassDB::bind_method(D_METHOD("get_control_blend", "global_position"), &Terrain3DData::get_control_blend);
	ClassDB::bind_method(D_METHOD("set_control_angle", "global_position", "degrees"), &Terrain3DData::set_control_angle);
	ClassDB::bind_method(D_METHOD("get_control_angle", "global_position"), &Terrain3DData::get_control_angle);
	ClassDB::bind_method(D_METHOD("set_control_scale", "global_position", "percentage_modifier"), &Terrain3DData::set_control_scale);
	ClassDB::bind_method(D_METHOD("get_control_scale", "global_position"), &Terrain3DData::get_control_scale);
	ClassDB::bind_method(D_METHOD("set_control_hole", "global_position", "enable"), &Terrain3DData::set_control_hole);
	ClassDB::bind_method(D_METHOD("get_control_hole", "global_position"), &Terrain3DData::get_control_hole);
	ClassDB::bind_method(D_METHOD("set_control_navigation", "global_position", "enable"), &Terrain3DData::set_control_navigation);
	ClassDB::bind_method(D_METHOD("get_control_navigation", "global_position"), &Terrain3DData::get_control_navigation);
	ClassDB::bind_method(D_METHOD("set_control_auto", "global_position", "enable"), &Terrain3DData::set_control_auto);
	ClassDB::bind_method(D_METHOD("get_control_auto", "global_position"), &Terrain3DData::get_control_auto);

	ClassDB::bind_method(D_METHOD("get_normal", "global_position"), &Terrain3DData::get_normal);
	ClassDB::bind_method(D_METHOD("is_in_slope", "global_position", "slope_range", "normal"), &Terrain3DData::is_in_slope, DEFVAL(V3_ZERO));
	ClassDB::bind_method(D_METHOD("get_texture_id", "global_position"), &Terrain3DData::get_texture_id);
	ClassDB::bind_method(D_METHOD("get_mesh_vertex", "lod", "filter", "global_position"), &Terrain3DData::get_mesh_vertex);

	ClassDB::bind_method(D_METHOD("get_height_range"), &Terrain3DData::get_height_range);
	ClassDB::bind_method(D_METHOD("calc_height_range", "recursive"), &Terrain3DData::calc_height_range, DEFVAL(false));

	ClassDB::bind_method(D_METHOD("import_images", "images", "global_position", "offset", "scale"), &Terrain3DData::import_images, DEFVAL(V3_ZERO), DEFVAL(0.f), DEFVAL(1.f));
	ClassDB::bind_method(D_METHOD("export_image", "file_name", "map_type"), &Terrain3DData::export_image);
	ClassDB::bind_method(D_METHOD("layered_to_image", "map_type"), &Terrain3DData::layered_to_image);
	ClassDB::bind_method(D_METHOD("dump", "verbose"), &Terrain3DData::dump, DEFVAL(false));

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
}
