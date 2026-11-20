## One connection state for every Couch game: what the game and its players are
## told when a connection drops, a player is away, a session resyncs or a match
## ends. It reads a session and the lobby and never sends anything, so it works
## over any transport. See docs/connections.md.
##
##   var connection := CouchConnection.new()
##   add_child(connection)
##   connection.bind(session, CouchGames.lobby)   # a CouchSession or CouchLobbySession
##   connection.state_changed.connect(_on_connection_state)
##
## Connection state, for the local player:
##   connecting   bound, no session yet
##   syncing      a guest's session started; waiting for the host's snapshot
##   live         playing. A host is live from its session start, and stays
##                live while guests come and go: its world runs on
##   reconnecting the link or the session is being rebuilt; `reason` says why
##   ended        over; `end_reason` is one of END_REASONS
##
## Player state, for every other player: connected, away (only after
## AWAY_QUIET_MS without them, as the platform does), gone.
##
## On the web the platform draws the reconnecting, away and left notices itself
## (platform decision 0078), so the overlay draws nothing there. The states are
## reported everywhere.
##
## Time is explicit, like CouchSession: poll(now_ms) drives the quiet stretch,
## the overlay delay and the hold. In the tree, _process calls it every frame.
## Facts that arrive between polls are stamped with the last poll's time.
class_name CouchConnection
extends Node

signal state_changed(state: String, reason: String)
signal player_state_changed(user_id: String, state: String)

const STATE_CONNECTING := "connecting"
const STATE_SYNCING := "syncing"
const STATE_LIVE := "live"
const STATE_RECONNECTING := "reconnecting"
const STATE_ENDED := "ended"

const PLAYER_CONNECTED := "connected"
const PLAYER_AWAY := "away"
const PLAYER_GONE := "gone"

const END_HOST_LEFT := "host-left"
const END_CONNECTION_LOST := "connection-lost"
const END_RECONNECT_TIMED_OUT := "reconnect-timed-out"
const END_LEFT := "left"
const END_REASONS := [END_HOST_LEFT, END_CONNECTION_LOST, END_RECONNECT_TIMED_OUT, END_LEFT]

## Reconnecting reasons besides the session's own stop reasons.
const REASON_HOST_AWAY := "host-away"
const REASON_OWN_CONNECTION := "own-connection"

## Nothing about another player being away shows for this long (0078).
const AWAY_QUIET_MS := 10_000
## A resync shorter than this never reaches the overlay.
const OVERLAY_DELAY_MS := 1000

## Guest session stops that mean "the session is being rebuilt", not "over".
const RESYNC_STOPS := ["link-reset", "host-restarted", "steam-link-gap", "role-changed"]
## Host session stops that leave a host's world running. "reroute" is the
## driver's stop before CouchRoutedTransport.apply_pending_reroutes().
const HOST_STAYS_LIVE_STOPS := ["roster-too-small", "authorized-peer-left", "reroute"]

## The backend this runs on: "web", "steam", "local", "mock" or "". Read from
## the CouchGames autoload at bind() when empty. "web" means the platform draws
## its own connection notices.
var platform := ""
## How long `reconnecting` may last before ending reconnect-timed-out. 0 picks
## the platform's: 65 s on the web (its 60 s away limit, plus time for its own
## end to arrive), 120 s on Steam (its recovery window), 60 s elsewhere.
var hold_ms := 0
## The built-in overlay (CouchConnectionOverlay). Turn it off to draw your own
## from state_changed, player_state_changed, overlay_lines() and describe_end().
var overlay_enabled := true
## One line per state change on the output.
var log_enabled := true

var state: String:
	get: return _state
var reason: String:
	get: return _reason
var end_reason: String:
	get: return _end_reason if _state == STATE_ENDED else ""
var is_host: bool:
	get: return _is_host
var platform_ui: bool:
	get: return platform == "web"

var _state := STATE_CONNECTING
var _reason := ""
var _end_reason := ""
var _is_host := false
var _has_baseline := false
var _session_up := false
var _own_link_down := false
var _since_ms := 0                 # when _state was entered
var _now_ms := 0
var _session: Object = null
var _lobby: Object = null
var _host_id := ""
var _host_name := ""
var _players: Dictionary = {}      # user_id -> {state, name, quiet_since (-1 when present)}
var _overlay: Node = null
var _seeding := false


func _process(_delta: float) -> void:
	poll(Time.get_ticks_msec())


func _ready() -> void:
	if overlay_enabled and not platform_ui and _overlay == null:
		_overlay = preload("res://addons/couch-games-sdk/netcode/connection_overlay.gd").new()
		_overlay.connection = self
		add_child(_overlay)


func _exit_tree() -> void:
	_release()


