## G22: CouchLobbySession is the standard host_authoritative driver (step 6 of
## docs/plans/standard-connection-design.md).
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_lobby_driver.gd
##
## Real code under test: CouchLobbySession, CouchSessionTransport.pick(),
## CouchRoutedTransport, CouchLobbyTransport, CouchSession, CouchConnection. The
## lobby is G12's N-player double with player statuses and the lobby state
## signal added; the star is G12's double, links up only when a case says so.
## Drivers stay out of the tree and are polled with explicit time.
##
##   D1  default: pick() gives a routed transport; with no WebRTC here every
##       guest is on the tunnel, and snapshots, intents and the connection run.
##   D2  the first evaluate() waits until every guest is routed.
##   D3  ...or until ready_timeout_ms, when a guest never answers.
##   D4  rebuild-exhausted: the host stops "reroute", moves the guest and starts
##       a new epoch in its next poll, and its connection stays live.
##   D5  refusals reach transport_refused: from pick(), and from the host.
##   D6  drop_in: a host left alone keeps its session and epoch, and the next
##       arrival joins it; without drop_in, or with one slot, it stops.
##   D7  pause_on_drop: the host pauses while a slotted guest is away, a guest
##       while its connection is reconnecting; nothing without the flag.
##   D8  the session's slot and hold signals reach the driver.
##   D9  stop() releases everything, ends the connection "left", and a second
##       start() works.
##   D10 Steam keeps its lobby wire under PREFER_ROUTED.
##
## Exit codes: 0 = every check passed, 1 = at least one failed.
extends SceneTree

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== G22 lobby driver ==")
	await _case_d1_default_routed()
	await _case_d2_waits_for_routes()
	await _case_d3_ready_timeout()
	await _case_d4_reroute()
	await _case_d5_refusals()
	await _case_d6_drop_in()
	await _case_d7_pause_on_drop()
	await _case_d8_forwarded()
	await _case_d9_stop()
	await _case_d10_steam()
	if _failures == 0:
		print("COUCH_LOBBY_DRIVER_OK: %d check(s)" % _checks)
	else:
		printerr("G22 lobby driver: %d of %d checks FAILED" % [_failures, _checks])
	quit(0 if _failures == 0 else 1)


# --- harness ---------------------------------------------------------------

## A world: the hub, the star net, the clock and the drivers by id.
func _world(ids: Array) -> Dictionary:
	var hub := _Hub.new()
	var w := {"hub": hub, "stars": _StarNet.new(), "now": 1000, "d": {}, "lobby": {}}
	for id in ids:
		w["lobby"][id] = hub.endpoint(id, id == "host")
	hub.set_roster(ids)
	return w


