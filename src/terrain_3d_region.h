// Copyright © 2024 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_REGION_CLASS_H
#define TERRAIN3D_REGION_CLASS_H

#include "constants.h"

using namespace godot;

class Terrain3DRegion : public Resource {
	GDCLASS(Terrain3DRegion, Resource);
	CLASS_NAME();

private:
	real_t _version = 0.8f; // Set to first version to ensure Godot always upgrades this
	bool _modified = false;
	Vector2i _region_loc = Vector2i(INT32_MIN, INT32_MIN);
	// Maps
	Ref<Image> _height_map;
	Ref<Image> _control_map;
	Ref<Image> _color_map;
	// Instancer MultiMeshes saved to disk
	// Dictionary[mesh_id:int] -> MultiMesh
	Dictionary _multimeshes;

public:
	void set_version(const real_t p_version);
	real_t get_version() const { return _version; }
	void set_modified(const bool p_modified) { _modified = p_modified; }
	bool is_modified() const { return _modified; }
	void set_region_loc(const Vector2i &p_region_loc) { _region_loc = p_region_loc; }
	Vector2i get_region_loc() const { return _region_loc; }

	// Maps
	void set_height_map(const Ref<Image> &p_map);
	Ref<Image> get_height_map() const { return _height_map; }
	void set_control_map(const Ref<Image> &p_map) { _control_map = p_map; }
	Ref<Image> get_control_map() const { return _control_map; }
	void set_color_map(const Ref<Image> &p_map) { _color_map = p_map; }
	Ref<Image> get_color_map() const { return _color_map; }

	// Instancer
	void set_multimeshes(const Dictionary &p_multimeshes) { _multimeshes = p_multimeshes; }
	Dictionary get_multimeshes() const { return _multimeshes; }

	// File I/O
	Error save(const String &p_path = "", const bool p_16_bit = false);

protected:
	static void _bind_methods();
};

#endif // TERRAIN3D_REGION_CLASS_H
