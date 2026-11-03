extends SceneTree
## Headless lazy region generation flight: a fake background generator (worker threads that write region files with a
## delay, atomically through a temporary name and a rename) drives the real streamer through register_pending_locations,
## get_wanted_pending and notify_regions_written, while the reference governor (flight_governor.gd) flies a camera across an
## UNGENERATED corridor. The camera must slow instead of flying over regions that do not exist yet (get_path_ready_distance
## counts pending locations as missing), the governor must not read generation lag as a slow loader (observe_gate, with
## generating_wanted as the trigger and a generation ETA), no hole may ever show, the destination must be complete on arrival
## and the generator must work in the streamer's order.
##   godot --headless --path project --script res://tests/test_streaming_lazy_flight.gd [-- size=256 length=10000 gen=20 workers=1,2,4 only=text]
## The cruise cap follows the flight time budgets: v = d / (T - ramps), T(10 km) = 5 s, T(28 km) = 15 s, linear in between, at
## most 2.5 km/s. It is passed to the governor explicitly (auto_cap off).
const FlightGovernor := preload("res://tests/flight_governor.gd")
const RING_RADIUS := 1000.0
var _fail := 0
var _t: Terrain3D
var _root_dir := "user://lazy_flight_%d" % OS.get_process_id()
var _args := {}
var _master := ""
var _rows: Array[String] = []


## The game's background generator: workers take the first location of the priority list that nobody generated yet, spend
## gen_ms on it, and write the file atomically. Finished locations are handed to the main thread, which notifies the streamer.
class Generator:
	extends RefCounted
	var dir := ""
	var master := ""
	var gen_ms := 20
	var mutex := Mutex.new()
	var threads: Array[Thread] = []
	var list: Array = [] # Priority list, set by the main thread
	var claimed := {}
	var done: Array[Vector2i] = []
	var claim_order: Array[Vector2i] = []
	var written := 0
	var busy_ms := 0
	var stop := false

	func start(p_workers: int) -> void:
		for i in p_workers:
			var th := Thread.new()
			th.start(_work)
			threads.append(th)

	func set_list(p_list: Array) -> void:
		mutex.lock()
		list = p_list
		mutex.unlock()

	func take_done() -> Array[Vector2i]:
		mutex.lock()
		var out := done
		done = []
		mutex.unlock()
		return out

	func pending_work() -> int:
		mutex.lock()
		var n := 0
		for loc: Vector2i in list:
			n += 0 if claimed.has(loc) else 1
		mutex.unlock()
		return n

	func finish() -> void:
		stop = true
		for th in threads:
			th.wait_to_finish()
		threads.clear()

	func _work() -> void:
		while not stop:
			mutex.lock()
			var pick = null
			for i in list.size():
				var loc: Vector2i = list[i]
				if not claimed.has(loc):
					claimed[loc] = true
					pick = loc
					break
			if pick != null:
				claim_order.append(pick)
			mutex.unlock()
			if pick == null:
				OS.delay_msec(1)
				continue
			var t0 := Time.get_ticks_msec()
			OS.delay_msec(gen_ms) # The work of the generator
			var final := dir + "/" + Terrain3DUtil.location_to_filename(pick)
			var tmp := final + ".part"
			DirAccess.copy_absolute(master, tmp)
			DirAccess.rename_absolute(tmp, final) # Atomic: a reader sees all of the file or none
			mutex.lock()
			done.append(pick)
			written += 1
			busy_ms += Time.get_ticks_msec() - t0
			mutex.unlock()


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			_args[kv[0]] = kv[1]
	DirAccess.make_dir_recursive_absolute(_root_dir)
	process_frame.connect(_run)


func _frames(n: int) -> void:
	for i in n:
		await process_frame
		RenderingServer.emit_signal("frame_pre_draw")


func _clean(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + f)


