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

## Sentinel returned by a driver that needs the session layer not ported yet.
## Distinct from a failure string so the two can never be conflated in reporting.
const SESSION_NOT_PORTED := "@session-not-ported"

## Keys every step may carry regardless of action.
const COMMON_KEYS := ["action", "at"]

const CASE_KEYS := ["name", "tier", "description", "policy", "session", "world", "steps"]
const POLICY_KEYS := [
	"defaultRttMs", "rttAlphaNumerator", "rttAlphaDenominator", "maxSampleMs",
	"timeoutRttMultiplier", "minTimeoutMs", "maxTimeoutMs", "maxPendingPredictions",
	"fixedTimeoutMs",
]
const SESSION_POLICY_KEYS := [
	"stuckHeadMs", "baseBackoffMs", "maxBackoffMs", "backoffShiftCap", "maxAttempts",
	"noBaselineMs",
]
const WORLD_KEYS := [
	"canReconcile", "rewindBudget", "epoch", "generation", "canApplyRemote", "applyRemote",
	"rewind", "rewindResults",
]
const EXPECTED_STEP_KEYS := ["kind", "playerSlot", "requestSequence", "dx", "dy"]
const AUTHORITATIVE_OP_KEYS := ["kind", "playerSlot", "requestSequence", "dx", "dy"]
const STACK_OP_KEYS := ["pop", "push"]
const HEAD_KEYS := ["token", "kind", "level", "playerSlot", "requestSequence", "dx", "dy"]
const EXPECTED_ACTION_KEYS := [
	"kind", "trigger", "nonce", "attempt", "maxAttempts", "active", "elapsedMs", "headLevel",
]
const TIER_LABELS := ["core-invariant", "seed-1-policy"]
const TIMED_ACTIONS := [
	"local-move", "authoritative", "tick", "frame", "recovery", "arrival", "transport-gap",
]
const OP_KIND_LABELS := ["move", "undo", "restart", "load-level", "pause", "accept", "skip"]
const RECOVERY_TRIGGER_LABELS := [
	"sequence-gap", "unapplicable-head", "stuck-head", "voided-latch", "no-baseline",
	"transport-gap",
]
const SESSION_ACTION_KIND_LABELS := [
	"send-rebaseline-request", "announce-recovery-state", "warn-stuck-head", "announce-gave-up",
]
const SKIP_REASON_LABELS := [
	"not-unit-input", "pending-limit", "rewind-budget", "world-busy", "epoch-changed", "diverged",
]

