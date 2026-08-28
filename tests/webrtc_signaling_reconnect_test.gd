# Focused regression test for CouchWebRTC signaling lifecycle recovery. Run:
#   godot --headless --path Project -s res://addons/couch-games-sdk/tests/webrtc_signaling_reconnect_test.gd
extends SceneTree

var _failed := false
var _outcomes: Dictionary = {}


## Deliberately adversarial backend: disconnecting a pending connect does NOT
## cancel its eventual result. CouchWebRTC must serialize and dispose that late
## success without ever disconnecting a replacement connection.
class StubBackend extends CouchGamesBackend:
	var connect_calls := 0
	var joined := false
	var active_call := 0
	var active_room := ""
	var released: Dictionary = {}  # call:int -> success:bool
	var closed_calls: Array[int] = []

	func webrtc_is_available() -> bool:
		return true

	func webrtc_connect_signaling(requested_room_id: String) -> Dictionary:
		connect_calls += 1
		var call := connect_calls
		while not released.has(call):
			await get_tree().process_frame
		if not bool(released[call]):
			return {"success": false, "error": "injected connect failure"}
		joined = true
		active_call = call
		active_room = requested_room_id
		return {"success": true, "payload": {
			"peerId": "local-peer",
			"roomId": requested_room_id,
			"iceServers": [{"urls": "stun:test-%d.invalid" % call}],
		}}

	func webrtc_disconnect() -> void:
		if not joined:
			return
		closed_calls.append(active_call)
		var closed_room := active_room
		joined = false
		active_call = 0
		active_room = ""
		webrtc_signaling_closed.emit(closed_room)

	func release(call: int, success: bool = true) -> void:
		released[call] = success

	func drop_unexpectedly() -> void:
		var closed_room := active_room
		joined = false
		active_call = 0
		active_room = ""
		webrtc_signaling_closed.emit(closed_room)

	func close_during_connect(room: String) -> void:
		webrtc_signaling_closed.emit(room)


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	await _check_cancel_during_initial_connect()
	await _check_cancel_during_automatic_reconnect()
	await _check_overlapping_connects()
	await _check_close_during_in_flight_connect()
	await _check_stuck_canceled_connect_fails_closed_then_recovers()
	await process_frame
	if _failed:
		quit(1)
		return
	print("WEBRTC_SIGNALING_RECONNECT_TEST: PASS")
	quit(0)


func _new_pair() -> Array:
	var backend := StubBackend.new()
	var webrtc := CouchWebRTC.new()
	webrtc.signaling_reconnect_initial_delay_sec = 0.01
	webrtc.signaling_reconnect_max_delay_sec = 0.02
	webrtc.signaling_close_timeout_sec = 0.25
	root.add_child(backend)
	root.add_child(webrtc)
	webrtc.setup(backend)
	return [backend, webrtc]


func _capture_connect(key: String, webrtc: CouchWebRTC, room: String) -> void:
	_outcomes[key] = await webrtc.connect_signaling(room)


