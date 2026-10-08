extends SceneTree
const _LiveFixture := preload("res://addons/couch-games-sdk/fixtures/steam/main.gd")
const SDK := preload("res://addons/couch-games-sdk/core/couch_games_sdk.gd")
const ProductionBridge := preload("res://addons/couch-games-sdk/steam/steam_bridge.gd")
const SteamBackend := preload("res://addons/couch-games-sdk/backends/steam_backend.gd")
const Bridge := preload("res://addons/couch-games-sdk/tests/steam/fake_bridge.gd")
const Awards := preload("res://addons/couch-games-sdk/steam/steam_achievements.gd")
const Wire := preload("res://addons/couch-games-sdk/steam/steam_events.gd")
const ExportFilter := preload("res://addons/couch-games-sdk/editor/steam_export_plugin.gd")
var checks := 0
var failures := 0
var _owned: Array = []
var _journal_index := 0
var _run_id := str(Time.get_unix_time_from_system()).replace(".", "_")
class HungBackend extends CouchGamesBackend:
	signal finish
	var shutdowns := 0
	func initialize() -> void: await finish
	func is_available() -> bool: return true
	func shutdown() -> void: shutdowns += 1
class HungMetadata extends CouchGamesBackend:
	signal finish
	func is_available() -> bool: return true
	func get_experience_data() -> Dictionary:
		await finish
		return {"success": true, "payload": {"experienceUrl": "late-metadata"}}
func _initialize() -> void:
	_run.call_deferred()
