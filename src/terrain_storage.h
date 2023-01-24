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

    int map_size = 1024;
    int map_height = 512;

    Ref<TerrainMaterial3D> material;
    Ref<Shader> shader_override;
    Array layers;

    Ref<Texture2DArray> height_maps;
    Ref<Texture2DArray> control_maps;
    Array map_offsets;

    Ref<Texture2DArray> albedo_textures;
    Ref<Texture2DArray> normal_textures;

    bool _initialized = false;

private:
    void _update_layers();
    void _update_arrays();
    void _update_textures();
    void _update_material();

    Ref<Texture2DArray> _convert_array(const Array& p_array) const;

protected:
    static void _bind_methods();

public:
    Terrain3DStorage();
    ~Terrain3DStorage();

    void set_size(int p_size);
    int get_size() const;
    void set_height(int p_height);
    int get_height() const;

    void set_layer(const Ref<TerrainLayerMaterial3D>& p_material, int p_index);
    Ref<TerrainLayerMaterial3D> get_layer(int p_index) const;
    void set_layers(const Array& p_layers);
    Array get_layers() const;
    int get_layer_count() const;

    void add_map(Vector2 p_global_position);
    void remove_map(Vector2 p_global_position);
    void set_height_maps(const Ref<Texture2DArray>& p_maps);
    Ref<Texture2DArray> get_height_maps() const;
    void set_control_maps(const Ref<Texture2DArray>& p_maps);
    Ref<Texture2DArray> get_control_maps() const;
    void set_map_offsets(const Array& p_offsets);
    Array get_map_offsets() const;
    int get_map_count() const;

    void set_material(const Ref<TerrainMaterial3D>& p_material);
    Ref<TerrainMaterial3D> get_material() const;
    void set_shader_override(const Ref<Shader>& p_shader);
    Ref<Shader> get_shader_override() const;
    
};

#endif // TERRAINSTORAGE_CLASS_H