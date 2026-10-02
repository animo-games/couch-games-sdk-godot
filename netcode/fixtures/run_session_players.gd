## Headless gate for N input players in CouchSession (max_input_players) --
## gate G13.
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_session_players.gd
##
## What this proves. CouchSession has two modes, chosen ONCE at construction by
## CouchSessionPolicy.max_input_players. LEGACY (== 1, the default, and what a
## two-argument `CouchSession.new(roster, transport)` gets) pins exactly one
## guest for the life of the session: slot 1 to the pick, -1 to every other
## guest, a roster change that loses the pin stops the session
## ("authorized-peer-left"), a spectator's hello is rejected as
## unauthorized-sender, and no player_joined/player_left ever fires. MULTI
## (> 1) makes the host's slots map the authority for who may send: the first N
## guests, in (controller_slot asc, user_id asc) order, get slots 1..N; a guest
## that leaves frees its slot WITHOUT stopping the session or changing the
## epoch; a newcomer or a waiting spectator takes the lowest free slot; every
## slot change is announced to the host's game through player_joined /
## player_left and to the affected guest through local_slot_changed.
##
## Case L1 is the LEGACY spec: it must stay green on today's code and after the
## change, because "bit-for-bit unchanged" is the promise. Cases M1-M13 are the
## multi-mode contract. M1-M10 were written first (gate-first) against inert
## stubs; M11-M13 were added after mutation testing left three mutations green
## (unsorted departures, no tracker pre-seed on a mid-session grant, an
## unconditional re-seed that erases a spectator's hello history).
##
## HARNESS. Entirely synchronous: no WebRTC, no await, no real clock. Each
## participant (`_Side`) is a CouchScriptedRoster + CouchScriptedTransport + a
## real CouchSession, with every signal recorded in order. `_Net` wires them
## into a star: the host's "broadcast" is delivered to every other side with the
## host as sender, "peer:<id>" to that side, and a guest's "authority" send to
## the host with the guest as sender. The scripted transport logs a send's
## fields separately, so the pump rebuilds each envelope with
## CouchEnvelope.make and delivers it raw -- no codec in the way. `pump()`
## loops until no side has a pending send, with an iteration cap whose breach
## is itself a FAIL. A leaver is simply dropped from routing; a newcomer is a
## fresh side (a fresh session, so its sequence numbers restart at 1, exactly
## like a real rejoin).
##
## VIRTUAL CLOCK. The host rate-limits hello replies per sender
## (HELLO_STATE_REQUEST_MIN_INTERVAL_MS = 250) and a not-yet-active guest
## re-sends its hello every HELLO_RETRY_MS = 500 from poll(). `_Net.now` is a
## file-wide virtual clock and `advance(ms)` poll()s every side then pumps; the
## cases advance a full second between phases so neither timer can make a
## result depend on how fast the harness happened to run.
##
## Every assertion is on an OBSERVED EFFECT: a recorded signal, an envelope the
## host actually received, a host-side `rejected`. The send gate is never
## proven by a send's return value alone: where one is checked it is paired
## with an INJECTED envelope at the host (the host gate is what actually
## protects the game, the guest's gate only saves bandwidth) and with the
## host's input_received count not moving.
##
## LOAD-BEARING GOTCHA: SceneTree.quit(code) only SCHEDULES termination; it
## does not return. `return` follows the one quit(...) in this file.
extends SceneTree

const PUMP_CAP := 200
const INJECT_SEQ_BASE := 1000

var failures := 0
var _checks := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("  PASS: " + message)
	else:
		failures += 1
		printerr("  FAIL: " + message)


static func _p(id: String, role: String, controller_slot: int) -> Dictionary:
	return {"userId": id, "username": id.to_upper(), "role": role, "controllerSlot": controller_slot}


