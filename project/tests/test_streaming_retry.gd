extends SceneTree
## Headless test that a failed streaming load is retried and eventually given up on:
##   godot --headless --path project --script tests/test_streaming_retry.gd
## A region file that is unreadable at first (as during a copy) must stream in once it is
## fixed. One that stays unreadable is requested a bounded number of times, then ignored
## until the directory is rescanned.
const DIR := "user://stream_retry_test"
const RETRY_SECONDS := 5.0 # Terrain3DStreamer::FAIL_RETRY_MSEC
const RETRIES := 3 # Terrain3DStreamer::FAIL_RETRIES
var _fail := 0
var _t: Terrain3D
var _done := false


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR + "/" + f)
	process_frame.connect(_run)


func _wait(p_seconds: float) -> void:
	await create_timer(p_seconds).timeout


func _write(p_name: String, p_bytes: PackedByteArray) -> void:
	var f := FileAccess.open(DIR + "/" + p_name, FileAccess.WRITE)
	f.store_buffer(p_bytes)
	f.close()


func _run() -> void:
	if _done:
		return
	_done = true
	var t0 := Terrain3D.new()
	root.add_child(t0)
	await process_frame
	var rs: int = t0.region_size
	for x in 3:
		t0.data.add_region_blank(Vector2i(x, 0), false)
		t0.data.get_region(Vector2i(x, 0)).get_height_map().fill(Color(float(10 + x), 0, 0))
	t0.data.update_maps()
	t0.data.save_directory(DIR)
	t0.queue_free()
	await process_frame
	var good1: PackedByteArray = FileAccess.get_file_as_bytes(DIR + "/terrain3d_01_00.res")
	var good2: PackedByteArray = FileAccess.get_file_as_bytes(DIR + "/terrain3d_02_00.res")
	var garbage := PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])
	_write("terrain3d_01_00.res", garbage)
	_write("terrain3d_02_00.res", garbage)

	_t = Terrain3D.new()
	_t.assets = Terrain3DAssets.new()
	_t.collision_mode = Terrain3DCollision.DISABLED
	_t.streaming_enabled = true
	_t.streaming_distance = 2
	_t.streaming_slots = 49
	_t.data_directory = DIR
	root.add_child(_t)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = Vector3(rs * 0.5, 50, rs * 0.5)
	_t.set_camera(cam)
	_t.set_clipmap_target(cam)
	await process_frame
	await _wait(2.0)
	ok(_t.data.has_region(Vector2i(0, 0)), "healthy region streams in")
	ok(not _t.data.has_region(Vector2i(1, 0)), "unreadable region is not loaded")
	ok(int(_t.get_streaming_stats().get("failed", 0)) == 2, "both unreadable regions are marked failed")

	# Region 1 is fixed (a copy finished): it must be retried and stream in without a rescan.
	_write("terrain3d_01_00.res", good1)
	await _wait(RETRY_SECONDS + 2.0)
	ok(_t.data.has_region(Vector2i(1, 0)), "region loads on retry once its file is fixed")
	var h1: float = _t.data.get_height(Vector3(rs * 1.5, 0, rs * 0.5))
	ok(absf(h1 - 11.0) < 0.01, "retried region has its data (%.1f)" % h1)

	# Region 2 stays unreadable: after FAIL_RETRIES attempts it is given up on, even once fixed.
	await _wait(RETRY_SECONDS * RETRIES)
	_write("terrain3d_02_00.res", good2)
	await _wait(RETRY_SECONDS + 2.0)
	ok(not _t.data.has_region(Vector2i(2, 0)), "region that kept failing is given up on until a rescan")
	_t.get_streamer().scan_directory()
	await _wait(2.0)
	ok(_t.data.has_region(Vector2i(2, 0)), "rescan clears the give up and loads it")

	DirAccess.remove_absolute(DIR + "/terrain3d_00_00.res")
	print("SUITE ", "GREEN" if _fail == 0 else "RED (%d)" % _fail)
	quit(_fail)
