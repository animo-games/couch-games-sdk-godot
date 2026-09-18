## Headless full-stack gate: CouchSession on top of a REAL CouchStarTransport,
## one process -- gate G9.
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_star_session.gd
##
## What is REAL under test: CouchSession, CouchStarTransport, CouchEnvelope's
## binary codec, and real WebRTCPeerConnections on a real establishment path
## over CouchScriptedSignaling. The only doubles are the signaling
## (netcode/fixtures/scripted_signaling.gd) and the roster
## (netcode/fixtures/scripted_roster.gd -- it satisfies BOTH the session's
## roster contract and the star's lobby contract, so one object stands in for
## CouchLobby at both layers, exactly as the real CouchLobby would). run_star_link.gd
## (G8) proves the star carries traffic; the transport corpus (G2/G3) proves the
## session over a scripted transport and the lobby tunnel. Neither puts a
## CouchSession on a star, and the seam between them has rules of its own --
## the poll order, the boot-time hello that the star refuses before the link is
## up, the restart that arrives as a signaling rejoin -- which is what this
## file exists to prove. Every assertion is on an OBSERVED EFFECT (a signal
## fired, a counter moved, an envelope that arrived) and never solely on a
## send's return value; the two places a return value is checked are paired
## with a lane-tally witness of the same non-send.
##
## REQUIRES a concrete WebRTC implementation. A missing one is a FAIL here, not
## a skip, and the run is NOT short-circuited -- same discipline as G8.
##
## POLL ORDER IS THE FIRST THING PROVED. star_transport.gd's header: "The
## driver MUST call poll(now_ms) before session.poll(now_ms), so a frame's
## arrivals are dispatched before the session's timers advance over them."
## _Side.poll() is the ONLY place either poll is called, in that order. The
## proof (section 3) makes the order observable with a VIRTUAL CLOCK and a
## deliberately UNPOLLED guest: the guest's hello retry fires on the virtual
## timer; the host is polled ALONE until it has answered and the reply has had
## REPLY_SETTLE_MS of real time to land in the guest's peer; then ONE guest
## frame runs with the retry due again. Correct order: star.poll dispatches the
## reply, the session goes active, session.poll sends nothing. Swapped order:
## session.poll fires a redundant hello first, then star.poll makes it active
## -- one extra RELIABLE frame on the guest's lane tally, and one extra hello at
## the host. Swap the two lines in _Side.poll and section 3 goes red.
##
## VIRTUAL CLOCK, as in run_star_faults.gd: `_step(sides, dt_ms)` does `await
## process_frame`, advances one file-wide `_virtual_now` by `dt_ms`, then polls
## every side passed in. Neither the star nor the session reads a clock of its
## own, so `dt_ms == 0` (the default) lets real engine work proceed without
## moving any timer, and an explicit `dt_ms` fires exactly the timer this file
## means to fire. `_step()` is the ONLY place `await process_frame` appears.
##
## THREE INTEGRATION FACTS THIS FILE PINS, stated here because each is a
## behaviour a game author will meet on the star and not on the tunnel:
##   1. The boot hello is REFUSED, and its seq is spent. A game evaluates its
##      session at boot, before the star's link is up; the star refuses the
##      guest's first hello (correctly -- nothing is connected) but the
##      session's per-kind counter has already advanced, so the first hello the
##      host ever sees is seq 2 and the host reports ONE phantom
##      sequence_gap("hello", guest, 1). envelope.gd documents the same
##      residual across an epoch change; this is the boot-time instance of it,
##      specific to a transport that is not ready at evaluate() time. Pinned in
##      section 3, and again after the restart in section 6 (missing == 2).
##   2. peer_lost does NOT stop a session. CouchSession subscribes to
##      envelope_received and transport_gap only. A departure is a ROSTER fact
##      -- the platform's lobby drops the player, the game calls evaluate(),
##      the session stops with "authorized-peer-left" -- exactly as on the
##      lobby tunnel, whose peer_lost is itself derived from the roster. Section
##      7 proves the star's peer_lost fires on guest close() AND that the
##      session stays active until the roster says otherwise. That second
##      assertion is a deliberate DESIGN PIN: wiring peer_lost into the session
##      is a decision, and this line is where it must be made consciously.
##   3. A host restart is a signaling REJOIN, and incarnation labels are
##      per-process. The dead host's signaling close() reaches the guest as
##      peer_left(host); the new host's connect_room() reaches it as
##      peer_joined(host). The guest tears its link down (peer_lost,
##      transport_gap "peer-rejoined" -- which reaches the guest SESSION), so
##      the restarted host's first offer is an INITIAL adoption on a fresh peer:
##      no handshake-restart, no follow budget spent. Labels are minted above a
##      per-instance random seed (CouchStarTransport.INCARNATION_SEED_BITS), so
##      the restarted host's label is distinct from the dead one's; what is
##      asserted is that the guest follows the restarted host, that both ends
##      agree on the label afterwards, and that it differs from the old one.
##      The case where signaling does NOT report the restart is G11 F24's
##      territory, not this file's.
##
## HONESTY RISKS, stated plainly:
##   - Section 3's premise ("the reply is in the guest's peer before the
##     decisive frame") rests on REPLY_SETTLE_MS of real time on loopback,
##     with the guest's WebRTCMultiplayerPeer left unpolled so the packet can
##     only queue. A machine slow enough to miss that window fails the PREMISE
##     assertion, which is labelled as such, before the ordering assertion
##     that depends on it.
##   - Section 6's re-establishment wait runs with dt_ms == 0, so it relies on
##     the restarted host's offer reaching the guest AFTER the guest has
##     processed peer_joined(host). Both are call_deferred from the same
##     connect_room() resolution and the offer additionally needs async SDP
##     generation, so the order holds structurally -- but if it ever did not,
##     the guest would drop the offer as "departed" and the host's
##     SDP_RETRANSMIT_INTERVAL_MS retry could never fire on a frozen clock.
##     That would surface as a 20 s TIMEOUT there, not a silent pass.
##
## LOAD-BEARING GOTCHA: SceneTree.quit(code) only SCHEDULES termination; it
## does not return. `return` follows the one quit(...) in this file.
extends SceneTree

