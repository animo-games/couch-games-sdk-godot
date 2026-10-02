## Headless gate for the client net clock and its host-side helpers -- gate G14.
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_net_clock.gd
##
## What this proves. CouchNetClock (client) estimates the HOST's tick timeline
## from snapshots, steers an input lead so inputs reach the host before it
## simulates their tick, and hands the game ticks to stamp (advance) and an
## interpolation time (render_tick_milli). CouchFixedTicker is the host's
## drift-free fixed step; CouchNetClockEcho is the host's per-peer bookkeeping of
## the newest received input tick, echoed in the snapshot body so the client's
## RTT sample is not polluted by how long the host buffered the input.
## U1/U2 are unit specs of the ticker and the echo. C1-C10 drive the real
## classes through a simulated network.
##
## C11/C12/U3/U4/U5 and the C2 pinned-rate and C6 shrink-spacing checks were
## added AFTER mutation testing left seven mutants of CouchNetClock green (each
## is the one change a case now kills):
##   M03 no over-threshold resync        -> C11 (forward timeline jump of 120 ticks
##                                          within the epoch: exactly one
##                                          error-over-threshold, back within 1 s)
##   M04 no rate clamp                   -> C12 (6-tick jump, below resync_ticks:
##                                          no resync, rate in bounds on every
##                                          frame and reaching the upper bound)
##   M13 shrink not rate-limited         -> C6 (every lead decrease is 1 tick and
##                                          >= lead_shrink_interval_ms apart)
##   M22 stale snapshot processed        -> U3 (twin clocks, one gets a stale
##                                          snapshot, both stay identical)
##   M25 no error smoothing              -> C2 (rate at a bound on < 1% of frames)
##   M26 lead growth not capped          -> U4 (max_lead_ticks 5: a -20 margin echo
##                                          gives exactly 5; a 200 ms link never
##                                          exceeds 5 while inputs are late)
##   M27 hard resync keeps smoothed err  -> U5 (after a resync an on-time snapshot
##                                          leaves rate exactly 1000)
##
## HARNESS (`_Sim`). Entirely synchronous and deterministic: fixed seeds, no
## WebRTC, no await, no real clock, nothing reads Time. One host (a
## CouchFixedTicker, a CouchNetClockEcho, a snapshot every `snap_every` ticks)
## and ONE client (a CouchNetClock) joined by two one-way links whose delay is
## base +/- uniform jitter from a seeded RNG (FIFO NOT required: messages are
## delivered in ARRIVAL-time order, so jitter reorders them). Host and client
## each run their own frame loop at frame_ms with seeded +/- frame_jitter
## (default 16 +/- 4 ms), on different phases. The CLIENT'S LOCAL CLOCK is the
## host clock plus a large OFFSET (987_654 ms) and optionally a SKEW (skew_permille
## extra client ms per 1000 host ms): the gate proves nothing compares absolute
## times across machines.
##
## Each host frame: ticker.advance -> (strict order) simulate due ticks, then
## process the inputs that have arrived (echo.note_input with the ARRIVAL
## timestamp, i.e. the transport timestamps packets; an input for a tick the
## host already simulated is LATE), then send one snapshot
## {host_tick = last tick simulated, echo = echo_for(peer, now)} once host_tick
## has advanced snap_every ticks since the last one. Each client frame:
## clock.advance -> one input {tick} per stamped tick. A snapshot is delivered to
## the client at its arrival time (on_snapshot, then on_echo if the echo is
## non-empty). A host stall skips host frames (messages queue and are processed
## on resume with their arrival timestamps); a client stall skips client frames.
##
## GROUND TRUTH. The host timeline in milliticks at virtual time t is
## first_tick * 1000 + (t - ticker_start) * tick_hz (it advances tick_hz
## milliticks per ms). The estimate error is clock.host_tick_estimate_milli(
## client_now(t)) - truth(t) at the SAME virtual instant, recorded at every client
## frame. Because a snapshot's host_tick is an integer, "the last tick simulated"
## (simulated at the first host frame at or after its due time), the best any
## estimator can recover is truth minus a mean ~0.5 tick; the design's tolerance
## of 1000 milliticks accounts for that, and the gate does not loosen it.
##
## Every assertion is on an OBSERVED EFFECT (ticks stamped, inputs the host saw
## late, resyncs emitted, estimate error, render monotonicity). Absence checks
## ("zero late", "no resync") are always conjoined with a presence guard (inputs
## were actually processed, the clock actually synced) so an inert implementation
## cannot pass them vacuously.
##
## LOAD-BEARING GOTCHA: SceneTree.quit(code) only SCHEDULES termination; it
## does not return. `return` follows the one quit(...) in this file.
extends SceneTree

const FAR := 1 << 60
const OFFSET_MS := 987_654

var failures := 0
var _checks := 0
var _sims: Array = []   # every simulated run, for the C7 stamp audit


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("  PASS: " + message)
	else:
		failures += 1
		printerr("  FAIL: " + message)


