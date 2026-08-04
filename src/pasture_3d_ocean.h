// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
// The infinite clipmap ocean, extracted from Pasture3D.
// Spec: PASTURE3D_WATER_BODIES_SPEC.md §6

#ifndef PASTURE3D_OCEAN_CLASS_H
#define PASTURE3D_OCEAN_CLASS_H

#include <godot_cpp/classes/geometry_instance3d.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/rendering_server.hpp>

#include "constants.h"
#include "pasture_3d_clipmap_host.h"
#include "pasture_3d_mesher.h"
#include "target_node_3d.h"

using namespace godot;

class Pasture3DPoolManager;

/**
 * An ocean, on its own node, owning its own clipmap.
 *
 * Everything here used to be `ocean_*` on Pasture3D, which made the ocean a feature
 * of the terrain: you could not have one without the other, the ocean's wave table
 * was the only wave table in the project, and a lake had no way to reach any of the
 * machinery the ocean was sitting on. Splitting it out is what lets Pasture3DPool exist.
 *
 * Two things changed on the way out, both of them improvements that fall out of
 * having a node at all rather than features anyone asked for:
 *
 *   - SEA LEVEL IS THE NODE'S Y. The clipmap sheet is built flat at y=0 and the
 *     shader lifts it to the `sea_level` uniform; with a node in the picture,
 *     global_position.y is the obvious source and the uniform becomes
 *     plugin-written. This retires the water guide's troubleshooting entry about
 *     setting sea_level from code and having the ocean vanish.
 *   - THE WAVES COME FROM A PROFILE. `wave_profile` names one on the Pasture3DPoolManager,
 *     so the ocean is now just another water body that happens to be infinite.
 *
 * It implements Pasture3DClipmapHost, so Pasture3DMesher serves it and the terrain
 * identically. It needs no Pasture3D in the scene (spec W4).
 */
class Pasture3DOcean : public Node3D, public Pasture3DClipmapHost {
	GDCLASS(Pasture3DOcean, Node3D);
	CLASS_NAME();

public: // Constants
	// So a scene can find its ocean without a NodePath to it -- the replacement for
	// asking the terrain whether `ocean_enabled` was set. A `const char *` and not a
	// StringName: see the note on Pasture3DPoolManager::MANAGER_GROUP for what a StringName
	// built at static-initialisation time does to the DLL.
	static constexpr const char *OCEAN_GROUP = "pasture3d_ocean";

private:
	Pasture3DMesher *_mesher = nullptr;
	bool _enabled = true;
	bool _is_inside_world = false;

	// Geometry. Defaults carried over verbatim from Pasture3D, including the
	// reasoning in water spec §11 q6: vertex_spacing and mesh_lods MOVE TOGETHER,
	// because the clipmap is scale-invariant. Halving the spacing halves the reach
	// and one more LOD buys it back.
	int _mesh_lods = 9;
	int _tessellation_level = 0;
	int _mesh_size = 16;
	real_t _vertex_spacing = 1.0f;
	real_t _cull_margin = 20.0f;
	RenderingServer::ShadowCastingSetting _cast_shadows = RenderingServer::SHADOW_CASTING_SETTING_OFF;
	GeometryInstance3D::GIMode _gi_mode = GeometryInstance3D::GI_MODE_DISABLED;
	uint32_t _render_layers = 1u;

	Ref<Material> _material;
	// The instance this node actually draws with: a private duplicate of _material
	// with the profile's table uploaded into it. NOT the manager's shared cache --
	// the clipmap writes _mesh_size, _vertex_spacing, _subdiv, _target_pos and
	// sea_level into its material, and those are properties of THIS ocean, so a
	// material shared with a pool would be fought over.
	Ref<Material> _runtime_material;
	StringName _wave_profile = "ocean_default";
	Vector3 _domain_origin = V3_ZERO;

	TargetNode3D _clipmap_target;

	// Last height range applied to the cull AABB (water spec §4.5). Polled rather
	// than pushed because sea level is this node's transform and the amplitude sum
	// belongs to a profile on another node, and neither emits anything this can
	// hang off cheaply.
	Vector2 _height_range_sent = V2_MAX;
	real_t _sea_level_sent = FLT_MAX;

	// Has this ocean handed itself to a manager yet? Sibling ENTER_TREE order decides
	// whether there was one to hand itself to, so the attempt is retried on the physics
	// tick until it lands rather than being made once and lost. See
	// _try_register_with_manager().
	bool _manager_registered = false;

	Pasture3DPoolManager *_find_manager() const;
	void _try_register_with_manager();
	void _setup_mesher();
	void _destroy_mesher(const bool p_final = false);
	void _rebuild_runtime_material();
	void _poll_base_material();
	void _push_clipmap_uniforms();
	void _update_aabbs(const bool p_force = false);
	void _on_profiles_changed();

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
	Pasture3DOcean();
	~Pasture3DOcean();

	// --- Pasture3DClipmapHost ----------------------------------------------
	virtual Vector3 get_clipmap_target_position() const override;
	virtual bool is_clipmap_host_ready() const override { return _is_inside_world; }
	virtual Ref<World3D> get_clipmap_world() const override { return get_world_3d(); }
	virtual bool is_clipmap_visible() const override { return is_visible_in_tree(); }
	virtual real_t get_default_cull_margin() const override { return _cull_margin; }
	virtual Vector2 get_default_height_range() const override;

	void set_enabled(const bool p_enabled);
	bool is_enabled() const { return _enabled; }
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
	void set_wave_profile(const StringName &p_name);
	StringName get_wave_profile() const { return _wave_profile; }
	void set_domain_origin(const Vector3 &p_origin);
	Vector3 get_domain_origin() const { return _domain_origin; }
	void set_clipmap_target(Node3D *p_node);
	Node3D *get_clipmap_target() const { return _clipmap_target.ptr(); }

	// The undisplaced sheet's height: this node's Y. Written to the material's
	// sea_level uniform, and added to every CPU query.
	real_t get_sea_level() const { return get_global_position().y; }

	// --- CPU water query (water spec §4.3, G4) ------------------------------
	// Same three signatures Pasture3D carried, same contract, now answered from the
	// profile the manager holds rather than from a wave table this node owns.
	real_t get_water_height(const Vector2 &p_xz) const;
	Vector3 get_water_normal(const Vector2 &p_xz) const;
	Vector3 get_water_surface_point(const Vector2 &p_domain_xz) const;
	real_t get_water_time() const;

	// Body-registry contract (spec §5.5). Unbounded horizontally, so this is a
	// vertical test against the wave surface.
	bool contains_point(const Vector3 &p_global_pos) const;

	PackedStringArray _get_configuration_warnings() const;
};

#endif // PASTURE3D_OCEAN_CLASS_H
