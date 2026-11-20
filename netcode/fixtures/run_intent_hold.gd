## G21: a guest's intents survive a drop (standard connection plan, step 5b).
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_intent_hold.gd
##
## The lobby route is held through a drop by the room itself (platform decision
## 0078). The star (WebRTC) route is not: an intent the guest's game sends
## while its link is down is refused by the transport, and one sent while the
## session waits for the resync baseline is refused by the session. Before
## this step both were lost. Now CouchSession holds them, in order and
## bounded (CouchSessionPolicy.intent_hold_limit), and sends them right after
## the next snapshot -- the host drops a guest's intents until that guest's
## resync hello (step 2), so the snapshot that answers the hello is the
## earliest point a held intent can be applied.
##
##   H1  link down, then rebuilt: held intents arrive once each, in order,
##       after the resync snapshot, and later intents follow them (both slot
##       modes).
##   H2  an intent sent while waiting for the baseline is held behind the
##       ones held before it.
##   H3  the bound: a full hold refuses (false); a limit of 0 is the old
##       behaviour.
##   H4  stop() drops the hold and says so.
##   H5  a new host epoch drops the hold: those intents were for a world the
##       host no longer has.
##   H6  a refused send with no reset reported waits for the next snapshot,
##       and nothing overtakes it.
##   H7  inputs are never held (the next input supersedes them).
##   H8  a spectator holds nothing.
##   H9  a guest that comes back without a slot drops the hold.
##   H10 Steam's provider gap holds and replays the same way.
##   H11 a refusal in the middle of a replay keeps the rest, in order.
##   H12 before its first session a guest refuses intents, as before.
##   H13 the time limit: an intent held longer than intent_hold_ms is dropped
##       as "expired" and never sent; younger ones still go; the limit is
##       inclusive; expiry happens on poll, without waiting for a recovery.
##   H14 intent_hold_ms = 0 turns holding off completely.
##
## HARNESS. Synchronous, no WebRTC, no clock: each side is a
## CouchScriptedRoster + a CouchScriptedTransport subclass that can be taken
## DOWN (its sends return false and nothing is delivered to it, the way the
## star refuses a send once the engine has noticed the dead link) + a real
## CouchSession. The host answers every hello_received with a snapshot unless
## a case turns that off. Assertions are on what the HOST's game received
## (intent_received, in order) and on the wire, never on a return alone.
extends SceneTree

const PUMP_CAP := 200

var _failures := 0
var _checks := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("  PASS: " + message)
	else:
		_failures += 1
		printerr("  FAIL: " + message)


static func _p(id: String, role: String, controller_slot: int) -> Dictionary:
	return {"userId": id, "username": id.to_upper(), "role": role, "controllerSlot": controller_slot}


class _Link extends CouchScriptedTransport:
	var down := false
	var refuse := false   # sends refused, receives still delivered

	func send_to_authority(envelope: Dictionary) -> bool:
		if down or refuse:
			return false
		return super.send_to_authority(envelope)

	func send_to_peer(peer_id: String, envelope: Dictionary) -> bool:
		if down:
			return false
		return super.send_to_peer(peer_id, envelope)

	func broadcast(envelope: Dictionary) -> bool:
		if down:
			return false
		return super.broadcast(envelope)


class _Side extends RefCounted:
	var id: String
	var roster: CouchScriptedRoster
	var transport: _Link
	var session: CouchSession
	var intents: Array = []    # host: [sender, n]
	var inputs: Array = []     # host: [sender, n]
	var rejects: Array = []    # [reason, sender]
	var stopped: Array = []
	var dropped: Array = []    # [count, reason]
	var auto_snapshot := true

	func _init(p_id: String, players: Array, policy: CouchSessionPolicy) -> void:
		id = p_id
		roster = CouchScriptedRoster.new(p_id, players)
		transport = _Link.new()
		session = CouchSession.new(roster, transport, policy)
		session.intent_received.connect(func(body: Dictionary, sender: String) -> void:
			intents.append([sender, int(body.get("n", -1))]))
		session.input_received.connect(func(body: Dictionary, sender: String) -> void:
			inputs.append([sender, int(body.get("n", -1))]))
		session.rejected.connect(func(reason: String, sender: String) -> void:
			rejects.append([reason, sender]))
		session.session_stopped.connect(func(reason: String) -> void: stopped.append(reason))
		session.hello_received.connect(func(_sender: String) -> void:
			if auto_snapshot:
				session.broadcast_snapshot({"w": 1}))
		if session.has_signal("held_intents_dropped"):
			session.connect("held_intents_dropped", func(count: int, reason: String) -> void:
				dropped.append([count, reason]))

	func held() -> int:
		var v: Variant = session.get("held_intent_count")
		return -1 if v == null else int(v)

	func numbers_from(sender: String) -> Array:
		var out: Array = []
		for entry in intents:
			if entry[0] == sender:
				out.append(entry[1])
		return out


