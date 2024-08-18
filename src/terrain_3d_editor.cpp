// Copyright © 2024 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/editor_undo_redo_manager.hpp>
#include <godot_cpp/classes/time.hpp>

#include "logger.h"
#include "terrain_3d_editor.h"
#include "terrain_3d_storage.h"
#include "terrain_3d_util.h"

///////////////////////////
// Private Functions
///////////////////////////

// Sends the whole region aabb to edited_area
void Terrain3DEditor::_send_region_aabb(const Vector2i &p_region_loc, const Vector2 &p_height_range) {
	Terrain3DStorage::RegionSize region_size = _terrain->get_storage()->get_region_size();
	AABB edited_area;
	edited_area.position = Vector3(p_region_loc.x * region_size, p_height_range.x, p_region_loc.y * region_size);
	edited_area.size = Vector3(region_size, p_height_range.y - p_height_range.x, region_size);
	edited_area.position *= _terrain->get_mesh_vertex_spacing();
	edited_area.size *= _terrain->get_mesh_vertex_spacing();
	_terrain->get_storage()->add_edited_area(edited_area);
}

void Terrain3DEditor::_operate_region(const Vector3 &p_global_position) {
	Vector2i region_loc = _terrain->get_storage()->get_region_location(p_global_position);
	bool has_region = _terrain->get_storage()->has_region(region_loc);
	bool changed = false;
	Vector2 height_range;

	if (_operation == ADD) {
		if (!has_region) {
			_terrain->get_storage()->add_region_blank(region_loc);
			_terrain->get_storage()->set_region_modified(region_loc, true);
			changed = true;
		}
	} else { // Remove region
		if (has_region) {
			Ref<Terrain3DRegion> region = _terrain->get_storage()->get_region(region_loc);
			height_range = region->get_height_range();
			_terrain->get_storage()->remove_region(region);
			changed = true;
		}
	}
	if (changed) {
		_modified = true;
		_send_region_aabb(region_loc, height_range);
	}
}

