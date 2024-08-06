// Copyright © 2024 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/resource_saver.hpp>

#include "logger.h"
#include "terrain_3d_region.h"
#include "terrain_3d_storage.h"
#include "terrain_3d_util.h"

/////////////////////
// Public Functions
/////////////////////

Terrain3DRegion::Terrain3DRegion(const Ref<Image> &p_height_map, const Ref<Image> &p_control_map,
		const Ref<Image> &p_color_map, const int p_region_size) {
	_height_map = p_height_map;
	_control_map = p_control_map;
	_color_map = p_color_map;
	_region_size = p_region_size;
	sanitize_maps();
}

void Terrain3DRegion::set_version(const real_t p_version) {
	LOG(INFO, vformat("%.3f", p_version));
	_version = p_version;
	if (_version < Terrain3DStorage::CURRENT_VERSION) {
		LOG(WARN, "Region ", get_path(), " version ", vformat("%.3f", _version),
				" will be updated to ", vformat("%.3f", Terrain3DStorage::CURRENT_VERSION), " upon save");
	}
}

void Terrain3DRegion::set_height_map(const Ref<Image> &p_map) {
	Image::Format format = FORMAT[TYPE_HEIGHT];
	// This is to convert format_RH to RF, but probably unnecessary w/ sanitize
	/*if (p_map.is_valid() && p_map->get_format() != format) {
	if (p_map.is_valid() && p_map->get_format() != format) {
		LOG(DEBUG, "Converting file format: ", p_map->get_format(), " to ", format);
		if (_height_map.is_null()) {
			_height_map.instantiate();
		}
		_height_map->copy_from(p_map);
		_height_map->convert(format);
	} else {
		_height_map = p_map;
	} */
	_height_map = sanitize_map(TYPE_HEIGHT, p_map);
}

void Terrain3DRegion::set_control_map(const Ref<Image> &p_map) {
	_control_map = sanitize_map(TYPE_CONTROL, p_map);
}

void Terrain3DRegion::set_color_map(const Ref<Image> &p_map) {
	_color_map = sanitize_map(TYPE_COLOR, p_map);
}

void Terrain3DRegion::sanitize_maps(const MapType p_map_type) {
	LOG(INFO, "Verifying images maps are valid");
	if (p_map_type == TYPE_HEIGHT || p_map_type == TYPE_MAX) {
		_height_map = sanitize_map(TYPE_HEIGHT, _height_map);
	}
	if (p_map_type == TYPE_CONTROL || p_map_type == TYPE_MAX) {
		_control_map = sanitize_map(TYPE_CONTROL, _control_map);
	}
	if (p_map_type == TYPE_COLOR || p_map_type == TYPE_MAX) {
		_color_map = sanitize_map(TYPE_COLOR, _color_map);
	}
}

// Verifies region map is a valid size and format
// Creates filled blanks if lacking
Ref<Image> Terrain3DRegion::sanitize_map(const MapType p_map_type, const Ref<Image> &p_img) const {
	LOG(INFO, "Verifying images maps are valid");
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Invalid map type: ", p_map_type);
		return Ref<Image>();
	}

	Image::Format format = FORMAT[p_map_type];
	const char *type_str = TYPESTR[p_map_type];
	Color color = COLOR[p_map_type];

	if (p_img.is_valid()) {
		if (p_img->get_size() == Vector2i(_region_size, _region_size)) {
			if (p_img->get_format() == format) {
				LOG(DEBUG, "Map type ", type_str, " correct format, size. Using image");
				return p_img;
			} else {
				LOG(DEBUG, "Provided ", type_str, " map wrong format: ", p_img->get_format(), ". Converting copy to: ", format);
				Ref<Image> newimg;
				newimg.instantiate();
				newimg->copy_from(p_img);
				newimg->convert(format);
				if (newimg->get_format() == format) {
					return newimg;
				} else {
					LOG(DEBUG, "Couldn't convert image to format: ", format, ". Creating blank ");
				}
			}
		} else {
			LOG(DEBUG, "Provided ", type_str, " map wrong size: ", p_img->get_size(), ". Creating blank");
		}
	} else {
		LOG(DEBUG, "No provided ", type_str, " map. Creating blank");
	}
	return Util::get_filled_image(Vector2i(_region_size, _region_size), color, false, format);
}