## A driver for `id`, with the game's fields applied. `routed` options build an
## injected CouchRoutedTransport over the star double; without them start()
## picks. Records what the game would see.
func _driver(w: Dictionary, id: String, fields: Dictionary = {}, routed: Dictionary = {}) -> Dictionary:
	var lobby: _HubLobby = w["lobby"][id]
	var net := CouchLobbySession.new()
	for key in fields:
		net.set(key, fields[key])
	var rec := {"net": net, "id": id, "snapshots": [], "intents": [], "started": [], "stopped": [], "refused": [], "pauses": [], "states": [], "joined": [], "left": [], "hellos": [], "slot_changes": [], "dropped": [], "ready_at_start": []}
	var world := {"rev": 1}
	rec["world"] = world
	net.snapshot_provider = func() -> Dictionary: return {"rev": world["rev"]}
	net.snapshot_received.connect(func(body: Dictionary) -> void: rec["snapshots"].append(int(body.get("rev", -1))))
	net.intent_received.connect(func(body: Dictionary, sender: String) -> void: rec["intents"].append([sender, body.get("n")]))
	net.session_started.connect(func(epoch: int, is_host: bool, _slot: int, _p: String, _n: String) -> void:
		rec["started"].append(epoch)
		if net.transport != null and net.transport.has_method("is_ready"):
			rec["ready_at_start"].append(bool(net.transport.is_ready())))
	net.session_stopped.connect(func(reason: String) -> void: rec["stopped"].append(reason))
	net.transport_refused.connect(func(error: String) -> void: rec["refused"].append(error))
	net.pause_changed.connect(func(p: bool, why: String) -> void: rec["pauses"].append([p, why]))
	net.player_joined.connect(func(peer: String, slot: int) -> void: rec["joined"].append([peer, slot]))
	net.player_left.connect(func(peer: String, slot: int) -> void: rec["left"].append([peer, slot]))
	net.hello_received.connect(func(sender: String) -> void: rec["hellos"].append(sender))
	net.local_slot_changed.connect(func(a: int, b: int) -> void: rec["slot_changes"].append([a, b]))
	net.held_intents_dropped.connect(func(count: int, why: String) -> void: rec["dropped"].append([count, why]))
	var override: Object = null
	if not routed.is_empty():
		var probe_ok: bool = routed.get("probe_ok", true)
		var star: _Star = (w["stars"] as _StarNet).endpoint(id, id == "host") if probe_ok else null
		var opts := {"probe_ok": probe_ok, "probe_reason": "" if probe_ok else "webrtc-blocked:test", "link_deadline_ms": 5000}
		opts.merge(routed.get("options", {}), true)
		override = CouchRoutedTransport.new(lobby, CouchLobbyTransport.new(lobby), star, opts)
	net.poll(w["now"])
	await net.start(lobby, override)
	if net.connection != null:
		net.connection.log_enabled = false
		net.connection.state_changed.connect(func(s: String, r: String) -> void: rec["states"].append([s, r]))
	w["d"][id] = rec
	return rec


func _tick(w: Dictionary, steps: int = 1, step_ms: int = 500) -> void:
	for i in steps:
		w["now"] += step_ms
		for id in w["d"]:
			(w["d"][id]["net"] as CouchLobbySession).poll(w["now"])


func _free(w: Dictionary) -> void:
	for id in w["d"]:
		var net: CouchLobbySession = w["d"][id]["net"]
		net.stop()
		net.free()
	w["d"].clear()


func _net(w: Dictionary, id: String) -> CouchLobbySession:
	return w["d"][id]["net"]


# --- D1 ----------------------------------------------------------------------

func _case_d1_default_routed() -> void:
	var w := _world(["host", "ga"])
	var host := await _driver(w, "host")
	var ga := await _driver(w, "ga")
	_check(_net(w, "host").transport is CouchRoutedTransport and _net(w, "host").transport_kind == CouchSessionTransport.KIND_ROUTED, "D1 the default pick is the routed transport (got %s)" % _net(w, "host").transport_kind)
	_check(not (_net(w, "ga").transport as CouchRoutedTransport).has_star, "D1 no signaling here, so the guest has no star")
	_tick(w, 6)
	_check((_net(w, "ga").transport as CouchRoutedTransport).local_route == "lobby", "D1 the guest is routed to the tunnel")
	_check(_net(w, "host").is_host() and _net(w, "ga").is_active() and not _net(w, "ga").is_host(), "D1 host and guest sessions run")
	_check(ga["snapshots"].has(1), "D1 the guest got the host's baseline (got %s)" % [ga["snapshots"]])
	_check(_net(w, "ga").send_intent({"n": 7}), "D1 the guest's intent is accepted")
	_tick(w, 2)
	_check(host["intents"] == [["ga", 7]], "D1 the host hears the intent once (got %s)" % [host["intents"]])
	_check(_net(w, "host").connection is CouchConnection and _net(w, "host").connection.state == CouchConnection.STATE_LIVE, "D1 the host's connection is live")
	_check(_net(w, "ga").connection.state == CouchConnection.STATE_LIVE, "D1 the guest's connection is live after the baseline (got %s)" % _net(w, "ga").connection.state)
	_check(bool(_net(w, "host").session.get("_connection_bound")) and bool(_net(w, "ga").session.get("_connection_bound")), "D1 the sessions are marked bound (no hand-wired warning)")
	_check(_net(w, "host").connection.get_parent() == _net(w, "host"), "D1 the connection is the driver's child")
	_check(_net(w, "host").process_mode == Node.PROCESS_MODE_ALWAYS, "D1 the driver runs while the game is paused")
	_free(w)


