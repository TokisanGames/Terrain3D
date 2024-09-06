// Copyright © 2024 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/rendering_server.hpp>

#include "geoclipmap.h"
#include "logger.h"

///////////////////////////
// Private Functions
///////////////////////////

// Half each triangle, have to check for longest side.
void GeoClipMap::_subdivide_half(PackedVector3Array &vertices, PackedInt32Array &indices) {

	// Hash for map for quick vertex search, for loop was very very slow!
	struct Vector3Hash {
		std::size_t operator()(const Vector3 &v) const {
			std::size_t h1 = std::hash<float>()(v.x);
			std::size_t h2 = std::hash<float>()(v.y);
			std::size_t h3 = std::hash<float>()(v.z);
			return h1 ^ (h2 << 1) ^ (h3 << 2);
		}
	};

	PackedVector3Array new_vertices;
	PackedInt32Array new_indices;

	std::unordered_map<Vector3, int, Vector3Hash> vertex_map;

	auto midpoint = [](const Vector3 &p1, const Vector3 &p2) -> Vector3 {
		return (p1 + p2) / 2.0f;
	};

	auto find_or_add_vertex = [&vertex_map, &new_vertices](const Vector3 &vertex) -> int {
		auto it = vertex_map.find(vertex);
		if (it != vertex_map.end()) {
			return it->second;
		} else {
			int index = new_vertices.size();
			vertex_map[vertex] = index;
			new_vertices.push_back(vertex);
			return index;
		}
	};

	for (int i = 0; i < indices.size(); i += 3) {
		int id_0 = indices[i];
		int id_1 = indices[i + 1];
		int id_2 = indices[i + 2];

		Vector3 A = vertices[id_0];
		Vector3 B = vertices[id_1];
		Vector3 C = vertices[id_2];

		float length_AB = (B - A).length_squared();
		float length_BC = (C - B).length_squared();
		float length_CA = (A - C).length_squared();

		// Determine the longest edge and its midpoint, chaos otherwise.
		int A_id, B_id, C_id, mid_id;
		if (length_AB >= length_BC && length_AB >= length_CA) {
			A_id = find_or_add_vertex(A);
			B_id = find_or_add_vertex(B);
			C_id = find_or_add_vertex(C);
			mid_id = find_or_add_vertex(midpoint(A, B));

			new_indices.push_back(A_id);
			new_indices.push_back(mid_id);
			new_indices.push_back(C_id);

			new_indices.push_back(mid_id);
			new_indices.push_back(B_id);
			new_indices.push_back(C_id);

		} else if (length_BC >= length_AB && length_BC >= length_CA) {
			A_id = find_or_add_vertex(A);
			B_id = find_or_add_vertex(B);
			C_id = find_or_add_vertex(C);
			mid_id = find_or_add_vertex(midpoint(B, C));

			new_indices.push_back(B_id);
			new_indices.push_back(mid_id);
			new_indices.push_back(A_id);

			new_indices.push_back(mid_id);
			new_indices.push_back(C_id);
			new_indices.push_back(A_id);

		} else {
			// length_BC >= length_AB && length_BC >= length_CA
			A_id = find_or_add_vertex(A);
			B_id = find_or_add_vertex(B);
			C_id = find_or_add_vertex(C);
			mid_id = find_or_add_vertex(midpoint(C, A));

			new_indices.push_back(C_id);
			new_indices.push_back(mid_id);
			new_indices.push_back(B_id);

			new_indices.push_back(mid_id);
			new_indices.push_back(A_id);
			new_indices.push_back(B_id);
		}
	}

	vertices.clear();
	vertices.append_array(new_vertices);
	indices.clear();
	indices.append_array(new_indices);
}

RID GeoClipMap::_create_mesh(const PackedVector3Array &p_vertices, const PackedInt32Array &p_indices, const AABB &p_aabb) {
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

	return mesh;
}

///////////////////////////
// Public Functions
///////////////////////////

/* Generate clipmap meshes originally by Mike J Savage
 * Article https://mikejsavage.co.uk/blog/geometry-clipmaps.html
 * Code http://git.mikejsavage.co.uk/medfall/file/clipmap.cc.html#l197
 * In email communication with Cory, Mike clarified that the code in his
 * repo can be considered either MIT or public domain.
 */
