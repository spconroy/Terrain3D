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
			if (kv.value.is_valid() && kv.value->is_modified() && !kv.value->is_read_only()) {
				String path = _terrain->get_data_directory() + String("/") + Util::location_to_filename(kv.key);
				kv.value->save(path, _terrain->get_save_16_bit());
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
	_resolved.clear();
	_discard.clear();
	// Staged regions hold pool slots of the data being torn down or rebuilt
	_staged.clear();
	_staged_set.clear();
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
	for (const Vector2i &loc : _virtual) {
		_known.push_back(loc);
		_known_set.insert(loc);
	}
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
	LOG(INFO, "Streaming scan: ", _known.size(), " regions on disk at ", dir);
}

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
	// Region locations are unbounded, the region map window is not. Recentre it on the
	// focus whenever the retained area (distance + 1, see eviction below) leaves it.
	// Regions left outside are beyond the retained area, so they evict below. Keep shapes
	// never move the window: only the part of them inside it is inserted, the rest waits
	// in the body cache until the window reaches it.
	const int retained = _distance + 1;
	const Vector2i origin = data->get_region_map_origin();
	const int window = data->get_region_map_size();
	if (floc.x - retained < origin.x || floc.y - retained < origin.y ||
			floc.x + retained >= origin.x + window || floc.y + retained >= origin.y + window) {
		data->set_region_map_origin(floc - V2I(window / 2));
	}
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
	const bool keep_active = _keep_active();
	const real_t span = _region_span();
	uint64_t start_us = Time::get_singleton()->get_ticks_usec();
	_poll_retiring(false);

	// Collect the wanted set: every known region inside the keep set, with its load order.
	// Order is (tier, rank): destination shapes first, then paths in order of arrival from the
	// target, then everything else nearest first with ties broken toward the travel direction.
	struct Want {
		Vector2i loc;
		int tier = 2;
		real_t rank = 0.f;
		real_t ahead = 0.f;
		real_t cam_d = 0.f;
	};
	struct WantSort {
		bool operator()(const Want &a, const Want &b) const {
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
	HashMap<Vector2i, Want> wanted;
	auto add_want = [&](const Vector2i &p_loc, int p_tier, real_t p_rank, real_t p_ahead) {
		if (!_known_set.has(p_loc) || _is_failed(p_loc)) {
			return;
		}
		Want w;
		w.loc = p_loc;
		w.tier = p_tier;
		w.rank = p_rank;
		w.ahead = p_ahead;
		w.cam_d = _distance_to(p_loc, floc);
		if (wanted.has(p_loc) && !WantSort()(w, wanted[p_loc])) {
			return;
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
				add_want(loc, 2, d, ahead);
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
							// Ahead of the target first, in order along the path; behind last
							real_t rank = arc >= cam_arc ? arc - cam_arc : 1e9f + (cam_arc - arc);
							add_want(Vector2i(x, y), tier, rank, 0.f);
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
					add_want(Vector2i(x, y), tier, rank, 0.f);
				}
			}
		}
	}
	// Split by the region map window; only regions inside it can take a slot
	Vector<Want> in_window;
	int outside = 0;
	for (const KeyValue<Vector2i, Want> &kv : wanted) {
		if (data->get_region_map_index(kv.key) >= 0) {
			in_window.push_back(kv.value);
		} else {
			outside++;
		}
	}
	// A pool smaller than the union keeps the regions nearest the target and defers the rest
	HashSet<Vector2i> deferred;
	if (keep_active && in_window.size() > data->get_slot_capacity()) {
		in_window.sort_custom<CamSort>();
		for (int i = data->get_slot_capacity(); i < in_window.size(); i++) {
			deferred.insert(in_window[i].loc);
		}
	}
	_stat_wanted = (int)wanted.size();
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
		_stat_missing = missing;
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
		_stat_missing = 0;
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
			if (!_is_kept(kv.key, false)) {
				_discard.insert(kv.key);
			}
		}
	}
	_keep_dirty = false;
	if (_mode == DISK && !_ram_cache.is_empty()) {
		// Prefetched bodies of keep shapes drop once nothing keeps them
		Vector<Vector2i> unkept;
		for (const KeyValue<Vector2i, Ref<Terrain3DRegion>> &kv : _ram_cache) {
			if (!_is_kept(kv.key, true)) {
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
		int tier = 2;
		real_t rank = 0.f;
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
		const bool kept = !_discard.has(kv.key) && _is_kept(kv.key, true);
		if (!kept || data->get_region_map_index(kv.key) < 0) {
			// Walked away while it loaded, or loaded for a spot beyond the map window:
			// consume, and keep the body in RAM mode or while a keep shape still wants it
			Ref<Terrain3DRegion> body = ResourceLoader::get_singleton()->load_threaded_get(kv.value);
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
	struct LandingSort {
		bool operator()(const Landing &a, const Landing &b) const {
			if (a.tier != b.tier) {
				return a.tier < b.tier;
			}
			return a.rank < b.rank;
		}
	};
	ready.sort_custom<LandingSort>();
	int inserted = 0;
	bool worked = false;
	_advance_staged(data, start_us, worked); // Finish a region begun on an earlier frame first
	for (int i = 0; i < ready.size(); i++) {
		if (!_can_insert(inserted, worked, start_us)) {
			break;
		}
		Ref<Terrain3DRegion> region = ResourceLoader::get_singleton()->load_threaded_get(ready[i].path);
		_pending.erase(ready[i].loc);
		if (region.is_null()) {
			_resolved.erase(ready[i].loc);
			LOG(ERROR, "Streaming load returned null region ", ready[i].loc);
			_mark_failed(ready[i].loc);
			continue;
		}
		_finish_body(region, ready[i].loc, ready[i].path);
		_resolved.erase(ready[i].loc);
		// Loading runs the setters, which flag the region modified. Reset it like load_directory
		// does; otherwise persist_edits would rewrite every region it evicts. The on disk version is
		// left alone: streaming is read only, and a save stamps the current version itself
		region->set_modified(false);
		if (_insert(data, region, start_us, worked)) {
			inserted += 1;
		} else if (data->get_free_slot_count() > 0) {
			// Rejected with a slot available means the body itself is bad. Never
			// re-request it, pool pressure alone retries fine
			_mark_failed(ready[i].loc, true);
		}
	}
	// Request missing regions within the keep set in load order. Every pending body
	// inside the map window claims a slot on insertion, so never keep more of those in
	// flight than free slots can absorb. Bodies for spots beyond the window only take IO.
	int slot_pending = 0;
	for (const KeyValue<Vector2i, String> &kv : _pending) {
		if (data->get_region_map_index(kv.key) >= 0) {
			slot_pending++;
		}
	}
	int io_free = _concurrent_loads - (int)_pending.size();
	int slot_free = data->get_free_slot_count() - slot_pending;
	if (!keep_active && MIN(io_free, slot_free) <= 0) {
		return;
	}
	Vector<Want> cands;
	for (const KeyValue<Vector2i, Want> &kv : wanted) {
		const Vector2i &loc = kv.key;
		if (resident.has(loc) || data->has_region(loc) || _is_failed(loc) || _pending.has(loc) || deferred.has(loc) ||
				_staged_set.has(loc) || _saving.has(loc)) {
			continue;
		}
		cands.push_back(kv.value);
	}
	cands.sort_custom<WantSort>();
	for (int i = 0; i < cands.size(); i++) {
		if (!keep_active && MIN(io_free, slot_free) <= 0) {
			break;
		}
		Vector2i loc = cands[i].loc;
		const bool in_win = data->get_region_map_index(loc) >= 0;
		if (_ram_cache.has(loc)) {
			// Cached body (RAM mode revisit or a prefetch for a keep shape): it is already
			// decoded, only the GPU upload remains. Still bounded by loads_per_frame
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
			continue;
		}
		if (!in_win && _mode == DISK && (int)_ram_cache.size() + (int)_pending.size() - slot_pending >= _keep_cache_limit) {
			continue; // Prefetch beyond the window is capped in DISK mode
		}
		Error err = _request_load(loc, dir);
		if (err == ERR_BUSY) {
			continue; // A shared file is already loading for another location
		}
		if (err != OK) {
			_mark_failed(loc);
			continue;
		}
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

// Liang-Barsky clip of the segment against the rectangle
static bool _segment_hits_rect(const Vector2 &p_a, const Vector2 &p_b, const Vector2 &p_min, const Vector2 &p_max) {
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
	return true;
}

real_t Terrain3DStreamer::_region_span() const {
	return _terrain != nullptr ? real_t((int)_terrain->get_region_size()) * _terrain->get_vertex_spacing() : 1.f;
}

// Is a region inside the focus area or any keep shape? Retaining adds the hysteresis band
// of one region to every shape; wanting is the strict union that loads.
bool Terrain3DStreamer::_is_kept(const Vector2i &p_region_loc, const bool p_retain) const {
	if (_camera_scale > 0.f && (p_retain ? _is_retained(p_region_loc) : _is_wanted(p_region_loc))) {
		return true;
	}
	const real_t expand = p_retain ? _region_span() : 0.f;
	for (int i = 0; i < _keep.size(); i++) {
		if (_shape_hit(_keep[i], p_region_loc, expand, nullptr)) {
			return true;
		}
	}
	return false;
}

// Does a keep shape touch a region? Circles and path corridors are exact against the
// region's footprint. A cone is an ellipse half grown by half a region, so it keeps every
// region it overlaps and the one around its origin. r_rank receives the load rank: the
// distance from the shape's anchor in regions, or the distance along the path.
bool Terrain3DStreamer::_shape_hit(const KeepShape &p_shape, const Vector2i &p_region_loc, const real_t p_expand, real_t *r_rank) const {
	if (p_shape.type == KeepShape::PATH) {
		bool hit = false;
		real_t best = INFINITY;
		for (int i = 0; i + 1 < p_shape.points.size(); i++) {
			real_t arc = 0.f;
			if (_segment_hit(p_shape, i, p_region_loc, p_expand, &arc)) {
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
	if (r_arc != nullptr) {
		const Vector2 ab = b - a;
		const real_t len2 = ab.length_squared();
		const real_t t = len2 > 0.f ? CLAMP((rmin + V2(span * 0.5f) - a).dot(ab) / len2, 0.f, 1.f) : 0.f;
		const real_t arc = p_shape.arc[p_index] + t * Math::sqrt(len2);
		*r_arc = arc;
	}
	return true;
}

// Distance along the path of the point closest to p_point
real_t Terrain3DStreamer::_arc_of(const KeepShape &p_shape, const Vector2 &p_point) const {
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
		}
	}
	return arc;
}

Terrain3DStreamer::KeepShape *Terrain3DStreamer::_find_keep(const int p_id, const KeepShape::Type p_type) {
	for (int i = 0; i < _keep.size(); i++) {
		if (_keep[i].id == p_id) {
			return _keep[i].type == p_type ? &_keep.write[i] : nullptr;
		}
	}
	return nullptr;
}

void Terrain3DStreamer::_set_path(KeepShape &p_shape, const PackedVector3Array &p_points) {
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
	return _distance_to(p_region_loc, _focus_loc) <= real_t(_distance) * _camera_scale;
}

bool Terrain3DStreamer::_is_retained(const Vector2i &p_region_loc) const {
	return _distance_to(p_region_loc, _focus_loc) <= real_t(_distance) * _camera_scale + 1.f;
}

// Hands an evicted body to a worker thread. A body with edits is saved first when
// persist_edits is on; releasing it there keeps freeing its images off the main thread.
void Terrain3DStreamer::_retire(const Vector2i &p_region_loc, const Ref<Terrain3DRegion> &p_region, const String &p_dir) {
	RetireJob *job = memnew(RetireJob);
	job->region = p_region;
	job->loc = p_region_loc;
	if (_persist_edits && !p_dir.is_empty() && p_region->is_modified() && !p_region->is_read_only()) {
		job->path = p_dir + String("/") + Util::location_to_filename(p_region_loc);
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

// Starts a threaded load for a location, asking the resolver (if set) which file to use.
// Returns ERR_BUSY if the file is already loading for another location: a threaded load
// can be consumed only once, so shared files load one location at a time.
Error Terrain3DStreamer::_request_load(const Vector2i &p_loc, const String &p_dir) {
	String path = p_dir + String("/") + Util::location_to_filename(p_loc);
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

// A streamed insertion only matters to collision when the region can intersect the
// dynamic window around the collision target. A forced update() refills shape data in
// place; build() would destroy and recreate the physics body under the player.
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
	ClassDB::bind_method(D_METHOD("set_persist_edits", "enabled"), &Terrain3DStreamer::set_persist_edits);
	ClassDB::bind_method(D_METHOD("get_persist_edits"), &Terrain3DStreamer::get_persist_edits);
	ClassDB::bind_method(D_METHOD("set_camera_scale", "scale"), &Terrain3DStreamer::set_camera_scale);
	ClassDB::bind_method(D_METHOD("get_camera_scale"), &Terrain3DStreamer::get_camera_scale);
	ClassDB::bind_method(D_METHOD("set_keep_cache_limit", "limit"), &Terrain3DStreamer::set_keep_cache_limit);
	ClassDB::bind_method(D_METHOD("get_keep_cache_limit"), &Terrain3DStreamer::get_keep_cache_limit);
	ClassDB::bind_method(D_METHOD("add_keep_circle", "center", "radius", "destination"), &Terrain3DStreamer::add_keep_circle, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("add_keep_path", "points", "radius"), &Terrain3DStreamer::add_keep_path);
	ClassDB::bind_method(D_METHOD("add_keep_cone", "origin", "direction", "length", "half_width", "behind", "destination"),
			&Terrain3DStreamer::add_keep_cone, DEFVAL(0.f), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("set_keep_circle", "id", "center", "radius"), &Terrain3DStreamer::set_keep_circle);
	ClassDB::bind_method(D_METHOD("set_keep_path", "id", "points", "radius"), &Terrain3DStreamer::set_keep_path);
	ClassDB::bind_method(D_METHOD("set_keep_cone", "id", "origin", "direction", "length", "half_width", "behind"),
			&Terrain3DStreamer::set_keep_cone, DEFVAL(0.f));
	ClassDB::bind_method(D_METHOD("remove_keep", "id"), &Terrain3DStreamer::remove_keep);
	ClassDB::bind_method(D_METHOD("clear_keep"), &Terrain3DStreamer::clear_keep);
	ClassDB::bind_method(D_METHOD("get_keep_count"), &Terrain3DStreamer::get_keep_count);
	ClassDB::bind_method(D_METHOD("set_resolver", "resolver"), &Terrain3DStreamer::set_resolver);
	ClassDB::bind_method(D_METHOD("get_resolver"), &Terrain3DStreamer::get_resolver);
	ClassDB::bind_method(D_METHOD("register_virtual_locations", "locations"), &Terrain3DStreamer::register_virtual_locations);
	ClassDB::bind_method(D_METHOD("clear_virtual_locations"), &Terrain3DStreamer::clear_virtual_locations);
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
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "persist_edits"), "set_persist_edits", "get_persist_edits");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "camera_scale", PROPERTY_HINT_RANGE, "0,1,0.01"), "set_camera_scale", "get_camera_scale");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "keep_cache_limit", PROPERTY_HINT_RANGE, "0,4096,1"), "set_keep_cache_limit", "get_keep_cache_limit");
}
