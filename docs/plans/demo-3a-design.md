# Step 3a design: the netcode demo, system 1 (owner authority) only

Status: DECIDED 2026-10-05 (rev 2, Fable frame review folded in). Daniel: A=1 submodule; E = runtime
toggle (see below); L = local only for now (no GitHub repo); B, C, D, F-K accepted as recommended. Builds on addon `main` at fc9b4b4 (PR #27, step 1.1, merged 2026-10-05).

## Goal

The first real consumer of 0a-1.1. A minimal Godot project where 2-4 instances play in one
top-down arena under owner authority, with a debug overlay that injects delay, jitter and loss
and shows what the library is doing. Success is not "it looks fine": it is a list of library
bugs, awkward APIs and measured defaults, each turned into its own addon issue or PR. Second
job: be the test bed step 2 and 3b plug into, so the player controller sits behind a seam now.

Already decided (roadmap, 2026-10-02): new sibling repo `~/Repositories/couch-netcode-demo`;
top-down arena; N players; overlay sliders bound to the 0a levers; one pushable crate
(host-owned, impulses); 2-4 local instances first, the real platform on the star later.

Out of scope for 3a: system 2 and the toggle (3b); 3D; moving platforms; a real-platform run
(later milestone, needs a dev-portal upload); art, menus.

### Definition of done

- Slices 1-5 merged (slice 6, the star, is a stretch).
- Smoke script ([DECIDE K]) green on Godot 4.7 and run before every demo PR.
- A recorded manual run at 50 / 150 / 250 ms injected RTT with the overlay visible.
- Every findings-log row filed as an addon issue or PR (gate-first, matrix before PR).
- The four defaults (settle_ms, impulse_tau_ms, snapshot interval, render_delay_ticks) written
  back to the roadmap, each WITH the procedure used to pick it (e.g. "smallest settle_ms with no
  visible overshoot at 150 ms RTT, read off `effective_settle_ms()`"). A value without a
  procedure is an opinion.

## The shape, in one picture

```
 owner (guest k)                      host                                  other owners
 ----------------                     ----                                  ------------
 CharacterBody2D (real)  --input-->   CouchOwnerTargets.note_input
   o = full kind state                  target_for -> CouchPDFollower
   ev = inbox.last_applied              stand-in RigidBody2D (force_from)
                                        crate (RigidBody2D, host-owned)
                                        host's own player (local)
 inbox <-- "ev" in snapshot --------  CouchEventRing (knocks)
 world.sample(render)  <--snapshot--  CouchReplicatedWorld.pack  --snapshot-->  world.sample
   (others + crate, interpolated;                                              (all but own)
    own id is set_local)
```

## Findings before writing any code

1. **No documented recipe for driving ticks from a Node game.** The gates drive
   `CouchFixedTicker` / `CouchNetClock.advance` from a scripted clock with toy integrators. In a
   Godot game the host's `_physics_process` already IS a fixed, wall-anchored tick, so a Node
   host does not need `CouchFixedTicker` at all, and running both gives 0- and 2-tick frames
   plus a trap (a repeated snapshot `ht` is counted stale by clients). See [DECIDE C]. Addon
   follow-up: a "driving it from Nodes" section in the README / class docs.
2. **The star has no loss lever.** `CouchLobbyTransport` has `fault_drop_permille` +
   `fault_kinds`; `CouchStarTransport` only delay / jitter / `fault_kill_link`. Addon issue:
   `fault_drop_permille` on the star (small, gate-first, G11 case).
3. **Predicted deadlock: pushing a crate with local collision on.** An owner blocked by its
   render-delayed crate copy stops at the surface and reports velocity 0 into it; the stand-in
   follows to the same surface and never pushes the real crate. See [DECIDE E].
4. **Fault levers act on OUTGOING envelopes.** A symmetric 150 ms RTT needs ~75 ms on every
   instance. The overlay must say so ([DECIDE H]).
5. **`CouchOwnedEntity`'s wiring is RigidBody2D-only.** Its recipe says
   `body.apply_central_impulse(imp.j)`. A kinematic owner must do `velocity += j / PLAYER_MASS`
   with the same mass the host passed to `set_owner`, AND its controller must be acceleration-
   based (as G16's owner is: `vx += (ux - vx) * 6/60`). A controller that sets
   `velocity = input * speed` erases the knock next tick, and the host's compensation lead (which
   assumes the body carries dv) then overshoots. Addon follow-up: a CharacterBody2D line in the
   class doc. See [DECIDE D].
6. **The settle_ms lever is clamped.** `omega = min(4.74 / settle_s, 0.5 / dt)`: at 60 Hz any
   settle_ms below ~158 gives the same spring, and the default is 150. The overlay must show
   `follower.effective_settle_ms()` or the first "measured default" will be a no-op value.
   Possibly an addon finding in itself (the default sits inside the clamp).
7. `~/Repositories/netfox` is checked out locally: a read-only reference for how a Godot
   netcode library drives ticks from `_physics_process`.

## Decisions

### [DECIDE A] How the demo consumes the addon

1. **git submodule at `addons/couch-games-sdk`, tracking `main`** (recommended). Pinned, clones
   and runs on a second machine (Star Run B, platform upload), and matches the five game repos
   that embed it this way. An addon fix lands as its own addon PR, then the demo bumps the
   submodule in a one-line commit.
2. Symlink to the checkout (what the roadmap wrote). Zero friction while editing both, but not
   clonable and nothing pins which addon was verified.
3. Vendored copy (tower-defense style). Portable, noisy bumps.

`webrtc_native` (star only) is vendored from tower-defense in any case.

### [DECIDE B] Godot version

**4.7** (recommended), the games' version. The demo targets 4.7 only; the addon matrix keeps 4.4 /
4.5.1 / 4.7.

### [DECIDE C] Who owns the tick, and the per-frame cadence

1. **(recommended)**
   - **Host**: tick = a counter incremented once per `_physics_process` (60 Hz). Game logic,
     knocks and followers run per physics frame; `echo.note_input(peer, t, host_tick + 1, now)`;
     snapshot every N physics frames with `ht = host_tick`. No `CouchFixedTicker`.
   - **Owners**: in `_physics_process`, step the CharacterBody2D once per tick that
     `clock.advance(now)` returns (fixed dt, explicit `move_and_collide` slide), so owner ticks
     are exactly the stamped ticks. The controller already has system 2's `step` shape.
   - **Transport + session poll**: `transport.poll(now)` then `session.poll(now)` from `_process`
     (every render frame), as the README shows. Injected delay is then flushed at render-frame
     granularity rather than quantized to 16 ms physics frames.
   - `now_ms = Time.get_ticks_msec()` everywhere.
2. Host also uses `CouchFixedTicker` beside the physics loop. Rejected: 0/2-tick frames and the
   repeated-`ht` trap, for nothing the host needs.
3. Host steps physics manually per ticker tick. Not available: Godot 4.7 has no manual
   `PhysicsServer2D` space step (checked in the 4.7 extension API).

### [DECIDE D] Body types and host physics setup

1. **(recommended)** Owners: CharacterBody2D, acceleration-based controller (finding 5), knocks
   applied as `velocity += j / PLAYER_MASS`. Host stand-ins: RigidBody2D, rotation locked,
   driven by `CouchPDFollower.force_from` in `_integrate_forces`; a follower snap sets
   `state.transform` and velocities INSIDE `_integrate_forces` (setting `position` outside is
   overwritten by the physics server). Host's own player: the same CharacterBody2D controller as
   owners, as a plain local entity; it pushes the crate by applying an impulse on each slide
   collision (Godot 4 CharacterBody2D does not push rigid bodies by itself).
   Top-down setup: `gravity_scale = 0` on stand-ins and crate; stand-in `mass` == the mass
   passed to `set_owner`; the crate's `linear_damp` / `angular_damp` are the "does it stop"
   tuning and become overlay levers.
2. Everything CharacterBody2D (stand-ins via `velocity_after`). Simpler, but kinematic stand-ins
   neither push nor get pushed by the crate, so the contact -> knock path is never exercised.
3. Owners RigidBody2D too. Not replayable, so 3b would need a second controller.

Players do not rotate (circles; no `rot`/`w` in their channel map). The crate rotates
(host-owned, ANGLE-interpolated).

### [DECIDE E] How a player pushes the crate (finding 3)
[DECIDED, Daniel 2026-10-05: BOTH, as a live overlay toggle on each owner (default option 1,
collision off), so the difference can be seen and played with at different pings. The
`--crate-collide` user arg sets the initial state for scripted runs.]

1. **Owners do not collide with crates locally (layer off); the host stand-in pushes the real
   crate; the owner sees its interpolated crate move after ~RTT/2 + render delay**
   (recommended). No deadlock. Predicted failure mode, to record rather than pre-fix: the spring
   force grows with error, so under lag the stand-in shoves the crate harder the further the
   owner has walked "through" it, and past `snap_distance` (256) the stand-in teleports inside
   the crate and gets ejected by physics.
2. Owners collide with an AnimatableBody2D crate copy at its interpolated position. Should
   deadlock (finding 3). Available as a user arg (`--crate-collide`) so the hypothesis gets
   tested on day one.
3. Owners report intended velocity instead of actual. Breaks "o is the entity's state". Not
   recommended; listed so it is not reinvented.

### [DECIDE F] What knocks players, and player-player contact

1. **Shockwave key on the host** (recommended, first): `targets.push_impulse(ring, peer, J, 0.0,
   tick, now)` for every player in a radius; change only the target, never apply J to the
   stand-in, per the docs. (Bumper pads cut: same path, more code.)
2. **Contact knocks** (recommended, second): crate-vs-stand-in contacts above an impulse
   threshold, measured in the stand-in's `_integrate_forces`, become knock events. Host physics
   already moved the stand-in, so J is never applied again on the host. Threshold is a lever.

Player-player collision on the host: **on by default (step-1 decision A=1), overlay toggle flips
the layer** (recommended). Shoves reach the shoved owner only through the contact-knock path.
Superseded for player-player contact by [DECIDE M] (finding 9): stand-ins no longer collide with
each other; the host turns overlaps into knocks.

### [DECIDE G] Players, ids, roster, epochs

- `max_input_players = 3` (counts guests: host + 3 guests = 4 players).
- Kinds, registered identically on both roles (the layout hash rejects mismatches):
  `PLAYER_KIND [x, y, vx, vy]` (LERP x4), `CRATE_KIND [x, y, rot, vx, vy, w]`
  (LERP, LERP, ANGLE, LERP, LERP, LERP). Ids: `eid = PLAYER_EID_BASE + slot` (host = slot 0),
  `CRATE_EID` a constant.
- Host: `player_joined` spawns (set_owner + set_entity + stand-in), `player_left` despawns
  (targets / ring / echo forget, remove_entity). Guests learn their slot from
  `session_started(..., local_slot, ...)` and `local_slot_changed`.
- **Epoch resets**: on host-side session start and on guest `session_stopped` ->
  `session_started` (host restart), reset world / clock / inbox (guest) and targets / ring /
  echo / world (host), as G16's `new_epoch()` does; otherwise later snapshots are rejected as
  stale.
- A 5th instance is a spectator (slot -1, no peer section, no clock sync): it shows a
  "spectating" label and renders nothing. Recommended; supporting spectators is not a 3a goal.
- **Bot input** (`--bot`): scripted movement for headless runs and for one human + 3 movers.

### [DECIDE H] Overlay: levers and readouts

Toggle key: not F10 (the SDK's mock overlay owns it); proposal F3.

Levers (per instance, labelled "outgoing from THIS instance", finding 4):
- `fault_delay_ms`, `fault_jitter_ms`, `fault_drop_permille` (tunnel only; greyed on the star).
- User-arg presets `--net-delay= --net-jitter= --net-loss= --net-seed=` so a 4-instance run is
  reproducible without four sets of sliders (seed is arg-only).
- Host: `settle_ms` (with `effective_settle_ms()` shown beside it, finding 6), `snap_distance`,
  `impulse_compensation`, `impulse_tau_ms`, `extrapolate_cap_ms`, snapshot every 1 / 2 / 3 ticks,
  contact-knock threshold, crate damping, player-player collision.
- Owner: `render_delay_ticks`.
- Cut from 3a: `stale_mode` REPORT_ONLY (needs a second "game owns the stand-in" path),
  `rot_settle_ms` (no rotating owned bodies).

Readouts (raw counters are fine; no per-second rates):
- Owner clock: rtt_ms, rttvar, lead_ticks, last_margin, sync_generation, skipped_ticks.
- Owner world: extrapolated_frames, held_frames, stale_count, rejected_count; inbox gap / lost.
- Host: per peer ring pending / expired / overflow, `pending_impulse_count(peer)`,
  `impulse_timeout_count(peer)`, accepted, rejects by reason, stale gaps, snaps, bad_input_count.

Ghosts (debug drawing, no side channel):
- Host: per stand-in, the last accepted report (outline) and the current compensated target
  (dashed).
- Owner: its own entity as the host last saw it (`world.latest(my_eid)["state"]`; local ids are
  still buffered). The gap is the round trip.
- No true-now ghost of owners on the host in 3a (would need a debug side channel). The smoke
  script measures true error offline instead ([DECIDE K]).

### [DECIDE I] Transport and snapshot rate

1. **`--transport=lobby` is the explicit default; `star` is the stretch slice 6** (recommended).
   Not `auto`: `resolve_kind(PREFER_AUTO)` picks the star whenever `webrtc_native` is installed,
   so vendoring it would silently flip every run, smoke included, onto the transport where loss
   can't be injected. `pick()` is awaited at boot; `CouchGames.webrtc` is only touched on the
   star path. The local backend serves a WebRTC signaling room, so the star runs locally.
2. Star only. Closer to production, but no loss injection (finding 2).

Snapshot rate: host lever, every 1 / 2 / 3 physics ticks, default 2 (30 Hz, as G16). Measuring
it per transport is an explicit output (roadmap open question).

**Measured in slice 6 (2026-10-05)**, smoke harness with player-player collision off, bots, host +
2 guests on one machine. Lobby = delay 40 / jitter 15 / 2% loss; star = 40 / 15, NO loss (no
lever, finding 2). Every 2 = the 18-run bound measurement; every 1 and 3 = 6 runs each. Ranges
are over owner traces (2 per run); frame counters are per guest over the whole ~20 s run
(~2450 render frames on the lobby, ~2365 on the star).

| every | transport | traces | pass | err p50 | err p95 | err max | rtt ms | held frames | extrap frames | stale | sample_frames |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | star | 12 | 6/6 | 12.4-14.3 | 14.9-17.5 | 17.4-21.6 | 88.0-91.0 | 0-0 | 0-0 | 0-0 | 2364-2367 |
| 1 | lobby | 12 | 6/6 | 13.8-16.6 | 17.1-20.0 | 18.6-30.9 | 105.0-108.0 | 0-0 | 0-0 | 0-0 | 2450-2454 |
| 2 | star | 36 | 18/18 | 11.7-14.6 | 14.9-22.5 | 16.7-68.4 | 89.0-96.0 | 0-0 | 0-0 | 0-0 | 2362-2368 |
| 2 | lobby | 36 | 18/18 | 14.1-16.5 | 17.0-20.2 | 18.4-30.6 | 101.0-106.0 | 0-0 | 16-27 | 0-0 | 2447-2453 |
| 3 | star | 12 | 6/6 | 12.4-13.9 | 15.2-16.7 | 16.0-24.4 | 87.0-92.0 | 0-0 | 0-10 | 0-0 | 2359-2369 |
| 3 | lobby | 12 | 6/6 | 14.6-16.1 | 17.2-19.4 | 18.5-31.1 | 99.0-104.0 | 0-0 | 121-151 | 0-0 | 2445-2448 |

Reading:
- Error does not move with the rate on either transport: p50 / p95 / max overlap within
  run-to-run noise at 1, 2 and 3. The render delay (6 ticks = 100 ms) absorbs a 50 ms snapshot
  gap. rtt does not move either (it rides input reports, not snapshots).
- Held 0 and stale 0 everywhere. Extrapolation is the only counter that moves: lobby 0 / 16-27
  / 121-151 frames (0 / ~1% / ~5-6%), star 0 / 0 / 0-10. CONFOUNDED: the lobby runs drop 2% of
  envelopes and the star runs none, and a dropped snapshot is exactly what makes a sparse
  stream extrapolate. This does NOT show the star tolerates a lower rate better; a fair
  comparison needs the star's loss lever (finding 2) or a lobby run at 0% loss.
- Not measured: bandwidth (bytes per second per peer), the axis that would argue for 3.
- Default stays 2 (not changed: Daniel's call). Every 3 costs nothing visible here at 40 / 15;
  its price shows only as extrapolation under loss.

### [DECIDE J] The seam for 3b

One owner-side `PlayerController.step(state, input, dt) -> state` on the CharacterBody2D, input
sampled once per tick. One host-side `RemotePlayerDriver` with a single implementation
(`OwnerAuthorityDriver`: targets + follower + stand-in). 3b adds a second driver and the toggle.
**Nothing for system 2 gets built in 3a.**

### [DECIDE K] Verification

1. **Headless multi-process smoke script in the demo repo** (recommended). A shell runner boots
   the host (`--couch-role=host`), waits for its "local lobby hosting" log line (the local join
   timeout is 3 s), then 2 guests (`--couch-role=guest`), all headless with `--bot`,
   `--net-delay=40 --net-jitter=15 --net-loss=20 --net-seed=<fixed per process>`,
   `--smoke-seconds=20`. The host fires one shockwave at t = 8 s. Each process writes
   `user://smoke-<role>-<slot>.json` and a log; every owner logs `(unix_ms, x, y)` per tick and
   the host logs the same per physics frame per stand-in (one machine, so one clock). The runner
   asserts:
   - host saw `player_joined` x2; each guest's `session_started` had slot >= 1;
   - every owner sampled every other player + the crate on > 95% of frames after warm-up;
   - TRUE owner-vs-stand-in error by time (computed post-hoc from the logs, as G16's
     `owner_at` does in-process) below a bound, measured in slices 2-4 then frozen;
   - each owner's `clock.rtt_ms` within `[2*delay, 2*(delay+jitter) + 32]`: proves the levers
     and the RTT path end to end;
   - the knocked owners applied each event id exactly once, rings 0 pending at the end,
     0 expired / overflowed, inbox gaps 0 (loss only hits snapshots, which repeat events);
   - 0 rejects, 0 follower bad inputs, no `SCRIPT ERROR` / `ERROR:` in any log (a typed
     function that hits a script error returns a default silently).
   Non-zero exit on any failure. Godot 4.7 only. Runs before every demo PR.

   **Built in slice 5** (`tools/smoke.sh` + `tools/smoke_check.py`, Python so the trace join and
   percentiles need no fourth Godot). What changed from the plan above, and the measurement:
   - Port isolation: a temp copy of the project with an `override.cfg` (finding 16).
   - A guest that joins after the session minted starts as a SPECTATOR (slot -1) and gets its
     slot via `local_slot_changed` (CouchSession's documented "Input slots" behaviour), so the
     second guest fails "session_started slot >= 1". The assert is now: one session per
     process and a slot history of `[n]` or `[-1, n]`.
   - Owners trace once per physics frame, not per tick (a frame with two ticks would put two
     positions at one time). Host runs 22 s, guests 20 s; each process dumps at its deadline
     and lingers 3 s, so all three dumps see the full session. That needs the guests to start
     within 2 s of the host (measured ~1 s); the checker asserts the dump order.
   - Error bound, measured 2026-10-05 over 18 clean runs (36 owner traces) at 40 / 15 / 2%:
     p50 14.5-16.5 px, p95 17.5-31.5, max 33-77 (max rises with the knocks a run gets).
     Frozen: p50 <= 19, p95 <= 45, max <= 120. p50 ~15 px = ~47 ms of lag at 320 px/s.
   - Mutation-checked, each failing its own assert: delay 0 (rtt), a bad-shape report every
     300 ticks (rejects), a doubled applied id (exactly-once), a 10% crate sample drop (>95%),
     `--extrapolate-cap=0` (p50 40), a 100 ms stale target (p50 19.4-21; passed the first p50
     bound of 25, hence 19), ring `max_age_ticks = 2` (expired), a `push_error` (logs), the
     wrong port (logs), a missing guest (missing dump), guests started 3 s late (dump order).
     Committed as demo 0d27675.
   - Limit: the error asserts barely see the spring. `--settle-ms=600` (4x) PASSES (p50 ~18.5,
     p95 43.6): on the bots' smooth wander path the stand-in follows the extrapolated target
     closely whatever the settle time. The smoke guards latency, extrapolation and knocks, not
     settle tuning.
   **Slice 6 (star)**: `SMOKE_TRANSPORT=star` (demo 91fb687, review fixes d618bd7): delay 40 /
   jitter 15, no loss, `--transport=star` everywhere, and the checker asserts every log says
   `demo: transport <kind>`. `pick(prefer = star)` never falls back (it refuses with
   push_error), but the kind is asserted anyway. Player-player collision is OFF on both
   transports (Daniel, after findings row 17: the star failed 11/11 on stand-in jams). Bounds
   re-measured over 18 runs per transport and frozen as ONE shared set from the star's worst:
   p50 <= 19, p95 <= 35, max <= 100 (the max is a jam / snap guard, the star has a tail to 68).
   Lobby p50 14.1-16.5 / rtt 101-106; star p50 11.7-14.6 / rtt 89-96. Mutation-checked: a
   lobby run checked as star and vice versa (3 failures each), a live star run with one guest
   on the lobby (fails the kind assert), star with `--extrapolate-cap=0` (p50 38-39, fails).
   Lost by turning collision off: smoke coverage of player-player contact knocks (crate and
   shockwave knocks remain).
   **Goal run, finding 9 fixed** (demo bd92828 + 0e05a9c, [DECIDE M]): player contact back ON on
   both transports, as host overlap knocks; bots meet at t = 13 s; knock ids carry a source and
   the checker asserts a guest APPLIED >= 1 "player" knock. 18 runs per transport, all PASS:
   lobby p50 13.0-15.5, p95 16.8-19.7, max 19.5-27.0, rtt 101-105; star p50 11.4-13.8, p95
   14.4-18.6, max 20.6-46.6, rtt 90-96; knock sources over 36 runs: player 225, crate 50,
   shockwave 36. Jam signature (owner samples > 60 px whose stand-in is within 40 px of another):
   0 samples > 60 px at all, against 98% (503/513) touching on the old code with collision on.
   Frozen: p95 <= 30, max <= 70 (shared, ~1.5x worst); p50 PER TRANSPORT, lobby <= 17.5 / star
   <= 15.5: the 100 ms stale-target mutant reached 16.5-17.8 (star) and 19.1-19.2 (lobby) worst
   guest p50 per run, overlapping the lobby's clean 15.5, so one shared p50 cannot catch it on
   both. Mutation-checked: stand-ins colliding again (p95 197-232, max 233-245; 4/4 fail),
   `--no-player-knocks` (fails only the player-knock assert; 2/2), stale target (p50; 4/4).
2. Plus the recorded manual run at 50 / 150 / 250 ms RTT. DONE 2026-10-07 (bots, star, F3 open,
   one-way (RTT-15)/2 + jitter 15 per process): ~/Videos/couch-netcode-demo/latency-run-2026-10-07/
   rtt{50,150,250}.mp4, recorded with demo 58dd282's crate fix (then uncommitted). Headless sweep
   on the same levers, 9 runs per RTT per transport (tools/smoke.sh SMOKE_DELAY / SMOKE_JITTER,
   demo 24d6202), every structural assert green; error bounds are tuned for 40/15 so they fail at
   150/250 by design. Before the crate fix: err p50 lobby 7-9 / 20-24 / 33-37, star 5-7 / 18-21 /
   31-35 px; measured rtt 55-62 / 155-161 / 255-261 (lobby), 42-52 / 143-147 / 242-250 (star);
   input lead 5-6 / 8-10 / 11-13 ticks with the host margin steady at 2-4; no snaps, stale or
   impulse timeouts anywhere. The p50 is the transit lag itself (~270 px/s x one-way). Puppets
   extrapolate on 9-36% of frames at 150 and on all frames at 250: render delay 6 (100 ms) is
   below one-way + jitter there, input for the defaults goal. Star max spikes at 250 (to 132 px)
   = row 19, fixed by [DECIDE N]: after it, 250 star max 44-62 (lobby 47-58).
3. Real-platform star run: later milestone.

### [DECIDE L] Repo hosting
[DECIDED, Daniel 2026-10-05: local only for now; no GitHub repo until asked.]

Org and visibility are Daniel's call (suggestion: `animo-games/couch-netcode-demo`, private).
Nothing is created or pushed until decided.

### [DECIDE M] Player-player contact without a host-only collision (finding 9 / row 17)

[DECIDED 2026-10-05, goal run after slice 6: option 1, as recommended in the goal prompt.]

The problem: owner controllers sit on no collision layer, so owners pass through each other,
while their host stand-ins (RigidBody2D) collide. The host simulates contacts no owner saw, and
two stand-ins can pin each other for seconds while their owners walk apart (row 17: the star
smoke failed 11/11 on it, max error = snap distance).

1. **Stand-ins never collide with each other; the host turns OVERLAP into knocks**
   (recommended, chosen). A distance check on the host (`PlayerContacts`, every physics frame,
   all pairs of stand-ins including the host's own) detects the moment two stand-ins start to
   overlap (centre distance < 2 radii) while approaching, and sends each player the impulse an
   inelastic equal-mass collision would have given it: `J = m/2 * v_approach` along the
   contact normal, opposite signs. That is what the rigid contact used to deliver as a contact
   knock (bounce 0), so the knock strength does not change. Knocks go through the existing path:
   `push_impulse` + the ring to remote owners (the compensated target moves the stand-in, as for
   the shockwave; host physics did NOT move it this time), `apply_knock` for the host's own
   player. The same `knock_threshold` lever filters soft touches. A pair fires once per
   contact: on its first overlapping frame with J above the threshold (not only the first frame
   of the overlap, since one player can catch up with another it already touches; review fix),
   and re-arms only after the two separate past 2 radii + 4 px (hysteresis), which is the
   overlap analogue of findings row 11 (IMPACT, not contact).
   Why: owners stay authoritative over their own bodies and nothing on the host can pin a
   stand-in against another, so the disagreement is gone at the root; the knock path is already
   exactly-once and mutation-checked. Cost: contact is felt one round trip late, and players do
   not block each other: after the knock, two owners who keep walking at each other pass
   through. That was already true owner-side (owners never collided), so what the owner feels
   changes from "a knock, sometimes, plus a host-side jam" to "a knock, on every hard contact".
2. Owners collide locally with the other players' interpolated puppets. Cheap, but each owner
   sees the others render-delay + one-way in the past, so the two sides disagree about whether
   and where they touched, and the host disagrees with both.
3. Keep collision on and damp the spring while two stand-ins touch. Treats the symptom; the
   host still simulates contacts no owner saw.

Detection uses the stand-ins' state (what the host publishes and the crate sees), not the raw
reports: the stand-ins are the host's single view of where players are. The lever is renamed
to what it now does: `DemoSettings.player_knocks`, `--no-player-knocks`, overlay "player-player
contact knocks".

Built as demo 0e05a9c (after bd92828, findings row 18). Smoke: contact ON on both transports,
a bot rendezvous (`--bot-meet-at=13`: every wander bot walks to `DemoInput.MEET_POINT` for 4 s)
because the wander paths alone left a lobby run with no player contact; 4-5 contacts per run.
Numbers and mutants: [DECIDE K], "Goal run".

The crate keeps the same mechanism (owners pass through it, stand-ins hit it) and so can pin a
stand-in (row 17's suspected star max tail); left as is unless it blocks the goal. Fixed by [DECIDE N].

### [DECIDE N] Crate contact without a host-only collision (row 19, finding 9's crate half)

[DECIDED 2026-10-07, Daniel: "fix the crate overlap knocks". Option 1.]

The problem (row 19): owners pass through the crate (the [DECIDE E] default), while host
stand-ins hit it as rigid bodies. A stand-in blocked or deflected by the crate leaves its owner
for a full round trip, until the contact knock reaches the owner. The error therefore grows
with RTT faster than any other source: worst error in the 600 ms after a knock, star, median /
max px, crate 16/21, 39/44, 58/132 at 50 / 150 / 250 ms against player 9/21, 19/44, 22/58.

1. **Stand-ins never collide with the crate; the host resolves the contact itself**
   (chosen). Every physics frame, `CrateContacts` finds each stand-in that overlaps the crate
   (circle against the rotated box: the closest point on the box) and does two things:
   - **Push (every overlapping frame):** if the stand-in is closing on the crate along the
     contact normal, the crate gets the impulse that makes its normal speed match the stand-in's,
     plus a small separation bias (a fraction of the penetration per frame). It is applied at
     the contact point, so an off-centre push still turns the crate. The stand-in is not
     touched: it keeps following its owner.
   - **Knock (once per contact, an impact):** on the first overlapping frame with
     `J = m_p m_c / (m_p + m_c) * v_approach` above `knock_threshold`, the player gets `J`
     along the normal, away from the crate: the impulse an inelastic player-crate collision
     gives the player. It goes through the existing knock path, source "crate". The contact
     re-arms after the stand-in separates from the box by 4 px, as in [DECIDE M].
   Why: the owner stays authoritative over its own body, so nothing on the host holds a
   stand-in away from its owner, while the crate is still pushed as it was. Cost: a sustained
   push does not slow the player (only the impact knock reaches it), and a crate pinned on a
   wall does not block the player (owners already walked through it). That was true owner-side
   before; only the host's view changes. It also removes StandIn's contact-impulse reader and
   its IMPACT_STEPS workaround, which existed only for rigid stand-in/crate contacts.
2. Keep the rigid contact and damp the spring while touching the crate. Treats the symptom;
   the stand-in still leaves its owner for a round trip.
3. Owners collide with their crate puppet (the [DECIDE E] option 2 toggle) as the default.
   Rejected in [DECIDE E]: the owner's crate is render-delayed, so it deadlocks (finding 3).

The crate-collide toggle ([DECIDE E] option 2) stays as an experiment: an owner blocked by its
own crate copy now stops short, and its stand-in rarely reaches the real crate (only when the
real crate has moved toward a target extrapolated past the owner), so a "crate" knock can still
reach an owner that already stopped. Left as observed: it is an experiment toggle. The crate's angular velocity is ignored when measuring the
closing speed (linear velocities only); revisit if spinning crates look wrong. Review fix: the separation bias
applies only while the stand-in's centre is outside the box; past the centre the nearest face is
the far one, and the bias flung the crate backwards through a player walking into a pinned crate.

Built as demo 58dd282. Defaults, 18 runs per transport: 18/18 both; star max 20.7-29.0 (was up to
46.6), lobby max 19.2-27.1; bounds unchanged. 250 ms: star max 44-62 (was 42-132); worst owner
error in the 600 ms after a crate knock, star, 132 -> 62 px. Checker: crate_pushes > 0 and
crate_knocks > 0, each mutation-checked (no push / no knock fail only their own assert, 4/4).

## Build slices (one PR each, in order)

1. **Scaffold**: project (4.7), addon per [A], boot + awaited `pick()` (lobby) + `CouchSession`
   (`max_input_players = 3`), arena walls, role / slot label, epoch-reset wiring. Done when
   3 instances form a session: host logs `player_joined` x2, guests log their slot.
2. **Player loop**: `PlayerController` + bot input, owner wiring (clock, world, inbox,
   `CouchOwnedEntity`), host wiring (tick counter, echo, targets, followers, rigid stand-ins,
   snapshots), interpolated remote players. Done when 4 players move and see each other.
3. **Crate + knocks**: host crate, per-owner crate-collision toggle ([E], default off),
   shockwave key, contact knocks. Test finding 3 here.
4. **Overlay**: levers, readouts, ghosts, arg presets.
5. **Smoke script**: [K] 1, bound measured from slices 2-4.
6. (Stretch) **Star**: `webrtc_native`, `--transport=star`, smoke variant.

## Findings log (filled during the build)

| # | Found in | What | Addon follow-up |
|---|---|---|---|
| 1 | design | No recipe for driving ticks from Nodes; Node host needs no CouchFixedTicker | README / class-doc section |
| 2 | design | Star has no loss lever | issue: `fault_drop_permille` on CouchStarTransport |
| 3 | design, CONFIRMED slice 3 | Crate-push deadlock under local collision. ~150 ms RTT, one --bot=crate owner, 12 s: collision OFF pushed the crate 640,360 -> wall 79,627 and along it; ON moved it ~200 px on first contact then stuck at 431,482 for ~8 s. Off-mode failure also seen: 1 snap when the owner walked through a crate pinned on a wall | class-doc line in owned_entity / owner_targets: an owner must not collide with replicated host-owned bodies it is meant to push |
| 5 | design | CouchOwnedEntity wiring is RigidBody2D-only; kinematic owner needs accel controller | class-doc line |
| 6 | design | settle_ms default (150) sits inside the 60 Hz clamp (~158) | discuss: default or doc |
| 7 | slice 1 | Every import of a consuming project writes `tools/upload_shared_assets.gd.uid` into the addon, dirtying the submodule | commit the .uid in the addon |
| 9 | slice 2 review | Owners pass through other players locally while host stand-ins collide: owner and stand-in drift apart, spring force grows with error, past 256 px the stand-in snaps through. Host's own CharacterBody2D player is an immovable wall and is never knocked | DONE slice 3 (Daniel: yes): host player = local controller + zero-latency StandIn, takes contact knocks like a guest. Controllers sit on no collision layer. The remaining player-player half (stand-ins colliding while owners pass through) = row 17, FIXED by [DECIDE M] |
| 10 | slice 2 review | A rejoining peer gets a fresh inbox (last_applied 0) while the ring keeps ids across forget(): one spurious inbox gap per rejoin. forget()'s rationale assumes the client inbox survives | addon doc point; smoke "gaps 0" holds only without rejoins |
| 11 | slice 3, CONFIRMED by review, FIXED d6be259 | Knocks from summed contact impulse fire during sustained contact: get_contact_impulse is the constraint impulse, which grows with the spring error while the stand-in is at rest (host player knocked at 550-900 px/s 4x a second pushing a pinned crate). Fix: only a contact's first 2 steps count | class-doc point for CouchOwnerTargets' 'a contact the game turns into a knock event': say IMPACT, not contact |
| 12 | slice 3 | Godot Physics 2D (4.7) reports a contact one step BEFORE its impulse (0, then the whole impulse, then 0s) | same doc point, if the library ever converts contacts itself |
| 13 | slice 3 review | With an owner's crate collision on, its stand-in still hits the real crate (target extrapolated up to 100 ms) and the impact is knocked back to an owner that already stopped: double count on first contact | accepted artefact of the experiment, documented on StandIn |
| 14 | Daniel playtest + measurement, after slice 3 | ZERO net delay: a guest pushing the crate (collision off) sits ~27-40 px inside its crate copy while pushing and walks ~45 px in before the copy moves (render delay 6 ticks + round trip + spring, ~150 ms at 320 px/s); the host pushing its own crate sits ~7 px inside. Collision ON deadlocks at zero latency too (Daniel saw it): the controller reports v=0 at the surface, so the stand-in never presses. Inherent to system 1 with an interpolated crate; system 2 alone does not fix it either | Lower render delay (slice 4 lever) shrinks it. Real fix = AUTHORITY HANDOFF for pushed entities (the pusher simulates the crate while touching it, host takes it back; cf. per-entity-authority-netcode.md). Proposed as its own roadmap step. BUILT 2026-10-07: authority-handoff-design.md, demo a7b8416 (prediction) + 9ac1b24 (handoff); own-crate penetration 0 px, release jump <= 2.8 px |
| 15 | slice 4 | CouchOwnerTargets has no public read of the last ACCEPTED report (state + receive time). The host overlay can draw only target_for (extrapolated + compensated) and compensation_of, not the raw report [DECIDE H] asked for, so "how stale is the report vs where the stand-in chases" is not visible | small accessor, e.g. `last_report(peer) -> {o, t, ms}`; gate-first |
| 16 | slice 5 | The local backend's port comes only from `couch_games/local/port`: no env var or cmdline override (only `--couch-role`). A headless run beside an open editor joins the editor's game. The smoke runs a temp project copy with an `override.cfg` | small: `--couch-port=` user arg beside `--couch-role=` in local_backend.gd |
| 17 | slice 5 mutant run, CONFIRMED slice 6 | Stand-in pinned by another stand-in = finding 9. Star smoke (40 / 15, no loss), 11 runs: 11/11 fail p95 / max (p95 up to 237, max up to 266 px = snap distance). In 11 runs, 95-100% of samples with error > 60 px have the guest's stand-in within 40 px (2 radii + slack) of another stand-in, usually the host's own, for 2-4 s while the owner walks away. The lobby smoke has the same signature (every > 60 px sample is touching, max ~74) but short contacts, so it passes; each transport's runs are near-deterministic (the lobby's max is 73.7 again and again), so this depends on which encounters the bot paths produce, NOT on transport quality. Star with `--no-player-collision`: 4/4 green, p50 12-14, p95 <= 17.4, max <= 25. The lobby's 120 px max bound only holds because its encounters happen to be short | demo-side (finding 9's host stand-ins collide while owners pass through); DECIDED (Daniel, slice 6): the smoke runs with player-player collision off on both transports. FIXED in the goal run: [DECIDE M], demo 0e05a9c; the smoke runs with player contact ON again |
| 18 | goal run (finding 9 fix) | A stand-in at REST against a wall sticks there while its spring pulls it along the wall, until snap distance: Godot Physics 2D (4.7) friction holds a resting contact against far more tangential force than the (tiny) normal force allows. 3/18 runs failed (owner sliding along the bottom wall, stand-in frozen at v = 0 for 1+ s, target moving away at 270 px/s, not pressed into the wall). Isolated repro: can_sleep = false circle, PD force in _integrate_forces, resting on a StaticBody2D, target then slides along it: moves 6.5 px and sticks for good, sleeping = false, _integrate_forces runs every step; a per-frame mask write does not help; friction 0 on either body fixes it (combined as min) | demo-side FIXED bd92828: walls friction 0 (stand-ins and crate slide, as the owner controller does). Addon: worth a class-doc line on CouchPDFollower / StandIn-style bodies (a driven body touching static geometry should have friction 0, or it sticks) |
| 19 | latency run 2026-10-07 | Crate contact = finding 9's crate half. At 250 ms RTT, 7/18 star guests have max error 78-132 px, all 50-250 ms after a crate knock, no other stand-in within 84 px. The stand-in hits the real crate while its owner walks through it, and stays off its owner for a round trip until the knock arrives. The star shows it only because its bot paths reach the crate ~4x as often (35 crate knocks at 250 vs the lobby's 9) | demo-side; FIXED by [DECIDE N], demo 58dd282 (Daniel 2026-10-07) |
| 8 | slice 2 | Owner input lead settles at 8 ticks (133 ms) at ~100 ms RTT, host margin 3-4; more than one-way + margin suggests | investigate before step 2 (lead = system 2's input delay) |
