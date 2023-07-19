// Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
#include <godot_cpp/classes/editor_undo_redo_manager.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "terrain_3d_editor.h"
#include "terrain_3d_logger.h"

///////////////////////////
// Subclass Functions
///////////////////////////

void Terrain3DEditor::Brush::set_data(Dictionary p_data) {
	LOG(DEBUG, "Setting brush data: ");
	Array ks = p_data.keys();
	for (int i = 0; i < ks.size(); i++) {
		LOG(DEBUG, ks[i], ": ", p_data[ks[i]]);
	}
	_size = p_data["size"];
	_index = p_data["index"];
	_opacity = p_data["opacity"];
	_height = p_data["height"];
	_color = p_data["color"];
	_roughness = p_data["roughness"];
	_gamma = p_data["gamma"];
	_jitter = p_data["jitter"];
	_texture = p_data["texture"];
	_image = p_data["image"];
	if (_image.is_valid()) {
		_img_size = Vector2(_image->get_size());
	} else {
		_img_size = Vector2(0, 0);
	}
	_align_to_view = p_data["align_with_view"];
	_auto_regions = p_data["automatic_regions"];
}

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3DEditor::_operate_region(Vector3 p_global_position) {
	bool has_region = _terrain->get_storage()->has_region(p_global_position);

	if (_operation == ADD) {
		if (!has_region) {
			_terrain->get_storage()->add_region(p_global_position);
		}
	}
	if (_operation == SUBTRACT) {
		if (has_region) {
			_terrain->get_storage()->remove_region(p_global_position);
		}
	}
}

