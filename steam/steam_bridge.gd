## GodotSteam 4.23 GDExtension / Steamworks 1.65. This is the ONLY native API seam.
## Explicit manual callbacks: initialize_on_startup and embed_callbacks must be false.
extends "res://addons/couch-games-sdk/steam/bridge.gd"
const CHANNEL := 73
var _native: Object
var _creating := -1
var _joining := -1
var _joining_id := ""
var _created_id := ""
var _create_entry: Dictionary = {}
var _connections: Array = []
func initialize(requested_app_id: int) -> Dictionary:
	if initialized:
		return {"success": true}
	if OS.has_feature("web") or not Engine.has_singleton("Steam"):
		return {"success": false, "error": "GodotSteam is not installed on this platform"}
	if ProjectSettings.get_setting("steam/initialization/processes/initialize_on_startup", false) or ProjectSettings.get_setting("steam/initialization/processes/embed_callbacks", false):
		return {"success": false, "error": "Disable GodotSteam automatic initialization and embedded callbacks; CouchGames owns both"}
	_native = Engine.get_singleton("Steam")
	for method in ["steamInitEx", "getAppID", "getSteamID", "run_callbacks", "sendMessageToUser", "receiveMessagesOnChannel", "getAchievement", "storeStats", "steamShutdown", "loggedOn", "createLobby", "joinLobby", "leaveLobby", "getNumLobbyMembers", "getLobbyMemberByIndex", "getLobbyOwner", "getFriendPersonaName", "setLobbyData", "getLobbyData", "requestLobbyData", "isOverlayEnabled", "activateGameOverlayInviteDialog", "acceptSessionWithUser", "closeSessionWithUser", "setAchievement"]:
		if not _native.has_method(method):
			return {"success": false, "error": "Incompatible GodotSteam: missing " + method}
	for event in ["lobby_created", "lobby_joined", "lobby_chat_update", "lobby_data_update", "persona_state_change", "join_requested", "network_messages_session_request", "network_messages_session_failed", "user_stats_stored", "steam_server_connected", "steam_server_disconnected"]:
		if not _native.has_signal(event):
			shutdown()
			return {"success": false, "error": "Incompatible GodotSteam: missing signal " + event}
	_link("lobby_created", _on_created)
	_link("lobby_joined", _on_joined)
	_link("lobby_chat_update", func(id, _changed, _actor, _state): roster_changed.emit(str(id)))
	_link("lobby_data_update", func(_success, id, _member): roster_changed.emit(str(id)))
	_link("persona_state_change", func(_id, _flags): roster_changed.emit(""))
	_link("join_requested", func(id, _friend): join_requested.emit(str(id)))
	_link("network_messages_session_request", func(id): peer_requested.emit(str(id)))
	_link("network_messages_session_failed", func(reason, id, _state, message): peer_failed.emit(str(id), "%s: %s" % [reason, message]))
	_link("user_stats_stored", func(game_id, result): stats_stored.emit(str(game_id), result == 1))
	_link("steam_server_connected", func(): connection_changed.emit(true))
	_link("steam_server_disconnected", func(_reason): connection_changed.emit(false))
	var result: Dictionary = _native.call("steamInitEx", requested_app_id, false)
	initialized = int(result.get("status", -1)) == 0
	if initialized:
		app_id = str(_native.call("getAppID"))
		user_id = str(_native.call("getSteamID"))
		if app_id == "0" or user_id == "0":
			shutdown()
			return {"success": false, "error": "Steam did not identify the app/account"}
	if not initialized:
		shutdown()
		return {"success": false, "error": str(result.get("verbal", "Steam initialization failed"))}
	return {"success": true, "error": ""}
func _link(event: String, callback: Callable) -> void:
	_native.connect(event, callback)
	_connections.append([event, callback])
func shutdown() -> void:
	if _native != null:
		for link in _connections:
			if _native.is_connected(link[0], link[1]):
				_native.disconnect(link[0], link[1])
		if initialized:
			_native.call("steamShutdown")
	_connections.clear()
	initialized = false
	_native = null
	_creating = -1
	_joining = -1
	_joining_id = ""
	_created_id = ""
	_create_entry.clear()
	app_id = ""
	user_id = ""
func connected() -> bool:
	return initialized and bool(_native.call("loggedOn"))
func poll() -> void:
	if initialized:
		_native.call("run_callbacks")
