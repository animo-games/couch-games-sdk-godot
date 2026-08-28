extends SceneTree

var _failed := false


class StubSource:
	extends RefCounted

	signal sig_received(peer_id: String, data: Variant)
	signal peer_joined(peer_id: String)
	signal peer_left(peer_id: String)
	signal connection_config_updated(config: Dictionary)
	signal present_peers_updated(peer_ids: Array)

	var sent: Array[Dictionary] = []
	var closed := false
	var present_peers: Array[String] = []
	var snapshot_requests := 0

	func connect_room() -> Dictionary:
		return {
			"success": true,
			"peer_id": "local",
			"room_id": "room",
			"ice_servers": [],
		}

	func send(peer_id: String, data: Variant) -> void:
		sent.append({"peer_id": peer_id, "data": data})

	func close() -> void:
		closed = true

	func get_connection_config() -> Dictionary:
		return {"iceServers": []}

	func get_present_peers() -> Array[String]:
		return present_peers.duplicate()

	func request_present_peers() -> void:
		snapshot_requests += 1


class RecoveryConnection extends WebRTCMultiplayerConnection:
	var rebuilt: Array[Dictionary] = []

	func _rebuild_peer_connection(peer_id: String, gen: int) -> bool:
		_gens[peer_id] = gen
		rebuilt.append({
			"peer_id": peer_id,
			"gen": gen,
			"config": _connection_config.duplicate(true),
		})
		return true


## A signaling source from before either presence capability existed.
class LegacySource:
	extends RefCounted

	signal sig_received(peer_id: String, data: Variant)
	signal peer_joined(peer_id: String)
	signal peer_left(peer_id: String)

	func connect_room() -> Dictionary:
		return {"success": true, "peer_id": "local", "room_id": "room", "ice_servers": []}

	func send(_peer_id: String, _data: Variant) -> void:
		pass

	func close() -> void:
		pass


class DiscoveryConnection extends WebRTCMultiplayerConnection:
	var created: Array[String] = []

	func _create_peer_connection(peer_id: String, _gen: int) -> bool:
		created.append(peer_id)
		return true


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	_check_public_contract()
	_check_generation_and_envelope_contract()
	_check_udp_first_option()
	_check_strict_identify()
	_check_targeted_and_simultaneous_recovery()
	_check_refreshed_config_reaches_recovery()
	_check_safe_multiplayer_detach()
	_check_cached_peer_discovery()
	_check_authoritative_peer_snapshot()
	_check_single_couch_handler()
	_check_compatibility_alias()
	await process_frame
	if _failed:
		quit(1)
		return
	print("WEBRTC_CONNECTION_HANDLER_TEST: PASS")
	quit(0)


func _check_public_contract() -> void:
	var connection := WebRTCMultiplayerConnection.new()
	for signal_name in [
		&"peer_ready", &"peer_lost", &"peer_recovery_started", &"peer_recovered",
		&"connection_ready", &"connection_failed",
	]:
		_expect(connection.has_signal(signal_name), true, "missing signal %s" % signal_name)
	for method_name in [
		&"start", &"stop", &"request_recovery", &"get_ready_peers", &"get_net_id",
		&"get_peer_id", &"get_multiplayer_peer", &"is_recovering",
	]:
		_expect(connection.has_method(method_name), true, "missing method %s" % method_name)
	_expect(WebRTCMultiplayerConnection._implements_signaling_source(StubSource.new()), true,
		"stub source must satisfy the duck-typed signaling contract")
	connection.free()