# --- D2 ----------------------------------------------------------------------

func _case_d2_waits_for_routes() -> void:
	var w := _world(["host", "ga"])
	var host := await _driver(w, "host", {}, {"probe_ok": true})
	var ga := await _driver(w, "ga", {}, {"probe_ok": true})
	var hub: _Hub = w["hub"]
	_tick(w, 3)
	_check(not _net(w, "host").session.active and host["started"].is_empty(), "D2 no host session while the guest's link is not up")
	var session_frames := hub.log.filter(func(e): return e["event"] == "couch-net").size()
	_check(session_frames == 0, "D2 nothing goes out on the session wire before routes are settled (got %d)" % session_frames)
	hub.set_roster(["host", "ga"])
	_check(host["started"].is_empty(), "D2 a roster change while waiting does not start the session early")
	(w["stars"] as _StarNet).connect_link("ga")
	_tick(w, 4)
	_check(host["started"].size() == 1 and host["ready_at_start"] == [true], "D2 the host's session starts once every guest is routed (got %s / %s)" % [host["started"], host["ready_at_start"]])
	_check((_net(w, "host").transport as CouchRoutedTransport).route_for("ga") == "star", "D2 the guest is on the star")
	_check(ga["snapshots"].has(1) and (w["stars"] as _StarNet).frames_to("ga") > 0, "D2 the baseline reached the guest over the star")
	_free(w)


# --- D3 ----------------------------------------------------------------------

func _case_d3_ready_timeout() -> void:
	# "gx" is in the roster but runs no game, so it never reports a route.
	var w := _world(["host", "gx"])
	var host := await _driver(w, "host", {"ready_timeout_ms": 3000}, {"probe_ok": true})
	_tick(w, 5)
	_check(host["started"].is_empty(), "D3 no start before ready_timeout_ms")
	_tick(w, 1)
	_check(host["started"].size() == 1, "D3 the host starts at ready_timeout_ms anyway (got %s)" % [host["started"]])
	_free(w)


# --- D4 ----------------------------------------------------------------------

func _case_d4_reroute() -> void:
	var w := _world(["host", "ga"])
	var host := await _driver(w, "host", {}, {"probe_ok": true})
	var ga := await _driver(w, "ga", {}, {"probe_ok": true})
	(w["stars"] as _StarNet).connect_link("ga")
	_tick(w, 6)
	var first_epoch: int = _net(w, "host").session.epoch
	_check(host["started"].size() == 1 and ga["snapshots"].has(1), "D4 setup: live on the star")
	(w["stars"] as _StarNet).gap("host", "ga", "rebuild-exhausted")
	_check(_net(w, "host").session.active and _net(w, "host").session.epoch == first_epoch, "D4 nothing moves inside the transport's signal")
	host["world"]["rev"] = 2
	_tick(w, 1)
	_check(host["stopped"] == ["reroute"], "D4 the host stops with reason reroute in its next poll (got %s)" % [host["stopped"]])
	_check(host["started"].size() == 2 and _net(w, "host").session.epoch != first_epoch, "D4 a new epoch starts right after")
	_check((_net(w, "host").transport as CouchRoutedTransport).route_for("ga") == "lobby", "D4 the guest moved to the tunnel")
	_tick(w, 6)
	_check(ga["snapshots"].has(2), "D4 the guest resyncs on the new route (got %s)" % [ga["snapshots"]])
	var states: Array = host["states"]
	_check(states.filter(func(s): return s[0] != CouchConnection.STATE_LIVE).is_empty() and _net(w, "host").connection.state == CouchConnection.STATE_LIVE, "D4 the host's connection stays live through the reroute (got %s)" % [states])
	_check(_net(w, "ga").send_intent({"n": 9}), "D4 the guest sends after the reroute")
	_tick(w, 2)
	_check(host["intents"].has(["ga", 9]), "D4 the host hears it on the tunnel")
	_free(w)


# --- D5 ----------------------------------------------------------------------

