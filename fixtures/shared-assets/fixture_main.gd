extends Node

## The exported fixture is deliberately tiny.  The local integration host gives
## it a real parent runtime/root and a logical path through command-line args;
## this script proves the exported addon consumes that runtime contract instead
## of reconstructing a sibling URL from its build location.
func _ready() -> void:
	await CouchGames.init()
	var logical_path := "nested/binary.bin"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shared-fixture-path="):
			logical_path = arg.get_slice("=", 1)
	var root := CouchGames.game.shared_root()
	if root.is_empty():
		print("SHARED_FIXTURE_UNAVAILABLE")
		return
	var url := await CouchGames.game.get_shared_file_url(logical_path)
	var bytes := await CouchGames.game.get_shared_file(logical_path)
	var empty := await CouchGames.game.get_shared_file("nested/empty.bin")
	var pack_loaded := await CouchGames.game.load_shared_pack("packs/common.pck")
	print("SHARED_FIXTURE_RESULT root=%s url=%s bytes=%d empty=%d pack=%s hex=%s mock=%s" % [
		root, url, bytes.size(), empty.size(), pack_loaded, bytes.hex_encode(), CouchGames.is_mock])
