// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/core/version.hpp>

#include "logger.h"
#include "pasture_3d.h"
#include "pasture_3d_mesher.h"

///////////////////////////
// Private Functions
///////////////////////////

void Pasture3DMesher::_generate_mesh_types() {
	_clear_mesh_types();
	LOG(INFO, "Generating all Mesh segments for clipmap of size ", _mesh_size);
	// Create initial set of Mesh blocks to build the clipmap
	// # 0 TILE - mesh_size x mesh_size tiles
	_mesh_rids.push_back(_generate_mesh(V2I(_mesh_size)));
	// # 1 EDGE_A - 2 by (mesh_size * 4 + 8) strips to bridge LOD transitions along +-Z axis
	_mesh_rids.push_back(_generate_mesh(Vector2i(2, _mesh_size * 4 + 8)));
	// # 2 EDGE_B - (mesh_size * 4 + 4) by 2 strips to bridge LOD transitions along +-X axis
	_mesh_rids.push_back(_generate_mesh(Vector2i(_mesh_size * 4 + 4, 2)));
	// # 3 FILL_A - 4 by mesh_size
	_mesh_rids.push_back(_generate_mesh(Vector2i(4, _mesh_size)));
	// # 4 FILL_B - mesh_size by 4
	_mesh_rids.push_back(_generate_mesh(Vector2i(_mesh_size, 4)));
	// # 5 STANDARD_TRIM_A - 2 by (mesh_size * 4 + 2) strips for LOD0 +-Z axis edge
	_mesh_rids.push_back(_generate_mesh(Vector2i(2, _mesh_size * 4 + 2), true));
	// # 6 STANDARD_TRIM_B - (mesh_size * 4 + 2) by 2 strips for LOD0 +-X axis edge
	_mesh_rids.push_back(_generate_mesh(Vector2i(_mesh_size * 4 + 2, 2), true));
	// # 7 STANDARD_TILE - mesh_size x mesh_size tiles
	_mesh_rids.push_back(_generate_mesh(Vector2i(_mesh_size, _mesh_size), true));
	// # 8 STANDARD_EDGE_A - 2 by (mesh_size * 4 + 8) strips to bridge LOD transitions along +-Z axis
	_mesh_rids.push_back(_generate_mesh(Vector2i(2, _mesh_size * 4 + 8), true));
	// # 9 STANDARD_EDGE_B - (mesh_size * 4 + 4) by 2 strips to bridge LOD transitions along +-X axis
	_mesh_rids.push_back(_generate_mesh(Vector2i(_mesh_size * 4 + 4, 2), true));
	return;
}

RID Pasture3DMesher::_generate_mesh(const Vector2i &p_size, const bool p_standard_grid) {
	PackedVector3Array vertices;
	PackedInt32Array indices;
	AABB aabb = AABB(V3_ZERO, Vector3(p_size.x, 0.1f, p_size.y));
	LOG(DEBUG, "Generating verticies and indices for a", p_standard_grid ? " symmetric " : " standard ", "grid mesh of width: ", p_size.x, " and height: ", p_size.y);

	// Generate vertices
	for (int y = 0; y <= p_size.y; ++y) {
		for (int x = 0; x <= p_size.x; ++x) {
			// Match GDScript vertex definitions
			vertices.push_back(Vector3(x, 0.f, y)); // bottom-left
		}
	}

	// Generate indices for quads with alternating diagonals
	for (int y = 0; y < p_size.y; ++y) {
		for (int x = 0; x < p_size.x; ++x) {
			int bottomLeft = y * (p_size.x + 1) + x;
			int bottomRight = bottomLeft + 1;
			int topLeft = (y + 1) * (p_size.x + 1) + x;
			int topRight = topLeft + 1;

			if ((x + y) % 2 == 0 || p_standard_grid) {
				indices.push_back(bottomLeft);
				indices.push_back(topRight);
				indices.push_back(topLeft);

				indices.push_back(bottomLeft);
				indices.push_back(bottomRight);
				indices.push_back(topRight);
			} else {
				indices.push_back(bottomLeft);
				indices.push_back(bottomRight);
				indices.push_back(topLeft);

				indices.push_back(topLeft);
				indices.push_back(bottomRight);
				indices.push_back(topRight);
			}
		}
	}

	return _instantiate_mesh(vertices, indices, aabb);
}

