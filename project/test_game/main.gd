extends Node3D
## Region add/remove cost and streaming measurements for a Terrain3D fork.
## Run: godot --path project --gpu-index 1 --resolution 1280x720 -- mode=<cost|move|stream|twonodes> [spread=1]

const RS := 1024
const HEIGHT_SCALE := 120.0 # baked into the source images so import_images runs with scale 1.0 (no per-pixel pass)
const OUT := "D:/Captures/panzerstrike/scratch/terrain3d_fork_test/"

var mode := "cost"
var terrain: Terrain3D
var cam: Camera3D
var base_h: Array[Image] = []
var base_c: Image
var base_col: Image
var log_lines: PackedStringArray = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("mode="):
			mode = a.substr(5)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	DirAccess.make_dir_recursive_absolute(OUT)
	_make_base()
	cam = Camera3D.new()
	cam.far = 8000.0
	add_child(cam)
	cam.make_current()
	cam.position = Vector3(512, 300, 512)
	cam.rotation_degrees = Vector3(-30, 0, 0)
	add_child(DirectionalLight3D.new())
	if mode != "twonodes":
		terrain = _make_terrain(1.0)
	await get_tree().process_frame
	await get_tree().process_frame
	call("run_" + mode)


func p(s: String) -> void:
	print("[T3D] ", s)
	log_lines.append(s)


func _make_base() -> void:
	for i in 4:
		var n := FastNoiseLite.new()
		n.seed = 100 + i
		n.frequency = 0.0015
		n.fractal_octaves = 5
		var im := n.get_image(RS, RS, false, false, false)
		im.convert(Image.FORMAT_RF)
		for y in RS:
			for x in RS:
				im.set_pixel(x, y, Color(im.get_pixel(x, y).r * HEIGHT_SCALE, 0, 0))
		base_h.append(im)
	base_c = Image.create_empty(RS, RS, false, Image.FORMAT_RF)
	base_col = Image.create_empty(RS, RS, false, Image.FORMAT_RGBA8)
	base_col.fill(Color(0.4, 0.5, 0.3))


func _make_terrain(spacing: float, data_dir := "") -> Terrain3D:
	var t := Terrain3D.new()
	t.name = "Terrain3D_%s" % spacing
	if data_dir != "":
		t.data_directory = data_dir # before add_child: setting it on a live node crashes (see RESULTS.md)
	add_child(t)
	t.change_region_size(RS)
	t.vertex_spacing = spacing
	t.set_camera(cam)
	t.assets = Terrain3DAssets.new()
	return t


func imgs(i: int) -> Array[Image]:
	var a: Array[Image] = [base_h[i % 4].duplicate(), base_c.duplicate(), base_col.duplicate()]
	return a


func add_region(t: Terrain3D, rx: int, rz: int, i: int, spacing := 1.0) -> int:
	var im := imgs(i)
	var t0 := Time.get_ticks_usec()
	t.data.import_images(im, Vector3(rx * RS * spacing, 0, rz * RS * spacing), 0.0, 1.0)
	return Time.get_ticks_usec() - t0


func vram_mb() -> float:
	return RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0


func next_frame_ms() -> float:
	var t0 := Time.get_ticks_usec()
	await get_tree().process_frame
	return (Time.get_ticks_usec() - t0) / 1000.0


static func med(a: Array) -> float:
	var s := a.duplicate()
	s.sort()
	return s[s.size() / 2] if s.size() else 0.0


static func pct(a: Array, q: float) -> float:
	var s := a.duplicate()
	s.sort()
	return s[min(s.size() - 1, int(s.size() * q))] if s.size() else 0.0


static func mx(a: Array) -> float:
	return a.max() if a.size() else 0.0


func finish() -> void:
	var f := FileAccess.open(OUT + "log_%s.txt" % mode, FileAccess.WRITE)
	f.store_string("\n".join(log_lines))
	f.close()
	get_tree().quit()


func xlocs() -> Array:
	var r := []
	for l in terrain.data.get_region_locations():
		r.append((l as Vector2i).x)
	r.sort()
	return r


