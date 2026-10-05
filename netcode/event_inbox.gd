## CLIENT-side exactly-once receiver for the events a CouchEventRing carries.
##
## CONTRACT. receive(events) takes the "ev" array of this peer's snapshot section
## and returns, as [id, kind, payload] in ascending id order, only the events with
## id > last_applied(), each at most once -- however snapshots duplicate, reorder
## or arrive stale, because every snapshot repeats all un-acked events. Duplicate
## ids inside one call apply once. last_applied() starts at 0 and is what the game
## sends back in its input body as "ev", which is the host's ack.
##
## Gaps never stall: if an id is not last_applied + 1, the host dropped events
## (expired or overflowed). The event is still returned, gap_count += 1 and
## lost_count += the number of ids skipped; waiting for them would block the
## stream forever. A non-Array argument returns [] and malformed_count += 1; an
## element that is not an Array of size 3 with int id >= 1 and int kind is
## skipped and counted the same way.
##
## reset() (new epoch) zeroes last_applied and the counters; the host's ring is
## reset at the same time so ids restart at 1.
class_name CouchEventInbox
extends RefCounted

## Gaps detected (events expired host-side).
var gap_count: int = 0
## Total event ids skipped across gaps.
var lost_count: int = 0
## Malformed events or event lists skipped.
var malformed_count: int = 0

var _last_applied: int = 0


## Newly applicable [id, kind, payload] events, ascending, each exactly once.
func receive(events: Variant) -> Array:
	var out: Array = []
	if typeof(events) != TYPE_ARRAY:
		malformed_count += 1
		return out
	var fresh: Dictionary = {}  # id -> event, unique ids above last_applied
	for e in events:
		if typeof(e) != TYPE_ARRAY or e.size() != 3 \
				or typeof(e[0]) != TYPE_INT or typeof(e[1]) != TYPE_INT or int(e[0]) < 1:
			malformed_count += 1
			continue
		var id: int = e[0]
		if id > _last_applied and not fresh.has(id):
			fresh[id] = [id, e[1], e[2]]
	var ids: Array = fresh.keys()
	ids.sort()
	for id in ids:
		if id != _last_applied + 1:
			gap_count += 1
			lost_count += id - _last_applied - 1
		out.append(fresh[id])
		_last_applied = id
	return out


## Highest applied id, 0 initially; goes in the input body as "ev".
func last_applied() -> int:
	return _last_applied


## New epoch: last_applied 0, counters 0.
func reset() -> void:
	_last_applied = 0
	gap_count = 0
	lost_count = 0
	malformed_count = 0