func _wait_until(cond: Callable, what: String, timeout_msec: int = 1000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while not bool(cond.call()) and Time.get_ticks_msec() < deadline:
		await process_frame
	if not bool(cond.call()):
		_expect(false, true, "timed out waiting for " + what)
		return false
	return true


func _free_pair(pair: Array) -> void:
	(pair[1] as CouchWebRTC).free()
	(pair[0] as StubBackend).free()


func _check_cancel_during_initial_connect() -> void:
	var pair := _new_pair()
	var backend := pair[0] as StubBackend
	var webrtc := pair[1] as CouchWebRTC
	var key := "cancel-initial"
	_capture_connect(key, webrtc, "room-initial")
	await _wait_until(func() -> bool: return backend.connect_calls == 1, "initial backend call")
	webrtc.disconnect_signaling()
	backend.release(1, true)  # succeeds after cancellation: the adversarial case
	await _wait_until(func() -> bool: return _outcomes.has(key), "canceled initial result")
	_expect(bool((_outcomes[key] as Dictionary).get("success", true)), false,
		"cancel during initial connect must not succeed")
	_expect(backend.joined, false, "late initial success must be disconnected")
	_expect(backend.closed_calls, [1], "late initial connection must close exactly itself")
	_expect(webrtc.is_signaling_connected, false, "canceled initial connect must stay disconnected")
	_free_pair(pair)


func _check_cancel_during_automatic_reconnect() -> void:
	var pair := _new_pair()
	var backend := pair[0] as StubBackend
	var webrtc := pair[1] as CouchWebRTC
	var key := "reconnect-initial"
	_capture_connect(key, webrtc, "room-reconnect")
	backend.release(1)
	await _wait_until(func() -> bool: return _outcomes.has(key), "initial reconnect setup")
	_expect(bool((_outcomes[key] as Dictionary).get("success", false)), true,
		"reconnect setup connection must succeed")

	backend.drop_unexpectedly()
	await _wait_until(func() -> bool: return backend.connect_calls == 2, "automatic reconnect call")
	webrtc.disconnect_signaling()
	backend.release(2, true)
	await _wait_until(func() -> bool: return backend.closed_calls.has(2), "late reconnect cleanup")
	await create_timer(0.05).timeout
	_expect(backend.connect_calls, 2, "disconnect must stop the automatic reconnect loop")
	_expect(backend.joined, false, "late reconnect success must be disconnected")
	_expect(webrtc.is_signaling_connected, false, "canceled reconnect must stay disconnected")
	_free_pair(pair)


func _check_overlapping_connects() -> void:
	var pair := _new_pair()
	var backend := pair[0] as StubBackend
	var webrtc := pair[1] as CouchWebRTC
	var first_key := "overlap-first"
	var second_key := "overlap-second"
	_capture_connect(first_key, webrtc, "room-old")
	await _wait_until(func() -> bool: return backend.connect_calls == 1, "first overlapping call")
	_capture_connect(second_key, webrtc, "room-new")
	await process_frame
	_expect(backend.connect_calls, 1, "replacement backend connect must wait for the old call")

	backend.release(1, true)
	await _wait_until(func() -> bool: return backend.connect_calls == 2, "serialized replacement call")
	backend.release(2, true)
	await _wait_until(func() -> bool: return _outcomes.has(first_key) and _outcomes.has(second_key),
		"both overlapping results")
	_expect(bool((_outcomes[first_key] as Dictionary).get("success", true)), false,
		"superseded connect must fail")
	_expect(bool((_outcomes[second_key] as Dictionary).get("success", false)), true,
		"latest connect must succeed")
	_expect(backend.active_call, 2, "stale cleanup must not close the replacement")
	_expect(backend.closed_calls, [1], "only the stale physical connection must be closed")
	_expect(webrtc.room_id, "room-new", "latest room must own signaling state")
	webrtc.disconnect_signaling()
	_free_pair(pair)


func _check_close_during_in_flight_connect() -> void:
	var pair := _new_pair()
	var backend := pair[0] as StubBackend
	var webrtc := pair[1] as CouchWebRTC
	var key := "close-in-flight"
	_capture_connect(key, webrtc, "room-close")
	await _wait_until(func() -> bool: return backend.connect_calls == 1, "close-in-flight call")
	backend.close_during_connect("room-close")
	backend.release(1, true)
	await _wait_until(func() -> bool: return _outcomes.has(key), "close-in-flight result")
	_expect(bool((_outcomes[key] as Dictionary).get("success", true)), false,
		"a connect closed while pending must not become live")
	_expect(backend.joined, false, "ambiguous late success after close must be disposed")
	_expect(backend.connect_calls, 1, "initial close during connect must not start auto reconnect")
	_free_pair(pair)


func _check_stuck_canceled_connect_fails_closed_then_recovers() -> void:
	var pair := _new_pair()
	var backend := pair[0] as StubBackend
	var webrtc := pair[1] as CouchWebRTC
	webrtc.signaling_close_timeout_sec = 0.05
	var stale_key := "stuck-old"
	var blocked_key := "stuck-replacement"
	_capture_connect(stale_key, webrtc, "room-stuck-old")
	await _wait_until(func() -> bool: return backend.connect_calls == 1, "stuck backend call")
	_capture_connect(blocked_key, webrtc, "room-stuck-new")
	await _wait_until(func() -> bool: return _outcomes.has(blocked_key),
		"replacement to fail closed", 500)
	_expect(bool((_outcomes[blocked_key] as Dictionary).get("success", true)), false,
		"replacement must fail rather than overlap a stuck canceled connect")
	_expect(str((_outcomes[blocked_key] as Dictionary).get("error", "")).contains("timed out"), true,
		"stuck-owner failure must explain its close timeout")
	_expect(backend.connect_calls, 1, "fail-closed replacement must not reach the backend")

	# Once the stale coroutine eventually finishes, its physical socket is
	# disposed behind the same owner slot and a later request can proceed.
	backend.release(1, true)
	await _wait_until(func() -> bool: return _outcomes.has(stale_key), "stuck stale cleanup")
	_expect(backend.closed_calls, [1], "eventual stale success must close itself")
	var recovered_key := "stuck-recovered"
	_capture_connect(recovered_key, webrtc, "room-after-stuck")
	await _wait_until(func() -> bool: return backend.connect_calls == 2, "post-stuck backend call")
	backend.release(2, true)
	await _wait_until(func() -> bool: return _outcomes.has(recovered_key), "post-stuck result")
	_expect(bool((_outcomes[recovered_key] as Dictionary).get("success", false)), true,
		"coordinator must recover after the stale owner finally drains")
	webrtc.disconnect_signaling()
	_free_pair(pair)


func _expect(actual: Variant, expected: Variant, what: String) -> void:
	if actual != expected:
		print("WEBRTC_SIGNALING_RECONNECT_TEST: FAIL %s (got %s, expected %s)" % [
			what, str(actual), str(expected)])
		_failed = true
