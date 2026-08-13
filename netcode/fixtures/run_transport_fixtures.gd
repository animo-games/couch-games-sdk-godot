## Headless entry point for the transport/session fixture corpus.
##
##   godot --headless --script netcode/fixtures/run_transport_fixtures.gd \
##     -- --fixtures=<dir>
##
## `--fixtures` points at couch-netcode-fixtures/transport/data -- same
## convention as run_fixtures.gd, a sibling corpus checkout, no vendored copy.
##
## Exit codes: 0 = no failures, 1 = at least one failure, 2 = the corpus could
## not be loaded. There is no UNIMPLEMENTED status for this corpus (see
## transport_fixture_runner.gd's header): every case either passes or fails.
extends SceneTree

const DEFAULT_FIXTURES := "../couch-netcode-fixtures/transport/data"


func _initialize() -> void:
	var fixtures_dir := DEFAULT_FIXTURES
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--fixtures="):
			fixtures_dir = argument.trim_prefix("--fixtures=")

	if fixtures_dir.is_relative_path():
		fixtures_dir = ProjectSettings.globalize_path("res://").path_join(fixtures_dir).simplify_path()

	# The loader's own completeness guards are checked before the real corpus:
	# a guard that has stopped guarding is invisible from a green run, because
	# the failure it prevents (an incomplete corpus) IS a green run.
	var guard_failures := CouchTransportFixtureRunner.self_test_load_corpus()
	if not guard_failures.is_empty():
		for guard_failure in guard_failures:
			printerr("corpus-loader self-test: %s" % guard_failure)
		quit(2)
		return
	print("corpus-loader self-test: 5 checks passed")

	print("transport corpus: %s" % fixtures_dir)
	var loaded := CouchTransportFixtureRunner.load_corpus(fixtures_dir)
	if not loaded["error"].is_empty():
		printerr("could not load corpus: %s" % loaded["error"])
		quit(2)
		return

	var cases: Array = loaded["cases"]
	var runner := CouchTransportFixtureRunner.new()
	var case_results := runner.run_all(cases)

	var failed: Array = []
	for result in case_results:
		if result.status == CouchTransportFixtureRunner.Status.FAILED:
			failed.append(result)

	for result in failed:
		printerr("FAIL [%s] %s: %s" % [result.tier, result.name, result.message])

	print("")
	var summary := CouchTransportFixtureRunner.summarize(case_results)
	for tier in summary:
		var counts: Dictionary = summary[tier]
		print("%-16s passed %3d   failed %3d" % [tier, counts["passed"], counts["failed"]])
	print(
		"total %d cases: %d passed, %d failed"
		% [case_results.size(), case_results.size() - failed.size(), failed.size()]
	)

	quit(1 if not failed.is_empty() else 0)
	return
