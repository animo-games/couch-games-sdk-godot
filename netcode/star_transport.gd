## WebRTC-star implementation of CouchTransport: the host is the authority AND the
## hub. The host runs create_server(), every guest runs create_client(), and each
## guest holds exactly ONE connection -- to the host. There is no guest<->guest
## edge and the host does not relay: this is a star, not a mesh.
##
## Wire. Every envelope is one CouchEnvelope.to_bytes() datagram put on the peer
## with put_packet(). SceneMultiplayer and the high-level RPC API are bypassed
## entirely and `multiplayer.multiplayer_peer` is NEVER assigned -- doing so would
## hand every packet to SceneMultiplayer, which would read our envelopes as RPC
## frames. (WebRTCMultiplayerPeer.is_server_relay_supported() is true, but only
## the high-level API consults it; that relay is exactly what we are not using,
## and it is why broadcast() from a guest reaches only the host.)
##
## Lanes. The lane is derived from the envelope's `kind` -- see lane_for_kind().
## The table lives HERE and not in envelope.gd, which is transport-agnostic and
## must stay so. Lanes are independent SCTP streams and carry NO cross-lane
## ordering guarantee: a reliable `hello` sent after an unreliable `snapshot` can
## and does arrive first (measured on 4.7 headless). Nothing above depends on
## cross-lane order, and that is not luck. Each kind maps to exactly ONE lane, and
## CouchEnvelope's `seq` is per-(sender, kind), so cross-lane reordering can never
## manufacture a within-kind gap. The one visible consequence -- a guest seeing a
## new epoch's snapshot before that epoch's hello -- is a case couch_session.gd's
## header already names and already self-heals ("a guest can learn a new epoch
## from ANY accepted kind, not only hello").
##
## Identity. CouchTransport addresses peers by PLATFORM USER ID (a String); Godot
## addresses them by int net id and requires the server to be 1. The map is
## derived, never negotiated: the host is HOST_NET_ID, every guest is
## derive_net_id(user_id). That function is duo's, byte for byte -- see its own
## docstring. No identify handshake exists here because none is needed: both sides
## can compute both ids from strings they already hold.
##
## `sender_peer_id` on envelope_received is stamped by the LINK and never read out
## of the envelope, exactly as the contract requires. On this link that is
## structural: get_packet_peer() returns the net id WE bound to that connection in
## add_peer(), so a guest cannot assert any identity at all. It is the star's
## counterpart to local_backend.gd:214's "senderUserId is stamped from the
## connection".
##
## Dependencies are duck-typed, and this file must parse in a project that
## installs neither `lobby/` nor `webrtc/` (the rule netcode/transport.gd states
## and webrtc/couch_signaling_adapter.gd documents). WebRTCPeerConnection and
## WebRTCMultiplayerPeer ARE named directly and that is safe: both are CORE engine
## classes, present in stock 4.4 / 4.5 / 4.7 with no `webrtc_native` installed.
## What the GDExtension supplies is only the concrete IMPLEMENTATION -- see
## is_webrtc_available().
##   Required signaling surface (CouchRollbackSignalingAdapter satisfies it as
##   shipped; nothing here may name that class, which duo also depends on):
##     connect_room() -> Dictionary {success, error?, peer_id?, room_id?, ice_servers?}
##     send(target_peer_id: String, data: Variant) -> void   (BEST EFFORT by contract)
##     close() -> void
##     sig_received(peer_id: String, data: Variant)
##     peer_joined(peer_id: String)   -- "already here" and "just arrived" BOTH
##     peer_left(peer_id: String)
##   Required lobby surface:
##     is_host() -> bool, get_host() -> Variant, get_me() -> Variant
##
## `peer_exists` and `peer_joined` both surface as `peer_joined` on the adapter,
## by design, because a peer already in the room and one that joins later both
## mean "build a connection". Discovery here is idempotent for exactly that
## reason, and both join orders are exercised by the two-process gate.
##
## RefCounted, not Node, like CouchLobbyTransport and CouchSession -- nothing here
## needs the tree, and a fixture can construct it directly. The cost is that
## WebRTCMultiplayerPeer must be polled every frame and nothing here can do that
## on its own, so this class adds `poll(now_ms)`. That is contract-legal:
## CouchTransport.REQUIRED_METHODS lists only what an implementation MUST have
## (netcode/transport.gd:37-50), and missing_methods() checks presence, never
## absence. Every deadline in this file is arithmetic on the `now_ms` the caller
## supplies; this file never reads a clock, so a fixture owns time completely.
##
## The driver MUST call poll(now_ms) before session.poll(now_ms), so a frame's
## arrivals are dispatched before the session's timers advance over them.
##
## `_is_host` is latched at start() and never re-read. CouchLobbyTransport reads
## is_host() live because its link is role-agnostic; a star's is not --
## create_server() vs create_client() and the "host offers" rule are chosen once,
## at construction. A role change means a NEW transport, exactly as a transport
## change does. There is no mid-session switching anywhere in v1.
##
## v1 limitations, decided and stated rather than hidden:
##   - A link that came UP and then died is not rebuilt. peer_lost fires and that
##     is all. The rebuild path is armed only by the connect timeout (a link that
##     never came up) and by a signaling peer_left/peer_joined pair. Automatic
##     re-establishment needs a backoff policy to avoid a rebuild storm, and that
##     is design surface Phase 1 did not sanction. Phase 2 adds it in
##     _on_engine_peer_disconnected.
##   - There is no star->lobby fallback SWITCHING. Selecting a transport is the
##     caller's job and happens once.
##   - A roster player with no signaling presence (an overlay-faked guest) is
##     never discovered and never connected. The star carries traffic only between
##     peers that are really in the signaling room.
##   - Handshake generations are classified three ways (PROCESS / DROP_STALE /
##     ADOPT -- see classify_generation) rather than "!= adopts": a delayed
##     older packet must never rebuild a live connection backward, on pain of
##     wedging a guest permanently against a single reordered frame. A rejoin
##     (signaling peer_left -> peer_joined) is the only legal way a generation
##     goes down, and it is guarded by an explicit incarnation barrier
##     (_awaiting_rejoin_gen0) so a stale higher-generation packet cannot get
##     ADOPTed across the rejoin and re-wedge the guest in mirror image. A host
##     restart that signaling does not report as peer_left/peer_joined heals
##     only when the dead link finally dies -- loud (stale_generation_drops) and
##     diagnosable, not silent.
##   - The guest now arms its OWN connect deadline (GUEST_CONNECT_TIMEOUT_MS,
##     deliberately longer than the host's whole retry budget) instead of
##     waiting forever: it never rebuilds unilaterally -- only the host mints
##     generations -- so a guest timeout is always terminal, reported loudly.
##   - Peer count is capped (MAX_PEERS -- a couch lobby is <= 8) so a hostile or
##     misbehaving signaling server cannot make the host allocate unlimited
##     WebRTCPeerConnections.
##   - A peer whose frames repeatedly fail to decode is muted for
##     MUTE_DURATION_MS after MAX_DECODE_FAILURES consecutive rejects, because
##     bytes_to_var() writes an engine ERROR line this file cannot suppress
##     through the public API -- muting bounds the flood at the application
##     level instead. Any accepted frame resets the counter, so a merely lossy
##     peer is never muted.
class_name CouchStarTransport
extends RefCounted

# ============================================================================
# Constants
# ============================================================================

const REQUIRED_SIGNALING_METHODS := ["connect_room", "send", "close"]
const REQUIRED_SIGNALING_SIGNALS := ["sig_received", "peer_joined", "peer_left"]
const REQUIRED_LOBBY_METHODS := ["is_host", "get_host", "get_me"]

const HOST_NET_ID := 1
const NET_ID_MIN := 2
const NET_ID_MAX := 1073741825            # 2^30 + 1, the top of derive_net_id's fold

const SIGNAL_PROTOCOL_VERSION := 1        # the HANDSHAKE wire, distinct from CouchEnvelope's `v`
const SIGNAL_KIND_SDP := "sdp"
const SIGNAL_KIND_ICE := "ice"

const MAX_PENDING_ICE := 64               # a full trickle set is ~12; this bounds a pathological sender
const MAX_RECENTLY_LOST := 64             # same bound and same rationale as CouchLobbyTransport's
const MAX_UNMAPPED_LOGGED := 16           # flood control on "packet from an id we never bound"
const MAX_DEPARTED := 64                  # same bound and rationale as MAX_RECENTLY_LOST
const MAX_REJECT_KEYS := 32               # flood-control dedup keys; distinct malformed-frame shapes are few
const MAX_PENDING_ANNOUNCES := 32         # peer_joined announces buffered during start()'s connect_room() await
const MAX_PEERS := 16                     # a couch lobby is <= 8; bounds allocation from a hostile signaling server
const MAX_DEFERRED_PEERS := 16            # announcements held while the roster has not yet named a host

