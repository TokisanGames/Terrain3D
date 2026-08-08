// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "logger.h"
#include "pasture_3d_util.h"
#include "pasture_3d_water_clipmap.h"

///////////////////////////
// Private Functions
///////////////////////////

void Pasture3DWaterClipmap::_setup_mesher() {
	if (!_is_inside_world) {
		return;
	}
	if (!_mesher) {
		_mesher = new Pasture3DMesher();
	}
	// The material AS GIVEN. See the class docstring: the owner already holds a private copy
	// because the shore field is a sampler2D, and a second duplicate here would be a material it
	// could no longer write into.
	// TRUE: per-instance _target_pos, so each split-screen view geomorphs to its own camera. The
	// terrain has always passed true here; Pasture3DOcean passed false and was single-view because
	// of it, which is the bug this fixes rather than a choice either of them made.
	_mesher->initialize(this, _mesh_size, _mesh_lods, _tessellation_level, _vertex_spacing,
			_material.is_valid() ? _material->get_rid() : RID(),
			_render_layers, true, _cast_shadows, _gi_mode);
	// initialize() resets to a single view, so any multi-camera config has to be re-applied -- the
	// same order Pasture3D::_setup_terrain_mesher() uses.
	_apply_views();
	_push_clipmap_uniforms();
	_height_range_sent = V2_MAX;
	if (_height_range != V2_MAX) {
		_mesher->update_aabbs(_cull_margin, _height_range);
		_height_range_sent = _height_range;
	}
}

void Pasture3DWaterClipmap::_destroy_mesher(const bool p_final) {
	if (_mesher) {
		_mesher->destroy();
		if (p_final) {
			delete _mesher;
			_mesher = nullptr;
		}
	}
}

void Pasture3DWaterClipmap::_push_clipmap_uniforms() {
	ShaderMaterial *mat = Object::cast_to<ShaderMaterial>(_material.ptr());
	if (mat) {
		// Read by the clipmap geomorph in water_surface.gdshaderinc. Written here and not by the
		// owner because they describe THIS clipmap's lattice, and the owner does not choose it.
		mat->set_shader_parameter("_mesh_size", _mesh_size);
		mat->set_shader_parameter("_vertex_spacing", _vertex_spacing);
		mat->set_shader_parameter("_subdiv", Math::pow(2.f, (real_t)_tessellation_level));
	}
	if (_mesher) {
		// An instance uniform since water spec Phase 1, so it cannot go on the material.
		_mesher->set_instance_shader_param("_water_domain_origin", _domain_origin);
	}
}

///////////////////////////
// Public Functions
///////////////////////////

Pasture3DWaterClipmap::Pasture3DWaterClipmap() {
	set_notify_transform(false); // the sheet is world-anchored; this node's transform means nothing
}

Pasture3DWaterClipmap::~Pasture3DWaterClipmap() {
	_destroy_mesher(true);
}

Vector3 Pasture3DWaterClipmap::get_clipmap_target_position() const {
	Node3D *target = _clipmap_target.ptr();
	if (target && target->is_inside_tree()) {
		return target->get_global_position();
	}
	// No explicit target: the current camera, which in the editor is the editor's viewport camera.
	// A body whose clipmap centred on itself instead would draw a ring of water around its origin
	// and nothing where the user is looking, so this fallback is load-bearing for authoring, not a
	// convenience.
	Viewport *vp = get_viewport();
	if (vp) {
		Camera3D *cam = vp->get_camera_3d();
		if (cam) {
			return cam->get_global_position();
		}
	}
	return get_global_position();
}

void Pasture3DWaterClipmap::set_mesh_lods(const int p_count) {
	int lods = CLAMP(p_count, 1, 10);
	SET_IF_DIFF(_mesh_lods, lods);
	_setup_mesher();
}

void Pasture3DWaterClipmap::set_tessellation_level(const int p_level) {
	int level = CLAMP(p_level, 0, 3);
	SET_IF_DIFF(_tessellation_level, level);
	_setup_mesher();
}

void Pasture3DWaterClipmap::set_mesh_size(const int p_size) {
	// Even, and at least 8: the mesher's edge and trim strips are sized as mesh_size * 4 + n and
	// assume the tile grid can be halved. Same clamp Pasture3DOcean applies.
	int size = CLAMP(p_size, 8, 256);
	size -= size % 2;
	SET_IF_DIFF(_mesh_size, size);
	_setup_mesher();
}

void Pasture3DWaterClipmap::set_vertex_spacing(const real_t p_spacing) {
	real_t spacing = CLAMP(p_spacing, 0.05f, 64.f);
	SET_IF_DIFF(_vertex_spacing, spacing);
	_setup_mesher();
}

