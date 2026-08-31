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
## The room's full peer list after a webrtc_request_peers snapshot. Complete
## and authoritative as of the moment the server sent it: replaces a previous
## view rather than adding to it. Never includes the local peer.
signal webrtc_peers_updated(peer_ids: Array)
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

## `expected_revision` and `on_conflict` are the game's to set, never the SDK's.
## Leave them at their defaults and the platform applies its own: a refused
## write is reported as {success: true, persisted: false, conflict: true}.
##
## `expected_revision` (an int from load_save_result()) asserts the revision
## this write replaces. `on_conflict` is "" (platform default), "no-op", or
## "error"; "error" turns a refusal into success: false, which only a game with
## a BOUNDED retry loop should ask for — an uncapped one would spin for the
## whole session.
func save_game(
	_save_data: Dictionary,
	_progress: float,
	_expected_revision: Variant = null,
	_on_conflict: String = "",
) -> Dictionary:
	return _not_implemented()


## The synchronous cache read. Cannot distinguish "no save" from "not loaded
## yet" from "withheld from a joined guest" — use load_save_result() to decide
## whether this is a new player.
func load_latest_save() -> Dictionary:
	return _not_implemented()


## The awaitable, honest counterpart to load_latest_save(). Returns the
## platform's shape: {status, message, payload?, metadata?, revision?,
## hostAuthoritative}. See CouchGamesSaveLoadResult.
##
## Unimplemented backends report "unavailable" rather than a generic failure:
## a game must never read a backend's silence as "this player is new".
func load_save_result() -> Dictionary:
	return {
		"status": CouchGamesSaveLoadResult.STATUS_UNAVAILABLE,
		"message": "Not implemented",
		"hostAuthoritative": false,
	}


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
## CouchWebRTC serializes calls because the platform owns one global signaling
## socket. Implementations must make webrtc_disconnect() invalidate a connect
## suspended inside this function, so post-await code cannot rejoin after a
## cancellation. A disconnect of either a pending or live connection must emit
## webrtc_signaling_closed once its physical socket/membership is gone.
func webrtc_connect_signaling(_room_id: String) -> Dictionary:
	return _not_implemented()


func webrtc_send_signal(_target_peer_id: String, _data: Variant) -> void:
	pass


## Ask for fresh ICE servers (TURN credentials expire after ~1h). Results
## arrive via webrtc_ice_servers_updated.
func webrtc_request_ice_servers() -> void:
	pass


## Ask the signaling room who is present. webrtc_peer_exists is announced once,
## at connect, so this is the only way back to the truth for a caller that
## connected earlier or missed an event. Results arrive via
## webrtc_peers_updated; backends that cannot answer stay silent.
func webrtc_request_peers() -> void:
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
