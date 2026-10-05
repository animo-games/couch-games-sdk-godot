## Headless gate for owner-authority helpers -- gate G16.
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_owner_authority.gd
##
## What this proves. Each player simulates their own entity and reports its full 0d kind
## state in its `input`; the host keeps a STAND-IN body per owner and drives it toward the
## report with a critically damped spring. CouchBodyChannels says which state index is
## position / velocity / rotation. CouchPDFollower is the spring maths (acceleration out,
## a snap flag past a distance / angle), CouchOwnerTargets is the host's per-peer ledger
## (ownership, validation, extrapolated target, staleness, impulse pushes), and
## CouchOwnedEntity is the owner's side (input fields, impulse decoding). The gate tests the
## frozen API CONTRACT (docs/plans/owner-authority-step1-design.md, final section), not any
## implementation: it is written test-first against inert stubs, and every check is guarded
## so a stub (or a wrong-typed return) produces FAIL lines, never a script error.
##
## Cases:
##   P1  follower maths: omega / clamp / effective settle, policy edits, exact accel / alpha
##       against the formula (with a permuted channel map), empty / bad input handling and
##       bad_input_count, snap boundary (strictly above) and snap result contents (copies),
##       toy symplectic-Euler bodies: critically damped, settles in time, no overshoot, the
##       clamped case is stable, velocity feed-forward, rotation short arc across +/-PI.
##   P2  force_from / velocity_after, including the snap branch.
##   C1  CouchBodyChannels validity (each rule broken on its own), has_rotation, fits()
##       against LERP / ANGLE layouts; CouchReplicatedWorld.kind_channels returns a copy.
##   T1  CouchOwnerTargets: set_channels / set_owner refusals, every reject reason (one case
##       per step and first-failure-wins pairs), a rejection changes nothing, copies,
##       extrapolation exact numbers, cap boundary, HOLD vs REPORT_ONLY, staleness boundary
##       and clock start, stale_gap_count, forget / reset, accessors, push_impulse.
##   O1  CouchOwnedEntity.input_fields: keys, copy, "ev" from the inbox, refusals.
##   I1  impulse_of round trip (ring -> inbox, and ring -> pack -> ingest -> inbox) + refusals.
##   S1  end to end: a host + 3 owners as REAL CouchSessions (max_input_players 3) over seeded
##       lossy / jittery / reordering links, CouchNetClock on each owner, CouchReplicatedWorld
##       + CouchEventRing / CouchEventInbox, toy integrator bodies. The game wiring of the
##       contract is followed literally, including the ALIGNMENT RULE. Asserts effects:
##       stand-ins converge to the owners' true paths, a host impulse is applied by exactly
##       one owner exactly once and acked, an input's "o" reflects every event <= its "ev",
##       a teleport snaps the stand-in once, owners never sample their own entity, and the
##       other owners' view tracks the host stand-ins.
##   S2  a player leaves (0b player_left) and rejoins; a new epoch resets everything.
##
## HARNESS (`_OSim`). Entirely synchronous and deterministic: fixed seeds, no WebRTC, no
## await, no real clock, nothing reads Time. Every participant is a CouchScriptedRoster +
## CouchScriptedTransport + a real CouchSession (G13's scripted star); envelopes are routed
## through a seeded delay / loss queue instead of G13's instant pump, then delivered raw.
##
## LOAD-BEARING GOTCHA: SceneTree.quit(code) only SCHEDULES termination; it does not
## return. `return` follows the one quit(...) in this file.
extends SceneTree

const LERP := CouchReplicatedWorld.LERP
const ANGLE := CouchReplicatedWorld.ANGLE
const SNAP := CouchReplicatedWorld.SNAP
const DT := 1.0 / 60.0
## Kinds used by the unit sections (all registered on the same world).
const KIND6 := 1    # [x, y, rot, vx, vy, w]
const KIND_NR := 3  # [x, y, vx, vy]  (no rotation)
const KIND7 := 4    # [x, y, rot, vx, vy, w, extra(SNAP)]
const KIND_FREE := 9  # registered in the world, never given set_channels
const INT_MAX := 2147483647
const REASONS := ["unowned", "bad-shape", "bad-stride", "non-finite", "stale-tick"]

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


## dict[key] or null when `v` is not a Dictionary / lacks the key.
func _dg(v: Variant, key: Variant) -> Variant:
	if typeof(v) == TYPE_DICTIONARY and (v as Dictionary).has(key):
		return (v as Dictionary)[key]
	return null


## The number as a float, NAN when `v` is not an int / float.
func _num(v: Variant) -> float:
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return float(v)
	return NAN


## 0.0 unless `v` is an int / float (for toy integrators fed by possibly-broken results).
func _numz(v: Variant) -> float:
	var f := _num(v)
	return 0.0 if is_nan(f) else f


func _isf(v: Variant) -> bool:
	return typeof(v) == TYPE_FLOAT


func _close(v: Variant, e: float, tol: float = 1e-4) -> bool:
	var f := _num(v)
	return not is_nan(f) and absf(f - e) <= tol * maxf(1.0, absf(e))


func _v2close(v: Variant, e: Vector2, tol: float = 1e-4) -> bool:
	return typeof(v) == TYPE_VECTOR2 and _close((v as Vector2).x, e.x, tol) and _close((v as Vector2).y, e.y, tol)


func _is_pf(v: Variant) -> bool:
	return typeof(v) == TYPE_PACKED_FLOAT32_ARRAY


func _pfclose(v: Variant, e: Array, tol: float = 1e-4) -> bool:
	if not _is_pf(v):
		return false
	var pa: PackedFloat32Array = v
	if pa.size() != e.size():
		return false
	for i in e.size():
		if not _close(pa[i], float(e[i]), tol):
			return false
	return true


func _at(v: Variant, i: int) -> float:
	if _is_pf(v) and i >= 0 and i < (v as PackedFloat32Array).size():
		return (v as PackedFloat32Array)[i]
	return NAN


func _psize(v: Variant) -> int:
	return (v as PackedFloat32Array).size() if _is_pf(v) else -1


func _bool_is(v: Variant, e: bool) -> bool:
	return typeof(v) == TYPE_BOOL and v == e


func _int_is(v: Variant, e: int) -> bool:
	return typeof(v) == TYPE_INT and v == e


func _wrap(v: float) -> float:
	return wrapf(v, -PI, PI)


## True iff `r` is the contract's zero result: {snap:false, accel:ZERO, alpha:0.0}.
func _is_zero_result(r: Variant) -> bool:
	return _bool_is(_dg(r, "snap"), false) and typeof(_dg(r, "accel")) == TYPE_VECTOR2 \
		and (_dg(r, "accel") as Vector2) == Vector2.ZERO and _isf(_dg(r, "alpha")) and _dg(r, "alpha") == 0.0


## Independent re-implementation of the contract's omega formula.
func _om(settle_ms: float, dt: float) -> float:
	var d := dt if dt > 0.0 else 1.0 / 60.0
	return minf(4.74 / (maxf(settle_ms, 1.0) / 1000.0), 0.5 / d)


func _map6() -> CouchBodyChannels:
	return CouchBodyChannels.new({"x": 0, "y": 1, "rot": 2, "vx": 3, "vy": 4, "w": 5})


func _map4() -> CouchBodyChannels:
	return CouchBodyChannels.new({"x": 0, "y": 1, "vx": 2, "vy": 3})


## A permuted map over a 6-slot state: nothing is where the identity map would put it.
func _mapx() -> CouchBodyChannels:
	return CouchBodyChannels.new({"x": 4, "y": 2, "rot": 0, "vx": 5, "vy": 1, "w": 3})


func _fol(map: CouchBodyChannels, p: CouchPDFollowerPolicy, dt: float = DT) -> CouchPDFollower:
	return CouchPDFollower.new(map, p, dt)


## A policy that never snaps and has the given settle times.
func _pol(settle_ms: float, rot_settle_ms: float) -> CouchPDFollowerPolicy:
	var p := CouchPDFollowerPolicy.new()
	p.settle_ms = settle_ms
	p.rot_settle_ms = rot_settle_ms
	p.snap_distance = 1.0e9
	p.snap_angle = 1.0e9
	return p


## World with kinds 1 [L,L,A,L,L,L], 3 [L,L,L,L], 4 [L,L,A,L,L,L,SNAP], 9 [L,L,A,L,L,L].
func _new_world() -> CouchReplicatedWorld:
	var w := CouchReplicatedWorld.new()
	w.register_kind(KIND6, [LERP, LERP, ANGLE, LERP, LERP, LERP])
	w.register_kind(KIND_NR, [LERP, LERP, LERP, LERP])
	w.register_kind(KIND7, [LERP, LERP, ANGLE, LERP, LERP, LERP, SNAP])
	w.register_kind(KIND_FREE, [LERP, LERP, ANGLE, LERP, LERP, LERP])
	return w


## Targets with channel maps set for kinds 1, 3, 4 (not 9).
func _new_targets(w: CouchReplicatedWorld) -> CouchOwnerTargets:
	var t := CouchOwnerTargets.new(w)
	t.set_channels(KIND6, _map6())
	t.set_channels(KIND_NR, _map4())
	t.set_channels(KIND7, _map6())
	return t


const BASE_O := [10.0, -4.0, 3.0, 20.0, -40.0, 2.0]


## A well-formed KIND6 input body.
func _b6(tick: Variant, vals: Array = BASE_O) -> Dictionary:
	return {"t": tick, "o": _pf(vals), "ev": 0}


## Targets with peer "a" owning entity 10 (KIND6, mass 2, inertia 3, set at now 0).
func _owner_a() -> CouchOwnerTargets:
	var t := _new_targets(_new_world())
	t.set_owner("a", 10, KIND6, 2.0, 3.0, 0)
	return t


# --- P1: follower maths -------------------------------------------------------------------


