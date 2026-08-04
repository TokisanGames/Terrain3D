// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "logger.h"
#include "pasture_3d_buoy.h"
#include "pasture_3d_pool_manager.h"

///////////////////////////
// Private Functions
///////////////////////////

/**
 * The water body this buoy is in, resolving it if the cache has gone stale.
 *
 * Spec §9.2. `water_body` wins when set. Otherwise the manager's registry is asked, and the answer
 * is cached -- re-asked when the cached body stops containing this point, and unconditionally every
 * RESOLVE_INTERVAL ticks. The first covers a boat leaving a lake; the second covers it arriving
 * somewhere the first cannot see, such as a pool that was built after the buoy last looked.
 *
 * No body is a normal state, not an error. A boat driven onto land, or dropped into a scene before
 * the water exists, gets no force and no message.
 */
Node *Pasture3DBuoy::_resolve_body() {
	if (_water_body_id != 0) {
		Object *obj = ObjectDB::get_instance(_water_body_id);
		return obj ? Object::cast_to<Node>(obj) : nullptr;
	}
	Node *cached = _get_body();
	_ticks_since_resolve++;
	if (cached && _ticks_since_resolve < RESOLVE_INTERVAL) {
		// The cached body is still the answer as long as it still contains us. This is the exact
		// test, not a box, so leaving a lake is noticed on the tick it happens rather than up to
		// RESOLVE_INTERVAL later.
		//
		// It is NOT cheap, whatever this comment used to claim: contains_point() bottoms out in
		// get_water_height(), so it runs the same 16-iteration Gerstner inverse the height sample
		// below does. The two are the same query at the same position in the same frame, and
		// Pasture3DWaterBody.get_water_height() memoises exactly that pair -- so the second one is
		// free, but only because that memo is there. Anything that moves this call to a different
		// position, or off the physics frame, pays for a whole second solve.
		if (cached->has_method("contains_point")) {
			bool still_in = cached->call("contains_point", get_global_position());
			if (still_in) {
				return cached;
			}
		} else {
			return cached;
		}
	}
	_ticks_since_resolve = 0;
	Pasture3DPoolManager *manager = Pasture3DPoolManager::get_active_manager();
	if (!manager) {
		_body_id = 0;
		return nullptr;
	}
	Node *found = manager->body_at(get_global_position());
	_body_id = found ? found->get_instance_id() : 0;
	return found;
}

Node *Pasture3DBuoy::_get_body() const {
	if (_water_body_id != 0) {
		Object *obj = ObjectDB::get_instance(_water_body_id);
		return obj ? Object::cast_to<Node>(obj) : nullptr;
	}
	if (_body_id == 0) {
		return nullptr;
	}
	Object *obj = ObjectDB::get_instance(_body_id);
	return obj ? Object::cast_to<Node>(obj) : nullptr;
}

/**
 * The nearest RigidBody3D ancestor. Buoys are placed as children of the hull they float, so this is
 * "the thing I push on". Walked rather than exported: an export would be one more thing to wire up
 * and one more thing to wire up wrongly, and the tree already says it.
 */
RigidBody3D *Pasture3DBuoy::_find_parent_body() const {
	Node *n = get_parent();
	while (n) {
		RigidBody3D *body = Object::cast_to<RigidBody3D>(n);
		if (body) {
			return body;
		}
		n = n->get_parent();
	}
	return nullptr;
}

/**
 * The project's gravity, not a hardcoded 9.8.
 *
 * Buoyancy has to balance the same gravity the body is falling under, so a project that changed it
 * would otherwise have every boat float wrong by exactly that ratio.
 */
real_t Pasture3DBuoy::_gravity() const {
	return _gravity_cached;
}

/**
 * Re-reads the project's gravity into the cache.
 *
 * Called on entering the tree rather than on every tick. apply_buoyancy() needs this value
 * once per submerged buoy per physics frame, and resolving it through ProjectSettings each
 * time meant hashing a 28-character String, walking the settings dictionary and unboxing a
 * Variant -- 3840 times a second at the 64 buoys §9.3 budgets, for a number that describes
 * the project rather than the frame.
 *
 * Entering the tree, and not once per process, so that a project which changes its gravity
 * still gets it: the setting is read after the project is loaded, and any buoy spawned or
 * re-parented afterwards picks up the current value.
 */
void Pasture3DBuoy::_refresh_gravity() {
	ProjectSettings *settings = ProjectSettings::get_singleton();
	if (!settings) {
		_gravity_cached = 9.80665f;
		return;
	}
	_gravity_cached = (real_t)(double)settings->get_setting("physics/3d/default_gravity", 9.80665);
}

///////////////////////////
// Public Functions
///////////////////////////

