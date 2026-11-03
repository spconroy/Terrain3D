extends SceneTree
## Headless test for loading a data_directory that already holds region files when
## Terrain3D enters the tree:
##   godot --headless --path project --script res://tests/test_data_directory_load.gd
## Loading regions updates the maps and signals the collision, which divides by the region
## size, so Terrain3DData::initialize() must set it before loading. Setting data_directory on a
## terrain that is already in the tree rebuilds the data object and crashed without that.
var _fail := 0
var _t: Terrain3D


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var dir := OS.get_user_data_dir().path_join("t3d_data_directory_load")
	DirAccess.make_dir_recursive_absolute(dir)

	# Make a data_directory with two region files at the default region size
	var src := Terrain3D.new()
	root.add_child(src)
	await process_frame
	var img := Image.create_empty(src.get_region_size(), src.get_region_size(), false, Image.FORMAT_RF)
	img.fill(Color(7.0, 0, 0))
	src.data.import_images([img, null, null], Vector3(0, 0, 0))
	src.data.import_images([img, null, null], Vector3(src.get_region_size(), 0, 0))
	src.data.save_directory(dir)
	root.remove_child(src)
	src.free()

	# Set the directory before entering the tree, as a saved scene does
	var early := Terrain3D.new()
	early.data_directory = dir
	root.add_child(early)
	await process_frame
	ok(early.data.get_region_count() == 2, "directory set before entering the tree loads (%d)" % early.data.get_region_count())
	root.remove_child(early)
	early.free()

	# Set the directory on a terrain already in the tree. This rebuilds the data object and
	# crashed in Terrain3DCollision before the fix.
	_t = Terrain3D.new()
	root.add_child(_t)
	await process_frame
	_t.data_directory = dir
	await process_frame
	var data: Terrain3DData = _t.data
	ok(data.get_region_count() == 2, "both regions loaded from data_directory (%d)" % data.get_region_count())
	ok(is_equal_approx(data.get_height(Vector3(5, 0, 5)), 7.0), "loaded height is correct")
	ok(_t.get_collision() != null, "collision exists")
	print("DONE: %d failures" % _fail)
	quit(1 if _fail > 0 else 0)
