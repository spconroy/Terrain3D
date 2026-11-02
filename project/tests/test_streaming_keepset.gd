extends SceneTree
## Headless test for the streamer's keep set (union of keep shapes, early eviction, deferral):
##   godot --headless --path project --script res://tests/test_streaming_keepset.gd
## Covers: unchanged default behaviour, circle / path / cone membership against an independent
## computation, load order (destination, then path in order of arrival), early eviction when a shape
## shrinks or goes away, the hysteresis baseline, pool deferral, edited regions saved before eviction,
## clear_keep, shapes beyond the region map window, and a 10 km flight at 2.5 km/s on 512 m regions.
var _fail := 0
var _t: Terrain3D
var _root_dir := "user://keepset_test_%d" % OS.get_process_id()


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
		# Headless never emits frame_pre_draw, so pump the instancer queue like a renderer would
		RenderingServer.emit_signal("frame_pre_draw")


func _clean(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + f)


## Writes one flat region at (x0, y0), then clones its file to every other location of the block.
## The streamer sets the location after loading, so clones are valid regions of their own.
func _author_block(dir: String, rs: int, x0: int, x1: int, y0: int, y1: int, noisy: bool = false) -> int:
	DirAccess.make_dir_recursive_absolute(dir)
	var src := dir + "/" + Terrain3DUtil.location_to_filename(Vector2i(x0, y0))
	var r := Terrain3DRegion.new()
	r.set_location(Vector2i(x0, y0))
	var h := Image.create_empty(rs, rs, false, Image.FORMAT_RF)
	h.fill(Color(5.0, 0, 0))
	if noisy:
		# Realistic payload: height, control and color all carry noise, so files are large
		# and decode and upload cost what a real region costs
		var noise := FastNoiseLite.new()
		noise.frequency = 0.01
		h = noise.get_image(rs, rs)
		h.convert(Image.FORMAT_RF)
		var ctl := noise.get_image(rs, rs)
		ctl.convert(Image.FORMAT_RF)
		r.set_control_map(ctl)
		var col := Image.create_from_data(rs, rs, false, Image.FORMAT_RGBA8, Crypto.new().generate_random_bytes(rs * rs * 4))
		col.generate_mipmaps()
		r.set_color_map(col)
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


func _new_terrain(dir: String, slots: int, distance: int, shape: int = Terrain3DStreamer.SQUARE) -> Camera3D:
	_t = Terrain3D.new()
	_t.streaming_enabled = true
	_t.streaming_shape = shape
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


func _same(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k):
			return false
	return true


## Waits until the resident set equals expected and then stays equal for 10 frames
func _wait_for(expected: Dictionary, max_frames: int) -> bool:
	var stable := 0
	for i in max_frames:
		await _frames(1)
		if _same(_resident(), expected):
			stable += 1
			if stable >= 10:
				return true
		else:
			stable = 0
	return false


func _wait_count(n: int, max_frames: int) -> bool:
	for i in max_frames:
		await _frames(1)
		if _t.data.get_region_count() == n:
			await _frames(10)
			return _t.data.get_region_count() == n
	return false


## Square or circle of regions around a centre, in region units (the streamer's own rule)
func _area(centre: Vector2i, radius: float, circle: bool, known: Dictionary) -> Dictionary:
	var d := {}
	var r := int(ceil(radius))
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var dist := Vector2(dx, dy).length() if circle else float(maxi(absi(dx), absi(dy)))
			var loc := centre + Vector2i(dx, dy)
			if dist <= radius and known.has(loc):
				d[loc] = true
	return d


func _known_block(x0: int, x1: int, y0: int, y1: int) -> Dictionary:
	var k := {}
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			k[Vector2i(x, y)] = true
	return k


func _union(a: Dictionary, b: Dictionary) -> Dictionary:
	var d := a.duplicate()
	d.merge(b)
	return d


func _rect_dist(loc: Vector2i, p: Vector2) -> float:
	var s := _span()
	var mn := Vector2(loc) * s
	return (p - p.clamp(mn, mn + Vector2(s, s))).length()


func _circle_set(c: Vector2, r: float, known: Dictionary) -> Dictionary:
	var d := {}
	for loc: Vector2i in known:
		if _rect_dist(loc, c) <= r:
			d[loc] = true
	return d


