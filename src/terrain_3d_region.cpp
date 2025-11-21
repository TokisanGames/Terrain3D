// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/resource_saver.hpp>

#include "logger.h"
#include "terrain_3d_data.h"
#include "terrain_3d_layer.h"
#include "terrain_3d_region.h"
#include "terrain_3d_util.h"

/////////////////////
// Public Functions
/////////////////////

TypedArray<Terrain3DLayer> &Terrain3DRegion::_get_layers_ref(const MapType p_map_type) {
	switch (p_map_type) {
		case TYPE_HEIGHT:
			return _height_layers;
		case TYPE_CONTROL:
			return _control_layers;
		case TYPE_COLOR:
			return _color_layers;
		default:
			return _height_layers;
	}
}

const TypedArray<Terrain3DLayer> &Terrain3DRegion::_get_layers_ref(const MapType p_map_type) const {
	switch (p_map_type) {
		case TYPE_HEIGHT:
			return _height_layers;
		case TYPE_CONTROL:
			return _control_layers;
		case TYPE_COLOR:
			return _color_layers;
		default:
			return _height_layers;
	}
}

bool &Terrain3DRegion::_get_layers_dirty(const MapType p_map_type) const {
	switch (p_map_type) {
		case TYPE_HEIGHT:
			return const_cast<bool &>(_height_layers_dirty);
		case TYPE_CONTROL:
			return const_cast<bool &>(_control_layers_dirty);
		case TYPE_COLOR:
			return const_cast<bool &>(_color_layers_dirty);
		default:
			return const_cast<bool &>(_height_layers_dirty);
	}
}

Ref<Image> &Terrain3DRegion::_get_baked_map(const MapType p_map_type) const {
	switch (p_map_type) {
		case TYPE_HEIGHT:
			return const_cast<Ref<Image> &>(_baked_height_map);
		case TYPE_CONTROL:
			return const_cast<Ref<Image> &>(_baked_control_map);
		case TYPE_COLOR:
			return const_cast<Ref<Image> &>(_baked_color_map);
		default:
			return const_cast<Ref<Image> &>(_baked_height_map);
	}
}

void Terrain3DRegion::mark_layers_dirty(const MapType p_map_type, const bool p_mark_modified) const {
	bool &dirty = _get_layers_dirty(p_map_type);
	dirty = true;
	Ref<Image> &cache = _get_baked_map(p_map_type);
	if (cache.is_valid()) {
		cache.unref();
	}
	if (p_mark_modified) {
		const_cast<Terrain3DRegion *>(this)->set_edited(true);
		const_cast<Terrain3DRegion *>(this)->set_modified(true);
	}
}

TypedArray<Terrain3DLayer> Terrain3DRegion::get_layers(const MapType p_map_type) const {
	return _get_layers_ref(p_map_type);
}

void Terrain3DRegion::set_layers(const MapType p_map_type, const TypedArray<Terrain3DLayer> &p_layers) {
	TypedArray<Terrain3DLayer> &layers = _get_layers_ref(p_map_type);
	layers = p_layers;
	for (int i = 0; i < layers.size(); i++) {
		Ref<Terrain3DLayer> layer = layers[i];
		if (layer.is_valid()) {
			layer->set_map_type(p_map_type);
		}
	}
	mark_layers_dirty(p_map_type);
}

