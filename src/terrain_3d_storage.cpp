// Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
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
	RS->free_rid(_material);
	RS->free_rid(_shader);

	_region_map_dirty = true;
	_generated_region_blend_map.clear();
	_generated_height_maps.clear();
	_generated_control_maps.clear();
	_generated_color_maps.clear();
}

void Terrain3DStorage::_update_regions() {
	if (_generated_height_maps.is_dirty()) {
		LOG(DEBUG_CONT, "Regenerating height layered texture from ", _height_maps.size(), " maps");
		_generated_height_maps.create(_height_maps);
		RS->material_set_param(_material, "height_maps", _generated_height_maps.get_rid());
		_modified = true;
		emit_signal("height_maps_changed");
	}

	if (_generated_control_maps.is_dirty()) {
		LOG(DEBUG_CONT, "Regenerating control layered texture from ", _control_maps.size(), " maps");
		_generated_control_maps.create(_control_maps);
		RS->material_set_param(_material, "control_maps", _generated_control_maps.get_rid());
		_modified = true;
	}

	if (_generated_color_maps.is_dirty()) {
		LOG(DEBUG_CONT, "Regenerating color layered texture from ", _color_maps.size(), " maps");
		_generated_color_maps.create(_color_maps);
		RS->material_set_param(_material, "color_maps", _generated_color_maps.get_rid());
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
		RS->material_set_param(_material, "region_map", _region_map);
		RS->material_set_param(_material, "region_map_size", REGION_MAP_SIZE);
		RS->material_set_param(_material, "region_offsets", _region_offsets);
		_modified = true;

		if (_noise_enabled) {
			LOG(DEBUG_CONT, "Regenerating ", Vector2i(512, 512), " region blend map");
			Ref<Image> region_blend_img = Image::create(REGION_MAP_SIZE, REGION_MAP_SIZE, false, Image::FORMAT_RH);
			for (int y = 0; y < REGION_MAP_SIZE; y++) {
				for (int x = 0; x < REGION_MAP_SIZE; x++) {
					if (_region_map[y * REGION_MAP_SIZE + x] > 0) {
						region_blend_img->set_pixel(x, y, COLOR_WHITE);
					}
				}
			}
			region_blend_img->resize(512, 512, Image::INTERPOLATE_TRILINEAR);
			_generated_region_blend_map.create(region_blend_img);
			RS->material_set_param(_material, "region_blend_map", _generated_region_blend_map.get_rid());
		}
	}
}

void Terrain3DStorage::_update_texture_arrays(const Array &args) {
	LOG(DEBUG, "Sending textures to shader");
	if (args.size() < 2) {
		LOG(ERROR, "Expecting at least 2 arguments");
		return;
	}
	RS->material_set_param(_material, "texture_array_albedo", args[0]);
	RS->material_set_param(_material, "texture_array_normal", args[1]);
	if (args.size() == 5) {
		RS->material_set_param(_material, "texture_uv_rotation_array", args[2]);
		RS->material_set_param(_material, "texture_uv_scale_array", args[3]);
		RS->material_set_param(_material, "texture_color_array", args[4]);
	}
}

// Setup_material(), and don't need it so often elsewhere
void Terrain3DStorage::_update_material() {
	LOG(INFO, "Updating material");
	if (!_material.is_valid()) {
		_material = RS->material_create();
	}

	if (!_shader.is_valid()) {
		_shader = RS->shader_create();
	}

	if (_shader_override_enabled && _shader_override.is_valid()) {
		RS->material_set_shader(_material, _shader_override->get_rid());
	} else {
		RS->shader_set_code(_shader, _generate_shader_code());
		RS->material_set_shader(_material, _shader);
	}

	RS->material_set_param(_material, "region_size", _region_size);
	RS->material_set_param(_material, "region_pixel_size", 1.0f / float(_region_size));
}

