// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/time.hpp>

#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_collision.h"
#include "terrain_3d_data.h"
#include "terrain_3d_streamer.h"
#include "terrain_3d_util.h"

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DStreamer::initialize(Terrain3D *p_terrain) {
	_terrain = p_terrain;
}

void Terrain3DStreamer::set_enabled(const bool p_enabled) {
	if (_enabled == p_enabled) {
		return;
	}
	_enabled = p_enabled;
	LOG(INFO, "Region streaming ", p_enabled ? "enabled" : "disabled");
	if (!p_enabled) {
		abort_pending();
	}
}

bool Terrain3DStreamer::is_active() const {
	return _enabled && !IS_EDITOR;
}

// Consumes and drops every in flight threaded load. An unconsumed threaded load
// is pinned in the loader forever, so this must run whenever streaming stops:
// rescans, disabling streaming at runtime, and leaving the tree.
void Terrain3DStreamer::abort_pending() {
	for (const KeyValue<Vector2i, String> &kv : _pending) {
		ResourceLoader::get_singleton()->load_threaded_get(kv.value);
	}
	_pending.clear();
}

// Scans the data directory for region locations. Only file names are read, nothing is loaded.
void Terrain3DStreamer::scan_directory() {
	IS_INIT(VOID);
	_known.clear();
	_known_set.clear();
	_failed.clear();
	abort_pending();
	_travel_dir = Vector2();
	_has_last_focus = false;
	_landed_total = 0;
	_evicted_total = 0;
	_land_ms_avg = 0.f;
	String dir = _terrain->get_data_directory();
	if (dir.is_empty()) {
		return;
	}
	PackedStringArray files = Util::get_files(dir, "terrain3d*.res");
	for (const String &fname : files) {
		Vector2i loc = Util::filename_to_location(fname);
		if (loc.x == INT32_MAX) {
			continue; // Sibling non-region file
		}
		_known.push_back(loc);
		_known_set.insert(loc);
	}
	LOG(INFO, "Streaming scan: ", _known.size(), " regions on disk at ", dir);
}

