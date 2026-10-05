## Optional runtime-loaded backend; production calls live exclusively in steam_bridge.
extends CouchGamesBackend
const _Achievements := preload("res://addons/couch-games-sdk/steam/steam_achievements.gd")
const _Events := preload("res://addons/couch-games-sdk/steam/steam_events.gd")
var bridge: Node # Inject before initialize() in fixtures.
var catalog: Dictionary = {}
var operation_timeout_ms := 10000
var metadata_timeout_ms := 3000
var max_event_bytes := _Events.MAX_BYTES
var receive_budget := 64
var game_id := ""
var protocol_version := "1"
var content_version := "1"
var state := "idle"
var lobby_id := ""
var _authority := ""
var _token := ""
var _players: Array = []
var _members: Array = []
var _slots: Dictionary = {}
var _generation := 0
var _operation: Dictionary = {}
var _awards: Node
var _active := false
var _closed := false
var _pinned_account := ""
var _launch_invite := ""

func initialize() -> void:
	if _closed or _active:
		return
	if OS.has_feature("web"):
		initialization_error = "Steam is unsupported on Web"
		return
	if bridge == null:
		bridge = load("res://addons/couch-games-sdk/steam/steam_bridge.gd").new()
	bridge.name = "SteamBridge"
	if bridge.get_parent() == null:
		add_child(bridge)
	bridge.request_entered.connect(_on_entered)
	bridge.roster_changed.connect(_on_roster_changed)
	bridge.join_requested.connect(_on_invite)
	bridge.peer_requested.connect(_on_peer_request)
	bridge.peer_failed.connect(_on_peer_failure)
	bridge.connection_changed.connect(_on_connection_changed)
	var response: Dictionary = await bridge.initialize(int(ProjectSettings.get_setting("couch_games/steam/app_id", 0)))
	if _closed:
		bridge.shutdown()
		return
	_active = bool(response.get("success", false))
	initialization_error = str(response.get("error", "Steam initialization failed")) if not _active else ""
	if not _active:
		return
	_pinned_account = bridge.app_id + "/" + bridge.user_id
	if game_id.is_empty():
		game_id = str(ProjectSettings.get_setting("couch_games/steam/game_id", ProjectSettings.get_setting("application/config/name", "")))
	if game_id.is_empty():
		game_id = str(ProjectSettings.get_setting("application/config/name", "game"))
	operation_timeout_ms = maxi(1, int(ProjectSettings.get_setting("couch_games/steam/operation_timeout_ms", operation_timeout_ms)))
	metadata_timeout_ms = maxi(1, int(ProjectSettings.get_setting("couch_games/steam/metadata_timeout_ms", metadata_timeout_ms)))
	protocol_version = str(ProjectSettings.get_setting("couch_games/steam/protocol_version", protocol_version))
	content_version = str(ProjectSettings.get_setting("couch_games/steam/content_version", content_version))
	if catalog.is_empty():
		catalog = ProjectSettings.get_setting("couch_games/achievements/catalog", {})
	max_event_bytes = clampi(int(ProjectSettings.get_setting("couch_games/steam/max_event_bytes", max_event_bytes)), 1024, _Events.NATIVE_MAX_BYTES)
	receive_budget = clampi(int(ProjectSettings.get_setting("couch_games/steam/receive_budget", receive_budget)), 1, 256)
	_awards = _Achievements.new()
	_awards.timeout_ms = int(ProjectSettings.get_setting("couch_games/achievements/timeout_ms", 5000))
	add_child(_awards)
	_awards.setup(bridge, catalog)
	_awards.ready_changed.connect(func(_value): capabilities_changed.emit())
	process_priority = -100
	process_mode = Node.PROCESS_MODE_ALWAYS
	capabilities_changed.emit()
	capture_launch_invitation(OS.get_cmdline_args() + OS.get_cmdline_user_args())

func capture_launch_invitation(args: PackedStringArray) -> void:
	for index in range(args.size() - 1):
		if args[index] == "+connect_lobby" and _valid_id(args[index + 1]):
			_on_invite(args[index + 1])
			return

func consume_join_request() -> String:
	var id := _launch_invite
	_launch_invite = ""
	return id

func _on_invite(id: String) -> void:
	if _valid_id(id):
		_launch_invite = id
		lobby_join_requested.emit(id)

func is_available() -> bool:
	return _active and not _closed and bridge != null and bridge.initialized and _pinned_account == bridge.app_id + "/" + bridge.user_id

