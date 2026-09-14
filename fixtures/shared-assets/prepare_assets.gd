extends SceneTree

## Produces deterministic bytes that the actual local workerd/R2 fixture can
## publish through the shared-files API.  The source file used to make the PCK
## lives in the disposable project; only the requested output directory remains.
func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var output_dir := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			output_dir = arg.get_slice("=", 1)
	if output_dir.is_empty():
		push_error("Pass --output=/absolute/directory")
		quit(2)
		return
	if not output_dir.is_absolute_path():
		push_error("Shared fixture output must be an absolute directory")
		quit(2)
		return
	var directory_error := DirAccess.make_dir_recursive_absolute(output_dir.path_join("nested"))
	if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
		push_error("Cannot create fixture output: " + error_string(directory_error))
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output_dir.path_join("packs"))
	if not _write(output_dir.path_join("nested/binary.bin"), PackedByteArray([0, 1, 2, 255, 0, 128, 64])) \
			or not _write(output_dir.path_join("nested/empty.bin"), PackedByteArray()) \
			or not _write("res://fixture_pack_payload.txt", "shared fixture pack".to_utf8_buffer()):
		quit(1)
		return
	var packer := PCKPacker.new()
	var pack_path := output_dir.path_join("packs/common.pck")
	if packer.pck_start(pack_path) != OK \
			or packer.add_file("res://shared_fixture/common.txt", "res://fixture_pack_payload.txt") != OK \
			or packer.flush() != OK:
		push_error("Cannot create fixture pack")
		quit(1)
		return
	print("SHARED_FIXTURE_ASSETS_READY " + output_dir)
	quit(0)


func _write(path: String, bytes: PackedByteArray) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write " + path)
		return false
	file.store_buffer(bytes)
	file.close()
	return true
