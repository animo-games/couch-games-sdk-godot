## Duck-typed CouchSession roster double for the transport/session fixture corpus.
##
## Holds a flat array of PLATFORM-shaped player dictionaries (camelCase keys:
## userId/username/role/controllerSlot -- the shape the fixture's `roster` and
## `roster` step's `players` fields use) and exposes them through the surface
## CouchSession._implements_roster requires (get_players/get_me/get_host/
## get_guests/is_host), translated into the snake_case field shape
## CouchSession._field_string/_field_int actually read (user_id/username/
## controller_slot). Nothing here references anything outside netcode/ -- no
## CouchLobbyPlayer, no CouchLobby; this file must parse in a project that
## installs neither.
class_name CouchScriptedRoster
extends RefCounted

## Re-emitted on set_players(), matching the real CouchLobby's signal shape.
## CouchSession does not subscribe to this itself -- the caller (the game, or
## this corpus's runner) drives evaluate()/poll() explicitly on a roster
## change -- but it is wired up for parity with the real lobby surface.
signal players_changed(players: Array)

## Read via `.get("is_available")` by CouchSession, exactly like the real
## CouchLobby's computed property (see couch_session.gd evaluate()).
var is_available: bool = true

var _local_user_id: String = ""
var _players: Array = []   # Array[Dictionary], snake_case shape


func _init(local_user_id: String, players: Array = []) -> void:
	_local_user_id = local_user_id
	_players = _translate(players)


## Replace the roster wholesale -- what a fixture `roster` step drives.
func set_players(players: Array) -> void:
	_players = _translate(players)
	players_changed.emit(_players.duplicate())


func get_players() -> Array:
	return _players.duplicate()


func get_me() -> Variant:
	return _find(_local_user_id)


func get_host() -> Variant:
	for player in _players:
		if player.get("role", "") == "host":
			return player
	return null


func get_guests() -> Array:
	var guests: Array = []
	for player in _players:
		if player.get("role", "") == "guest":
			guests.append(player)
	return guests


func is_host() -> bool:
	var me: Variant = get_me()
	if me == null:
		return false
	return (me as Dictionary).get("role", "") == "host"


func _find(user_id: String) -> Variant:
	for player in _players:
		if player.get("user_id", "") == user_id:
			return player
	return null


## Translates the fixture's platform-shaped (camelCase) player dictionaries into
## the snake_case shape CouchSession._field_string/_field_int read.
static func _translate(players: Array) -> Array:
	var translated: Array = []
	for entry in players:
		var d: Dictionary = entry
		translated.append({
			"user_id": str(d.get("userId", "")),
			"username": str(d.get("username", "")),
			"role": str(d.get("role", "")),
			"controller_slot": int(d.get("controllerSlot", -1)),
		})
	return translated
