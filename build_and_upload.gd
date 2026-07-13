extends SceneTree
# Build the Web export and push it to couchgames.com as a new dev version.
#
# Pure Godot, zero external CLI tools: uses ZIPPacker (instead of `zip`),
# HTTPClient (instead of `curl`), and JSON (instead of `jq`), so the exact same
# logic runs on Windows, macOS, and Linux. The only requirement is a Godot
# editor binary with the Web export templates installed.
#
# Run it through the thin launcher for your platform, which just locates Godot:
#   ./addons/couch-games-sdk/build_and_upload.sh  <game-slug>   (macOS/Linux)
#   ./addons/couch-games-sdk/build_and_upload.ps1 <game-slug>   (Windows)
# ...or invoke it directly:
#   <godot> --headless --path <project> \
#     --script res://addons/couch-games-sdk/build_and_upload.gd -- <game-slug>
#
# Assumes it lives at <project>/addons/couch-games-sdk/ inside a Godot project
# with a "Web" export preset. Reads COUCHGAMES_API_KEY (required) and optional
# DEV_PORTAL_URL from the environment or a .env file at the project root.

const PRESET := "Web"
const DEFAULT_PORTAL := "https://developer.couchgames.com"

func _init() -> void:
	# Defer to the first idle frame: doing TLS/network I/O straight from _init()
	# fails with "SSL module failed to initialize!" because the crypto module and
	# scene tree aren't ready yet. By the deferred call they are.
	_start.call_deferred()

func _start() -> void:
	quit(await _run())

func _run() -> int:
	var user_args := OS.get_cmdline_user_args()
	if user_args.is_empty():
		printerr("usage: build_and_upload.gd -- <game-slug>")
		return 2
	var slug: String = user_args[0]

	var env := _load_env("res://.env")
	var api_key := _resolve("COUCHGAMES_API_KEY", env, "")
	if api_key == "":
		printerr("COUCHGAMES_API_KEY is required (create one on the API Keys page of the dev portal).")
		return 1
	var portal := _resolve("DEV_PORTAL_URL", env, DEFAULT_PORTAL).rstrip("/")

	# 1. Export ----------------------------------------------------------------
	var project_dir := ProjectSettings.globalize_path("res://")
	var web_dir := ProjectSettings.globalize_path("res://build/web")
	DirAccess.make_dir_recursive_absolute(web_dir)
	# .gdignore keeps Godot from importing prior export output back into the build.
	var ignore := FileAccess.open("res://build/.gdignore", FileAccess.WRITE)
	if ignore:
		ignore.close()

	var index_path := web_dir.path_join("index.html")
	print("Exporting \"%s\" preset ..." % PRESET)
	var export_args := ["--headless", "--path", project_dir, "--export-release", PRESET, index_path]
	var out := []
	var rc := OS.execute(OS.get_executable_path(), export_args, out, true)
	if rc != 0:
		printerr("Export failed (exit %d):" % rc)
		for chunk in out:
			printerr(chunk)
		return 1

	# 2. Zip the *contents* of build/web (index.html lands at the archive root,
	#    matching what the upload endpoint extracts to games/<slug>/v<n>/<path>).
	var zip_path := ProjectSettings.globalize_path("res://build/_upload.zip")
	if FileAccess.file_exists(zip_path):
		DirAccess.remove_absolute(zip_path)
	var packer := ZIPPacker.new()
	var perr := packer.open(zip_path)
	if perr != OK:
		printerr("Could not create %s (error %d)" % [zip_path, perr])
		return 1
	var count := _zip_dir(packer, web_dir, "")
	packer.close()
	if count == 0:
		printerr("Export produced no files in %s" % web_dir)
		return 1

	# 3. Upload ----------------------------------------------------------------
	var zip_bytes := FileAccess.get_file_as_bytes(zip_path)
	print("Uploading %s build to %s ..." % [_human_size(zip_bytes.size()), portal])
	return await _upload(portal, slug, api_key, zip_bytes)


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


# Recursively add every file under abs_dir to the archive, storing it under
# prefix (forward slashes, per the zip spec). Returns the number of files added.
func _zip_dir(packer: ZIPPacker, abs_dir: String, prefix: String) -> int:
	var written := 0
	var d := DirAccess.open(abs_dir)
	if d == null:
		return 0
	d.set_include_hidden(true)
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name != "." and name != "..":
			var child := abs_dir.path_join(name)
			var rel := name if prefix == "" else prefix + "/" + name
			if d.current_is_dir():
				written += _zip_dir(packer, child, rel)
			else:
				packer.start_file(rel)
				packer.write_file(FileAccess.get_file_as_bytes(child))
				packer.close_file()
				written += 1
		name = d.get_next()
	d.list_dir_end()
	return written


func _human_size(n: int) -> String:
	if n >= 1048576:
		return "%.1fM" % (n / 1048576.0)
	if n >= 1024:
		return "%.1fK" % (n / 1024.0)
	return "%dB" % n


# POST the zip as multipart/form-data (field "gameFile") to the versions endpoint.
# Uses HTTPRequest so TLS, redirects, and chunked responses are handled for us.
func _upload(portal: String, slug: String, api_key: String, zip_bytes: PackedByteArray) -> int:
	var url := "%s/api/games/%s/versions" % [portal, slug]
	var boundary := "----CouchGamesBoundary" + str(Time.get_ticks_usec())
	var head := "--%s\r\nContent-Disposition: form-data; name=\"gameFile\"; filename=\"build.zip\"\r\nContent-Type: application/zip\r\n\r\n" % boundary
	var tail := "\r\n--%s--\r\n" % boundary
	var body := PackedByteArray()
	body.append_array(head.to_utf8_buffer())
	body.append_array(zip_bytes)
	body.append_array(tail.to_utf8_buffer())
	var headers := PackedStringArray([
		"X-API-Key: " + api_key,
		"Content-Type: multipart/form-data; boundary=" + boundary,
	])

	var req := HTTPRequest.new()
	root.add_child(req)
	var err := req.request_raw(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		printerr("Upload request failed to start (error %d)" % err)
		req.queue_free()
		return 1
	var res: Array = await req.request_completed
	req.queue_free()

	var result: int = res[0]
	var status_code: int = res[1]
	if result != HTTPRequest.RESULT_SUCCESS:
		printerr("Upload did not complete (HTTPRequest result %d)" % result)
		return 1
	var text: String = (res[3] as PackedByteArray).get_string_from_utf8()
	if status_code < 200 or status_code >= 300:
		printerr("Upload failed (HTTP %d):" % status_code)
		printerr(text)
		return 1

	var json := JSON.new()
	if json.parse(text) == OK and typeof(json.data) == TYPE_DICTIONARY:
		var data: Dictionary = json.data
		if not data.get("success", false):
			printerr("Upload failed (HTTP %d):" % status_code)
			printerr(text)
			return 1
		print("Uploaded version %s (%s files) — now the isDeveloperActive build for \"%s\"." % [
			str(data.get("versionNumber", "?")), str(data.get("filesUploaded", "?")), slug])
	else:
		print(text)
	print("Play: https://couchgames.com/games/%s" % slug)
	return 0