func _case_p1() -> void:
	print("P1: CouchPDFollower maths")
	var P := CouchPDFollowerPolicy
	_check(P.SETTLE_K == 4.74 and P.MAX_W_DT == 0.5, "P1: policy consts SETTLE_K 4.74, MAX_W_DT 0.5")
	var dp := CouchPDFollowerPolicy.new()
	_check(dp.settle_ms == 150.0 and dp.rot_settle_ms == 100.0 and dp.snap_distance == 256.0 and dp.snap_angle == PI,
		"P1: policy defaults 150 / 100 ms, snap 256 units, snap_angle PI")

	# omega, clamp, effective settle.
	var p := _pol(50.0, 50.0)
	var f := _fol(_map6(), p)
	_check(_close(f.omega(), 30.0, 1e-9) and _close(f.rot_omega(), 30.0, 1e-9),
		"P1: settle 50 ms at dt 1/60 is clamped to omega 30 (MAX_W_DT / dt), not 94.8: %s / %s" % [f.omega(), f.rot_omega()])
	_check(_close(f.effective_settle_ms(), 4.74 / 30.0 * 1000.0, 1e-6) and _close(f.effective_rot_settle_ms(), 158.0, 1e-3),
		"P1: effective settle of the clamped case is 4.74 / 30 s = 158 ms")
	p = _pol(200.0, 300.0)
	f = _fol(_map6(), p)
	_check(_close(f.omega(), 23.7, 1e-9) and _close(f.rot_omega(), 4.74 / 0.3, 1e-9),
		"P1: unclamped omega = 4.74 / settle_s (200 ms -> 23.7, rot 300 ms -> 15.8): %s / %s" % [f.omega(), f.rot_omega()])
	_check(_close(f.effective_settle_ms(), 200.0, 1e-6) and _close(f.effective_rot_settle_ms(), 300.0, 1e-6),
		"P1: unclamped effective settle equals the configured settle")
	f = _fol(_map6(), CouchPDFollowerPolicy.new())
	_check(_close(f.omega(), 30.0, 1e-9) and _close(f.rot_omega(), 30.0, 1e-9),
		"P1: default policy at 60 Hz: 150 ms -> 31.6 clamps to 30, 100 ms -> 47.4 clamps to 30")
	f = _fol(_map6(), _pol(50.0, 50.0), 1.0 / 120.0)
	_check(_close(f.omega(), 60.0, 1e-9), "P1: dt 1/120 raises the clamp to 60 (MAX_W_DT / dt), %s" % f.omega())
	f = _fol(_map6(), _pol(1000.0, 1000.0), 1.0 / 30.0)
	_check(_close(f.omega(), 4.74, 1e-9) and _close(f.rot_omega(), 4.74, 1e-9), "P1: a slow settle (1000 ms) at dt 1/30 is unclamped: 4.74")
	f = _fol(_map6(), _pol(100.0, 100.0), 1.0 / 30.0)
	_check(_close(f.omega(), 15.0, 1e-9), "P1: settle 100 ms at dt 1/30 clamps to 0.5 * 30 = 15")
	f = _fol(_map6(), _pol(0.0, 50.0), 0.0001)
	_check(_close(f.omega(), 4740.0, 1e-9), "P1: settle_ms 0 is clamped to 1 ms: omega 4.74 / 0.001 = 4740 (below the 5000 dt clamp), %s" % f.omega())
	f = _fol(_map6(), _pol(-5.0, 50.0), 0.0001)
	_check(_close(f.omega(), 4740.0, 1e-9), "P1: a negative settle_ms is clamped to 1 ms too")
	f = _fol(_map6(), _pol(0.5, 50.0), 0.0001)
	_check(_close(f.omega(), 4740.0, 1e-9), "P1: settle_ms 0.5 is clamped up to 1.0 as well")
	f = _fol(_map6(), _pol(50.0, 50.0), 0.0)
	_check(_close(f.omega(), 30.0, 1e-9), "P1: physics_dt 0 is treated as 1/60 (omega 30, not 94.8 or inf)")
	f = _fol(_map6(), _pol(50.0, 50.0), -0.01)
	_check(_close(f.omega(), 30.0, 1e-9), "P1: a negative physics_dt is treated as 1/60")
	f = _fol(_map6(), _pol(400.0, 400.0), 0.0)
	_check(_close(f.omega(), 11.85, 1e-9), "P1: dt 0 with settle 400 ms: 11.85 (unclamped)")

	# Exact accel / alpha with a permuted channel map.
	p = _pol(200.0, 300.0)
	f = _fol(_mapx(), p)
	var c := [0.3, 2.0, -1.0, 0.5, 5.0, 3.0]   # rot, vy, y, w, x, vx
	var t := [0.8, 3.5, 4.0, 1.5, 8.0, -2.0]
	var r: Dictionary = f.step(_pf(c), _pf(t))
	var w := _om(200.0, DT)
	var wr := _om(300.0, DT)
	var ep := Vector2(8.0 - 5.0, 4.0 - -1.0)
	var ev := Vector2(-2.0 - 3.0, 3.5 - 2.0)
	var accel := w * w * ep + 2.0 * w * ev
	var alpha := wr * wr * (_wrap(0.8 - 0.3)) + 2.0 * wr * (1.5 - 0.5)
	_check(_bool_is(_dg(r, "snap"), false) and _v2close(_dg(r, "accel"), accel) and _close(_dg(r, "alpha"), alpha),
		"P1: exact accel = w^2 * ep + 2w * dv and alpha = wr^2 * er + 2wr * dw through a permuted map: %s / %s, expected %s / %s" % [_dg(r, "accel"), _dg(r, "alpha"), accel, alpha])
	_check(typeof(_dg(r, "accel")) == TYPE_VECTOR2 and _isf(_dg(r, "alpha")), "P1: accel is a Vector2 and alpha a float")
	# Position-only error / velocity-only error isolate the two terms.
	r = f.step(_pf([0.0, 0.0, 0.0, 0.0, 0.0, 0.0]), _pf([0.0, 0.0, 0.0, 0.0, 2.0, 0.0]))  # x idx 4 -> ex = 2
	_check(_v2close(_dg(r, "accel"), Vector2(w * w * 2.0, 0.0)) and _close(_dg(r, "alpha"), 0.0),
		"P1: a pure x error (index 4) gives accel (w^2 * 2, 0)")
	r = f.step(_pf([0.0, 0.0, 0.0, 0.0, 0.0, 0.0]), _pf([0.0, 1.0, 0.0, 0.0, 0.0, 0.0]))  # vy idx 1
	_check(_v2close(_dg(r, "accel"), Vector2(0.0, 2.0 * w * 1.0)) and _close(_dg(r, "alpha"), 0.0),
		"P1: a pure vy difference (index 1) gives accel (0, 2w)")
	# A matching state needs no acceleration.
	r = f.step(_pf(c), _pf(c))
	_check(_is_zero_result(r), "P1: current == target gives a zero, non-snap result")
	# No-rotation map.
	var f4 := _fol(_map4(), _pol(200.0, 300.0))
	r = f4.step(_pf([0.0, 0.0, 1.0, 2.0]), _pf([3.0, 4.0, -1.0, 0.0]))
	_check(_bool_is(_dg(r, "snap"), false) and _v2close(_dg(r, "accel"), w * w * Vector2(3, 4) + 2.0 * w * Vector2(-2, -2)) and _isf(_dg(r, "alpha")) and _dg(r, "alpha") == 0.0,
		"P1: without rotation alpha is exactly 0.0 and accel follows the formula")
	# Rotation short arc across +/-PI.
	f = _fol(_map6(), _pol(200.0, 300.0))
	r = f.step(_pf([0, 0, 3.0, 0, 0, 0]), _pf([0, 0, -3.0, 0, 0, 0]))
	_check(_close(_dg(r, "alpha"), wr * wr * _wrap(-3.0 - 3.0), 1e-3) and _num(_dg(r, "alpha")) > 0.0,
		"P1: 3.0 -> -3.0 turns the SHORT way (+0.283 rad): alpha %s" % _dg(r, "alpha"))
	r = f.step(_pf([0, 0, -3.0, 0, 0, 0]), _pf([0, 0, 3.0, 0, 0, 0]))
	_check(_close(_dg(r, "alpha"), wr * wr * _wrap(3.0 + 3.0), 1e-3) and _num(_dg(r, "alpha")) < 0.0,
		"P1: -3.0 -> 3.0 turns the short way the other direction (-0.283 rad)")
	# Policy edits take effect at the next step.
	var pe := _pol(200.0, 300.0)
	pe.snap_distance = 1000.0
	f = _fol(_map6(), pe)
	var cur := _pf([0, 0, 0, 0, 0, 0])
	var tgt := _pf([10, 0, 0, 0, 0, 0])
	r = f.step(cur, tgt)
	var a_before: Variant = _dg(r, "accel")
	pe.settle_ms = 400.0
	r = f.step(cur, tgt)
	_check(_v2close(a_before, Vector2(_om(200.0, DT) * _om(200.0, DT) * 10.0, 0.0)) and _v2close(_dg(r, "accel"), Vector2(_om(400.0, DT) * _om(400.0, DT) * 10.0, 0.0)),
		"P1: a settle_ms edit changes the very next step's accel (23.7^2*10 -> 11.85^2*10)")
	pe.snap_distance = 5.0
	r = f.step(cur, tgt)
	_check(_bool_is(_dg(r, "snap"), true), "P1: a snap_distance edit takes effect at the next step (error 10 > 5 -> snap)")

	# Empty / bad input.
	f = _fol(_map6(), _pol(200.0, 300.0))
	r = f.step(_pf([1, 2, 3, 4, 5, 6]), PackedFloat32Array())
	_check(_is_zero_result(r) and f.bad_input_count == 0, "P1: an empty target gives the zero result without counting")
	r = f.step(PackedFloat32Array(), PackedFloat32Array())
	_check(_is_zero_result(r) and f.bad_input_count == 0, "P1: empty current and empty target: zero result, not counted")
	r = f.step(_pf([1, 2, 3, 4, 5, 6]), _pf([1, 2, 3, 4, 5]))
	_check(_is_zero_result(r) and f.bad_input_count == 1, "P1: a size mismatch gives the zero result and bad_input_count 1")
	r = f.step(_pf([1, 2, 3, 4, 5]), _pf([1, 2, 3, 4, 5, 6]))
	_check(_is_zero_result(r) and f.bad_input_count == 2, "P1: the mismatch is counted both ways (current shorter): 2")
	r = f.step(PackedFloat32Array(), _pf([1, 2, 3, 4, 5, 6]))
	_check(_is_zero_result(r) and f.bad_input_count == 3, "P1: an empty CURRENT with a non-empty target is a size mismatch: 3")
	var bad_maps := [
		["x", {"x": 6, "y": 1, "rot": 2, "vx": 3, "vy": 4, "w": 5}],
		["vy", {"x": 0, "y": 1, "rot": 2, "vx": 3, "vy": 9, "w": 5}],
		["rot", {"x": 0, "y": 1, "rot": 6, "vx": 3, "vy": 4, "w": 5}],
	]
	for bm in bad_maps:
		var fb := _fol(CouchBodyChannels.new(bm[1]), _pol(200.0, 300.0))
		r = fb.step(_pf([1, 2, 3, 4, 5, 6]), _pf([2, 3, 4, 5, 6, 7]))
		_check(_is_zero_result(r) and fb.bad_input_count == 1, "P1: a channel index out of range (%s) gives the zero result and counts" % bm[0])
	var nonfinite := [
		["target x NAN", false, 0, NAN], ["target y INF", false, 1, INF], ["target rot -INF", false, 2, -INF],
		["target vx NAN", false, 3, NAN], ["target w NAN", false, 5, NAN],
		["current x INF", true, 0, INF], ["current vy NAN", true, 4, NAN], ["current w -INF", true, 5, -INF],
	]
	for nf in nonfinite:
		var fn := _fol(_map6(), _pol(200.0, 300.0))
		var cc := _pf([1, 2, 3, 4, 5, 6])
		var tt := _pf([2, 3, 4, 5, 6, 7])
		if nf[1]:
			cc[nf[2]] = nf[3]
		else:
			tt[nf[2]] = nf[3]
		r = fn.step(cc, tt)
		_check(_is_zero_result(r) and fn.bad_input_count == 1, "P1: a non-finite used value (%s) gives the zero result and counts" % nf[0])
	var fu := _fol(_map4(), _pol(200.0, 300.0))
	r = fu.step(_pf([0, 0, 0, 0, 0, NAN]), _pf([1, 1, 0, 0, 0, NAN]))
	_check(_bool_is(_dg(r, "snap"), false) and _num(_dg(r, "accel").x if typeof(_dg(r, "accel")) == TYPE_VECTOR2 else NAN) > 0.0 and fu.bad_input_count == 0,
		"P1: a non-finite value in an UNUSED channel (index 5 of a 4-channel map) is not an error")
	r = fu.step(_pf([0, 0, 0, 0]), _pf([NAN, 0, 0, 0]))
	r = fu.step(_pf([0, 0, 0, 0]), _pf([1, 0, 0, 0]))
	_check(fu.bad_input_count == 1 and _num(_dg(r, "accel").x if typeof(_dg(r, "accel")) == TYPE_VECTOR2 else NAN) > 0.0,
		"P1: a bad step does not poison the next: counter 1, the following step works")
	# Mutation survivors (f11, f19): a size mismatch whose used indices are all in range, and an
	# invalid map (every index -1, which GDScript would otherwise read from the array's end).
	r = fu.step(_pf([0, 0, 0, 0]), _pf([1, 0, 0, 0, 9]))
	_check(_is_zero_result(r) and fu.bad_input_count == 2, "P1: a size mismatch is refused even when every used index is in range in both")
	var fi := _fol(CouchBodyChannels.new({"x": 0}), _pol(200.0, 300.0))
	r = fi.step(_pf([1, 2, 3, 4, 5, 6]), _pf([2, 3, 4, 5, 6, 7]))
	_check(_is_zero_result(r) and fi.bad_input_count == 1, "P1: a follower with an INVALID channel map (indices -1) gives the zero result and counts")

	# Snap boundary: strictly above.
	var ps := CouchPDFollowerPolicy.new()
	ps.snap_distance = 10.0
	ps.snap_angle = 1.0
	f = _fol(_map6(), ps)
	var zero := _pf([0, 0, 0, 0, 0, 0])
	r = f.step(zero, _pf([6, 8, 0, 0, 0, 0]))
	_check(_bool_is(_dg(r, "snap"), false) and _num(_dg(r, "accel").x if typeof(_dg(r, "accel")) == TYPE_VECTOR2 else NAN) > 0.0, "P1: error length exactly == snap_distance (6, 8 vs 10) does NOT snap")
	r = f.step(zero, _pf([10.001, 0, 0, 0, 0, 0]))
	_check(_bool_is(_dg(r, "snap"), true), "P1: error 10.001 > 10 snaps")
	r = f.step(zero, _pf([6, 8.001, 0, 0, 0, 0]))
	_check(_bool_is(_dg(r, "snap"), true), "P1: (6, 8.001) snaps: the distance is the vector length")
	r = f.step(zero, _pf([-10.001, 0, 0, 0, 0, 0]))
	_check(_bool_is(_dg(r, "snap"), true), "P1: the sign of the error does not matter for the distance")
	r = f.step(zero, _pf([0, 0, 1.0, 0, 0, 0]))
	_check(_bool_is(_dg(r, "snap"), false), "P1: rotation error exactly == snap_angle (1.0) does NOT snap")
	r = f.step(zero, _pf([0, 0, 1.001, 0, 0, 0]))
	_check(_bool_is(_dg(r, "snap"), true), "P1: rotation error 1.001 > 1.0 snaps even with zero position error")
	r = f.step(zero, _pf([0, 0, -1.001, 0, 0, 0]))
	_check(_bool_is(_dg(r, "snap"), true), "P1: the angle test is on the absolute value")
	r = f.step(_pf([0, 0, 3.0, 0, 0, 0]), _pf([0, 0, -3.0, 0, 0, 0]))
	_check(_bool_is(_dg(r, "snap"), false), "P1: 3.0 -> -3.0 is a 0.283 rad error (short arc), below snap_angle 1.0: no snap")
	f = _fol(_map6(), CouchPDFollowerPolicy.new())
	r = f.step(_pf([0, 0, 0.0, 0, 0, 0]), _pf([0, 0, 3.1, 0, 0, 0]))
	_check(_bool_is(_dg(r, "snap"), false), "P1: the default snap_angle PI never snaps (a 3.1 rad error)")

	# Snap result contents.
	var pk := CouchPDFollowerPolicy.new()
	pk.snap_distance = 100.0
	f = _fol(_map6(), pk)
	var target := _pf([300, -400, 1.2, 7, -8, 0.9])
	r = f.step(zero, target)
	_check(_bool_is(_dg(r, "snap"), true) and _v2close(_dg(r, "accel"), Vector2.ZERO) and _close(_dg(r, "alpha"), 0.0)
		and typeof(_dg(r, "accel")) == TYPE_VECTOR2 and _isf(_dg(r, "alpha")),
		"P1: a snap result has accel ZERO and alpha 0.0")
	_check(_v2close(_dg(r, "pos"), Vector2(300, -400)) and _v2close(_dg(r, "vel"), Vector2(7, -8)) and _close(_dg(r, "rot"), 1.2) and _close(_dg(r, "w"), 0.9)
		and _isf(_dg(r, "rot")) and _isf(_dg(r, "w")),
		"P1: snap pos / vel / rot / w are the target's (floats)")
	_check(_pfclose(_dg(r, "state"), [300, -400, 1.2, 7, -8, 0.9]), "P1: snap state holds the target's contents")
	var st: Variant = _dg(r, "state")
	if _is_pf(st):
		(st as PackedFloat32Array)[0] = -999.0
	_check(_at(target, 0) == 300.0, "P1: mutating result.state does not change the caller's target (a COPY)")
	target[1] = 5.5
	_check(_close(_at(_dg(r, "state"), 1), -400.0), "P1: mutating the target afterwards does not change result.state")
	f = _fol(_mapx(), pk)
	r = f.step(_pf([0, 0, 0, 0, 0, 0]), _pf([0.5, 6.0, 300.0, 0.25, 400.0, 7.0]))
	_check(_bool_is(_dg(r, "snap"), true) and _v2close(_dg(r, "pos"), Vector2(400, 300)) and _v2close(_dg(r, "vel"), Vector2(7, 6)) and _close(_dg(r, "rot"), 0.5) and _close(_dg(r, "w"), 0.25),
		"P1: snap fields come through the channel map (x idx 4, y idx 2, vx 5, vy 1, rot 0, w 3)")
	f = _fol(_map4(), pk)
	r = f.step(_pf([0, 0, 0, 0]), _pf([300, 400, 5, 6]))
	_check(_bool_is(_dg(r, "snap"), true) and _v2close(_dg(r, "pos"), Vector2(300, 400)) and _v2close(_dg(r, "vel"), Vector2(5, 6))
		and _isf(_dg(r, "rot")) and _dg(r, "rot") == 0.0 and _isf(_dg(r, "w")) and _dg(r, "w") == 0.0 and _pfclose(_dg(r, "state"), [300, 400, 5, 6]),
		"P1: a no-rotation snap has rot 0.0 / w 0.0 and a 4-value state")

	# Toy symplectic-Euler bodies (v += a dt; x += v dt).
	_toy_step_cases()
	_toy_track_case()


## One axis of a toy body driven by the real follower toward a step error.
## axis "x": 0 -> 100 (units); axis "rot": 0 -> 1.0 rad.
func _toy_step(settle_ms: float, rot_settle_ms: float, dt: float, steps: int, axis: String) -> Dictionary:
	var f := _fol(_map6(), _pol(settle_ms, rot_settle_ms), dt)
	var x := 0.0
	var vx := 0.0
	var rot := 0.0
	var wv := 0.0
	var goal := 100.0 if axis == "x" else 1.0
	var first := -1
	var over := 0.0
	var worst := 0.0
	var finite := true
	for n in range(1, steps + 1):
		var cur := _pf([x, 0.0, rot, vx, 0.0, wv])
		var tgt := _pf([goal if axis == "x" else 0.0, 0.0, goal if axis == "rot" else 0.0, 0.0, 0.0, 0.0])
		var r: Dictionary = f.step(cur, tgt)
		var a: Variant = _dg(r, "accel")
		vx += (a.x if typeof(a) == TYPE_VECTOR2 else 0.0) * dt
		x += vx * dt
		wv += _numz(_dg(r, "alpha")) * dt
		rot += wv * dt
		var pos := x if axis == "x" else rot
		over = maxf(over, pos - goal)
		worst = maxf(worst, absf(pos))
		if not is_finite(pos):
			finite = false
		if first < 0 and absf(goal - pos) <= 0.05 * goal:
			first = n
	var end_pos := x if axis == "x" else rot
	return {"first": first, "over": over, "worst": worst, "end_err": absf(goal - end_pos), "finite": finite, "goal": goal}


func _toy_step_cases() -> void:
	var cases := [
		["unclamped 200 ms", 200.0, 200.0],
		["clamped 50 ms (omega 30, w*dt = 0.5)", 50.0, 50.0],
		["slow 1000 ms", 1000.0, 1000.0],
	]
	for cs in cases:
		var settle: float = cs[1]
		# 5% is reached within the effective settle time plus two ticks (a discrete body lags the
		# continuous solution by about one tick), and the effective settle is what the formula says.
		var eff_ms := 4.74 / _om(settle, DT) * 1000.0
		var limit_steps := int(ceil((eff_ms + 2.0 * DT * 1000.0) / (DT * 1000.0)))
		var res := _toy_step(settle, settle, DT, 400, "x")
		var first: int = res["first"]
		_check(first > 0 and first <= limit_steps,
			"P1: toy x step, %s: 5%% error reached at step %d (limit %d = effective settle %.0f ms + 2 ticks)" % [cs[0], first, limit_steps, eff_ms])
		_check(first > 0 and float(res["over"]) <= 1.0 and bool(res["finite"]) and float(res["worst"]) <= 101.0 and float(res["end_err"]) <= 0.5,
			"P1: toy x step, %s: critically damped (overshoot %.4f <= 1%% of the step), finite, settled" % [cs[0], float(res["over"])])
		res = _toy_step(settle, settle, DT, 400, "rot")
		first = res["first"]
		_check(first > 0 and first <= limit_steps and float(res["over"]) <= 0.01 and bool(res["finite"]) and float(res["end_err"]) <= 0.005,
			"P1: toy rotation step, %s: settles by step %d (limit %d), overshoot %.5f <= 1%%" % [cs[0], first, limit_steps, float(res["over"])])
	var hi := _toy_step(50.0, 50.0, 1.0 / 120.0, 800, "x")
	var lim_hi := int(ceil((4.74 / 60.0 * 1000.0 + 2.0 * 1000.0 / 120.0) / (1000.0 / 120.0)))
	_check(int(hi["first"]) > 0 and int(hi["first"]) <= lim_hi and float(hi["over"]) <= 1.0 and bool(hi["finite"]),
		"P1: toy x step at 120 Hz with settle 50 ms (clamped to omega 60): settles by step %d (limit %d), no overshoot" % [int(hi["first"]), lim_hi])


