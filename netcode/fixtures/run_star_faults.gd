## Headless fault-injection acceptance gate for CouchStarTransport -- gate G11.
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_star_faults.gd
##
## What is REAL under test: CouchStarTransport, real WebRTCPeerConnections, and
## CouchScriptedSignaling extended with its TEST-ONLY fault-injection surface
## (netcode/fixtures/scripted_signaling.gd -- hold_kind/release_held, drop_all,
## duplicate_sends, captured, replay, announce_left, close_count,
## connect_room_count). run_star_link.gd (G8) proves the star establishes and
## carries traffic cleanly; run_star_unit.gd (G7) proves classify_generation and
## the codec in isolation. Neither gate forces ICE-before-SDP, a duplicate
## peer_joined, a connect timeout/rebuild, a stale-generation delivery, or a
## close-during-start -- which is exactly why this gate exists: it is where
## Codex's critical finding (a delayed OLDER-generation packet rebuilding the
## guest backward and wedging it permanently) becomes a test that can fail. Every
## assertion below is on an OBSERVED EFFECT -- a signal fired, a counter moved, a
## frame that did or did not arrive -- never on a send's return value, which the
## contract documents as "accepted for send", not a delivery receipt.
##
## Transport-only, like run_star_link.gd: no CouchSession anywhere here.
##
## VIRTUAL CLOCK. `_step(stars, dt_ms)` does `await process_frame`, THEN advances
## one file-wide `_virtual_now` by `dt_ms`, THEN polls every star passed in with
## that value. CouchStarTransport reads no clock of its own -- every deadline is
## arithmetic on the `now_ms` a caller supplies -- so this file controls time
## completely: `dt_ms == 0` (the default, used by every ordinary wait) lets real
## engine work (SDP/ICE generation, DTLS handshake) proceed at real speed without
## moving any deadline forward, and an explicit large `dt_ms` jumps a deadline
## into the past in exactly one poll() call, deterministically, with no sleep.
## `_step()` is the ONLY place `await process_frame` appears in this file, so no
## wait anywhere can skip a poll.
##
## `_virtual_now` is ONE counter shared across the whole file and only ever
## grows. That is safe: a deadline is always computed as `now_ms + DURATION` at
## the moment it is armed, and once satisfied (established) or spent (terminal
## failure) it is erased by the transport itself, so a later, unrelated fault's
## big jump cannot resurrect it -- PROVIDED this file stops polling a pair once
## its fault case is done with it, which every fault function below does (each
## only ever passes the stars it currently cares about to `_step`/`_wait_until`).
##
## LOAD-BEARING GOTCHA: SceneTree.quit(code) only SCHEDULES termination; it does
## not return, and a LATER quit() call overwrites the exit code. `return` follows
## the one quit(...) call in this file without exception.
##
## Fresh pairs, not one shared session. Unlike run_star_link.gd's single
## continuous run, most fault cases here need a state (a specific generation, an
## unresolved roster, a connection that must never establish) that would
## contaminate every case after it on a shared pair. Each fault function below
## either takes a dedicated, freshly constructed _Pair or is explicitly
## documented as reusing one that stays generation-stable (the MAIN pair, used
## for F1/F2 and again for the orthogonal F14/F15/F16 reject/mute counters).
##
## HONESTY RISKS, stated plainly rather than papered over:
##   - F3 (duplicate SDP/ICE): loopback establishment can be fast enough that a
##     duplicated description arrives after the connection is already up, in
##     which case this fault may not reliably turn red under a retransmit-guard
##     removal. Implemented anyway for the coverage it does provide; do not read
##     a pass here as proof of that guard.
##   - F6/F6b/F8 all replay a blob pulled from some signaling's `captured`
##     array verbatim. CONFIRMED by actually running this gate: captured DOES
##     record a blob at send()'s JSON-round-trip step regardless of whether
##     drop_all/hold_kind ultimately deliver it -- the only reading of "captured:
##     every blob sent" (netcode/fixtures/scripted_signaling.gd) that made F6's
##     own setup possible, and it holds against the real implementation.
##   - F7's setup cell says only "announce_left(host) then announce(host) AT THE
##     GUEST". Taken completely literally that leaves the HOST's own connection
##     untouched -- nothing would ever produce the fresh generation-0 offer the
##     assertion "peer_ready fires a second time once the host rebuilds"
##     requires, since a died-but-undetected link is not spontaneously rebuilt by
##     anything on the host's side. This file therefore ALSO mirrors the same
##     announce_left/announce pair on the host's OWN signaling, in the same
##     frame, which is what a real host-restart cascade (see the plan's own
##     "genuine host restart" narrative) would produce on both ends. Flagged here
##     as an explicit extension beyond the setup cell's literal text, not a
##     silent deviation. CONFIRMED working by actually running this gate.
##   - F7 and F8 are SEPARATE dedicated pairs, not one combined flow as
##     originally written. Measured empirically: on this engine, the host's
##     fresh post-rejoin offer AND its ICE candidates can both reach the guest
##     and clear the rejoin barrier within the SAME _step() that processes the
##     deferred rejoin signals -- there is no naturally-occurring multi-frame
##     window after "the guest processed the rejoin" to inject a stale replay
##     into, and `hold_kind` cannot close it either (it is a single string and
##     cannot hold both "sdp" and "ice" at once, so a held offer still leaves
##     ICE free to clear the barrier first). F7 now runs on a clean pair with no
##     interference, proving the recovery path end to end; F8 runs on its own
##     dedicated pair with the host's signaling fully `drop_all`-blocked through
##     the whole rejoin, which reliably keeps the barrier armed long enough to
##     inject the stale replay -- at the cost of F8's pair never establishing
##     again afterward, which is fine, since F7's pair is what proves that part.
##
## NOT COVERED, stated rather than hidden (mirrors run_star_link.gd's own
## assertion-21 note and the plan's own §3.5 closing line): `pc-init-failed`,
## `add-peer-failed`, and the `_discover_peer` map rollback are not provokable
## through any public surface either double offers. Fixed by inspection only.
extends SceneTree

const WAIT_TIMEOUT_MS := 20000

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


## Minimal duck-typed roster double, trimmed to exactly what the star reads
## (is_host/get_host/get_me) -- modelled on run_star_link.gd's own `_StarRoster`,
## deliberately duplicated here rather than shared: see run_transport_faults.gd's
## header for the precedent on this exact kind of duplication.
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


