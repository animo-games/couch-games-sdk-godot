## Signaling-provider-neutral WebRTC mesh connection.
##
## The signaling source is duck typed. It must expose `sig_received`,
## `peer_joined`, and `peer_left` signals plus `connect_room()`, `send()`, and
## `close()` methods. An optional `connection_config_updated` signal and
## `get_connection_config()` method provide refreshed ICE/TURN credentials.
## An optional `get_present_peers()` method supplies a current room snapshot
## when signaling was connected before this handler started.
##
## Add this node at the same path on every peer before start(): the strict
## `_identify` RPC is part of the connection protocol and depends on that path.
class_name WebRTCMultiplayerConnection
extends Node

signal peer_ready(peer_id: String, net_id: int)
signal peer_lost(peer_id: String, net_id: int)
signal peer_recovery_started(peer_id: String, net_id: int)
signal peer_recovered(peer_id: String, net_id: int, duration_ms: int)
signal connection_ready()
signal connection_failed(reason: String)
## Compatibility aliases for callers migrating from RollbackTransport.
signal transport_ready()
signal transport_failed(reason: String)

@export var connect_timeout_sec := 10.0
@export var recovery_timeout_sec := 15.0
@export var recovery_retry_sec := 5.0
## Generation-0 connections can prefer UDP-capable TURN URLs, then retry with
## the full server list at generation 1.
@export var udp_first := false
@export var udp_first_timeout_sec := 4.0

## Console logging of connection lifecycle (the gen/ice-policy line) is off by
## default so release builds stay silent; the game turns it on through
## `CouchGames.set_verbose_logging`.
static var verbose_logging := false

const MAX_GEN := 1
const MAX_PENDING_ICE := 64
const RESTART_ANNOUNCE_INTERVAL_SEC := 1.0
const SDP_RETRANSMIT_INTERVAL_SEC := 1.0

enum GenAction {
	PROCESS,
	DROP_STALE,
	ADOPT,
}

var local_peer_id := ""
var local_net_id := 0

var _source
var _multiplayer_api: MultiplayerAPI
var _rpc_host: Node
var _mesh: WebRTCMultiplayerPeer
var _connection_config: Dictionary = {}
var _ice_servers: Array = []
var _active := false
var _peers_ready := false
var _pending_peer_ids: Array[String] = []
var _departed: Dictionary = {}
var _awaiting_rejoin_gen0: Dictionary = {}
var _lifecycle_seq := 0

var _known_peers: Array[String] = []
var _pcs: Dictionary = {}
var _peer_to_net: Dictionary = {}
var _net_to_peer: Dictionary = {}
var _ready_peer_set: Dictionary = {}
var _recovering_peers: Dictionary = {}
var _timers: Dictionary = {}
var _gens: Dictionary = {}
var _remote_desc_set: Dictionary = {}
var _pending_ice: Dictionary = {}
var _pc_epochs: Dictionary = {}
var _restart_timers: Dictionary = {}
var _sdp_retransmits: Dictionary = {}
var _epoch_seq := 0


## Override the node that owns the wire-compatible `_identify` RPC. This is
## used only by compatibility facades; normal SDK games leave it as `self`.
func set_rpc_host(host: Node) -> void:
	_rpc_host = host


func _exit_tree() -> void:
	if _active:
		stop()


## Join signaling and install an owned WebRTCMultiplayerPeer on `multiplayer_api`.
## A null API uses this node's configured MultiplayerAPI.
func start(signaling_source = null, multiplayer_api: MultiplayerAPI = null) -> void:
	if not _implements_signaling_source(signaling_source):
		_fail_connection("invalid signaling source")
		return
	if not _probe_webrtc_available():
		_fail_connection("WebRTC peer connection backend unavailable")
		return

	_lifecycle_seq += 1
	var token := _lifecycle_seq
	if _source != null and _source != signaling_source:
		_detach_source_signals(_source)
	_source = signaling_source
	_attach_source_signals(_source)
	_multiplayer_api = multiplayer_api if multiplayer_api != null else multiplayer
	_rpc_host = self if _rpc_host == null else _rpc_host

	var result: Dictionary = await _source.connect_room()
	if token != _lifecycle_seq:
		if _source != signaling_source:
			_detach_source_signals(signaling_source)
			signaling_source.close()
		return
	if not (result.get("success", false) as bool):
		var reason := str(result.get("error", "connect_room failed"))
		_detach_source_signals(signaling_source)
		_fail_connection(reason)
		return

	local_peer_id = str(result.get("peer_id", ""))
	if local_peer_id.is_empty():
		_detach_source_signals(signaling_source)
		_fail_connection("signaling returned an empty local peer id")
		return
	local_net_id = derive_net_id(local_peer_id)
	var servers: Variant = result.get("ice_servers", [])
	_ice_servers = (servers as Array).duplicate(true) if servers is Array else []
	_connection_config = {"iceServers": _ice_servers.duplicate(true)}
	if _source.has_method("get_connection_config"):
		var current: Variant = _source.call("get_connection_config")
		if current is Dictionary and not (current as Dictionary).is_empty():
			_set_connection_config(current as Dictionary)

	_mesh = WebRTCMultiplayerPeer.new()
	var mesh_error := _mesh.create_mesh(local_net_id)
	if mesh_error != OK:
		_mesh = null
		_fail_connection("WebRTC mesh creation failed (err=%d)" % mesh_error)
		return
	_attach_multiplayer_signals()
	_multiplayer_api.multiplayer_peer = _mesh
	_active = true
	_peers_ready = true

	var pending := _pending_peer_ids.duplicate()
	_pending_peer_ids.clear()
	for pid in pending:
		_on_peer_discovered(pid)
	_seed_present_peers(signaling_source)


