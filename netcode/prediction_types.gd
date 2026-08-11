## Core-invariant value vocabulary for host-authoritative prediction.
##
## Transcribed from the C# reference implementation in
## handshakes-couch-games/Assets/Scripts/Netcode/PredictionTypes.cs, which is the
## spec (see couch-netcode-fixtures/README.md). Enum ORDINALS and kebab-case
## LABELS are both part of the contract: the labels are what the shared fixture
## corpus uses on the wire, so renaming one silently breaks conformance.
##
## Nothing here references a game. `dx`/`dy` are the seed-1 instantiation of an
## opaque operation payload -- the core carries them for identity, comparison and
## replay and never interprets them, with exactly one documented exception
## (the unit-axis predicate, which is policy a port may re-decide).
class_name CouchPredictionTypes
extends RefCounted


## How an authoritative operation affects the prediction pipeline. A binding maps
## its own wire vocabulary onto these four buckets; that mapping is game-specific,
## the buckets are not.
enum OpKind {
	## Does not touch the predicted world (pause, accept, skip). Never rolls back.
	NEUTRAL = 0,
	## A move on the shared, non-commutative world.
	MOVE = 1,
	## An undo -- world-mutating, reconciled the same as a foreign move.
	UNDO = 2,
	## A non-linear mutation (restart, level load). Always flushes without rewinding.
	WORLD_RESET = 3,
}

## Tri-state result of attempting one move. Collapsing this to a bool loses the
## "ran but bounced" case, which costs no rollback budget and must not be rolled back.
enum MoveOutcome {
	## The world refused to attempt it (controls disabled). No snapshot taken.
	BLOCKED = 0,
	## Ran, world unchanged (bumped a wall). Consumes a sequence, no snapshot.
	NO_CHANGE = 1,
	## Ran and changed the world. Exactly one rewindable snapshot was taken.
	MOVED = 2,
}

## The observable output of every core entry point: the ordered record of what the
## core did to the world, in the order it did it.
enum StepKind {
	PREDICT = 0,
	ROLLBACK = 1,
	APPLY_REMOTE = 2,
	REPLAY = 3,
	DROP_CONFIRMED = 4,
	DROP_SUPERSEDED = 5,
	DROP_MISPREDICTED = 6,
	DROP_TIMED_OUT = 7,
	FLUSH_PREDICTIONS = 8,
	ABORT = 9,
	APPLY_REMOTE_FAILED = 10,
	DIVERGED = 11,
	DROP_ORPHANED_ECHO = 12,
	REBASELINE_REQUIRED = 13,
}

## Why a local move was not predicted. The thresholds behind PENDING_LIMIT and
## REWIND_BUDGET are seed-1 policy; the categories are not.
enum SkipReason {
	NONE = 0,
	NOT_UNIT_INPUT = 1,
	PENDING_LIMIT = 2,
	REWIND_BUDGET = 3,
	WORLD_BUSY = 4,
	EPOCH_CHANGED = 5,
	DIVERGED = 6,
}

const OP_KIND_LABELS := {
	OpKind.NEUTRAL: "neutral",
	OpKind.MOVE: "move",
	OpKind.UNDO: "undo",
	OpKind.WORLD_RESET: "world-reset",
}

const MOVE_OUTCOME_LABELS := {
	MoveOutcome.BLOCKED: "blocked",
	MoveOutcome.NO_CHANGE: "no-change",
	MoveOutcome.MOVED: "moved",
}

const STEP_KIND_LABELS := {
	StepKind.PREDICT: "predict",
	StepKind.ROLLBACK: "rollback",
	StepKind.APPLY_REMOTE: "apply-remote",
	StepKind.REPLAY: "replay",
	StepKind.DROP_CONFIRMED: "drop-confirmed",
	StepKind.DROP_SUPERSEDED: "drop-superseded",
	StepKind.DROP_MISPREDICTED: "drop-mispredicted",
	StepKind.DROP_TIMED_OUT: "drop-timed-out",
	StepKind.FLUSH_PREDICTIONS: "flush-predictions",
	StepKind.ABORT: "abort",
	StepKind.APPLY_REMOTE_FAILED: "apply-remote-failed",
	StepKind.DIVERGED: "diverged",
	StepKind.DROP_ORPHANED_ECHO: "drop-orphaned-echo",
	StepKind.REBASELINE_REQUIRED: "rebaseline-required",
}

