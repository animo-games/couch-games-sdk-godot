## Bounded one-outstanding re-baseline request policy.
class_name CouchRecoveryCoordinator
extends RefCounted

var policy: CouchSessionPolicy
var _outstanding_nonce: int = 0
var _nonce_counter: int = 0
var _last_request_ms: int = 0
var _attempts: int = 0
var _has_given_up: bool = false

var outstanding_nonce: int:
	get:
		return _outstanding_nonce

var is_awaiting: bool:
	get:
		return _outstanding_nonce != 0

var attempts: int:
	get:
		return _attempts

var has_given_up: bool:
	get:
		return _has_given_up

var suppress_prediction: bool:
	get:
		return is_awaiting


func _init(session_policy: CouchSessionPolicy) -> void:
	policy = session_policy


func needs_authority_reachability(now_ms: int, is_guest: bool) -> bool:
	return (
		is_guest
		and _attempts < policy.max_attempts
		and (
			_outstanding_nonce == 0
			or now_ms - _last_request_ms >= policy.backoff_ms_for(_attempts)
		)
	)


func request(
	trigger: int,
	now_ms: int,
	is_guest: bool,
	can_reach_authority: bool,
	head_level: int = CouchSessionTypes.SessionAction.NO_HEAD_LEVEL
) -> Array:
	if not is_guest:
		return []
	if _attempts >= policy.max_attempts:
		if _has_given_up:
			return []
		_has_given_up = true
		return [CouchSessionTypes.SessionAction.gave_up(trigger, _attempts)]
	if not needs_authority_reachability(now_ms, is_guest):
		return []
	if not can_reach_authority:
		return []

	var was_awaiting := _outstanding_nonce != 0
	_nonce_counter += 1
	_outstanding_nonce = _nonce_counter
	_last_request_ms = now_ms
	_attempts += 1
	var send := CouchSessionTypes.SessionAction.send(
		trigger, _outstanding_nonce, _attempts, policy.max_attempts, head_level
	)
	if was_awaiting:
		return [send]
	return [CouchSessionTypes.SessionAction.announce(true), send]


func on_rebaselined() -> Array:
	var was_awaiting := _outstanding_nonce != 0
	_outstanding_nonce = 0
	_attempts = 0
	_has_given_up = false
	return [CouchSessionTypes.SessionAction.announce(false)] if was_awaiting else []


func on_topology_changed() -> Array:
	return on_rebaselined()
