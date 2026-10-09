## OWNER-side controller of pushable props (docs/plans/prop-authority-design.md). Each prop's
## copy is normally a frozen puppet drawn at the replicated sample. When this peer's player
## comes near a prop that is free (or still named this peer's), update() returns CLAIM with
## the newest snapshot advanced to this tick: the game unfreezes the copy there and simulates
## it, so its controller collides with it and pushes it with no delay. Predicting IS a claim:
## input_fields() reports the copy every tick and the host grants the first claim on a free
## prop (CouchPropAuthority), whose body then follows this copy. update() returns RELEASE when
## the claim is denied or, once settled, when this peer has left the prop alone; the copy
## goes back to a puppet, blending from where this peer had it to the sample. Presses others
## make on a prop this peer holds arrive in snapshots and are spread over the snapshot
## interval (drain_press). Pure data: no Nodes, no physics server, no Time; wall time is now_ms.
##
## CONTRACT. Props are keyed by entity id; owner_of is the newest on_snapshot's owner ("" =
## free or unknown). Per prop, states PUPPET, CLAIMING (predicting, not granted), HELD
## (predicting, granted):
##   PUPPET -> CLAIMING: CLAIM when near AND the owner is "" or my_id (for a round trip after
##   a release the snapshots still name this peer) AND world.latest(eid) is not empty AND
##   now_ms >= the backoff. The CLAIM state is latest advanced by age = clamp((tick -
##   latest.tick) * physics_dt, 0, extrapolate_cap_ms / 1000): x, y by vx, vy; rot (if the
##   kind has one) by w, wrapped to [-PI, PI]; every other channel as in the snapshot.
##   Slice C (item 3): the CLAIM state is the last drawn pose (the "now" state when nothing was
##   drawn yet) with the "now" velocities; the difference rides in the report as claim_off * k,
##   k = 1 at the claim, decaying to 0 (see _decay). The drawn pose is the collider, so the claim
##   never jumps on screen.
##   CLAIMING / HELD, in this order:
##   1. owner == my_id and now_ms - claim >= int(rtt_ms): granted (HELD). An earlier "mine"
##      is the previous grant still on the wire.
##   2. denial -> RELEASE, denials += 1, backoff until now_ms + int(rtt_ms); reason "lost"
##      (owner neither "" nor my_id), else "taken-back" (granted, owner ""), else
##      "unanswered" (not granted, now_ms - claim > int(rtt_ms) + snapshot_ms +
##      claim_grace_ms; snapshot_ms is 0 until the first on_snapshot).
##   3. near: the contact time is noted.
##   4. else RELEASE "settled" when ALL of: release_idle_ms since the last contact, the
##      copy's speed < settle_speed, the copy's position within release_match of the last
##      render_pose sample (none yet: never), no queued press.
##   5. else (slice C, item 1) HELD and RELEASE "transfer" when not near, release_idle_ms since
##      the last contact, and a press run is still live (the newest queued press is at most
##      transfer_gap_ms old) that has lasted release_idle_ms. Not counted as a denial.
##   Every RELEASE: releases += 1, the press queue is cleared, the copy's pose at release is
##   the release offset's start (slice C, item 3), the claim offset and run tracking reset. on_snapshot queues a non-zero "pp"[eid]["pr"] (left += press,
##   ticks_left = snapshot_ticks, presses_applied += 1) only while predicting and named owner;
##   otherwise it is dropped (the presser keeps pressing). update() returns {"action": NONE /
##   CLAIM / RELEASE, "state": the CLAIM state else empty, "reason": "" except on RELEASE}.
##
## GAME WIRING (owner). Setup: set_channels(kind, channels); add_prop(eid, kind) on
## entity_spawned, remove_prop on entity_despawned. After every accepted world.ingest:
## on_snapshot(world.extra(), snapshot_every, now_ms). Each owner tick, after applying inbox
## events and BEFORE the player steps, per prop: d := update(eid, gap < CLAIM_MARGIN, the
## copy's state in the kind's layout, tick, now_ms, clock.rtt_ms); CLAIM: unfreeze the copy
## at d["state"]; RELEASE: freeze it; then apply drain_press(eid) to it. After the player
## steps: presses on predicted props are applied to the copy; merge input_fields(tick,
## {eid: copy state}, {eid: press}) into the input next to CouchOwnedEntity.input_fields.
## Each render frame: p := render_pose(...); while not predicting put the frozen body at p
## (so what is drawn is what blocks the controller). The body-level gotchas (STATIC puppet,
## body_set_state on CLAIM, freeze on RELEASE, same body everywhere, skip zero presses) are
## CouchPropAuthority's PHYSICS-BODY RECIPE.
class_name CouchPropController
extends RefCounted

