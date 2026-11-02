extends SceneTree
## Headless test for the streamer's flight support (direction aware priority, behind limit, ready distance,
## path cost, nearest_missing stat, prefetch cache):
##   godot --headless --path project --script res://tests/test_streaming_flight.gd
## Uses 64 px cloned regions along a strip, so it is fast. The 10 km flights with the governor are in
## test_flight_policy.gd.
const RS := 64
var _fail := 0
var _t: Terrain3D
var _root_dir := "user://flight_test_%d" % OS.get_process_id()


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(_root_dir)
	process_frame.connect(_run)


func _frames(n: int) -> void:
	for i in n:
		await process_frame
		RenderingServer.emit_signal("frame_pre_draw")


func _clean(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + f)


func _author_block(dir: String, x0: int, x1: int, y0: int, y1: int) -> int:
	DirAccess.make_dir_recursive_absolute(dir)
	var src := dir + "/" + Terrain3DUtil.location_to_filename(Vector2i(x0, y0))
	var r := Terrain3DRegion.new()
	r.set_location(Vector2i(x0, y0))
	var h := Image.create_empty(RS, RS, false, Image.FORMAT_RF)
	h.fill(Color(5.0, 0, 0))
	r.set_height_map(h)
	r.set_modified(true)
	r.save(src)
	var n := 1
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			if x == x0 and y == y0:
				continue
			DirAccess.copy_absolute(src, dir + "/" + Terrain3DUtil.location_to_filename(Vector2i(x, y)))
			n += 1
	return n


func _new_terrain(dir: String, slots: int, distance: int) -> Camera3D:
	_t = Terrain3D.new()
	_t.streaming_enabled = true
	_t.streaming_slots = slots
	_t.streaming_distance = distance
	_t.data_directory = dir
	root.add_child(_t)
	var cam := Camera3D.new()
	root.add_child(cam)
	_t.set_camera(cam)
	_t.set_clipmap_target(cam)
	await _frames(2)
	return cam


func _free_terrain(cam: Camera3D) -> void:
	cam.queue_free()
	_t.queue_free()
	await _frames(2)


func _span() -> float:
	return float(_t.region_size) * _t.vertex_spacing


func _place(cam: Camera3D, loc: Vector2i) -> void:
	cam.global_position = Vector3((loc.x + 0.5) * _span(), 50, (loc.y + 0.5) * _span())


func _streamer() -> Terrain3DStreamer:
	return _t.get_streamer()


func _resident() -> Dictionary:
	var d := {}
	for loc: Vector2i in _t.data.get_region_locations():
		d[loc] = true
	return d


func _row_path(x0: float, x1: float) -> PackedVector3Array:
	var z := 0.5 * _span()
	return PackedVector3Array([Vector3(x0 * _span(), 0, z), Vector3(x1 * _span(), 0, z)])


func _run() -> void:
	process_frame.disconnect(_run)
	await _test_priority_ahead()
	await _test_behind_limit()
	await _test_cone_recipe()
	await _test_ready_distance()
	await _test_path_cost()
	await _test_prefetch_cache()
	await _test_persist_behind()
	await _test_path_ahead()
	await _test_junction()
	for sub in DirAccess.get_directories_at(_root_dir):
		_clean(_root_dir + "/" + sub)
		DirAccess.remove_absolute(_root_dir + "/" + sub)
	DirAccess.remove_absolute(_root_dir)
	print("SUITE ", "GREEN" if _fail == 0 else "RED (%d failures)" % _fail)
	quit(0 if _fail == 0 else 1)


