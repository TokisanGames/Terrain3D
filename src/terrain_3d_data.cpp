// Copyright © 2024 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/editor_file_system.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/resource_saver.hpp>

#include "logger.h"
#include "terrain_3d_data.h"

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3DData::_clear() {
	LOG(INFO, "Clearing storage");
	_region_map_dirty = true;
	_region_map.clear();
	_region_map.resize(REGION_MAP_SIZE * REGION_MAP_SIZE);
	_regions.clear();
	_master_height_range = V2_ZERO;
	_generated_height_maps.clear();
	_generated_control_maps.clear();
	_generated_color_maps.clear();
}

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DData::initialize(Terrain3D *p_terrain) {
	if (p_terrain == nullptr) {
		LOG(ERROR, "Initialization failed, p_terrain is null");
		return;
	}
	LOG(INFO, "Initializing storage");
	bool initialized = _terrain != nullptr;
	_terrain = p_terrain;
	_region_map.resize(REGION_MAP_SIZE * REGION_MAP_SIZE);
	_mesh_vertex_spacing = _terrain->get_mesh_vertex_spacing();
	_region_size = _terrain->get_region_size();
	_region_sizev = Vector2i(_region_size, _region_size);

	if (!initialized && !_terrain->get_data_directory().is_empty()) {
		load_directory(_terrain->get_data_directory());
	}
}

// Returns an array of active regions, optionally a shallow or deep copy
TypedArray<Terrain3DRegion> Terrain3DData::get_regions_active(const bool p_copy, const bool p_deep) const {
	TypedArray<Terrain3DRegion> region_arr;
	for (int i = 0; i < _region_locations.size(); i++) {
		Vector2i region_loc = _region_locations[i];
		Ref<Terrain3DRegion> region = _regions[region_loc];
		if (region.is_valid()) {
			region_arr.push_back((p_copy) ? region->duplicate(p_deep) : region);
		}
	}
	return region_arr;
}

// Recalculates master height range from all active regions current height ranges
// Recursive mode has all regions to recalculate from each heightmap pixel
void Terrain3DData::calc_height_range(const bool p_recursive) {
	_master_height_range = V2_ZERO;
	for (int i = 0; i < _region_locations.size(); i++) {
		Vector2i region_loc = _region_locations[i];
		Ref<Terrain3DRegion> region = _regions[region_loc];
		if (region.is_null()) {
			LOG(ERROR, "Region not found at: ", region_loc);
			return;
		}
		if (p_recursive) {
			region->calc_height_range();
		}
		update_master_heights(region->get_height_range());
	}
	LOG(DEBUG_CONT, "Accumulated height range for all regions: ", _master_height_range);
}

void Terrain3DData::clear_edited_area() {
	_edited_area = AABB();
}

void Terrain3DData::add_edited_area(const AABB &p_area) {
	if (_edited_area.has_surface()) {
		_edited_area = _edited_area.merge(p_area);
	} else {
		_edited_area = p_area;
	}
	emit_signal("maps_edited", _edited_area);
}

void Terrain3DData::set_region_modified(const Vector2i &p_region_loc, const bool p_modified) {
	Ref<Terrain3DRegion> region = _regions[p_region_loc];
	if (region.is_null()) {
		LOG(ERROR, "Region not found at: ", p_region_loc);
		return;
	}
	return region->set_modified(p_modified);
}

bool Terrain3DData::is_region_modified(const Vector2i &p_region_loc) const {
	Ref<Terrain3DRegion> region = _regions[p_region_loc];
	if (region.is_null()) {
		LOG(ERROR, "Region not found at: ", p_region_loc);
		return false;
	}
	return region->is_modified();
}

void Terrain3DData::set_region_deleted(const Vector2i &p_region_loc, const bool p_deleted) {
	Ref<Terrain3DRegion> region = _regions[p_region_loc];
	if (region.is_null()) {
		LOG(ERROR, "Region not found at: ", p_region_loc);
		return;
	}
	return region->set_deleted(p_deleted);
}

bool Terrain3DData::is_region_deleted(const Vector2i &p_region_loc) const {
	Ref<Terrain3DRegion> region = _regions[p_region_loc];
	if (region.is_null()) {
		LOG(ERROR, "Region not found at: ", p_region_loc);
		return true;
	}
	return region->is_deleted();
}

