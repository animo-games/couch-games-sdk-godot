## HOST-side per-peer impulse-event streams, carried in every snapshot until the
## peer acknowledges them. Pair with CouchEventInbox on the client.
##
## CONTRACT. push(peer, kind, payload, host_tick) appends an event and returns
## its id: monotone PER PEER, 1, 2, 3, ... within an epoch. pending_for(peer)
## returns the un-acked events as NEW [[id, kind, payload], ...] arrays in
## ascending id order (the payload itself is not deep-copied); the world packs
## it into that peer's snapshot section ("ev") every snapshot, so loss of any one
## snapshot is repaired by the next. ack(peer, n) -- n comes from the peer's input
## body ("ev" = CouchEventInbox.last_applied()) -- drops events with id <= n. An
## ack <= the peer's acked id is ignored (reordered inputs must not roll back); an
## ack beyond highest_id() is clamped to it and counted in over_ack_count().
##
## Loss is never silent. expire(host_tick) drops every pending event with
## host_tick - event_tick > max_age_ticks (expired_count). Exceeding max_pending
## drops the OLDEST (overflow_count). The inbox then sees the id gap and counts it.
##
## forget(peer) (player_left) drops the peer's pending events and counters but KEEPS
## its next id and acked id: a peer that returns within the epoch keeps receiving
## monotone ids, and a stale ack from its previous life is still ignored. If the ids
## restarted at 1, the returning client's inbox (last_applied > 0) would discard
## every new event as already applied. reset() (new epoch) forgets everything and
## ids restart at 1; the clients reset their inboxes too.
##
## Game wiring: on input from a peer, after dropping stale-epoch inputs,
## `ring.ack(peer, int(input_body.get("ev", 0)))`; per snapshot pass the ring to
## CouchReplicatedWorld.pack(), which calls expire() and fills each "ev".
class_name CouchEventRing
extends RefCounted

## Un-acked events older than this many host ticks are dropped and counted.
var max_age_ticks: int = 120
## Per-peer pending cap; overflow drops the oldest.
var max_pending: int = 64

## peer_id -> Array of [id, kind, payload, host_tick], ascending id
var _pending: Dictionary = {}
## peer_id -> highest id ever pushed this epoch (survives forget)
var _highest: Dictionary = {}
## peer_id -> highest acked id this epoch (survives forget)
var _acked: Dictionary = {}
var _expired: Dictionary = {}
var _overflow: Dictionary = {}
var _over_ack: Dictionary = {}


## Queue an event for one peer; returns its per-peer monotone id.
func push(peer_id: String, kind: int, payload: Variant, host_tick: int) -> int:
	var id: int = int(_highest.get(peer_id, 0)) + 1
	_highest[peer_id] = id
	if not _pending.has(peer_id):
		_pending[peer_id] = []
	var list: Array = _pending[peer_id]
	list.append([id, kind, payload, host_tick])
	while list.size() > max_pending:
		list.remove_at(0)
		_overflow[peer_id] = int(_overflow.get(peer_id, 0)) + 1
	return id


## Drop pending events older than max_age_ticks at host_tick.
func expire(host_tick: int) -> void:
	for peer_id in _pending:
		var list: Array = _pending[peer_id]
		# Ascending id implies ascending push tick, so expired events are a prefix.
		while not list.is_empty() and host_tick - int(list[0][3]) > max_age_ticks:
			list.remove_at(0)
			_expired[peer_id] = int(_expired.get(peer_id, 0)) + 1


## Copy of the peer's un-acked events, [[id, kind, payload], ...] ascending.
func pending_for(peer_id: String) -> Array:
	var out: Array = []
	for e in _pending.get(peer_id, []):
		out.append([e[0], e[1], e[2]])
	return out


## Peer reports it applied events up to last_applied.
func ack(peer_id: String, last_applied: int) -> void:
	if last_applied <= int(_acked.get(peer_id, 0)):
		return
	var n: int = last_applied
	var highest: int = int(_highest.get(peer_id, 0))
	if n > highest:
		n = highest
		_over_ack[peer_id] = int(_over_ack.get(peer_id, 0)) + 1
	_acked[peer_id] = n
	var list: Array = _pending.get(peer_id, [])
	while not list.is_empty() and int(list[0][0]) <= n:
		list.remove_at(0)


## Highest id pushed to the peer this epoch (kept across forget), 0 if none.
func highest_id(peer_id: String) -> int:
	return int(_highest.get(peer_id, 0))


## Events dropped for age.
func expired_count(peer_id: String) -> int:
	return int(_expired.get(peer_id, 0))


## Events dropped for exceeding max_pending.
func overflow_count(peer_id: String) -> int:
	return int(_overflow.get(peer_id, 0))


## Acks beyond the highest pushed id.
func over_ack_count(peer_id: String) -> int:
	return int(_over_ack.get(peer_id, 0))


## Drop a peer's pending events and counters, keeping its next id and acked id.
func forget(peer_id: String) -> void:
	_pending.erase(peer_id)
	_expired.erase(peer_id)
	_overflow.erase(peer_id)
	_over_ack.erase(peer_id)


## New epoch: forget everything, ids restart at 1.
func reset() -> void:
	_pending.clear()
	_highest.clear()
	_acked.clear()
	_expired.clear()
	_overflow.clear()
	_over_ack.clear()
