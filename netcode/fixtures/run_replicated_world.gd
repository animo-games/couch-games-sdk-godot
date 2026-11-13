## Headless gate for the replicated world, event ring and event inbox -- gate G15.
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_replicated_world.gd
##
## What this proves. CouchReplicatedWorld packs the host's entities (id, kind, packed
## float state) into one full-world snapshot body together with the 0c clock fields and
## per-peer event sections, and on the client ingests those bodies, interpolates /
## extrapolates per channel at a render time and reports spawn / despawn at RENDER time.
## CouchEventRing (host) keeps per-peer monotone event streams until the peer acks them
## through its input; CouchEventInbox (client) yields every event exactly once. The gate
## tests the frozen API CONTRACT (docs/plans/replicated-world-0d-design.md, final section),
## not any implementation: it is written test-first against inert stubs.
##
## Cases:
##   W0  register_kind validation; layout_hash equals an independently computed FNV-1a
##       (hand-coded here + a pinned literal), is order-independent, and sees a
##       same-stride channel swap.
##   W1  pack: key presence rules (x / ev / rt,hm,mg), ascending ids, exact states, copies
##       not aliases, acks/extra not mutated, ring.expire called once per pack; the body
##       survives BOTH real codecs (JSON frame and binary) bit-exact and ingests.
##   W1b host entity API: set_entity / remove_entity / has_entity validation, replace with
##       another kind, state persistence between packs.
##   W2  every ingest rejection reason, in contract ORDER (two-defect bodies: the
##       first-listed reason wins), distinct reasons, a rejected body changes no state.
##   W2b a same-stride channel-swapped layout on the host is rejected as layout-mismatch;
##       a different registration order is not.
##   W3  stale / duplicate / out-of-order snapshots ignored and counted (no signal, no state
##       change), newest wins, peer_section follows the newest accepted snapshot.
##   W4  interpolation: LERP / ANGLE (short arc across +/-PI, wrapped) / SNAP against the
##       contract formulas at non-tick-aligned render times; render never runs backwards.
##   W4b history eviction: history_size alone (history_ticks 0), the default tick window,
##       and history_size as a floor under sparse snapshots; then hold-oldest.
##   W4c the default history brackets render times down to CouchNetClockPolicy's
##       render_delay_max_ticks behind the newest, at snapshots every 1, 2 and 3 ticks.
##   W5  extrapolation formula, the cap, hold beyond it, once-per-call counters, resume.
##   W6  spawn/despawn signals at render time: ordering rules, skipped lives, no re-fire
##       when render goes backwards, kind change, reappearing id is a new life.
##   W6b late snapshots (spawn/despawn tick already behind render time) still fire their signal
##       exactly once on the next sample() call, with despawn-before-spawn ordering; on-time
##       spawns do not double fire.
##   W7  local ids: omitted from sample and its signals, available through latest/state_at.
##   X   extra(): newest accepted snapshot's x as a copy, {} when absent, cleared by reset.
##   H   aliasing / edge holes: pack x and ingest pl are copies, latest/state_at return copies,
##       ANGLE extrapolation takes the short arc at a fractional k, a missing ack reads -1.
##   E1  event ring: monotone per-peer ids, ack pruning, stale / over-ack, expiry boundary,
##       overflow, forget keeps the next id, reset restarts at 1, pending_for is a copy.
##   E2  event inbox: exactly once, in order, under duplicates / reorder / redelivery; gap
##       and lost counting; malformed counting; reset.
##   S1  end to end: host + 3 clients over lossy, jittery, reordering links, a real
##       CouchFixedTicker / CouchNetClock / CouchNetClockEcho / world / ring / inbox. Events
##       exactly once or counted lost, no cross-peer events, render never backwards,
##       post-warmup held_frames == 0, extrapolation bounded, a constant-velocity entity
##       tracks truth, spawn/despawn lives consistent.
##   S1b render-delay sweep 2..8: a REPORT (held / extrapolated per delay and the smallest
##       delay with post-warmup held_frames == 0). Only sanity checks, no threshold.
##   S1c S1 with one client cut off for 3.5 s: events expire host-side, the inbox reports
##       the gap, and the accounting still closes.
##   S1d S1 with the adaptive render delay from a floor of 3 ticks: held 0, extrapolated
##       <= 1% (S1-S1c pin the fixed mode).
##   S2  new epoch: reset() on world / ring / inbox / clock then a clean rebuild; no stale
##       event re-applied, ids restart at 1, old lives gone, lower ticks accepted again.
##
## HARNESS (`_WSim`). Entirely synchronous and deterministic: fixed seeds, no WebRTC, no
## await, no real clock, nothing reads Time. One host (CouchFixedTicker 60 Hz,
## CouchNetClockEcho, CouchEventRing, a world; a snapshot every 2 ticks) and three clients
## (CouchNetClock, world, inbox), each with its own seeded one-way delay (50 +/- 30 ms),
## loss and a client clock = host clock + a large per-peer OFFSET. Messages are delivered in
## ARRIVAL-time order so jitter reorders them. Host and clients run their own frame loops
## (16 +/- 4 ms) on different phases. Snapshots travel through the REAL CouchEnvelope codecs
## (client 0 over the JSON frame, the others binary). Clients feed their clocks from
## peer_section exactly as the contract's "Game wiring" paragraph says, and carry
## inbox.last_applied() back in every input as "ev" (host: ring.ack).
##
## Every assertion is on an OBSERVED EFFECT (returned values, recorded signals in the order
## they fired, counters, decoded wire bodies). Absence checks are always conjoined with a
## presence guard (snapshots accepted, samples produced, events delivered) so an inert
## implementation cannot pass them vacuously.
##
## LOAD-BEARING GOTCHA: SceneTree.quit(code) only SCHEDULES termination; it does not
## return. `return` follows the one quit(...) in this file.
extends SceneTree

const LERP := CouchReplicatedWorld.LERP
const ANGLE := CouchReplicatedWorld.ANGLE
const SNAP := CouchReplicatedWorld.SNAP
const FAR := 1 << 60
const OFFSET_MS := 987_654
const INT_MAX := 2147483647

var failures := 0
var _rej_expected := 0
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


# --- recording / small helpers -------------------------------------------------------------


## Records world signals in the order they fire.
class _Rec extends RefCounted:
	var log: Array = []

	func _init(w: CouchReplicatedWorld) -> void:
		w.entity_spawned.connect(_on_spawn)
		w.entity_despawned.connect(_on_despawn)
		w.rejected.connect(_on_reject)

	func _on_spawn(id: int, kind: int) -> void:
		log.append("S:%d:%d" % [id, kind])

	func _on_despawn(id: int) -> void:
		log.append("D:%d" % id)

	func _on_reject(reason: String) -> void:
		log.append("R:" + reason)

	func take() -> Array:
		var out := log.duplicate()
		log.clear()
		return out


## A ring that counts expire() calls.
class _CountingRing extends CouchEventRing:
	var expire_calls := 0
	var last_expire_tick := -1

	func expire(host_tick: int) -> void:
		expire_calls += 1
		last_expire_tick = host_tick
		super.expire(host_tick)


