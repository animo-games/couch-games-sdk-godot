## CLIENT-side estimate of the host's tick timeline plus the input lead.
##
## CONTRACT (see the step-0c design). Integer-only; time is always passed in as
## the client's own local `now_ms` -- absolute times are never compared across
## machines, only differences on one clock.
##
## - on_snapshot(host_tick, now_ms): the host's last simulated tick, with RTT/2
##   of link delay added, becomes an observation of the host timeline. The first
##   one syncs (emits resynced("first-sync")); a raw error beyond
##   policy.resync_ticks, or a host_tick far below the last one, is a hard
##   re-sync; otherwise the smoothed error is spread over drift_correct_ms by
##   nudging rate_permille within 1000 +/- drift_max_permille. The estimate is
##   continuous: a rate change never jumps it.
## - on_echo(recv_tick, hold_ms, margin, now_ms): RTT sample = now - send time of
##   recv_tick - hold_ms (srtt/rttvar per RFC 6298), only for a recv_tick still
##   in the send ring and newer than the last sampled one; samples above
##   max_rtt_sample_ms are discarded. The reported margin steers lead_ticks: grow
##   at once when below target_margin_ticks, shrink one tick at most per
##   lead_shrink_interval_ms when above target + hysteresis.
## - advance(now_ms): the input ticks to stamp NOW (ascending, consecutive, at
##   most max_catchup_ticks; a longer gap jumps and counts skipped_ticks). Never
##   repeats a tick within a reset() epoch.
## - render_tick_milli(now_ms): estimate minus render_delay_ticks, monotone
##   since the last reset().
## - reset(): new epoch; forgets everything, sync_generation += 1.
##
## WHY RTT COMES FROM recv_tick + hold_ms, NOT ack_tick. The host buffers an
## input (~ the input lead) until its tick is simulated, so `now - send(ack_tick)`
## = uplink + buffer hold + snapshot phase + downlink. The lead is derived from
## RTT, so measuring the hold as RTT is a feedback loop that ratchets the lead up
## forever. The host instead echoes the NEWEST RECEIVED input tick and how long it
## held it (CouchNetClockEcho); `now - send(recv_tick) - hold_ms` is the link RTT
## alone, and the host reports the arrival margin directly.
##
## Lead and RTT survive a hard re-sync (they describe the link, not the host's
## timeline); only reset() forgets them. A tick is never stamped twice within one
## reset() epoch: after a re-sync to a lower timeline advance() stalls until the
## target passes the last stamped tick.
class_name CouchNetClock
extends RefCounted

## reason: "first-sync" | "error-over-threshold" | "host-tick-backwards"
signal resynced(reason: String)

## False until the first on_snapshot after construction/reset().
var synced: bool = false
## +1 on reset() and on every hard re-sync.
var sync_generation: int = 0
## srtt (default_rtt_ms before any sample).
var rtt_ms: int = 0
var rttvar_ms: int = 0
var rtt_sample_count: int = 0
var lead_ticks: int = 0
## min_margin + ceil(rttvar * permille / 1000 / tick_ms), in ticks.
var target_margin_ticks: int = 0
var rate_permille: int = 1000
var last_margin: int = 0
## Ticks dropped by advance() jumps (a gap longer than max_catchup_ticks).
var skipped_ticks: int = 0

var _policy: CouchNetClockPolicy

const _NEVER: int = -(1 << 40)

var _anchor_ms: int = 0
var _anchor_milli: int = 0
var _smoothed_err: int = 0
var _last_host_tick: int = 0
var _have_host_tick: bool = false
var _ring_ticks: PackedInt64Array = PackedInt64Array()
var _ring_ms: PackedInt64Array = PackedInt64Array()
var _last_sampled_recv: int = _NEVER
var _settle_tick: int = _NEVER
var _last_shrink_ms: int = _NEVER
var _had_echo: bool = false
var _next_stamp: int = 0
var _stamp_generation: int = -1
var _last_stamped: int = 0
var _has_stamped: bool = false
var _last_render: int = 0
var _has_render: bool = false


func _init(policy: CouchNetClockPolicy = null) -> void:
	_policy = policy if policy != null else CouchNetClockPolicy.default_policy()
	_clear()


## New epoch: forget rtt, lead, ring and sync; sync_generation += 1.
func reset() -> void:
	var generation: int = sync_generation + 1
	_clear()
	sync_generation = generation


func _clear() -> void:
	synced = false
	sync_generation = 0
	rtt_ms = _policy.default_rtt_ms
	rttvar_ms = 0
	rtt_sample_count = 0
	lead_ticks = 0
	rate_permille = 1000
	last_margin = 0
	skipped_ticks = 0
	_anchor_ms = 0
	_anchor_milli = 0
	_smoothed_err = 0
	_last_host_tick = 0
	_have_host_tick = false
	var size: int = maxi(_policy.send_ring_size, 1)
	_ring_ticks = PackedInt64Array()
	_ring_ticks.resize(size)
	_ring_ticks.fill(_NEVER)
	_ring_ms = PackedInt64Array()
	_ring_ms.resize(size)
	_last_sampled_recv = _NEVER
	_settle_tick = _NEVER
	_last_shrink_ms = _NEVER
	_had_echo = false
	_next_stamp = 0
	_stamp_generation = -1
	_last_stamped = 0
	_has_stamped = false
	_last_render = 0
	_has_render = false
	_update_target()


