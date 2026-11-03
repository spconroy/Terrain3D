# Tests for Terrain3D.color_map_enabled.
# Run from the repo root with a Godot 4.6+ binary:
#   godot --headless --path project --script res://tests/test_color_map_enabled.gd
# Run it without --headless on a real renderer to also check the VRAM and shader results.
# Exits with the number of failed checks.
extends SceneTree

const PAINT := Color(1, 0, 0, 0.5)

var _fails: int = 0
var _dir: String = ProjectSettings.globalize_path("user://t3d_color_map_test")


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(_dir)
	await _test_data()
	if DisplayServer.get_name() != "headless":
		await _test_vram_and_shader()
	_cleanup()
	print("Failed checks: ", _fails)
	quit(_fails)


func _check(p_ok: bool, p_msg: String) -> void:
	print(("PASS  " if p_ok else "FAIL  ") + p_msg)
	if not p_ok:
		_fails += 1


# The color map is 8-bit per channel, so allow one step of rounding
func _same(p_a: Color, p_b: Color) -> bool:
	return absf(p_a.r - p_b.r) < 0.01 and absf(p_a.g - p_b.g) < 0.01 and absf(p_a.b - p_b.b) < 0.01 and absf(p_a.a - p_b.a) < 0.01


func _new_terrain() -> Terrain3D:
	var t := Terrain3D.new()
	root.add_child(t)
	t.assets = Terrain3DAssets.new()
	t.collision_mode = Terrain3DCollision.DISABLED
	await process_frame
	return t


func _paint(p_data: Terrain3DData) -> void:
	for x in 256:
		for z in 256:
			p_data.set_pixel(Terrain3DRegion.TYPE_COLOR, Vector3(x, 0, z), PAINT)
	p_data.update_maps(Terrain3DRegion.TYPE_COLOR, true, true)


# Data behaviour: default, pre-init set, array lifetime, colour is never lost
func _test_data() -> void:
	# The property can be set before the node enters the tree (as a saved scene does)
	var early := Terrain3D.new()
	early.assets = Terrain3DAssets.new()
	early.material = Terrain3DMaterial.new()
	early.collision_mode = Terrain3DCollision.DISABLED
	early.color_map_enabled = false
	root.add_child(early)
	await process_frame
	_check(not early.color_map_enabled, "can be set before entering the tree")
	early.data.add_region_blankp(Vector3.ZERO, false)
	_check(early.data.get_color_maps_rid() == RID(), "no color array is built while disabled")
	early.color_map_enabled = true
	_check(early.data.get_color_maps_rid() != RID(), "enabling builds the color array")
	early.queue_free()
	await process_frame

	var t: Terrain3D = await _new_terrain()
	_check(t.color_map_enabled, "defaults to enabled")
	t.data.add_region_blankp(Vector3.ZERO, false)
	_paint(t.data)
	_check(t.data.get_color_maps_rid() != RID(), "color array exists while enabled")
	t.color_map_enabled = false
	_check(t.data.get_color_maps_rid() == RID(), "disabling frees the color array")
	_check(_same(t.data.get_pixel(Terrain3DRegion.TYPE_COLOR, Vector3(10, 0, 10)), PAINT), "region keeps its color data")

	# Re-adding the region and saving to another directory must not lose the color
	var region: Terrain3DRegion = t.data.get_regionp(Vector3.ZERO)
	t.data.remove_region(region, false)
	t.data.add_region(region, false)
	t.data.save_directory(_dir)
	var on_disk: Terrain3DRegion = ResourceLoader.load(region.resource_path, "Terrain3DRegion", ResourceLoader.CACHE_MODE_IGNORE)
	_check(_same(on_disk.get_color_map().get_pixel(10, 10), PAINT), "saved file keeps the color")
	t.color_map_enabled = true
	_check(t.data.get_color_maps_rid() != RID(), "re-enabling rebuilds the color array")
	_check(_same(t.data.get_pixel(Terrain3DRegion.TYPE_COLOR, Vector3(10, 0, 10)), PAINT), "color is intact after a disable and enable")
	t.queue_free()
	await process_frame


# Needs a real renderer: texture memory drops and the shader skips the lookups
func _test_vram_and_shader() -> void:
	var t: Terrain3D = await _new_terrain()
	t.data.add_region_blankp(Vector3.ZERO, false)
	_paint(t.data)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.position = Vector3(128, 120, 128)
	cam.rotation_degrees = Vector3(-90, 0, 0)
	t.set_camera(cam)
	t.material.show_colormap = true
	await _frames(5)
	var mem_on: float = _texture_mem()
	var red_on: Color = await _center_color()
	t.color_map_enabled = false
	await _frames(3)
	var mem_off: float = _texture_mem()
	var red_off: Color = await _center_color()
	_check(mem_off < mem_on, "disabling lowers texture memory (%.2f -> %.2f MB)" % [mem_on, mem_off])
	_check(red_on.r - red_on.g > 0.1, "enabled renders the painted color")
	_check(red_off.is_equal_approx(Color(red_off.r, red_off.r, red_off.r)), "disabled renders the neutral default")
	t.color_map_enabled = true
	await _frames(3)
	var red_back: Color = await _center_color()
	_check(red_back.r - red_back.g > 0.1, "re-enabling renders the painted color again")
	t.queue_free()
	cam.queue_free()
	await process_frame


func _frames(p_count: int) -> void:
	for i in p_count:
		await process_frame


func _texture_mem() -> float:
	return RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED) / 1048576.0


func _center_color() -> Color:
	await _frames(2)
	var img: Image = root.get_texture().get_image()
	return img.get_pixel(img.get_width() / 2, img.get_height() / 2)


func _cleanup() -> void:
	for f in DirAccess.get_files_at(_dir):
		DirAccess.remove_absolute(_dir + "/" + f)
	DirAccess.remove_absolute(_dir)
