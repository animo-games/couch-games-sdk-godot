# Files that shipped inside the build, and immutable shared files published for
# the game, exposed together as `CouchGames.game`.
#
# Build files retain their original build-root behaviour. Shared files are a
# distinct namespace: a decoded logical path is resolved through the platform's
# launch manifest before it is read. In the editor/local relay the mock maps
# the same logical path directly into couch_games/mock/shared_files_dir.
class_name CouchGameFiles
extends Node

## Where build packs are staged before mounting. Kept as-is for compatibility.
const MOUNT_DIR := "user://couch_game/"

## Shared packs include their immutable root/content/path identity in the
## staging path. `load_resource_pack()` is process-global, so this prevents
## equal filenames from another game, root, or revision aliasing a mounted pack.
const SHARED_MOUNT_DIR := "user://couch_shared/"

## How long a download may go without receiving a byte before it is abandoned.
const STALL_TIMEOUT_MS := 30_000

var _backend: CouchGamesBackend

## Build and shared transfers use separate keys. Existing build behaviour is
## keyed by canonical build path; shared transfers include immutable identity.
var _build_in_flight: Dictionary = {}
var _shared_in_flight: Dictionary = {}

## A successful shared resolution is enough to ask whether its pack is mounted.
## Do not resolve from is_shared_pack_loaded(): before a game has resolved a
## path in this launch, there is deliberately no mounted identity to inspect.
var _shared_resolutions: Dictionary = {}


func setup(backend: CouchGamesBackend) -> void:
	_backend = backend


# --- Build files (existing public API) ---

func build_root() -> String:
	if _backend == null:
		return ""
	return _backend.build_root()


func is_pack_loaded(relative_path: String) -> bool:
	var mount_path := _build_mount_path(relative_path)
	return not mount_path.is_empty() and CouchPackInstaller.is_mounted(mount_path)


## Fetches and mounts a .pck/.zip shipped beside the exported build.
func load_pack(relative_path: String, on_progress: Callable = Callable()) -> bool:
	if _backend == null:
		push_error("CouchGames: SDK not initialised, call await CouchGames.init()")
		return false
	var canonical := canonical_build_path(relative_path)
	if canonical.is_empty():
		push_error("CouchGames: '%s' is not a valid build-relative path" % relative_path)
		return false
	var mount_path := MOUNT_DIR.path_join(canonical)
	if CouchPackInstaller.is_mounted(mount_path):
		return true

	if _build_in_flight.has(canonical):
		var active: Dictionary = _build_in_flight[canonical]
		while not active.get("done", false):
			await get_tree().process_frame
		return bool(active.get("loaded", false))

	var transfer := {"done": false, "loaded": false}
	_build_in_flight[canonical] = transfer
	var read: Dictionary = await _read_build(canonical, on_progress)
	if not read.get("success", false):
		push_error("CouchGames: %s" % str(read.get("error", "cannot read build file")))
	else:
		var bytes: PackedByteArray = read.get("bytes", PackedByteArray())
		transfer.loaded = CouchPackInstaller.install(bytes, mount_path, relative_path)
	transfer.done = true
	_build_in_flight.erase(canonical)
	return bool(transfer.loaded)


func _build_mount_path(relative_path: String) -> String:
	var canonical := canonical_build_path(relative_path)
	return MOUNT_DIR.path_join(canonical) if not canonical.is_empty() else ""


## Build-relative paths retain the legacy contract. Shared paths below are
## stricter because they cross a catalog/URL boundary and are decoded text.
static func canonical_build_path(relative_path: String) -> String:
	if relative_path.is_empty() or relative_path.begins_with("/"):
		return ""
	if relative_path.contains("\\") or relative_path.contains("://"):
		return ""
	for segment in relative_path.split("/"):
		if segment.is_empty() or segment == "." or segment == "..":
			return ""
	return relative_path


func _read_build(relative_path: String, on_progress: Callable) -> Dictionary:
	var root := build_root()
	if root.is_empty():
		return _read_failure("no build root, build files are unavailable here")
	if _is_http_url(root):
		return await _download(root.path_join(_encoded_path(relative_path)), on_progress)
	return _read_local(root.path_join(relative_path), on_progress)


# --- Shared game assets ---

