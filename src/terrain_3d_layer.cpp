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
	ClassDB::bind_method(D_METHOD("mark_dirty"), &Terrain3DLayer::mark_dirty);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "map_type", PROPERTY_HINT_ENUM, "HEIGHT,CONTROL,COLOR"), "set_map_type", "get_map_type");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enabled"), "set_enabled", "is_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "intensity", PROPERTY_HINT_RANGE, "0.0,10.0,0.01"), "set_intensity", "get_intensity");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "feather_radius", PROPERTY_HINT_RANGE, "0.0,64.0,0.01"), "set_feather_radius", "get_feather_radius");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "blend_mode", PROPERTY_HINT_ENUM, "Add,Subtract,Replace"), "set_blend_mode", "get_blend_mode");
	ADD_PROPERTY(PropertyInfo(Variant::RECT2I, "coverage"), "set_coverage", "get_coverage");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "payload", PROPERTY_HINT_RESOURCE_TYPE, "Image"), "set_payload", "get_payload");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "alpha", PROPERTY_HINT_RESOURCE_TYPE, "Image"), "set_alpha", "get_alpha");

	BIND_ENUM_CONSTANT(BLEND_ADD);
	BIND_ENUM_CONSTANT(BLEND_SUBTRACT);
	BIND_ENUM_CONSTANT(BLEND_REPLACE);
}

void Terrain3DLayer::_generate_payload(const int p_region_size, const real_t p_vertex_spacing) {
	// Base layer does not procedurally generate payload by default.
	if (_payload.is_null() && _coverage.size != Vector2i()) {
		_payload = Util::get_filled_image(_coverage.size, COLOR_BLACK, false, map_type_get_format(_map_type));
	}
	_cached_region_size = p_region_size;
	_cached_vertex_spacing = p_vertex_spacing;
	_dirty = false;
}

void Terrain3DLayer::_ensure_payload(const int p_region_size, const real_t p_vertex_spacing) {
	if (_dirty || _payload.is_null() || needs_rebuild(p_region_size, p_vertex_spacing)) {
		_generate_payload(p_region_size, p_vertex_spacing);
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
		mark_dirty();
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

bool Terrain3DLayer::needs_rebuild(const int p_region_size, const real_t p_vertex_spacing) const {
	return _cached_region_size != p_region_size || !Math::is_equal_approx(_cached_vertex_spacing, p_vertex_spacing);
}

void Terrain3DLayer::apply(Image &p_target, const int p_region_size, const real_t p_vertex_spacing) {
	if (!_enabled) {
		return;
	}
	_ensure_payload(p_region_size, p_vertex_spacing);
	if (_payload.is_null()) {
		return;
	}
	Vector2i target_size = Vector2i(p_target.get_width(), p_target.get_height());
	Rect2i coverage = _coverage.has_area() ? _coverage : Rect2i(Vector2i(), Vector2i(_payload->get_width(), _payload->get_height()));

	Rect2i coverage_clamped = coverage;
	coverage_clamped.position = coverage_clamped.position.clamp(Vector2i(), target_size);
	Vector2i far = coverage_clamped.position + coverage_clamped.size;
	far = Vector2i(MIN(far.x, target_size.x), MIN(far.y, target_size.y));
	coverage_clamped.size = far - coverage_clamped.position;
	if (coverage_clamped.size.x <= 0 || coverage_clamped.size.y <= 0) {
		return;
	}

	for (int y = 0; y < coverage_clamped.size.y; y++) {
		for (int x = 0; x < coverage_clamped.size.x; x++) {
			int src_x = x + (coverage_clamped.position.x - coverage.position.x);
			int src_y = y + (coverage_clamped.position.y - coverage.position.y);
			Color src = _payload->get_pixel(src_x, src_y);
			Color dst = p_target.get_pixel(coverage_clamped.position.x + x, coverage_clamped.position.y + y);

			real_t alpha_weight = 1.0f;
			if (_alpha.is_valid()) {
				alpha_weight = _alpha->get_pixel(src_x, src_y).r;
			}
			real_t feather_weight = _compute_feather_weight(Vector2i(src_x, src_y));
			real_t weight = CLAMP(alpha_weight * feather_weight, 0.0f, 1.0f);
			real_t scaled_weight = MIN(weight * _intensity, 1.0f);

			switch (_map_type) {
				case TYPE_HEIGHT: {
					real_t delta = src.r * scaled_weight;
					if (_blend_mode == BLEND_REPLACE) {
						dst.r = Math::lerp(dst.r, src.r, scaled_weight);
					} else {
						real_t sign = (_blend_mode == BLEND_SUBTRACT) ? -1.0f : 1.0f;
						dst.r = dst.r + delta * sign;
					}
					dst.a = 1.0f;
				} break;
				case TYPE_CONTROL: {
					real_t delta = src.r * scaled_weight;
					if (_blend_mode == BLEND_REPLACE) {
						dst.r = Math::lerp(dst.r, src.r, scaled_weight);
					} else {
						real_t sign = (_blend_mode == BLEND_SUBTRACT) ? -1.0f : 1.0f;
						dst.r = dst.r + delta * sign;
					}
					dst.a = 1.0f;
				} break;
				case TYPE_COLOR: {
					Color delta = src * scaled_weight;
					if (_blend_mode == BLEND_REPLACE) {
						dst = dst.lerp(src, scaled_weight);
					} else {
						real_t sign = (_blend_mode == BLEND_SUBTRACT) ? -1.0f : 1.0f;
						dst.r = CLAMP(dst.r + delta.r * sign, 0.0f, 1.0f);
						dst.g = CLAMP(dst.g + delta.g * sign, 0.0f, 1.0f);
						dst.b = CLAMP(dst.b + delta.b * sign, 0.0f, 1.0f);
						dst.a = CLAMP(dst.a + delta.a * sign, 0.0f, 1.0f);
					}
				} break;
				default:
					break;
			}

			p_target.set_pixel(coverage_clamped.position.x + x, coverage_clamped.position.y + y, dst);
		}
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

///////////////////////////
// Terrain3DCurveLayer
///////////////////////////

void Terrain3DCurveLayer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_points", "points"), &Terrain3DCurveLayer::set_points);
	ClassDB::bind_method(D_METHOD("get_points"), &Terrain3DCurveLayer::get_points);
	ClassDB::bind_method(D_METHOD("set_width", "width"), &Terrain3DCurveLayer::set_width);
	ClassDB::bind_method(D_METHOD("get_width"), &Terrain3DCurveLayer::get_width);
	ClassDB::bind_method(D_METHOD("set_depth", "depth"), &Terrain3DCurveLayer::set_depth);
	ClassDB::bind_method(D_METHOD("get_depth"), &Terrain3DCurveLayer::get_depth);
	ClassDB::bind_method(D_METHOD("set_dual_groove", "dual"), &Terrain3DCurveLayer::set_dual_groove);
	ClassDB::bind_method(D_METHOD("get_dual_groove"), &Terrain3DCurveLayer::get_dual_groove);

	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "points", PROPERTY_HINT_ARRAY_TYPE, "Vector3"), "set_points", "get_points");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "width", PROPERTY_HINT_RANGE, "0.1,256.0,0.1"), "set_width", "get_width");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "depth", PROPERTY_HINT_RANGE, "0.0,5.0,0.01"), "set_depth", "get_depth");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "dual_groove"), "set_dual_groove", "get_dual_groove");
}

