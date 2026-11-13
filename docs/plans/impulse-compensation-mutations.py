# Mutation runner for G17 (step 1.1, host-side impulse compensation in owner_targets.gd).
# Each mutation is ONE exact string replacement on the final file (asserted unique); G17 and
# G16 are both run on 4.7 for every mutant, and the file is restored in finally. A mutant is
# RED on any FAIL: line, a non-zero exit, or any SCRIPT ERROR / Parse Error line (a typed-bool
# function that hits a runtime error returns false, so error-only kills are listed apart).
import subprocess, sys, os
REPO = "/home/daniel/Repositories/couch-games-sdk-godot/netcode/"
GODOT = os.path.expanduser("~/.local/share/godot/app_userdata/Godots/versions/Godot_v4_7-stable_linux_x86_64/Godot_v4.7-stable_linux.x86_64")
SCRATCH = "/tmp/claude-1000/-home-daniel-Repositories-platform-dev/ed427b9b-3571-41d8-a684-01b80ab50761/scratchpad/godot/g47"
T = "owner_targets.gd"
GATES = {
 "G17": ("res://addons/couch-games-sdk/netcode/fixtures/run_impulse_compensation.gd", "G17 impulse compensation"),
 "G16": ("res://addons/couch-games-sdk/netcode/fixtures/run_owner_authority.gd", "G16 owner authority"),
}
COMP_BLOCK = "\tif impulse_compensation:\n\t\tvar comp := compensation_of(peer_id, now_ms)\n\t\tout[ch.x] += comp[\"pos\"].x\n\t\tout[ch.y] += comp[\"pos\"].y\n\t\tout[ch.vx] += comp[\"vel\"].x\n\t\tout[ch.vy] += comp[\"vel\"].y\n\t\tif ch.has_rotation():\n\t\t\tout[ch.rot] = wrapf(out[ch.rot] + comp[\"rot\"], -PI, PI)\n\t\t\tout[ch.w] += comp[\"w\"]\n"
HELD_BLOCK = "\tif held:\n\t\tout[ch.vx] = 0.0\n\t\tout[ch.vy] = 0.0\n\t\tif ch.has_rotation():\n\t\t\tout[ch.w] = 0.0\n"
COVER_ON_REJECT = "\t\tfor entry in rec[\"impulses\"]:\n\t\t\tif not entry[\"covered\"] and entry[\"id\"] <= int(d.get(\"ev\", 0)):\n\t\t\t\t_hand_off(entry, now_ms)\n\t\trec[\"covered_ev\"] = maxi(rec[\"covered_ev\"], int(d.get(\"ev\", 0)))\n"
PUSH_TAIL = "\t_prune_impulses(peer_id, now_ms)\n\tvar rec: Dictionary = _owners[peer_id]\n\tvar inertia: float = rec[\"inertia\"]\n\trec[\"impulses\"].append({\n\t\t\"id\": id, \"dv\": impulse / float(rec[\"mass\"]),\n\t\t\"dw\": angular / inertia if inertia > 0.0 else 0.0,\n\t\t\"t0\": now_ms, \"covered\": false,\n\t})\n\treturn id\n"
MUTS = {
 # "ev" validation
 "e01-ev-float-ok": (T, "(typeof(d[\"ev\"]) != TYPE_INT or", "(typeof(d[\"ev\"]) != TYPE_INT and typeof(d[\"ev\"]) != TYPE_FLOAT or"),
 "e02-ev-negative-ok": (T, " or int(d[\"ev\"]) < 0):", "):"),
 "e03-ev-null-ok": (T, "if d.has(\"ev\") and (", "if d.get(\"ev\") != null and ("),
 "e04-ev-unchecked": (T, "\tif d.has(\"ev\") and (typeof(d[\"ev\"]) != TYPE_INT or int(d[\"ev\"]) < 0):\n\t\treturn _reject(peer_id, \"bad-shape\")\n", ""),
 "e05-ev-check-after-stride": (T, "\tif d.has(\"ev\") and (typeof(d[\"ev\"]) != TYPE_INT or int(d[\"ev\"]) < 0):\n\t\treturn _reject(peer_id, \"bad-shape\")\n\tvar o: PackedFloat32Array = d[\"o\"]\n\tvar rec: Dictionary = _owners[peer_id]\n\tif o.size() != _world.kind_channels(rec[\"kind\"]).size():\n\t\treturn _reject(peer_id, \"bad-stride\")\n",
   "\tvar o: PackedFloat32Array = d[\"o\"]\n\tvar rec: Dictionary = _owners[peer_id]\n\tif o.size() != _world.kind_channels(rec[\"kind\"]).size():\n\t\treturn _reject(peer_id, \"bad-stride\")\n\tif d.has(\"ev\") and (typeof(d[\"ev\"]) != TYPE_INT or int(d[\"ev\"]) < 0):\n\t\treturn _reject(peer_id, \"bad-shape\")\n"),
 "e06-ev-missing-covers-all": (T, "var ev: int = d.get(\"ev\", 0)", "var ev: int = d.get(\"ev\", 1 << 30)"),
 # cover
 "c01-cover-on-stale-tick": (T, "\tif rec[\"has_tick\"] and t <= rec[\"tick\"]:\n\t\treturn _reject", "\tif rec[\"has_tick\"] and t <= rec[\"tick\"]:\n" + COVER_ON_REJECT + "\t\treturn _reject"),
 "c02-cover-on-non-finite": (T, "\t\tif not is_finite(v):\n\t\t\treturn _reject", "\t\tif not is_finite(v):\n" + "".join("\t" + l for l in COVER_ON_REJECT.splitlines(True)) + "\t\t\treturn _reject"),
 "c03-cover-non-monotone": (T, "if ev > rec[\"covered_ev\"]:", "if ev != rec[\"covered_ev\"]:"),
 "c04-cover-strict-lt": (T, "entry[\"id\"] <= ev:", "entry[\"id\"] < ev:"),
 "c05-cover-guard-ge": (T, "if ev > rec[\"covered_ev\"]:", "if ev >= rec[\"covered_ev\"]:"),
 "c06-cover-tc-t0": (T, "\t\t\t\t_hand_off(entry, now_ms)\n", "\t\t\t\t_hand_off(entry, int(entry[\"t0\"]))\n"),
 "c07-cover-before-prune": (T, "\t_prune_impulses(peer_id, now_ms)\n\tvar ev: int = d.get(\"ev\", 0)\n\tif ev > rec[\"covered_ev\"]:\n\t\trec[\"covered_ev\"] = ev\n\t\tfor entry in rec[\"impulses\"]:\n\t\t\tif not entry[\"covered\"] and entry[\"id\"] <= ev:\n\t\t\t\t_hand_off(entry, now_ms)\n",
   "\tvar ev: int = d.get(\"ev\", 0)\n\tif ev > rec[\"covered_ev\"]:\n\t\trec[\"covered_ev\"] = ev\n\t\tfor entry in rec[\"impulses\"]:\n\t\t\tif not entry[\"covered\"] and entry[\"id\"] <= ev:\n\t\t\t\t_hand_off(entry, now_ms)\n\t_prune_impulses(peer_id, now_ms)\n"),
 "c08-cover-no-covered-ev-update": (T, "\t\trec[\"covered_ev\"] = ev\n", ""),
 "c09-cover-rehands-covered": (T, "if not entry[\"covered\"] and entry[\"id\"] <= ev:", "if entry[\"id\"] <= ev:"),
 # growing lead P / P'
 "f01-P-no-tau": (T, "\"pos\": entry[\"dv\"] * tau * (1.0 - e)", "\"pos\": entry[\"dv\"] * (1.0 - e)"),
 "f02-P-sign": (T, "\"pos\": entry[\"dv\"] * tau * (1.0 - e)", "\"pos\": entry[\"dv\"] * tau * (e - 1.0)"),
 "f03-P-exp-arg": (T, "\tvar e := exp(-s / tau)\n\treturn {\n\t\t\"pos\": entry[\"dv\"]", "\tvar e := exp(-s * tau)\n\treturn {\n\t\t\"pos\": entry[\"dv\"]"),
 "f04-s-ms-not-converted": (T, "var s: float = (now_ms - int(entry[\"t0\"])) / 1000.0", "var s: float = (now_ms - int(entry[\"t0\"]))"),
 "f05-Pdot-no-decay": (T, "\"vel\": entry[\"dv\"] * e,", "\"vel\": entry[\"dv\"],"),
 "f06-rot-no-tau": (T, "\"rot\": entry[\"dw\"] * tau * (1.0 - e)", "\"rot\": entry[\"dw\"] * (1.0 - e)"),
 "f07-w-no-decay": (T, "\"w\": entry[\"dw\"] * e,", "\"w\": entry[\"dw\"],"),
 "f08-no-negative-s-zero": (T, "\tif s < 0.0:\n\t\treturn {\"pos\": Vector2.ZERO, \"vel\": Vector2.ZERO, \"rot\": 0.0, \"w\": 0.0}\n", ""),
 "f09-zero-at-s0": (T, "if s < 0.0:", "if s <= 0.0:"),
 "f10-tau-no-clamp": (T, "return maxi(impulse_tau_ms, 1) / 1000.0", "return impulse_tau_ms / 1000.0"),
 "f11-tau-int-div": (T, "return maxi(impulse_tau_ms, 1) / 1000.0", "return maxi(impulse_tau_ms, 1) / 1000"),
 "f12-tau-clamp-10": (T, "return maxi(impulse_tau_ms, 1) / 1000.0", "return maxi(impulse_tau_ms, 10) / 1000.0"),
 # decaying lead / hand-off
 "d01-dec-vel-sign": (T, "\"vel\": -entry[\"lead\"] / tau * e", "\"vel\": entry[\"lead\"] / tau * e"),
 "d02-dec-vel-no-tau": (T, "\"vel\": -entry[\"lead\"] / tau * e", "\"vel\": -entry[\"lead\"] * e"),
 "d03-dec-w-sign": (T, "\"w\": -entry[\"alead\"] / tau * e", "\"w\": entry[\"alead\"] / tau * e"),
 "d04-dec-no-clamp": (T, "var s: float = maxi(now_ms - int(entry[\"tc\"]), 0) / 1000.0", "var s: float = (now_ms - int(entry[\"tc\"])) / 1000.0"),
 "d05-dec-rot-no-decay": (T, "\"rot\": entry[\"alead\"] * e,", "\"rot\": entry[\"alead\"],"),
 "d06-dec-pos-no-decay": (T, "\"pos\": entry[\"lead\"] * e,", "\"pos\": entry[\"lead\"],"),
 "d07-alead-from-w": (T, "entry[\"alead\"] = at_cover[\"rot\"]", "entry[\"alead\"] = at_cover[\"w\"]"),
 "d08-lead-from-vel": (T, "entry[\"lead\"] = at_cover[\"pos\"]", "entry[\"lead\"] = at_cover[\"vel\"]"),
 "d09-decay-from-t0": (T, "\tentry[\"tc\"] = tc_ms\n", "\tentry[\"tc\"] = entry[\"t0\"]\n"),
 "d10-dec-int-div": (T, "maxi(now_ms - int(entry[\"tc\"]), 0) / 1000.0", "maxi(now_ms - int(entry[\"tc\"]), 0) / 1000"),
 # timeout
 "t01-prune-timeout-inclusive": (T, "if not entry[\"covered\"] and now_ms - int(entry[\"t0\"]) > impulse_timeout_ms:", "if not entry[\"covered\"] and now_ms - int(entry[\"t0\"]) >= impulse_timeout_ms:"),
 "t02-comp-timeout-inclusive": (T, "elif now_ms - int(entry[\"t0\"]) > impulse_timeout_ms:", "elif now_ms - int(entry[\"t0\"]) >= impulse_timeout_ms:"),
 "t03-prune-timeout-tc-now": (T, "\t\t\t_hand_off(entry, int(entry[\"t0\"]) + impulse_timeout_ms)\n", "\t\t\t_hand_off(entry, now_ms)\n"),
 "t04-comp-timeout-tc-now": (T, "_hand_off(handed, int(entry[\"t0\"]) + impulse_timeout_ms)", "_hand_off(handed, now_ms)"),
 "t05-timeout-not-counted": (T, "\t\t\t_counter(peer_id)[\"timeouts\"] += 1\n", ""),
 "t06-timeout-counted-each-prune": (T, "\t\tif entry[\"covered\"] and now_ms - int(entry[\"tc\"]) > 8.0", "\t\tif entry[\"covered\"] and now_ms - int(entry[\"t0\"]) > impulse_timeout_ms:\n\t\t\t_counter(peer_id)[\"timeouts\"] += 1\n\t\tif entry[\"covered\"] and now_ms - int(entry[\"tc\"]) > 8.0"),
 "t07-timeout-counted-in-comp-of": (T, "\t\t\t_hand_off(handed, int(entry[\"t0\"]) + impulse_timeout_ms)\n", "\t\t\t_hand_off(handed, int(entry[\"t0\"]) + impulse_timeout_ms)\n\t\t\t_counter(peer_id)[\"timeouts\"] += 1\n"),
 "t08-comp-of-ignores-timeout": (T, "elif now_ms - int(entry[\"t0\"]) > impulse_timeout_ms:", "elif false:"),
 "t09-comp-of-mutates-entry": (T, "var handed: Dictionary = entry.duplicate()", "var handed: Dictionary = entry"),
 "t10-prune-ignores-timeout": (T, "if not entry[\"covered\"] and now_ms - int(entry[\"t0\"]) > impulse_timeout_ms:", "if false:"),
 "t11-timeout-lead-at-now": (T, "\t\t\t_hand_off(entry, int(entry[\"t0\"]) + impulse_timeout_ms)\n\t\t\t_counter", "\t\t\tvar keep_tc: int = int(entry[\"t0\"]) + impulse_timeout_ms\n\t\t\t_hand_off(entry, now_ms)\n\t\t\tentry[\"tc\"] = keep_tc\n\t\t\t_counter"),
 # prune
 "p01-drop-inclusive": (T, "> 8.0 * _tau() * 1000.0", ">= 8.0 * _tau() * 1000.0"),
 "p02-drop-4-tau": (T, "> 8.0 * _tau() * 1000.0", "> 4.0 * _tau() * 1000.0"),
 "p03-drop-from-t0": (T, "now_ms - int(entry[\"tc\"]) > 8.0", "now_ms - int(entry[\"t0\"]) > 8.0"),
 "p04-never-drop": (T, "\t\t\tcontinue\n", "\t\t\tpass\n"),
 "p05-push-no-prune": (T, "\t_prune_impulses(peer_id, now_ms)\n\tvar rec: Dictionary = _owners[peer_id]\n\tvar inertia", "\tvar rec: Dictionary = _owners[peer_id]\n\tvar inertia"),
 "p06-push-prune-after-record": (T, PUSH_TAIL, PUSH_TAIL.replace("\t_prune_impulses(peer_id, now_ms)\n", "", 1).replace("\treturn id\n", "\t_prune_impulses(peer_id, now_ms)\n\treturn id\n")),
 "p07-note-no-prune": (T, "\t_prune_impulses(peer_id, now_ms)\n\tvar ev: int", "\tvar ev: int"),
 "p08-prune-on-rejected-input": (T, "\t\treturn _reject(peer_id, \"unowned\")\n\tif typeof(body) != TYPE_DICTIONARY:", "\t\treturn _reject(peer_id, \"unowned\")\n\t_prune_impulses(peer_id, now_ms)\n\tif typeof(body) != TYPE_DICTIONARY:"),
 "p09-push-prune-on-minus1": (T, "\t\treturn -1\n\tif not is_finite(impulse.x)", "\t\treturn -1\n\t_prune_impulses(peer_id, now_ms)\n\tif not is_finite(impulse.x)"),
 "p10-push-records-on-minus1": (T, "\tif id < 1:\n\t\treturn id\n", ""),
 # push record
 "r01-dv-not-divided": (T, "\"dv\": impulse / float(rec[\"mass\"])", "\"dv\": impulse"),
 "r02-dw-inertia0-divides": (T, "\"dw\": angular / inertia if inertia > 0.0 else 0.0", "\"dw\": angular / inertia"),
 "r03-dw-uses-mass": (T, "\"dw\": angular / inertia if", "\"dw\": angular / float(rec[\"mass\"]) if"),
 "r04-t0-host-tick": (T, "\"t0\": now_ms,", "\"t0\": host_tick,"),
 "r05-records-only-when-on": (T, "if id < 1:", "if id < 1 or not impulse_compensation:"),
 "r06-dv-swapped": (T, "\"dv\": impulse / float(rec[\"mass\"])", "\"dv\": Vector2(impulse.y, impulse.x) / float(rec[\"mass\"])"),
 # target_for
 "g01-kill-switch-ignored": (T, "\tif impulse_compensation:\n", "\tif true:\n"),
 "g02-kill-switch-inverted": (T, "\tif impulse_compensation:\n", "\tif not impulse_compensation:\n"),
 "g03-angular-without-rot-channels": (T, "\t\tif ch.has_rotation():\n\t\t\tout[ch.rot] = wrapf(out[ch.rot] + comp[\"rot\"], -PI, PI)\n\t\t\tout[ch.w] += comp[\"w\"]\n", "\t\tout[ch.rot] = wrapf(out[ch.rot] + comp[\"rot\"], -PI, PI)\n\t\tout[ch.w] += comp[\"w\"]\n"),
 "g04-rot-not-wrapped": (T, "out[ch.rot] = wrapf(out[ch.rot] + comp[\"rot\"], -PI, PI)", "out[ch.rot] = out[ch.rot] + comp[\"rot\"]"),
 "g05-vel-not-added": (T, "\t\tout[ch.vx] += comp[\"vel\"].x\n\t\tout[ch.vy] += comp[\"vel\"].y\n", ""),
 "g06-vel-swapped": (T, "\t\tout[ch.vx] += comp[\"vel\"].x\n\t\tout[ch.vy] += comp[\"vel\"].y\n", "\t\tout[ch.vx] += comp[\"vel\"].y\n\t\tout[ch.vy] += comp[\"vel\"].x\n"),
 "g07-w-not-added": (T, "\t\t\tout[ch.w] += comp[\"w\"]\n", ""),
 "g08-held-skips-comp": (T, "\tif impulse_compensation:\n", "\tif impulse_compensation and not held:\n"),
 "g09-stale-skips-comp": (T, "\tif impulse_compensation:\n", "\tif impulse_compensation and not is_stale(peer_id, now_ms):\n"),
 "g10-pos-y-from-x": (T, "out[ch.y] += comp[\"pos\"].y", "out[ch.y] += comp[\"pos\"].x"),
 "g11-held-zeroes-comp-vel": (T, HELD_BLOCK + COMP_BLOCK, COMP_BLOCK + HELD_BLOCK),
 "g12-rot-not-added": (T, "out[ch.rot] = wrapf(out[ch.rot] + comp[\"rot\"], -PI, PI)", "out[ch.rot] = wrapf(out[ch.rot], -PI, PI)"),
 "g13-empty-report-compensated": (T, "\tif report.is_empty():\n\t\treturn PackedFloat32Array()\n\tif is_stale", "\tif report.is_empty() and not impulse_compensation:\n\t\treturn PackedFloat32Array()\n\tif is_stale"),
 # lifecycle
 "l01-set-owner-keeps-entries": (T, "\"covered_ev\": 0, \"impulses\": [],", "\"covered_ev\": _owners[peer_id][\"covered_ev\"] if _owners.has(peer_id) else 0, \"impulses\": _owners[peer_id][\"impulses\"] if _owners.has(peer_id) else [],"),
 "l02-set-owner-keeps-covered-ev": (T, "\"covered_ev\": 0, \"impulses\": [],", "\"covered_ev\": _owners[peer_id][\"covered_ev\"] if _owners.has(peer_id) else 0, \"impulses\": [],"),
 "l03-set-owner-keeps-impulses": (T, "\"covered_ev\": 0, \"impulses\": [],", "\"covered_ev\": 0, \"impulses\": _owners[peer_id][\"impulses\"] if _owners.has(peer_id) else [],"),
 "l04-set-owner-clears-timeouts": (T, "\t_owners[peer_id] = {\n", "\tif _counters.has(peer_id):\n\t\t_counters[peer_id][\"timeouts\"] = 0\n\t_owners[peer_id] = {\n"),
 "l05-forget-keeps-timeouts": (T, "\t_owners.erase(peer_id)\n\t_counters.erase(peer_id)\n", "\t_owners.erase(peer_id)\n\tif _counters.has(peer_id):\n\t\tvar keep: int = _counters[peer_id][\"timeouts\"]\n\t\t_counters.erase(peer_id)\n\t\t_counter(peer_id)[\"timeouts\"] = keep\n"),
}


