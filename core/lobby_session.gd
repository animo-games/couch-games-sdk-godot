## The standard driver for host-authoritative games (docs/connections.md).
##
## Picks the transport (WebRTC per guest, the lobby tunnel where WebRTC doesn't
## work), owns the CouchSession and a CouchConnection, polls them, re-evaluates
## on lobby changes and applies the baseline rules: a host answers each guest
## hello with a snapshot, and publishes one when its own session starts, so a
## guest that started first does not wait forever. CouchSession stays public for
## games that need finer control.
##
##   var net := CouchLobbySession.new()
##   net.snapshot_provider = func(): return {"revision": _revision, "board": _board}
##   add_child(net)
##   net.snapshot_received.connect(_apply_snapshot)
##   net.connection.state_changed.connect(_on_connection_state)   # after start()
##   net.start(CouchGames.lobby)
##
## What it does for the game, on top of CouchSession:
##   - the transport: CouchSessionTransport.pick() with `prefer` (PREFER_ROUTED
##     by default; Steam always gets its lobby wire). A refusal is reported on
##     transport_refused and nothing starts;
##   - the first evaluate() waits until the transport is ready (every guest
##     routed), or ready_timeout_ms, since a guest's hello retry recovers anyway;
##   - re-routing: when a WebRTC link dies for good (reroute_pending), the host
##     stops the session ("reroute"), moves the guest, and starts a new epoch;
##   - a CouchConnection, bound and polled, as `connection`;
##   - drop_in and pause_on_drop, below.
##
## Time: in the tree, _process calls poll(Time.get_ticks_msec()), also while
## the tree is paused (PROCESS_MODE_ALWAYS). A fixture that keeps the node out
## of the tree calls poll(now_ms) itself.
##
## Lives in core/, not netcode/, because it calls CouchSessionTransport.pick(),
## which names webrtc/ (see core/session_transport.gd).
class_name CouchLobbySession
extends Node

signal session_started(epoch: int, is_host: bool, local_slot: int, peer_id: String, peer_name: String)
signal session_stopped(reason: String)
signal snapshot_received(body: Dictionary)
signal intent_received(body: Dictionary, sender_id: String)
signal input_received(body: Dictionary, sender_id: String)
signal rejected(reason: String, sender_id: String)
signal transport_gap(peer_id: String, reason: String)
## Host: a guest asked for full state. The driver already answers it from
## snapshot_provider.
signal hello_received(sender_id: String)
## Host, more than one input slot: a guest took or freed an input slot.
signal player_joined(peer_id: String, slot: int)
signal player_left(peer_id: String, slot: int)
## Guest: the host moved this player's slot mid-session.
signal local_slot_changed(old_slot: int, new_slot: int)
## Guest: held intents that will never be sent (docs/connections.md).
signal held_intents_dropped(count: int, reason: String)
## This player can't play on this transport: pick() refused it, or the host
## refused its route (require_datagram and no WebRTC here). For an error that
## starts with "webrtc-blocked:", CouchWebRTCProbe.describe(<the rest>) gives a
## player-facing line.
signal transport_refused(error: String)
## pause_on_drop only: pause or resume the game. `reason` is PAUSE_RECONNECTING
## or PAUSE_PLAYER_AWAY while paused, "" when resumed.
signal pause_changed(paused: bool, reason: String)

const PAUSE_RECONNECTING := "reconnecting"
const PAUSE_PLAYER_AWAY := "player-away"
const DEFAULT_READY_TIMEOUT_MS := 5000

## Host only. Returns the full authoritative state, as a Dictionary, that is sent
## to each guest on hello, on host session start and after recovery.
var snapshot_provider: Callable

# --- set before start() --------------------------------------------------------

## The CouchSessionTransport preference. Every player in a lobby must use the
## same one, so ship it in the build.
var prefer: String = CouchSessionTransport.PREFER_ROUTED
## Never put a player on the lobby tunnel: a player who can't use WebRTC is
## refused (transport_refused) instead. For games that can't live with the
## tunnel's latency.
var require_datagram := false
## Drop-in, drop-out: set it when your game has both "Handles a guest leaving"
## and "Takes mid-game arrivals" on. A host whose last guest leaves keeps its
## session and world, and the next arrival joins it. Needs
## policy.max_input_players > 1.
var drop_in := false
## Pause while a player the game needs is missing: emits pause_changed. The
## host pauses while a guest with an input slot is away (after the platform's
## 10 quiet seconds) or its own connection is reconnecting; a guest pauses
## while its connection is reconnecting, which includes the host being away.
## The game applies the pause. Off by default: the host keeps playing.
var pause_on_drop := false
## The session policy (max_input_players, intent_hold_ms, ...). null = defaults.
var policy: CouchSessionPolicy = null
## How long the first evaluate() waits for every guest to be routed.
var ready_timeout_ms := DEFAULT_READY_TIMEOUT_MS
## The WebRTC preflight probe's bound (pick()'s probe_timeout_ms).
var probe_timeout_ms := CouchWebRTCProbe.DEFAULT_TIMEOUT_MS

