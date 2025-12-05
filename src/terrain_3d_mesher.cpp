// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/core/version.hpp>

#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_mesher.h"

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3DMesher::_generate_mesh_types() {
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

RID Terrain3DMesher::_generate_mesh(const Vector2i &p_size, const bool p_standard_grid) {
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

RID Terrain3DMesher::_instantiate_mesh(const PackedVector3Array &p_vertices, const PackedInt32Array &p_indices, const AABB &p_aabb) {
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

void Terrain3DMesher::_generate_clipmap() {
	_clear_clipmap();
	_generate_mesh_types();
	_generate_offset_data();
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

		// Append LOD to _lod_rids array
		_clipmap_rids.append(lod);
	}
}

// Precomputes all instance offset data into lookup arrays that match created instances.
// All meshes are created with 0,0 as their origin and grow along +xz. Offsets account for this.
void Terrain3DMesher::_generate_offset_data() {
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

// Frees all clipmap instance RIDs. Mesh rids must be freed separately.
void Terrain3DMesher::_clear_clipmap() {
	LOG(INFO, "Freeing all clipmap instances");
	for (const Array &lod_array : _clipmap_rids) {
		for (const Array &mesh_array : lod_array) {
			for (const RID &rid : mesh_array) {
				RS->free_rid(rid);
			}
		}
	}
	_clipmap_rids.clear();
	return;
}

// Frees all Mesh RIDs use for clipmap instances.
void Terrain3DMesher::_clear_mesh_types() {
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

void Terrain3DMesher::initialize(Terrain3D *p_terrain, const int p_mesh_size, const int p_lods, const int p_tessellation_level, const real_t p_vertex_spacing, const RID &p_material) {
	if (p_terrain) {
		_terrain = p_terrain;
	} else {
		return;
	}
	if (!_terrain->is_inside_world()) {
		LOG(DEBUG, "Terrain3D's world3D is null");
		return;
	}

	LOG(INFO, "Initializing GeoMesh");
	_scenario = _terrain->get_world_3d()->get_scenario();
	set_material(p_material);
	set_lods(p_lods);
	set_mesh_size(p_mesh_size);
	set_tessellation_level(p_tessellation_level);
	set_vertex_spacing(p_vertex_spacing);
	_generate_clipmap();
	update();
	update_aabbs();
	reset_target_position();
	snap();
}

void Terrain3DMesher::destroy() {
	LOG(INFO, "Destroying clipmap");
	_clear_clipmap();
	_clear_mesh_types();
	_tile_pos_lod_0.clear();
	_trim_a_pos.clear();
	_trim_b_pos.clear();
	_edge_pos.clear();
	_fill_a_pos.clear();
	_fill_b_pos.clear();
}

void Terrain3DMesher::snap() {
	IS_INIT(VOID);
	// Always update target position in shader
	Vector3 target_pos = _terrain->get_clipmap_target_position();
	if (_material.is_valid()) {
		RS->material_set_param(_material, "_target_pos", target_pos);
	}
	// If clipmap target hasn't moved enough, skip
	Vector2 target_pos_2d = v3v2(target_pos);
	real_t tessellation_density = 1.f / pow(2.f, _tessellation_level);
	real_t vertex_spacing = _vertex_spacing * tessellation_density;
	if (MAX(std::abs(_last_target_position.x - target_pos_2d.x), std::abs(_last_target_position.y - target_pos_2d.y)) < vertex_spacing) {
		return;
	}

	// Recenter terrain on the target
	_last_target_position = target_pos_2d;
	Vector3 snapped_pos = (target_pos / vertex_spacing).floor() * vertex_spacing;
	Vector3 pos = V3_ZERO;
	for (int lod = 0; lod < _clipmap_rids.size(); ++lod) {
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
		Array lod_array = _clipmap_rids[lod];
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
#if GODOT_VERSION_MAJOR == 4 && GODOT_VERSION_MINOR >= 5
				RS->instance_teleport(mesh_array[instance]);
#endif
// Deprecated Godot 4.5+
#if GODOT_VERSION_MAJOR == 4 && GODOT_VERSION_MINOR == 4
				RS->instance_reset_physics_interpolation(mesh_array[instance]);
#endif
			}
		}
	}
	return;
}

// Iterates over every instance of every mesh and updates all properties.
void Terrain3DMesher::update() {
	IS_INIT(VOID);
	if (!_terrain->is_inside_world()) {
		LOG(DEBUG, "Terrain3D's world3D is null");
		return;
	}
	bool baked_light;
	bool dynamic_gi;
	switch (_terrain->get_gi_mode()) {
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

	uint32_t render_layers = _terrain->get_render_layers();
	RenderingServer::ShadowCastingSetting cast_shadows = _terrain->get_cast_shadows();
	bool visible = _terrain->is_visible_in_tree();

	LOG(INFO, "Updating all mesh instances for ", _clipmap_rids.size(), " LODs");
	for (const Array &lod_array : _clipmap_rids) {
		for (const Array &mesh_array : lod_array) {
			for (const RID &rid : mesh_array) {
				RS->instance_set_visible(rid, visible);
				RS->instance_set_scenario(rid, _scenario);
				RS->instance_set_layer_mask(rid, render_layers);
				RS->instance_geometry_set_cast_shadows_setting(rid, cast_shadows);
				RS->instance_geometry_set_flag(rid, RenderingServer::INSTANCE_FLAG_USE_BAKED_LIGHT, baked_light);
				RS->instance_geometry_set_flag(rid, RenderingServer::INSTANCE_FLAG_USE_DYNAMIC_GI, dynamic_gi);
			}
		}
	}
	return;
}

// Iterates over all meshes and updates their AABBs
// All instances of each mesh inherit the updated AABB
void Terrain3DMesher::update_aabbs() {
	IS_DATA_INIT(VOID);
	real_t cull_margin = _terrain->get_cull_margin();
	Vector2 height_range = _terrain->get_data()->get_height_range();
	height_range.y += std::abs(height_range.x);

	LOG(INFO, "Updating ", _mesh_rids.size(), " meshes AABBs")
	for (const RID &rid : _mesh_rids) {
		AABB aabb = RS->mesh_get_custom_aabb(rid);
		aabb.position.y = height_range.x - cull_margin;
		aabb.size.y = height_range.y + cull_margin * 2.f;
		RS->mesh_set_custom_aabb(rid, aabb);
	}
	return;
}
