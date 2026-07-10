# Abstract base for CouchGames SDK backends. The facade autoload
# (couch_games_sdk.gd) delegates every SDK verb here; concrete implementations
# are CouchGamesWebBackend (the real platform bridge, web exports only) and
# CouchGamesMockBackend (local simulation for the editor and standalone runs).
#
# Classic verbs return raw response Dictionaries in the platform's shape
# ({success, error?, payload?, metadata?}); the facade wraps them into
# CouchGamesSDKResponse. Lobby data uses the platform's key style (userId,
# username, role, status, experienceId, controllerSlot, ping) — CouchLobby
# converts to typed CouchLobbyPlayer objects.
class_name CouchGamesBackend
extends Node

## A lobby tunnel event addressed to the local player.
signal lobby_event_received(event: String, data: Variant, sender_user_id: String)
## The lobby roster changed. `players` is an Array of raw player Dictionaries.
signal lobby_players_updated(players: Array)


func is_available() -> bool:
	return false


func is_mock() -> bool:
	return false


func initialize() -> void:
	pass


func load_resource_packs(_experience_payload: Dictionary) -> void:
	pass


# ────────────────────────────────────────────────
# Classic SDK verbs
# ────────────────────────────────────────────────

func save_game(_save_data: Dictionary, _progress: float) -> Dictionary:
	return _not_implemented()


func load_latest_save() -> Dictionary:
	return _not_implemented()


func gameplay_start() -> Dictionary:
	return _not_implemented()


func gameplay_end() -> Dictionary:
	return _not_implemented()


func gameplay_completed() -> Dictionary:
	return _not_implemented()


func get_experience_data() -> Dictionary:
	return _not_implemented()


func get_experience_date() -> Variant:
	return null


func get_game_metadata() -> Dictionary:
	return _not_implemented()


func set_game_metadata(_category: String, _key: String, _value: Variant) -> Dictionary:
	return _not_implemented()


func unlock_achievement(_key: String) -> Dictionary:
	return _not_implemented()


func get_achievements() -> Dictionary:
	return _not_implemented()


func get_session_stats() -> Dictionary:
	return _not_implemented()


# ────────────────────────────────────────────────
# Lobby
# ────────────────────────────────────────────────

func lobby_is_available() -> bool:
	return false


func lobby_get_current_game() -> Dictionary:
	return {}


func lobby_get_players() -> Array:
	return []


func lobby_get_me() -> Dictionary:
	return {}


func lobby_send_event(_event: String, _data: Variant, _target: Dictionary) -> void:
	pass


func _not_implemented() -> Dictionary:
	return {"success": false, "error": "Not implemented"}
