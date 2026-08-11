## Host-authoritative client prediction and reconciliation for one predicting player.
##
## Core invariant: at every observable boundary the world equals authoritative state
## with every live pending prediction re-applied in ascending request-sequence order.
class_name CouchPredictionCore
extends RefCounted


class Pending extends RefCounted:
	var player_slot: int
	var request_sequence: int
	var dx: int
	var dy: int
	var changed: bool
	var submitted_at_ms: int


class Orphan extends RefCounted:
	var player_slot: int
	var request_sequence: int


var policy: CouchPredictionPolicy
var _pending: Array = []
var _latency: CouchLatencyEstimator
var _tracked_epoch: int = 0
var _has_epoch: bool = false
var _tracked_generation: int = 0

## Latched after the rollback base is destroyed with predictions outstanding.
var _poisoned: bool = false
var _has_destroying_move: bool = false
var _destroying_move_slot: int = 0
var _destroying_move_sequence: int = 0
## A foreign mutation while poisoned voids destroying-move echo proof.
var _mutated_while_latched: bool = false
## Predictions abandoned without being rewound out of the world.
var _orphans: Array = []

var pending_count: int:
	get:
		return _pending.size()

var has_orphaned_predictions: bool:
	get:
		return not _orphans.is_empty()

var oldest_pending_sequence: int:
	get:
		return 0 if _pending.is_empty() else _pending[0].request_sequence

var rtt_ms: int:
	get:
		return _latency.rtt_ms

var sample_count: int:
	get:
		return _latency.sample_count

var timeout_ms: int:
	get:
		return _latency.timeout_ms

var is_diverged: bool:
	get:
		return _poisoned

var needs_rebaseline: bool:
	get:
		return _poisoned and _mutated_while_latched


func _init(prediction_policy: CouchPredictionPolicy) -> void:
	policy = prediction_policy
	_latency = CouchLatencyEstimator.new(policy)


func _changed_count() -> int:
	var count := 0
	for prediction in _pending:
		if prediction.changed:
			count += 1
	return count


## Adopts rollback-structure identity and reports a change after first observation.
func _structure_changed(world: Object, include_epoch: bool) -> bool:
	var changed: bool = (
		world.world_generation() != _tracked_generation
		or (include_epoch and world.world_epoch() != _tracked_epoch)
	)
	_tracked_generation = world.world_generation()
	if not _has_epoch:
		return false
	return changed


func _note_lost_base(
	steps: Array, world: Object, speculative_layers: int, include_epoch: bool
) -> bool:
	if not _structure_changed(world, include_epoch):
		return false
	if speculative_layers == 0:
		return false
	steps.append(CouchPredictionTypes.ReconcileStep.simple(CouchPredictionTypes.StepKind.DIVERGED))
	_abandon_pending()
	_poisoned = true
	return true


func _check_base_between_calls(steps: Array, world: Object) -> bool:
	return _note_lost_base(steps, world, _pending.size(), false)


func _check_base_after_own_move(steps: Array, world: Object) -> bool:
	return _note_lost_base(steps, world, _pending.size() + 1, true)


func _remember_orphan(player_slot: int, request_sequence: int) -> void:
	var orphan := Orphan.new()
	orphan.player_slot = player_slot
	orphan.request_sequence = request_sequence
	_orphans.append(orphan)


func _record_destroying_move(player_slot: int, request_sequence: int) -> void:
	_has_destroying_move = true
	_destroying_move_slot = player_slot
	_destroying_move_sequence = request_sequence
	_mutated_while_latched = false


func _clear_latch() -> void:
	_poisoned = false
	_orphans.clear()
	_has_destroying_move = false
	_mutated_while_latched = false


func _abandon_pending() -> void:
	_abandon_pending_up_to(_pending.size() - 1)


## Only predictions at or below this index remain represented after a partial rollback.
func _abandon_pending_up_to(upto_index_inclusive: int) -> void:
	for i in range(mini(upto_index_inclusive + 1, _pending.size())):
		_remember_orphan(_pending[i].player_slot, _pending[i].request_sequence)
	_pending.clear()