class _Net extends RefCounted:
	var sides: Dictionary = {}
	var host_id := ""
	var now := 1000
	var wire: Array = []   # {from, to, kind, n}
	var players: Array = []
	var _check_cb: Callable

	func _init(check_cb: Callable) -> void:
		_check_cb = check_cb

	func side(id: String) -> _Side:
		return sides[id]

	func host() -> _Side:
		return sides[host_id]

	func boot(p_players: Array, policy: CouchSessionPolicy) -> void:
		players = p_players
		for player in players:
			if player["role"] == "host":
				host_id = player["userId"]
				sides[host_id] = _Side.new(host_id, players, policy)
		for player in players:
			if player["role"] != "host":
				sides[player["userId"]] = _Side.new(player["userId"], players, policy)
		for id in sides.keys():
			(sides[id] as _Side).session.evaluate(now)
		pump("boot")
		advance(1000)

	func advance(ms: int) -> void:
		now += ms
		for id in sides.keys():
			(sides[id] as _Side).session.poll(now)
		pump("advance")

	func intent(id: String, n: int) -> bool:
		var ok: bool = side(id).session.send_intent({"n": n})
		pump("intent")
		return ok

	func snapshot() -> void:
		host().session.broadcast_snapshot({"w": 2})
		pump("snapshot")

	func gap(at: String, peer: String, reason: String) -> void:
		side(at).transport.emit_transport_gap(peer, reason)

	func wire_index(from: String, kind: String, n: int = -1, after: int = 0) -> int:
		for i in range(after, wire.size()):
			var w: Dictionary = wire[i]
			if w["from"] == from and w["kind"] == kind and (n < 0 or w["n"] == n):
				return i
		return -1

	func pump(where: String) -> void:
		for _round in PUMP_CAP:
			var moved := 0
			for id in sides.keys():
				var origin: _Side = sides[id]
				var batch: Array = origin.transport.sends.duplicate()
				origin.transport.reset_log()
				for entry in batch:
					moved += 1
					var env := CouchEnvelope.make(str(entry["kind"]), int(entry["epoch"]), int(entry["seq"]), entry["body"])
					var to := str(entry["to"])
					var body: Dictionary = entry["body"]
					wire.append({"from": origin.id, "to": to, "kind": str(entry["kind"]), "n": int(body.get("n", -1))})
					_route(origin, to, env)
			if moved == 0:
				return
		_check_cb.call(false, "pump(%s) settles within %d rounds" % [where, PUMP_CAP])

	func _deliver(target: String, env: Dictionary, from: String) -> void:
		if not sides.has(target):
			return
		var t: _Side = sides[target]
		if t.transport.down:
			return
		t.transport.deliver(env, from)

	func _route(origin: _Side, to: String, env: Dictionary) -> void:
		if to == "broadcast":
			for id in sides.keys():
				if id != origin.id:
					_deliver(id, env, origin.id)
		elif to == "authority":
			_deliver(host_id, env, origin.id)
		elif to.begins_with("peer:"):
			_deliver(to.substr(5), env, origin.id)


func _policy(n: int, limit: int = -1, hold_ms: int = -1) -> CouchSessionPolicy:
	var policy := CouchSessionPolicy.new()
	policy.max_input_players = n
	if limit >= 0:
		policy.set("intent_hold_limit", limit)
	if hold_ms >= 0:
		policy.set("intent_hold_ms", hold_ms)
	return policy