## One participant: roster + transport doubles, a real session, and ordered
## recordings of everything the session emitted.
class _Side extends RefCounted:
	var id: String
	var roster: CouchScriptedRoster
	var transport: CouchScriptedTransport
	var session: CouchSession
	var events: Array = []        # ordered strings: started / stopped:<r> / joined:<id>:<s> / left:<id>:<s> / slot:<old>:<new>
	var started: Array = []       # {epoch, is_host, slot, peer}
	var stopped: Array = []       # reason strings
	var joined: Array = []        # {id, slot}
	var left: Array = []          # {id, slot}
	var slot_changes: Array = []  # {old, new}
	var inputs: Array = []        # {sender, body}
	var rejects: Array = []       # {reason, sender}
	var hellos: Array = []        # sender ids (host hello_received)

	func _init(p_id: String, players: Array, policy_n: int) -> void:
		id = p_id
		roster = CouchScriptedRoster.new(p_id, players)
		transport = CouchScriptedTransport.new()
		if policy_n <= 0:
			session = CouchSession.new(roster, transport)   # legacy: two args, no policy
		else:
			var policy := CouchSessionPolicy.new()
			policy.max_input_players = policy_n
			session = CouchSession.new(roster, transport, policy)
		session.session_started.connect(func(epoch: int, is_host: bool, slot: int, peer: String, _name: String):
			events.append("started")
			started.append({"epoch": epoch, "is_host": is_host, "slot": slot, "peer": peer})
		)
		session.session_stopped.connect(func(reason: String):
			events.append("stopped:" + reason)
			stopped.append(reason)
		)
		session.input_received.connect(func(body: Dictionary, sender: String):
			inputs.append({"sender": sender, "body": body})
		)
		session.rejected.connect(func(reason: String, sender: String):
			rejects.append({"reason": reason, "sender": sender})
		)
		session.hello_received.connect(func(sender: String):
			hellos.append(sender)
		)
		# Signals that do not exist yet (gate-first) must not break parsing of the
		# gate; the session declares them as inert API, so connecting is safe.
		session.player_joined.connect(func(peer: String, slot: int):
			events.append("joined:%s:%d" % [peer, slot])
			joined.append({"id": peer, "slot": slot})
		)
		session.player_left.connect(func(peer: String, slot: int):
			events.append("left:%s:%d" % [peer, slot])
			left.append({"id": peer, "slot": slot})
		)
		session.local_slot_changed.connect(func(old_slot: int, new_slot: int):
			events.append("slot:%d:%d" % [old_slot, new_slot])
			slot_changes.append({"old": old_slot, "new": new_slot})
		)

	func inputs_from(sender: String) -> int:
		var n := 0
		for entry in inputs:
			if entry["sender"] == sender:
				n += 1
		return n

	func rejects_of(sender: String, reason: String = "") -> int:
		var n := 0
		for entry in rejects:
			if entry["sender"] == sender and (reason.is_empty() or entry["reason"] == reason):
				n += 1
		return n


