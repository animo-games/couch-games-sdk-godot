## Headless test for the calls that mirror window.CouchGames verbs added after
## the first release: flush_saves, complete_campaign, delete_game_metadata,
## clear_game_metadata, track / flush_telemetry, and the response fields they
## answer with (already_completed, already_unlocked, flushed).
##
##   godot --headless --path Project -s res://addons/couch-games-sdk/tests/platform_calls_test.gd
##
## Real under test: the mock backend (what every editor run talks to) and
## CouchGamesSDKResponse.from_dict on both the mock's and the platform's shapes.
extends SceneTree

const MockBackend := preload("res://addons/couch-games-sdk/backends/mock_backend.gd")
const Response := preload("res://addons/couch-games-sdk/core/response.gd")

var _failed := false


func _init() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		_failed = true


func _run() -> void:
	var mock: Node = MockBackend.new()
	root.add_child(mock)
	mock.reset_persistence()
	mock.initialize()

	var flushed := Response.from_dict(await mock.flush_saves())
	_check(flushed.success and flushed.persisted and flushed.flushed == 0, "flush_saves answers persisted with nothing waiting")

	var first := Response.from_dict(await mock.complete_campaign())
	_check(first.success and not first.already_completed, "complete_campaign records the first time")
	var again := Response.from_dict(await mock.complete_campaign())
	_check(again.success and again.already_completed, "complete_campaign is write-once")

	await mock.set_game_metadata("settings", "volume", "7")
	await mock.set_game_metadata("settings", "subtitles", "on")
	var set_answer := Response.from_dict(await mock.set_game_metadata("audio", "music", "off"))
	_check(set_answer.payload.get("audio", {}).get("music") == "off", "set_game_metadata answers the metadata after the write")
	var deleted := Response.from_dict(await mock.delete_game_metadata("settings", "volume"))
	_check(not deleted.payload["settings"].has("volume") and not deleted.payload.has("volume"), "delete_game_metadata removes the key and its root mirror")
	_check(deleted.payload["settings"].get("subtitles") == "on", "delete_game_metadata keeps the other keys")
	var emptied := Response.from_dict(await mock.delete_game_metadata("audio", "music"))
	_check(not emptied.payload.has("audio"), "a category left with no keys disappears")
	var cleared := Response.from_dict(await mock.clear_game_metadata())
	var after_clear := Response.from_dict(await mock.get_game_metadata())
	_check(cleared.success and after_clear.payload.is_empty(), "clear_game_metadata deletes everything")

	mock.track("level_start", {"level": 3})
	mock.track("level_complete", {})
	await mock.flush_telemetry()
	_check(mock.tracked_events.size() == 2 and mock.tracked_events[0].name == "level_start", "track queues events in order")
	_check(int(mock.tracked_events[0].properties.level) == 3, "track keeps the properties")

	var unlocked := Response.from_dict(await mock.unlock_achievement("first_win"))
	var repeat := Response.from_dict(await mock.unlock_achievement("first_win"))
	_check(unlocked.success and not unlocked.already_unlocked and repeat.already_unlocked, "unlock_achievement reports a repeat")
	var achievements := Response.from_dict(await mock.get_achievements())
	_check(achievements.payload_array.size() == 1 and achievements.payload_array[0].key == "first_win" and achievements.payload_array[0].earned == true, "get_achievements answers an array, as the platform does")

	# The platform's own shapes, as they cross the JS bridge (numbers as floats).
	var platform := Response.from_dict({"success": true, "message": "", "alreadyCompleted": true})
	_check(platform.already_completed, "already_completed reads the platform's alreadyCompleted")
	var platform_flush := Response.from_dict({"success": true, "persisted": true, "flushed": 2.0, "message": ""})
	_check(platform_flush.flushed == 2, "flushed arrives as an int")
	var odd := Response.from_dict({"success": true, "alreadyCompleted": "yes", "flushed": "two"})
	_check(not odd.already_completed and odd.flushed == 0, "unexpected types degrade instead of failing")

	mock.reset_persistence()
	mock.queue_free()
	print("platform_calls_test: " + ("FAILED" if _failed else "OK"))
	quit(1 if _failed else 0)
