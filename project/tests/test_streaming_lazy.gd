extends SceneTree
## Headless test for lazily generated regions (Terrain3DStreamer.register_pending_locations, notify_region_written,
## notify_regions_written, get_pending_locations, get_wanted_pending, the generating / generating_wanted stats):
##   godot --headless --path project --script res://tests/test_streaming_lazy.gd
## Uses 64 px cloned regions, so it is fast. "Generating" a region here is an atomic file write (temp file + rename)
## followed by notify_region_written().
const RS := 64
var _fail := 0
var _t: Terrain3D
var _root_dir := "user://lazy_test_%d" % OS.get_process_id()
var _template := ""


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(_root_dir)
	_template = _root_dir + "/template.res"
	var r := Terrain3DRegion.new()
	r.set_location(Vector2i(0, 0))
	var h := Image.create_empty(RS, RS, false, Image.FORMAT_RF)
	h.fill(Color(5.0, 0, 0))
	r.set_height_map(h)
	r.set_modified(true)
	r.save(_template)
	process_frame.connect(_run)


func _frames(n: int) -> void:
	for i in n:
		await process_frame
		RenderingServer.emit_signal("frame_pre_draw")


func _clean(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + f)


func _file(dir: String, loc: Vector2i) -> String:
	return dir + "/" + Terrain3DUtil.location_to_filename(loc)


## The game's generator: write next to the final name, then rename, so a reader sees all of the file or none
func _write_region(dir: String, loc: Vector2i) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var tmp := _file(dir, loc) + ".part"
	DirAccess.copy_absolute(_template, tmp)
	DirAccess.rename_absolute(tmp, _file(dir, loc))


## Files for the block except the given locations (which stay ungenerated)
func _author_block(dir: String, x0: int, x1: int, y0: int, y1: int, p_except: Array = []) -> void:
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			if not p_except.has(Vector2i(x, y)):
				_write_region(dir, Vector2i(x, y))


func _new_terrain(dir: String, slots: int, distance: int) -> Camera3D:
	_t = Terrain3D.new()
	_t.streaming_enabled = true
	_t.streaming_slots = slots
	_t.streaming_distance = distance
	_t.data_directory = dir
	root.add_child(_t)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = Vector3(500.5 * _span(), 50, 500.5 * _span())
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


func _locs(arr: Array) -> Dictionary:
	var d := {}
	for loc: Vector2i in arr:
		d[loc] = true
	return d


func _same(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i] != b[i]:
			return false
	return true


func _row_path(x0: float, x1: float) -> PackedVector3Array:
	var z := 0.5 * _span()
	return PackedVector3Array([Vector3(x0 * _span(), 0, z), Vector3(x1 * _span(), 0, z)])


func _run() -> void:
	process_frame.disconnect(_run)
	await _test_default_parity()
	await _test_never_requested()
	await _test_notify()
	await _test_batch_notify()
	await _test_scan_interplay()
	await _test_abort_pending()
	await _test_forget()
	await _test_persist()
	await _test_ram_mode()
	await _test_window_slide()
	await _test_ready_distance()
	await _test_order()
	await _test_explicit_path()
	for sub in DirAccess.get_directories_at(_root_dir):
		_clean(_root_dir + "/" + sub)
		DirAccess.remove_absolute(_root_dir + "/" + sub)
	_clean(_root_dir)
	DirAccess.remove_absolute(_root_dir)
	print("SUITE ", "GREEN" if _fail == 0 else "RED (%d failures)" % _fail)
	quit(0 if _fail == 0 else 1)


# 1. Nothing registered: nothing changes
func _test_default_parity() -> void:
	var dir := _root_dir + "/parity"
	_author_block(dir, -3, 3, -3, 3)
	var cam := await _new_terrain(dir, 49, 1)
	var s := _streamer()
	_place(cam, Vector2i(0, 0))
	await _frames(120)
	var st := s.get_stats()
	ok(_resident().size() == 9, "parity: nine regions stream in (%d)" % _resident().size())
	ok(st.generating == 0 and st.generating_wanted == 0, "parity: the generating stats stay zero")
	ok(s.get_pending_locations().is_empty() and s.get_wanted_pending().is_empty(), "parity: no pending locations")
	ok(st.wanted == 9 and st.missing == 0 and st.failed == 0, "parity: wanted 9, missing 0, failed 0 (%d, %d, %d)" % [st.wanted, st.missing, st.failed])
	await _free_terrain(cam)
	_clean(dir)


