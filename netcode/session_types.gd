## Engine-neutral value vocabulary for session draining and recovery.
class_name CouchSessionTypes
extends RefCounted


enum RecoveryTrigger {
	NONE = 0,
	SEQUENCE_GAP = 1,
	UNAPPLICABLE_HEAD = 2,
	STUCK_HEAD = 3,
	VOIDED_LATCH = 4,
	NO_BASELINE = 5,
	TRANSPORT_GAP = 6,
}

enum SessionActionKind {
	SEND_REBASELINE_REQUEST = 0,
	ANNOUNCE_RECOVERY_STATE = 1,
	WARN_STUCK_HEAD = 2,
	ANNOUNCE_GAVE_UP = 3,
}

const RECOVERY_TRIGGER_LABELS := {
	RecoveryTrigger.NONE: "none",
	RecoveryTrigger.SEQUENCE_GAP: "sequence-gap",
	RecoveryTrigger.UNAPPLICABLE_HEAD: "unapplicable-head",
	RecoveryTrigger.STUCK_HEAD: "stuck-head",
	RecoveryTrigger.VOIDED_LATCH: "voided-latch",
	RecoveryTrigger.NO_BASELINE: "no-baseline",
	RecoveryTrigger.TRANSPORT_GAP: "transport-gap",
}

const SESSION_ACTION_KIND_LABELS := {
	SessionActionKind.SEND_REBASELINE_REQUEST: "send-rebaseline-request",
	SessionActionKind.ANNOUNCE_RECOVERY_STATE: "announce-recovery-state",
	SessionActionKind.WARN_STUCK_HEAD: "warn-stuck-head",
	SessionActionKind.ANNOUNCE_GAVE_UP: "announce-gave-up",
}


static func value_for_label(labels: Dictionary, label: String) -> int:
	for key in labels:
		if labels[key] == label:
			return key
	return -1


static func label_for_value(labels: Dictionary, value: int) -> String:
	return labels.get(value, "unknown(%d)" % value)


## Holds a transport-gap fact until the local roster role is known.
class TransportGapDispatchGate extends RefCounted:
	var _pending: bool = false

	func report() -> void:
		_pending = true

	func reset() -> void:
		_pending = false

	func on_local_world_replaced(preserve_pending_report: bool) -> void:
		if not preserve_pending_report:
			reset()

	func try_dispatch(has_current_local_roster_entry: bool, is_remote_guest: bool) -> bool:
		if not _pending or not has_current_local_roster_entry:
			return false
		_pending = false
		return is_remote_guest


## One ordered outbound action produced by the session layer.
class SessionAction extends RefCounted:
	const NO_HEAD_LEVEL := -1

	var kind: int = CouchSessionTypes.SessionActionKind.SEND_REBASELINE_REQUEST
	var trigger: int = CouchSessionTypes.RecoveryTrigger.NONE
	var nonce: int = 0
	var attempt: int = 0
	var max_attempts: int = 0
	var active: bool = false
	var elapsed_ms: int = 0
	var head_level: int = NO_HEAD_LEVEL

	static func create(
		action_kind: int,
		recovery_trigger: int,
		action_nonce: int,
		action_attempt: int,
		action_max_attempts: int,
		is_active: bool,
		elapsed: int,
		action_head_level: int = NO_HEAD_LEVEL
	) -> SessionAction:
		var action := SessionAction.new()
		action.kind = action_kind
		action.trigger = recovery_trigger
		action.nonce = action_nonce
		action.attempt = action_attempt
		action.max_attempts = action_max_attempts
		action.active = is_active
		action.elapsed_ms = elapsed
		action.head_level = action_head_level
		return action

	static func send(
		recovery_trigger: int,
		action_nonce: int,
		action_attempt: int,
		action_max_attempts: int,
		action_head_level: int = NO_HEAD_LEVEL
	) -> SessionAction:
		return create(
			CouchSessionTypes.SessionActionKind.SEND_REBASELINE_REQUEST,
			recovery_trigger,
			action_nonce,
			action_attempt,
			action_max_attempts,
			false,
			0,
			action_head_level
		)

	static func announce(is_active: bool) -> SessionAction:
		return create(
			CouchSessionTypes.SessionActionKind.ANNOUNCE_RECOVERY_STATE,
			CouchSessionTypes.RecoveryTrigger.NONE,
			0,
			0,
			0,
			is_active,
			0
		)

	static func gave_up(recovery_trigger: int, attempts: int) -> SessionAction:
		return create(
			CouchSessionTypes.SessionActionKind.ANNOUNCE_GAVE_UP,
			recovery_trigger,
			0,
			attempts,
			0,
			false,
			0
		)

	static func stuck_head(elapsed: int) -> SessionAction:
		return create(
			CouchSessionTypes.SessionActionKind.WARN_STUCK_HEAD,
			CouchSessionTypes.RecoveryTrigger.NONE,
			0,
			0,
			0,
			false,
			elapsed
		)

	func _to_string() -> String:
		match kind:
			CouchSessionTypes.SessionActionKind.SEND_REBASELINE_REQUEST:
				return (
					"send-rebaseline-request(trigger=%s,nonce=%d,attempt=%d/%d)"
					% [
						CouchSessionTypes.label_for_value(
							CouchSessionTypes.RECOVERY_TRIGGER_LABELS, trigger
						),
						nonce,
						attempt,
						max_attempts,
					]
				)
			CouchSessionTypes.SessionActionKind.ANNOUNCE_RECOVERY_STATE:
				return "announce-recovery-state(active=%s)" % ("true" if active else "false")
			CouchSessionTypes.SessionActionKind.WARN_STUCK_HEAD:
				return "warn-stuck-head(elapsed=%d)" % elapsed_ms
			CouchSessionTypes.SessionActionKind.ANNOUNCE_GAVE_UP:
				return (
					"announce-gave-up(trigger=%s,attempts=%d)"
					% [
						CouchSessionTypes.label_for_value(
							CouchSessionTypes.RECOVERY_TRIGGER_LABELS, trigger
						),
						attempt,
					]
				)
		return "unknown(%d)" % kind


