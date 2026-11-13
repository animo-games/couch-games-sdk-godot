import subprocess, sys, os
REPO = "/home/daniel/Repositories/couch-games-sdk-godot/netcode/"
GODOT = os.path.expanduser("~/.local/share/godot/app_userdata/Godots/versions/Godot_v4_7-stable_linux_x86_64/Godot_v4.7-stable_linux.x86_64")
SCRATCH = "/tmp/claude-1000/-home-daniel-Repositories-couch-games-sdk-godot/e31212cf-6cbc-4f10-88f9-520898fb9bd8/scratchpad/g47"
C="net_clock.gd"; E="net_clock_echo.gd"; T="fixed_ticker.gd"
MUTS = {
 "m01-no-half-rtt": (C, "(rtt_ms / 2) * _policy.tick_hz", "0"),
 "m02-no-backwards-resync": (C, "host_tick < _last_host_tick - _policy.resync_ticks", "false"),
 "m03-no-threshold-resync": (C, "absi(raw_err) > _policy.resync_ticks * 1000", "false"),
 "m04-no-rate-clamp": (C, "clampi(nudge, -_policy.drift_max_permille, _policy.drift_max_permille)", "nudge"),
 "m05-no-drift-correction": (C, "rate_permille = 1000 + clampi(", "rate_permille = 1000 + 0 * clampi("),
 "m06-snap-every-snapshot": (C, "_anchor_milli = estimate", "_anchor_milli = observed"),
 "m07-rtt-ignores-hold": (C, "now_ms - _ring_ms[idx] - hold_ms", "now_ms - _ring_ms[idx]"),
 "m08-no-recv-dedupe": (C, "if recv_tick > _last_sampled_recv:", "if true:"),
 "m09-no-ring-check": (C, "if _ring_ticks[idx] == recv_tick:", "if true:"),
 "m10-no-discard": (C, "if sample <= _policy.max_rtt_sample_ms:", "if true:"),
 "m11-no-settle": (C, "if recv_tick < _settle_tick:\n\t\treturn", "if false:\n\t\treturn"),
 "m12-no-hysteresis": (C, "target_margin_ticks + _policy.margin_hysteresis_ticks", "target_margin_ticks"),
 "m13-no-shrink-interval": (C, "now_ms - _last_shrink_ms >= _policy.lead_shrink_interval_ms", "true"),
 "m14-never-shrink": (C, "lead_ticks = maxi(0, lead_ticks - 1)", "lead_ticks = lead_ticks"),
 "m15-no-jitter-margin": (C, "_policy.min_margin_ticks + _ceil_ticks(jitter_ms)", "_policy.min_margin_ticks"),
 "m16-grow-by-one": (C, "lead_ticks + (target_margin_ticks - margin)", "lead_ticks + 1"),
 "m17-no-catchup-cap": (C, "if count > _policy.max_catchup_ticks:", "if false:"),
 "m18-restamp-after-resync": (C, "_next_stamp = maxi(_next_stamp, _last_stamped + 1)", "pass"),
 "m19-render-not-monotone": (C, "if _has_render and value < _last_render:", "if false:"),
 "m20-no-render-delay": (C, " - _policy.render_delay_ticks * 1000", ""),
 "m21-reset-keeps-rtt": (C, "\trtt_ms = _policy.default_rtt_ms\n", "\tpass\n"),
 "m22-stale-processed": (C, "if host_tick < _last_host_tick:\n\t\treturn", "if false:\n\t\treturn"),
 "m23-no-lead-bootstrap": (C, "lead_ticks = mini(_policy.max_lead_ticks, _ceil_ticks(rtt_ms / 2) + target_margin_ticks)", "lead_ticks = 0"),
 "m24-reset-no-generation": (C, "\tsync_generation = generation\n", "\tpass\n"),
 "m25-no-err-smoothing": (C, " * _policy.offset_alpha_numerator / _policy.offset_alpha_denominator", ""),
 "m26-no-max-lead": (C, "lead_ticks = mini(_policy.max_lead_ticks, lead_ticks + (", "lead_ticks = maxi(0, lead_ticks + ("),
 "m27-resync-keeps-err": (C, "\t_smoothed_err = 0\n\trate_permille = 1000\n", "\trate_permille = 1000\n"),
 "m28-rttvar-init-zero": (C, "rttvar_ms = sample / 2", "rttvar_ms = 0"),
 "m29-rtt-no-ewma": (C, "rtt_ms = (rtt_ms * (ad - an) + sample * an) / ad", "rtt_ms = sample"),
 "e01-older-updates": (E, "if _peers.has(peer_id) and input_tick <= int(_peers[peer_id][\"tick\"]):", "if false:"),
 "e02-margin-off-by-one": (E, "var margin: int = input_tick - next_host_tick", "var margin: int = input_tick - next_host_tick + 1"),
 "e03-late-counts-all": (E, "\tif margin < 0:\n", "\tif true:\n"),
 "e04-hold-from-zero": (E, "maxi(0, now_ms - int(rec[\"recv_ms\"]))", "0"),
 "t01-ticker-floor": (T, "((elapsed + 1) * _tick_hz - 1) / 1000", "(elapsed * _tick_hz) / 1000 - 1"),
 "t02-ticker-accum": (T, "var due: int = last_due + 1 - next_tick", "var due: int = mini(last_due + 1 - next_tick, 1)"),
}
def run():
    r = subprocess.run([GODOT, "--headless", "--path", SCRATCH, "--script", "res://addons/couch-games-sdk/netcode/fixtures/run_net_clock.gd"], capture_output=True, text=True, timeout=600)
    out = r.stdout + r.stderr
    return r.returncode, [l.strip() for l in out.splitlines() if "FAIL:" in l], [l.strip() for l in out.splitlines() if "SCRIPT ERROR" in l or "Parse Error" in l], [l for l in out.splitlines() if "G14 net clock" in l]
names = sys.argv[1:] or list(MUTS)
origs = {f: open(REPO+f).read() for f in (C,E,T)}
try:
    for name in names:
        f, a, b = MUTS[name]
        assert origs[f].count(a) == 1, (name, origs[f].count(a))
        open(REPO+f, "w").write(origs[f].replace(a, b))
        rc, fails, errs, summ = run()
        print(f"{name}: rc={rc} fails={len(fails)} errs={len(errs)} {summ}", flush=True)
        for x in fails[:6]: print("    ", x[:160])
        for x in errs[:2]: print("    ERR", x[:160])
        open(REPO+f, "w").write(origs[f])
finally:
    for f, s in origs.items(): open(REPO+f, "w").write(s)
