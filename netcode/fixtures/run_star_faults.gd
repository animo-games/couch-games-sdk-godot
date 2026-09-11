## Headless fault-injection acceptance gate for CouchStarTransport -- gate G11.
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_star_faults.gd
##
## What is REAL under test: CouchStarTransport, real WebRTCPeerConnections, and
## CouchScriptedSignaling extended with its TEST-ONLY fault-injection surface
## (netcode/fixtures/scripted_signaling.gd -- hold_kind/release_held, drop_all,
## duplicate_sends, captured, replay, announce_left, close_count,
## connect_room_count, is_joined). run_star_link.gd (G8) proves the star
## establishes and carries traffic cleanly; run_star_unit.gd (G7) proves
## classify_incarnation and the codec in isolation. Neither gate forces
## ICE-before-SDP, a duplicate peer_joined, a connect timeout/rebuild, a
## stale-incarnation delivery, or a close-during-start -- which is exactly why
## this gate exists: it is where Codex's critical finding (a delayed packet from
## a DEAD incarnation rebuilding the guest backward and wedging it permanently)
## becomes a test that can fail. Every assertion below is on an OBSERVED EFFECT
## -- a signal fired, a counter moved, a frame that did or did not arrive --
## never on a send's return value, which the contract documents as "accepted
## for send", not a delivery receipt.
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
## documented as reusing one that stays incarnation-stable (the MAIN pair, used
## for F1/F2 and again for the orthogonal F14/F15/F16/F22 reject/mute/validation
## counters).
##
## HONESTY RISKS, stated plainly rather than papered over:
##   - F3 (duplicate SDP/ICE): loopback establishment can be fast enough that a
##     duplicated description arrives after the connection is already up, in
##     which case this fault may not reliably turn red under a retransmit-guard
##     removal. Implemented anyway for the coverage it does provide; do not read
##     a pass here as proof of that guard.
##   - F6/F6b/F8 all replay a blob pulled from some signaling's `captured`
##     array verbatim; F6c replays one MUTATED (its `inc` field bumped past the
##     host's own) and re-JSON-round-tripped, never actually sent over the wire.
##     CONFIRMED by actually running this gate: captured DOES record a blob at
##     send()'s JSON-round-trip step regardless of whether drop_all/hold_kind
##     ultimately deliver it -- the only reading of "captured: every blob sent"
##     (netcode/fixtures/scripted_signaling.gd) that made F6's own setup
##     possible, and it holds against the real implementation.
##   - F21 (the asymmetric reconnect) depends on a REAL WebRTCPeerConnection
##     teardown on the host propagating to a real disconnect on the guest within
##     WAIT_TIMEOUT_MS -- see that function's own header comment for the full
##     reasoning. This is genuine engine timing, not a scripted guarantee, in
##     the same honesty-risk family as F3's and F7/F8's real-engine dependence.
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
##   - F23 (link death, backoff, exhaustion) kills links with the debug-only
##     CouchStarTransport.fault_kill_link and depends on the far side's engine
##     noticing a real closure -- the same real-engine dependence as F21. Every
##     DELAY assertion, by contrast, is on the virtual clock and exact.
##   - F7 and F8 are SEPARATE dedicated pairs, not one combined flow. F7 proves
##     the clean rejoin-recovery path end to end with no interference; F8
##     deliberately injects a stale, dead-incarnation replay into the same kind
##     of rejoin and proves CONVERGENCE despite it. There is no barrier any more
##     to keep armed (`_awaiting_rejoin_gen0` is deleted -- see F8's own header),
##     so unlike its predecessor F8 no longer needs `drop_all` to hold a window
##     open, and it DOES need its pair to actually re-establish afterward, which
##     is why it stays on its own pair rather than sharing F7's.
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
# F1 -- ICE before SDP, starved in BOTH directions (M41)
# ============================================================================


## Count of `signaling.captured` entries whose `kind` == `kind_filter` --
## generation-agnostic (unlike `_find_captured`), for a fault that cares only
## about volume, not any one blob's contents.
func _count_captured(captured: Array, kind_filter: String) -> int:
	var n := 0
	for entry in captured:
		if entry is Dictionary and str((entry as Dictionary).get("kind", "")) == kind_filter:
			n += 1
	return n


## Poll `pair` until `signaling`'s captured ICE count has stopped growing for
## `quiet_steps` consecutive polled frames, having captured at least one.
## Returns the count at the moment quiescence is declared, or -1 on timeout
## (nothing ever captured, or it never stopped growing within WAIT_TIMEOUT_MS).
## `dt_ms == 0` throughout (via `_step`'s default), so this never advances any
## deadline -- see the file header's virtual-clock note.
func _wait_ice_quiescent(pair: _Pair, signaling: CouchScriptedSignaling, quiet_steps: int) -> int:
	var last_count := -1
	var stable_for := 0
	var deadline := Time.get_ticks_msec() + WAIT_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		var count := _count_captured(signaling.captured, CouchStarTransport.SIGNAL_KIND_ICE)
		if count > 0 and count == last_count:
			stable_for += 1
			if stable_for >= quiet_steps:
				return count
		else:
			stable_for = 0
		last_count = count
		await _step(pair.stars())
	return -1


