//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#ifndef GEOCLIPMAP_CLASS_H
#define GEOCLIPMAP_CLASS_H

#ifdef WIN32
#include <windows.h>
#endif

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/templates/vector.hpp>

using namespace godot;

class GeoClipMap {
	static int patch_2d(int x, int y, int res);
	static RID create_mesh(PackedVector3Array p_vertices, PackedInt32Array p_indices);

public:
	enum MeshType {
		TILE,
		FILLER,
		TRIM,
		CROSS,
		SEAM,
	};

	static Vector<RID> generate(int p_resolution, int p_clipmap_levels);
};

#endif // GEOCLIPMAP_CLASS_H