## G23: CouchRollbackAdapter turns a rollback game's connection signals into
## CouchConnection states (step 7 of docs/plans/standard-connection-design.md).
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_rollback_adapter.gd
##
## Real code under test: CouchRollbackAdapter and CouchConnection. The rollback
## controller and the WebRTC connection are doubles that carry only the signal
## names and arguments of RollbackSessionController (the rollback addon) and
## WebRTCMultiplayerConnection (webrtc/), which is all the adapter reads. Time
## is explicit.
##
##   A1  the first segment makes both peers live; later segments (level
##       transitions) report nothing.
##   A2  a link rebuild is reconnecting (link-rebuild), once, then live again;
##       the overlay says so after a second.
##   A3  a failure ends connection-lost and keeps the raw reason; only the
##       first failure counts.
##   A4  a failure after the host left ends host-left off the web, and is the
##       platform's host-away on the web.
##   A5  a failure before the first segment still ends the connection.
##   A6  recovery signals before the first segment are ignored.
##   A7  close() ends left and lets go of every signal.
##   A8  with no link given, the controller's transport is used.
##   A9  player states come from the lobby as for any game.
##   A10 bind() twice rebinds cleanly.
##
## Exit codes: 0 = every check passed, 1 = at least one failed.
extends SceneTree

var _failures := 0
var _checks := 0


func _initialize() -> void:
	print("== G23 rollback adapter ==")
	_case_a1_first_segment_live()
	_case_a2_link_rebuild()
	_case_a3_failure()
	_case_a4_host_left()
	_case_a5_failure_before_start()
	_case_a6_recovery_before_start()
	_case_a7_close()
	_case_a8_transport_from_controller()
	_case_a9_player_states()
	_case_a10_rebind()
	if _failures == 0:
		print("COUCH_ROLLBACK_ADAPTER_OK: %d check(s)" % _checks)
	else:
		printerr("G23 rollback adapter: %d of %d checks FAILED" % [_failures, _checks])
	quit(0 if _failures == 0 else 1)


# --- harness -------------------------------------------------------------------

## A peer: `me` is "host" or "g1". Off the web unless `platform` says so.
func _make(me: String, platform: String = "mock", with_link: bool = true) -> Dictionary:
	var lobby := _Lobby.new(me)
	lobby.am_host = me == "host"
	lobby.rows = _rows()
	var controller := _Controller.new()
	var link: _Link = _Link.new() if with_link else null
	if not with_link:
		controller.transport = _Link.new()
	var adapter := CouchRollbackAdapter.new()
	adapter.platform = platform
	adapter.log_enabled = false
	adapter.overlay_enabled = false
	var states: Array = []
	adapter.poll(0)
	adapter.bind(controller, link, lobby)
	adapter.connection.state_changed.connect(func(s: String, r: String) -> void: states.append([s, r]))
	return {"a": adapter, "c": controller, "k": link if with_link else controller.transport, "l": lobby, "states": states}


func _rows(host_status: String = "playing", guest_status: String = "playing") -> Array:
	return [
		{"user_id": "host", "username": "Hana", "role": "host", "status": host_status},
		{"user_id": "g1", "username": "Gus", "role": "guest", "status": guest_status},
	]


func _start(u: Dictionary) -> void:
	(u["c"] as _Controller).segment_started.emit(0, RefCounted.new())


func _state(u: Dictionary) -> String:
	return (u["a"] as CouchRollbackAdapter).connection.state


func _free(u: Dictionary) -> void:
	(u["a"] as CouchRollbackAdapter).free()


# --- cases -----------------------------------------------------------------------

func _case_a1_first_segment_live() -> void:
	for me in ["host", "g1"]:
		var u := _make(me)
		var a: CouchRollbackAdapter = u["a"]
		_check(_state(u) == CouchConnection.STATE_CONNECTING, "A1 %s: connecting before the first segment" % me)
		var started: Array = []
		a.session_started.connect(func(epoch: int, is_host: bool, slot: int, peer: String, peer_name: String) -> void: started.append([epoch, is_host, slot, peer, peer_name]))
		_start(u)
		_check(_state(u) == CouchConnection.STATE_LIVE, "A1 %s: live at the first segment, with no snapshot to wait for (got %s)" % [me, _state(u)])
		var peer := "g1" if me == "host" else "host"
		var peer_name := "Gus" if me == "host" else "Hana"
		_check(started == [[0, me == "host", 0 if me == "host" else 1, peer, peer_name]], "A1 %s: session_started names the role, slot and other player (got %s)" % [me, started])
		_check(a.connection.is_host == (me == "host"), "A1 %s: the connection knows the role" % me)
		(u["c"] as _Controller).segment_started.emit(1, RefCounted.new())
		_check(started.size() == 1 and u["states"] == [[CouchConnection.STATE_LIVE, ""]], "A1 %s: a level transition reports nothing (got %s)" % [me, u["states"]])
		_free(u)


