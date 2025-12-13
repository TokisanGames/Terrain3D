// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef CONSTANTS_CLASS_H
#define CONSTANTS_CLASS_H

// GDExtension uses the godot namespace, custom modules do not.
#if defined(GDEXTENSION) && !defined(GODOT_MODULE)
using namespace godot;
#endif

// Engine Shortcuts
#define RS RenderingServer::get_singleton()
#define PS PhysicsServer3D::get_singleton()
#define IS_EDITOR Engine::get_singleton()->is_editor_hint()

// Constants
#define COLOR_NAN Color(NAN, NAN, NAN, NAN)
#define COLOR_BLACK Color(0.0f, 0.0f, 0.0f, 1.0f)
#define COLOR_WHITE Color(1.0f, 1.0f, 1.0f, 1.0f)
#define COLOR_ROUGHNESS Color(1.0f, 1.0f, 1.0f, 0.5f)
#define COLOR_CHECKED Color(1.f, 1.f, 1.0f, -1.0f)
#define COLOR_NORMAL Color(0.5f, 0.5f, 1.0f, 1.0f)
#define COLOR_CONTROL Color(as_float(enc_auto(true)), 0.f, 0.f, 1.0f)

// For consistency between MSVC, gcc, clang
#ifndef FLT_MAX
#define FLT_MAX __FLT_MAX__
#endif
#ifndef FLT_MIN
#define FLT_MIN __FLT_MIN__
#endif

// Terrain3D::_warnings is uint8_t
#define WARN_MISMATCHED_SIZE 0x01
#define WARN_MISMATCHED_FORMAT 0x02
#define WARN_MISMATCHED_MIPMAPS 0x04
#define WARN_ALL 0xFF

// Global Types

#define V2(x) Vector2(x, x)
#define V2I(x) Vector2i(x, x)
#define V3(x) Vector3(x, x, x)
static const Vector2 V2_ZERO{ 0.f, 0.f };
static const Vector2 V2_MAX{ FLT_MAX, FLT_MAX };
static const Vector2i V2I_ZERO{ 0, 0 };
static const Vector2i V2I_MAX{ INT32_MAX, INT32_MAX };
static const Vector3 V3_ZERO{ 0.f, 0.f, 0.f };
static const Vector3 V3_MAX{ FLT_MAX, FLT_MAX, FLT_MAX };
static const Vector3 V3_NAN{ NAN, NAN, NAN };
static const Vector3 V3_UP{ 0.f, 1.f, 0.f };

// Set class name for logger.h

#define CLASS_NAME() const String __class__ = get_class_static() + \
		String("#") + String::num_uint64(get_instance_id()).right(4);

#define CLASS_NAME_STATIC(p_name) static inline const char *__class__ = p_name;

// Validation macros

#define ASSERT(cond, ret)                                                                            \
	if (!(cond)) {                                                                                   \
		UtilityFunctions::push_error("Assertion '", #cond, "' failed at ", __FILE__, ":", __LINE__); \
		return ret;                                                                                  \
	}

#define VOID // a return value for void, to avoid compiler warnings

#define IS_INIT(ret) \
	if (!_terrain) { \
		return ret;  \
	}

#define IS_INIT_MESG(mesg, ret) \
	if (!_terrain) {            \
		LOG(ERROR, mesg);       \
		return ret;             \
	}

#define IS_INIT_COND(cond, ret) \
	if (!_terrain || cond) {    \
		return ret;             \
	}

#define IS_INIT_COND_MESG(cond, mesg, ret) \
	if (!_terrain || cond) {               \
		LOG(ERROR, mesg);                  \
		return ret;                        \
	}

#define IS_INSTANCER_INIT(ret)                     \
	if (!_terrain || !_terrain->get_instancer()) { \
		return ret;                                \
	}

#define IS_INSTANCER_INIT_MESG(mesg, ret)          \
	if (!_terrain || !_terrain->get_instancer()) { \
		LOG(ERROR, mesg);                          \
		return ret;                                \
	}

#define IS_DATA_INIT(ret)                     \
	if (!_terrain || !_terrain->get_data()) { \
		return ret;                           \
	}

#define IS_DATA_INIT_MESG(mesg, ret)          \
	if (!_terrain || !_terrain->get_data()) { \
		LOG(ERROR, mesg);                     \
		return ret;                           \
	}

#endif // CONSTANTS_CLASS_H