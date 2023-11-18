// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_STORAGE_CLASS_H
#define TERRAIN3D_STORAGE_CLASS_H

#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/shader.hpp>

#include "constants.h"
#include "generated_tex.h"
#include "terrain_3d_surface.h" // DEPRECATED 0.8.3, remove 0.9
#include "terrain_3d_texture_list.h"

using namespace godot;

class Terrain3DStorage : public Resource {
	GDCLASS(Terrain3DStorage, Resource);

public:
	// Constants
	static inline const char *__class__ = "Terrain3DStorage";

	static inline const real_t CURRENT_VERSION = 0.842;
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
		COLOR_BLACK, // TYPE_CONTROL
		COLOR_ROUGHNESS, // TYPE_COLOR
		COLOR_ZERO, // TYPE_MAX, unused just in case someone indexes the array
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

private:
	// Storage Settings & flags
	real_t _version = 0.8; // Set to ensure Godot always saves this
	bool _modified = false;
	bool _save_16_bit = false;
	RegionSize _region_size = SIZE_1024;
	Vector2i _region_sizev = Vector2i(_region_size, _region_size);

	// Stored Data
	Vector2 _height_range = Vector2(0, 0);

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

	// Generated Texture RIDs
	// These contain the TextureLayered RID from the RenderingServer, no Image
	GeneratedTex _generated_height_maps;
	GeneratedTex _generated_control_maps;
	GeneratedTex _generated_color_maps;

	// Functions
	void _clear();

	// DEPRECATED 0.8.3, remove 0.9
	Ref<Terrain3DTextureList> _texture_list;
	// DEPRECATED 0.8.4, remove 0.9
	bool _841_colormap_upgraded = false;
	bool _842_controlmap_upgraded = false;

public:
	Terrain3DStorage();
	~Terrain3DStorage();

	inline void set_version(real_t p_version);
	inline real_t get_version() const { return _version; }
	inline void set_save_16_bit(bool p_enabled);
	inline bool get_save_16_bit() const { return _save_16_bit; }

	inline void set_height_range(Vector2 p_range);
	inline Vector2 get_height_range() const { return _height_range; }
	void update_heights(real_t p_height);
	void update_heights(Vector2 p_heights);
	void update_height_range();

	// Regions
	void set_region_size(RegionSize p_size);
	RegionSize get_region_size() const { return _region_size; }
	void set_region_offsets(const TypedArray<Vector2i> &p_offsets);
	TypedArray<Vector2i> get_region_offsets() const { return _region_offsets; }
	int get_region_count() const { return _region_offsets.size(); }
	Vector2i get_region_offset(Vector3 p_global_position);
	int get_region_index(Vector3 p_global_position);
	bool has_region(Vector3 p_global_position) { return get_region_index(p_global_position) != -1; }
	Error add_region(Vector3 p_global_position, const TypedArray<Image> &p_images = TypedArray<Image>(), bool p_update = true);
	void remove_region(Vector3 p_global_position, bool p_update = true);
	void update_regions(bool force_emit = false);

	// Maps
	void set_map_region(MapType p_map_type, int p_region_index, const Ref<Image> p_image);
	Ref<Image> get_map_region(MapType p_map_type, int p_region_index) const;
	void set_maps(MapType p_map_type, const TypedArray<Image> &p_maps);
	TypedArray<Image> get_maps(MapType p_map_type) const;
	TypedArray<Image> get_maps_copy(MapType p_map_type) const;
	void set_height_maps(const TypedArray<Image> &p_maps);
	TypedArray<Image> get_height_maps() const { return _height_maps; }
	void set_control_maps(const TypedArray<Image> &p_maps);
	TypedArray<Image> get_control_maps() const { return _control_maps; }
	void set_color_maps(const TypedArray<Image> &p_maps);
	TypedArray<Image> get_color_maps() const { return _color_maps; }
	Color get_pixel(MapType p_map_type, Vector3 p_global_position);
	inline real_t get_height(Vector3 p_global_position) { return get_pixel(TYPE_HEIGHT, p_global_position).r; }
	inline Color get_color(Vector3 p_global_position);
	inline Color get_control(Vector3 p_global_position) { return get_pixel(TYPE_CONTROL, p_global_position); }
	inline real_t get_roughness(Vector3 p_global_position) { return get_pixel(TYPE_COLOR, p_global_position).a; }
	Vector3 get_mesh_vertex(int32_t p_lod, HeightFilter p_filter, Vector3 p_global_position);
	Vector3 get_texture_id(Vector3 p_global_position);
	TypedArray<Image> sanitize_maps(MapType p_map_type, const TypedArray<Image> &p_maps);
	void force_update_maps(MapType p_map = TYPE_MAX);

	// File I/O
	void save();
	void clear_modified() { _modified = false; }
	void set_modified() { _modified = true; }
	static Ref<Image> load_image(String p_file_name, int p_cache_mode = ResourceLoader::CACHE_MODE_IGNORE,
			Vector2 p_r16_height_range = Vector2(0, 255), Vector2i p_r16_size = Vector2i(0, 0));
	void import_images(const TypedArray<Image> &p_images, Vector3 p_global_position = Vector3(0, 0, 0),
			real_t p_offset = 0.0, real_t p_scale = 1.0);
	Error export_image(String p_file_name, MapType p_map_type = TYPE_HEIGHT);
	Ref<Image> layered_to_image(MapType p_map_type);

	// Testing
	void print_audit_data();

	// DEPRECATED 0.8.3, remove 0.9
	void set_surfaces(const TypedArray<Terrain3DSurface> &p_surfaces);
	TypedArray<Terrain3DSurface> get_surfaces() const { return TypedArray<Terrain3DSurface>(); }
	Ref<Terrain3DTextureList> get_texture_list() const { return _texture_list; }

protected:
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Terrain3DStorage::MapType);
VARIANT_ENUM_CAST(Terrain3DStorage::RegionSize);
VARIANT_ENUM_CAST(Terrain3DStorage::HeightFilter);

#endif // TERRAIN3D_STORAGE_CLASS_H