## The star: sides keyed by id, the host first. `wire` logs every routed
## envelope so a case can assert on what the host actually broadcast.
class _Net extends RefCounted:
	var sides: Dictionary = {}
	var host_id: String = ""
	var policy_n: int
	var now: int = 1000
	var wire: Array = []          # {from, to, env}
	var _inject_seq: Dictionary = {}
	var _check_cb: Callable

	func _init(p_policy_n: int, check_cb: Callable) -> void:
		policy_n = p_policy_n
		_check_cb = check_cb

	func side(id: String) -> _Side:
		return sides[id]

	func host() -> _Side:
		return sides[host_id]

	## Build one side per player (host first so it evaluates first), evaluate
	## everyone, and pump the handshake to quiescence.
	func boot(players: Array) -> void:
		for player in players:
			if player["role"] == "host":
				host_id = player["userId"]
				sides[host_id] = _Side.new(host_id, players, policy_n)
		for player in players:
			if player["role"] != "host":
				sides[player["userId"]] = _Side.new(player["userId"], players, policy_n)
		_evaluate_all()
		pump("boot")

	## Like boot(), but every GUEST evaluates (and sends its first hello) and the
	## hellos are pumped to the not-yet-engaged host BEFORE the host evaluates.
	## The host session drops envelopes while unengaged, so those hellos are lost.
	func boot_guests_first(players: Array) -> void:
		for player in players:
			if player["role"] == "host":
				host_id = player["userId"]
				sides[host_id] = _Side.new(host_id, players, policy_n)
		for player in players:
			if player["role"] != "host":
				sides[player["userId"]] = _Side.new(player["userId"], players, policy_n)
		for id in sides.keys():
			if id != host_id:
				(sides[id] as _Side).session.evaluate(now)
		pump("boot_guests_first/guests")
		host().session.evaluate(now)
		pump("boot_guests_first/host")

	## Set every remaining side's roster, evaluate each, pump.
	func set_roster(players: Array) -> void:
		for id in sides.keys():
			(sides[id] as _Side).roster.set_players(players)
		_evaluate_all()
		pump("set_roster")

	## A newcomer is a fresh side (fresh session, seqs from 1).
	func join(id: String, players: Array) -> void:
		sides[id] = _Side.new(id, players, policy_n)
		set_roster(players)

	## A leaver is dropped from routing; its session is just discarded.
	func leave(id: String, remaining_players: Array) -> void:
		sides.erase(id)
		set_roster(remaining_players)

	func advance(ms: int) -> void:
		now += ms
		for id in sides.keys():
			(sides[id] as _Side).session.poll(now)
		pump("advance")

	## Send an input from a guest session, pump, and return send_input's result
	## (callers pair it with an observed effect).
	func guest_input(id: String, tag: String) -> bool:
		var accepted: bool = (sides[id] as _Side).session.send_input({"t": tag})
		pump("guest_input")
		return accepted

	## Deliver a raw envelope at the HOST as if `sender` sent it, stamped with
	## the host's own epoch so only the sender gate (not the epoch gate) decides.
	func inject(kind: String, sender: String, body: Dictionary = {}) -> void:
		var seq := int(_inject_seq.get(sender, INJECT_SEQ_BASE)) + 1
		_inject_seq[sender] = seq
		var epoch := host().session.epoch
		if kind == CouchEnvelope.KIND_HELLO:
			epoch = CouchEnvelope.UNKNOWN_EPOCH
		host().transport.deliver(CouchEnvelope.make(kind, epoch, seq, body), sender)
		pump("inject")

	func _evaluate_all() -> void:
		for id in sides.keys():
			(sides[id] as _Side).session.evaluate(now)

	## Route logged sends until no side has anything pending. Failing to settle
	## within PUMP_CAP rounds is itself a FAIL.
	func pump(where: String) -> void:
		for _round in PUMP_CAP:
			var moved := 0
			for id in sides.keys():
				var origin: _Side = sides[id]
				var batch: Array = origin.transport.sends.duplicate()
				origin.transport.reset_log()
				for entry in batch:
					moved += 1
					var env := CouchEnvelope.make(
						str(entry["kind"]), int(entry["epoch"]), int(entry["seq"]), entry["body"]
					)
					var to := str(entry["to"])
					wire.append({"from": origin.id, "to": to, "env": env})
					_route(origin, to, env)
			if moved == 0:
				return
		_check_cb.call(false, "pump(%s) settles within %d rounds" % [where, PUMP_CAP])

	func _route(origin: _Side, to: String, env: Dictionary) -> void:
		if to == "broadcast":
			for id in sides.keys():
				if id != origin.id:
					(sides[id] as _Side).transport.deliver(env, origin.id)
		elif to == "authority":
			if sides.has(host_id):
				(sides[host_id] as _Side).transport.deliver(env, origin.id)
		elif to.begins_with("peer:"):
			var target := to.substr(5)
			if sides.has(target):
				(sides[target] as _Side).transport.deliver(env, origin.id)


func _run() -> void:
	_case_l1()
	_case_m1()
	_case_m2()
	_case_m3()
	_case_m4()
	_case_m5()
	_case_m6()
	_case_m7()
	_case_m8()
	_case_m9()
	_case_m10()
	_case_m11()
	_case_m12()
	_case_m13()

	print("")
	if failures > 0:
		printerr("COUCH_SESSION_PLAYERS_FAILED: %d check(s)" % failures)
	else:
		print("COUCH_SESSION_PLAYERS_OK: %d check(s)" % _checks)
	quit(failures)
	return


func _net(n: int) -> _Net:
	return _Net.new(n, _check)


## Hello broadcasts the host put on the wire at or after wire index `from`.
func _host_hellos(net: _Net, from: int) -> Array:
	var out: Array = []
	for i in range(from, net.wire.size()):
		var w: Dictionary = net.wire[i]
		if w["from"] == net.host_id and w["to"] == "broadcast" and w["env"]["kind"] == CouchEnvelope.KIND_HELLO:
			out.append(w["env"])
	return out


func _slice(events: Array, from: int) -> Array:
	return events.slice(from)