void Terrain3DEditor::_operate_map(const Vector3 &p_global_position, const real_t p_camera_direction) {
	LOG(DEBUG_CONT, "Operating at ", p_global_position, " tool type ", _tool, " op ", _operation);

	MapType map_type;
	switch (_tool) {
		case HEIGHT:
		case INSTANCER:
			map_type = TYPE_HEIGHT;
			break;
		case TEXTURE:
		case AUTOSHADER:
		case HOLES:
		case NAVIGATION:
		case ANGLE:
		case SCALE:
			map_type = TYPE_CONTROL;
			break;
		case COLOR:
		case ROUGHNESS:
			map_type = TYPE_COLOR;
			break;
		default:
			LOG(ERROR, "Invalid tool selected");
			return;
	}

	Terrain3DStorage *storage = _terrain->get_storage();
	int region_size = storage->get_region_size();
	Vector2i region_vsize = Vector2i(region_size, region_size);

	// If no region and not height, skip whole function. Checked again later
	if (!storage->has_regionp(p_global_position) && (!_brush_data["auto_regions"] || _tool != HEIGHT)) {
		return;
	}

	Ref<Image> brush_image = _brush_data["brush_image"];
	if (brush_image.is_null()) {
		LOG(ERROR, "Invalid brush image. Returning");
		return;
	}
	Vector2i img_size = _brush_data["brush_image_size"];
	real_t brush_size = _brush_data["size"];

	// Typicall we multiply mouse pressure & strength setting, but
	// * Mouse movement w/ button down has a pressure of 1
	// * Mouse clicks always have pressure of 0
	// * Pen movement pressure varies, sometimes lifting or clicking has a pressure of 0
	// If we're operating with a pressure of 0.001-.999 it's a pen
	// So if there's a 0 pressure operation >100ms after a pen operation, we assume it's
	// a mouse click. This occasionally catches a pen click, but avoids most pen lifts.
	real_t mouse_pressure = CLAMP(real_t(_brush_data.get("mouse_pressure", 0.f)), 0.f, 1.f);
	if (mouse_pressure > CMP_EPSILON && mouse_pressure < 1.f) {
		_last_pen_tick = Time::get_singleton()->get_ticks_msec();
	}
	uint64_t ticks = Time::get_singleton()->get_ticks_msec();
	if (mouse_pressure < CMP_EPSILON && ticks - _last_pen_tick >= 100) {
		mouse_pressure = 1.f;
	}
	real_t strength = mouse_pressure * (real_t)_brush_data["strength"];

	real_t height = _brush_data["height"];
	Color color = _brush_data["color"];
	real_t roughness = _brush_data["roughness"];

	bool enable_texture = _brush_data["enable_texture"];
	int asset_id = _brush_data["asset_id"];

	bool enable_angle = _brush_data["enable_angle"];
	bool dynamic_angle = _brush_data["dynamic_angle"];
	real_t angle = _brush_data["angle"];

	bool enable_scale = _brush_data["enable_scale"];
	real_t scale = _brush_data["scale"];

	real_t gamma = _brush_data["gamma"];
	PackedVector3Array gradient_points = _brush_data["gradient_points"];
	bool lift_flatten = _brush_data["lift_flatten"];

	real_t randf = UtilityFunctions::randf();
	real_t rot = randf * Math_PI * real_t(_brush_data["jitter"]);
	if (_brush_data["align_to_view"]) {
		rot += p_camera_direction;
	}
	// Rotate the decal to align with the brush
	cast_to<Node>(_terrain->get_plugin()->get("ui"))->call("set_decal_rotation", rot);

	AABB edited_area;
	edited_area.position = p_global_position - Vector3(brush_size, 0.f, brush_size) * .5f;
	edited_area.size = Vector3(brush_size, 0.f, brush_size);

	if (_tool == INSTANCER) {
		if (_operation == ADD) {
			_terrain->get_instancer()->add_instances(p_global_position, _brush_data);
		} else {
			_terrain->get_instancer()->remove_instances(p_global_position, _brush_data);
		}
		_modified = true;
		return;
	}

	// MAP Operations
	real_t vertex_spacing = _terrain->get_mesh_vertex_spacing();
	for (real_t x = 0.f; x < brush_size; x += vertex_spacing) {
		for (real_t y = 0.f; y < brush_size; y += vertex_spacing) {
			Vector2 brush_offset = Vector2(x, y) - (Vector2(brush_size, brush_size) / 2.f);
			Vector3 brush_global_position =
					Vector3(p_global_position.x + brush_offset.x + .5f, p_global_position.y,
							p_global_position.z + brush_offset.y + .5f);

			// Get region for current brush pixel global position
			Vector2i region_loc = storage->get_region_location(brush_global_position);
			Ref<Terrain3DRegion> region = storage->get_region(region_loc);
			// If no region, create one
			if (region.is_null()) {
				// Except if outside of regions and we can't add one
				if (!_brush_data["auto_regions"] || _tool != HEIGHT) {
					continue;
				}
				region = storage->add_region_blank(region_loc);
				if (region.is_null()) {
					// A new region can't be made
					continue;
				}
				_modified = true;
				_send_region_aabb(region_loc);
			}

			// Get map for this region and tool
			Ref<Image> map = region->get_map(map_type);

			// Identify position on map image
			Vector2 uv_position = _get_uv_position(brush_global_position, region_size, vertex_spacing);
			Vector2i map_pixel_position = Vector2i(uv_position * region_size);

			if (_is_in_bounds(map_pixel_position, region_vsize)) {
				Vector2 brush_uv = Vector2(x, y) / brush_size;
				Vector2i brush_pixel_position = Vector2i(_get_rotated_uv(brush_uv, rot) * img_size);

				if (!_is_in_bounds(brush_pixel_position, img_size)) {
					continue;
				}

				Vector3 edited_position = brush_global_position;
				edited_position.y = storage->get_height(edited_position);
				edited_area = edited_area.expand(edited_position);

				// Start brushing on the map
				real_t brush_alpha = brush_image->get_pixelv(brush_pixel_position).r;
				brush_alpha = real_t(Math::pow(double(brush_alpha), double(gamma)));
				Color src = map->get_pixelv(map_pixel_position);
				Color dest = src;

				if (map_type == TYPE_HEIGHT) {
					real_t srcf = src.r;
					real_t destf = dest.r;

					switch (_operation) {
						case ADD: {
							if (lift_flatten && !std::isnan(p_global_position.y)) {
								real_t brush_center_y = p_global_position.y + brush_alpha * strength;
								destf = Math::clamp(brush_center_y, srcf, srcf + brush_alpha * strength);
							} else {
								destf = srcf + (brush_alpha * strength);
							}
							break;
						}
						case SUBTRACT: {
							if (lift_flatten && !std::isnan(p_global_position.y)) {
								real_t brush_center_y = p_global_position.y - brush_alpha * strength;
								destf = Math::clamp(brush_center_y, srcf - brush_alpha * strength, srcf);
							} else {
								destf = srcf - (brush_alpha * strength);
							}
							break;
						}
						case REPLACE: {
							destf = Math::lerp(srcf, height, brush_alpha * strength * .5f);
							break;
						}
						case AVERAGE: {
							Vector3 left_position = brush_global_position - Vector3(vertex_spacing, 0.f, 0.f);
							Vector3 right_position = brush_global_position + Vector3(vertex_spacing, 0.f, 0.f);
							Vector3 down_position = brush_global_position - Vector3(0.f, 0.f, vertex_spacing);
							Vector3 up_position = brush_global_position + Vector3(0.f, 0.f, vertex_spacing);
							real_t left = storage->get_pixel(map_type, left_position).r;
							if (std::isnan(left)) {
								left = 0.f;
							}
							real_t right = storage->get_pixel(map_type, right_position).r;
							if (std::isnan(right)) {
								right = 0.f;
							}
							real_t up = storage->get_pixel(map_type, up_position).r;
							if (std::isnan(up)) {
								up = 0.f;
							}
							real_t down = storage->get_pixel(map_type, down_position).r;
							if (std::isnan(down)) {
								down = 0.f;
							}
							real_t avg = (srcf + left + right + up + down) * 0.2f;
							destf = Math::lerp(srcf, avg, CLAMP(brush_alpha * strength * 2.f, .02f, 1.f));
							break;
						}
						case GRADIENT: {
							if (gradient_points.size() == 2) {
								Vector3 point_1 = gradient_points[0];
								Vector3 point_2 = gradient_points[1];

								Vector2 point_1_xz = Vector2(point_1.x, point_1.z);
								Vector2 point_2_xz = Vector2(point_2.x, point_2.z);
								Vector2 brush_xz = Vector2(brush_global_position.x, brush_global_position.z);

								if (_operation_movement.length_squared() > 0.f) {
									// Ramp up/down only in the direction of movement, to avoid giving winding
									// paths one edge higher than the other.
									Vector2 movement_xz = Vector2(_operation_movement.x, _operation_movement.z).normalized();
									Vector2 offset = movement_xz * Vector2(brush_offset).dot(movement_xz);
									brush_xz = Vector2(p_global_position.x + offset.x, p_global_position.z + offset.y);
								}

								Vector2 dir = point_2_xz - point_1_xz;
								real_t weight = dir.normalized().dot(brush_xz - point_1_xz) / dir.length();
								weight = Math::clamp(weight, (real_t)0.0f, (real_t)1.0f);
								real_t height = Math::lerp(point_1.y, point_2.y, weight);

								destf = Math::lerp(srcf, height, brush_alpha * strength * .5f);
							}
							break;
						}
						default:
							break;
					}
					dest = Color(destf, 0.f, 0.f, 1.f);
					region->update_height(destf);
					// TODO Move this line to a signal sent from above line
					storage->update_master_height(destf);

					edited_position.y = destf;
					edited_area = edited_area.expand(edited_position);

				} else if (map_type == TYPE_CONTROL) {
					// Get bit field from pixel
					uint32_t base_id = get_base(src.r);
					uint32_t overlay_id = get_overlay(src.r);
					real_t blend = real_t(get_blend(src.r)) / 255.f;
					uint32_t uvrotation = get_uv_rotation(src.r);
					uint32_t uvscale = get_uv_scale(src.r);
					bool hole = is_hole(src.r);
					bool navigation = is_nav(src.r);
					bool autoshader = is_auto(src.r);

					real_t alpha_clip = (brush_alpha > 0.1f) ? 1.f : 0.f;
					uint32_t dest_id = uint32_t(Math::lerp(base_id, asset_id, alpha_clip));
					// Lookup to shift values saved to control map so that 0 (default) is the first entry
					// Shader scale array is aligned to match this.
					std::array<uint32_t, 8> scale_align = { 5, 6, 7, 0, 1, 2, 3, 4 };

					switch (_tool) {
						case TEXTURE:
							switch (_operation) {
								// Base Paint
								case REPLACE: {
									if (brush_alpha > 0.1f) {
										if (enable_texture) {
											// Set base texture
											base_id = dest_id;
											// Erase blend value
											blend = Math::lerp(blend, real_t(0.f), alpha_clip);
											autoshader = false;
										}
										// Set angle & scale
										if (enable_angle) {
											if (dynamic_angle) {
												// Angle from mouse movement.
												angle = Vector2(-_operation_movement.x, _operation_movement.z).angle();
												// Avoid negative, align texture "up" with mouse direction.
												angle = real_t(Math::fmod(Math::rad_to_deg(angle) + 450.f, 360.f));
											}
											// Convert from degrees to 0 - 15 value range
											uvrotation = uint32_t(CLAMP(Math::round(angle / 22.5f), 0.f, 15.f));
										}
										if (enable_scale) {
											// Offset negative and convert from percentage to 0 - 7 bit value range
											// Maintain 0 = 0, remap negatives to end.
											uvscale = scale_align[uint8_t(CLAMP(Math::round((scale + 60.f) / 20.f), 0.f, 7.f))];
										}
									}
									break;
								}

								// Overlay Spray
								case ADD: {
									real_t spray_strength = CLAMP(strength * 0.05f, 0.003f, .25f);
									real_t brush_value = CLAMP(brush_alpha * spray_strength, 0.f, 1.f);
									if (enable_texture) {
										// If overlay and base texture are the same, reduce blend value
										if (dest_id == base_id) {
											blend = CLAMP(blend - brush_value, 0.f, 1.f);
										} else {
											// Else overlay and base are separate, set overlay texture and increase blend value
											overlay_id = dest_id;
											blend = CLAMP(blend + brush_value, 0.f, 1.f);
										}
										autoshader = false;
									}
									if (brush_alpha * strength * 11.f > 0.1f) {
										// Set angle & scale
										if (enable_angle) {
											if (dynamic_angle) {
												// Angle from mouse movement.
												angle = Vector2(-_operation_movement.x, _operation_movement.z).angle();
												// Avoid negative, align texture "up" with mouse direction.
												angle = real_t(Math::fmod(Math::rad_to_deg(angle) + 450.f, 360.f));
											}
											// Convert from degrees to 0 - 15 value range
											uvrotation = uint32_t(CLAMP(Math::round(angle / 22.5f), 0.f, 15.f));
										}
										if (enable_scale) {
											// Offset negative and convert from percentage to 0 - 7 bit value range
											// Maintain 0 = 0, remap negatives to end.
											uvscale = scale_align[uint8_t(CLAMP(Math::round((scale + 60.f) / 20.f), 0.f, 7.f))];
										}
									}
									break;
								}

								default: {
									break;
								}
							}
							break;
						case AUTOSHADER: {
							if (brush_alpha > 0.1f) {
								autoshader = (_operation == ADD);
							}
							break;
						}
						case HOLES: {
							if (brush_alpha > 0.1f) {
								hole = (_operation == ADD);
							}
							break;
						}
						case NAVIGATION: {
							if (brush_alpha > 0.1f) {
								navigation = (_operation == ADD);
							}
							break;
						}
						default: {
							break;
						}
					}

					// Convert back to bitfield
					uint32_t blend_int = uint32_t(CLAMP(Math::round(blend * 255.f), 0.f, 255.f));
					uint32_t bits = enc_base(base_id) | enc_overlay(overlay_id) |
							enc_blend(blend_int) | enc_uv_rotation(uvrotation) |
							enc_uv_scale(uvscale) | enc_hole(hole) |
							enc_nav(navigation) | enc_auto(autoshader);

					// Write back to pixel in FORMAT_RF. Must be a 32-bit float
					dest = Color(as_float(bits), 0.f, 0.f, 1.f);

				} else if (map_type == TYPE_COLOR) {
					switch (_tool) {
						case COLOR:
							dest = src.lerp((_operation == ADD) ? color : COLOR_WHITE, brush_alpha * strength);
							dest.a = src.a;
							break;
						case ROUGHNESS:
							/* Roughness received from UI is -100 to 100. Changed to 0,1 before storing.
							 * To convert 0,1 back to -100,100 use: 200 * (color.a - 0.5)
							 * However Godot stores values as 8-bit ints. Roundtrip is = int(a*255)/255.0
							 * Roughness 0 is saved as 0.5, but retreived is 0.498, or -0.4 roughness
							 * We round the final amount in tool_settings.gd:_on_picked().
							 */
							if (_operation == ADD) {
								dest.a = Math::lerp(real_t(src.a), real_t(.5f + .5f * roughness), brush_alpha * strength);
							} else {
								dest.a = Math::lerp(real_t(src.a), real_t(.5f + .5f * 0.5f), brush_alpha * strength);
							}
							break;
						default:
							break;
					}
				}
				map->set_pixelv(map_pixel_position, dest);
				_modified = true;
				region->set_modified(true);
			}
		}
	}
	storage->force_update_maps(map_type);
	storage->add_edited_area(edited_area);
}

