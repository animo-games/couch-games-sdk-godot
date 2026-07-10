# Local-relay backend: lets two or more locally running instances of the game
# form a REAL lobby over a loopback WebSocket, so multiplayer logic can be
# tested across separate processes (Debug > Run Multiple Instances) instead of
# only against overlay-faked players.
#
# Role is decided automatically: the first instance to bind
# couch_games/local/port becomes the host; later instances find the port taken
# and join it as guests. Override per instance with the user args
# `--couch-role=host` / `--couch-role=guest` (Debug > Customize Run Instances).
#
# The host relays with the same semantics as the platform's signaling server:
# senderUserId is stamped from the connection (no impersonation), target
# userId/role conditions AND together, and nothing echoes back to its sender.
#
# Extends the mock backend, so classic verbs (saves/stats/metadata) and the
# debug overlay keep working — overlay-faked players on the host are part of
# the shared roster and visible to real guest instances too.
class_name CouchGamesLocalBackend
extends CouchGamesMockBackend

const _PORT_SETTING := "couch_games/local/port"
const DEFAULT_PORT := 8974
# How long a joining instance waits for the host's handshake + first roster.
const _JOIN_TIMEOUT_MS := 3000
# How long the host tolerates an accepted socket that never sends local-join.
const _REGISTER_TIMEOUT_MS := 5000

var _port: int = DEFAULT_PORT
var _server: TCPServer  # host role
var _guest_ws: WebSocketPeer  # guest role: the connection to the host
var _peers: Dictionary = {}  # host role: user_id -> WebSocketPeer (real guests)
var _pending: Array = []  # host role: accepted sockets awaiting local-join
var _joined := false  # guest role: first lobby-update received


func initialize() -> void:
	await super.initialize()
	_port = int(ProjectSettings.get_setting(_PORT_SETTING, DEFAULT_PORT))
	var role_override := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--couch-role="):
			role_override = arg.get_slice("=", 1)
	if role_override != "guest" and _try_listen():
		print("CouchGames SDK: local lobby hosting on ws://127.0.0.1:%d" % _port)
		return
	if role_override != "host" and await _try_join():
		print("CouchGames SDK: joined local lobby on port %d as %s" % [_port, local_user_id])
		return
	push_warning("CouchGames SDK: no local lobby on port %d — running as solo mock host" % _port)


func get_network_status() -> String:
	if _server:
		return "hosting ws://127.0.0.1:%d — %d instance(s) connected" % [_port, _peers.size()]
	if _guest_ws:
		return "guest of ws://127.0.0.1:%d" % _port
	return "solo (no local lobby)"


func _exit_tree() -> void:
	if _guest_ws:
		_guest_ws.close()
	for user_id in _peers:
		_peers[user_id].close()
	if _server:
		_server.stop()


# ────────────────────────────────────────────────
# Role setup
# ────────────────────────────────────────────────

func _try_listen() -> bool:
	_server = TCPServer.new()
	if _server.listen(_port, "127.0.0.1") != OK:
		_server = null
		return false
	return true


func _try_join() -> bool:
	local_role = "guest"
	# Unique per instance — the host dedups connections by userId.
	local_user_id = "local-%d-%04x" % [OS.get_process_id(), randi() & 0xFFFF]
	_seed_local_player()
	_guest_ws = WebSocketPeer.new()
	if _guest_ws.connect_to_url("ws://127.0.0.1:%d" % _port) != OK:
		return _join_failed()

	var deadline := Time.get_ticks_msec() + _JOIN_TIMEOUT_MS
	while _guest_ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		if Time.get_ticks_msec() > deadline or _guest_ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			return _join_failed()
		_guest_ws.poll()
		await get_tree().process_frame

	_send(_guest_ws, {
		"type": "local-join",
		"userId": local_user_id,
		"username": str(ProjectSettings.get_setting(_USERNAME_SETTING, "Player 1")),
	})

	# Wait for the first roster push so is_host()/get_players() are settled by
	# the time the game's `await CouchGames.init()` returns.
	while not _joined:
		if Time.get_ticks_msec() > deadline:
			return _join_failed()
		_guest_ws.poll()
		if _guest_ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			return _join_failed()
		while _guest_ws.get_available_packet_count() > 0:
			_handle_guest_message(_read_ws_json(_guest_ws))
		await get_tree().process_frame
	return true