func _case_a2_link_rebuild() -> void:
	var u := _make("g1")
	var a: CouchRollbackAdapter = u["a"]
	var k: _Link = u["k"]
	var stops: Array = []
	a.session_stopped.connect(func(r: String) -> void: stops.append(r))
	_start(u)
	a.poll(1000)
	k.peer_recovery_started.emit("host", 1)
	k.peer_recovery_started.emit("host", 1)
	_check(stops == [CouchRollbackAdapter.STOP_LINK_REBUILD], "A2 one link-rebuild stop per rebuild (got %s)" % [stops])
	_check(_state(u) == CouchConnection.STATE_RECONNECTING and a.connection.reason == CouchRollbackAdapter.STOP_LINK_REBUILD, "A2 reconnecting (link-rebuild) (got %s / %s)" % [_state(u), a.connection.reason])
	a.poll(1500)
	_check(a.connection.overlay_lines().is_empty(), "A2 nothing on the overlay for the first second")
	a.poll(2100)
	_check(a.connection.overlay_lines() == ["Reconnecting…"], "A2 the overlay says Reconnecting… after a second (got %s)" % [a.connection.overlay_lines()])
	k.peer_recovered.emit("host", 1, 1100)
	_check(_state(u) == CouchConnection.STATE_LIVE, "A2 live again when the link is back")
	k.peer_recovered.emit("host", 1, 1100)
	_check(u["states"].size() == 3, "A2 a second recovered changes nothing (got %s)" % [u["states"]])
	k.peer_recovery_started.emit("host", 1)
	k.peer_recovered.emit("host", 1, 300)
	_check(u["states"].size() == 5 and _state(u) == CouchConnection.STATE_LIVE, "A2 a second rebuild goes round again (got %s)" % [u["states"]])
	_free(u)


func _case_a3_failure() -> void:
	var u := _make("host")
	var a: CouchRollbackAdapter = u["a"]
	_start(u)
	(u["c"] as _Controller).segment_failed.emit("session_failed: peer lost: g1")
	_check(_state(u) == CouchConnection.STATE_ENDED and a.connection.end_reason == CouchConnection.END_CONNECTION_LOST, "A3 a failure ends connection-lost (got %s / %s)" % [_state(u), a.connection.end_reason])
	_check(a.failure_reason == "session_failed: peer lost: g1", "A3 the raw reason is kept (got %s)" % a.failure_reason)
	(u["k"] as _Link).transport_failed.emit("later")
	_check(a.failure_reason == "session_failed: peer lost: g1" and u["states"].size() == 2, "A3 only the first failure counts")
	_free(u)
	u = _make("g1")
	_start(u)
	(u["k"] as _Link).transport_failed.emit("peer host connect timeout")
	_check(_state(u) == CouchConnection.STATE_ENDED and (u["a"] as CouchRollbackAdapter).failure_reason == "peer host connect timeout", "A3 a transport failure ends it too")
	_check((u["a"] as CouchRollbackAdapter).connection.end_reason == CouchConnection.END_CONNECTION_LOST, "A3 with the host still in the lobby a guest's failure is connection-lost, not host-left (got %s)" % (u["a"] as CouchRollbackAdapter).connection.end_reason)
	_free(u)


func _case_a4_host_left() -> void:
	var u := _make("g1")
	_start(u)
	(u["l"] as _Lobby).set_rows([_rows()[1]])
	(u["c"] as _Controller).segment_failed.emit("session_failed: peer lost: host")
	_check((u["a"] as CouchRollbackAdapter).connection.end_reason == CouchConnection.END_HOST_LEFT, "A4 off the web: the host left (got %s)" % (u["a"] as CouchRollbackAdapter).connection.end_reason)
	_free(u)
	u = _make("g1", "web")
	_start(u)
	(u["l"] as _Lobby).set_rows([_rows()[1]])
	(u["c"] as _Controller).segment_failed.emit("session_failed: peer lost: host")
	_check(_state(u) == CouchConnection.STATE_RECONNECTING and (u["a"] as CouchRollbackAdapter).connection.reason == CouchConnection.REASON_HOST_AWAY, "A4 on the web: the host is away, as the platform shows it (got %s / %s)" % [_state(u), (u["a"] as CouchRollbackAdapter).connection.reason])
	_free(u)
	# A guest that left, seen by the host: not host-left.
	u = _make("host")
	_start(u)
	(u["l"] as _Lobby).set_rows([_rows()[0]])
	(u["c"] as _Controller).segment_failed.emit("session_failed: peer lost: g1")
	_check((u["a"] as CouchRollbackAdapter).connection.end_reason == CouchConnection.END_CONNECTION_LOST, "A4 the host whose guest left ends connection-lost")
	_free(u)