## Rebuilt per finding "M41 coverage hole": the previous version held only the
## HOST's SDP and released the moment the FIRST ice blob was captured, while
## gathering was still running -- so later candidates landed AFTER the SDP was
## released (post-release, i.e. NOT starved), and only the host's own
## candidates were ever buffered at all (the guest's reached a host whose
## remote description was already set, since the guest was never held). A
## mutation pass proved this stayed green even with the pending-ICE buffer
## deleted outright: ICE still completed by peer-reflexive discovery on the
## unstarved side. Fixed here as a TWO-PHASE, BOTH-DIRECTIONS starvation: both
## signalings hold "sdp" from the start, each side's ICE gathering is run all
## the way to QUIESCENCE (not just "one candidate seen") before its SDP is
## released, and the test asserts its OWN premise at the end -- that no
## candidate arrived on either side after that side's release -- so a run that
## silently stopped starving the buffer is caught rather than passing by
## accident, mirroring the exact way the old version lost its power invisibly.
func _run_f1_ice_before_sdp(pair: _Pair) -> void:
	print("-- F1: ICE buffering is load-bearing in BOTH directions (two-phase starvation, M41) --")
	pair.host_signaling.hold_kind = "sdp"
	pair.guest_signaling.hold_kind = "sdp"

	var host_start: Dictionary = await pair.host_star.start()
	var guest_start: Dictionary = await pair.guest_star.start()
	_check(bool(host_start.get("success", false)), "F1: host_star.start() succeeds")
	_check(bool(guest_start.get("success", false)), "F1: guest_star.start() succeeds")

	# Phase 1: the host's offer is held, so the guest can never take a remote
	# description yet -- every ICE candidate the host gathers in the meantime
	# lands in the guest's pending-ICE buffer. Wait for the host's gathering to
	# go fully quiescent (not merely "one candidate seen") before releasing.
	var host_ice_at_release := await _wait_ice_quiescent(pair, pair.host_signaling, 60)
	_check(
		host_ice_at_release > 0,
		"F1: setup -- the host's ICE gathering goes quiescent (>= 1 candidate, none new for 60 frames) while its own SDP offer is held"
	)
	if host_ice_at_release <= 0:
		return

	pair.host_signaling.release_held()

	# Phase 2: the guest takes the offer, flushes what it buffered, and answers
	# -- but that answer is held by the GUEST's own hold_kind, so the host has
	# no remote description either. Every candidate the guest gathers now lands
	# in the HOST's pending-ICE buffer. Wait for the guest's gathering to go
	# quiescent the same way before releasing its answer.
	var guest_ice_at_release := await _wait_ice_quiescent(pair, pair.guest_signaling, 60)
	_check(
		guest_ice_at_release > 0,
		"F1: setup -- the guest's ICE gathering goes quiescent (>= 1 candidate, none new for 60 frames) after taking the offer, with its own answer still held"
	)
	if guest_ice_at_release <= 0:
		return

	pair.guest_signaling.release_held()

	var both_ready_predicate := func() -> bool:
		return pair.host_ready.has(pair.guest_id) and pair.guest_ready.has(pair.host_id)
	var both_ready := await _wait_until(
		pair.stars(), both_ready_predicate,
		"F1: both sides to reach peer_ready after both held SDPs are released"
	)
	_check(
		both_ready,
		"F1 (M41): both sides reach peer_ready even though EVERY candidate on BOTH sides was gathered before that "
			+ "side's own SDP was released -- with the pending-ICE buffer removed, neither side would hold a single "
			+ "remote candidate and no connectivity check could ever be sent"
	)

	# The test's OWN premise, not the code's -- this is what stops it silently
	# losing its power the way the old version did. If a candidate arrived on
	# either side AFTER that side's release, this run no longer starved that
	# side's buffer and proves nothing about it.
	var host_ice_at_end := _count_captured(pair.host_signaling.captured, CouchStarTransport.SIGNAL_KIND_ICE)
	var guest_ice_at_end := _count_captured(pair.guest_signaling.captured, CouchStarTransport.SIGNAL_KIND_ICE)
	var host_premise_msg := (
		"F1 premise: the host's captured ICE count is unchanged between release and the end (%d -> %d) -- "
			+ "otherwise a candidate arrived AFTER the release, so this case no longer starves the buffer and cannot prove it load-bearing"
	) % [host_ice_at_release, host_ice_at_end]
	_check(host_ice_at_end == host_ice_at_release, host_premise_msg)
	var guest_premise_msg := (
		"F1 premise: the guest's captured ICE count is unchanged between release and the end (%d -> %d) -- "
			+ "otherwise a candidate arrived AFTER the release, so this case no longer starves the buffer and cannot prove it load-bearing"
	) % [guest_ice_at_release, guest_ice_at_end]
	_check(guest_ice_at_end == guest_ice_at_release, guest_premise_msg)


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
	# A3/finding 4: a terminal failure now tears the peer down completely
	# (_teardown_peer + a _failed tombstone), not merely caps it at generation 1
	# -- MAX_CONNECT_ATTEMPTS is proven above by handshake_restarts/gen==1 at
	# the FIRST (non-terminal) timeout; this second timeout's own guarantee is
	# that nothing is left half-mapped behind it.
	_check(
		pair.host_star.generation_for(pair.guest_id) == -1,
		"F4 (A3/finding 4): generation_for(guest) == -1 after the terminal failure -- the peer is torn down, not merely capped at generation 1"
	)
	_check(
		pair.host_star.net_id_for(pair.guest_id) == 0,
		"F4 (A3/finding 4): net_id_for(guest) == 0 after the terminal failure -- the net id mapping was released, not left dangling"
	)
	_check(
		not pair.host_star.connected_peer_ids().has(pair.guest_id),
		"F4 (A3/finding 4): the guest never appears in connected_peer_ids() -- it never actually came up"
	)
	var connect_failed_gap := false
	for g in pair.host_gaps:
		if g["peer_id"] == pair.guest_id and g["reason"] == "connect-failed":
			connect_failed_gap = true
	_check(connect_failed_gap, "F4: transport_gap(pid, \"connect-failed\") fired for the terminal failure")

	# The tombstone itself (A3/finding 4): a RAW signaling message purporting to
	# be from the failed peer -- NOT a fresh peer_joined -- must not resurrect
	# it. _on_sig_received's own "not _pcs.has(sender_pid): _discover_peer(...)"
	# path is exactly what `_failed` exists to block; the message never even
	# reaches the gen/inc validation, since _discover_peer returns first.
	var straggler_blob := {
		"v": CouchStarTransport.SIGNAL_PROTOCOL_VERSION, "gen": 0,
		"kind": CouchStarTransport.SIGNAL_KIND_ICE, "mid": "0", "index": 0,
		"candidate": "candidate:1 1 UDP 1 0.0.0.0 9 typ host", "inc": 1,
	}
	pair.host_signaling.replay(straggler_blob, pair.guest_id)
	await _step(pair.stars())
	_check(
		pair.host_star.net_id_for(pair.guest_id) == 0,
		"F4 (A3/finding 4): a raw signaling message from the tombstoned peer does NOT resurrect it -- net_id_for stays 0"
	)

	# A fresh peer_joined, by contrast, DOES clear the tombstone --
	# _on_signaling_peer_joined erases _failed[pid] UNCONDITIONALLY, before
	# _discover_peer runs, and only a fresh peer_joined does that.
	pair.host_signaling.announce(pair.guest_id)
	var rediscovered_predicate := func() -> bool: return pair.host_star.net_id_for(pair.guest_id) != 0
	var rediscovered := await _wait_until(
		pair.stars(), rediscovered_predicate,
		"F4 (A3/finding 4): a fresh peer_joined to clear the tombstone and rediscover the peer"
	)
	_check(
		rediscovered,
		"F4 (A3/finding 4): a fresh peer_joined DOES clear the tombstone -- net_id_for(guest) becomes nonzero again"
	)


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
# F6 -- an ESTABLISHED guest ignores a delayed, replayed LOWER-incarnation SDP
# (M19/M36) -- the critical finding this whole gate exists to prove closed, and
# C4's "established guest freezes" case: classify_incarnation's guest+
# established branch is DROP_STALE unconditionally, so this now proves the rule
# through `incarnation_for`, the field the rule actually operates on, not only
# through `generation_for` (which stays wire-visible but is no longer what
# decides anything).
# ============================================================================


