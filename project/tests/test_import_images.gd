extends SceneTree
## Headless test for Terrain3DData.import_images:
##   godot --headless --path project --script res://tests/test_import_images.gd
## Covers full-region sources (duplicate and blit skipped), partial overlaps that must
## still preserve existing data, source images not being aliased, and update=false
## followed by one update_maps().
var _fail := 0
var _done := false
var _t: Terrain3D
const RS := 256


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	_t = Terrain3D.new()
	root.add_child(_t)
	process_frame.connect(_run)


func _img(h: float, size := RS) -> Image:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RF)
	img.fill(Color(h, 0, 0))
	return img


func _run() -> void:
	if _done:
		return
	_done = true
	_t.change_region_size(RS)
	var data: Terrain3DData = _t.data
	var col := Image.create_empty(RS, RS, false, Image.FORMAT_RGBA8)
	col.fill(Color(0.2, 0.4, 0.6))

	# Full region sources, default update
	var src := _img(10.0)
	data.import_images([src, null, col], Vector3(0, 0, 0))
	ok(data.get_region_count() == 1, "full region import adds one region")
	ok(is_equal_approx(data.get_height(Vector3(5, 0, 5)), 10.0), "full region heights imported (%.2f)" % data.get_height(Vector3(5, 0, 5)))
	var c := data.get_color(Vector3(5, 0, 5))
	ok(is_equal_approx(c.r, 0.2) and is_equal_approx(c.b, 0.6), "full region color imported")
	src.fill(Color(99.0, 0, 0))
	ok(is_equal_approx(data.get_height(Vector3(5, 0, 5)), 10.0), "region does not alias the source image")
	ok(data.get_region(Vector2i(0, 0)).get_color_map().has_mipmaps(), "color map has mipmaps")

	# Re-import over an existing region replaces it
	data.import_images([_img(20.0), null, null], Vector3(0, 0, 0))
	ok(is_equal_approx(data.get_height(Vector3(5, 0, 5)), 20.0), "re-import replaces existing region")

	# Partial overlap keeps what is outside the imported rectangle
	data.import_images([_img(30.0, 64), null, null], Vector3(32, 0, 32))
	ok(is_equal_approx(data.get_height(Vector3(40, 0, 40)), 30.0), "partial import writes the rectangle")
	ok(is_equal_approx(data.get_height(Vector3(5, 0, 5)), 20.0), "partial import keeps existing data outside it")

	# Image spanning four regions
	data.import_images([_img(7.0, RS * 2), null, null], Vector3(RS, 0, RS))
	ok(data.get_region_count() == 5, "2x2 region import adds four regions (%d)" % data.get_region_count())
	ok(is_equal_approx(data.get_height(Vector3(RS * 1.5, 0, RS * 1.5)), 7.0), "2x2 import heights")
	ok(is_equal_approx(data.get_height(Vector3(RS * 2.5, 0, RS * 2.5)), 7.0), "2x2 import far corner")

	# update=false defers the rebuild until update_maps()
	data.import_images([_img(50.0), null, null], Vector3(-RS, 0, 0), 0.0, 1.0, false)
	data.import_images([_img(60.0), null, null], Vector3(-RS * 2, 0, 0), 0.0, 1.0, false)
	data.update_maps()
	ok(data.get_region_count() == 7, "two deferred imports add two regions")
	ok(is_equal_approx(data.get_height(Vector3(-RS + 5, 0, 5)), 50.0), "deferred import 1 heights after update_maps")
	ok(is_equal_approx(data.get_height(Vector3(-RS * 2 + 5, 0, 5)), 60.0), "deferred import 2 heights after update_maps")
	ok(data.get_height_maps().size() == 7, "height texture array has every region")

	# Scale and offset still apply to full region sources
	data.import_images([_img(2.0), null, null], Vector3(0, 0, -RS), 1.0, 3.0)
	ok(is_equal_approx(data.get_height(Vector3(5, 0, -RS + 5)), 7.0), "scale and offset applied (%.2f)" % data.get_height(Vector3(5, 0, -RS + 5)))

	var big := _img(1.0, 1024)
	_t.change_region_size(1024)
	var t0 := Time.get_ticks_usec()
	for i in 8:
		data.import_images([big, null, null], Vector3(i * 1024, 0, 4096))
	print("8 x 1024 region imports (update=true): %.1f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	t0 = Time.get_ticks_usec()
	for i in 8:
		data.import_images([big, null, null], Vector3(i * 1024, 0, 8192), 0.0, 1.0, false)
	data.update_maps()
	print("8 x 1024 region imports (update=false + one update_maps): %.1f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	print("SUITE GREEN" if _fail == 0 else "SUITE RED (%d)" % _fail)
	quit(_fail)
