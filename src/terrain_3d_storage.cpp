// Copyright © 2024 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/editor_file_system.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/resource_saver.hpp>
#include <godot_cpp/classes/time.hpp>

#include "logger.h"
#include "terrain_3d_storage.h"

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3DStorage::_clear() {
	LOG(INFO, "Clearing storage");
	_region_map_dirty = true;
	_region_map.clear();
	_regions.clear();
	_generated_height_maps.clear();
	_generated_control_maps.clear();
	_generated_color_maps.clear();
	set_multimeshes(Dictionary()); // Sends a signal to the instancer
}

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DStorage::initialize(Terrain3D *p_terrain) {
	if (p_terrain == nullptr) {
		LOG(ERROR, "Initialization failed, p_terrain is null");
		return;
	}
	LOG(INFO, "Initializing storage");
	bool initialized = _terrain != nullptr;
	_terrain = p_terrain;
	_region_map.resize(REGION_MAP_SIZE * REGION_MAP_SIZE);
	_mesh_vertex_spacing = _terrain->get_mesh_vertex_spacing();
	if (!initialized && !_terrain->get_storage_directory().is_empty()) {
		load_directory(_terrain->get_storage_directory());
	}
}

void Terrain3DStorage::set_height_range(const Vector2 &p_range) {
	LOG(INFO, vformat("%.2v", p_range));
	_height_range = p_range;
}

// TODO: _height_range should move to Terrain3D, or the next 3 functions should move
// to individual Regions and AABBs are updated from loaded regions.
// modified might be edited only by the editor
void Terrain3DStorage::update_heights(const real_t p_height) {
	if (p_height < _height_range.x) {
		_height_range.x = p_height;
		//_modified = true;
	} else if (p_height > _height_range.y) {
		_height_range.y = p_height;
		//_modified = true;
	}
	//if (_modified) {
	//	LOG(DEBUG_CONT, "Expanded height range: ", _height_range);
	//}
}

void Terrain3DStorage::update_heights(const Vector2 &p_heights) {
	if (p_heights.x < _height_range.x) {
		_height_range.x = p_heights.x;
		//_modified = true;
	}
	if (p_heights.y > _height_range.y) {
		_height_range.y = p_heights.y;
		//_modified = true;
	}
	//if (_modified) {
	//	LOG(DEBUG_CONT, "Expanded height range: ", _height_range);
	//}
}

void Terrain3DStorage::update_height_range() {
	_height_range = Vector2(0.f, 0.f);
	for (int i = 0; i < _height_maps.size(); i++) {
		update_heights(Util::get_min_max(_height_maps[i]));
	}
	LOG(INFO, "Recalculated terrain height range: ", _height_range);
}

void Terrain3DStorage::clear_edited_area() {
	_edited_area = AABB();
}

void Terrain3DStorage::add_edited_area(const AABB &p_area) {
	if (_edited_area.has_surface()) {
		_edited_area = _edited_area.merge(p_area);
	} else {
		_edited_area = p_area;
	}
	emit_signal("maps_edited", _edited_area);
}

Ref<Terrain3DRegion> Terrain3DStorage::get_region(const Vector2i &p_region_loc) {
	return _regions.get(p_region_loc, Ref<Terrain3DRegion>());
}

void Terrain3DStorage::set_region_modified(const Vector2i &p_region_loc, const bool p_modified) {
	Ref<Terrain3DRegion> region = _regions.get(p_region_loc, Ref<Terrain3DRegion>());
	if (region.is_null()) {
		LOG(ERROR, "Region not found at: ", p_region_loc);
		return;
	}
	return region->set_modified(p_modified);
}

bool Terrain3DStorage::get_region_modified(const Vector2i &p_region_loc) const {
	Ref<Terrain3DRegion> region = _regions.get(p_region_loc, Ref<Terrain3DRegion>());
	if (region.is_null()) {
		LOG(ERROR, "Region not found at: ", p_region_loc);
		return false;
	}
	return region->is_modified();
}

void Terrain3DStorage::set_region_size(const RegionSize p_size) {
	LOG(INFO, p_size);
	//ERR_FAIL_COND(p_size < SIZE_64);
	//ERR_FAIL_COND(p_size > SIZE_2048);
	ERR_FAIL_COND(p_size != SIZE_1024);
	_region_size = p_size;
	_region_sizev = Vector2i(_region_size, _region_size);
	emit_signal("region_size_changed", _region_size);
}

void Terrain3DStorage::set_region_locations(const TypedArray<Vector2i> &p_locations) {
	LOG(INFO, "Setting _region_locations with array sized: ", p_locations.size());
	_region_locations = p_locations;
	_region_map_dirty = true;
	update_maps();
}

/** Returns a region location given a global position. No bounds checking*/
Vector2i Terrain3DStorage::get_region_location(const Vector3 &p_global_position) const {
	Vector3 descaled_position = p_global_position / _mesh_vertex_spacing;
	return Vector2i((Vector2(descaled_position.x, descaled_position.z) / real_t(_region_size)).floor());
}

// Returns Vector2i(2147483647) if out of range
Vector2i Terrain3DStorage::get_region_location_from_id(const int p_region_id) const {
	if (p_region_id < 0 || p_region_id >= _region_locations.size()) {
		return Vector2i(INT32_MAX, INT32_MAX);
	}
	return _region_locations[p_region_id];
}

int Terrain3DStorage::get_region_id(const Vector3 &p_global_position) const {
	Vector2i region_loc = get_region_location(p_global_position);
	return get_region_id_from_location(region_loc);
}

// Returns -1 if out of bounds, 0 if no region, or region id
int Terrain3DStorage::get_region_id_from_location(const Vector2i &p_region_loc) const {
	int map_index = _get_region_map_index(p_region_loc);
	if (map_index >= 0) {
		int region_id = _region_map[map_index] - 1; // 0 = no region
		if (region_id >= 0 && region_id < _region_locations.size()) {
			return region_id;
		}
	}
	return -1;
}

/** Adds a region to the terrain
 * Option to include an array of Images to use for maps
 * Map types are Height:0, Control:1, Color:2, defined in MapType
 * If the region already exists and maps are included, the current maps will be overwritten
 * Parameters:
 *	p_global_position - the world location to place the region, rounded down to the nearest region_size multiple
 *	p_images - Optional array of [ Height, Control, Color ... ] w/ region_sized images
 *	p_update - rebuild the maps if true. Set to false if bulk adding many regions.
 */
