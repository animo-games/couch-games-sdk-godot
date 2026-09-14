extends SceneTree
# Publishes a directory as a game's shared assets: audio, packs, or other
# large resources that can change without a new build export. Never creates a
# version and never removes remote files -- a name absent locally today may
# still be referenced by an existing launch's manifest snapshot.
#
# Uses HTTPRequest for the multipart upload protocol instead of `curl`, so it
# behaves the same on Windows, macOS and Linux. All it needs is a Godot editor
# binary -- no export templates required.
#
# Run it through the launcher for your platform (they only locate Godot):
#   ./addons/couch-games-sdk/tools/upload_shared_assets.sh  <slug> [dir] [--overwrite]
#   .\addons\couch-games-sdk\tools\upload_shared_assets.ps1 <slug> [dir] [--overwrite]
# or invoke it directly:
#   <godot> --headless --path <project> \
#     --script res://addons/couch-games-sdk/tools/upload_shared_assets.gd \
#     -- <slug> [dir] [--overwrite]
#
# `dir` defaults to couch_games/mock/shared_files_dir (default res://shared_files)
# -- the same directory the mock reads in the editor, so what you test locally
# is what you publish. Reads COUCHGAMES_API_KEY (required) and DEV_PORTAL_URL
# (optional) from the environment or from a .env file at the project root.

const SHARED_DIR_SETTING := "couch_games/mock/shared_files_dir"
const DEFAULT_SHARED_DIR := "res://shared_files"
const DEFAULT_PORTAL := "https://developer.couchgames.com"
const SHARED_FILE_MAX_BYTES := 200 * 1024 * 1024
const MAX_RETRIES := 4
const _USAGE := "usage: upload_shared_assets.gd -- <game-slug> [dir] [--overwrite]"

# Extension -> MIME type. Godot has no MIME-sniffing library (the reference
# upload script relies on Bun's), so this covers the asset kinds shared game
# assets are expected to hold; anything else falls back to octet-stream.
const _MIME_TYPES := {
	"png": "image/png",
	"jpg": "image/jpeg",
	"jpeg": "image/jpeg",
	"gif": "image/gif",
	"webp": "image/webp",
	"svg": "image/svg+xml",
	"ogg": "audio/ogg",
	"mp3": "audio/mpeg",
	"wav": "audio/wav",
	"json": "application/json",
	"txt": "text/plain",
	"md": "text/markdown",
	"csv": "text/csv",
	"html": "text/html",
	"js": "text/javascript",
	"css": "text/css",
	"wasm": "application/wasm",
	"pck": "application/octet-stream",
	"zip": "application/zip",
	"glb": "model/gltf-binary",
	"gltf": "model/gltf+json",
	"ttf": "font/ttf",
	"otf": "font/otf",
	"woff": "font/woff",
	"woff2": "font/woff2",
	"mp4": "video/mp4",
	"webm": "video/webm",
}


func _init() -> void:
	# Deferred to the first idle frame. TLS/network I/O straight out of _init()
	# fails with "SSL module failed to initialize!" because the crypto module
	# and the scene tree aren't up yet.
	_start.call_deferred()


func _start() -> void:
	quit(await _run())


func _run() -> int:
	var parsed := _parse_args(OS.get_cmdline_user_args())
	if parsed.error != "":
		printerr(parsed.error)
		return parsed.code

	var prepared := await _prepare(parsed)
	if prepared.error != "":
		printerr(prepared.error)
		return prepared.code

	return await _upload_all(prepared)


# Parses the user args into {slug, dir_arg, overwrite, error, code}. A
# non-empty error means the caller should print it and exit with code.
func _parse_args(user_args: PackedStringArray) -> Dictionary:
	var slug := ""
	var dir_arg := ""
	var overwrite := false
	var bad_usage := user_args.is_empty()
	for arg in user_args:
		if arg == "--overwrite":
			overwrite = true
		elif slug == "":
			slug = arg
		elif dir_arg == "":
			dir_arg = arg
		else:
			bad_usage = true
	if slug == "":
		bad_usage = true
	if bad_usage:
		return {"error": _USAGE, "code": 2}
	return {"slug": slug, "dir_arg": dir_arg, "overwrite": overwrite, "error": "", "code": 0}


