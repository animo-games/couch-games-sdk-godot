## Signaling adapter for the `rollback` addon (github.com/animo-games/rollback-godot),
## backed by the SDK's CouchWebRTC node. The game constructs this with the node it
## gets from CouchGames.webrtc and hands it to RollbackTransport.start() /
## RollbackSessionController.begin().
##
## Deliberately does NOT `extends RollbackSignalingAdapter`. This addon ships in
## games that do not install the rollback addon, where that base class does not
## exist and naming it would be an unresolvable-base parse error in every one of
## them. The rollback addon's contract is duck-typed for exactly this reason:
## connect_room()/send()/close() plus sig_received/peer_joined/peer_left, checked
## at runtime by RollbackSignalingAdapter.implements(). Keep this file in sync
## with that contract; nothing here may reference the rollback addon.
##
## peer_exists and peer_joined both surface as peer_joined here: the transport
## treats a peer that was already in the room and one that joins after us
## identically (build a connection either way).
##
## `explicit_room_id` picks the signaling room connect_room() joins: empty =
## the platform's default lobby room; non-empty = an explicit room (menu
## host/join-code flow, e.g. CouchWebRTC.room_id_for_code). Reconnecting to a
## room the peer is already in is safe: the signaling server dedups by peerId (a
## new socket with the same peerId replaces the old one) and re-announces peer
## presence.
class_name CouchRollbackSignalingAdapter
extends RefCounted

## A handshake blob from another peer, after a JSON round-trip. Ints arrive as
## floats — cast with int() before using a numeric field.
signal sig_received(peer_id: String, data: Variant)
## A peer is present in the signaling room (already there or just joined).
signal peer_joined(peer_id: String)
## A peer left the signaling room.
signal peer_left(peer_id: String)

var _webrtc: CouchWebRTC
var _explicit_room_id := ""
var _peer_ufrags: Dictionary = {}


func _init(webrtc: CouchWebRTC, explicit_room_id: String = "") -> void:
	_webrtc = webrtc
	_explicit_room_id = explicit_room_id
	_webrtc.signal_received.connect(_on_signal_received)
	_webrtc.peer_exists.connect(_on_peer_present)
	_webrtc.peer_joined.connect(_on_peer_present)
	_webrtc.peer_left.connect(_on_peer_left)


## Join the signaling room. Async — await the result. Returns
## {success, error?, peer_id?, room_id?, ice_servers?}.
func connect_room() -> Dictionary:
	return await _webrtc.connect_signaling(_explicit_room_id)


## Relay an opaque JSON-serializable blob to one peer. Best-effort: unknown or
## disconnected targets are dropped silently, so drive retries off connection
## state, not this channel.
func send(target_peer_id: String, data: Variant) -> void:
	_note_local_ufrag(target_peer_id, data)
	_webrtc.send_signal(target_peer_id, data)


## Leave the signaling room. Existing WebRTC peer connections are unaffected.
func close() -> void:
	_webrtc.disconnect_signaling()


## The selected candidate pair for one peer, or {} when unknown (no local
## SDP seen yet, native build, or no probe). Payload shape: see
## CouchWebRTC.get_connection_paths().
func get_path_for_peer(peer_id: String) -> Dictionary:
	var ufrag := str(_peer_ufrags.get(peer_id, ""))
	if ufrag == "":
		return {}
	for entry in _webrtc.get_connection_paths():
		if entry is Dictionary and str(entry.get("ufrag", "")) == ufrag:
			return entry
	return {}


func _on_signal_received(sender_peer_id: String, data: Variant) -> void:
	sig_received.emit(sender_peer_id, data)


func _on_peer_present(peer_id: String) -> void:
	peer_joined.emit(peer_id)


func _on_peer_left(peer_id: String) -> void:
	_peer_ufrags.erase(peer_id)
	peer_left.emit(peer_id)


# The rollback transport relays each peer's LOCAL session description
# through send() (rollback_transport.gd _on_session_description_created).
# Its ICE ufrag is the key that ties a peer id to a probe entry. Read-only
# sniff — the blob is still forwarded unchanged.
func _note_local_ufrag(peer_id: String, data: Variant) -> void:
	if not (data is Dictionary):
		return
	var d: Dictionary = data
	if str(d.get("kind", "")) != "sdp":
		return
	var sdp: Variant = d.get("sdp")
	if not (sdp is String):
		return
	var ufrag := _parse_ice_ufrag(sdp)
	if ufrag != "":
		_peer_ufrags[peer_id] = ufrag


static func _parse_ice_ufrag(sdp: String) -> String:
	for line in sdp.split("\n", false):
		var l := line.strip_edges()
		if l.begins_with("a=ice-ufrag:"):
			return l.substr("a=ice-ufrag:".length())
	return ""