RID Pasture3DMesher::_instantiate_mesh(const PackedVector3Array &p_vertices, const PackedInt32Array &p_indices, const AABB &p_aabb) {
	Array arrays;
	arrays.resize(RenderingServer::ARRAY_MAX);
	arrays[RenderingServer::ARRAY_VERTEX] = p_vertices;
	arrays[RenderingServer::ARRAY_INDEX] = p_indices;

	PackedVector3Array normals;
	normals.resize(p_vertices.size());
	normals.fill(V3_UP);
	arrays[RenderingServer::ARRAY_NORMAL] = normals;

	PackedFloat32Array tangents;
	tangents.resize(p_vertices.size() * 4);
	tangents.fill(0.0f);
	arrays[RenderingServer::ARRAY_TANGENT] = tangents;

	LOG(DEBUG, "Creating mesh via the Rendering server");
	RID mesh = RS->mesh_create();
	RS->mesh_add_surface_from_arrays(mesh, RenderingServer::PRIMITIVE_TRIANGLES, arrays);

	LOG(DEBUG, "Setting custom aabb: ", p_aabb.position, ", ", p_aabb.size);
	RS->mesh_set_custom_aabb(mesh, p_aabb);
	RS->mesh_surface_set_material(mesh, 0, _material.is_valid() ? _material : RID());

	return mesh;
}

// Builds one clipmap instance-set (one view / camera) from the shared _mesh_rids.
// Mesh resources and offset data must already exist (see initialize()).
void Pasture3DMesher::_generate_view_instances(ClipmapView &p_view) {
	p_view.clipmap_rids.clear();
	p_view.instance_rids.clear();
	LOG(DEBUG, "Creating instances for all mesh segments for clipmap of size ", _mesh_size, " for ", _lods, " LODs");
	for (int level = 0; level < _lods + _tessellation_level; level++) {
		Array lod;
		// 12 Tiles LOD1+, 16 for LOD0
		Array tile_rids;
		int tile_amount = (level == 0) ? 16 : 12;

		for (int i = 0; i < tile_amount; i++) {
			RID tile_rid = RS->instance_create2(_mesh_rids[level == 0 ? STANDARD_TILE : TILE], _scenario);
			tile_rids.append(tile_rid);
		}
		lod.append(tile_rids); // index 0 TILE

		// 4 Edges present on all LODs
		Array edge_a_rids;
		for (int i = 0; i < 2; i++) {
			RID edge_a_rid = RS->instance_create2(_mesh_rids[level == 0 ? STANDARD_EDGE_A : EDGE_A], _scenario);
			edge_a_rids.append(edge_a_rid);
		}
		lod.append(edge_a_rids); // index 1 EDGE_A

		Array edge_b_rids;
		for (int i = 0; i < 2; i++) {
			RID edge_b_rid = RS->instance_create2(_mesh_rids[level == 0 ? STANDARD_EDGE_B : EDGE_B], _scenario);
			edge_b_rids.append(edge_b_rid);
		}
		lod.append(edge_b_rids); // index 2 EDGE_B

		// Fills only present on LODs 1+
		if (level > 0) {
			Array fill_a_rids;
			for (int i = 0; i < 2; i++) {
				RID fill_a_rid = RS->instance_create2(_mesh_rids[FILL_A], _scenario);
				fill_a_rids.append(fill_a_rid);
			}
			lod.append(fill_a_rids); // index 4 FILL_A

			Array fill_b_rids;
			for (int i = 0; i < 2; i++) {
				RID fill_b_rid = RS->instance_create2(_mesh_rids[FILL_B], _scenario);
				fill_b_rids.append(fill_b_rid);
			}
			lod.append(fill_b_rids); // index 5 FILL_B
			// Trims only on LOD 0 These share the indices of the fills for the offsets.
			// When snapping LOD 0 Trim a/b positions are looked up instead of Fill a/b
		} else {
			Array trim_a_rids;
			for (int i = 0; i < 2; i++) {
				RID trim_a_rid = RS->instance_create2(_mesh_rids[STANDARD_TRIM_A], _scenario);
				trim_a_rids.append(trim_a_rid);
			}
			lod.append(trim_a_rids); // index 4 TRIM_A

			Array trim_b_rids;
			for (int i = 0; i < 2; i++) {
				RID trim_b_rid = RS->instance_create2(_mesh_rids[STANDARD_TRIM_B], _scenario);
				trim_b_rids.append(trim_b_rid);
			}
			lod.append(trim_b_rids); // index 5 TRIM_B
		}

		// Append LOD to this view's instance array
		p_view.clipmap_rids.append(lod);
	}

	// Flatten into a fast lookup list for per-frame updates (target_pos, layers, shadows).
	for (const Array &lod_array : p_view.clipmap_rids) {
		for (const Array &mesh_array : lod_array) {
			for (const RID &rid : mesh_array) {
				p_view.instance_rids.push_back(rid);
			}
		}
	}
}

