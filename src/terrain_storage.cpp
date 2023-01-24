//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#include "terrain_storage.h"
#include <godot_cpp/core/class_db.hpp>

using namespace godot;

Terrain3DStorage::Terrain3DStorage() 
{
    if (!_initialized) {
        _update_material();
        _initialized = true;
    }
}

Terrain3DStorage::~Terrain3DStorage() 
{
    if (_initialized) {
        _initialized = false;
    }
}

void Terrain3DStorage::set_size(int p_size)
{
    map_size = p_size;
}

int Terrain3DStorage::get_size() const
{
    return map_size;
}

void Terrain3DStorage::set_height(int p_height)
{
    map_height = p_height;
}

int Terrain3DStorage::get_height() const
{
    return map_height;
}

void Terrain3DStorage::add_map(Vector2 p_global_position)
{
    TypedArray<Image> h_maps, c_maps;

    if (height_maps.is_valid() && control_maps.is_valid()) {

        ERR_FAIL_COND(height_maps->get_layers() != control_maps->get_layers());

        for (int i = 0; i < height_maps->get_layers(); i++) {
            h_maps.push_back(height_maps->get_layer_data(i));
            c_maps.push_back(control_maps->get_layer_data(i));
        }
    }

    Ref<Image> hmap_img = Image::create(map_size, map_size, false, Image::FORMAT_RH);
    hmap_img->fill(Color(0.0, 0.0, 0.0, 1.0));
    h_maps.push_back(hmap_img);
    
    Ref<Image> cmap_img = Image::create(map_size, map_size, false, Image::FORMAT_RGBA8);
    cmap_img->fill(Color(0.0, 0.0, 0.0, 1.0));
    c_maps.push_back(cmap_img);

    if (height_maps.is_null()) {
        height_maps.instantiate();
    }

    if (control_maps.is_null()) {
        control_maps.instantiate();
    }

    height_maps->create_from_images(h_maps);
    control_maps->create_from_images(c_maps);

    Vector2 uv_offset = (p_global_position / float(map_size)).floor();
    map_offsets.push_back(uv_offset);

    _update_material();

    notify_property_list_changed();
    emit_changed();
}

void Terrain3DStorage::remove_map(Vector2 p_global_position)
{
    Vector2 uv_offset = (p_global_position / float(map_size)).floor();
    int index = -1;

    for (int i = 0; i < map_offsets.size(); i++) {
        Vector2 pos = map_offsets[i];
        if (pos == uv_offset) {
            index = i;
            break;
        }
    }

    ERR_FAIL_COND_MSG(index == -1, "Map does not exist.");
    map_offsets.remove_at(index);

    TypedArray<Image> h_maps, c_maps;
   
    for (int i = 0; i < height_maps->get_layers(); i++) {
        if (i != index) {
            h_maps.push_back(height_maps->get_layer_data(i));
            c_maps.push_back(control_maps->get_layer_data(i));
        }
    }

    height_maps->create_from_images(h_maps);
    control_maps->create_from_images(c_maps);

    _update_material();

    notify_property_list_changed();
    emit_changed();
}

void Terrain3DStorage::set_height_maps(const Ref<Texture2DArray>& p_maps)
{
    height_maps = p_maps;
    _update_material();
}

Ref<Texture2DArray> Terrain3DStorage::get_height_maps() const
{
    return height_maps;
}

void Terrain3DStorage::set_control_maps(const Ref<Texture2DArray>& p_maps)
{
    control_maps = p_maps;
    _update_material();
}

Ref<Texture2DArray> Terrain3DStorage::get_control_maps() const
{
    return control_maps;
}

void Terrain3DStorage::set_map_offsets(const Array& p_offsets)
{
    map_offsets = p_offsets;
    _update_material();
}

Array Terrain3DStorage::get_map_offsets() const
{
    return map_offsets;
}

int Terrain3DStorage::get_map_count() const
{
    return map_offsets.size();
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
    notify_property_list_changed();
}

