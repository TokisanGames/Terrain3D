// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/resource_saver.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "logger.h"
#include "terrain_3d_storage.h"
#include "util.h"

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3DStorage::_clear() {
	LOG(INFO, "Clearing storage");
	_region_map_dirty = true;
	_region_map.clear();
	_generated_height_maps.clear();
	_generated_control_maps.clear();
	_generated_color_maps.clear();
}

///////////////////////////
// Public Functions
///////////////////////////

Terrain3DStorage::Terrain3DStorage() {
	_region_map.resize(REGION_MAP_SIZE * REGION_MAP_SIZE);
}

Terrain3DStorage::~Terrain3DStorage() {
	_clear();
}

// Lots of the upgrade process requires this to run first
// It only runs if the version is saved in the file, which only happens if it was
// different from the in the file is different from _version
inline void Terrain3DStorage::set_version(real_t p_version) {
	LOG(INFO, vformat("%.3f", p_version));
	_version = p_version;
	if (_version >= 0.841f) {
		_841_colormap_upgraded = true;
	}
	if (_version >= 0.842f) {
		_842_controlmap_upgraded = true;
	}
	if (_version < CURRENT_VERSION) {
		LOG(WARN, "Storage version ", vformat("%.3f", _version), " will be updated to ", vformat("%.3f", CURRENT_VERSION), " upon save");
		_modified = true;
	}
}

inline void Terrain3DStorage::set_save_16_bit(bool p_enabled) {
	LOG(INFO, p_enabled);
	_save_16_bit = p_enabled;
}

inline void Terrain3DStorage::set_height_range(Vector2 p_range) {
	LOG(INFO, vformat("%.2v", p_range));
	_height_range = p_range;
}

void Terrain3DStorage::update_heights(real_t p_height) {
	if (p_height < _height_range.x) {
		_height_range.x = p_height;
	} else if (p_height > _height_range.y) {
		_height_range.y = p_height;
	}
	_modified = true;
}

void Terrain3DStorage::update_heights(Vector2 p_heights) {
	if (p_heights.x < _height_range.x) {
		_height_range.x = p_heights.x;
	}
	if (p_heights.y > _height_range.y) {
		_height_range.y = p_heights.y;
	}
	_modified = true;
}

void Terrain3DStorage::update_height_range() {
	_height_range = Vector2(0, 0);
	for (int i = 0; i < _height_maps.size(); i++) {
		update_heights(Util::get_min_max(_height_maps[i]));
	}
	LOG(INFO, "Updated terrain height range: ", _height_range);
}

void Terrain3DStorage::set_region_size(RegionSize p_size) {
	LOG(INFO, p_size);
	//ERR_FAIL_COND(p_size < SIZE_64);
	//ERR_FAIL_COND(p_size > SIZE_2048);
	ERR_FAIL_COND(p_size != SIZE_1024);
	_region_size = p_size;
	_region_sizev = Vector2i(_region_size, _region_size);
	emit_signal("region_size_changed", _region_size);
}

void Terrain3DStorage::set_region_offsets(const TypedArray<Vector2i> &p_offsets) {
	LOG(INFO, "Setting region offsets with array sized: ", p_offsets.size());
	_region_offsets = p_offsets;
	_region_map_dirty = true;
	update_regions();
}

/** Returns a region offset given a location */
Vector2i Terrain3DStorage::get_region_offset(Vector3 p_global_position) {
	return Vector2i((Vector2(p_global_position.x, p_global_position.z) / real_t(_region_size)).floor());
}