Error Terrain3DStorage::add_region(const Vector3 &p_global_position, const TypedArray<Image> &p_images, const bool p_update, const String &p_path) {
	IS_INIT_MESG("Storage not initialized", FAILED);
	Vector2i region_loc = get_region_location(p_global_position);
	LOG(INFO, "Adding region at ", p_global_position, ", region_loc ", region_loc,
			", array size: ", p_images.size(),
			", update maps: ", p_update ? "yes" : "no");

	if (_get_region_map_index(region_loc) < 0) {
		uint64_t time = Time::get_singleton()->get_ticks_msec();
		if (time - _last_region_bounds_error > 1000) {
			_last_region_bounds_error = time;
			LOG(ERROR, "Specified position outside of maximum region map size: +/-",
					real_t((REGION_MAP_SIZE / 2) * _region_size) * _mesh_vertex_spacing);
		}
		return FAILED;
	}

	if (has_region(p_global_position)) {
		if (p_images.is_empty()) {
			LOG(DEBUG, "Region at ", p_global_position, " already exists and nothing to overwrite. Doing nothing");
			return OK;
		} else {
			LOG(DEBUG, "Region at ", p_global_position, " already exists, overwriting");
			remove_region(p_global_position, false, p_path);
		}
	}

	TypedArray<Image> images = sanitize_maps(TYPE_MAX, p_images);
	if (images.is_empty()) {
		LOG(ERROR, "Sanitize_maps failed to accept images or produce blanks");
		return FAILED;
	}

	// If we're importing data into a region, check its heights for aabbs
	Vector2 min_max = Vector2(0.f, 0.f);
	if (p_images.size() > TYPE_HEIGHT) {
		min_max = Util::get_min_max(images[TYPE_HEIGHT]);
		LOG(DEBUG, "Checking imported height range: ", min_max);
		update_heights(min_max);
	}

	LOG(DEBUG, "Pushing back ", images.size(), " images");
	_height_maps.push_back(images[TYPE_HEIGHT]);
	_control_maps.push_back(images[TYPE_CONTROL]);
	_color_maps.push_back(images[TYPE_COLOR]);
	_region_locations.push_back(region_loc);
	LOG(DEBUG, "Total regions after pushback: ", _region_locations.size());

	// Region_map is used by get_region_id so must be updated every time
	_region_map_dirty = true;
	if (!_loading) {
		if (p_update) {
			//notify_property_list_changed();
			//emit_changed();
			force_update_maps();
		} else {
			update_maps();
		}
	}
	return OK;
}

void Terrain3DStorage::remove_region(const Vector3 &p_global_position, const bool p_update, const String &p_path) {
	LOG(INFO, "Removing region at ", p_global_position, " Updating: ", p_update ? "yes" : "no");
	int region_id = get_region_id(p_global_position);
	ERR_FAIL_COND_MSG(region_id == -1, "Position out of bounds");
	remove_region_by_id(region_id, p_update, p_path);
}

void Terrain3DStorage::remove_region_by_id(const int p_region_id, const bool p_update, const String &p_path) {
	ERR_FAIL_COND_MSG(p_region_id == -1 || p_region_id >= _region_locations.size(), "Region id out of bounds.");
	String fname = Util::location_to_filename(_region_locations[p_region_id]);
	LOG(INFO, "Removing region at: ", p_region_id);
	_region_locations.remove_at(p_region_id);
	LOG(DEBUG, "Removed region_locations, new size: ", _region_locations.size());
	_height_maps.remove_at(p_region_id);
	LOG(DEBUG, "Removed heightmaps, new size: ", _height_maps.size());
	_control_maps.remove_at(p_region_id);
	LOG(DEBUG, "Removed control maps, new size: ", _control_maps.size());
	_color_maps.remove_at(p_region_id);
	LOG(DEBUG, "Removed colormaps, new size: ", _color_maps.size());

	if (p_path != "") {
		Ref<DirAccess> da = DirAccess::open(p_path);
		da->remove(fname);
		if (Engine::get_singleton()->is_editor_hint()) {
			EditorInterface::get_singleton()->get_resource_filesystem()->scan();
		}
	}

	if (_height_maps.size() == 0) {
		_height_range = Vector2(0.f, 0.f);
	}

	// Region_map is used by get_region_id so must be updated
	_region_map_dirty = true;
	if (p_update) {
		LOG(DEBUG, "Updating generated maps");
		_generated_height_maps.clear();
		_generated_control_maps.clear();
		_generated_color_maps.clear();
		update_maps();
		notify_property_list_changed();
		//emit_changed(); //! FIXME - (needs to be consistent w/ add_regions
	} else {
		update_maps();
	}
}

void Terrain3DStorage::update_maps() {
	bool any_changed = false;
	if (_generated_height_maps.is_dirty()) {
		LOG(DEBUG_CONT, "Regenerating height layered texture from ", _height_maps.size(), " maps");
		_generated_height_maps.create(_height_maps);
		any_changed = true;
		emit_signal("height_maps_changed");
	}

	if (_generated_control_maps.is_dirty()) {
		LOG(DEBUG_CONT, "Regenerating control layered texture from ", _control_maps.size(), " maps");
		_generated_control_maps.create(_control_maps);
		any_changed = true;
		emit_signal("control_maps_changed");
	}

	if (_generated_color_maps.is_dirty()) {
		LOG(DEBUG_CONT, "Regenerating color layered texture from ", _color_maps.size(), " maps");
		for (int i = 0; i < _color_maps.size(); i++) {
			Ref<Image> map = _color_maps[i];
			map->generate_mipmaps();
		}
		_generated_color_maps.create(_color_maps);
		any_changed = true;
		emit_signal("color_maps_changed");
	}

	if (_region_map_dirty) {
		LOG(DEBUG_CONT, "Regenerating ", REGION_MAP_VSIZE, " region map array");
		_region_map.clear();
		_region_map.resize(REGION_MAP_SIZE * REGION_MAP_SIZE);
		_region_map_dirty = false;
		for (int i = 0; i < _region_locations.size(); i++) {
			int map_index = _get_region_map_index(_region_locations[i]);
			if (map_index >= 0) {
				_region_map[map_index] = i + 1; // Begin at 1 since 0 = no region
			}
		}
		any_changed = true;
		emit_signal("region_map_changed");
	}
	if (any_changed) {
		emit_signal("maps_changed");
	}
}

