extends Node
const SDK := preload("res://addons/couch-games-sdk/core/couch_games_sdk.gd")
var failures := 0
func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		printerr("FAIL: " + message)
func _ready() -> void:
	var mode := "auto"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mode="): mode = arg.trim_prefix("--mode=")
	if OS.has_feature("web"):
		var browser: Object = JavaScriptBridge.get_interface("window")
		var query := str(browser.location.search)
		if query.contains("mode=steam"): mode = "steam"
		elif query.contains("mode=couch"): mode = "couch"
		else: mode = "mock"
	ProjectSettings.set_setting("couch_games/backend", mode)
	ProjectSettings.set_setting("couch_games/mock/enable_debug_overlay", false)
	ProjectSettings.set_setting("couch_games/initialization_timeout_ms", 2000)
	ProjectSettings.set_setting("couch_games/local/port", 0)
	var sdk := SDK.new()
	add_child(sdk)
	await sdk.init()
	var expect_extension := bool(ProjectSettings.get_setting("sdk_fixture/expect_steam_extension", false)) and not OS.has_feature("web")
	check(Engine.has_singleton("Steam") == expect_extension, "pinned extension loads only in installed native fixture")
	if mode == "steam" or (mode == "auto" and OS.has_feature("steam")):
		check(sdk.backend_name == "steam" and sdk.initialization_state == "failed" and not sdk.is_mock, "explicit Steam must fail visibly without an app/account")
		if expect_extension:
			check(not sdk.initialization_error.contains("Incompatible GodotSteam") and not sdk.initialization_error.contains("not installed"), "installed native failure comes from Steam environment")
		check(not sdk.initialization_error.is_empty() and not sdk.supports("lobby_events"), "Steam failure disables capabilities and exposes error")
		if OS.has_feature("web"):
			check(not ResourceLoader.exists("res://addons/couch-games-sdk/backends/steam_backend.gd"), "Web adapter excluded")
			check(not ResourceLoader.exists("res://addons/godotsteam/godotsteam.gdextension"), "Web extension excluded")
	else:
		var expected := mode
		if mode == "auto": expected = "local" if OS.is_debug_build() else "mock"
		check(sdk.backend_name == expected and sdk.initialization_state in ["ready", "degraded"], "shared initialization selects usable " + expected)
		check(sdk.lobby.is_available and sdk.lobby.get_players().size() > 0, "shared lobby usable")
		if mode == "couch":
			check(not sdk.is_mock and sdk.lobby.get_me().user_id == "browser-user", "Couch browser bridge supplies authenticated roster")
		if Engine.has_singleton("Steam"):
			# Observe lifecycle ownership without invoking the native singleton.
			check(sdk.get_node("Backend").get_node_or_null("SteamBridge") == null, "extension presence alone creates no Steam bridge")
	var report := {"mode": mode, "backend": sdk.backend_name, "state": sdk.initialization_state, "error": sdk.initialization_error, "failures": failures, "web": OS.has_feature("web"), "extension_installed": Engine.has_singleton("Steam")}
	print("SDK_PACKAGE_SMOKE: " + JSON.stringify(report))
	sdk.free()
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.sdkPackageResult = " + JSON.stringify(report), true)
	else:
		get_tree().quit(1 if failures else 0)