const MAX_SDP_CHARS := 16384              # generous for a real SDP; bounds a hostile signaling payload
const MAX_CANDIDATE_CHARS := 512          # a real ICE candidate line is well under 200 bytes
const MAX_MID_CHARS := 64                 # a real SCTP/media mid is a handful of characters

const MAX_DECODE_FAILURES := 32           # consecutive decode rejects (no accepted frame between) before a mute
const MUTE_DURATION_MS := 5000            # a transient protocol glitch heals on its own after this

const CONNECT_TIMEOUT_MS := 10000
## Deliberately LONGER than the host's whole retry budget (MAX_CONNECT_ATTEMPTS
## attempts of CONNECT_TIMEOUT_MS each), so the host's own rebuild always gets
## its chance before the guest gives up -- see _on_connect_timeout.
const GUEST_CONNECT_TIMEOUT_MS := 30000
const HOST_RESOLVE_TIMEOUT_MS := 10000    # how long a guest waits for the roster to name a host before failing loudly
const SDP_RETRANSMIT_INTERVAL_MS := 1000
const MAX_CONNECT_ATTEMPTS := 2           # the initial attempt plus exactly one rebuild
## == 1. The host mints at most generation 1 (_on_connect_timeout spends
## MAX_CONNECT_ATTEMPTS), so a guest can never legitimately see a higher one.
## Bounds a hostile or buggy signaling peer that would otherwise force
## unlimited WebRTCPeerConnection allocations.
const MAX_GEN := MAX_CONNECT_ATTEMPTS - 1

# ============================================================================
# Signals -- the four CouchTransport contract signals, verbatim (transport.gd:26-33)
# ============================================================================

signal envelope_received(envelope: Dictionary, sender_peer_id: String)
signal peer_ready(peer_id: String)
signal peer_lost(peer_id: String)
signal transport_gap(peer_id: String, reason: String)

# ============================================================================
# Read-only diagnostics -- same getter-backed shape as CouchLobbyTransport.fault_drops
# ============================================================================

var local_peer_id: String:
	get:
		return _local_peer_id

var local_net_id: int:
	get:
		return _local_net_id

var is_host: bool:
	get:
		return _is_host

var rejected_count: int:
	get:
		return _reject_count

var oversized_sends: int:
	get:
		return _oversized_sends

var net_id_collisions: int:
	get:
		return _net_id_collisions

var connect_failures: int:
	get:
		return _connect_failures

var handshake_restarts: int:
	get:
		return _handshake_restarts

var stale_generation_drops: int:
	get:
		return _stale_generation_drops

var ice_dropped: int:
	get:
		return _ice_dropped

var ice_rejected: int:
	get:
		return _ice_rejected

var decode_mutes: int:
	get:
		return _decode_mutes

var logged_reject_kinds: int:
	get:
		return _seen_reject_errors.size()

## Count of frames handed to put_packet, per TRANSFER MODE, as READ BACK FROM
## THE PEER after set_transfer_mode(). The lane is a property of the link and
## cannot be recovered from an envelope after the fact, so this is the only way
## anything above the transport can prove the lane TABLE is actually in force.
## Deliberately read via _mp.get_transfer_mode() rather than from
## lane_for_kind(kind) again: a mutation that forces one lane inside _send()
## changes this tally, which a second call to lane_for_kind() would not.
var send_lane_tally: Dictionary:
	get:
		return _send_lane_tally.duplicate()

# ============================================================================
# Statics
# ============================================================================

## Whether a concrete WebRTC implementation is installed.
##
## Without one, WebRTCPeerConnection.new() returns the abstract
## WebRTCPeerConnectionExtension stub, whose unoverridden virtuals return 0/OK --
## so initialize()'s return code cannot be trusted -- and calling
## create_data_channel() on it returns null AND writes engine ERROR lines.
## get_class() is the QUIET discriminator, and quiet matters: this runs on every
## boot of every game that installs the SDK, including ones that never go online.
##
## Written as a DENYLIST of the one known-bad name rather than an allowlist of
## known-good ones. The web platform's implementation class name has NOT been
## verified (no web export was run), and an unverified web build must come out
## AVAILABLE, not silently disabled.
static func is_webrtc_available() -> bool:
	return WebRTCPeerConnection.new().get_class() != "WebRTCPeerConnectionExtension"


## Deterministic platform-user-id -> Godot net id. FNV-1a 32-bit over the UTF-8
## BYTES, folded into [2, 2^30+1].
##
## This is duo's function, copied verbatim from
## rollback-godot's transport/rollback_transport.gd (derive_net_id). It is
## DUPLICATED, not shared: the rollback addon is a separate repo that cannot
## depend on this SDK, and this SDK ships in games that never install it. duo is
## the co-spec, and netcode/fixtures/net_id_vectors.gd is the conformance fixture
## that proves the two implementations agree -- that file is written so it can be
## dropped into duo's suite unchanged.
##
## The fold deliberately avoids 0 and 1. That is precisely what makes host = 1
## compose with it: the reserved server id can never be handed to a guest.
##
## It folds over to_utf8_buffer(), i.e. BYTES, not code points. A port that
## iterates characters agrees on every ASCII id and diverges on the first
## non-ASCII one, which is why the conformance vectors include a multi-byte id.
##
## 32 bits folded to 30 means collisions exist (~1 in 2^30 per pair, birthday-wise
## ~1 in 2^15 within a room). A collision is a LOUD failure here -- see
## _discover_peer -- never silent mis-addressing.
static func derive_net_id(peer_id: String) -> int:
	var h := 2166136261
	for b in peer_id.to_utf8_buffer():
		h = ((h ^ b) * 16777619) & 0xFFFFFFFF
	return (h & 0x3FFFFFFF) + 2


## The transfer lane for an envelope kind. THE table for decision 2(a), and it
## lives here rather than in envelope.gd because envelope.gd is transport-agnostic
## and a lane is a property of THIS link, not of the message.
##
##   hello    RELIABLE            -- the ready barrier; losing one costs a 500 ms retry
##   intent   RELIABLE            -- a discrete verb; nothing supersedes a lost one
##   input    UNRELIABLE          -- 30/s, latest-wins (CouchEnvelope.LATEST_WINS_KINDS)
##   snapshot UNRELIABLE_ORDERED  -- latest-wins, but a STALE one must never overwrite a newer
##   resync-* RELIABLE            -- reserved kinds; a control message is reliable by default
##
## An unrecognised kind gets RELIABLE. It cannot be classified as loss-tolerant,
## the receiver's codec will reject it anyway (from_bytes -> "unknown-kind"), and
## reliable is the conservative choice. Written as a match, not a const Dictionary:
## a const initialiser naming constants of two other classes is the kind of thing
## that parses on one Godot version and not another, and neither repo has a
## precedent for it.
static func lane_for_kind(kind: String) -> int:
	match kind:
		CouchEnvelope.KIND_INPUT:
			return MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
		CouchEnvelope.KIND_SNAPSHOT:
			return MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
		_:
			return MultiplayerPeer.TRANSFER_MODE_RELIABLE


enum GenAction {
	PROCESS,     ## Same generation -- the envelope belongs to our connection.
	DROP_STALE,  ## Older generation -- from a connection we already discarded.
	ADOPT,       ## Newer generation -- the peer restarted; follow it.
}

## Decide what to do with a handshake envelope tagged `incoming_gen` when our own
## connection for that peer sits at `local_gen`. Pure, static, and unit-tested
## directly (G7) -- the whole of Codex finding 1 lives in these three lines.
static func classify_generation(local_gen: int, incoming_gen: int) -> GenAction:
	if incoming_gen < local_gen:
		return GenAction.DROP_STALE
	if incoming_gen > local_gen:
		return GenAction.ADOPT
	return GenAction.PROCESS

# ============================================================================
# Internal state
# ============================================================================

var _signaling: Object
var _lobby: Object
var _closed: bool = false
var _started: bool = false
var _starting: bool = false                # true only while a start() coroutine is in flight
var _lifecycle_seq: int = 0
var _now_ms: int = 0                       # cached from the last poll(); this file never reads a clock

