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
## Interpolation runs this many ticks behind the host-time estimate; with
## render_delay_adaptive on, this is the floor the measured delay never goes below.
## 6 (100 ms at 60 Hz) from G15's S1b sweep: with snapshots every 2 ticks over
## 50 +/- 30 ms links, 3 left ~65% of frames extrapolating, 6 ~3%, 8 none.
var render_delay_ticks: int = 6
## Measure the render delay from snapshot arrivals (CouchNetClock, RENDER DELAY)
## instead of holding render_delay_ticks: a fixed delay that suits one link
## extrapolates on every frame over a slower one.
var render_delay_adaptive: bool = true
## The measured delay never exceeds this. CouchReplicatedWorld.history_ticks must
## stay above it, or render time falls before the oldest sample kept.
var render_delay_max_ticks: int = 30
## Added to the peak lag, so the next slightly later snapshot still lands in time.
var render_margin_ticks: int = 1
## Once per this interval the target shrinks to the higher peak need of the last
## two intervals plus render_shrink_hysteresis_ticks, when that is below it.
var render_shrink_interval_ms: int = 2000
## Kept above the two intervals' peak need when shrinking, so the target settles
## one tick over the need rather than on it. Every need is at least the floor, so
## a shrink never goes under the floor.
var render_shrink_hysteresis_ticks: int = 1
## While the delay grows, render time advances at (1000 - this) permille of the
## estimate: 500 is half speed, so a 3-tick growth takes 6 ticks (100 ms).
var render_slew_grow_permille: int = 500
## While it shrinks, render time advances at (1000 + this) permille: 50 is 5% fast,
## one tick per 20 (333 ms per tick), too little to notice.
var render_slew_shrink_permille: int = 50
## Size of the stamped-tick -> local send time ring.
var send_ring_size: int = 128


static func default_policy() -> CouchNetClockPolicy:
	return CouchNetClockPolicy.new()


## Milliseconds per tick, times 1000 (1_000_000 / tick_hz).
func tick_ms_milli() -> int:
	return 1_000_000 / maxi(tick_hz, 1)
