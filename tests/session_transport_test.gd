## Headless test for CouchSessionTransport, the once-at-boot star/lobby seam.
##
##   godot --headless --path Project -s res://addons/couch-games-sdk/tests/session_transport_test.gd
##
## Real under test: CouchSessionTransport, a real CouchLobby and a real
## CouchWebRTC over a stub backend, and -- on the star path -- a real
## CouchStarTransport started against them (create_server(), no peers). The
## backend is the only double: it says whether signaling exists, what
## connect_signaling() answers, and who the local player is.
##
## The star cases need a concrete WebRTC implementation. Without one they are
## reported as FAILs, not skipped, matching the netcode gates: a green run that
## never built a star would be a green tick nobody earned.
extends SceneTree

var _failed := false


class StubBackend extends CouchGamesBackend:
	var webrtc_available := true
	var connect_result: Dictionary = {}       # what webrtc_connect_signaling answers
	var connect_calls := 0
	var disconnect_calls := 0
	var me: Dictionary = {}                   # lobby_get_me()
	var _joined := false

	func webrtc_is_available() -> bool:
		return webrtc_available

	func webrtc_connect_signaling(_room_id: String) -> Dictionary:
		connect_calls += 1
		await get_tree().process_frame
		if bool(connect_result.get("success", false)):
			_joined = true
		return connect_result

	func webrtc_disconnect() -> void:
		disconnect_calls += 1
		if not _joined:
			return
		_joined = false
		webrtc_signaling_closed.emit("room")

	func lobby_is_available() -> bool:
		return true

	func lobby_get_me() -> Dictionary:
		return me


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== CouchSessionTransport ==")
	var available := CouchStarTransport.is_webrtc_available()
	print("is_webrtc_available() = %s" % available)

	_check_resolve_kind(available)
	await _check_lobby_pick()
	await _check_unknown_preference()
	await _check_star_refusals(available)
	await _check_star_success(available)
	await _check_auto(available)

	print("")
	if _failed:
		printerr("SESSION_TRANSPORT_TEST_FAILED")
		quit(1)
	else:
		print("SESSION_TRANSPORT_TEST_OK")
		quit(0)
	return


# ---------------------------------------------------------------------------


## The pure decision table. Both availability branches are spelled out so the
## test states what THIS build resolves rather than assuming a machine.
func _check_resolve_kind(available: bool) -> void:
	_expect(CouchSessionTransport.resolve_kind(CouchSessionTransport.PREFER_LOBBY),
		CouchSessionTransport.KIND_LOBBY, "resolve_kind(lobby) is always lobby")
	_expect(CouchSessionTransport.resolve_kind(CouchSessionTransport.PREFER_STAR),
		CouchSessionTransport.KIND_STAR if available else CouchSessionTransport.KIND_NONE,
		"resolve_kind(star) is star iff a WebRTC implementation is installed, else none (a refusal)")
	_expect(CouchSessionTransport.resolve_kind(CouchSessionTransport.PREFER_AUTO),
		CouchSessionTransport.KIND_STAR if available else CouchSessionTransport.KIND_LOBBY,
		"resolve_kind(auto) is star iff a WebRTC implementation is installed, else lobby")
	_expect(CouchSessionTransport.resolve_kind(), CouchSessionTransport.resolve_kind(CouchSessionTransport.PREFER_AUTO),
		"resolve_kind() defaults to auto")
	_expect(CouchSessionTransport.resolve_kind("mesh"), CouchSessionTransport.KIND_NONE,
		"resolve_kind(<unknown>) is none, never a silent default")


func _check_lobby_pick() -> void:
	var pair := _new_pair({"userId": "host", "username": "Host", "role": "host"})
	var picked: Dictionary = await CouchSessionTransport.pick(pair.lobby, pair.webrtc, CouchSessionTransport.PREFER_LOBBY)
	_expect(picked.kind, CouchSessionTransport.KIND_LOBBY, "pick(lobby): kind == lobby")
	_expect(picked.error, "", "pick(lobby): no error")
	_expect(picked.transport is CouchLobbyTransport, true, "pick(lobby): transport is a CouchLobbyTransport")
	_expect(CouchTransport.implements(picked.transport), true, "pick(lobby): the transport satisfies CouchTransport")
	_expect(picked.transport.has_method("poll"), true, "pick(lobby): the tunnel has poll() so the driver loop is unconditional")
	picked.transport.poll(0)
	_expect(picked.transport.is_ready(), true, "pick(lobby): the tunnel is ready without any start()")
	_expect(pair.backend.connect_calls, 0, "pick(lobby): signaling was never touched")
	var session := CouchSession.new(pair.lobby, picked.transport)
	_expect(session != null, true, "pick(lobby): CouchSession.new() accepts the transport")
	picked.transport.close()
	_free_pair(pair)


