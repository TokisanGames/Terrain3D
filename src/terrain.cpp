//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#include "terrain.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

Terrain3D::Terrain3D() {
    set_notify_transform(true);
}

Terrain3D::~Terrain3D() {
}

void Terrain3D::_process(double delta)
{
    if (camera == nullptr) {
        get_camera();
    }
    else {
        Vector3 cam_pos = camera->get_global_transform().origin;

        if (!valid) {
            return;
        }

        {
            Transform3D t = Transform3D(Basis(), cam_pos.floor() * Vector3(1, 0, 1));
            RenderingServer::get_singleton()->instance_set_transform(data.cross, t);
        }
        
        int edge = 0;
        int tile = 0;

        for (int l = 0; l < clipmap_levels; l++) {

            float scale = float(1 << l);
            Vector3 snapped_pos = (cam_pos / scale).floor() * scale * Vector3(1, 0, 1);
            
            Vector3 tile_size = Vector3(float(resolution << l), 0, float(resolution << l));
            Vector3 base = snapped_pos - Vector3(float(resolution << (l + 1)), 0, float(resolution << (l + 1)));

            // position tiles
            for (int x = 0; x < 4; x++) {
                for (int y = 0; y < 4; y++) {
                    if (l != 0 && (x == 1 || x == 2) && (y == 1 || y == 2)) {
                        continue;
                    }

                    Vector3 fill = Vector3(x >= 2 ? 1 : 0, 0, y >= 2 ? 1 : 0) * scale;
                    Vector3 tile_tl = base + Vector3(x, 0, y) * tile_size + fill;
                    //Vector3 tile_br = tile_tl + tile_size;

                    Transform3D t = Transform3D().scaled(Vector3(scale, 1, scale));
                    t.origin = tile_tl;

                    RenderingServer::get_singleton()->instance_set_transform(data.tiles[tile], t);

                    tile++;
                }
            }

            {
                Transform3D t = Transform3D().scaled(Vector3(scale, 1, scale));
                t.origin = snapped_pos;
                RenderingServer::get_singleton()->instance_set_transform(data.fillers[l], t);
            }

            if (l != clipmap_levels - 1) {
                float next_scale = scale * 2.0f;
                Vector3 next_snapped_pos = (cam_pos / next_scale).floor() * next_scale * Vector3(1, 0, 1);

                // position trims
                {
                    Vector3 tile_center = snapped_pos + (Vector3(scale, 0, scale) * 0.5f);
                    Vector3 d = cam_pos - next_snapped_pos;

                    int r = 0;
                    r |= d.x >= scale ? 0 : 2;
                    r |= d.z >= scale ? 0 : 1;

                    float rotations[4] = {
                        0.0, 270.0, 90, 180.0
                    };

                    float angle = UtilityFunctions::deg_to_rad(rotations[r]);
                    
                    Transform3D t = Transform3D().rotated(Vector3(0, 1, 0), -angle);
                    t = t.scaled(Vector3(scale, 1, scale));
                    t.origin = tile_center;

                    RenderingServer::get_singleton()->instance_set_transform(data.trims[edge], t);

                }

                // position seams
                {
                    Vector3 next_base = next_snapped_pos - Vector3(float(resolution << (l + 1)), 0, float(resolution << (l + 1)));
                    
                    Transform3D t = Transform3D().scaled(Vector3(scale, 1, scale));
                    t.origin = next_base;

                    RenderingServer::get_singleton()->instance_set_transform(data.seams[edge], t);
                    
                }

                edge++;
            }
        } 
    }
}

