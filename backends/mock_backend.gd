# Mock backend: a full local simulation of the CouchGames platform so games
# are testable in the editor (and any non-platform build) without changes.
#
# - Classic verbs persist to user://couch_games_mock/*.json.
# - The lobby starts with the local player as host; fake guests are added via
#   add_guest() or the debug overlay.
# - Tunnel routing mirrors the real server (signaling-object): an event is
#   NEVER delivered back to its sender, and a target's userId/role conditions
#   AND together.
# - Every payload crosses a JSON round-trip so type fidelity matches the web
#   bridge exactly (ints become floats, callers get copies).
class_name CouchGamesMockBackend
extends CouchGamesBackend

const SAVE_DIR := "user://couch_games_mock/"
const LOCAL_USER_ID := "mock-local-host"

const _LATENCY_SETTING := "couch_games/mock/latency_ms"
const _USERNAME_SETTING := "couch_games/mock/local_username"
const _EXPERIENCE_NAME_SETTING := "couch_games/mock/experience_name"
const _EXPERIENCE_URL_SETTING := "couch_games/mock/experience_url"

## Every tunnel delivery attempt (both directions), for the debug overlay log.
## entry = {direction: "in"|"out", event, data, sender_user_id, target,
##          delivered_to: Array[String], time}
signal mock_event_logged(entry: Dictionary)

## Artificial delay applied to every awaited verb, to shake out timing
## assumptions. 0 still suspends one frame for web await-parity.
var latency_ms: int = 0

## The local player's identity. The local-relay backend overrides these on
## guest instances; all routing below goes through them, never the const.
var local_user_id: String = LOCAL_USER_ID
var local_role: String = "host"

var _players: Array = []  # raw dicts, platform key style
var _next_guest_index: int = 1
var _gameplay_started_at_ms: int = -1
var _save: Dictionary = {}
var _session_stats: Dictionary = {"cumulativeGameplayTimeMs": 0.0, "gameplayCompleted": false}
var _metadata: Dictionary = {}
var _achievements: Dictionary = {}  # key -> {"unlockedAt": iso}


func is_available() -> bool:
	return true


func is_mock() -> bool:
	return true


func initialize() -> void:
	latency_ms = int(ProjectSettings.get_setting(_LATENCY_SETTING, 0))
	_load_persisted()
	_seed_local_player()
	# Deferred so a subscriber connected right after CouchGames.init() still
	# receives it, mirroring the platform's fire-on-registration semantics.
	if not multiplayer_get_play_mode().is_empty():
		_emit_play_mode_selected.call_deferred()


## Resets the roster to just the local player. Reused by the local-relay
## backend when its role/identity changes.
func _seed_local_player() -> void:
	var username := str(ProjectSettings.get_setting(_USERNAME_SETTING, "Player 1"))
	_players = [{
		"userId": local_user_id,
		"username": username,
		"role": local_role,
		"status": "lobby",
		"experienceId": null,
		"controllerSlot": 0 if local_role == "host" else null,
		"ping": 12,
	}]
	_emit_players()


## Human-readable transport state, shown in the debug overlay.
func get_network_status() -> String:
	return "offline mock"


# ────────────────────────────────────────────────
# Mock-control API (used by tests and the debug overlay)
# ────────────────────────────────────────────────

## Adds a fake guest and returns its generated user id ("mock-guest-<n>").
func add_guest(username: String = "") -> String:
	var user_id := "mock-guest-%d" % _next_guest_index
	if username.is_empty():
		username = "Guest %d" % _next_guest_index
	_next_guest_index += 1
	_players.append({
		"userId": user_id,
		"username": username,
		"role": "guest",
		"status": "lobby",
		"experienceId": null,
		"controllerSlot": _lowest_free_slot(),
		"ping": 38,
	})
	_emit_players()
	return user_id


func remove_player(user_id: String) -> void:
	if user_id == local_user_id:
		push_warning("CouchGames mock: the local player can't be removed")
		return
	for i in _players.size():
		if _players[i].get("userId") == user_id:
			_players.remove_at(i)
			_emit_players()
			return


func set_player_status(user_id: String, status: String) -> void:
	for player in _players:
		if player.get("userId") == user_id:
			player["status"] = status
			_emit_players()
			return


func get_mock_players() -> Array:
	return _players.duplicate(true)


## Delivers an event as if `sender_user_id` (a fake player) sent it over the
## tunnel, with server-faithful routing. If the local player is a recipient,
## lobby_event_received is emitted (after the latency tick).
func simulate_event(event: String, data: Variant, sender_user_id: String, target: Dictionary = {}) -> void:
	var payload: Variant = _round_trip(data)
	var delivered: Array = []
	var to_local := false
	for player in _players:
		var uid := str(player.get("userId", ""))
		if uid == sender_user_id:
			continue  # the server never echoes to the sender
		if not _target_matches(player, target):
			continue
		delivered.append(uid)
		if uid == local_user_id:
			to_local = true
	_log_event("in" if to_local else "out", event, payload, sender_user_id, target, delivered)
	if to_local:
		_deliver_local(event, payload, sender_user_id)


