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
    else if (valid) {

        Vector3 cam_pos = camera->get_global_transform().origin * Vector3(1, 0, 1);
        {
            Transform3D t = Transform3D(Basis(), cam_pos.floor());
            RenderingServer::get_singleton()->instance_set_transform(data.cross, t);
        }
        
        int edge = 0;
        int tile = 0;

        for (int l = 0; l < clipmap_levels; l++) {
            float scale = float(1 << l);
            Vector3 snapped_pos = (cam_pos / scale).floor() * scale;
            Vector3 tile_size = Vector3(float(clipmap_size << l), 0, float(clipmap_size << l));
            Vector3 base = snapped_pos - Vector3(float(clipmap_size << (l + 1)), 0, float(clipmap_size << (l + 1)));

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
                Vector3 next_snapped_pos = (cam_pos / next_scale).floor() * next_scale;

                // position trims
                {
                    Vector3 tile_center = snapped_pos + (Vector3(scale, 0, scale) * 0.5f);
                    Vector3 d = cam_pos - next_snapped_pos;

                    int r = 0;
                    r |= d.x >= scale ? 0 : 2;
                    r |= d.z >= scale ? 0 : 1;

                    float rotations[4] = { 0.0, 270.0, 90, 180.0 };

                    float angle = UtilityFunctions::deg_to_rad(rotations[r]);
                    Transform3D t = Transform3D().rotated(Vector3(0, 1, 0), -angle);
                    t = t.scaled(Vector3(scale, 1, scale));
                    t.origin = tile_center;
                    RenderingServer::get_singleton()->instance_set_transform(data.trims[edge], t);
                }

                // position seams
                {
                    Vector3 next_base = next_snapped_pos - Vector3(float(clipmap_size << (l + 1)), 0, float(clipmap_size << (l + 1)));
                    Transform3D t = Transform3D().scaled(Vector3(scale, 1, scale));
                    t.origin = next_base;
                    RenderingServer::get_singleton()->instance_set_transform(data.seams[edge], t); 
                }
                edge++;
            }
        } 
    }
}

void Terrain3D::build(int p_clipmap_levels, int p_clipmap_size) 
{
    ERR_FAIL_COND(!storage.is_valid());
   
    RID scenario = get_world_3d()->get_scenario();
    RID material_rid = storage->get_material().is_valid() ? storage->get_material()->get_rid() : RID();

    meshes = GeoClipMap::generate(p_clipmap_size, p_clipmap_levels);
    ERR_FAIL_COND(meshes.is_empty());

    for (const RID rid : meshes) {
        RenderingServer::get_singleton()->mesh_surface_set_material(rid, 0, material_rid);
    }

    data.cross = RenderingServer::get_singleton()->instance_create2(meshes[GeoClipMap::CROSS], scenario);

    for (int l = 0; l < p_clipmap_levels; l++) {

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

        if (l != p_clipmap_levels - 1) {
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

void Terrain3D::clear(bool p_clear_meshes, bool p_clear_collision) {

    if (p_clear_meshes) {

        for (const RID rid : meshes) {
            RenderingServer::get_singleton()->free_rid(rid);
        }

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

        meshes.clear();

        data.tiles.clear();
        data.fillers.clear();
        data.trims.clear();
        data.seams.clear();

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


void Terrain3D::set_clipmap_levels(int p_count)
{
    if (clipmap_levels != p_count) {
        clear();
        build(p_count, clipmap_size);
    }
    clipmap_levels = p_count;
}

int Terrain3D::get_clipmap_levels() const
{
    return clipmap_levels;
}

void Terrain3D::set_clipmap_size(int p_size)
{
    if (clipmap_size != p_size) {
        clear();
        build(clipmap_levels, p_size);
    }
    clipmap_size = p_size;
}

int Terrain3D::get_clipmap_size() const
{
    return clipmap_size;
}

void Terrain3D::set_storage(const Ref<Terrain3DStorage> &p_storage) 
{
    if (storage != p_storage) {
        storage = p_storage;

        clear();

        if (storage.is_valid()) {

            if (storage->get_map_count() == 0) {
                storage->add_map(Vector2(0, 0));
            }
                
            build(clipmap_levels, clipmap_size);
        }
    }
}

Ref<Terrain3DStorage> Terrain3D::get_storage() const 
{
    return storage;
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
        EditorScript temp_editor_script;
        EditorInterface* editor_interface = temp_editor_script.get_editor_interface();
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

void Terrain3D::_bind_methods() {


    ClassDB::bind_method(D_METHOD("set_clipmap_levels", "count"), &Terrain3D::set_clipmap_levels);
    ClassDB::bind_method(D_METHOD("get_clipmap_levels"), &Terrain3D::get_clipmap_levels);

    ClassDB::bind_method(D_METHOD("set_clipmap_size", "size"), &Terrain3D::set_clipmap_size);
    ClassDB::bind_method(D_METHOD("get_clipmap_size"), &Terrain3D::get_clipmap_size);

    ClassDB::bind_method(D_METHOD("set_storage", "storage"), &Terrain3D::set_storage);
    ClassDB::bind_method(D_METHOD("get_storage"), &Terrain3D::get_storage);

    ClassDB::bind_method(D_METHOD("clear", "clear_meshes", "clear_collision"), &Terrain3D::clear);
    ClassDB::bind_method(D_METHOD("build", "clipmap_levels", "clipmap_size"), &Terrain3D::build);

    ADD_GROUP("Clipmap", "clipmap_");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "clipmap_levels", PROPERTY_HINT_RANGE, "1,10,1"), "set_clipmap_levels", "get_clipmap_levels");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "clipmap_size", PROPERTY_HINT_RANGE, "8,64,1"), "set_clipmap_size", "get_clipmap_size");

    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "storage", PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DStorage"), "set_storage", "get_storage");

}