var _mp: WebRTCMultiplayerPeer = null
var _is_host: bool = false
var _host_peer_id: String = ""
var _local_peer_id: String = ""
var _local_net_id: int = 0
var _ice_servers: Array = []

var _pcs: Dictionary = {}                  # peer_id -> WebRTCPeerConnection
var _peer_to_net: Dictionary = {}          # peer_id -> int
var _net_to_peer: Dictionary = {}          # int -> peer_id
var _connected: Dictionary = {}            # peer_id -> true, engine-level link is UP
var _gens: Dictionary = {}                 # peer_id -> int, handshake generation (wire-visible)
var _pc_epochs: Dictionary = {}            # peer_id -> int, identity of the live connection; never reused
var _epoch_seq: int = 0
var _remote_desc_set: Dictionary = {}      # peer_id -> true
var _pending_ice: Dictionary = {}          # peer_id -> Array[Dictionary], bounded by MAX_PENDING_ICE
var _departed: Dictionary = {}             # peer_id -> true, left signaling; only peer_joined re-authorises
var _attempts: Dictionary = {}             # peer_id -> int, connect attempts since discovery
var _connect_deadlines: Dictionary = {}    # peer_id -> int ms, -1 == "arm on the next poll"
var _sdp_retx: Dictionary = {}             # peer_id -> {gen, epoch, sdp_type, sdp, next_ms}
var _pending_peer_ids: Array = []          # announces during connect_room()'s await, bounded by MAX_PENDING_ANNOUNCES
var _recently_lost: Dictionary = {}        # bounded by MAX_RECENTLY_LOST
var _seen_reject_errors: Dictionary = {}   # flood control, verbatim from CouchLobbyTransport, bounded by MAX_REJECT_KEYS
var _seen_unmapped: Dictionary = {}
## peer_id -> true. Incarnation barrier: only a generation-0 envelope may clear
## it, see classify_generation's docs and _on_sig_received.
var _awaiting_rejoin_gen0: Dictionary = {}
var _deferred_peer_ids: Dictionary = {}    # peer_id -> true, held while the roster names no host, bounded by MAX_DEFERRED_PEERS
var _host_resolve_deadline: int = 0        # 0 = disarmed, -1 = arm on next poll(), >0 = absolute ms
var _decode_failures: Dictionary = {}      # peer_id -> int, consecutive rejects with no accepted frame between
var _muted_until: Dictionary = {}          # peer_id -> int ms, packets dropped undecoded while now_ms < this
var _send_lane_tally: Dictionary = {}      # MultiplayerPeer.TRANSFER_MODE_* -> int, sender-side lane witness
var _reject_count: int = 0
var _oversized_sends: int = 0
var _net_id_collisions: int = 0
var _connect_failures: int = 0
var _handshake_restarts: int = 0
var _stale_generation_drops: int = 0
var _ice_dropped: int = 0
var _ice_rejected: int = 0
var _decode_mutes: int = 0
var _logged_ice_sample: bool = false       # true once one full add_ice_candidate rejection has been logged

# ============================================================================
# Construction / duck typing
# ============================================================================


## Stores both dependencies and validates the duck contract immediately, so a
## misconfigured caller sees the error at construction time rather than at the
## first start() call. start() re-checks independently (see there for why): a
## constructor has no way to hand back a Dictionary result, and start() is the
## point where a caller actually needs to react to a bad dependency.
func _init(signaling: Object, lobby: Object) -> void:
	_signaling = signaling
	_lobby = lobby
	if not _implements_signaling(signaling):
		push_error("CouchStarTransport: signaling does not satisfy the required duck contract")
	if not _implements_lobby(lobby):
		push_error("CouchStarTransport: lobby does not satisfy the required duck contract")


static func _implements_signaling(candidate: Object) -> bool:
	if candidate == null:
		return false
	for method_name in REQUIRED_SIGNALING_METHODS:
		if not candidate.has_method(method_name):
			return false
	for signal_name in REQUIRED_SIGNALING_SIGNALS:
		if not candidate.has_signal(signal_name):
			return false
	return true


static func _implements_lobby(candidate: Object) -> bool:
	if candidate == null:
		return false
	for method_name in REQUIRED_LOBBY_METHODS:
		if not candidate.has_method(method_name):
			return false
	return true

# ============================================================================
# Lifecycle
# ============================================================================


## Join signaling, decide the local net id, stand up the WebRTCMultiplayerPeer
## in the role latched here, and (guest only) start connecting to the host.
## Async -- await the result. {"success": bool, "error": String}.
func start() -> Dictionary:
	if _closed:
		return {"success": false, "error": "closed"}
	if _started or _starting:
		return {"success": false, "error": "already-started"}
	if not _implements_signaling(_signaling):
		push_error("CouchStarTransport: signaling does not satisfy the required duck contract")
		return {"success": false, "error": "invalid-signaling"}
	if not _implements_lobby(_lobby):
		push_error("CouchStarTransport: lobby does not satisfy the required duck contract")
		return {"success": false, "error": "invalid-lobby"}

	_starting = true

	# Guards a start() coroutine outliving a close() (or another start()) that
	# supersedes it: captured before connect_room()'s await and re-checked
	# after. close() during the await is reachable (the game's initialize()
	# awaits start()).
	_lifecycle_seq += 1
	var token := _lifecycle_seq
	_attach_signaling()

	var res: Dictionary = await _signaling.connect_room()

	if token != _lifecycle_seq:
		_abort_start(bool(res.get("success", false)))
		return {"success": false, "error": "superseded"}

	if not bool(res.get("success", false)):
		var reason := str(res.get("error", "connect_room failed"))
		push_error("CouchStarTransport: signaling connect failed: %s" % reason)
		_abort_start(false)
		return {"success": false, "error": reason}

	_local_peer_id = str(res.get("peer_id", ""))
	if _local_peer_id.is_empty():
		push_error("CouchStarTransport: connect_room returned no peer id")
		_abort_start(true)
		return {"success": false, "error": "no-peer-id"}

	# INVARIANT: a signaling peer id IS a lobby user id -- that equivalence is
	# the whole addressing scheme (see the header's "Identity" section). This is
	# FATAL, not merely logged: if it is false, every derived net id is wrong and
	# BOTH roles wedge while start() reports success. An empty me_id is the same
	# defect wearing a different hat -- it also means is_host() is unreliable,
	# and a host whose roster had not settled would latch _is_host == false and
	# run create_client() (Codex finding 2's unreported sibling; finding 9).
	var me_id := _field_string(_lobby.get_me(), "user_id")
	if me_id.is_empty() or me_id != _local_peer_id:
		push_error("CouchStarTransport: peer-id-mismatch (signaling=%s lobby=%s)" % [_local_peer_id, me_id])
		_abort_start(true)
		return {"success": false, "error": "peer-id-mismatch"}

	_is_host = bool(_lobby.is_host())
	_host_peer_id = _local_peer_id if _is_host else _field_string(_lobby.get_host(), "user_id")

	var servers: Variant = res.get("ice_servers", [])
	_ice_servers = (servers as Array).duplicate(true) if servers is Array else []

	_mp = WebRTCMultiplayerPeer.new()
	var err: int
	if _is_host:
		_local_net_id = HOST_NET_ID
		err = _mp.create_server()
	else:
		_local_net_id = derive_net_id(_local_peer_id)
		err = _mp.create_client(_local_net_id)
	if err != OK:
		push_error("CouchStarTransport: WebRTCMultiplayerPeer setup failed (err=%d)" % err)
		_mp = null
		_abort_start(true)
		return {"success": false, "error": "peer-setup-failed"}

	_mp.peer_connected.connect(_on_engine_peer_connected)
	_mp.peer_disconnected.connect(_on_engine_peer_disconnected)

	# DO NOT assign multiplayer.multiplayer_peer -- see the header's "Wire"
	# section. This transport only ever talks to _mp directly.

	_starting = false
	_started = true

	# Drain peer announces buffered during connect_room()'s await -- the
	# signaling server can announce presence immediately on (re)connect, so
	# peer_joined can fire mid-await.
	var pending := _pending_peer_ids.duplicate()
	_pending_peer_ids.clear()
	for pid in pending:
		_discover_peer(pid as String)

	if not _is_host:
		# The roster already names the host, and the guest never offers, so a
		# PC built before the signaling announce costs nothing and saves a
		# full retry cycle. The host does NOT pre-discover from the roster: a
		# lobby player with no signaling presence would burn a connect
		# timeout for nothing.
		_discover_peer(_host_peer_id)

	return {"success": true, "error": ""}