# 2. A pending location is never requested: no failure, no retry, counted as missing
func _test_never_requested() -> void:
	var dir := _root_dir + "/never"
	var pend: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1)]
	_author_block(dir, -3, 3, -3, 3, pend)
	var cam := await _new_terrain(dir, 49, 1)
	var s := _streamer()
	s.register_pending_locations(pend)
	ok(_locs(s.get_pending_locations()) == _locs(pend), "never: get_pending_locations returns what was registered")
	s.register_pending_locations(pend) # Twice changes nothing
	ok(s.get_pending_locations().size() == 2, "never: registering again adds nothing")
	_place(cam, Vector2i(0, 0))
	await _frames(150)
	var st := s.get_stats()
	ok(_resident().size() == 7 and not _t.data.has_region(Vector2i(1, 0)) and not _t.data.has_region(Vector2i(0, 1)), "never: the seven generated regions load, the pending two do not (%d)" % _resident().size())
	ok(st.failed == 0 and st.inflight == 0, "never: no failed state, no load in flight (%d failed)" % st.failed)
	ok(st.disk_loads_needed == 7, "never: the loader counters only count real loads (%d)" % st.disk_loads_needed)
	ok(st.wanted == 9 and st.missing == 2, "never: counted as wanted and missing (%d wanted, %d missing)" % [st.wanted, st.missing])
	ok(st.generating == 2 and st.generating_wanted == 2, "never: generating 2, generating_wanted 2 (%d, %d)" % [st.generating, st.generating_wanted])
	ok(st.nearest_missing >= 0.0 and st.nearest_missing < _span(), "never: nearest_missing sees a pending region next to the camera (%.1f)" % st.nearest_missing)
	ok(st.known == 47, "never: known counts files only, not pending locations (%d)" % st.known)
	ok(_locs(s.get_wanted_pending()) == _locs(pend), "never: get_wanted_pending lists both")
	# Well past the retry delay of a failed location: still nothing requested
	await create_timer(0.3).timeout
	await _frames(30)
	st = s.get_stats()
	ok(st.failed == 0 and st.inflight == 0 and _resident().size() == 7 and st.disk_loads_needed == 7, "never: and it stays that way")
	# Registering something that is resident, or known from a file, is ignored
	s.register_pending_locations([Vector2i(0, 0), Vector2i(-1, 0), Vector2i(9999999, 0), "x"])
	ok(s.get_pending_locations().size() == 2, "never: resident, known, out of range and non-vector entries are skipped")
	s.clear_pending_locations()
	ok(s.get_pending_locations().is_empty() and s.get_stats().generating == 0, "never: clear_pending_locations empties the set")
	await _free_terrain(cam)
	_clean(dir)


