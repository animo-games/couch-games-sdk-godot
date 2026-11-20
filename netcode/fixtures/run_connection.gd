## G20: CouchConnection, the one connection state every game reports.
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_connection.gd
##
## Real code under test: CouchConnection (and, in E, CouchSession,
## CouchLobbyTransport and CouchEnvelope). The session and lobby are scripted:
## their signals are emitted directly, as CouchSession and CouchLobby emit them.
## Time is explicit: every case drives poll(now_ms), so no check sleeps.
##
##   C  connection states: host, guest, resync reasons, host-left off and on
##      the web, the hold timeout, the lobby's own states, ending once.
##   P  player states: away only after the 10 s quiet stretch, back, gone,
##      newcomers, the local player never reported, the away host on the web.
##   T  player-facing text and the overlay's lines: nothing on the web, delays,
##      every end reason described.
##   W  the hand-wired warning: bind() marks a real CouchSession as bound.
##   E  end to end: a guest whose real session resyncs after a restart goes
##      live -> reconnecting -> syncing -> live.
##
## Exit codes: 0 = every check passed, 1 = at least one failed.
extends SceneTree

const C := preload("res://addons/couch-games-sdk/netcode/connection.gd")

var _failures := 0
var _checks := 0


func _initialize() -> void:
	print("== G20 connection ==")
	_case_c1_host()
	_case_c2_guest_resyncs()
	_case_c3_host_left_off_web()
	_case_c4_host_left_on_web()
	_case_c5_hold_timeout()
	_case_c6_lobby_states()
	_case_c7_stop_reasons()
	_case_c8_close()
	_case_p1_away_after_quiet()
	_case_p2_gone_and_new()
	_case_p3_host_away_on_web()
	_case_t1_text()
	_case_t2_overlay_lines()
	_case_t3_overlay_node()
	_case_w1_bound()
	_case_e1_real_session()
	_case_w2_warns_once_in_a_game()
	if _failures == 0:
		print("COUCH_CONNECTION_OK: %d check(s)" % _checks)
	else:
		printerr("G20 connection: %d of %d checks FAILED" % [_failures, _checks])
	quit(0 if _failures == 0 else 1)


# --- harness -------------------------------------------------------------------

func _make(platform: String, me: String = "g1", rows: Array = []) -> Dictionary:
	var session := _Session.new()
	var lobby := _Lobby.new(me)
	var connection: CouchConnection = C.new()
	connection.platform = platform
	connection.log_enabled = false
	connection.overlay_enabled = false
	var states: Array = []
	var players: Array = []
	connection.state_changed.connect(func(state: String, reason: String) -> void: states.append([state, reason]))
	connection.player_state_changed.connect(func(id: String, state: String) -> void: players.append([id, state]))
	connection.poll(0)
	if not rows.is_empty():
		lobby.rows = rows
	connection.bind(session, lobby)
	return {"c": connection, "s": session, "l": lobby, "states": states, "players": players}


func _rows_host_guest(guest_status: String = "playing") -> Array:
	return [
		{"user_id": "host", "username": "Hana", "role": "host", "status": "playing"},
		{"user_id": "g1", "username": "Gus", "role": "guest", "status": guest_status},
	]


func _start_guest(u: Dictionary) -> void:
	(u["s"] as _Session).session_started.emit(1, false, 1, "host", "Hana")
	(u["s"] as _Session).snapshot_received.emit({"world": 1})


func _last(u: Dictionary) -> Array:
	var states: Array = u["states"]
	return states[-1] if not states.is_empty() else []


func _free(u: Dictionary) -> void:
	(u["c"] as CouchConnection).free()


# --- C: connection states ------------------------------------------------------