const NONE := 0
const CLAIM := 1
const RELEASE := 2

const _MAX_INT31 := 2147483647

var release_idle_ms: int = 300      # own contact gap before a settled release
var settle_speed: float = 10.0      # units/s: the copy must be slower than this to release
var release_match: float = 1.0      # units: the sample must show the prop this close to the copy
var extrapolate_cap_ms: int = 250   # claim: newest snapshot advanced by at most this
var claim_grace_ms: int = 150       # slack before an unanswered claim is given up
var transfer_gap_ms: int = 100      # slice C: a press run stays live while presses come this close
var offset_tau_ms: int = 100        # slice C: claim and release offsets close at k / tau
var offset_max_speed: float = 150.0 # slice C: units/s; an offset never closes faster than this
var claims: int = 0
var releases: int = 0               # every RELEASE decision
var denials: int = 0                # RELEASE for "lost", "taken-back" or "unanswered"
var transfers: int = 0              # RELEASE for "transfer" (slice C; not a denial)
var presses_applied: int = 0        # snapshots whose forwarded press was queued

var _world: CouchReplicatedWorld
var _my_id: String
var _dt: float
var _snapshot_ms: int = 0
## kind -> CouchBodyChannels
var _channels: Dictionary = {}
## eid -> {"kind", "owner", "predicting", "granted", "claim_ms", "contact_ms", "backoff_ms",
## "left": Vector3, "ticks_left", "has_sample", "sample_pos", "from_pos", "from_rot",
## slice C: "run_start_ms", "run_last_ms" (-1: no run), "claim_off" Vector2, "claim_rot_off",
## "claim_k" (report offset weight), "drawn_pos", "drawn_rot", "has_drawn" (last pose drawn),
## "rel_pending", "rel_off_pos", "rel_off_rot", "rel_k" (release offset weight), "frame_ms"}
var _props: Dictionary = {}


func _init(world: CouchReplicatedWorld, my_id: String, physics_dt: float) -> void:
	_world = world
	_my_id = my_id
	_dt = physics_dt


## Register (or replace) a kind's channel map; false unless it fits the world's layout.
func set_channels(kind: int, channels: CouchBodyChannels) -> bool:
	if channels == null or not channels.fits(_world.kind_channels(kind)):
		return false
	_channels[kind] = channels
	return true


func add_prop(entity_id: int, kind: int) -> bool:
	if not _channels.has(kind) or entity_id < 0 or entity_id > _MAX_INT31 or _props.has(entity_id):
		return false
	_props[entity_id] = {
		"kind": kind, "owner": "", "predicting": false, "granted": false, "claim_ms": 0,
		"contact_ms": 0, "backoff_ms": 0, "left": Vector3.ZERO, "ticks_left": 0,
		"has_sample": false, "sample_pos": Vector2.ZERO, "from_pos": Vector2.ZERO,
		"from_rot": 0.0, "run_start_ms": 0, "run_last_ms": -1,
		"claim_off": Vector2.ZERO, "claim_rot_off": 0.0, "claim_k": 0.0,
		"drawn_pos": Vector2.ZERO, "drawn_rot": 0.0, "has_drawn": false,
		"rel_pending": false, "rel_off_pos": Vector2.ZERO, "rel_off_rot": 0.0, "rel_k": 0.0,
		"frame_ms": 0,
	}
	return true


func remove_prop(entity_id: int) -> void:
	_props.erase(entity_id)


