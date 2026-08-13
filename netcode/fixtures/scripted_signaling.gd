## Two-sided fake signaling adapter, used ONLY by netcode/fixtures/run_star_link.gd.
## It exists so that test can put a REAL CouchStarTransport, with REAL
## WebRTCPeerConnections, on a real establishment path in ONE process -- testing
## the star against a fake transport would prove nothing about the star.
##
## Presents exactly the duck contract CouchStarTransport requires:
##   connect_room() -> Dictionary, send(target, data) -> void, close() -> void
##   sig_received / peer_joined / peer_left
##
## Three real behaviours are reproduced deliberately:
##   - connect_room() is a genuine COROUTINE that costs one real frame. Every real
##     signaling connect crosses a socket, and a transport that only worked when
##     connect_room() resolved synchronously would pass here and fail in the field
##     -- it is also the exact window CouchStarTransport's _lifecycle_seq and
##     _pending_peer_ids exist to survive.
##   - presence is announced DEFERRED and symmetrically: the newcomer learns about
##     the incumbent ("peer-exists") and the incumbent learns about the newcomer
##     ("peer-joined"), both as peer_joined, matching local_backend.gd:216-224 and
##     the adapter's documented collapsing of the two. Whichever side's
##     connect_room() resolves SECOND is the one that fires both directions --
##     that makes both join orders (host-first and guest-first) reach the same
##     state, exactly as couch_signaling_adapter.gd's contract requires.
##   - every blob crosses a REAL JSON round trip
##     (JSON.parse_string(JSON.stringify(data))), because every real backend does.
##     That is what turns `gen` and `index` into floats on the way across -- the
##     exact class of bug the int() coercions exist to survive, and a double that
##     skipped it would hide that class rather than exercise it.
##
## Not a general N-party room: link() cross-wires exactly two instances. send()
## only reaches the linked partner; any other target is an unknown recipient and
## is dropped silently, matching the adapter's documented best-effort contract
## (couch_signaling_adapter.gd:58-60).
##
## No class from outside netcode/ is referenced here.
##
## TEST-ONLY control surface (netcode/fixtures/run_star_faults.gd, gate G11):
## none of the members below this notice is reachable from a game --
## CouchStarTransport only ever calls connect_room()/send()/close() and
## listens for sig_received/peer_joined/peer_left, same as production.
##   - hold_kind / held / release_held(): queue blobs of one `kind` instead
##     of delivering them, so a test can force an ordering (e.g. ICE before
##     SDP) that loopback speed would otherwise make unreachable.
##   - drop_all: swallow every send(), for connect-timeout/rebuild cases.
##   - duplicate_sends: deliver every send() twice, for retransmit-guard
##     cases.
##   - captured / replay(): every blob this side has sent, after the JSON
##     round trip, so a test can hand a peer's OWN earlier blob back to it
##     later, byte-for-byte, to simulate a delayed or stale delivery.
##   - announce_left(): peer_left sibling of the existing announce().
##   - close_count / connect_room_count: call counters for concurrency tests
##     (concurrent start(), close() racing a suspended start()).
##   - is_joined(): whether this side currently considers itself joined to the
##     room. Exists so a test (run_star_faults.gd's F10) can assert on the
##     TRANSPORT's own cleanup rather than on this fake refusing to join in the
##     first place -- see connect_room()'s docstring.
class_name CouchScriptedSignaling
extends RefCounted

## A handshake blob from the linked partner, after a JSON round-trip.
signal sig_received(peer_id: String, data: Variant)
## A peer is present in the room (already there or just joined) -- see the
## "deferred and symmetrical" note above.
signal peer_joined(peer_id: String)
## A peer left the room.
signal peer_left(peer_id: String)

var peer_id: String = ""
var ice_servers: Array = []

## TEST-ONLY. When non-empty, send() queues blobs whose "kind" matches this
## string into `held` instead of delivering them. See release_held().
var hold_kind: String = ""
## TEST-ONLY. Blobs queued by `hold_kind`, in the order send() queued them.
var held: Array = []
## TEST-ONLY. When true, send() swallows every blob (still captured).
var drop_all: bool = false
## TEST-ONLY. When true, every delivered send() reaches sig_received twice.
var duplicate_sends: bool = false
## TEST-ONLY. Every blob passed to send(), after the JSON round trip, in
## order -- independent of hold_kind/drop_all/duplicate_sends, so a test can
## capture a blob under normal conditions and replay() it later under fault
## conditions.
var captured: Array = []
## TEST-ONLY. Incremented once per close() call.
var close_count: int = 0
## TEST-ONLY. Incremented once per connect_room() call, before its await.
var connect_room_count: int = 0