## Stop signaling and close only the MultiplayerPeer installed by this node.
## A stale teardown never replaces a newer connection installed on the API.
func stop() -> void:
	_active = false
	_lifecycle_seq += 1
	_detach_source_signals(_source)
	_detach_multiplayer_signals()
	for pid_v in _timers.keys().duplicate():
		_cancel_timer(str(pid_v))
	for pid_v in _restart_timers.keys().duplicate():
		_cancel_restart_timer(str(pid_v))
	for pid_v in _sdp_retransmits.keys().duplicate():
		_cancel_sdp_retransmit(str(pid_v))

	var owned_mesh := _mesh
	var owns_installed_peer := _multiplayer_api != null and owned_mesh != null \
		and _multiplayer_api.multiplayer_peer == owned_mesh
	if owned_mesh != null:
		owned_mesh.close()
	if owns_installed_peer:
		_multiplayer_api.multiplayer_peer = OfflineMultiplayerPeer.new()
	_mesh = null
	if _source != null:
		_source.close()

	_source = null
	_multiplayer_api = null
	_pcs.clear()
	_peer_to_net.clear()
	_net_to_peer.clear()
	_ready_peer_set.clear()
	_recovering_peers.clear()
	_known_peers.clear()
	_gens.clear()
	_remote_desc_set.clear()
	_pending_ice.clear()
	_pc_epochs.clear()
	_departed.clear()
	_awaiting_rejoin_gen0.clear()
	_pending_peer_ids.clear()
	_connection_config.clear()
	_ice_servers.clear()
	_peers_ready = false
	local_peer_id = ""
	local_net_id = 0


func get_multiplayer_peer() -> MultiplayerPeer:
	return _mesh


func get_net_id(peer_id: String) -> int:
	if _peer_to_net.has(peer_id):
		return int(_peer_to_net[peer_id])
	return derive_net_id(peer_id)


func get_peer_id(net_id: int) -> String:
	var value: Variant = _net_to_peer.get(net_id)
	return value as String if value is String else ""


func get_generation(peer_id: String) -> int:
	return int(_gens.get(peer_id, 0))


func get_ready_peers() -> Array[String]:
	var peers: Array[String] = []
	for pid_v in _ready_peer_set.keys():
		peers.append(str(pid_v))
	return peers


func is_recovering(peer_id: String = "") -> bool:
	return not _recovering_peers.is_empty() if peer_id.is_empty() \
		else _recovering_peers.has(peer_id)


func is_webrtc_mode() -> bool:
	return true


## Targeted recovery is generic and per-peer. Choosing which peer and when to
## recover remains application policy.
func request_recovery(peer_id: String) -> bool:
	if not _active or peer_id.is_empty() or _recovering_peers.has(peer_id):
		return false
	if not _known_peers.has(peer_id) or not _ready_peer_set.has(peer_id):
		return false
	var net_id := get_net_id(peer_id)
	_mark_peer_recovering(peer_id, net_id)
	var next_gen := int(_gens.get(peer_id, 0)) + 1
	if _rebuild_peer_connection(peer_id, next_gen):
		_announce_restart(peer_id, next_gen)
	return true


func _on_peer_discovered(pid: String) -> void:
	if _departed.has(pid):
		_awaiting_rejoin_gen0[pid] = true
	_departed.erase(pid)
	_discover_peer(pid)


func _discover_peer(pid: String) -> void:
	if not _peers_ready:
		if not pid.is_empty() and not _pending_peer_ids.has(pid) and not _pcs.has(pid):
			_pending_peer_ids.append(pid)
		return
	if pid.is_empty() or pid == local_peer_id or _known_peers.has(pid):
		return
	var candidate_id := derive_net_id(pid)
	if candidate_id == local_net_id:
		_fail_connection("net id collision with %s" % pid)
		return
	for known in _known_peers:
		if derive_net_id(known) == candidate_id:
			_fail_connection("net id collision between %s and %s" % [known, pid])
			return
	_known_peers.append(pid)
	_create_peer_connection(pid, 0)