## Roster double for F17/F18 (Codex finding 2, "empty host roster at start()").
## get_host() returns null until set_host() is called -- or never, for F18 --
## simulating a guest whose star started before the roster's async refresh
## named a host. Always a guest (is_host() == false).
class _LateHostRoster extends RefCounted:
	var _me: Dictionary
	var _host: Variant = null


	func _init(me: Dictionary) -> void:
		_me = me


	func get_me() -> Variant:
		return _me


	func get_host() -> Variant:
		return _host


	func is_host() -> bool:
		return false


	func set_host(host: Dictionary) -> void:
		_host = host


## One host+guest CouchStarTransport pair over a linked CouchScriptedSignaling,
## with tap arrays recording every contract signal it fires. Most fault cases
## below build a fresh _Pair so their generation/connection state cannot
## contaminate any other case; a few explicitly share one (see the file header).
class _Pair extends RefCounted:
	var host_id: String
	var guest_id: String
	var host_signaling: CouchScriptedSignaling
	var guest_signaling: CouchScriptedSignaling
	var host_star: CouchStarTransport
	var guest_star: CouchStarTransport

	var host_ready: Array = []
	var host_lost: Array = []
	var host_gaps: Array = []
	var host_received: Array = []
	var guest_ready: Array = []
	var guest_lost: Array = []
	var guest_gaps: Array = []
	var guest_received: Array = []


	func _init(p_host_id: String, p_guest_id: String) -> void:
		host_id = p_host_id
		guest_id = p_guest_id
		host_signaling = CouchScriptedSignaling.new(host_id)
		guest_signaling = CouchScriptedSignaling.new(guest_id)
		CouchScriptedSignaling.link(host_signaling, guest_signaling)

		var host_player := {"user_id": host_id}
		var guest_player := {"user_id": guest_id}
		var host_roster := _StarRoster.new(host_player, host_player, true)
		var guest_roster := _StarRoster.new(guest_player, host_player, false)

		host_star = CouchStarTransport.new(host_signaling, host_roster)
		guest_star = CouchStarTransport.new(guest_signaling, guest_roster)

		host_star.peer_ready.connect(func(pid: String) -> void: host_ready.append(pid))
		host_star.peer_lost.connect(func(pid: String) -> void: host_lost.append(pid))
		host_star.transport_gap.connect(
			func(pid: String, reason: String) -> void: host_gaps.append({"peer_id": pid, "reason": reason})
		)
		host_star.envelope_received.connect(
			func(env: Dictionary, sender: String) -> void: host_received.append({"envelope": env, "sender": sender})
		)
		guest_star.peer_ready.connect(func(pid: String) -> void: guest_ready.append(pid))
		guest_star.peer_lost.connect(func(pid: String) -> void: guest_lost.append(pid))
		guest_star.transport_gap.connect(
			func(pid: String, reason: String) -> void: guest_gaps.append({"peer_id": pid, "reason": reason})
		)
		guest_star.envelope_received.connect(
			func(env: Dictionary, sender: String) -> void: guest_received.append({"envelope": env, "sender": sender})
		)


	func stars() -> Array:
		return [host_star, guest_star]


## The only place `await process_frame` appears -- see the file header. Polls
## every star in `stars` with the same file-wide virtual clock.
func _step(stars: Array, dt_ms: int = 0) -> void:
	await process_frame
	_virtual_now += dt_ms
	for s in stars:
		(s as CouchStarTransport).poll(_virtual_now)


## `step_dt_ms` (default 0) is the virtual-clock advance applied on EVERY
## iteration of this wait, same as `_step`'s own `dt_ms`. Default 0 preserves
## every other call site's existing behaviour (an ordinary establishment wait
## needs no virtual time to pass at all). A nonzero value is for a wait whose
## OWN success depends on a background, virtual-time-gated retry -- e.g. F17's
## final wait, which needs CouchStarTransport's SDP retransmit timer to fire at
## least once. Without this, `_wait_until`'s real-wall-clock loop can spin for
## the full `timeout_ms` while `_virtual_now` never moves, so a retry gated on
## it can never fire -- exactly the bug this comment exists to prevent
## reintroducing (found by actually running this gate against F17).
func _wait_until(
	stars: Array, predicate: Callable, label: String, timeout_ms: int = WAIT_TIMEOUT_MS, step_dt_ms: int = 0
) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await _step(stars, step_dt_ms)
	printerr("  TIMEOUT waiting for %s" % label)
	return false


## First entry in `captured` (a signaling's recorded-after-JSON-round-trip send
## log) matching `kind_filter` (empty == any kind) and `gen_filter`. `gen` always
## arrives as a float here (see the file header), hence the int() coercion.
func _find_captured(captured: Array, kind_filter: String, gen_filter: int) -> Variant:
	for entry in captured:
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry
		if not kind_filter.is_empty() and str(e.get("kind", "")) != kind_filter:
			continue
		if int(e.get("gen", -999)) != gen_filter:
			continue
		return e
	return null


## Drive `pair`'s host to a connection that was NEVER live at generation 0 --
## only ever OFFERED (and captured) at generation 0 -- and IS live at generation
## 1. Mechanism: drop the host's gen-0 offer/ICE entirely (F4's technique) until
## its connect timeout rebuilds exactly once, then lift the drop and let the
## gen-1 handshake through for real. Several fault cases (F6, F6b, F7, F8) need
## exactly this state, since a generation can only ever advance via this
## pre-connection rebuild path -- an established link cannot bump its own
## generation (see the plan's settled generation rule).
func _drive_host_to_gen1(pair: _Pair) -> bool:
	pair.host_signaling.drop_all = true
	var host_start: Dictionary = await pair.host_star.start()
	var guest_start: Dictionary = await pair.guest_star.start()
	if not (bool(host_start.get("success", false)) and bool(guest_start.get("success", false))):
		return false

	await _step(pair.stars())                                            # arm the connect deadline
	await _step(pair.stars(), CouchStarTransport.CONNECT_TIMEOUT_MS + 1000)   # fire it -> rebuild to gen 1
	if pair.host_star.generation_for(pair.guest_id) != 1:
		return false

	pair.host_signaling.drop_all = false
	var predicate := func() -> bool:
		return pair.host_ready.has(pair.guest_id) and pair.guest_ready.has(pair.host_id)
	return await _wait_until(pair.stars(), predicate, "the generation-1 handshake to establish once drop_all is lifted")


# ============================================================================
# F1 -- ICE before SDP (M41)
# ============================================================================


