// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef LOGGER_CLASS_H
#define LOGGER_CLASS_H

#include <godot_cpp/variant/utility_functions.hpp>

#include "terrain_3d.h"

using namespace godot;

/**
 * Prints warnings, errors, and regular messages to the console.
 * Regular messages are filtered based on the user specified debug level.
 * Warnings and errors always print except in release builds.
 * DEBUG_CONT is for continuously called prints like inside snapping
 *
 * Note that in DEBUG mode Godot will crash on quit due to an
 * access violation in editor_log.cpp EditorLog::_process_message().
 * This is most likely caused by us printing messages as Godot is
 * attempting to quit.
 */
#define MESG -1 // Always print
#define ERROR 0
#define WARN 99 // Higher than DEBUG_MAX so doesn't impact gdscript enum
#define INFO 1
#define DEBUG 2
#define DEBUG_CONT 3
#define DEBUG_MAX 3
#define LOG(level, ...)                                                              \
	if (level == ERROR)                                                              \
		UtilityFunctions::push_error(__class__, ":", __func__, ": ", __VA_ARGS__);   \
	else if (level == WARN)                                                          \
		UtilityFunctions::push_warning(__class__, ":", __func__, ": ", __VA_ARGS__); \
	else if (Terrain3D::debug_level >= level)                                        \
		UtilityFunctions::print(__class__, ":", __func__, ": ", __VA_ARGS__);

#endif // LOGGER_CLASS_H