func _case_d5_refusals() -> void:
	# From pick(): require_datagram, and this machine has no signaling.
	var w := _world(["host", "ga"])
	var ga := await _driver(w, "ga", {"require_datagram": true})
	_check(ga["refused"].size() == 1 and not str(ga["refused"][0]).is_empty(), "D5 pick()'s refusal reaches transport_refused (got %s)" % [ga["refused"]])
	_check(_net(w, "ga").session == null and _net(w, "ga").transport == null and _net(w, "ga").connection == null, "D5 nothing starts after a refusal")
	_free(w)
	# From the host: require_datagram, and the guest's probe failed.
	w = _world(["host", "ga"])
	var host := await _driver(w, "host", {}, {"probe_ok": true, "options": {"require_datagram": true}})
	ga = await _driver(w, "ga", {}, {"probe_ok": false, "options": {"require_datagram": true}})
	_tick(w, 4)
	_check(ga["refused"] == ["webrtc-blocked:test"], "D5 the host's refusal reaches the guest's transport_refused (got %s)" % [ga["refused"]])
	_check(not ga["snapshots"].has(1), "D5 a refused guest gets no gameplay")
	_free(w)


# --- D6 ----------------------------------------------------------------------

func _case_d6_drop_in() -> void:
	var w := _world(["host", "ga"])
	var host := await _driver(w, "host", {"drop_in": true, "policy": _policy(2)})
	await _driver(w, "ga", {"policy": _policy(2)})
	_tick(w, 6)
	var epoch: int = _net(w, "host").session.epoch
	_check(host["joined"] == [["ga", 1]], "D6 setup: ga holds slot 1")
	(w["hub"] as _Hub).set_roster(["host"])
	_tick(w, 2)
	_check(host["stopped"].is_empty() and _net(w, "host").session.active and _net(w, "host").session.epoch == epoch, "D6 drop_in: a host left alone keeps its session and epoch (stopped %s)" % [host["stopped"]])
	_check(host["left"] == [["ga", 1]], "D6 the leaver's slot is freed (got %s)" % [host["left"]])
	_check(_net(w, "host").connection.state == CouchConnection.STATE_LIVE, "D6 the host is live while it waits")
	host["world"]["rev"] = 5
	w["lobby"]["gb"] = (w["hub"] as _Hub).endpoint("gb", false)
	(w["hub"] as _Hub).set_roster(["host", "gb"])
	var gb := await _driver(w, "gb", {"policy": _policy(2)})
	_tick(w, 6)
	_check(host["joined"] == [["ga", 1], ["gb", 1]] and _net(w, "host").session.epoch == epoch, "D6 the next arrival takes the free slot under the same epoch (got %s)" % [host["joined"]])
	_check(gb["snapshots"].has(5), "D6 the arrival gets the running world (got %s)" % [gb["snapshots"]])
	_check(host["started"].size() == 1, "D6 the host never restarted")
	_free(w)
	# Without drop_in the host stops.
	w = _world(["host", "ga"])
	host = await _driver(w, "host", {"policy": _policy(2)})
	await _driver(w, "ga", {"policy": _policy(2)})
	_tick(w, 6)
	(w["hub"] as _Hub).set_roster(["host"])
	_tick(w, 1)
	_check(host["stopped"] == ["roster-too-small"], "D6 without drop_in a host left alone stops (got %s)" % [host["stopped"]])
	_free(w)
	# One input slot: drop_in is ignored (with a warning).
	w = _world(["host", "ga"])
	host = await _driver(w, "host", {"drop_in": true})
	await _driver(w, "ga")
	_tick(w, 6)
	(w["hub"] as _Hub).set_roster(["host"])
	_tick(w, 1)
	_check(host["stopped"] == ["authorized-peer-left"], "D6 drop_in needs more than one slot (got %s)" % [host["stopped"]])
	_free(w)
	# A teardown that loses the host itself still stops.
	w = _world(["host", "ga"])
	host = await _driver(w, "host", {"drop_in": true, "policy": _policy(2)})
	await _driver(w, "ga", {"policy": _policy(2)})
	_tick(w, 6)
	(w["hub"] as _Hub).set_roster([])
	_tick(w, 1)
	_check(host["stopped"] == ["roster-too-small"], "D6 a roster without the host still stops (got %s)" % [host["stopped"]])
	_free(w)