void Terrain3D::build() {

    RID scenario = get_world_3d()->get_scenario();
    RID material_rid = material.is_valid() ? material->get_rid() : RID();

    meshes = GeoClipMap::generate(resolution, clipmap_levels);

    for (int i = 0; i < meshes.size(); i++) {
        RID mesh = meshes[i];
        RenderingServer::get_singleton()->mesh_surface_set_material(mesh, 0, material_rid);
    }

    data.cross = RenderingServer::get_singleton()->instance_create2(meshes[GeoClipMap::CROSS], scenario);

    for (int l = 0; l < clipmap_levels; l++) {

        for (int x = 0; x < 4; x++) {
            for (int y = 0; y < 4; y++) {

                if (l != 0 && (x == 1 || x == 2) && (y == 1 || y == 2)) {
                    continue;
                }

                RID tile = RenderingServer::get_singleton()->instance_create2(meshes[GeoClipMap::TILE], scenario);
                data.tiles.push_back(tile);
;           }
        }

        RID filler = RenderingServer::get_singleton()->instance_create2(meshes[GeoClipMap::FILLER], scenario);
        data.fillers.push_back(filler);

        if (l != clipmap_levels - 1) {
            RID trim = RenderingServer::get_singleton()->instance_create2(meshes[GeoClipMap::TRIM], scenario);
            data.trims.push_back(trim);

            RID seam = RenderingServer::get_singleton()->instance_create2(meshes[GeoClipMap::SEAM], scenario);
            data.seams.push_back(seam);
        }
    }
    
    // Create collision

    /*if (!static_body.is_valid()) {
        static_body = PhysicsServer3D::get_singleton()->body_create();

        PhysicsServer3D::get_singleton()->body_set_mode(static_body, PhysicsServer3D::BODY_MODE_STATIC);
        PhysicsServer3D::get_singleton()->body_set_space(static_body, get_world_3d()->get_space());

        RID shape = PhysicsServer3D::get_singleton()->heightmap_shape_create();
        PhysicsServer3D::get_singleton()->body_add_shape(static_body, shape);

        Dictionary shape_data;
        int shape_size = p_size + 1;

        PackedFloat32Array map_data;
        map_data.resize(shape_size * shape_size);

        shape_data["width"] = shape_size;
        shape_data["depth"] = shape_size;
        shape_data["heights"] = map_data;
        shape_data["min_height"] = 0.0;
        shape_data["max_height"] = real_t(height);

        PhysicsServer3D::get_singleton()->shape_set_data(shape, shape_data);
    }*/

    valid = true;
}

void Terrain3D::set_as_infinite(bool p_enable)
{
    infinite = p_enable;
}

bool Terrain3D::is_infinite() const
{
    return infinite;
}

void Terrain3D::clear(bool p_clear_meshes, bool p_clear_collision) {

    if (p_clear_meshes) {

        for (const RID rid : meshes) {
            RenderingServer::get_singleton()->free_rid(rid);
        }

        meshes.clear();

        RenderingServer::get_singleton()->free_rid(data.cross);
        
        for (const RID rid : data.tiles) {
            RenderingServer::get_singleton()->free_rid(rid);
        }

        for (const RID rid : data.fillers) {
            RenderingServer::get_singleton()->free_rid(rid);
        }

        for (const RID rid : data.trims) {
            RenderingServer::get_singleton()->free_rid(rid);
        }

        for (const RID rid : data.seams) {
            RenderingServer::get_singleton()->free_rid(rid);
        }

        valid = false;
        
    }
    
    if (p_clear_collision) {
        if (static_body.is_valid()) {
            RID shape = PhysicsServer3D::get_singleton()->body_get_shape(static_body, 0);
            PhysicsServer3D::get_singleton()->free_rid(shape);
            PhysicsServer3D::get_singleton()->free_rid(static_body);
            static_body = RID();
        }
    }
}

void Terrain3D::set_size(int p_value) {
    ERR_FAIL_COND(p_value < MIN_TOTAL_SIZE);
    ERR_FAIL_COND(p_value > MAX_TOTAL_SIZE);

    size = p_value;
}

int Terrain3D::get_size() const {
    return size;
}

void Terrain3D::set_height(int p_value) {
    height = p_value;
}

int Terrain3D::get_height() const {
    return height;
}


void Terrain3D::set_material(const Ref<TerrainMaterial3D> &p_material) {

    material = p_material;

    if (!valid && material.is_valid()) {
        build();
    }
    else {
        RID rid = material.is_valid() ? material->get_rid() : RID();
        for (int i = 0; i < meshes.size(); i++) {
            RID mesh = meshes[i];
            RenderingServer::get_singleton()->mesh_surface_set_material(mesh, 0, rid);
        }
    } 
}

Ref<TerrainMaterial3D> Terrain3D::get_material() const {
    return material;
}

void Terrain3D::_notification(int p_what) {

    switch (p_what) {
        case NOTIFICATION_PREDELETE: {
            clear();
        } break;

        case NOTIFICATION_ENTER_WORLD: {
            _update_world(get_world_3d()->get_space(), get_world_3d()->get_scenario());
        } break;

        case NOTIFICATION_TRANSFORM_CHANGED: {
        } break;

        case NOTIFICATION_EXIT_WORLD: {
            _update_world(RID(), RID());
        } break;

        case NOTIFICATION_VISIBILITY_CHANGED: {
            _update_visibility();
        } break;

    }
}