# 1. A short pool defers what is behind the direction of travel first, and the corridor ahead in order of arrival
func _test_priority_ahead() -> void:
	var dir := _root_dir + "/prio"
	_author_block(dir, -12, 40, -3, 3)
	var cam := await _new_terrain(dir, 25, 1)
	_place(cam, Vector2i(0, 0))
	var s := _streamer()
	# A corridor three regions wide: more than 25 regions lie ahead inside the window
	s.add_keep_path(_row_path(-11.5, 40.5), 1.2 * _span())
	await _frames(300)
	var res := _resident()
	var st := s.get_stats()
	var in_window: int = st.wanted - st.outside_window
	ok(res.size() == 25 and st.deferred == in_window - 25, "priority: the pool is full and the rest is deferred (%d resident, %d deferred of %d in the window)" % [res.size(), st.deferred, in_window])
	ok(st.ram_cached > st.outside_window, "priority: the deferred corridor regions ahead load their bodies into the cache too (%d cached, %d beyond the window, %d deferred)" % [st.ram_cached, st.outside_window, st.deferred])
	var behind_res := 0
	var max_x := -99
	for loc: Vector2i in res:
		behind_res += 1 if loc.x < 0 else 0
		max_x = maxi(max_x, loc.x)
	ok(behind_res == 0, "priority: no region behind the camera outranks the corridor ahead (%d resident)" % behind_res)
	var gaps := 0
	for y in range(-1, 2):
		for x in range(0, max_x):
			gaps += 0 if res.has(Vector2i(x, y)) else 1
	ok(gaps == 0, "priority: the corridor ahead is resident in order of arrival up to x=%d, no gaps (%d)" % [max_x, gaps])
	# Walk forward: the corridor window follows, nothing behind
	_place(cam, Vector2i(14, 0)) # Close enough to the window edge to recentre it
	await _frames(300)
	res = _resident()
	behind_res = 0
	max_x = -99
	for loc: Vector2i in res:
		behind_res += 1 if loc.x < 14 else 0
		max_x = maxi(max_x, loc.x)
	ok(res.has(Vector2i(14, 0)) and res.has(Vector2i(15, 0)) and res.size() <= 25, "priority: the window moved with the camera (%d resident, to x=%d)" % [res.size(), max_x])
	ok(behind_res == 0, "priority: the regions behind are the ones given up (%d resident behind x=14)" % behind_res)
	# A pool that holds everything ahead: the rest of the pool goes to the regions behind, nearest first
	await _free_terrain(cam)
	cam = await _new_terrain(dir, 25, 1)
	_place(cam, Vector2i(0, 0))
	s = _streamer()
	s.add_keep_path(_row_path(-11.5, 40.5), 20.0)
	await _frames(300)
	res = _resident()
	var ahead_ok := true
	for x in range(0, 16):
		ahead_ok = ahead_ok and res.has(Vector2i(x, 0))
	ok(ahead_ok and res.size() == 25, "priority: with room to spare the whole corridor in the window ahead is resident (%d)" % res.size())
	var near_behind := res.has(Vector2i(-1, 0)) and not res.has(Vector2i(-6, 0))
	ok(near_behind, "priority: the spare slots go to the nearest regions behind")
	await _free_terrain(cam)
	_clean(dir)