## Deletes all persisted mock data (saves, stats, metadata, achievements).
func reset_persistence() -> void:
	_save = {}
	_session_stats = {"cumulativeGameplayTimeMs": 0.0, "gameplayCompleted": false}
	_metadata = {}
	_achievements = {}
	_gameplay_started_at_ms = -1
	var dir := DirAccess.open(SAVE_DIR)
	if dir:
		for file_name in dir.get_files():
			dir.remove(file_name)


# ────────────────────────────────────────────────
# Classic SDK verbs
# ────────────────────────────────────────────────

func save_game(save_data: Dictionary, progress: float) -> Dictionary:
	await _tick()
	_save = {
		"saveData": _round_trip(save_data),
		"progress": progress,
		"savedAt": Time.get_datetime_string_from_system(true),
	}
	_write_json("save.json", _save)
	return {"success": true}


func load_latest_save() -> Dictionary:
	await _tick()
	if _save.is_empty():
		return {"success": true, "payload": {}}
	return {"success": true, "payload": _round_trip(_save.get("saveData", {}))}


func gameplay_start() -> Dictionary:
	await _tick()
	_gameplay_started_at_ms = Time.get_ticks_msec()
	return {"success": true}


func gameplay_end() -> Dictionary:
	await _tick()
	_fold_gameplay_time()
	_write_json("session_stats.json", _session_stats)
	return {"success": true}


func gameplay_completed() -> Dictionary:
	await _tick()
	_fold_gameplay_time()
	_session_stats["gameplayCompleted"] = true
	_write_json("session_stats.json", _session_stats)
	return {"success": true}


func get_experience_data() -> Dictionary:
	await _tick()
	return {"success": true, "payload": _mock_experience_payload()}


func get_experience_date() -> Variant:
	# NOTE: the web bridge returns a JS Date object here; a datetime string is
	# the closest local equivalent. No game code consumes the value directly.
	return Time.get_datetime_string_from_system()


func get_game_metadata() -> Dictionary:
	await _tick()
	return {"success": true, "payload": _round_trip(_metadata)}


func set_game_metadata(category: String, key: String, value: Variant) -> Dictionary:
	await _tick()
	var stored: Variant = _round_trip(value)
	if not (_metadata.get(category) is Dictionary):
		_metadata[category] = {}
	_metadata[category][key] = stored
	# Root-level spread mirrors the platform's cache shape (back-compat reads).
	_metadata[key] = stored
	_write_json("metadata.json", _metadata)
	return {"success": true}


func unlock_achievement(key: String) -> Dictionary:
	await _tick()
	var already: bool = _achievements.has(key)
	if not already:
		_achievements[key] = {"unlockedAt": Time.get_datetime_string_from_system(true)}
		_write_json("achievements.json", _achievements)
	return {"success": true, "alreadyUnlocked": already}


func get_achievements() -> Dictionary:
	await _tick()
	var unlocked := []
	for key in _achievements.keys():
		var entry: Dictionary = {"key": key}
		var details = _achievements[key]
		if details is Dictionary:
			entry.merge(details)
		unlocked.append(entry)
	return {"success": true, "payload": {"achievements": unlocked}}


func get_session_stats() -> Dictionary:
	await _tick()
	var total := float(_session_stats.get("cumulativeGameplayTimeMs", 0.0))
	if _gameplay_started_at_ms >= 0:
		total += Time.get_ticks_msec() - _gameplay_started_at_ms
	return {"success": true, "payload": {
		"cumulativeGameplayTimeMs": total,
		"gameplayCompleted": _session_stats.get("gameplayCompleted", false),
	}}


# ────────────────────────────────────────────────
# Lobby
# ────────────────────────────────────────────────

func lobby_is_available() -> bool:
	return true


func lobby_get_current_game() -> Dictionary:
	return {"gameId": "mock-game", "experienceId": "mock-experience"}


func lobby_get_players() -> Array:
	var players = _round_trip(_players)
	return players if players is Array else []


func lobby_get_me() -> Dictionary:
	return {"userId": local_user_id, "role": local_role}


func lobby_send_event(event: String, data: Variant, target: Dictionary) -> void:
	var payload: Variant = _round_trip(data)
	var delivered: Array = []
	for player in _players:
		var uid := str(player.get("userId", ""))
		if uid == local_user_id:
			continue  # the server never echoes to the sender
		if not _target_matches(player, target):
			continue
		delivered.append(uid)
	_log_event("out", event, payload, LOCAL_USER_ID, target, delivered)


# ────────────────────────────────────────────────
# WebRTC signaling (offline mock: a room with only the local peer)
# ────────────────────────────────────────────────

const WEBRTC_MOCK_ROOM := "mock-room"

## True after webrtc_connect_signaling, until webrtc_disconnect.
var webrtc_joined := false


func webrtc_is_available() -> bool:
	return true


func webrtc_connect_signaling(_room_id: String) -> Dictionary:
	await _tick()
	webrtc_joined = true
	# Overlay-faked guests are roster-only — they can't do WebRTC, so the mock
	# room never reports other peers.
	return {"success": true, "payload": {
		"peerId": local_user_id,
		"roomId": WEBRTC_MOCK_ROOM,
		"iceServers": [],
	}}


