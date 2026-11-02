extends SceneTree
## Headless flight policy test: the reference governor flies a camera over streamed regions.
##   godot --headless --path project --script res://tests/test_flight_policy.gd [-- size=512 only=text csv=path]
## Cloned noisy region files, a keep path (lookahead segment, optionally the rest prefetched as bodies), a
## forward cone, behind_limit of one region, and the destination ring activated late. The governor limits the
## camera to what the ready distance (Terrain3DStreamer.get_path_ready_distance) shows is loaded, so it never
## outruns the visible terrain: zero holes at any time, the destination complete on arrival, the load order
## path ahead -> rest of the corridor -> destination, jerk limited motion, and regions more than a tile behind
## unloaded. Ungoverned flights at the cap are run for comparison. Prints a summary table; the full time
## series of the main flights go to CSV for plotting (T3D_CSV_DIR).
const FlightGovernor := preload("res://tests/flight_governor.gd")
const CAP := 2500.0
const RING_RADIUS := 1000.0
var _fail := 0
var _t: Terrain3D
var _root_dir := "user://flight_policy_%d" % OS.get_process_id()
var _args := {}
var _worlds := {}
var _rows: Array[String] = []
var _csv_dir := "E:/Terrain3D_fork/private/research/bench/flight-policy"


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			_args[kv[0]] = kv[1]
	if OS.get_environment("T3D_CSV_DIR") != "":
		_csv_dir = OS.get_environment("T3D_CSV_DIR")
	if _args.has("csv"):
		_csv_dir = _args["csv"]
	DirAccess.make_dir_recursive_absolute(_root_dir)
	process_frame.connect(_run)


func _frames(n: int) -> void:
	for i in n:
		await process_frame
		RenderingServer.emit_signal("frame_pre_draw")


func _clean(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + f)


func _write_region(path: String, rs: int) -> void:
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


## One noisy region file cloned to every location of the block (the streamer sets the location after loading)
func _world(rs: int) -> Dictionary:
	if _worlds.has(rs):
		return _worlds[rs]
	var dir := _root_dir + "/world_%d" % rs
	DirAccess.make_dir_recursive_absolute(dir)
	var master := _root_dir + "/master_%d.res" % rs
	_write_region(master, rs)
	var rows := 3 if rs == 512 else 5
	var x1 := int(28000.0 / rs) + 8
	var known := {}
	for y in range(-rows, rows + 1):
		for x in range(-4, x1 + 1):
			DirAccess.copy_absolute(master, dir + "/" + Terrain3DUtil.location_to_filename(Vector2i(x, y)))
			known[Vector2i(x, y)] = true
	DirAccess.remove_absolute(master)
	print("WORLD %d m regions: %d files in %s" % [rs, known.size(), dir])
	_worlds[rs] = {"dir": dir, "known": known}
	return _worlds[rs]


func _new_terrain(w: Dictionary, cfg: Dictionary) -> Camera3D:
	_t = Terrain3D.new()
	_t.streaming_enabled = true
	_t.streaming_slots = cfg.slots
	_t.streaming_distance = 2
	_t.streaming_frame_budget_ms = cfg.budget
	_t.streaming_concurrent_loads = cfg.conc
	_t.streaming_loads_per_frame = cfg.lpf
	_t.data_directory = w.dir
	root.add_child(_t)
	_t.collision_mode = Terrain3DCollision.DYNAMIC_GAME if cfg.collision != "off" else Terrain3DCollision.DISABLED # After add_child: before it the mode is ignored
	var cam := Camera3D.new()
	cam.far = 20000.0
	root.add_child(cam)
	_t.set_camera(cam)
	_t.set_clipmap_target(cam)
	await _frames(2)
	return cam


## Rolling hills, +-40 m, a function of the distance along the route only (the world wide low resolution map stands in)
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


func _base_cfg() -> Dictionary:
	return {"label": "", "rs": 512, "length": 10000.0, "governed": true, "soft": true, "cap": -1.0, "conc": 3, "lpf": 1, "budget": 2.0, "slots": 160,
			"prefetch": true, "ram_budget": 3.0e9, "lookahead": true, "collision": "off", "csv": false, "timeout": 150.0, "expect_zero": true}