void Terrain3DData::set_region_locations(const TypedArray<Vector2i> &p_locations) {
	LOG(INFO, "Setting _region_locations with array sized: ", p_locations.size());
	_region_locations = p_locations;
	_region_map_dirty = true;
	update_maps();
}

Error Terrain3DData::add_regionl(const Vector2i &p_region_loc, const Ref<Terrain3DRegion> &p_region, const bool p_update) {
	p_region->set_location(p_region_loc);
	return add_region(p_region, p_update);
}

Error Terrain3DData::add_regionp(const Vector3 &p_global_position, const Ref<Terrain3DRegion> &p_region, const bool p_update) {
	p_region->set_location(get_region_location(p_global_position));
	return add_region(p_region, p_update);
}

Ref<Terrain3DRegion> Terrain3DData::add_region_blank(const Vector2i &p_region_loc, const bool p_update) {
	Ref<Terrain3DRegion> region;
	region.instantiate();
	region->set_location(p_region_loc);
	region->set_region_size(_region_size);
	if (add_region(region, p_update) == OK) {
		region->set_modified(true);
		return region;
	}
	return Ref<Terrain3DRegion>();
}

Ref<Terrain3DRegion> Terrain3DData::add_region_blankp(const Vector3 &p_global_position, const bool p_update) {
	return add_region_blank(get_region_location(p_global_position));
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
		force_update_maps();
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
		force_update_maps();
	}
}

void Terrain3DData::update_maps() {
	bool any_changed = false;

	if (_region_map_dirty) {
		LOG(DEBUG_CONT, "Regenerating ", REGION_MAP_VSIZE, " region map array from active regions");
		_region_map.clear();
		_region_map.resize(REGION_MAP_SIZE * REGION_MAP_SIZE);
		_region_map_dirty = false;
		_region_locations = TypedArray<Vector2i>(); // enforce new pointer
		Array locs = _regions.keys();
		int region_id = 0;
		for (int i = 0; i < locs.size(); i++) {
			Ref<Terrain3DRegion> region = _regions[locs[i]];
			if (region.is_valid() && !region->is_deleted()) {
				region_id += 1; // Begin at 1 since 0 = no region
				int map_index = get_region_map_index(region->get_location());
				if (map_index >= 0) {
					_region_map[map_index] = region_id;
					_region_locations.push_back(region->get_location());
				}
			}
		}
		any_changed = true;
		emit_signal("region_map_changed");
	}

	if (_generated_height_maps.is_dirty()) {
		LOG(DEBUG_CONT, "Regenerating height texture array from regions");
		_height_maps.clear();
		for (int i = 0; i < _region_locations.size(); i++) {
			Vector2i region_loc = _region_locations[i];
			Ref<Terrain3DRegion> region = _regions[region_loc];
			if (region.is_valid()) {
				_height_maps.push_back(region->get_height_map());
			} else {
				LOG(ERROR, "Can't find region ", region_loc, ", _regions: ", _regions.size(),
						", locations: ", _region_locations.size(), ". Please report this error.");
				_region_map_dirty = true;
			}
		}
		_generated_height_maps.create(_height_maps);
		calc_height_range();
		any_changed = true;
		emit_signal("height_maps_changed");
	}

	if (_generated_control_maps.is_dirty()) {
		LOG(DEBUG_CONT, "Regenerating control texture array from regions");
		_control_maps.clear();
		for (int i = 0; i < _region_locations.size(); i++) {
			Vector2i region_loc = _region_locations[i];
			Ref<Terrain3DRegion> region = _regions[region_loc];
			_control_maps.push_back(region->get_control_map());
		}
		_generated_control_maps.create(_control_maps);
		any_changed = true;
		emit_signal("control_maps_changed");
	}

	if (_generated_color_maps.is_dirty()) {
		LOG(DEBUG_CONT, "Regenerating color texture array from regions");
		_color_maps.clear();
		for (int i = 0; i < _region_locations.size(); i++) {
			Vector2i region_loc = _region_locations[i];
			Ref<Terrain3DRegion> region = _regions[region_loc];
			_color_maps.push_back(region->get_color_map());
		}
		_generated_color_maps.create(_color_maps);
		any_changed = true;
		emit_signal("color_maps_changed");
	}

	if (any_changed) {
		emit_signal("maps_changed");
	}
}

void Terrain3DData::save_region(const Vector2i &p_region_loc, const String &p_dir, const bool p_16_bit) {
	Ref<Terrain3DRegion> region = _regions[p_region_loc];
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
		da->remove(fname);
		if (Engine::get_singleton()->is_editor_hint()) {
			EditorInterface::get_singleton()->get_resource_filesystem()->scan();
		}
		LOG(INFO, "File ", path, " deleted");
		return;
	}
	region->save(path, p_16_bit);
}

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

