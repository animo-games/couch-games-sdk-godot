# Mock backend: a local stand-in for the CouchGames platform, so games stay
# testable in the editor (and in any non-platform build) without changes.
#
# - Classic verbs persist to user://couch_games_mock/*.json.
# - The lobby starts with the local player as host; fake guests come from
#   add_guest() or the debug overlay.
# - Tunnel routing mirrors the real server (signaling-object): an event is
#   NEVER delivered back to its sender, and a target's userId/role conditions
#   AND together.
# - Every payload crosses a JSON round-trip so type fidelity matches the web
#   bridge (ints become floats, callers get copies).
class_name CouchGamesMockBackend
extends CouchGamesBackend

const SAVE_DIR := "user://couch_games_mock/"
const LOCAL_USER_ID := "mock-local-host"

const _LATENCY_SETTING := "couch_games/mock/latency_ms"
const _USERNAME_SETTING := "couch_games/mock/local_username"
const _EXPERIENCE_NAME_SETTING := "couch_games/mock/experience_name"
const _EXPERIENCE_URL_SETTING := "couch_games/mock/experience_url"
const _EXPERIENCE_FILES_DIR_SETTING := "couch_games/mock/experience_files_dir"
const _BUILD_FILES_DIR_SETTING := "couch_games/mock/build_files_dir"

## Where the mock backend reads experience files from, so packs can be built and
## played without uploading them.
const DEFAULT_EXPERIENCE_FILES_DIR := "res://experience_files"

## Where the mock backend reads build files from. res://build/web is the
## directory tools/build_and_upload zips and uploads, so the file the game
## loads in the editor is the same file that ships.
const DEFAULT_BUILD_FILES_DIR := "res://build/web"

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
## The stored revision this simulated session has seen. Set to the stored
## revision at startup, the way the platform hands a session its save, so the
## editor's normal save-without-loading flow keeps working unchanged.
var _session_known_revision: int = 0
## A save.json that exists but does not parse. The platform reports that as
## "unavailable" (a save exists and cannot be read); without this the mock would
## fall through to "not_found" and tell a game it is safe to start fresh.
var _save_corrupt := false

# The knobs below, plus simulate_unread_save(), let a game rehearse in the
# editor the save paths it could otherwise only reach on the live platform.

## Makes load_save_result() report "unavailable" — a save may exist and could
## not be read, so the game must not treat the player as new.
var simulate_load_unavailable := false
## Makes load_save_result() report hostAuthoritative — this player joined
## someone else's session, so the payload is their own save and the host owns
## the shared board.
var simulate_host_authoritative := false
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


# --- Mock-control API (used by tests and the debug overlay) ---

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
	_session_known_revision = 0
	_save_corrupt = false
	_session_stats = {"cumulativeGameplayTimeMs": 0.0, "gameplayCompleted": false}
	_metadata = {}
	_achievements = {}
	_gameplay_started_at_ms = -1
	var dir := DirAccess.open(SAVE_DIR)
	if dir:
		for file_name in dir.get_files():
			dir.remove(file_name)


## Pretend this session never read the stored save, so the next whole-document
## save_game() is refused the way the platform refuses a joined guest's blind
## write. No-op when nothing is stored — the platform always admits a new
## player's first save, and so does the mock.
##
## Recovery works as documented: call load_save_result(), merge into what it
## returns, and the next write is admitted again.
func simulate_unread_save() -> void:
	_session_known_revision = -1


# --- Classic SDK verbs ---