func _write_master(path: String, rs: int) -> void:
	var r := Terrain3DRegion.new()
	r.set_location(Vector2i(0, 0))
	var noise := FastNoiseLite.new()
	noise.frequency = 0.01
	var h := noise.get_image(rs, rs)
	h.convert(Image.FORMAT_RF)
	var ctl := noise.get_image(rs, rs)
	ctl.convert(Image.FORMAT_RF)
	r.set_control_map(ctl)
	var col := Image.create_from_data(rs, rs, false, Image.FORMAT_RGBA8, Crypto.new().generate_random_bytes(rs * rs * 4))
	col.generate_mipmaps()
	r.set_color_map(col)
	r.set_height_map(h)
	r.set_modified(true)
	r.save(path)


func _ground(x: float) -> float:
	return 40.0 * (0.6 * sin(x / 1900.0 + 0.7) + 0.4 * sin(x / 760.0 + 2.1))


func _heights(length: float) -> PackedFloat32Array:
	var h := PackedFloat32Array()
	for i in int(length / 50.0) + 1:
		h.append(_ground(float(i) * 50.0))
	return h


func _pct(a: Array, p: float) -> float:
	if a.is_empty():
		return 0.0
	var b := a.duplicate()
	b.sort()
	return float(b[mini(int(float(b.size()) * p), b.size() - 1)])


## The world: every location the game has (rows around the route, from the start to past the destination)
func _world_cells(rs: int, length: float) -> Array[Vector2i]:
	var rows := 3 if rs == 512 else 5
	var x1 := int(length / rs) + 8
	var out: Array[Vector2i] = []
	for y in range(-rows, rows + 1):
		for x in range(-4, x1 + 1):
			out.append(Vector2i(x, y))
	return out


## The nominal cruise speed of a flight: d / (T - ramps) with T the time budget (5 s at 10 km, 15 s at 28 km, linear, constant outside)
## and the ramps of the jerk limited take-off and stop at the governor's acceleration; at most the 2.5 km/s hard cap
func _cruise_cap(length: float, g: FlightGovernor) -> float:
	var budget := 5.0 + 10.0 * clampf((length - 10000.0) / 18000.0, 0.0, 1.0)
	var v := length / budget
	for i in 8:
		var ramps := v / g.max_accel + g.max_accel / g.max_jerk
		v = length / maxf(budget - ramps, 0.5)
	return minf(v, 2500.0)


## Generates a list of locations with the fake generator and waits for it. Returns the wall seconds.
func _pregenerate(dir: String, locs: Array[Vector2i], workers: int, gen_ms: int) -> float:
	var gen := Generator.new()
	gen.dir = dir
	gen.master = _master
	gen.gen_ms = gen_ms
	gen.list = locs.duplicate()
	var t0 := Time.get_ticks_usec()
	gen.start(workers)
	while true:
		OS.delay_msec(2)
		gen.mutex.lock()
		var n := gen.written
		gen.mutex.unlock()
		if n >= locs.size():
			break
	gen.finish()
	return float(Time.get_ticks_usec() - t0) * 1e-6


func _new_terrain(dir: String, cfg: Dictionary) -> Camera3D:
	_t = Terrain3D.new()
	_t.streaming_enabled = true
	_t.streaming_slots = cfg.slots
	_t.streaming_distance = 2
	_t.streaming_frame_budget_ms = cfg.budget
	_t.streaming_concurrent_loads = cfg.conc
	_t.streaming_loads_per_frame = cfg.lpf
	_t.data_directory = dir
	root.add_child(_t)
	_t.collision_mode = Terrain3DCollision.DISABLED
	var cam := Camera3D.new()
	cam.far = 20000.0
	root.add_child(cam)
	_t.set_camera(cam)
	_t.set_clipmap_target(cam)
	await _frames(2)
	return cam