TypedArray<Image> Terrain3DData::get_maps_copy(const MapType p_map_type, const TypedArray<int> &p_region_ids) const {
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

void Terrain3DData::set_pixel(const MapType p_map_type, const Vector3 &p_global_position, const Color &p_pixel) {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return;
	}
	Vector2i region_loc = get_region_location(p_global_position);
	Ref<Terrain3DRegion> region = _regions[region_loc];
	if (region.is_null()) {
		LOG(ERROR, "No region found at: ", p_global_position);
		return;
	}
	Vector2i global_offset = region_loc * _region_size;
	Vector3 descaled_pos = p_global_position / _mesh_vertex_spacing;
	Vector2i img_pos = Vector2i(descaled_pos.x - global_offset.x, descaled_pos.z - global_offset.y);
	img_pos = img_pos.clamp(V2I_ZERO, Vector2i(_region_size - 1, _region_size - 1));
	Ref<Image> map = region->get_map(p_map_type);
	map->set_pixelv(img_pos, p_pixel);
	region->set_modified(true);
}

Color Terrain3DData::get_pixel(const MapType p_map_type, const Vector3 &p_global_position) const {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return COLOR_NAN;
	}
	Vector2i region_loc = get_region_location(p_global_position);
	Ref<Terrain3DRegion> region = _regions[region_loc];
	if (region.is_null()) {
		return COLOR_NAN;
	}
	Vector2i global_offset = region_loc * _region_size;
	Vector3 descaled_pos = p_global_position / _mesh_vertex_spacing;
	Vector2i img_pos = Vector2i(descaled_pos.x - global_offset.x, descaled_pos.z - global_offset.y);
	img_pos = img_pos.clamp(V2I_ZERO, Vector2i(_region_size - 1, _region_size - 1));
	Ref<Image> map = region->get_map(p_map_type);
	return map->get_pixelv(img_pos);
}

real_t Terrain3DData::get_height(const Vector3 &p_global_position) const {
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
Vector3 Terrain3DData::get_texture_id(const Vector3 &p_global_position) const {
	// Verify in a region
	int region_id = get_region_idp(p_global_position);
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

real_t Terrain3DData::get_angle(const Vector3 &p_global_position) const {
	float src = get_pixel(TYPE_CONTROL, p_global_position).r; // Must be 32-bit float, not double/real
	if (std::isnan(src)) {
		return NAN;
	}
	real_t angle = real_t(get_uv_rotation(src));
	angle *= 22.5; // Return value in degrees.
	return angle;
}

real_t Terrain3DData::get_scale(const Vector3 &p_global_position) const {
	float src = get_pixel(TYPE_CONTROL, p_global_position).r; // Must be 32-bit float, not double/real
	if (std::isnan(src)) {
		return NAN;
	}
	std::array<real_t, 8> scale_values = { 0.0f, 20.0f, 40.0f, 60.0f, 80.0f, -60.0f, -40.0f, -20.0f };
	real_t scale = scale_values[get_uv_scale(src)]; //select from array UI return values
	return scale;
}

void Terrain3DData::force_update_maps(const MapType p_map_type, const bool p_generate_mipmaps) {
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
			_region_map_dirty = true;
			break;
	}
	if (p_generate_mipmaps && (p_map_type == TYPE_COLOR || p_map_type == TYPE_MAX)) {
		LOG(DEBUG_CONT, "Regenerating color mipmaps");
		for (int i = 0; i < _region_locations.size(); i++) {
			Vector2i region_loc = _region_locations[i];
			Ref<Terrain3DRegion> region = _regions[region_loc];
			region->get_color_map()->generate_mipmaps();
		}
	}
	update_maps();
}

void Terrain3DData::save_directory(const String &p_dir) {
	LOG(INFO, "Saving data files to ", p_dir);
	Array locations = _regions.keys();
	for (int i = 0; i < locations.size(); i++) {
		save_region(locations[i], p_dir, _terrain->get_save_16_bit());
	}
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
					img_slice->blit_rect(tmp_images[i], Rect2i(start_coords, size_to_copy), V2I_ZERO);
				} else {
					img_slice = Util::get_filled_image(_region_sizev, COLOR[i], false, FORMAT[i]);
				}
				images[i] = img_slice;
			}
			// Add the heightmap slice and only regenerate on the last one
			Ref<Terrain3DRegion> region;
			region.instantiate();
			Vector3 position = Vector3(descaled_position.x + start_coords.x, 0.f, descaled_position.z + start_coords.y);
			position *= _mesh_vertex_spacing;
			region->set_location(get_region_location(position));
			region->set_maps(images);
			add_region(region, (x == slices_width - 1 && y == slices_height - 1));
		}
	} // for y < slices_height, x < slices_width
}