func _net(n: int, limit: int = -1, extra_guest := false, hold_ms: int = -1) -> _Net:
	var net := _Net.new(_check)
	var players := [_p("host", "host", 0), _p("ga", "guest", 1)]
	if extra_guest:
		players.append(_p("gb", "guest", 2))
	net.boot(players, _policy(n, limit, hold_ms))
	return net


## The full recovery a star link rebuild drives: the host hears the gap, asks
## for a hello, answers it, and (auto_snapshot) sends the baseline.
func _rebuild(net: _Net, guest: String) -> void:
	net.side(guest).transport.down = false
	net.gap("host", guest, "link-rebuild")
	net.advance(1000)
	net.advance(1000)


func _run() -> void:
	print("== G21 intent hold ==")
	for mode in [1, 2]:
		_case_h1(mode)
	_case_h2()
	_case_h3()
	_case_h4()
	_case_h5()
	_case_h6()
	_case_h7()
	_case_h8()
	_case_h9()
	_case_h10()
	_case_h11()
	_case_h12()
	_case_h13()
	_case_h14()
	if _failures == 0:
		print("COUCH_INTENT_HOLD_OK: %d check(s)" % _checks)
	else:
		printerr("G21 intent hold: %d of %d checks FAILED" % [_failures, _checks])
	quit(0 if _failures == 0 else 1)
	return


func _case_h1(mode: int) -> void:
	print("-- H1[%d] link down, rebuilt: held intents replay in order --" % mode)
	var net := _net(mode)
	var ga := net.side("ga")
	_check(ga.session.active, "H1[%d] the guest is live" % mode)
	net.intent("ga", 1)
	_check(net.host().numbers_from("ga") == [1], "H1[%d] a live intent arrives (got %s)" % [mode, net.host().numbers_from("ga")])
	ga.transport.down = true
	var r2 := net.intent("ga", 2)
	var r3 := net.intent("ga", 3)
	_check(r2 and r3, "H1[%d] intents sent into a dead link are accepted (held)" % mode)
	_check(ga.held() == 2, "H1[%d] two intents are held (got %d)" % [mode, ga.held()])
	_check(net.host().numbers_from("ga") == [1], "H1[%d] nothing reaches the host while down (got %s)" % [mode, net.host().numbers_from("ga")])
	var wire_before := net.wire.size()
	_rebuild(net, "ga")
	_check(ga.session.active, "H1[%d] the guest is live again" % mode)
	_check(net.host().numbers_from("ga") == [1, 2, 3], "H1[%d] held intents arrive once each, in order (got %s)" % [mode, net.host().numbers_from("ga")])
	_check(ga.held() == 0, "H1[%d] the hold is empty after the replay (got %d)" % [mode, ga.held()])
	var snap_at := net.wire_index("host", CouchEnvelope.KIND_SNAPSHOT, -1, wire_before)
	var first_at := net.wire_index("ga", CouchEnvelope.KIND_INTENT, 2, wire_before)
	_check(snap_at >= 0 and first_at > snap_at, "H1[%d] the replay goes out after the resync snapshot (snapshot %d, intent %d)" % [mode, snap_at, first_at])
	var refused := 0
	for r in net.host().rejects:
		if r[1] == "ga":
			refused += 1
	_check(refused == 0, "H1[%d] the host rejects none of them (got %s)" % [mode, net.host().rejects])
	net.intent("ga", 4)
	_check(net.host().numbers_from("ga") == [1, 2, 3, 4], "H1[%d] a later intent follows the replay (got %s)" % [mode, net.host().numbers_from("ga")])


func _case_h2() -> void:
	print("-- H2 an intent in the baseline window queues behind the held ones --")
	var net := _net(1)
	var ga := net.side("ga")
	net.host().auto_snapshot = false
	ga.transport.down = true
	net.intent("ga", 2)
	_rebuild(net, "ga")
	_check(ga.session.active, "H2 the guest is live, waiting for its baseline")
	var body3 := {"n": 3}
	var r3: bool = ga.session.send_intent(body3)
	body3["n"] = 99   # the game reuses its dictionary; the hold kept a copy
	net.pump("h2")
	_check(r3, "H2 an intent in the baseline window is accepted (held)")
	_check(ga.held() == 2, "H2 both are held (got %d)" % ga.held())
	_check(net.host().numbers_from("ga").is_empty(), "H2 nothing reaches the host before the baseline (got %s)" % [net.host().numbers_from("ga")])
	net.snapshot()
	_check(net.host().numbers_from("ga") == [2, 3], "H2 the baseline releases both, in order (got %s)" % [net.host().numbers_from("ga")])


