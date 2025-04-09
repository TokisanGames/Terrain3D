// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef LOGGER_CLASS_H
#define LOGGER_CLASS_H

#include <godot_cpp/variant/utility_functions.hpp>

#include "terrain_3d.h"

using namespace godot;

/**
 * Prints warnings, errors, and messages to the console.
 * Regular messages are filtered based on the user specified debug level.
 * Warnings and errors always print except in release builds.
 * EXTREME is for continuously called prints like inside snapping.
 * See Terrain3D::DebugLevel and Terrain3D::debug_level.
 *
 * Note that in DEBUG mode Godot will crash on quit due to an
 * access violation in editor_log.cpp EditorLog::_process_message().
 * This is most likely caused by us printing messages as Godot is
 * attempting to quit.
 */

#ifdef DEBUG_ENABLED
#define LOG(level, ...)                                                                                 \
	do {                                                                                                \
		if (level == ERROR)                                                                             \
			UtilityFunctions::push_error(__class__, ":", __func__, ":", __LINE__, ": ", __VA_ARGS__);   \
		else if (level == WARN)                                                                         \
			UtilityFunctions::push_warning(__class__, ":", __func__, ":", __LINE__, ": ", __VA_ARGS__); \
		else if (level <= Terrain3D::debug_level)                                                       \
			UtilityFunctions::print(__class__, ":", __func__, ":", __LINE__, ": ", __VA_ARGS__);        \
	} while (false); // Macro safety
#else
#define LOG(...)
#endif

#endif // LOGGER_CLASS_H