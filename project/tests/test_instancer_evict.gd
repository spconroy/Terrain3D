extends SceneTree
## Headless test: instancer MMIs must follow streamed region residency.
##   godot --headless --path project --script res://tests/test_instancer_evict.gd
var _fail := 0
var _per := 0
var _extra := 0 # cells added by the test to region (0,0)
var _done := false
var _t: Terrain3D
var _dir := "user://stream_inst_test_data"
const COUNT := 20


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	var d := DirAccess.open("user://")
	if d != null and d.dir_exists("stream_inst_test_data"):
		for f in DirAccess.get_files_at(_dir):
			d.remove("stream_inst_test_data/" + f)
	else:
		DirAccess.make_dir_recursive_absolute(_dir)
	_t = Terrain3D.new()
	root.add_child(_t)
	_t.vertex_spacing = 1.0
	process_frame.connect(_run)


func _pump() -> void:
	await process_frame
	# Headless never emits frame_pre_draw; pump the instancer queue like a renderer.
	RenderingServer.emit_signal("frame_pre_draw")


func _settle(max_frames: int) -> void:
	var last := -1
	var stable := 0
	for i in range(max_frames):
		await _pump()
		var n: int = _t.data.get_region_count()
		if n == last:
			stable += 1
			if stable >= 15:
				return
		else:
			stable = 0
			last = n


func _instance_total(only: Vector2i = Vector2i(2147483647, 2147483647)) -> int:
	var n := 0
	for loc in _t.data.get_region_locations():
		if only.x != 2147483647 and loc != only:
			continue
		var r: Terrain3DRegion = _t.data.get_region(loc)
		for mesh_id in r.instances:
			for cell in r.instances[mesh_id]:
				n += (r.instances[mesh_id][cell][0] as Array).size()
	return n


func _match(msg: String) -> void:
	var res: Array = _t.data.get_region_locations()
	var mm: Array = _t.instancer.get_mmi_region_locations()
	res.sort()
	mm.sort()
	ok(_t.instancer.get_mmi_count() == _per * res.size() + (_extra if res.has(Vector2i(0, 0)) else 0),
			"%s: MMI cell count (%d)" % [msg, _t.instancer.get_mmi_count()])
	ok(res == mm, "%s: MMI regions == resident regions (%s vs %s)" % [msg, mm, res])


