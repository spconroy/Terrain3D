extends SceneTree
## Headless test for Terrain3DUtil.get_min_max:
##   godot --headless --path project --script res://tests/test_get_min_max.gd
## Checks the FORMAT_RF fast path against a get_pixel() reference, a non-RF format,
## and the error cases. Also prints the time for a 1024x1024 image.
var _fail := 0


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _reference(img: Image) -> Vector2:
	var r := Vector2(INF, -INF)
	for y in img.get_height():
		for x in img.get_width():
			var v := img.get_pixel(x, y).r
			r.x = minf(r.x, v)
			r.y = maxf(r.y, v)
	return r


func _initialize() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var rf := Image.create_empty(256, 128, false, Image.FORMAT_RF)
	for y in rf.get_height():
		for x in rf.get_width():
			rf.set_pixel(x, y, Color(rng.randf_range(-50.0, 300.0), 0, 0))
	rf.set_pixel(7, 3, Color(-123.5, 0, 0))
	rf.set_pixel(250, 120, Color(987.25, 0, 0))
	var got := Terrain3DUtil.get_min_max(rf)
	ok(got == _reference(rf), "RF matches get_pixel reference (%s)" % got)
	ok(got == Vector2(-123.5, 987.25), "RF finds planted min and max")

	var flat := Image.create_empty(64, 64, false, Image.FORMAT_RF)
	flat.fill(Color(4.0, 0, 0))
	ok(Terrain3DUtil.get_min_max(flat) == Vector2(4.0, 4.0), "constant RF image")

	var rgba := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	rgba.fill(Color(0.5, 0.2, 0.1))
	rgba.set_pixel(1, 1, Color(1.0, 0, 0))
	ok(Terrain3DUtil.get_min_max(rgba) == _reference(rgba), "RGBA8 image still uses the generic path")

	var big := Image.create_empty(1024, 1024, false, Image.FORMAT_RF)
	big.fill(Color(1.0, 0, 0))
	var t0 := Time.get_ticks_usec()
	var bm := Terrain3DUtil.get_min_max(big)
	print("1024x1024 RF get_min_max: %.2f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	ok(bm == Vector2(1.0, 1.0), "1024 image result")

	ok(is_inf(Terrain3DUtil.get_min_max(null).x), "null image returns INF")
	ok(is_inf(Terrain3DUtil.get_min_max(Image.new()).x), "empty image returns INF")
	print("SUITE GREEN" if _fail == 0 else "SUITE RED (%d)" % _fail)
	quit(_fail)
