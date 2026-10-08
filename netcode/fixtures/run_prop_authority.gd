## Headless gate for prop authority -- gate G18.
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_prop_authority.gd
##
## What this proves. CouchPropAuthority is the host's ledger of pushable props: who simulates
## each prop (free, held by the host's player, or owned by a claiming guest), the per-prop
## CouchOwnerTargets a guest's reports go through, press routing (apply now, or sum and
## forward to the owner in the snapshot extra) and the recovered-press returns.
## CouchPropController is the owner's side: when to claim, grant and denial, the settled
## release, press spreading, the input fields and the pose to draw. The gate tests
## the frozen API CONTRACT (docs/plans/prop-authority-design.md, "API contract"), not the
## implementation; every check is guarded so a stub or a wrong-typed return gives FAIL lines,
## never a script error.
##
## Cases (slice A1, host side):
##   A1  registration: set_channels / add_prop refusals one by one, a new prop is free,
##       remove_prop, owner_of "" for unknown ids.
##   A2  grants: first claim on a free prop wins, a second claimant and claims on a host-held
##       prop are ignored, a claim with a rejected report grants nothing (and the next good one
##       does), malformed claim keys are ignored, counters.
##   A3  host hold: near takes a free prop, never a guest-held one; let-go at exactly
##       release_idle_ms with no settle wait (the toy body is still moving); the stale check runs
##       before the hold.
##   A4  releases: an input without "p", with "p" not a Dictionary, and with "p" lacking one of
##       two owned eids, each releasing exactly the right props.
##   A0  recovered presses: update and forget return {} (also on the calls that take back or
##       let go); on_input returns only routed presses on an input that releases a prop.
##   A5  take-back: stale at the stale_ms boundary frees on update; forget frees every prop of
##       the peer and only those; target_for empty afterwards.
##   A6  presses: apply_now routing, sums forwarded only to the owner they were collected for,
##       cleared per snapshot, releases and claims before presses in on_input, every malformed
##       "pr" entry counted, free props absent, the extra survives pack -> ingest and
##       var_to_bytes with int keys and packed types.
##   A7  several props: one peer holds two, two peers hold one each, per-prop staleness and
##       take-back, target_for per prop, and a toy host body following target_for with a real
##       CouchPDFollower converges onto the owner's moving report.
##
## Cases (slice A2, owner side: CouchPropController over a real client world fed by a real
## host world through var_to_bytes):
##   O1  claim: only with near AND free-or-mine AND latest AND past the backoff (one negative
##       each); the state advanced by (tick - latest.tick) * dt, the 250 ms cap and its
##       boundary, negative age clamped, rotation wrapped, a kind without rotation.
##   O2  grant and denial: "mine" before rtt is no grant, at rtt it is; lost, taken-back and
##       unanswered (boundary rtt + snapshot_ms + grace; snapshot_ms 0 before on_snapshot),
##       each setting the backoff to now + rtt.
##   O3  settled release: fires with all four conditions, each alone blocks it, near refreshes
##       the contact time, never before a render_pose.
##   O4  press spreading: P over n ticks, re-spread mid-way, dropped when not predicting, named
##       another owner, zero or malformed; RELEASE clears the queue.
##   O5  input fields: "p" only for predicted props (a copy), "pr" only for non-zero presses on
##       props not predicted, {} when neither; var_to_bytes round trip; the host accepts them.
##   O6  render: predicted -> the copy, puppet -> the sample, the release lerp at 0/50/100 ms,
##       is_blending until the frame that draws the end, the short arc.
##   E1  end to end: one host authority, two controllers, a 3-tick link each way, toy bodies:
##       claim, grant, follow, forwarded presses, settled release, re-claim by the other peer,
##       a claim on a host-held prop lost; snapshot and bookkeeping invariants.
##
## Deterministic: virtual time (now_ms passed in), no await, no Time, no physics server.
##
## LOAD-BEARING GOTCHA: SceneTree.quit(code) only SCHEDULES termination; it does not
## return. `return` follows the one quit(...) in this file.
extends SceneTree

const LERP := CouchReplicatedWorld.LERP
const ANGLE := CouchReplicatedWorld.ANGLE
const DT := 1.0 / 60.0
const KIND6 := 1    # [x, y, rot, vx, vy, w]
const KIND_NR := 3  # [x, y, vx, vy]  (no rotation)
const KIND_FREE := 9  # registered in the world, never given set_channels
const INT_MAX := 2147483647
const HOST := "host"
const MASS := 4.0
const INERTIA := 2.0
const ME := "g1"          # the owner side's own peer id
const RTT := 100.0        # ms, passed to CouchPropController.update
const SNAP_TICKS := 2     # snapshot interval: snapshot_ms = int(2 * DT * 1000) = 33
const EID := 5            # E1's prop
const LINK_TICKS := 3     # E1: one-way delay of inputs and snapshots
const DAMP := 2.0         # E1: toy linear damping, 1/s

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


func _num(v: Variant) -> float:
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return float(v)
	return NAN


func _close(v: Variant, e: float, tol: float = 1e-4) -> bool:
	var f := _num(v)
	return not is_nan(f) and absf(f - e) <= tol * maxf(1.0, absf(e))


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


func _is_empty_dict(v: Variant) -> bool:
	return typeof(v) == TYPE_DICTIONARY and (v as Dictionary).is_empty()


func _is_empty_pf(v: Variant) -> bool:
	return _is_pf(v) and (v as PackedFloat32Array).is_empty()


## True iff `v` is a Dictionary with exactly these keys (order ignored).
func _keys_are(v: Variant, keys: Array) -> bool:
	if typeof(v) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = v
	if d.size() != keys.size():
		return false
	for k in keys:
		if not d.has(k):
			return false
	return true


func _v3is(v: Variant, e: Vector3) -> bool:
	return typeof(v) == TYPE_VECTOR3 and (v as Vector3).is_equal_approx(e)


func _map6() -> CouchBodyChannels:
	return CouchBodyChannels.new({"x": 0, "y": 1, "rot": 2, "vx": 3, "vy": 4, "w": 5})


func _new_world() -> CouchReplicatedWorld:
	var w := CouchReplicatedWorld.new()
	w.register_kind(KIND6, [LERP, LERP, ANGLE, LERP, LERP, LERP])
	w.register_kind(KIND_NR, [LERP, LERP, LERP, LERP])
	w.register_kind(KIND_FREE, [LERP, LERP, ANGLE, LERP, LERP, LERP])
	return w


## An authority over a fresh world with KIND6 channels and the given props added.
func _auth(eids: Array) -> CouchPropAuthority:
	var a := CouchPropAuthority.new(_new_world(), HOST)
	a.set_channels(KIND6, _map6())
	for eid in eids:
		a.add_prop(eid, KIND6, MASS, INERTIA)
	return a


## A KIND6 report {"t", "o"} at (x, y) moving at (vx, vy).
func _rep(t: int, x: float, y: float, vx: float = 0.0, vy: float = 0.0) -> Dictionary:
	return {"t": t, "o": _pf([x, y, 0.0, vx, vy, 0.0])}


## An input body claiming `claims` ({eid: report}); "pr" only when `presses` is non-empty.
func _inp(claims: Dictionary, presses: Dictionary = {}) -> Dictionary:
	var body := {"t": 1, "o": _pf([0, 0, 0, 0, 0, 0]), CouchPropAuthority.INPUT_CLAIMS: claims}
	if not presses.is_empty():
		body[CouchPropAuthority.INPUT_PRESSES] = presses
	return body


func _press_pf(p: Vector3) -> PackedFloat32Array:
	return PackedFloat32Array([p.x, p.y, p.z])


# --- A1 registration ------------------------------------------------------------------------


