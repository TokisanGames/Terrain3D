// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef UTIL_CLASS_H
#define UTIL_CLASS_H

#include <godot_cpp/classes/image.hpp>

#include "constants.h"
#include "generated_tex.h"

using namespace godot;

class Util {
public:
	static inline const char *__class__ = "Terrain3DUtil";

	// Print info to the console
	static void print_dict(String name, const Dictionary &p_dict, int p_level = 1); // Defaults to INFO
	static void dump_gen(GeneratedTex p_gen, String name = "");
	static void dump_maps(const TypedArray<Image> p_maps, String p_name = "");

	// Image operations
	static Vector2 get_min_max(const Ref<Image> p_image);
	static Ref<Image> get_thumbnail(const Ref<Image> p_image, Vector2i p_size = Vector2i(256, 256));
	static Ref<Image> get_filled_image(Vector2i p_size,
			Color p_color = COLOR_BLACK,
			bool p_create_mipmaps = true,
			Image::Format p_format = Image::FORMAT_RF);
};

#endif // UTIL_CLASS_H