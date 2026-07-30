@tool
extends EditorExportPlugin

const PATCH_MARKER := "/*present-path-patch*/"
const FORCED := (
	"if(contextAttributes.explicitSwapControl&&"
	+ "!contextAttributes.renderViaOffscreenBackBuffer)"
	+ "{contextAttributes.renderViaOffscreenBackBuffer=true}"
)
const PATCHED := (
	"if(false&&contextAttributes.explicitSwapControl&&"
	+ "!contextAttributes.renderViaOffscreenBackBuffer)"
	+ "{contextAttributes.renderViaOffscreenBackBuffer=true}"
	+ PATCH_MARKER
)
const COMMIT_OK := (
	"if(GL.currentContext.defaultFbo){GL.blitOffscreenFramebuffer"
	+ "(GL.currentContext);return 0}if(!GL.currentContext.attributes."
	+ "explicitSwapControl){return-3}return 0"
)

var _web_export_path := ""


func _get_name() -> String:
	return "CouchGamesPresentPathPatch"


func _export_begin(
	features: PackedStringArray,
	_is_debug: bool,
	path: String,
	_flags: int
) -> void:
	_web_export_path = path if is_web_export(features) else ""


func _export_end() -> void:
	if _web_export_path == "":
		return

	var export_path := _web_export_path
	_web_export_path = ""
	if export_path.begins_with("res://") or export_path.begins_with("user://"):
		export_path = ProjectSettings.globalize_path(export_path)
	var js_path := export_path.get_basename() + ".js"
	_patch_js_file(js_path)


static func patch_source(source: String) -> Dictionary:
	if PATCHED in source:
		return {
			"ok": true,
			"changed": false,
			"source": source,
			"error": "",
		}

	var forced_count := source.count(FORCED)
	if forced_count != 1:
		return {
			"ok": false,
			"changed": false,
			"source": source,
			"error": (
				"expected exactly 1 forcing site, found %d"
				% forced_count
			),
		}
	if COMMIT_OK not in source:
		return {
			"ok": false,
			"changed": false,
			"source": source,
			"error": "commit_frame shape changed — patch would not be safe",
		}

	return {
		"ok": true,
		"changed": true,
		"source": source.replace(FORCED, PATCHED),
		"error": "",
	}


static func is_web_export(features: PackedStringArray) -> bool:
	return features.has("web")


func _patch_js_file(js_path: String) -> void:
	if not FileAccess.file_exists(js_path):
		_report_error("generated JavaScript file is missing: %s" % js_path)
		return

	var input := FileAccess.open(js_path, FileAccess.READ)
	if input == null:
		_report_error(
			"could not read generated JavaScript file %s (error %d)"
			% [js_path, FileAccess.get_open_error()]
		)
		return
	var result := patch_source(input.get_as_text())
	input.close()

	if not result.ok:
		_report_error(
			"%s in %s — glue layout changed, re-inspect before patching"
			% [result.error, js_path]
		)
		return
	if not result.changed:
		print("[Couch Games] Present-path patch already present: %s" % js_path)
		return

	var output := FileAccess.open(js_path, FileAccess.WRITE)
	if output == null:
		_report_error(
			"could not write generated JavaScript file %s (error %d)"
			% [js_path, FileAccess.get_open_error()]
		)
		return
	var wrote_all: bool = output.store_string(result.source)
	output.flush()
	var write_error := output.get_error()
	output.close()
	if not wrote_all or write_error != OK:
		_report_error(
			"failed while writing generated JavaScript file %s (error %d)"
			% [js_path, write_error]
		)
		return

	print("[Couch Games] Patched Web export present path: %s" % js_path)


func _report_error(message: String) -> void:
	var platform := get_export_platform()
	if platform:
		platform.add_message(
			EditorExportPlatform.EXPORT_MESSAGE_ERROR,
			"Couch Games present-path patch",
			message
		)
	push_error("[Couch Games] Present-path patch failed: %s" % message)
