## G19: the lobby transport hears Couch's away flow (platform decision 0078).
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_lobby_away.gd
##
## On Couch a dropped or reloaded player is "away": a guest stays in the roster
## as a `disconnected` row, and when anyone comes back the platform raises the
## reserved lobby events `couchgames:peer-reconnected` ({userId, role,
## downtimeMs}, on the clients that stayed) and `couchgames:reconnected`
## ({downtimeMs}, on the client that dropped). CouchLobbyTransport turns these
## into ONE `peer-reconnected` link-reset gap per peer per reconnect, which is
## what CouchSession's host needs to hear a guest whose game restarted while
## its roster row (and slot) stayed put.
##
## Real code under test: CouchLobbyTransport, CouchSession, CouchEnvelope. The
## lobby is CouchScriptedLobby (the same double G3 uses), with the reserved
## events and roster updates emitted on it directly, as the backends deliver
## them.
##
##   A  transport unit: event -> gap, malformed events, self reconnect, the
##      `disconnected` row coming back, one gap when both signals arrive (either
##      order), a peer that leaves while away, reserved names never reach the
##      gameplay channel, nothing after close().
##   B  end to end, both slot modes: a guest restarts with its roster row
##      unchanged. Without a reconnect signal the host stays deaf to it (the
##      documented limit). With `couchgames:peer-reconnected`, or with the row
##      going `disconnected` and back, the host resyncs it and hears it again.
##
## Exit codes: 0 = every check passed, 1 = at least one failed.
extends SceneTree

const PEER_RECONNECTED := "couchgames:peer-reconnected"
const RECONNECTED := "couchgames:reconnected"

var _failures := 0
var _checks := 0


func _initialize() -> void:
	print("== G19 lobby away ==")
	_case_a1_event_raises_one_gap()
	_case_a2_malformed_events()
	_case_a3_self_reconnected()
	_case_a4_disconnected_row_comes_back()
	_case_a5_both_signals_one_gap()
	_case_a6_left_while_away()
	_case_a7_reserved_names_stay_off_the_wire()
	_case_a8_closed_transport_is_silent()
	for mode in [1, 2]:
		_case_b1_restart_without_signal_is_deaf(mode)
		_case_b2_restart_heard_after_event(mode)
		_case_b3_restart_heard_after_row_returns(mode)
	if _failures == 0:
		print("COUCH_LOBBY_AWAY_OK: %d check(s)" % _checks)
	else:
		printerr("G19 lobby away: %d of %d checks FAILED" % [_failures, _checks])
	quit(0 if _failures == 0 else 1)


# --- A: transport unit -------------------------------------------------------

func _row(id: String, role: String, status: String = "playing") -> Dictionary:
	return {"user_id": id, "username": id, "role": role, "status": status}


func _unit(me: String = "host", is_host: bool = true) -> Dictionary:
	var lobby := CouchScriptedLobby.new(me, is_host)
	var transport := CouchLobbyTransport.new(lobby)
	var gaps: Array = []
	transport.transport_gap.connect(func(peer: String, reason: String) -> void: gaps.append([peer, reason]))
	var envelopes: Array = []
	transport.envelope_received.connect(func(env: Dictionary, sender: String) -> void: envelopes.append([env, sender]))
	return {"lobby": lobby, "transport": transport, "gaps": gaps, "envelopes": envelopes}


func _roster(u: Dictionary, rows: Array) -> void:
	(u["lobby"] as CouchScriptedLobby).players_changed.emit(rows)


func _event(u: Dictionary, name: String, data: Variant) -> void:
	(u["lobby"] as CouchScriptedLobby).event_received.emit(name, data, "")


