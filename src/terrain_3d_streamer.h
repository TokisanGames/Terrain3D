// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_STREAMER_CLASS_H
#define TERRAIN3D_STREAMER_CLASS_H

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/templates/hash_set.hpp>

#include "constants.h"
#include "terrain_3d_region.h"

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

	enum StreamMode {
		DISK, // RAM and GPU follow the loaded area; evicted regions save and drop
		RAM, // Region bodies stay cached in RAM; only the GPU layers follow
	};

private:
	Terrain3D *_terrain = nullptr;

	// Public settings
	bool _enabled = false;
	StreamShape _shape = SQUARE;
	StreamMode _mode = DISK;
	int _distance = 4; // Regions kept loaded around the clipmap target
	int _slots = 121; // Pooled texture array layers, must exceed the loaded area
	int _concurrent_loads = 3; // Threaded region loads in flight
	int _loads_per_frame = 1; // Loaded regions inserted per physics frame

	// Work data
	Vector<Vector2i> _known; // Region locations present on disk
	HashSet<Vector2i> _known_set;
	HashSet<Vector2i> _failed; // Corrupt or unreadable on disk, never retried
	HashMap<Vector2i, String> _pending; // In flight threaded loads, location -> path
	HashMap<Vector2i, Ref<Terrain3DRegion>> _ram_cache; // RAM mode: evicted bodies, plus prefetched ones
	int _prefetch_cursor = 0; // RAM mode: background walk of _known filling the cache
	Vector2 _travel_dir; // Moving average of target motion, breaks load order ties
	Vector2 _last_focus;
	bool _has_last_focus = false;
	uint64_t _landed_total = 0; // Counters for get_stats()
	uint64_t _evicted_total = 0;
	real_t _land_ms_avg = 0.f;

	real_t _distance_to(const Vector2i &p_region_loc, const Vector2i &p_focus_loc) const;
	void _apply_distance_limit();
	void _collision_refresh(const Vector2i &p_region_loc);
	void _flush_ram_cache();

public:
	Terrain3DStreamer() {}
	~Terrain3DStreamer() { abort_pending(); }
	void initialize(Terrain3D *p_terrain);

	void set_enabled(const bool p_enabled);
	bool is_enabled() const { return _enabled; }
	bool is_active() const; // Enabled and outside the editor
	void set_shape(const StreamShape p_shape);
	StreamShape get_shape() const { return _shape; }
	void set_mode(const StreamMode p_mode);
	StreamMode get_mode() const { return _mode; }
	void set_distance(const int p_distance);
	int get_distance() const { return _distance; }
	void set_slots(const int p_slots);
	int get_slots() const { return _slots; }
	int get_required_slots(const int p_distance) const;
	int get_max_distance() const;
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
using StreamMode = Terrain3DStreamer::StreamMode;
VARIANT_ENUM_CAST(Terrain3DStreamer::StreamShape);
VARIANT_ENUM_CAST(Terrain3DStreamer::StreamMode);

#endif // TERRAIN3D_STREAMER_CLASS_H
