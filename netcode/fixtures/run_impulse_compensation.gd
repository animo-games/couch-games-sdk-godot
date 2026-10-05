## Headless gate for host-side impulse compensation -- gate G17 (step 1.1).
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_impulse_compensation.gd
##
## What this proves. When the host knocks an owner's stand-in (push_impulse), the owner applies
## the impulse ~one-way later and the first report that shows it (the COVERING report, first
## accepted report with "ev" >= the impulse id) reaches the host ~RTT later. CouchOwnerTargets
## now adds a predicted displacement P(s) = dv * tau * (1 - exp(-s / tau)) from the push until the
## cover, freezes it at the cover as a lead L and lets it decay (hand-off), so the stand-in moves
## at once with no step at the cover. The gate tests the frozen API contract
## (docs/plans/impulse-compensation-1.1-design.md, "API contract" + "Exact definitions"), not any
## implementation: it is written test-first against inert stubs, and every check is guarded so a
## stub (or a wrong-typed return) produces FAIL lines, never a script error.
##
## Cases:
##   U1  offset maths against the closed form: defaults, before / at / after the push, pre-cover
##       growth and velocity (= derivative), the hand-off value at and after the cover, tau read
##       at each call, the timeout hand-off as evaluated by the pure compensation_of (strict
##       boundary, custom timeout), inertia 0 -> no angular part, the tau clamp, the 8-tau drop
##       (at the boundary not yet, one ms later yes).
##   U2  cover bookkeeping: "ev" missing -> 0; "ev" float / negative / String / null / bool ->
##       "bad-shape" with nothing stored; ev covers every impulse <= ev and no later one; game
##       events interleaved in the ring (impulse id 3 after game ids 1, 2: ev 2 covers nothing);
##       several impulses sum; a lower ev on a newer tick does not un-cover; an ev above every
##       impulse covers all.
##   U3  alignment edges of the wiring (ring.ack before note_input): the ring acked by a
##       malformed / a stale-tick input leaves covered_ev and the entry alone; reordered reports
##       (newer accepted first, older rejected) do not un-cover; a lost covering report -> the
##       next accepted report hands off at its own arrival.
##   U4  lifecycle: timeout hand-off counted once and only by a prune (note_input / push_impulse,
##       never compensation_of), a late cover leaves a timed-out entry alone; push_impulse
##       returning -1 and a rejected note_input record and prune nothing; entries are recorded
##       while compensation is off; set_owner (replace) / forget / reset clear; target_for adds
##       the offset below and past extrapolate_cap_ms and in HOLD-stale, wraps rotation, leaves
##       extra channels, is empty in REPORT_ONLY-stale and before the first report; with
##       impulse_compensation = false target_for is byte-equal to step 1 on the same inputs.
##   U5  edges added by the mutation pass: the "ev" check precedes the stride check; prune before
##       cover on one input; the frozen lead before tc; a late timeout prune still freezes
##       P(timeout); ev == covered_ev covers nothing new; impulse_timeout_count persists across
##       set_owner and is cleared by forget / reset.
##   M1  measurement (the review focus): a host + 2 owners as REAL CouchSessions over seeded
##       lossy / jittery links (one-way base 25 / 75 / 125 ms -> RTT 50 / 150 / 250, jitter 30,
##       loss 2-3 %), one knock of p1 (mass 2, |dv| 200). Each scenario runs twice with the same
##       seeds, with and without the knock; the knock displacement is the stand-in's difference
##       between the twins projected on J, so the owner's path cancels out (the twins are first
##       checked to agree exactly before the knock). Metrics: retreat (largest drop below the
##       running peak), overshoot (max minus final), lag50 (ms from the knock until half the
##       final displacement), and the owner's own lag50 from the tick it applied the impulse.
##       Compensation off vs on, target-only vs host direct-apply (dv added to the stand-in's
##       velocity during the knock step, after the spring's update). Asserts on -> small retreat / overshoot and lag50 near the
##       owner's own at every RTT; off -> lag50 grows with RTT. Prints a before / after table.
##   M2  model mismatch: impulse_tau_ms 60 / 167 / 500 against the owner's ~160 ms decay, and a
##       wall case (the owner's velocity zeroed one tick after it applies the impulse, in both
##       twins): overshoot within |dv| * tau * (1 - exp(-RTT / tau)) (RTT = the measured cover
##       delay) plus a small allowance, and re-convergence to the owner's true displacement.
##   M3  with compensation on, the knocked owner applies the impulse exactly once, the
##       ALIGNMENT RULE still holds in every accepted input, the hand-off happens at the first
##       accepted covering report, and the entry is dropped afterwards (no timeout).
##
## HARNESS (`_MSim`). A trimmed copy of G16's S1 harness: entirely synchronous and
## deterministic, fixed seeds, no WebRTC, no await, no real clock, nothing reads Time. Every
## participant is a CouchScriptedRoster + CouchScriptedTransport + a real CouchSession; envelopes
## are routed through a seeded delay / loss queue. The toy owner applies an impulse as
## v += J / mass (w += aj / inertia) and its velocity relaxes to its scripted path
## (v += (u - v) * 6 / 60 per tick, time constant ~160 ms).
##
## LOAD-BEARING GOTCHA: SceneTree.quit(code) only SCHEDULES termination; it does not
## return. `return` follows the one quit(...) in this file.
extends SceneTree

const LERP := CouchReplicatedWorld.LERP
const ANGLE := CouchReplicatedWorld.ANGLE
const SNAP := CouchReplicatedWorld.SNAP
const KIND6 := 1    # [x, y, rot, vx, vy, w]
const KIND_NR := 3  # [x, y, vx, vy]  (no rotation)
const KIND7 := 4    # [x, y, rot, vx, vy, w, extra(SNAP)]
const BASE_O := [10.0, -4.0, 3.0, 20.0, -40.0, 2.0]
## The unit cases' impulse: owner "a" has mass 2 / inertia 4, so dv = (120, -50), dw = 0.5.
const UJ := Vector2(240.0, -100.0)
const UA := 2.0
const UDV := Vector2(120.0, -50.0)
const UDW := 0.5
const TAU := 120  # the default impulse_tau_ms

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


# --- small helpers (all total: a wrong-typed return is a FAIL, never an error) -------------


