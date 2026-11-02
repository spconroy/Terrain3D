extends SceneTree
## Headless test for the streamer's insert gate (Terrain3DStreamer.set_insert_gate, gate_timeout_ms, the gated /
## gate_timeouts / gate_wait_ms_max stats and get_gated_regions):
##   godot --headless --path project --script res://tests/test_streaming_insertgate.gd
## Uses 64 px cloned regions, so it is fast. The gate holds a loaded region back until the game says its trees
## and everything else are ready; the region waits as a body in the RAM cache, holds no slot and is not visible.
const RS := 64
const FlightGovernor := preload("res://tests/flight_governor.gd")
var _fail := 0
var _t: Terrain3D
var _root_dir := "user://insertgate_test_%d" % OS.get_process_id()

# Gate state, driven by the tests
var _mode := "open" # open, hold_all, set, from_x, order
var _held := {} # "set": locations that are refused
var _x_min := 0 # "from_x": locations with x >= this are refused
var _open_at := {} # "order": location -> msec time it opens
var _calls := 0
var _calls_per_loc := {}
var _off_main := false
var _release_ms := 0 # "from_x": opens for everyone at this time, 0 = never


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
	_mode = "open"
	_held = {}
	_open_at = {}
	_release_ms = 0
	_calls = 0
	_calls_per_loc = {}
	_off_main = false
	_t = Terrain3D.new()
	_t.streaming_enabled = true
	_t.streaming_slots = slots
	_t.streaming_distance = distance
	_t.data_directory = dir
	root.add_child(_t)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = Vector3(500.5 * _span(), 50, 500.5 * _span()) # Where nothing exists: a test places it after setting the gate
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


func _row_path(x0: float, x1: float) -> PackedVector3Array:
	var z := 0.5 * _span()
	return PackedVector3Array([Vector3(x0 * _span(), 0, z), Vector3(x1 * _span(), 0, z)])


## The gate itself: a cheap lookup on the main thread
func gate(loc: Vector2i) -> bool:
	_calls += 1
	_calls_per_loc[loc] = _calls_per_loc.get(loc, 0) + 1
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		_off_main = true
	match _mode:
		"hold_all":
			return false
		"set":
			return not _held.has(loc)
		"from_x":
			return loc.x < _x_min or (_release_ms > 0 and Time.get_ticks_msec() >= _release_ms)
		"order":
			return Time.get_ticks_msec() >= int(_open_at.get(loc, 0))
	return true


func _gate_string(_loc: Vector2i) -> String:
	return "no"


func _gate_nothing(_loc: Vector2i) -> void:
	pass


func _run() -> void:
	process_frame.disconnect(_run)
	await _test_default_parity()
	await _test_hold_and_release()
	await _test_order()
	await _test_budget()
	await _test_timeout()
	await _test_invalid()
	await _test_ready_distance()
	await _test_evict_before_insert()
	await _test_behind_limit()
	await _test_persist()
	await _test_retry_and_failed()
	await _test_window_slide()
	await _test_ram_mode()
	await _test_resolver()
	await _test_rescan_abort()
	await _test_flight()
	for sub in DirAccess.get_directories_at(_root_dir):
		_clean(_root_dir + "/" + sub)
		DirAccess.remove_absolute(_root_dir + "/" + sub)
	DirAccess.remove_absolute(_root_dir)
	print("SUITE ", "GREEN" if _fail == 0 else "RED (%d failures)" % _fail)
	quit(0 if _fail == 0 else 1)


# 1. No gate: nothing changes
func _test_default_parity() -> void:
	var dir := _root_dir + "/parity"
	_author_block(dir, -3, 3, -3, 3)
	var cam := await _new_terrain(dir, 49, 1)
	var s := _streamer()
	ok(not s.get_insert_gate().is_valid(), "parity: no gate by default")
	ok(s.gate_timeout_ms == 0, "parity: gate_timeout_ms defaults to 0 (wait forever)")
	_place(cam, Vector2i(0, 0))
	await _frames(120)
	var st := s.get_stats()
	ok(_resident().size() == 9, "parity: all nine regions stream in without a gate (%d)" % _resident().size())
	ok(st.gated == 0 and st.gate_timeouts == 0 and st.gate_wait_ms_max == 0, "parity: gate stats stay zero")
	ok(s.get_gated_regions().is_empty(), "parity: nothing is gated")
	# A gate that always says yes changes nothing either
	await _free_terrain(cam)
	cam = await _new_terrain(dir, 49, 1)
	s = _streamer()
	s.set_insert_gate(gate)
	_place(cam, Vector2i(0, 0))
	await _frames(120)
	st = s.get_stats()
	ok(_resident().size() == 9, "parity: an always open gate loads the same nine regions")
	ok(st.gated == 0 and st.gate_timeouts == 0 and st.gate_wait_ms_max == 0, "parity: an always open gate holds nothing")
	await _free_terrain(cam)
	_clean(dir)