func _case_c1_host() -> void:
	var u := _make("mock", "host", _rows_host_guest())
	var c: CouchConnection = u["c"]
	_check(c.state == CouchConnection.STATE_CONNECTING, "C1 a bound connection starts connecting (got %s)" % c.state)
	(u["s"] as _Session).session_started.emit(7, true, 0, "g1", "Gus")
	_check(c.state == CouchConnection.STATE_LIVE, "C1 the host is live as soon as its session starts (got %s)" % c.state)
	_check(c.is_host, "C1 the connection knows it hosts")
	for reason in ["roster-too-small", "authorized-peer-left"]:
		(u["s"] as _Session).session_stopped.emit(reason)
		_check(c.state == CouchConnection.STATE_LIVE, "C1 a host stays live through %s: its world runs on (got %s)" % [reason, c.state])
	(u["s"] as _Session).session_started.emit(8, true, 0, "g2", "Gia")
	_check(u["states"] == [[CouchConnection.STATE_LIVE, ""]], "C1 one state change in all, no repeats (got %s)" % [u["states"]])
	_free(u)


func _case_c2_guest_resyncs() -> void:
	var u := _make("mock", "g1", _rows_host_guest())
	var c: CouchConnection = u["c"]
	var s: _Session = u["s"]
	s.session_started.emit(1, false, 1, "host", "Hana")
	_check(c.state == CouchConnection.STATE_SYNCING, "C2 a guest syncs until its first snapshot (got %s)" % c.state)
	s.snapshot_received.emit({"world": 1})
	_check(c.state == CouchConnection.STATE_LIVE, "C2 the first snapshot makes the guest live (got %s)" % c.state)
	s.snapshot_received.emit({"world": 2})
	_check(u["states"].size() == 2, "C2 later snapshots change nothing (got %s)" % [u["states"]])
	for reason in ["link-reset", "host-restarted", "steam-link-gap", "role-changed"]:
		s.session_stopped.emit(reason)
		_check(_last(u) == [CouchConnection.STATE_RECONNECTING, reason], "C2 %s puts the guest in reconnecting with that reason (got %s)" % [reason, _last(u)])
		s.session_started.emit(2, false, 1, "host", "Hana")
		_check(c.state == CouchConnection.STATE_SYNCING, "C2 after %s the restarted session syncs (got %s)" % [reason, c.state])
		s.snapshot_received.emit({"world": 3})
		_check(c.state == CouchConnection.STATE_LIVE, "C2 after %s the next snapshot makes it live (got %s)" % [reason, c.state])
	_free(u)


func _case_c3_host_left_off_web() -> void:
	for platform in ["mock", "local", "steam"]:
		var u := _make(platform, "g1", _rows_host_guest())
		var c: CouchConnection = u["c"]
		_start_guest(u)
		(u["s"] as _Session).session_stopped.emit("host-left")
		_check(c.state == CouchConnection.STATE_ENDED and c.end_reason == CouchConnection.END_HOST_LEFT, "C3[%s] off the web, host-left ends with host-left (got %s %s)" % [platform, c.state, c.end_reason])
		var count: int = u["states"].size()
		(u["s"] as _Session).session_started.emit(2, false, 1, "host", "Hana")
		(u["s"] as _Session).snapshot_received.emit({})
		c.poll(10_000_000)
		_check(u["states"].size() == count and c.state == CouchConnection.STATE_ENDED, "C3[%s] nothing moves an ended connection (got %s)" % [platform, u["states"]])
		_free(u)