func _run_f1_ice_before_sdp(pair: _Pair) -> void:
	print("-- F1: ICE demonstrably arrives before SDP (host SDP held) --")
	pair.host_signaling.hold_kind = "sdp"

	var host_start: Dictionary = await pair.host_star.start()
	var guest_start: Dictionary = await pair.guest_star.start()
	_check(bool(host_start.get("success", false)), "F1: host_star.start() succeeds")
	_check(bool(guest_start.get("success", false)), "F1: guest_star.start() succeeds")

	var ice_predicate := func() -> bool:
		return _find_captured(pair.host_signaling.captured, "ice", 0) != null
	var ice_captured := await _wait_until(
		pair.stars(), ice_predicate,
		"F1: the host to generate and send a gen-0 ICE candidate while its SDP offer is held"
	)
	_check(ice_captured, "F1: setup -- the host's ICE candidate(s) were sent while the SDP offer was held")

	pair.host_signaling.release_held()

	var both_ready_predicate := func() -> bool:
		return pair.host_ready.has(pair.guest_id) and pair.guest_ready.has(pair.host_id)
	var both_ready := await _wait_until(
		pair.stars(), both_ready_predicate,
		"F1: both sides to reach peer_ready after the held SDP is released"
	)
	_check(
		both_ready,
		"F1 (M41): both sides reach peer_ready even though ICE demonstrably arrived before the SDP offer"
	)


# ============================================================================
# F2 -- duplicate peer_joined for an already-connected peer (M42)
# ============================================================================


func _run_f2_duplicate_peer_joined(pair: _Pair) -> void:
	print("-- F2: duplicate peer_joined after establishment --")
	var host_ready_before := pair.host_ready.size()
	var guest_ready_before := pair.guest_ready.size()
	var host_gaps_before := pair.host_gaps.size()
	var guest_gaps_before := pair.guest_gaps.size()
	var collisions_before := pair.host_star.net_id_collisions + pair.guest_star.net_id_collisions

	pair.host_signaling.announce(pair.guest_id)
	pair.host_signaling.announce(pair.guest_id)
	pair.guest_signaling.announce(pair.host_id)
	pair.guest_signaling.announce(pair.host_id)

	# A duplicate join is a no-op by construction if the fix holds -- there is no
	# new signal to wait FOR, so just pump a handful of frames and confirm
	# nothing new happened.
	for i in range(10):
		await _step(pair.stars())

	_check(
		pair.host_ready.size() == host_ready_before and pair.guest_ready.size() == guest_ready_before,
		"F2 (M42): duplicate peer_joined fires peer_ready exactly once per side (no new entries)"
	)
	_check(
		pair.host_star.net_id_collisions + pair.guest_star.net_id_collisions == collisions_before,
		"F2 (M42): net_id_collisions is unaffected by a duplicate peer_joined for an already-connected peer"
	)
	_check(
		pair.host_gaps.size() == host_gaps_before and pair.guest_gaps.size() == guest_gaps_before,
		"F2 (M42): no transport_gap fired from a duplicate peer_joined"
	)

	var pre_frame_count := pair.guest_received.size()
	_check(
		pair.host_star.send_to_peer(pair.guest_id, CouchEnvelope.make(CouchEnvelope.KIND_HELLO, 1, 900, {})),
		"F2: host_star.send_to_peer is still accepted for send after the duplicate joins"
	)
	var frame_predicate := func() -> bool: return pair.guest_received.size() > pre_frame_count
	var frame_crossed := await _wait_until(
		pair.stars(), frame_predicate, "F2: a frame to still cross the link after the duplicate peer_joined events"
	)
	_check(frame_crossed, "F2 (M42): a frame still crosses after the duplicate peer_joined events")


# ============================================================================
# F3 -- duplicate SDP/ICE for the whole run (no numbered mutation; see the
# file header's honesty-risk note before trusting a red/green result here)
# ============================================================================


func _run_f3_duplicate_sends(pair: _Pair) -> void:
	print("-- F3: duplicate SDP/ICE for the whole establishment (HONESTY RISK, see file header) --")
	pair.host_signaling.duplicate_sends = true
	pair.guest_signaling.duplicate_sends = true

	var host_start: Dictionary = await pair.host_star.start()
	var guest_start: Dictionary = await pair.guest_star.start()
	_check(
		bool(host_start.get("success", false)) and bool(guest_start.get("success", false)),
		"F3: setup -- both sides start() with duplicate_sends on"
	)

	var both_ready_predicate := func() -> bool:
		return pair.host_ready.has(pair.guest_id) and pair.guest_ready.has(pair.host_id)
	var both_ready := await _wait_until(
		pair.stars(), both_ready_predicate,
		"F3: both sides to establish despite every handshake blob being delivered twice"
	)
	_check(both_ready, "F3: the link still comes up with every SDP/ICE message duplicated")

	var host_ready_matches := 0
	for pid in pair.host_ready:
		if pid == pair.guest_id:
			host_ready_matches += 1
	var guest_ready_matches := 0
	for pid in pair.guest_ready:
		if pid == pair.host_id:
			guest_ready_matches += 1
	_check(
		host_ready_matches == 1 and guest_ready_matches == 1,
		"F3: exactly one peer_ready per side despite the duplicated handshake traffic "
			+ "(may not reliably distinguish a retransmit-guard removal -- see the file header)"
	)


# ============================================================================
# F4 -- host connect timeout, one rebuild, then terminal failure
# (not in the M19/M36-M51 list; implemented for the table's own sake)
# ============================================================================


