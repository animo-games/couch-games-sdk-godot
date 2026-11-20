## G12: CouchRoutedTransport carries each guest on its own wire, WebRTC or the
## lobby tunnel, assigned by the host before the guest's session traffic flows
## and never changed in place (docs/plans/per-link-transport-fallback.md).
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_routed_session.gd
##
## Real code under test: CouchRoutedTransport, CouchLobbyTransport, CouchSession
## and CouchEnvelope. The lobby is an N-player double (_Hub) with the server's
## targeting and a JSON round trip; the star is a double (_StarNet) whose links
## come up only when a case says so, so link formation is under the case's
## control. The real CouchStarTransport is covered by G8, G9 and G11; this gate
## proves the routing around it. Time is explicit.
##
##   F1  mixed: guest A on the star, guest B (probe failed) on the tunnel; both
##       get every snapshot exactly once, and the host hears both.
##   F2  the host's probe failed: every guest is on the tunnel, the star unused.
##   F3  a guest's probe passed but its link never forms: the tunnel at the
##       deadline, and the session runs.
##   F4  wrong-wire and unrouted envelopes are dropped with a gap.
##   F5  a stale assign (older round) is ignored; a restarted host's newer
##       round is adopted.
##   F6  rebuild-exhausted mid-session does not re-route in place; only
##       apply_pending_reroutes() does, under a new round.
##   F7  require_datagram: a blocked guest is refused, never put on the tunnel.
##   F9  the host's side of the handshake, message by message: nothing is sent
##       to a guest before its ack, and only an ack for the current round counts.
##   R1  the same routing over REAL CouchStarTransports and WebRTC links
##       (CouchScriptedSignaling, as in G9): one guest on the star, one forced
##       to the tunnel. Needs a WebRTC implementation: a FAIL without one, not
##       a skip, like G8 and G9.
##   F8  readiness, the query that recovers lost reports, a restarted guest,
##       a guest that leaves, and the per-route counters.
##
## Exit codes: 0 = every check passed, 1 = at least one failed.
extends SceneTree

const ROUTE_EVENT := "couch-route"

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== G12 routed session ==")
	_case_f1_mixed()
	_case_f2_host_blocked()
	_case_f3_link_never_forms()
	_case_f4_wrong_wire()
	_case_f5_stale_assign()
	_case_f6_no_reroute_in_place()
	_case_f7_require_datagram()
	_case_f8_ready_query_restart_leave_stats()
	_case_f9_handshake_by_hand()
	await _case_r1_real_star()
	if _failures == 0:
		print("COUCH_ROUTED_SESSION_OK: %d check(s)" % _checks)
	else:
		printerr("G12 routed session: %d of %d checks FAILED" % [_failures, _checks])
	quit(0 if _failures == 0 else 1)


# --- harness ---------------------------------------------------------------

## One participant: its lobby endpoint, star endpoint (or null), routed
## transport and session.
func _node(hub: _Hub, stars: _StarNet, id: String, is_host: bool, probe_ok: bool, options: Dictionary = {}) -> Dictionary:
	var lobby := hub.endpoint(id, is_host)
	var star: _Star = stars.endpoint(id, is_host) if probe_ok else null
	var opts := {"probe_ok": probe_ok, "probe_reason": "" if probe_ok else "webrtc-blocked:test", "link_deadline_ms": 5000}
	opts.merge(options, true)
	var routed := CouchRoutedTransport.new(lobby, CouchLobbyTransport.new(lobby), star, opts)
	var policy := CouchSessionPolicy.default_policy()
	policy.max_input_players = 2
	var session := CouchSession.new(lobby, routed, policy)
	var n := {"id": id, "lobby": lobby, "star": star, "routed": routed, "session": session, "snapshots": [], "intents": [], "gaps": []}
	session.snapshot_received.connect(func(body: Dictionary) -> void: n["snapshots"].append(body.get("n")))
	session.intent_received.connect(func(body: Dictionary, sender: String) -> void: n["intents"].append([sender, body.get("n")]))
	routed.transport_gap.connect(func(peer: String, reason: String) -> void: n["gaps"].append([peer, reason]))
	if is_host:
		session.hello_received.connect(func(_s: String) -> void: session.broadcast_snapshot({"n": 0}))
	return n