Dictionary Terrain3DEditor::_get_undo_data() const {
	Dictionary data;
	return data; // ignore undo for now
	if (_tool < 0 || _tool >= TOOL_MAX) {
		return data;
	}

	TypedArray<int> e_regions;
	Array regions = _terrain->get_storage()->get_regions().values();
	for (int i = 0; i < regions.size(); i++) {
		bool is_modified = static_cast<Ref<Terrain3DRegion>>(regions[i])->is_modified();
		if (is_modified) {
			e_regions.push_back(i);
		}
	}

	//= _terrain->get_storage()->get_regions_under_aabb(_terrain->get_storage()->get_edited_area());
	data["edited_regions"] = e_regions;
	LOG(DEBUG, "E Regions ", data["edited_regions"]);
	switch (_tool) {
		case REGION:
			LOG(DEBUG, "Storing region locations");
			data["is_add"] = _operation == ADD;
			if (_operation == SUBTRACT) {
				data["region_locations"] = _terrain->get_storage()->get_region_locations().duplicate();
				data["height_map"] = _terrain->get_storage()->get_maps_copy(TYPE_HEIGHT, e_regions);
				data["control_map"] = _terrain->get_storage()->get_maps_copy(TYPE_CONTROL, e_regions);
				data["color_map"] = _terrain->get_storage()->get_maps_copy(TYPE_COLOR, e_regions);
				data["height_range"] = _terrain->get_storage()->get_height_range();
				data["edited_area"] = _terrain->get_storage()->get_edited_area();
			}
			break;

		case HEIGHT:
			LOG(DEBUG, "Storing height maps and range");
			data["region_locations"] = _terrain->get_storage()->get_region_locations().duplicate();
			data["height_map"] = _terrain->get_storage()->get_maps_copy(TYPE_HEIGHT, e_regions);
			data["height_range"] = _terrain->get_storage()->get_height_range();
			data["edited_area"] = _terrain->get_storage()->get_edited_area();
			break;

		case HOLES:
			// Holes can remove instances
			//data["multimeshes"] = _terrain->get_storage()->get_multimeshes().duplicate(true);
			LOG(DEBUG, "Storing Multimesh: ", data["multimeshes"]);
		case TEXTURE:
		case AUTOSHADER:
		case NAVIGATION:
			LOG(DEBUG, "Storing control maps");
			data["control_map"] = _terrain->get_storage()->get_maps_copy(TYPE_CONTROL, e_regions);
			break;

		case COLOR:
		case ROUGHNESS:
			LOG(DEBUG, "Storing color maps");
			data["color_map"] = _terrain->get_storage()->get_maps_copy(TYPE_COLOR, e_regions);
			break;

		case INSTANCER:
			//data["multimeshes"] = _terrain->get_storage()->get_multimeshes().duplicate(true);
			LOG(DEBUG, "Storing Multimesh: ", data["multimeshes"]);
			break;

		default:
			return data;
	}
	return data;
}