func run_cost() -> void:
	p("godot %s, adapter %s" % [Engine.get_version_info().string, RenderingServer.get_video_adapter_name()])
	var v0 := vram_mb()
	p("vram baseline MB %.1f, regions %d" % [v0, terrain.data.get_region_count()])
	var locs: Array[Vector2i] = []
	for z in 4:
		for x in 6:
			locs.append(Vector2i(x - 3, z - 2))
	var add_us: Array = []
	var nf1: Array = []
	var nf2: Array = []
	var vr: Array = []
	for i in locs.size():
		var us := add_region(terrain, locs[i].x, locs[i].y, i)
		var d1 := await next_frame_ms()
		var d2 := await next_frame_ms()
		add_us.append(us / 1000.0)
		nf1.append(d1)
		nf2.append(d2)
		vr.append(vram_mb())
		p("add N=%d  import_ms=%.2f  nextframe_ms=%.2f  frame2_ms=%.2f  vram_MB=%.1f" % [i + 1, us / 1000.0, d1, d2, vr[-1]])
	p("(a) first add ms %.2f ; N=2..24 median %.2f worst %.2f ; N=2..6 med %.2f ; N=19..24 med %.2f" % [add_us[0], med(add_us.slice(1)), mx(add_us.slice(1)), med(add_us.slice(1, 6)), med(add_us.slice(18))])
	p("nextframe ms: median %.2f worst %.2f" % [med(nf1), mx(nf1)])
	p("(e) vram MB before %.1f after24 %.1f delta %.1f => %.2f MB/region" % [v0, vr[-1], vr[-1] - v0, (vr[-1] - v0) / 24.0])
	var rm_unload: Array = []
	var rm_next: Array = []
	for i in range(12):
		var t0 := Time.get_ticks_usec()
		terrain.data.unload_region(locs[i])
		rm_unload.append((Time.get_ticks_usec() - t0) / 1000.0)
		rm_next.append(await next_frame_ms())
	p("(d) unload_region (update=true) x12 from N=24: median %.2f worst %.2f ms ; nextframe med %.2f worst %.2f ; first %.2f last %.2f" % [med(rm_unload), mx(rm_unload), med(rm_next), mx(rm_next), rm_unload[0], rm_unload[-1]])
	var rm2: Array = []
	for i in range(12, 24):
		var t0 := Time.get_ticks_usec()
		terrain.data.remove_regionl(locs[i])
		rm2.append((Time.get_ticks_usec() - t0) / 1000.0)
		await next_frame_ms()
	p("(d) remove_regionl x12 from N=12: median %.2f worst %.2f ms ; count after %d (soft delete)" % [med(rm2), mx(rm2), terrain.data.get_region_count()])
	p("vram after removals MB %.1f" % vram_mb())
	terrain.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	terrain = _make_terrain(1.0)
	await get_tree().process_frame
	await get_tree().process_frame
	p("vram fresh terrain MB %.1f" % vram_mb())
	var t0 := Time.get_ticks_usec()
	for i in 4:
		add_region(terrain, i, 0, i)
	var batch_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var bn := await next_frame_ms()
	p("(c) 4 regions one frame: total import %.2f ms, nextframe %.2f ms" % [batch_ms, bn])
	for i in 4:
		terrain.data.unload_region(Vector2i(i, 0), false)
	var tb := Time.get_ticks_usec()
	terrain.data.update_maps(Terrain3DRegion.TYPE_MAX, true, false)
	p("batch unload 4 (update=false) then 1 update_maps: %.2f ms" % ((Time.get_ticks_usec() - tb) / 1000.0))
	await get_tree().process_frame
	await get_tree().process_frame
	var sep: Array = []
	var sepn: Array = []
	for i in 4:
		sep.append(add_region(terrain, i, 0, i) / 1000.0)
		sepn.append(await next_frame_ms())
	var s := 0.0
	for x in sep:
		s += x
	p("(c) 4 regions separate frames: import ms %s total %.2f, nextframes %s" % [str(sep), s, str(sepn)])
	var t1 := Time.get_ticks_usec()
	for i in 4:
		add_region(terrain, i, 1, i)
	p("(c) +4 more in one frame (4 resident before): %.2f ms" % ((Time.get_ticks_usec() - t1) / 1000.0))
	await next_frame_ms()
	finish()