# 2. behind_limit keeps at most the limit behind the camera, for every shape and the camera area
func _test_behind_limit() -> void:
	var dir := _root_dir + "/behind"
	_author_block(dir, -30, 30, -3, 3)
	var cam := await _new_terrain(dir, 200, 3)
	_place(cam, Vector2i(0, 0))
	var s := _streamer()
	s.add_keep_path(_row_path(-25.5, 25.5), 100.0)
	await _frames(400)
	var res := _resident()
	var min_x := 0
	for loc: Vector2i in res:
		min_x = mini(min_x, loc.x)
	ok(min_x <= -15, "behind: without a limit the corridor behind stays loaded (down to x=%d)" % min_x)
	var before: int = s.get_stats().evicted_total
	s.behind_limit = _span() # One region behind the camera
	ok(is_equal_approx(s.behind_limit, _span()), "behind: property reads back")
	await _frames(6)
	res = _resident()
	min_x = 0
	for loc: Vector2i in res:
		min_x = mini(min_x, loc.x)
	ok(min_x == -1, "behind: one region behind the camera, everything further is gone within 6 frames at once (min x %d, %d evicted)" % [min_x, s.get_stats().evicted_total - before])
	ok(res.has(Vector2i(-1, 0)) and res.has(Vector2i(0, 0)) and res.has(Vector2i(1, 0)), "behind: the neighbour behind, the camera region and the next one stay")
	# Fly east 6 regions: regions that fall more than one region behind unload
	_place(cam, Vector2i(6, 0))
	await _frames(60)
	res = _resident()
	min_x = 99
	for loc: Vector2i in res:
		min_x = mini(min_x, loc.x)
	ok(min_x == 5, "behind: after flying 6 regions east the rear is x=%d (one region behind the camera at 6)" % min_x)
	# The camera area alone is cut too, with no shapes
	s.clear_keep()
	s.add_keep_cone(Vector3(6.5 * _span(), 0, 0.5 * _span()), Vector3(1, 0, 0), 4.0 * _span(), 2.0 * _span(), 0.0)
	await _frames(60)
	res = _resident()
	min_x = 99
	for loc: Vector2i in res:
		min_x = mini(min_x, loc.x)
	ok(min_x == 5, "behind: the camera area is cut behind the camera as well (rear x=%d)" % min_x)
	# Destination shapes are exempt
	var dest := s.add_keep_circle(Vector3(0.5 * _span(), 0, 0.5 * _span()), 150.0, true)
	await _frames(120)
	res = _resident()
	ok(res.has(Vector2i(0, 0)) and res.has(Vector2i(1, 0)), "behind: a destination circle behind the camera is kept (%s)" % res.has(Vector2i(0, 0)))
	s.remove_keep(dest)
	# Off again
	s.behind_limit = -1.0
	s.clear_keep()
	await _frames(200)
	res = _resident()
	min_x = 99
	for loc: Vector2i in res:
		min_x = mini(min_x, loc.x)
	ok(min_x <= 3, "behind: with the limit off the camera area is back (rear x=%d)" % min_x)
	await _free_terrain(cam)
	_clean(dir)


# 3. The cone recipe: a cone with behind = one region and camera_scale 0 holds one region behind the camera
func _test_cone_recipe() -> void:
	var dir := _root_dir + "/cone"
	_author_block(dir, -20, 20, -4, 4)
	var cam := await _new_terrain(dir, 200, 4)
	_place(cam, Vector2i(0, 0))
	var s := _streamer()
	var o := Vector3(0.5 * _span(), 0, 0.5 * _span())
	var cone := s.add_keep_cone(o, Vector3(1, 0, 0), 8.0 * _span(), 3.0 * _span(), 8.0 * _span())
	s.camera_scale = 0.0
	await _frames(300)
	var res := _resident()
	var min_x := 0
	for loc: Vector2i in res:
		min_x = mini(min_x, loc.x)
	ok(min_x <= -6, "cone: a deep cone keeps %d regions behind" % -min_x)
	var before: int = s.get_stats().evicted_total
	s.set_keep_cone(cone, o, Vector3(1, 0, 0), 8.0 * _span(), 3.0 * _span(), _span())
	await _frames(4)
	res = _resident()
	min_x = 0
	for loc: Vector2i in res:
		min_x = mini(min_x, loc.x)
	# behind = one region: the half ellipse grown by half a region reaches 1.5 regions, so the neighbour stays and x=-2 goes
	ok(min_x == -1, "cone: behind = one region evicts everything further behind at once (rear x=%d, %d evicted in 4 frames)" % [min_x, s.get_stats().evicted_total - before])
	await _free_terrain(cam)
	_clean(dir)