void Terrain3DEditor::_store_undo() {
	IS_INIT_COND_MESG(_terrain->get_plugin() == nullptr, "_terrain isn't initialized, returning", VOID);
	if (_tool < 0 || _tool >= TOOL_MAX) {
		return;
	}
	LOG(INFO, "Storing undo snapshot...");
	EditorUndoRedoManager *undo_redo = _terrain->get_plugin()->get_undo_redo();

	String action_name = String("Terrain3D ") + OPNAME[_operation] + String(" ") + TOOLNAME[_tool];
	LOG(DEBUG, "Creating undo action: '", action_name, "'");
	undo_redo->create_action(action_name);

	if (_undo_data.has("edited_area")) {
		_undo_data["edited_area"] = _terrain->get_storage()->get_edited_area();
		LOG(DEBUG, "Updating undo snapshot edited area: ", _undo_data["edited_area"]);
	}

	LOG(DEBUG, "Storing undo snapshot: ", _undo_data);
	undo_redo->add_undo_method(this, "apply_undo", _undo_data.duplicate());

	LOG(DEBUG, "Setting up redo snapshot...");
	Dictionary redo_set = _get_undo_data();

	LOG(DEBUG, "Storing redo snapshot: ", redo_set);
	undo_redo->add_do_method(this, "apply_undo", redo_set);

	LOG(DEBUG, "Committing undo action");
	undo_redo->commit_action(false);
}