## Returns the orphan-drop step on an exact match, otherwise null.
func _try_consume_orphan_echo(op: CouchPredictionTypes.AuthoritativeOp) -> Variant:
	if op.kind != CouchPredictionTypes.OpKind.MOVE:
		return null

	var matched_index := -1
	var to_retire: Array[int] = []
	for i in range(_orphans.size()):
		var orphan: Orphan = _orphans[i]
		if orphan.player_slot != op.player_slot:
			continue
		if orphan.request_sequence < op.request_sequence:
			to_retire.append(i)
		elif orphan.request_sequence == op.request_sequence:
			matched_index = i
	if matched_index >= 0:
		to_retire.append(matched_index)

	to_retire.sort()
	for i in range(to_retire.size() - 1, -1, -1):
		_orphans.remove_at(to_retire[i])

	if matched_index < 0:
		return null
	return CouchPredictionTypes.ReconcileStep.simple(
		CouchPredictionTypes.StepKind.DROP_ORPHANED_ECHO
	)


## Attempts one speculative local operation.
func predict_local_move(
	player_slot: int, dx: int, dy: int, request_sequence: int, now_ms: int, world: Object
) -> CouchPredictionTypes.PredictResult:
	var generation_steps: Array = []
	_check_base_between_calls(generation_steps, world)
	if _poisoned:
		return CouchPredictionTypes.PredictResult.create(
			false,
			CouchPredictionTypes.SkipReason.DIVERGED,
			CouchPredictionTypes.MoveOutcome.BLOCKED,
			generation_steps
		)

	if not _has_epoch:
		_tracked_epoch = world.world_epoch()
		_has_epoch = true
	elif world.world_epoch() != _tracked_epoch:
		if not _pending.is_empty():
			var flush_steps := [
				CouchPredictionTypes.ReconcileStep.simple(
					CouchPredictionTypes.StepKind.FLUSH_PREDICTIONS
				)
			]
			_abandon_pending()
			_tracked_epoch = world.world_epoch()
			return CouchPredictionTypes.PredictResult.create(
				false,
				CouchPredictionTypes.SkipReason.EPOCH_CHANGED,
				CouchPredictionTypes.MoveOutcome.BLOCKED,
				flush_steps
			)
		_tracked_epoch = world.world_epoch()

	if _abs(dx) + _abs(dy) != 1:
		return _skipped(CouchPredictionTypes.SkipReason.NOT_UNIT_INPUT)
	if not world.can_reconcile():
		return _skipped(CouchPredictionTypes.SkipReason.WORLD_BUSY)
	if _pending.size() >= policy.max_pending_predictions:
		return _skipped(CouchPredictionTypes.SkipReason.PENDING_LIMIT)
	if world.rewind_budget() < _changed_count():
		return _skipped(CouchPredictionTypes.SkipReason.REWIND_BUDGET)

	var outcome: int = world.apply_move(player_slot, dx, dy, false)
	var crush_steps: Array = []
	if _check_base_after_own_move(crush_steps, world):
		_tracked_epoch = world.world_epoch()
		_remember_orphan(player_slot, request_sequence)
		_record_destroying_move(player_slot, request_sequence)
		return CouchPredictionTypes.PredictResult.create(
			false, CouchPredictionTypes.SkipReason.DIVERGED, outcome, crush_steps
		)

	if outcome == CouchPredictionTypes.MoveOutcome.BLOCKED:
		return _skipped(CouchPredictionTypes.SkipReason.WORLD_BUSY)

	var record := Pending.new()
	record.player_slot = player_slot
	record.request_sequence = request_sequence
	record.dx = dx
	record.dy = dy
	record.changed = outcome == CouchPredictionTypes.MoveOutcome.MOVED
	record.submitted_at_ms = now_ms
	_pending.append(record)
	_tracked_epoch = world.world_epoch()
	return CouchPredictionTypes.PredictResult.create(
		true,
		CouchPredictionTypes.SkipReason.NONE,
		outcome,
		[
			CouchPredictionTypes.ReconcileStep.create(
				CouchPredictionTypes.StepKind.PREDICT,
				player_slot,
				request_sequence,
				dx,
				dy
			)
		]
	)