func _case_a1() -> void:
	var a := CouchPropAuthority.new(_new_world(), HOST)
	_check(a.release_idle_ms == 300 and a.grants == 0 and a.releases == 0 and a.takebacks == 0
			and a.presses_forwarded == 0 and a.bad_presses == 0 and a.refused_claims == 0,
			"A1: defaults (release_idle_ms 300, every counter 0)")
	_check(CouchPropAuthority.INPUT_CLAIMS == "p" and CouchPropAuthority.INPUT_PRESSES == "pr"
			and CouchPropAuthority.EXTRA_KEY == "pp" and CouchPropAuthority.EXTRA_OWNER == "ow"
			and CouchPropAuthority.EXTRA_PRESS == "pr", "A1: wire key constants")
	_check(not a.add_prop(10, KIND6, MASS, INERTIA), "A1: add_prop refused before the kind has channels")
	_check(not a.set_channels(KIND6, null), "A1: set_channels refuses null")
	_check(not a.set_channels(KIND6, CouchBodyChannels.new({"x": 0})), "A1: set_channels refuses an invalid map")
	_check(not a.set_channels(77, _map6()), "A1: set_channels refuses an unregistered kind")
	_check(not a.set_channels(KIND_NR, _map6()), "A1: set_channels refuses a map that does not fit the kind")
	_check(a.set_channels(KIND6, _map6()), "A1: set_channels accepts a fitting map")
	_check(a.set_channels(KIND6, _map6()), "A1: set_channels replaces")
	_check(not a.add_prop(10, KIND_FREE, MASS, INERTIA), "A1: add_prop refused for a kind without channels")
	_check(not a.add_prop(-1, KIND6, MASS, INERTIA), "A1: add_prop refused for a negative id")
	_check(not a.add_prop(INT_MAX + 1, KIND6, MASS, INERTIA), "A1: add_prop refused above 2^31-1")
	_check(not a.add_prop(10, KIND6, 0.0, INERTIA), "A1: add_prop refused for mass 0")
	_check(not a.add_prop(10, KIND6, -1.0, INERTIA), "A1: add_prop refused for a negative mass")
	_check(not a.add_prop(10, KIND6, NAN, INERTIA), "A1: add_prop refused for a NaN mass")
	_check(not a.add_prop(10, KIND6, INF, INERTIA), "A1: add_prop refused for an infinite mass")
	_check(not a.add_prop(10, KIND6, MASS, -1.0), "A1: add_prop refused for a negative inertia")
	_check(not a.add_prop(10, KIND6, MASS, NAN), "A1: add_prop refused for a NaN inertia")
	# None of the refusals added the prop: a press on it is unknown (false), not "apply now".
	_check(not a.apply_now(10, Vector3(1, 0, 0)), "A1: the refused adds left no prop behind")
	_check(a.add_prop(INT_MAX, KIND6, MASS, 0.0), "A1: add_prop accepts id 2^31-1 and inertia 0")
	_check(a.add_prop(0, KIND6, MASS, INERTIA), "A1: add_prop accepts id 0")
	_check(a.add_prop(10, KIND6, MASS, INERTIA), "A1: add_prop accepts a valid prop")
	_check(not a.add_prop(10, KIND6, MASS, INERTIA), "A1: add_prop refused for an id already added")
	_check(a.owner_of(10) == "" and not a.is_guest_owned(10) and _is_empty_pf(a.target_for(10, 0)),
			"A1: a new prop is free (owner \"\", not guest-owned, target empty)")
	_check(a.apply_now(10, Vector3(1, 0, 0)), "A1: a new prop takes presses now (the host simulates it)")
	_check(a.owner_of(999) == "" and not a.is_guest_owned(999) and _is_empty_pf(a.target_for(999, 0)),
			"A1: owner_of \"\" and target empty for an unknown id")
	a.on_input("g1", _inp({10: _rep(1, 5, 5)}), 1000)
	_check(a.owner_of(10) == "g1", "A1: a guest can claim the prop")
	a.remove_prop(10)
	_check(a.owner_of(10) == "" and not a.is_guest_owned(10) and not a.apply_now(10, Vector3(1, 0, 0))
			and _is_empty_pf(a.target_for(10, 1000)), "A1: remove_prop drops the prop (owner \"\", unknown to apply_now)")
	a.remove_prop(12345)
	_check(a.owner_of(0) == "" and a.apply_now(0, Vector3(1, 0, 0)), "A1: remove_prop of an unknown id is a no-op")
	_check(a.add_prop(10, KIND6, MASS, INERTIA) and a.owner_of(10) == "", "A1: a removed id can be added again, free")
	_check(a.take_snapshot_extra().is_empty(), "A1: nothing held, nothing in the extra")


# --- A2 grants ------------------------------------------------------------------------------


func _case_a2() -> void:
	var a := _auth([10, 11, 12, 13])
	a.on_input("g1", _inp({10: _rep(1, 100, 50)}), 1000)
	_check(a.owner_of(10) == "g1" and a.is_guest_owned(10) and a.grants == 1,
			"A2: the first claim on a free prop is granted (grants 1)")
	_check(_pfclose(a.target_for(10, 1000), [100, 50, 0, 0, 0, 0]), "A2: target_for is the granted report")
	a.on_input("g2", _inp({10: _rep(1, 300, 300)}), 1010)
	_check(a.owner_of(10) == "g1" and a.grants == 1, "A2: a second claimant is ignored")
	_check(_pfclose(a.target_for(10, 1010), [100, 50, 0, 0, 0, 0]), "A2: the second claimant's report does not reach the target")
	a.on_input("g1", _inp({10: _rep(2, 110, 50)}), 1020)
	_check(a.owner_of(10) == "g1" and a.grants == 1 and _pfclose(a.target_for(10, 1020), [110, 50, 0, 0, 0, 0]),
			"A2: the owner's next claim updates its report, no new grant")
	a.update(11, true, 1000)
	_check(a.owner_of(11) == HOST and not a.is_guest_owned(11), "A2: the host's player holds prop 11")
	a.on_input("g1", _inp({10: _rep(3, 110, 50), 11: _rep(3, 0, 0)}), 1030)
	_check(a.owner_of(11) == HOST and a.grants == 1 and _is_empty_pf(a.target_for(11, 1030)),
			"A2: a claim on a host-held prop is ignored")
	# Rejected first reports: bad stride, missing "t", not a Dictionary, non-finite.
	a.on_input("g3", _inp({12: {"t": 1, "o": _pf([1, 2])}}), 1000)
	_check(a.owner_of(12) == "" and a.grants == 1 and _is_empty_pf(a.target_for(12, 1000)),
			"A2: a claim whose report has the wrong stride grants nothing")
	a.on_input("g3", _inp({12: {"o": _pf([1, 2, 0, 0, 0, 0])}}), 1001)
	_check(a.owner_of(12) == "", "A2: a claim whose report lacks \"t\" grants nothing")
	a.on_input("g3", _inp({12: "junk"}), 1002)
	_check(a.owner_of(12) == "", "A2: a claim whose report is not a Dictionary grants nothing")
	a.on_input("g3", _inp({12: {"t": 1, "o": _pf([NAN, 2, 0, 0, 0, 0])}}), 1003)
	_check(a.owner_of(12) == "" and a.grants == 1, "A2: a claim whose report is non-finite grants nothing")
	a.on_input("g3", _inp({12: _rep(1, 7, 8)}), 1004)
	_check(a.owner_of(12) == "g3" and a.grants == 2 and _pfclose(a.target_for(12, 1004), [7, 8, 0, 0, 0, 0]),
			"A2: the next good claim after rejections is granted at once (no backoff; tick 1 accepted again)")
	# Malformed claim keys.
	a.on_input("g4", _inp({"13": _rep(1, 0, 0), 13.0: _rep(1, 0, 0), 999: _rep(1, 0, 0), -1: _rep(1, 0, 0)}), 1000)
	_check(a.owner_of(13) == "" and a.grants == 2, "A2: claim keys that are not an added prop's int id are ignored")
	_check(a.releases == 0 and a.takebacks == 0, "A2: no releases or take-backs counted")


# --- A3 host hold ---------------------------------------------------------------------------


func _case_a3() -> void:
	var a := _auth([10, 20])
	# A toy body the host's player keeps pushing: still moving when the host lets go.
	var vx := 0.0
	a.update(10, true, 1000)
	_check(a.owner_of(10) == HOST and not a.is_guest_owned(10) and _is_empty_pf(a.target_for(10, 1000)),
			"A3: near takes a free prop (host-held, target empty)")
	_check(a.apply_now(10, Vector3(8, 0, 0)), "A3: a host-held prop takes presses now")
	vx += 8.0 / MASS
	a.update(10, true, 1100)
	for now in range(1101, 1400):
		a.update(10, false, now)
	_check(a.owner_of(10) == HOST, "A3: still held 299 ms after the last near tick")
	a.update(10, false, 1400)
	_check(a.owner_of(10) == "" and vx > 1.0, "A3: let go at exactly release_idle_ms (300 ms), the prop still moving (no settle wait)")
	# Guest-held props are never taken by the host's touch.
	a.on_input("g1", _inp({20: _rep(1, 0, 0)}), 2000)
	a.update(20, true, 2010)
	_check(a.owner_of(20) == "g1" and a.is_guest_owned(20), "A3: near never takes a guest-held prop")
	a.update(20, true, 2500)
	_check(a.owner_of(20) == "g1", "A3: the owner 500 ms after its last report is not stale yet")
	a.update(20, true, 2501)
	_check(a.owner_of(20) == HOST and a.takebacks == 1,
			"A3: stale check before the hold: a take-back and a touch in one tick end host-held")
	# Tunable let-go.
	var b := _auth([30])
	b.release_idle_ms = 50
	b.update(30, true, 0)
	b.update(30, false, 49)
	_check(b.owner_of(30) == HOST, "A3: release_idle_ms 50: held at 49 ms")
	b.update(30, false, 50)
	_check(b.owner_of(30) == "", "A3: release_idle_ms 50: free at 50 ms")
	# Re-touching restarts the let-go clock; a free prop not near stays free.
	b.update(30, true, 100)
	b.update(30, true, 140)
	b.update(30, false, 189)
	_check(b.owner_of(30) == HOST, "A3: the let-go clock runs from the LAST near tick")
	b.update(30, false, 190)
	b.update(30, false, 500)
	_check(b.owner_of(30) == "", "A3: a free prop that is not near stays free")


# --- A4 releases ----------------------------------------------------------------------------