void Terrain3DEditor::_apply_undo(const Dictionary &p_set) {
	IS_INIT_COND_MESG(_terrain->get_plugin() == nullptr, "_terrain isn't initialized, returning", VOID);
	LOG(INFO, "Applying Undo/Redo set. Array size: ", p_set.size());
	LOG(DEBUG, "Apply undo received: ", p_set);

	TypedArray<int> e_regions = p_set["edited_regions"];

	if (p_set.has("is_add")) {
		// FIXME: This block assumes a lot about the structure of the dictionary and the number of elements
		bool is_add = p_set["is_add"];
		if (is_add) {
			// Remove
			LOG(DEBUG, "Removing region...");

			TypedArray<int> current;
			Array regions = _terrain->get_storage()->get_regions().values();
			for (int i = 0; i < regions.size(); i++) {
				bool is_modified = static_cast<Ref<Terrain3DRegion>>(regions[i])->is_modified();
				if (is_modified) {
					current.push_back(i);
				}
			}

			TypedArray<int> diff;

			for (int i = 0; i < current.size(); i++) {
				if (!regions.has(current[i])) {
					diff.push_back(current[i]);
				}
			}

			for (int i = 0; i < diff.size(); i++) {
				_terrain->get_storage()->remove_region(diff[i]);
			}
		} else {
			// Add region
			TypedArray<int> current;
			Array regions = _terrain->get_storage()->get_regions().values();
			for (int i = 0; i < regions.size(); i++) {
				bool is_modified = static_cast<Ref<Terrain3DRegion>>(regions[i])->is_modified();
				if (is_modified) {
					current.push_back(i);
				}
			}

			TypedArray<int> diff;

			for (int i = 0; i < current.size(); i++) {
				if (!regions.has(current[i])) {
					diff.push_back(current[i]);
				}
			}

			LOG(DEBUG, "Re-adding regions...");
			for (int i = 0; i < diff.size(); i++) {
				Vector2i new_region = ((TypedArray<Vector2i>)p_set["region_locations"])[regions[0]];
				int size = _terrain->get_storage()->get_region_size();
				Vector3 new_region_position = Vector3(new_region.x * size, 0, new_region.y * size);

				TypedArray<Image> map_info = TypedArray<Image>();
				map_info.resize(3);
				map_info[TYPE_HEIGHT] = ((TypedArray<Image>)p_set["height_map"])[0];
				map_info[TYPE_CONTROL] = ((TypedArray<Image>)p_set["control_map"])[0];
				map_info[TYPE_COLOR] = ((TypedArray<Image>)p_set["color_map"])[0];
				Ref<Terrain3DRegion> region;
				region.instantiate();
				region->set_maps(map_info);
				_terrain->get_storage()->add_region(region);
			}
		}
	} else {
		Array keys = p_set.keys();
		for (int i = 0; i < keys.size(); i++) {
			String key = keys[i];
			if (key == "region_locations") {
				_terrain->get_storage()->set_region_locations(p_set[key]);
			} else if (key == "height_map") {
				//_terrain->get_storage()->set_maps(TYPE_HEIGHT, p_set[key], e_regions);
			} else if (key == "control_map") {
				//_terrain->get_storage()->set_maps(TYPE_CONTROL, p_set[key], e_regions);
			} else if (key == "color_map") {
				//_terrain->get_storage()->set_maps(TYPE_COLOR, p_set[key], e_regions);
			} else if (key == "height_range") {
				//_terrain->get_storage()->set_height_range(p_set[key]);
			} else if (key == "edited_area") {
				_terrain->get_storage()->clear_edited_area();
				_terrain->get_storage()->add_edited_area(p_set[key]);
			} else if (key == "multimeshes") {
				//_terrain->get_storage()->set_multimeshes(p_set[key], e_regions);
			}
		}
	}

	/* Rework all of undo
	_terrain->get_storage()->set_all_regions_modified(false);
	// Roll back to previous modified state
	for (int i = 0; i < e_regions.size(); i++) {
		_terrain->get_storage()->set_modified(i);
	}*/

	if (_terrain->get_plugin()->has_method("update_grid")) {
		LOG(DEBUG, "Calling GDScript update_grid()");
		_terrain->get_plugin()->call("update_grid");
	}
	_pending_undo = false;
	_modified = false;
}

