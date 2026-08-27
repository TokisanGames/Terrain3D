// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// TemplateGraphNativeKernel — Boilerplate starting header for a C++ GDExtension kernel.

#ifndef TEMPLATE_GRAPH_NATIVE_KERNEL_H
#define TEMPLATE_GRAPH_NATIVE_KERNEL_H

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

PackedFloat32Array template_filter_solve(const PackedFloat32Array &p_surface,
		const PackedFloat32Array &p_mask, int p_gw, int p_gh, double p_intensity);

} // namespace godot

#endif // TEMPLATE_GRAPH_NATIVE_KERNEL_H