func _case_a4() -> void:
	var a := _auth([30, 31, 32])
	a.on_input("g1", _inp({30: _rep(1, 0, 0), 31: _rep(1, 5, 5)}), 1000)
	a.on_input("g2", _inp({32: _rep(1, 9, 9)}), 1000)
	_check(a.owner_of(30) == "g1" and a.owner_of(31) == "g1" and a.owner_of(32) == "g2" and a.grants == 3,
			"A4: g1 holds 30 and 31, g2 holds 32")
	a.on_input("g1", {"t": 2, "o": _pf([0, 0, 0, 0, 0, 0])}, 1010)
	_check(a.owner_of(30) == "" and a.owner_of(31) == "" and a.owner_of(32) == "g2" and a.releases == 2,
			"A4: an input without \"p\" releases every prop of its sender, and only those")
	_check(_is_empty_pf(a.target_for(30, 1010)) and _is_empty_pf(a.target_for(31, 1010)), "A4: released props have no target")
	a.on_input("g1", _inp({30: _rep(3, 0, 0), 31: _rep(3, 5, 5)}), 1020)
	_check(a.owner_of(30) == "g1" and a.owner_of(31) == "g1" and a.grants == 5, "A4: released props can be claimed again")
	a.on_input("g1", {"t": 4, CouchPropAuthority.INPUT_CLAIMS: "junk"}, 1030)
	_check(a.owner_of(30) == "" and a.owner_of(31) == "" and a.owner_of(32) == "g2" and a.releases == 4,
			"A4: \"p\" not a Dictionary counts as no claims")
	a.on_input("g1", _inp({30: _rep(5, 0, 0), 31: _rep(5, 5, 5)}), 1040)
	a.on_input("g1", _inp({30: _rep(6, 1, 0)}), 1050)
	_check(a.owner_of(30) == "g1" and a.owner_of(31) == "" and a.releases == 5,
			"A4: \"p\" lacking one of two owned eids releases exactly that prop")
	_check(_pfclose(a.target_for(30, 1050), [1, 0, 0, 0, 0, 0]), "A4: the still-claimed prop keeps following its report")
	a.on_input("g3", {"t": 1}, 1060)
	_check(a.owner_of(30) == "g1" and a.owner_of(32) == "g2" and a.releases == 5,
			"A4: another peer's input without claims releases nothing of others")
	a.update(31, true, 1070)
	a.on_input("g1", _inp({30: _rep(7, 1, 0)}), 1080)
	_check(a.owner_of(31) == HOST and a.releases == 5, "A4: a host-held prop is never released by a guest's input")
	_check(a.takebacks == 0, "A4: releases are not take-backs")


# --- A0 recovered presses -------------------------------------------------------------------


func _case_a0() -> void:
	var a := _auth([40, 41, 42])
	_check(_is_empty_dict(a.update(40, false, 0)), "A0: update returns {} on a plain tick")
	_check(_is_empty_dict(a.update(40, true, 0)), "A0: update returns {} when the host takes the prop")
	_check(_is_empty_dict(a.update(40, false, 300)) and a.owner_of(40) == "", "A0: update returns {} on the host's let-go")
	a.on_input("g1", _inp({41: _rep(1, 0, 0)}), 1000)
	a.apply_now(41, Vector3(3, 0, 0))
	_check(_is_empty_dict(a.update(41, false, 1501)) and a.owner_of(41) == "" and a.takebacks == 1,
			"A0: update returns {} on the call that takes a stale owner's prop back")
	a.on_input("g1", _inp({41: _rep(2, 0, 0)}), 2000)
	a.apply_now(41, Vector3(3, 0, 0))
	_check(_is_empty_dict(a.forget("g1")) and a.owner_of(41) == "" and a.takebacks == 2,
			"A0: forget returns {} on the call that takes the prop back")
	_check(_is_empty_dict(a.forget("nobody")), "A0: forget of an unknown peer returns {}")
	a.on_input("g1", _inp({41: _rep(3, 0, 0), 42: _rep(3, 0, 0)}), 3000)
	a.apply_now(41, Vector3(5, 0, 0))
	a.apply_now(42, Vector3(6, 0, 0))
	var r := a.on_input("g1", {"t": 4}, 3010)
	_check(_is_empty_dict(r) and a.owner_of(41) == "" and a.owner_of(42) == "",
			"A0: on_input that releases props with forwarded sums and no press returns {}")
	a.on_input("g1", _inp({41: _rep(5, 0, 0), 42: _rep(5, 0, 0)}), 3020)
	a.apply_now(41, Vector3(5, 0, 0))
	r = a.on_input("g1", _inp({42: _rep(6, 0, 0)}, {41: _press_pf(Vector3(1, 2, 0.5))}), 3030)
	_check(_keys_are(r, [41]) and _v3is(_dg(r, 41), Vector3(1, 2, 0.5)),
			"A0: on_input that releases a prop holds only the routed press (no recovered sum)")


# --- A5 take-back ---------------------------------------------------------------------------


func _case_a5() -> void:
	var a := _auth([50, 51, 52, 53, 54])
	a.on_input("g1", _inp({50: _rep(1, 10, 10)}), 1000)
	a.update(50, false, 1500)
	_check(a.owner_of(50) == "g1" and a.takebacks == 0, "A5: not stale exactly stale_ms (500) after the last report")
	_check(not _is_empty_pf(a.target_for(50, 1500)), "A5: the owner's target is still served")
	a.update(50, false, 1501)
	_check(a.owner_of(50) == "" and a.takebacks == 1 and _is_empty_pf(a.target_for(50, 1501)),
			"A5: stale 501 ms after the last report: taken back on update, target empty")
	a.on_input("g1", _inp({50: _rep(2, 10, 10)}), 2000)
	a.on_input("g1", _inp({50: _rep(3, 10, 10)}), 2400)
	a.update(50, false, 2900)
	_check(a.owner_of(50) == "g1", "A5: staleness runs from the newest accepted report")
	a.update(50, false, 2901)
	_check(a.owner_of(50) == "" and a.takebacks == 2, "A5: and takes back once that is 501 ms old")
	a.on_input("g1", _inp({51: _rep(1, 0, 0), 52: _rep(1, 0, 0)}), 3000)
	a.on_input("g2", _inp({53: _rep(1, 0, 0)}), 3000)
	a.update(54, true, 3000)
	a.forget("g1")
	_check(a.owner_of(51) == "" and a.owner_of(52) == "" and a.takebacks == 4,
			"A5: forget frees every prop of the peer (takebacks +2)")
	_check(a.owner_of(53) == "g2" and a.owner_of(54) == HOST, "A5: forget leaves other peers' and host-held props")
	_check(_is_empty_pf(a.target_for(51, 3000)) and _is_empty_pf(a.target_for(52, 3000)) and not _is_empty_pf(a.target_for(53, 3000)),
			"A5: target_for empty for the freed props only")
	a.forget("g1")
	_check(a.takebacks == 4 and a.releases == 0, "A5: a second forget changes nothing; take-backs are not releases")
	# A freed prop's inner targets forgot the peer: a new claim starts a fresh tick clock.
	a.on_input("g1", _inp({51: _rep(1, 4, 4)}), 3100)
	_check(a.owner_of(51) == "g1" and _pfclose(a.target_for(51, 3100), [4, 4, 0, 0, 0, 0]),
			"A5: after forget, the peer's restarted tick 1 is accepted on a new claim")


# --- A6 presses -----------------------------------------------------------------------------


