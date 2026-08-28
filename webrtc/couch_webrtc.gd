# WebRTC signaling bridge, exposed as `CouchGames.webrtc`.
#
# Handles the signaling side of setting up WebRTC peer connections with other
# session members: a relay for opaque handshake blobs (SDP offers/answers, ICE
# candidates), peer presence for the signaling room, and ICE server config
# (STUN, plus server-minted TURN credentials on the real platform).
#
# A peer id IS the lobby userId, so signaling peers correlate 1:1 with
# CouchGames.lobby players (role, controller slot). This node is transport
# plumbing only. Assembling WebRTCPeerConnection / WebRTCMultiplayerPeer out of
# it is the game's job, or a netcode addon's.
#
# Typical flow:
#   var res := await CouchGames.webrtc.connect_signaling()
#   # res.ice_servers -> WebRTCPeerConnection.initialize({"iceServers": ...})
#   # peer_exists/peer_joined -> create a connection per peer; the side with
#   # the lexicographically smaller peer id creates the offer.
#   # send_signal(peer, {...}) / signal_received carry the handshake blobs.
class_name CouchWebRTC
extends Node

const _PathProbe := preload("res://addons/couch-games-sdk/webrtc/path_probe.gd")

## A handshake blob from another peer. `data` is whatever they passed to
## send_signal, after a JSON round-trip.
signal signal_received(sender_peer_id: String, data: Variant)
## A peer joined the signaling room after us.
signal peer_joined(peer_id: String)
signal peer_left(peer_id: String)
## A peer that was already in the room when we connected (reported right
## after connect_signaling resolves).
signal peer_exists(peer_id: String)
## The signaling socket closed, including after disconnect_signaling().
signal signaling_closed(room_id: String)
## An automatic reconnect attempt is about to start (attempts are 1-based).
signal signaling_reconnecting(room_id: String, attempt: int)
## An unexpected signaling close was automatically recovered.
signal signaling_reconnected(room_id: String)
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

## Keep the signaling relay available for later ICE/connection rebuilds. This
## does not touch established WebRTC peer connections.
@export var auto_reconnect_signaling := true
@export var signaling_reconnect_initial_delay_sec := 0.5
@export var signaling_reconnect_max_delay_sec := 4.0
## A replacement signaling socket must not start until the previous global
## backend connection has acknowledged closing. If that acknowledgement never
## arrives, fail closed rather than risk an old close/disconnect hitting a new
## live socket.
@export var signaling_close_timeout_sec := 3.0

var _backend: CouchGamesBackend
var _desired_room_id := ""
var _wants_signaling := false
var _signaling_lifecycle := 0
## Logical reconnect-loop ownership. A stopped/superseded loop only clears this
## field if it still owns the same id.
var _reconnect_loop_seq := 0
var _active_reconnect_loop := 0
## Physical backend ownership. The backend exposes one global signaling socket,
## so only one connect coroutine may own it at a time.
var _backend_attempt_seq := 0
var _backend_connect_owner := 0
var _live_backend_attempt := 0
var _backend_connection_open := false
var _backend_closing := false
var _backend_close_expected := false
var _backend_close_deadline_msec := 0
var _backend_close_seq := 0
var _backend_blocked_error := ""


## Normalize a platform-issued room code: uppercase and strip all whitespace.
## The platform owns code generation and its alphabet, so this must not
## filter characters the way a locally-generated code's alphabet would.
static func normalize_room_code(code: String) -> String:
	var normalized := ""
	for c in code.to_upper():
		if c.strip_edges() != "":
			normalized += c
	return normalized


