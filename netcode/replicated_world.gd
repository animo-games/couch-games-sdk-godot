## Replicated entity world: the host packs ALL entities into one snapshot body; the
## client ingests bodies, buffers per-entity history and samples interpolated state
## at render time. Pure data: no Nodes, no physics, no transport. The game passes
## the body to CouchSession.broadcast_snapshot() and applies sample() results to its
## own nodes. ONE class serves either role (the kind registry is shared); a game
## uses one instance per role.
##
## ENTITY MODEL. entity = (id: int, kind: int, state: PackedFloat32Array). Each kind
## is registered on BOTH sides with a channel layout, e.g.
## register_kind(CRATE, [LERP, LERP, ANGLE, LERP, LERP, LERP]). LERP is linear, ANGLE
## is radians on the shortest arc (results wrapped to [-PI, PI)), SNAP steps (flags,
## animation ids, hp). Stride = channel count; the layout is NOT on the wire. State
## is float32: ints are exact to 2^24; strings and variable-length data belong in the
## extra Dictionary or in events.
##
## WIRE SHAPE (pack() output, ingest() input):
##   { "ht": int, "lh": int, "ids": PackedInt32Array (ascending),
##     "kinds": PackedInt32Array, "st": PackedFloat32Array (states concatenated),
##     "pl": { peer_id: {"ack": int, "rt": int, "hm": int, "mg": int,
##                       "ev": [[event_id, kind, payload], ...]} },
##     "x": Dictionary (only when the extra is non-empty) }
## Every snapshot is the FULL world, so latest-wins loss is invisible. "rt"/"hm"/"mg"
## are CouchNetClockEcho's recv_tick/hold_ms/margin under short wire names; the
## packer owns them (and "ht") so games do not carry clock fields by hand. The body
## is broadcast, so every peer receives every "pl" section and reads only its own.
##
## WHY "lh" (layout hash, FNV-1a over every kind's id + channels, independent of
## registration order) is on EVERY snapshot: the stride check cannot see two kinds
## whose channels are swapped at equal length, and a hash in the body keeps
## CouchSession's hello untouched. A snapshot with a different hash is rejected whole.
##
## INGEST. Validation order, first failure wins, and a rejection changes no state
## except rejected_count / last_reject_reason / the rejected(reason) signal:
## bad-shape, layout-mismatch, size-mismatch, unknown-kind, duplicate-id,
## bad-state-length, bad-peer-section. Then ht <= newest_tick() is stale: counted,
## ignored. Accepting snapshot S updates each entity's LIFE (a spawn..despawn span
## with its own samples): an id new to S, or returning after a despawn, or with a
## changed kind starts a NEW life at S; an id absent from S has its life end at S.
## Lives never mix samples, so a reused id never interpolates from its predecessor.
##
## WHY spawn/despawn fire from sample() at RENDER time, not on ingest: the client
## renders render_delay behind the newest data. Firing on receipt would make things
## appear and vanish that long before their interpolated motion says they should (a
## crate would vanish before it visibly reached the pit). So a life's spawn tick S
## fires on the first sample() call with render time >= S*1000, its despawn likewise
## (never before its own spawn). Each fires exactly ONCE per life, tracked by flags
## rather than by "ticks crossed since the previous call": a LATE snapshot (render
## time already passed its tick when it arrives) must still fire on the next call,
## or the game would get a never-spawned entity or a never-despawned ghost. Within a
## call signals fire in ascending tick order, despawns before spawns at an equal
## tick, ties by id. Local ids fire none, and a spawn/despawn that comes due while
## its id is local is consumed silently (the game already owns that node, so it is
## not announced later if the id stops being local).
##
## SAMPLING (milliticks, integer; floats only for entity state). Between samples a, b:
## alpha = (r - a*1000) / ((b - a)*1000). Past the newest sample LERP/ANGLE
## extrapolate linearly from the last two samples for at most extrapolate_cap_ticks,
## then hold; SNAP holds. Before the oldest sample, hold it. extrapolated_frames and
## held_frames count sample() calls (not entities) so underrun is observable.
## Render time never runs backwards: a lower render_milli reuses the previous one.
##
## LOCAL ENTITIES. set_local(ids) marks entities the client owns/predicts: they are
## buffered but omitted from sample() and its signals; latest()/state_at() expose
## host truth (a reconciling predictor reads the host state at its ack tick).
##
## Copy-not-alias: set_entity, pack, ingest, extra(), peer_section(), sample(),
## latest() and state_at() never share arrays or dictionaries with the caller.
## reset() (new epoch) clears everything except the kind registry.
##
## Game wiring. Host per snapshot: `body = world.pack(tick, now, acks, echo, ring,
## extra)`; `session.broadcast_snapshot(body)`. Host on input from a peer: drop
## stale-epoch inputs, then `echo.note_input(...)` and
## `ring.ack(peer, int(input_body.get("ev", 0)))`. Client on snapshot:
## `if world.ingest(body): ps = world.peer_section(me); clock.on_snapshot(ps.ht, now);
## if ps.has("rt"): clock.on_echo(ps.rt, ps.hm, ps.mg, now);
## for e in inbox.receive(ps.ev): apply(e)`. Client per frame:
## `world.sample(clock.render_tick_milli(now))`.
class_name CouchReplicatedWorld
extends RefCounted