Ref<Terrain3DLayer> Terrain3DRegion::add_layer(const MapType p_map_type, const Ref<Terrain3DLayer> &p_layer, const int p_index) {
	TypedArray<Terrain3DLayer> &layers = _get_layers_ref(p_map_type);
	Ref<Terrain3DLayer> layer = p_layer;
	if (layer.is_null()) {
		layer.instantiate();
		layer->set_map_type(p_map_type);
	}
	if (p_index >= 0 && p_index < layers.size()) {
		layers.insert(p_index, layer);
	} else {
		layers.push_back(layer);
	}
	mark_layers_dirty(p_map_type);
	if (layer.is_valid()) {
		int expected_size = _region_size;
		if (!is_valid_region_size(expected_size)) {
			Ref<Image> base_map = get_map(p_map_type);
			if (base_map.is_valid()) {
				expected_size = MAX(base_map->get_width(), base_map->get_height());
			}
		}
		if (expected_size > 0) {
			Vector2i expected_dims(expected_size, expected_size);
			Rect2i coverage = layer->get_coverage();
			if (!coverage.has_area()) {
				layer->set_coverage(Rect2i(Vector2i(), expected_dims));
			}
			Ref<Image> payload = layer->get_payload();
			bool payload_invalid = payload.is_null() || payload->get_width() <= 0 || payload->get_height() <= 0;
			if (payload_invalid) {
				Ref<Image> init_payload = Util::get_filled_image(expected_dims, COLOR_BLACK, false, map_type_get_format(p_map_type));
				layer->set_payload(init_payload);
			}
		} else {
			static int invalid_layer_dims_log_count = 0;
			if (invalid_layer_dims_log_count < 5) {
				LOG(WARN, "Unable to initialize layer payload; expected size unresolved for map type ", p_map_type, " in region ", _location);
				invalid_layer_dims_log_count++;
			}
		}
	}
	return layer;
}

void Terrain3DRegion::remove_layer(const MapType p_map_type, const int p_index) {
	TypedArray<Terrain3DLayer> &layers = _get_layers_ref(p_map_type);
	if (p_index < 0 || p_index >= layers.size()) {
		return;
	}
	layers.remove_at(p_index);
	mark_layers_dirty(p_map_type);
}

void Terrain3DRegion::clear_layers(const MapType p_map_type) {
	TypedArray<Terrain3DLayer> &layers = _get_layers_ref(p_map_type);
	layers.clear();
	mark_layers_dirty(p_map_type);
}

Ref<Image> Terrain3DRegion::get_composited_map(const MapType p_map_type) const {
	const TypedArray<Terrain3DLayer> &layers = _get_layers_ref(p_map_type);
	Ref<Image> base = get_map(p_map_type);
	if (layers.is_empty() || base.is_null()) {
		return base;
	}
	Ref<Image> &cache = _get_baked_map(p_map_type);
	bool &dirty = _get_layers_dirty(p_map_type);
	if (dirty || cache.is_null()) {
		cache = base->duplicate();
		if (cache.is_null()) {
			return base;
		}
		for (int i = 0; i < layers.size(); i++) {
			Ref<Terrain3DLayer> layer = layers[i];
			if (layer.is_null()) {
				continue;
			}
			layer->set_map_type(p_map_type);
			layer->apply(*cache.ptr(), _vertex_spacing);
		}
		dirty = false;
	}
	return cache;
}

void Terrain3DRegion::set_version(const real_t p_version) {
	real_t version = CLAMP(p_version, 0.8f, 100.f);
	if (_version == version) {
		return;
	}
	// Mark modified if already initialized and we get a new value
	if (_version > 0.8f) {
		_modified = true;
	}
	_version = version;
	LOG(INFO, vformat("%.3f", _version));
	if (_version < Terrain3DData::CURRENT_VERSION) {
		LOG(WARN, "Region ", get_path(), " version ", vformat("%.3f", _version),
				" will be updated to ", vformat("%.3f", Terrain3DData::CURRENT_VERSION), " upon save");
	}
}

void Terrain3DRegion::set_region_size(const int p_region_size) {
	if (!is_valid_region_size(p_region_size)) {
		LOG(ERROR, "Invalid region size: ", p_region_size, ". Must be power of 2, 64-2048");
		return;
	}
	// Mark modified if already initialized and we get a new value
	if (_region_size > 0 && _region_size != p_region_size) {
		_modified = true;
	}
	SET_IF_DIFF(_region_size, p_region_size);
	LOG(INFO, "Setting region ", _location, " size: ", p_region_size);
	mark_layers_dirty(TYPE_HEIGHT, false);
	mark_layers_dirty(TYPE_CONTROL, false);
	mark_layers_dirty(TYPE_COLOR, false);
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
		case TYPE_CONTROL:
			return get_control_map();
		case TYPE_COLOR:
			return get_color_map();
		default:
			LOG(ERROR, "Requested map type ", p_map_type, ", is invalid");
			return Ref<Image>();
	}
}

