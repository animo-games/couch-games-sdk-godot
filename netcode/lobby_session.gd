## Opt-in lobby session driver for the common host/guest case.
##
## Owns the lobby transport and CouchSession, polls them, re-evaluates on lobby
## changes and applies the baseline rules: a host answers each guest hello with
## a snapshot, and publishes one when its own session starts, so a guest that
## started first does not wait forever. CouchSession stays public for games that
## need finer control.
##
##   var net := CouchLobbySession.new()
##   add_child(net)
##   net.snapshot_provider = func(): return {"revision": _revision, "board": _board}
##   net.snapshot_received.connect(_apply_snapshot)
##   net.start(CouchGames.lobby)
class_name CouchLobbySession
extends Node

signal session_started(epoch: int, is_host: bool, local_slot: int, peer_id: String, peer_name: String)
signal session_stopped(reason: String)
signal snapshot_received(body: Dictionary)
signal intent_received(body: Dictionary, sender_id: String)
signal input_received(body: Dictionary, sender_id: String)
signal rejected(reason: String, sender_id: String)
signal transport_gap(peer_id: String, reason: String)

## Host only. Returns the full authoritative state, as a Dictionary, that is sent
## to each guest on hello, on host session start and after recovery.
var snapshot_provider: Callable

var session: CouchSession:
	get: return _session

var _lobby: Object
var _transport: CouchLobbyTransport
var _session: CouchSession
var _warned_no_provider := false


## Begin driving a session over `lobby`, defaulting to the CouchGames autoload's
## lobby. Does nothing if already started.
func start(lobby: Object = null) -> void:
	if _session != null:
		return
	if lobby == null:
		lobby = get_node_or_null("/root/CouchGames")
		lobby = lobby.lobby if lobby != null else null
	if lobby == null:
		push_error("CouchLobbySession: no lobby to drive")
		return
	_lobby = lobby
	_transport = CouchLobbyTransport.new(lobby)
	_session = CouchSession.new(lobby, _transport)
	_session.hello_received.connect(func(_sender): _send_snapshot())
	_session.session_started.connect(_on_session_started)
	_session.session_stopped.connect(func(reason): session_stopped.emit(reason))
	_session.snapshot_received.connect(func(body): snapshot_received.emit(body))
	_session.intent_received.connect(func(body, sender): intent_received.emit(body, sender))
	_session.input_received.connect(func(body, sender): input_received.emit(body, sender))
	_session.rejected.connect(func(reason, sender): rejected.emit(reason, sender))
	_session.transport_gap.connect(func(peer, reason): transport_gap.emit(peer, reason))
	lobby.state_changed.connect(_reevaluate)
	lobby.players_changed.connect(_reevaluate)
	_session.evaluate(Time.get_ticks_msec())


## Ends the session and closes its transport. Safe to call repeatedly.
func stop() -> void:
	if _session == null:
		return
	if _lobby.state_changed.is_connected(_reevaluate):
		_lobby.state_changed.disconnect(_reevaluate)
	if _lobby.players_changed.is_connected(_reevaluate):
		_lobby.players_changed.disconnect(_reevaluate)
	_session.stop("stopped")
	_transport.close()
	_session = null
	_transport = null
	_lobby = null


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


func _process(_delta: float) -> void:
	if _session == null:
		return
	_transport.poll(Time.get_ticks_msec())
	_session.poll(Time.get_ticks_msec())


func _exit_tree() -> void:
	stop()


func _reevaluate(_value: Variant = null) -> void:
	if _session != null:
		_session.evaluate(Time.get_ticks_msec())


func _on_session_started(epoch: int, is_host_role: bool, local_slot: int, peer_id: String, peer_name: String) -> void:
	session_started.emit(epoch, is_host_role, local_slot, peer_id, peer_name)
	# A guest that started first may stop retrying after the initial hello, so
	# the host also publishes a baseline when its own session starts.
	if is_host_role:
		_send_snapshot()


func _send_snapshot() -> void:
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