void Terrain3DStorage::_preload_shaders() {
	// Preprocessor loading of external shader inserts
	_parse_shader(
#include "shaders/world_noise.glsl"
			, "world_noise");

	_parse_shader(
#include "shaders/debug_views.glsl"
			, "debug_views");

	_shader_code["main"] = String(
#include "shaders/main.glsl"
	);

	if (Terrain3D::_debug_level >= DEBUG) {
		Array keys = _shader_code.keys();
		for (int i = 0; i < keys.size(); i++) {
			LOG(DEBUG, "Loaded shader insert: ", keys[i]);
		}
	}
}

/**
 * Dual use function that uses the same parsing mechanics for different purposes
 * if p_name has a value, Reading mode:
 *	any //INSERT: ID in p_shader is loaded into the DB _shader_code
 *	returns String()
 * else
 *	Apply mode: any //INSERT: ID is replaced by the entry in the DB
 *	returns a shader string with inserts applied
 */
String Terrain3DStorage::_parse_shader(String p_shader, String p_name, Array p_excludes) {
	PackedStringArray parsed = p_shader.split("//INSERT:");

	String shader;
	for (int i = 0; i < parsed.size(); i++) {
		// First section of the file before any //INSERT:
		if (i == 0) {
			if (!p_name.is_empty()) {
				// Load mode
				_shader_code[p_name] = parsed[0];
			} else {
				// Apply mode
				shader = parsed[0];
			}
		} else {
			// If there is at least one //INSERT:
			// Get the first ID on the first line
			PackedStringArray segment = parsed[i].split("\n", true, 1);
			// If there isn't an ID AND body, skip this insert
			if (segment.size() < 2) {
				continue;
			}
			String id = segment[0].strip_edges();

			// Process the insert
			if (!p_name.is_empty()) {
				// Load mode
				if (!id.is_empty()) {
					_shader_code[id] = segment[1];
				}
			} else {
				// Apply mode
				if (!id.is_empty() && !p_excludes.has(id)) {
					String str = _shader_code[id];
					shader += str;
				}
				shader += segment[1];
			}
		}
	}
	return shader;
}

String Terrain3DStorage::_generate_shader_code() {
	LOG(INFO, "Generating default shader code");
	Array excludes;
	if (!_noise_enabled) {
		excludes.push_back("WORLD_NOISE1");
		excludes.push_back("WORLD_NOISE2");
	}
	if (!_debug_view_checkered) {
		excludes.push_back("DEBUG_CHECKERED");
	}
	if (!_debug_view_grey) {
		excludes.push_back("DEBUG_GREY");
	}
	if (!_debug_view_heightmap) {
		excludes.push_back("DEBUG_HEIGHTMAP");
	}
	if (!_debug_view_colormap) {
		excludes.push_back("DEBUG_COLORMAP");
	}
	if (!_debug_view_roughmap) {
		excludes.push_back("DEBUG_ROUGHMAP");
	}
	if (!_debug_view_tex_height) {
		excludes.push_back("DEBUG_TEXTURE_HEIGHT");
	}
	if (!_debug_view_tex_normal) {
		excludes.push_back("DEBUG_TEXTURE_NORMAL");
	}
	if (!_debug_view_tex_rough) {
		excludes.push_back("DEBUG_TEXTURE_ROUGHNESS");
	}
	if (!_debug_view_controlmap) {
		excludes.push_back("DEBUG_CONTROLMAP");
	}
	if (!_debug_view_vertex_grid) {
		excludes.push_back("DEBUG_VERTEX_GRID");
	}
	String shader = _parse_shader(_shader_code["main"], "", excludes);
	return shader;
}

///////////////////////////
// Public Functions
///////////////////////////

Terrain3DStorage::Terrain3DStorage() {
	_region_map.resize(REGION_MAP_SIZE * REGION_MAP_SIZE);
	_preload_shaders();
	if (!_initialized) {
		LOG(INFO, "Initializing terrain storage");
		_update_material();
		_initialized = true;
	}
}