## Factory seam used by headless characterization tests.
func _new_peer_connection() -> WebRTCPeerConnection:
	return WebRTCPeerConnection.new()


func _create_peer_connection(pid: String, gen: int) -> bool:
	if _mesh == null:
		return false
	var pc := _new_peer_connection()
	var config := _connection_config.duplicate(true)
	var servers := ice_servers_for_generation(_ice_servers, gen, udp_first)
	if servers.is_empty():
		config.erase("iceServers")
	else:
		config["iceServers"] = servers
	var error := pc.initialize(config)
	if error != OK:
		if _recovering_peers.has(pid):
			_fail_recovery(pid, "peer connection init failed")
		else:
			_fail_connection("peer connection init failed for %s" % pid)
		return false

	var epoch := _next_epoch()
	pc.session_description_created.connect(
		_on_session_description_created.bind(pid, gen, epoch))
	pc.ice_candidate_created.connect(
		_on_ice_candidate_created.bind(pid, gen, epoch))
	_gens[pid] = gen
	_pc_epochs[pid] = epoch
	_pcs[pid] = pc
	var mesh_error := _mesh.add_peer(pc, derive_net_id(pid))
	if mesh_error != OK:
		pc.close()
		_pcs.erase(pid)
		if _recovering_peers.has(pid):
			_fail_recovery(pid, "mesh add_peer failed")
		else:
			_fail_connection("mesh add_peer failed for %s" % pid)
		return false

	var policy := "full"
	if udp_first and gen == 0:
		policy = "udp-only" if servers != _ice_servers else "udp-only(no-op)"
	if verbose_logging:
		print("WebRTCMultiplayerConnection: %s gen=%d ice=%s (%d/%d servers)" % [
			pid, gen, policy, servers.size(), _ice_servers.size()])
	if local_peer_id < pid:
		pc.create_offer()
	_start_connect_timeout(pid)
	return true


func _rebuild_peer_connection(pid: String, gen: int) -> bool:
	var net_id := derive_net_id(pid)
	if _mesh != null and _mesh.has_peer(net_id):
		_mesh.remove_peer(net_id)
	var old: Variant = _pcs.get(pid)
	if old is WebRTCPeerConnection:
		(old as WebRTCPeerConnection).close()
	_pcs.erase(pid)
	_remote_desc_set.erase(pid)
	_pending_ice.erase(pid)
	_cancel_restart_timer(pid)
	_cancel_sdp_retransmit(pid)
	return _create_peer_connection(pid, gen)


func _on_sig_received(sender_peer_id: String, data: Variant) -> void:
	if not _active:
		return
	if not (data is Dictionary):
		return
	var env := data as Dictionary
	if int(env.get("v", 0)) != 1:
		return
	var kind := str(env.get("kind", ""))
	if kind != "sdp" and kind != "ice" and kind != "restart" and kind != "sdp_ack":
		return
	if not _known_peers.has(sender_peer_id):
		if _departed.has(sender_peer_id):
			return
		_discover_peer(sender_peer_id)

	var incoming_gen := int(env.get("gen", 0))
	if _awaiting_rejoin_gen0.has(sender_peer_id):
		if incoming_gen != 0:
			return
		_awaiting_rejoin_gen0.erase(sender_peer_id)
	if incoming_gen >= int(_gens.get(sender_peer_id, 0)):
		_cancel_restart_timer(sender_peer_id)
	if kind == "sdp_ack":
		_handle_sdp_ack(sender_peer_id, env, incoming_gen)
		return

	match classify_generation(int(_gens.get(sender_peer_id, 0)), incoming_gen):
		GenAction.DROP_STALE:
			return
		GenAction.ADOPT:
			var established := _ready_peer_set.has(sender_peer_id) \
				or _recovering_peers.has(sender_peer_id)
			if incoming_gen > MAX_GEN and not established:
				return
			if _ready_peer_set.has(sender_peer_id):
				_mark_peer_recovering(sender_peer_id, get_net_id(sender_peer_id))
			if not _rebuild_peer_connection(sender_peer_id, incoming_gen):
				return
		GenAction.PROCESS:
			pass

	match kind:
		"sdp":
			_handle_sdp(sender_peer_id, env)
		"ice":
			_handle_ice(sender_peer_id, env)


func _handle_sdp(pid: String, env: Dictionary) -> void:
	var pc := _pcs.get(pid) as WebRTCPeerConnection
	if pc == null:
		return
	var sdp_type := str(env.get("sdp_type", ""))
	var sdp := str(env.get("sdp", ""))
	if _remote_desc_set.has(pid):
		_ack_sdp(pid, sdp_type)
		return
	var error := pc.set_remote_description(sdp_type, sdp)
	if error != OK:
		push_error("WebRTCMultiplayerConnection: set_remote_description failed for %s (err=%d)" % [pid, error])
		return
	_remote_desc_set[pid] = true
	if sdp_type == "answer":
		_cancel_sdp_retransmit(pid)
	_ack_sdp(pid, sdp_type)
	_flush_pending_ice(pid)