///////////////////////////
// Public Functions
///////////////////////////

// Santize and set incoming brush data w/ defaults and clamps
// Only santizes data needed for the editor, other parameters (eg instancer) untouched here
void Terrain3DEditor::set_brush_data(const Dictionary &p_data) {
	_brush_data = p_data; // Same instance. Anything could be inserted after this, eg mouse_pressure

	// Sanitize image and textures
	Array brush_images = p_data["brush"];
	bool error = false;
	if (brush_images.size() == 2) {
		Ref<Image> img = brush_images[0];
		if (img.is_valid() && !img->is_empty()) {
			_brush_data["brush_image"] = img;
			_brush_data["brush_image_size"] = img->get_size();
		} else {
			LOG(ERROR, "Brush data doesn't contain a valid image");
		}
		Ref<Texture2D> tex = brush_images[1];
		if (tex.is_valid() && tex->get_width() > 0 && tex->get_height() > 0) {
			_brush_data["brush_texture"] = tex;
		} else {
			LOG(ERROR, "Brush data doesn't contain a valid texture");
		}
	} else {
		LOG(ERROR, "Brush data doesn't contain an image and texture");
	}

	// Santize settings
	_brush_data["size"] = CLAMP(real_t(p_data.get("size", 10.f)), 2.f, 4096.f); // Diameter in meters
	_brush_data["strength"] = CLAMP(real_t(p_data.get("strength", .1f)) * .01f, .01f, 1000.f); // 1-100k% (max of 1000m per click)
	// mouse_pressure injected in editor.gd and sanitized in _operate_map()
	_brush_data["height"] = CLAMP(real_t(p_data.get("height", 0.f)), -65536.f, 65536.f); // Meters
	Color col = p_data.get("color", COLOR_ROUGHNESS);
	col.r = CLAMP(col.r, 0.f, 5.f);
	col.g = CLAMP(col.g, 0.f, 5.f);
	col.b = CLAMP(col.b, 0.f, 5.f);
	col.a = CLAMP(col.a, 0.f, 1.f);
	_brush_data["color"] = col;
	_brush_data["roughness"] = CLAMP(real_t(p_data.get("roughness", 0.f)), -100.f, 100.f) * .01f; // Percentage

	_brush_data["enable_texture"] = p_data.get("enable_texture", true);
	_brush_data["asset_id"] = CLAMP(int(p_data.get("asset_id", 0)), 0, ((_tool == INSTANCER) ? Terrain3DAssets::MAX_MESHES : Terrain3DAssets::MAX_TEXTURES) - 1);

	_brush_data["enable_angle"] = p_data.get("enable_angle", true);
	_brush_data["dynamic_angle"] = p_data.get("dynamic_angle", false);
	_brush_data["angle"] = CLAMP(real_t(p_data.get("angle", 0.f)), 0.f, 337.5f);

	_brush_data["enable_scale"] = p_data.get("enable_scale", true);
	_brush_data["scale"] = CLAMP(real_t(p_data.get("scale", 0.f)), -60.f, 80.f);

	_brush_data["auto_regions"] = bool(p_data.get("auto_regions", true));
	_brush_data["align_to_view"] = bool(p_data.get("align_to_view", true));
	_brush_data["gamma"] = CLAMP(real_t(p_data.get("gamma", 1.f)), 0.1f, 2.f);
	_brush_data["jitter"] = CLAMP(real_t(p_data.get("jitter", 0.f)), 0.f, 1.f);
	_brush_data["gradient_points"] = p_data.get("gradient_points", PackedVector3Array());

	Util::print_dict("set_brush_data() Santized brush data:", _brush_data, DEBUG_CONT);
}