func save_game(
	save_data: Dictionary,
	progress: float,
	expected_revision: Variant = null,
	on_conflict: String = "",
) -> Dictionary:
	await _tick()
	var stored_revision := _stored_revision()
	if not _admits_save_write(stored_revision, expected_revision):
		# The platform's shape for a refusal, both modes. Only `success` differs
		# between them; `persisted` is accurate in both, which is why it is the
		# field a game should branch on.
		return {
			"success": on_conflict != "error",
			"error": "Save skipped: this session has not loaded the stored save it would replace",
			"persisted": false,
			"conflict": true,
			# A refusal implies something is stored: _admits_save_write always
			# admits at revision 0.
			"currentRevision": stored_revision,
		}
	var next_revision := stored_revision + 1
	_save = {
		"saveData": _round_trip(save_data),
		"progress": progress,
		"savedAt": Time.get_datetime_string_from_system(true),
		"revision": next_revision,
	}
	# A session that just wrote knows what is stored: itself. Without this a new
	# player's SECOND save would be refused as a blind overwrite of their own.
	_session_known_revision = next_revision
	_save_corrupt = false
	_write_json("save.json", _save)
	return {"success": true, "persisted": true, "currentRevision": next_revision}


func load_latest_save() -> Dictionary:
	await _tick()
	# Deliberately does NOT mark the save as read. That matches the platform's
	# SERVER guard, which this cache read never syncs. The platform's CLIENT
	# guard is laxer — a non-empty cache read clears its staleness flag — so the
	# mock refuses a few writes the platform would admit. Erring strict is the
	# right direction for a simulation whose job is to surface refusals.
	if _save.is_empty():
		return {"success": true, "payload": {}}
	return {"success": true, "payload": _round_trip(_save.get("saveData", {}))}


func load_save_result() -> Dictionary:
	await _tick()
	if simulate_load_unavailable or _save_corrupt:
		# Note the deliberate asymmetry with the platform: an unavailable read
		# does NOT mark the save as read, so a save that follows one is still
		# refused. That is what makes "unavailable means keep writes off"
		# testable in the editor.
		return {
			"status": CouchGamesSaveLoadResult.STATUS_UNAVAILABLE,
			"message": "Simulated: save could not be loaded" if simulate_load_unavailable \
				else "Corrupted save data",
			"hostAuthoritative": simulate_host_authoritative,
		}
	# Both authoritative answers sync the session, exactly as the platform does:
	# the game has now seen what is stored, or confirmed nothing is, so its next
	# write is intentional rather than blind. This is what makes the documented
	# recovery — load, merge, write — work against the mock.
	_session_known_revision = _stored_revision()
	if _save.is_empty():
		return {
			"status": CouchGamesSaveLoadResult.STATUS_NOT_FOUND,
			"message": "No save found",
			"payload": null,
			"metadata": _round_trip(_metadata),
			"hostAuthoritative": simulate_host_authoritative,
		}
	return {
		"status": CouchGamesSaveLoadResult.STATUS_FOUND,
		"message": "",
		"payload": _round_trip(_save.get("saveData", {})),
		"metadata": _round_trip(_metadata),
		"revision": _stored_revision(),
		"hostAuthoritative": simulate_host_authoritative,
	}


## The stored save's revision, or 0 when nothing is stored. Saves written by an
## older build of this mock have no revision and count as 1.
func _stored_revision() -> int:
	if _save.is_empty():
		return 0
	return int(_save.get("revision", 1))


## Mirrors the platform's no-clobber guard: a write lands unless it would
## replace a stored save this session has never seen.
func _admits_save_write(stored_revision: int, expected_revision: Variant) -> bool:
	if stored_revision == 0:
		return true  # Nothing stored, so nothing to destroy.
	if _session_known_revision == stored_revision:
		return true
	# Numeric only, matching the platform's strict `===`. Coercing a String here
	# would admit in the editor a write the platform refuses, which is the worst
	# way for a game to learn about expected_revision.
	if (expected_revision is int or expected_revision is float) \
			and int(expected_revision) == stored_revision:
		return true  # The caller asserted what it replaces, and is right.
	return false


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


# --- Experience files ---
#
# Served from a directory in the project, so an experience can be built and
# played in the editor before it is ever uploaded. Point
# couch_games/mock/experience_files_dir at wherever your packs are built to.