## Corridor membership by dense sampling along the polyline, independent of the streamer's
## closed form. Fails the test if a region sits within 1.5 m of the corridor edge.
func _path_set(pts: Array[Vector2], r: float, known: Dictionary) -> Dictionary:
	var d := {}
	for loc: Vector2i in known:
		var best := INF
		for i in pts.size() - 1:
			var seg_len := pts[i].distance_to(pts[i + 1])
			var steps := int(seg_len)
			for k in steps + 1:
				best = minf(best, _rect_dist(loc, pts[i].lerp(pts[i + 1], float(k) / maxf(steps, 1))))
		if absf(best - r) < 1.5:
			ok(false, "test setup: region %s lies on the corridor edge (%.2f vs %.2f)" % [loc, best, r])
		if best <= r:
			d[loc] = true
	return d


## The documented cone rule: region centre inside the half ellipses grown by half a region, or the origin's region
func _cone_set(o: Vector2, dir: Vector2, length: float, hw: float, behind: float, known: Dictionary) -> Dictionary:
	var d := {}
	var s := _span()
	dir = dir.normalized()
	var perp := Vector2(-dir.y, dir.x)
	for loc: Vector2i in known:
		if _rect_dist(loc, o) == 0.0:
			d[loc] = true
			continue
		var q := (Vector2(loc) + Vector2(0.5, 0.5)) * s - o
		var a := q.dot(dir)
		var b := q.dot(perp)
		var ax := (length if a >= 0.0 else behind) + s * 0.5
		var bx := hw + s * 0.5
		if a * a / (ax * ax) + b * b / (bx * bx) <= 1.0:
			d[loc] = true
	return d


func _run() -> void:
	process_frame.disconnect(_run)
	await _test_default_parity()
	await _test_membership()
	await _test_load_order()
	await _test_eviction_and_baseline()
	await _test_pool_deferred()
	await _test_edit_saved()
	await _test_outside_window()
	await _test_flight()
	for sub in DirAccess.get_directories_at(_root_dir):
		_clean(_root_dir + "/" + sub)
		DirAccess.remove_absolute(_root_dir + "/" + sub)
	DirAccess.remove_absolute(_root_dir)
	print("SUITE ", "GREEN" if _fail == 0 else "RED (%d failures)" % _fail)
	quit(0 if _fail == 0 else 1)


# 1. With no keep shapes the streamer behaves as before: the focus area, nothing else
func _test_default_parity() -> void:
	var dir := _root_dir + "/default"
	_author_block(dir, 64, -8, 8, -8, 8)
	var known := _known_block(-8, 8, -8, 8)
	for circle in [false, true]:
		var shape: int = Terrain3DStreamer.CIRCLE if circle else Terrain3DStreamer.SQUARE
		var cam := await _new_terrain(dir, 100, 2, shape)
		var s := _streamer()
		ok(s.get_keep_count() == 0 and is_equal_approx(s.camera_scale, 1.0), "default %s: no keep shapes, camera scale 1" % shape)
		_place(cam, Vector2i(0, 0))
		var want := _area(Vector2i(0, 0), 2.0, circle, known)
		ok(await _wait_for(want, 400), "default %s: exactly the focus area loads (%d of %d)" % [shape, _t.data.get_region_count(), want.size()])
		var st := s.get_stats()
		ok(st.deferred == 0 and st.outside_window == 0 and st.keep_shapes == 0, "default %s: stats report no deferral (%s)" % [shape, st])
		# One region east: the new area loads, the old area keeps one region of hysteresis
		_place(cam, Vector2i(1, 0))
		var expect := _union(_area(Vector2i(1, 0), 2.0, circle, known), {})
		for loc: Vector2i in want:
			if (Vector2(loc - Vector2i(1, 0)).length() if circle else float(maxi(absi(loc.x - 1), absi(loc.y)))) <= 3.0:
				expect[loc] = true
		ok(await _wait_for(expect, 400), "default %s: one region east keeps the hysteresis band (%d of %d)" % [shape, _t.data.get_region_count(), expect.size()])
		# Far teleport: the old area evicts entirely
		_place(cam, Vector2i(6, 6))
		var far := _area(Vector2i(6, 6), 2.0, circle, known)
		ok(await _wait_for(far, 600), "default %s: teleport replaces the area (%d of %d)" % [shape, _t.data.get_region_count(), far.size()])
		await _free_terrain(cam)
	_clean(dir)