## One run of the simulated network. See the file header.
class _Sim extends RefCounted:
	const PEER := "g1"
	const FAR := 1 << 60

	var name: String = ""
	var policy: CouchNetClockPolicy
	var clock: CouchNetClock
	var ticker: CouchFixedTicker
	var echo: CouchNetClockEcho
	var net_rng := RandomNumberGenerator.new()
	var frame_rng := RandomNumberGenerator.new()

	# Knobs.
	var up_ms := 50            # client -> host one-way base delay
	var down_ms := 50          # host -> client
	var up_jitter := 0
	var down_jitter := 0
	var snap_every := 2        # host ticks between snapshots
	var offset_ms := OFFSET_MS
	var skew_permille := 0     # client ms advance 1000 + skew per 1000 host ms
	var frame_ms := 16
	var frame_jitter := 4
	var warmup_ms := 3000
	var host_stall_from := -1
	var host_stall_to := -1
	var client_stall_from := -1
	var client_stall_to := -1
	var restart_at := -1       # host restarts its ticker at tick 0 at/after this
	var restart_resets_client := false
	var client_reset_delay := 50
	var expects_gaps := false  # a client stall is scheduled (jump gaps are legitimate)
	var has_client_reset := false

	# Virtual time and queues.
	var t := 0
	var next_host_t := 0
	var next_client_t := 7
	var actions: Array = []    # {t, cb}
	var to_host: Array = []    # {arrive, seq, tick, epoch}
	var to_client: Array = []  # {arrive, seq, host_tick, echo}
	var _seq := 0

	# Host epoch / timeline.
	var host_epoch := 1
	var client_epoch := 1
	var epoch_start_t := 0
	var epoch_first_tick := 0
	var next_snap := 0
	var restart_done := false
	var restart_t := -1
	var dropped_inputs := 0

	# Host-side recordings (times are the input's ARRIVAL time).
	var inputs_total := 0
	var late_total := 0
	var input_times := PackedInt64Array()
	var late_times := PackedInt64Array()

	# Client-side recordings.
	var resync_log: Array = []     # {t, reason}
	var frames_t := PackedInt64Array()
	var frames_err := PackedInt64Array()
	var frames_est := PackedInt64Array()
	var frames_lead := PackedInt64Array()
	var frames_rate := PackedInt64Array()
	var lead_log: Array = []       # {cn, delta} for every receive that changed lead_ticks
	var jump_t := -1               # virtual time of the last jump_host()
	var frames_post := 0
	var max_abs_err := -1
	var rate_sum := 0
	var rate_pinned := 0
	var frames_stepped := 0
	var step_violations := 0
	var snaps_since_frame := 0
	var prev_valid := false
	var prev_synced := false
	var prev_est := 0
	var prev_cn := 0
	var prev_resyncs := 0
	var prev_gen := 0
	var render_violations := 0
	var render_frames := 0
	var render_first := 0
	var render_last := 0
	var render_max := -FAR
	var render_minus_est_last := 0
	var prev_r_valid := false
	var prev_r := 0

	# Stamp audit.
	var stamp_epoch := 0
	var stamps_total := 0
	var stamp_times := PackedInt64Array()
	var stamp_violations := 0     # descending / repeated / backwards across a generation
	var stamp_batch_breaks := 0   # a non-consecutive tick INSIDE one advance() batch
	var stamp_repeats := 0        # the same tick stamped twice in one reset() epoch
	var gap_total := 0            # ticks missing between consecutive stamps in one generation
	var max_batch := 0
	var _have_last := false
	var _last_tick := 0
	var _last_gen := 0
	var _seen := {}

	# Client reset recordings.
	var awaiting_first_sync := false
	var reset_info: Dictionary = {}
	var first_sync_info: Dictionary = {}

	func _init(p_policy: CouchNetClockPolicy, seed_value: int) -> void:
		policy = p_policy
		net_rng.seed = seed_value
		frame_rng.seed = seed_value + 1
		clock = CouchNetClock.new(policy)
		ticker = CouchFixedTicker.new(policy.tick_hz)
		echo = CouchNetClockEcho.new()
		ticker.start(0, 0)
		clock.resynced.connect(_on_resynced)

	func _on_resynced(reason: String) -> void:
		resync_log.append({"t": t, "reason": reason})

	# --- time ---

	func client_now(tt: int) -> int:
		return offset_ms + tt + (tt * skew_permille) / 1000

	func truth_milli(tt: int) -> int:
		return epoch_first_tick * 1000 + (tt - epoch_start_t) * policy.tick_hz

	func _delay(base: int, jitter: int) -> int:
		var d := base
		if jitter > 0:
			d += net_rng.randi_range(-jitter, jitter)
		return maxi(d, 1)

	func _frame_gap() -> int:
		var g := frame_ms
		if frame_jitter > 0:
			g += frame_rng.randi_range(-frame_jitter, frame_jitter)
		return maxi(g, 1)

	func schedule(at: int, cb: Callable) -> void:
		actions.append({"t": at, "cb": cb})

	func set_delays(up: int, down: int) -> void:
		up_ms = up
		down_ms = down

	## The host's timeline jumps FORWARD `ticks` within the same epoch (no epoch
	## change: inputs are still accepted). Ground truth is re-based to match.
	func jump_host(ticks: int) -> void:
		var first := truth_milli(t) / 1000 + ticks
		ticker.start(t, first)
		epoch_start_t = t
		epoch_first_tick = first
		jump_t = t

	func _earliest(arr: Array, key: String) -> int:
		var best := -1
		var best_t := FAR
		for i in arr.size():
			var v: int = int(arr[i][key])
			if v < best_t:
				best_t = v
				best = i
		return best

	## Advance virtual time to end_t, processing events in time order (ties:
	## scheduled action, client-bound delivery, host frame, client frame).
	func run_until(end_t: int) -> void:
		while true:
			var best := FAR
			var kind := -1
			var a := _earliest(actions, "t")
			if a >= 0:
				best = int(actions[a]["t"])
				kind = 0
			var m := _earliest(to_client, "arrive")
			if m >= 0 and int(to_client[m]["arrive"]) < best:
				best = int(to_client[m]["arrive"])
				kind = 1
			if next_host_t < best:
				best = next_host_t
				kind = 2
			if next_client_t < best:
				best = next_client_t
				kind = 3
			if kind < 0 or best > end_t:
				break
			t = maxi(t, best)
			match kind:
				0:
					var act: Dictionary = actions[a]
					actions.remove_at(a)
					(act["cb"] as Callable).call()
				1:
					var msg: Dictionary = to_client[m]
					to_client.remove_at(m)
					_client_receive(msg)
				2:
					_host_frame(t)
				3:
					_client_frame(t)
		t = maxi(t, end_t)

	# --- host ---

	func _host_frame(th: int) -> void:
		next_host_t = th + _frame_gap()
		if th >= host_stall_from and th < host_stall_to:
			return
		if restart_at >= 0 and not restart_done and th >= restart_at:
			restart_done = true
			restart_t = th
			host_epoch += 1
			ticker.start(th, 0)
			echo.reset()
			epoch_start_t = th
			epoch_first_tick = 0
			next_snap = 0
			if restart_resets_client:
				schedule(th + client_reset_delay, client_reset)
		ticker.advance(th)
		var last := ticker.next_tick - 1
		var due: Array = []
		var keep: Array = []
		for msg in to_host:
			if int(msg["arrive"]) <= th:
				due.append(msg)
			else:
				keep.append(msg)
		to_host = keep
		due.sort_custom(func(x, y):
			if int(x["arrive"]) != int(y["arrive"]):
				return int(x["arrive"]) < int(y["arrive"])
			return int(x["seq"]) < int(y["seq"])
		)
		for msg in due:
			if int(msg["epoch"]) != host_epoch:
				dropped_inputs += 1
				continue
			var tick := int(msg["tick"])
			var arrive := int(msg["arrive"])
			inputs_total += 1
			input_times.append(arrive)
			if tick < ticker.next_tick:
				late_total += 1
				late_times.append(arrive)
			echo.note_input(PEER, tick, ticker.next_tick, arrive)
		if ticker.started and last >= next_snap:
			_seq += 1
			to_client.append({
				"arrive": th + _delay(down_ms, down_jitter),
				"seq": _seq,
				"host_tick": last,
				"echo": echo.echo_for(PEER, th),
			})
			next_snap = last + snap_every

	# --- client ---

	func _client_receive(msg: Dictionary) -> void:
		var cn := client_now(int(msg["arrive"]))
		snaps_since_frame += 1
		var lead_before := clock.lead_ticks
		clock.on_snapshot(int(msg["host_tick"]), cn)
		var e: Dictionary = msg["echo"]
		if not e.is_empty():
			clock.on_echo(
				int(e.get(CouchNetClockEcho.KEY_RECV_TICK, 0)),
				int(e.get(CouchNetClockEcho.KEY_HOLD_MS, 0)),
				int(e.get(CouchNetClockEcho.KEY_MARGIN, 0)),
				cn
			)
		if clock.lead_ticks != lead_before:
			lead_log.append({"cn": cn, "delta": clock.lead_ticks - lead_before})
		if awaiting_first_sync and clock.synced:
			awaiting_first_sync = false
			first_sync_info = {"t": t, "lead": clock.lead_ticks, "gen": clock.sync_generation}

	## The caller path on session_started: a new epoch for the client clock.
	func client_reset() -> void:
		var gen_before := clock.sync_generation
		var samples_before := clock.rtt_sample_count
		var synced_before := clock.synced
		var lead_before := clock.lead_ticks
		clock.reset()
		client_epoch = host_epoch
		stamp_epoch += 1
		_have_last = false
		prev_valid = false
		prev_r_valid = false
		render_max = -FAR
		awaiting_first_sync = true
		has_client_reset = true
		var adv := clock.advance(client_now(t))
		reset_info = {
			"t": t,
			"gen_before": gen_before,
			"gen_after": clock.sync_generation,
			"samples_before": samples_before,
			"synced_before": synced_before,
			"lead_before": lead_before,
			"synced": clock.synced,
			"rtt": clock.rtt_ms,
			"samples": clock.rtt_sample_count,
			"lead": clock.lead_ticks,
			"advance_size": adv.size(),
		}

	func _client_frame(tc: int) -> void:
		next_client_t = tc + _frame_gap()
		if tc >= client_stall_from and tc < client_stall_to:
			return
		var cn := client_now(tc)
		var ticks := clock.advance(cn)
		max_batch = maxi(max_batch, ticks.size())
		var gen := clock.sync_generation
		for i in ticks.size():
			var tk := int(ticks[i])
			_note_stamp(tk, gen, i == 0, tc)
			_seq += 1
			to_host.append({
				"arrive": tc + _delay(up_ms, up_jitter),
				"seq": _seq,
				"tick": tk,
				"epoch": client_epoch,
			})
		# Observe the estimate against ground truth at this same instant.
		var est := clock.host_tick_estimate_milli(cn)
		var err := est - truth_milli(tc)
		frames_t.append(tc)
		frames_err.append(err)
		frames_est.append(est)
		frames_lead.append(clock.lead_ticks)
		frames_rate.append(clock.rate_permille)
		if tc >= warmup_ms:
			frames_post += 1
			max_abs_err = maxi(max_abs_err, absi(err))
			rate_sum += clock.rate_permille
			var dm := policy.drift_max_permille
			if clock.rate_permille <= 1000 - dm or clock.rate_permille >= 1000 + dm:
				rate_pinned += 1
		# Continuity: between two frames with no resync the estimate moves at
		# a rate inside 1000 +/- drift_max (plus integer truncation: at most 1
		# milli per re-anchor, and every snapshot may re-anchor).
		if (
			prev_valid and clock.synced and prev_synced
			and resync_log.size() == prev_resyncs and clock.sync_generation == prev_gen
		):
			var dn := cn - prev_cn
			var hi := dn * policy.tick_hz * (1000 + policy.drift_max_permille) / 1000 + 1 + snaps_since_frame
			var lo := dn * policy.tick_hz * (1000 - policy.drift_max_permille) / 1000 - 1 - snaps_since_frame
			var step := est - prev_est
			frames_stepped += 1
			if step > hi or step < lo:
				step_violations += 1
		prev_valid = true
		prev_synced = clock.synced
		prev_est = est
		prev_cn = cn
		prev_resyncs = resync_log.size()
		prev_gen = clock.sync_generation
		snaps_since_frame = 0
		# Render time must never go backwards within a reset() epoch.
		var r := clock.render_tick_milli(cn)
		if prev_r_valid and r < prev_r:
			render_violations += 1
		if not prev_r_valid or render_frames == 0:
			render_first = r
		prev_r_valid = true
		prev_r = r
		render_frames += 1
		render_last = r
		render_max = maxi(render_max, r)
		render_minus_est_last = r - est

	func _note_stamp(tk: int, gen: int, first_in_batch: bool, tc: int) -> void:
		stamps_total += 1
		stamp_times.append(tc)
		var key := (stamp_epoch << 40) | tk
		if _seen.has(key):
			stamp_repeats += 1
		_seen[key] = true
		if _have_last:
			if not first_in_batch and tk != _last_tick + 1:
				stamp_batch_breaks += 1
			if gen == _last_gen:
				if tk > _last_tick + 1:
					gap_total += tk - _last_tick - 1
				elif tk <= _last_tick:
					stamp_violations += 1
			elif tk <= _last_tick:
				stamp_violations += 1
		_have_last = true
		_last_tick = tk
		_last_gen = gen

	# --- queries ---

	func resync_reasons(from_t: int, to_t: int) -> Array:
		var out: Array = []
		for entry in resync_log:
			if int(entry["t"]) >= from_t and int(entry["t"]) < to_t:
				out.append(str(entry["reason"]))
		return out

	func count_in(times: PackedInt64Array, from_t: int, to_t: int) -> int:
		var n := 0
		for v in times:
			if v >= from_t and v < to_t:
				n += 1
		return n

	func late_post() -> int:
		return count_in(late_times, warmup_ms, FAR)

	func inputs_post() -> int:
		return count_in(input_times, warmup_ms, FAR)

	## Earliest frame time f >= from_t such that EVERY frame at or after f has
	## |error| <= tol; FAR when the last frame is out of tolerance or none exist.
	func settled_time(from_t: int, tol: int) -> int:
		var result := FAR
		var i := frames_t.size() - 1
		while i >= 0 and frames_t[i] >= from_t:
			if absi(int(frames_err[i])) > tol:
				break
			result = int(frames_t[i])
			i -= 1
		return result

	func lead_at(at: int) -> int:
		for i in frames_t.size():
			if frames_t[i] >= at:
				return int(frames_lead[i])
		return -1

	func lead_peak(from_t: int, to_t: int) -> int:
		var peak := -1
		for i in frames_t.size():
			if frames_t[i] >= from_t and frames_t[i] < to_t:
				peak = maxi(peak, int(frames_lead[i]))
		return peak

	## Frames at or after from_t whose rate_permille is outside 1000 +/- drift_max.
	func rate_out_of_bounds(from_t: int) -> int:
		var n := 0
		var dm := policy.drift_max_permille
		for i in frames_t.size():
			if frames_t[i] >= from_t and (frames_rate[i] < 1000 - dm or frames_rate[i] > 1000 + dm):
				n += 1
		return n

	func rate_max(from_t: int) -> int:
		var best := -FAR
		for i in frames_t.size():
			if frames_t[i] >= from_t:
				best = maxi(best, int(frames_rate[i]))
		return best

	func est_at(at: int) -> int:
		for i in frames_t.size():
			if frames_t[i] >= at:
				return int(frames_est[i])
		return -FAR

	func frame_time_at(at: int) -> int:
		for i in frames_t.size():
			if frames_t[i] >= at:
				return int(frames_t[i])
		return -1

	func rate_mean() -> int:
		if frames_post == 0:
			return 0
		return rate_sum / frames_post


