//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#ifndef TERRAINSTORAGE_CLASS_H
#define TERRAINSTORAGE_CLASS_H

#ifdef WIN32
#include <windows.h>
#endif

#include <godot_cpp/classes/shader.hpp>

#include "terrain_surface.h"

using namespace godot;

// TERRAIN STORAGE

class Terrain3DStorage : public Resource {
	GDCLASS(Terrain3DStorage, Resource);

	enum MapType {
		TYPE_HEIGHT,
		TYPE_CONTROL,
		TYPE_COLOR,
		TYPE_ALL
	};

	enum RegionSize {
		SIZE_64 = 64,
		SIZE_128 = 128,
		SIZE_256 = 256,
		SIZE_512 = 512,
		SIZE_1024 = 1024,
		SIZE_2048 = 2048,
	};

	struct Generated {
		RID rid = RID();
		Ref<Image> image;
		bool dirty = false;

	public:
		void clear();
		bool is_dirty() { return dirty; }
		void create(const TypedArray<Image> &p_layers);
		void create(const Ref<Image> &p_image);
		Ref<Image> get_image() const { return image; }
		RID get_rid() { return rid; }
	};

	RegionSize region_size = SIZE_1024;
	const int region_map_size = 16;

	RID material;
	RID shader;
	Ref<Shader> shader_override;

	bool noise_enabled = false;
	float noise_scale = 2.0;
	float noise_height = 1.0;
	float noise_blend_near = 0.5;
	float noise_blend_far = 1.0;

	TypedArray<Terrain3DSurface> surfaces;
	bool surfaces_enabled = false;

	TypedArray<Vector2i> region_offsets;
	TypedArray<Image> height_maps;
	TypedArray<Image> control_maps;

	Generated generated_region_map;
	Generated generated_height_maps;
	Generated generated_control_maps;
	Generated generated_albedo_textures;
	Generated generated_normal_textures;

	bool _initialized = false;

private:
	// Copied from and set by Terrain
	int max_height = 512;

	void _update_surfaces();
	void _update_surface_data(bool p_update_textures, bool p_update_values);
	void _update_regions();
	void _update_material();

	void _clear();
	Vector2i _get_offset_from(Vector3 p_global_position);

protected:
	static void _bind_methods();

public:
	Terrain3DStorage();
	~Terrain3DStorage();

	void set_region_size(RegionSize p_size);
	RegionSize get_region_size() const { return region_size; }
	void set_max_height(int p_height);
	int get_max_height() const { return max_height; }

	void set_surface(const Ref<Terrain3DSurface> &p_material, int p_index);
	Ref<Terrain3DSurface> get_surface(int p_index) const { return surfaces[p_index]; }
	void set_surfaces(const TypedArray<Terrain3DSurface> &p_surfaces);
	TypedArray<Terrain3DSurface> get_surfaces() const { return surfaces; }
	int get_surface_count() const;

	// Workaround until callable_mp is implemented
	void update_surface_textures();
	void update_surface_values();

	Error add_region(Vector3 p_global_position);
	void remove_region(Vector3 p_global_position);
	bool has_region(Vector3 p_global_position);
	int get_region_index(Vector3 p_global_position);
	void set_region_offsets(const TypedArray<Vector2i> &p_array);
	TypedArray<Vector2i> get_region_offsets() const { return region_offsets; }
	int get_region_count() const;

	Ref<Image> get_map(int p_region_index, MapType p_map) const;
	void force_update_maps(MapType p_map);

	void set_height_maps(const TypedArray<Image> &p_maps);
	TypedArray<Image> get_height_maps() const;
	void set_control_maps(const TypedArray<Image> &p_maps);
	TypedArray<Image> get_control_maps() const { return control_maps; }

	RID get_material() const { return material; }
	void set_shader_override(const Ref<Shader> &p_shader);
	Ref<Shader> get_shader_override() const { return shader_override; }

	void set_noise_enabled(bool p_enabled);
	void set_noise_scale(float p_scale);
	void set_noise_height(float p_height);
	void set_noise_blend_near(float p_near);
	void set_noise_blend_far(float p_far);
	bool get_noise_enabled() const { return noise_enabled; }
	float get_noise_scale() const { return noise_scale; };
	float get_noise_height() const { return noise_height; };
	float get_noise_blend_near() const { return noise_blend_near; };
	float get_noise_blend_far() const { return noise_blend_far; };
};

VARIANT_ENUM_CAST(Terrain3DStorage, MapType);
VARIANT_ENUM_CAST(Terrain3DStorage, RegionSize);

#endif // TERRAINSTORAGE_CLASS_H