void Pasture3DWaterClipmap::set_cull_margin(const real_t p_margin) {
	SET_IF_DIFF(_cull_margin, MAX(p_margin, 0.f));
	_height_range_sent = V2_MAX;
}

void Pasture3DWaterClipmap::set_cast_shadows(const RenderingServer::ShadowCastingSetting p_cast_shadows) {
	SET_IF_DIFF(_cast_shadows, p_cast_shadows);
	_setup_mesher();
}

void Pasture3DWaterClipmap::set_gi_mode(const GeometryInstance3D::GIMode p_gi_mode) {
	SET_IF_DIFF(_gi_mode, p_gi_mode);
	_setup_mesher();
}

void Pasture3DWaterClipmap::set_render_layers(const uint32_t p_layers) {
	SET_IF_DIFF(_render_layers, p_layers);
	if (_mesher) {
		_mesher->set_render_layers(_render_layers);
		_mesher->update();
	}
}

void Pasture3DWaterClipmap::set_material(const Ref<Material> &p_material) {
	SET_IF_DIFF(_material, p_material);
	_setup_mesher();
}

void Pasture3DWaterClipmap::set_domain_origin(const Vector3 &p_origin) {
	SET_IF_DIFF(_domain_origin, p_origin);
	_push_clipmap_uniforms();
}

void Pasture3DWaterClipmap::set_clipmap_target(Node3D *p_node) {
	_clipmap_target.set_target(p_node);
	if (_mesher) {
		_mesher->reset_target_position();
	}
}

void Pasture3DWaterClipmap::set_views(const TypedArray<Camera3D> &p_cameras,
		const PackedInt32Array &p_layers) {
	_view_cameras = p_cameras;
	_view_layers = p_layers;
	_apply_views();
}

int Pasture3DWaterClipmap::get_view_count() const {
	return _mesher ? _mesher->get_view_count() : 0;
}

int Pasture3DWaterClipmap::get_in_range_view_count() const {
	return _mesher ? _mesher->get_in_range_view_count() : 0;
}

bool Pasture3DWaterClipmap::is_view_in_range(const int p_view) const {
	return _mesher ? _mesher->is_view_in_range(p_view) : false;
}

void Pasture3DWaterClipmap::set_body_bounds(const Rect2 &p_world_xz) {
	_body_bounds = p_world_xz;
	// Not applied here. snap() re-asks every frame, so the next physics tick picks this up -- and
	// applying it here would mean deciding a view's visibility from a target that has not been
	// resolved, which is exactly the kind of half-state that leaves a lake hidden.
}

void Pasture3DWaterClipmap::set_cull_views(const bool p_cull) {
	if (_cull_views == p_cull) {
		return;
	}
	_cull_views = p_cull;
	// Switching it OFF has to take effect without waiting for a camera to move, because the reason
	// somebody switches it off is that water is missing and they want it back now. snap() re-asks and
	// un-hides on the next tick; forcing a re-ask here makes that immediate.
	if (_mesher) {
		_mesher->snap();
	}
}

/**
 * How far outside the body's footprint a view's target may sit and still be admitted.
 *
 * PROVABLY conservative, and it has to be: hiding a view that could have drawn something is
 * invisible water, which is a far worse failure than drawing water nobody can see.
 *
 *   the rings span get_reach() from their snapped centre, and
 *   the snapped centre is within one COARSEST snap step of the target -- _snap_view rounds LOD n to
 *   2^(n+1) * spacing, so the outermost ring's step is 2^mesh_lods * spacing.
 *
 * A target further than the sum from the padded footprint therefore has no vertex that can land
 * inside it. Nothing was being drawn there, so hiding the view changes no pixel -- which is the
 * claim bench/WaterTwoLakesGate.gd criterion H sweeps a camera across to check.
 */
real_t Pasture3DWaterClipmap::_view_cull_slack() const {
	const real_t spacing = _vertex_spacing / Math::pow(2.f, (real_t)_tessellation_level);
	return get_reach() + Math::pow(2.f, (real_t)_mesh_lods) * spacing;
}

bool Pasture3DWaterClipmap::is_clipmap_view_in_range(const Vector2 &p_target_xz) const {
	// Never told where the body is, or told not to cull: admit everything. Both are the behaviour
	// this node had before per-view culling existed.
	if (!_cull_views || _body_bounds.size.x <= 0.f || _body_bounds.size.y <= 0.f) {
		return true;
	}
	return _body_bounds.grow(_view_cull_slack()).has_point(p_target_xz);
}