# 2. A refusing gate keeps the regions loaded but invisible and costs nothing else; opening it releases them
func _test_hold_and_release() -> void:
	var dir := _root_dir + "/hold"
	_author_block(dir, -3, 3, -3, 3)
	var cam := await _new_terrain(dir, 49, 1)
	var s := _streamer()
	_mode = "hold_all"
	s.set_insert_gate(gate)
	ok(s.get_insert_gate().is_valid(), "hold: the gate is set and read back")
	_place(cam, Vector2i(0, 0))
	await _frames(120)
	var st := s.get_stats()
	ok(_t.data.get_region_count() == 0, "hold: nothing is inserted while the gate refuses (%d resident)" % _t.data.get_region_count())
	ok(_t.data.get_region(Vector2i(0, 0)) == null and _t.data.get_region_id(Vector2i(0, 0)) < 0, "hold: the region is neither in the data nor in a slot")
	ok(st.gated == 9 and s.get_gated_regions().size() == 9, "hold: the nine wanted regions are gated (%d)" % st.gated)
	ok(st.ram_cached == 9, "hold: their bodies wait in the RAM cache (%d)" % st.ram_cached)
	ok(st.inflight == 0 and st.staged == 0, "hold: the gate holds no load place and no staged region (%d in flight, %d staged)" % [st.inflight, st.staged])
	ok(st.free_slots == 49, "hold: no pool slot is held (%d free of 49)" % st.free_slots)
	ok(st.failed == 0, "hold: a gated region is never a failure")
	ok(st.landed_total == 0, "hold: nothing counts as landed")
	ok(st.nearest_missing >= 0.0, "hold: the nearest missing distance counts gated regions as not visible (%.1f)" % st.nearest_missing)
	ok(st.gate_wait_ms_max > 0, "hold: the longest wait is reported (%d ms)" % st.gate_wait_ms_max)
	ok(not _off_main and _calls > 0, "hold: the gate is only called on the main thread (%d calls)" % _calls)
	var asked_all := true
	for loc in s.get_gated_regions():
		asked_all = asked_all and _calls_per_loc.get(loc, 0) > 1
	ok(asked_all, "hold: every held region is asked again on later steps")
	_mode = "open"
	await _frames(120)
	st = s.get_stats()
	ok(_resident().size() == 9, "hold: opening the gate releases all nine (%d)" % _resident().size())
	ok(st.gated == 0 and s.get_gated_regions().is_empty(), "hold: nothing is gated after the release")
	ok(st.ram_cached == 0 and st.free_slots == 49 - 9, "hold: the cache is empty and the nine slots are in use")
	ok(st.gate_wait_ms_max > 0 and st.gate_timeouts == 0, "hold: the wait is kept in the stat, no timeout")
	# A released region that is evicted and wanted again goes through the gate again
	_mode = "hold_all"
	_place(cam, Vector2i(30, 30)) # Nothing there: everything unloads
	await _frames(60)
	ok(_t.data.get_region_count() == 0, "hold: moving away evicts the visible regions")
	_place(cam, Vector2i(0, 0))
	await _frames(120)
	ok(_t.data.get_region_count() == 0 and s.get_stats().gated == 9, "hold: coming back asks the gate again")
	await _free_terrain(cam)
	_clean(dir)


# 3. The gate releases in an order of its own: ready regions are inserted first, whatever their priority
func _test_order() -> void:
	var dir := _root_dir + "/order"
	_author_block(dir, -3, 3, -3, 3)
	var cam := await _new_terrain(dir, 49, 1)
	var s := _streamer()
	_mode = "order"
	_place(cam, Vector2i(0, 0))
	var now := Time.get_ticks_msec()
	# Farthest (corner) first, the centre last: the reverse of the streamer's own priority
	var order: Array[Vector2i] = [Vector2i(1, 1), Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(0, 0)]
	for i in order.size():
		_open_at[order[i]] = now + 600 + i * 250
	s.set_insert_gate(gate)
	var seen: Array[Vector2i] = []
	var seen_before_open := 0
	for f in 400:
		await _frames(1)
		for loc: Vector2i in order:
			if _t.data.has_region(loc) and not seen.has(loc):
				seen.append(loc)
				if Time.get_ticks_msec() < int(_open_at[loc]):
					seen_before_open += 1
		if seen.size() == order.size():
			break
	ok(seen.size() == order.size(), "order: all nine become visible (%d)" % seen.size())
	ok(seen_before_open == 0, "order: none became visible before the gate opened it")
	ok(seen == order, "order: they became visible in the order the gate released them: %s" % [seen])
	await _free_terrain(cam)
	_clean(dir)


