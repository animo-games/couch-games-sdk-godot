## A deterministic provider simulator, not proof of Steam connectivity/storage.
extends "res://addons/couch-games-sdk/steam/bridge.gd"
var hub: Dictionary = {"lobbies": {}, "peers": {}, "next_id": 1000}
var hold_membership := false
var requests: Array = []
var left: Array = []
var closed_peers: Array = []
var accepted_peers: Array = []
var sends: Array = []
var packets: Array = []
var send_ok := true
var store_ok := true
var online := true
var read_ok := true
var overlay_ok := true
var auto_store_callback := false
var store_calls := 0
var set_calls := 0
var initialization_calls := 0
var shutdown_calls := 0
var definitions: Dictionary = {"ACH_A": false, "ACH_B": false}
var init_ok := true

func _init() -> void:
	app_id = "123"
	user_id = "76561198000000001"
func initialize(_id: int) -> Dictionary:
	initialization_calls += 1
	initialized = init_ok
	hub.peers[user_id] = self
	return {"success": initialized, "error": "fake initialization failed" if not initialized else ""}
func shutdown() -> void:
	shutdown_calls += 1
	hub.peers.erase(user_id)
	initialized = false
func connected() -> bool:
	return initialized and online
func create_lobby(generation: int, _visibility: String, maximum: int) -> bool:
	hub.next_id += 1
	var id := str(hub.next_id)
	hub.lobbies[id] = {"owner": user_id, "members": [user_id], "metadata": {}, "maximum": maximum}
	requests.append({"generation": generation, "id": id, "code": ""})
	if not hold_membership: complete_next.call_deferred()
	return true
func join_lobby(generation: int, id: String) -> bool:
	var code := ""
	if not hub.lobbies.has(id): code = "unavailable"
	elif hub.lobbies[id].members.size() >= hub.lobbies[id].maximum: code = "full"
	else: hub.lobbies[id].members.append(user_id)
	requests.append({"generation": generation, "id": id, "code": code})
	if not hold_membership: complete_next.call_deferred()
	return true
func complete_next() -> void:
	if requests.is_empty(): return
	var request: Dictionary = requests.pop_front()
	request_entered.emit(request.generation, request.id, request.code)
	if hub.lobbies.has(request.id): notify_roster(request.id)
func notify_roster(id: String) -> void:
	for peer in hub.peers.values(): peer.roster_changed.emit(id)
func leave_lobby(id: String) -> void:
	left.append(id)
	if hub.lobbies.has(id):
		hub.lobbies[id].members.erase(user_id)
		notify_roster.call_deferred(id)
func lobby_members(id: String) -> Array:
	return hub.lobbies[id].members.duplicate() if hub.lobbies.has(id) else []
func lobby_owner(id: String) -> String:
	return hub.lobbies[id].owner if hub.lobbies.has(id) else ""
func persona_name(id: String) -> String:
	return "Player " + id.right(2)
func set_metadata(id: String, key: String, value: String) -> bool:
	hub.lobbies[id].metadata[key] = value
	return true
func metadata(id: String, key: String) -> String:
	return hub.lobbies[id].metadata.get(key, "") if hub.lobbies.has(id) else ""
func request_metadata(_id: String) -> bool:
	return true
func invite_overlay(_id: String) -> bool:
	return overlay_ok
func send_reliable(id: String, bytes: PackedByteArray) -> bool:
	sends.append({"peer": id, "bytes": bytes})
	if not send_ok: return false
	if hub.peers.has(id): hub.peers[id].packets.append({"sender": user_id, "bytes": bytes})
	return true
func receive(budget: int) -> Array:
	var received := []
	for index in range(mini(budget, packets.size())): received.append(packets.pop_front())
	return received
func accept_peer(id: String) -> bool:
	accepted_peers.append(id)
	return true
func close_peer(id: String) -> void:
	closed_peers.append(id)
	# Queued packets from a broken link are discarded before a fresh handshake.
	packets = packets.filter(func(packet): return packet.sender != id)
func read_achievement(api_name: String) -> Dictionary:
	return {"success": read_ok and definitions.has(api_name), "unlocked": definitions.get(api_name, false), "error_code": "definition-or-read-failed"}
func set_achievement(api_name: String) -> bool:
	set_calls += 1
	if not definitions.has(api_name): return false
	definitions[api_name] = true
	return true
func store_stats() -> bool:
	store_calls += 1
	if store_ok and auto_store_callback:
		stats_stored.emit.call_deferred(app_id, true)
	return store_ok