# --- read-only -----------------------------------------------------------------

var session: CouchSession:
	get: return _session
## The transport in use: a CouchRoutedTransport under PREFER_ROUTED.
var transport: Object:
	get: return _transport
## The picked kind (CouchSessionTransport.KIND_*), or "injected".
var transport_kind: String:
	get: return _kind
## Created by start(); kept after stop() so its end state can still be read.
var connection: CouchConnection:
	get: return _connection
var paused: bool:
	get: return _paused
var pause_reason: String:
	get: return _pause_reason

var _lobby: Object
var _transport: Object
var _session: CouchSession
var _connection: CouchConnection
var _kind := ""
var _starting := false
var _generation := 0          # stop() during the pick discards its result
var _waiting_ready := false
var _ready_deadline_ms := 0
var _reroute_pending := false
var _now_ms := 0
var _polled := false
var _paused := false
var _pause_reason := ""
var _warned_no_provider := false


## Begin driving a session over `lobby`, defaulting to the CouchGames autoload's
## lobby. `transport_override` drives an already built transport instead of
## picking one. Does nothing if already started or starting. A coroutine: the
## pick may join signaling and run the WebRTC probe first.
func start(lobby: Object = null, transport_override: Object = null) -> void:
	if _session != null or _starting:
		return
	var sdk := _sdk()
	if lobby == null and sdk != null:
		lobby = sdk.get("lobby")
	if lobby == null:
		push_error("CouchLobbySession: no lobby to drive")
		return
	var picked_transport := transport_override
	var kind := "injected"
	if picked_transport == null:
		_starting = true
		var generation := _generation
		var webrtc: Variant = sdk.get("webrtc") if sdk != null else null
		var picked: Dictionary = await CouchSessionTransport.pick(lobby, webrtc, prefer, probe_timeout_ms, require_datagram)
		if generation != _generation:
			if picked.transport != null:
				picked.transport.close()
			return
		_starting = false
		if picked.transport == null:
			transport_refused.emit(str(picked.error))
			return
		picked_transport = picked.transport
		kind = str(picked.kind)
	_bind(lobby, picked_transport, kind)


## Ends the session and closes its transport. Safe to call repeatedly. The
## connection ends `left` and stays readable.
func stop() -> void:
	_generation += 1
	_starting = false
	if _session == null:
		return
	for sig in ["state_changed", "players_changed"]:
		if _lobby.has_signal(sig) and _lobby.is_connected(sig, _reevaluate):
			_lobby.disconnect(sig, _reevaluate)
	_session.stop("stopped")
	_transport.close()
	_session = null
	_transport = null
	_lobby = null
	_waiting_ready = false
	_reroute_pending = false
	# The session's "stopped" has already ended the connection (and lifted any
	# pause); close() lets go of the lobby.
	if _connection != null:
		_connection.close()


## True while a handshaken session is running for this peer.
func is_active() -> bool:
	return _session != null and _session.active


func is_host() -> bool:
	return is_active() and _session.is_host


## Host: publish the current state to every guest. Call after each accepted change.
func send_snapshot(body: Dictionary) -> bool:
	return _session != null and _session.broadcast_snapshot(body)


## Guest: ask the host to change shared state. Authority stays with the host.
func send_intent(body: Dictionary) -> bool:
	return _session != null and _session.send_intent(body)


func send_input(body: Dictionary) -> bool:
	return _session != null and _session.send_input(body)


## Drives the transport, the held first evaluate, re-routes, the session and
## the connection, in that order.
func poll(now_ms: int) -> void:
	_now_ms = now_ms
	_polled = true
	if _session == null:
		return
	_transport.poll(now_ms)
	if _session == null:
		return
	if _reroute_pending:
		_reroute_pending = false
		_apply_reroutes()
	if _waiting_ready:
		if _transport_ready() or now_ms >= _ready_deadline_ms:
			_waiting_ready = false
			_session.evaluate(now_ms)
	if _session == null:
		return
	_session.poll(now_ms)
	if _connection != null:
		_connection.poll(now_ms)


func _init() -> void:
	# The network keeps running while the game is paused, so a pause_on_drop
	# pause can end: the driver has to see the player come back.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	poll(Time.get_ticks_msec())


func _exit_tree() -> void:
	stop()


# --- internals -------------------------------------------------------------------