func create_lobby(generation: int, visibility: String, max_players: int) -> bool:
	if not initialized or _creating >= 0 or _joining >= 0:
		return false
	_creating = generation
	# ELobbyType: private=0, friends-only=1, public=2.
	_native.call("createLobby", {"private": 0, "friends": 1, "public": 2}[visibility], max_players)
	return true
func join_lobby(generation: int, id: String) -> bool:
	if not initialized or _creating >= 0 or _joining >= 0:
		return false
	_joining = generation
	_joining_id = id
	_native.call("joinLobby", int(id))
	return true
func _on_created(result: int, id: int) -> void:
	if not initialized or _creating < 0:
		return
	if result != 1:
		var generation := _creating
		_creating = -1
		_created_id = ""
		_create_entry.clear()
		request_entered.emit(generation, str(id), "unavailable")
		return
	# createLobby also produces LobbyEnter. Keep the native reservation until
	# BOTH callbacks arrive; otherwise a synchronous listener could join the
	# same lobby and consume the old create's LobbyEnter as a new join result.
	_created_id = str(id)
	_complete_create()
func _complete_create() -> void:
	if _created_id.is_empty() or _create_entry.get("id", "") != _created_id:
		return
	var generation := _creating
	var id := _created_id
	var code: String = _create_entry.code
	_creating = -1
	_created_id = ""
	_create_entry.clear()
	request_entered.emit(generation, id, code)
func _on_joined(id: int, _permissions: int, _locked: bool, response: int) -> void:
	if not initialized:
		return
	var code: String = {1: "", 4: "full", 2: "unavailable", 3: "unavailable"}.get(response, "unavailable")
	if _creating >= 0:
		_create_entry = {"id": str(id), "code": code}
		_complete_create()
		return
	if _joining < 0 or str(id) != _joining_id:
		return
	var generation := _joining
	_joining = -1
	_joining_id = ""
	request_entered.emit(generation, str(id), code)
func leave_lobby(id: String) -> void:
	if initialized and not id.is_empty():
		_native.call("leaveLobby", int(id))
func lobby_members(id: String) -> Array:
	var members := []
	for index in range(int(_native.call("getNumLobbyMembers", int(id)))):
		members.append(str(_native.call("getLobbyMemberByIndex", int(id), index)))
	return members
func lobby_owner(id: String) -> String:
	return str(_native.call("getLobbyOwner", int(id)))
func persona_name(id: String) -> String:
	return str(_native.call("getFriendPersonaName", int(id)))
func set_metadata(id: String, key: String, value: String) -> bool:
	return bool(_native.call("setLobbyData", int(id), key, value))
func metadata(id: String, key: String) -> String:
	return str(_native.call("getLobbyData", int(id), key))
func request_metadata(id: String) -> bool:
	return bool(_native.call("requestLobbyData", int(id)))
func invite_overlay(id: String) -> bool:
	if not initialized or not bool(_native.call("isOverlayEnabled")):
		return false
	_native.call("activateGameOverlayInviteDialog", int(id))
	return true
func send_reliable(id: String, bytes: PackedByteArray) -> bool:
	# k_nSteamNetworkingSend_Reliable = 8. Do not enable AutoRestartBrokenSession:
	# stale gameplay actions must never silently survive a broken link.
	return int(_native.call("sendMessageToUser", int(id), bytes, 8, CHANNEL)) == 1
func receive(budget: int) -> Array:
	var messages := []
	for packet in _native.call("receiveMessagesOnChannel", CHANNEL, budget):
		messages.append({"sender": str(packet.identity), "bytes": packet.payload})
	return messages
func accept_peer(id: String) -> bool:
	return bool(_native.call("acceptSessionWithUser", int(id)))
func close_peer(id: String) -> void:
	if initialized:
		_native.call("closeSessionWithUser", int(id))
func read_achievement(api_name: String) -> Dictionary:
	if not initialized:
		return {"success": false, "error_code": "unavailable"}
	var value: Dictionary = _native.call("getAchievement", api_name)
	return {"success": bool(value.get("ret", false)), "unlocked": bool(value.get("achieved", false)), "error_code": "definition-or-read-failed"}
func set_achievement(api_name: String) -> bool:
	return initialized and bool(_native.call("setAchievement", api_name))
func store_stats() -> bool:
	return initialized and bool(_native.call("storeStats"))
