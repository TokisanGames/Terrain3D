//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#include "terrain_storage.h"
#include <godot_cpp/core/class_db.hpp>

using namespace godot;

Terrain3DStorage::Terrain3DStorage() 
{
    if (!_initialized) {
        material.instantiate();
        _initialized = true;
    }
}

Terrain3DStorage::~Terrain3DStorage() 
{
    if (_initialized) {
        
    }
}

void Terrain3DStorage::set_size(int p_size)
{
    size = p_size;
}

int Terrain3DStorage::get_size() const
{
    return size;
}

void Terrain3DStorage::set_height(int p_height)
{
    height = p_height;
}

int Terrain3DStorage::get_height() const
{
    return height;
}

void Terrain3DStorage::add_map(Vector2 p_position)
{
    Array h_maps;
    Array c_maps;

    for (int i = 0; i < height_map_array->get_layers(); i++) {
        h_maps.push_back(height_map_array->get_layer_data(i));
        c_maps.push_back(control_map_array->get_layer_data(i));
    }

    int hmap_size = size + 1;
    Ref<Image> hmap_img = Image::create(hmap_size, hmap_size, false, Image::FORMAT_RH);
    hmap_img->fill(Color(0.0, 0.0, 0.0, 1.0));
    h_maps.push_back(hmap_img);
    
    int cmap_size = size / 2;
    Ref<Image> cmap_img = Image::create(cmap_size, cmap_size, false, Image::FORMAT_RGBA8);
    cmap_img->fill(Color(0.0, 0.0, 0.0, 1.0));
    c_maps.push_back(cmap_img);

    height_map_array->create_from_images(h_maps);
    control_map_array->create_from_images(c_maps);

    map_array_positions.push_back(p_position);

    notify_property_list_changed();
    emit_changed();
}

void Terrain3DStorage::remove_map(Vector2 p_position)
{
}

void Terrain3DStorage::set_material(const Ref<TerrainMaterial3D>& p_material)
{
    material = p_material;
}

Ref<TerrainMaterial3D> Terrain3DStorage::get_material() const
{
    return material;
}


void Terrain3DStorage::set_shader_override(const Ref<Shader>& p_shader)
{
    shader_override = p_shader;
}

Ref<Shader> Terrain3DStorage::get_shader_override() const
{
    return shader_override;
}

void Terrain3DStorage::set_layer(const Ref<TerrainLayerMaterial3D> &p_material, int p_index)
{
    if (p_index < layers.size()) {

        if (p_material.is_null()) {
            Ref<TerrainLayerMaterial3D> material_to_remove = layers[p_index];
            material_to_remove->disconnect("texture_changed", Callable(this, "_update_textures"));
            material_to_remove->disconnect("value_changed", Callable(this, "_update_arrays"));
            layers.remove_at(p_index);
        } else {
            layers[p_index] = p_material;
        }
    } else {
        layers.push_back(p_material);
    }
    _update_layers();
}


void Terrain3DStorage::_update_layers()
{
    for (int i = 0; i < layers.size(); i++) {
        Ref<TerrainLayerMaterial3D> material = layers[i];

        if (!material->is_connected("texture_changed", Callable(this, "_update_textures"))) {
            material->connect("texture_changed", Callable(this, "_update_textures"));
        }
        if (!material->is_connected("value_changed", Callable(this, "_update_values"))) {
            material->connect("value_changed", Callable(this, "_update_values"));
        }
    }

    _update_arrays();
    _update_textures();
}

void Terrain3DStorage::_update_arrays()
{
    PackedVector3Array uv_scales;
    PackedColorArray colors;
    
    for (int i = 0; i < layers.size(); i++) {
        Ref<TerrainLayerMaterial3D> l_material = layers[i];

        uv_scales.push_back(l_material->get_uv_scale());
        colors.push_back(l_material->get_albedo());
    }

    emit_changed();
}

void Terrain3DStorage::_update_textures()
{
    Array albedo_texture_array;
    Array normal_texture_array;

    for (int i = 0; i < layers.size(); i++) {
        Ref<TerrainLayerMaterial3D> l_material = layers[i];
        albedo_texture_array.push_back(l_material->get_albedo_texture());
        normal_texture_array.push_back(l_material->get_normal_texture());
    }

    albedo_textures = _convert_array(albedo_texture_array);
    normal_textures = _convert_array(normal_texture_array);

}

Ref<Texture2DArray> Terrain3DStorage::_convert_array(const Array &p_array) const
{
    Array img_arr;

    for (int i = 0; i < p_array.size(); i++) {
        Ref<Texture2D> tex = p_array[i];

        if (!tex.is_null()) {
            img_arr.push_back(tex->get_image());
        }
    }

    Ref<Texture2DArray> tex_arr;

    if (!img_arr.is_empty()) {
        tex_arr->create_from_images(img_arr);
    }

    return tex_arr;
}

void Terrain3DStorage::_bind_methods() {

    ClassDB::bind_method(D_METHOD("set_size", "size"), &Terrain3DStorage::set_size);
    ClassDB::bind_method(D_METHOD("get_size"), &Terrain3DStorage::get_size);
    ClassDB::bind_method(D_METHOD("set_height", "height"), &Terrain3DStorage::set_height);
    ClassDB::bind_method(D_METHOD("get_height"), &Terrain3DStorage::get_height);

    ClassDB::bind_method(D_METHOD("set_shader_override", "shader"), &Terrain3DStorage::set_shader_override);
    ClassDB::bind_method(D_METHOD("get_shader_override"), &Terrain3DStorage::get_shader_override);

    ClassDB::bind_method(D_METHOD("set_layer", "material", "layer"), &Terrain3DStorage::set_layer);

    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "shader_override", PROPERTY_HINT_RESOURCE_TYPE, "Shader"), "set_shader_override", "get_shader_override");

}

