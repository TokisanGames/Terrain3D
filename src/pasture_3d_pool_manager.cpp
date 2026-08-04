// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "logger.h"
#include "pasture_3d_ocean.h"
#include "pasture_3d_pool_manager.h"

///////////////////////////
// Private Functions
///////////////////////////

/**
 * Cache key for one (base material, profile) pair.
 *
 * Keyed on the base's INSTANCE ID and not its resource path, because the base is
 * frequently pathless: a material the user made unique into the scene, or one built
 * in code by a test, has no path at all and every one of them would collide on "".
 */
String Pasture3DPoolManager::_cache_key(const Ref<Material> &p_base, const StringName &p_profile) const {
	uint64_t id = p_base.is_valid() ? (uint64_t)p_base->get_instance_id() : 0;
	return String::num_uint64(id) + "|" + String(p_profile);
}

/**
 * Writes a profile's table into one material.
 *
 * Only ShaderMaterial carries the uniforms; anything else is left alone rather than
 * refused. A user is allowed to put a StandardMaterial3D on a pool -- it will not be
 * water, and Pasture3DPool warns about it in Phase 3 -- but it must not error here every
 * frame.
 */
void Pasture3DPoolManager::_upload_into(const Ref<Material> &p_material, const Ref<Pasture3DWaveProfile> &p_profile) {
	ShaderMaterial *mat = Object::cast_to<ShaderMaterial>(p_material.ptr());
	if (!mat || p_profile.is_null()) {
		return;
	}
	// The period is the manager's, not the profile's (§5.3), and it has to be in
	// place before the table is built: WaterWaves quantises every frequency to a
	// whole number of cycles in the period, which is what makes the clock's wrap
	// seamless. Setting it after would upload a table quantised to the old one.
	p_profile->set_loop_period(_loop_period);
	mat->set_shader_parameter("_waves", p_profile->get_shader_table());
	mat->set_shader_parameter("wave_steepness", p_profile->get_steepness());
	_upload_count++;
}

/**
 * Declares the water globals at runtime if project.godot did not.
 *
 * Moved verbatim from Pasture3D::_register_water_globals() in Phase 2. The editor
 * plugin persists these to project.godot, which is what makes them exist at engine
 * startup and therefore resolve in exported builds; this is the fallback for the
 * first run after enabling the plugin, and for projects where the settings were
 * never written.
 *
 * Phase 1 probes of the water shader work established the rules:
 *   - ProjectSettings::has_setting() is the only runtime-safe existence check.
 *     global_shader_parameter_get_list() and _get() are editor-only and error out
 *     in a game build.
 *   - Writing ProjectSettings at runtime does NOT register with RenderingServer;
 *     its global table is built from project.godot at startup and only then.
 */
void Pasture3DPoolManager::register_water_globals() {
	// Process-global, not per-node: the RenderingServer table is shared, so a
	// second manager (or an ocean) must not try to add what the first already did.
	static bool s_registered = false;
	if (s_registered) {
		return;
	}
	s_registered = true;

	struct GlobalDecl {
		const char *name;
		RenderingServer::GlobalShaderParameterType type;
		Variant initial;
	};
	const GlobalDecl decls[] = {
		{ "water_time", RenderingServer::GLOBAL_VAR_TYPE_FLOAT, 0.0f },
		{ "water_sun_direction", RenderingServer::GLOBAL_VAR_TYPE_VEC3, Vector3(0.f, -1.f, 0.f) },
		{ "water_sun_color", RenderingServer::GLOBAL_VAR_TYPE_VEC3, Vector3(1.f, 1.f, 1.f) },
		// The clock's wrap period. The shader needs it, not just the clock:
		// anything else that advances with water_time -- the scrolling detail
		// texture -- has to quantise its own rate to the same loop or the wrap that
		// is seamless for the waves is a visible jump for the ripples.
		{ "water_time_period", RenderingServer::GLOBAL_VAR_TYPE_FLOAT, 120.0f },
	};
	ProjectSettings *settings = ProjectSettings::get_singleton();
	for (const GlobalDecl &decl : decls) {
		if (settings && settings->has_setting(String("shader_globals/") + decl.name)) {
			continue;
		}
		// No LOG here: this is a static member and the LOG macro reaches for the
		// instance's __class__.
		RS->global_shader_parameter_add(decl.name, decl.type, decl.initial);
	}
}

