# Files that shipped inside the game's own build, exposed as `CouchGames.game`.
#
# A build file is anything you drop next to your export before uploading:
# tools/build_and_upload zips every file under res://build/web, so
# res://build/web/packs/rooms.pck ships with the build and is addressed here as
# "packs/rooms.pck". The parameter is a path RELATIVE to the build, never a
# URL — the platform mints each build's URL with a random suffix, and in the
# editor there is no URL at all.
#
# This is the PULL half of the pack story. Experience files are pushed: the
# platform starts downloading them before the game frame even mounts, and
# CouchGames.experience hands over bytes that have already landed. Build files
# are not fetched until the game asks, which is exactly what makes a progress
# bar possible here and impossible there.
#
#     func _ready() -> void:
#         await CouchGames.init()
#         await CouchGames.game.load_pack("packs/rooms.pck",
#             func(got: int, total: int) -> void:
#                 bar.value = 0.0 if total <= 0 else float(got) / total)
#
# Progress is a per-call Callable rather than a signal on this node so that two
# packs loading at once cannot cross wires: each load reports to its own
# listener, with nothing to filter.
#
# There is deliberately no load_all_packs() here. CouchGames.experience has one
# because somebody ELSE uploads an experience and the game cannot know the
# filenames. A build pack is shipped by the same person who writes the loading
# code, so they already know the name.
class_name CouchGameFiles
extends Node

## Where load_pack() stages bytes before handing them to the engine. Under
## user:// because res:// is read-only in an exported build.
const MOUNT_DIR := "user://couch_game/"

## How long a download may go without receiving a byte before it is abandoned.
## Deliberately NOT HTTPRequest.timeout, which bounds the TOTAL request: a value
## generous enough for a 100 MB pack on slow mobile cannot detect a stall, and
## one tight enough to detect a stall kills legitimate downloads. Measured from
## the request, so it also covers a server that accepts the connection and never
## responds — get_downloaded_bytes() sits at 0 until the first byte lands.
const STALL_TIMEOUT_MS := 30_000

var _backend: CouchGamesBackend

## Relative paths currently downloading. Two callers asking for the same pack
## must not both fetch it: the second parks until the first is done rather than
## racing it into load_resource_pack().
var _in_flight: Dictionary = {}


## Called by the CouchGames autoload during setup.
func setup(backend: CouchGamesBackend) -> void:
	_backend = backend


## The directory this build was served from: an absolute URL on the platform, a
## local directory in the editor (couch_games/mock/build_files_dir). Empty when
## the backend has no notion of one.
##
## load_pack() is the reason this exists, but it is public because it is also
## the escape hatch: join a relative path onto it and fetch whatever else you
## shipped, with your own HTTPRequest or FileAccess.
func build_root() -> String:
	if _backend == null:
		return ""
	return _backend.build_root()


## True once this pack has been loaded in this process.
func is_pack_loaded(relative_path: String) -> bool:
	var mount_path := _mount_path(relative_path)
	return not mount_path.is_empty() and CouchPackInstaller.is_mounted(mount_path)


## Fetches a .pck/.zip that shipped with this build and loads it into the
## resource system, so its contents become available at their res:// paths.
##
## `relative_path` is relative to the build root — "packs/rooms.pck" for a file
## you put at res://build/web/packs/rooms.pck before uploading.
##
## `on_progress` is called as bytes arrive, as f(downloaded_bytes: int,
## total_bytes: int). total_bytes is -1 while the size is still unknown (no
## Content-Length yet), so divide only after checking it is positive. A local
## read reports once, at 100%.
##
## Idempotent: loading the same pack twice is a no-op returning true, because
## load_resource_pack() replaces files and re-running it would reshuffle what a
## scene already resolved. Asking for one that is still downloading waits for
## that download rather than starting a second — in which case only the first
## caller's on_progress is called, since there is only the one download.
func load_pack(relative_path: String, on_progress: Callable = Callable()) -> bool:
	if _backend == null:
		push_error("CouchGames: SDK not initialised, call await CouchGames.init()")
		return false

	var canonical := _canonical_path(relative_path)
	if canonical.is_empty():
		push_error("CouchGames: '%s' is not a valid build-relative path" % relative_path)
		return false
	var mount_path := MOUNT_DIR.path_join(canonical)
	if CouchPackInstaller.is_mounted(mount_path):
		return true

	if _in_flight.has(canonical):
		# Park until the first caller finishes, the same way CouchGames.init()
		# parks a second caller behind the first.
		while _in_flight.has(canonical):
			await get_tree().process_frame
		return CouchPackInstaller.is_mounted(mount_path)

	_in_flight[canonical] = true
	var bytes: PackedByteArray = await _read(canonical, on_progress)
	var loaded := (not bytes.is_empty()
		and CouchPackInstaller.install(bytes, mount_path, relative_path))
	_in_flight.erase(canonical)
	return loaded


## Where a build-relative path is staged, or "" if it is not one.
func _mount_path(relative_path: String) -> String:
	var canonical := _canonical_path(relative_path)
	if canonical.is_empty():
		return ""
	return MOUNT_DIR.path_join(canonical)