func _ack_sdp(pid: String, sdp_type: String) -> void:
	if sdp_type == "answer":
		_source.send(pid, {
			"v": 1, "gen": int(_gens.get(pid, 0)), "kind": "sdp_ack",
			"sdp_type": sdp_type,
		})


func _handle_sdp_ack(pid: String, env: Dictionary, incoming_gen: int) -> void:
	var entry: Variant = _sdp_retransmits.get(pid)
	if not (entry is Dictionary):
		return
	var current := entry as Dictionary
	if incoming_gen == int(current["gen"]) \
			and str(env.get("sdp_type", "")) == str(current["sdp_type"]):
		_cancel_sdp_retransmit(pid)


func _handle_ice(pid: String, env: Dictionary) -> void:
	var mid := str(env.get("mid", ""))
	var index := int(env.get("index", 0))
	var candidate := str(env.get("candidate", ""))
	var pc := _pcs.get(pid) as WebRTCPeerConnection
	if pc == null or not _remote_desc_set.has(pid):
		_buffer_pending_ice(pid, mid, index, candidate)
		return
	_apply_ice_candidate(pid, pc, mid, index, candidate)


func _buffer_pending_ice(pid: String, mid: String, index: int, candidate: String) -> void:
	var queued: Array = _pending_ice.get(pid, [])
	if queued.size() >= MAX_PENDING_ICE:
		return
	queued.append({"mid": mid, "index": index, "candidate": candidate})
	_pending_ice[pid] = queued


func _flush_pending_ice(pid: String) -> void:
	var queued: Array = _pending_ice.get(pid, [])
	_pending_ice.erase(pid)
	var pc := _pcs.get(pid) as WebRTCPeerConnection
	if pc == null:
		return
	for entry_v in queued:
		var entry := entry_v as Dictionary
		_apply_ice_candidate(pid, pc, str(entry["mid"]), int(entry["index"]), str(entry["candidate"]))


func _apply_ice_candidate(
	pid: String, pc: WebRTCPeerConnection, mid: String, index: int, candidate: String
) -> void:
	var error := pc.add_ice_candidate(mid, index, candidate)
	if error != OK:
		push_warning("WebRTCMultiplayerConnection: ICE rejected for %s (err=%d)" % [pid, error])


func _on_session_description_created(
	sdp_type: String, sdp: String, pid: String, gen: int, epoch: int
) -> void:
	if int(_pc_epochs.get(pid, -1)) != epoch:
		return
	var pc := _pcs.get(pid) as WebRTCPeerConnection
	if pc == null:
		return
	pc.set_local_description(sdp_type, sdp)
	_source.send(pid, {
		"v": 1, "gen": gen, "kind": "sdp", "sdp_type": sdp_type, "sdp": sdp,
	})
	_track_sdp_for_retransmit(pid, gen, epoch, sdp_type, sdp)


func _on_ice_candidate_created(
	mid: String, index: int, candidate: String, pid: String, gen: int, epoch: int
) -> void:
	if int(_pc_epochs.get(pid, -1)) == epoch:
		_source.send(pid, {
			"v": 1, "gen": gen, "kind": "ice", "mid": mid,
			"index": index, "candidate": candidate,
		})


func _on_source_peer_left(pid: String) -> void:
	_pending_peer_ids.erase(pid)
	if _ready_peer_set.has(pid) or _recovering_peers.has(pid):
		return
	_cancel_timer(pid)
	_cancel_restart_timer(pid)
	_cancel_sdp_retransmit(pid)
	_departed[pid] = true
	_awaiting_rejoin_gen0.erase(pid)
	_gens.erase(pid)
	_remote_desc_set.erase(pid)
	_pending_ice.erase(pid)
	_known_peers.erase(pid)
	var pc: Variant = _pcs.get(pid)
	if pc is WebRTCPeerConnection:
		(pc as WebRTCPeerConnection).close()
	_pcs.erase(pid)


func _seed_present_peers(signaling_source) -> void:
	if signaling_source == null:
		return
	if signaling_source.has_method("get_present_peers"):
		var peers: Variant = signaling_source.call("get_present_peers")
		if peers is Array:
			for peer_id_v in peers:
				_on_peer_discovered(str(peer_id_v))
		else:
			push_warning("WebRTCMultiplayerConnection: get_present_peers() did not return Array")
	# The cache above is what the source happened to overhear, which is all a
	# source can offer synchronously. Ask for the authoritative room as well;
	# the answer lands on present_peers_updated, or never, on a platform that
	# does not implement it. Nothing here waits for it.
	if signaling_source.has_method("request_present_peers"):
		signaling_source.call("request_present_peers")