# --- L1: legacy default policy ---------------------------------------------------


func _case_l1() -> void:
	print("L1: legacy (default policy), one pinned guest")
	var h := _p("h", "host", 0)
	var players := [h, _p("g1", "guest", 1), _p("g2", "guest", 2)]
	var net := _net(0)
	net.boot(players)
	net.advance(1000)
	var host := net.host()
	var g1 := net.side("g1")
	var g2 := net.side("g2")

	_check(host.session.active and host.session.epoch != CouchEnvelope.UNKNOWN_EPOCH, "L1: host active with a minted epoch")
	_check(host.started.size() == 1 and host.started[0]["peer"] == "g1", "L1: host session_started names g1 as the peer")
	_check(g1.session.active and g1.session.local_slot == 1, "L1: g1 active at slot 1")
	# A legacy spectator IS active: it adopts the host's mint-time broadcast hello,
	# which carries the slots map with its own entry at -1. Its slot is what matters.
	_check(g2.session.local_slot == -1, "L1: g2 holds slot -1 (spectator)")
	_check(
		host.session.slots == {"h": 0, "g1": 1, "g2": -1},
		"L1: host slots map is {h:0, g1:1, g2:-1}"
	)
	_check(host.rejects_of("g2", "unauthorized-sender") >= 1, "L1: g2's own hello was rejected unauthorized-sender at the host")
	_check(host.joined.is_empty() and host.left.is_empty() and g1.joined.is_empty() and g2.joined.is_empty(), "L1: no player_joined/player_left fires anywhere in legacy mode")

	net.guest_input("g1", "a")
	_check(host.inputs_from("g1") == 1, "L1: g1's input reached the host input_received from g1")

	var rejects_before := host.rejects_of("g2", "unauthorized-sender")
	var accepted := net.guest_input("g2", "x")
	_check(not accepted, "L1: g2.send_input returns false")
	net.inject(CouchEnvelope.KIND_INPUT, "g2", {"t": "x"})
	_check(host.rejects_of("g2", "unauthorized-sender") == rejects_before + 1, "L1: an injected input from g2 is rejected unauthorized-sender at the host")
	_check(host.inputs_from("g2") == 0, "L1: the host never saw an input from g2")

	var old_epoch := host.session.epoch
	var mark := host.events.size()
	net.advance(1000)
	net.leave("g1", [h, _p("g2", "guest", 2)])
	var tail := _slice(host.events, mark)
	_check(tail == ["stopped:authorized-peer-left", "started"], "L1: g1 leaving -> host session_stopped(authorized-peer-left) then a new session_started")
	_check(host.started.size() == 2 and host.started[1]["epoch"] != old_epoch and host.started[1]["peer"] == "g2", "L1: the new session has a NEW epoch and peer g2")
	net.advance(1000)
	_check(g2.session.active and g2.session.local_slot == 1, "L1: g2 becomes active at slot 1 in the new session")
	_check(host.joined.is_empty(), "L1: still no player_joined after the restart")


# --- M1: N=3, two guests ----------------------------------------------------------


func _case_m1() -> void:
	print("M1: multi N=3, two guests get slots 1 and 2")
	var players := [_p("h", "host", 0), _p("g1", "guest", 1), _p("g2", "guest", 2)]
	var net := _net(3)
	net.boot(players)
	net.advance(1000)
	var host := net.host()
	var g1 := net.side("g1")
	var g2 := net.side("g2")

	_check(host.events == ["started", "joined:g1:1", "joined:g2:2"], "M1: host emits session_started then player_joined(g1,1), player_joined(g2,2) in order")
	_check(g1.session.active and g1.session.local_slot == 1, "M1: g1 active at local_slot 1")
	_check(g2.session.active and g2.session.local_slot == 2, "M1: g2 active at local_slot 2")
	net.guest_input("g1", "a")
	net.guest_input("g2", "b")
	_check(host.inputs_from("g1") == 1 and host.inputs_from("g2") == 1, "M1: both guests' inputs reach the host with the right sender")
	_check(host.session.slots == {"h": 0, "g1": 1, "g2": 2}, "M1: host slots == {h:0, g1:1, g2:2}")
	_check(host.session.max_input_players == 3, "M1: max_input_players getter reports 3")


# --- M2: ordering -----------------------------------------------------------------