func _run() -> void:
	_case_u1()
	_case_u2()
	_case_c1()
	_case_c2()
	_case_c3()
	_case_c4()
	_case_c5()
	_case_c6()
	_case_c11()
	_case_c12()
	_case_u3()
	_case_u4()
	_case_u5()
	_case_c8()
	_case_c9()
	_case_c10()
	_case_c7()

	print("")
	print("G14 net clock: %d/%d checks passed" % [_checks - failures, _checks])
	if failures > 0:
		printerr("NET_CLOCK_FAILED: %d check(s)" % failures)
	quit(1 if failures > 0 else 0)
	return


func _new_sim(name: String, seed_value: int, hz: int = 60) -> _Sim:
	var policy := CouchNetClockPolicy.new()
	policy.tick_hz = hz
	var sim := _Sim.new(policy, seed_value)
	sim.name = name
	_sims.append(sim)
	return sim


# --- U1: CouchFixedTicker -------------------------------------------------------------


## Ticks due at elapsed ms `elapsed` (>= 0) under start(S, F): tick F + j is due at
## floor(j * 1000 / hz), so j <= ((elapsed + 1) * hz - 1) / 1000.
func _expected_next_tick(hz: int, first_tick: int, elapsed: int) -> int:
	if elapsed < 0:
		return first_tick
	return first_tick + ((elapsed + 1) * hz - 1) / 1000 + 1