var _other: CouchScriptedSignaling = null
var _joined: bool = false


func _init(p_peer_id: String, p_ice_servers: Array = []) -> void:
	peer_id = p_peer_id
	ice_servers = p_ice_servers


## Cross-wire two signaling doubles so each one's connect_room()/send() reaches
## the other's peer_joined/peer_left/sig_received.
static func link(a: CouchScriptedSignaling, b: CouchScriptedSignaling) -> void:
	a._other = b
	b._other = a


## Join the room. See the file header for why this costs one real frame and why
## presence fires both ways from whichever side resolves second.
##
## The pending join ALWAYS completes, even when close() lands on THIS side
## while the call is suspended at the `await` below (Codex finding 6). A real
## signaling backend has no way to know a purely LOCAL close() call happened
## mid-request -- the join lands regardless -- and a fake that suppressed it
## made the transport's OWN cleanup (CouchStarTransport._abort_start) untestable:
## a superseded start() never had a real membership to release, so F10 passed
## even with that cleanup deleted outright. It is the TRANSPORT's job to notice
## a start() was superseded and release what connect_room() went on to join
## anyway, and F10 (run_star_faults.gd) now asserts exactly that: two close()
## calls (the star's own, plus _abort_start's) leaving this fake unjoined.
func connect_room() -> Dictionary:
	connect_room_count += 1
	await (Engine.get_main_loop() as SceneTree).process_frame
	_joined = true
	if _other != null and _other._joined:
		_other.peer_joined.emit.call_deferred(peer_id)
		peer_joined.emit.call_deferred(_other.peer_id)
	return {
		"success": true,
		"peer_id": peer_id,
		"room_id": "scripted-room",
		"ice_servers": ice_servers.duplicate(true),
	}


## TEST-ONLY. Whether this side currently considers itself joined to the room.
func is_joined() -> bool:
	return _joined


## Best-effort by contract: an unknown or not-yet-joined target is dropped
## silently, exactly like the real adapter's documented behaviour, so a caller
## must drive retries off connection state, not this channel.
func send(target_peer_id: String, data: Variant) -> void:
	# Real JSON round trip -- every real backend does this on the wire. It is
	# what turns `gen` and `index` into floats on the way across, exactly the
	# class of bug the int() coercions in star_transport.gd exist to survive.
	# Captured unconditionally, before any TEST-ONLY fault is applied, so a
	# blob captured under normal conditions can be replay()ed later verbatim.
	var wire: Variant = JSON.parse_string(JSON.stringify(data))
	captured.append(wire)
	if drop_all:
		return
	if _other == null or not _other._joined or target_peer_id != _other.peer_id:
		return
	if hold_kind != "" and wire is Dictionary and str((wire as Dictionary).get("kind", "")) == hold_kind:
		held.append(wire)
		return
	_other.sig_received.emit(peer_id, wire)
	if duplicate_sends:
		_other.sig_received.emit(peer_id, wire)


## TEST-ONLY. Deliver everything `hold_kind` queued, in the order send()
## queued it, then clear the queue.
func release_held() -> void:
	var to_release := held.duplicate()
	held.clear()
	if _other == null:
		return
	for wire in to_release:
		_other.sig_received.emit(peer_id, wire)


## TEST-ONLY. Deliver `blob` to THIS side's sig_received directly, as if it
## had just arrived from `from_peer_id` -- no JSON round trip, so a blob
## pulled from `captured` (or another side's) replays byte-for-byte. This is
## how a delayed or stale generation envelope is simulated.
func replay(blob: Variant, from_peer_id: String) -> void:
	sig_received.emit(from_peer_id, blob)


func close() -> void:
	close_count += 1
	_joined = false
	if _other != null:
		_other.peer_left.emit.call_deferred(peer_id)


## TEST-ONLY. Exists solely so netcode/fixtures/run_star_link.gd can reach the
## net-id collision branch: it simulates a THIRD peer id announcing presence in
## THIS side's signaling room, with no partnered CouchScriptedSignaling instance
## required for that id. The collision test never needs that peer to actually
## connect -- only to be discovered and mapped, which is what makes the
## collision reachable.
func announce(announced_peer_id: String) -> void:
	peer_joined.emit.call_deferred(announced_peer_id)


## TEST-ONLY. Sibling of announce(): simulates signaling reporting that
## `pid` left THIS side's room, with no partnered CouchScriptedSignaling
## instance required. Used to drive the rejoin (peer_left -> peer_joined)
## path deliberately, e.g. while the engine-level link is still up.
func announce_left(pid: String) -> void:
	peer_left.emit.call_deferred(pid)