func supports(capability: String) -> bool:
	if not is_available(): return false
	match capability:
		"lobby_events", "lobby_host", "lobby_join", "friend_invites": return bridge.connected()
		"achievements": return _awards != null and _awards.is_ready()
	return false

func achievement_adapter() -> Node:
	return _awards

func _process(_delta: float) -> void:
	poll(Time.get_ticks_msec())

func poll(now_ms: int) -> void:
	if _closed or not _active: return
	bridge.poll()
	if not is_available():
		lobby_leave()
		_active = false
		initialization_error = "Steam account changed; reinitialize in a new SDK instance"
		capabilities_changed.emit()
		return
	if _awards != null:
		_awards.poll(now_ms)
	if not _operation.is_empty() and not _operation.done:
		if now_ms >= int(_operation.deadline):
			_finish_operation(false, "timeout", "Steam membership operation timed out")
		elif _operation.get("entered", false):
			_validate_entry()
	for packet in bridge.receive(receive_budget):
		if not lobby_is_available() or not packet is Dictionary: continue
		var sender := str(packet.get("sender", ""))
		if sender == bridge.user_id or not _members.has(sender) or not packet.get("bytes") is PackedByteArray: continue
		var envelope: Dictionary = _Events.decode(packet.bytes, lobby_id, _token, max_event_bytes)
		if not envelope.is_empty():
			lobby_event_received.emit(envelope.event, envelope.data, sender)

func lobby_host(options: Dictionary) -> Dictionary:
	var visibility := str(options.get("visibility", "private"))
	var maximum := int(options.get("max_players", 2))
	if visibility not in ["private", "friends", "public"] or maximum < 2 or maximum > 16:
		return _failure("invalid-options", "Visibility or player limit is invalid")
	if not supports("lobby_host"): return _failure("unavailable" if is_available() else "initialization-failed", "Steam is not available")
	if not _can_enter(): return _failure("busy", "Leave the current lobby or wait for the operation")
	var operation := _begin_operation("creating")
	operation.maximum = maximum
	if not bridge.create_lobby(_generation, visibility, maximum):
		_finish_operation(false, "busy", "A native membership request is still outstanding")
	return await _await_operation(operation)

func lobby_join(id: String) -> Dictionary:
	if not _valid_id(id): return _failure("invalid-id", "Invalid lobby ID")
	if not supports("lobby_join"): return _failure("unavailable" if is_available() else "initialization-failed", "Steam is not available")
	if not _can_enter(): return _failure("busy", "Leave the current lobby or wait for the operation")
	var operation := _begin_operation("joining")
	operation.requested_id = id
	if not bridge.join_lobby(_generation, id):
		_finish_operation(false, "busy", "A native membership request is still outstanding")
	return await _await_operation(operation)

func _can_enter() -> bool:
	return state in ["idle", "failed"] and (_operation.is_empty() or _operation.done)

func _begin_operation(next_state: String) -> Dictionary:
	_generation += 1
	_operation = {"generation": _generation, "kind": next_state, "done": false, "deadline": Time.get_ticks_msec() + operation_timeout_ms}
	_set_state(next_state)
	return _operation

func _await_operation(operation: Dictionary) -> Dictionary:
	while not operation.done:
		if Time.get_ticks_msec() >= int(operation.deadline) and _operation == operation:
			_finish_operation(false, "timeout", "Steam membership operation timed out")
			break
		await get_tree().process_frame
	return operation.result

func _on_entered(generation: int, id: String, code: String) -> void:
	if _closed or _operation.is_empty() or _operation.done or generation != _generation:
		if code.is_empty() and id != lobby_id:
			bridge.leave_lobby(id)
		return
	if not code.is_empty():
		_finish_operation(false, code, "Steam refused lobby entry")
		return
	if not _valid_id(id) or (_operation.kind == "joining" and id != _operation.requested_id):
		bridge.leave_lobby(id)
		_finish_operation(false, "unavailable", "Unexpected lobby entry")
		return
	lobby_id = id
	_operation.entered = true
	_operation.deadline = mini(int(_operation.deadline), Time.get_ticks_msec() + metadata_timeout_ms)
	if _operation.kind == "creating":
		_authority = bridge.user_id
		_token = Crypto.new().generate_random_bytes(24).hex_encode()
		_slots = {_authority: 0}
		var values := {"game": game_id, "wire": str(_Events.WIRE_VERSION), "protocol": protocol_version, "content": content_version, "match": "lobby", "authority": _authority, "token": _token, "slots": JSON.stringify(_slots)}
		for key in values:
			if not bridge.set_metadata(id, "couch_" + key, values[key]):
				_finish_operation(false, "metadata-failed", "Cannot publish lobby compatibility metadata")
				return
	else:
		bridge.request_metadata(id)
	_validate_entry()

