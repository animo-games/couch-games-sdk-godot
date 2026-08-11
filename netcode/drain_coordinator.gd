## Authoritative queue draining, arrival ordering, baseline tracking, and recovery policy.
class_name CouchDrainCoordinator
extends RefCounted

var prediction: CouchPredictionCore
var recovery: CouchRecoveryCoordinator
var policy: CouchSessionPolicy

var _head_token: int = 0
var _stuck_since_ms: int = 0
var _stuck_warned: bool = false
var _last_applied_sequence: int = 0
var _has_applied_any: bool = false
var _has_baseline: bool = false
var _level_establishing_queued: bool = false
var _no_baseline_clock_started: bool = false
var _no_baseline_since_ms: int = 0
var _transport_gap_pending: bool = false

## Records argument-contract violations that C# reports by exception.
var contract_violation: String = ""

var has_baseline: bool:
	get:
		return _has_baseline

var head_token: int:
	get:
		return _head_token

var can_request_baseline_confirmation: bool:
	get:
		return (
			_has_baseline
			and prediction.pending_count == 0
			and not prediction.has_orphaned_predictions
			and not prediction.is_diverged
		)


func _init(
	prediction_core: CouchPredictionCore,
	recovery_coordinator: CouchRecoveryCoordinator,
	session_policy: CouchSessionPolicy
) -> void:
	prediction = prediction_core
	recovery = recovery_coordinator
	policy = session_policy


func run_frame(
	input: CouchSessionTypes.FrameInput, world: Object, drain: Object
) -> CouchSessionTypes.FrameResult:
	if input.head.has_head and input.head.token == 0:
		_violate(
			"Head.has_head is true but token == 0; an enqueue site failed to mint a token."
		)
		return CouchSessionTypes.FrameResult.empty()

	var steps: Array = []
	var actions: Array = []

	if _transport_gap_pending:
		if not input.is_predicting:
			_transport_gap_pending = false
		else:
			actions.append_array(
				_request_recovery(
					CouchSessionTypes.RecoveryTrigger.TRANSPORT_GAP,
					input.now_ms,
					input.is_predicting,
					drain
				)
			)

	if input.head.has_head:
		if input.head.token != _head_token:
			_head_token = input.head.token
			_stuck_since_ms = input.now_ms
			_stuck_warned = false
		elif input.now_ms - _stuck_since_ms >= policy.stuck_head_ms:
			if not _stuck_warned:
				_stuck_warned = true
				actions.append(
					CouchSessionTypes.SessionAction.stuck_head(
						input.now_ms - _stuck_since_ms
					)
				)
			actions.append_array(
				_request_recovery(
					CouchSessionTypes.RecoveryTrigger.STUCK_HEAD,
					input.now_ms,
					input.is_predicting,
					drain,
					input.head.level
				)
			)

		if (
			input.is_predicting
			and policy.is_structurally_unapplicable(input.head, input.current_level)
		):
			actions.append_array(
				_request_recovery(
					CouchSessionTypes.RecoveryTrigger.UNAPPLICABLE_HEAD,
					input.now_ms,
					true,
					drain,
					input.head.level
				)
			)

		if not input.is_predicting:
			var consumed: bool = drain.apply_head_unpredicted()
			if consumed:
				drain.dequeue_head()
				_note_head_consumed(input.is_predicting)
			return CouchSessionTypes.FrameResult.create([], actions, consumed)

		drain.bind_head()
		var reconcile_result := prediction.on_authoritative_operation(
			input.head.to_op(), input.now_ms, world
		)
		drain.unbind_head()
		steps.append_array(reconcile_result.steps)

		if prediction.needs_rebaseline:
			actions.append_array(
				_request_recovery(
					CouchSessionTypes.RecoveryTrigger.VOIDED_LATCH,
					input.now_ms,
					true,
					drain,
					input.head.level
				)
			)

		if reconcile_result.consumed:
			drain.dequeue_head()
			_note_head_consumed(input.is_predicting)
			return CouchSessionTypes.FrameResult.create(steps, actions, true)
	else:
		if not input.is_predicting or _has_baseline:
			_no_baseline_clock_started = false
		elif not _no_baseline_clock_started:
			_no_baseline_clock_started = true
			_no_baseline_since_ms = input.now_ms
		elif input.now_ms - _no_baseline_since_ms >= policy.no_baseline_ms:
			actions.append_array(
				_request_recovery(
					CouchSessionTypes.RecoveryTrigger.NO_BASELINE,
					input.now_ms,
					input.is_predicting,
					drain
				)
			)

	if input.is_predicting and prediction.pending_count > 0:
		steps.append_array(prediction.tick(input.now_ms, world).steps)
		if prediction.needs_rebaseline:
			actions.append_array(
				_request_recovery(
					CouchSessionTypes.RecoveryTrigger.VOIDED_LATCH,
					input.now_ms,
					true,
					drain
				)
			)

	return CouchSessionTypes.FrameResult.create(steps, actions, false)


