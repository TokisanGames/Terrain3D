// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/world3d.hpp>

#include "terrain_3d_geomesh.h"

#include "logger.h"

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3DGeoMesh::_clear_clipmap() {
	for (int lod = 0; lod < _clipmap_rids.size(); lod++) {
		Array lod_array = _clipmap_rids[lod];
		for (int mesh = 0; mesh < lod_array.size(); mesh++) {
			Array mesh_array = lod_array[mesh];
			for (int instance = 0; instance < mesh_array.size(); instance++) {
				RS->free_rid(mesh_array[instance]);
			};
			mesh_array.clear();
		};
		lod_array.clear();
	};
	_clipmap_rids.clear();
	_initialized = false;
	return;
}

void Terrain3DGeoMesh::_clear_mesh_types() {
	for (int m = 0; m < _mesh_rids.size(); m++) {
		RS->free_rid(_mesh_rids[m]);
	}
	_mesh_rids.clear();
	_initialized = false;
	return;
}

void Terrain3DGeoMesh::_generate_offset_data(const int size) {
	_tile_pos_lod_0.clear();
	_trim_a_pos.clear();
	_trim_b_pos.clear();
	_edge_pos.clear();
	_fill_a_pos.clear();
	_fill_b_pos.clear();

	// LOD0
	_tile_pos_lod_0.push_back(Vector3(0, 0, size));
	_tile_pos_lod_0.push_back(Vector3(size, 0, size));
	_tile_pos_lod_0.push_back(Vector3(size, 0, 0));
	_tile_pos_lod_0.push_back(Vector3(size, 0, -size));
	_tile_pos_lod_0.push_back(Vector3(size, 0, -size * 2));
	_tile_pos_lod_0.push_back(Vector3(0, 0, -size * 2));
	_tile_pos_lod_0.push_back(Vector3(-size, 0, -size * 2));
	_tile_pos_lod_0.push_back(Vector3(-size * 2, 0, -size * 2));
	_tile_pos_lod_0.push_back(Vector3(-size * 2, 0, -size));
	_tile_pos_lod_0.push_back(Vector3(-size * 2, 0, 0));
	_tile_pos_lod_0.push_back(Vector3(-size * 2, 0, size));
	_tile_pos_lod_0.push_back(Vector3(-size, 0, size));
	// Inner tiles
	_tile_pos_lod_0.push_back(Vector3(0, 0, 0));
	_tile_pos_lod_0.push_back(Vector3(-size, 0, 0));
	_tile_pos_lod_0.push_back(Vector3(0, 0, -size));
	_tile_pos_lod_0.push_back(Vector3(-size, 0, -size));

	// Trims
	_trim_a_pos.push_back(Vector3(size * 2, 0, -size * 2));
	_trim_a_pos.push_back(Vector3(-size * 2 - 2, 0, -size * 2 - 2));
	
	_trim_b_pos.push_back(Vector3(-size * 2, 0, -size * 2 - 2));
	_trim_b_pos.push_back(Vector3(-size * 2 - 2, 0, size * 2));

	// LOD1+
	_tile_pos.clear();
	_tile_pos.push_back(Vector3(2, 0, size + 2));
	_tile_pos.push_back(Vector3(size + 2, 0, size + 2));
	_tile_pos.push_back(Vector3(size + 2, 0, -2));
	_tile_pos.push_back(Vector3(size + 2, 0, -size - 2));
	_tile_pos.push_back(Vector3(size + 2, 0, -size * 2 - 2));
	_tile_pos.push_back(Vector3(-2, 0, -size * 2 - 2));
	_tile_pos.push_back(Vector3(-size - 2, 0, -size * 2 - 2));
	_tile_pos.push_back(Vector3(-size * 2 - 2, 0, -size * 2 - 2));
	_tile_pos.push_back(Vector3(-size * 2 - 2, 0, -size + 2));
	_tile_pos.push_back(Vector3(-size * 2 - 2, 0, +2));
	_tile_pos.push_back(Vector3(-size * 2 - 2, 0, size + 2));
	_tile_pos.push_back(Vector3(-size + 2, 0, size + 2));

	_offset_a = real_t(size * 2) + 4.f;
	_offset_b = real_t(size * 2) + 6.f;
	_offset_c = real_t(size * 2) + 2.f;
		
	_edge_pos.push_back(Vector3(_offset_c, _offset_c, -_offset_a));
	_edge_pos.push_back(Vector3(_offset_a, -_offset_a, -_offset_b));

	
	_fill_a_pos.push_back(Vector3(size - 2, 0, -size * 2 - 2));
	_fill_a_pos.push_back(Vector3(-size - 2, 0, size + 2));

	_fill_b_pos.push_back(Vector3(size + 2, 0, size - 2));
	_fill_b_pos.push_back(Vector3(-size * 2 - 2, 0, -size - 2));
	return;
}

