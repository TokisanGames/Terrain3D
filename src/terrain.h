//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#ifndef TERRAIN3D_CLASS_H
#define TERRAIN3D_CLASS_H

#ifdef WIN32
#include <windows.h>
#endif

#ifndef FLT_MAX
#define FLT_MAX __FLT_MAX__
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

#include <terrain_storage.h>
#include <geoclipmap.h>

using namespace godot;

class Terrain3D : public Node3D {

private:
    GDCLASS(Terrain3D, Node3D);

    int clipmap_size = 48;
    int clipmap_levels = 7;

    bool valid = false;

    Ref<Terrain3DStorage> storage;
    
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

    // Current editor or gameplay camera we are centering the terrain on.
    Camera3D* camera;
    // Position of the camera during the previous snapping. Set to max float value to force a snap update.
    Vector3 camera_last_position = Vector3(FLT_MAX, FLT_MAX, FLT_MAX);
    // Crashes if this is removed or <8 bytes, compiled w/ MSVC 2019 or mingw-w64 gcc. Two 32-bit vars work.
    uint64_t _dummy_var = 0;


protected:
    static void _bind_methods();
    void _notification(int p_what);
    void _update_visibility();
    void _update_world(RID p_space, RID p_scenario);

private:
    void get_camera();
    void find_cameras(TypedArray<Node> from_nodes, Node* excluded_node, Array& cam_array);

public:

    void set_clipmap_levels(int p_count);
    int get_clipmap_levels() const;

    void set_clipmap_size(int p_size);
    int get_clipmap_size() const;
    
    void set_storage(const Ref<Terrain3DStorage> &p_storage);
    Ref<Terrain3DStorage> get_storage() const;
    
    void clear(bool p_clear_meshes = true, bool p_clear_collision = true);
    void build(int p_clipmap_levels, int p_clipmap_size);
    void snap(Vector3 cam_pos);

    void _process(double delta);
    
    Terrain3D();
    ~Terrain3D();

};

#endif // TERRAIN3D_CLASS_H