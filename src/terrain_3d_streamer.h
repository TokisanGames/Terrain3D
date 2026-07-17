// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_STREAMER_CLASS_H
#define TERRAIN3D_STREAMER_CLASS_H

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/templates/hash_set.hpp>

#include "constants.h"

using namespace godot;

class Terrain3D;

// Runtime region streaming. Loads regions around the clipmap target on background
// threads and evicts them as the target moves away, so memory scales with the
// loaded area instead of the whole terrain. Works with Terrain3DData's slot pool;
// see Terrain3DData::enable_streaming().
class Terrain3DStreamer : public Object {
	GDCLASS(Terrain3DStreamer, Object);
	CLASS_NAME();

public: // Constants
	enum StreamShape {
		SQUARE,
		CIRCLE,
	};

private:
	Terrain3D *_terrain = nullptr;

	// Public settings
	bool _enabled = false;
	StreamShape _shape = SQUARE;
	int _distance = 4; // Regions kept loaded around the clipmap target
	int _slots = 121; // Pooled texture array layers, must exceed the loaded area
	int _concurrent_loads = 3; // Threaded region loads in flight
	int _loads_per_frame = 1; // Loaded regions inserted per physics frame

	// Work data
	Vector<Vector2i> _known; // Region locations present on disk
	HashSet<Vector2i> _known_set;
	HashSet<Vector2i> _failed; // Corrupt or unreadable on disk, never retried
	HashMap<Vector2i, String> _pending; // In flight threaded loads, location -> path
	Vector2 _travel_dir; // Moving average of target motion, breaks load order ties
	Vector2 _last_focus;
	bool _has_last_focus = false;
	uint64_t _landed_total = 0; // Counters for get_stats()
	uint64_t _evicted_total = 0;
	real_t _land_ms_avg = 0.f;

	real_t _distance_to(const Vector2i &p_region_loc, const Vector2i &p_focus_loc) const;
	void _collision_refresh(const Vector2i &p_region_loc);

public:
	Terrain3DStreamer() {}
	~Terrain3DStreamer() { abort_pending(); }
	void initialize(Terrain3D *p_terrain);

	void set_enabled(const bool p_enabled);
	bool is_enabled() const { return _enabled; }
	bool is_active() const; // Enabled and outside the editor
	void set_shape(const StreamShape p_shape) { _shape = p_shape; }
	StreamShape get_shape() const { return _shape; }
	void set_distance(const int p_distance) { _distance = CLAMP(p_distance, 1, 15); }
	int get_distance() const { return _distance; }
	void set_slots(const int p_slots) { _slots = CLAMP(p_slots, 9, 1024); }
	int get_slots() const { return _slots; }
	void set_concurrent_loads(const int p_count) { _concurrent_loads = CLAMP(p_count, 1, 8); }
	int get_concurrent_loads() const { return _concurrent_loads; }
	void set_loads_per_frame(const int p_count) { _loads_per_frame = CLAMP(p_count, 1, 8); }
	int get_loads_per_frame() const { return _loads_per_frame; }

	void scan_directory();
	void step();
	void abort_pending();
	Dictionary get_stats() const;

protected:
	static void _bind_methods();
};

using StreamShape = Terrain3DStreamer::StreamShape;
VARIANT_ENUM_CAST(Terrain3DStreamer::StreamShape);

#endif // TERRAIN3D_STREAMER_CLASS_H