def run(script):
    r = subprocess.run([GODOT, "--headless", "--path", SCRATCH, "--script", script], capture_output=True, text=True, timeout=600)
    lines = (r.stdout + r.stderr).splitlines()
    return (r.returncode,
            [l.strip() for l in lines if "FAIL:" in l],
            [l.strip() for l in lines if "SCRIPT ERROR" in l or "Parse Error" in l],
            [l.strip() for l in lines if any(s in l for _, s in GATES.values())])


names = sys.argv[1:] or list(MUTS)
orig = open(REPO + T).read()
try:
    for name in names:
        f, a, b = MUTS[name]
        assert orig.count(a) == 1, (name, orig.count(a))
        assert a != b, name
    for name in names:
        f, a, b = MUTS[name]
        open(REPO + f, "w").write(orig.replace(a, b))
        parts, red = [], False
        detail = []
        for g, (script, _) in GATES.items():
            rc, fails, errs, summ = run(script)
            if rc != 0 or fails or errs:
                red = True
            kind = "FAIL" if fails else ("ERR" if errs else ("rc" if rc != 0 else "-"))
            parts.append(f"{g}:{kind} rc={rc} f={len(fails)} e={len(errs)} {summ[-1] if summ else 'NO-SUMMARY'}")
            detail += [f"    {g} " + x[:200] for x in fails[:2]] + [f"    {g} ERR " + x[:200] for x in errs[:2]]
        print(f"{'RED' if red else 'GREEN':5} {name}: " + " | ".join(parts), flush=True)
        for x in detail:
            print(x, flush=True)
        open(REPO + f, "w").write(orig)
finally:
    open(REPO + T, "w").write(orig)