# 4. Gated regions do not use the insertion budget: with one load per frame the open regions still stream in
func _test_budget() -> void:
	for budget in [0.0, 2.0]:
		var dir := _root_dir + "/budget"
		_author_block(dir, -3, 3, -3, 3)
		var cam := await _new_terrain(dir, 49, 1)
		var s := _streamer()
		_t.streaming_loads_per_frame = 1
		_t.streaming_frame_budget_ms = budget
		_place(cam, Vector2i(0, 0))
		# The four nearest and the centre are refused; they would be inserted first without a gate
		_mode = "set"
		_held = {Vector2i(0, 0): true, Vector2i(1, 0): true, Vector2i(-1, 0): true, Vector2i(0, 1): true, Vector2i(0, -1): true}
		s.set_insert_gate(gate)
		await _frames(150)
		var res := _resident()
		ok(res.size() == 4, "budget %.0f ms: the four open regions are inserted while the nearest five are held (%d resident)" % [budget, res.size()])
		ok(s.get_stats().gated == 5, "budget %.0f ms: five are gated" % budget)
		# Count the frames it takes to insert after the release: one by one, as the budget allows
		_mode = "open"
		var frames := 0
		while _resident().size() < 9 and frames < 300:
			await _frames(1)
			frames += 1
		ok(_resident().size() == 9 and frames < 100, "budget %.0f ms: the held five follow once released (%d frames)" % [budget, frames])
		await _free_terrain(cam)
		_clean(dir)


# 5. Timeout: inserted anyway after gate_timeout_ms, counted
func _test_timeout() -> void:
	var dir := _root_dir + "/timeout"
	_author_block(dir, -3, 3, -3, 3)
	var cam := await _new_terrain(dir, 49, 1)
	var s := _streamer()
	s.gate_timeout_ms = 700
	ok(s.gate_timeout_ms == 700, "timeout: gate_timeout_ms is stored")
	_mode = "set"
	_held = {Vector2i(1, 0): true, Vector2i(0, 1): true}
	s.set_insert_gate(gate)
	_place(cam, Vector2i(0, 0))
	await _frames(40)
	var st := s.get_stats()
	ok(_resident().size() == 7 and st.gated == 2 and st.gate_timeouts == 0, "timeout: two held, seven visible before the timeout (%d resident, %d gated)" % [_resident().size(), st.gated])
	await create_timer(1.0).timeout
	await _frames(30)
	st = s.get_stats()
	ok(_resident().size() == 9, "timeout: the two are inserted anyway (%d resident)" % _resident().size())
	ok(st.gate_timeouts == 2 and st.gated == 0, "timeout: two timeouts counted, none gated (%d, %d)" % [st.gate_timeouts, st.gated])
	ok(st.gate_wait_ms_max >= 700 and st.gate_wait_ms_max < 2500, "timeout: the longest wait is about the timeout (%d ms)" % st.gate_wait_ms_max)
	ok(s.get_gated_regions().is_empty(), "timeout: get_gated_regions is empty after")
	# Zero means forever
	s.gate_timeout_ms = 0
	_held = {Vector2i(0, 0): true}
	_place(cam, Vector2i(30, 30))
	await _frames(40)
	_place(cam, Vector2i(0, 0))
	await create_timer(1.2).timeout
	await _frames(20)
	ok(not _t.data.has_region(Vector2i(0, 0)) and s.get_stats().gated == 1, "timeout: with 0 it waits however long")
	# A shorter timeout set later applies to a region already waiting
	s.gate_timeout_ms = 100
	await _frames(30)
	ok(_t.data.has_region(Vector2i(0, 0)) and s.get_stats().gate_timeouts == 3, "timeout: lowering the timeout releases what already waited that long")
	await _free_terrain(cam)
	_clean(dir)


# 6. A callable that is invalid, freed or answers nonsense is handled safely
func _test_invalid() -> void:
	var dir := _root_dir + "/invalid"
	_author_block(dir, -3, 12, -3, 3)
	var cam := await _new_terrain(dir, 49, 1)
	var s := _streamer()
	_place(cam, Vector2i(0, 0))
	# Freed object: the gate is gone, regions are not held
	var holder := Node.new()
	var scr := GDScript.new()
	scr.source_code = "extends Node
