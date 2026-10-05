## HOST-side bookkeeping for owner-authority: which peer owns which entity, the latest
## accepted report of each owner, staleness, and the extrapolated target a
## CouchPDFollower chases. Pure data; wall time is passed in as now_ms.
##
## CONTRACT. note_input validates in this order, first failure wins, and a rejection
## changes nothing but reject_count / last_reject_reason: "unowned" (peer owns no entity),
## "bad-shape" (body not a Dictionary, "t" missing or not an int, "o" missing or not a
## PackedFloat32Array, "ev" present but not an int >= 0), "bad-stride" (o.size() != the kind's stride), "non-finite",
## "stale-tick" (a tick was already accepted since set_owner and t <= it). An accepted
## report stores a COPY of "o". target_for returns a NEW array: the last report
## extrapolated by its velocity for at most extrapolate_cap_ms, then held with velocity
## channels zeroed; empty for non-owners and before the first report. A peer is stale after
## stale_ms without a report (the clock starts at set_owner); in REPORT_ONLY a stale peer's
## target is empty so the game owns the stand-in, in HOLD it stays held. forget drops a
## peer entirely (a rejoining client's tick clock restarts); reset starts a new epoch and
## keeps only set_channels registrations and the tuning vars. Counters persist until then.
## The world is only read (kind registry), never changed. No plausibility limits: a
## well-formed report is trusted.
##
## IMPULSE COMPENSATION. push_impulse(..., now_ms) also records the knock, and target_for
## adds a lead so the stand-in moves from the push instead of one round trip later. Before
## the owner's covering report (the first accepted report with "ev" >= the impulse id) the
## lead grows as P(s) = dv * tau * (1 - exp(-s / tau)), dv = J / mass, with s and tau in
## SECONDS (tau = max(impulse_tau_ms, 1) / 1000.0, s = elapsed ms / 1000.0).
## At the cover it is frozen and then decays as lead * exp(-s / tau), because from then on
## the reports themselves carry the knock. Cover is keyed on the "ev" of ACCEPTED reports
## ("ev" missing counts as 0), never on ring.ack: the wiring acks before note_input, so a
## rejected input can advance the ring while the stored report still predates the knock.
## A lower "ev" never un-covers. An impulse not covered within impulse_timeout_ms is handed
## off as if covered then (impulse_timeout_count). Handed-off entries are dropped 8 tau
## later. impulse_compensation = false makes target_for exactly the step-1 target;
## compensation_of reports the offset either way. set_owner (replace), forget and reset
## clear a peer's entries and covered_ev; impulse_timeout_count lives with the counters.
##
## GAME WIRING (host). Setup: targets.set_channels(PLAYER_KIND, CouchBodyChannels.new({...})).
## player_joined: targets.set_owner(peer, eid, PLAYER_KIND, mass, inertia, now_ms) and
## world.set_entity(eid, ...). player_left: targets.forget(peer), ring.forget(peer),
## world.remove_entity(eid). On input: ring.ack(peer, int(body.get("ev", 0))) then
## targets.note_input(peer, body, now_ms). Each physics step feed
## targets.target_for(peer, now_ms) to that stand-in's CouchPDFollower. To knock a player:
## targets.push_impulse(ring, peer, J, angular_J, host_tick, now_ms); the owner applies it
## (see CouchOwnedEntity, including its ALIGNMENT RULE). For scripted knocks change only the
## target (do not also apply J to the stand-in): at the default clamped spring the follower
## sets the stand-in's velocity to the target's every step, so a direct velocity kick made
## before the follower step is erased anyway. If host physics already moved the stand-in (a
## contact the game turns into a knock event), never apply J again; the compensation keeps
## the spring from pulling it back. The host's own player is a plain local entity with no
## targets entry. mass / inertia scale the knock (dv = J / mass, dw = angular_J / inertia, 0
## when inertia is 0) and are otherwise stored for the game.
class_name CouchOwnerTargets
extends RefCounted

## stale_mode: once stale, target_for returns the held target with velocities zeroed.
const HOLD := 0
## stale_mode: once stale, target_for returns an empty array (the game owns the stand-in).
const REPORT_ONLY := 1

const _MAX_INT31 := 2147483647

