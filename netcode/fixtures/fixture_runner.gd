## Runs the shared netcode conformance corpus against this addon's core.
##
## Corpus lives in couch-netcode-fixtures (schema handshakes.prediction.fixtures/v1).
## The reference C# runner is FixtureRunner.cs; this must agree with it case for case.
##
## The four rules the corpus imposes on a runner, and how they are met here:
##
##   1. FAIL on unknown actions and unknown keys, never skip. Every step is checked
##      against a per-action key allowlist before it runs. This is rule one because
##      the corpus has already been bitten by a branch that silently ignored a key,
##      leaving those declarations green while asserting nothing.
##   2. Compare the step log IN ORDER, including kind, slot and sequence.
##   3. Report tier, so a port that deliberately re-decides a policy case can show
##      100/100 invariants passing while failing a policy case BY DESIGN.
##   4. Model the snapshot stack by identity (see CouchScriptedWorld).
##
## A case whose action this build has not implemented yet reports UNIMPLEMENTED,
## which is deliberately NOT a pass and deliberately NOT a failure -- conflating
## either way would misreport how far the port has actually got.
class_name CouchFixtureRunner
extends RefCounted

const EXPECTED_SCHEMA := "handshakes.prediction.fixtures/v1"

enum Status { PASSED, FAILED, UNIMPLEMENTED }

## Sentinel returned by a driver that needs a core this build has not ported yet.
## Distinct from a failure string so the two can never be conflated in reporting.
const CORE_NOT_PORTED := "@core-not-ported"

## Keys every step may carry regardless of action.
const COMMON_KEYS := ["action", "at"]

## Per-action key allowlist. A step carrying anything not listed for its action is a
## failure: it means the fixture is asserting something this runner does not read.
const ACTION_KEYS := {
	"local-move":
	[
		"playerSlot", "dx", "dy", "requestSequence", "moveOutcomes", "expectPredicted",
		"expectSteps", "expectSkipReason", "epochAfterMove", "generationAfterMove", "stackOps",
	],
	"authoritative": ["op", "expectConsumed", "expectSteps", "moveOutcomes", "epochAfterMove"],
	"tick": ["expectSteps", "moveOutcomes", "epochAfterMove"],
	"reset": ["expectSteps"],
	"set-world":
	["epoch", "generation", "canReconcile", "canApplyRemote", "applyRemote", "rewindBudget"],
	"assert":
	[
		"pendingCount", "isDiverged", "needsRebaseline", "isAwaitingRebaseline",
		"recoveryAttempts", "hasGivenUp", "rewindCount", "rewindBudget", "worldEpoch",
		"worldGeneration", "rttMs", "sampleCount", "timeoutMs", "outstandingNonce",
		"suppressPrediction", "headToken", "oldestPendingSequence",
	],
	# Session-layer actions. Listed so an unknown-ACTION failure is distinguishable
	# from a not-yet-ported one; the runner reports these UNIMPLEMENTED until the
	# drain and recovery coordinators land.
	"frame":
	[
		"isPredicting", "currentLevel", "head", "expectActions", "expectSteps",
		"expectHeadConsumed", "expectCalls", "expectAuthorityProbeCount", "applyHeadUnpredicted",
	],
	"arrival":
	[
		"authoritySequence", "isLoadLevel", "isPredicting", "expectEnqueued", "expectActions",
		"expectSteps", "expectCalls",
	],
	"adopt-sync":
	["authoritySequence", "level", "paused", "operationCount", "expectCalls", "expectSteps", "expectActions"],
	"recovery": ["trigger", "expectActions", "canReachAuthority", "isGuest"],
	"transport-gap":
	[
		"expectActions", "expectCalls", "expectAuthorityProbeCount", "isPredicting",
		"canReachAuthority",
	],
	"rebaselined": ["expectActions"],
	"topology-changed": ["expectActions"],
	"local-world-replaced": ["expectActions", "expectCalls"],
}

## Actions this build can actually drive. Everything else in ACTION_KEYS is a known
## action awaiting its coordinator.
const IMPLEMENTED_ACTIONS := ["local-move", "authoritative", "tick", "reset", "set-world", "assert"]

var results: Array = []


