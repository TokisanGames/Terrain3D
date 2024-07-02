// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_STORAGE_CLASS_H
#define TERRAIN3D_STORAGE_CLASS_H

#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/shader.hpp>

#include "constants.h"
#include "generated_texture.h"
#include "terrain_3d_texture_asset.h"
#include "terrain_3d_util.h"

class Terrain3D;

using namespace godot;

class Terrain3DRegionManager : public Object {
	GDCLASS(Terrain3DRegionManager, Object);
	CLASS_NAME();

public: // Constants
	static inline const real_t CURRENT_VERSION = 0.842f;
	static inline const int REGION_MAP_SIZE = 16;
	static inline const Vector2i REGION_MAP_VSIZE = Vector2i(REGION_MAP_SIZE, REGION_MAP_SIZE);

	enum MapType {
		TYPE_HEIGHT,
		TYPE_CONTROL,
		TYPE_COLOR,
		TYPE_MAX,
	};

	static inline const Image::Format FORMAT[] = {
		Image::FORMAT_RF, // TYPE_HEIGHT
		Image::FORMAT_RF, // TYPE_CONTROL
		Image::FORMAT_RGBA8, // TYPE_COLOR
		Image::Format(TYPE_MAX), // Proper size of array instead of FORMAT_MAX
	};

	static inline const char *TYPESTR[] = {
		"TYPE_HEIGHT",
		"TYPE_CONTROL",
		"TYPE_COLOR",
		"TYPE_MAX",
	};

	static inline const Color COLOR[] = {
		COLOR_BLACK, // TYPE_HEIGHT
		COLOR_CONTROL, // TYPE_CONTROL
		COLOR_ROUGHNESS, // TYPE_COLOR
		COLOR_NAN, // TYPE_MAX, unused just in case someone indexes the array
	};

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

	class Terrain3DRegion : public Resource {
		GDCLASS(Terrain3DRegion, Resource);
		CLASS_NAME();

	private:
		// Map info
		Ref<Image> _height_map;
		Ref<Image> _control_map;
		Ref<Image> _color_map;

		// Foliage Instancer contains MultiMeshes saved to disk
		// Dictionary[mesh_id:int] -> MultiMesh
		Dictionary _multimeshes;

		real_t _version = 0.8f;

	public:
		// Map Info
		void set_height_map(Ref<Image> p_map) { _height_map = p_map; }
		Ref<Image> get_height_map() const { return _height_map; }
		void set_control_map(Ref<Image> p_map) { _control_map = p_map; }
		Ref<Image> get_control_map() const { return _control_map; }
		void set_color_map(Ref<Image> p_map) { _color_map = p_map; }
		Ref<Image> get_color_map() const { return _color_map; }

		// Foliage Instancer
		void set_multimeshes(Dictionary p_instances) { _multimeshes = p_instances; }
		Dictionary get_multimeshes() const { return _multimeshes; }

		void set_version(real_t p_version) { _version = p_version; }
		real_t get_version() { return _version; }

	protected:
		static void _bind_methods();
	};

private:
	Terrain3D *_terrain = nullptr;

	// Storage Settings & flags
	real_t _version = 0.8f; // Set to ensure Godot always saves this
	TypedArray<bool> _modified = TypedArray<bool>(); // TODO: Make sure this is the right size
	bool _save_16_bit = false;
	RegionSize _region_size = SIZE_1024;
	Vector2i _region_sizev = Vector2i(_region_size, _region_size);
	bool _loading = false; // I am a little hesitant to include state like this.

	// Stored Data
	Vector2 _height_range = Vector2(0.f, 0.f);
	AABB _edited_area;

	/**
	 * These arrays house all of the map data.
	 * The Image arrays are region_sized slices of all heightmap data. Their world
	 * location is tracked by region_offsets. The region data are combined into one large
	 * texture in generated_*_maps.
	 */
	bool _region_map_dirty = true;
	PackedInt32Array _region_map; // 16x16 Region grid with index into region_offsets (1 based array)
	TypedArray<Vector2i> _region_offsets; // Array of active region coordinates