func _skipped(reason: int) -> CouchPredictionTypes.PredictResult:
	return CouchPredictionTypes.PredictResult.create(
		false, reason, CouchPredictionTypes.MoveOutcome.BLOCKED, []
	)


## Reconciles the authoritative operation currently at the drain head.
func on_authoritative_operation(
	op: CouchPredictionTypes.AuthoritativeOp, now_ms: int, world: Object
) -> CouchPredictionTypes.ReconcileResult:
	var generation_steps: Array = []
	_check_base_between_calls(generation_steps, world)

	var orphan_step: Variant = _try_consume_orphan_echo(op)
	if orphan_step != null:
		if (
			_poisoned
			and _has_destroying_move
			and not _mutated_while_latched
			and op.player_slot == _destroying_move_slot
			and op.request_sequence == _destroying_move_sequence
		):
			_poisoned = false
			_has_destroying_move = false
			_mutated_while_latched = false
		generation_steps.append(orphan_step)
		return CouchPredictionTypes.ReconcileResult.create(true, generation_steps)

	if _pending.is_empty():
		_tracked_epoch = world.world_epoch()
		_has_epoch = true
		var result := _apply_or_defer(world)
		var just_voided := (
			not _mutated_while_latched
			and _poisoned
			and result.consumed
			and op.kind in [CouchPredictionTypes.OpKind.MOVE, CouchPredictionTypes.OpKind.UNDO]
		)
		if just_voided:
			_mutated_while_latched = true
		if op.kind == CouchPredictionTypes.OpKind.WORLD_RESET and result.consumed:
			_clear_latch()
		if generation_steps.is_empty() and not just_voided:
			return result
		generation_steps.append_array(result.steps)
		if just_voided:
			generation_steps.append(
				CouchPredictionTypes.ReconcileStep.simple(
					CouchPredictionTypes.StepKind.REBASELINE_REQUIRED
				)
			)
		return CouchPredictionTypes.ReconcileResult.create(result.consumed, generation_steps)

	if op.kind == CouchPredictionTypes.OpKind.NEUTRAL:
		return _apply_or_defer(world)

	if op.kind == CouchPredictionTypes.OpKind.WORLD_RESET:
		if not world.can_apply_pending_remote():
			return CouchPredictionTypes.ReconcileResult.deferred()
		var reset_steps := [
			CouchPredictionTypes.ReconcileStep.simple(
				CouchPredictionTypes.StepKind.FLUSH_PREDICTIONS
			)
		]
		_abandon_pending()
		var reset_applied := _try_apply(reset_steps, world)
		if reset_applied:
			_clear_latch()
		_tracked_epoch = world.world_epoch()
		_has_epoch = true
		return CouchPredictionTypes.ReconcileResult.create(reset_applied, reset_steps)

	var head: Pending = _pending[0]
	var is_confirmation := (
		op.kind == CouchPredictionTypes.OpKind.MOVE
		and op.player_slot == head.player_slot
		and op.request_sequence == head.request_sequence
	)
	if is_confirmation:
		_pending.remove_at(0)
		_latency.add_sample(now_ms - head.submitted_at_ms)
		return CouchPredictionTypes.ReconcileResult.create(
			true,
			[
				CouchPredictionTypes.ReconcileStep.create(
					CouchPredictionTypes.StepKind.DROP_CONFIRMED,
					head.player_slot,
					head.request_sequence,
					head.dx,
					head.dy
				)
			]
		)

	if not world.can_reconcile() or not world.can_apply_pending_remote():
		return CouchPredictionTypes.ReconcileResult.deferred()

	var steps: Array = []
	if world.world_epoch() != _tracked_epoch:
		steps.append(
			CouchPredictionTypes.ReconcileStep.simple(
				CouchPredictionTypes.StepKind.FLUSH_PREDICTIONS
			)
		)
		_abandon_pending()
		var flush_applied := _try_apply(steps, world)
		_tracked_epoch = world.world_epoch()
		_has_epoch = true
		return CouchPredictionTypes.ReconcileResult.create(flush_applied, steps)

	if world.rewind_budget() < _changed_count():
		steps.append(CouchPredictionTypes.ReconcileStep.simple(CouchPredictionTypes.StepKind.ABORT))
		_abandon_pending()
		var abort_applied := _try_apply(steps, world)
		_tracked_epoch = world.world_epoch()
		_has_epoch = true
		return CouchPredictionTypes.ReconcileResult.create(abort_applied, steps)

	var rollback_failed_at := _rollback_changed_newest_first(steps, world)
	if rollback_failed_at >= 0:
		_abandon_pending_up_to(rollback_failed_at)
		var rollback_abort_applied := _try_apply(steps, world)
		_tracked_epoch = world.world_epoch()
		_has_epoch = true
		return CouchPredictionTypes.ReconcileResult.create(rollback_abort_applied, steps)

	if op.kind == CouchPredictionTypes.OpKind.MOVE:
		_drop_superseded_own_predictions(steps, op)
	var applied := _try_apply(steps, world)
	_replay_remaining(steps, world)
	_tracked_epoch = world.world_epoch()
	_has_epoch = true
	return CouchPredictionTypes.ReconcileResult.create(applied, steps)