bool Pasture3DPoolManager::is_plugin_written_param(const StringName &p_name) {
	// The `_` prefix is this codebase's existing marker for a uniform the plugin fills
	// in rather than one the artist sets -- _waves, _mesh_size, _subdiv,
	// _vertex_spacing, _target_pos, _water_domain_origin all carry it, in the water
	// shaders and in the legacy one alike. The two exceptions are named as art knobs
	// because they read as art knobs, but the profile and the ocean own them.
	return String(p_name).begins_with("_") || p_name == StringName("sea_level") ||
			p_name == StringName("wave_steepness");
}

bool Pasture3DPoolManager::sync_material_params(const Ref<Material> &p_base, const Ref<Material> &p_target) {
	ShaderMaterial *base = Object::cast_to<ShaderMaterial>(p_base.ptr());
	ShaderMaterial *target = Object::cast_to<ShaderMaterial>(p_target.ptr());
	if (!base || !target || base == target) {
		return false;
	}
	bool wrote = false;
	// The SHADER can change under the material too -- dropping a different .gdshader on
	// a preset is how someone moves a body between tiers -- and a target still
	// compiling the old one would silently ignore every uniform copied below.
	Ref<Shader> shader = base->get_shader();
	if (target->get_shader() != shader) {
		target->set_shader(shader);
		wrote = true;
	}
	if (target->get_render_priority() != base->get_render_priority()) {
		target->set_render_priority(base->get_render_priority());
		wrote = true;
	}
	if (target->get_next_pass() != base->get_next_pass()) {
		target->set_next_pass(base->get_next_pass());
		wrote = true;
	}
	if (shader.is_null()) {
		return wrote;
	}
	// Driven off the SHADER's uniform list rather than the base's property list: a
	// parameter the base leaves at its shader default is absent from the base's own
	// storage but may well be set on the target from an earlier sync, and only walking
	// every uniform clears it back. get_shader_parameter() returns nil for an unset one,
	// and setting nil is how a ShaderMaterial spells "use the shader's default".
	Array uniforms = shader->get_shader_uniform_list();
	for (int i = 0; i < uniforms.size(); i++) {
		Dictionary uniform = uniforms[i];
		StringName name = uniform.get("name", StringName());
		if (String(name).is_empty() || is_plugin_written_param(name)) {
			continue;
		}
		Variant value = base->get_shader_parameter(name);
		// Compared before writing, because this is polled: an untouched material must
		// cost reads and no RenderingServer traffic at all.
		if (target->get_shader_parameter(name) != value) {
			target->set_shader_parameter(name, value);
			wrote = true;
		}
	}
	return wrote;
}

void Pasture3DPoolManager::upload_profile_into(const Ref<Material> &p_material, const StringName &p_profile) {
	_upload_into(p_material, get_profile(p_profile));
}

/**
 * Carries inspector edits of a base material into the duplicates handed out from it.
 *
 * Polled, and polled over every cached pair rather than over the one that moved, because
 * nothing announces a shader parameter change -- see sync_material_params(). Bounded by
 * the number of distinct (base, profile) pairs in the scene, not by the number of
 * bodies, which is the same bound _on_profile_changed works to.
 *
 * EDITOR ONLY. This exists so a slider drag shows up on the water; a running game
 * assigns materials, it does not tune them, and paying a per-frame walk of every uniform
 * for that would be a poll nobody asked for.
 */
void Pasture3DPoolManager::_poll_base_materials() {
	for (const KeyValue<String, CachedMaterial> &kv : _material_cache) {
		sync_material_params(kv.value.base, kv.value.shared);
	}
}

