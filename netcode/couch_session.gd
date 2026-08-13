## Host-authoritative session layer on top of CouchTransport: owns epoch
## minting/adoption, per-(sender, kind) sequence tracking (via
## CouchEnvelope.ReceiveTracker), the authorized-guest pin, the ready barrier,
## and the hello handshake. Nothing here may reference anything outside
## netcode/ -- `roster` is a duck-typed stand-in for CouchLobby (real one or a
## fixture double), checked structurally in _init and read only through
## `.get(field)` / documented methods, never cast to CouchLobby.
##
## Epoch: the HOST is the sole minter (unix milliseconds, monotone within the
## process -- see _mint_epoch). A guest adopts any epoch different from the one
## it tracks (`!=`, never `>`: a `>` rule would leave a guest permanently
## rejecting an epoch after the host's clock stepped backwards, which is the
## wedge this layer exists to kill). The host rejects any envelope whose epoch
## isn't the session epoch; a `hello` may additionally carry UNKNOWN_EPOCH,
## because a guest's first-contact hello cannot know the epoch yet. Nothing
## else is exempt -- in particular a hello stamped with some OTHER epoch is
## rejected before the hello-epoch substitution below can launder it.
##
## The host pre-seeds the pinned peer's ReceiveTracker to the session epoch at
## MINT time, not on its first hello. Without that, a host that stops and
## restarts (D8) while the guest stays `active` clears every tracker, mints a
## new epoch, and then rejects that guest's messages PERMANENTLY -- the guest
## adopted the new epoch from the host's broadcast hello but, being already
## active, never sends another hello, so nothing bootstraps the tracker again.
## That is defect 1's exact shape through a third door. Pre-seeding also makes
## UNKNOWN_EPOCH a hello-only concession: with a default tracker, a bare
## intent/input carrying epoch 0 coincidentally matched it and was accepted.
##
## Ready barrier: the host is active the instant it mints an epoch and picks its
## authorized guest -- it needs no reply to be authoritative. A guest is NOT
## `active` until the host's `hello` arrives; poll() re-sends the guest hello on
## a fixed timer until then. This is an observable behaviour change from the
## pre-session code: the guest shows nothing for up to one RTT at match start.
##
## Authorized guest: picked once, when the host's session starts (lowest
## controller_slot, ties broken by ascending user_id -- the pre-session pick,
## preserved verbatim). It is pinned for the life of the session: a roster
## change never repicks it. If the pinned guest leaves, the session STOPS
## (`stop("authorized-peer-left")`); the very next `evaluate()` may start a
## FRESH session with a NEW epoch and, if the pinned guest is gone, a newly
## picked one. That restart is announced through `session_stopped` +
## `session_started`, never a silent takeover. The addon must not assume the
## platform bounces a departing player anywhere -- stop+restart is correct
## either way.
##
## Reserved kinds (`resync-request` / `resync-response`) are accepted
## vocabulary, not implemented in Phase 0: a message of one of those kinds is
## silently ignored (at most one push_warning for the whole session), never
## rejected and never counted as a sequence gap, so a mixed-build match during
## a deploy degrades quietly instead of log-flooding an older client.
##
## `poll(now_ms)` drives all timed behaviour (the guest hello retry). There is
## no `_process` here -- the session is a RefCounted, not a Node -- so a fixture
## can drive time explicitly instead of sleeping in real time.
##
## Every `send_*` return means "accepted for send", never "delivered". There is
## no acknowledgement anywhere in this layer; see netcode/transport.gd.
class_name CouchSession
extends RefCounted

const REQUIRED_ROSTER_METHODS := ["get_players", "get_me", "get_host", "get_guests", "is_host"]

signal session_started(epoch: int, is_host: bool, local_slot: int, peer_id: String, peer_name: String)
signal session_stopped(reason: String)
signal hello_received(sender_id: String)            # host side: the guest wants full state
signal intent_received(body: Dictionary, sender_id: String)
signal input_received(body: Dictionary, sender_id: String)
signal snapshot_received(body: Dictionary)
signal sequence_gap(kind: String, sender_id: String, missing: int)
signal transport_gap(peer_id: String, reason: String)
signal rejected(reason: String, sender_id: String)  # observability for malformed/unauthorised