void Terrain3DStorage::save_region(const String &p_dir, const Vector2i &p_region_loc, const bool p_16_bit) {
	Ref<Terrain3DRegion> region = _regions[p_region_loc];
	// looks like get isn't required
	if (region.is_null()) {
		LOG(ERROR, "No region at: ", p_region_loc);
		// need to create it
		return;
	}
	String fname = Util::location_to_filename(p_region_loc);
	String path = p_dir + String("/") + fname;
	LOG(INFO, "Saving file: ", fname, " location: ", p_region_loc);
	region->save(path, p_16_bit);
}

void Terrain3DStorage::load_region(const String &p_dir, const Vector2i &p_region_loc) {
	LOG(INFO, "Loading region from location ", p_region_loc);
	String path = p_dir + String("/") + Util::location_to_filename(p_region_loc);
	Ref<Terrain3DRegion> region = ResourceLoader::get_singleton()->load(path,
			"Terrain3DRegion", ResourceLoader::CACHE_MODE_IGNORE);
	if (region.is_null()) {
		LOG(ERROR, "Could not load region at ", path, " at location", p_region_loc);
		return;
	}
	register_region(region, p_region_loc);
}

void Terrain3DStorage::register_region(const Ref<Terrain3DRegion> &p_region, const Vector2i &p_region_loc) {
	Vector3 global_position = Vector3(_region_size * p_region_loc.x, 0.0f, _region_size * p_region_loc.y);
	TypedArray<Image> maps = TypedArray<Image>();
	maps.resize(3);
	if (p_region->get_height_map().is_valid()) {
		maps[0] = p_region->get_height_map()->duplicate();
	}
	if (p_region->get_control_map().is_valid()) {
		maps[1] = p_region->get_control_map()->duplicate();
	}
	if (p_region->get_color_map().is_valid()) {
		maps[2] = p_region->get_color_map()->duplicate();
	}
	// 3 - Add to region map
	add_region(global_position, maps);

	// Store region
	p_region->set_region_loc(p_region_loc);
	LOG(INFO, "Registered region ", p_region->get_path(), " at ", p_region->get_region_loc(), " - ", p_region_loc);
	_regions[p_region_loc] = p_region;
}

TypedArray<int> Terrain3DStorage::get_regions_under_aabb(const AABB &p_aabb) {
	TypedArray<int> found = TypedArray<int>();
	// Step 1: Calculate how many region tiles are under the AABB
	Vector2 start = Vector2(p_aabb.get_position().x, p_aabb.get_position().y);
	real_t size_x = p_aabb.get_size().x;
	real_t size_y = p_aabb.get_size().y;
	LOG(INFO, "AABB: ", p_aabb);
	real_t rcx = size_x / _region_size;
	real_t rcy = size_y / _region_size;
	LOG(INFO, "rcx ", rcx, " rcy ", rcy);
	// This ternary avoids the edge case of the AABB being exactly on the region boundaries
	int region_count_x = godot::Math::is_equal_approx(godot::Math::fract(rcx), 0.0f) ? (int)(rcx) : (int)ceilf(rcx);
	int region_count_y = godot::Math::is_equal_approx(godot::Math::fract(rcy), 0.0f) ? (int)(rcy) : (int)ceilf(rcy);
	LOG(INFO, "Region counts: x ", region_count_x, " y ", region_count_y);
	// Step 2: Check under every region point
	// Using ceil and min may seem like an odd choice, but it will snap the checking bounds to the edges of the AABB,
	// ensuring that it also hits regions partially covered by the AABB
	for (int i = 0; i < region_count_x; i++) {
		real_t x = start.x + godot::Math::min((real_t)(i * _region_size), size_x);
		for (int j = 0; j < region_count_y; j++) {
			real_t y = start.y + godot::Math::min((real_t)(j * _region_size), size_y);
			int region_id = get_region_id(Vector3(x, 0, y));
			LOG(INFO, "Region id ", region_id, " location ", Vector3(x, 0, y));
			// If found, push_back to array
			if (region_id != -1) {
				found.push_back(region_id);
			}
		}
	}
	return found;
}

void Terrain3DStorage::set_map_region(const MapType p_map_type, const int p_region_id, const Ref<Image> &p_image) {
	switch (p_map_type) {
		case TYPE_HEIGHT:
			if (p_region_id >= 0 && p_region_id < _height_maps.size()) {
				_height_maps[p_region_id] = p_image;
				force_update_maps(TYPE_HEIGHT);
			} else {
				LOG(ERROR, "Requested region id is out of bounds. height_maps size: ", _height_maps.size());
			}
			break;
		case TYPE_CONTROL:
			if (p_region_id >= 0 && p_region_id < _control_maps.size()) {
				_control_maps[p_region_id] = p_image;
				force_update_maps(TYPE_CONTROL);
			} else {
				LOG(ERROR, "Requested region id is out of bounds. control_maps size: ", _control_maps.size());
			}
			break;
		case TYPE_COLOR:
			if (p_region_id >= 0 && p_region_id < _color_maps.size()) {
				_color_maps[p_region_id] = p_image;
				force_update_maps(TYPE_COLOR);
			} else {
				LOG(ERROR, "Requested region id is out of bounds. color_maps size: ", _color_maps.size());
			}
			break;
		default:
			LOG(ERROR, "Requested map type is invalid");
			break;
	}
}

Ref<Image> Terrain3DStorage::get_map_region(const MapType p_map_type, const int p_region_id) const {
	switch (p_map_type) {
		case TYPE_HEIGHT:
			if (p_region_id >= 0 && p_region_id < _height_maps.size()) {
				return _height_maps[p_region_id];
			} else {
				LOG(ERROR, "Requested region id is out of bounds. height_maps size: ", _height_maps.size());
			}
			break;
		case TYPE_CONTROL:
			if (p_region_id >= 0 && p_region_id < _control_maps.size()) {
				return _control_maps[p_region_id];
			} else {
				LOG(ERROR, "Requested region id is out of bounds. control_maps size: ", _control_maps.size());
			}
			break;
		case TYPE_COLOR:
			if (p_region_id >= 0 && p_region_id < _color_maps.size()) {
				return _color_maps[p_region_id];
			} else {
				LOG(ERROR, "Requested region id is out of bounds. color_maps size: ", _color_maps.size());
			}
			break;
		default:
			LOG(ERROR, "Requested map type is invalid");
			break;
	}
	return Ref<Image>();
}