func _run() -> void:
	if _done:
		return
	_done = true
	var rs: int = _t.region_size
	var ma := Terrain3DMeshAsset.new()
	ma.set_generated_type(Terrain3DMeshAsset.TYPE_TEXTURE_CARD)
	_t.assets.set_mesh_asset(0, ma)
	for y in range(-2, 3):
		for x in range(-2, 3):
			_t.data.add_region_blank(Vector2i(x, y), false)
			var xforms: Array[Transform3D] = []
			for i in COUNT:
				xforms.append(Transform3D(Basis(), Vector3(x * rs + i * 10.0 + 5.0, 10, y * rs + 5.0)))
			_t.instancer.add_transforms(0, xforms)
			_t.data.get_region(Vector2i(x, y)).set_modified(true)
	_t.data.update_maps()
	for y in range(-2, 3):
		for x in range(-2, 3):
			_t.data.save_region(Vector2i(x, y), _dir, false)
	_t.queue_free()
	await process_frame

	_t = Terrain3D.new()
	var ma2 := Terrain3DMeshAsset.new()
	ma2.set_generated_type(Terrain3DMeshAsset.TYPE_TEXTURE_CARD)
	_t.assets = Terrain3DAssets.new()
	_t.assets.set_mesh_asset(0, ma2)
	_t.streaming_enabled = true
	_t.streaming_slots = 25
	_t.streaming_distance = 1
	_t.data_directory = _dir
	root.add_child(_t)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = Vector3(rs * 0.5, 50, rs * 0.5)
	_t.set_camera(cam)
	_t.set_clipmap_target(cam)
	await process_frame
	await _settle(400)
	_per = _t.instancer.get_mmi_count() / 9
	_match("initial")
	ok(_instance_total() == 9 * COUNT, "initial: instance data loaded (%d)" % _instance_total())

	# Fast churn: hop every N frames (N small = evictions while loads are in flight).
	for wait in [0, 1, 2, 5]:
		await _churn(cam, wait, 80, true)
		_match("churn wait=%d" % wait)

	# No render frames between hops: queued updates pile up across many evictions.
	await _churn(cam, 1, 80, false)
	await _pump()
	await _settle(400)
	_match("churn without frame_pre_draw")

	# RAM resident mode: bodies park in the cache, MMIs must still follow residency.
	_t.streaming_mode = Terrain3DStreamer.RAM
	for wait in [0, 2]:
		await _churn(cam, wait, 80, true)
		_match("ram churn wait=%d" % wait)
	_t.streaming_mode = Terrain3DStreamer.DISK
	await _settle(400)
	_match("after leaving ram mode")

	# Runtime added instances survive a persisted eviction and come back with the region.
	_t.streaming_persist_edits = true
	cam.global_position = Vector3(rs * 0.5, 50, rs * 0.5)
	await _settle(400)
	var xf: Array[Transform3D] = [Transform3D(Basis(), Vector3(rs * 0.5, 10, rs * 0.5)), Transform3D(Basis(), Vector3(rs * 0.5 + 3, 10, rs * 0.5))]
	_t.instancer.add_transforms(0, xf)
	_t.data.get_region(Vector2i(0, 0)).set_modified(true)
	_extra = 1
	await _pump()
	var before := _instance_total(Vector2i(0, 0))
	cam.global_position = Vector3(rs * 6.5, 50, rs * 0.5)
	await _settle(400)
	ok(not _t.data.has_region(Vector2i(0, 0)), "persist: region evicted")
	_match("persist: after far hop")
	cam.global_position = Vector3(rs * 0.5, 50, rs * 0.5)
	await _settle(400)
	_match("persist: after return")
	ok(_instance_total(Vector2i(0, 0)) == before and before == COUNT + 2, "persist: runtime instances saved on eviction and reloaded (%d/%d)" % [_instance_total(Vector2i(0, 0)), before])
	_t.streaming_persist_edits = false

	# Hop away and straight back repeatedly: re-adding the same region must not duplicate or leak.
	for i in range(20):
		cam.global_position = Vector3(rs * 6.5, 50, rs * 0.5)
		for f in range(randi_range(1, 4)):
			await _pump()
		cam.global_position = Vector3(rs * 0.5, 50, rs * 0.5)
		for f in range(randi_range(1, 4)):
			await _pump()
	await _settle(400)
	_match("re-add same region")

	# Live toggles rebuild the terrain; no MMIs may survive from the old one.
	_t.streaming_enabled = false
	await _settle(400)
	_match("classic after live disable")
	_t.streaming_enabled = true
	await _settle(400)
	_match("streaming after live enable")
	_t.streaming_slots = 49
	await _settle(400)
	_match("after slot rebuild")

	# A second mesh whose asset is removed while its MMIs exist must not strand them on eviction.
	cam.global_position = Vector3(rs * 0.5, 50, rs * 0.5)
	await _settle(400)
	var mb := Terrain3DMeshAsset.new()
	mb.set_generated_type(Terrain3DMeshAsset.TYPE_TEXTURE_CARD)
	_t.assets.set_mesh_asset(1, mb)
	var xb: Array[Transform3D] = [Transform3D(Basis(), Vector3(rs * 0.5, 10, rs * 0.5 + 40))]
	_t.instancer.add_transforms(1, xb)
	await _pump()
	_t.assets.set_mesh_asset(1, null)
	await _pump()
	cam.global_position = Vector3(rs * 6.5, 50, rs * 0.5)
	await _settle(400)
	await _pump()
	ok(_t.instancer.get_mmi_count() == 0 or _t.data.get_region_count() > 0, "removed mesh asset: no MMIs stranded (%d MMIs, %d regions)" % [
			_t.instancer.get_mmi_count(), _t.data.get_region_count()])
	_extra = 0
	_match("removed mesh asset")

	print("SUITE ", "GREEN" if _fail == 0 else "RED (%d)" % _fail)
	quit(_fail)


func _churn(cam: Camera3D, wait: int, hops: int, pump: bool) -> void:
	var rs: int = _t.region_size
	seed(11 + wait)
	for i in range(hops):
		cam.global_position = Vector3((randi_range(-2, 2) + 0.5) * rs, 50, (randi_range(-2, 2) + 0.5) * rs)
		for f in range(wait):
			if pump:
				await _pump()
			else:
				await process_frame
	await _settle(400)