func refuse(_loc: Vector2i) -> bool:
	return false
"
	scr.reload()
	holder.set_script(scr)
	var c := Callable(holder, "refuse")
	s.set_insert_gate(c)
	await _frames(60)
	ok(_resident().size() == 0 and s.get_stats().gated == 9, "invalid: a live gate on an object holds")
	holder.free()
	await _frames(60)
	ok(not s.get_insert_gate().is_valid(), "invalid: the callable of a freed object is invalid")
	ok(_resident().size() == 9 and s.get_stats().gated == 0, "invalid: when its object is freed the regions are inserted (%d)" % _resident().size())
	# Null clears
	s.set_insert_gate(Callable())
	ok(not s.get_insert_gate().is_valid(), "invalid: an empty Callable clears the gate")
	await _free_terrain(cam)
	# Answers that are not a bool do not hold
	cam = await _new_terrain(dir, 49, 1)
	s = _streamer()
	_place(cam, Vector2i(0, 0))
	s.set_insert_gate(_gate_string)
	await _frames(80)
	ok(_resident().size() == 9 and s.get_stats().gated == 0, "invalid: a gate that answers a String does not hold (%d)" % _resident().size())
	await _free_terrain(cam)
	cam = await _new_terrain(dir, 49, 1)
	s = _streamer()
	_place(cam, Vector2i(0, 0))
	s.set_insert_gate(_gate_nothing)
	await _frames(80)
	ok(_resident().size() == 9 and s.get_stats().gated == 0, "invalid: a gate that returns nothing does not hold (%d)" % _resident().size())
	# Clearing the gate while regions wait releases them
	s.set_insert_gate(gate)
	_mode = "hold_all"
	_place(cam, Vector2i(10, 0))
	await _frames(80)
	ok(s.get_stats().gated == 9 and _resident().size() == 0, "invalid: held again at a new place")
	s.set_insert_gate(Callable())
	await _frames(80)
	ok(s.get_stats().gated == 0 and _resident().size() == 9, "invalid: clearing the gate releases what waited (%d)" % _resident().size())
	await _free_terrain(cam)
	_clean(dir)


# 7. The ready distance counts only visible regions, so a gated region ends it
func _test_ready_distance() -> void:
	var dir := _root_dir + "/ready"
	_author_block(dir, -3, 20, -2, 2)
	var cam := await _new_terrain(dir, 100, 1)
	var s := _streamer()
	_place(cam, Vector2i(0, 0))
	cam.global_position.x = 0.5 * _span()
	var radius := 0.3 * _span()
	_mode = "set"
	_held = {Vector2i(6, 0): true}
	s.set_insert_gate(gate)
	var id := s.add_keep_path(_row_path(0.5, 14.5), radius)
	await _frames(250)
	var total: float = 14.0 * _span()
	ok(not _t.data.has_region(Vector2i(6, 0)) and s.get_gated_regions().has(Vector2i(6, 0)), "ready: the region at x=6 is loaded but held")
	ok(_t.data.has_region(Vector2i(5, 0)) and _t.data.has_region(Vector2i(7, 0)) and _t.data.has_region(Vector2i(14, 0)), "ready: its neighbours and the end of the path are visible")
	var ready: float = s.get_path_ready_distance(id)
	var expect: float = (6.0 - 0.5) * _span() - radius # Corridor box entry of x=6, from the path start at 0.5 regions
	ok(absf(ready - expect) < 2.0, "ready: the distance ends at the gated region (%.1f, expected %.1f)" % [ready, expect])
	ok(s.get_stats().nearest_missing > 0.0, "ready: nearest_missing sees it")
	_held = {}
	await _frames(100)
	ready = s.get_path_ready_distance(id)
	ok(absf(ready - total) < 1.0 and _t.data.has_region(Vector2i(6, 0)), "ready: released, the whole path is ready again (%.1f of %.1f)" % [ready, total])
	await _free_terrain(cam)
	_clean(dir)


