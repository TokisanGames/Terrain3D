// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_UTIL_CLASS_H
#define TERRAIN3D_UTIL_CLASS_H

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "constants.h"
#include "generated_texture.h"
#include "terrain_3d.h"

// This file holds stateless utility functions for both C++ and GDScript
// The class exposes static member and inline functions to GDscript
// The inline functions below are not part of the class but are in the namespace, eg bilerp
// However some of these inline functions are also exposed to GDScript

class Terrain3DUtil : public Object {
	GDCLASS(Terrain3DUtil, Object);
	CLASS_NAME_STATIC("Terrain3DUtil");

public:
	// Print info to the console
	static void print_arr(const String &p_name, const Array &p_arr, const int p_level = 2); // Level 2: DEBUG
	static void print_dict(const String &p_name, const Dictionary &p_dict, const int p_level = 2); // Level 2: DEBUG
	static void dump_gentex(const GeneratedTexture &p_gen, const String &p_name = "");
	static void dump_maps(const TypedArray<Image> &p_maps, const String &p_name = "");

	// String functions
	static Vector2i filename_to_location(const String &p_filename);
	static Vector2i string_to_location(const String &p_string);
	static String location_to_filename(const Vector2i &p_region_loc);
	static String location_to_string(const Vector2i &p_region_loc);
	static PackedStringArray get_files(const String &p_dir, const String &p_glob = "*");

	// Image operations
	static Ref<Image> black_to_alpha(const Ref<Image> &p_image);
	static Vector2 get_min_max(const Ref<Image> &p_image);
	static Ref<Image> get_thumbnail(const Ref<Image> &p_image, const Vector2i &p_size = V2I(256));
	static Ref<Image> get_filled_image(const Vector2i &p_size,
			const Color &p_color = COLOR_BLACK,
			const bool p_create_mipmaps = true,
			const Image::Format p_format = Image::FORMAT_MAX);
	static Ref<Image> load_image(const String &p_file_name, const int p_cache_mode = ResourceLoader::CACHE_MODE_IGNORE,
			const Vector2 &p_r16_height_range = Vector2(0.f, 255.f), const Vector2i &p_r16_size = V2I_ZERO);
	static Ref<Image> pack_image(const Ref<Image> &p_src_rgb,
			const Ref<Image> &p_src_a,
			const bool p_invert_green = false,
			const bool p_invert_alpha = false,
			const bool p_normalize_alpha = false,
			const int p_alpha_channel = 0);
	static Ref<Image> luminance_to_height(const Ref<Image> &p_src_rgb);
	static void benchmark(Terrain3D *p_terrain);

protected:
	static void _bind_methods();
};

using Util = Terrain3DUtil;

// Inline Functions

///////////////////////////
// Type Conversion
///////////////////////////

// Convert Vector3 to Vector2i, ignoring Y
inline Vector2i v3v2i(const Vector3 &p_v3) {
	return Vector2i(p_v3.x, p_v3.z);
}

// Convert Vector2i to Vector3, ignoring Y
inline Vector3 v2iv3(const Vector2i &p_v2) {
	return Vector3(p_v2.x, 0., p_v2.y);
}

// Convert Vector3 to Vector2, ignoring Y
inline Vector2 v3v2(const Vector3 &p_v3) {
	return Vector2(p_v3.x, p_v3.z);
}

// Convert Vector2 to Vector3, ignoring Y
inline Vector3 v2v3(const Vector2 &p_v2) {
	return Vector3(p_v2.x, 0., p_v2.y);
}

///////////////////////////
// Math
///////////////////////////

inline bool is_valid_region_size(int value) {
	return value >= 64 && value <= 2048 && is_power_of_2(value);
}

// Integer round to multiples
// https://stackoverflow.com/questions/3407012/rounding-up-to-the-nearest-multiple-of-a-number

// Integer round up to a multiple
template <typename T>
inline T int_ceil_mult(const T numToRound, const T multiple) {
	static_assert(std::numeric_limits<T>::is_integer, "Only integer types are allowed");
	ASSERT(multiple != 0, 0);
	T isPositive = (T)(numToRound >= 0);
	return ((numToRound + isPositive * (multiple - 1)) / multiple) * multiple;
}

// Integer round up to a power of 2 multiple (3.7x faster)
template <typename T>
inline T int_ceil_pow2(T numToRound, T multiple) {
	static_assert(std::numeric_limits<T>::is_integer, "Only integer types are allowed");
	ASSERT(is_power_of_2(multiple), int_ceil_mult(numToRound, multiple));
	return (numToRound + multiple - 1) & -multiple;
}