func on_snapshot(host_tick: int, now_ms: int) -> void:
	var observed: int = host_tick * 1000 + (rtt_ms / 2) * _policy.tick_hz
	if not synced:
		_snap(observed, now_ms, host_tick)
		synced = true
		if not _had_echo:
			lead_ticks = mini(_policy.max_lead_ticks, _ceil_ticks(rtt_ms / 2) + target_margin_ticks)
		sync_generation += 1
		resynced.emit("first-sync")
		return
	if host_tick < _last_host_tick - _policy.resync_ticks:
		_snap(observed, now_ms, host_tick)
		sync_generation += 1
		resynced.emit("host-tick-backwards")
		return
	if host_tick < _last_host_tick:
		return # stale / reordered snapshot
	var estimate: int = host_tick_estimate_milli(now_ms)
	var raw_err: int = observed - estimate
	if absi(raw_err) > _policy.resync_ticks * 1000:
		_snap(observed, now_ms, host_tick)
		sync_generation += 1
		resynced.emit("error-over-threshold")
		return
	_last_host_tick = host_tick
	_smoothed_err += (raw_err - _smoothed_err) * _policy.offset_alpha_numerator / _policy.offset_alpha_denominator
	_anchor_milli = estimate
	_anchor_ms = now_ms
	var nudge: int = _smoothed_err * 1000 / (_policy.drift_correct_ms * _policy.tick_hz)
	rate_permille = 1000 + clampi(nudge, -_policy.drift_max_permille, _policy.drift_max_permille)


func _snap(observed: int, now_ms: int, host_tick: int) -> void:
	_anchor_milli = observed
	_anchor_ms = now_ms
	_smoothed_err = 0
	rate_permille = 1000
	_last_host_tick = host_tick
	_have_host_tick = true


func on_echo(recv_tick: int, hold_ms: int, margin: int, now_ms: int) -> void:
	_had_echo = true
	if recv_tick > _last_sampled_recv:
		var idx: int = posmod(recv_tick, _ring_ticks.size())
		if _ring_ticks[idx] == recv_tick:
			var sample: int = maxi(0, now_ms - _ring_ms[idx] - hold_ms)
			if sample <= _policy.max_rtt_sample_ms:
				_last_sampled_recv = recv_tick
				_take_rtt_sample(sample)
	last_margin = margin
	if recv_tick < _settle_tick:
		return
	if margin < target_margin_ticks:
		lead_ticks = mini(_policy.max_lead_ticks, lead_ticks + (target_margin_ticks - margin))
		_settle_tick = _next_stamp
	elif margin > target_margin_ticks + _policy.margin_hysteresis_ticks \
			and now_ms - _last_shrink_ms >= _policy.lead_shrink_interval_ms:
		lead_ticks = maxi(0, lead_ticks - 1)
		_last_shrink_ms = now_ms
		_settle_tick = _next_stamp


func _take_rtt_sample(sample: int) -> void:
	if rtt_sample_count == 0:
		rtt_ms = sample
		rttvar_ms = sample / 2
	else:
		var bn: int = _policy.rttvar_alpha_numerator
		var bd: int = _policy.rttvar_alpha_denominator
		var an: int = _policy.rtt_alpha_numerator
		var ad: int = _policy.rtt_alpha_denominator
		rttvar_ms = (rttvar_ms * (bd - bn) + absi(rtt_ms - sample) * bn) / bd
		rtt_ms = (rtt_ms * (ad - an) + sample * an) / ad
	rtt_sample_count += 1
	_update_target()


func _update_target() -> void:
	var jitter_ms: int = rttvar_ms * _policy.margin_jitter_permille / 1000
	target_margin_ticks = _policy.min_margin_ticks + _ceil_ticks(jitter_ms)


## ceil(ms * tick_hz / 1000)
func _ceil_ticks(ms: int) -> int:
	return (ms * _policy.tick_hz + 999) / 1000


## Input ticks to simulate and send now, ascending and consecutive.
func advance(now_ms: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	if not synced:
		return out
	var target: int = _floor_div(host_tick_estimate_milli(now_ms), 1000) + lead_ticks
	if _stamp_generation != sync_generation:
		_stamp_generation = sync_generation
		_next_stamp = target
		if _has_stamped:
			_next_stamp = maxi(_next_stamp, _last_stamped + 1)
	if target < _next_stamp:
		return out
	var count: int = target - _next_stamp + 1
	if count > _policy.max_catchup_ticks:
		skipped_ticks += count - _policy.max_catchup_ticks
		_next_stamp = target - _policy.max_catchup_ticks + 1
	for tick in range(_next_stamp, target + 1):
		out.append(tick)
		var idx: int = posmod(tick, _ring_ticks.size())
		_ring_ticks[idx] = tick
		_ring_ms[idx] = now_ms
	_next_stamp = target + 1
	_last_stamped = target
	_has_stamped = true
	return out


func _floor_div(a: int, b: int) -> int:
	return (a - posmod(a, b)) / b


## Estimated host timeline in milliticks (tick * 1000).
func host_tick_estimate_milli(now_ms: int) -> int:
	if not synced:
		return 0
	return _anchor_milli + (now_ms - _anchor_ms) * _policy.tick_hz * rate_permille / 1000


## Interpolation time in milliticks.
func render_tick_milli(now_ms: int) -> int:
	var value: int = host_tick_estimate_milli(now_ms) - _policy.render_delay_ticks * 1000
	if _has_render and value < _last_render:
		value = _last_render
	_last_render = value
	_has_render = true
	return value