Error Terrain3DRegion::save(const String &p_path, const bool p_16_bit) {
	// Initiate save to external file. The scene will save itself.
	if (!_modified) {
		LOG(INFO, "Save requested, but not modified. Skipping");
		return ERR_SKIP;
	}
	if (p_path.is_empty() && get_path().is_empty()) {
		LOG(ERROR, "No valid path provided");
		return ERR_FILE_NOT_FOUND;
	}
	String path = p_path;
	if (path.is_empty()) {
		path = get_path();
	}
	set_version(Terrain3DStorage::CURRENT_VERSION);
	LOG(INFO, "Writing", (p_16_bit) ? " 16-bit" : "", " region ", _location, " to ", path);

	Error err;
	if (p_16_bit) {
		Ref<Image> original_map;
		original_map.instantiate();
		original_map->copy_from(_height_map);
		_height_map->convert(Image::FORMAT_RH);
		err = ResourceSaver::get_singleton()->save(this, path, ResourceSaver::FLAG_COMPRESS);
		_height_map = original_map;
	} else {
		err = ResourceSaver::get_singleton()->save(this, path, ResourceSaver::FLAG_COMPRESS);
	}
	if (err == OK) {
		_modified = false;
		LOG(INFO, "File saved successfully");
	} else {
		LOG(ERROR, "Can't save region file: ", path, ". Error code: ", ERROR, ". Look up @GlobalScope Error enum in the Godot docs");
	}
	return err;
}

/////////////////////
// Protected Functions
/////////////////////

void Terrain3DRegion::_bind_methods() {
	BIND_ENUM_CONSTANT(TYPE_HEIGHT);
	BIND_ENUM_CONSTANT(TYPE_CONTROL);
	BIND_ENUM_CONSTANT(TYPE_COLOR);
	BIND_ENUM_CONSTANT(TYPE_MAX);

	ClassDB::bind_method(D_METHOD("set_version"), &Terrain3DRegion::set_version);
	ClassDB::bind_method(D_METHOD("get_version"), &Terrain3DRegion::get_version);

	ClassDB::bind_method(D_METHOD("set_height_map", "map"), &Terrain3DRegion::set_height_map);
	ClassDB::bind_method(D_METHOD("get_height_map"), &Terrain3DRegion::get_height_map);
	ClassDB::bind_method(D_METHOD("set_control_map", "map"), &Terrain3DRegion::set_control_map);
	ClassDB::bind_method(D_METHOD("get_control_map"), &Terrain3DRegion::get_control_map);
	ClassDB::bind_method(D_METHOD("set_color_map", "map"), &Terrain3DRegion::set_color_map);
	ClassDB::bind_method(D_METHOD("get_color_map"), &Terrain3DRegion::get_color_map);
	ClassDB::bind_method(D_METHOD("set_multimeshes", "multimeshes"), &Terrain3DRegion::set_multimeshes);
	ClassDB::bind_method(D_METHOD("get_multimeshes"), &Terrain3DRegion::get_multimeshes);

	ClassDB::bind_method(D_METHOD("save", "path", "16-bit"), &Terrain3DRegion::save, DEFVAL(""), DEFVAL(false));

	ClassDB::bind_method(D_METHOD("is_modified"), &Terrain3DRegion::is_modified);
	ClassDB::bind_method(D_METHOD("set_location"), &Terrain3DRegion::set_location);
	ClassDB::bind_method(D_METHOD("get_location"), &Terrain3DRegion::get_location);

	int ro_flags = PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY;
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "version", PROPERTY_HINT_NONE, "", ro_flags), "set_version", "get_version");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "heightmap", PROPERTY_HINT_RESOURCE_TYPE, "Image", ro_flags), "set_height_map", "get_height_map");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "controlmap", PROPERTY_HINT_RESOURCE_TYPE, "Image", ro_flags), "set_control_map", "get_control_map");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "colormap", PROPERTY_HINT_RESOURCE_TYPE, "Image", ro_flags), "set_color_map", "get_color_map");
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "multimeshes", PROPERTY_HINT_NONE, "", ro_flags), "set_multimeshes", "get_multimeshes");

	// The inspector only shows what's on disk, not what is in memory, so hide them. Being generated, they only show defaults
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "modified", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "", "is_modified");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2I, "location", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_location", "get_location");
}