## A report is extrapolated by its velocity for at most this long, then held.
var extrapolate_cap_ms: int = 100
## A peer with no accepted report for longer than this is stale.
var stale_ms: int = 500
var stale_mode: int = HOLD
## Kill switch: false makes target_for return exactly the uncompensated target.
var impulse_compensation: bool = true
## Decay time constant of the compensation model (clamped to >= 1 when read). Too short only
## loses some of the benefit; too long overshoots. Raise it for floaty bodies.
var impulse_tau_ms: int = 120
## An impulse not covered within this long is handed off as if covered then.
var impulse_timeout_ms: int = 1000

var _world: CouchReplicatedWorld
## kind -> CouchBodyChannels
var _channels: Dictionary = {}
## peer -> {"entity", "kind", "mass", "inertia", "owner_ms", "has_tick", "tick",
## "report": PackedFloat32Array (empty until the first), "report_ms", "covered_ev",
## "impulses": Array of entries}. An entry is {"id", "dv", "dw", "t0", "covered": false}
## until covered, then also {"lead", "alead", "tc"}.
var _owners: Dictionary = {}
## peer -> {"accepted", "stale_gaps", "timeouts", "rejects": reason -> count, "last_reason"}
var _counters: Dictionary = {}


func _init(world: CouchReplicatedWorld) -> void:
	_world = world


## Register (or replace) the channel map of a kind; false unless it fits the world's layout.
func set_channels(kind: int, channels: CouchBodyChannels) -> bool:
	if channels == null or not channels.fits(_world.kind_channels(kind)):
		return false
	_channels[kind] = channels
	return true


func set_owner(peer_id: String, entity_id: int, kind: int, mass: float, inertia: float, now_ms: int) -> bool:
	if not _channels.has(kind) or entity_id < 0 or entity_id > _MAX_INT31:
		return false
	if not is_finite(mass) or mass <= 0.0 or not is_finite(inertia) or inertia < 0.0:
		return false
	for other in _owners:
		if other != peer_id and _owners[other]["entity"] == entity_id:
			return false
	_owners[peer_id] = {
		"entity": entity_id, "kind": kind, "mass": mass, "inertia": inertia,
		"owner_ms": now_ms, "has_tick": false, "tick": 0,
		"report": PackedFloat32Array(), "report_ms": 0,
		"covered_ev": 0, "impulses": [],
	}
	return true


func forget(peer_id: String) -> void:
	_owners.erase(peer_id)
	_counters.erase(peer_id)


func reset() -> void:
	_owners.clear()
	_counters.clear()


func note_input(peer_id: String, body: Variant, now_ms: int) -> bool:
	if not _owners.has(peer_id):
		return _reject(peer_id, "unowned")
	if typeof(body) != TYPE_DICTIONARY:
		return _reject(peer_id, "bad-shape")
	var d: Dictionary = body
	if typeof(d.get("t")) != TYPE_INT or typeof(d.get("o")) != TYPE_PACKED_FLOAT32_ARRAY:
		return _reject(peer_id, "bad-shape")
	if d.has("ev") and (typeof(d["ev"]) != TYPE_INT or int(d["ev"]) < 0):
		return _reject(peer_id, "bad-shape")
	var o: PackedFloat32Array = d["o"]
	var rec: Dictionary = _owners[peer_id]
	if o.size() != _world.kind_channels(rec["kind"]).size():
		return _reject(peer_id, "bad-stride")
	for v in o:
		if not is_finite(v):
			return _reject(peer_id, "non-finite")
	var t: int = d["t"]
	if rec["has_tick"] and t <= rec["tick"]:
		return _reject(peer_id, "stale-tick")
	var c := _counter(peer_id)
	if now_ms - _last_heard_ms(rec) > stale_ms:
		c["stale_gaps"] += 1
	rec["report"] = o.duplicate()
	rec["report_ms"] = now_ms
	rec["has_tick"] = true
	rec["tick"] = t
	c["accepted"] += 1
	_prune_impulses(peer_id, now_ms)
	var ev: int = d.get("ev", 0)
	if ev > rec["covered_ev"]:
		rec["covered_ev"] = ev
		for entry in rec["impulses"]:
			if not entry["covered"] and entry["id"] <= ev:
				_hand_off(entry, now_ms)
	return true