## The explicit launch root from the parent runtime, or the local shared-files
## directory under the mock. A Web export outside a Couch Games parent keeps
## its historic mock behaviour for unrelated SDK APIs, but shared assets are
## intentionally unavailable because there is no manifest capability.
func shared_root() -> String:
	if _backend == null or _shared_capability_is_unavailable():
		return ""
	return _backend.shared_root()


## Resolves a logical shared filename to the immutable URL selected by this
## launch's manifest. On local/mock runs it returns the direct local path.
func get_shared_file_url(relative_path: String) -> String:
	var resolved: Dictionary = await _resolve_shared_file(relative_path)
	if not resolved.get("success", false):
		return ""
	return str(resolved.get("url", resolved.get("local_path", "")))


## Returns arbitrary shared bytes. A successful zero-byte object returns an
## empty PackedByteArray without reporting an error; callers that need a pack
## should use load_shared_pack(), which rejects empty/invalid packs explicitly.
func get_shared_file(relative_path: String, on_progress: Callable = Callable()) -> PackedByteArray:
	var resolved: Dictionary = await _resolve_shared_file(relative_path)
	if not resolved.get("success", false):
		return PackedByteArray()
	var read: Dictionary = await _read_shared(resolved, on_progress)
	if not read.get("success", false):
		push_error("CouchGames: %s" % str(read.get("error", "cannot read shared file")))
		return PackedByteArray()
	return read.get("bytes", PackedByteArray())


## Fetches a shared .pck/.zip selected by the current launch manifest and
## mounts it. The final mounted key includes root, hash and logical path.
func load_shared_pack(relative_path: String, on_progress: Callable = Callable()) -> bool:
	var resolved: Dictionary = await _resolve_shared_file(relative_path)
	if not resolved.get("success", false):
		return false
	var mount_path := _shared_mount_path(resolved)
	if mount_path.is_empty():
		push_error("CouchGames: cannot construct a safe shared-pack mount path")
		return false
	if CouchPackInstaller.is_mounted(mount_path):
		return true
	var read: Dictionary = await _read_shared(resolved, on_progress)
	if not read.get("success", false):
		push_error("CouchGames: %s" % str(read.get("error", "cannot read shared pack")))
		return false
	return CouchPackInstaller.install(
		read.get("bytes", PackedByteArray()), mount_path, str(resolved.get("logical_path", relative_path)))


## Does not contact the platform. It is false until this SDK instance has
## resolved the path in its current launch, even if another pack happens to
## have the same filename mounted process-wide.
func is_shared_pack_loaded(relative_path: String) -> bool:
	var canonical := canonical_shared_path(relative_path)
	if canonical.is_empty() or not _shared_resolutions.has(canonical):
		return false
	var resolved: Dictionary = _shared_resolutions[canonical]
	# A parent can replace its current launch while an old Godot frame is winding
	# down. Never treat that old resolution as belonging to the new root.
	if shared_root() != str(resolved.get("resolved_root", "")):
		return false
	var mount_path := _shared_mount_path(resolved)
	return not mount_path.is_empty() and CouchPackInstaller.is_mounted(mount_path)


func _resolve_shared_file(relative_path: String) -> Dictionary:
	var canonical := canonical_shared_path(relative_path)
	if canonical.is_empty():
		var invalid := _shared_failure("'%s' is not a valid shared logical path" % relative_path)
		push_error("CouchGames: %s" % invalid.error)
		return invalid
	if _backend == null:
		var unavailable := _shared_failure("SDK not initialised, call await CouchGames.init()")
		push_error("CouchGames: %s" % unavailable.error)
		return unavailable
	if _shared_capability_is_unavailable():
		var no_parent := _shared_failure(
			"Shared assets are unavailable in this Web export without the Couch Games parent SDK")
		push_error("CouchGames: %s" % no_parent.error)
		return no_parent

	# Capture the explicit root around the async resolution. The parent runtime
	# rejects a launch change itself, but this keeps a backend implementation from
	# ever attaching an old immutable identity to a newer root.
	var root_before := _backend.shared_root()
	var resolved: Dictionary = await _backend.resolve_shared_file(canonical)
	if root_before != _backend.shared_root():
		var changed := _shared_failure("Shared asset launch changed while resolving '%s'" % canonical)
		push_error("CouchGames: %s" % changed.error)
		return changed
	if not _validate_shared_resolution(resolved):
		var message := str(resolved.get("error", "invalid shared-file resolution"))
		push_error("CouchGames: %s" % message)
		return _shared_failure(message)
	resolved.logical_path = canonical
	resolved.resolved_root = root_before
	_shared_resolutions[canonical] = resolved
	return resolved


