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
class Terrain3DData;

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

	static inline const int FAIL_RETRIES = 3; // A failing location is requested this many times, then ignored until a rescan
	static inline const uint64_t FAIL_RETRY_MSEC = 5000; // Wait between requests of a failed location

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
	bool _persist_edits = false; // Write a modified region back to disk when it is evicted
	real_t _frame_budget_ms = 2.f; // Main thread time for insertions and evictions per physics frame, 0 = loads_per_frame

	// A region whose texture layers are being uploaded over several frames
	struct Staged {
		Ref<Terrain3DRegion> region;
		int slot = -1;
		int step = 0; // Maps uploaded so far; the next step commits
		real_t ms = 0.f; // Main thread time spent on it
	};

	// An evicted region handed to a worker thread: written to disk if it carries edits,
	// then released there, so neither the save nor freeing its images stalls the main thread
	struct RetireJob {
		Ref<Terrain3DRegion> region;
		Vector2i loc;
		String path; // Empty when nothing needs saving
		bool save_16_bit = false;
		int64_t task = -1;
	};

	// Work data
	Vector<Vector2i> _known; // Region locations present on disk
	HashSet<Vector2i> _known_set;
	HashMap<Vector2i, uint64_t> _failed; // Failed loads, location -> msec time it may be requested again
	HashMap<Vector2i, int> _fail_count; // Failures per location, a location is given up on after FAIL_RETRIES
	HashMap<Vector2i, String> _pending; // In flight threaded loads, location -> path
	Vector<RetireJob *> _retiring; // Oldest first
	HashSet<Vector2i> _saving; // Locations whose retiring job writes the file; not reloaded until done
	Vector<Staged> _staged; // Reserved regions being uploaded, oldest first
	HashSet<Vector2i> _staged_set;
	HashMap<Vector2i, Ref<Terrain3DRegion>> _ram_cache; // RAM mode: evicted bodies, plus prefetched ones
	int _prefetch_cursor = 0; // RAM mode: background walk of _known filling the cache
	Vector2 _travel_dir; // Moving average of target motion, breaks load order ties
	Vector2 _last_focus;
	bool _has_last_focus = false;
	uint64_t _landed_total = 0; // Counters for get_stats()
	uint64_t _evicted_total = 0;
	real_t _land_ms_avg = 0.f;
	int _bench_batch = 1; // SCRATCH: regions committed together
	int _ready_left = 0; // SCRATCH: loaded regions not yet staged this frame
	uint64_t _commits_total = 0;
	uint64_t _last_commit_total_us = 0;
	uint64_t _last_step_us = 0;
	uint64_t _tick_upload_us = 0;
	uint64_t _tick_reserve_us = 0;
	uint64_t _tick_land_us = 0;
	void _step_impl();

	real_t _distance_to(const Vector2i &p_region_loc, const Vector2i &p_focus_loc) const;
	void _apply_distance_limit();
	void _collision_refresh(const Vector2i &p_region_loc);
	bool _collision_intersects(const Vector2i &p_region_loc);
	void _land_batch(const Vector<Ref<Terrain3DRegion>> &p_regions, const real_t p_ms);
	bool _bench_coalesce_collision = true;
	void _retire(const Vector2i &p_region_loc, const Ref<Terrain3DRegion> &p_region, const String &p_dir);
	void _run_retire_job(const int64_t p_job);
	void _poll_retiring(const bool p_wait);
	bool _budget_spent(const uint64_t p_start_us) const;
	bool _can_insert(const int p_inserted, const bool p_worked, const uint64_t p_start_us) const;
	void _land(const Vector2i &p_region_loc, const real_t p_ms);
	bool _insert(Terrain3DData *p_data, const Ref<Terrain3DRegion> &p_region, const uint64_t p_start_us, bool &r_worked);
	void _advance_staged(Terrain3DData *p_data, const uint64_t p_start_us, bool &r_worked);
	void _flush_ram_cache();
	void _mark_failed(const Vector2i &p_region_loc, const bool p_give_up = false);
	bool _is_failed(const Vector2i &p_region_loc) const;

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
	void set_concurrent_loads(const int p_count) { _concurrent_loads = CLAMP(p_count, 1, 64); }
	int get_concurrent_loads() const { return _concurrent_loads; }
	void set_loads_per_frame(const int p_count) { _loads_per_frame = CLAMP(p_count, 1, 64); }
	int get_loads_per_frame() const { return _loads_per_frame; }
	void set_bench_batch(const int p_n) { _bench_batch = CLAMP(p_n, 1, 64); }
	int get_bench_batch() const { return _bench_batch; }
	void set_bench_coalesce_collision(const bool p_on) { _bench_coalesce_collision = p_on; }
	void set_persist_edits(const bool p_enabled) { _persist_edits = p_enabled; }
	bool get_persist_edits() const { return _persist_edits; }
	void set_frame_budget_ms(const real_t p_ms) { _frame_budget_ms = CLAMP(p_ms, 0.f, 50.f); }
	real_t get_frame_budget_ms() const { return _frame_budget_ms; }

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