## Abandon a start() that will not complete. Detaches the callbacks THIS call
## attached and releases the signaling membership it may have established.
## `joined` says whether connect_room() actually returned success: a membership
## that was never established must not be closed.
##
## Detaching is safe even on the superseded path. `_starting` makes a concurrent
## start() impossible, so the only thing that can bump _lifecycle_seq mid-await
## is close() -- after which the transport is terminal and start() returns
## "closed". There is therefore no "newer call" whose callbacks this could steal;
## that was Codex finding 3's second defect and this is why it no longer exists.
func _abort_start(joined: bool) -> void:
	_starting = false
	_detach_signaling()
	if joined and _signaling != null:
		_signaling.close()


## Poll the underlying WebRTCMultiplayerPeer, dispatch arrived packets, and
## advance every deadline this file owns. Deadlines are stored as -1 meaning
## "unarmed": the first poll() to see one arms it (now_ms + INTERVAL) rather
## than comparing immediately, because a deadline created inside start() --
## before any poll() has run -- has no now_ms to add to yet, and treating an
## unarmed deadline as 0 would fire a spurious timeout on frame one.
func poll(now_ms: int) -> void:
	_now_ms = now_ms
	if _closed or _mp == null:
		return
	_mp.poll()
	# get_packet_peer() PEEKS the sender of the next packet; get_packet() pops
	# it. The order is load-bearing and the reverse silently mis-attributes
	# every frame.
	while _mp.get_available_packet_count() > 0:
		var from_net := _mp.get_packet_peer()
		var bytes := _mp.get_packet()
		_receive(from_net, bytes)

	# Retry resolving the host's platform user id for any announcement that
	# arrived before the roster named a host (Codex finding 2). Holding rather
	# than refusing is what makes a late-settling roster non-fatal; the
	# deadline below is what makes a roster that NEVER settles loud instead of
	# an eternal silent wait.
	if not _deferred_peer_ids.is_empty():
		if not _resolve_host_peer_id().is_empty():
			var deferred := _deferred_peer_ids.keys()
			_deferred_peer_ids.clear()
			_host_resolve_deadline = 0
			for pid in deferred:
				_discover_peer(pid as String)
		else:
			if _host_resolve_deadline == -1:
				_host_resolve_deadline = now_ms + HOST_RESOLVE_TIMEOUT_MS
			elif _host_resolve_deadline > 0 and now_ms >= _host_resolve_deadline:
				# A guest that can never learn who the host is must FAIL, loudly and
				# once, not wait forever with nothing reported.
				_connect_failures += 1
				_host_resolve_deadline = 0
				push_error("CouchStarTransport: the roster never named a host; %d announcement(s) unclassifiable"
					% _deferred_peer_ids.size())
				for pid in _deferred_peer_ids.keys():
					transport_gap.emit(pid as String, "host-unresolved")
				_deferred_peer_ids.clear()

	# Both loops below iterate a DUPLICATED key list: a timeout can rebuild a
	# connection and a retransmit can be cancelled, and either mutates the map
	# being walked.
	for pid in _connect_deadlines.keys().duplicate():
		var deadline: int = int(_connect_deadlines[pid])
		if deadline == -1:
			deadline = now_ms + _connect_timeout_ms()
			_connect_deadlines[pid] = deadline
		if now_ms >= deadline:
			_on_connect_timeout(pid as String)

	for pid in _sdp_retx.keys().duplicate():
		var entry: Variant = _sdp_retx.get(pid)
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry
		var next_ms: int = int(e.get("next_ms", -1))
		if next_ms == -1:
			next_ms = now_ms + SDP_RETRANSMIT_INTERVAL_MS
			e["next_ms"] = next_ms
			_sdp_retx[pid] = e
		if now_ms >= next_ms:
			# Only fire if and only if this entry still describes the LIVE
			# connection at the generation it was recorded under, and that
			# connection is not already up -- otherwise the receipt (an
			# engine-level connection) already arrived, or a rebuild already
			# superseded this description.
			if int(_pc_epochs.get(pid, -1)) != int(e.get("epoch", -1)) \
					or int(_gens.get(pid, 0)) != int(e.get("gen", -1)) \
					or _connected.has(pid):
				_sdp_retx.erase(pid)
				continue
			_signaling.send(pid as String, {
				"v": SIGNAL_PROTOCOL_VERSION, "gen": int(e["gen"]), "kind": SIGNAL_KIND_SDP,
				"sdp_type": str(e["sdp_type"]), "sdp": str(e["sdp"]),
			})
			e["next_ms"] = now_ms + SDP_RETRANSMIT_INTERVAL_MS
			_sdp_retx[pid] = e


## Release the link. Idempotent. Individual WebRTCPeerConnections are not
## closed one by one here -- _mp.close() tears down every peer it holds, the
## same simplification duo's stop() makes (rollback_transport.gd:281-283);
## _rebuild_connection/_teardown_peer close a PC individually only because
## THOSE evict a single peer while the mesh itself stays alive.
func close() -> void:
	if _closed:
		return
	_closed = true
	_lifecycle_seq += 1
	_detach_signaling()

	if _mp != null:
		if _mp.peer_connected.is_connected(_on_engine_peer_connected):
			_mp.peer_connected.disconnect(_on_engine_peer_connected)
		if _mp.peer_disconnected.is_connected(_on_engine_peer_disconnected):
			_mp.peer_disconnected.disconnect(_on_engine_peer_disconnected)
		_mp.close()
		_mp = null

	if _signaling != null:
		_signaling.close()

	_pcs.clear()
	_peer_to_net.clear()
	_net_to_peer.clear()
	_connected.clear()
	_gens.clear()
	_pc_epochs.clear()
	_remote_desc_set.clear()
	_pending_ice.clear()
	_departed.clear()
	_attempts.clear()
	_connect_deadlines.clear()
	_sdp_retx.clear()
	_pending_peer_ids.clear()
	_recently_lost.clear()
	_awaiting_rejoin_gen0.clear()
	_deferred_peer_ids.clear()
	_host_resolve_deadline = 0
	_decode_failures.clear()
	_muted_until.clear()

# ============================================================================
# Public contract (CouchTransport)
# ============================================================================


## Contract (netcode/transport.gd): on the authority this is a no-op returning
## false -- the authority never talks to itself over the wire. The guard runs
## BEFORE any readiness check, so the contract holds on a fully-established star
## as well as an empty one.
func send_to_authority(envelope: Dictionary) -> bool:
	if _is_host:
		return false
	return _send(envelope, HOST_NET_ID)


## Deliver to exactly one peer, addressed by its platform user id. Unknown or
## not-yet-connected ids fail closed via _send's own mapped-and-connected check.
func send_to_peer(peer_id: String, envelope: Dictionary) -> bool:
	var net_id := net_id_for(peer_id)
	if net_id == 0:
		return false
	return _send(envelope, net_id)


## DOCUMENTED DIVERGENCE. On a guest this delivers to the AUTHORITY and returns
## what that send returned. The v1 star has NO guest->guest fan-out and the host
## does NOT re-fan a guest's frame: raw put_packet bypasses SceneMultiplayer,
## whose server-relay is the only thing that would have done it.
##
## No observable effect today. CouchSession calls broadcast() only from the host
## (couch_session.gd:653-655 -- `if _is_host: return _transport.broadcast(...)`);
## a guest always uses send_to_authority. This branch exists so a future caller
## gets delivery-to-the-authority rather than silence, and so the divergence is
## written down where a reader will actually find it.
func broadcast(envelope: Dictionary) -> bool:
	if not _is_host:
		return _send(envelope, HOST_NET_ID)
	# put_packet(TARGET_PEER_BROADCAST) on a server with ZERO connected peers
	# returns OK -- create_server() sets the peer CONNECTED immediately and the
	# broadcast loop simply has nothing to iterate. Returning true there would be
	# a false-positive "accepted for send" on the very method whose whole point is
	# that a send return is not a delivery receipt. Same defect class as
	# CouchLobbyTransport's send_to_authority guard, same fix.
	if _connected.is_empty():
		return false
	return _send(envelope, MultiplayerPeer.TARGET_PEER_BROADCAST)


func is_ready() -> bool:
	return not _closed and _mp != null and not _connected.is_empty()

# ============================================================================
# Diagnostics / lookup (not part of the CouchTransport contract, extra methods
# are contract-legal -- missing_methods() checks presence, never absence)
# ============================================================================


