# WebRTC signaling bridge, exposed as `CouchGames.webrtc`.
#
# Provides everything a game needs to establish WebRTC peer connections with
# other session members: a relay for opaque handshake blobs (SDP offers/
# answers, ICE candidates), peer presence for the signaling room, and ICE
# server configuration (STUN + server-minted TURN credentials on the real
# platform).
#
# A peer id IS the lobby userId, so signaling peers correlate 1:1 with
# CouchGames.lobby players (role, controller slot). This node is transport
# plumbing only — assembling WebRTCPeerConnection / WebRTCMultiplayerPeer from
# it is the game's (or a netcode addon's) job.
#
# Typical flow:
#   var res := await CouchGames.webrtc.connect_signaling()
#   # res.ice_servers -> WebRTCPeerConnection.initialize({"iceServers": ...})
#   # peer_exists/peer_joined -> create a connection per peer; the side with
#   # the lexicographically smaller peer id creates the offer.
#   # send_signal(peer, {...}) / signal_received carry the handshake blobs.
class_name CouchWebRTC
extends Node

## A handshake blob from another peer. `data` is whatever they passed to
## send_signal, after a JSON round-trip.
signal signal_received(sender_peer_id: String, data: Variant)
## A peer joined the signaling room after us.
signal peer_joined(peer_id: String)
signal peer_left(peer_id: String)
## A peer that was already in the room when we connected (reported right
## after connect_signaling resolves).
signal peer_exists(peer_id: String)
## The signaling socket closed — including after disconnect_signaling().
## Reconnect with connect_signaling() if the session is still live.
signal signaling_closed(room_id: String)
## Fresh ICE servers after a request_ice_servers() refresh.
signal ice_servers_updated(ice_servers: Array)

var is_available: bool:
	get:
		return _backend != null and _backend.webrtc_is_available()

## True while the signaling socket is open.
var is_signaling_connected := false
## The local peer id (== lobby userId), set by a successful connect.
var local_peer_id := ""
## The signaling room id, set by a successful connect.
var room_id := ""
## Latest ICE server list, in WebRTCPeerConnection.initialize() "iceServers"
## element shape ({urls, username?, credential?}). Kept fresh by refreshes.
var ice_servers: Array = []

var _backend: CouchGamesBackend


## Called by the CouchGames autoload during setup.
func setup(backend: CouchGamesBackend) -> void:
	_backend = backend
	_backend.webrtc_signal_received.connect(signal_received.emit)
	_backend.webrtc_peer_joined.connect(peer_joined.emit)
	_backend.webrtc_peer_left.connect(peer_left.emit)
	_backend.webrtc_peer_exists.connect(peer_exists.emit)
	_backend.webrtc_signaling_closed.connect(_on_signaling_closed)
	_backend.webrtc_ice_servers_updated.connect(_on_ice_servers_updated)


## Join the session's signaling room. Leave `explicit_room_id` empty to use
## the active lobby's room (the normal case). Returns
## {success, error?, peer_id?, room_id?, ice_servers?}.
func connect_signaling(explicit_room_id: String = "") -> Dictionary:
	if _backend == null or not _backend.webrtc_is_available():
		return {"success": false, "error": "WebRTC signaling not available"}
	var raw: Dictionary = await _backend.webrtc_connect_signaling(explicit_room_id)
	if not raw.get("success", false):
		# The web bridge reports failures under "message"; backends under "error".
		var reason := str(raw.get("message", raw.get("error", "connect failed")))
		return {"success": false, "error": reason}
	var payload: Dictionary = raw.get("payload") if raw.get("payload") is Dictionary else {}
	local_peer_id = str(payload.get("peerId", ""))
	room_id = str(payload.get("roomId", ""))
	var servers: Variant = payload.get("iceServers", [])
	ice_servers = servers if servers is Array else []
	is_signaling_connected = true
	return {
		"success": true,
		"peer_id": local_peer_id,
		"room_id": room_id,
		"ice_servers": ice_servers.duplicate(true),
	}


## Relay an opaque JSON-serializable handshake blob to one peer. Delivery is
## best-effort: unknown/disconnected targets are dropped silently, so drive
## retries off WebRTC connection state, not the relay.
func send_signal(target_peer_id: String, data: Variant) -> void:
	if _backend == null:
		return
	_backend.webrtc_send_signal(target_peer_id, data)


## Ask for fresh ICE servers (TURN credentials expire after ~1h). The result
## arrives via ice_servers_updated and also updates `ice_servers`.
func request_ice_servers() -> void:
	if _backend != null:
		_backend.webrtc_request_ice_servers()


## Leave the signaling room. Existing WebRTC peer connections stay up — this
## only tears down the handshake channel.
func disconnect_signaling() -> void:
	if _backend != null:
		_backend.webrtc_disconnect()


func _on_signaling_closed(closed_room_id: String) -> void:
	is_signaling_connected = false
	signaling_closed.emit(closed_room_id)


func _on_ice_servers_updated(servers: Array) -> void:
	ice_servers = servers
	ice_servers_updated.emit(servers)