## After every accepted world.ingest, with world.extra().
func on_snapshot(extra: Dictionary, snapshot_ticks: int, now_ms: int) -> void:
	_snapshot_ms = int(snapshot_ticks * _dt * 1000.0)
	var field: Variant = extra.get(CouchPropAuthority.EXTRA_KEY)
	var section: Dictionary = field if typeof(field) == TYPE_DICTIONARY else {}
	for eid in _props:
		var rec: Dictionary = _props[eid]
		var entry: Variant = section.get(eid)
		var owned: Dictionary = entry if typeof(entry) == TYPE_DICTIONARY else {}
		rec["owner"] = str(owned.get(CouchPropAuthority.EXTRA_OWNER, ""))
		if rec["owner"] != _my_id or not rec["predicting"]:
			continue
		var press := CouchPropAuthority.press_of(owned.get(CouchPropAuthority.EXTRA_PRESS))
		if press != Vector3.ZERO:
			rec["left"] += press
			rec["ticks_left"] = snapshot_ticks
			presses_applied += 1
			# Slice C: a new run starts after a gap longer than transfer_gap_ms.
			if int(rec["run_last_ms"]) < 0 or now_ms - int(rec["run_last_ms"]) > transfer_gap_ms:
				rec["run_start_ms"] = now_ms
			rec["run_last_ms"] = now_ms


## Once per owner tick per prop, BEFORE the player steps. `copy` is the body's state in the
## kind's layout (the frozen puppet's when not predicting).
func update(entity_id: int, near: bool, copy: PackedFloat32Array, tick: int, now_ms: int, rtt_ms: float) -> Dictionary:
	if not _props.has(entity_id):
		return _decision(NONE, PackedFloat32Array(), "")
	var rec: Dictionary = _props[entity_id]
	var owner: String = rec["owner"]
	if rec["claim_k"] > 0.0:
		rec["claim_k"] = _decay(rec["claim_k"], (rec["claim_off"] as Vector2).length(), _dt)
	if not rec["predicting"]:
		var latest := _world.latest(entity_id)
		if near and (owner == "" or owner == _my_id) and not latest.is_empty() and now_ms >= int(rec["backoff_ms"]):
			return _claim(rec, latest, tick, now_ms)
		return _decision(NONE, PackedFloat32Array(), "")
	if owner == _my_id and now_ms - int(rec["claim_ms"]) >= int(rtt_ms):
		rec["granted"] = true
	var reason := ""
	if owner != "" and owner != _my_id:
		reason = "lost"
	elif rec["granted"] and owner == "":
		reason = "taken-back"
	elif not rec["granted"] and now_ms - int(rec["claim_ms"]) > int(rtt_ms) + _snapshot_ms + claim_grace_ms:
		reason = "unanswered"
	if reason != "":
		denials += 1
		rec["backoff_ms"] = now_ms + int(rtt_ms)
		return _release(rec, copy, now_ms, reason)
	if near:
		rec["contact_ms"] = now_ms
		return _decision(NONE, PackedFloat32Array(), "")
	var ch: CouchBodyChannels = _channels[rec["kind"]]
	# A queued press blocks it: releasing would drop it, and a short tap on an idle, settled
	# prop would never move it.
	if now_ms - int(rec["contact_ms"]) >= release_idle_ms \
			and Vector2(copy[ch.vx], copy[ch.vy]).length() < settle_speed \
			and rec["has_sample"] and Vector2(copy[ch.x], copy[ch.y]).distance_to(rec["sample_pos"]) < release_match \
			and int(rec["ticks_left"]) == 0:
		return _release(rec, copy, now_ms, "settled")
	if rec["granted"] and _transfer_due(rec, now_ms):
		transfers += 1
		return _release(rec, copy, now_ms, "transfer")
	return _decision(NONE, PackedFloat32Array(), "")


## Once per owner tick, after update(): this tick's share of the queued presses.
func drain_press(entity_id: int) -> Vector3:
	if not _props.has(entity_id) or int(_props[entity_id]["ticks_left"]) <= 0:
		return Vector3.ZERO
	var rec: Dictionary = _props[entity_id]
	var slice: Vector3 = rec["left"] / int(rec["ticks_left"])
	rec["left"] -= slice
	rec["ticks_left"] -= 1
	return slice