func _case_h3() -> void:
	print("-- H3 the bound --")
	var net := _net(1, 2)
	var ga := net.side("ga")
	ga.transport.down = true
	var r := [net.intent("ga", 1), net.intent("ga", 2), net.intent("ga", 3)]
	_check(r == [true, true, false], "H3 a full hold refuses the next intent (got %s)" % [r])
	_check(ga.held() == 2, "H3 the hold stays at its limit (got %d)" % ga.held())
	_rebuild(net, "ga")
	_check(net.host().numbers_from("ga") == [1, 2], "H3 the first two arrive, the refused one never (got %s)" % [net.host().numbers_from("ga")])

	var off := _net(1, 0)
	var go := off.side("ga")
	go.transport.down = true
	var r0 := off.intent("ga", 1)
	_check(not r0, "H3 with a limit of 0 a dead link refuses the intent, as before")
	_check(go.held() == 0, "H3 with a limit of 0 nothing is held (got %d)" % go.held())
	_rebuild(off, "ga")
	_check(off.host().numbers_from("ga").is_empty(), "H3 with a limit of 0 nothing is replayed (got %s)" % [off.host().numbers_from("ga")])


func _case_h4() -> void:
	print("-- H4 stop() drops the hold --")
	var net := _net(1)
	var ga := net.side("ga")
	ga.transport.down = true
	net.intent("ga", 1)
	net.intent("ga", 2)
	ga.session.stop("left")
	_check(ga.held() == 0, "H4 the hold is empty after stop (got %d)" % ga.held())
	_check(ga.dropped == [[2, "left"]], "H4 the drop is reported with the stop reason (got %s)" % [ga.dropped])
	ga.transport.down = false
	ga.session.evaluate(net.now)
	net.pump("h4")
	net.advance(1000)
	_check(net.host().numbers_from("ga").is_empty(), "H4 nothing from the old session is replayed (got %s)" % [net.host().numbers_from("ga")])


func _case_h5() -> void:
	print("-- H5 a new host epoch drops the hold --")
	var net := _net(1)
	var ga := net.side("ga")
	ga.transport.down = true
	net.intent("ga", 1)
	var host := net.host()
	host.session.stop("test-restart")
	host.session.evaluate(net.now)
	net.pump("h5-restart")
	ga.transport.down = false
	net.snapshot()
	_check(ga.dropped == [[1, "host-restarted"]], "H5 the hold is dropped as host-restarted (got %s)" % [ga.dropped])
	var r_wait := net.intent("ga", 2)
	_check(not r_wait and ga.held() == 0, "H5 waiting to join the new session, an intent is refused, not held (got %s, %d)" % [r_wait, ga.held()])
	net.advance(1000)
	net.advance(1000)
	_check(ga.session.active and ga.session.epoch == host.session.epoch, "H5 the guest joins the new session")
	_check(host.numbers_from("ga").is_empty(), "H5 the old intent never reaches the new session (got %s)" % [host.numbers_from("ga")])
	var stale := 0
	for r in host.rejects:
		if r[1] == "ga" and r[0] == "epoch-mismatch":
			stale += 1
	_check(stale == 0, "H5 and it is not sent stamped with the dead epoch (got %s)" % [host.rejects])