func _check_unknown_preference() -> void:
	var pair := _new_pair({"userId": "host", "username": "Host", "role": "host"})
	var picked: Dictionary = await CouchSessionTransport.pick(pair.lobby, pair.webrtc, "mesh")
	_expect(picked.kind, CouchSessionTransport.KIND_NONE, "pick(<unknown>): kind == none")
	_expect(picked.transport, null, "pick(<unknown>): no transport")
	_expect(picked.error, "unknown-preference:mesh", "pick(<unknown>): error names the preference")
	_expect(pair.backend.connect_calls, 0, "pick(<unknown>): signaling was never touched")
	_free_pair(pair)


## Every way a requested star can be refused. None of them may build a
## transport, and every one that joined signaling must have released it.
func _check_star_refusals(available: bool) -> void:
	if not available:
		_expect(false, true, "star refusal cases need a WebRTC implementation (FAIL, not skip)")
		return

	# Backend without signaling: environment, refused -- never demoted to the tunnel.
	var no_sig := _new_pair({"userId": "host", "role": "host"})
	no_sig.backend.webrtc_available = false
	var picked: Dictionary = await CouchSessionTransport.pick(no_sig.lobby, no_sig.webrtc, CouchSessionTransport.PREFER_STAR)
	_expect(picked.kind, CouchSessionTransport.KIND_NONE, "star, backend without signaling: kind == none")
	_expect(picked.transport, null, "star, backend without signaling: no transport (not a lobby tunnel either)")
	_expect(picked.error, CouchSessionTransport.ERROR_SIGNALING_UNAVAILABLE, "star, backend without signaling: error == signaling-unavailable")
	_expect(no_sig.backend.connect_calls, 0, "star, backend without signaling: connect never attempted")
	_free_pair(no_sig)

	# Signaling connect fails: the star's own reason comes through verbatim.
	var bad_connect := _new_pair({"userId": "host", "role": "host"})
	bad_connect.backend.connect_result = {"success": false, "error": "injected connect failure"}
	picked = await CouchSessionTransport.pick(bad_connect.lobby, bad_connect.webrtc, CouchSessionTransport.PREFER_STAR)
	_expect(picked.kind, CouchSessionTransport.KIND_NONE, "star, connect fails: kind == none")
	_expect(picked.transport, null, "star, connect fails: no transport")
	_expect(picked.error, "injected connect failure", "star, connect fails: the backend's reason is passed through")
	_expect(bad_connect.backend.connect_calls, 1, "star, connect fails: exactly one connect attempt")
	_expect(bad_connect.webrtc.is_signaling_connected, false, "star, connect fails: signaling is not left connected")
	_free_pair(bad_connect)

	# Signaling joins but as a peer id the lobby does not know as me: the
	# star's fatal invariant. The membership it opened must be released.
	var mismatch := _new_pair({"userId": "host", "role": "host"})
	mismatch.backend.connect_result = {"success": true, "payload": {"peerId": "stranger", "roomId": "room", "iceServers": []}}
	picked = await CouchSessionTransport.pick(mismatch.lobby, mismatch.webrtc, CouchSessionTransport.PREFER_STAR)
	_expect(picked.kind, CouchSessionTransport.KIND_NONE, "star, peer id != lobby me: kind == none")
	_expect(picked.transport, null, "star, peer id != lobby me: no transport")
	_expect(picked.error, "peer-id-mismatch", "star, peer id != lobby me: the star's own error")
	_expect(mismatch.webrtc.is_signaling_connected, false, "star, peer id != lobby me: the signaling membership the attempt opened was released")
	_expect(mismatch.backend.disconnect_calls >= 1, true, "star, peer id != lobby me: the backend saw a disconnect")
	_free_pair(mismatch)


