## HOST-side owner of pushable props (docs/plans/prop-authority-design.md). Exactly one peer
## simulates each prop: the host (free, or held by the host's own player) or the guest that
## claimed it, whose reported copy the host's body then follows. Anyone else's contact is a
## per-tick PRESS routed to the simulator: applied now while the host simulates the prop,
## else summed and forwarded to the owner in the next snapshot. Never an ownership change,
## never a knock. Pure data: no Nodes, no physics server, no Time; wall time is now_ms.
##
## CONTRACT. Props are keyed by entity id; each gets its OWN CouchOwnerTargets (channels for
## its kind, impulse_compensation false, other tuning at defaults), so a prop has at most one
## owner and a peer may own several. owner_of: "" = free, host id = the host's player holds
## it, else the owning guest. Per prop:
##   FREE -> HOST on update(host_near); HOST -> FREE on update once not near for
##   release_idle_ms (no settle wait: the host's body is the real one).
##   FREE -> GUEST(g) on an input from g claiming it ("p"[eid]) when set_owner AND note_input
##   both accept; otherwise nothing changes (a rejected first report is not a denial).
##   GUEST(g) -> FREE on an input from g without that prop's claim (releases), on update with
##   g stale (takebacks; checked BEFORE the host hold) and on forget(g) (takebacks).
##   A take-back or forget also refuses g's claims on that prop (item 5): they grant nothing
##   and count in refused_claims until an input from g without that prop's claim clears it.
##   Claims on a prop held by anyone else, the host included, are ignored.
## on_input order: releases, then claims, then presses ("pr"), so an input releasing a prop
## and pressing it returns the press to apply. A bad "pr" entry (key not an added prop's int
## id, value not a finite PackedFloat32Array of size 3) counts in bad_presses; a zero press is
## skipped. apply_now: guest-owned -> summed for the current owner (a sum collected for a
## previous owner is discarded first), false; free or host-held -> true (apply it now).
## take_snapshot_extra (once per snapshot): {"pp": {eid: {"ow": owner, "pr"?: [jx, jy, aj]}}}
## for every held prop, "pr" only for a non-zero sum collected for the current owner; every
## sum is then cleared; free props are absent; {} when none is held. target_for is empty iff
## not is_guest_owned. update / forget / on_input return {eid: Vector3} presses for the game
## to apply now, with the same call as apply_now presses.
##
## LIMIT (recovered presses). Presses forwarded within one round trip plus one snapshot
## interval of a release under press are lost (~280 ms at 250 ms RTT). update and forget
## always return {} and on_input only its routed presses until host-acknowledged release
## (design item 2) fills them; the signatures will not change.
##
## GAME WIRING (host). Setup: set_channels(kind, channels); add_prop(eid, kind, mass, inertia).
## Each physics tick, before the host's player steps: apply update(eid, host_near, now_ms)'s
## presses, then switch the body to follow while is_guest_owned(eid). host_near is the game's
## player-to-prop gap below its claim margin, not actual contact. The host's own presses go
## through apply_now (apply when true). Feed target_for(eid, now_ms) to the body's
## CouchPDFollower in _integrate_forces. Per snapshot: extra.merge(take_snapshot_extra()). On
## an accepted input (after ring.ack and the player's note_input): apply on_input's presses.
## player_left: apply forget(peer)'s presses. Keys "p" / "pr" (input) and "pp" (snapshot
## extra) are reserved for the addon.
##
## PHYSICS-BODY RECIPE (gotchas observed on Godot 4.7; 2D RigidBody2D):
##   1. Owner puppet: freeze STATIC, not KINEMATIC. A frozen kinematic body went to sleep on
##      the controller's first contact (can_sleep = false did not help) and stopped taking
##      node moves; a static body takes every node move and still blocks the controller.
##   2. On CLAIM: set transform, freeze = false, then ALSO PhysicsServer2D.body_set_state(rid,
##      BODY_STATE_TRANSFORM, xf), then linear_velocity / angular_velocity from the state.
##      Without the server write a jump back was seen once.
##   3. On RELEASE: freeze = true (STATIC); the controller's render_pose places it from then on.
##   4. Host follower: while guest-owned set can_sleep = false and sleeping = false (a sleeping
##      body gets no _integrate_forces); restore can_sleep when the host simulates it again.
##      Snap inside _integrate_forces only.
##   5. Host controller layer: while a guest owns the prop, drop the controller layer from the
##      prop's collision MASK (the host's controller is still blocked by it and presses it);
##      restore it when the host simulates the prop.
##   6. Same body everywhere: mass, explicit inertia, damping and shape equal on the host's body
##      and every owner copy.
##   7. Skip zero presses: apply_central_impulse(Vector2.ZERO) still wakes a sleeping body.
class_name CouchPropAuthority
extends RefCounted