func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: " + message)
func _run() -> void:
	_selection()
	await _initialization()
	await _membership_events()
	await _fixture_start_order()
	await _lifecycle_validation()
	await _achievements()
	await _hardening_regressions()
	await _teardown_regressions()
	_native_callback_correlation()
	await _classic_achievements()
	await _ui()
	for node in _owned:
		if is_instance_valid(node): node.free()
	print("Steam deterministic contracts: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
func _selection() -> void:
	check(SDK.select_backend("steam", true, true, false, true, true, true) == "mock", "forced mock precedes explicit selection")
	check(SDK.select_backend("auto", false, true, true, true, true, true) == "couch", "parent Couch precedes Steam feature")
	check(SDK.select_backend("auto", false, false, false, true, true, true) == "steam", "native Steam feature selects Steam")
	check(SDK.select_backend("auto", false, false, false, false, true, true) == "local", "editor auto retains local")
	check(SDK.select_backend("auto", false, false, true, false, true, true) == "mock", "standalone Web retains mock")
	check(SDK.select_backend("steam", false, false, true, false, true, true) == "steam", "explicit Steam Web does not silently fall back")
	check(ExportFilter.excludes_from_web("res://addons/godotsteam/godotsteam.gdextension"), "Web excludes extension descriptor")
	check(ExportFilter.excludes_from_web("res://addons/godotsteam/linux64/libsteam_api.so"), "Web excludes Steam runtime")
	check(not ExportFilter.excludes_from_web("res://addons/couch-games-sdk/core/couch_games_sdk.gd"), "Web keeps shared core")
func _init_call(sdk: Node, result: Dictionary, key: String) -> void:
	await sdk.init()
	result[key] = sdk.initialization_state
func _initialization() -> void:
	var backend := HungBackend.new()
	var sdk := SDK.new()
	sdk.backend_override = backend
	sdk.initialization_timeout_ms = 20
	root.add_child(sdk)
	var result := {}
	_init_call(sdk, result, "first")
	_init_call(sdk, result, "second")
	while result.size() < 2: await process_frame
	check(result.first == "failed" and result.second == "failed", "all concurrent init callers resolve after timeout")
	check(backend.shutdowns == 1, "timed-out backend shut down")
	backend.finish.emit()
	check(backend.shutdowns == 2 and sdk.initialization_state == "failed", "late init cannot revive failed SDK")
	sdk.free()
	var metadata := HungMetadata.new()
	var with_metadata := SDK.new()
	with_metadata.backend_override = metadata
	with_metadata.initialization_timeout_ms = 20
	root.add_child(with_metadata)
	await with_metadata.init()
	check(with_metadata.initialization_state == "degraded", "hung optional metadata does not fail usable backend initialization")
	metadata.finish.emit()
	check(with_metadata.get_url() == "late-metadata", "late optional metadata can fill cache independently")
	with_metadata.free()
	var classic := SDK.new()
	classic.backend_override = CouchGamesMockBackend.new()
	root.add_child(classic)
	await classic.init()
	check(classic.get_url() == "https://couch.games/mock", "await init preserves responsive classic experience metadata")
	classic.free()
	ProjectSettings.set_setting("couch_games/backend", "steam")
	var missing := SDK.new()
	root.add_child(missing)
	await missing.init()
	check(missing.backend_name == "steam" and missing.initialization_state == "failed", "missing Steam dependency stays failed Steam")
	check(not missing.supports("achievements") and not missing.webrtc.is_available, "failed Steam exposes no usable capabilities/WebRTC")
	missing.free()
	ProjectSettings.set_setting("couch_games/backend", "auto")
func _backend(provider: Node) -> Node:
	var backend := SteamBackend.new()
	backend.bridge = provider
	backend.game_id = "sdk-fixture"
	backend.catalog = {"a": "ACH_A", "b": "ACH_B"}
	root.add_child(backend)
	_owned.append(backend)
	return backend
func _op(backend: Node, job: Dictionary, kind: String, id := "") -> void:
	job.result = await backend.lobby_host({"max_players": 3}) if kind == "host" else await backend.lobby_join(id)
	job.done = true
func _membership_events() -> void:
	var provider := Bridge.new()
	provider.hold_membership = true
	var host := _backend(provider)
	await host.initialize()
	var job := {"done": false}
	_op(host, job, "host")
	var busy: Dictionary = await host.lobby_host({})
	check(busy.metadata.error_code == "busy", "one membership operation at a time")
	host.lobby_leave()
	await process_frame
	check(job.done and job.result.metadata.error_code == "cancelled", "leave resolves cancelled caller")
	var abandoned: String = provider.requests[0].id
	provider.complete_next()
	check(provider.left.has(abandoned) and host.lobby_id.is_empty(), "late successful create is cleaned up")
	var timeout_job := {"done": false}
	_op(host, timeout_job, "host")
	var abandoned_timeout: String = provider.requests[0].id
	host.poll(Time.get_ticks_msec() + 100000)
	await process_frame
	check(timeout_job.done and timeout_job.result.metadata.error_code == "timeout", "bounded membership timeout")
	provider.complete_next()
	check(provider.left.has(abandoned_timeout), "late timeout callback releases membership")
	provider.hold_membership = false
	var response: Dictionary = await host.lobby_host({"max_players": 3})
	check(response.success and host.state == "joined", "host publishes metadata and enters")
	var id: String = host.lobby_id
	var guest_provider := Bridge.new()
	guest_provider.user_id = "76561198000000002"
	guest_provider.hub = provider.hub
	var guest := _backend(guest_provider)
	await guest.initialize()
	response = await guest.lobby_join(id)
	check(response.success and guest.state == "joined", "join validates host-assigned metadata and roster")
	check(guest.lobby_get_me().role == "guest" and guest.lobby_get_me().controllerSlot == 1, "guest gets creator-assigned slot")
	check(host.lobby_get_me().ping == -1, "Steam ping unavailable remains -1")
	var lobby := CouchLobby.new()
	lobby.setup(host)
	root.add_child(lobby)
	_owned.append(lobby)
	lobby.refresh_players()
	var events := []
	guest.lobby_event_received.connect(func(event, data, sender): events.append([event, data, sender]))
	check(lobby.try_send_event("value", {"n": 7}), "broadcast accepted")
	guest.poll(Time.get_ticks_msec())
	check(provider.sends.size() == 1 and provider.sends[0].peer == guest_provider.user_id, "broadcast excludes self")
	check(events.size() == 1 and typeof(events[0][1].n) == TYPE_FLOAT and events[0][2] == provider.user_id, "JSON normalization and authenticated sender")
	var send_count := provider.sends.size()
	lobby.try_send_event("value", null, {"user_id": guest_provider.user_id, "role": "host"})
	check(provider.sends.size() == send_count, "intersection targeting requires both filters")
	lobby.try_send_event("value", null, {"role": "guest"})
	check(provider.sends.size() == send_count + 1, "role targeting reaches guest")
	lobby.try_send_event("value", null, {"user_id": guest_provider.user_id})
	check(provider.sends.size() == send_count + 2, "user targeting reaches guest")
	check(not lobby.try_send_event("bad", Vector2.ONE), "native objects rejected before serialization")
	check(not lobby.try_send_event("large", "x".repeat(400000)), "oversized complete JSON envelope rejected")
	guest_provider.packets.clear()
	var before := events.size()
	for bytes in ["bad-json".to_utf8_buffer(), Wire.encode(id, "stale", "bad", null), Wire.encode("999", host.get("_token"), "bad", null), JSON.stringify({"wire_version": 2}).to_utf8_buffer()]:
		guest_provider.packets.append({"sender": provider.user_id, "bytes": bytes})
	guest_provider.packets.append({"sender": "outsider", "bytes": Wire.encode(id, host.get("_token"), "bad", null)})
	guest_provider.packets.append({"sender": provider.user_id, "bytes": "x".repeat(400000).to_utf8_buffer()})
	guest.poll(Time.get_ticks_msec())
	check(events.size() == before, "malformed, stale, incompatible, outsider and oversized receive rejected")
	guest_provider.peer_requested.emit("outsider")
	guest_provider.peer_requested.emit(provider.user_id)
	check(guest_provider.closed_peers.has("outsider") and guest_provider.accepted_peers == [provider.user_id], "peer sessions accepted only for validated members")
	var transport := CouchLobbyTransport.new(lobby)
	var gaps := []
	transport.transport_gap.connect(func(peer, reason): gaps.append([peer, reason]))
	provider.send_ok = false
	var envelope := {"v": 1, "epoch": 1, "kind": "hello", "seq": 1, "body": {}}
	check(not transport.broadcast(envelope), "CouchLobbyTransport returns provider rejection")
	check(gaps.size() == 1 and gaps[0][0] == guest_provider.user_id, "send rejection propagates transport gap while roster stays unchanged")
	provider.peer_failed.emit(guest_provider.user_id, "injected-link-failure")
	check(gaps.size() == 2 and lobby.get_players().size() == 2, "asynchronous link failure reaches transport with unchanged roster")
	transport.close()
	provider.peer_failed.emit(guest_provider.user_id, "after-close")
	check(gaps.size() == 2, "closed transport disconnects provider gap")
	provider.send_ok = true
	var guest_lobby := CouchLobby.new()
	guest_lobby.setup(guest)
	root.add_child(guest_lobby)
	_owned.append(guest_lobby)
	guest_lobby.refresh_players()
	var picked: Dictionary = await CouchSessionTransport.pick(lobby, null)
	check(picked.kind == CouchSessionTransport.KIND_LOBBY, "Steam auto session selects existing lobby transport")
	var guest_transport := CouchLobbyTransport.new(guest_lobby)
	var session := CouchSession.new(lobby, picked.transport)
	var guest_session := CouchSession.new(guest_lobby, guest_transport)
	var snapshots := []
	guest_session.snapshot_received.connect(func(body): snapshots.append(body))
	var intents := []
	var hellos := []
	var on_hello := func(sender): hellos.append(sender); session.broadcast_snapshot({"revision": 1})
	session.hello_received.connect(on_hello)
	session.intent_received.connect(func(body, sender): intents.append([body, sender]))
	session.evaluate(1000)
	guest_session.evaluate(1000)
	for step in range(6):
		host.poll(Time.get_ticks_msec())
		guest.poll(Time.get_ticks_msec())
		picked.transport.poll(1000 + step * 10)
		guest_transport.poll(1000 + step * 10)
		session.poll(1000 + step * 10)
		guest_session.poll(1000 + step * 10)
	check(snapshots.size() == 1 and snapshots[0].revision == 1, "real CouchSession hello carries a snapshot through fake Steam networking")
	check(guest_session.send_intent({"action": "pick"}), "handshaken guest intent accepted")
	host.poll(Time.get_ticks_msec())
	check(intents.size() == 1 and intents[0][1] == guest_provider.user_id, "session authenticates guest intent over Steam lobby transport")
	var hellos_before := hellos.size()
	provider.peer_failed.emit(guest_provider.user_id, "broken")
	guest_provider.peer_failed.emit(provider.user_id, "broken")
	check(not guest_session.send_intent({"action": "stale"}), "broken link blocks stale guest gameplay")
	for step in range(6):
		host.poll(Time.get_ticks_msec())
		guest.poll(Time.get_ticks_msec())
		session.poll(2000 + step * 10)
		guest_session.poll(2000 + step * 10)
	check(hellos.size() > hellos_before and snapshots.size() > 1, "peer gap requires fresh hello and baseline")
	check(guest_session.send_intent({"action": "fresh"}), "guest resumes after recovered baseline")
	host.poll(Time.get_ticks_msec())
	check(intents.size() == 2 and intents[1][0].action == "fresh", "stale action never replayed after recovery")
	session.hello_received.disconnect(on_hello)
	picked.transport.envelope_received.disconnect(session._on_envelope_received)
	picked.transport.transport_gap.disconnect(session._on_transport_gap)
	guest_transport.envelope_received.disconnect(guest_session._on_envelope_received)
	guest_transport.transport_gap.disconnect(guest_session._on_transport_gap)
	picked.transport.close()
	guest_transport.close()
	var invites := []
	host.lobby_join_requested.connect(func(value): invites.append(value))
	host.capture_launch_invitation(PackedStringArray(["+connect_lobby", "123456"]))
	provider.join_requested.emit("654321")
	check(invites == ["123456", "654321"], "launch and running-game invitation entry paths")
	check((await host.lobby_open_invite_overlay()).success, "invite overlay returns acceptance")
	provider.overlay_ok = false
	check(not (await host.lobby_open_invite_overlay()).success, "overlay unavailable reported")
	host.lobby_leave()
	guest_provider.notify_roster(id)
	check(guest.state == "failed" and guest.lobby_id.is_empty(), "original authority departure ends guest membership")
	host.shutdown()
	host.shutdown()
	check(provider.shutdown_calls == 1, "Steam teardown idempotent")
func _fixture_start_order() -> void:
	for guest_first in [false, true]:
		var provider := Bridge.new()
		var host := _backend(provider)
		await host.initialize()
		var response: Dictionary = await host.lobby_host({})
		check(response.success, "fixture startup host lobby created")
		var guest_provider := Bridge.new()
		guest_provider.user_id = "76561198000000002"
		guest_provider.hub = provider.hub
		var guest := _backend(guest_provider)
		await guest.initialize()
		response = await guest.lobby_join(host.lobby_id)
		check(response.success, "fixture startup guest joined")
		var host_lobby := CouchLobby.new()
		host_lobby.setup(host)
		host_lobby.refresh_players()
		var guest_lobby := CouchLobby.new()
		guest_lobby.setup(guest)
		guest_lobby.refresh_players()
		# The driver only needs sdk.lobby; do not run its live-Steam _ready.
		var host_sdk := SDK.new()
		var guest_sdk := SDK.new()
		host_sdk.lobby = host_lobby
		guest_sdk.lobby = guest_lobby
		var host_driver := _LiveFixture.new()
		var guest_driver := _LiveFixture.new()
		host_driver.sdk = host_sdk
		guest_driver.sdk = guest_sdk
		host_driver._revision = 42
		var snapshots := []
		if guest_first:
			guest_driver._start_session()
			guest_driver.session.snapshot_received.connect(func(body): snapshots.append(body))
			# Deliver several retries before the host installs its transport.
			for step in range(3):
				guest_driver.session.poll(Time.get_ticks_msec() + step * 600)
				host.poll(Time.get_ticks_msec())
			host_driver._start_session()
		else:
			host_driver._start_session()
			# A host's initial messages may reach an unstarted guest.
			guest.poll(Time.get_ticks_msec())
			guest_driver._start_session()
			guest_driver.session.snapshot_received.connect(func(body): snapshots.append(body))
		for step in range(6):
			host.poll(Time.get_ticks_msec())
			guest.poll(Time.get_ticks_msec())
			host_driver._process(0.0)
			guest_driver._process(0.0)
		check(guest_driver.session.active and guest_driver.session.local_slot == 1,
			"fixture guest session starts with guest_first=%s" % guest_first)
		check(not snapshots.is_empty() and snapshots.back() == {"fixture": true, "revision": 42},
			"fixture applies authoritative baseline with guest_first=%s" % guest_first)
		# Reuse both session objects across host leave and a new lobby.
		host_lobby.players_changed.connect(func(_players):
			host_driver.session.evaluate(Time.get_ticks_msec()))
		guest_lobby.players_changed.connect(func(_players):
			guest_driver.session.evaluate(Time.get_ticks_msec()))
		var old_epoch := guest_driver.session.epoch
		var snapshots_before := snapshots.size()
		var previous_lobby_id: String = host.lobby_id
		host.lobby_leave()
		guest_provider.notify_roster(previous_lobby_id)
		check(not guest_driver.session.active, "fixture guest stops on host leave")
		response = await host.lobby_host({})
		check(response.success, "fixture host creates replacement lobby")
		response = await guest.lobby_join(host.lobby_id)
		check(response.success, "fixture guest rejoins replacement lobby")
		# The initial roster arrived while joining; early host packets are
		# delivered while the old guest session is still stopped.
		guest.poll(Time.get_ticks_msec())
		guest_driver._start_session()
		host_driver._start_session()
		for step in range(6):
			host.poll(Time.get_ticks_msec())
			guest.poll(Time.get_ticks_msec())
			host_driver._process(0.0)
			guest_driver._process(0.0)
		check(guest_driver.session.active and guest_driver.session.epoch != old_epoch,
			"fixture Start resumes stopped guest into a fresh epoch")
		check(snapshots.size() > snapshots_before and snapshots.back().revision == 42,
			"fixture applies fresh baseline after leave and rejoin")
		host_driver.transport.close()
		guest_driver.transport.close()
		host_driver.free()
		guest_driver.free()
		host_sdk.free()
		guest_sdk.free()
		host_lobby.free()
		guest_lobby.free()
		host.lobby_leave()
		guest.lobby_leave()

func _award_call(awards: Node, key: String, job: Dictionary) -> void:
	job.result = await awards.unlock(key)
	job.done = true
func _new_awards(provider: Node, journal := "") -> Node:
	var awards := Awards.new()
	awards.timeout_ms = 20
	_journal_index += 1
	awards.journal_root = journal if not journal.is_empty() else "user://steam_contract_%s_%s" % [_run_id, _journal_index]
	root.add_child(awards)
	_owned.append(awards)
	awards.setup(provider, {"a": "ACH_A", "b": "ACH_B", "missing": "NOT_DEFINED"})
	return awards
func _achievements() -> void:
	var provider := Bridge.new()
	root.add_child(provider)
	_owned.append(provider)
	await provider.initialize(0)
	var awards := _new_awards(provider)
	var unlocks := []
	var confirmations := []
	awards.unlocked.connect(func(key): unlocks.append(key))
	awards.stored.connect(func(keys): confirmations.append(keys))
	check(awards.get_state("a").status == "locked", "read distinguishes locked")
	check((await awards.unlock("unknown")).error_code == "unknown-key", "unknown catalog key rejected")
	check((await awards.unlock("missing")).status == "error", "missing Steam definition rejected")
	awards.catalog.erase("missing")
	var a := {"done": false}
	var duplicate := {"done": false}
	_award_call(awards, "a", a)
	_award_call(awards, "a", duplicate)
	check(awards.pending.has("a") and FileAccess.file_exists(awards.get("_journal_path")), "validated award journaled before storage")
	awards.poll(Time.get_ticks_msec())
	check(provider.store_calls == 1 and unlocks == ["a"], "duplicate awards coalesce into one local transition and store")
	check(provider.set_calls == 1, "already-local pending award does not repeat SetAchievement")
	var b := {"done": false}
	_award_call(awards, "b", b)
	while not a.done or not duplicate.done or not b.done: await process_frame
	check(a.result.status == "pending" and not a.result.provider_acknowledged, "caller timeout returns unconfirmed pending")
	awards.poll(Time.get_ticks_msec() + 100000)
	check(provider.store_calls == 1, "timeout never frees outstanding native store")
	provider.stats_stored.emit("999", true)
	check(awards.pending.size() == 2, "wrong game ID callback ignored")
	provider.stats_stored.emit(provider.app_id, true)
	check(not awards.pending.has("a") and awards.pending.has("b"), "late callback acknowledges only captured batch")
	check(confirmations == [["a"]] and unlocks == ["a", "b"], "late callback confirms storage without duplicate unlock")
	awards.poll(Time.get_ticks_msec())
	check(provider.store_calls == 2, "new award stored in next serialized batch")
	provider.stats_stored.emit(provider.app_id, false)
	check(awards.pending.has("b"), "failed callback retains pending award")
	awards.poll(Time.get_ticks_msec())
	check(provider.store_calls == 2, "bounded backoff avoids immediate callback retry")
	awards.poll(Time.get_ticks_msec() + 100000)
	provider.stats_stored.emit(provider.app_id, true)
	check(awards.pending.is_empty() and confirmations == [["a"], ["b"]], "successful retry confirms pending batch")
	var calls: int = provider.store_calls
	check((await awards.unlock("a")).status == "already_unlocked" and provider.store_calls == calls, "acknowledged duplicates never store again")
	check(awards.get_unlocked().payload.achievements.size() == 2, "legacy unlocked list reports confirmed keys")
	provider.read_ok = false
	check(not awards.get_unlocked().success and awards.get_state("a").status == "error", "failed read never invents empty successful list or locked state")
	provider.read_ok = true
	var other := Bridge.new()
	other.user_id = "76561198000000003"
	root.add_child(other)
	_owned.append(other)
	await other.initialize(0)
	var offline := _new_awards(other)
	other.online = false
	var job := {"done": false}
	_award_call(offline, "a", job)
	while not job.done: await process_frame
	check(job.result.status == "pending" and other.store_calls == 0, "offline unlock journals and returns pending")
	var journal: String = offline.journal_root
	offline.shutdown()
	var restarted := _new_awards(other, journal)
	check(restarted.pending.has("a") and restarted.get_state("a").status == "pending", "relaunch retains journal despite local Steam unlocked bit")
	var restarted_unlocks := []
	restarted.unlocked.connect(func(key): restarted_unlocks.append(key))
	var isolated_provider := Bridge.new()
	isolated_provider.user_id = "76561198000000004"
	root.add_child(isolated_provider)
	_owned.append(isolated_provider)
	await isolated_provider.initialize(0)
	var isolated := _new_awards(isolated_provider, journal)
	check(isolated.pending.is_empty(), "different account never consumes another journal")
	other.online = true
	other.store_ok = false
	restarted.poll(Time.get_ticks_msec())
	check(restarted.pending.has("a") and restarted.get("_inflight").is_empty(), "synchronous store rejection retains award but releases request")
	check(restarted_unlocks.is_empty(), "restart retry never repeats a journaled local unlock signal")
	other.store_ok = true
	restarted.poll(Time.get_ticks_msec() + 100000)
	other.user_id = "76561198000000005"
	other.stats_stored.emit(other.app_id, true)
	check(restarted.pending.has("a") and not restarted.is_ready(), "account change cannot acknowledge old account journal")
	var unknown := Bridge.new()
	unknown.user_id = ""
	root.add_child(unknown)
	_owned.append(unknown)
	await unknown.initialize(0)
	var unknown_awards := _new_awards(unknown, journal)
	check((await unknown_awards.unlock("a")).status == "unavailable", "unknown account cannot open pending journal")
	var corrupt_provider := Bridge.new()
	corrupt_provider.user_id = "76561198000000006"
	root.add_child(corrupt_provider)
	_owned.append(corrupt_provider)
	await corrupt_provider.initialize(0)
	var corrupt := _new_awards(corrupt_provider)
	var corrupt_path: String = corrupt.get("_journal_path")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(corrupt.journal_root))
	var file := FileAccess.open(corrupt_path, FileAccess.WRITE)
	file.store_string("{broken")
	file.close()
	corrupt.shutdown()
	var reload_corrupt := _new_awards(corrupt_provider, corrupt.journal_root)
	check(not reload_corrupt.is_ready(), "corrupt journal fails visibly instead of dropping awards")
