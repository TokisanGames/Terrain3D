// Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
#ifndef TERRAIN3D_STORAGE_CLASS_H
#define TERRAIN3D_STORAGE_CLASS_H

#ifdef WIN32
#include <windows.h>
#endif

#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/shader.hpp>

#include "terrain_3d_surface.h"

class Terrain3D;
using namespace godot;

#define COLOR_ZERO Color(0.0f, 0.0f, 0.0f, 0.0f)
#define COLOR_BLACK Color(0.0f, 0.0f, 0.0f, 1.0f)
#define COLOR_WHITE Color(1.0f, 1.0f, 1.0f, 1.0f)
#define COLOR_ROUGHNESS Color(1.0f, 1.0f, 1.0f, 0.5f)
#define COLOR_RB Color(1.0f, 0.0f, 1.0f, 1.0f)
#define COLOR_NORMAL Color(0.5f, 0.5f, 1.0f, 1.0f)

class Terrain3DStorage : public Resource {
private:
	GDCLASS(Terrain3DStorage, Resource);

	// Constants & Definitions

	enum MapType {
		TYPE_HEIGHT,
		TYPE_CONTROL,
		TYPE_COLOR,
		TYPE_MAX,
	};

	static inline const Image::Format FORMAT[] = {
		Image::FORMAT_RF, // TYPE_HEIGHT
		Image::FORMAT_RGB8, // TYPE_CONTROL
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

	static const int REGION_MAP_SIZE = 16;
	static inline const Vector2i REGION_MAP_VSIZE = Vector2i(REGION_MAP_SIZE, REGION_MAP_SIZE);

	class Generated {
	private:
		RID _rid = RID();
		Ref<Image> _image;
		bool _dirty = false;

	public:
		void clear();
		bool is_dirty() { return _dirty; }
		void create(const TypedArray<Image> &p_layers);
		void create(const Ref<Image> &p_image);
		Ref<Image> get_image() const { return _image; }
		RID get_rid() { return _rid; }
	};

	// Storage Settings & flags

	RegionSize _region_size = SIZE_1024;
	Vector2i _region_sizev = Vector2i(_region_size, _region_size);
	bool _initialized = false;
	bool _modified = false;
	bool _save_16_bit = false;
	float _version = 0.8;

	// Stored Data

	Vector2 _height_range = Vector2(0, 0);

	/**
	 * These arrays house all of the map data.
	 * The Image arrays are region_sized slices of all heightmap data. Their world
	 * location is tracked by region_offsets. The region data are combined into one large
	 * texture in generated_*_maps.
	 */
	TypedArray<Vector2i> _region_offsets;
	TypedArray<Image> _height_maps;
	TypedArray<Image> _control_maps;
	TypedArray<Image> _color_maps;
	TypedArray<Terrain3DSurface> _surfaces;

	// Material Settings

	bool _surfaces_enabled = false;
	RID _material;
	RID _shader;
	bool _shader_override_enabled = false;
	Ref<Shader> _shader_override;

	bool _noise_enabled = false;
	float _noise_scale = 2.0;
	float _noise_height = 300.0;
	float _noise_blend_near = 0.5;
	float _noise_blend_far = 1.0;

	// Generated Data

	// These contain an Image described below and a texture RID from the RenderingServer
	Generated _generated_region_map; // REGION_MAP_SIZE^2 sized texture w/ active regions
	Generated _generated_region_blend_map; // 512x512 blurred version of above for blending
	// These contain the TextureLayered RID from the RenderingServer, no Image
	Generated _generated_height_maps;
	Generated _generated_control_maps;
	Generated _generated_color_maps;
	Generated _generated_albedo_textures;
	Generated _generated_normal_textures;

	// Functions

	void _clear();

	void _update_surfaces();
	void _update_surface_data(bool p_update_textures, bool p_update_values);
	void _update_regions();
	void _update_material();
	String _generate_shader_code();

public:
	Terrain3DStorage();
	~Terrain3DStorage();

	void set_region_size(RegionSize p_size);
	RegionSize get_region_size() const { return _region_size; }
	inline void set_save_16_bit(bool p_enabled) { _save_16_bit = p_enabled; }
	inline bool get_save_16_bit() const { return _save_16_bit; }
	inline void set_version(float p_version) { _version = p_version; }
	inline float get_version() const { return _version; }

	inline void set_height_range(Vector2 p_range) { _height_range = p_range; }
	inline Vector2 get_height_range() const { return _height_range; }
	void update_heights(float p_height);
	void update_heights(Vector2 p_heights);
	void update_height_range();

	// Regions
	void set_region_offsets(const TypedArray<Vector2i> &p_array);
	TypedArray<Vector2i> get_region_offsets() const { return _region_offsets; }
	int get_region_count() const { return _region_offsets.size(); }
	Vector2i get_region_offset(Vector3 p_global_position);
	int get_region_index(Vector3 p_global_position);
	bool has_region(Vector3 p_global_position) { return get_region_index(p_global_position) != -1; }
	Error add_region(Vector3 p_global_position, const TypedArray<Image> &p_images = TypedArray<Image>(), bool p_update = true);
	void remove_region(Vector3 p_global_position, bool p_update = true);

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
	inline float get_height(Vector3 p_global_position) { return get_pixel(TYPE_HEIGHT, p_global_position).r; }
	inline Color get_color(Vector3 p_global_position);
	inline Color get_control(Vector3 p_global_position) { return get_pixel(TYPE_CONTROL, p_global_position); }
	inline float get_roughness(Vector3 p_global_position) { return get_pixel(TYPE_COLOR, p_global_position).a; }

	TypedArray<Image> sanitize_maps(MapType p_map_type, const TypedArray<Image> &p_maps);

	// File I/O

	void save();
	void _clear_modified() { _modified = false; }
	static Ref<Image> load_image(String p_file_name, int p_cache_mode = ResourceLoader::CACHE_MODE_IGNORE,
			Vector2 p_r16_height_range = Vector2(0, 255), Vector2i p_r16_size = Vector2i(0, 0));
	void import_images(const TypedArray<Image> &p_images, Vector3 p_global_position = Vector3(0, 0, 0),
			float p_offset = 0.0, float p_scale = 1.0);
	Error export_image(String p_file_name, MapType p_map_type = TYPE_HEIGHT);
	Ref<Image> layered_to_image(MapType p_map_type);
	static Vector2 get_min_max(const Ref<Image> p_image);
	static Ref<Image> get_thumbnail(const Ref<Image> p_image, Vector2i p_size = Vector2i(256, 256));
	static Ref<Image> get_filled_image(Vector2i p_size, Color p_color = COLOR_BLACK, bool create_mipmaps = true, Image::Format format = FORMAT[TYPE_HEIGHT]);

	// Materials

	void set_surface(const Ref<Terrain3DSurface> &p_material, int p_index);
	Ref<Terrain3DSurface> get_surface(int p_index) const { return _surfaces[p_index]; }
	void set_surfaces(const TypedArray<Terrain3DSurface> &p_surfaces);
	TypedArray<Terrain3DSurface> get_surfaces() const { return _surfaces; }
	int get_surface_count() const { return _surfaces.size(); }

	RID get_material() const { return _material; }
	void set_shader_override(const Ref<Shader> &p_shader);
	Ref<Shader> get_shader_override() const { return _shader_override; }
	void enable_shader_override(bool p_enabled);
	bool is_shader_override_enabled() const { return _shader_override_enabled; }

	void set_noise_enabled(bool p_enabled);
	bool get_noise_enabled() const { return _noise_enabled; }
	void set_noise_scale(float p_scale);
	float get_noise_scale() const { return _noise_scale; };
	void set_noise_height(float p_height);
	float get_noise_height() const { return _noise_height; };
	void set_noise_blend_near(float p_near);
	float get_noise_blend_near() const { return _noise_blend_near; };
	void set_noise_blend_far(float p_far);
	float get_noise_blend_far() const { return _noise_blend_far; };
	RID get_region_blend_map() { return _generated_region_blend_map.get_rid(); }

	// Regenerate data
	// Workaround until callable_mp is implemented
	void update_surface_textures();
	void update_surface_values();
	void force_update_maps(MapType p_map = TYPE_MAX);

	// Testing

	void print_audit_data();

protected:
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Terrain3DStorage::MapType);
VARIANT_ENUM_CAST(Terrain3DStorage::RegionSize);

#endif // TERRAIN3D_STORAGE_CLASS_H