## Build the signaling room id for a room code. Pass the result to
## connect_signaling() so host and joiner land in the same room. The "code-"
## namespace keeps short codes from colliding with platform lobby room ids.
static func room_id_for_code(code: String) -> String:
	return "code-" + normalize_room_code(code)


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
	_signaling_lifecycle += 1
	var token := _signaling_lifecycle
	_desired_room_id = explicit_room_id
	_wants_signaling = true
	# This explicit request supersedes any reconnect loop and any physical socket
	# it was using. The replacement waits inside _connect_once until the old
	# coroutine and close acknowledgement have both drained.
	_active_reconnect_loop = 0
	_begin_backend_disconnect()
	var result: Dictionary = await _connect_once(token, explicit_room_id)
	if token != _signaling_lifecycle or not _wants_signaling:
		return {"success": false, "error": "signaling connect superseded"}
	if not result.get("success", false):
		_wants_signaling = false
		return result
	if int(result.get("_backend_attempt", 0)) != _live_backend_attempt:
		_wants_signaling = false
		return {"success": false, "error": "signaling closed during connect"}
	_apply_signaling_connection(result, false)
	result.erase("_backend_attempt")
	return result


## Run one physical connect against the backend's singleton signaling socket.
## Every caller, including automatic reconnect, comes through this gate.
func _connect_once(token: int, explicit_room_id: String) -> Dictionary:
	var wait_error := await _wait_for_backend_slot(token)
	if not wait_error.is_empty():
		return {"success": false, "error": wait_error}
	if token != _signaling_lifecycle or not _wants_signaling:
		return {"success": false, "error": "signaling connect superseded"}

	_backend_attempt_seq += 1
	var attempt := _backend_attempt_seq
	_backend_connect_owner = attempt
	_backend_close_deadline_msec = 0
	var close_seq_at_start := _backend_close_seq
	var result: Dictionary = await _request_signaling_connection(explicit_room_id)
	var closed_during_connect := _backend_close_seq != close_seq_at_start

	if token != _signaling_lifecycle or not _wants_signaling:
		if result.get("success", false):
			# A canceled backend promise still opened its global socket. Dispose it
			# while this attempt retains the physical slot; no newer connection can
			# exist yet, so this disconnect cannot hit the replacement.
			_backend_connection_open = true
			_live_backend_attempt = attempt
			_begin_backend_disconnect()
			await _wait_for_backend_close()
		elif _backend_closing:
			# A cancellation-induced failure may resolve just before the backend's
			# close callback. Keep the physical slot until that callback drains.
			await _wait_for_backend_close()
		_release_backend_attempt(attempt)
		return {"success": false, "error": "signaling connect superseded"}

	if not result.get("success", false) or closed_during_connect:
		if result.get("success", false):
			# The socket reported a close while its connect promise was pending,
			# then still resolved successfully. Treat that as an ambiguous late
			# connection and close it behind the same physical-slot barrier.
			_backend_connection_open = true
			_live_backend_attempt = attempt
			_begin_backend_disconnect()
			await _wait_for_backend_close()
		_backend_closing = false
		_backend_close_expected = false
		_release_backend_attempt(attempt)
		if closed_during_connect and result.get("success", false):
			return {"success": false, "error": "signaling closed during connect"}
		return result

	_backend_connection_open = true
	_live_backend_attempt = attempt
	result["_backend_attempt"] = attempt
	_release_backend_attempt(attempt)
	return result


func _wait_for_backend_slot(token: int) -> String:
	while _backend_connect_owner != 0 or _backend_closing:
		if token != _signaling_lifecycle or not _wants_signaling:
			return "signaling connect superseded"
		if _backend_connect_owner != 0 and _backend_close_deadline_msec > 0 \
				and Time.get_ticks_msec() >= _backend_close_deadline_msec:
			_backend_blocked_error = "timed out waiting for canceled signaling connect to finish"
			_backend_closing = false
			_backend_close_expected = false
			push_error("CouchWebRTC: " + _backend_blocked_error)
			return _backend_blocked_error
		if _backend_closing and Time.get_ticks_msec() >= _backend_close_deadline_msec:
			_backend_blocked_error = "timed out waiting for signaling backend to close"
			_backend_closing = false
			_backend_close_expected = false
			push_error("CouchWebRTC: " + _backend_blocked_error)
			return _backend_blocked_error
		await get_tree().process_frame
	return _backend_blocked_error