func _world(host_probe: bool, a_probe: bool, b_probe: bool, options: Dictionary = {}) -> Dictionary:
	var hub := _Hub.new()
	var stars := _StarNet.new()
	var w := {"hub": hub, "stars": stars, "now": 0}
	w["host"] = _node(hub, stars, "host", true, host_probe, options)
	w["a"] = _node(hub, stars, "ga", false, a_probe, options)
	w["b"] = _node(hub, stars, "gb", false, b_probe, options)
	hub.set_roster(["host", "ga", "gb"])
	return w


func _nodes(w: Dictionary) -> Array:
	var out: Array = []
	for key in ["host", "a", "b"]:
		if w.has(key):
			out.append(w[key])
	return out


func _tick(w: Dictionary, steps: int = 1, step_ms: int = 500) -> void:
	for i in steps:
		w["now"] += step_ms
		for n in _nodes(w):
			(n["routed"] as CouchRoutedTransport).poll(w["now"])
			(n["session"] as CouchSession).poll(w["now"])
			(n["session"] as CouchSession).evaluate(w["now"])


func _link(w: Dictionary, guest: String) -> void:
	(w["stars"] as _StarNet).connect_link(guest)


func _route(w: Dictionary, who: String, peer: String = "") -> String:
	var r: CouchRoutedTransport = w[who]["routed"]
	return r.route_for(peer) if not peer.is_empty() else r.local_route


func _snap(w: Dictionary, n: int) -> void:
	(w["host"]["session"] as CouchSession).broadcast_snapshot({"n": n})


func _sends(w: Dictionary, who: String, route: String) -> int:
	return int((w[who]["routed"] as CouchRoutedTransport).stats()[route]["sent"])


# --- F1 ----------------------------------------------------------------------

func _case_f1_mixed() -> void:
	var w := _world(true, true, false)
	_link(w, "ga")
	_tick(w, 6)
	_check(_route(w, "host", "ga") == "star" and _route(w, "host", "gb") == "lobby", "F1 the host routes A to the star and B to the tunnel (got %s / %s)" % [_route(w, "host", "ga"), _route(w, "host", "gb")])
	_check(_route(w, "a") == "star" and _route(w, "b") == "lobby", "F1 each guest adopted its own route (got %s / %s)" % [_route(w, "a"), _route(w, "b")])
	_check((w["a"]["session"] as CouchSession).active and (w["b"]["session"] as CouchSession).active, "F1 both guest sessions are active")
	for n in _nodes(w):
		n["snapshots"].clear()
	for i in range(1, 6):
		_snap(w, i)
	_check(w["a"]["snapshots"] == [1, 2, 3, 4, 5], "F1 A gets every snapshot exactly once (got %s)" % [w["a"]["snapshots"]])
	_check(w["b"]["snapshots"] == [1, 2, 3, 4, 5], "F1 B gets every snapshot exactly once (got %s)" % [w["b"]["snapshots"]])
	(w["a"]["session"] as CouchSession).send_intent({"n": 1})
	(w["b"]["session"] as CouchSession).send_intent({"n": 2})
	_check(w["host"]["intents"] == [["ga", 1], ["gb", 2]], "F1 the host hears both guests (got %s)" % [w["host"]["intents"]])
	var star_lobby_frames := 0
	for frame in (w["hub"] as _Hub).log:
		if frame["event"] == "couch-net" and (frame["from"] == "ga" or frame["to"] == "ga"):
			star_lobby_frames += 1
	_check(star_lobby_frames == 0, "F1 nothing of A's session crosses the tunnel (got %d)" % star_lobby_frames)
	_check(((w["stars"] as _StarNet).frames_to("gb")) == 0, "F1 nothing reaches B over the star (got %d)" % (w["stars"] as _StarNet).frames_to("gb"))


# --- F2 ----------------------------------------------------------------------