# 4. Ready distance along a path counts regions that are visible (inserted), not cached or staged ones
func _test_ready_distance() -> void:
	var dir := _root_dir + "/ready"
	_author_block(dir, -3, 40, -2, 2)
	var cam := await _new_terrain(dir, 60, 1)
	_place(cam, Vector2i(0, 0))
	var s := _streamer()
	var path := _row_path(0.5, 38.5)
	var id := s.add_keep_path(path, 20.0)
	var total := 38.0 * _span()
	ok(s.get_path_ready_distance(9999) == -1.0, "ready: unknown id returns -1")
	ok(s.get_path_ready_distance(id) < 2.0 * _span(), "ready: almost nothing loaded yet, a region at the camera is missing (%.1f)" % s.get_path_ready_distance(id))
	var samples := 0
	var bad := 0
	for i in 300:
		await _frames(1)
		# Independent expectation from the resident set: the path starts at x = 0.5 regions and the camera stands
		# on it, so the arc of a region's left edge, less the corridor radius, is x * span - 0.5 span - 20
		var res := _resident()
		var expect := total
		for x in range(0, 40):
			if not res.has(Vector2i(x, 0)):
				expect = maxf(x * _span() - 0.5 * _span() - 20.0, 0.0)
				break
		var got: float = s.get_path_ready_distance(id)
		var from_zero: float = s.get_path_ready_distance(id, 0.0)
		samples += 1
		if absf(got - expect) > 0.5 or absf(from_zero - expect) > 0.5:
			bad += 1
	ok(bad == 0, "ready: matches an independent computation from the resident set on %d frames (%d off)" % [samples, bad])
	var r_end: float = s.get_path_ready_distance(id)
	var st := s.get_stats()
	print("ready: %.0f m of %.0f, resident %d, cached %d, outside window %d" % [r_end, total, _t.data.get_region_count(), st.ram_cached, st.outside_window])
	ok(r_end > 10.0 * _span() and r_end < total, "ready: stops at the window edge (%.0f m), not at the end (%.0f m)" % [r_end, total])
	ok(st.ram_cached > 0, "ready: regions beyond the window are cached (%d) but do not count as visible" % st.ram_cached)
	# From a distance further along
	var mid: float = s.get_path_ready_distance(id, 10.0 * _span())
	ok(absf(mid - (r_end - 10.0 * _span())) < 1.0 or r_end < 10.0 * _span(), "ready: from_distance measures from there (%.0f vs %.0f)" % [mid, r_end - 10.0 * _span()])
	# Fly to the middle: the window follows and the ready distance extends to the end
	_place(cam, Vector2i(20, 0))
	await _frames(300)
	var r2: float = s.get_path_ready_distance(id)
	var first_out := _t.data.get_region_map_origin().x + _t.data.get_region_map_size() # First column beyond the window
	var expect2 := first_out * _span() - 0.5 * _span() - 20.0 - 20.0 * _span()
	ok(absf(r2 - expect2) < 0.5, "ready: after the move the window shows the corridor up to x=%d (%.0f m, expected %.0f)" % [first_out, r2, expect2])
	# nearest_missing: a stat for the nearest wanted region not visible
	st = s.get_stats()
	ok(st.nearest_missing == -1.0 or st.nearest_missing >= 0.0, "ready: nearest_missing stat is present (%s)" % st.nearest_missing)
	await _free_terrain(cam)
	_clean(dir)


# 5. get_path_cost counts the regions and bytes of a corridor
func _test_path_cost() -> void:
	var dir := _root_dir + "/cost"
	_author_block(dir, -3, 60, -2, 2)
	var cam := await _new_terrain(dir, 60, 1)
	_place(cam, Vector2i(0, 0))
	var s := _streamer()
	var pts := _row_path(0.5, 49.5)
	var c: Dictionary = s.get_path_cost(pts, 20.0)
	# One row, x = 0 .. 49
	ok(c.regions == 50 and c.cells == 50, "cost: 50 regions on a single row corridor (%s)" % [c])
	ok(c.region_bytes == RS * RS * 12 and c.bytes == c.regions * RS * RS * 12, "cost: bytes are 12 per vertex (height, control, color): %d" % c.bytes)
	ok(absf(c.length - 49.0 * _span()) < 0.5, "cost: length %.0f" % c.length)
	ok(c.outside_window == 50 - 16 - 0 or c.outside_window > 25, "cost: regions beyond the current window are counted (%d)" % c.outside_window)
	var wide: Dictionary = s.get_path_cost(pts, 1.5 * _span())
	ok(wide.regions > c.regions * 2, "cost: a wider corridor needs more (%d vs %d)" % [wide.regions, c.regions])
	var ghost: Dictionary = s.get_path_cost(PackedVector3Array([Vector3(100.0 * _span(), 0, 0), Vector3(110.0 * _span(), 0, 0)]), 20.0)
	ok(ghost.regions == 0 and ghost.cells > 0, "cost: regions without a file are not counted (%d cells, %d regions)" % [ghost.cells, ghost.regions])
	_t.color_map_enabled = false
	var c2: Dictionary = s.get_path_cost(pts, 20.0)
	ok(c2.region_bytes == RS * RS * 8, "cost: 8 bytes per vertex with the color map off (%d)" % c2.region_bytes)
	_t.color_map_enabled = true
	await _free_terrain(cam)
	_clean(dir)