## The net id bound to `peer_id`, or 0 when unknown. Never a guess: only set by
## _discover_peer once a connection is actually being built for that peer.
func net_id_for(peer_id: String) -> int:
	return int(_peer_to_net.get(peer_id, 0))


## The platform user id bound to `net_id`, or "" when unknown.
func peer_id_for(net_id: int) -> String:
	return str(_net_to_peer.get(net_id, ""))


## Platform user ids with an engine-level connection UP right now.
func connected_peer_ids() -> Array:
	return _connected.keys()


## The handshake generation this transport currently holds for `peer_id`, or -1
## when the peer is unknown. Exposed for tests (G11) that must assert a stale
## packet did NOT move the live generation.
func generation_for(peer_id: String) -> int:
	return int(_gens.get(peer_id, -1))

# ============================================================================
# Peer discovery / connection establishment
# ============================================================================


## Resolve the host's platform user id, late-binding it from the lobby when
## start() ran before the roster had settled. A guest that latched "" would
## reject every later announcement (pid != _host_peer_id) with nothing to clear
## it -- Codex finding 2. refresh_players() is synchronous against a CACHE the
## web backend fills from an async callback, so an empty first read is a real
## path, not a theoretical one.
func _resolve_host_peer_id() -> String:
	if not _host_peer_id.is_empty():
		return _host_peer_id
	if _is_host:
		_host_peer_id = _local_peer_id
		return _host_peer_id
	var late := _field_string(_lobby.get_host(), "user_id")
	if not late.is_empty():
		_host_peer_id = late
	return _host_peer_id


## Adapter-authorized discovery of one peer. A guest calls this only for the
## host id (from the roster, in start(), and via _on_sig_received's "discover
## on any handshake envelope" rule); the host calls it for every signaling
## peer_joined. Idempotent by construction: an already-known peer id is a no-op.
func _discover_peer(pid: String) -> void:
	if not _started:
		# start()'s connect_room() await is still in flight -- buffer the
		# announce and drain it once _local_peer_id/_is_host are set. See the
		# drain site in start(). Bounded: a hostile signaling server announcing
		# faster than start() resolves must not grow this without limit.
		if not pid.is_empty() and not _pending_peer_ids.has(pid) and not _pcs.has(pid) \
				and _pending_peer_ids.size() < MAX_PENDING_ANNOUNCES:
			_pending_peer_ids.append(pid)
		return

	if pid.is_empty() or pid == _local_peer_id or _pcs.has(pid):
		return

	if not _is_host:
		var host_id := _resolve_host_peer_id()
		if host_id.is_empty():
			# Hold, do not refuse: refusing here is exactly what wedged a guest
			# whose star started before the roster named a host. poll() retries
			# via _resolve_host_peer_id() until HOST_RESOLVE_TIMEOUT_MS.
			if not _deferred_peer_ids.has(pid) and _deferred_peer_ids.size() < MAX_DEFERRED_PEERS:
				_deferred_peer_ids[pid] = true
				if _host_resolve_deadline == 0:
					_host_resolve_deadline = -1        # armed on the next poll()
			return
		if pid != host_id:
			# The guest never builds a connection to anyone but the host. Refusing
			# here -- not merely declining to offer -- is what makes this a star:
			# a guest that built a PC to another guest would be a mesh edge.
			return

	if _pcs.size() >= MAX_PEERS:
		# A couch lobby is <= 8; without this bound a hostile signaling server
		# makes the host allocate unlimited WebRTCPeerConnections.
		_reject("peer-limit", pid)
		transport_gap.emit(pid, "peer-limit")
		return

	var candidate_net_id: int = HOST_NET_ID if pid == _host_peer_id else derive_net_id(pid)
	if candidate_net_id == _local_net_id:
		_net_id_collisions += 1
		push_error("CouchStarTransport: net id collision between local peer and %s" % pid)
		transport_gap.emit(pid, "net-id-collision")
		return
	if _net_to_peer.has(candidate_net_id):
		_net_id_collisions += 1
		push_error("CouchStarTransport: net id collision between %s and %s" % [
			_net_to_peer[candidate_net_id], pid])
		transport_gap.emit(pid, "net-id-collision")
		return

	_peer_to_net[pid] = candidate_net_id
	_net_to_peer[candidate_net_id] = pid
	if _is_host:
		# Attempt budget is host-side only -- see MAX_CONNECT_ATTEMPTS and
		# _on_connect_timeout. The guest arms its own (longer) deadline instead
		# of rebuilding unilaterally -- see _arm_connect_deadline.
		_attempts[pid] = 0
	if not _build_connection(pid, 0):
		# Leaving these installed turns the NEXT announcement for this same peer
		# into a phantom net-id collision against itself, with no deadline to
		# clear it (Codex finding 4).
		_peer_to_net.erase(pid)
		_net_to_peer.erase(candidate_net_id)
		_attempts.erase(pid)


## Build a fresh WebRTCPeerConnection for `pid` at handshake generation `gen`
## and add it to the mesh under its bound net id. Returns whether it succeeded;
## on failure nothing is left behind -- see the add_peer() note below.
func _build_connection(pid: String, gen: int) -> bool:
	if _mp == null:
		push_error("CouchStarTransport: refusing to build a connection for %s with no WebRTCMultiplayerPeer" % pid)
		return false
	var net_id := int(_peer_to_net.get(pid, 0))
	if net_id == 0:
		push_error("CouchStarTransport: refusing to build a connection for %s with no bound net id" % pid)
		return false

	var pc := WebRTCPeerConnection.new()
	var init_cfg: Dictionary = {"iceServers": _ice_servers} if not _ice_servers.is_empty() else {}
	var err := pc.initialize(init_cfg)
	if err != OK:
		push_error("CouchStarTransport: WebRTCPeerConnection.initialize failed for %s (err=%d)" % [pid, err])
		transport_gap.emit(pid, "pc-init-failed")
		return false

	# The epoch is bound into the callbacks rather than read at emit time: a
	# closed connection can still deliver queued signals, and those must not
	# be published as if they belonged to its replacement.
	var epoch := _next_epoch()
	pc.session_description_created.connect(_on_sdp_created.bind(pid, gen, epoch))
	pc.ice_candidate_created.connect(_on_ice_created.bind(pid, gen, epoch))

	# add_peer() BEFORE any state is published: an Error here must leave nothing
	# behind. Ignoring it (iteration 1) left _pcs populated with no peer inside
	# _mp, and on a guest -- which armed no deadline at the time -- start() then
	# returned success and the transport waited forever (Codex finding 4).
	var add_err := _mp.add_peer(pc, net_id)
	if add_err != OK:
		push_error("CouchStarTransport: add_peer failed for %s (net_id=%d err=%d)" % [pid, net_id, add_err])
		pc.close()
		_connect_failures += 1
		transport_gap.emit(pid, "add-peer-failed")
		return false

	_gens[pid] = gen
	_pc_epochs[pid] = epoch
	_pcs[pid] = pc
	_remote_desc_set.erase(pid)
	_pending_ice.erase(pid)
	_arm_connect_deadline(pid)

	if _is_host:
		# The host always offers -- the guest never calls create_offer().
		# Setting a remote OFFER makes the engine emit
		# session_description_created("answer", ...) on its own, so the
		# guest's _on_sdp_created fires without this transport ever calling
		# create_answer() (no such method exists).
		pc.create_offer()
	return true


## Discard `pid`'s connection and build a fresh one at `gen`. A one-sided
## rebuild strands the handshake: the peer keeps a connection whose candidates
## can no longer reach anything, so callers must keep the peer in step -- either
## by adopting the peer's generation (_on_sig_received) or, host-side, by being
## the one who minted the new generation in the first place (_on_connect_timeout).
func _rebuild_connection(pid: String, gen: int) -> void:
	var net_id := int(_peer_to_net.get(pid, 0))
	if _mp != null and net_id != 0 and _mp.has_peer(net_id):
		_mp.remove_peer(net_id)
	var old_pc: Variant = _pcs.get(pid)
	if old_pc is WebRTCPeerConnection:
		(old_pc as WebRTCPeerConnection).close()
	_pcs.erase(pid)
	_remote_desc_set.erase(pid)
	_pending_ice.erase(pid)
	_sdp_retx.erase(pid)
	_connect_deadlines.erase(pid)
	if not _build_connection(pid, gen):
		# A rebuild that cannot re-establish a PC must not leave the peer mapped
		# with nothing behind it and no deadline to notice -- that is finding 4's
		# defect reachable through a second call path. Tear the peer down
		# completely instead of leaving it half-mapped.
		_teardown_peer(pid)


