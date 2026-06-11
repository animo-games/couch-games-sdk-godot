# couch_games_sdk.gd
# Autoload singleton for CouchGames SDK
# Communicates with parent window via direct calls to window.CouchGames (Web export only)

extends Node

# ────────────────────────────────────────────────
# Private
# ────────────────────────────────────────────────

var _is_web: bool = OS.has_feature("web")
var _window: JavaScriptObject
var _sdk: JavaScriptObject

# ------------------------------------------------
# Public
# ------------------------------------------------

var is_available: bool:
	get:
		return _is_web and _get_sdk() != null

var experience_data: Dictionary
# ────────────────────────────────────────────────
# Setup
# ────────────────────────────────────────────────

func init() -> void:
	if _is_web:
		# Note: This might be used by the platform to load external assets
		ProjectSettings.load_resource_pack("/tmp/level.pck")
		_window = JavaScriptBridge.get_interface("window")
		if _window:
			_sdk = _window.CouchGames

		var data := await get_experience_data()
		if data.success and data.payload:
			experience_data = data.payload
			var files = data.payload.get("files", [])
			for file_name in files.keys():
				ProjectSettings.load_resource_pack("/tmp/" + file_name)

func _get_sdk() -> JavaScriptObject:
	if not _is_web:
		return null
	if not _sdk:
		if _window:
			_sdk = _window.CouchGames
	return _sdk

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
# Public API
# ────────────────────────────────────────────────

func save_game(save_data: Dictionary, progress: float = 0.0) -> CouchGamesSDKResponse:
	var sdk = _get_sdk()
	if not sdk:
		push_error("CouchGames SDK: Not available")
		return CouchGamesSDKResponse.from_dict({"success": false, "error": "SDK not available"})

	var js_save_data = _dict_to_js(save_data)
	var promise = sdk.saveGame(js_save_data, progress)

	var response_data = await _await_promise(promise)
	return CouchGamesSDKResponse.from_dict(_js_to_dict(response_data))

func load_latest_save() -> CouchGamesSDKResponse:
	var sdk = _get_sdk()
	if not sdk:
		return CouchGamesSDKResponse.from_dict({"success": false, "error": "SDK not available"})

	var data = sdk.loadLatestSave()
	if data == null:
		return CouchGamesSDKResponse.from_dict({"success": true, "payload": {}})

	# The SDK returns the save data string or null
	return CouchGamesSDKResponse.from_dict({"success": true, "payload": data})

func gameplay_start() -> void:
	var sdk = _get_sdk()
	if sdk:
		await _await_promise(sdk.gameplayStart())

func gameplay_end() -> void:
	var sdk = _get_sdk()
	if sdk:
		await _await_promise(sdk.gameplayEnd())

func gameplay_completed() -> void:
	var sdk = _get_sdk()
	if sdk:
		await _await_promise(sdk.gameplayComplete())

func get_experience_date() -> Variant:
	var sdk = _get_sdk()
	if sdk:
		return sdk.getExperienceDate()
	return null

func get_experience_data() -> CouchGamesSDKResponse:
	var sdk = _get_sdk()
	if not sdk:
		return CouchGamesSDKResponse.from_dict({"success": false, "error": "SDK not available"})

	var promise = sdk.getExperienceData()
	var response_data = await _await_promise(promise)
	return CouchGamesSDKResponse.from_dict(_js_to_dict(response_data))

func get_game_metadata() -> CouchGamesSDKResponse:
	var sdk = _get_sdk()
	if not sdk:
		return CouchGamesSDKResponse.from_dict({"success": false, "error": "SDK not available"})

	var response_data = sdk.getGameMetadata()
	return CouchGamesSDKResponse.from_dict(_js_to_dict(response_data))

func set_game_metadata(category: String, key: String, value: Variant) -> CouchGamesSDKResponse:
	var sdk = _get_sdk()
	if not sdk:
		return CouchGamesSDKResponse.from_dict({"success": false, "error": "SDK not available"})

	var promise = sdk.setGameMetadata(category, key, value)
	var response_data = await _await_promise(promise)
	return CouchGamesSDKResponse.from_dict(_js_to_dict(response_data))

func unlock_achievement(key: String) -> CouchGamesSDKResponse:
	var sdk = _get_sdk()
	if not sdk:
		return CouchGamesSDKResponse.from_dict({"success": false, "error": "SDK not available"})

	var promise = sdk.unlockAchievement(key)
	var response_data = await _await_promise(promise)
	return CouchGamesSDKResponse.from_dict(_js_to_dict(response_data))

func get_achievements() -> CouchGamesSDKResponse:
	var sdk = _get_sdk()
	if not sdk:
		return CouchGamesSDKResponse.from_dict({"success": false, "error": "SDK not available"})

	var promise = sdk.getAchievements()
	var response_data = await _await_promise(promise)
	return CouchGamesSDKResponse.from_dict(_js_to_dict(response_data))

func get_session_stats() -> CouchGamesSDKResponse:
	var sdk = _get_sdk()
	if not sdk:
		return CouchGamesSDKResponse.from_dict({"success": false, "error": "SDK not available"})

	var promise = sdk.getSessionStats()
	var response_data = await _await_promise(promise)
	return CouchGamesSDKResponse.from_dict(_js_to_dict(response_data))

func get_url(experienceId: String = "") -> String:
	if OS.has_feature("web"):
		return experience_data.experienceUrl
	else:
		return ""

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

func _js_to_dict(js_obj: Variant) -> Dictionary:
	if typeof(js_obj) != TYPE_OBJECT or js_obj == null:
		return {}

	var json = JavaScriptBridge.get_interface("JSON")
	var stringified = json.stringify(js_obj)
	var parsed = JSON.parse_string(stringified)
	return parsed if parsed is Dictionary else {}

# Legacy mock
func mock_load() -> Dictionary:
	print("Mock load")
	await get_tree().process_frame
	return {1: {"character_idx": 0.0, "inventory.enabled_items": [1.0, 2.0], "spawn_scene_path": "", "spawner_path": "Level/InteractableProps/SpawnPoint"}, 2: {"character_idx": 1.0, "inventory.enabled_items": [1.0, 2.0], "spawn_scene_path": "", "spawner_path": "Level/InteractableProps/SpawnPoint"}, 4783139376069951111: {"is_on": true}}