void Terrain3DStorage::set_maps(const MapType p_map_type, const TypedArray<Image> &p_maps, const TypedArray<int> &p_region_ids) {
	ERR_FAIL_COND_MSG(p_map_type < 0 || p_map_type >= TYPE_MAX, "Specified map type out of range");
	if (p_region_ids.is_empty()) {
		LOG(INFO, "Setting ", TYPESTR[p_map_type], " maps: ", p_maps.size());
		switch (p_map_type) {
			case TYPE_HEIGHT:
				_height_maps = sanitize_maps(TYPE_HEIGHT, p_maps);
				break;
			case TYPE_CONTROL:
				_control_maps = sanitize_maps(TYPE_CONTROL, p_maps);
				break;
			case TYPE_COLOR:
				_color_maps = sanitize_maps(TYPE_COLOR, p_maps);
				break;
			default:
				break;
		}
	} else {
		TypedArray<Image> sanitized = sanitize_maps(p_map_type, p_maps);
		for (int i = 0; i < p_region_ids.size(); i++) {
			switch (p_map_type) {
				case TYPE_HEIGHT:
					_height_maps[p_region_ids[i]] = sanitized[i];
					break;
				case TYPE_CONTROL:
					_control_maps[p_region_ids[i]] = sanitized[i];
					break;
				case TYPE_COLOR:
					_color_maps[p_region_ids[i]] = sanitized[i];
					break;
				default:
					break;
			}
		}
	}
	force_update_maps(p_map_type);
}

TypedArray<Image> Terrain3DStorage::get_maps(const MapType p_map_type) const {
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

TypedArray<Image> Terrain3DStorage::get_maps_copy(const MapType p_map_type, const TypedArray<int> &p_region_ids) const {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return TypedArray<Image>();
	}
	TypedArray<Image> maps = get_maps(p_map_type);
	TypedArray<Image> newmaps;
	if (p_region_ids.is_empty()) {
		newmaps.resize(maps.size());
		for (int i = 0; i < maps.size(); i++) {
			Ref<Image> img;
			img.instantiate();
			img->copy_from(maps[i]);
			newmaps[i] = img;
		}
	} else {
		newmaps.resize(p_region_ids.size());
		for (int i = 0; i < p_region_ids.size(); i++) {
			Ref<Image> img;
			img.instantiate();
			img->copy_from(maps[p_region_ids[i]]);
			newmaps[i] = img;
		}
	}
	return newmaps;
}

void Terrain3DStorage::set_pixel(const MapType p_map_type, const Vector3 &p_global_position, const Color &p_pixel) {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return;
	}
	int region_id = get_region_id(p_global_position);
	if (region_id < 0) {
		return;
	}
	Vector2i region_loc = _region_locations[region_id];
	Vector2i global_offset = region_loc * _region_size;
	Vector3 descaled_pos = p_global_position / _mesh_vertex_spacing;
	Vector2i img_pos = Vector2i(descaled_pos.x - global_offset.x, descaled_pos.z - global_offset.y);
	img_pos = img_pos.clamp(Vector2i(), Vector2i(_region_size - 1, _region_size - 1));
	Ref<Image> map = get_map_region(p_map_type, region_id);
	map->set_pixelv(img_pos, p_pixel);
	set_region_modified(region_loc, true);
}

Color Terrain3DStorage::get_pixel(const MapType p_map_type, const Vector3 &p_global_position) const {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return COLOR_NAN;
	}
	int region_id = get_region_id(p_global_position);
	if (region_id < 0) {
		return COLOR_NAN;
	}
	Vector2i region_loc = _region_locations[region_id];
	Vector2i global_offset = region_loc * _region_size;
	Vector3 descaled_pos = p_global_position / _mesh_vertex_spacing;
	Vector2i img_pos = Vector2i(descaled_pos.x - global_offset.x, descaled_pos.z - global_offset.y);
	img_pos = img_pos.clamp(Vector2i(), Vector2i(_region_size - 1, _region_size - 1));
	Ref<Image> map = get_map_region(p_map_type, region_id);
	return map->get_pixelv(img_pos);
}

