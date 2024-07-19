// Copyright © 2024 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_UTIL_CLASS_H
#define TERRAIN3D_UTIL_CLASS_H

#include <godot_cpp/classes/image.hpp>

#include "constants.h"
#include "generated_texture.h"

using namespace godot;

class Terrain3DUtil : public Object {
	GDCLASS(Terrain3DUtil, Object);
	CLASS_NAME_STATIC("Terrain3DUtil");

public:
	// Print info to the console
	static void print_dict(const String &name, const Dictionary &p_dict, const int p_level = 2); // Level 2: DEBUG
	static void dump_gentex(const GeneratedTexture p_gen, const String &name = "", const int p_level = 2);
	static void dump_maps(const TypedArray<Image> &p_maps, const String &p_name = "");

	// Image operations
	static Ref<Image> black_to_alpha(const Ref<Image> &p_image);
	static Vector2 get_min_max(const Ref<Image> &p_image);
	static Ref<Image> get_thumbnail(const Ref<Image> &p_image, const Vector2i &p_size = Vector2i(256, 256));
	static Ref<Image> get_filled_image(const Vector2i &p_size,
			const Color &p_color = COLOR_BLACK,
			const bool p_create_mipmaps = true,
			const Image::Format p_format = Image::FORMAT_MAX);
	static Ref<Image> load_image(const String &p_file_name, const int p_cache_mode = ResourceLoader::CACHE_MODE_IGNORE,
			const Vector2 &p_r16_height_range = Vector2(0.f, 255.f), const Vector2i &p_r16_size = Vector2i(0, 0));
	static Ref<Image> pack_image(const Ref<Image> &p_src_rgb, const Ref<Image> &p_src_r, const bool p_invert_green_channel = false);

protected:
	static void _bind_methods();
};

typedef Terrain3DUtil Util;

// Inline Functions

///////////////////////////
// Math
///////////////////////////

template <typename T>
T round_multiple(const T p_value, const T p_multiple) {
	if (p_multiple == 0) {
		return p_value;
	}
	return static_cast<T>(std::round(static_cast<double>(p_value) / static_cast<double>(p_multiple)) * static_cast<double>(p_multiple));
}

// Returns the bilinearly interpolated value derived from parameters:
// * 4 values to be interpolated
// * Positioned at the 4 corners of the p_pos00 - p_pos11 rectangle
// * Interpolated to the position p_pos, which is global, not a 0-1 percentage
inline real_t bilerp(const real_t p_v00, const real_t p_v01, const real_t p_v10, const real_t p_v11,
		const Vector2 &p_pos00, const Vector2 &p_pos11, const Vector2 &p_pos) {
	real_t x2x1 = p_pos11.x - p_pos00.x;
	real_t y2y1 = p_pos11.y - p_pos00.y;
	real_t x2x = p_pos11.x - p_pos.x;
	real_t y2y = p_pos11.y - p_pos.y;
	real_t xx1 = p_pos.x - p_pos00.x;
	real_t yy1 = p_pos.y - p_pos00.y;
	return (p_v00 * x2x * y2y +
				   p_v01 * x2x * yy1 +
				   p_v10 * xx1 * y2y +
				   p_v11 * xx1 * yy1) /
			(x2x1 * y2y1);
}

inline real_t bilerp(const real_t p_v00, const real_t p_v01, const real_t p_v10, const real_t p_v11,
		const Vector3 &p_pos00, const Vector3 &p_pos11, const Vector3 &p_pos) {
	Vector2 pos00 = Vector2(p_pos00.x, p_pos00.z);
	Vector2 pos11 = Vector2(p_pos11.x, p_pos11.z);
	Vector2 pos = Vector2(p_pos.x, p_pos.z);
	return bilerp(p_v00, p_v01, p_v10, p_v11, pos00, pos11, pos);
}

inline Rect2 aabb2rect(const AABB &p_aabb) {
	Rect2 rect;
	rect.position = Vector2(p_aabb.position.x, p_aabb.position.z);
	rect.size = Vector2(p_aabb.size.x, p_aabb.size.z);
	return rect;
}

///////////////////////////
// Controlmap Handling
///////////////////////////

// Getters read the 32-bit float as a 32-bit uint, then mask bits to retreive value
// Encoders return a full 32-bit uint with bits in the proper place for ORing
inline float as_float(const uint32_t p_value) { return *(float *)&p_value; }
inline uint32_t as_uint(const float p_value) { return *(uint32_t *)&p_value; }

inline uint8_t get_base(const uint32_t p_pixel) { return p_pixel >> 27 & 0x1F; }
inline uint8_t get_base(const float p_pixel) { return get_base(as_uint(p_pixel)); }
inline uint32_t enc_base(const uint8_t p_base) { return (p_base & 0x1F) << 27; }

