## Headless test for CouchGames.set_verbose_logging: the WebRTC layer's console
## lines are off by default and the game's diagnostics flag turns them on.
##
##   godot --headless --path Project -s res://addons/couch-games-sdk/tests/verbose_logging_test.gd
##
## Real under test: CouchGames.set_verbose_logging on an SDK node that never
## enters the tree (so no backend starts), WebRTCMultiplayerConnection's static
## switch, and path_probe's console switch (on the web it also sets the browser
## flag window.__couchNetPathDebug, which a headless run can't see). Not
## covered: that the gen/ice print obeys the switch -- reading it would mean
## capturing the engine's stdout.
extends SceneTree

var _failed := false
var _checks := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== verbose logging ==")
	_expect(WebRTCMultiplayerConnection.verbose_logging, false, "WebRTC console logging is off by default")
	var probe: GDScript = load("res://addons/couch-games-sdk/webrtc/path_probe.gd")
	_expect(probe.is_console_logging(), false, "the NETPATH console echo is off by default")
	var sdk: Node = load("res://addons/couch-games-sdk/core/couch_games_sdk.gd").new()
	sdk.set_verbose_logging(true)
	_expect(WebRTCMultiplayerConnection.verbose_logging, true, "set_verbose_logging(true) turns the WebRTC lines on")
	_expect(probe.is_console_logging(), true, "...and the NETPATH console echo")
	sdk.set_verbose_logging(false)
	_expect(WebRTCMultiplayerConnection.verbose_logging, false, "set_verbose_logging(false) turns the WebRTC lines off again")
	_expect(probe.is_console_logging(), false, "...and the NETPATH console echo")
	sdk.free()
	if _failed:
		printerr("VERBOSE_LOGGING_TEST: FAILED")
		quit(1)
	else:
		print("VERBOSE_LOGGING_TEST_OK: %d check(s)" % _checks)
		quit(0)


func _expect(actual: Variant, expected: Variant, what: String) -> void:
	_checks += 1
	if actual == expected:
		print("  PASS: " + what)
	else:
		_failed = true
		printerr("  FAIL: %s (expected %s, got %s)" % [what, expected, actual])