Image *Terrain3DRegion::get_map_ptr(const MapType p_map_type) const {
	switch (p_map_type) {
		case TYPE_HEIGHT:
			return *_height_map;
		case TYPE_CONTROL:
			return *_control_map;
		case TYPE_COLOR:
			return *_color_map;
		default:
			LOG(ERROR, "Requested map type ", p_map_type, ", is invalid");
			return nullptr;
	}
}

void Terrain3DRegion::set_maps(const TypedArray<Image> &p_maps) {
	if (p_maps.size() != TYPE_MAX) {
		LOG(ERROR, "Expected ", TYPE_MAX - 1, " maps. Received ", p_maps.size());
		return;
	}
	_region_size = 0;
	set_height_map(p_maps[TYPE_HEIGHT]);
	set_control_map(p_maps[TYPE_CONTROL]);
	set_color_map(p_maps[TYPE_COLOR]);
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
	SET_IF_DIFF(_height_map, p_map);
	LOG(INFO, "Setting height map for region: ", (_location.x != INT32_MAX) ? String(_location) : "(new)");
	if (_region_size == 0 && p_map.is_valid()) {
		set_region_size(p_map->get_width());
	}
	Ref<Image> map = sanitize_map(TYPE_HEIGHT, p_map);
	// If already initialized and receiving a new map, or the map was sanitized
	if (_height_map.is_valid() && _height_map != p_map || map != p_map) {
		_modified = true;
	}
	_height_map = map;
	calc_height_range();
	mark_layers_dirty(TYPE_HEIGHT);
}

void Terrain3DRegion::set_control_map(const Ref<Image> &p_map) {
	SET_IF_DIFF(_control_map, p_map);
	LOG(INFO, "Setting control map for region: ", (_location.x != INT32_MAX) ? String(_location) : "(new)");
	if (_region_size == 0 && p_map.is_valid()) {
		set_region_size(p_map->get_width());
	}
	Ref<Image> map = sanitize_map(TYPE_CONTROL, p_map);
	// If already initialized and receiving a new map, or the map was sanitized
	if (_control_map.is_valid() && _control_map != p_map || map != p_map) {
		_modified = true;
	}
	_control_map = map;
	mark_layers_dirty(TYPE_CONTROL);
}

void Terrain3DRegion::set_color_map(const Ref<Image> &p_map) {
	SET_IF_DIFF(_color_map, p_map);
	LOG(INFO, "Setting color map for region: ", (_location.x != INT32_MAX) ? String(_location) : "(new)");
	if (_region_size == 0 && p_map.is_valid()) {
		set_region_size(p_map->get_width());
	}
	Ref<Image> map = sanitize_map(TYPE_COLOR, p_map);
	// If already initialized and receiving a new map, or the map was sanitized
	if (_color_map.is_valid() && _color_map != p_map || map != p_map) {
		_modified = true;
	}
	_color_map = map;
	mark_layers_dirty(TYPE_COLOR);
}

void Terrain3DRegion::sanitize_maps() {
	if (_region_size == 0) { // blank region, no set_*_map has been called
		LOG(ERROR, "Set region_size first");
		return;
	}
	Ref<Image> map = sanitize_map(TYPE_HEIGHT, _height_map);
	if (_height_map != map) {
		_modified = true;
	}
	_height_map = map;
	mark_layers_dirty(TYPE_HEIGHT);
	map = sanitize_map(TYPE_CONTROL, _control_map);
	if (_control_map != map) {
		_modified = true;
	}
	_control_map = map;
	mark_layers_dirty(TYPE_CONTROL);
	map = sanitize_map(TYPE_COLOR, _color_map);
	if (_color_map != map) {
		_modified = true;
	}
	_color_map = map;
	mark_layers_dirty(TYPE_COLOR);
}