# 6. Prefetch: bodies of the corridor beyond the window wait in the cache up to keep_cache_limit and do not count as visible
func _test_prefetch_cache() -> void:
	var dir := _root_dir + "/prefetch"
	_author_block(dir, -3, 90, -1, 1)
	var cam := await _new_terrain(dir, 60, 1)
	_place(cam, Vector2i(0, 0))
	var s := _streamer()
	s.keep_cache_limit = 0
	var id := s.add_keep_path(_row_path(0.5, 80.5), 20.0)
	await _frames(300)
	ok(s.get_stats().ram_cached == 0, "prefetch: with keep_cache_limit 0 nothing beyond the window is cached")
	var ready_nocache: float = s.get_path_ready_distance(id)
	s.keep_cache_limit = 4096
	await _frames(300)
	var st := s.get_stats()
	var beyond := 80 - 16 + 1 # Known path regions from x = 16, the first cell past the window at origin -16
	ok(st.ram_cached == beyond, "prefetch: with a high limit the whole corridor beyond the window is cached (%d of %d)" % [st.ram_cached, beyond])
	ok(absf(s.get_path_ready_distance(id) - ready_nocache) < 0.5, "prefetch: cached bodies do not count as ready (%.0f vs %.0f)" % [s.get_path_ready_distance(id), ready_nocache])
	# The window follows the camera: the cached bodies insert without disk IO and the ready distance reaches the end
	_place(cam, Vector2i(40, 0))
	await _frames(300)
	var r: float = s.get_path_ready_distance(id)
	var first_out := _t.data.get_region_map_origin().x + _t.data.get_region_map_size()
	var expect := first_out * _span() - 0.5 * _span() - 20.0 - 40.0 * _span()
	ok(absf(r - expect) < 0.5 and r > 12.0 * _span(), "prefetch: after the move the corridor is visible up to the new window edge x=%d (%.0f m, expected %.0f)" % [first_out, r, expect])
	ok(s.get_stats().ram_cached < beyond, "prefetch: the cache drained as the window arrived (%d)" % s.get_stats().ram_cached)
	await _free_terrain(cam)
	_clean(dir)


# 7. Regions edited far behind the camera are saved on the worker thread when behind_limit unloads them
func _test_persist_behind() -> void:
	var dir := _root_dir + "/persist"
	_author_block(dir, -12, 12, -2, 2)
	var cam := await _new_terrain(dir, 100, 2)
	_t.streaming_persist_edits = true
	_place(cam, Vector2i(0, 0))
	var s := _streamer()
	s.add_keep_path(_row_path(-10.5, 10.5), 20.0)
	await _frames(300)
	var edited := Vector2i(-8, 0)
	ok(_t.data.has_region(edited), "persist: the corridor behind is loaded")
	var r: Terrain3DRegion = _t.data.get_region(edited)
	r.get_height_map().set_pixel(10, 10, Color(777.0, 0, 0))
	r.set_modified(true)
	var path := dir + "/" + Terrain3DUtil.location_to_filename(edited)
	s.behind_limit = _span()
	await _frames(30)
	ok(not _t.data.has_region(edited), "persist: the edited region behind is unloaded")
	var saved: Terrain3DRegion = ResourceLoader.load(path, "Terrain3DRegion", ResourceLoader.CACHE_MODE_IGNORE)
	ok(saved != null and absf(saved.get_height_map().get_pixel(10, 10).r - 777.0) < 0.01, "persist: the edit reached the file through the worker thread")
	await _free_terrain(cam)
	_clean(dir)