func _case_c4_host_left_on_web() -> void:
	var u := _make("web", "g1", _rows_host_guest())
	var c: CouchConnection = u["c"]
	_start_guest(u)
	(u["l"] as _Lobby).set_rows([_rows_host_guest()[1]])
	(u["s"] as _Session).session_stopped.emit("host-left")
	_check(_last(u) == [CouchConnection.STATE_RECONNECTING, CouchConnection.REASON_HOST_AWAY], "C4 on the web, host-left while still running is the host away (got %s)" % [_last(u)])
	(u["l"] as _Lobby).set_rows(_rows_host_guest())
	(u["s"] as _Session).session_started.emit(1, false, 1, "host", "Hana")
	_check(c.state == CouchConnection.STATE_SYNCING, "C4 the host back restarts the guest's session: syncing (got %s)" % c.state)
	(u["s"] as _Session).snapshot_received.emit({"world": 9})
	_check(c.state == CouchConnection.STATE_LIVE, "C4 and live again on its snapshot (got %s)" % c.state)
	# A guest that loses its own row as well is not the host away.
	var v := _make("web", "g1", _rows_host_guest())
	_start_guest(v)
	(v["s"] as _Session).session_stopped.emit("roster-too-small")
	_check(_last(v) == [CouchConnection.STATE_RECONNECTING, "roster-too-small"], "C4 a guest's roster-too-small on the web waits too (got %s)" % [_last(v)])
	_free(u)
	_free(v)


func _case_c5_hold_timeout() -> void:
	var defaults := {"web": 65_000, "steam": 120_000, "local": 60_000, "mock": 60_000}
	for platform in defaults:
		var u := _make(platform, "g1", _rows_host_guest())
		var c: CouchConnection = u["c"]
		_check(c.hold_ms == defaults[platform], "C5[%s] the hold defaults to %d ms (got %d)" % [platform, defaults[platform], c.hold_ms])
		_start_guest(u)
		c.poll(1000)
		(u["s"] as _Session).session_stopped.emit("link-reset")
		c.poll(1000 + c.hold_ms - 1)
		_check(c.state == CouchConnection.STATE_RECONNECTING, "C5[%s] still reconnecting 1 ms inside the hold (got %s)" % [platform, c.state])
		c.poll(1000 + c.hold_ms)
		_check(c.state == CouchConnection.STATE_ENDED and c.end_reason == CouchConnection.END_RECONNECT_TIMED_OUT, "C5[%s] the hold running out ends reconnect-timed-out (got %s %s)" % [platform, c.state, c.end_reason])
		_free(u)
	# A reconnect that succeeds resets the clock.
	var w := _make("mock", "g1", _rows_host_guest())
	var wc: CouchConnection = w["c"]
	_start_guest(w)
	wc.poll(1000)
	(w["s"] as _Session).session_stopped.emit("link-reset")
	wc.poll(50_000)
	(w["s"] as _Session).session_started.emit(2, false, 1, "host", "Hana")
	(w["s"] as _Session).snapshot_received.emit({})
	wc.poll(70_000)
	(w["s"] as _Session).session_stopped.emit("link-reset")
	wc.poll(120_000)
	_check(wc.state == CouchConnection.STATE_RECONNECTING, "C5 each reconnect gets its own hold (got %s)" % wc.state)
	# A hold set by the game wins.
	var x := _make("mock", "g1", _rows_host_guest())
	var xc: CouchConnection = x["c"]
	xc.hold_ms = 5000
	_start_guest(x)
	(x["s"] as _Session).session_stopped.emit("link-reset")
	xc.poll(5000)
	_check(xc.end_reason == CouchConnection.END_RECONNECT_TIMED_OUT, "C5 a game-set hold is used (got %s)" % xc.end_reason)
	_free(w)
	_free(x)