const WAIT_TIMEOUT_MS := 20000
## Real wall-clock hold, host polled alone, before the poll-order decisive
## frame. Loopback delivery is sub-millisecond; this is two orders above it.
const REPLY_SETTLE_MS := 250
## Real wall-clock drain after a phase whose assertion is "nothing ELSE
## arrived": long enough for a would-be stray frame to land on loopback.
const DRAIN_MS := 100

const HOST_PLAYER := {"userId": "host", "username": "Host", "role": "host", "controllerSlot": 0}
const GUEST_PLAYER := {"userId": "g1", "username": "Guest", "role": "guest", "controllerSlot": 1}

var failures := 0
var _virtual_now: int = 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  PASS: " + message)
	else:
		failures += 1
		printerr("  FAIL: " + message)


## One participant: signaling double, roster double, a real star, a real
## session on top of it, and tap arrays for every signal both layers emit.
class _Side extends RefCounted:
	var id: String
	var signaling: CouchScriptedSignaling
	var roster: CouchScriptedRoster
	var star: CouchStarTransport
	var session: CouchSession

	# Star-level taps (the CouchTransport contract signals).
	var star_ready: Array = []       # [String]
	var star_lost: Array = []        # [String]
	var star_gaps: Array = []        # [{"peer_id", "reason"}]
	var star_received: Array = []    # [{"envelope", "sender"}]

	# Session-level taps.
	var started: Array = []          # [{"epoch", "is_host", "local_slot", "peer_id", "peer_name"}]
	var stopped: Array = []          # [String] reasons
	var hellos: Array = []           # [String] sender ids (host side only)
	var intents: Array = []          # [{"body", "sender"}]
	var inputs: Array = []           # [{"body", "sender"}]
	var snapshots: Array = []        # [Dictionary]
	var gaps: Array = []             # [{"peer_id", "reason"}] -- the session's re-emission
	var seq_gaps: Array = []         # [{"kind", "sender", "missing"}]
	var rejects: Array = []          # [{"reason", "sender"}]


	func _init(p_id: String, players: Array) -> void:
		id = p_id
		signaling = CouchScriptedSignaling.new(id)
		roster = CouchScriptedRoster.new(id, players)
		star = CouchStarTransport.new(signaling, roster)
		session = CouchSession.new(roster, star)

		star.peer_ready.connect(func(pid: String) -> void: star_ready.append(pid))
		star.peer_lost.connect(func(pid: String) -> void: star_lost.append(pid))
		star.transport_gap.connect(
			func(pid: String, reason: String) -> void: star_gaps.append({"peer_id": pid, "reason": reason})
		)
		star.envelope_received.connect(
			func(env: Dictionary, sender: String) -> void: star_received.append({"envelope": env, "sender": sender})
		)

		session.session_started.connect(
			func(epoch: int, is_host: bool, local_slot: int, peer_id: String, peer_name: String) -> void:
				started.append({
					"epoch": epoch, "is_host": is_host, "local_slot": local_slot,
					"peer_id": peer_id, "peer_name": peer_name,
				})
		)
		session.session_stopped.connect(func(reason: String) -> void: stopped.append(reason))
		session.hello_received.connect(func(sender_id: String) -> void: hellos.append(sender_id))
		session.intent_received.connect(
			func(body: Dictionary, sender_id: String) -> void: intents.append({"body": body, "sender": sender_id})
		)
		session.input_received.connect(
			func(body: Dictionary, sender_id: String) -> void: inputs.append({"body": body, "sender": sender_id})
		)
		session.snapshot_received.connect(func(body: Dictionary) -> void: snapshots.append(body))
		session.transport_gap.connect(
			func(pid: String, reason: String) -> void: gaps.append({"peer_id": pid, "reason": reason})
		)
		session.sequence_gap.connect(
			func(kind: String, sender_id: String, missing: int) -> void:
				seq_gaps.append({"kind": kind, "sender": sender_id, "missing": missing})
		)
		session.rejected.connect(
			func(reason: String, sender_id: String) -> void: rejects.append({"reason": reason, "sender": sender_id})
		)


	## The ONLY place either poll is called. The order is load-bearing and is
	## what section 3 proves: the star dispatches this frame's arrivals FIRST,
	## so the session's timers never advance over a reply that has already
	## landed. Swap these two lines and section 3 goes red.
	func poll(now_ms: int) -> void:
		star.poll(now_ms)
		session.poll(now_ms)


	func lane(mode: int) -> int:
		return int(star.send_lane_tally.get(mode, 0))