# 3. notify_region_written makes the location load, without a scan
func _test_notify() -> void:
	var dir := _root_dir + "/notify"
	var pend: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1)]
	_author_block(dir, -3, 3, -3, 3, pend)
	var cam := await _new_terrain(dir, 49, 1)
	var s := _streamer()
	s.register_pending_locations(pend)
	_place(cam, Vector2i(0, 0))
	await _frames(100)
	var known0: int = s.get_stats().known
	_write_region(dir, Vector2i(1, 0))
	await _frames(40)
	ok(not _t.data.has_region(Vector2i(1, 0)), "notify: a written file alone is not picked up (no scan, no notify)")
	s.notify_region_written(Vector2i(1, 0))
	var st := s.get_stats()
	ok(st.generating == 1 and st.known == known0 + 1, "notify: the location leaves the pending set and becomes known (%d generating, %d known)" % [st.generating, st.known])
	await _frames(60)
	st = s.get_stats()
	ok(_t.data.has_region(Vector2i(1, 0)), "notify: and it loads by the normal priority")
	ok(st.missing == 1 and st.generating_wanted == 1, "notify: one is still missing and generating (%d, %d)" % [st.missing, st.generating_wanted])
	ok(st.failed == 0, "notify: no failed state")
	ok(_t.data.get_region(Vector2i(1, 0)).get_height_map().get_pixel(3, 3).r == 5.0, "notify: the loaded body is the written file")
	# A location that was never pending is made known the same way
	_write_region(dir, Vector2i(-4, 0))
	var wide := _streamer()
	wide.add_keep_circle(Vector3((-4 + 0.5) * _span(), 0, 0.5 * _span()), 0.2 * _span())
	await _frames(40)
	ok(not _t.data.has_region(Vector2i(-4, 0)), "notify: an unknown file is not loaded")
	s.notify_region_written(Vector2i(-4, 0))
	await _frames(60)
	ok(_t.data.has_region(Vector2i(-4, 0)), "notify: a location that was never pending loads after the notification")
	# The explicit path is the default when empty; notifying an already known location twice is harmless
	s.notify_region_written(Vector2i(1, 0), "")
	s.notify_region_written(Vector2i(1, 0))
	await _frames(20)
	ok(_t.data.has_region(Vector2i(1, 0)) and s.get_stats().failed == 0, "notify: notifying a loaded location again is harmless")
	await _free_terrain(cam)
	_clean(dir)


# 4. A batch of notifications
func _test_batch_notify() -> void:
	var dir := _root_dir + "/batch"
	var pend: Array[Vector2i] = []
	for y in range(-2, 3):
		for x in range(-2, 3):
			pend.append(Vector2i(x, y))
	_author_block(dir, -3, 3, -3, 3, pend)
	var cam := await _new_terrain(dir, 49, 2)
	var s := _streamer()
	s.register_pending_locations(pend)
	_place(cam, Vector2i(0, 0))
	await _frames(100)
	var st := s.get_stats()
	ok(_resident().size() == 0 and st.generating == 25 and st.missing == 25 and st.generating_wanted == 25, "batch: all 25 camera regions are missing and pending (%d resident, %d missing)" % [_resident().size(), st.missing])
	var first: Array = []
	for loc: Vector2i in pend:
		_write_region(dir, loc)
		first.append(loc)
	var plain: Array = first.duplicate()
	plain.append("junk") # Anything that is not a Vector2i is skipped
	s.notify_regions_written(plain)
	await _frames(120)
	st = s.get_stats()
	ok(_resident().size() == 25 and st.generating == 0 and st.missing == 0 and st.generating_wanted == 0, "batch: all 25 load after one batch call (%d)" % _resident().size())
	ok(st.failed == 0 and s.get_wanted_pending().is_empty(), "batch: no failures, nothing left to generate")
	await _free_terrain(cam)
	_clean(dir)