func _check_star_success(available: bool) -> void:
	if not available:
		_expect(false, true, "star success case needs a WebRTC implementation (FAIL, not skip)")
		return
	var pair := _new_pair({"userId": "host", "username": "Host", "role": "host"})
	pair.backend.connect_result = {"success": true, "payload": {"peerId": "host", "roomId": "room", "iceServers": []}}
	var picked: Dictionary = await CouchSessionTransport.pick(pair.lobby, pair.webrtc, CouchSessionTransport.PREFER_STAR)
	_expect(picked.kind, CouchSessionTransport.KIND_STAR, "star: kind == star")
	_expect(picked.error, "", "star: no error")
	_expect(picked.transport is CouchStarTransport, true, "star: transport is a CouchStarTransport")
	_expect(CouchTransport.implements(picked.transport), true, "star: the transport satisfies CouchTransport")
	_expect(picked.transport.is_host, true, "star: the role was latched from the lobby (host)")
	_expect(picked.transport.local_net_id, CouchStarTransport.HOST_NET_ID, "star: the host's net id is 1")
	_expect(picked.transport.local_peer_id, "host", "star: the local peer id is the signaling peer id == lobby user id")
	_expect(pair.webrtc.is_signaling_connected, true, "star: signaling is connected after pick()")
	_expect(pair.backend.connect_calls, 1, "star: exactly one connect")
	var session := CouchSession.new(pair.lobby, picked.transport)
	_expect(session != null, true, "star: CouchSession.new() accepts the transport")
	picked.transport.poll(0)
	session.poll(0)
	picked.transport.close()
	_expect(pair.webrtc.is_signaling_connected, false, "star: close() releases signaling")
	_free_pair(pair)


## PREFER_AUTO lands on whatever resolve_kind(auto) says for this build, and
## builds exactly that -- the tunnel with signaling untouched, or a started star.
func _check_auto(available: bool) -> void:
	var pair := _new_pair({"userId": "host", "username": "Host", "role": "host"})
	pair.backend.connect_result = {"success": true, "payload": {"peerId": "host", "roomId": "room", "iceServers": []}}
	var picked: Dictionary = await CouchSessionTransport.pick(pair.lobby, pair.webrtc)
	_expect(picked.kind, CouchSessionTransport.resolve_kind(CouchSessionTransport.PREFER_AUTO), "auto: kind == resolve_kind(auto)")
	_expect(picked.error, "", "auto: no error")
	if available:
		_expect(picked.transport is CouchStarTransport, true, "auto (WebRTC installed): transport is a CouchStarTransport")
		_expect(pair.backend.connect_calls, 1, "auto (WebRTC installed): the star joined signaling")
	else:
		_expect(picked.transport is CouchLobbyTransport, true, "auto (no WebRTC): transport is a CouchLobbyTransport")
		_expect(pair.backend.connect_calls, 0, "auto (no WebRTC): signaling was never touched")
	picked.transport.close()
	_free_pair(pair)


# ---------------------------------------------------------------------------


class _Pair extends RefCounted:
	var backend: StubBackend
	var webrtc: CouchWebRTC
	var lobby: CouchLobby


func _new_pair(me: Dictionary) -> _Pair:
	var pair := _Pair.new()
	pair.backend = StubBackend.new()
	pair.backend.me = me
	pair.webrtc = CouchWebRTC.new()
	pair.webrtc.signaling_close_timeout_sec = 0.25
	pair.lobby = CouchLobby.new()
	root.add_child(pair.backend)
	root.add_child(pair.webrtc)
	root.add_child(pair.lobby)
	pair.webrtc.setup(pair.backend)
	pair.lobby.setup(pair.backend)
	# A two-player roster so the lobby's get_host()/get_me() resolve from the
	# live roster, the way they do on the platform.
	pair.backend.lobby_players_updated.emit([
		me, {"userId": "g1", "username": "Guest", "role": "guest", "controllerSlot": 1},
	])
	return pair


func _free_pair(pair: _Pair) -> void:
	pair.lobby.free()
	pair.webrtc.free()
	pair.backend.free()


func _expect(actual: Variant, expected: Variant, what: String) -> void:
	if actual == expected:
		print("  PASS: " + what)
		return
	_failed = true
	printerr("  FAIL: %s (expected %s, got %s)" % [what, expected, actual])