void Pasture3DPoolManager::_on_profile_changed() {
	// A knob moved. Every cached material carrying that profile is now stale --
	// and rather than work out which, re-upload all of them: the cache holds one
	// material per pair, so this is bounded by the number of distinct pairs in the
	// scene, not by the number of bodies. Ten ponds is still one upload.
	for (const KeyValue<String, CachedMaterial> &kv : _material_cache) {
		_upload_into(kv.value.shared, get_profile(kv.value.profile));
	}
	// Bodies outside the cache (Pasture3DOcean holds a private material, §6) have no other
	// way to learn a knob moved.
	emit_signal("profiles_changed");
}

void Pasture3DPoolManager::_connect_profiles() {
	Callable cb = callable_mp(this, &Pasture3DPoolManager::_on_profile_changed);
	for (int i = 0; i < _profiles.size(); i++) {
		Ref<Pasture3DWaveProfile> profile = _profiles[i];
		if (profile.is_null()) {
			continue;
		}
		profile->set_loop_period(_loop_period);
		if (!profile->is_connected("changed", cb)) {
			profile->connect("changed", cb);
		}
	}
}

/**
 * Advances the shared clock and wraps it to the loop period.
 *
 * Lifted from Pasture3D::_update_water_clock() with one change: the period is the
 * manager's own rather than the ocean wave table's. Everything else -- the wrap, the
 * change-detected period write, the reason the clock is bounded at all (water spec
 * §3.2) -- is the same and is documented there.
 */
void Pasture3DPoolManager::_update_clock(const double p_delta) {
	if (!_paused) {
		_water_time += p_delta;
	}
	double period = (double)_loop_period;
	if (period > 0.0) {
		_water_time = Math::fposmod(_water_time, period);
	}
	RS->global_shader_parameter_set("water_time", (float)_water_time);
	if (_period_sent != (float)period) {
		_period_sent = (float)period;
		RS->global_shader_parameter_set("water_time_period", (float)period);
	}
}

void Pasture3DPoolManager::_update_sun() {
	DirectionalLight3D *light = Object::cast_to<DirectionalLight3D>(_sun_light.ptr());
	if (!light) {
		return;
	}
	// The light's +Z basis column points FROM the surface TOWARD the sun, so
	// water_sun_direction.y > 0 is daytime. Same convention as the ocean's, and as
	// water_common.gdshaderinc documents.
	Vector3 direction = light->get_global_basis().get_column(2);
	Color c = light->get_color() * light->get_param(DirectionalLight3D::PARAM_ENERGY);
	Vector3 color(c.r, c.g, c.b);
	if (direction != _sun_dir_sent) {
		_sun_dir_sent = direction;
		RS->global_shader_parameter_set("water_sun_direction", direction);
	}
	if (color != _sun_color_sent) {
		_sun_color_sent = color;
		RS->global_shader_parameter_set("water_sun_color", color);
	}
}

/**
 * Fills _profiles with the four shipped sea states (spec §5.2).
 *
 * A manager with no profiles is a manager that answers every question with "no such
 * profile", so a freshly added one carries the same four shapes the materials on disk
 * already use -- `ocean_default`, `lake_calm` and `pond_still` are the exact knobs
 * bench/WavePresetTables.gd generated M_water_ocean/lake/pond's `_waves` arrays from,
 * which is what makes a preset material and the profile driving it the same water.
 *
 * `river_flow` has no material yet (Phase 7 ships M_water_river.tres): it is pond
 * chop aligned to a flow direction, narrow-spread so the crests run with the channel
 * instead of across it. Its numbers are a starting point in the same sense the other
 * three are -- generator-produced tables from chosen knobs, not measurements.
 *
 * Seeded in the CONSTRUCTOR rather than on entering the tree, because that is what
 * makes it a property default: a scene stores `profiles` as edited and set_profiles()
 * replaces these on load, including with an empty array if that is what was saved.
 * Writes _profiles directly instead of calling set_profiles() -- that path emits
 * profiles_changed and touches configuration warnings, neither of which a
 * half-constructed Node should be doing.
 */
