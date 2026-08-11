## Headless entry point for the netcode conformance corpus.
##
##   godot --headless --script netcode/fixtures/run_fixtures.gd -- --fixtures=<dir>
##
## `--fixtures` points at the corpus `data/` directory in couch-netcode-fixtures.
## It defaults to a sibling checkout, which is the usual local layout; there is no
## vendored copy on purpose -- a copy is exactly what the shared corpus exists to
## prevent.
##
## Exit codes: 0 = no failures, 1 = at least one failure, 2 = the corpus could not
## be loaded. UNIMPLEMENTED cases do NOT fail the run; they are reported separately
## so a partial port shows honest progress instead of a green tick it has not earned.
extends SceneTree

const DEFAULT_FIXTURES := "../couch-netcode-fixtures/data"


func _initialize() -> void:
	var fixtures_dir := DEFAULT_FIXTURES
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--fixtures="):
			fixtures_dir = argument.trim_prefix("--fixtures=")

	if fixtures_dir.is_relative_path():
		fixtures_dir = ProjectSettings.globalize_path("res://").path_join(fixtures_dir).simplify_path()

	print("corpus: %s" % fixtures_dir)
	var loaded := CouchFixtureRunner.load_corpus(fixtures_dir)
	if not loaded["error"].is_empty():
		printerr("could not load corpus: %s" % loaded["error"])
		quit(2)
		return

	var cases: Array = loaded["cases"]
	var runner := CouchFixtureRunner.new()
	var case_results := runner.run_all(cases)

	var failed: Array = []
	var unimplemented := 0
	for result in case_results:
		match result.status:
			CouchFixtureRunner.Status.FAILED:
				failed.append(result)
			CouchFixtureRunner.Status.UNIMPLEMENTED:
				unimplemented += 1

	for result in failed:
		printerr("FAIL [%s] %s: %s" % [result.tier, result.name, result.message])

	print("")
	var summary := CouchFixtureRunner.summarize(case_results)
	for tier in summary:
		var counts: Dictionary = summary[tier]
		print(
			"%-16s passed %3d   failed %3d   unimplemented %3d"
			% [tier, counts["passed"], counts["failed"], counts["unimplemented"]]
		)
	print(
		"total %d cases: %d passed, %d failed, %d awaiting port"
		% [case_results.size(), case_results.size() - failed.size() - unimplemented, failed.size(), unimplemented]
	)

	quit(1 if not failed.is_empty() else 0)
