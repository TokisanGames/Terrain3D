//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#ifndef TERRAINEDITOR_CLASS_H
#define TERRAINEDITOR_CLASS_H

#ifdef WIN32
#include <windows.h>
#endif

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/core/math.hpp>

#include "terrain.h"

using namespace godot;

class Terrain3DEditor : public Object {
	GDCLASS(Terrain3DEditor, Object);

public:
	enum Operation {
		ADD,
		SUBTRACT,
		MULTIPLY,
		REPLACE,
		AVERAGE,
	};

	enum Tool {
		REGION,
		HEIGHT,
		TEXTURE,
		COLOR,
	};

	struct Brush {
		Ref<Image> image;
		Vector2 img_size;
		int size = 0;
		float opacity = 0.0;
		float flow = 0.0;

	public:
		void set_image(const Ref<Image> &p_image);
		Ref<Image> get_image() const;
		Vector2 get_image_size() const;
		void set_values(float p_size, float p_opacity, float p_flow);
		Color get_pixel(Vector2i p_position);
		int get_size() const;
		float get_opacity() const;
		float get_flow() const;
	};

	Tool tool = REGION;
	Operation operation = ADD;
	Brush brush;

	Terrain3D *terrain = nullptr;

private:
	void _operate_region(Vector3 p_global_position);
	void _operate_height(Vector2 p_uv_position, Vector3 p_global_position);
	bool _is_in_bounds(Vector2i p_position, Vector2i p_max_position);

protected:
	static void _bind_methods();

public:
	Terrain3DEditor();
	~Terrain3DEditor();

	void set_tool(Tool p_tool);
	Tool get_tool() const;
	void set_operation(Operation p_operation);
	Operation get_operation() const;
	void set_brush_data(Dictionary data);
	void operate(Vector3 p_global_position, bool p_continuous_operation);

	void set_terrain(Terrain3D *p_terrain);
	Terrain3D *get_terrain() const;
};

VARIANT_ENUM_CAST(Terrain3DEditor, Operation);
VARIANT_ENUM_CAST(Terrain3DEditor, Tool);

#endif // TERRAINEDITOR_CLASS_H