int Terrain3DStorage::get_region_index(Vector3 p_global_position) {
	Vector2i uv_offset = get_region_offset(p_global_position);
	Vector2i pos = Vector2i(uv_offset + (REGION_MAP_VSIZE / 2));
	if (pos.x >= REGION_MAP_SIZE || pos.y >= REGION_MAP_SIZE || pos.x < 0 || pos.y < 0) {
		return -1;
	}
	return _region_map[pos.y * REGION_MAP_SIZE + pos.x] - 1;
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
Error Terrain3DStorage::add_region(Vector3 p_global_position, const TypedArray<Image> &p_images, bool p_update) {
	Vector2i uv_offset = get_region_offset(p_global_position);
	LOG(INFO, "Adding region at ", p_global_position, ", uv_offset ", uv_offset,
			", array size: ", p_images.size(),
			", update maps: ", p_update ? "yes" : "no");

	Vector2i region_pos = Vector2i(uv_offset + (REGION_MAP_VSIZE / 2));
	if (region_pos.x >= REGION_MAP_SIZE || region_pos.y >= REGION_MAP_SIZE || region_pos.x < 0 || region_pos.y < 0) {
		LOG(ERROR, "Specified position outside of maximum region map size: +/-", REGION_MAP_SIZE / 2 * _region_size);
		return FAILED;
	}

	if (has_region(p_global_position)) {
		if (p_images.is_empty()) {
			LOG(DEBUG, "Region at ", p_global_position, " already exists and nothing to overwrite. Doing nothing");
			return OK;
		} else {
			LOG(DEBUG, "Region at ", p_global_position, " already exists, overwriting");
			remove_region(p_global_position, false);
		}
	}

	TypedArray<Image> images = sanitize_maps(TYPE_MAX, p_images);
	if (images.is_empty()) {
		LOG(ERROR, "Sanitize_maps failed to accept images or produce blanks");
		return FAILED;
	}

	// If we're importing data into a region, check its heights for aabbs
	Vector2 min_max = Vector2(0, 0);
	if (p_images.size() > TYPE_HEIGHT) {
		min_max = Util::get_min_max(images[TYPE_HEIGHT]);
		LOG(DEBUG, "Checking imported height range: ", min_max);
		update_heights(min_max);
	}

	LOG(DEBUG, "Pushing back ", images.size(), " images");
	_height_maps.push_back(images[TYPE_HEIGHT]);
	_control_maps.push_back(images[TYPE_CONTROL]);
	_color_maps.push_back(images[TYPE_COLOR]);
	_region_offsets.push_back(uv_offset);
	LOG(DEBUG, "Total regions after pushback: ", _region_offsets.size());

	// Region_map is used by get_region_index so must be updated every time
	_region_map_dirty = true;
	if (p_update) {
		LOG(DEBUG, "Updating generated maps");
		_generated_height_maps.clear();
		_generated_control_maps.clear();
		_generated_color_maps.clear();
		update_regions();
		notify_property_list_changed();
		emit_changed();
	} else {
		update_regions();
	}
	return OK;
}

void Terrain3DStorage::remove_region(Vector3 p_global_position, bool p_update) {
	LOG(INFO, "Removing region at ", p_global_position, " Updating: ", p_update ? "yes" : "no");
	int index = get_region_index(p_global_position);
	ERR_FAIL_COND_MSG(index == -1, "Map does not exist.");

	LOG(INFO, "Removing region at: ", get_region_offset(p_global_position));
	_region_offsets.remove_at(index);
	LOG(DEBUG, "Removed region_offsets, new size: ", _region_offsets.size());
	_height_maps.remove_at(index);
	LOG(DEBUG, "Removed heightmaps, new size: ", _height_maps.size());
	_control_maps.remove_at(index);
	LOG(DEBUG, "Removed control maps, new size: ", _control_maps.size());
	_color_maps.remove_at(index);
	LOG(DEBUG, "Removed colormaps, new size: ", _color_maps.size());

	if (_height_maps.size() == 0) {
		_height_range = Vector2(0, 0);
	}

	// Region_map is used by get_region_index so must be updated
	_region_map_dirty = true;
	if (p_update) {
		LOG(DEBUG, "Updating generated maps");
		_generated_height_maps.clear();
		_generated_control_maps.clear();
		_generated_color_maps.clear();
		update_regions();
		notify_property_list_changed();
		emit_changed();
	} else {
		update_regions();
	}
}

void Terrain3DStorage::update_regions(bool force_emit) {
	if (_generated_height_maps.is_dirty()) {
		LOG(DEBUG_CONT, "Regenerating height layered texture from ", _height_maps.size(), " maps");
		_generated_height_maps.create(_height_maps);
		force_emit = true;
		_modified = true;
		emit_signal("height_maps_changed");
	}

	if (_generated_control_maps.is_dirty()) {
		LOG(DEBUG_CONT, "Regenerating control layered texture from ", _control_maps.size(), " maps");
		_generated_control_maps.create(_control_maps);
		force_emit = true;
		_modified = true;
	}

	if (_generated_color_maps.is_dirty()) {
		LOG(DEBUG_CONT, "Regenerating color layered texture from ", _color_maps.size(), " maps");
		_generated_color_maps.create(_color_maps);
		force_emit = true;
		_modified = true;
	}

	if (_region_map_dirty) {
		LOG(DEBUG_CONT, "Regenerating ", REGION_MAP_VSIZE, " region map array");
		_region_map.clear();
		_region_map.resize(REGION_MAP_SIZE * REGION_MAP_SIZE);
		_region_map_dirty = false;
		for (int i = 0; i < _region_offsets.size(); i++) {
			Vector2i ofs = _region_offsets[i];
			Vector2i pos = Vector2i(ofs + (REGION_MAP_VSIZE / 2));
			if (pos.x >= REGION_MAP_SIZE || pos.y >= REGION_MAP_SIZE || pos.x < 0 || pos.y < 0) {
				continue;
			}
			_region_map[pos.y * REGION_MAP_SIZE + pos.x] = i + 1; // 0 = no region
		}
		force_emit = true;
		_modified = true;
	}

	// Don't emit if no changes and not requested
	if (force_emit) {
		Array region_signal_args;
		region_signal_args.push_back(_generated_height_maps.get_rid());
		region_signal_args.push_back(_generated_control_maps.get_rid());
		region_signal_args.push_back(_generated_color_maps.get_rid());
		region_signal_args.push_back(_region_map);
		region_signal_args.push_back(_region_offsets);
		emit_signal("regions_changed", region_signal_args);
	}
}

void Terrain3DStorage::set_map_region(MapType p_map_type, int p_region_index, const Ref<Image> p_image) {
	switch (p_map_type) {
		case TYPE_HEIGHT:
			if (p_region_index >= 0 && p_region_index < _height_maps.size()) {
				_height_maps[p_region_index] = p_image;
				force_update_maps(TYPE_HEIGHT);
			} else {
				LOG(ERROR, "Requested index is out of bounds. height_maps size: ", _height_maps.size());
			}
			break;
		case TYPE_CONTROL:
			if (p_region_index >= 0 && p_region_index < _control_maps.size()) {
				_control_maps[p_region_index] = p_image;
				force_update_maps(TYPE_CONTROL);
			} else {
				LOG(ERROR, "Requested index is out of bounds. control_maps size: ", _control_maps.size());
			}
			break;
		case TYPE_COLOR:
			if (p_region_index >= 0 && p_region_index < _color_maps.size()) {
				_color_maps[p_region_index] = p_image;
				force_update_maps(TYPE_COLOR);
			} else {
				LOG(ERROR, "Requested index is out of bounds. color_maps size: ", _color_maps.size());
			}
			break;
		default:
			LOG(ERROR, "Requested map type is invalid");
			break;
	}
}

Ref<Image> Terrain3DStorage::get_map_region(MapType p_map_type, int p_region_index) const {
	switch (p_map_type) {
		case TYPE_HEIGHT:
			if (p_region_index >= 0 && p_region_index < _height_maps.size()) {
				return _height_maps[p_region_index];
			} else {
				LOG(ERROR, "Requested index is out of bounds. height_maps size: ", _height_maps.size());
			}
			break;
		case TYPE_CONTROL:
			if (p_region_index >= 0 && p_region_index < _control_maps.size()) {
				return _control_maps[p_region_index];
			} else {
				LOG(ERROR, "Requested index is out of bounds. control_maps size: ", _control_maps.size());
			}
			break;
		case TYPE_COLOR:
			if (p_region_index >= 0 && p_region_index < _color_maps.size()) {
				return _color_maps[p_region_index];
			} else {
				LOG(ERROR, "Requested index is out of bounds. color_maps size: ", _color_maps.size());
			}
			break;
		default:
			LOG(ERROR, "Requested map type is invalid");
			break;
	}
	return Ref<Image>();
}

void Terrain3DStorage::set_maps(MapType p_map_type, const TypedArray<Image> &p_maps) {
	ERR_FAIL_COND_MSG(p_map_type < 0 || p_map_type >= TYPE_MAX, "Specified map type out of range");
	switch (p_map_type) {
		case TYPE_HEIGHT:
			set_height_maps(p_maps);
			break;
		case TYPE_CONTROL:
			set_control_maps(p_maps);
			break;
		case TYPE_COLOR:
			set_color_maps(p_maps);
			break;
		default:
			break;
	}
}

TypedArray<Image> Terrain3DStorage::get_maps(MapType p_map_type) const {
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

TypedArray<Image> Terrain3DStorage::get_maps_copy(MapType p_map_type) const {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return TypedArray<Image>();
	}
	TypedArray<Image> maps = get_maps(p_map_type);
	TypedArray<Image> newmaps;
	newmaps.resize(maps.size());
	for (int i = 0; i < maps.size(); i++) {
		Ref<Image> img;
		img.instantiate();
		img->copy_from(maps[i]);
		newmaps[i] = img;
	}
	return newmaps;
}

void Terrain3DStorage::set_height_maps(const TypedArray<Image> &p_maps) {
	LOG(INFO, "Setting height maps: ", p_maps.size());
	_height_maps = sanitize_maps(TYPE_HEIGHT, p_maps);
	force_update_maps(TYPE_HEIGHT);
}

void Terrain3DStorage::set_control_maps(const TypedArray<Image> &p_maps) {
	LOG(INFO, "Setting control maps: ", p_maps.size());
	TypedArray<Image> maps = p_maps;
	// DEPRECATED 0.8.4 Remove 0.9
	// Convert old RGB8 control format <0.841 to bit based format 0.8.42
	if (_version < 0.842 && !_842_controlmap_upgraded && maps.size() > 0 &&
			(Ref<Image>(maps[0])->get_format() != FORMAT[TYPE_CONTROL])) {
		LOG(WARN, "Converting control maps to int format: ", vformat("%.3f", _version), "->", vformat("%.3f", CURRENT_VERSION));
		for (int i = 0; i < maps.size(); i++) {
			Ref<Image> old_img = maps[i];
			PackedByteArray pba;
			pba.resize(_region_size * _region_size * sizeof(uint32_t));
			for (int x = 0; x < old_img->get_width(); x++) {
				for (int y = 0; y < old_img->get_height(); y++) {
					Color pixel = old_img->get_pixel(x, y);
					uint32_t base = (pixel.get_r8() & 0x1F) << 27; // 5 bits 32-28
					uint32_t over = (pixel.get_g8() & 0x1F) << 22; // 5 bits 27-23
					uint32_t blend = (pixel.get_b8() & 0xFF) << 14; // 8 bits 22-15
					uint32_t value = base | over | blend;
					pba.encode_u32((y * _region_size + x) * sizeof(uint32_t), value);
				}
			}
			Ref<Image> new_img = Image::create_from_data(_region_size, _region_size, false, Image::FORMAT_RF, pba);
			maps[i] = new_img;
		}
		_842_controlmap_upgraded = true;
	}
	_control_maps = sanitize_maps(TYPE_CONTROL, maps);
	force_update_maps(TYPE_CONTROL);
}

void Terrain3DStorage::set_color_maps(const TypedArray<Image> &p_maps) {
	LOG(INFO, "Setting color maps: ", p_maps.size());
	TypedArray<Image> maps = p_maps;
	// DEPRECATED 0.8.4 Remove 0.9
	// Convert colormap from linear <0.84 to srgb 0.841
	if (_version < 0.841 && !_841_colormap_upgraded && maps.size() > 0) {
		LOG(WARN, "Converting color maps from linear to srgb: ", vformat("%.3f", _version), "->", vformat("%.3f", CURRENT_VERSION));
		for (int i = 0; i < maps.size(); i++) {
			Ref<Image> img = maps[i];
			for (int x = 0; x < img->get_width(); x++) {
				for (int y = 0; y < img->get_height(); y++) {
					Color c = img->get_pixel(x, y);
					img->set_pixel(x, y, c.linear_to_srgb());
				}
			}
			maps[i] = img;
		}
		_841_colormap_upgraded = true;
	}
	_color_maps = sanitize_maps(TYPE_COLOR, maps);
	force_update_maps(TYPE_COLOR);
}

Color Terrain3DStorage::get_pixel(MapType p_map_type, Vector3 p_global_position) {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return COLOR_ZERO;
	}
	int region = get_region_index(p_global_position);
	if (region < 0 || region >= _region_offsets.size()) {
		return COLOR_ZERO;
	}
	Ref<Image> map = get_map_region(p_map_type, region);
	Vector2i global_offset = Vector2i(get_region_offsets()[region]) * _region_size;
	Vector2i img_pos = Vector2i(
			Vector2(p_global_position.x - global_offset.x,
					p_global_position.z - global_offset.y)
					.floor());
	return map->get_pixelv(img_pos);
}

