## Tunable policy for CouchNetClock, CouchFixedTicker and CouchNetClockEcho.
##
## All time is integer. The host timeline is expressed in MILLITICKS (tick * 1000)
## so fractions of a tick are representable without floats. Rates are permille
## (1000 == real time). A fresh policy should be used per clock so one caller's
## tuning cannot leak into another.
class_name CouchNetClockPolicy
extends RefCounted

## Host simulation rate.
var tick_hz: int = 60
## RTT assumed before the first sample.
var default_rtt_ms: int = 100
## RTT samples above this are DISCARDED (not clamped).
var max_rtt_sample_ms: int = 2000
## srtt EWMA gain (RFC 6298: 1/8).
var rtt_alpha_numerator: int = 1
var rtt_alpha_denominator: int = 8
## rttvar EWMA gain (RFC 6298: 1/4).
var rttvar_alpha_numerator: int = 1
var rttvar_alpha_denominator: int = 4
## Smoothing of the per-snapshot clock error (1/8).
var offset_alpha_numerator: int = 1
var offset_alpha_denominator: int = 8
## A (smoothed) clock error is spread over this long.
var drift_correct_ms: int = 500
## The estimate's rate stays within 1000 +/- this (permille).
var drift_max_permille: int = 50
## A raw error beyond this many ticks is a hard re-sync.
var resync_ticks: int = 8
## Inputs should arrive at least this many ticks before the host needs them.
var min_margin_ticks: int = 1
## Target margin grows by rttvar_ms * this / 1000 (converted to ticks, rounded up).
var margin_jitter_permille: int = 1000
## The lead shrinks only when the observed margin exceeds target + this.
var margin_hysteresis_ticks: int = 2
## At most one 1-tick lead shrink per this interval.
var lead_shrink_interval_ms: int = 1000
var max_lead_ticks: int = 30
## advance() emits at most this many ticks per call.
var max_catchup_ticks: int = 8
## Interpolation runs this many ticks behind the host-time estimate.
var render_delay_ticks: int = 3
## Size of the stamped-tick -> local send time ring.
var send_ring_size: int = 128


static func default_policy() -> CouchNetClockPolicy:
	return CouchNetClockPolicy.new()


## Milliseconds per tick, times 1000 (1_000_000 / tick_hz).
func tick_ms_milli() -> int:
	return 1_000_000 / maxi(tick_hz, 1)