func experience_list_files() -> PackedStringArray:
	var dir := _experience_files_dir()
	if not DirAccess.dir_exists_absolute(dir):
		return PackedStringArray()
	var out := PackedStringArray()
	for file_name in DirAccess.get_files_at(dir):
		# The editor writes .import/.remap siblings next to real files; an
		# exported build sees the .remap name instead. Neither is a payload.
		if file_name.ends_with(".import") or file_name.ends_with(".remap"):
			continue
		out.append(file_name)
	return out


func experience_get_file(file_name: String) -> Dictionary:
	await _tick()
	if file_name.is_empty() or file_name != file_name.get_file():
		# Basenames only, matching the platform. A path would escape the dir.
		return {"success": false, "error": "Not a basename: '%s'" % file_name}
	var path := _experience_files_dir().path_join(file_name)
	if not FileAccess.file_exists(path):
		return {"success": false, "error": "No file at %s" % path}
	var bytes := FileAccess.get_file_as_bytes(path)
	var open_error := FileAccess.get_open_error()
	if open_error != OK:
		return {"success": false, "error": error_string(open_error)}
	return {"success": true, "bytes": bytes}


func _experience_files_dir() -> String:
	return str(ProjectSettings.get_setting(
		_EXPERIENCE_FILES_DIR_SETTING, DEFAULT_EXPERIENCE_FILES_DIR))


# --- Build files ---
#
# A local directory stands in for the served build. CouchGameFiles reads it with
# FileAccess rather than HTTPRequest because the root has no http(s) scheme, so
# CouchGames.game.load_pack() works in the editor exactly as it does on the
# platform — which is the point, since on web a dev could have written the
# HTTPRequest themselves.

func build_root() -> String:
	return str(ProjectSettings.get_setting(
		_BUILD_FILES_DIR_SETTING, DEFAULT_BUILD_FILES_DIR))


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


# --- Lobby ---

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


# --- WebRTC signaling (offline mock: a room with only the local peer) ---

const WEBRTC_MOCK_ROOM := "mock-room"

## True after webrtc_connect_signaling, until webrtc_disconnect.
var webrtc_joined := false


func webrtc_is_available() -> bool:
	return true


func webrtc_connect_signaling(_room_id: String) -> Dictionary:
	await _tick()
	webrtc_joined = true
	# Overlay-faked guests are roster-only and can't do WebRTC, so the mock room
	# never reports other peers.
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


# --- Play mode (native dev/testing: emulated via env vars, no platform page) ---

func multiplayer_get_play_mode() -> String:
	return OS.get_environment("COUCH_PLAY_MODE")


func multiplayer_get_share_code() -> String:
	return OS.get_environment("COUCH_SHARE_CODE")


func multiplayer_is_joining() -> bool:
	return OS.get_environment("COUCH_JOINING") == "1"


func _emit_play_mode_selected() -> void:
	play_mode_selected.emit(multiplayer_get_play_mode(), multiplayer_get_share_code())


# --- Internals ---

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
## artificial latency. Keeps await timing the same across backends.
func _tick() -> void:
	if latency_ms > 0:
		await get_tree().create_timer(latency_ms / 1000.0).timeout
	else:
		await get_tree().process_frame


## Replicates the JS bridge's JSON boundary: ints become floats, non-JSON types
## degrade the same way, and callers get copies rather than aliases.
func _round_trip(value: Variant) -> Variant:
	if value == null:
		return null
	return JSON.parse_string(JSON.stringify(value))


func _load_persisted() -> void:
	_save = _read_json("save.json", {})
	_save_corrupt = _save.is_empty() and FileAccess.file_exists(SAVE_DIR + "save.json")
	# The platform hands a starting session the save it is in sync with, so the
	# guard admits its writes. Match that, or every editor run with a save on
	# disk would start out refusing.
	_session_known_revision = _stored_revision()
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