## Tear down a half-built (never engine-connected) peer entirely -- used when
## signaling reports the peer left before its link came up, or when an
## incarnation change discards a stale identity outright.
##
## `_pc_epochs` IS erased here, diverging deliberately from duo's "never erase"
## rule (rollback_transport.gd). That rule is over-cautious given this file's
## own invariant: `_epoch_seq` is never reset and `_next_epoch()` only ever
## returns values >= 1, so `_pc_epochs.get(pid, -1)` returning -1 for an erased
## entry still fails the `!= epoch` guard in `_on_sdp_created`/`_on_ice_created`
## exactly as a stale-but-present epoch would -- a queued callback from a
## torn-down connection can never be mistaken for a live one either way. A
## later rejoin builds a fresh PC under a NEW epoch from the never-reset
## _epoch_seq regardless of whether the old entry lingered.
func _teardown_peer(pid: String) -> void:
	var net_id := int(_peer_to_net.get(pid, 0))
	if _mp != null and net_id != 0 and _mp.has_peer(net_id):
		_mp.remove_peer(net_id)
	var pc: Variant = _pcs.get(pid)
	if pc is WebRTCPeerConnection:
		(pc as WebRTCPeerConnection).close()
	_pcs.erase(pid)
	_gens.erase(pid)
	_pc_epochs.erase(pid)
	_remote_desc_set.erase(pid)
	_pending_ice.erase(pid)
	_sdp_retx.erase(pid)
	_connect_deadlines.erase(pid)
	_attempts.erase(pid)
	_peer_to_net.erase(pid)
	_net_to_peer.erase(net_id)
	_connected.erase(pid)
	_awaiting_rejoin_gen0.erase(pid)
	_decode_failures.erase(pid)
	_muted_until.erase(pid)


## Arm `pid`'s connect deadline (see poll()'s "unarmed" convention). Called from
## _build_connection for BOTH roles now: the guest previously armed nothing and
## simply waited forever on a connection that never came up (Codex finding 4).
func _arm_connect_deadline(pid: String) -> void:
	_connect_deadlines[pid] = -1


## The connect-timeout budget for the local role. The guest's is deliberately
## LONGER than the host's whole retry budget (MAX_CONNECT_ATTEMPTS attempts of
## CONNECT_TIMEOUT_MS each), so the host's rebuild always gets its chance before
## the guest gives up.
func _connect_timeout_ms() -> int:
	return CONNECT_TIMEOUT_MS if _is_host else GUEST_CONNECT_TIMEOUT_MS


## Next connection epoch. Strictly increasing for the lifetime of this
## transport and never reset by peer churn -- that is the whole point, see
## `_pc_epochs`.
func _next_epoch() -> int:
	_epoch_seq += 1
	return _epoch_seq

# ============================================================================
# SDP / ICE callbacks (local descriptions/candidates -> signaling)
# ============================================================================


func _on_sdp_created(sdp_type: String, sdp: String, pid: String, gen: int, epoch: int) -> void:
	if int(_pc_epochs.get(pid, -1)) != epoch:
		# A superseded connection still draining callbacks. Publishing under
		# the live generation would hand the peer a dead ufrag.
		return
	var pc := _pcs.get(pid) as WebRTCPeerConnection
	if pc == null:
		return
	pc.set_local_description(sdp_type, sdp)
	_signaling.send(pid, {
		"v": SIGNAL_PROTOCOL_VERSION, "gen": gen, "kind": SIGNAL_KIND_SDP,
		"sdp_type": sdp_type, "sdp": sdp,
	})
	# Retransmit until something proves this arrived -- the adapter contract
	# is explicitly best-effort. "Something proves it arrived" is either an
	# answer for our offer (_handle_sdp) or the engine-level connection itself
	# (_on_engine_peer_connected); there is no separate ack, unlike duo.
	_sdp_retx[pid] = {"gen": gen, "epoch": epoch, "sdp_type": sdp_type, "sdp": sdp, "next_ms": -1}


func _on_ice_created(mid: String, index: int, candidate: String, pid: String, gen: int, epoch: int) -> void:
	if int(_pc_epochs.get(pid, -1)) != epoch:
		# A superseded connection still draining candidates. Sending them
		# under the live generation would hand the peer a stale ufrag to
		# discard.
		return
	_signaling.send(pid, {
		"v": SIGNAL_PROTOCOL_VERSION, "gen": gen, "kind": SIGNAL_KIND_ICE,
		"mid": mid, "index": index, "candidate": candidate,
	})

# ============================================================================
# Signaling receive
# ============================================================================


func _on_sig_received(sender_pid: String, data: Variant) -> void:
	if not _started or _closed:
		return
	if not (data is Dictionary):
		_reject("bad-signal:not-a-dictionary", sender_pid)
		return
	var d: Dictionary = data
	if int(d.get("v", 0)) != SIGNAL_PROTOCOL_VERSION:
		_reject("bad-signal:bad-version", sender_pid)
		return
	var kind := str(d.get("kind", ""))
	if kind != SIGNAL_KIND_SDP and kind != SIGNAL_KIND_ICE:
		# duo's mesh speaks "restart"/"sdp_ack"/"ws_listen" on this same
		# adapter shape; a star has no use for any of them (see the header's
		# keep/drop rationale), so anything else is dropped with a
		# flood-controlled warning rather than treated as an error. The key is
		# the fixed string, not the attacker-controlled kind -- an attacker
		# spraying distinct kind values must not be able to grow the dedup map
		# (Codex finding 7); the kind itself goes in `detail`, truncated.
		_reject("bad-signal:unknown-kind", sender_pid, kind.substr(0, 32))
		return

	if _departed.has(sender_pid):
		# Only a fresh peer_joined may resurrect a departed peer id.
		return

	if not _pcs.has(sender_pid):
		_discover_peer(sender_pid)
	if not _pcs.has(sender_pid):
		# Refused (a guest hearing from someone who is not the host) or still
		# buffered pending start()'s await -- nothing to dispatch to yet.
		return

	var incoming_gen := int(d.get("gen", 0))   # int() because it crossed JSON
	var local_gen := int(_gens.get(sender_pid, 0))

	if not _is_host and _awaiting_rejoin_gen0.has(sender_pid):
		# Rejoin barrier (see classify_generation's docs). This peer's presence
		# was just re-authorised by a fresh signaling peer_joined and we cannot
		# yet tell its NEW incarnation's envelopes from its previous one's --
		# only a fresh generation-0 offer proves this is the new incarnation.
		# Anything else here is a straggler from the incarnation we just
		# discarded. Without this barrier a stale higher-generation packet
		# would ADOPT across the rejoin and re-wedge the guest in mirror image.
		if incoming_gen != 0:
			_stale_generation_drops += 1
			_reject("stale-generation", sender_pid)
			return
		_awaiting_rejoin_gen0.erase(sender_pid)

	var action := classify_generation(local_gen, incoming_gen)
	if _is_host:
		# Sole minter, NEVER adopts a peer's generation. Any classification
		# other than PROCESS is stale.
		if action != GenAction.PROCESS:
			_stale_generation_drops += 1
			_reject("stale-generation", sender_pid)
			return
	else:
		match action:
			GenAction.DROP_STALE:
				# A delayed packet from a connection we already discarded. Never
				# rebuild backwards -- rebuilding on a bare `!=` is Codex finding
				# 1's exact wedge: a single delayed older packet would tear down
				# and permanently strand a live, newer connection.
				_stale_generation_drops += 1
				_reject("stale-generation", sender_pid)
				return
			GenAction.ADOPT:
				if incoming_gen > MAX_GEN:
					_reject("bad-signal:gen-out-of-budget", sender_pid)
					return
				# The same rule and the same reason as CouchSession's epoch
				# adoption: a follower that never adopts forward leaves itself
				# permanently rejecting the authority after a legitimate restart.
				_rebuild_connection(sender_pid, incoming_gen)
				_handshake_restarts += 1
				transport_gap.emit(sender_pid, "handshake-restart")
			GenAction.PROCESS:
				pass

	match kind:
		SIGNAL_KIND_SDP:
			_handle_sdp(sender_pid, d)
		SIGNAL_KIND_ICE:
			_handle_ice(sender_pid, d)