// Runs the streaming state machine once per physics frame: evict regions that fell
// outside the loaded area, insert completed loads, and request missing regions.
// IO runs wide (concurrent_loads threaded loads decompress at once) while
// insertions stay narrow (loads_per_frame per physics frame), since the texture
// layer uploads and signal cascade are the main thread cost that hitches.
void Terrain3DStreamer::step() {
	IS_INIT(VOID);
	Terrain3DData *data = _terrain->get_data();
	if (data == nullptr || !data->is_streaming()) {
		return;
	}
	String dir = _terrain->get_data_directory();
	Vector3 focus = _terrain->get_clipmap_target_position();
	Vector2i floc = data->get_region_location(focus);
	// Track the travel direction so regions ahead of travel load first on ties.
	// A teleport (a jump beyond one region span) resets it.
	Vector2 fpos = Vector2(focus.x, focus.z);
	if (_has_last_focus) {
		Vector2 delta = fpos - _last_focus;
		real_t span = real_t((int)_terrain->get_region_size()) * _terrain->get_vertex_spacing();
		if (delta.length_squared() > span * span) {
			_travel_dir = Vector2();
		} else if (delta.length_squared() > 1e-6f) {
			_travel_dir = _travel_dir * 0.9f + delta.normalized() * 0.1f;
		}
	}
	_last_focus = fpos;
	_has_last_focus = true;
	// Evict regions beyond the loaded area plus one region of hysteresis, up to 8 per
	// frame so a teleport frees the whole stale area quickly without starving the pool
	TypedArray<Vector2i> loaded = data->get_region_locations();
	Vector<Vector2i> stale;
	for (int i = 0; i < loaded.size(); i++) {
		Vector2i loc = loaded[i];
		if (_distance_to(loc, floc) > real_t(_distance + 1)) {
			stale.push_back(loc);
		}
	}
	for (int i = 0; i < stale.size() && i < 8; i++) {
		data->evict_region(stale[i], dir);
		_evicted_total += 1;
	}
	// Poll in flight loads. Failures are marked and never retried, loads that fell out
	// of range while loading are consumed and dropped, and the nearest completed
	// bodies are inserted, up to loads_per_frame
	struct Landing {
		Vector2i loc;
		String path;
		real_t d;
	};
	Vector<Landing> ready;
	Vector<Vector2i> drop;
	for (const KeyValue<Vector2i, String> &kv : _pending) {
		ResourceLoader::ThreadLoadStatus status =
				ResourceLoader::get_singleton()->load_threaded_get_status(kv.value);
		if (status == ResourceLoader::THREAD_LOAD_IN_PROGRESS) {
			continue;
		}
		if (status != ResourceLoader::THREAD_LOAD_LOADED) {
			LOG(ERROR, "Streaming load failed for region ", kv.key, " at ", kv.value);
			_failed.insert(kv.key);
			drop.push_back(kv.key);
			continue;
		}
		real_t d = _distance_to(kv.key, floc);
		if (d > real_t(_distance + 1)) {
			// Walked away while it loaded: consume and drop
			ResourceLoader::get_singleton()->load_threaded_get(kv.value);
			drop.push_back(kv.key);
			continue;
		}
		Landing l;
		l.loc = kv.key;
		l.path = kv.value;
		l.d = d;
		ready.push_back(l);
	}
	for (int i = 0; i < drop.size(); i++) {
		_pending.erase(drop[i]);
	}
	struct LandingSort {
		bool operator()(const Landing &a, const Landing &b) const { return a.d < b.d; }
	};
	ready.sort_custom<LandingSort>();
	for (int i = 0; i < ready.size() && i < _loads_per_frame; i++) {
		uint64_t t0 = Time::get_singleton()->get_ticks_usec();
		Ref<Terrain3DRegion> region = ResourceLoader::get_singleton()->load_threaded_get(ready[i].path);
		_pending.erase(ready[i].loc);
		if (region.is_null()) {
			LOG(ERROR, "Streaming load returned null region ", ready[i].loc);
			_failed.insert(ready[i].loc);
			continue;
		}
		region->take_over_path(ready[i].path);
		region->set_location(ready[i].loc);
		region->set_version(Terrain3DData::CURRENT_DATA_VERSION);
		if (data->add_region_streamed(region) == OK) {
			_collision_refresh(ready[i].loc);
			_landed_total += 1;
			real_t ms = real_t(Time::get_singleton()->get_ticks_usec() - t0) * 0.001f;
			_land_ms_avg = _land_ms_avg == 0.f ? ms : _land_ms_avg * 0.9f + ms * 0.1f;
		} else if (data->get_free_slot_count() > 0) {
			// Rejected with a slot available means the body itself is bad. Never
			// re-request it, pool pressure alone retries fine
			_failed.insert(ready[i].loc);
		}
	}
	// Request missing regions within the loaded area, nearest first with ties broken
	// toward the travel direction. Every pending body claims a slot on insertion, so
	// never keep more in flight than free slots can absorb
	int budget = MIN(_concurrent_loads, data->get_free_slot_count()) - (int)_pending.size();
	if (budget <= 0) {
		return;
	}
	struct Cand {
		Vector2i loc;
		real_t d;
		real_t ahead;
	};
	struct CandSort {
		bool operator()(const Cand &a, const Cand &b) const {
			if (!Math::is_equal_approx(a.d, b.d)) {
				return a.d < b.d;
			}
			return a.ahead > b.ahead;
		}
	};
	Vector<Cand> cands;
	for (int dy = -_distance; dy <= _distance; dy++) {
		for (int dx = -_distance; dx <= _distance; dx++) {
			Vector2i loc = floc + Vector2i(dx, dy);
			if (!_known_set.has(loc) || data->has_region(loc) ||
					_failed.has(loc) || _pending.has(loc)) {
				continue;
			}
			real_t d = _distance_to(loc, floc);
			if (d > real_t(_distance)) {
				continue; // Corner outside a circular area
			}
			Cand c;
			c.loc = loc;
			c.d = d;
			c.ahead = (d == 0.f) ? 1.f : _travel_dir.dot(Vector2(real_t(dx), real_t(dy)).normalized());
			cands.push_back(c);
		}
	}
	cands.sort_custom<CandSort>();
	for (int i = 0; i < cands.size() && budget > 0; i++) {
		String path = dir + String("/") + Util::location_to_filename(cands[i].loc);
		Error err = ResourceLoader::get_singleton()->load_threaded_request(
				path, "Terrain3DRegion", false, ResourceLoader::CACHE_MODE_IGNORE);
		if (err != OK) {
			LOG(ERROR, "Streaming load request failed for ", path, ": ", err);
			_failed.insert(cands[i].loc);
			continue;
		}
		_pending[cands[i].loc] = path;
		budget--;
	}
}

