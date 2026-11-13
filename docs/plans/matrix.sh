#!/bin/bash
S=/tmp/claude-1000/-home-daniel-Repositories-platform-dev/ed427b9b-3571-41d8-a684-01b80ab50761/scratchpad/godot
V=~/.local/share/godot/app_userdata/Godots/versions
FX=/home/daniel/Repositories/couch-netcode-fixtures
R=res://addons/couch-games-sdk
declare -A BIN=([g44]=$V/Godot_v4_4-stable_linux_x86_64/Godot_v4.4-stable_linux.x86_64 [g451]=$V/Godot_v4_5_1-stable_linux_x86_64/Godot_v4.5.1-stable_linux.x86_64 [g47]=$V/Godot_v4_7-stable_linux_x86_64/Godot_v4.7-stable_linux.x86_64 [g47nw]=$V/Godot_v4_7-stable_linux_x86_64/Godot_v4.7-stable_linux.x86_64)
OUT=/tmp/claude-1000/-home-daniel-Repositories-platform-dev/ed427b9b-3571-41d8-a684-01b80ab50761/scratchpad/matrix-logs; mkdir -p $OUT
for p in g44 g451 g47 g47nw; do
  timeout 300 ${BIN[$p]} --headless --path $S/$p --import >/dev/null 2>&1
done
run() { # proj name script args...
  local p=$1 n=$2 s=$3; shift 3
  timeout 600 ${BIN[$p]} --headless --path $S/$p --script $R/$s "$@" > $OUT/$p-$n.log 2>&1
  local rc=$?
  local pass=$(grep -c "PASS" $OUT/$p-$n.log); local fail=$(grep -c "FAIL" $OUT/$p-$n.log)
  local summ=$(grep -E "[0-9]+ ?/ ?[0-9]+|_OK|_FAILED|passed|failed" $OUT/$p-$n.log | tail -1 | cut -c1-110)
  printf "%-6s %-5s rc=%-3s PASS=%-4s FAIL=%-3s %s\n" $p $n $rc $pass $fail "$summ"
}
for p in g44 g451 g47; do
  run $p G1 netcode/fixtures/run_fixtures.gd -- --fixtures=$FX/data
  run $p G2 netcode/fixtures/run_transport_fixtures.gd -- --fixtures=$FX/transport/data
  run $p G3 netcode/fixtures/run_transport_faults.gd
  run $p G7 netcode/fixtures/run_star_unit.gd
  run $p G8 netcode/fixtures/run_star_link.gd
  run $p G9 netcode/fixtures/run_star_session.gd
  run $p G11 netcode/fixtures/run_star_faults.gd
  run $p G13 netcode/fixtures/run_session_players.gd
  run $p G14 netcode/fixtures/run_net_clock.gd
  run $p G15 netcode/fixtures/run_replicated_world.gd
  run $p G16 netcode/fixtures/run_owner_authority.gd
  run $p G17 netcode/fixtures/run_impulse_compensation.gd
  run $p stt tests/session_transport_test.gd
  run $p probe tests/webrtc_probe_test.gd
  run $p wch tests/webrtc_connection_handler_test.gd
  run $p wsr tests/webrtc_signaling_reconnect_test.gd
done
run g47nw stt tests/session_transport_test.gd
run g47nw G13 netcode/fixtures/run_session_players.gd
run g47nw G14 netcode/fixtures/run_net_clock.gd
run g47nw G15 netcode/fixtures/run_replicated_world.gd
run g47nw G16 netcode/fixtures/run_owner_authority.gd
cd /home/daniel/Repositories/couch-games-sdk-godot && rm -f tools/upload_shared_assets.gd.uid && git checkout -q -- core/save_load_result.gd.uid 2>/dev/null; git status --short
run g47nw G17 netcode/fixtures/run_impulse_compensation.gd
