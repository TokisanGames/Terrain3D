// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef GEOCLIPMAP_CLASS_H
#define GEOCLIPMAP_CLASS_H

#include <godot_cpp/templates/vector.hpp>

#include "constants.h"

using namespace godot;

class GeoClipMap {
	CLASS_NAME_STATIC("Terrain3DGeoClipMap");

	static inline int _patch_2d(const int x, const int y, const int res);
	static void _subdivide_half(PackedVector3Array &vertices, PackedInt32Array &indices);
	static RID _create_mesh(const PackedVector3Array &p_vertices, const PackedInt32Array &p_indices, const AABB &p_aabb);

public:
	enum MeshType {
		TILE,
		FILLER,
		TRIM,
		CROSS,
		SEAM,
		TILE_INNER,
		FILLER_INNER,
		TRIM_INNER,
	};

	static Vector<RID> generate(const int p_resolution, const int p_clipmap_levels);
};

// Inline Functions

inline int GeoClipMap::_patch_2d(const int x, const int y, const int res) {
	return y * res + x;
}

#endif // GEOCLIPMAP_CLASS_H