func _classic_achievements() -> void:
	var backend := CouchGamesMockBackend.new()
	root.add_child(backend)
	_owned.append(backend)
	await backend.initialize()
	var facade := CouchAchievements.new()
	root.add_child(facade)
	_owned.append(facade)
	var key := "contract_" + str(OS.get_process_id())
	facade.setup(backend, {key: ""})
	var classic_lobby := CouchLobby.new()
	classic_lobby.setup(backend)
	root.add_child(classic_lobby)
	_owned.append(classic_lobby)
	check(not classic_lobby.try_send_event("invalid", Vector2.ONE), "shared try-send rejects non-JSON payload on classic providers")
	classic_lobby.refresh_players()
	check(classic_lobby.state == "joined", "externally supplied local/mock roster maps to joined state")
	backend.simulate_achievement_pending = true
	var result := await facade.unlock(key)
	check(result.status == "pending" and result.locally_unlocked and not result.provider_acknowledged, "mock supports explicit pending storage")
	backend.simulate_achievement_pending = false
	facade.set("_retry_at", 0)
	var response := await facade.flush()
	check(response.success and (await facade.unlock(key)).status == "already_unlocked", "mock facade automatically retries and confirms storage")
	backend.simulate_achievements_unavailable = true
	check(not (await facade.get_unlocked()).success, "unavailable classic read stays unavailable")
	check((await facade.get_state(key)).status == "unavailable", "unknown classic read is never locked")
	backend.simulate_achievements_unavailable = false
	check((await backend.unlock_achievement("legacy_unconfigured_key")).success, "legacy classic calls retain unrestricted keys and response semantics")

