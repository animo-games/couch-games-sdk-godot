extends "res://addons/couch-games-sdk/backends/backend.gd"

static var shared_bytes := PackedByteArray([9, 8, 7, 6, 5, 4])
static var retry_bytes := PackedByteArray([4, 5, 6])

var _root := ""


func _init(root_url: String) -> void:
	_root = root_url


func shared_root() -> String:
	return _root


func resolve_shared_file(relative_path: String) -> Dictionary:
	var endpoint := "/shared.bin" if relative_path == "remote/shared.bin" else "/retry.bin"
	var bytes := shared_bytes if endpoint == "/shared.bin" else retry_bytes
	var sha := _sha256_hex(bytes)
	return {
		"success": true,
		"error": "",
		"root_identity": _sha256_hex(_root.to_utf8_buffer()),
		"file_identity": "%s\n%s" % [relative_path, sha],
		"url": _root + endpoint,
		"sha256": sha,
		"size": bytes.size(),
		"local_path": "",
	}


static func _sha256_hex(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	if not bytes.is_empty():
		context.update(bytes)
	return context.finish().hex_encode()
