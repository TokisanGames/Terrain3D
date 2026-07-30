// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/core/class_db.hpp>

#include "logger.h"
#include "pasture_3d_wave_profile.h"

///////////////////////////
// Public Functions
///////////////////////////

// Every setter emits changed(). Pool3DManager listens for it and re-uploads the
// table into the materials it has cached for this profile -- which is what makes
// dragging a knob in the inspector move ten ponds at once, and is the only reason
// the manager does not have to poll.

void Pasture3DWaveProfile::set_profile_name(const StringName &p_name) {
	if (_profile_name == p_name) {
		return;
	}
	_profile_name = p_name;
	emit_changed();
}

void Pasture3DWaveProfile::set_wave_count(const int p_count) {
	_waves.set_count(p_count);
	emit_changed();
}

void Pasture3DWaveProfile::set_direction_deg(const real_t p_deg) {
	_waves.set_direction_deg((float)p_deg);
	emit_changed();
}

void Pasture3DWaveProfile::set_spread_deg(const real_t p_deg) {
	_waves.set_spread_deg((float)p_deg);
	emit_changed();
}

void Pasture3DWaveProfile::set_amplitude(const real_t p_metres) {
	_waves.set_amplitude((float)p_metres);
	emit_changed();
}

void Pasture3DWaveProfile::set_length_max(const real_t p_metres) {
	_waves.set_length_max((float)p_metres);
	emit_changed();
}

void Pasture3DWaveProfile::set_steepness(const real_t p_steepness) {
	_waves.set_steepness((float)p_steepness);
	emit_changed();
}

void Pasture3DWaveProfile::set_loop_period(const real_t p_seconds) {
	if (Math::is_equal_approx(_waves.get_loop_period(), (float)p_seconds)) {
		return;
	}
	_waves.set_loop_period((float)p_seconds);
	emit_changed();
}

PackedVector4Array Pasture3DWaveProfile::get_shader_table() {
	_ensure_built();
	return _waves.get_shader_table();
}

real_t Pasture3DWaveProfile::get_amplitude_sum() {
	_ensure_built();
	return (real_t)_waves.get_amplitude_sum();
}

/**
 * Shortest wavelength actually in the table.
 *
 * Read off the built table rather than derived from length_max, because the series
 * does not run to a fixed ratio: WaterWaves floors it at MIN_WAVELENGTH for large
 * bodies but continues to length_max/2 for small ones (the pond case). Deriving it
 * would reproduce that rule in a second place and get it wrong the first time the
 * rule changed.
 */
real_t Pasture3DWaveProfile::get_min_wavelength() {
	_ensure_built();
	PackedVector4Array table = _waves.get_shader_table();
	real_t shortest = 0.f;
	for (int i = 0; i < table.size(); i++) {
		// Slots past the count are zero-amplitude padding and carry no wavelength
		// worth reporting; including them would return the padding's default.
		if (table[i].z <= 0.f) {
			continue;
		}
		if (shortest <= 0.f || (real_t)table[i].w < shortest) {
			shortest = (real_t)table[i].w;
		}
	}
	return shortest;
}

Vector3 Pasture3DWaveProfile::get_surface_point(const Vector2 &p_domain_xz, const real_t p_time) {
	_ensure_built();
	return _waves.get_position(p_domain_xz, (float)p_time);
}

real_t Pasture3DWaveProfile::get_height_at(const Vector2 &p_domain_xz, const real_t p_time) {
	_ensure_built();
	return (real_t)_waves.get_height(p_domain_xz, (float)p_time);
}

Vector3 Pasture3DWaveProfile::get_normal_at(const Vector2 &p_domain_xz, const real_t p_time) {
	_ensure_built();
	return _waves.get_normal(p_domain_xz, (float)p_time);
}

Vector2 Pasture3DWaveProfile::solve_domain(const Vector2 &p_target_xz, const real_t p_time) {
	_ensure_built();
	return _waves.solve_domain(p_target_xz, (float)p_time);
}