func _case_f2_host_blocked() -> void:
	var w := _world(false, true, true)
	_link(w, "ga")
	_link(w, "gb")
	_tick(w, 6)
	_check(_route(w, "host", "ga") == "lobby" and _route(w, "host", "gb") == "lobby", "F2 a host whose probe failed puts every guest on the tunnel (got %s / %s)" % [_route(w, "host", "ga"), _route(w, "host", "gb")])
	_check(_route(w, "a") == "lobby" and _route(w, "b") == "lobby", "F2 both guests adopted the tunnel")
	var before := (w["stars"] as _StarNet).total_frames
	for n in _nodes(w):
		n["snapshots"].clear()
	_snap(w, 1)
	(w["a"]["session"] as CouchSession).send_intent({"n": 1})
	_check(w["a"]["snapshots"] == [1] and w["b"]["snapshots"] == [1], "F2 both get the snapshot over the tunnel (got %s / %s)" % [w["a"]["snapshots"], w["b"]["snapshots"]])
	_check((w["stars"] as _StarNet).total_frames == before and before == 0, "F2 nothing touches the star (got %d)" % (w["stars"] as _StarNet).total_frames)
	_check((w["a"]["star"] as _Star).closed and (w["b"]["star"] as _Star).closed, "F2 a guest put on the tunnel closes its unused star")


# --- F3 ----------------------------------------------------------------------

func _case_f3_link_never_forms() -> void:
	var w := _world(true, true, true)
	_link(w, "ga")
	_tick(w, 4)
	_check(_route(w, "host", "ga") == "star", "F3 A's link formed: star (got %s)" % _route(w, "host", "ga"))
	_check(_route(w, "host", "gb") == "", "F3 B's probe passed and its link is pending: no route yet (got %s)" % _route(w, "host", "gb"))
	_check(not (w["b"]["session"] as CouchSession).active, "F3 B's session waits while unrouted")
	_tick(w, 10)
	_check(_route(w, "host", "gb") == "lobby" and _route(w, "b") == "lobby", "F3 at the deadline B goes to the tunnel (got %s / %s)" % [_route(w, "host", "gb"), _route(w, "b")])
	_tick(w, 4)
	_check((w["b"]["session"] as CouchSession).active, "F3 and B's session starts")
	# A link that forms after the deadline changes nothing.
	_link(w, "gb")
	_tick(w, 2)
	_check(_route(w, "host", "gb") == "lobby", "F3 a late link does not re-route B (got %s)" % _route(w, "host", "gb"))


# --- F4 ----------------------------------------------------------------------

func _case_f4_wrong_wire() -> void:
	var w := _world(true, true, false)
	_link(w, "ga")
	_tick(w, 6)
	var host: Dictionary = w["host"]
	var tracker_before := (host["session"] as CouchSession).rejected_count
	host["gaps"].clear()
	host["intents"].clear()
	var stray := CouchEnvelope.make(CouchEnvelope.KIND_INTENT, (host["session"] as CouchSession).epoch, 99, {"n": 99})
	# A's frame arriving over the tunnel, and B's over the star.
	(w["hub"] as _Hub).inject("ga", "host", "couch-net", CouchEnvelope.to_json_frame(stray))
	(w["stars"] as _StarNet).inject("gb", "host", stray)
	_check(host["intents"].is_empty(), "F4 wrong-wire envelopes never reach the session (got %s)" % [host["intents"]])
	_check(host["gaps"].has(["ga", "wrong-wire"]) and host["gaps"].has(["gb", "wrong-wire"]), "F4 each is reported as a wrong-wire gap (got %s)" % [host["gaps"]])
	_check((host["session"] as CouchSession).rejected_count == tracker_before, "F4 sequence state is untouched (rejected %d -> %d)" % [tracker_before, (host["session"] as CouchSession).rejected_count])
	(w["stars"] as _StarNet).inject("gb", "host", stray)
	_check(host["gaps"].count(["gb", "wrong-wire"]) == 1, "F4 a repeated stray is reported once (got %s)" % [host["gaps"]])
	(w["a"]["session"] as CouchSession).send_intent({"n": 5})
	_check(host["intents"] == [["ga", 5]], "F4 A's real intent still arrives, with seq unaffected (got %s)" % [host["intents"]])
	# An envelope from a peer that has no route at all.
	(w["hub"] as _Hub).inject("stranger", "host", "couch-net", CouchEnvelope.to_json_frame(stray))
	_check(host["gaps"].has(["stranger", "unrouted"]), "F4 an unrouted sender is dropped as unrouted (got %s)" % [host["gaps"]])
	# The guest side filters too.
	var a: Dictionary = w["a"]
	a["gaps"].clear()
	var snap := CouchEnvelope.make(CouchEnvelope.KIND_SNAPSHOT, (host["session"] as CouchSession).epoch, 50, {"n": 50})
	a["snapshots"].clear()
	(w["hub"] as _Hub).inject("host", "ga", "couch-net", CouchEnvelope.to_json_frame(snap))
	_check(a["snapshots"].is_empty() and a["gaps"].has(["host", "wrong-wire"]), "F4 a star guest drops a tunnel frame (got %s / %s)" % [a["snapshots"], a["gaps"]])


