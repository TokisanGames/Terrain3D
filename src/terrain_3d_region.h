// Copyright © 2024 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_REGION_CLASS_H
#define TERRAIN3D_REGION_CLASS_H

#include "constants.h"
#include "terrain_3d_util.h"

using namespace godot;

class Terrain3DRegion : public Resource {
	GDCLASS(Terrain3DRegion, Resource);
	CLASS_NAME();

public: // Constants
	enum MapType {
		TYPE_HEIGHT,
		TYPE_CONTROL,
		TYPE_COLOR,
		TYPE_MAX,
	};

	static inline const Image::Format FORMAT[] = {
		Image::FORMAT_RF, // TYPE_HEIGHT
		Image::FORMAT_RF, // TYPE_CONTROL
		Image::FORMAT_RGBA8, // TYPE_COLOR
		Image::Format(TYPE_MAX), // Proper size of array instead of FORMAT_MAX
	};

	static inline const char *TYPESTR[] = {
		"TYPE_HEIGHT",
		"TYPE_CONTROL",
		"TYPE_COLOR",
		"TYPE_MAX",
	};

	static inline const Color COLOR[] = {
		COLOR_BLACK, // TYPE_HEIGHT
		COLOR_CONTROL, // TYPE_CONTROL
		COLOR_ROUGHNESS, // TYPE_COLOR
		COLOR_NAN, // TYPE_MAX, unused just in case someone indexes the array
	};

private:
	// Saved data
	real_t _version = 0.8f; // Set to first version to ensure Godot always upgrades this
	int _region_size = 1024;
	// Maps
	Ref<Image> _height_map;
	Ref<Image> _control_map;
	Ref<Image> _color_map;
	// Dictionary[mesh_id:int] -> MultiMesh
	Dictionary _multimeshes;

	// Workind data not saved to disk
	Vector2i _location = Vector2i(INT32_MAX, INT32_MAX);
	bool _modified = false;

public:
	Terrain3DRegion() {}
	Terrain3DRegion(const Ref<Image> &p_height_map, const Ref<Image> &p_control_map, const Ref<Image> &p_color_map, const int p_region_size = 1024);
	~Terrain3DRegion() {}

	void set_version(const real_t p_version);
	real_t get_version() const { return _version; }

	// Maps
	void set_height_map(const Ref<Image> &p_map);
	Ref<Image> get_height_map() const { return _height_map; }
	void set_control_map(const Ref<Image> &p_map);
	Ref<Image> get_control_map() const { return _control_map; }
	void set_color_map(const Ref<Image> &p_map);
	Ref<Image> get_color_map() const { return _color_map; }
	void sanitize_maps(const MapType p_map_type = TYPE_MAX);
	Ref<Image> sanitize_map(const MapType p_map_type, const Ref<Image> &p_img) const;

	// Instancer
	void set_multimeshes(const Dictionary &p_multimeshes) { _multimeshes = p_multimeshes; }
	Dictionary get_multimeshes() const { return _multimeshes; }

	// File I/O
	Error save(const String &p_path = "", const bool p_16_bit = false);

	// Working
	void set_modified(const bool p_modified) { _modified = p_modified; }
	bool is_modified() const { return _modified; }
	void set_location(const Vector2i &p_location) { _location = p_location; }
	Vector2i get_location() const { return _location; }
	void set_region_size(const int p_region_size) { _region_size = p_region_size; }
	int get_region_size() const { return _region_size; }

protected:
	static void _bind_methods();
};

typedef Terrain3DRegion::MapType MapType;
VARIANT_ENUM_CAST(Terrain3DRegion::MapType);
constexpr Terrain3DRegion::MapType TYPE_HEIGHT = Terrain3DRegion::MapType::TYPE_HEIGHT;
constexpr Terrain3DRegion::MapType TYPE_CONTROL = Terrain3DRegion::MapType::TYPE_CONTROL;
constexpr Terrain3DRegion::MapType TYPE_COLOR = Terrain3DRegion::MapType::TYPE_COLOR;
constexpr Terrain3DRegion::MapType TYPE_MAX = Terrain3DRegion::MapType::TYPE_MAX;
constexpr inline const Image::Format *FORMAT = Terrain3DRegion::FORMAT;
constexpr inline const char **TYPESTR = Terrain3DRegion::TYPESTR;
constexpr inline const Color *COLOR = Terrain3DRegion::COLOR;

#endif // TERRAIN3D_REGION_CLASS_H
