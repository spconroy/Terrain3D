extends SceneTree
## Headless test for the region map window (locations are global, only a window of cells is mapped):
##   godot --headless --path project --script res://tests/test_region_window.gd
## Covers the unchanged 32x32 default, far locations, window moves in every direction, teleports,
## 512 and 256 worlds wider than 32 regions, window sizes, and save/load of far locations.
var _fail := 0
var _t: Terrain3D
var _root_dir := "user://region_window_test_%d" % OS.get_process_id()


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


func _sig(loc: Vector2i) -> float:
	return float(loc.x) * 2.0 + float(loc.y) * 0.25 + 0.5


## Writes one region file per location, filled with a per-location signature height
func _author(dir: String, rs: int, locs: Array[Vector2i]) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	for loc in locs:
		var r := Terrain3DRegion.new()
		r.set_location(loc)
		var h := Image.create_empty(rs, rs, false, Image.FORMAT_RF)
		h.fill(Color(_sig(loc), 0, 0))
		r.set_height_map(h)
		r.set_modified(true) # Unmodified regions are skipped by save
		var err := r.save(dir + "/" + Terrain3DUtil.location_to_filename(loc))
		if err != OK:
			print("authoring failed ", loc, " ", err)


func _clean(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + f)


func _mapped_cells() -> int:
	var n := 0
	for v in _t.data.get_region_map():
		if v != 0:
			n += 1
	return n


func _new_stream_terrain(dir: String, slots: int, distance: int, map_size: int = 32) -> Camera3D:
	_t = Terrain3D.new()
	_t.region_map_size = map_size
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


## Moves the camera to the middle of a region and waits until every on-disk region within
## the streaming distance is resident and the loaded set is stable. Returns the settled state check.
func _goto(cam: Camera3D, loc: Vector2i, known: Dictionary, label: String) -> void:
	var rs: int = _t.region_size
	var d: int = _t.streaming_distance
	cam.global_position = Vector3((loc.x + 0.5) * rs, 50, (loc.y + 0.5) * rs)
	var want: Array[Vector2i] = []
	for y in range(-d, d + 1):
		for x in range(-d, d + 1):
			if known.has(loc + Vector2i(x, y)):
				want.append(loc + Vector2i(x, y))
	var stable := 0
	var last := -1
	for i in 600:
		await _frames(1)
		var all := true
		for w in want:
			if not _t.data.has_region(w):
				all = false
				break
		var n: int = _t.data.get_region_count()
		stable = stable + 1 if (n == last and all) else 0
		last = n
		if stable >= 12:
			break
	var present := true
	var heights := true
	for w in want:
		if not _t.data.has_region(w):
			present = false
			continue
		var h: float = _t.data.get_height(Vector3((w.x + 0.5) * rs, 0, (w.y + 0.5) * rs))
		if absf(h - _sig(w)) > 0.01:
			heights = false
	ok(present, "%s: all %d regions within distance resident" % [label, want.size()])
	ok(heights, "%s: heights match the authored signature" % label)
	ok(_mapped_cells() == _t.data.get_region_count(),
			"%s: mapped cells %d == resident %d (no stale cells)" % [label, _mapped_cells(), _t.data.get_region_count()])
	var origin: Vector2i = _t.data.get_region_map_origin()
	var size: int = _t.data.get_region_map_size()
	var r := d + 1
	ok(loc.x - r >= origin.x and loc.y - r >= origin.y and loc.x + r < origin.x + size and loc.y + r < origin.y + size,
			"%s: retained area inside window origin %s size %d" % [label, origin, size])
	var free_n: int = _t.data.get_free_slot_count()
	ok(free_n + _t.data.get_region_count() == _t.data.get_slot_capacity(), "%s: no slot leaked" % label)


func _run() -> void:
	process_frame.disconnect(_run)
	await _test_defaults()
	await _test_far_classic()
	await _test_filenames()
	await _test_window_moves()
	await _test_strip(512)
	await _test_strip(256)
	await _test_window_sizes()
	await _test_roundtrip()
	_clean_all()
	print("SUITE ", "GREEN" if _fail == 0 else "RED (%d)" % _fail)
	quit(_fail)