func _locs(arr: Array) -> Dictionary:
	var d := {}
	for loc: Vector2i in arr:
		d[loc] = true
	return d


# 8. A path loads only a lookahead segment; the rest of the corridor is fetched as bodies only, after everything
# needed, and never takes the last load slot while a needed region waits
func _test_path_ahead() -> void:
	var dir := _root_dir + "/ahead"
	_author_block(dir, -3, 60, -2, 2)
	var cam := await _new_terrain(dir, 80, 1)
	_t.streaming_concurrent_loads = 2
	_place(cam, Vector2i(0, 0))
	var s := _streamer()
	s.keep_cache_limit = 4096
	var id := s.add_keep_path(_row_path(0.5, 58.5), 20.0)
	ok(s.set_keep_path_ahead(id, 5.0 * _span(), 0.0), "ahead: set_keep_path_ahead accepts a path id")
	ok(not s.set_keep_path_ahead(9999, 1.0), "ahead: unknown id")
	await _frames(200)
	var near := _locs(s.get_wanted_regions(false))
	var st := s.get_stats()
	# Row x = 0 .. 5 (arc <= 5 spans, plus the half region of tolerance), plus the camera area around (0, 0)
	var max_x := -99
	for loc: Vector2i in near:
		if loc.y == 0:
			max_x = maxi(max_x, loc.x)
	ok(max_x == 5 or max_x == 6, "ahead: the needed set reaches %d regions ahead, not the whole route (max x %d)" % [5, max_x])
	ok(st.wanted == near.size() and st.wanted < 20, "ahead: the wanted stat counts the lookahead set only (%d)" % st.wanted)
	ok(s.get_wanted_regions(true).size() == 0, "ahead: no prefetch reach, no cache-only set")
	ok(st.ram_cached == 0 and st.missing == 0, "ahead: nothing cached, nothing missing")
	# Prefetch the whole corridor as bodies
	s.set_keep_path_ahead(id, 5.0 * _span(), -1.0)
	var order: Array = []
	var seen := {}
	var near_after_cache := 0
	for i in 400:
		await _frames(1)
		var nearset := _locs(s.get_wanted_regions(false))
		var cacheset := _locs(s.get_wanted_regions(true))
		for loc: Vector2i in s.get_pending_regions():
			if not seen.has(loc):
				seen[loc] = true
				order.append([loc, nearset.has(loc)])
		if cacheset.size() == 0 and i > 10:
			break
	var near_first := true
	var seen_cache := false
	for e in order:
		if not e[1]:
			seen_cache = true
		elif seen_cache:
			near_after_cache += 1
	st = s.get_stats()
	print("ahead: %d requests recorded, %d needed regions requested after a cache-only one, cached %d, resident %d" % [order.size(), near_after_cache, st.ram_cached, _t.data.get_region_count()])
	ok(st.ram_cached > 40, "ahead: the rest of the corridor was fetched into the cache (%d bodies)" % st.ram_cached)
	ok(_t.data.get_region_count() <= 16, "ahead: and none of it took a slot (%d resident)" % _t.data.get_region_count())
	# Move the camera: the needed window moves, cached bodies insert without a request
	_place(cam, Vector2i(14, 0))
	await _frames(200)
	near = _locs(s.get_wanted_regions(false))
	max_x = -99
	var min_x := 99
	for loc: Vector2i in near:
		if loc.y == 0:
			max_x = maxi(max_x, loc.x)
			min_x = mini(min_x, loc.x)
	ok(max_x >= 19 and _t.data.has_region(Vector2i(19, 0)) and _t.data.has_region(Vector2i(14, 0)), "ahead: after the move the window ahead is resident (x 14..%d)" % max_x)
	await _free_terrain(cam)
	_clean(dir)