func _run() -> void:
	process_frame.disconnect(_run)
	var sizes: Array = [512, 256]
	if _args.has("size"):
		sizes = [int(_args["size"])]
	var only: String = _args.get("only", "")
	var small_slots := {512: 90, 256: 200}
	var big_slots := {512: 160, 256: 400}
	var plan: Array = []
	for rs: int in sizes:
		var b := _base_cfg()
		b.rs = rs
		b.slots = big_slots[rs]
		plan.append(_cfg(b, "%d m 10 km governed, prefetch" % rs, {}))
		plan.append(_cfg(b, "%d m 10 km governed, load as you go" % rs, {"prefetch": false}))
		plan.append(_cfg(b, "%d m 10 km governed, whole route wanted" % rs, {"prefetch": false, "lookahead": false}))
		plan.append(_cfg(b, "%d m 10 km slow loads (conc 1, lpf 1, 2 ms)" % rs, {"conc": 1, "prefetch": false}))
		plan.append(_cfg(b, "%d m 10 km fast loads (conc 8, lpf 8, no budget)" % rs, {"conc": 8, "lpf": 8, "budget": 0.0}))
		plan.append(_cfg(b, "%d m 10 km small RAM budget (fallback)" % rs, {"ram_budget": 60.0e6, "conc": 1}))
		plan.append(_cfg(b, "%d m 10 km small pool (%d slots)" % [rs, small_slots[rs]], {"slots": small_slots[rs], "prefetch": false}))
		plan.append(_cfg(b, "%d m 2 km hop governed" % rs, {"length": 2000.0}))
		plan.append(_cfg(b, "%d m 10 km UNGOVERNED at 2.5 km/s" % rs, {"governed": false, "expect_zero": false}))
		plan.append(_cfg(b, "%d m 10 km UNGOVERNED, slow loads" % rs, {"governed": false, "conc": 1, "prefetch": false, "expect_zero": false}))
		plan.append(_cfg(b, "%d m 10 km UNGOVERNED 5 km/s, slow loads" % rs, {"governed": false, "cap": 5000.0, "conc": 1, "prefetch": false, "expect_zero": false}))
		plan.append(_cfg(b, "%d m 10 km governed 5 km/s cap, slow loads" % rs, {"cap": 5000.0, "conc": 1, "prefetch": false}))
		plan.append(_cfg(b, "%d m 28 km governed, prefetch" % rs, {"length": 28000.0, "csv": rs == 512}))
		plan.append(_cfg(b, "%d m 28 km governed, load as you go" % rs, {"length": 28000.0, "prefetch": false}))
		# Governor v2: the soft law against the v1 braking clamp, with loaders slowed three ways (one load in flight, a
		# 0.5 ms insertion budget that makes every region take several frames, both)
		for variant: Array in [["conc 1", {"conc": 1}], ["budget 0.5 ms", {"budget": 0.5}], ["conc 1 + budget 0.5 ms", {"conc": 1, "budget": 0.5}]]:
			var vo: Dictionary = variant[1]
			vo.merge({"length": 28000.0, "prefetch": false}, true)
			plan.append(_cfg(b, "%d m 28 km v2 soft, %s" % [rs, variant[0]], vo))
			var vo1 := vo.duplicate()
			vo1.merge({"soft": false}, true)
			plan.append(_cfg(b, "%d m 28 km v1 hard clamp, %s" % [rs, variant[0]], vo1))
		# An artificially slowed loader: a 0.05 ms budget lets only one upload step of one region run per frame
		plan.append(_cfg(b, "%d m 10 km v2 soft, one upload step per frame" % rs, {"conc": 1, "budget": 0.05, "prefetch": false, "timeout": 400.0}))
		plan.append(_cfg(b, "%d m 10 km v1 hard clamp, one upload step per frame" % rs, {"conc": 1, "budget": 0.05, "prefetch": false, "soft": false, "timeout": 400.0}))
	# Frame pacing: dynamic collision refresh and the frame budget
	for rs: int in sizes:
		var cb := _base_cfg()
		cb.rs = rs
		cb.slots = big_slots[rs]
		cb.prefetch = false
		for coll: String in ["on", "suspend"]:
			for budget: float in [2.0, 6.0]:
				plan.append(_cfg(cb, "%d m 10 km collision %s, budget %.0f ms" % [rs, coll, budget], {"collision": coll, "budget": budget}))
	if sizes.has(512):
		plan[0].csv = true
	for cfg: Dictionary in plan:
		if only != "" and cfg.label.find(only) < 0:
			continue
		var r: Dictionary = await _fly(cfg)
		_rows.append(r.row)
		print("ROW ", r.row)
	# Prefetch timing and the cost of the corridor
	var costs: Array[String] = []
	for rs: int in sizes:
		for length: float in [10000.0, 28000.0]:
			if only != "" and only != "prefetch":
				continue
			costs.append(await _prefetch_time(rs, length))
	print("")
	print("FLIGHT SUMMARY")
	for row in _rows:
		print("  ", row)
	print("PREFETCH COST AND TIME")
	for c in costs:
		print("  ", c)
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


