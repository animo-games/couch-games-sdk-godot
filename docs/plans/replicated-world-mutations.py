# Mutation runner for G15 (step 0d). Each mutation is ONE exact string replacement on the
# final file (asserted unique), the gate is run on 4.7, and the file is restored in finally.
import subprocess, sys, os
REPO = "/home/daniel/Repositories/couch-games-sdk-godot/netcode/"
GODOT = os.path.expanduser("~/.local/share/godot/app_userdata/Godots/versions/Godot_v4_7-stable_linux_x86_64/Godot_v4.7-stable_linux.x86_64")
SCRATCH = "/tmp/claude-1000/-home-daniel-Repositories-platform-dev/f65e30c1-3df1-4822-9e7e-603b6ab3f449/scratchpad/godot/g47"
W = "replicated_world.gd"; R = "event_ring.gd"; I = "event_inbox.gd"
MUTS = {
 "w01-hash-unsorted": (W, "\torder.sort()\n\tvar h: int = _FNV_BASIS", "\tvar h: int = _FNV_BASIS"),
 "w02-hash-no-count": (W, "var seq: Array = [kind, channels.size()]", "var seq: Array = [kind]"),
 "w03-set-alias": (W, "\"state\": state.duplicate()}", "\"state\": state}"),
 "w04-pack-unsorted": (W, "\torder.sort()\n\tvar ids", "\tvar ids"),
 "w05-pack-no-expire": (W, "\t\tring.expire(host_tick)\n", "\t\tpass\n"),
 "w07-x-always": (W, "if not extra.is_empty():\n\t\tbody[\"x\"]", "if true:\n\t\tbody[\"x\"]"),
 "w08-x-alias": (W, "body[\"x\"] = extra.duplicate(true)", "body[\"x\"] = extra"),
 "w09-equal-ht-accepted": (W, "if ht <= _newest:", "if ht < _newest:"),
 "w10-no-kindchange-life": (W, " or cur[\"kind\"] != kind:", ":"),
 "w11-no-history-cap": (W, "> history_size:", "> history_size + 1000:"),
 "w12-no-despawn-on-absence": (W, "\t\t\t\tcur[\"despawn\"] = ht\n\treturn true", "\t\t\t\tpass\n\treturn true"),
 "w13-render-backwards": (W, "if _has_render and r < _last_render:", "if false:"),
 "w14-local-in-sample": (W, "\t\t\t\tif not _local.has(id):\n\t\t\t\t\tout[id]", "\t\t\t\tif true:\n\t\t\t\t\tout[id]"),
 "w16-despawn-inclusive": (W, "or r < int(life[\"despawn\"]) * 1000):", "or r <= int(life[\"despawn\"]) * 1000):"),
 "w17-counter-no-cap": (W, "if r <= (_newest + extrapolate_cap_ticks) * 1000:", "if true:"),
 "w18-no-extrap-cap": (W, "var rc: int = mini(r, (tn + extrapolate_cap_ticks) * 1000)", "var rc: int = r"),
 "w19-angle-extrap-long-arc": (W, "wrapf(vn[c] + wrapf(vn[c] - vp[c], -PI, PI) * k, -PI, PI)", "wrapf(vn[c] + (vn[c] - vp[c]) * k, -PI, PI)"),
 "w20-angle-long-arc": (W, "wrapf(va[c] + wrapf(vb[c] - va[c], -PI, PI) * alpha, -PI, PI)", "wrapf(va[c] + (vb[c] - va[c]) * alpha, -PI, PI)"),
 "w21-angle-unwrapped": (W, "wrapf(va[c] + wrapf(vb[c] - va[c], -PI, PI) * alpha, -PI, PI)", "va[c] + wrapf(vb[c] - va[c], -PI, PI) * alpha"),
 "w22-snap-inclusive": (W, "res[c] = va[c] if r < b * 1000 else vb[c]", "res[c] = va[c] if r <= b * 1000 else vb[c]"),
 "w23-snap-lerps": (W, "res[c] = va[c] if r < b * 1000 else vb[c]", "res[c] = va[c] + (vb[c] - va[c]) * alpha"),
 "w24-snap-extrapolates": (W, "\t\t\t\t\tout[c] = wrapf(vn[c] + wrapf(vn[c] - vp[c], -PI, PI) * k, -PI, PI)\n", "\t\t\t\t\tout[c] = wrapf(vn[c] + wrapf(vn[c] - vp[c], -PI, PI) * k, -PI, PI)\n\t\t\t\t_:\n\t\t\t\t\tout[c] = vn[c] + (vn[c] - vp[c]) * k\n"),
 "w25-alpha-off": (W, "float((b - a) * 1000)", "float((b - a + 1) * 1000)"),
 "w28-no-layout-check": (W, "if int(d[\"lh\"]) != _layout_hash:", "if false:"),
 "w29-no-dup-check": (W, "if seen.has(id):", "if false:"),
 "w30-no-ev-type-check": (W, "if section.has(\"ev\") and typeof(section[\"ev\"]) != TYPE_ARRAY:", "if false:"),
 "w32-ack-default-0": (W, "int(wire.get(\"ack\", -1))", "int(wire.get(\"ack\", 0))"),
 "w33-reset-keeps-lives": (W, "\t_lives.clear()\n", ""),
 "w34-reset-keeps-counters": (W, "\textrapolated_frames = 0\n\theld_frames = 0\n", ""),
 "w36-latest-alias": (W, "\"state\": (life[\"states\"][n - 1] as PackedFloat32Array).duplicate()}", "\"state\": life[\"states\"][n - 1]}"),
 "w37-ingest-pl-alias": (W, "_pl = (snap[\"pl\"] as Dictionary).duplicate(true)", "_pl = snap[\"pl\"]"),
 "w38-stale-before-validate": (W, "\tvar reason := _validate(body)\n", "\tif typeof(body) == TYPE_DICTIONARY and typeof(body.get(\"ht\")) == TYPE_INT and int(body[\"ht\"]) <= _newest:\n\t\tstale_count += 1\n\t\treturn false\n\tvar reason := _validate(body)\n"),
 "w15-local-signals": (W, "\t\t\t\tif not local:\n\t\t\t\t\tevents.append([life[\"spawn\"]", "\t\t\t\tif true:\n\t\t\t\t\tevents.append([life[\"spawn\"]"),
 "w26-spawn-before-despawn-at-tie": (W, "return a[1] < b[1]", "return a[1] > b[1]"),
 "w27-tie-id-desc": (W, "return a[2] < b[2])", "return a[2] > b[2])"),
 "w39-spawn-refires": (W, "\t\t\t\tlife[\"spawn_fired\"] = true\n", ""),
 "w40-late-spawn-dropped": (W, "not life[\"spawn_fired\"] and int(life[\"spawn\"]) * 1000 <= r:", "not life[\"spawn_fired\"] and int(life[\"spawn\"]) * 1000 <= r and (not _has_render or _last_render < int(life[\"spawn\"]) * 1000):"),
 "w41-late-despawn-dropped": (W, "and int(life[\"despawn\"]) * 1000 <= r:", "and int(life[\"despawn\"]) * 1000 <= r and (not _has_render or _last_render < int(life[\"despawn\"]) * 1000):"),
 "w42-discard-before-fired": (W, "while not lives.is_empty() and lives[0][\"despawn_fired\"]:", "while not lives.is_empty() and lives[0][\"despawn\"] != -1:"),
 "w43-local-not-consumed": (W, "\t\t\t\tlife[\"spawn_fired\"] = true\n\t\t\t\tif not local:\n\t\t\t\t\tevents.append([life[\"spawn\"]", "\t\t\t\tif not local:\n\t\t\t\t\tlife[\"spawn_fired\"] = true\n\t\t\t\t\tevents.append([life[\"spawn\"]"),
 "r01-stale-ack-processed": (R, "if last_applied <= int(_acked.get(peer_id, 0)):\n\t\treturn", "if false:\n\t\treturn"),
 "r02-no-clamp": (R, "\t\tn = highest\n", "\t\tpass\n"),
 "r03-overflow-drops-newest": (R, "\t\tlist.remove_at(0)\n\t\t_overflow", "\t\tlist.remove_at(list.size() - 1)\n\t\t_overflow"),
 "r04-expire-inclusive": (R, "> max_age_ticks:", ">= max_age_ticks:"),
 "r05-forget-resets-ids": (R, "\t_pending.erase(peer_id)\n", "\t_pending.erase(peer_id)\n\t_highest.erase(peer_id)\n"),
 "r06-forget-keeps-expired": (R, "\t_expired.erase(peer_id)\n", ""),
 "r07-pending-inner-alias": (R, "out.append([e[0], e[1], e[2]])", "out.append(e)"),
 "r08-reset-keeps-ids": (R, "\t_highest.clear()\n", ""),
 "r09-forget-resets-acked": (R, "\t_pending.erase(peer_id)\n", "\t_pending.erase(peer_id)\n\t_acked.erase(peer_id)\n"),
 "i02-reapply-last": (I, "if id > _last_applied and", "if id >= _last_applied and"),
 "i03-no-gap-count": (I, "\t\t\tgap_count += 1\n", ""),
 "i04-lost-off-by-one": (I, "lost_count += id - _last_applied - 1", "lost_count += id - _last_applied"),
 "i05-unsorted": (I, "\tids.sort()\n", ""),
 "i06-accept-id-0": (I, "or int(e[0]) < 1:", "or int(e[0]) < 0:"),
 "i07-reset-keeps-last": (I, "\t_last_applied = 0\n\tgap_count", "\tgap_count"),
}
def run():
    r = subprocess.run([GODOT, "--headless", "--path", SCRATCH, "--script", "res://addons/couch-games-sdk/netcode/fixtures/run_replicated_world.gd"], capture_output=True, text=True, timeout=600)
    out = r.stdout + r.stderr
    lines = out.splitlines()
    return r.returncode, [l.strip() for l in lines if "FAIL:" in l], [l.strip() for l in lines if "SCRIPT ERROR" in l or "Parse Error" in l], [l for l in lines if "G15 replicated world" in l]
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
        verdict = "RED" if rc != 0 or fails else "GREEN"
        print(f"{verdict:5} {name}: rc={rc} fails={len(fails)} errs={len(errs)} {summ}", flush=True)
        for x in fails[:4]: print("    ", x[:170])
        for x in errs[:2]: print("    ERR", x[:170])
        open(REPO + f, "w").write(origs[f])
finally:
    for f, s in origs.items(): open(REPO + f, "w").write(s)
