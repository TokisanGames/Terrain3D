//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#ifndef TERRAINSTORAGE_CLASS_H
#define TERRAINSTORAGE_CLASS_H

#ifdef WIN32
#include <windows.h>
#endif

#include "terrain_material.h"

using namespace godot;

// TERRAIN STORAGE

class Terrain3DStorage : public Resource {
	GDCLASS(Terrain3DStorage, Resource);

	enum Map {
		HEIGHT,
		CONTROL
	};

	int map_size = 1024;
	int map_height = 512;

	Ref<TerrainMaterial3D> material;
	Ref<Shader> shader_override;

	TypedArray<TerrainLayerMaterial3D> layers;
	TypedArray<Image> height_maps;
	TypedArray<Image> control_maps;
	TypedArray<Vector2> region_offsets;

	struct GeneratedTextureArray {
	private:
		RID rid = RID();
		bool dirty = false;

	public:
		void clear();
		bool is_dirty() { return dirty; }
		void create(const TypedArray<Image> &p_layers);
		RID get_rid() { return rid; }
	};

	GeneratedTextureArray generated_height_maps;
	GeneratedTextureArray generated_control_maps;
	GeneratedTextureArray generated_albedo_textures;
	GeneratedTextureArray generated_normal_textures;

	bool _initialized = false;

private:
	void _update_layers();
	void _update_arrays();
	void _update_textures();
	void _update_regions();
	void _update_material();

	void _clear_generated_data();
	Vector2 _global_position_to_uv_offset(Vector3 p_global_position);

protected:
	static void _bind_methods();

public:
	Terrain3DStorage();
	~Terrain3DStorage();

	void set_size(int p_size);
	int get_size() const;
	void set_height(int p_height);
	int get_height() const;

	void set_layer(const Ref<TerrainLayerMaterial3D> &p_material, int p_index);
	Ref<TerrainLayerMaterial3D> get_layer(int p_index) const;
	void set_layers(const TypedArray<TerrainLayerMaterial3D> &p_layers);
	TypedArray<TerrainLayerMaterial3D> get_layers() const;
	int get_layer_count() const;

	void add_region(Vector3 p_global_position);
	void remove_region(Vector3 p_global_position);
	bool has_region(Vector3 p_global_position);
	int get_region_index(Vector3 p_global_position);
	Ref<Image> get_map(int p_region_index, Map p_map) const;
	void force_update_maps(Map p_map);

	void set_height_maps(const TypedArray<Image> &p_maps);
	TypedArray<Image> get_height_maps() const;
	void set_control_maps(const TypedArray<Image> &p_maps);
	TypedArray<Image> get_control_maps() const;

	void set_region_offsets(const Array &p_offsets);
	Array get_region_offsets() const;
	int get_region_count() const;

	void set_material(const Ref<TerrainMaterial3D> &p_material);
	Ref<TerrainMaterial3D> get_material() const;
	void set_shader_override(const Ref<Shader> &p_shader);
	Ref<Shader> get_shader_override() const;
};

VARIANT_ENUM_CAST(Terrain3DStorage, Map);

#endif // TERRAINSTORAGE_CLASS_H