# 2. Circle, path and cone membership, with the camera area removed so only the shapes load
func _test_membership() -> void:
	var dir := _root_dir + "/members"
	_author_block(dir, 64, -12, 12, -12, 12)
	var known := _known_block(-12, 12, -12, 12)
	var s64 := 64.0
	var cam := await _new_terrain(dir, 441, 2)
	_place(cam, Vector2i(0, 0))
	var s := _streamer()
	s.camera_scale = 0.0
	await _frames(10)
	ok(_t.data.get_region_count() == 0, "members: camera scale 0 and no shapes keeps nothing (%d)" % _t.data.get_region_count())
	# Circle
	var cc := Vector2(-7.5 * s64, -6.5 * s64)
	var id_c := s.add_keep_circle(Vector3(cc.x, 0, cc.y), 150.0)
	var want_c := _circle_set(cc, 150.0, known)
	ok(id_c > 0 and want_c.size() > 5, "members: circle id %d covers %d regions" % [id_c, want_c.size()])
	ok(await _wait_for(want_c, 600), "members: circle loads exactly its footprint (%d of %d)" % [_t.data.get_region_count(), want_c.size()])
	# Path, a corridor with a bend
	var pts: Array[Vector2] = [Vector2(-3.5 * s64, 6.5 * s64), Vector2(2.5 * s64, 6.5 * s64), Vector2(6.5 * s64, 2.0 * s64)]
	var pv := PackedVector3Array()
	for p in pts:
		pv.append(Vector3(p.x, 0, p.y))
	var id_p := s.add_keep_path(pv, 70.0)
	var want_p := _path_set(pts, 70.0, known)
	ok(id_p > 0 and id_p != id_c and want_p.size() > 8, "members: path id %d covers %d regions" % [id_p, want_p.size()])
	var union := _union(want_c, want_p)
	ok(await _wait_for(union, 800), "members: circle + path = exact union (%d of %d)" % [_t.data.get_region_count(), union.size()])
	# Cone pointing south-east from the middle
	var co := Vector2(0.5 * s64, -3.5 * s64)
	var cdir := Vector2(1, 1).normalized()
	var id_k := s.add_keep_cone(Vector3(co.x, 0, co.y), Vector3(cdir.x, 0, cdir.y), 400.0, 130.0, 64.0)
	var want_k := _cone_set(co, cdir, 400.0, 130.0, 64.0, known)
	ok(id_k > 0 and want_k.size() > 8, "members: cone id %d covers %d regions" % [id_k, want_k.size()])
	union = _union(union, want_k)
	ok(await _wait_for(union, 800), "members: circle + path + cone = exact union (%d of %d)" % [_t.data.get_region_count(), union.size()])
	var st := s.get_stats()
	ok(st.wanted == union.size() and st.missing == 0 and st.keep_shapes == 3 and st.outside_window == 0, "members: stats agree (%s)" % st)
	# The cone is aimed: a cone pointing the other way covers different regions
	var back := _cone_set(co, -cdir, 400.0, 130.0, 64.0, known)
	ok(not _same(back, want_k), "members: direction matters")
	# Removing one shape keeps the others
	s.remove_keep(id_k)
	union = _union(want_c, want_p)
	ok(await _wait_for(union, 400), "members: remove_keep(cone) leaves circle + path (%d of %d)" % [_t.data.get_region_count(), union.size()])
	ok(s.get_keep_count() == 2, "members: two shapes left")
	s.remove_keep(9999) # Unknown ids are ignored
	await _free_terrain(cam)
	_clean(dir)


