// Copyright © 2024 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/resource_saver.hpp>

#include "logger.h"
#include "terrain_3d_region.h"
#include "terrain_3d_storage.h"
#include "terrain_3d_util.h"

/////////////////////
// Public Functions
/////////////////////

void Terrain3DRegion::set_version(const real_t p_version) {
	LOG(INFO, vformat("%.3f", p_version));
	_version = p_version;
	if (_version < Terrain3DStorage::CURRENT_VERSION) {
		LOG(WARN, "Region ", get_path(), " version ", vformat("%.3f", _version),
				" will be updated to ", vformat("%.3f", Terrain3DStorage::CURRENT_VERSION), " upon save");
	}
}

void Terrain3DRegion::set_map(const MapType p_map_type, const Ref<Image> &p_image) {
	switch (p_map_type) {
		case TYPE_HEIGHT:
			set_height_map(p_image);
			break;
		case TYPE_CONTROL:
			set_control_map(p_image);
			break;
		case TYPE_COLOR:
			set_color_map(p_image);
			break;
		default:
			LOG(ERROR, "Requested map type is invalid");
			break;
	}
}

Ref<Image> Terrain3DRegion::get_map(const MapType p_map_type) const {
	switch (p_map_type) {
		case TYPE_HEIGHT:
			return get_height_map();
			break;
		case TYPE_CONTROL:
			return get_control_map();
			break;
		case TYPE_COLOR:
			return get_color_map();
			break;
		default:
			LOG(ERROR, "Requested map type is invalid");
			return Ref<Image>();
	}
}

void Terrain3DRegion::set_maps(const TypedArray<Image> &p_maps) {
	if (p_maps.size() != TYPE_MAX) {
		LOG(ERROR, "Expected ", TYPE_MAX - 1, " maps. Received ", p_maps.size());
		return;
	}
	LOG(INFO, "Setting maps for region: ", _location);
	_height_map = p_maps[TYPE_HEIGHT];
	_control_map = p_maps[TYPE_CONTROL];
	_color_map = p_maps[TYPE_COLOR];
	sanitize_map(TYPE_MAX);
}

TypedArray<Image> Terrain3DRegion::get_maps() const {
	LOG(INFO, "Retrieving maps from region: ", _location);
	TypedArray<Image> maps;
	maps.push_back(_height_map);
	maps.push_back(_control_map);
	maps.push_back(_color_map);
	return maps;
}

void Terrain3DRegion::set_height_map(const Ref<Image> &p_map) {
	LOG(INFO, "Setting height map for region: ", (_location.x != INT32_MAX) ? String(_location) : "(new)");
	_height_map = p_map;
	sanitize_map(TYPE_HEIGHT);
}

void Terrain3DRegion::set_control_map(const Ref<Image> &p_map) {
	LOG(INFO, "Setting control map for region: ", (_location.x != INT32_MAX) ? String(_location) : "(new)");
	_control_map = p_map;
	sanitize_map(TYPE_CONTROL);
}

void Terrain3DRegion::set_color_map(const Ref<Image> &p_map) {
	LOG(INFO, "Setting color map for region: ", (_location.x != INT32_MAX) ? String(_location) : "(new)");
	_color_map = p_map;
	sanitize_map(TYPE_COLOR);
}

// Verifies region map is a valid size and format
// Creates filled blanks if lacking
void Terrain3DRegion::sanitize_map(const MapType p_map_type) {
	if (p_map_type < 0 || p_map_type > TYPE_MAX) {
		LOG(ERROR, "Invalid map type: ", p_map_type);
		return;
	}
	LOG(INFO, "Verifying image maps type: ", TYPESTR[p_map_type], " are valid for region: ", (_location.x != INT32_MAX) ? String(_location) : "(new)");

	TypedArray<int> queued_map_types;
	if (p_map_type == TYPE_MAX) {
		queued_map_types.push_back(TYPE_HEIGHT);
		queued_map_types.push_back(TYPE_CONTROL);
		queued_map_types.push_back(TYPE_COLOR);
	} else {
		queued_map_types.push_back(p_map_type);
	}

	for (int i = 0; i < queued_map_types.size(); i++) {
		MapType type = (MapType)(int)queued_map_types[i];
		const char *type_str = TYPESTR[type];
		Image::Format format = FORMAT[type];
		Color color = COLOR[type];

		Ref<Image> map = get_map(type);

		if (map.is_valid()) {
			if (map->get_size() == Vector2i(_region_size, _region_size)) {
				if (map->get_format() == format) {
					LOG(DEBUG, "Map type ", type_str, " correct format, size. Mipmaps: ", map->has_mipmaps());
					if (type == TYPE_HEIGHT) {
						calc_height_range();
					}
					if (type == TYPE_COLOR && !map->has_mipmaps()) {
						LOG(DEBUG, "Color map does not have mipmaps. Generating");
						map->generate_mipmaps();
					}
					continue;
				} else {
					LOG(DEBUG, "Provided ", type_str, " map wrong format: ", map->get_format(), ". Converting copy to: ", format);
					Ref<Image> newimg;
					newimg.instantiate();
					newimg->copy_from(map);
					newimg->convert(format);
					if (type == TYPE_COLOR && !map->has_mipmaps()) {
						LOG(DEBUG, "Color map does not have mipmaps. Generating");
						newimg->generate_mipmaps();
					}
					if (newimg->get_format() == format) {
						set_map(type, newimg);
						continue;
					} else {
						LOG(DEBUG, "Cannot convert image to format: ", format, ". Creating blank ");
					}
				}
			} else {
				LOG(DEBUG, "Provided ", type_str, " map wrong size: ", map->get_size(), ". Creating blank");
			}
		} else {
			LOG(DEBUG, "No provided ", type_str, " map. Creating blank");
		}
		LOG(DEBUG, "Making new image of type: ", type_str, " and generating mipmaps: ", type == TYPE_COLOR);
		set_map(type, Util::get_filled_image(Vector2i(_region_size, _region_size), color, type == TYPE_COLOR, format));
	}
}