func _lifecycle_validation() -> void:
	var production := ProductionBridge.new()
	production.initialized = true
	production.set("_creating", 42)
	check(not production.create_lobby(43, "private", 2) and not production.join_lobby(43, "1000"), "production bridge retains outstanding uncorrelated create after SDK timeout")
	production.set("_creating", -1)
	production.set("_joining", 44)
	production.set("_joining_id", "1000")
	production._on_joined(999, 0, false, 1)
	check(production.get("_joining") == 44, "unrelated create/join callback cannot consume pending native join")
	production.initialized = false
	production.free()
	var provider := Bridge.new()
	var host := _backend(provider)
	await host.initialize()
	check((await host.lobby_host({})).success, "lifecycle fixture host enters")
	var id: String = host.lobby_id
	var guest_provider := Bridge.new()
	guest_provider.user_id = "76561198000000011"
	guest_provider.hub = provider.hub
	var guest := _backend(guest_provider)
	await guest.initialize()
	provider.hub.lobbies[id].maximum = 1
	var response: Dictionary = await guest.lobby_join(id)
	check(response.metadata.error_code == "full", "full lobby returns distinct normalized error")
	provider.hub.lobbies[id].maximum = 2
	provider.set_metadata(id, "couch_content", "incompatible")
	response = await guest.lobby_join(id)
	check(response.metadata.error_code == "incompatible" and guest.lobby_id.is_empty(), "incompatible content rejects and leaves membership")
	provider.set_metadata(id, "couch_content", "1")
	guest_provider.hold_membership = true
	var job := {"done": false}
	_op(guest, job, "join", id)
	guest.lobby_leave()
	guest_provider.complete_next()
	await process_frame
	check(job.done and job.result.metadata.error_code == "cancelled" and not provider.hub.lobbies[id].members.has(guest_provider.user_id), "late successful cancelled join is left")
	guest_provider.hold_membership = false
	provider.set_metadata(id, "couch_token", "")
	var metadata_job := {"done": false}
	_op(guest, metadata_job, "join", id)
	await process_frame
	guest.poll(Time.get_ticks_msec() + 100000)
	await process_frame
	check(metadata_job.done and metadata_job.result.metadata.error_code == "timeout", "missing metadata wait is bounded and releases membership")
	provider.set_metadata(id, "couch_token", "restored-token")
	guest_provider.hold_membership = true
	var old_job := {"done": false}
	_op(guest, old_job, "join", id)
	guest.lobby_leave()
	# Simulator can deliver generations out of order; production serializes
	# its uncorrelated native request and rejects the attempted replacement.
	guest_provider.hold_membership = false
	var new_job := {"done": false}
	_op(guest, new_job, "host")
	var current: Dictionary = guest_provider.requests.pop_back()
	guest_provider.request_entered.emit(current.generation, current.id, current.code)
	guest_provider.complete_next()
	await process_frame
	check(new_job.done and new_job.result.success and guest.lobby_id == current.id, "old successful callback cannot clear newer active lobby")
	check(guest_provider.left.has(id) and not guest_provider.left.has(current.id), "late cleanup leaves only the abandoned membership")
	var lobby := CouchLobby.new()
	lobby.setup(guest)
	root.add_child(lobby)
	_owned.append(lobby)
	var ordering := []
	lobby.player_joined.connect(func(_player): ordering.append("joined"))
	lobby.players_changed.connect(func(_players): ordering.append("changed"))
	lobby.refresh_players()
	check(ordering == ["joined", "changed"], "refresh preserves per-player before aggregate roster ordering")
	lobby.refresh_players()
	check(ordering.size() == 2, "identical refresh does not duplicate roster signals")
	host.shutdown()
	guest.shutdown()