func _case_c6_lobby_states() -> void:
	var u := _make("steam", "g1", _rows_host_guest())
	var c: CouchConnection = u["c"]
	_start_guest(u)
	(u["l"] as _Lobby).state_changed.emit("reconnecting")
	_check(_last(u) == [CouchConnection.STATE_RECONNECTING, CouchConnection.REASON_OWN_CONNECTION], "C6 the lobby reconnecting is your own connection (got %s)" % [_last(u)])
	(u["l"] as _Lobby).state_changed.emit("joined")
	_check(c.state == CouchConnection.STATE_LIVE, "C6 joined again returns to live (got %s)" % c.state)
	(u["l"] as _Lobby).state_changed.emit("failed")
	_check(c.state == CouchConnection.STATE_ENDED and c.end_reason == CouchConnection.END_CONNECTION_LOST, "C6 failed ends connection-lost (got %s %s)" % [c.state, c.end_reason])
	var v := _make("steam", "g1", _rows_host_guest())
	_start_guest(v)
	(v["l"] as _Lobby).state_changed.emit("leaving")
	_check((v["c"] as CouchConnection).end_reason == CouchConnection.END_LEFT, "C6 leaving ends left (got %s)" % (v["c"] as CouchConnection).end_reason)
	# A guest whose own link came back while its session was mid-resync syncs.
	var w := _make("steam", "g1", _rows_host_guest())
	_start_guest(w)
	(w["l"] as _Lobby).state_changed.emit("reconnecting")
	(w["s"] as _Session).session_stopped.emit("steam-link-gap")
	(w["l"] as _Lobby).state_changed.emit("joined")
	_check((w["c"] as CouchConnection).state == CouchConnection.STATE_RECONNECTING, "C6 joined while the session is still down stays reconnecting (got %s)" % (w["c"] as CouchConnection).state)
	(w["s"] as _Session).session_started.emit(2, false, 1, "host", "Hana")
	(w["s"] as _Session).snapshot_received.emit({})
	_check((w["c"] as CouchConnection).state == CouchConnection.STATE_LIVE, "C6 and live once resynced (got %s)" % (w["c"] as CouchConnection).state)
	# idle and joined before any session change nothing.
	var x := _make("web", "g1", _rows_host_guest())
	(x["l"] as _Lobby).state_changed.emit("idle")
	(x["l"] as _Lobby).state_changed.emit("joined")
	_check((x["states"] as Array).is_empty(), "C6 idle/joined while connecting change nothing (got %s)" % [x["states"]])
	_free(u)
	_free(v)
	_free(w)
	_free(x)


func _case_c7_stop_reasons() -> void:
	var u := _make("mock", "g1", _rows_host_guest())
	_start_guest(u)
	(u["s"] as _Session).session_stopped.emit("lobby-unavailable")
	_check((u["c"] as CouchConnection).end_reason == CouchConnection.END_CONNECTION_LOST, "C7 lobby-unavailable ends connection-lost (got %s)" % (u["c"] as CouchConnection).end_reason)
	var v := _make("mock", "g1", _rows_host_guest())
	_start_guest(v)
	(v["s"] as _Session).session_stopped.emit("stopped")
	_check((v["c"] as CouchConnection).end_reason == CouchConnection.END_LEFT, "C7 the driver's own stop ends left (got %s)" % (v["c"] as CouchConnection).end_reason)
	var w := _make("mock", "g1", _rows_host_guest())
	_start_guest(w)
	(w["s"] as _Session).session_stopped.emit("something-new")
	_check((w["c"] as CouchConnection).end_reason == CouchConnection.END_CONNECTION_LOST, "C7 an unknown reason ends connection-lost (got %s)" % (w["c"] as CouchConnection).end_reason)
	var x := _make("mock", "g1", _rows_host_guest())
	(x["s"] as _Session).session_stopped.emit("roster-too-small")
	_check((x["c"] as CouchConnection).state == CouchConnection.STATE_CONNECTING, "C7 a stop before any start leaves it connecting (got %s)" % (x["c"] as CouchConnection).state)
	_free(u)
	_free(v)
	_free(w)
	_free(x)


func _case_c8_close() -> void:
	var u := _make("mock", "g1", _rows_host_guest())
	var c: CouchConnection = u["c"]
	_start_guest(u)
	c.close()
	c.close()
	_check(_last(u) == [CouchConnection.STATE_ENDED, CouchConnection.END_LEFT] and u["states"].size() == 3, "C8 close() ends left exactly once (got %s)" % [u["states"]])
	_check(not (u["s"] as _Session).session_started.is_connected(c._on_session_started), "C8 close() lets go of the session")
	_free(u)


