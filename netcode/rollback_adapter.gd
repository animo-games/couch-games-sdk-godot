## CouchConnection states for a rollback game (the `rollback` profile in
## docs/plans/standard-connection-design.md; docs/connections.md).
##
## A rollback game doesn't run a CouchSession: two peers simulate the same world
## over a WebRTC mesh, and the rollback addon rebuilds a dropped link itself.
## This adapter reads that stack's own signals and presents them to a
## CouchConnection as a session, so a rollback game gets the same connection
## states, player states, overlay, log lines and end reasons as every other
## Couch game.
##
##   var adapter := CouchRollbackAdapter.new()
##   add_child(adapter)
##   adapter.bind(controller, connection, CouchGames.lobby)
##   adapter.connection.state_changed.connect(_on_connection_state)
##
## `controller` is the rollback addon's RollbackSessionController, `connection`
## the CouchWebRTCConnection it runs on (or null: the controller's `transport`).
## Both are read through signal names only, so the SDK takes no dependency on
## the rollback addon and this file names neither it nor webrtc/.
##
## The mapping:
##   controller.segment_started (the first)  -> live. Later segments are level
##                                               transitions: nothing changes.
##   link.peer_recovery_started              -> reconnecting (link-rebuild)
##   link.peer_recovered                     -> live
##   controller.segment_failed,
##   link.transport_failed                   -> ended: host-left when the other
##                                               player was the host and has left
##                                               the lobby, else connection-lost.
##                                               The raw reason is failure_reason.
## There is no snapshot to wait for, so a guest goes straight to live.
##
## Not covered yet: a player who reloads comes back to a session that has
## already failed (the rejoin hook is a later step), and a link that lands on
## a TCP relay is not reported.
class_name CouchRollbackAdapter
extends Node

## CouchConnection reads these three; snapshot_received is never emitted.
signal session_started(epoch: int, is_host: bool, local_slot: int, peer_id: String, peer_name: String)
signal session_stopped(reason: String)
signal snapshot_received(body: Dictionary)

## The stop reason while the rollback addon rebuilds the link.
const STOP_LINK_REBUILD := "link-rebuild"
## The stop reason for any rollback failure; failure_reason has the detail.
const STOP_SESSION_FAILED := "session-failed"

## Passed to the CouchConnection that bind() creates; set before bind().
var platform := ""
var hold_ms := 0
var overlay_enabled := true
var log_enabled := true

## CouchConnection reads this: a rollback session has no baseline snapshot.
var baseline_required: bool:
	get: return false
## The CouchConnection bind() created; kept after close() so its end can be read.
var connection: CouchConnection:
	get: return _connection
## The rollback stack's own words for the failure that ended the session.
var failure_reason: String:
	get: return _failure_reason

var _controller: Object = null
var _link: Object = null
var _lobby: Object = null
var _connection: CouchConnection = null
var _started := false
var _link_down := false
var _failed := false
var _failure_reason := ""
var _peer_id := ""
var _peer_name := ""
var _peer_was_host := false
var _now_ms := 0


func _init() -> void:
	# Like the overlay: keep reporting while a stalled game pauses the tree.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	poll(Time.get_ticks_msec())


func _exit_tree() -> void:
	_release()


## Starts reporting for `controller` over `link` (null: controller.transport)
## and `lobby`. A second bind() lets go of the first and starts a fresh
## connection.
func bind(controller: Object, link: Object, lobby: Object) -> void:
	_release()
	if _connection != null:
		remove_child(_connection)
		_connection.free()
	_controller = controller
	_link = link if link != null else controller.get("transport")
	_lobby = lobby
	_started = false
	_link_down = false
	_failed = false
	_failure_reason = ""
	_connect(_controller, "segment_started", _on_segment_started)
	_connect(_controller, "segment_failed", _on_failed)
	_connect(_link, "peer_recovery_started", _on_recovery_started)
	_connect(_link, "peer_recovered", _on_recovered)
	_connect(_link, "transport_failed", _on_failed)
	_connection = CouchConnection.new()
	_connection.platform = platform
	_connection.hold_ms = hold_ms
	_connection.overlay_enabled = overlay_enabled
	_connection.log_enabled = log_enabled
	add_child(_connection)
	_connection.poll(_now_ms)
	_connection.bind(self, lobby)


## The local player is done: the connection ends `left`, and every signal is
## released.
func close() -> void:
	_release()
	if _connection != null:
		_connection.close()


func poll(now_ms: int) -> void:
	_now_ms = now_ms
	if _connection != null:
		_connection.poll(now_ms)


# --- the rollback stack's facts ---------------------------------------------------

func _on_segment_started(_seg_index: int, _session: Object) -> void:
	if _started or _failed:
		return
	_started = true
	_remember_peer()
	_emit_started()


func _on_recovery_started(_peer: String, _net_id: int) -> void:
	if not _started or _failed or _link_down:
		return
	_link_down = true
	session_stopped.emit(STOP_LINK_REBUILD)


func _on_recovered(_peer: String, _net_id: int, _duration_ms: int) -> void:
	if not _link_down or _failed:
		return
	_link_down = false
	_emit_started()


func _on_failed(reason: String) -> void:
	if _failed:
		return
	_failed = true
	_failure_reason = reason
	if not _started:
		_connection.fail()
		return
	var host_gone := _peer_was_host and not _in_roster(_peer_id)
	session_stopped.emit("host-left" if host_gone else STOP_SESSION_FAILED)


# --- helpers ---------------------------------------------------------------------

func _emit_started() -> void:
	var host := _is_host()
	session_started.emit(0, host, 0 if host else 1, _peer_id, _peer_name)


## The other player, read from the lobby at the first segment: the rollback
## profile is one local player and one remote one.
func _remember_peer() -> void:
	var me := _field(_lobby.get_me(), "user_id")
	for row in _lobby.get_players():
		var user_id := _field(row, "user_id")
		if user_id.is_empty() or user_id == me:
			continue
		_peer_id = user_id
		_peer_name = _field(row, "username")
		_peer_was_host = _field(row, "role") == "host"
		return


func _in_roster(user_id: String) -> bool:
	for row in _lobby.get_players():
		if _field(row, "user_id") == user_id:
			return true
	return false


func _is_host() -> bool:
	return _lobby != null and bool(_lobby.is_host())


func _connect(source: Object, sig: String, target: Callable) -> void:
	if source != null and source.has_signal(sig) and not source.is_connected(sig, target):
		source.connect(sig, target)


func _release() -> void:
	for pair in [[_controller, "segment_started", _on_segment_started], [_controller, "segment_failed", _on_failed],
			[_link, "peer_recovery_started", _on_recovery_started], [_link, "peer_recovered", _on_recovered],
			[_link, "transport_failed", _on_failed]]:
		var source: Object = pair[0]
		if source != null and is_instance_valid(source) and source.has_signal(pair[1]) and source.is_connected(pair[1], pair[2]):
			source.disconnect(pair[1], pair[2])
	_controller = null
	_link = null


static func _field(row: Variant, key: String) -> String:
	if row is Dictionary:
		var d: Dictionary = row
		var value: Variant = d.get(key, d.get("userId") if key == "user_id" else null)
		return "" if value == null else str(value)
	if row is Object:
		var value: Variant = (row as Object).get(key)
		return "" if value == null else str(value)
	return ""
