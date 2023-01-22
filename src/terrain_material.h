//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#ifndef TERRAINMATERIAL3D_CLASS_H
#define TERRAINMATERIAL3D_CLASS_H

#ifdef WIN32
#include <windows.h>
#endif

#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/classes/texture2d_array.hpp>
#include <godot_cpp/classes/image_texture.hpp>


using namespace godot;

class TerrainLayerMaterial3D : public Material {
    GDCLASS(TerrainLayerMaterial3D, Material);

    Color albedo = Color(1.0, 1.0, 1.0, 1.0);
    Ref<Texture2D> albedo_texture;
    Ref<Texture2D> normal_texture;
    Vector3 uv_scale = Vector3(1.0, 1.0, 1.0);

    RID shader;

protected:
    static void _bind_methods();

public:
    TerrainLayerMaterial3D();
    ~TerrainLayerMaterial3D();

    Shader::Mode _get_shader_mode() const;
    RID _get_shader_rid();

    void set_albedo(Color p_color);
    Color get_albedo() const;
    
    void set_albedo_texture(Ref<Texture2D> &p_texture);
    Ref<Texture2D> get_albedo_texture() const;
    void set_normal_texture(Ref<Texture2D> &p_texture);
    Ref<Texture2D> get_normal_texture() const;

    void set_uv_scale(Vector3 p_scale);
    Vector3 get_uv_scale() const;


private:
    bool _texture_is_valid(Ref<Texture2D> &p_texture) const;
    void _update_shader();
};

class TerrainMaterial3D : public Material {

    GDCLASS(TerrainMaterial3D, Material);

    const int LAYERS_MAX = 256;

    int size = 1024;
    int height = 64;

    bool grid_enabled = true;
    real_t grid_scale = 1.0;

    Ref<ImageTexture> height_map;
    Ref<ImageTexture> control_map;
    Ref<ImageTexture> normal_map;

    Array layers;

    Ref<Texture2DArray> albedo_textures;
    Ref<Texture2DArray> normal_textures;

    RID shader;

protected:
    static void _bind_methods();

public:
    TerrainMaterial3D();
    ~TerrainMaterial3D();

    Shader::Mode _get_shader_mode() const;
    RID _get_shader_rid();

    void reset();

    void set_size(int p_size);
    int get_size() const;
    void set_height(int p_height);
    int get_height() const;

    void enable_grid(bool p_enable);
    bool is_grid_enabled() const;
    void set_grid_scale(real_t p_scale);

    void set_layer(const Ref<TerrainLayerMaterial3D> &p_material, int p_index);

    Ref<ImageTexture> get_height_map() const;
    Ref<ImageTexture> get_normal_map() const;
    Ref<ImageTexture> get_control_map() const;

private:
    void _update_shader();
    void _update_maps();
    void _update_layers();
    void _update_arrays();
    void _update_textures();

    Ref<Texture2DArray> _convert_array(const Array &p_array) const;
    
};

#endif // TERRAINMATERIAL3D_CLASS_H