# 8. A gated region that leaves the keep set before it was inserted is dropped and never appears
func _test_evict_before_insert() -> void:
	var dir := _root_dir + "/evict"
	_author_block(dir, -20, 20, -3, 3)
	var cam := await _new_terrain(dir, 49, 1)
	var s := _streamer()
	_mode = "set"
	_held = {Vector2i(1, 0): true, Vector2i(-1, 0): true}
	s.set_insert_gate(gate)
	_place(cam, Vector2i(0, 0))
	await _frames(100)
	ok(s.get_stats().gated == 2 and not _t.data.has_region(Vector2i(1, 0)), "evict: two held")
	var ever := false
	_place(cam, Vector2i(12, 0))
	for f in 150:
		await _frames(1)
		ever = ever or _t.data.has_region(Vector2i(1, 0)) or _t.data.has_region(Vector2i(-1, 0))
	var st := s.get_stats()
	ok(not ever, "evict: the held regions never appeared on the way")
	ok(not s.get_gated_regions().has(Vector2i(1, 0)) and not s.get_gated_regions().has(Vector2i(-1, 0)), "evict: they left the gated list")
	ok(not _locs(s.get_wanted_regions(false)).has(Vector2i(1, 0)) and st.ram_cached == 0 and st.gated == 0, "evict: and the cache (DISK mode, %d cached, %d gated)" % [st.ram_cached, st.gated])
	ok(_resident().size() == 9 and st.free_slots == 49 - 9, "evict: the new area is inserted and the pool is intact (%d resident, %d free)" % [_resident().size(), st.free_slots])
	# Back again: asked again and still held
	_place(cam, Vector2i(0, 0))
	await _frames(120)
	ok(s.get_stats().gated == 2 and not _t.data.has_region(Vector2i(1, 0)), "evict: when it is wanted again the gate still holds it")
	await _free_terrain(cam)
	_clean(dir)


# 9. behind_limit drops held regions behind the direction of travel without ever inserting them
func _test_behind_limit() -> void:
	var dir := _root_dir + "/behind"
	_author_block(dir, -3, 30, -3, 3)
	var cam := await _new_terrain(dir, 100, 2)
	var s := _streamer()
	_mode = "from_x"
	_x_min = -100
	s.set_insert_gate(gate)
	_place(cam, Vector2i(5, 0))
	s.add_keep_path(_row_path(5.5, 25.5), 0.3 * _span())
	_x_min = 0 # Everything x >= 0 is refused
	await _frames(150)
	var held := _locs(s.get_gated_regions())
	ok(held.has(Vector2i(3, 0)) and held.has(Vector2i(4, 0)) and held.has(Vector2i(5, 0)), "behind: the camera area and the path start are held (%d gated)" % held.size())
	var ever := false
	s.behind_limit = _span()
	for f in 40:
		await _frames(1)
		ever = ever or _t.data.has_region(Vector2i(3, 0)) or _t.data.has_region(Vector2i(4, 0))
	held = _locs(s.get_gated_regions())
	ok(not held.has(Vector2i(3, 0)) and held.has(Vector2i(5, 0)), "behind: the region more than a region behind is dropped, the rest stays held")
	ok(not ever and not _t.data.has_region(Vector2i(3, 0)), "behind: it was never inserted")
	ok(s.get_stats().failed == 0, "behind: no failure")
	await _free_terrain(cam)
	_clean(dir)


# 10. Edited regions are still saved when they are evicted while others wait at the gate
func _test_persist() -> void:
	var dir := _root_dir + "/persist"
	_author_block(dir, -3, 30, -3, 3)
	var cam := await _new_terrain(dir, 49, 1)
	_t.streaming_persist_edits = true
	var s := _streamer()
	_mode = "set"
	_held = {Vector2i(1, 0): true}
	s.set_insert_gate(gate)
	_place(cam, Vector2i(0, 0))
	await _frames(100)
	var edited := Vector2i(0, 0)
	ok(_t.data.has_region(edited) and not _t.data.has_region(Vector2i(1, 0)), "persist: the centre is visible, its neighbour held")
	var r: Terrain3DRegion = _t.data.get_region(edited)
	r.get_height_map().set_pixel(10, 10, Color(555.0, 0, 0))
	r.set_modified(true)
	_place(cam, Vector2i(15, 0))
	await _frames(120)
	ok(not _t.data.has_region(edited) and not _t.data.has_region(Vector2i(1, 0)), "persist: both are gone")
	var path := dir + "/" + Terrain3DUtil.location_to_filename(edited)
	var saved: Terrain3DRegion = ResourceLoader.load(path, "Terrain3DRegion", ResourceLoader.CACHE_MODE_IGNORE)
	ok(saved != null and absf(saved.get_height_map().get_pixel(10, 10).r - 555.0) < 0.01, "persist: the edit of the visible region reached the file")
	var other: Terrain3DRegion = ResourceLoader.load(dir + "/" + Terrain3DUtil.location_to_filename(Vector2i(1, 0)), "Terrain3DRegion", ResourceLoader.CACHE_MODE_IGNORE)
	ok(other != null and absf(other.get_height_map().get_pixel(10, 10).r - 5.0) < 0.01, "persist: the held region was left alone on disk")
	await _free_terrain(cam)
	_clean(dir)