func _case_a6() -> void:
	var a := _auth([60, 61, 62, 63])
	var p1 := Vector3(1.5, -2.0, 0.25)
	var p2 := Vector3(0.5, 1.0, -0.75)
	_check(a.apply_now(60, p1), "A6: apply_now true for a free prop")
	a.update(61, true, 0)
	_check(a.apply_now(61, p1), "A6: apply_now true for a host-held prop")
	_check(not a.apply_now(999, p1), "A6: apply_now false for an unknown id")
	_check(_keys_are(a.take_snapshot_extra(), ["pp"]), "A6: (setup) the extra has only \"pp\"")
	var x := a.take_snapshot_extra()
	_check(_keys_are(_dg(x, "pp"), [61]) and _dg(_dg(_dg(x, "pp"), 61), "ow") == HOST
			and _keys_are(_dg(_dg(x, "pp"), 61), ["ow"]),
			"A6: a host-held prop is in the extra with its owner and no press; free props absent")
	a.on_input("g1", _inp({60: _rep(1, 0, 0)}), 1000)
	_check(not a.apply_now(60, p1) and not a.apply_now(60, p2), "A6: apply_now false for a guest-held prop")
	x = a.take_snapshot_extra()
	var e60: Variant = _dg(_dg(x, "pp"), 60)
	_check(_dg(e60, "ow") == "g1" and _pfclose(_dg(e60, "pr"), [2.0, -1.0, -0.5]) and a.presses_forwarded == 1,
			"A6: the sum reaches the extra for the owner it was collected for (presses_forwarded 1)")
	x = a.take_snapshot_extra()
	_check(_keys_are(_dg(_dg(x, "pp"), 60), ["ow"]) and a.presses_forwarded == 1, "A6: sums are cleared by each take_snapshot_extra")
	# Never to a new owner: g1 releases, g2 claims, no press in between.
	a.apply_now(60, p1)
	a.on_input("g1", {"t": 2}, 1010)
	a.on_input("g2", _inp({60: _rep(1, 0, 0)}), 1011)
	x = a.take_snapshot_extra()
	_check(_dg(_dg(_dg(x, "pp"), 60), "ow") == "g2" and _keys_are(_dg(_dg(x, "pp"), 60), ["ow"]) and a.presses_forwarded == 1,
			"A6: a sum collected for g1 never reaches g2 after a release and a re-grant")
	# Taken back, re-granted to g2, then pressed: only the new press.
	a.apply_now(60, p1)
	a.forget("g2")
	a.on_input("g3", _inp({60: _rep(1, 0, 0)}), 1020)
	a.apply_now(60, p2)
	x = a.take_snapshot_extra()
	_check(_dg(_dg(_dg(x, "pp"), 60), "ow") == "g3" and _pfclose(_dg(_dg(_dg(x, "pp"), 60), "pr"), [0.5, 1.0, -0.75]),
			"A6: a sum for a previous owner is discarded before the new owner's press is added")
	# on_input routing.
	var r := a.on_input("g4", _inp({}, {60: _press_pf(p1), 62: _press_pf(p2)}), 1030)
	_check(_keys_are(r, [62]) and _v3is(_dg(r, 62), p2), "A6: on_input returns presses on host-simulated props only")
	x = a.take_snapshot_extra()
	_check(_pfclose(_dg(_dg(_dg(x, "pp"), 60), "pr"), [1.5, -2.0, 0.25]), "A6: a guest's press on a guest-held prop is forwarded to its owner")
	a.on_input("g5", _inp({63: _rep(1, 0, 0)}), 1040)
	r = a.on_input("g5", _inp({}, {63: _press_pf(p1)}), 1050)
	_check(a.owner_of(63) == "" and _keys_are(r, [63]) and _v3is(_dg(r, 63), p1),
			"A6: an input releasing a prop and pressing it returns the press to apply (release before presses)")
	r = a.on_input("g6", _inp({62: _rep(1, 0, 0)}, {62: _press_pf(p1)}), 1060)
	_check(a.owner_of(62) == "g6" and _is_empty_dict(r), "A6: an input claiming a prop and pressing it routes the press after the grant")
	x = a.take_snapshot_extra()
	_check(_pfclose(_dg(_dg(_dg(x, "pp"), 62), "pr"), [1.5, -2.0, 0.25]), "A6: that press is summed for the new owner")
	# Malformed "pr" entries: each one alone.
	var bad := [
		["string key", {"62": _press_pf(p1)}],
		["float key", {62.0: _press_pf(p1)}],
		["unknown eid", {999: _press_pf(p1)}],
		["Array value", {60: [1.0, 2.0, 3.0]}],
		["size 2", {60: _pf([1, 2])}],
		["size 4", {60: _pf([1, 2, 3, 4])}],
		["PackedFloat64Array", {60: PackedFloat64Array([1, 2, 3])}],
		["NaN", {60: _pf([NAN, 2, 3])}],
		["INF", {60: _pf([1, INF, 3])}],
		["Vector3", {60: Vector3(1, 2, 3)}],
	]
	for b in bad:
		var before := a.bad_presses
		r = a.on_input("g7", {"t": 1, CouchPropAuthority.INPUT_PRESSES: b[1]}, 1070)
		_check(a.bad_presses == before + 1 and _is_empty_dict(r), "A6: bad \"pr\" entry (%s) counted in bad_presses, nothing routed" % b[0])
	x = a.take_snapshot_extra()
	_check(_keys_are(_dg(_dg(x, "pp"), 60), ["ow"]), "A6: no bad entry reached a sum")
	var before_bad := a.bad_presses
	r = a.on_input("g7", {"t": 1, CouchPropAuthority.INPUT_PRESSES: "junk"}, 1080)
	_check(a.bad_presses == before_bad and _is_empty_dict(r), "A6: \"pr\" not a Dictionary is ignored, not counted")
	r = a.on_input("g7", _inp({}, {61: _pf([0, 0, 0]), 60: _pf([0, 0, 0])}), 1090)
	x = a.take_snapshot_extra()
	_check(a.bad_presses == before_bad and _is_empty_dict(r) and _keys_are(_dg(_dg(x, "pp"), 60), ["ow"]),
			"A6: a valid zero press is skipped silently (not counted, not routed, not summed)")
	r = a.on_input("g7", _inp({}, {61: _press_pf(p1), 999: _press_pf(p1)}), 1100)
	_check(_keys_are(r, [61]) and a.bad_presses == before_bad + 1, "A6: one bad entry does not stop the good ones")
	# press_of.
	_check(CouchPropAuthority.press_of(_pf([1, 2, 3])) == Vector3(1, 2, 3), "A6: press_of reads a finite size-3 array")
	_check(CouchPropAuthority.press_of(_pf([1, 2])) == Vector3.ZERO and CouchPropAuthority.press_of(_pf([1, 2, 3, 4])) == Vector3.ZERO
			and CouchPropAuthority.press_of(_pf([NAN, 0, 0])) == Vector3.ZERO and CouchPropAuthority.press_of(null) == Vector3.ZERO
			and CouchPropAuthority.press_of([1.0, 2.0, 3.0]) == Vector3.ZERO, "A6: press_of gives ZERO for anything else")
	# Nothing held -> {}.
	var c := _auth([70])
	c.apply_now(70, p1)
	_check(_is_empty_dict(c.take_snapshot_extra()), "A6: {} when no prop is held")
	# The extra over the real wire: pack -> var_to_bytes -> ingest.
	var hw := _new_world()
	var cw := _new_world()
	var d := CouchPropAuthority.new(hw, HOST)
	d.set_channels(KIND6, _map6())
	d.add_prop(80, KIND6, MASS, INERTIA)
	d.on_input("g1", _inp({80: _rep(1, 0, 0)}), 0)
	d.apply_now(80, p1)
	hw.set_entity(80, KIND6, _pf([0, 0, 0, 0, 0, 0]))
	var body := hw.pack(1, 0, {}, null, null, d.take_snapshot_extra())
	var wire: Variant = bytes_to_var(var_to_bytes(body))
	_check(cw.ingest(wire), "A6: the snapshot with the extra is ingested")
	var got: Variant = _dg(cw.extra(), "pp")
	_check(_keys_are(got, [80]) and typeof((got as Dictionary).keys()[0]) == TYPE_INT, "A6: the \"pp\" eid key arrives as an int")
	_check(_dg(_dg(got, 80), "ow") == "g1" and _is_pf(_dg(_dg(got, 80), "pr"))
			and CouchPropAuthority.press_of(_dg(_dg(got, 80), "pr")) == p1,
			"A6: owner and press arrive intact (PackedFloat32Array, press_of reads it)")


# --- A7 several props -----------------------------------------------------------------------


func _case_a7() -> void:
	var a := _auth([70, 71, 72, 73])
	a.on_input("g1", _inp({70: _rep(1, 10, 0), 71: _rep(1, 20, 0)}), 1000)
	a.on_input("g2", _inp({72: _rep(1, 30, 0)}), 1000)
	_check(a.owner_of(70) == "g1" and a.owner_of(71) == "g1" and a.owner_of(72) == "g2" and a.grants == 3,
			"A7: one peer holds two props, another holds a third")
	_check(_pfclose(a.target_for(70, 1000), [10, 0, 0, 0, 0, 0]) and _pfclose(a.target_for(71, 1000), [20, 0, 0, 0, 0, 0])
			and _pfclose(a.target_for(72, 1000), [30, 0, 0, 0, 0, 0]), "A7: target_for is per prop")
	a.on_input("g1", _inp({70: _rep(2, 11, 0, 60, 0), 71: _rep(2, 21, 0)}), 1100)
	_check(_close(_at(a.target_for(70, 1150), 0), 14.0) and _close(_at(a.target_for(71, 1150), 0), 21.0),
			"A7: each prop extrapolates its own report (70 moving, 71 still)")
	# Per-prop staleness: 70's report is rejected (stale tick), 71's accepted.
	a.on_input("g1", _inp({70: _rep(2, 99, 0), 71: _rep(3, 22, 0)}), 1300)
	a.on_input("g2", _inp({72: _rep(2, 30, 0)}), 1300)
	_check(_close(_at(a.target_for(70, 1300), 0), 17.0), "A7: a rejected report on one prop leaves its target alone")
	for eid in [70, 71, 72, 73]:
		a.update(eid, false, 1601)
	_check(a.owner_of(70) == "" and a.owner_of(71) == "g1" and a.owner_of(72) == "g2" and a.takebacks == 1,
			"A7: the take-back of one stale prop touches nothing else")
	_check(_is_empty_pf(a.target_for(70, 1601)) and _close(_at(a.target_for(71, 1601), 0), 22.0)
			and _close(_at(a.target_for(72, 1601), 0), 30.0), "A7: the others keep their targets")
	a.on_input("g1", _inp({71: _rep(4, 22, 0)}, {72: _press_pf(Vector3(1, 0, 0))}), 1610)
	a.on_input("g2", _inp({72: _rep(3, 30, 0)}, {71: _press_pf(Vector3(0, 2, 0))}), 1610)
	var x := a.take_snapshot_extra()
	_check(_keys_are(_dg(x, "pp"), [71, 72]) and _pfclose(_dg(_dg(_dg(x, "pp"), 71), "pr"), [0, 2, 0])
			and _pfclose(_dg(_dg(_dg(x, "pp"), 72), "pr"), [1, 0, 0]),
			"A7: two owners pressing each other's props: each sum goes to the right owner")
	# A toy host body following the owner's moving report with a real CouchPDFollower.
	var b := _auth([90])
	var pol := CouchPDFollowerPolicy.new()
	var fol := CouchPDFollower.new(_map6(), pol, DT)
	var body := _pf([0, 0, 0, 0, 0, 0])
	var own_x := 40.0
	var t := 0
	var max_err := 0.0
	for tick in 120:
		var now := 5000 + int(tick * DT * 1000.0)
		own_x += 60.0 * DT
		b.on_input("g1", _inp({90: _rep(tick + 1, own_x, 10, 60, 0)}), now)
		if tick >= 90:
			max_err = maxf(max_err, Vector2(body[0] - own_x, body[1] - 10.0).length())
		var r := fol.step(body, b.target_for(90, now))
		if typeof(_dg(r, "snap")) == TYPE_BOOL and r["snap"]:
			body = (r["state"] as PackedFloat32Array).duplicate()
		elif typeof(_dg(r, "accel")) == TYPE_VECTOR2:
			var acc: Vector2 = r["accel"]
			body[3] += acc.x * DT
			body[4] += acc.y * DT
		body[0] += body[3] * DT
		body[1] += body[4] * DT
		t = tick
	_check(t == 119 and b.owner_of(90) == "g1" and max_err < 0.5,
			"A7: the host's toy body follows the owner's moving report (err %.3f px over the last 30 ticks)" % max_err)


# --- owner side (slice A2) helpers ------------------------------------------------------------


func _map_nr() -> CouchBodyChannels:
	return CouchBodyChannels.new({"x": 0, "y": 1, "vx": 2, "vy": 3})