# --- P: player states ----------------------------------------------------------

func _case_p1_away_after_quiet() -> void:
	var u := _make("mock", "host", _rows_host_guest())
	var c: CouchConnection = u["c"]
	_check(c.get_player_state("g1") == CouchConnection.PLAYER_CONNECTED, "P1 a guest in the roster is connected (got %s)" % c.get_player_state("g1"))
	c.poll(1000)
	(u["l"] as _Lobby).set_rows(_rows_host_guest("disconnected"))
	c.poll(1000 + CouchConnection.AWAY_QUIET_MS - 1)
	_check(c.get_player_state("g1") == CouchConnection.PLAYER_CONNECTED and u["players"].is_empty(), "P1 nothing shows in the first 10 s (got %s)" % [u["players"]])
	c.poll(1000 + CouchConnection.AWAY_QUIET_MS)
	_check(u["players"] == [["g1", CouchConnection.PLAYER_AWAY]], "P1 away after 10 quiet seconds (got %s)" % [u["players"]])
	c.poll(30_000)
	_check(u["players"].size() == 1, "P1 away is reported once (got %s)" % [u["players"]])
	(u["l"] as _Lobby).set_rows(_rows_host_guest())
	_check(u["players"][-1] == ["g1", CouchConnection.PLAYER_CONNECTED], "P1 back is connected (got %s)" % [u["players"]])
	# A short drop never shows.
	var v := _make("mock", "host", _rows_host_guest())
	var vc: CouchConnection = v["c"]
	vc.poll(1000)
	(v["l"] as _Lobby).set_rows(_rows_host_guest("disconnected"))
	vc.poll(5000)
	(v["l"] as _Lobby).set_rows(_rows_host_guest())
	vc.poll(20_000)
	_check(v["players"].is_empty(), "P1 a drop shorter than 10 s reports nothing (got %s)" % [v["players"]])
	_free(u)
	_free(v)


func _case_p2_gone_and_new() -> void:
	var u := _make("mock", "host", _rows_host_guest())
	var c: CouchConnection = u["c"]
	(u["l"] as _Lobby).set_rows([_rows_host_guest()[0]])
	_check(u["players"] == [["g1", CouchConnection.PLAYER_GONE]], "P2 a guest out of the roster is gone (got %s)" % [u["players"]])
	_check(c.get_player_state("g1") == CouchConnection.PLAYER_GONE, "P2 get_player_state says gone (got %s)" % c.get_player_state("g1"))
	var rows := _rows_host_guest()
	rows.append({"user_id": "g2", "username": "Gia", "role": "guest", "status": "playing"})
	(u["l"] as _Lobby).set_rows(rows)
	_check(u["players"].slice(1) == [["g1", CouchConnection.PLAYER_CONNECTED], ["g2", CouchConnection.PLAYER_CONNECTED]], "P2 arrivals are connected (got %s)" % [u["players"]])
	_check(not c.get_players_state().has("host"), "P2 the local player is never reported (got %s)" % [c.get_players_state()])
	# A guest who leaves while away is gone, not away.
	var v := _make("mock", "host", _rows_host_guest())
	var vc: CouchConnection = v["c"]
	vc.poll(0)
	(v["l"] as _Lobby).set_rows(_rows_host_guest("disconnected"))
	vc.poll(4000)
	(v["l"] as _Lobby).set_rows([_rows_host_guest()[0]])
	vc.poll(20_000)
	_check(v["players"] == [["g1", CouchConnection.PLAYER_GONE]], "P2 leaving while away is gone only (got %s)" % [v["players"]])
	# CouchLobbyPlayer rows are read too.
	var w := _make("mock", "host", [])
	(w["l"] as _Lobby).set_rows([
		CouchLobbyPlayer.from_dict({"userId": "host", "role": "host", "status": "playing"}),
		CouchLobbyPlayer.from_dict({"userId": "g1", "role": "guest", "status": "playing"}),
	])
	_check(w["players"] == [["g1", CouchConnection.PLAYER_CONNECTED]], "P2 CouchLobbyPlayer rows are read (got %s)" % [w["players"]])
	_free(u)
	_free(v)
	_free(w)