	TypedArray<Image> _height_maps;
	TypedArray<Image> _control_maps;
	TypedArray<Image> _color_maps;
	Dictionary _multimeshes; // region offset -> Dictionary

	// Generated Texture RIDs
	// These contain the TextureLayered RID from the RenderingServer, no Image
	GeneratedTexture _generated_height_maps;
	GeneratedTexture _generated_control_maps;
	GeneratedTexture _generated_color_maps;

	uint64_t _last_region_bounds_error = 0;

	// Functions
	void _clear();

public:
	Terrain3DRegionManager() {}
	void initialize(Terrain3D *p_terrain);
	~Terrain3DRegionManager();

	void set_version(real_t p_version);
	real_t get_version() const { return _version; }
	void set_save_16_bit(bool p_enabled);
	bool get_save_16_bit() const { return _save_16_bit; }

	void set_height_range(Vector2 p_range);
	Vector2 get_height_range() const { return _height_range; }
	void update_heights(real_t p_height);
	void update_heights(Vector2 p_heights);
	void update_height_range();

	void clear_edited_area();
	void add_edited_area(AABB p_area);
	AABB get_edited_area() const { return _edited_area; }

	// Regions
	void set_region_size(RegionSize p_size);
	RegionSize get_region_size() const { return _region_size; }
	Vector2i get_region_sizev() const { return _region_sizev; }
	void set_region_offsets(const TypedArray<Vector2i> &p_offsets);
	TypedArray<Vector2i> get_region_offsets() const { return _region_offsets; }
	PackedInt32Array get_region_map() const { return _region_map; }
	int get_region_count() const { return _region_offsets.size(); }
	Vector2i get_region_offset(Vector3 p_global_position);
	Vector2i get_region_file_offset(String p_filename);
	int get_region_index(Vector3 p_global_position);
	String get_region_filename(int p_region_id);
	Vector2i get_region_offset_from_index(int p_index) const;
	static String get_region_filename_from_offset(Vector2i p_offset);
	bool has_region(Vector3 p_global_position) { return get_region_index(p_global_position) != -1; }
	Error add_region(Vector3 p_global_position, const TypedArray<Image> &p_images = TypedArray<Image>(), bool p_update = true, String p_path = "");
	void remove_region(Vector3 p_global_position, bool p_update = true, String p_path = "");
	void update_regions(bool force_emit = false);
	void save_region(String p_path, int p_region_id);
	void load_region(String p_path, int p_region_id);
	void load_region_from_offset(String p_path, Vector2i p_region_offset);
	void register_region(Ref<Terrain3DRegion> p_region, Vector2i p_offset);
	TypedArray<int> get_regions_under_aabb(AABB p_aabb);

