## Headless gate for prop authority -- gate G18.
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_prop_authority.gd
##
## What this proves. CouchPropAuthority is the host's ledger of pushable props: who simulates
## each prop (free, held by the host's player, or owned by a claiming guest), the per-prop
## CouchOwnerTargets a guest's reports go through, press routing (apply now, or sum and
## forward to the owner in the snapshot extra) and the recovered-press returns. The gate tests
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

	print("")
	print("G18 prop authority: %d/%d checks passed" % [_checks - failures, _checks])
	if failures > 0:
		printerr("PROP_AUTHORITY_FAILED: %d check(s)" % failures)
	quit(1 if failures > 0 else 0)
	return