Ref<Image> Terrain3DRegion::sanitize_map(const MapType p_map_type, const Ref<Image> &p_map) const {
	LOG(INFO, "Sanitizing map type: ", p_map_type, ", map: ", p_map);
	if (!is_valid_region_size(_region_size)) {
		LOG(ERROR, "Invalid region size: ", _region_size, ". Set it or set a map first. Must be power of 2, 64-2048");
		return Ref<Image>();
	}
	const char *type_str = TYPESTR[p_map_type];
	Image::Format format = FORMAT[p_map_type];
	Color color = COLOR[p_map_type];
	Ref<Image> map;

	if (p_map.is_valid()) {
		if (validate_map_size(p_map)) {
			if (p_map->get_format() == format) {
				LOG(DEBUG, "Map type ", type_str, " correct format, size. Mipmaps: ", p_map->has_mipmaps());
				map = p_map;
			} else {
				LOG(DEBUG, "Provided ", type_str, " map wrong format: ", p_map->get_format(), ". Converting copy to: ", format);
				map.instantiate();
				map->copy_from(p_map);
				map->convert(format);
				if (map->get_format() != format) {
					LOG(DEBUG, "Cannot convert image to format: ", format, ". Creating blank ");
					map.unref();
				}
			}
		} else {
			LOG(DEBUG, "Provided ", type_str, " map wrong size: ", p_map->get_size(), ". Creating blank");
		}
	} else {
		LOG(DEBUG, "No provided ", type_str, " map. Creating blank");
	}
	if (map.is_null()) {
		LOG(DEBUG, "Making new image of type: ", type_str, " and generating mipmaps: ", p_map_type == TYPE_COLOR);
		return Util::get_filled_image(V2I(_region_size), color, p_map_type == TYPE_COLOR, format);
	} else {
		if (p_map_type == TYPE_COLOR && !map->has_mipmaps()) {
			LOG(DEBUG, "Color map does not have mipmaps. Generating");
			map->generate_mipmaps();
		}
		return map;
	}
}

bool Terrain3DRegion::validate_map_size(const Ref<Image> &p_map) const {
	Vector2i region_sizev = p_map->get_size();
	if (region_sizev.x != region_sizev.y) {
		LOG(ERROR, "Image width doesn't match height: ", region_sizev);
		return false;
	}
	if (!is_valid_region_size(region_sizev.x) || !is_valid_region_size(region_sizev.y)) {
		LOG(ERROR, "Invalid image size: ", region_sizev, ". Must be power of 2, 64-2048 and square");
		return false;
	}
	if (_region_size != region_sizev.x || _region_size != region_sizev.y) {
		LOG(ERROR, "Image size doesn't match existing images in this region", region_sizev);
		return false;
	}
	return true;
}

void Terrain3DRegion::set_height_range(const Vector2 &p_range) {
	if (differs(_height_range, p_range)) {
		// Mark modified if setting after initialization
		if (!_height_range.is_zero_approx()) {
			_modified = true;
		}
		_height_range = p_range;
		LOG(INFO, vformat("%.2v", p_range));
	} else {
		return;
	};
}

void Terrain3DRegion::calc_height_range() {
	Vector2 range = Util::get_min_max(_height_map);
	if (_height_range != range) {
		_height_range = range;
		_modified = true;
		LOG(DEBUG, "Recalculated new height range: ", _height_range, " for region: ", (_location.x != INT32_MAX) ? String(_location) : "(new)", ". Marking modified");
	}
}

void Terrain3DRegion::set_instances(const Dictionary &p_instances) {
	if (!_instances.is_empty() && differs(_instances, p_instances)) {
		_modified = true;
	}
	SET_IF_DIFF(_instances, p_instances);
	LOG(INFO, "Region ", _location, " setting instances ptr: ", ptr_to_str(p_instances._native_ptr()));
}