func _bind(lobby: Object, picked_transport: Object, kind: String) -> void:
	_lobby = lobby
	_transport = picked_transport
	_kind = kind
	var session_policy := policy if policy != null else CouchSessionPolicy.default_policy()
	if drop_in:
		if session_policy.max_input_players <= 1:
			push_warning("CouchLobbySession: drop_in needs policy.max_input_players > 1; a host left alone will still stop")
		session_policy.drop_in = true
	_session = CouchSession.new(lobby, _transport, session_policy)
	_session.hello_received.connect(_on_hello)
	_session.session_started.connect(_on_session_started)
	_session.session_stopped.connect(func(reason): session_stopped.emit(reason))
	_session.snapshot_received.connect(func(body): snapshot_received.emit(body))
	_session.intent_received.connect(func(body, sender): intent_received.emit(body, sender))
	_session.input_received.connect(func(body, sender): input_received.emit(body, sender))
	_session.rejected.connect(func(reason, sender): rejected.emit(reason, sender))
	_session.transport_gap.connect(func(peer, reason): transport_gap.emit(peer, reason))
	_session.player_joined.connect(func(peer, slot):
		player_joined.emit(peer, slot)
		_update_pause())
	_session.player_left.connect(func(peer, slot):
		player_left.emit(peer, slot)
		_update_pause())
	_session.local_slot_changed.connect(func(old_slot, new_slot): local_slot_changed.emit(old_slot, new_slot))
	_session.held_intents_dropped.connect(func(count, reason): held_intents_dropped.emit(count, reason))
	if _transport.has_signal("reroute_pending"):
		_transport.reroute_pending.connect(func(_peer: String) -> void: _reroute_pending = true)
	if _transport.has_signal("route_refused"):
		_transport.route_refused.connect(func(reason: String) -> void: transport_refused.emit(reason))
	for sig in ["state_changed", "players_changed"]:
		if lobby.has_signal(sig):
			lobby.connect(sig, _reevaluate)
	if _connection != null:
		remove_child(_connection)
		_connection.free()
	_connection = CouchConnection.new()
	add_child(_connection)
	# bind() marks the session bound: the standard driver never warns.
	_connection.bind(self, lobby)
	_connection.state_changed.connect(func(_s, _r): _update_pause())
	_connection.player_state_changed.connect(func(_u, _s): _update_pause())
	_waiting_ready = true
	_ready_deadline_ms = _clock() + ready_timeout_ms
	if _transport_ready():
		_waiting_ready = false
		_session.evaluate(_clock())


func _transport_ready() -> bool:
	return not _transport.has_method("is_ready") or bool(_transport.is_ready())


func _apply_reroutes() -> void:
	# A route never changes under a live epoch: end it, move, start a new one.
	_session.stop("reroute")
	_transport.apply_pending_reroutes()
	if not _waiting_ready:
		_session.evaluate(_now_ms)


func _reevaluate(_value: Variant = null) -> void:
	if _session != null and not _waiting_ready:
		_session.evaluate(_clock())


func _clock() -> int:
	return _now_ms if _polled else Time.get_ticks_msec()


func _on_hello(sender: String) -> void:
	hello_received.emit(sender)
	_send_snapshot()


func _on_session_started(epoch: int, is_host_role: bool, local_slot: int, peer_id: String, peer_name: String) -> void:
	session_started.emit(epoch, is_host_role, local_slot, peer_id, peer_name)
	# A guest that started first may stop retrying after the initial hello, so
	# the host also publishes a baseline when its own session starts.
	if is_host_role:
		_send_snapshot()


func _send_snapshot() -> void:
	if _session == null:
		return
	if not snapshot_provider.is_valid():
		if not _warned_no_provider:
			_warned_no_provider = true
			push_warning("CouchLobbySession: host has no snapshot_provider; guests will not receive a baseline")
		return
	var body: Variant = snapshot_provider.call()
	if body is Dictionary:
		_session.broadcast_snapshot(body)
	else:
		push_error("CouchLobbySession: snapshot_provider must return a Dictionary")


func _update_pause() -> void:
	var why := ""
	if pause_on_drop and _session != null and _connection != null:
		match _connection.state:
			CouchConnection.STATE_RECONNECTING:
				why = PAUSE_RECONNECTING
			CouchConnection.STATE_LIVE, CouchConnection.STATE_SYNCING:
				var slots: Dictionary = _session.slots
				for user_id in slots:
					if int(slots[user_id]) >= CouchSession.SLOT_HOST and _connection.get_player_state(user_id) == CouchConnection.PLAYER_AWAY:
						why = PAUSE_PLAYER_AWAY
						break
	_set_pause(why)


func _set_pause(why: String) -> void:
	var now_paused := not why.is_empty()
	if now_paused == _paused and why == _pause_reason:
		return
	_paused = now_paused
	_pause_reason = why
	pause_changed.emit(_paused, _pause_reason)


func _sdk() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("CouchGames") if tree != null else null