## Advances real time and unwinds a prediction whose confirmation timed out.
func tick(now_ms: int, world: Object) -> CouchPredictionTypes.ReconcileResult:
	var generation_steps: Array = []
	_check_base_between_calls(generation_steps, world)
	if _poisoned:
		return CouchPredictionTypes.ReconcileResult.create(false, generation_steps)
	if _pending.is_empty():
		return CouchPredictionTypes.ReconcileResult.create(false, [])
	if world.world_epoch() != _tracked_epoch:
		var flush_steps := [
			CouchPredictionTypes.ReconcileStep.simple(
				CouchPredictionTypes.StepKind.FLUSH_PREDICTIONS
			)
		]
		_abandon_pending()
		_tracked_epoch = world.world_epoch()
		_has_epoch = true
		return CouchPredictionTypes.ReconcileResult.create(false, flush_steps)
	if not world.can_reconcile():
		return CouchPredictionTypes.ReconcileResult.create(false, [])

	var oldest: Pending = _pending[0]
	if now_ms - oldest.submitted_at_ms < _latency.timeout_ms:
		return CouchPredictionTypes.ReconcileResult.create(false, [])

	var steps: Array = []
	if world.rewind_budget() < _changed_count():
		steps.append(CouchPredictionTypes.ReconcileStep.simple(CouchPredictionTypes.StepKind.ABORT))
		_abandon_pending()
		_tracked_epoch = world.world_epoch()
		_has_epoch = true
		return CouchPredictionTypes.ReconcileResult.create(false, steps)

	var rollback_failed_at := _rollback_changed_newest_first(steps, world)
	if rollback_failed_at >= 0:
		_abandon_pending_up_to(rollback_failed_at)
		_tracked_epoch = world.world_epoch()
		_has_epoch = true
		return CouchPredictionTypes.ReconcileResult.create(false, steps)

	steps.append(
		CouchPredictionTypes.ReconcileStep.create(
			CouchPredictionTypes.StepKind.DROP_TIMED_OUT,
			oldest.player_slot,
			oldest.request_sequence,
			oldest.dx,
			oldest.dy
		)
	)
	_pending.remove_at(0)
	_replay_remaining(steps, world)
	_tracked_epoch = world.world_epoch()
	_has_epoch = true
	return CouchPredictionTypes.ReconcileResult.create(false, steps)


## Drops pending state and baseline identity without resetting RTT knowledge.
func reset() -> Array:
	var had_pending := not _pending.is_empty()
	_pending.clear()
	_has_epoch = false
	_clear_latch()
	if had_pending:
		return [
			CouchPredictionTypes.ReconcileStep.simple(
				CouchPredictionTypes.StepKind.FLUSH_PREDICTIONS
			)
		]
	return []


static func _try_apply(steps: Array, world: Object) -> bool:
	if world.apply_pending_remote():
		steps.append(CouchPredictionTypes.ReconcileStep.simple(CouchPredictionTypes.StepKind.APPLY_REMOTE))
		return true
	steps.append(
		CouchPredictionTypes.ReconcileStep.simple(
			CouchPredictionTypes.StepKind.APPLY_REMOTE_FAILED
		)
	)
	return false