void Terrain3DRegion::set_location(const Vector2i &p_location) {
	// In the future anywhere they want to put the location might be fine, but because of region_map
	// We have a limitation of 32x32.
	if (Terrain3DData::get_region_map_index(p_location) < 0) {
		LOG(ERROR, "Location ", p_location, " out of bounds. Max: ",
				-Terrain3DData::REGION_MAP_SIZE / 2, " to ", Terrain3DData::REGION_MAP_SIZE / 2 - 1);
		return;
	}
	// Marked modified if setting after initialized
	if (_location < V2I_MAX && _location != p_location) {
		_modified = true;
	}
	SET_IF_DIFF(_location, p_location);
	LOG(INFO, "Set location: ", p_location);
}

Error Terrain3DRegion::save(const String &p_path, const bool p_16_bit) {
	// Initiate save to external file. The scene will save itself.
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
	if (!p_path.is_empty()) {
		LOG(DEBUG, "Setting file path for region ", _location, " to ", p_path);
		take_over_path(p_path);
		// Set region path and take over the path from any other cached resources,
		// incuding those in the undo queue
	}
	LOG(MESG, "Writing", (p_16_bit) ? " 16-bit" : "", " region ", _location, " to ", get_path());
	set_version(Terrain3DData::CURRENT_VERSION);
	Error err = OK;
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
	SET_IF_HAS(_vertex_spacing, "vertex_spacing");
	SET_IF_HAS(_height_range, "height_range");
	SET_IF_HAS(_height_map, "height_map");
	SET_IF_HAS(_control_map, "control_map");
	SET_IF_HAS(_color_map, "color_map");
	SET_IF_HAS(_instances, "instances");
#undef SET_IF_HAS
	if (p_data.has("height_layers")) {
		Array height_layers = p_data["height_layers"];
		_height_layers = height_layers;
	}
	if (p_data.has("control_layers")) {
		Array control_layers = p_data["control_layers"];
		_control_layers = control_layers;
	}
	if (p_data.has("color_layers")) {
		Array color_layers = p_data["color_layers"];
		_color_layers = color_layers;
	}
	for (int i = 0; i < _height_layers.size(); i++) {
		Ref<Terrain3DLayer> layer = _height_layers[i];
		if (layer.is_valid()) {
			layer->set_map_type(TYPE_HEIGHT);
		}
	}
	for (int i = 0; i < _control_layers.size(); i++) {
		Ref<Terrain3DLayer> layer = _control_layers[i];
		if (layer.is_valid()) {
			layer->set_map_type(TYPE_CONTROL);
		}
	}
	for (int i = 0; i < _color_layers.size(); i++) {
		Ref<Terrain3DLayer> layer = _color_layers[i];
		if (layer.is_valid()) {
			layer->set_map_type(TYPE_COLOR);
		}
	}
	mark_layers_dirty(TYPE_HEIGHT);
	mark_layers_dirty(TYPE_CONTROL);
	mark_layers_dirty(TYPE_COLOR);
}