func _handle_sdp(pid: String, d: Dictionary) -> void:
	var pc := _pcs.get(pid) as WebRTCPeerConnection
	if pc == null:
		return
	var sdp_type := str(d.get("sdp_type", ""))
	var sdp := str(d.get("sdp", ""))

	# Flood/allocation control on a hostile or buggy signaling peer (Codex
	# finding 7): this star produces no sdp_type other than offer/answer, and a
	# real SDP is well under MAX_SDP_CHARS, so anything past those bounds is
	# rejected before it reaches the engine.
	if sdp.length() > MAX_SDP_CHARS:
		_reject("bad-signal:oversized-sdp", pid)
		return
	if sdp_type != "offer" and sdp_type != "answer":
		_reject("bad-signal:bad-sdp-type", pid, sdp_type.substr(0, 32))
		return

	if _remote_desc_set.has(pid):
		# A retransmit: this generation's description is already applied.
		# Re-applying would renegotiate a connection that is still
		# mid-handshake. Idempotent no-op -- the receipt that stops the
		# SENDER's retransmit is the engine-level connection coming up
		# (_on_engine_peer_connected), which both sides observe independently
		# of this frame, so no ack is needed here (unlike duo).
		return

	var err := pc.set_remote_description(sdp_type, sdp)
	if err != OK:
		# Held candidates stay held rather than being applied to a connection
		# that never took the description -- they would only error
		# individually. Nothing landed, so the peer's own retransmit is now
		# the only thing that will retry it.
		_reject("sdp-rejected", pid, "err=%d" % err)
		return
	_remote_desc_set[pid] = true
	if sdp_type == "answer":
		# Our offer has demonstrably arrived -- an answer cannot exist
		# without it.
		_sdp_retx.erase(pid)
	_flush_pending_ice(pid)


func _handle_ice(pid: String, d: Dictionary) -> void:
	var mid := str(d.get("mid", ""))
	var index := int(d.get("index", 0))   # int() because it crossed JSON
	var candidate := str(d.get("candidate", ""))

	# Flood/allocation control (Codex finding 7): a real ICE candidate line and
	# mid are tiny; with the MAX_PENDING_ICE-entry queue this also gives the
	# pending buffer an actual BYTE bound (MAX_PENDING_ICE * MAX_CANDIDATE_CHARS
	# == 32 KiB), which it lacked before.
	if mid.length() > MAX_MID_CHARS or candidate.length() > MAX_CANDIDATE_CHARS:
		_reject("bad-signal:oversized-candidate", pid)
		return
	if index < 0 or index > 255:
		_reject("bad-signal:bad-ice-index", pid)
		return

	var pc := _pcs.get(pid) as WebRTCPeerConnection
	if pc == null or not _remote_desc_set.has(pid):
		# Candidates that arrive before the connection can take them -- ahead
		# of the peer announce, or ahead of their own session description.
		# Dropping them costs the entire trickle set on links slow enough to
		# reorder the handshake against discovery; hold them instead.
		_buffer_pending_ice(pid, mid, index, candidate)
		return
	_apply_ice(pid, pc, mid, index, candidate)


func _buffer_pending_ice(pid: String, mid: String, index: int, candidate: String) -> void:
	var queued: Array = _pending_ice.get(pid, [])
	if queued.size() >= MAX_PENDING_ICE:
		_ice_dropped += 1
		_reject("pending-ice-overflow", pid)
		return
	queued.append({"mid": mid, "index": index, "candidate": candidate})
	_pending_ice[pid] = queued


## Apply everything held for `pid`, in arrival order. Called once the peer's
## remote description lands, which is what makes the connection able to accept
## candidates at all.
func _flush_pending_ice(pid: String) -> void:
	var queued: Array = _pending_ice.get(pid, [])
	if queued.is_empty():
		return
	_pending_ice.erase(pid)
	var pc := _pcs.get(pid) as WebRTCPeerConnection
	if pc == null:
		return
	for entry in queued:
		var e: Dictionary = entry
		_apply_ice(pid, pc, str(e["mid"]), int(e["index"]), str(e["candidate"]))


## Hand one candidate to the connection, reporting rejection rather than
## swallowing it: a candidate lost without a trace is expensive to diagnose,
## and if the discarded one was the only viable relay, the handshake just
## times out with nothing to explain why. Rejections are flood-controlled like
## every other malformed-input path (Codex finding 7); the one exception is the
## full candidate text, which is diagnostically useful and is logged exactly
## ONCE per transport lifetime rather than not at all.
func _apply_ice(pid: String, pc: WebRTCPeerConnection, mid: String, index: int, candidate: String) -> void:
	var err := pc.add_ice_candidate(mid, index, candidate)
	if err != OK:
		_ice_rejected += 1
		if not _logged_ice_sample:
			_logged_ice_sample = true
			push_warning("CouchStarTransport: add_ice_candidate rejected for %s (gen=%d err=%d): %s" % [
				pid, int(_gens.get(pid, 0)), err, candidate])
		_reject("ice-rejected", pid)

# ============================================================================
# Signaling presence
# ============================================================================


## A peer is present in the signaling room -- already there, or just joined;
## the adapter collapses both into this one signal. Idempotent via
## _discover_peer's own guard, so both join orders converge on the same state.
##
## A rejoin (this peer was previously recorded as departed) fires an
## incarnation change on whatever this transport still holds for it, and arms
## the rejoin barrier: both sides reset to generation 0 on a rejoin, and until
## this peer speaks at generation 0 we cannot tell its new incarnation's
## envelopes from its previous one's, so it may not move us off generation 0 in
## the meantime (Codex finding 1's mirror-image wedge; see classify_generation).
func _on_signaling_peer_joined(pid: String) -> void:
	if _departed.has(pid):
		_departed.erase(pid)
		if _pcs.has(pid) or _connected.has(pid):
			_on_incarnation_change(pid)
		_awaiting_rejoin_gen0[pid] = true
	_discover_peer(pid)


## A peer left the signaling room. The departure is ALWAYS recorded, even when
## the engine link is still up. duo's "an established link outlives room
## presence" rule is kept -- the link is not torn down here -- but discarding the
## event entirely is what let a rejoin arrive as a no-op, leaving a dead PC in
## _pcs forever (Codex finding 5). Recording is what arms the incarnation change.
func _on_signaling_peer_left(pid: String) -> void:
	if not (_pcs.has(pid) or _connected.has(pid) or _peer_to_net.has(pid) or _deferred_peer_ids.has(pid)):
		return
	_deferred_peer_ids.erase(pid)
	_remember_departed(pid)
	if _connected.has(pid):
		return
	_teardown_peer(pid)


## Everything we hold for `pid` belongs to an incarnation that is provably gone.
## Fire peer_lost first (the session must learn the link died) and only then
## discard, mirroring _on_engine_peer_disconnected's ordering.
func _on_incarnation_change(pid: String) -> void:
	if _connected.has(pid):
		_connected.erase(pid)
		_remember_lost(pid)
		peer_lost.emit(pid)
	_teardown_peer(pid)
	transport_gap.emit(pid, "peer-rejoined")

# ============================================================================
# Engine-level connection state
# ============================================================================


func _on_engine_peer_connected(net_id: int) -> void:
	var pid := str(_net_to_peer.get(net_id, ""))
	if pid.is_empty():
		# The engine confirmed a link for a net id we never bound in
		# _build_connection. Should not be reachable; never guess an identity
		# for it.
		push_warning("CouchStarTransport: peer_connected for unmapped net id %d" % net_id)
		return
	if _connected.has(pid):
		return
	_connected[pid] = true
	_connect_deadlines.erase(pid)
	_sdp_retx.erase(pid)
	peer_ready.emit(pid)
	if _recently_lost.has(pid):
		_recently_lost.erase(pid)
		transport_gap.emit(pid, "peer-reconnected")


## A link that came UP and then died is not rebuilt here -- peer_lost fires
## and that is all (see the header's v1 limitations). The rebuild path is
## armed only by the connect timeout (a link that never came up) and by a
## signaling peer_left/peer_joined pair.
func _on_engine_peer_disconnected(net_id: int) -> void:
	var pid := str(_net_to_peer.get(net_id, ""))
	if pid.is_empty():
		return
	if not _connected.has(pid):
		return
	_connected.erase(pid)
	_remember_lost(pid)
	peer_lost.emit(pid)