func _run() -> void:
	process_frame.disconnect(_run)
	var rs := int(_args.get("size", 256))
	var length := float(_args.get("length", 10000))
	var gen_ms := int(_args.get("gen", 20))
	var only: String = _args.get("only", "")
	var worker_list: Array = []
	for w in String(_args.get("workers", "1,2,4")).split(","):
		worker_list.append(int(w))
	_master = _root_dir + "/master.res"
	_write_master(_master, rs)
	# Time to first settle: only the camera area generated against a fully generated region map window
	if only == "" or only == "settle":
		await _settle_report(rs, gen_ms, worker_list.back())
	var base := {"rs": rs, "length": length, "conc": 3, "lpf": 1, "budget": 2.0, "slots": 400 if rs == 256 else 160, "gen_ms": gen_ms, "workers": 4,
			"lazy": true, "aware": true, "eta": true, "label": ""}
	var plan: Array = []
	var tag := "%d m %d km" % [rs, int(length / 1000.0)]
	plan.append(_cfg(base, "%s pre-generated corridor" % tag, {"lazy": false}))
	for wk: int in worker_list:
		plan.append(_cfg(base, "%s lazy, %d ms x %d workers, gate aware + eta" % [tag, gen_ms, wk], {"workers": wk}))
	plan.append(_cfg(base, "%s lazy, %d ms x %d workers, gate aware" % [tag, gen_ms, worker_list.back()], {"workers": worker_list.back(), "eta": false}))
	plan.append(_cfg(base, "%s lazy, %d ms x %d workers, governor unaware" % [tag, gen_ms, worker_list.back()], {"workers": worker_list.back(), "aware": false, "eta": false}))
	plan.append(_cfg(base, "%s lazy, %d ms x 1 workers, governor unaware" % [tag, gen_ms], {"workers": 1, "aware": false, "eta": false}))
	for cfg: Dictionary in plan:
		if only != "" and only != "settle" and cfg.label.find(only) < 0:
			continue
		if only == "settle":
			break
		var r: Dictionary = await _fly(cfg)
		_rows.append(r.row)
		print("ROW ", r.row)
	print("")
	print("LAZY FLIGHT SUMMARY")
	for row in _rows:
		print("  ", row)
	for sub in DirAccess.get_directories_at(_root_dir):
		_clean(_root_dir + "/" + sub)
		DirAccess.remove_absolute(_root_dir + "/" + sub)
	for f in DirAccess.get_files_at(_root_dir):
		DirAccess.remove_absolute(_root_dir + "/" + f)
	DirAccess.remove_absolute(_root_dir)
	print("SUITE ", "GREEN" if _fail == 0 else "RED (%d failures)" % _fail)
	quit(0 if _fail == 0 else 1)


func _cfg(base: Dictionary, label: String, over: Dictionary) -> Dictionary:
	var c := base.duplicate()
	c.label = label
	c.merge(over, true)
	return c


func _settle(dir: String, cfg: Dictionary) -> float:
	var t0 := Time.get_ticks_usec()
	var cam := await _new_terrain(dir, cfg)
	var sp := float(cfg.rs)
	cam.global_position = Vector3(0.5 * sp, 120, 0.5 * sp)
	var s := _t.get_streamer()
	for i in 1200:
		await _frames(1)
		var done := true
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				done = done and _t.data.has_region(Vector2i(dx, dy))
		if done and s.get_stats().staged == 0:
			break
	var secs := float(Time.get_ticks_usec() - t0) * 1e-6
	cam.queue_free()
	_t.queue_free()
	await _frames(3)
	return secs


## Time to the first usable terrain: the generation of what the map needs, then the streamer's settle (5 x 5 regions)
func _settle_report(rs: int, gen_ms: int, workers: int) -> void:
	var cfg := {"rs": rs, "conc": 3, "lpf": 1, "budget": 2.0, "slots": 400 if rs == 256 else 160}
	# Camera area: 7 x 7 locations (the settle area plus the hysteresis band)
	var dir := _root_dir + "/settle_cam"
	DirAccess.make_dir_recursive_absolute(dir)
	var cam_locs: Array[Vector2i] = []
	for y in range(-3, 4):
		for x in range(-3, 4):
			cam_locs.append(Vector2i(x, y))
	var gen_cam := _pregenerate(dir, cam_locs, workers, gen_ms)
	var settle_cam: float = await _settle(dir, cfg)
	_clean(dir)
	# The whole region map window (32 x 32)
	dir = _root_dir + "/settle_win"
	DirAccess.make_dir_recursive_absolute(dir)
	var win_locs: Array[Vector2i] = []
	for y in range(-16, 16):
		for x in range(-16, 16):
			win_locs.append(Vector2i(x, y))
	var gen_win := _pregenerate(dir, win_locs, workers, gen_ms)
	var settle_win: float = await _settle(dir, cfg)
	_clean(dir)
	var row := "SETTLE %d m, %d ms x %d workers: camera area (%d files) generation %.2f s + settle %.2f s = %.2f s | window (%d files) generation %.2f s + settle %.2f s = %.2f s" % [
			rs, gen_ms, workers, cam_locs.size(), gen_cam, settle_cam, gen_cam + settle_cam, win_locs.size(), gen_win, settle_win, gen_win + settle_win]
	print(row)
	_rows.append(row)
	ok(gen_cam + settle_cam < gen_win + settle_win, "settle: generating only the camera area is faster to the first terrain than the whole window (%.2f s against %.2f s)" % [gen_cam + settle_cam, gen_win + settle_win])