func _validate_entry() -> void:
	var values := {}
	for key in ["game", "wire", "protocol", "content", "match", "authority", "token", "slots"]:
		values[key] = bridge.metadata(lobby_id, "couch_" + key)
		if values[key].is_empty(): return # bounded by operation deadline
	if values.game != game_id or values.wire != str(_Events.WIRE_VERSION) or values.protocol != protocol_version or values.content != content_version or values.match not in ["lobby", "playing"]:
		_finish_operation(false, "incompatible", "Lobby game/protocol/content is incompatible")
		return
	var members: Array = bridge.lobby_members(lobby_id)
	if not members.has(bridge.user_id):
		_finish_operation(false, "unavailable", "Steam did not confirm local membership")
		return
	if not _valid_id(values.authority) or not members.has(values.authority) or bridge.lobby_owner(lobby_id) != values.authority:
		_finish_operation(false, "host-left", "Original authority is no longer present")
		return
	var slots: Variant = JSON.parse_string(values.slots)
	if not _valid_slots(slots, members, values.authority): return
	_authority = values.authority
	_token = values.token
	_slots = slots
	_refresh_roster()
	_finish_operation(true)

func _valid_slots(slots: Variant, members: Array, authority: String) -> bool:
	if not slots is Dictionary or slots.get(authority) != 0: return false
	var used := {}
	for id in members:
		var slot: Variant = slots.get(id)
		if not (slot is int or slot is float) or slot != int(slot) or int(slot) < 0 or int(slot) > 15 or used.has(int(slot)): return false
		used[int(slot)] = true
	return true

func _finish_operation(success: bool, code := "", message := "") -> void:
	if _operation.is_empty() or _operation.done: return
	_operation.done = true
	_operation.result = {"success": true, "payload": {"lobby_id": lobby_id}} if success else _failure(code, message)
	if success:
		_set_state("joined")
	else:
		_clear_membership()
		_set_state("failed")
		lobby_operation_failed.emit(code, message)

func lobby_leave() -> void:
	if state == "idle" and lobby_id.is_empty(): return
	_generation += 1
	_set_state("leaving")
	if not _operation.is_empty() and not _operation.done:
		_operation.done = true
		_operation.result = _failure("cancelled", "Lobby operation cancelled")
	_clear_membership()
	_set_state("idle")

func _clear_membership() -> void:
	for id in _members:
		if id != bridge.user_id: bridge.close_peer(id)
	if not lobby_id.is_empty(): bridge.leave_lobby(lobby_id)
	lobby_id = ""
	_authority = ""
	_token = ""
	_slots.clear()
	_members.clear()
	_players.clear()
	# Drain stale packets in bounded frame budgets thereafter; lobby/token checks
	# reject any remaining provider packets. No SDK outbound queue exists.
	lobby_players_updated.emit([])

func _set_state(value: String) -> void:
	state = value
	lobby_state_changed.emit(state, lobby_id)

func _on_roster_changed(id: String) -> void:
	if not is_available() or lobby_id.is_empty() or (not id.is_empty() and id != lobby_id): return
	if state == "joined": _refresh_roster()
	elif _operation.get("entered", false) and not _operation.get("done", true): _validate_entry()

func _refresh_roster() -> void:
	var members: Array = bridge.lobby_members(lobby_id)
	if not members.has(_authority) or not members.has(bridge.user_id):
		var code := "host-left" if not members.has(_authority) else "unavailable"
		lobby_leave()
		_set_state("failed")
		lobby_operation_failed.emit(code, "Original authority or local member left the lobby")
		return
	for id in _members:
		if not members.has(id) and id != bridge.user_id: bridge.close_peer(id)
	if _authority == bridge.user_id:
		# Stable while present; leaving frees its slot for a later participant.
		for old_id in _slots.keys():
			if not members.has(old_id): _slots.erase(old_id)
		var used := {}
		for id in members:
			if _slots.has(id): used[int(_slots[id])] = true
		for id in members:
			if not _slots.has(id):
				for slot in range(1, 16):
					if not used.has(slot):
						_slots[id] = slot
						used[slot] = true
						break
		if not bridge.set_metadata(lobby_id, "couch_slots", JSON.stringify(_slots)):
			lobby_leave()
			lobby_operation_failed.emit("metadata-failed", "Cannot publish controller slots")
			return
	else:
		var slots: Variant = JSON.parse_string(bridge.metadata(lobby_id, "couch_slots"))
		if not _valid_slots(slots, members, _authority): return
		_slots = slots
	_members = members.duplicate()
	_players.clear()
	for id in members:
		_players.append({"userId": id, "username": bridge.persona_name(id), "role": "host" if id == _authority else "guest", "controllerSlot": int(_slots.get(id, -1)), "status": "lobby", "ping": -1})
	lobby_players_updated.emit(_players.duplicate(true))