// Precomputes all instance offset data into lookup arrays that match created instances.
// All meshes are created with 0,0 as their origin and grow along +xz. Offsets account for this.
void Pasture3DMesher::_generate_offset_data() {
	LOG(INFO, "Computing all clipmap instance positioning offsets");
	_tile_pos_lod_0.clear();
	_trim_a_pos.clear();
	_trim_b_pos.clear();
	_edge_pos.clear();
	_fill_a_pos.clear();
	_fill_b_pos.clear();
	_tile_pos.clear();

	// LOD0 Tiles: Full 4x4 Grid of mesh size tiles
	_tile_pos_lod_0.push_back(Vector3(0, 0, _mesh_size));
	_tile_pos_lod_0.push_back(Vector3(_mesh_size, 0, _mesh_size));
	_tile_pos_lod_0.push_back(Vector3(_mesh_size, 0, 0));
	_tile_pos_lod_0.push_back(Vector3(_mesh_size, 0, -_mesh_size));
	_tile_pos_lod_0.push_back(Vector3(_mesh_size, 0, -_mesh_size * 2));
	_tile_pos_lod_0.push_back(Vector3(0, 0, -_mesh_size * 2));
	_tile_pos_lod_0.push_back(Vector3(-_mesh_size, 0, -_mesh_size * 2));
	_tile_pos_lod_0.push_back(Vector3(-_mesh_size * 2, 0, -_mesh_size * 2));
	_tile_pos_lod_0.push_back(Vector3(-_mesh_size * 2, 0, -_mesh_size));
	_tile_pos_lod_0.push_back(Vector3(-_mesh_size * 2, 0, 0));
	_tile_pos_lod_0.push_back(Vector3(-_mesh_size * 2, 0, _mesh_size));
	_tile_pos_lod_0.push_back(Vector3(-_mesh_size, 0, _mesh_size));
	// Inner tiles
	_tile_pos_lod_0.push_back(V3_ZERO);
	_tile_pos_lod_0.push_back(Vector3(-_mesh_size, 0, 0));
	_tile_pos_lod_0.push_back(Vector3(0, 0, -_mesh_size));
	_tile_pos_lod_0.push_back(Vector3(-_mesh_size, 0, -_mesh_size));

	// LOD0 Trims: Fixed 2 unit wide ring around LOD0 tiles.
	_trim_a_pos.push_back(Vector3(_mesh_size * 2, 0, -_mesh_size * 2));
	_trim_a_pos.push_back(Vector3(-_mesh_size * 2 - 2, 0, -_mesh_size * 2 - 2));
	_trim_b_pos.push_back(Vector3(-_mesh_size * 2, 0, -_mesh_size * 2 - 2));
	_trim_b_pos.push_back(Vector3(-_mesh_size * 2 - 2, 0, _mesh_size * 2));

	// LOD1+: 4x4 Ring of mesh size tiles, with one 2 unit wide gap on each axis for fill meshes.
	_tile_pos.push_back(Vector3(2, 0, _mesh_size + 2));
	_tile_pos.push_back(Vector3(_mesh_size + 2, 0, _mesh_size + 2));
	_tile_pos.push_back(Vector3(_mesh_size + 2, 0, -2));
	_tile_pos.push_back(Vector3(_mesh_size + 2, 0, -_mesh_size - 2));
	_tile_pos.push_back(Vector3(_mesh_size + 2, 0, -_mesh_size * 2 - 2));
	_tile_pos.push_back(Vector3(-2, 0, -_mesh_size * 2 - 2));
	_tile_pos.push_back(Vector3(-_mesh_size - 2, 0, -_mesh_size * 2 - 2));
	_tile_pos.push_back(Vector3(-_mesh_size * 2 - 2, 0, -_mesh_size * 2 - 2));
	_tile_pos.push_back(Vector3(-_mesh_size * 2 - 2, 0, -_mesh_size + 2));
	_tile_pos.push_back(Vector3(-_mesh_size * 2 - 2, 0, +2));
	_tile_pos.push_back(Vector3(-_mesh_size * 2 - 2, 0, _mesh_size + 2));
	_tile_pos.push_back(Vector3(-_mesh_size + 2, 0, _mesh_size + 2));

	// Edge offsets set edge pair positions to either both before, straddle, or both after
	// Depending on current LOD position within the next LOD, (via test_x or test_z in snap())
	_offset_a = real_t(_mesh_size * 2) + 2.f;
	_offset_b = real_t(_mesh_size * 2) + 4.f;
	_offset_c = real_t(_mesh_size * 2) + 6.f;
	_edge_pos.push_back(Vector3(_offset_a, _offset_a, -_offset_b));
	_edge_pos.push_back(Vector3(_offset_b, -_offset_b, -_offset_c));

	// Fills: Occupies the gaps between tiles for LOD1+ to complete the ring.
	_fill_a_pos.push_back(Vector3(_mesh_size - 2, 0, -_mesh_size * 2 - 2));
	_fill_a_pos.push_back(Vector3(-_mesh_size - 2, 0, _mesh_size + 2));
	_fill_b_pos.push_back(Vector3(_mesh_size + 2, 0, _mesh_size - 2));
	_fill_b_pos.push_back(Vector3(-_mesh_size * 2 - 2, 0, -_mesh_size - 2));

	return;
}