## After the player steps. copies: {eid: state} for every predicted prop; presses: {eid:
## Vector3} this tick. "p" for predicted props, "pr" for non-zero presses on added props this
## peer does not predict; each key only when non-empty.
func input_fields(tick: int, copies: Dictionary, presses: Dictionary) -> Dictionary:
	var reports: Dictionary = {}
	var forwarded: Dictionary = {}
	for eid in _props:
		if _props[eid]["predicting"] and typeof(copies.get(eid)) == TYPE_PACKED_FLOAT32_ARRAY:
			reports[eid] = {"t": tick, "o": _with_claim_offset(_props[eid], copies[eid])}
		elif not _props[eid]["predicting"] and typeof(presses.get(eid)) == TYPE_VECTOR3 and presses[eid] != Vector3.ZERO:
			var p: Vector3 = presses[eid]
			forwarded[eid] = PackedFloat32Array([p.x, p.y, p.z])
	var out: Dictionary = {}
	if not reports.is_empty():
		out[CouchPropAuthority.INPUT_CLAIMS] = reports
	if not forwarded.is_empty():
		out[CouchPropAuthority.INPUT_PRESSES] = forwarded
	return out


## Once per render frame per prop: {"pos", "rot"} to DRAW. Predicted: the copy's pose.
## Otherwise the sample plus the release offset, decaying out of the last prediction (slice C).
func render_pose(entity_id: int, sample_pos: Vector2, sample_rot: float, copy_pos: Vector2, copy_rot: float, now_ms: int) -> Dictionary:
	if not _props.has(entity_id):
		return {"pos": sample_pos, "rot": sample_rot}
	var rec: Dictionary = _props[entity_id]
	rec["sample_pos"] = sample_pos
	rec["has_sample"] = true
	var pose: Dictionary = {"pos": copy_pos, "rot": copy_rot}
	if not rec["predicting"]:
		pose = _puppet_pose(rec, sample_pos, sample_rot, now_ms)
	rec["drawn_pos"] = pose["pos"]
	rec["drawn_rot"] = pose["rot"]
	rec["has_drawn"] = true
	return pose


## The puppet's pose: the sample plus the release offset while it decays (slice C, item 3).
## The offset starts at the copy's pose at release, so the first frame draws where it was.
func _puppet_pose(rec: Dictionary, sample_pos: Vector2, sample_rot: float, now_ms: int) -> Dictionary:
	if rec["rel_pending"]:
		rec["rel_pending"] = false
		rec["rel_off_pos"] = (rec["from_pos"] as Vector2) - sample_pos
		rec["rel_off_rot"] = wrapf(rec["from_rot"] - sample_rot, -PI, PI)
		rec["rel_k"] = 1.0
		rec["frame_ms"] = now_ms
	var dt := maxi(now_ms - int(rec["frame_ms"]), 0) / 1000.0
	rec["frame_ms"] = now_ms
	if rec["rel_k"] > 0.0:
		rec["rel_k"] = _decay(rec["rel_k"], (rec["rel_off_pos"] as Vector2).length(), dt)
	var k: float = rec["rel_k"]
	return {
		"pos": sample_pos + (rec["rel_off_pos"] as Vector2) * k,
		"rot": wrapf(sample_rot + float(rec["rel_off_rot"]) * k, -PI, PI),
	}


func owner_of(entity_id: int) -> String:
	return _props[entity_id]["owner"] if _props.has(entity_id) else ""


func is_predicting(entity_id: int) -> bool:
	return _props.has(entity_id) and _props[entity_id]["predicting"]


## True until the render_pose that draws the release offset's last frame.
func is_blending(entity_id: int) -> bool:
	return _props.has(entity_id) and (_props[entity_id]["rel_pending"] or float(_props[entity_id]["rel_k"]) > 0.0)