func _ui() -> void:
	var provider := Bridge.new()
	var backend := SteamBackend.new()
	backend.bridge = provider
	backend.game_id = "sdk-ui-fixture"
	backend.catalog = {"a": "ACH_A"}
	var sdk := SDK.new()
	sdk.backend_override = backend
	root.add_child(sdk)
	var panel := CouchLobbyPanel.new()
	panel.sdk = sdk
	root.add_child(panel)
	await sdk.init()
	await process_frame
	check(panel.get("_host").visible and panel.get("_join").visible, "panel shows provider-owned Steam membership controls")
	check(sdk.initialization_state == "ready" and sdk.supports("achievements") and not sdk.supports("webrtc"), "Steam SDK configures services independently")
	check((await sdk.lobby.host()).success, "panel fixture hosts through public shared facade")
	var active_id: String = sdk.lobby.lobby_id
	panel.match_active = true
	provider.join_requested.emit("987654")
	check(panel.get("_confirmation").visible and sdk.lobby.lobby_id == active_id, "running invitation cannot silently abandon active match")
	panel.get("_confirmation").canceled.emit()
	panel.get("_confirmation").hide()
	check(sdk.lobby.lobby_id == active_id, "canceling invitation retains current membership")
	provider.online = false
	provider.connection_changed.emit(false)
	check(sdk.initialization_state == "degraded" and sdk.supports("achievements") and not sdk.supports("lobby_events"), "later networking failure degrades only networking capability")
	provider.online = true
	provider.connection_changed.emit(true)
	check(sdk.initialization_state == "ready", "restored provider updates readiness")
	panel.free()
	sdk.free()

