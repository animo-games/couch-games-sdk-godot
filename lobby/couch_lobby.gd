# Multiplayer lobby abstraction, exposed as `CouchGames.lobby`.
#
# Push-driven: the backend emits roster and tunnel-event updates (from the
# platform bridge on web, from the local simulation in mock) and this node
# turns them into typed Godot signals. Game code never touches the transport.
class_name CouchLobby
extends Node

## A tunnel event from another client in the session. You never receive your
## own send_event back (server semantics) — apply local effects at send time.
signal event_received(event: String, data: Variant, sender_user_id: String)
## The full new roster after any membership/status/slot change. Ping-only
## changes don't fire. players: Array[CouchLobbyPlayer]
signal players_changed(players: Array)
signal player_joined(player: CouchLobbyPlayer)
signal player_left(player: CouchLobbyPlayer)

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
	if _backend == null:
		return
	_backend.lobby_send_event(event, data, _normalize_target(target))


## Re-fetch the roster from the backend immediately. Normally unnecessary —
## updates are pushed — but useful right after awaiting CouchGames.init().
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

	# Per-player signals fire before the aggregate one so players_changed
	# handlers observe the final roster.
	for player in joined:
		player_joined.emit(player)
	for player in left:
		player_left.emit(player)
	if changed:
		players_changed.emit(get_players())
