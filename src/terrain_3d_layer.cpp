// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "logger.h"
#include "terrain_3d_layer.h"
#include "terrain_3d_util.h"

namespace {
static inline real_t smooth_step(real_t edge0, real_t edge1, real_t x) {
	x = CLAMP((x - edge0) / (edge1 - edge0), 0.0f, 1.0f);
	return x * x * (3.0f - 2.0f * x);
}
}

///////////////////////////
// Terrain3DLayer
///////////////////////////

void Terrain3DLayer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_map_type", "map_type"), &Terrain3DLayer::set_map_type);
	ClassDB::bind_method(D_METHOD("get_map_type"), &Terrain3DLayer::get_map_type);
	ClassDB::bind_method(D_METHOD("set_enabled", "enabled"), &Terrain3DLayer::set_enabled);
	ClassDB::bind_method(D_METHOD("is_enabled"), &Terrain3DLayer::is_enabled);
	ClassDB::bind_method(D_METHOD("set_intensity", "intensity"), &Terrain3DLayer::set_intensity);
	ClassDB::bind_method(D_METHOD("get_intensity"), &Terrain3DLayer::get_intensity);
	ClassDB::bind_method(D_METHOD("set_feather_radius", "radius"), &Terrain3DLayer::set_feather_radius);
	ClassDB::bind_method(D_METHOD("get_feather_radius"), &Terrain3DLayer::get_feather_radius);
	ClassDB::bind_method(D_METHOD("set_blend_mode", "blend_mode"), &Terrain3DLayer::set_blend_mode);
	ClassDB::bind_method(D_METHOD("get_blend_mode"), &Terrain3DLayer::get_blend_mode);
	ClassDB::bind_method(D_METHOD("set_coverage", "rect"), &Terrain3DLayer::set_coverage);
	ClassDB::bind_method(D_METHOD("get_coverage"), &Terrain3DLayer::get_coverage);
	ClassDB::bind_method(D_METHOD("set_payload", "image"), &Terrain3DLayer::set_payload);
	ClassDB::bind_method(D_METHOD("get_payload"), &Terrain3DLayer::get_payload);
	ClassDB::bind_method(D_METHOD("set_alpha", "image"), &Terrain3DLayer::set_alpha);
	ClassDB::bind_method(D_METHOD("get_alpha"), &Terrain3DLayer::get_alpha);
	ClassDB::bind_method(D_METHOD("set_group_id", "group_id"), &Terrain3DLayer::set_group_id);
	ClassDB::bind_method(D_METHOD("get_group_id"), &Terrain3DLayer::get_group_id);
	ClassDB::bind_method(D_METHOD("set_user_editable", "editable"), &Terrain3DLayer::set_user_editable);
	ClassDB::bind_method(D_METHOD("is_user_editable"), &Terrain3DLayer::is_user_editable);
	ClassDB::bind_method(D_METHOD("mark_dirty"), &Terrain3DLayer::mark_dirty);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "map_type", PROPERTY_HINT_ENUM, "HEIGHT,CONTROL,COLOR"), "set_map_type", "get_map_type");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enabled"), "set_enabled", "is_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "intensity", PROPERTY_HINT_RANGE, "0.0,10.0,0.01"), "set_intensity", "get_intensity");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "feather_radius", PROPERTY_HINT_RANGE, "0.0,64.0,0.01"), "set_feather_radius", "get_feather_radius");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "blend_mode", PROPERTY_HINT_ENUM, "Add,Subtract,Replace"), "set_blend_mode", "get_blend_mode");
	ADD_PROPERTY(PropertyInfo(Variant::RECT2I, "coverage"), "set_coverage", "get_coverage");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "payload", PROPERTY_HINT_RESOURCE_TYPE, "Image"), "set_payload", "get_payload");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "alpha", PROPERTY_HINT_RESOURCE_TYPE, "Image"), "set_alpha", "get_alpha");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "group_id", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_INTERNAL), "set_group_id", "get_group_id");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "user_editable", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_INTERNAL), "set_user_editable", "is_user_editable");

	BIND_ENUM_CONSTANT(BLEND_ADD);
	BIND_ENUM_CONSTANT(BLEND_SUBTRACT);
	BIND_ENUM_CONSTANT(BLEND_REPLACE);
}

