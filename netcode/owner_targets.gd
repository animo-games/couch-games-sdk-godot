## HOST-side bookkeeping for owner-authority: which peer owns which entity, the latest
## accepted report of each owner, staleness, and the extrapolated target a
## CouchPDFollower chases. Pure data; wall time is passed in as now_ms.
##
## CONTRACT. note_input validates in this order, first failure wins, and a rejection
## changes nothing but reject_count / last_reject_reason: "unowned" (peer owns no entity),
## "bad-shape" (body not a Dictionary, "t" missing or not an int, "o" missing or not a
## PackedFloat32Array), "bad-stride" (o.size() != the kind's stride), "non-finite",
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
## GAME WIRING (host). Setup: targets.set_channels(PLAYER_KIND, CouchBodyChannels.new({...})).
## player_joined: targets.set_owner(peer, eid, PLAYER_KIND, mass, inertia, now_ms) and
## world.set_entity(eid, ...). player_left: targets.forget(peer), ring.forget(peer),
## world.remove_entity(eid). On input: ring.ack(peer, int(body.get("ev", 0))) then
## targets.note_input(peer, body, now_ms). Each physics step feed
## targets.target_for(peer, now_ms) to that stand-in's CouchPDFollower. To knock a player:
## targets.push_impulse(ring, peer, J, angular_J, host_tick); the owner applies it (see
## CouchOwnedEntity, including its ALIGNMENT RULE). The host's own player is a plain local
## entity with no targets entry. mass / inertia are stored for the game and unused here.
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

var _world: CouchReplicatedWorld
## kind -> CouchBodyChannels
var _channels: Dictionary = {}
## peer -> {"entity", "kind", "mass", "inertia", "owner_ms", "has_tick", "tick",
## "report": PackedFloat32Array (empty until the first), "report_ms"}
var _owners: Dictionary = {}
## peer -> {"accepted", "stale_gaps", "rejects": reason -> count, "last_reason"}
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
func push_impulse(ring: CouchEventRing, peer_id: String, impulse: Vector2, angular: float, host_tick: int) -> int:
	if not _owners.has(peer_id):
		return -1
	if not is_finite(impulse.x) or not is_finite(impulse.y) or not is_finite(angular):
		return -1
	var payload := PackedFloat32Array([impulse.x, impulse.y, angular])
	return ring.push(peer_id, CouchOwnedEntity.IMPULSE_EVENT_KIND, payload, host_tick)


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


## When the peer was last heard from: its newest report, else when it became an owner.
func _last_heard_ms(rec: Dictionary) -> int:
	return rec["owner_ms"] if (rec["report"] as PackedFloat32Array).is_empty() else rec["report_ms"]


func _counter(peer_id: String) -> Dictionary:
	if not _counters.has(peer_id):
		_counters[peer_id] = {"accepted": 0, "stale_gaps": 0, "rejects": {}, "last_reason": ""}
	return _counters[peer_id]


## Count a rejection; always returns false so note_input can `return _reject(...)`.
func _reject(peer_id: String, reason: String) -> bool:
	var c := _counter(peer_id)
	c["rejects"][reason] = int(c["rejects"].get(reason, 0)) + 1
	c["last_reason"] = reason
	return false