## Starts reporting for `session` (CouchSession, CouchLobbySession, or anything
## with their session_started / session_stopped / snapshot_received signals)
## and `lobby` (CouchLobby or a roster with players_changed and get_players();
## state_changed is read when present). `lobby` may be null: no player states.
func bind(session: Object, lobby: Object = null) -> void:
	_release()
	if platform.is_empty():
		platform = _detect_platform()
	if hold_ms <= 0:
		hold_ms = {"web": 65_000, "steam": 120_000}.get(platform, 60_000)
	_session = session
	_lobby = lobby
	var inner: Variant = session.get("session") if session.get("session") != null else session
	if inner is CouchSession:
		(inner as CouchSession).mark_connection_bound()
	session.session_started.connect(_on_session_started)
	session.session_stopped.connect(_on_session_stopped)
	session.snapshot_received.connect(_on_snapshot)
	if lobby != null:
		lobby.players_changed.connect(_on_players)
		if lobby.has_signal("state_changed"):
			lobby.state_changed.connect(_on_lobby_state)
		# The roster as it stands is the starting point, not a list of arrivals.
		_seeding = true
		_on_players(lobby.get_players())
		_seeding = false
	_since_ms = _now_ms
	_log("bound (%s, hold %d ms)" % [platform if not platform.is_empty() else "no backend", hold_ms])


## Ends with `left`: the local player is done. Lets go of the session and lobby.
func close() -> void:
	_end(END_LEFT)
	_release()


func poll(now_ms: int) -> void:
	_now_ms = now_ms
	if _state == STATE_RECONNECTING and now_ms - _since_ms >= hold_ms:
		_end(END_RECONNECT_TIMED_OUT)
	for user_id in _players:
		var p: Dictionary = _players[user_id]
		if p["state"] == PLAYER_CONNECTED and p["quiet_since"] >= 0 and now_ms - int(p["quiet_since"]) >= AWAY_QUIET_MS:
			_set_player(user_id, PLAYER_AWAY)


func get_player_state(user_id: String) -> String:
	if _players.has(user_id):
		return _players[user_id]["state"]
	return PLAYER_GONE


## {user_id: state} for every other player still tracked.
func get_players_state() -> Dictionary:
	var out := {}
	for user_id in _players:
		out[user_id] = _players[user_id]["state"]
	return out


## The lines the built-in overlay shows now; empty when it shows nothing. Always
## empty on the web, where the platform draws these notices.
func overlay_lines() -> Array:
	if platform_ui:
		return []
	if _state == STATE_ENDED:
		return [describe_end(_end_reason, _host_name)]
	var lines: Array = []
	if _state == STATE_RECONNECTING and _now_ms - _since_ms >= OVERLAY_DELAY_MS:
		lines.append("Reconnecting…")
	for user_id in _players:
		var p: Dictionary = _players[user_id]
		if p["state"] == PLAYER_AWAY:
			lines.append("%s's away" % _name_or(p["name"], "A player"))
	return lines


## Player-facing text for an end reason, in the platform's words. `host_name`
## fills host-left; an unknown reason reads as connection-lost.
static func describe_end(end: String, host_name: String = "") -> String:
	match end:
		END_HOST_LEFT:
			return "%s left the game" % _name_or(host_name, "The host")
		END_RECONNECT_TIMED_OUT:
			return "Couldn't reconnect in time"
		END_LEFT:
			return "You left the game"
		_:
			return "Lost the connection to the game"


# --- facts ---------------------------------------------------------------------

func _on_session_started(_epoch: int, is_host_role: bool, _slot: int, peer_id: String, peer_name: String) -> void:
	_is_host = is_host_role
	_session_up = true
	if not is_host_role:
		_host_id = _host_id if not _host_id.is_empty() else _host_from_roster()
		if _host_id.is_empty():
			_host_id = peer_id
		if not peer_name.is_empty():
			_host_name = peer_name
		_has_baseline = false
	_settle()


func _on_snapshot(_body: Dictionary) -> void:
	_has_baseline = true
	_settle()


func _on_session_stopped(stop_reason: String) -> void:
	if _state == STATE_ENDED or _state == STATE_CONNECTING:
		return
	_session_up = false
	if _is_host and stop_reason in HOST_STAYS_LIVE_STOPS:
		_session_up = true   # the host's world runs on; the next start finds it live
		return
	if stop_reason in RESYNC_STOPS:
		_enter(STATE_RECONNECTING, stop_reason)
	elif stop_reason == "host-left" or (not _is_host and stop_reason == "roster-too-small"):
		if platform_ui:
			# On the web a host who left ends the room and unloads the game, so
			# a game still running was left by a host that is only away.
			_enter(STATE_RECONNECTING, REASON_HOST_AWAY if stop_reason == "host-left" else stop_reason)
		elif stop_reason == "host-left":
			_end(END_HOST_LEFT)
		else:
			_end(END_CONNECTION_LOST)
	elif stop_reason == "stopped":
		_end(END_LEFT)
	else:
		_end(END_CONNECTION_LOST)


