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
		_flush_ram_cache();
	}
}

// Regions within distance + 1 (hysteresis) stay resident, so the pool must hold
// every cell of the shape at that radius. Square: (2 * (distance + 1) + 1)^2 -
// the default 121 slots fit the default distance 4. A circle needs ~21% fewer.
int Terrain3DStreamer::get_required_slots(const int p_distance) const {
	int retained = p_distance + 1;
	int count = 0;
	for (int dy = -retained; dy <= retained; dy++) {
		for (int dx = -retained; dx <= retained; dx++) {
			if (_distance_to(Vector2i(dx, dy), Vector2i()) <= real_t(retained)) {
				count++;
			}
		}
	}
	return count;
}

// Largest distance the current slot capacity can hold with the current shape
int Terrain3DStreamer::get_max_distance() const {
	int d = 1;
	while (d < 15 && get_required_slots(d + 1) <= _slots) {
		d++;
	}
	return d;
}

// Lowers distance to what the pool can hold. A distance the slots cannot hold
// would permanently starve loading: the pool fills, nothing beyond it ever
// inserts, and nothing evicts, leaving holes in the world.
void Terrain3DStreamer::_apply_distance_limit() {
	int max_distance = get_max_distance();
	if (_distance > max_distance) {
		LOG(WARN, "streaming_distance ", _distance, " needs ", get_required_slots(_distance),
				" slots but only ", _slots, " are allocated; clamping distance to ", max_distance,
				". Raise streaming_slots to increase it");
		_distance = max_distance;
	}
}

void Terrain3DStreamer::set_shape(const StreamShape p_shape) {
	if (_shape == p_shape) {
		return;
	}
	_shape = p_shape;
	_apply_distance_limit();
}

void Terrain3DStreamer::set_distance(const int p_distance) {
	_distance = CLAMP(p_distance, 1, 15);
	// Distance is the primary knob: grow the pool to hold it rather than clamping
	// distance down. slots follows distance up (capped at 1024); only an
	// explicit slots decrease pulls distance back (see set_slots).
	int required = get_required_slots(_distance);
	if (required > _slots) {
		_slots = MIN(required, 1024);
	}
	_apply_distance_limit(); // Still clamps if even 1024 slots cannot hold it (square distance > 14)
}

void Terrain3DStreamer::set_slots(const int p_slots) {
	// Floor at the smallest usable pool: distance 1 with a square shape retains
	// (2 * 2 + 1)^2 = 25 regions, so a smaller pool starves even at the minimum
	// distance. Circle needs fewer, but the square worst case is shape safe.
	_slots = CLAMP(p_slots, 25, 1024);
	_apply_distance_limit();
}

void Terrain3DStreamer::set_mode(const StreamMode p_mode) {
	if (_mode == p_mode) {
		return;
	}
	_mode = p_mode;
	LOG(INFO, "Streaming mode: ", p_mode == RAM ? "RAM resident" : "disk");
	if (p_mode == DISK) {
		// Cached bodies may carry runtime edits that DISK mode would have saved
		// on eviction; write them back before the cache drops
		_flush_ram_cache();
	}
	_prefetch_cursor = 0;
}