///////////////////////////
// Protected Functions
///////////////////////////

void Pasture3DWaveProfile::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_profile_name", "name"), &Pasture3DWaveProfile::set_profile_name);
	ClassDB::bind_method(D_METHOD("get_profile_name"), &Pasture3DWaveProfile::get_profile_name);
	ClassDB::bind_method(D_METHOD("set_wave_count", "count"), &Pasture3DWaveProfile::set_wave_count);
	ClassDB::bind_method(D_METHOD("get_wave_count"), &Pasture3DWaveProfile::get_wave_count);
	ClassDB::bind_method(D_METHOD("set_direction_deg", "degrees"), &Pasture3DWaveProfile::set_direction_deg);
	ClassDB::bind_method(D_METHOD("get_direction_deg"), &Pasture3DWaveProfile::get_direction_deg);
	ClassDB::bind_method(D_METHOD("set_spread_deg", "degrees"), &Pasture3DWaveProfile::set_spread_deg);
	ClassDB::bind_method(D_METHOD("get_spread_deg"), &Pasture3DWaveProfile::get_spread_deg);
	ClassDB::bind_method(D_METHOD("set_amplitude", "metres"), &Pasture3DWaveProfile::set_amplitude);
	ClassDB::bind_method(D_METHOD("get_amplitude"), &Pasture3DWaveProfile::get_amplitude);
	ClassDB::bind_method(D_METHOD("set_length_max", "metres"), &Pasture3DWaveProfile::set_length_max);
	ClassDB::bind_method(D_METHOD("get_length_max"), &Pasture3DWaveProfile::get_length_max);
	ClassDB::bind_method(D_METHOD("set_steepness", "steepness"), &Pasture3DWaveProfile::set_steepness);
	ClassDB::bind_method(D_METHOD("get_steepness"), &Pasture3DWaveProfile::get_steepness);
	ClassDB::bind_method(D_METHOD("set_loop_period", "seconds"), &Pasture3DWaveProfile::set_loop_period);
	ClassDB::bind_method(D_METHOD("get_loop_period"), &Pasture3DWaveProfile::get_loop_period);

	ClassDB::bind_method(D_METHOD("get_shader_table"), &Pasture3DWaveProfile::get_shader_table);
	ClassDB::bind_method(D_METHOD("get_amplitude_sum"), &Pasture3DWaveProfile::get_amplitude_sum);
	ClassDB::bind_method(D_METHOD("get_min_wavelength"), &Pasture3DWaveProfile::get_min_wavelength);

	ClassDB::bind_method(D_METHOD("get_surface_point", "domain_xz", "time"), &Pasture3DWaveProfile::get_surface_point);
	ClassDB::bind_method(D_METHOD("get_height_at", "domain_xz", "time"), &Pasture3DWaveProfile::get_height_at);
	ClassDB::bind_method(D_METHOD("get_normal_at", "domain_xz", "time"), &Pasture3DWaveProfile::get_normal_at);
	ClassDB::bind_method(D_METHOD("solve_domain", "target_xz", "time"), &Pasture3DWaveProfile::solve_domain);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "profile_name"), "set_profile_name", "get_profile_name");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "wave_count", PROPERTY_HINT_RANGE, "1,8,1"), "set_wave_count", "get_wave_count");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "direction_deg", PROPERTY_HINT_RANGE, "-360,360,0.5"), "set_direction_deg", "get_direction_deg");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spread_deg", PROPERTY_HINT_RANGE, "0,180,0.5"), "set_spread_deg", "get_spread_deg");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "amplitude", PROPERTY_HINT_RANGE, "0,20,0.01,or_greater"), "set_amplitude", "get_amplitude");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "length_max", PROPERTY_HINT_RANGE, "1,1000,0.5,or_greater"), "set_length_max", "get_length_max");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "steepness", PROPERTY_HINT_RANGE, "0,0.6,0.01"), "set_steepness", "get_steepness");
}