void Pasture3DPoolManager::_seed_default_profiles() {
	struct Preset {
		const char *name;
		int count;
		real_t direction_deg;
		real_t spread_deg;
		real_t amplitude;
		real_t length_max;
		real_t steepness;
	};
	const Preset presets[] = {
		{ "ocean_default", 8, 20.f, 28.f, 1.6f, 137.f, 0.35f },
		{ "lake_calm", 4, 35.f, 40.f, 0.25f, 25.f, 0.25f },
		{ "pond_still", 2, 55.f, 50.f, 0.05f, 12.f, 0.15f },
		// length_max is the generator's floor (WaterWaves::MIN_WAVELENGTH) and is spelled
		// as such: anything smaller is silently raised to it, so asking for 6 m would
		// document a wave this can never produce. The series still runs BELOW the floor
		// on its way down -- 10.2 / 7.2 / 5.0 m -- which is the branch water_waves.cpp
		// added for ponds, and carries the same caveat: a river placed kilometres from
		// the world origin needs its domain origin set, which Pasture3DPool does.
		{ "river_flow", 3, 0.f, 10.f, 0.06f, 10.f, 0.12f },
	};
	for (const Preset &p : presets) {
		Ref<Pasture3DWaveProfile> profile;
		profile.instantiate();
		profile->set_profile_name(p.name);
		profile->set_wave_count(p.count);
		profile->set_direction_deg(p.direction_deg);
		profile->set_spread_deg(p.spread_deg);
		profile->set_amplitude(p.amplitude);
		profile->set_length_max(p.length_max);
		profile->set_steepness(p.steepness);
		_profiles.push_back(profile);
	}
	_connect_profiles();
}

///////////////////////////
// Public Functions
///////////////////////////

Pasture3DPoolManager::Pasture3DPoolManager() {
	set_notify_transform(false);
	_seed_default_profiles();
}

Pasture3DPoolManager::~Pasture3DPoolManager() {
}

void Pasture3DPoolManager::set_profiles(const TypedArray<Pasture3DWaveProfile> &p_profiles) {
	// Disconnect the outgoing set first, or a profile removed from the array keeps
	// re-uploading into materials it no longer describes.
	Callable cb = callable_mp(this, &Pasture3DPoolManager::_on_profile_changed);
	for (int i = 0; i < _profiles.size(); i++) {
		Ref<Pasture3DWaveProfile> profile = _profiles[i];
		if (profile.is_valid() && profile->is_connected("changed", cb)) {
			profile->disconnect("changed", cb);
		}
	}
	_profiles = p_profiles;
	_connect_profiles();
	// The set changed, so a cached material may now be carrying a table from a
	// profile that is gone. Rebuild rather than reason about it.
	rebuild_tables();
	update_configuration_warnings();
}

void Pasture3DPoolManager::set_loop_period(const real_t p_seconds) {
	real_t period = MAX(p_seconds, 0.1f);
	if (Math::is_equal_approx(_loop_period, period)) {
		return;
	}
	_loop_period = period;
	// Every table's frequency quantisation is against this number, so they are all
	// stale now. This is the one knob on this node that costs a full rebuild.
	rebuild_tables();
}

void Pasture3DPoolManager::set_sun_light(Node3D *p_light) {
	_sun_light.set_target(p_light);
	_sun_dir_sent = V3_MAX;
	_sun_color_sent = V3_MAX;
	update_configuration_warnings();
}

void Pasture3DPoolManager::set_paused(const bool p_paused) {
	_paused = p_paused;
}

Ref<Pasture3DWaveProfile> Pasture3DPoolManager::get_profile(const StringName &p_name) const {
	for (int i = 0; i < _profiles.size(); i++) {
		Ref<Pasture3DWaveProfile> profile = _profiles[i];
		if (profile.is_valid() && profile->get_profile_name() == p_name) {
			return profile;
		}
	}
	return Ref<Pasture3DWaveProfile>();
}

PackedStringArray Pasture3DPoolManager::get_profile_names() const {
	PackedStringArray names;
	for (int i = 0; i < _profiles.size(); i++) {
		Ref<Pasture3DWaveProfile> profile = _profiles[i];
		if (profile.is_valid()) {
			names.push_back(String(profile->get_profile_name()));
		}
	}
	return names;
}

