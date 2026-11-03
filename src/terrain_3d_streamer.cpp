// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/worker_thread_pool.hpp>

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

// Largest distance the current slot capacity can hold with the current shape, and
// whose retained area (2 * (distance + 1) + 1 regions across) fits the region map window
int Terrain3DStreamer::get_max_distance() const {
	const Terrain3DData *data = _terrain != nullptr ? _terrain->get_data() : nullptr;
	const int window = data != nullptr ? data->get_region_map_size() : Terrain3DData::REGION_MAP_SIZE;
	int d = 1;
	while (d < 15 && get_required_slots(d + 1) <= _slots && 2 * (d + 2) + 1 <= window) {
		d++;
	}
	return d;
}

// Lowers distance to what the pool can hold. A distance the slots cannot hold
// would permanently starve loading: the pool fills, nothing beyond it ever
// inserts, and nothing evicts, leaving holes in the world.
void Terrain3DStreamer::apply_distance_limit() {
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
	apply_distance_limit();
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
	apply_distance_limit(); // Still clamps if even 1024 slots cannot hold it (square distance > 14)
}

void Terrain3DStreamer::set_slots(const int p_slots) {
	// Floor at the smallest usable pool: distance 1 with a square shape retains
	// (2 * 2 + 1)^2 = 25 regions, so a smaller pool starves even at the minimum
	// distance. Circle needs fewer, but the square worst case is shape safe.
	_slots = CLAMP(p_slots, 25, 1024);
	apply_distance_limit();
}

void Terrain3DStreamer::set_mode(const StreamMode p_mode) {
	if (_mode == p_mode) {
		return;
	}
	_mode = p_mode;
	LOG(INFO, "Streaming mode: ", p_mode == RAM ? "RAM resident" : "disk");
	if (p_mode == DISK) {
		// Cached bodies may carry runtime edits; they are written back before the cache
		// drops only when persist_edits is on
		_flush_ram_cache();
	}
	_prefetch_cursor = 0;
}

// Drops the cache, first saving modified regions when persist_edits is on. Runs when leaving
// RAM mode or when streaming stops; otherwise cached runtime edits are discarded.
void Terrain3DStreamer::_flush_ram_cache() {
	// Only write cached edits back when the terrain opts in; by default streaming never
	// persists on its own (see Terrain3DData::evict_region).
	if (_terrain != nullptr && _persist_edits && !_terrain->get_data_directory().is_empty()) {
		for (const KeyValue<Vector2i, Ref<Terrain3DRegion>> &kv : _ram_cache) {
			if (kv.value.is_valid() && kv.value->is_modified() && !kv.value->is_read_only() && !_lazy.has(kv.key)) {
				kv.value->save(_file_path(kv.key, _terrain->get_data_directory()), _terrain->get_save_16_bit());
			}
		}
	}
	_ram_cache.clear();
	_gated.clear(); // Gated bodies lived in the cache
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
	_resolved.clear();
	_discard.clear();
	// Staged regions hold pool slots of the data being torn down or rebuilt
	_staged.clear();
	_staged_set.clear();
	_gated.clear();
	_poll_retiring(true);
}

// The resolver maps a region location to the file that provides it, so several locations
// can share one file: Callable(location: Vector2i) -> Dictionary {path: String,
// rotation: int 0-3 clockwise quarter turns, mirror: bool, read_only: bool}. An empty
// Dictionary or an empty path means the normal file for the location. It is called on
// the main thread each time the streamer requests a location; keep it fast.
void Terrain3DStreamer::set_resolver(const Callable &p_resolver) {
	_resolver = p_resolver;
}

// Makes locations known to the streamer without a file in the data directory. They are
// loaded through the resolver; a virtual location with no resolver result fails like a
// missing file. Survives scan_directory().
void Terrain3DStreamer::register_virtual_locations(const TypedArray<Vector2i> &p_locations) {
	for (int i = 0; i < p_locations.size(); i++) {
		Vector2i loc = p_locations[i];
		_virtual.insert(loc);
		_lazy.erase(loc);
		if (!_known_set.has(loc)) {
			_known.push_back(loc);
			_known_set.insert(loc);
		}
	}
}

void Terrain3DStreamer::clear_virtual_locations() {
	_virtual.clear();
	scan_directory();
}

// Lazily generated regions. The game registers locations that belong to the world but whose file it has not
// written yet. They are wanted like any known location, so they appear in the keep set statistics, count as
// missing (get_path_ready_distance, nearest_missing, missing) and are listed by get_wanted_pending() in load
// order, but the streamer never requests them: no load, no failure, no retry. The game writes the file
// atomically and calls notify_region_written(), after which the location is loaded like any other.
// Locations the streamer already knows, or holds resident, are not pending and are skipped.
void Terrain3DStreamer::register_pending_locations(const Array &p_locations) {
	Terrain3DData *data = _terrain != nullptr ? _terrain->get_data() : nullptr;
	for (int i = 0; i < p_locations.size(); i++) {
		if (p_locations[i].get_type() != Variant::VECTOR2I) {
			continue;
		}
		const Vector2i loc = p_locations[i];
		if (abs(loc.x) > Terrain3DRegion::MAX_LOCATION || abs(loc.y) > Terrain3DRegion::MAX_LOCATION) {
			continue;
		}
		if (_known_set.has(loc) || (data != nullptr && data->has_region(loc))) {
			continue;
		}
		_lazy.insert(loc);
		_failed.erase(loc);
		_fail_count.erase(loc);
	}
}

// Forgets every pending location, e.g. when the world is replaced. Nothing is loaded or evicted by this.
void Terrain3DStreamer::clear_pending_locations() {
	_lazy.clear();
	_wanted_lazy.clear();
	_stat_generating_wanted = 0;
}

TypedArray<Vector2i> Terrain3DStreamer::get_pending_locations() const {
	TypedArray<Vector2i> out;
	for (const Vector2i &loc : _lazy) {
		out.push_back(loc);
	}
	return out;
}

// The pending locations the last step() wanted, in the order loads would run: destination shapes first, then
// paths in order of arrival, then everything else nearest first, regions behind the direction of travel and
// those only fetched ahead of a path's reach last. Locations notified since are left out.
TypedArray<Vector2i> Terrain3DStreamer::get_wanted_pending(const int p_max) const {
	TypedArray<Vector2i> out;
	for (int i = 0; i < _wanted_lazy.size() && out.size() < p_max; i++) {
		if (_lazy.has(_wanted_lazy[i])) {
			out.push_back(_wanted_lazy[i]);
		}
	}
	return out;
}

// The game wrote the file of a location (atomically: a complete file under its final name). It leaves the pending
// set and becomes known without scanning the directory; the streamer requests it by the normal priority. The
// optional path names the file when it is not the data directory's own name for the location. Also usable for a
// location that was never pending, and for one that failed to load before: the failure is forgotten.
void Terrain3DStreamer::notify_region_written(const Vector2i &p_location, const String &p_path) {
	if (abs(p_location.x) > Terrain3DRegion::MAX_LOCATION || abs(p_location.y) > Terrain3DRegion::MAX_LOCATION) {
		return;
	}
	_lazy.erase(p_location);
	if (p_path.is_empty()) {
		_paths.erase(p_location);
	} else {
		_paths[p_location] = p_path;
	}
	_failed.erase(p_location);
	_fail_count.erase(p_location);
	if (!_known_set.has(p_location)) {
		_known.push_back(p_location);
		_known_set.insert(p_location);
	}
}

void Terrain3DStreamer::notify_regions_written(const Array &p_locations) {
	for (int i = 0; i < p_locations.size(); i++) {
		if (p_locations[i].get_type() == Variant::VECTOR2I) {
			notify_region_written(p_locations[i]);
		}
	}
}

// Files found by a scan and locations written with their own path are no longer pending
void Terrain3DStreamer::_sync_pending() {
	for (const KeyValue<Vector2i, String> &kv : _paths) {
		if (!_known_set.has(kv.key)) {
			_known.push_back(kv.key);
			_known_set.insert(kv.key);
		}
	}
	Vector<Vector2i> found;
	for (const Vector2i &loc : _lazy) {
		if (_known_set.has(loc)) {
			found.push_back(loc);
		}
	}
	for (int i = 0; i < found.size(); i++) {
		_lazy.erase(found[i]);
	}
}

// The insert gate decides when a loaded region may become visible: Callable(location: Vector2i) -> bool.
// It is called on the main thread, for every region that is ready to be inserted, on each step, so it must be
// a cheap lookup and must not change the streamer. false holds the region: its body waits in the RAM cache,
// holds no pool slot and counts as not visible (get_path_ready_distance, nearest_missing). true, anything
// that is not a bool, or an invalid Callable lets it through. After gate_timeout_ms it is inserted anyway.
void Terrain3DStreamer::set_insert_gate(const Callable &p_gate) {
	_insert_gate = p_gate;
	if (!_insert_gate.is_valid()) {
		_gated.clear();
	}
}

TypedArray<Vector2i> Terrain3DStreamer::get_gated_regions() const {
	TypedArray<Vector2i> out;
	for (const KeyValue<Vector2i, Gated> &kv : _gated) {
		if (kv.value.held) {
			out.push_back(kv.key);
		}
	}
	return out;
}

// Scans the data directory for region locations. Only file names are read, nothing is loaded.
void Terrain3DStreamer::scan_directory() {
	IS_INIT(VOID);
	_known.clear();
	_known_set.clear();
	_failed.clear();
	_fail_count.clear();
	_resolved.clear();
	abort_pending();
	_flush_ram_cache();
	_prefetch_cursor = 0;
	_travel_dir = Vector2();
	_has_last_focus = false;
	_landed_total = 0;
	_evicted_total = 0;
	_land_ms_avg = 0.f;
	_stat_gate_timeouts = 0;
	_stat_gate_wait_max = 0;
	for (const Vector2i &loc : _virtual) {
		_known.push_back(loc);
		_known_set.insert(loc);
	}
	String dir = _terrain->get_data_directory();
	if (dir.is_empty()) {
		_sync_pending();
		return;
	}
	PackedStringArray files = Util::get_files(dir, "terrain3d*.res");
	for (const String &fname : files) {
		Vector2i loc = Util::filename_to_location(fname);
		if (loc.x == INT32_MAX) {
			continue; // Sibling non-region file
		}
		if (abs(loc.x) > Terrain3DRegion::MAX_LOCATION || abs(loc.y) > Terrain3DRegion::MAX_LOCATION) {
			// Region locations are bounded; a file beyond the limit cannot be added as a region
			LOG(WARN, "Streaming scan: ignoring ", fname, ", location ", loc, " is outside the world");
			continue;
		}
		if (!_known_set.has(loc)) {
			_known.push_back(loc);
			_known_set.insert(loc);
		}
	}
	_sync_pending();
	LOG(INFO, "Streaming scan: ", _known.size(), " regions on disk at ", dir);
}