// Resolves the world-space focal point for a view: its camera if valid, else the terrain's
// default clipmap target (preserves single-view / editor behavior).
Vector3 Pasture3DMesher::_resolve_view_target(const ClipmapView &p_view) const {
	if (p_view.camera_id != 0) {
		Object *obj = ObjectDB::get_instance(p_view.camera_id);
		Node3D *cam = Object::cast_to<Node3D>(obj);
		if (cam) {
			return cam->get_global_position();
		}
	}
	return _host->get_clipmap_target_position();
}

// Frees all view instance RIDs. Mesh rids must be freed separately.
void Pasture3DMesher::_clear_views() {
	LOG(INFO, "Freeing all clipmap view instances");
	for (ClipmapView &view : _views) {
		for (const RID &rid : view.instance_rids) {
			RS->free_rid(rid);
		}
		view.instance_rids.clear();
		view.clipmap_rids.clear();
	}
	_views.clear();
	return;
}

// Frees all Mesh RIDs used for clipmap instances.
void Pasture3DMesher::_clear_mesh_types() {
	LOG(INFO, "Freeing all clipmap meshes");
	for (const RID &rid : _mesh_rids) {
		RS->free_rid(rid);
	}
	_mesh_rids.clear();
	return;
}

///////////////////////////
// Public Functions
///////////////////////////