func _join_failed() -> bool:
	if _guest_ws:
		_guest_ws.close()
		_guest_ws = null
	local_role = "host"
	local_user_id = LOCAL_USER_ID
	_seed_local_player()
	return false


# ────────────────────────────────────────────────
# Per-frame socket pumping
# ────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if _server:
		_process_host()
	elif _guest_ws:
		_process_guest()


func _process_host() -> void:
	while _server.is_connection_available():
		var ws := WebSocketPeer.new()
		if ws.accept_stream(_server.take_connection()) == OK:
			_pending.append({"ws": ws, "since": Time.get_ticks_msec()})

	for i in range(_pending.size() - 1, -1, -1):
		var entry: Dictionary = _pending[i]
		var ws: WebSocketPeer = entry.ws
		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED \
				or Time.get_ticks_msec() - entry.since > _REGISTER_TIMEOUT_MS:
			_pending.remove_at(i)
		elif state == WebSocketPeer.STATE_OPEN and ws.get_available_packet_count() > 0:
			var msg = _read_ws_json(ws)
			if msg is Dictionary and msg.get("type") == "local-join":
				_register_guest(ws, msg)
			_pending.remove_at(i)

	for user_id in _peers.keys():
		var ws: WebSocketPeer = _peers[user_id]
		ws.poll()
		match ws.get_ready_state():
			WebSocketPeer.STATE_OPEN:
				while ws.get_available_packet_count() > 0:
					_handle_host_message(user_id, _read_ws_json(ws))
			WebSocketPeer.STATE_CLOSED:
				_peers.erase(user_id)
				super.remove_player(user_id)


func _process_guest() -> void:
	_guest_ws.poll()
	match _guest_ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			while _guest_ws.get_available_packet_count() > 0:
				_handle_guest_message(_read_ws_json(_guest_ws))
		WebSocketPeer.STATE_CLOSED:
			push_warning("CouchGames SDK: local lobby host disconnected")
			_guest_ws = null
			_seed_local_player()  # keep running with a roster of just ourselves


# ────────────────────────────────────────────────
# Host: registration, routing, relay
# ────────────────────────────────────────────────

func _register_guest(ws: WebSocketPeer, msg: Dictionary) -> void:
	var user_id := str(msg.get("userId", ""))
	if user_id.is_empty() or _find_player(user_id) != null:
		ws.close(1008, "Duplicate or invalid userId")
		return
	_peers[user_id] = ws
	_players.append({
		"userId": user_id,
		"username": _dedup_username(str(msg.get("username", "Guest"))),
		"role": "guest",
		"status": "lobby",
		"experienceId": null,
		"controllerSlot": _lowest_free_slot(),
		"ping": 1,
	})
	_emit_players()


func _handle_host_message(sender_id: String, msg: Variant) -> void:
	if msg is Dictionary and msg.get("type") == "lobby-tunnel-event":
		var target: Dictionary = msg.get("target") if msg.get("target") is Dictionary else {}
		# senderUserId is stamped from the connection, like the real server —
		# a guest can't impersonate anyone.
		_route_event(str(msg.get("event", "")), msg.get("payload"), sender_id, target)


