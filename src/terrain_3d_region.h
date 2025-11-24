// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_REGION_CLASS_H
#define TERRAIN3D_REGION_CLASS_H

#include "constants.h"
#include "terrain_3d_map.h"
#include "terrain_3d_util.h"

class Terrain3DLayer;
class Terrain3DStampLayer;
class Terrain3DCurveLayer;

class Terrain3DRegion : public Resource {
	GDCLASS(Terrain3DRegion, Resource);
	CLASS_NAME();

private:
	TypedArray<Terrain3DLayer> &_get_layers_ref(const MapType p_map_type);
	const TypedArray<Terrain3DLayer> &_get_layers_ref(const MapType p_map_type) const;
	bool &_get_layers_dirty(const MapType p_map_type) const;
	bool &_get_dirty_rect_valid(const MapType p_map_type) const;
	Rect2i &_get_dirty_rect(const MapType p_map_type) const;
	Ref<Image> &_get_baked_map(const MapType p_map_type) const;
	Rect2i _clamp_rect_to_map(const MapType p_map_type, const Rect2i &p_rect) const;
	void _apply_layers_to_rect(const MapType p_map_type, Image &p_target, const Rect2i &p_rect) const;
	// Saved data
	real_t _version = 0.8f; // Set to first version to ensure we always upgrades this
	int _region_size = 0;
	Vector2 _height_range = V2_ZERO;
	// Maps
	Ref<Image> _height_map;
	Ref<Image> _control_map;
	Ref<Image> _color_map;
	TypedArray<Terrain3DLayer> _height_layers;
	TypedArray<Terrain3DLayer> _control_layers;
	TypedArray<Terrain3DLayer> _color_layers;
	mutable Ref<Image> _baked_height_map;
	mutable Ref<Image> _baked_control_map;
	mutable Ref<Image> _baked_color_map;
	mutable bool _height_layers_dirty = true;
	mutable bool _control_layers_dirty = true;
	mutable bool _color_layers_dirty = true;
	mutable Rect2i _height_dirty_rect;
	mutable Rect2i _control_dirty_rect;
	mutable Rect2i _color_dirty_rect;
	mutable bool _height_dirty_rect_valid = false;
	mutable bool _control_dirty_rect_valid = false;
	mutable bool _color_dirty_rect_valid = false;
	// Instancer
	Dictionary _instances; // Meshes{int} -> Cells{v2i} -> [ Transform3D, Color, Modified ]
	real_t _vertex_spacing = 1.f; // Spacing that instancer transforms are currently scaled by.

	// Working data not saved to disk
	bool _deleted = false; // Marked for deletion on save
	bool _edited = false; // Marked for undo/redo storage
	bool _modified = false; // Marked for saving
	Vector2i _location = V2I_MAX;

public:
	Terrain3DRegion() {}
	~Terrain3DRegion() {}

	void set_version(const real_t p_version);
	real_t get_version() const { return _version; }
	void set_region_size(const int p_region_size);
	int get_region_size() const { return _region_size; }

	// Maps
	void set_map(const MapType p_map_type, const Ref<Image> &p_image);
	Ref<Image> get_map(const MapType p_map_type) const;
	Image *get_map_ptr(const MapType p_map_type) const;
	void set_maps(const TypedArray<Image> &p_maps);
	TypedArray<Image> get_maps() const;
	TypedArray<Terrain3DLayer> get_layers(const MapType p_map_type) const;
	void set_layers(const MapType p_map_type, const TypedArray<Terrain3DLayer> &p_layers);
	Ref<Terrain3DLayer> add_layer(const MapType p_map_type, const Ref<Terrain3DLayer> &p_layer, const int p_index = -1);
	void remove_layer(const MapType p_map_type, const int p_index);
	void clear_layers(const MapType p_map_type);
	Ref<Image> get_composited_map(const MapType p_map_type) const;
	void mark_layers_dirty(const MapType p_map_type, const bool p_mark_modified = true) const;
	void mark_layers_dirty_rect(const MapType p_map_type, const Rect2i &p_rect, const bool p_mark_modified = true) const;
	void set_height_map(const Ref<Image> &p_map);
	Ref<Image> get_height_map() const { return _height_map; }
	void set_control_map(const Ref<Image> &p_map);
	Ref<Image> get_control_map() const { return _control_map; }
	void set_color_map(const Ref<Image> &p_map);
	Ref<Image> get_color_map() const { return _color_map; }
	void set_height_layers(const TypedArray<Terrain3DLayer> &p_layers) { set_layers(TYPE_HEIGHT, p_layers); }
	TypedArray<Terrain3DLayer> get_height_layers() const { return _height_layers; }
	void set_control_layers(const TypedArray<Terrain3DLayer> &p_layers) { set_layers(TYPE_CONTROL, p_layers); }
	TypedArray<Terrain3DLayer> get_control_layers() const { return _control_layers; }
	void set_color_layers(const TypedArray<Terrain3DLayer> &p_layers) { set_layers(TYPE_COLOR, p_layers); }
	TypedArray<Terrain3DLayer> get_color_layers() const { return _color_layers; }
	void sanitize_maps();
	Ref<Image> sanitize_map(const MapType p_map_type, const Ref<Image> &p_map) const;
	bool validate_map_size(const Ref<Image> &p_map) const;

	void set_height_range(const Vector2 &p_range);
	Vector2 get_height_range() const { return _height_range; }
	void update_height(const real_t p_height);
	void update_heights(const Vector2 &p_low_high);
	void calc_height_range();

	// Instancer
	void set_instances(const Dictionary &p_instances);
	Dictionary get_instances() const { return _instances; }
	void set_vertex_spacing(const real_t p_vertex_spacing) {
		_vertex_spacing = CLAMP(p_vertex_spacing, 0.25f, 100.f);
		mark_layers_dirty(TYPE_HEIGHT);
		mark_layers_dirty(TYPE_CONTROL);
		mark_layers_dirty(TYPE_COLOR);
	}
	real_t get_vertex_spacing() const { return _vertex_spacing; }

	// Working Data
	void set_deleted(const bool p_deleted) { _deleted = p_deleted; }
	bool is_deleted() const { return _deleted; }
	void set_edited(const bool p_edited) { _edited = p_edited; }
	bool is_edited() const { return _edited; }
	void set_modified(const bool p_modified) { _modified = p_modified; }
	bool is_modified() const { return _modified; }
	void set_location(const Vector2i &p_location);
	Vector2i get_location() const { return _location; }

	// File I/O
	Error save(const String &p_path = "", const bool p_16_bit = false);

	// Utility
	void set_data(const Dictionary &p_data);
	Dictionary get_data() const;
	Ref<Terrain3DRegion> duplicate(const bool p_deep = false);
	void dump(const bool verbose = false) const;

protected:
	static void _bind_methods();
};

VARIANT_ENUM_CAST(MapType);

// Inline functions

inline void Terrain3DRegion::update_height(const real_t p_height) {
	if (p_height < _height_range.x) {
		_height_range.x = p_height;
		_modified = true;
	} else if (p_height > _height_range.y) {
		_height_range.y = p_height;
		_modified = true;
	}
}

inline void Terrain3DRegion::update_heights(const Vector2 &p_low_high) {
	if (p_low_high.x < _height_range.x) {
		_height_range.x = p_low_high.x;
		_modified = true;
	}
	if (p_low_high.y > _height_range.y) {
		_height_range.y = p_low_high.y;
		_modified = true;
	}
}

#endif // TERRAIN3D_REGION_CLASS_H