func _case_u1() -> void:
	print("U1: CouchFixedTicker")
	for hz in [60, 30]:
		var start_ms := 12345
		var tk := CouchFixedTicker.new(hz)
		tk.start(start_ms, 0)
		_check(tk.started and tk.next_tick == 0, "U1/%d: start() marks it started with next_tick == first_tick (0)" % hz)

		# Irregular real-time steps (1..40 ms) for 10 s: next_tick must equal the
		# closed form at every call, advance() never negative, never skips.
		var rng := RandomNumberGenerator.new()
		rng.seed = 7 + hz
		var now := start_ms
		var mismatches := 0
		var negatives := 0
		var skips := 0
		var total := tk.advance(now)
		var calls := 1
		while now < start_ms + 10_000:
			now += rng.randi_range(1, 40)
			var before := tk.next_tick
			var n := tk.advance(now)
			calls += 1
			if n < 0:
				negatives += 1
			if tk.next_tick != before + n:
				skips += 1
			total += n
			if tk.next_tick != _expected_next_tick(hz, 0, now - start_ms):
				mismatches += 1
		_check(
			total > 10 * hz and mismatches == 0,
			"U1/%d: next_tick equals the closed form at all %d calls over 10 s (%d mismatches, %d ticks)" % [hz, calls, mismatches, total]
		)
		_check(
			total > 10 * hz and negatives == 0 and skips == 0,
			"U1/%d: advance() never negative and next_tick moves by exactly what it returned" % hz
		)

		# No drift: a steady tick_hz per second however the calls are split.
		var steady := CouchFixedTicker.new(hz)
		steady.start(start_ms, 0)
		steady.advance(start_ms)
		var first_second := steady.advance(start_ms + 1000)
		var rest := steady.advance(start_ms + 10_000)
		_check(
			first_second == hz and first_second + rest == 10 * hz,
			"U1/%d: exactly %d ticks in the first second and %d in 10 s after the first (got %d, %d)" % [hz, hz, 10 * hz, first_second, first_second + rest]
		)

		# One huge jump equals the same time walked in small steps.
		var jump := CouchFixedTicker.new(hz)
		jump.start(start_ms, 0)
		var jumped := jump.advance(start_ms + 5000)
		_check(
			jumped == _expected_next_tick(hz, 0, 5000) and jump.next_tick == jumped,
			"U1/%d: a single 5 s advance returns the full catch-up (%d ticks)" % [hz, jumped]
		)

		# first_tick is honoured.
		var ft := CouchFixedTicker.new(hz)
		ft.start(1000, 100)
		var ft_start := ft.next_tick
		var ft_first := ft.advance(1000)
		var ft_after := ft.next_tick
		ft.advance(3000)
		_check(
			ft_start == 100 and ft_first == 1 and ft_after == 101 and ft.next_tick == _expected_next_tick(hz, 100, 2000),
			"U1/%d: first_tick 100 honoured (next_tick %d -> %d -> %d)" % [hz, ft_start, ft_after, ft.next_tick]
		)

		# A clock that goes backwards neither returns ticks nor rewinds.
		var back_before := ft.next_tick
		var back := ft.advance(2500)
		_check(
			back_before > 100 and back == 0 and ft.next_tick == back_before,
			"U1/%d: advance() with an earlier now returns 0 and leaves next_tick" % hz
		)

		# Restart (new epoch) re-bases the timeline.
		ft.start(9000, 0)
		var re_start := ft.next_tick
		ft.advance(9000 + 1000)
		_check(
			re_start == 0 and ft.next_tick == _expected_next_tick(hz, 0, 1000),
			"U1/%d: start() again re-bases to tick 0 at the new start time" % hz
		)


# --- U2: CouchNetClockEcho ------------------------------------------------------------


func _case_u2() -> void:
	print("U2: CouchNetClockEcho")
	var K_RECV := CouchNetClockEcho.KEY_RECV_TICK
	var K_HOLD := CouchNetClockEcho.KEY_HOLD_MS
	var K_MARGIN := CouchNetClockEcho.KEY_MARGIN
	var e := CouchNetClockEcho.new()

	var unknown_before := e.echo_for("zzz", 100)
	e.note_input("a", 10, 8, 1000)
	var first := e.echo_for("a", 1250)
	_check(
		first.size() == 3 and first.get(K_RECV, -1) == 10 and first.get(K_HOLD, -1) == 250 and first.get(K_MARGIN, -99) == 2,
		"U2: first input -> {recv_tick 10, hold_ms 250 at +250ms, margin 10 - 8 = 2}"
	)
	_check(
		not first.is_empty() and unknown_before.is_empty() and e.echo_for("zzz", 100).is_empty() and e.late_count("zzz") == 0,
		"U2: an unknown peer echoes {} (and late_count 0) while a known one does not"
	)

	e.note_input("a", 9, 9, 1300)
	var older := e.echo_for("a", 1300)
	_check(
		older.get(K_RECV, -1) == 10 and older.get(K_HOLD, -1) == 300 and older.get(K_MARGIN, -99) == 2,
		"U2: an OLDER input tick is ignored (recv_tick, hold base and margin unchanged)"
	)
	e.note_input("a", 10, 11, 1400)
	var dup := e.echo_for("a", 1400)
	_check(
		dup.get(K_RECV, -1) == 10 and dup.get(K_HOLD, -1) == 400 and dup.get(K_MARGIN, -99) == 2 and e.late_count("a") == 0,
		"U2: a DUPLICATE tick is ignored (hold keeps counting from the first receipt, margin stays 2, not late)"
	)

	e.note_input("a", 11, 11, 1500)
	var on_time := e.echo_for("a", 1500)
	_check(
		on_time.get(K_RECV, -1) == 11 and on_time.get(K_HOLD, -1) == 0 and on_time.get(K_MARGIN, -99) == 0 and e.late_count("a") == 0,
		"U2: a newer input updates; margin 0 is on time (not counted late)"
	)
	_check(
		e.echo_for("a", 1900).get(K_HOLD, -1) == 400 and e.echo_for("a", 2300).get(K_HOLD, -1) == 800,
		"U2: hold_ms grows with now (400 at +400, 800 at +800)"
	)
	_check(
		e.echo_for("a", 1400).get(K_HOLD, -1) == 0 and e.echo_for("a", 1400).get(K_RECV, -1) == 11,
		"U2: hold_ms never goes negative when now precedes the receipt"
	)

	e.note_input("a", 12, 15, 1600)
	var late1 := e.echo_for("a", 1600)
	_check(
		late1.get(K_MARGIN, 99) == -3 and late1.get(K_RECV, -1) == 12 and e.late_count("a") == 1,
		"U2: a late newest input has margin -3 and late_count becomes 1"
	)
	e.note_input("a", 5, 15, 1650)
	_check(
		e.late_count("a") == 1 and e.echo_for("a", 1650).get(K_RECV, -1) == 12,
		"U2: a late but OLDER input is not counted (late_count stays 1)"
	)
	e.note_input("a", 13, 14, 1700)
	_check(
		e.late_count("a") == 2 and e.echo_for("a", 1700).get(K_MARGIN, 99) == -1,
		"U2: the next late newest input counts again (late_count 2, margin -1)"
	)

	e.note_input("b", 3, 0, 2000)
	var b := e.echo_for("b", 2010)
	_check(
		b.get(K_RECV, -1) == 3 and b.get(K_MARGIN, -99) == 3 and b.get(K_HOLD, -1) == 10
		and e.late_count("b") == 0 and e.late_count("a") == 2 and e.echo_for("a", 2010).get(K_RECV, -1) == 13,
		"U2: peers are independent"
	)

	e.forget("a")
	_check(
		e.echo_for("a", 2010).is_empty() and e.late_count("a") == 0 and e.echo_for("b", 2010).get(K_RECV, -1) == 3,
		"U2: forget(a) clears a (echo {}, late_count 0) and leaves b"
	)
	e.note_input("a", 1, 0, 3000)
	_check(
		e.echo_for("a", 3000).get(K_RECV, -1) == 1,
		"U2: after forget, a lower tick is accepted again (the recv_tick floor was cleared)"
	)
	var before_reset_a := e.echo_for("a", 3000)
	var before_reset_b := e.echo_for("b", 3000)
	e.reset()
	_check(
		not before_reset_a.is_empty() and not before_reset_b.is_empty()
		and e.echo_for("a", 3000).is_empty() and e.echo_for("b", 3000).is_empty() and e.late_count("a") == 0,
		"U2: reset() clears every peer"
	)
	e.note_input("a", 0, 0, 4000)
	_check(
		e.echo_for("a", 4000).get(K_RECV, -1) == 0,
		"U2: after reset the first input (tick 0) is recorded"
	)


# --- C1 / C10: constant link ----------------------------------------------------------