static real_t _rect_point_dist2(const Vector2 &p_min, const Vector2 &p_max, const Vector2 &p_point);

// Runs the streaming state machine once per physics frame: evict regions that fell
// outside the keep set, insert completed loads, and request missing regions.
// The keep set is the union of the clipmap target's own area (distance regions, scaled by
// camera_scale) and any shapes added with add_keep_*(). With no shapes it is the clipmap
// target's area alone. IO runs wide (concurrent_loads threaded loads decompress at once)
// while insertions stay narrow (loads_per_frame per physics frame), since the texture
// layer uploads and signal cascade are the main thread cost that hitches. Insertions are
// staged over frames (frame_budget_ms) and evicted bodies are retired on a worker thread.
void Terrain3DStreamer::step() {
	IS_INIT(VOID);
	Terrain3DData *data = _terrain->get_data();
	if (data == nullptr || !data->is_streaming()) {
		return;
	}
	String dir = _terrain->get_data_directory();
	Vector3 focus = _terrain->get_clipmap_target_position();
	Vector2i floc = data->get_region_location(focus);
	_focus_loc = floc;
	Vector2 fpos = Vector2(focus.x, focus.z);
	_focus_pos = fpos;
	_update_axis();
	// Region locations are unbounded, the region map window is not. Recentre it whenever the
	// retained area (distance + 1, see eviction below) leaves it. Regions left outside are beyond the
	// retained area, so they evict below. Along a keep path or cone the window also slides ahead of the
	// target: the retained area stays inside, the rest of the window reaches along the direction of
	// travel, and it moves as soon as a region needed now lies outside, so that regions ahead take a
	// slot with time to spare instead of only when the target arrives. Wanted regions beyond the
	// window wait in the body cache until it reaches them.
	const int retained = _distance + 1;
	const Vector2i origin = data->get_region_map_origin();
	const int window = data->get_region_map_size();
	const bool escaped = floc.x - retained < origin.x || floc.y - retained < origin.y ||
			floc.x + retained >= origin.x + window || floc.y + retained >= origin.y + window;
	Vector2i target = floc - V2I(window / 2);
	if (_has_axis) {
		// Keep the retained area at the rear of the window, on the axes the direction of travel points along
		const real_t bias = 0.3f;
		target = floc - V2I(window / 2);
		if (_axis.x > bias) {
			target.x = floc.x - retained;
		} else if (_axis.x < -bias) {
			target.x = floc.x + retained - window + 1;
		}
		if (_axis.y > bias) {
			target.y = floc.y - retained;
		} else if (_axis.y < -bias) {
			target.y = floc.y + retained - window + 1;
		}
		// Pick the position of the window that leaves the fewest regions needed now outside it: the one
		// reaching ahead, the one centred on the target (what a destination around the target needs once
		// it stops), or where it is. Move only when that is an improvement...
		auto outside_of = [&](const Vector2i &p_origin) {
			int n = 0;
			for (int i = 0; i < _wanted_near.size(); i++) {
				const Vector2i &w = _wanted_near[i];
				n += (w.x < p_origin.x || w.y < p_origin.y || w.x >= p_origin.x + window || w.y >= p_origin.y + window) ? 1 : 0;
			}
			return n;
		};
		const Vector2i centred = floc - V2I(window / 2);
		const int outside_now = outside_of(origin);
		const int outside_ahead = outside_of(target);
		const int outside_centred = outside_of(centred);
		if (outside_centred < outside_ahead) {
			target = centred;
		}
		const int outside_after = MIN(outside_ahead, outside_centred);
		// ...and in jumps of a few regions, so a fast flight does not rewrite the map every region it crosses
		const Vector2i shift = target - origin;
		if (!escaped && (outside_now == 0 || outside_after >= outside_now || (ABS(shift.x) < WINDOW_SLIDE_MIN && ABS(shift.y) < WINDOW_SLIDE_MIN))) {
			target = origin;
		}
	}
	if (target != origin && (escaped || _has_axis)) {
		data->set_region_map_origin(target);
		_stat_recentres += 1;
	}
	// Track the travel direction so regions ahead of travel load first on ties.
	// A teleport (a jump beyond one region span) resets it.
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
	const bool keep_active = _keep_active();
	const real_t span = _region_span();
	uint64_t start_us = Time::get_singleton()->get_ticks_usec();
	_poll_retiring(false);

	// Collect the wanted set: every known region inside the keep set, with its load order.
	// Order is (behind, tier, rank): regions behind the direction of travel last, then destination
	// shapes first, then paths in order of arrival from the target, then everything else nearest
	// first with ties broken toward the travel direction. defer is how far the region is from being
	// needed, in meters: a short pool keeps the smallest values and defers the rest, behind last.
	struct Want {
		Vector2i loc;
		int tier = 2;
		real_t rank = 0.f;
		real_t ahead = 0.f;
		real_t cam_d = 0.f;
		bool behind = false;
		bool cache_only = false; // Body only: beyond the reach of a path, requested after everything that is needed
		bool lazy = false; // Pending: the game has not generated its file yet, never requested
		real_t defer = 0.f;
	};
	struct WantSort {
		bool operator()(const Want &a, const Want &b) const {
			if (a.cache_only != b.cache_only) {
				return b.cache_only;
			}
			if (a.behind != b.behind) {
				return b.behind;
			}
			if (a.tier != b.tier) {
				return a.tier < b.tier;
			}
			if (!Math::is_equal_approx(a.rank, b.rank)) {
				return a.rank < b.rank;
			}
			return a.ahead > b.ahead;
		}
	};
	struct CamSort {
		bool operator()(const Want &a, const Want &b) const {
			if (!Math::is_equal_approx(a.cam_d, b.cam_d)) {
				return a.cam_d < b.cam_d;
			}
			return a.ahead > b.ahead;
		}
	};
	struct DeferSort {
		bool operator()(const Want &a, const Want &b) const {
			if (a.behind != b.behind) {
				return b.behind;
			}
			if (!Math::is_equal_approx(a.defer, b.defer)) {
				return a.defer < b.defer;
			}
			return a.ahead > b.ahead;
		}
	};
	HashMap<Vector2i, Want> wanted;
	// p_defer < 0 means the distance to the target in meters. A path passes its arrival distance.
	auto add_want = [&](const Vector2i &p_loc, int p_tier, real_t p_rank, real_t p_ahead, bool p_behind, real_t p_defer = -1.f, bool p_cache_only = false) {
		const bool lazy = _lazy.has(p_loc);
		if (lazy ? data->has_region(p_loc) : (!_known_set.has(p_loc) || _is_failed(p_loc))) {
			return;
		}
		Want w;
		w.loc = p_loc;
		w.lazy = lazy;
		w.tier = p_tier;
		w.rank = p_rank;
		w.ahead = p_ahead;
		w.cam_d = _distance_to(p_loc, floc);
		w.behind = p_behind;
		w.cache_only = p_cache_only;
		w.defer = p_defer >= 0.f ? p_defer : w.cam_d * span;
		Want *old = wanted.getptr(p_loc);
		if (old != nullptr) {
			// A region claimed twice keeps the better order and the nearer need
			const real_t defer = MIN(old->defer, w.defer);
			if (!WantSort()(w, *old)) {
				old->defer = defer;
				return;
			}
			w.defer = defer;
		}
		wanted[p_loc] = w;
	};
	if (_camera_scale > 0.f) {
		const int reach = (int)Math::ceil(real_t(_distance) * _camera_scale);
		for (int dy = -reach; dy <= reach; dy++) {
			for (int dx = -reach; dx <= reach; dx++) {
				Vector2i loc = floc + Vector2i(dx, dy);
				if (!_is_wanted(loc)) {
					continue; // Corner outside a circular area
				}
				real_t d = _distance_to(loc, floc);
				real_t ahead = (d == 0.f) ? 1.f : _travel_dir.dot(Vector2(real_t(dx), real_t(dy)).normalized());
				add_want(loc, 2, d, ahead, _is_behind(loc));
			}
		}
	}
	for (int k = 0; k < _keep.size(); k++) {
		const KeepShape &s = _keep[k];
		const int tier = s.destination ? 0 : (s.type == KeepShape::PATH ? 1 : 2);
		if (s.type == KeepShape::PATH) {
			const real_t cam_arc = _arc_of(s, fpos);
			for (int i = 0; i + 1 < s.points.size(); i++) {
				Vector2 lo = s.points[i].min(s.points[i + 1]) - V2(s.radius);
				Vector2 hi = s.points[i].max(s.points[i + 1]) + V2(s.radius);
				Vector2i c0 = Vector2i((lo / span).floor());
				Vector2i c1 = Vector2i((hi / span).floor());
				for (int y = c0.y; y <= c1.y; y++) {
					for (int x = c0.x; x <= c1.x; x++) {
						real_t arc = 0.f;
						if (_segment_hit(s, i, Vector2i(x, y), 0.f, &arc)) {
							// Ahead of the target first, in order along the path; behind last. The region
							// the target stands in is ahead whichever side of its center the target is
							const bool behind = arc < cam_arc - span * 0.5f;
							real_t rank = behind ? cam_arc - arc : MAX(arc - cam_arc, 0.f);
							if (_beyond_reach(s, arc, true)) {
								continue; // Beyond even the prefetch reach
							}
							add_want(Vector2i(x, y), tier, rank, 0.f, behind, rank, _beyond_reach(s, arc, false));
						}
					}
				}
			}
			continue;
		}
		const real_t reach = s.type == KeepShape::CIRCLE ? s.radius : MAX(MAX(s.length, s.behind), s.radius);
		Vector2i c0 = Vector2i(((s.point - V2(reach)) / span).floor());
		Vector2i c1 = Vector2i(((s.point + V2(reach)) / span).floor());
		for (int y = c0.y; y <= c1.y; y++) {
			for (int x = c0.x; x <= c1.x; x++) {
				real_t rank = 0.f;
				if (_shape_hit(s, Vector2i(x, y), 0.f, &rank)) {
					add_want(Vector2i(x, y), tier, rank, 0.f, _is_behind(Vector2i(x, y)));
				}
			}
		}
	}
	// Split by the region map window; only regions inside it can take a slot
	// Pending locations count as wanted and missing but take no slot until their file exists
	Vector<Want> in_window;
	Vector<Want> lazy_wants;
	int outside = 0;
	int lazy_missing = 0;
	_wanted_near.clear();
	_wanted_cache.clear();
	for (const KeyValue<Vector2i, Want> &kv : wanted) {
		if (kv.value.lazy) {
			lazy_wants.push_back(kv.value);
		}
		if (kv.value.cache_only) {
			_wanted_cache.push_back(kv.key);
			continue;
		}
		_wanted_near.push_back(kv.key);
		const bool in_map = data->get_region_map_index(kv.key) >= 0;
		if (kv.value.lazy) {
			lazy_missing += in_map ? 1 : 0;
			outside += in_map ? 0 : 1;
		} else if (in_map) {
			in_window.push_back(kv.value);
		} else {
			outside++;
		}
	}
	lazy_wants.sort_custom<WantSort>();
	_wanted_lazy.clear();
	_stat_generating_wanted = 0;
	for (int i = 0; i < lazy_wants.size(); i++) {
		_wanted_lazy.push_back(lazy_wants[i].loc);
		_stat_generating_wanted += (lazy_wants[i].cache_only || lazy_wants[i].behind) ? 0 : 1;
	}
	// A pool smaller than the union keeps what is needed first and defers the rest: regions ahead
	// of the direction of travel before regions behind it, nearest first, a path by arrival
	HashSet<Vector2i> deferred;
	if (keep_active && in_window.size() > data->get_slot_capacity()) {
		in_window.sort_custom<DeferSort>();
		for (int i = data->get_slot_capacity(); i < in_window.size(); i++) {
			deferred.insert(in_window[i].loc);
		}
	}
	_stat_wanted = _wanted_near.size();
	_stat_outside = outside;
	_stat_deferred = (int)deferred.size();

	// Evict regions beyond the keep set plus one region of hysteresis, up to 8 per frame so
	// a teleport frees the whole stale area quickly without starving the pool. A keep set
	// that shrank evicts to its strict union at once and becomes the new baseline.
	TypedArray<Vector2i> loaded = data->get_region_locations();
	HashSet<Vector2i> resident;
	Vector<Vector2i> stale;
	for (int i = 0; i < loaded.size(); i++) {
		Vector2i loc = loaded[i];
		resident.insert(loc);
		if (data->get_region_map_index(loc) < 0 || deferred.has(loc) || !_is_kept(loc, !_keep_dirty)) {
			stale.push_back(loc);
		}
	}
	if (keep_active) {
		// The pool must also hold what is still missing: spend hysteresis regions
		// (retained but not wanted), farthest first, rather than starve the union
		int missing = 0;
		for (int i = 0; i < in_window.size(); i++) {
			if (!resident.has(in_window[i].loc) && !deferred.has(in_window[i].loc) && !_staged_set.has(in_window[i].loc)) {
				missing++;
			}
		}
		_stat_missing = missing + lazy_missing;
		int freeing = _keep_dirty ? (int)stale.size() : MIN((int)stale.size(), 8);
		int short_by = missing - data->get_free_slot_count() - freeing;
		if (short_by > 0) {
			HashSet<Vector2i> queued;
			for (int i = 0; i < stale.size(); i++) {
				queued.insert(stale[i]);
			}
			Vector<Want> band;
			for (int i = 0; i < loaded.size(); i++) {
				Vector2i loc = loaded[i];
				if (queued.has(loc) || wanted.has(loc)) {
					continue;
				}
				Want w;
				w.loc = loc;
				w.cam_d = -_distance_to(loc, floc);
				band.push_back(w);
			}
			band.sort_custom<CamSort>(); // Farthest first through the negated distance
			for (int i = 0; i < band.size() && i < short_by; i++) {
				stale.push_back(band[i].loc);
			}
		}
	} else {
		_stat_missing = lazy_missing;
	}
	const int evict_limit = _keep_dirty ? (int)stale.size() : 8;
	for (int i = 0; i < stale.size() && i < evict_limit; i++) {
		if (!_keep_dirty && i > 0 && _budget_spent(start_us)) {
			break; // An early eviction after a shape shrank is not budgeted: the keep set must be exact at once
		}
		if (_mode == RAM) {
			// Keep the body: eviction only frees the GPU slot, the region parks in
			// the cache with any runtime edits intact and reinserts without disk IO
			Ref<Terrain3DRegion> body = data->get_region(stale[i]);
			data->evict_region(stale[i], String());
			if (body.is_valid()) {
				_ram_cache[stale[i]] = body;
			}
		} else {
			// A worker thread writes a modified body (persist_edits) and frees it
			Ref<Terrain3DRegion> body = data->get_region(stale[i]);
			data->evict_region(stale[i], String());
			if (body.is_valid()) {
				_retire(stale[i], body, dir);
			}
		}
		_evicted_total += 1;
		resident.erase(stale[i]);
	}
	// Drop staged regions that left the keep set before they became visible
	for (int i = _staged.size() - 1; i >= 0; i--) {
		Vector2i loc = _staged[i].region->get_location();
		if (data->get_region_map_index(loc) < 0 || deferred.has(loc) || !_is_kept(loc, !_keep_dirty)) {
			if (_mode == RAM) {
				_ram_cache[loc] = _staged[i].region;
			}
			data->release_slot_streamed(_staged[i].slot);
			_staged_set.erase(loc);
			_staged.remove_at(i);
		}
	}
	if (_keep_dirty) {
		// New baseline: loads still in flight for area outside the strict union land nowhere
		for (const KeyValue<Vector2i, String> &kv : _pending) {
			if (!_is_kept(kv.key, false, true)) {
				_discard.insert(kv.key);
			}
		}
	}
	_keep_dirty = false;
	if (_mode == DISK && !_ram_cache.is_empty()) {
		// Prefetched bodies of keep shapes drop once nothing keeps them
		Vector<Vector2i> unkept;
		for (const KeyValue<Vector2i, Ref<Terrain3DRegion>> &kv : _ram_cache) {
			if (!_is_kept(kv.key, true, true)) {
				unkept.push_back(kv.key);
			}
		}
		for (int i = 0; i < unkept.size(); i++) {
			_ram_cache.erase(unkept[i]);
		}
	}
	// Poll in flight loads. Failures are marked and never retried, loads that fell out
	// of range while loading are consumed and dropped, and the nearest completed
	// bodies are inserted, up to loads_per_frame
	struct Landing {
		Vector2i loc;
		String path;
		bool behind = false;
		int tier = 2;
		real_t rank = 0.f;
		bool cached = false; // The body waits in the RAM cache (held by the insert gate), no load to collect
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
			// Consume the failed task. The loader pins it otherwise, and a later request for the path would
			// only report the old failure instead of reading the file again
			ResourceLoader::get_singleton()->load_threaded_get(kv.value);
			_mark_failed(kv.key);
			drop.push_back(kv.key);
			continue;
		}
		const bool kept = !_discard.has(kv.key) && _is_kept(kv.key, true, true);
		const Want *pending_want = wanted.getptr(kv.key);
		if (!kept || data->get_region_map_index(kv.key) < 0 || deferred.has(kv.key) || (pending_want != nullptr && pending_want->cache_only)) {
			// Walked away while it loaded, or loaded for a spot beyond the map window or one the slot pool
			// cannot hold yet: consume, and keep the body in RAM mode or while a keep shape still wants it
			Ref<Terrain3DRegion> body = ResourceLoader::get_singleton()->load_threaded_get(kv.value);
			_stat_disk_needed += (kept && (pending_want == nullptr || !pending_want->cache_only)) ? 1 : 0;
			if (body.is_valid() && (_mode == RAM || (kept && (int)_ram_cache.size() < _keep_cache_limit))) {
				_finish_body(body, kv.key, kv.value);
				body->set_modified(false);
				_ram_cache[kv.key] = body;
			}
			drop.push_back(kv.key);
			continue;
		}
		Landing l;
		l.loc = kv.key;
		l.path = kv.value;
		if (wanted.has(kv.key)) {
			l.behind = wanted[kv.key].behind;
			l.tier = wanted[kv.key].tier;
			l.rank = wanted[kv.key].rank;
		} else {
			l.tier = 3; // Hysteresis band
			l.rank = _distance_to(kv.key, floc);
		}
		ready.push_back(l);
	}
	for (int i = 0; i < drop.size(); i++) {
		_pending.erase(drop[i]);
		_resolved.erase(drop[i]);
		_discard.erase(drop[i]);
	}
	// With an insert gate, bodies it holds back wait in the cache and compete with new loads in one order
	const bool gating = _insert_gate.is_valid();
	_gate_step += 1;
	if (gating) {
		for (const KeyValue<Vector2i, Want> &kv : wanted) {
			const Vector2i &loc = kv.key;
			if (kv.value.cache_only || kv.value.lazy || !_ram_cache.has(loc) || data->get_region_map_index(loc) < 0 || deferred.has(loc) ||
					resident.has(loc) || data->has_region(loc) || _is_failed(loc) || _pending.has(loc) ||
					_staged_set.has(loc) || _saving.has(loc)) {
				continue;
			}
			Landing l;
			l.loc = loc;
			l.behind = kv.value.behind;
			l.tier = kv.value.tier;
			l.rank = kv.value.rank;
			l.cached = true;
			ready.push_back(l);
		}
		for (const Landing &l : ready) {
			Gated *g = _gated.getptr(l.loc);
			if (g != nullptr) {
				g->seen = _gate_step;
			}
		}
	}
	if (!_gated.is_empty()) {
		// Forget what is no longer waiting here: inserted, evicted, or left the window or the keep set
		Vector<Vector2i> gone;
		for (const KeyValue<Vector2i, Gated> &kv : _gated) {
			if (kv.value.seen != _gate_step) {
				gone.push_back(kv.key);
			}
		}
		for (int i = 0; i < gone.size(); i++) {
			_gated.erase(gone[i]);
		}
	}
	struct LandingSort {
		bool operator()(const Landing &a, const Landing &b) const {
			if (a.behind != b.behind) {
				return b.behind;
			}
			if (a.tier != b.tier) {
				return a.tier < b.tier;
			}
			return a.rank < b.rank;
		}
	};
	ready.sort_custom<LandingSort>();
	int inserted = 0;
	bool worked = false;
	bool full = false; // The insertion budget is spent; with an insert gate the rest is still asked, to hold it
	_advance_staged(data, start_us, worked); // Finish a region begun on an earlier frame first
	for (int i = 0; i < ready.size(); i++) {
		if (!full && !_can_insert(inserted, worked, start_us)) {
			if (!gating) {
				break;
			}
			full = true;
		}
		const Vector2i loc = ready[i].loc;
		if (gating && !_gate_open(loc)) {
			// Held back. It takes neither a slot nor insertion budget: a finished load leaves the loader (and its
			// concurrent load place) for the cache, a cached body stays, and the next ready region is tried
			if (!ready[i].cached) {
				Ref<Terrain3DRegion> body = ResourceLoader::get_singleton()->load_threaded_get(ready[i].path);
				_pending.erase(loc);
				_stat_disk_needed += 1;
				if (body.is_null()) {
					_resolved.erase(loc);
					LOG(ERROR, "Streaming load returned null region ", loc);
					_mark_failed(loc);
					_gated.erase(loc);
					continue;
				}
				_finish_body(body, loc, ready[i].path);
				_resolved.erase(loc);
				body->set_modified(false);
				_ram_cache[loc] = body;
			}
			continue;
		}
		if (full) {
			continue;
		}
		Ref<Terrain3DRegion> region;
		if (ready[i].cached) {
			region = _ram_cache[loc];
			_ram_cache.erase(loc);
			region->set_location(loc);
		} else {
			region = ResourceLoader::get_singleton()->load_threaded_get(ready[i].path);
			_pending.erase(loc);
			_stat_disk_needed += 1;
			if (region.is_null()) {
				_resolved.erase(loc);
				LOG(ERROR, "Streaming load returned null region ", loc);
				_mark_failed(loc);
				continue;
			}
			_finish_body(region, loc, ready[i].path);
			_resolved.erase(loc);
			// Loading runs the setters, which flag the region modified. Reset it like load_directory
			// does; otherwise persist_edits would rewrite every region it evicts. The on disk version is
			// left alone: streaming is read only, and a save stamps the current version itself
			region->set_modified(false);
		}
		if (_insert(data, region, start_us, worked)) {
			inserted += 1;
			_gate_done(loc);
		} else if (!ready[i].cached && data->get_free_slot_count() > 0) {
			// Rejected with a slot available means the body itself is bad. Never
			// re-request it, pool pressure alone retries fine
			_mark_failed(loc, true);
		}
	}
	// How far is the nearest wanted region that is not visible yet? Staged and cached regions are not.
	_stat_nearest = -1.f;
	for (const KeyValue<Vector2i, Want> &kv : wanted) {
		if (kv.value.cache_only || kv.value.behind || data->has_region(kv.key)) {
			continue;
		}
		const Vector2 rmin = Vector2(kv.key) * span;
		const real_t d = Math::sqrt(_rect_point_dist2(rmin, rmin + V2(span), fpos));
		_stat_nearest = _stat_nearest < 0.f ? d : MIN(_stat_nearest, d);
	}
	// Request missing regions within the keep set in load order. Every pending body
	// inside the map window claims a slot on insertion, so never keep more of those in
	// flight than free slots can absorb. Bodies for spots beyond the window only take IO.
	int slot_pending = 0;
	for (const KeyValue<Vector2i, String> &kv : _pending) {
		const Want *w = wanted.getptr(kv.key);
		if (data->get_region_map_index(kv.key) >= 0 && !deferred.has(kv.key) && (w == nullptr || !w->cache_only)) {
			slot_pending++;
		}
	}
	for (const KeyValue<Vector2i, Gated> &kv : _gated) {
		slot_pending += kv.value.seen == _gate_step ? 1 : 0; // A body waiting for the gate will need a slot too
	}
	int io_free = _concurrent_loads - (int)_pending.size();
	int slot_free = data->get_free_slot_count() - slot_pending;
	if (!keep_active && MIN(io_free, slot_free) <= 0) {
		_collision_flush();
		return;
	}
	Vector<Want> cands;
	for (const KeyValue<Vector2i, Want> &kv : wanted) {
		const Vector2i &loc = kv.key;
		if (kv.value.lazy || resident.has(loc) || data->has_region(loc) || _is_failed(loc) || _pending.has(loc) ||
				_staged_set.has(loc) || _saving.has(loc)) {
			continue;
		}
		cands.push_back(kv.value);
	}
	cands.sort_custom<WantSort>();
	// Bodies only fetched ahead of a path's reach never delay what is needed: one load slot stays free
	// for the path while any needed region is still unrequested
	int cache_pending = 0;
	for (const KeyValue<Vector2i, String> &kv : _pending) {
		const Want *w = wanted.getptr(kv.key);
		cache_pending += (w != nullptr && w->cache_only) ? 1 : 0;
	}
	int near_unrequested = 0;
	for (int i = 0; i < cands.size(); i++) {
		if (!keep_active && MIN(io_free, slot_free) <= 0) {
			break;
		}
		Vector2i loc = cands[i].loc;
		// A region the pool cannot hold yet loads its body into the cache like one beyond the window,
		// unless it lies behind the direction of travel
		const bool in_win = data->get_region_map_index(loc) >= 0 && !deferred.has(loc) && !cands[i].cache_only;
		if (!in_win && cands[i].behind) {
			continue;
		}
		if (cands[i].cache_only && near_unrequested > 0 && cache_pending >= _concurrent_loads - 1) {
			continue;
		}
		if (_ram_cache.has(loc)) {
			// Cached body (RAM mode revisit or a prefetch for a keep shape): it is already
			// decoded, only the GPU upload remains. Still bounded by loads_per_frame.
			// With an insert gate the ones inside the window were handled with the landings above
			if (gating && in_win) {
				continue;
			}
			if (!in_win || !_can_insert(inserted, worked, start_us) || data->get_free_slot_count() <= 0) {
				continue;
			}
			Ref<Terrain3DRegion> region = _ram_cache[loc];
			_ram_cache.erase(loc);
			region->set_location(loc);
			if (_insert(data, region, start_us, worked)) {
				inserted += 1;
			}
			continue;
		}
		if (io_free <= 0 || (in_win && slot_free <= 0)) {
			near_unrequested += cands[i].cache_only ? 0 : 1;
			continue;
		}
		if (!in_win && _mode == DISK && (int)_ram_cache.size() + (int)_pending.size() - slot_pending >= _keep_cache_limit) {
			// Prefetch beyond the window is capped in DISK mode. A needed body takes the place of the
			// farthest one fetched ahead of a path's reach
			bool made_room = false;
			if (!cands[i].cache_only) {
				Vector2i victim;
				real_t far_rank = -1.f;
				for (const KeyValue<Vector2i, Ref<Terrain3DRegion>> &kv : _ram_cache) {
					const Want *w = wanted.getptr(kv.key);
					if (w != nullptr && w->cache_only && w->rank > far_rank) {
						far_rank = w->rank;
						victim = kv.key;
					}
				}
				if (far_rank >= 0.f) {
					_ram_cache.erase(victim);
					made_room = true;
				}
			}
			if (!made_room) {
				continue;
			}
		}
		Error err = _request_load(loc, dir);
		if (err == ERR_BUSY) {
			continue; // A shared file is already loading for another location
		}
		if (err != OK) {
			_mark_failed(loc);
			continue;
		}
		cache_pending += cands[i].cache_only ? 1 : 0;
		io_free--;
		if (in_win) {
			slot_free--;
		}
	}
	// RAM mode: spend leftover load budget prefetching the rest of the world into
	// the cache, so revisits and far teleports never touch the disk again
	if (_mode == RAM) {
		int budget = keep_active ? io_free : MIN(io_free, slot_free);
		while (budget > 0 && _prefetch_cursor < _known.size()) {
			Vector2i loc = _known[_prefetch_cursor];
			_prefetch_cursor++;
			if (data->has_region(loc) || _ram_cache.has(loc) || _is_failed(loc) || _pending.has(loc) || _staged_set.has(loc)) {
				continue;
			}
			Error err = _request_load(loc, dir);
			if (err == ERR_BUSY) {
				_prefetch_cursor--; // Retry once the shared file has landed
				break;
			}
			if (err != OK) {
				_mark_failed(loc);
				continue;
			}
			budget--;
		}
	}
	_collision_flush();
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
	d["staged"] = (int)_staged.size();
	d["saving"] = (int)_saving.size();
	d["keep_shapes"] = _keep.size();
	d["wanted"] = _stat_wanted; // Known regions inside the keep set
	d["missing"] = _stat_missing; // Wanted, inside the map window and not resident yet
	d["deferred"] = _stat_deferred; // Wanted but the slot pool cannot hold them
	d["outside_window"] = _stat_outside; // Wanted but beyond the region map window
	d["collision_refreshes"] = (int64_t)_stat_collision; // Dynamic collision refreshes this streamer asked for
	d["disk_loads_needed"] = (int64_t)_stat_disk_needed; // Threaded loads consumed for regions needed now (not cached ahead of a path's reach, not RAM cache inserts)
	d["recentres"] = (int64_t)_stat_recentres; // Window moves so far
	d["nearest_missing"] = _stat_nearest; // Meters to the nearest wanted region not visible yet, not behind the target, -1 if none
	int gated = 0;
	uint64_t wait_max = _stat_gate_wait_max;
	const uint64_t now = Time::get_singleton()->get_ticks_msec();
	for (const KeyValue<Vector2i, Gated> &kv : _gated) {
		gated += kv.value.held ? 1 : 0;
		wait_max = MAX(wait_max, now - kv.value.since);
	}
	d["generating"] = (int)_lazy.size(); // Pending locations: registered, file not written yet
	d["generating_wanted"] = _stat_generating_wanted; // Of those, wanted now and needed (not behind the direction of travel, not only fetched ahead of a path's reach)
	d["gated"] = gated; // Loaded regions the insert gate holds back now
	d["gate_timeouts"] = (int64_t)_stat_gate_timeouts; // Regions inserted anyway after gate_timeout_ms
	d["gate_wait_ms_max"] = (int64_t)wait_max; // Longest time the gate held a region, waiting now or inserted since
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