## A target moving at constant velocity (position AND rotation, crossing +/-PI): feed-forward
## makes the steady-state error ~0; without it the error would be 2v/w (8.4 units here).
func _toy_track_case() -> void:
	var f := _fol(_map6(), _pol(200.0, 200.0))
	var x := 50.0
	var vx := 0.0
	var y := 0.0
	var vy := 0.0
	var rot := 2.5
	var wv := 0.0
	var vt := Vector2(100.0, -60.0)
	var wt := 3.0
	var peak := 0.0
	var end_err := 0.0
	var end_rot := 0.0
	var finite := true
	for n in range(0, 240):
		var tx := 50.0 + vt.x * n * DT
		var ty := vt.y * n * DT
		var tr := _wrap(2.5 + wt * n * DT)
		var cur := _pf([x, y, rot, vx, vy, wv])
		var tgt := _pf([tx, ty, tr, vt.x, vt.y, wt])
		var r: Dictionary = f.step(cur, tgt)
		var a: Variant = _dg(r, "accel")
		vx += (a.x if typeof(a) == TYPE_VECTOR2 else 0.0) * DT
		vy += (a.y if typeof(a) == TYPE_VECTOR2 else 0.0) * DT
		x += vx * DT
		y += vy * DT
		wv += _numz(_dg(r, "alpha")) * DT
		rot = _wrap(rot + wv * DT)
		var err := Vector2(50.0 + vt.x * (n + 1) * DT - x, vt.y * (n + 1) * DT - y).length()
		finite = finite and is_finite(err) and is_finite(rot)
		peak = maxf(peak, err)
		if n >= 180:
			end_err = maxf(end_err, err)
			end_rot = maxf(end_rot, absf(_wrap(2.5 + wt * (n + 1) * DT - rot)))
	_check(finite and end_err <= 0.05, "P1: constant-velocity target (100, -60): steady-state error %.4f <= 0.05 (feed-forward; no feed-forward would sit at ~8.4)" % end_err)
	_check(finite and peak <= 5.0, "P1: the start-up transient from rest is bounded (peak error %.3f <= 5, ~v / (e w))" % peak)
	_check(finite and end_rot <= 0.01, "P1: a target spinning at 3 rad/s through +/-PI is tracked the short way (steady-state rot error %.5f <= 0.01)" % end_rot)


# --- P2: helpers --------------------------------------------------------------------------


func _case_p2() -> void:
	print("P2: force_from / velocity_after")
	var res := {"snap": false, "accel": Vector2(3.0, -4.0), "alpha": 2.0}
	var fz: Dictionary = CouchPDFollower.force_from(res, 2.5, 4.0)
	_check(_v2close(_dg(fz, "force"), Vector2(7.5, -10.0)) and _close(_dg(fz, "torque"), 8.0),
		"P2: force_from = accel * mass, torque = alpha * inertia: %s" % [fz])
	fz = CouchPDFollower.force_from(res, 0.0, 0.0)
	_check(_v2close(_dg(fz, "force"), Vector2.ZERO) and _close(_dg(fz, "torque"), 0.0) and typeof(_dg(fz, "force")) == TYPE_VECTOR2,
		"P2: zero mass / inertia give zero force / torque (no division)")
	var va: Dictionary = CouchPDFollower.velocity_after(res, Vector2(10.0, 20.0), 1.0, 0.1)
	_check(_v2close(_dg(va, "linear"), Vector2(10.3, 19.6)) and _close(_dg(va, "angular"), 1.2),
		"P2: velocity_after = vel + accel * dt, ang_vel + alpha * dt: %s" % [va])
	# Snap branch, built by hand and through a real step.
	var snap_res := {"snap": true, "accel": Vector2.ZERO, "alpha": 0.0, "state": _pf([5, 6, 0.5, 1, 2, 0.25]),
		"pos": Vector2(5, 6), "vel": Vector2(1, 2), "rot": 0.5, "w": 0.25}
	fz = CouchPDFollower.force_from(snap_res, 2.5, 4.0)
	_check(_v2close(_dg(fz, "force"), Vector2.ZERO) and _close(_dg(fz, "torque"), 0.0) and typeof(_dg(fz, "force")) == TYPE_VECTOR2,
		"P2: force_from of a snap result is zeros")
	# Mutation survivor (f17): the snap flag alone decides, not a zero accel / alpha in the result.
	var snap_acc := snap_res.duplicate()
	snap_acc["accel"] = Vector2(3.0, -4.0)
	snap_acc["alpha"] = 2.0
	fz = CouchPDFollower.force_from(snap_acc, 2.5, 4.0)
	_check(_v2close(_dg(fz, "force"), Vector2.ZERO) and _close(_dg(fz, "torque"), 0.0),
		"P2: force_from of a snap result is zeros even if the result carries a non-zero accel / alpha")
	va = CouchPDFollower.velocity_after(snap_res, Vector2(10.0, 20.0), 1.0, 0.1)
	_check(_v2close(_dg(va, "linear"), Vector2(1, 2)) and _close(_dg(va, "angular"), 0.25),
		"P2: velocity_after of a snap result is the result's vel / w, ignoring the current velocity and dt")
	var pk := CouchPDFollowerPolicy.new()
	pk.snap_distance = 50.0
	var f := _fol(_map6(), pk)
	var real_snap: Dictionary = f.step(_pf([0, 0, 0, 0, 0, 0]), _pf([100, 0, 0.5, 3, 4, 0.75]))
	va = CouchPDFollower.velocity_after(real_snap, Vector2(9, 9), 9.0, 0.5)
	fz = CouchPDFollower.force_from(real_snap, 3.0, 3.0)
	_check(_v2close(_dg(va, "linear"), Vector2(3, 4)) and _close(_dg(va, "angular"), 0.75) and _v2close(_dg(fz, "force"), Vector2.ZERO),
		"P2: the helpers on a REAL snap step: velocity_after -> target vel / w, force_from -> zeros")
	var real_step: Dictionary = _fol(_map6(), _pol(200.0, 300.0)).step(_pf([0, 0, 0, 0, 0, 0]), _pf([1, 2, 0.1, 0, 0, 0]))
	fz = CouchPDFollower.force_from(real_step, 2.0, 5.0)
	var acc: Variant = _dg(real_step, "accel")
	_check(typeof(acc) == TYPE_VECTOR2 and _v2close(_dg(fz, "force"), (acc as Vector2) * 2.0) and _close(_dg(fz, "torque"), _num(_dg(real_step, "alpha")) * 5.0)
		and _num(_dg(fz, "torque")) > 0.0,
		"P2: the helpers compose with a real non-snap step (force = accel * 2, torque = alpha * 5)")


# --- C1: CouchBodyChannels ----------------------------------------------------------------


func _idx(c: CouchBodyChannels) -> Array:
	return [c.x, c.y, c.vx, c.vy, c.rot, c.w]


func _case_c1() -> void:
	print("C1: CouchBodyChannels + kind_channels")
	var c := _map6()
	_check(c.is_valid() and _idx(c) == [0, 1, 3, 4, 2, 5] and c.has_rotation(), "C1: a full map is valid, indices [x, y, vx, vy, rot, w] = %s, has_rotation" % [_idx(c)])
	c = _map4()
	_check(c.is_valid() and _idx(c) == [0, 1, 2, 3, -1, -1] and not c.has_rotation(), "C1: a rotation-free map is valid, rot / w are -1, has_rotation false: %s" % [_idx(c)])
	c = _mapx()
	_check(c.is_valid() and _idx(c) == [4, 2, 5, 1, 0, 3] and c.has_rotation(), "C1: a permuted map keeps each index: %s" % [_idx(c)])
	c = CouchBodyChannels.new({"x": 0, "y": 1, "vx": 2, "vy": 3, "rot": 10, "w": 20})
	_check(c.is_valid() and c.rot == 10 and c.w == 20, "C1: large indices are fine for validity (range is checked by fits)")
	var invalid := [
		["x missing", {"y": 1, "vx": 2, "vy": 3}],
		["y missing", {"x": 0, "vx": 2, "vy": 3}],
		["vx missing", {"x": 0, "y": 1, "vy": 3}],
		["vy missing", {"x": 0, "y": 1, "vx": 2}],
		["empty map", {}],
		["rot without w", {"x": 0, "y": 1, "vx": 2, "vy": 3, "rot": 4}],
		["w without rot", {"x": 0, "y": 1, "vx": 2, "vy": 3, "w": 4}],
		["an extra string key", {"x": 0, "y": 1, "vx": 2, "vy": 3, "z": 4}],
		["an extra key beside a full rotation set", {"x": 0, "y": 1, "vx": 2, "vy": 3, "rot": 4, "w": 5, "extra": 6}],
		["a non-string extra key", {"x": 0, "y": 1, "vx": 2, "vy": 3, 7: 4}],
		["duplicate x == y", {"x": 0, "y": 0, "vx": 2, "vy": 3}],
		["duplicate vx == vy", {"x": 0, "y": 1, "vx": 2, "vy": 2}],
		["duplicate rot == w", {"x": 0, "y": 1, "vx": 2, "vy": 3, "rot": 4, "w": 4}],
		["duplicate x == w", {"x": 0, "y": 1, "vx": 2, "vy": 3, "rot": 4, "w": 0}],
		["negative x", {"x": -1, "y": 1, "vx": 2, "vy": 3}],
		["negative w", {"x": 0, "y": 1, "vx": 2, "vy": 3, "rot": 4, "w": -2}],
		["float index (1.0)", {"x": 0, "y": 1.0, "vx": 2, "vy": 3}],
		["string index", {"x": 0, "y": 1, "vx": "2", "vy": 3}],
		["bool index", {"x": 0, "y": 1, "vx": 2, "vy": true}],
		["null index", {"x": 0, "y": 1, "vx": 2, "vy": null}],
		["float rot", {"x": 0, "y": 1, "vx": 2, "vy": 3, "rot": 4.0, "w": 5}],
	]
	for iv in invalid:
		var ic := CouchBodyChannels.new(iv[1])
		var bad_idx := _idx(ic)
		_check(not ic.is_valid() and bad_idx == [-1, -1, -1, -1, -1, -1] and not ic.fits([LERP, LERP, LERP, LERP, ANGLE, LERP, LERP, LERP]),
			"C1: invalid (%s): is_valid false, every index -1, fits false" % iv[0])
	# fits() against layouts.
	var l6 := [LERP, LERP, ANGLE, LERP, LERP, LERP]
	_check(_map6().fits(l6), "C1: fits the [L,L,A,L,L,L] layout")
	_check(_map4().fits([LERP, LERP, LERP, LERP]) and _map4().fits([LERP, LERP, LERP, LERP, ANGLE, LERP]) and _map4().fits([LERP, LERP, LERP, LERP, SNAP]),
		"C1: a rotation-free map fits wherever its four indices are LERP (the other slots are not looked at)")
	_check(_mapx().fits([ANGLE, LERP, LERP, LERP, LERP, LERP]), "C1: the permuted map fits a layout with ANGLE at its rot index (0)")
	_check(not _mapx().fits(l6), "C1: ...and not the layout whose ANGLE sits at index 2 (index 0 is LERP, index 2 is ANGLE for y)")
	_check(not _map6().fits([LERP, LERP, LERP, LERP, LERP, LERP]), "C1: rot on a LERP channel does not fit")
	_check(not _map6().fits([LERP, LERP, SNAP, LERP, LERP, LERP]), "C1: rot on a SNAP channel does not fit")
	_check(not _map6().fits([ANGLE, LERP, ANGLE, LERP, LERP, LERP]), "C1: x on an ANGLE channel does not fit")
	_check(not _map6().fits([LERP, SNAP, ANGLE, LERP, LERP, LERP]), "C1: y on a SNAP channel does not fit")
	_check(not _map6().fits([LERP, LERP, ANGLE, SNAP, LERP, LERP]), "C1: vx on a SNAP channel does not fit")
	_check(not _map6().fits([LERP, LERP, ANGLE, LERP, ANGLE, LERP]), "C1: vy on an ANGLE channel does not fit")
	_check(not _map6().fits([LERP, LERP, ANGLE, LERP, LERP, ANGLE]), "C1: w on an ANGLE channel does not fit")
	_check(not _map6().fits([LERP, LERP, ANGLE, LERP, LERP, SNAP]), "C1: w on a SNAP channel does not fit")
	_check(not _map6().fits([LERP, LERP, ANGLE, LERP, LERP]), "C1: an index beyond the layout (w = 5 vs 5 channels) does not fit")
	_check(not _map4().fits([LERP, LERP, LERP]), "C1: vy = 3 vs 3 channels does not fit")
	_check(not _map6().fits([]), "C1: an empty layout fits nothing")
	_check(CouchBodyChannels.new({"x": 0, "y": 1, "vx": 2, "vy": 3, "rot": 4, "w": 5}).fits([LERP, LERP, LERP, LERP, ANGLE, LERP, SNAP]),
		"C1: a longer layout is fine (trailing channels are the game's)")
	# kind_channels is a copy.
	var w := _new_world()
	var kc: Array = w.kind_channels(KIND7)
	_check(kc == [LERP, LERP, ANGLE, LERP, LERP, LERP, SNAP], "C1: world.kind_channels(kind) lists the registered channels: %s" % [kc])
	kc.append(99)
	kc[0] = SNAP
	_check(w.kind_channels(KIND7) == [LERP, LERP, ANGLE, LERP, LERP, LERP, SNAP], "C1: kind_channels returns a COPY (mutating it changes nothing)")
	_check(w.kind_channels(77) == [] and typeof(w.kind_channels(77)) == TYPE_ARRAY and w.kind_channels(-1) == [], "C1: an unregistered kind gives []")
	var hash_before := w.layout_hash()
	w.kind_channels(KIND6)
	_check(w.layout_hash() == hash_before and w.register_kind(50, [LERP]) and w.kind_channels(50) == [LERP], "C1: kind_channels does not disturb the registry (a later register_kind shows up)")


# --- T1: CouchOwnerTargets ----------------------------------------------------------------


## Everything a rejected input must not change, sampled at `now` (stale by then).
func _fp_t(t: CouchOwnerTargets, peer: String, now: int) -> Array:
	var tg: Array = []
	for v in t.target_for(peer, now):
		tg.append(v)
	return [t.accepted_count(peer), tg, t.is_stale(peer, now), t.stale_gap_count(peer), t.entity_of(peer)]


func _all_rej(t: CouchOwnerTargets, peer: String) -> int:
	var n := 0
	for r in REASONS:
		n += t.reject_count(peer, r)
	return n