func _pf(values: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for v in values:
		out.append(float(v))
	return out


func _dg(v: Variant, key: Variant) -> Variant:
	if typeof(v) == TYPE_DICTIONARY and (v as Dictionary).has(key):
		return (v as Dictionary)[key]
	return null


func _num(v: Variant) -> float:
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return float(v)
	return NAN


func _close(v: Variant, e: float, tol: float = 1e-4) -> bool:
	var f := _num(v)
	return not is_nan(f) and absf(f - e) <= tol * maxf(1.0, absf(e))


func _v2close(v: Variant, e: Vector2, tol: float = 1e-4) -> bool:
	return typeof(v) == TYPE_VECTOR2 and _close((v as Vector2).x, e.x, tol) and _close((v as Vector2).y, e.y, tol)


func _pfclose(v: Variant, e: Array, tol: float = 1e-4) -> bool:
	if typeof(v) != TYPE_PACKED_FLOAT32_ARRAY:
		return false
	var pa: PackedFloat32Array = v
	if pa.size() != e.size():
		return false
	for i in e.size():
		if not _close(pa[i], float(e[i]), tol):
			return false
	return true


func _wrap(v: float) -> float:
	return wrapf(v, -PI, PI)


func _new_world() -> CouchReplicatedWorld:
	var w := CouchReplicatedWorld.new()
	w.register_kind(KIND6, [LERP, LERP, ANGLE, LERP, LERP, LERP])
	w.register_kind(KIND_NR, [LERP, LERP, LERP, LERP])
	w.register_kind(KIND7, [LERP, LERP, ANGLE, LERP, LERP, LERP, SNAP])
	return w


func _new_targets() -> CouchOwnerTargets:
	var t := CouchOwnerTargets.new(_new_world())
	t.set_channels(KIND6, CouchBodyChannels.new({"x": 0, "y": 1, "rot": 2, "vx": 3, "vy": 4, "w": 5}))
	t.set_channels(KIND_NR, CouchBodyChannels.new({"x": 0, "y": 1, "vx": 2, "vy": 3}))
	t.set_channels(KIND7, CouchBodyChannels.new({"x": 0, "y": 1, "rot": 2, "vx": 3, "vy": 4, "w": 5}))
	return t


## A well-formed KIND6 input body; ev == null leaves "ev" out.
func _b6(tick: int, ev: Variant, vals: Array = BASE_O) -> Dictionary:
	var b := {"t": tick, "o": _pf(vals)}
	if ev != null:
		b["ev"] = ev
	return b


## Targets with "a" owning entity 10 (KIND6, mass 2, inertia 4) and one accepted report at 900.
func _owner_a() -> CouchOwnerTargets:
	var t := _new_targets()
	t.set_owner("a", 10, KIND6, 2.0, 4.0, 0)
	t.note_input("a", _b6(1, 0), 900)
	return t


# --- the closed form (the contract's "Exact definitions") -----------------------------------
# An expected compensation is [pos: Vector2, vel: Vector2, rot: float, w: float].


func _tau_s(tau_ms: int) -> float:
	return maxi(tau_ms, 1) / 1000.0


## P(s) for one scalar dv, s in ms.
func _p1(dv: float, s_ms: int, tau_ms: int) -> float:
	if s_ms < 0:
		return 0.0
	var tau := _tau_s(tau_ms)
	return dv * tau * (1.0 - exp(-(s_ms / 1000.0) / tau))


## P'(s).
func _pd1(dv: float, s_ms: int, tau_ms: int) -> float:
	if s_ms < 0:
		return 0.0
	return dv * exp(-(s_ms / 1000.0) / _tau_s(tau_ms))


func _pv(dv: Vector2, s_ms: int, tau_ms: int) -> Vector2:
	return Vector2(_p1(dv.x, s_ms, tau_ms), _p1(dv.y, s_ms, tau_ms))


## An uncovered entry s_ms after its push.
func _pre(dv: Vector2, dw: float, s_ms: int, tau_ms: int = TAU) -> Array:
	return [_pv(dv, s_ms, tau_ms), Vector2(_pd1(dv.x, s_ms, tau_ms), _pd1(dv.y, s_ms, tau_ms)), _p1(dw, s_ms, tau_ms), _pd1(dw, s_ms, tau_ms)]


## A handed-off entry with leads (lead, alead), since_ms after its tc.
func _post(lead: Vector2, alead: float, since_ms: int, tau_ms: int = TAU) -> Array:
	var tau := _tau_s(tau_ms)
	var e: float = exp(-(since_ms / 1000.0) / tau)
	return [lead * e, -lead / tau * e, alead * e, -alead / tau * e]


## The hand-off of an entry covered cover_ms after its push, evaluated since_ms after the cover.
func _ho(dv: Vector2, dw: float, cover_ms: int, since_ms: int, tau_ms: int = TAU) -> Array:
	return _post(_pv(dv, cover_ms, tau_ms), _p1(dw, cover_ms, tau_ms), since_ms, tau_ms)


func _sum(a: Array, b: Array) -> Array:
	return [(a[0] as Vector2) + (b[0] as Vector2), (a[1] as Vector2) + (b[1] as Vector2), float(a[2]) + float(b[2]), float(a[3]) + float(b[3])]


func _zero() -> Array:
	return [Vector2.ZERO, Vector2.ZERO, 0.0, 0.0]


## compensation_of matches `e` (typed keys, tolerance relative to max(1, |value|)).
func _comp_ok(c: Variant, e: Array, tol: float = 1e-4) -> bool:
	if typeof(c) != TYPE_DICTIONARY or (c as Dictionary).size() != 4:
		return false
	return _v2close(_dg(c, "pos"), e[0], tol) and _v2close(_dg(c, "vel"), e[1], tol) \
		and typeof(_dg(c, "rot")) == TYPE_FLOAT and _close(_dg(c, "rot"), e[2], tol) \
		and typeof(_dg(c, "w")) == TYPE_FLOAT and _close(_dg(c, "w"), e[3], tol)


func _fmt(e: Array) -> String:
	return "pos (%.4f, %.4f) vel (%.4f, %.4f) rot %.5f w %.5f" % [(e[0] as Vector2).x, (e[0] as Vector2).y, (e[1] as Vector2).x, (e[1] as Vector2).y, e[2], e[3]]


## One compensation_of check: message carries expected and actual.
func _cc(t: CouchOwnerTargets, peer: String, now: int, e: Array, label: String, tol: float = 1e-4) -> void:
	var c: Variant = t.compensation_of(peer, now)
	_check(_comp_ok(c, e, tol), "%s: compensation_of(%s, %d) == %s (got %s)" % [label, peer, now, _fmt(e), c])


# --- U1: offset maths ---------------------------------------------------------------------


func _case_u1() -> void:
	print("U1: offset maths against the closed form")
	var fresh := _new_targets()
	_check(fresh.impulse_compensation == true and fresh.impulse_tau_ms == 120 and fresh.impulse_timeout_ms == 1000,
		"U1: defaults impulse_compensation true, impulse_tau_ms 120, impulse_timeout_ms 1000")
	_cc(fresh, "nobody", 1000, _zero(), "U1: a non-owner gives the exact zero result")
	var t := _owner_a()
	_cc(t, "a", 1000, _zero(), "U1: an owner with no entries gives zeros")
	var ring := CouchEventRing.new()
	var id: int = t.push_impulse(ring, "a", UJ, UA, 5, 1000)
	_check(id == 1 and t.pending_impulse_count("a") == 1 and t.covered_ev("a") == 0 and t.impulse_timeout_count("a") == 0,
		"U1: push_impulse returns id 1 and records one entry (pending %d, covered_ev %d)" % [t.pending_impulse_count("a"), t.covered_ev("a")])
	_check(ring.pending_for("a").size() == 1, "U1: ...and still pushes the event to the ring (step-1 behaviour)")
	_cc(t, "a", 999, _zero(), "U1: before the push time (s < 0) P = P' = 0")
	_cc(t, "a", 1000, [Vector2.ZERO, UDV, 0.0, UDW], "U1: at the push: no displacement yet, velocity dv = J / mass, w = aj / inertia")
	for s in [16, 50, 120, 400]:
		_cc(t, "a", 1000 + s, _pre(UDV, UDW, s), "U1: uncovered, %d ms after the push: P(s), P'(s) with tau 120" % s)
	_cc(t, "a", 2000, _pre(UDV, UDW, 1000), "U1: exactly impulse_timeout_ms after the push it is still uncovered (strict >)")
	# velocity is the derivative of position.
	var c0: Variant = t.compensation_of("a", 1049)
	var c1: Variant = t.compensation_of("a", 1051)
	var cm: Variant = t.compensation_of("a", 1050)
	var fd := Vector2.ZERO
	var fdr := 0.0
	if typeof(_dg(c0, "pos")) == TYPE_VECTOR2 and typeof(_dg(c1, "pos")) == TYPE_VECTOR2:
		fd = ((_dg(c1, "pos") as Vector2) - (_dg(c0, "pos") as Vector2)) / 0.002
		fdr = (_num(_dg(c1, "rot")) - _num(_dg(c0, "rot"))) / 0.002
	_check(fd != Vector2.ZERO and _v2close(_dg(cm, "vel"), fd, 1e-3) and _close(_dg(cm, "w"), fdr, 1e-3),
		"U1: vel / w are the time derivative of pos / rot (central difference %s vs %s)" % [fd, _dg(cm, "vel")])
	# tau is read at each call.
	t.impulse_tau_ms = 240
	_cc(t, "a", 1050, _pre(UDV, UDW, 50, 240), "U1: impulse_tau_ms is read at each call (240 after the push)")
	t.impulse_tau_ms = 120
	# The cover at 1080.
	_check(t.note_input("a", _b6(2, 1), 1080) and t.covered_ev("a") == 1 and t.pending_impulse_count("a") == 1,
		"U1: an accepted report with ev 1 at 1080 covers the impulse (covered_ev %d)" % t.covered_ev("a"))
	_cc(t, "a", 1080, _ho(UDV, UDW, 80, 0), "U1: at the cover the lead is frozen at L = P(80 ms) and starts to decay (vel = -L / tau)")
	_check(_v2close(_dg(t.compensation_of("a", 1080), "pos"), _pv(UDV, 80, TAU)), "U1: ...so the position is continuous across the cover")
	for s in [1, 120, 500]:
		_cc(t, "a", 1080 + s, _ho(UDV, UDW, 80, s), "U1: handed off, %d ms after the cover: L * exp(-s / tau)" % s)
	t.impulse_tau_ms = 240
	_cc(t, "a", 1200, _post(_pv(UDV, 80, TAU), _p1(UDW, 80, TAU), 120, 240), "U1: after the cover tau is still read at each call (the lead stays frozen)")
	t.impulse_tau_ms = 120
	# The 8-tau drop (strict): tc 1080 + 960 = 2040 kept, 2041 dropped.
	t.note_input("a", _b6(3, 1), 2040)
	_check(t.pending_impulse_count("a") == 1, "U1: a covered entry is kept while now - tc == 8 * tau (960 ms): pending %d" % t.pending_impulse_count("a"))
	_cc(t, "a", 2040, _ho(UDV, UDW, 80, 960), "U1: ...and still contributes L * exp(-8)")
	t.note_input("a", _b6(4, 1), 2041)
	_check(t.pending_impulse_count("a") == 0 and t.accepted_count("a") == 4, "U1: one ms later an accepted report prunes it (pending %d)" % t.pending_impulse_count("a"))
	_cc(t, "a", 2041, _zero(), "U1: a dropped entry contributes nothing")

	# Timeout hand-off as seen by the pure compensation_of.
	var tt := _owner_a()
	tt.push_impulse(CouchEventRing.new(), "a", UJ, UA, 5, 1000)
	_cc(tt, "a", 2001, _ho(UDV, UDW, 1000, 1), "U1: uncovered and now - t0 > timeout: evaluated as handed off at t0 + timeout with L = P(timeout)")
	_cc(tt, "a", 2300, _ho(UDV, UDW, 1000, 300), "U1: ...300 ms after the timeout")
	_cc(tt, "a", 1500, _pre(UDV, UDW, 500), "U1: compensation_of is pure: an earlier time after a later one still gives the uncovered value")
	_check(tt.impulse_timeout_count("a") == 0 and tt.pending_impulse_count("a") == 1, "U1: compensation_of never counts a timeout nor prunes")
	tt.impulse_timeout_ms = 300
	_cc(tt, "a", 1300, _pre(UDV, UDW, 300), "U1: impulse_timeout_ms is a variable (300: at 300 ms still uncovered)")
	_cc(tt, "a", 1301, _ho(UDV, UDW, 300, 1), "U1: ...and at 301 ms handed off with L = P(300)")

	# inertia 0 -> no angular part.
	var tz := _new_targets()
	tz.set_owner("z", 20, KIND6, 4.0, 0.0, 0)
	tz.push_impulse(CouchEventRing.new(), "z", Vector2(40.0, 80.0), 3.0, 1, 1000)
	_cc(tz, "z", 1050, _pre(Vector2(10.0, 20.0), 0.0, 50), "U1: inertia 0 -> dw = 0 (no rot / w), the linear part still uses J / mass (mass 4)")

	# tau clamp.
	var tc := _owner_a()
	tc.push_impulse(CouchEventRing.new(), "a", UJ, UA, 5, 1000)
	for v in [0, -50]:
		tc.impulse_tau_ms = v
		_cc(tc, "a", 1005, _pre(UDV, UDW, 5, 1), "U1: impulse_tau_ms %d is clamped to 1 ms when read" % v)


# --- U2: cover bookkeeping -----------------------------------------------------------------


## note_input must refuse as "bad-shape" and store nothing (count, report, cover, entries).
func _expect_bad_ev(t: CouchOwnerTargets, ev: Variant, label: String) -> void:
	var acc := t.accepted_count("a")
	var n := t.reject_count("a", "bad-shape")
	var cev := t.covered_ev("a")
	var pend := t.pending_impulse_count("a")
	var tg := t.target_for("a", 1065)
	var comp: Variant = t.compensation_of("a", 1065)
	var body := _b6(50, 0, [99.0, 99.0, 0.0, 0.0, 0.0, 0.0])
	body["ev"] = ev
	var res := t.note_input("a", body, 1064)
	_check(res == false and t.reject_count("a", "bad-shape") == n + 1 and t.last_reject_reason("a") == "bad-shape"
		and t.accepted_count("a") == acc and t.covered_ev("a") == cev and t.pending_impulse_count("a") == pend
		and t.target_for("a", 1065) == tg and str(t.compensation_of("a", 1065)) == str(comp),
		"U2: \"ev\" %s -> 'bad-shape', nothing stored (no report, no cover, entries unchanged)" % label)


func _case_u2() -> void:
	print("U2: cover bookkeeping")
	var t := _owner_a()
	var ring := CouchEventRing.new()
	ring.push("a", 7, "game event", 1)
	ring.push("a", 7, "game event", 2)
	var id3: int = t.push_impulse(ring, "a", UJ, UA, 3, 1000)
	var j4 := Vector2(-60.0, 20.0)
	var dv4 := Vector2(-30.0, 10.0)
	var id4: int = t.push_impulse(ring, "a", j4, -1.0, 4, 1020)
	_check(id3 == 3 and id4 == 4 and t.pending_impulse_count("a") == 2,
		"U2: impulses pushed after two game events get ring ids 3 and 4 (got %d, %d); both recorded" % [id3, id4])
	_cc(t, "a", 1030, _sum(_pre(UDV, UDW, 30), _pre(dv4, -0.25, 10)), "U2: two uncovered impulses sum")
	# ev missing -> 0.
	_check(t.note_input("a", _b6(2, null), 1040) and t.accepted_count("a") == 2 and t.covered_ev("a") == 0,
		"U2: an input without \"ev\" is accepted and counts as ev 0 (covered_ev %d)" % t.covered_ev("a"))
	_check(t.note_input("a", _b6(3, 0), 1045) and t.covered_ev("a") == 0, "U2: an explicit ev 0 is accepted and covers nothing")
	# Malformed ev.
	for b in [["1.0 (float)", 3.0], ["-1", -1], ["\"3\" (String)", "3"], ["null", null], ["true (bool)", true], ["an Array", [3]]]:
		_expect_bad_ev(t, b[1], b[0])
	# ev 2 covers only game events.
	_check(t.note_input("a", _b6(4, 2), 1050) and t.covered_ev("a") == 2, "U2: ev 2 (game events only) is accepted: covered_ev 2")
	_cc(t, "a", 1050, _sum(_pre(UDV, UDW, 50), _pre(dv4, -0.25, 30)), "U2: ...but covers neither impulse (ids 3, 4 are > 2): both still growing")
	# ev 3 covers id 3 only.
	t.note_input("a", _b6(5, 3), 1070)
	_check(t.covered_ev("a") == 3, "U2: ev 3: covered_ev 3 (got %d)" % t.covered_ev("a"))
	_cc(t, "a", 1070, _sum(_ho(UDV, UDW, 70, 0), _pre(dv4, -0.25, 50)), "U2: ev 3 hands off id 3 at 1070 and leaves id 4 growing")
	# Lower ev on a newer tick.
	_check(t.note_input("a", _b6(6, 1), 1080) and t.covered_ev("a") == 3, "U2: a lower ev (1) on a newer tick is accepted and does not lower covered_ev (%d)" % t.covered_ev("a"))
	_cc(t, "a", 1100, _sum(_ho(UDV, UDW, 70, 30), _pre(dv4, -0.25, 80)), "U2: ...and un-covers nothing")
	# ev above every impulse.
	_check(t.note_input("a", _b6(7, 99), 1120) and t.covered_ev("a") == 99, "U2: ev 99 (above every pushed id) is legal: covered_ev 99")
	_cc(t, "a", 1150, _sum(_ho(UDV, UDW, 70, 80), _ho(dv4, -0.25, 100, 30)), "U2: ...and covers every impulse <= 99 (id 4 handed off at 1120)")
	_check(t.pending_impulse_count("a") == 2 and t.reject_count("a", "bad-shape") == 6, "U2: both entries are still stored (pending %d); 6 bad-shape rejections" % t.pending_impulse_count("a"))
	_check(t.covered_ev("nobody") == 0 and t.pending_impulse_count("nobody") == 0 and t.impulse_timeout_count("nobody") == 0,
		"U2: covered_ev / pending_impulse_count / impulse_timeout_count of a non-owner are 0")


# --- U3: alignment edges --------------------------------------------------------------------


## The game wiring of an input: ring.ack first, then note_input.
func _wire(t: CouchOwnerTargets, ring: CouchEventRing, body: Dictionary, now: int) -> bool:
	ring.ack("a", int(body.get("ev", 0)) if typeof(body.get("ev", 0)) == TYPE_INT else 0)
	return t.note_input("a", body, now)


func _case_u3() -> void:
	print("U3: alignment edges")
	var t := _owner_a()
	var ring := CouchEventRing.new()
	t.push_impulse(ring, "a", UJ, UA, 5, 1000)
	var ok_bad := _wire(t, ring, _b6(2, 1, [NAN, 0.0, 0.0, 0.0, 0.0, 0.0]), 1040)
	_check(not ok_bad and ring.pending_for("a").is_empty(), "U3: a malformed (non-finite) input with ev 1 is rejected, but the wiring already acked the ring")
	_check(t.covered_ev("a") == 0 and t.pending_impulse_count("a") == 1, "U3: ...covered_ev stays 0 (keyed on accepted reports, not ring.ack)")
	_cc(t, "a", 1050, _pre(UDV, UDW, 50), "U3: ...and the entry is still uncovered")
	var ok_stale := _wire(t, ring, _b6(1, 1), 1060)
	_check(not ok_stale and t.reject_count("a", "stale-tick") == 1 and t.covered_ev("a") == 0, "U3: a stale-tick input with ev 1 is rejected and does not cover")
	_cc(t, "a", 1070, _pre(UDV, UDW, 70), "U3: ...the entry is still uncovered")
	# The covering report t=3 is "lost"; the next accepted one (t=4) arrives at 1117.
	_check(_wire(t, ring, _b6(4, 1), 1117) and t.covered_ev("a") == 1, "U3: a lost covering report: the next accepted report (t 4, ev 1) covers")
	_cc(t, "a", 1117, _ho(UDV, UDW, 117, 0), "U3: ...and hands off at ITS arrival (1117): L = P(117 ms)")
	_cc(t, "a", 1200, _ho(UDV, UDW, 117, 83), "U3: ...decaying from there")

	# Reordered reports.
	var r := _owner_a()
	var ring2 := CouchEventRing.new()
	r.push_impulse(ring2, "a", UJ, UA, 5, 1000)
	r.push_impulse(ring2, "a", Vector2(0.0, 60.0), 0.0, 6, 1010)
	var dv2 := Vector2(0.0, 30.0)
	_check(_wire(r, ring2, _b6(10, 2), 1100) and r.covered_ev("a") == 2, "U3: reordering: the newer report (t 10, ev 2) arrives first and covers both")
	_check(not _wire(r, ring2, _b6(9, 1), 1110) and not _wire(r, ring2, _b6(8, 0), 1112) and r.covered_ev("a") == 2,
		"U3: ...the older ones (t 9 ev 1, t 8 ev 0) are stale-tick and do not un-cover (covered_ev %d)" % r.covered_ev("a"))
	_cc(r, "a", 1150, _sum(_ho(UDV, UDW, 100, 50), _ho(dv2, 0.0, 90, 50)), "U3: ...both stay handed off at 1100")


# --- U4: lifecycle ---------------------------------------------------------------------------


func _case_u4() -> void:
	print("U4: lifecycle, target_for, kill switch")
	_u4_timeout()
	_u4_no_prune()
	_u4_clear()
	_u4_target_for()
	_u4_switch()


func _u4_timeout() -> void:
	var t := _owner_a()
	var tr := CouchEventRing.new()
	t.push_impulse(tr, "a", UJ, UA, 5, 1000)
	t.note_input("a", _b6(2, 0), 2000)
	_check(t.impulse_timeout_count("a") == 0 and t.pending_impulse_count("a") == 1, "U4: a prune at exactly t0 + timeout does not time out (strict)")
	_cc(t, "a", 2000, _pre(UDV, UDW, 1000), "U4: ...still uncovered")
	t.note_input("a", _b6(3, 0), 2001)
	_check(t.impulse_timeout_count("a") == 1 and t.pending_impulse_count("a") == 1 and t.covered_ev("a") == 0,
		"U4: an accepted report at t0 + timeout + 1 hands the entry off by timeout: impulse_timeout_count 1 (got %d)" % t.impulse_timeout_count("a"))
	_cc(t, "a", 2001, _ho(UDV, UDW, 1000, 1), "U4: ...as if covered at t0 + timeout with L = P(timeout)")
	t.note_input("a", _b6(4, 0), 2002)
	t.push_impulse(tr, "a", Vector2.ZERO, 0.0, 9, 2003)
	_check(t.impulse_timeout_count("a") == 1 and t.pending_impulse_count("a") == 2, "U4: later prunes do not count it again (count %d)" % t.impulse_timeout_count("a"))
	t.note_input("a", _b6(5, 1), 2100)
	_check(t.covered_ev("a") == 1 and t.impulse_timeout_count("a") == 1, "U4: a late cover (ev 1 at 2100) raises covered_ev but changes no count")
	_cc(t, "a", 2100, _sum(_ho(UDV, UDW, 1000, 100), _zero()), "U4: ...and leaves the timed-out entry's hand-off (tc = t0 + timeout) alone")
	t.note_input("a", _b6(6, 1), 2961)
	_check(t.pending_impulse_count("a") == 1, "U4: the timed-out entry is dropped 8 tau after its tc (2000 + 960 < 2961); the zero impulse (id 2, uncovered) is kept: pending %d" % t.pending_impulse_count("a"))
	# push_impulse prunes too.
	var p := _owner_a()
	var ring := CouchEventRing.new()
	p.push_impulse(ring, "a", UJ, UA, 5, 1000)
	p.push_impulse(ring, "a", UJ, UA, 6, 2500)
	_check(p.impulse_timeout_count("a") == 1 and p.pending_impulse_count("a") == 2,
		"U4: push_impulse prunes before recording: the first entry timed out (count %d), not yet dropped (pending %d)" % [p.impulse_timeout_count("a"), p.pending_impulse_count("a")])
	_cc(p, "a", 2500, _sum(_ho(UDV, UDW, 1000, 500), _pre(UDV, UDW, 0)), "U4: ...the old entry decays from 2000, the new one starts at 2500")
	p.push_impulse(ring, "a", UJ, UA, 7, 2961)
	_check(p.pending_impulse_count("a") == 2 and p.impulse_timeout_count("a") == 1, "U4: a push 8 tau after the first entry's tc drops it (pending %d)" % p.pending_impulse_count("a"))
	var q := _owner_a()
	q.push_impulse(CouchEventRing.new(), "a", UJ, UA, 5, 1000)
	q.compensation_of("a", 5000)
	q.target_for("a", 5000)
	_check(q.impulse_timeout_count("a") == 0 and q.pending_impulse_count("a") == 1, "U4: compensation_of / target_for never prune or count a timeout")


func _u4_no_prune() -> void:
	var t := _owner_a()
	var ring := CouchEventRing.new()
	t.push_impulse(ring, "a", UJ, UA, 5, 1000)
	t.note_input("a", _b6(2, 1), 1080)
	_check(t.push_impulse(ring, "a", Vector2(NAN, 0.0), 0.0, 9, 3000) == -1 and t.pending_impulse_count("a") == 1,
		"U4: push_impulse returning -1 (non-finite J) at a time past the drop records and prunes nothing (pending %d)" % t.pending_impulse_count("a"))
	_check(t.push_impulse(ring, "ghost", UJ, UA, 9, 3000) == -1 and t.pending_impulse_count("ghost") == 0, "U4: a non-owner push returns -1 and records nothing")
	_check(not t.note_input("a", _b6(3, 1, [NAN, 0, 0, 0, 0, 0]), 3000) and t.pending_impulse_count("a") == 1,
		"U4: a REJECTED note_input past the drop prunes nothing (pending %d)" % t.pending_impulse_count("a"))
	_check(not t.note_input("a", _b6(2, 1), 3000) and t.pending_impulse_count("a") == 1, "U4: ...nor does a stale-tick one")
	_check(t.note_input("a", _b6(4, 1), 3000) and t.pending_impulse_count("a") == 0, "U4: an accepted one at the same time does (pending %d)" % t.pending_impulse_count("a"))


func _u4_clear() -> void:
	# set_owner (replace).
	var t := _owner_a()
	var ring := CouchEventRing.new()
	t.push_impulse(ring, "a", UJ, UA, 5, 1000)
	t.note_input("a", _b6(2, 1), 1080)
	t.push_impulse(ring, "a", UJ, UA, 6, 1100)
	var pre_ok := t.pending_impulse_count("a") == 2 and t.covered_ev("a") == 1
	_check(t.set_owner("a", 10, KIND6, 2.0, 4.0, 1200) and pre_ok and t.pending_impulse_count("a") == 0 and t.covered_ev("a") == 0,
		"U4: set_owner (replace) clears the peer's entries and covered_ev (before: pending 2, covered_ev 1)")
	_cc(t, "a", 1200, _zero(), "U4: ...compensation is zero after the replace")
	_check(t.note_input("a", _b6(1, 1), 1250) and t.covered_ev("a") == 1, "U4: ...and covered_ev counts again from 0 (a report with ev 1 raises it to 1)")
	# forget.
	var f := _owner_a()
	f.set_owner("b", 11, KIND6, 1.0, 1.0, 0)
	f.push_impulse(ring, "a", UJ, UA, 5, 1000)
	f.push_impulse(ring, "b", UJ, UA, 5, 1000)
	f.note_input("a", _b6(2, 1), 1080)
	f.forget("a")
	_check(f.pending_impulse_count("a") == 0 and f.covered_ev("a") == 0, "U4: forget clears the peer's entries and covered_ev")
	_cc(f, "a", 1100, _zero(), "U4: ...a forgotten peer gets zeros")
	f.set_owner("a", 10, KIND6, 2.0, 4.0, 1200)
	_check(f.pending_impulse_count("a") == 0 and f.covered_ev("a") == 0, "U4: ...and nothing comes back when it owns again")
	_check(f.pending_impulse_count("b") == 1, "U4: forget leaves other peers' entries alone")
	_cc(f, "b", 1050, _pre(UJ, UA, 50), "U4: ...peer b (mass 1, inertia 1) still compensated")
	# reset.
	f.push_impulse(ring, "a", UJ, UA, 7, 1300)
	f.note_input("b", _b6(1, 1), 1310)
	f.reset()
	_check(f.pending_impulse_count("a") == 0 and f.pending_impulse_count("b") == 0 and f.covered_ev("b") == 0, "U4: reset clears every peer's entries and covered_ev")
	f.set_owner("b", 11, KIND6, 1.0, 1.0, 1400)
	_check(f.pending_impulse_count("b") == 0 and f.covered_ev("b") == 0 and f.impulse_tau_ms == 120 and f.impulse_compensation, "U4: ...nothing returns after a new set_owner; the tuning vars are kept")
	_cc(f, "b", 1400, _zero(), "U4: ...zeros after the reset")


func _u4_target_for() -> void:
	# Report BASE_O [x 10, y -4, rot 3.0, vx 20, vy -40, w 2.0] at 1000; push with dw 10 at 1000.
	var aj := 40.0
	var dw := 10.0
	var t := _new_targets()
	t.set_owner("a", 10, KIND6, 2.0, 4.0, 0)
	_check(t.push_impulse(CouchEventRing.new(), "a", UJ, aj, 5, 900) == 1 and t.target_for("a", 950).is_empty(),
		"U4: before the first report target_for stays empty although an entry exists")
	_check(_v2close(_dg(t.compensation_of("a", 950), "pos"), _pv(UDV, 50, TAU)), "U4: ...while compensation_of reports it")
	t = _new_targets()
	t.set_owner("a", 10, KIND6, 2.0, 4.0, 0)
	t.note_input("a", _b6(1, 0), 1000)
	t.push_impulse(CouchEventRing.new(), "a", UJ, aj, 5, 1000)
	var cases := [
		["below the cap (age 50): extrapolated report + offset", 1050, [11.0, -6.0, 3.1, 20.0, -40.0, 2.0], _pre(UDV, dw, 50)],
		["past the cap (age 150): held report (zero velocities) + offset and its velocity", 1150, [12.0, -8.0, _wrap(3.2), 0.0, 0.0, 0.0], _pre(UDV, dw, 150)],
		["HOLD-stale (age 700): held + offset", 1700, [12.0, -8.0, _wrap(3.2), 0.0, 0.0, 0.0], _pre(UDV, dw, 700)],
		["HOLD-stale past the timeout (age 1300): held + timed-out hand-off", 2300, [12.0, -8.0, _wrap(3.2), 0.0, 0.0, 0.0], _ho(UDV, dw, 1000, 300)],
	]
	for c in cases:
		var base: Array = c[2]
		var e: Array = c[3]
		var pos: Vector2 = e[0]
		var vel: Vector2 = e[1]
		var exp_arr := [base[0] + pos.x, base[1] + pos.y, _wrap(base[2] + e[2]), base[3] + vel.x, base[4] + vel.y, base[5] + e[3]]
		_check(_pfclose(t.target_for("a", c[1]), exp_arr, 2e-4), "U4: target_for %s: %s (got %s)" % [c[0], exp_arr, t.target_for("a", c[1])])
	var wrapped: float = 3.1 + _p1(dw, 50, TAU)
	_check(wrapped > PI and _close(t.target_for("a", 1050)[2] if t.target_for("a", 1050).size() == 6 else NAN, _wrap(wrapped), 2e-4),
		"U4: the rotation channel is wrapped after adding the offset (3.1 + %.3f wraps to %.3f)" % [wrapped - 3.1, _wrap(wrapped)])
	t.stale_mode = CouchOwnerTargets.REPORT_ONLY
	_check(t.target_for("a", 1700).is_empty(), "U4: REPORT_ONLY-stale: target_for stays empty with an entry live")
	_check(t.target_for("a", 1150).size() == 6, "U4: ...REPORT_ONLY before stale still returns the compensated target")
	# No rotation channels; an extra channel.
	var n := _new_targets()
	n.set_owner("n", 20, KIND_NR, 2.0, 4.0, 0)
	n.note_input("n", {"t": 1, "o": _pf([1.0, 2.0, 10.0, -20.0])}, 1000)
	n.push_impulse(CouchEventRing.new(), "n", UJ, aj, 5, 1000)
	var en := _pre(UDV, dw, 50)
	_check(_pfclose(n.target_for("n", 1050), [1.5 + en[0].x, 1.0 + en[0].y, 10.0 + en[1].x, -20.0 + en[1].y], 2e-4),
		"U4: a rotation-free kind gets x / y / vx / vy offsets only (no rot / w channels touched)")
	var x7 := _new_targets()
	x7.set_owner("e", 21, KIND7, 2.0, 4.0, 0)
	x7.note_input("e", {"t": 1, "o": _pf([0.0, 0.0, 0.5, 10.0, 10.0, 1.0, 42.0])}, 1000)
	x7.push_impulse(CouchEventRing.new(), "e", UJ, UA, 5, 1000)
	var e7 := _pre(UDV, UDW, 50)
	_check(_pfclose(x7.target_for("e", 1050), [0.5 + e7[0].x, 0.5 + e7[0].y, 0.55 + e7[2], 10.0 + e7[1].x, 10.0 + e7[1].y, 1.0 + e7[3], 42.0], 2e-4),
		"U4: an extra channel (KIND7's SNAP slot) is passed through unchanged")


func _u4_switch() -> void:
	var ref := _new_targets()
	var t := _new_targets()
	for tg in [ref, t]:
		(tg as CouchOwnerTargets).set_owner("a", 10, KIND6, 2.0, 4.0, 0)
		(tg as CouchOwnerTargets).note_input("a", _b6(1, 0), 1000)
	t.impulse_compensation = false
	_check(t.push_impulse(CouchEventRing.new(), "a", UJ, UA, 5, 1000) == 1 and t.pending_impulse_count("a") == 1,
		"U4: with impulse_compensation = false the entry is still recorded")
	for tg in [ref, t]:
		(tg as CouchOwnerTargets).note_input("a", _b6(2, 1, [11.0, -5.0, 3.05, 21.0, -41.0, 2.5]), 1080)
	_check(t.covered_ev("a") == 1, "U4: ...and covered")
	var same := true
	for now in [1000, 1050, 1080, 1100, 1180, 1181, 1300, 1580, 1581, 2200]:
		same = same and t.target_for("a", now) == ref.target_for("a", now)
	ref.stale_mode = CouchOwnerTargets.REPORT_ONLY
	t.stale_mode = CouchOwnerTargets.REPORT_ONLY
	for now in [1100, 1581, 2200]:
		same = same and t.target_for("a", now) == ref.target_for("a", now)
	ref.stale_mode = CouchOwnerTargets.HOLD
	t.stale_mode = CouchOwnerTargets.HOLD
	_check(same, "U4: impulse_compensation = false: target_for is byte-equal to step 1 (no impulse) on the same inputs, extrapolating, held, stale, REPORT_ONLY")
	_cc(t, "a", 1100, _ho(UDV, UDW, 80, 20), "U4: compensation_of ignores the switch (reports what would be added)")
	t.impulse_compensation = true
	var on: PackedFloat32Array = t.target_for("a", 1100)
	var base: PackedFloat32Array = ref.target_for("a", 1100)
	var e := _ho(UDV, UDW, 80, 20)
	_check(on.size() == 6 and base.size() == 6 and _close(on[0], base[0] + (e[0] as Vector2).x, 2e-4) and _close(on[4], base[4] + (e[1] as Vector2).y, 2e-4) and on != base,
		"U4: switching it on later applies to the live entry (x %s vs step-1 %s)" % [on[0] if on.size() > 0 else NAN, base[0] if base.size() > 0 else NAN])


# --- U5: edges found by the mutation pass ----------------------------------------------------
# Each check here was added because a mutant of owner_targets.gd survived U1-U4 / M1-M3
# (docs/plans/impulse-compensation-mutations.py); the mutant it kills is named in a comment.


func _case_u5() -> void:
	print("U5: mutation-pass edges")
	# e05: the "ev" check is step 2 (with "t" / "o"), before the stride check.
	var t := _owner_a()
	var odd := {"t": 5, "o": _pf([1.0, 2.0, 3.0]), "ev": -1}
	_check(not t.note_input("a", odd, 1000) and t.last_reject_reason("a") == "bad-shape" and t.reject_count("a", "bad-stride") == 0,
		"U5: a bad \"ev\" AND a bad stride -> 'bad-shape' (the ev check comes first; got '%s')" % t.last_reject_reason("a"))
	# c07: on accept, prune / time out first, then cover.
	var c := _owner_a()
	c.push_impulse(CouchEventRing.new(), "a", UJ, UA, 5, 1000)
	_check(c.note_input("a", _b6(2, 1), 2100) and c.covered_ev("a") == 1 and c.impulse_timeout_count("a") == 1,
		"U5: the first report after the timeout also covers: the prune times it out first (impulse_timeout_count %d, covered_ev %d)" % [c.impulse_timeout_count("a"), c.covered_ev("a")])
	_cc(c, "a", 2100, _ho(UDV, UDW, 1000, 100), "U5: ...so it stays handed off at t0 + timeout (not covered at 2100 with L = P(1100))")
	# d04: a handed-off entry evaluated before its tc gives the frozen lead (max(now - tc, 0)).
	var d := _owner_a()
	d.push_impulse(CouchEventRing.new(), "a", UJ, UA, 5, 1000)
	d.note_input("a", _b6(2, 1), 1080)
	_cc(d, "a", 1050, _ho(UDV, UDW, 80, 0), "U5: compensation_of before a handed-off entry's tc gives the frozen lead (s clamped to 0)")
	# t11: a timeout hand-off found late by the prune still freezes L = P(timeout), not P(now - t0).
	var k := _owner_a()
	k.impulse_timeout_ms = 100
	k.push_impulse(CouchEventRing.new(), "a", UJ, UA, 5, 1000)
	k.note_input("a", _b6(2, 0), 1600)
	_check(k.impulse_timeout_count("a") == 1 and k.pending_impulse_count("a") == 1, "U5: a prune 500 ms after a 100 ms timeout times the entry out once")
	_cc(k, "a", 1600, _ho(UDV, UDW, 100, 500), "U5: ...with L = P(100 ms) frozen at tc = t0 + 100, whenever the prune ran")
	# c05: a cover happens only when ev RAISES covered_ev (ev == covered_ev covers nothing new).
	var g := _owner_a()
	g.note_input("a", _b6(2, 99), 1000)
	var gid: int = g.push_impulse(CouchEventRing.new(), "a", UJ, UA, 5, 1010)
	_check(gid == 1 and g.note_input("a", _b6(3, 99), 1050) and g.covered_ev("a") == 99,
		"U5: covered_ev 99, then impulse id 1 pushed, then a report with ev 99 again (accepted)")
	_cc(g, "a", 1050, _pre(UDV, UDW, 40), "U5: ...ev 99 does not raise covered_ev, so the entry stays uncovered (contract: only ev > covered_ev covers)")
	# l04 / l05: impulse_timeout_count lives with the step-1 counters.
	var n := _owner_a()
	n.push_impulse(CouchEventRing.new(), "a", UJ, UA, 5, 1000)
	n.note_input("a", _b6(2, 0), 2001)
	var before := n.impulse_timeout_count("a")
	n.set_owner("a", 10, KIND6, 2.0, 4.0, 2100)
	_check(before == 1 and n.impulse_timeout_count("a") == 1 and n.accepted_count("a") == 2,
		"U5: impulse_timeout_count persists across set_owner (replace), like accepted_count (got %d)" % n.impulse_timeout_count("a"))
	n.forget("a")
	_check(n.impulse_timeout_count("a") == 0, "U5: forget clears impulse_timeout_count (got %d)" % n.impulse_timeout_count("a"))
	var r := _owner_a()
	r.push_impulse(CouchEventRing.new(), "a", UJ, UA, 5, 1000)
	r.note_input("a", _b6(2, 0), 2001)
	r.reset()
	_check(r.impulse_timeout_count("a") == 0, "U5: reset clears impulse_timeout_count (got %d)" % r.impulse_timeout_count("a"))


# --- M harness (a trimmed copy of G16's S1 harness) --------------------------------------------


const HOST_ID := "host"
const EID_BASE := 10
const KNOCK_MS := 5000
const AFTER_MS := 3000
## p1 has mass 2 / inertia 3: dv = (120, -160) (|dv| 200), dw = 1.5.
const KNOCK_J := Vector2(240.0, -320.0)
const KNOCK_A := 4.5
const KNOCK_PEER := "p1"
const SNAP_DIST := 150.0
const MS_PER_TICK := 1000.0 / 60.0


class _Own extends RefCounted:
	var id := ""
	var eid := -1
	var mass := 1.0
	var inertia := 1.0
	var roster: CouchScriptedRoster
	var transport: CouchScriptedTransport
	var session: CouchSession
	var clock: CouchNetClock
	var world: CouchReplicatedWorld
	var inbox: CouchEventInbox
	var owned: CouchOwnedEntity
	var ev_latest: Array = []
	var offset_ms := 0
	var next_t := 0
	var net_rng := RandomNumberGenerator.new()
	var frame_rng := RandomNumberGenerator.new()
	var base := 50
	var jitter := 30
	var loss_down := 0.03
	var loss_up := 0.02
	var dropped := 0
	var x := 0.0
	var y := 0.0
	var rot := 0.0
	var vx := 0.0
	var vy := 0.0
	var w := 0.0
	var w_nom := 1.0
	var amp_x := 80.0
	var amp_y := 60.0
	var om_x := 1.3
	var om_y := 1.7
	var applied_count := 0
	var applied_ids: Array = []
	var apply_tick := -1
	var wall := false        # zero the velocity one tick after applying an impulse
	var wall_tick := -1      # the tick at which to zero the velocity (set directly in a baseline twin)
	var hist: Array = []     # [tick, x, y] per owner tick


class _MSim extends RefCounted:
	const FAR_T := 1 << 60
	var T := 1000
	var owners: Dictionary = {}
	var players: Array = []
	var host_roster: CouchScriptedRoster
	var host_transport: CouchScriptedTransport
	var host_session: CouchSession
	var host_world: CouchReplicatedWorld
	var ring: CouchEventRing
	var echo: CouchNetClockEcho
	var ticker: CouchFixedTicker
	var targets: CouchOwnerTargets
	var pol: CouchPDFollowerPolicy
	var acks: Dictionary = {}
	var standins: Dictionary = {}
	var queue: Array = []
	var seq := 0
	var host_rng := RandomNumberGenerator.new()
	var next_host_t := 0
	var next_snap := 0
	var mk_check: Callable
	var immediate := true
	# Scenario.
	var knock := false
	var direct := false
	# Observations.
	var track: Array = []          # [host tick, x, y] of the knocked peer's stand-in
	var knock_tick := -1
	var knock_T := -1
	var knock_id := 0
	var cover_T := -1              # first accepted input of the knocked peer with ev >= knock_id
	var cover_comp: Variant = null # compensation_of right after that input was noted
	var align_samples := 0
	var align_violations := 0
	var accepted: Dictionary = {}

	func _init(seed_value: int, one_way_ms: int) -> void:
		host_rng.seed = seed_value
		host_world = _world()
		ring = CouchEventRing.new()
		echo = CouchNetClockEcho.new()
		ticker = CouchFixedTicker.new(60)
		pol = CouchPDFollowerPolicy.new()
		pol.snap_distance = SNAP_DIST
		targets = CouchOwnerTargets.new(host_world)
		targets.set_channels(KIND7, CouchBodyChannels.new({"x": 0, "y": 1, "rot": 2, "vx": 3, "vy": 4, "w": 5}))
		var ids := ["p1", "p2"]
		players = [_pl(HOST_ID, "host", 0)]
		for i in ids.size():
			players.append(_pl(ids[i], "guest", i + 1))
		var policy := CouchSessionPolicy.new()
		policy.max_input_players = ids.size()
		host_roster = CouchScriptedRoster.new(HOST_ID, players)
		host_transport = CouchScriptedTransport.new()
		host_session = CouchSession.new(host_roster, host_transport, policy)
		host_session.player_joined.connect(_on_joined)
		host_session.input_received.connect(_on_input)
		for i in ids.size():
			owners[ids[i]] = _new_owner(ids[i], i, policy, one_way_ms)

	func _world() -> CouchReplicatedWorld:
		var wd := CouchReplicatedWorld.new()
		wd.register_kind(KIND7, [LERP, LERP, ANGLE, LERP, LERP, LERP, SNAP])
		return wd

	static func _pl(id: String, role: String, slot: int) -> Dictionary:
		return {"userId": id, "username": id.to_upper(), "role": role, "controllerSlot": slot}

	func _new_owner(id: String, i: int, policy: CouchSessionPolicy, one_way_ms: int) -> _Own:
		var o := _Own.new()
		o.id = id
		o.roster = CouchScriptedRoster.new(id, players)
		o.transport = CouchScriptedTransport.new()
		o.session = CouchSession.new(o.roster, o.transport, policy)
		o.session.snapshot_received.connect(_on_snapshot.bind(o))
		o.base = one_way_ms
		var losses := [0.03, 0.02]
		o.loss_down = losses[i % 2]
		o.loss_up = losses[(i + 1) % 2]
		o.net_rng.seed = host_rng.seed * 31 + i * 7 + 1
		o.frame_rng.seed = host_rng.seed * 17 + i * 5 + 3
		o.offset_ms = 987_654 + i * 13_579
		o.next_t = T + 7 + i * 5
		var policy_c := CouchNetClockPolicy.new()
		policy_c.render_delay_ticks = 7
		o.clock = CouchNetClock.new(policy_c)
		o.world = _world()
		o.inbox = CouchEventInbox.new()
		var om_x := [1.3, 1.9]
		var om_y := [1.7, 1.1]
		var wn := [1.1, 2.0]
		o.om_x = om_x[i % 2]
		o.om_y = om_y[i % 2]
		o.w_nom = wn[i % 2]
		o.mass = 2.0 if i == 0 else 1.0
		o.inertia = 3.0 if i == 0 else 1.0
		o.x = 100.0 * float(i + 1)
		return o

	func boot() -> void:
		immediate = true
		host_session.evaluate(T)
		for id in owners:
			(owners[id] as _Own).session.evaluate(T)
		_collect_all()
		pump_now()
		for id in owners:
			var o: _Own = owners[id]
			o.eid = EID_BASE + o.session.local_slot
			o.owned = CouchOwnedEntity.new(o.world, o.eid, KIND7)
			o.world.set_local([o.eid])
		ticker.start(T, 0)
		next_host_t = T + 3
		immediate = false

	# --- transport ---

	func _transport_of(id: String) -> CouchScriptedTransport:
		return host_transport if id == HOST_ID else (owners[id] as _Own).transport

	func _collect_all() -> void:
		_collect(HOST_ID)
		for id in owners.keys():
			_collect(id)

	func _collect(id: String) -> void:
		var tr := _transport_of(id)
		var batch: Array = tr.sends.duplicate()
		tr.reset_log()
		for entry in batch:
			var env := CouchEnvelope.make(str(entry["kind"]), int(entry["epoch"]), int(entry["seq"]), entry["body"])
			var to := str(entry["to"])
			if to == "broadcast":
				for gid in owners.keys():
					if gid != id:
						_enq(id, gid, env)
			elif to == "authority":
				_enq(id, HOST_ID, env)
			elif to.begins_with("peer:"):
				_enq(id, to.substr(5), env)

	func _enq(from: String, to: String, env: Dictionary) -> void:
		if to != HOST_ID and not owners.has(to):
			return
		var arrive := T
		if not immediate:
			var o: _Own = owners[to if from == HOST_ID else from]
			var kind := str(env["kind"])
			var loss := o.loss_down if from == HOST_ID else o.loss_up
			if (kind == CouchEnvelope.KIND_SNAPSHOT or kind == CouchEnvelope.KIND_INPUT) and o.net_rng.randf() < loss:
				o.dropped += 1
				return
			arrive = T + maxi(o.base + o.net_rng.randi_range(-o.jitter, o.jitter), 1)
		seq += 1
		queue.append({"arrive": arrive, "seq": seq, "from": from, "to": to, "env": env})

	func _pop_due(limit: int) -> Variant:
		var best := -1
		for i in queue.size():
			var q: Dictionary = queue[i]
			if int(q["arrive"]) > limit:
				continue
			if best < 0 or int(q["arrive"]) < int(queue[best]["arrive"]) \
					or (int(q["arrive"]) == int(queue[best]["arrive"]) and int(q["seq"]) < int(queue[best]["seq"])):
				best = i
		if best < 0:
			return null
		var msg: Dictionary = queue[best]
		queue.remove_at(best)
		return msg

	func _deliver(msg: Dictionary) -> void:
		var to: String = msg["to"]
		_transport_of(to).deliver(msg["env"], msg["from"])
		_collect(to)

	func pump_now() -> void:
		for _i in 2000:
			var msg: Variant = _pop_due(T)
			if msg == null:
				return
			T = maxi(T, int(msg["arrive"]))
			_deliver(msg)
		mk_check.call(false, "pump_now settles")

	# --- host game wiring ---

	func _on_joined(peer: String, slot: int) -> void:
		var eid := EID_BASE + slot
		var mass := 2.0 if slot == 1 else 1.0
		var inertia := 3.0 if slot == 1 else 1.0
		targets.set_owner(peer, eid, KIND7, mass, inertia, T)
		var sx := 100.0 * float(slot)
		host_world.set_entity(eid, KIND7, PackedFloat32Array([sx, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]))
		var map := CouchBodyChannels.new({"x": 0, "y": 1, "rot": 2, "vx": 3, "vy": 4, "w": 5})
		standins[peer] = {"eid": eid, "x": sx, "y": 0.0, "rot": 0.0, "vx": 0.0, "vy": 0.0, "w": 0.0,
			"mass": mass, "inertia": inertia, "rigid": slot == 1, "follower": CouchPDFollower.new(map, pol, 1.0 / 60.0), "extra": 0.0}
		acks[peer] = -1
		accepted[peer] = 0

	func _on_input(body: Dictionary, sender: String) -> void:
		ring.ack(sender, int(body.get("ev", 0)))
		if not targets.note_input(sender, body, T):
			return
		var tk := int(body["t"])
		acks[sender] = maxi(int(acks.get(sender, -1)), tk)
		echo.note_input(sender, tk, ticker.next_tick, T)
		accepted[sender] = int(accepted.get(sender, 0)) + 1
		var o: Variant = body.get("o")
		if typeof(o) == TYPE_PACKED_FLOAT32_ARRAY and (o as PackedFloat32Array).size() == 7:
			align_samples += 1
			if int((o as PackedFloat32Array)[6]) != int(body.get("ev", 0)):
				align_violations += 1
		if sender == KNOCK_PEER and knock_id >= 1 and cover_T < 0 and int(body.get("ev", 0)) >= knock_id:
			cover_T = T
			cover_comp = targets.compensation_of(sender, T)

	func _host_tick(tk: int, th: int) -> void:
		var knocked_now := false
		if knock and knock_tick < 0 and th >= KNOCK_MS and standins.has(KNOCK_PEER):
			knock_id = targets.push_impulse(ring, KNOCK_PEER, KNOCK_J, KNOCK_A, tk, T)
			knock_tick = tk
			knock_T = T
			knocked_now = true
		for peer in standins.keys():
			var s: Dictionary = standins[peer]
			var tgt := targets.target_for(peer, th)
			var cur := PackedFloat32Array([s["x"], s["y"], s["rot"], s["vx"], s["vy"], s["w"], s["extra"]])
			var r: Dictionary = (s["follower"] as CouchPDFollower).step(cur, tgt)
			var snapped: Variant = r.get("snap")
			if typeof(snapped) == TYPE_BOOL and snapped:
				var pos: Variant = r.get("pos")
				var vel: Variant = r.get("vel")
				if typeof(pos) == TYPE_VECTOR2 and typeof(vel) == TYPE_VECTOR2:
					s["x"] = pos.x
					s["y"] = pos.y
					s["vx"] = vel.x
					s["vy"] = vel.y
					s["rot"] = float(r.get("rot", 0.0))
					s["w"] = float(r.get("w", 0.0))
			elif s["rigid"]:
				var fz: Dictionary = CouchPDFollower.force_from(r, s["mass"], s["inertia"])
				var fv: Variant = fz.get("force")
				if typeof(fv) == TYPE_VECTOR2:
					s["vx"] += fv.x / s["mass"] * (1.0 / 60.0)
					s["vy"] += fv.y / s["mass"] * (1.0 / 60.0)
				s["w"] += float(fz.get("torque", 0.0)) / s["inertia"] * (1.0 / 60.0)
			else:
				var va: Dictionary = CouchPDFollower.velocity_after(r, Vector2(s["vx"], s["vy"]), s["w"], 1.0 / 60.0)
				var lin: Variant = va.get("linear")
				if typeof(lin) == TYPE_VECTOR2:
					s["vx"] = lin.x
					s["vy"] = lin.y
				s["w"] = float(va.get("angular", s["w"]))
			# Direct-apply: host physics adds dv during the knock step, AFTER the spring's velocity
			# update. Added before it, the kick is erased in the same step (at the clamped default
			# omega 2 * w * dt == 1, so the spring sets v to the target velocity every step).
			if knocked_now and direct and peer == KNOCK_PEER:
				s["vx"] += KNOCK_J.x / float(s["mass"])
				s["vy"] += KNOCK_J.y / float(s["mass"])
				s["w"] += KNOCK_A / float(s["inertia"])
			if not (snapped is bool and snapped):
				s["x"] += s["vx"] / 60.0
				s["y"] += s["vy"] / 60.0
				s["rot"] = wrapf(s["rot"] + s["w"] / 60.0, -PI, PI)
			s["extra"] = tgt[6] if tgt.size() == 7 else 0.0
			host_world.set_entity(int(s["eid"]), KIND7, PackedFloat32Array([s["x"], s["y"], s["rot"], s["vx"], s["vy"], s["w"], s["extra"]]))
			if peer == KNOCK_PEER:
				track.append([tk, float(s["x"]), float(s["y"])])

	func host_snapshot(th: int) -> void:
		var body := host_world.pack(ticker.next_tick - 1, th, acks, echo, ring, {})
		host_session.broadcast_snapshot(body)
		_collect(HOST_ID)

	func _host_frame(th: int) -> void:
		next_host_t = th + maxi(16 + host_rng.randi_range(-4, 4), 1)
		var before := ticker.next_tick
		ticker.advance(th)
		for tk in range(before, ticker.next_tick):
			_host_tick(tk, th)
		var last := ticker.next_tick - 1
		if ticker.started and last >= next_snap and last >= 0:
			host_snapshot(th)
			next_snap = last + 2

	# --- owners ---

	func _on_snapshot(body: Dictionary, o: _Own) -> void:
		if not o.world.ingest(body):
			return
		var ps := o.world.peer_section(o.id)
		if ps.is_empty():
			return
		var cn := T + o.offset_ms
		o.clock.on_snapshot(int(ps["ht"]), cn)
		if ps.has("rt"):
			o.clock.on_echo(int(ps["rt"]), int(ps["hm"]), int(ps["mg"]), cn)
		o.ev_latest = ps["ev"]

	## One owner tick in the ALIGNMENT order: receive + apply events, step, THEN input_fields.
	func owner_tick(o: _Own, tk: int) -> void:
		if tk == o.wall_tick:
			o.vx = 0.0
			o.vy = 0.0
			o.w = 0.0
		for e in o.inbox.receive(o.ev_latest):
			var imp: Dictionary = CouchOwnedEntity.impulse_of(e)
			var j: Variant = imp.get("j")
			if typeof(j) != TYPE_VECTOR2:
				continue
			o.vx += j.x / o.mass
			o.vy += j.y / o.mass
			o.w += float(imp.get("a", 0.0)) / o.inertia
			o.applied_count += 1
			o.applied_ids.append(int(e[0]))
			o.apply_tick = tk
			if o.wall:
				o.wall_tick = tk + 1
		var t := float(tk) / 60.0
		var ux := o.amp_x * o.om_x * cos(o.om_x * t)
		var uy := o.amp_y * o.om_y * cos(o.om_y * t + 1.0)
		o.vx += (ux - o.vx) * 6.0 / 60.0
		o.vy += (uy - o.vy) * 6.0 / 60.0
		o.w += (o.w_nom - o.w) * 6.0 / 60.0
		o.x += o.vx / 60.0
		o.y += o.vy / 60.0
		o.rot = wrapf(o.rot + o.w / 60.0, -PI, PI)
		o.hist.append([tk, o.x, o.y])
		var state := PackedFloat32Array([o.x, o.y, o.rot, o.vx, o.vy, o.w, float(o.applied_count)])
		var fields: Dictionary = o.owned.input_fields(tk, state, o.inbox)
		if fields.is_empty():
			return
		o.session.send_input(fields)
		_collect(o.id)

	func _owner_frame(o: _Own, tc: int) -> void:
		o.next_t = tc + maxi(16 + o.frame_rng.randi_range(-4, 4), 1)
		for tk in o.clock.advance(tc + o.offset_ms):
			owner_tick(o, int(tk))

	func run_until(end_t: int) -> void:
		while true:
			var best := FAR_T
			var kind := -1
			var which := ""
			for q in queue:
				if int(q["arrive"]) < best:
					best = int(q["arrive"])
					kind = 1
			if next_host_t < best:
				best = next_host_t
				kind = 2
			for id in owners:
				if (owners[id] as _Own).next_t < best:
					best = (owners[id] as _Own).next_t
					kind = 3
					which = id
			if kind < 0 or best > end_t:
				break
			T = maxi(T, best)
			match kind:
				1:
					var m: Variant = _pop_due(T)
					if m != null:
						_deliver(m)
				2:
					_host_frame(T)
				3:
					_owner_frame(owners[which], T)
		T = maxi(T, end_t)


# --- M: running twins and measuring ----------------------------------------------------------


const SEED := 5151
const RTTS := [50, 150, 250]

## Baselines (no knock) per RTT, shared by every scenario at that RTT; wall baselines are separate.
var _baselines: Dictionary = {}


## One sim run. `opts`: knock, comp, tau, direct, wall, wall_tick.
func _sim_run(rtt: int, opts: Dictionary) -> _MSim:
	var sim := _MSim.new(SEED, int(rtt / 2.0))
	sim.mk_check = _check
	sim.knock = bool(opts.get("knock", false))
	sim.direct = bool(opts.get("direct", false))
	sim.targets.impulse_compensation = bool(opts.get("comp", true))
	sim.targets.impulse_tau_ms = int(opts.get("tau", TAU))
	var p1: _Own = sim.owners[KNOCK_PEER]
	p1.wall = bool(opts.get("wall", false))
	p1.wall_tick = int(opts.get("wall_tick", -1))
	sim.boot()
	sim.run_until(KNOCK_MS + AFTER_MS)
	return sim


func _baseline(rtt: int) -> _MSim:
	if not _baselines.has(rtt):
		_baselines[rtt] = _sim_run(rtt, {})
	return _baselines[rtt]


## Retreat / overshoot / lag50 of a displacement series [[tick, d], ...] starting at tick0.
func _metrics(series: Array, tick0: int) -> Dictionary:
	if series.is_empty():
		return {"ok": false, "final": 0.0, "retreat": INF, "overshoot": INF, "lag50": INF, "peak": 0.0}
	var final: float = series[series.size() - 1][1]
	var peak := -INF
	var retreat := 0.0
	var dmax := -INF
	var lag := INF
	for p in series:
		var d: float = p[1]
		peak = maxf(peak, d)
		retreat = maxf(retreat, peak - d)
		dmax = maxf(dmax, d)
		if lag == INF and final > 0.0 and d >= 0.5 * final:
			lag = (int(p[0]) - tick0) * MS_PER_TICK
	return {"ok": true, "final": final, "retreat": retreat, "overshoot": dmax - final, "lag50": lag, "peak": dmax}


## Compare a knock run with its baseline twin. Returns the stand-in and owner metrics plus
## "pre_equal" (stand-in and owner identical before the knock / apply) and "len_ok".
func _measure(k: _MSim, b: _MSim) -> Dictionary:
	var dir := KNOCK_J.normalized()
	var out := {"len_ok": k.track.size() == b.track.size() and k.track.size() > 0, "pre_equal": true, "pre_n": 0}
	var series: Array = []
	if out["len_ok"]:
		for i in k.track.size():
			var a: Array = k.track[i]
			var c: Array = b.track[i]
			if int(a[0]) != int(c[0]):
				out["len_ok"] = false
				break
			var diff := Vector2(float(a[1]) - float(c[1]), float(a[2]) - float(c[2]))
			if k.knock_tick < 0 or int(a[0]) < k.knock_tick:
				out["pre_n"] = int(out["pre_n"]) + 1
				if diff != Vector2.ZERO:
					out["pre_equal"] = false
			else:
				series.append([int(a[0]), diff.dot(dir)])
	out["s"] = _metrics(series, k.knock_tick)
	var ko: _Own = k.owners[KNOCK_PEER]
	var bo: _Own = b.owners[KNOCK_PEER]
	var oser: Array = []
	var n := mini(ko.hist.size(), bo.hist.size())
	for i in n:
		var a: Array = ko.hist[i]
		var c: Array = bo.hist[i]
		if int(a[0]) != int(c[0]):
			out["len_ok"] = false
			break
		var diff := Vector2(float(a[1]) - float(c[1]), float(a[2]) - float(c[2]))
		if ko.apply_tick < 0 or int(a[0]) < ko.apply_tick:
			if diff != Vector2.ZERO:
				out["pre_equal"] = false
		else:
			oser.append([int(a[0]), diff.dot(dir)])
	out["o"] = _metrics(oser, ko.apply_tick)
	out["cover_ms"] = k.cover_T - k.knock_T if k.cover_T >= 0 and k.knock_T >= 0 else -1
	return out


func _row(label: String, m: Dictionary) -> String:
	var s: Dictionary = m["s"]
	return "%-34s retreat %6.2f  overshoot %6.2f  lag50 %6.1f ms  final %6.2f  (owner final %6.2f, owner lag50 %5.1f ms, cover %d ms)" % [
		label, s["retreat"], s["overshoot"], s["lag50"], s["final"], (m["o"] as Dictionary)["final"], (m["o"] as Dictionary)["lag50"], m["cover_ms"]]


# --- M1: measurement ------------------------------------------------------------------------

# BOUNDS. Set from a reference run of an on-contract implementation (outside the repo), with
# headroom; the measured values are printed in every message and the table goes to the log.
# Reference (on, both modes, RTT 50 / 150 / 250): retreat <= 0.26, overshoot 0.00, lag50
# 100-117 ms against the owner's own 100 ms, final == the owner's 30.00. Off: lag50 150 / 250 /
# 333 ms; off with direct-apply retreats 2.3-3.3 (the spring pulls the kick back). Dropping the
# lead at the cover instead of handing it off shows here as a stall rather than a big retreat
# (the covering report carries ~0.9 dv, so the spring's feed-forward waits for the target):
# retreat 1.33 at RTT 250, hence the 1.0 bound.
const ON_RETREAT_MAX := 1.0
const ON_OVERSHOOT_MAX := 1.0
const ON_LAG_OVER_OWNER_MAX := 34.0   # ms above the owner's own lag50 (two ticks)
const ON_LAG_SPREAD_MAX := 34.0       # ms between the best and worst RTT (two ticks)
const OFF_LAG_GROWTH_MIN := 150.0     # ms, RTT 250 vs RTT 50
const FINAL_TOL := 1.0                # units, stand-in vs owner final displacement


func _case_m1() -> void:
	print("M1: knock measurement, RTT 50 / 150 / 250, compensation off vs on, target-only vs direct-apply")
	var table: Array = []
	var res: Dictionary = {}
	for rtt in RTTS:
		var b := _baseline(rtt)
		for comp in [false, true]:
			for direct in [false, true]:
				var k := _sim_run(rtt, {"knock": true, "comp": comp, "direct": direct})
				var m := _measure(k, b)
				var key := "%d/%s/%s" % [rtt, "on" if comp else "off", "direct" if direct else "target"]
				res[key] = m
				table.append(_row("RTT %3d  %-3s  %-11s" % [rtt, "on" if comp else "off", "direct" if direct else "target-only"], m))
				_check(m["len_ok"] and m["pre_equal"] and int(m["pre_n"]) > 200 and k.knock_id == 1,
					"M1 %s: the twins agree exactly before the knock (%d host ticks, owner ticks before the apply) and the knock was pushed (id %d)" % [key, m["pre_n"], k.knock_id])
				if rtt == RTTS[0] and not comp and not direct:
					var p1: _Own = k.owners[KNOCK_PEER]
					_check(p1.dropped > 5 and (k.owners["p2"] as _Own).dropped > 5,
						"M1: the links really are lossy (dropped p1 %d / p2 %d)" % [p1.dropped, (k.owners["p2"] as _Own).dropped])
	print("  M1 table (displacement projected on J; |dv| 200, owner decay ~160 ms, impulse_tau_ms %d):" % TAU)
	for line in table:
		print("    " + line)
	for rtt in RTTS:
		for mode in ["target", "direct"]:
			var on: Dictionary = res["%d/on/%s" % [rtt, mode]]
			var s: Dictionary = on["s"]
			var o: Dictionary = on["o"]
			_check(float(s["retreat"]) <= ON_RETREAT_MAX and float(s["overshoot"]) <= ON_OVERSHOOT_MAX,
				"M1 RTT %d on/%s: retreat %.2f <= %.1f and overshoot %.2f <= %.1f" % [rtt, mode, s["retreat"], ON_RETREAT_MAX, s["overshoot"], ON_OVERSHOOT_MAX])
			_check(float(s["lag50"]) <= float(o["lag50"]) + ON_LAG_OVER_OWNER_MAX,
				"M1 RTT %d on/%s: lag50 %.1f ms is within %.0f ms of the owner's own %.1f ms" % [rtt, mode, s["lag50"], ON_LAG_OVER_OWNER_MAX, o["lag50"]])
			_check(absf(float(s["final"]) - float(o["final"])) <= FINAL_TOL and float(o["final"]) > 25.0,
				"M1 RTT %d on/%s: the stand-in ends at the owner's displacement (%.2f vs %.2f)" % [rtt, mode, s["final"], o["final"]])
	for mode in ["target", "direct"]:
		var lags_on: Array = []
		var lags_off: Array = []
		for rtt in RTTS:
			lags_on.append(float((res["%d/on/%s" % [rtt, mode]]["s"] as Dictionary)["lag50"]))
			lags_off.append(float((res["%d/off/%s" % [rtt, mode]]["s"] as Dictionary)["lag50"]))
		_check(lags_off[0] < lags_off[1] and lags_off[1] < lags_off[2] and lags_off[2] - lags_off[0] >= OFF_LAG_GROWTH_MIN,
			"M1 off/%s: lag50 grows with RTT (%.1f / %.1f / %.1f ms, +%.1f >= %.0f): the measurement sees the delay" % [mode, lags_off[0], lags_off[1], lags_off[2], lags_off[2] - lags_off[0], OFF_LAG_GROWTH_MIN])
		var spread: float = lags_on.max() - lags_on.min()
		_check(spread <= ON_LAG_SPREAD_MAX and lags_on[2] < lags_off[2],
			"M1 on/%s: lag50 does not grow with RTT (%.1f / %.1f / %.1f ms, spread %.1f <= %.0f) and beats off at RTT 250 (%.1f)" % [mode, lags_on[0], lags_on[1], lags_on[2], spread, ON_LAG_SPREAD_MAX, lags_off[2]])


# --- M2: model mismatch ---------------------------------------------------------------------

## Allowance on top of |dv| * tau * (1 - exp(-RTT / tau)): step 1's own extrapolation of the
## covering report, which carries ~0.9 dv for up to extrapolate_cap_ms (the wall case WITHOUT
## compensation already overshoots by up to 4.8), plus the covering report's tick of the impulse.
## Reference: worst excess over the bare bound 3.43 (wall, RTT 50).
const M2_SLACK := 6.0


func _m2_bound(tau_ms: int, cover_ms: int) -> float:
	var tau := _tau_s(tau_ms)
	return 200.0 * tau * (1.0 - exp(-(maxi(cover_ms, 0) / 1000.0) / tau))


func _case_m2() -> void:
	print("M2: model mismatch (impulse_tau_ms 60 / 167 / 500 vs the owner's ~160 ms decay) and a wall")
	var table: Array = []
	for rtt in RTTS:
		var b := _baseline(rtt)
		for tau in [60, 167, 500]:
			var k := _sim_run(rtt, {"knock": true, "comp": true, "tau": tau})
			var m := _measure(k, b)
			var s: Dictionary = m["s"]
			var o: Dictionary = m["o"]
			var bound := _m2_bound(tau, int(m["cover_ms"]))
			table.append(_row("RTT %3d  tau %3d" % [rtt, tau], m) + "  bound %.2f" % bound)
			_check(m["len_ok"] and m["pre_equal"] and int(m["cover_ms"]) > 0 and float(s["overshoot"]) <= bound + M2_SLACK,
				"M2 RTT %d tau %d: overshoot %.2f <= |dv| tau (1 - exp(-%d ms / tau)) = %.2f + %.1f" % [rtt, tau, s["overshoot"], m["cover_ms"], bound, M2_SLACK])
			_check(absf(float(s["final"]) - float(o["final"])) <= FINAL_TOL,
				"M2 RTT %d tau %d: re-converges to the owner's displacement (%.2f vs %.2f)" % [rtt, tau, s["final"], o["final"]])
		# The wall: velocity zeroed one tick after the apply, in both twins.
		for comp in [false, true]:
			var kw := _sim_run(rtt, {"knock": true, "comp": comp, "wall": true})
			var wt: int = (kw.owners[KNOCK_PEER] as _Own).wall_tick
			var bw := _sim_run(rtt, {"wall_tick": wt})
			var mw := _measure(kw, bw)
			var sw: Dictionary = mw["s"]
			var ow: Dictionary = mw["o"]
			var bound_w := _m2_bound(TAU, int(mw["cover_ms"]))
			table.append(_row("RTT %3d  wall %-3s" % [rtt, "on" if comp else "off"], mw) + "  bound %.2f" % bound_w)
			if comp:
				_check(wt > 0 and mw["len_ok"] and mw["pre_equal"] and float(ow["final"]) > 1.0 and float(ow["final"]) < 5.0,
					"M2 RTT %d wall: the owner stopped one tick after the apply (tick %d; owner displacement %.2f, one tick of dv)" % [rtt, wt, ow["final"]])
				_check(float(sw["overshoot"]) <= bound_w + M2_SLACK and float(sw["peak"]) > float(ow["final"]) + 0.25 * bound_w,
					"M2 RTT %d wall: the predicted displacement overshoots (peak %.2f) but within the bound: overshoot %.2f <= %.2f + %.1f" % [rtt, sw["peak"], sw["overshoot"], bound_w, M2_SLACK])
				_check(absf(float(sw["final"]) - float(ow["final"])) <= FINAL_TOL,
					"M2 RTT %d wall: ...and drifts back to the owner's displacement (%.2f vs %.2f)" % [rtt, sw["final"], ow["final"]])
	print("  M2 table:")
	for line in table:
		print("    " + line)


# --- M3: exactly once, alignment, hand-off at the real cover ---------------------------------


func _case_m3() -> void:
	print("M3: exactly-once apply, ALIGNMENT RULE and the hand-off with compensation on")
	for rtt in RTTS:
		var k := _sim_run(rtt, {"knock": true, "comp": true})
		var p1: _Own = k.owners[KNOCK_PEER]
		var p2: _Own = k.owners["p2"]
		_check(k.knock_id == 1 and p1.applied_ids == [1] and p1.applied_count == 1 and p2.applied_count == 0 and k.ring.pending_for(KNOCK_PEER).is_empty(),
			"M3 RTT %d: p1 applied the impulse exactly once (applied ids %s), p2 none, the ack reached the ring" % [rtt, p1.applied_ids])
		_check(k.align_violations == 0 and k.align_samples > 500,
			"M3 RTT %d: ALIGNMENT RULE holds in every accepted input (%d violations in %d)" % [rtt, k.align_violations, k.align_samples])
		var t := k.targets
		_check(t.covered_ev(KNOCK_PEER) == 1 and t.covered_ev("p2") == 0,
			"M3 RTT %d: covered_ev p1 %d (== 1), p2 %d (== 0)" % [rtt, t.covered_ev(KNOCK_PEER), t.covered_ev("p2")])
		var cover_ms := k.cover_T - k.knock_T
		var e := _ho(KNOCK_J / 2.0, KNOCK_A / 3.0, cover_ms, 0)
		_check(k.cover_T > 0 and _comp_ok(k.cover_comp, e),
			"M3 RTT %d: right after the first accepted report with ev >= 1 (%d ms after the push) the entry is handed off: %s (got %s)" % [rtt, cover_ms, _fmt(e), k.cover_comp])
		_check(t.pending_impulse_count(KNOCK_PEER) == 0 and t.impulse_timeout_count(KNOCK_PEER) == 0 and _comp_ok(t.compensation_of(KNOCK_PEER, k.T), _zero()),
			"M3 RTT %d: at the end the entry has been dropped (pending %d), no timeout (%d), zero compensation" % [rtt, t.pending_impulse_count(KNOCK_PEER), t.impulse_timeout_count(KNOCK_PEER)])


# --- driver ---------------------------------------------------------------------------------


func _section(label: String, fn: Callable) -> void:
	var before := _checks
	fn.call()
	print("  [%s: %d checks]" % [label, _checks - before])


func _run() -> void:
	_section("U1", _case_u1)
	_section("U2", _case_u2)
	_section("U3", _case_u3)
	_section("U4", _case_u4)
	_section("U5", _case_u5)
	_section("M1", _case_m1)
	_section("M2", _case_m2)
	_section("M3", _case_m3)

	print("")
	print("G17 impulse compensation: %d/%d checks passed" % [_checks - failures, _checks])
	if failures > 0:
		printerr("IMPULSE_COMPENSATION_FAILED: %d check(s)" % failures)
	quit(1 if failures > 0 else 0)
	return