func _case_h6() -> void:
	print("-- H6 a refused send with no reset waits for the next snapshot --")
	var net := _net(1)
	var ga := net.side("ga")
	ga.transport.down = true
	net.intent("ga", 1)
	ga.transport.down = false
	var r2 := net.intent("ga", 2)
	_check(r2, "H6 a later intent is accepted")
	_check(net.host().numbers_from("ga").is_empty(), "H6 it does not overtake the held one (got %s)" % [net.host().numbers_from("ga")])
	_check(ga.held() == 2, "H6 both are held (got %d)" % ga.held())
	net.snapshot()
	_check(net.host().numbers_from("ga") == [1, 2], "H6 the next snapshot releases both, in order (got %s)" % [net.host().numbers_from("ga")])
	net.intent("ga", 3)
	_check(net.host().numbers_from("ga") == [1, 2, 3], "H6 then intents flow directly (got %s)" % [net.host().numbers_from("ga")])
	_check(net.host().session.gap_count == 0, "H6 the refused send cost no sequence number: no gap at the host (got %d)" % net.host().session.gap_count)


func _case_h7() -> void:
	print("-- H7 inputs are never held --")
	var net := _net(1)
	var ga := net.side("ga")
	ga.transport.down = true
	var r := ga.session.send_input({"n": 7})
	_check(not r, "H7 an input into a dead link is refused")
	_check(ga.held() == 0, "H7 nothing is held (got %d)" % ga.held())
	_rebuild(net, "ga")
	_check(net.host().inputs.is_empty(), "H7 no input is replayed (got %s)" % [net.host().inputs])


func _case_h8() -> void:
	print("-- H8 a spectator holds nothing --")
	var net := _net(1, -1, true)
	var gb := net.side("gb")
	_check(gb.session.active and gb.session.local_slot == CouchSession.SLOT_SPECTATOR, "H8 gb is a spectator")
	gb.transport.down = true
	var r := net.intent("gb", 1)
	_check(not r, "H8 a spectator's intent is refused")
	_check(gb.held() == 0, "H8 nothing is held (got %d)" % gb.held())
	gb.transport.down = false
	net.gap("host", "gb", "link-rebuild")
	net.advance(1000)
	net.snapshot()
	_check(net.host().numbers_from("gb").is_empty(), "H8 nothing is replayed (got %s)" % [net.host().numbers_from("gb")])


func _case_h9() -> void:
	print("-- H9 coming back without a slot drops the hold --")
	var net := _net(1)
	var ga := net.side("ga")
	net.host().auto_snapshot = false
	ga.transport.down = true
	net.intent("ga", 1)
	ga.transport.down = false
	# The host's reconnect hello, then one that gives ga no slot, as a host
	# that re-pinned would send. Same epoch, so this is the same session.
	var epoch := net.host().session.epoch
	ga.transport.deliver(CouchEnvelope.make(CouchEnvelope.KIND_HELLO, epoch, 900,
		{"role": "host", "slots": {"host": 0, "ga": 1}, "name": "HOST", "reconnect": true}), "host")
	ga.transport.reset_log()
	ga.transport.deliver(CouchEnvelope.make(CouchEnvelope.KIND_HELLO, epoch, 901,
		{"role": "host", "slots": {"host": 0}, "name": "HOST"}), "host")
	ga.transport.deliver(CouchEnvelope.make(CouchEnvelope.KIND_SNAPSHOT, epoch, 902, {"w": 3}), "host")
	_check(ga.session.active and ga.session.local_slot == CouchSession.SLOT_SPECTATOR, "H9 ga is back as a spectator")
	_check(ga.dropped == [[1, "slot-lost"]], "H9 the hold is dropped as slot-lost (got %s)" % [ga.dropped])
	var sent := 0
	for s in ga.transport.sends:
		if s["kind"] == CouchEnvelope.KIND_INTENT:
			sent += 1
	_check(sent == 0, "H9 nothing is put on the wire (got %d)" % sent)


func _case_h10() -> void:
	print("-- H10 Steam's provider gap holds and replays --")
	var net := _net(1)
	var ga := net.side("ga")
	net.gap("ga", "host", "steam:session-failed")
	_check(not ga.session.active, "H10 the guest's session is waiting on its link")
	var r := net.intent("ga", 1)
	_check(r, "H10 an intent while waiting is accepted (held)")
	_check(ga.held() == 1, "H10 it is held (got %d)" % ga.held())
	net.gap("host", "ga", "steam:session-failed")
	net.advance(1000)
	net.advance(1000)
	_check(ga.session.active, "H10 the guest is live again")
	_check(net.host().numbers_from("ga") == [1], "H10 the held intent arrives (got %s)" % [net.host().numbers_from("ga")])