const SKIP_REASON_LABELS := {
	SkipReason.NONE: "none",
	SkipReason.NOT_UNIT_INPUT: "not-unit-input",
	SkipReason.PENDING_LIMIT: "pending-limit",
	SkipReason.REWIND_BUDGET: "rewind-budget",
	SkipReason.WORLD_BUSY: "world-busy",
	SkipReason.EPOCH_CHANGED: "epoch-changed",
	SkipReason.DIVERGED: "diverged",
}


## Reverse-lookup a label to its enum value. Returns -1 when unknown, and callers
## MUST treat that as an error rather than a default: a fixture naming a step kind
## this build does not have is a conformance failure, not something to skip.
static func value_for_label(labels: Dictionary, label: String) -> int:
	for key in labels:
		if labels[key] == label:
			return key
	return -1


static func label_for_value(labels: Dictionary, value: int) -> String:
	return labels.get(value, "unknown(%d)" % value)


## One authoritative operation as the core sees it. Pure data.
class AuthoritativeOp extends RefCounted:
	var kind: int = CouchPredictionTypes.OpKind.NEUTRAL
	## -1 when not applicable to this op's kind.
	var player_slot: int = -1
	## 0 when not applicable to this op's kind.
	var request_sequence: int = 0
	var dx: int = 0
	var dy: int = 0

	static func move(slot: int, sequence: int, x: int, y: int) -> AuthoritativeOp:
		var op := AuthoritativeOp.new()
		op.kind = CouchPredictionTypes.OpKind.MOVE
		op.player_slot = slot
		op.request_sequence = sequence
		op.dx = x
		op.dy = y
		return op

	static func simple(op_kind: int) -> AuthoritativeOp:
		var op := AuthoritativeOp.new()
		op.kind = op_kind
		return op


## One thing the core did to the world. This is what fixtures assert against, in order.
class ReconcileStep extends RefCounted:
	var kind: int = CouchPredictionTypes.StepKind.PREDICT
	var player_slot: int = -1
	var request_sequence: int = 0
	var dx: int = 0
	var dy: int = 0

	static func create(step_kind: int, slot: int, sequence: int, x: int, y: int) -> ReconcileStep:
		var step := ReconcileStep.new()
		step.kind = step_kind
		step.player_slot = slot
		step.request_sequence = sequence
		step.dx = x
		step.dy = y
		return step

	## A step with no associated slot/sequence/direction (apply-remote, abort, ...).
	static func simple(step_kind: int) -> ReconcileStep:
		return create(step_kind, -1, 0, 0, 0)

	## Matches the C# ReconcileStep.ToString() format exactly -- fixture failure
	## messages are compared against the reference implementation's output by
	## humans reading two logs side by side, so keep this stable.
	func _to_string() -> String:
		var label: String = CouchPredictionTypes.label_for_value(
			CouchPredictionTypes.STEP_KIND_LABELS, kind
		)
		if player_slot < 0:
			return label
		return "%s(slot=%d,seq=%d,d=%d,%d)" % [label, player_slot, request_sequence, dx, dy]


## Result of OnAuthoritativeOperation. `consumed == false` means the binding must
## leave the operation at the queue head -- it was not applied.
class ReconcileResult extends RefCounted:
	var consumed: bool = false
	var steps: Array = []

	static func create(was_consumed: bool, step_list: Array) -> ReconcileResult:
		var result := ReconcileResult.new()
		result.consumed = was_consumed
		result.steps = step_list
		return result

	static func deferred() -> ReconcileResult:
		return create(false, [])


## Result of PredictLocalMove.
class PredictResult extends RefCounted:
	var predicted: bool = false
	var reason: int = CouchPredictionTypes.SkipReason.NONE
	## BLOCKED whenever `predicted` is false.
	var outcome: int = CouchPredictionTypes.MoveOutcome.BLOCKED
	var steps: Array = []

	static func create(
		was_predicted: bool, skip_reason: int, move_outcome: int, step_list: Array
	) -> PredictResult:
		var result := PredictResult.new()
		result.predicted = was_predicted
		result.reason = skip_reason
		result.outcome = move_outcome
		result.steps = step_list
		return result