const SLOT_HOST := 0
const SLOT_GUEST := 1
const SLOT_SPECTATOR := -1
const HELLO_RETRY_MS := 500
const HELLO_STATE_REQUEST_MIN_INTERVAL_MS := 250

var active: bool:
	get:
		return _active

var epoch: int:
	get:
		return _epoch

var is_host: bool:
	get:
		return _is_host

var local_slot: int:
	get:
		return _local_slot

var authorized_peer_id: String:
	get:
		return _authorized_peer_id

var host_id: String:
	get:
		return _host_id

var peer_name: String:
	get:
		return _peer_name

var gap_count: int:  # for the milestone report
	get:
		return _gap_count

var rejected_count: int:  # for the milestone report
	get:
		return _rejected_count

var _roster: Object
var _transport: Object

var _engaged: bool = false   # true from the moment a role is committed until stop()
var _active: bool = false
var _epoch: int = CouchEnvelope.UNKNOWN_EPOCH
var _is_host: bool = false
var _local_slot: int = SLOT_SPECTATOR
var _authorized_peer_id: String = ""
var _host_id: String = ""
var _peer_name: String = ""
var _gap_count: int = 0
var _rejected_count: int = 0

var _last_minted_epoch: int = 0
var _out_seq: Dictionary = {}                      # kind -> int, my own outgoing counters
var _trackers: Dictionary = {}                      # sender_id -> CouchEnvelope.ReceiveTracker
var _slots: Dictionary = {}                         # user_id -> int, host-assigned

var _now_ms: int = 0                                # cached from the last evaluate()/poll()
var _next_hello_retry_ms: int = 0
var _last_hello_state_request_ms: Dictionary = {}   # sender_id -> int, host-side rate limit
var _warned_reserved_kind: bool = false             # at most one push_warning per session


func _init(roster: Object, transport: Object) -> void:
	_roster = roster
	_transport = transport
	if not _implements_roster(roster):
		push_error("CouchSession: roster does not satisfy the required duck contract")
		return
	if not CouchTransport.assert_implements(transport, "session transport"):
		return
	_transport.envelope_received.connect(_on_envelope_received)
	_transport.transport_gap.connect(_on_transport_gap)


static func _implements_roster(candidate: Object) -> bool:
	if candidate == null:
		return false
	for method_name in REQUIRED_ROSTER_METHODS:
		if not candidate.has_method(method_name):
			return false
	return true


## Call on roster change and once at boot.
func evaluate(now_ms: int) -> void:
	_now_ms = now_ms

	if _roster == null or not bool(_roster.get("is_available")):
		stop("lobby-unavailable")
		return

	var players: Array = _roster.get_players()
	if players.size() < 2:
		# The specific reason beats the generic one when it applies. A
		# two-player roster losing the pinned guest is BOTH "too small" and
		# "the authorized peer left", and the second is the actionable fact a
		# game shows the player -- session_stopped(reason) is the only channel
		# that carries it. Claimed ONLY when this session is an engaged host,
		# a pin exists, the roster still contains that host, and the pin is
		# genuinely absent; so a lobby teardown (a roster that has lost the
		# local player too) still reports the generic reason and this can
		# never name the wrong cause. The guard lives here rather than in a
		# reorder of the role dispatch below: moving the size check after the
		# dispatch would leave a roster of [guest-only] failing to stop at all.
		if (
			_engaged
			and _is_host
			and not _authorized_peer_id.is_empty()
			and _has_player(players, _host_id)
			and not _has_player(players, _authorized_peer_id)
		):
			stop("authorized-peer-left")
		else:
			stop("roster-too-small")
		return

	var i_am_host: bool = bool(_roster.is_host())

	if _engaged and i_am_host != _is_host:
		stop("role-changed")

	if i_am_host:
		_evaluate_as_host(players)
	else:
		_evaluate_as_guest(now_ms, players)


## Call every frame; drives the guest hello retry.
func poll(now_ms: int) -> void:
	_now_ms = now_ms
	if _engaged and not _is_host and not _active and now_ms >= _next_hello_retry_ms:
		_send_guest_hello()
		_next_hello_retry_ms = now_ms + HELLO_RETRY_MS