## Reconcile against an authoritative room snapshot.
##
## Adds peers the local view missed, and retires peers the room no longer lists
## through the ordinary departure path -- exactly as strong as a peer_left and
## no stronger. _on_source_peer_left keeps ready and recovering peers, because a
## datagram path is allowed to outlive the signaling room. What it does retire
## is a peer still mid-handshake, whose SDP retransmit and restart timers would
## otherwise keep firing at someone already gone, and a peer queued as pending
## before start() completed, which has nothing else to retract it.
##
## Safe to apply on arrival: the server computes and sends a snapshot without an
## await, so the room it reports always matches its position in the ordered
## message stream -- a peer joining after it is announced after it.
func _on_present_peers_snapshot(peer_ids: Array) -> void:
	var present: Dictionary = {}
	for peer_id_v in peer_ids:
		var pid := str(peer_id_v)
		if pid.is_empty() or pid == local_peer_id:
			continue
		present[pid] = true
	# Copied before iterating: _on_source_peer_left mutates both collections.
	var tracked: Array[String] = _pending_peer_ids.duplicate()
	for pid in _known_peers:
		if not tracked.has(pid):
			tracked.append(pid)
	for pid in tracked:
		if not present.has(pid):
			_on_source_peer_left(pid)
	for pid in present.keys():
		_on_peer_discovered(pid)


func _attach_multiplayer_signals() -> void:
	if _multiplayer_api == null:
		return
	if not _multiplayer_api.peer_connected.is_connected(_on_engine_peer_connected):
		_multiplayer_api.peer_connected.connect(_on_engine_peer_connected)
	if not _multiplayer_api.peer_disconnected.is_connected(_on_engine_peer_disconnected):
		_multiplayer_api.peer_disconnected.connect(_on_engine_peer_disconnected)


func _detach_multiplayer_signals() -> void:
	if _multiplayer_api == null:
		return
	if _multiplayer_api.peer_connected.is_connected(_on_engine_peer_connected):
		_multiplayer_api.peer_connected.disconnect(_on_engine_peer_connected)
	if _multiplayer_api.peer_disconnected.is_connected(_on_engine_peer_disconnected):
		_multiplayer_api.peer_disconnected.disconnect(_on_engine_peer_disconnected)


func _on_engine_peer_connected(net_id: int) -> void:
	if _active and _rpc_host != null:
		_rpc_host.rpc_id(net_id, &"_identify", local_peer_id)


func _on_engine_peer_disconnected(net_id: int) -> void:
	var mapped: Variant = _net_to_peer.get(net_id)
	if mapped == null:
		return
	var pid := str(mapped)
	if _recovering_peers.has(pid):
		_ready_peer_set.erase(pid)
		return
	if _active and _known_peers.has(pid) and request_recovery(pid):
		return
	_ready_peer_set.erase(pid)
	_finalize_peer_loss(pid, net_id)


@rpc("any_peer", "call_remote", "reliable")
func _identify(peer_id: String) -> void:
	if _multiplayer_api != null:
		receive_identify(peer_id, _multiplayer_api.get_remote_sender_id())


## Compatibility RPC hosts forward `_identify` here with their sender id.
func receive_identify(peer_id: String, sender_net_id: int) -> void:
	var validation_error := _validate_identify(peer_id, sender_net_id)
	if not validation_error.is_empty():
		_reject_identify(peer_id, sender_net_id, validation_error)
		return
	var recovery: Variant = _recovering_peers.get(peer_id)
	_peer_to_net[peer_id] = sender_net_id
	_net_to_peer[sender_net_id] = peer_id
	_cancel_timer(peer_id)
	_cancel_restart_timer(peer_id)
	_cancel_sdp_retransmit(peer_id)
	_ready_peer_set[peer_id] = true
	peer_ready.emit(peer_id, sender_net_id)
	if recovery is Dictionary:
		_recovering_peers.erase(peer_id)
		var started := int((recovery as Dictionary).get("started_msec", Time.get_ticks_msec()))
		peer_recovered.emit(peer_id, sender_net_id, maxi(0, Time.get_ticks_msec() - started))
	_maybe_emit_connection_ready()


func _validate_identify(peer_id: String, sender_net_id: int) -> String:
	if peer_id.is_empty():
		return "empty peer id"
	if sender_net_id <= 0:
		return "invalid sender net id %d" % sender_net_id
	if not _known_peers.has(peer_id):
		return "peer was not authorized by signaling"
	var expected := derive_net_id(peer_id)
	if sender_net_id != expected:
		return "net id mismatch (sender=%d expected=%d)" % [sender_net_id, expected]
	var mapped_peer: Variant = _net_to_peer.get(sender_net_id)
	if mapped_peer != null and str(mapped_peer) != peer_id:
		return "sender net id is already mapped to %s" % str(mapped_peer)
	var mapped_net: Variant = _peer_to_net.get(peer_id)
	if mapped_net != null and int(mapped_net) != sender_net_id:
		return "peer id is already mapped to net id %d" % int(mapped_net)
	var recovery: Variant = _recovering_peers.get(peer_id)
	if recovery is Dictionary and int((recovery as Dictionary).get("net_id", -1)) != sender_net_id:
		return "recovery net id changed"
	return ""