void Terrain3DRegion::set_height_range(const Vector2 &p_range) {
	LOG(INFO, vformat("%.2v", p_range));
	if (_height_range != p_range) {
		// If initial value, we're loading it from disk, else mark modified
		if (_height_range != V2_ZERO) {
			_modified = true;
		}
		_height_range = p_range;
	}
}

void Terrain3DRegion::calc_height_range() {
	Vector2 range = Util::get_min_max(_height_map);
	if (_height_range != range) {
		_height_range = range;
		_modified = true;
		LOG(DEBUG, "Recalculated new height range: ", _height_range, " for region: ", (_location.x != INT32_MAX) ? String(_location) : "(new)", ". Marking modified");
	}
}

Error Terrain3DRegion::save(const String &p_path, const bool p_16_bit) {
	// Initiate save to external file. The scene will save itself.
	//LOG(WARN, "Saving region: ", _location, " modified: ", _modified, " path: ", get_path(), ", to : ", p_path);
	if (_location.x == INT32_MAX) {
		LOG(ERROR, "Region has not been setup. Location is INT32_MAX. Skipping ", p_path);
	}
	if (!_modified) {
		LOG(DEBUG, "Region ", _location, " not modified. Skipping ", p_path);
		return ERR_SKIP;
	}
	if (p_path.is_empty() && get_path().is_empty()) {
		LOG(ERROR, "No valid path provided");
		return ERR_FILE_NOT_FOUND;
	}
	if (get_path().is_empty() && !p_path.is_empty()) {
		LOG(DEBUG, "Setting file path for region ", _location, " to ", p_path);
		take_over_path(p_path);
		// Set region path and take over the path from any other cached resources,
		// incuding those in the undo queue
	}
	LOG(INFO, "Writing", (p_16_bit) ? " 16-bit" : "", " region ", _location, " to ", get_path());
	set_version(Terrain3DStorage::CURRENT_VERSION);
	Error err;
	if (p_16_bit) {
		Ref<Image> original_map;
		original_map.instantiate();
		original_map->copy_from(_height_map);
		_height_map->convert(Image::FORMAT_RH);
		err = ResourceSaver::get_singleton()->save(this, get_path(), ResourceSaver::FLAG_COMPRESS);
		_height_map = original_map;
	} else {
		err = ResourceSaver::get_singleton()->save(this, get_path(), ResourceSaver::FLAG_COMPRESS);
	}
	if (err == OK) {
		_modified = false;
		LOG(INFO, "File saved successfully");
	} else {
		LOG(ERROR, "Cannot save region file: ", get_path(), ". Error code: ", ERROR, ". Look up @GlobalScope Error enum in the Godot docs");
	}
	return err;
}

void Terrain3DRegion::set_location(const Vector2i &p_location) {
	// In the future anywhere they want to put the location might be fine, but because of region_map
	// We have a limitation of 16x16 and eventually 45x45.
	if (Terrain3DStorage::get_region_map_index(p_location) < 0) {
		LOG(ERROR, "Location ", p_location, " out of bounds. Max: ",
				-Terrain3DStorage::REGION_MAP_SIZE / 2, " to ", Terrain3DStorage::REGION_MAP_SIZE / 2 - 1);
		return;
	}
	LOG(INFO, "Set location: ", p_location);
	_location = p_location;
}

void Terrain3DRegion::set_data(const Dictionary &p_data) {
#define SET_IF_HAS(var, str) \
	if (p_data.has(str)) {   \
		var = p_data[str];   \
	}
	SET_IF_HAS(_location, "location");
	SET_IF_HAS(_deleted, "deleted");
	SET_IF_HAS(_edited, "edited");
	SET_IF_HAS(_modified, "modified");
	SET_IF_HAS(_version, "version");
	SET_IF_HAS(_region_size, "region_size");
	SET_IF_HAS(_height_range, "height_range");
	SET_IF_HAS(_height_map, "height_map");
	SET_IF_HAS(_control_map, "control_map");
	SET_IF_HAS(_color_map, "color_map");
	SET_IF_HAS(_multimeshes, "multimeshes");
}

