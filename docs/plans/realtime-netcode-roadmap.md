# Real-time netcode roadmap: owner authority, then host authority with prediction

Status: planned 2026-10-02. 0a-0d MERGED (PRs #21-#24). Render-delay default -> 6 MERGED (PR #25). Step 1 (owner authority): BUILT, PR #26 (1a95a1c, G16 375 checks, 74/74 mutations red); design in owner-authority-step1-design.md; decided A=1 (collide normally, games may opt out via layers), B=1 (full kind state in "o"), C=1 (tune by settle time), D=1 (accel + snap flag + helpers), E=1 (explicit ownership, trust reports), F=stale_mode HOLD default / REPORT_ONLY, G=split (impulse format + mass now, compensation in step 1.1 / G17). All decided; API contract frozen in the design doc 2026-10-05. Step 1 MERGED (PR #26, c9afe31). Step 1.1 (impulse compensation, G17 197 checks): BUILT 2026-10-05, local commit f90557e on feat/impulse-compensation, PR #27 open; design impulse-compensation-1.1-design.md. NEXT (order changed 2026-10-05): step 3a demo, system 1 only -- docs/plans/demo-pickup-prompt.md; step 2 after it. Follow-ups: moving-platform riding (platform-relative coords) later.

- **N input-sending players** per session, not the single pinned guest `CouchSession` has today.
- **Host-authority prediction rolls back only the local player's own entity**, netfox-style. Everything else is interpolated from snapshots. There is no determinism contract on the game.
- **The end-to-end test bed is a new minimal Godot demo**, not mosa-like (Phaser/Matter today, no netcode) and not tower-defense.

Related: `per-entity-authority-netcode.md` is the earlier, single-guest, physics-sandbox version of system 1. Its wire shapes, PD controller and impulse-event ring carry over. Its "one guest" assumption does not. duo's `rollback-godot` is GGPO-style deterministic rollback, a different model, and is not reused. `CouchPredictionCore`, `drain_coordinator.gd` and `recovery_coordinator.gd` are discrete-grid machinery and must not be bent toward any of this.

## The two systems

**1. Owner authority.** Each player simulates their own entity and is authoritative for its transform. They send it every tick as `input`. The host drives a stand-in for each remote player's entity toward the reported transform. For a physics body this is a critically-damped PD spring with velocity feed-forward and a snap threshold. The host is authoritative for everything else and broadcasts snapshots that include every player's entity (so guests see each other through the host; the star has no guest-to-guest links). Impulses the host applies to a player-owned entity go back to its owner through an acknowledged event ring. Cheap, no rewind, and cheating is trivial (fine for couch co-op).

**2. Host authority with client prediction.** Each player sends **inputs**, tagged by tick. The host simulates every entity and broadcasts snapshots carrying, per player, the last input tick it applied. The client:

- predicts its own entity by running a game-supplied `step(state, input, dt) -> state` locally;
- keeps a ring of its unacknowledged inputs;
- on each snapshot, resets its entity to the host's state at `ack_tick`, replays the newer inputs through `step`, and hides the correction with a decaying visual offset.

The player's own entity must be replayable, so it has to be a `CharacterBody2D`-style kinematic controller, not a `RigidBody2D`. Every other entity is interpolated, as in system 1.

Both systems share almost everything except the "who simulates the player's entity" part, so the shared foundation comes first.

## Steps (each its own branch and PR, gate-first, mutations reported)

### 0a. Delay and jitter injection on both transports (in progress)

Debug-only `fault_delay_ms` / `fault_jitter_ms` (seeded, reproducible) on `CouchLobbyTransport` and `CouchStarTransport`, next to the existing drop levers. Outgoing envelopes are queued and flushed from `poll(now_ms)`. Without this, interpolation buffers, PD thresholds and prediction cannot be tuned or gated without a WAN. Gates: G3 and G11 gain cases.

### 0b. N input players in `CouchSession` (done, PR #22)

As built: `max_input_players` counts GUESTS (host slot 0 not counted). Multi mode promotes waiting spectators into freed slots (lowest slot first, same ordering as newcomers), emits `player_joined` for every starting slot after `session_started`, and the guest-side `local_slot_changed(old, new)`. `SLOT_GUEST` stays 1 ("first guest slot"); the guest send gate is `slot >= 1`. `authorized_peer_id` is the slot-1 guest at session start, not updated, not the authority in multi mode. Multi mode below two players stops with `roster-too-small` (no `player_left`). G13 = `netcode/fixtures/run_session_players.gd`, 83 checks.

Original plan:


Today `_authorized_peer_id` is the single guest allowed to send `input`/`intent`, and its departure stops the session (`authorized-peer-left`). The change:

- A `CouchSessionPolicy` setting `max_input_players`, default 1, which keeps today's behaviour and every existing gate unchanged.
- When it is greater than 1, every roster player up to the cap gets an input slot. The slots map in the host's hello already exists; it becomes the authority for "who may send input".
- A slotted guest leaving no longer stops the session. Instead the session emits `player_left(peer_id, slot)`, and a newcomer emits `player_joined` and gets a slot via a re-sent hello.
- Epoch rules are untouched: a host restart is still a new epoch.

This step needs a new gate (G13). G9's pins, and the D8 host-restart pins, must stay green.

### 0c. `CouchNetClock` (done, PR #23)

As built: `CouchFixedTicker` (host fixed step, drift-free), `CouchNetClockEcho` (host: per-peer newest received input tick, arrival time, margin), `CouchNetClock` (client), `CouchNetClockPolicy` (tick_hz 60 default). RTT is NOT from ack_tick (it includes the host's buffer hold ~ the input lead -> feedback loop): the snapshot echoes `recv_tick`, `hold_ms`, `margin` per player and RTT = now - send(recv_tick) - hold_ms. The input lead is driven by the host-reported margin (grow at once, shrink 1 tick/s with hysteresis), not by RTT/2. No new envelope kind: fields ride in the game's input body (`tick`) and snapshot body (`host_tick`, per player `ack_tick` + echo dict) until 0d packs them. G14 = `netcode/fixtures/run_net_clock.gd`, 112 checks; 35/35 mutations red.

Original plan:


A fixed simulation tick, plus the client's estimate of the host's current tick. The estimate comes from the snapshot `t`, half the RTT (`CouchLatencyEstimator` already exists) and a slow drift correction. It answers two questions: which tick a client should stamp on its input (system 2's input lead) and which render time to interpolate at. Pure, so it can be gated headless.

### 0d. `CouchReplicatedWorld` + `CouchEventRing`

The SDK helpers the per-entity proposal deferred:

- packing a snapshot by entity id and kind into packed arrays, and diffing on receive;
- an interpolation buffer with a render delay and an extrapolation cap;
- a monotone, acknowledged impulse-event ring.

Pure data structures, unit-gated. Game-agnostic about what an entity *is*: the game supplies pack and apply callables.

### 1. Owner-authority helpers

- `CouchOwnedEntity`: the owner-side pack and send.
- `CouchPDFollower`: the host-side pure spring math, usable from `_integrate_forces` or a kinematic body.

Gate: a headless fixture with three sessions (host plus two guests) over a scripted transport with 0a's delay. Its invariants:

- host stand-ins converge to the owners' transforms within a bound;
- events are applied exactly once and acknowledged;
- the stand-in snaps over the threshold.

### 2. Host-authority prediction

- `CouchInputBuffer` (host): per-player inputs by tick; a missing input repeats the last one and is counted; late inputs are dropped.
- `CouchReconciler` (client): the input ring, rewind and replay through the game's `step` Callable, and smoothing of the visual error.

Gate invariant, mirroring `CouchPredictionCore`'s: *after reconcile, predicted state == `step`-replay of the unacknowledged inputs on top of the host's state at `ack_tick`*. With zero loss and a deterministic `step`, the error must be zero. Under delay, jitter and loss the client must converge, and every correction must be accounted for.

### 3. Demo (3a: system 1 only, NEXT; 3b: add system 2 after step 2)

A minimal top-down arena in a sibling repo (`couch-netcode-demo`) with the SDK symlinked in:

- N players, with a toggle between system 1 and system 2;
- a debug overlay with delay, jitter and loss sliders bound to the 0a levers;
- a pushable crate to exercise host-owned entities and impulses.

It runs as two to four instances over the local/mock backend, then over the real platform on the star.

## Order and why

0a → 0b → 0c → 0d are prerequisites for both systems. 1 is smaller than 2 and proves 0b–0d first.

**Changed 2026-10-05 (Daniel): 1 → 1.1 → 3a (demo, system 1 only) → 2 → 3b (demo gains system 2).**
Everything through 1.1 is library code exercised only by gates; nothing real calls it. The demo
is the first consumer, and real use finds the remaining bugs (and real defaults for settle_ms,
impulse_tau_ms, snapshot rate) faster than more library work. It is also the test bed step 2
needs. The system 1 / system 2 toggle in the demo is therefore added in 3b, after step 2; 3a
leaves room for it. Pickup: `docs/plans/demo-pickup-prompt.md`.

## Open questions

- In owner mode, should two player-owned entities collide on the host? Each owner sees the other as kinematic.
- Should input be sent every tick, or redundantly (each packet carrying the last N inputs) so that loss doesn't starve the host buffer? Redundancy is cheap and standard. The proposal is redundant inputs in system 2.
- Snapshot rate on the lobby tunnel versus the star. Measure in the demo.

---

## Pickup prompt (paste into a fresh session)

Continue the real-time netcode roadmap in `couch-games-sdk-godot`. Read `docs/plans/realtime-netcode-roadmap.md` first (untracked; this prompt is at its bottom).

**State as of 2026-10-05 (end of decisions session):** 0a-0d MERGED, render-delay 6 MERGED (PR #25). Step 1 decisions A-G all settled; API contract frozen in `owner-authority-step1-design.md`; build not started. The step-1 pickup prompt is `docs/plans/step1-pickup-prompt.md` -- use that.

**0c as built (for reference):** client `CouchNetClock.on_snapshot(host_tick, now_ms)`, `on_echo(recv_tick, hold_ms, margin, now_ms)`, `advance(now_ms) -> PackedInt64Array` (ticks to stamp now), `host_tick_estimate_milli`, `render_tick_milli`, `reset()` on new epoch, signal `resynced(reason)`. Host: `CouchFixedTicker.advance(now_ms)`, `next_tick`; `CouchNetClockEcho.note_input(peer, tick, next_host_tick, now_ms)` (caller must drop stale-epoch inputs first, or a late old-epoch input poisons recv_tick), `echo_for(peer, now_ms)`, `forget`, `reset`. Timeline unit is milliticks (tick*1000), integer-only. RTT = now - send(recv_tick) - hold_ms, NOT from ack_tick (the buffer hold would make a lead/RTT feedback loop); the input lead is driven by the host-reported margin.

**How the work is done** (memory: star-transport-conventions, realtime-netcode-decisions, godot-gate-matrix-recipe, no-claude-commit-trailers):
- Opus plans and reviews; Sonnet agents write all code. Pattern used for 0b and 0c: design doc settled with Daniel; Sonnet agent 1 writes the gate + inert stubs and shows the red run; Sonnet agent 2 writes the behaviour independently from the design (not from agent 1's reference); Opus reviews and runs mutations with a script (exact string replacements on the final file, run the gate, restore in `finally`); every mutation that stays green gets a new gate case. 0c's runner is saved at `docs/plans/net-clock-mutations.py` as a template.
- Gate-first; mutations against the FINAL code, reported in the commit with which cases went red. Assertions on observed effects. Missing WebRTC is FAIL, not skip.
- Do not bend `prediction_core.gd`, `drain_coordinator.gd`, `recovery_coordinator.gd`, `latency_estimator.gd`. Nothing in `netcode/` may reference `webrtc/` or `lobby/`.
- Long-form commit messages with reasoning, the mutation table and real gate counts. No Co-Authored-By/Claude trailers and no "Generated with Claude Code" footer on commits or PRs. One branch and PR per step. Ask Daniel before pushing / opening the PR.
- Full matrix on Godot 4.4 / 4.5.1 / 4.7 before a PR. The reboot WIPES `/tmp`: recreate the scratch projects (g44, g451, g47, g47nw) in the new session's scratchpad per the godot-gate-matrix-recipe memory, then use `docs/plans/matrix.sh` (it includes G14; edit its `S=` and `OUT=` paths to the new scratchpad, and add G15). Re-`--import` after adding a class; delete stray `.uid` files from the import (`tools/upload_shared_assets.gd.uid`; restore `core/save_load_result.gd.uid` with git checkout).
- Expected counts on `main`: G14 112, G13 83, G3 41, G11 230, G7 100, G8 47, G9 60, G1 117/117, G2 44/44, `tests/session_transport_test` 62, `tests/webrtc_probe_test` 38, both `tests/webrtc_*` exit 0. In g47nw (no webrtc_native) session_transport_test fails exactly its 4 FAIL-not-skip star checks, by design. The probe test logs "CouchWebRTCProbe: FAILED (no-route)" on purpose; grep for the `_OK` marker.
- The user's shell is fish: use `bash -c` for multi-line logic.

**Side items, not part of the roadmap steps:** tower-defense should show `CouchWebRTCProbe.describe(picked.probe.reason)` and log `picked.probe` on every `pick()`; Star Run B is UNBLOCKED (platform-dev PR #233 merged 2026-09-14) and needs two devices (`star-transport-handoff.md`); the per-link tunnel fallback waits on refusal data.
