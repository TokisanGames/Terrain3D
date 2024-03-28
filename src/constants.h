// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef CONSTANTS_CLASS_H
#define CONSTANTS_CLASS_H

using namespace godot;

//////////////////////////////////////
// Macro Constants & Syntactic Sugar
//////////////////////////////////////

#define RS RenderingServer::get_singleton()

#define COLOR_NAN Color(NAN, NAN, NAN, NAN)
#define COLOR_BLACK Color(0.0f, 0.0f, 0.0f, 1.0f)
#define COLOR_WHITE Color(1.0f, 1.0f, 1.0f, 1.0f)
#define COLOR_ROUGHNESS Color(1.0f, 1.0f, 1.0f, 0.5f)
#define COLOR_CHECKED Color(1.f, 1.f, 1.0f, -1.0f)
#define COLOR_NORMAL Color(0.5f, 0.5f, 1.0f, 1.0f)
#define COLOR_CONTROL Color(as_float(enc_auto(true)), 0.f, 0.f, 1.0f)

#ifndef __FLT_MAX__
#define __FLT_MAX__ FLT_MAX
#endif

#ifdef REAL_T_IS_DOUBLE
typedef PackedFloat64Array PackedRealArray;
#else
typedef PackedFloat32Array PackedRealArray;
#endif

#define CLASS_NAME() const String __class__ = get_class_static() + \
		String("#") + String::num_uint64(get_instance_id()).right(4);

#define CLASS_NAME_STATIC(p_name) static inline const char *__class__ = p_name;

#endif // CONSTANTS_CLASS_H