func _note_head_consumed(is_predicting: bool) -> void:
	if not _level_establishing_queued:
		return
	_level_establishing_queued = false
	if is_predicting:
		_has_baseline = true


func _request_recovery(
	trigger: int,
	now_ms: int,
	is_guest: bool,
	drain: Object,
	head_level: int = CouchSessionTypes.SessionAction.NO_HEAD_LEVEL
) -> Array:
	var needs_reachability := recovery.needs_authority_reachability(now_ms, is_guest)
	return recovery.request(
		trigger,
		now_ms,
		is_guest,
		drain.can_reach_authority() if needs_reachability else true,
		head_level
	)


func on_arrival(
	authority_sequence: int,
	is_load_level: bool,
	is_predicting: bool,
	now_ms: int,
	drain: Object
) -> CouchSessionTypes.ArrivalResult:
	if authority_sequence <= _last_applied_sequence:
		return CouchSessionTypes.ArrivalResult.create(false, [], [])

	var actions: Array = []
	if _has_applied_any and authority_sequence != _last_applied_sequence + 1:
		actions = _request_recovery(
			CouchSessionTypes.RecoveryTrigger.SEQUENCE_GAP,
			now_ms,
			is_predicting,
			drain
		)
	_has_applied_any = true

	var steps: Array = []
	if is_load_level:
		_has_baseline = true
		_level_establishing_queued = true
		drain.clear_queue()
		steps = prediction.reset()

	_last_applied_sequence = authority_sequence
	return CouchSessionTypes.ArrivalResult.create(true, steps, actions)


func is_stale_sync(sync_authority_sequence: int) -> bool:
	return sync_authority_sequence < _last_applied_sequence


func adopt_sync(
	authority_sequence: int,
	level: int,
	paused: bool,
	operation_count: int,
	drain: Object
) -> CouchSessionTypes.SyncAdoptionResult:
	drain.clear_queue()
	var steps := prediction.reset()
	var actions := recovery.on_rebaselined()

	_last_applied_sequence = authority_sequence
	_has_baseline = true
	_level_establishing_queued = true
	_transport_gap_pending = false

	drain.enqueue_synthesised_load_level(level)
	drain.enqueue_synthesised_pause(paused)
	for i in range(operation_count):
		drain.enqueue_sync_operation(i)
	return CouchSessionTypes.SyncAdoptionResult.create(steps, actions)


## Result-object adaptation of the C# bool + out-actions API.
func try_confirm_current_baseline(
	authority_sequence: int
) -> CouchSessionTypes.BaselineConfirmationResult:
	if (
		not can_request_baseline_confirmation
		or authority_sequence != _last_applied_sequence
	):
		return CouchSessionTypes.BaselineConfirmationResult.create(false, [])
	_transport_gap_pending = false
	return CouchSessionTypes.BaselineConfirmationResult.create(
		true, recovery.on_rebaselined()
	)


func on_local_world_replaced() -> Array:
	_has_baseline = false
	_no_baseline_clock_started = false
	_transport_gap_pending = false
	return recovery.on_topology_changed()


func on_transport_gap(now_ms: int, is_predicting: bool, drain: Object) -> Array:
	if not is_predicting:
		_transport_gap_pending = false
		return []
	_transport_gap_pending = true
	return _request_recovery(
		CouchSessionTypes.RecoveryTrigger.TRANSPORT_GAP,
		now_ms,
		is_predicting,
		drain
	)


func _violate(message: String) -> void:
	if contract_violation.is_empty():
		contract_violation = message
