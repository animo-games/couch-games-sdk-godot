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
G18 = "netcode/fixtures/run_prop_authority.gd"
# name: (file, search, replace, gate, case that must fail)
MUTS = {
 "h01-held-claim-grants": (H, "\t\tif rec[\"owner\"] == \"\":\n\t\t\tif targets.set_owner", "\t\tif true:\n\t\t\tif targets.set_owner", G18, "A2"),
 "h02-grant-rejected-report": (H, "and targets.note_input(peer_id, claims[eid], now_ms):", "and (targets.note_input(peer_id, claims[eid], now_ms) or true):", G18, "A2"),
 "h03-no-host-hold": (H, "\t\t\trec[\"owner\"] = _host_id\n", "\t\t\tpass\n", G18, "A3"),
 "h04-let-go-strict": (H, "now_ms - int(rec[\"host_ms\"]) >= release_idle_ms:", "now_ms - int(rec[\"host_ms\"]) > release_idle_ms:", G18, "A3"),
 # The host has no body state, so "waits for the prop to settle" is an extra settle wait.
 "h05-let-go-settle-wait": (H, "now_ms - int(rec[\"host_ms\"]) >= release_idle_ms:", "now_ms - int(rec[\"host_ms\"]) >= release_idle_ms + 200:", G18, "A3"),
 "h06-no-per-eid-release": (H, "and not claims.has(eid):", "and claims.is_empty():", G18, "A4"),
 "h07-no-stale-takeback": (H, "and (rec[\"targets\"] as CouchOwnerTargets).is_stale(rec[\"owner\"], now_ms):", "and false:", G18, "A5"),
 "h08-forget-keeps-owner": (H, "\t\t\ttakebacks += 1\n\t\t\t_free(rec)\n", "\t\t\ttakebacks += 1\n", G18, "A5"),
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
