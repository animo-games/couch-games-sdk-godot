## Injectable provider boundary. All identities cross it as opaque decimal strings.
## request_entered carries the SDK generation; implementations must serialize native
## requests whose callbacks lack a request ID, including after caller timeouts.
extends Node
signal request_entered(generation: int, lobby_id: String, error_code: String)
signal roster_changed(lobby_id: String)
signal join_requested(lobby_id: String)
signal peer_requested(peer_id: String)
signal peer_failed(peer_id: String, reason: String)
signal stats_stored(app_id: String, success: bool)
signal connection_changed(connected: bool)
var app_id := ""
var user_id := ""
var initialized := false
func initialize(_app_id: int) -> Dictionary:
	return {"success": false, "error": "Steam bridge unavailable"}
func shutdown() -> void:
	initialized = false
func connected() -> bool:
	return initialized
func poll() -> void:
	pass
func create_lobby(_generation: int, _visibility: String, _max_players: int) -> bool:
	return false
func join_lobby(_generation: int, _id: String) -> bool:
	return false
func leave_lobby(_id: String) -> void:
	pass
func lobby_members(_id: String) -> Array:
	return []
func lobby_owner(_id: String) -> String:
	return ""
func persona_name(_id: String) -> String:
	return ""
func set_metadata(_id: String, _key: String, _value: String) -> bool:
	return false
func metadata(_id: String, _key: String) -> String:
	return ""
func request_metadata(_id: String) -> bool:
	return false
func invite_overlay(_id: String) -> bool:
	return false
func send_reliable(_id: String, _bytes: PackedByteArray) -> bool:
	return false
func receive(_budget: int) -> Array:
	return []
func accept_peer(_id: String) -> bool:
	return false
func close_peer(_id: String) -> void:
	pass
func read_achievement(_name: String) -> Dictionary:
	return {"success": false, "error_code": "unavailable"}
func set_achievement(_name: String) -> bool:
	return false
func store_stats() -> bool:
	return false