func _shared_capability_is_unavailable() -> bool:
	return OS.has_feature("web") and _backend != null and _backend.is_mock()


func _validate_shared_resolution(resolved: Dictionary) -> bool:
	if not resolved.get("success", false):
		return false
	if not _is_sha256(str(resolved.get("root_identity", ""))):
		return false
	if str(resolved.get("file_identity", "")).is_empty():
		return false
	if not _is_sha256(str(resolved.get("sha256", ""))):
		return false
	var size_value = resolved.get("size", -1)
	if (typeof(size_value) != TYPE_INT and typeof(size_value) != TYPE_FLOAT) \
			or float(size_value) < 0.0 or float(size_value) != floor(float(size_value)):
		return false
	var local_path := str(resolved.get("local_path", ""))
	var url := str(resolved.get("url", ""))
	return not local_path.is_empty() or _is_http_url(url)


func _shared_mount_path(resolved: Dictionary) -> String:
	var root_identity := str(resolved.get("root_identity", ""))
	var sha256 := str(resolved.get("sha256", ""))
	var logical_path := str(resolved.get("logical_path", ""))
	if not _is_sha256(root_identity) or not _is_sha256(sha256) \
			or canonical_shared_path(logical_path).is_empty():
		return ""
	return SHARED_MOUNT_DIR.path_join(root_identity).path_join(sha256).path_join(logical_path)


## A shared transfer is deduplicated only after immutable resolution. The first
## caller owns progress; waiters receive its final structured result and all
## terminal paths erase the in-flight key so a later retry can start fresh.
func _read_shared(resolved: Dictionary, on_progress: Callable) -> Dictionary:
	var key := "%s\n%s" % [resolved.root_identity, resolved.file_identity]
	if _shared_in_flight.has(key):
		var active: Dictionary = _shared_in_flight[key]
		while not active.get("done", false):
			await get_tree().process_frame
		return active.get("result", _read_failure("shared transfer ended without a result"))

	var transfer := {"done": false, "result": _read_failure("shared transfer did not start")}
	_shared_in_flight[key] = transfer
	var local_path := str(resolved.get("local_path", ""))
	var result: Dictionary
	if not local_path.is_empty():
		result = _read_local(local_path, on_progress)
	else:
		result = await _download(str(resolved.get("url", "")), on_progress)
	# The resolver and runtime reject a launch replacement while resolving, but
	# an HTTP body can still be in flight when the parent starts the next launch.
	# Do not return or mount bytes obtained for the old launch in that case.
	if shared_root() != str(resolved.get("resolved_root", "")):
		result = _read_failure("Shared asset launch changed while downloading '%s'"
			% str(resolved.get("logical_path", "")))
	if result.get("success", false):
		var bytes: PackedByteArray = result.get("bytes", PackedByteArray())
		if bytes.size() != int(resolved.get("size", -1)):
			result = _read_failure("shared file '%s' length does not match its immutable metadata"
				% str(resolved.get("logical_path", "")))
		elif _sha256_hex(bytes) != str(resolved.get("sha256", "")):
			result = _read_failure("shared file '%s' SHA-256 does not match its immutable metadata"
				% str(resolved.get("logical_path", "")))
	transfer.result = result
	transfer.done = true
	_shared_in_flight.erase(key)
	return result


## A decoded logical path. Keep Unicode exactly as supplied, but reject every
## spelling that can become a hierarchy/scheme after a URL or local join. A
## literal "%2e%2e" is not decoded here and remains a legal filename; callers
## pass decoded strings, and URL creation encodes each segment exactly once.
static func canonical_shared_path(relative_path: String) -> String:
	if relative_path.is_empty() or relative_path.begins_with("/") \
			or relative_path.contains("\\"):
		return ""
	for i in relative_path.length():
		var codepoint := relative_path.unicode_at(i)
		if codepoint <= 0x1F or (codepoint >= 0x7F and codepoint <= 0x9F):
			return ""
	if _starts_with_scheme(relative_path):
		return ""
	for segment in relative_path.split("/"):
		if segment.is_empty() or segment == "." or segment == "..":
			return ""
	return relative_path