func _run_f4_host_timeout_rebuild(pair: _Pair) -> void:
	print("-- F4: host connect timeout + rebuild, then terminal failure --")
	pair.host_signaling.drop_all = true

	var host_start: Dictionary = await pair.host_star.start()
	var guest_start: Dictionary = await pair.guest_star.start()
	_check(
		bool(host_start.get("success", false)) and bool(guest_start.get("success", false)),
		"F4: setup -- both sides start() (the host's SDP/ICE sends are dropped from here on)"
	)

	await _step(pair.stars())   # arm the first connect deadline

	var restarts_before := pair.host_star.handshake_restarts
	var gaps_before := pair.host_gaps.size()
	await _step(pair.stars(), CouchStarTransport.CONNECT_TIMEOUT_MS + 1000)

	_check(
		pair.host_star.handshake_restarts == restarts_before + 1,
		"F4: the first connect timeout bumps handshake_restarts by exactly 1"
	)
	_check(
		pair.host_star.generation_for(pair.guest_id) == 1,
		"F4: the first connect timeout rebuilds at generation 1"
	)
	var first_gap_seen := false
	for g in pair.host_gaps.slice(gaps_before):
		if g["peer_id"] == pair.guest_id and g["reason"] == "handshake-restart":
			first_gap_seen = true
	_check(first_gap_seen, "F4: transport_gap(pid, \"handshake-restart\") fired for the first timeout")

	await _step(pair.stars())   # arm the second (post-rebuild) connect deadline

	var failures_before := pair.host_star.connect_failures
	await _step(pair.stars(), CouchStarTransport.CONNECT_TIMEOUT_MS + 1000)

	_check(
		pair.host_star.connect_failures == failures_before + 1,
		"F4: the second connect timeout is terminal -- connect_failures goes up by exactly 1"
	)
	_check(
		pair.host_star.generation_for(pair.guest_id) == 1,
		"F4: generation_for stays at 1 after the terminal failure -- MAX_CONNECT_ATTEMPTS is honored, no third attempt"
	)
	var connect_failed_gap := false
	for g in pair.host_gaps:
		if g["peer_id"] == pair.guest_id and g["reason"] == "connect-failed":
			connect_failed_gap = true
	_check(connect_failed_gap, "F4: transport_gap(pid, \"connect-failed\") fired for the terminal failure")


# ============================================================================
# F5 -- the guest's own connect timeout is loud (M43)
# ============================================================================


func _run_f5_guest_timeout(pair: _Pair) -> void:
	print("-- F5: guest connect timeout is loud --")
	pair.guest_signaling.drop_all = true

	var host_start: Dictionary = await pair.host_star.start()
	var guest_start: Dictionary = await pair.guest_star.start()
	_check(
		bool(host_start.get("success", false)) and bool(guest_start.get("success", false)),
		"F5: setup -- both sides start() (the guest's replies are dropped from here on)"
	)

	await _step(pair.stars())   # arm the guest's own connect deadline

	var failures_before := pair.guest_star.connect_failures
	await _step(pair.stars(), CouchStarTransport.GUEST_CONNECT_TIMEOUT_MS + 1000)

	_check(
		pair.guest_star.connect_failures == failures_before + 1,
		"F5 (M43): the guest's own connect timeout is loud -- connect_failures goes up by exactly 1"
	)
	var gap_seen := false
	for g in pair.guest_gaps:
		if g["peer_id"] == pair.host_id and g["reason"] == "connect-failed":
			gap_seen = true
	_check(gap_seen, "F5 (M43): the guest emits transport_gap(host, \"connect-failed\")")


# ============================================================================
# F6 -- a delayed, replayed generation-0 SDP must not disturb a live
# generation-1 link (M19 / M36) -- the critical finding this whole gate exists
# to prove closed.
# ============================================================================


func _run_f6_delayed_stale_generation(pair: _Pair) -> void:
	print("-- F6: a delayed generation-0 SDP must not disturb a live generation-1 link --")
	var established := await _drive_host_to_gen1(pair)
	_check(established, "F6: setup -- the pair reaches a live link at generation 1")
	if not established:
		return

	var gen0_offer: Variant = _find_captured(pair.host_signaling.captured, CouchStarTransport.SIGNAL_KIND_SDP, 0)
	_check(
		gen0_offer != null,
		"F6: setup -- a generation-0 SDP offer was captured (before the rebuild) to drop into replay"
	)
	if gen0_offer == null:
		return

	var restarts_before := pair.guest_star.handshake_restarts
	var lost_before := pair.guest_lost.size()
	var stale_before := pair.guest_star.stale_generation_drops

	pair.guest_signaling.replay(gen0_offer, pair.host_id)
	await _step(pair.stars())
	await _step(pair.stars())

	_check(
		pair.guest_star.generation_for(pair.host_id) == 1,
		"F6 (M19/M36): the guest's generation stays at 1 after the replayed stale generation-0 SDP"
	)
	_check(
		pair.guest_star.handshake_restarts == restarts_before,
		"F6 (M19/M36): handshake_restarts is unchanged -- the stale SDP did not trigger a rebuild"
	)
	_check(
		pair.guest_lost.size() == lost_before,
		"F6 (M19/M36): peer_lost never fired -- the live link was untouched"
	)
	_check(
		pair.guest_star.stale_generation_drops == stale_before + 1,
		"F6 (M19/M36): stale_generation_drops goes up by exactly 1"
	)

	var pre_frame_count := pair.host_received.size()
	pair.guest_star.send_to_authority(CouchEnvelope.make(CouchEnvelope.KIND_INTENT, 1, 950, {}))
	var frame_predicate := func() -> bool: return pair.host_received.size() > pre_frame_count
	var frame_crossed := await _wait_until(
		pair.stars(), frame_predicate, "F6: a frame to still cross the untouched live link after the stale replay"
	)
	_check(frame_crossed, "F6 (M19/M36): a frame still crosses the live link after the stale replay")


# ============================================================================
# F6b -- the host, sole minter, never adopts a differing generation (M40)
# ============================================================================


func _run_f6b_host_never_adopts(pair: _Pair, donor: _Pair) -> void:
	print("-- F6b: the host never adopts a differing generation --")
	var established := await _drive_host_to_gen1(pair)
	_check(established, "F6b: setup -- the pair reaches a live link at generation 1")
	if not established:
		return

	# Borrowed from `donor`'s guest, which established cleanly at generation 0
	# (any real, cleanly-captured guest blob at gen 0 works -- replay() re-emits
	# it verbatim regardless of which pair originally produced it).
	var gen0_guest_blob: Variant = _find_captured(donor.guest_signaling.captured, "", 0)
	_check(
		gen0_guest_blob != null,
		"F6b: setup -- a captured generation-0 guest blob is available to replay"
	)
	if gen0_guest_blob == null:
		return

	var gen_before := pair.host_star.generation_for(pair.guest_id)
	var stale_before := pair.host_star.stale_generation_drops

	pair.host_signaling.replay(gen0_guest_blob, pair.guest_id)
	await _step(pair.stars())
	await _step(pair.stars())

	_check(
		pair.host_star.generation_for(pair.guest_id) == gen_before,
		"F6b (M40): the host's generation for the guest is unchanged -- the sole minter never adopts"
	)
	_check(
		pair.host_star.stale_generation_drops == stale_before + 1,
		"F6b (M40): stale_generation_drops on the host goes up by exactly 1"
	)