void Terrain3DCurveLayer::_generate_payload(const int p_region_size, const real_t p_vertex_spacing) {
	if (_points.is_empty()) {
		_payload.unref();
		_cached_region_size = p_region_size;
		_cached_vertex_spacing = p_vertex_spacing;
		_dirty = false;
		return;
	}

	Vector2 min_pt = Vector2(Math_INF, Math_INF);
	Vector2 max_pt = Vector2(-Math_INF, -Math_INF);
	for (int i = 0; i < _points.size(); i++) {
		Vector3 p = _points[i];
		Vector2 v2 = Vector2(p.x, p.z);
		min_pt.x = MIN(min_pt.x, v2.x);
		min_pt.y = MIN(min_pt.y, v2.y);
		max_pt.x = MAX(max_pt.x, v2.x);
		max_pt.y = MAX(max_pt.y, v2.y);
	}

	real_t padding = (_width * 0.5f) + _feather_radius + 0.5f;
	min_pt -= Vector2(padding, padding);
	max_pt += Vector2(padding, padding);

	real_t pixels_per_meter = (p_vertex_spacing <= CMP_EPSILON) ? 1.0f : (1.0f / p_vertex_spacing);
	Vector2i rect_pos = Vector2i(Math::floor(min_pt.x * pixels_per_meter), Math::floor(min_pt.y * pixels_per_meter));
	Vector2i rect_end = Vector2i(Math::ceil(max_pt.x * pixels_per_meter), Math::ceil(max_pt.y * pixels_per_meter));
	Vector2i rect_size = rect_end - rect_pos;
	rect_pos = rect_pos.clamp(Vector2i(-p_region_size, -p_region_size), Vector2i(p_region_size * 2, p_region_size * 2));
	rect_size.x = MAX(rect_size.x, 1);
	rect_size.y = MAX(rect_size.y, 1);

	Rect2i coverage(rect_pos, rect_size);
	set_coverage(coverage);

	_payload.instantiate();
	_payload->create(rect_size.x, rect_size.y, false, map_type_get_format(_map_type));
	_payload->fill(Color(0.0f, 0.0f, 0.0f, 1.0f));

	real_t half_width = _width * 0.5f;

	for (int y = 0; y < rect_size.y; y++) {
		for (int x = 0; x < rect_size.x; x++) {
			real_t world_x = (rect_pos.x + x + 0.5f) / pixels_per_meter;
			real_t world_z = (rect_pos.y + y + 0.5f) / pixels_per_meter;
			Vector2 sample(world_x, world_z);
			real_t dist = _distance_to_polyline(sample);
			if (dist < 0.0f) {
				continue;
			}
			real_t influence = 0.0f;
			real_t groove_limit = half_width;
			if (_dual_groove) {
				real_t lane_offset = half_width * 0.5f;
				real_t dist_left = MAX(0.0f, dist - lane_offset);
				real_t dist_right = MAX(0.0f, dist + lane_offset);
				real_t min_lane = MIN(dist_left, dist_right);
				groove_limit = lane_offset;
				dist = min_lane;
			}

			if (dist <= groove_limit + _feather_radius) {
				real_t normalized = CLAMP(dist / MAX(CMP_EPSILON, groove_limit), 0.0f, 1.0f);
				real_t core = 1.0f - smooth_step(0.0f, 1.0f, normalized);
				real_t feather = 1.0f;
				if (dist > groove_limit && _feather_radius > CMP_EPSILON) {
					real_t feather_t = (dist - groove_limit) / _feather_radius;
					feather = 1.0f - smooth_step(0.0f, 1.0f, feather_t);
				}
				influence = core * feather;
			}

			if (influence <= CMP_EPSILON) {
				continue;
			}

			real_t depth = -_depth * influence * _intensity;
			Color c(depth, 0.0f, 0.0f, 1.0f);
			_payload->set_pixel(x, y, c);
		}
	}

	_cached_region_size = p_region_size;
	_cached_vertex_spacing = p_vertex_spacing;
	_dirty = false;
}

