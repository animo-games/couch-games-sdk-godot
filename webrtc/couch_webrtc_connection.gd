## Convenient Couch Games façade over the provider-neutral WebRTC mesh.
class_name CouchWebRTCConnection
extends WebRTCMultiplayerConnection

var _webrtc: CouchWebRTC
var _explicit_room_id := ""
var _couch_source: CouchWebRTCSignalingSource
var _owns_handler := false


func _init(webrtc: CouchWebRTC = null, explicit_room_id: String = "") -> void:
	_webrtc = webrtc
	_explicit_room_id = explicit_room_id
	if _webrtc != null:
		_couch_source = CouchWebRTCSignalingSource.new(_webrtc, _explicit_room_id)


func configure(webrtc: CouchWebRTC, explicit_room_id: String = "") -> void:
	_webrtc = webrtc
	_explicit_room_id = explicit_room_id
	_couch_source = CouchWebRTCSignalingSource.new(_webrtc, _explicit_room_id)


func get_signaling_source() -> CouchWebRTCSignalingSource:
	return _couch_source


func start(signaling_source = null, multiplayer_api: MultiplayerAPI = null) -> void:
	if signaling_source != null and not (signaling_source is CouchWebRTC):
		super.start(signaling_source, multiplayer_api)
		return
	var selected := signaling_source as CouchWebRTC \
		if signaling_source is CouchWebRTC else _webrtc
	if selected == null:
		_fail_connection("CouchWebRTCConnection has no CouchWebRTC source")
		return
	if not selected.claim_connection_handler(self):
		_fail_connection("CouchWebRTC already has an active connection handler")
		return
	_webrtc = selected
	_owns_handler = true
	if _couch_source == null:
		_couch_source = CouchWebRTCSignalingSource.new(_webrtc, _explicit_room_id)
	super.start(_couch_source, multiplayer_api)


func stop() -> void:
	super.stop()
	_release_handler()


func _fail_connection(reason: String) -> void:
	super._fail_connection(reason)
	_release_handler()


func _release_handler() -> void:
	if _owns_handler and _webrtc != null:
		_webrtc.release_connection_handler(self)
	_owns_handler = false
