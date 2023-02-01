//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#include "terrain_editor.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void Terrain3DEditor::Brush::set_image(const Ref<Image> &p_image) {
	img_size = Vector2(p_image->get_size());
	image = p_image;
}

Vector2 Terrain3DEditor::Brush::get_image_size() const {
	return img_size;
}

void Terrain3DEditor::Brush::set_values(float p_size, float p_opacity, float p_flow) {
	size = int(p_size);
	opacity = p_opacity;
	flow = p_flow;
}

Color Terrain3DEditor::Brush::get_pixel(Vector2i p_position) {
	return image->get_pixelv(p_position);
}

int Terrain3DEditor::Brush::get_size() const {
	return size;
}

float Terrain3DEditor::Brush::get_opacity() const {
	return opacity;
}

float Terrain3DEditor::Brush::get_flow() const {
	return flow;
}

Terrain3DEditor::Terrain3DEditor() {
}

Terrain3DEditor::~Terrain3DEditor() {
}

void Terrain3DEditor::set_tool(Tool p_tool) {
	tool = p_tool;
}

Terrain3DEditor::Tool Terrain3DEditor::get_tool() const {
	return tool;
}

void Terrain3DEditor::set_operation(Operation p_operation) {
	operation = p_operation;
}

Terrain3DEditor::Operation Terrain3DEditor::get_operation() const {
	return operation;
}

void Terrain3DEditor::set_brush_data(Dictionary data) {
	if (data.is_empty()) {
		return;
	}
	brush.set_values(data["size"], data["opacity"], data["flow"]);
	brush.set_image(data["image"]);
}

void Terrain3DEditor::operate(Vector3 p_global_position, bool p_continuous_operation) {
	int region_size = terrain->get_storage()->get_region_size();

	Vector2 global_position_2d = Vector2(p_global_position.x, p_global_position.z);
	Vector2 region_position = global_position_2d / region_size + Vector2(0.5, 0.5);
	region_position = region_position.floor();
	Vector2 uv_position = ((global_position_2d / region_size) + Vector2(0.5, 0.5)) - region_position;

	switch (tool) {
		case REGION:
			if (!p_continuous_operation) {
				_operate_region(p_global_position);
				break;
			}
			break;
		case HEIGHT:
			if (p_continuous_operation) {
				_operate_height(uv_position, p_global_position);
				break;
			}
			break;
		case TEXTURE:
			break;
		case COLOR:
			break;
		default:
			break;
	}
}

void Terrain3DEditor::set_terrain(Terrain3D *p_terrain) {
	terrain = p_terrain;
}

Terrain3D *Terrain3DEditor::get_terrain() const {
	return terrain;
}

void Terrain3DEditor::_operate_region(Vector3 p_global_position) {
	bool has_region = terrain->get_storage()->has_region(p_global_position);

	if (operation == ADD) {
		if (!has_region) {
			terrain->get_storage()->add_region(p_global_position);
		}
		return;
	}
	if (operation == SUBTRACT) {
		if (has_region) {
			terrain->get_storage()->remove_region(p_global_position);
		}
		return;
	}
}

void Terrain3DEditor::_operate_height(Vector2 p_uv_position, Vector3 p_global_position) {
	if (!terrain->get_storage()->has_region(p_global_position)) {
		return;
	}

	int region_index = terrain->get_storage()->get_region_index(p_global_position);
	Ref<Image> image = terrain->get_storage()->get_map(region_index, Terrain3DStorage::TYPE_HEIGHT);
	Vector2i image_size = image->get_size();

	int s = brush.get_size();
	Vector2 is = brush.get_image_size();
	float o = brush.get_opacity();
	float f = brush.get_flow();

	for (int x = 0; x < s; x++) {
		for (int y = 0; y < s; y++) {
			Vector2i brush_offset = Vector2i(x, y) - (Vector2i(s, s) / 2);
			Vector2i img_pixel_position = Vector2i(p_uv_position * image_size) + brush_offset;

			if (_is_in_bounds(img_pixel_position, image_size)) {
				Vector2 brush_uv = Vector2(x, y) / float(s);
				Vector2i brush_pixel_position = Vector2i(brush_uv * is);

				float alpha = brush.get_pixel(brush_pixel_position).r;
				float source = image->get_pixelv(img_pixel_position).r;

				float final = source;

				switch (operation) {
					case Terrain3DEditor::ADD:
						final = Math::lerp(source, source + (o * alpha), f);
						break;
					case Terrain3DEditor::SUBTRACT:
						final = Math::lerp(source, source - (o * alpha), f);
						break;
					case Terrain3DEditor::MULTIPLY:
						final = Math::lerp(source, source * (o * alpha + 1.0f), f);
						break;
					case Terrain3DEditor::REPLACE:
						final = Math::lerp(source, o, alpha * f);
						break;
					default:
						break;
				}

				final = Math::clamp(final, 0.0f, 1.0f);
				Color color = Color(final, 0.0f, 0.0f, 1.0f);

				image->set_pixelv(img_pixel_position, color);
			}
		}
	}
	terrain->get_storage()->force_update_maps(Terrain3DStorage::TYPE_HEIGHT);
}

bool Terrain3DEditor::_is_in_bounds(Vector2i p_position, Vector2i p_max_position) {
	bool more_than_min = p_position.x >= 0 && p_position.y >= 0;
	bool less_than_max = p_position.x < p_max_position.x && p_position.y < p_max_position.y;
	return more_than_min && less_than_max;
}

void Terrain3DEditor::_bind_methods() {
	BIND_ENUM_CONSTANT(ADD);
	BIND_ENUM_CONSTANT(SUBTRACT);
	BIND_ENUM_CONSTANT(MULTIPLY);
	BIND_ENUM_CONSTANT(REPLACE);

	BIND_ENUM_CONSTANT(REGION);
	BIND_ENUM_CONSTANT(HEIGHT);
	BIND_ENUM_CONSTANT(TEXTURE);
	BIND_ENUM_CONSTANT(COLOR);

	ClassDB::bind_method(D_METHOD("operate", "position", "continuous_operation"), &Terrain3DEditor::operate);
	ClassDB::bind_method(D_METHOD("set_brush_data", "data"), &Terrain3DEditor::set_brush_data);
	ClassDB::bind_method(D_METHOD("set_tool", "tool"), &Terrain3DEditor::set_tool);
	ClassDB::bind_method(D_METHOD("get_tool"), &Terrain3DEditor::get_tool);
	ClassDB::bind_method(D_METHOD("set_operation", "operation"), &Terrain3DEditor::set_operation);
	ClassDB::bind_method(D_METHOD("get_operation"), &Terrain3DEditor::get_operation);

	ClassDB::bind_method(D_METHOD("set_terrain", "terrain"), &Terrain3DEditor::set_terrain);
}