void Terrain3DGeoMesh::_generate_mesh_types(const int size) {
	_clear_mesh_types();
	//Create initial set of Mesh blocks to build the clipmap
	//# 0 TILE - mesh_size x mesh_size tiles
	_mesh_rids.push_back(_generate_mesh(Vector2i(size, size)));
	//# 1 EDGE_A - 2 by (mesh_size * 4 + 8) strips to bridge LOD transitions along +-Z axis
	_mesh_rids.push_back(_generate_mesh(Vector2i(2, size * 4 + 8)));
	//# 2 EDGE_B - (mesh_size * 4 + 4) by 2 strips to bridge LOD transitions along +-X axis
	_mesh_rids.push_back(_generate_mesh(Vector2i(size * 4 + 4, 2)));
	//# 3 FILL_A - 4 by mesh_size
	_mesh_rids.push_back(_generate_mesh(Vector2i(4, size)));
	//# 4 FILL_B - mesh_size by 4
	_mesh_rids.push_back(_generate_mesh(Vector2i(size, 4)));
	//# 5 TRIM_A - 2 by (mesh_size * 4 + 2) strips for LOD0 +-Z axis edge
	_mesh_rids.push_back(_generate_mesh(Vector2i(2, size * 4 + 2)));
	//# 6 TRIM_B - (mesh_size * 4 + 4) by 2 strips for LOD0 +-X axis edge
	_mesh_rids.push_back(_generate_mesh(Vector2i(size * 4 + 2, 2)));
	return;
}