// Keep shapes live on the XZ plane in world units, independent of region size and vertex spacing
static Vector2 _xz(const Vector3 &p_v) {
	return Vector2(p_v.x, p_v.z);
}

static real_t _rect_point_dist2(const Vector2 &p_min, const Vector2 &p_max, const Vector2 &p_point) {
	return (p_point - p_point.clamp(p_min, p_max)).length_squared();
}

static real_t _point_segment_dist2(const Vector2 &p_point, const Vector2 &p_a, const Vector2 &p_b) {
	Vector2 ab = p_b - p_a;
	real_t len2 = ab.length_squared();
	real_t t = len2 > 0.f ? CLAMP((p_point - p_a).dot(ab) / len2, 0.f, 1.f) : 0.f;
	return (p_point - (p_a + ab * t)).length_squared();
}

// Liang-Barsky clip of the segment against the rectangle. r_t0 and r_t1 receive the parameters of
// the part inside (0 at p_a, 1 at p_b).
static bool _segment_clip(const Vector2 &p_a, const Vector2 &p_b, const Vector2 &p_min, const Vector2 &p_max, real_t *r_t0 = nullptr, real_t *r_t1 = nullptr) {
	Vector2 d = p_b - p_a;
	real_t t0 = 0.f;
	real_t t1 = 1.f;
	const real_t p[4] = { -d.x, d.x, -d.y, d.y };
	const real_t q[4] = { p_a.x - p_min.x, p_max.x - p_a.x, p_a.y - p_min.y, p_max.y - p_a.y };
	for (int i = 0; i < 4; i++) {
		if (p[i] == 0.f) {
			if (q[i] < 0.f) {
				return false;
			}
			continue;
		}
		real_t t = q[i] / p[i];
		if (p[i] < 0.f) {
			t0 = MAX(t0, t);
		} else {
			t1 = MIN(t1, t);
		}
		if (t0 > t1) {
			return false;
		}
	}
	if (r_t0 != nullptr) {
		*r_t0 = t0;
	}
	if (r_t1 != nullptr) {
		*r_t1 = t1;
	}
	return true;
}