func stop(reason: String) -> void:
	if not _engaged:
		return
	_engaged = false
	_active = false
	_epoch = CouchEnvelope.UNKNOWN_EPOCH
	_is_host = false
	_local_slot = SLOT_SPECTATOR
	_authorized_peer_id = ""
	_host_id = ""
	_peer_name = ""
	_out_seq.clear()
	_trackers.clear()
	_slots.clear()
	_next_hello_retry_ms = 0
	_last_hello_state_request_ms.clear()
	_warned_reserved_kind = false
	session_stopped.emit(reason)


func send_intent(body: Dictionary) -> bool:
	return _send(CouchEnvelope.KIND_INTENT, body, false)


func send_input(body: Dictionary) -> bool:
	return _send(CouchEnvelope.KIND_INPUT, body, false)


func broadcast_snapshot(body: Dictionary) -> bool:
	return _send(CouchEnvelope.KIND_SNAPSHOT, body, true)


# --- Bootstrap ---------------------------------------------------------------


func _evaluate_as_host(players: Array) -> void:
	if _engaged and not _has_player(players, _authorized_peer_id):
		stop("authorized-peer-left")

	if _engaged:
		return

	var guest := _pick_authorized_guest()
	if guest == null:
		return

	var host_player: Variant = _roster.get_me()
	var host_id := _field_string(host_player, "user_id")

	_authorized_peer_id = _field_string(guest, "user_id")
	_epoch = _mint_epoch()
	_out_seq.clear()
	_trackers.clear()

	# Pre-seed the pinned peer's ReceiveTracker to the epoch this session just
	# minted, rather than waiting for its first hello to bootstrap it. Two
	# reasons, both measured (see the header). It kills a restart wedge: a host
	# that stops and restarts (D8) clears every tracker and mints a new epoch,
	# but a guest that never stopped is still `active`, adopts the new epoch
	# silently from the host's broadcast hello, and by the ready-barrier rule
	# never sends another hello -- so with a default-UNKNOWN_EPOCH tracker the
	# host rejects that guest FOREVER. And it closes an epoch-check bypass: an
	# untouched tracker sits at UNKNOWN_EPOCH, which a bare intent/input
	# carrying epoch 0 coincidentally MATCHES. Scoped to the pinned peer alone:
	# it is the only sender whose envelopes can reach a tracker on a host (the
	# _authorized_peer_id check in _on_envelope_received runs first), and the
	# tracker records what a sender has sent -- it never grants authority.
	var pinned_tracker := CouchEnvelope.ReceiveTracker.new()
	pinned_tracker.reset(_epoch)
	_trackers[_authorized_peer_id] = pinned_tracker

	_slots.clear()
	_slots[host_id] = SLOT_HOST
	_slots[_authorized_peer_id] = SLOT_GUEST
	for player in players:
		var uid := _field_string(player, "user_id")
		if not _slots.has(uid):
			_slots[uid] = SLOT_SPECTATOR

	_is_host = true
	_host_id = host_id
	_local_slot = SLOT_HOST
	_peer_name = _field_string(guest, "username")
	_engaged = true

	_send_host_hello("")   # broadcast

	_active = true
	session_started.emit(_epoch, true, SLOT_HOST, _authorized_peer_id, _peer_name)


func _evaluate_as_guest(now_ms: int, _players: Array) -> void:
	var host_player: Variant = _roster.get_host()
	var host_id := _field_string(host_player, "user_id") if host_player != null else ""

	if _engaged and (host_player == null or host_id != _host_id):
		stop("host-left")

	if host_player == null:
		return

	if _engaged:
		return

	_host_id = host_id
	_epoch = CouchEnvelope.UNKNOWN_EPOCH
	_out_seq.clear()
	_trackers.clear()
	_is_host = false
	_local_slot = SLOT_SPECTATOR
	_active = false
	_engaged = true

	_send_guest_hello()
	_next_hello_retry_ms = now_ms + HELLO_RETRY_MS