func _run_f6_delayed_stale_generation(pair: _Pair) -> void:
	print("-- F6: an established guest ignores a delayed, replayed LOWER-incarnation SDP --")
	var established := await _drive_host_to_gen1(pair)
	_check(established, "F6: setup -- the pair reaches a live link at generation 1")
	if not established:
		return

	var gen0_offer: Variant = _find_captured(pair.host_signaling.captured, CouchStarTransport.SIGNAL_KIND_SDP, 0)
	_check(
		gen0_offer != null,
		"F6: setup -- a generation-0 SDP offer (the pair's FIRST, now-dead incarnation) was captured before the rebuild, to drop into replay"
	)
	if gen0_offer == null:
		return

	var inc_before := pair.guest_star.incarnation_for(pair.host_id)
	var restarts_before := pair.guest_star.handshake_restarts
	var lost_before := pair.guest_lost.size()
	var stale_before := pair.guest_star.stale_generation_drops

	pair.guest_signaling.replay(gen0_offer, pair.host_id)
	await _step(pair.stars())
	await _step(pair.stars())

	_check(
		pair.guest_star.incarnation_for(pair.host_id) == inc_before,
		"F6 (M19/M36, C4 \"established guest freezes\"): incarnation_for(host) is unchanged -- the established-guest branch of classify_incarnation drops the stale replay outright"
	)
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
# F6b -- the host, sole minter, never adopts a LOWER differing incarnation
# (M40). See F6c below for the HIGHER-incarnation half of the same rule.
# ============================================================================


func _run_f6b_host_never_adopts(pair: _Pair, donor: _Pair) -> void:
	print("-- F6b: the host never adopts a LOWER differing incarnation --")
	var established := await _drive_host_to_gen1(pair)
	_check(established, "F6b: setup -- the pair reaches a live link at generation 1")
	if not established:
		return

	# Borrowed from `donor`'s guest, which established cleanly at its FIRST (and
	# only) incarnation -- any real, cleanly-captured guest blob at generation 0
	# works (replay() re-emits it verbatim regardless of which pair originally
	# produced it). `donor` never rebuilt, so its incarnation is necessarily
	# LOWER than `pair`'s post-rebuild one.
	var lower_inc_guest_blob: Variant = _find_captured(donor.guest_signaling.captured, "", 0)
	_check(
		lower_inc_guest_blob != null,
		"F6b: setup -- a captured guest blob at a lower (never-rebuilt) incarnation is available to replay"
	)
	if lower_inc_guest_blob == null:
		return

	var inc_before := pair.host_star.incarnation_for(pair.guest_id)
	var stale_before := pair.host_star.stale_generation_drops

	pair.host_signaling.replay(lower_inc_guest_blob, pair.guest_id)
	await _step(pair.stars())
	await _step(pair.stars())

	_check(
		pair.host_star.incarnation_for(pair.guest_id) == inc_before,
		"F6b (M40): the host's incarnation for the guest is unchanged -- the sole minter never adopts a LOWER incarnation"
	)
	_check(
		pair.host_star.stale_generation_drops == stale_before + 1,
		"F6b (M40): stale_generation_drops on the host goes up by exactly 1"
	)


# ============================================================================
# F6c -- the host, sole minter, never follows a HIGHER differing incarnation
# either (M18/M40). F6b alone cannot catch a mutant that special-cases
# "DROP_STALE only when the incoming incarnation is lower, ADOPT when higher"
# -- F6b only ever replays a LOWER incarnation, so that mutant drops it
# correctly and F6b stays green. This case replays a HIGHER one, which is
# exactly the M18/M40 coverage hole the mutation pass found: the single
# production line under test is classify_incarnation's `if is_host: return
# DROP_STALE` (star_transport.gd), which must fire unconditionally on ANY
# mismatch, not only a lower one. If that line were mutated to compare
# magnitude and ADOPT on a higher incoming value, `_adopt_incarnation` would
# run: `_remote_desc_set.has(pid)` is true on this established link, so it
# would `_rebuild_connection` -- tearing down the live PC -- adopt the replayed
# label, bump `_handshake_restarts`, and never touch
# `_stale_generation_drops`. Every assertion below is chosen to catch exactly
# that: `incarnation_for` moving, `handshake_restarts` moving, and
# `stale_generation_drops` NOT moving would each independently go red, and the
# final frame-crossing check would then also time out since the torn-down PC
# has no fresh handshake driven through it.
# ============================================================================


func _run_f6c_host_never_follows_higher_incarnation(pair: _Pair) -> void:
	print("-- F6c: the host never follows a HIGHER incarnation than its own (M18/M40) --")
	var host_start: Dictionary = await pair.host_star.start()
	var guest_start: Dictionary = await pair.guest_star.start()
	_check(
		bool(host_start.get("success", false)) and bool(guest_start.get("success", false)),
		"F6c: setup -- both sides start()"
	)

	var ready_predicate := func() -> bool:
		return pair.host_ready.has(pair.guest_id) and pair.guest_ready.has(pair.host_id)
	var established := await _wait_until(pair.stars(), ready_predicate, "F6c: setup -- the pair to establish cleanly")
	_check(established, "F6c: setup -- the pair establishes cleanly at its first (only) incarnation")
	if not established:
		return

	# Any captured guest blob at the live (only) incarnation works -- kind
	# doesn't matter, since a DROP_STALE verdict returns before either
	# _handle_sdp or _handle_ice ever runs.
	var guest_blob: Variant = _find_captured(pair.guest_signaling.captured, "", 0)
	_check(
		guest_blob != null,
		"F6c: setup -- a captured guest blob at the live incarnation is available to mutate and replay"
	)
	if guest_blob == null:
		return

	var inc_before := pair.host_star.incarnation_for(pair.guest_id)
	var restarts_before := pair.host_star.handshake_restarts
	var stale_before := pair.host_star.stale_generation_drops
	var lost_before := pair.host_lost.size()

	var higher_blob: Dictionary = (guest_blob as Dictionary).duplicate(true)
	higher_blob["inc"] = inc_before + 1
	# JSON round-trip so `inc`/`gen` arrive as floats, exactly like a real blob
	# (see the file header's captured/replay note) -- this mutated blob was
	# never actually sent over `send()`, so it never got the treatment for free.
	var wire: Variant = JSON.parse_string(JSON.stringify(higher_blob))

	pair.host_signaling.replay(wire, pair.guest_id)
	await _step(pair.stars())
	await _step(pair.stars())

	_check(
		pair.host_star.incarnation_for(pair.guest_id) == inc_before,
		"F6c (M18/M40): incarnation_for is unchanged -- the sole minter never follows a HIGHER incarnation either"
	)
	_check(
		pair.host_star.handshake_restarts == restarts_before,
		"F6c (M18/M40): handshake_restarts is unchanged -- no rebuild happened"
	)
	_check(
		pair.host_star.stale_generation_drops == stale_before + 1,
		"F6c (M18/M40): stale_generation_drops goes up by exactly 1"
	)
	_check(
		pair.host_lost.size() == lost_before,
		"F6c (M18/M40): peer_lost never fired -- the established link was untouched"
	)

	var pre_frame_count := pair.host_received.size()
	pair.guest_star.send_to_authority(CouchEnvelope.make(CouchEnvelope.KIND_INTENT, 1, 960, {}))
	var frame_predicate := func() -> bool: return pair.host_received.size() > pre_frame_count
	var frame_crossed := await _wait_until(
		pair.stars(), frame_predicate, "F6c: a frame to still cross the live link after the higher-incarnation replay"
	)
	_check(frame_crossed, "F6c (M18/M40): a frame still crosses the live link after the higher-incarnation replay")


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
# F8 -- after a rejoin, a delayed straggler from the incarnation that JUST DIED
# may be followed TRANSIENTLY, but the guest CONVERGES on the host's live one
# rather than wedging (Codex finding 1's core ABA case). `_awaiting_rejoin_gen0`
# -- the barrier the OLD version of this case tested -- is deleted; there is no
# barrier any more BY DESIGN (star_transport.gd's header: "no barrier exists
# any more ... a guest follows whichever incarnation it last heard, bounded by
# MAX_INCARNATION_FOLLOWS. Being wrong is transient"). This case exercises
# exactly that trade: a stale replay from the dead incarnation, injected right
# after a rejoin, IS followed (ADOPT needs no ordering between labels) -- and
# the guarantee under test is that a SECOND, correcting ADOPT -- driven by the
# live host's own SDP_RETRANSMIT_INTERVAL_MS retransmit -- brings the guest
# back to the host's actual current incarnation and the link still establishes.
#
# HONESTY RISK, same family as the note this replaces: whether the guest's
# very FIRST post-rejoin contact is this stale replay or the host's own fresh
# offer (which can arrive within the same _step() that processes the rejoin)
# is real-engine timing, not scripted. It does not matter which arrives first:
# as long as the guest has not yet completed a real engine-level connect (a
# multi-frame process the rejoin-signal-processing wait below does not by
# itself complete), ADOPT has no ordering requirement, so replaying the DEAD
# incarnation's blob always knocks incarnation_for onto the dead value
# regardless of what arrived before it -- which is what makes the post-replay
# assertion below deterministic even though the timing preceding it is not.
# ============================================================================