func _clean_all() -> void:
	var da := DirAccess.open("user://")
	if da == null:
		return
	var base := _root_dir.get_file()
	for sub in DirAccess.get_directories_at(_root_dir):
		_clean(_root_dir + "/" + sub)
		DirAccess.remove_absolute(_root_dir + "/" + sub)
	DirAccess.remove_absolute(_root_dir)
	print("cleaned ", base)


# 1. The default window is the old fixed 32x32 centred grid
func _test_defaults() -> void:
	_t = Terrain3D.new()
	root.add_child(_t)
	await _frames(2)
	var d := _t.data
	ok(Terrain3DData.REGION_MAP_SIZE == 32, "REGION_MAP_SIZE constant is 32")
	ok(_t.region_map_size == 32 and d.get_region_map_size() == 32, "default window size is 32")
	ok(d.get_region_map_origin() == Vector2i(-16, -16), "default origin is (-16,-16)")
	ok(d.get_region_map_index(Vector2i(-16, -16)) == 0, "index of (-16,-16) is 0")
	ok(d.get_region_map_index(Vector2i(15, 15)) == 1023, "index of (15,15) is 1023")
	ok(d.get_region_map_index(Vector2i(0, 0)) == 16 * 32 + 16, "index of (0,0) is 528")
	ok(d.get_region_map_index(Vector2i(-1, 2)) == 18 * 32 + 15, "index of (-1,2) matches loc + 16")
	ok(d.get_region_map_index(Vector2i(16, 0)) == -1 and d.get_region_map_index(Vector2i(0, 16)) == -1, "(16,0) and (0,16) out of bounds")
	ok(d.get_region_map_index(Vector2i(-17, 0)) == -1 and d.get_region_map_index(Vector2i(0, -17)) == -1, "(-17,0) and (0,-17) out of bounds")
	ok(d.get_region_map_index(Vector2i(2147483647, 2147483647)) == -1, "INT32_MAX sentinel out of bounds, no overflow")
	for loc in [Vector2i(-16, -16), Vector2i(15, 15), Vector2i(-16, 15), Vector2i(15, -16), Vector2i(0, 0)]:
		d.add_region_blank(loc, false)
	d.update_maps()
	for loc in [Vector2i(-16, -16), Vector2i(15, 15), Vector2i(-16, 15), Vector2i(15, -16), Vector2i(0, 0)]:
		ok(d.has_region(loc), "default window holds corner region %s" % loc)
	ok(d.get_region_count() == 5, "five regions at the old bounds")
	d.add_region_blank(Vector2i(16, 0), false)
	d.add_region_blank(Vector2i(-17, 3), false)
	d.update_maps()
	ok(not d.has_region(Vector2i(16, 0)) and not d.has_region(Vector2i(-17, 3)), "regions beyond the window are refused")
	ok(d.get_region_count() == 5, "refused regions are not added (%d)" % d.get_region_count())
	var rm := d.get_region_map()
	ok(rm.size() == 1024, "region map array is 1024 ints")
	var before := rm.duplicate()
	d.set_region_map_origin(Vector2i(-16, -16))
	ok(d.get_region_map() == before, "setting the same origin changes nothing")
	await _free_terrain_only()


func _free_terrain_only() -> void:
	_t.queue_free()
	await _frames(2)