func _reject_identify(peer_id: String, sender_net_id: int, reason: String) -> void:
	var message := "identify rejected for %s from sender %d: %s" % [peer_id, sender_net_id, reason]
	var recovering_pid := _recovery_peer_for_identify(peer_id, sender_net_id)
	if not recovering_pid.is_empty():
		_fail_recovery(recovering_pid, message)
		return
	var cleanup_pid := _peer_for_sender(sender_net_id)
	if cleanup_pid.is_empty() and _known_peers.has(peer_id) \
			and not _ready_peer_set.has(peer_id):
		cleanup_pid = peer_id
	_cleanup_unidentified_peer(cleanup_pid)
	_fail_connection(message)


func _recovery_peer_for_identify(peer_id: String, sender_net_id: int) -> String:
	if _recovering_peers.has(peer_id):
		return peer_id
	for pid_v in _recovering_peers.keys():
		var pid := str(pid_v)
		if int((_recovering_peers[pid] as Dictionary).get("net_id", -1)) == sender_net_id:
			return pid
	return ""


func _peer_for_sender(sender_net_id: int) -> String:
	var mapped: Variant = _net_to_peer.get(sender_net_id)
	if mapped != null:
		return str(mapped)
	for pid in _known_peers:
		if derive_net_id(pid) == sender_net_id:
			return pid
	return ""


func _cleanup_unidentified_peer(pid: String) -> void:
	if pid.is_empty() or _ready_peer_set.has(pid):
		return
	_cancel_timer(pid)
	_cancel_restart_timer(pid)
	_cancel_sdp_retransmit(pid)
	_gens.erase(pid)
	_remote_desc_set.erase(pid)
	_pending_ice.erase(pid)
	_known_peers.erase(pid)
	var net_id := derive_net_id(pid)
	if _mesh != null and _mesh.has_peer(net_id):
		_mesh.remove_peer(net_id)
	var pc: Variant = _pcs.get(pid)
	if pc is WebRTCPeerConnection:
		(pc as WebRTCPeerConnection).close()
	_pcs.erase(pid)


func _maybe_emit_connection_ready() -> void:
	if _known_peers.is_empty():
		return
	for pid in _known_peers:
		if not _ready_peer_set.has(pid):
			return
	connection_ready.emit()
	transport_ready.emit()


func _start_connect_timeout(pid: String) -> void:
	_cancel_timer(pid)
	var timer := Timer.new()
	timer.wait_time = _connect_timeout_for(pid)
	timer.one_shot = true
	timer.timeout.connect(_on_connect_timeout.bind(pid))
	add_child(timer)
	timer.start()
	_timers[pid] = timer


func _connect_timeout_for(pid: String) -> float:
	var recovery: Variant = _recovering_peers.get(pid)
	if recovery is Dictionary:
		var remaining := int((recovery as Dictionary).get("deadline_msec", 0)) \
			- Time.get_ticks_msec()
		return maxf(0.05, minf(recovery_retry_sec, float(remaining) / 1000.0))
	if udp_first and int(_gens.get(pid, 0)) == 0:
		return minf(udp_first_timeout_sec, connect_timeout_sec)
	return connect_timeout_sec


func _on_connect_timeout(pid: String) -> void:
	if _ready_peer_set.has(pid):
		return
	if _recovering_peers.has(pid):
		_on_recovery_timeout(pid)
		return
	var gen := int(_gens.get(pid, 0))
	if gen >= MAX_GEN:
		_fail_peer(pid)
		return
	var next_gen := gen + 1
	if _rebuild_peer_connection(pid, next_gen):
		_announce_restart(pid, next_gen)


func _mark_peer_recovering(pid: String, net_id: int) -> void:
	if _recovering_peers.has(pid):
		return
	var now := Time.get_ticks_msec()
	_recovering_peers[pid] = {
		"net_id": net_id,
		"started_msec": now,
		"deadline_msec": now + maxi(1, roundi(recovery_timeout_sec * 1000.0)),
		"attempt": 1,
	}
	_ready_peer_set.erase(pid)
	peer_recovery_started.emit(pid, net_id)