# 11. The gate never causes a failed state; a really bad file still fails like before
func _test_retry_and_failed() -> void:
	var dir := _root_dir + "/retry"
	_author_block(dir, -3, 3, -3, 3)
	var f := FileAccess.open(dir + "/" + Terrain3DUtil.location_to_filename(Vector2i(1, 1)), FileAccess.WRITE)
	f.store_buffer(PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8]))
	f.close()
	var cam := await _new_terrain(dir, 49, 1)
	var s := _streamer()
	_mode = "hold_all"
	s.set_insert_gate(gate)
	_place(cam, Vector2i(0, 0))
	await _frames(100)
	var st := s.get_stats()
	ok(st.failed == 1 and st.gated == 8, "retry: only the unreadable file fails, the other eight are held (%d failed, %d gated)" % [st.failed, st.gated])
	ok(not s.get_gated_regions().has(Vector2i(1, 1)), "retry: the failed region is not gated")
	await create_timer(1.0).timeout
	st = s.get_stats()
	ok(st.failed == 1 and st.gated == 8, "retry: held regions do not age into failures")
	_mode = "open"
	await _frames(100)
	ok(_resident().size() == 8, "retry: released, the eight are visible, the bad one is not (%d)" % _resident().size())
	await _free_terrain(cam)
	_clean(dir)


# 12. Window slide and recentring: a held region outside the window waits cached, inside it waits gated
func _test_window_slide() -> void:
	var dir := _root_dir + "/window"
	_author_block(dir, -3, 80, -3, 3)
	var cam := await _new_terrain(dir, 49, 1)
	var s := _streamer()
	_mode = "from_x"
	_x_min = -50
	s.set_insert_gate(gate)
	_place(cam, Vector2i(0, 0))
	s.add_keep_path(_row_path(0.5, 70.5), 0.3 * _span())
	s.keep_cache_limit = 200
	await _frames(200)
	var st := s.get_stats()
	var win: int = _t.data.get_region_map_size()
	ok(_t.data.get_region_count() == 0 and st.gated > 0, "window: everything is held, %d gated" % st.gated)
	ok(st.outside_window > 0, "window: part of the corridor lies beyond the window (%d)" % st.outside_window)
	var origin0: Vector2i = _t.data.get_region_map_origin()
	var all_in := true
	for loc: Vector2i in s.get_gated_regions():
		all_in = all_in and _t.data.get_region_map_index(loc) >= 0
	ok(all_in, "window: only regions inside the window are gated; the others wait cached as before")
	_x_min = 1000 # Everything opens
	var recentres0: int = st.recentres
	_place(cam, Vector2i(win + 10, 0))
	await _frames(300)
	st = s.get_stats()
	ok(st.recentres > recentres0 and _t.data.get_region_map_origin() != origin0, "window: the window moved with the camera (%d recentres)" % (st.recentres - recentres0))
	ok(_t.data.has_region(Vector2i(win + 10, 0)) and st.gated == 0, "window: and the regions there were inserted once the gate opened")
	await _free_terrain(cam)
	_clean(dir)


# 13. RAM mode: a held region that leaves the keep set stays cached and goes through the gate again later
func _test_ram_mode() -> void:
	var dir := _root_dir + "/ram"
	_author_block(dir, -20, 20, -3, 3)
	var cam := await _new_terrain(dir, 49, 1)
	_t.streaming_mode = Terrain3DStreamer.RAM
	var s := _streamer()
	_mode = "set"
	_held = {Vector2i(1, 0): true}
	s.set_insert_gate(gate)
	_place(cam, Vector2i(0, 0))
	await _frames(100)
	ok(s.get_stats().gated == 1 and not _t.data.has_region(Vector2i(1, 0)), "ram: one held")
	_place(cam, Vector2i(12, 0))
	await _frames(100)
	ok(not _t.data.has_region(Vector2i(1, 0)), "ram: never inserted after the move")
	ok(s.get_stats().ram_cached > 0 and s.get_stats().gated == 0, "ram: the body stays cached, no longer gated")
	_held = {}
	_place(cam, Vector2i(0, 0))
	await _frames(100)
	ok(_t.data.has_region(Vector2i(1, 0)) and _resident().size() == 9, "ram: inserted once wanted again with the gate open")
	await _free_terrain(cam)
	_clean(dir)