Pasture3DBuoy::Pasture3DBuoy() {
	set_notify_transform(false);
}

void Pasture3DBuoy::set_displacement(const real_t p_cubic_metres) {
	_displacement = MAX(p_cubic_metres, 0.f);
	update_configuration_warnings();
}

void Pasture3DBuoy::set_full_depth(const real_t p_metres) {
	// A zero would make the submersion fraction a step function: fully out one tick, fully in the
	// next, which is a boat that snaps rather than floats.
	_full_depth = MAX(p_metres, 0.001f);
}

void Pasture3DBuoy::set_linear_drag(const real_t p_drag) {
	_linear_drag = MAX(p_drag, 0.f);
}

void Pasture3DBuoy::set_angular_drag(const real_t p_drag) {
	_angular_drag = MAX(p_drag, 0.f);
}

void Pasture3DBuoy::set_sample_interval(const int p_ticks) {
	_sample_interval = MAX(p_ticks, 1);
}

void Pasture3DBuoy::set_water_body(Node *p_body) {
	_water_body_id = p_body ? p_body->get_instance_id() : 0;
	// A manual assignment invalidates whatever was resolved, in both directions: clearing it must
	// hand control back to the registry rather than leave the last explicit body pinned.
	_body_id = 0;
	_ticks_since_resolve = RESOLVE_INTERVAL;
	update_configuration_warnings();
}

Node *Pasture3DBuoy::get_water_body() const {
	if (_water_body_id == 0) {
		return nullptr;
	}
	Object *obj = ObjectDB::get_instance(_water_body_id);
	return obj ? Object::cast_to<Node>(obj) : nullptr;
}

real_t Pasture3DBuoy::get_submersion() const {
	Node *body = _get_body();
	if (!body || !body->has_method("get_water_height")) {
		return 0.f;
	}
	Vector3 pos = get_global_position();
	real_t h = body->call("get_water_height", Vector2(pos.x, pos.z));
	return CLAMP((h - pos.y) / _full_depth, 0.f, 1.f);
}

real_t Pasture3DBuoy::get_body_displacement() const {
	RigidBody3D *parent = _find_parent_body();
	if (!parent) {
		return _displacement;
	}
	// Every buoy under the same hull, at any depth -- a boat is free to group them under an
	// anchor Node3D per side, and that must not change the answer.
	real_t total = 0.f;
	Vector<Node *> stack;
	stack.push_back(parent);
	while (!stack.is_empty()) {
		Node *n = stack[stack.size() - 1];
		stack.remove_at(stack.size() - 1);
		Pasture3DBuoy *buoy = Object::cast_to<Pasture3DBuoy>(n);
		if (buoy) {
			total += buoy->get_displacement();
		}
		for (int i = 0; i < n->get_child_count(); i++) {
			stack.push_back(n->get_child(i));
		}
	}
	return total;
}

real_t Pasture3DBuoy::get_required_displacement() const {
	RigidBody3D *parent = _find_parent_body();
	// mass / density: the volume of water that weighs what this body weighs. Displace exactly that
	// and it is neutrally buoyant; displace less and it sinks, whatever the drag settings say.
	return parent ? parent->get_mass() / WATER_DENSITY : 0.f;
}

/**
 * One tick of buoyancy for this sample point. Spec §9.1.
 *
 * Everything here is scaled by `frac`, the submersion fraction, including the drag -- a buoy in the
 * air must contribute nothing at all, or a boat leaving the water would keep being slowed by the
 * water it left.
 */