func _case_a1_event_raises_one_gap() -> void:
	var u := _unit()
	_roster(u, [_row("host", "host"), _row("g1", "guest")])
	_event(u, PEER_RECONNECTED, {"userId": "g1", "role": "guest", "downtimeMs": 1200})
	_check(u["gaps"] == [["g1", "peer-reconnected"]], "A1 peer-reconnected event raises one peer-reconnected gap for that peer (got %s)" % [u["gaps"]])
	_event(u, PEER_RECONNECTED, {"userId": "g1", "role": "guest", "downtimeMs": 300})
	_check(u["gaps"].size() == 2, "A1 a second reconnect raises a second gap (got %s)" % [u["gaps"]])
	_event(u, PEER_RECONNECTED, {"userId": "host", "role": "host", "downtimeMs": 300})
	_check(u["gaps"].size() == 2, "A1 an event naming the local player raises nothing (got %s)" % [u["gaps"]])


func _case_a2_malformed_events() -> void:
	var u := _unit()
	_roster(u, [_row("host", "host"), _row("g1", "guest")])
	for data in [null, "g1", 7, [], {}, {"userId": 5}, {"userId": ""}, {"user_id": "g1"}]:
		_event(u, PEER_RECONNECTED, data)
	_check(u["gaps"].is_empty(), "A2 malformed peer-reconnected payloads raise no gap (got %s)" % [u["gaps"]])
	_check(u["envelopes"].is_empty(), "A2 malformed reserved events never reach envelope_received")


func _case_a3_self_reconnected() -> void:
	var u := _unit()
	_roster(u, [_row("host", "host"), _row("g1", "guest"), _row("g2", "guest")])
	_event(u, RECONNECTED, {"downtimeMs": 4000})
	var peers: Array = []
	for g in u["gaps"]:
		peers.append(g[0])
		_check(g[1] == "peer-reconnected", "A3 own reconnect gaps use peer-reconnected (got %s)" % g[1])
	peers.sort()
	_check(peers == ["g1", "g2"], "A3 own reconnect raises one gap per other known peer, never self (got %s)" % [peers])
	var lone := _unit()
	_roster(lone, [_row("host", "host")])
	_event(lone, RECONNECTED, {"downtimeMs": 4000})
	_check(lone["gaps"].is_empty(), "A3 own reconnect with no other peer raises nothing (got %s)" % [lone["gaps"]])


func _case_a4_disconnected_row_comes_back() -> void:
	var u := _unit()
	_roster(u, [_row("host", "host"), _row("g1", "guest")])
	_roster(u, [_row("host", "host"), _row("g1", "guest", "disconnected")])
	_check(u["gaps"].is_empty(), "A4 a row going disconnected raises no gap yet (got %s)" % [u["gaps"]])
	_roster(u, [_row("host", "host"), _row("g1", "guest", "disconnected")])
	_check(u["gaps"].is_empty(), "A4 a repeated disconnected roster raises nothing (got %s)" % [u["gaps"]])
	_roster(u, [_row("host", "host"), _row("g1", "guest", "playing")])
	_check(u["gaps"] == [["g1", "peer-reconnected"]], "A4 the row coming back raises one peer-reconnected gap (got %s)" % [u["gaps"]])
	_roster(u, [_row("host", "host"), _row("g1", "guest", "lobby")])
	_check(u["gaps"].size() == 1, "A4 an ordinary status change raises nothing (got %s)" % [u["gaps"]])
	# A backend with no reserved events: every away episode raises its own gap.
	_roster(u, [_row("host", "host"), _row("g1", "guest", "disconnected")])
	_roster(u, [_row("host", "host"), _row("g1", "guest")])
	_check(u["gaps"].size() == 2, "A4 a second roster-only reconnect raises a second gap (got %s)" % [u["gaps"]])
	# A peer already away when we first see it, then back.
	var late := _unit()
	_roster(late, [_row("host", "host"), _row("g1", "guest", "disconnected")])
	_roster(late, [_row("host", "host"), _row("g1", "guest")])
	_check(late["gaps"] == [["g1", "peer-reconnected"]], "A4 a peer first seen away raises one gap when back (got %s)" % [late["gaps"]])
	# CouchLobbyPlayer objects carry the status as a property.
	var objs := _unit()
	var p := CouchLobbyPlayer.from_dict({"userId": "g1", "role": "guest", "status": "disconnected"})
	var h := CouchLobbyPlayer.from_dict({"userId": "host", "role": "host", "status": "playing"})
	_roster(objs, [h, p])
	var back := CouchLobbyPlayer.from_dict({"userId": "g1", "role": "guest", "status": "playing"})
	_roster(objs, [h, back])
	_check(objs["gaps"] == [["g1", "peer-reconnected"]], "A4 CouchLobbyPlayer rows are read too (got %s)" % [objs["gaps"]])
	# The local player's own row never raises a gap.
	var own := _unit()
	_roster(own, [_row("host", "host", "disconnected"), _row("g1", "guest")])
	_roster(own, [_row("host", "host"), _row("g1", "guest")])
	_check(own["gaps"].is_empty(), "A4 the local row coming back raises nothing (got %s)" % [own["gaps"]])


