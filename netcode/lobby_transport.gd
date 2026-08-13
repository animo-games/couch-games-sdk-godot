## Lobby-tunnel implementation of CouchTransport. Frames every envelope as JSON
## and sends it through CouchLobby.send_event under ONE event name -- the four
## td-hello/td-action/td-input/td-state events this replaces are gone; `kind`
## inside the envelope carries what the event name used to.
##
## `lobby` is duck-typed on purpose: CouchLobby lives outside netcode/, and this
## file must parse in a project that installs neither `lobby/` nor `webrtc/`, per
## the partial-install rule documented on webrtc/couch_signaling_adapter.gd.
## Required lobby surface (checked in _init, not statically typed):
##   send_event(event: String, data: Variant, target: Dictionary) -> void
##   event_received(event: String, data: Variant, sender_user_id: String)
##   players_changed(players: Array)
##   an `is_available` property, read via `.get("is_available")` since CouchLobby
##   exposes it as a computed property, not a method.
##
## `RefCounted`, not `Node`: nothing here needs the tree, and it is trivially
## constructible inside a headless fixture. The owner (CouchSession) holds the
## reference.
class_name CouchLobbyTransport
extends RefCounted

const REQUIRED_LOBBY_METHODS := ["send_event", "is_host"]
const REQUIRED_LOBBY_SIGNALS := ["event_received", "players_changed"]

const DEFAULT_EVENT_NAME := "couch-net"

## Bound on `_recently_lost`. That map exists only so a departed peer that comes
## back fires the diagnostic transport_gap(id, "peer-rejoined"); an id is erased
## the moment it rejoins, so it only accumulates for peers that leave and never
## return. 64 is an order of magnitude above any plausible concurrent lobby, so
## a rejoin that could matter (seconds, in the same match) is never forgotten,
## while a long-lived lobby churning distinct users stays O(1) in memory. The
## oldest entry is evicted first -- Godot Dictionaries preserve insertion order
## -- and the only cost of an eviction is one missed diagnostic signal for a
## peer that left more than MAX_RECENTLY_LOST departures ago. Correctness never
## depends on it: the session's epoch and per-kind sequence state, not
## transport_gap, is what protects continuity.
const MAX_RECENTLY_LOST := 64

signal envelope_received(envelope: Dictionary, sender_peer_id: String)
signal peer_ready(peer_id: String)
signal peer_lost(peer_id: String)
signal transport_gap(peer_id: String, reason: String)

# --- DEBUG-ONLY fault injection -------------------------------------------------
# Drops OUTGOING envelopes on the real send path so gap handling can be exercised
# without a lossy network. Disabled by default and inert in a release build: every
# lever is gated on OS.is_debug_build(), so an exported release can never drop a
# packet no matter what a caller sets.
#
# Two levers, both real code:
#   fault_drop_permille  -- probabilistic, "a fraction of outgoing envelopes"
#   fault_drop_next()    -- deterministic queue, for assertions
# A test drives the DETERMINISTIC lever, so no assertion depends on an RNG sequence
# that a future Godot build could legitimately change.

var fault_drop_permille: int = 0          # 0..1000; 0 disables
var fault_kinds: PackedStringArray = []   # empty = every kind is eligible
var fault_seed: int = 0: set = _set_fault_seed   # reseeds _fault_rng; reproducible

var fault_drops: int:  # total dropped, for evidence
	get:
		return _fault_drops

var _lobby: Object
var _event_name: String
var _closed: bool = false

var _known_peer_ids: Dictionary = {}      # user_id -> true
var _recently_lost: Dictionary = {}       # user_id -> true

var _seen_reject_errors: Dictionary = {}  # error string -> true, flood control
var _reject_count: int = 0

var _fault_rng := RandomNumberGenerator.new()
var _fault_pending: Dictionary = {}       # kind -> count
var _fault_drops: int = 0


func _init(lobby: Object, event_name: String = DEFAULT_EVENT_NAME) -> void:
	_event_name = event_name
	_lobby = lobby
	if not _implements_lobby(lobby):
		push_error("CouchLobbyTransport: lobby does not satisfy the required duck contract")
		return
	_lobby.event_received.connect(_on_lobby_event)
	_lobby.players_changed.connect(_on_players_changed)


static func _implements_lobby(candidate: Object) -> bool:
	if candidate == null:
		return false
	for method_name in REQUIRED_LOBBY_METHODS:
		if not candidate.has_method(method_name):
			return false
	for signal_name in REQUIRED_LOBBY_SIGNALS:
		if not candidate.has_signal(signal_name):
			return false
	return true


## Contract (netcode/transport.gd): on the authority itself this is a no-op that
## returns false -- the authority never talks to itself over the wire. Without
## the guard the lobby would accept the frame and relay it to every participant
## EXCEPT the sender, so a host caller would get `true` for a frame no authority
## will ever receive: a false-positive success on the one method whose whole
## point is that a send return is not a delivery receipt.
func send_to_authority(envelope: Dictionary) -> bool:
	if _is_authority():
		return false
	return _send(envelope, {"role": "host"})