void Terrain3DLayer::_generate_payload(const real_t p_vertex_spacing) {
	if (_payload.is_null() && _coverage.size != Vector2i()) {
		_payload = Util::get_filled_image(_coverage.size, COLOR_BLACK, false, map_type_get_format(_map_type));
	}
	_cached_vertex_spacing = p_vertex_spacing;
	_dirty = false;
}

void Terrain3DLayer::_ensure_payload(const real_t p_vertex_spacing) {
	if (_dirty || _payload.is_null() || needs_rebuild(p_vertex_spacing)) {
		_generate_payload(p_vertex_spacing);
	}
}

real_t Terrain3DLayer::_compute_feather_weight(const Vector2i &p_pixel) const {
	if (_feather_radius <= CMP_EPSILON) {
		return 1.0f;
	}
	Vector2i size = _payload->get_size();
	Vector2 dist_to_edge = Vector2(MIN(real_t(p_pixel.x), real_t(size.x - 1 - p_pixel.x)), MIN(real_t(p_pixel.y), real_t(size.y - 1 - p_pixel.y)));
	real_t shortest = MIN(dist_to_edge.x, dist_to_edge.y);
	if (shortest >= _feather_radius) {
		return 1.0f;
	}
	real_t t = CLAMP(shortest / _feather_radius, 0.0f, 1.0f);
	return smooth_step(0.0f, 1.0f, t);
}

void Terrain3DLayer::set_map_type(const MapType p_type) {
	if (_map_type != p_type) {
		_map_type = p_type;
		mark_dirty();
	}
}

void Terrain3DLayer::set_enabled(const bool p_enabled) {
	_enabled = p_enabled;
}

void Terrain3DLayer::set_intensity(const real_t p_intensity) {
	if (!Math::is_equal_approx(_intensity, p_intensity)) {
		_intensity = p_intensity;
	}
}

void Terrain3DLayer::set_feather_radius(const real_t p_radius) {
	if (!Math::is_equal_approx(_feather_radius, p_radius)) {
		_feather_radius = MAX(0.0f, p_radius);
	}
}

void Terrain3DLayer::set_blend_mode(const BlendMode p_mode) {
	if (_blend_mode != p_mode) {
		_blend_mode = p_mode;
	}
}

void Terrain3DLayer::set_coverage(const Rect2i &p_rect) {
	if (_coverage != p_rect) {
		_coverage = p_rect;
		mark_dirty();
	}
}

void Terrain3DLayer::set_payload(const Ref<Image> &p_image) {
	_payload = p_image;
	mark_dirty();
}

void Terrain3DLayer::set_alpha(const Ref<Image> &p_alpha) {
	_alpha = p_alpha;
}

void Terrain3DLayer::set_group_id(const uint64_t p_group_id) {
	_group_id = p_group_id;
}

void Terrain3DLayer::set_user_editable(bool p_editable) {
	_user_editable = p_editable;
}

bool Terrain3DLayer::needs_rebuild(const real_t p_vertex_spacing) const {
	return !Math::is_equal_approx(_cached_vertex_spacing, p_vertex_spacing);
}

namespace {
static inline Rect2i clamp_rect_to_size(const Rect2i &p_rect, const Vector2i &p_max_size) {
	Rect2i clamped = p_rect;
	Vector2i pos_clamped = p_rect.position.clamp(Vector2i(), p_max_size);
	Vector2i coverage_end = p_rect.position + p_rect.size;
	Vector2i end_clamped = Vector2i(MIN(coverage_end.x, p_max_size.x), MIN(coverage_end.y, p_max_size.y));
	clamped.position = pos_clamped;
	clamped.size = end_clamped - clamped.position;
	return clamped;
}
}

void Terrain3DLayer::apply(Image &p_target, const real_t p_vertex_spacing) {
	apply_rect(p_target, p_vertex_spacing, Rect2i());
}

