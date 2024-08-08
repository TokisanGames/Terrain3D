// Copyright © 2024 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_STORAGE_CLASS_H
#define TERRAIN3D_STORAGE_CLASS_H

#include "constants.h"
#include "generated_texture.h"
#include "terrain_3d_region.h"

class Terrain3D;

using namespace godot;

class Terrain3DStorage : public Object {
	GDCLASS(Terrain3DStorage, Object);
	CLASS_NAME();
	friend Terrain3D;

public: // Constants
	static inline const real_t CURRENT_VERSION = 0.92f;
	static inline const int REGION_MAP_SIZE = 16;
	static inline const Vector2i REGION_MAP_VSIZE = Vector2i(REGION_MAP_SIZE, REGION_MAP_SIZE);

	enum RegionSize {
		//SIZE_64 = 64,
		//SIZE_128 = 128,
		//SIZE_256 = 256,
		//SIZE_512 = 512,
		SIZE_1024 = 1024,
		//SIZE_2048 = 2048,
	};

	enum HeightFilter {
		HEIGHT_FILTER_NEAREST,
		HEIGHT_FILTER_MINIMUM
	};

private:
	Terrain3D *_terrain = nullptr;

	// Storage Settings & flags
	RegionSize _region_size = SIZE_1024;
	Vector2i _region_sizev = Vector2i(_region_size, _region_size);
	real_t _mesh_vertex_spacing = 1.f; // Set by Terrain3D::set_mesh_vertex_spacing
	bool _loading = false; // tracking when we're loading so we don't add_region w/ update

	// TODO: Should be in Terrain3D or per region so its saved
	Vector2 _height_range = Vector2(0.f, 0.f);

	// Work data
	bool _region_map_dirty = true;
	PackedInt32Array _region_map; // 16x16 Region grid with index into region_locations (1 based array)
	// Generated Texture RIDs
	// These contain the TextureLayered RID from the RenderingServer, no Image
	GeneratedTexture _generated_height_maps;
	GeneratedTexture _generated_control_maps;
	GeneratedTexture _generated_color_maps;

	AABB _edited_area;
	uint64_t _last_region_bounds_error = 0;

	/**
	 * These arrays house all of the map data.
	 * The Image arrays are region_sized slices of all heightmap data. Their world
	 * location is tracked by region_locations. The region data are combined into one large
	 * texture in generated_*_maps.
	 */
	TypedArray<Vector2i> _region_locations;
	TypedArray<Image> _height_maps;
	TypedArray<Image> _control_maps;
	TypedArray<Image> _color_maps;

	// Dictionary[region_location:Vector2i] -> Terrain3DRegion
	Dictionary _regions;

	// Foliage Instancer contains MultiMeshes saved to disk
	// Dictionary[region_location:Vector2i] -> Dictionary[mesh_id:int] -> MultiMesh
	Dictionary _multimeshes;

	// Functions
	void _clear();
	int _get_region_map_index(const Vector2i &p_region_loc) const;

public:
	Terrain3DStorage() {}
	void initialize(Terrain3D *p_terrain);
	~Terrain3DStorage() { _clear(); }

	Vector2i get_region_location(const Vector3 &p_global_position) const;
	Vector2i get_region_locationi(const int p_region_id) const;
	int get_region_id(const Vector2i &p_region_loc) const;
	int get_region_idp(const Vector3 &p_global_position) const;
	bool has_region(const Vector2i &p_region_loc) const { return get_region_id(p_region_loc) != -1; }
	bool has_regionp(const Vector3 &p_global_position) const { return get_region_idp(p_global_position) != -1; }
	void set_height_range(const Vector2 &p_range);
	Vector2 get_height_range() const { return _height_range; }
	void update_heights(const real_t p_height);
	void update_heights(const Vector2 &p_heights);
	void update_height_range();

	void clear_edited_area();
	void add_edited_area(const AABB &p_area);
	AABB get_edited_area() const { return _edited_area; }

	// Regions
	Dictionary get_regions() { return _regions; }
	Ref<Terrain3DRegion> get_region(const Vector2i &p_region_loc);
	void set_region_modified(const Vector2i &p_region_loc, const bool p_modified = true);
	bool get_region_modified(const Vector2i &p_region_loc) const;