Ref<TerrainLayerMaterial3D> Terrain3DStorage::get_layer(int p_index) const
{
    return layers[p_index];
}

void Terrain3DStorage::set_layers(const Array& p_layers)
{
    layers = p_layers;
}

Array Terrain3DStorage::get_layers() const
{
   return layers;
}

int Terrain3DStorage::get_layer_count() const
{
    return layers.size();
}


void Terrain3DStorage::_update_layers()
{
    for (int i = 0; i < layers.size(); i++) {
        Ref<TerrainLayerMaterial3D> l_material = layers[i];

        if (!l_material->is_connected("texture_changed", Callable(this, "_update_textures"))) {
            l_material->connect("texture_changed", Callable(this, "_update_textures"));
        }
        if (!l_material->is_connected("value_changed", Callable(this, "_update_values"))) {
            l_material->connect("value_changed", Callable(this, "_update_values"));
        }
    }

    _update_arrays();
    _update_textures();
}

// PRIVATE

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

void Terrain3DStorage::_update_material()
{
    if (material.is_null()) {
        material.instantiate();
    }
    material->set_maps(height_maps, control_maps, map_offsets);
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

    ClassDB::bind_method(D_METHOD("set_height", "height"), &Terrain3DStorage::set_height);
    ClassDB::bind_method(D_METHOD("get_height"), &Terrain3DStorage::get_height);
  
    ClassDB::bind_method(D_METHOD("set_shader_override", "shader"), &Terrain3DStorage::set_shader_override);
    ClassDB::bind_method(D_METHOD("get_shader_override"), &Terrain3DStorage::get_shader_override);

    ClassDB::bind_method(D_METHOD("set_layer", "material", "index"), &Terrain3DStorage::set_layer);
    ClassDB::bind_method(D_METHOD("get_layer", "index"), &Terrain3DStorage::get_layer);

    ClassDB::bind_method(D_METHOD("set_layers", "layers"), &Terrain3DStorage::set_layers);
    ClassDB::bind_method(D_METHOD("get_layers"), &Terrain3DStorage::get_layers);

    ClassDB::bind_method(D_METHOD("add_map", "global_position"), &Terrain3DStorage::add_map);
    ClassDB::bind_method(D_METHOD("remove_map", "global_position"), &Terrain3DStorage::remove_map);

    ClassDB::bind_method(D_METHOD("set_height_maps", "maps"), &Terrain3DStorage::set_height_maps);
    ClassDB::bind_method(D_METHOD("get_height_maps"), &Terrain3DStorage::get_height_maps);
    ClassDB::bind_method(D_METHOD("set_control_maps", "maps"), &Terrain3DStorage::set_control_maps);
    ClassDB::bind_method(D_METHOD("get_control_maps"), &Terrain3DStorage::get_control_maps);
    ClassDB::bind_method(D_METHOD("set_map_offsets", "offsets"), &Terrain3DStorage::set_map_offsets);
    ClassDB::bind_method(D_METHOD("get_map_offsets"), &Terrain3DStorage::get_map_offsets);

    ADD_PROPERTY(PropertyInfo(Variant::INT, "map_height", PROPERTY_HINT_RANGE, "1, 1024, 1"), "set_height", "get_height");

    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "height_maps", PROPERTY_HINT_RESOURCE_TYPE, "Texture2DArray"), "set_height_maps", "get_height_maps");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "control_maps", PROPERTY_HINT_RESOURCE_TYPE, "Texture2DArray"), "set_control_maps", "get_control_maps");
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "map_offsets", PROPERTY_HINT_ARRAY_TYPE, vformat("%s/%s:%s", Variant::VECTOR2, PROPERTY_HINT_NONE)), "set_map_offsets", "get_map_offsets");

    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "shader_override", PROPERTY_HINT_RESOURCE_TYPE, "Shader"), "set_shader_override", "get_shader_override");
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "layers", PROPERTY_HINT_ARRAY_TYPE, vformat("%s/%s:%s", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "TerrainLayerMaterial3D")), "set_layers", "get_layers");

}