Terrain3DStorage::~Terrain3DStorage() {
	if (_initialized) {
		_clear();
	}
}

void Terrain3DStorage::set_region_size(RegionSize p_size) {
	LOG(INFO, "Setting region size: ", p_size);
	//ERR_FAIL_COND(p_size < SIZE_64);
	//ERR_FAIL_COND(p_size > SIZE_2048);
	ERR_FAIL_COND(p_size != SIZE_1024);

	_region_size = p_size;
	_region_sizev = Vector2i(_region_size, _region_size);
	RS->material_set_param(_material, "region_size", float(_region_size));
	RS->material_set_param(_material, "region_pixel_size", 1.0f / float(_region_size));
	//emit region_size_changed
}

void Terrain3DStorage::update_heights(float p_height) {
	if (p_height < _height_range.x) {
		_height_range.x = p_height;
	} else if (p_height > _height_range.y) {
		_height_range.y = p_height;
	}
}

void Terrain3DStorage::update_heights(Vector2 p_heights) {
	if (p_heights.x < _height_range.x) {
		_height_range.x = p_heights.x;
	}
	if (p_heights.y > _height_range.y) {
		_height_range.y = p_heights.y;
	}
}

void Terrain3DStorage::update_height_range() {
	_height_range = Vector2(0, 0);
	for (int i = 0; i < _height_maps.size(); i++) {
		update_heights(Util::get_min_max(_height_maps[i]));
	}
	LOG(INFO, "Updated terrain height range: ", _height_range);
}

void Terrain3DStorage::set_region_offsets(const TypedArray<Vector2i> &p_offsets) {
	LOG(INFO, "Setting region offsets with array sized: ", p_offsets.size());
	_region_offsets = p_offsets;

	_region_map_dirty = true;
	_generated_region_blend_map.clear();
	_update_regions();
}

