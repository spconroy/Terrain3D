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

	// Work data
	Vector<Vector2i> _known; // Region locations present on disk
	HashSet<Vector2i> _known_set;
	HashSet<Vector2i> _failed; // Corrupt or unreadable on disk, never retried
	HashMap<Vector2i, String> _pending; // In flight threaded loads, location -> path
	HashMap<Vector2i, Ref<Terrain3DRegion>> _ram_cache; // RAM mode: evicted bodies, plus prefetched ones
	int _prefetch_cursor = 0; // RAM mode: background walk of _known filling the cache
	Vector2 _travel_dir; // Moving average of target motion, breaks load order ties
	Vector2 _last_focus;
	Vector2i _focus_loc; // Region location of the clipmap target, set every step
	bool _has_last_focus = false;
	Vector<KeepShape> _keep; // Extra keep shapes, see add_keep_circle()
	int _next_keep_id = 1;
	HashSet<Vector2i> _discard; // In flight loads to drop when they land
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
	real_t _arc_of(const KeepShape &p_shape, const Vector2 &p_point) const;
	KeepShape *_find_keep(const int p_id, const KeepShape::Type p_type);
	void _set_path(KeepShape &p_shape, const PackedVector3Array &p_points);
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
	void apply_distance_limit();
	void set_concurrent_loads(const int p_count) { _concurrent_loads = CLAMP(p_count, 1, 8); }
	int get_concurrent_loads() const { return _concurrent_loads; }
	void set_loads_per_frame(const int p_count) { _loads_per_frame = CLAMP(p_count, 1, 8); }
	int get_loads_per_frame() const { return _loads_per_frame; }
	void set_persist_edits(const bool p_enabled) { _persist_edits = p_enabled; }
	bool get_persist_edits() const { return _persist_edits; }
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
