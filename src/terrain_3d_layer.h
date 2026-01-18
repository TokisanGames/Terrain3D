// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_LAYER_CLASS_H
#define TERRAIN3D_LAYER_CLASS_H

#include <cstdint>

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/resource.hpp>

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

	real_t _cached_vertex_spacing = 0.0f;
	uint64_t _group_id = 0;
	bool _user_editable = true;

protected:
	static void _bind_methods();

	virtual void _generate_payload(const real_t p_vertex_spacing);
	void _ensure_payload(const real_t p_vertex_spacing);
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

	void set_group_id(const uint64_t p_group_id);
	uint64_t get_group_id() const { return _group_id; }

	void set_user_editable(bool p_editable);
	bool is_user_editable() const { return _user_editable; }

	bool needs_rebuild(const real_t p_vertex_spacing) const;

	void apply(Image &p_target, const real_t p_vertex_spacing);
	void apply_rect(Image &p_target, const real_t p_vertex_spacing, const Rect2i &p_rect);

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

#endif // TERRAIN3D_LAYER_CLASS_H
