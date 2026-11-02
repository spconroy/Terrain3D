extends SceneTree
## Headless test for streaming at large distances on a 40x40 region world:
##   godot --headless --path project --script tests/test_region_streaming_distance.gd
## After the loaded set settles, every region within streaming_distance of the
## target must be resident, for both shapes, at small and large distances, after
## walking and after teleports.
var _fail := 0
var _done := false
var _t: Terrain3D
var _dir := "user://stream_dist_data_%d" % OS.get_process_id()
const HALF := 16
const RS := 64


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(_dir)
	for f in DirAccess.get_files_at(_dir):
		DirAccess.remove_absolute(_dir + "/" + f)
	process_frame.connect(_run)


func _settle(max_frames: int) -> void:
	var last := -1
	var stable := 0
	for i in range(max_frames):
		await physics_frame
		RenderingServer.emit_signal("frame_pre_draw")
		var s: Dictionary = _t.get_streaming_stats()
		var n: int = _t.data.get_region_count() + int(s.get("inflight", 0))
		if n == last:
			stable += 1
			if stable >= 20:
				return
		else:
			stable = 0
			last = n


# Count known regions within distance of focus (respecting shape) that are missing.
func _missing(floc: Vector2i, dist: int, circle: bool) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy in range(-dist, dist + 1):
		for dx in range(-dist, dist + 1):
			var loc := floc + Vector2i(dx, dy)
			if loc.x < -HALF or loc.x >= HALF or loc.y < -HALF or loc.y >= HALF:
				continue
			if circle and Vector2(dx, dy).length() > dist:
				continue
			if not _t.data.has_region(loc):
				out.append(loc)
	return out


func _move(cam: Camera3D, loc: Vector2i) -> void:
	cam.global_position = Vector3((loc.x + 0.5) * RS, 50, (loc.y + 0.5) * RS)


func _check(cam: Camera3D, loc: Vector2i, tag: String) -> void:
	_move(cam, loc)
	await _settle(1500)
	var d: int = _t.streaming_distance
	var m := _missing(loc, d, _t.streaming_shape == Terrain3DStreamer.CIRCLE)
	var st: Dictionary = _t.get_streaming_stats()
	ok(m.is_empty(), "%s: all regions within %d resident, missing %d %s (resident %d, free %d, failed %d)" % [
			tag, d, m.size(), str(m.slice(0, 4)), _t.data.get_region_count(),
			_t.data.get_free_slot_count(), int(st.get("failed", 0))])


func _run() -> void:
	if _done:
		return
	_done = true
	# Author one blank region, then clone its file to every location of the world.
	_t = Terrain3D.new()
	root.add_child(_t)
	_t.region_size = RS
	_t.data.add_region_blank(Vector2i(0, 0), false)
	_t.data.save_region(Vector2i(0, 0), _dir, false)
	var src := _dir + "/" + Terrain3DUtil.location_to_filename(Vector2i(0, 0))
	for y in range(-HALF, HALF):
		for x in range(-HALF, HALF):
			if x == 0 and y == 0:
				continue
			DirAccess.copy_absolute(src, _dir + "/" + Terrain3DUtil.location_to_filename(Vector2i(x, y)))
	# Files outside the 32x32 region map (-16..15) must be ignored, not streamed at a wrong
	# location (they used to land at (0,0) and be evicted again every frame).
	for y in range(-HALF, HALF + 1):
		for x in [HALF, HALF + 1]:
			DirAccess.copy_absolute(src, _dir + "/" + Terrain3DUtil.location_to_filename(Vector2i(x, y)))
	for x in range(-HALF, HALF):
		DirAccess.copy_absolute(src, _dir + "/" + Terrain3DUtil.location_to_filename(Vector2i(x, HALF)))
	ok(DirAccess.get_files_at(_dir).size() > HALF * HALF * 4, "authored %d region files" % DirAccess.get_files_at(_dir).size())
	_t.queue_free()
	await physics_frame

	_t = Terrain3D.new()
	_t.assets = Terrain3DAssets.new()
	_t.streaming_enabled = true
	_t.streaming_distance = 4
	_t.data_directory = _dir
	root.add_child(_t)
	var cam := Camera3D.new()
	root.add_child(cam)
	_move(cam, Vector2i(0, 0))
	_t.set_camera(cam)
	_t.set_clipmap_target(cam)
	await physics_frame
	ok(_t.data.is_streaming(), "streaming active")
	ok(int(_t.get_streaming_stats().get("known", 0)) == HALF * HALF * 4, "scan found the whole world, ignoring out of bounds files")

	for shape in [Terrain3DStreamer.SQUARE, Terrain3DStreamer.CIRCLE]:
		_t.streaming_shape = shape
		var sname := "square" if shape == Terrain3DStreamer.SQUARE else "circle"
		for d in [4, 10, 15]:
			_t.streaming_distance = d
			var tag := "%s d%d" % [sname, _t.streaming_distance]
			await _check(cam, Vector2i(0, 0), tag + " start")
			# Walk east in single region steps, then settle.
			for x in range(1, 7):
				_move(cam, Vector2i(x, 0))
				for f in range(6):
					await physics_frame
			await _check(cam, Vector2i(6, 0), tag + " walked")
			# Teleport across the world, and back.
			await _check(cam, Vector2i(-9, -8), tag + " teleport")
			await _check(cam, Vector2i(4, 6), tag + " teleport2")
			# Rapid hops that outrun the loads.
			for i in range(12):
				_move(cam, Vector2i(-10 + i * 2, -8 + i))
				for f in range(3):
					await physics_frame
			await _check(cam, Vector2i(9, 1), tag + " after rapid hops")
			# Against the east and south edges of the world, next to the ignored files.
			await _check(cam, Vector2i(HALF - 2, HALF - 3), tag + " world corner")

	print("SUITE ", "GREEN" if _fail == 0 else "RED (%d)" % _fail)
	quit(_fail)