class CaseResult extends RefCounted:
	var name: String = ""
	var tier: String = ""
	var status: int = CouchFixtureRunner.Status.PASSED
	var message: String = ""


## Loads every corpus file in `data_dir`, verifying it against `manifest.json` beside
## it when present. Returns {"cases": Array, "error": String}.
static func load_corpus(data_dir: String) -> Dictionary:
	var dir_path := data_dir.trim_suffix("/")
	var manifest_path := dir_path.get_base_dir().path_join("manifest.json")
	var expected: Dictionary = {}
	if FileAccess.file_exists(manifest_path):
		var manifest_text := FileAccess.get_file_as_string(manifest_path)
		var manifest: Variant = JSON.parse_string(manifest_text)
		if manifest is Dictionary:
			for entry in manifest.get("files", []):
				expected[entry["file"]] = entry

	var listing := DirAccess.get_files_at(dir_path)
	if listing.is_empty():
		return {"cases": [], "error": "no fixture files found at %s" % dir_path}

	var cases: Array = []
	var names: Array = []
	for file_name in listing:
		if not file_name.ends_with(".json"):
			continue
		var path := dir_path.path_join(file_name)
		var bytes := FileAccess.get_file_as_bytes(path)
		# Drift guard: prove we are running the corpus rather than a stale fork of it.
		if expected.has(file_name):
			var actual_sha := _sha256_hex(bytes)
			if actual_sha != expected[file_name]["sha256"]:
				return {
					"cases": [],
					"error":
					(
						"%s does not match manifest.json (sha256 %s, expected %s). "
						+ "The corpus has drifted -- resolve that before trusting any result."
					) % [file_name, actual_sha, expected[file_name]["sha256"]],
				}
		var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
		if not parsed is Dictionary:
			return {"cases": [], "error": "%s is not a JSON object" % file_name}
		if parsed.get("schema", "") != EXPECTED_SCHEMA:
			return {
				"cases": [],
				"error":
				"%s declares schema %s, expected %s" % [file_name, parsed.get("schema", ""), EXPECTED_SCHEMA],
			}
		for case_data in parsed.get("cases", []):
			var case_name: String = case_data.get("name", "")
			if case_name in names:
				return {"cases": [], "error": "duplicate case name %s" % case_name}
			names.append(case_name)
			cases.append(case_data)
	return {"cases": cases, "error": ""}