## note_input must refuse: false, exactly `reason` counted once, last reason, no state change.
func _expect_rej(t: CouchOwnerTargets, peer: String, body: Variant, reason: String, label: String) -> void:
	var fp := _fp_t(t, peer, 1800)
	var n_reason := t.reject_count(peer, reason)
	var n_all := _all_rej(t, peer)
	var res: bool = t.note_input(peer, body, 1400)
	_check(res == false and t.reject_count(peer, reason) == n_reason + 1 and _all_rej(t, peer) == n_all + 1
		and t.last_reject_reason(peer) == reason and _fp_t(t, peer, 1800) == fp,
		"T1: %s -> '%s' (counted once, last reason set, nothing else changed)" % [label, reason])


func _case_t1() -> void:
	print("T1: CouchOwnerTargets")
	_t1_setup()
	_t1_set_owner()
	_t1_rejections()
	_t1_accept()
	_t1_extrapolation()
	_t1_staleness()
	_t1_lifecycle()
	_t1_impulse()


func _t1_setup() -> void:
	var w := _new_world()
	var t := CouchOwnerTargets.new(w)
	_check(t.extrapolate_cap_ms == 100 and t.stale_ms == 500 and t.stale_mode == CouchOwnerTargets.HOLD and CouchOwnerTargets.HOLD == 0 and CouchOwnerTargets.REPORT_ONLY == 1,
		"T1: defaults extrapolate_cap_ms 100, stale_ms 500, stale_mode HOLD (0), REPORT_ONLY == 1")
	var hash_before := w.layout_hash()
	_check(t.set_channels(KIND6, _map6()), "T1: set_channels accepts a map that fits the registered layout")
	_check(not t.set_channels(77, _map6()), "T1: set_channels refuses an unregistered kind")
	_check(not t.set_channels(KIND6, CouchBodyChannels.new({"x": 0, "y": 1})), "T1: set_channels refuses an invalid map")
	_check(not t.set_channels(KIND6, _mapx()), "T1: set_channels refuses a map that does not fit the layout")
	_check(not t.set_channels(KIND_NR, _map6()), "T1: set_channels refuses a map whose indices exceed the layout (6-slot map on a 4-slot kind)")
	_check(w.layout_hash() == hash_before, "T1: the targets never mutate the world's registry")
	# replace; a refused call does not replace.
	t = _new_targets(_new_world())
	var swapped := CouchBodyChannels.new({"x": 0, "y": 1, "rot": 2, "vx": 4, "vy": 3, "w": 5})
	var o := [1.0, 2.0, 0.0, 10.0, 20.0, 0.0]
	t.set_owner("a", 10, KIND6, 1.0, 1.0, 0)
	t.note_input("a", _b6(1, o), 1000)
	_check(_pfclose(t.target_for("a", 1050), [1.0 + 10.0 * 0.05, 2.0 + 20.0 * 0.05, 0.0, 10.0, 20.0, 0.0]), "T1: the identity map extrapolates x by index 3, y by index 4 (baseline)")
	_check(t.set_channels(KIND6, swapped), "T1: set_channels replaces an existing registration")
	_check(_pfclose(t.target_for("a", 1050), [1.0 + 20.0 * 0.05, 2.0 + 10.0 * 0.05, 0.0, 10.0, 20.0, 0.0]),
		"T1: ...and the replacement is what extrapolation uses (x by index 4, y by index 3)")
	_check(not t.set_channels(KIND6, CouchBodyChannels.new({"x": 0, "y": 1, "vx": 2, "vy": 3, "rot": 2, "w": 5}))
		and _pfclose(t.target_for("a", 1050), [1.0 + 20.0 * 0.05, 2.0 + 10.0 * 0.05, 0.0, 10.0, 20.0, 0.0]),
		"T1: a refused set_channels leaves the previous registration in place")


func _t1_set_owner() -> void:
	var t := _new_targets(_new_world())
	_check(t.set_owner("a", 10, KIND6, 2.0, 3.0, 0) and t.entity_of("a") == 10 and t.mass_of("a") == 2.0 and t.inertia_of("a") == 3.0,
		"T1: set_owner accepts; entity_of / mass_of / inertia_of report it")
	_check(t.entity_of("nobody") == -1 and t.mass_of("nobody") == 0.0, "T1: a non-owner has entity_of -1 and mass_of 0.0")
	# Each refusal individually; each leaves a fresh peer a non-owner and an existing owner unchanged.
	var refusals := [
		["kind with no set_channels", func(tg: CouchOwnerTargets, p: String) -> bool: return tg.set_owner(p, 11, KIND_FREE, 1.0, 1.0, 0)],
		["unregistered kind", func(tg: CouchOwnerTargets, p: String) -> bool: return tg.set_owner(p, 11, 77, 1.0, 1.0, 0)],
		["entity id -1", func(tg: CouchOwnerTargets, p: String) -> bool: return tg.set_owner(p, -1, KIND6, 1.0, 1.0, 0)],
		["entity id 2^31", func(tg: CouchOwnerTargets, p: String) -> bool: return tg.set_owner(p, INT_MAX + 1, KIND6, 1.0, 1.0, 0)],
		["entity owned by another peer", func(tg: CouchOwnerTargets, p: String) -> bool: return tg.set_owner(p, 12, KIND6, 1.0, 1.0, 0)],
		["mass 0", func(tg: CouchOwnerTargets, p: String) -> bool: return tg.set_owner(p, 11, KIND6, 0.0, 1.0, 0)],
		["negative mass", func(tg: CouchOwnerTargets, p: String) -> bool: return tg.set_owner(p, 11, KIND6, -1.0, 1.0, 0)],
		["NAN mass", func(tg: CouchOwnerTargets, p: String) -> bool: return tg.set_owner(p, 11, KIND6, NAN, 1.0, 0)],
		["INF mass", func(tg: CouchOwnerTargets, p: String) -> bool: return tg.set_owner(p, 11, KIND6, INF, 1.0, 0)],
		["negative inertia", func(tg: CouchOwnerTargets, p: String) -> bool: return tg.set_owner(p, 11, KIND6, 1.0, -0.1, 0)],
		["NAN inertia", func(tg: CouchOwnerTargets, p: String) -> bool: return tg.set_owner(p, 11, KIND6, 1.0, NAN, 0)],
		["INF inertia", func(tg: CouchOwnerTargets, p: String) -> bool: return tg.set_owner(p, 11, KIND6, 1.0, INF, 0)],
	]
	for rf in refusals:
		var tg := _new_targets(_new_world())
		tg.set_owner("a", 10, KIND6, 2.0, 3.0, 0)
		tg.set_owner("z", 12, KIND6, 1.0, 1.0, 0)
		tg.note_input("a", _b6(5), 1000)
		var fresh_ok: bool = rf[1].call(tg, "fresh")
		_check(not fresh_ok and tg.entity_of("fresh") == -1 and tg.mass_of("fresh") == 0.0, "T1: set_owner refuses %s (a fresh peer stays a non-owner)" % rf[0])
		var fp := _fp_t(tg, "a", 1400)
		var own_ok: bool = rf[1].call(tg, "a")
		_check(not own_ok and tg.entity_of("a") == 10 and tg.mass_of("a") == 2.0 and tg.inertia_of("a") == 3.0 and _fp_t(tg, "a", 1400) == fp,
			"T1: a refused re-set_owner (%s) changes nothing for the existing owner (entity, mass, inertia, report)" % rf[0])
	var tb := _new_targets(_new_world())
	_check(tb.set_owner("lo", 0, KIND6, 1.0, 0.0, 0) and tb.entity_of("lo") == 0 and tb.inertia_of("lo") == 0.0,
		"T1: entity id 0 and inertia 0.0 are accepted")
	_check(tb.set_owner("hi", INT_MAX, KIND6, 0.001, 1.0, 0) and tb.entity_of("hi") == INT_MAX, "T1: entity id 2^31-1 and a tiny positive mass are accepted")
	_check(tb.set_owner("lo", 0, KIND6, 1.0, 1.0, 0), "T1: the same peer may set_owner its own entity again")
	# Re-set replaces ownership and releases the old entity.
	_check(tb.set_owner("lo", 5, KIND7, 4.0, 5.0, 0) and tb.entity_of("lo") == 5 and tb.mass_of("lo") == 4.0 and tb.inertia_of("lo") == 5.0,
		"T1: re-set_owner replaces entity, mass and inertia")
	_check(tb.set_owner("other", 0, KIND6, 1.0, 1.0, 0), "T1: the entity the peer moved away from is free for another peer")
	# Re-set clears report state, keeps counters, restarts the staleness clock.
	var t2 := _new_targets(_new_world())
	t2.set_owner("a", 10, KIND6, 1.0, 1.0, 0)
	t2.note_input("a", _b6(5), 100)
	t2.note_input("a", _b6(6), 120)
	t2.note_input("a", _b6(7, [1.0, 2.0, 0.0, NAN, 0.0, 0.0]), 130)  # non-finite
	_check(t2.accepted_count("a") == 2 and t2.reject_count("a", "non-finite") == 1, "T1: setup for re-set: 2 accepted, 1 non-finite")
	t2.set_owner("a", 10, KIND6, 1.0, 1.0, 5000)
	_check(t2.target_for("a", 5000).is_empty() and t2.accepted_count("a") == 2 and t2.reject_count("a", "non-finite") == 1,
		"T1: re-set_owner clears the report (no target) but KEEPS the counters")
	_check(not t2.is_stale("a", 5500) and t2.is_stale("a", 5501), "T1: re-set_owner restarts the staleness clock at its now_ms (500 not stale, 501 stale)")
	_check(t2.note_input("a", _b6(1), 5100) and t2.accepted_count("a") == 3, "T1: after a re-set_owner a low tick is accepted again (last tick cleared)")


func _t1_rejections() -> void:
	var t := _owner_a()
	_check(t.note_input("a", _b6(10), 1000) and t.accepted_count("a") == 1, "T1: setup for rejections: peer a accepted at t=10, now 1000")
	# Step 1: unowned.
	_expect_rej(t, "ghost", _b6(1), "unowned", "an input from a peer that owns nothing")
	_check(t.accepted_count("ghost") == 0 and t.reject_count("ghost", "bad-shape") == 0, "T1: the unowned peer's other counters stay 0")
	# Step 2: bad-shape.
	var nan6 := [1.0, 2.0, 0.0, 0.0, 0.0, 0.0]
	var shapes := [
		["body is an int", 5], ["body is null", null], ["body is an Array", [1, 2]], ["body is a String", "t"],
		["t missing", {"o": _pf(nan6)}], ["t is a float (11.0)", {"t": 11.0, "o": _pf(nan6)}], ["t is a String", {"t": "11", "o": _pf(nan6)}],
		["o missing", {"t": 11}], ["o is an Array", {"t": 11, "o": [1.0, 2.0, 0.0, 0.0, 0.0, 0.0]}],
		["o is a PackedFloat64Array", {"t": 11, "o": PackedFloat64Array([1, 2, 0, 0, 0, 0])}],
		["o is a PackedInt32Array", {"t": 11, "o": PackedInt32Array([1, 2, 0, 0, 0, 0])}],
		["o is null", {"t": 11, "o": null}],
	]
	for s in shapes:
		_expect_rej(t, "a", s[1], "bad-shape", "bad shape (%s)" % s[0])
	# Step 3: bad-stride.
	for n in [0, 1, 5, 7, 12]:
		var vals: Array = []
		for i in n:
			vals.append(1.0)
		_expect_rej(t, "a", {"t": 11, "o": _pf(vals)}, "bad-stride", "stride %d against 6" % n)
	# Step 4: non-finite.
	for i in [0, 1, 2, 3, 4, 5]:
		var v := nan6.duplicate()
		v[i] = NAN if i % 2 == 0 else INF
		_expect_rej(t, "a", _b6(11, v), "non-finite", "a non-finite value at index %d" % i)
	_expect_rej(t, "a", _b6(11, [1.0, 2.0, 0.0, 0.0, 0.0, -INF]), "non-finite", "-INF in the last slot")
	# Step 5: stale-tick.
	_expect_rej(t, "a", _b6(10), "stale-tick", "a duplicate tick (10 after 10)")
	_expect_rej(t, "a", _b6(9), "stale-tick", "an older tick (9 after 10)")
	_expect_rej(t, "a", _b6(-100), "stale-tick", "a far older tick")
	# First failure wins.
	_expect_rej(t, "ghost", 5, "unowned", "pair: unowned + a non-Dictionary body")
	_expect_rej(t, "ghost", {"t": 1.5, "o": _pf([1, 2])}, "unowned", "pair: unowned + bad shape + bad stride")
	_expect_rej(t, "a", {"t": 1.5, "o": _pf([1, 2])}, "bad-shape", "pair: bad shape (t float) + bad stride")
	_expect_rej(t, "a", {"t": 20, "o": [1.0]}, "bad-shape", "pair: bad shape (o Array) + bad stride")
	_expect_rej(t, "a", {"t": 3, "o": [1.0, 2.0, 0.0, 0.0, 0.0, 0.0]}, "bad-shape", "pair: bad shape + an older tick")
	_expect_rej(t, "a", {"t": 20, "o": _pf([1, 2, 3, 4, NAN])}, "bad-stride", "pair: bad stride + non-finite")
	_expect_rej(t, "a", {"t": 3, "o": _pf([1, 2])}, "bad-stride", "pair: bad stride + an older tick")
	_expect_rej(t, "a", _b6(3, [NAN, 0.0, 0.0, 0.0, 0.0, 0.0]), "non-finite", "pair: non-finite + an older tick")
	_expect_rej(t, "a", _b6(10, [INF, 0.0, 0.0, 0.0, 0.0, 0.0]), "non-finite", "pair: non-finite + a duplicate tick")
	# Rejected inputs did not advance the last tick: a tick between 10 and the rejected 20 is still fine.
	_check(t.note_input("a", _b6(11), 1450) and t.accepted_count("a") == 2, "T1: rejected inputs (t=20 included) did not advance the last accepted tick: t=11 is accepted")
	_check(not t.note_input("a", _b6(11), 1460) and t.reject_count("a", "stale-tick") == 4, "T1: ...and 11 again is now stale (4 stale-tick rejections so far)")
	_check(t.reject_count("a", "no-such-reason") == 0 and t.reject_count("nobody", "unowned") == 0, "T1: an unknown reason / a peer with no history counts 0")


func _t1_accept() -> void:
	var t := _new_targets(_new_world())
	t.set_owner("b", 11, KIND6, 1.0, 1.0, 0)
	var o := _pf(BASE_O)
	var body := {"t": 5, "o": o, "ev": "ignored garbage", "extra": [1, 2, 3]}
	_check(t.note_input("b", body, 1000) and t.accepted_count("b") == 1, "T1: an accepted input returns true and counts; \"ev\" and extra keys are ignored here")
	o[0] = 999.0
	body["o"] = null
	_check(_pfclose(t.target_for("b", 1000), BASE_O), "T1: the stored report is a COPY of o (mutating the caller's array afterwards changes nothing)")
	t.set_owner("c", 12, KIND6, 1.0, 1.0, 0)
	_check(t.note_input("c", _b6(0), 1000) and t.accepted_count("c") == 1, "T1: the first accepted tick may be 0")
	var t3 := _new_targets(_new_world())
	t3.set_owner("n", 13, KIND6, 1.0, 1.0, 0)
	_check(t3.note_input("n", _b6(-3), 1000) and t3.note_input("n", _b6(-2), 1001) and not t3.note_input("n", _b6(-2), 1002) and t3.accepted_count("n") == 2,
		"T1: the first accepted tick may be negative; staleness is only against a tick accepted since set_owner")
	_check(t.note_input("b", _b6(6), 1010) and t.note_input("b", _b6(100), 1020) and not t.note_input("b", _b6(99), 1030) and t.accepted_count("b") == 3,
		"T1: strictly newer ticks are accepted (jumps allowed), an older one is not")
	_check(t.note_input("c", _b6(1), 1040) and t.accepted_count("c") == 2, "T1: ticks are tracked per peer (c is not affected by b's tick 100)")
	var o2 := _pf([7, 8, 0.5, 1, 2, 3])
	t.note_input("b", {"t": 101, "o": o2}, 2000)
	_check(_pfclose(t.target_for("b", 2000), [7, 8, 0.5, 1, 2, 3]), "T1: the newest accepted report is the target (age 0 returns it unchanged)")
	# Longer layouts: KIND7's extra channel is carried.
	var tx := _new_targets(_new_world())
	tx.set_owner("e", 14, KIND7, 1.0, 1.0, 0)
	_check(tx.note_input("e", {"t": 1, "o": _pf([1, 2, 0.5, 3, 4, 5, 42.0])}, 100) and tx.accepted_count("e") == 1 and not tx.note_input("e", _b6(2), 110),
		"T1: a kind with an extra channel needs its full stride (a 6-value report to a 7-stride kind is bad-stride)")
	_check(tx.reject_count("e", "bad-stride") == 1, "T1: ...counted as bad-stride")


