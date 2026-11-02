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
	// An extra area to keep loaded beside the clipmap target's own area. World units, XZ plane.
	struct KeepShape {
		enum Type {
			CIRCLE,
			PATH,
			CONE,
		};
		int id = 0;
		Type type = CIRCLE;
		bool destination = false; // Loads before everything else
		Vector2 point; // Circle center, cone origin
		Vector2 dir = Vector2(0.f, -1.f); // Cone forward, unit length
		Vector<Vector2> points; // Path polyline
		Vector<real_t> arc; // Path: distance along the polyline at each point
		real_t cam_arc = 0.f; // Path: arc position of the clipmap target, set every step
		real_t radius = 0.f; // Circle radius, path corridor radius, cone half width
		real_t length = 0.f; // Cone extent ahead
		real_t behind = 0.f; // Cone extent behind
	};

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
	real_t _camera_scale = 1.f; // Scales the clipmap target's own area, 0 removes it
	int _keep_cache_limit = 128; // Regions outside the map window whose bodies may be cached
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

	// Optional location -> {path, rotation, mirror, read_only} override, called on the main thread
	Callable _resolver;
	struct Resolved {
		int rotation = 0;
		bool mirror = false;
		bool read_only = false;
	};
	HashMap<Vector2i, Resolved> _resolved; // Pending locations that used the resolver
	HashSet<Vector2i> _virtual; // Locations registered without a file of their own

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
	Vector2i _focus_loc; // Region location of the clipmap target, set every step
	bool _has_last_focus = false;
	Vector2 _focus_pos; // Clipmap target on the XZ plane, set every step
	Vector2 _axis; // Direction of travel of the keep set, unit length: the first path's tangent at the target, else the first cone's
	bool _has_axis = false;
	Vector<KeepShape> _keep; // Extra keep shapes, see add_keep_circle()
	int _next_keep_id = 1;
	HashSet<Vector2i> _discard; // In flight loads to drop when they land
	bool _collision_dirty = false; // A region landed in range of the dynamic collision; refreshed once at the end of step()
	bool _keep_dirty = false; // A shape shrank or vanished: the next step evicts to the strict union
	int _stat_wanted = 0; // Union stats from the last step
	int _stat_missing = 0;
	int _stat_deferred = 0;
	int _stat_outside = 0;
	uint64_t _landed_total = 0; // Counters for get_stats()
	uint64_t _evicted_total = 0;
	real_t _land_ms_avg = 0.f;

	real_t _distance_to(const Vector2i &p_region_loc, const Vector2i &p_focus_loc) const;
	bool _is_wanted(const Vector2i &p_region_loc) const;
	bool _is_retained(const Vector2i &p_region_loc) const;
	bool _is_kept(const Vector2i &p_region_loc, const bool p_retain) const;
	bool _keep_active() const { return !_keep.is_empty() || _camera_scale != 1.f; }
	real_t _region_span() const;
	bool _shape_hit(const KeepShape &p_shape, const Vector2i &p_region_loc, const real_t p_expand, real_t *r_rank) const;
	bool _segment_hit(const KeepShape &p_shape, const int p_index, const Vector2i &p_region_loc, const real_t p_expand, real_t *r_arc) const;
	real_t _arc_of(const KeepShape &p_shape, const Vector2 &p_point, Vector2 *r_dir = nullptr) const;
	void _update_axis();
	bool _is_behind(const Vector2i &p_region_loc) const;
	KeepShape *_find_keep(const int p_id, const KeepShape::Type p_type);
	void _set_path(KeepShape &p_shape, const PackedVector3Array &p_points);
	void _collision_refresh(const Vector2i &p_region_loc);
	void _collision_flush();
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
	Error _request_load(const Vector2i &p_loc, const String &p_dir);
	void _finish_body(const Ref<Terrain3DRegion> &p_region, const Vector2i &p_loc, const String &p_path);

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
	void apply_distance_limit();
	void set_concurrent_loads(const int p_count) { _concurrent_loads = CLAMP(p_count, 1, 8); }
	int get_concurrent_loads() const { return _concurrent_loads; }
	void set_loads_per_frame(const int p_count) { _loads_per_frame = CLAMP(p_count, 1, 8); }
	int get_loads_per_frame() const { return _loads_per_frame; }
	void set_persist_edits(const bool p_enabled) { _persist_edits = p_enabled; }
	bool get_persist_edits() const { return _persist_edits; }
	void set_frame_budget_ms(const real_t p_ms) { _frame_budget_ms = CLAMP(p_ms, 0.f, 50.f); }
	real_t get_frame_budget_ms() const { return _frame_budget_ms; }

	void set_camera_scale(const real_t p_scale);
	real_t get_camera_scale() const { return _camera_scale; }
	void set_keep_cache_limit(const int p_limit) { _keep_cache_limit = CLAMP(p_limit, 0, 4096); }
	int get_keep_cache_limit() const { return _keep_cache_limit; }

	int add_keep_circle(const Vector3 &p_center, const real_t p_radius, const bool p_destination = false);
	int add_keep_path(const PackedVector3Array &p_points, const real_t p_radius);
	int add_keep_cone(const Vector3 &p_origin, const Vector3 &p_direction, const real_t p_length, const real_t p_half_width,
			const real_t p_behind = 0.f, const bool p_destination = false);
	bool set_keep_circle(const int p_id, const Vector3 &p_center, const real_t p_radius);
	bool set_keep_path(const int p_id, const PackedVector3Array &p_points, const real_t p_radius);
	bool set_keep_cone(const int p_id, const Vector3 &p_origin, const Vector3 &p_direction, const real_t p_length,
			const real_t p_half_width, const real_t p_behind = 0.f);
	void remove_keep(const int p_id);
	void clear_keep();
	int get_keep_count() const { return _keep.size(); }

	void set_resolver(const Callable &p_resolver);
	Callable get_resolver() const { return _resolver; }
	void register_virtual_locations(const TypedArray<Vector2i> &p_locations);
	void clear_virtual_locations();

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
