# couchgames.gd
# Autoload singleton for CouchGames SDK
# Communicates with parent window via postMessage (Web export only)

extends Node

# ────────────────────────────────────────────────
# Private
# ────────────────────────────────────────────────

var _request_callbacks: Dictionary = {} # request_id -> Callable
var _is_web: bool = OS.has_feature("web")
var window: JavaScriptObject

var _callback_ref = JavaScriptBridge.create_callback(_on_received_message)

# ────────────────────────────────────────────────
# Setup
# ────────────────────────────────────────────────

func init() -> void:
	if _is_web:
		window = JavaScriptBridge.get_interface("window");
		_setup_message_listener()

func _setup_message_listener() -> void:
	# Create a callback that JavaScript can call
	# var godot_callback = JavaScriptBridge.create_callback(self._on_parent_response.bind())
	window.addEventListener("message", _callback_ref);
  # Set up the JavaScript listener and pass the callback

func mock_load() -> Dictionary:
	print("Mock load")
	await get_tree().process_frame
	return {1: {"character_idx": 0.0, "inventory.enabled_items": [1.0, 2.0], "spawn_scene_path": "", "spawner_path": "Level/InteractableProps/SpawnPoint"}, 2: {"character_idx": 1.0, "inventory.enabled_items": [1.0, 2.0], "spawn_scene_path": "", "spawner_path": "Level/InteractableProps/SpawnPoint"}, 4783139376069951111: {"is_on": true}}

func _on_received_message(args: Array):
	var event = args[0]
	if event.origin != window.location.origin:
		return

	if not event.data.couchgamesResponse:
		return

	var request_id = event.data.requestId
	var response = event.data.response
	var response_dict: Dictionary = {
		"success": response.success,
		"message": response.message,
		"payload": response.payload,
		"error": response.error if response.error else ""
	}
	_request_callbacks[request_id] = response_dict
	# _on_parent_response(request_id, response_dict)


# func _on_parent_response(request_id: String, response: Dictionary) -> void:
# 	if _request_callbacks.has(request_id):
# 		var callback = _request_callbacks[request_id]
# 		callback.call(response)
# 		_request_callbacks.erase(request_id)


# ────────────────────────────────────────────────
# Core send function
# ────────────────────────────────────────────────

func _send(type: String, payload: Dictionary = {}) -> String:
	if not _is_web:
		push_error("CouchGames SDK: postMessage only works in Web export")
		return ""

	var request_id = str(randi()) + "_" + str(Time.get_ticks_msec())

	var message = {
		"couchgames": true,
		"type": type,
		"payload": payload,
		"requestId": request_id
	}

	var json = JSON.stringify(message)

	JavaScriptBridge.eval("window.parent.postMessage(%s, '*');" % json, true)
	_request_callbacks

	return request_id


# ────────────────────────────────────────────────
# Public API
# ────────────────────────────────────────────────

func save_game(save_data: Dictionary) -> CouchGamesSDKResponse:
	var request_id = _send("saveGame", {
		"saveData": save_data
	})

	var response := await _wait_for_response(request_id)
	return response

func load_latest_save() -> CouchGamesSDKResponse:
	var request_id = _send("loadLatestSave")

	var response := await _wait_for_response(request_id)
	return response


func gameplay_start():
	var request_id = _send("gameplayStart")

	var response := await _wait_for_response(request_id)
	if response.success:
		print("Gameplay started")
	else:
		printerr("Gameplay start failed: ", response.error)

func gameplay_end():
	var request_id = _send("gameplayEnd")

	_request_callbacks[request_id] = func(response: Dictionary):
		if response.get("success", false):
			print("Gameplay ended")
		else:
			printerr("Gameplay end failed: ", response.get("error", "Unknown error"))

# Helper to wait for a specific request ID
func _wait_for_response(request_id: String) -> CouchGamesSDKResponse:
	var start_time = Time.get_ticks_msec()
	while true:
		await get_tree().process_frame # wait one frame
		if _request_callbacks.has(request_id):
			var response = _request_callbacks[request_id]
			_request_callbacks.erase(request_id)
			return CouchGamesSDKResponse.from_dict(response)

		if Time.get_ticks_msec() - start_time > 10000:
			push_error("Load timeout")
			return CouchGamesSDKResponse.from_dict({"success": false, "error": "Timeout"})

	return CouchGamesSDKResponse.from_dict({"success": false, "error": "Unknown error"})
