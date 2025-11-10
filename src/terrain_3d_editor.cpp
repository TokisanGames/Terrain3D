// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <climits>
#include <cstring>
#include <unordered_map>

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/variant/callable.hpp>

#include "constants.h"
#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_data.h"
#include "terrain_3d_editor.h"
#include "terrain_3d_layer.h"
#include "terrain_3d_util.h"

///////////////////////////
// Private Functions
///////////////////////////

// Sends the whole region aabb to edited_area
void Terrain3DEditor::_send_region_aabb(const Vector2i &p_region_loc, const Vector2 &p_height_range) {
	Terrain3D::RegionSize region_size = _terrain->get_region_size();
	AABB edited_area;
	edited_area.position = Vector3(p_region_loc.x * region_size, p_height_range.x, p_region_loc.y * region_size);
	edited_area.size = Vector3(region_size, p_height_range.y - p_height_range.x, region_size);
	edited_area.position *= _terrain->get_vertex_spacing();
	edited_area.size *= _terrain->get_vertex_spacing();
	_terrain->get_data()->add_edited_area(edited_area);
}

// Process location to add new region, mark as deleted, or just retrieve
Ref<Terrain3DRegion> Terrain3DEditor::_operate_region(const Vector2i &p_region_loc) {
	bool changed = false;
	Vector2 height_range;
	Terrain3DData *data = _terrain->get_data();

	// Check if in bounds, limiting errors
	bool can_print = false;
	uint64_t ticks = Time::get_singleton()->get_ticks_msec();
	if (ticks - _last_region_bounds_error > 1000) {
		_last_region_bounds_error = ticks;
		can_print = true;
	}
	if (data->get_region_map_index(p_region_loc) < 0) {
		if (can_print) {
			LOG(INFO, "Location ", p_region_loc, " out of bounds. Max: ",
					-Terrain3DData::REGION_MAP_SIZE / 2, " to ", Terrain3DData::REGION_MAP_SIZE / 2 - 1);
		}
		return Ref<Terrain3DRegion>();
	}

	// Get Region & dump data if debug
	Ref<Terrain3DRegion> region = data->get_region(p_region_loc);
	if (can_print) {
		LOG(DEBUG, "Tool: ", _tool, " Op: ", _operation, " processing region ", p_region_loc, ": ", ptr_to_str(*region));
	}

	// Create new region if location is null or deleted
	if (region.is_null() || (region.is_valid() && region->is_deleted())) {
		// And tool is Add Region, or Height + auto_regions
		if ((_tool == REGION && _operation == ADD) || ((_tool == SCULPT || _tool == HEIGHT) && _brush_data["auto_regions"])) {
			LOG(DEBUG, "Adding blank region at: ", p_region_loc, ", ptr: ", ptr_to_str(*region));
			region = data->add_region_blank(p_region_loc);
			if (region.is_null()) {
				LOG(ERROR, "A new region cannot be created");
				return region;
			}
			_edited_regions.push_back(region); // Ensure new region is added to the redo set
			changed = true;
		}
	}

	// If removing region
	else if (region.is_valid() && _tool == REGION && _operation == SUBTRACT) {
		LOG(DEBUG, "Removing region at: ", p_region_loc, ", ptr: ", ptr_to_str(*region));
		_original_regions.push_back(region);
		height_range = region->get_height_range();
		_terrain->get_data()->remove_region(region);
		changed = true;
	}

	if (changed) {
		_added_removed_locations.push_back(p_region_loc);
		region->set_modified(true);
		_send_region_aabb(p_region_loc, height_range);
	}
	return region;
}

