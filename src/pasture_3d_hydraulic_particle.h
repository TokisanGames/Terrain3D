// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Native Particle Hydraulic Erosion solver (PASTURE3D_EROSION_NODES_EXPANSION_SPEC.md §3.1 Phase 1).
// Simulates Lagrangian water droplets with inertia, momentum, capacity, erosion pickup, and deposition.

#ifndef PASTURE_3D_HYDRAULIC_PARTICLE_H
#define PASTURE_3D_HYDRAULIC_PARTICLE_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <vector>

namespace godot {

struct HydraulicParticleParams {
	int droplet_count = 25000;
	int max_lifetime = 30;
	float inertia = 0.05f;
	float sediment_capacity = 4.0f;
	float erosion_speed = 0.3f;
	float deposition_speed = 0.3f;
	float evaporation_rate = 0.01f;
	float min_slope = 0.01f;
	float gravity = 4.0f;
	int64_t seed = 1337;
	PackedFloat32Array mask;

	static HydraulicParticleParams from_dict(const Dictionary &p_dict);
};

struct HydraulicParticleResult {
	bool ok = false;
	PackedFloat32Array height;
	PackedFloat32Array sediment;
	PackedFloat32Array flow;
	PackedFloat32Array water_depth;

	Dictionary to_dict() const;
};

// C++ native Lagrangian droplet solver.
// Matches the GDScript Tier 1 oracle bit-for-bit (<= 2e-6 m).
HydraulicParticleResult hydraulic_particle_solve(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const HydraulicParticleParams &p_params);

} // namespace godot

#endif // PASTURE_3D_HYDRAULIC_PARTICLE_H
