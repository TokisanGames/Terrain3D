#ifndef OCEANCLIPMAP_CLASS_H
#define OCEANCLIPMAP_CLASS_H

#include <godot_cpp/templates/vector.hpp>

#include "constants.h"

using namespace godot;

class OceanClipMap {
	CLASS_NAME_STATIC("Terrain3DOceanClipMap");

	static inline int _patch_2d(int x, int y, int res);
	static RID _create_mesh(PackedVector3Array p_vertices, PackedInt32Array p_indices, AABB p_aabb);

public:
	enum MeshType {
		TILE,
		FILLER,
		TRIM,
		CROSS,
		SEAM,
		SKIRT,
	};

	static Vector<RID> generate(int p_resolution, int p_clipmap_levels);
};

// Inline Functions

inline int OceanClipMap::_patch_2d(int x, int y, int res) {
	return y * res + x;
}

#endif // OCEANCLIPMAP_CLASS_H