const INPUT_CLAIMS := "p"     # input: {eid: {"t": int, "o": PackedFloat32Array}}
const INPUT_PRESSES := "pr"   # input: {eid: PackedFloat32Array([jx, jy, aj])}
const EXTRA_KEY := "pp"       # snapshot extra: {eid: {"ow": String, "pr": PackedFloat32Array}}
const EXTRA_OWNER := "ow"
const EXTRA_PRESS := "pr"

const _MAX_INT31 := 2147483647

## Host let-go: the host's own player stops holding a prop this long after it was last near it.
var release_idle_ms: int = 300
var grants: int = 0             # guest claims granted
var releases: int = 0           # guest owners that released (an input without the prop's claim)
var takebacks: int = 0          # guest owners that went stale or left
var presses_forwarded: int = 0  # owner entries in take_snapshot_extra() that carried a press
var bad_presses: int = 0        # malformed INPUT_PRESSES entries ignored
var refused_claims: int = 0     # slice D: claims ignored after a take-back (item 5)

var _world: CouchReplicatedWorld
var _host_id: String
## kind -> CouchBodyChannels
var _channels: Dictionary = {}
## eid -> {"kind", "mass", "inertia", "targets": CouchOwnerTargets, "owner": String,
## "host_ms": last time the host was near, "sum": Vector3, "sum_for": owner it was summed for,
## "refused": {peer: true} whose claims on this prop are refused after a take-back (item 5)}
var _props: Dictionary = {}


func _init(world: CouchReplicatedWorld, host_id: String) -> void:
	_world = world
	_host_id = host_id


## Register (or replace) a kind's channel map; false unless it fits the world's layout.
func set_channels(kind: int, channels: CouchBodyChannels) -> bool:
	if channels == null or not channels.fits(_world.kind_channels(kind)):
		return false
	_channels[kind] = channels
	for eid in _props:
		if _props[eid]["kind"] == kind:
			(_props[eid]["targets"] as CouchOwnerTargets).set_channels(kind, channels)
	return true


func add_prop(entity_id: int, kind: int, mass: float, inertia: float) -> bool:
	if not _channels.has(kind) or entity_id < 0 or entity_id > _MAX_INT31 or _props.has(entity_id):
		return false
	if not is_finite(mass) or mass <= 0.0 or not is_finite(inertia) or inertia < 0.0:
		return false
	var targets := CouchOwnerTargets.new(_world)
	targets.set_channels(kind, _channels[kind])
	targets.impulse_compensation = false
	_props[entity_id] = {
		"kind": kind, "mass": mass, "inertia": inertia, "targets": targets, "owner": "",
		"host_ms": 0, "sum": Vector3.ZERO, "sum_for": "", "refused": {},
	}
	return true


func remove_prop(entity_id: int) -> void:
	_props.erase(entity_id)


func owner_of(entity_id: int) -> String:
	return _props[entity_id]["owner"] if _props.has(entity_id) else ""


func is_guest_owned(entity_id: int) -> bool:
	var owner := owner_of(entity_id)
	return owner != "" and owner != _host_id


## Once per physics tick per prop, before the host's player steps. Returns recovered presses.
func update(entity_id: int, host_near: bool, now_ms: int) -> Dictionary:
	if not _props.has(entity_id):
		return {}
	var rec: Dictionary = _props[entity_id]
	if is_guest_owned(entity_id) and (rec["targets"] as CouchOwnerTargets).is_stale(rec["owner"], now_ms):
		_take_back(rec)
	if host_near:
		rec["host_ms"] = now_ms
		if rec["owner"] == "":
			rec["owner"] = _host_id
	elif rec["owner"] == _host_id and now_ms - int(rec["host_ms"]) >= release_idle_ms:
		rec["owner"] = ""
	return {}


## Every input the game accepted from a remote player. Returns {eid: Vector3} to apply now.
func on_input(peer_id: String, body: Dictionary, now_ms: int) -> Dictionary:
	var field: Variant = body.get(INPUT_CLAIMS)
	var claims: Dictionary = field if typeof(field) == TYPE_DICTIONARY else {}
	_release_unclaimed(peer_id, claims)
	_grant_claims(peer_id, claims, now_ms)
	return _route_presses(body.get(INPUT_PRESSES))