inline uint8_t get_overlay(const uint32_t p_pixel) { return p_pixel >> 22 & 0x1F; }
inline uint8_t get_overlay(const float p_pixel) { return get_overlay(as_uint(p_pixel)); }
inline uint32_t enc_overlay(const uint8_t p_over) { return (p_over & 0x1F) << 22; }

inline uint8_t get_blend(const uint32_t p_pixel) { return p_pixel >> 14 & 0xFF; }
inline uint8_t get_blend(const float p_pixel) { return get_blend(as_uint(p_pixel)); }
inline uint32_t enc_blend(const uint8_t p_blend) { return (p_blend & 0xFF) << 14; }

inline uint8_t get_uv_rotation(const uint32_t p_pixel) { return p_pixel >> 10 & 0xF; }
inline uint8_t get_uv_rotation(const float p_pixel) { return get_uv_rotation(as_uint(p_pixel)); }
inline uint32_t enc_uv_rotation(const uint8_t p_rotation) { return (p_rotation & 0xF) << 10; }

inline uint8_t get_uv_scale(const uint32_t p_pixel) { return p_pixel >> 7 & 0x7; }
inline uint8_t get_uv_scale(const float p_pixel) { return get_uv_scale(as_uint(p_pixel)); }
inline uint32_t enc_uv_scale(const uint8_t p_scale) { return (p_scale & 0x7) << 7; }

inline bool is_hole(const uint32_t p_pixel) { return (p_pixel >> 2 & 0x1) == 1; }
inline bool is_hole(const float p_pixel) { return is_hole(as_uint(p_pixel)); }
inline uint32_t enc_hole(const bool p_hole) { return (p_hole & 0x1) << 2; }

inline bool is_nav(const uint32_t p_pixel) { return (p_pixel >> 1 & 0x1) == 1; }
inline bool is_nav(const float p_pixel) { return is_nav(as_uint(p_pixel)); }
inline uint32_t enc_nav(const bool p_nav) { return (p_nav & 0x1) << 1; }

inline bool is_auto(const uint32_t p_pixel) { return (p_pixel & 0x1) == 1; }
inline bool is_auto(const float p_pixel) { return is_auto(as_uint(p_pixel)); }
inline uint32_t enc_auto(const bool p_autosh) { return p_autosh & 0x1; }

// Aliases for GDScript since it can't handle overridden functions
inline uint32_t gd_get_base(const uint32_t p_pixel) { return get_base(p_pixel); }
inline uint32_t gd_enc_base(const uint32_t p_base) { return enc_base(p_base); }
inline uint32_t gd_get_overlay(const uint32_t p_pixel) { return get_overlay(p_pixel); }
inline uint32_t gd_enc_overlay(const uint32_t p_over) { return enc_overlay(p_over); }
inline uint32_t gd_get_blend(const uint32_t p_pixel) { return get_overlay(p_pixel); }
inline uint32_t gd_enc_blend(const uint32_t p_blend) { return enc_blend(p_blend); }
inline bool gd_is_hole(const uint32_t p_pixel) { return is_hole(p_pixel); }
inline bool gd_is_auto(const uint32_t p_pixel) { return is_auto(p_pixel); }
inline bool gd_is_nav(const uint32_t p_pixel) { return is_nav(p_pixel); }
inline uint32_t gd_get_uv_rotation(const uint32_t p_pixel) { return get_uv_rotation(p_pixel); }
inline uint32_t gd_enc_uv_rotation(const uint32_t p_rotation) { return enc_uv_rotation(p_rotation); }
inline uint32_t gd_get_uv_scale(const uint32_t p_pixel) { return get_uv_rotation(p_pixel); }
inline uint32_t gd_enc_uv_scale(const uint32_t p_scale) { return enc_uv_rotation(p_scale); }

///////////////////////////
// Memory
///////////////////////////

template <typename TType>
_FORCE_INLINE_ bool memdelete_safely(TType *&p_ptr) {
	if (p_ptr != nullptr) {
		memdelete(p_ptr);
		p_ptr = nullptr;
		return true;
	}
	return false;
}

_FORCE_INLINE_ bool remove_from_tree(Node *p_node) {
	// Note: is_in_tree() doesn't work in Godot-cpp 4.1.3
	if (p_node != nullptr) {
		Node *parent = p_node->get_parent();
		if (parent != nullptr) {
			parent->remove_child(p_node);
			return true;
		}
	}
	return false;
}

// UtilityFunctions::is_instance_valid() is faulty and shouldn't be used.
// Use this version instead on objects that might be freed by the user.
// See https://github.com/godotengine/godot-cpp/issues/1390#issuecomment-1937570699
_FORCE_INLINE_ bool is_instance_valid(const uint64_t p_instance_id, Object *p_object = nullptr) {
	Object *obj = ObjectDB::get_instance(p_instance_id);
	if (p_object != nullptr) {
		return p_instance_id > 0 && p_object == obj;
	} else {
		return p_instance_id > 0 && obj != nullptr;
	}
}

#endif // TERRAIN3D_UTIL_CLASS_H
