@tool
extends EditorPlugin

# name, default, type, hint, hint_string
const _SETTINGS := [
	["couch_games/mock/force_mock", false, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	["couch_games/mock/enable_debug_overlay", true, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	["couch_games/mock/overlay_toggle_key", KEY_F10, TYPE_INT, PROPERTY_HINT_NONE, ""],
	["couch_games/mock/latency_ms", 0, TYPE_INT, PROPERTY_HINT_RANGE, "0,2000,10"],
	["couch_games/mock/local_username", "Player 1", TYPE_STRING, PROPERTY_HINT_NONE, ""],
	["couch_games/mock/experience_name", "", TYPE_STRING, PROPERTY_HINT_NONE, ""],
	["couch_games/mock/experience_url", "https://couch.games/mock", TYPE_STRING, PROPERTY_HINT_NONE, ""],
	["couch_games/local/enabled", true, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	["couch_games/local/port", 8974, TYPE_INT, PROPERTY_HINT_RANGE, "1024,65535,1"],
]


func _enter_tree():
	for setting in _SETTINGS:
		_define_setting(setting[0], setting[1], setting[2], setting[3], setting[4])
	add_autoload_singleton("CouchGames", "./couch_games_sdk.gd")


func _exit_tree():
	remove_autoload_singleton("CouchGames")


# Registers a project setting with its default, without overwriting a value
# the user already changed. The runtime reads these with the same defaults, so
# exports work even if the plugin never ran.
func _define_setting(name: String, default_value: Variant, type: int, hint: int, hint_string: String) -> void:
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, default_value)
	ProjectSettings.set_initial_value(name, default_value)
	ProjectSettings.add_property_info({
		"name": name,
		"type": type,
		"hint": hint,
		"hint_string": hint_string,
	})