Dictionary Terrain3DRegion::get_data() const {
	Dictionary dict;
	dict["location"] = _location;
	dict["deleted"] = _deleted;
	dict["edited"] = _edited;
	dict["modified"] = _modified;
	dict["version"] = _version;
	dict["region_size"] = _region_size;
	dict["vertex_spacing"] = _vertex_spacing;
	dict["height_range"] = _height_range;
	dict["height_map"] = _height_map;
	dict["control_map"] = _control_map;
	dict["color_map"] = _color_map;
	dict["instances"] = _instances;
	dict["height_layers"] = _height_layers;
	dict["control_layers"] = _control_layers;
	dict["color_layers"] = _color_layers;
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
		dict["vertex_spacing"] = _vertex_spacing;
		dict["height_range"] = _height_range;
		dict["modified"] = _modified;
		dict["deleted"] = _deleted;
		dict["location"] = _location;
		// Resource duplicates
		dict["height_map"] = _height_map->duplicate();
		dict["control_map"] = _control_map->duplicate();
		dict["color_map"] = _color_map->duplicate();
		dict["instances"] = _instances.duplicate(true);
		{
			TypedArray<Terrain3DLayer> layers;
			for (int i = 0; i < _height_layers.size(); i++) {
				Ref<Terrain3DLayer> layer = _height_layers[i];
				Ref<Terrain3DLayer> copy = layer;
				if (layer.is_valid()) {
					Ref<Resource> dup_res = layer->duplicate();
					Ref<Terrain3DLayer> dup_layer = dup_res;
					if (dup_layer.is_valid()) {
						copy = dup_layer;
					}
				}
				layers.push_back(copy);
			}
			dict["height_layers"] = layers;
		}
		{
			TypedArray<Terrain3DLayer> layers;
			for (int i = 0; i < _control_layers.size(); i++) {
				Ref<Terrain3DLayer> layer = _control_layers[i];
				Ref<Terrain3DLayer> copy = layer;
				if (layer.is_valid()) {
					Ref<Resource> dup_res = layer->duplicate();
					Ref<Terrain3DLayer> dup_layer = dup_res;
					if (dup_layer.is_valid()) {
						copy = dup_layer;
					}
				}
				layers.push_back(copy);
			}
			dict["control_layers"] = layers;
		}
		{
			TypedArray<Terrain3DLayer> layers;
			for (int i = 0; i < _color_layers.size(); i++) {
				Ref<Terrain3DLayer> layer = _color_layers[i];
				Ref<Terrain3DLayer> copy = layer;
				if (layer.is_valid()) {
					Ref<Resource> dup_res = layer->duplicate();
					Ref<Terrain3DLayer> dup_layer = dup_res;
					if (dup_layer.is_valid()) {
						copy = dup_layer;
					}
				}
				layers.push_back(copy);
			}
			dict["color_layers"] = layers;
		}
		region->set_data(dict);
	}
	return region;
}

void Terrain3DRegion::dump(const bool verbose) const {
	LOG(MESG, "Region: ", _location, ", version: ", vformat("%.2f", _version), ", size: ", _region_size,
			", spacing: ", vformat("%.1f", _vertex_spacing), ", range: ", vformat("%.2v", _height_range),
			", flags (", _edited ? "ed," : "", _modified ? "mod," : "", _deleted ? "del" : "", "), ",
			ptr_to_str(this));
	LOG(MESG, "Height map: ", ptr_to_str(*_height_map), ", Control map: ", ptr_to_str(*_control_map),
			", Color map: ", ptr_to_str(*_color_map));
	LOG(MESG, "Instances: Mesh IDs: ", _instances.size(), ", ", ptr_to_str(_instances._native_ptr()));
	Array mesh_ids = _instances.keys();
	for (const int &mesh_id : mesh_ids) {
		int counter = 0;
		Dictionary cell_inst_dict = _instances[mesh_id];
		Array cells = cell_inst_dict.keys();
		for (const Vector2i &cell : cells) {
			Array triple = cell_inst_dict[cell];
			if (triple.size() == 3) {
				counter += Array(triple[0]).size();
			} else {
				LOG(WARN, "Malformed triple at cell ", cell, ": ", triple);
				continue;
			}
			if (verbose) {
				Array xforms = triple[0];
				Array colors = triple[1];
				bool modified = triple[2];
				LOG(MESG, "Mesh ID: ", mesh_id, " cell: ", cell, " xforms: ", xforms.size(),
						", colors: ", colors.size(), modified ? ", modified" : "");
			}
		}
		LOG(MESG, "Mesh ID: ", mesh_id, ", instance count: ", counter);
	}
}

/////////////////////
// Protected Functions
/////////////////////