func send_to_peer(peer_id: String, envelope: Dictionary) -> bool:
	return _send(envelope, {"user_id": peer_id})


func broadcast(envelope: Dictionary) -> bool:
	return _send(envelope, {})


func is_ready() -> bool:
	return not _closed and _lobby != null and bool(_lobby.get("is_available"))


## The lobby knows the local role; the transport does not need to be told it.
## `is_host` is part of REQUIRED_LOBBY_METHODS so this can never silently
## degrade to "assume guest" against a lobby that does not expose it.
func _is_authority() -> bool:
	return _lobby != null and _lobby.has_method("is_host") and bool(_lobby.is_host())


func close() -> void:
	if _closed:
		return
	_closed = true
	if _lobby != null:
		if _lobby.event_received.is_connected(_on_lobby_event):
			_lobby.event_received.disconnect(_on_lobby_event)
		if _lobby.players_changed.is_connected(_on_players_changed):
			_lobby.players_changed.disconnect(_on_players_changed)


## Drop the next `count` outgoing envelopes of `kind`. Deterministic; no RNG.
func fault_drop_next(kind: String, count: int = 1) -> void:
	_fault_pending[kind] = int(_fault_pending.get(kind, 0)) + count


## Clear both levers and the counters.
func fault_reset() -> void:
	fault_drop_permille = 0
	fault_kinds = PackedStringArray()
	_fault_pending.clear()
	_fault_drops = 0


func _send(envelope: Dictionary, target: Dictionary) -> bool:
	if not is_ready():
		return false
	var kind := str(envelope.get(CouchEnvelope.KEY_KIND, ""))
	if _should_drop(kind):
		_fault_drops += 1
		return true
	var frame := CouchEnvelope.to_json_frame(envelope)
	_lobby.send_event(_event_name, frame, target)
	return true


func _should_drop(kind: String) -> bool:
	if not OS.is_debug_build():
		return false
	var pending := int(_fault_pending.get(kind, 0))
	if pending > 0:
		_fault_pending[kind] = pending - 1
		return true
	if fault_drop_permille <= 0:
		return false
	if not fault_kinds.is_empty() and not (kind in fault_kinds):
		return false
	return _fault_rng.randi_range(1, 1000) <= fault_drop_permille


func _set_fault_seed(value: int) -> void:
	fault_seed = value
	_fault_rng.seed = value


func _on_lobby_event(event: String, data: Variant, sender_user_id: String) -> void:
	if event != _event_name:
		return
	var result := CouchEnvelope.from_json_frame(data)
	var error := str(result.get("error", ""))
	if not error.is_empty():
		_reject_count += 1
		# Flood control: the tunnel has no size or rate bound, so a hostile peer
		# must not be able to fill the log by repeating the same malformed frame.
		if not _seen_reject_errors.has(error):
			_seen_reject_errors[error] = true
			var message := "CouchLobbyTransport: rejected frame from %s: %s" % [sender_user_id, error]
			if error == "oversized-body":
				# D13: the 256 KiB cap is a behaviour CLIFF -- a legitimately huge
				# snapshot silences the guest rather than degrading -- so it is
				# reported at error severity, not warning, and must stay visible.
				push_error(message)
			else:
				push_warning(message)
		return
	envelope_received.emit(result["envelope"], sender_user_id)


## Roster-derived link liveness. A rejoin (an id that was lost reappearing) is
## exactly the case where messages were lost across a boundary the sequence
## numbers cannot see, so it fires peer_ready AND transport_gap.
func _on_players_changed(players: Array) -> void:
	var current_ids: Dictionary = {}
	for player in players:
		var user_id := _player_user_id(player)
		if user_id.is_empty():
			continue
		current_ids[user_id] = true

	for user_id in _known_peer_ids:
		if not current_ids.has(user_id):
			_remember_lost(user_id)
			peer_lost.emit(user_id)

	for user_id in current_ids:
		if not _known_peer_ids.has(user_id):
			peer_ready.emit(user_id)
			if _recently_lost.has(user_id):
				_recently_lost.erase(user_id)
				transport_gap.emit(user_id, "peer-rejoined")

	_known_peer_ids = current_ids


func _remember_lost(user_id: String) -> void:
	if _recently_lost.has(user_id):
		return
	_recently_lost[user_id] = true
	while _recently_lost.size() > MAX_RECENTLY_LOST:
		_recently_lost.erase(_recently_lost.keys()[0])


static func _player_user_id(player: Variant) -> String:
	if player is Dictionary:
		var d: Dictionary = player
		if d.has("user_id"):
			return str(d["user_id"])
		if d.has("userId"):
			return str(d["userId"])
		return ""
	if player is Object:
		var uid: Variant = player.get("user_id")
		if uid != null:
			return str(uid)
		return ""
	return ""