func _release_backend_attempt(attempt: int) -> void:
	if _backend_connect_owner == attempt:
		_backend_connect_owner = 0
		if not _backend_closing and not _backend_connection_open:
			_backend_blocked_error = ""


func _begin_backend_disconnect() -> void:
	if _backend == null:
		return
	var had_physical_owner := _backend_connect_owner != 0 or _backend_connection_open
	is_signaling_connected = false
	_live_backend_attempt = 0
	_backend_connection_open = false
	if had_physical_owner:
		_backend_closing = true
		_backend_close_expected = true
		_backend_close_deadline_msec = Time.get_ticks_msec() \
			+ maxi(1, roundi(signaling_close_timeout_sec * 1000.0))
	_backend.webrtc_disconnect()


func _wait_for_backend_close() -> void:
	while _backend_closing:
		if Time.get_ticks_msec() >= _backend_close_deadline_msec:
			_backend_blocked_error = "timed out disposing canceled signaling connection"
			_backend_closing = false
			_backend_close_expected = false
			push_error("CouchWebRTC: " + _backend_blocked_error)
			return
		await get_tree().process_frame


func _request_signaling_connection(explicit_room_id: String) -> Dictionary:
	var raw: Dictionary = await _backend.webrtc_connect_signaling(explicit_room_id)
	if not raw.get("success", false):
		# The web bridge reports failures under "message"; backends under "error".
		var reason := str(raw.get("message", raw.get("error", "connect failed")))
		return {"success": false, "error": reason}
	var payload: Dictionary = raw.get("payload") if raw.get("payload") is Dictionary else {}
	var servers: Variant = payload.get("iceServers", [])
	if payload.has("iceServers") and not (servers is Array):
		push_warning("CouchWebRTC: connect response iceServers was %s, not Array — falling back to empty" % type_string(typeof(servers)))
	return {
		"success": true,
		"peer_id": str(payload.get("peerId", "")),
		"room_id": str(payload.get("roomId", "")),
		"ice_servers": (servers as Array).duplicate(true) if servers is Array else [],
	}


func _apply_signaling_connection(result: Dictionary, publish_ice_update: bool) -> void:
	local_peer_id = str(result.get("peer_id", ""))
	room_id = str(result.get("room_id", ""))
	var servers: Variant = result.get("ice_servers", [])
	_set_ice_servers((servers as Array) if servers is Array else [], publish_ice_update)
	# Warned rather than swallowed: an empty ICE list means no STUN/TURN,
	# so any player on a restrictive network fails to connect with nothing
	# in the log pointing at why.
	if ice_servers.is_empty():
		push_warning("CouchWebRTC: no ICE servers available — connections will fail on any network that needs STUN/TURN")
	is_signaling_connected = true


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


## Leave the signaling room. Existing WebRTC peer connections stay up; this only
## tears down the handshake channel.
func disconnect_signaling() -> void:
	_wants_signaling = false
	_signaling_lifecycle += 1
	_active_reconnect_loop = 0
	is_signaling_connected = false
	_begin_backend_disconnect()


## True when WebRTC path stats are observable, i.e. a web export with the SDK
## probe installed. False in the editor and in native builds, where
## get_connection_paths() always returns [].
func is_path_probe_available() -> bool:
	return _PathProbe.is_available()


