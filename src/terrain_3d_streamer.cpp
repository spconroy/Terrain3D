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
			if (kv.value.is_valid() && kv.value->is_modified()) {
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
	// Staged regions hold pool slots of the data being torn down or rebuilt
	_staged.clear();
	_staged_set.clear();
	_poll_retiring(true);
}

// Scans the data directory for region locations. Only file names are read, nothing is loaded.
void Terrain3DStreamer::scan_directory() {
	IS_INIT(VOID);
	_known.clear();
	_known_set.clear();
	_failed.clear();
	_fail_count.clear();
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
		if (Terrain3DData::get_region_map_index(loc) < 0) {
			// A body cannot keep a location outside the 32x32 region map: it would land
			// at the wrong place and be evicted again every frame, starving real loads
			LOG(WARN, "Streaming scan: ignoring ", fname, ", location ", loc, " is outside the world");
			continue;
		}
		_known.push_back(loc);
		_known_set.insert(loc);
	}
	LOG(INFO, "Streaming scan: ", _known.size(), " regions on disk at ", dir);
}

// Runs the streaming state machine once per physics frame: evict regions that fell
// outside the loaded area, insert completed loads, and request missing regions.
// IO runs wide (concurrent_loads threaded loads decompress at once) while
// insertions stay narrow (frame_budget_ms of main thread time per physics frame, or
// loads_per_frame whole regions when the budget is 0), since the texture layer
// uploads and signal cascade are the main thread cost that hitches.
void Terrain3DStreamer::step() {
	uint64_t s0 = Time::get_singleton()->get_ticks_usec();
	_tick_upload_us = 0;
	_tick_reserve_us = 0;
	_tick_land_us = 0;
	_step_impl();
	_last_step_us = Time::get_singleton()->get_ticks_usec() - s0;
}