func _case_m2() -> void:
	print("M2: slots follow (controllerSlot asc, user_id asc)")
	# Roster order is deliberately scrambled; amy and zed tie on controllerSlot 1.
	var players := [_p("h", "host", 0), _p("zed", "guest", 1), _p("amy", "guest", 1), _p("bob", "guest", 0)]
	var net := _net(3)
	net.boot(players)
	net.advance(1000)
	_check(
		net.host().session.slots == {"h": 0, "bob": 1, "amy": 2, "zed": 3},
		"M2: N=3 slots are bob:1 (cs 0), amy:2, zed:3 (cs tie -> user_id)"
	)
	_check(
		net.host().events == ["started", "joined:bob:1", "joined:amy:2", "joined:zed:3"],
		"M2: player_joined fires in ascending slot order"
	)
	var net2 := _net(2)
	net2.boot(players)
	net2.advance(1000)
	_check(
		net2.host().session.slots == {"h": 0, "bob": 1, "amy": 2, "zed": -1},
		"M2: N=2 cuts off the worst-ordered guest (zed) as a spectator"
	)


# --- M3: leave ----------------------------------------------------------------------


func _case_m3() -> void:
	print("M3: a slot holder leaves without stopping the session")
	var h := _p("h", "host", 0)
	var g2p := _p("g2", "guest", 2)
	var net := _net(3)
	net.boot([h, _p("g1", "guest", 1), g2p])
	net.advance(1000)
	var host := net.host()
	var g2 := net.side("g2")
	var epoch := host.session.epoch
	var host_mark := host.events.size()
	var g2_mark := g2.events.size()
	var wire_mark := net.wire.size()

	net.leave("g1", [h, g2p])
	net.advance(1000)

	_check(_slice(host.events, host_mark) == ["left:g1:1"], "M3: host emits exactly player_left(g1,1) -- no session_stopped")
	_check(host.stopped.is_empty() and g2.stopped.is_empty(), "M3: no session_stopped on host or g2")
	_check(host.session.epoch == epoch and g2.session.epoch == epoch, "M3: epoch unchanged on host and g2")
	_check(_slice(g2.events, g2_mark).is_empty() and g2.session.local_slot == 2, "M3: g2 still at slot 2 and saw no events")
	var before := host.inputs_from("g2")
	net.guest_input("g2", "after")
	_check(host.inputs_from("g2") == before + 1, "M3: g2's next input is received by the host")
	var hellos := _host_hellos(net, wire_mark)
	var ok := not hellos.is_empty()
	for env in hellos:
		var s: Dictionary = env["body"].get("slots", {})
		ok = ok and not s.has("g1") and int(s.get("g2", -9)) == 2
	_check(ok, "M3: host broadcast a hello whose slots no longer contain g1")


# --- M4: join -----------------------------------------------------------------------


func _case_m4() -> void:
	print("M4: a newcomer takes the lowest free slot")
	var h := _p("h", "host", 0)
	var g2p := _p("g2", "guest", 2)
	var g3p := _p("g3", "guest", 3)
	var net := _net(3)
	net.boot([h, _p("g1", "guest", 1), g2p])
	net.advance(1000)
	net.leave("g1", [h, g2p])
	net.advance(1000)
	var host := net.host()
	var g2 := net.side("g2")
	var epoch := host.session.epoch
	var host_mark := host.events.size()
	var wire_mark := net.wire.size()

	net.join("g3", [h, g2p, g3p])
	net.advance(1000)
	var g3 := net.side("g3")

	_check(_slice(host.events, host_mark) == ["joined:g3:1"], "M4: host emits exactly player_joined(g3,1) (lowest free slot)")
	_check(g3.session.active and g3.session.local_slot == 1, "M4: g3 active with local_slot 1")
	_check(g3.started.size() == 1 and g3.started[0]["epoch"] == epoch, "M4: g3's session_started carries the host's epoch")
	net.guest_input("g3", "n")
	_check(host.inputs_from("g3") == 1, "M4: g3's input is received by the host")
	_check(host.stopped.is_empty() and g2.stopped.is_empty() and g3.stopped.is_empty(), "M4: no session_stopped anywhere")
	_check(g2.slot_changes.is_empty() and g2.session.local_slot == 2, "M4: g2 saw no local_slot_changed")
	var hellos := _host_hellos(net, wire_mark)
	var ok := not hellos.is_empty()
	for env in hellos:
		ok = ok and int(env["body"].get("slots", {}).get("g3", -9)) == 1
	_check(ok, "M4: the host's hello broadcast carries g3's slot")