## The one accepted spelling of a build-relative path, or "" if it is not one.
## Everything downstream keys off this single string — the _in_flight entry, the
## user:// staging path and the local source — so one file cannot become two of
## anything by being written two ways.
##
## Segments that are empty, "." or ".." are rejected rather than resolved:
## "packs/../packs/rooms.pck" is a legal path that this has no reason to accept,
## and refusing ".." as a SEGMENT (rather than as a substring, which is what
## this used to do) stops it rejecting a legitimate "foo..pck". A path that
## climbed out of the build directory would fetch something else entirely on
## the platform and stage it outside MOUNT_DIR here.
func _canonical_path(relative_path: String) -> String:
	if relative_path.is_empty() or relative_path.begins_with("/"):
		return ""
	if relative_path.contains("\\") or relative_path.contains("://"):
		return ""
	var segments := relative_path.split("/")
	for segment in segments:
		if segment.is_empty() or segment == "." or segment == "..":
			return ""
	return "/".join(segments)


## Bytes for one build file. The SCHEME decides how to read it, not the backend
## type: the platform serves the build over HTTP, while the mock (and any other
## local root) names a directory the engine can open directly. HTTPRequest
## cannot do the latter — it rejects any URL without an http(s) scheme.
func _read(relative_path: String, on_progress: Callable) -> PackedByteArray:
	var root := build_root()
	if root.is_empty():
		push_error("CouchGames: no build root, build files are unavailable here")
		return PackedByteArray()
	if root.begins_with("http://") or root.begins_with("https://"):
		var url := root.path_join(_encoded_path(relative_path))
		var downloaded: PackedByteArray = await _download(url, on_progress)
		return downloaded
	return _read_local(root.path_join(relative_path), on_progress)


## The URL form of a build-relative path. Encoded a segment at a time because
## uri_encode() escapes "/" as well, and only for HTTP: "packs/a?b.pck" is one
## file to FileAccess but path + query to a server, so without this a file with
## a "?" or "#" in its name loads in the mock and fetches the wrong thing (or
## nothing) on the platform.
func _encoded_path(relative_path: String) -> String:
	var encoded := PackedStringArray()
	for segment in relative_path.split("/"):
		encoded.append(segment.uri_encode())
	return "/".join(encoded)


func _read_local(path: String, on_progress: Callable) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		push_error("CouchGames: no build file at %s" % path)
		return PackedByteArray()
	var bytes := FileAccess.get_file_as_bytes(path)
	var open_error := FileAccess.get_open_error()
	if open_error != OK:
		push_error("CouchGames: cannot read '%s': %s" % [path, error_string(open_error)])
		return PackedByteArray()
	if bytes.is_empty():
		# Opened cleanly and read nothing: a genuinely zero-byte file, not a
		# read failure. Reported here because load_pack() cannot tell the two
		# empty results apart once they are both PackedByteArray().
		push_error("CouchGames: build file '%s' is empty" % path)
		return bytes
	# One report at 100%. A local read has no observable progress, but a caller
	# driving a bar should still see it reach the end.
	_report(on_progress, bytes.size(), bytes.size())
	return bytes


func _download(url: String, on_progress: Callable) -> PackedByteArray:
	var http := HTTPRequest.new()
	add_child(http)
	# Mutated by the callback, never reassigned: a lambda/bound callable
	# captures locals by value, so only a shared Dictionary carries the result
	# back out. Same pattern as the web backend's promise bridge.
	var outcome := {"done": false, "result": -1, "code": 0, "body": PackedByteArray()}
	http.request_completed.connect(_on_request_completed.bind(outcome), CONNECT_ONE_SHOT)

	var error := http.request(url)
	if error != OK:
		push_error("CouchGames: cannot request '%s': %s" % [url, error_string(error)])
		http.queue_free()
		return PackedByteArray()

	var reported := -1
	var advanced_at := Time.get_ticks_msec()
	while not outcome.done:
		var downloaded: int = http.get_downloaded_bytes()
		if downloaded != reported:
			reported = downloaded
			advanced_at = Time.get_ticks_msec()
			_report(on_progress, downloaded, http.get_body_size())
		elif Time.get_ticks_msec() - advanced_at > STALL_TIMEOUT_MS:
			# Without this the loop never exits, so _in_flight never clears and
			# every later caller for this path parks on it forever.
			http.cancel_request()
			http.queue_free()
			push_error("CouchGames: download of '%s' stalled, no data for %d seconds"
				% [url, STALL_TIMEOUT_MS / 1000])
			return PackedByteArray()
		await get_tree().process_frame

	http.queue_free()
	if outcome.result != HTTPRequest.RESULT_SUCCESS:
		push_error("CouchGames: download of '%s' failed (HTTPRequest result %d)"
			% [url, outcome.result])
		return PackedByteArray()
	if outcome.code < 200 or outcome.code >= 300:
		push_error("CouchGames: '%s' returned HTTP %d" % [url, outcome.code])
		return PackedByteArray()

	var body: PackedByteArray = outcome.body
	if body.is_empty():
		# load_pack() short-circuits on empty bytes, so this is the only place
		# the difference between "a 2xx with nothing in it" and a failure that
		# already reported itself is still known.
		push_error("CouchGames: '%s' returned HTTP %d with an empty body"
			% [url, outcome.code])
		return body
	_report(on_progress, body.size(), body.size())
	return body


func _on_request_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray,
		outcome: Dictionary) -> void:
	outcome.result = result
	outcome.code = response_code
	outcome.body = body
	outcome.done = true


## is_valid() covers both "no callback passed" and a callback whose node has
## been freed mid-download.
func _report(on_progress: Callable, downloaded_bytes: int, total_bytes: int) -> void:
	if on_progress.is_valid():
		on_progress.call(downloaded_bytes, total_bytes)