func target_for(peer_id: String, now_ms: int) -> PackedFloat32Array:
	if not _owners.has(peer_id):
		return PackedFloat32Array()
	var rec: Dictionary = _owners[peer_id]
	var report: PackedFloat32Array = rec["report"]
	if report.is_empty():
		return PackedFloat32Array()
	if is_stale(peer_id, now_ms) and stale_mode == REPORT_ONLY:
		return PackedFloat32Array()
	var age: int = maxi(now_ms - int(rec["report_ms"]), 0)
	var held: bool = age > extrapolate_cap_ms
	if held:
		age = extrapolate_cap_ms
	var ch: CouchBodyChannels = _channels[rec["kind"]]
	var secs: float = age / 1000.0
	var out: PackedFloat32Array = report.duplicate()
	out[ch.x] = report[ch.x] + report[ch.vx] * secs
	out[ch.y] = report[ch.y] + report[ch.vy] * secs
	if ch.has_rotation():
		out[ch.rot] = wrapf(report[ch.rot] + report[ch.w] * secs, -PI, PI)
	if held:
		out[ch.vx] = 0.0
		out[ch.vy] = 0.0
		if ch.has_rotation():
			out[ch.w] = 0.0
	if impulse_compensation:
		var comp := compensation_of(peer_id, now_ms)
		out[ch.x] += comp["pos"].x
		out[ch.y] += comp["pos"].y
		out[ch.vx] += comp["vel"].x
		out[ch.vy] += comp["vel"].y
		if ch.has_rotation():
			out[ch.rot] = wrapf(out[ch.rot] + comp["rot"], -PI, PI)
			out[ch.w] += comp["w"]
	return out


func is_stale(peer_id: String, now_ms: int) -> bool:
	if not _owners.has(peer_id):
		return false
	return now_ms - _last_heard_ms(_owners[peer_id]) > stale_ms


## -1 if not an owner.
func entity_of(peer_id: String) -> int:
	return _owners[peer_id]["entity"] if _owners.has(peer_id) else -1


## 0.0 if not an owner.
func mass_of(peer_id: String) -> float:
	return _owners[peer_id]["mass"] if _owners.has(peer_id) else 0.0


func inertia_of(peer_id: String) -> float:
	return _owners[peer_id]["inertia"] if _owners.has(peer_id) else 0.0


## Push a reserved-kind impulse event to the owner's ring; the id, or -1 (nothing pushed).
## On success the knock is also recorded for compensation (even while it is switched off).
func push_impulse(ring: CouchEventRing, peer_id: String, impulse: Vector2, angular: float, host_tick: int, now_ms: int) -> int:
	if not _owners.has(peer_id):
		return -1
	if not is_finite(impulse.x) or not is_finite(impulse.y) or not is_finite(angular):
		return -1
	var payload := PackedFloat32Array([impulse.x, impulse.y, angular])
	var id := ring.push(peer_id, CouchOwnedEntity.IMPULSE_EVENT_KIND, payload, host_tick)
	if id < 1:
		return id
	_prune_impulses(peer_id, now_ms)
	var rec: Dictionary = _owners[peer_id]
	var inertia: float = rec["inertia"]
	rec["impulses"].append({
		"id": id, "dv": impulse / float(rec["mass"]),
		"dw": angular / inertia if inertia > 0.0 else 0.0,
		"t0": now_ms, "covered": false,
	})
	return id


## Highest "ev" of an accepted report since set_owner; 0 if not an owner.
func covered_ev(peer_id: String) -> int:
	return _owners[peer_id]["covered_ev"] if _owners.has(peer_id) else 0


## Compensation entries currently stored (uncovered and handed off, not yet dropped).
func pending_impulse_count(peer_id: String) -> int:
	return (_owners[peer_id]["impulses"] as Array).size() if _owners.has(peer_id) else 0


## Entries handed off because no covering report arrived within impulse_timeout_ms.
func impulse_timeout_count(peer_id: String) -> int:
	return int(_counters[peer_id]["timeouts"]) if _counters.has(peer_id) else 0


## The offset target_for adds while impulse_compensation is on, summed over the peer's
## entries: {"pos": Vector2, "vel": Vector2, "rot": float, "w": float}. Changes nothing.
func compensation_of(peer_id: String, now_ms: int) -> Dictionary:
	var sum := {"pos": Vector2.ZERO, "vel": Vector2.ZERO, "rot": 0.0, "w": 0.0}
	if not _owners.has(peer_id):
		return sum
	for entry in _owners[peer_id]["impulses"]:
		var part: Dictionary
		if entry["covered"]:
			part = _decaying_lead(entry, now_ms)
		elif now_ms - int(entry["t0"]) > impulse_timeout_ms:
			# Evaluate as the prune will hand it off, so the value does not depend on when it ran.
			var handed: Dictionary = entry.duplicate()
			_hand_off(handed, int(entry["t0"]) + impulse_timeout_ms)
			part = _decaying_lead(handed, now_ms)
		else:
			part = _growing_lead(entry, now_ms)
		for key in sum:
			sum[key] += part[key]
	return sum