func run_move() -> void:
	var spread := false
	for a in OS.get_cmdline_user_args():
		if a == "spread=1":
			spread = true
	var speed := 500.0
	var base_col_i := -14
	var n := 0
	for c in range(base_col_i - 2, base_col_i + 5):
		for z in range(-1, 2):
			add_region(terrain, c, z, n)
			n += 1
	await get_tree().process_frame
	await get_tree().process_frame
	cam.position = Vector3(base_col_i * RS + 512, 300, 512)
	cam.look_at(cam.position + Vector3(1000, -250, 0))
	var op_frames: Array = []
	var quiet: Array = []
	var cur := base_col_i
	var pending: Array = []
	var op_cost: Array = []
	var end_col := base_col_i + 14
	var last := Time.get_ticks_usec()
	var vr0 := vram_mb()
	while cur < end_col:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var dt := (now - last) / 1e6
		last = now
		var ops := false
		cam.position.x += speed * dt
		var c := int(floor(cam.position.x / RS))
		if c > cur:
			cur = c
			for z in range(-1, 2):
				pending.append(["add", cur + 4, z])
				pending.append(["rm", cur - 3, z])
		var budget := 1 if spread else 99
		var t0 := Time.get_ticks_usec()
		while pending.size() and budget > 0:
			var op = pending.pop_front()
			if op[0] == "add":
				add_region(terrain, op[1], op[2], n)
				n += 1
			else:
				terrain.data.unload_region(Vector2i(op[1], op[2]))
			ops = true
			budget -= 1
		if ops:
			op_cost.append((Time.get_ticks_usec() - t0) / 1000.0)
			op_frames.append(dt * 1000.0)
		else:
			quiet.append(dt * 1000.0)
	for i in 90:
		await get_tree().process_frame
	p("vram after 90 settle frames: %.1f MB" % vram_mb())
	p("move mode=%s speed=%.0f m/s columns crossed=%d regions resident=%d vram %.1f -> %.1f MB" % ["spread" if spread else "burst", speed, cur - base_col_i, terrain.data.get_region_count(), vr0, vram_mb()])
	p("quiet frames: n=%d median %.2f p99 %.2f max %.2f ms" % [quiet.size(), med(quiet), pct(quiet, 0.99), mx(quiet)])
	p("frames after op frames (dt of the frame following ops): n=%d median %.2f max %.2f ms ; op cost in-frame (sum per frame) median %.2f max %.2f ms" % [op_frames.size(), med(op_frames), mx(op_frames), med(op_cost), mx(op_cost)])
	finish()


func run_stream() -> void:
	var dir := "D:/Captures/panzerstrike/scratch/terrain3d_fork_test/streamdata"
	DirAccess.make_dir_recursive_absolute(dir)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + f)
	for i in 10:
		add_region(terrain, i, 0, i)
	terrain.data.save_directory(dir)
	p("saved files: %s" % str(DirAccess.get_files_at(dir)))
	terrain.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	terrain = _make_terrain(1.0, dir)
	await get_tree().process_frame
	p("data_directory=%s regions resident right after setting it (eager load): %d" % [terrain.data_directory, terrain.data.get_region_count()])
	for step in range(0, 10):
		var pos := Vector3(step * RS + 512, 0, 512)
		var t0 := Time.get_ticks_usec()
		terrain.data.update_streaming(PackedVector3Array([pos]), 1500.0)
		var us := Time.get_ticks_usec() - t0
		var nf := await next_frame_ms()
		p("explicit target x=%.0f -> resident x-locs %s (%.2f ms, nextframe %.2f)" % [pos.x, str(xlocs()), us / 1000.0, nf])
	terrain.region_streaming_radius = 1500.0
	cam.position = Vector3(512, 300, 512)
	for step in [0, 4, 9, 0]:
		cam.position = Vector3(step * RS + 512, 300, 512)
		await get_tree().create_timer(1.5).timeout
		p("auto (camera+property) cam x=%.0f after 1.5 s -> resident x-locs %s" % [cam.position.x, str(xlocs())])
	var n3 := Node3D.new()
	add_child(n3)
	n3.position = Vector3(8 * RS + 512, 0, 512)
	terrain.add_streaming_target(n3)
	cam.position = Vector3(512, 300, 512)
	await get_tree().create_timer(1.5).timeout
	p("camera x=512 + extra target x=8704 -> resident %s" % str(xlocs()))
	terrain.remove_streaming_target(n3)
	await get_tree().create_timer(1.5).timeout
	p("after remove_streaming_target -> resident %s" % str(xlocs()))
	# run-time generated regions
	var dir2 := "D:/Captures/panzerstrike/scratch/terrain3d_fork_test/streamdata_rt"
	DirAccess.make_dir_recursive_absolute(dir2)
	for f in DirAccess.get_files_at(dir2):
		DirAccess.remove_absolute(dir2 + "/" + f)
	terrain.region_streaming_radius = 0.0
	terrain.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	terrain = _make_terrain(1.0)
	await get_tree().process_frame
	for i in 6:
		add_region(terrain, i, 0, i)
	terrain.data.update_streaming(PackedVector3Array([Vector3(512, 0, 512)]), 1500.0)
	p("RT, no data_directory: resident after update_streaming = %d (6 generated; no-op expected)" % terrain.data.get_region_count())
	terrain.data_directory = dir2 # dir2 is empty and data not empty: retains data (no re-init) per set_data_directory
	terrain.data.update_streaming(PackedVector3Array([Vector3(512, 0, 512)]), 1500.0)
	p("RT, data_directory set, target x=512: resident %s ; files on disk %s" % [str(xlocs()), str(DirAccess.get_files_at(dir2))])
	terrain.data.update_streaming(PackedVector3Array([Vector3(5 * RS + 512, 0, 512)]), 1500.0)
	p("RT, target moved to x=5632: resident %s" % str(xlocs()))
	terrain.data.update_streaming(PackedVector3Array([Vector3(512, 0, 512)]), 1500.0)
	p("RT, target back to x=512: resident %s" % str(xlocs()))
	finish()