func _case_p3_host_away_on_web() -> void:
	var u := _make("web", "g1", _rows_host_guest())
	var c: CouchConnection = u["c"]
	_start_guest(u)
	c.poll(1000)
	(u["l"] as _Lobby).set_rows([_rows_host_guest()[1]])
	_check(c.get_player_state("host") == CouchConnection.PLAYER_CONNECTED and u["players"].is_empty(), "P3 on the web a missing host is not gone (got %s)" % [u["players"]])
	c.poll(1000 + CouchConnection.AWAY_QUIET_MS)
	_check(u["players"] == [["host", CouchConnection.PLAYER_AWAY]], "P3 the host missing for 10 s is away (got %s)" % [u["players"]])
	(u["l"] as _Lobby).set_rows(_rows_host_guest())
	_check(u["players"][-1] == ["host", CouchConnection.PLAYER_CONNECTED], "P3 the host back is connected (got %s)" % [u["players"]])
	# Off the web a missing host is gone at once.
	var v := _make("mock", "g1", _rows_host_guest())
	_start_guest(v)
	(v["l"] as _Lobby).set_rows([_rows_host_guest()[1]])
	_check(v["players"] == [["host", CouchConnection.PLAYER_GONE]], "P3 off the web a missing host is gone (got %s)" % [v["players"]])
	_free(u)
	_free(v)


# --- T: text -------------------------------------------------------------------

func _case_t1_text() -> void:
	var seen: Dictionary = {}
	for reason in CouchConnection.END_REASONS:
		var text := CouchConnection.describe_end(reason, "Hana")
		_check(not text.is_empty() and not seen.has(text), "T1 %s has its own text (got %s)" % [reason, text])
		seen[text] = true
	_check(CouchConnection.describe_end(CouchConnection.END_HOST_LEFT, "Hana") == "Hana left the game", "T1 host-left uses the platform's words (got %s)" % CouchConnection.describe_end(CouchConnection.END_HOST_LEFT, "Hana"))
	_check(CouchConnection.describe_end(CouchConnection.END_HOST_LEFT, "") == "The host left the game", "T1 host-left without a name (got %s)" % CouchConnection.describe_end(CouchConnection.END_HOST_LEFT, ""))
	_check(CouchConnection.describe_end("nonsense", "") == CouchConnection.describe_end(CouchConnection.END_CONNECTION_LOST, ""), "T1 an unknown reason reads as connection-lost")