	void set_region_size(const RegionSize p_size);
	RegionSize get_region_size() const { return _region_size; }
	Vector2i get_region_sizev() const { return _region_sizev; }
	void set_region_locations(const TypedArray<Vector2i> &p_locations);
	TypedArray<Vector2i> get_region_locations() const { return _region_locations; }
	PackedInt32Array get_region_map() const { return _region_map; }
	int get_region_count() const { return _region_locations.size(); }
	Error add_region(const Vector3 &p_global_position,
			const TypedArray<Image> &p_images = TypedArray<Image>(),
			const bool p_update = true,
			const String &p_path = "");
	void remove_region(const Vector3 &p_global_position, const bool p_update = true, const String &p_path = "");
	void remove_region_by_id(const int p_region_id, const bool p_update = true, const String &p_path = "");
	void update_maps();

	// Maps
	void set_map_region(const MapType p_map_type, const int p_region_id, const Ref<Image> &p_image);
	Ref<Image> get_map_region(const MapType p_map_type, const int p_region_id) const;
	void set_maps(const MapType p_map_type, const TypedArray<Image> &p_maps, const TypedArray<int> &p_region_ids = TypedArray<int>());
	TypedArray<Image> get_maps(const MapType p_map_type) const;
	TypedArray<Image> get_maps_copy(const MapType p_map_type, const TypedArray<int> &p_region_ids = TypedArray<int>()) const;
	void set_height_maps(const TypedArray<Image> &p_maps) { set_maps(TYPE_HEIGHT, p_maps); }
	TypedArray<Image> get_height_maps() const { return _height_maps; }
	RID get_height_maps_rid() const { return _generated_height_maps.get_rid(); }
	void set_control_maps(const TypedArray<Image> &p_maps) { set_maps(TYPE_CONTROL, p_maps); }
	TypedArray<Image> get_control_maps() const { return _control_maps; }
	RID get_control_maps_rid() const { return _generated_control_maps.get_rid(); }
	void set_color_maps(const TypedArray<Image> &p_maps) { set_maps(TYPE_COLOR, p_maps); }
	TypedArray<Image> get_color_maps() const { return _color_maps; }
	RID get_color_maps_rid() const { return _generated_color_maps.get_rid(); }
	void set_pixel(const MapType p_map_type, const Vector3 &p_global_position, const Color &p_pixel);
	Color get_pixel(const MapType p_map_type, const Vector3 &p_global_position) const;
	void set_height(const Vector3 &p_global_position, const real_t p_height);
	real_t get_height(const Vector3 &p_global_position) const;
	void set_color(const Vector3 &p_global_position, const Color &p_color);
	Color get_color(const Vector3 &p_global_position) const;
	void set_control(const Vector3 &p_global_position, const uint32_t p_control);
	uint32_t get_control(const Vector3 &p_global_position) const;
	void set_roughness(const Vector3 &p_global_position, const real_t p_roughness);
	real_t get_roughness(const Vector3 &p_global_position) const;
	Vector3 get_texture_id(const Vector3 &p_global_position) const;
	real_t get_angle(const Vector3 &p_global_position) const;
	real_t get_scale(const Vector3 &p_global_position) const;
	void force_update_maps(const MapType p_map = TYPE_MAX);

	// Instancer
	void set_multimeshes(const Dictionary &p_multimeshes);
	void set_multimeshes(const Dictionary &p_multimeshes, const TypedArray<int> &p_region_ids);
	Dictionary get_multimeshes() const { return _multimeshes; }
	Dictionary get_multimeshes(const TypedArray<int> &p_region_ids) const;

	// File I/O
	void save_directory(const String &p_dir);
	void load_directory(const String &p_dir);
	void save_region(const String &p_dir, const Vector2i &p_region_loc, const bool p_16_bit = false);
	void load_region(const String &p_dir, const Vector2i &p_region_loc);

	void register_region(const Ref<Terrain3DRegion> &p_region);
	TypedArray<int> get_regions_under_aabb(const AABB &p_aabb);

