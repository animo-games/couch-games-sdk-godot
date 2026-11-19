## Live single-account acceptance only. Never invokes Steam outside the bridge.
extends SceneTree
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		printerr("FAIL: " + message)

func _run() -> void:
	var app_id := 0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--app-id="):
			var raw := arg.trim_prefix("--app-id=")
			if raw.is_valid_int():
				app_id = int(raw)
	if app_id <= 0:
		printerr("FAIL: --app-id=<actual-positive-id> is required")
		quit(1)
		return
	ProjectSettings.set_setting("couch_games/backend", "steam")
	ProjectSettings.set_setting("couch_games/steam/app_id", app_id)
	ProjectSettings.set_setting("couch_games/steam/game_id", "couch-sdk-steam-fixture")
	var sdk = load("res://addons/couch-games-sdk/core/couch_games_sdk.gd").new()
	root.add_child(sdk)
	var started := Time.get_ticks_msec()
	await sdk.init()
	var initialization_ms := Time.get_ticks_msec() - started
	check(Engine.has_singleton("Steam"), "pinned native extension loaded")
	check(sdk.backend_name == "steam" and sdk.initialization_state == "ready", "real Steam initialization")
	var backend = sdk.get_node("Backend")
	if failures == 0:
		check(backend.bridge.app_id == str(app_id), "Steam identified the requested App ID")
		check(backend.bridge.connected(), "Steam account logged on")
		check(sdk.supports("lobby_host"), "real lobby hosting capability")
	if failures:
		print("STEAM_LIVE_PROBE: ", JSON.stringify({"requested_app_id":app_id,
			"failures":failures,"state":sdk.initialization_state,"error":sdk.initialization_error}))
		sdk.free()
		quit(1)
		return
	var hosted = await sdk.lobby.host({"visibility":"private", "max_players":2})
	check(hosted.success, "private creation and entry callbacks succeeded")
	check(sdk.lobby.state == "joined" and not sdk.lobby.lobby_id.is_empty(), "live lobby membership joined")
	check(sdk.lobby.is_host() and sdk.lobby.get_players().size() == 1, "creating account owns single-member roster")
	var host_state: String = sdk.lobby.state
	sdk.lobby.leave()
	check(sdk.lobby.state == "idle" and not sdk.lobby.is_available, "leave removed membership")
	check(sdk.lobby.lobby_id.is_empty() and sdk.lobby.get_players().is_empty(), "leave cleared lobby ID and roster")
	var report := {"requested_app_id":app_id,"actual_app_id":backend.bridge.app_id,
		"backend":sdk.backend_name,"initialization_state":sdk.initialization_state,
		"initialization_ms":initialization_ms,"host_success":hosted.success,
		"state_after_host":host_state,"state_after_leave":sdk.lobby.state,"failures":failures}
	sdk.free()
	check(not is_instance_valid(backend), "SDK teardown released the backend and native bridge")
	report.failures = failures
	print("STEAM_LIVE_PROBE: ", JSON.stringify(report))
	quit(1 if failures else 0)