# 5. scan_directory keeps the pending set and drops what the scan found
func _test_scan_interplay() -> void:
	var dir := _root_dir + "/scan"
	var pend: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	_author_block(dir, -3, 3, -3, 3, pend)
	var cam := await _new_terrain(dir, 49, 1)
	var s := _streamer()
	s.register_pending_locations(pend)
	_place(cam, Vector2i(0, 0))
	await _frames(100)
	_write_region(dir, Vector2i(0, 1)) # Written, the game forgot to notify
	s.scan_directory()
	ok(_locs(s.get_pending_locations()) == _locs([Vector2i(1, 0), Vector2i(-1, 0)]), "scan: the file found leaves the pending set, the others survive")
	await _frames(120)
	var st := s.get_stats()
	ok(_t.data.has_region(Vector2i(0, 1)) and not _t.data.has_region(Vector2i(1, 0)) and not _t.data.has_region(Vector2i(-1, 0)), "scan: the found one loads, the pending ones still do not")
	ok(st.generating == 2 and st.failed == 0 and st.missing == 2, "scan: two still generating, no failure (%d generating, %d missing)" % [st.generating, st.missing])
	# A notified location survives a scan too (its file is on disk)
	_write_region(dir, Vector2i(1, 0))
	s.notify_region_written(Vector2i(1, 0))
	s.scan_directory()
	await _frames(100)
	ok(_t.data.has_region(Vector2i(1, 0)) and s.get_stats().generating == 1, "scan: a notified location is known after a scan")
	# register_virtual_locations on a pending location makes it a virtual one
	s.register_virtual_locations([Vector2i(-1, 0)])
	ok(s.get_stats().generating == 0, "scan: a location registered virtual is no longer pending")
	s.clear_virtual_locations()
	await _free_terrain(cam)
	_clean(dir)
	# A scan of an empty directory keeps the pending set as well
	dir = _root_dir + "/scan_empty"
	DirAccess.make_dir_recursive_absolute(dir)
	cam = await _new_terrain(dir, 49, 1)
	s = _streamer()
	s.register_pending_locations(pend)
	s.scan_directory()
	ok(s.get_pending_locations().size() == 3 and s.get_stats().known == 0, "scan: an empty directory scan keeps the three pending locations")
	await _free_terrain(cam)
	_clean(dir)


# 6. abort_pending drops loads in flight but the pending locations stay registered
func _test_abort_pending() -> void:
	var dir := _root_dir + "/abort"
	var pend: Array[Vector2i] = [Vector2i(1, 0)]
	_author_block(dir, -3, 3, -3, 3, pend)
	var cam := await _new_terrain(dir, 49, 1)
	var s := _streamer()
	s.register_pending_locations(pend)
	_place(cam, Vector2i(0, 0))
	await _frames(2)
	s.abort_pending()
	ok(s.get_pending_locations().size() == 1 and s.get_stats().inflight == 0, "abort: pending locations survive abort_pending")
	await _frames(100)
	ok(_resident().size() == 8 and s.get_stats().generating == 1 and s.get_stats().failed == 0, "abort: the rest loads again, the pending one is still not requested (%d)" % _resident().size())
	await _free_terrain(cam)
	_clean(dir)


# 7. A pending location that leaves the keep set is forgotten from wanted but stays registered
func _test_forget() -> void:
	var dir := _root_dir + "/forget"
	var pend: Array[Vector2i] = [Vector2i(1, 0), Vector2i(20, 0)]
	_author_block(dir, -3, 25, -3, 3, pend)
	var cam := await _new_terrain(dir, 49, 1)
	var s := _streamer()
	s.register_pending_locations(pend)
	_place(cam, Vector2i(0, 0))
	await _frames(100)
	var st := s.get_stats()
	ok(st.generating == 2 and st.generating_wanted == 1 and st.missing == 1, "forget: one of the two is wanted (%d generating, %d wanted, %d missing)" % [st.generating, st.generating_wanted, st.missing])
	ok(_same(s.get_wanted_pending(), [Vector2i(1, 0)]), "forget: get_wanted_pending lists the wanted one only")
	_place(cam, Vector2i(10, 0))
	await _frames(100)
	st = s.get_stats()
	ok(st.generating == 2 and st.generating_wanted == 0 and st.missing == 0, "forget: out of the keep set both stay registered but nothing is wanted or missing (%d wanted, %d missing)" % [st.generating_wanted, st.missing])
	ok(s.get_wanted_pending().is_empty() and s.get_pending_locations().size() == 2, "forget: get_wanted_pending is empty, get_pending_locations is not")
	_place(cam, Vector2i(20, 0))
	await _frames(100)
	ok(_same(s.get_wanted_pending(), [Vector2i(20, 0)]) and s.get_stats().generating_wanted == 1, "forget: arriving at the other one wants it")
	# A keep shape that is removed again
	var id := s.add_keep_circle(Vector3(1.5 * _span(), 0, 0.5 * _span()), 0.2 * _span())
	await _frames(20)
	ok(_locs(s.get_wanted_pending()) == _locs([Vector2i(1, 0), Vector2i(20, 0)]), "forget: a keep circle wants the first one again")
	s.remove_keep(id)
	await _frames(20)
	ok(_same(s.get_wanted_pending(), [Vector2i(20, 0)]), "forget: and removing it forgets it again")
	await _free_terrain(cam)
	_clean(dir)


