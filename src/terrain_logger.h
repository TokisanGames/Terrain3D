//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#ifndef TERRAINLOGGER_CLASS_H
#define TERRAINLOGGER_CLASS_H

#include "terrain.h"

/**
 * Prints warnings, errors, and regular messages to the console.
 * Regular messages are filtered based on the user specified debug level.
 * Warnings and errors always print except in release builds.
 * DEBUG_CONT is for continuously called prints like inside snapping
 */
#define ERROR 0
#define WARN 99  // Higher than DEBUG_MAX so doesn't impact gdscript enum
#define INFO 1
#define DEBUG 2
#define DEBUG_CONT 3
#define DEBUG_MAX 3
#define LOG(level, ...)                                                             \
	if (level == ERROR)                                                             \
		UtilityFunctions::push_error("Terrain3D::", __func__, ": ", __VA_ARGS__);   \
	else if (level == WARN)                                                         \
		UtilityFunctions::push_warning("Terrain3D::", __func__, ": ", __VA_ARGS__); \
	else if (Terrain3D::debug_level >= level)                                       \
	UtilityFunctions::print("Terrain3D::", __func__, ": ", __VA_ARGS__)

#endif // TERRAINLOGGER_CLASS_H