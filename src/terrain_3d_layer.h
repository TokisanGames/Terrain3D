// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_LAYER_CLASS_H
#define TERRAIN3D_LAYER_CLASS_H

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include "constants.h"
#include "terrain_3d_map.h"

class Terrain3DLayer : public Resource {
	GDCLASS(Terrain3DLayer, Resource);
	CLASS_NAME();

public:
	enum BlendMode {
		BLEND_ADD = 0,
		BLEND_SUBTRACT,
		BLEND_REPLACE,
	};

protected:
	MapType _map_type = TYPE_HEIGHT;
	Rect2i _coverage = Rect2i();
	Ref<Image> _payload;
	Ref<Image> _alpha;
	real_t _intensity = 1.0f;
	real_t _feather_radius = 0.0f;
	bool _enabled = true;
	bool _dirty = true;
	BlendMode _blend_mode = BLEND_ADD;

	int _cached_region_size = 0;
	real_t _cached_vertex_spacing = 0.0f;

protected:
	static void _bind_methods();

	virtual void _generate_payload(const int p_region_size, const real_t p_vertex_spacing);
	void _ensure_payload(const int p_region_size, const real_t p_vertex_spacing);
	real_t _compute_feather_weight(const Vector2i &p_pixel) const;

public:
	Terrain3DLayer() {}
	~Terrain3DLayer() {}

	void set_map_type(const MapType p_type);
	MapType get_map_type() const { return _map_type; }

	void set_enabled(const bool p_enabled);
	bool is_enabled() const { return _enabled; }

	void set_intensity(const real_t p_intensity);
	real_t get_intensity() const { return _intensity; }

	void set_feather_radius(const real_t p_radius);
	real_t get_feather_radius() const { return _feather_radius; }

	void set_blend_mode(const BlendMode p_mode);
	BlendMode get_blend_mode() const { return _blend_mode; }

	void set_coverage(const Rect2i &p_rect);
	Rect2i get_coverage() const { return _coverage; }

	void set_payload(const Ref<Image> &p_image);
	Ref<Image> get_payload() const { return _payload; }

	void set_alpha(const Ref<Image> &p_alpha);
	Ref<Image> get_alpha() const { return _alpha; }

	bool needs_rebuild(const int p_region_size, const real_t p_vertex_spacing) const;

	void apply(Image &p_target, const int p_region_size, const real_t p_vertex_spacing);

	void mark_dirty();
};

VARIANT_ENUM_CAST(Terrain3DLayer::BlendMode);

class Terrain3DStampLayer : public Terrain3DLayer {
	GDCLASS(Terrain3DStampLayer, Terrain3DLayer);
	CLASS_NAME();

protected:
	static void _bind_methods();

public:
	Terrain3DStampLayer() {}
	~Terrain3DStampLayer() {}
};

class Terrain3DCurveLayer : public Terrain3DLayer {
	GDCLASS(Terrain3DCurveLayer, Terrain3DLayer);
	CLASS_NAME();

private:
	PackedVector3Array _points;
	real_t _width = 5.0f;
	real_t _depth = 0.5f;
	bool _dual_groove = false;

protected:
	static void _bind_methods();
	virtual void _generate_payload(const int p_region_size, const real_t p_vertex_spacing) override;

	real_t _distance_to_polyline(const Vector2 &p_point) const;

public:
	Terrain3DCurveLayer() {}
	~Terrain3DCurveLayer() {}

	void set_points(const PackedVector3Array &p_points);
	PackedVector3Array get_points() const { return _points; }

	void set_width(const real_t p_width);
	real_t get_width() const { return _width; }

	void set_depth(const real_t p_depth);
	real_t get_depth() const { return _depth; }

	void set_dual_groove(const bool p_dual);
	bool get_dual_groove() const { return _dual_groove; }
};

class Terrain3DLocalNodeLayer : public Terrain3DLayer {
	GDCLASS(Terrain3DLocalNodeLayer, Terrain3DLayer);
	CLASS_NAME();

private:
	NodePath _source_path;
	Transform3D _local_transform;

protected:
	static void _bind_methods();
	virtual void _generate_payload(const int p_region_size, const real_t p_vertex_spacing) override;

public:
	Terrain3DLocalNodeLayer() {}
	~Terrain3DLocalNodeLayer() {}

	void set_source_path(const NodePath &p_path) { _source_path = p_path; }
	NodePath get_source_path() const { return _source_path; }
	void set_local_transform(const Transform3D &p_transform) { _local_transform = p_transform; mark_dirty(); }
	Transform3D get_local_transform() const { return _local_transform; }
};

#endif // TERRAIN3D_LAYER_CLASS_H