func _t1_extrapolation() -> void:
	var t := _owner_a()
	t.note_input("a", _b6(10), 1000)
	# [x, y, rot, vx, vy, w] = [10, -4, 3.0, 20, -40, 2.0]
	var cases := [
		["age 0", 1000, [10.0, -4.0, 3.0, 20.0, -40.0, 2.0]],
		["age 50 (x + vx*0.05, y + vy*0.05, rot + w*0.05)", 1050, [11.0, -6.0, 3.1, 20.0, -40.0, 2.0]],
		["age exactly == extrapolate_cap_ms (100): full extrapolation, velocities as reported, rotation wrapped", 1100, [12.0, -8.0, _wrap(3.2), 20.0, -40.0, 2.0]],
		["age 101: extrapolation capped at 100 ms and velocities zeroed", 1101, [12.0, -8.0, _wrap(3.2), 0.0, 0.0, 0.0]],
		["age 400: held (cap age, zero velocities)", 1400, [12.0, -8.0, _wrap(3.2), 0.0, 0.0, 0.0]],
		["age 500 == stale_ms: not stale yet, still the held target", 1500, [12.0, -8.0, _wrap(3.2), 0.0, 0.0, 0.0]],
		["a NEGATIVE age (now before the report) is clamped to 0", 900, [10.0, -4.0, 3.0, 20.0, -40.0, 2.0]],
	]
	for c in cases:
		_check(_pfclose(t.target_for("a", c[1]), c[2]), "T1: target_for %s" % c[0])
	_check(_pfclose(t.target_for("a", 1100), [12.0, -8.0, -3.0832, 20.0, -40.0, 2.0], 1e-3), "T1: rotation 3.0 + 2.0 * 0.1 = 3.2 wraps to -3.0832 (short representation in [-PI, PI))")
	# A fresh array each call.
	var first: PackedFloat32Array = t.target_for("a", 1050)
	if first.size() > 0:
		first[0] = 12345.0
	first.append(1.0)
	_check(_pfclose(t.target_for("a", 1050), [11.0, -6.0, 3.1, 20.0, -40.0, 2.0]), "T1: target_for returns a NEW array each call (mutating one does not affect the next)")
	var second: PackedFloat32Array = t.target_for("a", 1000)
	if second.size() > 0:
		second[0] = -5.0
	_check(_pfclose(t.target_for("a", 1000), BASE_O), "T1: ...nor the stored report at age 0")
	# Empty cases.
	_check(t.target_for("nobody", 1000).is_empty() and typeof(t.target_for("nobody", 1000)) == TYPE_PACKED_FLOAT32_ARRAY, "T1: a non-owner has an empty target")
	var tn := _owner_a()
	_check(tn.target_for("a", 50).is_empty(), "T1: an owner with no report yet has an empty target")
	# cap variable.
	t.extrapolate_cap_ms = 40
	_check(_pfclose(t.target_for("a", 1030), [10.6, -5.2, 3.06, 20.0, -40.0, 2.0]) and _pfclose(t.target_for("a", 1050), [10.8, -5.6, 3.08, 0.0, 0.0, 0.0]),
		"T1: extrapolate_cap_ms is a variable (cap 40: age 30 extrapolates, age 50 is capped at 40 with zero velocities)")
	t.extrapolate_cap_ms = 100
	# No rotation: no w to zero, no rot to touch.
	var w := _new_world()
	var tr := _new_targets(w)
	tr.set_owner("n", 20, KIND_NR, 1.0, 1.0, 0)
	tr.note_input("n", {"t": 1, "o": _pf([1.0, 2.0, 10.0, -20.0])}, 1000)
	_check(_pfclose(tr.target_for("n", 1050), [1.5, 1.0, 10.0, -20.0]) and _pfclose(tr.target_for("n", 1150), [2.0, 0.0, 0.0, 0.0]),
		"T1: a rotation-free kind extrapolates x / y only and zeroes vx / vy past the cap")
	# Extra channels are reported as-is, even held.
	var tx := _new_targets(w)
	tx.set_owner("e", 21, KIND7, 1.0, 1.0, 0)
	tx.note_input("e", {"t": 1, "o": _pf([0.0, 0.0, 0.5, 10.0, 10.0, 1.0, 42.0])}, 1000)
	_check(_pfclose(tx.target_for("e", 1050), [0.5, 0.5, 0.55, 10.0, 10.0, 1.0, 42.0]) and _pfclose(tx.target_for("e", 1150), [1.0, 1.0, 0.6, 0.0, 0.0, 0.0, 42.0]),
		"T1: channels the follower does not use (the extra SNAP slot) are passed through unchanged, also when held")


func _t1_staleness() -> void:
	var t := _owner_a()
	t.set_owner("a", 10, KIND6, 2.0, 3.0, 2000)
	_check(not t.is_stale("a", 2500) and t.is_stale("a", 2501), "T1: with no report, staleness counts from set_owner: == stale_ms is NOT stale, +1 is")
	_check(t.target_for("a", 2501).is_empty(), "T1: no report -> empty target even when stale (HOLD has nothing to hold)")
	t.note_input("a", _b6(1), 2400)
	_check(not t.is_stale("a", 2900) and t.is_stale("a", 2901), "T1: once reported, staleness counts from the report: 2400 + 500 not stale, +1 stale")
	_check(not t.is_stale("nobody", 99999), "T1: a non-owner is never stale")
	# HOLD (default) vs REPORT_ONLY.
	var held := [12.0, -8.0, _wrap(3.2), 0.0, 0.0, 0.0]
	var th := _owner_a()
	th.note_input("a", _b6(10), 1000)
	_check(_pfclose(th.target_for("a", 1500), held) and _pfclose(th.target_for("a", 1501), held) and _pfclose(th.target_for("a", 99999), held),
		"T1: HOLD: past stale_ms the held target (cap-age position, zero velocities) keeps coming")
	var tr := _owner_a()
	tr.stale_mode = CouchOwnerTargets.REPORT_ONLY
	tr.note_input("a", _b6(10), 1000)
	_check(_pfclose(tr.target_for("a", 1050), [11.0, -6.0, 3.1, 20.0, -40.0, 2.0]) and _pfclose(tr.target_for("a", 1500), held),
		"T1: REPORT_ONLY before stale is identical to HOLD (extrapolate, then hold; 500 == stale_ms is not stale)")
	_check(tr.target_for("a", 1501).is_empty() and tr.target_for("a", 99999).is_empty() and tr.is_stale("a", 1501),
		"T1: REPORT_ONLY once stale: an EMPTY target (the game owns the stand-in); is_stale still true")
	tr.note_input("a", _b6(11), 1600)
	_check(_pfclose(tr.target_for("a", 1650), [10.0 + 20.0 * 0.05, -4.0 - 40.0 * 0.05, _wrap(3.0 + 2.0 * 0.05), 20.0, -40.0, 2.0]) and not tr.is_stale("a", 1700),
		"T1: a fresh report ends staleness in REPORT_ONLY")
	th.stale_ms = 300
	_check(not th.is_stale("a", 1300) and th.is_stale("a", 1301), "T1: stale_ms is a variable (300)")
	th.stale_mode = CouchOwnerTargets.REPORT_ONLY
	_check(_pfclose(th.target_for("a", 1300), held) and th.target_for("a", 1301).is_empty(), "T1: stale_mode is a variable (switched at runtime) and uses the new stale_ms")
	# stale_gap_count.
	var tg := _owner_a()
	tg.set_owner("a", 10, KIND6, 1.0, 1.0, 0)
	tg.note_input("a", _b6(1), 600)
	_check(tg.stale_gap_count("a") == 1, "T1: the first report 600 ms after set_owner is a stale gap (600 > 500)")
	tg.note_input("a", _b6(2), 1100)
	_check(tg.stale_gap_count("a") == 1, "T1: a gap of exactly stale_ms (500) is not a stale gap")
	tg.note_input("a", _b6(3), 1200)
	tg.note_input("a", _b6(4), 1701)
	_check(tg.stale_gap_count("a") == 2, "T1: a gap of 501 ms is a stale gap (count 2)")
	tg.note_input("a", _b6(5, [NAN, 0, 0, 0, 0, 0]), 1900)  # rejected: must not refresh the clock
	tg.note_input("a", _b6(6), 2400)
	_check(tg.stale_gap_count("a") == 3 and tg.accepted_count("a") == 5, "T1: a REJECTED input does not restart the gap clock (2400 - 1701 = 699 > 500: count 3)")
	var tq := _owner_a()
	tq.note_input("a", _b6(5), 100)
	tq.note_input("a", _b6(4), 5000)  # stale tick, rejected
	_check(tq.stale_gap_count("a") == 0 and tq.is_stale("a", 5000), "T1: a rejected stale-tick input at 5000 neither counts a gap nor refreshes staleness")
	_check(tq.stale_gap_count("nobody") == 0, "T1: stale_gap_count of an unknown peer is 0")


func _t1_lifecycle() -> void:
	var w := _new_world()
	var t := _new_targets(w)
	t.set_owner("a", 10, KIND6, 2.0, 3.0, 0)
	t.set_owner("b", 11, KIND6, 1.0, 1.0, 0)
	t.note_input("a", _b6(50), 1000)
	t.note_input("a", _b6(51, [1, 2, 0, 0, 0, NAN]), 1010)
	t.note_input("b", _b6(5), 1000)
	t.note_input("ghost", _b6(1), 1000)
	# forget.
	t.forget("a")
	_check(t.entity_of("a") == -1 and t.mass_of("a") == 0.0 and t.target_for("a", 1000).is_empty() and not t.is_stale("a", 99999),
		"T1: forget drops ownership, report and staleness")
	_check(t.accepted_count("a") == 0 and t.reject_count("a", "non-finite") == 0 and t.stale_gap_count("a") == 0, "T1: forget drops the peer's counters")
	_check(not t.note_input("a", _b6(60), 1100) and t.reject_count("a", "unowned") == 1, "T1: after forget an input is 'unowned'")
	_check(t.entity_of("b") == 11 and t.accepted_count("b") == 1, "T1: forget leaves other peers alone")
	t.forget("never-existed")
	_check(t.entity_of("b") == 11, "T1: forgetting an unknown peer is harmless")
	_check(t.set_owner("c", 10, KIND6, 1.0, 1.0, 2000), "T1: the forgotten peer's entity can be owned by another peer")
	_check(t.set_owner("a", 12, KIND6, 1.0, 1.0, 2000) and t.note_input("a", _b6(1), 2100) and t.accepted_count("a") == 1,
		"T1: a rejoining peer's low ticks are accepted again (its old last tick of 50 was forgotten)")
	# reset keeps registrations and policy vars.
	t.extrapolate_cap_ms = 60
	t.stale_ms = 250
	t.stale_mode = CouchOwnerTargets.REPORT_ONLY
	t.reset()
	_check(t.entity_of("b") == -1 and t.entity_of("c") == -1 and t.entity_of("a") == -1 and t.accepted_count("b") == 0 and t.reject_count("ghost", "unowned") == 0,
		"T1: reset drops every owner and every counter")
	_check(t.target_for("b", 1000).is_empty() and not t.is_stale("b", 99999), "T1: reset drops reports")
	_check(t.extrapolate_cap_ms == 60 and t.stale_ms == 250 and t.stale_mode == CouchOwnerTargets.REPORT_ONLY, "T1: reset keeps the policy vars")
	_check(t.set_owner("b", 11, KIND6, 1.0, 1.0, 0) and t.set_owner("n", 20, KIND_NR, 1.0, 1.0, 0) and t.set_owner("e", 21, KIND7, 1.0, 1.0, 0),
		"T1: reset keeps the set_channels registrations (set_owner works without set_channels again)")
	_check(t.note_input("b", _b6(1), 10) and t.accepted_count("b") == 1, "T1: after reset ticks start over")


func _t1_impulse() -> void:
	var t := _owner_a()
	var ring := CouchEventRing.new()
	_check(CouchOwnedEntity.IMPULSE_EVENT_KIND == -1, "T1: IMPULSE_EVENT_KIND is -1")
	var id: int = t.push_impulse(ring, "a", Vector2(3.0, -4.0), 0.5, 77)
	var pend: Array = ring.pending_for("a")
	var ok: bool = pend.size() == 1 and typeof(pend[0]) == TYPE_ARRAY and (pend[0] as Array).size() == 3
	_check(id == 1 and ok and _int_is(pend[0][0], 1) and _int_is(pend[0][1], -1) and _pfclose(pend[0][2], [3.0, -4.0, 0.5]),
		"T1: push_impulse pushes [id 1, kind -1, PackedFloat32Array([jx, jy, aj])] and returns the id")
	_check(_is_pf(pend[0][2] if ok else null) and _psize(pend[0][2] if ok else null) == 3, "T1: the payload is a PackedFloat32Array of size 3")
	_check(t.push_impulse(ring, "a", Vector2(-1.0, 2.0), -0.25, 80) == 2 and ring.highest_id("a") == 2 and ring.pending_for("a").size() == 2,
		"T1: the next push returns the next per-peer id (2)")
	ring.expire(77 + 120)
	_check(ring.pending_for("a").size() == 2 and ring.expired_count("a") == 0, "T1: the host_tick passed through: not expired at 77 + max_age")
	ring.expire(77 + 121)
	_check(ring.pending_for("a").size() == 1 and ring.expired_count("a") == 1, "T1: ...and the first impulse (tick 77) expires one tick later; the second (tick 80) does not")
	_check(ring.pending_for("b").is_empty(), "T1: the impulse went to the owner's stream only")
	var r2 := CouchEventRing.new()
	_check(t.push_impulse(r2, "nobody", Vector2(1, 1), 1.0, 5) == -1 and r2.highest_id("nobody") == 0 and r2.pending_for("nobody").is_empty(),
		"T1: push_impulse for a non-owner returns -1 and pushes nothing")
	var bads := [["x NAN", Vector2(NAN, 1.0), 0.0], ["y INF", Vector2(1.0, INF), 0.0], ["x -INF", Vector2(-INF, 1.0), 0.0], ["angular NAN", Vector2(1, 1), NAN], ["angular INF", Vector2(1, 1), INF]]
	for b in bads:
		_check(t.push_impulse(r2, "a", b[1], b[2], 5) == -1 and r2.highest_id("a") == 0 and r2.pending_for("a").is_empty(),
			"T1: push_impulse with a non-finite value (%s) returns -1 and pushes nothing" % b[0])
	_check(t.push_impulse(r2, "a", Vector2.ZERO, 0.0, 5) == 1, "T1: a zero impulse is finite and is pushed")


# --- O1 / I1: CouchOwnedEntity -------------------------------------------------------------