func _c1_checks(label: String, s: _Sim) -> void:
	var p := s.policy
	var reasons := s.resync_reasons(0, _Sim.FAR)
	_check(
		s.clock.synced and reasons == ["first-sync"],
		"%s: synced after exactly one resync (first-sync), got %s" % [label, str(reasons)]
	)
	_check(
		s.clock.rtt_sample_count > 100 and absi(s.clock.rtt_ms - 100) <= 3,
		"%s: rtt_ms %d within +/-3 of 100 (%d samples)" % [label, s.clock.rtt_ms, s.clock.rtt_sample_count]
	)
	_check(
		s.frames_post > 300 and s.max_abs_err <= 1000,
		"%s: |estimate error| <= 1000 milliticks at every post-warmup frame (worst %d over %d frames)" % [label, s.max_abs_err, s.frames_post]
	)
	_check(
		s.inputs_post() > 5 * p.tick_hz and s.late_post() == 0,
		"%s: zero late inputs after warmup (%d late of %d)" % [label, s.late_post(), s.inputs_post()]
	)
	_check(
		s.inputs_total > 8 * p.tick_hz and s.echo.late_count(_Sim.PEER) == s.late_total,
		"%s: the host echo's late_count (%d) equals the late inputs the harness saw (%d)" % [label, s.echo.late_count(_Sim.PEER), s.late_total]
	)
	var target := s.clock.target_margin_ticks
	_check(
		s.clock.rtt_sample_count > 0 and s.clock.last_margin >= target and s.clock.last_margin <= target + p.margin_hysteresis_ticks + 1,
		"%s: final last_margin %d within [target %d, target + hysteresis + 1]" % [label, s.clock.last_margin, target]
	)
	var one_way_ticks := (50 * p.tick_hz + 999) / 1000
	_check(
		s.clock.lead_ticks >= one_way_ticks and s.clock.lead_ticks <= p.max_lead_ticks,
		"%s: lead %d ticks covers the 50 ms one-way delay (%d ticks)" % [label, s.clock.lead_ticks, one_way_ticks]
	)
	_check(
		s.stamps_total > 8 * p.tick_hz,
		"%s: the clock stamped %d ticks over the run" % [label, s.stamps_total]
	)


func _case_c1() -> void:
	print("C1: constant 50/50 ms link, no jitter, no skew, 10 s")
	var s := _new_sim("C1", 1001)
	s.run_until(10_000)
	_c1_checks("C1", s)


func _case_c10() -> void:
	print("C10: C1 at 30 Hz")
	var s := _new_sim("C10", 1010, 30)
	s.snap_every = 1
	s.run_until(10_000)
	_c1_checks("C10", s)


# --- C2: jitter -------------------------------------------------------------------------


func _case_c2() -> void:
	print("C2: jitter 50 +/- 30 ms each way, 20 s")
	var s := _new_sim("C2", 1002)
	s.up_jitter = 30
	s.down_jitter = 30
	s.run_until(20_000)
	var reasons := s.resync_reasons(0, _Sim.FAR)
	_check(
		s.clock.synced and reasons == ["first-sync"],
		"C2: synced with ZERO resyncs after the first sync, got %s" % str(reasons)
	)
	_check(
		s.inputs_post() > 500 and s.late_post() * 100 <= s.inputs_post(),
		"C2: at most 1%% of post-warmup inputs late (%d of %d)" % [s.late_post(), s.inputs_post()]
	)
	_check(
		s.frames_stepped > 800 and s.step_violations == 0,
		"C2: the estimate never moves faster than the bounded rate (%d violations over %d frame steps)" % [s.step_violations, s.frames_stepped]
	)
	_check(
		s.clock.rtt_sample_count > 200 and s.clock.target_margin_ticks > s.policy.min_margin_ticks,
		"C2: jitter raises target_margin_ticks (%d) above min_margin_ticks (%d)" % [s.clock.target_margin_ticks, s.policy.min_margin_ticks]
	)
	_check(
		s.clock.rtt_sample_count > 200 and s.clock.rtt_ms >= 75 and s.clock.rtt_ms <= 130 and s.clock.rttvar_ms > 0,
		"C2: srtt %d ms stays near the 100 ms mean and rttvar %d is positive" % [s.clock.rtt_ms, s.clock.rttvar_ms]
	)
	# Added after mutation testing (M25): the per-snapshot error is smoothed, so the
	# rate is not slammed to a bound by every jittery snapshot.
	_check(
		s.frames_post > 800 and s.rate_pinned * 100 < s.frames_post,
		"C2: rate_permille sits at a bound on < 1%% of post-warmup frames (%d of %d)" % [s.rate_pinned, s.frames_post]
	)


# --- C3: render monotone ------------------------------------------------------------------


func _case_c3() -> void:
	print("C3: render_tick_milli is monotone across jitter and a 600 ms host stall")
	var s := _new_sim("C3", 1003)
	s.up_jitter = 30
	s.down_jitter = 30
	s.host_stall_from = 10_000
	s.host_stall_to = 10_600
	s.run_until(20_000)
	_check(
		s.render_frames > 1000 and s.render_violations == 0 and s.render_last - s.render_first > 1_100_000,
		"C3: render never decreased across %d frames and advanced %d milliticks (%d violations)" % [s.render_frames, s.render_last - s.render_first, s.render_violations]
	)
	_check(
		s.clock.synced and absi(s.render_minus_est_last + s.policy.render_delay_ticks * 1000) <= 1,
		"C3: render_tick_milli == estimate - render_delay_ticks * 1000 (off by %d)" % (s.render_minus_est_last + s.policy.render_delay_ticks * 1000)
	)


# --- C4: host hitch ------------------------------------------------------------------------


func _case_c4() -> void:
	print("C4: host stops ticking and sending for 600 ms, then catches up")
	var s := _new_sim("C4", 1004)
	s.up_jitter = 10
	s.down_jitter = 10
	s.host_stall_from = 8000
	s.host_stall_to = 8600
	s.run_until(15_000)
	var reasons := s.resync_reasons(0, _Sim.FAR)
	var over := 0
	for r in s.resync_reasons(8000, 9600):
		if r == "error-over-threshold":
			over += 1
	_check(
		s.clock.synced and reasons.size() >= 1 and reasons[0] == "first-sync" and over <= 1,
		"C4: first-sync then at most one error-over-threshold for the hitch (got %s)" % str(reasons)
	)
	var settled := s.settled_time(8600, 1000)
	_check(
		s.frames_post > 300 and settled <= 9600,
		"C4: estimate within 1 tick from t=%d (stall ended 8600, must be <= 9600) and stays there" % settled
	)
	var t1 := s.frame_time_at(8000)
	var t2 := s.frame_time_at(8600)
	var grew := s.est_at(8600) - s.est_at(8000)
	var min_grow := (t2 - t1) * s.policy.tick_hz * (1000 - s.policy.drift_max_permille) / 1000 - 5
	_check(
		t1 >= 0 and t2 - t1 >= 550 and grew >= min_grow and grew > 0,
		"C4: the estimate keeps running through the silence (%d milliticks over %d ms, >= %d)" % [grew, t2 - t1, min_grow]
	)
	_check(
		s.stamps_total > 600 and s.stamp_repeats == 0 and s.stamp_violations == 0,
		"C4: %d ticks stamped, none twice, all ascending" % s.stamps_total
	)
	_check(
		s.inputs_post() > 300 and s.count_in(s.late_times, 10_000, _Sim.FAR) == 0,
		"C4: the link recovers: zero late inputs from t=10 s (%d late)" % s.count_in(s.late_times, 10_000, _Sim.FAR)
	)


# --- C5: new epoch ---------------------------------------------------------------------------