void Terrain3DEditor::_operate_map(Vector3 p_global_position, float p_camera_direction) {
	Ref<Terrain3DStorage> storage = _terrain->get_storage();
	int region_size = storage->get_region_size();
	Vector2i region_vsize = Vector2i(region_size, region_size);
	int region_index = storage->get_region_index(p_global_position);

	if (region_index == -1) {
		LOG(DEBUG, "No region to operate on, attempting to add");
		storage->add_region(p_global_position);
		region_size = storage->get_region_size();
		region_index = storage->get_region_index(p_global_position);
		if (region_index == -1) {
			LOG(ERROR, "Failed to add region, no region to operate on");
			return;
		}
	} else if (_tool < 0 || _tool >= REGION) {
		LOG(ERROR, "Invalid tool selected");
		return;
	}

	Terrain3DStorage::MapType map_type;
	switch (_tool) {
		case HEIGHT:
			map_type = Terrain3DStorage::TYPE_HEIGHT;
			break;
		case TEXTURE:
			map_type = Terrain3DStorage::TYPE_CONTROL;
			break;
		case COLOR:
			map_type = Terrain3DStorage::TYPE_COLOR;
			break;
		case ROUGHNESS:
			map_type = Terrain3DStorage::TYPE_COLOR;
			break;
		default:
			return;
	}

	Ref<Image> map = storage->get_map_region(map_type, region_index);
	int brush_size = _brush.get_size();
	int index = _brush.get_index();
	Vector2 img_size = _brush.get_image_size();
	float opacity = _brush.get_opacity();
	float height = _brush.get_height();
	Color color = _brush.get_color();
	float roughness = _brush.get_roughness();
	float gamma = _brush.get_gamma();

	float randf = UtilityFunctions::randf();
	float rot = randf * Math_PI * _brush.get_jitter();
	if (_brush.is_aligned_to_view()) {
		rot += p_camera_direction;
	}
	Object::cast_to<Node>(_terrain->get_plugin()->get("ui"))->call("set_decal_rotation", rot);

	for (int x = 0; x < brush_size; x++) {
		for (int y = 0; y < brush_size; y++) {
			Vector2i brush_offset = Vector2i(x, y) - (Vector2i(brush_size, brush_size) / 2);
			Vector3 brush_global_position = Vector3(p_global_position.x + float(brush_offset.x), p_global_position.y, p_global_position.z + float(brush_offset.y));

			int new_region_index = storage->get_region_index(brush_global_position);

			if (new_region_index == -1) {
				if (!_brush.auto_regions_enabled()) {
					continue;
				}
				Error err = storage->add_region(brush_global_position);
				if (err) {
					continue;
				}
				new_region_index = storage->get_region_index(brush_global_position);
			}

			if (new_region_index != region_index) {
				region_index = new_region_index;
				map = storage->get_map_region(map_type, region_index);
			}

			Vector2 uv_position = _get_uv_position(brush_global_position, region_size);
			Vector2i map_pixel_position = Vector2i(uv_position * region_size);

			if (_is_in_bounds(map_pixel_position, region_vsize)) {
				Vector2 brush_uv = Vector2(x, y) / float(brush_size);
				Vector2i brush_pixel_position = Vector2i(_rotate_uv(brush_uv, rot) * img_size);

				if (!_is_in_bounds(brush_pixel_position, Vector2i(img_size))) {
					continue;
				}

				float brush_alpha = float(Math::pow(double(_brush.get_alpha(brush_pixel_position)), double(gamma)));
				Color src = map->get_pixelv(map_pixel_position);
				Color dest = src;

				if (map_type == Terrain3DStorage::TYPE_HEIGHT) {
					float srcf = src.r;
					float destf = dest.r;

					switch (_operation) {
						case ADD:
							destf = srcf + (brush_alpha * opacity * 10.f);
							break;
						case SUBTRACT:
							destf = srcf - (brush_alpha * opacity * 10.f);
							break;
						case MULTIPLY:
							destf = srcf * (brush_alpha * opacity * .01f + 1.0f);
							break;
						case DIVIDE:
							destf = srcf * (-brush_alpha * opacity * .01f + 1.0f);
							break;
						case REPLACE:
							destf = Math::lerp(srcf, height, brush_alpha * opacity);
							break;
						case Terrain3DEditor::AVERAGE: {
							Vector3 left_position = brush_global_position - Vector3(1, 0, 0);
							Vector3 right_position = brush_global_position + Vector3(1, 0, 0);
							Vector3 down_position = brush_global_position - Vector3(0, 0, 1);
							Vector3 up_position = brush_global_position + Vector3(0, 0, 1);

							float left = srcf, right = srcf, up = srcf, down = srcf;

							left = storage->get_pixel(map_type, left_position).r;
							right = storage->get_pixel(map_type, right_position).r;
							up = storage->get_pixel(map_type, up_position).r;
							down = storage->get_pixel(map_type, down_position).r;

							float avg = (srcf + left + right + up + down) * 0.2;
							destf = Math::lerp(srcf, avg, brush_alpha * opacity);
							break;
						}
						default:
							break;
					}
					dest = Color(destf, 0.0f, 0.0f, 1.0f);
					storage->update_heights(destf);

				} else if (map_type == Terrain3DStorage::TYPE_CONTROL) {
					float alpha_clip = (brush_alpha < 0.1f) ? 0.0f : 1.0f;
					int index_base = int(src.r * 255.0f);
					int index_overlay = int(src.g * 255.0f);
					int dest_index = 0;

					switch (_operation) {
						case Terrain3DEditor::ADD:
							// Spray Overlay
							dest_index = int(Math::lerp(index_overlay, index, alpha_clip));
							if (dest_index == index_base) {
								dest.b = Math::lerp(src.b, 0.0f, alpha_clip * opacity * .5f);
							} else {
								dest.g = float(dest_index) / 255.0f;
								dest.b = Math::lerp(src.b, CLAMP(src.b + brush_alpha, 0.0f, 1.0f), brush_alpha * opacity * .5f);
							}
							break;
						case Terrain3DEditor::REPLACE:
							// Base Paint
							dest_index = int(Math::lerp(index_base, index, alpha_clip));
							dest.r = float(dest_index) / 255.0f;
							dest.b = Math::lerp(src.b, 0.0f, alpha_clip * opacity);
							break;
						default:
							break;
					}
				} else if (map_type == Terrain3DStorage::TYPE_COLOR) {
					switch (_tool) {
						case COLOR:
							dest = src.lerp(color, brush_alpha * opacity);
							dest.a = src.a;
							break;
						case ROUGHNESS:
							/* Roughness received from UI is -100 to 100. Changed to 0,1 before storing.
							 * To convert 0,1 back to -100,100 use: 200 * (color.a - 0.5)
							 * However Godot stores values as 8-bit ints. Roundtrip is = int(a*255)/255.0
							 * Roughness 0 is saved as 0.5, but retreived is 0.498, or -0.4 roughness
							 * We round the final amount in tool_settings.gd:_on_picked().
							 * Tip: One can round to 2 decimal places like so: 0.01*round(100.0*a)
							 */
							dest.a = Math::lerp(src.a, .5f + .5f * .01f * roughness, brush_alpha * opacity);
							break;
						default:
							break;
					}
				}

				map->set_pixelv(map_pixel_position, dest);
			}
		}
	}
	storage->force_update_maps(map_type);
}