void Terrain3D::_update_visibility() {

    if (!is_inside_tree() || !valid) {
        return;
    }

    bool v = is_visible_in_tree();
    RenderingServer::get_singleton()->instance_set_visible(data.cross, v);

    for (const RID rid : data.tiles) {
        RenderingServer::get_singleton()->instance_set_visible(rid, v);
    }

    for (const RID rid : data.fillers) {
        RenderingServer::get_singleton()->instance_set_visible(rid, v);
    }

    for (const RID rid : data.trims) {
        RenderingServer::get_singleton()->instance_set_visible(rid, v);
    }

    for (const RID rid : data.seams) {
        RenderingServer::get_singleton()->instance_set_visible(rid, v);
    }

}

void Terrain3D::_update_world(RID p_space, RID p_scenario)
{
    if (static_body.is_valid()) {
        PhysicsServer3D::get_singleton()->body_set_space(static_body, p_space);
    }

    if (!valid) {
        return;
    }

    RenderingServer::get_singleton()->instance_set_scenario(data.cross, p_scenario);

    for (const RID rid : data.tiles) {
        RenderingServer::get_singleton()->instance_set_scenario(rid, p_scenario);
    }

    for (const RID rid : data.fillers) {
        RenderingServer::get_singleton()->instance_set_scenario(rid, p_scenario);
    }

    for (const RID rid : data.trims) {
        RenderingServer::get_singleton()->instance_set_scenario(rid, p_scenario);
    }

    for (const RID rid : data.seams) {
        RenderingServer::get_singleton()->instance_set_scenario(rid, p_scenario);
    }

}

void Terrain3D::get_camera()
{
    if (Engine::get_singleton()->is_editor_hint()) {
        Ref<EditorScript> temp_editor_script = memnew(EditorScript);
        EditorInterface* editor_interface = temp_editor_script->get_editor_interface();
        Array& cam_array = Array();
        find_cameras(editor_interface->get_editor_main_screen()->get_children(), cam_array);
        if (!cam_array.is_empty()) {
            camera = Object::cast_to<Camera3D>(cam_array[0]);
        }
    }
    else {
        camera = get_viewport()->get_camera_3d();
    }
}

void Terrain3D::find_cameras(TypedArray<Node>& from_nodes, Array& cam_array)
{   
    for (int i = 0; i < from_nodes.size(); i++) {
        Node* node = Object::cast_to<Node>(from_nodes[i]);
        find_cameras(node->get_children(), cam_array);
        if (node->is_class("Camera3D")) {
            cam_array.push_back(node);
        }
    }
}

