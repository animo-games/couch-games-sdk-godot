# Mutation runner for G16 (step 1). Each mutation is ONE exact string replacement on the
# final file (asserted unique), the gate is run on 4.7, and the file is restored in finally.
import subprocess, sys, os
REPO = "/home/daniel/Repositories/couch-games-sdk-godot/netcode/"
GODOT = os.path.expanduser("~/.local/share/godot/app_userdata/Godots/versions/Godot_v4_7-stable_linux_x86_64/Godot_v4.7-stable_linux.x86_64")
SCRATCH = "/tmp/claude-1000/-home-daniel-Repositories-platform-dev/f3272ea4-a69a-4026-996d-c5614c94e55f/scratchpad/godot/g47"
B = "body_channels.gd"; F = "pd_follower.gd"; T = "owner_targets.gd"; O = "owned_entity.gd"; W = "replicated_world.gd"
MUTS = {
 # CouchBodyChannels
 "b01-extra-key-ok": (B, "\t\tif not (key in _REQUIRED or key in _OPTIONAL):\n\t\t\treturn false\n", ""),
 "b02-rot-without-w": (B, "\tif map.has(\"rot\") != map.has(\"w\"):\n\t\treturn false\n", ""),
 "b03-dup-index-ok": (B, " or seen.has(v):", ":"),
 "b04-negative-ok": (B, "typeof(v) != TYPE_INT or v < 0 or", "typeof(v) != TYPE_INT or"),
 "b05-float-ok": (B, "typeof(v) != TYPE_INT or v < 0", "(typeof(v) != TYPE_INT and typeof(v) != TYPE_FLOAT) or v < 0"),
 "b06-fits-no-range": (B, "\t\tif i >= kind_channels.size():\n\t\t\treturn false\n", "\t\tpass\n"),
 "b07-fits-w-not-lerp": (B, "for i in [x, y, vx, vy, w]:", "for i in [x, y, vx, vy]:"),
 "b08-fits-no-angle": (B, "if rot >= 0 and kind_channels[rot] != CouchReplicatedWorld.ANGLE:", "if false:"),
 "b09-partial-on-invalid": (B, "\tif not _map_is_valid(map):\n\t\treturn\n\tx = map[\"x\"]", "\tx = map[\"x\"] if map.has(\"x\") else -1\n\tif not _map_is_valid(map):\n\t\treturn\n\tx = map[\"x\"]"),
 # CouchPDFollower
 "f01-no-ff": (F, "w * w * ep + 2.0 * w * dv", "w * w * ep + 2.0 * w * (-Vector2(current[c.vx], current[c.vy]))"),
 "f02-no-damping": (F, "w * w * ep + 2.0 * w * dv", "w * w * ep"),
 "f03-underdamped": (F, "w * w * ep + 2.0 * w * dv", "w * w * ep + 1.0 * w * dv"),
 "f04-no-clamp": (F, "return minf(CouchPDFollowerPolicy.SETTLE_K / settle_s, CouchPDFollowerPolicy.MAX_W_DT / _dt)", "return CouchPDFollowerPolicy.SETTLE_K / settle_s"),
 "f05-no-settle-floor": (F, "maxf(settle_ms, 1.0) / 1000.0", "maxf(settle_ms, 0.001) / 1000.0"),
 "f06-dt-fallback": (F, "else 1.0 / 60.0", "else 1.0 / 30.0"),
 "f07-snap-inclusive": (F, "ep.length() > _policy.snap_distance", "ep.length() >= _policy.snap_distance"),
 "f08-angle-snap-inclusive": (F, "absf(er) > _policy.snap_angle", "absf(er) >= _policy.snap_angle"),
 "f09-long-arc": (F, "er = wrapf(target[c.rot] - current[c.rot], -PI, PI)", "er = target[c.rot] - current[c.rot]"),
 "f10-snap-alias": (F, "\"state\": target.duplicate(),", "\"state\": target,"),
 "f11-no-size-check": (F, "current.size() != target.size() or not _usable", "not _usable"),
 "f12-no-finite-check": (F, " or not is_finite(state[i]):", ":"),
 "f13-empty-counts": (F, "\tif target.is_empty():\n\t\treturn zero\n", "\tif target.is_empty():\n\t\tbad_input_count += 1\n\t\treturn zero\n"),
 "f14-rot-uses-pos-omega": (F, "var wr := rot_omega()", "var wr := omega()"),
 "f15-alpha-no-ff": (F, "2.0 * wr * (target[c.w] - current[c.w])", "2.0 * wr * (-current[c.w])"),
 "f16-policy-cached": (F, "\t_policy = policy\n", "\t_policy = policy.duplicate()\n"),
 "f17-force-no-snap-zero": (F, "\tif result[\"snap\"]:\n\t\treturn {\"force\": Vector2.ZERO, \"torque\": 0.0}\n", ""),
 "f18-vel-after-snap-integrates": (F, "\tif result[\"snap\"]:\n\t\treturn {\"linear\": result[\"vel\"], \"angular\": result[\"w\"]}\n", ""),
 "f19-negative-index-ok": (F, "if i < 0 or i >= state.size()", "if i >= state.size()"),
 # CouchOwnerTargets
 "t01-unowned-after-shape": (T, "\tif not _owners.has(peer_id):\n\t\treturn _reject(peer_id, \"unowned\")\n\tif typeof(body) != TYPE_DICTIONARY:\n\t\treturn _reject(peer_id, \"bad-shape\")\n", "\tif typeof(body) != TYPE_DICTIONARY:\n\t\treturn _reject(peer_id, \"bad-shape\")\n\tif not _owners.has(peer_id):\n\t\treturn _reject(peer_id, \"unowned\")\n"),
 "t02-float-t-ok": (T, "typeof(d.get(\"t\")) != TYPE_INT or", "(typeof(d.get(\"t\")) != TYPE_INT and typeof(d.get(\"t\")) != TYPE_FLOAT) or"),
 "t03-array-o-ok": (T, "typeof(d.get(\"o\")) != TYPE_PACKED_FLOAT32_ARRAY", "not (typeof(d.get(\"o\")) in [TYPE_PACKED_FLOAT32_ARRAY, TYPE_ARRAY])"),
 "t04-no-stride": (T, "\tif o.size() != _world.kind_channels(rec[\"kind\"]).size():\n\t\treturn _reject(peer_id, \"bad-stride\")\n", ""),
 "t05-no-finite": (T, "\t\tif not is_finite(v):\n\t\t\treturn _reject(peer_id, \"non-finite\")\n", "\t\tpass\n"),
 "t06-tick-before-finite": (T, "\tfor v in o:\n\t\tif not is_finite(v):\n\t\t\treturn _reject(peer_id, \"non-finite\")\n\tvar t: int = d[\"t\"]\n\tif rec[\"has_tick\"] and t <= rec[\"tick\"]:\n\t\treturn _reject(peer_id, \"stale-tick\")\n", "\tvar t: int = d[\"t\"]\n\tif rec[\"has_tick\"] and t <= rec[\"tick\"]:\n\t\treturn _reject(peer_id, \"stale-tick\")\n\tfor v in o:\n\t\tif not is_finite(v):\n\t\t\treturn _reject(peer_id, \"non-finite\")\n"),
 "t07-dup-tick-ok": (T, "t <= rec[\"tick\"]", "t < rec[\"tick\"]"),
 "t08-tick-sentinel": (T, "if rec[\"has_tick\"] and t <= rec[\"tick\"]:", "if t <= rec[\"tick\"]:"),
 "t09-report-alias": (T, "rec[\"report\"] = o.duplicate()", "rec[\"report\"] = o"),
 "t10-gap-inclusive": (T, "if now_ms - _last_heard_ms(rec) > stale_ms:", "if now_ms - _last_heard_ms(rec) >= stale_ms:"),
 "t11-gap-after-update": (T, "\tif now_ms - _last_heard_ms(rec) > stale_ms:\n\t\tc[\"stale_gaps\"] += 1\n\trec[\"report\"] = o.duplicate()\n\trec[\"report_ms\"] = now_ms\n", "\trec[\"report\"] = o.duplicate()\n\trec[\"report_ms\"] = now_ms\n\tif now_ms - _last_heard_ms(rec) > stale_ms:\n\t\tc[\"stale_gaps\"] += 1\n"),
 "t12-stale-clock-not-owner": (T, "return rec[\"owner_ms\"] if", "return 0 if"),
 "t13-stale-inclusive": (T, "return now_ms - _last_heard_ms(_owners[peer_id]) > stale_ms", "return now_ms - _last_heard_ms(_owners[peer_id]) >= stale_ms"),
 "t14-no-age-clamp": (T, "var age: int = maxi(now_ms - int(rec[\"report_ms\"]), 0)", "var age: int = now_ms - int(rec[\"report_ms\"])"),
 "t15-cap-inclusive": (T, "var held: bool = age > extrapolate_cap_ms", "var held: bool = age >= extrapolate_cap_ms"),
 "t16-no-cap-age": (T, "\tif held:\n\t\tage = extrapolate_cap_ms\n", ""),
 "t17-held-keeps-vel": (T, "\t\tout[ch.vx] = 0.0\n\t\tout[ch.vy] = 0.0\n", ""),
 "t18-held-keeps-w": (T, "\t\tif ch.has_rotation():\n\t\t\tout[ch.w] = 0.0\n", ""),
 "t19-rot-unwrapped": (T, "out[ch.rot] = wrapf(report[ch.rot] + report[ch.w] * secs, -PI, PI)", "out[ch.rot] = report[ch.rot] + report[ch.w] * secs"),
 "t20-no-rot-extrap": (T, "out[ch.rot] = wrapf(report[ch.rot] + report[ch.w] * secs, -PI, PI)", "out[ch.rot] = report[ch.rot]"),
 "t21-report-only-ignored": (T, "if is_stale(peer_id, now_ms) and stale_mode == REPORT_ONLY:", "if false:"),
 "t22-target-alias": (T, "var out: PackedFloat32Array = report.duplicate()", "var out: PackedFloat32Array = report"),
 "t23-set-owner-no-steal-check": (T, "\t\tif other != peer_id and _owners[other][\"entity\"] == entity_id:\n\t\t\treturn false\n", "\t\tpass\n"),
 "t24-set-owner-self-steal": (T, "if other != peer_id and _owners[other]", "if _owners[other]"),
 "t25-mass-zero-ok": (T, "mass <= 0.0", "mass < 0.0"),
 "t26-inertia-zero-refused": (T, "inertia < 0.0", "inertia <= 0.0"),
 "t27-entity-range-low": (T, "entity_id < 0 or", "entity_id < -1 or"),
 "t28-forget-keeps-counters": (T, "\t_owners.erase(peer_id)\n\t_counters.erase(peer_id)\n", "\t_owners.erase(peer_id)\n"),
 "t29-reset-keeps-counters": (T, "\t_owners.clear()\n\t_counters.clear()\n", "\t_owners.clear()\n"),
 "t30-reset-drops-channels": (T, "\t_owners.clear()\n\t_counters.clear()\n", "\t_owners.clear()\n\t_counters.clear()\n\t_channels.clear()\n"),
 "t31-set-channels-no-fit": (T, "if channels == null or not channels.fits(_world.kind_channels(kind)):", "if channels == null:"),
 "t32-impulse-kind-0": (T, "return ring.push(peer_id, CouchOwnedEntity.IMPULSE_EVENT_KIND, payload, host_tick)", "return ring.push(peer_id, 0, payload, host_tick)"),
 "t33-impulse-no-owner-check": (T, "\tif not _owners.has(peer_id):\n\t\treturn -1\n\tif not is_finite(impulse.x)", "\tif not is_finite(impulse.x)"),
 "t34-impulse-no-finite": (T, "\tif not is_finite(impulse.x) or not is_finite(impulse.y) or not is_finite(angular):\n\t\treturn -1\n", ""),
 "t35-impulse-swap": (T, "PackedFloat32Array([impulse.x, impulse.y, angular])", "PackedFloat32Array([impulse.y, impulse.x, angular])"),
 "t36-reset-owner-keeps-tick": (T, "\"owner_ms\": now_ms, \"has_tick\": false, \"tick\": 0,", "\"owner_ms\": now_ms, \"has_tick\": _owners.has(peer_id), \"tick\": _owners[peer_id][\"tick\"] if _owners.has(peer_id) else 0,"),
 # CouchOwnedEntity
 "o01-o-alias": (O, "\"o\": state.duplicate(),", "\"o\": state,"),
 "o02-ev-zero": (O, "\"ev\": inbox.last_applied() if inbox != null else 0,", "\"ev\": 0,"),
 "o03-no-stride": (O, "state.size() != stride or ", ""),
 "o09-unregistered-empty-ok": (O, "if stride == 0 or state", "if state"),
 "o04-no-finite": (O, " or not _all_finite(state):", ":"),
 "o05-impulse-any-kind": (O, "\tif typeof(e[1]) != TYPE_INT or e[1] != IMPULSE_EVENT_KIND:\n\t\treturn {}\n", ""),
 "o06-impulse-any-size": (O, "if p.size() != 3 or not _all_finite(p):", "if p.size() < 3 or not _all_finite(p):"),
 "o07-impulse-nonfinite-ok": (O, "if p.size() != 3 or not _all_finite(p):", "if p.size() != 3:"),
 "o08-no-refused-count": (O, "\t\trefused_count += 1\n", ""),
 # CouchReplicatedWorld.kind_channels
 "w01-kind-channels-alias": (W, "return (_kinds[kind] as Array).duplicate()", "return _kinds[kind]"),
}
def run():
    r = subprocess.run([GODOT, "--headless", "--path", SCRATCH, "--script", "res://addons/couch-games-sdk/netcode/fixtures/run_owner_authority.gd"], capture_output=True, text=True, timeout=600)
    out = r.stdout + r.stderr
    lines = out.splitlines()
    return r.returncode, [l.strip() for l in lines if "FAIL:" in l], [l.strip() for l in lines if "SCRIPT ERROR" in l or "Parse Error" in l], [l for l in lines if "G16 owner authority" in l]
names = sys.argv[1:] or list(MUTS)
files = sorted({f for f, _, _ in MUTS.values()})
origs = {f: open(REPO + f).read() for f in files}
try:
    for name in names:
        f, a, b = MUTS[name]
        assert origs[f].count(a) == 1, (name, origs[f].count(a))
    for name in names:
        f, a, b = MUTS[name]
        open(REPO + f, "w").write(origs[f].replace(a, b))
        rc, fails, errs, summ = run()
        verdict = "RED" if rc != 0 or fails or errs else "GREEN"
        print(f"{verdict:5} {name}: rc={rc} fails={len(fails)} errs={len(errs)} {summ}", flush=True)
        for x in fails[:3]: print("    ", x[:170])
        for x in errs[:2]: print("    ERR", x[:170])
        open(REPO + f, "w").write(origs[f])
finally:
    for f, s in origs.items(): open(REPO + f, "w").write(s)