## Linear channel.
const LERP := 0
## Radians, shortest arc, wrapped to [-PI, PI).
const ANGLE := 1
## Step channel.
const SNAP := 2

const _MAX_INT31 := 2147483647
const _FNV_BASIS := 2166136261
const _FNV_PRIME := 16777619

## Fired from sample() when an entity life's spawn tick is reached by render time.
signal entity_spawned(id: int, kind: int)
## Fired from sample() when an entity life's despawn tick is reached by render time.
signal entity_despawned(id: int)
## Fired by ingest() with the reason when a body is rejected.
signal rejected(reason: String)

## Samples kept per entity life (client).
var history_size: int = 8
## Ticks of linear extrapolation past the newest sample before holding (client).
var extrapolate_cap_ticks: int = 6

## Snapshots ignored as stale or duplicate.
var stale_count: int = 0
## Snapshots rejected as malformed.
var rejected_count: int = 0
## Reason of the most recent rejection, "" until the first.
var last_reject_reason: String = ""
## sample() calls that extrapolated.
var extrapolated_frames: int = 0
## sample() calls that held past the extrapolation cap.
var held_frames: int = 0

## kind -> Array of channel ints
var _kinds: Dictionary = {}
var _layout_hash: int = _FNV_BASIS
## host: id -> {"kind": int, "state": PackedFloat32Array}
var _entities: Dictionary = {}

var _newest: int = -1
var _pl: Dictionary = {}
var _extra: Dictionary = {}
var _local: Dictionary = {}
## id -> Array of lives (oldest first, the last is the current one). A life is
## {"kind", "spawn", "despawn" (-1 = none), "ticks": Array[int], "states": Array,
## "spawn_fired", "despawn_fired": signal flags}
var _lives: Dictionary = {}
var _has_render: bool = false
var _last_render: int = 0


## Register a kind with its channel layout; false if invalid or already registered.
func register_kind(kind: int, channels: Array) -> bool:
	if kind < 0 or kind > _MAX_INT31 or channels.is_empty() or _kinds.has(kind):
		return false
	for c in channels:
		if typeof(c) != TYPE_INT or c < LERP or c > SNAP:
			return false
	_kinds[kind] = channels.duplicate()
	_layout_hash = _compute_hash()
	return true


## Copy of a registered kind's channel list; [] if the kind is unregistered.
func kind_channels(kind: int) -> Array:
	if not _kinds.has(kind):
		return []
	return (_kinds[kind] as Array).duplicate()


## FNV-1a 32-bit hash of the registry (ascending kind order: kind, count, channels).
func layout_hash() -> int:
	return _layout_hash


## Host: set or replace an entity (stores a copy of state).
func set_entity(id: int, kind: int, state: PackedFloat32Array) -> bool:
	if id < 0 or id > _MAX_INT31 or not _kinds.has(kind):
		return false
	if state.size() != (_kinds[kind] as Array).size():
		return false
	_entities[id] = {"kind": kind, "state": state.duplicate()}
	return true


## Host: remove an entity; false if absent.
func remove_entity(id: int) -> bool:
	return _entities.erase(id)