func _on_recovery_timeout(pid: String) -> void:
	var recovery: Variant = _recovering_peers.get(pid)
	if not (recovery is Dictionary):
		return
	var entry := recovery as Dictionary
	if Time.get_ticks_msec() >= int(entry.get("deadline_msec", 0)):
		_fail_recovery(pid, "recovery timeout")
		return
	entry["attempt"] = int(entry.get("attempt", 1)) + 1
	_recovering_peers[pid] = entry
	var next_gen := int(_gens.get(pid, 0)) + 1
	if _rebuild_peer_connection(pid, next_gen):
		_announce_restart(pid, next_gen)


func _fail_recovery(pid: String, reason: String) -> void:
	var recovery: Variant = _recovering_peers.get(pid)
	if not (recovery is Dictionary):
		return
	var net_id := int((recovery as Dictionary).get("net_id", derive_net_id(pid)))
	_recovering_peers.erase(pid)
	_cancel_timer(pid)
	_cancel_restart_timer(pid)
	_cancel_sdp_retransmit(pid)
	_ready_peer_set.erase(pid)
	_peer_to_net.erase(pid)
	_net_to_peer.erase(net_id)
	if _mesh != null and _mesh.has_peer(net_id):
		_mesh.remove_peer(net_id)
	var pc: Variant = _pcs.get(pid)
	if pc is WebRTCPeerConnection:
		(pc as WebRTCPeerConnection).close()
	_pcs.erase(pid)
	push_error("WebRTCMultiplayerConnection: peer %s %s" % [pid, reason])
	peer_lost.emit(pid, net_id)


func _finalize_peer_loss(pid: String, net_id: int) -> void:
	_recovering_peers.erase(pid)
	_peer_to_net.erase(pid)
	_net_to_peer.erase(net_id)
	if _mesh != null and _mesh.has_peer(net_id):
		_mesh.remove_peer(net_id)
	peer_lost.emit(pid, net_id)


func _fail_peer(pid: String) -> void:
	_cancel_timer(pid)
	_cancel_restart_timer(pid)
	_cancel_sdp_retransmit(pid)
	_fail_connection("peer %s connect timeout" % pid)


func _fail_connection(reason: String) -> void:
	push_error("WebRTCMultiplayerConnection: " + reason)
	connection_failed.emit(reason)
	transport_failed.emit(reason)


func _cancel_timer(pid: String) -> void:
	var timer := _timers.get(pid) as Timer
	if timer != null:
		timer.stop()
		timer.queue_free()
	_timers.erase(pid)


func _announce_restart(pid: String, gen: int) -> void:
	_awaiting_rejoin_gen0.erase(pid)
	_cancel_restart_timer(pid)
	_source.send(pid, {"v": 1, "gen": gen, "kind": "restart"})
	var timer := Timer.new()
	timer.wait_time = RESTART_ANNOUNCE_INTERVAL_SEC
	timer.timeout.connect(_on_restart_announce_tick.bind(pid, gen))
	add_child(timer)
	timer.start()
	_restart_timers[pid] = timer


func _on_restart_announce_tick(pid: String, gen: int) -> void:
	if int(_gens.get(pid, 0)) != gen or _ready_peer_set.has(pid):
		_cancel_restart_timer(pid)
		return
	_source.send(pid, {"v": 1, "gen": gen, "kind": "restart"})


func _track_sdp_for_retransmit(
	pid: String, gen: int, epoch: int, sdp_type: String, sdp: String
) -> void:
	_cancel_sdp_retransmit(pid)
	var timer := Timer.new()
	timer.wait_time = SDP_RETRANSMIT_INTERVAL_SEC
	timer.timeout.connect(_on_sdp_retransmit_tick.bind(pid))
	add_child(timer)
	timer.start()
	_sdp_retransmits[pid] = {
		"gen": gen, "epoch": epoch, "sdp_type": sdp_type, "sdp": sdp, "timer": timer,
	}


func _on_sdp_retransmit_tick(pid: String) -> void:
	var entry: Variant = _sdp_retransmits.get(pid)
	if not (entry is Dictionary):
		return
	var current := entry as Dictionary
	if int(_pc_epochs.get(pid, -1)) != int(current["epoch"]) \
			or int(_gens.get(pid, 0)) != int(current["gen"]) \
			or _ready_peer_set.has(pid):
		_cancel_sdp_retransmit(pid)
		return
	_source.send(pid, {
		"v": 1, "gen": int(current["gen"]), "kind": "sdp",
		"sdp_type": str(current["sdp_type"]), "sdp": str(current["sdp"]),
	})


func _cancel_sdp_retransmit(pid: String) -> void:
	var entry: Variant = _sdp_retransmits.get(pid)
	if entry is Dictionary:
		var timer := (entry as Dictionary).get("timer") as Timer
		if timer != null:
			timer.stop()
			timer.queue_free()
	_sdp_retransmits.erase(pid)


func _cancel_restart_timer(pid: String) -> void:
	var timer := _restart_timers.get(pid) as Timer
	if timer != null:
		timer.stop()
		timer.queue_free()
	_restart_timers.erase(pid)