## Host-side router with server semantics: the sender is excluded, target
## conditions AND together. Delivers locally, relays to real guests over the
## wire, and logs the attempt for the overlay.
func _route_event(event: String, payload: Variant, sender_id: String, target: Dictionary) -> void:
	var delivered: Array = []
	var to_local := false
	for player in _players:
		var uid := str(player.get("userId", ""))
		if uid == sender_id:
			continue
		if not _target_matches(player, target):
			continue
		delivered.append(uid)
		if uid == local_user_id:
			to_local = true
		elif _peers.has(uid):
			_send(_peers[uid], {
				"type": "lobby-tunnel-event",
				"event": event,
				"payload": payload,
				"senderUserId": sender_id,
			})
	_log_event("in" if to_local else "out", event, payload, sender_id, target, delivered)
	if to_local:
		_deliver_local(event, payload, sender_id)


# Roster changes on the host are pushed to every connected instance.
func _emit_players() -> void:
	super._emit_players()
	if _server:
		_broadcast({"type": "lobby-update", "players": _round_trip(_players)})


# ────────────────────────────────────────────────
# Guest: incoming messages
# ────────────────────────────────────────────────

func _handle_guest_message(msg: Variant) -> void:
	if not (msg is Dictionary):
		return
	match str(msg.get("type", "")):
		"lobby-update":
			var players = msg.get("players")
			if players is Array:
				_players = players
				_joined = true
				super._emit_players()
		"lobby-tunnel-event":
			var event := str(msg.get("event", ""))
			var sender := str(msg.get("senderUserId", ""))
			_log_event("in", event, msg.get("payload"), sender, {}, [local_user_id])
			_deliver_local(event, msg.get("payload"), sender)


# ────────────────────────────────────────────────
# Overrides: send/simulate/roster control
# ────────────────────────────────────────────────

func lobby_send_event(event: String, data: Variant, target: Dictionary) -> void:
	var payload: Variant = _round_trip(data)
	if _server:
		_route_event(event, payload, local_user_id, target)
	elif _guest_ws and _guest_ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send(_guest_ws, {
			"type": "lobby-tunnel-event",
			"event": event,
			"payload": payload,
			"target": target,
		})
		_log_event("out", event, payload, local_user_id, target, ["(via host)"])
	else:
		super.lobby_send_event(event, data, target)


func simulate_event(event: String, data: Variant, sender_user_id: String, target: Dictionary = {}) -> void:
	if _guest_ws:
		push_warning("CouchGames mock: only the host instance can simulate events")
		return
	if _server:
		_route_event(event, _round_trip(data), sender_user_id, target)
	else:
		super.simulate_event(event, data, sender_user_id, target)


func add_guest(username: String = "") -> String:
	if _guest_ws:
		push_warning("CouchGames mock: only the host instance can modify the roster")
		return ""
	return super.add_guest(username)


func remove_player(user_id: String) -> void:
	if _guest_ws:
		push_warning("CouchGames mock: only the host instance can modify the roster")
		return
	if _peers.has(user_id):
		_peers[user_id].close(1008, "Kicked by host")
		_peers.erase(user_id)
	super.remove_player(user_id)


func set_player_status(user_id: String, status: String) -> void:
	if _guest_ws:
		push_warning("CouchGames mock: only the host instance can modify the roster")
		return
	super.set_player_status(user_id, status)


# ────────────────────────────────────────────────
# Wire helpers
# ────────────────────────────────────────────────

func _send(ws: WebSocketPeer, msg: Dictionary) -> void:
	ws.send_text(JSON.stringify(msg))


func _read_ws_json(ws: WebSocketPeer) -> Variant:
	return JSON.parse_string(ws.get_packet().get_string_from_utf8())


func _broadcast(msg: Dictionary) -> void:
	for user_id in _peers:
		var ws: WebSocketPeer = _peers[user_id]
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			_send(ws, msg)


func _find_player(user_id: String) -> Variant:
	for player in _players:
		if str(player.get("userId", "")) == user_id:
			return player
	return null


func _dedup_username(username: String) -> String:
	var taken := {}
	for player in _players:
		taken[str(player.get("username", ""))] = true
	if not taken.has(username):
		return username
	var n := 2
	while taken.has("%s (%d)" % [username, n]):
		n += 1
	return "%s (%d)" % [username, n]