Ref<Material> Pasture3DPoolManager::get_material_for(const Ref<Material> &p_base, const StringName &p_profile) {
	if (p_base.is_null()) {
		return Ref<Material>();
	}
	Ref<Pasture3DWaveProfile> profile = get_profile(p_profile);
	if (profile.is_null()) {
		// An unresolved name is a configuration problem the body reports, not a
		// reason to hand back nothing: water with the material's own compile-time
		// default table is still water, and an invisible pool is a worse diagnostic
		// than a wrong-looking one.
		LOG(WARN, "No wave profile named '", String(p_profile), "'; returning the base material untouched");
		return p_base;
	}
	String key = _cache_key(p_base, p_profile);
	HashMap<String, CachedMaterial>::Iterator it = _material_cache.find(key);
	if (it) {
		return it->value.shared;
	}
	CachedMaterial entry;
	entry.base = p_base;
	entry.shared = p_base->duplicate();
	entry.profile = p_profile;
	_upload_into(entry.shared, profile);
	_material_cache.insert(key, entry);
	LOG(DEBUG, "Cached water material for key ", key, "; cache now holds ", _material_cache.size());
	return entry.shared;
}

void Pasture3DPoolManager::clear_material_cache() {
	_material_cache.clear();
}

void Pasture3DPoolManager::rebuild_tables() {
	for (int i = 0; i < _profiles.size(); i++) {
		Ref<Pasture3DWaveProfile> profile = _profiles[i];
		if (profile.is_valid()) {
			profile->set_loop_period(_loop_period);
		}
	}
	_on_profile_changed();
}

void Pasture3DPoolManager::register_body(Node *p_body) {
	if (p_body && !_bodies.has(p_body)) {
		_bodies.push_back(p_body);
	}
}

void Pasture3DPoolManager::unregister_body(Node *p_body) {
	_bodies.erase(p_body);
}

TypedArray<Node> Pasture3DPoolManager::get_bodies() const {
	TypedArray<Node> out;
	for (Node *body : _bodies) {
		if (body) {
			out.push_back(body);
		}
	}
	return out;
}

/**
 * The body a world point is inside, or null.
 *
 * Two passes on purpose. An ocean is unbounded, so a single pass in registration
 * order would return the ocean for a point plainly inside a pond whenever the ocean
 * happened to register first -- and registration order is scene-tree order, which no
 * user thinks about. Finite bodies are therefore asked first, and only if none claims
 * the point does the ocean get it.
 *
 * `contains_point` is duck-typed rather than an interface: Pasture3DPool is GDScript
 * and Pasture3DOcean is C++, and requiring a shared base would mean making one of
 * them the other's language.
 */
Node *Pasture3DPoolManager::body_at(const Vector3 &p_global_pos) const {
	Node *ocean = nullptr;
	for (Node *body : _bodies) {
		if (!body) {
			continue;
		}
		if (Object::cast_to<Pasture3DOcean>(body)) {
			if (!ocean) {
				ocean = body;
			}
			continue;
		}
		if (body->has_method("contains_point") &&
				(bool)body->call("contains_point", p_global_pos)) {
			return body;
		}
	}
	// The ocean is the fallback for every point no finite body claimed, INCLUDING one
	// above the surface -- so it is returned without being asked whether it contains the
	// point. It used to be asked, and the answer was discarded: both the guarded branch
	// and the fallthrough returned `ocean`, so a full Pasture3DOcean::contains_point() --
	// which compares against the WAVE surface and therefore runs solve_domain(), 16
	// Gerstner iterations -- was spent choosing between returning the ocean and returning
	// the ocean. On the buoy resolve path that ran per buoy per physics tick.
	//
	// Returning it unconditionally is also the behaviour a buoy wants: a hull lifted clear
	// of a crest must keep its body rather than drop to null and re-resolve on the next
	// tick. Submersion decides whether it gets force; this only decides whose surface to
	// measure against.
	return ocean;
}

real_t Pasture3DPoolManager::evaluate_height(const StringName &p_profile, const Vector2 &p_domain_xz) const {
	Ref<Pasture3DWaveProfile> profile = get_profile(p_profile);
	if (profile.is_null()) {
		return 0.f;
	}
	return profile->get_height_at(p_domain_xz, (real_t)_water_time);
}