# 8. persist_edits never writes a base file for a pending location
func _test_persist() -> void:
	var dir := _root_dir + "/persist"
	var pend: Array[Vector2i] = [Vector2i(1, 0)]
	_author_block(dir, -3, 30, -3, 3, pend)
	var cam := await _new_terrain(dir, 49, 1)
	_t.streaming_persist_edits = true
	var s := _streamer()
	s.register_pending_locations(pend)
	_place(cam, Vector2i(0, 0))
	await _frames(100)
	# Runtime edit of a loaded region still persists
	var r: Terrain3DRegion = _t.data.get_region(Vector2i(0, 0))
	r.get_height_map().set_pixel(10, 10, Color(555.0, 0, 0))
	r.set_modified(true)
	# A region created at a pending location by other means (an editor tool, a script): its base file is the generator's
	_t.data.add_region_blank(Vector2i(1, 0), true)
	var made: Terrain3DRegion = _t.data.get_region(Vector2i(1, 0))
	ok(made != null, "persist: a region could be added at the pending location")
	if made != null:
		made.get_height_map().set_pixel(10, 10, Color(777.0, 0, 0))
		made.set_modified(true)
	_place(cam, Vector2i(15, 0))
	await _frames(120)
	ok(not _t.data.has_region(Vector2i(0, 0)) and not _t.data.has_region(Vector2i(1, 0)), "persist: both were evicted")
	var saved: Terrain3DRegion = ResourceLoader.load(_file(dir, Vector2i(0, 0)), "Terrain3DRegion", ResourceLoader.CACHE_MODE_IGNORE)
	ok(saved != null and absf(saved.get_height_map().get_pixel(10, 10).r - 555.0) < 0.01, "persist: the edit of a normal region reached its file")
	ok(not FileAccess.file_exists(_file(dir, Vector2i(1, 0))), "persist: no base file was written for the pending location")
	ok(s.get_stats().generating == 1, "persist: and it is still pending")
	await _free_terrain(cam)
	_clean(dir)


# 9. RAM mode: pending locations are not prefetched, and a notified one loads
func _test_ram_mode() -> void:
	var dir := _root_dir + "/ram"
	var pend: Array[Vector2i] = [Vector2i(1, 0), Vector2i(12, 0)]
	_author_block(dir, -3, 14, -3, 3, pend)
	var cam := await _new_terrain(dir, 49, 1)
	_t.streaming_mode = Terrain3DStreamer.RAM
	var s := _streamer()
	s.register_pending_locations(pend)
	_place(cam, Vector2i(0, 0))
	await _frames(250)
	var st := s.get_stats()
	ok(st.failed == 0 and st.generating == 2 and not _t.data.has_region(Vector2i(1, 0)), "ram: pending locations are never requested, not even by the prefetch (%d failed)" % st.failed)
	ok(st.ram_cached > 20, "ram: the rest of the world is prefetched (%d cached)" % st.ram_cached)
	_write_region(dir, Vector2i(12, 0))
	s.notify_region_written(Vector2i(12, 0))
	await _frames(100)
	ok(s.get_cached_regions().has(Vector2i(12, 0)), "ram: a notified location far away is prefetched into the cache")
	_write_region(dir, Vector2i(1, 0))
	s.notify_region_written(Vector2i(1, 0))
	await _frames(60)
	ok(_t.data.has_region(Vector2i(1, 0)), "ram: a notified location in the keep set is inserted")
	await _free_terrain(cam)
	_clean(dir)