func _hardening_regressions() -> void:
	var production := ProductionBridge.new()
	production.initialized = true
	production.set("_creating", 81)
	production.set("_joining", 82)
	production.set("_joining_id", "1000")
	production.shutdown()
	check(production.get("_creating") == -1 and production.get("_joining") == -1 and production.get("_joining_id").is_empty(), "native shutdown clears uncorrelated request reservations")
	var entries := []
	production.request_entered.connect(func(g, id, code): entries.append([g, id, code]))
	production._on_created(1, 1000)
	production._on_joined(1000, 0, false, 1)
	check(entries.is_empty(), "callbacks after native shutdown cannot resurrect membership")
	production.free()
	var provider := Bridge.new()
	root.add_child(provider)
	_owned.append(provider)
	await provider.initialize(0)
	var awards := _new_awards(provider)
	awards.catalog["a"] = {"steam": ""}
	provider.definitions["a"] = false
	var job := {"done": false}
	_award_call(awards, "a", job)
	while not job.done: await process_frame
	check(job.result.status == "pending" and provider.definitions.a, "empty dictionary Steam name defaults to stable game key")
	awards.shutdown()
	var path: String = awards.get("_journal_path")
	var invalid_files := [
		{"pending": ["a", 7], "local_keys": []},
		{"pending": ["a", "a"], "local_keys": []},
		{"pending": ["a"], "local_keys": "a"},
		{"pending": ["a"], "local_keys": ["b"]},
		{"pending": [""], "local_keys": []},
	]
	var too_many := []
	for index in range(129): too_many.append("key_%s" % index)
	invalid_files.append({"pending": too_many, "local_keys": []})
	for value in invalid_files:
		value.account = provider.app_id + "/" + provider.user_id
		var file := FileAccess.open(path, FileAccess.WRITE)
		var original := JSON.stringify(value)
		file.store_string(original)
		file.close()
		var recovered := _new_awards(provider, awards.journal_root)
		check(not recovered.is_ready() and recovered.pending.is_empty(), "invalid journal rejected atomically: " + original.left(60))
		check((await recovered.unlock("a")).status == "unavailable" and FileAccess.get_file_as_string(path) == original, "invalid journal remains intact after rejected unlock")
		recovered.shutdown()
	var host_provider := Bridge.new()
	var host := _backend(host_provider)
	await host.initialize()
	check((await host.lobby_host({"max_players": 3})).success, "roster hardening fixture host enters")
	var id: String = host.lobby_id
	var guest_provider := Bridge.new()
	guest_provider.user_id = "76561198000000021"
	guest_provider.hub = host_provider.hub
	var guest := _backend(guest_provider)
	await guest.initialize()
	check((await guest.lobby_join(id)).success, "roster hardening fixture guest enters")
	var departed := "76561198000000022"
	host_provider.hub.lobbies[id].members.append(departed)
	host._on_roster_changed(id)
	guest._on_roster_changed(id)
	check(guest.get("_members").has(departed), "third member validated before departure")
	# Membership changes before the authority publishes a new slot map.
	host_provider.hub.lobbies[id].members.erase(departed)
	host_provider.hub.lobbies[id].members.append("76561198000000023")
	guest._on_roster_changed(id)
	var delivered := []
	guest.lobby_event_received.connect(func(event, _data, _sender): delivered.append(event))
	guest_provider.packets.append({"sender": departed, "bytes": Wire.encode(id, guest.get("_token"), "stale", null)})
	guest_provider.peer_requested.emit(departed)
	guest.poll(Time.get_ticks_msec())
	check(delivered.is_empty() and not guest.get("_members").has(departed) and not guest_provider.accepted_peers.has(departed), "departed peer revoked while slot metadata lags new membership")
	host._on_roster_changed(id)
	guest.poll(Time.get_ticks_msec())
	check(guest.get("_members").has("76561198000000023") and guest.get("_roster_wait_until") == 0, "bounded slot wait resumes after authority publishes metadata")
	var lobby := CouchLobby.new()
	lobby.setup(guest)
	root.add_child(lobby)
	_owned.append(lobby)
	lobby.refresh_players()
	var transport := CouchLobbyTransport.new(lobby)
	transport.fault_delay_ms = 100
	transport.poll(10)
	check(transport.broadcast({"v": 1, "epoch": 1, "kind": "intent", "seq": 1, "body": {"stale": true}}), "delayed gameplay accepted before provider gap")
	var sends_before: int = guest_provider.sends.size()
	guest_provider.peer_failed.emit(host_provider.user_id, "broken")
	transport.poll(1000)
	check(guest_provider.sends.size() == sends_before and transport.fault_delay_dropped == 1, "provider gap discards delayed stale gameplay before recovery")
	transport.close()
	host_provider.hub.lobbies[id].members.append("76561198000000024")
	guest._on_roster_changed(id)
	var failure_states := []
	guest.lobby_state_changed.connect(func(value, _id): failure_states.append(value))
	guest.poll(Time.get_ticks_msec() + 100000)
	check(not failure_states.has("idle"), "failed roster cleanup never exposes an intermediate idle state to synchronous listeners")
	check(guest.state == "failed" and guest.lobby_id.is_empty(), "slot metadata wait fails visibly instead of holding a stale roster indefinitely")
	host.shutdown()
	guest.shutdown()

