// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
// A camera-centred water clipmap with no opinions about water.
// Spec: PASTURE3D_WATER_BODIES_SPEC.md §6.2 (the host interface it implements)

#ifndef PASTURE3D_WATER_CLIPMAP_CLASS_H
#define PASTURE3D_WATER_CLIPMAP_CLASS_H

#include <godot_cpp/classes/geometry_instance3d.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/rendering_server.hpp>

#include "constants.h"
#include "pasture_3d_clipmap_host.h"
#include "pasture_3d_mesher.h"
#include "target_node_3d.h"

using namespace godot;

/**
 * The clipmap, on a node that a GDScript body can own.
 *
 * WHY THIS EXISTS AND Pasture3DOcean DOES NOT SERVE. Pasture3DMesher is already host-agnostic --
 * six methods, and Pasture3DOcean answers all of them -- but the interface is a C++ abstract class,
 * and Pasture3DPool is GDScript and cannot implement one. The alternatives were to port the pool to
 * C++, which is most of a thousand lines of authoring logic that has no business being compiled, or
 * to let a pool own an ocean, which cannot work: an ocean joins OCEAN_GROUP and registers itself as
 * a BODY, so a lake containing one would put two overlapping answers into Pasture3DPoolManager's
 * registry and body_at() would start returning the wrong one.
 *
 * So this is the clipmap and nothing else. It has no wave profile, answers no water query, joins no
 * group and registers with nothing. Everything that makes the water water -- the profile, the CPU
 * height query, the shore field, the underwater volume, the material -- stays on the body that owns
 * this, which is the only place it can stay if the two surface modes are to agree.
 *
 * THE MATERIAL IS USED AS GIVEN, not duplicated. That is the one deliberate difference from
 * Pasture3DOcean, which takes a private copy because it is handed a shared preset. Here the owner
 * has ALREADY made a private copy -- it has to, because the shore mask is a sampler2D and cannot be
 * an instance uniform -- so duplicating again would give this node a material the owner could no
 * longer write the field into.
 */
class Pasture3DWaterClipmap : public Node3D, public Pasture3DClipmapHost {
	GDCLASS(Pasture3DWaterClipmap, Node3D);
	CLASS_NAME();

private:
	Pasture3DMesher *_mesher = nullptr;
	bool _is_inside_world = false;

	// Defaults carried from Pasture3DOcean, including water spec §11 q6's reasoning: vertex_spacing
	// and mesh_lods MOVE TOGETHER, because the clipmap is scale-invariant. Halving the spacing
	// halves the reach and one more LOD buys it back.
	int _mesh_lods = 9;
	int _tessellation_level = 0;
	int _mesh_size = 16;
	real_t _vertex_spacing = 1.0f;
	real_t _cull_margin = 20.0f;
	RenderingServer::ShadowCastingSetting _cast_shadows = RenderingServer::SHADOW_CASTING_SETTING_OFF;
	GeometryInstance3D::GIMode _gi_mode = GeometryInstance3D::GI_MODE_DISABLED;
	uint32_t _render_layers = 1u;

	Ref<Material> _material;
	Vector3 _domain_origin = V3_ZERO;
	// Pushed by the owner, which is the only thing that knows the body's level and its wave
	// amplitude. V2_MAX means "not set yet", so the first update always applies.
	Vector2 _height_range = V2_MAX;
	Vector2 _height_range_sent = V2_MAX;

	TargetNode3D _clipmap_target;

	// Held so _setup_mesher() can re-apply them: initialize() resets the mesher to a single view, and
	// every geometry knob on this node calls it.
	TypedArray<Camera3D> _view_cameras;
	PackedInt32Array _view_layers;
	void _apply_views();

	void _setup_mesher();
	void _destroy_mesher(const bool p_final = false);
	void _push_clipmap_uniforms();

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
	Pasture3DWaterClipmap();
	~Pasture3DWaterClipmap();

	// --- Pasture3DClipmapHost ----------------------------------------------
	virtual Vector3 get_clipmap_target_position() const override;
	virtual bool is_clipmap_host_ready() const override { return _is_inside_world; }
	virtual Ref<World3D> get_clipmap_world() const override { return get_world_3d(); }
	virtual bool is_clipmap_visible() const override { return is_visible_in_tree(); }
	virtual real_t get_default_cull_margin() const override { return _cull_margin; }
	virtual Vector2 get_default_height_range() const override { return _height_range; }

	void set_mesh_lods(const int p_count);
	int get_mesh_lods() const { return _mesh_lods; }
	void set_tessellation_level(const int p_level);
	int get_tessellation_level() const { return _tessellation_level; }
	void set_mesh_size(const int p_size);
	int get_mesh_size() const { return _mesh_size; }
	void set_vertex_spacing(const real_t p_spacing);
	real_t get_vertex_spacing() const { return _vertex_spacing; }
	void set_cull_margin(const real_t p_margin);
	real_t get_cull_margin() const { return _cull_margin; }
	void set_cast_shadows(const RenderingServer::ShadowCastingSetting p_cast_shadows);
	RenderingServer::ShadowCastingSetting get_cast_shadows() const { return _cast_shadows; }
	void set_gi_mode(const GeometryInstance3D::GIMode p_gi_mode);
	GeometryInstance3D::GIMode get_gi_mode() const { return _gi_mode; }
	void set_render_layers(const uint32_t p_layers);
	uint32_t get_render_layers() const { return _render_layers; }
	void set_material(const Ref<Material> &p_material);
	Ref<Material> get_material() const { return _material; }
	void set_domain_origin(const Vector3 &p_origin);
	Vector3 get_domain_origin() const { return _domain_origin; }
	void set_clipmap_target(Node3D *p_node);
	// One clipmap view per camera, each on the render layer that camera reads. An EMPTY list means
	// one view following get_clipmap_target_position(), which is the solo / editor path.
	void set_views(const TypedArray<Camera3D> &p_cameras, const PackedInt32Array &p_layers);
	int get_view_count() const;
	Node3D *get_clipmap_target() const { return _clipmap_target.ptr(); }
	// The vertical span the cull volumes must cover, in WORLD y: the body's level plus and minus
	// its wave amplitude. Pushed rather than derived, because the level belongs to the owner's
	// transform and the amplitude to a profile on the manager, and neither is this node's business.
	void set_height_range(const Vector2 &p_range);
	Vector2 get_height_range() const { return _height_range; }

	// Half the width the clipmap reaches from its centre, in metres. The number the owner needs to
	// answer "does this cover my body", and the one water guide §10 spells out by hand.
	real_t get_reach() const;
	// Vertices across every instance of one view. Reported so a bench can assert that the count is
	// a property of the CLIPMAP and not of the body it is drawing.
	int get_vertex_count() const;

	PackedStringArray _get_configuration_warnings() const;
};

#endif // PASTURE3D_WATER_CLIPMAP_CLASS_H