Dictionary Terrain3DStreamer::get_stats() const {
	Terrain3DData *data = _terrain != nullptr ? _terrain->get_data() : nullptr;
	Dictionary d;
	d["streaming_active"] = is_active();
	d["resident"] = data != nullptr ? data->get_region_count() : 0;
	d["free_slots"] = data != nullptr ? data->get_free_slot_count() : 0;
	d["inflight"] = (int)_pending.size();
	d["failed"] = (int)_failed.size();
	d["known"] = (int)_known.size();
	d["landed_total"] = (int64_t)_landed_total;
	d["evicted_total"] = (int64_t)_evicted_total;
	d["land_ms_avg"] = _land_ms_avg;
	return d;
}

///////////////////////////
// Private Functions
///////////////////////////

// Distance between region locations in region units, using the configured area shape
real_t Terrain3DStreamer::_distance_to(const Vector2i &p_region_loc, const Vector2i &p_focus_loc) const {
	Vector2i d = p_region_loc - p_focus_loc;
	if (_shape == CIRCLE) {
		return Vector2(d).length();
	}
	return real_t(MAX(ABS(d.x), ABS(d.y)));
}

// A streamed insertion only matters to collision when the region can intersect the
// dynamic window around the collision target. A forced update() refills shape data in
// place; build() would destroy and recreate the physics body under the player.
void Terrain3DStreamer::_collision_refresh(const Vector2i &p_region_loc) {
	Terrain3DCollision *collision = _terrain->get_collision();
	if (collision == nullptr || !collision->is_enabled() || !collision->is_dynamic_mode()) {
		return;
	}
	Vector3 t = _terrain->get_collision_target_position();
	Vector2 tp = Vector2(t.x, t.z) / _terrain->get_vertex_spacing(); // Descaled, like the window grid
	real_t rs = real_t((int)_terrain->get_region_size());
	Vector2 rmin = Vector2(p_region_loc) * rs;
	Vector2 cp = tp.clamp(rmin, rmin + Vector2(rs, rs));
	real_t d = MAX(ABS(cp.x - tp.x), ABS(cp.y - tp.y));
	if (d <= real_t(collision->get_radius()) + real_t(collision->get_shape_size())) {
		collision->update(V2I_MAX, true);
	}
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DStreamer::_bind_methods() {
	BIND_ENUM_CONSTANT(SQUARE);
	BIND_ENUM_CONSTANT(CIRCLE);

	ClassDB::bind_method(D_METHOD("set_enabled", "enabled"), &Terrain3DStreamer::set_enabled);
	ClassDB::bind_method(D_METHOD("is_enabled"), &Terrain3DStreamer::is_enabled);
	ClassDB::bind_method(D_METHOD("is_active"), &Terrain3DStreamer::is_active);
	ClassDB::bind_method(D_METHOD("set_shape", "shape"), &Terrain3DStreamer::set_shape);
	ClassDB::bind_method(D_METHOD("get_shape"), &Terrain3DStreamer::get_shape);
	ClassDB::bind_method(D_METHOD("set_distance", "distance"), &Terrain3DStreamer::set_distance);
	ClassDB::bind_method(D_METHOD("get_distance"), &Terrain3DStreamer::get_distance);
	ClassDB::bind_method(D_METHOD("set_slots", "slots"), &Terrain3DStreamer::set_slots);
	ClassDB::bind_method(D_METHOD("get_slots"), &Terrain3DStreamer::get_slots);
	ClassDB::bind_method(D_METHOD("set_concurrent_loads", "count"), &Terrain3DStreamer::set_concurrent_loads);
	ClassDB::bind_method(D_METHOD("get_concurrent_loads"), &Terrain3DStreamer::get_concurrent_loads);
	ClassDB::bind_method(D_METHOD("set_loads_per_frame", "count"), &Terrain3DStreamer::set_loads_per_frame);
	ClassDB::bind_method(D_METHOD("get_loads_per_frame"), &Terrain3DStreamer::get_loads_per_frame);
	ClassDB::bind_method(D_METHOD("get_stats"), &Terrain3DStreamer::get_stats);

	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enabled"), "set_enabled", "is_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "shape", PROPERTY_HINT_ENUM, "Square,Circle"), "set_shape", "get_shape");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "distance", PROPERTY_HINT_RANGE, "1,15,1"), "set_distance", "get_distance");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "slots", PROPERTY_HINT_RANGE, "9,1024,1"), "set_slots", "get_slots");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "concurrent_loads", PROPERTY_HINT_RANGE, "1,8,1"), "set_concurrent_loads", "get_concurrent_loads");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "loads_per_frame", PROPERTY_HINT_RANGE, "1,8,1"), "set_loads_per_frame", "get_loads_per_frame");
}