# 10. A path beyond the region map window: the window slides, pending regions count, notified ones load
func _test_window_slide() -> void:
	var dir := _root_dir + "/window"
	var pend: Array[Vector2i] = []
	for x in range(10, 60):
		pend.append(Vector2i(x, 0))
	_author_block(dir, -3, 80, -3, 3, pend)
	var cam := await _new_terrain(dir, 49, 1)
	var s := _streamer()
	s.register_pending_locations(pend)
	_place(cam, Vector2i(0, 0))
	s.add_keep_path(_row_path(0.5, 70.5), 0.3 * _span())
	s.keep_cache_limit = 200
	await _frames(200)
	var st := s.get_stats()
	ok(st.generating == 50 and st.generating_wanted == 50 and st.failed == 0, "window: 50 pending along the path, wanted, none failed (%d, %d)" % [st.generating, st.generating_wanted])
	ok(st.outside_window > 0, "window: part of them lies beyond the region map window (%d)" % st.outside_window)
	var written := 0
	var origin0: Vector2i = _t.data.get_region_map_origin()
	var recentres0: int = st.recentres
	# The generator follows get_wanted_pending while the camera flies along
	for step in 400:
		var want := s.get_wanted_pending(2)
		for loc: Vector2i in want:
			_write_region(dir, loc)
			s.notify_region_written(loc)
			written += 1
		if want.is_empty():
			break
		var x := minf(float(step) * 0.2 + 0.5, 69.5)
		cam.global_position = Vector3(x * _span(), 50, 0.5 * _span())
		await _frames(2)
	await _frames(200)
	st = s.get_stats()
	ok(written == 50 and st.generating == 0, "window: all 50 were handed out by get_wanted_pending (%d)" % written)
	ok(st.recentres > recentres0 and _t.data.get_region_map_origin() != origin0, "window: the window moved with the camera (%d recentres)" % (st.recentres - recentres0))
	_place(cam, Vector2i(50, 0))
	await _frames(150)
	ok(_t.data.has_region(Vector2i(50, 0)) and _t.data.has_region(Vector2i(49, 0)) and _t.data.has_region(Vector2i(51, 0)), "window: the camera area of a generated stretch is resident")
	await _free_terrain(cam)
	_clean(dir)


# 11. The ready distance of a path stops at a pending region; once it is generated and loaded the path is ready
func _test_ready_distance() -> void:
	var dir := _root_dir + "/ready"
	var pend: Array[Vector2i] = [Vector2i(6, 0)]
	_author_block(dir, -3, 20, -2, 2, pend)
	var cam := await _new_terrain(dir, 100, 1)
	var s := _streamer()
	s.register_pending_locations(pend)
	_place(cam, Vector2i(0, 0))
	cam.global_position.x = 0.5 * _span()
	var radius := 0.3 * _span()
	var id := s.add_keep_path(_row_path(0.5, 14.5), radius)
	await _frames(250)
	var total: float = 14.0 * _span()
	var ready: float = s.get_path_ready_distance(id)
	var expect: float = (6.0 - 0.5) * _span() - radius
	ok(absf(ready - expect) < 2.0, "ready: the distance ends at the pending region (%.1f, expected %.1f)" % [ready, expect])
	ok(_t.data.has_region(Vector2i(5, 0)) and _t.data.has_region(Vector2i(7, 0)) and _t.data.has_region(Vector2i(14, 0)), "ready: the neighbours and the end of the path are visible")
	var st := s.get_stats()
	ok(st.nearest_missing > 0.0 and st.generating_wanted == 1, "ready: nearest_missing and generating_wanted see it (%.1f, %d)" % [st.nearest_missing, st.generating_wanted])
	ok(s.get_path_cost(_row_path(0.5, 14.5), radius).generating == 1, "ready: get_path_cost reports it")
	# Without the registration the same hole would be ignored: a missing file is not a region of the world
	var other := s.get_path_ready_distance(id, 8.0 * _span())
	ok(absf(other - (total - 8.0 * _span())) < 1.0, "ready: measured from beyond it the rest of the path is ready (%.1f)" % other)
	_write_region(dir, Vector2i(6, 0))
	s.notify_region_written(Vector2i(6, 0))
	await _frames(100)
	ready = s.get_path_ready_distance(id)
	ok(absf(ready - total) < 1.0 and _t.data.has_region(Vector2i(6, 0)), "ready: after the notification the whole path is ready (%.1f of %.1f)" % [ready, total])
	await _free_terrain(cam)
	_clean(dir)