func _teardown_regressions() -> void:
	var rejecting := Bridge.new()
	rejecting.fail_metadata_after = 8
	var failed_host := _backend(rejecting)
	await failed_host.initialize()
	var rejected: Dictionary = await failed_host.lobby_host({})
	check(not rejected.success and rejected.metadata.error_code == "metadata-failed" and failed_host.state == "failed", "slot publication failure cannot overwrite failed entry with success/cancellation")
	failed_host.shutdown()
	var provider := Bridge.new()
	var backend := _backend(provider)
	await backend.initialize()
	check((await backend.lobby_host({})).success, "teardown fixture enters")
	provider.hold_membership = true
	var job := {"done": false}
	backend.lobby_state_changed.connect(func(value, _id):
		if value == "idle": _op(backend, job, "host"))
	var invites := []
	backend.lobby_join_requested.connect(func(id): invites.append(id))
	backend.shutdown()
	provider.join_requested.emit("12345")
	check(job.done and job.result.metadata.error_code == "initialization-failed" and provider.requests.is_empty(), "synchronous leave listener cannot reopen native membership during teardown")
	check(invites.is_empty(), "late invitation ignored after backend shutdown")

func _native_callback_correlation() -> void:
	var production := ProductionBridge.new()
	production.initialized = true
	production.set("_creating", 91)
	var results := []
	production.request_entered.connect(func(g, id, code): results.append([g, id, code]))
	production._on_created(1, 1000)
	check(results.is_empty() and not production.join_lobby(92, "1000"), "native create retains reservation until its LobbyEnter callback")
	production._on_joined(1000, 0, false, 1)
	check(results == [[91, "1000", ""]] and production.get("_creating") == -1, "native creation completes exactly once after both callbacks")
	production._on_joined(1000, 0, false, 1)
	check(results.size() == 1, "duplicate abandoned LobbyEnter cannot complete another operation")
	production.set("_creating", 93)
	production._on_joined(1001, 0, false, 1)
	check(results.size() == 1 and production.get("_creating") == 93, "native entry arriving before creation remains reserved")
	production._on_created(1, 1001)
	check(results.size() == 2 and results[1] == [93, "1001", ""], "native create handles callback order inversion")
	production.set("_creating", 94)
	production._on_created(2, 0)
	check(results.size() == 3 and results[2][2] == "unavailable" and production.get("_creating") == -1, "failed native creation releases reservation visibly")
	production.shutdown()
	production.free()
