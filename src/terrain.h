//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#ifndef TERRAIN3D_CLASS_H
#define TERRAIN3D_CLASS_H

#ifdef WIN32
#include <windows.h>
#endif

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/physics_server3d.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/classes/editor_script.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/v_box_container.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/templates/vector.hpp>

#include <terrain_material.h>
#include <geoclipmap.h>

using namespace godot;

class Terrain3D : public Node3D {

private:
    GDCLASS(Terrain3D, Node3D);

public:
    enum {
        MIN_TOTAL_SIZE = 512,
        MAX_TOTAL_SIZE = 8192,
    };

private:
    int size = 1024;
    int height = 128;
   
    int resolution = 48;
    int clipmap_levels = 7;

    bool infinite = false;
    bool valid = false;

    Ref<TerrainMaterial3D> material;

    struct Instances {
        RID cross;
        Vector<RID> tiles;
        Vector<RID> fillers;
        Vector<RID> trims;
        Vector<RID> seams;
    };

    Instances data;

    Vector<RID> meshes;
    RID static_body;

    uint32_t collision_layer = 1;
    uint32_t collision_mask = 1;
    real_t collision_priority = 1.0;

    Camera3D* camera;
    Vector3 previous_offset_position = Vector3(0, 0, 0);

protected:
    static void _bind_methods();
    void _notification(int p_what);
    void _update_visibility();
    void _update_world(RID p_space, RID p_scenario);

private:
    void get_camera();
    void find_cameras(TypedArray<Node>& from_nodes, Array& cam_array);

public:
    void set_size(int p_value);
    int get_size() const;
    void set_height(int p_value);
    int get_height() const;

    void set_material(const Ref<TerrainMaterial3D> &p_material);
    Ref<TerrainMaterial3D> get_material() const;

    RID create_section_mesh(int p_size, int p_subvision, RID p_material) const;
    void clear(bool p_clear_meshes = true, bool p_clear_collision = true);
    void build();

    void set_as_infinite(bool p_enable);
    bool is_infinite() const;

    void _process(double delta);
    
    Terrain3D();
    ~Terrain3D();

};

#endif // TERRAIN3D_CLASS_H