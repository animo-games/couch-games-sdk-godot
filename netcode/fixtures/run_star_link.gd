## Headless two-peer WebRTC-star establishment gate -- gate G8.
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_star_link.gd
##
## Puts a REAL CouchStarTransport, with REAL WebRTCPeerConnections, on a real
## establishment path -- host create_server(), guest create_client(), a genuine
## offer/answer/ICE exchange over CouchScriptedSignaling (netcode/fixtures/
## scripted_signaling.gd) -- in ONE process. Testing the star against a fake
## transport would prove nothing about the star: this file is where most of the
## Phase 1 mutation list must actually turn red, so every assertion below is on
## an OBSERVED EFFECT (a signal fired, a count incremented, an envelope that
## arrived) and never SOLELY on a send's return value, which the contract
## documents as "accepted for send", not a delivery receipt. Two sites below DO
## assert a send's return value (host_star.send_to_peer's hello, and
## guest_star.broadcast's intent) -- a `false` there really would be a defect --
## but both are immediately paired with an observed-arrival assertion on the
## same envelope, so the return-value check is never the sole evidence.
##
## REQUIRES a concrete WebRTC implementation (CouchStarTransport.is_webrtc_available()
## == true). A missing implementation is a FAIL here, not a skip -- same
## discipline as run_transport_faults.gd's OS.is_debug_build() check: silently
## skipping would turn "WebRTC isn't installed" into a green tick nobody earned.
## The run is deliberately NOT short-circuited when the check fails: everything
## below still executes and reports honestly (mostly as further FAILs or
## eventual 20s timeouts) rather than hiding behind an early return.
##
## Transport-only, DELIBERATELY: there is no CouchSession anywhere in this file.
## Every envelope is built directly with CouchEnvelope.make(), so every assertion
## below maps to a transport behaviour with no session policy layered in between.
## The full stack (CouchSession on top of a real star) is G9's job, not this
## file's.
##
## One honest limitation, stated rather than hidden: assertion 21's "no third
## WebRTCPeerConnection was built" is checked through the PUBLIC surface only
## (net_id_for() staying 0, the peer never reaching peer_ready). This harness has
## no access to CouchStarTransport's private _pcs map -- reaching into a "_"
## field from outside would be exactly the kind of encapsulation break this
## codebase does not do anywhere else (see run_transport_faults.gd's use of only
## public `fault_drops`) -- so "no connection was built" is proven by its only
## externally visible consequence: the refused peer id never gets mapped to a
## net id and never becomes ready. If a future mutation built a doomed
## connection that still left those two facts true, this proxy would not catch
## it; net_id_collisions == 1 and the "net-id-collision" transport_gap remain the
## primary, exact assertions for that mutation.
##
## LOAD-BEARING GOTCHA: SceneTree.quit(code) only SCHEDULES termination; it does
## not return, and a LATER quit() call overwrites the exit code. `return`
## follows every quit(...) in this file without exception.
##
## `_step()` is the ONLY place `await process_frame` appears in this file. Every
## wait loops through it, so every wait also polls both transports, and neither
## transport's timers or SDP retransmit logic can ever advance against a frame
## this file forgot to poll.
extends SceneTree

const WAIT_TIMEOUT_MS := 20000

var failures := 0

var _host_signaling: CouchScriptedSignaling
var _guest_signaling: CouchScriptedSignaling
var _host_star: CouchStarTransport
var _guest_star: CouchStarTransport

var _host_ready: Array = []          # [String] peer ids, in arrival order
var _host_lost: Array = []           # [String] peer ids
var _host_gaps: Array = []           # [{"peer_id": String, "reason": String}]
var _host_received: Array = []       # [{"envelope": Dictionary, "sender": String}]
var _guest_ready: Array = []
var _guest_lost: Array = []
var _guest_gaps: Array = []
var _guest_received: Array = []

# SceneMultiplayer-never-touched witness (assertion 23). `_initial_peer` is
# captured by OBJECT IDENTITY before start() runs; `_mp_touched` is sampled
# every polled frame from inside _step(), so a transient assign-and-restore
# that a start/end comparison would miss still flips it.
var _initial_peer: Object = null
var _mp_touched: bool = false


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  PASS: " + message)
	else:
		failures += 1
		printerr("  FAIL: " + message)


