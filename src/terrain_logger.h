//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#ifndef TERRAINLOGGER_CLASS_H
#define TERRAINLOGGER_CLASS_H

#include "terrain.h"

#define ERROR 0
#define WARN 1
#define INFO 2
#define DEBUG 3
#define DEBUG_CONT 4
#define DEBUG_MAX 4
#define LOG(level, ...)                                                             \
	if (level == ERROR)                                                             \
		UtilityFunctions::push_error("Terrain3D::", __func__, ": ", __VA_ARGS__);   \
	else if (level == WARN)                                                         \
		UtilityFunctions::push_warning("Terrain3D::", __func__, ": ", __VA_ARGS__); \
	else if (Terrain3D::debug_level >= level)                                       \
	UtilityFunctions::print("Terrain3D::", __func__, ": ", __VA_ARGS__)

#endif // TERRAINLOGGER_CLASS_H