//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#ifndef TERRAINLOGGER_CLASS_H
#define TERRAINLOGGER_CLASS_H

#include "terrain.h"

#define ERR 0
#define INFO 1
#define DEBUG 2
#define DEBUG2 3
#define DEBUG_MAX 3
#define LOG(level, ...)                  \
	if (Terrain3D::debug_level >= level) \
	UtilityFunctions::print("Terrain3D::", __func__, ": ", __VA_ARGS__)

#endif // TERRAINLOGGER_CLASS_H