void Terrain3DEditor::set_tool(const Tool p_tool) {
	_tool = CLAMP(p_tool, Tool(0), TOOL_MAX);
	if (_terrain) {
		_terrain->get_material()->update();
	}
}

// Called on mouse click
void Terrain3DEditor::start_operation(const Vector3 &p_global_position) {
	IS_STORAGE_INIT_MESG("Terrain isn't initialized", VOID);
	LOG(INFO, "Setting up undo snapshot...");
	_undo_data.clear();
	_undo_data = _get_undo_data();
	_pending_undo = true;
	_modified = false; // Undo created, but don't save unless terrain modified
	// Reset counter at start to ensure first click places an instance
	_terrain->get_instancer()->reset_instance_counter();
	_terrain->get_storage()->clear_edited_area();
	_operation_position = p_global_position;
	_operation_movement = Vector3();
	if (_tool == REGION) {
		_operate_region(p_global_position);
	}
}

// Called on mouse movement with left mouse button down
void Terrain3DEditor::operate(const Vector3 &p_global_position, const real_t p_camera_direction) {
	IS_STORAGE_INIT_MESG("Terrain isn't initialized", VOID);
	if (!_pending_undo) {
		return;
	}
	_operation_movement = p_global_position - _operation_position;
	_operation_position = p_global_position;

	// Convolve the last 8 movement events, we dont clear on mouse release
	// so as to make repeated mouse strokes in the same direction consistent
	_operation_movement_history.push_back(_operation_movement);
	if (_operation_movement_history.size() > 8) {
		_operation_movement_history.pop_front();
	}
	// size -1, dont add the last appended entry
	for (int i = 0; i < _operation_movement_history.size() - 1; i++) {
		_operation_movement += _operation_movement_history[i];
	}
	_operation_movement *= 0.125; // 1/8th

	if (_tool == REGION) {
		_operate_region(p_global_position);
	} else if (_tool >= 0 && _tool < TOOL_MAX) {
		_operate_map(p_global_position, p_camera_direction);
	}
}

