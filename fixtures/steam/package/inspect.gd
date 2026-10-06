extends SceneTree
var paths: Array = []
func walk(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null: return
	directory.include_hidden = true
	for file in directory.get_files(): paths.append(path.path_join(file))
	for folder in directory.get_directories(): walk(path.path_join(folder))
func _initialize() -> void:
	var pack := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--pack="): pack = arg.trim_prefix("--pack=")
	walk("res://")
	var fixture_paths := paths.duplicate()
	paths.clear()
	if not ProjectSettings.load_resource_pack(pack, false):
		printerr("FAIL: cannot mount exported pack")
		quit(1)
		return
	walk("res://")
	# Exclude inspector-project files from the mounted resource inventory.
	paths = paths.filter(func(path): return not fixture_paths.has(path))
	paths.sort()
	print("PACK_PATHS:" + JSON.stringify(paths))
	quit()