void Pasture3DBuoy::apply_buoyancy(const double p_delta) {
	RigidBody3D *parent = _parent_body;
	if (!parent || parent->is_freeze_enabled()) {
		return;
	}
	Node *body = _resolve_body();
	if (!body || !body->has_method("get_water_height")) {
		_held_valid = false;
		return;
	}

	const Vector3 pos = get_global_position();

	// Sampling. sample_interval > 1 re-uses the last HEIGHT rather than the last force, so the buoy
	// still responds to its own motion between samples -- it is the wave query that is skipped, and
	// that is the expensive part (§9.3). At 60 Hz against a 120 s loop, N=2 is invisible on
	// anything short of a violent sea.
	if (!_held_valid || _ticks_since_sample >= _sample_interval - 1) {
		_held_height = (real_t)(double)body->call("get_water_height", Vector2(pos.x, pos.z));
		_held_valid = true;
		_ticks_since_sample = 0;
	} else {
		_ticks_since_sample++;
	}

	const real_t depth = _held_height - pos.y;
	const real_t frac = CLAMP(depth / _full_depth, 0.f, 1.f);

	// Per-body angular damping bookkeeping, done whether or not this buoy is wet: a buoy in the air
	// still has to report its zero, or the body's maximum would be wrong.
	const uint64_t body_key = parent->get_instance_id();
	const uint64_t frame = Engine::get_singleton()->get_physics_frames();
	BodyTick *tick = _body_ticks.getptr(body_key);
	if (!tick) {
		_body_ticks.insert(body_key, BodyTick());
		tick = _body_ticks.getptr(body_key);
	}
	if (tick->frame != frame) {
		// First buoy of this body to run this tick. Roll the accumulator over and apply the body's
		// angular damping once, using the PREVIOUS tick's completed maximum.
		//
		// Previous rather than current, deliberately: the current tick's maximum is not known until
		// every buoy has run, and there is no "last buoy" to hook. Using whichever buoy happens to
		// run first would mean a hull with two buoys in the water and two in the air damps or does
		// not damp depending on child order -- the bug this whole block exists to avoid. One tick
		// of lag on a damping term at 60 Hz is not observable; child-order-dependent physics is.
		tick->frame = frame;
		tick->frac_prev = tick->frac_now;
		tick->frac_now = 0.f;
		if (_angular_drag > 0.f && tick->frac_prev > 0.f) {
			const real_t keep = MAX(1.f - _angular_drag * tick->frac_prev * (real_t)p_delta, 0.f);
			parent->set_angular_velocity(parent->get_angular_velocity() * keep);
		}
	}
	tick->frac_now = MAX(tick->frac_now, frac);

	if (frac <= 0.f) {
		return;
	}

	// Archimedes: the weight of the water displaced. Up is world up, not the body's up -- a
	// capsized hull is still pushed toward the sky, which is what rights it.
	const Vector3 buoyant = Vector3(0.f, WATER_DENSITY * _gravity() * _displacement * frac, 0.f);

	// Velocity OF THIS POINT, not of the body: the angular term is what makes drag resist rotation
	// and what stops a boat rocking forever.
	const Vector3 offset = pos - parent->get_global_position();
	const Vector3 point_velocity = parent->get_linear_velocity() +
			parent->get_angular_velocity().cross(offset);
	const Vector3 drag = -point_velocity * _linear_drag * frac;

	parent->apply_force(buoyant + drag, offset);
}

PackedStringArray Pasture3DBuoy::_get_configuration_warnings() const {
	return get_buoyancy_warnings();
}

PackedStringArray Pasture3DBuoy::get_buoyancy_warnings() const {
	PackedStringArray warnings;
	RigidBody3D *parent = _find_parent_body();
	if (!parent) {
		warnings.push_back("No RigidBody3D above this buoy. A buoy is a sample point ON a body; "
						   "put it under the hull it should float.");
		return warnings;
	}
	// The equilibrium, spelled out. "Why does my boat sink" is otherwise a numbers puzzle with no
	// way in: the answer is always this ratio, and it is never visible in the inspector.
	const real_t have = get_body_displacement();
	const real_t need = get_required_displacement();
	if (need <= 0.f) {
		warnings.push_back(vformat("'%s' has a mass of %.3f kg, so buoyancy cannot be balanced "
								   "against it.",
				parent->get_name(), parent->get_mass()));
	} else if (have <= 0.f) {
		warnings.push_back(vformat("Total displacement across this body's buoys is 0 m3, so it "
								   "will sink. It needs %.3f m3 to float (mass %.1f kg / 1000).",
				need, parent->get_mass()));
	} else {
		const real_t equilibrium = need / have;
		if (equilibrium > 1.f) {
			warnings.push_back(vformat("This body will SINK: its buoys displace %.3f m3 between "
									   "them and it needs %.3f m3 (mass %.1f kg / 1000). Raise "
									   "displacement by %.0f%%, or lower the mass.",
					have, need, parent->get_mass(), (equilibrium - 1.f) * 100.f));
		} else if (equilibrium < 0.05f) {
			warnings.push_back(vformat("This body will float very high: it displaces %.3f m3 and "
									   "needs only %.3f m3, so it settles at %.0f%% of full_depth "
									   "and will look like it is skating on the surface.",
					have, need, equilibrium * 100.f));
		}
	}
	if (_sample_interval > 1) {
		warnings.push_back(vformat("sample_interval is %d, so the wave height under this buoy is "
								   "re-read every %d physics ticks and held in between. Intended "
								   "for crowds of buoys; on a hero boat leave it at 1.",
				_sample_interval, _sample_interval));
	}
	return warnings;
}

///////////////////////////
// Protected Functions
///////////////////////////