func _case_a5_failure_before_start() -> void:
	var u := _make("g1")
	(u["c"] as _Controller).segment_failed.emit("timeout waiting for transport_ready")
	_check(_state(u) == CouchConnection.STATE_ENDED and (u["a"] as CouchRollbackAdapter).connection.end_reason == CouchConnection.END_CONNECTION_LOST, "A5 a failure before the first segment ends connection-lost (got %s)" % _state(u))
	_free(u)


func _case_a6_recovery_before_start() -> void:
	var u := _make("g1")
	(u["k"] as _Link).peer_recovery_started.emit("host", 1)
	(u["k"] as _Link).peer_recovered.emit("host", 1, 10)
	_check(_state(u) == CouchConnection.STATE_CONNECTING and u["states"].is_empty(), "A6 recovery before the first segment is ignored (got %s)" % [u["states"]])
	_start(u)
	_check(_state(u) == CouchConnection.STATE_LIVE, "A6 and the first segment still makes it live")
	_free(u)


func _case_a7_close() -> void:
	var u := _make("g1")
	var a: CouchRollbackAdapter = u["a"]
	var c: _Controller = u["c"]
	var k: _Link = u["k"]
	var l: _Lobby = u["l"]
	_start(u)
	var old := a.connection
	a.close()
	_check(old.state == CouchConnection.STATE_ENDED and old.end_reason == CouchConnection.END_LEFT, "A7 close() ends left")
	var still := 0
	for pair in [[c, "segment_started"], [c, "segment_failed"], [k, "peer_recovery_started"], [k, "peer_recovered"], [k, "transport_failed"], [l, "players_changed"]]:
		still += (pair[0] as Object).get_signal_connection_list(pair[1]).size()
	_check(still == 0, "A7 every signal is released (%d left)" % still)
	k.peer_recovery_started.emit("host", 1)
	_check(old.state == CouchConnection.STATE_ENDED, "A7 nothing after close() changes it")
	_free(u)


func _case_a8_transport_from_controller() -> void:
	var u := _make("g1", "mock", false)
	_start(u)
	(u["k"] as _Link).peer_recovery_started.emit("host", 1)
	_check(_state(u) == CouchConnection.STATE_RECONNECTING, "A8 the controller's transport is read when no link is given")
	_free(u)


func _case_a9_player_states() -> void:
	var u := _make("host")
	var a: CouchRollbackAdapter = u["a"]
	_start(u)
	(u["l"] as _Lobby).set_rows(_rows("playing", "disconnected"))
	a.poll(5000)
	_check(a.connection.get_player_state("g1") == CouchConnection.PLAYER_CONNECTED, "A9 an away guest is not away for 10 s")
	a.poll(10_001)
	_check(a.connection.get_player_state("g1") == CouchConnection.PLAYER_AWAY, "A9 then it is away")
	_free(u)


func _case_a10_rebind() -> void:
	var u := _make("g1")
	var a: CouchRollbackAdapter = u["a"]
	_start(u)
	var first := a.connection
	var c2 := _Controller.new()
	var k2 := _Link.new()
	a.bind(c2, k2, u["l"])
	_check(a.connection != first and a.connection.state == CouchConnection.STATE_CONNECTING, "A10 a second bind starts a fresh connection")
	_check(not is_instance_valid(first) and a.get_child_count() == 1, "A10 the old connection is freed (children: %d)" % a.get_child_count())
	(u["k"] as _Link).peer_recovery_started.emit("host", 1)
	_check(a.connection.state == CouchConnection.STATE_CONNECTING, "A10 the old link is no longer read")
	c2.segment_started.emit(0, RefCounted.new())
	_check(a.connection.state == CouchConnection.STATE_LIVE, "A10 the new controller is")
	_free(u)


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("  PASS: " + label)
	else:
		_failures += 1
		printerr("  FAIL: " + label)


# --- doubles -----------------------------------------------------------------------

## RollbackSessionController's signals (addons/rollback/net/session_controller.gd).
class _Controller extends RefCounted:
	signal segment_started(seg_index: int, session: Object)
	signal segment_failed(reason: String)
	signal peer_ready(peer_id: String)
	var transport: Object = null


## WebRTCMultiplayerConnection's signals (webrtc/webrtc_multiplayer_connection.gd).
class _Link extends RefCounted:
	signal peer_ready(peer_id: String, net_id: int)
	signal peer_lost(peer_id: String, net_id: int)
	signal peer_recovery_started(peer_id: String, net_id: int)
	signal peer_recovered(peer_id: String, net_id: int, duration_ms: int)
	signal transport_failed(reason: String)


class _Lobby extends RefCounted:
	signal players_changed(players: Array)
	var rows: Array = []
	var me_id: String
	var am_host: bool = false

	func _init(me: String) -> void:
		me_id = me

	func set_rows(value: Array) -> void:
		rows = value
		players_changed.emit(rows)

	func get_players() -> Array:
		return rows

	func get_me() -> Variant:
		return {"user_id": me_id}

	func is_host() -> bool:
		return am_host