# ============================================================================
# F7 -- a rejoin recovers a live-but-dead link (M38). A clean pair, no
# interference: this is what proves the fixed recovery path actually works
# end to end.
# ============================================================================


func _run_f7_rejoin(pair: _Pair) -> void:
	print("-- F7: a rejoin recovers a live-but-dead link --")
	var established := await _drive_host_to_gen1(pair)
	_check(established, "F7: setup -- the pair reaches a live link at generation 1")
	if not established:
		return

	var host_ready_before := pair.host_ready.size()
	var guest_ready_before := pair.guest_ready.size()

	# Both sides, in the SAME frame, observe their own local rejoin -- see the
	# file header's honesty-risk note on why this mirrors the host too, not only
	# the guest the setup cell names.
	pair.guest_signaling.announce_left(pair.host_id)
	pair.guest_signaling.announce(pair.host_id)
	pair.host_signaling.announce_left(pair.guest_id)
	pair.host_signaling.announce(pair.guest_id)

	var rejoin_predicate := func() -> bool:
		for g in pair.guest_gaps:
			if g["peer_id"] == pair.host_id and g["reason"] == "peer-rejoined":
				return true
		return false
	var rejoin_processed := await _wait_until(
		pair.stars(), rejoin_predicate, "F7: the guest to process the rejoin and fire transport_gap(host, \"peer-rejoined\")"
	)
	_check(rejoin_processed, "F7 (M38): the guest fires transport_gap(host, \"peer-rejoined\")")
	_check(
		pair.guest_lost.has(pair.host_id),
		"F7 (M38): the guest fires peer_lost(host) for the abandoned live-but-dead connection"
	)
	_check(
		pair.guest_star.generation_for(pair.host_id) == 0,
		"F7 (M38): the guest's generation for the host resets to 0 after the rejoin"
	)

	var ready_again_predicate := func() -> bool:
		return pair.host_ready.size() > host_ready_before and pair.guest_ready.size() > guest_ready_before
	var both_ready_again := await _wait_until(
		pair.stars(), ready_again_predicate,
		"F7: both sides to reach peer_ready a second time once the rebuilt connection establishes"
	)
	_check(
		both_ready_again,
		"F7 (M38): peer_ready fires a second time on both sides once the rejoin's fresh handshake completes"
	)


# ============================================================================
# F8 -- the rejoin barrier holds against a stale replay in the window before
# the fresh generation-0 offer arrives (M37). A SEPARATE dedicated pair from
# F7: measured empirically (running this gate) that on this engine, the
# host's fresh post-rejoin offer AND its ICE candidates can both reach the
# guest and clear the barrier within the very first _step() that processes
# the deferred rejoin -- there is no naturally-occurring multi-frame window to
# inject a stale replay into. `hold_kind` (a single string) cannot hold both
# "sdp" and "ice" at once, so it cannot close that race either -- an early
# gen-0 ICE candidate would still clear the barrier while only "sdp" is held.
# `drop_all` blocks BOTH, deterministically, for the rest of this pair's life;
# this function does not need the pair to ever establish again afterward
# (F7's own clean pair already proves recovery works), only that the barrier
# demonstrably holds while armed.
# ============================================================================


func _run_f8_rejoin_barrier(pair: _Pair) -> void:
	print("-- F8: the rejoin barrier holds against a stale replay --")
	var established := await _drive_host_to_gen1(pair)
	_check(established, "F8: setup -- the pair reaches a live link at generation 1")
	if not established:
		return

	var gen1_blob: Variant = _find_captured(pair.host_signaling.captured, CouchStarTransport.SIGNAL_KIND_SDP, 1)
	if gen1_blob == null:
		gen1_blob = _find_captured(pair.host_signaling.captured, CouchStarTransport.SIGNAL_KIND_ICE, 1)
	_check(gen1_blob != null, "F8: setup -- a captured generation-1 blob is available to replay")
	if gen1_blob == null:
		return

	pair.host_signaling.drop_all = true

	pair.guest_signaling.announce_left(pair.host_id)
	pair.guest_signaling.announce(pair.host_id)
	pair.host_signaling.announce_left(pair.guest_id)
	pair.host_signaling.announce(pair.guest_id)

	var rejoin_predicate := func() -> bool:
		for g in pair.guest_gaps:
			if g["peer_id"] == pair.host_id and g["reason"] == "peer-rejoined":
				return true
		return false
	var rejoin_processed := await _wait_until(
		pair.stars(), rejoin_predicate, "F8: the guest to process the rejoin and arm the rejoin barrier"
	)
	_check(rejoin_processed, "F8: setup -- the guest processes the rejoin (transport_gap fires, barrier arms)")
	if not rejoin_processed:
		return

	var restarts_before := pair.guest_star.handshake_restarts
	var stale_before := pair.guest_star.stale_generation_drops

	pair.guest_signaling.replay(gen1_blob, pair.host_id)
	await _step(pair.stars())

	_check(
		pair.guest_star.generation_for(pair.host_id) == 0,
		"F8 (M37): the guest stays at generation 0 -- the rejoin barrier holds against a stale generation-1 replay"
	)
	_check(
		pair.guest_star.stale_generation_drops == stale_before + 1,
		"F8 (M37): stale_generation_drops goes up by exactly 1"
	)
	_check(
		pair.guest_star.handshake_restarts == restarts_before,
		"F8 (M37): no rebuild happens from the barred replay"
	)


# ============================================================================
# F9 -- the generation budget rejects an out-of-range generation (M39)
# ============================================================================


func _run_f9_generation_budget(pair: _Pair) -> void:
	print("-- F9: the generation budget rejects an out-of-range generation --")
	var host_start: Dictionary = await pair.host_star.start()
	var guest_start: Dictionary = await pair.guest_star.start()
	_check(
		bool(host_start.get("success", false)) and bool(guest_start.get("success", false)),
		"F9: setup -- both sides start()"
	)

	var ready_predicate := func() -> bool:
		return pair.host_ready.has(pair.guest_id) and pair.guest_ready.has(pair.host_id)
	var both_ready := await _wait_until(pair.stars(), ready_predicate, "F9: setup -- the pair to establish at generation 0")
	_check(both_ready, "F9: setup -- the pair establishes at generation 0")
	if not both_ready:
		return

	var over_budget_gen := CouchStarTransport.MAX_GEN + 1
	var bad_blob := {
		"v": CouchStarTransport.SIGNAL_PROTOCOL_VERSION,
		"gen": over_budget_gen,
		"kind": CouchStarTransport.SIGNAL_KIND_SDP,
		"sdp_type": "offer",
		"sdp": "irrelevant-because-rejected-before-parsing",
	}

	var rejected_before := pair.guest_star.rejected_count
	var gen_before := pair.guest_star.generation_for(pair.host_id)
	var restarts_before := pair.guest_star.handshake_restarts

	pair.guest_signaling.replay(bad_blob, pair.host_id)
	await _step(pair.stars())

	_check(
		pair.guest_star.rejected_count == rejected_before + 1,
		"F9 (M39): an SDP at gen = MAX_GEN + 1 is rejected -- rejected_count goes up by exactly 1"
	)
	_check(
		pair.guest_star.generation_for(pair.host_id) == gen_before,
		"F9 (M39): generation_for is unchanged by the out-of-budget replay"
	)
	_check(
		pair.guest_star.handshake_restarts == restarts_before,
		"F9 (M39): no rebuild happens from the out-of-budget replay"
	)