// Integer round to nearest +/- multiple
// https://stackoverflow.com/questions/29557459/round-to-nearest-multiple-of-a-number
template <typename T>
inline T int_round_mult(const T numToRound, const T multiple) {
	static_assert(std::numeric_limits<T>::is_integer, "Only integer types are allowed");
	ASSERT(multiple != 0, 0);
	T result = abs(numToRound) + multiple / 2;
	result -= result % multiple;
	result *= numToRound > 0 ? 1 : -1;
	return result;
}

// Integer division with rounding up, down, nearest
// https : //stackoverflow.com/questions/2422712/rounding-integer-division-instead-of-truncating/58568736#58568736
#define V2I_DIVIDE_CEIL(v, f) Vector2i(int_divide_ceil(v.x, int32_t(f)), int_divide_ceil(v.y, int32_t(f)))
#define V2I_DIVIDE_FLOOR(v, f) Vector2i(int_divide_floor(v.x, int32_t(f)), int_divide_floor(v.y, int32_t(f)))

// Integer division rounding up
template <typename T>
inline T int_divide_ceil(const T numer, const T denom) {
	static_assert(std::numeric_limits<T>::is_integer, "Only integer types are allowed");
	T result = ((numer) < 0) != ((denom) < 0) ? (numer) / (denom) : ((numer) + ((denom) < 0 ? (denom) + 1 : (denom)-1)) / (denom);
	return result;
}

// Integer division rounding down
template <typename T>
inline T int_divide_floor(const T numer, const T denom) {
	static_assert(std::numeric_limits<T>::is_integer, "Only integer types are allowed");
	T result = ((numer) < 0) != ((denom) < 0) ? ((numer) - ((denom) < 0 ? (denom) + 1 : (denom)-1)) / (denom) : (numer) / (denom);
	return result;
}