# --- M5: cap + promotion ------------------------------------------------------------


func _case_m5() -> void:
	print("M5: cap N=2, a waiting spectator is promoted into a freed slot")
	var h := _p("h", "host", 0)
	var g2p := _p("g2", "guest", 2)
	var g3p := _p("g3", "guest", 3)
	var net := _net(2)
	net.boot([h, _p("g1", "guest", 1), g2p, g3p])
	net.advance(1000)
	var host := net.host()
	var g3 := net.side("g3")

	_check(host.session.slots == {"h": 0, "g1": 1, "g2": 2, "g3": -1}, "M5: host slots give g3 -1")
	_check(g3.session.active and g3.session.local_slot == -1, "M5: g3 is active (hello accepted and answered) at slot -1")
	_check(host.hellos.has("g3") and host.rejects_of("g3") == 0, "M5: host answered g3's hello and rejected nothing from g3")
	var accepted := net.guest_input("g3", "x")
	_check(not accepted, "M5: g3.send_input returns false")
	net.inject(CouchEnvelope.KIND_INPUT, "g3", {"t": "x"})
	_check(host.rejects_of("g3", "unauthorized-sender") == 1, "M5: an injected input from g3 is rejected unauthorized-sender at the host")
	_check(host.inputs_from("g3") == 0, "M5: the host never saw an input from g3")

	var host_mark := host.events.size()
	net.leave("g1", [h, g2p, g3p])
	net.advance(1000)
	_check(_slice(host.events, host_mark) == ["left:g1:1", "joined:g3:1"], "M5: g1 leaving -> player_left(g1,1) then player_joined(g3,1) in that order")
	_check(g3.slot_changes == [{"old": -1, "new": 1}], "M5: g3 emits local_slot_changed(-1,1)")
	_check(g3.session.local_slot == 1, "M5: g3's local_slot is now 1")
	net.guest_input("g3", "now")
	_check(host.inputs_from("g3") == 1, "M5: g3's input is now received by the host")


# --- M6: rejoin ---------------------------------------------------------------------


func _case_m6() -> void:
	print("M6: a rejoiner restarting its sequence numbers is not rejected as a duplicate")
	var h := _p("h", "host", 0)
	var g1p := _p("g1", "guest", 1)
	var g2p := _p("g2", "guest", 2)
	var net := _net(3)
	net.boot([h, g1p, g2p])
	net.advance(1000)
	var host := net.host()
	for i in 3:
		net.guest_input("g1", "old%d" % i)
	_check(host.inputs_from("g1") == 3, "M6: (setup) three inputs from the first g1 session arrived")

	net.leave("g1", [h, g2p])
	net.advance(1000)
	net.join("g1", [h, g1p, g2p])
	net.advance(1000)
	var g1 := net.side("g1")
	_check(g1.session.active and g1.session.local_slot == 1, "M6: the rejoined g1 is active at slot 1")
	for i in 2:
		net.guest_input("g1", "new%d" % i)
	_check(host.inputs_from("g1") == 5, "M6: the rejoiner's inputs are received (3 old + 2 new)")
	_check(host.rejects_of("g1") == 0, "M6: zero rejections from g1 at the host (no duplicate-style rejection)")


# --- M7: host restart ---------------------------------------------------------------


