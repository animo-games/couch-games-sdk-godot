@tool
extends EditorExportPlugin
var _web := false
func _get_name() -> String:
	return "CouchGamesOptionalSteam"
func _export_begin(features: PackedStringArray, _debug: bool, _path: String, _flags: int) -> void:
	_web = features.has("web")
func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if _web and excludes_from_web(path):
		skip()
static func excludes_from_web(path: String) -> bool:
	return path.begins_with("res://addons/godotsteam/") or path.begins_with("res://addons/couch-games-sdk/steam/") or path == "res://addons/couch-games-sdk/backends/steam_backend.gd"