void Pasture3DMesher::initialize(Pasture3DClipmapHost *p_host, const int p_mesh_size, const int p_lods, const int p_tessellation_level,
		const real_t p_vertex_spacing, const RID &p_material, const uint32_t p_render_layers,
		const bool p_uses_instance_target_pos,
		const RenderingServer::ShadowCastingSetting p_cast_shadows,
		const GeometryInstance3D::GIMode p_gi_mode) {
	if (p_host) {
		_host = p_host;
	} else {
		return;
	}
	if (!_host->is_clipmap_host_ready()) {
		LOG(DEBUG, "Clipmap host is not ready (no world3D)");
		return;
	}

	LOG(INFO, "Initializing GeoMesh");
	_scenario = _host->get_clipmap_world()->get_scenario();
	_material = p_material;
	_lods = p_lods;
	_tessellation_level = p_tessellation_level;
	_mesh_size = p_mesh_size;
	_vertex_spacing = p_vertex_spacing;
	_render_layers = p_render_layers;
	_uses_instance_target_pos = p_uses_instance_target_pos;
	_cast_shadows = p_cast_shadows;
	_gi_mode = p_gi_mode;
	_generate_mesh_types();
	_generate_offset_data();
	// Start with a single default view (current single-camera behavior). The Pasture3D node
	// re-applies its multi-camera config via set_views() after (re)initialization if needed.
	set_views(Vector<uint64_t>(), Vector<uint32_t>());
	update_aabbs();
}

void Pasture3DMesher::destroy() {
	LOG(INFO, "Destroying clipmap");
	_clear_views();
	_clear_mesh_types();
	_tile_pos_lod_0.clear();
	_trim_a_pos.clear();
	_trim_b_pos.clear();
	_edge_pos.clear();
	_fill_a_pos.clear();
	_fill_b_pos.clear();
	_tile_pos.clear();
}

// Rebuilds the clipmap views. Pass an empty list for the default single view (follows the
// terrain's clipmap target). Pass one camera ObjectID per view for local split-screen; each view
// then renders on its own layer and snaps to its own camera, all sharing the single terrain data.
void Pasture3DMesher::set_views(const Vector<uint64_t> &p_camera_ids, const Vector<uint32_t> &p_render_layers) {
	if (!_host) {
		return;
	}
	if (!_host->is_clipmap_host_ready() || _mesh_rids.is_empty()) {
		LOG(DEBUG, "Mesher not ready; skipping set_views");
		return;
	}
	_clear_views();
	if (p_camera_ids.is_empty()) {
		ClipmapView view;
		view.camera_id = 0;
		view.render_layers = _render_layers;
		view.cast_shadows = true;
		_generate_view_instances(view);
		_views.push_back(view);
	} else {
		for (int i = 0; i < p_camera_ids.size(); i++) {
			ClipmapView view;
			view.camera_id = p_camera_ids[i];
			view.render_layers = (i < p_render_layers.size()) ? p_render_layers[i] : _render_layers;
			view.cast_shadows = (i == 0); // Single shadow caster across all viewports
			_generate_view_instances(view);
			_views.push_back(view);
		}
	}
	LOG(INFO, "Configured ", _views.size(), " clipmap view(s)");
	update();
	reset_target_position();
	snap();
	return;
}