# 2. Classic mode far away: move the window, add regions at global locations
func _test_far_classic() -> void:
	_t = Terrain3D.new()
	root.add_child(_t)
	await _frames(2)
	var d := _t.data
	var rs: int = _t.region_size
	d.add_region_blank(Vector2i(0, 0), true)
	ok(d.has_region(Vector2i(0, 0)), "classic: region at origin added")
	var id0 := d.get_region_id(Vector2i(0, 0))
	# Moving would orphan (0,0): refused, state unchanged
	d.set_region_map_origin(Vector2i(40, 40))
	ok(d.get_region_map_origin() == Vector2i(-16, -16) and d.has_region(Vector2i(0, 0)), "classic: move that would orphan a region is refused")
	# Move it within reach, keeping (0,0), then past it after removing
	d.set_region_map_origin(Vector2i(-30, -2))
	ok(d.get_region_map_origin() == Vector2i(-30, -2), "classic: window moves when all regions still fit")
	ok(d.get_region_id(Vector2i(0, 0)) == id0 and d.has_region(Vector2i(0, 0)), "classic: region keeps its id after a move")
	ok(_mapped_cells() == 1, "classic: one mapped cell after a move")
	d.remove_regionl(Vector2i(0, 0), true)
	ok(not d.has_region(Vector2i(0, 0)) and d.get_region_count() == 0, "classic: region removed")
	d.set_region_map_origin(Vector2i(95, -140))
	var far := [Vector2i(95, -140), Vector2i(126, -109), Vector2i(100, -120)]
	for loc in far:
		d.add_region_blank(loc, false)
		var r := d.get_region(loc)
		if r != null:
			r.get_height_map().fill(Color(_sig(loc), 0, 0))
			r.set_modified(true)
	d.update_maps()
	for loc in far:
		ok(d.has_region(loc), "classic: far region %s added" % loc)
		var h: float = d.get_height(Vector3((loc.x + 0.5) * rs, 0, (loc.y + 0.5) * rs))
		ok(absf(h - _sig(loc)) < 0.01, "classic: far height at %s (%.2f)" % [loc, h])
		ok(d.get_region_location(Vector3((loc.x + 0.5) * rs, 0, (loc.y + 0.5) * rs)) == loc, "classic: world position resolves to far location %s" % loc)
	ok(d.get_region_id(Vector2i(0, 0)) == -1 and not d.has_region(Vector2i(94, -140)) and not d.has_region(Vector2i(127, -109)), "classic: outside the window is not a region")
	d.add_region_blank(Vector2i(127, -139), false)
	d.update_maps()
	ok(not d.has_region(Vector2i(127, -139)), "classic: location right of the window refused")
	ok(_mapped_cells() == 3 and d.get_region_count() == 3, "classic: three mapped cells")
	# Window size property, refused while regions would fall outside
	_t.region_map_size = 16
	ok(_t.region_map_size == 32 and d.get_region_map_size() == 32, "classic: shrinking to 16 refused while regions would fall outside")
	d.set_region_map_origin(Vector2i(-16, -16)) # refused, regions far away
	ok(d.get_region_map_origin() == Vector2i(95, -140), "classic: origin stays while regions are loaded far away")
	await _free_terrain_only()


# 3. Region file names beyond two digits
func _test_filenames() -> void:
	var cases: Array[Vector2i] = [Vector2i(0, 0), Vector2i(-1, 2), Vector2i(15, -16), Vector2i(99, -99), Vector2i(100, 105),
			Vector2i(-100, 100), Vector2i(-123, -456), Vector2i(1000, 7), Vector2i(7, -1000), Vector2i(-99, 99)]
	var all := true
	for c in cases:
		var f := Terrain3DUtil.location_to_filename(c)
		if Terrain3DUtil.filename_to_location(f) != c:
			all = false
			print("   round trip failed: ", c, " -> ", f, " -> ", Terrain3DUtil.filename_to_location(f))
	ok(all, "file names round trip, including 3 and 4 digit locations")
	ok(Terrain3DUtil.location_to_filename(Vector2i(-1, 2)) == "terrain3d-01_02.res", "two digit file name format unchanged")
	ok(Terrain3DUtil.location_to_filename(Vector2i(12, -5)) == "terrain3d_12-05.res", "mixed sign file name format unchanged")
	ok(Terrain3DUtil.filename_to_location("terrain3d-01_02.res") == Vector2i(-1, 2), "existing file name parses as before")
	ok(Terrain3DUtil.filename_to_location("terrain3d_00_00.res") == Vector2i(0, 0), "origin file name parses as before")