func _check_generation_and_envelope_contract() -> void:
	_expect(
		WebRTCMultiplayerConnection.classify_generation(0, 0),
		WebRTCMultiplayerConnection.GenAction.PROCESS,
		"same generation must process",
	)
	_expect(
		WebRTCMultiplayerConnection.classify_generation(1, 0),
		WebRTCMultiplayerConnection.GenAction.DROP_STALE,
		"older generation must be stale",
	)
	_expect(
		WebRTCMultiplayerConnection.classify_generation(0, 1),
		WebRTCMultiplayerConnection.GenAction.ADOPT,
		"newer generation must be adopted",
	)

	var source := StubSource.new()
	var connection := RecoveryConnection.new()
	root.add_child(connection)
	connection._source = source
	connection._gens["peer"] = 2
	connection._announce_restart("peer", 2)
	_expect(source.sent.size(), 1, "restart must emit one envelope immediately")
	if source.sent.size() == 1:
		_expect(source.sent[0], {
			"peer_id": "peer", "data": {"v": 1, "gen": 2, "kind": "restart"},
		}, "restart envelope must retain v1 field names and values")
	connection.stop()
	connection.free()


func _check_udp_first_option() -> void:
	var servers: Array = [
		{"urls": "stun:example:3478"},
		{"urls": "turn:example:3478?transport=udp", "username": "u"},
		{"urls": "turn:example:80?transport=tcp", "username": "u"},
		{"urls": "turns:example:443?transport=tcp", "username": "u"},
	]
	var first := WebRTCMultiplayerConnection.ice_servers_for_generation(servers, 0, true)
	_expect(first.size(), 2, "UDP-first generation 0 must remove TCP/TLS relays")
	_expect(
		WebRTCMultiplayerConnection.ice_servers_for_generation(servers, 1, true),
		servers,
		"generation 1 must restore the full ICE list",
	)
	_expect(
		WebRTCMultiplayerConnection.ice_servers_for_generation(servers, 0, false),
		servers,
		"disabled UDP-first policy must preserve the full list",
	)


func _check_strict_identify() -> void:
	var valid := WebRTCMultiplayerConnection.new()
	root.add_child(valid)
	valid._known_peers.append("peer-valid")
	var ready: Array[String] = []
	valid.peer_ready.connect(func(peer_id: String, _net_id: int) -> void: ready.append(peer_id))
	var expected := WebRTCMultiplayerConnection.derive_net_id("peer-valid")
	valid.receive_identify("peer-valid", expected)
	_expect(ready, ["peer-valid"], "authorized deterministic identify must become ready")
	_expect(valid.get_peer_id(expected), "peer-valid", "identify must populate reverse mapping")
	valid.stop()
	valid.free()

	var invalid := WebRTCMultiplayerConnection.new()
	root.add_child(invalid)
	invalid._known_peers.append("peer-invalid")
	var failures: Array[String] = []
	invalid.connection_failed.connect(func(reason: String) -> void: failures.append(reason))
	invalid.receive_identify("peer-invalid", expected)
	_expect(failures.size(), 1, "net-id mismatch must fail the initial connection")
	_expect(invalid.get_ready_peers().is_empty(), true, "invalid identify must never become ready")
	invalid.stop()
	invalid.free()


func _ready_connection(peer_ids: Array[String]) -> RecoveryConnection:
	var connection := RecoveryConnection.new()
	root.add_child(connection)
	connection._source = StubSource.new()
	connection._active = true
	connection.local_peer_id = "local"
	connection.local_net_id = WebRTCMultiplayerConnection.derive_net_id("local")
	for peer_id in peer_ids:
		var net_id := WebRTCMultiplayerConnection.derive_net_id(peer_id)
		connection._known_peers.append(peer_id)
		connection._gens[peer_id] = WebRTCMultiplayerConnection.MAX_GEN
		connection._peer_to_net[peer_id] = net_id
		connection._net_to_peer[net_id] = peer_id
		connection._ready_peer_set[peer_id] = true
	return connection