## [client world, controller for ME] with KIND6 and KIND_NR channels and `eids` added as `kind`.
func _owner(eids: Array, kind: int = KIND6) -> Array:
	var w := _new_world()
	var c := CouchPropController.new(w, ME, DT)
	c.set_channels(KIND6, _map6())
	c.set_channels(KIND_NR, _map_nr())
	for eid in eids:
		c.add_prop(eid, kind)
	return [w, c]


## Host tick `tick` reaches the owner: `states` ({eid: Array}, size 6 = KIND6, 4 = KIND_NR) and
## `pp` as the "pp" section ({} = every prop free), packed by a real host world and sent through
## var_to_bytes. on_snapshot follows only when `notify`.
func _snap(o: Array, tick: int, states: Dictionary, pp: Dictionary, now: int, notify: bool = true,
		ticks: int = SNAP_TICKS) -> bool:
	var hw := _new_world()
	for eid in states:
		var arr: Array = states[eid]
		hw.set_entity(eid, KIND6 if arr.size() == 6 else KIND_NR, _pf(arr))
	var extra := {} if pp.is_empty() else {CouchPropAuthority.EXTRA_KEY: pp}
	var w: CouchReplicatedWorld = o[0]
	var ok := w.ingest(bytes_to_var(var_to_bytes(hw.pack(tick, now, {}, null, null, extra))))
	if ok and notify:
		(o[1] as CouchPropController).on_snapshot(w.extra(), ticks, now)
	return ok


func _act(d: Variant) -> int:
	var a: Variant = _dg(d, "action")
	return a if typeof(a) == TYPE_INT else -1


func _why(d: Variant) -> String:
	var r: Variant = _dg(d, "reason")
	return r if typeof(r) == TYPE_STRING else "?"


## A KIND6 copy state at (x, y) moving at (vx, vy) with rotation `rot`.
func _c6(x: float, y: float, vx: float = 0.0, vy: float = 0.0, rot: float = 0.0) -> PackedFloat32Array:
	return _pf([x, y, rot, vx, vy, 0.0])


## An owner with prop 10 (KIND6) and one free snapshot (host tick 100, at now 900) of `state`.
func _one(state: Array, notify: bool = true) -> Array:
	var o := _owner([10])
	_snap(o, 100, {10: state}, {}, 900, notify)
	return o


## An owner HOLDING prop 10 at (x, y), at rest: claimed at 1000, the grant seen at 1100 (the
## last contact), and (when `render`) one render_pose with the sample at (x, y).
func _held(x: float = 200.0, y: float = 100.0, render: bool = true) -> Array:
	var o := _one([x, y, 0, 0, 0, 0])
	var c: CouchPropController = o[1]
	c.update(10, true, _c6(x, y), 100, 1000, RTT)
	_snap(o, 101, {10: [x, y, 0, 0, 0, 0]}, {10: {"ow": ME}}, 1050)
	c.update(10, true, _c6(x, y), 106, 1100, RTT)
	if render:
		c.render_pose(10, Vector2(x, y), 0.0, Vector2(x, y), 0.0, 1100)
	return o


# --- O1 claim -------------------------------------------------------------------------------


func _case_o1() -> void:
	var NONE := CouchPropController.NONE
	var CLAIM := CouchPropController.CLAIM
	var o := _owner([10, 11, 12])
	var c: CouchPropController = o[1]
	_check(CouchPropController.NONE == 0 and CouchPropController.CLAIM == 1 and CouchPropController.RELEASE == 2,
			"O1: action constants NONE 0, CLAIM 1, RELEASE 2")
	_check(c.release_idle_ms == 300 and is_equal_approx(c.settle_speed, 10.0) and is_equal_approx(c.release_match, 1.0)
			and c.blend_ms == 100 and c.extrapolate_cap_ms == 250 and c.claim_grace_ms == 150 and c.claims == 0
			and c.releases == 0 and c.denials == 0 and c.presses_applied == 0, "O1: defaults (demo 4af9e66 values, counters 0)")
	_check(not c.set_channels(KIND6, null) and not c.set_channels(KIND_NR, _map6()) and not c.set_channels(77, _map6()),
			"O1: set_channels refuses null, a map that does not fit, an unregistered kind")
	_check(not c.add_prop(13, KIND_FREE) and not c.add_prop(10, KIND6) and not c.add_prop(-1, KIND6),
			"O1: add_prop refused for a kind without channels, an id already added, a negative id")
	var cp := _c6(0, 0)
	var d := c.update(10, true, cp, 100, 1000, RTT)
	_check(_act(d) == NONE and _is_empty_pf(_dg(d, "state")) and _why(d) == "" and c.claims == 0,
			"O1: no CLAIM while world.latest is empty (NONE: empty state, no reason)")
	var s := [100, 50, 0.5, 60, -30, 2]
	_snap(o, 100, {10: s, 11: s, 12: s}, {11: {"ow": "g2"}, 12: {"ow": ME}}, 1000)
	_check(c.owner_of(10) == "" and c.owner_of(11) == "g2" and c.owner_of(12) == ME and c.owner_of(999) == "",
			"O1: owner_of reads the newest snapshot (\"\" when absent or unknown)")
	_check(_act(c.update(10, false, cp, 100, 1000, RTT)) == NONE and not c.is_predicting(10), "O1: not near: no CLAIM")
	_check(_act(c.update(11, true, cp, 100, 1000, RTT)) == NONE and not c.is_predicting(11), "O1: a prop another peer holds is not claimed")
	_check(_act(c.update(12, true, cp, 100, 1000, RTT)) == CLAIM and c.is_predicting(12),
			"O1: a prop the snapshot still names mine is claimable")
	d = c.update(10, true, cp, 106, 1000, RTT)
	_check(_act(d) == CLAIM and _why(d) == "" and c.claims == 2 and c.is_predicting(10), "O1: near + free + latest: CLAIM (claims 2)")
	_check(_pfclose(_dg(d, "state"), [106, 47, 0.7, 60, -30, 2], 1e-3),
			"O1: CLAIM state = latest advanced by (tick - latest.tick) * dt (6 ticks = 0.1 s)")
	_check(_act(c.update(10, true, cp, 107, 1001, RTT)) == NONE, "O1: no second CLAIM while predicting")
	_check(_act(c.update(999, true, cp, 100, 1000, RTT)) == NONE and not c.is_predicting(999), "O1: an unknown id is NONE")
	# Cap, its boundary, a negative age, rotation wrap and a kind without rotation.
	var q := _owner([20, 21, 22, 23, 24])
	var k: CouchPropController = q[1]
	q[1].add_prop(25, KIND_NR)
	_snap(q, 100, {20: s, 21: s, 22: s, 23: s, 24: [0, 0, 3.0, 0, 0, 2], 25: [10, 20, 30, -60]}, {}, 1000)
	_check(_pfclose(_dg(k.update(20, true, cp, 114, 1000, RTT), "state"), [114, 43, 0.9666667, 60, -30, 2], 1e-3),
			"O1: 14 ticks (0.233 s) is under the cap: advanced in full")
	_check(_pfclose(_dg(k.update(21, true, cp, 115, 1000, RTT), "state"), [115, 42.5, 1.0, 60, -30, 2], 1e-3),
			"O1: 15 ticks = exactly the 250 ms cap")
	_check(_pfclose(_dg(k.update(22, true, cp, 130, 1000, RTT), "state"), [115, 42.5, 1.0, 60, -30, 2], 1e-3),
			"O1: 30 ticks is capped at 250 ms")
	_check(_pfclose(_dg(k.update(23, true, cp, 95, 1000, RTT), "state"), s, 1e-3), "O1: a negative age is clamped to 0")
	_check(_pfclose(_dg(k.update(24, true, cp, 106, 1000, RTT), "state"), [0, 0, 3.2 - TAU, 0, 0, 2], 1e-3),
			"O1: claim rotation wrapped to [-PI, PI]")
	_check(_pfclose(_dg(k.update(25, true, cp, 106, 1000, RTT), "state"), [13, 14, 30, -60], 1e-3),
			"O1: a kind without rotation advances x and y only")
	# Backoff after a denial: now + int(rtt), boundary.
	var b := _one(s)
	var bc: CouchPropController = b[1]
	bc.update(10, true, cp, 100, 2000, RTT)
	_snap(b, 101, {10: s}, {10: {"ow": "g2"}}, 2010)
	bc.update(10, true, cp, 101, 2010, RTT)
	_snap(b, 102, {10: s}, {}, 2020)
	_check(_act(bc.update(10, true, cp, 102, 2109, RTT)) == NONE, "O1: no CLAIM 99 ms after a denial at rtt 100 (backoff)")
	_check(_act(bc.update(10, true, cp, 102, 2110, RTT)) == CLAIM, "O1: CLAIM again at exactly now + int(rtt)")


# --- O2 grant and denial --------------------------------------------------------------------