func _attach_source_signals(source) -> void:
	if source == null:
		return
	if not source.sig_received.is_connected(_on_sig_received):
		source.sig_received.connect(_on_sig_received)
	if not source.peer_joined.is_connected(_on_peer_discovered):
		source.peer_joined.connect(_on_peer_discovered)
	if not source.peer_left.is_connected(_on_source_peer_left):
		source.peer_left.connect(_on_source_peer_left)
	if source.has_signal("connection_config_updated") \
			and not source.connection_config_updated.is_connected(_on_connection_config_updated):
		source.connection_config_updated.connect(_on_connection_config_updated)
	if source.has_signal("present_peers_updated") \
			and not source.present_peers_updated.is_connected(_on_present_peers_snapshot):
		source.present_peers_updated.connect(_on_present_peers_snapshot)


func _detach_source_signals(source) -> void:
	if source == null:
		return
	if source.sig_received.is_connected(_on_sig_received):
		source.sig_received.disconnect(_on_sig_received)
	if source.peer_joined.is_connected(_on_peer_discovered):
		source.peer_joined.disconnect(_on_peer_discovered)
	if source.peer_left.is_connected(_on_source_peer_left):
		source.peer_left.disconnect(_on_source_peer_left)
	if source.has_signal("connection_config_updated") \
			and source.connection_config_updated.is_connected(_on_connection_config_updated):
		source.connection_config_updated.disconnect(_on_connection_config_updated)
	if source.has_signal("present_peers_updated") \
			and source.present_peers_updated.is_connected(_on_present_peers_snapshot):
		source.present_peers_updated.disconnect(_on_present_peers_snapshot)


func _on_connection_config_updated(config: Dictionary) -> void:
	_set_connection_config(config)


func _set_connection_config(config: Dictionary) -> void:
	_connection_config = config.duplicate(true)
	var servers: Variant = _connection_config.get("iceServers", [])
	_ice_servers = (servers as Array).duplicate(true) if servers is Array else []


func _next_epoch() -> int:
	_epoch_seq += 1
	return _epoch_seq


static func classify_generation(local_gen: int, incoming_gen: int) -> GenAction:
	if incoming_gen < local_gen:
		return GenAction.DROP_STALE
	if incoming_gen > local_gen:
		return GenAction.ADOPT
	return GenAction.PROCESS


static func derive_net_id(peer_id: String) -> int:
	var hash := 2166136261
	for byte in peer_id.to_utf8_buffer():
		hash = ((hash ^ byte) * 16777619) & 0xFFFFFFFF
	return (hash & 0x3FFFFFFF) + 2


static func ice_servers_for_generation(
	servers: Array, gen: int, udp_first_enabled: bool
) -> Array:
	return _udp_only_ice_servers(servers) if udp_first_enabled and gen == 0 else servers


static func _udp_only_ice_servers(servers: Array) -> Array:
	var had_relay := false
	var filtered: Array = []
	for entry_v in servers:
		if not (entry_v is Dictionary):
			filtered.append(entry_v)
			continue
		var entry := entry_v as Dictionary
		if not entry.has("urls"):
			filtered.append(entry_v)
			continue
		var urls: Variant = entry["urls"]
		var url_list: Array = urls if urls is Array else [urls]
		var kept: Array = []
		for url_v in url_list:
			var lower := str(url_v).to_lower()
			if lower.begins_with("turn:") or lower.begins_with("turns:"):
				had_relay = true
			if lower.begins_with("turns:"):
				continue
			if lower.begins_with("turn:") and lower.contains("transport=tcp"):
				continue
			kept.append(str(url_v))
		if kept.is_empty():
			continue
		if urls is Array:
			var copy := entry.duplicate()
			copy["urls"] = kept
			filtered.append(copy)
		else:
			filtered.append(entry_v)
	if had_relay and not _has_relay(filtered):
		return servers
	return filtered


static func _has_relay(servers: Array) -> bool:
	for entry_v in servers:
		if not (entry_v is Dictionary):
			continue
		var urls: Variant = (entry_v as Dictionary).get("urls")
		var url_list: Array = urls if urls is Array else [urls]
		for url_v in url_list:
			var lower := str(url_v).to_lower()
			if lower.begins_with("turn:") or lower.begins_with("turns:"):
				return true
	return false


static func _implements_signaling_source(source) -> bool:
	if source == null:
		return false
	for signal_name in [&"sig_received", &"peer_joined", &"peer_left"]:
		if not source.has_signal(signal_name):
			return false
	for method_name in [&"connect_room", &"send", &"close"]:
		if not source.has_method(method_name):
			return false
	return true


static func _probe_webrtc_available() -> bool:
	var pc := WebRTCPeerConnection.new()
	if pc.get_class() == "WebRTCPeerConnectionExtension":
		return false
	return pc.initialize({}) == OK