void Pasture3DWaterClipmap::_apply_views() {
	if (!_mesher) {
		return;
	}
	Vector<uint64_t> ids;
	Vector<uint32_t> layers;
	for (int i = 0; i < _view_cameras.size(); i++) {
		Camera3D *cam = Object::cast_to<Camera3D>(_view_cameras[i]);
		if (!cam) {
			continue;
		}
		ids.push_back(cam->get_instance_id());
		// The layer the OWNER sent, not one derived here. Camera i's cull_mask contains exactly one
		// reserved bit and the terrain already put its own view on it; picking a different bit would
		// make this water invisible to that camera or visible to all of them.
		layers.push_back(i < _view_layers.size() ? (uint32_t)_view_layers[i] : _render_layers);
	}
	_mesher->set_views(ids, layers);
	// set_views() re-created the instances, so anything written per-instance is gone with them.
	_push_clipmap_uniforms();
	if (_height_range != V2_MAX) {
		_mesher->update_aabbs(_cull_margin, _height_range);
		_height_range_sent = _height_range;
	}
}

void Pasture3DWaterClipmap::set_height_range(const Vector2 &p_range) {
	SET_IF_DIFF(_height_range, p_range);
	if (_mesher && _height_range != _height_range_sent) {
		_mesher->update_aabbs(_cull_margin, _height_range);
		_height_range_sent = _height_range;
	}
}

/**
 * Half-extent, in metres. Water guide §10 gives the same formula by hand:
 * 2 * mesh_size * vertex_spacing * 2^(mesh_lods - 1), with the tessellation level dividing the
 * spacing. The owner needs it to decide whether the clipmap covers its body at all.
 */
real_t Pasture3DWaterClipmap::get_reach() const {
	const real_t spacing = _vertex_spacing / Math::pow(2.f, (real_t)_tessellation_level);
	return 2.f * (real_t)_mesh_size * spacing * Math::pow(2.f, (real_t)(_mesh_lods - 1));
}

/**
 * Vertices across one view's instances, from the mesh shapes the mesher builds.
 *
 * Derived rather than read back off the RenderingServer, which does not offer the question. The
 * shapes are fixed by mesh_size and the LOD count, which is the point being made: this number does
 * not know how large the body is.
 */
int Pasture3DWaterClipmap::get_vertex_count() const {
	const int m = _mesh_size;
	const int tile = (m + 1) * (m + 1);
	const int edge_a = 3 * (m * 4 + 8 + 1);
	const int edge_b = (m * 4 + 4 + 1) * 3;
	const int fill_a = 5 * (m + 1);
	const int fill_b = (m + 1) * 5;
	const int trim_a = 3 * (m * 4 + 2 + 1);
	const int trim_b = (m * 4 + 2 + 1) * 3;
	int total = 0;
	for (int level = 0; level < _mesh_lods + _tessellation_level; level++) {
		total += (level == 0 ? 16 : 12) * tile;
		total += 2 * edge_a + 2 * edge_b;
		total += (level == 0) ? (2 * trim_a + 2 * trim_b) : (2 * fill_a + 2 * fill_b);
	}
	return total;
}

PackedStringArray Pasture3DWaterClipmap::_get_configuration_warnings() const {
	PackedStringArray warnings;
	// This node is created and driven by a water body. One placed by hand draws nothing and gives
	// no clue why, because every input it needs comes from an owner it does not have.
	if (_material.is_null()) {
		warnings.push_back("No material. Pasture3DWaterClipmap is driven by a water body — add a "
						   "Pasture3DPool and set its surface_mode rather than placing this by hand.");
	}
	return warnings;
}

///////////////////////////
// Protected Functions
///////////////////////////

void Pasture3DWaterClipmap::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_ENTER_WORLD: {
			_is_inside_world = true;
			_setup_mesher();
			set_physics_process(true);
			break;
		}

		case NOTIFICATION_EXIT_WORLD: {
			_is_inside_world = false;
			_destroy_mesher(false);
			set_physics_process(false);
			break;
		}

		case NOTIFICATION_PREDELETE: {
			_destroy_mesher(true);
			break;
		}

		case NOTIFICATION_VISIBILITY_CHANGED: {
			if (_mesher) {
				_mesher->update();
			}
			break;
		}

		case NOTIFICATION_PHYSICS_PROCESS: {
			if (_mesher) {
				// The rings re-centre on the target. snap() early-outs on its own when the target
				// has not moved a whole cell, so this is cheap on a still camera.
				_mesher->snap();
			}
			break;
		}

		default:
			break;
	}
}