bool Terrain3DEditor::_is_in_bounds(Vector2i p_position, Vector2i p_max_position) {
	bool more_than_min = p_position.x >= 0 && p_position.y >= 0;
	bool less_than_max = p_position.x < p_max_position.x && p_position.y < p_max_position.y;
	return more_than_min && less_than_max;
}

Vector2 Terrain3DEditor::_get_uv_position(Vector3 p_global_position, int p_region_size) {
	Vector2 global_position_2d = Vector2(p_global_position.x, p_global_position.z);
	Vector2 region_position = global_position_2d / float(p_region_size) + Vector2(0.5, 0.5);
	region_position = region_position.floor();
	Vector2 uv_position = ((global_position_2d / float(p_region_size)) + Vector2(0.5, 0.5)) - region_position;

	return uv_position;
}

Vector2 Terrain3DEditor::_rotate_uv(Vector2 p_uv, float p_angle) {
	Vector2 rotation_offset = Vector2(0.5, 0.5);
	p_uv = (p_uv - rotation_offset).rotated(p_angle) + rotation_offset;
	return p_uv.clamp(Vector2(0, 0), Vector2(1, 1));
}

///////////////////////////
// Public Functions
///////////////////////////

Terrain3DEditor::Terrain3DEditor() {
}

Terrain3DEditor::~Terrain3DEditor() {
}

void Terrain3DEditor::set_brush_data(Dictionary p_data) {
	if (p_data.is_empty()) {
		return;
	}
	_brush.set_data(p_data);
}

void Terrain3DEditor::operate(Vector3 p_global_position, float p_camera_direction, bool p_continuous_operation) {
	if (_operation_position == Vector3()) {
		_operation_position = p_global_position;
	}
	_operation_interval = p_global_position.distance_to(_operation_position);
	_operation_position = p_global_position;

	if (_tool == REGION && !p_continuous_operation) {
		_operate_region(p_global_position);
	} else if (_tool >= 0 && _tool < REGION && p_continuous_operation) {
		_operate_map(p_global_position, p_camera_direction);
	}
}

/* Stored in the _undo_set is:
 * 0-2: map 0,1,2
 * 3: Region offsets
 * 4: height range
 */
void Terrain3DEditor::setup_undo() {
	ERR_FAIL_COND_MSG(_terrain == nullptr, "terrain is null, returning");
	ERR_FAIL_COND_MSG(_terrain->get_plugin() == nullptr, "terrain->plugin is null, returning");
	if (_tool < 0 || _tool > REGION) {
		return;
	}
	LOG(INFO, "Setting up undo snapshot...");
	_undo_set.clear();
	_undo_set.resize(Terrain3DStorage::TYPE_MAX + 2);
	for (int i = 0; i < Terrain3DStorage::TYPE_MAX; i++) {
		_undo_set[i] = _terrain->get_storage()->get_maps_copy(static_cast<Terrain3DStorage::MapType>(i));
		LOG(DEBUG, "maps ", i, "(", static_cast<TypedArray<Image>>(_undo_set[i]).size(), "): ", _undo_set[i]);
	}
	_undo_set[Terrain3DStorage::TYPE_MAX] = _terrain->get_storage()->get_region_offsets().duplicate();
	LOG(DEBUG, "region_offsets(", static_cast<TypedArray<Vector2i>>(_undo_set[Terrain3DStorage::TYPE_MAX]).size(), "): ", _undo_set[Terrain3DStorage::TYPE_MAX]);
	_undo_set[Terrain3DStorage::TYPE_MAX + 1] = _terrain->get_storage()->get_height_range();
}

