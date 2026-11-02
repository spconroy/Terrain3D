extends SceneTree
## Headless test for the streaming path resolver:
##   godot --headless --path project --script res://tests/test_streaming_resolver.gd
## Several locations share one library file with rotation/mirror. Checks default
## parity without a resolver, exact per-pixel transforms of the height, control and
## color maps, read-only regions never reaching the disk, and a bad resolver path.
const RS := 256
var _fail := 0
var _done := false
var _t: Terrain3D
var _dir := "user://resolver_test_data_%d" % OS.get_process_id()
var _lib := ""
var _resolver_calls := 0
var _resolver_on_main := true
var _table := {}


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(_dir)
	_lib = _dir + "/lib_a.res"
	process_frame.connect(_run)


func _settle(max_frames: int) -> void:
	var last: int = -1
	var stable := 0
	for i in range(max_frames):
		await process_frame
		RenderingServer.emit_signal("frame_pre_draw")
		var n: int = _t.data.get_region_count()
		if n == last:
			stable += 1
			if stable >= 15:
				return
		else:
			stable = 0
			last = n


# Every map is 4 bytes per pixel (RF, RF, RGBA8), so patterns are built as raw bytes
func _pattern(kind: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(RS * RS * 4)
	for y in RS:
		for x in RS:
			var o := (y * RS + x) * 4
			match kind:
				0: # height: unique, exactly representable floats
					b.encode_float(o, float(x + y * RS) * 0.5)
				1: # control: arbitrary bit patterns, not valid floats
					b.encode_u32(o, ((x * 7919 + y * 104729 + 12345) * 2654435761) & 0xFFFFFFFF)
				_: # color
					b.encode_u32(o, ((x * 3) | ((y * 5) << 8) | (((x ^ y) & 255) << 16) | (255 << 24)))
	return b


# Independent reference, sampled on a grid plus the corners (a full per-pixel pass in
# GDScript is too slow at 256 px). Output = clockwise quarter turns of the mirrored
# (x flipped) source; a clockwise turn maps output (x, y) back to source (y, RS-1-x).
func _matches(got: PackedByteArray, src: PackedByteArray, rot: int, mirror: bool) -> bool:
	var pts: Array[Vector2i] = [Vector2i(0, 0), Vector2i(RS - 1, 0), Vector2i(0, RS - 1), Vector2i(RS - 1, RS - 1)]
	for y in range(0, RS, 3):
		for x in range(0, RS, 5):
			pts.append(Vector2i(x, y))
	for p in pts:
		var sx := p.x
		var sy := p.y
		for r in range(rot):
			var nx := sy
			sy = RS - 1 - sx
			sx = nx
		if mirror:
			sx = RS - 1 - sx
		var so := (sy * RS + sx) * 4
		var go := (p.y * RS + p.x) * 4
		for k in 4:
			if got[go + k] != src[so + k]:
				return false
	return true


func _bytes(img: Image) -> PackedByteArray:
	return img.get_data().slice(0, RS * RS * 4)


func _new_terrain(persist: bool) -> void:
	_t = Terrain3D.new()
	_t.vertex_spacing = 1.0
	_t.streaming_enabled = true
	_t.streaming_slots = 25
	_t.streaming_distance = 1
	_t.streaming_persist_edits = persist
	_t.data_directory = _dir
	root.add_child(_t)


func _cam_at(loc: Vector2i) -> Camera3D:
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = Vector3((loc.x + 0.5) * RS, 50, (loc.y + 0.5) * RS)
	_t.set_camera(cam)
	_t.set_clipmap_target(cam)
	return cam


func resolve(loc: Vector2i) -> Dictionary:
	_resolver_calls += 1
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		_resolver_on_main = false
	return _table.get(loc, {})


func _run() -> void:
	if _done:
		return
	_done = true
	var hp := _pattern(0)
	var cp := _pattern(1)
	var kp := _pattern(2)

	ok(_matches(hp, hp, 4, false) and _matches(hp, hp, 0, true) == false, "reference sanity: 4 turns identity, mirror differs")

	# Author: the library file, and an ordinary file for location (0,0)
	var classic := Terrain3D.new()
	root.add_child(classic)
	classic.data.add_region_blank(Vector2i(0, 0), false)
	var r: Terrain3DRegion = classic.data.get_region(Vector2i(0, 0))
	r.set_height_map(Image.create_from_data(RS, RS, false, Image.FORMAT_RF, hp))
	r.set_control_map(Image.create_from_data(RS, RS, false, Image.FORMAT_RF, cp))
	r.set_color_map(Image.create_from_data(RS, RS, false, Image.FORMAT_RGBA8, kp))
	r.calc_height_range()
	r.set_modified(true)
	var hr: Vector2 = r.get_height_range()
	ok(r.save(_lib, false) == OK, "library file written")
	r.get_height_map().fill(Color(777.0, 0, 0))
	r.calc_height_range()
	r.set_modified(true)
	classic.data.save_region(Vector2i(0, 0), _dir, false)
	var own_file := _dir + "/" + Terrain3DUtil.location_to_filename(Vector2i(0, 0))
	ok(FileAccess.file_exists(own_file), "ordinary location file written")
	classic.queue_free()
	await process_frame
	var lib_md5 := FileAccess.get_md5(_lib)
	var own_md5 := FileAccess.get_md5(own_file)

	# 1. Default parity: no resolver, location (0,0) streams from its own file
	_new_terrain(false)
	_cam_at(Vector2i(0, 0))
	await _settle(300)
	ok(_t.data.has_region(Vector2i(0, 0)), "parity: ordinary file streams without a resolver")
	var h0: float = _t.data.get_height(Vector3(5, 0, 5))
	ok(absf(h0 - 777.0) < 0.01, "parity: body from its own file (%.1f)" % h0)
	ok(_t.data.get_region_count() == 1, "parity: nothing else known (%d)" % _t.data.get_region_count())
	_t.queue_free()
	await process_frame

	# 2. Resolver: nine locations around (1,0), most sharing the one library file
	_table = {
		Vector2i(1, 0): {"path": _lib, "rotation": 0, "mirror": false, "read_only": true},
		Vector2i(2, 0): {"path": _lib, "rotation": 0, "mirror": false, "read_only": true},
		Vector2i(1, 1): {"path": _lib, "rotation": 1, "mirror": false, "read_only": true},
		Vector2i(0, 1): {"path": _lib, "rotation": 2, "mirror": false, "read_only": true},
		Vector2i(2, 1): {"path": _lib, "rotation": 3, "mirror": false, "read_only": true},
		Vector2i(2, -1): {"path": _lib, "rotation": 0, "mirror": true, "read_only": true},
		Vector2i(1, -1): {"path": _lib, "rotation": 1, "mirror": true, "read_only": true},
		Vector2i(0, -1): {"path": "res://does_not_exist.res", "read_only": true},
	}
	_new_terrain(true)
	var streamer: Terrain3DStreamer = _t.get_streamer()
	streamer.set_resolver(resolve)
	var virt: Array[Vector2i] = []
	for k in _table:
		virt.append(k)
	streamer.register_virtual_locations(virt)
	_cam_at(Vector2i(1, 0))
	await _settle(400)
	ok(_resolver_calls > 0, "resolver called (%d)" % _resolver_calls)
	ok(_resolver_on_main, "resolver only called on the main thread")
	ok(_t.data.has_region(Vector2i(0, 0)), "resolver {} falls back to the ordinary file")
	ok(absf(_t.data.get_height(Vector3(5, 0, 5)) - 777.0) < 0.01, "ordinary location unchanged by resolver")
	var shared: Array[Vector2i] = [Vector2i(1, 0), Vector2i(2, 0)]
	for k in _table:
		if k != Vector2i(0, -1):
			ok(_t.data.has_region(k), "virtual location %s loaded" % k)
	var a: Terrain3DRegion = _t.data.get_region(Vector2i(1, 0))
	var b: Terrain3DRegion = _t.data.get_region(Vector2i(2, 0))
	ok(a != b and a.get_location() == Vector2i(1, 0) and b.get_location() == Vector2i(2, 0),
			"shared file: two distinct bodies with their own locations")
	ok(_bytes(a.get_height_map()) == _bytes(b.get_height_map()) and _bytes(a.get_control_map()) == _bytes(b.get_control_map()),
			"shared file: identical bodies")
	ok(_bytes(a.get_height_map()) == hp and _bytes(a.get_control_map()) == cp and _bytes(a.get_color_map()) == kp,
			"rotation 0: identity")
	for k in _table:
		var e: Dictionary = _table[k]
		if k == Vector2i(0, -1) or not _t.data.has_region(k):
			continue
		var reg: Terrain3DRegion = _t.data.get_region(k)
		var rot: int = e["rotation"]
		var mir: bool = e["mirror"]
		var tag := "rot %d%s at %s" % [rot, " mirror" if mir else "", k]
		ok(_matches(_bytes(reg.get_height_map()), hp, rot, mir), "height exact: " + tag)
		ok(_matches(_bytes(reg.get_control_map()), cp, rot, mir), "control exact (bits intact): " + tag)
		ok(_matches(_bytes(reg.get_color_map()), kp, rot, mir), "color exact: " + tag)
		ok(reg.get_height_range().is_equal_approx(hr), "height range kept: " + tag)
		ok(reg.is_read_only(), "flagged read only: " + tag)
	var st: Dictionary = streamer.get_stats()
	ok(int(st["failed"]) == 1 and not _t.data.has_region(Vector2i(0, -1)),
			"invalid resolver path: clean failure, no region (failed=%d)" % int(st["failed"]))

	ok(_t.data.get_region(Vector2i(1, 0)).save(_dir + "/should_not_exist.res") == ERR_UNAUTHORIZED, "Terrain3DRegion.save refuses a read only region")
	ok(not _t.data.get_region(Vector2i(0, 0)).is_read_only(), "ordinary region is not read only")

	# 3. Read only regions never reach the disk, even with persist_edits on
	_t.data.set_height(Vector3(2 * RS + 35, 0, 3), 99.0)
	ok(absf(_t.data.get_height(Vector3(2 * RS + 35, 0, 3)) - 99.0) < 0.01, "edit applied to a read only region while resident")
	var cam: Camera3D = _t.get_camera() as Camera3D
	cam.global_position = Vector3(9.5 * RS, 50, 0.5 * RS) # everything evicts
	await _settle(400)
	ok(not _t.data.has_region(Vector2i(2, 0)), "read only region evicted")
	ok(not FileAccess.file_exists(_dir + "/" + Terrain3DUtil.location_to_filename(Vector2i(2, 0))), "persist_edits did not write a file for the reused location")
	ok(FileAccess.get_md5(_lib) == lib_md5, "library file untouched")
	ok(FileAccess.get_md5(own_file) == own_md5, "ordinary file untouched")
	var files := DirAccess.get_files_at(_dir)
	ok(files.size() == 2 and not files.has("should_not_exist.res"), "only the two authored files on disk (%s)" % str(files))
	cam.global_position = Vector3(1.5 * RS, 50, 0.5 * RS)
	await _settle(400)
	ok(_t.data.has_region(Vector2i(2, 0)), "reused location streams back in")
	ok(absf(_t.data.get_height(Vector3(2 * RS + 35, 0, 3)) - float(35 + 3 * RS) * 0.5) < 0.01,
			"edit to a read only region was discarded on eviction")

	print("SUITE ", "GREEN" if _fail == 0 else "RED (%d)" % _fail)
	quit(_fail)