# Resolves env/config, walks the local directory, and lists the remote
# manifest, returning everything _upload_all needs. On failure, {error, code}
# describes what to print and exit with.
func _prepare(parsed: Dictionary) -> Dictionary:
	var env := _load_env("res://.env")
	var api_key := _resolve("COUCHGAMES_API_KEY", env, "")
	if api_key == "":
		return {
			"error": "COUCHGAMES_API_KEY is required (create one on the API Keys page of the dev portal).",
			"code": 1,
		}
	var portal := _resolve("DEV_PORTAL_URL", env, DEFAULT_PORTAL).rstrip("/")

	var dir: String = parsed.dir_arg
	if dir == "":
		dir = str(ProjectSettings.get_setting(SHARED_DIR_SETTING, DEFAULT_SHARED_DIR)).strip_edges()
		if dir == "":
			dir = DEFAULT_SHARED_DIR
	var abs_dir := ProjectSettings.globalize_path(dir)
	if not DirAccess.dir_exists_absolute(abs_dir):
		return {"error": "Directory not found: %s" % abs_dir, "code": 2}

	var collected := _collect_files(abs_dir)
	if collected.error != "":
		return {"error": collected.error, "code": 1}
	var files: Array = collected.files
	print("skipped %d file(s) (.import sidecars / dot-prefixed)" % collected.skipped)

	var encoded_slug: String = str(parsed.slug).uri_encode()
	var remote := await _list_remote(portal, encoded_slug, api_key)
	if remote.error != "":
		return {"error": remote.error, "code": 1}
	var remote_files: Dictionary = remote.files

	var duplicates := []
	for f in files:
		if remote_files.has(f.logical_path):
			duplicates.append(f.logical_path)
	if duplicates.size() > 0 and not parsed.overwrite:
		return {
			"error": (
				"Refusing to replace %d existing shared asset(s) without --overwrite: %s"
				% [duplicates.size(), ", ".join(duplicates)]
			),
			"code": 1,
		}

	return {
		"error": "",
		"portal": portal,
		"encoded_slug": encoded_slug,
		"api_key": api_key,
		"files": files,
		"remote_files": remote_files,
	}


# Uploads every local file sequentially and prints the sorted result lines.
func _upload_all(prepared: Dictionary) -> int:
	var files: Array = prepared.files
	var remote_files: Dictionary = prepared.remote_files
	var results := []
	for f in files:
		if f.size > SHARED_FILE_MAX_BYTES:
			var max_mib := SHARED_FILE_MAX_BYTES / (1024 * 1024)
			results.append({
				"logical_path": f.logical_path,
				"success": false,
				"message": "file exceeds the %d MiB limit" % max_mib,
			})
			continue
		var expected_revision = remote_files.get(f.logical_path, null)
		results.append(await _upload_file(
			prepared.portal, prepared.encoded_slug, prepared.api_key, f, expected_revision
		))

	var failures := 0
	for r in results:
		if r.success:
			var verb := "recovered" if r.get("replayed", false) else "uploaded"
			print("%s: %s → %s" % [verb, r.logical_path, r.get("url", "")])
		else:
			printerr("failed: %s — %s" % [r.logical_path, r.message])
			failures += 1
	print(
		"%d/%d shared asset(s) published; remote files absent locally were left unchanged."
		% [results.size() - failures, files.size()]
	)
	return 0 if failures == 0 else 1


# --- Local directory walk ---

# Recursively collects uploadable files under abs_dir. Skips *.import
# sidecars (Godot writes these next to imported assets; they must never be
# published) and any dot-prefixed file or directory. Returns
# {files: Array[{logical_path, absolute_path, size}], skipped: int, error: String}
# -- a non-empty error means a logical path failed validation and the whole
# run should abort before anything is uploaded.
func _collect_files(abs_dir: String) -> Dictionary:
	var files := []
	var counters := {"skipped": 0}
	var error := _walk_dir(abs_dir, abs_dir, files, counters)
	if error != "":
		return {"files": [], "skipped": counters.skipped, "error": error}
	files.sort_custom(func(a, b): return a.logical_path < b.logical_path)
	return {"files": files, "skipped": counters.skipped, "error": ""}