func _on_lobby_state(lobby_state: String) -> void:
	if _state == STATE_ENDED:
		return
	match lobby_state:
		"reconnecting":
			if _state != STATE_CONNECTING:
				_own_link_down = true
				_enter(STATE_RECONNECTING, REASON_OWN_CONNECTION)
		"joined":
			if _own_link_down:
				_own_link_down = false
				_settle()
		"failed":
			_end(END_CONNECTION_LOST)
		"leaving":
			_end(END_LEFT)


func _on_players(rows: Array) -> void:
	var my_id := _local_id()
	var present := {}
	for row in rows:
		var user_id := _field(row, "user_id", "userId")
		if user_id.is_empty() or user_id == my_id:
			continue
		present[user_id] = true
		var name := _field(row, "username", "username")
		var away := _field(row, "status", "status") == "disconnected"
		if not _players.has(user_id):
			_players[user_id] = {"state": "", "name": name, "quiet_since": -1}
			_set_player(user_id, PLAYER_CONNECTED)
		var p: Dictionary = _players[user_id]
		p["name"] = name if not name.is_empty() else p["name"]
		if away:
			if p["quiet_since"] < 0:
				p["quiet_since"] = _now_ms
		else:
			p["quiet_since"] = -1
			if p["state"] == PLAYER_AWAY:
				_set_player(user_id, PLAYER_CONNECTED)
	for user_id in _players.keys():
		if present.has(user_id):
			continue
		var p: Dictionary = _players[user_id]
		if platform_ui and not _is_host and user_id == _host_id and _state != STATE_ENDED:
			# 0078: an away host is left out of the roster, not marked.
			if p["quiet_since"] < 0:
				p["quiet_since"] = _now_ms
			continue
		_players.erase(user_id)
		player_state_changed.emit(user_id, PLAYER_GONE)
		_log("%s is %s" % [user_id, PLAYER_GONE])


# --- state ---------------------------------------------------------------------

## The state the facts point to when nothing is wrong.
func _settle() -> void:
	if _state == STATE_ENDED or _own_link_down or not _session_up:
		return
	_enter(STATE_LIVE if _is_host or _has_baseline else STATE_SYNCING, "")


func _enter(new_state: String, new_reason: String) -> void:
	if _state == STATE_ENDED or (_state == new_state and _reason == new_reason):
		return
	var old := _state
	_state = new_state
	_reason = new_reason
	_since_ms = _now_ms
	_log("%s -> %s%s" % [old, new_state, " (%s)" % new_reason if not new_reason.is_empty() else ""])
	state_changed.emit(new_state, new_reason)


func _end(end: String) -> void:
	if _state == STATE_ENDED:
		return
	_end_reason = end
	_enter(STATE_ENDED, end)


func _set_player(user_id: String, player_state: String) -> void:
	var p: Dictionary = _players[user_id]
	if p["state"] == player_state:
		return
	p["state"] = player_state
	if _seeding:
		return
	player_state_changed.emit(user_id, player_state)
	_log("%s is %s" % [user_id, player_state])


func _release() -> void:
	if _session != null:
		for pair in [["session_started", _on_session_started], ["session_stopped", _on_session_stopped], ["snapshot_received", _on_snapshot]]:
			if _session.is_connected(pair[0], pair[1]):
				_session.disconnect(pair[0], pair[1])
	if _lobby != null:
		if _lobby.is_connected("players_changed", _on_players):
			_lobby.disconnect("players_changed", _on_players)
		if _lobby.has_signal("state_changed") and _lobby.is_connected("state_changed", _on_lobby_state):
			_lobby.disconnect("state_changed", _on_lobby_state)
	_session = null
	_lobby = null


func _log(line: String) -> void:
	if log_enabled:
		print("CouchConnection: " + line)


func _local_id() -> String:
	if _lobby == null or not _lobby.has_method("get_me"):
		return ""
	return _field(_lobby.get_me(), "user_id", "userId")


func _host_from_roster() -> String:
	if _lobby == null or not _lobby.has_method("get_players"):
		return ""
	for row in _lobby.get_players():
		if _field(row, "role", "role") == "host":
			return _field(row, "user_id", "userId")
	return ""


func _detect_platform() -> String:
	var tree := Engine.get_main_loop() as SceneTree
	var sdk: Node = tree.root.get_node_or_null("CouchGames") if tree != null else null
	if sdk == null:
		return ""
	return str(sdk.get("backend_name"))


static func _field(row: Variant, key: String, alt: String) -> String:
	if row is Dictionary:
		var d: Dictionary = row
		var value: Variant = d.get(key, d.get(alt))
		return "" if value == null else str(value)
	if row is Object:
		var value: Variant = row.get(key)
		return "" if value == null else str(value)
	return ""


static func _name_or(name: String, fallback: String) -> String:
	return name if not name.is_empty() else fallback
