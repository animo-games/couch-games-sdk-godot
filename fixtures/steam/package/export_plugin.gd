@tool
extends EditorPlugin
const Filter := preload("res://addons/couch-games-sdk/editor/steam_export_plugin.gd")
var _filter: EditorExportPlugin
func _enter_tree() -> void:
	_filter = Filter.new()
	add_export_plugin(_filter)
func _exit_tree() -> void:
	remove_export_plugin(_filter)