real_t Terrain3DStorage::get_height(const Vector3 &p_global_position) const {
	if (is_hole(get_control(p_global_position))) {
		return NAN;
	}
	Vector3 pos = p_global_position;
	const real_t &step = _mesh_vertex_spacing;
	pos.y = 0.f;
	// Round to nearest vertex
	Vector3 pos_round = Vector3(round_multiple(pos.x, step), 0.f, round_multiple(pos.z, step));
	// If requested position is close to a vertex, return its height
	if ((pos - pos_round).length() < 0.01f) {
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
Vector3 Terrain3DStorage::get_texture_id(const Vector3 &p_global_position) const {
	// Verify in a region
	int region_id = get_region_id(p_global_position);
	if (region_id < 0) {
		return Vector3(NAN, NAN, NAN);
	}

	// Verify not in a hole
	float src = get_pixel(TYPE_CONTROL, p_global_position).r; // 32-bit float, not double/real
	if (is_hole(src)) {
		return Vector3(NAN, NAN, NAN);
	}

	// If material available, autoshader enabled, and pixel set to auto
	if (_terrain != nullptr) {
		Ref<Terrain3DMaterial> t_material = _terrain->get_material();
		bool auto_enabled = t_material->get_auto_shader();
		bool control_auto = is_auto(src);
		if (auto_enabled && control_auto) {
			real_t auto_slope = real_t(t_material->get_shader_param("auto_slope")) * 2.f - 1.f;
			real_t auto_height_reduction = real_t(t_material->get_shader_param("auto_height_reduction"));
			real_t height = get_height(p_global_position);
			Vector3 normal = get_normal(p_global_position);
			uint32_t base_id = t_material->get_shader_param("auto_base_texture");
			uint32_t overlay_id = t_material->get_shader_param("auto_overlay_texture");
			real_t blend = CLAMP(
					vec3_dot(Vector3(0.f, 1.f, 0.f),
							normal * auto_slope * 2.f - Vector3(auto_slope, auto_slope, auto_slope)) -
							auto_height_reduction * .01f * height,
					0.f, 1.f);
			return Vector3(real_t(base_id), real_t(overlay_id), blend);
		}
	}

	// Else, just get textures from control map
	uint32_t base_id = get_base(src);
	uint32_t overlay_id = get_overlay(src);
	real_t blend = real_t(get_blend(src)) / 255.0f;
	return Vector3(real_t(base_id), real_t(overlay_id), blend);
}

real_t Terrain3DStorage::get_angle(const Vector3 &p_global_position) const {
	float src = get_pixel(TYPE_CONTROL, p_global_position).r; // Must be 32-bit float, not double/real
	if (std::isnan(src)) {
		return NAN;
	}
	real_t angle = real_t(get_uv_rotation(src));
	angle *= 22.5; // Return value in degrees.
	return real_t(angle);
}

real_t Terrain3DStorage::get_scale(const Vector3 &p_global_position) const {
	float src = get_pixel(TYPE_CONTROL, p_global_position).r; // Must be 32-bit float, not double/real
	if (std::isnan(src)) {
		return NAN;
	}
	std::array<real_t, 8> scale_values = { 0.0f, 20.0f, 40.0f, 60.0f, 80.0f, -60.0f, -40.0f, -20.0f };
	real_t scale = scale_values[get_uv_scale(src)]; //select from array UI return values
	return real_t(scale);
}

/**
 * Returns sanitized maps of either a region set or a uniform set
 * Verifies size, vailidity, and format of maps
 * Creates filled blanks if lacking
 * p_map_type:
 *	TYPE_HEIGHT, TYPE_CONTROL, TYPE_COLOR: uniform set - p_maps are all the same type, size=N
 *	TYPE_MAX = region set - p_maps is [ height, control, color ], size=3
 **/
TypedArray<Image> Terrain3DStorage::sanitize_maps(const MapType p_map_type, const TypedArray<Image> &p_maps) const {
	LOG(INFO, "Verifying image set is valid: ", p_maps.size(), " maps of type: ", TYPESTR[TYPE_MAX]);

	TypedArray<Image> images;
	int iterations;

	if (p_map_type == TYPE_MAX) {
		images.resize(TYPE_MAX);
		iterations = TYPE_MAX;
	} else {
		images.resize(p_maps.size());
		iterations = p_maps.size();
		if (iterations <= 0) {
			LOG(DEBUG, "Empty Image set. Nothing to sanitize");
			return images;
		}
	}

	Image::Format format;
	const char *type_str;
	Color color;
	for (int i = 0; i < iterations; i++) {
		if (p_map_type == TYPE_MAX) {
			format = FORMAT[i];
			type_str = TYPESTR[i];
			color = COLOR[i];
		} else {
			format = FORMAT[p_map_type];
			type_str = TYPESTR[p_map_type];
			color = COLOR[p_map_type];
		}

		if (i < p_maps.size()) {
			Ref<Image> img;
			img = p_maps[i];
			if (img.is_valid()) {
				if (img->get_size() == _region_sizev) {
					if (img->get_format() == format) {
						LOG(DEBUG, "Map type ", type_str, " correct format, size. Using image");
						images[i] = img;
					} else {
						LOG(DEBUG, "Provided ", type_str, " map wrong format: ", img->get_format(), ". Converting copy to: ", format);
						Ref<Image> newimg;
						newimg.instantiate();
						newimg->copy_from(img);
						newimg->convert(format);
						images[i] = newimg;
					}
					continue; // Continue for loop
				} else {
					LOG(DEBUG, "Provided ", type_str, " map wrong size: ", img->get_size(), ". Creating blank");
				}
			} else {
				LOG(DEBUG, "No provided ", type_str, " map. Creating blank");
			}
		} else {
			LOG(DEBUG, "p_images.size() < ", i, ". Creating blank");
		}
		images[i] = Util::get_filled_image(_region_sizev, color, false, format);
	}

	return images;
}

void Terrain3DStorage::force_update_maps(const MapType p_map_type) {
	LOG(DEBUG_CONT, "Regenerating maps of type: ", p_map_type);
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
			break;
	}
	update_maps();
}

void Terrain3DStorage::set_multimeshes(const Dictionary &p_multimeshes) {
	LOG(INFO, "Loading multimeshes: ", p_multimeshes);
	if (_multimeshes != p_multimeshes) {
		_multimeshes = p_multimeshes;
		emit_signal("multimeshes_changed");
	}
}

void Terrain3DStorage::set_multimeshes(const Dictionary &p_multimeshes, const TypedArray<int> &p_region_ids) {
	if (p_region_ids.is_empty()) {
		_multimeshes = p_multimeshes;
	} else {
		for (int i = 0; i < p_region_ids.size(); i++) {
			_multimeshes[p_region_ids[i]] = p_multimeshes[i];
		}
	}
}

Dictionary Terrain3DStorage::get_multimeshes(const TypedArray<int> &p_region_ids) const {
	if (p_region_ids.is_empty()) {
		return _multimeshes;
	} else {
		Dictionary output = Dictionary();
		for (int i = 0; i < p_region_ids.size(); i++) {
			Vector2i region_loc = get_region_location_from_id(i);
			output[region_loc] = _multimeshes[p_region_ids[i]];
		}
		return output;
	}
}

void Terrain3DStorage::save_directory(const String &p_dir) {
	LOG(INFO, "Saving data files to ", p_dir);
	for (int i = 0; i < _region_locations.size(); i++) {
		save_region(p_dir, _region_locations[i], _terrain->get_save_16_bit());
	}
}

/**
 * Imports an Image set (Height, Control, Color) into Terrain3DStorage
 * It does NOT normalize values to 0-1. You must do that using get_min_max() and adjusting scale and offset.
 * Parameters:
 *	p_images - MapType.TYPE_MAX sized array of Images for Height, Control, Color. Images can be blank or null
 *	p_global_position - X,0,Z location on the region map. Valid range is ~ (+/-8192, +/-8192)
 *	p_offset - Add this factor to all height values, can be negative
 *	p_scale - Scale all height values by this factor (applied after offset)
 */
void Terrain3DStorage::import_images(const TypedArray<Image> &p_images, const Vector3 &p_global_position, const real_t p_offset, const real_t p_scale) {
	IS_INIT_MESG("Storage not initialized", VOID);
	if (p_images.size() != TYPE_MAX) {
		LOG(ERROR, "p_images.size() is ", p_images.size(), ". It should be ", TYPE_MAX, " even if some Images are blank or null");
		return;
	}

	Vector2i img_size = Vector2i(0, 0);
	for (int i = 0; i < TYPE_MAX; i++) {
		Ref<Image> img = p_images[i];
		if (img.is_valid() && !img->is_empty()) {
			LOG(INFO, "Importing image type ", TYPESTR[i], ", size: ", img->get_size(), ", format: ", img->get_format());
			if (i == TYPE_HEIGHT) {
				LOG(INFO, "Applying offset: ", p_offset, ", scale: ", p_scale);
			}
			if (img_size == Vector2i(0, 0)) {
				img_size = img->get_size();
			} else if (img_size != img->get_size()) {
				LOG(ERROR, "Included Images in p_images have different dimensions. Aborting import");
				return;
			}
		}
	}
	if (img_size == Vector2i(0, 0)) {
		LOG(ERROR, "All images are empty. Nothing to import");
		return;
	}

	Vector3 descaled_position = p_global_position / _mesh_vertex_spacing;
	int max_dimension = _region_size * REGION_MAP_SIZE / 2;
	if ((abs(descaled_position.x) > max_dimension) || (abs(descaled_position.z) > max_dimension)) {
		LOG(ERROR, "Specify a position within +/-", Vector3(max_dimension, 0.f, max_dimension) * _mesh_vertex_spacing);
		return;
	}
	if ((descaled_position.x + img_size.x > max_dimension) ||
			(descaled_position.z + img_size.y > max_dimension)) {
		LOG(ERROR, img_size, " image will not fit at ", p_global_position,
				". Try ", -(img_size * _mesh_vertex_spacing) / 2.f, " to center");
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

		// Apply scale and offsets to a new heightmap if applicable
		if (i == TYPE_HEIGHT && (p_offset != 0.f || p_scale != 1.f)) {
			LOG(DEBUG, "Creating new temp image to adjust scale: ", p_scale, " offset: ", p_offset);
			Ref<Image> newimg = Image::create(img->get_size().x, img->get_size().y, false, FORMAT[TYPE_HEIGHT]);
			for (int y = 0; y < img->get_height(); y++) {
				for (int x = 0; x < img->get_width(); x++) {
					Color clr = img->get_pixel(x, y);
					clr.r = (clr.r * p_scale) + p_offset;
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
			Vector2i end_coords = Vector2i((x + 1) * _region_size, (y + 1) * _region_size);
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
			TypedArray<Image> images;
			images.resize(TYPE_MAX);
			for (int i = 0; i < TYPE_MAX; i++) {
				Ref<Image> img = tmp_images[i];
				Ref<Image> img_slice;
				if (img.is_valid() && !img->is_empty()) {
					img_slice = Util::get_filled_image(_region_sizev, COLOR[i], false, img->get_format());
					img_slice->blit_rect(tmp_images[i], Rect2i(start_coords, size_to_copy), Vector2i(0, 0));
				} else {
					img_slice = Util::get_filled_image(_region_sizev, COLOR[i], false, FORMAT[i]);
				}
				images[i] = img_slice;
			}
			// Add the heightmap slice and only regenerate on the last one
			Vector3 position = Vector3(descaled_position.x + start_coords.x, 0.f, descaled_position.z + start_coords.y);
			add_region(position * _mesh_vertex_spacing, images, (x == slices_width - 1 && y == slices_height - 1));
		}
	} // for y < slices_height, x < slices_width
}

/** Exports a specified map as one of r16/raw, exr, jpg, png, webp, res, tres
 * r16 or exr are recommended for roundtrip external editing
 * r16 can be edited by Krita, however you must know the dimensions and min/max before reimporting
 * res/tres allow storage in any of Godot's native Image formats.
 */
Error Terrain3DStorage::export_image(const String &p_file_name, const MapType p_map_type) const {
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

	// Check if the file could be opened for writing
	Ref<FileAccess> file_ref = FileAccess::open(file_name, FileAccess::ModeFlags::WRITE);
	if (file_ref.is_null()) {
		LOG(ERROR, "Could not open file '" + file_name + "' for writing");
		return FAILED;
	}
	file_ref->close();

	// Filename is validated. Begin export image generation
	Ref<Image> img = layered_to_image(p_map_type);
	if (img.is_null() || img->is_empty()) {
		LOG(ERROR, "Could not create an export image for map type: ", TYPESTR[p_map_type]);
		return FAILED;
	}

	String ext = file_name.get_extension().to_lower();
	LOG(MESG, "Saving ", img->get_size(), " sized ", TYPESTR[p_map_type],
			" map in format ", img->get_format(), " as ", ext, " to: ", file_name);
	if (ext == "r16" || ext == "raw") {
		Vector2i minmax = Util::get_min_max(img);
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

Ref<Image> Terrain3DStorage::layered_to_image(const MapType p_map_type) const {
	LOG(INFO, "Generating a full sized image for all regions including empty regions");
	MapType map_type = p_map_type;
	if (map_type >= TYPE_MAX) {
		map_type = TYPE_HEIGHT;
	}
	Vector2i top_left = Vector2i(0, 0);
	Vector2i bottom_right = Vector2i(0, 0);
	for (int i = 0; i < _region_locations.size(); i++) {
		LOG(DEBUG, "Region locations[", i, "]: ", _region_locations[i]);
		Vector2i region_loc = _region_locations[i];
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

	for (int i = 0; i < _region_locations.size(); i++) {
		Vector2i region_loc = _region_locations[i];
		Vector2i img_location = (region_loc - top_left) * _region_size;
		LOG(DEBUG, "Region to blit: ", region_loc, " Export image coords: ", img_location);
		int region_id = get_region_id(Vector3(region_loc.x, 0, region_loc.y) * _region_size);
		img->blit_rect(get_map_region(map_type, region_id), Rect2i(Vector2i(0, 0), _region_sizev), img_location);
	}
	return img;
}

void Terrain3DStorage::load_directory(const String &p_dir) {
	if (p_dir.is_empty()) {
		LOG(ERROR, "Specified data directory is blank");
		return;
	}
	Ref<DirAccess> da = DirAccess::open(p_dir);
	if (da.is_null()) {
		LOG(ERROR, "Cannot read Terrain3D data directory: ", p_dir);
		return;
	}
	LOG(INFO, "Loading region files from ", p_dir);
	_clear();
	_region_map.resize(REGION_MAP_SIZE * REGION_MAP_SIZE);
	_loading = true;
	PackedStringArray files = da->get_files();
	for (int i = 0; i < files.size(); i++) {
		String fname = files[i];
		String path = p_dir + String("/") + fname;
		if (!fname.begins_with("terrain3d") || !fname.ends_with(".res")) {
			continue;
		}
		LOG(DEBUG, "Loading region from ", path);
		Ref<Terrain3DRegion> region = ResourceLoader::get_singleton()->load(
				path, "Terrain3DRegion", ResourceLoader::CACHE_MODE_IGNORE);
		if (region.is_null()) {
			LOG(ERROR, "Region file ", path, " failed to load");
			continue;
		}
		Vector2i loc = Util::filename_to_location(fname);
		if (loc.x == INT32_MAX) {
			LOG(ERROR, "Cannot get region location from file name: ", fname);
			continue;
		}
		LOG(DEBUG, "Region version: ", region->get_version(), " location: ", loc);
		region->set_region_loc(loc);
		region->set_version(CURRENT_VERSION); // Sends upgrade warning if old version
		register_region(region, loc);
	}
	_loading = false;
	force_update_maps();
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
Vector3 Terrain3DStorage::get_mesh_vertex(const int32_t p_lod, const HeightFilter p_filter, const Vector3 &p_global_position) const {
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
					Vector3 position = p_global_position + Vector3(dx, 0.f, dz) * _mesh_vertex_spacing;
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

Vector3 Terrain3DStorage::get_normal(const Vector3 &p_global_position) const {
	if (get_region_id(p_global_position) < 0 || is_hole(get_control(p_global_position))) {
		return Vector3(NAN, NAN, NAN);
	}
	real_t height = get_height(p_global_position);
	real_t u = height - get_height(p_global_position + Vector3(_mesh_vertex_spacing, 0.0f, 0.0f));
	real_t v = height - get_height(p_global_position + Vector3(0.f, 0.f, _mesh_vertex_spacing));
	Vector3 normal = Vector3(u, _mesh_vertex_spacing, v);
	normal.normalize();
	return normal;
}

void Terrain3DStorage::print_audit_data() const {
	LOG(INFO, "Dumping storage data");
	LOG(INFO, "Region_locations size: ", _region_locations.size(), " ", _region_locations);
	LOG(INFO, "Region map");
	for (int i = 0; i < _region_map.size(); i++) {
		if (_region_map[i]) {
			LOG(INFO, "Region id: ", _region_map[i], " array index: ", i);
		}
	}
	Util::dump_maps(_height_maps, "Height maps");
	Util::dump_maps(_control_maps, "Control maps");
	Util::dump_maps(_color_maps, "Color maps");

	Util::dump_gentex(_generated_height_maps, "height");
	Util::dump_gentex(_generated_control_maps, "control");
	Util::dump_gentex(_generated_color_maps, "color");
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DStorage::_bind_methods() {
	BIND_ENUM_CONSTANT(TYPE_HEIGHT);
	BIND_ENUM_CONSTANT(TYPE_CONTROL);
	BIND_ENUM_CONSTANT(TYPE_COLOR);
	BIND_ENUM_CONSTANT(TYPE_MAX);

	//BIND_ENUM_CONSTANT(SIZE_64);
	//BIND_ENUM_CONSTANT(SIZE_128);
	//BIND_ENUM_CONSTANT(SIZE_256);
	//BIND_ENUM_CONSTANT(SIZE_512);
	BIND_ENUM_CONSTANT(SIZE_1024);
	//BIND_ENUM_CONSTANT(SIZE_2048);

	BIND_ENUM_CONSTANT(HEIGHT_FILTER_NEAREST);
	BIND_ENUM_CONSTANT(HEIGHT_FILTER_MINIMUM);

	BIND_CONSTANT(REGION_MAP_SIZE);

	ClassDB::bind_method(D_METHOD("set_height_range", "range"), &Terrain3DStorage::set_height_range);
	ClassDB::bind_method(D_METHOD("get_height_range"), &Terrain3DStorage::get_height_range);
	ClassDB::bind_method(D_METHOD("update_height_range"), &Terrain3DStorage::update_height_range);

	ClassDB::bind_method(D_METHOD("set_region_size", "size"), &Terrain3DStorage::set_region_size);
	ClassDB::bind_method(D_METHOD("get_region_size"), &Terrain3DStorage::get_region_size);
	ClassDB::bind_method(D_METHOD("set_region_locations", "region_locations"), &Terrain3DStorage::set_region_locations);
	ClassDB::bind_method(D_METHOD("get_region_locations"), &Terrain3DStorage::get_region_locations);
	ClassDB::bind_method(D_METHOD("get_region_count"), &Terrain3DStorage::get_region_count);
	ClassDB::bind_method(D_METHOD("get_region_location", "global_position"), &Terrain3DStorage::get_region_location);
	ClassDB::bind_method(D_METHOD("get_region_location_from_id", "region_id"), &Terrain3DStorage::get_region_location_from_id);
	ClassDB::bind_method(D_METHOD("get_region_id", "global_position"), &Terrain3DStorage::get_region_id);
	ClassDB::bind_method(D_METHOD("get_region_id_from_location", "region_location"), &Terrain3DStorage::get_region_id_from_location);
	ClassDB::bind_method(D_METHOD("has_region", "global_position"), &Terrain3DStorage::has_region);
	ClassDB::bind_method(D_METHOD("add_region", "global_position", "images", "update", "path"), &Terrain3DStorage::add_region,
			DEFVAL(TypedArray<Image>()), DEFVAL(true), DEFVAL(""));
	ClassDB::bind_method(D_METHOD("remove_region", "global_position", "update"), &Terrain3DStorage::remove_region, DEFVAL(true));

	ClassDB::bind_method(D_METHOD("save_directory", "directory"), &Terrain3DStorage::save_directory);
	ClassDB::bind_method(D_METHOD("load_directory", "directory"), &Terrain3DStorage::load_directory);
	ClassDB::bind_method(D_METHOD("save_region", "directory", "region_location"), &Terrain3DStorage::save_region);
	ClassDB::bind_method(D_METHOD("load_region", "directory", "region_location"), &Terrain3DStorage::load_region);
	ClassDB::bind_method(D_METHOD("register_region", "region", "region_location"), &Terrain3DStorage::register_region);

	ClassDB::bind_method(D_METHOD("set_map_region", "map_type", "region_id", "image"), &Terrain3DStorage::set_map_region);
	ClassDB::bind_method(D_METHOD("get_map_region", "map_type", "region_id"), &Terrain3DStorage::get_map_region);
	ClassDB::bind_method(D_METHOD("set_maps", "map_type", "maps"), &Terrain3DStorage::set_maps);
	ClassDB::bind_method(D_METHOD("get_maps", "map_type"), &Terrain3DStorage::get_maps);
	ClassDB::bind_method(D_METHOD("get_maps_copy", "map_type"), &Terrain3DStorage::get_maps_copy);
	ClassDB::bind_method(D_METHOD("set_height_maps", "maps"), &Terrain3DStorage::set_height_maps);
	ClassDB::bind_method(D_METHOD("get_height_maps"), &Terrain3DStorage::get_height_maps);
	ClassDB::bind_method(D_METHOD("set_control_maps", "maps"), &Terrain3DStorage::set_control_maps);
	ClassDB::bind_method(D_METHOD("get_control_maps"), &Terrain3DStorage::get_control_maps);
	ClassDB::bind_method(D_METHOD("set_color_maps", "maps"), &Terrain3DStorage::set_color_maps);
	ClassDB::bind_method(D_METHOD("get_color_maps"), &Terrain3DStorage::get_color_maps);
	ClassDB::bind_method(D_METHOD("get_height_maps_rid"), &Terrain3DStorage::get_height_maps_rid);
	ClassDB::bind_method(D_METHOD("get_control_maps_rid"), &Terrain3DStorage::get_control_maps_rid);
	ClassDB::bind_method(D_METHOD("get_color_maps_rid"), &Terrain3DStorage::get_color_maps_rid);
	ClassDB::bind_method(D_METHOD("set_pixel", "map_type", "global_position", "pixel"), &Terrain3DStorage::set_pixel);
	ClassDB::bind_method(D_METHOD("get_pixel", "map_type", "global_position"), &Terrain3DStorage::get_pixel);
	ClassDB::bind_method(D_METHOD("set_height", "global_position", "height"), &Terrain3DStorage::set_height);
	ClassDB::bind_method(D_METHOD("get_height", "global_position"), &Terrain3DStorage::get_height);
	ClassDB::bind_method(D_METHOD("set_color", "global_position", "color"), &Terrain3DStorage::set_color);
	ClassDB::bind_method(D_METHOD("get_color", "global_position"), &Terrain3DStorage::get_color);
	ClassDB::bind_method(D_METHOD("set_control", "global_position", "control"), &Terrain3DStorage::set_control);
	ClassDB::bind_method(D_METHOD("get_control", "global_position"), &Terrain3DStorage::get_control);
	ClassDB::bind_method(D_METHOD("set_roughness", "global_position", "roughness"), &Terrain3DStorage::set_roughness);
	ClassDB::bind_method(D_METHOD("get_roughness", "global_position"), &Terrain3DStorage::get_roughness);
	ClassDB::bind_method(D_METHOD("get_texture_id", "global_position"), &Terrain3DStorage::get_texture_id);
	ClassDB::bind_method(D_METHOD("get_angle", "global_position"), &Terrain3DStorage::get_angle);
	ClassDB::bind_method(D_METHOD("get_scale", "global_position"), &Terrain3DStorage::get_scale);
	ClassDB::bind_method(D_METHOD("force_update_maps", "map_type"), &Terrain3DStorage::force_update_maps, DEFVAL(TYPE_MAX));

	//ClassDB::bind_method(D_METHOD("set_multimeshes", "multimeshes"), &Terrain3DStorage::set_multimeshes);
	//ClassDB::bind_method(D_METHOD("get_multimeshes"), &Terrain3DStorage::get_multimeshes);

	ClassDB::bind_method(D_METHOD("import_images", "images", "global_position", "offset", "scale"), &Terrain3DStorage::import_images, DEFVAL(Vector3(0, 0, 0)), DEFVAL(0.0), DEFVAL(1.0));
	ClassDB::bind_method(D_METHOD("export_image", "file_name", "map_type"), &Terrain3DStorage::export_image);
	ClassDB::bind_method(D_METHOD("layered_to_image", "map_type"), &Terrain3DStorage::layered_to_image);

	ClassDB::bind_method(D_METHOD("get_mesh_vertex", "lod", "filter", "global_position"), &Terrain3DStorage::get_mesh_vertex);
	ClassDB::bind_method(D_METHOD("get_normal", "global_position"), &Terrain3DStorage::get_normal);

	int ro_flags = PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY;
	//ADD_PROPERTY(PropertyInfo(Variant::INT, "region_size", PROPERTY_HINT_ENUM, "64:64, 128:128, 256:256, 512:512, 1024:1024, 2048:2048"), "set_region_size", "get_region_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "region_size", PROPERTY_HINT_ENUM, "1024:1024"), "set_region_size", "get_region_size");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "height_range", PROPERTY_HINT_NONE, "", ro_flags), "set_height_range", "get_height_range");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "region_locations", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::VECTOR2, PROPERTY_HINT_NONE), ro_flags), "set_region_locations", "get_region_locations");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "height_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image"), ro_flags), "set_height_maps", "get_height_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "control_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image"), ro_flags), "set_control_maps", "get_control_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "color_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image"), ro_flags), "set_color_maps", "get_color_maps");
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "multimeshes", PROPERTY_HINT_NONE, "", ro_flags), "set_multimeshes", "get_multimeshes");

	ADD_SIGNAL(MethodInfo("maps_changed"));
	ADD_SIGNAL(MethodInfo("region_map_changed"));
	ADD_SIGNAL(MethodInfo("height_maps_changed"));
	ADD_SIGNAL(MethodInfo("control_maps_changed"));
	ADD_SIGNAL(MethodInfo("color_maps_changed"));
	ADD_SIGNAL(MethodInfo("region_size_changed"));
	ADD_SIGNAL(MethodInfo("maps_edited", PropertyInfo(Variant::AABB, "edited_area")));
	ADD_SIGNAL(MethodInfo("multimeshes_changed"));
}