func _walk_dir(root_dir: String, current_dir: String, files: Array, counters: Dictionary) -> String:
	var d := DirAccess.open(current_dir)
	if d == null:
		return "Could not open directory: %s (error %d)" % [current_dir, DirAccess.get_open_error()]
	d.set_include_hidden(true)
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name == "." or name == "..":
			name = d.get_next()
			continue
		if name.begins_with("."):
			counters.skipped += 1
			name = d.get_next()
			continue
		var child := current_dir.path_join(name)
		if d.current_is_dir():
			var err := _walk_dir(root_dir, child, files, counters)
			if err != "":
				return err
		elif name.ends_with(".import"):
			counters.skipped += 1
		else:
			var rel := child.substr(root_dir.length()).trim_prefix("/")
			var validation_error := _validate_logical_path(rel)
			if validation_error != "":
				return "Invalid shared asset path \"%s\": %s" % [rel, validation_error]
			var fa := FileAccess.open(child, FileAccess.READ)
			if fa == null:
				return "Could not read %s (error %d)" % [child, FileAccess.get_open_error()]
			var size := fa.get_length()
			fa.close()
			files.append({"logical_path": rel, "absolute_path": child, "size": size})
		name = d.get_next()
	d.list_dir_end()
	return ""


# Mirrors validateSharedLogicalPath in packages/config/src/shared-assets.ts
# (platform-dev) so a path this tool accepts is one the portal will accept.
func _validate_logical_path(path: String) -> String:
	if path == "":
		return "must not be empty"
	if path.begins_with("/"):
		return "must not start with \"/\""
	if path.find("\\") != -1 or _has_control_char(path):
		return "must not contain \"\\\" or a control character"
	if _is_scheme_like(path) or _is_windows_drive(path):
		return "must not look like a URL or a Windows drive"
	for segment in path.split("/"):
		var bad_segment := segment == "" or segment == "." or segment == ".."
		if bad_segment or _is_windows_drive(segment):
			return "must not contain an empty, \".\", \"..\", or Windows-drive-like segment"
	return ""


func _has_control_char(s: String) -> bool:
	for i in s.length():
		var c := s.unicode_at(i)
		if c <= 0x1F or (c >= 0x7F and c <= 0x9F):
			return true
	return false


# ^[a-z][a-z0-9+.-]*: (case-insensitive), tested against the start of the string.
func _is_scheme_like(s: String) -> bool:
	if s.length() == 0:
		return false
	var first := s[0].to_lower()
	if first < "a" or first > "z":
		return false
	var i := 1
	while i < s.length():
		var ch := s[i]
		var lower := ch.to_lower()
		var is_scheme_char := (lower >= "a" and lower <= "z") or (lower >= "0" and lower <= "9")
		if is_scheme_char or ch == "+" or ch == "." or ch == "-":
			i += 1
			continue
		return ch == ":"
	return false


# ^[a-z]:i (case-insensitive) -- a Windows drive letter.
func _is_windows_drive(s: String) -> bool:
	if s.length() < 2:
		return false
	var first := s[0].to_lower()
	return first >= "a" and first <= "z" and s[1] == ":"


# --- Remote listing ---

# GET .../shared-files, following nextCursor. Returns
# {files: Dictionary[path -> revision String], error: String}.
func _list_remote(portal: String, encoded_slug: String, api_key: String) -> Dictionary:
	var files := {}
	var cursor := ""
	while true:
		var url := "%s/api/games/%s/shared-files" % [portal, encoded_slug]
		if cursor != "":
			url += "?cursor=%s" % cursor.uri_encode()
		var res := await _request_with_retry({
			"url": url,
			"headers": PackedStringArray(["X-API-Key: " + api_key]),
			"method": HTTPClient.METHOD_GET,
		})
		if not res.ok:
			return {"files": {}, "error": res.error}
		var data: Dictionary = res.data
		for item in data.get("files", []):
			files[str(item.path)] = str(item.revision)
		var next_cursor = data.get("nextCursor")
		if next_cursor == null or str(next_cursor) == "":
			break
		cursor = str(next_cursor)
	return {"files": files, "error": ""}


# --- Upload ---