Vector3 Pasture3DPoolManager::evaluate_normal(const StringName &p_profile, const Vector2 &p_domain_xz) const {
	Ref<Pasture3DWaveProfile> profile = get_profile(p_profile);
	if (profile.is_null()) {
		return Vector3(0.f, 1.f, 0.f);
	}
	return profile->get_normal_at(p_domain_xz, (real_t)_water_time);
}

Vector3 Pasture3DPoolManager::evaluate_surface_point(const StringName &p_profile, const Vector2 &p_domain_xz) const {
	Ref<Pasture3DWaveProfile> profile = get_profile(p_profile);
	if (profile.is_null()) {
		return Vector3(p_domain_xz.x, 0.f, p_domain_xz.y);
	}
	return profile->get_surface_point(p_domain_xz, (real_t)_water_time);
}

Vector2 Pasture3DPoolManager::solve_domain(const StringName &p_profile, const Vector2 &p_target_xz) const {
	Ref<Pasture3DWaveProfile> profile = get_profile(p_profile);
	if (profile.is_null()) {
		return p_target_xz;
	}
	return profile->solve_domain(p_target_xz, (real_t)_water_time);
}

PackedStringArray Pasture3DPoolManager::_get_configuration_warnings() const {
	PackedStringArray warnings;
	if (_managers.size() > 1) {
		warnings.push_back(
				"There is more than one Pasture3DPoolManager in the tree. water_time is a project-wide "
				"shader global, so they overwrite each other every frame and the clock runs at the "
				"rate of however many are present. Keep one.");
	}
	if (_profiles.is_empty()) {
		warnings.push_back(
				"No wave profiles. Water bodies selecting a profile by name will fall back to "
				"whatever compile-time table their material's variant carries.");
	}
	if (_sun_light.is_null()) {
		warnings.push_back(
				"No sun_light. Water is still lit by the scene, but its own sun-dependent terms "
				"(specular tint, scattering) sit at their defaults.");
	}
	// A duplicate profile name is silently first-wins in get_profile(), which is
	// the kind of thing that gets debugged for an hour.
	PackedStringArray names = get_profile_names();
	for (int i = 0; i < names.size(); i++) {
		for (int j = i + 1; j < names.size(); j++) {
			if (names[i] == names[j]) {
				warnings.push_back("Two wave profiles are both named '" + names[i] +
						"'. Bodies select by name, so the second is unreachable.");
				i = names.size(); // one warning is enough
				break;
			}
		}
	}
	return warnings;
}

///////////////////////////
// Protected Functions
///////////////////////////

void Pasture3DPoolManager::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_ENTER_TREE: {
			LOG(INFO, "NOTIFICATION_ENTER_TREE");
			register_water_globals();
			if (!_managers.has(this)) {
				_managers.push_back(this);
			}
			add_to_group(MANAGER_GROUP);
			_connect_profiles();
			set_physics_process(true);
			update_configuration_warnings();
			break;
		}

		case NOTIFICATION_EXIT_TREE: {
			LOG(INFO, "NOTIFICATION_EXIT_TREE");
			_managers.erase(this);
			remove_from_group(MANAGER_GROUP);
			set_physics_process(false);
			break;
		}

		case NOTIFICATION_PHYSICS_PROCESS: {
			_update_clock(get_physics_process_delta_time());
			_update_sun();
			if (Engine::get_singleton()->is_editor_hint()) {
				_poll_base_materials();
			}
			break;
		}
	}
}