static bool _segment_hits_rect(const Vector2 &p_a, const Vector2 &p_b, const Vector2 &p_min, const Vector2 &p_max) {
	return _segment_clip(p_a, p_b, p_min, p_max);
}

real_t Terrain3DStreamer::_region_span() const {
	return _terrain != nullptr ? real_t((int)_terrain->get_region_size()) * _terrain->get_vertex_spacing() : 1.f;
}

// Is a region inside the focus area or any keep shape? Retaining adds the hysteresis band
// of one region to every shape; wanting is the strict union that loads.
bool Terrain3DStreamer::_is_kept(const Vector2i &p_region_loc, const bool p_retain, const bool p_cache) const {
	if (_camera_scale > 0.f && (p_retain ? _is_retained(p_region_loc) : _is_wanted(p_region_loc))) {
		return true;
	}
	const real_t expand = p_retain ? _region_span() : 0.f;
	for (int i = 0; i < _keep.size(); i++) {
		if (_shape_hit(_keep[i], p_region_loc, expand, nullptr, p_cache)) {
			return true;
		}
	}
	return false;
}

// Does a keep shape touch a region? Circles and path corridors are exact against the
// region's footprint. A cone is an ellipse half grown by half a region, so it keeps every
// region it overlaps and the one around its origin. r_rank receives the load rank: the
// distance from the shape's anchor in regions, or the distance along the path.
// Is a path arc position past how far ahead of the target the path loads (or, for the cache, prefetches)?
bool Terrain3DStreamer::_beyond_reach(const KeepShape &p_shape, const real_t p_arc, const bool p_cache) const {
	if (p_shape.ahead < 0.f) {
		return false;
	}
	real_t reach = p_shape.ahead;
	if (p_cache) {
		reach = p_shape.prefetch < 0.f ? INFINITY : MAX(reach, p_shape.prefetch);
	}
	return p_arc > p_shape.cam_arc + reach + _region_span() * 0.5f;
}

