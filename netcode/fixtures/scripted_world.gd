## A scripted fake of the CouchPredictionWorld contract, driven entirely by fixture
## JSON. Transcribed from ScriptedWorld.cs in the reference implementation.
##
## Deliberately strict: a fixture that under-declares its queued move outcomes or
## pops an empty stack fails LOUDLY rather than silently permitting behaviour the
## fixture never specified. Strictness is the point -- a lenient fake reports green
## while testing nothing.
##
## The rewind budget is backed by a stack of opaque SNAPSHOT IDENTITY TOKENS rather
## than a bare counter, mirroring the real snapshot list. That is what lets a case
## assert WHAT a rewind restored, not merely that one happened -- the distinction
## that makes the synchronous-arm-cut case expressible at all, where one rewind is
## a visual no-op because the number is right and the identity underneath is not.
class_name CouchScriptedWorld
extends RefCounted

## Two tokens are the "level start" floor a rewind can never cross.
const STACK_FLOOR := 2

var can_reconcile_value: bool = true
var world_epoch_value: int = 0
var world_generation_value: int = 0
var can_apply_remote_result: bool = true
var apply_remote_result: bool = true
var rewind_result: bool = true

## Whether apply_move enforces that a call's NET effect on the snapshot stack matches
## its outcome: MOVED must be exactly +1, anything else exactly 0.
##
## WHAT THIS DOES: catches a fixture that declares "moved" but scripts a stack shape
## whose net effect disagrees -- a corpus self-consistency guard.
##
## WHAT THIS DOES NOT DO: verify that any real engine behaves this way. It only checks
## numbers a fixture author typed against each other.
##
## Default on. Disabling it is for a mutation gate only, to prove the corpus needs it
## off nowhere.
var contract_assertions_enabled: bool = true

## Outcomes consumed in call order by apply_move.
var move_outcomes: Array = []
## Per-call override of the snapshot-stack effect, as {"pop": int, "push": int},
## consumed in apply_move call order. Empty means the default shape (MOVED pushes
## one, anything else pushes none). This is how a fixture expresses the synchronous
## arm cut: {"pop": 1, "push": 2}.
var stack_ops: Array = []
## Absolute epoch to set after the i-th apply_move, when present.
var epoch_after_move: Array = []
## Absolute generation to set after the i-th apply_move, when present.
var generation_after_move: Array = []
## Per-call rewind outcomes; falls back to `rewind_result` once exhausted.
var rewind_results: Array = []

## e.g. "rewind", "apply-remote", "move(0,1,0,silent)". Shared with the drain fake so
## a case can assert ONE interleaved call sequence rather than two separate logs.
var call_log: Array = []
var rewind_count: int = 0
## Set when the fake detects a fixture that contradicts itself. The runner turns this
## into a failure; it must never be swallowed.
var contract_violation: String = ""

var _stack: Array = []
var _next_token: int = 1


func _init(shared_log: Array = []) -> void:
	call_log = shared_log
	set_rewind_budget(0)


## Derived, mirroring the real stack: max(0, depth - STACK_FLOOR).
func rewind_budget() -> int:
	return maxi(0, _stack.size() - STACK_FLOOR)


## Reseeds the whole stack with `value + STACK_FLOOR` fresh tokens, so a fixture's
## "rewindBudget": N keeps meaning exactly what it always meant while real token
## identities sit underneath it.
func set_rewind_budget(value: int) -> void:
	_stack.clear()
	for i in range(value + STACK_FLOOR):
		_stack.append(_mint_token())


## Identity of the snapshot a rewind would restore to right now. -1 if the stack is
## somehow empty, which should not occur -- the floor is always STACK_FLOOR tokens.
func top_token() -> int:
	return -1 if _stack.is_empty() else _stack[_stack.size() - 1]


func can_reconcile() -> bool:
	return can_reconcile_value


func world_epoch() -> int:
	return world_epoch_value


func world_generation() -> int:
	return world_generation_value


func rewind_one() -> bool:
	call_log.append("rewind")
	var ok: bool = rewind_results.pop_front() if not rewind_results.is_empty() else rewind_result
	if not ok:
		return false
	# Mirrors the real floor: refuse once the budget is actually exhausted, whatever
	# the fixture's flat "rewind" flag says.
	if _stack.size() <= STACK_FLOOR:
		return false
	_stack.pop_back()
	rewind_count += 1
	return true


func can_apply_pending_remote() -> bool:
	return can_apply_remote_result


func apply_pending_remote() -> bool:
	call_log.append("apply-remote")
	return apply_remote_result


func apply_move(player_slot: int, dx: int, dy: int, silent: bool) -> int:
	call_log.append(
		"move(%d,%d,%d,%s)" % [player_slot, dx, dy, "silent" if silent else "loud"]
	)
	if move_outcomes.is_empty():
		_violate("apply_move ran out of queued moveOutcomes -- the fixture under-declared them.")
		return CouchPredictionTypes.MoveOutcome.BLOCKED
	var outcome: int = move_outcomes.pop_front()

	var before_count := _stack.size()
	if not stack_ops.is_empty():
		_apply_stack_op(stack_ops.pop_front())
	elif outcome == CouchPredictionTypes.MoveOutcome.MOVED:
		# Default shape: a MOVED outcome takes exactly one snapshot of its own.
		_stack.append(_mint_token())

	# Peek rather than consume, so the contract check can see whether THIS call also
	# changes the generation before the queue is drained below.
	var generation_changes: bool = (
		not generation_after_move.is_empty()
		and generation_after_move[0] != world_generation_value
	)
	_check_stack_contract(outcome, before_count, _stack.size(), generation_changes)

	if not epoch_after_move.is_empty():
		world_epoch_value = epoch_after_move.pop_front()
	if not generation_after_move.is_empty():
		world_generation_value = generation_after_move.pop_front()
	return outcome


func _apply_stack_op(op: Dictionary) -> void:
	for i in range(int(op.get("pop", 0))):
		if _stack.is_empty():
			_violate("a scripted stackOps entry popped an already-empty stack.")
			return
		_stack.pop_back()
	for i in range(int(op.get("push", 0))):
		_stack.append(_mint_token())


## Checks the NET stack-depth change against the outcome, not the mechanism used to
## reach it -- a pop-one-push-two call is not a violation, which is precisely why one
## rewind is a visual no-op in that case.
func _check_stack_contract(
	outcome: int, before_count: int, after_count: int, generation_changed_this_call: bool
) -> void:
	if not contract_assertions_enabled:
		return
	# The contract holds only while the rollback base survives. A call that also
	# changes the generation has truncated the stack for its own reasons, and the
	# generation change IS the signal that the old contract no longer applies -- the
	# core's post-move base guard is what catches that, not this check.
	if generation_changed_this_call:
		return
	var expected_delta := 1 if outcome == CouchPredictionTypes.MoveOutcome.MOVED else 0
	var actual_delta := after_count - before_count
	if actual_delta == expected_delta:
		return
	_violate(
		(
			"a %s outcome must change the snapshot stack's NET depth by exactly %d "
			+ "(this call changed it by %d, stack went from %d to %d entries). This checks a "
			+ "SCRIPTED fixture's own internal consistency, not any engine's actual behaviour."
		)
		% [
			CouchPredictionTypes.label_for_value(
				CouchPredictionTypes.MOVE_OUTCOME_LABELS, outcome
			),
			expected_delta,
			actual_delta,
			before_count,
			after_count,
		]
	)


func _violate(message: String) -> void:
	if contract_violation.is_empty():
		contract_violation = message


func _mint_token() -> int:
	var token := _next_token
	_next_token += 1
	return token