Dictionary Terrain3DRegion::get_data() const {
	Dictionary dict;
	dict["location"] = _location;
	dict["deleted"] = _deleted;
	dict["edited"] = _edited;
	dict["modified"] = _modified;
	dict["instance_id"] = String::num_uint64(get_instance_id()); // don't commit
	dict["version"] = _version;
	dict["region_size"] = _region_size;
	dict["height_range"] = _height_range;
	dict["height_map"] = _height_map;
	dict["control_map"] = _control_map;
	dict["color_map"] = _color_map;
	dict["multimeshes"] = _multimeshes;
	return dict;
}

Ref<Terrain3DRegion> Terrain3DRegion::duplicate(const bool p_deep) {
	Ref<Terrain3DRegion> region;
	region.instantiate();
	if (!p_deep) {
		region->set_data(get_data());
	} else {
		Dictionary dict;
		// Native type copies
		dict["version"] = _version;
		dict["region_size"] = _region_size;
		dict["height_range"] = _height_range;
		dict["modified"] = _modified;
		dict["deleted"] = _deleted;
		dict["location"] = _location;
		// Resource duplicates
		dict["height_map"] = _height_map->duplicate();
		dict["control_map"] = _control_map->duplicate();
		dict["color_map"] = _color_map->duplicate();
		Dictionary mms;
		Array keys = _multimeshes.keys();
		for (int i = 0; i < keys.size(); i++) {
			int mesh_id = keys[i];
			Ref<MultiMesh> mm = _multimeshes[mesh_id];
			mm->duplicate();
			mms[mesh_id] = mm;
		}
		dict["multimeshes"] = mms;
		region->set_data(dict);
	}
	return region;
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

	ClassDB::bind_method(D_METHOD("set_height_range", "range"), &Terrain3DRegion::set_height_range);
	ClassDB::bind_method(D_METHOD("get_height_range"), &Terrain3DRegion::get_height_range);
	ClassDB::bind_method(D_METHOD("update_height", "height"), &Terrain3DRegion::update_height);
	ClassDB::bind_method(D_METHOD("update_heights", "low_high"), &Terrain3DRegion::update_heights);
	ClassDB::bind_method(D_METHOD("calc_height_range"), &Terrain3DRegion::calc_height_range);

	ClassDB::bind_method(D_METHOD("set_multimeshes", "multimeshes"), &Terrain3DRegion::set_multimeshes);
	ClassDB::bind_method(D_METHOD("get_multimeshes"), &Terrain3DRegion::get_multimeshes);

	ClassDB::bind_method(D_METHOD("save", "path", "16-bit"), &Terrain3DRegion::save, DEFVAL(""), DEFVAL(false));

	ClassDB::bind_method(D_METHOD("set_deleted"), &Terrain3DRegion::set_deleted);
	ClassDB::bind_method(D_METHOD("is_deleted"), &Terrain3DRegion::is_deleted);
	ClassDB::bind_method(D_METHOD("set_edited"), &Terrain3DRegion::set_edited);
	ClassDB::bind_method(D_METHOD("is_edited"), &Terrain3DRegion::is_edited);
	ClassDB::bind_method(D_METHOD("set_modified"), &Terrain3DRegion::set_modified);
	ClassDB::bind_method(D_METHOD("is_modified"), &Terrain3DRegion::is_modified);
	ClassDB::bind_method(D_METHOD("set_location"), &Terrain3DRegion::set_location);
	ClassDB::bind_method(D_METHOD("get_location"), &Terrain3DRegion::get_location);

	ClassDB::bind_method(D_METHOD("set_data"), &Terrain3DRegion::set_data);
	ClassDB::bind_method(D_METHOD("get_data"), &Terrain3DRegion::get_data);
	ClassDB::bind_method(D_METHOD("duplicate", "deep"), &Terrain3DRegion::duplicate, DEFVAL(false));

	int ro_flags = PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY;
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "version", PROPERTY_HINT_NONE, "", ro_flags), "set_version", "get_version");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "height_range", PROPERTY_HINT_NONE, "", ro_flags), "set_height_range", "get_height_range");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "heightmap", PROPERTY_HINT_RESOURCE_TYPE, "Image", ro_flags), "set_height_map", "get_height_map");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "controlmap", PROPERTY_HINT_RESOURCE_TYPE, "Image", ro_flags), "set_control_map", "get_control_map");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "colormap", PROPERTY_HINT_RESOURCE_TYPE, "Image", ro_flags), "set_color_map", "get_color_map");
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "multimeshes", PROPERTY_HINT_NONE, "", ro_flags), "set_multimeshes", "get_multimeshes");

	// Double-clicking a region .res file shows what's on disk, the defaults, not in memory. So these are hidden
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "edited", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_edited", "is_edited");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "deleted", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_deleted", "is_deleted");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "modified", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_modified", "is_modified");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2I, "location", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_location", "get_location");
}