func run_twonodes() -> void:
	var t1 := _make_terrain(1.0)
	var t10 := _make_terrain(10.0)
	t10.name = "T10"
	var green := base_col.duplicate()
	green.fill(Color(0.1, 0.8, 0.1))
	var orange := base_col.duplicate()
	orange.fill(Color(0.9, 0.4, 0.05))
	var fine_h := base_h[0].duplicate() as Image
	var a: Array[Image] = [fine_h, base_c.duplicate(), green]
	t1.data.import_images(a, Vector3(0, 0, 0), 0.0, 1.0)
	for dx in range(-60, 61):
		for dz in range(-60, 61):
			t1.data.set_control_hole(Vector3(512 + dx, 0, 512 + dz), true)
	t1.data.update_maps(Terrain3DRegion.TYPE_CONTROL, true, false)
	var b: Array[Image] = [base_h[1].duplicate(), base_c.duplicate(), orange]
	t10.data.import_images(b, Vector3(0, 0, 0), -150.0, 1.0)
	t10.data.import_images(b, Vector3(10240, 0, 0), -150.0, 1.0)
	cam.far = 30000.0
	cam.position = Vector3(512, 250, 900)
	cam.look_at(Vector3(512, 40, 512))
	for i in 10:
		await get_tree().process_frame
	_shot("twonodes_a_low")
	cam.position = Vector3(5000, 3000, 9000)
	cam.look_at(Vector3(2000, 0, 1000))
	for i in 10:
		await get_tree().process_frame
	_shot("twonodes_b_high")
	cam.position = Vector3(300, 60, 700)
	cam.look_at(Vector3(512, 20, 512))
	for i in 10:
		await get_tree().process_frame
	_shot("twonodes_c_hole")
	t1.visible = false
	cam.position = Vector3(512, 250, 900)
	cam.look_at(Vector3(512, 40, 512))
	for i in 10:
		await get_tree().process_frame
	_shot("twonodes_d_coarse_only")
	t1.visible = true
	t10.visible = false
	for i in 10:
		await get_tree().process_frame
	_shot("twonodes_e_fine_only")
	t10.visible = true
	finish()


func _shot(shot_name: String) -> void:
	var im := get_viewport().get_texture().get_image()
	im.save_png(OUT + shot_name + ".png")
	p("saved " + shot_name)


func run_decomp() -> void:
	var one: Array = []
	for n in [1, 4, 8, 16, 24]:
		while terrain.data.get_region_count() < n:
			var i := terrain.data.get_region_count()
			add_region(terrain, i % 6 - 3, i / 6 - 2, i)
		await get_tree().process_frame
		await get_tree().process_frame
		var d := terrain.data
		var r := {}
		for k in ["all_nomip", "all_mip", "height", "control", "color_nomip"]:
			var t0 := Time.get_ticks_usec()
			match k:
				"all_nomip": d.update_maps(Terrain3DRegion.TYPE_MAX, true, false)
				"all_mip": d.update_maps(Terrain3DRegion.TYPE_MAX, true, true)
				"height": d.update_maps(Terrain3DRegion.TYPE_HEIGHT, true, false)
				"control": d.update_maps(Terrain3DRegion.TYPE_CONTROL, true, false)
				"color_nomip": d.update_maps(Terrain3DRegion.TYPE_COLOR, true, false)
			r[k] = (Time.get_ticks_usec() - t0) / 1000.0
		p("decomp N=%d update_maps ms: %s" % [n, str(r)])
		# a full add at this N (new location far away)
		var us := add_region(terrain, 10 + n, 5, n)
		p("decomp N=%d next add import_images ms: %.2f" % [n, us / 1000.0])
		terrain.data.unload_region(Vector2i(10 + n, 5), true)
	# scale != 1 pass cost
	var im := imgs(0)
	var t0 := Time.get_ticks_usec()
	terrain.data.import_images(im, Vector3(-9 * RS, 0, 5 * RS), 0.0, 1.5)
	p("import_images with scale 1.5 (per-pixel pass) at N=24: %.2f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	finish()