func _case_a5_both_signals_one_gap() -> void:
	# Roster first, then the event.
	var u := _unit()
	_roster(u, [_row("host", "host"), _row("g1", "guest", "disconnected")])
	_roster(u, [_row("host", "host"), _row("g1", "guest")])
	_event(u, PEER_RECONNECTED, {"userId": "g1", "role": "guest", "downtimeMs": 9000})
	_check(u["gaps"] == [["g1", "peer-reconnected"]], "A5 roster then event raises one gap (got %s)" % [u["gaps"]])
	# The next drop is a new episode and raises again.
	_event(u, PEER_RECONNECTED, {"userId": "g1", "role": "guest", "downtimeMs": 800})
	_check(u["gaps"].size() == 2, "A5 a later event-only drop still raises (got %s)" % [u["gaps"]])
	# Event first, while the row still reads disconnected, then the row.
	var v := _unit()
	_roster(v, [_row("host", "host"), _row("g1", "guest", "disconnected")])
	_event(v, PEER_RECONNECTED, {"userId": "g1", "role": "guest", "downtimeMs": 9000})
	_roster(v, [_row("host", "host"), _row("g1", "guest")])
	_check(v["gaps"] == [["g1", "peer-reconnected"]], "A5 event then roster raises one gap (got %s)" % [v["gaps"]])
	_roster(v, [_row("host", "host"), _row("g1", "guest", "disconnected")])
	_roster(v, [_row("host", "host"), _row("g1", "guest")])
	_check(v["gaps"].size() == 2, "A5 the next away episode raises again (got %s)" % [v["gaps"]])


func _case_a6_left_while_away() -> void:
	var u := _unit()
	_roster(u, [_row("host", "host"), _row("g1", "guest", "disconnected")])
	_roster(u, [_row("host", "host")])
	_check(u["gaps"].is_empty(), "A6 a peer leaving while away raises no gap (got %s)" % [u["gaps"]])
	_roster(u, [_row("host", "host"), _row("g1", "guest")])
	_check(u["gaps"] == [["g1", "peer-rejoined"]], "A6 coming back after leaving is peer-rejoined only (got %s)" % [u["gaps"]])


func _case_a7_reserved_names_stay_off_the_wire() -> void:
	var u := _unit()
	_roster(u, [_row("host", "host"), _row("g1", "guest")])
	_event(u, PEER_RECONNECTED, {"userId": "g1", "role": "guest", "downtimeMs": 1})
	_event(u, RECONNECTED, {"downtimeMs": 1})
	_check(u["envelopes"].is_empty(), "A7 reserved events never reach envelope_received")
	var custom_lobby := CouchScriptedLobby.new("host", true)
	var custom := CouchLobbyTransport.new(custom_lobby, PEER_RECONNECTED)
	var custom_gaps: Array = []
	custom.transport_gap.connect(func(peer: String, reason: String) -> void: custom_gaps.append([peer, reason]))
	custom_lobby.players_changed.emit([_row("host", "host"), _row("g1", "guest")])
	custom_lobby.event_received.emit(PEER_RECONNECTED, {"userId": "g1", "role": "guest", "downtimeMs": 1}, "")
	_check(custom_gaps == [["g1", "peer-reconnected"]], "A7 the reserved event is read even if a game misnames its channel (got %s)" % [custom_gaps])