## The only place `await process_frame` appears -- see the file header. Polls
## BOTH transports every frame this file ever waits through.
func _step() -> void:
	await process_frame
	var now := Time.get_ticks_msec()
	_host_star.poll(now)
	_guest_star.poll(now)
	if root.multiplayer.multiplayer_peer != _initial_peer:
		_mp_touched = true


func _wait_until(predicate: Callable, label: String, timeout_ms: int = WAIT_TIMEOUT_MS) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await _step()
	printerr("  TIMEOUT waiting for %s" % label)
	return false


## Minimal duck-typed roster double satisfying CouchStarTransport's
## REQUIRED_LOBBY_METHODS (is_host/get_host/get_me). Modelled on
## run_transport_faults.gd's _FaultRoster, trimmed to only what the star reads:
## it never calls get_players()/get_guests().
class _StarRoster extends RefCounted:
	var _me: Dictionary
	var _host: Dictionary
	var _am_host: bool


	func _init(me: Dictionary, host: Dictionary, am_host: bool) -> void:
		_me = me
		_host = host
		_am_host = am_host


	func get_me() -> Variant:
		return _me


	func get_host() -> Variant:
		return _host


	func is_host() -> bool:
		return _am_host


func _run() -> void:
	print("== Couch star transport link (G8) ==")
	var webrtc_available := CouchStarTransport.is_webrtc_available()
	_check(webrtc_available, "is_webrtc_available() is true (else everything below is vacuous)")
	if not webrtc_available:
		printerr(
			"  no concrete WebRTC implementation is installed -- continuing anyway "
			+ "per this file's FAIL-not-skip discipline; expect further FAILs and timeouts below"
		)

	# --- Setup -------------------------------------------------------------
	_host_signaling = CouchScriptedSignaling.new("host")
	_guest_signaling = CouchScriptedSignaling.new("g1")
	CouchScriptedSignaling.link(_host_signaling, _guest_signaling)

	var host_player := {"user_id": "host"}
	var guest_player := {"user_id": "g1"}
	var host_roster := _StarRoster.new(host_player, host_player, true)
	var guest_roster := _StarRoster.new(guest_player, host_player, false)

	_host_star = CouchStarTransport.new(_host_signaling, host_roster)
	_guest_star = CouchStarTransport.new(_guest_signaling, guest_roster)

	_host_star.peer_ready.connect(func(pid: String) -> void: _host_ready.append(pid))
	_host_star.peer_lost.connect(func(pid: String) -> void: _host_lost.append(pid))
	_host_star.transport_gap.connect(
		func(pid: String, reason: String) -> void: _host_gaps.append({"peer_id": pid, "reason": reason})
	)
	_host_star.envelope_received.connect(
		func(env: Dictionary, sender: String) -> void: _host_received.append({"envelope": env, "sender": sender})
	)
	_guest_star.peer_ready.connect(func(pid: String) -> void: _guest_ready.append(pid))
	_guest_star.peer_lost.connect(func(pid: String) -> void: _guest_lost.append(pid))
	_guest_star.transport_gap.connect(
		func(pid: String, reason: String) -> void: _guest_gaps.append({"peer_id": pid, "reason": reason})
	)
	_guest_star.envelope_received.connect(
		func(env: Dictionary, sender: String) -> void: _guest_received.append({"envelope": env, "sender": sender})
	)

	_initial_peer = root.multiplayer.multiplayer_peer
	var initial_peer_class := _initial_peer.get_class() if _initial_peer != null else "null"

	# --- assertion 2: start() succeeds on both sides ----------------------------
	var host_start: Dictionary = await _host_star.start()
	var guest_start: Dictionary = await _guest_star.start()
	_check(bool(host_start.get("success", false)), "host_star.start() returns success == true")
	_check(bool(guest_start.get("success", false)), "guest_star.start() returns success == true")

	# --- assertion 3/4: net ids -------------------------------------------------
	_check(_host_star.local_net_id == CouchStarTransport.HOST_NET_ID, "host_star.local_net_id == 1")
	var expected_guest_net_id := CouchStarTransport.derive_net_id("g1")
	_check(
		_guest_star.local_net_id == expected_guest_net_id
			and _guest_star.local_net_id != CouchStarTransport.HOST_NET_ID
			and _guest_star.local_net_id >= CouchStarTransport.NET_ID_MIN
			and _guest_star.local_net_id <= CouchStarTransport.NET_ID_MAX,
		"guest_star.local_net_id == derive_net_id(\"g1\"), != 1, and within [NET_ID_MIN, NET_ID_MAX]"
	)

	# --- assertions 5-7: refused/not-ready BEFORE any _step() -------------------
	var hello_env: Dictionary = CouchEnvelope.make(CouchEnvelope.KIND_HELLO, 1, 1, {})
	_check(
		_host_star.broadcast(hello_env) == false,
		"synchronously after start(), before any _step(): host_star.broadcast() == false"
	)
	_check(
		_host_star.send_to_authority(hello_env) == false,
		"synchronously after start(): host_star.send_to_authority() == false (authority no-op)"
	)
	_check(
		_guest_star.send_to_authority(hello_env) == false,
		"synchronously after start(): guest_star.send_to_authority() == false (no established link yet)"
	)
	_check(_guest_star.is_ready() == false, "synchronously after start(): guest_star.is_ready() == false")

	# --- assertion 8: establishment ----------------------------------------------
	var both_ready := await _wait_until(
		func() -> bool: return _host_ready == ["g1"] and _guest_ready == ["host"],
		"both sides to report peer_ready for each other"
	)
	_check(
		both_ready,
		"both peer_ready lists become exactly [\"g1\"] / [\"host\"] within %ds of stepping"
			% (WAIT_TIMEOUT_MS / 1000)
	)

	# --- assertion 9: peer_ready carries a platform user id, not a net id -------
	_check(
		not _host_ready.is_empty() and _host_ready[0] == "g1" and _host_ready[0] != str(expected_guest_net_id),
		"peer_ready carried a platform user id (\"g1\"), not a net id (\"%d\")" % expected_guest_net_id
	)

	# --- assertion 10: is_ready() true on both sides -----------------------------
	_check(_host_star.is_ready() and _guest_star.is_ready(), "is_ready() is true on both sides after peer_ready")

	# --- assertion 11: net id lookups ---------------------------------------------
	_check(_host_star.net_id_for("g1") == expected_guest_net_id, "host_star.net_id_for(\"g1\") == derive_net_id(\"g1\")")
	_check(_guest_star.net_id_for("host") == CouchStarTransport.HOST_NET_ID, "guest_star.net_id_for(\"host\") == 1")

	# --- assertion 22: no transport_gap during clean establishment --------------
	# Checked here, BEFORE the collision test (assertion 21) deliberately adds
	# one to these same arrays.
	_check(
		_host_gaps.is_empty() and _guest_gaps.is_empty(),
		"no transport_gap fired during the clean establishment (checked before the collision test)"
	)

	# --- assertion 12: a hello (reliable) host -> guest arrives -------------------
	var pre_hello_count := _guest_received.size()
	_check(_host_star.send_to_peer("g1", hello_env), "host_star.send_to_peer(\"g1\", hello) is accepted for send")
	var hello_arrived := await _wait_until(
		func() -> bool: return _guest_received.size() > pre_hello_count,
		"guest to receive the hello"
	)
	_check(hello_arrived, "a hello (reliable) host->guest arrives")
	if hello_arrived:
		var entry: Dictionary = _guest_received[_guest_received.size() - 1]
		_check(str(entry["sender"]) == "host", "the guest's envelope_received sender_peer_id == \"host\"")
	else:
		_check(false, "the guest's envelope_received sender_peer_id == \"host\"")

	# --- assertion 13: an input (unreliable) guest -> host arrives, >= 1 of 20 --
	var pre_input_count := _host_received.size()
	for i in range(20):
		_guest_star.send_to_authority(CouchEnvelope.make(CouchEnvelope.KIND_INPUT, 1, i + 1, {"i": i}))
	var input_arrived := await _wait_until(
		func() -> bool: return _count_received(_host_received, pre_input_count, CouchEnvelope.KIND_INPUT) >= 1,
		"host to receive at least one of 20 unreliable inputs"
	)
	_check(input_arrived, "an input (unreliable) guest->host arrives (>= 1 of 20 sent)")

	# --- lane witness: the 20-input burst really went out UNRELIABLE -------------
	# Read back from the PEER via _mp.get_transfer_mode() after set_transfer_mode()
	# (see star_transport.gd's send_lane_tally), NOT by calling lane_for_kind()
	# again -- a mutation that forces one lane inside _send() changes this tally,
	# which a second call to lane_for_kind() would not. This is what makes assertion
	# 15 below (which only counts KINDS) insufficient on its own: a _send() that
	# always selects RELIABLE leaves assertion 15 green.
	_check(
		int(_guest_star.send_lane_tally.get(MultiplayerPeer.TRANSFER_MODE_UNRELIABLE, 0)) == 20,
		"lane witness: guest_star.send_lane_tally[UNRELIABLE] == 20 after the 20-input burst"
	)

	# --- assertion 14: a snapshot (unreliable_ordered) host -> guest, >= 1 of 20 -
	var snapshot_body := {"v2": Vector2(1.5, -2.25), "arr": [1, null, "x"], "nested": {"k": "v"}}
	var pre_snapshot_count := _guest_received.size()
	for i in range(20):
		_host_star.broadcast(CouchEnvelope.make(CouchEnvelope.KIND_SNAPSHOT, 1, i + 1, snapshot_body))
	var snapshot_arrived := await _wait_until(
		func() -> bool: return _count_received(_guest_received, pre_snapshot_count, CouchEnvelope.KIND_SNAPSHOT) >= 1,
		"guest to receive at least one of 20 unreliable_ordered snapshots"
	)
	_check(snapshot_arrived, "a snapshot (unreliable_ordered) host->guest arrives (>= 1 of 20 sent)")

	# --- lane witness: the 20-snapshot burst really went out UNRELIABLE_ORDERED --
	_check(
		int(_host_star.send_lane_tally.get(MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED, 0)) == 20,
		"lane witness: host_star.send_lane_tally[UNRELIABLE_ORDERED] == 20 after the 20-snapshot burst"
	)

	# --- assertion 15: all three lanes carried at least one frame ----------------
	var guest_hello_tally := _count_received(_guest_received, 0, CouchEnvelope.KIND_HELLO)
	var host_input_tally := _count_received(_host_received, 0, CouchEnvelope.KIND_INPUT)
	var guest_snapshot_tally := _count_received(_guest_received, 0, CouchEnvelope.KIND_SNAPSHOT)
	_check(
		guest_hello_tally >= 1 and host_input_tally >= 1 and guest_snapshot_tally >= 1,
		"all three lanes (reliable, unreliable, unreliable_ordered) carried at least one frame"
	)

	# --- assertion 16: snapshot body with Godot types arrives identical ----------
	var last_snapshot_body: Variant = null
	for e in _guest_received:
		var env: Dictionary = e["envelope"]
		if env[CouchEnvelope.KEY_KIND] == CouchEnvelope.KIND_SNAPSHOT:
			last_snapshot_body = env[CouchEnvelope.KEY_BODY]
	_check(
		last_snapshot_body != null and last_snapshot_body == snapshot_body,
		"a snapshot body with Vector2/null-in-array/nested Dictionary arrives == identical"
	)

	# --- assertion 17: an extra "from" key is stripped; real sender is stamped ---
	var impostor_env: Dictionary = CouchEnvelope.make(CouchEnvelope.KIND_INTENT, 1, 1, {"probe": "impostor-test"})
	impostor_env["from"] = "impostor"
	var pre_impostor_count := _guest_received.size()
	_host_star.send_to_peer("g1", impostor_env)
	var impostor_arrived := await _wait_until(
		func() -> bool: return _guest_received.size() > pre_impostor_count,
		"guest to receive the impostor-tagged envelope"
	)
	if impostor_arrived:
		var entry: Dictionary = _guest_received[_guest_received.size() - 1]
		var delivered_env: Dictionary = entry["envelope"]
		_check(
			str(entry["sender"]) == "host" and not delivered_env.has("from"),
			"an envelope carrying an extra \"from\": \"impostor\" key arrives with the real sender stamped and no \"from\" key"
		)
	else:
		_check(false, "an envelope carrying an extra \"from\": \"impostor\" key arrives with the real sender stamped and no \"from\" key")

	# --- assertion 18: guest_star.broadcast() is received by the host (decision #2)
	var pre_guest_broadcast_count := _host_received.size()
	_check(
		_guest_star.broadcast(CouchEnvelope.make(CouchEnvelope.KIND_INTENT, 1, 2, {"probe": "guest-broadcast"})),
		"guest_star.broadcast() is accepted for send"
	)
	var guest_broadcast_arrived := await _wait_until(
		func() -> bool: return _host_received.size() > pre_guest_broadcast_count,
		"host to receive the guest's broadcast"
	)
	_check(
		guest_broadcast_arrived,
		"guest_star.broadcast(env) is received by the host (decision #2: a guest's broadcast reaches only the authority)"
	)

	# --- lane witness: reliable carried the hello + the impostor intent, the -----
	# guest never touched the snapshot lane, and each side exercised >= 2 lanes.
	_check(
		int(_host_star.send_lane_tally.get(MultiplayerPeer.TRANSFER_MODE_RELIABLE, 0)) >= 2,
		"lane witness: host_star.send_lane_tally[RELIABLE] >= 2 (the hello + the impostor intent)"
	)
	_check(
		not _guest_star.send_lane_tally.has(MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED),
		"lane witness: guest_star.send_lane_tally has no UNRELIABLE_ORDERED entry -- a guest never sends a snapshot"
	)
	_check(
		_host_star.send_lane_tally.size() >= 2 and _guest_star.send_lane_tally.size() >= 2,
		"lane witness: at least two distinct lanes were exercised on EACH side"
	)

	# --- assertion 19: an oversized broadcast is refused on the SENDER -----------
	var oversized_body := {"blob": "x".repeat(200000)}
	var oversized_env: Dictionary = CouchEnvelope.make(CouchEnvelope.KIND_INTENT, 1, 3, oversized_body)
	_check(
		_host_star.broadcast(oversized_env) == false,
		"host_star.broadcast(<envelope with a 200 000-byte body>) == false"
	)
	_check(_host_star.oversized_sends == 1, "host_star.oversized_sends == 1")

	# --- assertion 20: an unknown-kind envelope is rejected on receive -----------
	var bogus_env: Dictionary = CouchEnvelope.make("bogus", 1, 4, {})
	var pre_bogus_rejected := _host_star.rejected_count
	var pre_bogus_received := _host_received.size()
	_guest_star.broadcast(bogus_env)
	var bogus_rejected := await _wait_until(
		func() -> bool: return _host_star.rejected_count > pre_bogus_rejected,
		"host to reject the bogus-kind envelope"
	)
	_check(
		bogus_rejected and _host_star.rejected_count == pre_bogus_rejected + 1,
		"guest_star.broadcast(make(\"bogus\", ...)) makes host_star.rejected_count go up by exactly 1"
	)
	var bogus_seen := false
	for e in _host_received.slice(pre_bogus_received):
		if (e["envelope"] as Dictionary).get(CouchEnvelope.KEY_KIND, "") == "bogus":
			bogus_seen = true
	_check(not bogus_seen, "no envelope of kind \"bogus\" was ever emitted as envelope_received")

	# --- assertion 21: net-id collision is loud -----------------------------------
	var colliding_a: String = CouchNetIdVectors.COLLIDING_PAIR[0]
	var colliding_b: String = CouchNetIdVectors.COLLIDING_PAIR[1]
	_host_signaling.announce(colliding_a)
	var colliding_a_mapped := await _wait_until(
		func() -> bool: return _host_star.net_id_for(colliding_a) == CouchNetIdVectors.COLLIDING_NET_ID,
		"host to discover and map the first colliding peer id"
	)
	_check(
		colliding_a_mapped,
		"the first colliding peer id (%s) is discovered and mapped to COLLIDING_NET_ID" % colliding_a
	)

	var pre_collision_count := _host_star.net_id_collisions
	_host_signaling.announce(colliding_b)
	var collision_detected := await _wait_until(
		func() -> bool: return _host_star.net_id_collisions > pre_collision_count,
		"host to detect the net-id collision on the second colliding peer id"
	)
	_check(
		collision_detected and _host_star.net_id_collisions == pre_collision_count + 1,
		"announcing the second colliding peer id after the first is mapped makes net_id_collisions go up by exactly 1"
	)
	var collision_gap_fired := false
	for g in _host_gaps:
		if g["peer_id"] == colliding_b and g["reason"] == "net-id-collision":
			collision_gap_fired = true
	_check(collision_gap_fired, "transport_gap(pid, \"net-id-collision\") fired for the refused peer id")
	# "No third WebRTCPeerConnection was built" proxy -- see the file header for
	# why this is checked through the public surface rather than a private field.
	_check(
		_host_star.net_id_for(colliding_b) == 0,
		"the refused colliding peer id was never mapped to a net id"
	)
	_check(
		not _host_ready.has(colliding_b),
		"the refused colliding peer id never reaches peer_ready either"
	)

	# --- assertion 23: SceneMultiplayer is never touched --------------------------
	# The class comparison alone is WEAK: a transient assign of a same-class
	# object, or an assign-and-restore back to the original object, would still
	# pass it. The load-bearing check is `_mp_touched`, sampled by object IDENTITY
	# on every polled frame from inside _step() (see its declaration) -- that is
	# what actually catches a transient touch a start/end comparison cannot.
	var final_peer: Object = root.multiplayer.multiplayer_peer
	var final_peer_class := final_peer.get_class() if final_peer != null else "null"
	_check(
		final_peer_class == initial_peer_class and final_peer_class != "WebRTCMultiplayerPeer",
		"root.multiplayer.multiplayer_peer's CLASS is unchanged (%s) across the whole run"
			% initial_peer_class
	)
	_check(
		not _mp_touched,
		"root.multiplayer.multiplayer_peer's IDENTITY never changed on any polled frame -- the star never touches SceneMultiplayer, even transiently"
	)

	# --- assertion 24: guest close() is idempotent; host observes peer_lost ------
	_guest_star.close()
	_check(_guest_star.is_ready() == false, "guest_star.is_ready() == false after close()")
	_check(_guest_star.broadcast(hello_env) == false, "guest_star.broadcast() == false after close()")
	var host_saw_lost := await _wait_until(
		func() -> bool: return _host_lost.has("g1"),
		"host to emit peer_lost(\"g1\") after the guest closes"
	)
	_check(
		host_saw_lost,
		"guest_star.close() called once: within %ds the HOST emits peer_lost(\"g1\")"
			% (WAIT_TIMEOUT_MS / 1000)
	)

	# Idempotence PROOF, not merely a repeat of the same observation. Snapshot
	# every host tap array BEFORE the second close(): a second close() that
	# (wrongly) re-runs teardown and fires anything at all -- even a duplicate of
	# something already observed -- is directly visible as an array change here,
	# rather than inferred from an unchanged boolean that a single re-fired
	# peer_lost could still satisfy.
	var pre_second_close_ready := _host_ready.duplicate()
	var pre_second_close_lost := _host_lost.duplicate()
	var pre_second_close_gaps := _host_gaps.duplicate()
	var pre_second_close_received := _host_received.duplicate()
	_guest_star.close()
	for i in range(5):
		await _step()
	_check(
		_host_ready == pre_second_close_ready
			and _host_lost == pre_second_close_lost
			and _host_gaps == pre_second_close_gaps
			and _host_received == pre_second_close_received,
		"guest_star.close() called a SECOND time produces no new host-side signal at all (5 polled frames)"
	)
	for i in range(10):
		await _step()
	_check(
		_host_lost.count("g1") == 1,
		"host_lost contains exactly ONE \"g1\" entry even after a second close() and 10 further polled frames"
	)
	_check(
		_guest_signaling.close_count == 1,
		"the underlying signaling's close() was invoked exactly ONCE across two guest_star.close() calls (M34's exact detector)"
	)

	print("")
	print("total assertions: %d failed" % failures)
	if failures == 0:
		print("COUCH_STAR_LINK_OK")
	else:
		printerr("COUCH_STAR_LINK_FAILED: %d check(s)" % failures)
	quit(failures)
	return


## Count entries in `received` (a [{"envelope", "sender"}] tap array), starting
## at index `from_index`, whose envelope kind == `kind`.
func _count_received(received: Array, from_index: int, kind: String) -> int:
	var count := 0
	for e in received.slice(from_index):
		if (e["envelope"] as Dictionary).get(CouchEnvelope.KEY_KIND, "") == kind:
			count += 1
	return count