bool Terrain3DStreamer::_shape_hit(const KeepShape &p_shape, const Vector2i &p_region_loc, const real_t p_expand, real_t *r_rank, const bool p_cache) const {
	if (p_shape.type == KeepShape::PATH) {
		bool hit = false;
		real_t best = INFINITY;
		for (int i = 0; i + 1 < p_shape.points.size(); i++) {
			real_t arc = 0.f;
			if (_segment_hit(p_shape, i, p_region_loc, p_expand, &arc) && !_beyond_reach(p_shape, arc, p_cache)) {
				hit = true;
				best = MIN(best, arc);
			}
		}
		if (hit && r_rank != nullptr) {
			*r_rank = best;
		}
		return hit;
	}
	const real_t span = _region_span();
	const Vector2 rmin = Vector2(p_region_loc) * span;
	const Vector2 rmax = rmin + V2(span);
	const Vector2 center = rmin + V2(span * 0.5f);
	if (!p_shape.destination && _cut_behind(p_region_loc)) {
		return false;
	}
	if (r_rank != nullptr) {
		*r_rank = (center - p_shape.point).length() / span;
	}
	if (p_shape.type == KeepShape::CIRCLE) {
		const real_t r = p_shape.radius + p_expand;
		return _rect_point_dist2(rmin, rmax, p_shape.point) <= r * r;
	}
	// Cone: the region around the origin always counts, otherwise an ellipse half ahead
	// and a smaller one behind, both grown by half a region
	if (_rect_point_dist2(rmin, rmax, p_shape.point) == 0.f) {
		return true;
	}
	const Vector2 q = center - p_shape.point;
	const real_t a = q.dot(p_shape.dir);
	const real_t b = q.dot(Vector2(-p_shape.dir.y, p_shape.dir.x));
	const real_t grow = span * 0.5f + p_expand;
	const real_t ax = (a >= 0.f ? p_shape.length : p_shape.behind) + grow;
	const real_t bx = p_shape.radius + grow;
	return (a * a) / (ax * ax) + (b * b) / (bx * bx) <= 1.f;
}

// Does one path segment's corridor touch a region? r_arc receives the distance along the
// polyline of the point closest to the region's center.
bool Terrain3DStreamer::_segment_hit(const KeepShape &p_shape, const int p_index, const Vector2i &p_region_loc, const real_t p_expand, real_t *r_arc) const {
	const real_t span = _region_span();
	const Vector2 rmin = Vector2(p_region_loc) * span;
	const Vector2 rmax = rmin + V2(span);
	const Vector2 a = p_shape.points[p_index];
	const Vector2 b = p_shape.points[p_index + 1];
	real_t d2 = 0.f;
	if (!_segment_hits_rect(a, b, rmin, rmax)) {
		d2 = MIN(_rect_point_dist2(rmin, rmax, a), _rect_point_dist2(rmin, rmax, b));
		const Vector2 corners[4] = { rmin, Vector2(rmax.x, rmin.y), rmax, Vector2(rmin.x, rmax.y) };
		for (int i = 0; i < 4; i++) {
			d2 = MIN(d2, _point_segment_dist2(corners[i], a, b));
		}
	}
	const real_t r = p_shape.radius + p_expand;
	if (d2 > r * r) {
		return false;
	}
	if (r_arc != nullptr || _behind_limit >= 0.f) {
		const Vector2 ab = b - a;
		const real_t len2 = ab.length_squared();
		const real_t t = len2 > 0.f ? CLAMP((rmin + V2(span * 0.5f) - a).dot(ab) / len2, 0.f, 1.f) : 0.f;
		const real_t arc = p_shape.arc[p_index] + t * Math::sqrt(len2);
		if (_behind_limit >= 0.f && p_shape.id != 0 && (arc < p_shape.cam_arc - _behind_limit - span * 0.5f || _cut_behind(p_region_loc))) {
			return false; // Further behind the target than behind_limit, by arc or in the plane (the path's start cap)
		}
		if (r_arc != nullptr) {
			*r_arc = arc;
		}
	}
	return true;
}

// Distance along the path of the point closest to p_point
real_t Terrain3DStreamer::_arc_of(const KeepShape &p_shape, const Vector2 &p_point, Vector2 *r_dir) const {
	real_t best = INFINITY;
	real_t arc = 0.f;
	for (int i = 0; i + 1 < p_shape.points.size(); i++) {
		const Vector2 a = p_shape.points[i];
		const Vector2 ab = p_shape.points[i + 1] - a;
		const real_t len2 = ab.length_squared();
		const real_t t = len2 > 0.f ? CLAMP((p_point - a).dot(ab) / len2, 0.f, 1.f) : 0.f;
		const real_t d2 = (p_point - (a + ab * t)).length_squared();
		if (d2 < best) {
			best = d2;
			arc = p_shape.arc[i] + t * Math::sqrt(len2);
			if (r_dir != nullptr && len2 > 0.f) {
				*r_dir = ab / Math::sqrt(len2);
			}
		}
	}
	return arc;
}

// Finds the direction of travel of the keep set: the tangent of the first path at the clipmap
// target (the target's arc position is also stored on every path), else the first cone's
// direction. Without either there is no direction and nothing counts as behind.
void Terrain3DStreamer::_update_axis() {
	_has_axis = false;
	for (int i = 0; i < _keep.size(); i++) {
		KeepShape &s = _keep.write[i];
		if (s.type == KeepShape::PATH) {
			Vector2 dir;
			s.cam_arc = _arc_of(s, _focus_pos, _has_axis ? nullptr : &dir);
			if (!_has_axis && dir.length_squared() > 0.f) {
				_axis = dir;
				_has_axis = true;
			}
		}
	}
	for (int i = 0; i < _keep.size() && !_has_axis; i++) {
		if (_keep[i].type == KeepShape::CONE) {
			_axis = _keep[i].dir;
			_has_axis = true;
		}
	}
}

// Is a region beyond behind_limit from the clipmap target, against the direction of travel?
// Used by every shape and the target's own area, so nothing keeps what the camera left behind.
// Destination shapes skip it, and the target's own region is never cut.
bool Terrain3DStreamer::_cut_behind(const Vector2i &p_region_loc) const {
	if (_behind_limit < 0.f || !_has_axis || p_region_loc == _focus_loc) {
		return false;
	}
	const real_t span = _region_span();
	const Vector2 center = (Vector2(p_region_loc) + V2(0.5f)) * span;
	return (center - _focus_pos).dot(_axis) < -(_behind_limit + span * 0.5f);
}

// Is a region's center more than half a region behind the clipmap target along the axis?
// The target's own region never is.
bool Terrain3DStreamer::_is_behind(const Vector2i &p_region_loc) const {
	if (!_has_axis || p_region_loc == _focus_loc) {
		return false;
	}
	const real_t span = _region_span();
	const Vector2 center = (Vector2(p_region_loc) + V2(0.5f)) * span;
	return (center - _focus_pos).dot(_axis) < -span * 0.5f;
}

Terrain3DStreamer::KeepShape *Terrain3DStreamer::_find_keep(const int p_id, const KeepShape::Type p_type) {
	for (int i = 0; i < _keep.size(); i++) {
		if (_keep[i].id == p_id) {
			return _keep[i].type == p_type ? &_keep.write[i] : nullptr;
		}
	}
	return nullptr;
}