# --- F5 ----------------------------------------------------------------------

func _case_f5_stale_assign() -> void:
	var w := _world(true, true, false, {"round_seed": 1000})
	_link(w, "ga")
	_tick(w, 6)
	var a: CouchRoutedTransport = w["a"]["routed"]
	var round_now := a.local_round
	_check(round_now >= 1000, "F5 the guest holds the host's round (got %d)" % round_now)
	(w["hub"] as _Hub).inject("host", "ga", ROUTE_EVENT, {"v": 1, "t": "assign", "round": round_now - 1, "route": "lobby"})
	_check(a.local_route == "star" and a.local_round == round_now, "F5 an older round's assign is ignored (got %s %d)" % [a.local_route, a.local_round])
	(w["hub"] as _Hub).inject("gb", "ga", ROUTE_EVENT, {"v": 1, "t": "assign", "round": round_now + 5, "route": "lobby"})
	_check(a.local_route == "star", "F5 an assign from anyone but the host is ignored (got %s)" % a.local_route)
	for bad in [null, 5, {"t": "assign"}, {"v": 1, "t": "assign", "round": "x", "route": "lobby"}, {"v": 1, "t": "assign", "round": round_now + 9, "route": "carrier-pigeon"}, {"v": 2, "t": "assign", "round": round_now + 9, "route": "lobby"}]:
		(w["hub"] as _Hub).inject("host", "ga", ROUTE_EVENT, bad)
	_check(a.local_route == "star" and a.local_round == round_now, "F5 malformed assigns are ignored (got %s %d)" % [a.local_route, a.local_round])
	# A restarted host: a fresh transport with a newer seed re-routes everyone.
	var hub: _Hub = w["hub"]
	(w["host"]["routed"] as CouchRoutedTransport).close()
	w["host"] = _node(hub, w["stars"], "host", true, false, {"round_seed": round_now + 100})
	_tick(w, 6)
	_check(a.local_route == "lobby" and a.local_round >= round_now + 100, "F5 a restarted host's newer round is adopted (got %s %d)" % [a.local_route, a.local_round])


# --- F6 ----------------------------------------------------------------------

func _case_f6_no_reroute_in_place() -> void:
	var w := _world(true, true, true)
	_link(w, "ga")
	_link(w, "gb")
	_tick(w, 6)
	var host: CouchRoutedTransport = w["host"]["routed"]
	var pending: Array = []
	host.reroute_pending.connect(func(peer: String) -> void: pending.append(peer))
	(w["stars"] as _StarNet).gap("host", "ga", "rebuild-exhausted")
	_tick(w, 4)
	_check(host.route_for("ga") == "star" and _route(w, "a") == "star", "F6 rebuild-exhausted does not re-route in place (got %s / %s)" % [host.route_for("ga"), _route(w, "a")])
	_check(pending == ["ga"] and host.pending_reroutes() == ["ga"], "F6 it is queued as a pending re-route (got %s / %s)" % [pending, host.pending_reroutes()])
	_check(w["host"]["gaps"].has(["ga", "rebuild-exhausted"]), "F6 the gap is still reported (got %s)" % [w["host"]["gaps"]])
	var round_before: int = (w["a"]["routed"] as CouchRoutedTransport).local_round
	var applied := host.apply_pending_reroutes()
	_tick(w, 4)
	_check(applied == ["ga"] and host.route_for("ga") == "lobby" and _route(w, "a") == "lobby", "F6 apply_pending_reroutes() moves it to the tunnel (got %s / %s / %s)" % [applied, host.route_for("ga"), _route(w, "a")])
	_check((w["a"]["routed"] as CouchRoutedTransport).local_round > round_before, "F6 under a newer round")
	_check(host.pending_reroutes().is_empty() and host.route_for("gb") == "star", "F6 nothing else moves (got %s / %s)" % [host.pending_reroutes(), host.route_for("gb")])
	(w["host"]["session"] as CouchSession).stop("reroute")
	_tick(w, 8)
	w["a"]["snapshots"].clear()
	_snap(w, 7)
	_check(w["a"]["snapshots"] == [7], "F6 the new epoch reaches A over the tunnel (got %s)" % [w["a"]["snapshots"]])
	# A guest on the tunnel is never queued.
	(w["stars"] as _StarNet).gap("host", "ga", "rebuild-exhausted")
	_check(host.pending_reroutes().is_empty(), "F6 a star gap for a tunnel guest queues nothing (got %s)" % [host.pending_reroutes()])