# 3. Load order: destination first, then the path in order of arrival (nearest the camera first)
func _test_load_order() -> void:
	var dir := _root_dir + "/order"
	_author_block(dir, 64, -12, 12, -4, 4)
	var known := _known_block(-12, 12, -4, 4)
	var cam := await _new_terrain(dir, 300, 2)
	_t.streaming_concurrent_loads = 1 # One request at a time: landing order is request order
	_t.streaming_loads_per_frame = 1
	_place(cam, Vector2i(-8, 0)) # On the path start, so everything on the path is ahead
	var s := _streamer()
	await _wait_count(25, 400)
	s.camera_scale = 0.0
	await _frames(20)
	ok(_t.data.get_region_count() == 0, "order: starts empty")
	var s64 := 64.0
	var y := 0.5 * s64
	var pv := PackedVector3Array([Vector3(-7.5 * s64, 0, y), Vector3(7.5 * s64, 0, y)])
	var dest := Vector2(7.5 * s64, y)
	var near := Vector2(-6.5 * s64, 2.5 * s64)
	# Add in the order that would load worst: normal circle, path, then the destination
	s.add_keep_circle(Vector3(near.x, 0, near.y), 90.0)
	s.add_keep_path(pv, 30.0)
	s.add_keep_circle(Vector3(dest.x, 0, dest.y), 100.0, true)
	var d_set := _circle_set(dest, 100.0, known)
	var p_set := _path_set([Vector2(-7.5 * s64, y), Vector2(7.5 * s64, y)], 30.0, known)
	var n_set := _circle_set(near, 90.0, known)
	var union := _union(_union(d_set, p_set), n_set)
	ok(await _wait_for(union, 1200), "order: all three shapes loaded (%d of %d)" % [_t.data.get_region_count(), union.size()])
	var seq: Array[Vector2i] = []
	for loc: Vector2i in _t.data.get_region_locations():
		seq.append(loc)
	var last_dest := -1
	var first_path := 1 << 30
	var last_path := -1
	var first_norm := 1 << 30
	var path_x: Array[int] = []
	for i in seq.size():
		var loc := seq[i]
		if d_set.has(loc):
			last_dest = maxi(last_dest, i)
		elif p_set.has(loc):
			first_path = mini(first_path, i)
			last_path = maxi(last_path, i)
			path_x.append(loc.x)
		else:
			first_norm = mini(first_norm, i)
	ok(last_dest < first_path, "order: every destination region (last at %d) loads before any path region (first at %d)" % [last_dest, first_path])
	ok(last_path < first_norm, "order: every path region (last at %d) loads before the other shapes (first at %d)" % [last_path, first_norm])
	var sorted_x := path_x.duplicate()
	sorted_x.sort()
	ok(path_x == sorted_x and path_x.size() > 5, "order: the path loads in order of arrival along it (%s)" % [path_x])
	await _free_terrain(cam)
	_clean(dir)


# 4. Early eviction when a shape shrinks or goes away, and the new union is the hysteresis baseline
func _test_eviction_and_baseline() -> void:
	var dir := _root_dir + "/evict"
	_author_block(dir, 64, -12, 12, -12, 12)
	var known := _known_block(-12, 12, -12, 12)
	var cam := await _new_terrain(dir, 200, 4)
	_place(cam, Vector2i(0, 0))
	var s := _streamer()
	ok(await _wait_for(_area(Vector2i(0, 0), 4.0, false, known), 800), "evict: distance 4 area loaded (%d)" % _t.data.get_region_count())
	# The camera area shrinks to half: the 5x5 core stays, the rest goes at once, no hysteresis band
	s.camera_scale = 0.5
	ok(await _wait_for(_area(Vector2i(0, 0), 2.0, false, known), 60), "evict: scale 0.5 evicts to the strict 5x5 (%d)" % _t.data.get_region_count())
	# Hysteresis resumes from the new baseline: step one region east and the column left behind stays
	_place(cam, Vector2i(1, 0))
	var expect := _area(Vector2i(1, 0), 2.0, false, known)
	for loc: Vector2i in _area(Vector2i(0, 0), 2.0, false, known):
		if absi(loc.x - 1) <= 3:
			expect[loc] = true
	ok(await _wait_for(expect, 400), "evict: hysteresis band works from the new baseline (%d of %d)" % [_t.data.get_region_count(), expect.size()])
	# Growing back is not an eviction and loads the rest
	s.camera_scale = 1.0
	ok(await _wait_for(_union(_area(Vector2i(1, 0), 4.0, false, known), expect), 800), "evict: scale 1 grows back (%d)" % _t.data.get_region_count())
	# A shrinking cone evicts what it no longer covers; moving or growing it does not
	s.camera_scale = 0.0
	await _frames(5)
	ok(_t.data.get_region_count() == 0, "evict: scale 0 empties a terrain with no shapes (%d)" % _t.data.get_region_count())
	var o := Vector2(0.5 * 64.0, 0.5 * 64.0)
	var id := s.add_keep_cone(Vector3(o.x, 0, o.y), Vector3(1, 0, 0), 600.0, 150.0, 64.0)
	var big := _cone_set(o, Vector2(1, 0), 600.0, 150.0, 64.0, known)
	ok(await _wait_for(big, 800), "evict: cone loaded (%d of %d)" % [_t.data.get_region_count(), big.size()])
	ok(s.set_keep_cone(id, Vector3(o.x, 0, o.y), Vector3(1, 0, 0), 300.0, 150.0, 64.0), "evict: set_keep_cone accepts a known id")
	var small := _cone_set(o, Vector2(1, 0), 300.0, 150.0, 64.0, known)
	ok(await _wait_for(small, 60), "evict: shorter cone evicts the far end at once (%d of %d)" % [_t.data.get_region_count(), small.size()])
	ok(not s.set_keep_circle(id, Vector3(), 10.0), "evict: set_keep_circle refuses a cone id")
	# Remove: the cone's regions go, the baseline is strict
	s.remove_keep(id)
	ok(await _wait_for({}, 60), "evict: remove_keep evicts what only it kept (%d)" % _t.data.get_region_count())
	# clear_keep restores the default focus area
	s.add_keep_circle(Vector3(5 * 64, 0, 5 * 64), 80.0)
	s.camera_scale = 0.2
	await _frames(10)
	s.clear_keep()
	ok(s.get_keep_count() == 0 and is_equal_approx(s.camera_scale, 1.0), "clear: no shapes, camera scale back to 1")
	ok(await _wait_for(_area(Vector2i(1, 0), 4.0, false, known), 800), "clear: default focus area restored (%d)" % _t.data.get_region_count())
	await _free_terrain(cam)
	_clean(dir)