func _case_m7() -> void:
	print("M7: host restart in multi mode (D8)")
	var players := [_p("h", "host", 0), _p("g1", "guest", 1), _p("g2", "guest", 2)]
	var net := _net(3)
	net.boot(players)
	net.advance(1000)
	var host := net.host()
	var g1 := net.side("g1")
	var g2 := net.side("g2")
	var old_epoch := host.session.epoch
	var slots_before: Dictionary = host.session.slots
	var host_mark := host.events.size()
	var g1_mark := g1.events.size()
	var g2_mark := g2.events.size()

	host.session.stop("test")
	net.advance(1000)
	net.set_roster(players)
	net.advance(1000)

	var new_epoch := host.session.epoch
	_check(new_epoch != CouchEnvelope.UNKNOWN_EPOCH and new_epoch != old_epoch, "M7: the host minted a NEW epoch")
	_check(
		_slice(host.events, host_mark) == ["stopped:test", "started", "joined:g1:1", "joined:g2:2"],
		"M7: host emits session_started then player_joined for both guests again, after the restart"
	)
	for g in [g1, g2]:
		var tail := _slice((g as _Side).events, g1_mark if g == g1 else g2_mark)
		_check(tail == ["stopped:host-restarted", "started"], "M7: %s emits session_stopped(host-restarted) then session_started" % (g as _Side).id)
		_check((g as _Side).started.back()["epoch"] == new_epoch, "M7: %s's new session carries the new epoch" % (g as _Side).id)
	_check(host.session.slots == slots_before, "M7: the host's slots map is the same")
	_check(g1.session.local_slot == 1 and g2.session.local_slot == 2, "M7: guests keep slots 1 and 2")
	var b1 := host.inputs_from("g1")
	var b2 := host.inputs_from("g2")
	net.guest_input("g1", "p")
	net.guest_input("g2", "q")
	_check(host.inputs_from("g1") == b1 + 1 and host.inputs_from("g2") == b2 + 1, "M7: both guests' inputs are received at the new epoch")


# --- M8: roster shrinks to the host --------------------------------------------------


func _case_m8() -> void:
	print("M8: roster drops to host-only in multi mode")
	var h := _p("h", "host", 0)
	var net := _net(3)
	net.boot([h, _p("g1", "guest", 1), _p("g2", "guest", 2)])
	net.advance(1000)
	var host := net.host()
	var mark := host.events.size()
	# Both guests vanish in ONE roster change; two sequential leaves would hit the
	# legacy pin-absent stop on the first.
	net.sides.erase("g1")
	net.leave("g2", [h])
	_check(host.stopped.size() == 1 and host.stopped[0] == "roster-too-small", "M8: host session_stopped(roster-too-small)")
	var left_after := false
	for ev in _slice(host.events, mark):
		if str(ev).begins_with("left:"):
			left_after = true
	_check(not left_after, "M8: no player_left was emitted")
	_check(host.left.is_empty(), "M8: host recorded no player_left at all")


# --- M9: non-roster sender ------------------------------------------------------------


func _case_m9() -> void:
	print("M9: a sender who is not in the roster is rejected at a multi host")
	var net := _net(3)
	net.boot([_p("h", "host", 0), _p("g1", "guest", 1), _p("g2", "guest", 2)])
	net.advance(1000)
	var host := net.host()
	var inputs_before := host.inputs.size()
	net.inject(CouchEnvelope.KIND_INPUT, "ghost", {"t": "i"})
	net.inject(CouchEnvelope.KIND_HELLO, "ghost", {"role": "guest", "name": "x"})
	_check(host.rejects_of("ghost", "unauthorized-sender") == 2, "M9: the injected input AND hello from a non-roster sender are each rejected unauthorized-sender")
	_check(host.inputs.size() == inputs_before and not host.hellos.has("ghost"), "M9: no input accepted and no hello answered for the stranger")


# --- M10: spectator leaves ------------------------------------------------------------


func _case_m10() -> void:
	print("M10: a waiting spectator leaving does not emit player_left")
	var h := _p("h", "host", 0)
	var g1p := _p("g1", "guest", 1)
	var g2p := _p("g2", "guest", 2)
	var net := _net(2)
	net.boot([h, g1p, g2p, _p("g3", "guest", 3)])
	net.advance(1000)
	var host := net.host()
	var mark := host.events.size()
	var wire_mark := net.wire.size()
	net.leave("g3", [h, g1p, g2p])
	net.advance(1000)
	_check(host.left.is_empty() and _slice(host.events, mark).is_empty(), "M10: no player_left (and no other host event) when the spectator leaves")
	_check(host.session.slots == {"h": 0, "g1": 1, "g2": 2}, "M10: slots updated to {h:0, g1:1, g2:2}")
	var hellos := _host_hellos(net, wire_mark)
	var ok := not hellos.is_empty()
	for env in hellos:
		ok = ok and not env["body"].get("slots", {}).has("g3")
	_check(ok, "M10: the host re-broadcast a hello without g3")