void Terrain3DLayer::apply_rect(Image &p_target, const real_t p_vertex_spacing, const Rect2i &p_rect) {
	if (!_enabled) {
		return;
	}
	_ensure_payload(p_vertex_spacing);
	if (_payload.is_null()) {
		LOG(DEBUG, "Layer payload missing for map type ", _map_type, ", coverage ", _coverage);
		return;
	}
	if (_payload->get_width() <= 0 || _payload->get_height() <= 0) {
		LOG(ERROR, "Layer payload has invalid size ", Vector2i(_payload->get_width(), _payload->get_height()), " for coverage ", _coverage);
		return;
	}
	Vector2i target_size = Vector2i(p_target.get_width(), p_target.get_height());
	if (target_size.x <= 0 || target_size.y <= 0) {
		return;
	}
	Rect2i coverage = _coverage.has_area() ? _coverage : Rect2i(Vector2i(), Vector2i(_payload->get_width(), _payload->get_height()));
	Rect2i coverage_clamped = clamp_rect_to_size(coverage, target_size);
	if (coverage_clamped.size.x <= 0 || coverage_clamped.size.y <= 0) {
		return;
	}
	Rect2i effective = coverage_clamped;
	if (p_rect.has_area()) {
		Rect2i limit = clamp_rect_to_size(p_rect, target_size);
		effective = effective.intersection(limit);
		if (!effective.has_area()) {
			return;
		}
	}
	int skipped_samples = 0;
	Vector2i loop_end = effective.position + effective.size;
	for (int dst_y = effective.position.y; dst_y < loop_end.y; dst_y++) {
		for (int dst_x = effective.position.x; dst_x < loop_end.x; dst_x++) {
			int src_x = dst_x - coverage.position.x;
			int src_y = dst_y - coverage.position.y;
			if (src_x < 0 || src_y < 0 || src_x >= _payload->get_width() || src_y >= _payload->get_height()) {
				skipped_samples++;
				continue;
			}
			Color src = _payload->get_pixel(src_x, src_y);
			Color dst = p_target.get_pixel(dst_x, dst_y);

			real_t alpha_weight = 1.0f;
			if (_alpha.is_valid()) {
				int alpha_w = _alpha->get_width();
				int alpha_h = _alpha->get_height();
				if (src_x >= 0 && src_x < alpha_w && src_y >= 0 && src_y < alpha_h) {
					alpha_weight = _alpha->get_pixel(src_x, src_y).r;
				}
			}
			real_t feather_weight = _compute_feather_weight(Vector2i(src_x, src_y));
			real_t mask_weight = CLAMP(alpha_weight * feather_weight, 0.0f, 1.0f);
			real_t intensity = MAX(_intensity, 0.0f);
			real_t replace_weight = MIN(mask_weight * intensity, 1.0f);
			real_t additive_weight = mask_weight * intensity;

			switch (_map_type) {
				case TYPE_HEIGHT: {
					real_t payload = src.r;
					if (_blend_mode == BLEND_REPLACE) {
						dst.r = Math::lerp(dst.r, payload, replace_weight);
					} else {
						real_t sign = (_blend_mode == BLEND_SUBTRACT) ? -1.0f : 1.0f;
						real_t delta = payload * additive_weight;
						dst.r += delta * sign;
					}
					dst.a = 1.0f;
				} break;
				case TYPE_CONTROL: {
					real_t payload = src.r;
					if (_blend_mode == BLEND_REPLACE) {
						dst.r = Math::lerp(dst.r, payload, replace_weight);
					} else {
						real_t sign = (_blend_mode == BLEND_SUBTRACT) ? -1.0f : 1.0f;
						real_t delta = payload * additive_weight;
						dst.r += delta * sign;
					}
					dst.a = 1.0f;
				} break;
				case TYPE_COLOR: {
					Color payload = src;
					if (_blend_mode == BLEND_REPLACE) {
						dst = dst.lerp(payload, replace_weight);
					} else {
						real_t sign = (_blend_mode == BLEND_SUBTRACT) ? -1.0f : 1.0f;
						Color delta = payload * additive_weight;
						dst.r = CLAMP(dst.r + delta.r * sign, 0.0f, 1.0f);
						dst.g = CLAMP(dst.g + delta.g * sign, 0.0f, 1.0f);
						dst.b = CLAMP(dst.b + delta.b * sign, 0.0f, 1.0f);
						dst.a = CLAMP(dst.a + delta.a * sign, 0.0f, 1.0f);
					}
				} break;
				default:
					break;
			}

			p_target.set_pixel(dst_x, dst_y, dst);
		}
	}
	if (skipped_samples > 0) {
		LOG(WARN, "Layer skipped ", skipped_samples, " samples due to payload bounds. coverage=", coverage, " clamped=", effective, " payload_size=", Vector2i(_payload->get_width(), _payload->get_height()));
	}
}

void Terrain3DLayer::mark_dirty() {
	_dirty = true;
}

///////////////////////////
// Terrain3DStampLayer
///////////////////////////

void Terrain3DStampLayer::_bind_methods() {
}