func webrtc_send_signal(target_peer_id: String, data: Variant) -> void:
	# No real peers exist offline; log the attempt for the overlay and drop.
	_log_event("out", "[webrtc] signal", _round_trip(data), local_user_id,
		{"userId": target_peer_id}, [])


func webrtc_disconnect() -> void:
	if webrtc_joined:
		webrtc_joined = false
		webrtc_signaling_closed.emit(WEBRTC_MOCK_ROOM)


# ────────────────────────────────────────────────
# Play mode (native dev/testing: emulated via env vars, no platform page)
# ────────────────────────────────────────────────

func multiplayer_get_play_mode() -> String:
	return OS.get_environment("COUCH_PLAY_MODE")


func multiplayer_get_share_code() -> String:
	return OS.get_environment("COUCH_SHARE_CODE")


func multiplayer_is_joining() -> bool:
	return OS.get_environment("COUCH_JOINING") == "1"


func _emit_play_mode_selected() -> void:
	play_mode_selected.emit(multiplayer_get_play_mode(), multiplayer_get_share_code())


# ────────────────────────────────────────────────
# Internals
# ────────────────────────────────────────────────

func _deliver_local(event: String, payload: Variant, sender_user_id: String) -> void:
	await _tick()
	lobby_event_received.emit(event, payload, sender_user_id)


func _target_matches(player: Dictionary, target: Dictionary) -> bool:
	# Mirrors the server predicate: provided conditions AND together.
	if target.is_empty():
		return true
	if target.has("userId") and str(player.get("userId", "")) != str(target["userId"]):
		return false
	if target.has("role") and str(player.get("role", "")) != str(target["role"]):
		return false
	return true


func _emit_players() -> void:
	var players = _round_trip(_players)
	if players is Array:
		lobby_players_updated.emit(players)


func _log_event(direction: String, event: String, data: Variant, sender_user_id: String, target: Dictionary, delivered_to: Array) -> void:
	mock_event_logged.emit({
		"direction": direction,
		"event": event,
		"data": data,
		"sender_user_id": sender_user_id,
		"target": target,
		"delivered_to": delivered_to,
		"time": Time.get_time_string_from_system(),
	})


func _lowest_free_slot() -> int:
	var used := {}
	for player in _players:
		var slot = player.get("controllerSlot")
		if slot is int or slot is float:
			used[int(slot)] = true
	var free := 1
	while used.has(free):
		free += 1
	return free


func _fold_gameplay_time() -> void:
	if _gameplay_started_at_ms < 0:
		return
	var elapsed := Time.get_ticks_msec() - _gameplay_started_at_ms
	_gameplay_started_at_ms = -1
	_session_stats["cumulativeGameplayTimeMs"] = \
		float(_session_stats.get("cumulativeGameplayTimeMs", 0.0)) + elapsed


func _mock_experience_payload() -> Dictionary:
	var experience_name := str(ProjectSettings.get_setting(_EXPERIENCE_NAME_SETTING, ""))
	if experience_name.is_empty():
		experience_name = str(ProjectSettings.get_setting("application/config/name", "Mock Game"))
	var experience_url := str(ProjectSettings.get_setting(_EXPERIENCE_URL_SETTING, "https://couch.games/mock"))
	return {
		"activatedAt": Time.get_datetime_string_from_system(true),
		"files": {},
		"type": "game",
		"experienceIndex": 0,
		"title": experience_name,
		"experienceId": "mock-experience",
		"experienceUrl": experience_url,
		"experienceName": experience_name,
		"gameId": "mock-game",
		"gameTitle": experience_name,
	}


## Suspends like a web-bridge call would: one frame minimum, or the configured
## artificial latency. Keeps `await` timing semantics identical across backends.
func _tick() -> void:
	if latency_ms > 0:
		await get_tree().create_timer(latency_ms / 1000.0).timeout
	else:
		await get_tree().process_frame


## Replicates the JS bridge's JSON boundary: ints become floats, non-JSON
## types degrade identically, and callers receive copies rather than aliases.
func _round_trip(value: Variant) -> Variant:
	if value == null:
		return null
	return JSON.parse_string(JSON.stringify(value))


func _load_persisted() -> void:
	_save = _read_json("save.json", {})
	_session_stats = _read_json("session_stats.json",
		{"cumulativeGameplayTimeMs": 0.0, "gameplayCompleted": false})
	_metadata = _read_json("metadata.json", {})
	_achievements = _read_json("achievements.json", {})


func _read_json(file_name: String, fallback: Dictionary) -> Dictionary:
	var path := SAVE_DIR + file_name
	if not FileAccess.file_exists(path):
		return fallback
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return fallback
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else fallback


func _write_json(file_name: String, data: Dictionary) -> void:
	var err := DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_error("CouchGames mock: failed to create " + SAVE_DIR)
		return
	var file := FileAccess.open(SAVE_DIR + file_name, FileAccess.WRITE)
	if file == null:
		push_error("CouchGames mock: failed to write " + file_name)
		return
	file.store_string(JSON.stringify(data, "\t"))