real_t Terrain3DCurveLayer::_distance_to_polyline(const Vector2 &p_point) const {
	if (_points.size() < 2) {
		return -1.0f;
	}
	real_t best = Math_INF;
	for (int i = 0; i < _points.size() - 1; i++) {
		Vector2 a(_points[i].x, _points[i].z);
		Vector2 b(_points[i + 1].x, _points[i + 1].z);
		Vector2 ab = b - a;
	real_t len_sq = ab.length_squared();
	if (len_sq < CMP_EPSILON) {
		continue;
	}
		real_t t = ((p_point - a).dot(ab)) / len_sq;
		t = CLAMP(t, 0.0f, 1.0f);
		Vector2 projection = a + ab * t;
		real_t dist = (p_point - projection).length();
		best = MIN(best, dist);
	}
	return (best == Math_INF) ? -1.0f : best;
}

void Terrain3DCurveLayer::set_points(const PackedVector3Array &p_points) {
	_points = p_points;
	mark_dirty();
}

void Terrain3DCurveLayer::set_width(const real_t p_width) {
	real_t width = MAX(0.1f, p_width);
	if (!Math::is_equal_approx(_width, width)) {
		_width = width;
		mark_dirty();
	}
}

void Terrain3DCurveLayer::set_depth(const real_t p_depth) {
	real_t depth = MAX(0.0f, p_depth);
	if (!Math::is_equal_approx(_depth, depth)) {
		_depth = depth;
		mark_dirty();
	}
}

void Terrain3DCurveLayer::set_dual_groove(const bool p_dual) {
	if (_dual_groove != p_dual) {
		_dual_groove = p_dual;
		mark_dirty();
	}
}

///////////////////////////
// Terrain3DLocalNodeLayer
///////////////////////////

void Terrain3DLocalNodeLayer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_source_path", "source_path"), &Terrain3DLocalNodeLayer::set_source_path);
	ClassDB::bind_method(D_METHOD("get_source_path"), &Terrain3DLocalNodeLayer::get_source_path);
	ClassDB::bind_method(D_METHOD("set_local_transform", "transform"), &Terrain3DLocalNodeLayer::set_local_transform);
	ClassDB::bind_method(D_METHOD("get_local_transform"), &Terrain3DLocalNodeLayer::get_local_transform);

	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "source_path"), "set_source_path", "get_source_path");
	ADD_PROPERTY(PropertyInfo(Variant::TRANSFORM3D, "local_transform"), "set_local_transform", "get_local_transform");
}

void Terrain3DLocalNodeLayer::_generate_payload(const int p_region_size, const real_t p_vertex_spacing) {
	Terrain3DLayer::_generate_payload(p_region_size, p_vertex_spacing);
}