# 14. The resolver maps virtual locations to a file; they are gated like any other
func resolve(loc: Vector2i) -> Dictionary:
	if loc.x >= 20:
		return {"path": _root_dir + "/resolver/" + Terrain3DUtil.location_to_filename(Vector2i(0, 0)), "read_only": true}
	return {}


func _test_resolver() -> void:
	var dir := _root_dir + "/resolver"
	_author_block(dir, 0, 2, 0, 2)
	var cam := await _new_terrain(dir, 49, 1)
	var s := _streamer()
	var virt: Array[Vector2i] = []
	for x in range(20, 23):
		for y in range(0, 3):
			virt.append(Vector2i(x, y))
	s.set_resolver(resolve)
	s.register_virtual_locations(virt)
	_mode = "set"
	_held = {Vector2i(21, 1): true, Vector2i(20, 1): true}
	s.set_insert_gate(gate)
	_place(cam, Vector2i(21, 1))
	await _frames(300)
	ok(_t.data.has_region(Vector2i(22, 2)) and _t.data.has_region(Vector2i(20, 0)), "resolver: open virtual locations are inserted")
	ok(not _t.data.has_region(Vector2i(21, 1)) and not _t.data.has_region(Vector2i(20, 1)), "resolver: gated virtual locations are not")
	var st := s.get_stats()
	ok(st.gated == 2 and st.failed == 0, "resolver: gated, not failed (%d gated, %d failed)" % [st.gated, st.failed])
	_held = {}
	await _frames(100)
	ok(_t.data.has_region(Vector2i(21, 1)) and _t.data.has_region(Vector2i(20, 1)) and s.get_stats().gated == 0, "resolver: released")
	await _free_terrain(cam)
	_clean(dir)


# 15. scan_directory and abort_pending forget what the gate held
func _test_rescan_abort() -> void:
	var dir := _root_dir + "/rescan"
	_author_block(dir, -3, 3, -3, 3)
	var cam := await _new_terrain(dir, 49, 1)
	var s := _streamer()
	_mode = "hold_all"
	s.set_insert_gate(gate)
	_place(cam, Vector2i(0, 0))
	await _frames(80)
	ok(s.get_stats().gated == 9 and s.get_stats().ram_cached == 9, "rescan: nine held")
	s.abort_pending()
	var st := s.get_stats()
	ok(st.gated == 0 and s.get_gated_regions().is_empty(), "rescan: abort_pending forgets the held regions")
	await _frames(80)
	ok(s.get_stats().gated == 9 and _t.data.get_region_count() == 0, "rescan: and they are asked again")
	s.gate_timeout_ms = 200
	await create_timer(0.5).timeout
	await _frames(20)
	ok(s.get_stats().gate_timeouts == 9 and _resident().size() == 9, "rescan: timeouts counted")
	s.scan_directory()
	st = s.get_stats()
	ok(st.gate_timeouts == 0 and st.gate_wait_ms_max == 0 and st.gated == 0, "rescan: scan_directory resets the gate stats")
	await _free_terrain(cam)
	_clean(dir)