## Corridor regions: known cells whose footprint touches the band |y - route| <= radius between x0 and x1
func _band(known: Dictionary, rs: int, y_mid: float, radius: float, x0: float, x1: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for loc: Vector2i in known:
		var mn := Vector2(loc) * rs
		if mn.x + rs >= x0 and mn.x <= x1 and mn.y + rs >= y_mid - radius and mn.y <= y_mid + radius:
			out.append(loc)
	return out


func _in_circle(loc: Vector2i, rs: int, c: Vector2, r: float) -> bool:
	var mn := Vector2(loc) * rs
	return (c - c.clamp(mn, mn + Vector2(rs, rs))).length() <= r


func _prefetch_time(rs: int, length: float) -> String:
	var w := _world(rs)
	var cfg := _base_cfg()
	cfg.rs = rs
	cfg.slots = 160 if rs == 512 else 400
	cfg.conc = 8
	cfg.lpf = 8
	cfg.budget = 0.0
	var cam := await _new_terrain(w, cfg)
	var s := _t.get_streamer()
	var sp := float(rs)
	var start := Vector2(0.5 * sp, 0.5 * sp)
	cam.global_position = Vector3(start.x, 120, start.y)
	var g := FlightGovernor.new()
	g.setup(length, _heights(length), 50.0, _ground(0.0), _ground(length))
	var fp := FlightGovernor.view_footprint(g.cruise_altitude, g.base_pitch_deg, g.base_fov)
	var pts := PackedVector3Array([Vector3(start.x, 0, start.y), Vector3(start.x + length, 0, start.y)])
	var cost: Dictionary = s.get_path_cost(pts, fp.half_width)
	_t.get_streamer().keep_cache_limit = mini(4096, cost.regions + 64)
	for i in 120:
		await _frames(1)
	var id := s.add_keep_path(pts, fp.half_width)
	s.set_keep_path_ahead(id, 0.0, -1.0) # Needed set: just the camera's own regions; everything else is prefetch
	var corridor := _band(w.known, rs, start.y, fp.half_width, start.x, start.x + length)
	var t0 := Time.get_ticks_usec()
	var done_s := -1.0
	for i in 3000:
		await _frames(1)
		var st: Dictionary = s.get_stats()
		var have := _locs(s.get_cached_regions())
		var all := true
		for loc in corridor:
			if not have.has(loc) and not _t.data.has_region(loc):
				all = false
				break
		if all and st.inflight == 0 and st.staged == 0:
			done_s = float(Time.get_ticks_usec() - t0) * 1e-6
			break
	var st2: Dictionary = s.get_stats()
	var mb := float(cost.bytes) / 1048576.0
	var row := "%d m %2.0f km: corridor radius %4.0f m (cruise alt %3.0f m, far %4.0f m) | %4d regions, %6.0f MB raw (%.2f MB each), %3d beyond the window now, RAM cache %6.0f MB | fully prefetched in %5.1f s warm (conc 8, no budget; cached %d, resident %d)" % [
			rs, length / 1000.0, fp.half_width, g.cruise_altitude, fp.far, cost.regions, mb, float(cost.region_bytes) / 1048576.0, cost.outside_window,
			float(st2.ram_cached) * float(cost.region_bytes) / 1048576.0, done_s, st2.ram_cached, st2.resident]
	ok(done_s > 0.0, "prefetch time %s" % row.substr(0, 40))
	cam.queue_free()
	_t.queue_free()
	await _frames(3)
	return row


func _locs(arr: Array) -> Dictionary:
	var d := {}
	for loc: Vector2i in arr:
		d[loc] = true
	return d


## The ring regions that the corridor does not want anyway: further than the corridor radius from the route
func _ring_only(known: Dictionary, rs: int, c: Vector2, y_mid: float, radius: float, x_start: float, x_end: float) -> Dictionary:
	var d := {}
	for loc: Vector2i in known:
		if _in_circle(loc, rs, c, RING_RADIUS + float(rs)): # The ring and its hysteresis band of one region
			var mn := Vector2(loc) * rs
			var lateral := maxf(maxf(mn.y - y_mid, y_mid - (mn.y + rs)), 0.0)
			var along := maxf(maxf(mn.x - x_end, x_start - (mn.x + rs)), 0.0)
			if Vector2(lateral, along).length() > radius + 1.0:
				d[loc] = true
	return d


func _fly(cfg: Dictionary) -> Dictionary:
	var rs: int = cfg.rs
	var w := _world(rs)
	var known: Dictionary = w.known
	var length: float = cfg.length
	var governed: bool = cfg.governed
	var cam := await _new_terrain(w, cfg)
	var s := _t.get_streamer()
	var sp := float(rs)
	var start := Vector2(0.5 * sp, 0.5 * sp)
	var dest := start + Vector2(length, 0)
	cam.global_position = Vector3(start.x, 120, start.y)
	for i in 600:
		await _frames(1)
		var done := true
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				if not _t.data.has_region(Vector2i(dx, dy)):
					done = false
		if done and s.get_stats().staged == 0:
			break
	# The plan: cruise altitude from the terrain profile, the sharp footprint from it, corridor from the footprint
	var g := FlightGovernor.new()
	g.soft = cfg.soft
	if cfg.cap > 0.0:
		g.auto_cap = false
		g.max_speed = cfg.cap
	var heights := _heights(length)
	g.setup(length, heights, 50.0, _ground(0.0), _ground(length))
	var fp := FlightGovernor.view_footprint(g.cruise_altitude, g.base_pitch_deg, g.base_fov)
	var radius: float = fp.half_width
	var far: float = fp.far
	g.safety = far
	var pts := PackedVector3Array([Vector3(start.x, 0, start.y), Vector3(dest.x, 0, dest.y)])
	var cost: Dictionary = s.get_path_cost(pts, radius)
	# Footprint quality: the corridor radius falls from the derived one to half of it before the camera slows. A load
	# advances the front by span / (regions in one column of the corridor)
	var radius_full := radius
	var radius_min := 0.5 * radius_full
	var mpl_cache := {}
	var q_applied := 20
	var radius_q := radius_full
	var cols := length / sp
	var mpl_now: float = sp / maxf(float(cost.regions) / cols, 1.0)
	mpl_cache[20] = mpl_now
	var ahead := -1.0
	if cfg.lookahead:
		ahead = fp.far + FlightGovernor.stop_distance(g.max_speed, g.max_accel * g.brake_fraction, g.max_jerk) + g.max_speed * 1.0
	var prefetch_reach := 0.0
	var prefetch_all := false
	if cfg.prefetch and cfg.lookahead:
		# Whole route into the cache when the RAM budget allows, else as much as it allows
		var cache_regions := int(float(cfg.ram_budget) / float(cost.region_bytes))
		prefetch_all = cost.outside_window + 64 <= cache_regions
		s.keep_cache_limit = mini(4096, cost.outside_window + 64) if prefetch_all else maxi(cache_regions, 0)
		prefetch_reach = -1.0
	else:
		s.keep_cache_limit = 0 if cfg.lookahead else 128
	var corridor := _band(known, rs, start.y, radius, start.x, dest.x)
	var ring := _ring_only(known, rs, dest, start.y, radius, start.x, dest.x)
	var ring_keep := {} # The ring and its hysteresis band of one region: exempt from the behind limit
	var ring_all: Array[Vector2i] = []
	for loc: Vector2i in known:
		if _in_circle(loc, rs, dest, RING_RADIUS):
			ring_all.append(loc)
		if _in_circle(loc, rs, dest, RING_RADIUS + sp):
			ring_keep[loc] = true
	var path_id := s.add_keep_path(pts, radius)
	if cfg.lookahead:
		s.set_keep_path_ahead(path_id, ahead, prefetch_reach)
	var cone_id := s.add_keep_cone(Vector3(start.x, 0, start.y), Vector3(1, 0, 0), fp.far, radius, sp)
	s.behind_limit = sp
	var circ_id := -1
	if not cfg.lookahead:
		circ_id = s.add_keep_circle(Vector3(dest.x, 0, dest.y), RING_RADIUS, true) # Legacy: everything wanted from t=0
	var col_start: int = s.get_stats().collision_refreshes
	if cfg.collision == "suspend":
		_t.collision_mode = Terrain3DCollision.DISABLED
	var sat_time := 0.0
	var sat_loads := 0
	var sat_mpl := 0.0
	var front_adv := 0.0
	var est_sum := 0.0
	var est_n := 0
	var prev_front := -1.0
	var sat_prev_loads: int = s.get_stats().disk_loads_needed
	var mid_speeds: Array[float] = []
	var all_speeds: Array[float] = []
	var mid_dvdt: Array[float] = []
	var m := {"quality_min": 1.0, "adapt_a": 0.0, "adapt_j": 0.0, "adapt_frames": 0, "adapt_j_over": 0, "ticks": 0, "holes": 0, "holes_near": 0, "behind_age_max": 0, "arrive": -1.0, "complete": -1.0, "peak_v": 0.0,
			"min_ready": INF, "resident_max": 0, "da_ratio": 0.0, "dv_max": 0.0, "dv_frames": 0, "peak_a": 0.0, "peak_j": 0.0,
			"first_ring": -1.0, "act": -1.0, "corridor_done": -1.0, "wanted_behind": 0, "ring_early": 0, "order_violations": 0,
			"ring_missing": -1, "ring_whole": -1, "ring_check": false, "lead_dist_min": INF, "lead_t_min": INF, "late_inserts": 0, "recentres": 0, "recentre_log": [], "wanted_missing": -1, "landed_start": s.get_stats().landed_total, "tick_ms": [], "phys_ms": [],
			"wanted_max": 0, "missing_max": 0, "restore_ms": 0.0, "post_tick_max": 0.0, "col_refreshes": 0, "col_start": 0, "classes": {"near": 0, "cache": 0, "ring": 0}}
	var csv := PackedStringArray(["t,distance,speed,accel,jerk,altitude,ground,climb_speed,pitch_deg,fov,ready,resident,wanted,missing,tick_ms"])
	var seen := {}
	var col_insert := {} # Column x -> [time inserted, meters ahead of the camera then]
	var col_reach := {}
	var org_prev: Vector2i = _t.data.get_region_map_origin()
	var recentres_start: int = s.get_stats().recentres
	var behind_age := {}
	var t := 0.0
	var wall_prev := Time.get_ticks_usec()
	var activated := false
	var load_rate := 10.0 # Peak loads per second seen, with a floor
	var rate_t := 0.0
	var rate_n: int = m.landed_start
	var landed_at_done := false
	var done_t := -1.0
	var hold := 0
	var prev_v := 0.0
	var prev_a := 0.0
	var t_act := 2.0
	var ring_pending_seen := false
	while true:
		await physics_frame
		RenderingServer.emit_signal("frame_pre_draw")
		var now := Time.get_ticks_usec()
		var wall_dt := float(now - wall_prev) * 1e-6
		wall_prev = now
		var dt := clampf(wall_dt, 1.0 / 240.0, 1.0 / 20.0) if m.ticks > 0 else 1.0 / 60.0
		var st: Dictionary = s.get_stats()
		var remaining := length - g.distance
		var ready := s.get_path_ready_distance(path_id)
		if governed:
			var saturated: bool = st.inflight >= cfg.conc
			g.observe_loader(dt, int(st.disk_loads_needed), saturated, mpl_now)
			var front := g.distance + ready
			if saturated and ready < remaining - 1.0 and prev_front >= 0.0 and not activated:
				sat_time += dt
				est_sum += g.rate_est if g.rate_valid else 0.0
				est_n += 1 if g.rate_valid else 0
				front_adv += front - prev_front + 0.0 # Includes the camera's own travel: front = distance + ready
			prev_front = front if ready < remaining - 1.0 else -1.0
			sat_prev_loads = int(st.disk_loads_needed)
			g.step(dt, ready)
			# Apply the footprint quality the governor asks for (steps of 0.05)
			var qi := roundi(g.quality * 20.0)
			if qi != q_applied:
				q_applied = qi
				radius_q = lerpf(radius_min, radius_full, float(qi) / 20.0)
				if not mpl_cache.has(qi):
					mpl_cache[qi] = sp / maxf(float(s.get_path_cost(pts, radius_q).regions) / cols, 1.0)
				mpl_now = mpl_cache[qi]
				s.set_keep_path(path_id, pts, radius_q)
			m.quality_min = minf(m.quality_min, g.quality)
		else:
			g.step(dt, INF)
		t += dt
		var pos := start + Vector2(g.distance, 0)
		cam.global_position = Vector3(pos.x, g.altitude, pos.y)
		cam.basis = Basis(Vector3.UP, -PI / 2.0) * Basis(Vector3.RIGHT, g.pitch)
		cam.fov = g.fov
		s.set_keep_cone(cone_id, Vector3(pos.x, 0, pos.y), Vector3(1, 0, 0), g.safety if governed else fp.far, radius_q, sp)
		s.camera_scale = clampf(1.0 - t, 0.0, 1.0)
		m.ticks += 1
		m.tick_ms.append(wall_dt * 1000.0)
		if wall_dt > 0.15:
			print("DEBUG slow tick %.0f ms at t=%.2f s: quality %.2f (applied %d), resident %d, staged %d, inflight %d" % [wall_dt * 1000.0, t, g.quality, q_applied, st.resident, st.staged, st.inflight])
		m.phys_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		m.peak_v = maxf(m.peak_v, g.speed)
		m.peak_a = maxf(m.peak_a, absf(g.accel))
		m.peak_j = maxf(m.peak_j, absf(g.jerk))
		if g.distance < length:
			m.da_ratio = maxf(m.da_ratio, absf(g.accel - prev_a) / (g.max_jerk * dt))
		elif m.arrive < 0.0:
			m.arrive = t
		prev_a = g.accel
		if g.adapting:
			m.adapt_frames += 1
			m.adapt_a = maxf(m.adapt_a, absf(g.accel))
			m.adapt_j = maxf(m.adapt_j, absf(g.jerk))
			m.adapt_j_over += 1 if absf(g.jerk) > g.max_jerk * g.soft_jerk_fraction * 1.05 else 0
		if g.distance > 0.15 * length and g.distance < 0.85 * length:
			all_speeds.append(g.speed)
			if not activated:
				mid_speeds.append(g.speed)
				mid_dvdt.append((g.speed - prev_v) / dt)
		m.dv_max = maxf(m.dv_max, absf(g.speed - prev_v))
		m.dv_frames += 1 if absf(g.speed - prev_v) > 0.03 * g.max_speed else 0
		prev_v = g.speed
		if ready < remaining - 1.0:
			m.min_ready = minf(m.min_ready, ready)
		m.resident_max = maxi(m.resident_max, st.resident)
		m.wanted_max = maxi(m.wanted_max, st.wanted)
		m.missing_max = maxi(m.missing_max, st.missing)
		# Load rate seen, for the activation time of the destination
		if t - rate_t >= 0.5:
			load_rate = maxf(load_rate, float(st.landed_total - rate_n) / (t - rate_t))
			rate_t = t
			rate_n = st.landed_total
		var cam_loc := Vector2i(int(floorf(pos.x / sp)), int(floorf(pos.y / sp)))
		# Holes: a known region of the sharp footprint (a trapezoid ahead) not visible
		var holes := 0
		var holes_near := 0
		if m.arrive < 0.0 and g.speed > 1.0:
			var fp_now := FlightGovernor.view_footprint(g.altitude, g.base_pitch_deg, g.base_fov) # The view shrinks as the camera descends
			var far_now: float = fp_now.far * lerpf(g.far_min_fraction, 1.0, g.quality if governed and g.soft else 1.0)
			var x_hi: float = pos.x + far_now
			for cx in range(cam_loc.x, int(floorf(x_hi / sp)) + 1):
				for cy in range(cam_loc.y - 6, cam_loc.y + 7):
					var loc := Vector2i(cx, cy)
					if not known.has(loc):
						continue
					var near_x := maxf(float(cx) * sp - pos.x, 0.0)
					var half: float = maxf(150.0, near_x * (radius_q - 100.0) / far)
					if near_x > far_now:
						continue
					var mn_y := float(cy) * sp
					var lat := maxf(maxf(mn_y - pos.y, pos.y - (mn_y + sp)), 0.0)
					if lat <= half and not _t.data.has_region(loc):
						holes += 1
						if m.holes < 3 and holes == 1:
							print("DEBUG hole: ", loc, " cam x %.0f t %.2f v %.0f ready %.0f near_x %.0f half %.0f lat %.0f" % [pos.x, t, g.speed, ready, near_x, half, lat])
						if near_x <= sp:
							holes_near += 1
			m.holes += 1 if holes > 0 else 0
			m.holes_near += 1 if holes_near > 0 else 0
		# Lead time: when does each column of the route's centre row become visible, against when the camera reaches it
		for cx in range(cam_loc.x - 1, cam_loc.x + 40):
			if col_insert.has(cx) or cx < 0:
				continue
			if _t.data.has_region(Vector2i(cx, cam_loc.y)):
				col_insert[cx] = [t, float(cx) * sp - pos.x if m.ticks > 1 else INF]
		for cx in col_insert:
			if not col_reach.has(cx) and pos.x >= float(cx) * sp:
				col_reach[cx] = t
		var org_now: Vector2i = _t.data.get_region_map_origin()
		if org_now != org_prev:
			var cached_now: int = st.ram_cached
			m.recentre_log.append("t=%.2f cam x %.0f origin %s -> %s, resident %d, cached %d" % [t, pos.x, org_prev, org_now, st.resident, cached_now])
			org_prev = org_now
		# Behind: resident regions more than 1.5 regions behind (centre) the camera should be gone within a few frames
		var far_behind := 0
		var res_list: Array = _t.data.get_region_locations()
		var keep_ages := {}
		for loc: Vector2i in res_list:
			if (float(loc.x) + 0.5) * sp < pos.x - 2.5 * sp and not ring_keep.has(loc):
				keep_ages[loc] = behind_age.get(loc, 0) + 1
				far_behind += 1
		behind_age = keep_ages
		var age_max := 0
		for k in behind_age:
			age_max = maxi(age_max, behind_age[k])
		m.behind_age_max = maxi(m.behind_age_max, age_max)
		# Wanted must not reach behind the camera by more than a tile (the destination ring excepted)
		if m.ticks % 3 == 0:
			var wanted_list: Array = s.get_wanted_regions(false)
			var missing := 0
			for loc: Vector2i in wanted_list:
				if (float(loc.x) + 0.5) * sp < pos.x - 1.5 * sp - 100.0 - g.speed * 0.05 and not ring_keep.has(loc): # The wanted list is a tick or two old
					m.wanted_behind += 1
					if m.wanted_behind <= 3:
						print("DEBUG wanted behind: ", loc, " cam x ", pos.x / sp, " t ", t, " scale ", s.camera_scale)
				missing += 0 if _t.data.has_region(loc) else 1
			if csv.size() % 1 == 0:
				pass
		# Request order: record new requests and their class
		var near_set: Dictionary = {}
		var pend: Array = s.get_pending_regions()
		var new_reqs: Array[Vector2i] = []
		for loc: Vector2i in pend:
			if not seen.has(loc):
				seen[loc] = true
				new_reqs.append(loc)
		if not new_reqs.is_empty():
			near_set = _locs(s.get_wanted_regions(false))
			for loc in new_reqs:
				if ring.has(loc) and not near_set.has(loc):
					m.classes.ring += 1
				elif ring.has(loc):
					m.classes.ring += 1
				elif near_set.has(loc):
					m.classes.near += 1
				else:
					m.classes.cache += 1
				if ring.has(loc) and m.first_ring < 0.0:
					m.first_ring = t
		# Destination activation: the corridor is complete, or the time to arrival drops below T_act
		if not activated and cfg.lookahead:
			if m.ticks % 6 == 0 and m.corridor_done < 0.0:
				var have := _locs(s.get_cached_regions())
				var cdone := true
				for loc in corridor:
					if loc.x < cam_loc.x - 1:
						continue
					if not _t.data.has_region(loc) and not have.has(loc):
						cdone = false
						break
				if cfg.prefetch and cdone or (not cfg.prefetch and ready >= minf(ahead, remaining) - 1.0 and remaining < ahead + 1.0):
					m.corridor_done = t
			# Estimated time to arrival: braking from the present speed, or the cruise at the cap
			var eta := t_act + 99.0
			if g.speed > 50.0:
				eta = remaining / maxf(g.speed, 1.0) + g.speed / (g.max_accel * g.end_brake_fraction) * 0.5
			t_act = float(ring_all.size()) / load_rate * 1.5 + 0.75
			if m.corridor_done > 0.0 or eta <= t_act or (g.speed < 50.0 and remaining < ahead + 1.0):
				activated = true
				m.act = t
				circ_id = s.add_keep_circle(Vector3(dest.x, 0, dest.y), RING_RADIUS, true)
				m.ring_check = true
		elif not cfg.lookahead and m.act < 0.0:
			m.act = 0.0
			activated = true
		if m.ring_check and m.act < t:
			# The ring is requested as a whole: every known ring region is in the wanted set one tick after activation
			m.ring_check = false
			var wl := _locs(s.get_wanted_regions(false))
			var absent := 0
			for loc in ring_all:
				absent += 0 if wl.has(loc) else 1
			m.ring_whole = absent
		# Before activation no destination-only region may be pending, cached or resident (beyond the cone's reach)
		if not activated and cfg.lookahead:
			var cached := _locs(s.get_cached_regions())
			for loc in ring:
				if (float(loc.x) * sp) > pos.x + fp.far + 2.0 * sp and (cached.has(loc) or _locs(pend).has(loc) or _t.data.has_region(loc)):
					m.ring_early += 1
					break
		# Landing
		var ring_ready: bool = s.get_stats().missing == 0 # Everything wanted, and below the whole ring
		for loc in ring_all:
			if not _t.data.has_region(loc):
				ring_ready = false
				break
		if csv.size() < 100000 and cfg.csv:
			csv.append("%.4f,%.2f,%.2f,%.1f,%.0f,%.2f,%.2f,%.2f,%.3f,%.2f,%.1f,%d,%d,%d,%.2f" % [t, g.distance, g.speed, g.accel, g.jerk, g.altitude,
					_ground(g.distance), g.climb_speed, rad_to_deg(g.pitch), g.fov, ready if ready < remaining - 1.0 else -1.0, st.resident, st.wanted, st.missing, wall_dt * 1000.0])
		if done_t < 0.0 and g.is_done(ring_ready if governed else true):
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
			if not governed:
				m.classes_missing = _classify_missing(s, ring_all)
			m.col_refreshes = s.get_stats().collision_refreshes - col_start
			if cfg.collision == "suspend":
				var tr := Time.get_ticks_usec()
				_t.collision_mode = Terrain3DCollision.DYNAMIC_GAME
				await _frames(1)
				m.restore_ms = float(Time.get_ticks_usec() - tr) * 0.001
		if done_t >= 0.0:
			m.post_tick_max = maxf(m.post_tick_max, wall_dt * 1000.0)
			hold += 1
			if hold >= 45:
				break
		if t > float(cfg.timeout):
			m.complete = -1.0
			break
	for cx in col_insert:
		var rec: Array = col_insert[cx]
		if rec[1] == INF or not col_reach.has(cx):
			continue
		m.lead_dist_min = minf(m.lead_dist_min, rec[1])
		m.lead_t_min = minf(m.lead_t_min, col_reach[cx] - rec[0])
		m.late_inserts += 1 if rec[1] < sp else 0
	m.recentres = s.get_stats().recentres - recentres_start
	var far_left := 0
	for loc: Vector2i in _t.data.get_region_locations():
		if (float(loc.x) + 0.5) * sp < start.x + g.distance - 2.5 * sp and not ring_keep.has(loc):
			far_left += 1
			print("DEBUG left behind: ", loc, " cam x ", (start.x + g.distance) / sp)
	var st_end: Dictionary = s.get_stats()
	var tick: Array = m.tick_ms
	var phys: Array = m.phys_ms
	var mean_speed: float = length / m.arrive if m.arrive > 0.0 else 0.0
	var row := "%-46s | arrive %5.2f s (landed %5.2f) mean %4.0f peak %4.0f m/s | holes %3d/%3d near %d | min ready %5.0f m | dest start %5.2f s, act %5.2f, corridor done %5.2f, ring missing %2d | resident max %3d wanted max %3d | tick p99 %5.1f max %5.1f ms | jerk %5.0f clamp %d | cached %d | %d regions %4.0f MB" % [
			cfg.label, m.arrive, m.complete, mean_speed, m.peak_v, m.holes, m.ticks, m.holes_near, m.min_ready if m.min_ready < INF else -1.0, m.first_ring, m.act,
			m.corridor_done, m.ring_missing, m.resident_max, m.wanted_max, _pct(tick, 0.99), tick.max() if not tick.is_empty() else 0.0, m.peak_j, g.clamp_hits,
			st_end.ram_cached, cost.regions, float(cost.bytes) / 1048576.0]
	row += " | lead min %.1f s / %.0f m, recentres %d" % [m.lead_t_min if m.lead_t_min < INF else -1.0, m.lead_dist_min if m.lead_dist_min < INF else -1.0, m.recentres]
	var cruise := 0.0
	var vmin := 0.0
	var wob := 0.0
	if not mid_speeds.is_empty():
		var sorted := mid_speeds.duplicate()
		sorted.sort()
		cruise = sorted[sorted.size() / 2]
		vmin = sorted[0]
		var mean := 0.0
		for d in mid_dvdt:
			mean += d
		mean /= mid_dvdt.size()
		for d in mid_dvdt:
			wob += (d - mean) * (d - mean)
		wob = sqrt(wob / mid_dvdt.size())
	m["min_frac"] = vmin / maxf(cruise, 1.0)
	var vmin_all := INF
	for v in all_speeds:
		vmin_all = minf(vmin_all, v)
	m["min_frac_all"] = vmin_all / maxf(cruise, 1.0) if not all_speeds.is_empty() else 0.0
	var theory := length / g.max_speed + 1.5
	var actual_rate := front_adv / sat_time if sat_time > 0.3 else -1.0
	row += " | v2: cap %.0f cruise %.0f min speed %.2f of cruise (%.2f including the destination phase), wobble %.0f, adapt a %.0f j %.0f (%d frames, %d above 0.3 x the jerk limit), quality min %.2f, lost %.1f s vs cap flight, rate est (mean before the destination) %.0f / actual front advance %.0f m/s" % [
			g.max_speed, cruise, m.min_frac, m.min_frac_all, wob, m.adapt_a, m.adapt_j, m.adapt_frames, m.adapt_j_over, m.quality_min, m.arrive - theory, est_sum / maxf(float(est_n), 1.0) if est_n > 0 else -1.0, actual_rate]
	if m.has("classes_missing"):
		row += " | missing at arrival: " + str(m.classes_missing)
	if cfg.collision != "off":
		row += " | collision refreshes in flight %d, resume %.1f ms (worst tick in the hold after landing %.1f ms), phys p99 %.1f max %.1f" % [m.col_refreshes, m.restore_ms, m.post_tick_max, _pct(phys, 0.99), phys.max() if not phys.is_empty() else 0.0]
		if cfg.collision == "suspend":
			ok(m.col_refreshes == 0, "%s: no collision refresh during the flight (%d)" % [cfg.label, m.col_refreshes])
	var label: String = cfg.label
	if cfg.csv or cfg.rs == 256 and cfg.length == 10000.0 and cfg.prefetch:
		for line in m.recentre_log:
			print("RECENTRE ", label, ": ", line)
	if governed and cfg.expect_zero:
		ok(m.complete > 0.0, "%s: landed (%.2f s)" % [label, m.complete])
		ok(m.holes == 0 and m.holes_near == 0, "%s: no hole in the sharp footprint at any time (%d of %d frames, %d within a tile)" % [label, m.holes, m.ticks, m.holes_near])
		ok(m.wanted_missing == 0 and m.ring_missing == 0, "%s: every wanted region and the whole destination ring are resident on arrival (%d, %d missing)" % [label, m.wanted_missing, m.ring_missing])
		ok(m.peak_v <= g.max_speed * 1.001 and m.peak_a <= g.max_accel * 1.001 and m.peak_j <= g.max_jerk * 1.001, "%s: speed, acceleration and jerk within the limits (%.0f m/s, %.0f, %.0f)" % [label, m.peak_v, m.peak_a, m.peak_j])
		ok(m.da_ratio <= 1.01, "%s: acceleration continuous, largest step %.3f of the jerk limit" % [label, m.da_ratio])
		ok(g.clamp_hits == 0, "%s: the braking constraint alone held, the failsafe clamp never engaged (%d)" % [label, g.clamp_hits])
		ok(m.behind_age_max <= 45 and far_left == 0, "%s: regions more than a tile behind unload within %d frames (and %d are left at the end)" % [label, m.behind_age_max, far_left])
		ok(m.late_inserts == 0 and m.lead_t_min >= 0.0, "%s: no column of the route is inserted once the camera is within a tile of it (lead min %.2f s, %.0f m ahead)" % [label, m.lead_t_min, m.lead_dist_min])
		ok(m.wanted_behind == 0, "%s: the wanted set never reaches more than a tile behind the camera (%d violations)" % [label, m.wanted_behind])
		if cfg.lookahead:
			ok(m.ring_whole == 0, "%s: the destination ring is wanted as a whole when it activates (%d of %d ring regions absent from the wanted set)" % [label, m.ring_whole, ring_all.size()])
			ok(m.ring_early == 0, "%s: no destination-only region was pending, cached or resident before activation (%d ticks)" % [label, m.ring_early])
			ok(m.first_ring < 0.0 or m.first_ring >= m.act - 1.0 / 30.0, "%s: the destination's first request (%.2f s) came after its activation (%.2f s)" % [label, m.first_ring, m.act])
	elif governed:
		ok(m.complete > 0.0 and m.holes == 0, "%s: landed with no holes" % label)
	if governed and g.soft and (cfg.conc == 1 or cfg.budget < 1.0):
		ok(m.min_frac >= 0.5, "%s: mid-flight speed never below 50%% of cruise (%.2f)" % [label, m.min_frac])
		ok(g.clamp_hits == 0, "%s: the failsafe clamp never engaged (%d)" % [label, g.clamp_hits])
	else:
		ok(m.arrive > 0.0, "%s: reported (holes %d of %d frames)" % [label, m.holes, m.ticks])
	if cfg.csv:
		DirAccess.make_dir_recursive_absolute(_csv_dir)
		var name := label.replace(" ", "_").replace(",", "").replace("(", "").replace(")", "").replace("/", "_")
		var f := FileAccess.open(_csv_dir + "/" + name + ".csv", FileAccess.WRITE)
		if f != null:
			f.store_string("\n".join(csv))
			f.close()
	s.clear_keep()
	s.behind_limit = -1.0
	cam.queue_free()
	_t.queue_free()
	await _frames(3)
	return {"row": row, "m": m}


## What the regions still missing on arrival were: beyond the window, deferred, in flight or just not requested yet
func _classify_missing(s: Terrain3DStreamer, ring_all: Array[Vector2i]) -> Dictionary:
	var out := {"outside_window": 0, "pending": 0, "cached": 0, "queued": 0}
	var pending := _locs(s.get_pending_regions())
	var cached := _locs(s.get_cached_regions())
	var org := _t.data.get_region_map_origin()
	var size := _t.data.get_region_map_size()
	var all: Array = s.get_wanted_regions(false)
	for loc in ring_all:
		all.append(loc)
	var seen := {}
	for loc: Vector2i in all:
		if seen.has(loc) or _t.data.has_region(loc):
			continue
		seen[loc] = true
		if loc.x < org.x or loc.y < org.y or loc.x >= org.x + size or loc.y >= org.y + size:
			out.outside_window += 1
		elif pending.has(loc):
			out.pending += 1
		elif cached.has(loc):
			out.cached += 1
		else:
			out.queued += 1
	return out
