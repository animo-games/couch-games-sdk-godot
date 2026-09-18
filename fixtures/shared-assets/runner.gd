extends SceneTree

const GameFiles := preload("res://addons/couch-games-sdk/game/couch_game_files.gd")
const MockBackend := preload("res://addons/couch-games-sdk/backends/mock_backend.gd")
const FixtureHttpBackend := preload("res://fixture_http_backend.gd")

var _failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_prepare_local_files()
	await _test_path_validation()
	await _test_mock_bytes_and_resolution()
	await _test_http_dedup_and_retry()
	await _test_distinct_pack_identities()
	if _failures.is_empty():
		print("SHARED_ASSETS_NATIVE_FIXTURE_PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("SHARED_ASSETS_NATIVE_FIXTURE: " + failure)
	quit(1)


func _prepare_local_files() -> void:
	for root_path in ["res://fixture_shared_a", "res://fixture_shared_b"]:
		var error := DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(root_path.path_join("nested")))
		_expect(error == OK or error == ERR_ALREADY_EXISTS, "create fixture nested directory")
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(root_path.path_join("packs")))
	_write_bytes("res://fixture_shared_a/nested/binary ?#%2e%2e ü.bin",
		PackedByteArray([0, 1, 2, 255, 0, 128, 64]))
	_write_bytes("res://fixture_shared_a/nested/empty.bin", PackedByteArray())


func _test_path_validation() -> void:
	for invalid in ["", "/leading", "nested//double", "nested/./dot", "nested/../up",
			"nested\\backslash", "https://host/file", "C:/file", "hello\nworld"]:
		_expect(GameFiles.canonical_shared_path(invalid).is_empty(), "reject logical path %s" % invalid)
	_expect(GameFiles.canonical_shared_path("nested/%2e%2e/a ?# ü.bin")
		== "nested/%2e%2e/a ?# ü.bin", "preserve decoded percent, punctuation and Unicode")


func _test_mock_bytes_and_resolution() -> void:
	ProjectSettings.set_setting("couch_games/mock/shared_files_dir", "res://fixture_shared_a")
	var backend := MockBackend.new()
	root.add_child(backend)
	await backend.initialize()
	var game := GameFiles.new()
	root.add_child(game)
	game.setup(backend)
	_expect(game.shared_root() == "res://fixture_shared_a", "expose mock shared root")
	_expect(not game.is_shared_pack_loaded("packs/common.pck"), "unresolved shared pack is not loaded")
	var logical := "nested/binary ?#%2e%2e ü.bin"
	var expected := PackedByteArray([0, 1, 2, 255, 0, 128, 64])
	var url := await game.get_shared_file_url(logical)
	_expect(url == "res://fixture_shared_a/" + logical, "local resolver returns direct local path")
	var bytes := await game.get_shared_file(logical)
	_expect(bytes == expected, "read nested arbitrary binary bytes")
	var empty_resolution: Dictionary = await backend.resolve_shared_file("nested/empty.bin")
	_expect(empty_resolution.get("success", false) and int(empty_resolution.get("size", -1)) == 0,
		"zero-byte local object resolves successfully")
	var empty := await game.get_shared_file("nested/empty.bin")
	_expect(empty.is_empty(), "zero-byte local object reads successfully")
	var missing: Dictionary = await backend.resolve_shared_file("nested/missing.bin")
	_expect(not missing.get("success", true), "missing local object is a structured failure")
	game.queue_free()
	backend.queue_free()


func _test_http_dedup_and_retry() -> void:
	var server := FixtureHttpServer.new()
	root.add_child(server)
	_expect(server.listen(), "start local HTTP fixture server")
	var backend := FixtureHttpBackend.new(server.base_url())
	root.add_child(backend)
	var game := GameFiles.new()
	root.add_child(game)
	game.setup(backend)
	var first_progress := {"count": 0}
	var second_progress := {"count": 0}
	var first := {"done": false, "bytes": PackedByteArray()}
	_start_read(game, "remote/shared.bin", first,
		func(_got: int, _total: int): first_progress.count += 1)
	await process_frame
	var second := {"done": false, "bytes": PackedByteArray()}
	_start_read(game, "remote/shared.bin", second,
		func(_got: int, _total: int): second_progress.count += 1)
	while not first.done or not second.done:
		await process_frame
	var first_bytes: PackedByteArray = first.bytes
	var second_bytes: PackedByteArray = second.bytes
	_expect(first_bytes == server.shared_bytes and second_bytes == server.shared_bytes,
		"concurrent immutable requests receive identical bytes")
	_expect(server.request_count("/shared.bin") == 1, "concurrent immutable requests share one HTTP transfer")
	_expect(first_progress.count > 0 and second_progress.count == 0,
		"only transfer initiator receives progress")
	var failed := await game.get_shared_file("remote/retry.bin")
	_expect(failed.is_empty(), "first transient HTTP failure returns no bytes")
	var retried := await game.get_shared_file("remote/retry.bin")
	_expect(retried == server.retry_bytes and server.request_count("/retry.bin") == 2,
		"failed transfer clears identity key so retry starts again")
	game.queue_free()
	backend.queue_free()
	server.queue_free()