void Pasture3DPoolManager::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_profiles", "profiles"), &Pasture3DPoolManager::set_profiles);
	ClassDB::bind_method(D_METHOD("get_profiles"), &Pasture3DPoolManager::get_profiles);
	ClassDB::bind_method(D_METHOD("set_loop_period", "seconds"), &Pasture3DPoolManager::set_loop_period);
	ClassDB::bind_method(D_METHOD("get_loop_period"), &Pasture3DPoolManager::get_loop_period);
	ClassDB::bind_method(D_METHOD("set_sun_light", "light"), &Pasture3DPoolManager::set_sun_light);
	ClassDB::bind_method(D_METHOD("get_sun_light"), &Pasture3DPoolManager::get_sun_light);
	ClassDB::bind_method(D_METHOD("set_paused", "paused"), &Pasture3DPoolManager::set_paused);
	ClassDB::bind_method(D_METHOD("is_paused"), &Pasture3DPoolManager::is_paused);

	ClassDB::bind_method(D_METHOD("get_water_time"), &Pasture3DPoolManager::get_water_time);
	ClassDB::bind_method(D_METHOD("get_profile", "name"), &Pasture3DPoolManager::get_profile);
	ClassDB::bind_method(D_METHOD("get_profile_names"), &Pasture3DPoolManager::get_profile_names);
	ClassDB::bind_method(D_METHOD("has_profile", "name"), &Pasture3DPoolManager::has_profile);

	ClassDB::bind_method(D_METHOD("get_material_for", "base", "profile"), &Pasture3DPoolManager::get_material_for);
	ClassDB::bind_method(D_METHOD("get_cached_material_count"), &Pasture3DPoolManager::get_cached_material_count);
	ClassDB::bind_method(D_METHOD("get_upload_count"), &Pasture3DPoolManager::get_upload_count);
	ClassDB::bind_method(D_METHOD("clear_material_cache"), &Pasture3DPoolManager::clear_material_cache);
	ClassDB::bind_method(D_METHOD("rebuild_tables"), &Pasture3DPoolManager::rebuild_tables);
	ClassDB::bind_method(D_METHOD("upload_profile_into", "material", "profile"), &Pasture3DPoolManager::upload_profile_into);
	// Bound for the same reason upload_profile_into is: the bodies that need it are
	// outside this class's cache. It is also the only way a gate can drive the sync,
	// since the callers run it behind is_editor_hint() and a headless test is not the
	// editor.
	ClassDB::bind_static_method("Pasture3DPoolManager",
			D_METHOD("sync_material_params", "base", "target"), &Pasture3DPoolManager::sync_material_params);
	ClassDB::bind_static_method("Pasture3DPoolManager",
			D_METHOD("is_plugin_written_param", "name"), &Pasture3DPoolManager::is_plugin_written_param);
	ClassDB::bind_method(D_METHOD("register_body", "body"), &Pasture3DPoolManager::register_body);
	ClassDB::bind_method(D_METHOD("unregister_body", "body"), &Pasture3DPoolManager::unregister_body);
	ClassDB::bind_method(D_METHOD("get_bodies"), &Pasture3DPoolManager::get_bodies);
	ClassDB::bind_method(D_METHOD("body_at", "global_pos"), &Pasture3DPoolManager::body_at);

	ADD_SIGNAL(MethodInfo("profiles_changed"));

	ClassDB::bind_method(D_METHOD("evaluate_height", "profile", "domain_xz"), &Pasture3DPoolManager::evaluate_height);
	ClassDB::bind_method(D_METHOD("evaluate_normal", "profile", "domain_xz"), &Pasture3DPoolManager::evaluate_normal);
	ClassDB::bind_method(D_METHOD("evaluate_surface_point", "profile", "domain_xz"), &Pasture3DPoolManager::evaluate_surface_point);
	ClassDB::bind_method(D_METHOD("solve_domain", "profile", "target_xz"), &Pasture3DPoolManager::solve_domain);

	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "profiles", PROPERTY_HINT_TYPE_STRING,
						 String::num(Variant::OBJECT) + "/" + String::num(PROPERTY_HINT_RESOURCE_TYPE) + ":Pasture3DWaveProfile"),
			"set_profiles", "get_profiles");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "loop_period", PROPERTY_HINT_RANGE, "1,600,0.5,or_greater,suffix:s"),
			"set_loop_period", "get_loop_period");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "sun_light", PROPERTY_HINT_NODE_TYPE, "DirectionalLight3D"),
			"set_sun_light", "get_sun_light");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "paused"), "set_paused", "is_paused");
}