func lobby_is_available() -> bool:
	return is_available() and state == "joined" and not lobby_id.is_empty() and bridge.connected()
func lobby_get_players() -> Array:
	return _players.duplicate(true)
func lobby_get_me() -> Dictionary:
	for player in _players:
		if player.userId == bridge.user_id: return player.duplicate()
	return {}
func lobby_get_current_game() -> Dictionary:
	return {"gameId": game_id, "experienceId": lobby_id} if lobby_is_available() else {}
func lobby_open_invite_overlay() -> Dictionary:
	if not lobby_is_available() or not supports("friend_invites") or not bridge.invite_overlay(lobby_id):
		return _failure("unavailable", "Steam invitation overlay unavailable")
	return {"success": true}
func lobby_send_event(event: String, data: Variant, target: Dictionary) -> void:
	lobby_try_send_event(event, data, target)
func lobby_try_send_event(event: String, data: Variant, target: Dictionary) -> bool:
	if not lobby_is_available(): return _reject_send("unavailable", "Lobby events unavailable")
	if event.is_empty() or not _Events.json_compatible(data): return _reject_send("invalid-payload", "Event and data must be JSON-compatible")
	if target.has("role") and target.role not in ["host", "guest"]: return _reject_send("invalid-target", "Invalid target role")
	if target.has("userId") and not target.userId is String: return _reject_send("invalid-target", "User IDs must be strings")
	var bytes: PackedByteArray = _Events.encode(lobby_id, _token, event, data)
	if bytes.size() > max_event_bytes: return _reject_send("oversized", "Serialized event exceeds byte limit")
	var accepted := true
	for player in _players:
		var id := str(player.userId)
		if id == bridge.user_id: continue
		if target.has("userId") and target.userId != id: continue
		if target.has("role") and target.role != player.role: continue
		if not bridge.send_reliable(id, bytes):
			accepted = false
			_reject_send("send-failed", "Steam rejected reliable event", id)
			_on_peer_failure(id, "send-failed")
	return accepted
func _reject_send(code: String, message: String, id := "") -> bool:
	event_send_failed.emit(code, message, id)
	return false
func _on_peer_request(id: String) -> void:
	if lobby_is_available() and id != bridge.user_id and _members.has(id):
		if not bridge.accept_peer(id): _on_peer_failure(id, "accept-failed")
	else:
		bridge.close_peer(id)
func _on_peer_failure(id: String, reason: String) -> void:
	if lobby_is_available() and _members.has(id) and id != bridge.user_id:
		bridge.close_peer(id)
		transport_gap.emit(id, "steam:" + reason)
func _on_connection_changed(connected: bool) -> void:
	capabilities_changed.emit()
	if not connected:
		for id in _members:
			if id != bridge.user_id:
				bridge.close_peer(id)
				transport_gap.emit(id, "steam:disconnected")
func unlock_achievement(key: String) -> Dictionary:
	if _awards == null: return _failure("unavailable", "Achievements unavailable")
	var result: Dictionary = await _awards.unlock(key)
	return {"success": result.status in ["stored", "already_unlocked"] and result.provider_acknowledged, "alreadyUnlocked": result.already_unlocked, "error": result.error, "metadata": {"status": result.status, "error_code": result.error_code if not result.error_code.is_empty() else result.status}}
func get_achievements() -> Dictionary:
	return _awards.get_unlocked() if _awards != null else _failure("unavailable", "Achievements unavailable")
func shutdown() -> void:
	if _closed: return
	lobby_leave()
	_closed = true
	_active = false
	if _awards != null: _awards.shutdown()
	if bridge != null: bridge.shutdown()
	capabilities_changed.emit()
func _exit_tree() -> void:
	shutdown()
static func _valid_id(id: String) -> bool:
	return not id.is_empty() and id.is_valid_int() and int(id) > 0 and str(int(id)) == id
static func _failure(code: String, message: String) -> Dictionary:
	return {"success": false, "error": message, "metadata": {"error_code": code}}

func _not_implemented() -> Dictionary:
	return _failure("unavailable", "This service is unavailable for the Steam backend")
func load_save_result() -> Dictionary:
	return {"status": "unavailable", "message": "The save API is unavailable for Steam", "hostAuthoritative": false}