func _claim(rec: Dictionary, latest: Dictionary, tick: int, now_ms: int) -> Dictionary:
	var ch: CouchBodyChannels = _channels[rec["kind"]]
	var st: PackedFloat32Array = latest["state"]
	var age := clampf((tick - int(latest["tick"])) * _dt, 0.0, extrapolate_cap_ms / 1000.0)
	st[ch.x] += st[ch.vx] * age
	st[ch.y] += st[ch.vy] * age
	if ch.has_rotation():
		st[ch.rot] = wrapf(st[ch.rot] + st[ch.w] * age, -PI, PI)
	claims += 1
	rec["predicting"] = true
	rec["granted"] = false
	rec["claim_ms"] = now_ms
	rec["contact_ms"] = now_ms
	_start_claim_offset(rec, st, ch)
	rec["run_last_ms"] = -1
	rec["rel_k"] = 0.0
	rec["rel_pending"] = false
	return _decision(CLAIM, st, "")


## Slice C (item 3): the claim state is the last drawn pose; the gap to "now" rides in the report
## as claim_off * k, so the copy the player touches does not jump.
func _start_claim_offset(rec: Dictionary, st: PackedFloat32Array, ch: CouchBodyChannels) -> void:
	rec["claim_off"] = Vector2.ZERO
	rec["claim_rot_off"] = 0.0
	rec["claim_k"] = 0.0
	if not rec["has_drawn"]:
		return
	var drawn: Vector2 = rec["drawn_pos"]
	rec["claim_off"] = Vector2(st[ch.x], st[ch.y]) - drawn
	rec["claim_k"] = 1.0
	st[ch.x] = drawn.x
	st[ch.y] = drawn.y
	if ch.has_rotation():
		rec["claim_rot_off"] = wrapf(st[ch.rot] - rec["drawn_rot"], -PI, PI)
		st[ch.rot] = rec["drawn_rot"]


func _release(rec: Dictionary, copy: PackedFloat32Array, now_ms: int, reason: String) -> Dictionary:
	var ch: CouchBodyChannels = _channels[rec["kind"]]
	releases += 1
	rec["predicting"] = false
	rec["left"] = Vector3.ZERO
	rec["ticks_left"] = 0
	rec["from_pos"] = Vector2(copy[ch.x], copy[ch.y])
	rec["from_rot"] = copy[ch.rot] if ch.has_rotation() else 0.0
	rec["claim_k"] = 0.0
	rec["rel_pending"] = true
	rec["run_last_ms"] = -1
	return _decision(RELEASE, PackedFloat32Array(), reason)


## Slice C, item 1 (P7): idle for release_idle_ms AND a press run that has lasted release_idle_ms
## and is still live (its newest press is at most transfer_gap_ms old). The caller checks HELD
## and not near.
func _transfer_due(rec: Dictionary, now_ms: int) -> bool:
	var last := int(rec["run_last_ms"])
	return last >= 0 and now_ms - last <= transfer_gap_ms \
			and last - int(rec["run_start_ms"]) >= release_idle_ms \
			and now_ms - int(rec["contact_ms"]) >= release_idle_ms


## The report: the copy plus the claim offset, which closes to 0 (slice C, item 3).
func _with_claim_offset(rec: Dictionary, copy: PackedFloat32Array) -> PackedFloat32Array:
	var out := copy.duplicate()
	var k: float = rec["claim_k"]
	if k > 0.0:
		var ch: CouchBodyChannels = _channels[rec["kind"]]
		var off: Vector2 = rec["claim_off"]
		out[ch.x] += off.x * k
		out[ch.y] += off.y * k
		if ch.has_rotation():
			out[ch.rot] = wrapf(out[ch.rot] + float(rec["claim_rot_off"]) * k, -PI, PI)
	return out


## One step of an offset's decay (slice C, item 3): k closes at k / tau, never moving the offset
## faster than offset_max_speed; exactly 0 below 0.001.
func _decay(k: float, off_len: float, dt_s: float) -> float:
	var rate := k / (offset_tau_ms / 1000.0)
	if off_len > 0.0:
		rate = minf(rate, offset_max_speed / off_len)
	var next := maxf(k - rate * dt_s, 0.0)
	return 0.0 if next < 0.001 else next


static func _decision(action: int, state: PackedFloat32Array, reason: String) -> Dictionary:
	return {"action": action, "state": state, "reason": reason}