## Lowest controller_slot, ties broken by ascending user_id -- preserved
## verbatim from the pre-session pick so this is not a behaviour change.
func _pick_authorized_guest() -> Variant:
	var guests: Array = _roster.get_guests()
	if guests.is_empty():
		return null
	guests.sort_custom(func(a, b):
		var slot_a := _field_int(a, "controller_slot", -1)
		var slot_b := _field_int(b, "controller_slot", -1)
		if slot_a == slot_b:
			return _field_string(a, "user_id") < _field_string(b, "user_id")
		return slot_a < slot_b
	)
	return guests[0]


func _has_player(players: Array, user_id: String) -> bool:
	for player in players:
		if _field_string(player, "user_id") == user_id:
			return true
	return false


## Unix MILLISECONDS. Survives a host reload because it comes from the wall clock,
## not from process state; sub-second resolution means a reload-and-restart inside
## the same second still mints a different value. ~1.75e12 today, four orders of
## magnitude under MAX_SAFE_INT, so it survives the JSON/JS double round trip
## exactly. The maxi() guard keeps it strictly increasing WITHIN a process so a
## clock step backwards cannot mint a repeat.
func _mint_epoch() -> int:
	var minted := maxi(int(Time.get_unix_time_from_system() * 1000.0), _last_minted_epoch + 1)
	_last_minted_epoch = minted
	return minted


# --- Hello --------------------------------------------------------------------


func _send_host_hello(target_peer_id: String) -> void:
	var body := {
		"role": "host",
		"slots": _slots.duplicate(),
		"authorizedGuest": _authorized_peer_id,
		"name": _field_string(_roster.get_me(), "username"),
	}
	_out_seq[CouchEnvelope.KIND_HELLO] = int(_out_seq.get(CouchEnvelope.KIND_HELLO, 0)) + 1
	var envelope := CouchEnvelope.make(
		CouchEnvelope.KIND_HELLO, _epoch, _out_seq[CouchEnvelope.KIND_HELLO], body
	)
	if target_peer_id.is_empty():
		_transport.broadcast(envelope)
	else:
		_transport.send_to_peer(target_peer_id, envelope)


func _send_guest_hello() -> void:
	var body := {
		"role": "guest",
		"name": _field_string(_roster.get_me(), "username"),
	}
	_out_seq[CouchEnvelope.KIND_HELLO] = int(_out_seq.get(CouchEnvelope.KIND_HELLO, 0)) + 1
	var envelope := CouchEnvelope.make(
		CouchEnvelope.KIND_HELLO, CouchEnvelope.UNKNOWN_EPOCH,
		_out_seq[CouchEnvelope.KIND_HELLO], body
	)
	_transport.send_to_authority(envelope)


func _on_hello_at_host(sender_id: String) -> void:
	# Rate-limited because each reply costs the host a full-world broadcast.
	var last := int(_last_hello_state_request_ms.get(sender_id, -HELLO_STATE_REQUEST_MIN_INTERVAL_MS))
	if _now_ms - last < HELLO_STATE_REQUEST_MIN_INTERVAL_MS:
		return
	_last_hello_state_request_ms[sender_id] = _now_ms
	_send_host_hello(sender_id)
	hello_received.emit(sender_id)


func _on_hello_at_guest(body: Dictionary) -> void:
	var my_id := _field_string(_roster.get_me(), "user_id")
	var slots: Dictionary = body.get("slots", {})
	_local_slot = int(slots.get(my_id, SLOT_SPECTATOR))
	_peer_name = str(body.get("name", ""))
	if not _active:
		_active = true
		session_started.emit(_epoch, false, _local_slot, _host_id, _peer_name)


# --- Receive --------------------------------------------------------------------