# ============================================================================
# F10 -- close() during start()'s own await (M47)
# ============================================================================


func _run_f10_close_during_start() -> void:
	print("-- F10: close() during start()'s own await --")
	var signaling := CouchScriptedSignaling.new("solo10")
	var player := {"user_id": "solo10"}
	var roster := _StarRoster.new(player, player, true)
	var star := CouchStarTransport.new(signaling, roster)

	var close_count_before := signaling.close_count
	# `star.start()` bare (no `await`) is a PARSE error here -- GDScript's
	# static analyzer proves at compile time that start() is a coroutine and
	# refuses to load the file at all ("Function \"start()\" is a coroutine, so
	# it must be called with \"await\""); no amount of awaiting it later at a
	# DIFFERENT point helps, because the file never parses. Object.call() is a
	# dynamic dispatch the analyzer cannot resolve at compile time, so it is
	# exempt from that check -- and at runtime it invokes the exact same
	# compiled coroutine, which still runs to its first internal suspension
	# point (inside start(), that is `await _signaling.connect_room()`) and
	# returns the same awaitable Signal a bare `await`-less call would have.
	# Confirmed by actually running this gate on Godot 4.7 headless: F10 needs
	# close() to land while connect_room() is still in flight, and F11 (below)
	# needs the SECOND start() call to observe `_starting == true`
	# synchronously -- both require exactly the "runs to the first suspension
	# point, then returns control to the caller" semantics, and both hold
	# under call("start").
	var start_future: Variant = star.call("start")
	star.close()
	var result: Dictionary = await start_future

	_check(
		bool(result.get("success", true)) == false and str(result.get("error", "")) == "superseded",
		"F10 (M47): start() superseded by a close() during its own await returns {success: false, error: \"superseded\"}"
	)
	_check(
		signaling.close_count >= close_count_before + 1,
		"F10 (M47): the signaling membership's close() ran, releasing what start() had joined"
	)
	_check(star.is_ready() == false, "F10: is_ready() is false after the aborted start()")


# ============================================================================
# F11 -- concurrent start() calls (M46)
# ============================================================================


func _run_f11_concurrent_start() -> void:
	print("-- F11: concurrent start() calls --")
	var signaling := CouchScriptedSignaling.new("solo11")
	var player := {"user_id": "solo11"}
	var roster := _StarRoster.new(player, player, true)
	var star := CouchStarTransport.new(signaling, roster)

	# See F10's comment above on why call("start") replaces a bare start() --
	# same parse-time restriction, same dynamic-dispatch escape.
	var f1: Variant = star.call("start")
	var f2: Variant = star.call("start")
	var r1: Dictionary = await f1
	var r2: Dictionary = await f2

	var success_count := 0
	if bool(r1.get("success", false)):
		success_count += 1
	if bool(r2.get("success", false)):
		success_count += 1
	_check(success_count == 1, "F11 (M46): exactly one of the two concurrent start() calls succeeds")

	var errors := [str(r1.get("error", "")), str(r2.get("error", ""))]
	_check(
		errors.has("already-started"),
		"F11 (M46): the other concurrent start() call returns error \"already-started\""
	)
	_check(
		signaling.connect_room_count == 1,
		"F11 (M46): connect_room() was invoked exactly once despite two concurrent start() calls"
	)


# ============================================================================
# F13 -- the peer limit is enforced and loud (M48)
# ============================================================================


func _run_f13_peer_limit() -> void:
	print("-- F13: the peer limit is enforced and loud --")
	var signaling := CouchScriptedSignaling.new("solo13")
	var player := {"user_id": "solo13"}
	var roster := _StarRoster.new(player, player, true)
	var star := CouchStarTransport.new(signaling, roster)

	var gaps: Array = []
	star.transport_gap.connect(func(pid: String, reason: String) -> void: gaps.append({"peer_id": pid, "reason": reason}))

	var start_result: Dictionary = await star.start()
	_check(bool(start_result.get("success", false)), "F13: setup -- the solo host starts")

	var announced: Array = []
	for i in range(CouchStarTransport.MAX_PEERS + 3):
		var pid := "peer-limit-%d" % i
		announced.append(pid)
		signaling.announce(pid)

	# One deferred frame is enough for each announce()'s peer_joined to fire and
	# for _discover_peer to run synchronously off it; a generous margin below.
	for i in range(announced.size() + 5):
		await _step([star])

	var mapped := 0
	for pid in announced:
		if star.net_id_for(pid) != 0:
			mapped += 1
	_check(
		mapped == CouchStarTransport.MAX_PEERS,
		"F13 (M48): exactly MAX_PEERS (%d) of the announced ids get a nonzero net id (got %d)"
			% [CouchStarTransport.MAX_PEERS, mapped]
	)

	var limit_gaps := 0
	for g in gaps:
		if g["reason"] == "peer-limit":
			limit_gaps += 1
	var expected_refused: int = announced.size() - CouchStarTransport.MAX_PEERS
	_check(
		limit_gaps == expected_refused,
		"F13 (M48): transport_gap(pid, \"peer-limit\") fired for every id refused past the cap (got %d, want %d)"
			% [limit_gaps, expected_refused]
	)


# ============================================================================
# F14 -- 200 distinct unknown handshake kinds collapse under ONE flood-control
# key (M49). Reuses the MAIN pair: orthogonal to generation state.
# ============================================================================