func _case_t2_overlay_lines() -> void:
	# Off the web: own connection, a resync, the host away, a guest away, the end.
	var u := _make("steam", "g1", _rows_host_guest())
	var c: CouchConnection = u["c"]
	_start_guest(u)
	c.poll(1000)
	_check(c.overlay_lines() == [], "T2 nothing while live (got %s)" % [c.overlay_lines()])
	(u["s"] as _Session).session_stopped.emit("link-reset")
	c.poll(1000 + CouchConnection.OVERLAY_DELAY_MS - 1)
	_check(c.overlay_lines() == [], "T2 a resync shows nothing in its first second (got %s)" % [c.overlay_lines()])
	c.poll(1000 + CouchConnection.OVERLAY_DELAY_MS)
	_check(c.overlay_lines() == ["Reconnecting…"], "T2 a longer resync reads Reconnecting… (got %s)" % [c.overlay_lines()])
	(u["s"] as _Session).session_started.emit(2, false, 1, "host", "Hana")
	(u["s"] as _Session).snapshot_received.emit({})
	_check(c.overlay_lines() == [], "T2 cleared once live (got %s)" % [c.overlay_lines()])
	(u["l"] as _Lobby).set_rows(_rows_host_guest())
	(u["s"] as _Session).session_stopped.emit("host-left")
	_check(c.overlay_lines() == ["Hana left the game"], "T2 an end shows its text at once (got %s)" % [c.overlay_lines()])
	# A host off the web sees a guest away after the quiet stretch.
	var v := _make("local", "host", _rows_host_guest())
	var vc: CouchConnection = v["c"]
	(v["s"] as _Session).session_started.emit(1, true, 0, "g1", "Gus")
	vc.poll(0)
	(v["l"] as _Lobby).set_rows(_rows_host_guest("disconnected"))
	vc.poll(CouchConnection.AWAY_QUIET_MS)
	_check(vc.overlay_lines() == ["Gus's away"], "T2 the host sees <name>'s away (got %s)" % [vc.overlay_lines()])
	# The web: the platform draws all of it.
	var w := _make("web", "g1", _rows_host_guest())
	var wc: CouchConnection = w["c"]
	_start_guest(w)
	(w["s"] as _Session).session_stopped.emit("link-reset")
	wc.poll(60_000)
	_check(wc.overlay_lines() == [], "T2 on the web the overlay draws nothing (got %s)" % [wc.overlay_lines()])
	_free(u)
	_free(v)
	_free(w)


func _case_t3_overlay_node() -> void:
	for platform in ["steam", "web"]:
		var u := _make(platform, "g1", _rows_host_guest())
		var c: CouchConnection = u["c"]
		c.overlay_enabled = true
		root.add_child(c)
		# The root is not ready during _initialize, so ready has not propagated yet.
		if not c.is_node_ready():
			c._ready()
		var overlay: CouchConnectionOverlay = null
		for child in c.get_children():
			if child is CouchConnectionOverlay:
				overlay = child
		if platform == "web":
			_check(overlay == null, "T3 on the web no overlay is added")
		else:
			_check(overlay != null and overlay.process_mode == Node.PROCESS_MODE_ALWAYS, "T3 off the web the overlay is added and runs while paused")
			if overlay != null:
				_start_guest(u)
				overlay._process(0.0)
				_check(not overlay._panel.visible, "T3 hidden while live")
				c.close()
				overlay._process(0.0)
				_check(overlay._panel.visible and overlay._label.text == "You left the game", "T3 shows the end text (got %s)" % overlay._label.text)
		root.remove_child(c)
		_free(u)


# --- W: the hand-wired warning -------------------------------------------------

func _case_w1_bound() -> void:
	var roster := _Lobby.new("host")
	roster.rows = _rows_host_guest()
	var transport := CouchLobbyTransport.new(CouchScriptedLobby.new("host", true))
	var session := CouchSession.new(roster, transport)
	_check(not session.connection_bound, "W1 a fresh CouchSession is not bound")
	var connection: CouchConnection = C.new()
	connection.platform = "mock"
	connection.overlay_enabled = false
	connection.log_enabled = false
	connection.bind(session, roster)
	_check(session.connection_bound, "W1 bind() marks the session bound, which silences the hand-wired warning")
	connection.free()


## Runs after every other case, which all start sessions without the autoload.
func _case_w2_warns_once_in_a_game() -> void:
	_check(not CouchSession._warned_hand_wired, "W2 no warning without the CouchGames autoload (headless fixtures)")
	var sdk := Node.new()
	sdk.name = "CouchGames"
	root.add_child(sdk)
	var bound := _host_session()
	var connection: CouchConnection = C.new()
	connection.platform = "mock"
	connection.overlay_enabled = false
	connection.log_enabled = false
	connection.bind(bound, null)
	bound.evaluate(0)
	_check(bound.active and not CouchSession._warned_hand_wired, "W2 a bound session in a game does not warn")
	var hand_wired := _host_session()
	hand_wired.evaluate(0)
	_check(hand_wired.active and CouchSession._warned_hand_wired, "W2 a hand-wired session in a game warns")
	connection.free()
	root.remove_child(sdk)
	sdk.free()


