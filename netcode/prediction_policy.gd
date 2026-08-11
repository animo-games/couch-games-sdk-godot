## Tunable seed-1 prediction and reconciliation policy.
##
## These values are policy rather than core invariants. A fresh policy must be used
## for each core so one caller's tuning cannot leak into another.
class_name CouchPredictionPolicy
extends RefCounted

## Assumed RTT before any sample has been observed.
var default_rtt_ms: int = 250
## Integer EWMA numerator.
var rtt_alpha_numerator: int = 1
## Integer EWMA denominator.
var rtt_alpha_denominator: int = 4
## Samples are clamped to this ceiling before entering the EWMA.
var max_sample_ms: int = 2000
## Reconciliation timeout multiplier applied to the current RTT.
var timeout_rtt_multiplier: int = 2
## Floor applied to the adaptive timeout.
var min_timeout_ms: int = 300
## Ceiling applied to the adaptive timeout.
var max_timeout_ms: int = 3000
## Maximum number of unconfirmed predictions allowed at once.
var max_pending_predictions: int = 8
## When positive, replaces the adaptive timeout entirely.
var fixed_timeout_ms: int = 0


## Returns a fresh mutable policy carrying seed-1 defaults.
static func default_policy() -> CouchPredictionPolicy:
	return CouchPredictionPolicy.new()
