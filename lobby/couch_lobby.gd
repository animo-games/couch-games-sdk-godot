# Multiplayer lobby abstraction, exposed as `CouchGames.lobby`.
#
# Push-driven: the backend emits roster and tunnel-event updates (from the
# platform bridge on web, from the local simulation in mock) and this node turns
# them into typed Godot signals, so game code never touches the transport.
class_name CouchLobby
extends Node
const _JSONValue := preload("res://addons/couch-games-sdk/core/json_value.gd")

## A tunnel event from another client in the session. You never receive your
## own send_event back (server semantics), so apply local effects at send time.
signal event_received(event: String, data: Variant, sender_user_id: String)
## The full new roster after any membership/status/slot change. Ping-only
## changes don't fire. players: Array[CouchLobbyPlayer]
signal players_changed(players: Array)
signal player_joined(player: CouchLobbyPlayer)
signal player_left(player: CouchLobbyPlayer)

signal state_changed(state: String)
signal join_requested(lobby_id: String)
signal operation_failed(code: String, message: String)
signal event_send_failed(code: String, message: String, peer_id: String)
signal transport_gap(peer_id: String, reason: String)
var state := "idle"
var lobby_id := ""

var is_available: bool:
	get:
		return _backend != null and _backend.lobby_is_available()

var _backend: CouchGamesBackend
var _players: Array[CouchLobbyPlayer] = []


## Called by the CouchGames autoload during setup.
func setup(backend: CouchGamesBackend) -> void:
	_backend = backend
	_backend.lobby_event_received.connect(_on_backend_event)
	_backend.lobby_players_updated.connect(_on_roster)
	_backend.lobby_state_changed.connect(_on_state)
	_backend.lobby_join_requested.connect(join_requested.emit)
	_backend.lobby_operation_failed.connect(operation_failed.emit)
	_backend.event_send_failed.connect(event_send_failed.emit)
	_backend.transport_gap.connect(transport_gap.emit)


func get_players() -> Array[CouchLobbyPlayer]:
	return _players.duplicate()


func get_player(user_id: String) -> CouchLobbyPlayer:
	for player in _players:
		if player.user_id == user_id:
			return player
	return null


func get_host() -> CouchLobbyPlayer:
	for player in _players:
		if player.is_host:
			return player
	return null


func get_guests() -> Array[CouchLobbyPlayer]:
	var guests: Array[CouchLobbyPlayer] = []
	for player in _players:
		if not player.is_host:
			guests.append(player)
	return guests


## The local player, or null when no lobby is active. Prefers the live roster
## entry (which carries username/status/slot) over the identity-only fallback.
func get_me() -> CouchLobbyPlayer:
	if _backend == null:
		return null
	var me: Dictionary = _backend.lobby_get_me()
	var user_id = me.get("userId")
	if user_id == null or str(user_id).is_empty():
		return null
	var from_roster := get_player(str(user_id))
	if from_roster != null:
		return from_roster
	return CouchLobbyPlayer.from_dict(me)


## True when the local player hosts the session (always true in mock).
func is_host() -> bool:
	var me := get_me()
	return me != null and me.is_host


## {"game_id": ..., "experience_id": ...} for the lobby's current game, or {}.
func get_current_game() -> Dictionary:
	if _backend == null:
		return {}
	var game: Dictionary = _backend.lobby_get_current_game()
	if game.is_empty():
		return {}
	return {
		"game_id": game.get("gameId"),
		"experience_id": game.get("experienceId"),
	}


## Send a named event with a JSON-serializable payload through the lobby
## tunnel. Without `target` it reaches every OTHER client in the session;
## {"user_id": ...} and/or {"role": "host"|"guest"} narrow delivery (conditions
## AND together). You will not receive your own event back.
func send_event(event: String, data: Variant = null, target: Dictionary = {}) -> void:
	try_send_event(event, data, target)


## Re-fetch the roster from the backend immediately. Rarely needed, since
## updates are pushed, but useful right after awaiting CouchGames.init().
func refresh_players() -> void:
	if _backend == null:
		return
	_on_roster(_backend.lobby_get_players())


func _normalize_target(target: Dictionary) -> Dictionary:
	# Accept idiomatic snake_case from GDScript callers; the wire format (and
	# the mock, which mirrors it) uses the platform's camelCase keys.
	var normalized := {}
	if target.has("user_id"):
		normalized["userId"] = target["user_id"]
	elif target.has("userId"):
		normalized["userId"] = target["userId"]
	if target.has("role"):
		normalized["role"] = target["role"]
	return normalized


func _on_backend_event(event: String, data: Variant, sender_user_id: String) -> void:
	event_received.emit(event, data, sender_user_id)


func _on_roster(raw_players: Array) -> void:
	var new_players: Array[CouchLobbyPlayer] = []
	for entry in raw_players:
		if entry is Dictionary:
			new_players.append(CouchLobbyPlayer.from_dict(entry))

	var old_by_id := {}
	for player in _players:
		old_by_id[player.user_id] = player
	var new_ids := {}
	for player in new_players:
		new_ids[player.user_id] = true

	var joined: Array[CouchLobbyPlayer] = []
	var changed := false
	for player in new_players:
		var old: CouchLobbyPlayer = old_by_id.get(player.user_id)
		if old == null:
			joined.append(player)
			changed = true
		elif not player.roster_equals(old):
			changed = true

	var left: Array[CouchLobbyPlayer] = []
	for player in _players:
		if not new_ids.has(player.user_id):
			left.append(player)
			changed = true

	_players = new_players
	if not _backend.has_method("achievement_adapter"):
		var legacy_state := "joined" if not _players.is_empty() and is_available else "idle"
		if state != legacy_state:
			state = legacy_state
			state_changed.emit(state)

	# Per-player signals fire before the aggregate one so players_changed
	# handlers observe the final roster.
	for player in joined:
		player_joined.emit(player)
	for player in left:
		player_left.emit(player)
	if changed:
		players_changed.emit(get_players())


func try_send_event(event: String, data: Variant = null, target: Dictionary = {}) -> bool:
	if _backend == null:
		return false
	if event.is_empty() or not _JSONValue.compatible(data):
		event_send_failed.emit("invalid-payload", "Event and payload must be JSON-compatible", "")
		return false
	var normalized := _normalize_target(target)
	if (normalized.has("role") and normalized.role not in ["host", "guest"]) or (normalized.has("userId") and not normalized.userId is String):
		event_send_failed.emit("invalid-target", "Invalid user or role filter", "")
		return false
	return _backend.lobby_try_send_event(event, data, normalized)

func host(options: Dictionary = {}) -> CouchGamesSDKResponse:
	return CouchGamesSDKResponse.from_dict(await _backend.lobby_host(options))

func join(id: String) -> CouchGamesSDKResponse:
	return CouchGamesSDKResponse.from_dict(await _backend.lobby_join(id))

func leave() -> void:
	if _backend != null:
		_backend.lobby_leave()

func open_invite_overlay() -> CouchGamesSDKResponse:
	return CouchGamesSDKResponse.from_dict(await _backend.lobby_open_invite_overlay())

func _on_state(value: String, id: String) -> void:
	state = value
	lobby_id = id
	state_changed.emit(state)

func get_backend_name() -> String:
	return "steam" if _backend != null and _backend.has_method("achievement_adapter") else ""

func consume_join_request() -> String:
	return _backend.consume_join_request() if _backend != null and _backend.has_method("consume_join_request") else ""
