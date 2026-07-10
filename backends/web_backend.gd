# Web backend: bridges to the platform's window.CouchGames global via
# JavaScriptBridge. Active only in web exports running inside the Couch Games
# platform page.
#
# The lobby connection is the PLATFORM's WebSocket, owned by the parent page.
# This backend must never open its own — the server allows one connection per
# userId and would kick the platform's socket (close code 1008).
class_name CouchGamesWebBackend
extends CouchGamesBackend

var _window: JavaScriptObject
var _sdk: JavaScriptObject
var _lobby: JavaScriptObject

# Persistent JS callbacks MUST be held in member vars — a JavaScriptBridge
# callback is garbage-collected as soon as its Godot-side reference dies.
# (_await_promise's local callbacks are fine: the coroutine frame that polls
# `result.completed` keeps them alive for the promise's lifetime.)
var _on_any_event_cb: JavaScriptObject
var _on_players_changed_cb: JavaScriptObject


## True when this export can reach the platform SDK. False for web exports
## hosted outside the platform (itch.io, local http server) — the facade then
## falls back to the mock backend.
static func detect() -> bool:
	if not OS.has_feature("web"):
		return false
	var window := JavaScriptBridge.get_interface("window")
	return window != null and window.CouchGames != null


func is_available() -> bool:
	return _get_sdk() != null


func initialize() -> void:
	# Note: This might be used by the platform to load external assets
	ProjectSettings.load_resource_pack("/tmp/level.pck")
	_window = JavaScriptBridge.get_interface("window")
	if _window:
		_sdk = _window.CouchGames
	if _sdk:
		_lobby = _sdk.lobby
	if _lobby == null:
		push_warning("CouchGames SDK: platform lobby bridge not available")
		return
	if _lobby.onAnyEvent == null or _lobby.onPlayersChanged == null:
		push_error(
			"CouchGames SDK: platform lobby bridge is outdated — deploy a platform "
			+ "build with lobby.onAnyEvent/onPlayersChanged before this game build."
		)
		_lobby = null
		return
	_on_any_event_cb = JavaScriptBridge.create_callback(_on_any_event)
	_on_players_changed_cb = JavaScriptBridge.create_callback(_on_players_changed)
	_lobby.onAnyEvent(_on_any_event_cb)
	# Fires immediately with the current roster on registration.
	_lobby.onPlayersChanged(_on_players_changed_cb)


func load_resource_packs(experience_payload: Dictionary) -> void:
	var files: Variant = experience_payload.get("files", [])
	var names: Array = []
	if files is Dictionary:
		names = files.keys()
	elif files is Array:
		names = files
	for file_name in names:
		ProjectSettings.load_resource_pack("/tmp/" + str(file_name))


func _get_sdk() -> JavaScriptObject:
	if not _sdk:
		if not _window:
			_window = JavaScriptBridge.get_interface("window")
		if _window:
			_sdk = _window.CouchGames
	return _sdk


# ────────────────────────────────────────────────
# Classic SDK verbs
# ────────────────────────────────────────────────

func save_game(save_data: Dictionary, progress: float) -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		push_error("CouchGames SDK: Not available")
		return {"success": false, "error": "SDK not available"}
	var promise = sdk.saveGame(_dict_to_js(save_data), progress)
	return _js_to_dict(await _await_promise(promise))


func load_latest_save() -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	# The SDK returns the save data string or null
	var data = sdk.loadLatestSave()
	if data == null:
		return {"success": true, "payload": {}}
	return {"success": true, "payload": data}


func gameplay_start() -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	return _js_to_dict(await _await_promise(sdk.gameplayStart()))


func gameplay_end() -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	return _js_to_dict(await _await_promise(sdk.gameplayEnd()))


func gameplay_completed() -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	return _js_to_dict(await _await_promise(sdk.gameplayComplete()))


func get_experience_data() -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	return _js_to_dict(await _await_promise(sdk.getExperienceData()))


func get_experience_date() -> Variant:
	var sdk = _get_sdk()
	if sdk:
		return sdk.getExperienceDate()
	return null


func get_game_metadata() -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	return _js_to_dict(sdk.getGameMetadata())


func set_game_metadata(category: String, key: String, value: Variant) -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	return _js_to_dict(await _await_promise(sdk.setGameMetadata(category, key, value)))