func _case_o2() -> void:
	var NONE := CouchPropController.NONE
	var CLAIM := CouchPropController.CLAIM
	var RELEASE := CouchPropController.RELEASE
	var s := [200, 100, 0, 0, 0, 0]
	var cp := _c6(200, 100)
	# Grant only at rtt after the claim: an earlier "mine" is the previous grant on the wire.
	var o := _one(s)
	var c: CouchPropController = o[1]
	c.update(10, true, cp, 100, 1000, RTT)
	_snap(o, 101, {10: s}, {10: {"ow": ME}}, 1050)
	c.update(10, true, cp, 101, 1099, RTT)
	_snap(o, 102, {10: s}, {}, 1099)
	var d := c.update(10, true, cp, 102, 1100, RTT)
	_check(_act(d) == NONE and c.is_predicting(10) and c.denials == 0,
			"O2: \"mine\" 99 ms after the claim is no grant: a free snapshot next is not a take-back")
	_snap(o, 103, {10: s}, {10: {"ow": ME}}, 1100)
	c.update(10, true, cp, 103, 1100, RTT)
	_snap(o, 104, {10: s}, {}, 1101)
	d = c.update(10, true, cp, 104, 1101, RTT)
	_check(_act(d) == RELEASE and _why(d) == "taken-back" and _is_empty_pf(_dg(d, "state")) and c.denials == 1
			and c.releases == 1 and not c.is_predicting(10),
			"O2: \"mine\" at exactly rtt is the grant; free afterwards: RELEASE taken-back (denials 1, releases 1)")
	_check(_act(c.update(10, true, cp, 104, 1200, RTT)) == NONE and _act(c.update(10, true, cp, 104, 1201, RTT)) == CLAIM,
			"O2: taken-back sets the backoff to now + rtt")
	# Unanswered: boundary rtt + snapshot_ms + grace = 100 + 33 + 150.
	o = _one(s)
	c = o[1]
	c.update(10, true, cp, 100, 1000, RTT)
	_check(_act(c.update(10, true, cp, 117, 1283, RTT)) == NONE, "O2: no answer 283 ms after the claim (rtt + snapshot_ms + grace): holds")
	d = c.update(10, true, cp, 117, 1284, RTT)
	_check(_act(d) == RELEASE and _why(d) == "unanswered" and c.denials == 1, "O2: 284 ms: RELEASE unanswered")
	_check(_act(c.update(10, true, cp, 123, 1383, RTT)) == NONE and _act(c.update(10, true, cp, 123, 1384, RTT)) == CLAIM,
			"O2: unanswered sets the backoff to now + rtt")
	# Before the first on_snapshot snapshot_ms is 0.
	o = _one(s, false)
	c = o[1]
	c.update(10, true, cp, 100, 1000, RTT)
	_check(_act(c.update(10, true, cp, 115, 1250, RTT)) == NONE and _why(c.update(10, true, cp, 115, 1251, RTT)) == "unanswered",
			"O2: with no on_snapshot yet, unanswered after rtt + grace (snapshot_ms 0)")
	# Lost: claiming and while held; it wins over unanswered.
	o = _one(s)
	c = o[1]
	c.update(10, true, cp, 100, 1000, RTT)
	_snap(o, 101, {10: s}, {10: {"ow": "g2"}}, 1010)
	d = c.update(10, true, cp, 101, 1010, RTT)
	_check(_act(d) == RELEASE and _why(d) == "lost" and c.denials == 1 and c.releases == 1, "O2: another owner named while claiming: RELEASE lost")
	_snap(o, 102, {10: s}, {}, 1050)
	_check(_act(c.update(10, true, cp, 102, 1109, RTT)) == NONE and _act(c.update(10, true, cp, 102, 1110, RTT)) == CLAIM,
			"O2: lost sets the backoff to now + rtt")
	o = _held()
	c = o[1]
	_snap(o, 102, {10: s}, {10: {"ow": "g2"}}, 1200)
	d = c.update(10, true, cp, 112, 1200, RTT)
	_check(_act(d) == RELEASE and _why(d) == "lost" and c.denials == 1, "O2: another owner named while held: RELEASE lost")
	o = _one(s)
	c = o[1]
	c.update(10, true, cp, 100, 1000, RTT)
	_snap(o, 101, {10: s}, {10: {"ow": "g2"}}, 1300)
	_check(_why(c.update(10, true, cp, 118, 1300, RTT)) == "lost", "O2: lost wins over unanswered")
	o = _held()
	c = o[1]
	_check(_act(c.update(10, true, cp, 200, 5000, RTT)) == NONE and c.is_predicting(10) and c.denials == 0,
			"O2: once granted, no answer for a long time is not unanswered")


# --- O3 settled release ---------------------------------------------------------------------


func _case_o3() -> void:
	var NONE := CouchPropController.NONE
	var CLAIM := CouchPropController.CLAIM
	var RELEASE := CouchPropController.RELEASE
	var o := _held()
	var c: CouchPropController = o[1]
	_check(_act(c.update(10, false, _c6(200, 100), 120, 1399, RTT)) == NONE, "O3: idle 299 ms: holds")
	var d := c.update(10, false, _c6(200, 100), 120, 1400, RTT)
	_check(_act(d) == RELEASE and _why(d) == "settled" and c.releases == 1 and c.denials == 0 and not c.is_predicting(10),
			"O3: idle 300 ms, at rest, matching the sample, nothing queued: RELEASE settled (not a denial)")
	_check(_act(c.update(10, true, _c6(200, 100), 121, 1401, RTT)) == CLAIM, "O3: no backoff after a settled release")
	o = _held()
	c = o[1]
	_check(_act(c.update(10, false, _c6(200, 100, 10, 0), 120, 1400, RTT)) == NONE
			and _act(c.update(10, false, _c6(200, 100, 6, -8), 120, 1400, RTT)) == NONE,
			"O3: speed 10 (= settle_speed) blocks it")
	_check(_why(c.update(10, false, _c6(200, 100, 0, 9.9), 120, 1400, RTT)) == "settled", "O3: speed 9.9 releases")
	o = _held()
	c = o[1]
	_check(_act(c.update(10, false, _c6(201, 100), 120, 1400, RTT)) == NONE
			and _act(c.update(10, false, _c6(200, 99), 120, 1400, RTT)) == NONE,
			"O3: the copy 1.0 from the sample (= release_match) blocks it")
	_check(_why(c.update(10, false, _c6(200.9, 100), 120, 1400, RTT)) == "settled", "O3: 0.9 from the sample releases")
	o = _held()
	c = o[1]
	_snap(o, 102, {10: [200, 100, 0, 0, 0, 0]}, {10: {"ow": ME, "pr": _pf([2, 0, 0])}}, 1300)
	_check(_act(c.update(10, false, _c6(200, 100), 120, 1400, RTT)) == NONE, "O3: a queued press blocks it")
	c.drain_press(10)
	_check(_act(c.update(10, false, _c6(200, 100), 120, 1400, RTT)) == NONE, "O3: one tick of the press still queued blocks it")
	c.drain_press(10)
	_check(_why(c.update(10, false, _c6(200, 100), 121, 1401, RTT)) == "settled", "O3: releases once the queue is drained")
	o = _held()
	c = o[1]
	c.update(10, true, _c6(200, 100), 112, 1300, RTT)
	_check(_act(c.update(10, false, _c6(200, 100), 130, 1599, RTT)) == NONE, "O3: near refreshes the contact time")
	_check(_why(c.update(10, false, _c6(200, 100), 130, 1600, RTT)) == "settled", "O3: 300 ms after the last near tick: settled")
	o = _held(0.0, 0.0, false)
	c = o[1]
	_check(_act(c.update(10, false, _c6(0, 0), 130, 1600, RTT)) == NONE, "O3: no settled release before any render_pose (copy at the origin)")
	c.render_pose(10, Vector2.ZERO, 0.0, Vector2.ZERO, 0.0, 1600)
	_check(_why(c.update(10, false, _c6(0, 0), 131, 1601, RTT)) == "settled", "O3: and it releases after the first render_pose")


# --- O4 press spreading ---------------------------------------------------------------------


func _case_o4() -> void:
	var s := [200, 100, 0, 0, 0, 0]
	var o := _held()
	var c: CouchPropController = o[1]
	_snap(o, 102, {10: s}, {10: {"ow": ME, "pr": _pf([6, -3, 1.5])}}, 1200, true, 3)
	_check(c.presses_applied == 1, "O4: a forwarded press to the holder is queued (presses_applied 1)")
	var got := []
	for i in 4:
		got.append(c.drain_press(10))
	_check(_v3is(got[0], Vector3(2, -1, 0.5)) and _v3is(got[1], Vector3(2, -1, 0.5)) and _v3is(got[2], Vector3(2, -1, 0.5)),
			"O4: P with snapshot_ticks 3 drains as P/3 for 3 ticks")
	_check(_v3is(got[3], Vector3.ZERO), "O4: then ZERO")
	o = _held()
	c = o[1]
	_snap(o, 102, {10: s}, {10: {"ow": ME, "pr": _pf([6, 0, 0])}}, 1200, true, 3)
	var first := c.drain_press(10)
	_snap(o, 103, {10: s}, {10: {"ow": ME, "pr": _pf([3, 0, 0])}}, 1233, true, 3)
	var total := first
	var rest := []
	for i in 4:
		var p := c.drain_press(10)
		rest.append(p)
		total += p
	_check(_v3is(first, Vector3(2, 0, 0)) and _v3is(rest[0], Vector3(7.0 / 3.0, 0, 0)) and _v3is(rest[2], Vector3(7.0 / 3.0, 0, 0))
			and _v3is(rest[3], Vector3.ZERO), "O4: a second press mid-way re-spreads the remainder plus it over 3 ticks")
	_check(_v3is(total, Vector3(9, 0, 0)) and c.presses_applied == 2, "O4: everything queued drains in full")
	o = _held()
	c = o[1]
	_snap(o, 102, {10: s}, {10: {"ow": ME, "pr": _pf([0, 0, 0])}}, 1200)
	_snap(o, 103, {10: s}, {10: {"ow": ME, "pr": _pf([1, 2])}}, 1233)
	_snap(o, 104, {10: s}, {10: {"ow": ME, "pr": _pf([NAN, 0, 0])}}, 1266)
	_check(c.presses_applied == 0 and _v3is(c.drain_press(10), Vector3.ZERO), "O4: zero and malformed presses are dropped")
	o = _one(s)
	c = o[1]
	_snap(o, 101, {10: s}, {10: {"ow": ME, "pr": _pf([6, 0, 0])}}, 1000)
	_check(c.presses_applied == 0 and _v3is(c.drain_press(10), Vector3.ZERO), "O4: dropped when not predicting")
	c.update(10, true, _c6(200, 100), 101, 1000, RTT)
	_snap(o, 102, {10: s}, {10: {"ow": "g2", "pr": _pf([6, 0, 0])}}, 1010)
	_check(c.presses_applied == 0 and _v3is(c.drain_press(10), Vector3.ZERO), "O4: dropped when the snapshot names another owner")
	o = _held()
	c = o[1]
	_snap(o, 102, {10: s}, {10: {"ow": ME, "pr": _pf([6, 0, 0])}}, 1200, true, 3)
	_snap(o, 103, {10: s}, {10: {"ow": "g2"}}, 1210)
	c.update(10, true, _c6(200, 100), 110, 1210, RTT)
	_check(not c.is_predicting(10) and _v3is(c.drain_press(10), Vector3.ZERO), "O4: RELEASE clears the queue")
	_snap(o, 104, {10: s}, {}, 1300)
	c.update(10, true, _c6(200, 100), 120, 1400, RTT)
	_check(c.is_predicting(10) and _v3is(c.drain_press(10), Vector3.ZERO), "O4: nothing left over at the next claim")
	_check(_v3is(c.drain_press(999), Vector3.ZERO), "O4: drain_press of an unknown id is ZERO")