func _apply_or_defer(world: Object) -> CouchPredictionTypes.ReconcileResult:
	if not world.can_apply_pending_remote():
		return CouchPredictionTypes.ReconcileResult.deferred()
	if not world.apply_pending_remote():
		return CouchPredictionTypes.ReconcileResult.create(
			false,
			[
				CouchPredictionTypes.ReconcileStep.simple(
					CouchPredictionTypes.StepKind.APPLY_REMOTE_FAILED
				)
			]
		)
	return CouchPredictionTypes.ReconcileResult.create(
		true,
		[
			CouchPredictionTypes.ReconcileStep.simple(
				CouchPredictionTypes.StepKind.APPLY_REMOTE
			)
		]
	)


## Returns -1 on success or the index whose rewind failed.
func _rollback_changed_newest_first(steps: Array, world: Object) -> int:
	for i in range(_pending.size() - 1, -1, -1):
		var prediction: Pending = _pending[i]
		if not prediction.changed:
			continue
		if not world.rewind_one():
			steps.append(CouchPredictionTypes.ReconcileStep.simple(CouchPredictionTypes.StepKind.ABORT))
			return i
		steps.append(
			CouchPredictionTypes.ReconcileStep.create(
				CouchPredictionTypes.StepKind.ROLLBACK,
				prediction.player_slot,
				prediction.request_sequence,
				prediction.dx,
				prediction.dy
			)
		)
	return -1


func _drop_superseded_own_predictions(
	steps: Array, op: CouchPredictionTypes.AuthoritativeOp
) -> void:
	var i := 0
	while i < _pending.size():
		var prediction: Pending = _pending[i]
		if prediction.player_slot != op.player_slot:
			i += 1
			continue
		if prediction.request_sequence < op.request_sequence:
			steps.append(
				CouchPredictionTypes.ReconcileStep.create(
					CouchPredictionTypes.StepKind.DROP_TIMED_OUT,
					prediction.player_slot,
					prediction.request_sequence,
					prediction.dx,
					prediction.dy
				)
			)
			_pending.remove_at(i)
			continue
		if prediction.request_sequence == op.request_sequence:
			steps.append(
				CouchPredictionTypes.ReconcileStep.create(
					CouchPredictionTypes.StepKind.DROP_SUPERSEDED,
					prediction.player_slot,
					prediction.request_sequence,
					prediction.dx,
					prediction.dy
				)
			)
			_pending.remove_at(i)
			continue
		i += 1


func _replay_remaining(steps: Array, world: Object) -> void:
	var i := 0
	while i < _pending.size():
		if not world.can_reconcile():
			for k in range(i, _pending.size()):
				var stuck: Pending = _pending[k]
				steps.append(
					CouchPredictionTypes.ReconcileStep.create(
						CouchPredictionTypes.StepKind.DROP_MISPREDICTED,
						stuck.player_slot,
						stuck.request_sequence,
						stuck.dx,
						stuck.dy
					)
				)
			_pending.resize(i)
			return

		var prediction: Pending = _pending[i]
		var outcome: int = world.apply_move(
			prediction.player_slot, prediction.dx, prediction.dy, true
		)
		if outcome == CouchPredictionTypes.MoveOutcome.BLOCKED:
			steps.append(
				CouchPredictionTypes.ReconcileStep.create(
					CouchPredictionTypes.StepKind.DROP_MISPREDICTED,
					prediction.player_slot,
					prediction.request_sequence,
					prediction.dx,
					prediction.dy
				)
			)
			_pending.remove_at(i)
			continue

		prediction.changed = outcome == CouchPredictionTypes.MoveOutcome.MOVED
		steps.append(
			CouchPredictionTypes.ReconcileStep.create(
				CouchPredictionTypes.StepKind.REPLAY,
				prediction.player_slot,
				prediction.request_sequence,
				prediction.dx,
				prediction.dy
			)
		)
		i += 1


static func _abs(value: int) -> int:
	return -value if value < 0 else value