func _run_f14_flood_control(pair: _Pair) -> void:
	print("-- F14: 200 distinct unknown handshake kinds collapse under one flood-control key --")
	var rejected_before := pair.guest_star.rejected_count
	var logged_before := pair.guest_star.logged_reject_kinds

	for i in range(200):
		var blob := {
			"v": CouchStarTransport.SIGNAL_PROTOCOL_VERSION,
			"gen": 0,
			"kind": "unknown-kind-%d" % i,
		}
		pair.guest_signaling.replay(blob, pair.host_id)

	await _step(pair.stars())

	_check(
		pair.guest_star.rejected_count == rejected_before + 200,
		"F14 (M49): rejected_count goes up by exactly 200 for 200 distinct unknown handshake kinds"
	)
	_check(
		pair.guest_star.logged_reject_kinds == logged_before + 1,
		"F14 (M49): logged_reject_kinds goes up by exactly 1 -- the attacker-controlled kind text never enters the dedup key"
	)


# ============================================================================
# F15 -- an oversized SDP / candidate is rejected without disturbing the link
# (M50). Reuses the MAIN pair.
# ============================================================================


func _run_f15_oversized(pair: _Pair) -> void:
	print("-- F15: an oversized SDP / candidate is rejected without disturbing the link --")
	var local_gen := pair.guest_star.generation_for(pair.host_id)
	var rejected_before := pair.guest_star.rejected_count
	var gen_before := pair.guest_star.generation_for(pair.host_id)
	var ready_before := pair.guest_star.is_ready()

	var oversized_sdp := {
		"v": CouchStarTransport.SIGNAL_PROTOCOL_VERSION,
		"gen": local_gen,
		"kind": CouchStarTransport.SIGNAL_KIND_SDP,
		"sdp_type": "offer",
		"sdp": "x".repeat(CouchStarTransport.MAX_SDP_CHARS + 1),
	}
	var oversized_candidate := {
		"v": CouchStarTransport.SIGNAL_PROTOCOL_VERSION,
		"gen": local_gen,
		"kind": CouchStarTransport.SIGNAL_KIND_ICE,
		"mid": "0",
		"index": 0,
		"candidate": "x".repeat(CouchStarTransport.MAX_CANDIDATE_CHARS + 1),
	}

	pair.guest_signaling.replay(oversized_sdp, pair.host_id)
	pair.guest_signaling.replay(oversized_candidate, pair.host_id)
	await _step(pair.stars())

	_check(
		pair.guest_star.rejected_count == rejected_before + 2,
		"F15 (M50): both the oversized SDP and the oversized candidate are rejected -- rejected_count goes up by exactly 2"
	)
	_check(
		pair.guest_star.generation_for(pair.host_id) == gen_before,
		"F15 (M50): generation_for is unchanged by either oversized frame"
	)
	_check(
		pair.guest_star.is_ready() == ready_before,
		"F15 (M50): is_ready() (a proxy for _connected) is unchanged by either oversized frame"
	)


# ============================================================================
# F16 -- a flood of undecodable envelopes trips a decode-failure mute, which
# then expires (M51). Reuses the MAIN pair.
# ============================================================================


func _run_f16_decode_mute(pair: _Pair) -> void:
	print("-- F16: 40 undecodable envelopes trip a decode-failure mute, which expires --")
	var gaps_before := pair.host_gaps.size()
	var mutes_before := pair.host_star.decode_mutes

	var next_seq := 5000
	for i in range(40):
		next_seq += 1
		pair.guest_star.send_to_authority(CouchEnvelope.make("bogus", 1, next_seq, {}))

	var mute_predicate := func() -> bool: return pair.host_star.decode_mutes > mutes_before
	var muted := await _wait_until(
		pair.stars(), mute_predicate, "F16 (M51): the host to mute the guest after enough decode failures"
	)
	_check(muted, "F16 (M51): decode_mutes goes up -- the flood of bogus-kind envelopes trips the mute")
	_check(pair.host_star.decode_mutes == mutes_before + 1, "F16 (M51): decode_mutes goes up by exactly 1")

	var mute_gap_seen := false
	var mute_gap_count := 0
	for g in pair.host_gaps.slice(gaps_before):
		if g["peer_id"] == pair.guest_id and g["reason"] == "peer-muted":
			mute_gap_seen = true
			mute_gap_count += 1
	_check(
		mute_gap_seen and mute_gap_count == 1,
		"F16 (M51): transport_gap(pid, \"peer-muted\") fires exactly once"
	)

	next_seq += 1
	var muted_valid_seq := next_seq
	var pre_received := pair.host_received.size()
	pair.guest_star.send_to_authority(
		CouchEnvelope.make(CouchEnvelope.KIND_INTENT, 1, muted_valid_seq, {"probe": "while-muted"})
	)
	for i in range(10):
		await _step(pair.stars())
	var arrived_while_muted := false
	for e in pair.host_received.slice(pre_received):
		var env: Dictionary = e["envelope"]
		if int(env.get(CouchEnvelope.KEY_SEQ, -1)) == muted_valid_seq:
			arrived_while_muted = true
	_check(not arrived_while_muted, "F16 (M51): a valid frame sent WHILE muted does not arrive")

	await _step(pair.stars(), CouchStarTransport.MUTE_DURATION_MS + 500)

	next_seq += 1
	var post_expiry_seq := next_seq
	var pre_received_2 := pair.host_received.size()
	pair.guest_star.send_to_authority(
		CouchEnvelope.make(CouchEnvelope.KIND_INTENT, 1, post_expiry_seq, {"probe": "after-expiry"})
	)
	var post_expiry_predicate := func() -> bool: return pair.host_received.size() > pre_received_2
	var arrived_after_expiry := await _wait_until(
		pair.stars(), post_expiry_predicate, "F16 (M51): a valid frame sent AFTER the mute expires to arrive"
	)
	_check(arrived_after_expiry, "F16 (M51): a valid frame sent after MUTE_DURATION_MS expires DOES arrive")


# ============================================================================
# F17 -- an empty host roster at start() defers, then resolves once the
# roster is populated (M44)
# ============================================================================