void Pasture3DMesher::snap() {
	if (!_host) {
		return;
	}
	const bool host_visible = _host->is_clipmap_visible();
	for (ClipmapView &view : _views) {
		const Vector3 target_pos = _resolve_view_target(view);
		// The per-view range test, BEFORE any instance traffic. A host that does not override it
		// answers true for every view and this costs one virtual call per view per frame.
		const bool in_range = _host->is_clipmap_view_in_range(v3v2(target_pos));
		if (in_range != view.in_range) {
			view.in_range = in_range;
			if (in_range) {
				// Coming back into range. The rings are wherever they were left when the view was
				// hidden, and _snap_view's early-out compares against last_target_position -- so
				// without forgetting it, a view can return VISIBLE and still centred on wherever its
				// camera was standing when it left. Same reasoning as reset_target_position().
				view.last_target_position = V2_MAX;
				view.last_shader_target_pos = V3_MAX;
			}
			_apply_view_visibility(view, host_visible);
		}
		if (!view.in_range) {
			// The saving. A hidden instance is not drawn, but it is still an instance the
			// RenderingServer is told the transform of: skipping the snap is what makes an
			// out-of-reach view cost nothing rather than cost only its rasterisation.
			continue;
		}
		_snap_view(view, target_pos);
	}
	return;
}

void Pasture3DMesher::_apply_view_visibility(ClipmapView &p_view, const bool p_host_visible) {
	// The node's own visibility still gates everything: hiding the node hides every view, and a view
	// out of range stays hidden when the node is shown again.
	const bool visible = p_host_visible && p_view.in_range;
	if (visible == p_view.visible_sent) {
		return;
	}
	p_view.visible_sent = visible;
	for (const RID &rid : p_view.instance_rids) {
		RS->instance_set_visible(rid, visible);
	}
}

int Pasture3DMesher::get_in_range_view_count() const {
	int n = 0;
	for (const ClipmapView &view : _views) {
		if (view.in_range) {
			n++;
		}
	}
	return n;
}

bool Pasture3DMesher::is_view_in_range(const int p_view) const {
	if (p_view < 0 || p_view >= _views.size()) {
		return false;
	}
	return _views[p_view].in_range;
}