func _case_h11() -> void:
	print("-- H11 a refusal during the replay keeps the rest --")
	var net := _net(1)
	var ga := net.side("ga")
	ga.transport.down = true
	net.intent("ga", 1)
	net.intent("ga", 2)
	ga.transport.down = false
	ga.transport.refuse = true
	net.snapshot()
	_check(ga.held() == 2, "H11 a refused replay keeps both (got %d)" % ga.held())
	_check(net.host().numbers_from("ga").is_empty(), "H11 nothing arrived (got %s)" % [net.host().numbers_from("ga")])
	ga.transport.refuse = false
	net.snapshot()
	_check(net.host().numbers_from("ga") == [1, 2], "H11 the next snapshot sends both, in order (got %s)" % [net.host().numbers_from("ga")])


func _case_h12() -> void:
	print("-- H12 before the first session nothing is held --")
	var net := _Net.new(_check)
	var players := [_p("host", "host", 0), _p("ga", "guest", 1)]
	var policy := _policy(1)
	net.players = players
	net.host_id = "host"
	net.sides["host"] = _Side.new("host", players, policy)
	net.sides["ga"] = _Side.new("ga", players, policy)
	var ga := net.side("ga")
	ga.session.evaluate(net.now)
	ga.transport.reset_log()
	var r := ga.session.send_intent({"n": 1})
	_check(not r and ga.held() == 0, "H12 an intent before the first session is refused, not held (got %s, %d)" % [r, ga.held()])
	net.host().session.evaluate(net.now)
	net.advance(1000)
	net.advance(1000)
	_check(ga.session.active, "H12 the guest joins")
	_check(net.host().numbers_from("ga").is_empty(), "H12 nothing is sent after the first snapshot (got %s)" % [net.host().numbers_from("ga")])


func _case_h13() -> void:
	print("-- H13 the time limit --")
	var net := _net(1, -1, false, 3000)
	var ga := net.side("ga")
	ga.transport.down = true
	net.intent("ga", 1)
	net.advance(1000)
	net.intent("ga", 2)
	net.advance(2000)   # 1 is exactly 3000 ms old: still held
	_check(ga.held() == 2 and ga.dropped.is_empty(), "H13 an intent exactly at the limit is kept (held %d, dropped %s)" % [ga.held(), ga.dropped])
	net.advance(1)      # 1 is now past the limit, 2 is not
	_check(ga.held() == 1, "H13 poll expires the old one without a recovery (held %d)" % ga.held())
	_check(ga.dropped == [[1, "expired"]], "H13 the expiry is reported (got %s)" % [ga.dropped])
	ga.transport.down = false
	ga.transport.refuse = false
	net.snapshot()
	_check(net.host().numbers_from("ga") == [2], "H13 only the younger intent is sent (got %s)" % [net.host().numbers_from("ga")])
	ga.transport.down = true
	net.intent("ga", 3)
	net.intent("ga", 4)
	net.advance(5000)
	_check(ga.held() == 0 and ga.dropped == [[1, "expired"], [2, "expired"]], "H13 a long outage expires everything (held %d, dropped %s)" % [ga.held(), ga.dropped])
	var r := net.intent("ga", 5)
	_check(r and ga.held() == 1, "H13 still in the outage, a new intent is held again")
	_rebuild(net, "ga")
	_check(net.host().numbers_from("ga") == [2, 5], "H13 expired intents never arrive, the fresh one does (got %s)" % [net.host().numbers_from("ga")])


func _case_h14() -> void:
	print("-- H14 intent_hold_ms = 0 turns holding off --")
	var net := _net(1, -1, false, 0)
	var ga := net.side("ga")
	ga.transport.down = true
	var r := net.intent("ga", 1)
	_check(not r and ga.held() == 0, "H14 an intent into a dead link is refused, not held (got %s, %d)" % [r, ga.held()])
	_rebuild(net, "ga")
	var r2 := net.intent("ga", 2)
	_check(r2 and net.host().numbers_from("ga") == [2], "H14 only the intent sent after recovery arrives (got %s)" % [net.host().numbers_from("ga")])