func _run_f17_late_host_resolves() -> void:
	print("-- F17: an empty host roster at start() defers, then resolves once populated --")
	var host_signaling := CouchScriptedSignaling.new("host17")
	var guest_signaling := CouchScriptedSignaling.new("g17")
	CouchScriptedSignaling.link(host_signaling, guest_signaling)

	var host_player := {"user_id": "host17"}
	var guest_player := {"user_id": "g17"}
	var host_roster := _StarRoster.new(host_player, host_player, true)
	var guest_roster := _LateHostRoster.new(guest_player)

	var host_star := CouchStarTransport.new(host_signaling, host_roster)
	var guest_star := CouchStarTransport.new(guest_signaling, guest_roster)

	var host_ready: Array = []
	host_star.peer_ready.connect(func(pid: String) -> void: host_ready.append(pid))
	var guest_ready: Array = []
	guest_star.peer_ready.connect(func(pid: String) -> void: guest_ready.append(pid))

	var host_start: Dictionary = await host_star.start()
	var guest_start: Dictionary = await guest_star.start()
	_check(
		bool(host_start.get("success", false)) and bool(guest_start.get("success", false)),
		"F17: setup -- both sides start() successfully even though the guest's roster has no host yet"
	)
	_check(
		guest_star.net_id_for("host17") == 0,
		"F17: setup -- the guest has NOT discovered the host yet (roster unresolved)"
	)

	guest_signaling.announce("host17")
	for i in range(5):
		await _step([host_star, guest_star])
	_check(
		guest_star.net_id_for("host17") == 0,
		"F17: setup -- the announced host id is still deferred, not yet mapped"
	)

	guest_roster.set_host(host_player)
	await _step([host_star, guest_star])

	var resolved_predicate := func() -> bool:
		return guest_star.net_id_for("host17") == CouchStarTransport.HOST_NET_ID
	var resolved := await _wait_until(
		[host_star, guest_star], resolved_predicate, "F17 (M44): the guest to discover the host once the roster resolves"
	)
	_check(resolved, "F17 (M44): net_id_for(\"host17\") == HOST_NET_ID once the roster names the host")

	# The host discovered "g17" and offered at generation 0 back when start()
	# first ran (the natural mutual-join notification, unaffected by the
	# guest's late roster) -- long before the guest had a PC to receive it, so
	# that first offer was necessarily wasted. Recovery depends on the host's
	# SDP_RETRANSMIT_INTERVAL_MS retry actually firing, which needs virtual
	# time to move -- see _wait_until's step_dt_ms doc.
	var established_predicate := func() -> bool:
		return host_ready.has("g17") and guest_ready.has("host17")
	var established := await _wait_until(
		[host_star, guest_star], established_predicate, "F17 (M44): the deferred, then late-bound, handshake to establish",
		WAIT_TIMEOUT_MS, CouchStarTransport.SDP_RETRANSMIT_INTERVAL_MS
	)
	_check(established, "F17 (M44): the link comes up after the late-bound host resolution")


# ============================================================================
# F18 -- a host that never resolves is a loud, terminal failure (M45)
# ============================================================================


func _run_f18_host_never_resolves() -> void:
	print("-- F18: the host never resolving is a loud, terminal failure --")
	var host_signaling := CouchScriptedSignaling.new("host18")
	var guest_signaling := CouchScriptedSignaling.new("g18")
	CouchScriptedSignaling.link(host_signaling, guest_signaling)

	var host_player := {"user_id": "host18"}
	var guest_player := {"user_id": "g18"}
	var host_roster := _StarRoster.new(host_player, host_player, true)
	var guest_roster := _LateHostRoster.new(guest_player)   # get_host() stays null for the whole test

	var host_star := CouchStarTransport.new(host_signaling, host_roster)
	var guest_star := CouchStarTransport.new(guest_signaling, guest_roster)

	var guest_gaps: Array = []
	guest_star.transport_gap.connect(
		func(pid: String, reason: String) -> void: guest_gaps.append({"peer_id": pid, "reason": reason})
	)

	var host_start: Dictionary = await host_star.start()
	var guest_start: Dictionary = await guest_star.start()
	_check(
		bool(host_start.get("success", false)) and bool(guest_start.get("success", false)),
		"F18: setup -- both sides start() successfully"
	)

	guest_signaling.announce("host18")
	for i in range(5):   # let the deferred announce fire and arm the resolution deadline
		await _step([host_star, guest_star])

	var failures_before := guest_star.connect_failures
	await _step([host_star, guest_star], CouchStarTransport.HOST_RESOLVE_TIMEOUT_MS + 1000)

	_check(
		guest_star.connect_failures == failures_before + 1,
		"F18 (M45): a host that never resolves is a terminal, loud failure -- connect_failures goes up by exactly 1"
	)
	var gap_seen := false
	for g in guest_gaps:
		if g["reason"] == "host-unresolved":
			gap_seen = true
	_check(gap_seen, "F18 (M45): transport_gap(pid, \"host-unresolved\") fired")


# ============================================================================
# Orchestration
# ============================================================================


func _run() -> void:
	print("== Couch star transport fault injection (G11) ==")
	var webrtc_available := CouchStarTransport.is_webrtc_available()
	_check(webrtc_available, "is_webrtc_available() is true (else everything below is vacuous)")
	if not webrtc_available:
		printerr(
			"  no concrete WebRTC implementation is installed -- continuing anyway "
			+ "per this codebase's FAIL-not-skip discipline (see run_star_link.gd); "
			+ "expect further FAILs and timeouts below"
		)

	var main := _Pair.new("host", "g1")
	await _run_f1_ice_before_sdp(main)
	await _run_f2_duplicate_peer_joined(main)

	var p3 := _Pair.new("host3", "g3")
	await _run_f3_duplicate_sends(p3)

	var p4 := _Pair.new("host4", "g4")
	await _run_f4_host_timeout_rebuild(p4)

	var p5 := _Pair.new("host5", "g5")
	await _run_f5_guest_timeout(p5)

	var p6 := _Pair.new("host6", "g6")
	await _run_f6_delayed_stale_generation(p6)

	var p6b := _Pair.new("host6b", "g6b")
	await _run_f6b_host_never_adopts(p6b, main)

	var p7 := _Pair.new("host7", "g7")
	await _run_f7_rejoin(p7)

	var p8 := _Pair.new("host8", "g8")
	await _run_f8_rejoin_barrier(p8)

	var p9 := _Pair.new("host9", "g9")
	await _run_f9_generation_budget(p9)

	await _run_f10_close_during_start()
	await _run_f11_concurrent_start()
	await _run_f13_peer_limit()

	await _run_f14_flood_control(main)
	await _run_f15_oversized(main)
	await _run_f16_decode_mute(main)

	await _run_f17_late_host_resolves()
	await _run_f18_host_never_resolves()

	print("")
	print("total assertions: %d failed" % failures)
	if failures == 0:
		print("COUCH_STAR_FAULTS_OK")
	else:
		printerr("COUCH_STAR_FAULTS_FAILED: %d check(s)" % failures)
	quit(failures)
	return
