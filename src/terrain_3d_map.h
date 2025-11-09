// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_MAP_CLASS_H
#define TERRAIN3D_MAP_CLASS_H

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/core/math.hpp>

#include "constants.h"

enum MapType {
	TYPE_HEIGHT,
	TYPE_CONTROL,
	TYPE_COLOR,
	TYPE_MAX,
};

inline const Image::Format FORMAT[] = {
	Image::FORMAT_RF,
	Image::FORMAT_RF,
	Image::FORMAT_RGBA8,
	Image::Format(TYPE_MAX),
};

inline const char *TYPESTR[] = {
	"TYPE_HEIGHT",
	"TYPE_CONTROL",
	"TYPE_COLOR",
	"TYPE_MAX",
};

inline const Color COLOR[] = {
	COLOR_BLACK,
	COLOR_CONTROL,
	COLOR_ROUGHNESS,
	COLOR_NAN,
};

inline Image::Format map_type_get_format(MapType p_type) {
	int idx = CLAMP(static_cast<int>(p_type), 0, static_cast<int>(TYPE_MAX) - 1);
	return FORMAT[idx];
}

inline const char *map_type_get_string(MapType p_type) {
	int idx = CLAMP(static_cast<int>(p_type), 0, static_cast<int>(TYPE_MAX) - 1);
	return TYPESTR[idx];
}

inline Color map_type_get_default_color(MapType p_type) {
	int idx = CLAMP(static_cast<int>(p_type), 0, static_cast<int>(TYPE_MAX) - 1);
	return COLOR[idx];
}

#endif // TERRAIN3D_MAP_CLASS_H
