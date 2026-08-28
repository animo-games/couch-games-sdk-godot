## Adapts CouchWebRTC to the provider-neutral signaling contract consumed by
## WebRTCMultiplayerConnection.
class_name CouchWebRTCSignalingSource
extends RefCounted

signal sig_received(peer_id: String, data: Variant)
signal peer_joined(peer_id: String)
signal peer_left(peer_id: String)
signal connection_config_updated(config: Dictionary)
## Optional capability: an authoritative room snapshot, in reply to
## request_present_peers().
signal present_peers_updated(peer_ids: Array)

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
	_webrtc.ice_servers_updated.connect(_on_ice_servers_updated)
	_webrtc.peers_updated.connect(_on_peers_updated)


func connect_room() -> Dictionary:
	var adopted := _webrtc.adopt_signaling(_explicit_room_id)
	if not adopted.is_empty():
		return adopted
	return await _webrtc.connect_signaling(_explicit_room_id)


func send(target_peer_id: String, data: Variant) -> void:
	_note_local_ufrag(target_peer_id, data)
	_webrtc.send_signal(target_peer_id, data)


func close() -> void:
	_webrtc.disconnect_signaling()


func get_connection_config() -> Dictionary:
	return {"iceServers": _webrtc.ice_servers.duplicate(true)}


## Optional signaling-source capability consumed by
## WebRTCMultiplayerConnection after connect_room(). This preserves presence
## announcements that arrived before this source existed.
func get_present_peers() -> Array[String]:
	return _webrtc.get_present_peers()


## Optional signaling-source capability. Asks the room who is present; the
## answer arrives on present_peers_updated, or never, if the platform build
## predates the snapshot. Callers must not block on it.
func request_present_peers() -> void:
	_webrtc.request_peers()


func get_path_for_peer(peer_id: String) -> Dictionary:
	var ufrag := str(_peer_ufrags.get(peer_id, ""))
	if ufrag.is_empty():
		return {}
	for entry_v in _webrtc.get_connection_paths():
		if entry_v is Dictionary and str((entry_v as Dictionary).get("ufrag", "")) == ufrag:
			return (entry_v as Dictionary).duplicate(true)
	return {}


func _on_signal_received(sender_peer_id: String, data: Variant) -> void:
	sig_received.emit(sender_peer_id, data)


func _on_peer_present(peer_id: String) -> void:
	peer_joined.emit(peer_id)


func _on_peer_left(peer_id: String) -> void:
	_peer_ufrags.erase(peer_id)
	peer_left.emit(peer_id)


func _on_ice_servers_updated(servers: Array) -> void:
	connection_config_updated.emit({"iceServers": servers.duplicate(true)})


func _on_peers_updated(peer_ids: Array) -> void:
	present_peers_updated.emit(peer_ids)


func _note_local_ufrag(peer_id: String, data: Variant) -> void:
	if not (data is Dictionary):
		return
	var envelope := data as Dictionary
	if str(envelope.get("kind", "")) != "sdp":
		return
	var sdp: Variant = envelope.get("sdp")
	if not (sdp is String):
		return
	var ufrag := _parse_ice_ufrag(sdp)
	if not ufrag.is_empty():
		_peer_ufrags[peer_id] = ufrag


static func _parse_ice_ufrag(sdp: String) -> String:
	for line in sdp.split("\n", false):
		var normalized := line.strip_edges()
		if normalized.begins_with("a=ice-ufrag:"):
			return normalized.trim_prefix("a=ice-ufrag:")
	return ""