void Terrain3DEditor::store_undo() {
	ERR_FAIL_COND_MSG(_terrain == nullptr, "terrain is null, returning");
	ERR_FAIL_COND_MSG(_terrain->get_plugin() == nullptr, "terrain->plugin is null, returning");
	if (_tool < 0 || _tool > REGION) {
		return;
	}
	LOG(INFO, "Storing undo snapshot...");
	EditorUndoRedoManager *undo_redo = _terrain->get_plugin()->get_undo_redo();

	String action_name = String("Terrain3D ") + OPNAME[_operation] + String(" ") + TOOLNAME[_tool];
	LOG(DEBUG, "Creating undo action: '", action_name, "'");
	undo_redo->create_action(action_name);

	LOG(DEBUG, "Storing undo snapshot: ", _undo_set);
	undo_redo->add_undo_method(this, "apply_undo", _undo_set.duplicate()); // Must be duplicated

	LOG(DEBUG, "Setting up redo snapshot...");
	Array redo_set;
	redo_set.resize(Terrain3DStorage::TYPE_MAX + 2);
	for (int i = 0; i < Terrain3DStorage::TYPE_MAX; i++) {
		redo_set[i] = _terrain->get_storage()->get_maps_copy(static_cast<Terrain3DStorage::MapType>(i));
		LOG(DEBUG, "maps ", i, "(", static_cast<TypedArray<Image>>(redo_set[i]).size(), "): ", redo_set[i]);
	}
	redo_set[Terrain3DStorage::TYPE_MAX] = _terrain->get_storage()->get_region_offsets().duplicate();
	LOG(DEBUG, "region_offsets(", static_cast<TypedArray<Vector2i>>(redo_set[Terrain3DStorage::TYPE_MAX]).size(), "): ", redo_set[Terrain3DStorage::TYPE_MAX]);
	redo_set[Terrain3DStorage::TYPE_MAX + 1] = _terrain->get_storage()->get_height_range();

	LOG(DEBUG, "Storing redo snapshot: ", redo_set);
	undo_redo->add_do_method(this, "apply_undo", redo_set);

	LOG(DEBUG, "Committing undo action");
	undo_redo->commit_action(false);
}

void Terrain3DEditor::apply_undo(const Array &p_set) {
	ERR_FAIL_COND_MSG(_terrain == nullptr, "terrain is null, returning");
	ERR_FAIL_COND_MSG(_terrain->get_plugin() == nullptr, "terrain->plugin is null, returning");
	LOG(INFO, "Applying Undo/Redo set. Array size: ", p_set.size());
	LOG(DEBUG, "Apply undo received: ", p_set);

	for (int i = 0; i < Terrain3DStorage::TYPE_MAX; i++) {
		Terrain3DStorage::MapType map_type = static_cast<Terrain3DStorage::MapType>(i);
		_terrain->get_storage()->set_maps(map_type, p_set[i]);
	}
	_terrain->get_storage()->set_region_offsets(p_set[Terrain3DStorage::TYPE_MAX]);
	_terrain->get_storage()->set_height_range(p_set[Terrain3DStorage::TYPE_MAX + 1]);

	if (_terrain->get_plugin()->has_method("update_grid")) {
		LOG(DEBUG, "Calling GDScript update_grid()");
		_terrain->get_plugin()->call("update_grid");
	}
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DEditor::_bind_methods() {
	BIND_ENUM_CONSTANT(ADD);
	BIND_ENUM_CONSTANT(SUBTRACT);
	BIND_ENUM_CONSTANT(MULTIPLY);
	BIND_ENUM_CONSTANT(DIVIDE);
	BIND_ENUM_CONSTANT(REPLACE);
	BIND_ENUM_CONSTANT(AVERAGE);
	BIND_ENUM_CONSTANT(OP_MAX);

	BIND_ENUM_CONSTANT(HEIGHT);
	BIND_ENUM_CONSTANT(TEXTURE);
	BIND_ENUM_CONSTANT(COLOR);
	BIND_ENUM_CONSTANT(ROUGHNESS);
	BIND_ENUM_CONSTANT(REGION);
	BIND_ENUM_CONSTANT(TOOL_MAX);

	ClassDB::bind_method(D_METHOD("set_terrain", "terrain"), &Terrain3DEditor::set_terrain);
	ClassDB::bind_method(D_METHOD("get_terrain"), &Terrain3DEditor::get_terrain);

	ClassDB::bind_method(D_METHOD("set_brush_data", "data"), &Terrain3DEditor::set_brush_data);
	ClassDB::bind_method(D_METHOD("set_tool", "tool"), &Terrain3DEditor::set_tool);
	ClassDB::bind_method(D_METHOD("get_tool"), &Terrain3DEditor::get_tool);
	ClassDB::bind_method(D_METHOD("set_operation", "operation"), &Terrain3DEditor::set_operation);
	ClassDB::bind_method(D_METHOD("get_operation"), &Terrain3DEditor::get_operation);
	ClassDB::bind_method(D_METHOD("operate", "position", "camera_direction", "continuous_operation"), &Terrain3DEditor::operate);

	ClassDB::bind_method(D_METHOD("setup_undo"), &Terrain3DEditor::setup_undo);
	ClassDB::bind_method(D_METHOD("store_undo"), &Terrain3DEditor::store_undo);
	ClassDB::bind_method(D_METHOD("apply_undo", "maps"), &Terrain3DEditor::apply_undo);
}