func _on_envelope_received(envelope: Dictionary, sender_id: String) -> void:
	if not _engaged:
		return
	var kind := str(envelope.get(CouchEnvelope.KEY_KIND, ""))

	if not CouchEnvelope.is_implemented(kind):
		# Reserved vocabulary (resync-request/-response): accept and ignore, not
		# a rejection and not a sequence gap, so a mixed-build peer degrades
		# quietly instead of log-flooding an older client. At most one warning
		# for the whole session (D14).
		if kind in CouchEnvelope.KINDS and not _warned_reserved_kind:
			_warned_reserved_kind = true
			push_warning("CouchSession: reserved kind '%s' received and ignored" % kind)
		return

	if _is_host:
		match kind:
			CouchEnvelope.KIND_HELLO, CouchEnvelope.KIND_INTENT, CouchEnvelope.KIND_INPUT:
				if sender_id != _authorized_peer_id:
					_reject(sender_id, "unauthorized-sender")
					return
			CouchEnvelope.KIND_SNAPSHOT:
				_reject(sender_id, "authority-kind-from-peer")
				return
	else:
		match kind:
			CouchEnvelope.KIND_SNAPSHOT, CouchEnvelope.KIND_HELLO:
				if sender_id != _host_id:
					_reject(sender_id, "unauthorized-sender")
					return
			CouchEnvelope.KIND_INTENT, CouchEnvelope.KIND_INPUT:
				_reject(sender_id, "participant-kind-at-peer")
				return

	# Foreign-epoch guard for `hello` at a host. The host is the sole epoch
	# authority and never adopts (D3). UNKNOWN_EPOCH is the one carve-out -- a
	# guest's first-contact hello cannot know the epoch yet -- and the session's
	# own epoch is accepted too, so a guest that has already adopted it and
	# re-hellos still works. ANYTHING else is a foreign epoch and is rejected
	# exactly like any other kind. This runs BEFORE the tracker is fetched and
	# before the substitution below, both of which would otherwise launder the
	# wire epoch into the live one: a pinned guest left over from a dead session
	# could then stamp any epoch it liked, advance the host's hello sequence
	# state, and force a full-state reply.
	if _is_host and kind == CouchEnvelope.KIND_HELLO:
		var hello_epoch := int(envelope.get(CouchEnvelope.KEY_EPOCH, CouchEnvelope.UNKNOWN_EPOCH))
		if hello_epoch != CouchEnvelope.UNKNOWN_EPOCH and hello_epoch != _epoch:
			_reject(sender_id, "epoch-mismatch")
			return

	# Session-owned hello body shape. Checked HERE -- after the sender/kind and
	# foreign-epoch guards, but BEFORE the tracker is fetched -- because
	# tracker.observe() COMMITS state: on a guest it adopts the wire epoch and
	# records this frame's seq. A hello that passes the codec and the tracker
	# and only then fails to apply (_on_hello_at_guest does a typed Dictionary
	# assignment and an int() coercion on fields the SESSION owns) leaves the
	# guest inactive with the epoch already adopted and this frame already
	# counted, so the very frame that should have started the session is now a
	# duplicate. Rejecting first prevents every one of those commits; the
	# guest's hello retry timer is untouched by a rejection, so it keeps asking
	# and a later well-formed hello starts the session normally. Guest-side
	# only: the host's counterpart, _on_hello_at_host, never reads the body at
	# all, so a host has no equivalent exposure and gains no guard.
	if not _is_host and kind == CouchEnvelope.KIND_HELLO:
		if not _hello_body_is_valid(envelope.get(CouchEnvelope.KEY_BODY, {})):
			_reject(sender_id, "malformed-hello-body")
			return

	var tracker: CouchEnvelope.ReceiveTracker = _trackers.get(sender_id)
	if tracker == null:
		tracker = CouchEnvelope.ReceiveTracker.new()
		_trackers[sender_id] = tracker

	var observed_envelope := envelope
	if _is_host and kind == CouchEnvelope.KIND_HELLO:
		# A guest's hello always carries UNKNOWN_EPOCH -- it doesn't know the
		# epoch yet -- but the host is the sole epoch authority and a hello
		# from the authorized peer (checked above) is never a foreign-epoch
		# attack. Track it against the SESSION epoch instead of what it
		# carries. The SUBSTITUTION below is load-bearing and always will be:
		# remove it and three corpus cases fail immediately. The reset above
		# it is now belt-and-braces -- _evaluate_as_host pre-seeds this
		# tracker at mint time, so across the whole corpus, the fault test and
		# every probed restart path it never fires. Kept because if it ever
		# did fire, resetting to the session epoch is exactly right.
		if tracker.epoch != _epoch:
			tracker.reset(_epoch)
		observed_envelope = envelope.duplicate()
		observed_envelope[CouchEnvelope.KEY_EPOCH] = _epoch

	var result := tracker.observe(observed_envelope, not _is_host)
	if not bool(result.get("accept", false)):
		_reject(sender_id, str(result.get("reason", "")))
		return

	# The session's own epoch mirrors whatever the tracker just adopted -- a
	# guest can learn a new epoch from ANY accepted kind, not only hello.
	if not _is_host and bool(result.get("reset", false)):
		_epoch = tracker.epoch

	var gap := int(result.get("gap", 0))
	if gap > 0 and not CouchEnvelope.gap_is_ignorable(kind):
		_gap_count += 1
		sequence_gap.emit(kind, sender_id, gap)

	_dispatch(kind, envelope, sender_id)