Color Terrain3DStorage::get_color(Vector3 p_global_position) {
	Color clr = get_pixel(TYPE_COLOR, p_global_position);
	clr.a = 1.0;
	return clr;
}

/**
 * Returns the location of a terrain vertex at a certain LOD.
 * p_lod (0-8): Determines how many heights around the given global position will be sampled.
 * p_filter:
 *  HEIGHT_FILTER_NEAREST: Samples the height map at the exact coordinates given.
 *  HEIGHT_FILTER_MINIMUM: Samples (1 << p_lod) ** 2 heights around the given coordinates and returns the lowest.
 * p_global_position: X and Z coordinates of the vertex. Heights will be sampled around these coordinates.
 */
Vector3 Terrain3DStorage::get_mesh_vertex(int32_t p_lod, HeightFilter p_filter, Vector3 p_global_position) {
	LOG(INFO, "Calculating vertex location");
	int32_t step = 1 << CLAMP(p_lod, 0, 8);
	real_t height = 0.0;
	switch (p_filter) {
		case HEIGHT_FILTER_NEAREST: {
			height = get_height(p_global_position);
		} break;
		case HEIGHT_FILTER_MINIMUM: {
			height = get_height(p_global_position);
			for (int32_t dx = -step / 2; dx < step / 2; dx += 1) {
				for (int32_t dz = -step / 2; dz < step / 2; dz += 1) {
					real_t h = get_height(p_global_position + Vector3(dx, 0.0, dz));
					if (h < height) {
						height = h;
					}
				}
			}
		} break;
	}
	return Vector3(p_global_position.x, height, p_global_position.z);
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
Vector3 Terrain3DStorage::get_texture_id(Vector3 p_global_position) {
	// Get bit field from pixel
	uint32_t bits;
	*(float *)&bits = get_pixel(TYPE_CONTROL, p_global_position).r; // Must be 32-bit float, not double/real
	uint32_t base_index = bits >> 27u & 0x1Fu;
	uint32_t overlay_index = bits >> 22u & 0x1Fu;
	real_t blend = real_t(bits >> 14u & 0xFFu) / 255.0f;
	return Vector3(real_t(base_index), real_t(overlay_index), blend);
}

/**
 * Returns sanitized maps of either a region set or a uniform set
 * Verifies size, vailidity, and format of maps
 * Creates filled blanks if lacking
 * p_map_type:
 *	TYPE_HEIGHT, TYPE_CONTROL, TYPE_COLOR: uniform set - p_maps are all the same type, size=N
 *	TYPE_MAX = region set - p_maps is [ height, control, color ], size=3
 **/
TypedArray<Image> Terrain3DStorage::sanitize_maps(MapType p_map_type, const TypedArray<Image> &p_maps) {
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

void Terrain3DStorage::force_update_maps(MapType p_map_type) {
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
	update_regions();
}

void Terrain3DStorage::save() {
	if (!_modified) {
		LOG(INFO, "Save requested, but not modified. Skipping");
		return;
	}
	String path = get_path();
	// Initiate save to external file. The scene will save itself.
	if (path.get_extension() == "tres" || path.get_extension() == "res") {
		LOG(DEBUG, "Attempting to save terrain data to external file: " + path);
		LOG(DEBUG, "Saving storage version: ", vformat("%.3f", CURRENT_VERSION));
		set_version(CURRENT_VERSION);
		Error err;
		if (_save_16_bit) {
			LOG(DEBUG, "16-bit save requested, converting heightmaps");
			TypedArray<Image> original_maps;
			original_maps = get_maps_copy(Terrain3DStorage::MapType::TYPE_HEIGHT);
			for (int i = 0; i < _height_maps.size(); i++) {
				Ref<Image> img = _height_maps[i];
				img->convert(Image::FORMAT_RH);
			}
			LOG(DEBUG, "Images converted, saving");
			err = ResourceSaver::get_singleton()->save(this, path, ResourceSaver::FLAG_COMPRESS);

			LOG(DEBUG, "Restoring 32-bit maps");
			_height_maps = original_maps;

		} else {
			err = ResourceSaver::get_singleton()->save(this, path, ResourceSaver::FLAG_COMPRESS);
		}
		ERR_FAIL_COND(err);
		LOG(DEBUG, "ResourceSaver return error (0 is OK): ", err);
		if (err == OK) {
			_modified = false;
		}
		LOG(INFO, "Finished saving terrain data");
	}
	if (path.get_extension() != "res") {
		LOG(WARN, "Storage resource is not saved as an external, binary .res file");
	}
}

/**
 * Loads a file from disk and returns an Image
 * Parameters:
 *	p_filename - file on disk to load. EXR, R16/RAW, PNG, or a ResourceLoader format (jpg, res, tres, etc)
 *	p_cache_mode - Send this flag to the resource loader to force caching or not
 *	p_height_range - R16 format: x=Min & y=Max value ranges. Required for R16 import
 *	p_size - R16 format: Image dimensions. Default (0,0) auto detects f/ square images. Required f/ non-square R16
 */
Ref<Image> Terrain3DStorage::load_image(String p_file_name, int p_cache_mode, Vector2 p_r16_height_range, Vector2i p_r16_size) {
	if (p_file_name.is_empty()) {
		LOG(ERROR, "No file specified. Nothing imported.");
		return Ref<Image>();
	}
	if (!FileAccess::file_exists(p_file_name)) {
		LOG(ERROR, "File ", p_file_name, " does not exist. Nothing to import.");
		return Ref<Image>();
	}

	// Load file based on extension
	Ref<Image> img;
	LOG(INFO, "Attempting to load: ", p_file_name);
	String ext = p_file_name.get_extension().to_lower();
	PackedStringArray imgloader_extensions = PackedStringArray(Array::make("bmp", "dds", "exr", "hdr", "jpg", "jpeg", "png", "tga", "svg", "webp"));

	// If R16 integer format (read/writeable by Krita)
	if (ext == "r16" || ext == "raw") {
		LOG(DEBUG, "Loading file as an r16");
		Ref<FileAccess> file = FileAccess::open(p_file_name, FileAccess::READ);
		// If p_size is zero, assume square and try to auto detect size
		if (p_r16_size <= Vector2i(0, 0)) {
			file->seek_end();
			int fsize = file->get_position();
			int fwidth = sqrt(fsize / 2);
			p_r16_size = Vector2i(fwidth, fwidth);
			LOG(DEBUG, "Total file size is: ", fsize, " calculated width: ", fwidth, " dimensions: ", p_r16_size);
			file->seek(0);
		}
		img = Image::create(p_r16_size.x, p_r16_size.y, false, FORMAT[TYPE_HEIGHT]);
		for (int y = 0; y < p_r16_size.y; y++) {
			for (int x = 0; x < p_r16_size.x; x++) {
				real_t h = real_t(file->get_16()) / 65535.0f;
				h = h * (p_r16_height_range.y - p_r16_height_range.x) + p_r16_height_range.x;
				img->set_pixel(x, y, Color(h, 0, 0));
			}
		}

		// If an Image extension, use Image loader
	} else if (imgloader_extensions.has(ext)) {
		LOG(DEBUG, "ImageFormatLoader loading recognized file type: ", ext);
		img = Image::load_from_file(p_file_name);

		// Else, see if Godot's resource loader will read it as an image: RES, TRES, etc
	} else {
		LOG(DEBUG, "Loading file as a resource");
		img = ResourceLoader::get_singleton()->load(p_file_name, "", static_cast<ResourceLoader::CacheMode>(p_cache_mode));
	}

	if (!img.is_valid()) {
		LOG(ERROR, "File", p_file_name, " could not be loaded.");
		return Ref<Image>();
	}
	if (img->is_empty()) {
		LOG(ERROR, "File", p_file_name, " is empty.");
		return Ref<Image>();
	}
	LOG(DEBUG, "Loaded Image size: ", img->get_size(), " format: ", img->get_format());
	return img;
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
void Terrain3DStorage::import_images(const TypedArray<Image> &p_images, Vector3 p_global_position, real_t p_offset, real_t p_scale) {
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

	int max_dimension = _region_size * REGION_MAP_SIZE / 2;
	if ((abs(p_global_position.x) > max_dimension) || (abs(p_global_position.z) > max_dimension)) {
		LOG(ERROR, "Specify a position within +/-", Vector3i(max_dimension, 0, max_dimension));
		return;
	}
	if ((p_global_position.x + img_size.x > max_dimension) ||
			(p_global_position.z + img_size.y > max_dimension)) {
		LOG(ERROR, img_size, " image will not fit at ", p_global_position,
				". Try ", -img_size / 2, " to center");
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
		if (i == TYPE_HEIGHT && (p_offset != 0 || p_scale != 1.0)) {
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
			Vector3 position = Vector3(p_global_position.x + start_coords.x, 0, p_global_position.z + start_coords.y);
			add_region(position, images, (x == slices_width - 1 && y == slices_height - 1));
		}
	} // for y < slices_height, x < slices_width
}

/** Exports a specified map as one of r16/raw, exr, jpg, png, webp, res, tres
 * r16 or exr are recommended for roundtrip external editing
 * r16 can be edited by Krita, however you must know the dimensions and min/max before reimporting
 * res/tres allow storage in any of Godot's native Image formats.
 */
Error Terrain3DStorage::export_image(String p_file_name, MapType p_map_type) {
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
	p_file_name = p_file_name.replace("\\", "/");

	// Check if p_file_name has a path and prepend "res://" if not
	bool is_simple_filename = true;
	for (int i = 0; i < p_file_name.length(); ++i) {
		char32_t c = p_file_name[i];
		if (c == '/' || c == ':') {
			is_simple_filename = false;
			break;
		}
	}
	if (is_simple_filename) {
		p_file_name = "res://" + p_file_name;
	}

	// Check if the file could be opened for writing
	Ref<FileAccess> file_ref = FileAccess::open(p_file_name, FileAccess::ModeFlags::WRITE);
	if (file_ref.is_null()) {
		LOG(ERROR, "Could not open file '" + p_file_name + "' for writing");
		return FAILED;
	}
	file_ref->close();

	// Filename is validated. Begin export image generation
	Ref<Image> img = layered_to_image(p_map_type);
	if (img.is_null() || img->is_empty()) {
		LOG(ERROR, "Could not create an export image for map type: ", TYPESTR[p_map_type]);
		return FAILED;
	}

	String ext = p_file_name.get_extension().to_lower();
	LOG(MESG, "Saving ", img->get_size(), " sized ", TYPESTR[p_map_type],
			" map in format ", img->get_format(), " as ", ext, " to: ", p_file_name);
	if (ext == "r16" || ext == "raw") {
		Vector2i minmax = Util::get_min_max(img);
		Ref<FileAccess> file = FileAccess::open(p_file_name, FileAccess::WRITE);
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
		return img->save_exr(p_file_name, (p_map_type == TYPE_HEIGHT) ? true : false);
	} else if (ext == "png") {
		return img->save_png(p_file_name);
	} else if (ext == "jpg") {
		return img->save_jpg(p_file_name);
	} else if (ext == "webp") {
		return img->save_webp(p_file_name);
	} else if ((ext == "res") || (ext == "tres")) {
		return ResourceSaver::get_singleton()->save(img, p_file_name, ResourceSaver::FLAG_COMPRESS);
	}

	LOG(ERROR, "No recognized file type. See docs for valid extensions");
	return FAILED;
}

Ref<Image> Terrain3DStorage::layered_to_image(MapType p_map_type) {
	LOG(INFO, "Generating a full sized image for all regions including empty regions");
	if (p_map_type >= TYPE_MAX) {
		p_map_type = TYPE_HEIGHT;
	}
	Vector2i top_left = Vector2i(0, 0);
	Vector2i bottom_right = Vector2i(0, 0);
	for (int i = 0; i < _region_offsets.size(); i++) {
		LOG(DEBUG, "Region offsets[", i, "]: ", _region_offsets[i]);
		Vector2i region = _region_offsets[i];
		if (region.x < top_left.x) {
			top_left.x = region.x;
		} else if (region.x > bottom_right.x) {
			bottom_right.x = region.x;
		}
		if (region.y < top_left.y) {
			top_left.y = region.y;
		} else if (region.y > bottom_right.y) {
			bottom_right.y = region.y;
		}
	}

	LOG(DEBUG, "Full range to cover all regions: ", top_left, " to ", bottom_right);
	Vector2i img_size = Vector2i(1 + bottom_right.x - top_left.x, 1 + bottom_right.y - top_left.y) * _region_size;
	LOG(DEBUG, "Image size: ", img_size);
	Ref<Image> img = Util::get_filled_image(img_size, COLOR[p_map_type], false, FORMAT[p_map_type]);

	for (int i = 0; i < _region_offsets.size(); i++) {
		Vector2i region = _region_offsets[i];
		int index = get_region_index(Vector3(region.x, 0, region.y) * _region_size);
		Vector2i img_location = (region - top_left) * _region_size;
		LOG(DEBUG, "Region to blit: ", region, " Export image coords: ", img_location);
		img->blit_rect(get_map_region(p_map_type, index), Rect2i(Vector2i(0, 0), _region_sizev), img_location);
	}
	return img;
}

Vector3 Terrain3DStorage::get_normal(Vector3 p_global_position) {
	real_t left = get_height(p_global_position + Vector3(-1.0f, 0.0f, 0.0f));
	real_t right = get_height(p_global_position + Vector3(1.0f, 0.0f, 0.0f));
	real_t back = get_height(p_global_position + Vector3(0.f, 0.f, -1.0f));
	real_t front = get_height(p_global_position + Vector3(0.f, 0.f, 1.0f));
	Vector3 horizontal = Vector3(2.0f, right - left, 0.0f);
	Vector3 vertical = Vector3(0.0f, back - front, 2.0f);
	Vector3 normal = vertical.cross(horizontal).normalized();
	normal.z *= -1.0f;
	return normal;
}

void Terrain3DStorage::print_audit_data() {
	LOG(INFO, "Dumping storage data");
	LOG(INFO, "_modified: ", _modified);
	LOG(INFO, "Region_offsets size: ", _region_offsets.size(), " ", _region_offsets);
	LOG(INFO, "Region map");
	for (int i = 0; i < _region_map.size(); i++) {
		if (_region_map[i]) {
			LOG(INFO, "Region id: ", _region_map[i], " array index: ", i);
		}
	}
	Util::dump_maps(_height_maps, "Height maps");
	Util::dump_maps(_control_maps, "Control maps");
	Util::dump_maps(_color_maps, "Color maps");

	Util::dump_gen(_generated_height_maps, "height");
	Util::dump_gen(_generated_control_maps, "control");
	Util::dump_gen(_generated_color_maps, "color");
}

// DEPRECATED 0.8.3, remove 0.9
void Terrain3DStorage::set_surfaces(const TypedArray<Terrain3DSurface> &p_surfaces) {
	set_version(0.8f);
	LOG(WARN, "Converting Surfaces to separate TextureList: ", vformat("%.3f", _version), "->", vformat("%.3f", CURRENT_VERSION));
	_texture_list.instantiate();
	TypedArray<Terrain3DTexture> textures;
	textures.resize(p_surfaces.size());

	for (int i = 0; i < p_surfaces.size(); i++) {
		LOG(DEBUG, "Converting surface: ", i);
		Ref<Terrain3DSurface> sfc = p_surfaces[i];
		Ref<Terrain3DTexture> tex;
		tex.instantiate();

		Terrain3DTexture::Settings *tex_data = tex->get_data();
		Terrain3DSurface::Settings *sfc_data = sfc->get_data();
		tex_data->_name = sfc_data->_name;
		tex_data->_texture_id = sfc_data->_surface_id;
		tex_data->_albedo_color = sfc_data->_albedo;
		tex_data->_albedo_texture = sfc_data->_albedo_texture;
		tex_data->_normal_texture = sfc_data->_normal_texture;
		tex_data->_uv_scale = sfc_data->_uv_scale;
		tex_data->_uv_rotation = sfc_data->_uv_rotation;
		textures[i] = tex;
	}
	_texture_list->set_textures(textures);
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

	ClassDB::bind_method(D_METHOD("set_version", "version"), &Terrain3DStorage::set_version);
	ClassDB::bind_method(D_METHOD("get_version"), &Terrain3DStorage::get_version);
	ClassDB::bind_method(D_METHOD("set_save_16_bit", "enabled"), &Terrain3DStorage::set_save_16_bit);
	ClassDB::bind_method(D_METHOD("get_save_16_bit"), &Terrain3DStorage::get_save_16_bit);

	ClassDB::bind_method(D_METHOD("set_height_range", "range"), &Terrain3DStorage::set_height_range);
	ClassDB::bind_method(D_METHOD("get_height_range"), &Terrain3DStorage::get_height_range);
	ClassDB::bind_method(D_METHOD("update_height_range"), &Terrain3DStorage::update_height_range);

	ClassDB::bind_method(D_METHOD("set_region_size", "size"), &Terrain3DStorage::set_region_size);
	ClassDB::bind_method(D_METHOD("get_region_size"), &Terrain3DStorage::get_region_size);
	ClassDB::bind_method(D_METHOD("set_region_offsets", "offsets"), &Terrain3DStorage::set_region_offsets);
	ClassDB::bind_method(D_METHOD("get_region_offsets"), &Terrain3DStorage::get_region_offsets);
	ClassDB::bind_method(D_METHOD("get_region_count"), &Terrain3DStorage::get_region_count);
	ClassDB::bind_method(D_METHOD("get_region_offset", "global_position"), &Terrain3DStorage::get_region_offset);
	ClassDB::bind_method(D_METHOD("get_region_index", "global_position"), &Terrain3DStorage::get_region_index);
	ClassDB::bind_method(D_METHOD("has_region", "global_position"), &Terrain3DStorage::has_region);
	ClassDB::bind_method(D_METHOD("add_region", "global_position", "images", "update"), &Terrain3DStorage::add_region, DEFVAL(TypedArray<Image>()), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("remove_region", "global_position", "update"), &Terrain3DStorage::remove_region, DEFVAL(true));

	ClassDB::bind_method(D_METHOD("set_map_region", "map_type", "region_index", "image"), &Terrain3DStorage::set_map_region);
	ClassDB::bind_method(D_METHOD("get_map_region", "map_type", "region_index"), &Terrain3DStorage::get_map_region);
	ClassDB::bind_method(D_METHOD("set_maps", "map_type", "maps"), &Terrain3DStorage::set_maps);
	ClassDB::bind_method(D_METHOD("get_maps", "map_type"), &Terrain3DStorage::get_maps);
	ClassDB::bind_method(D_METHOD("get_maps_copy", "map_type"), &Terrain3DStorage::get_maps_copy);
	ClassDB::bind_method(D_METHOD("set_height_maps", "maps"), &Terrain3DStorage::set_height_maps);
	ClassDB::bind_method(D_METHOD("get_height_maps"), &Terrain3DStorage::get_height_maps);
	ClassDB::bind_method(D_METHOD("set_control_maps", "maps"), &Terrain3DStorage::set_control_maps);
	ClassDB::bind_method(D_METHOD("get_control_maps"), &Terrain3DStorage::get_control_maps);
	ClassDB::bind_method(D_METHOD("set_color_maps", "maps"), &Terrain3DStorage::set_color_maps);
	ClassDB::bind_method(D_METHOD("get_color_maps"), &Terrain3DStorage::get_color_maps);
	ClassDB::bind_method(D_METHOD("get_pixel", "map_type", "global_position"), &Terrain3DStorage::get_pixel);
	ClassDB::bind_method(D_METHOD("get_height", "global_position"), &Terrain3DStorage::get_height);
	ClassDB::bind_method(D_METHOD("get_color", "global_position"), &Terrain3DStorage::get_color);
	ClassDB::bind_method(D_METHOD("get_control", "global_position"), &Terrain3DStorage::get_control);
	ClassDB::bind_method(D_METHOD("get_roughness", "global_position"), &Terrain3DStorage::get_roughness);
	ClassDB::bind_method(D_METHOD("get_mesh_vertex", "lod", "filter", "global_position"), &Terrain3DStorage::get_mesh_vertex);
	ClassDB::bind_method(D_METHOD("get_texture_id", "global_position"), &Terrain3DStorage::get_texture_id);
	ClassDB::bind_method(D_METHOD("force_update_maps", "map_type"), &Terrain3DStorage::force_update_maps, DEFVAL(TYPE_MAX));

	ClassDB::bind_static_method("Terrain3DStorage", D_METHOD("load_image", "file_name", "cache_mode", "r16_height_range", "r16_size"), &Terrain3DStorage::load_image, DEFVAL(ResourceLoader::CACHE_MODE_IGNORE), DEFVAL(Vector2(0, 255)), DEFVAL(Vector2i(0, 0)));
	ClassDB::bind_method(D_METHOD("import_images", "images", "global_position", "offset", "scale"), &Terrain3DStorage::import_images, DEFVAL(Vector3(0, 0, 0)), DEFVAL(0.0), DEFVAL(1.0));
	ClassDB::bind_method(D_METHOD("export_image", "file_name", "map_type"), &Terrain3DStorage::export_image);
	ClassDB::bind_method(D_METHOD("layered_to_image", "map_type"), &Terrain3DStorage::layered_to_image);
	ClassDB::bind_method(D_METHOD("get_normal", "global_position"), &Terrain3DStorage::get_normal);

	int ro_flags = PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY;
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "version", PROPERTY_HINT_NONE, "", ro_flags), "set_version", "get_version");
	//ADD_PROPERTY(PropertyInfo(Variant::INT, "region_size", PROPERTY_HINT_ENUM, "64:64, 128:128, 256:256, 512:512, 1024:1024, 2048:2048"), "set_region_size", "get_region_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "region_size", PROPERTY_HINT_ENUM, "1024:1024"), "set_region_size", "get_region_size");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "save_16_bit", PROPERTY_HINT_NONE), "set_save_16_bit", "get_save_16_bit");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "height_range", PROPERTY_HINT_NONE, "", ro_flags), "set_height_range", "get_height_range");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "region_offsets", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::VECTOR2, PROPERTY_HINT_NONE), ro_flags), "set_region_offsets", "get_region_offsets");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "height_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image"), ro_flags), "set_height_maps", "get_height_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "control_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image"), ro_flags), "set_control_maps", "get_control_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "color_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image"), ro_flags), "set_color_maps", "get_color_maps");

	ADD_SIGNAL(MethodInfo("height_maps_changed"));
	ADD_SIGNAL(MethodInfo("region_size_changed"));
	ADD_SIGNAL(MethodInfo("regions_changed"));

	// DEPRECATED 0.8.4, Remove 0.9
	int flags = PROPERTY_USAGE_NONE;
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "data_version", PROPERTY_HINT_NONE, "", flags), "set_version", "get_version");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "data_height_range", PROPERTY_HINT_NONE, "", flags), "set_height_range", "get_height_range");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "data_region_offsets", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::VECTOR2, PROPERTY_HINT_NONE), flags), "set_region_offsets", "get_region_offsets");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "data_height_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image"), flags), "set_height_maps", "get_height_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "data_control_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image"), flags), "set_control_maps", "get_control_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "data_color_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image"), flags), "set_color_maps", "get_color_maps");
	ClassDB::bind_method(D_METHOD("set_surfaces", "surfaces"), &Terrain3DStorage::set_surfaces);
	ClassDB::bind_method(D_METHOD("get_surfaces"), &Terrain3DStorage::get_surfaces);
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "data_surfaces", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DSurface"), flags), "set_surfaces", "get_surfaces");
}