Vector<RID> GeoClipMap::generate(const int p_size, const int p_levels) {
	LOG(DEBUG, "Generating meshes of size: ", p_size, " levels: ", p_levels);

	// TODO bit of a mess here. someone care to clean up?
	RID tile_mesh;
	RID filler_mesh;
	RID trim_mesh;
	RID cross_mesh;
	RID seam_mesh;
	RID tile_inner_mesh;
	RID filler_inner_mesh;
	RID trim_inner_mesh;

	int TILE_RESOLUTION = p_size;
	int PATCH_VERT_RESOLUTION = TILE_RESOLUTION + 1;
	int CLIPMAP_RESOLUTION = TILE_RESOLUTION * 4 + 1;
	int CLIPMAP_VERT_RESOLUTION = CLIPMAP_RESOLUTION + 1;
	int NUM_CLIPMAP_LEVELS = p_levels;
	AABB aabb;
	int n = 0;

	// Create a tile mesh
	// A tile is the main component of terrain panels
	// LOD0: 4 tiles are placed as a square in each center quadrant, for a total of 16 tiles
	// LOD1..N 3 tiles make up a corner, 4 corners uses 12 tiles
	{
		PackedVector3Array vertices;
		vertices.resize(PATCH_VERT_RESOLUTION * PATCH_VERT_RESOLUTION);
		PackedInt32Array indices;
		indices.resize(TILE_RESOLUTION * TILE_RESOLUTION * 6);

		n = 0;

		for (int y = 0; y < PATCH_VERT_RESOLUTION; y++) {
			for (int x = 0; x < PATCH_VERT_RESOLUTION; x++) {
				vertices[n++] = Vector3(x, 0.f, y);
			}
		}

		n = 0;

		for (int y = 0; y < TILE_RESOLUTION; y++) {
			for (int x = 0; x < TILE_RESOLUTION; x++) {
				indices[n++] = _patch_2d(x, y, PATCH_VERT_RESOLUTION);
				indices[n++] = _patch_2d(x + 1, y + 1, PATCH_VERT_RESOLUTION);
				indices[n++] = _patch_2d(x, y + 1, PATCH_VERT_RESOLUTION);

				indices[n++] = _patch_2d(x, y, PATCH_VERT_RESOLUTION);
				indices[n++] = _patch_2d(x + 1, y, PATCH_VERT_RESOLUTION);
				indices[n++] = _patch_2d(x + 1, y + 1, PATCH_VERT_RESOLUTION);
			}
		}

		aabb = AABB(V3_ZERO, Vector3(PATCH_VERT_RESOLUTION, 0.1f, PATCH_VERT_RESOLUTION));
		tile_inner_mesh = _create_mesh(vertices, indices, aabb);
		_subdivide_half(vertices, indices);
		tile_mesh = _create_mesh(vertices, indices, aabb);
	}

	// Create a filler mesh
	// These meshes are small strips that fill in the gaps between LOD1+,
	// but only on the camera X and Z axes, and not on LOD0.
	{
		PackedVector3Array vertices;
		vertices.resize(PATCH_VERT_RESOLUTION * 8);
		PackedInt32Array indices;
		indices.resize(TILE_RESOLUTION * 24);

		n = 0;
		int offset = TILE_RESOLUTION;

		for (int i = 0; i < PATCH_VERT_RESOLUTION; i++) {
			vertices[n] = Vector3(offset + i + 1.f, 0.f, 0.f);
			aabb.expand_to(vertices[n]);
			n++;

			vertices[n] = Vector3(offset + i + 1.f, 0.f, 1.f);
			aabb.expand_to(vertices[n]);
			n++;
		}

		for (int i = 0; i < PATCH_VERT_RESOLUTION; i++) {
			vertices[n] = Vector3(1.f, 0.f, offset + i + 1.f);
			aabb.expand_to(vertices[n]);
			n++;

			vertices[n] = Vector3(0.f, 0.f, offset + i + 1.f);
			aabb.expand_to(vertices[n]);
			n++;
		}

		for (int i = 0; i < PATCH_VERT_RESOLUTION; i++) {
			vertices[n] = Vector3(-real_t(offset + i), 0.f, 1.f);
			aabb.expand_to(vertices[n]);
			n++;

			vertices[n] = Vector3(-real_t(offset + i), 0.f, 0.f);
			aabb.expand_to(vertices[n]);
			n++;
		}

		for (int i = 0; i < PATCH_VERT_RESOLUTION; i++) {
			vertices[n] = Vector3(0.f, 0.f, -real_t(offset + i));
			aabb.expand_to(vertices[n]);
			n++;

			vertices[n] = Vector3(1.f, 0.f, -real_t(offset + i));
			aabb.expand_to(vertices[n]);
			n++;
		}

		n = 0;
		for (int i = 0; i < TILE_RESOLUTION * 4; i++) {
			int arm = i / TILE_RESOLUTION;

			int bl = (arm + i) * 2 + 0;
			int br = (arm + i) * 2 + 1;
			int tl = (arm + i) * 2 + 2;
			int tr = (arm + i) * 2 + 3;

			if (arm % 2 == 0) {
				indices[n++] = br;
				indices[n++] = bl;
				indices[n++] = tr;
				indices[n++] = bl;
				indices[n++] = tl;
				indices[n++] = tr;
			} else {
				indices[n++] = br;
				indices[n++] = bl;
				indices[n++] = tl;
				indices[n++] = br;
				indices[n++] = tl;
				indices[n++] = tr;
			}
		}
		filler_inner_mesh = _create_mesh(vertices, indices, aabb);
		_subdivide_half(vertices, indices);
		filler_mesh = _create_mesh(vertices, indices, aabb);
	}

	// Create trim mesh
	// This mesh is a skinny L shape that fills in the gaps between
	// LOD meshes when they are moving at different speeds and have gaps
	{
		PackedVector3Array vertices;
		vertices.resize((CLIPMAP_VERT_RESOLUTION * 2 + 1) * 2);
		PackedInt32Array indices;
		indices.resize((CLIPMAP_VERT_RESOLUTION * 2 - 1) * 6);

		n = 0;
		Vector3 offset = Vector3(0.5f * real_t(CLIPMAP_VERT_RESOLUTION + 1), 0.f, 0.5f * real_t(CLIPMAP_VERT_RESOLUTION + 1));

		for (int i = 0; i < CLIPMAP_VERT_RESOLUTION + 1; i++) {
			vertices[n] = Vector3(0.f, 0.f, CLIPMAP_VERT_RESOLUTION - i) - offset;
			aabb.expand_to(vertices[n]);
			n++;

			vertices[n] = Vector3(1.f, 0.f, CLIPMAP_VERT_RESOLUTION - i) - offset;
			aabb.expand_to(vertices[n]);
			n++;
		}

		int start_of_horizontal = n;

		for (int i = 0; i < CLIPMAP_VERT_RESOLUTION; i++) {
			vertices[n] = Vector3(i + 1.f, 0.f, 0.f) - offset;
			aabb.expand_to(vertices[n]);
			n++;

			vertices[n] = Vector3(i + 1.f, 0.f, 1.f) - offset;
			aabb.expand_to(vertices[n]);
			n++;
		}

		n = 0;

		for (int i = 0; i < CLIPMAP_VERT_RESOLUTION; i++) {
			indices[n++] = (i + 0) * 2 + 1;
			indices[n++] = (i + 0) * 2 + 0;
			indices[n++] = (i + 1) * 2 + 0;

			indices[n++] = (i + 1) * 2 + 1;
			indices[n++] = (i + 0) * 2 + 1;
			indices[n++] = (i + 1) * 2 + 0;
		}

		for (int i = 0; i < CLIPMAP_VERT_RESOLUTION - 1; i++) {
			indices[n++] = start_of_horizontal + (i + 0) * 2 + 1;
			indices[n++] = start_of_horizontal + (i + 0) * 2 + 0;
			indices[n++] = start_of_horizontal + (i + 1) * 2 + 0;

			indices[n++] = start_of_horizontal + (i + 1) * 2 + 1;
			indices[n++] = start_of_horizontal + (i + 0) * 2 + 1;
			indices[n++] = start_of_horizontal + (i + 1) * 2 + 0;
		}
		trim_inner_mesh = _create_mesh(vertices, indices, aabb);
		_subdivide_half(vertices, indices);
		trim_mesh = _create_mesh(vertices, indices, aabb);
	}

	// Create center cross mesh
	// This mesh is the small cross shape that fills in the gaps along the
	// X and Z axes between the center quadrants on LOD0.
	{
		PackedVector3Array vertices;
		vertices.resize(PATCH_VERT_RESOLUTION * 8);
		PackedInt32Array indices;
		indices.resize(TILE_RESOLUTION * 24 + 6);

		n = 0;

		for (int i = 0; i < PATCH_VERT_RESOLUTION * 2; i++) {
			vertices[n] = Vector3(real_t(i - TILE_RESOLUTION), 0.f, 0.f);
			aabb.expand_to(vertices[n]);
			n++;

			vertices[n] = Vector3(real_t(i - TILE_RESOLUTION), 0.f, 1.f);
			aabb.expand_to(vertices[n]);
			n++;
		}

		int start_of_vertical = n;

		for (int i = 0; i < PATCH_VERT_RESOLUTION * 2; i++) {
			vertices[n] = Vector3(0.f, 0.f, real_t(i - TILE_RESOLUTION));
			aabb.expand_to(vertices[n]);
			n++;

			vertices[n] = Vector3(1.f, 0.f, real_t(i - TILE_RESOLUTION));
			aabb.expand_to(vertices[n]);
			n++;
		}

		n = 0;

		for (int i = 0; i < TILE_RESOLUTION * 2 + 1; i++) {
			int bl = i * 2 + 0;
			int br = i * 2 + 1;
			int tl = i * 2 + 2;
			int tr = i * 2 + 3;

			indices[n++] = br;
			indices[n++] = bl;
			indices[n++] = tr;
			indices[n++] = bl;
			indices[n++] = tl;
			indices[n++] = tr;
		}

		for (int i = 0; i < TILE_RESOLUTION * 2 + 1; i++) {
			if (i == TILE_RESOLUTION) {
				continue;
			}

			int bl = i * 2 + 0;
			int br = i * 2 + 1;
			int tl = i * 2 + 2;
			int tr = i * 2 + 3;

			indices[n++] = start_of_vertical + br;
			indices[n++] = start_of_vertical + tr;
			indices[n++] = start_of_vertical + bl;
			indices[n++] = start_of_vertical + bl;
			indices[n++] = start_of_vertical + tr;
			indices[n++] = start_of_vertical + tl;
		}

		cross_mesh = _create_mesh(vertices, indices, aabb);
	}

	// Create seam mesh
	// This is a very thin mesh that is supposed to cover tiny gaps
	// between tiles and fillers when the vertices do not line up
	{
		PackedVector3Array vertices;
		vertices.resize(CLIPMAP_VERT_RESOLUTION * 4);
		PackedInt32Array indices;
		indices.resize(CLIPMAP_VERT_RESOLUTION * 6);

		n = 0;

		for (int i = 0; i < CLIPMAP_VERT_RESOLUTION; i++) {
			n = CLIPMAP_VERT_RESOLUTION * 0 + i;
			vertices[n] = Vector3(i, 0.f, 0.f);
			aabb.expand_to(vertices[n]);

			n = CLIPMAP_VERT_RESOLUTION * 1 + i;
			vertices[n] = Vector3(CLIPMAP_VERT_RESOLUTION, 0.f, i);
			aabb.expand_to(vertices[n]);

			n = CLIPMAP_VERT_RESOLUTION * 2 + i;
			vertices[n] = Vector3(CLIPMAP_VERT_RESOLUTION - i, 0.f, CLIPMAP_VERT_RESOLUTION);
			aabb.expand_to(vertices[n]);

			n = CLIPMAP_VERT_RESOLUTION * 3 + i;
			vertices[n] = Vector3(0.f, 0.f, CLIPMAP_VERT_RESOLUTION - i);
			aabb.expand_to(vertices[n]);
		}

		n = 0;

		for (int i = 0; i < CLIPMAP_VERT_RESOLUTION * 4; i += 2) {
			indices[n++] = i + 1;
			indices[n++] = i;
			indices[n++] = i + 2;
		}

		indices[indices.size() - 1] = 0;

		seam_mesh = _create_mesh(vertices, indices, aabb);
	}

	// skirt mesh
	/*{
		real_t scale = real_t(1 << (NUM_CLIPMAP_LEVELS - 1));
		real_t fbase = real_t(TILE_RESOLUTION << NUM_CLIPMAP_LEVELS);
		Vector2 base = -Vector2(fbase, fbase);

		Vector2 clipmap_tl = base;
		Vector2 clipmap_br = clipmap_tl + (Vector2(CLIPMAP_RESOLUTION, CLIPMAP_RESOLUTION) * scale);

		real_t big = 10000000.0;
		Array vertices = Array::make(
			Vector3(-1, 0, -1) * big,
			Vector3(+1, 0, -1) * big,
			Vector3(-1, 0, +1) * big,
			Vector3(+1, 0, +1) * big,
			Vector3(clipmap_tl.x, 0, clipmap_tl.y),
			Vector3(clipmap_br.x, 0, clipmap_tl.y),
			Vector3(clipmap_tl.x, 0, clipmap_br.y),
			Vector3(clipmap_br.x, 0, clipmap_br.y)
		);

		Array indices = Array::make(
			0, 1, 4, 4, 1, 5,
			1, 3, 5, 5, 3, 7,
			3, 2, 7, 7, 2, 6,
			4, 6, 0, 0, 6, 2
		);

		skirt_mesh = _create_mesh(PackedVector3Array(vertices), PackedInt32Array(indices));

	}*/

	Vector<RID> meshes = {
		tile_mesh,
		filler_mesh,
		trim_mesh,
		cross_mesh,
		seam_mesh,
		tile_inner_mesh,
		filler_inner_mesh,
		trim_inner_mesh,
	};

	return meshes;
}