## Host: whether the entity exists.
func has_entity(id: int) -> bool:
	return _entities.has(id)


## Host: pack the world into one snapshot body (see the wire shape above). `acks` is
## peer_id -> ack tick and defines which peers get a section.
func pack(host_tick: int, now_ms: int, acks: Dictionary,
		echo: CouchNetClockEcho = null, ring: CouchEventRing = null,
		extra: Dictionary = {}) -> Dictionary:
	if ring != null:
		ring.expire(host_tick)
	var order: Array = _entities.keys()
	order.sort()
	var ids := PackedInt32Array()
	var kinds := PackedInt32Array()
	var st := PackedFloat32Array()
	for id in order:
		var ent: Dictionary = _entities[id]
		ids.append(id)
		kinds.append(ent["kind"])
		st.append_array(ent["state"])
	var pl: Dictionary = {}
	for peer in acks:
		var section: Dictionary = {"ack": int(acks[peer])}
		if echo != null:
			var e: Dictionary = echo.echo_for(peer, now_ms)
			if not e.is_empty():
				section["rt"] = e[CouchNetClockEcho.KEY_RECV_TICK]
				section["hm"] = e[CouchNetClockEcho.KEY_HOLD_MS]
				section["mg"] = e[CouchNetClockEcho.KEY_MARGIN]
		if ring != null:
			section["ev"] = ring.pending_for(peer)
		pl[peer] = section
	var body: Dictionary = {"ht": host_tick, "lh": _layout_hash, "ids": ids,
			"kinds": kinds, "st": st, "pl": pl}
	if not extra.is_empty():
		body["x"] = extra.duplicate(true)
	return body


## Client: validate and ingest a snapshot body; true iff accepted as the newest.
func ingest(body: Variant) -> bool:
	var reason := _validate(body)
	if reason != "":
		rejected_count += 1
		last_reject_reason = reason
		rejected.emit(reason)
		return false
	var snap: Dictionary = body
	var ht: int = snap["ht"]
	if ht <= _newest:
		stale_count += 1
		return false
	_newest = ht
	_pl = (snap["pl"] as Dictionary).duplicate(true)
	_extra = (snap["x"] as Dictionary).duplicate(true) if snap.has("x") else {}

	var ids: PackedInt32Array = snap["ids"]
	var kinds: PackedInt32Array = snap["kinds"]
	var st: PackedFloat32Array = snap["st"]
	var present: Dictionary = {}
	var offset := 0
	for i in ids.size():
		var id: int = ids[i]
		var kind: int = kinds[i]
		var stride: int = (_kinds[kind] as Array).size()
		var state: PackedFloat32Array = st.slice(offset, offset + stride)
		offset += stride
		present[id] = true
		var lives: Array = _lives.get(id, [])
		var cur: Dictionary = {} if lives.is_empty() else lives[lives.size() - 1]
		if cur.is_empty() or cur["despawn"] != -1 or cur["kind"] != kind:
			if not cur.is_empty() and cur["despawn"] == -1:
				cur["despawn"] = ht
			lives.append({"kind": kind, "spawn": ht, "despawn": -1,
					"ticks": [ht], "states": [state],
					"spawn_fired": false, "despawn_fired": false})
			_lives[id] = lives
		else:
			cur["ticks"].append(ht)
			cur["states"].append(state)
			while cur["ticks"].size() > history_size:
				cur["ticks"].remove_at(0)
				cur["states"].remove_at(0)
	for id in _lives:
		if not present.has(id):
			var lives: Array = _lives[id]
			var cur: Dictionary = lives[lives.size() - 1]
			if cur["despawn"] == -1:
				cur["despawn"] = ht
	return true


## Client: host tick of the newest accepted snapshot, -1 before the first.
func newest_tick() -> int:
	return _newest


## Client: copy of the newest accepted snapshot's "x", {} when absent.
func extra() -> Dictionary:
	return _extra.duplicate(true)


## Client: this peer's section of the newest accepted snapshot ({} if none).
func peer_section(peer_id: String) -> Dictionary:
	if _newest < 0 or not _pl.has(peer_id):
		return {}
	var wire: Dictionary = _pl[peer_id]
	var out: Dictionary = {"ht": _newest, "ack": int(wire.get("ack", -1)),
			"ev": (wire["ev"] as Array).duplicate(true) if wire.has("ev") else []}
	for key in ["rt", "hm", "mg"]:
		if wire.has(key):
			out[key] = wire[key]
	return out