	// Maps
	void set_map_region(MapType p_map_type, int p_region_index, const Ref<Image> p_image);
	Ref<Image> get_map_region(MapType p_map_type, int p_region_index) const;
	void set_maps(MapType p_map_type, const TypedArray<Image> &p_maps, const TypedArray<int> p_regions = TypedArray<int>());
	TypedArray<Image> get_maps(MapType p_map_type) const;
	TypedArray<Image> get_maps_copy(MapType p_map_type, const TypedArray<int> p_regions = TypedArray<int>()) const;
	void set_height_maps(const TypedArray<Image> &p_maps) { set_maps(TYPE_HEIGHT, p_maps); }
	TypedArray<Image> get_height_maps() const { return _height_maps; }
	RID get_height_rid() { return _generated_height_maps.get_rid(); }
	void set_control_maps(const TypedArray<Image> &p_maps) { set_maps(TYPE_CONTROL, p_maps); }
	TypedArray<Image> get_control_maps() const { return _control_maps; }
	RID get_control_rid() { return _generated_control_maps.get_rid(); }
	void set_color_maps(const TypedArray<Image> &p_maps) { set_maps(TYPE_COLOR, p_maps); }
	TypedArray<Image> get_color_maps() const { return _color_maps; }
	RID get_color_rid() { return _generated_color_maps.get_rid(); }
	void set_pixel(MapType p_map_type, Vector3 p_global_position, Color p_pixel);
	Color get_pixel(MapType p_map_type, Vector3 p_global_position);
	void set_height(Vector3 p_global_position, real_t p_height);
	real_t get_height(Vector3 p_global_position);
	void set_color(Vector3 p_global_position, Color p_color);
	Color get_color(Vector3 p_global_position);
	void set_control(Vector3 p_global_position, uint32_t p_control);
	uint32_t get_control(Vector3 p_global_position);
	void set_roughness(Vector3 p_global_position, real_t p_roughness);
	real_t get_roughness(Vector3 p_global_position);
	Vector3 get_texture_id(Vector3 p_global_position);
	TypedArray<Image> sanitize_maps(MapType p_map_type, const TypedArray<Image> &p_maps);
	void force_update_maps(MapType p_map = TYPE_MAX);
	void set_multimeshes(const Dictionary p_multimeshes, const TypedArray<int> p_regions = TypedArray<int>());
	Dictionary get_multimeshes(const TypedArray<int> p_regions = TypedArray<int>()) const;

	// File I/O
	void save(String p_path);
	void clear_modified() { _modified.fill(false); }
	void set_all_regions_modified() { _modified.fill(true); }
	void set_modified(int p_index);
	void import_images(const TypedArray<Image> &p_images, Vector3 p_global_position = Vector3(0.f, 0.f, 0.f),
			real_t p_offset = 0.f, real_t p_scale = 1.f);
	Error export_image(String p_file_name, MapType p_map_type = TYPE_HEIGHT);
	Ref<Image> layered_to_image(MapType p_map_type);
	void load_directory(String p_dir);

	// Utility
	Vector3 get_mesh_vertex(int32_t p_lod, HeightFilter p_filter, Vector3 p_global_position);
	Vector3 get_normal(Vector3 global_position);
	void print_audit_data();

protected:
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Terrain3DRegionManager::MapType);
VARIANT_ENUM_CAST(Terrain3DRegionManager::RegionSize);
VARIANT_ENUM_CAST(Terrain3DRegionManager::HeightFilter);

// Inline Functions

inline void Terrain3DRegionManager::set_height(Vector3 p_global_position, real_t p_height) {
	set_pixel(TYPE_HEIGHT, p_global_position, Color(p_height, 0.f, 0.f, 1.f));
}

inline void Terrain3DRegionManager::set_color(Vector3 p_global_position, Color p_color) {
	p_color.a = get_roughness(p_global_position);
	set_pixel(TYPE_COLOR, p_global_position, p_color);
}

inline Color Terrain3DRegionManager::get_color(Vector3 p_global_position) {
	Color clr = get_pixel(TYPE_COLOR, p_global_position);
	clr.a = 1.0f;
	return clr;
}

inline void Terrain3DRegionManager::set_control(Vector3 p_global_position, uint32_t p_control) {
	set_pixel(TYPE_CONTROL, p_global_position, Color(as_float(p_control), 0.f, 0.f, 1.f));
}

inline uint32_t Terrain3DRegionManager::get_control(Vector3 p_global_position) {
	return as_uint(get_pixel(TYPE_CONTROL, p_global_position).r);
}

inline void Terrain3DRegionManager::set_roughness(Vector3 p_global_position, real_t p_roughness) {
	Color clr = get_pixel(TYPE_COLOR, p_global_position);
	clr.a = p_roughness;
	set_pixel(TYPE_COLOR, p_global_position, clr);
}

inline real_t Terrain3DRegionManager::get_roughness(Vector3 p_global_position) {
	return get_pixel(TYPE_COLOR, p_global_position).a;
}

#endif // TERRAIN3D_STORAGE_CLASS_H