# --- F7 ----------------------------------------------------------------------

func _case_f7_require_datagram() -> void:
	var w := _world(true, true, false, {"require_datagram": true})
	var refused: Array = []
	(w["b"]["routed"] as CouchRoutedTransport).route_refused.connect(func(reason: String) -> void: refused.append(reason))
	_link(w, "ga")
	_tick(w, 6)
	_check(_route(w, "host", "gb") == "none" and _route(w, "b") == "none", "F7 a blocked guest is refused, not tunnelled (got %s / %s)" % [_route(w, "host", "gb"), _route(w, "b")])
	_check(refused.size() == 1 and not str(refused[0]).is_empty(), "F7 the guest is told why, once (got %s)" % [refused])
	_check(not (w["b"]["routed"] as CouchRoutedTransport).is_ready() and not (w["b"]["session"] as CouchSession).active, "F7 the refused guest never goes ready or active")
	_check(_route(w, "host", "ga") == "star" and (w["a"]["session"] as CouchSession).active, "F7 the star guest plays on")
	# The deadline refuses too.
	var v := _world(true, true, true, {"require_datagram": true})
	_link(v, "ga")
	_tick(v, 14)
	_check(_route(v, "host", "gb") == "none", "F7 a link that never forms is refused at the deadline (got %s)" % _route(v, "host", "gb"))
	# rebuild-exhausted under require_datagram queues a refusal, not the tunnel.
	(v["stars"] as _StarNet).gap("host", "ga", "rebuild-exhausted")
	var host: CouchRoutedTransport = v["host"]["routed"]
	host.apply_pending_reroutes()
	_tick(v, 4)
	_check(host.route_for("ga") == "none", "F7 a dead link is refused under require_datagram (got %s)" % host.route_for("ga"))


# --- F8 ----------------------------------------------------------------------

func _case_f8_ready_query_restart_leave_stats() -> void:
	var w := _world(true, true, false)
	var host: CouchRoutedTransport = w["host"]["routed"]
	_check(not host.is_ready(), "F8 the host is not ready before any route is acknowledged")
	# Lose B's first report: the host's query recovers it.
	(w["hub"] as _Hub).drop_next(ROUTE_EVENT, "gb")
	_link(w, "ga")
	_tick(w, 8)
	_check(host.route_for("gb") == "lobby", "F8 a lost report is recovered by the host's query (got %s)" % host.route_for("gb"))
	_check(host.is_ready() and (w["a"]["routed"] as CouchRoutedTransport).is_ready() and (w["b"]["routed"] as CouchRoutedTransport).is_ready(), "F8 everyone is ready once every route is acknowledged")
	var ready_peers: Array = []
	# B restarts: a fresh guest process re-handshakes and keeps its route.
	var hub: _Hub = w["hub"]
	(w["b"]["routed"] as CouchRoutedTransport).close()
	w["b"] = _node(hub, w["stars"], "gb", false, false)
	_tick(w, 6)
	_check(_route(w, "b") == "lobby" and host.route_for("gb") == "lobby", "F8 a restarted guest gets its route again (got %s)" % _route(w, "b"))
	_check((w["b"]["session"] as CouchSession).active, "F8 and its session starts")
	# B leaves: its route is forgotten.
	hub.set_roster(["host", "ga"])
	_tick(w, 1)
	_check(host.route_for("gb") == "" and host.is_ready(), "F8 a guest who left loses its route and does not block readiness (got %s)" % host.route_for("gb"))
	# A new guest arriving makes the host not ready until it is routed.
	w.erase("b")
	w["b"] = _node(hub, w["stars"], "gc", false, false)
	hub.set_roster(["host", "ga", "gc"])
	_tick(w, 1, 1)
	_check(not host.is_ready(), "F8 an unrouted arrival makes the host not ready")
	_tick(w, 6)
	_check(host.route_for("gc") == "lobby" and host.is_ready(), "F8 until it is routed (got %s)" % host.route_for("gc"))
	# Counters.
	var stats := host.stats()
	_check(int(stats["star"]["sent"]) > 0 and int(stats["lobby"]["sent"]) > 0 and int(stats["lobby"]["bytes_sent"]) > 0, "F8 per-route counters count sends (got %s)" % [stats])
	_check(int(stats["star"]["received"]) > 0 and int(stats["lobby"]["received"]) > 0, "F8 and receives (got %s)" % [stats])
	_check(int(stats["dropped"]) >= 0, "F8 and drops")