func _case_c5() -> void:
	print("C5: the host restarts its ticker at tick 0 after 5 s")
	# A: nobody calls reset() -- the clock must notice by itself.
	var a := _new_sim("C5a", 1005)
	a.up_jitter = 5
	a.down_jitter = 5
	a.restart_at = 5000
	a.run_until(8500)
	var after := a.resync_reasons(a.restart_t, _Sim.FAR)
	_check(
		a.restart_done and a.restart_t >= 5000 and a.clock.synced and after == ["host-tick-backwards"],
		"C5/no-reset: exactly one resync after the restart, host-tick-backwards (got %s)" % str(after)
	)
	var a_settled := a.settled_time(a.restart_t, 1000)
	_check(
		a_settled <= a.restart_t + 1000,
		"C5/no-reset: re-converged to within 1 tick by t=%d (restart at %d, budget 1000 ms)" % [a_settled, a.restart_t]
	)
	_check(
		a.render_frames > 300 and a.render_violations == 0 and a.render_last >= a.render_max and a.render_max > 250_000,
		"C5/no-reset: render never went backwards across the backward resync (held at %d)" % a.render_last
	)

	# B: the caller path -- session_started => clock.reset().
	var b := _new_sim("C5b", 1005)
	b.up_jitter = 5
	b.down_jitter = 5
	b.restart_at = 5000
	b.restart_resets_client = true
	b.run_until(8500)
	var ri := b.reset_info
	_check(
		not ri.is_empty() and ri["gen_after"] == int(ri["gen_before"]) + 1,
		"C5/reset: reset() bumps sync_generation (%s -> %s)" % [str(ri.get("gen_before")), str(ri.get("gen_after"))]
	)
	_check(
		not ri.is_empty() and int(ri["samples_before"]) > 50 and ri["rtt"] == b.policy.default_rtt_ms and ri["samples"] == 0,
		"C5/reset: rtt_ms back to default %d with no samples (got %s, %s)" % [b.policy.default_rtt_ms, str(ri.get("rtt")), str(ri.get("samples"))]
	)
	_check(
		not ri.is_empty() and ri["synced_before"] == true and int(ri["lead_before"]) > 0
		and ri["synced"] == false and ri["advance_size"] == 0 and ri["lead"] == 0,
		"C5/reset: right after reset() the clock is unsynced, stamps nothing and has forgotten its lead"
	)
	var fs := b.first_sync_info
	_check(
		not fs.is_empty() and int(fs["lead"]) >= 2 and int(fs["lead"]) <= 8 and int(fs["gen"]) == int(ri.get("gen_after", -5)) + 1,
		"C5/reset: the first snapshot after reset() syncs (generation +1) and re-bootstraps the lead (%s ticks)" % str(fs.get("lead"))
	)
	var b_after := b.resync_reasons(b.restart_t, _Sim.FAR)
	_check(
		b.clock.synced and b_after == ["first-sync"],
		"C5/reset: the only resync after the restart is the new epoch's first-sync (got %s)" % str(b_after)
	)
	var b_settled := b.settled_time(b.restart_t, 1000)
	_check(
		b_settled <= b.restart_t + 1000,
		"C5/reset: within 1 tick by t=%d (restart at %d, budget 1000 ms)" % [b_settled, b.restart_t]
	)
	_check(
		b.count_in(b.stamp_times, b.restart_t + 1000, b.restart_t + 2000) >= 50
		and b.clock.rtt_sample_count > 10 and absi(b.clock.rtt_ms - 100) <= 15,
		"C5/reset: stamping resumed (%d ticks in the second after) and RTT re-learned (%d ms, %d samples)" % [b.count_in(b.stamp_times, b.restart_t + 1000, b.restart_t + 2000), b.clock.rtt_ms, b.clock.rtt_sample_count]
	)


# --- C6: delay step ---------------------------------------------------------------------------


func _case_c6() -> void:
	print("C6: one-way delay 50 -> 150 ms at 6 s, back to 50 ms at 14 s")
	var s := _new_sim("C6", 1006)
	# Raising the lead by more than max_catchup_ticks in one step is a legitimate
	# advance() jump (counted in skipped_ticks), so C7 must not call it unexplained.
	s.expects_gaps = true
	s.schedule(6000, func(): s.set_delays(150, 150))
	s.schedule(14_000, func(): s.set_delays(50, 50))
	s.run_until(5900)
	var lead_before := s.clock.lead_ticks
	s.run_until(30_000)
	# The steady lead for the 50 ms link, measured on an unperturbed twin.
	var ref := _new_sim("C6ref", 1006)
	ref.run_until(30_000)

	var hz := s.policy.tick_hz
	var peak := s.lead_peak(6000, 14_000)
	_check(
		lead_before >= 1 and peak >= lead_before + 5 and peak >= (150 * hz + 999) / 1000,
		"C6: the lead grows with the delay (%d before the step, peak %d)" % [lead_before, peak]
	)
	var window_inputs := s.count_in(s.input_times, 6000, 9000)
	var window_late := s.count_in(s.late_times, 6000, 9000)
	var bound := 2 * 300 * hz / 1000
	_check(
		window_inputs > 100 and window_late <= bound,
		"C6: late inputs while adapting (t 6-9 s) bounded by 2*RTT of ticks: %d <= %d (of %d inputs)" % [window_late, bound, window_inputs]
	)
	_check(
		s.count_in(s.input_times, 9000, 14_000) > 200 and s.count_in(s.late_times, 9000, 14_000) == 0,
		"C6: zero late inputs from t=9 s to the step back (%d late)" % s.count_in(s.late_times, 9000, 14_000)
	)
	var ref_lead := ref.clock.lead_ticks
	var end_lead := s.clock.lead_ticks
	_check(
		ref.stamps_total > 1000 and absi(end_lead - ref_lead) <= s.policy.margin_hysteresis_ticks and peak > end_lead + 3,
		"C6: by t=30 s the lead shrank back to %d, within hysteresis of the steady %d (peak was %d)" % [end_lead, ref_lead, peak]
	)
	_check(
		s.count_in(s.input_times, 14_000, 30_000) > 500 and s.count_in(s.late_times, 14_000, 30_000) == 0,
		"C6: still zero late inputs after the step back (%d late)" % s.count_in(s.late_times, 14_000, 30_000)
	)
	_check(
		s.clock.rtt_sample_count > 100 and absi(s.clock.rtt_ms - 100) <= 10,
		"C6: srtt returned to the 100 ms RTT (%d)" % s.clock.rtt_ms
	)
	# Added after mutation testing (M13): shrinking is rate-limited on the CLIENT clock.
	var decreases: Array = []
	for entry in s.lead_log:
		if int(entry["delta"]) < 0:
			decreases.append(entry)
	var one_tick_each := true
	var spaced := true
	var min_gap := FAR
	for i in decreases.size():
		if int(decreases[i]["delta"]) != -1:
			one_tick_each = false
		if i > 0:
			var gap := int(decreases[i]["cn"]) - int(decreases[i - 1]["cn"])
			min_gap = mini(min_gap, gap)
			if gap < s.policy.lead_shrink_interval_ms:
				spaced = false
	_check(
		decreases.size() >= 2 and one_tick_each and spaced,
		"C6: %d lead decreases, each exactly 1 tick, >= %d ms apart on the client clock (closest %d ms)" % [decreases.size(), s.policy.lead_shrink_interval_ms, min_gap]
	)


# --- C7: stamps ---------------------------------------------------------------------------------