# 5. A pool smaller than the union keeps the regions nearest the camera and reports the rest
func _test_pool_deferred() -> void:
	var dir := _root_dir + "/pool"
	_author_block(dir, 64, -12, 12, -6, 6)
	var known := _known_block(-12, 12, -6, 6)
	var cam := await _new_terrain(dir, 25, 1)
	_place(cam, Vector2i(-8, 0))
	var s := _streamer()
	ok(_t.data.get_slot_capacity() == 25, "pool: 25 slots")
	var pv := PackedVector3Array([Vector3(-8.5 * 64, 0, 0.5 * 64), Vector3(9.5 * 64, 0, 0.5 * 64)])
	var p_set := _path_set([Vector2(-8.5 * 64, 0.5 * 64), Vector2(9.5 * 64, 0.5 * 64)], 105.0, known)
	s.add_keep_path(pv, 105.0)
	var union := _union(p_set, _area(Vector2i(-8, 0), 1.0, false, known))
	ok(union.size() > 25, "pool: the union needs %d slots, more than 25" % union.size())
	await _frames(300)
	var st := s.get_stats()
	ok(st.wanted == union.size(), "pool: wanted %d == %d" % [st.wanted, union.size()])
	ok(st.deferred == union.size() - 25, "pool: deferred %d == union %d - 25 slots" % [st.deferred, union.size()])
	ok(_t.data.get_region_count() == 25 and _t.data.get_free_slot_count() == 0, "pool: 25 resident, none free (%d)" % _t.data.get_region_count())
	# Nearest to the camera first: every resident is at least as near as every deferred region
	var cam_loc := Vector2i(-8, 0)
	var far_res := 0.0
	for loc: Vector2i in _resident():
		far_res = maxf(far_res, float(maxi(absi(loc.x - cam_loc.x), absi(loc.y - cam_loc.y))))
	var near_def := INF
	var res := _resident()
	for loc: Vector2i in union:
		if not res.has(loc):
			near_def = minf(near_def, float(maxi(absi(loc.x - cam_loc.x), absi(loc.y - cam_loc.y))))
	ok(far_res <= near_def, "pool: residents reach %.0f regions out, deferred start at %.0f" % [far_res, near_def])
	ok(st.missing == 0, "pool: nothing admitted is still missing (%d)" % st.missing)
	# Moving the camera forward trades the far end for the near end, no slot leak
	_place(cam, Vector2i(4, 0))
	await _frames(300)
	res = _resident()
	ok(res.has(Vector2i(4, 0)) and res.has(Vector2i(5, 0)) and _t.data.get_region_count() <= 25, "pool: the window follows the camera along the path (%d)" % _t.data.get_region_count())
	ok(_t.data.get_free_slot_count() + _t.data.get_region_count() == 25, "pool: no slot leaked")
	await _free_terrain(cam)
	_clean(dir)