# 4. Window moves: every direction, diagonals and teleports, over clusters of regions
func _test_window_moves() -> void:
	var dir := _root_dir + "/moves"
	var rs := 64
	var centres: Array[Vector2i] = [Vector2i(0, 0), Vector2i(60, 0), Vector2i(-60, 0), Vector2i(0, 60), Vector2i(0, -60),
			Vector2i(60, 60), Vector2i(-60, -60), Vector2i(60, -60), Vector2i(-60, 60), Vector2i(250, -180)]
	var locs: Array[Vector2i] = []
	var known := {}
	for c in centres:
		for y in range(-3, 4):
			for x in range(-3, 4):
				locs.append(c + Vector2i(x, y))
				known[c + Vector2i(x, y)] = true
	_author(dir, rs, locs)
	var cam := await _new_stream_terrain(dir, 49, 2)
	ok(_t.data.is_streaming() and _t.region_size == rs, "moves: streaming at region size %d" % _t.region_size)
	var steps: Array = [
		[Vector2i(0, 0), "start"],
		[Vector2i(60, 0), "teleport east"],
		[Vector2i(-60, 0), "teleport west"],
		[Vector2i(0, 60), "teleport south"],
		[Vector2i(0, -60), "teleport north"],
		[Vector2i(60, 60), "teleport diagonal se"],
		[Vector2i(-60, -60), "teleport diagonal nw"],
		[Vector2i(60, -60), "teleport diagonal ne"],
		[Vector2i(-60, 60), "teleport diagonal sw"],
		[Vector2i(250, -180), "far teleport (3 digit locations)"],
		[Vector2i(0, 0), "teleport home"],
	]
	for s in steps:
		await _goto(cam, s[0], known, "moves %s" % s[1])
	# Walk inside a cluster (cells shift without any window move) and walk off its edge
	var origin_before: Vector2i = _t.data.get_region_map_origin()
	for dx in range(-2, 3):
		await _goto(cam, Vector2i(dx, 0), known, "moves walk east %d" % dx)
	ok(_t.data.get_region_map_origin() == origin_before, "moves: walking inside the window does not move it")
	for dy in range(-2, 3):
		await _goto(cam, Vector2i(2, dy), known, "moves walk south %d" % dy)
	for dx in range(2, -3, -1):
		await _goto(cam, Vector2i(dx, 2), known, "moves walk west %d" % dx)
	for dy in range(2, -3, -1):
		await _goto(cam, Vector2i(-2, dy), known, "moves walk north %d" % dy)
	for i in range(0, 4):
		await _goto(cam, Vector2i(-2 + i, -2 + i), known, "moves walk diagonal %d" % i)
	# Hop around fast without settling in between, then settle: no stale cells, no leaked slots
	seed(11)
	for i in 40:
		var c: Vector2i = centres[randi() % centres.size()] + Vector2i(randi_range(-2, 2), randi_range(-2, 2))
		cam.global_position = Vector3((c.x + 0.5) * rs, 50, (c.y + 0.5) * rs)
		await _frames(randi_range(1, 6))
	await _goto(cam, Vector2i(60, 60), known, "moves after random hops")
	await _free_terrain(cam)
	_clean(dir)


# 5. A world wider than 32 regions at the region sizes the game wants
func _test_strip(rs: int) -> void:
	var dir := _root_dir + "/strip_%d" % rs
	var locs: Array[Vector2i] = []
	var known := {}
	for x in range(-24, 25):
		for y in range(0, 2):
			locs.append(Vector2i(x, y))
			known[Vector2i(x, y)] = true
	_author(dir, rs, locs)
	var cam := await _new_stream_terrain(dir, 49, 2)
	ok(_t.region_size == rs, "strip %d: region size adopted from the files (%d)" % [rs, _t.region_size])
	var origins := {}
	for x in range(-24, 25):
		await _goto(cam, Vector2i(x, 0), known, "strip %d x=%d" % [rs, x])
		origins[_t.data.get_region_map_origin()] = true
	ok(origins.size() >= 3, "strip %d: the window recentred %d times over 49 regions" % [rs, origins.size()])
	# Whole world back and forth by teleport
	for x in [24, -24, 0, 17, -17, 24, -24]:
		await _goto(cam, Vector2i(x, 1), known, "strip %d teleport to x=%d" % [rs, x])
	await _free_terrain(cam)
	_clean(dir)