func _case_o1() -> void:
	print("O1: CouchOwnedEntity.input_fields")
	var w := _new_world()
	var oe := CouchOwnedEntity.new(w, 10, KIND6)
	var inbox := CouchEventInbox.new()
	inbox.receive([[1, 5, "x"], [2, 5, "y"]])
	var state := _pf(BASE_O)
	var f: Dictionary = oe.input_fields(42, state, inbox)
	_check(f.size() == 3 and f.has("t") and f.has("o") and f.has("ev"), "O1: input_fields returns exactly {t, o, ev}: keys %s" % [f.keys()])
	_check(_int_is(_dg(f, "t"), 42) and _int_is(_dg(f, "ev"), 2) and inbox.last_applied() == 2, "O1: t is the tick passed in, ev is inbox.last_applied() (2)")
	_check(_pfclose(_dg(f, "o"), BASE_O) and _is_pf(_dg(f, "o")), "O1: o holds the state's values as a PackedFloat32Array")
	var o: Variant = _dg(f, "o")
	if _is_pf(o):
		(o as PackedFloat32Array)[0] = -77.0
	_check(_at(state, 0) == 10.0, "O1: mutating the returned o does not change the caller's state (a COPY)")
	state[1] = 55.0
	_check(_close(_at(_dg(f, "o"), 1), -4.0), "O1: mutating the caller's state afterwards does not change the returned o")
	_check(oe.refused_count == 0, "O1: refused_count starts at 0 and a success does not raise it")
	f = oe.input_fields(0, _pf(BASE_O), null)
	_check(_int_is(_dg(f, "t"), 0) and _int_is(_dg(f, "ev"), 0) and _pfclose(_dg(f, "o"), BASE_O), "O1: tick 0 is fine and a null inbox gives ev 0")
	inbox.receive([[3, 5, "z"]])
	_check(_int_is(_dg(oe.input_fields(1, _pf(BASE_O), inbox), "ev"), 3), "O1: ev follows the inbox as it advances (3)")
	# Refusals.
	var refusals := [
		["a short state (5)", oe, _pf([1, 2, 3, 4, 5])], ["a long state (7)", oe, _pf([1, 2, 3, 4, 5, 6, 7])], ["an empty state", oe, PackedFloat32Array()],
		["a NAN value", oe, _pf([NAN, 2, 3, 4, 5, 6])], ["an INF value", oe, _pf([1, 2, 3, 4, 5, INF])], ["a -INF value", oe, _pf([1, -INF, 3, 4, 5, 6])],
	]
	var expect := 0
	for rf in refusals:
		expect += 1
		var res: Dictionary = (rf[1] as CouchOwnedEntity).input_fields(7, rf[2], inbox)
		_check(typeof(res) == TYPE_DICTIONARY and res.is_empty() and oe.refused_count == expect, "O1: %s -> {} and refused_count %d" % [rf[0], expect])
	var unk := CouchOwnedEntity.new(w, 10, 77)
	var ru: Dictionary = unk.input_fields(7, _pf(BASE_O), inbox)
	_check(ru.is_empty() and unk.refused_count == 1, "O1: an unregistered kind -> {} and refused_count 1")
	# Review finding: an unregistered kind has stride 0 in kind_channels(), so an EMPTY state
	# must still be refused on the kind, not accepted as stride-correct.
	ru = unk.input_fields(8, PackedFloat32Array(), inbox)
	_check(ru.is_empty() and unk.refused_count == 2, "O1: an unregistered kind with an EMPTY state -> {} and refused_count 2")
	var o7 := CouchOwnedEntity.new(w, 10, KIND7)
	_check(o7.input_fields(7, _pf(BASE_O), inbox).is_empty() and o7.refused_count == 1 and _pfclose(_dg(o7.input_fields(8, _pf([1, 2, 3, 4, 5, 6, 7]), inbox), "o"), [1, 2, 3, 4, 5, 6, 7]),
		"O1: the stride comes from the kind (a 7-stride kind refuses 6 values and accepts 7)")


func _case_i1() -> void:
	print("I1: impulse_of")
	var good := CouchOwnedEntity.impulse_of([3, -1, _pf([1.5, -2.5, 0.75])])
	_check(good.size() == 2 and _v2close(_dg(good, "j"), Vector2(1.5, -2.5)) and _close(_dg(good, "a"), 0.75) and _isf(_dg(good, "a")),
		"I1: impulse_of([id, -1, [jx, jy, aj]]) -> {j: Vector2, a: float}: %s" % [good])
	_check(CouchOwnedEntity.impulse_of([1, -1, _pf([0, 0, 0])]).size() == 2, "I1: a zero impulse is valid")
	var bad := [
		["kind 0", [3, 0, _pf([1, 2, 3])]], ["kind -2", [3, -2, _pf([1, 2, 3])]], ["kind 7", [3, 7, _pf([1, 2, 3])]],
		["payload size 2", [3, -1, _pf([1, 2])]], ["payload size 4", [3, -1, _pf([1, 2, 3, 4])]], ["payload size 0", [3, -1, PackedFloat32Array()]],
		["NAN", [3, -1, _pf([NAN, 2, 3])]], ["INF in y", [3, -1, _pf([1, INF, 3])]], ["-INF angular", [3, -1, _pf([1, 2, -INF])]],
		["payload an Array", [3, -1, [1.0, 2.0, 3.0]]], ["payload a PackedFloat64Array", [3, -1, PackedFloat64Array([1, 2, 3])]],
		["payload a Vector3", [3, -1, Vector3(1, 2, 3)]], ["payload null", [3, -1, null]], ["payload a Dictionary", [3, -1, {"j": 1}]],
		["event null", null], ["event an int", 5], ["event a Dictionary", {"id": 1}], ["event size 2", [3, -1]], ["event empty", []],
	]
	for b in bad:
		var r: Dictionary = CouchOwnedEntity.impulse_of(b[1])
		_check(typeof(r) == TYPE_DICTIONARY and r.is_empty(), "I1: impulse_of refuses %s -> {}" % b[0])
	# Round trips through the ring + inbox, and through pack / ingest.
	var t := _owner_a()
	var ring := CouchEventRing.new()
	t.push_impulse(ring, "a", Vector2(120.0, -160.0), 1.5, 10)
	t.push_impulse(ring, "a", Vector2(-3.0, 4.0), -0.5, 11)
	ring.push("a", 7, "a game event", 12)
	var inbox := CouchEventInbox.new()
	var got: Array = inbox.receive(ring.pending_for("a"))
	var imps: Array = []
	for e in got:
		imps.append(CouchOwnedEntity.impulse_of(e))
	_check(got.size() == 3 and imps.size() == 3 and _v2close(_dg(imps[0], "j"), Vector2(120, -160)) and _close(_dg(imps[0], "a"), 1.5)
		and _v2close(_dg(imps[1], "j"), Vector2(-3, 4)) and _close(_dg(imps[1], "a"), -0.5) and _dg(imps[2], "j") == null and CouchOwnedEntity.impulse_of(got[2]).is_empty(),
		"I1: ring -> inbox -> impulse_of round trip gives the pushed values; a game event (kind 7) is not an impulse")
	var host := _new_world()
	var ring2 := CouchEventRing.new()
	var t2 := _new_targets(host)
	t2.set_owner("a", 10, KIND6, 1.0, 1.0, 0)
	t2.push_impulse(ring2, "a", Vector2(9.0, -8.0), 0.25, 5)
	var body: Dictionary = host.pack(5, 1000, {"a": 3}, null, ring2)
	var client := _new_world()
	_check(client.ingest(body), "I1: the packed snapshot ingests")
	var ps: Dictionary = client.peer_section("a")
	var ev_in: Variant = _dg(ps, "ev")
	var inbox2 := CouchEventInbox.new()
	var evs: Array = inbox2.receive(ev_in if typeof(ev_in) == TYPE_ARRAY else [])
	var imp2: Dictionary = CouchOwnedEntity.impulse_of(evs[0]) if evs.size() == 1 else {}
	_check(evs.size() == 1 and _v2close(_dg(imp2, "j"), Vector2(9, -8)) and _close(_dg(imp2, "a"), 0.25),
		"I1: ring -> pack -> ingest -> peer_section -> inbox -> impulse_of round trip")


# --- S1 / S2 harness -----------------------------------------------------------------------


const HOST_ID := "host"
const HOST_EID := 100
const EID_BASE := 10
const WARM_MS := 4000
const KNOCK_MS := 9000
const TELE_MS := 6500
const TELE_DX := 400.0
const KNOCK_J := Vector2(120.0, -160.0)
const KNOCK_A := 1.5
const SNAP_DIST := 150.0


## One owner: roster / transport / session doubles, a clock, a client world, its own toy body.
class _Own extends RefCounted:
	var id := ""
	var idx := 0
	var eid := -1
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
	var down_base := 50
	var up_base := 50
	var jitter := 30
	var loss_down := 0.03
	var loss_up := 0.02
	var dropped := 0
	# The owner's toy body: a velocity-following point (v relaxes to the scripted u).
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
	var tele_at := -1
	var tele_t := -1
	var applied_count := 0
	var applied_ids: Array = []
	var foreign_events := 0
	var refused := 0
	var sent := 0
	var hist: Array = []   # [T, x, y, rot] per owner tick
	var snaps_in := 0
	var ev_snapshots := 0
	var started_count := 0
	# Client-view observations.
	var frames := 0
	var local_leak := 0
	var local_buffered := 0
	var others_present := 0
	var view_samples := 0
	var view_err := 0.0
	var view_rot_err := 0.0
	var relay_seen: Dictionary = {}   # eid -> last relayed extra channel seen
	var view_span: Dictionary = {}    # stand-in eid -> [min x, max x] sampled
	var render_back := 0
	var prev_r := 0
	var prev_valid := false