func accepted_count(peer_id: String) -> int:
	return int(_counters[peer_id]["accepted"]) if _counters.has(peer_id) else 0


func reject_count(peer_id: String, reason: String) -> int:
	if not _counters.has(peer_id):
		return 0
	return int(_counters[peer_id]["rejects"].get(reason, 0))


func last_reject_reason(peer_id: String) -> String:
	return _counters[peer_id]["last_reason"] if _counters.has(peer_id) else ""


## Accepted reports that arrived more than stale_ms after the previous report (or set_owner).
func stale_gap_count(peer_id: String) -> int:
	return int(_counters[peer_id]["stale_gaps"]) if _counters.has(peer_id) else 0


## Decay time constant in seconds.
func _tau() -> float:
	return maxi(impulse_tau_ms, 1) / 1000.0


## Before the cover: the lead P(s) = dv * tau * (1 - exp(-s / tau)) and its velocity
## dv * exp(-s / tau), s seconds since the push; zero before it.
func _growing_lead(entry: Dictionary, now_ms: int) -> Dictionary:
	var s: float = (now_ms - int(entry["t0"])) / 1000.0
	if s < 0.0:
		return {"pos": Vector2.ZERO, "vel": Vector2.ZERO, "rot": 0.0, "w": 0.0}
	var tau := _tau()
	var e := exp(-s / tau)
	return {
		"pos": entry["dv"] * tau * (1.0 - e), "vel": entry["dv"] * e,
		"rot": entry["dw"] * tau * (1.0 - e), "w": entry["dw"] * e,
	}


## After the cover: the lead frozen at tc decays as lead * exp(-s / tau), velocity
## -lead / tau * exp(-s / tau), s seconds since tc (never negative).
func _decaying_lead(entry: Dictionary, now_ms: int) -> Dictionary:
	var s: float = maxi(now_ms - int(entry["tc"]), 0) / 1000.0
	var tau := _tau()
	var e := exp(-s / tau)
	return {
		"pos": entry["lead"] * e, "vel": -entry["lead"] / tau * e,
		"rot": entry["alead"] * e, "w": -entry["alead"] / tau * e,
	}


## Freeze an uncovered entry's lead at tc_ms; from then on it decays.
func _hand_off(entry: Dictionary, tc_ms: int) -> void:
	var at_cover := _growing_lead(entry, tc_ms)
	entry["covered"] = true
	entry["lead"] = at_cover["pos"]
	entry["alead"] = at_cover["rot"]
	entry["tc"] = tc_ms


## Hand off entries that waited longer than impulse_timeout_ms (counted once) and drop
## handed-off entries more than 8 tau past their tc.
func _prune_impulses(peer_id: String, now_ms: int) -> void:
	var rec: Dictionary = _owners[peer_id]
	var kept: Array = []
	for entry in rec["impulses"]:
		if not entry["covered"] and now_ms - int(entry["t0"]) > impulse_timeout_ms:
			_hand_off(entry, int(entry["t0"]) + impulse_timeout_ms)
			_counter(peer_id)["timeouts"] += 1
		if entry["covered"] and now_ms - int(entry["tc"]) > 8.0 * _tau() * 1000.0:
			continue
		kept.append(entry)
	rec["impulses"] = kept


## When the peer was last heard from: its newest report, else when it became an owner.
func _last_heard_ms(rec: Dictionary) -> int:
	return rec["owner_ms"] if (rec["report"] as PackedFloat32Array).is_empty() else rec["report_ms"]


func _counter(peer_id: String) -> Dictionary:
	if not _counters.has(peer_id):
		_counters[peer_id] = {"accepted": 0, "stale_gaps": 0, "timeouts": 0, "rejects": {}, "last_reason": ""}
	return _counters[peer_id]


## Count a rejection; always returns false so note_input can `return _reject(...)`.
func _reject(peer_id: String, reason: String) -> bool:
	var c := _counter(peer_id)
	c["rejects"][reason] = int(c["rejects"].get(reason, 0)) + 1
	c["last_reason"] = reason
	return false