## Client: ids excluded from sample() and its signals.
func set_local(ids: Array) -> void:
	_local.clear()
	for id in ids:
		_local[int(id)] = true


## Client: interpolated state of every alive non-local entity at render time
## (milliticks). Fires spawn/despawn signals for ticks crossed since the last call.
func sample(render_milli: int) -> Dictionary:
	var r: int = render_milli
	if _has_render and r < _last_render:
		r = _last_render
	_fire_signals(r)
	var out: Dictionary = {}
	var gone: Array = []
	for id in _lives:
		var lives: Array = _lives[id]
		# Lives of one id never overlap in time, so at most one is alive at r.
		for i in range(lives.size() - 1, -1, -1):
			var life: Dictionary = lives[i]
			if r >= int(life["spawn"]) * 1000 and (life["despawn"] == -1 or r < int(life["despawn"]) * 1000):
				if not _local.has(id):
					out[id] = _value_at(life, r)
				break
		# Drop lives whose despawn signal has fired.
		while not lives.is_empty() and lives[0]["despawn_fired"]:
			lives.remove_at(0)
		if lives.is_empty():
			gone.append(id)
	for id in gone:
		_lives.erase(id)
	if _newest >= 0 and r > _newest * 1000:
		if r <= (_newest + extrapolate_cap_ticks) * 1000:
			extrapolated_frames += 1
		else:
			held_frames += 1
	_has_render = true
	_last_render = r
	return out


## Client: newest sample of an entity's current life, {} if none.
func latest(id: int) -> Dictionary:
	if not _lives.has(id):
		return {}
	var lives: Array = _lives[id]
	var life: Dictionary = lives[lives.size() - 1]
	var n: int = life["ticks"].size()
	return {"tick": life["ticks"][n - 1],
			"state": (life["states"][n - 1] as PackedFloat32Array).duplicate()}


## Client: the current life's sample at exactly `tick`, or empty.
func state_at(id: int, tick: int) -> PackedFloat32Array:
	if _lives.has(id):
		var lives: Array = _lives[id]
		var life: Dictionary = lives[lives.size() - 1]
		var i: int = (life["ticks"] as Array).find(tick)
		if i >= 0:
			return (life["states"][i] as PackedFloat32Array).duplicate()
	return PackedFloat32Array()


## New epoch: clear everything except the kind registry.
func reset() -> void:
	_entities.clear()
	_lives.clear()
	_pl = {}
	_extra = {}
	_local.clear()
	_newest = -1
	_has_render = false
	_last_render = 0
	stale_count = 0
	rejected_count = 0
	last_reject_reason = ""
	extrapolated_frames = 0
	held_frames = 0


func _compute_hash() -> int:
	var order: Array = _kinds.keys()
	order.sort()
	var h: int = _FNV_BASIS
	for kind in order:
		var channels: Array = _kinds[kind]
		var seq: Array = [kind, channels.size()]
		seq.append_array(channels)
		for v in seq:
			h = ((h ^ (int(v) & 0xFFFFFFFF)) * _FNV_PRIME) & 0xFFFFFFFF
	return h