func _fnv(seq: Array) -> int:
	var h := 2166136261
	for v in seq:
		h = ((h ^ (int(v) & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
	return h


func _pf(values: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for v in values:
		out.append(float(v))
	return out


func _near(a: Variant, b: Array, tol: float = 0.0001) -> bool:
	if not (a is PackedFloat32Array):
		return false
	var pa: PackedFloat32Array = a
	if pa.size() != b.size():
		return false
	for i in b.size():
		if absf(pa[i] - float(b[i])) > tol:
			return false
	return true


func _sorted_keys(d: Dictionary) -> Array:
	var k := d.keys()
	k.sort()
	return k


func _ids(events: Array) -> Array:
	var out: Array = []
	for e in events:
		out.append(e[0])
	return out


## World with kinds 1 [L,L], 2 [L,ANGLE,SNAP], 5 [L,L,ANGLE,L,L,L]; order 1 registers in reverse.
func _new_world(order: int = 0) -> CouchReplicatedWorld:
	var w := CouchReplicatedWorld.new()
	var defs := [
		[1, [LERP, LERP]],
		[2, [LERP, ANGLE, SNAP]],
		[5, [LERP, LERP, ANGLE, LERP, LERP, LERP]],
	]
	if order == 1:
		defs.reverse()
	for d in defs:
		w.register_kind(int(d[0]), d[1])
	return w


## A snapshot body built by hand (independent of pack): ents = [[id, kind, [state...]], ...].
func _body(w: CouchReplicatedWorld, ht: int, ents: Array, pl: Dictionary = {}) -> Dictionary:
	var ids := PackedInt32Array()
	var kinds := PackedInt32Array()
	var st := PackedFloat32Array()
	for e in ents:
		ids.append(int(e[0]))
		kinds.append(int(e[1]))
		for v in e[2]:
			st.append(float(v))
	return {"ht": ht, "lh": w.layout_hash(), "ids": ids, "kinds": kinds, "st": st, "pl": pl}


## Fingerprint of the client state a rejected / stale body must not change.
func _fp(w: CouchReplicatedWorld) -> Array:
	return [w.newest_tick(), w.stale_count, w.latest(1), w.latest(2), w.peer_section("a")]


func _psize(v: Variant) -> int:
	return (v as PackedFloat32Array).size() if v is PackedFloat32Array else -1


func _wrap(v: float) -> float:
	return wrapf(v, -PI, PI)


# --- W0 ---------------------------------------------------------------------------------------


func _case_w0() -> void:
	print("W0: register_kind and layout_hash")
	var w := CouchReplicatedWorld.new()
	var empty_hash := w.layout_hash()
	var ok := [
		w.register_kind(5, [LERP, LERP, ANGLE, LERP, LERP, LERP]),
		w.register_kind(1, [LERP, LERP]),
		w.register_kind(2, [LERP, ANGLE, SNAP]),
	]
	_check(
		empty_hash == 2166136261 and ok == [true, true, true],
		"W0: empty registry hashes to the FNV offset basis 2166136261 and three valid registrations return true"
	)
	var before := w.layout_hash()
	var bad := [
		w.register_kind(1, [SNAP]),
		w.register_kind(-1, [LERP]),
		w.register_kind(1 << 31, [LERP]),
		w.register_kind(9, []),
		w.register_kind(9, [3]),
		w.register_kind(9, [-1]),
		w.register_kind(9, ["a"]),
		w.register_kind(9, [LERP, 7]),
	]
	_check(
		ok == [true, true, true] and bad == [false, false, false, false, false, false, false, false] and w.layout_hash() == before,
		"W0: duplicate kind, out-of-range kinds, empty channels and bad channel values all return false and register nothing (got %s)" % str(bad)
	)
	var after_bad := w.register_kind(9, [LERP])
	_check(
		after_bad and w.layout_hash() == _fnv([1, 2, 0, 0, 2, 3, 0, 1, 2, 5, 6, 0, 0, 1, 0, 0, 0, 9, 1, 0]),
		"W0: a failed registration of kind 9 left nothing behind: a later valid kind 9 registers and is hashed"
	)
	var w2 := _new_world(0)
	var expected := _fnv([1, 2, 0, 0, 2, 3, 0, 1, 2, 5, 6, 0, 0, 1, 0, 0, 0])
	_check(
		w2.layout_hash() == expected and expected == 584617582,
		"W0: layout_hash == independent FNV-1a (%d) == pinned literal 584617582, got %d" % [expected, w2.layout_hash()]
	)
	var w3 := _new_world(1)
	_check(
		w3.layout_hash() == expected and w2.layout_hash() == expected,
		"W0: registration order does not change the hash (reverse order gave %d)" % w3.layout_hash()
	)
	var swapped := CouchReplicatedWorld.new()
	swapped.register_kind(1, [LERP, LERP])
	swapped.register_kind(2, [LERP, SNAP, ANGLE])
	swapped.register_kind(5, [LERP, LERP, ANGLE, LERP, LERP, LERP])
	var swapped_expected := _fnv([1, 2, 0, 0, 2, 3, 0, 2, 1, 5, 6, 0, 0, 1, 0, 0, 0])
	_check(
		swapped.layout_hash() == swapped_expected and swapped_expected != expected,
		"W0: swapping two channels of kind 2 (same stride) changes the hash to %d" % swapped_expected
	)
	var edge := CouchReplicatedWorld.new()
	var edge_ok := [edge.register_kind(INT_MAX, [SNAP, SNAP]), edge.register_kind(0, [LERP, ANGLE])]
	_check(
		edge_ok == [true, true] and edge.layout_hash() == _fnv([0, 2, 0, 1, INT_MAX, 2, 2, 2]),
		"W0: kinds 0 and 2^31-1 are valid and hashed in ascending kind order"
	)


# --- W1 ---------------------------------------------------------------------------------------


func _case_w1() -> void:
	print("W1: pack, key presence, copies, codecs")
	var h := _new_world(0)
	var s10 := _pf([0.1, 1.5, -2.25])
	var s3 := _pf([7.5, 8.25])
	var s7 := _pf([0.1, 0.2, 0.3, 0.4, 0.5, 0.6])
	var set_ok := [h.set_entity(10, 2, s10), h.set_entity(3, 1, s3), h.set_entity(7, 5, s7)]
	var ring := CouchEventRing.new()
	var pushed := [ring.push("p1", 4, {"hp": 3}, 50), ring.push("p1", 9, "s", 51), ring.push("p2", 4, 5, 50)]
	var echo := CouchNetClockEcho.new()
	echo.note_input("p1", 10, 8, 1000)
	var acks := {"p1": 33, "p2": 40, "p3": 1}
	var extra := {"score": 5, "names": ["a", "b"]}
	var acks_before := acks.duplicate(true)
	var extra_before := extra.duplicate(true)
	var body := h.pack(60, 1250, acks, echo, ring, extra)
	_check(
		set_ok == [true, true, true] and pushed == [1, 2, 1] and _sorted_keys(body) == ["ht", "ids", "kinds", "lh", "pl", "st", "x"],
		"W1: pack with echo + ring + extra returns exactly the keys ht, lh, ids, kinds, st, pl, x (got %s)" % str(_sorted_keys(body))
	)
	var expected_st := PackedFloat32Array()
	expected_st.append_array(s3)
	expected_st.append_array(s7)
	expected_st.append_array(s10)
	_check(
		body.get("ht") == 60 and body.get("lh") == h.layout_hash() and h.layout_hash() == 584617582,
		"W1: ht is the host tick and lh is the registry's layout hash"
	)
	_check(
		typeof(body.get("ids")) == TYPE_PACKED_INT32_ARRAY and body.get("ids") == PackedInt32Array([3, 7, 10])
		and typeof(body.get("kinds")) == TYPE_PACKED_INT32_ARRAY and body.get("kinds") == PackedInt32Array([1, 5, 2]),
		"W1: ids ascending (3, 7, 10) as PackedInt32Array with kinds in the same order"
	)
	_check(
		typeof(body.get("st")) == TYPE_PACKED_FLOAT32_ARRAY and body.get("st") == expected_st,
		"W1: st is the exact concatenation of the states in id order (%d floats)" % expected_st.size()
	)
	var pl: Dictionary = body.get("pl", {})
	_check(
		_sorted_keys(pl) == ["p1", "p2", "p3"]
		and pl.get("p1") == {"ack": 33, "rt": 10, "hm": 250, "mg": 2, "ev": [[1, 4, {"hp": 3}], [2, 9, "s"]]},
		"W1: p1 section = ack + echo mapped to rt/hm/mg (10, 250, 2) + its pending events (got %s)" % str(pl.get("p1"))
	)
	_check(
		pl.get("p2") == {"ack": 40, "ev": [[1, 4, 5]]} and pl.get("p3") == {"ack": 1, "ev": []},
		"W1: a peer the echo has not heard has no rt/hm/mg; a peer with no events still has ev == []"
	)
	_check(
		body.get("x") == extra_before and acks == acks_before and extra == extra_before,
		"W1: x passes the extra through and pack does not mutate acks or extra"
	)
	var bare := h.pack(61, 1250, acks)
	var bare_pl: Dictionary = bare.get("pl", {})
	_check(
		_sorted_keys(bare) == ["ht", "ids", "kinds", "lh", "pl", "st"] and bare_pl.get("p1") == {"ack": 33}
		and bare_pl.get("p2") == {"ack": 40} and _sorted_keys(bare_pl) == ["p1", "p2", "p3"],
		"W1: with no extra there is no x; with no echo and no ring each section is just {ack}"
	)
	var echo_only := h.pack(62, 1250, acks, echo)
	var no_ring_pl: Dictionary = echo_only.get("pl", {})
	_check(
		no_ring_pl.get("p1") == {"ack": 33, "rt": 10, "hm": 250, "mg": 2} and no_ring_pl.get("p2") == {"ack": 40},
		"W1: echo without ring gives rt/hm/mg for the known peer only and no ev key anywhere"
	)
	var ring_only := h.pack(63, 1250, acks, null, ring)
	var ring_pl: Dictionary = ring_only.get("pl", {})
	_check(
		ring_pl.get("p1") == {"ack": 33, "ev": [[1, 4, {"hp": 3}], [2, 9, "s"]]} and ring_pl.get("p3") == {"ack": 1, "ev": []},
		"W1: ring without echo gives ev (always present) and no rt/hm/mg"
	)
	# Copies, not aliases.
	var snap1 := h.pack(64, 1250, acks)
	var ids1: PackedInt32Array = snap1.get("ids", PackedInt32Array())
	var kinds1: PackedInt32Array = snap1.get("kinds", PackedInt32Array())
	var st1: PackedFloat32Array = snap1.get("st", PackedFloat32Array())
	if ids1.size() > 0 and kinds1.size() > 0 and st1.size() > 0:
		ids1[0] = 99
		kinds1[0] = 99
		st1[0] = 99.0
	s3[0] = -1.0
	s7[5] = -1.0
	var snap2 := h.pack(65, 1250, acks)
	_check(
		snap1.get("ids") != null and snap2.get("ids") == PackedInt32Array([3, 7, 10]) and snap2.get("kinds") == PackedInt32Array([1, 5, 2])
		and snap2.get("st") == expected_st,
		"W1: mutating a returned body or the arrays passed to set_entity does not change what the next pack returns"
	)
	# ring.expire is called once per pack, only with a ring.
	var cring := _CountingRing.new()
	cring.max_age_ticks = 10
	cring.push("p1", 1, "old", 0)
	h.pack(5, 0, acks)
	var calls_without := cring.expire_calls
	var expired_body := h.pack(11, 0, {"p1": 1}, null, cring)
	var expired_pl: Dictionary = expired_body.get("pl", {})
	_check(
		calls_without == 0 and cring.expire_calls == 1 and cring.last_expire_tick == 11
		and cring.expired_count("p1") == 1 and expired_pl.get("p1") == {"ack": 1, "ev": []},
		"W1: pack calls ring.expire(host_tick) exactly once (and not without a ring); the event aged out BEFORE the section was built"
	)
	# Codecs.
	var envelope := CouchEnvelope.make(CouchEnvelope.KIND_SNAPSHOT, 7, 1, body)
	var dec_json := CouchEnvelope.from_json_frame(CouchEnvelope.to_json_frame(envelope))
	var dec_bin := CouchEnvelope.from_bytes(CouchEnvelope.to_bytes(envelope))
	for pair in [["json", dec_json], ["binary", dec_bin]]:
		var label: String = pair[0]
		var dec: Dictionary = pair[1]
		var wire_body: Dictionary = dec.get("envelope", {}).get("body", {})
		var c := _new_world(1)
		var accepted := c.ingest(wire_body)
		var l3 := c.latest(3)
		var l7 := c.latest(7)
		var l10 := c.latest(10)
		_check(
			dec.get("error") == "" and accepted and c.newest_tick() == 60 and wire_body.get("x") == extra_before,
			"W1/%s: the packed body decodes through the real codec, ingests, and x survives the wire" % label
		)
		_check(
			accepted and c.extra() == extra_before and not c.extra().is_empty(),
			"W1/%s: extra() returns the snapshot's x after the wire round trip" % label
		)
		_check(
			l3.get("tick") == 60 and l3.get("state") == _pf([7.5, 8.25]) and l7.get("state") == _pf([0.1, 0.2, 0.3, 0.4, 0.5, 0.6])
			and l10.get("state") == s10 and c.state_at(10, 60) == s10 and c.state_at(10, 59).is_empty(),
			"W1/%s: ids, kinds and states arrive bit-exact (latest/state_at read back every entity)" % label
		)
		_check(
			c.peer_section("p1") == {"ht": 60, "ack": 33, "ev": [[1, 4, {"hp": 3}], [2, 9, "s"]], "rt": 10, "hm": 250, "mg": 2}
			and c.peer_section("p2") == {"ht": 60, "ack": 40, "ev": [[1, 4, 5]]}
			and c.peer_section("p3") == {"ht": 60, "ack": 1, "ev": []} and c.peer_section("zz") == {},
			"W1/%s: peer_section returns each peer's own section (with rt/hm/mg only where present) and {} for an unknown peer" % label
		)


# --- W1b --------------------------------------------------------------------------------------


func _case_w1b() -> void:
	print("W1b: host entity API")
	var h := _new_world(0)
	var rejected := [
		h.set_entity(1, 99, _pf([1, 2])),
		h.set_entity(1, 1, _pf([1])),
		h.set_entity(1, 1, _pf([1, 2, 3])),
		h.set_entity(-1, 1, _pf([1, 2])),
		h.set_entity(1 << 31, 1, _pf([1, 2])),
	]
	var pre := h.pack(1, 0, {})
	var edge := [h.set_entity(0, 1, _pf([0, 0])), h.set_entity(INT_MAX, 1, _pf([9, 9]))]
	var post := h.pack(2, 0, {})
	_check(
		rejected == [false, false, false, false, false] and pre.get("ids") == PackedInt32Array()
		and edge == [true, true] and h.has_entity(0) and h.has_entity(INT_MAX) and not h.has_entity(1)
		and post.get("ids") == PackedInt32Array([0, INT_MAX]),
		"W1b: unregistered kind, wrong state size and out-of-range ids return false and add nothing; ids 0 and 2^31-1 are valid"
	)
	_check(
		h.set_entity(5, 1, _pf([1, 2])) and h.remove_entity(5) and not h.has_entity(5) and not h.remove_entity(5)
		and not h.remove_entity(12345) and h.has_entity(0),
		"W1b: remove_entity returns true once then false; absent ids return false"
	)
	h.set_entity(8, 1, _pf([1, 2]))
	var replaced := h.set_entity(8, 2, _pf([4, 5, 6]))
	var b1 := h.pack(3, 0, {})
	var b2 := h.pack(4, 0, {})
	var ids: PackedInt32Array = b1.get("ids", PackedInt32Array())
	var idx := ids.find(8)
	var kinds: PackedInt32Array = b1.get("kinds", PackedInt32Array())
	_check(
		replaced and idx >= 0 and kinds[idx] == 2 and b1.get("st") == b2.get("st") and b1.get("ids") == b2.get("ids")
		and _psize(b1.get("st")) == 2 + 2 + 3,
		"W1b: re-setting an id with another kind replaces it, and state persists unchanged between packs"
	)


# --- W2 ---------------------------------------------------------------------------------------


func _expect_reject(c: CouchReplicatedWorld, rec: _Rec, body: Variant, reason: String, label: String) -> void:
	_rej_expected += 1
	var before := c.rejected_count
	var fp := _fp(c)
	var stale_before := c.stale_count
	rec.take()
	var res := c.ingest(body)
	var events := rec.take()
	_check(
		res == false and c.last_reject_reason == reason and c.rejected_count == before + 1 and events == ["R:" + reason]
		and _fp(c) == fp and c.stale_count == stale_before,
		"W2: %s -> %s (false, counted once, one signal, state unchanged; got reason '%s', signals %s)" % [label, reason, c.last_reject_reason, str(events)]
	)


func _case_w2() -> void:
	print("W2: ingest rejections in contract order")
	var c := _new_world(1)
	var rec := _Rec.new(c)
	var fresh_reason := c.last_reject_reason
	var first := c.ingest(_body(c, 5, [[1, 1, [1, 2]], [2, 2, [1, 2, 3]]], {"a": {"ack": 1}}))
	_check(
		first and c.newest_tick() == 5 and fresh_reason == "" and c.rejected_count == 0 and c.latest(2).get("tick") == 5,
		"W2: (setup) a valid body is accepted; last_reject_reason is empty before any rejection"
	)

	var mk := func(ht: int = 9) -> Dictionary:
		return _body(c, ht, [[1, 1, [1, 2]], [2, 2, [1, 2, 3]]], {"a": {"ack": 1}})

	# 1. bad-shape
	_expect_reject(c, rec, 5, "bad-shape", "body is an int")
	_expect_reject(c, rec, null, "bad-shape", "body is null")
	_expect_reject(c, rec, [1, 2], "bad-shape", "body is an Array")
	_expect_reject(c, rec, "snapshot", "bad-shape", "body is a String")
	var b: Dictionary = mk.call()
	b.erase("ht")
	_expect_reject(c, rec, b, "bad-shape", "ht missing")
	b = mk.call()
	b["ht"] = 9.0
	_expect_reject(c, rec, b, "bad-shape", "ht is a float")
	b = mk.call()
	b["ht"] = "9"
	_expect_reject(c, rec, b, "bad-shape", "ht is a String")
	b = mk.call()
	b.erase("lh")
	_expect_reject(c, rec, b, "bad-shape", "lh missing")
	b = mk.call()
	b["lh"] = float(c.layout_hash())
	_expect_reject(c, rec, b, "bad-shape", "lh is a float")
	b = mk.call()
	b.erase("ids")
	_expect_reject(c, rec, b, "bad-shape", "ids missing")
	b = mk.call()
	b["ids"] = [1, 2]
	_expect_reject(c, rec, b, "bad-shape", "ids is a plain Array")
	b = mk.call()
	b["ids"] = PackedInt64Array([1, 2])
	_expect_reject(c, rec, b, "bad-shape", "ids is a PackedInt64Array")
	b = mk.call()
	b.erase("kinds")
	_expect_reject(c, rec, b, "bad-shape", "kinds missing")
	b = mk.call()
	b["kinds"] = PackedInt64Array([1, 2])
	_expect_reject(c, rec, b, "bad-shape", "kinds is a PackedInt64Array")
	b = mk.call()
	b["kinds"] = [1, 2]
	_expect_reject(c, rec, b, "bad-shape", "kinds is a plain Array")
	b = mk.call()
	b.erase("st")
	_expect_reject(c, rec, b, "bad-shape", "st missing")
	b = mk.call()
	b["st"] = PackedFloat64Array([1, 2, 1, 2, 3])
	_expect_reject(c, rec, b, "bad-shape", "st is a PackedFloat64Array")
	b = mk.call()
	b["st"] = [1.0, 2.0, 1.0, 2.0, 3.0]
	_expect_reject(c, rec, b, "bad-shape", "st is a plain Array")
	b = mk.call()
	b.erase("pl")
	_expect_reject(c, rec, b, "bad-shape", "pl missing")
	b = mk.call()
	b["pl"] = []
	_expect_reject(c, rec, b, "bad-shape", "pl is an Array")
	b = mk.call()
	b["x"] = [1]
	_expect_reject(c, rec, b, "bad-shape", "x present but an Array")
	b = mk.call()
	b["x"] = 5
	_expect_reject(c, rec, b, "bad-shape", "x present but an int")
	b = mk.call()
	b.erase("pl")
	b["lh"] = int(b["lh"]) + 1
	_expect_reject(c, rec, b, "bad-shape", "pl missing AND lh wrong (shape is checked first)")

	# 2. layout-mismatch
	b = mk.call()
	b["lh"] = int(b["lh"]) + 1
	_expect_reject(c, rec, b, "layout-mismatch", "lh differs")
	b = mk.call()
	b["lh"] = 0
	b["kinds"] = PackedInt32Array([1])
	_expect_reject(c, rec, b, "layout-mismatch", "lh wrong AND ids/kinds sizes differ (layout first)")

	# 3. size-mismatch
	b = mk.call()
	b["kinds"] = PackedInt32Array([1])
	_expect_reject(c, rec, b, "size-mismatch", "kinds shorter than ids")
	b = mk.call()
	b["ids"] = PackedInt32Array([1, 2, 3])
	_expect_reject(c, rec, b, "size-mismatch", "ids longer than kinds")
	b = mk.call()
	b["ids"] = PackedInt32Array([1, 1, 2])
	b["kinds"] = PackedInt32Array([1, 99])
	b["st"] = PackedFloat32Array()
	_expect_reject(c, rec, b, "size-mismatch", "size mismatch AND unknown kind AND duplicate id AND bad st (size first)")

	# 4. unknown-kind
	b = mk.call()
	b["kinds"] = PackedInt32Array([1, 99])
	_expect_reject(c, rec, b, "unknown-kind", "kind 99 is not registered")
	b = mk.call()
	b["kinds"] = PackedInt32Array([1, -1])
	_expect_reject(c, rec, b, "unknown-kind", "kind -1 is not registered")
	b = mk.call()
	b["kinds"] = PackedInt32Array([99, 1])
	b["ids"] = PackedInt32Array([4, 4])
	b["st"] = PackedFloat32Array()
	_expect_reject(c, rec, b, "unknown-kind", "unknown kind AND duplicate id AND bad st (unknown-kind first)")

	# 5. duplicate-id
	b = mk.call()
	b["ids"] = PackedInt32Array([1, 1])
	_expect_reject(c, rec, b, "duplicate-id", "id 1 repeated")
	b = mk.call()
	b["ids"] = PackedInt32Array([2, 2])
	b["st"] = PackedFloat32Array([1.0])
	b["pl"] = {"a": 5}
	_expect_reject(c, rec, b, "duplicate-id", "duplicate id AND bad st length AND bad section (duplicate first)")

	# 6. bad-state-length
	b = mk.call()
	b["st"] = PackedFloat32Array([1, 2, 1, 2, 3, 4])
	_expect_reject(c, rec, b, "bad-state-length", "st one float too long")
	b = mk.call()
	b["st"] = PackedFloat32Array([1, 2, 1, 2])
	_expect_reject(c, rec, b, "bad-state-length", "st one float too short")
	b = mk.call()
	b["st"] = PackedFloat32Array()
	_expect_reject(c, rec, b, "bad-state-length", "st empty while entities listed")
	b = mk.call()
	b["st"] = PackedFloat32Array([1, 2, 1, 2])
	b["pl"] = {"a": {"ack": 1.5}}
	_expect_reject(c, rec, b, "bad-state-length", "bad st length AND bad section (state length first)")

	# 7. bad-peer-section
	var bad_sections := [
		[{5: {}}, "pl key is an int"],
		[{"a": 5}, "section is an int"],
		[{"a": {"ack": 1.5}}, "ack is a float"],
		[{"a": {"rt": "3"}}, "rt is a String"],
		[{"a": {"hm": 1.0}}, "hm is a float"],
		[{"a": {"mg": "x"}}, "mg is a String"],
		[{"a": {"ev": {}}}, "ev is a Dictionary"],
		[{"a": {"ack": 1}, "b": null}, "second section is null"],
	]
	for entry in bad_sections:
		b = mk.call()
		b["pl"] = entry[0]
		_expect_reject(c, rec, b, "bad-peer-section", str(entry[1]))

	# A defective body that is ALSO stale is rejected, not counted stale.
	b = mk.call(5)
	b["kinds"] = PackedInt32Array([1, 99])
	_expect_reject(c, rec, b, "unknown-kind", "defective body at ht == newest (rejected, not stale)")

	_check(
		c.rejected_count == _rej_expected and _rej_expected > 40 and c.stale_count == 0 and first,
		"W2: every defect was counted exactly once (rejected_count %d, stale_count %d)" % [c.rejected_count, c.stale_count]
	)
	rec.take()
	var good := c.ingest(mk.call(6))
	_check(
		good and c.newest_tick() == 6 and rec.take() == [] and c.latest(1).get("tick") == 6 and c.peer_section("a").get("ack") == 1,
		"W2: after all the rejections a valid body is still accepted normally"
	)


func _case_w2b() -> void:
	print("W2b: channel-swapped layout")
	var c := _new_world(1)
	var rec := _Rec.new(c)
	var good_host := _new_world(0)
	good_host.set_entity(2, 2, _pf([1, 2, 3]))
	var swapped_host := CouchReplicatedWorld.new()
	swapped_host.register_kind(1, [LERP, LERP])
	swapped_host.register_kind(2, [LERP, SNAP, ANGLE])
	swapped_host.register_kind(5, [LERP, LERP, ANGLE, LERP, LERP, LERP])
	swapped_host.set_entity(2, 2, _pf([1, 2, 3]))
	var ok_body := good_host.pack(20, 0, {})
	var swapped_body := swapped_host.pack(21, 0, {})
	var ok_res := c.ingest(ok_body)
	rec.take()
	var res := c.ingest(swapped_body)
	_check(
		ok_res and c.newest_tick() == 20 and _psize(ok_body.get("st")) == _psize(swapped_body.get("st")) and _psize(ok_body.get("st")) == 3
		and ok_body.get("lh") != swapped_body.get("lh") and res == false and c.last_reject_reason == "layout-mismatch"
		and rec.take() == ["R:layout-mismatch"] and c.newest_tick() == 20,
		"W2b: same stride, swapped channels on the host -> layout-mismatch (state unchanged); a differently-ordered but equal registry was accepted first"
	)


# --- W3 ---------------------------------------------------------------------------------------


func _case_w3() -> void:
	print("W3: stale / duplicate / out of order")
	var c := _new_world(0)
	var rec := _Rec.new(c)
	var r1 := c.ingest(_body(c, 10, [[1, 1, [1, 1]]], {"a": {"ack": 10}}))
	var r2 := c.ingest(_body(c, 12, [[1, 1, [3, 3]]], {"a": {"ack": 12}}))
	_check(
		r1 and r2 and c.newest_tick() == 12 and c.stale_count == 0 and c.latest(1) == {"tick": 12, "state": _pf([3, 3])},
		"W3: (setup) ticks 10 and 12 accepted, newest is 12"
	)
	rec.take()
	var dup := c.ingest(_body(c, 12, [[1, 1, [9, 9]]], {"a": {"ack": 99}}))
	_check(
		dup == false and c.stale_count == 1 and c.rejected_count == 0 and rec.take() == [] and c.newest_tick() == 12
		and c.latest(1) == {"tick": 12, "state": _pf([3, 3])} and c.peer_section("a").get("ack") == 12,
		"W3: a duplicate tick (different content) is ignored: stale_count 1, no rejection, no signal, state unchanged"
	)
	var older := c.ingest(_body(c, 11, [[1, 1, [8, 8]]]))
	var oldest := c.ingest(_body(c, 10, [[1, 1, [7, 7]]]))
	_check(
		older == false and oldest == false and c.stale_count == 3 and c.state_at(1, 11).is_empty()
		and c.state_at(1, 10) == _pf([1, 1]) and c.latest(1).get("tick") == 12,
		"W3: older ticks 11 and 10 are stale (count 3) and their content is not applied; the real tick-10 sample is untouched"
	)
	var r14 := c.ingest(_body(c, 14, [[1, 1, [5, 5]]], {"a": {"ack": 14}}))
	var late13 := c.ingest(_body(c, 13, [[1, 1, [6, 6]]], {"a": {"ack": 13}}))
	_check(
		r14 and late13 == false and c.stale_count == 4 and c.newest_tick() == 14 and c.state_at(1, 13).is_empty()
		and c.state_at(1, 14) == _pf([5, 5]) and c.peer_section("a").get("ack") == 14 and rec.take() == [],
		"W3: 14 then a late 13: newest wins, 13 is stale (count 4), peer_section follows the newest accepted snapshot"
	)
	var f := _new_world(0)
	var neg := f.ingest(_body(f, -5, [[1, 1, [1, 1]]]))
	var neg_newest := f.newest_tick()
	var zero := f.ingest(_body(f, 0, [[1, 1, [1, 1]]]))
	_check(
		neg == false and f.stale_count == 1 and neg_newest == -1 and zero and f.newest_tick() == 0,
		"W3: on a fresh world ht -5 is stale (newest stays -1) and ht 0 is accepted as the first snapshot"
	)


# --- W4 / W4b ---------------------------------------------------------------------------------


## Contract interpolation between two samples (va at tick a, vb at tick b) at render r.
func _interp(kind: int, va: float, vb: float, a: int, b: int, r: int) -> float:
	var alpha := float(r - a * 1000) / float((b - a) * 1000)
	match kind:
		LERP:
			return va + (vb - va) * alpha
		ANGLE:
			return _wrap(va + _wrap(vb - va) * alpha)
		_:
			return va if r < b * 1000 else vb
	return 0.0


func _case_w4() -> void:
	print("W4: interpolation")
	var c := _new_world(0)
	var rec := _Rec.new(c)
	var samples := [[10, [0.0, 3.0, 1.0]], [12, [10.0, -2.8, 2.0]], [16, [30.0, 3.0, 5.0]]]
	var accepted := true
	for s in samples:
		accepted = c.ingest(_body(c, int(s[0]), [[1, 2, s[1]]])) and accepted
	_check(accepted and c.newest_tick() == 16, "W4: (setup) three snapshots (ticks 10, 12, 16) accepted")
	var times := [10333, 11000, 11500, 11777, 11999, 12000, 13000, 14000, 15999, 16000]
	var all_ok := true
	var in_range := true
	var last_result := {}
	for r in times:
		var seg := 0 if r <= 12000 else 1
		var a: int = samples[seg][0]
		var b: int = samples[seg + 1][0]
		var va: Array = samples[seg][1]
		var vb: Array = samples[seg + 1][1]
		var expected: Array = []
		for ch in 3:
			expected.append(_interp([LERP, ANGLE, SNAP][ch], va[ch], vb[ch], a, b, int(r)))
		var res := c.sample(int(r))
		last_result = res
		var got: Variant = res.get(1)
		var ok := _near(got, expected, 0.0001)
		all_ok = all_ok and ok
		if got is PackedFloat32Array:
			in_range = in_range and (got as PackedFloat32Array)[1] >= -PI - 0.0001 and (got as PackedFloat32Array)[1] < PI + 0.0001
		_check(ok, "W4: sample(%d) = [LERP %.4f, ANGLE %.4f, SNAP %.1f] (got %s)" % [r, expected[0], expected[1], expected[2], str(got)])
	var mid := _new_world(0)
	mid.ingest(_body(mid, 10, [[1, 2, [0.0, 3.0, 1.0]]]))
	mid.ingest(_body(mid, 12, [[1, 2, [10.0, -2.8, 2.0]]]))
	var mid_s := mid.sample(11000)
	_check(
		mid_s.has(1) and mid_s[1][0] == 5.0,
		"W4: LERP midpoint of 0 and 10 is exactly 5.0 (got %s)" % str(mid_s.get(1))
	)
	_check(all_ok and in_range, "W4: every ANGLE result lies in [-PI, PI] (the short arc across +/-PI was taken and the result wrapped)")
	rec.take()
	var back := c.sample(11000)
	_check(
		back.has(1) and last_result.has(1) and back[1] == last_result[1] and rec.take() == [],
		"W4: sample() with an earlier render time reuses the previous one (same values as at 16000, no signals)"
	)


func _case_w4b() -> void:
	print("W4b: history eviction")
	var c := _new_world(0)
	c.history_size = 3
	c.history_ticks = 0   # count only
	var rec := _Rec.new(c)
	for t in range(1, 7):
		c.ingest(_body(c, t, [[1, 1, [t * 10, -t * 10]]]))
	var s1 := c.sample(2500)
	_check(
		c.newest_tick() == 6 and _near(s1.get(1), [40, -40]) and rec.take() == ["S:1:1"],
		"W4b: history_size 3 with history_ticks 0 keeps ticks 4..6; render time 2500 (before the oldest kept) holds the oldest sample [40, -40] (got %s)" % str(s1.get(1))
	)
	var s2 := c.sample(4500)
	_check(
		_near(s2.get(1), [45, -45]) and c.state_at(1, 3).is_empty() and c.state_at(1, 4) == _pf([40, -40])
		and c.latest(1).get("tick") == 6,
		"W4b: interpolation resumes inside the kept window (4500 -> [45, -45]); tick 3 was evicted, tick 4 kept"
	)
	var d := _new_world(0)
	for t in range(1, 61):
		d.ingest(_body(d, t, [[1, 1, [t, t]]]))
	_check(
		d.history_size == 8 and d.history_ticks == 34 and d.state_at(1, 26) == _pf([26, 26])
		and d.state_at(1, 25).is_empty() and d.state_at(1, 60) == _pf([60, 60]),
		"W4b: the defaults (history_size 8, history_ticks 34) keep of ticks 1..60 exactly 26..60: back to newest - 34"
	)
	var e := _new_world(0)
	for t in range(10, 201, 10):
		e.ingest(_body(e, t, [[1, 1, [t, t]]]))
	_check(
		e.state_at(1, 130) == _pf([130, 130]) and e.state_at(1, 120).is_empty(),
		"W4b: snapshots 10 ticks apart: history_size still keeps 8 samples (130..200) though 34 ticks need only 5"
	)


func _case_w4c() -> void:
	print("W4c: the default history brackets render times down to the adaptive delay's cap")
	var cap := CouchNetClockPolicy.new().render_delay_max_ticks
	var keep := CouchReplicatedWorld.new().history_ticks
	_check(
		keep >= cap + 2,
		"W4c: history_ticks %d covers render_delay_max_ticks %d plus at least one 2-tick snapshot interval" % [keep, cap]
	)
	for every in [1, 2, 3]:
		var c := _new_world(0)
		for t in range(every, 121, every):
			c.ingest(_body(c, t, [[1, 1, [t, -t]]]))
		var newest := c.newest_tick()
		var r := (newest - cap) * 1000 - 500
		var s := c.sample(r)
		var x := float(r) / 1000.0
		_check(
			_near(s.get(1), [x, -x]),
			"W4c: snapshots every %d ticks, render time newest - %d.5 ticks interpolates to [%.1f, %.1f] (got %s)" % [every, cap, x, -x, str(s.get(1))]
		)


# --- W5 ---------------------------------------------------------------------------------------


func _case_w5() -> void:
	print("W5: extrapolation, cap, hold")
	var c := _new_world(0)
	var empty := c.sample(5000)
	c.ingest(_body(c, 10, [[1, 2, [0, 0.0, 5]], [2, 1, [0, 0]]]))
	c.ingest(_body(c, 12, [[1, 2, [4, 0.2, 7]], [2, 1, [8, 8]]]))
	_check(
		empty == {} and c.newest_tick() == 12 and c.extrapolated_frames == 0 and c.held_frames == 0,
		"W5: (setup) sample() before any snapshot returns {} and counts nothing; two snapshots then accepted"
	)
	var inside := c.sample(11000)
	var at_newest := c.sample(12000)
	_check(
		_near(inside.get(1), [2, 0.1, 5]) and _near(at_newest.get(1), [4, 0.2, 7]) and c.extrapolated_frames == 0 and c.held_frames == 0,
		"W5: inside and exactly at the newest sample nothing is extrapolated or held"
	)
	var steps := [
		[13000, [6, 0.3, 7], 1, 0],
		[13000, [6, 0.3, 7], 2, 0],
		[14500, [9, 0.45, 7], 3, 0],
		[18000, [16, 0.8, 7], 4, 0],
		[18001, [16, 0.8, 7], 4, 1],
		[25000, [16, 0.8, 7], 4, 2],
	]
	for s in steps:
		var res := c.sample(int(s[0]))
		_check(
			_near(res.get(1), s[1]) and res.has(2) and c.extrapolated_frames == int(s[2]) and c.held_frames == int(s[3]),
			"W5: sample(%d) -> %s with extrapolated_frames %d, held_frames %d (got %s, %d, %d)" % [s[0], str(s[1]), s[2], s[3], str(res.get(1)), c.extrapolated_frames, c.held_frames]
		)
	c.ingest(_body(c, 20, [[1, 2, [10, 0.5, 9]], [2, 1, [1, 1]]]))
	c.ingest(_body(c, 30, [[1, 2, [40, 0.9, 9]], [2, 1, [2, 2]]]))
	var resumed := c.sample(25000)
	_check(
		_near(resumed.get(1), [25, 0.7, 9]) and c.extrapolated_frames == 4 and c.held_frames == 2,
		"W5: when newer snapshots arrive the entity interpolates again (25000 between ticks 20 and 30 -> 25) and the counters stop (got %s)" % str(resumed.get(1))
	)
	# A smaller cap.
	var k := _new_world(0)
	k.extrapolate_cap_ticks = 2
	k.ingest(_body(k, 10, [[1, 1, [0, 0]]]))
	k.ingest(_body(k, 12, [[1, 1, [4, 2]]]))
	var at_cap := k.sample(14000)
	var past_cap := k.sample(15000)
	_check(
		_near(at_cap.get(1), [8, 4]) and _near(past_cap.get(1), [8, 4]) and k.extrapolated_frames == 1 and k.held_frames == 1,
		"W5: extrapolate_cap_ticks = 2: 14000 extrapolates to [8, 4], 15000 holds there (got %s)" % str(past_cap.get(1))
	)
	# Single sample: hold, but still an extrapolation frame.
	var one := _new_world(0)
	one.ingest(_body(one, 5, [[1, 1, [3, 4]]]))
	var held_one := one.sample(6000)
	_check(
		_near(held_one.get(1), [3, 4]) and one.extrapolated_frames == 1 and one.held_frames == 0,
		"W5: past the only sample the values hold ([3, 4]) while the frame counts as extrapolated"
	)
	# ANGLE extrapolation wraps and takes the short arc.
	var ang := _new_world(0)
	ang.ingest(_body(ang, 1, [[1, 2, [0, 2.9, 0]]]))
	ang.ingest(_body(ang, 2, [[1, 2, [0, 3.1, 0]]]))
	var a1 := ang.sample(3000)
	var arc := _new_world(0)
	arc.ingest(_body(arc, 1, [[1, 2, [0, 3.0, 0]]]))
	arc.ingest(_body(arc, 2, [[1, 2, [0, -3.1, 0]]]))
	var a2 := arc.sample(3000)
	var e1 := _wrap(3.1 + _wrap(3.1 - 2.9) * 1.0)
	var e2 := _wrap(-3.1 + _wrap(-3.1 - 3.0) * 1.0)
	_check(
		a1.has(1) and a2.has(1) and absf(a1[1][1] - e1) < 0.0001 and absf(a2[1][1] - e2) < 0.0001 and e1 < 0.0 and e2 > -3.1,
		"W5: ANGLE extrapolation wraps to [-PI, PI) (3.1 + 0.2 -> %.4f) and uses the short arc across +/-PI (-3.1 -> %.4f)" % [e1, e2]
	)


# --- W6 ---------------------------------------------------------------------------------------


func _case_w6() -> void:
	print("W6: spawn / despawn at render time")
	var c := _new_world(0)
	var rec := _Rec.new(c)
	var accepted := [
		c.ingest(_body(c, 10, [[1, 1, [10, 0]], [2, 1, [20, 0]]])),
		c.ingest(_body(c, 12, [[1, 1, [11, 0]], [2, 1, [22, 0]], [3, 1, [30, 0]]])),
		c.ingest(_body(c, 14, [[1, 1, [12, 0]], [3, 1, [32, 0]]])),
		c.ingest(_body(c, 16, [[1, 1, [13, 0]], [2, 1, [99, 0]], [3, 1, [34, 0]]])),
	]
	_check(
		accepted == [true, true, true, true] and c.newest_tick() == 16 and rec.take() == [],
		"W6: ingesting snapshots up to tick 16 fires NO spawn/despawn signal (they wait for render time)"
	)
	var seq := [
		[9500, [], []],
		[10000, ["S:1:1", "S:2:1"], [1, 2]],
		[11999, [], [1, 2]],
		[12000, ["S:3:1"], [1, 2, 3]],
		[13999, [], [1, 2, 3]],
		[14000, ["D:2"], [1, 3]],
		[15000, [], [1, 3]],
		[16000, ["S:2:1"], [1, 2, 3]],
		[16500, [], [1, 2, 3]],
	]
	for s in seq:
		var res := c.sample(int(s[0]))
		var log := rec.take()
		_check(
			c.newest_tick() == 16 and log == s[1] and _sorted_keys(res) == s[2],
			"W6: sample(%d) fires %s and returns ids %s (got %s, %s)" % [s[0], str(s[1]), str(s[2]), str(log), str(_sorted_keys(res))]
		)
	var at_16500 := c.sample(16500)
	_check(
		_near(at_16500.get(2), [99, 0]),
		"W6: the reappeared id 2 is a NEW life: its value is its own sample [99, 0], never interpolated from the old life (got %s)" % str(at_16500.get(2))
	)
	var back := c.sample(11000)
	_check(
		rec.take() == [] and _sorted_keys(back) == [1, 2, 3] and _near(back.get(2), [99, 0]),
		"W6: render going backwards fires nothing again and the previous render time is reused"
	)
	# Despawn before spawn at an equal tick, even when the spawning id is lower.
	var t := _new_world(0)
	var trec := _Rec.new(t)
	t.ingest(_body(t, 18, [[9, 1, [1, 1]]]))
	t.ingest(_body(t, 20, [[4, 1, [2, 2]]]))
	t.ingest(_body(t, 22, []))
	t.sample(18000)
	var first := trec.take()
	t.sample(20000)
	var second := trec.take()
	var third_res := t.sample(22000)
	var third := trec.take()
	_check(
		t.newest_tick() == 22 and first == ["S:9:1"] and second == ["D:9", "S:4:1"] and third == ["D:4"] and third_res == {},
		"W6: at equal tick 20 id 9 despawns BEFORE id 4 spawns (%s); an empty snapshot despawns the rest (%s)" % [str(second), str(third)]
	)
	# A life spawned and despawned between two calls fires both, in tick order.
	var j := _new_world(0)
	var jrec := _Rec.new(j)
	j.ingest(_body(j, 30, [[20, 1, [1, 1]]]))
	j.ingest(_body(j, 31, [[21, 1, [2, 2]]]))
	j.ingest(_body(j, 32, []))
	var jres := j.sample(40000)
	var jlog := jrec.take()
	j.sample(41000)
	_check(
		j.newest_tick() == 32 and jlog == ["S:20:1", "D:20", "S:21:1", "D:21"] and jres == {} and jrec.take() == [],
		"W6: one call spanning whole lives fires spawn then despawn per life in ascending tick order (%s), and not again" % str(jlog)
	)
	# Ties by ascending id.
	var m := _new_world(0)
	var mrec := _Rec.new(m)
	m.ingest(_body(m, 50, [[8, 1, [1, 1]], [5, 1, [1, 1]], [6, 1, [1, 1]]]))
	m.ingest(_body(m, 52, []))
	m.sample(50000)
	var spawns := mrec.take()
	m.sample(52000)
	var despawns := mrec.take()
	_check(
		m.newest_tick() == 52 and spawns == ["S:5:1", "S:6:1", "S:8:1"] and despawns == ["D:5", "D:6", "D:8"],
		"W6: simultaneous spawns and despawns fire in ascending id order (%s / %s)" % [str(spawns), str(despawns)]
	)
	# Kind change of the same id = despawn + spawn.
	var k := _new_world(0)
	var krec := _Rec.new(k)
	k.ingest(_body(k, 60, [[1, 1, [1, 1]]]))
	k.ingest(_body(k, 62, [[1, 1, [2, 2]]]))
	k.ingest(_body(k, 64, [[1, 2, [7, 7, 7]]]))
	var old_life := k.sample(63000)
	var l1 := krec.take()
	var new_life := k.sample(64000)
	var l2 := krec.take()
	var later := k.sample(65000)
	_check(
		k.newest_tick() == 64 and l1 == ["S:1:1"] and _psize(old_life.get(1)) == 2
		and l2 == ["D:1", "S:1:2"] and _near(new_life.get(1), [7, 7, 7]) and _near(later.get(1), [7, 7, 7]),
		"W6: the same id with another kind is despawn + spawn at that tick (%s), sized by the new kind" % str(l2)
	)


# --- W6b --------------------------------------------------------------------------------------


func _case_w6b() -> void:
	print("W6b: late snapshots still fire their signals exactly once")
	var c := _new_world(0)
	var rec := _Rec.new(c)
	var ok := [c.ingest(_body(c, 10, [[1, 1, [1, 1]]])), c.ingest(_body(c, 20, [[1, 1, [2, 2]]]))]
	var on_time := c.sample(50000)
	var l1 := rec.take()
	c.sample(50000)
	c.sample(51000)
	var l2 := rec.take()
	_check(
		ok == [true, true] and c.newest_tick() == 20 and l1 == ["S:1:1"] and l2 == [] and _sorted_keys(on_time) == [1],
		"W6b: (setup) render time is 50000; id 1 spawned (tick 10) exactly once and not again on later calls (%s then %s)" % [str(l1), str(l2)]
	)
	# Late spawn: tick 30 is already behind the render time.
	var late_ok := c.ingest(_body(c, 30, [[1, 1, [3, 3]], [5, 1, [9, 9]]]))
	rec.take()
	var s1 := c.sample(52000)
	var spawn_log := rec.take()
	c.sample(53000)
	c.sample(54000)
	var again := rec.take()
	_check(
		late_ok and c.newest_tick() == 30 and spawn_log == ["S:5:1"] and again == [] and _sorted_keys(s1) == [1, 5],
		"W6b: a late snapshot (tick 30 < render 50000) starting id 5 fires entity_spawned on the NEXT call, once, and never again (%s then %s)" % [str(spawn_log), str(again)]
	)
	# Late despawn.
	var late_d := c.ingest(_body(c, 35, [[5, 1, [9, 9]]]))
	var s2 := c.sample(54000)
	var d_log := rec.take()
	c.sample(55000)
	c.sample(55500)
	var d_again := rec.take()
	_check(
		late_d and c.newest_tick() == 35 and d_log == ["D:1"] and d_again == [] and _sorted_keys(s2) == [5],
		"W6b: a late snapshot ending id 1 at tick 35 < render fires entity_despawned once on the next call, never again (%s then %s)" % [str(d_log), str(d_again)]
	)
	# Late despawn and late spawn at the same tick: despawn first although the spawning id is lower.
	var late_both := c.ingest(_body(c, 40, [[3, 1, [1, 1]]]))
	var s3 := c.sample(56000)
	var both_log := rec.take()
	c.sample(57000)
	var both_again := rec.take()
	_check(
		late_both and c.newest_tick() == 40 and both_log == ["D:5", "S:3:1"] and both_again == [] and _sorted_keys(s3) == [3],
		"W6b: late despawn of id 5 and late spawn of id 3 at the same tick 40: D:5 BEFORE S:3, once (%s then %s)" % [str(both_log), str(both_again)]
	)
	# Late life that both spawns and despawns, with ordering across ticks.
	var late_life := [c.ingest(_body(c, 42, [[7, 1, [1, 1]]])), c.ingest(_body(c, 44, []))]
	var s4 := c.sample(58000)
	var life_log := rec.take()
	c.sample(59000)
	var life_again := rec.take()
	_check(
		late_life == [true, true] and c.newest_tick() == 44 and life_log == ["D:3", "S:7:1", "D:7"] and life_again == [] and s4 == {},
		"W6b: one call fires the late despawn (tick 42), then the late life's spawn (42) and despawn (44), each once (%s then %s)" % [str(life_log), str(life_again)]
	)
	# An ordinary on-time spawn still fires exactly once.
	var future := c.ingest(_body(c, 60, [[9, 1, [4, 4]]]))
	var before := c.sample(59500)
	var f0 := rec.take()
	var at := c.sample(60000)
	var f1 := rec.take()
	c.sample(61000)
	c.sample(62000)
	var f2 := rec.take()
	_check(
		future and c.newest_tick() == 60 and before == {} and f0 == [] and f1 == ["S:9:1"] and f2 == [] and _sorted_keys(at) == [9],
		"W6b: an on-time spawn waits for its tick, fires once at 60000 and does not double fire (%s, %s, %s)" % [str(f0), str(f1), str(f2)]
	)


# --- W7 ---------------------------------------------------------------------------------------


func _case_w7() -> void:
	print("W7: local ids")
	var c := _new_world(0)
	var rec := _Rec.new(c)
	c.ingest(_body(c, 10, [[1, 1, [0, 0]], [2, 1, [5, 5]]]))
	c.ingest(_body(c, 12, [[1, 1, [2, 2]], [2, 1, [7, 7]]]))
	c.set_local([2])
	var s1 := c.sample(11000)
	var log1 := rec.take()
	_check(
		c.newest_tick() == 12 and _sorted_keys(s1) == [1] and _near(s1.get(1), [1, 1]) and log1 == ["S:1:1"],
		"W7: with id 2 local, sample() omits it and no signal fires for it (got ids %s, %s)" % [str(_sorted_keys(s1)), str(log1)]
	)
	_check(
		c.latest(2) == {"tick": 12, "state": _pf([7, 7])} and c.state_at(2, 10) == _pf([5, 5]) and c.state_at(2, 12) == _pf([7, 7])
		and c.state_at(2, 11).is_empty() and c.latest(99) == {},
		"W7: latest/state_at still expose the local entity's host truth; unknown ids give {} / empty"
	)
	c.set_local([1])
	var s2 := c.sample(12000)
	_check(
		_sorted_keys(s2) == [2] and _near(s2.get(2), [7, 7]) and rec.take() == [],
		"W7: set_local replaces the set: now id 1 is omitted and id 2 is sampled (got %s)" % str(_sorted_keys(s2))
	)
	c.set_local([2])
	c.ingest(_body(c, 14, [[1, 1, [3, 3]]]))
	var s3 := c.sample(14000)
	_check(
		c.newest_tick() == 14 and _sorted_keys(s3) == [1] and rec.take() == [],
		"W7: a local entity's despawn fires no signal either (id 2 despawned at tick 14, log empty)"
	)


# --- X: extra() ---------------------------------------------------------------------------


func _case_x() -> void:
	print("X: extra()")
	var c := _new_world(0)
	var before := c.extra()
	var with_x := _body(c, 10, [[1, 1, [1, 1]]])
	with_x["x"] = {"score": 5, "tags": ["a"]}
	var a1 := c.ingest(with_x)
	var got1 := c.extra()
	got1["junk"] = 1
	var got2 := c.extra()
	_check(
		before == {} and a1 and got2.get("score") == 5 and got2.size() == 2 and not got2.has("junk"),
		"X: extra() is {} before any snapshot, then the accepted snapshot's x; editing the returned Dictionary does not change it"
	)
	var no_x := _body(c, 12, [[1, 1, [2, 2]]])
	var stale_x := _body(c, 10, [[1, 1, [3, 3]]])
	stale_x["x"] = {"stale": true}
	var bad_x := _body(c, 14, [[1, 1, [4, 4]]])
	bad_x["x"] = {"bad": true}
	bad_x["lh"] = 0
	var a2 := c.ingest(stale_x)
	var kept := c.extra()
	var a3 := c.ingest(bad_x)
	var kept2 := c.extra()
	var a4 := c.ingest(no_x)
	_check(
		a1 and a2 == false and a3 == false and kept.get("score") == 5 and kept2.get("score") == 5 and a4 and c.newest_tick() == 12 and c.extra() == {},
		"X: a stale or rejected snapshot leaves extra() alone; the next accepted snapshot without x gives {}"
	)
	var with_x2 := _body(c, 16, [[1, 1, [5, 5]]])
	with_x2["x"] = {"n": 1}
	var a5 := c.ingest(with_x2)
	var before_reset := c.extra()
	c.reset()
	_check(
		a5 and before_reset == {"n": 1} and c.extra() == {},
		"X: reset() clears extra()"
	)


# --- H: aliasing and edge holes -------------------------------------------------------------


func _case_holes() -> void:
	print("H: aliasing and edge cases")
	# pack() must not alias the caller's extra (including nested values).
	var h := _new_world(0)
	h.set_entity(1, 1, _pf([1, 2]))
	var extra := {"a": {"b": 1}, "n": 1}
	var body := h.pack(5, 0, {"p": 1}, null, null, extra)
	extra["a"]["b"] = 2
	extra["n"] = 9
	extra["new"] = true
	_check(
		body.get("ht") == 5 and body.get("x") == {"a": {"b": 1}, "n": 1},
		"H: mutating the caller's extra (also a nested value) after pack() leaves the returned x unchanged (got %s)" % str(body.get("x"))
	)
	# ANGLE extrapolation takes the short arc at a non-integer k.
	var ang := _new_world(0)
	ang.ingest(_body(ang, 1, [[1, 2, [0, 3.0, 0]]]))
	ang.ingest(_body(ang, 2, [[1, 2, [0, -3.0, 0]]]))
	var r1 := ang.sample(2500)
	var e1 := _wrap(-3.0 + _wrap(-3.0 - 3.0) * 0.5)
	var neg := _new_world(0)
	neg.ingest(_body(neg, 1, [[1, 2, [0, -3.0, 0]]]))
	neg.ingest(_body(neg, 2, [[1, 2, [0, 3.0, 0]]]))
	var r2 := neg.sample(2500)
	var e2 := _wrap(3.0 + _wrap(3.0 + 3.0) * 0.5)
	_check(
		r1.has(1) and r2.has(1) and ang.extrapolated_frames == 1 and absf(r1[1][1] - e1) < 0.0001 and absf(r2[1][1] - e2) < 0.0001
		and absf(e1 - (-2.8584)) < 0.001 and absf(e2 - 2.8584) < 0.001,
		"H: ANGLE extrapolation across +/-PI continues the short arc at k = 0.5 (3.0 -> -3.0 gives %.4f, -3.0 -> 3.0 gives %.4f)" % [e1, e2]
	)
	# peer_section: a section without ack reads -1; ev defaults to [].
	var c := _new_world(0)
	var accepted := c.ingest(_body(c, 7, [[1, 1, [1, 1]]], {"a": {}, "b": {"ack": 0}}))
	_check(
		accepted and c.peer_section("a") == {"ht": 7, "ack": -1, "ev": []} and c.peer_section("b") == {"ht": 7, "ack": 0, "ev": []},
		"H: a wire section without ack gives ack -1 (an explicit ack 0 stays 0) and ev defaults to []"
	)
	# latest() returns copies.
	var l := c.latest(1)
	var st: PackedFloat32Array = l.get("state", PackedFloat32Array())
	if st.size() > 0:
		st[0] = 99.0
	var s_after := c.sample(8000)
	_check(
		st.size() == 2 and c.latest(1).get("state") == _pf([1, 1]) and c.state_at(1, 7) == _pf([1, 1]) and _near(s_after.get(1), [1, 1]),
		"H: mutating the state returned by latest() changes neither a later latest(), state_at() nor sample()"
	)
	var sa := c.state_at(1, 7)
	if sa.size() > 0:
		sa[1] = 55.0
	_check(
		sa.size() == 2 and c.latest(1).get("state") == _pf([1, 1]),
		"H: mutating the array returned by state_at() does not change the stored sample"
	)
	# ingest() must not alias the body's pl.
	var d := _new_world(0)
	var pl := {"p1": {"ack": 5, "ev": [[1, 2, "x"]], "rt": 3}}
	var db := _body(d, 3, [[1, 1, [1, 1]]], pl)
	var ok := d.ingest(db)
	var expected := {"ht": 3, "ack": 5, "ev": [[1, 2, "x"]], "rt": 3}
	var snapshot_ok := d.peer_section("p1") == expected
	pl["p1"]["ack"] = 999
	pl["p1"]["ev"].append([2, 2, "y"])
	pl["p1"]["ev"][0][2] = "mutated"
	pl["p1"]["rt"] = 77
	pl["p2"] = {"ack": 1}
	_check(
		ok and snapshot_ok and d.peer_section("p1") == expected and d.peer_section("p2") == {},
		"H: mutating the ingested body's pl (ack, rt, ev array and an inner event, a new peer) after ingest() does not change peer_section() (got %s)" % str(d.peer_section("p1"))
	)


# --- E1 ---------------------------------------------------------------------------------------


func _case_e1() -> void:
	print("E1: event ring")
	var r := CouchEventRing.new()
	var pushed := [
		r.push("a", 4, {"hp": 1}, 10), r.push("a", 5, "two", 11), r.push("a", 4, 3, 12),
		r.push("b", 9, null, 12), r.push("a", 4, 4, 13),
	]
	_check(
		pushed == [1, 2, 3, 1, 4] and r.highest_id("a") == 4 and r.highest_id("b") == 1 and r.highest_id("zz") == 0
		and r.max_age_ticks == 120 and r.max_pending == 64,
		"E1: ids are monotone per peer (a: 1,2,3,4 and b: 1 interleaved); highest_id agrees; defaults 120 ticks / 64 pending"
	)
	_check(
		r.pending_for("a") == [[1, 4, {"hp": 1}], [2, 5, "two"], [3, 4, 3], [4, 4, 4]] and r.pending_for("b") == [[1, 9, null]]
		and r.pending_for("zz") == [],
		"E1: pending_for returns [id, kind, payload] ascending per peer and [] for an unknown peer"
	)
	var p: Array = r.pending_for("a")
	p.clear()
	var p2: Array = r.pending_for("a")
	p2.append("junk")
	_check(
		p.is_empty() and _ids(r.pending_for("a")) == [1, 2, 3, 4],
		"E1: pending_for returns a copy (clearing / appending to it leaves the ring intact)"
	)
	var inner: Array = r.pending_for("a")
	if inner.size() > 0 and inner[0] is Array:
		inner[0][0] = 777
		inner[0][1] = 777
	_check(
		inner.size() == 4 and r.pending_for("a")[0] == [1, 4, {"hp": 1}],
		"E1: the inner [id, kind, payload] arrays are copies too (editing a returned event leaves the ring intact)"
	)
	r.ack("a", 2)
	var after_ack := _ids(r.pending_for("a"))
	r.ack("a", 1)
	r.ack("a", 2)
	r.ack("a", 0)
	_check(
		after_ack == [3, 4] and _ids(r.pending_for("a")) == [3, 4] and r.over_ack_count("a") == 0 and _ids(r.pending_for("b")) == [1],
		"E1: ack(2) drops ids 1-2; stale acks (1, 2, 0) are ignored and not over-acks; another peer is untouched"
	)
	r.ack("a", 99)
	var after_over := r.pending_for("a")
	var next_id := r.push("a", 4, "five", 14)
	_check(
		after_over == [] and r.over_ack_count("a") == 1 and next_id == 5 and _ids(r.pending_for("a")) == [5] and r.over_ack_count("b") == 0,
		"E1: ack(99) beyond the highest id clamps to 4 and is counted once; the next push is 5, not 100"
	)
	r.ack("a", 4)
	var kept := _ids(r.pending_for("a"))
	r.ack("a", 5)
	_check(
		kept == [5] and r.pending_for("a") == [] and r.over_ack_count("a") == 1,
		"E1: after the clamp an ack of 4 is stale (event 5 stays), ack 5 clears it without a second over-ack"
	)
	r.ack("n", 3)
	var n_id := r.push("n", 1, "v", 0)
	_check(
		r.over_ack_count("n") == 1 and n_id == 1 and _ids(r.pending_for("n")) == [1],
		"E1: an ack for a peer with nothing pushed is an over-ack clamped to 0 and does not swallow the next event"
	)
	# Expiry boundary, custom and default.
	var e := CouchEventRing.new()
	e.max_age_ticks = 10
	e.push("a", 1, "x", 100)
	e.push("a", 1, "y", 101)
	e.push("b", 1, "z", 100)
	e.expire(110)
	var at_boundary := [_ids(e.pending_for("a")), e.expired_count("a"), _ids(e.pending_for("b")), e.expired_count("b")]
	e.expire(111)
	var one_past := [_ids(e.pending_for("a")), e.expired_count("a"), _ids(e.pending_for("b")), e.expired_count("b")]
	e.expire(112)
	_check(
		at_boundary == [[1, 2], 0, [1], 0] and one_past == [[2], 1, [], 1] and _ids(e.pending_for("a")) == [] and e.expired_count("a") == 2,
		"E1: with max_age 10, age exactly 10 is kept and age 11 is dropped and counted (at %s, past %s)" % [str(at_boundary), str(one_past)]
	)
	e.ack("a", 2)
	_check(e.over_ack_count("a") == 0 and e.highest_id("a") == 2, "E1: acking events that already expired is not an over-ack")
	var d := CouchEventRing.new()
	d.push("a", 1, "x", 0)
	d.expire(120)
	var d_at := [_ids(d.pending_for("a")), d.expired_count("a")]
	d.expire(121)
	_check(
		d_at == [[1], 0] and d.pending_for("a") == [] and d.expired_count("a") == 1,
		"E1: the default max_age_ticks 120: kept at age 120, expired at 121"
	)
	# Overflow.
	var o := CouchEventRing.new()
	o.max_pending = 3
	var o_ids: Array = []
	for i in 3:
		o_ids.append(o.push("a", 1, i, i))
	var full := _ids(o.pending_for("a"))
	var full_overflow := o.overflow_count("a")
	for i in range(3, 5):
		o_ids.append(o.push("a", 1, i, i))
	_check(
		o_ids == [1, 2, 3, 4, 5] and full == [1, 2, 3] and full_overflow == 0 and _ids(o.pending_for("a")) == [3, 4, 5]
		and o.overflow_count("a") == 2 and o.expired_count("a") == 0 and o.overflow_count("b") == 0,
		"E1: max_pending 3: exactly 3 pending is fine; pushes 4 and 5 drop the OLDEST (ids 1, 2), counted as overflow not expiry"
	)
	o.ack("a", 3)
	_check(_ids(o.pending_for("a")) == [4, 5], "E1: ack after overflow still prunes by id")
	# forget keeps the next id; reset restarts.
	var f := CouchEventRing.new()
	f.push("a", 1, "x", 0)
	f.push("a", 1, "y", 0)
	f.push("a", 1, "z", 0)
	f.push("b", 1, "bb", 0)
	f.expire(500)
	var before_forget := [f.expired_count("a"), f.expired_count("b")]
	f.push("a", 1, "w", 500)
	f.push("b", 1, "v", 500)
	f.forget("a")
	var a_after := [f.pending_for("a"), f.expired_count("a"), f.overflow_count("a"), f.over_ack_count("a")]
	var a_next := f.push("a", 1, "back", 501)
	_check(
		before_forget == [3, 1] and a_after == [[], 0, 0, 0] and a_next == 5 and _ids(f.pending_for("b")) == [2] and f.expired_count("b") == 1,
		"E1: forget(a) drops its pending events and counters but keeps its next id (5); b is untouched"
	)
	_check(
		before_forget == [3, 1] and f.highest_id("a") == 5 and f.highest_id("b") == 2,
		"E1: highest_id survives forget (a: 5 after the post-forget push, b: 2)"
	)
	var g := CouchEventRing.new()
	g.max_pending = 2
	g.max_age_ticks = 10
	for i in 3:
		g.push("a", 1, i, 0)
	g.ack("a", 2)
	g.ack("a", 50)
	g.push("a", 1, "four", 0)
	g.push("a", 1, "five", 0)
	g.expire(100)
	g.push("a", 1, "six", 100)
	var pre := [g.highest_id("a"), g.overflow_count("a"), g.over_ack_count("a"), g.expired_count("a"), _ids(g.pending_for("a"))]
	g.forget("a")
	var post := [g.highest_id("a"), g.overflow_count("a"), g.over_ack_count("a"), g.expired_count("a"), g.pending_for("a")]
	_check(
		pre == [6, 1, 1, 2, [6]] and post == [6, 0, 0, 0, []],
		"E1: forget zeroes pending and the overflow / over-ack / expired counters (%s -> %s) but highest_id stays 6" % [str(pre), str(post)]
	)
	var seven := g.push("a", 1, "seven", 101)
	g.ack("a", 3)
	g.ack("a", 6)
	_check(
		pre == [6, 1, 1, 2, [6]] and seven == 7 and _ids(g.pending_for("a")) == [7] and g.over_ack_count("a") == 0 and g.expired_count("a") == 0,
		"E1: after forget an old ack (3, 6 <= the kept acked id) is ignored: event 7 stays pending, no over-ack counted"
	)
	f.reset()
	_check(
		before_forget == [3, 1] and f.pending_for("a") == [] and f.pending_for("b") == [] and f.highest_id("a") == 0 and f.expired_count("b") == 0
		and f.push("a", 1, "n", 0) == 1 and f.push("b", 1, "n", 0) == 1,
		"E1: reset() clears everything and ids restart at 1"
	)


# --- E2 ---------------------------------------------------------------------------------------


func _case_e2() -> void:
	print("E2: event inbox")
	var ib := CouchEventInbox.new()
	var first := ib.receive([[1, 7, "a"], [2, 7, "b"], [3, 8, {"k": 1}]])
	_check(
		first == [[1, 7, "a"], [2, 7, "b"], [3, 8, {"k": 1}]] and ib.last_applied() == 3 and ib.gap_count == 0,
		"E2: three events are returned in order with their kind and payload; last_applied 3"
	)
	var again := ib.receive([[1, 7, "a"], [2, 7, "b"], [3, 8, {"k": 1}]])
	var stale := ib.receive([[2, 7, "b"]])
	_check(
		ib.last_applied() == 3 and again == [] and stale == [] and ib.malformed_count == 0 and ib.gap_count == 0,
		"E2: redelivery and stale events return [] (exactly once; not counted malformed)"
	)
	var reordered := ib.receive([[5, 1, "e"], [4, 1, "d"]])
	_check(
		reordered == [[4, 1, "d"], [5, 1, "e"]] and ib.last_applied() == 5 and ib.gap_count == 0,
		"E2: events arriving out of order within a call are returned ascending, no gap"
	)
	var dups := ib.receive([[6, 1, "f"], [6, 1, "f"], [7, 1, "g"], [6, 1, "f"]])
	var mixed := ib.receive([[6, 1, "f"], [7, 1, "g"], [8, 2, "h"]])
	_check(
		dups == [[6, 1, "f"], [7, 1, "g"]] and mixed == [[8, 2, "h"]] and ib.last_applied() == 8,
		"E2: a duplicate inside one call is applied once; a call mixing old and new returns only the new"
	)
	var gapped := ib.receive([[11, 1, "x"], [12, 1, "y"]])
	_check(
		gapped == [[11, 1, "x"], [12, 1, "y"]] and ib.gap_count == 1 and ib.lost_count == 2 and ib.last_applied() == 12,
		"E2: ids 9-10 never arrive: events 11 and 12 are still delivered (no stall), gap_count 1, lost_count 2"
	)
	var gapped2 := ib.receive([[16, 1, "p"], [14, 1, "q"]])
	_check(
		gapped2 == [[14, 1, "q"], [16, 1, "p"]] and ib.gap_count == 3 and ib.lost_count == 4 and ib.last_applied() == 16,
		"E2: two more gaps (13 and 15 lost) in one call: gap_count 3, lost_count 4"
	)
	var null_payload := ib.receive([[17, 3, null]])
	_check(null_payload == [[17, 3, null]], "E2: a null payload is a valid event")
	var malformed_before := ib.malformed_count
	var non_arrays := [ib.receive(5), ib.receive("s"), ib.receive({"a": 1}), ib.receive(null)]
	_check(
		non_arrays == [[], [], [], []] and ib.malformed_count == malformed_before + 4 and ib.last_applied() == 17,
		"E2: a non-Array events value returns [] and counts malformed each time"
	)
	var m0 := ib.malformed_count
	var mixed_bad := ib.receive([[18, 1, "ok"], 5, [19, 1], [20, 1, 2, 3], [0, 1, "z"], [-3, 1, "z"], [21.0, 1, "f"], ["22", 1, "s"], [23, "k", "s"], [24, 1.5, "f"], null, []])
	_check(
		mixed_bad == [[18, 1, "ok"]] and ib.malformed_count == m0 + 11 and ib.last_applied() == 18 and ib.gap_count == 3,
		"E2: 11 malformed elements are skipped and counted individually; the one valid sibling is delivered; no gap invented (got %s, +%d)" % [str(mixed_bad), ib.malformed_count - m0]
	)
	var next := ib.receive([[19, 1, "q"]])
	_check(next == [[19, 1, "q"]] and ib.last_applied() == 19, "E2: after the malformed batch the next valid id 19 is applied")
	ib.reset()
	var fresh := ib.receive([[1, 1, "n"]])
	_check(
		fresh == [[1, 1, "n"]] and ib.last_applied() == 1 and ib.gap_count == 0 and ib.lost_count == 0 and ib.malformed_count == 0,
		"E2: reset() sets last_applied 0 and zeroes the counters: event 1 is applicable again"
	)
	var g := CouchEventInbox.new()
	var from_zero := g.receive([[3, 1, "x"]])
	_check(
		from_zero == [[3, 1, "x"]] and g.gap_count == 1 and g.lost_count == 2 and g.last_applied() == 3,
		"E2: a first event with id 3 is a gap of 2 (ids 1-2 lost)"
	)


# --- S1 harness -------------------------------------------------------------------------------


## One client of the simulated session.
class _Peer extends RefCounted:
	var id := ""
	var idx := 0
	var use_json := false
	var down_base := 50
	var up_base := 50
	var jitter := 30
	var loss_down := 0.03
	var loss_up := 0.02
	var net_rng := RandomNumberGenerator.new()
	var frame_rng := RandomNumberGenerator.new()
	var offset_ms := 0
	var outage_from := -1
	var outage_to := -1
	var policy: CouchNetClockPolicy
	var clock: CouchNetClock
	var world: CouchReplicatedWorld
	var inbox: CouchEventInbox
	var rec: RefCounted
	var next_t := 0
	# Observations.
	var frames := 0
	var post_frames := 0
	var track_frames := 0
	var track_err_render := 0.0     # |sampled x - truth at the render tick|
	var track_err_timeline := 0.0   # |sampled x - truth at (host timeline - render delay)|
	var render_violations := 0
	var prev_r := 0
	var prev_valid := false
	var warm_marked := false
	var held_warm := 0
	var ext_warm := 0
	var applied: Array = []         # event ids in application order
	var wrong_target := 0
	var codec_fail := 0
	var snaps_ingested := 0
	var snaps_dropped := 0
	var inputs_dropped := 0
	var spawned: Array = []
	var despawned: Array = []

	func in_outage(t: int) -> bool:
		return t >= outage_from and t < outage_to

	func held_post() -> int:
		return world.held_frames - held_warm

	func ext_post() -> int:
		return world.extrapolated_frames - ext_warm


class _SigLog extends RefCounted:
	var peer: _Peer

	func _init(p: _Peer) -> void:
		peer = p
		p.world.entity_spawned.connect(_s)
		p.world.entity_despawned.connect(_d)

	func _s(id: int, _kind: int) -> void:
		peer.spawned.append(id)

	func _d(id: int) -> void:
		peer.despawned.append(id)


## The simulated session. See the file header.
class _WSim extends RefCounted:
	const FAR_T := 1 << 60
	const MOVER := 100

	var peers: Array = []
	var host_world: CouchReplicatedWorld
	var ring: CouchEventRing
	var echo: CouchNetClockEcho
	var ticker: CouchFixedTicker
	var host_rng := RandomNumberGenerator.new()
	var acks := {}
	var render_delay := 6
	var warmup_ms := 4000
	var duration_ms := 25_000
	var snap_every := 2
	var events_end_tick := 0
	var t := 0
	var next_host_t := 0
	var next_snap := 0
	var to_host: Array = []
	var to_client: Array = []
	var seq := 0
	var env_seq := 0
	var event_counter := 0

	func _init(seed_value: int, p_render_delay: int, p_duration_ms: int, outage_peer: int = -1, outage_from: int = -1, outage_to: int = -1) -> void:
		render_delay = p_render_delay
		duration_ms = p_duration_ms
		host_rng.seed = seed_value
		host_world = CouchReplicatedWorld.new()
		host_world.register_kind(1, [LERP, LERP])
		ring = CouchEventRing.new()
		echo = CouchNetClockEcho.new()
		ticker = CouchFixedTicker.new(60)
		ticker.start(0, 0)
		events_end_tick = (duration_ms - 4000) * 60 / 1000
		var bases := [50, 45, 55]
		var losses := [0.02, 0.03, 0.04]
		for i in 3:
			var p := _Peer.new()
			p.id = "peer%d" % i
			p.idx = i
			p.use_json = i == 0
			p.down_base = bases[i]
			p.up_base = bases[(i + 1) % 3]
			p.loss_down = losses[i]
			p.loss_up = losses[(i + 2) % 3]
			p.net_rng.seed = seed_value * 31 + i * 7 + 1
			p.frame_rng.seed = seed_value * 17 + i * 5 + 3
			p.offset_ms = OFFSET_MS + i * 13_579
			p.next_t = 7 + i * 5
			p.policy = CouchNetClockPolicy.new()
			p.policy.render_delay_ticks = render_delay
			p.policy.render_delay_adaptive = false   # S1d switches it on
			p.clock = CouchNetClock.new(p.policy)
			p.world = CouchReplicatedWorld.new()
			p.world.register_kind(1, [LERP, LERP])
			p.inbox = CouchEventInbox.new()
			p.rec = _SigLog.new(p)
			if i == outage_peer:
				p.outage_from = outage_from
				p.outage_to = outage_to
			peers.append(p)
			acks[p.id] = -1

	func _gap(rng: RandomNumberGenerator) -> int:
		return maxi(16 + rng.randi_range(-4, 4), 1)

	func _delay(p: _Peer, base: int) -> int:
		return maxi(base + p.net_rng.randi_range(-p.jitter, p.jitter), 1)

	func client_now(p: _Peer, tt: int) -> int:
		return p.offset_ms + tt

	func run_until(end_t: int) -> void:
		while true:
			var best := FAR_T
			var kind := -1
			var which := -1
			var m := -1
			var m_t := FAR_T
			for i in to_client.size():
				if int(to_client[i]["arrive"]) < m_t:
					m_t = int(to_client[i]["arrive"])
					m = i
			if m >= 0:
				best = m_t
				kind = 1
			if next_host_t < best:
				best = next_host_t
				kind = 2
			for i in peers.size():
				if peers[i].next_t < best:
					best = peers[i].next_t
					kind = 3
					which = i
			if kind < 0 or best > end_t:
				break
			t = maxi(t, best)
			match kind:
				1:
					var msg: Dictionary = to_client[m]
					to_client.remove_at(m)
					_client_receive(msg)
				2:
					_host_frame(t)
				3:
					_client_frame(peers[which], t)
		t = maxi(t, end_t)

	# --- host ---

	func _sim_tick(tk: int) -> void:
		host_world.set_entity(MOVER, 1, PackedFloat32Array([0.5 * tk, -0.25 * tk]))
		var k := tk / 120
		var ph := tk % 120
		if ph >= 30 and ph < 90:
			host_world.set_entity(200 + k, 1, PackedFloat32Array([float(tk), 0.0]))
		elif ph == 90:
			host_world.remove_entity(200 + k)
		if tk < events_end_tick:
			if tk % 12 == 0:
				var target: _Peer = peers[(tk / 12) % peers.size()]
				event_counter += 1
				ring.push(target.id, 7, {"to": target.id, "n": event_counter}, tk)
			if tk % 90 == 45:
				var first: _Peer = peers[0]
				event_counter += 1
				ring.push(first.id, 7, {"to": first.id, "n": event_counter}, tk)
				event_counter += 1
				ring.push(first.id, 8, {"to": first.id, "n": event_counter}, tk)

	func _host_frame(th: int) -> void:
		next_host_t = th + _gap(host_rng)
		var before := ticker.next_tick
		ticker.advance(th)
		for tk in range(before, ticker.next_tick):
			_sim_tick(tk)
		var last := ticker.next_tick - 1
		var due: Array = []
		var keep: Array = []
		for msg in to_host:
			if int(msg["arrive"]) <= th:
				due.append(msg)
			else:
				keep.append(msg)
		to_host = keep
		due.sort_custom(func(x, y):
			if int(x["arrive"]) != int(y["arrive"]):
				return int(x["arrive"]) < int(y["arrive"])
			return int(x["seq"]) < int(y["seq"])
		)
		for msg in due:
			var pid: String = msg["peer"]
			var body: Dictionary = msg["body"]
			var tick := int(body["tick"])
			acks[pid] = maxi(int(acks[pid]), tick)
			echo.note_input(pid, tick, ticker.next_tick, int(msg["arrive"]))
			ring.ack(pid, int(body.get("ev", 0)))
		if ticker.started and last >= next_snap and last >= 0:
			var body := host_world.pack(last, th, acks, echo, ring, {})
			env_seq += 1
			var envelope := CouchEnvelope.make(CouchEnvelope.KIND_SNAPSHOT, 1, env_seq, body)
			var json_frame := CouchEnvelope.to_json_frame(envelope)
			var bytes := CouchEnvelope.to_bytes(envelope)
			for p in peers:
				if p.in_outage(th) or p.net_rng.randf() < p.loss_down:
					p.snaps_dropped += 1
					continue
				seq += 1
				to_client.append({
					"arrive": th + _delay(p, p.down_base), "seq": seq, "peer": p,
					"json": json_frame, "bytes": bytes,
				})
			next_snap = last + snap_every

	# --- client ---

	func _client_receive(msg: Dictionary) -> void:
		var p: _Peer = msg["peer"]
		var res: Dictionary
		if p.use_json:
			res = CouchEnvelope.from_json_frame(msg["json"])
		else:
			res = CouchEnvelope.from_bytes(msg["bytes"])
		if res.get("error", "x") != "":
			p.codec_fail += 1
			return
		var body: Variant = res["envelope"]["body"]
		var cn := client_now(p, int(msg["arrive"]))
		if p.world.ingest(body):
			p.snaps_ingested += 1
			var ps := p.world.peer_section(p.id)
			if ps.is_empty():
				return
			p.clock.on_snapshot(int(ps["ht"]), cn)
			if ps.has("rt"):
				p.clock.on_echo(int(ps["rt"]), int(ps["hm"]), int(ps["mg"]), cn)
			for e in p.inbox.receive(ps["ev"]):
				var payload: Variant = e[2]
				if not (payload is Dictionary) or payload.get("to") != p.id:
					p.wrong_target += 1
				p.applied.append(int(e[0]))

	func _client_frame(p: _Peer, tc: int) -> void:
		p.next_t = tc + _gap(p.frame_rng)
		var cn := client_now(p, tc)
		var ticks := p.clock.advance(cn)
		for tk in ticks:
			if p.in_outage(tc) or p.net_rng.randf() < p.loss_up:
				p.inputs_dropped += 1
				continue
			seq += 1
			to_host.append({
				"arrive": tc + _delay(p, p.up_base), "seq": seq, "peer": p.id,
				"body": {"tick": int(tk), "ev": p.inbox.last_applied()},
			})
		if not p.clock.synced:
			return
		var r := p.clock.render_tick_milli(cn)
		if p.prev_valid and r < p.prev_r:
			p.render_violations += 1
		p.prev_r = r
		p.prev_valid = true
		p.frames += 1
		if tc >= warmup_ms and not p.warm_marked:
			p.warm_marked = true
			p.held_warm = p.world.held_frames
			p.ext_warm = p.world.extrapolated_frames
		var s := p.world.sample(r)
		if tc >= warmup_ms:
			p.post_frames += 1
			if s.has(MOVER):
				var x: float = (s[MOVER] as PackedFloat32Array)[0]
				p.track_frames += 1
				p.track_err_render = maxf(p.track_err_render, absf(x - 0.5 * float(r) / 1000.0))
				var timeline_tick := float(tc * 60 - render_delay * 1000) / 1000.0
				p.track_err_timeline = maxf(p.track_err_timeline, absf(x - 0.5 * timeline_tick))

	func total_held_post() -> int:
		var n := 0
		for p in peers:
			n += p.held_post()
		return n

	func total_ext_post() -> int:
		var n := 0
		for p in peers:
			n += p.ext_post()
		return n

	func min_post_frames() -> int:
		var n := FAR_T
		for p in peers:
			n = mini(n, p.post_frames)
		return n

	func min_track_frames() -> int:
		var n := FAR_T
		for p in peers:
			n = mini(n, p.track_frames)
		return n


const S1_DELAY := 7


func _case_s1() -> void:
	print("S1: host + 3 clients, lossy jittery links, render delay %d ticks" % S1_DELAY)
	var s := _WSim.new(4242, S1_DELAY, 25_000)
	s.run_until(25_000)
	var total_cross := 0
	for p in s.peers:
		var lbl: String = p.id
		var w: CouchReplicatedWorld = p.world
		_check(
			p.clock.synced and p.snaps_ingested > 300 and p.post_frames > 800 and p.track_frames > 800 and p.codec_fail == 0,
			"S1/%s: synced, ingested %d snapshots through the %s codec, %d post-warmup frames (%d with the mover), no codec failures" % [lbl, p.snaps_ingested, "JSON" if p.use_json else "binary", p.post_frames, p.track_frames]
		)
		_check(
			p.snaps_dropped > 4 and p.inputs_dropped > 10 and w.stale_count > 0 and w.rejected_count == 0,
			"S1/%s: the impairment really happened (%d snapshots and %d inputs dropped, %d reordered/stale) and nothing was rejected" % [lbl, p.snaps_dropped, p.inputs_dropped, w.stale_count]
		)
		_check(
			p.frames > 1000 and p.render_violations == 0,
			"S1/%s: render time never ran backwards over %d frames" % [lbl, p.frames]
		)
		_check(
			p.post_frames > 800 and p.track_frames > 800 and p.held_post() == 0,
			"S1/%s: post-warmup held_frames == 0 (%d frames, %d with the mover)" % [lbl, p.post_frames, p.track_frames]
		)
		_check(
			p.post_frames > 800 and p.track_frames > 800 and p.ext_post() * 10 <= p.post_frames,
			"S1/%s: post-warmup extrapolated_frames bounded: %d of %d frames (<= 10%%)" % [lbl, p.ext_post(), p.post_frames]
		)
		_check(
			p.track_frames > 800 and p.track_err_render <= 0.05,
			"S1/%s: the constant-velocity entity's sampled x is within 0.05 of its true position at the render tick (worst %.4f)" % [lbl, p.track_err_render]
		)
		_check(
			p.track_frames > 800 and p.track_err_timeline <= 1.5,
			"S1/%s: ...and within 1.5 units (3 ticks of motion) of the host timeline minus the render delay (worst %.4f)" % [lbl, p.track_err_timeline]
		)
		var highest := s.ring.highest_id(p.id)
		var strictly_ascending := true
		for i in range(1, p.applied.size()):
			if int(p.applied[i]) <= int(p.applied[i - 1]):
				strictly_ascending = false
		_check(
			p.applied.size() > 20 and strictly_ascending and p.wrong_target == 0,
			"S1/%s: %d events applied, each id at most once and in ascending order, none addressed to another peer" % [lbl, p.applied.size()]
		)
		_check(
			p.applied.size() > 20 and highest > 20 and p.inbox.last_applied() == highest and p.applied.size() + p.inbox.lost_count == highest
			and p.inbox.lost_count <= s.ring.expired_count(p.id) and s.ring.pending_for(p.id) == [],
			"S1/%s: every one of the %d pushed events was applied (%d) or counted lost (%d <= %d expired host-side); nothing is left pending" % [lbl, highest, p.applied.size(), p.inbox.lost_count, s.ring.expired_count(p.id)]
		)
		var spawn_ok := true
		var seen := {}
		for id in p.spawned:
			if seen.has(id):
				spawn_ok = false
			seen[id] = true
		var d_seen := {}
		for id in p.despawned:
			if not seen.has(id) or d_seen.has(id):
				spawn_ok = false
			d_seen[id] = true
		_check(
			p.spawned.size() >= 5 and p.despawned.size() >= 4 and spawn_ok and p.spawned.size() - p.despawned.size() <= 2,
			"S1/%s: %d spawns and %d despawns, every despawn follows its own spawn and no life spawned twice" % [lbl, p.spawned.size(), p.despawned.size()]
		)
		total_cross += p.wrong_target
	_check(
		total_cross == 0 and s.ring.highest_id("peer0") > 20 and s.ring.highest_id("peer1") > 20 and s.ring.highest_id("peer2") > 20,
		"S1: no peer received another peer's event (3 independent streams of %d / %d / %d events)" % [s.ring.highest_id("peer0"), s.ring.highest_id("peer1"), s.ring.highest_id("peer2")]
	)


func _case_s1b() -> void:
	print("S1b: render_delay_ticks sweep 2..8 (report)")
	var smallest := -1
	var smallest_calm := -1
	var all_ran := true
	for delay in range(2, 9):
		var s := _WSim.new(4242, delay, 15_000)
		s.run_until(15_000)
		var held := PackedInt32Array()
		var ext := PackedInt32Array()
		for p in s.peers:
			held.append(p.held_post())
			ext.append(p.ext_post())
		var total_held := s.total_held_post()
		print("  S1b: render_delay_ticks=%d held_frames=%d (per client %s) extrapolated_frames=%d (per client %s) post-warmup frames=%d" % [delay, total_held, str(held), s.total_ext_post(), str(ext), s.min_post_frames()])
		if s.min_post_frames() < 300 or s.min_track_frames() < 300:
			all_ran = false
		if total_held == 0 and smallest < 0:
			smallest = delay
		if total_held == 0 and s.total_ext_post() == 0 and smallest_calm < 0:
			smallest_calm = delay
	if smallest >= 0:
		print("  S1b: smallest render_delay_ticks with post-warmup held_frames == 0: %d" % smallest)
	else:
		print("  S1b: no render_delay_ticks in 2..8 reached post-warmup held_frames == 0")
	if smallest_calm >= 0:
		print("  S1b: smallest render_delay_ticks with post-warmup held_frames == 0 AND extrapolated_frames == 0: %d" % smallest_calm)
	else:
		print("  S1b: no render_delay_ticks in 2..8 reached zero extrapolated_frames as well")
	_check(all_ran, "S1b: all seven sweep runs synced and produced post-warmup samples for every client (report only, no threshold on the delay)")


func _case_s1d() -> void:
	print("S1d: the S1 network with the adaptive render delay from a floor of 3 ticks")
	var s := _WSim.new(4242, 3, 15_000)
	for p in s.peers:
		p.policy.render_delay_adaptive = true
	s.run_until(15_000)
	for p in s.peers:
		var lbl: String = p.id
		var c: CouchNetClock = p.clock
		print("  S1d/%s: render delay %d milliticks (target %d), %d late snapshots, %d extrapolated of %d post-warmup frames" % [lbl, c.render_delay_milli, c.render_target_milli, c.late_snapshots, p.ext_post(), p.post_frames])
		_check(
			p.post_frames > 500 and p.held_post() == 0 and p.ext_post() * 100 <= p.post_frames and p.render_violations == 0,
			"S1d/%s: post-warmup held 0 and extrapolated %d of %d frames (<= 1%%; fixed 3 ticks: ~65%%), render never backwards" % [lbl, p.ext_post(), p.post_frames]
		)
		_check(
			p.track_frames > 500 and p.track_err_render <= 0.05,
			"S1d/%s: the mover's sampled x is within 0.05 of truth at the render tick (worst %.4f)" % [lbl, p.track_err_render]
		)
		_check(
			c.render_delay_milli >= 3000 and c.render_delay_milli <= 12_000,
			"S1d/%s: the delay settled between the floor and 12 ticks (%d)" % [lbl, c.render_delay_milli]
		)


func _case_s1c() -> void:
	print("S1c: client 1 cut off for 3.5 s")
	var s := _WSim.new(777, S1_DELAY, 25_000, 1, 8000, 11_500)
	s.run_until(25_000)
	var cut: _Peer = s.peers[1]
	var highest := s.ring.highest_id(cut.id)
	var asc := true
	for i in range(1, cut.applied.size()):
		if int(cut.applied[i]) <= int(cut.applied[i - 1]):
			asc = false
	_check(
		cut.snaps_ingested > 300 and cut.applied.size() > 10 and highest > 20 and s.ring.expired_count(cut.id) > 0,
		"S1c: the cut peer lost events host-side during the outage (expired_count %d of %d pushed) and still received %d" % [s.ring.expired_count(cut.id), highest, cut.applied.size()]
	)
	_check(
		cut.inbox.gap_count >= 1 and cut.inbox.lost_count >= 1 and cut.inbox.lost_count <= s.ring.expired_count(cut.id)
		and cut.inbox.last_applied() == highest and cut.applied.size() + cut.inbox.lost_count == highest and asc and cut.wrong_target == 0,
		"S1c: the inbox reported the gap (gap_count %d, lost_count %d); applied %d + lost %d == %d pushed; ascending, none foreign" % [cut.inbox.gap_count, cut.inbox.lost_count, cut.applied.size(), cut.inbox.lost_count, highest]
	)
	var others_ok := true
	for p in s.peers:
		if p != cut:
			others_ok = others_ok and p.applied.size() + p.inbox.lost_count == s.ring.highest_id(p.id) and p.wrong_target == 0
	_check(
		others_ok and s.ring.highest_id("peer0") > 20 and s.peers[0].applied.size() > 20 and s.peers[2].applied.size() > 20,
		"S1c: the other peers' streams still close exactly (applied + lost == pushed) despite the outage"
	)


# --- S2 ---------------------------------------------------------------------------------------


func _case_s2() -> void:
	print("S2: new epoch")
	var h := _new_world(0)
	var ring := CouchEventRing.new()
	var echo := CouchNetClockEcho.new()
	h.set_entity(7, 1, _pf([1, 2]))
	h.set_entity(8, 1, _pf([3, 4]))
	var old_ids := [ring.push("a", 4, "old1", 100), ring.push("a", 4, "old2", 100), ring.push("a", 4, "old3", 100)]
	echo.note_input("a", 5, 4, 1000)
	var body := h.pack(100, 1050, {"a": 90}, echo, ring)
	var c := _new_world(0)
	var rec := _Rec.new(c)
	var inbox := CouchEventInbox.new()
	var clock := CouchNetClock.new()
	var accepted := c.ingest(body)
	c.set_local([8])
	var s_old := c.sample(100_000)
	var spawn_log := rec.take()
	c.sample(120_000)
	var dup := c.ingest(body)
	var bad := c.ingest(5)
	rec.take()
	var ps := c.peer_section("a")
	var delivered := inbox.receive(ps.get("ev", []))
	clock.on_snapshot(int(ps.get("ht", 0)), 1000)
	var gen := clock.sync_generation
	var hash_before := c.layout_hash()
	_check(
		old_ids == [1, 2, 3] and accepted and c.newest_tick() == 100 and spawn_log == ["S:7:1"] and _sorted_keys(s_old) == [7]
		and delivered.size() == 3 and clock.synced and c.held_frames == 1 and dup == false and bad == false
		and c.stale_count == 1 and c.rejected_count == 1,
		"S2: (setup) epoch 1 is populated: tick 100 ingested, 3 events delivered, local id 8, counters non-zero (held %d, stale %d, rejected %d)" % [c.held_frames, c.stale_count, c.rejected_count]
	)
	var hazard := inbox.receive([[1, 4, "new1"]])
	_check(
		inbox.last_applied() == 3 and hazard == [],
		"S2: WITHOUT reset the new epoch's event 1 would be swallowed as a duplicate (the hazard reset() exists for)"
	)
	h.reset()
	ring.reset()
	echo.reset()
	c.reset()
	inbox.reset()
	clock.reset()
	var sample_after := c.sample(500)
	_check(
		c.newest_tick() == -1 and c.stale_count == 0 and c.rejected_count == 0 and c.last_reject_reason == "" and c.extrapolated_frames == 0
		and c.held_frames == 0 and c.latest(7) == {} and c.state_at(7, 100).is_empty() and c.peer_section("a") == {} and sample_after == {}
		and rec.take() == [] and delivered.size() == 3,
		"S2: client world reset: newest_tick -1, all counters and last_reject_reason cleared, lives gone, nothing fires for the old entities"
	)
	var new_ok := [h.set_entity(8, 1, _pf([1, 1])), h.set_entity(9, 1, _pf([5, 6]))]
	_check(
		hash_before == 584617582 and c.layout_hash() == hash_before and new_ok == [true, true] and not h.has_entity(7) and h.has_entity(9),
		"S2: the kind registry survives reset() (same hash, entities can be set again) while the host's old entities are gone"
	)
	var new_id := ring.push("a", 4, "new1", 3)
	var body2 := h.pack(3, 2000, {"a": -1}, echo, ring)
	var body2_pl: Dictionary = body2.get("pl", {})
	_check(
		new_id == 1 and ring.highest_id("a") == 1 and body2.get("ids") == PackedInt32Array([8, 9])
		and body2_pl.get("a") == {"ack": -1, "ev": [[1, 4, "new1"]]},
		"S2: the reset host ring restarts at id 1; the new body carries only the new event, no old entities, and no stale echo"
	)
	var accepted2 := c.ingest(body2)
	var s_new := c.sample(3500)
	var new_log := rec.take()
	_check(
		accepted2 and c.newest_tick() == 3 and _sorted_keys(s_new) == [8, 9] and _near(s_new.get(9), [5, 6]) and new_log == ["S:8:1", "S:9:1"],
		"S2: tick 3 (lower than the old newest 100) is accepted again; the local set was cleared (id 8 now sampled); render memory restarted (sample(3500) is answered at 3500); only the new lives spawn (%s)" % str(new_log)
	)
	var ps2 := c.peer_section("a")
	var delivered2 := inbox.receive(ps2.get("ev", []))
	var repeat2 := inbox.receive(ps2.get("ev", []))
	_check(
		delivered2 == [[1, 4, "new1"]] and repeat2 == [] and inbox.last_applied() == 1 and inbox.gap_count == 0 and inbox.lost_count == 0,
		"S2: after inbox.reset() the new epoch's event 1 is applied exactly once and none of the old payloads reappear"
	)
	_check(
		accepted2 and delivered2.size() == 1 and clock.synced == false and clock.sync_generation == gen + 1 and gen >= 0,
		"S2: clock.reset() bumps the sync generation (%d -> %d) and unsyncs; the client re-syncs from the first new snapshot" % [gen, clock.sync_generation]
	)
	clock.on_snapshot(int(ps2.get("ht", -1)), 5000)
	_check(clock.synced and ps2.get("ht") == 3, "S2: fed from peer_section the clock syncs again on the new epoch's tick 3")


# --- driver -----------------------------------------------------------------------------------


func _run() -> void:
	_case_w0()
	_case_w1()
	_case_w1b()
	_case_w2()
	_case_w2b()
	_case_w3()
	_case_w4()
	_case_w4b()
	_case_w4c()
	_case_w5()
	_case_w6()
	_case_w6b()
	_case_w7()
	_case_x()
	_case_holes()
	_case_e1()
	_case_e2()
	_case_s1()
	_case_s1b()
	_case_s1c()
	_case_s1d()
	_case_s2()

	print("")
	print("G15 replicated world: %d/%d checks passed" % [_checks - failures, _checks])
	if failures > 0:
		printerr("REPLICATED_WORLD_FAILED: %d check(s)" % failures)
	quit(1 if failures > 0 else 0)
	return