# 6. An edited region is written back before an early eviction drops it
func _test_edit_saved() -> void:
	var dir := _root_dir + "/edit"
	_author_block(dir, 64, -4, 4, -4, 4)
	var known := _known_block(-4, 4, -4, 4)
	var cam := await _new_terrain(dir, 100, 2)
	_t.streaming_persist_edits = true
	_place(cam, Vector2i(0, 0))
	var s := _streamer()
	ok(await _wait_for(_area(Vector2i(0, 0), 2.0, false, known), 400), "edit: area loaded")
	var edited := Vector2i(0, 1)
	var r: Terrain3DRegion = _t.data.get_region(edited)
	r.get_height_map().set_pixel(10, 10, Color(777.0, 0, 0))
	r.set_modified(true)
	var untouched := Vector2i(0, -1)
	var path := dir + "/" + Terrain3DUtil.location_to_filename(edited)
	var before := FileAccess.get_modified_time(path)
	# The camera area shrinks to nothing: both regions evict, only the edited one is written
	s.camera_scale = 0.0
	ok(await _wait_for({}, 60), "edit: everything evicted (%d)" % _t.data.get_region_count())
	var saved: Terrain3DRegion = ResourceLoader.load(path, "Terrain3DRegion", ResourceLoader.CACHE_MODE_IGNORE)
	ok(saved != null and absf(saved.get_height_map().get_pixel(10, 10).r - 777.0) < 0.01, "edit: the edit reached the file before the eviction (%s)" % [saved.get_height_map().get_pixel(10, 10).r if saved else -1])
	ok(FileAccess.get_modified_time(path) >= before, "edit: the file was rewritten")
	# And it reloads with the edit
	s.clear_keep()
	ok(await _wait_for(_area(Vector2i(0, 0), 2.0, false, known), 400), "edit: area reloads")
	ok(absf(_t.data.get_region(edited).get_height_map().get_pixel(10, 10).r - 777.0) < 0.01, "edit: the edit survives the round trip")
	ok(absf(_t.data.get_region(untouched).get_height_map().get_pixel(10, 10).r - 5.0) < 0.01, "edit: neighbours unchanged")
	await _free_terrain(cam)
	_clean(dir)


# 7. A shape beyond the region map window prefetches its bodies and inserts them once the window arrives
func _test_outside_window() -> void:
	var dir := _root_dir + "/window"
	_author_block(dir, 64, -20, 30, -3, 3)
	var known := _known_block(-20, 30, -3, 3)
	var cam := await _new_terrain(dir, 200, 2)
	_place(cam, Vector2i(0, 0))
	var s := _streamer()
	ok(await _wait_for(_area(Vector2i(0, 0), 2.0, false, known), 400), "window: focus area loaded")
	ok(_t.data.get_region_map_origin() == Vector2i(-16, -16), "window: default origin")
	var dc := Vector2(22.5 * 64.0, 0.5 * 64.0)
	s.add_keep_circle(Vector3(dc.x, 0, dc.y), 100.0, true)
	var d_set := _circle_set(dc, 100.0, known)
	await _frames(200)
	var st := s.get_stats()
	ok(st.outside_window == d_set.size() and st.wanted == d_set.size() + 25, "window: %d destination regions lie beyond the window (%s)" % [d_set.size(), st])
	var any_resident := false
	for loc: Vector2i in d_set:
		any_resident = any_resident or _t.data.has_region(loc)
	ok(not any_resident, "window: none of them takes a slot")
	ok(st.ram_cached == d_set.size(), "window: their bodies wait in the cache (%d of %d)" % [st.ram_cached, d_set.size()])
	ok(_t.data.get_region_count() == 25, "window: the pool still holds only the focus area (%d)" % _t.data.get_region_count())
	# Fly east: the window recentres, the destination comes into it and inserts from the cache
	_place(cam, Vector2i(14, 0))
	var want := _union(d_set, _area(Vector2i(14, 0), 2.0, false, known))
	ok(await _wait_for(want, 800), "window: destination and the new focus area are resident (%d of %d)" % [_t.data.get_region_count(), want.size()])
	ok(_t.data.get_region_map_origin() != Vector2i(-16, -16), "window: the window recentred on the camera, %s" % _t.data.get_region_map_origin())
	st = s.get_stats()
	ok(st.ram_cached == 0 and st.outside_window == 0, "window: cache drained (%s)" % st)
	# Back to the start: the destination is outside again and evicts; its bodies reload into the cache
	_place(cam, Vector2i(0, 0))
	ok(await _wait_for(_area(Vector2i(0, 0), 2.0, false, known), 800), "window: back home, the destination slots are free again (%d)" % _t.data.get_region_count())
	await _free_terrain(cam)
	_clean(dir)