## "" if the body is acceptable, else the rejection reason (contract order).
func _validate(body: Variant) -> String:
	if typeof(body) != TYPE_DICTIONARY:
		return "bad-shape"
	var d: Dictionary = body
	if typeof(d.get("ht")) != TYPE_INT or typeof(d.get("lh")) != TYPE_INT \
			or typeof(d.get("ids")) != TYPE_PACKED_INT32_ARRAY \
			or typeof(d.get("kinds")) != TYPE_PACKED_INT32_ARRAY \
			or typeof(d.get("st")) != TYPE_PACKED_FLOAT32_ARRAY \
			or typeof(d.get("pl")) != TYPE_DICTIONARY \
			or (d.has("x") and typeof(d["x"]) != TYPE_DICTIONARY):
		return "bad-shape"
	if int(d["lh"]) != _layout_hash:
		return "layout-mismatch"
	var ids: PackedInt32Array = d["ids"]
	var kinds: PackedInt32Array = d["kinds"]
	if ids.size() != kinds.size():
		return "size-mismatch"
	var total := 0
	for k in kinds:
		if not _kinds.has(k):
			return "unknown-kind"
		total += (_kinds[k] as Array).size()
	var seen: Dictionary = {}
	for id in ids:
		if seen.has(id):
			return "duplicate-id"
		seen[id] = true
	if (d["st"] as PackedFloat32Array).size() != total:
		return "bad-state-length"
	var pl: Dictionary = d["pl"]
	for peer in pl:
		if typeof(peer) != TYPE_STRING or typeof(pl[peer]) != TYPE_DICTIONARY:
			return "bad-peer-section"
		var section: Dictionary = pl[peer]
		for key in ["ack", "rt", "hm", "mg"]:
			if section.has(key) and typeof(section[key]) != TYPE_INT:
				return "bad-peer-section"
		if section.has("ev") and typeof(section["ev"]) != TYPE_ARRAY:
			return "bad-peer-section"
	return ""


## Fire each life's spawn / despawn once, on the first call where it is due
## (tick*1000 <= r). Local ids consume the flags silently. Order: ascending tick,
## despawn before spawn at an equal tick, then by id.
func _fire_signals(r: int) -> void:
	var events: Array = []  # [tick, 0 despawn | 1 spawn, id, kind]
	for id in _lives:
		var local: bool = _local.has(id)
		for life in _lives[id]:
			if not life["spawn_fired"] and int(life["spawn"]) * 1000 <= r:
				life["spawn_fired"] = true
				if not local:
					events.append([life["spawn"], 1, id, life["kind"]])
			if life["despawn"] != -1 and not life["despawn_fired"] \
					and int(life["despawn"]) * 1000 <= r:
				life["despawn_fired"] = true
				if not local:
					events.append([life["despawn"], 0, id, life["kind"]])
	if events.is_empty():
		return
	events.sort_custom(func(a: Array, b: Array) -> bool:
		if a[0] != b[0]:
			return a[0] < b[0]
		if a[1] != b[1]:
			return a[1] < b[1]
		return a[2] < b[2])
	for e in events:
		if e[1] == 1:
			entity_spawned.emit(e[2], e[3])
		else:
			entity_despawned.emit(e[2])


## Interpolate / extrapolate / hold one life at render time r (milliticks).
func _value_at(life: Dictionary, r: int) -> PackedFloat32Array:
	var ticks: Array = life["ticks"]
	var states: Array = life["states"]
	var n: int = ticks.size()
	var channels: Array = _kinds[life["kind"]]
	if n == 1 or r <= int(ticks[0]) * 1000:
		return (states[0] as PackedFloat32Array).duplicate()
	if r >= int(ticks[n - 1]) * 1000:
		var tn: int = ticks[n - 1]
		var tp: int = ticks[n - 2]
		var vn: PackedFloat32Array = states[n - 1]
		var vp: PackedFloat32Array = states[n - 2]
		var rc: int = mini(r, (tn + extrapolate_cap_ticks) * 1000)
		var k: float = float(rc - tn * 1000) / float((tn - tp) * 1000)
		var out := vn.duplicate()
		for c in channels.size():
			match channels[c]:
				LERP:
					out[c] = vn[c] + (vn[c] - vp[c]) * k
				ANGLE:
					out[c] = wrapf(vn[c] + wrapf(vn[c] - vp[c], -PI, PI) * k, -PI, PI)
		return out
	var i: int = n - 2
	while int(ticks[i]) * 1000 > r:
		i -= 1
	var a: int = ticks[i]
	var b: int = ticks[i + 1]
	var va: PackedFloat32Array = states[i]
	var vb: PackedFloat32Array = states[i + 1]
	var alpha: float = float(r - a * 1000) / float((b - a) * 1000)
	var res := va.duplicate()
	for c in channels.size():
		match channels[c]:
			LERP:
				res[c] = va[c] + (vb[c] - va[c]) * alpha
			ANGLE:
				res[c] = wrapf(va[c] + wrapf(vb[c] - va[c], -PI, PI) * alpha, -PI, PI)
			_:
				res[c] = va[c] if r < b * 1000 else vb[c]
	return res