## Queue-head description with enqueue-time identity.
class HeadDescriptor extends RefCounted:
	var has_head: bool = false
	var token: int = 0
	var kind: int = CouchPredictionTypes.OpKind.NEUTRAL
	var level: int = 0
	var player_slot: int = -1
	var request_sequence: int = 0
	var dx: int = 0
	var dy: int = 0

	static func none() -> HeadDescriptor:
		return HeadDescriptor.new()

	static func create(
		head_token: int,
		op_kind: int,
		head_level: int,
		slot: int,
		sequence: int,
		x: int,
		y: int
	) -> HeadDescriptor:
		var head := HeadDescriptor.new()
		head.has_head = true
		head.token = head_token
		head.kind = op_kind
		head.level = head_level
		head.player_slot = slot
		head.request_sequence = sequence
		head.dx = x
		head.dy = y
		return head

	func to_op() -> CouchPredictionTypes.AuthoritativeOp:
		if kind == CouchPredictionTypes.OpKind.MOVE:
			return CouchPredictionTypes.AuthoritativeOp.move(
				player_slot, request_sequence, dx, dy
			)
		return CouchPredictionTypes.AuthoritativeOp.simple(kind)


class FrameInput extends RefCounted:
	var now_ms: int
	var is_predicting: bool
	var current_level: int
	var head: HeadDescriptor

	static func create(
		now: int, predicting: bool, level: int, head_descriptor: HeadDescriptor
	) -> FrameInput:
		var input := FrameInput.new()
		input.now_ms = now
		input.is_predicting = predicting
		input.current_level = level
		input.head = head_descriptor
		return input


class FrameResult extends RefCounted:
	var steps: Array = []
	var actions: Array = []
	var head_consumed: bool = false

	static func create(step_list: Array, action_list: Array, consumed: bool) -> FrameResult:
		var result := FrameResult.new()
		result.steps = step_list
		result.actions = action_list
		result.head_consumed = consumed
		return result

	static func empty() -> FrameResult:
		return create([], [], false)


class ArrivalResult extends RefCounted:
	var should_enqueue: bool
	var steps: Array = []
	var actions: Array = []

	static func create(enqueue: bool, step_list: Array, action_list: Array) -> ArrivalResult:
		var result := ArrivalResult.new()
		result.should_enqueue = enqueue
		result.steps = step_list
		result.actions = action_list
		return result


class SyncAdoptionResult extends RefCounted:
	var steps: Array = []
	var actions: Array = []

	static func create(step_list: Array, action_list: Array) -> SyncAdoptionResult:
		var result := SyncAdoptionResult.new()
		result.steps = step_list
		result.actions = action_list
		return result


## GDScript replacement for TryConfirmCurrentBaseline's bool + out actions pair.
class BaselineConfirmationResult extends RefCounted:
	var confirmed: bool
	var actions: Array = []

	static func create(was_confirmed: bool, action_list: Array) -> BaselineConfirmationResult:
		var result := BaselineConfirmationResult.new()
		result.confirmed = was_confirmed
		result.actions = action_list
		return result