func _case_f9_handshake_by_hand() -> void:
	var hub := _Hub.new()
	var lobby := hub.endpoint("host", true)
	var guest_lobby := hub.endpoint("gx", false)
	hub.set_roster(["host", "gx"])
	var heard: Array = []
	guest_lobby.event_received.connect(func(event: String, data: Variant, _from: String) -> void:
		if event == ROUTE_EVENT:
			heard.append(data))
	var host := CouchRoutedTransport.new(lobby, CouchLobbyTransport.new(lobby), null, {"round_seed": 500})
	var ready: Array = []
	host.peer_ready.connect(func(pid: String) -> void: ready.append(pid))
	host.poll(0)
	_check(heard.size() == 1 and heard[0].get("t") == "query", "F9 an unreported guest is queried (got %s)" % [heard])
	hub.inject("gx", "host", ROUTE_EVENT, {"v": 1, "t": "report", "ok": false, "reason": "webrtc-blocked:test"})
	host.poll(10)
	var assign: Dictionary = heard[-1]
	_check(assign.get("t") == "assign" and assign.get("route") == "lobby" and int(assign.get("round")) == 501, "F9 the report is answered with an assign for round 501 (got %s)" % [assign])
	var env := CouchEnvelope.make(CouchEnvelope.KIND_SNAPSHOT, 1, 1, {"n": 1})
	_check(not host.send_to_peer("gx", env) and not host.broadcast(env), "F9 nothing goes to the guest before its ack")
	hub.inject("gx", "host", ROUTE_EVENT, {"v": 1, "t": "ack", "round": 500, "route": "lobby"})
	hub.inject("gx", "host", ROUTE_EVENT, {"v": 1, "t": "ack", "round": 501, "route": "star"})
	_check(not host.send_to_peer("gx", env) and ready.is_empty(), "F9 an ack for another round or route does not count (got ready %s)" % [ready])
	host.poll(10 + CouchRoutedTransport.RETRY_MS)
	_check(heard[-1].get("t") == "assign" and int(heard[-1].get("round")) == 501, "F9 the unacknowledged assign is sent again (got %s)" % [heard[-1]])
	hub.inject("gx", "host", ROUTE_EVENT, {"v": 1, "t": "ack", "round": 501, "route": "lobby"})
	_check(host.send_to_peer("gx", env) and ready == ["gx"], "F9 the right ack opens the route, and the guest is ready (got %s)" % [ready])
	hub.inject("gx", "host", ROUTE_EVENT, {"v": 1, "t": "ack", "round": 501, "route": "lobby"})
	_check(ready == ["gx"], "F9 a repeated ack is ready once (got %s)" % [ready])