static func _sha256_hex(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()


func run_all(cases: Array) -> Array:
	results.clear()
	for case_data in cases:
		results.append(run_case(case_data))
	return results


func run_case(case_data: Dictionary) -> CaseResult:
	var result := CaseResult.new()
	result.name = case_data.get("name", "<unnamed>")
	result.tier = case_data.get("tier", "<untiered>")

	var world := _build_world(case_data.get("world", {}))
	var step_index := 0
	for step in case_data.get("steps", []):
		var action: String = step.get("action", "")
		if not ACTION_KEYS.has(action):
			result.status = Status.FAILED
			result.message = "step %d: unknown action %s" % [step_index, action]
			return result
		var unknown := _unknown_keys(step, action)
		if not unknown.is_empty():
			result.status = Status.FAILED
			result.message = (
				"step %d (%s): keys this runner does not read: %s -- the fixture asserts something untested"
				% [step_index, action, ", ".join(unknown)]
			)
			return result
		if not action in IMPLEMENTED_ACTIONS:
			result.status = Status.UNIMPLEMENTED
			result.message = "step %d: action %s is not ported yet" % [step_index, action]
			return result

		var failure := _drive(action, step, world)
		# A fixture contradicting itself outranks everything: it means the case cannot
		# be trusted either way, so report it before any pass/fail verdict.
		if not world.contract_violation.is_empty():
			result.status = Status.FAILED
			result.message = "step %d: fixture self-contradiction: %s" % [step_index, world.contract_violation]
			return result
		if failure == CORE_NOT_PORTED:
			result.status = Status.UNIMPLEMENTED
			result.message = "step %d (%s): needs the prediction core" % [step_index, action]
			return result
		if not failure.is_empty():
			result.status = Status.FAILED
			result.message = "step %d (%s): %s" % [step_index, action, failure]
			return result
		step_index += 1
	return result


func _unknown_keys(step: Dictionary, action: String) -> Array:
	var allowed: Array = COMMON_KEYS + ACTION_KEYS[action]
	var unknown: Array = []
	for key in step:
		if not key in allowed:
			unknown.append(str(key))
	return unknown


func _build_world(spec: Dictionary) -> CouchScriptedWorld:
	var world := CouchScriptedWorld.new()
	world.can_reconcile_value = spec.get("canReconcile", true)
	world.world_epoch_value = int(spec.get("epoch", 0))
	world.world_generation_value = int(spec.get("generation", 0))
	world.can_apply_remote_result = spec.get("canApplyRemote", true)
	world.apply_remote_result = spec.get("applyRemote", true)
	world.rewind_result = spec.get("rewind", true)
	for entry in spec.get("rewindResults", []):
		world.rewind_results.append(bool(entry))
	world.set_rewind_budget(int(spec.get("rewindBudget", 0)))
	return world


## Drives one step. Returns "" on success or a failure description.
##
## The prediction core is not ported yet, so the actions that need it report that
## plainly instead of pretending. `set-world` and `assert` already work against the
## world fake, which is what makes this harness verifiable before the core exists.
func _drive(action: String, step: Dictionary, world: CouchScriptedWorld) -> String:
	match action:
		"set-world":
			if step.has("epoch"):
				world.world_epoch_value = int(step["epoch"])
			if step.has("generation"):
				world.world_generation_value = int(step["generation"])
			if step.has("canReconcile"):
				world.can_reconcile_value = bool(step["canReconcile"])
			if step.has("canApplyRemote"):
				world.can_apply_remote_result = bool(step["canApplyRemote"])
			if step.has("applyRemote"):
				world.apply_remote_result = bool(step["applyRemote"])
			if step.has("rewindBudget"):
				world.set_rewind_budget(int(step["rewindBudget"]))
			return ""
		"assert":
			return _assert_world(step, world)
		_:
			return CORE_NOT_PORTED


## Only the world-facing assertions can be checked without the core. Anything else in
## an assert step is reported as core-dependent rather than silently passed.
func _assert_world(step: Dictionary, world: CouchScriptedWorld) -> String:
	if step.has("rewindCount") and world.rewind_count != int(step["rewindCount"]):
		return "rewindCount expected %d, got %d" % [int(step["rewindCount"]), world.rewind_count]
	if step.has("rewindBudget") and world.rewind_budget() != int(step["rewindBudget"]):
		return "rewindBudget expected %d, got %d" % [int(step["rewindBudget"]), world.rewind_budget()]
	if step.has("worldEpoch") and world.world_epoch_value != int(step["worldEpoch"]):
		return "worldEpoch expected %d, got %d" % [int(step["worldEpoch"]), world.world_epoch_value]
	if step.has("worldGeneration") and world.world_generation_value != int(step["worldGeneration"]):
		return (
			"worldGeneration expected %d, got %d"
			% [int(step["worldGeneration"]), world.world_generation_value]
		)
	if step.has("headToken") and world.top_token() != int(step["headToken"]):
		return "headToken expected %d, got %d" % [int(step["headToken"]), world.top_token()]
	for core_key in [
		"pendingCount",
		"isDiverged",
		"needsRebaseline",
		"isAwaitingRebaseline",
		"recoveryAttempts",
		"hasGivenUp",
		"rttMs",
		"sampleCount",
		"timeoutMs",
		"outstandingNonce",
		"suppressPrediction",
		"oldestPendingSequence",
	]:
		if step.has(core_key):
			return CORE_NOT_PORTED
	return ""


## Aggregate counts by tier and status, for the summary line.
static func summarize(case_results: Array) -> Dictionary:
	var summary := {}
	for result in case_results:
		if not summary.has(result.tier):
			summary[result.tier] = {"passed": 0, "failed": 0, "unimplemented": 0}
		match result.status:
			Status.PASSED:
				summary[result.tier]["passed"] += 1
			Status.FAILED:
				summary[result.tier]["failed"] += 1
			Status.UNIMPLEMENTED:
				summary[result.tier]["unimplemented"] += 1
	return summary