## Host: spends the retry budget -- one rebuild, then a terminal failure
## reported as a loud transport_gap (see MAX_CONNECT_ATTEMPTS). Guest: never
## rebuilds unilaterally -- a one-sided rebuild strands the handshake, and only
## the host mints generations -- so a guest timeout is always terminal; its
## budget is GUEST_CONNECT_TIMEOUT_MS, deliberately longer than the host's
## whole retry budget so the host's own rebuild always gets its chance first.
## Previously the guest armed no deadline at all and simply waited forever
## (Codex finding 4).
func _on_connect_timeout(pid: String) -> void:
	if _connected.has(pid):
		return
	if not _is_host:
		_connect_failures += 1
		_connect_deadlines.erase(pid)
		_sdp_retx.erase(pid)
		push_error("CouchStarTransport: host %s connect timeout, giving up" % pid)
		transport_gap.emit(pid, "connect-failed")
		return
	var attempts := int(_attempts.get(pid, 0)) + 1
	_attempts[pid] = attempts
	if attempts >= MAX_CONNECT_ATTEMPTS:
		_connect_failures += 1
		_connect_deadlines.erase(pid)
		_sdp_retx.erase(pid)
		push_error("CouchStarTransport: peer %s connect timeout, giving up" % pid)
		transport_gap.emit(pid, "connect-failed")
		return
	_rebuild_connection(pid, int(_gens.get(pid, 0)) + 1)
	_handshake_restarts += 1
	transport_gap.emit(pid, "handshake-restart")

# ============================================================================
# Send / receive
# ============================================================================


func _receive(from_net: int, bytes: PackedByteArray) -> void:
	var pid := str(_net_to_peer.get(from_net, ""))
	if pid.is_empty():
		# Never guess. An id we did not bind in add_peer() has no user id, and
		# inventing one would be exactly the impersonation the link is supposed to
		# make impossible.
		if _seen_unmapped.size() < MAX_UNMAPPED_LOGGED and not _seen_unmapped.has(from_net):
			_seen_unmapped[from_net] = true
			push_warning("CouchStarTransport: packet from unmapped net id %d" % from_net)
		_reject_count += 1
		return

	# Application-level flood control that runs BEFORE the decoder. bytes_to_var()
	# writes an engine ERROR line for every malformed input and _reject() can only
	# ever run after it, so a connected hostile peer could flood the engine log
	# without bound (Codex finding 8). A peer that produces MAX_DECODE_FAILURES
	# rejects with no accepted frame in between is muted: its packets are dropped
	# and counted without being decoded at all. The mute expires after
	# MUTE_DURATION_MS so a transient protocol glitch heals on its own, and any
	# ACCEPTED frame resets the counter, so a merely lossy peer is never muted.
	var muted_until := int(_muted_until.get(pid, 0))
	if muted_until > 0:
		if _now_ms < muted_until:
			_reject_count += 1
			return
		_muted_until.erase(pid)
		_decode_failures.erase(pid)

	var result := CouchEnvelope.from_bytes(bytes)
	var error := str(result.get("error", ""))
	if not error.is_empty():
		_reject(error, pid)
		var failures := int(_decode_failures.get(pid, 0)) + 1
		_decode_failures[pid] = failures
		if failures >= MAX_DECODE_FAILURES:
			_muted_until[pid] = _now_ms + MUTE_DURATION_MS
			_decode_mutes += 1
			transport_gap.emit(pid, "peer-muted")
		return
	_decode_failures.erase(pid)
	envelope_received.emit(result["envelope"], pid)


func _send(envelope: Dictionary, target_net_id: int) -> bool:
	if not is_ready():
		return false
	if target_net_id != MultiplayerPeer.TARGET_PEER_BROADCAST:
		var pid := str(_net_to_peer.get(target_net_id, ""))
		if pid.is_empty() or not _connected.has(pid):
			return false
	var kind := str(envelope.get(CouchEnvelope.KEY_KIND, ""))
	var payload := CouchEnvelope.to_bytes(envelope)
	# Enforced on the SENDER, not only on the receiver, because the sender is the
	# only side that can do anything about it. CouchLobbyTransport reports this
	# cliff at error severity on receive (its D13 note); here it is caught one hop
	# earlier and the frame is honestly refused instead of vanishing.
	if payload.size() > CouchEnvelope.MAX_BINARY_FRAME_BYTES:
		_oversized_sends += 1
		_reject("oversized-send:" + kind, _local_peer_id)
		return false
	_mp.set_target_peer(target_net_id)
	_mp.set_transfer_mode(lane_for_kind(kind))
	# Read back from the peer, not from a second call to lane_for_kind(): the
	# lane is a property of the link, and this is the only way anything above
	# the transport can prove the lane TABLE is actually in force (§3.1).
	var lane := _mp.get_transfer_mode()
	_send_lane_tally[lane] = int(_send_lane_tally.get(lane, 0)) + 1
	return _mp.put_packet(payload) == OK

# ============================================================================
# Helpers
# ============================================================================


## Flood-controlled rejection log, verbatim in spirit from
## CouchLobbyTransport._on_lobby_event: at most one push per distinct error
## string, `push_error` for anything beginning with "oversized" (a behaviour
## cliff that must stay visible), `push_warning` otherwise. Used both for
## malformed envelopes (_receive, oversized sends) and for malformed handshake
## frames (_on_sig_received, _handle_sdp, _handle_ice) -- one flood-control
## mechanism, two wires.
##
## `detail` carries attacker-controlled text (an unknown kind, an sdp_type)
## OUT of the dedup key -- keying on raw attacker input would let a flood of
## distinct payloads grow _seen_reject_errors without bound, which the fixed
## error-string key alone does not stop (Codex finding 7). The dedup map
## itself is additionally bounded by MAX_REJECT_KEYS: once every legitimate
## rejection SHAPE this file can produce has logged once, an attacker cycling
## through error strings gains nothing further.
func _reject(error: String, who: String, detail: String = "") -> void:
	_reject_count += 1
	if _seen_reject_errors.has(error) or _seen_reject_errors.size() >= MAX_REJECT_KEYS:
		return
	_seen_reject_errors[error] = true
	var suffix := "" if detail.is_empty() else " (%s)" % detail
	var message := "CouchStarTransport: rejected frame from %s: %s%s" % [who, error, suffix]
	if error.begins_with("oversized"):
		push_error(message)
	else:
		push_warning(message)


## Roster-derived-equivalent liveness bookkeeping so a reconnecting peer's
## engine link fires a diagnostic transport_gap("peer-reconnected") rather
## than silently looking like a first connect. Bounded exactly like
## CouchLobbyTransport._remember_lost: 64 is an order of magnitude above any
## plausible concurrent lobby, so a rejoin that could matter is never
## forgotten, and the oldest entry is evicted first (Godot Dictionaries
## preserve insertion order).
func _remember_lost(pid: String) -> void:
	if _recently_lost.has(pid):
		return
	_recently_lost[pid] = true
	while _recently_lost.size() > MAX_RECENTLY_LOST:
		_recently_lost.erase(_recently_lost.keys()[0])


## Bounded departure bookkeeping, identical in shape and rationale to
## _remember_lost: a signaling server that churns peer_left events -- or simply
## a long-lived session with heavy turnover -- must not grow _departed forever
## (Codex finding 7).
func _remember_departed(pid: String) -> void:
	if _departed.has(pid):
		return
	_departed[pid] = true
	while _departed.size() > MAX_DEPARTED:
		_departed.erase(_departed.keys()[0])


func _attach_signaling() -> void:
	if _signaling == null:
		return
	if not _signaling.sig_received.is_connected(_on_sig_received):
		_signaling.sig_received.connect(_on_sig_received)
	if not _signaling.peer_joined.is_connected(_on_signaling_peer_joined):
		_signaling.peer_joined.connect(_on_signaling_peer_joined)
	if not _signaling.peer_left.is_connected(_on_signaling_peer_left):
		_signaling.peer_left.connect(_on_signaling_peer_left)


func _detach_signaling() -> void:
	if _signaling == null:
		return
	if _signaling.sig_received.is_connected(_on_sig_received):
		_signaling.sig_received.disconnect(_on_sig_received)
	if _signaling.peer_joined.is_connected(_on_signaling_peer_joined):
		_signaling.peer_joined.disconnect(_on_signaling_peer_joined)
	if _signaling.peer_left.is_connected(_on_signaling_peer_left):
		_signaling.peer_left.disconnect(_on_signaling_peer_left)


## Copied verbatim from CouchSession._field_string.
static func _field_string(obj: Variant, field: String) -> String:
	if obj == null:
		return ""
	if obj is Dictionary:
		return str((obj as Dictionary).get(field, ""))
	if obj is Object:
		var value: Variant = obj.get(field)
		if value == null:
			return ""
		return str(value)
	return ""