func _check_targeted_and_simultaneous_recovery() -> void:
	var connection := _ready_connection(["peer-a", "peer-b", "peer-c"])
	var started: Array[String] = []
	var recovered: Array[String] = []
	connection.peer_recovery_started.connect(
		func(peer_id: String, _net_id: int) -> void: started.append(peer_id))
	connection.peer_recovered.connect(
		func(peer_id: String, _net_id: int, _duration: int) -> void: recovered.append(peer_id))

	_expect(connection.request_recovery("peer-a"), true, "targeted recovery must be accepted")
	_expect(connection.request_recovery("peer-b"), true, "a second peer may recover simultaneously")
	_expect(connection.request_recovery("peer-a"), false, "duplicate recovery must be rejected")
	_expect(started, ["peer-a", "peer-b"], "only targeted peers must enter recovery")
	_expect(connection.is_recovering("peer-c"), false, "untargeted peer must stay ready")
	_expect(connection.get_ready_peers().has("peer-c"), true, "untargeted peer must remain ready")

	connection.receive_identify(
		"peer-a", WebRTCMultiplayerConnection.derive_net_id("peer-a"))
	_expect(recovered, ["peer-a"], "identify must finish only that peer's recovery")
	_expect(connection.is_recovering("peer-b"), true, "other peer recovery must remain independent")
	connection.stop()
	connection.free()


func _check_refreshed_config_reaches_recovery() -> void:
	var connection := _ready_connection(["peer"])
	var refreshed := {
		"iceServers": [{
			"urls": "turn:refresh.example:3478?transport=udp",
			"username": "new-user",
			"credential": "new-credential",
		}],
		"bundlePolicy": "max-bundle",
	}
	connection._set_connection_config(refreshed)
	refreshed["iceServers"][0]["credential"] = "mutated"
	_expect(connection.request_recovery("peer"), true, "recovery must accept the ready peer")
	_expect(connection.rebuilt.size(), 1, "recovery must build exactly one replacement")
	if connection.rebuilt.size() == 1:
		var used := connection.rebuilt[0]["config"] as Dictionary
		_expect(used.get("bundlePolicy"), "max-bundle", "neutral config fields must survive")
		_expect(
			(used["iceServers"] as Array)[0]["credential"], "new-credential",
			"recovery must use the refreshed credential snapshot",
		)
	connection.stop()
	connection.free()


func _check_safe_multiplayer_detach() -> void:
	var connection := WebRTCMultiplayerConnection.new()
	root.add_child(connection)
	var api := MultiplayerAPI.create_default_interface()
	var owned := WebRTCMultiplayerPeer.new()
	owned.create_mesh(23)
	api.multiplayer_peer = owned
	connection._multiplayer_api = api
	connection._mesh = owned
	connection._source = StubSource.new()
	var replacement := OfflineMultiplayerPeer.new()
	api.multiplayer_peer = replacement
	connection.stop()
	_expect(api.multiplayer_peer == replacement, true,
		"stale stop must not replace a newer MultiplayerPeer")
	connection.free()


func _check_cached_peer_discovery() -> void:
	var source := StubSource.new()
	source.present_peers.assign(["peer-cached", "local", "peer-cached"])
	var connection := DiscoveryConnection.new()
	connection.local_peer_id = "local"
	connection.local_net_id = WebRTCMultiplayerConnection.derive_net_id("local")
	connection._peers_ready = true
	connection._seed_present_peers(source)
	_expect(connection._known_peers, ["peer-cached"],
		"startup must discover peers from the source presence snapshot")
	_expect(connection.created, ["peer-cached"],
		"cached presence must create one peer connection")

	var pending := DiscoveryConnection.new()
	pending._peers_ready = false
	source.present_peers.assign(["peer-departed"])
	pending._seed_present_peers(source)
	pending._on_source_peer_left("peer-departed")
	_expect(pending._pending_peer_ids.is_empty(), true,
		"a departure before startup completes must remove cached pending presence")
	connection.free()
	pending.free()