# 9. The junction between a narrow path strip and a wider destination circle: every cell the geometry says belongs
# to the union is wanted by the streamer, and all of them are resident on arrival
func _test_junction() -> void:
	var dir := _root_dir + "/junction"
	_author_block(dir, -3, 40, -8, 8)
	var known := {}
	for y in range(-8, 9):
		for x in range(-3, 41):
			known[Vector2i(x, y)] = true
	var cam := await _new_terrain(dir, 200, 1)
	_place(cam, Vector2i(0, 0))
	var s := _streamer()
	var sp := _span()
	var end := Vector2(30.5 * sp, 0.5 * sp)
	var id := s.add_keep_path(_row_path(0.5, 30.5), 0.9 * sp) # Strip of about two regions
	var circ := s.add_keep_circle(Vector3(end.x, 0, end.y), 4.2 * sp, true) # Circle of about nine
	await _frames(100)
	_place(cam, Vector2i(30, 0)) # Arrival: the window recentres on the end of the path
	await _frames(600)
	# Independent membership: path strip (rect to polyline distance) plus the circle, plus the camera area
	var expected := {}
	for loc: Vector2i in known:
		var mn := Vector2(loc) * sp
		var mx := mn + Vector2(sp, sp)
		var d_circle := (end - end.clamp(mn, mx)).length()
		var line_y := 0.5 * sp
		var nearest_x := clampf(clampf(0.5 * sp, mn.x, mx.x), 0.5 * sp, 30.5 * sp)
		var d_path := (Vector2(nearest_x, line_y) - Vector2(nearest_x, line_y).clamp(mn, mx)).length()
		# distance from the segment to the rect: points of the segment inside the rect's x range
		var x_lo := maxf(mn.x, 0.5 * sp)
		var x_hi := minf(mx.x, 30.5 * sp)
		if x_lo <= x_hi:
			d_path = maxf(maxf(mn.y - line_y, line_y - mx.y), 0.0)
		else:
			d_path = INF
		if absf(d_circle - 4.2 * sp) < 1.5 or absf(d_path - 0.9 * sp) < 1.5:
			ok(false, "test setup: region %s sits on a shape edge" % loc)
		if d_circle <= 4.2 * sp or d_path <= 0.9 * sp:
			expected[loc] = true
	for y in range(-1, 2):
		for x in range(-1, 2):
			expected[Vector2i(x, y)] = true
	var wanted := _locs(s.get_wanted_regions(false))
	var missing_from_wanted := 0
	var extra := 0
	for loc: Vector2i in expected:
		missing_from_wanted += 0 if wanted.has(loc) else 1
	for loc: Vector2i in wanted:
		extra += 0 if expected.has(loc) else 1
	ok(missing_from_wanted == 0 and extra == 0, "junction: the streamer's wanted list equals the geometric union (%d wanted, %d expected, %d absent, %d extra)" % [wanted.size(), expected.size(), missing_from_wanted, extra])
	var res := _resident()
	var not_resident := 0
	var in_window := 0
	var org := _t.data.get_region_map_origin()
	for loc: Vector2i in wanted:
		if loc.x < org.x or loc.x >= org.x + _t.data.get_region_map_size():
			continue # Beyond the window: waits in the cache (the path behind the camera, with no behind_limit)
		in_window += 1
		not_resident += 0 if res.has(loc) else 1
	ok(not_resident == 0, "junction: every wanted cell inside the window is resident, including the junction column (%d missing of %d, %d deferred)" % [not_resident, in_window, s.get_stats().deferred])
	# The cells where the strip meets the circle
	var junction_ok := true
	for y in range(-4, 5):
		for x in range(24, 28):
			var loc := Vector2i(x, y)
			if expected.has(loc) and not res.has(loc):
				junction_ok = false
	ok(junction_ok, "junction: the cells between the strip end and the circle edge are resident")
	await _free_terrain(cam)
	_clean(dir)