// Integer division rounding to nearest int
template <typename T>
inline T int_divide_round(const T numer, const T denom) {
	static_assert(std::numeric_limits<T>::is_integer, "Only integer types are allowed");
	T result = ((numer) < 0) != ((denom) < 0) ? ((numer) - ((denom) / 2)) / (denom) : ((numer) + ((denom) / 2)) / (denom);
	return result;
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
// Aliases for GDScript prefixed with gd_ since it can't handle overridden functions
inline float as_float(const uint32_t p_value) { return *(float *)&p_value; }
inline uint32_t as_uint(const float p_value) { return *(uint32_t *)&p_value; }

inline uint8_t get_base(const uint32_t p_pixel) { return p_pixel >> 27 & 0x1F; }
inline uint8_t get_base(const float p_pixel) { return get_base(as_uint(p_pixel)); }
inline uint32_t enc_base(const uint8_t p_base) { return (p_base & 0x1F) << 27; }
inline uint32_t gd_get_base(const uint32_t p_pixel) { return get_base(p_pixel); }
inline uint32_t gd_enc_base(const uint32_t p_base) { return enc_base(p_base); }

inline uint8_t get_overlay(const uint32_t p_pixel) { return p_pixel >> 22 & 0x1F; }
inline uint8_t get_overlay(const float p_pixel) { return get_overlay(as_uint(p_pixel)); }
inline uint32_t enc_overlay(const uint8_t p_over) { return (p_over & 0x1F) << 22; }
inline uint32_t gd_get_overlay(const uint32_t p_pixel) { return get_overlay(p_pixel); }
inline uint32_t gd_enc_overlay(const uint32_t p_over) { return enc_overlay(p_over); }

inline uint8_t get_blend(const uint32_t p_pixel) { return p_pixel >> 14 & 0xFF; }
inline uint8_t get_blend(const float p_pixel) { return get_blend(as_uint(p_pixel)); }
inline uint32_t enc_blend(const uint8_t p_blend) { return (p_blend & 0xFF) << 14; }
inline uint32_t gd_get_blend(const uint32_t p_pixel) { return get_blend(p_pixel); }
inline uint32_t gd_enc_blend(const uint32_t p_blend) { return enc_blend(p_blend); }

inline uint8_t get_uv_rotation(const uint32_t p_pixel) { return p_pixel >> 10 & 0xF; }
inline uint8_t get_uv_rotation(const float p_pixel) { return get_uv_rotation(as_uint(p_pixel)); }
inline uint32_t enc_uv_rotation(const uint8_t p_rotation) { return (p_rotation & 0xF) << 10; }
inline uint32_t gd_get_uv_rotation(const uint32_t p_pixel) { return get_uv_rotation(p_pixel); }
inline uint32_t gd_enc_uv_rotation(const uint32_t p_rotation) { return enc_uv_rotation(p_rotation); }

inline uint8_t get_uv_scale(const uint32_t p_pixel) { return p_pixel >> 7 & 0x7; }
inline uint8_t get_uv_scale(const float p_pixel) { return get_uv_scale(as_uint(p_pixel)); }
inline uint32_t enc_uv_scale(const uint8_t p_scale) { return (p_scale & 0x7) << 7; }
inline uint32_t gd_get_uv_scale(const uint32_t p_pixel) { return get_uv_scale(p_pixel); }
inline uint32_t gd_enc_uv_scale(const uint32_t p_scale) { return enc_uv_scale(p_scale); }

inline bool is_hole(const uint32_t p_pixel) { return (p_pixel >> 2 & 0x1) == 1; }
inline bool is_hole(const float p_pixel) { return is_hole(as_uint(p_pixel)); }
inline uint32_t enc_hole(const bool p_hole) { return (p_hole & 0x1) << 2; }
inline bool gd_is_hole(const uint32_t p_pixel) { return is_hole(p_pixel); }

inline bool is_nav(const uint32_t p_pixel) { return (p_pixel >> 1 & 0x1) == 1; }
inline bool is_nav(const float p_pixel) { return is_nav(as_uint(p_pixel)); }
inline uint32_t enc_nav(const bool p_nav) { return (p_nav & 0x1) << 1; }
inline bool gd_is_nav(const uint32_t p_pixel) { return is_nav(p_pixel); }

inline bool is_auto(const uint32_t p_pixel) { return (p_pixel & 0x1) == 1; }
inline bool is_auto(const float p_pixel) { return is_auto(as_uint(p_pixel)); }
inline uint32_t enc_auto(const bool p_auto) { return p_auto & 0x1; }
inline bool gd_is_auto(const uint32_t p_pixel) { return is_auto(p_pixel); }

///////////////////////////
// Memory
///////////////////////////

template <typename TType>
_FORCE_INLINE_ bool memdelete_safely(TType *&p_ptr) {
	if (p_ptr) {
		memdelete(p_ptr);
		p_ptr = nullptr;
		return true;
	}
	return false;
}

_FORCE_INLINE_ bool remove_from_tree(Node *p_node) {
	// Note: is_in_tree() doesn't work in Godot-cpp 4.1.3
	if (p_node) {
		Node *parent = p_node->get_parent();
		if (parent) {
			parent->remove_child(p_node);
			return true;
		}
	}
	return false;
}

_FORCE_INLINE_ String ptr_to_str(const void *p_ptr) {
	return "0x" + String::num_uint64(uint64_t(p_ptr), 16, true);
}

// Trait to detect types with _native_ptr(): Dictionary, Array, String, etc
template <typename T, typename = void>
struct has_native_ptr : std::false_type {};

template <typename T>
struct has_native_ptr<T, std::void_t<decltype(std::declval<T>()._native_ptr())>>
		: std::true_type {};

// Returns true if Variants share an internal pointer
template <typename T>
_FORCE_INLINE_ bool shares_ptr(const T &a, const T &b) {
	static_assert(has_native_ptr<T>::value); // Enforce type check via trait
	static_assert(sizeof(godot::Variant) == 24);
	auto pa = static_cast<const uint8_t *>(a._native_ptr());
	auto pb = static_cast<const uint8_t *>(b._native_ptr());
	return *reinterpret_cast<const void *const *>(pa + 8) ==
			*reinterpret_cast<const void *const *>(pb + 8);
}

// Returns if A is different from B
// O(1) pointer compare for Array/TypedArray/Dictionary
// Operator==() otherwise
// Could be extended for PackedArray and other special types
template <typename T>
_FORCE_INLINE_ bool differs(T &a, const T &b) {
	if constexpr (std::is_base_of_v<godot::Array, T> ||
			std::is_base_of_v<godot::Dictionary, T>) {
		return !shares_ptr(a, b);
	} else {
		return !(a == b);
	}
}

// Sets A if different from B, otherwise returns
#define SET_IF_DIFF(a, b) \
	if (differs(a, b)) {  \
		a = b;            \
	} else {              \
		return;           \
	}

#endif // TERRAIN3D_UTIL_CLASS_H