## Per-action key allowlist. A step carrying anything not listed for its action is a
## failure: it means the fixture is asserting something this runner does not read.
const ACTION_KEYS := {
	"local-move":
	[
		"playerSlot", "dx", "dy", "requestSequence", "moveOutcomes", "expectPredicted",
		"expectSteps", "expectSkipReason", "epochAfterMove", "generationAfterMove", "stackOps",
		"expectCalls",
	],
	"authoritative":
	["op", "expectConsumed", "expectSteps", "moveOutcomes", "epochAfterMove", "expectCalls"],
	"tick": ["expectSteps", "moveOutcomes", "epochAfterMove", "expectCalls"],
	"reset": ["expectSteps", "expectCalls"],
	"set-world":
	["epoch", "generation", "canReconcile", "canApplyRemote", "applyRemote", "rewindBudget"],
	"assert":
	[
		"pendingCount", "isDiverged", "needsRebaseline", "isAwaitingRebaseline",
		"recoveryAttempts", "hasGivenUp", "rewindCount", "rewindBudget", "worldEpoch",
		"worldGeneration", "rttMs", "sampleCount", "timeoutMs", "outstandingNonce",
		"suppressPrediction", "topToken", "headToken", "oldestPendingSequence",
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
		var root_unknown := _unknown_keys_for(parsed, ["schema", "cases"])
		if not root_unknown.is_empty():
			return {
				"cases": [],
				"error": "%s has unknown root key(s): %s" % [file_name, ", ".join(root_unknown)],
			}
		if not parsed.has("schema") or not parsed["schema"] is String:
			return {"cases": [], "error": "%s has missing or non-string field 'schema'" % file_name}
		if parsed["schema"] != EXPECTED_SCHEMA:
			return {
				"cases": [],
				"error":
				"%s declares schema %s, expected %s" % [file_name, parsed["schema"], EXPECTED_SCHEMA],
			}
		if not parsed.has("cases") or not parsed["cases"] is Array:
			return {"cases": [], "error": "%s has missing or non-array field 'cases'" % file_name}
		for case_index in range(parsed["cases"].size()):
			var case_data: Variant = parsed["cases"][case_index]
			if not case_data is Dictionary:
				return {
					"cases": [],
					"error": "%s: cases[%d] is not a JSON object" % [file_name, case_index],
				}
			var case_name: Variant = case_data.get("name", "")
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
	var schema_failure := _validate_case_schema(case_data)
	if not schema_failure.is_empty():
		result.status = Status.FAILED
		result.message = schema_failure
		return result

	var shared_log: Array = []
	var world := _build_world(case_data.get("world", {}), shared_log)
	var core := CouchPredictionCore.new(_build_policy(case_data.get("policy", {})))
	var step_index := 0
	for step in case_data.get("steps", []):
		shared_log.clear()
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

		var failure := _drive(action, step, world, core)
		# A fixture contradicting itself outranks everything: it means the case cannot
		# be trusted either way, so report it before any pass/fail verdict.
		if not world.contract_violation.is_empty():
			result.status = Status.FAILED
			result.message = "step %d: fixture self-contradiction: %s" % [step_index, world.contract_violation]
			return result
		if failure == SESSION_NOT_PORTED:
			result.status = Status.UNIMPLEMENTED
			result.message = "step %d (%s): needs the session layer" % [step_index, action]
			return result
		if not failure.is_empty():
			result.status = Status.FAILED
			result.message = "step %d (%s): %s" % [step_index, action, failure]
			return result
		failure = _compare_calls(step, shared_log)
		if not failure.is_empty():
			result.status = Status.FAILED
			result.message = "step %d (%s): %s" % [step_index, action, failure]
			return result
		step_index += 1
	return result


func _unknown_keys(step: Dictionary, action: String) -> Array:
	var allowed: Array = COMMON_KEYS + ACTION_KEYS[action]
	return _unknown_keys_for(step, allowed)


static func _unknown_keys_for(data: Dictionary, allowed: Array) -> Array:
	var unknown: Array = []
	for key in data:
		if not key in allowed:
			unknown.append(str(key))
	return unknown


## Validates the complete case before executing its first step. This ensures a
## known-but-unported session action cannot mask a typo in a later declaration.
func _validate_case_schema(case_data: Dictionary) -> String:
	var unknown := _unknown_keys_for(case_data, CASE_KEYS)
	if not unknown.is_empty():
		return "case keys this runner does not read: %s" % ", ".join(unknown)
	if not case_data.has("name") or not case_data["name"] is String:
		return "case has missing or non-string field 'name'"
	if not case_data.has("tier") or not case_data["tier"] is String:
		return "case has missing or non-string field 'tier'"
	if not case_data["tier"] in TIER_LABELS:
		return "case has unknown tier '%s'" % case_data["tier"]
	if case_data.has("description") and not case_data["description"] is String:
		return "description must be a string"

	for object_spec in [
		["policy", POLICY_KEYS], ["session", SESSION_POLICY_KEYS], ["world", WORLD_KEYS]
	]:
		var field: String = object_spec[0]
		if field == "world" and not case_data.has(field):
			return "case has missing field 'world'"
		if not case_data.has(field):
			continue
		if not case_data[field] is Dictionary:
			return "%s must be an object" % field
		unknown = _unknown_keys_for(case_data[field], object_spec[1])
		if not unknown.is_empty():
			return "%s has unknown key(s): %s" % [field, ", ".join(unknown)]

	if case_data.has("policy"):
		var failure := _validate_number_fields(case_data["policy"], POLICY_KEYS, "policy")
		if not failure.is_empty():
			return failure
	if case_data.has("session"):
		var failure := _validate_number_fields(
			case_data["session"], SESSION_POLICY_KEYS, "session"
		)
		if not failure.is_empty():
			return failure
	var world_failure := _validate_world_schema(case_data["world"])
	if not world_failure.is_empty():
		return world_failure

	if not case_data.has("steps"):
		return "case has missing field 'steps'"
	var steps: Variant = case_data["steps"]
	if not steps is Array:
		return "steps must be an array"
	for step_index in range(steps.size()):
		if not steps[step_index] is Dictionary:
			return "step %d must be an object" % step_index
		var step: Dictionary = steps[step_index]
		if not step.has("action") or not step["action"] is String:
			return "step %d: missing or non-string field 'action'" % step_index
		var action: String = step["action"]
		if not ACTION_KEYS.has(action):
			return "step %d: unknown action %s" % [step_index, action]
		unknown = _unknown_keys(step, action)
		if not unknown.is_empty():
			return (
				"step %d (%s): keys this runner does not read: %s -- the fixture asserts something untested"
				% [step_index, action, ", ".join(unknown)]
			)
		var nested_failure := _validate_step_schema(step, step_index, action)
		if not nested_failure.is_empty():
			return nested_failure
	return ""


func _validate_world_schema(world: Dictionary) -> String:
	for field in ["canReconcile", "canApplyRemote", "applyRemote", "rewind"]:
		if not world.has(field) or not world[field] is bool:
			return "world has missing or non-bool field '%s'" % field
	for field in ["rewindBudget", "epoch"]:
		if not world.has(field) or not _is_number(world[field]):
			return "world has missing or non-numeric field '%s'" % field
	if world.has("generation") and not _is_number(world["generation"]):
		return "world.generation must be numeric"
	if world.has("rewindResults"):
		return _validate_array_members(world["rewindResults"], TYPE_BOOL, "world.rewindResults")
	return ""


func _validate_step_schema(step: Dictionary, step_index: int, action: String) -> String:
	var context := "step %d (%s)" % [step_index, action]
	if action in TIMED_ACTIONS and not step.has("at"):
		return "%s: action requires 'at'" % context
	if step.has("at") and not _is_number(step["at"]):
		return "%s: at must be numeric" % context

	var failure := _validate_number_fields(
		step,
		[
			"playerSlot", "dx", "dy", "requestSequence", "epoch", "generation", "rewindBudget",
			"pendingCount", "recoveryAttempts", "rewindCount", "worldEpoch", "worldGeneration",
			"rttMs", "sampleCount", "timeoutMs", "outstandingNonce", "topToken", "headToken",
			"oldestPendingSequence", "currentLevel", "expectAuthorityProbeCount", "authoritySequence",
			"level", "operationCount",
		],
		context
	)
	if not failure.is_empty():
		return failure
	failure = _validate_bool_fields(
		step,
		[
			"expectPredicted", "expectConsumed", "canReconcile", "canApplyRemote", "applyRemote",
			"isDiverged", "needsRebaseline", "isAwaitingRebaseline", "hasGivenUp",
			"suppressPrediction", "isPredicting", "expectHeadConsumed", "isLoadLevel",
			"expectEnqueued", "paused", "canReachAuthority", "isGuest",
		],
		context
	)
	if not failure.is_empty():
		return failure

	if step.has("expectSkipReason"):
		failure = _validate_known_label(
			step["expectSkipReason"], SKIP_REASON_LABELS, "%s.expectSkipReason" % context
		)
		if not failure.is_empty():
			return failure
	if action == "recovery" and not step.has("trigger"):
		return "%s: action requires 'trigger'" % context
	if step.has("trigger"):
		failure = _validate_known_label(
			step["trigger"], RECOVERY_TRIGGER_LABELS, "%s.trigger" % context
		)
		if not failure.is_empty():
			return failure

	if action == "authoritative" and not step.has("op"):
		return "%s: action requires 'op'" % context
	if step.has("op"):
		failure = _validate_nested_object(
			step["op"], AUTHORITATIVE_OP_KEYS, step_index, action, "op"
		)
		if not failure.is_empty():
			return failure
		failure = _validate_required_known_kind(
			step["op"], OP_KIND_LABELS, "%s.op" % context
		)
		if not failure.is_empty():
			return failure
		failure = _validate_number_fields(
			step["op"], ["playerSlot", "requestSequence", "dx", "dy"], "%s.op" % context
		)
		if not failure.is_empty():
			return failure
	if step.has("head"):
		failure = _validate_nested_object(step["head"], HEAD_KEYS, step_index, action, "head")
		if not failure.is_empty():
			return failure
		if not step["head"].has("token") or not _is_number(step["head"]["token"]):
			return "%s.head has missing or non-numeric field 'token'" % context
		failure = _validate_required_known_kind(
			step["head"], OP_KIND_LABELS, "%s.head" % context
		)
		if not failure.is_empty():
			return failure
		failure = _validate_number_fields(
			step["head"], ["level", "playerSlot", "requestSequence", "dx", "dy"], "%s.head" % context
		)
		if not failure.is_empty():
			return failure
	for array_spec in [
		["expectSteps", EXPECTED_STEP_KEYS],
		["stackOps", STACK_OP_KEYS],
		["expectActions", EXPECTED_ACTION_KEYS],
	]:
		var field: String = array_spec[0]
		if not step.has(field):
			continue
		if not step[field] is Array:
			return "step %d (%s): %s must be an array" % [step_index, action, field]
		for nested_index in range(step[field].size()):
			failure = _validate_nested_object(
				step[field][nested_index],
				array_spec[1],
				step_index,
				action,
				"%s[%d]" % [field, nested_index]
			)
			if not failure.is_empty():
				return failure
			var nested: Dictionary = step[field][nested_index]
			var nested_context := "%s.%s[%d]" % [context, field, nested_index]
			match field:
				"expectSteps":
					failure = _validate_required_known_kind(
						nested, CouchPredictionTypes.STEP_KIND_LABELS.values(), nested_context
					)
					if failure.is_empty():
						failure = _validate_number_fields(
							nested, ["playerSlot", "requestSequence", "dx", "dy"], nested_context
						)
				"stackOps":
					failure = _validate_number_fields(nested, STACK_OP_KEYS, nested_context)
				"expectActions":
					failure = _validate_required_known_kind(
						nested, SESSION_ACTION_KIND_LABELS, nested_context
					)
					if failure.is_empty() and nested.has("trigger"):
						failure = _validate_known_label(
							nested["trigger"], RECOVERY_TRIGGER_LABELS, "%s.trigger" % nested_context
						)
					if failure.is_empty():
						failure = _validate_number_fields(
							nested,
							["nonce", "attempt", "maxAttempts", "elapsedMs", "headLevel"],
							nested_context
						)
					if failure.is_empty():
						failure = _validate_bool_fields(nested, ["active"], nested_context)
			if not failure.is_empty():
				return failure

	if step.has("moveOutcomes"):
		failure = _validate_label_array(
			step["moveOutcomes"], CouchPredictionTypes.MOVE_OUTCOME_LABELS.values(), "%s.moveOutcomes" % context
		)
		if not failure.is_empty():
			return failure
	for field in ["epochAfterMove", "generationAfterMove"]:
		if step.has(field):
			failure = _validate_array_members(step[field], TYPE_FLOAT, "%s.%s" % [context, field], true)
			if not failure.is_empty():
				return failure
	if step.has("applyHeadUnpredicted"):
		failure = _validate_array_members(
			step["applyHeadUnpredicted"], TYPE_BOOL, "%s.applyHeadUnpredicted" % context
		)
		if not failure.is_empty():
			return failure
	if step.has("expectCalls"):
		failure = _validate_array_members(
			step["expectCalls"], TYPE_STRING, "%s.expectCalls" % context
		)
		if not failure.is_empty():
			return failure
	return ""


func _validate_nested_object(
	value: Variant,
	allowed: Array,
	step_index: int,
	action: String,
	context: String
) -> String:
	if not value is Dictionary:
		return "step %d (%s): %s must be an object" % [step_index, action, context]
	var unknown := _unknown_keys_for(value, allowed)
	if unknown.is_empty():
		return ""
	return (
		"step %d (%s): %s has unknown key(s): %s"
		% [step_index, action, context, ", ".join(unknown)]
	)


func _validate_required_known_kind(data: Dictionary, labels: Array, context: String) -> String:
	if not data.has("kind") or not data["kind"] is String:
		return "%s has missing or non-string field 'kind'" % context
	if not data["kind"] in labels:
		return "%s has unknown kind '%s'" % [context, data["kind"]]
	return ""


func _validate_known_label(value: Variant, labels: Array, context: String) -> String:
	if not value is String:
		return "%s must be a string" % context
	if not value in labels:
		return "%s has unknown label '%s'" % [context, value]
	return ""


func _validate_label_array(value: Variant, labels: Array, context: String) -> String:
	if not value is Array:
		return "%s must be an array" % context
	for i in range(value.size()):
		var failure := _validate_known_label(value[i], labels, "%s[%d]" % [context, i])
		if not failure.is_empty():
			return failure
	return ""


func _validate_array_members(
	value: Variant, expected_type: int, context: String, numeric: bool = false
) -> String:
	if not value is Array:
		return "%s must be an array" % context
	for i in range(value.size()):
		if numeric:
			if not _is_number(value[i]):
				return "%s[%d] must be numeric" % [context, i]
		elif typeof(value[i]) != expected_type:
			return "%s[%d] has the wrong primitive type" % [context, i]
	return ""


func _validate_number_fields(data: Dictionary, fields: Array, context: String) -> String:
	for field in fields:
		if data.has(field) and not _is_number(data[field]):
			return "%s.%s must be numeric" % [context, field]
	return ""


func _validate_bool_fields(data: Dictionary, fields: Array, context: String) -> String:
	for field in fields:
		if data.has(field) and not data[field] is bool:
			return "%s.%s must be a bool" % [context, field]
	return ""


func _is_number(value: Variant) -> bool:
	return value is int or value is float


func _build_world(spec: Dictionary, shared_log: Array) -> CouchScriptedWorld:
	var world := CouchScriptedWorld.new(shared_log)
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


func _build_policy(spec: Dictionary) -> CouchPredictionPolicy:
	var policy := CouchPredictionPolicy.default_policy()
	if spec.has("defaultRttMs"):
		policy.default_rtt_ms = int(spec["defaultRttMs"])
	if spec.has("rttAlphaNumerator"):
		policy.rtt_alpha_numerator = int(spec["rttAlphaNumerator"])
	if spec.has("rttAlphaDenominator"):
		policy.rtt_alpha_denominator = int(spec["rttAlphaDenominator"])
	if spec.has("maxSampleMs"):
		policy.max_sample_ms = int(spec["maxSampleMs"])
	if spec.has("timeoutRttMultiplier"):
		policy.timeout_rtt_multiplier = int(spec["timeoutRttMultiplier"])
	if spec.has("minTimeoutMs"):
		policy.min_timeout_ms = int(spec["minTimeoutMs"])
	if spec.has("maxTimeoutMs"):
		policy.max_timeout_ms = int(spec["maxTimeoutMs"])
	if spec.has("maxPendingPredictions"):
		policy.max_pending_predictions = int(spec["maxPendingPredictions"])
	if spec.has("fixedTimeoutMs"):
		policy.fixed_timeout_ms = int(spec["fixedTimeoutMs"])
	return policy


## Drives one step. Returns "" on success or a failure description.
##
func _drive(
	action: String, step: Dictionary, world: CouchScriptedWorld, core: CouchPredictionCore
) -> String:
	match action:
		"local-move":
			var queue_failure := _queue_world_effects(step, world)
			if not queue_failure.is_empty():
				return queue_failure
			var predict_result := core.predict_local_move(
				int(step.get("playerSlot", 0)),
				int(step.get("dx", 0)),
				int(step.get("dy", 0)),
				int(step.get("requestSequence", 0)),
				int(step.get("at", 0)),
				world
			)
			if (
				step.has("expectPredicted")
				and predict_result.predicted != bool(step["expectPredicted"])
			):
				return (
					"expectPredicted expected %s, got %s"
					% [bool(step["expectPredicted"]), predict_result.predicted]
				)
			if step.has("expectSkipReason"):
				var expected_reason := CouchPredictionTypes.value_for_label(
					CouchPredictionTypes.SKIP_REASON_LABELS, str(step["expectSkipReason"])
				)
				if expected_reason < 0:
					return "unknown expectSkipReason %s" % step["expectSkipReason"]
				if predict_result.reason != expected_reason:
					return (
						"expectSkipReason expected %s, got %s"
						% [
							step["expectSkipReason"],
							CouchPredictionTypes.label_for_value(
								CouchPredictionTypes.SKIP_REASON_LABELS, predict_result.reason
							),
						]
					)
			return _compare_steps(step, predict_result.steps)
		"authoritative":
			var queue_failure := _queue_world_effects(step, world)
			if not queue_failure.is_empty():
				return queue_failure
			var parsed_op := _parse_authoritative_op(step.get("op", {}))
			if not parsed_op["error"].is_empty():
				return parsed_op["error"]
			var reconcile_result := core.on_authoritative_operation(
				parsed_op["op"], int(step.get("at", 0)), world
			)
			if (
				step.has("expectConsumed")
				and reconcile_result.consumed != bool(step["expectConsumed"])
			):
				return (
					"expectConsumed expected %s, got %s"
					% [bool(step["expectConsumed"]), reconcile_result.consumed]
				)
			return _compare_steps(step, reconcile_result.steps)
		"tick":
			var queue_failure := _queue_world_effects(step, world)
			if not queue_failure.is_empty():
				return queue_failure
			return _compare_steps(step, core.tick(int(step.get("at", 0)), world).steps)
		"reset":
			return _compare_steps(step, core.reset())
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
			return _assert_state(step, world, core)
		_:
			return SESSION_NOT_PORTED


func _assert_state(
	step: Dictionary, world: CouchScriptedWorld, core: CouchPredictionCore
) -> String:
	if step.has("pendingCount") and core.pending_count != int(step["pendingCount"]):
		return "pendingCount expected %d, got %d" % [int(step["pendingCount"]), core.pending_count]
	if (
		step.has("oldestPendingSequence")
		and core.oldest_pending_sequence != int(step["oldestPendingSequence"])
	):
		return (
			"oldestPendingSequence expected %d, got %d"
			% [int(step["oldestPendingSequence"]), core.oldest_pending_sequence]
		)
	if step.has("isDiverged") and core.is_diverged != bool(step["isDiverged"]):
		return "isDiverged expected %s, got %s" % [bool(step["isDiverged"]), core.is_diverged]
	if step.has("needsRebaseline") and core.needs_rebaseline != bool(step["needsRebaseline"]):
		return (
			"needsRebaseline expected %s, got %s"
			% [bool(step["needsRebaseline"]), core.needs_rebaseline]
		)
	if step.has("rttMs") and core.rtt_ms != int(step["rttMs"]):
		return "rttMs expected %d, got %d" % [int(step["rttMs"]), core.rtt_ms]
	if step.has("sampleCount") and core.sample_count != int(step["sampleCount"]):
		return "sampleCount expected %d, got %d" % [int(step["sampleCount"]), core.sample_count]
	if step.has("timeoutMs") and core.timeout_ms != int(step["timeoutMs"]):
		return "timeoutMs expected %d, got %d" % [int(step["timeoutMs"]), core.timeout_ms]
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
	if step.has("topToken") and world.top_token() != int(step["topToken"]):
		return "topToken expected %d, got %d" % [int(step["topToken"]), world.top_token()]
	for session_key in [
		"isAwaitingRebaseline",
		"recoveryAttempts",
		"hasGivenUp",
		"outstandingNonce",
		"suppressPrediction",
		"headToken",
	]:
		if step.has(session_key):
			return SESSION_NOT_PORTED
	return ""


func _queue_world_effects(step: Dictionary, world: CouchScriptedWorld) -> String:
	for label in step.get("moveOutcomes", []):
		var outcome := CouchPredictionTypes.value_for_label(
			CouchPredictionTypes.MOVE_OUTCOME_LABELS, str(label)
		)
		if outcome < 0:
			return "unknown moveOutcome %s" % label
		world.move_outcomes.append(outcome)
	for epoch in step.get("epochAfterMove", []):
		world.epoch_after_move.append(int(epoch))
	for generation in step.get("generationAfterMove", []):
		world.generation_after_move.append(int(generation))
	for stack_op in step.get("stackOps", []):
		world.stack_ops.append(stack_op)
	return ""


func _parse_authoritative_op(spec: Dictionary) -> Dictionary:
	var kind_label := str(spec.get("kind", ""))
	match kind_label:
		"move":
			return {
				"op":
				CouchPredictionTypes.AuthoritativeOp.move(
					int(spec.get("playerSlot", -1)),
					int(spec.get("requestSequence", 0)),
					int(spec.get("dx", 0)),
					int(spec.get("dy", 0))
				),
				"error": "",
			}
		"undo":
			return {
				"op": CouchPredictionTypes.AuthoritativeOp.simple(CouchPredictionTypes.OpKind.UNDO),
				"error": "",
			}
		"restart", "load-level":
			return {
				"op":
				CouchPredictionTypes.AuthoritativeOp.simple(CouchPredictionTypes.OpKind.WORLD_RESET),
				"error": "",
			}
		"pause", "accept", "skip":
			return {
				"op": CouchPredictionTypes.AuthoritativeOp.simple(CouchPredictionTypes.OpKind.NEUTRAL),
				"error": "",
			}
		_:
			return {"op": null, "error": "unknown authoritative op kind %s" % kind_label}


func _compare_steps(step: Dictionary, actual: Array) -> String:
	if not step.has("expectSteps"):
		return ""
	var expected: Array = step["expectSteps"]
	if expected.size() != actual.size():
		return (
			"expected %d step(s) %s, got %d %s"
			% [expected.size(), _describe_expected_steps(expected), actual.size(), _describe_steps(actual)]
		)
	for i in range(expected.size()):
		var expected_step: Dictionary = expected[i]
		var actual_step: CouchPredictionTypes.ReconcileStep = actual[i]
		var expected_kind := CouchPredictionTypes.value_for_label(
			CouchPredictionTypes.STEP_KIND_LABELS, str(expected_step.get("kind", ""))
		)
		if expected_kind < 0:
			return "unknown expected step kind %s at index %d" % [expected_step.get("kind", ""), i]
		if actual_step.kind != expected_kind:
			return (
				"expected %s, got %s (kind mismatch at index %d)"
				% [_describe_expected_steps(expected), _describe_steps(actual), i]
			)
		for field in ["playerSlot", "requestSequence", "dx", "dy"]:
			if not expected_step.has(field):
				continue
			var actual_value: int
			match field:
				"playerSlot":
					actual_value = actual_step.player_slot
				"requestSequence":
					actual_value = actual_step.request_sequence
				"dx":
					actual_value = actual_step.dx
				_:
					actual_value = actual_step.dy
			if actual_value != int(expected_step[field]):
				return (
					"expected %s, got %s (%s mismatch at index %d: expected %d, got %d)"
					% [
						_describe_expected_steps(expected),
						_describe_steps(actual),
						field,
						i,
						int(expected_step[field]),
						actual_value,
					]
				)
	return ""


func _compare_calls(step: Dictionary, actual: Array) -> String:
	if not step.has("expectCalls"):
		return ""
	var expected: Array = step["expectCalls"]
	if expected.size() != actual.size():
		return "expected calls %s, got %s" % [expected, actual]
	for i in range(expected.size()):
		if str(expected[i]) != str(actual[i]):
			return (
				"expected calls %s, got %s (mismatch at index %d: expected '%s', got '%s')"
				% [expected, actual, i, expected[i], actual[i]]
			)
	return ""


func _describe_steps(steps: Array) -> String:
	var labels: Array[String] = []
	for step in steps:
		labels.append(str(step))
	return "[%s]" % ", ".join(labels)


func _describe_expected_steps(steps: Array) -> String:
	var labels: Array[String] = []
	for expected in steps:
		var kind := str(expected.get("kind", ""))
		if not expected.has("playerSlot"):
			labels.append(kind)
		else:
			labels.append(
				"%s(slot=%d,seq=%d,d=%d,%d)"
				% [
					kind,
					int(expected.get("playerSlot", -1)),
					int(expected.get("requestSequence", 0)),
					int(expected.get("dx", 0)),
					int(expected.get("dy", 0)),
				]
			)
	return "[%s]" % ", ".join(labels)


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