/** Exports a specified map as one of r16/raw, exr, jpg, png, webp, res, tres
 * r16 or exr are recommended for roundtrip external editing
 * r16 can be edited by Krita, however you must know the dimensions and min/max before reimporting
 * res/tres allow storage in any of Godot's native Image formats.
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

Ref<Image> Terrain3DData::layered_to_image(const MapType p_map_type) const {
	LOG(INFO, "Generating a full sized image for all regions including empty regions");
	MapType map_type = p_map_type;
	if (map_type >= TYPE_MAX) {
		map_type = TYPE_HEIGHT;
	}
	Vector2i top_left = V2I_ZERO;
	Vector2i bottom_right = V2I_ZERO;
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
		Ref<Terrain3DRegion> region = _regions[region_loc];
		img->blit_rect(region->get_map(map_type), Rect2i(V2I_ZERO, _region_sizev), img_location);
	}
	return img;
}

void Terrain3DData::load_directory(const String &p_dir) {
	if (p_dir.is_empty()) {
		LOG(ERROR, "Specified data directory is blank");
		return;
	}
	Ref<DirAccess> da = DirAccess::open(p_dir);
	if (da.is_null()) {
		LOG(ERROR, "Cannot read Terrain3D data directory: ", p_dir);
		return;
	}
	_clear();

	LOG(INFO, "Loading region files from ", p_dir);
	PackedStringArray files = da->get_files();
	for (int i = 0; i < files.size(); i++) {
		String fname = files[i];
		String path = p_dir + String("/") + fname;
		if (!fname.begins_with("terrain3d") || !fname.ends_with(".res")) {
			continue;
		}
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
		region->take_over_path(path);
		region->set_location(loc);
		region->set_version(CURRENT_VERSION); // Sends upgrade warning if old version
		add_region(region, false);
	}
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

Vector3 Terrain3DData::get_normal(const Vector3 &p_global_position) const {
	if (get_region_idp(p_global_position) < 0 || is_hole(get_control(p_global_position))) {
		return Vector3(NAN, NAN, NAN);
	}
	real_t height = get_height(p_global_position);
	real_t u = height - get_height(p_global_position + Vector3(_mesh_vertex_spacing, 0.0f, 0.0f));
	real_t v = height - get_height(p_global_position + Vector3(0.f, 0.f, _mesh_vertex_spacing));
	Vector3 normal = Vector3(u, _mesh_vertex_spacing, v);
	normal.normalize();
	return normal;
}

void Terrain3DData::print_audit_data() const {
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
	ClassDB::bind_static_method("Terrain3DData", D_METHOD("get_region_map_index"), &Terrain3DData::get_region_map_index);

	ClassDB::bind_method(D_METHOD("has_region", "region_location"), &Terrain3DData::has_region);
	ClassDB::bind_method(D_METHOD("has_regionp", "global_position"), &Terrain3DData::has_regionp);
	ClassDB::bind_method(D_METHOD("get_region", "region_location"), &Terrain3DData::get_region);
	ClassDB::bind_method(D_METHOD("get_regionp", "global_position"), &Terrain3DData::get_regionp);

	ClassDB::bind_method(D_METHOD("set_region_modified", "region_location", "modified"), &Terrain3DData::set_region_modified);
	ClassDB::bind_method(D_METHOD("is_region_modified", "region_location"), &Terrain3DData::is_region_modified);
	ClassDB::bind_method(D_METHOD("set_region_deleted", "region_location", "deleted"), &Terrain3DData::set_region_deleted);
	ClassDB::bind_method(D_METHOD("is_region_deleted", "region_location"), &Terrain3DData::is_region_deleted);

	ClassDB::bind_method(D_METHOD("get_region_location", "global_position"), &Terrain3DData::get_region_location);
	ClassDB::bind_method(D_METHOD("get_region_locationi", "region_id"), &Terrain3DData::get_region_locationi);
	ClassDB::bind_method(D_METHOD("get_region_id", "region_location"), &Terrain3DData::get_region_id);
	ClassDB::bind_method(D_METHOD("get_region_idp", "global_position"), &Terrain3DData::get_region_idp);

	ClassDB::bind_method(D_METHOD("add_region", "region", "update"), &Terrain3DData::add_region, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_regionl", "region_location", "update"), &Terrain3DData::add_regionl, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_regionp", "global_position", "update"), &Terrain3DData::add_regionp, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_region_blank", "region_location", "update"), &Terrain3DData::add_region, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_region_blankp", "global_position", "update"), &Terrain3DData::add_region, DEFVAL(true));

	ClassDB::bind_method(D_METHOD("remove_region", "region", "update"), &Terrain3DData::remove_region, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("remove_regionl", "region_location", "update"), &Terrain3DData::remove_regionl, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("remove_regionp", "global_position", "update"), &Terrain3DData::remove_regionp, DEFVAL(true));

	ClassDB::bind_method(D_METHOD("save_directory", "directory"), &Terrain3DData::save_directory);
	ClassDB::bind_method(D_METHOD("load_directory", "directory"), &Terrain3DData::load_directory);
	ClassDB::bind_method(D_METHOD("save_region", "directory", "region_location", "16_bit"), &Terrain3DData::save_region, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("load_region", "directory", "region_location", "update"), &Terrain3DData::load_region, DEFVAL(true));

	ClassDB::bind_method(D_METHOD("get_height_maps"), &Terrain3DData::get_height_maps);
	ClassDB::bind_method(D_METHOD("get_control_maps"), &Terrain3DData::get_control_maps);
	ClassDB::bind_method(D_METHOD("get_color_maps"), &Terrain3DData::get_color_maps);
	ClassDB::bind_method(D_METHOD("get_height_maps_rid"), &Terrain3DData::get_height_maps_rid);
	ClassDB::bind_method(D_METHOD("get_control_maps_rid"), &Terrain3DData::get_control_maps_rid);
	ClassDB::bind_method(D_METHOD("get_color_maps_rid"), &Terrain3DData::get_color_maps_rid);
	ClassDB::bind_method(D_METHOD("force_update_maps", "map_type", "generate_mipmaps"), &Terrain3DData::force_update_maps, DEFVAL(TYPE_MAX), DEFVAL(false));

	ClassDB::bind_method(D_METHOD("get_maps", "map_type"), &Terrain3DData::get_maps);
	ClassDB::bind_method(D_METHOD("get_maps_copy", "map_type"), &Terrain3DData::get_maps_copy);

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
	ClassDB::bind_method(D_METHOD("get_angle", "global_position"), &Terrain3DData::get_angle);
	ClassDB::bind_method(D_METHOD("get_scale", "global_position"), &Terrain3DData::get_scale);

	ClassDB::bind_method(D_METHOD("get_normal", "global_position"), &Terrain3DData::get_normal);
	ClassDB::bind_method(D_METHOD("get_texture_id", "global_position"), &Terrain3DData::get_texture_id);
	ClassDB::bind_method(D_METHOD("get_mesh_vertex", "lod", "filter", "global_position"), &Terrain3DData::get_mesh_vertex);

	ClassDB::bind_method(D_METHOD("get_height_range"), &Terrain3DData::get_height_range);
	ClassDB::bind_method(D_METHOD("calc_height_range", "recursive"), &Terrain3DData::calc_height_range, DEFVAL(false));

	ClassDB::bind_method(D_METHOD("import_images", "images", "global_position", "offset", "scale"), &Terrain3DData::import_images, DEFVAL(Vector3(0, 0, 0)), DEFVAL(0.0), DEFVAL(1.0));
	ClassDB::bind_method(D_METHOD("export_image", "file_name", "map_type"), &Terrain3DData::export_image);
	ClassDB::bind_method(D_METHOD("layered_to_image", "map_type"), &Terrain3DData::layered_to_image);

	ADD_SIGNAL(MethodInfo("maps_changed"));
	ADD_SIGNAL(MethodInfo("region_map_changed"));
	ADD_SIGNAL(MethodInfo("height_maps_changed"));
	ADD_SIGNAL(MethodInfo("control_maps_changed"));
	ADD_SIGNAL(MethodInfo("color_maps_changed"));
	ADD_SIGNAL(MethodInfo("maps_edited", PropertyInfo(Variant::AABB, "edited_area")));
}
