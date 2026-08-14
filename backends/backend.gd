# Abstract base for CouchGames SDK backends. The CouchGames autoload delegates
# every SDK verb here. The implementations are CouchGamesWebBackend (the
# platform bridge, web exports only) and CouchGamesMockBackend (local simulation
# for the editor and standalone runs).
#
# Classic verbs return raw response Dictionaries in the platform's shape
# ({success, error?, payload?, metadata?}); the autoload wraps them into
# CouchGamesSDKResponse. Lobby data keeps the platform's key style (userId,
# username, role, status, experienceId, controllerSlot, ping); converting it to
# typed CouchLobbyPlayer objects is CouchLobby's job.
class_name CouchGamesBackend
extends Node

## A lobby tunnel event addressed to the local player.
signal lobby_event_received(event: String, data: Variant, sender_user_id: String)
## The lobby roster changed. `players` is an Array of raw player Dictionaries.
signal lobby_players_updated(players: Array)

## A WebRTC signaling blob (SDP offer/answer, ICE candidate, ...) relayed to
## the local peer. `data` is the sender's payload after a JSON round-trip.
signal webrtc_signal_received(sender_peer_id: String, data: Variant)
## Peer presence in the signaling room. Peer ids are lobby userIds.
signal webrtc_peer_joined(peer_id: String)
signal webrtc_peer_left(peer_id: String)
## An already-connected peer, reported right after our own connect.
signal webrtc_peer_exists(peer_id: String)
## The signaling socket closed (including after webrtc_disconnect).
signal webrtc_signaling_closed(room_id: String)
## Fresh ICE servers after a webrtc_request_ice_servers refresh.
signal webrtc_ice_servers_updated(ice_servers: Array)

## Play-mode selection made on the parent platform page ("1-device",
## "2-devices"); empty when none has been made (or not on the platform).
signal play_mode_selected(mode: String, code: String)


func is_available() -> bool:
	return false


func is_mock() -> bool:
	return false


func initialize() -> void:
	pass


# --- Experience files ---
#
# Addressed by basename. `experience_get_file` returns
# {success: bool, error: String, bytes: PackedByteArray} rather than raw bytes,
# so CouchExperience can report WHY a file is missing instead of handing game
# code an empty array with no cause.

func experience_list_files() -> PackedStringArray:
	return PackedStringArray()


func experience_get_file(_file_name: String) -> Dictionary:
	return {"success": false, "error": "Experience files are not available here"}


# --- Build files ---
#
# Files that shipped inside the game's own build, addressed by their path
# relative to it. `build_root()` is the only thing a backend has to supply:
# CouchGameFiles joins the relative path onto it and picks a reader from the
# SCHEME, so an http(s) root is downloaded and a local one is opened directly.
#
# The platform's build path carries a random suffix (games/<slug>/v73-1a2b3c4d),
# so on web this can only come from the running frame's own URL — there is
# nothing to reconstruct it from. Empty means build files are unavailable here.

func build_root() -> String:
	return ""


# --- Classic SDK verbs ---

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


# --- Lobby ---

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


# --- WebRTC signaling ---

func webrtc_is_available() -> bool:
	return false


## Join the session's signaling room. `room_id` is normally "", which lets the
## platform default to the active lobby's room. Returns the platform's shape:
## {success, message?, payload?: {peerId, roomId, iceServers}}.
func webrtc_connect_signaling(_room_id: String) -> Dictionary:
	return _not_implemented()


func webrtc_send_signal(_target_peer_id: String, _data: Variant) -> void:
	pass


## Ask for fresh ICE servers (TURN credentials expire after ~1h). Results
## arrive via webrtc_ice_servers_updated.
func webrtc_request_ice_servers() -> void:
	pass


func webrtc_disconnect() -> void:
	pass


# --- Play mode ---

func multiplayer_get_play_mode() -> String:
	return ""


func multiplayer_get_share_code() -> String:
	return ""


func multiplayer_is_joining() -> bool:
	return false


func _not_implemented() -> Dictionary:
	return {"success": false, "error": "Not implemented"}