void Pasture3DWaterClipmap::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_mesh_lods", "count"), &Pasture3DWaterClipmap::set_mesh_lods);
	ClassDB::bind_method(D_METHOD("get_mesh_lods"), &Pasture3DWaterClipmap::get_mesh_lods);
	ClassDB::bind_method(D_METHOD("set_tessellation_level", "level"), &Pasture3DWaterClipmap::set_tessellation_level);
	ClassDB::bind_method(D_METHOD("get_tessellation_level"), &Pasture3DWaterClipmap::get_tessellation_level);
	ClassDB::bind_method(D_METHOD("set_mesh_size", "size"), &Pasture3DWaterClipmap::set_mesh_size);
	ClassDB::bind_method(D_METHOD("get_mesh_size"), &Pasture3DWaterClipmap::get_mesh_size);
	ClassDB::bind_method(D_METHOD("set_vertex_spacing", "spacing"), &Pasture3DWaterClipmap::set_vertex_spacing);
	ClassDB::bind_method(D_METHOD("get_vertex_spacing"), &Pasture3DWaterClipmap::get_vertex_spacing);
	ClassDB::bind_method(D_METHOD("set_cull_margin", "margin"), &Pasture3DWaterClipmap::set_cull_margin);
	ClassDB::bind_method(D_METHOD("get_cull_margin"), &Pasture3DWaterClipmap::get_cull_margin);
	ClassDB::bind_method(D_METHOD("set_render_layers", "layers"), &Pasture3DWaterClipmap::set_render_layers);
	ClassDB::bind_method(D_METHOD("get_render_layers"), &Pasture3DWaterClipmap::get_render_layers);
	ClassDB::bind_method(D_METHOD("set_material", "material"), &Pasture3DWaterClipmap::set_material);
	ClassDB::bind_method(D_METHOD("get_material"), &Pasture3DWaterClipmap::get_material);
	ClassDB::bind_method(D_METHOD("set_domain_origin", "origin"), &Pasture3DWaterClipmap::set_domain_origin);
	ClassDB::bind_method(D_METHOD("get_domain_origin"), &Pasture3DWaterClipmap::get_domain_origin);
	ClassDB::bind_method(D_METHOD("set_clipmap_target", "node"), &Pasture3DWaterClipmap::set_clipmap_target);
	ClassDB::bind_method(D_METHOD("get_clipmap_target"), &Pasture3DWaterClipmap::get_clipmap_target);
	ClassDB::bind_method(D_METHOD("set_height_range", "range"), &Pasture3DWaterClipmap::set_height_range);
	ClassDB::bind_method(D_METHOD("get_height_range"), &Pasture3DWaterClipmap::get_height_range);
	ClassDB::bind_method(D_METHOD("set_views", "cameras", "layers"), &Pasture3DWaterClipmap::set_views);
	ClassDB::bind_method(D_METHOD("get_view_count"), &Pasture3DWaterClipmap::get_view_count);
	ClassDB::bind_method(D_METHOD("get_in_range_view_count"), &Pasture3DWaterClipmap::get_in_range_view_count);
	ClassDB::bind_method(D_METHOD("is_view_in_range", "view"), &Pasture3DWaterClipmap::is_view_in_range);
	ClassDB::bind_method(D_METHOD("set_body_bounds", "world_xz"), &Pasture3DWaterClipmap::set_body_bounds);
	ClassDB::bind_method(D_METHOD("get_body_bounds"), &Pasture3DWaterClipmap::get_body_bounds);
	ClassDB::bind_method(D_METHOD("set_cull_views", "cull"), &Pasture3DWaterClipmap::set_cull_views);
	ClassDB::bind_method(D_METHOD("get_cull_views"), &Pasture3DWaterClipmap::get_cull_views);
	ClassDB::bind_method(D_METHOD("get_view_cull_radius"), &Pasture3DWaterClipmap::get_view_cull_radius);
	ClassDB::bind_method(D_METHOD("get_reach"), &Pasture3DWaterClipmap::get_reach);
	ClassDB::bind_method(D_METHOD("get_vertex_count"), &Pasture3DWaterClipmap::get_vertex_count);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_lods", PROPERTY_HINT_RANGE, "1,10,1"), "set_mesh_lods", "get_mesh_lods");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_size", PROPERTY_HINT_RANGE, "8,256,2"), "set_mesh_size", "get_mesh_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "tessellation_level", PROPERTY_HINT_RANGE, "0,3,1"), "set_tessellation_level", "get_tessellation_level");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "vertex_spacing", PROPERTY_HINT_RANGE, "0.05,64.0,0.01"), "set_vertex_spacing", "get_vertex_spacing");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "cull_margin", PROPERTY_HINT_RANGE, "0.0,500.0,1.0"), "set_cull_margin", "get_cull_margin");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "render_layers", PROPERTY_HINT_LAYERS_3D_RENDER), "set_render_layers", "get_render_layers");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "material", PROPERTY_HINT_RESOURCE_TYPE, "Material"), "set_material", "get_material");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "domain_origin"), "set_domain_origin", "get_domain_origin");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "height_range"), "set_height_range", "get_height_range");
}