func _case_a8_closed_transport_is_silent() -> void:
	var u := _unit()
	_roster(u, [_row("host", "host"), _row("g1", "guest", "disconnected")])
	(u["transport"] as CouchLobbyTransport).close()
	_event(u, PEER_RECONNECTED, {"userId": "g1", "role": "guest", "downtimeMs": 1})
	_event(u, RECONNECTED, {"downtimeMs": 1})
	_roster(u, [_row("host", "host"), _row("g1", "guest")])
	_check(u["gaps"].is_empty(), "A8 a closed transport raises nothing (got %s)" % [u["gaps"]])


# --- B: a restarted guest, end to end --------------------------------------

func _pair(mode: int) -> Dictionary:
	var host_player := {"user_id": "host", "username": "Host", "controller_slot": 0}
	var guest_player := {"user_id": "g1", "username": "Guest", "controller_slot": 1}
	var players := [host_player, guest_player]
	var host_lobby := CouchScriptedLobby.new("host", true)
	var host_transport := CouchLobbyTransport.new(host_lobby)
	var host_roster := _Roster.new(host_player, host_player, [guest_player], players, true)
	var policy := CouchSessionPolicy.default_policy()
	policy.max_input_players = mode
	var host_session := CouchSession.new(host_roster, host_transport, policy)
	var heard: Array = []
	host_session.intent_received.connect(func(body: Dictionary, sender: String) -> void: heard.append([sender, body.get("n")]))
	# As a game does: answer every hello with the world, which is the baseline a
	# resynced guest waits for before it sends again.
	host_session.hello_received.connect(func(_sender: String) -> void: host_session.broadcast_snapshot({"world": 1}))
	var pair := {
		"host_player": host_player, "guest_player": guest_player, "players": players, "mode": mode,
		"host_lobby": host_lobby, "host_transport": host_transport, "host_session": host_session,
		"heard": heard, "now": 0,
	}
	_new_guest(pair)
	host_lobby.players_changed.emit([_row("host", "host"), _row("g1", "guest")])
	host_session.evaluate(0)
	(pair["guest_session"] as CouchSession).evaluate(0)
	return pair


## A fresh guest process: new lobby endpoint, transport and session, same user.
func _new_guest(pair: Dictionary) -> void:
	var guest_lobby := CouchScriptedLobby.new("g1", false)
	CouchScriptedLobby.link(pair["host_lobby"], guest_lobby)
	var guest_transport := CouchLobbyTransport.new(guest_lobby)
	var guest_roster := _Roster.new(pair["guest_player"], pair["host_player"], [pair["guest_player"]], pair["players"], false)
	var policy := CouchSessionPolicy.default_policy()
	policy.max_input_players = pair["mode"]
	pair["guest_lobby"] = guest_lobby
	pair["guest_transport"] = guest_transport
	pair["guest_session"] = CouchSession.new(guest_roster, guest_transport, policy)


func _tick(pair: Dictionary, steps: int = 4) -> void:
	for i in steps:
		pair["now"] += 1000
		(pair["host_session"] as CouchSession).poll(pair["now"])
		(pair["host_session"] as CouchSession).evaluate(pair["now"])
		(pair["guest_session"] as CouchSession).poll(pair["now"])
		(pair["guest_session"] as CouchSession).evaluate(pair["now"])


func _send(pair: Dictionary, from: int, to: int) -> void:
	for n in range(from, to + 1):
		(pair["guest_session"] as CouchSession).send_intent({"n": n})


func _heard_numbers(pair: Dictionary) -> Array:
	var out: Array = []
	for h in pair["heard"]:
		out.append(int(h[1]))
	return out


