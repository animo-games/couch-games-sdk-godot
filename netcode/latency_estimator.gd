## Integer-only RTT EWMA and clamped reconciliation timeout.
class_name CouchLatencyEstimator
extends RefCounted

var _policy: CouchPredictionPolicy
var rtt_ms: int
var sample_count: int = 0

var timeout_ms: int:
	get:
		if _policy.fixed_timeout_ms > 0:
			return _policy.fixed_timeout_ms
		return clampi(
			rtt_ms * _policy.timeout_rtt_multiplier,
			_policy.min_timeout_ms,
			_policy.max_timeout_ms
		)


func _init(policy: CouchPredictionPolicy) -> void:
	_policy = policy
	rtt_ms = policy.default_rtt_ms


## Adds a confirmed-prediction RTT sample. Other drop paths must never call this.
func add_sample(sample_ms: int) -> void:
	var sample := clampi(sample_ms, 0, _policy.max_sample_ms)
	if sample_count == 0:
		rtt_ms = sample
	else:
		var denominator := _policy.rtt_alpha_denominator
		var numerator := _policy.rtt_alpha_numerator
		rtt_ms = (
			rtt_ms * (denominator - numerator) + sample * numerator
		) / denominator
	sample_count += 1


func reset() -> void:
	rtt_ms = _policy.default_rtt_ms
	sample_count = 0
