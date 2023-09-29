// Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
#ifndef TERRAIN3D_EDITOR_CLASS_H
#define TERRAIN3D_EDITOR_CLASS_H

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>

#include "terrain_3d.h"

using namespace godot;

class Terrain3DEditor : public Object {
private:
	GDCLASS(Terrain3DEditor, Object);
	static inline const char *__class__ = "Terrain3DEditor";

	// Constants & Definitions

	enum Operation {
		ADD,
		SUBTRACT,
		MULTIPLY,
		DIVIDE,
		REPLACE,
		AVERAGE,
		OP_MAX,
	};

	static inline const char *OPNAME[] = {
		"Add",
		"Subtract",
		"Multiply",
		"Divide",
		"Replace",
		"Average",
		"OP_MAX",
	};

	enum Tool {
		HEIGHT,
		TEXTURE,
		COLOR,
		ROUGHNESS,
		REGION,
		TOOL_MAX,
	};

	static inline const char *TOOLNAME[] = {
		"Height",
		"Texture",
		"Color",
		"Roughness",
		"Region",
		"TOOL_MAX",
	};

	class Brush {
	private:
		Ref<ImageTexture> _texture;
		Ref<Image> _image;
		Vector2 _img_size;
		int _size = 0;
		int _index = 0;
		float _opacity = 0.0;
		float _height = 0.0;
		Color _color = COLOR_ROUGHNESS;
		float _roughness = 0.5;
		float _jitter = 0.0;
		float _gamma = 1.0;
		bool _align_to_view = false;
		bool _auto_regions = false;

	public:
		Ref<ImageTexture> get_texture() const { return _texture; }
		Ref<Image> get_image() const { return _image; }
		Vector2 get_image_size() const { return _img_size; }
		void set_data(Dictionary p_data);
		float get_alpha(Vector2i p_position) { return _image->get_pixelv(p_position).r; }
		int get_size() const { return _size; }
		int get_index() const { return _index; }
		float get_opacity() const { return _opacity; }
		float get_height() const { return _height; }
		Color get_color() const { return _color; }
		float get_roughness() const { return _roughness; }
		float get_jitter() const { return _jitter; }
		float get_gamma() const { return _gamma; }
		bool is_aligned_to_view() const { return _align_to_view; }
		bool auto_regions_enabled() const { return _auto_regions; }
	};

	// Object references

	Terrain3D *_terrain = nullptr;

	// Painter settings & variables

	Tool _tool = REGION;
	Operation _operation = ADD;
	Vector3 _operation_position = Vector3();
	float _operation_interval = 0.0f;
	Brush _brush;

	Array _undo_set; // 0-2: map 0,1,2, 3: Region offsets, 4: height range

private:
	void _operate_region(Vector3 p_global_position);
	void _operate_map(Vector3 p_global_position, float p_camera_direction);
	bool _is_in_bounds(Vector2i p_position, Vector2i p_max_position);
	Vector2 _get_uv_position(Vector3 p_global_position, int p_region_size);
	Vector2 _rotate_uv(Vector2 p_uv, float p_angle);

public:
	Terrain3DEditor();
	~Terrain3DEditor();

	inline void set_terrain(Terrain3D *p_terrain) { _terrain = p_terrain; }
	inline Terrain3D *get_terrain() const { return _terrain; }

	void set_brush_data(Dictionary data);
	void set_tool(Tool p_tool) { _tool = p_tool; }
	Tool get_tool() const { return _tool; }
	void set_operation(Operation p_operation) { _operation = p_operation; }
	Operation get_operation() const { return _operation; }
	void operate(Vector3 p_global_position, float p_camera_direction, bool p_continuous_operation);

	void setup_undo();
	void store_undo();
	void apply_undo(const Array &p_set);

protected:
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Terrain3DEditor::Operation);
VARIANT_ENUM_CAST(Terrain3DEditor::Tool);

#endif // TERRAIN3D_EDITOR_CLASS_H