// Saves modified cached regions and drops the cache. Runs when leaving RAM mode
// or when streaming stops, so runtime edits are never lost with the bodies.
void Terrain3DStreamer::_flush_ram_cache() {
	if (_terrain != nullptr && !_terrain->get_data_directory().is_empty()) {
		for (const KeyValue<Vector2i, Ref<Terrain3DRegion>> &kv : _ram_cache) {
			if (kv.value.is_valid() && kv.value->is_modified()) {
				String path = _terrain->get_data_directory() + String("/") + Util::location_to_filename(kv.key);
				kv.value->save(path, _terrain->get_save_16_bit());
				mark_known(kv.key);
			}
		}
	}
	_ram_cache.clear();
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
	_flush_ram_cache();
	_prefetch_cursor = 0;
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

// Records that a region file now exists at this location. Called when a region is
// saved or created after the boot scan, so is_location_known stays authoritative for
// the overwrite guards and the dock's on-disk cells. Idempotent.
void Terrain3DStreamer::mark_known(const Vector2i &p_loc) {
	if (_known_set.has(p_loc)) {
		return;
	}
	_known_set.insert(p_loc);
	_known.push_back(p_loc);
}

// Records that a region file was deleted from disk, so the known-set no longer
// reports it. Rewinds the prefetch cursor if it sat past the removed entry.
void Terrain3DStreamer::mark_unknown(const Vector2i &p_loc) {
	if (!_known_set.has(p_loc)) {
		return;
	}
	_known_set.erase(p_loc);
	int idx = _known.find(p_loc);
	if (idx >= 0) {
		_known.remove_at(idx);
		if (_prefetch_cursor > idx) {
			_prefetch_cursor--;
		}
	}
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
		if (_mode == RAM) {
			// Keep the body: eviction only frees the GPU slot, the region parks in
			// the cache with any runtime edits intact and reinserts without disk IO
			Ref<Terrain3DRegion> body = data->get_region(stale[i]);
			data->evict_region(stale[i], String());
			if (body.is_valid()) {
				_ram_cache[stale[i]] = body;
			}
		} else {
			data->evict_region(stale[i], dir);
		}
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
			// Walked away while it loaded: consume, and in RAM mode keep the body
			Ref<Terrain3DRegion> body = ResourceLoader::get_singleton()->load_threaded_get(kv.value);
			if (_mode == RAM && body.is_valid()) {
				body->take_over_path(kv.value);
				body->set_location(kv.key);
				_ram_cache[kv.key] = body;
			}
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
	int inserted = 0;
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
		// Restamping an older region to the current version marks it modified, so
		// merely panning over an old world saves every region back on eviction. Skip
		// it while streaming; a region then upgrades and saves only on a real edit.
		if (!_skip_version_upgrade) {
			region->set_version(Terrain3DData::CURRENT_DATA_VERSION);
		}
		if (data->add_region_streamed(region) == OK) {
			_collision_refresh(ready[i].loc);
			_landed_total += 1;
			inserted += 1;
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
		Vector2i loc = cands[i].loc;
		if (_ram_cache.has(loc)) {
			// RAM mode revisit: the body is already decoded, only the GPU upload
			// remains. Still bounded by loads_per_frame
			if (inserted >= _loads_per_frame || data->get_free_slot_count() <= 0) {
				continue;
			}
			uint64_t t0 = Time::get_singleton()->get_ticks_usec();
			Ref<Terrain3DRegion> region = _ram_cache[loc];
			_ram_cache.erase(loc);
			region->set_location(loc);
			if (!_skip_version_upgrade) {
				region->set_version(Terrain3DData::CURRENT_DATA_VERSION);
			}
			if (data->add_region_streamed(region) == OK) {
				_collision_refresh(loc);
				_landed_total += 1;
				inserted += 1;
				real_t ms = real_t(Time::get_singleton()->get_ticks_usec() - t0) * 0.001f;
				_land_ms_avg = _land_ms_avg == 0.f ? ms : _land_ms_avg * 0.9f + ms * 0.1f;
			}
			continue;
		}
		String path = dir + String("/") + Util::location_to_filename(loc);
		Error err = ResourceLoader::get_singleton()->load_threaded_request(
				path, "Terrain3DRegion", false, ResourceLoader::CACHE_MODE_IGNORE);
		if (err != OK) {
			LOG(ERROR, "Streaming load request failed for ", path, ": ", err);
			_failed.insert(loc);
			continue;
		}
		_pending[loc] = path;
		budget--;
	}
	// RAM mode: spend leftover load budget prefetching the rest of the world into
	// the cache, so revisits and far teleports never touch the disk again
	if (_mode == RAM) {
		while (budget > 0 && _prefetch_cursor < _known.size()) {
			Vector2i loc = _known[_prefetch_cursor];
			_prefetch_cursor++;
			if (data->has_region(loc) || _ram_cache.has(loc) || _failed.has(loc) || _pending.has(loc)) {
				continue;
			}
			String path = dir + String("/") + Util::location_to_filename(loc);
			Error err = ResourceLoader::get_singleton()->load_threaded_request(
					path, "Terrain3DRegion", false, ResourceLoader::CACHE_MODE_IGNORE);
			if (err != OK) {
				_failed.insert(loc);
				continue;
			}
			_pending[loc] = path;
			budget--;
		}
	}
}

Dictionary Terrain3DStreamer::get_stats() const {
	Terrain3DData *data = _terrain != nullptr ? _terrain->get_data() : nullptr;
	Dictionary d;
	d["streaming_active"] = is_active();
	d["resident"] = data != nullptr ? data->get_region_count() : 0;
	d["free_slots"] = data != nullptr ? data->get_free_slot_count() : 0;
	d["inflight"] = (int)_pending.size();
	d["ram_cached"] = (int)_ram_cache.size();
	d["mode"] = _mode == RAM ? "ram" : "disk";
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

	BIND_ENUM_CONSTANT(DISK);
	BIND_ENUM_CONSTANT(RAM);

	ClassDB::bind_method(D_METHOD("set_enabled", "enabled"), &Terrain3DStreamer::set_enabled);
	ClassDB::bind_method(D_METHOD("is_enabled"), &Terrain3DStreamer::is_enabled);
	ClassDB::bind_method(D_METHOD("is_active"), &Terrain3DStreamer::is_active);
	ClassDB::bind_method(D_METHOD("set_shape", "shape"), &Terrain3DStreamer::set_shape);
	ClassDB::bind_method(D_METHOD("get_shape"), &Terrain3DStreamer::get_shape);
	ClassDB::bind_method(D_METHOD("set_mode", "mode"), &Terrain3DStreamer::set_mode);
	ClassDB::bind_method(D_METHOD("get_mode"), &Terrain3DStreamer::get_mode);
	ClassDB::bind_method(D_METHOD("set_distance", "distance"), &Terrain3DStreamer::set_distance);
	ClassDB::bind_method(D_METHOD("get_distance"), &Terrain3DStreamer::get_distance);
	ClassDB::bind_method(D_METHOD("set_slots", "slots"), &Terrain3DStreamer::set_slots);
	ClassDB::bind_method(D_METHOD("get_slots"), &Terrain3DStreamer::get_slots);
	ClassDB::bind_method(D_METHOD("set_concurrent_loads", "count"), &Terrain3DStreamer::set_concurrent_loads);
	ClassDB::bind_method(D_METHOD("get_concurrent_loads"), &Terrain3DStreamer::get_concurrent_loads);
	ClassDB::bind_method(D_METHOD("set_loads_per_frame", "count"), &Terrain3DStreamer::set_loads_per_frame);
	ClassDB::bind_method(D_METHOD("get_loads_per_frame"), &Terrain3DStreamer::get_loads_per_frame);
	ClassDB::bind_method(D_METHOD("set_skip_version_upgrade", "skip"), &Terrain3DStreamer::set_skip_version_upgrade);
	ClassDB::bind_method(D_METHOD("get_skip_version_upgrade"), &Terrain3DStreamer::get_skip_version_upgrade);
	ClassDB::bind_method(D_METHOD("get_required_slots", "distance"), &Terrain3DStreamer::get_required_slots);
	ClassDB::bind_method(D_METHOD("get_max_distance"), &Terrain3DStreamer::get_max_distance);
	ClassDB::bind_method(D_METHOD("scan_directory"), &Terrain3DStreamer::scan_directory);
	ClassDB::bind_method(D_METHOD("is_location_known", "location"), &Terrain3DStreamer::is_location_known);
	ClassDB::bind_method(D_METHOD("get_stats"), &Terrain3DStreamer::get_stats);

	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enabled"), "set_enabled", "is_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "shape", PROPERTY_HINT_ENUM, "Square,Circle"), "set_shape", "get_shape");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mode", PROPERTY_HINT_ENUM, "Disk,RAM Resident"), "set_mode", "get_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "slots", PROPERTY_HINT_RANGE, "25,1024,1"), "set_slots", "get_slots");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "distance", PROPERTY_HINT_RANGE, "1,15,1"), "set_distance", "get_distance");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "concurrent_loads", PROPERTY_HINT_RANGE, "1,8,1"), "set_concurrent_loads", "get_concurrent_loads");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "loads_per_frame", PROPERTY_HINT_RANGE, "1,8,1"), "set_loads_per_frame", "get_loads_per_frame");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "skip_version_upgrade"), "set_skip_version_upgrade", "get_skip_version_upgrade");
}
