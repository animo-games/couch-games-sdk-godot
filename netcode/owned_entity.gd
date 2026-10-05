## OWNER-side helper: builds the owner-authority part of the input body each tick and
## decodes the library's impulse events. Pure data; no Nodes, no physics server.
##
## CONTRACT. input_fields(tick, state, inbox) returns {"t": tick, "o": COPY of state,
## "ev": inbox.last_applied()} ("ev" is 0 for a null inbox). A state whose size is not the
## kind's stride (or whose kind is unregistered) or that holds a non-finite value gives {}
## and refused_count += 1. impulse_of(event) takes an [id, kind, payload] event from
## CouchEventInbox.receive and returns {"j": Vector2, "a": float} iff kind ==
## IMPULSE_EVENT_KIND and payload is a finite PackedFloat32Array of size 3; else {}.
## Negative event kinds are reserved for the library; games use kinds >= 0.
##
## GAME WIRING. world.set_local([my_eid, ...]) so the owner's own entity is never
## interpolated over its real body. Per owner tick:
##   1. for e in inbox.receive(ps.ev): var imp = CouchOwnedEntity.impulse_of(e) and, if
##      not empty, body.apply_central_impulse(imp.j); body.apply_torque_impulse(imp.a)
##   2. step physics
##   3. input.merge(owned.input_fields(t, state_of(body), inbox))
## ALIGNMENT RULE: an input body's "o" is the owned state AFTER the owner has applied
## every event with id <= that same body's "ev". That is why input_fields() comes last:
## receive and apply events, step physics, THEN input_fields().
class_name CouchOwnedEntity
extends RefCounted

## Reserved event kind of CouchOwnerTargets.push_impulse; games use kinds >= 0.
const IMPULSE_EVENT_KIND := -1

## input_fields calls refused (wrong stride, unregistered kind, non-finite state).
var refused_count: int = 0

var _world: CouchReplicatedWorld
var _entity_id: int
var _kind: int


func _init(world: CouchReplicatedWorld, entity_id: int, kind: int) -> void:
	_world = world
	_entity_id = entity_id
	_kind = kind


## {"t": tick, "o": copy of state, "ev": inbox.last_applied()} or {} when refused.
func input_fields(tick: int, state: PackedFloat32Array, inbox: CouchEventInbox) -> Dictionary:
	# kind_channels() is [] for an unregistered kind (registered kinds are never empty).
	var stride: int = _world.kind_channels(_kind).size()
	if stride == 0 or state.size() != stride or not _all_finite(state):
		refused_count += 1
		return {}
	return {
		"t": tick,
		"o": state.duplicate(),
		"ev": inbox.last_applied() if inbox != null else 0,
	}


## {"j": Vector2, "a": float} for an impulse event [id, kind, payload], else {}.
static func impulse_of(event: Variant) -> Dictionary:
	if typeof(event) != TYPE_ARRAY or (event as Array).size() != 3:
		return {}
	var e: Array = event
	if typeof(e[1]) != TYPE_INT or e[1] != IMPULSE_EVENT_KIND:
		return {}
	if typeof(e[2]) != TYPE_PACKED_FLOAT32_ARRAY:
		return {}
	var p: PackedFloat32Array = e[2]
	if p.size() != 3 or not _all_finite(p):
		return {}
	return {"j": Vector2(p[0], p[1]), "a": p[2]}


static func _all_finite(values: PackedFloat32Array) -> bool:
	for v in values:
		if not is_finite(v):
			return false
	return true