void Pasture3DMesher::_snap_view(ClipmapView &p_view, const Vector3 &p_target_pos) {
	Vector3 target_pos = p_target_pos;

	// Update _target_pos every frame so LOD geomorphing stays smooth between discrete ring snaps.
	// Terrain: per-instance (each view morphs to its own center). Ocean: on the shared material.
	if (_uses_instance_target_pos) {
		if (target_pos != p_view.last_shader_target_pos) {
			p_view.last_shader_target_pos = target_pos;
			for (const RID &rid : p_view.instance_rids) {
				RS->instance_geometry_set_shader_parameter(rid, "_target_pos", target_pos);
			}
		}
	} else if (_material.is_valid()) {
		RS->material_set_param(_material, "_target_pos", target_pos);
	}

	// If this view's target hasn't moved enough, skip re-snapping its rings.
	Vector2 target_pos_2d = v3v2(target_pos);
	real_t tessellation_density = 1.f / pow(2.f, _tessellation_level);
	real_t vertex_spacing = _vertex_spacing * tessellation_density;
	if (MAX(std::abs(p_view.last_target_position.x - target_pos_2d.x), std::abs(p_view.last_target_position.y - target_pos_2d.y)) < vertex_spacing) {
		return;
	}

	// Recenter this view's clipmap on its target
	p_view.last_target_position = target_pos_2d;
	Vector3 snapped_pos = (target_pos / vertex_spacing).floor() * vertex_spacing;
	Vector3 pos = V3_ZERO;
	Array clipmap_rids = p_view.clipmap_rids;
	for (int lod = 0; lod < clipmap_rids.size(); ++lod) {
		real_t snap_step = pow(2.f, lod + 1.f) * vertex_spacing;
		Vector3 lod_scale = Vector3(pow(2.f, lod) * vertex_spacing, 1.f, pow(2.f, lod) * vertex_spacing);

		// Snap pos.xz
		pos.x = round(snapped_pos.x / snap_step) * snap_step;
		pos.z = round(snapped_pos.z / snap_step) * snap_step;

		LOG(EXTREME, "Snapping clipmap LOD", lod, " to position: ", pos);

		// test_x and test_z for edge strip positions
		real_t next_snap_step = pow(2.f, lod + 2.f) * vertex_spacing;
		real_t next_x = round(snapped_pos.x / next_snap_step) * next_snap_step;
		real_t next_z = round(snapped_pos.z / next_snap_step) * next_snap_step;
		int test_x = CLAMP(int(round((pos.x - next_x) / snap_step)) + 1, 0, 2);
		int test_z = CLAMP(int(round((pos.z - next_z) / snap_step)) + 1, 0, 2);
		Array lod_array = clipmap_rids[lod];
		for (int mesh = 0; mesh < lod_array.size(); ++mesh) {
			Array mesh_array = lod_array[mesh];
			for (int instance = 0; instance < mesh_array.size(); ++instance) {
				Transform3D t = Transform3D();
				switch (mesh) {
					case TILE: {
						t.origin = (lod == 0) ? _tile_pos_lod_0[instance] : _tile_pos[instance];
						break;
					}
					case EDGE_A: {
						Vector3 edge_pos_instance = _edge_pos[instance];
						t.origin.z -= _offset_a + (test_z * 2.f);
						t.origin.x = edge_pos_instance[test_x];
						break;
					}
					case EDGE_B: {
						Vector3 edge_pos_instance = _edge_pos[instance];
						t.origin.z = edge_pos_instance[test_z];
						t.origin.x -= _offset_a;
						break;
					}
					// LOD0 doesnt have fills so the trims share the same index.
					case FILL_A: {
						if (lod > 0) {
							t.origin = _fill_a_pos[instance];
						} else {
							t.origin = _trim_a_pos[instance];
						}
						break;
					}
					case FILL_B: {
						if (lod > 0) {
							t.origin = _fill_b_pos[instance];
						} else {
							t.origin = _trim_b_pos[instance];
						}
						break;
					}
					default: {
						break;
					}
				}
				t = t.scaled(lod_scale);
				t.origin += pos;
				RS->instance_set_transform(mesh_array[instance], t);
				RS->instance_teleport(mesh_array[instance]);
			}
		}
	}
	return;
}

void Pasture3DMesher::set_instance_shader_param(const StringName &p_name, const Variant &p_value) {
	for (const ClipmapView &view : _views) {
		for (const RID &rid : view.instance_rids) {
			RS->instance_geometry_set_shader_parameter(rid, p_name, p_value);
		}
	}
}

void Pasture3DMesher::reset_target_position() {
	for (ClipmapView &view : _views) {
		view.last_target_position = V2_MAX;
		view.last_shader_target_pos = V3_MAX;
	}
}

void Pasture3DMesher::set_render_layers(const uint32_t p_layers) {
	_render_layers = p_layers;
	// Default (non-camera) views track the node's render_layers; camera-bound views keep their
	// assigned per-player layer (set via set_views()).
	for (ClipmapView &view : _views) {
		if (view.camera_id == 0) {
			view.render_layers = p_layers;
		}
	}
}