RID Terrain3DGeoMesh::_generate_mesh(const Vector2i size) {
	PackedVector3Array vertices;
	PackedInt32Array indices;
	AABB aabb = AABB(V3_ZERO, Vector3(size.x, 0.1f, size.y));

	// Generate vertices
	for (int y = 0; y <= size.y; ++y) {
		for (int x = 0; x <= size.x; ++x) {
			// Match GDScript vertex definitions
			vertices.push_back(Vector3(x, 0, y)); // bottom-left
		}
	}

	// Generate indices for quads with alternating diagonals
	for (int y = 0; y < size.y; ++y) {
		for (int x = 0; x < size.x; ++x) {
			int bottomLeft = y * (size.x + 1) + x;
			int bottomRight = bottomLeft + 1;
			int topLeft = (y + 1) * (size.x + 1) + x;
			int topRight = topLeft + 1;

			if ((x + y) % 2 == 0) {
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

RID Terrain3DGeoMesh::_instantiate_mesh(const PackedVector3Array &p_vertices, const PackedInt32Array &p_indices, const AABB &p_aabb) {
	Array arrays;
	arrays.resize(RenderingServer::ARRAY_MAX);
	arrays[RenderingServer::ARRAY_VERTEX] = p_vertices;
	arrays[RenderingServer::ARRAY_INDEX] = p_indices;

	PackedVector3Array normals;
	normals.resize(p_vertices.size());
	normals.fill(Vector3(0, 1, 0));
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
	RS->mesh_surface_set_material(mesh, 0, _terrain->get_material()->get_material_rid());

	return mesh;
}

void Terrain3DGeoMesh::_generate_clipmap(const int size, const int lods, const RID &scenario) {
	_clear_clipmap();
	_generate_mesh_types(size);
	_generate_offset_data(size);
	
	for (int level = 0; level < lods; level++) {
		Array lod;
		// 12 Tiles LOD1+, 16 for LOD0
		Array tile_rids;
		int tile_ammount = (level == 0) ? 16 : 12;

		for (int i = 0; i < tile_ammount; i++) {
		RID tile_rid = RS->instance_create2(_mesh_rids[TILE], scenario);
			tile_rids.append(tile_rid);
		}
		lod.append(tile_rids); // index 0 TILE

		// 4 Edges present on all LODs
		Array edge_a_rids;
		for (int i = 0; i < 2; i++) {
			RID edge_a_rid = RS->instance_create2(_mesh_rids[EDGE_A], scenario);
			edge_a_rids.append(edge_a_rid);
		}
		lod.append(edge_a_rids); // index 1 EDGE_A

		Array edge_b_rids;
		for (int i = 0; i < 2; i++) {
			RID edge_b_rid = RS->instance_create2(_mesh_rids[EDGE_B], scenario);
			edge_b_rids.append(edge_b_rid);
		}
		lod.append(edge_b_rids); // index 2 EDGE_B

		// Fillers only present on LODs 1+
		if (level > 0) {
			Array fill_a_rids;
			for (int i = 0; i < 2; i++) {
				RID fill_a_rid = RS->instance_create2(_mesh_rids[FILL_A], scenario);
				fill_a_rids.append(fill_a_rid);
			}
			lod.append(fill_a_rids); // index 4 FILL_A

			Array fill_b_rids;
			for (int i = 0; i < 2; i++) {
				RID fill_b_rid = RS->instance_create2(_mesh_rids[FILL_B], scenario);
				fill_b_rids.append(fill_b_rid);
			}
			lod.append(fill_b_rids); // index 5 FILL_B
		// Trims only on LOD 0
		} else {
			Array trim_a_rids;
			for (int i = 0; i < 2; i++) {
				RID trim_a_rid = RS->instance_create2(_mesh_rids[TRIM_A], scenario);
				trim_a_rids.append(trim_a_rid);
			}
			lod.append(trim_a_rids); // index 6 TRIM_A

			Array trim_b_rids;
			for (int i = 0; i < 2; i++) {
				RID trim_b_rid = RS->instance_create2(_mesh_rids[TRIM_B], scenario);
				trim_b_rids.append(trim_b_rid);
			}
			lod.append(trim_b_rids); // index 7 TRIM_B
		}

		// Append LOD to _lod_rids array
		_clipmap_rids.append(lod);
	}
}

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DGeoMesh::initialize(Terrain3D *p_terrain) {
	if (p_terrain) {
		_terrain = p_terrain;
	}
	IS_DATA_INIT_MESG("Terrain3D not initialized yet", VOID);
	LOG(INFO, "Initializing GeoMesh");
	// move these from _terrain to this class.?
	int size = _terrain->get_mesh_size();
	int lods = _terrain->get_mesh_lods();
	_generate_clipmap(size, lods, _terrain->get_world_3d()->get_scenario());
	_initialized = true;
	update_aabbs();
	update_clipmap_instances();
	snap(_terrain->get_snapped_position(), _terrain->get_vertex_spacing());
}

void Terrain3DGeoMesh::regenerate() {
	if (!_initialized) {
		return;
	}
	int size = _terrain->get_mesh_size();
	int lods = _terrain->get_mesh_lods();
	_generate_clipmap(size, lods, _terrain->get_world_3d()->get_scenario());
	_initialized = true;
	update_aabbs();
	update_clipmap_instances();
	snap(_terrain->get_snapped_position(), _terrain->get_vertex_spacing());
}

void Terrain3DGeoMesh::destroy() {
	_initialized = false;
	_clear_clipmap();
	_clear_mesh_types();
	_tile_pos_lod_0.clear();
	_trim_a_pos.clear();
	_trim_b_pos.clear();
	_edge_pos.clear();
	_fill_a_pos.clear();
	_fill_b_pos.clear();
}

void Terrain3DGeoMesh::snap(const Vector3 tracked_pos, const real_t mesh_density) {
	if (!_initialized) {
		return;
	}
	Vector3 pos = Vector3(0.0, 0.0, 0.0);

	for (int lod = 0; lod < _clipmap_rids.size(); ++lod) {
		real_t snap_step = pow(2.0, lod + 1.0) * mesh_density;
		Vector3 lod_scale = Vector3(pow(2, lod) * mesh_density, 1.0, pow(2, lod) * mesh_density);

		// Snap pos.xz
		real_t pos_x = tracked_pos.x;
		real_t pos_z = tracked_pos.z;
		pos.x = round(pos_x / snap_step) * snap_step;
		pos.z = round(pos_z / snap_step) * snap_step;

		// test_x and test_z for edge strip positions
		real_t next_snap_step = pow(2.0, lod + 2.0) * mesh_density;
		real_t next_x = round(pos_x / next_snap_step) * next_snap_step;
		real_t next_z = round(pos_z / next_snap_step) * next_snap_step;
		int test_x = CLAMP(int((pos.x - next_x) / snap_step) + 1, 0, 2);
		int test_z = CLAMP(int((pos.z - next_z) / snap_step) + 1, 0, 2);

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
						t.origin.z -= _offset_c + (test_z * 2.0);
						t.origin.x = edge_pos_instance[test_x];
						break;
					}
					case EDGE_B: {
						Vector3 edge_pos_instance = _edge_pos[instance];
						t.origin.z = edge_pos_instance[test_z];
						t.origin.x -= _offset_c;
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
				#if GODOT_VERSION_MAJOR == 4 && GODOT_VERSION_MINOR == 4
				RS->instance_reset_physics_interpolation(mesh_array[instance]);
				#endif
			}
		}
	}
	return;
}

void Terrain3DGeoMesh::update_aabbs() {
	if (!_initialized) {
		return;
	}
	real_t cull_margin = _terrain->get_cull_margin();
	Vector2 height_range = _terrain->get_data()->get_height_range();
	height_range.y += abs(height_range.x);

	for (int m = 0; m < _mesh_rids.size(); m++) {
		RID mesh = _mesh_rids[m];
		AABB aabb = RS->mesh_get_custom_aabb(mesh);
		aabb.position.y = height_range.x - cull_margin;
		aabb.size.y = height_range.y + cull_margin * 2.f;
		RS->mesh_set_custom_aabb(mesh, aabb);
	}
	return;
}

void Terrain3DGeoMesh::update_clipmap_instances() {
	if (!_initialized) {
		return;
	}
	RID scenario = _terrain->get_world_3d()->get_scenario();
	uint32_t render_layers = _terrain->get_render_layers();
	RenderingServer::ShadowCastingSetting cast_shadows = _terrain->get_cast_shadows();
	bool baked_light;
	bool dynamic_gi;
	bool v = _terrain->is_visible_in_tree();
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

	for (int lod = 0; lod < _clipmap_rids.size(); ++lod) {
		Array lod_array = _clipmap_rids[lod];
		for (int mesh = 0; mesh < lod_array.size(); ++mesh) {
			Array mesh_array = lod_array[mesh];
			for (int instance = 0; instance < mesh_array.size(); ++instance) {
				RS->instance_set_visible(mesh_array[instance], v);
				RS->instance_set_scenario(mesh_array[instance], scenario);
				RS->instance_set_layer_mask(mesh_array[instance], render_layers);
				RS->instance_geometry_set_cast_shadows_setting(mesh_array[instance], cast_shadows);
				RS->instance_geometry_set_flag(mesh_array[instance], RenderingServer::INSTANCE_FLAG_USE_BAKED_LIGHT, baked_light);
				RS->instance_geometry_set_flag(mesh_array[instance], RenderingServer::INSTANCE_FLAG_USE_DYNAMIC_GI, dynamic_gi);
			}
		}
	}
	return;
}

void Terrain3DGeoMesh::_bind_methods() {
}
