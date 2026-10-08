"""Mutation check for the adaptive render delay (CouchNetClock RENDER DELAY) and the
replicated world's tick-window history. Each mutant is one exact search/replace in
a COPY of the addon inside a scratch Godot project; the named gate must fail.

  python3 render-delay-mutations.py <scratch project> [mutant ...]

The project must contain addons/couch-games-sdk as a plain copy (not a symlink or
worktree) and have been imported once (godot --headless --path P --import). The
script restores every file it touched, also on error. It never touches a git
checkout: the addon copy must have no .git entry.
"""
import os, subprocess, sys
GODOT = os.environ.get("GODOT", os.path.expanduser(
    "~/.local/share/godot/app_userdata/Godots/versions/Godot_v4_7-stable_linux_x86_64/Godot_v4.7-stable_linux.x86_64"))
C = "netcode/net_clock.gd"
W = "netcode/replicated_world.gd"
G14 = "netcode/fixtures/run_net_clock.gd"
G15 = "netcode/fixtures/run_replicated_world.gd"
# name: (file, search, replace, gate, case that must fail)
MUTS = {
 "r01-no-grow-slew": (C, "render_delay_milli + step * _policy.render_slew_grow_permille / 1000", "render_target_milli", G14, "R3"),
 "r02-no-shrink-slew": (C, "render_delay_milli - step * _policy.render_slew_shrink_permille / 1000", "render_target_milli", G14, "R3"),
 "r03-no-peak-hold": (C, "\tif need > render_target_milli:\n", "\tif true:\n", G14, "R4"),
 "r04-no-margin": (C, "lag + _policy.render_margin_ticks * 1000", "lag", G14, "R2"),
 "r05-no-cap": (C, "_policy.render_delay_max_ticks * 1000)", "1 << 40)", G14, "R5"),
 "r06-shrink-no-interval": (C, "now_ms - _window_start_ms >= _policy.render_shrink_interval_ms", "true", G14, "R4"),
 "r07-no-hysteresis": (C, " + _policy.render_shrink_hysteresis_ticks * 1000", "", G14, "R4"),
 "r08-no-floor": (C, "_policy.render_delay_ticks * 1000, _policy.render_delay_max_ticks * 1000)", "0, _policy.render_delay_max_ticks * 1000)", G14, "R5"),
 "r09-no-snap-on-resync": (C, "\t_lag_ready = false\n\trender_delay_milli = render_target_milli\n", "\t_lag_ready = false\n", G14, "R6"),
 "r10-no-skip-after-resync": (C, "\t_lag_ready = false\n\trender_delay_milli = render_target_milli\n", "\trender_delay_milli = render_target_milli\n", G14, "R6"),
 "r11-fixed-mode-adapts": (C, "\tif not _policy.render_delay_adaptive:\n\t\treturn\n", "", G14, "R1"),
 "r12-late-counts-ties": (C, "if lag > render_delay_milli:", "if lag >= render_delay_milli:", G14, "R1"),
 "r13-no-late-count": (C, "\t\tlate_snapshots += 1\n", "\t\tpass\n", G14, "R1"),
 "r14-render-uses-target": (C, "var value: int = estimate - render_delay_milli", "var value: int = estimate - render_target_milli", G14, "R3"),
 "r15-never-adapts": (C, "\tif need > render_target_milli:\n\t\trender_target_milli = need\n", "\tif need > render_target_milli:\n\t\tpass\n", G14, "R2"),
 "r16-one-window-decay": (C, "maxi(_prev_peak, _window_peak)", "_window_peak", G14, "R4"),
 "w01-count-only-history": (W, " and int(cur[\"ticks\"][1]) <= ht - history_ticks", "", G15, "W4c"),
 "w02-window-only-history": (W, "cur[\"ticks\"].size() > history_size and ", "cur[\"ticks\"].size() > 1 and ", G15, "W4b"),
}


def run(project, gate):
    r = subprocess.run([GODOT, "--headless", "--path", project, "--script", "res://addons/couch-games-sdk/" + gate],
                       capture_output=True, text=True, timeout=900)
    out = r.stdout + r.stderr
    fails = [l.strip() for l in out.splitlines() if "FAIL:" in l]
    errs = [l.strip() for l in out.splitlines() if "SCRIPT ERROR" in l or "Parse Error" in l]
    return r.returncode, fails, errs


def main():
    project = sys.argv[1]
    addon = os.path.join(project, "addons/couch-games-sdk/")
    assert not os.path.islink(addon.rstrip("/")) and not os.path.exists(os.path.join(addon, ".git")), \
        "the addon in the scratch project must be a plain copy"
    names = sys.argv[2:] or list(MUTS)
    origs = {f: open(addon + f).read() for f in {m[0] for m in MUTS.values()}}
    survivors = []
    try:
        for name in names:
            f, a, b, gate, case = MUTS[name]
            assert origs[f].count(a) == 1, (name, origs[f].count(a))
            open(addon + f, "w").write(origs[f].replace(a, b))
            rc, fails, errs = run(project, gate)
            killed_by_case = any(l.startswith("FAIL: " + case) for l in fails)
            print(f"{name}: rc={rc} fails={len(fails)} errs={len(errs)} {'KILLED by ' + case if killed_by_case else 'SURVIVED (expected ' + case + ')'}", flush=True)
            for x in fails[:4]:
                print("    ", x[:150])
            for x in errs[:2]:
                print("    ERR", x[:150])
            if not killed_by_case:
                survivors.append(name)
            open(addon + f, "w").write(origs[f])
    finally:
        for f, s in origs.items():
            open(addon + f, "w").write(s)
    print("survivors:", survivors or "none")
    return 1 if survivors else 0


if __name__ == "__main__":
    sys.exit(main())