## The simulated session: a real CouchSession host + N real CouchSession owners.
class _OSim extends RefCounted:
	const FAR_T := 1 << 60
	var T := 1000
	var impaired := true
	var immediate := true
	var owners: Dictionary = {}
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
	var standins: Dictionary = {}      # peer -> Dictionary (host stand-in body + stats)
	var hist: Dictionary = {}          # eid -> Array of [x, y, rot] indexed by host tick
	var jumps: Dictionary = {}         # eid -> {tick: true} where the host state jumped
	var queue: Array = []
	var seq := 0
	var host_rng := RandomNumberGenerator.new()
	var next_host_t := 0
	var next_snap := 0
	var players: Array = []
	var snapshots_sent := 0
	var mk_check: Callable
	# Host-side observations.
	var accepted_inputs: Dictionary = {}   # peer -> count
	var align_violations := 0
	var align_samples := 0
	var rejected_inputs := 0
	var knock_peers: Dictionary = {}       # peer -> {"at": ms, "id": int}
	var knock_first_dv: Dictionary = {}    # peer -> |dv| of the first accepted report with ev >= 1
	var prev_o: Dictionary = {}
	var impulse_ids: Dictionary = {}
	var left_log: Array = []
	var joined_log: Array = []
	var knock_at := -1
	var knock_peer := ""
	var knock_tick := -1
	var knock_id := 0
	var err_stats: Dictionary = {}

	func _init(seed_value: int, n_guests: int, p_impaired: bool) -> void:
		impaired = p_impaired
		host_rng.seed = seed_value
		host_roster = null
		host_world = _world()
		ring = CouchEventRing.new()
		echo = CouchNetClockEcho.new()
		ticker = CouchFixedTicker.new(60)
		pol = CouchPDFollowerPolicy.new()
		pol.snap_distance = SNAP_DIST
		targets = CouchOwnerTargets.new(host_world)
		targets.set_channels(KIND7, CouchBodyChannels.new({"x": 0, "y": 1, "rot": 2, "vx": 3, "vy": 4, "w": 5}))
		var ids: Array = []
		for i in n_guests:
			ids.append("p%d" % (i + 1))
		players = [_pl(HOST_ID, "host", 0)]
		for i in ids.size():
			players.append(_pl(ids[i], "guest", i + 1))
		var policy := CouchSessionPolicy.new()
		policy.max_input_players = n_guests
		host_roster = CouchScriptedRoster.new(HOST_ID, players)
		host_transport = CouchScriptedTransport.new()
		host_session = CouchSession.new(host_roster, host_transport, policy)
		host_session.player_joined.connect(_on_joined)
		host_session.player_left.connect(_on_left)
		host_session.input_received.connect(_on_input)
		hist[HOST_EID] = []
		jumps[HOST_EID] = {}
		for i in ids.size():
			owners[ids[i]] = _new_owner(ids[i], i, policy)

	func _world() -> CouchReplicatedWorld:
		var wd := CouchReplicatedWorld.new()
		wd.register_kind(KIND6, [LERP, LERP, ANGLE, LERP, LERP, LERP])
		wd.register_kind(KIND_NR, [LERP, LERP, LERP, LERP])
		wd.register_kind(KIND7, [LERP, LERP, ANGLE, LERP, LERP, LERP, SNAP])
		wd.register_kind(KIND_FREE, [LERP, LERP, ANGLE, LERP, LERP, LERP])
		return wd

	static func _pl(id: String, role: String, slot: int) -> Dictionary:
		return {"userId": id, "username": id.to_upper(), "role": role, "controllerSlot": slot}

	func _new_owner(id: String, i: int, policy: CouchSessionPolicy) -> _Own:
		var o := _Own.new()
		o.id = id
		o.idx = i
		o.roster = CouchScriptedRoster.new(id, players)
		o.transport = CouchScriptedTransport.new()
		o.session = CouchSession.new(o.roster, o.transport, policy)
		o.session.snapshot_received.connect(_on_snapshot.bind(o))
		o.session.session_started.connect(func(_e: int, _h: bool, _s: int, _p: String, _n: String): o.started_count += 1)
		var bases := [50, 45, 55, 52]
		var losses := [0.02, 0.03, 0.04, 0.03]
		o.down_base = bases[i % 4]
		o.up_base = bases[(i + 1) % 4]
		o.loss_down = losses[i % 4]
		o.loss_up = losses[(i + 2) % 4]
		o.net_rng.seed = host_rng.seed * 31 + i * 7 + 1
		o.frame_rng.seed = host_rng.seed * 17 + i * 5 + 3
		o.offset_ms = 987_654 + i * 13_579
		o.next_t = T + 7 + i * 5
		var policy_c := CouchNetClockPolicy.new()
		policy_c.render_delay_ticks = 7
		o.clock = CouchNetClock.new(policy_c)
		o.world = _world()
		o.inbox = CouchEventInbox.new()
		var om_x := [1.3, 1.9, 2.4, 1.6]
		var om_y := [1.7, 1.1, 1.5, 2.0]
		var wn := [1.1, 2.0, -2.6, 1.4]
		o.om_x = om_x[i % 4]
		o.om_y = om_y[i % 4]
		o.w_nom = wn[i % 4]
		o.x = spawn_x(i + 1)
		o.y = 0.0
		return o

	static func spawn_x(slot: int) -> float:
		return 100.0 * float(slot)

	func _setup_owner(o: _Own) -> void:
		var slot: int = o.session.local_slot
		o.eid = EID_BASE + slot
		o.owned = CouchOwnedEntity.new(o.world, o.eid, KIND7)
		o.world.set_local([o.eid])

	# --- boot / roster ---

	func boot() -> void:
		immediate = true
		host_session.evaluate(T)
		for id in owners:
			(owners[id] as _Own).session.evaluate(T)
		_collect_all()
		pump_now()
		for id in owners:
			_setup_owner(owners[id])
		ticker.start(T, 0)
		next_host_t = T + 3
		immediate = not impaired

	func set_roster(p: Array) -> void:
		players = p
		host_roster.set_players(players)
		for id in owners:
			(owners[id] as _Own).roster.set_players(players)
		host_session.evaluate(T)
		for id in owners.keys():
			(owners[id] as _Own).session.evaluate(T)
		_collect_all()
		pump_now()

	func roster_with(ids: Array) -> Array:
		var out: Array = [_pl(HOST_ID, "host", 0)]
		for id in ids:
			out.append(_pl(id, "guest", int(str(id).substr(1))))
		return out

	func leave(id: String, remaining: Array) -> void:
		owners.erase(id)
		set_roster(roster_with(remaining))

	func join(id: String, all_ids: Array) -> _Own:
		var policy := CouchSessionPolicy.new()
		policy.max_input_players = 2
		players = roster_with(all_ids)
		var o := _new_owner(id, int(id.substr(1)) - 1, policy)
		owners[id] = o
		set_roster(roster_with(all_ids))
		_setup_owner(o)
		return o

	func new_epoch() -> void:
		targets.reset()
		ring.reset()
		host_world.reset()
		echo.reset()
		acks.clear()
		standins.clear()
		for id in owners:
			var o: _Own = owners[id]
			o.inbox.reset()
			o.world.reset()
			o.clock.reset()
			o.ev_latest = []

	# --- transport ---

	func _transport_of(id: String) -> CouchScriptedTransport:
		return host_transport if id == HOST_ID else (owners[id] as _Own).transport

	func _has_side(id: String) -> bool:
		return id == HOST_ID or owners.has(id)

	func _collect_all() -> void:
		_collect(HOST_ID)
		for id in owners.keys():
			_collect(id)

	func _collect(id: String) -> void:
		if not _has_side(id):
			return
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
		if not _has_side(to):
			return
		var arrive := T
		if impaired and not immediate:
			var o: _Own = owners[to if from == HOST_ID else from]
			var kind := str(env["kind"])
			var down := from == HOST_ID
			var loss := o.loss_down if down else o.loss_up
			if (kind == CouchEnvelope.KIND_SNAPSHOT or kind == CouchEnvelope.KIND_INPUT) and o.net_rng.randf() < loss:
				o.dropped += 1
				return
			var base := o.down_base if down else o.up_base
			arrive = T + maxi(base + o.net_rng.randi_range(-o.jitter, o.jitter), 1)
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
		if not _has_side(to):
			return
		_transport_of(to).deliver(msg["env"], msg["from"])
		_collect(to)

	## Deliver everything due now (instant control-plane / unimpaired mode).
	func pump_now() -> void:
		for _i in 2000:
			var msg: Variant = _pop_due(T)
			if msg == null:
				return
			T = maxi(T, int(msg["arrive"]))
			_deliver(msg)
		mk_check.call(false, "pump_now settles")

	# --- host game wiring (the contract's "Game wiring") ---

	func _on_joined(peer: String, slot: int) -> void:
		var eid := EID_BASE + slot
		var mass := 2.0 if slot == 1 else 1.0
		var inertia := 3.0 if slot == 1 else 1.0
		targets.set_owner(peer, eid, KIND7, mass, inertia, T)
		var sx := spawn_x(slot)
		host_world.set_entity(eid, KIND7, PackedFloat32Array([sx, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]))
		var map := CouchBodyChannels.new({"x": 0, "y": 1, "rot": 2, "vx": 3, "vy": 4, "w": 5})
		standins[peer] = {"eid": eid, "x": sx, "y": 0.0, "rot": 0.0, "vx": 0.0, "vy": 0.0, "w": 0.0,
			"mass": mass, "inertia": inertia, "rigid": slot == 1, "follower": CouchPDFollower.new(map, pol, 1.0 / 60.0),
			"extra": 0.0, "snaps": 0, "snap_ticks": [], "err_sum": 0.0, "err_n": 0, "err_max": 0.0, "win_max": 0.0, "end_err": 0.0, "end_n": 0,
			"after_snap_max": 0.0, "after_snap_n": 0, "snap_T": -1}
		hist[eid] = []
		jumps[eid] = {}
		accepted_inputs[peer] = 0
		acks[peer] = -1   # a peer gets a snapshot section (and so its clock sync) from its first snapshot
		joined_log.append([peer, slot])

	func _on_left(peer: String, slot: int) -> void:
		left_log.append([peer, slot])
		var s: Variant = standins.get(peer)
		targets.forget(peer)
		ring.forget(peer)
		echo.forget(peer)
		acks.erase(peer)
		if s != null:
			host_world.remove_entity(int(s["eid"]))
			standins.erase(peer)

	func _on_input(body: Dictionary, sender: String) -> void:
		ring.ack(sender, int(body.get("ev", 0)))
		var ok := targets.note_input(sender, body, T)
		if not ok:
			rejected_inputs += 1
			return
		var tk := int(body["t"])
		acks[sender] = maxi(int(acks.get(sender, -1)), tk)
		echo.note_input(sender, tk, ticker.next_tick, T)
		var o: Variant = body.get("o")
		accepted_inputs[sender] = int(accepted_inputs.get(sender, 0)) + 1
		if typeof(o) == TYPE_PACKED_FLOAT32_ARRAY and (o as PackedFloat32Array).size() == 7:
			var arr: PackedFloat32Array = o
			align_samples += 1
			if int(arr[6]) != int(body.get("ev", 0)):
				align_violations += 1
			if int(body.get("ev", 0)) >= 1 and not knock_first_dv.has(sender) and prev_o.has(sender):
				var pv: PackedFloat32Array = prev_o[sender]
				knock_first_dv[sender] = Vector2(arr[3] - pv[3], arr[4] - pv[4]).length()
			prev_o[sender] = arr.duplicate()

	func _host_tick(tk: int, th: int) -> void:
		var tt := float(tk) / 60.0
		var hx := 40.0 * sin(1.2 * tt) - 100.0
		var hy := 30.0 * cos(0.9 * tt)
		var hrot := _wrapf(1.5 * tt)
		(hist[HOST_EID] as Array).append([hx, hy, hrot])
		host_world.set_entity(HOST_EID, KIND7, PackedFloat32Array([hx, hy, hrot, 0.0, 0.0, 1.5, 0.0]))
		if knock_at >= 0 and knock_tick < 0 and th >= knock_at and standins.has(knock_peer):
			knock_id = targets.push_impulse(ring, knock_peer, KNOCK_J, KNOCK_A, tk)
			knock_tick = tk
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
				s["snaps"] = int(s["snaps"]) + 1
				(s["snap_ticks"] as Array).append(tk)
				s["snap_T"] = th
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
			if not (snapped is bool and snapped):
				s["x"] += s["vx"] / 60.0
				s["y"] += s["vy"] / 60.0
				s["rot"] = _wrapf(s["rot"] + s["w"] / 60.0)
			var relay := 0.0
			if tgt.size() == 7:
				relay = tgt[6]
			s["extra"] = relay
			host_world.set_entity(int(s["eid"]), KIND7, PackedFloat32Array([s["x"], s["y"], s["rot"], s["vx"], s["vy"], s["w"], relay]))
			var eh: Array = hist[int(s["eid"])]
			if not eh.is_empty():
				var prev: Array = eh[eh.size() - 1]
				if absf(float(prev[0]) - float(s["x"])) > 50.0 or absf(float(prev[1]) - float(s["y"])) > 50.0:
					jumps[int(s["eid"])][eh.size()] = true
			eh.append([s["x"], s["y"], s["rot"]])
			_observe_standin(peer, s, th)

	static func _wrapf(v: float) -> float:
		return wrapf(v, -PI, PI)

	## Owner true position at global time tt (interpolating the owner's tick log).
	func owner_at(peer: String, tt: float) -> Array:
		var o: Variant = owners.get(peer)
		if o == null:
			return []
		var arr: Array = (o as _Own).hist
		var n := arr.size()
		if n == 0 or tt < float(arr[0][0]):
			return []
		if tt >= float(arr[n - 1][0]):
			return [arr[n - 1][1], arr[n - 1][2], arr[n - 1][3]]
		var lo := 0
		var hi := n - 1
		while hi - lo > 1:
			var mid := (lo + hi) >> 1
			if float(arr[mid][0]) <= tt:
				lo = mid
			else:
				hi = mid
		var a: Array = arr[lo]
		var b: Array = arr[hi]
		var span := float(b[0]) - float(a[0])
		var f := 0.0 if span <= 0.0 else (tt - float(a[0])) / span
		return [lerpf(a[1], b[1], f), lerpf(a[2], b[2], f), wrapf(float(a[3]) + wrapf(float(b[3]) - float(a[3]), -PI, PI) * f, -PI, PI)]

	func _observe_standin(peer: String, s: Dictionary, th: int) -> void:
		if th < WARM_MS:
			return
		var truth: Array = owner_at(peer, float(th))
		if truth.is_empty():
			return
		var err := Vector2(float(s["x"]) - float(truth[0]), float(s["y"]) - float(truth[1])).length()
		if int(s["snap_T"]) >= 0 and th - int(s["snap_T"]) <= 1000:
			s["after_snap_max"] = maxf(float(s["after_snap_max"]), err)
			s["after_snap_n"] = int(s["after_snap_n"]) + 1
		var in_window := false
		if peer == "p2" and knock_tick >= 0 and th >= knock_at and th < knock_at + 1500:
			in_window = true
		if peer == "p3":
			var tele_t: int = (owners["p3"] as _Own).tele_t
			if tele_t >= 0 and th >= tele_t and th < tele_t + 1500:
				in_window = true
		if in_window:
			s["win_max"] = maxf(float(s["win_max"]), err)
		else:
			s["err_sum"] = float(s["err_sum"]) + err
			s["err_n"] = int(s["err_n"]) + 1
			s["err_max"] = maxf(float(s["err_max"]), err)
		if th >= end_window_from:
			s["end_err"] = maxf(float(s["end_err"]), err)
			s["end_n"] = int(s["end_n"]) + 1

	var end_window_from := FAR_T

	func host_snapshot(th: int) -> void:
		var last := ticker.next_tick - 1
		var body := host_world.pack(last, th, acks, echo, ring, {})
		if host_session.broadcast_snapshot(body):
			snapshots_sent += 1
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
		o.snaps_in += 1
		var ps := o.world.peer_section(o.id)
		if ps.is_empty():
			return
		var cn := T + o.offset_ms
		o.clock.on_snapshot(int(ps["ht"]), cn)
		if ps.has("rt"):
			o.clock.on_echo(int(ps["rt"]), int(ps["hm"]), int(ps["mg"]), cn)
		var evs: Array = ps["ev"]
		o.ev_latest = evs
		if not evs.is_empty():
			o.ev_snapshots += 1

	## One owner tick, in the contract's ALIGNMENT order: receive + apply events, step the
	## body, THEN input_fields. `tc` is the global time the tick runs at.
	func owner_tick(o: _Own, tk: int, tc: int) -> void:
		for e in o.inbox.receive(o.ev_latest):
			var imp: Dictionary = CouchOwnedEntity.impulse_of(e)
			var j: Variant = imp.get("j")
			if typeof(j) != TYPE_VECTOR2:
				o.foreign_events += 1
				continue
			o.vx += j.x
			o.vy += j.y
			o.w += float(imp.get("a", 0.0))
			o.applied_count += 1
			o.applied_ids.append(int(e[0]))
		if o.tele_at >= 0 and o.tele_t < 0 and tc >= o.tele_at:
			o.x += TELE_DX
			o.tele_t = tc
		var t := float(tk) / 60.0
		var ux := o.amp_x * o.om_x * cos(o.om_x * t)
		var uy := o.amp_y * o.om_y * cos(o.om_y * t + 1.0)
		o.vx += (ux - o.vx) * 6.0 / 60.0
		o.vy += (uy - o.vy) * 6.0 / 60.0
		o.w += (o.w_nom - o.w) * 6.0 / 60.0
		o.x += o.vx / 60.0
		o.y += o.vy / 60.0
		o.rot = wrapf(o.rot + o.w / 60.0, -PI, PI)
		o.hist.append([tc, o.x, o.y, o.rot])
		var state := PackedFloat32Array([o.x, o.y, o.rot, o.vx, o.vy, o.w, float(o.applied_count)])
		var fields: Dictionary = o.owned.input_fields(tk, state, o.inbox)
		if fields.is_empty():
			o.refused += 1
			return
		var body := {"extra_game_field": 1}
		body.merge(fields)
		if o.session.send_input(body):
			o.sent += 1
		_collect(o.id)

	func _owner_frame(o: _Own, tc: int) -> void:
		o.next_t = tc + maxi(16 + o.frame_rng.randi_range(-4, 4), 1)
		var cn := tc + o.offset_ms
		for tk in o.clock.advance(cn):
			owner_tick(o, int(tk), tc)
		if not o.clock.synced:
			return
		var r := o.clock.render_tick_milli(cn)
		if o.prev_valid and r < o.prev_r:
			o.render_back += 1
		o.prev_r = r
		o.prev_valid = true
		o.frames += 1
		var s := o.world.sample(r)
		if tc < WARM_MS:
			return
		o.local_buffered += 1 if not o.world.latest(o.eid).is_empty() else 0
		if s.has(o.eid):
			o.local_leak += 1
		var all_here := true
		for oid in owners:
			var other: _Own = owners[oid]
			if other != o and not s.has(other.eid):
				all_here = false
		if not s.has(HOST_EID):
			all_here = false
		if all_here:
			o.others_present += 1
		var watch: Array = [HOST_EID]
		for oid in owners:
			if oid != o.id:
				watch.append((owners[oid] as _Own).eid)
		for eid in watch:
			if not s.has(eid):
				continue
			var st: PackedFloat32Array = s[eid]
			if st.size() != 7:
				continue
			o.relay_seen[eid] = st[6]
			if eid != HOST_EID:
				var sp: Array = o.view_span.get(eid, [INF, -INF])
				sp[0] = minf(sp[0], st[0])
				sp[1] = maxf(sp[1], st[0])
				o.view_span[eid] = sp
			var i := r / 1000
			var f := float(r % 1000) / 1000.0
			var eh: Array = hist[eid]
			if i < 8 or i + 1 >= eh.size():
				continue
			var skip := false
			for k in range(i - 8, i + 4):
				if (jumps[eid] as Dictionary).has(k):
					skip = true
			if skip:
				continue
			var a: Array = eh[i]
			var b: Array = eh[i + 1]
			var ex := lerpf(a[0], b[0], f)
			var ey := lerpf(a[1], b[1], f)
			var er := wrapf(float(a[2]) + wrapf(float(b[2]) - float(a[2]), -PI, PI) * f, -PI, PI)
			o.view_samples += 1
			o.view_err = maxf(o.view_err, Vector2(st[0] - ex, st[1] - ey).length())
			o.view_rot_err = maxf(o.view_rot_err, absf(wrapf(st[2] - er, -PI, PI)))

	func run_until(end_t: int) -> void:
		while true:
			var best := FAR_T
			var kind := -1
			var which := ""
			var m: Variant = null
			var m_t := FAR_T
			for q in queue:
				if int(q["arrive"]) < m_t:
					m_t = int(q["arrive"])
			if m_t < FAR_T:
				best = m_t
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
					m = _pop_due(T)
					if m != null:
						_deliver(m)
				2:
					_host_frame(T)
				3:
					_owner_frame(owners[which], T)
		T = maxi(T, end_t)


# --- S1 ------------------------------------------------------------------------------------