static func _starts_with_scheme(value: String) -> bool:
	var colon := value.find(":")
	if colon <= 0:
		return false
	var slash := value.find("/")
	if slash != -1 and slash < colon:
		return false
	var prefix := value.substr(0, colon)
	if not _is_ascii_letter(prefix.unicode_at(0)):
		return false
	for i in range(1, prefix.length()):
		var codepoint := prefix.unicode_at(i)
		if not _is_ascii_letter(codepoint) and not (codepoint >= 48 and codepoint <= 57) \
				and codepoint != 43 and codepoint != 45 and codepoint != 46:
			return false
	return true


static func _is_ascii_letter(codepoint: int) -> bool:
	return (codepoint >= 65 and codepoint <= 90) or (codepoint >= 97 and codepoint <= 122)


static func _encoded_path(relative_path: String) -> String:
	var encoded := PackedStringArray()
	for segment in relative_path.split("/"):
		encoded.append(segment.uri_encode())
	return "/".join(encoded)


# --- Structured raw readers ---

## Both readers distinguish a failed read from a valid zero-byte object. The
## public byte method returns PackedByteArray for API compatibility, while the
## structured shape lets pack loading reject emptiness without misreporting it
## as an HTTP/local I/O error.
func _read_local(path: String, on_progress: Callable) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _read_failure("no file at %s" % path)
	var bytes := FileAccess.get_file_as_bytes(path)
	var open_error := FileAccess.get_open_error()
	if open_error != OK:
		return _read_failure("cannot read '%s': %s" % [path, error_string(open_error)])
	_report(on_progress, bytes.size(), bytes.size())
	return {"success": true, "error": "", "bytes": bytes}


func _download(url: String, on_progress: Callable) -> Dictionary:
	if not _is_http_url(url):
		return _read_failure("invalid HTTP shared-file URL '%s'" % url)
	var http := HTTPRequest.new()
	add_child(http)
	var outcome := {"done": false, "result": -1, "code": 0, "body": PackedByteArray()}
	http.request_completed.connect(_on_request_completed.bind(outcome), CONNECT_ONE_SHOT)

	var request_error := http.request(url)
	if request_error != OK:
		http.queue_free()
		return _read_failure("cannot request '%s': %s" % [url, error_string(request_error)])

	var reported := -1
	var advanced_at := Time.get_ticks_msec()
	while not outcome.done:
		var downloaded: int = http.get_downloaded_bytes()
		if downloaded != reported:
			reported = downloaded
			advanced_at = Time.get_ticks_msec()
			_report(on_progress, downloaded, http.get_body_size())
		elif Time.get_ticks_msec() - advanced_at > STALL_TIMEOUT_MS:
			http.cancel_request()
			http.queue_free()
			return _read_failure("download of '%s' stalled, no data for %d seconds"
				% [url, STALL_TIMEOUT_MS / 1000])
		await get_tree().process_frame

	http.queue_free()
	if outcome.result != HTTPRequest.RESULT_SUCCESS:
		return _read_failure("download of '%s' failed (HTTPRequest result %d)"
			% [url, outcome.result])
	if outcome.code < 200 or outcome.code >= 300:
		return _read_failure("'%s' returned HTTP %d" % [url, outcome.code])
	var body: PackedByteArray = outcome.body
	_report(on_progress, body.size(), body.size())
	return {"success": true, "error": "", "bytes": body}


func _on_request_completed(result: int, response_code: int,
		headers: PackedStringArray, body: PackedByteArray, outcome: Dictionary) -> void:
	outcome.result = result
	outcome.code = response_code
	outcome.body = body
	outcome.done = true


static func _read_failure(message: String) -> Dictionary:
	return {"success": false, "error": message, "bytes": PackedByteArray()}


static func _shared_failure(message: String) -> Dictionary:
	return {
		"success": false,
		"error": message,
		"root_identity": "",
		"file_identity": "",
		"url": "",
		"sha256": "",
		"size": -1,
		"local_path": "",
	}


static func _is_http_url(value: String) -> bool:
	return value.begins_with("https://") or value.begins_with("http://")


static func _is_sha256(value: String) -> bool:
	if value.length() != 64:
		return false
	for i in value.length():
		if "0123456789abcdef".find(value.substr(i, 1)) == -1:
			return false
	return true


static func _sha256_hex(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	if not bytes.is_empty():
		context.update(bytes)
	return context.finish().hex_encode()


func _report(on_progress: Callable, downloaded_bytes: int, total_bytes: int) -> void:
	if on_progress.is_valid():
		on_progress.call(downloaded_bytes, total_bytes)