func _run_f8_rejoin_convergence(pair: _Pair) -> void:
	print("-- F8: a stale straggler from a dead incarnation is followed TRANSIENTLY, but the guest converges on the live one --")
	var established := await _drive_host_to_gen1(pair)
	_check(established, "F8: setup -- the pair reaches a live link at generation 1")
	if not established:
		return

	# Snapshot BEFORE the rejoin, not .has(): both ids are already present in
	# these tap arrays from the FIRST establishment above, so a bare .has()
	# check is vacuously true from the very start -- it would let the
	# convergence wait below return the moment the incarnation LABELS match,
	# long before the engine-level link has actually come back up, which is
	# exactly what made the frame-crossing assertion after it time out.
	var host_ready_before := pair.host_ready.size()
	var guest_ready_before := pair.guest_ready.size()

	# Capture a blob from the incarnation that is ABOUT TO DIE, and its
	# incarnation number, before triggering the rejoin below.
	var dying_inc := pair.host_star.incarnation_for(pair.guest_id)
	var dying_inc_blob: Variant = _find_captured(pair.host_signaling.captured, CouchStarTransport.SIGNAL_KIND_SDP, 1)
	if dying_inc_blob == null:
		dying_inc_blob = _find_captured(pair.host_signaling.captured, CouchStarTransport.SIGNAL_KIND_ICE, 1)
	_check(dying_inc_blob != null, "F8: setup -- a captured blob from the about-to-die incarnation is available to replay")
	if dying_inc_blob == null:
		return

	# Mirrored rejoin, same technique as F7: both sides observe their own local
	# rejoin. The host mints a FRESH incarnation (necessarily different from
	# `dying_inc` -- epochs never repeat); the guest's local incarnation resets
	# to 0 via _teardown_peer.
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
		pair.stars(), rejoin_predicate, "F8: the guest to process the rejoin"
	)
	_check(rejoin_processed, "F8: setup -- the guest processes the rejoin")
	if not rejoin_processed:
		return

	# Inject the straggler from the DEAD incarnation. Whatever the guest's
	# incarnation currently is (0, if nothing has reached it yet; the host's
	# fresh one, if it already has -- see the honesty-risk note above), this
	# replay's incarnation is neither, so -- as long as the guest is not yet
	# established -- ADOPT fires unconditionally and knocks it onto the dead
	# value.
	pair.guest_signaling.replay(dying_inc_blob, pair.host_id)
	await _step(pair.stars())

	_check(
		pair.guest_star.incarnation_for(pair.host_id) == dying_inc,
		"F8: setup -- the guest is now pointed at the DEAD incarnation after transiently following the stale straggler"
	)

	# Let virtual time pass so the LIVE host's SDP_RETRANSMIT_INTERVAL_MS
	# retransmit of its CURRENT offer actually fires and reaches the guest --
	# see F21/F17's identical need for a nonzero step_dt_ms. Convergence means
	# BOTH the incarnation labels matching AND a FRESH peer_ready on each side
	# (size growth from the snapshot above) -- the engine-level link actually
	# coming back up, not merely the label catching up while the old,
	# now-dead-again PC from the stale replay is still mid-negotiation.
	var converged_predicate := func() -> bool:
		return (
			pair.guest_star.incarnation_for(pair.host_id) == pair.host_star.incarnation_for(pair.guest_id)
			and pair.host_ready.size() > host_ready_before
			and pair.guest_ready.size() > guest_ready_before
		)
	var converged := await _wait_until(
		pair.stars(), converged_predicate,
		"F8 (Codex finding 1): the guest to converge on the host's CURRENT incarnation and RE-establish, after transiently following the stale straggler",
		WAIT_TIMEOUT_MS, CouchStarTransport.SDP_RETRANSMIT_INTERVAL_MS
	)
	_check(
		converged,
		"F8 (Codex finding 1): being wrong once is transient, not permanent -- guest.incarnation_for(host) converges on "
			+ "host.incarnation_for(guest) and the link RE-establishes (a fresh peer_ready on both sides), rather than staying wedged pointing at the dead one"
	)

	var pre_frame_count := pair.host_received.size()
	pair.guest_star.send_to_authority(CouchEnvelope.make(CouchEnvelope.KIND_INTENT, 1, 956, {}))
	var frame_predicate := func() -> bool: return pair.host_received.size() > pre_frame_count
	var frame_crossed := await _wait_until(
		pair.stars(), frame_predicate, "F8: a frame to cross the converged link",
		WAIT_TIMEOUT_MS, CouchStarTransport.SDP_RETRANSMIT_INTERVAL_MS
	)
	_check(frame_crossed, "F8 (Codex finding 1): a frame crosses the link once the guest has converged")


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
	print("-- F10: close() during start()'s own await -- the fake now COMPLETES the join anyway (finding 6) --")
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
	# The fake's connect_room() now ALWAYS completes the join (finding 6 -- it
	# used to suppress this via `_close_epoch`, which made the transport's own
	# cleanup untestable, since there was never a real membership left behind
	# for it to release). So the join DOES land here, and what this asserts is
	# that the TRANSPORT is the one that cleans it back up: `star.close()`
	# above ran close() once immediately (before connect_room() even resumed),
	# and once start() notices it was superseded AND that connect_room()
	# reports success (which it now always does), `_abort_start(true)` runs a
	# SECOND close() -- that is the cleanup this case exists to prove, not the
	# fake refusing to join in the first place.
	_check(
		signaling.close_count == close_count_before + 2,
		"F10 (M47/finding 6): close() was invoked exactly TWICE -- the star's own close() plus _abort_start's -- now that the fake no longer suppresses the join on a superseded connect_room()"
	)
	_check(
		signaling.is_joined() == false,
		"F10 (M47/finding 6): the signaling ends UNJOINED -- proof that the TRANSPORT's own _abort_start(joined=true) released the membership the fake actually completed"
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
# F20 -- the guest's incarnation-follow budget exhausts, then drops the rest as
# stale (C4, third case; MAX_INCARNATION_FOLLOWS). A solo guest, no real host:
# ICE-kind replays (never SDP) are used deliberately -- an ICE blob with no
# remote description set is simply buffered by _handle_ice and never touches
# the real WebRTC engine's SDP parser, so the guest's own connection can never
# accidentally establish and this case stays cleanly scoped to the budget
# counters alone.
# ============================================================================


func _run_f20_follow_budget_exhausts() -> void:
	print("-- F20: the guest's incarnation-follow budget exhausts, then drops the rest as stale --")
	var host_id := "host20"
	var guest_signaling := CouchScriptedSignaling.new("g20")
	var host_player := {"user_id": host_id}
	var guest_player := {"user_id": "g20"}
	var guest_roster := _StarRoster.new(guest_player, host_player, false)
	var guest_star := CouchStarTransport.new(guest_signaling, guest_roster)

	var guest_start: Dictionary = await guest_star.start()
	_check(
		bool(guest_start.get("success", false)),
		"F20: setup -- the solo guest starts (builds a PC to the roster-named host; no real peer on the other end)"
	)

	# The FIRST distinct incarnation this guest ever hears is an INITIAL
	# adoption (local_inc == 0, i.e. `not _inc.has(pid)`) -- silent by design:
	# it sets the label but consumes no follow budget and fires no
	# handshake_restarts/transport_gap (adopting from nothing IS the
	# handshake, not a restart -- see star_transport.gd's _adopt_incarnation).
	# Every DISTINCT incarnation after that is a GENUINE follow, budgeted by
	# MAX_INCARNATION_FOLLOWS. So N distinct incarnations succeed as
	# 1 (free, initial) + MAX_INCARNATION_FOLLOWS (budgeted, genuine) before
	# the budget is spent and the rest DROP_STALE -- the naive
	# "N == MAX_INCARNATION_FOLLOWS" count this case originally asserted was
	# off by exactly the free initial adoption.
	var adopted := 0             # incarnation_for actually moved (initial OR genuine)
	var genuinely_followed := 0  # handshake_restarts moved too (genuine only)
	var dropped := 0
	var total_attempts := CouchStarTransport.MAX_INCARNATION_FOLLOWS + 3
	var expected_adopted := 1 + CouchStarTransport.MAX_INCARNATION_FOLLOWS
	for i in range(total_attempts):
		var blob := {
			"v": CouchStarTransport.SIGNAL_PROTOCOL_VERSION,
			"gen": 0,
			"kind": CouchStarTransport.SIGNAL_KIND_ICE,
			"mid": "0",
			"index": 0,
			"candidate": "candidate:1 1 UDP 1 0.0.0.0 9 typ host",
			"inc": i + 1,   # strictly distinct, strictly increasing, never 0 (never a valid wire incarnation)
		}
		var inc_before := guest_star.incarnation_for(host_id)
		var restarts_before := guest_star.handshake_restarts
		guest_signaling.replay(blob, host_id)
		if guest_star.incarnation_for(host_id) != inc_before:
			adopted += 1
			if guest_star.handshake_restarts > restarts_before:
				genuinely_followed += 1
		else:
			dropped += 1

	_check(
		adopted == expected_adopted,
		"F20: exactly %d distinct incarnations are ADOPTed -- 1 free initial + MAX_INCARNATION_FOLLOWS (%d) budgeted (got %d)"
			% [expected_adopted, CouchStarTransport.MAX_INCARNATION_FOLLOWS, adopted]
	)
	_check(
		genuinely_followed == CouchStarTransport.MAX_INCARNATION_FOLLOWS,
		"F20: exactly MAX_INCARNATION_FOLLOWS (%d) of those adoptions are GENUINE follows that actually consumed the budget -- the first is free (got %d)"
			% [CouchStarTransport.MAX_INCARNATION_FOLLOWS, genuinely_followed]
	)
	_check(
		dropped == total_attempts - expected_adopted,
		"F20: the incarnations past the budget are DROP_STALE, not allocating a connection each (got %d dropped, want %d)"
			% [dropped, total_attempts - expected_adopted]
	)
	_check(
		guest_star.stale_generation_drops == dropped,
		"F20: stale_generation_drops == the number of over-budget replays (%d)" % dropped
	)
	_check(
		guest_star.incarnation_for(host_id) == expected_adopted,
		"F20: incarnation_for(host) settles at the LAST successfully adopted incarnation (%d = 1 free + MAX_INCARNATION_FOLLOWS budgeted), never a later dropped one"
			% expected_adopted
	)


# ============================================================================
# F21 -- an ASYMMETRIC signaling reconnect (C5, Codex finding 1's second half).
# F7 mirrors the leave/rejoin announce onto the HOST's signaling too, which
# supplies the very synchronisation the implementation is supposed to provide
# on its own -- a real reconnect is not that tidy. This case drives each side's
# signaling independently: the host sees a genuine left+rejoin pair (so its own
# explicit rebuild path runs, exactly like F7), while the guest sees ONLY a
# re-join, with no preceding "left" at all -- modelling a guest whose OWN
# signaling session reset and simply re-reported the room's current members
# ("peer_joined" collapsing "already here" and "just arrived", per the
# adapter's documented contract), with nothing ever telling it the host went
# away.
#
# WHAT THIS ACTUALLY PROVES, confirmed by instrumenting the transport directly
# (that diagnostic build is not part of this file): the host's fresh,
# higher-incarnation offer and candidates reach the guest WHILE it is still
# established under the old incarnation, so the established-guest freeze rule
# (F6's rule) correctly DROPS them first -- `_on_signaling_peer_joined` on the
# guest's own side is a genuine no-op here (its `_departed` never held "host",
# and `_pcs` already has it), so it is NOT what recovers this link. What
# recovers it is the REAL WebRTCPeerConnection the host tears down as part of
# its own rebuild: over a real, connected link, that eventually surfaces as a
# real disconnect on the guest (`peer_lost` fires, `_connected` empties), which
# is what makes the guest "not established" -- and therefore free to ADOPT --
# by the time the host's NEXT retransmitted offer lands. So the case actually
# under test is: the guest correctly freezes while it believes the link is up,
# then follows the new incarnation once its engine link genuinely dies,
# recovering within one SDP_RETRANSMIT_INTERVAL_MS retransmit. That retransmit
# is background, virtual-time-gated behaviour -- exactly what `_wait_until`'s
# own docstring (see its `step_dt_ms` parameter, exercised already by F17)
# warns cannot fire under the default `step_dt_ms == 0`, which is why the
# waits below pass SDP_RETRANSMIT_INTERVAL_MS explicitly. This is real engine
# timing for the disconnect-detection half, not a scripted guarantee -- the
# same honesty-risk family as F3's and F7/F8's real-engine dependence.
# ============================================================================


func _run_f21_asymmetric_reconnect(pair: _Pair) -> void:
	print("-- F21: an ASYMMETRIC reconnect -- host sees left+rejoined, guest sees only re-joined --")
	var established := await _drive_host_to_gen1(pair)
	_check(established, "F21: setup -- the pair reaches a live link at generation 1")
	if not established:
		return

	var host_ready_before := pair.host_ready.size()
	var guest_ready_before := pair.guest_ready.size()

	# HOST's signaling: a genuine left/rejoin pair, same explicit path as F7.
	pair.host_signaling.announce_left(pair.guest_id)
	pair.host_signaling.announce(pair.guest_id)

	# GUEST's signaling: ONLY a re-join, deliberately NOT mirrored -- see the
	# section header's honesty-risk note on what actually recovers this link.
	pair.guest_signaling.announce(pair.host_id)

	# The guest's recovery depends on the host's SDP_RETRANSMIT_INTERVAL_MS
	# background retry actually firing (see the header) -- `step_dt_ms == 0`
	# (the default) never advances the virtual clock and this wait times out.
	var ready_again_predicate := func() -> bool:
		return pair.host_ready.size() > host_ready_before and pair.guest_ready.size() > guest_ready_before
	var both_ready_again := await _wait_until(
		pair.stars(), ready_again_predicate,
		"F21: both sides to reach peer_ready again once the guest's real engine-level disconnect is detected and the host's retransmit lands",
		WAIT_TIMEOUT_MS, CouchStarTransport.SDP_RETRANSMIT_INTERVAL_MS
	)
	_check(
		both_ready_again,
		"F21 (finding 1, asymmetric case): the guest correctly FREEZES on the host's fresh offer while it still believes the old link is up, "
			+ "then follows it once its engine-level link actually dies -- recovering within one retransmit rather than staying wedged forever"
	)

	var pre_frame_count := pair.host_received.size()
	pair.guest_star.send_to_authority(CouchEnvelope.make(CouchEnvelope.KIND_INTENT, 1, 970, {}))
	var frame_predicate := func() -> bool: return pair.host_received.size() > pre_frame_count
	var frame_crossed := await _wait_until(
		pair.stars(), frame_predicate, "F21: a frame to cross the re-established link",
		WAIT_TIMEOUT_MS, CouchStarTransport.SDP_RETRANSMIT_INTERVAL_MS
	)
	_check(frame_crossed, "F21: a frame crosses the link after the asymmetric reconnect")


# ============================================================================
# F23 -- a link that came UP and then DIED is rebuilt by the host, with backoff
# (Phase 2 re-establishment). The header's v1 limitation said peer_lost fires
# and that is all; this case is what turns the rebuild, its backoff, the
# stable-link reset and the exhaustion tombstone into assertions that can
# fail. Written BEFORE the rebuild existed: under Phase 1 every assertion past
# "both sides report peer_lost" is red.
#
# Deaths are injected with CouchStarTransport.fault_kill_link (debug-only,
# same gate as CouchLobbyTransport's levers): it closes the local
# WebRTCPeerConnection and touches nothing else, so the death reaches this
# file's bookkeeping through the engine's own peer_disconnected on the killing
# side and through a REAL remote closure on the other -- F23a kills on the
# guest so the host's rebuild is triggered by remote detection; every later
# death is killed on the host so its own detection is exercised too.
#
# Timing discipline is the virtual clock's: the rebuild deadline is armed at
# the poll that observes the death (dt 0, so `_virtual_now` is exactly where
# the wait left it), a step of delay-1 plus a few dt-0 holds proves nothing was
# issued early, and a step of 1 proves it is issued exactly at the deadline.
# "Issued" is observed two ways: link_rebuilds (the counter) and a fresh SDP
# blob in the host signaling's captured log (the wire).
#
# HONESTY RISK, same family as F21: remote death detection is real engine
# timing -- libdatachannel's close reaching the far side's connection state
# within WAIT_TIMEOUT_MS. Confirmed by running this gate; a slow machine shows
# up as a TIMEOUT on a peer_lost wait, never as a silent pass.
# ============================================================================


## Kill the live link from `killer`'s side, wait for BOTH sides to report the
## death, and return the host-side offer count at that moment. The rebuild
## deadline is armed inside the poll that observed the death, at the current
## virtual time.
func _f23_kill_and_wait_lost(pair: _Pair, kill_on_host: bool, label: String) -> bool:
	var host_lost_before := pair.host_lost.size()
	var guest_lost_before := pair.guest_lost.size()
	var killed: bool
	if kill_on_host:
		killed = pair.host_star.fault_kill_link(pair.guest_id)
	else:
		killed = pair.guest_star.fault_kill_link(pair.host_id)
	_check(killed, "%s: fault_kill_link on the %s returns true (a live link was killed)" % [label, "host" if kill_on_host else "guest"])
	var lost_predicate := func() -> bool:
		return pair.host_lost.size() > host_lost_before and pair.guest_lost.size() > guest_lost_before
	var both_lost := await _wait_until(pair.stars(), lost_predicate, "%s: both sides to report peer_lost" % label)
	_check(both_lost, "%s: both sides report peer_lost for the dead link" % label)
	return both_lost


## Prove the host issues exactly one rebuild for `pair` at `delay_ms` after the
## death it just observed -- none before, one at the deadline, a fresh offer on
## the wire -- then wait for the rebuilt link to come up on both sides.
func _f23_expect_rebuild_after(pair: _Pair, delay_ms: int, label: String) -> void:
	var rebuilds_before := pair.host_star.link_rebuilds
	var offers_before := _count_captured(pair.host_signaling.captured, CouchStarTransport.SIGNAL_KIND_SDP)
	var host_ready_before := pair.host_ready.size()
	var guest_ready_before := pair.guest_ready.size()
	var gaps_before := pair.host_gaps.size()

	await _step(pair.stars(), delay_ms - 1)
	for i in range(3):
		await _step(pair.stars())
	_check(
		pair.host_star.link_rebuilds == rebuilds_before
			and _count_captured(pair.host_signaling.captured, CouchStarTransport.SIGNAL_KIND_SDP) == offers_before,
		"%s: nothing is issued %d ms after the death (one short of the %d ms deadline): link_rebuilds and the offer count are unchanged"
			% [label, delay_ms - 1, delay_ms]
	)
	await _step(pair.stars(), 1)
	_check(
		pair.host_star.link_rebuilds == rebuilds_before + 1,
		"%s: link_rebuilds goes up by exactly 1 at the %d ms deadline" % [label, delay_ms]
	)
	var rebuild_gap := false
	for g in pair.host_gaps.slice(gaps_before):
		if g["peer_id"] == pair.guest_id and g["reason"] == "link-rebuild":
			rebuild_gap = true
	_check(rebuild_gap, "%s: the host fires transport_gap(guest, \"link-rebuild\") when the rebuild is issued" % label)

	var offer_predicate := func() -> bool:
		return _count_captured(pair.host_signaling.captured, CouchStarTransport.SIGNAL_KIND_SDP) > offers_before
	var offered := await _wait_until(pair.stars(), offer_predicate, "%s: a fresh offer to leave the host" % label)
	_check(offered, "%s: a fresh SDP offer leaves the host after the rebuild is issued" % label)

	var ready_predicate := func() -> bool:
		return pair.host_ready.size() > host_ready_before and pair.guest_ready.size() > guest_ready_before
	var ready_again := await _wait_until(pair.stars(), ready_predicate, "%s: the rebuilt link to come up on both sides" % label)
	_check(ready_again, "%s: peer_ready fires again on both sides once the rebuilt link establishes" % label)


func _run_f23_link_rebuild(pair: _Pair) -> void:
	print("-- F23: a link that came up and then died is rebuilt by the host, with backoff --")
	var host_start: Dictionary = await pair.host_star.start()
	var guest_start: Dictionary = await pair.guest_star.start()
	_check(
		bool(host_start.get("success", false)) and bool(guest_start.get("success", false)),
		"F23: setup -- both sides start()"
	)
	var established := await _wait_until(
		pair.stars(),
		func() -> bool: return pair.host_ready.has(pair.guest_id) and pair.guest_ready.has(pair.host_id),
		"F23: setup -- the clean link to establish"
	)
	_check(established, "F23: setup -- the pair reaches a live link")
	if not established:
		return

	# --- F23a: the GUEST's side dies; the host notices remotely and rebuilds ---
	# after REBUILD_BACKOFF_BASE_MS under a NEW incarnation.
	var inc_before := pair.host_star.incarnation_for(pair.guest_id)
	if not await _f23_kill_and_wait_lost(pair, false, "F23a"):
		return
	_check(
		pair.host_star.incarnation_for(pair.guest_id) == inc_before,
		"F23a: the death itself mints nothing -- the host's incarnation for the guest is unchanged until the rebuild"
	)
	await _f23_expect_rebuild_after(pair, CouchStarTransport.REBUILD_BACKOFF_BASE_MS, "F23a")
	_check(
		pair.host_star.incarnation_for(pair.guest_id) != inc_before
			and pair.guest_star.incarnation_for(pair.host_id) == pair.host_star.incarnation_for(pair.guest_id),
		"F23a: the rebuilt link runs under a NEW incarnation that both ends agree on"
	)
	var host_reconnected := false
	for g in pair.host_gaps:
		if g["peer_id"] == pair.guest_id and g["reason"] == "peer-reconnected":
			host_reconnected = true
	var guest_reconnected := false
	for g in pair.guest_gaps:
		if g["peer_id"] == pair.host_id and g["reason"] == "peer-reconnected":
			guest_reconnected = true
	_check(
		host_reconnected and guest_reconnected,
		"F23a: both sides fire transport_gap(peer, \"peer-reconnected\") -- the rebuild is reported as a reconnect, not a first connect"
	)
	_check(
		pair.guest_star.handshake_restarts == 1,
		"F23a: the guest counts exactly one handshake-restart -- it ADOPTED the rebuild offer over its dead description (got %d)"
			% pair.guest_star.handshake_restarts
	)
	var pre_frame := pair.host_received.size()
	pair.guest_star.send_to_authority(CouchEnvelope.make(CouchEnvelope.KIND_INTENT, 1, 2301, {}))
	var frame_crossed := await _wait_until(
		pair.stars(), func() -> bool: return pair.host_received.size() > pre_frame, "F23a: a frame to cross the rebuilt link"
	)
	_check(frame_crossed, "F23a: a frame crosses the rebuilt link")

	# --- F23b: a second death right away doubles the delay. ---
	if not await _f23_kill_and_wait_lost(pair, true, "F23b"):
		return
	await _f23_expect_rebuild_after(pair, CouchStarTransport.REBUILD_BACKOFF_BASE_MS * 2, "F23b")

	# --- F23c: a link that stayed up for REBUILD_STABLE_MS starts over at BASE. ---
	await _step(pair.stars(), CouchStarTransport.REBUILD_STABLE_MS)
	_check(
		pair.host_star.link_rebuilds == 2 and pair.host_lost.size() == 2,
		"F23c: REBUILD_STABLE_MS of virtual time on a live link issues nothing and loses nothing"
	)
	if not await _f23_kill_and_wait_lost(pair, true, "F23c"):
		return
	await _f23_expect_rebuild_after(pair, CouchStarTransport.REBUILD_BACKOFF_BASE_MS, "F23c")

	# --- F23d: flapping -- consecutive deaths climb to the cap, then exhaust. ---
	# After F23c's reset the sequence is BASE (spent), 2*BASE, 4*BASE, then the
	# cap; the death after MAX_LINK_REBUILDS consecutive rebuilds is terminal.
	var delays: Array = []
	for level in range(1, CouchStarTransport.MAX_LINK_REBUILDS):
		delays.append(mini(CouchStarTransport.REBUILD_BACKOFF_BASE_MS << level, CouchStarTransport.REBUILD_BACKOFF_MAX_MS))
	_check(
		delays[delays.size() - 1] == CouchStarTransport.REBUILD_BACKOFF_MAX_MS,
		"F23d: setup -- the constants make the cap observable (the last consecutive delay is REBUILD_BACKOFF_MAX_MS: %s)" % [delays]
	)
	for i in range(delays.size()):
		var label := "F23d.%d" % (i + 1)
		if not await _f23_kill_and_wait_lost(pair, true, label):
			return
		await _f23_expect_rebuild_after(pair, int(delays[i]), label)

	var failures_before := pair.host_star.connect_failures
	var rebuilds_at_exhaustion := pair.host_star.link_rebuilds
	var offers_at_exhaustion := _count_captured(pair.host_signaling.captured, CouchStarTransport.SIGNAL_KIND_SDP)
	if not await _f23_kill_and_wait_lost(pair, true, "F23d.exhaust"):
		return
	await _step(pair.stars())
	_check(
		pair.host_star.connect_failures == failures_before + 1,
		"F23d: the death after MAX_LINK_REBUILDS consecutive rebuilds is terminal -- connect_failures goes up by exactly 1"
	)
	var exhausted_gap := false
	for g in pair.host_gaps:
		if g["peer_id"] == pair.guest_id and g["reason"] == "rebuild-exhausted":
			exhausted_gap = true
	_check(exhausted_gap, "F23d: transport_gap(guest, \"rebuild-exhausted\") fired")
	_check(
		pair.host_star.net_id_for(pair.guest_id) == 0 and pair.host_star.generation_for(pair.guest_id) == -1,
		"F23d: the exhausted peer is torn down completely -- net id released, generation -1"
	)
	await _step(pair.stars(), CouchStarTransport.REBUILD_BACKOFF_MAX_MS * 4)
	for i in range(3):
		await _step(pair.stars())
	_check(
		pair.host_star.link_rebuilds == rebuilds_at_exhaustion
			and _count_captured(pair.host_signaling.captured, CouchStarTransport.SIGNAL_KIND_SDP) == offers_at_exhaustion,
		"F23d: no rebuild is ever issued for the tombstoned peer, however much time passes"
	)

	# Only a fresh peer_joined revives it -- the same tombstone rule F4 proves
	# for a terminal connect failure.
	var host_ready_before := pair.host_ready.size()
	var guest_ready_before := pair.guest_ready.size()
	pair.host_signaling.announce(pair.guest_id)
	var revived := await _wait_until(
		pair.stars(),
		func() -> bool: return pair.host_ready.size() > host_ready_before and pair.guest_ready.size() > guest_ready_before,
		"F23d: a fresh peer_joined to clear the tombstone and re-establish"
	)
	_check(revived, "F23d: a fresh peer_joined clears the tombstone and the link comes back on both sides")

	# --- F23e: a peer signaling reported GONE while its link was still up is ---
	# not rebuilt when that link then dies -- only a fresh peer_joined
	# re-authorises, and that path rebuilds on its own. This is the order a
	# guest's close() produces (its signaling close lands before the engine
	# notices the dead link), made deterministic.
	pair.host_signaling.announce_left(pair.guest_id)
	await _step(pair.stars())
	_check(
		pair.host_star.connected_peer_ids().has(pair.guest_id),
		"F23e: setup -- peer_left with the link up keeps the link (an established link outlives room presence)"
	)
	var rebuilds_before_departed := pair.host_star.link_rebuilds
	if not await _f23_kill_and_wait_lost(pair, true, "F23e"):
		return
	await _step(pair.stars(), CouchStarTransport.REBUILD_BACKOFF_MAX_MS * 4)
	for i in range(3):
		await _step(pair.stars())
	_check(
		pair.host_star.link_rebuilds == rebuilds_before_departed,
		"F23e: the death of a link whose peer already LEFT signaling schedules no rebuild, however much time passes"
	)
	host_ready_before = pair.host_ready.size()
	guest_ready_before = pair.guest_ready.size()
	pair.host_signaling.announce(pair.guest_id)
	var rejoined := await _wait_until(
		pair.stars(),
		func() -> bool: return pair.host_ready.size() > host_ready_before and pair.guest_ready.size() > guest_ready_before,
		"F23e: the rejoin to rebuild the link"
	)
	_check(rejoined, "F23e: the peer's rejoin (peer_joined) rebuilds the link on both sides, through the rejoin path and not the backoff")
	_check(
		pair.host_star.link_rebuilds == rebuilds_before_departed,
		"F23e: link_rebuilds is still unchanged -- the rejoin path is not counted as a backoff rebuild"
	)


# ============================================================================
# F22 -- strict numeric field validation is observable (C7, finding 5). Each
# case supplies a VALID value for every field EXCEPT the one under test (same
# discipline as run_star_unit.gd's default-field checks), so a mutated
# _wire_int call on any ONE field is independently observable and cannot hide
# behind another field's defect. Reuses the MAIN pair -- orthogonal to
# generation/incarnation state, same rationale as F14/F15/F16.
# ============================================================================


func _run_f22_field_validation(pair: _Pair) -> void:
	print("-- F22: strict numeric field validation is observable through rejected_count --")
	var valid_inc := pair.guest_star.incarnation_for(pair.host_id)

	var cases := [
		{
			"label": "\"v\": \"1\" (a numeric STRING, not an int/float)",
			"blob": {
				"v": "1", "gen": 0, "kind": CouchStarTransport.SIGNAL_KIND_SDP,
				"sdp_type": "offer", "sdp": "irrelevant-rejected-before-parsing", "inc": valid_inc,
			},
		},
		{
			"label": "gen: 1.9 (fractional -- used to alias generation 1 via a bare int())",
			"blob": {
				"v": CouchStarTransport.SIGNAL_PROTOCOL_VERSION, "gen": 1.9, "kind": CouchStarTransport.SIGNAL_KIND_SDP,
				"sdp_type": "offer", "sdp": "irrelevant-rejected-before-parsing", "inc": valid_inc,
			},
		},
		{
			"label": "inc: 0 (never a valid wire incarnation)",
			"blob": {
				"v": CouchStarTransport.SIGNAL_PROTOCOL_VERSION, "gen": 0, "kind": CouchStarTransport.SIGNAL_KIND_SDP,
				"sdp_type": "offer", "sdp": "irrelevant-rejected-before-parsing", "inc": 0,
			},
		},
		{
			"label": "index: 3.5 (fractional -- only reachable past a VALID v/gen/inc, since index is ICE-only)",
			"blob": {
				"v": CouchStarTransport.SIGNAL_PROTOCOL_VERSION, "gen": 0, "kind": CouchStarTransport.SIGNAL_KIND_ICE,
				"mid": "0", "index": 3.5, "candidate": "candidate:1 1 UDP 1 0.0.0.0 9 typ host", "inc": valid_inc,
			},
		},
	]

	for c in cases:
		var label: String = c["label"]
		var blob: Dictionary = c["blob"]
		# JSON round-trip so the malformed value arrives exactly as a real one
		# would (see the file header's JSON-round-trip note) -- most load-bearing
		# for the fractional cases, which are already floats in GDScript but
		# should still cross the wire honestly rather than being assumed.
		var wire: Variant = JSON.parse_string(JSON.stringify(blob))

		var rejected_before := pair.guest_star.rejected_count
		var inc_before := pair.guest_star.incarnation_for(pair.host_id)
		var gen_before := pair.guest_star.generation_for(pair.host_id)
		var ready_before := pair.guest_star.is_ready()

		pair.guest_signaling.replay(wire, pair.host_id)
		await _step(pair.stars())

		_check(
			pair.guest_star.rejected_count == rejected_before + 1,
			"F22 (finding 5): %s is rejected -- rejected_count goes up by exactly 1" % label
		)
		_check(
			pair.guest_star.incarnation_for(pair.host_id) == inc_before,
			"F22 (finding 5): %s does not move incarnation_for" % label
		)
		_check(
			pair.guest_star.generation_for(pair.host_id) == gen_before,
			"F22 (finding 5): %s does not move generation_for" % label
		)
		_check(
			pair.guest_star.is_ready() == ready_before,
			"F22 (finding 5): %s does not disturb is_ready() (a proxy for _connected)" % label
		)


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

	var p6c := _Pair.new("host6c", "g6c")
	await _run_f6c_host_never_follows_higher_incarnation(p6c)

	var p7 := _Pair.new("host7", "g7")
	await _run_f7_rejoin(p7)

	var p8 := _Pair.new("host8", "g8")
	await _run_f8_rejoin_convergence(p8)

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

	await _run_f20_follow_budget_exhausts()

	var p21 := _Pair.new("host21", "g21")
	await _run_f21_asymmetric_reconnect(p21)

	await _run_f22_field_validation(main)

	var p23 := _Pair.new("host23", "g23")
	await _run_f23_link_rebuild(p23)

	print("")
	print("total assertions: %d failed" % failures)
	if failures == 0:
		print("COUCH_STAR_FAULTS_OK")
	else:
		printerr("COUCH_STAR_FAULTS_FAILED: %d check(s)" % failures)
	quit(failures)
	return