/** Returns a region offset given a location */
Vector2i Terrain3DStorage::get_region_offset(Vector3 p_global_position) {
	return Vector2i((Vector2(p_global_position.x, p_global_position.z) / float(_region_size)).floor());
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

	// Region maps used by get_region_index so must be updated every time
	_region_map_dirty = true;
	_generated_region_blend_map.clear();
	if (p_update) {
		LOG(DEBUG, "Updating generated maps");
		_generated_height_maps.clear();
		_generated_control_maps.clear();
		_generated_color_maps.clear();
		_update_regions();
		notify_property_list_changed();
		emit_changed();
	} else {
		_update_regions();
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

	// Region maps used by get_region_index so must be updated
	_region_map_dirty = true;
	_generated_region_blend_map.clear();
	if (p_update) {
		LOG(DEBUG, "Updating generated maps");
		_generated_height_maps.clear();
		_generated_control_maps.clear();
		_generated_color_maps.clear();
		_update_regions();
		notify_property_list_changed();
		emit_changed();
	} else {
		_update_regions();
	}
}

void Terrain3DStorage::set_map_region(MapType p_map_type, int p_region_index, const Ref<Image> p_image) {
	switch (p_map_type) {
		case TYPE_HEIGHT:
			if (p_region_index >= 0 && p_region_index < _height_maps.size()) {
				_height_maps[p_region_index] = p_image;
			} else {
				LOG(ERROR, "Requested index is out of bounds. height_maps size: ", _height_maps.size());
			}
			break;
		case TYPE_CONTROL:
			if (p_region_index >= 0 && p_region_index < _control_maps.size()) {
				_control_maps[p_region_index] = p_image;
			} else {
				LOG(ERROR, "Requested index is out of bounds. control_maps size: ", _control_maps.size());
			}
			break;
		case TYPE_COLOR:
			if (p_region_index >= 0 && p_region_index < _color_maps.size()) {
				_color_maps[p_region_index] = p_image;
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
	_control_maps = sanitize_maps(TYPE_CONTROL, p_maps);
	force_update_maps(TYPE_CONTROL);
}

void Terrain3DStorage::set_color_maps(const TypedArray<Image> &p_maps) {
	LOG(INFO, "Setting color maps: ", p_maps.size());
	_color_maps = sanitize_maps(TYPE_COLOR, p_maps);
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
	_update_regions();
}

void Terrain3DStorage::save() {
	if (!_modified) {
		LOG(DEBUG, "Save requested, but not modified. Skipping");
		return;
	}
	String path = get_path();
	LOG(DEBUG, "Attempting to save terrain data to: " + path);
	if (path.get_extension() == "tres" || path.get_extension() == "res") {
		LOG(DEBUG, "Saving storage version: ", vformat("%.2f", CURRENT_VERSION));
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
				float h = float(file->get_16()) / 65535.0f;
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
void Terrain3DStorage::import_images(const TypedArray<Image> &p_images, Vector3 p_global_position, float p_offset, float p_scale) {
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
	int slices_width = ceil(float(img_size.x) / float(_region_size));
	int slices_height = ceil(float(img_size.y) / float(_region_size));
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
	if (p_file_name.is_empty()) {
		LOG(ERROR, "No file specified. Nothing to export");
		return FAILED;
	}
	if (get_region_count() == 0) {
		LOG(ERROR, "No valid regions. Nothing to export");
		return FAILED;
	}

	Ref<Image> img;
	switch (p_map_type) {
		case TYPE_HEIGHT:
			img = _generated_height_maps.get_image();
			break;
		case TYPE_CONTROL:
			img = _generated_control_maps.get_image();
			break;
		case TYPE_COLOR:
			img = _generated_color_maps.get_image();
			break;
		default:
			LOG(ERROR, "Invalid map type specified: ", p_map_type, " max: ", TYPE_MAX - 1);
			return FAILED;
	}

	if (img.is_null()) {
		LOG(DEBUG, "Generated image is invalid or empty");
		img = layered_to_image(p_map_type);
	}
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
		float height_min = minmax.x;
		float height_max = minmax.y;
		float hscale = 65535.0 / (height_max - height_min);
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

void Terrain3DStorage::set_shader_override(const Ref<Shader> &p_shader) {
	LOG(INFO, "Setting override shader");
	_shader_override = p_shader;
	_update_material();
}

void Terrain3DStorage::enable_shader_override(bool p_enabled) {
	LOG(INFO, "Enable shader override: ", p_enabled);
	_shader_override_enabled = p_enabled;
	if (_shader_override_enabled && _shader_override.is_null()) {
		String code = _generate_shader_code();
		Ref<Shader> shader_res;
		shader_res.instantiate();
		shader_res->set_code(code);
		set_shader_override(shader_res);
	} else {
		_update_material();
	}
}

void Terrain3DStorage::set_show_checkered(bool p_enabled) {
	LOG(INFO, "Enable set_show_checkered: ", p_enabled);
	_debug_view_checkered = p_enabled;
	_update_material();
}

void Terrain3DStorage::set_show_grey(bool p_enabled) {
	LOG(INFO, "Enable show_grey: ", p_enabled);
	_debug_view_grey = p_enabled;
	_update_material();
}

void Terrain3DStorage::set_show_heightmap(bool p_enabled) {
	LOG(INFO, "Enable show_heightmap: ", p_enabled);
	_debug_view_heightmap = p_enabled;
	_update_material();
}

void Terrain3DStorage::set_show_colormap(bool p_enabled) {
	LOG(INFO, "Enable show_colormap: ", p_enabled);
	_debug_view_colormap = p_enabled;
	_update_material();
}

void Terrain3DStorage::set_show_roughmap(bool p_enabled) {
	LOG(INFO, "Enable show_roughmap: ", p_enabled);
	_debug_view_roughmap = p_enabled;
	_update_material();
}

void Terrain3DStorage::set_show_controlmap(bool p_enabled) {
	LOG(INFO, "Enable show_controlmap: ", p_enabled);
	_debug_view_controlmap = p_enabled;
	_update_material();
}

void Terrain3DStorage::set_show_texture_height(bool p_enabled) {
	LOG(INFO, "Enable show_texture_height: ", p_enabled);
	_debug_view_tex_height = p_enabled;
	_update_material();
}

void Terrain3DStorage::set_show_texture_normal(bool p_enabled) {
	LOG(INFO, "Enable show_texture_normal: ", p_enabled);
	_debug_view_tex_normal = p_enabled;
	_update_material();
}

void Terrain3DStorage::set_show_texture_rough(bool p_enabled) {
	LOG(INFO, "Enable show_texture_rough: ", p_enabled);
	_debug_view_tex_rough = p_enabled;
	_update_material();
}

void Terrain3DStorage::set_show_vertex_grid(bool p_enabled) {
	LOG(INFO, "Enable show_vertex_grid: ", p_enabled);
	_debug_view_vertex_grid = p_enabled;
	_update_material();
}

void Terrain3DStorage::set_noise_enabled(bool p_enabled) {
	LOG(INFO, "Enable noise: ", p_enabled);
	_noise_enabled = p_enabled;
	_update_material();
	if (_noise_enabled) {
		_region_map_dirty = true;
		_generated_region_blend_map.clear();
		_update_regions();
	}
}

void Terrain3DStorage::set_noise_scale(float p_scale) {
	LOG(INFO, "Setting noise scale: ", p_scale);
	_noise_scale = p_scale;
	RS->material_set_param(_material, "noise_scale", _noise_scale);
}

void Terrain3DStorage::set_noise_height(float p_height) {
	LOG(INFO, "Setting noise height: ", p_height);
	_noise_height = p_height;
	RS->material_set_param(_material, "noise_height", _noise_height);
}

void Terrain3DStorage::set_noise_blend_near(float p_near) {
	LOG(INFO, "Setting noise blend near: ", p_near);
	_noise_blend_near = p_near;
	if (_noise_blend_near > _noise_blend_far) {
		set_noise_blend_far(_noise_blend_near);
	}
	RS->material_set_param(_material, "noise_blend_near", _noise_blend_near);
}

void Terrain3DStorage::set_noise_blend_far(float p_far) {
	LOG(INFO, "Setting noise blend far: ", p_far);
	_noise_blend_far = p_far;
	if (_noise_blend_far < _noise_blend_near) {
		set_noise_blend_near(_noise_blend_far);
	}
	RS->material_set_param(_material, "noise_blend_far", _noise_blend_far);
}

void Terrain3DStorage::print_audit_data() {
	LOG(INFO, "Dumping storage data");

	LOG(INFO, "_initialized: ", _initialized);
	LOG(INFO, "_modified: ", _modified);
	LOG(INFO, "Region_offsets size: ", _region_offsets.size(), " ", _region_offsets);
	LOG(INFO, "Map type height size: ", _height_maps.size(), " ", _height_maps);
	for (int i = 0; i < _height_maps.size(); i++) {
		Ref<Image> img = _height_maps[i];
		LOG(INFO, "\tMap size: ", img->get_size(), " format: ", img->get_format());
	}
	LOG(INFO, "Map type control size: ", _control_maps.size(), " ", _control_maps);
	for (int i = 0; i < _control_maps.size(); i++) {
		Ref<Image> img = _control_maps[i];
		LOG(INFO, "\tMap size: ", img->get_size(), " format: ", img->get_format());
	}
	LOG(INFO, "Map type color size: ", _color_maps.size(), " ", _color_maps);
	for (int i = 0; i < _color_maps.size(); i++) {
		Ref<Image> img = _color_maps[i];
		LOG(INFO, "\tMap size: ", img->get_size(), " format: ", img->get_format());
	}

	LOG(INFO, "generated_region_blend_map RID: ", _generated_region_blend_map.get_rid(), ", dirty: ", _generated_region_blend_map.is_dirty(), ", image: ", _generated_region_blend_map.get_image());
	LOG(INFO, "generated_height_maps RID: ", _generated_height_maps.get_rid(), ", dirty: ", _generated_height_maps.is_dirty(), ", image: ", _generated_height_maps.get_image());
	LOG(INFO, "generated_control_maps RID: ", _generated_control_maps.get_rid(), ", dirty: ", _generated_control_maps.is_dirty(), ", image: ", _generated_control_maps.get_image());
	LOG(INFO, "generated_color_maps RID: ", _generated_color_maps.get_rid(), ", dirty: ", _generated_color_maps.is_dirty(), ", image: ", _generated_color_maps.get_image());
}

// DEPRECATED 0.8.3, remove 0.9-1.0
void Terrain3DStorage::set_surfaces(const TypedArray<Terrain3DSurface> &p_surfaces) {
	LOG(WARN, "Converting old Surfaces to separate TextureList resource");
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

	BIND_CONSTANT(REGION_MAP_SIZE);

	ClassDB::bind_method(D_METHOD("set_region_size", "size"), &Terrain3DStorage::set_region_size);
	ClassDB::bind_method(D_METHOD("get_region_size"), &Terrain3DStorage::get_region_size);
	ClassDB::bind_method(D_METHOD("set_save_16_bit", "enabled"), &Terrain3DStorage::set_save_16_bit);
	ClassDB::bind_method(D_METHOD("get_save_16_bit"), &Terrain3DStorage::get_save_16_bit);
	ClassDB::bind_method(D_METHOD("set_version", "version"), &Terrain3DStorage::set_version);
	ClassDB::bind_method(D_METHOD("get_version"), &Terrain3DStorage::get_version);

	ClassDB::bind_method(D_METHOD("set_height_range", "range"), &Terrain3DStorage::set_height_range);
	ClassDB::bind_method(D_METHOD("get_height_range"), &Terrain3DStorage::get_height_range);
	ClassDB::bind_method(D_METHOD("update_height_range"), &Terrain3DStorage::update_height_range);

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
	ClassDB::bind_method(D_METHOD("force_update_maps", "map_type"), &Terrain3DStorage::force_update_maps, DEFVAL(TYPE_MAX));

	ClassDB::bind_static_method("Terrain3DStorage", D_METHOD("load_image", "file_name", "cache_mode", "r16_height_range", "r16_size"), &Terrain3DStorage::load_image, DEFVAL(ResourceLoader::CACHE_MODE_IGNORE), DEFVAL(Vector2(0, 255)), DEFVAL(Vector2i(0, 0)));
	ClassDB::bind_method(D_METHOD("import_images", "images", "global_position", "offset", "scale"), &Terrain3DStorage::import_images, DEFVAL(Vector3(0, 0, 0)), DEFVAL(0.0), DEFVAL(1.0));
	ClassDB::bind_method(D_METHOD("export_image", "file_name", "map_type"), &Terrain3DStorage::export_image);
	ClassDB::bind_method(D_METHOD("layered_to_image", "map_type"), &Terrain3DStorage::layered_to_image);

	ClassDB::bind_method(D_METHOD("set_shader_override", "shader"), &Terrain3DStorage::set_shader_override);
	ClassDB::bind_method(D_METHOD("get_shader_override"), &Terrain3DStorage::get_shader_override);
	ClassDB::bind_method(D_METHOD("enable_shader_override", "enabled"), &Terrain3DStorage::enable_shader_override);
	ClassDB::bind_method(D_METHOD("is_shader_override_enabled"), &Terrain3DStorage::is_shader_override_enabled);
	ClassDB::bind_method(D_METHOD("set_show_checkered", "enabled"), &Terrain3DStorage::set_show_checkered);
	ClassDB::bind_method(D_METHOD("get_show_checkered"), &Terrain3DStorage::get_show_checkered);
	ClassDB::bind_method(D_METHOD("set_show_grey", "enabled"), &Terrain3DStorage::set_show_grey);
	ClassDB::bind_method(D_METHOD("get_show_grey"), &Terrain3DStorage::get_show_grey);
	ClassDB::bind_method(D_METHOD("set_show_heightmap", "enabled"), &Terrain3DStorage::set_show_heightmap);
	ClassDB::bind_method(D_METHOD("get_show_heightmap"), &Terrain3DStorage::get_show_heightmap);
	ClassDB::bind_method(D_METHOD("set_show_colormap", "enabled"), &Terrain3DStorage::set_show_colormap);
	ClassDB::bind_method(D_METHOD("get_show_colormap"), &Terrain3DStorage::get_show_colormap);
	ClassDB::bind_method(D_METHOD("set_show_roughmap", "enabled"), &Terrain3DStorage::set_show_roughmap);
	ClassDB::bind_method(D_METHOD("get_show_roughmap"), &Terrain3DStorage::get_show_roughmap);
	ClassDB::bind_method(D_METHOD("set_show_controlmap", "enabled"), &Terrain3DStorage::set_show_controlmap);
	ClassDB::bind_method(D_METHOD("get_show_controlmap"), &Terrain3DStorage::get_show_controlmap);
	ClassDB::bind_method(D_METHOD("set_show_texture_height", "enabled"), &Terrain3DStorage::set_show_texture_height);
	ClassDB::bind_method(D_METHOD("get_show_texture_height"), &Terrain3DStorage::get_show_texture_height);
	ClassDB::bind_method(D_METHOD("set_show_texture_normal", "enabled"), &Terrain3DStorage::set_show_texture_normal);
	ClassDB::bind_method(D_METHOD("get_show_texture_normal"), &Terrain3DStorage::get_show_texture_normal);
	ClassDB::bind_method(D_METHOD("set_show_texture_rough", "enabled"), &Terrain3DStorage::set_show_texture_rough);
	ClassDB::bind_method(D_METHOD("get_show_texture_rough"), &Terrain3DStorage::get_show_texture_rough);
	ClassDB::bind_method(D_METHOD("set_show_vertex_grid", "enabled"), &Terrain3DStorage::set_show_vertex_grid);
	ClassDB::bind_method(D_METHOD("get_show_vertex_grid"), &Terrain3DStorage::get_show_vertex_grid);

	ClassDB::bind_method(D_METHOD("set_noise_enabled", "enabled"), &Terrain3DStorage::set_noise_enabled);
	ClassDB::bind_method(D_METHOD("get_noise_enabled"), &Terrain3DStorage::get_noise_enabled);
	ClassDB::bind_method(D_METHOD("set_noise_scale", "scale"), &Terrain3DStorage::set_noise_scale);
	ClassDB::bind_method(D_METHOD("get_noise_scale"), &Terrain3DStorage::get_noise_scale);
	ClassDB::bind_method(D_METHOD("set_noise_height", "height"), &Terrain3DStorage::set_noise_height);
	ClassDB::bind_method(D_METHOD("get_noise_height"), &Terrain3DStorage::get_noise_height);
	ClassDB::bind_method(D_METHOD("set_noise_blend_near", "fade"), &Terrain3DStorage::set_noise_blend_near);
	ClassDB::bind_method(D_METHOD("get_noise_blend_near"), &Terrain3DStorage::get_noise_blend_near);
	ClassDB::bind_method(D_METHOD("set_noise_blend_far", "sharpness"), &Terrain3DStorage::set_noise_blend_far);
	ClassDB::bind_method(D_METHOD("get_noise_blend_far"), &Terrain3DStorage::get_noise_blend_far);
	ClassDB::bind_method(D_METHOD("get_region_blend_map"), &Terrain3DStorage::get_region_blend_map);

	//Private
	ClassDB::bind_method(D_METHOD("_update_texture_arrays", "args"), &Terrain3DStorage::_update_texture_arrays);

	//ADD_PROPERTY(PropertyInfo(Variant::INT, "region_size", PROPERTY_HINT_ENUM, "64:64, 128:128, 256:256, 512:512, 1024:1024, 2048:2048"), "set_region_size", "get_region_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "region_size", PROPERTY_HINT_ENUM, "1024:1024"), "set_region_size", "get_region_size");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "save_16_bit", PROPERTY_HINT_NONE), "set_save_16_bit", "get_save_16_bit");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "shader_override_enabled", PROPERTY_HINT_NONE), "enable_shader_override", "is_shader_override_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "shader_override", PROPERTY_HINT_RESOURCE_TYPE, "Shader"), "set_shader_override", "get_shader_override");

	ADD_GROUP("Debug Views", "show_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_checkered", PROPERTY_HINT_NONE), "set_show_checkered", "get_show_checkered");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_grey", PROPERTY_HINT_NONE), "set_show_grey", "get_show_grey");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_heightmap", PROPERTY_HINT_NONE), "set_show_heightmap", "get_show_heightmap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_colormap", PROPERTY_HINT_NONE), "set_show_colormap", "get_show_colormap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_roughmap", PROPERTY_HINT_NONE), "set_show_roughmap", "get_show_roughmap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_controlmap", PROPERTY_HINT_NONE), "set_show_controlmap", "get_show_controlmap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_height", PROPERTY_HINT_NONE), "set_show_texture_height", "get_show_texture_height");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_normal", PROPERTY_HINT_NONE), "set_show_texture_normal", "get_show_texture_normal");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_rough", PROPERTY_HINT_NONE), "set_show_texture_rough", "get_show_texture_rough");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_vertex_grid", PROPERTY_HINT_NONE), "set_show_vertex_grid", "get_show_vertex_grid");

	ADD_GROUP("World Noise", "noise_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "noise_enabled", PROPERTY_HINT_NONE), "set_noise_enabled", "get_noise_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_scale", PROPERTY_HINT_RANGE, "0.0, 10.0"), "set_noise_scale", "get_noise_scale");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_height", PROPERTY_HINT_RANGE, "0.0, 1000.0"), "set_noise_height", "get_noise_height");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_blend_near", PROPERTY_HINT_RANGE, "0.0, .999"), "set_noise_blend_near", "get_noise_blend_near");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_blend_far", PROPERTY_HINT_RANGE, "0.0, 1.0"), "set_noise_blend_far", "get_noise_blend_far");

	ADD_GROUP("Read Only", "data_");
	int ro_flags = PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY;
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "data_version", PROPERTY_HINT_NONE, "", ro_flags), "set_version", "get_version");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "data_height_range", PROPERTY_HINT_NONE, "", ro_flags), "set_height_range", "get_height_range");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "data_region_offsets", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::VECTOR2, PROPERTY_HINT_NONE), ro_flags), "set_region_offsets", "get_region_offsets");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "data_height_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image"), ro_flags), "set_height_maps", "get_height_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "data_control_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image"), ro_flags), "set_control_maps", "get_control_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "data_color_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image"), ro_flags), "set_color_maps", "get_color_maps");

	ADD_SIGNAL(MethodInfo("height_maps_changed"));

	// DEPRECATED 0.8.3, Remove 0.9-1.0
	ClassDB::bind_method(D_METHOD("set_surfaces", "surfaces"), &Terrain3DStorage::set_surfaces);
	ClassDB::bind_method(D_METHOD("get_surfaces"), &Terrain3DStorage::get_surfaces);
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "data_surfaces", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DSurface"), ro_flags), "set_surfaces", "get_surfaces");
}