	void import_images(const TypedArray<Image> &p_images, const Vector3 &p_global_position = V3_ZERO,
			const real_t p_offset = 0.f, const real_t p_scale = 1.f);
	Error export_image(const String &p_file_name, const MapType p_map_type = TYPE_HEIGHT) const;
	Ref<Image> layered_to_image(const MapType p_map_type) const;

	// Utility
	Vector3 get_mesh_vertex(const int32_t p_lod, const HeightFilter p_filter, const Vector3 &p_global_position) const;
	Vector3 get_normal(const Vector3 &global_position) const;
	void print_audit_data() const;

protected:
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Terrain3DStorage::RegionSize);
VARIANT_ENUM_CAST(Terrain3DStorage::HeightFilter);

/// Inline Region Functions

// This function verifies the location is within the bounds of the _region_map array and
// thus the world. It returns the _region_map index if valid, -1 if not
inline int Terrain3DStorage::_get_region_map_index(const Vector2i &p_region_loc) const {
	// Offset locations centered on (0,0) to positive only
	Vector2i loc = Vector2i(p_region_loc + (REGION_MAP_VSIZE / 2));
	int map_index = loc.y * REGION_MAP_SIZE + loc.x;
	if (map_index < 0 || map_index >= REGION_MAP_SIZE * REGION_MAP_SIZE) {
		return -1;
	}
	return map_index;
}

// Returns a region location given a global position. No bounds checking nor data access.
inline Vector2i Terrain3DStorage::get_region_location(const Vector3 &p_global_position) const {
	Vector2 descaled_position = Vector2(p_global_position.x, p_global_position.z);
	return Vector2i((descaled_position / (_mesh_vertex_spacing * real_t(_region_size))).floor());
}

// Returns Vector2i(2147483647) if out of range
inline Vector2i Terrain3DStorage::get_region_locationi(const int p_region_id) const {
	if (p_region_id < 0 || p_region_id >= _region_locations.size()) {
		return V2I_MAX;
	}
	return _region_locations[p_region_id];
}

// Returns id of any active region. -1 if out of bounds, 0 if no region, or region id
inline int Terrain3DStorage::get_region_id(const Vector2i &p_region_loc) const {
	int map_index = _get_region_map_index(p_region_loc);
	if (map_index >= 0) {
		int region_id = _region_map[map_index] - 1; // 0 = no region
		if (region_id >= 0 && region_id < _region_locations.size()) {
			return region_id;
		}
	}
	return -1;
}

inline int Terrain3DStorage::get_region_idp(const Vector3 &p_global_position) const {
	return get_region_id(get_region_location(p_global_position));
}

/// Inline Map Functions

inline void Terrain3DStorage::set_height(const Vector3 &p_global_position, const real_t p_height) {
	set_pixel(TYPE_HEIGHT, p_global_position, Color(p_height, 0.f, 0.f, 1.f));
}

inline void Terrain3DStorage::set_color(const Vector3 &p_global_position, const Color &p_color) {
	Color clr = p_color;
	clr.a = get_roughness(p_global_position);
	set_pixel(TYPE_COLOR, p_global_position, clr);
}

inline Color Terrain3DStorage::get_color(const Vector3 &p_global_position) const {
	Color clr = get_pixel(TYPE_COLOR, p_global_position);
	clr.a = 1.0f;
	return clr;
}

inline void Terrain3DStorage::set_control(const Vector3 &p_global_position, const uint32_t p_control) {
	set_pixel(TYPE_CONTROL, p_global_position, Color(as_float(p_control), 0.f, 0.f, 1.f));
}

inline uint32_t Terrain3DStorage::get_control(const Vector3 &p_global_position) const {
	real_t val = get_pixel(TYPE_CONTROL, p_global_position).r;
	return (std::isnan(val)) ? UINT32_MAX : as_uint(val);
}

inline void Terrain3DStorage::set_roughness(const Vector3 &p_global_position, const real_t p_roughness) {
	Color clr = get_pixel(TYPE_COLOR, p_global_position);
	clr.a = p_roughness;
	set_pixel(TYPE_COLOR, p_global_position, clr);
}

inline real_t Terrain3DStorage::get_roughness(const Vector3 &p_global_position) const {
	return get_pixel(TYPE_COLOR, p_global_position).a;
}

#endif // TERRAIN3D_STORAGE_CLASS_H