func unlock_achievement(key: String) -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	return _js_to_dict(await _await_promise(sdk.unlockAchievement(key)))


func get_achievements() -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	return _js_to_dict(await _await_promise(sdk.getAchievements()))


func get_session_stats() -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	return _js_to_dict(await _await_promise(sdk.getSessionStats()))


# ────────────────────────────────────────────────
# Lobby
# ────────────────────────────────────────────────

func lobby_is_available() -> bool:
	return _lobby != null


func lobby_get_current_game() -> Dictionary:
	if _lobby == null:
		return {}
	return _js_to_dict(_lobby.getCurrentGame())


func lobby_get_players() -> Array:
	if _lobby == null:
		return []
	var players = _js_to_variant(_lobby.getLobbyPlayers())
	return players if players is Array else []


func lobby_get_me() -> Dictionary:
	if _lobby == null:
		return {}
	return _js_to_dict(_lobby.getMe())


func lobby_send_event(event: String, data: Variant, target: Dictionary) -> void:
	if _lobby == null:
		push_warning("CouchGames SDK: lobby not available; event '%s' dropped" % event)
		return
	if target.is_empty():
		_lobby.sendEvent(event, _variant_to_js(data), null)
	else:
		_lobby.sendEvent(event, _variant_to_js(data), _dict_to_js(target))


func _on_any_event(args: Array) -> void:
	# args: [event: String, data: any, senderUserId: String]
	if args.is_empty():
		return
	var event := str(args[0])
	var data: Variant = _js_to_variant(args[1]) if args.size() >= 2 else null
	var sender := ""
	if args.size() >= 3 and args[2] != null:
		sender = str(args[2])
	lobby_event_received.emit(event, data, sender)


func _on_players_changed(args: Array) -> void:
	if args.is_empty():
		return
	var players = _js_to_variant(args[0])
	if players is Array:
		lobby_players_updated.emit(players)


# ────────────────────────────────────────────────
# Helper to await JS Promises
# ────────────────────────────────────────────────

func _await_promise(promise: JavaScriptObject) -> Variant:
	if not promise:
		return null

	var result = {"completed": false, "data": null}

	var on_success = JavaScriptBridge.create_callback(func(args):
		result.data = args[0]
		result.completed = true
	)
	var on_error = JavaScriptBridge.create_callback(func(args):
		result.data = args[0]
		result.completed = true
	)

	promise.then(on_success).catch(on_error)

	while not result.completed:
		await get_tree().process_frame

	return result.data


# ────────────────────────────────────────────────
# Data Conversion Helpers
# ────────────────────────────────────────────────

func _dict_to_js(dict: Dictionary) -> JavaScriptObject:
	var js_obj = JavaScriptBridge.create_object("Object")
	for key in dict.keys():
		var value = dict[key]
		if value is Dictionary:
			js_obj[key] = _dict_to_js(value)
		elif value is Array:
			js_obj[key] = _array_to_js(value)
		else:
			js_obj[key] = value
	return js_obj


func _array_to_js(arr: Array) -> JavaScriptObject:
	var js_arr = JavaScriptBridge.create_object("Array")
	for i in range(arr.size()):
		var value = arr[i]
		if value is Dictionary:
			js_arr[i] = _dict_to_js(value)
		elif value is Array:
			js_arr[i] = _array_to_js(value)
		else:
			js_arr[i] = value
	return js_arr


func _variant_to_js(value: Variant) -> Variant:
	if value is Dictionary:
		return _dict_to_js(value)
	if value is Array:
		return _array_to_js(value)
	return value


func _js_to_variant(js_value: Variant) -> Variant:
	# Scalars cross the bridge as native Variants; only JS objects/arrays need
	# the JSON round-trip (which also makes JSON's usual type degradation —
	# ints arriving as floats — consistent everywhere).
	if typeof(js_value) != TYPE_OBJECT:
		return js_value
	var json = JavaScriptBridge.get_interface("JSON")
	var stringified = json.stringify(js_value)
	if stringified == null:
		return null
	return JSON.parse_string(stringified)


func _js_to_dict(js_obj: Variant) -> Dictionary:
	var parsed = _js_to_variant(js_obj)
	return parsed if parsed is Dictionary else {}