func _case_r1_real_star() -> void:
	if not CouchStarTransport.is_webrtc_available():
		_check(false, "R1 needs a WebRTC implementation (FAIL, not skip)")
		return
	var hub := _Hub.new()
	var sig := {}
	var nodes := {}
	for id in ["host", "ga", "gb"]:
		var lobby := hub.endpoint(id, id == "host")
		sig[id] = CouchScriptedSignaling.new(id)
		var star: Object = CouchStarTransport.new(sig[id], lobby) if id != "gb" else null
		var routed := CouchRoutedTransport.new(lobby, CouchLobbyTransport.new(lobby), star, {"probe_ok": star != null, "probe_reason": "" if star != null else "webrtc-blocked:test", "link_deadline_ms": 20_000})
		var policy := CouchSessionPolicy.default_policy()
		policy.max_input_players = 2
		var session := CouchSession.new(lobby, routed, policy)
		var n := {"star": star, "routed": routed, "session": session, "snapshots": [], "intents": []}
		session.snapshot_received.connect(func(body: Dictionary) -> void: n["snapshots"].append(body.get("n")))
		session.intent_received.connect(func(body: Dictionary, sender: String) -> void: n["intents"].append(sender))
		if id == "host":
			session.hello_received.connect(func(_s: String) -> void: session.broadcast_snapshot({"n": 0}))
		nodes[id] = n
	CouchScriptedSignaling.link(sig["host"], sig["ga"])
	hub.set_roster(["host", "ga", "gb"])
	for id in ["host", "ga"]:
		var res: Dictionary = await (nodes[id]["star"] as CouchStarTransport).start()
		_check(bool(res.get("success", false)), "R1 %s's real star starts" % id)
	var host: CouchRoutedTransport = nodes["host"]["routed"]
	var deadline := Time.get_ticks_msec() + 15_000
	while Time.get_ticks_msec() < deadline:
		var now := Time.get_ticks_msec()
		for id in nodes:
			(nodes[id]["routed"] as CouchRoutedTransport).poll(now)
			(nodes[id]["session"] as CouchSession).poll(now)
			(nodes[id]["session"] as CouchSession).evaluate(now)
		if host.is_ready() and (nodes["ga"]["session"] as CouchSession).active and (nodes["gb"]["session"] as CouchSession).active:
			break
		await process_frame
	_check(host.route_for("ga") == "star" and host.route_for("gb") == "lobby", "R1 over real WebRTC: A on the star, B on the tunnel (got %s / %s)" % [host.route_for("ga"), host.route_for("gb")])
	_check((nodes["ga"]["session"] as CouchSession).active and (nodes["gb"]["session"] as CouchSession).active, "R1 both guest sessions start")
	for id in ["ga", "gb"]:
		nodes[id]["snapshots"].clear()
	(nodes["host"]["session"] as CouchSession).broadcast_snapshot({"n": 1})
	(nodes["ga"]["session"] as CouchSession).send_intent({"n": 1})
	(nodes["gb"]["session"] as CouchSession).send_intent({"n": 2})
	deadline = Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline and (nodes["ga"]["snapshots"].is_empty() or nodes["host"]["intents"].size() < 2):
		var now := Time.get_ticks_msec()
		for id in nodes:
			(nodes[id]["routed"] as CouchRoutedTransport).poll(now)
		await process_frame
	_check(nodes["ga"]["snapshots"] == [1] and nodes["gb"]["snapshots"] == [1], "R1 each guest gets the snapshot once, on its own wire (got %s / %s)" % [nodes["ga"]["snapshots"], nodes["gb"]["snapshots"]])
	var heard: Array = nodes["host"]["intents"]
	heard.sort()
	_check(heard == ["ga", "gb"], "R1 the host hears both (got %s)" % [heard])
	_check(int(host.stats()["star"]["received"]) > 0 and int(host.stats()["lobby"]["received"]) > 0, "R1 both wires carried traffic (got %s)" % [host.stats()])
	for id in nodes:
		(nodes[id]["routed"] as CouchRoutedTransport).close()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("  PASS: " + label)
	else:
		_failures += 1
		printerr("  FAIL: " + label)


# --- doubles -----------------------------------------------------------------

## N-player lobby with the server's targeting: a sender never hears itself;
## {"user_id": id}, {"role": "host"} or {} (everyone else). Payloads cross a
## JSON round trip, as on every real backend.
class _Hub extends RefCounted:
	var endpoints: Dictionary = {}     # id -> _HubLobby (latest wins, like a reconnect)
	var roster_ids: Array = []
	var log: Array = []
	var _drops: Array = []             # [event, from]

	func endpoint(id: String, is_host: bool) -> _HubLobby:
		var e := _HubLobby.new(self, id, is_host)
		endpoints[id] = e
		if not roster_ids.is_empty():
			e.players_changed.emit.call_deferred(e.get_players())
		return e

	func set_roster(ids: Array) -> void:
		roster_ids = ids
		for id in endpoints:
			var e: _HubLobby = endpoints[id]
			e.players_changed.emit(e.get_players())

	func rows() -> Array:
		var out: Array = []
		for id in roster_ids:
			out.append({"user_id": id, "username": id, "role": "host" if id == "host" else "guest", "controller_slot": 0 if id == "host" else 1})
		return out

	func drop_next(event: String, from: String) -> void:
		_drops.append([event, from])

	func route(from: String, event: String, data: Variant, target: Dictionary) -> void:
		var drop_at := _drops.find([event, from])
		if drop_at >= 0:
			_drops.remove_at(drop_at)
			return
		for id in endpoints.keys():
			if id == from or not roster_ids.has(id):
				continue
			if target.has("user_id") and str(target["user_id"]) != id:
				continue
			if target.has("role") and str(target["role"]) != ("host" if id == "host" else "guest"):
				continue
			log.append({"event": event, "from": from, "to": id})
			var wire: Variant = JSON.parse_string(JSON.stringify(data))
			(endpoints[id] as _HubLobby).event_received.emit(event, wire, from)

	func inject(from: String, to: String, event: String, data: Variant) -> void:
		var wire: Variant = JSON.parse_string(JSON.stringify(data))
		(endpoints[to] as _HubLobby).event_received.emit(event, wire, from)