# --- O5 input fields ------------------------------------------------------------------------


func _case_o5() -> void:
	var s := [0, 0, 0, 0, 0, 0]
	var o := _owner([10, 11, 12])
	var c: CouchPropController = o[1]
	_snap(o, 100, {10: s, 11: s, 12: s}, {}, 1000)
	_check(_is_empty_dict(c.input_fields(7, {10: _c6(1, 2), 11: _c6(5, 5)}, {10: Vector3.ZERO, 11: Vector3.ZERO})),
			"O5: {} with nothing predicted and only zero presses")
	var f := c.input_fields(7, {}, {11: Vector3(0, 2, 0)})
	_check(_keys_are(f, ["pr"]) and _keys_are(_dg(f, "pr"), [11]) and _pfclose(_dg(_dg(f, "pr"), 11), [0, 2, 0]),
			"O5: only \"pr\" when nothing is predicted")
	c.update(10, true, _c6(0, 0), 100, 1000, RTT)
	var copy10 := _c6(1, 2, 3, 4, 0.5)
	f = c.input_fields(7, {10: copy10, 11: _c6(5, 5)}, {})
	_check(_keys_are(f, ["p"]), "O5: only \"p\" with no presses")
	f = c.input_fields(8, {10: copy10, 11: _c6(5, 5)},
			{10: Vector3(1, 0, 0), 11: Vector3(0, 2, 0), 12: Vector3.ZERO, 999: Vector3(1, 1, 1)})
	var p10: Variant = _dg(_dg(f, "p"), 10)
	_check(_keys_are(f, ["p", "pr"]) and _keys_are(_dg(f, "p"), [10]) and _keys_are(p10, ["t", "o"])
			and _dg(p10, "t") == 8 and _pfclose(_dg(p10, "o"), [1, 2, 0.5, 3, 4, 0]),
			"O5: \"p\" only for the predicted prop: {\"t\": tick, \"o\": its state}")
	_check(_keys_are(_dg(f, "pr"), [11]) and _pfclose(_dg(_dg(f, "pr"), 11), [0, 2, 0]),
			"O5: \"pr\" only for non-zero presses on added props not predicted")
	copy10[0] = 99.0
	_check(_pfclose(_dg(p10, "o"), [1, 2, 0.5, 3, 4, 0]), "O5: \"o\" is a copy of the state")
	var wire: Variant = bytes_to_var(var_to_bytes(f))
	var wp: Variant = _dg(wire, "p")
	var wr: Variant = _dg(wire, "pr")
	_check(_keys_are(wp, [10]) and typeof((wp as Dictionary).keys()[0]) == TYPE_INT and _is_pf(_dg(_dg(wp, 10), "o"))
			and typeof(_dg(_dg(wp, 10), "t")) == TYPE_INT and _keys_are(wr, [11]) and typeof((wr as Dictionary).keys()[0]) == TYPE_INT
			and _is_pf(_dg(wr, 11)), "O5: the fields survive var_to_bytes with int keys and packed types")
	var a := _auth([10, 11])
	var body: Dictionary = {"t": 8, "o": _pf([0, 0, 0, 0, 0, 0])}
	body.merge(wire)
	var r := a.on_input(ME, body, 1000)
	_check(a.owner_of(10) == ME and _pfclose(a.target_for(10, 1000), [1, 2, 0.5, 3, 4, 0]) and _keys_are(r, [11])
			and _v3is(_dg(r, 11), Vector3(0, 2, 0)), "O5: CouchPropAuthority grants the \"p\" claim and routes the \"pr\" press")


# --- O6 render ------------------------------------------------------------------------------


func _case_o6() -> void:
	var o := _one([0, 0, 0, 0, 0, 0])
	var c: CouchPropController = o[1]
	var p := c.render_pose(10, Vector2(5, 6), 0.3, Vector2(1, 1), 0.1, 1000)
	_check(_dg(p, "pos") == Vector2(5, 6) and _close(_dg(p, "rot"), 0.3) and not c.is_blending(10), "O6: a puppet is drawn at the sample")
	p = c.render_pose(999, Vector2(5, 6), 0.3, Vector2(1, 1), 0.1, 1000)
	_check(_dg(p, "pos") == Vector2(5, 6) and _close(_dg(p, "rot"), 0.3), "O6: an unknown id is drawn at the sample")
	o = _held()
	c = o[1]
	p = c.render_pose(10, Vector2(200, 100), 0.0, Vector2(210.25, 101.5), 0.4, 1200)
	_check(_dg(p, "pos") == Vector2(210.25, 101.5) and _dg(p, "rot") == 0.4 and not c.is_blending(10),
			"O6: a predicted prop is drawn exactly at its copy")
	_snap(o, 102, {10: [200, 100, 0, 0, 0, 0]}, {10: {"ow": "g2"}}, 1200)
	c.update(10, true, _c6(210, 100, 0, 0, 0.4), 112, 1200, RTT)
	_check(c.is_blending(10), "O6: blending right after a RELEASE")
	p = c.render_pose(10, Vector2(200, 100), 0.0, Vector2(210, 100), 0.4, 1200)
	_check(_dg(p, "pos") == Vector2(210, 100) and _close(_dg(p, "rot"), 0.4, 1e-4), "O6: at 0 ms the copy pose at release")
	p = c.render_pose(10, Vector2(200, 100), 0.0, Vector2(0, 0), 0.0, 1250)
	_check(typeof(_dg(p, "pos")) == TYPE_VECTOR2 and (p["pos"] as Vector2).is_equal_approx(Vector2(205, 100))
			and _close(_dg(p, "rot"), 0.2, 1e-4) and c.is_blending(10), "O6: at 50 ms halfway (lerp), still blending")
	c.render_pose(10, Vector2(200, 100), 0.0, Vector2(0, 0), 0.0, 1299)
	_check(c.is_blending(10), "O6: still blending at 99 ms")
	p = c.render_pose(10, Vector2(200, 100), 0.0, Vector2(0, 0), 0.0, 1300)
	_check(_dg(p, "pos") == Vector2(200, 100) and _close(_dg(p, "rot"), 0.0) and not c.is_blending(10),
			"O6: at 100 ms the sample; not blending after the frame that draws the end")
	o = _held()
	c = o[1]
	_snap(o, 102, {10: [200, 100, 0, 0, 0, 0]}, {10: {"ow": "g2"}}, 1200)
	c.update(10, true, _c6(200, 100, 0, 0, 3.0), 112, 1200, RTT)
	p = c.render_pose(10, Vector2(200, 100), -3.0, Vector2(0, 0), 0.0, 1250)
	_check(absf(_num(_dg(p, "rot"))) > 3.14, "O6: the rotation blend takes the short arc across PI")


# --- E1 end to end --------------------------------------------------------------------------