## The only place `await process_frame` appears -- see the file header. Advances
## the file-wide virtual clock, then polls every side in `sides` with it.
func _step(sides: Array, dt_ms: int = 0) -> void:
	await process_frame
	_virtual_now += dt_ms
	for s in sides:
		(s as _Side).poll(_virtual_now)


func _wait_until(sides: Array, predicate: Callable, label: String, timeout_ms: int = WAIT_TIMEOUT_MS) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await _step(sides)
	printerr("  TIMEOUT waiting for %s" % label)
	return false


## Poll `sides` for `ms` of REAL time with the virtual clock frozen.
func _hold_real(sides: Array, ms: int) -> void:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		await _step(sides)


## Count entries in a star-level `star_received` tap whose envelope kind == `kind`.
func _count_kind(received: Array, kind: String) -> int:
	var n := 0
	for e in received:
		if (e["envelope"] as Dictionary).get(CouchEnvelope.KEY_KIND, "") == kind:
			n += 1
	return n


func _has_gap(gaps: Array, peer_id: String, reason: String) -> bool:
	for g in gaps:
		if g["peer_id"] == peer_id and g["reason"] == reason:
			return true
	return false


func _count_gap(gaps: Array, peer_id: String, reason: String) -> int:
	var n := 0
	for g in gaps:
		if g["peer_id"] == peer_id and g["reason"] == reason:
			n += 1
	return n