# 16. The governed flight: the gate withholds the destination until the 'trees are ready'. The governor, which
# gets its limit from get_path_ready_distance(), slows and hovers instead of showing bare terrain.
func _flight(p_gated: bool, p_governed: bool, p_release_s: float) -> Dictionary:
	var dir := _root_dir + "/flight"
	var cam := await _new_terrain(dir, 160, 2)
	var s := _streamer()
	var sp := _span()
	var length := 22.0 * sp
	var start := Vector2(0.5 * sp, 0.5 * sp)
	var radius := 1.2 * sp
	var g := FlightGovernor.new()
	g.max_speed = 300.0
	g.max_accel = 300.0
	g.max_jerk = 1500.0
	g.safety = 3.0 * sp
	var heights := PackedFloat32Array()
	for i in int(length / 50.0) + 1:
		heights.append(5.0)
	g.setup(length, heights, 50.0, 5.0, 5.0)
	cam.global_position = Vector3(start.x, 120, start.y)
	_mode = "open"
	if p_gated:
		_mode = "from_x"
		_x_min = 18 # The destination chunks: trees there are not ready
	s.set_insert_gate(gate)
	var pts := PackedVector3Array([Vector3(start.x, 0, start.y), Vector3(start.x + length, 0, start.y)])
	var id := s.add_keep_path(pts, radius)
	s.set_keep_path_ahead(id, 10.0 * sp, 0.0)
	s.behind_limit = sp
	# Wait for the surroundings of the start
	for i in 300:
		await _frames(1)
		var done := true
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				done = done and _t.data.has_region(Vector2i(dx, dy))
		if done and s.get_stats().staged == 0:
			break
	var t0 := Time.get_ticks_msec()
	_release_ms = t0 + int(p_release_s * 1000.0)
	var m := {"holes": 0, "released_at": p_release_s, "arrive": -1.0, "max_x_before_release": 0.0, "hover_frames": 0, "gated_seen_early": 0, "frames": 0}
	var prev := Time.get_ticks_usec()
	var t := 0.0
	while true:
		await physics_frame
		RenderingServer.emit_signal("frame_pre_draw")
		var now := Time.get_ticks_usec()
		var dt := clampf(float(now - prev) * 1e-6, 1.0 / 240.0, 1.0 / 20.0)
		prev = now
		t = float(Time.get_ticks_msec() - t0) * 0.001
		g.step(dt, s.get_path_ready_distance(id) if p_governed else INF)
		var x := start.x + g.distance
		cam.global_position = Vector3(x, g.altitude, start.y)
		m.frames += 1
		var released: bool = t >= p_release_s
		if not released:
			m.max_x_before_release = maxf(m.max_x_before_release, x)
			if g.distance > 0.0 and g.speed < 1.0:
				m.hover_frames += 1
			for dy in range(-1, 2):
				for dx in range(18, 23):
					if _t.data.has_region(Vector2i(dx, dy)):
						m.gated_seen_early += 1
		# Bare terrain: a region in the corridor within the safety distance ahead of the camera is not visible
		var cx := int(floor(x / sp))
		var last_ax := int(floor((x + g.safety) / sp)) if g.speed > 1.0 else cx - 1 # Only while moving
		for ax in range(cx, last_ax + 1):
			if ax < 23 and not _t.data.has_region(Vector2i(ax, 0)):
				m.holes += 1
				break
		if g.distance >= length - 0.5 and m.arrive < 0.0:
			m.arrive = t
		if g.is_done(_t.data.has_region(Vector2i(22, 0)) and _t.data.has_region(Vector2i(21, 0))) or t > 60.0:
			break
	m.done = g.is_done(_t.data.has_region(Vector2i(22, 0)))
	m.clamp_hits = g.clamp_hits
	m.margin = g.min_ready_margin
	m.t_end = t
	m.gated_end = s.get_stats().gated
	m.speed_max = 0.0
	await _free_terrain(cam)
	return m


func _test_flight() -> void:
	var dir := _root_dir + "/flight"
	_author_block(dir, -4, 30, -3, 3)
	# Control: no gate, governed
	var free := await _flight(false, true, 0.0)
	print("FLIGHT free: ", free)
	ok(free.done and free.holes == 0 and free.clamp_hits == 0, "flight: without a gate the governed flight lands with no bare terrain (arrive %.1f s)" % free.arrive)
	# Gate on, the destination chunks are released after 16 s, well after the flight would have arrived
	var release := maxf(free.arrive + 6.0, 14.0)
	var gated := await _flight(true, true, release)
	print("FLIGHT gated: ", gated)
	ok(gated.done, "flight: the gated flight lands (%.1f s)" % gated.t_end)
	ok(gated.holes == 0, "flight: no bare terrain within the safety distance at any frame (%d frames)" % gated.holes)
	ok(gated.clamp_hits == 0, "flight: the failsafe clamp never had to hold the camera")
	ok(gated.gated_seen_early == 0, "flight: no gated chunk was visible before the release")
	ok(gated.hover_frames > 60, "flight: the governor hovered at the edge of the ready terrain (%d frames at rest)" % gated.hover_frames)
	ok(gated.max_x_before_release <= (18.0 - 1.2 - 3.0) * float(RS) + 10.0, "flight: it never went within safety of the first gated chunk (x %.0f)" % gated.max_x_before_release)
	ok(gated.arrive > release - 0.5, "flight: it arrived only once the chunks were released (arrive %.1f s, release %.1f s, free flight %.1f s)" % [gated.arrive, release, free.arrive])
	ok(gated.t_end < release + 12.0, "flight: and landed soon after (%.1f s)" % gated.t_end)
	# Ungoverned: the same gate makes the camera fly into bare terrain, which is what the governor prevents
	var naive := await _flight(true, false, release)
	print("FLIGHT naive: ", naive)
	ok(naive.holes > 0, "flight: control: without the governor the gated chunks are bare terrain for %d frames" % naive.holes)
	_clean(dir)