void Terrain3DEditor::_operate_map(const Vector3 &p_global_position, const real_t p_camera_direction) {
	LOG(EXTREME, "Operating at ", p_global_position, " tool type ", _tool, " op ", _operation);

	MapType map_type = _get_map_type();
	if (map_type == TYPE_MAX) {
		LOG(ERROR, "Invalid tool selected");
		return;
	}
	bool accumulate_layers = _stamp_to_layer && map_type == TYPE_HEIGHT && (_operation == ADD || _operation == SUBTRACT);
	if (_stamp_to_layer && !accumulate_layers) {
		if (map_type != TYPE_HEIGHT) {
			LOG(WARN, "Stamp-to-layer currently supports height operations only; falling back to direct painting");
		}
		if (_operation != ADD && _operation != SUBTRACT) {
			LOG(WARN, "Stamp-to-layer currently supports Add/Subtract operations only; falling back to direct painting");
		}
		accumulate_layers = false;
	}
	if (_active_layer_index < 0) {
		accumulate_layers = false;
	}
	if (accumulate_layers && _layer_stamp_map_type == TYPE_MAX) {
		_layer_stamp_map_type = map_type;
	}

	int region_size = _terrain->get_region_size();
	Vector2i region_vsize = V2I(region_size);

	// If no region and can't add one, skip whole function. Checked again later
	Terrain3DData *data = _terrain->get_data();
	if (!data->has_regionp(p_global_position) && (!_brush_data["auto_regions"] || (_tool != SCULPT && _tool != HEIGHT))) {
		return;
	}

	bool modifier_alt = _brush_data["modifier_alt"];
	bool modifier_ctrl = _brush_data["modifier_ctrl"];
	//bool modifier_shift = _brush_data["modifier_shift"];

	Image *brush_image = cast_to<Image>(_brush_data["brush_image"]);
	if (!brush_image) {
		LOG(ERROR, "Invalid brush image. Returning");
		return;
	}
	Vector2i img_size = _brush_data["brush_image_size"];
	real_t brush_size = CLAMP(real_t(_brush_data.get("size", 10.f)), 2.f, 4096.f); // Meters

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
	bool texture_filter = _brush_data["texture_filter"];
	int margin = _brush_data["margin"];
	int asset_id = _brush_data["asset_id"];

	Vector2 slope_range = _brush_data["slope"];
	bool enable_angle = _brush_data["enable_angle"];
	bool dynamic_angle = _brush_data["dynamic_angle"];
	real_t angle = _brush_data["angle"];

	bool enable_scale = _brush_data["enable_scale"];
	real_t scale = _brush_data["scale"];

	real_t gamma = _brush_data["gamma"];
	PackedVector3Array gradient_points = _brush_data["gradient_points"];

	real_t randf = UtilityFunctions::randf();
	real_t rot = randf * Math_PI * real_t(_brush_data["brush_spin_speed"]);
	if (_brush_data["align_to_view"]) {
		rot += p_camera_direction;
	}
	// Rotate the decal to align with the brush
	if (_terrain->get_plugin()) {
		Node *node = cast_to<Node>(_terrain->get_plugin()->get("ui"));
		if (node->has_method("set_decal_rotation")) {
			node->call("set_decal_rotation", rot);
		}
	}
	AABB edited_area;
	edited_area.position = p_global_position - Vector3(brush_size, 0.f, brush_size) * .5f;
	edited_area.size = Vector3(brush_size, 0.f, brush_size);

	if (_tool == INSTANCER) {
		if (modifier_ctrl) {
			_terrain->get_instancer()->remove_instances(p_global_position, _brush_data);
		} else {
			_terrain->get_instancer()->add_instances(p_global_position, _brush_data);
		}
		return;
	}

	// MAP Operations
	real_t vertex_spacing = _terrain->get_vertex_spacing();

	// save region count before brush pixel loop. Any regions added will have caused an Array
	// rebuild at the end of the last _operate() call, but until painting is finished we only
	// need to track if _added_removed_locations has changed between now and the end of the loop
	int regions_added_removed = _added_removed_locations.size();

	for (real_t x = 0.f; x < brush_size; x += vertex_spacing) {
		for (real_t y = 0.f; y < brush_size; y += vertex_spacing) {
			Vector2 brush_offset = Vector2(x, y) - (V2(brush_size) * .5f);
			Vector3 brush_global_position =
					Vector3(p_global_position.x + brush_offset.x + .5f, p_global_position.y,
							p_global_position.z + brush_offset.y + .5f);

			// Get region for current brush pixel global position
			Vector2i region_loc = data->get_region_location(brush_global_position);
			Ref<Terrain3DRegion> region = _operate_region(region_loc);
			// If no region and can't make one, skip
			if (region.is_null()) {
				continue;
			}

			// Get map for this region and tool
			Image *map = region->get_map_ptr(map_type);
			if (!map) {
				continue;
			}

			// Identify position on map image
			Vector2 uv_position = _get_uv_position(brush_global_position, region_size, vertex_spacing);
			Vector2i map_pixel_position = Vector2i(uv_position * region_size);
			if (!_is_in_bounds(map_pixel_position, region_vsize)) {
				continue;
			}

			Vector2 brush_uv = Vector2(x, y) / brush_size;
			Vector2i brush_pixel_position = Vector2i(_get_rotated_uv(brush_uv, rot) * img_size);
			if (!_is_in_bounds(brush_pixel_position, img_size)) {
				continue;
			}

			Vector3 edited_position = brush_global_position;
			edited_position.y = data->get_height(edited_position);
			edited_area = edited_area.expand(edited_position);

			// Start brushing on the map
			real_t brush_alpha = brush_image->get_pixelv(brush_pixel_position).r;
			brush_alpha = real_t(Math::pow(double(brush_alpha), double(gamma)));
			brush_alpha = std::isnan(brush_alpha) ? 0.f : brush_alpha;
			Color src = map->get_pixelv(map_pixel_position);
			Color dest = src;
			real_t layer_delta = 0.0f;
			bool has_layer_delta = false;
			real_t stamp_virtual_src_height = 0.0f;
			bool stamp_virtual_src_valid = false;
			LayerAccumulator *stamp_accumulator = nullptr;
			real_t accumulated_delta = 0.0f;
			uint64_t stamp_sample_key = 0;
			bool skip_layer_pixel = false;
			if (accumulate_layers) {
				TypedArray<Terrain3DLayer> target_layers = region->get_layers(map_type);
				if (_active_layer_index < 0 || _active_layer_index >= target_layers.size()) {
					static int missing_layer_log_count = 0;
					if (missing_layer_log_count < 5) {
						LOG(WARN, "Cannot edit layer index ", _active_layer_index, " in region ", region_loc,
								": available layers=", target_layers.size());
						missing_layer_log_count++;
					}
					skip_layer_pixel = true;
				} else {
					Ref<Terrain3DLayer> target_layer = target_layers[_active_layer_index];
					if (target_layer.is_null()) {
						static int null_layer_log_count = 0;
						if (null_layer_log_count < 5) {
							LOG(WARN, "Active layer ", _active_layer_index, " in region ", region_loc, " is null; skipping pixel");
							null_layer_log_count++;
						}
						skip_layer_pixel = true;
						continue;
					}
					std::pair<Vector2i, int> accumulator_key(region_loc, _active_layer_index);
					LayerAccumulator &acc = _pending_stamp_layers[accumulator_key];
					stamp_accumulator = &acc;
					acc.layer_index = _active_layer_index;
					if (acc.region.is_null()) {
						acc.region = region;
					}
					if (acc.map_width <= 0 || acc.map_height <= 0) {
						acc.map_width = map->get_width();
						acc.map_height = map->get_height();
					}
					if (acc.map_width <= 0 || acc.map_height <= 0) {
						stamp_accumulator = nullptr;
					} else {
						stamp_sample_key = (uint64_t(map_pixel_position.y) << 32) | uint32_t(map_pixel_position.x);
						auto sample_it = acc.delta_samples.find(stamp_sample_key);
						if (sample_it != acc.delta_samples.end()) {
							accumulated_delta = sample_it->second;
						}
					}
				}
			}
			if (skip_layer_pixel) {
				continue;
			}

			if (map_type == TYPE_HEIGHT) {
				real_t srcf = src.r;
				// In case data in existing map has nan or inf saved, check, and reset to real number if required.
				srcf = std::isnan(srcf) ? 0.f : srcf;
				real_t effective_srcf = srcf + accumulated_delta;
				real_t destf = effective_srcf;
				stamp_virtual_src_height = effective_srcf;
				stamp_virtual_src_valid = true;

				switch (_operation) {
					case ADD: {
						if (_tool == HEIGHT && !accumulate_layers) {
							// Height
							destf = Math::lerp(effective_srcf, height, CLAMP(brush_alpha * strength, 0.f, 1.f));
						} else if (modifier_alt && !std::isnan(p_global_position.y)) {
							// Lift troughs
							real_t brush_center_y = p_global_position.y + brush_alpha * strength;
							destf = Math::clamp(brush_center_y, effective_srcf, effective_srcf + brush_alpha * strength);
						} else {
							// Raise
							destf = effective_srcf + (brush_alpha * strength);
						}
						break;
					}
					case SUBTRACT: {
						if (_tool == HEIGHT && !accumulate_layers) {
							// Height, but GDScript has already picked height at cursor
							destf = Math::lerp(effective_srcf, height, CLAMP(brush_alpha * strength, 0.f, 1.f));
						} else if (modifier_alt && !std::isnan(p_global_position.y)) {
							// Flatten peaks
							real_t brush_center_y = p_global_position.y - brush_alpha * strength;
							destf = Math::clamp(brush_center_y, effective_srcf - brush_alpha * strength, effective_srcf);
						} else {
							// Lower
							destf = effective_srcf - (brush_alpha * strength);
						}
						break;
					}
					case AVERAGE: {
						real_t avg_default = _terrain->get_material()->get_world_background() == 0u ? effective_srcf : 0.f;
						real_t avg = _average(AVG_HEIGHT, brush_global_position, effective_srcf, avg_default);
						destf = Math::lerp(effective_srcf, avg, CLAMP(brush_alpha * strength * 2.f, .02f, 1.f));
						break;
					}
					case GRADIENT: {
						if (gradient_points.size() == 2) {
							Vector3 point_1 = gradient_points[0];
							Vector3 point_2 = gradient_points[1];
							Vector2 point_1_xz = Vector2(point_1.x, point_1.z);
							Vector2 point_2_xz = Vector2(point_2.x, point_2.z);
							Vector2 dir = point_2_xz - point_1_xz;
							if (dir.length_squared() < 0.01f) {
								return;
							}
							Vector2 brush_xz = Vector2(brush_global_position.x, brush_global_position.z);

							if (_operation_movement.length_squared() > 0.f) {
								// Ramp up/down only in the direction of movement, to avoid giving winding
								// paths one edge higher than the other.
								Vector2 movement_xz = Vector2(_operation_movement.x, _operation_movement.z).normalized();
								Vector2 offset = movement_xz * Vector2(brush_offset).dot(movement_xz);
								brush_xz = Vector2(p_global_position.x + offset.x, p_global_position.z + offset.y);
							}

							real_t weight = dir.normalized().dot(brush_xz - point_1_xz) / dir.length();
							weight = Math::clamp(weight, (real_t)0.0f, (real_t)1.0f);
							real_t height = Math::lerp(point_1.y, point_2.y, weight);
							destf = Math::lerp(effective_srcf, height, CLAMP(brush_alpha * strength, 0.f, 1.f));
						}
						break;
					}
					default:
						break;
				}
				dest = Color(destf, 0.f, 0.f, 1.f);
				if (accumulate_layers) {
					layer_delta = destf - effective_srcf;
					has_layer_delta = Math::abs(layer_delta) > CMP_EPSILON;
					static int stamp_delta_log_count = 0;
					if (stamp_delta_log_count < 20) {
						LOG(WARN, "Stamp delta sample region ", region_loc, ": src ", effective_srcf, ", dest ", destf, ", delta ", layer_delta, ", strength ", strength, ", alpha ", brush_alpha);
						stamp_delta_log_count++;
					}
				}
				region->update_height(destf);
				data->update_master_height(destf);
				edited_position.y = destf;
				edited_area = edited_area.expand(edited_position);
			} else if (map_type == TYPE_CONTROL) {
				// Get current bit field from pixel
				uint32_t base_id = get_base(src.r);
				uint32_t overlay_id = get_overlay(src.r);
				real_t blend = real_t(get_blend(src.r)) / 255.f;
				uint32_t uvrotation = get_uv_rotation(src.r);
				uint32_t uvscale = get_uv_scale(src.r);
				bool hole = is_hole(src.r);
				bool navigation = is_nav(src.r);
				bool autoshader = is_auto(src.r);
				// Lookup to shift values saved to control map so that 0 (default) is the first entry
				// Shader scale array is aligned to match this.
				std::array<uint32_t, 8> scale_align = { 5, 6, 7, 0, 1, 2, 3, 4 };

				switch (_tool) {
					case TEXTURE: {
						if (!data->is_in_slope(brush_global_position, slope_range)) {
							continue;
						}
						switch (_operation) {
							// Base Paint
							case REPLACE: {
								if (brush_alpha > 0.5f) {
									if (enable_texture) {
										// Set base & overlay texture
										base_id = asset_id;
										overlay_id = asset_id;
										// Erase blend value
										blend = 0.f;
										autoshader = false;
									}
									// Set angle & scale
									if (base_id == asset_id && enable_angle && !autoshader) {
										if (dynamic_angle) {
											// Angle from mouse movement.
											angle = Vector2(-_operation_movement.x, _operation_movement.z).angle();
											// Avoid negative, align texture "up" with mouse direction.
											angle = real_t(Math::fmod(Math::rad_to_deg(angle) + 450.f, real_t(360.f)));
										}
										// Convert from degrees to 0 - 15 value range
										uvrotation = uint32_t(CLAMP(Math::round(angle / 22.5f), 0.f, 15.f));
									}
									if (base_id == asset_id && enable_scale && !autoshader) {
										// Offset negative and convert from percentage to 0 - 7 bit value range
										// Maintain 0 = 0, remap negatives to end.
										uvscale = scale_align[uint8_t(CLAMP(Math::round((scale + 60.f) / 20.f), 0.f, 7.f))];
									}
								}
								break;
							}

							// Add asset id, and increase weighting
							case ADD: {
								real_t spray_strength = CLAMP(strength * 0.05f, 0.004f, .25f);
								real_t brush_value = CLAMP(brush_alpha * spray_strength, 0.f, 1.f);
								if (enable_texture && brush_alpha * strength * 11.f > 0.1f) {
									// Pick lowest weighted id, and lower to zero before setting new asset id.
									if (asset_id != base_id && asset_id != overlay_id) {
										if (modifier_alt) {
											if (blend < 0.5f) {
												overlay_id = asset_id;
											} else {
												base_id = asset_id;
											}
										} else {
											if (blend >= 0.5f) {
												blend = CLAMP(blend + brush_value, 0.f, 1.f);
											} else {
												blend = CLAMP(blend - brush_value, 0.f, 1.f);
											}
											if (blend <= 1.0f / 254.f) {
												overlay_id = asset_id;
											} else if (blend >= (1.f - 1.0f / 254.f)) {
												base_id = asset_id;
											}
										}
									}

									if (base_id == asset_id) {
										blend = CLAMP(blend - brush_value, 0.f, 1.f);
										if (brush_alpha > 0.5f && blend < 0.5f) {
											autoshader = false;
										}
									}
									if (overlay_id == asset_id) {
										blend = CLAMP(blend + brush_value, 0.f, 1.f);
										if (brush_alpha > 0.5f && blend >= 0.5f) {
											autoshader = false;
										}
									}
								}

								if ((base_id == asset_id && blend < 0.5f) || (overlay_id == asset_id && blend >= 0.5f)) {
									// Set angle & scale
									if (enable_angle && !autoshader && brush_alpha > 0.5f) {
										if (dynamic_angle) {
											// Angle from mouse movement.
											angle = Vector2(-_operation_movement.x, _operation_movement.z).angle();
											// Avoid negative, align texture "up" with mouse direction.
											angle = real_t(Math::fmod(Math::rad_to_deg(angle) + 450.f, real_t(360.f)));
										}
										// Convert from degrees to 0 - 15 value range
										uvrotation = uint32_t(CLAMP(Math::round(angle / 22.5f), 0.f, 15.f));
									}
									if (enable_scale && !autoshader && brush_alpha > 0.5f) {
										// Offset negative and convert from percentage to 0 - 7 bit value range
										// Maintain 0 = 0, remap negatives to end.
										uvscale = scale_align[uint8_t(CLAMP(Math::round((scale + 60.f) / 20.f), 0.f, 7.f))];
									}
								}
								break;
							}

							// Lower weight of current asset id
							case SUBTRACT: {
								real_t spray_strength = CLAMP(strength * 0.05f, 0.004f, .25f);
								real_t brush_value = CLAMP(brush_alpha * spray_strength, 0.f, 1.f);
								if (base_id == asset_id) {
									blend = CLAMP(blend + brush_value, 0.f, 1.f);
								}
								if (overlay_id == asset_id) {
									blend = CLAMP(blend - brush_value, 0.f, 1.f);
								}
								break;
							}

							case AVERAGE: {
								real_t avg = _average(AVG_BLEND, brush_global_position, src.r, 0.f, modifier_alt) / 255.f;
								blend = Math::lerp(blend, avg, CLAMP(brush_alpha * strength * 2.f, .02f, 1.f));
								break;
							}

							default: {
								break;
							}
						}
						break;
					}
					case AUTOSHADER: {
						if (brush_alpha > 0.5f) {
							autoshader = (_operation == ADD);
							uvscale = 0.f;
							uvrotation = 0.f;
						}
						break;
					}
					case HOLES: {
						if (brush_alpha > 0.5f) {
							hole = (_operation == ADD);
						}
						break;
					}
					case NAVIGATION: {
						if (brush_alpha > 0.5f) {
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
				// Filter by visible texture
				if (texture_filter) {
					Image *cmap = region->get_map_ptr(TYPE_CONTROL);
					if (!cmap) {
						continue;
					}
					float src_ctrl = cmap->get_pixelv(map_pixel_position).r; // Must be float
					int tex_id = (get_blend(src_ctrl) > 110 - margin) ? get_overlay(src_ctrl) : get_base(src_ctrl);
					if (tex_id != asset_id) {
						continue;
					}
				}
				if (!data->is_in_slope(brush_global_position, slope_range)) {
					continue;
				}
				switch (_tool) {
					case COLOR:
						switch (_operation) {
							case ADD: {
								dest = src.lerp(color, CLAMP(brush_alpha * strength, 0.f, 1.f));
								dest.a = src.a;
								break;
							}
							case SUBTRACT: {
								dest = src.lerp(COLOR_WHITE, CLAMP(brush_alpha * strength, 0.f, 1.f));
								dest.a = src.a;
								break;
							}
							case AVERAGE: {
								Color avg_col = _average(brush_global_position, src);
								dest = src.lerp(avg_col, CLAMP(brush_alpha * strength * 2.f, .02f, 1.f));
								dest.a = src.a;
								break;
							}
							default:
								break;
						}
						break;
					case ROUGHNESS:
						/* Roughness received from UI is -100 to 100. Changed to 0,1 before storing.
						 * To convert 0,1 back to -100,100 use: 200 * (color.a - 0.5)
						 * However Godot stores values as 8-bit ints. Roundtrip is = int(a*255)/255.0
						 * Roughness 0 is saved as 0.5, but retreived is 0.498, or -0.4 roughness
						 * We round the final amount in tool_settings.gd:_on_picked().
						 */
						switch (_operation) {
							case ADD: {
								real_t target = .5f + .5f * roughness;
								dest.a = Math::lerp(real_t(src.a), target, CLAMP(brush_alpha * strength, 0.f, 1.f));
								dest.a = float(int(dest.a * 255.f)) / 255.f; // Quantize explicitly so picked values match painted values
								break;
							}
							case SUBTRACT: {
								dest.a = Math::lerp(real_t(src.a), real_t(.5f), CLAMP(brush_alpha * strength, 0.f, 1.f));
								dest.a = float(int(dest.a * 255.f)) / 255.f;
								break;
							}
							case AVERAGE: {
								real_t avg = _average(AVG_ROUGHNESS, brush_global_position, src.a, 0.5f);
								dest.a = Math::lerp(real_t(dest.a), avg, CLAMP(brush_alpha * strength * 2.f, .0f, 1.f));
								dest.a = float(int(dest.a * 255.f)) / 255.f;
								break;
							}
							default:
								break;
						}
						break;
					default:
						break;
				}
			}
			backup_region(region);
			if (accumulate_layers) {
				if (has_layer_delta && stamp_accumulator != nullptr) {
					LayerAccumulator &acc = *stamp_accumulator;
					float previous_value = accumulated_delta;
					float updated_value = previous_value + layer_delta;

					bool previous_non_zero = Math::abs(previous_value) > CMP_EPSILON;
					bool updated_non_zero = Math::abs(updated_value) > CMP_EPSILON;

					static int stamp_delta_write_log_count = 0;
					if (stamp_delta_write_log_count < 20) {
						real_t log_src_height = stamp_virtual_src_valid ? stamp_virtual_src_height : (src.r + previous_value);
						LOG(WARN, "Accumulating stamp delta at ", region_loc, " pixel ", map_pixel_position,
							": virtual src height ", log_src_height, " dest height ", dest.r,
								" layer_delta ", layer_delta, " prev total delta ", previous_value,
								" updated total delta ", updated_value);
						stamp_delta_write_log_count++;
					}

					if (updated_non_zero) {
						acc.delta_samples[stamp_sample_key] = updated_value;
						if (!previous_non_zero) {
							acc.written_pixel_count++;
						}
						acc.min_x = MIN(acc.min_x, map_pixel_position.x);
						acc.min_y = MIN(acc.min_y, map_pixel_position.y);
						acc.max_x = MAX(acc.max_x, map_pixel_position.x);
						acc.max_y = MAX(acc.max_y, map_pixel_position.y);
					} else if (previous_non_zero) {
						acc.delta_samples.erase(stamp_sample_key);
						if (acc.written_pixel_count > 0) {
							acc.written_pixel_count--;
						}
						acc.bounds_dirty = true;
					}
				}
			} else {
				map->set_pixelv(map_pixel_position, dest);
			}
		}
	}

	if (accumulate_layers) {
		if (_added_removed_locations.size() != regions_added_removed) {
			_layer_stamp_regions_changed = true;
		}
		if (!_layer_stamp_edited_area.has_volume()) {
			_layer_stamp_edited_area = edited_area;
		} else {
			_layer_stamp_edited_area = _layer_stamp_edited_area.merge(edited_area);
		}
		return;
	}
	// Regenerate color mipmaps for edited regions
	if (map_type == TYPE_COLOR) {
		for (Ref<Terrain3DRegion> region : _edited_regions) {
			if (region.is_valid()) {
				region->get_map(map_type)->generate_mipmaps();
			}
		}
	}
	// If no added or removed regions, update only changed texture array layers from the edited regions in the rendering server
	if (_added_removed_locations.size() == regions_added_removed) {
		data->update_maps(map_type, false, false);
	} else {
		// If region qty was changed, must fully rebuild the maps
		data->update_maps(map_type, true, map_type == TYPE_COLOR);
	}
	data->add_edited_area(edited_area);

	if (_tool == HOLES || _tool == HEIGHT || _tool == SCULPT) {
		_terrain->get_instancer()->update_transforms(edited_area);
	}
	// Update Dynamic / Editor collision
	if (_terrain->get_collision_mode() == Terrain3DCollision::DYNAMIC_EDITOR) {
		_terrain->get_collision()->update(true);
	}
	if (_tool == HEIGHT || _tool == SCULPT || _tool == TEXTURE || _tool == AUTOSHADER) {
		_terrain->snap();
	}
}

void Terrain3DEditor::_finalize_stamp_layers() {
	if (_pending_stamp_layers.empty() || _layer_stamp_map_type == TYPE_MAX) {
		_clear_stamp_layers_state();
		return;
	}
	Terrain3DData *data = _terrain->get_data();
	if (!data) {
		_clear_stamp_layers_state();
		return;
	}
	LOG(WARN, "Finalizing stamp-to-layer with ", (int)_pending_stamp_layers.size(), " pending entries");
	bool mutated_layers = false;
	Image::Format payload_format = map_type_get_format(_layer_stamp_map_type);
	auto recompute_accumulator_stats = [](LayerAccumulator &p_acc) -> bool {
		if (p_acc.delta_samples.empty()) {
			p_acc.min_x = INT32_MAX;
			p_acc.min_y = INT32_MAX;
			p_acc.max_x = INT32_MIN;
			p_acc.max_y = INT32_MIN;
			p_acc.written_pixel_count = 0;
			p_acc.bounds_dirty = false;
			return false;
		}
		int min_x = INT32_MAX;
		int min_y = INT32_MAX;
		int max_x = INT32_MIN;
		int max_y = INT32_MIN;
		int pixel_count = 0;
		for (const auto &entry : p_acc.delta_samples) {
			float value = entry.second;
			if (Math::abs(value) <= CMP_EPSILON) {
				continue;
			}
			uint64_t key = entry.first;
			int x = static_cast<int>(key & 0xFFFFFFFFu);
			int y = static_cast<int>((key >> 32) & 0xFFFFFFFFu);
			pixel_count++;
			min_x = MIN(min_x, x);
			min_y = MIN(min_y, y);
			max_x = MAX(max_x, x);
			max_y = MAX(max_y, y);
		}
		if (pixel_count <= 0 || min_x > max_x || min_y > max_y) {
			p_acc.min_x = INT32_MAX;
			p_acc.min_y = INT32_MAX;
			p_acc.max_x = INT32_MIN;
			p_acc.max_y = INT32_MIN;
			p_acc.written_pixel_count = 0;
			p_acc.bounds_dirty = false;
			return false;
		}
		p_acc.min_x = min_x;
		p_acc.min_y = min_y;
		p_acc.max_x = max_x;
		p_acc.max_y = max_y;
		p_acc.written_pixel_count = pixel_count;
		p_acc.bounds_dirty = false;
		return true;
	};
	for (auto &entry : _pending_stamp_layers) {
		const Vector2i &region_loc = entry.first.first;
		const int layer_index = entry.first.second;
		LayerAccumulator &acc = entry.second;
		LOG(WARN, "Accumulator for region ", region_loc, " layer ", layer_index, " has pixel_count=", acc.written_pixel_count,
				" bounds [", acc.min_x, ",", acc.min_y, "] → [", acc.max_x, ",", acc.max_y, "]",
				" samples ", acc.delta_samples.size());
		if (acc.region.is_null()) {
			LOG(WARN, "Skipping stamp layer for region ", region_loc, " layer ", layer_index, ": accumulator missing region reference");
			continue;
		}
		bool needs_recompute = acc.bounds_dirty || acc.written_pixel_count <= 0 || acc.min_x > acc.max_x || acc.min_y > acc.max_y;
		if (needs_recompute && !recompute_accumulator_stats(acc)) {
			LOG(WARN, "Skipping stamp layer for region ", region_loc, " layer ", layer_index, ": no delta pixels recorded");
			continue;
		}
		if (acc.map_width <= 0 || acc.map_height <= 0) {
			LOG(WARN, "Skipping stamp layer for region ", region_loc, " layer ", layer_index, ": missing map dimensions");
			continue;
		}
		int start_x = CLAMP(acc.min_x, 0, acc.map_width - 1);
		int start_y = CLAMP(acc.min_y, 0, acc.map_height - 1);
		int end_x = CLAMP(acc.max_x, start_x, acc.map_width - 1);
		int end_y = CLAMP(acc.max_y, start_y, acc.map_height - 1);
		int copy_width = end_x - start_x + 1;
		int copy_height = end_y - start_y + 1;
		if (copy_width <= 0 || copy_height <= 0) {
			LOG(WARN, "Skipping stamp layer for region ", region_loc, " layer ", layer_index, ": computed copy size invalid (", copy_width, "x", copy_height, ")");
			continue;
		}
		Vector2i coverage_pos(start_x, start_y);
		Vector2i coverage_size(copy_width, copy_height);
		Rect2i coverage(coverage_pos, coverage_size);
		if (acc.delta_samples.empty()) {
			LOG(WARN, "Skipping stamp layer for region ", region_loc, " layer ", layer_index, ": delta samples missing");
			continue;
		}
			int64_t total_bytes = int64_t(copy_width) * int64_t(copy_height) * int64_t(sizeof(float));
			if (total_bytes <= 0) {
				LOG(WARN, "Skipping stamp layer for region ", region_loc, " layer ", layer_index, ": invalid payload size request");
				continue;
			}
			PackedByteArray payload_bytes;
			payload_bytes.resize(total_bytes);
			uint8_t *payload_raw = payload_bytes.ptrw();
			if (!payload_raw) {
				LOG(WARN, "Skipping stamp layer for region ", region_loc, " layer ", layer_index, ": unable to allocate payload buffer");
				continue;
			}
			memset(payload_raw, 0, payload_bytes.size());
			float *payload_data = reinterpret_cast<float *>(payload_raw);
			int pixels_capacity = copy_width * copy_height;
			for (const auto &sample : acc.delta_samples) {
				float value = sample.second;
				if (Math::abs(value) <= CMP_EPSILON) {
					continue;
				}
				uint64_t key = sample.first;
				int x = static_cast<int>(key & 0xFFFFFFFFu);
				int y = static_cast<int>((key >> 32) & 0xFFFFFFFFu);
				if (x < start_x || x > end_x || y < start_y || y > end_y) {
					continue;
				}
				int local_x = x - start_x;
				int local_y = y - start_y;
				int pixel_idx = local_y * copy_width + local_x;
				if (pixel_idx < 0 || pixel_idx >= pixels_capacity) {
					continue;
				}
				payload_data[pixel_idx] = value;
			}
			Ref<Image> payload = Image::create_from_data(copy_width, copy_height, false, Image::FORMAT_RF, payload_bytes);
			if (payload.is_null()) {
				LOG(WARN, "Skipping stamp layer for region ", region_loc, " layer ", layer_index, ": failed to build payload image");
				continue;
			}
			if (payload->get_format() != payload_format) {
				payload->convert(payload_format);
			}
		Ref<Terrain3DStampLayer> stamp_layer;
		TypedArray<Terrain3DLayer> region_layers = acc.region->get_layers(_layer_stamp_map_type);
		if (layer_index >= 0 && layer_index < region_layers.size()) {
			Ref<Terrain3DLayer> existing_layer = region_layers[layer_index];
			stamp_layer = existing_layer;
			if (stamp_layer.is_null()) {
				LOG(WARN, "Layer index ", layer_index, " in region ", region_loc, " is not a stamp layer; overwriting with new stamp layer");
			}
		}

		if (stamp_layer.is_null()) {
			LOG(DEBUG, "Creating stamp layer for region ", region_loc, " layer ", layer_index, " coverage ", coverage, " payload size ", payload->get_size());
			stamp_layer = data->add_stamp_layer(region_loc, _layer_stamp_map_type, payload, coverage, Ref<Image>(), 1.0f, 0.0f, Terrain3DLayer::BLEND_ADD, layer_index, false);
			if (stamp_layer.is_valid()) {
				mutated_layers = true;
				LOG(WARN, "Added stamp layer for region ", region_loc, " layer ", layer_index, " covering ", coverage);
			} else {
				LOG(WARN, "Failed to add stamp layer for region ", region_loc, " layer ", layer_index, " covering ", coverage);
			}
		} else {
			LOG(DEBUG, "Updating existing stamp layer for region ", region_loc, " layer ", layer_index, " coverage ", coverage, " payload size ", payload->get_size());
			stamp_layer->set_coverage(coverage);
			stamp_layer->set_payload(payload);
			stamp_layer->set_alpha(Ref<Image>());
			stamp_layer->set_intensity(1.0f);
			stamp_layer->set_feather_radius(0.0f);
			stamp_layer->set_blend_mode(Terrain3DLayer::BLEND_ADD);
			stamp_layer->set_enabled(true);
			stamp_layer->mark_dirty();
			acc.region->mark_layers_dirty(_layer_stamp_map_type);
			acc.region->set_modified(true);
			acc.region->set_edited(true);
			mutated_layers = true;
		}
	}
	if (mutated_layers) {
		bool full_rebuild = _layer_stamp_regions_changed;
		bool generate_mipmaps = (_layer_stamp_map_type == TYPE_COLOR);
		data->update_maps(_layer_stamp_map_type, full_rebuild, generate_mipmaps);
		if (_layer_stamp_edited_area.has_volume()) {
			data->add_edited_area(_layer_stamp_edited_area);
			if (_tool == HOLES || _tool == HEIGHT || _tool == SCULPT) {
				_terrain->get_instancer()->update_transforms(_layer_stamp_edited_area);
			}
			if (_terrain->get_collision_mode() == Terrain3DCollision::DYNAMIC_EDITOR) {
				_terrain->get_collision()->update(true);
			}
		}
	}
	_clear_stamp_layers_state();
}

void Terrain3DEditor::_clear_stamp_layers_state() {
	_pending_stamp_layers.clear();
	_layer_stamp_map_type = TYPE_MAX;
	_layer_stamp_edited_area = AABB();
	_layer_stamp_regions_changed = false;
}

void Terrain3DEditor::_store_undo() {
	IS_INIT_COND_MESG(!_terrain->get_plugin(), "_terrain isn't initialized, returning", VOID);
	if (_tool < 0 || _tool >= TOOL_MAX) {
		return;
	}
	LOG(DEBUG, "Finalize undo & redo snapshots");
	Dictionary redo_data;
	// Store current locations; Original backed up in start_operation()
	redo_data["region_locations"] = _terrain->get_data()->get_region_locations().duplicate();
	// Store original and current backups of edited regions
	_undo_data["edited_regions"] = _original_regions;
	redo_data["edited_regions"] = _edited_regions;

	if (Terrain3D::debug_level >= DEBUG) {
		LOG(DEBUG, "Storing Original Regions:");
		for (const Ref<Terrain3DRegion> &region : _original_regions) {
			if (region.is_valid()) {
				region->dump();
			}
		}
		LOG(DEBUG, "Storing Edited Regions:");
		for (const Ref<Terrain3DRegion> &region : _edited_regions) {
			if (region.is_valid()) {
				region->dump();
			}
		}
	}

	// Store regions that were removed or added
	if (_added_removed_locations.size() > 0) {
		if (_tool == REGION && _operation == SUBTRACT) {
			_undo_data["removed_regions"] = _added_removed_locations;
			redo_data["added_regions"] = _added_removed_locations;
			LOG(DEBUG, "Removed regions: ", _added_removed_locations);
		} else {
			_undo_data["added_regions"] = _added_removed_locations;
			redo_data["removed_regions"] = _added_removed_locations;
			LOG(DEBUG, "Added regions: ", _added_removed_locations);
		}
	}

	if (_terrain->get_data()->get_edited_area().has_volume()) {
		_undo_data["edited_area"] = _terrain->get_data()->get_edited_area();
		redo_data["edited_area"] = _terrain->get_data()->get_edited_area();
		LOG(DEBUG, "Adding edited area to snapshots: ", _undo_data["edited_area"]);
	}

	// Request the plugin store the undo/redo data.
	if (_terrain->get_plugin()->has_method("create_undo_action")) {
		LOG(INFO, "Storing undo snapshot");
		String action_name = String("Terrain3D ") + OPNAME[_operation] + String(" ") + TOOLNAME[_tool];
		LOG(DEBUG, "Creating undo action: '", action_name, "'");
		_terrain->get_plugin()->call("create_undo_action", action_name);

		LOG(DEBUG, "Storing undo snapshot: ");
		Util::print_dict("_undo_data snapshot", _undo_data, DEBUG);
		_terrain->get_plugin()->call("add_undo_method", Callable(this, "apply_undo").bind(_undo_data.duplicate()));

		LOG(DEBUG, "Storing redo snapshot: ");
		Util::print_dict("redo_data snapshot", redo_data, DEBUG);
		_terrain->get_plugin()->call("add_do_method", Callable(this, "apply_undo").bind(redo_data));

		LOG(DEBUG, "Committing undo action");
		_terrain->get_plugin()->call("commit_action", false);
	}
}

void Terrain3DEditor::_apply_undo(const Dictionary &p_data) {
	IS_INIT_COND_MESG(!_terrain->get_plugin(), "_terrain isn't initialized, returning", VOID);
	LOG(INFO, "Applying Undo/Redo data");

	Terrain3DData *data = _terrain->get_data();

	if (p_data.has("edited_regions")) {
		Util::print_arr("Edited regions", p_data["edited_regions"]);
		TypedArray<Terrain3DRegion> undo_regions = p_data["edited_regions"];
		LOG(DEBUG, "Backup has ", undo_regions.size(), " edited regions");
		for (Ref<Terrain3DRegion> region : undo_regions) {
			if (region.is_null()) {
				LOG(ERROR, "Null region saved in undo data. Please report this error.");
				continue;
			}
			region->sanitize_maps(); // Live data may not have some maps so must be sanitized
			Dictionary regions = data->get_regions_all();
			regions[region->get_location()] = region;
			region->set_modified(true); // Tell update_maps() this region has layers that can be individually updated
			region->set_edited(true); // Flag so update_maps() will include it
			region->set_deleted(false); // Ensure region not marked for deletion
			if (Terrain3D::debug_level >= DEBUG) {
				LOG(DEBUG, "Restoring region:");
				region->dump();
			}
		}
	}

	if (p_data.has("edited_area")) {
		LOG(DEBUG, "Edited area: ", p_data["edited_area"]);
		data->add_edited_area(p_data["edited_area"]);
	}

	if (p_data.has("added_regions")) {
		LOG(DEBUG, "Added regions: ", p_data["added_regions"]);
		TypedArray<Vector2i> region_locs = p_data["added_regions"];
		for (const Vector2i region_loc : region_locs) {
			Ref<Terrain3DRegion> region = data->get_region(region_loc);
			if (region.is_valid()) {
				LOG(DEBUG, "Marking region: ", region_loc, " +deleted, +modified, ", ptr_to_str(*region));
				region->set_deleted(true);
				region->set_modified(true);
			}
		}
	}
	if (p_data.has("removed_regions")) {
		LOG(DEBUG, "Removed regions: ", p_data["removed_regions"]);
		TypedArray<Vector2i> region_locs = p_data["removed_regions"];
		for (const Vector2i region_loc : region_locs) {
			Ref<Terrain3DRegion> region = data->get_region(region_loc);
			if (region.is_valid()) {
				LOG(DEBUG, "Marking region: ", region_loc, " -deleted, +modified, ", ptr_to_str(*region));
				region->set_deleted(false);
				region->set_modified(true);
				_send_region_aabb(region_loc, region->get_height_range());
			}
		}
	}

	// After all regions are in place, reset the region map, which also calls update_maps
	if (p_data.has("region_locations")) {
		// Load w/ duplicate or it gets a bit wonky undoing removed regions w/ saves
		TypedArray<Vector2i> locations = p_data["region_locations"];
		_terrain->get_data()->set_region_locations(locations.duplicate());
		LOG(DEBUG, "Locations(", locations.size(), "): ", locations);
	}
	// If this undo set modifies the region qty, we must rebuild the arrays. Otherwise we can update individual layers
	if (p_data.has("added_regions") || p_data.has("removed_regions")) {
		data->update_maps(TYPE_MAX, true, false);
	} else {
		data->update_maps(TYPE_MAX, false, false);
	}
	// After TextureArray updates clear edited regions flag.
	if (p_data.has("edited_regions")) {
		TypedArray<Terrain3DRegion> undo_regions = p_data["edited_regions"];
		for (Ref<Terrain3DRegion> region : undo_regions) {
			if (region.is_valid()) {
				region->set_edited(false);
			}
		}
	}
	_terrain->get_instancer()->update_mmis(-1, V2I_MAX, true);
	if (_terrain->get_plugin()->has_method("update_region_grid")) {
		LOG(DEBUG, "Calling GDScript update_region_grid()");
		_terrain->get_plugin()->call("update_region_grid");
	}
}

// Returns average of height, blend (as real_t(0-255)), or roughness. Overloaded version handles average color
real_t Terrain3DEditor::_average(const AverageMode p_mode, const Vector3 &p_global_position, const real_t p_base,
		const real_t p_nan_val, bool p_alt) const {
	IS_DATA_INIT(NAN);
	Terrain3DData *data = _terrain->get_data();
	real_t vertex_spacing = _terrain->get_vertex_spacing();
	Vector3 left_position = p_global_position - Vector3(vertex_spacing, 0.f, 0.f);
	Vector3 right_position = p_global_position + Vector3(vertex_spacing, 0.f, 0.f);
	Vector3 down_position = p_global_position - Vector3(0.f, 0.f, vertex_spacing);
	Vector3 up_position = p_global_position + Vector3(0.f, 0.f, vertex_spacing);

	MapType map_type;
	int index;
	switch (p_mode) {
		case AVG_HEIGHT:
			map_type = TYPE_HEIGHT;
			index = 0; // Red
			break;
		case AVG_BLEND:
			map_type = TYPE_CONTROL;
			index = 0; // Red
			break;
		case AVG_ROUGHNESS:
			map_type = TYPE_COLOR;
			index = 3; // Alpha
			break;
		default:
			break;
	}

	Color pixel;
	real_t left, right, up, down;
	pixel = data->get_pixel(map_type, left_position);
	left = std::isnan(pixel.r) ? p_nan_val : pixel[index];
	pixel = data->get_pixel(map_type, right_position);
	right = std::isnan(pixel.r) ? p_nan_val : pixel[index];
	pixel = data->get_pixel(map_type, up_position);
	up = std::isnan(pixel.r) ? p_nan_val : pixel[index];
	pixel = data->get_pixel(map_type, down_position);
	down = std::isnan(pixel.r) ? p_nan_val : pixel[index];

	if (p_mode == AVG_BLEND) {
		if (p_alt) {
			return real_t(get_blend(p_base) + get_blend(left) + get_blend(right) + get_blend(up) + get_blend(down)) * 0.2f;
		} else {
			return Math::lerp(get_blend(p_base), 128.f, .1f);
		}
	} else {
		return (p_base + left + right + up + down) * 0.2f;
	}
}

Color Terrain3DEditor::_average(const Vector3 &p_global_position, const Color &p_base) const {
	IS_DATA_INIT(COLOR_NAN);
	Terrain3DData *data = _terrain->get_data();
	real_t vertex_spacing = _terrain->get_vertex_spacing();
	Vector3 left_position = p_global_position - Vector3(vertex_spacing, 0.f, 0.f);
	Vector3 right_position = p_global_position + Vector3(vertex_spacing, 0.f, 0.f);
	Vector3 down_position = p_global_position - Vector3(0.f, 0.f, vertex_spacing);
	Vector3 up_position = p_global_position + Vector3(0.f, 0.f, vertex_spacing);

	Color left = data->get_pixel(TYPE_COLOR, left_position).srgb_to_linear();
	if (std::isnan(left.r)) {
		left = COLOR_WHITE;
	}
	Color right = data->get_pixel(TYPE_COLOR, right_position).srgb_to_linear();
	if (std::isnan(right.r)) {
		right = COLOR_WHITE;
	}
	Color up = data->get_pixel(TYPE_COLOR, up_position).srgb_to_linear();
	if (std::isnan(up.r)) {
		up = COLOR_WHITE;
	}
	Color down = data->get_pixel(TYPE_COLOR, down_position).srgb_to_linear();
	if (std::isnan(down.r)) {
		down = COLOR_WHITE;
	}
	Color base = p_base.srgb_to_linear();
	return Color(
			(base.r + left.r + right.r + up.r + down.r) * 0.2f,
			(base.g + left.g + right.g + up.g + down.g) * 0.2f,
			(base.b + left.b + right.b + up.b + down.b) * 0.2f,
			1.f)
			.linear_to_srgb();
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
	// size is redundantly clamped differently in _operate_map and instancer::add_transforms
	_brush_data["size"] = CLAMP(real_t(p_data.get("size", 10.f)), 0.1f, 4096.f); // Diameter in meters
	_brush_data["strength"] = CLAMP(real_t(p_data.get("strength", .1f)) * .01f, .01f, 1000.f); // 1-100k% (max of 1000m per click)
	// mouse_pressure injected in editor.gd and sanitized in _operate_map()
	Vector2 slope = p_data.get("slope", Vector2(0.f, 90.f));
	slope.x = CLAMP(slope.x, 0.f, 90.f);
	slope.y = CLAMP(slope.y, 0.f, 90.f);
	_brush_data["slope"] = slope; // 0-90 (degrees)
	_brush_data["height"] = CLAMP(real_t(p_data.get("height", 0.f)), -65536.f, 65536.f); // Meters
	Color col = p_data.get("color", COLOR_ROUGHNESS);
	col.r = CLAMP(col.r, 0.f, 5.f);
	col.g = CLAMP(col.g, 0.f, 5.f);
	col.b = CLAMP(col.b, 0.f, 5.f);
	col.a = CLAMP(col.a, 0.f, 1.f);
	_brush_data["color"] = col;
	_brush_data["roughness"] = CLAMP(real_t(p_data.get("roughness", 0.f)), -100.f, 100.f) * .01f; // Percentage

	_brush_data["enable_texture"] = p_data.get("enable_texture", true);
	_brush_data["texture_filter"] = p_data.get("texture_filter", false);
	_brush_data["asset_id"] = CLAMP(int(p_data.get("asset_id", 0)), 0, ((_tool == INSTANCER) ? Terrain3DAssets::MAX_MESHES : Terrain3DAssets::MAX_TEXTURES) - 1);
	_brush_data["margin"] = CLAMP(int(p_data.get("margin", 0)), -100, 100);

	_brush_data["enable_angle"] = p_data.get("enable_angle", true);
	_brush_data["dynamic_angle"] = p_data.get("dynamic_angle", false);
	_brush_data["angle"] = CLAMP(real_t(p_data.get("angle", 0.f)), 0.f, 337.5f);

	_brush_data["enable_scale"] = p_data.get("enable_scale", true);
	_brush_data["scale"] = CLAMP(real_t(p_data.get("scale", 0.f)), -60.f, 80.f);

	_brush_data["auto_regions"] = bool(p_data.get("auto_regions", true));
	_brush_data["align_to_view"] = bool(p_data.get("align_to_view", true));
	_brush_data["gamma"] = CLAMP(real_t(p_data.get("gamma", 1.f)), 0.1f, 2.f);
	_brush_data["brush_spin_speed"] = CLAMP(real_t(p_data.get("brush_spin_speed", 0.f)), 0.f, 1.f);
	_brush_data["gradient_points"] = p_data.get("gradient_points", PackedVector3Array());

	Util::print_dict("set_brush_data() Santized brush data:", _brush_data, EXTREME);
}

void Terrain3DEditor::set_tool(const Tool p_tool) {
	Tool old_tool = _tool;
	SET_IF_DIFF(_tool, CLAMP(p_tool, Tool(0), TOOL_MAX));
	if (_terrain && (_tool == Tool::NAVIGATION || old_tool == Tool::NAVIGATION)) {
		_terrain->get_material()->update(true);
	}
}

void Terrain3DEditor::set_operation(const Operation p_operation) {
	SET_IF_DIFF(_operation, CLAMP(p_operation, Operation(0), OP_MAX));
}

// Called on mouse click
void Terrain3DEditor::start_operation(const Vector3 &p_global_position) {
	IS_DATA_INIT_MESG("Terrain isn't initialized", VOID);
	LOG(INFO, "Setting up undo snapshot");
	_undo_data.clear();
	_undo_data["region_locations"] = _terrain->get_data()->get_region_locations().duplicate();
	_is_operating = true;
	_original_regions = TypedArray<Terrain3DRegion>(); // New pointers instead of clear
	_edited_regions = TypedArray<Terrain3DRegion>();
	_added_removed_locations = TypedArray<Vector2i>();
	// Reset counter at start to ensure first click places an instance
	_terrain->get_instancer()->reset_density_counter();
	_terrain->get_data()->clear_edited_area();
	_clear_stamp_layers_state();
	_operation_position = p_global_position;
	_operation_movement = V3_ZERO;
}

// Called on mouse movement with left mouse button down
void Terrain3DEditor::operate(const Vector3 &p_global_position, const real_t p_camera_direction) {
	IS_DATA_INIT_MESG("Terrain isn't initialized", VOID);
	if (!_is_operating) {
		LOG(ERROR, "Run start_operation() before operating");
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
	_operation_movement *= 0.125f; // 1/8th

	if (_tool == REGION) {
		_operate_region(_terrain->get_data()->get_region_location(p_global_position));
	} else if (_tool >= 0 && _tool < TOOL_MAX) {
		_operate_map(p_global_position, p_camera_direction);
	}
}

void Terrain3DEditor::backup_region(const Ref<Terrain3DRegion> &p_region) {
	// Backup region once at the start of an operation. Once Edited is set, this is skipped
	if (_is_operating && p_region.is_valid() && !p_region->is_edited()) {
		LOG(DEBUG, "Storing original copy of region: ", p_region->get_location());
		Ref<Terrain3DRegion> orig_region = p_region->duplicate(true);
		_original_regions.push_back(orig_region);
		_edited_regions.push_back(p_region);
		p_region->set_edited(true);
		p_region->set_modified(true);
		if (Terrain3D::debug_level >= DEBUG) {
			LOG(DEBUG, "Backup original region");
			orig_region->dump();
			LOG(DEBUG, "Backup edited region");
			p_region->dump();
		}
	}
}

// Called on left mouse button released
void Terrain3DEditor::stop_operation() {
	IS_DATA_INIT_MESG("Terrain isn't initialized", VOID);
	// If undo was created and terrain actually modified, store it
	LOG(DEBUG, "Backed up regions: ", _original_regions.size(), ", Edited regions: ", _edited_regions.size(),
			", Added/Removed regions: ", _added_removed_locations.size());
	if (_is_operating) {
		_finalize_stamp_layers();
	}
	if (_is_operating && (!_added_removed_locations.is_empty() || !_edited_regions.is_empty())) {
		for (int i = 0; i < _edited_regions.size(); i++) {
			Ref<Terrain3DRegion> region = _edited_regions[i];
			region->set_edited(false);
			// Make duplicate for redo, necessary or redos won't work
			Ref<Terrain3DRegion> redo_region = region->duplicate(true);
			_edited_regions[i] = redo_region;
			if (Terrain3D::debug_level >= DEBUG) {
				LOG(DEBUG, "Edited region:");
				region->dump();
				LOG(DEBUG, "Redo region:");
				redo_region->dump();
			}
		}
		_store_undo();
	}
	_undo_data.clear();
	_original_regions = TypedArray<Terrain3DRegion>(); //New pointers instead of clear
	_edited_regions = TypedArray<Terrain3DRegion>();
	_added_removed_locations = TypedArray<Vector2i>();
	_terrain->get_data()->clear_edited_area();
	_is_operating = false;
}

Dictionary Terrain3DEditor::add_curve_layer(const PackedVector3Array &p_points, const real_t p_width, const real_t p_depth, const bool p_dual_groove, const real_t p_feather_radius, const bool p_update) {
	Dictionary result;
	if (!_terrain) {
		LOG(ERROR, "Terrain not set on editor");
		return result;
	}
	Terrain3DData *data = _terrain->get_data();
	if (!data) {
		LOG(ERROR, "Terrain data not available");
		return result;
	}
	if (p_points.size() < 2) {
		LOG(ERROR, "Curve layer requires at least two points");
		return result;
	}

	int region_size = _terrain->get_region_size();
	real_t vertex_spacing = _terrain->get_vertex_spacing();
	real_t region_world_extent = region_size * vertex_spacing;

	Vector2 min_pt(Math_INF, Math_INF);
	Vector2 max_pt(-Math_INF, -Math_INF);
	for (int i = 0; i < p_points.size(); i++) {
		const Vector3 &pt = p_points[i];
		min_pt.x = MIN(min_pt.x, pt.x);
		min_pt.y = MIN(min_pt.y, pt.z);
		max_pt.x = MAX(max_pt.x, pt.x);
		max_pt.y = MAX(max_pt.y, pt.z);
	}
	real_t padding = (p_width * 0.5f) + p_feather_radius + vertex_spacing;
	min_pt -= Vector2(padding, padding);
	max_pt += Vector2(padding, padding);

	int min_region_x = Math::floor(min_pt.x / region_world_extent);
	int min_region_y = Math::floor(min_pt.y / region_world_extent);
	int max_region_x = Math::floor(max_pt.x / region_world_extent);
	int max_region_y = Math::floor(max_pt.y / region_world_extent);

	for (int rx = min_region_x; rx <= max_region_x; rx++) {
		for (int ry = min_region_y; ry <= max_region_y; ry++) {
			Vector2 region_min_world(rx * region_world_extent, ry * region_world_extent);
			Vector2 region_max_world = region_min_world + Vector2(region_world_extent, region_world_extent);
			bool intersects = !(region_max_world.x < min_pt.x || region_max_world.y < min_pt.y || region_min_world.x > max_pt.x || region_min_world.y > max_pt.y);
			if (!intersects) {
				continue;
			}
			Vector2i region_loc(rx, ry);
			Ref<Terrain3DCurveLayer> layer = data->add_curve_layer(region_loc, p_points, p_width, p_depth, p_dual_groove, p_feather_radius, false);
			if (layer.is_valid()) {
				result[region_loc] = layer;
			}
		}
	}

	if (p_update) {
		data->update_maps(TYPE_HEIGHT, false, false);
	}

	return result;
}

void Terrain3DEditor::set_stamp_to_layer(const bool p_enabled) {
	if (_stamp_to_layer == p_enabled) {
		return;
	}
	_stamp_to_layer = p_enabled;
	_clear_stamp_layers_state();
}

void Terrain3DEditor::set_active_layer_index(const int p_index) {
	if (p_index < -1) {
		LOG(WARN, "Ignoring request to set negative active layer index ", p_index);
		return;
	}
	if (_active_layer_index == p_index) {
		return;
	}
	_active_layer_index = p_index;
	_clear_stamp_layers_state();
}

int Terrain3DEditor::create_layer(const Vector2i &p_region_loc, const MapType p_map_type, const bool p_select) {
	IS_INIT(-1);
	Terrain3DData *data = _terrain->get_data();
	if (!data) {
		return -1;
	}
	Ref<Terrain3DRegion> region = data->get_region(p_region_loc);
	if (region.is_null()) {
		LOG(WARN, "Cannot create layer: region not found at ", p_region_loc);
		return -1;
	}
	Ref<Terrain3DLayer> new_layer;
	if (p_map_type == TYPE_HEIGHT) {
		Ref<Terrain3DStampLayer> stamp_layer;
		stamp_layer.instantiate();
		stamp_layer->set_map_type(p_map_type);
		stamp_layer->set_blend_mode(Terrain3DLayer::BLEND_ADD);
		stamp_layer->set_enabled(true);
		new_layer = stamp_layer;
	} else {
		new_layer.instantiate();
		new_layer->set_map_type(p_map_type);
		new_layer->set_enabled(true);
	}
	if (new_layer.is_null()) {
		LOG(ERROR, "Failed to instantiate layer resource for map type ", p_map_type);
		return -1;
	}
	TypedArray<Terrain3DLayer> existing_layers = region->get_layers(p_map_type);
	int insert_index = existing_layers.size();
	Ref<Terrain3DLayer> added_layer = data->add_layer(p_region_loc, p_map_type, new_layer, insert_index, true);
	if (added_layer.is_null()) {
		LOG(ERROR, "Failed to add layer to region ", p_region_loc);
		return -1;
	}
	TypedArray<Terrain3DLayer> updated_layers = region->get_layers(p_map_type);
	int result_index = -1;
	for (int i = 0; i < updated_layers.size(); i++) {
		if (updated_layers[i] == added_layer) {
			result_index = i;
			break;
		}
	}
	if (result_index < 0) {
		result_index = MAX(0, updated_layers.size() - 1);
	}
	if (p_select) {
		set_active_layer_index(result_index);
	}
	return result_index;
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

	BIND_ENUM_CONSTANT(SCULPT);
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
	ClassDB::bind_method(D_METHOD("set_stamp_to_layer", "enabled"), &Terrain3DEditor::set_stamp_to_layer);
	ClassDB::bind_method(D_METHOD("is_stamp_to_layer_enabled"), &Terrain3DEditor::is_stamp_to_layer_enabled);
	ClassDB::bind_method(D_METHOD("set_active_layer_index", "index"), &Terrain3DEditor::set_active_layer_index);
	ClassDB::bind_method(D_METHOD("get_active_layer_index"), &Terrain3DEditor::get_active_layer_index);
	ClassDB::bind_method(D_METHOD("start_operation", "position"), &Terrain3DEditor::start_operation);
	ClassDB::bind_method(D_METHOD("is_operating"), &Terrain3DEditor::is_operating);
	ClassDB::bind_method(D_METHOD("operate", "position", "camera_direction"), &Terrain3DEditor::operate);
	ClassDB::bind_method(D_METHOD("backup_region", "region"), &Terrain3DEditor::backup_region);
	ClassDB::bind_method(D_METHOD("stop_operation"), &Terrain3DEditor::stop_operation);
	ClassDB::bind_method(D_METHOD("add_curve_layer", "points", "width", "depth", "dual_groove", "feather_radius", "update"), &Terrain3DEditor::add_curve_layer, DEFVAL(false), DEFVAL(0.0f), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("create_layer", "region_location", "map_type", "select"), &Terrain3DEditor::create_layer, DEFVAL(true));

	ClassDB::bind_method(D_METHOD("apply_undo", "data"), &Terrain3DEditor::_apply_undo);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "stamp_to_layer"), "set_stamp_to_layer", "is_stamp_to_layer_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "active_layer_index"), "set_active_layer_index", "get_active_layer_index");
}