func _case_s1() -> void:
	print("S1: host + 3 owners (real CouchSessions), lossy jittery links, scripted paths, one knock, one teleport")
	var sim := _OSim.new(4242, 3, true)
	sim.mk_check = _check
	sim.boot()
	var ok_boot := true
	for id in sim.owners:
		var o: _Own = sim.owners[id]
		ok_boot = ok_boot and o.session.active and o.session.local_slot >= 1
	_check(ok_boot and sim.host_session.active and sim.host_session.max_input_players == 3 and sim.joined_log.size() == 3 and sim.targets.entity_of("p1") == 11 and sim.targets.entity_of("p3") == 13,
		"S1: boot: 3 guests hold input slots 1..3, player_joined fired x3, and the host game owns entities 11..13 through set_owner")
	(sim.owners["p3"] as _Own).tele_at = TELE_MS
	sim.knock_at = KNOCK_MS
	sim.knock_peer = "p2"
	sim.end_window_from = 16_000
	sim.run_until(18_000)

	# Presence guards so an inert implementation cannot pass vacuously.
	var min_acc := 1 << 30
	for id in sim.owners:
		min_acc = mini(min_acc, int(sim.accepted_inputs.get(id, 0)))
	_check(min_acc > 600 and sim.snapshots_sent > 300 and sim.align_samples > 1800,
		"S1: the session ran: every owner had > 600 inputs accepted (min %d), %d snapshots sent, %d inputs checked for alignment" % [min_acc, sim.snapshots_sent, sim.align_samples])
	var impaired_ok := true
	for id in sim.owners:
		impaired_ok = impaired_ok and (sim.owners[id] as _Own).dropped > 15
	_check(impaired_ok and sim.host_session.rejected_count > 0, "S1: the impairment really happened (messages dropped on every link; reordered ones rejected by the session tracker: %d)" % sim.host_session.rejected_count)
	for id in sim.owners:
		var o: _Own = sim.owners[id]
		_check(o.clock.synced and o.snaps_in > 300 and o.refused == 0 and o.sent > 800 and o.render_back == 0,
			"S1/%s: clock synced, %d snapshots ingested, %d inputs sent, none refused by input_fields, render time never ran backwards" % [id, o.snaps_in, o.sent])

	# BOUNDS (chosen from the maths, then checked against a reference run; observed worst values
	# in the comments). The owner moves at <= ~190 u/s with accel <= ~300 u/s^2. A stand-in chases
	# the newest accepted report extrapolated by its velocity for <= 100 ms, then held. A report is
	# ~80 ms old (one-way delay 50 +/- 30) plus up to a tick or two of quantisation, and ~30% of
	# inputs are lost or dropped as reordered duplicates, so the newest report is sometimes 150-200
	# ms old: beyond the 100 ms cap the target stops moving, i.e. an error of up to ~0.05-0.1 s of
	# speed = 10-19 units, usually far less. So: mean <= 6 (observed ~2.3), max <= 25 (observed
	# ~10). A stand-in that did not follow would sit ~100 units away (the paths span +/-80).
	# Convergence of every stand-in to its owner's true path.
	for id in sim.owners:
		var s: Dictionary = sim.standins.get(id, {})
		var n := int(s.get("err_n", 0))
		var mean := float(s.get("err_sum", 0.0)) / float(maxi(n, 1))
		var emax := float(s.get("err_max", 99999.0))
		_check(n > 600 and mean <= 6.0 and emax <= 25.0,
			"S1/%s: stand-in tracks the owner's true path once warm (outside the knock / teleport windows): mean error %.2f <= 6, max %.2f <= 25 over %d host ticks" % [id, mean, emax, n])
		_check(int(s.get("end_n", 0)) > 100 and float(s.get("end_err", 99999.0)) <= 25.0,
			"S1/%s: ...and it has re-converged by the end of the run (max error over the last second %.2f <= 25, %d ticks)" % [id, float(s.get("end_err", 99999.0)), int(s.get("end_n", 0))])

	# The knock.
	var p2: _Own = sim.owners["p2"]
	var ring: CouchEventRing = sim.ring
	_check(sim.knock_id == 1 and ring.highest_id("p2") == 1 and ring.highest_id("p1") == 0 and ring.highest_id("p3") == 0,
		"S1: the scripted host impulse was pushed once, to p2 only (id %d, highest ids p1 %d / p2 %d / p3 %d)" % [sim.knock_id, ring.highest_id("p1"), ring.highest_id("p2"), ring.highest_id("p3")])
	_check(p2.applied_ids == [1] and p2.applied_count == 1 and p2.inbox.last_applied() == 1 and p2.foreign_events == 0,
		"S1: p2 applied the impulse exactly once (applied ids %s) although it travelled in %d snapshots" % [p2.applied_ids, p2.ev_snapshots])
	_check(p2.ev_snapshots >= 2, "S1: the event really was repeated in >= 2 snapshots (so exactly-once is not vacuous): %d" % p2.ev_snapshots)
	_check(ring.highest_id("p2") == 1 and ring.pending_for("p2").is_empty() and ring.over_ack_count("p2") == 0 and ring.expired_count("p2") == 0 and ring.overflow_count("p2") == 0,
		"S1: the ack reached the host (nothing pending for p2, no over-ack / expiry / overflow)")
	var others_clean := true
	for id in ["p1", "p3"]:
		var o: _Own = sim.owners[id]
		others_clean = others_clean and o.applied_count == 0 and o.applied_ids.is_empty() and o.inbox.last_applied() == 0 and o.foreign_events == 0 and ring.pending_for(id).is_empty()
	_check(others_clean and ring.highest_id("p2") == 1 and p2.applied_count == 1, "S1: nobody else applied (or was sent) an impulse: p1 / p3 applied none, inbox last_applied 0")
	_check(sim.knock_first_dv.has("p2") and float(sim.knock_first_dv.get("p2", 0.0)) >= 120.0 and not sim.knock_first_dv.has("p1") and not sim.knock_first_dv.has("p3"),
		"S1: the first accepted report carrying ev >= 1 already shows the impulse in its velocity (|dv| %.1f >= 120 of ~200), only for p2" % float(sim.knock_first_dv.get("p2", 0.0)))
	_check(sim.align_violations == 0 and sim.align_samples > 1800,
		"S1: ALIGNMENT RULE: in every accepted input o[6] (impulses applied) == ev, i.e. 'o' reflects all events <= 'ev' and no later one (%d violations in %d inputs)" % [sim.align_violations, sim.align_samples])

	# The teleport.
	var s3: Dictionary = sim.standins.get("p3", {})
	_check(int(s3.get("snaps", -1)) == 1 and int((sim.standins.get("p1", {}) as Dictionary).get("snaps", -1)) == 0 and int((sim.standins.get("p2", {}) as Dictionary).get("snaps", -1)) == 0,
		"S1: the teleport snapped p3's stand-in exactly once; p1 and p2 (path + knock) never snapped (snaps p1 %s / p2 %s / p3 %s)" % [(sim.standins.get("p1", {}) as Dictionary).get("snaps"), (sim.standins.get("p2", {}) as Dictionary).get("snaps"), s3.get("snaps")])
	_check(int(s3.get("after_snap_n", 0)) > 40 and float(s3.get("after_snap_max", 99999.0)) <= 25.0,
		"S1: after the snap the stand-in never strays from p3's true path: max error over the next second %.2f <= 25 (no spring sweep, no overshoot; %d ticks)" % [float(s3.get("after_snap_max", 99999.0)), int(s3.get("after_snap_n", 0))])
	_check(p2_window_ok(sim),
		"S1: the knocked owner's stand-in stays bounded through the knock window (rubber band, no host compensation in step 1): max error %.2f <= 40" % float((sim.standins.get("p2", {}) as Dictionary).get("win_max", 99999.0)))

	# Views.
	for id in sim.owners:
		var o: _Own = sim.owners[id]
		_check(o.sent > 800 and o.frames > 800 and o.local_leak == 0 and o.local_buffered > 600 and o.others_present > 600,
			"S1/%s: its own entity is never interpolated (sample() omitted it in %d frames, set_local) while latest() still buffered it in %d; the others were present in %d frames" % [id, o.frames, o.local_buffered, o.others_present])
		# View bound: the client interpolates between snapshots 2 ticks apart (more when snapshots are
		# lost / dropped as reordered), the reference is the host history lerped between ticks; the
		# difference is curvature over a few ticks: <= 6 units (observed ~2.2) and 0.3 rad (observed
		# ~0.03). Frames within +/-8 ticks of a host-side jump (the snap) are skipped.
		var moved := o.view_span.size() == 2
		for sp in o.view_span.values():
			moved = moved and float(sp[1]) - float(sp[0]) >= 100.0
		_check(moved and o.view_samples > 1500 and o.view_err <= 6.0 and o.view_rot_err <= 0.3,
			"S1/%s: the other two stand-ins really moved in its view (>= 100 units of x) and its sampled view of them and of the host entity tracks the host's state within 6 units / 0.3 rad (worst %.2f / %.3f over %d samples)" % [id, o.view_err, o.view_rot_err, o.view_samples])
	var p1: _Own = sim.owners["p1"]
	var p3: _Own = sim.owners["p3"]
	_check(_close(p1.relay_seen.get(12), 1.0, 1e-6) and _close(p1.relay_seen.get(13), 0.0, 1e-6) and _close(p3.relay_seen.get(12), 1.0, 1e-6) and _close(p3.relay_seen.get(11), 0.0, 1e-6),
		"S1: a channel the follower does not use (the applied-impulse counter) rides the snapshot: others see p2's counter at 1 and p1 / p3's at 0")


func p2_window_ok(sim: _OSim) -> bool:
	return float((sim.standins.get("p2", {}) as Dictionary).get("win_max", 99999.0)) <= 40.0


# --- S2 ------------------------------------------------------------------------------------


## Advance the host's tick, pack and broadcast one snapshot, deliver it.
func _s2_snapshot(sim: _OSim) -> void:
	sim.T += 40
	sim.ticker.advance(sim.T)
	sim.host_snapshot(sim.T)
	sim.pump_now()


func _manual_ticks(sim: _OSim, o: _Own, from_tick: int, count: int) -> void:
	for k in count:
		sim.owner_tick(o, from_tick + k, sim.T)
		sim.pump_now()


func _case_s2() -> void:
	print("S2: a player leaves and rejoins; a new epoch resets everything")
	var sim := _OSim.new(77, 2, false)
	sim.mk_check = _check
	sim.boot()
	var p1: _Own = sim.owners["p1"]
	var p2: _Own = sim.owners["p2"]
	var t: CouchOwnerTargets = sim.targets
	_check(t.entity_of("p1") == 11 and t.entity_of("p2") == 12 and sim.host_world.has_entity(11) and sim.host_world.has_entity(12) and sim.joined_log.size() == 2,
		"S2: boot: p1 owns entity 11, p2 owns 12, both exist in the host world")
	_manual_ticks(sim, p1, 1, 5)
	_manual_ticks(sim, p2, 1, 5)
	_check(t.accepted_count("p1") == 5 and t.accepted_count("p2") == 5 and sim.align_violations == 0, "S2: each owner's 5 inputs were accepted through the real sessions")
	_check(t.push_impulse(sim.ring, "p1", Vector2(5, 5), 1.0, 10) == 1, "S2: the host knocks p1 (impulse id 1)")
	_s2_snapshot(sim)
	_manual_ticks(sim, p1, 6, 3)
	_check(p1.applied_ids == [1] and p1.inbox.last_applied() == 1 and sim.ring.pending_for("p1").is_empty(),
		"S2: p1 applied it once and the ack came back (nothing pending)")
	var acc_p2 := t.accepted_count("p2")

	# p1 leaves.
	sim.leave("p1", ["p2"])
	_check(sim.left_log == [["p1", 1]], "S2: 0b player_left fired for p1 (slot 1): %s" % [sim.left_log])
	_check(t.entity_of("p1") == -1 and t.accepted_count("p1") == 0 and t.target_for("p1", sim.T).is_empty() and not sim.host_world.has_entity(11),
		"S2: the game's forget / remove_entity: p1 is no longer an owner, its counters and report are gone, entity 11 left the world")
	_check(sim.ring.pending_for("p1").is_empty() and sim.ring.highest_id("p1") == 1, "S2: ring.forget dropped p1's pending events but kept its next id (highest 1)")
	_check(not t.note_input("p1", {"t": 99, "o": _pf(BASE_O), "ev": 0}, sim.T) and t.reject_count("p1", "unowned") == 1,
		"S2: a late input of the departed peer is 'unowned'")
	_check(t.push_impulse(sim.ring, "p1", Vector2(1, 1), 1.0, 20) == -1 and sim.ring.highest_id("p1") == 1, "S2: no impulse can be pushed to the departed peer")
	_check(t.entity_of("p2") == 12 and t.accepted_count("p2") == acc_p2 and sim.host_world.has_entity(12), "S2: p2 was not touched")

	# p1 rejoins as a brand-new client (fresh session / clock / inbox: ticks restart low).
	var p1b: _Own = sim.join("p1", ["p1", "p2"])
	_check(sim.joined_log.size() == 3 and sim.joined_log[2] == ["p1", 1] and p1b.session.active and p1b.session.local_slot == 1 and p1b.eid == 11,
		"S2: p1 rejoined into slot 1 (player_joined again), a fresh session, entity 11")
	_check(t.entity_of("p1") == 11 and t.accepted_count("p1") == 0 and t.target_for("p1", sim.T).is_empty() and sim.host_world.has_entity(11),
		"S2: new ownership: no report yet, no counters carried over")
	_manual_ticks(sim, p1b, 1, 3)
	_check(t.accepted_count("p1") == 3 and t.reject_count("p1", "stale-tick") == 0, "S2: the rejoiner's restarted low ticks 1..3 are accepted (the old last tick 8 was forgotten)")
	_check(t.push_impulse(sim.ring, "p1", Vector2(7, -7), 0.5, 30) == 2 and sim.ring.highest_id("p1") == 2,
		"S2: ring continuity: the next impulse after the rejoin has id 2 (ids stay monotone within the epoch)")
	_s2_snapshot(sim)
	_manual_ticks(sim, p1b, 4, 3)
	_check(p1b.applied_ids == [2] and p1b.applied_count == 1 and p1b.inbox.last_applied() == 2 and sim.ring.pending_for("p1").is_empty() and sim.ring.over_ack_count("p1") == 0,
		"S2: the rejoined owner applied the impulse once and the ack was accepted (no over-ack)")
	_check(p1.applied_ids == [1], "S2: the old client object applied nothing more")

	# New epoch.
	t.extrapolate_cap_ms = 60
	t.stale_mode = CouchOwnerTargets.REPORT_ONLY
	var kc_before: Array = sim.host_world.kind_channels(KIND7)
	var pre_ok: bool = t.entity_of("p1") == 11 and t.entity_of("p2") == 12 and t.accepted_count("p1") > 0 and t.accepted_count("p2") > 0 and sim.ring.highest_id("p1") == 2
	sim.new_epoch()
	_check(pre_ok and t.entity_of("p1") == -1 and t.entity_of("p2") == -1 and t.accepted_count("p1") == 0 and t.accepted_count("p2") == 0 and t.target_for("p1", sim.T).is_empty(),
		"S2: new epoch: targets.reset() dropped every owner, counter and report")
	_check(pre_ok and sim.ring.highest_id("p1") == 0 and sim.ring.highest_id("p2") == 0 and not sim.host_world.has_entity(11) and sim.host_world.kind_channels(KIND7) == kc_before and not kc_before.is_empty(),
		"S2: ring ids and host entities reset, the world's kind registry (kind_channels) is kept")
	_check(pre_ok and t.extrapolate_cap_ms == 60 and t.stale_mode == CouchOwnerTargets.REPORT_ONLY, "S2: the targets' policy vars survived the epoch")
	_check(pre_ok and p1b.applied_count == 1 and p1b.inbox.last_applied() == 0 and p1b.world.newest_tick() == -1, "S2: the owners' inbox / world were reset")
	_check(t.set_owner("p1", 11, KIND7, 1.0, 1.0, 5000) and t.note_input("p1", {"t": 1, "o": _pf([1, 2, 0, 0, 0, 0, 0]), "ev": 0}, 5010),
		"S2: after the reset set_owner works without set_channels and a low tick is accepted again")
	_check(t.push_impulse(sim.ring, "p1", Vector2(1, 2), 3.0, 1) == 1, "S2: after the reset the first impulse is id 1 again")
	var o: CouchOwnedEntity = p1b.owned
	var f: Dictionary = o.input_fields(1, PackedFloat32Array([1, 2, 0, 0, 0, 0, 0]), p1b.inbox)
	_check(_int_is(_dg(f, "ev"), 0) and _int_is(_dg(f, "t"), 1), "S2: the owner side starts the epoch with ev 0")


# --- driver ---------------------------------------------------------------------------------


func _section(label: String, fn: Callable) -> void:
	var before := _checks
	fn.call()
	print("  [%s: %d checks]" % [label, _checks - before])


func _run() -> void:
	_section("P1", _case_p1)
	_section("P2", _case_p2)
	_section("C1", _case_c1)
	_section("T1", _case_t1)
	_section("O1", _case_o1)
	_section("I1", _case_i1)
	_section("S1", _case_s1)
	_section("S2", _case_s2)

	print("")
	print("G16 owner authority: %d/%d checks passed" % [_checks - failures, _checks])
	if failures > 0:
		printerr("OWNER_AUTHORITY_FAILED: %d check(s)" % failures)
	quit(1 if failures > 0 else 0)
	return