## Snapshot of every live peer connection's selected candidate pair. Each
## entry:
##   ufrag          String  local ICE ufrag, the peer-correlation key
##   state          String  RTCPeerConnection.connectionState
##   selected       bool    a succeeded+nominated candidate pair exists
##   protocol       String  "udp" | "tcp" | ""
##   relay_protocol String  "udp" | "tcp" | "tls" | "" (relay candidates only)
##   local_type     String  "host"|"srflx"|"prflx"|"relay"|""
##   remote_type    String  same, for the remote candidate
##   is_datagram    bool    protocol=="udp" and relay_protocol in ["","udp"],
##                          i.e. safe for rollback netcode (a TCP path reports
##                          "connected" but head-of-line-blocks GGPO)
## Values are up to ~1s stale (a JS-side cache; candidate pairs only change on
## ICE restart). Read at diagnostics rate, never per frame.
func get_connection_paths() -> Array:
	return _PathProbe.paths()


## Ordered log of every RTCPeerConnection state transition this session, oldest
## first, capped at the last 64. Each entry:
##   ms     int     performance.now() at the transition
##   kind   String  "pc" (connectionState) | "ice" (iceConnectionState)
##   state  String  the new state
##   ufrag  String  local ICE ufrag, "" before a local description exists
## Also written to the browser console as `NETPATH STATE` lines as it happens.
## Entries survive the connection closing, so this is the one path-probe reader
## that still answers questions after a peer is lost — get_connection_paths()
## drops dead connections and reports nothing about how they ended.
func get_connection_state_events() -> Array:
	return _PathProbe.state_events()


func _on_signaling_closed(closed_room_id: String) -> void:
	_backend_close_seq += 1
	if _backend_connect_owner != 0 and _backend_close_deadline_msec <= Time.get_ticks_msec():
		_backend_close_deadline_msec = Time.get_ticks_msec() \
			+ maxi(1, roundi(signaling_close_timeout_sec * 1000.0))
	var was_expected := _backend_close_expected
	_backend_close_expected = false
	_backend_closing = false
	_backend_connection_open = false
	_live_backend_attempt = 0
	_backend_blocked_error = ""
	is_signaling_connected = false
	signaling_closed.emit(closed_room_id)
	if was_expected or _backend_connect_owner != 0 or not auto_reconnect_signaling \
			or not _wants_signaling or _active_reconnect_loop != 0:
		return
	_reconnect_loop_seq += 1
	_active_reconnect_loop = _reconnect_loop_seq
	_reconnect_signaling.call_deferred(_signaling_lifecycle, _active_reconnect_loop)


func _reconnect_signaling(token: int, loop_id: int) -> void:
	if loop_id != _active_reconnect_loop or token != _signaling_lifecycle \
			or not _wants_signaling:
		return
	var attempt := 0
	var delay_sec := maxf(0.01, signaling_reconnect_initial_delay_sec)
	while loop_id == _active_reconnect_loop and token == _signaling_lifecycle \
			and _wants_signaling and not is_signaling_connected:
		await get_tree().create_timer(delay_sec).timeout
		if loop_id != _active_reconnect_loop or token != _signaling_lifecycle \
				or not _wants_signaling:
			break
		attempt += 1
		signaling_reconnecting.emit(room_id, attempt)
		var result: Dictionary = await _connect_once(token, _desired_room_id)
		if loop_id != _active_reconnect_loop or token != _signaling_lifecycle \
				or not _wants_signaling:
			break
		if result.get("success", false) \
				and int(result.get("_backend_attempt", 0)) == _live_backend_attempt:
			_apply_signaling_connection(result, true)
			signaling_reconnected.emit(room_id)
			break
		push_warning("CouchWebRTC: signaling reconnect attempt %d failed: %s" % [
			attempt, str(result.get("error", "connect failed"))])
		delay_sec = minf(signaling_reconnect_max_delay_sec, delay_sec * 2.0)
	if _active_reconnect_loop == loop_id:
		_active_reconnect_loop = 0


func _on_ice_servers_updated(servers: Array) -> void:
	_set_ice_servers(servers, true)


func _set_ice_servers(servers: Array, publish_update: bool) -> void:
	ice_servers = servers.duplicate(true)
	if publish_update:
		ice_servers_updated.emit(ice_servers.duplicate(true))