// Iterates over every instance of every view and updates all properties.
void Pasture3DMesher::update() {
	if (!_host) {
		return;
	}
	if (!_host->is_clipmap_host_ready()) {
		LOG(DEBUG, "Pasture3D's world3D is null");
		return;
	}
	bool baked_light;
	bool dynamic_gi;
	// _gi_mode / _cast_shadows, not _terrain->get_gi_mode() / get_cast_shadows():
	// the ocean mesher is a second instance of this class with its own settings
	// (spec §4.4).
	switch (_gi_mode) {
		case GeometryInstance3D::GI_MODE_DISABLED: {
			baked_light = false;
			dynamic_gi = false;
		} break;
		case GeometryInstance3D::GI_MODE_DYNAMIC: {
			baked_light = false;
			dynamic_gi = true;
		} break;
		case GeometryInstance3D::GI_MODE_STATIC:
		default: {
			baked_light = true;
			dynamic_gi = false;
		} break;
	}

	RenderingServer::ShadowCastingSetting node_cast_shadows = _cast_shadows;
	bool host_visible = _host->is_clipmap_visible();

	LOG(INFO, "Updating all mesh instances for ", _views.size(), " view(s)");
	for (ClipmapView &view : _views) {
		// The per-view range test is honoured HERE too, not only in snap(). This is the full-reassert
		// pass -- it runs on a visibility change, a material swap, a GI change -- and a version that
		// wrote the host's answer alone would silently un-hide every out-of-range view until the next
		// snap happened to notice. That would show up as water flickering back on when something
		// unrelated touched the node.
		bool visible = host_visible && view.in_range;
		view.visible_sent = visible;
		// Only the first view casts shadows; identical geometry across views would otherwise
		// double-shadow / z-fight (guide §4).
		RenderingServer::ShadowCastingSetting cast_shadows = view.cast_shadows ? node_cast_shadows : RenderingServer::SHADOW_CASTING_SETTING_OFF;
		for (const RID &rid : view.instance_rids) {
			RS->instance_set_visible(rid, visible);
			RS->instance_set_scenario(rid, _scenario);
			RS->instance_set_layer_mask(rid, view.render_layers);
			RS->instance_geometry_set_cast_shadows_setting(rid, cast_shadows);
			RS->instance_geometry_set_flag(rid, RenderingServer::INSTANCE_FLAG_USE_BAKED_LIGHT, baked_light);
			RS->instance_geometry_set_flag(rid, RenderingServer::INSTANCE_FLAG_USE_DYNAMIC_GI, dynamic_gi);
		}
	}
	return;
}

// Iterates over all meshes and updates their AABBs
// All instances of each mesh inherit the updated AABB
// Defaults to using the terrain parameters
void Pasture3DMesher::update_aabbs(const real_t p_cull_margin, const Vector2 &p_height_range) {
	// Was IS_DATA_INIT, which early-returns unless the host is a Pasture3D WITH
	// loaded region data. An Pasture3DOcean has no data and never will, so under the old
	// guard its cull AABBs were never updated and the whole clipmap got culled the
	// moment the camera approached the water -- water spec §4.5's bug, reintroduced
	// through a guard nobody would think to look at. Criterion C of the Phase 2 gate
	// is this line, with the old guard as the control that must fail.
	if (!_host) {
		return;
	}
	LOG(INFO, "Updating ", _mesh_rids.size(), " meshes AABBs")
	real_t cull_margin;
	Vector2 height_range;
	if (p_cull_margin < 0.f) {
		cull_margin = _host->get_default_cull_margin();
	} else {
		cull_margin = p_cull_margin;
	}
	if (p_height_range.x == FLT_MAX) {
		height_range = _host->get_default_height_range();
	} else {
		height_range = p_height_range;
	}
	// (min, max) -> (min, extent). This was `y += abs(x)`, which is the same number
	// only while min <= 0 and overstates the extent by 2*min otherwise. Harmless
	// for a terrain whose height range straddles zero, but the ocean's range is
	// sea_level +/- amplitude and sits wherever the sea does, so a sea level of 300
	// inflated the y-extent to 600 m of nothing.
	height_range.y -= height_range.x;
	for (const RID &rid : _mesh_rids) {
		AABB aabb = RS->mesh_get_custom_aabb(rid);
		aabb.position.y = height_range.x - cull_margin;
		aabb.size.y = height_range.y + cull_margin * 2.f;
		RS->mesh_set_custom_aabb(rid, aabb);
	}
	return;
}
