extends SceneTree
## Headless test for Terrain3D.color_map_enabled together with region streaming:
##   godot --headless --path project --script res://tests/test_color_map_streaming.gd
## Asserts that a disabled color map allocates no pooled color array, that the pool
## rebuilds when the option is toggled live, that regions streamed while disabled keep
## (and never gain) color data, that persisted eviction saves keep color, and that
## compressed color modes (keep uncompressed on and off) stream correctly.
var _fail := 0
var _t: Terrain3D
var _cam: Camera3D
var _base := "user://cm_stream_test_%d" % OS.get_process_id()
var _rs := 256


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _same(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.02 and absf(a.g - b.g) < 0.02 and absf(a.b - b.b) < 0.02 and absf(a.a - b.a) < 0.02


func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _settle(max_frames: int) -> void:
	var last := -1
	var stable := 0
	for i in range(max_frames):
		await process_frame
		RenderingServer.emit_signal("frame_pre_draw")
		var n: int = _t.data.get_region_count()
		# Also wait for the worker thread saves of evicted regions: the persist checks read those files
		if n == last and int(_t.get_streaming_stats().get("saving", 0)) == 0:
			stable += 1
			if stable >= 15:
				return
		else:
			stable = 0
			last = n


func _clean(p_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(p_dir)
	for f in DirAccess.get_files_at(p_dir):
		DirAccess.remove_absolute(p_dir + "/" + f)


func _sig(x: int, y: int) -> Color:
	return Color(0.2 * (x + 2), 0.2 * (y + 2), 0.5, 1.0)


func _file(p_dir: String, p_loc: Vector2i) -> String:
	return p_dir + "/" + Terrain3DUtil.location_to_filename(p_loc)


# Author a 3x3 island. Region (x, y) is painted with a signature color unless p_blank_color
func _author(p_dir: String, p_mode: int, p_keep_uncompressed: bool, p_blank_color: bool = false) -> void:
	_clean(p_dir)
	var t := Terrain3D.new()
	t.vertex_spacing = 1.0
	root.add_child(t)
	await process_frame
	for y in range(-1, 2):
		for x in range(-1, 2):
			t.data.add_region_blank(Vector2i(x, y), false)
			var r: Terrain3DRegion = t.data.get_region(Vector2i(x, y))
			r.get_height_map().fill(Color(float(10 + x + y * 3), 0, 0))
			if p_blank_color:
				r.clear_color_map()
			else:
				r.get_color_map().fill(_sig(x, y))
				r.get_color_map().generate_mipmaps()
				if p_mode != Terrain3D.COMPRESS_NONE:
					# Export builds cannot compress, so author the compressed map by hand
					var c: Image = r.get_color_map().duplicate()
					c.compress_from_channels(p_mode as Image.CompressMode, Image.USED_CHANNELS_RGBA)
					r.set_compressed_color_map(c)
					if not p_keep_uncompressed:
						r.clear_color_map()
			r.take_over_path(_file(p_dir, Vector2i(x, y)))
			ResourceSaver.save(r, r.resource_path, ResourceSaver.FLAG_COMPRESS)
	t.queue_free()
	await process_frame


func _stream(p_dir: String, p_color: bool, p_mode: int = 5, p_keep: bool = true, p_persist: bool = false) -> void:
	if is_instance_valid(_t):
		_t.queue_free()
		await process_frame
	_t = Terrain3D.new()
	_t.assets = Terrain3DAssets.new()
	_t.color_map_enabled = p_color
	_t.color_compress_mode = p_mode
	_t.keep_uncompressed_color = p_keep
	_t.streaming_enabled = true
	_t.streaming_slots = 25
	_t.streaming_distance = 1
	_t.streaming_persist_edits = p_persist
	_t.data_directory = p_dir
	root.add_child(_t)
	if _cam == null:
		_cam = Camera3D.new()
		root.add_child(_cam)
	_cam.global_position = Vector3(_rs * 0.5, 50, _rs * 0.5)
	_t.set_camera(_cam)
	_t.set_clipmap_target(_cam)
	await process_frame
	await _settle(400)


func _run() -> void:
	var rs := _rs
	var d_plain := _base + "/plain"
	await _author(d_plain, Terrain3D.COMPRESS_NONE, true)
	var centre := Vector3(rs * 0.5, 0, rs * 0.5)

	# Disabled from the start: no pooled color array, regions resident, color untouched
	await _stream(d_plain, false)
	ok(_t.data.is_streaming(), "disabled: streaming active")
	ok(_t.data.get_region_count() == 9, "disabled: 3x3 loaded (%d)" % _t.data.get_region_count())
	ok(_t.data.get_color_maps_rid() == RID(), "disabled: no color array allocated in the pool")
	ok(_t.data.get_height_maps_rid() != RID() and _t.data.get_control_maps_rid() != RID(), "disabled: height/control pool intact")
	ok(_t.data.get_free_slot_count() == 25 - 9, "disabled: slots accounted (%d free)" % _t.data.get_free_slot_count())
	ok(absf(_t.data.get_height(centre) - 10.0) < 0.01, "disabled: heights stream")
	ok(_same(_t.data.get_pixel(Terrain3DRegion.TYPE_COLOR, centre), _sig(0, 0)), "disabled: region keeps its color data")
	_cam.global_position = Vector3(rs * 2.5, 50, rs * 0.5)
	await _settle(400)
	_cam.global_position = Vector3(rs * 0.5, 50, rs * 0.5)
	await _settle(400)
	ok(_t.data.get_color_maps_rid() == RID(), "disabled: still no color array after churn")
	ok(_t.data.get_free_slot_count() + _t.data.get_region_count() == 25, "disabled: no slot leaked")

	# Live toggle on: the pool is rebuilt with a color array and the ring reloads
	_t.color_map_enabled = true
	await _settle(400)
	ok(_t.data.is_streaming(), "toggle on: still streaming")
	ok(_t.data.get_color_maps_rid() != RID(), "toggle on: color array allocated")
	ok(_t.data.get_region_count() == 9, "toggle on: ring reloaded (%d)" % _t.data.get_region_count())
	ok(_same(_t.data.get_pixel(Terrain3DRegion.TYPE_COLOR, centre), _sig(0, 0)), "toggle on: color data intact")
	_t.color_map_enabled = false
	await _settle(400)
	ok(_t.data.get_color_maps_rid() == RID(), "toggle off: color array freed")
	ok(_t.data.get_region_count() == 9 and _t.data.is_streaming(), "toggle off: ring reloaded, streaming")
	ok(_t.data.get_free_slot_count() + _t.data.get_region_count() == 25, "toggle off: no slot leaked")

	# Regions saved without color are not given a color map while disabled, but are when enabled
	var d_nocol := _base + "/nocolor"
	await _author(d_nocol, Terrain3D.COMPRESS_NONE, true, true)
	await _stream(d_nocol, false)
	var r00: Terrain3DRegion = _t.data.get_region(Vector2i(0, 0))
	ok(r00 != null and r00.get_color_map() == null, "nocolor: no color map allocated while disabled")
	ok(_t.data.get_color_maps_rid() == RID(), "nocolor: no color array")
	await _stream(d_nocol, true)
	r00 = _t.data.get_region(Vector2i(0, 0))
	ok(r00 != null and r00.get_color_map() != null and r00.get_color_map().has_mipmaps(), "nocolor: enabled sanitizes a mipmapped blank")

	# Persisted eviction keeps the on-disk color, disabled and enabled
	for enabled in [false, true]:
		await _stream(d_plain, enabled, 5, true, true)
		var h := 77.0 if not enabled else 78.0
		_t.data.set_height(Vector3(10.0, 0, 10.0), h)
		_cam.global_position = Vector3(rs * 6.5, 50, rs * 0.5)
		await _settle(400)
		ok(not _t.data.has_region(Vector2i(0, 0)), "persist enabled=%s: edited region evicted" % enabled)
		var saved: Terrain3DRegion = ResourceLoader.load(_file(d_plain, Vector2i(0, 0)), "Terrain3DRegion", ResourceLoader.CACHE_MODE_IGNORE)
		ok(saved != null and absf(saved.get_height_map().get_pixel(10, 10).r - h) < 0.01, "persist enabled=%s: height edit saved" % enabled)
		ok(saved != null and _same(saved.get_color_map().get_pixel(10, 10), _sig(0, 0)), "persist enabled=%s: color kept in the saved file" % enabled)

	# Compressed color modes while streaming, with and without the uncompressed copy
	for keep in [true, false]:
		var d := _base + "/comp_%s" % keep
		await _author(d, Terrain3D.COMPRESS_S3TC, keep)
		for enabled in [true, false]:
			var tag := "s3tc keep=%s enabled=%s" % [keep, enabled]
			await _stream(d, enabled, Terrain3D.COMPRESS_S3TC, keep)
			ok(_t.data.get_region_count() == 9, "%s: ring loaded" % tag)
			ok((_t.data.get_color_maps_rid() != RID()) == enabled, "%s: color array presence" % tag)
			if enabled and not keep:
				# A compressed streaming pool takes the compressed map as it is and frees the uncompressed copy
				# (keep_uncompressed_color false), so per pixel reads give NaN: read the compressed map instead
				var rc: Terrain3DRegion = _t.data.get_region(Vector2i(0, 0))
				var cm: Image = rc.get_compressed_color_map().duplicate() if rc != null and rc.is_color_compressed() else null
				if cm != null:
					cm.decompress()
				var cpx: Color = cm.get_pixel(10, 10) if cm != null else Color(NAN, NAN, NAN, NAN)
				ok(rc != null and rc.get_color_map() == null and absf(cpx.r - _sig(0, 0).r) < 0.08 and absf(cpx.g - _sig(0, 0).g) < 0.08,
						"%s: streamed color correct in the compressed map, uncompressed freed (%s)" % [tag, cpx])
			elif enabled:
				var px: Color = _t.data.get_pixel(Terrain3DRegion.TYPE_COLOR, centre)
				ok(absf(px.r - _sig(0, 0).r) < 0.08 and absf(px.g - _sig(0, 0).g) < 0.08, "%s: streamed color correct (%s)" % [tag, px])
			ok(_t.data.get_free_slot_count() + _t.data.get_region_count() == 25, "%s: no slot leaked" % tag)

	_cleanup()
	print("Failed checks: ", _fail)
	quit(_fail)


func _cleanup() -> void:
	for sub in DirAccess.get_directories_at(_base):
		for f in DirAccess.get_files_at(_base + "/" + sub):
			DirAccess.remove_absolute(_base + "/" + sub + "/" + f)
		DirAccess.remove_absolute(_base + "/" + sub)
	DirAccess.remove_absolute(_base)