# 6. Window sizes and the distance they allow
func _test_window_sizes() -> void:
	var dir := _root_dir + "/sizes"
	var rs := 64
	var locs: Array[Vector2i] = []
	var known := {}
	for c in [Vector2i(0, 0), Vector2i(70, -50), Vector2i(-70, 50)]:
		for y in range(-8, 9):
			for x in range(-8, 9):
				locs.append(c + Vector2i(x, y))
				known[c + Vector2i(x, y)] = true
	_author(dir, rs, locs)
	var cam := await _new_stream_terrain(dir, 169, 3, 16)
	ok(_t.data.get_region_map_size() == 16, "sizes: window size 16 applied")
	ok(_t.get_streamer().get_max_distance() == 5, "sizes: 169 slots in a 16 window allow distance 5 (%d)" % _t.get_streamer().get_max_distance())
	ok(_t.streaming_distance == 3, "sizes: distance 3 kept in a 16 window")
	_t.streaming_distance = 10
	ok(_t.streaming_distance == 6 and _t.get_streamer().get_max_distance() == 6, "sizes: distance 10 clamps to 6 in a 16 window (%d)" % _t.streaming_distance)
	_t.streaming_distance = 3
	_t.streaming_slots = 169
	for c in [Vector2i(0, 0), Vector2i(70, -50), Vector2i(-70, 50), Vector2i(0, 0)]:
		await _goto(cam, c, known, "sizes 16 at %s" % c)
		await _goto(cam, c + Vector2i(3, -2), known, "sizes 16 near %s" % c)
		await _goto(cam, c + Vector2i(-4, 4), known, "sizes 16 further near %s" % c)
		ok(_mapped_cells() <= 256 and _t.data.get_region_map().size() == 256, "sizes: region map array is 16x16 (%d)" % _t.data.get_region_map().size())
	_t.region_map_size = 5
	ok(_t.region_map_size == 8 or _t.region_map_size == 16, "sizes: requested 5 rounds up to a power of two >= 8 (%d)" % _t.region_map_size)
	_t.region_map_size = 20
	ok(_t.region_map_size == 32 or _t.region_map_size == 16, "sizes: requested 20 becomes a power of two (%d)" % _t.region_map_size)
	await _free_terrain(cam)
	# Size 32: distance 14 is the largest whose retained area fits (2 * 15 + 1 = 31)
	var cam2 := await _new_stream_terrain(dir, 1024, 14, 32)
	ok(_t.get_streamer().get_max_distance() == 14 and _t.streaming_distance == 14, "sizes: window 32 allows distance 14 (%d)" % _t.streaming_distance)
	await _free_terrain(cam2)
	_clean(dir)


# 7. Far locations written by the editor API, saved with 3 digit names, then loaded by streaming
func _test_roundtrip() -> void:
	var dir := _root_dir + "/roundtrip"
	DirAccess.make_dir_recursive_absolute(dir)
	_t = Terrain3D.new()
	root.add_child(_t)
	await _frames(2)
	var d := _t.data
	var rs: int = _t.region_size
	var locs: Array[Vector2i] = [Vector2i(-105, -100), Vector2i(-104, -100), Vector2i(-105, -99)]
	d.set_region_map_origin(Vector2i(-110, -110))
	for loc in locs:
		d.add_region_blank(loc, false)
		var r := d.get_region(loc)
		r.get_height_map().fill(Color(_sig(loc), 0, 0))
		r.set_modified(true)
	d.update_maps()
	d.save_directory(dir)
	var files := DirAccess.get_files_at(dir)
	files.sort()
	ok(files.size() == 3, "roundtrip: three region files saved (%d)" % files.size())
	print("   files: ", files)
	ok("terrain3d-105-100.res" in files and "terrain3d-104-100.res" in files and "terrain3d-105-99.res" in files, "roundtrip: 3 digit file names written")
	await _free_terrain_only()
	var known := {}
	for l in locs:
		known[l] = true
	var cam := await _new_stream_terrain(dir, 25, 1)
	ok(_t.data.is_streaming(), "roundtrip: streaming from the saved directory")
	await _goto(cam, Vector2i(-105, -100), known, "roundtrip far load")
	var r := _t.data.get_region(Vector2i(-105, -100))
	ok(r != null and r.get_location() == Vector2i(-105, -100), "roundtrip: region keeps its location property")
	ok(_t.data.get_region_map_origin().x < -100, "roundtrip: window is around the far location (%s)" % _t.data.get_region_map_origin())
	# Positive far locations save and load too
	await _free_terrain(cam)
	var pdir := _root_dir + "/roundtrip_pos"
	var ploc: Array[Vector2i] = [Vector2i(120, 130), Vector2i(121, 130)]
	_author(pdir, 64, ploc)
	var pknown := {Vector2i(120, 130): true, Vector2i(121, 130): true}
	var cam2 := await _new_stream_terrain(pdir, 25, 1)
	await _goto(cam2, Vector2i(121, 130), pknown, "roundtrip positive")
	await _free_terrain(cam2)
	_clean(dir)
	_clean(pdir)