func _fly(cfg: Dictionary) -> Dictionary:
	var rs: int = cfg.rs
	var sp := float(rs)
	var length: float = cfg.length
	var lazy: bool = cfg.lazy
	var workers: int = cfg.workers
	var gen_s := float(cfg.gen_ms) * 0.001
	var dir := _root_dir + "/flight"
	DirAccess.make_dir_recursive_absolute(dir)
	_clean(dir)
	var cells := _world_cells(rs, length)
	var existing: Array[Vector2i] = []
	var pending: Array[Vector2i] = []
	for loc in cells:
		if lazy and not (absi(loc.x) <= 3 and absi(loc.y) <= 3):
			pending.append(loc) # Only the camera area is generated before the launch
		else:
			existing.append(loc)
	var pregen_s := _pregenerate(dir, existing, 4, 0) if not lazy else _pregenerate(dir, existing, 4, cfg.gen_ms)
	var cam := await _new_terrain(dir, cfg)
	var s := _t.get_streamer()
	var gen := Generator.new()
	gen.dir = dir
	gen.master = _master
	gen.gen_ms = cfg.gen_ms
	if lazy:
		s.register_pending_locations(pending)
		gen.start(workers)
	var start := Vector2(0.5 * sp, 0.5 * sp)
	var dest := start + Vector2(length, 0)
	cam.global_position = Vector3(start.x, 120, start.y)
	var t_settle0 := Time.get_ticks_usec()
	for i in 1200:
		if lazy:
			gen.set_list(s.get_wanted_pending(256))
			s.notify_regions_written(gen.take_done())
		await _frames(1)
		var done := true
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				done = done and _t.data.has_region(Vector2i(dx, dy))
		if done and s.get_stats().staged == 0:
			break
	var settle_s := float(Time.get_ticks_usec() - t_settle0) * 1e-6
	var g := FlightGovernor.new()
	g.auto_cap = false
	g.max_speed = _cruise_cap(length, g)
	var heights := _heights(length)
	g.setup(length, heights, 50.0, _ground(0.0), _ground(length))
	var fp := FlightGovernor.view_footprint(g.cruise_altitude, g.base_pitch_deg, g.base_fov)
	var radius: float = fp.half_width
	g.safety = fp.far
	var pts := PackedVector3Array([Vector3(start.x, 0, start.y), Vector3(dest.x, 0, dest.y)])
	var cols := length / sp
	var radius_full := radius
	var radius_min := 0.5 * radius_full
	var mpl_cache := {}
	var q_applied := 20
	var radius_q := radius_full
	var mpl_now := sp / maxf(_column_regions(s, pts, radius_q, lazy) / cols, 1.0)
	mpl_cache[20] = mpl_now
	var ahead: float = fp.far + FlightGovernor.stop_distance(g.max_speed, g.max_accel * g.brake_fraction, g.max_jerk) + g.max_speed * 1.0
	s.keep_cache_limit = 128
	var ring_all: Array[Vector2i] = []
	for loc in cells:
		var mn := Vector2(loc) * sp
		if (dest - dest.clamp(mn, mn + Vector2(sp, sp))).length() <= RING_RADIUS:
			ring_all.append(loc)
	var path_id := s.add_keep_path(pts, radius)
	s.set_keep_path_ahead(path_id, ahead, 0.0)
	var cone_id := s.add_keep_cone(Vector3(start.x, 0, start.y), Vector3(1, 0, 0), fp.far, radius, sp)
	s.behind_limit = sp
	var circ_id := -1
	# Generation ETA for the governor: the position in the generator's queue, times the time one region takes, shared by the workers
	var list_now: Array = []
	var rank_of := {}
	if cfg.aware and cfg.eta:
		g.gate_eta = func(loc: Vector2i) -> float:
			if not rank_of.has(loc):
				return -1.0
			return (float(rank_of[loc]) + 1.0) * (gen_s + 0.002) / float(workers) + 0.1
	var m := {"ticks": 0, "holes": 0, "arrive": -1.0, "complete": -1.0, "first_move": -1.0, "quality_min": 1.0, "blocked_t": 0.0, "min_ready": INF,
			"rest_t": 0.0, "peak_v": 0.0, "gen_wanted_max": 0, "generating_max": 0, "act": -1.0, "behind_gen": 0, "ring_missing": -1, "wanted_missing": -1,
			"wasted": 0, "tick_ms": []}
	var t := 0.0
	var wall_prev := Time.get_ticks_usec()
	var activated := false
	var load_rate := 10.0
	var rate_t := 0.0
	var rate_n: int = s.get_stats().landed_total
	var hold := 0
	var done_t := -1.0
	var t_act := 2.0
	var conc: int = cfg.conc
	var known := {}
	for loc in cells:
		known[loc] = true
	while true:
		await physics_frame
		RenderingServer.emit_signal("frame_pre_draw")
		var now := Time.get_ticks_usec()
		var wall_dt := float(now - wall_prev) * 1e-6
		wall_prev = now
		var dt := clampf(wall_dt, 1.0 / 240.0, 1.0 / 20.0) if m.ticks > 0 else 1.0 / 60.0
		if lazy:
			# The game's generator loop: the streamer's priority list in, the finished files out
			list_now = s.get_wanted_pending(256)
			rank_of.clear()
			for i in list_now.size():
				rank_of[list_now[i]] = i
			gen.set_list(list_now)
			var finished := gen.take_done()
			for loc in finished:
				m.wasted += 0 if rank_of.has(loc) else 1 # No longer wanted when it was finished
			s.notify_regions_written(finished)
		var st: Dictionary = s.get_stats()
		var remaining := length - g.distance
		var ready := s.get_path_ready_distance(path_id)
		var cam_x := start.x + g.distance
		if cfg.aware and lazy and st.generating_wanted > 0:
			# What a game feeds the governor: where the nearest pending region the corridor needs enters it
			var held_at := INF
			var held_loc = null
			for gloc: Vector2i in list_now:
				var gmn := Vector2(gloc) * sp
				if gmn.x + sp < cam_x:
					continue
				var glat := maxf(maxf(gmn.y - start.y, start.y - (gmn.y + sp)), 0.0)
				if glat > radius_q + 1.0:
					continue
				var at := maxf(gmn.x - start.x - radius_q, g.distance)
				if at < held_at:
					held_at = at
					held_loc = gloc
			g.observe_gate(held_at, held_loc)
		g.observe_loader(dt, int(st.disk_loads_needed), st.inflight >= conc, mpl_now)
		g.step(dt, ready)
		var qi := roundi(g.quality * 20.0)
		if qi != q_applied:
			q_applied = qi
			radius_q = lerpf(radius_min, radius_full, float(qi) / 20.0)
			if not mpl_cache.has(qi):
				mpl_cache[qi] = sp / maxf(_column_regions(s, pts, radius_q, lazy) / cols, 1.0)
			mpl_now = mpl_cache[qi]
			s.set_keep_path(path_id, pts, radius_q)
		m.quality_min = minf(m.quality_min, g.quality)
		t += dt
		if g.distance > 1.0 and m.first_move < 0.0:
			m.first_move = t
		if m.first_move >= 0.0 and g.length - g.distance > 0.5 and g.speed < 5.0:
			m.rest_t += dt
		m.blocked_t += dt if g.gate_blocked else 0.0
		var pos := start + Vector2(g.distance, 0)
		cam.global_position = Vector3(pos.x, g.altitude, pos.y)
		cam.basis = Basis(Vector3.UP, -PI / 2.0) * Basis(Vector3.RIGHT, g.pitch)
		cam.fov = g.fov
		s.set_keep_cone(cone_id, Vector3(pos.x, 0, pos.y), Vector3(1, 0, 0), g.safety, radius_q, sp)
		s.camera_scale = clampf(1.0 - t, 0.0, 1.0)
		m.ticks += 1
		m.tick_ms.append(wall_dt * 1000.0)
		m.peak_v = maxf(m.peak_v, g.speed)
		m.gen_wanted_max = maxi(m.gen_wanted_max, st.generating_wanted)
		m.generating_max = maxi(m.generating_max, st.generating)
		if g.distance >= length and m.arrive < 0.0:
			m.arrive = t
		if ready < remaining - 1.0:
			m.min_ready = minf(m.min_ready, ready)
		if t - rate_t >= 0.5:
			load_rate = maxf(load_rate, float(st.landed_total - rate_n) / (t - rate_t))
			rate_t = t
			rate_n = st.landed_total
		var cam_loc := Vector2i(int(floorf(pos.x / sp)), int(floorf(pos.y / sp)))
		# Holes: a region of the world inside the sharp footprint (a trapezoid ahead) that is not visible. Over pending regions too.
		if m.arrive < 0.0 and g.speed > 1.0:
			var fp_now := FlightGovernor.view_footprint(g.altitude, g.base_pitch_deg, g.base_fov)
			var far_now: float = fp_now.far * lerpf(g.far_min_fraction, 1.0, g.quality if g.soft else 1.0)
			var hole := false
			for cx in range(cam_loc.x, int(floorf((pos.x + far_now) / sp)) + 1):
				for cy in range(cam_loc.y - 6, cam_loc.y + 7):
					var loc := Vector2i(cx, cy)
					if not known.has(loc) or float(cx) * sp > dest.x:
						continue
					var near_x := maxf(float(cx) * sp - pos.x, 0.0)
					var half: float = maxf(150.0, near_x * (radius_q - 100.0) / fp.far)
					if near_x > far_now:
						continue
					var mn_y := float(cy) * sp
					var lat := maxf(maxf(mn_y - pos.y, pos.y - (mn_y + sp)), 0.0)
					if lat <= half and not _t.data.has_region(loc):
						if not hole and m.holes < 2:
							print("DEBUG hole: ", loc, " cam x %.0f t %.2f v %.0f ready %.0f near_x %.0f half %.0f lat %.0f far_now %.0f radius_q %.0f" % [pos.x, t, g.speed, ready, near_x, half, lat, far_now, radius_q])
						hole = true
			m.holes += 1 if hole else 0
		# Destination ring: activated when the time to arrival drops below what it needs to be generated and loaded
		if not activated:
			var eta := t_act + 99.0
			if g.speed > 50.0:
				eta = remaining / maxf(g.speed, 1.0) + g.speed / (g.max_accel * g.end_brake_fraction) * 0.5
			var ring_pending := 0
			if lazy:
				for loc in ring_all:
					ring_pending += 1 if not FileAccess.file_exists(dir + "/" + Terrain3DUtil.location_to_filename(loc)) else 0
			t_act = float(ring_all.size()) / load_rate * 1.5 + 0.75 + float(ring_pending) * (gen_s + 0.002) / float(workers) * 1.2
			if eta <= t_act or (g.speed < 50.0 and remaining < ahead + 1.0):
				activated = true
				m.act = t
				circ_id = s.add_keep_circle(Vector3(dest.x, 0, dest.y), RING_RADIUS, true)
		var ring_ready := true
		if g.length - g.distance <= 0.5:
			for loc: Vector2i in s.get_wanted_regions(false):
				if not _t.data.has_region(loc):
					ring_ready = false
					break
		for loc in ring_all:
			if not _t.data.has_region(loc):
				ring_ready = false
				break
		if done_t < 0.0 and g.is_done(ring_ready):
			done_t = t
			m.complete = t
			var left := 0
			for loc: Vector2i in s.get_wanted_regions(false):
				left += 0 if _t.data.has_region(loc) else 1
			m.wanted_missing = left
			var rleft := 0
			for loc in ring_all:
				rleft += 0 if _t.data.has_region(loc) else 1
			m.ring_missing = rleft
		if done_t >= 0.0:
			hold += 1
			if hold >= 30:
				break
		if t > 120.0:
			break
	var st_end: Dictionary = s.get_stats()
	if lazy:
		gen.finish()
	# The generator followed the streamer's list: how much of its work was no longer wanted when it finished, and how often it
	# went back by more than a few regions along the route (the destination ring excepted)
	var order: Array[Vector2i] = gen.claim_order
	var back_steps := 0
	var steps := 0
	for i in range(1, order.size()):
		if order[i].x * rs < int(dest.x - RING_RADIUS - sp) and order[i - 1].x * rs < int(dest.x - RING_RADIUS - sp):
			steps += 1
			back_steps += 1 if order[i].x < order[i - 1].x - 3 else 0
	var mean_gen_ms := float(gen.busy_ms) / maxf(float(gen.written), 1.0)
	var label: String = cfg.label
	var row := "%-58s | arrive %5.2f s (landed %5.2f) peak %4.0f m/s (cap %4.0f) | take-off hover %.2f s, rests %.2f s | holes %d of %d frames | min ready %5.0f m | quality min %.2f, gate blocked %.1f s | ring act %.2f s | generated %d (%.1f ms each, %d no longer wanted when finished, %d of %d steps back along the route) | pending max %d, wanted pending max %d, pregen %.1f s, settle %.2f s | tick p99 %.1f ms" % [
			label, m.arrive, m.complete, m.peak_v, g.max_speed, m.first_move, m.rest_t, m.holes, m.ticks, m.min_ready if m.min_ready < INF else -1.0, m.quality_min,
			m.blocked_t, m.act, gen.written, mean_gen_ms, m.wasted, back_steps, steps, m.generating_max, m.gen_wanted_max, pregen_s, settle_s, _pct(m.tick_ms, 0.99)]
	ok(m.complete > 0.0, "%s: landed (%.2f s)" % [label, m.complete])
	ok(m.holes == 0, "%s: no hole in the sharp footprint at any time (%d of %d frames): the camera never flew over a missing region" % [label, m.holes, m.ticks])
	ok(m.wanted_missing == 0 and m.ring_missing == 0, "%s: the destination is complete on arrival (%d wanted, %d ring regions missing)" % [label, m.wanted_missing, m.ring_missing])
	ok(g.clamp_hits == 0 or not lazy, "%s: the failsafe clamp never held the camera (%d)" % [label, g.clamp_hits])
	if lazy:
		ok(st_end.failed == 0, "%s: no region ever failed to load (%d)" % [label, st_end.failed])
		ok(m.wasted * 10 <= maxi(gen.written, 1), "%s: the generator worked on what the streamer wanted (%d of %d finished regions were no longer wanted)" % [label, m.wasted, gen.written])
		ok(back_steps * 10 <= maxi(steps, 1), "%s: and in its order, mostly forward along the route (%d of %d steps went back more than 3 regions)" % [label, back_steps, steps])
		if cfg.aware:
			ok(m.quality_min >= 0.99, "%s: generation lag is not read as a slow loader, the footprint quality stays at %.2f" % [label, m.quality_min])
	s.clear_keep()
	s.behind_limit = -1.0
	cam.queue_free()
	_t.queue_free()
	await _frames(3)
	_clean(dir)
	return {"row": row, "m": m}


func _column_regions(s: Terrain3DStreamer, pts: PackedVector3Array, radius: float, lazy: bool) -> float:
	var c: Dictionary = s.get_path_cost(pts, radius)
	return float(c.regions) + (float(c.generating) if lazy else 0.0)