# 12. get_wanted_pending follows the order the loads would use: needed before cache only, ahead before behind, destination, path by
# arrival, the camera's area by distance. Notifying everything at once with one load at a time then loads in that order.
func _test_order() -> void:
	var dir := _root_dir + "/order"
	DirAccess.make_dir_recursive_absolute(dir)
	_write_region(dir, Vector2i(100, 100)) # The pool takes its region size from the first file
	var pend: Array[Vector2i] = []
	for y in range(-4, 5):
		for x in range(-6, 45):
			pend.append(Vector2i(x, y))
	var cam := await _new_terrain(dir, 169, 2)
	_t.streaming_concurrent_loads = 1
	_t.streaming_loads_per_frame = 1
	_t.streaming_frame_budget_ms = 0.0
	var s := _streamer()
	s.register_pending_locations(pend)
	var sp := _span()
	_place(cam, Vector2i(10, 0))
	var path_id := s.add_keep_path(_row_path(0.5, 40.5), 0.3 * sp)
	s.set_keep_path_ahead(path_id, 12.0 * sp, -1.0) # Needed 12 regions ahead, bodies to the end
	var dest_c := Vector2(16.5 * sp, 3.5 * sp)
	s.add_keep_circle(Vector3(dest_c.x, 0, dest_c.y), 1.2 * sp, true)
	await _frames(30)
	var want := s.get_wanted_pending(100000)
	var st := s.get_stats()
	# The sort key of the streamer: (cache only, behind, tier, rank). Camera at (10, 0), path from 0.5 to 40.5
	var klass := func(loc: Vector2i) -> Array:
		var rmin := Vector2(loc) * sp
		var rd := (dest_c - dest_c.clamp(rmin, rmin + Vector2(sp, sp))).length()
		if rd <= 1.2 * sp:
			return [0, 0, 0, ((rmin + Vector2(sp, sp) * 0.5) - dest_c).length() / sp]
		if loc.y == 0 and loc.x >= 0 and loc.x <= 40:
			var behind: bool = loc.x <= 9
			var cache: bool = float(loc.x) > 10.0 + 12.5
			return [1 if cache else 0, 1 if behind else 0, 1, float(10 - loc.x) if behind else maxf(float(loc.x - 10), 0.0)]
		var cheb := maxi(absi(loc.x - 10), absi(loc.y))
		if cheb <= 2:
			return [0, 1 if loc.x <= 9 else 0, 2, float(cheb)]
		return [-1]
	var keys: Array = []
	var known := true
	for loc: Vector2i in want:
		var k: Array = klass.call(loc)
		known = known and k[0] >= 0
		keys.append(k)
	ok(want.size() > 50 and known, "order: %d pending locations wanted, every one by the model's shapes" % want.size())
	var sorted_ok := true
	for i in range(1, keys.size()):
		var a: Array = keys[i - 1]
		var b: Array = keys[i]
		var j := 0
		while j < 3 and a[j] == b[j]:
			j += 1
		var less: bool = a[j] < b[j] if j < 3 else a[3] <= b[3] + 0.001
		sorted_ok = sorted_ok and less
	ok(sorted_ok, "order: sorted by (cache only, behind, tier, rank)")
	ok(keys[0][2] == 0 and keys[0][1] == 0, "order: the first location to generate belongs to the destination")
	var needed := 0
	for k: Array in keys:
		needed += 1 if (k[0] == 0 and k[1] == 0) else 0
	ok(st.generating_wanted == needed and needed < want.size(), "order: generating_wanted counts what is needed ahead (%d, expected %d of %d listed)" % [st.generating_wanted, needed, want.size()])
	var tail_ok := true
	for i in range(needed, keys.size()):
		tail_ok = tail_ok and (keys[i][0] == 1 or keys[i][1] == 1)
	ok(tail_ok and keys[needed][1] == 1, "order: only behind and cache only locations follow (behind before the cache only ones)")
	# max limits the list, and the first entries are the head of the full list
	ok(_same(s.get_wanted_pending(5), want.slice(0, 5)), "order: max returns the head of the list")
	ok(s.get_wanted_pending(0).is_empty(), "order: max 0 returns nothing")
	# Load order equals the order of the list when the head is written at once
	var head := want.slice(0, needed)
	for loc: Vector2i in head:
		_write_region(dir, loc)
	s.notify_regions_written(head)
	var seen: Array[Vector2i] = []
	for f in 900:
		await physics_frame
		RenderingServer.emit_signal("frame_pre_draw")
		for loc: Vector2i in head:
			if _t.data.has_region(loc) and not seen.has(loc):
				seen.append(loc)
		if seen.size() == head.size():
			break
	ok(seen.size() == head.size(), "order: all %d notified regions load (%d)" % [head.size(), seen.size()])
	var same := seen.size() == head.size()
	for i in mini(seen.size(), head.size()):
		var kl: Array = klass.call(seen[i])
		var kw: Array = keys[i]
		same = same and kl[0] == kw[0] and kl[1] == kw[1] and kl[2] == kw[2] and absf(kl[3] - kw[3]) < 0.001
	ok(same, "order: they load in the order the list had (destination, path arrival, distance)")
	await _free_terrain(cam)
	_clean(dir)
	# Behind the camera on a path: wanted, but last and not counted as needed
	dir = _root_dir + "/order2"
	_author_block(dir, 30, 30, 30, 30)
	cam = await _new_terrain(dir, 100, 1)
	s = _streamer()
	var behind: Array[Vector2i] = [Vector2i(2, 0), Vector2i(3, 0), Vector2i(12, 0), Vector2i(8, 0)]
	s.register_pending_locations(behind)
	_place(cam, Vector2i(10, 0))
	s.add_keep_path(_row_path(0.5, 20.5), 0.3 * _span())
	await _frames(30)
	var w2 := s.get_wanted_pending(10)
	ok(w2.size() == 4 and w2[0] == Vector2i(12, 0) and w2[w2.size() - 1] == Vector2i(2, 0), "order: ahead of the camera first, farthest behind last: %s" % [w2])
	ok(s.get_stats().generating_wanted == 1, "order: behind the direction of travel is wanted but not counted as needed (%d)" % s.get_stats().generating_wanted)
	await _free_terrain(cam)
	_clean(dir)