func _dispatch(kind: String, envelope: Dictionary, sender_id: String) -> void:
	var body: Dictionary = envelope.get(CouchEnvelope.KEY_BODY, {})
	match kind:
		CouchEnvelope.KIND_HELLO:
			if _is_host:
				_on_hello_at_host(sender_id)
			else:
				_on_hello_at_guest(body)
		CouchEnvelope.KIND_INTENT:
			intent_received.emit(body, sender_id)
		CouchEnvelope.KIND_INPUT:
			input_received.emit(body, sender_id)
		CouchEnvelope.KIND_SNAPSHOT:
			snapshot_received.emit(body)


func _on_transport_gap(peer_id: String, reason: String) -> void:
	transport_gap.emit(peer_id, reason)


func _reject(sender_id: String, reason: String) -> void:
	_rejected_count += 1
	rejected.emit(reason, sender_id)


## Structural check on exactly the hello fields _on_hello_at_guest consumes, and
## nothing else: `slots` must be a map if present, and this player's own entry in
## it must be numeric if present. A hello carrying no `slots` at all stays legal
## and means "spectator" -- the pre-existing behaviour. `name` is read through
## str(), which never fails on any Variant, so it is not checked. Deliberately
## NOT a general schema validator: everything past these two fields is game
## payload, which this layer does not own.
func _hello_body_is_valid(body: Variant) -> bool:
	if not (body is Dictionary):
		return false
	var raw_slots: Variant = (body as Dictionary).get("slots", {})
	if not (raw_slots is Dictionary):
		return false
	var slots: Dictionary = raw_slots
	var my_id := _field_string(_roster.get_me(), "user_id")
	if not slots.has(my_id):
		return true
	var slot_value: Variant = slots[my_id]
	return slot_value is int or slot_value is float


# --- Send -----------------------------------------------------------------------


## Each send returns "accepted for send", never "delivered" -- see
## netcode/transport.gd. `requires_host` is the role gate: true means only the
## host may send this kind (snapshot), false means only a non-host may
## (intent/input).
func _send(kind: String, body: Dictionary, requires_host: bool) -> bool:
	if not _active:
		return false
	if requires_host != _is_host:
		return false
	# Only the ONE guest the host pinned may send a participant kind. A
	# spectator's intent/input is rejected by the host as `unauthorized-sender`
	# without exception -- this layer pins exactly one guest for the life of a
	# session -- so putting it on the wire is guaranteed-wasted tunnel bandwidth
	# on the platform's metered cost driver, and returning true would claim
	# "accepted for send" for a message that provably cannot be applied.
	# `_local_slot` is authoritative here: it is assigned from the host's own
	# `slots` map by the same hello that sets _active, so it can never be stale
	# at this point. Scoped to participant kinds -- a host is SLOT_HOST and its
	# snapshot broadcast must not be caught by this.
	if not requires_host and _local_slot != SLOT_GUEST:
		return false
	_out_seq[kind] = int(_out_seq.get(kind, 0)) + 1
	var envelope := CouchEnvelope.make(kind, _epoch, _out_seq[kind], body)
	if _is_host:
		return _transport.broadcast(envelope)
	return _transport.send_to_authority(envelope)


# --- Duck-typed roster field access ----------------------------------------------


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


static func _field_int(obj: Variant, field: String, fallback: int) -> int:
	if obj == null:
		return fallback
	var value: Variant
	if obj is Dictionary:
		value = (obj as Dictionary).get(field)
	elif obj is Object:
		value = obj.get(field)
	else:
		return fallback
	if value is int or value is float:
		return int(value)
	return fallback