## Distance flown after t seconds: 1 s ramp up to speed, cruise, 1 s ramp down. 10 km at 2.5 km/s takes 5 s.
func _flight_x(t: float, v: float, d: float) -> float:
	var ramp := 1.0
	var total := d / v + ramp
	if t >= total:
		return d
	if t < ramp:
		return 0.5 * v * t * t / ramp
	if t < total - ramp:
		return 0.5 * v * ramp + v * (t - ramp)
	var u := t - (total - ramp)
	return 0.5 * v * ramp + v * (total - 2.0 * ramp) + v * u - 0.5 * v * u * u / ramp


# 8. A 10 km flight at 2.5 km/s on 512 m regions, with and without the keep set
func _test_flight() -> void:
	var dir := _root_dir + "/flight"
	var n := _author_block(dir, 512, -3, 26, -2, 2, true)
	var bytes := FileAccess.get_file_as_bytes(dir + "/" + Terrain3DUtil.location_to_filename(Vector2i(0, 0))).size()
	ok(n == 150, "flight: %d cloned region files at 512 m, %.1f MB each" % [n, bytes / 1048576.0])
	var res := {}
	for cfg in [["keep conc4 lpf2", true, 4, 2], ["default conc4 lpf2", false, 4, 2], ["keep conc3 lpf1", true, 3, 1], ["default conc3 lpf1", false, 3, 1], ["keep conc1 lpf1", true, 1, 1], ["default conc1 lpf1", false, 1, 1], ["default d1 conc3 lpf1", false, 3, 1, 1], ["default d1 conc1 lpf1", false, 1, 1, 1]]:
		res[cfg[0]] = await _fly(dir, cfg[0], cfg[1], cfg[2], cfg[3], cfg[4] if cfg.size() > 4 else 2)
	var k: Dictionary = res["keep conc4 lpf2"]
	ok(k.ticks > 150 and k.checked > 150, "flight: the simulation ran in real time (%d ticks)" % k.ticks)
	ok(k.missing == 0, "flight: the destination ring (%d regions) is fully resident on arrival (missing %d)" % [k.ring, k.missing])
	ok(k.deferred == 0 and k.max_resident <= 160, "flight: the pool held the whole keep set (max %d resident, deferred %d)" % [k.max_resident, k.deferred])
	ok(k.ring_ok, "flight: the ring is still resident after settling")
	var base: Dictionary = res["default d1 conc3 lpf1"]
	ok(k.hole_frames < base.hole_frames and base.missing > 0, "flight: against default streaming at the same reduced radius (1 region) the keep set has fewer corridor holes (%d vs %d frames) and a complete destination (missing %d vs %d)" % [k.hole_frames, base.hole_frames, k.missing, base.missing])
	ok(res["keep conc3 lpf1"].missing == 0, "flight: the destination is also complete on arrival with default load settings (missing %d)" % res["keep conc3 lpf1"].missing)
	_clean(dir)