// Every region a path corridor touches, with the arc positions where the path enters (x) and leaves
// (y) the region grown by the corridor radius. A conservative box: the entry can be early at a corner.
void Terrain3DStreamer::_path_regions(const KeepShape &p_shape, HashMap<Vector2i, Vector2> &r_arcs) const {
	const real_t span = _region_span();
	for (int i = 0; i + 1 < p_shape.points.size(); i++) {
		const Vector2 a = p_shape.points[i];
		const Vector2 b = p_shape.points[i + 1];
		const real_t len = (b - a).length();
		const Vector2 lo = a.min(b) - V2(p_shape.radius);
		const Vector2 hi = a.max(b) + V2(p_shape.radius);
		const Vector2i c0 = Vector2i((lo / span).floor());
		const Vector2i c1 = Vector2i((hi / span).floor());
		for (int y = c0.y; y <= c1.y; y++) {
			for (int x = c0.x; x <= c1.x; x++) {
				const Vector2i loc(x, y);
				if (!_segment_hit(p_shape, i, loc, 0.f, nullptr)) {
					continue;
				}
				const Vector2 rmin = Vector2(loc) * span - V2(p_shape.radius);
				real_t t0 = 0.f;
				real_t t1 = 1.f;
				if (!_segment_clip(a, b, rmin, rmin + V2(span + 2.f * p_shape.radius), &t0, &t1)) {
					continue;
				}
				const Vector2 range = Vector2(p_shape.arc[i] + t0 * len, p_shape.arc[i] + t1 * len);
				Vector2 *known = r_arcs.getptr(loc);
				if (known == nullptr) {
					r_arcs[loc] = range;
				} else {
					known->x = MIN(known->x, range.x);
					known->y = MAX(known->y, range.y);
				}
			}
		}
	}
}

// Meters along a path, from the clipmap target's position on it (or from p_from_distance), until
// the first region it needs that is not visible yet, or to the end of the path when all are.
// A region counts only once it is inserted: cached and staged regions are not visible.
real_t Terrain3DStreamer::get_path_ready_distance(const int p_id, const real_t p_from_distance) const {
	const KeepShape *shape = nullptr;
	for (int i = 0; i < _keep.size(); i++) {
		if (_keep[i].id == p_id && _keep[i].type == KeepShape::PATH) {
			shape = &_keep[i];
		}
	}
	Terrain3DData *data = _terrain != nullptr ? _terrain->get_data() : nullptr;
	ERR_FAIL_COND_V_MSG(shape == nullptr, -1.f, "Unknown keep path id");
	ERR_FAIL_NULL_V(data, -1.f);
	const real_t total = shape->arc[shape->arc.size() - 1];
	const real_t from = p_from_distance >= 0.f ? MIN(p_from_distance, total) : _arc_of(*shape, _xz(_terrain->get_clipmap_target_position()));
	HashMap<Vector2i, Vector2> regions;
	_path_regions(*shape, regions);
	real_t ready = total - from;
	for (const KeyValue<Vector2i, Vector2> &kv : regions) {
		if (kv.value.y < from || !(_known_set.has(kv.key) || _lazy.has(kv.key)) || data->has_region(kv.key)) {
			continue; // Behind, no file (a pending location will have one), or visible
		}
		const uint64_t *until = _failed.getptr(kv.key);
		if (until != nullptr && *until == UINT64_MAX) {
			continue; // Given up on: it will never load
		}
		ready = MIN(ready, MAX(kv.value.x - from, 0.f));
	}
	return ready;
}

// What a corridor around a polyline costs to hold: the regions with a file that it touches, the raw
// bytes of their bodies (what the RAM cache holds per region) and how many are beyond the region
// map window now, so they can only be cached until the window reaches them.
Dictionary Terrain3DStreamer::get_path_cost(const PackedVector3Array &p_points, const real_t p_radius) const {
	Dictionary d;
	ERR_FAIL_COND_V_MSG(p_points.size() < 2, d, "A path needs at least two points");
	Terrain3DData *data = _terrain != nullptr ? _terrain->get_data() : nullptr;
	KeepShape shape;
	shape.type = KeepShape::PATH;
	shape.radius = MAX(p_radius, 0.f);
	_set_path(shape, p_points);
	HashMap<Vector2i, Vector2> regions;
	_path_regions(shape, regions);
	int known = 0;
	int outside = 0;
	int generating = 0;
	for (const KeyValue<Vector2i, Vector2> &kv : regions) {
		generating += _lazy.has(kv.key) ? 1 : 0;
		if (_known_set.has(kv.key)) {
			known++;
			outside += (data != nullptr && data->get_region_map_index(kv.key) < 0) ? 1 : 0;
		}
	}
	const int64_t size = _terrain != nullptr ? (int)_terrain->get_region_size() : 0;
	const int64_t maps = (_terrain != nullptr && !_terrain->get_color_map_enabled()) ? 2 : 3;
	const int64_t region_bytes = size * size * 4 * maps; // Height, control and color are 4 bytes a vertex
	d["length"] = shape.arc[shape.arc.size() - 1];
	d["cells"] = (int)regions.size();
	d["regions"] = known;
	d["region_bytes"] = region_bytes;
	d["bytes"] = region_bytes * known;
	d["outside_window"] = outside;
	d["generating"] = generating; // Pending locations on the path, not in regions: no file yet
	return d;
}

void Terrain3DStreamer::_set_path(KeepShape &p_shape, const PackedVector3Array &p_points) const {
	p_shape.points.clear();
	p_shape.arc.clear();
	real_t arc = 0.f;
	for (int i = 0; i < p_points.size(); i++) {
		const Vector2 p = _xz(p_points[i]);
		if (i > 0) {
			arc += (p - p_shape.points[i - 1]).length();
		}
		p_shape.points.push_back(p);
		p_shape.arc.push_back(arc);
	}
}

// Scales the clipmap target's own area, in regions: distance * scale. Callers shrink it a
// step per frame to release the area behind them gradually. Zero removes the area.
void Terrain3DStreamer::set_camera_scale(const real_t p_scale) {
	real_t scale = CLAMP(p_scale, 0.f, 1.f);
	if (scale < _camera_scale) {
		_keep_dirty = true;
	}
	_camera_scale = scale;
}

// Nothing is kept further than p_distance behind the clipmap target, against the direction of
// travel (see _update_axis). Lowering it evicts what it cuts at once, like a shrinking shape.
void Terrain3DStreamer::set_behind_limit(const real_t p_distance) {
	const real_t limit = p_distance < 0.f ? -1.f : p_distance;
	if (limit >= 0.f && (_behind_limit < 0.f || limit < _behind_limit)) {
		_keep_dirty = true;
	}
	_behind_limit = limit;
}

int Terrain3DStreamer::add_keep_circle(const Vector3 &p_center, const real_t p_radius, const bool p_destination) {
	KeepShape s;
	s.id = _next_keep_id++;
	s.type = KeepShape::CIRCLE;
	s.destination = p_destination;
	s.point = _xz(p_center);
	s.radius = MAX(p_radius, 0.f);
	_keep.push_back(s);
	return s.id;
}

int Terrain3DStreamer::add_keep_path(const PackedVector3Array &p_points, const real_t p_radius) {
	ERR_FAIL_COND_V_MSG(p_points.size() < 2, 0, "A keep path needs at least two points");
	KeepShape s;
	s.id = _next_keep_id++;
	s.type = KeepShape::PATH;
	s.radius = MAX(p_radius, 0.f);
	_set_path(s, p_points);
	_keep.push_back(s);
	return s.id;
}

int Terrain3DStreamer::add_keep_cone(const Vector3 &p_origin, const Vector3 &p_direction, const real_t p_length,
		const real_t p_half_width, const real_t p_behind, const bool p_destination) {
	KeepShape s;
	s.id = _next_keep_id++;
	s.type = KeepShape::CONE;
	s.destination = p_destination;
	s.point = _xz(p_origin);
	Vector2 dir = _xz(p_direction);
	s.dir = dir.length_squared() > 1e-12f ? dir.normalized() : Vector2(0.f, -1.f);
	s.length = MAX(p_length, 0.f);
	s.radius = MAX(p_half_width, 0.f);
	s.behind = MAX(p_behind, 0.f);
	_keep.push_back(s);
	return s.id;
}

// The set_keep_*() updates move a shape in place, e.g. every frame with the camera. A shape
// that gets smaller marks the keep set dirty, so regions it no longer covers evict now;
// moving or growing one leaves the usual one region of hysteresis.
bool Terrain3DStreamer::set_keep_circle(const int p_id, const Vector3 &p_center, const real_t p_radius) {
	KeepShape *s = _find_keep(p_id, KeepShape::CIRCLE);
	if (s == nullptr) {
		return false;
	}
	real_t radius = MAX(p_radius, 0.f);
	_keep_dirty |= radius < s->radius;
	s->point = _xz(p_center);
	s->radius = radius;
	return true;
}

bool Terrain3DStreamer::set_keep_path(const int p_id, const PackedVector3Array &p_points, const real_t p_radius) {
	KeepShape *s = _find_keep(p_id, KeepShape::PATH);
	if (s == nullptr) {
		return false;
	}
	ERR_FAIL_COND_V_MSG(p_points.size() < 2, false, "A keep path needs at least two points");
	real_t radius = MAX(p_radius, 0.f);
	_keep_dirty |= radius < s->radius || p_points.size() < s->points.size();
	s->radius = radius;
	_set_path(*s, p_points);
	return true;
}

bool Terrain3DStreamer::set_keep_cone(const int p_id, const Vector3 &p_origin, const Vector3 &p_direction, const real_t p_length,
		const real_t p_half_width, const real_t p_behind) {
	KeepShape *s = _find_keep(p_id, KeepShape::CONE);
	if (s == nullptr) {
		return false;
	}
	real_t length = MAX(p_length, 0.f);
	real_t half_width = MAX(p_half_width, 0.f);
	real_t behind = MAX(p_behind, 0.f);
	_keep_dirty |= length < s->length || half_width < s->radius || behind < s->behind;
	s->point = _xz(p_origin);
	Vector2 dir = _xz(p_direction);
	s->dir = dir.length_squared() > 1e-12f ? dir.normalized() : s->dir;
	s->length = length;
	s->radius = half_width;
	s->behind = behind;
	return true;
}

// How far ahead of the clipmap target along the path it loads: regions further than p_ahead meters are not
// wanted, so they take no slot, load order or stat. p_prefetch reaches further, for region bodies only (the
// RAM cache), requested after everything needed and never using the last load slot while one is waiting;
// negative means to the end of the path. A negative p_ahead restores the whole path.
bool Terrain3DStreamer::set_keep_path_ahead(const int p_id, const real_t p_ahead, const real_t p_prefetch) {
	KeepShape *s = _find_keep(p_id, KeepShape::PATH);
	if (s == nullptr) {
		return false;
	}
	s->ahead = p_ahead < 0.f ? -1.f : p_ahead;
	s->prefetch = p_prefetch;
	return true;
}

