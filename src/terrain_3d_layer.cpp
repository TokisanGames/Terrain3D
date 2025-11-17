// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <vector>

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

struct CurveSegmentCache {
	Vector2 a;
	Vector2 b;
	Vector2 ab;
	real_t length_sq = 0.0f;
	real_t height_a = 0.0f;
	real_t height_b = 0.0f;
};
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

	Rect2i region_bounds(Vector2i(), Vector2i(p_region_size, p_region_size));
	Rect2i coverage = get_coverage();
	Rect2i clamped = coverage.intersection(region_bounds);
	if (!clamped.has_area()) {
		_payload.unref();
		set_coverage(Rect2i());
		_dirty = false;
		return;
	}
	if (clamped != coverage) {
		Ref<Image> trimmed;
		trimmed.instantiate();
		trimmed->create(clamped.size.x, clamped.size.y, false, _payload->get_format());
		Rect2i copy_rect(clamped.position - coverage.position, clamped.size);
		trimmed->blit_rect(_payload, copy_rect, Vector2i());
		_payload = trimmed;
		set_coverage(clamped);
	}

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
		LOG(DEBUG, "Layer payload missing for map type ", _map_type, ", coverage ", _coverage);
		return;
	}
	if (_payload->get_width() <= 0 || _payload->get_height() <= 0) {
		LOG(ERROR, "Layer payload has invalid size ", Vector2i(_payload->get_width(), _payload->get_height()), " for coverage ", _coverage);
		return;
	}
	Vector2i target_size = Vector2i(p_target.get_width(), p_target.get_height());
	Rect2i coverage = _coverage.has_area() ? _coverage : Rect2i(Vector2i(), Vector2i(_payload->get_width(), _payload->get_height()));

    Rect2i coverage_clamped = coverage;
    Vector2i pos_clamped = coverage.position.clamp(Vector2i(), target_size);
    Vector2i coverage_end = coverage.position + coverage.size;
    Vector2i end_clamped = Vector2i(
	    MIN(coverage_end.x, target_size.x),
	    MIN(coverage_end.y, target_size.y));
    coverage_clamped.position = pos_clamped;
    coverage_clamped.size = end_clamped - coverage_clamped.position;
	if (coverage_clamped.size.x <= 0 || coverage_clamped.size.y <= 0) {
		return;
	}

	int skipped_samples = 0;
	for (int y = 0; y < coverage_clamped.size.y; y++) {
		for (int x = 0; x < coverage_clamped.size.x; x++) {
			int src_x = x + (coverage_clamped.position.x - coverage.position.x);
			int src_y = y + (coverage_clamped.position.y - coverage.position.y);
			if (src_x < 0 || src_y < 0 || src_x >= _payload->get_width() || src_y >= _payload->get_height()) {
				skipped_samples++;
				continue;
			}
			Color src = _payload->get_pixel(src_x, src_y);
			Color dst = p_target.get_pixel(coverage_clamped.position.x + x, coverage_clamped.position.y + y);

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
			real_t scaled_weight = MIN(mask_weight * intensity, 1.0f);

			switch (_map_type) {
				case TYPE_HEIGHT: {
					real_t payload = src.r;
					real_t delta = payload * scaled_weight;
					if (_blend_mode == BLEND_REPLACE) {
						dst.r = Math::lerp(dst.r, payload, scaled_weight);
					} else {
						real_t sign = (_blend_mode == BLEND_SUBTRACT) ? -1.0f : 1.0f;
						dst.r = dst.r + delta * sign;
					}
					dst.a = 1.0f;
				} break;
				case TYPE_CONTROL: {
					real_t payload = src.r;
					real_t delta = payload * scaled_weight;
					if (_blend_mode == BLEND_REPLACE) {
						dst.r = Math::lerp(dst.r, payload, scaled_weight);
					} else {
						real_t sign = (_blend_mode == BLEND_SUBTRACT) ? -1.0f : 1.0f;
						dst.r = dst.r + delta * sign;
					}
					dst.a = 1.0f;
				} break;
				case TYPE_COLOR: {
					Color payload = src;
					Color delta = payload * scaled_weight;
					if (_blend_mode == BLEND_REPLACE) {
						dst = dst.lerp(payload, scaled_weight);
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
	if (skipped_samples > 0) {
		LOG(WARN, "Layer skipped ", skipped_samples, " samples due to payload bounds. coverage=", coverage, " clamped=", coverage_clamped, " payload_size=", Vector2i(_payload->get_width(), _payload->get_height()));
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
	ClassDB::bind_method(D_METHOD("set_falloff_curve", "curve"), &Terrain3DCurveLayer::set_falloff_curve);
	ClassDB::bind_method(D_METHOD("get_falloff_curve"), &Terrain3DCurveLayer::get_falloff_curve);

	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "points", PROPERTY_HINT_ARRAY_TYPE, "Vector3"), "set_points", "get_points");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "width", PROPERTY_HINT_RANGE, "0.1,256.0,0.1"), "set_width", "get_width");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "depth", PROPERTY_HINT_RANGE, "-5.0,5.0,0.01"), "set_depth", "get_depth");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "dual_groove"), "set_dual_groove", "get_dual_groove");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "falloff_curve", PROPERTY_HINT_RESOURCE_TYPE, "Curve"), "set_falloff_curve", "get_falloff_curve");
}