func _case_c7() -> void:
	print("C7: stamped ticks are ascending, consecutive and never repeated (every run above + a client hitch)")
	# A dedicated client hitch: 300 ms with no client frame forces advance()'s jump.
	var h := _new_sim("C7hitch", 1007)
	h.up_jitter = 5
	h.down_jitter = 5
	h.client_stall_from = 8000
	h.client_stall_to = 8300
	h.expects_gaps = true
	h.run_until(14_000)
	var cap := h.policy.max_catchup_ticks
	_check(
		h.stamps_total > 600 and h.max_batch == cap and h.clock.skipped_ticks >= cap and h.clock.skipped_ticks == h.gap_total,
		"C7: after a 300 ms freeze advance() emits at most %d ticks (max batch %d) and counts the jump (skipped_ticks %d == %d observed missing)" % [cap, h.max_batch, h.clock.skipped_ticks, h.gap_total]
	)
	_check(
		h.stamp_violations == 0 and h.stamp_repeats == 0 and h.stamp_batch_breaks == 0 and h.count_in(h.stamp_times, 9000, 14_000) > 250,
		"C7: the hitch run still stamps ascending, unrepeated, consecutive batches, and resumed (%d ticks after)" % h.count_in(h.stamp_times, 9000, 14_000)
	)
	_check(
		h.settled_time(9500, 1000) <= 9500 + 2 * h.frame_ms and h.frames_post > 300,
		"C7: the estimate was unaffected by the client freeze (within 1 tick from t=9.5 s)"
	)

	var total := 0
	var violations := 0
	var repeats := 0
	var batch_breaks := 0
	var unexplained_gaps := 0
	var count_mismatch := 0
	for entry in _sims:
		var s: _Sim = entry
		total += s.stamps_total
		violations += s.stamp_violations
		repeats += s.stamp_repeats
		batch_breaks += s.stamp_batch_breaks
		if not s.expects_gaps:
			unexplained_gaps += s.gap_total
		if not s.has_client_reset and s.gap_total != s.clock.skipped_ticks:
			count_mismatch += 1
	_check(
		total > 5000 and violations == 0,
		"C7: across %d runs (%d stamps) no tick was stamped out of order or backwards (%d violations)" % [_sims.size(), total, violations]
	)
	_check(
		total > 5000 and repeats == 0,
		"C7: no tick was ever stamped twice within a reset() epoch (%d repeats)" % repeats
	)
	_check(
		total > 5000 and batch_breaks == 0 and unexplained_gaps == 0,
		"C7: ticks are consecutive within a batch and a sync generation (%d breaks, %d unexplained gap ticks)" % [batch_breaks, unexplained_gaps]
	)
	_check(
		total > 5000 and count_mismatch == 0,
		"C7: skipped_ticks equals the missing ticks observed in every run (%d runs disagree)" % count_mismatch
	)


# --- C8: RTT sample hygiene ----------------------------------------------------------------------


func _case_c8() -> void:
	print("C8: RTT sample hygiene (drives CouchNetClock directly)")
	var policy := CouchNetClockPolicy.new()
	var c := CouchNetClock.new(policy)
	c.on_snapshot(100, 1000)
	var first := c.advance(1000)
	var b := c.advance(1100)   # stamped (sent) at 1100
	var cc := c.advance(1200)  # sent at 1200
	var d := c.advance(1300)   # sent at 1300
	var have := first.size() == 1 and b.size() >= 2 and cc.size() >= 1 and d.size() >= 1
	_check(
		have and c.synced and c.rtt_sample_count == 0 and c.rtt_ms == policy.default_rtt_ms,
		"C8: (setup) synced, stamped ticks at 1100/1200/1300, no RTT sample yet (default %d)" % policy.default_rtt_ms
	)
	# No early return when the clock stamps nothing: the check count must not
	# depend on the implementation. The echoes below then simply fail.
	var t_old: int = b[0] if b.size() > 0 else -1
	var t_b: int = b[b.size() - 1] if b.size() > 0 else -1
	var t_d: int = d[d.size() - 1] if d.size() > 0 else -1

	c.on_echo(t_d + 100_000, 0, 3, 1400)
	_check(
		have and c.rtt_sample_count == 0 and c.rtt_ms == policy.default_rtt_ms,
		"C8: an echo for a recv_tick that was never stamped (not in the ring) takes no sample"
	)

	c.on_echo(t_b, 20, 3, 1300)
	_check(
		c.rtt_sample_count == 1 and c.rtt_ms == 180 and c.rttvar_ms == 90,
		"C8: first sample 1300 - 1100 - hold 20 = 180: srtt 180, rttvar 90 (got %d, %d, %d sample)" % [c.rtt_ms, c.rttvar_ms, c.rtt_sample_count]
	)

	c.on_echo(t_b, 20, 3, 1350)
	_check(
		have and c.rtt_sample_count == 1 and c.rtt_ms == 180,
		"C8: the same recv_tick echoed again takes no second sample (one sample, srtt %d)" % c.rtt_ms
	)

	c.on_echo(t_old, 0, 3, 1400)
	_check(
		have and c.rtt_sample_count == 1 and c.rtt_ms == 180,
		"C8: an older recv_tick than the last sampled takes no sample"
	)

	c.on_echo(t_d, 0, 3, 1300 + policy.max_rtt_sample_ms + 500)
	_check(
		have and c.rtt_sample_count == 1 and c.rtt_ms == 180 and c.rttvar_ms == 90,
		"C8: a sample above max_rtt_sample_ms (%d ms) is discarded, not clamped (srtt %d)" % [policy.max_rtt_sample_ms, c.rtt_ms]
	)

	var later := c.advance(3900)
	var t_e: int = later[later.size() - 1] if later.size() > 0 else -1
	c.on_echo(t_e, 500, 3, 4000)  # 4000 - 3900 - 500 = -400 -> 0
	_check(
		later.size() > 0 and c.rtt_sample_count == 2 and absi(c.rtt_ms - 157) <= 1 and absi(c.rttvar_ms - 112) <= 2,
		"C8: a negative sample (-400) is floored to 0 and enters the EWMA: srtt %d (157), rttvar %d (112)" % [c.rtt_ms, c.rttvar_ms]
	)


# --- C9: skew ---------------------------------------------------------------------------------------


func _case_c9() -> void:
	print("C9: client clock 0.5% fast, jitter 50 +/- 10, 30 s")
	var s := _new_sim("C9", 1009)
	s.skew_permille = 5
	s.up_jitter = 10
	s.down_jitter = 10
	s.run_until(30_000)
	_check(
		s.clock.synced and s.frames_post > 1000 and s.max_abs_err <= 1000,
		"C9: estimate error stays within 1 tick after warmup despite the skew (worst %d over %d frames)" % [s.max_abs_err, s.frames_post]
	)
	var mean := s.rate_mean()
	_check(
		s.frames_post > 1000 and mean >= 988 and mean <= 999,
		"C9: the rate settles BELOW 1000 to cancel the fast clock (mean %d permille)" % mean
	)
	_check(
		s.clock.synced and s.frames_post > 1000 and s.rate_pinned * 50 < s.frames_post,
		"C9: rate is not pinned at a bound (%d of %d frames at 950/1050)" % [s.rate_pinned, s.frames_post]
	)
	_check(
		s.stamps_total > 1500 and s.inputs_post() > 1000 and s.late_post() * 100 <= s.inputs_post(),
		"C9: at most 1%% late inputs under skew (%d of %d)" % [s.late_post(), s.inputs_post()]
	)


# --- C11 / C12: host timeline jumps (added after mutation testing) --------------------------


func _jump_run(name: String, seed_value: int, jump_ticks: int) -> _Sim:
	var s := _new_sim(name, seed_value)
	s.up_jitter = 3
	s.down_jitter = 3
	s.expects_gaps = true
	s.schedule(6000, func(): s.jump_host(jump_ticks))
	s.run_until(14_000)
	return s