func _start_read(game: Node, logical_path: String, result: Dictionary, progress: Callable) -> void:
	result.bytes = await game.get_shared_file(logical_path, progress)
	result.done = true


func _test_distinct_pack_identities() -> void:
	_write_bytes("res://fixture_payload_a.txt", "a".to_utf8_buffer())
	_write_bytes("res://fixture_payload_b.txt", "b".to_utf8_buffer())
	_expect(_make_pack("res://fixture_shared_a/packs/common.pck", "res://fixture_payload_a.txt",
		"res://shared_fixture/a.txt"), "create first native fixture pack")
	_expect(_make_pack("res://fixture_shared_b/packs/common.pck", "res://fixture_payload_b.txt",
		"res://shared_fixture/b.txt"), "create second native fixture pack")
	var backend := MockBackend.new()
	root.add_child(backend)
	await backend.initialize()
	var game := GameFiles.new()
	root.add_child(game)
	game.setup(backend)
	ProjectSettings.set_setting("couch_games/mock/shared_files_dir", "res://fixture_shared_a")
	_expect(await game.load_shared_pack("packs/common.pck"), "mount first common-named shared pack")
	var first_root := _sha256_hex(ProjectSettings.globalize_path("res://fixture_shared_a").simplify_path().to_utf8_buffer())
	var first_digest := _sha256_hex(FileAccess.get_file_as_bytes("res://fixture_shared_a/packs/common.pck"))
	ProjectSettings.set_setting("couch_games/mock/shared_files_dir", "res://fixture_shared_b")
	_expect(await game.load_shared_pack("packs/common.pck"), "mount second common-named shared pack")
	var second_root := _sha256_hex(ProjectSettings.globalize_path("res://fixture_shared_b").simplify_path().to_utf8_buffer())
	var second_digest := _sha256_hex(FileAccess.get_file_as_bytes("res://fixture_shared_b/packs/common.pck"))
	_expect(first_root != second_root, "different shared roots have different stable identities")
	_expect(FileAccess.file_exists("user://couch_shared/%s/%s/packs/common.pck" % [first_root, first_digest]),
		"first same-named pack keeps its identity-bearing mount path")
	_expect(FileAccess.file_exists("user://couch_shared/%s/%s/packs/common.pck" % [second_root, second_digest]),
		"second same-named pack keeps its identity-bearing mount path")
	_expect(game.is_shared_pack_loaded("packs/common.pck"), "resolved current-root pack reports mounted")
	game.queue_free()
	backend.queue_free()


func _make_pack(destination: String, source: String, packed_path: String) -> bool:
	var packer := PCKPacker.new()
	if packer.pck_start(destination) != OK:
		return false
	if packer.add_file(packed_path, source) != OK:
		return false
	return packer.flush() == OK


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures.append("cannot write fixture file " + path)
		return
	file.store_buffer(bytes)
	file.close()


func _sha256_hex(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	if not bytes.is_empty():
		context.update(bytes)
	return context.finish().hex_encode()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


class FixtureHttpServer extends Node:
	static var shared_bytes := PackedByteArray([9, 8, 7, 6, 5, 4])
	static var retry_bytes := PackedByteArray([4, 5, 6])
	var _server := TCPServer.new()
	var _connections: Array = []
	var _requests: Dictionary = {}

	func listen() -> bool:
		return _server.listen(0, "127.0.0.1") == OK

	func base_url() -> String:
		return "http://127.0.0.1:%d" % _server.get_local_port()

	func request_count(path: String) -> int:
		return int(_requests.get(path, 0))

	func _process(_delta: float) -> void:
		while _server.is_connection_available():
			_connections.append({"peer": _server.take_connection(), "frames": 0})
		for connection in _connections.duplicate():
			var peer: StreamPeerTCP = connection.peer
			connection.frames += 1
			if peer.get_available_bytes() <= 0 or connection.frames < 2:
				continue
			var request := peer.get_data(peer.get_available_bytes())
			if request[0] != OK:
				_connections.erase(connection)
				continue
			var first_line: String = request[1].get_string_from_utf8().get_slice("\n", 0)
			var pieces: PackedStringArray = first_line.split(" ")
			var path := str(pieces[1]) if pieces.size() > 1 else "/"
			_requests[path] = request_count(path) + 1
			var retry_once := path == "/retry.bin" and request_count(path) == 1
			var body := PackedByteArray() if retry_once else (retry_bytes if path == "/retry.bin" else shared_bytes)
			var status := 503 if retry_once else 200
			var header := "HTTP/1.1 %d %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [
				status, "retry" if retry_once else "ok", body.size()]
			peer.put_data(header.to_utf8_buffer() + body)
			peer.disconnect_from_host()
			_connections.erase(connection)

	func _exit_tree() -> void:
		_server.stop()