void Terrain3DCurveLayer::_generate_payload(const int p_region_size, const real_t p_vertex_spacing) {
	if (_points.is_empty()) {
		LOG(DEBUG, "Curve layer payload generation skipped: no points");
		_payload.unref();
		_alpha.unref();
		_cached_region_size = p_region_size;
		_cached_vertex_spacing = p_vertex_spacing;
		_dirty = false;
		return;
	}
	LOG(DEBUG, "Generating curve payload: points=", _points.size(), " region_size=", p_region_size, " vertex_spacing=", p_vertex_spacing, " width=", _width, " depth=", _depth, " intensity=", _intensity);

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
	LOG(DEBUG, "Curve payload bounds candidate: rect_pos=", rect_pos, " rect_end=", rect_end, " rect_size=", rect_size);

	Ref<Image> new_payload = Image::create(rect_size.x, rect_size.y, false, map_type_get_format(_map_type));
	if (new_payload.is_null()) {
		LOG(ERROR, "Curve payload create returned null. size=", Vector2i(rect_size.x, rect_size.y));
		set_coverage(Rect2i());
		_payload.unref();
		_alpha.unref();
		_cached_region_size = p_region_size;
		_cached_vertex_spacing = p_vertex_spacing;
		_dirty = false;
		return;
	}
	new_payload->fill(Color(0.0f, 0.0f, 0.0f, 1.0f));
	_payload = new_payload;
	Ref<Image> new_alpha = Image::create(rect_size.x, rect_size.y, false, Image::FORMAT_RF);
	if (new_alpha.is_null()) {
		LOG(ERROR, "Curve alpha create returned null. size=", Vector2i(rect_size.x, rect_size.y));
		set_coverage(Rect2i());
		_payload.unref();
		_alpha.unref();
		_cached_region_size = p_region_size;
		_cached_vertex_spacing = p_vertex_spacing;
		_dirty = false;
		return;
	}
	new_alpha->fill(Color(0.0f, 0.0f, 0.0f, 1.0f));
	_alpha = new_alpha;
	LOG(DEBUG, "Curve payload image created size=", Vector2i(_payload->get_width(), _payload->get_height()));

	// Reset the cached coverage before writing into the image so incremental re-use does not leak past writes.
	Rect2i updated_coverage(rect_pos, rect_size);
	set_coverage(updated_coverage);
	int payload_width = _payload->get_width();
	int payload_height = _payload->get_height();
	if (payload_width <= 0 || payload_height <= 0) {
		LOG(ERROR, "Curve payload allocation failed: requested=", Vector2i(rect_size.x, rect_size.y));
		set_coverage(Rect2i());
		_payload.unref();
		_cached_region_size = p_region_size;
		_cached_vertex_spacing = p_vertex_spacing;
		_dirty = false;
		return;
	}

	real_t half_width = _width * 0.5f;
	const int segment_count = MAX(0, _points.size() - 1);
	std::vector<CurveSegmentCache> segment_cache;
	segment_cache.resize(segment_count);
	for (int i = 0; i < segment_count; i++) {
		const Vector3 &p0 = _points[i];
		const Vector3 &p1 = _points[i + 1];
		CurveSegmentCache segment;
		segment.a = Vector2(p0.x, p0.z);
		segment.b = Vector2(p1.x, p1.z);
		segment.ab = segment.b - segment.a;
		segment.length_sq = segment.ab.length_squared();
		segment.height_a = p0.y;
		segment.height_b = p1.y;
		segment_cache[i] = segment;
	}

	const int GRID_AXIS_LIMIT = 64;
	real_t bounds_width = MAX(max_pt.x - min_pt.x, 0.001f);
	real_t bounds_depth = MAX(max_pt.y - min_pt.y, 0.001f);
	real_t target_cell_extent = MAX((_width * 0.5f) + _feather_radius, 2.0f);
	int grid_cols = CLAMP(int(Math::ceil(bounds_width / target_cell_extent)), 1, GRID_AXIS_LIMIT);
	int grid_rows = CLAMP(int(Math::ceil(bounds_depth / target_cell_extent)), 1, GRID_AXIS_LIMIT);
	real_t cell_size_x = bounds_width / real_t(grid_cols);
	real_t cell_size_y = bounds_depth / real_t(grid_rows);
	real_t inv_cell_size_x = (cell_size_x > CMP_EPSILON) ? (1.0f / cell_size_x) : 0.0f;
	real_t inv_cell_size_y = (cell_size_y > CMP_EPSILON) ? (1.0f / cell_size_y) : 0.0f;
	auto world_to_cell_x = [&](real_t value) -> int {
		if (grid_cols <= 1 || inv_cell_size_x <= 0.0f) {
			return 0;
		}
		real_t normalized = (value - min_pt.x) * inv_cell_size_x;
		int idx = int(Math::floor(normalized));
		return CLAMP(idx, 0, grid_cols - 1);
	};
	auto world_to_cell_y = [&](real_t value) -> int {
		if (grid_rows <= 1 || inv_cell_size_y <= 0.0f) {
			return 0;
		}
		real_t normalized = (value - min_pt.y) * inv_cell_size_y;
		int idx = int(Math::floor(normalized));
		return CLAMP(idx, 0, grid_rows - 1);
	};
	std::vector<std::vector<int>> cell_segments(grid_cols * grid_rows);
	real_t influence_margin = (_width * 0.5f) + _feather_radius + MAX(p_vertex_spacing, 0.01f);
	for (int i = 0; i < segment_count; i++) {
		const CurveSegmentCache &segment = segment_cache[i];
		Vector2 seg_min(MIN(segment.a.x, segment.b.x), MIN(segment.a.y, segment.b.y));
		Vector2 seg_max(MAX(segment.a.x, segment.b.x), MAX(segment.a.y, segment.b.y));
		seg_min.x -= influence_margin;
		seg_min.y -= influence_margin;
		seg_max.x += influence_margin;
		seg_max.y += influence_margin;
		int min_cell_x = world_to_cell_x(seg_min.x);
		int max_cell_x = world_to_cell_x(seg_max.x);
		int min_cell_y = world_to_cell_y(seg_min.y);
		int max_cell_y = world_to_cell_y(seg_max.y);
		for (int cy = min_cell_y; cy <= max_cell_y; cy++) {
			for (int cx = min_cell_x; cx <= max_cell_x; cx++) {
				int cell_index = cy * grid_cols + cx;
				if (cell_index < 0 || cell_index >= int(cell_segments.size())) {
					continue;
				}
				cell_segments[cell_index].push_back(i);
			}
		}
	}
	auto sample_curve = [&](const Vector2 &sample, real_t &out_distance, real_t &out_height) -> bool {
		if (segment_cache.empty()) {
			return _closest_point_on_polyline(sample, out_distance, out_height);
		}
		int cell_x = world_to_cell_x(sample.x);
		int cell_y = world_to_cell_y(sample.y);
		real_t best_distance = Math_INF;
		real_t best_height = 0.0f;
		auto evaluate_cell = [&](int cx, int cy, bool &has_candidates) {
			if (cx < 0 || cy < 0 || cx >= grid_cols || cy >= grid_rows) {
				return;
			}
			const std::vector<int> &candidates = cell_segments[cy * grid_cols + cx];
			if (candidates.empty()) {
				return;
			}
			has_candidates = true;
			for (int seg_idx : candidates) {
				if (seg_idx < 0 || seg_idx >= segment_count) {
					continue;
				}
				const CurveSegmentCache &segment = segment_cache[seg_idx];
				if (segment.length_sq < CMP_EPSILON) {
					real_t dist = (sample - segment.a).length();
					if (dist < best_distance) {
						best_distance = dist;
						best_height = segment.height_a;
					}
					continue;
				}
				Vector2 rel = sample - segment.a;
				real_t t = rel.dot(segment.ab) / segment.length_sq;
				t = CLAMP(t, 0.0f, 1.0f);
				Vector2 projection = segment.a + segment.ab * t;
				real_t dist = (sample - projection).length();
				if (dist < best_distance) {
					best_distance = dist;
					best_height = Math::lerp(segment.height_a, segment.height_b, t);
					if (best_distance <= CMP_EPSILON) {
						return;
					}
				}
			}
		};
		bool has_candidates = false;
		evaluate_cell(cell_x, cell_y, has_candidates);
		if (!has_candidates) {
			for (int radius = 1; radius <= 1 && !has_candidates; radius++) {
				for (int dz = -radius; dz <= radius; dz++) {
					for (int dx = -radius; dx <= radius; dx++) {
						if (dx == 0 && dz == 0) {
							continue;
						}
						evaluate_cell(cell_x + dx, cell_y + dz, has_candidates);
						if (has_candidates && best_distance <= CMP_EPSILON) {
							break;
						}
					}
					if (has_candidates && best_distance <= CMP_EPSILON) {
						break;
					}
				}
			}
		}
		if (!has_candidates) {
			return _closest_point_on_polyline(sample, out_distance, out_height);
		}
		if (best_distance == Math_INF) {
			return false;
		}
		out_distance = best_distance;
		out_height = best_height;
		return true;
	};

	for (int y = 0; y < rect_size.y; y++) {
		for (int x = 0; x < rect_size.x; x++) {
			real_t world_x = (rect_pos.x + x + 0.5f) / pixels_per_meter;
			real_t world_z = (rect_pos.y + y + 0.5f) / pixels_per_meter;
			Vector2 sample(world_x, world_z);
			real_t dist = -1.0f;
			real_t path_height = 0.0f;
			if (!sample_curve(sample, dist, path_height)) {
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
				real_t core = 0.0f;
				if (_falloff_curve.is_valid()) {
					core = CLAMP(_falloff_curve->sample_baked(normalized), 0.0f, 1.0f);
				} else {
					core = 1.0f - smooth_step(0.0f, 1.0f, normalized);
				}
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

			real_t target_height = path_height + _depth;
			_payload->set_pixel(x, y, Color(target_height, 0.0f, 0.0f, 1.0f));
			_alpha->set_pixel(x, y, Color(influence, 0.0f, 0.0f, 1.0f));
		}
	}

	Rect2i region_bounds(Vector2i(), Vector2i(p_region_size, p_region_size));
	Rect2i current_coverage = Rect2i(rect_pos, rect_size);
	Rect2i coverage_clamped = current_coverage.intersection(region_bounds);
	if (!coverage_clamped.has_area()) {
		LOG(WARN, "Curve layer coverage outside region bounds after generation. coverage=", current_coverage, " region_bounds=", region_bounds);
		_payload.unref();
		_alpha.unref();
		set_coverage(Rect2i());
		_cached_region_size = p_region_size;
		_cached_vertex_spacing = p_vertex_spacing;
		_dirty = false;
		return;
	}
	if (coverage_clamped != current_coverage) {
		LOG(DEBUG, "Curve layer clamping coverage from ", current_coverage, " to ", coverage_clamped);
		Ref<Image> trimmed;
		trimmed.instantiate();
		trimmed->create(coverage_clamped.size.x, coverage_clamped.size.y, false, _payload->get_format());
		Rect2i copy_rect(coverage_clamped.position - current_coverage.position, coverage_clamped.size);
		trimmed->blit_rect(_payload, copy_rect, Vector2i());
		_payload = trimmed;
		if (_alpha.is_valid()) {
			Ref<Image> trimmed_alpha;
			trimmed_alpha.instantiate();
			trimmed_alpha->create(coverage_clamped.size.x, coverage_clamped.size.y, false, _alpha->get_format());
			trimmed_alpha->blit_rect(_alpha, copy_rect, Vector2i());
			_alpha = trimmed_alpha;
		}
		set_coverage(coverage_clamped);
		current_coverage = coverage_clamped;
	}
	LOG(DEBUG, "Curve layer final coverage=", current_coverage, " payload_size=", Vector2i(_payload->get_width(), _payload->get_height()));

	_cached_region_size = p_region_size;
	_cached_vertex_spacing = p_vertex_spacing;
	_dirty = false;
}

bool Terrain3DCurveLayer::_closest_point_on_polyline(const Vector2 &p_point, real_t &r_distance, real_t &r_height) const {
	if (_points.size() < 2) {
		r_distance = -1.0f;
		r_height = 0.0f;
		return false;
	}
	real_t best = Math_INF;
	real_t best_height = 0.0f;
	for (int i = 0; i < _points.size() - 1; i++) {
		const Vector3 &p0 = _points[i];
		const Vector3 &p1 = _points[i + 1];
		Vector2 a(p0.x, p0.z);
		Vector2 b(p1.x, p1.z);
		Vector2 ab = b - a;
		real_t len_sq = ab.length_squared();
		if (len_sq < CMP_EPSILON) {
			continue;
		}
		real_t t = ((p_point - a).dot(ab)) / len_sq;
		t = CLAMP(t, 0.0f, 1.0f);
		Vector2 projection = a + ab * t;
		real_t dist = (p_point - projection).length();
		if (dist < best) {
			best = dist;
			best_height = Math::lerp(p0.y, p1.y, t);
		}
	}
	if (best == Math_INF) {
		r_distance = -1.0f;
		r_height = 0.0f;
		return false;
	}
	r_distance = best;
	r_height = best_height;
	return true;
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
	if (!Math::is_equal_approx(_depth, p_depth)) {
		_depth = p_depth;
		mark_dirty();
	}
}

void Terrain3DCurveLayer::set_dual_groove(const bool p_dual) {
	if (_dual_groove != p_dual) {
		_dual_groove = p_dual;
		mark_dirty();
	}
}

void Terrain3DCurveLayer::set_falloff_curve(const Ref<Curve> &p_curve) {
	if (_falloff_curve == p_curve) {
		return;
	}
	_falloff_curve = p_curve;
	mark_dirty();
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