## true = the caller applies the press now (the host simulates the prop).
func apply_now(entity_id: int, press: Vector3) -> bool:
	if not _props.has(entity_id):
		return false
	var rec: Dictionary = _props[entity_id]
	if is_guest_owned(entity_id):
		if rec["sum_for"] != rec["owner"]:
			rec["sum"] = Vector3.ZERO
			rec["sum_for"] = rec["owner"]
		rec["sum"] += press
		return false
	return true


## The owner's report extrapolated; empty while the host simulates the prop.
func target_for(entity_id: int, now_ms: int) -> PackedFloat32Array:
	if not is_guest_owned(entity_id):
		return PackedFloat32Array()
	var rec: Dictionary = _props[entity_id]
	return (rec["targets"] as CouchOwnerTargets).target_for(rec["owner"], now_ms)


## Exactly once per snapshot sent; consumes the press sums.
func take_snapshot_extra() -> Dictionary:
	var section: Dictionary = {}
	for eid in _props:
		var rec: Dictionary = _props[eid]
		var owner: String = rec["owner"]
		if owner != "":
			var entry: Dictionary = {EXTRA_OWNER: owner}
			var sum: Vector3 = rec["sum"]
			if sum != Vector3.ZERO and rec["sum_for"] == owner:
				entry[EXTRA_PRESS] = PackedFloat32Array([sum.x, sum.y, sum.z])
				presses_forwarded += 1
			section[eid] = entry
		rec["sum"] = Vector3.ZERO
	return {} if section.is_empty() else {EXTRA_KEY: section}


## player_left: every prop the peer owns is taken back. Returns recovered presses.
func forget(peer_id: String) -> Dictionary:
	for eid in _props:
		var rec: Dictionary = _props[eid]
		if is_guest_owned(eid) and rec["owner"] == peer_id:
			_take_back(rec)
	return {}


## A finite PackedFloat32Array of size 3 -> Vector3(jx, jy, aj); anything else -> ZERO.
static func press_of(field: Variant) -> Vector3:
	if not _is_press(field):
		return Vector3.ZERO
	var p: PackedFloat32Array = field
	return Vector3(p[0], p[1], p[2])


static func _is_press(field: Variant) -> bool:
	if typeof(field) != TYPE_PACKED_FLOAT32_ARRAY or (field as PackedFloat32Array).size() != 3:
		return false
	for v in (field as PackedFloat32Array):
		if not is_finite(v):
			return false
	return true


func _release_unclaimed(peer_id: String, claims: Dictionary) -> void:
	for eid in _props:
		var rec: Dictionary = _props[eid]
		if claims.has(eid):
			continue
		(rec["refused"] as Dictionary).erase(peer_id)
		if rec["owner"] == peer_id and is_guest_owned(eid):
			releases += 1
			_free(rec)


func _grant_claims(peer_id: String, claims: Dictionary, now_ms: int) -> void:
	for eid in claims:
		if typeof(eid) != TYPE_INT or not _props.has(eid):
			continue
		var rec: Dictionary = _props[eid]
		if (rec["refused"] as Dictionary).has(peer_id):
			refused_claims += 1
			continue
		var targets: CouchOwnerTargets = rec["targets"]
		if rec["owner"] == "":
			if targets.set_owner(peer_id, eid, rec["kind"], rec["mass"], rec["inertia"], now_ms) and targets.note_input(peer_id, claims[eid], now_ms):
				grants += 1
				rec["owner"] = peer_id
			else:
				targets.forget(peer_id)
		elif rec["owner"] == peer_id:
			targets.note_input(peer_id, claims[eid], now_ms)


func _route_presses(field: Variant) -> Dictionary:
	var out: Dictionary = {}
	if typeof(field) != TYPE_DICTIONARY:
		return out
	var presses: Dictionary = field
	for eid in presses:
		if typeof(eid) != TYPE_INT or not _props.has(eid) or not _is_press(presses[eid]):
			bad_presses += 1
			continue
		var press := press_of(presses[eid])
		if press != Vector3.ZERO and apply_now(eid, press):
			out[eid] = out.get(eid, Vector3.ZERO) + press
	return out


## Guest owner -> free: the inner targets forget it.
func _free(rec: Dictionary) -> void:
	(rec["targets"] as CouchOwnerTargets).forget(rec["owner"])
	rec["owner"] = ""


## A take-back (stale or forget): free, and refuse the old owner's claims on this prop (item 5).
func _take_back(rec: Dictionary) -> void:
	takebacks += 1
	(rec["refused"] as Dictionary)[rec["owner"]] = true
	_free(rec)