func _case_c11() -> void:
	print("C11: the host timeline jumps forward 120 ticks within the epoch at 6 s")
	var s := _jump_run("C11", 1011, 120)
	var reasons := s.resync_reasons(s.jump_t, _Sim.FAR)
	_check(
		s.jump_t == 6000 and s.clock.synced and s.resync_reasons(0, s.jump_t) == ["first-sync"] and s.inputs_post() > 500,
		"C11: only first-sync before the jump (jump at t=%d)" % s.jump_t
	)
	_check(
		reasons == ["error-over-threshold"],
		"C11: exactly one error-over-threshold resync after the jump, no other (got %s)" % str(reasons)
	)
	var settled := s.settled_time(s.jump_t, 1000)
	_check(
		s.frames_post > 300 and settled <= s.jump_t + 1000,
		"C11: estimate error within 1000 milliticks from t=%d (jump at %d, must be <= %d) and stays there" % [settled, s.jump_t, s.jump_t + 1000]
	)


func _case_c12() -> void:
	print("C12: the host timeline jumps forward 6 ticks (below resync_ticks) at 6 s")
	var s := _jump_run("C12", 1012, 6)
	var dm := s.policy.drift_max_permille
	_check(
		s.jump_t == 6000 and s.clock.synced and s.resync_reasons(0, _Sim.FAR) == ["first-sync"],
		"C12: NO resync after the jump (got %s)" % str(s.resync_reasons(0, _Sim.FAR))
	)
	var oob := s.rate_out_of_bounds(0)
	_check(
		s.frames_t.size() > 700 and oob == 0,
		"C12: rate_permille within [%d, %d] on every frame (%d outside of %d frames)" % [1000 - dm, 1000 + dm, oob, s.frames_t.size()]
	)
	var rmax := s.rate_max(s.jump_t)
	_check(
		rmax == 1000 + dm,
		"C12: rate reaches the upper bound after the jump (max %d), so the clamp was exercised" % rmax
	)
	var settled := s.settled_time(s.jump_t, 1000)
	_check(
		s.frames_post > 300 and settled <= s.jump_t + 4000,
		"C12: estimate error within 1000 milliticks from t=%d (jump at %d, must be <= %d) and stays there" % [settled, s.jump_t, s.jump_t + 4000]
	)
	_check(
		s.frames_stepped > 600 and s.step_violations == 0,
		"C12: the estimate never moved faster than the bounded rate (%d violations)" % s.step_violations
	)


# --- U3: a stale snapshot is ignored (twin clocks) -----------------------------------------


func _case_u3() -> void:
	print("U3: a stale (reordered) snapshot changes nothing -- twin clocks")
	var a := CouchNetClock.new()
	var b := CouchNetClock.new()
	var ra: Array = []
	var rb: Array = []
	a.resynced.connect(func(r): ra.append(r))
	b.resynced.connect(func(r): rb.append(r))
	# First sync at 1000 (host tick 100), then in-order snapshots 6 ticks / 100 ms
	# apart, the second one a tick early so the smoothed error is non-zero.
	var last_host := 100
	var last_now := 1000
	for c in [a, b]:
		c.on_snapshot(100, 1000)
	for k in range(1, 6):
		last_host = 100 + 6 * k + (1 if k == 2 else 0)
		last_now = 1000 + 100 * k
		for c in [a, b]:
			c.on_snapshot(last_host, last_now)
	var rate_before := b.rate_permille
	# Stale on A only: last - 3 is within resync_ticks, 20 ms after the last one.
	var stale_estimate := a.host_tick_estimate_milli(last_now + 20)
	a.on_snapshot(last_host - 3, last_now + 20)
	_check(
		a.synced and b.synced and ra == ["first-sync"] and rb == ["first-sync"]
		and a.host_tick_estimate_milli(last_now + 20) == stale_estimate and a.rate_permille == rate_before,
		"U3: the stale snapshot (host_tick last-3) leaves A's estimate and rate untouched, no resync (rate %d)" % a.rate_permille
	)
	var all_equal := true
	var samples := 0
	for k in range(1, 6):
		var h := last_host + 6 * k
		var n := last_now + 100 * k
		for c in [a, b]:
			c.on_snapshot(h, n)
		for dt in [0, 17, 60]:
			samples += 1
			if a.host_tick_estimate_milli(n + dt) != b.host_tick_estimate_milli(n + dt) or a.rate_permille != b.rate_permille:
				all_equal = false
	_check(
		samples == 15 and all_equal and ra == rb and ra == ["first-sync"],
		"U3: after the same later snapshots A equals B at %d instants (estimate and rate), A emitted no extra resync (%s)" % [samples, str(ra)]
	)


# --- U4: the lead is capped at max_lead_ticks ----------------------------------------------


func _case_u4() -> void:
	print("U4: lead growth is clamped to max_lead_ticks")
	var policy := CouchNetClockPolicy.new()
	policy.max_lead_ticks = 5
	var c := CouchNetClock.new(policy)
	c.on_snapshot(100, 1000)
	var first := c.advance(1000)
	var t1: int = first[first.size() - 1] if first.size() > 0 else -1
	c.on_echo(t1, 0, -20, 1100)
	_check(
		first.size() == 1 and c.lead_ticks == 5,
		"U4: an echo with margin -20 grows the lead to max_lead_ticks 5 exactly (got %d)" % c.lead_ticks
	)
	var more := c.advance(1200)
	var t2: int = more[more.size() - 1] if more.size() > 0 else -1
	c.on_echo(t2, 0, -20, 1300)
	_check(
		more.size() > 0 and t2 > t1 and c.lead_ticks == 5,
		"U4: a second very late echo keeps it at 5 (got %d)" % c.lead_ticks
	)

	var p2 := CouchNetClockPolicy.new()
	p2.max_lead_ticks = 5
	var s := _Sim.new(p2, 1014)
	s.name = "U4sim"
	_sims.append(s)
	s.set_delays(200, 200)
	s.run_until(10_000)
	var peak := s.lead_peak(0, _Sim.FAR)
	_check(
		s.frames_t.size() > 500 and peak == 5,
		"U4: with a 200 ms one-way delay the lead hits the cap and never exceeds it (peak %d)" % peak
	)
	_check(
		s.late_total > 0 and s.late_post() > 0,
		"U4: the cap bit: inputs were late (%d late, %d after warmup)" % [s.late_total, s.late_post()]
	)


# --- U5: a hard resync forgets the smoothed error ------------------------------------------


func _case_u5() -> void:
	print("U5: a hard resync discards the smoothed error")
	var c := CouchNetClock.new()
	var reasons: Array = []
	c.resynced.connect(func(r): reasons.append(r))
	c.on_snapshot(100, 1000)
	# Sub-threshold snapshots consistently ~5 ticks ahead of the estimate.
	var now := 1000
	for k in 8:
		now += 100
		var host := (c.host_tick_estimate_milli(now) - (c.rtt_ms / 2) * 60) / 1000 + 5
		c.on_snapshot(host, now)
	var built := c.rate_permille
	_check(
		reasons == ["first-sync"] and built > 1000,
		"U5: the smoothed error built up with no resync (rate %d, resyncs %s)" % [built, str(reasons)]
	)
	var t0 := now + 100
	var h := 10   # far below the last host tick: host-tick-backwards
	c.on_snapshot(h, t0)
	var observed := h * 1000 + (c.rtt_ms / 2) * 60
	_check(
		reasons == ["first-sync", "host-tick-backwards"] and c.rate_permille == 1000
		and c.host_tick_estimate_milli(t0) == observed,
		"U5: the hard resync anchors at the observation (%d) and resets the rate to 1000" % observed
	)
	c.on_snapshot(h + 3, t0 + 50)
	_check(
		c.rate_permille == 1000 and c.host_tick_estimate_milli(t0 + 50) == observed + 3000 and reasons.size() == 2,
		"U5: an exactly on-time snapshot after the resync leaves rate exactly 1000 (got %d) and the estimate at %d (want %d)" % [c.rate_permille, c.host_tick_estimate_milli(t0 + 50), observed + 3000]
	)