void Pasture3DBuoy::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_READY: {
			// The editor must not push a boat around while it is being placed.
			set_physics_process(!Engine::get_singleton()->is_editor_hint());
			_parent_body = _find_parent_body();
			update_configuration_warnings();
			break;
		}
		case NOTIFICATION_ENTER_TREE: {
			_parent_body = _find_parent_body();
			_refresh_gravity();
			// Re-resolve on the first tick after entering rather than trusting a cached body from
			// wherever this buoy was before.
			_body_id = 0;
			_ticks_since_resolve = RESOLVE_INTERVAL;
			_held_valid = false;
			break;
		}
		case NOTIFICATION_EXIT_TREE: {
			// Drop this body's damping accumulator. _body_ticks is static -- it has to be,
			// since the whole point is that every buoy on a hull shares one entry -- so
			// without this it grew by one entry per RigidBody3D ever floated and never
			// shrank. Instance ids are not reused, so a level reloaded fifty times leaked
			// fifty entries, for the life of the process and across scene changes.
			//
			// Erasing eagerly rather than refcounting the buoys on the body: the entry is
			// re-inserted on demand by apply_buoyancy(), so the worst a surviving sibling
			// buoy suffers is one tick with frac_prev back at 0, which costs it one tick
			// of angular damping. That value is already deliberately a tick stale.
			if (_parent_body) {
				_body_ticks.erase(_parent_body->get_instance_id());
			}
			_parent_body = nullptr;
			_held_valid = false;
			break;
		}
		case NOTIFICATION_PARENTED:
		case NOTIFICATION_UNPARENTED: {
			_parent_body = _find_parent_body();
			break;
		}
		case NOTIFICATION_PHYSICS_PROCESS: {
			apply_buoyancy(get_physics_process_delta_time());
			break;
		}
	}
}

void Pasture3DBuoy::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_displacement", "cubic_metres"), &Pasture3DBuoy::set_displacement);
	ClassDB::bind_method(D_METHOD("get_displacement"), &Pasture3DBuoy::get_displacement);
	ClassDB::bind_method(D_METHOD("set_full_depth", "metres"), &Pasture3DBuoy::set_full_depth);
	ClassDB::bind_method(D_METHOD("get_full_depth"), &Pasture3DBuoy::get_full_depth);
	ClassDB::bind_method(D_METHOD("set_linear_drag", "drag"), &Pasture3DBuoy::set_linear_drag);
	ClassDB::bind_method(D_METHOD("get_linear_drag"), &Pasture3DBuoy::get_linear_drag);
	ClassDB::bind_method(D_METHOD("set_angular_drag", "drag"), &Pasture3DBuoy::set_angular_drag);
	ClassDB::bind_method(D_METHOD("get_angular_drag"), &Pasture3DBuoy::get_angular_drag);
	ClassDB::bind_method(D_METHOD("set_sample_interval", "ticks"), &Pasture3DBuoy::set_sample_interval);
	ClassDB::bind_method(D_METHOD("get_sample_interval"), &Pasture3DBuoy::get_sample_interval);
	ClassDB::bind_method(D_METHOD("set_water_body", "body"), &Pasture3DBuoy::set_water_body);
	ClassDB::bind_method(D_METHOD("get_water_body"), &Pasture3DBuoy::get_water_body);

	ClassDB::bind_method(D_METHOD("get_resolved_body"), &Pasture3DBuoy::get_resolved_body);
	ClassDB::bind_method(D_METHOD("get_submersion"), &Pasture3DBuoy::get_submersion);
	ClassDB::bind_method(D_METHOD("get_body_displacement"), &Pasture3DBuoy::get_body_displacement);
	ClassDB::bind_method(D_METHOD("get_required_displacement"), &Pasture3DBuoy::get_required_displacement);
	ClassDB::bind_method(D_METHOD("apply_buoyancy", "delta"), &Pasture3DBuoy::apply_buoyancy);
	ClassDB::bind_method(D_METHOD("get_buoyancy_warnings"), &Pasture3DBuoy::get_buoyancy_warnings);

	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "displacement", PROPERTY_HINT_RANGE,
						 "0.001,10,0.001,or_greater,suffix:m3"),
			"set_displacement", "get_displacement");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "full_depth", PROPERTY_HINT_RANGE,
						 "0.01,5,0.01,or_greater,suffix:m"),
			"set_full_depth", "get_full_depth");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "linear_drag", PROPERTY_HINT_RANGE,
						 "0,2000,1,or_greater"),
			"set_linear_drag", "get_linear_drag");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "angular_drag", PROPERTY_HINT_RANGE,
						 "0,20,0.1,or_greater"),
			"set_angular_drag", "get_angular_drag");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "sample_interval", PROPERTY_HINT_RANGE, "1,8,1"),
			"set_sample_interval", "get_sample_interval");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "water_body", PROPERTY_HINT_NODE_TYPE, "Node"),
			"set_water_body", "get_water_body");
}