# Runs the begin/parts/complete protocol for one file. On any failure before
# the complete request is first attempted, best-effort aborts the upload so
# the server doesn't hold a staged multipart around unnecessarily. Returns
# {logical_path, success, message} or {logical_path, success, url, replayed}.
func _upload_file(
	portal: String, encoded_slug: String, api_key: String, file: Dictionary, expected_revision
) -> Dictionary:
	var logical_path: String = file.logical_path
	var base_url := "%s/api/games/%s/shared-files/uploads" % [portal, encoded_slug]

	var begin_res := await _request_with_retry({
		"url": base_url,
		"headers": PackedStringArray(["X-API-Key: " + api_key, "Content-Type: application/json"]),
		"method": HTTPClient.METHOD_POST,
		"body_str": JSON.stringify({
			"path": logical_path,
			"size": file.size,
			"contentType": _guess_content_type(logical_path),
			"expectedRevision": expected_revision,
		}),
	})
	if not begin_res.ok:
		return {"logical_path": logical_path, "success": false, "message": begin_res.error}

	var begin_data: Dictionary = begin_res.data
	var upload_id: String = str(begin_data.uploadId)
	var part_size: int = int(begin_data.partSize)
	var part_count: int = int(begin_data.partCount)
	var upload_base := "%s/%s" % [base_url, upload_id.uri_encode()]

	var fa := FileAccess.open(file.absolute_path, FileAccess.READ)
	if fa == null:
		await _abort_upload(upload_base, api_key)
		return {
			"logical_path": logical_path,
			"success": false,
			"message": "could not read %s (error %d)" % [file.absolute_path, FileAccess.get_open_error()],
		}

	var parts := []
	var failure_message := ""
	for part_number in range(1, part_count + 1):
		var start: int = (part_number - 1) * part_size
		var end: int = mini(part_number * part_size, file.size)
		fa.seek(start)
		var bytes := fa.get_buffer(end - start)
		var part_res := await _request_with_retry({
			"url": "%s/parts/%d" % [upload_base, part_number],
			"headers": PackedStringArray([
				"X-API-Key: " + api_key, "Content-Type: application/octet-stream",
			]),
			"method": HTTPClient.METHOD_POST,
			"body_bytes": bytes,
			"use_raw": true,
		})
		if not part_res.ok:
			failure_message = part_res.error
			break
		var part_data: Dictionary = part_res.data
		parts.append({"partNumber": int(part_data.partNumber), "etag": str(part_data.etag)})
	fa.close()

	if failure_message != "":
		await _abort_upload(upload_base, api_key)
		return {"logical_path": logical_path, "success": false, "message": failure_message}

	# The complete request is now "first attempted" -- a failure past this
	# point may have already published on the server, so we must not abort;
	# the server's retention sweep is the backstop instead.
	var complete_res := await _request_with_retry({
		"url": "%s/complete" % upload_base,
		"headers": PackedStringArray(["X-API-Key: " + api_key, "Content-Type: application/json"]),
		"method": HTTPClient.METHOD_POST,
		"body_str": JSON.stringify({"parts": parts}),
	})
	if not complete_res.ok:
		return {"logical_path": logical_path, "success": false, "message": complete_res.error}

	var complete_data: Dictionary = complete_res.data
	return {
		"logical_path": logical_path,
		"success": true,
		"url": str(complete_data.get("url", "")),
		"replayed": bool(complete_data.get("replayed", false)),
	}


# One attempt, ignore the result either way -- a best-effort cleanup only.
func _abort_upload(upload_base: String, api_key: String) -> void:
	await _request_with_retry({
		"url": "%s/abort" % upload_base,
		"headers": PackedStringArray(["X-API-Key: " + api_key, "Content-Type: application/json"]),
		"method": HTTPClient.METHOD_POST,
		"body_str": "{}",
		"retries": 0,
	})


func _guess_content_type(logical_path: String) -> String:
	return _MIME_TYPES.get(logical_path.get_extension().to_lower(), "application/octet-stream")


# --- HTTP with retry ---

