"""Mutation check for prop authority (docs/plans/prop-authority-design.md, "Mutation
script"). Each mutant is one exact search/replace in a COPY of the addon inside a
scratch Godot project; the named G18 case must fail.

  python3 prop-authority-mutations.py <scratch project> [mutant ...]

The project must contain addons/couch-games-sdk as a plain copy (not a symlink or
worktree) and have been imported once (godot --headless --path P --import). The
script restores every file it touched, also on error. It never touches a git
checkout: the addon copy must have no .git entry. A mutant is KILLED only if a line
starts with "FAIL: <case>"; rc and SCRIPT ERROR / Parse Error lines are printed too.
"""
import os, subprocess, sys
GODOT = os.environ.get("GODOT", os.path.expanduser(
    "~/.local/share/godot/app_userdata/Godots/versions/Godot_v4_7-stable_linux_x86_64/Godot_v4.7-stable_linux.x86_64"))
H = "netcode/prop_authority.gd"
P = "netcode/prop_controller.gd"
G18 = "netcode/fixtures/run_prop_authority.gd"
# name: (file, search, replace, gate, case that must fail)
MUTS = {
 "h01-held-claim-grants": (H, "\t\tif rec[\"owner\"] == \"\":\n\t\t\tif targets.set_owner", "\t\tif true:\n\t\t\tif targets.set_owner", G18, "A2"),
 "h02-grant-rejected-report": (H, "and targets.note_input(peer_id, claims[eid], now_ms):", "and (targets.note_input(peer_id, claims[eid], now_ms) or true):", G18, "A2"),
 "h03-no-host-hold": (H, "\t\t\trec[\"owner\"] = _host_id\n", "\t\t\tpass\n", G18, "A3"),
 "h04-let-go-strict": (H, "now_ms - int(rec[\"host_ms\"]) >= release_idle_ms:", "now_ms - int(rec[\"host_ms\"]) > release_idle_ms:", G18, "A3"),
 # The host has no body state, so "waits for the prop to settle" is an extra settle wait.
 "h05-let-go-settle-wait": (H, "now_ms - int(rec[\"host_ms\"]) >= release_idle_ms:", "now_ms - int(rec[\"host_ms\"]) >= release_idle_ms + 200:", G18, "A3"),
 "h06-no-per-eid-release": (H, "\t\tif claims.has(eid):\n", "\t\tif not claims.is_empty():\n", G18, "A4"),
 "h07-no-stale-takeback": (H, "and (rec[\"targets\"] as CouchOwnerTargets).is_stale(rec[\"owner\"], now_ms):", "and false:", G18, "A5"),
 "h08-forget-keeps-owner": (H, "\t\t\t_take_back(rec)\n", "\t\t\ttakebacks += 1\n", G18, "A5"),
 "h09-guest-held-applies": (H, "\t\trec[\"sum\"] += press\n\t\treturn false\n", "\t\trec[\"sum\"] += press\n\t\treturn true\n", G18, "A6"),
 "h10-sum-to-new-owner": (H, " and rec[\"sum_for\"] == owner:", ":", G18, "A6"),
 "h11-presses-first": (H,
    "\t_release_unclaimed(peer_id, claims)\n\t_grant_claims(peer_id, claims, now_ms)\n\treturn _route_presses(body.get(INPUT_PRESSES))\n",
    "\tvar routed := _route_presses(body.get(INPUT_PRESSES))\n\t_release_unclaimed(peer_id, claims)\n\t_grant_claims(peer_id, claims, now_ms)\n\treturn routed\n",
    G18, "A6"),
 "h12-no-press-size-check": (H, " or (field as PackedFloat32Array).size() != 3:", ":", G18, "A6"),
 "h13-shared-targets": (H, "\tvar targets := CouchOwnerTargets.new(_world)\n",
    "\tvar targets: CouchOwnerTargets = _props.values()[0][\"targets\"] if not _props.is_empty() else CouchOwnerTargets.new(_world)\n",
    G18, "A7"),
 # Owner side (CouchPropController, slice A2).
 "o01-claim-not-extrapolated": (P, "\tvar age := clampf((tick - int(latest[\"tick\"])) * _dt, 0.0, extrapolate_cap_ms / 1000.0)\n", "\tvar age := 0.0\n", G18, "O1"),
 "o02-extrapolation-uncapped": (P, "0.0, extrapolate_cap_ms / 1000.0)", "0.0, INF)", G18, "O1"),
 "o03-mine-not-claimable": (P, "(owner == \"\" or owner == _my_id)", "owner == \"\"", G18, "O1"),
 "o04-backoff-ignored": (P, " and now_ms >= int(rec[\"backoff_ms\"]):", ":", G18, "O1"),
 "o05-early-grant": (P, "if owner == _my_id and now_ms - int(rec[\"claim_ms\"]) >= int(rtt_ms):", "if owner == _my_id:", G18, "O2"),
 "o06-unanswered-no-grace": (P, " + _snapshot_ms + claim_grace_ms:", " + _snapshot_ms:", G18, "O2"),
 "o07-no-taken-back": (P, "elif rec[\"granted\"] and owner == \"\":", "elif false:", G18, "O2"),
 "o08-settled-no-match": (P, "and Vector2(copy[ch.x], copy[ch.y]).distance_to(rec[\"sample_pos\"]) < release_match", "and true", G18, "O3"),
 "o09-settled-press-queued": (P, "and int(rec[\"ticks_left\"]) == 0:", "and true:", G18, "O3"),
 "o10-settled-no-speed": (P, "and Vector2(copy[ch.vx], copy[ch.vy]).length() < settle_speed", "and true", G18, "O3"),
 "o11-press-one-lump": (P, "rec[\"ticks_left\"] = snapshot_ticks", "rec[\"ticks_left\"] = 1", G18, "O4"),
 "o12-press-when-not-predicting": (P, "if rec[\"owner\"] != _my_id or not rec[\"predicting\"]:", "if rec[\"owner\"] != _my_id:", G18, "O4"),
 "o13-release-keeps-queue": (P, "\trec[\"left\"] = Vector3.ZERO\n\trec[\"ticks_left\"] = 0\n", "", G18, "O4"),
 "o14-report-not-predicted": (P, "if _props[eid][\"predicting\"] and typeof(copies.get(eid))", "if typeof(copies.get(eid))", G18, "O5"),
 "o15-press-on-predicted": (P, "\t\telif not _props[eid][\"predicting\"] and typeof(presses.get(eid))", "\t\tif typeof(presses.get(eid))", G18, "O5"),
 "o16-no-release-blend": (P, "\trec[\"blend_ms\"] = now_ms\n", "\trec[\"blend_ms\"] = -1\n", G18, "O6"),
 # Slice D (item 5): refusal after a take-back or forget.
 "d01-no-refusal": (H, "\t(rec[\"refused\"] as Dictionary)[rec[\"owner\"]] = true\n", "\tpass\n", G18, "D1"),
 "d02-refusal-never-cleared": (H, "\t\t(rec[\"refused\"] as Dictionary).erase(peer_id)\n", "\t\tpass\n", G18, "D1"),
 "d03-refusal-blocks-every-prop": (H,
    "\t\tif (rec[\"refused\"] as Dictionary).has(peer_id):\n\t\t\trefused_claims += 1\n\t\t\tcontinue\n",
    "\t\tvar refused_anywhere := false\n\t\tfor other in _props.values():\n\t\t\trefused_anywhere = refused_anywhere or (other[\"refused\"] as Dictionary).has(peer_id)\n\t\tif refused_anywhere:\n\t\t\trefused_claims += 1\n\t\t\tcontinue\n",
    G18, "D1"),
 "d04-cleared-by-any-input": (H,
    "\t\tif claims.has(eid):\n\t\t\tcontinue\n\t\t(rec[\"refused\"] as Dictionary).erase(peer_id)\n",
    "\t\t(rec[\"refused\"] as Dictionary).erase(peer_id)\n\t\tif claims.has(eid):\n\t\t\tcontinue\n",
    G18, "D1"),
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
    for name in names:
        f, a, _, _, _ = MUTS[name]
        assert origs[f].count(a) == 1, (name, origs[f].count(a))
    survivors = []
    try:
        for name in names:
            f, a, b, gate, case = MUTS[name]
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