// Called on left mouse button released
void Terrain3DEditor::stop_operation() {
	IS_STORAGE_INIT_MESG("Terrain isn't initialized", VOID);
	// If undo was created and terrain actually modified, store it
	if (_pending_undo && _modified) {
		_store_undo();
		_pending_undo = false;
		_modified = false;
		_terrain->get_storage()->clear_edited_area();
	}
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DEditor::_bind_methods() {
	BIND_ENUM_CONSTANT(ADD);
	BIND_ENUM_CONSTANT(SUBTRACT);
	BIND_ENUM_CONSTANT(REPLACE);
	BIND_ENUM_CONSTANT(AVERAGE);
	BIND_ENUM_CONSTANT(GRADIENT);
	BIND_ENUM_CONSTANT(OP_MAX);

	BIND_ENUM_CONSTANT(HEIGHT);
	BIND_ENUM_CONSTANT(TEXTURE);
	BIND_ENUM_CONSTANT(COLOR);
	BIND_ENUM_CONSTANT(ROUGHNESS);
	BIND_ENUM_CONSTANT(ANGLE);
	BIND_ENUM_CONSTANT(SCALE);
	BIND_ENUM_CONSTANT(AUTOSHADER);
	BIND_ENUM_CONSTANT(HOLES);
	BIND_ENUM_CONSTANT(NAVIGATION);
	BIND_ENUM_CONSTANT(INSTANCER);
	BIND_ENUM_CONSTANT(REGION);
	BIND_ENUM_CONSTANT(TOOL_MAX);

	ClassDB::bind_method(D_METHOD("set_terrain", "terrain"), &Terrain3DEditor::set_terrain);
	ClassDB::bind_method(D_METHOD("get_terrain"), &Terrain3DEditor::get_terrain);

	ClassDB::bind_method(D_METHOD("set_brush_data", "data"), &Terrain3DEditor::set_brush_data);
	ClassDB::bind_method(D_METHOD("set_tool", "tool"), &Terrain3DEditor::set_tool);
	ClassDB::bind_method(D_METHOD("get_tool"), &Terrain3DEditor::get_tool);
	ClassDB::bind_method(D_METHOD("set_operation", "operation"), &Terrain3DEditor::set_operation);
	ClassDB::bind_method(D_METHOD("get_operation"), &Terrain3DEditor::get_operation);
	ClassDB::bind_method(D_METHOD("start_operation", "position"), &Terrain3DEditor::start_operation);
	ClassDB::bind_method(D_METHOD("operate", "position", "camera_direction"), &Terrain3DEditor::operate);
	ClassDB::bind_method(D_METHOD("stop_operation"), &Terrain3DEditor::stop_operation);
	ClassDB::bind_method(D_METHOD("is_operating"), &Terrain3DEditor::is_operating);

	ClassDB::bind_method(D_METHOD("apply_undo", "maps"), &Terrain3DEditor::_apply_undo);
}