# Retries a 503 (honoring Retry-After when numeric) or a network-level failure
# with full jitter, resending the identical URL and body each time. Any other
# non-2xx status, or a 2xx body with ok == false, is terminal. Returns
# {ok: true, data: Variant} or {ok: false, error: String}.
#
# opts: {url, headers, method, body_str (default ""), body_bytes (default ""),
# use_raw (default false), retries (default MAX_RETRIES)}.
func _request_with_retry(opts: Dictionary) -> Dictionary:
	var retries: int = opts.get("retries", MAX_RETRIES)
	var attempt := 0
	while true:
		var attempt_result := await _do_one_request(opts)
		if not attempt_result.network_ok:
			if attempt < retries:
				await _sleep(_retry_delay_seconds("", attempt))
				attempt += 1
				continue
			return {"ok": false, "error": attempt_result.raw_error}

		if attempt_result.status == 503 and attempt < retries:
			var retry_after := _find_header(attempt_result.headers, "Retry-After")
			await _sleep(_retry_delay_seconds(retry_after, attempt))
			attempt += 1
			continue

		var data = attempt_result.data
		var body_ok: bool = not (typeof(data) == TYPE_DICTIONARY and data.get("ok", true) == false)
		if attempt_result.status < 200 or attempt_result.status >= 300 or not body_ok:
			var message := "HTTP %d" % attempt_result.status
			if typeof(data) == TYPE_DICTIONARY:
				var err_obj = data.get("error")
				if typeof(err_obj) == TYPE_DICTIONARY and typeof(err_obj.get("message")) == TYPE_STRING:
					message = err_obj.message
			return {"ok": false, "error": message}
		return {"ok": true, "data": data}
	return {"ok": false, "error": "unreachable"}  # satisfies static return-path analysis


# Performs exactly one HTTP attempt from the same opts _request_with_retry
# takes. Returns {network_ok: false, raw_error: String} or
# {network_ok: true, status: int, data: Variant, headers: PackedStringArray}.
func _do_one_request(opts: Dictionary) -> Dictionary:
	var url: String = opts.url
	var headers: PackedStringArray = opts.headers
	var method: HTTPClient.Method = opts.method
	var use_raw: bool = opts.get("use_raw", false)

	var req := HTTPRequest.new()
	root.add_child(req)
	var start_err: int
	if use_raw:
		var body_bytes: PackedByteArray = opts.get("body_bytes", PackedByteArray())
		start_err = req.request_raw(url, headers, method, body_bytes)
	else:
		var body_str: String = opts.get("body_str", "")
		start_err = req.request(url, headers, method, body_str)
	if start_err != OK:
		req.queue_free()
		return {"network_ok": false, "raw_error": "request failed to start (error %d)" % start_err}

	var res: Array = await req.request_completed
	req.queue_free()
	var result: int = res[0]
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"network_ok": false, "raw_error": "network error (HTTPRequest result %d)" % result}

	var body: PackedByteArray = res[3]
	var text := body.get_string_from_utf8()
	var data = null
	var json := JSON.new()
	if json.parse(text) == OK:
		data = json.data
	return {"network_ok": true, "status": res[1], "data": data, "headers": res[2]}


func _find_header(headers: PackedStringArray, name: String) -> String:
	var prefix := name.to_lower() + ":"
	for h in headers:
		if h.to_lower().begins_with(prefix):
			return h.substr(h.find(":") + 1).strip_edges()
	return ""


func _retry_delay_seconds(retry_after: String, attempt: int) -> float:
	if retry_after != "" and retry_after.is_valid_float():
		var seconds := retry_after.to_float()
		if seconds >= 0.0:
			return seconds
	# Full jitter bounds synchronized client retries while retaining a finite
	# recovery window for a durable server-side publication attempt.
	return (randf() * minf(8000.0, 250.0 * pow(2.0, attempt))) / 1000.0


func _sleep(seconds: float) -> void:
	await create_timer(seconds).timeout


# --- .env / environment resolution ---
# Duplicated from build_and_upload.gd rather than shared: that file is an
# embedded submodule in six game repos and must not be refactored from here.

# Resolve a config value: real environment wins, then .env, then the fallback.
func _resolve(name: String, env: Dictionary, fallback: String) -> String:
	var from_env := OS.get_environment(name)
	if from_env != "":
		return from_env
	return env.get(name, fallback)


# Minimal KEY=VALUE .env parser (handles # comments and quoted values).
func _load_env(res_path: String) -> Dictionary:
	var vars := {}
	if not FileAccess.file_exists(res_path):
		return vars
	var f := FileAccess.open(res_path, FileAccess.READ)
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		var eq := line.find("=")
		if eq == -1:
			continue
		var key := line.substr(0, eq).strip_edges()
		var val := line.substr(eq + 1).strip_edges()
		if val.length() >= 2 and ((val.begins_with("\"") and val.ends_with("\"")) or (val.begins_with("'") and val.ends_with("'"))):
			val = val.substr(1, val.length() - 2)
		vars[key] = val
	return vars