func _check_authoritative_peer_snapshot() -> void:
	var source := StubSource.new()
	source.present_peers.assign(["peer-cached"])
	var connection := DiscoveryConnection.new()
	connection.local_peer_id = "local"
	connection.local_net_id = WebRTCMultiplayerConnection.derive_net_id("local")
	connection._peers_ready = true
	connection._attach_source_signals(source)
	connection._seed_present_peers(source)
	_expect(source.snapshot_requests, 1,
		"startup must ask the source for an authoritative room snapshot")
	_expect(connection.created, ["peer-cached"],
		"the cached view still seeds immediately, without waiting for a reply")

	# The snapshot names a peer the cache never heard announced. That is the
	# whole point: it must become a connection.
	source.present_peers_updated.emit(["peer-cached", "peer-missed", "local", ""])
	_expect(connection.created, ["peer-cached", "peer-missed"],
		"a snapshot must create connections for peers the cached view missed")
	_expect(connection._known_peers.has("local"), false,
		"a snapshot must never discover the local peer")

	# An established peer absent from a later snapshot is deliberately kept:
	# tearing down a live connection on a possibly-raced snapshot costs more
	# than carrying a stale peer until peer_left arrives.
	source.present_peers_updated.emit([])
	_expect(connection._known_peers, ["peer-cached", "peer-missed"],
		"a snapshot must not tear down established connections")

	# Before startup completes there is nothing established to protect, and a
	# pending peer the room no longer lists has nothing else to retract it.
	var pending := DiscoveryConnection.new()
	pending._peers_ready = false
	pending._attach_source_signals(source)
	pending._discover_peer("peer-gone")
	pending._discover_peer("peer-still-here")
	_expect(pending._pending_peer_ids, ["peer-gone", "peer-still-here"],
		"pre-startup discovery queues peers as pending")
	source.present_peers_updated.emit(["peer-still-here"])
	_expect(pending._pending_peer_ids, ["peer-still-here"],
		"a snapshot must drop pending peers the room no longer lists")
	_expect(pending.created.is_empty(), true,
		"a snapshot must not create connections before startup completes")

	connection._detach_source_signals(source)
	pending._detach_source_signals(source)
	connection.free()
	pending.free()

	# A source without the capability must still start: the request is skipped
	# and the cached view stands, which is exactly the pre-snapshot behavior.
	var legacy := LegacySource.new()
	var legacy_connection := DiscoveryConnection.new()
	legacy_connection.local_peer_id = "local"
	legacy_connection.local_net_id = WebRTCMultiplayerConnection.derive_net_id("local")
	legacy_connection._peers_ready = true
	legacy_connection._attach_source_signals(legacy)
	legacy_connection._seed_present_peers(legacy)
	_expect(legacy_connection.created.is_empty(), true,
		"a source without either presence capability must be tolerated")
	legacy_connection._detach_source_signals(legacy)
	legacy_connection.free()


func _check_single_couch_handler() -> void:
	var webrtc := CouchWebRTC.new()
	var first := Node.new()
	var second := Node.new()
	_expect(webrtc.claim_connection_handler(first), true, "first Couch handler must claim")
	_expect(webrtc.claim_connection_handler(second), false, "second Couch handler must be refused")
	webrtc.release_connection_handler(first)
	_expect(webrtc.claim_connection_handler(second), true, "released Couch handler may be replaced")
	first.free()
	second.free()
	webrtc.free()


func _check_compatibility_alias() -> void:
	var webrtc := CouchWebRTC.new()
	var source := CouchRollbackSignalingAdapter.new(webrtc)
	_expect(source is CouchWebRTCSignalingSource, true,
		"rollback adapter name must remain a signaling-source compatibility alias")
	source = null
	webrtc.free()


func _expect(actual: Variant, expected: Variant, label: String) -> void:
	if actual == expected:
		return
	_failed = true
	printerr("WEBRTC_CONNECTION_HANDLER_TEST: FAIL %s (expected=%s actual=%s)" % [
		label, str(expected), str(actual),
	])