class _HubLobby extends RefCounted:
	signal event_received(event: String, data: Variant, sender_user_id: String)
	signal players_changed(players: Array)
	var is_available: bool = true
	var hub: _Hub
	var id: String
	var host_role: bool

	func _init(p_hub: _Hub, p_id: String, p_host: bool) -> void:
		hub = p_hub
		id = p_id
		host_role = p_host

	func send_event(event: String, data: Variant, target: Dictionary = {}) -> void:
		hub.route(id, event, data, target)

	func is_host() -> bool:
		return host_role

	func get_players() -> Array:
		return hub.rows()

	func get_me() -> Variant:
		return {"user_id": id, "username": id, "role": "host" if host_role else "guest"}

	func get_host() -> Variant:
		for row in hub.rows():
			if row["role"] == "host":
				return row
		return null

	func get_guests() -> Array:
		return hub.rows().filter(func(row): return row["role"] != "host")


## The star's links, under the case's control: a guest's link to the host is up
## only after connect_link(). Frames cross only up links.
class _StarNet extends RefCounted:
	var endpoints: Dictionary = {}     # id -> _Star
	var up: Dictionary = {}            # guest id -> true
	var total_frames := 0
	var _to: Dictionary = {}           # id -> frames delivered

	func endpoint(id: String, is_host: bool) -> _Star:
		var s := _Star.new(self, id, is_host)
		endpoints[id] = s
		return s

	func connect_link(guest: String) -> void:
		up[guest] = true
		for id in ["host", guest]:
			if endpoints.has(id) and not (endpoints[id] as _Star).closed:
				(endpoints[id] as _Star).peer_ready.emit(guest if id == "host" else "host")

	func deliver(from: String, to: String, envelope: Dictionary) -> bool:
		var guest := to if from == "host" else from
		if not up.has(guest) or not endpoints.has(to) or (endpoints[to] as _Star).closed:
			return false
		total_frames += 1
		_to[to] = int(_to.get(to, 0)) + 1
		(endpoints[to] as _Star).envelope_received.emit(envelope.duplicate(true), from)
		return true

	func inject(from: String, to: String, envelope: Dictionary) -> void:
		(endpoints[to] as _Star).envelope_received.emit(envelope.duplicate(true), from)

	func gap(at: String, peer: String, reason: String) -> void:
		(endpoints[at] as _Star).transport_gap.emit(peer, reason)

	func frames_to(id: String) -> int:
		return int(_to.get(id, 0))


class _Star extends RefCounted:
	signal envelope_received(envelope: Dictionary, sender_peer_id: String)
	signal peer_ready(peer_id: String)
	signal peer_lost(peer_id: String)
	signal transport_gap(peer_id: String, reason: String)
	var net: _StarNet
	var id: String
	var host_role: bool
	var closed := false

	func _init(p_net: _StarNet, p_id: String, p_host: bool) -> void:
		net = p_net
		id = p_id
		host_role = p_host

	func send_to_authority(envelope: Dictionary) -> bool:
		return not host_role and not closed and net.deliver(id, "host", envelope)

	func send_to_peer(peer_id: String, envelope: Dictionary) -> bool:
		return not closed and net.deliver(id, peer_id, envelope)

	func broadcast(envelope: Dictionary) -> bool:
		if not host_role:
			return send_to_authority(envelope)
		var any := false
		for guest in net.up:
			any = net.deliver(id, guest, envelope) or any
		return any

	func is_ready() -> bool:
		return not closed

	func poll(_now_ms: int) -> void:
		pass

	func close() -> void:
		closed = true
