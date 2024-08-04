// Copyright © 2024 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_EDITOR_CLASS_H
#define TERRAIN3D_EDITOR_CLASS_H

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>

#include "terrain_3d.h"

using namespace godot;

class Terrain3DEditor : public Object {
	GDCLASS(Terrain3DEditor, Object);
	CLASS_NAME();

public: // Constants
	enum Operation {
		ADD,
		SUBTRACT,
		REPLACE,
		AVERAGE,
		GRADIENT,
		OP_MAX,
	};

	static inline const char *OPNAME[] = {
		"Add",
		"Subtract",
		"Replace",
		"Average",
		"Gradient",
		"OP_MAX",
	};

	enum Tool {
		REGION,
		HEIGHT,
		TEXTURE,
		COLOR,
		ROUGHNESS,
		AUTOSHADER,
		HOLES,
		NAVIGATION,
		INSTANCER,
		ANGLE, // used for picking, TODO change to a picking tool
		SCALE, // used for picking
		TOOL_MAX,
	};

	static inline const char *TOOLNAME[] = {
		"Region",
		"Height",
		"Texture",
		"Color",
		"Roughness",
		"Auto Shader",
		"Holes",
		"Navigation",
		"Instancer",
		"Angle",
		"Scale",
		"TOOL_MAX",
	};

private:
	Terrain3D *_terrain = nullptr;

	// Painter settings & variables
	Tool _tool = REGION;
	Operation _operation = ADD;
	Ref<Image> _brush_image;
	Dictionary _brush_data;
	Vector3 _operation_position = Vector3();
	Vector3 _operation_movement = Vector3();
	Array _operation_movement_history;
	bool _pending_undo = false;
	bool _modified = false;
	AABB _modified_area;
	Dictionary _undo_data; // See _get_undo_data for definition

	void _region_modified(const Vector3 &p_global_position, const Vector2 &p_height_range = Vector2());
	void _operate_region(const Vector3 &p_global_position);
	void _operate_map(const Vector3 &p_global_position, const real_t p_camera_direction);
	bool _is_in_bounds(const Vector2i &p_position, const Vector2i &p_max_position) const;
	real_t _get_brush_alpha(const Vector2i &p_position) const;
	Vector2 _get_uv_position(const Vector3 &p_global_position, const int p_region_size) const;
	Vector2 _get_rotated_uv(const Vector2 &p_uv, const real_t p_angle) const;

	Dictionary _get_undo_data() const;
	void _store_undo();
	void _apply_undo(const Dictionary &p_set);

public:
	Terrain3DEditor() {}
	~Terrain3DEditor() {}

	void set_terrain(Terrain3D *p_terrain) { _terrain = p_terrain; }
	Terrain3D *get_terrain() const { return _terrain; }

	void set_brush_data(const Dictionary &p_data);
	void set_tool(const Tool p_tool);
	Tool get_tool() const { return _tool; }
	void set_operation(const Operation p_operation) { _operation = CLAMP(p_operation, Operation(0), OP_MAX); }
	Operation get_operation() const { return _operation; }

	void start_operation(const Vector3 &p_global_position);
	void operate(const Vector3 &p_global_position, const real_t p_camera_direction);
	void stop_operation();
	bool is_operating() const { return _pending_undo; }

protected:
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Terrain3DEditor::Operation);
VARIANT_ENUM_CAST(Terrain3DEditor::Tool);

#endif // TERRAIN3D_EDITOR_CLASS_H