void Terrain3DStreamer::_step_impl() {
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
	uint64_t start_us = Time::get_singleton()->get_ticks_usec();
	_poll_retiring(false);
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
		if (i > 0 && _budget_spent(start_us)) {
			break;
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
	}
	// Drop staged regions that fell out of range before they became visible
	for (int i = _staged.size() - 1; i >= 0; i--) {
		Vector2i loc = _staged[i].region->get_location();
		if (_distance_to(loc, floc) > real_t(_distance + 1)) {
			if (_mode == RAM) {
				_ram_cache[loc] = _staged[i].region;
			}
			data->release_slot_streamed(_staged[i].slot);
			_staged_set.erase(loc);
			_staged.remove_at(i);
		}
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
			// Consume the failed task. The loader pins it otherwise, and a later request for the path would
			// only report the old failure instead of reading the file again
			ResourceLoader::get_singleton()->load_threaded_get(kv.value);
			_mark_failed(kv.key);
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
	bool worked = false;
	_ready_left = ready.size();
	_advance_staged(data, start_us, worked); // Finish a region begun on an earlier frame first
	for (int i = 0; i < ready.size(); i++) {
		if (!_can_insert(inserted, worked, start_us)) {
			break;
		}
		_ready_left = ready.size() - i - 1;
		Ref<Terrain3DRegion> region = ResourceLoader::get_singleton()->load_threaded_get(ready[i].path);
		_pending.erase(ready[i].loc);
		if (region.is_null()) {
			LOG(ERROR, "Streaming load returned null region ", ready[i].loc);
			_mark_failed(ready[i].loc);
			continue;
		}
		region->take_over_path(ready[i].path);
		region->set_location(ready[i].loc);
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
					_is_failed(loc) || _pending.has(loc) || _staged_set.has(loc) || _saving.has(loc)) {
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
			if (!_can_insert(inserted, worked, start_us) || data->get_free_slot_count() <= 0) {
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
		String path = dir + String("/") + Util::location_to_filename(loc);
		Error err = ResourceLoader::get_singleton()->load_threaded_request(
				path, "Terrain3DRegion", false, ResourceLoader::CACHE_MODE_IGNORE);
		if (err != OK) {
			LOG(ERROR, "Streaming load request failed for ", path, ": ", err);
			_mark_failed(loc);
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
			if (data->has_region(loc) || _ram_cache.has(loc) || _is_failed(loc) || _pending.has(loc) || _staged_set.has(loc)) {
				continue;
			}
			String path = dir + String("/") + Util::location_to_filename(loc);
			Error err = ResourceLoader::get_singleton()->load_threaded_request(
					path, "Terrain3DRegion", false, ResourceLoader::CACHE_MODE_IGNORE);
			if (err != OK) {
				_mark_failed(loc);
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
	d["staged"] = (int)_staged.size();
	d["saving"] = (int)_saving.size();
	d["commits_total"] = (int64_t)_commits_total;
	d["last_commit_us"] = Array::make((int64_t)Terrain3DData::_bench_last[0], (int64_t)Terrain3DData::_bench_last[1], (int64_t)Terrain3DData::_bench_last[2], (int64_t)Terrain3DData::_bench_last[3], (int64_t)Terrain3DData::_bench_last[4], (int64_t)Terrain3DData::_bench_last[5]);
	d["last_commit_total_us"] = (int64_t)_last_commit_total_us;
	d["last_step_us"] = (int64_t)_last_step_us;
	d["tick_parts_us"] = Array::make((int64_t)_tick_upload_us, (int64_t)_tick_reserve_us, (int64_t)_tick_land_us);
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

// Hands an evicted body to a worker thread. A body with edits is saved first when
// persist_edits is on; releasing it there keeps freeing its images off the main thread.
void Terrain3DStreamer::_retire(const Vector2i &p_region_loc, const Ref<Terrain3DRegion> &p_region, const String &p_dir) {
	RetireJob *job = memnew(RetireJob);
	job->region = p_region;
	job->loc = p_region_loc;
	if (_persist_edits && !p_dir.is_empty() && p_region->is_modified()) {
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
		return _staged.size() < _bench_batch && !(p_worked && _budget_spent(p_start_us));
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
	if (_frame_budget_ms <= 0.f && _bench_batch <= 1) {
		if (p_data->add_region_streamed(p_region) != OK) {
			return false;
		}
		_land(loc, real_t(Time::get_singleton()->get_ticks_usec() - t0) * 0.001f);
		r_worked = true;
		return true;
	}
	Staged staged;
	staged.region = p_region;
	Error rerr = p_data->reserve_region_streamed(p_region, staged.slot);
	_tick_reserve_us += Time::get_singleton()->get_ticks_usec() - t0;
	if (rerr != OK) {
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
		int next = -1;
		for (int i = 0; i < _staged.size(); i++) {
			if (_staged[i].step < TYPE_MAX) {
				next = i;
				break;
			}
		}
		if (next >= 0) {
			Staged &s = _staged.write[next];
			p_data->upload_region_streamed(s.region, s.slot, MapType(s.step));
			_tick_upload_us += Time::get_singleton()->get_ticks_usec() - t0;
			s.step += 1;
			s.ms += real_t(Time::get_singleton()->get_ticks_usec() - t0) * 0.001f;
		} else {
			// Everything staged is uploaded. Wait for a full batch while more loaded bodies are queued
			if (_staged.size() < _bench_batch && _ready_left > 0) {
				return;
			}
			Vector<Ref<Terrain3DRegion>> regs;
			Vector<int> slots;
			real_t ms = 0.f;
			for (int i = 0; i < _staged.size(); i++) {
				regs.push_back(_staged[i].region);
				slots.push_back(_staged[i].slot);
				ms = MAX(ms, _staged[i].ms);
			}
			Error cerr = p_data->commit_regions_streamed(regs, slots);
			_last_commit_total_us = Time::get_singleton()->get_ticks_usec() - t0;
			if (cerr == OK) {
				_commits_total += 1;
				real_t each = ms + real_t(Time::get_singleton()->get_ticks_usec() - t0) * 0.001f;
				uint64_t l0 = Time::get_singleton()->get_ticks_usec();
				_land_batch(regs, each);
				_tick_land_us += Time::get_singleton()->get_ticks_usec() - l0;
			}
			for (int i = 0; i < regs.size(); i++) {
				_staged_set.erase(regs[i]->get_location());
			}
			_staged.clear();
		}
		r_worked = true;
	}
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

bool Terrain3DStreamer::_collision_intersects(const Vector2i &p_region_loc) {
	Terrain3DCollision *collision = _terrain->get_collision();
	if (collision == nullptr || !collision->is_enabled() || !collision->is_dynamic_mode()) {
		return false;
	}
	Vector3 t = _terrain->get_collision_target_position();
	Vector2 tp = Vector2(t.x, t.z) / _terrain->get_vertex_spacing(); // Descaled, like the window grid
	real_t rs = real_t((int)_terrain->get_region_size());
	Vector2 rmin = Vector2(p_region_loc) * rs;
	Vector2 cp = tp.clamp(rmin, rmin + Vector2(rs, rs));
	real_t d = MAX(ABS(cp.x - tp.x), ABS(cp.y - tp.y));
	return d <= real_t(collision->get_radius()) + real_t(collision->get_shape_size());
}

void Terrain3DStreamer::_collision_refresh(const Vector2i &p_region_loc) {
	if (_collision_intersects(p_region_loc)) {
		_terrain->get_collision()->update(V2I_MAX, true);
	}
}

// SCRATCH: bookkeeping for a batch of regions made resident together, one collision refresh for all
void Terrain3DStreamer::_land_batch(const Vector<Ref<Terrain3DRegion>> &p_regions, const real_t p_ms) {
	if (p_regions.size() == 1 || !_bench_coalesce_collision) {
		for (int i = 0; i < p_regions.size(); i++) {
			_land(p_regions[i]->get_location(), p_ms);
		}
		return;
	}
	uint64_t t0 = Time::get_singleton()->get_ticks_usec();
	bool refresh = false;
	for (int i = 0; i < p_regions.size(); i++) {
		refresh = refresh || _collision_intersects(p_regions[i]->get_location());
	}
	if (refresh) {
		_terrain->get_collision()->update(V2I_MAX, true);
	}
	real_t ms = p_ms + real_t(Time::get_singleton()->get_ticks_usec() - t0) * 0.001f;
	for (int i = 0; i < p_regions.size(); i++) {
		_landed_total += 1;
		_land_ms_avg = _land_ms_avg == 0.f ? ms : _land_ms_avg * 0.9f + ms * 0.1f;
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
	ClassDB::bind_method(D_METHOD("set_bench_batch", "n"), &Terrain3DStreamer::set_bench_batch);
	ClassDB::bind_method(D_METHOD("get_bench_batch"), &Terrain3DStreamer::get_bench_batch);
	ClassDB::bind_method(D_METHOD("set_bench_coalesce_collision", "on"), &Terrain3DStreamer::set_bench_coalesce_collision);
	ClassDB::bind_method(D_METHOD("set_persist_edits", "enabled"), &Terrain3DStreamer::set_persist_edits);
	ClassDB::bind_method(D_METHOD("get_persist_edits"), &Terrain3DStreamer::get_persist_edits);
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
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "persist_edits"), "set_persist_edits", "get_persist_edits");
}