func _restart(pair: Dictionary) -> void:
	_tick(pair)
	_send(pair, 1, 5)
	_check(_heard_numbers(pair) == [1, 2, 3, 4, 5], "B[%d] the first process is heard (got %s)" % [pair["mode"], _heard_numbers(pair)])
	(pair["guest_session"] as CouchSession).stop("test-restart")
	(pair["guest_transport"] as CouchLobbyTransport).close()
	_new_guest(pair)
	_tick(pair)
	_check((pair["guest_session"] as CouchSession).active, "B[%d] the restarted guest is active again" % pair["mode"])
	pair["heard"].clear()


func _case_b1_restart_without_signal_is_deaf(mode: int) -> void:
	var pair := _pair(mode)
	_restart(pair)
	var rejected: Array = []
	(pair["host_session"] as CouchSession).rejected.connect(func(reason: String, _sender: String) -> void: rejected.append(reason))
	_send(pair, 1, 3)
	_check(rejected == ["duplicate", "duplicate", "duplicate"], "B1[%d] the restarted guest's intents are rejected as duplicates (got %s)" % [mode, rejected])
	_check(_heard_numbers(pair).is_empty(), "B1[%d] with no reconnect signal the host stays deaf to a restarted guest (the documented limit; got %s)" % [mode, _heard_numbers(pair)])


func _case_b2_restart_heard_after_event(mode: int) -> void:
	var pair := _pair(mode)
	_restart(pair)
	(pair["host_lobby"] as CouchScriptedLobby).event_received.emit(PEER_RECONNECTED, {"userId": "g1", "role": "guest", "downtimeMs": 2500}, "")
	_tick(pair)
	_send(pair, 1, 3)
	_check(_heard_numbers(pair) == [1, 2, 3], "B2[%d] after couchgames:peer-reconnected the host hears the restarted guest (got %s)" % [mode, _heard_numbers(pair)])
	_check((pair["guest_session"] as CouchSession).active, "B2[%d] the guest is active after the resync" % mode)


func _case_b3_restart_heard_after_row_returns(mode: int) -> void:
	var pair := _pair(mode)
	(pair["host_lobby"] as CouchScriptedLobby).players_changed.emit([_row("host", "host"), _row("g1", "guest", "disconnected")])
	_restart(pair)
	(pair["host_lobby"] as CouchScriptedLobby).players_changed.emit([_row("host", "host"), _row("g1", "guest")])
	_tick(pair)
	_send(pair, 1, 3)
	_check(_heard_numbers(pair) == [1, 2, 3], "B3[%d] after the disconnected row comes back the host hears the restarted guest (got %s)" % [mode, _heard_numbers(pair)])
	# The event arriving after the roster is the same reconnect: no second resync.
	var gaps: Array = []
	(pair["host_session"] as CouchSession).transport_gap.connect(func(peer: String, reason: String) -> void: gaps.append([peer, reason]))
	(pair["host_lobby"] as CouchScriptedLobby).event_received.emit(PEER_RECONNECTED, {"userId": "g1", "role": "guest", "downtimeMs": 2500}, "")
	_check(gaps.is_empty(), "B3[%d] the event after the roster raises no second gap (got %s)" % [mode, gaps])


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("  PASS: " + label)
	else:
		_failures += 1
		printerr("  FAIL: " + label)


class _Roster extends RefCounted:
	var is_available: bool = true
	var _me: Dictionary
	var _host: Dictionary
	var _guests: Array
	var _players: Array
	var _am_host: bool

	func _init(me: Dictionary, host: Dictionary, guests: Array, players: Array, am_host: bool) -> void:
		_me = me
		_host = host
		_guests = guests
		_players = players
		_am_host = am_host

	func get_players() -> Array:
		return _players

	func get_me() -> Variant:
		return _me

	func get_host() -> Variant:
		return _host

	func get_guests() -> Array:
		return _guests

	func is_host() -> bool:
		return _am_host