## Rejections the unordered `input` lane can legitimately produce: a frame
## overtaken on the wire arrives with seq <= last and the session's latest-wins
## tracker drops it as "duplicate". Loopback practically never reorders, but a
## gate that could go red on a reorder the lane explicitly permits would be
## asserting something the contract does not promise.
func _rejects_other_than_duplicate(rejects: Array) -> Array:
	var out: Array = []
	for r in rejects:
		if r["reason"] != "duplicate":
			out.append(r)
	return out


func _run() -> void:
	print("== Couch star session (G9) ==")
	var webrtc_available := CouchStarTransport.is_webrtc_available()
	_check(webrtc_available, "is_webrtc_available() is true (else everything below is vacuous)")
	if not webrtc_available:
		printerr(
			"  no concrete WebRTC implementation is installed -- continuing anyway "
			+ "per this codebase's FAIL-not-skip discipline; expect further FAILs and timeouts below"
		)

	var players := [HOST_PLAYER, GUEST_PLAYER]
	var host := _Side.new("host", players)
	var guest := _Side.new("g1", players)
	CouchScriptedSignaling.link(host.signaling, guest.signaling)

	# ======================================================================
	# 1. Boot: the star starts, then each session evaluates BEFORE the link is
	#    up -- the order a real game's initialize() produces.
	# ======================================================================
	print("-- 1: boot, sessions evaluate before the link exists --")
	var host_start: Dictionary = await host.star.start()
	var guest_start: Dictionary = await guest.star.start()
	_check(bool(host_start.get("success", false)), "host star.start() returns success")
	_check(bool(guest_start.get("success", false)), "guest star.start() returns success")

	host.session.evaluate(_virtual_now)
	guest.session.evaluate(_virtual_now)

	_check(
		host.started.size() == 1
			and host.started[0]["is_host"] == true
			and host.started[0]["local_slot"] == CouchSession.SLOT_HOST
			and host.started[0]["peer_id"] == "g1"
			and host.started[0]["peer_name"] == "Guest",
		"host session_started(epoch, true, SLOT_HOST, \"g1\", \"Guest\") fires at evaluate(): the host needs no reply to be authoritative"
	)
	_check(host.session.active and host.session.epoch != CouchEnvelope.UNKNOWN_EPOCH, "host session is active with a minted epoch")
	_check(
		not guest.session.active and guest.started.is_empty() and guest.session.epoch == CouchEnvelope.UNKNOWN_EPOCH,
		"guest session is engaged but NOT active before the link: the ready barrier holds"
	)
	_check(
		host.star.send_lane_tally.is_empty() and guest.star.send_lane_tally.is_empty(),
		"neither boot hello reached the wire: both stars' send_lane_tally are empty (the star refuses a send with no connected peer)"
	)

	# ======================================================================
	# 2. Establishment with the virtual clock FROZEN at 0.
	# ======================================================================
	print("-- 2: link establishment, clock frozen --")
	var both_ready := await _wait_until(
		[host, guest],
		func() -> bool: return host.star_ready == ["g1"] and guest.star_ready == ["host"],
		"both stars to report peer_ready for each other"
	)
	_check(both_ready, "both stars reach peer_ready ([\"g1\"] at the host, [\"host\"] at the guest)")
	_check(
		host.star_received.is_empty() and guest.star_received.is_empty(),
		"nothing crossed while the clock was frozen: a hello leaves on the session's timer, not on link-up"
	)
	_check(not guest.session.active, "guest session is still inactive with the link up and no hello exchanged")
	_check(host.star_gaps.is_empty() and guest.star_gaps.is_empty(), "no transport_gap during the clean establishment")

	# ======================================================================
	# 3. The hello round trip, and the POLL-ORDER proof -- see the header.
	# ======================================================================
	print("-- 3: hello round trip + poll order --")
	# 3a. One guest frame at T=HELLO_RETRY_MS: the retry timer fires and the
	#     hello leaves on the now-live link.
	await _step([guest], CouchSession.HELLO_RETRY_MS)
	_check(
		guest.lane(MultiplayerPeer.TRANSFER_MODE_RELIABLE) == 1,
		"at T=%d exactly one RELIABLE frame (the retried hello) left the guest" % _virtual_now
	)

	# 3b. Poll ONLY the host until the hello lands and is answered.
	var hello_landed := await _wait_until(
		[host], func() -> bool: return host.hellos == ["g1"], "the host session to receive the guest's hello"
	)
	_check(hello_landed, "host session hello_received fires for \"g1\": the hello crossed the star and cleared the sender guard")
	_check(_count_kind(host.star_received, CouchEnvelope.KIND_HELLO) == 1, "exactly one hello reached the host star")
	_check(
		host.lane(MultiplayerPeer.TRANSFER_MODE_RELIABLE) == 1,
		"the host's reply hello left on the RELIABLE lane (host send_lane_tally[RELIABLE] == 1)"
	)
	_check(
		host.seq_gaps == [{"kind": CouchEnvelope.KIND_HELLO, "sender": "g1", "missing": 1}] and host.session.gap_count == 1,
		"integration fact 1: the boot hello's seq was spent on a refused send, so the host reports exactly one phantom sequence_gap(\"hello\", \"g1\", 1)"
	)

	# 3c. Guest stays UNPOLLED for REPLY_SETTLE_MS of real time: the reply can
	#     only queue in its peer.
	await _hold_real([host], REPLY_SETTLE_MS)

	# 3d. The decisive frame: retry due again, reply already queued.
	var reliable_before := guest.lane(MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	await _step([guest], CouchSession.HELLO_RETRY_MS)
	_check(
		guest.session.active and guest.started.size() == 1,
		"PREMISE: the reply was queued in the guest's peer -- a single star.poll dispatched it and the session went active in that frame"
	)
	_check(
		guest.lane(MultiplayerPeer.TRANSFER_MODE_RELIABLE) == reliable_before,
		"POLL ORDER: no retry hello left the guest in the frame that made it active -- star.poll ran before session.poll, so the arrival was dispatched before the timer advanced over it"
	)

	# 3e. Drain both sides and confirm nothing else ever reached the host.
	await _hold_real([host, guest], DRAIN_MS)
	_check(
		_count_kind(host.star_received, CouchEnvelope.KIND_HELLO) == 1 and host.hellos == ["g1"],
		"after draining, still exactly ONE hello ever reached the host (a swapped poll order would have sent a second)"
	)
	_check(
		guest.started[0]["epoch"] == host.session.epoch
			and guest.started[0]["is_host"] == false
			and guest.started[0]["local_slot"] == CouchSession.SLOT_GUEST
			and guest.started[0]["peer_id"] == "host"
			and guest.started[0]["peer_name"] == "Host",
		"guest session_started(<host's epoch>, false, SLOT_GUEST, \"host\", \"Host\")"
	)
	_check(guest.session.epoch == host.session.epoch, "both sessions agree on the epoch")
	_check(guest.stopped.is_empty() and host.stopped.is_empty(), "no session_stopped anywhere during bootstrap")

	# ======================================================================
	# 4. Each kind crosses the session on its own lane.
	# ======================================================================
	print("-- 4: input / intent / snapshot through the session --")
	for i in range(20):
		guest.session.send_input({"i": i + 1})
	_check(
		guest.lane(MultiplayerPeer.TRANSFER_MODE_UNRELIABLE) == 20,
		"lane witness: 20 session.send_input() calls put 20 frames on the guest's UNRELIABLE lane"
	)
	var input_arrived := await _wait_until(
		[host, guest], func() -> bool: return host.inputs.size() >= 1, "the host session to receive an input"
	)
	_check(input_arrived, "host session input_received fires (>= 1 of 20 unreliable inputs)")
	await _hold_real([host, guest], DRAIN_MS)
	var inputs_monotone := not host.inputs.is_empty()
	var last_i := 0
	for e in host.inputs:
		var i := int((e["body"] as Dictionary).get("i", 0))
		if i <= last_i or e["sender"] != "g1":
			inputs_monotone = false
		last_i = i
	_check(
		inputs_monotone,
		"every delivered input is from \"g1\" and strictly increasing (%d delivered): the session's latest-wins tracker on an UNORDERED lane" % host.inputs.size()
	)

	guest.session.send_intent({"verb": "jump"})
	var intent_arrived := await _wait_until(
		[host, guest], func() -> bool: return host.intents.size() == 1, "the host session to receive the intent"
	)
	_check(
		intent_arrived and host.intents[0]["body"] == {"verb": "jump"} and host.intents[0]["sender"] == "g1",
		"host session intent_received({\"verb\": \"jump\"}, \"g1\") fires exactly once"
	)
	_check(
		guest.lane(MultiplayerPeer.TRANSFER_MODE_RELIABLE) == 2,
		"lane witness: guest RELIABLE tally == 2 (the hello, then the intent)"
	)

	for i in range(20):
		host.session.broadcast_snapshot({"tick": i + 1})
	_check(
		host.lane(MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED) == 20,
		"lane witness: 20 session.broadcast_snapshot() calls put 20 frames on the host's UNRELIABLE_ORDERED lane"
	)
	var snapshot_arrived := await _wait_until(
		[host, guest], func() -> bool: return guest.snapshots.size() >= 1, "the guest session to receive a snapshot"
	)
	_check(snapshot_arrived, "guest session snapshot_received fires (>= 1 of 20 unreliable_ordered snapshots)")
	await _hold_real([host, guest], DRAIN_MS)
	var ticks_monotone := not guest.snapshots.is_empty()
	var last_tick := 0
	for body in guest.snapshots:
		var tick := int((body as Dictionary).get("tick", 0))
		if tick <= last_tick:
			ticks_monotone = false
		last_tick = tick
	_check(
		ticks_monotone and last_tick <= 20,
		"delivered snapshot ticks are strictly increasing and <= 20 (%d delivered)" % guest.snapshots.size()
	)
	_check(
		guest.session.gap_count == 0 and guest.seq_gaps.is_empty(),
		"the guest reports no sequence_gap: input/snapshot are latest-wins and the host's hello was seq 1"
	)
	_check(
		host.session.gap_count == 1,
		"the host's gap_count is still the boot-time 1: a lost latest-wins input is not a gap"
	)
	_check(
		_rejects_other_than_duplicate(host.rejects).is_empty() and _rejects_other_than_duplicate(guest.rejects).is_empty(),
		"no session rejection on either side (an unordered-lane \"duplicate\" is the one the contract permits; host=%s guest=%s)"
			% [host.rejects, guest.rejects]
	)

	# ======================================================================
	# 5. A star-level transport_gap reaches the session's _on_transport_gap.
	#    The net-id collision is the one gap reachable from the public
	#    surface that disturbs nothing live -- see run_star_link.gd's
	#    assertion 21 for the mechanism.
	# ======================================================================
	print("-- 5: transport_gap reaches the session --")
	var colliding_a: String = CouchNetIdVectors.COLLIDING_PAIR[0]
	var colliding_b: String = CouchNetIdVectors.COLLIDING_PAIR[1]
	host.signaling.announce(colliding_a)
	var a_mapped := await _wait_until(
		[host, guest],
		func() -> bool: return host.star.net_id_for(colliding_a) == CouchNetIdVectors.COLLIDING_NET_ID,
		"the host star to map the first colliding peer id"
	)
	_check(a_mapped, "setup: the first colliding peer id is mapped by the host star")
	host.signaling.announce(colliding_b)
	var gap_reached := await _wait_until(
		[host, guest],
		func() -> bool: return _has_gap(host.gaps, colliding_b, "net-id-collision"),
		"the host SESSION to re-emit transport_gap(<colliding id>, \"net-id-collision\")"
	)
	_check(gap_reached, "host session transport_gap(\"%s\", \"net-id-collision\") fires: the star's gap reached _on_transport_gap" % colliding_b)
	_check(
		host.gaps == host.star_gaps and host.gaps.size() == 1,
		"the session's transport_gap taps mirror the star's one-for-one, and the collision is the only gap so far"
	)
	_check(host.session.active and guest.session.active, "a transport_gap for a stranger leaves both sessions active")

	# ======================================================================
	# 6. Host restart mid-session: the host process dies and comes back.
	# ======================================================================
	print("-- 6: host restart mid-session --")
	var old_epoch := host.session.epoch
	var old_label := guest.star.incarnation_for("host")
	var guest_ready_before := guest.star_ready.size()
	# The dead process: its star closes (which closes its signaling -- the
	# guest will hear peer_left), its session is never polled again and
	# never says goodbye.
	host.star.close()

	var host2 := _Side.new("host", players)
	CouchScriptedSignaling.link(host2.signaling, guest.signaling)
	var host2_start: Dictionary = await host2.star.start()
	_check(bool(host2_start.get("success", false)), "the restarted host's star.start() returns success")
	host2.session.evaluate(_virtual_now)
	_check(
		host2.started.size() == 1 and host2.started[0]["epoch"] != old_epoch and host2.session.epoch != old_epoch,
		"the restarted host mints a NEW epoch at evaluate() (old %d, new %d)" % [old_epoch, host2.session.epoch]
	)
	_check(
		host2.star.send_lane_tally.is_empty(),
		"its boot hello never reached the wire either: no link yet, tally empty"
	)

	var rejoin_seen := await _wait_until(
		[host2, guest],
		func() -> bool: return _has_gap(guest.star_gaps, "host", "peer-rejoined"),
		"the guest star to process the host's signaling rejoin"
	)
	_check(rejoin_seen, "guest star fires transport_gap(\"host\", \"peer-rejoined\"): the restart arrived as peer_left then peer_joined")
	_check(guest.star_lost == ["host"], "guest star fires peer_lost(\"host\") exactly once for the dead link")
	_check(
		_has_gap(guest.gaps, "host", "peer-rejoined"),
		"the rejoin's transport_gap reaches the guest SESSION's _on_transport_gap"
	)
	_check(
		guest.session.active and guest.stopped.is_empty() and guest.session.epoch == old_epoch,
		"the guest session is still active on the OLD epoch: a link fact alone never stops a session -- only the epoch does"
	)

	var reestablished := await _wait_until(
		[host2, guest],
		func() -> bool:
			return host2.star_ready == ["g1"] and guest.star_ready.size() == guest_ready_before + 1,
		"the rebuilt link to establish on both sides"
	)
	_check(reestablished, "peer_ready fires on the restarted host and a second time on the guest")
	_check(
		guest.star.incarnation_for("host") != 0
			and guest.star.incarnation_for("host") == host2.star.incarnation_for("g1")
			and guest.star.incarnation_for("host") != old_label,
		"the guest operates under the restarted host's incarnation label, distinct from the dead host's (see header fact 3)"
	)
	_check(
		_count_gap(guest.star_gaps, "host", "handshake-restart") == 0 and guest.star.handshake_restarts == 0,
		"the restarted host's offer was an INITIAL adoption on a torn-down peer: no handshake-restart, no follow budget spent"
	)
	_check(guest.session.active and guest.stopped.is_empty(), "still no session_stopped on the guest: nothing carrying the new epoch has arrived")

	# The restarted host's first broadcast is what carries the new epoch. A
	# real host sends snapshots at frame rate; the boot hello was lost.
	host2.session.broadcast_snapshot({"tick": 100})
	var guest_restarted := await _wait_until(
		[host2, guest],
		func() -> bool: return guest.stopped == ["host-restarted"],
		"the guest session to stop with \"host-restarted\""
	)
	_check(guest_restarted, "guest session_stopped(\"host-restarted\") fires on the first envelope carrying the new epoch")
	_check(
		not guest.snapshots.is_empty() and int(guest.snapshots[guest.snapshots.size() - 1].get("tick", 0)) == 100,
		"that snapshot is still delivered (snapshot_received tick 100) after the stop"
	)
	var guest_rejoined := await _wait_until(
		[host2, guest],
		func() -> bool: return guest.started.size() == 2,
		"the guest session to start again on the new epoch"
	)
	_check(
		guest_rejoined
			and guest.started[1]["epoch"] == host2.session.epoch
			and guest.started[1]["is_host"] == false
			and guest.started[1]["local_slot"] == CouchSession.SLOT_GUEST
			and guest.started[1]["peer_id"] == "host",
		"guest session_started(<new epoch>, false, SLOT_GUEST, \"host\") fires a second time: the guest re-helloed and the restarted host answered"
	)
	_check(host2.hellos == ["g1"], "the restarted host session's hello_received fires exactly once for \"g1\"")
	_check(
		host2.seq_gaps == [{"kind": CouchEnvelope.KIND_HELLO, "sender": "g1", "missing": 2}] and host2.session.gap_count == 1,
		"integration fact 1 again: the guest's hello counter was not reset across epochs (third hello, seq 3, fresh tracker), one phantom sequence_gap(\"hello\", \"g1\", 2)"
	)

	var inputs_before := host2.inputs.size()
	guest.session.send_input({"i": 21})
	var input_crossed := await _wait_until(
		[host2, guest], func() -> bool: return host2.inputs.size() > inputs_before, "an input to cross the rebuilt link"
	)
	_check(
		input_crossed
			and host2.inputs[host2.inputs.size() - 1]["body"] == {"i": 21}
			and host2.inputs[host2.inputs.size() - 1]["sender"] == "g1",
		"input_received({\"i\": 21}, \"g1\") fires on the restarted host: the guest's continued seq is accepted under the new epoch"
	)
	_check(
		_rejects_other_than_duplicate(host2.rejects).is_empty() and _rejects_other_than_duplicate(guest.rejects).is_empty(),
		"no rejection on either side across the restart (host2=%s guest=%s)" % [host2.rejects, guest.rejects]
	)

	# ======================================================================
	# 7. Guest close(): a link fact on the star, a roster fact for the session.
	# ======================================================================
	print("-- 7: guest close() and the session-level departure --")
	guest.star.close()
	var host_saw_lost := await _wait_until(
		[host2], func() -> bool: return host2.star_lost.has("g1"), "the host star to emit peer_lost(\"g1\")"
	)
	_check(host_saw_lost and host2.star_lost == ["g1"], "guest star.close(): the host star emits peer_lost(\"g1\") exactly once")
	_check(
		host2.session.active and host2.stopped.is_empty(),
		"DESIGN PIN (header fact 2): peer_lost alone leaves the host session active -- a departure is a roster fact, not a link fact"
	)
	# The platform's lobby drops the departed player and the game re-evaluates.
	# The roster double stands in for the lobby here.
	host2.roster.set_players([HOST_PLAYER])
	host2.session.evaluate(_virtual_now)
	_check(
		host2.stopped == ["authorized-peer-left"] and not host2.session.active,
		"after the roster drops \"g1\", evaluate() stops the host session with \"authorized-peer-left\""
	)
	_check(not host2.star.is_ready(), "the host star has no connected peer left (is_ready() == false)")
	var ordered_before := host2.lane(MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED)
	var accepted := host2.session.broadcast_snapshot({"tick": 101})
	_check(
		accepted == false and host2.lane(MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED) == ordered_before,
		"a broadcast_snapshot() on the stopped session is refused AND nothing reached the lane (tally unchanged at %d)" % ordered_before
	)

	print("")
	print("total assertions: %d failed" % failures)
	if failures == 0:
		print("COUCH_STAR_SESSION_OK")
	else:
		printerr("COUCH_STAR_SESSION_FAILED: %d check(s)" % failures)
	quit(failures)
	return