func _host_session() -> CouchSession:
	var roster := _Lobby.new("host")
	roster.rows = _rows_host_guest()
	roster.am_host = true
	return CouchSession.new(roster, CouchLobbyTransport.new(CouchScriptedLobby.new("host", true)))


# --- E: end to end -------------------------------------------------------------

func _case_e1_real_session() -> void:
	var host_player := {"user_id": "host", "username": "Hana", "role": "host", "controller_slot": 0}
	var guest_player := {"user_id": "g1", "username": "Gus", "role": "guest", "controller_slot": 1}
	var host_lobby := CouchScriptedLobby.new("host", true)
	var guest_lobby := CouchScriptedLobby.new("g1", false)
	CouchScriptedLobby.link(host_lobby, guest_lobby)
	var host_roster := _Lobby.new("host")
	host_roster.rows = [host_player, guest_player]
	host_roster.am_host = true
	var guest_roster := _Lobby.new("g1")
	guest_roster.rows = [host_player, guest_player]
	var host_transport := CouchLobbyTransport.new(host_lobby)
	var guest_transport := CouchLobbyTransport.new(guest_lobby)
	var host := CouchSession.new(host_roster, host_transport)
	var guest := CouchSession.new(guest_roster, guest_transport)
	host.hello_received.connect(func(_s: String) -> void: host.broadcast_snapshot({"world": 1}))
	var connection: CouchConnection = C.new()
	connection.platform = "mock"
	connection.overlay_enabled = false
	connection.log_enabled = false
	var states: Array = []
	connection.state_changed.connect(func(state: String, _reason: String) -> void: states.append(state))
	connection.bind(guest, guest_roster)
	host.evaluate(0)
	guest.evaluate(0)
	for t in [1000, 2000, 3000]:
		host.poll(t)
		guest.poll(t)
	_check(states == [CouchConnection.STATE_SYNCING, CouchConnection.STATE_LIVE], "E1 a real guest session goes syncing -> live (got %s)" % [states])
	host_lobby.event_received.emit("couchgames:peer-reconnected", {"userId": "g1", "role": "guest", "downtimeMs": 2000}, "")
	for t in [4000, 5000, 6000]:
		host.poll(t)
		guest.poll(t)
		connection.poll(t)
	_check(states == [CouchConnection.STATE_SYNCING, CouchConnection.STATE_LIVE, CouchConnection.STATE_RECONNECTING, CouchConnection.STATE_SYNCING, CouchConnection.STATE_LIVE], "E1 a resync after a reconnect goes reconnecting -> syncing -> live (got %s)" % [states])
	connection.free()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("  PASS: " + label)
	else:
		_failures += 1
		printerr("  FAIL: " + label)


## The session surface CouchConnection reads: CouchSession and CouchLobbySession
## both emit these.
class _Session extends RefCounted:
	signal session_started(epoch: int, is_host: bool, local_slot: int, peer_id: String, peer_name: String)
	signal session_stopped(reason: String)
	signal snapshot_received(body: Dictionary)


## The lobby surface CouchConnection reads, and enough of the roster surface
## for CouchSession in case E.
class _Lobby extends RefCounted:
	signal players_changed(players: Array)
	signal state_changed(state: String)
	var is_available: bool = true
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
		for row in rows:
			if (row is Dictionary and row.get("user_id") == me_id) or (row is Object and row.get("user_id") == me_id):
				return row
		return {"user_id": me_id}

	func get_host() -> Variant:
		for row in rows:
			if row is Dictionary and row.get("role") == "host":
				return row
		return null

	func get_guests() -> Array:
		return rows.filter(func(row): return row is Dictionary and row.get("role") != "host")

	func is_host() -> bool:
		return am_host