# --- D7 ----------------------------------------------------------------------

func _case_d7_pause_on_drop() -> void:
	var w := _world(["host", "ga"])
	var host := await _driver(w, "host", {"pause_on_drop": true, "policy": _policy(2)})
	var ga := await _driver(w, "ga", {"pause_on_drop": true, "policy": _policy(2)})
	_tick(w, 6)
	_check(host["pauses"].is_empty() and not _net(w, "host").paused, "D7 no pause while everyone is here")
	var hub: _Hub = w["hub"]
	hub.set_status("ga", "disconnected")
	_tick(w, 18)
	_check(host["pauses"].is_empty(), "D7 no pause in the first 10 quiet seconds")
	_tick(w, 3)
	_check(host["pauses"] == [[true, CouchLobbySession.PAUSE_PLAYER_AWAY]] and _net(w, "host").paused, "D7 the host pauses while a slotted guest is away (got %s)" % [host["pauses"]])
	hub.set_status("ga", "playing")
	_tick(w, 1)
	_check(host["pauses"].back() == [false, ""] and not _net(w, "host").paused, "D7 the host resumes when the guest is back (got %s)" % [host["pauses"]])
	# The guest's own resync after its away paused it too; look from here on.
	var before: int = ga["pauses"].size()
	_check(not _net(w, "ga").paused, "D7 setup: the guest is not paused")
	(w["lobby"]["ga"] as _HubLobby).state_changed.emit("reconnecting")
	_check(ga["pauses"].slice(before) == [[true, CouchLobbySession.PAUSE_RECONNECTING]], "D7 a guest pauses while its connection is reconnecting (got %s)" % [ga["pauses"].slice(before)])
	(w["lobby"]["ga"] as _HubLobby).state_changed.emit("joined")
	_check(ga["pauses"].back() == [false, ""], "D7 and resumes when it is back (got %s)" % [ga["pauses"]])
	hub.set_status("ga", "disconnected")
	_tick(w, 21)
	_check(_net(w, "host").paused, "D7 setup: paused again")
	_net(w, "host").stop()
	_check(host["pauses"].back() == [false, ""] and not _net(w, "host").paused, "D7 stop() lifts the pause")
	_free(w)
	# Off by default.
	w = _world(["host", "ga"])
	host = await _driver(w, "host", {"policy": _policy(2)})
	await _driver(w, "ga", {"policy": _policy(2)})
	_tick(w, 6)
	(w["hub"] as _Hub).set_status("ga", "disconnected")
	_tick(w, 24)
	_check(host["pauses"].is_empty() and _net(w, "host").connection.get_player_state("ga") == CouchConnection.PLAYER_AWAY, "D7 without pause_on_drop an away guest pauses nothing")
	_free(w)


# --- D8 ----------------------------------------------------------------------

func _case_d8_forwarded() -> void:
	var w := _world(["host", "ga"])
	var host := await _driver(w, "host", {"policy": _policy(2)})
	var ga := await _driver(w, "ga", {"policy": _policy(2)})
	_tick(w, 6)
	_check(host["hellos"].has("ga"), "D8 hello_received is forwarded")
	_check(host["joined"] == [["ga", 1]], "D8 player_joined is forwarded")
	_net(w, "ga").session.local_slot_changed.emit(1, 2)
	_net(w, "ga").session.held_intents_dropped.emit(3, "expired")
	_check(ga["slot_changes"] == [[1, 2]] and ga["dropped"] == [[3, "expired"]], "D8 local_slot_changed and held_intents_dropped are forwarded")
	(w["hub"] as _Hub).set_roster(["host"])
	_tick(w, 1)
	_check(host["left"].is_empty() and host["stopped"] == ["roster-too-small"], "D8 setup check: roster-too-small frees no slot without drop_in")
	_free(w)


# --- D9 ----------------------------------------------------------------------