void Terrain3DRegion::_bind_methods() {
	BIND_ENUM_CONSTANT(TYPE_HEIGHT);
	BIND_ENUM_CONSTANT(TYPE_CONTROL);
	BIND_ENUM_CONSTANT(TYPE_COLOR);
	BIND_ENUM_CONSTANT(TYPE_MAX);

	ClassDB::bind_method(D_METHOD("set_version", "version"), &Terrain3DRegion::set_version);
	ClassDB::bind_method(D_METHOD("get_version"), &Terrain3DRegion::get_version);
	ClassDB::bind_method(D_METHOD("set_region_size", "region_size"), &Terrain3DRegion::set_region_size);
	ClassDB::bind_method(D_METHOD("get_region_size"), &Terrain3DRegion::get_region_size);
	ClassDB::bind_method(D_METHOD("set_vertex_spacing", "vertex_spacing"), &Terrain3DRegion::set_vertex_spacing);
	ClassDB::bind_method(D_METHOD("get_vertex_spacing"), &Terrain3DRegion::get_vertex_spacing);

	ClassDB::bind_method(D_METHOD("set_map", "map_type", "map"), &Terrain3DRegion::set_map);
	ClassDB::bind_method(D_METHOD("get_map", "map_type"), &Terrain3DRegion::get_map);
	ClassDB::bind_method(D_METHOD("set_maps", "maps"), &Terrain3DRegion::set_maps);
	ClassDB::bind_method(D_METHOD("get_maps"), &Terrain3DRegion::get_maps);
	ClassDB::bind_method(D_METHOD("get_layers", "map_type"), &Terrain3DRegion::get_layers);
	ClassDB::bind_method(D_METHOD("set_layers", "map_type", "layers"), &Terrain3DRegion::set_layers);
	ClassDB::bind_method(D_METHOD("set_height_layers", "layers"), &Terrain3DRegion::set_height_layers);
	ClassDB::bind_method(D_METHOD("get_height_layers"), &Terrain3DRegion::get_height_layers);
	ClassDB::bind_method(D_METHOD("set_control_layers", "layers"), &Terrain3DRegion::set_control_layers);
	ClassDB::bind_method(D_METHOD("get_control_layers"), &Terrain3DRegion::get_control_layers);
	ClassDB::bind_method(D_METHOD("set_color_layers", "layers"), &Terrain3DRegion::set_color_layers);
	ClassDB::bind_method(D_METHOD("get_color_layers"), &Terrain3DRegion::get_color_layers);
	ClassDB::bind_method(D_METHOD("mark_layers_dirty", "map_type", "mark_modified"), &Terrain3DRegion::mark_layers_dirty, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_layer", "map_type", "layer", "index"), &Terrain3DRegion::add_layer, DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("remove_layer", "map_type", "index"), &Terrain3DRegion::remove_layer);
	ClassDB::bind_method(D_METHOD("clear_layers", "map_type"), &Terrain3DRegion::clear_layers);
	ClassDB::bind_method(D_METHOD("get_composited_map", "map_type"), &Terrain3DRegion::get_composited_map);
	ClassDB::bind_method(D_METHOD("set_height_map", "map"), &Terrain3DRegion::set_height_map);
	ClassDB::bind_method(D_METHOD("get_height_map"), &Terrain3DRegion::get_height_map);
	ClassDB::bind_method(D_METHOD("set_control_map", "map"), &Terrain3DRegion::set_control_map);
	ClassDB::bind_method(D_METHOD("get_control_map"), &Terrain3DRegion::get_control_map);
	ClassDB::bind_method(D_METHOD("set_color_map", "map"), &Terrain3DRegion::set_color_map);
	ClassDB::bind_method(D_METHOD("get_color_map"), &Terrain3DRegion::get_color_map);
	ClassDB::bind_method(D_METHOD("sanitize_maps"), &Terrain3DRegion::sanitize_maps);
	ClassDB::bind_method(D_METHOD("sanitize_map", "map_type", "map"), &Terrain3DRegion::sanitize_map);
	ClassDB::bind_method(D_METHOD("validate_map_size", "map"), &Terrain3DRegion::validate_map_size);

	ClassDB::bind_method(D_METHOD("set_height_range", "range"), &Terrain3DRegion::set_height_range);
	ClassDB::bind_method(D_METHOD("get_height_range"), &Terrain3DRegion::get_height_range);
	ClassDB::bind_method(D_METHOD("update_height", "height"), &Terrain3DRegion::update_height);
	ClassDB::bind_method(D_METHOD("update_heights", "low_high"), &Terrain3DRegion::update_heights);
	ClassDB::bind_method(D_METHOD("calc_height_range"), &Terrain3DRegion::calc_height_range);

	ClassDB::bind_method(D_METHOD("set_instances", "instances"), &Terrain3DRegion::set_instances);
	ClassDB::bind_method(D_METHOD("get_instances"), &Terrain3DRegion::get_instances);

	ClassDB::bind_method(D_METHOD("save", "path", "save_16_bit"), &Terrain3DRegion::save, DEFVAL(""), DEFVAL(false));

	ClassDB::bind_method(D_METHOD("set_deleted", "deleted"), &Terrain3DRegion::set_deleted);
	ClassDB::bind_method(D_METHOD("is_deleted"), &Terrain3DRegion::is_deleted);
	ClassDB::bind_method(D_METHOD("set_edited", "edited"), &Terrain3DRegion::set_edited);
	ClassDB::bind_method(D_METHOD("is_edited"), &Terrain3DRegion::is_edited);
	ClassDB::bind_method(D_METHOD("set_modified", "modified"), &Terrain3DRegion::set_modified);
	ClassDB::bind_method(D_METHOD("is_modified"), &Terrain3DRegion::is_modified);
	ClassDB::bind_method(D_METHOD("set_location", "location"), &Terrain3DRegion::set_location);
	ClassDB::bind_method(D_METHOD("get_location"), &Terrain3DRegion::get_location);

	ClassDB::bind_method(D_METHOD("set_data", "data"), &Terrain3DRegion::set_data);
	ClassDB::bind_method(D_METHOD("get_data"), &Terrain3DRegion::get_data);
	ClassDB::bind_method(D_METHOD("duplicate", "deep"), &Terrain3DRegion::duplicate, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("dump", "verbose"), &Terrain3DRegion::dump, DEFVAL(false));

	int ro_flags = PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY;
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "version", PROPERTY_HINT_NONE, "", ro_flags), "set_version", "get_version");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "region_size", PROPERTY_HINT_NONE, "", ro_flags), "set_region_size", "get_region_size");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "vertex_spacing", PROPERTY_HINT_NONE, "", ro_flags), "set_vertex_spacing", "get_vertex_spacing");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "height_range", PROPERTY_HINT_NONE, "", ro_flags), "set_height_range", "get_height_range");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "height_map", PROPERTY_HINT_RESOURCE_TYPE, "Image", ro_flags), "set_height_map", "get_height_map");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "control_map", PROPERTY_HINT_RESOURCE_TYPE, "Image", ro_flags), "set_control_map", "get_control_map");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "color_map", PROPERTY_HINT_RESOURCE_TYPE, "Image", ro_flags), "set_color_map", "get_color_map");
	int layer_flags = PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_INTERNAL;
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "height_layers", PROPERTY_HINT_ARRAY_TYPE, "Terrain3DLayer", layer_flags), "set_height_layers", "get_height_layers");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "control_layers", PROPERTY_HINT_ARRAY_TYPE, "Terrain3DLayer", layer_flags), "set_control_layers", "get_control_layers");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "color_layers", PROPERTY_HINT_ARRAY_TYPE, "Terrain3DLayer", layer_flags), "set_color_layers", "get_color_layers");
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "instances", PROPERTY_HINT_NONE, "", ro_flags), "set_instances", "get_instances");

	// Double-clicking a region .res file shows what's on disk, the defaults, not in memory. So these are hidden
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "edited", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_edited", "is_edited");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "deleted", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_deleted", "is_deleted");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "modified", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_modified", "is_modified");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2I, "location", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_location", "get_location");
}