// The regions the last step wanted: those needed now, or (cache_only) only fetched ahead as bodies
TypedArray<Vector2i> Terrain3DStreamer::get_wanted_regions(const bool p_cache_only) const {
	TypedArray<Vector2i> out;
	const Vector<Vector2i> &src = p_cache_only ? _wanted_cache : _wanted_near;
	for (int i = 0; i < src.size(); i++) {
		out.push_back(src[i]);
	}
	return out;
}

// The regions with a threaded load in flight, and those whose body waits in the RAM cache
TypedArray<Vector2i> Terrain3DStreamer::get_pending_regions() const {
	TypedArray<Vector2i> out;
	for (const KeyValue<Vector2i, String> &kv : _pending) {
		out.push_back(kv.key);
	}
	return out;
}

TypedArray<Vector2i> Terrain3DStreamer::get_cached_regions() const {
	TypedArray<Vector2i> out;
	for (const KeyValue<Vector2i, Ref<Terrain3DRegion>> &kv : _ram_cache) {
		out.push_back(kv.key);
	}
	return out;
}

// Removing a shape evicts what only it kept at the next step, without hysteresis
void Terrain3DStreamer::remove_keep(const int p_id) {
	for (int i = 0; i < _keep.size(); i++) {
		if (_keep[i].id == p_id) {
			_keep.remove_at(i);
			_keep_dirty = true;
			return;
		}
	}
}

// Removes every shape and restores the clipmap target's full area
void Terrain3DStreamer::clear_keep() {
	_keep_dirty |= !_keep.is_empty() || _camera_scale != 1.f;
	_keep.clear();
	_camera_scale = 1.f;
}

// A region is wanted (loaded) within distance of the focus, and retained (kept once loaded)
// within one more region of hysteresis so it does not thrash at the edge
bool Terrain3DStreamer::_is_wanted(const Vector2i &p_region_loc) const {
	return _distance_to(p_region_loc, _focus_loc) <= real_t(_distance) * _camera_scale && !_cut_behind(p_region_loc);
}

bool Terrain3DStreamer::_is_retained(const Vector2i &p_region_loc) const {
	return _distance_to(p_region_loc, _focus_loc) <= real_t(_distance) * _camera_scale + 1.f && !_cut_behind(p_region_loc);
}

// Hands an evicted body to a worker thread. A body with edits is saved first when
// persist_edits is on; releasing it there keeps freeing its images off the main thread.
void Terrain3DStreamer::_retire(const Vector2i &p_region_loc, const Ref<Terrain3DRegion> &p_region, const String &p_dir) {
	RetireJob *job = memnew(RetireJob);
	job->region = p_region;
	job->loc = p_region_loc;
	// A pending location's file belongs to the game's generator: never write a base file for it
	if (_persist_edits && !p_dir.is_empty() && p_region->is_modified() && !p_region->is_read_only() && !_lazy.has(p_region_loc)) {
		job->path = _file_path(p_region_loc, p_dir);
		job->save_16_bit = _terrain->get_save_16_bit();
		_saving.insert(p_region_loc);
	}
	job->task = WorkerThreadPool::get_singleton()->add_task(
			callable_mp(this, &Terrain3DStreamer::_run_retire_job).bind(int64_t(job)), false, "Terrain3D retire region");
	_retiring.push_back(job);
}

// Runs on a worker thread. The job is owned by _retiring until its task is awaited.
void Terrain3DStreamer::_run_retire_job(const int64_t p_job) {
	RetireJob *job = reinterpret_cast<RetireJob *>(p_job);
	if (!job->path.is_empty()) {
		Error err = job->region->save(job->path, job->save_16_bit);
		if (err != OK && err != ERR_SKIP) {
			LOG(ERROR, "Could not save evicted region ", job->loc, " to ", job->path, ", error: ", err);
		}
	}
	job->region.unref();
}

// Collects finished retire jobs, or all of them when p_wait is set
void Terrain3DStreamer::_poll_retiring(const bool p_wait) {
	for (int i = 0; i < _retiring.size();) {
		RetireJob *job = _retiring[i];
		if (!p_wait && !WorkerThreadPool::get_singleton()->is_task_completed(job->task)) {
			i++;
			continue;
		}
		WorkerThreadPool::get_singleton()->wait_for_task_completion(job->task);
		_saving.erase(job->loc);
		memdelete(job);
		_retiring.remove_at(i);
	}
}

// True once this physics frame has spent its frame_budget_ms. Always false when the
// budget is 0, which leaves loads_per_frame as the only limit.
bool Terrain3DStreamer::_budget_spent(const uint64_t p_start_us) const {
	return _frame_budget_ms > 0.f &&
			real_t(Time::get_singleton()->get_ticks_usec() - p_start_us) * 0.001f >= _frame_budget_ms;
}

// Another region may start inserting: under a time budget one at a time while the budget
// lasts, otherwise up to loads_per_frame per frame
bool Terrain3DStreamer::_can_insert(const int p_inserted, const bool p_worked, const uint64_t p_start_us) const {
	if (_frame_budget_ms > 0.f) {
		return _staged.is_empty() && !(p_worked && _budget_spent(p_start_us));
	}
	return p_inserted < _loads_per_frame;
}

// Asks the insert gate whether a region may become visible. The first refusal starts its clock; once
// gate_timeout_ms has passed the region is let through without asking and counted in gate_timeouts.
bool Terrain3DStreamer::_gate_open(const Vector2i &p_region_loc) {
	const uint64_t now = Time::get_singleton()->get_ticks_msec();
	Gated *g = _gated.getptr(p_region_loc);
	if (g != nullptr && g->timed_out) {
		return true;
	}
	if (g != nullptr && _gate_timeout_ms > 0 && now - g->since >= uint64_t(_gate_timeout_ms)) {
		g->timed_out = true;
		g->held = false;
		_stat_gate_timeouts += 1;
		return true;
	}
	bool open = true;
	if (_insert_gate.is_valid()) {
		Variant answer = _insert_gate.call(p_region_loc);
		open = answer.get_type() != Variant::BOOL || bool(answer); // Only a plain false holds a region
	}
	if (g == nullptr && !open) {
		Gated gated;
		gated.since = now;
		gated.seen = _gate_step;
		g = &(_gated[p_region_loc] = gated);
	}
	if (g != nullptr) {
		g->held = !open;
	}
	return open;
}

// A region the gate held became visible: records how long it waited
void Terrain3DStreamer::_gate_done(const Vector2i &p_region_loc) {
	const Gated *g = _gated.getptr(p_region_loc);
	if (g != nullptr) {
		_stat_gate_wait_max = MAX(_stat_gate_wait_max, Time::get_singleton()->get_ticks_msec() - g->since);
		_gated.erase(p_region_loc);
	}
}

// Bookkeeping once a region is resident
void Terrain3DStreamer::_land(const Vector2i &p_region_loc, const real_t p_ms) {
	uint64_t t0 = Time::get_singleton()->get_ticks_usec();
	_collision_refresh(p_region_loc);
	real_t ms = p_ms + real_t(Time::get_singleton()->get_ticks_usec() - t0) * 0.001f;
	_landed_total += 1;
	_land_ms_avg = _land_ms_avg == 0.f ? ms : _land_ms_avg * 0.9f + ms * 0.1f;
}

// Inserts a loaded body: all at once, or reserved here and uploaded over the next
// frames when a time budget is set. Returns false when the data rejected it.
bool Terrain3DStreamer::_insert(Terrain3DData *p_data, const Ref<Terrain3DRegion> &p_region, const uint64_t p_start_us, bool &r_worked) {
	uint64_t t0 = Time::get_singleton()->get_ticks_usec();
	Vector2i loc = p_region->get_location();
	if (_frame_budget_ms <= 0.f) {
		if (p_data->add_region_streamed(p_region) != OK) {
			return false;
		}
		_land(loc, real_t(Time::get_singleton()->get_ticks_usec() - t0) * 0.001f);
		r_worked = true;
		return true;
	}
	Staged staged;
	staged.region = p_region;
	if (p_data->reserve_region_streamed(p_region, staged.slot) != OK) {
		return false;
	}
	if (staged.slot < 0) {
		return true; // Already resident
	}
	staged.ms = real_t(Time::get_singleton()->get_ticks_usec() - t0) * 0.001f;
	_staged.push_back(staged);
	_staged_set.insert(loc);
	r_worked = true;
	_advance_staged(p_data, p_start_us, r_worked);
	return true;
}

// Uploads the next layer of the oldest staged region, or makes it visible after the last
// one, until the frame budget is spent. Runs at least one step when called with nothing done yet.
void Terrain3DStreamer::_advance_staged(Terrain3DData *p_data, const uint64_t p_start_us, bool &r_worked) {
	while (!_staged.is_empty()) {
		if (r_worked && _budget_spent(p_start_us)) {
			return;
		}
		uint64_t t0 = Time::get_singleton()->get_ticks_usec();
		Staged &s = _staged.write[0];
		Vector2i loc = s.region->get_location();
		if (s.step < TYPE_MAX) {
			p_data->upload_region_streamed(s.region, s.slot, MapType(s.step));
			s.step += 1;
			s.ms += real_t(Time::get_singleton()->get_ticks_usec() - t0) * 0.001f;
		} else {
			if (p_data->commit_region_streamed(s.region, s.slot) == OK) {
				_land(loc, s.ms + real_t(Time::get_singleton()->get_ticks_usec() - t0) * 0.001f);
			}
			_staged_set.erase(loc);
			_staged.remove_at(0);
		}
		r_worked = true;
	}
}

// The file of a location: the path it was written with, else the data directory's own name for it
String Terrain3DStreamer::_file_path(const Vector2i &p_loc, const String &p_dir) const {
	const String *path = _paths.getptr(p_loc);
	return path != nullptr ? *path : p_dir + String("/") + Util::location_to_filename(p_loc);
}