func _case_d9_stop() -> void:
	var w := _world(["host", "ga"])
	var host := await _driver(w, "host")
	await _driver(w, "ga")
	_tick(w, 6)
	var net := _net(w, "host")
	var lobby: _HubLobby = w["lobby"]["host"]
	var routed: CouchRoutedTransport = net.transport
	var old_connection := net.connection
	net.stop()
	_check(not net.is_active() and net.session == null and net.transport == null, "D9 stop releases the session and transport")
	_check(not routed.is_ready(), "D9 the transport is closed")
	_check(not lobby.players_changed.is_connected(net._reevaluate) and not lobby.state_changed.is_connected(net._reevaluate), "D9 the lobby signals are released")
	_check(old_connection.state == CouchConnection.STATE_ENDED and old_connection.end_reason == CouchConnection.END_LEFT, "D9 the connection ends left and stays readable")
	_check(not lobby.players_changed.is_connected(old_connection._on_players), "D9 the connection lets go of the lobby")
	net.stop()
	_check(net.connection == old_connection, "D9 a second stop is a no-op")
	await net.start(lobby)
	_check(net.session != null and net.connection != old_connection and net.connection.state == CouchConnection.STATE_CONNECTING, "D9 a second start builds a fresh session and connection")
	_tick(w, 6)
	_check(host["started"].size() == 2, "D9 the restarted host runs again")
	_free(w)


# --- D10 ---------------------------------------------------------------------

func _case_d10_steam() -> void:
	var hub := _Hub.new()
	var lobby := _SteamLobby.new(hub, "host", true)
	hub.endpoints["host"] = lobby
	hub.set_roster(["host"])
	var picked: Dictionary = await CouchSessionTransport.pick(lobby, null, CouchSessionTransport.PREFER_ROUTED)
	_check(picked.kind == CouchSessionTransport.KIND_LOBBY and picked.transport is CouchLobbyTransport, "D10 Steam keeps its lobby wire under PREFER_ROUTED (got %s)" % picked.kind)
	picked.transport.close()


func _policy(slots: int) -> CouchSessionPolicy:
	var p := CouchSessionPolicy.default_policy()
	p.max_input_players = slots
	return p


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("  PASS: " + label)
	else:
		_failures += 1
		printerr("  FAIL: " + label)


# --- doubles -----------------------------------------------------------------

## G12's N-player lobby with the server's targeting, plus player statuses.
class _Hub extends RefCounted:
	var endpoints: Dictionary = {}     # id -> _HubLobby
	var roster_ids: Array = []
	var status: Dictionary = {}        # id -> "disconnected" while away
	var log: Array = []

	func endpoint(id: String, is_host: bool) -> _HubLobby:
		var e := _HubLobby.new(self, id, is_host)
		endpoints[id] = e
		return e

	func set_roster(ids: Array) -> void:
		roster_ids = ids
		_announce()

	func set_status(id: String, value: String) -> void:
		status[id] = value
		_announce()

	func _announce() -> void:
		for id in endpoints:
			var e: _HubLobby = endpoints[id]
			e.players_changed.emit(e.get_players())

	func rows() -> Array:
		var out: Array = []
		for id in roster_ids:
			out.append({"user_id": id, "username": id, "role": "host" if id == "host" else "guest", "controller_slot": 0 if id == "host" else 1, "status": status.get(id, "playing")})
		return out

	func route(from: String, event: String, data: Variant, target: Dictionary) -> void:
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


class _HubLobby extends RefCounted:
	signal event_received(event: String, data: Variant, sender_user_id: String)
	signal players_changed(players: Array)
	signal state_changed(state: String)
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


class _SteamLobby extends _HubLobby:
	func get_backend_name() -> String:
		return "steam"


## G12's star links, under the case's control.
class _StarNet extends RefCounted:
	var endpoints: Dictionary = {}     # id -> _Star
	var up: Dictionary = {}            # guest id -> true
	var _to: Dictionary = {}

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
		_to[to] = int(_to.get(to, 0)) + 1
		(endpoints[to] as _Star).envelope_received.emit(envelope.duplicate(true), from)
		return true

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