## One host authority, two controllers, a fixed 3-tick link each way, toy bodies (damped point
## masses, no rotation). Script: g1 claims and pushes (+x); g2 presses the held prop (+y); g1
## idles until it settles and releases; g2 claims and pushes (-x) and settles; the host's player
## then holds the free prop while g2 tries to claim it.
func _case_e1() -> void:
	var host_w := _new_world()
	var host := CouchPropAuthority.new(host_w, HOST)
	host.set_channels(KIND6, _map6())
	host.add_prop(EID, KIND6, MASS, INERTIA)
	var fol := CouchPDFollower.new(_map6(), CouchPDFollowerPolicy.new(), DT)
	var hb := _pf([100, 100, 0, 0, 0, 0])
	var ids := ["g1", "g2"]
	var worlds := [_new_world(), _new_world()]
	var ctls: Array = []
	var copies: Array = [hb.duplicate(), hb.duplicate()]
	for i in 2:
		var c := CouchPropController.new(worlds[i], ids[i], DT)
		c.set_channels(KIND6, _map6())
		c.add_prop(EID, KIND6)
		ctls.append(c)
	var c1: CouchPropController = ctls[0]
	var c2: CouchPropController = ctls[1]
	var to_host: Array = []           # [due tick, peer, bytes]
	var to_owner: Array = [[], []]    # [due tick, bytes]
	var reasons: Array = [[], []]
	var owners: Array = [""]          # host owner_of, every change
	var bad_sections := 0
	var both_held := 0
	var sent_press := Vector3.ZERO    # g2's forwarded presses as sent
	var drained := Vector3.ZERO       # what g1's controller drained into its copy
	var host_err_at_release := INF
	var t1_release := -1
	var t2_claim := -1
	var t2_release := -1
	var t3 := -1
	var granted_g2 := false
	var held_by_host := true
	var end := 1500
	var t := 0
	while t < end:
		var now := int(t * 1000.0 / 60.0)
		# Scripted intent: near and own push (per owner), the host's player near.
		var near := [t >= 10 and t < 40, t >= 50 and t < 70]
		var push := [Vector3.ZERO, Vector3.ZERO]
		var poke := Vector3(0, MASS * 2.0, 0) if t >= 50 and t < 70 else Vector3.ZERO
		if t >= 10 and t < 40 and copies[0][3] < 60.0:
			push[0] = Vector3((60.0 - copies[0][3]) * MASS, 0, 0)
		if t2_claim >= 0 and t < t2_claim + 20:
			near[1] = true
			if copies[1][3] > -30.0:
				push[1] = Vector3((-30.0 - copies[1][3]) * MASS, 0, 0)
		var host_near := t3 >= 0 and t < t3 + 40
		if t3 >= 0 and t < t3 + 40:
			near[1] = true
		# Host tick.
		var keep: Array = []
		for m in to_host:
			if m[0] <= t:
				hb = _apply_all(hb, host.on_input(m[1], bytes_to_var(m[2]), now))
			else:
				keep.append(m)
		to_host = keep
		hb = _apply_all(hb, host.update(EID, host_near, now))
		if host.is_guest_owned(EID):
			var r := fol.step(hb, host.target_for(EID, now))
			if typeof(_dg(r, "snap")) == TYPE_BOOL and r["snap"]:
				hb = (r["state"] as PackedFloat32Array).duplicate()
			elif typeof(_dg(r, "accel")) == TYPE_VECTOR2:
				hb[3] += (r["accel"] as Vector2).x * DT
				hb[4] += (r["accel"] as Vector2).y * DT
			hb[0] += hb[3] * DT
			hb[1] += hb[4] * DT
		else:
			hb = _toy_step(hb)
		if host.owner_of(EID) != owners[owners.size() - 1]:
			owners.append(host.owner_of(EID))
		if host.owner_of(EID) == "g2":
			granted_g2 = true
		if t3 >= 0 and t >= t3 and t < t3 + 40 and host.owner_of(EID) != HOST:
			held_by_host = false
		host_w.set_entity(EID, KIND6, hb)
		if t % SNAP_TICKS == 0:
			var extra := host.take_snapshot_extra()
			var pp: Variant = _dg(extra, "pp")
			var ok: bool = (host.owner_of(EID) == "" and extra.is_empty()) or (_keys_are(pp, [EID])
					and typeof(_dg(_dg(pp, EID), "ow")) == TYPE_STRING and _dg(_dg(pp, EID), "ow") == host.owner_of(EID))
			if not ok:
				bad_sections += 1
			var wire := var_to_bytes(host_w.pack(t, now, {}, null, null, extra))
			for i in 2:
				to_owner[i].append([t + LINK_TICKS, wire])
		# Owner ticks.
		for i in 2:
			var c: CouchPropController = ctls[i]
			var w: CouchReplicatedWorld = worlds[i]
			var cp: PackedFloat32Array = copies[i]
			keep = []
			for m in to_owner[i]:
				if m[0] <= t:
					if w.ingest(bytes_to_var(m[1])):
						c.on_snapshot(w.extra(), SNAP_TICKS, now)
				else:
					keep.append(m)
			to_owner[i] = keep
			var d := c.update(EID, near[i], cp, t, now, RTT)
			if _act(d) == CouchPropController.CLAIM and _is_pf(_dg(d, "state")):
				cp = (d["state"] as PackedFloat32Array).duplicate()
			elif _act(d) == CouchPropController.RELEASE:
				reasons[i].append(_why(d))
				if i == 0 and t1_release < 0:
					t1_release = t
					host_err_at_release = Vector2(hb[0] - cp[0], hb[1] - cp[1]).length()
				elif i == 1 and t2_claim >= 0 and t2_release < 0 and t3 < 0:
					t2_release = t
			var dp := c.drain_press(EID)
			if i == 0:
				drained += dp
			cp = _press(cp, dp)
			var presses: Dictionary = {}
			var mine: Vector3 = push[i] if push[i] != Vector3.ZERO else (poke if i == 1 else Vector3.ZERO)
			if mine != Vector3.ZERO:
				presses[EID] = mine
				if c.is_predicting(EID):
					cp = _press(cp, mine)
			if c.is_predicting(EID):
				cp = _toy_step(cp)
			var fields := c.input_fields(t, {EID: cp}, presses)
			if i == 1:
				sent_press += CouchPropAuthority.press_of(_dg(_dg(fields, "pr"), EID))
			var body: Dictionary = {"t": t, "o": _pf([0, 0, 0, 0, 0, 0])}
			body.merge(fields)
			to_host.append([t + LINK_TICKS, ids[i], var_to_bytes(body)])
			var smp := w.sample((t - 5) * 1000)
			if smp.has(EID):
				var st: PackedFloat32Array = smp[EID]
				var pose := c.render_pose(EID, Vector2(st[0], st[1]), st[2], Vector2(cp[0], cp[1]), cp[2], now)
				if not c.is_predicting(EID) and typeof(_dg(pose, "pos")) == TYPE_VECTOR2:
					cp[0] = (pose["pos"] as Vector2).x
					cp[1] = (pose["pos"] as Vector2).y
					cp[2] = _num(_dg(pose, "rot"))
					cp[3] = st[3]
					cp[4] = st[4]
					cp[5] = st[5]
			copies[i] = cp
		if c1.is_predicting(EID) and c1.owner_of(EID) == "g1" and c2.is_predicting(EID) and c2.owner_of(EID) == "g2":
			both_held += 1
		# Phase changes once the previous one is over and both sides see the prop free.
		if t1_release >= 0 and t2_claim < 0 and host.owner_of(EID) == "" and c2.owner_of(EID) == "":
			t2_claim = t + 1
		if t2_release >= 0 and t3 < 0 and host.owner_of(EID) == "" and c2.owner_of(EID) == "":
			t3 = t + 1
			end = t3 + 100
		t += 1
	_check(t1_release >= 0 and t2_claim >= 0 and t2_release >= 0 and t3 >= 0 and t < 1500,
			"E1: every phase ran (g1 release t%d, g2 claim t%d, g2 release t%d, host hold t%d)" % [t1_release, t2_claim, t2_release, t3])
	_check(owners == ["", "g1", "", "g2", "", HOST, ""], "E1: host owner sequence free, g1, free, g2, free, host, free (got %s)" % [owners])
	_check(host.grants == 2 and c1.claims == 1 and c2.claims == 2, "E1: two grants (g1, then g2); g1 claimed once, g2 twice")
	_check(host_err_at_release < 1.0, "E1: the host's body converged to g1's copy (%.3f px at g1's release)" % host_err_at_release)
	_check(c1.presses_applied > 0 and absf(sent_press.y) > 100.0 and drained.is_equal_approx(sent_press),
			"E1: g2's presses reached g1's copy in full (sent %s, drained %s)" % [sent_press, drained])
	_check(reasons[0] == ["settled"] and c1.denials == 0, "E1: g1 idled, settled and released (%s)" % [reasons[0]])
	_check(granted_g2 and reasons[1] == ["settled", "lost"] and c2.denials == 1,
			"E1: g2 then claimed, was granted and settled; its claim on the host-held prop was lost (%s)" % [reasons[1]])
	_check(held_by_host, "E1: the host kept the prop it held while g2 claimed it")
	_check(bad_sections == 0, "E1: every snapshot names exactly the host's one owner (free props absent)")
	_check(both_held == 0, "E1: no tick where both controllers hold the prop")
	_check(c1.claims == c1.releases and c2.claims == c2.releases and not c1.is_predicting(EID) and not c2.is_predicting(EID),
			"E1: every claim ended in a release (grant + settle, or a denial)")


## Toy body tick: move, then linear damping. Returns the new state.
func _toy_step(state: PackedFloat32Array) -> PackedFloat32Array:
	var b := state.duplicate()
	b[0] += b[3] * DT
	b[1] += b[4] * DT
	b[3] *= 1.0 - DAMP * DT
	b[4] *= 1.0 - DAMP * DT
	return b


## A press changes the toy body's velocity by j / mass (no rotation in E1).
func _press(state: PackedFloat32Array, p: Vector3) -> PackedFloat32Array:
	var b := state.duplicate()
	b[3] += p.x / MASS
	b[4] += p.y / MASS
	return b


func _apply_all(state: PackedFloat32Array, presses: Variant) -> PackedFloat32Array:
	var b := state
	if typeof(presses) == TYPE_DICTIONARY:
		for eid in presses:
			if typeof(presses[eid]) == TYPE_VECTOR3:
				b = _press(b, presses[eid])
	return b


# --- driver ---------------------------------------------------------------------------------


func _section(label: String, fn: Callable) -> void:
	var before := _checks
	fn.call()
	print("  [%s: %d checks]" % [label, _checks - before])


func _run() -> void:
	_section("A1", _case_a1)
	_section("A2", _case_a2)
	_section("A3", _case_a3)
	_section("A4", _case_a4)
	_section("A0", _case_a0)
	_section("A5", _case_a5)
	_section("A6", _case_a6)
	_section("A7", _case_a7)
	_section("O1", _case_o1)
	_section("O2", _case_o2)
	_section("O3", _case_o3)
	_section("O4", _case_o4)
	_section("O5", _case_o5)
	_section("O6", _case_o6)
	_section("E1", _case_e1)

	print("")
	print("G18 prop authority: %d/%d checks passed" % [_checks - failures, _checks])
	if failures > 0:
		printerr("PROP_AUTHORITY_FAILED: %d check(s)" % failures)
	quit(1 if failures > 0 else 0)
	return
