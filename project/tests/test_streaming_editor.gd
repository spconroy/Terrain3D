extends SceneTree
## Headless test for streaming settings in the editor and old data versions:
##   godot --headless --path project --script res://tests/test_streaming_editor.gd
##   godot -e --headless --path project --script res://tests/test_streaming_editor.gd
## Run both ways. With -e, Engine.is_editor_hint() is true: streaming must stay
## inactive, every region stays loaded, changing streaming_* never crashes and
## saving writes every region. Without -e, a region file with an old version must
## stream in unmodified and keep its on disk version.
var _fail := 0
var _done := false
var _t: Terrain3D
var _dir := "user://stream_editor_test_data"


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	var d := DirAccess.open("user://")
	if d != null and d.dir_exists("stream_editor_test_data"):
		for f in DirAccess.get_files_at(_dir):
			d.remove("stream_editor_test_data/" + f)
	else:
		DirAccess.make_dir_recursive_absolute(_dir)
	_t = Terrain3D.new()
	root.add_child(_t)
	process_frame.connect(_run)


func _settle(frames: int) -> void:
	for i in range(frames):
		await process_frame
		RenderingServer.emit_signal("frame_pre_draw")


func _run() -> void:
	if _done:
		return
	_done = true
	var editor := Engine.is_editor_hint()
	print("editor hint: ", editor)
	var rs: int = _t.region_size
	for y in range(-1, 2):
		for x in range(-1, 2):
			_t.data.add_region_blank(Vector2i(x, y), false)
			var r: Terrain3DRegion = _t.data.get_region(Vector2i(x, y))
			r.get_height_map().fill(Color(float(10 + x + y * 3), 0, 0))
			r.set_modified(true)
	_t.data.update_maps()
	_t.data.save_directory(_dir)
	ok(DirAccess.get_files_at(_dir).size() == 9, "authored 9 regions on disk")
	# Re-save one file with an old version number, bypassing Terrain3DRegion.save
	# which stamps the current version
	var old_path: String = _dir + "/" + DirAccess.get_files_at(_dir)[0]
	var old: Terrain3DRegion = ResourceLoader.load(old_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	old.set_version(0.9)
	ok(ResourceSaver.save(old, old_path) == OK, "wrote a v0.9 region file")
	var old_loc: Vector2i = old.get_location()
	_t.queue_free()
	await process_frame

	_t = Terrain3D.new()
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = Vector3(rs * 0.5, 50, rs * 0.5)
	_t.streaming_enabled = true
	_t.streaming_slots = 25
	_t.streaming_distance = 1
	_t.data_directory = _dir
	root.add_child(_t)
	_t.set_camera(cam)
	_t.set_clipmap_target(cam)
	await _settle(120)
	var n: int = _t.data.get_region_count()
	if editor:
		ok(not _t.is_streaming_active(), "editor: streaming inactive")
		ok(not _t.data.is_streaming(), "editor: data not in slot pool mode")
		ok(n == 9, "editor: every region loaded (%d)" % n)
		# Change every streaming setting, on and off; nothing may crash or drop data
		_t.streaming_distance = 3
		_t.streaming_slots = 100
		_t.streaming_shape = 1
		_t.streaming_mode = 1
		_t.streaming_concurrent_loads = 5
		_t.streaming_loads_per_frame = 4
		_t.streaming_persist_edits = true
		await _settle(30)
		_t.streaming_enabled = false
		await _settle(10)
		_t.streaming_enabled = true
		await _settle(30)
		ok(_t.data.get_region_count() == 9, "editor: regions intact after changing settings (%d)" % _t.data.get_region_count())
		# Modify every region, save, and require every file to be rewritten
		for y in range(-1, 2):
			for x in range(-1, 2):
				_t.data.set_height(Vector3((x + 0.5) * rs, 0, (y + 0.5) * rs), 77.0)
		var before := {}
		for f in DirAccess.get_files_at(_dir):
			before[f] = FileAccess.get_modified_time(_dir + "/" + f)
		OS.delay_msec(1100)
		_t.data.save_directory(_dir)
		var rewritten := 0
		for f in before:
			if FileAccess.get_modified_time(_dir + "/" + f) > before[f]:
				rewritten += 1
		ok(rewritten == 9, "editor: all modified regions rewritten on save (%d/9)" % rewritten)
		var rl: Terrain3DRegion = ResourceLoader.load(_dir + "/" + Terrain3DUtil.location_to_filename(Vector2i(0, 0)), "", ResourceLoader.CACHE_MODE_IGNORE)
		ok(absf(rl.get_height_map().get_pixel(rs / 2, rs / 2).r - 77.0) < 0.01, "editor: saved file holds the edit")
	else:
		ok(_t.is_streaming_active(), "game: streaming active")
		var r: Terrain3DRegion = _t.data.get_region(old_loc)
		if r == null:
			# Move to the old region so it streams in
			cam.global_position = Vector3((old_loc.x + 0.5) * rs, 50, (old_loc.y + 0.5) * rs)
			await _settle(200)
			r = _t.data.get_region(old_loc)
		ok(r != null, "game: old version region streamed in")
		if r != null:
			ok(absf(r.get_version() - 0.9) < 0.001, "game: version left as on disk (%.2f)" % r.get_version())
			ok(not r.is_modified(), "game: old version region not marked modified")
			var cur: Terrain3DRegion = _t.data.get_region(Vector2i(0, 0))
			print("current-version region modified: ", cur.is_modified() if cur != null else "n/a")
		# Persisted edit still writes the current version
		_t.streaming_persist_edits = true
		var wc := Vector3((old_loc.x + 0.5) * rs, 0, (old_loc.y + 0.5) * rs)
		_t.data.set_height(wc, 55.0)
		cam.global_position = Vector3(rs * 9.5, 50, rs * 0.5)
		await _settle(200)
		var rl: Terrain3DRegion = ResourceLoader.load(old_path, "", ResourceLoader.CACHE_MODE_IGNORE)
		ok(absf(rl.get_version() - 1.1) < 0.001, "game: persisted region written at current version (%.2f)" % rl.get_version())
	print("RESULT: ", "ALL PASS" if _fail == 0 else "%d FAILED" % _fail)
	quit(_fail)