RID Terrain3D::create_section_mesh(int p_size, int p_subvision, RID p_material) const{
    PackedVector3Array vertices;
    PackedInt32Array indices;

    float s = float(p_size);
    int index = 0;
    float subdv = float(p_subvision);
    Vector3 ofs = Vector3(s, 0.0, s) / 2.0;

    // top
    for (int x = 0; x < p_subvision; x++) {
        for (int y = 0; y < p_subvision; y++) {
            vertices.append(Vector3(x / subdv * s, 0.0, y / subdv * s) - ofs);
            vertices.append(Vector3(x / subdv * s + s / subdv, 0.0, y / subdv * s) - ofs);
            vertices.append(Vector3(x / subdv * s, 0.0, y / subdv * s + s / subdv) - ofs);
            vertices.append(Vector3(x / subdv * s, 0.0, y / subdv * s + s / subdv) - ofs);
            vertices.append(Vector3(x / subdv * s + s / subdv, 0.0, y / subdv * s) - ofs);
            vertices.append(Vector3(x / subdv * s + s / subdv, 0.0, y / subdv * s + s / subdv) - ofs);
            indices.append(index);
            indices.append(index + 1);
            indices.append(index + 2);
            indices.append(index + 3);
            indices.append(index + 4);
            indices.append(index + 5);
            index += 6;
        }
    }
    // front
    for (int x = 0; x < p_subvision; x++) {
        vertices.append(Vector3(x / subdv * s, -1, 0) - ofs);
        vertices.append(Vector3(x / subdv * s + s / subdv, -1, 0) - ofs);
        vertices.append(Vector3(x / subdv * s, 0, 0) - ofs);
        vertices.append(Vector3(x / subdv * s, 0, 0) - ofs);
        vertices.append(Vector3(x / subdv * s + s / subdv, -1, 0) - ofs);
        vertices.append(Vector3(x / subdv * s + s / subdv, 0, 0) - ofs);
        indices.append(index);
        indices.append(index + 1);
        indices.append(index + 2);
        indices.append(index + 3);
        indices.append(index + 4);
        indices.append(index + 5);
        index += 6;
    }
    // back
    for (int x = 0; x < p_subvision; x++) {
        vertices.append(Vector3(x / subdv * s + s / subdv, 0, s) - ofs);
        vertices.append(Vector3(x / subdv * s + s / subdv, -1, s) - ofs);
        vertices.append(Vector3(x / subdv * s, 0, s) - ofs);
        vertices.append(Vector3(x / subdv * s, 0, s) - ofs);
        vertices.append(Vector3(x / subdv * s + s / subdv, -1, s) - ofs);
        vertices.append(Vector3(x / subdv * s, -1, s) - ofs);
        indices.append(index);
        indices.append(index + 1);
        indices.append(index + 2);
        indices.append(index + 3);
        indices.append(index + 4);
        indices.append(index + 5);
        index += 6;
    }
    // right
    for (int x = 0; x < p_subvision; x++) {
        vertices.append(Vector3(0, 0, x / subdv * s + s / subdv) - ofs);
        vertices.append(Vector3(0, -1, x / subdv * s + s / subdv) - ofs);
        vertices.append(Vector3(0, 0, x / subdv * s) - ofs);
        vertices.append(Vector3(0, 0, x / subdv * s) - ofs);
        vertices.append(Vector3(0, -1, x / subdv * s + s / subdv) - ofs);
        vertices.append(Vector3(0, -1, x / subdv * s) - ofs);
        indices.append(index);
        indices.append(index + 1);
        indices.append(index + 2);
        indices.append(index + 3);
        indices.append(index + 4);
        indices.append(index + 5);
        index += 6;
    }
    // left
    for (int x = 0; x < p_subvision; x++) {
        vertices.append(Vector3(s, -1, x / subdv * s) - ofs);
        vertices.append(Vector3(s, -1, x / subdv * s + s / subdv) - ofs);
        vertices.append(Vector3(s, 0, x / subdv * s) - ofs);
        vertices.append(Vector3(s, 0, x / subdv * s) - ofs);
        vertices.append(Vector3(s, -1, x / subdv * s + s / subdv) - ofs);
        vertices.append(Vector3(s, 0, x / subdv * s + s / subdv) - ofs);
        indices.append(index);
        indices.append(index + 1);
        indices.append(index + 2);
        indices.append(index + 3);
        indices.append(index + 4);
        indices.append(index + 5);
        index += 6;
    }

    Array arrays;
    arrays.resize(RenderingServer::ARRAY_MAX);
    arrays[RenderingServer::ARRAY_VERTEX] = vertices;
    arrays[RenderingServer::ARRAY_INDEX] = indices;

    RID mesh = RenderingServer::get_singleton()->mesh_create();

    RenderingServer::get_singleton()->mesh_add_surface_from_arrays(mesh, RenderingServer::PRIMITIVE_TRIANGLES, arrays);
    RenderingServer::get_singleton()->mesh_surface_set_material(mesh, 0, p_material);

    return mesh;
}

void Terrain3D::_bind_methods() {

    ClassDB::bind_method(D_METHOD("set_size", "size"), &Terrain3D::set_size);
    ClassDB::bind_method(D_METHOD("get_size"), &Terrain3D::get_size);

    ClassDB::bind_method(D_METHOD("set_height", "height"), &Terrain3D::set_height);
    ClassDB::bind_method(D_METHOD("get_height"), &Terrain3D::get_height);

    ClassDB::bind_method(D_METHOD("set_material", "material"), &Terrain3D::set_material);
    ClassDB::bind_method(D_METHOD("get_material"), &Terrain3D::get_material);

    ClassDB::bind_method(D_METHOD("set_as_infinite", "enable"), &Terrain3D::set_as_infinite);
    ClassDB::bind_method(D_METHOD("is_infinite"), &Terrain3D::is_infinite);

    ClassDB::bind_method(D_METHOD("clear"), &Terrain3D::clear);
    ClassDB::bind_method(D_METHOD("build"), &Terrain3D::build);

    ADD_PROPERTY(PropertyInfo(Variant::INT, "size", PROPERTY_HINT_RANGE, "128,8192,1"), "set_size", "get_size");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "height", PROPERTY_HINT_RANGE, "1,512,1"), "set_height", "get_height");

    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "infinite", PROPERTY_HINT_NONE), "set_as_infinite", "is_infinite");

    ADD_GROUP("Material", "surface_");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "surface_material", PROPERTY_HINT_RESOURCE_TYPE, "TerrainMaterial3D"), "set_material", "get_material");

}