// Starts a threaded load for a location, asking the resolver (if set) which file to use.
// Returns ERR_BUSY if the file is already loading for another location: a threaded load
// can be consumed only once, so shared files load one location at a time.
Error Terrain3DStreamer::_request_load(const Vector2i &p_loc, const String &p_dir) {
	String path = _file_path(p_loc, p_dir);
	Resolved info;
	bool has_info = false;
	if (_resolver.is_valid()) {
		Variant result = _resolver.call(p_loc);
		Dictionary dict = result.get_type() == Variant::DICTIONARY ? Dictionary(result) : Dictionary();
		String rpath = dict.get("path", String());
		if (!rpath.is_empty()) {
			path = rpath;
			info.rotation = int(dict.get("rotation", 0)) & 3;
			info.mirror = bool(dict.get("mirror", false));
			info.read_only = bool(dict.get("read_only", false));
			has_info = true;
		}
	}
	for (const KeyValue<Vector2i, String> &kv : _pending) {
		if (kv.value == path) {
			return ERR_BUSY;
		}
	}
	Error err = ResourceLoader::get_singleton()->load_threaded_request(
			path, "Terrain3DRegion", false, ResourceLoader::CACHE_MODE_IGNORE);
	if (err != OK) {
		LOG(ERROR, "Streaming load request failed for ", path, ": ", err);
		return err;
	}
	_pending[p_loc] = path;
	if (has_info) {
		_resolved[p_loc] = info;
	}
	return OK;
}

// Prepares a loaded body for insertion at its requested location. Resolved bodies get
// their mirror and rotation here, on the main thread: ResourceLoader's threaded load
// offers no hook to run code on the loader thread.
void Terrain3DStreamer::_finish_body(const Ref<Terrain3DRegion> &p_region, const Vector2i &p_loc, const String &p_path) {
	if (_resolved.has(p_loc)) {
		const Resolved &info = _resolved[p_loc];
		p_region->transform_maps(info.rotation, info.mirror);
		p_region->set_read_only(info.read_only);
		if (!info.read_only) {
			p_region->take_over_path(p_path);
		}
	} else {
		p_region->take_over_path(p_path);
	}
	p_region->set_location(p_loc);
}

// A failed load may be transient (file busy, a copy still in progress), so it is requested again after a
// delay. After FAIL_RETRIES failures, or at once if the body itself is bad, it is ignored until a rescan.
void Terrain3DStreamer::_mark_failed(const Vector2i &p_region_loc, const bool p_give_up) {
	int count = _fail_count.has(p_region_loc) ? _fail_count[p_region_loc] + 1 : 1;
	_fail_count[p_region_loc] = count;
	bool permanent = p_give_up || count >= FAIL_RETRIES;
	_failed[p_region_loc] = permanent ? UINT64_MAX : Time::get_singleton()->get_ticks_msec() + FAIL_RETRY_MSEC;
}

bool Terrain3DStreamer::_is_failed(const Vector2i &p_region_loc) const {
	const uint64_t *until = _failed.getptr(p_region_loc);
	return until != nullptr && Time::get_singleton()->get_ticks_msec() < *until;
}

// A streamed insertion only matters to collision when the region can intersect the
// dynamic window around the collision target. A forced update() refills shape data in
// place; build() would destroy and recreate the physics body under the player.
// The refresh itself runs once per step, see _collision_flush().
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
		_collision_dirty = true;
	}
}

// Refreshes the dynamic collision once for every region that landed this step. A forced update
// costs about 25 ms whatever the region size, and a region corner can touch up to four landings.
void Terrain3DStreamer::_collision_flush() {
	if (!_collision_dirty) {
		return;
	}
	_collision_dirty = false;
	Terrain3DCollision *collision = _terrain->get_collision();
	if (collision != nullptr && collision->is_enabled() && collision->is_dynamic_mode()) {
		collision->update(V2I_MAX, true);
		_stat_collision += 1;
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
	ClassDB::bind_method(D_METHOD("set_persist_edits", "enabled"), &Terrain3DStreamer::set_persist_edits);
	ClassDB::bind_method(D_METHOD("get_persist_edits"), &Terrain3DStreamer::get_persist_edits);
	ClassDB::bind_method(D_METHOD("set_camera_scale", "scale"), &Terrain3DStreamer::set_camera_scale);
	ClassDB::bind_method(D_METHOD("get_camera_scale"), &Terrain3DStreamer::get_camera_scale);
	ClassDB::bind_method(D_METHOD("set_keep_cache_limit", "limit"), &Terrain3DStreamer::set_keep_cache_limit);
	ClassDB::bind_method(D_METHOD("get_keep_cache_limit"), &Terrain3DStreamer::get_keep_cache_limit);
	ClassDB::bind_method(D_METHOD("set_behind_limit", "distance"), &Terrain3DStreamer::set_behind_limit);
	ClassDB::bind_method(D_METHOD("get_behind_limit"), &Terrain3DStreamer::get_behind_limit);
	ClassDB::bind_method(D_METHOD("add_keep_circle", "center", "radius", "destination"), &Terrain3DStreamer::add_keep_circle, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("add_keep_path", "points", "radius"), &Terrain3DStreamer::add_keep_path);
	ClassDB::bind_method(D_METHOD("add_keep_cone", "origin", "direction", "length", "half_width", "behind", "destination"),
			&Terrain3DStreamer::add_keep_cone, DEFVAL(0.f), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("set_keep_circle", "id", "center", "radius"), &Terrain3DStreamer::set_keep_circle);
	ClassDB::bind_method(D_METHOD("set_keep_path", "id", "points", "radius"), &Terrain3DStreamer::set_keep_path);
	ClassDB::bind_method(D_METHOD("set_keep_cone", "id", "origin", "direction", "length", "half_width", "behind"),
			&Terrain3DStreamer::set_keep_cone, DEFVAL(0.f));
	ClassDB::bind_method(D_METHOD("get_path_ready_distance", "id", "from_distance"), &Terrain3DStreamer::get_path_ready_distance, DEFVAL(-1.f));
	ClassDB::bind_method(D_METHOD("get_path_cost", "points", "radius"), &Terrain3DStreamer::get_path_cost);
	ClassDB::bind_method(D_METHOD("set_keep_path_ahead", "id", "ahead", "prefetch"), &Terrain3DStreamer::set_keep_path_ahead, DEFVAL(0.f));
	ClassDB::bind_method(D_METHOD("get_wanted_regions", "cache_only"), &Terrain3DStreamer::get_wanted_regions, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("get_pending_regions"), &Terrain3DStreamer::get_pending_regions);
	ClassDB::bind_method(D_METHOD("get_cached_regions"), &Terrain3DStreamer::get_cached_regions);
	ClassDB::bind_method(D_METHOD("remove_keep", "id"), &Terrain3DStreamer::remove_keep);
	ClassDB::bind_method(D_METHOD("clear_keep"), &Terrain3DStreamer::clear_keep);
	ClassDB::bind_method(D_METHOD("get_keep_count"), &Terrain3DStreamer::get_keep_count);
	ClassDB::bind_method(D_METHOD("set_insert_gate", "gate"), &Terrain3DStreamer::set_insert_gate);
	ClassDB::bind_method(D_METHOD("get_insert_gate"), &Terrain3DStreamer::get_insert_gate);
	ClassDB::bind_method(D_METHOD("set_gate_timeout_ms", "ms"), &Terrain3DStreamer::set_gate_timeout_ms);
	ClassDB::bind_method(D_METHOD("get_gate_timeout_ms"), &Terrain3DStreamer::get_gate_timeout_ms);
	ClassDB::bind_method(D_METHOD("get_gated_regions"), &Terrain3DStreamer::get_gated_regions);
	ClassDB::bind_method(D_METHOD("set_resolver", "resolver"), &Terrain3DStreamer::set_resolver);
	ClassDB::bind_method(D_METHOD("get_resolver"), &Terrain3DStreamer::get_resolver);
	ClassDB::bind_method(D_METHOD("register_virtual_locations", "locations"), &Terrain3DStreamer::register_virtual_locations);
	ClassDB::bind_method(D_METHOD("clear_virtual_locations"), &Terrain3DStreamer::clear_virtual_locations);
	ClassDB::bind_method(D_METHOD("register_pending_locations", "locations"), &Terrain3DStreamer::register_pending_locations);
	ClassDB::bind_method(D_METHOD("clear_pending_locations"), &Terrain3DStreamer::clear_pending_locations);
	ClassDB::bind_method(D_METHOD("get_pending_locations"), &Terrain3DStreamer::get_pending_locations);
	ClassDB::bind_method(D_METHOD("get_wanted_pending", "max"), &Terrain3DStreamer::get_wanted_pending, DEFVAL(64));
	ClassDB::bind_method(D_METHOD("notify_region_written", "location", "path"), &Terrain3DStreamer::notify_region_written, DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("notify_regions_written", "locations"), &Terrain3DStreamer::notify_regions_written);
	ClassDB::bind_method(D_METHOD("get_required_slots", "distance"), &Terrain3DStreamer::get_required_slots);
	ClassDB::bind_method(D_METHOD("get_max_distance"), &Terrain3DStreamer::get_max_distance);
	ClassDB::bind_method(D_METHOD("scan_directory"), &Terrain3DStreamer::scan_directory);
	ClassDB::bind_method(D_METHOD("abort_pending"), &Terrain3DStreamer::abort_pending);
	ClassDB::bind_method(D_METHOD("step"), &Terrain3DStreamer::step);
	ClassDB::bind_method(D_METHOD("get_stats"), &Terrain3DStreamer::get_stats);

	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enabled"), "set_enabled", "is_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "shape", PROPERTY_HINT_ENUM, "Square,Circle"), "set_shape", "get_shape");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mode", PROPERTY_HINT_ENUM, "Disk,RAM Resident"), "set_mode", "get_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "slots", PROPERTY_HINT_RANGE, "25,1024,1"), "set_slots", "get_slots");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "distance", PROPERTY_HINT_RANGE, "1,15,1"), "set_distance", "get_distance");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "concurrent_loads", PROPERTY_HINT_RANGE, "1,8,1"), "set_concurrent_loads", "get_concurrent_loads");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "loads_per_frame", PROPERTY_HINT_RANGE, "1,8,1"), "set_loads_per_frame", "get_loads_per_frame");
	ADD_PROPERTY(PropertyInfo(Variant::CALLABLE, "resolver", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_resolver", "get_resolver");
	ADD_PROPERTY(PropertyInfo(Variant::CALLABLE, "insert_gate", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_insert_gate", "get_insert_gate");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "gate_timeout_ms", PROPERTY_HINT_RANGE, "0,3600000,1,or_greater,suffix:ms"), "set_gate_timeout_ms", "get_gate_timeout_ms");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "persist_edits"), "set_persist_edits", "get_persist_edits");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "camera_scale", PROPERTY_HINT_RANGE, "0,1,0.01"), "set_camera_scale", "get_camera_scale");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "keep_cache_limit", PROPERTY_HINT_RANGE, "0,4096,1"), "set_keep_cache_limit", "get_keep_cache_limit");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "behind_limit", PROPERTY_HINT_RANGE, "-1,100000,1,or_greater,suffix:m"), "set_behind_limit", "get_behind_limit");
}