func _fly(dir: String, label: String, use_keep: bool, conc: int, lpf: int, distance: int) -> Dictionary:
	var known := _known_block(-3, 26, -2, 2)
	var cam := await _new_terrain(dir, 160, distance)
	_t.streaming_concurrent_loads = conc
	_t.streaming_loads_per_frame = lpf
	var s := _streamer()
	var sp := _span()
	var start := Vector2(0.5 * sp, 0.5 * sp)
	var dist := 10000.0
	var speed := 2500.0
	var dest := start + Vector2(dist, 0)
	_place(cam, Vector2i(0, 0))
	await _wait_for(_area(Vector2i(0, 0), float(distance), false, known), 800)
	# Click: preload the destination ring and the corridor (half width 200 m: the row the path runs along)
	var d_radius := 1000.0
	var cone := -1
	if use_keep:
		s.add_keep_path(PackedVector3Array([Vector3(start.x, 0, start.y), Vector3(dest.x, 0, dest.y)]), 200.0)
		s.add_keep_circle(Vector3(dest.x, 0, dest.y), d_radius, true)
		cone = s.add_keep_cone(Vector3(start.x, 0, start.y), Vector3(1, 0, 0), 1000.0, 400.0, 256.0)
	var d_set := _circle_set(dest, d_radius, known)
	var r := {"ring": d_set.size(), "ticks": 0, "checked": 0, "hole_frames": 0, "hole_regions": 0, "worst": 0, "max_resident": 0,
			"max_inflight": 0, "deferred": 0, "missing": -1, "complete_after": -1.0, "ring_done": -1.0, "phys_sum": 0.0, "phys_max": 0.0}
	var total := dist / speed + 1.0
	var t0 := Time.get_ticks_usec()
	while true:
		await physics_frame
		RenderingServer.emit_signal("frame_pre_draw")
		var t := float(Time.get_ticks_usec() - t0) * 1e-6
		var pos := Vector3(start.x + _flight_x(t, speed, dist), 50, start.y)
		cam.global_position = pos
		if use_keep:
			# The camera area shrinks over the first second, then a cone ahead replaces it
			s.camera_scale = clampf(1.0 - t, 0.0, 1.0)
			s.set_keep_cone(cone, Vector3(pos.x, 0, pos.z), Vector3(1, 0, 0), 1000.0, 400.0, 256.0)
		r.ticks += 1
		if t < total:
			# Holes: known regions of the path row within 0.5 km ahead of the camera that are not resident
			var holes := 0
			for cx in range(int(floor(pos.x / sp)), int(floor((pos.x + 500.0) / sp)) + 1):
				if known.has(Vector2i(cx, 0)) and not _t.data.has_region(Vector2i(cx, 0)):
					holes += 1
			r.checked += 1
			r.hole_regions += holes
			r.hole_frames += 1 if holes > 0 else 0
			r.worst = maxi(r.worst, holes)
		var phys := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		r.phys_sum += phys
		r.phys_max = maxf(r.phys_max, phys)
		var st := s.get_stats()
		r.max_inflight = maxi(r.max_inflight, st.inflight)
		r.deferred = maxi(r.deferred, st.deferred)
		r.max_resident = maxi(r.max_resident, st.resident)
		if t >= total:
			var left := 0
			for loc: Vector2i in d_set:
				if not _t.data.has_region(loc):
					left += 1
			if r.missing < 0:
				r.missing = left
			if left == 0 and r.complete_after < 0.0:
				r.complete_after = t - total
		if r.ring_done < 0.0:
			var gap := false
			for loc: Vector2i in d_set:
				if not _t.data.has_region(loc):
					gap = true
					break
			if not gap and t > 1.0:
				r.ring_done = t
		if t >= total + 3.0:
			break
	var st := s.get_stats()
	r["ring_ok"] = true
	for loc: Vector2i in d_set:
		r["ring_ok"] = r["ring_ok"] and _t.data.has_region(loc)
	print("FLIGHT [%s] ticks %d (%.0f/s); corridor holes: %d of %d frames had one, %d hole-regions, worst %d at once" % [
			label, r.ticks, r.ticks / (total + 3.0), r.hole_frames, r.checked, r.hole_regions, r.worst])
	print("FLIGHT [%s] ring %d regions, missing on arrival %d, complete %.2f s after arrival; max resident %d, inflight %d, deferred %d; landed %d, evicted %d" % [
			label, r.ring, r.missing, r.complete_after, r.max_resident, r.max_inflight, r.deferred, st.landed_total, st.evicted_total])
	print("FLIGHT [%s] ring first complete at t=%.2f s (flight %.1f s); physics process time avg %.2f ms, max %.2f ms" % [
			label, r.ring_done, total, r.phys_sum / maxf(r.ticks, 1), r.phys_max])
	await _free_terrain(cam)
	return r
