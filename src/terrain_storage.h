//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#ifndef TERRAINSTORAGE_CLASS_H
#define TERRAINSTORAGE_CLASS_H

#ifdef WIN32
#include <windows.h>
#endif

#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/texture2d_array.hpp>
#include <godot_cpp/templates/vector.hpp>

#include "terrain_material.h"


using namespace godot;

// TERRAIN STORAGE

class Terrain3DStorage : public Resource {

    GDCLASS(Terrain3DStorage, Resource);

    int size = 1024;
    int height = 512;

    Ref<TerrainMaterial3D> material;
    Ref<Shader> shader_override;

    Ref<Texture2DArray> height_map_array;
    Ref<Texture2DArray> control_map_array;
    Vector<Vector2> map_array_positions;

    TypedArray<TerrainLayerMaterial3D> layers;

    Ref<Texture2DArray> albedo_textures;
    Ref<Texture2DArray> normal_textures;

    bool _initialized = false;

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

    void add_map(Vector2 p_position);
    void remove_map(Vector2 p_position);

    void set_material(const Ref<TerrainMaterial3D>& p_material);
    Ref<TerrainMaterial3D> get_material() const;

    void set_shader_override(const Ref<Shader>& p_shader);
    Ref<Shader> get_shader_override() const;

private:
    void _update_layers();
    void _update_arrays();
    void _update_textures();

    Ref<Texture2DArray> _convert_array(const Array &p_array) const;
    
};

#endif // TERRAINSTORAGE_CLASS_H