# 13. notify_region_written with an explicit path: the file may live anywhere and survives a scan
func _test_explicit_path() -> void:
	var dir := _root_dir + "/explicit"
	var other := _root_dir + "/explicit_other"
	_author_block(dir, -3, 3, -3, 3, [Vector2i(1, 0)])
	DirAccess.make_dir_recursive_absolute(other)
	var cam := await _new_terrain(dir, 49, 1)
	var s := _streamer()
	s.register_pending_locations([Vector2i(1, 0)])
	_place(cam, Vector2i(0, 0))
	await _frames(60)
	var elsewhere := other + "/anything.res"
	DirAccess.copy_absolute(_template, elsewhere)
	s.notify_region_written(Vector2i(1, 0), elsewhere)
	await _frames(60)
	ok(_t.data.has_region(Vector2i(1, 0)) and s.get_stats().failed == 0, "explicit: a location notified with its own path loads from there")
	s.scan_directory()
	ok(s.get_stats().generating == 0 and s.get_stats().known == 49, "explicit: the scan keeps the location with its path (%d known)" % s.get_stats().known)
	await _frames(100)
	ok(_t.data.has_region(Vector2i(1, 0)) and s.get_stats().failed == 0, "explicit: and it still loads after the scan")
	await _free_terrain(cam)
	_clean(dir)
	_clean(other)
	DirAccess.remove_absolute(other)