# --- M11: departures in ascending slot order -------------------------------------------


func _case_m11() -> void:
	print("M11: simultaneous departures are announced in ascending slot order")
	var h := _p("h", "host", 0)
	var g1p := _p("g1", "guest", 1)
	var g2p := _p("g2", "guest", 2)
	var g3p := _p("g3", "guest", 3)
	var g4p := _p("g4", "guest", 4)
	var net := _net(3)
	net.boot([h, g1p, g2p, g4p])
	net.advance(1000)
	var host := net.host()
	_check(host.session.slots == {"h": 0, "g1": 1, "g2": 2, "g4": 3}, "M11: (setup) slots are g1:1, g2:2, g4:3")
	net.leave("g1", [h, g2p, g4p])
	net.advance(1000)
	net.join("g3", [h, g2p, g4p, g3p])
	net.advance(1000)
	_check(int(host.session.slots.get("g3", -9)) == 1, "M11: (setup) g3 took slot 1, so it sits AFTER g2 in the slots map's insertion order")
	var mark := host.events.size()
	# g2 and g3 leave in ONE roster change; the roster stays at h + g4.
	net.sides.erase("g3")
	net.leave("g2", [h, g4p])
	var tail := _slice(host.events, mark)
	_check(tail.slice(0, 2) == ["left:g3:1", "left:g2:2"], "M11: the step's events begin with left:g3:1 then left:g2:2 (ascending slot, not insertion order)")
	_check(host.stopped.is_empty(), "M11: the session did not stop")


# --- M12: promoted spectator whose hello never reached the host --------------------------


func _case_m12() -> void:
	print("M12: promotion of a spectator whose own hello was never accepted")
	var h := _p("h", "host", 0)
	var g2p := _p("g2", "guest", 2)
	var g3p := _p("g3", "guest", 3)
	var net := _net(2)
	# Guests evaluate and hello first; the unengaged host drops those hellos.
	net.boot_guests_first([h, _p("g1", "guest", 1), g2p, g3p])
	var host := net.host()
	var g3 := net.side("g3")
	_check(host.hellos.is_empty(), "M12: the host never emitted hello_received for anyone (all hellos were dropped)")
	_check(g3.session.active and g3.session.local_slot == -1, "M12: g3 is active at slot -1 off the mint-time broadcast hello alone")

	net.leave("g1", [h, g2p, g3p])
	_check(g3.slot_changes == [{"old": -1, "new": 1}], "M12: g3 is promoted: local_slot_changed(-1,1)")
	net.guest_input("g3", "p")
	_check(host.inputs_from("g3") == 1, "M12: the host received g3's input")
	_check(host.rejects_of("g3") == 0, "M12: zero rejections from g3 (no epoch-mismatch)")
	_check(not host.hellos.has("g3"), "M12: g3's own hello was still never accepted (the clock was not advanced)")


# --- M13: promoted spectator keeps its hello sequence history ----------------------------


func _case_m13() -> void:
	print("M13: a promoted spectator's tracker keeps its hello history")
	var h := _p("h", "host", 0)
	var g2p := _p("g2", "guest", 2)
	var g3p := _p("g3", "guest", 3)
	var net := _net(2)
	net.boot([h, _p("g1", "guest", 1), g2p, g3p])
	net.advance(1000)
	var host := net.host()
	_check(host.hellos.has("g3"), "M13: (setup) the host accepted a hello from g3")
	var captured: Dictionary = {}
	for w in net.wire:
		if w["from"] == "g3" and w["to"] == "authority" and w["env"]["kind"] == CouchEnvelope.KIND_HELLO:
			captured = w["env"]
	_check(not captured.is_empty(), "M13: (setup) captured the last hello g3 sent")

	net.leave("g1", [h, g2p, g3p])
	net.advance(1000)
	_check(net.side("g3").session.local_slot == 1, "M13: g3 is promoted to slot 1")
	var hellos_before := host.hellos.count("g3")
	var dup_before := host.rejects_of("g3", "duplicate")
	host.transport.deliver(captured, "g3")
	net.pump("m13 redeliver")
	_check(host.rejects_of("g3", "duplicate") == dup_before + 1, "M13: re-delivering the captured hello is rejected as duplicate")
	_check(host.hellos.count("g3") == hellos_before, "M13: no new hello_received for g3")
