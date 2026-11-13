# Step 1 design: owner-authority helpers (CouchOwnedEntity + CouchPDFollower)

Repo: /home/daniel/Repositories/couch-games-sdk-godot. Branch `feat/owner-authority` from `main`
(after 0d, PR #24, merge 97cec46). Roadmap: `docs/plans/realtime-netcode-roadmap.md` step 1.
Carries over from `docs/plans/per-entity-authority-netcode.md` (host loop, PD spring with
velocity feed-forward and snap threshold, impulse events acked via input `"ev"`), generalised
from one guest to N input players (0b) and rebuilt on 0c (clock) and 0d (world, event ring).
STATUS: all decisions settled 2026-10-05 (Daniel). API contract below; freeze before build.

## System 1 in one paragraph

Each player simulates their own entity locally and is authoritative for its state. Every tick
they send that state in their `input`. The host keeps a STAND-IN for each remote player's
entity and drives it toward the reported state with a critically damped spring, so the host's
physics still resolves the stand-in's contacts (a player standing on a crate still pushes it).
The host is authoritative for everything else and broadcasts 0d snapshots that include every
stand-in, so players see each other through the host (the star has no guest-to-guest links).
When the host applies a one-off impulse to a player's entity (explosion, trampoline), it is
pushed to that player's CouchEventRing stream; the owner applies it to its real body and acks
via `"ev"`. No rewind anywhere; cheating is trivial and accepted (couch co-op).

## Scope

Pure data + math, no Nodes, no physics server, no transport, nothing reads Time -- same rule as
0c/0d, so everything is gateable headless. The game calls these from `_physics_process` /
`_integrate_forces`. CouchSession is untouched.

- Owner side (`CouchOwnedEntity`): build the owner-authority part of the input body each tick.
- Host side (`CouchOwnerTargets` -- name open): per-peer latest reported state, ownership map,
  staleness, target extrapolation.
- `CouchPDFollower`: the spring maths (2D: position + rotation), snap decision.

Out of scope: system 2 (prediction, CouchInputBuffer, redundant inputs), the demo (step 3),
3D, lag compensation, compensating the host's target for un-acked impulses (see [DECIDE G]).

## Wire (input body additions; host->client side is 0d unchanged)

```
input body (owner -> host, every owner tick):
  "t":  tick stamped by CouchNetClock.advance()   (already what 0c's echo keys on)
  "o":  PackedFloat32Array -- the owned entity's state in its 0d kind layout   [DECIDE B]
  "ev": CouchEventInbox.last_applied()            (0d)
```
The input carries NO entity id: the host maps sender peer -> owned entity ([DECIDE E]), so a
peer cannot drive someone else's entity. Snapshots stay exactly 0d's: the stand-in is an
ordinary entity in the host's CouchReplicatedWorld; each owner `set_local([my_entity_id])` so
its own entity is never interpolated over its real body.

## Decisions

### [DECIDE A] Do players collide with each other on the host?
[DECIDED 1, Daniel 2026-10-05: stand-ins are ordinary PD-driven bodies and collide normally on the host.
Many games will opt out of player-player collision via collision layers -- that is the game's
choice and needs nothing from the library; the library must not assume either way. Contacts reach
the shoved player only if the game turns them into impulse events.]
Each owner sees every other player as an interpolated kinematic body (it can be pushed by them,
cannot push them locally). On the host the stand-ins are real bodies.
1. **Recommended: stand-ins are ordinary PD-driven bodies and collide normally on the host.**
   A shove between players happens on the host; the shoved player feels it only if the game
   turns it into an impulse event (same rule as any contact: above a threshold -> event, below
   -> absorbed by the spring). Library stays agnostic; this is the demo's default.
2. Players never collide with each other (collision layers). Simplest and symmetric, but
   players walk through each other.
3. Collide, and the library auto-converts stand-in contact impulses into events. Needs physics
   callbacks inside the library -- breaks the "no physics" rule. Not recommended.

### [DECIDE B] What the owner sends
[DECIDED 1, Daniel 2026-10-05: the owner sends the entity's full 0d kind state (same layout as
snapshots, validated against the kind registry). The game passes a channel map once; channels
the follower does not use are ignored by it but still relayed in snapshots.]
1. **Recommended: the entity's full 0d kind state** (e.g. `[x, y, rot, vx, vy, w]`), validated
   against the same kind registry (stride + finite values). Velocity gives the spring a
   feed-forward term and lets the host extrapolate a late report; one layout serves input and
   snapshot.
2. Position + rotation only. Smaller input, but the host has to difference successive reports
   for velocity (noisy under jitter) and the spring lags.
Either way the follower needs to know which channels are position / rotation / velocity:
the game passes a small channel map once (`{"x":0,"y":1,"rot":2,"vx":3,"vy":4,"w":5}`).

### [DECIDE C] How the spring is tuned
[DECIDED 1, Daniel 2026-10-05: tune by settle time. CouchPDFollowerPolicy holds settle_ms (position),
rotation settle_ms, snap_distance, snap_angle, extrapolate_cap_ms (default 100); always critically
damped (w = 4.74 / settle_s, k = w^2, c = 2w). No damping_ratio knob in step 1 -- additive later.]
1. **Recommended: by settle time, not raw gains.** `settle_ms` (time to close ~95% of an
   error; critically damped, so error(t) = e0 * (1 + w t) * exp(-w t), which is 5% at
   w t ~= 4.74: w = 4.74 / settle_s, k = w^2, c = 2 w), separately for position and rotation, plus `snap_distance` (world units),
   `snap_angle` (radians) and `extrapolate_cap_ms` (default 100). Defaults chosen in the demo.
2. Raw `k` / `c` gains. More familiar to physics people, easy to make under/over-damped by
   accident.

### [DECIDE D] What the follower outputs
[DECIDED 1, Daniel 2026-10-05: step() returns desired linear + angular acceleration and a snap flag
(on snap: the target state to set directly); static helpers force_from(result, mass, inertia) for
RigidBody2D._integrate_forces and velocity_after(result, vel, w, dt) for kinematic/CharacterBody2D.]
1. **Recommended: desired linear + angular ACCELERATION and a snap flag.** Two tiny helpers
   turn it into what each body type wants: `force = accel * mass` (and torque = alpha * inertia)
   for `RigidBody2D._integrate_forces`, or `velocity += accel * dt` for a kinematic /
   CharacterBody2D. On snap: the target transform and velocity, to be set directly.
2. Return a new velocity only. Simpler, but a RigidBody2D then fights its own solver.

### [DECIDE E] Ownership and trust on the host
[DECIDED 1, Daniel 2026-10-05: host assigns ownership explicitly (set_owner / forget); accept only
from an owning peer, only a strictly newer "t", only a stride-correct all-finite "o"; otherwise trust
the report (no plausibility limits). Rejections counted per peer with a reason. Name CouchPDFollower
kept (Daniel). Moving-platform riding (platform-relative coords) is out of step 1 -- roadmap follow-up.]
1. **Recommended:** the host game assigns ownership explicitly
   (`targets.set_owner(peer_id, entity_id)` on `player_joined`, `forget(peer_id)` on
   `player_left`). An input is accepted only from a peer that owns an entity, only if its
   `"t"` is newer than that peer's last accepted tick (latest-wins; older/duplicate counted),
   and only if `"o"` matches the kind's stride and every value is finite. Otherwise the host
   TRUSTS the reported state -- no speed/teleport validation (couch co-op; the snap threshold
   already bounds what a bad report can do visually). Rejections counted per peer with a reason.
2. Same plus plausibility limits (max speed / max jump per tick). Defer unless the demo shows a
   need.

### [DECIDE F] What happens when a peer's reports stop
[DECIDED (variant), Daniel 2026-10-05: switchable via policy `stale_mode`. Extrapolate-then-hold
before stale_ms is identical in both modes. HOLD (default): once stale, target_for() returns the
held target with velocity channels zeroed, so the follower parks the stand-in as a solid body.
REPORT_ONLY: once stale, target_for() returns an EMPTY array and the game owns the stand-in.
is_stale() + stale counter in both modes. Visual handling (ghost/bubble/no-collide) stays in the
game -- the library touches no Nodes.]
The target is the last report extrapolated by its velocity for at most `extrapolate_cap_ms`,
then HELD (the stand-in comes to rest at the held target). After `stale_ms` (default 500) with
no report the peer is reported stale (`is_stale(peer)` / a counter) so the game can e.g. freeze
or ghost the stand-in. **Recommended:** the library only reports staleness; what the stand-in
does is the game's call.

### [DECIDE G] Impulses vs the host spring (rubber-band window)
[DECIDED split, Daniel 2026-10-05: remote (TURN / cross-city, 150-250 ms RTT) play is in scope, so
the rubber band WILL be fixed. Step 1 freezes the costly-to-change parts: the standard impulse
event payload, mass/inertia on set_owner (stored, unused in step 1), and an owner-side
apply-impulse helper. Step 1.1 (own gate G17) adds host-side compensation for un-acked impulses,
with the ack/report tick alignment as its review focus and before/after rubber-band measurement
at 50/150/250 ms under 0a.]
When the host knocks a stand-in, the spring pulls it back toward the owner's last (pre-impulse)
report until the owner has applied the event and its new reports arrive -- about one RTT of
visible rubber-band on the host and every spectator.
1. **Recommended for step 1: accept it, measure it in the demo with the 0a delay levers.**
   Keeps step 1 small. The fix is known and additive.
2. Fix now: the host shifts that peer's target by the predicted effect of each un-acked impulse
   (`dv = J / m`, `dx = dv * t`) until the peer's `"ev"` ack covers it. Requires the library to
   define an IMPULSE event payload convention and to know the body's mass.

## Proposed API (to be frozen after the decisions, like 0d's contract)

```
CouchOwnedEntity (owner)
  func _init(world: CouchReplicatedWorld, entity_id: int, kind: int)
  func input_fields(tick: int, state: PackedFloat32Array, inbox: CouchEventInbox) -> Dictionary
      # {"t", "o", "ev"} to merge into the game's input body; validates stride

CouchOwnerTargets (host)
  func set_owner(peer_id: String, entity_id: int, kind: int) -> bool
  func forget(peer_id: String) -> void
  func reset() -> void
  func note_input(peer_id: String, body: Dictionary, now_ms: int) -> bool   # false + reason if rejected
  func target_for(peer_id: String, now_ms: int) -> PackedFloat32Array        # extrapolated, capped
  func entity_of(peer_id: String) -> int
  func is_stale(peer_id: String, now_ms: int) -> bool
  counters per peer: accepted, stale_tick, malformed, unowned

CouchPDFollower
  func _init(channels: Dictionary, policy: CouchPDFollowerPolicy)
  func step(current: PackedFloat32Array, target: PackedFloat32Array) -> Dictionary
      # {"snap": bool, "accel": Vector2, "alpha": float}  or on snap {"snap": true, "state": target}
  static helpers: force_from(result, mass, inertia), velocity_after(result, vel, w, dt)
```

## Gate G16: netcode/fixtures/run_owner_authority.gd (draft cases)

Headless, deterministic, virtual time, seeded, like G13/G15. Owners' "physics" is a toy 2D
integrator in the fixture (no PhysicsServer: not deterministic, not available to a plain
SceneTree script in a gateable way).
- P1 follower maths: critically damped (no overshoot beyond a tolerance) and settles within
  settle_ms on a step error; velocity feed-forward makes a constant-velocity target tracked
  with bounded steady-state error; rotation takes the short arc across +/-PI; snap fires above
  the threshold and not below (exactly-at boundary pinned).
- P2 helpers: force/torque from mass/inertia; kinematic velocity integration.
- T1 targets: ownership (unowned sender rejected, cannot drive another peer's entity), stale /
  duplicate ticks counted not applied, malformed / non-finite / wrong-stride rejected with
  reasons, extrapolation by velocity then hold at the cap, staleness after stale_ms, forget /
  reset.
- O1 owner fields: `"t"`, `"o"` (a copy), `"ev"` from the inbox; wrong stride refused.
- S1 end-to-end: host + 3 owners as REAL CouchSessions (G13's scripted-roster/transport star
  harness, max_input_players 3) with seeded 0a-style delay/jitter/loss per link, CouchNetClock
  on each owner, CouchReplicatedWorld + ring/inbox from 0d. Owners move on scripted paths.
  Assert: every stand-in converges to its owner's true path within a bound once warm; a
  scripted host impulse to one owner is applied by that owner exactly once and acked (and by
  no one else); a teleport larger than snap_distance snaps the stand-in (one snap, no
  spring-induced overshoot after); each owner's own entity is never interpolated (set_local);
  other owners' sampled view of a moving player tracks the host stand-in within a bound.
- S2 player leaves (0b player_left) / rejoins: forget, new ownership, ids/ring continuity
  per 0d's forget rule; new epoch resets everything.

## Conventions (same as 0c/0d)

GDScript, tabs, `class_name Couch...`, RefCounted, typed, `##` contract docs, 4.4-4.7
compatible. Nothing in netcode/ references webrtc/ or lobby/. Gate-first (Sonnet writes G16 +
inert stubs, red run) -> separate Sonnet implements from the frozen contract -> Opus reviews +
mutation pass (`docs/plans/replicated-world-mutations.py` is the template) -> survivors get
cases -> full matrix -> long-form commit, no Claude trailers -> ask Daniel before push/PR.

## API contract (frozen 2026-10-05 for the gate writer and the implementer)

Where this section and the prose above differ, THIS section wins. New files under `netcode/`
plus ONE additive method on CouchReplicatedWorld (`kind_channels`); nothing else changes except
new `.uid` files from import. Same rules as 0d: RefCounted, typed, tabs, `##` docs, 4.4-4.7,
nothing references `webrtc/`, `lobby/`, Nodes, a physics server, or Time. Peer ids are
`String`, ticks `int`, wall time `now_ms: int` passed in by the caller.

### Files and classes
- `netcode/body_channels.gd` -- `class_name CouchBodyChannels extends RefCounted`.
- `netcode/pd_follower_policy.gd` -- `class_name CouchPDFollowerPolicy extends RefCounted`.
- `netcode/pd_follower.gd` -- `class_name CouchPDFollower extends RefCounted` (host).
- `netcode/owner_targets.gd` -- `class_name CouchOwnerTargets extends RefCounted` (host).
- `netcode/owned_entity.gd` -- `class_name CouchOwnedEntity extends RefCounted` (owner).
- `netcode/fixtures/run_owner_authority.gd` -- gate G16, `extends SceneTree`, same style as
  `run_replicated_world.gd` (deterministic, seeded, no await, no Time reads, `_check`, one
  `quit()` then `return`). Final line on success: `G16 owner authority: N/N checks passed`;
  exit 0 iff no failures; each failed check prints a line containing `FAIL:`.

### CouchReplicatedWorld addition (additive, 0d otherwise untouched)
```
func kind_channels(kind: int) -> Array   # COPY of the registered channel list; [] if unregistered
```

### Reserved event kind and impulse payload (frozen now; host compensation is step 1.1)
- `CouchOwnedEntity.IMPULSE_EVENT_KIND := -1`. Negative event kinds are reserved for the library;
  games use kinds >= 0 (documented on CouchEventRing's push as well -- doc comment only).
- Payload: `PackedFloat32Array([jx, jy, aj])` -- linear impulse (world units, applied at the
  centre of mass) and angular impulse. Pushed ONLY via `CouchOwnerTargets.push_impulse`.
- ALIGNMENT RULE (what 1.1 depends on; game wiring, documented, exercised by G16 S1): an input
  body's `"o"` is the owned state AFTER the owner has applied every event with id <= that same
  body's `"ev"`. I.e. per owner tick: receive + apply events, step physics, THEN input_fields().

### CouchBodyChannels
```
func _init(map: Dictionary) -> void     # keys "x","y","vx","vy" required; "rot","w" optional, both or neither
func is_valid() -> bool
func fits(kind_channels: Array) -> bool
var x: int; var y: int; var vx: int; var vy: int
var rot: int; var w: int                 # -1 when absent
func has_rotation() -> bool
```
`is_valid`: every present value is an int >= 0, all present indices distinct, required keys
present, `rot`/`w` both present or both absent, no other keys. Invalid -> every index -1.
`fits(ch)`: is_valid, every index < ch.size(), `ch[x]`,`ch[y]`,`ch[vx]`,`ch[vy]` (and `ch[w]`)
== LERP, and `ch[rot]` == ANGLE when present.

### CouchPDFollowerPolicy
```
const SETTLE_K := 4.74          # critically damped: e(t)=e0(1+wt)e^-wt is 5% at wt=4.74
const MAX_W_DT := 0.5           # stability clamp for a symplectic-Euler body (no overshoot to ~0.7)
var settle_ms: float = 150.0
var rot_settle_ms: float = 100.0
var snap_distance: float = 256.0  # world units; snap iff error >  this
var snap_angle: float = PI        # radians;     snap iff |error| > this (PI = never)
```

### CouchPDFollower (host)
```
func _init(channels: CouchBodyChannels, policy: CouchPDFollowerPolicy, physics_dt: float) -> void
func omega() -> float          # = min(SETTLE_K / (settle_ms/1000), MAX_W_DT / physics_dt)
func rot_omega() -> float      # same with rot_settle_ms
func effective_settle_ms() -> float      # SETTLE_K / omega() * 1000
func effective_rot_settle_ms() -> float
var bad_input_count: int
func step(current: PackedFloat32Array, target: PackedFloat32Array) -> Dictionary
static func force_from(result: Dictionary, mass: float, inertia: float) -> Dictionary
static func velocity_after(result: Dictionary, vel: Vector2, ang_vel: float, dt: float) -> Dictionary
```
Policy values are read at each `step` (so a policy edit takes effect next step); omega uses
`settle_ms` clamped to >= 1.0. `physics_dt <= 0` -> treated as 1/60.

`step`: every result has `"snap": bool, "accel": Vector2, "alpha": float`.
1. `target` empty -> `{snap:false, accel:ZERO, alpha:0.0}` (no counter: normal before the
   first report and in REPORT_ONLY).
2. `current.size() != target.size()` or either has a channel index out of range or a
   non-finite used value -> same zero result, `bad_input_count += 1`.
3. `ep = Vector2(t[x]-c[x], t[y]-c[y])`, `er = wrapf(t[rot]-c[rot], -PI, PI)` (0 without rotation).
   Snap iff `ep.length() > snap_distance` or `abs(er) > snap_angle` -> result also has
   `"state"` (COPY of target), `"pos"`, `"vel"` (Vector2), `"rot"`, `"w"` (floats; 0.0 when
   no rotation); accel ZERO, alpha 0.0.
4. Else `w = omega()`: `accel = w*w*ep + 2*w*(Vector2(t[vx],t[vy]) - Vector2(c[vx],c[vy]))`;
   with rotation `wr = rot_omega()`: `alpha = wr*wr*er + 2*wr*(t[w]-c[w])`, else 0.0.
`force_from`: `{"force": accel*mass, "torque": alpha*inertia}` (zeros on snap).
`velocity_after`: not snap -> `{"linear": vel + accel*dt, "angular": ang_vel + alpha*dt}`;
snap -> `{"linear": result.vel, "angular": result.w}`.

### CouchOwnerTargets (host)
```
const HOLD := 0
const REPORT_ONLY := 1
var extrapolate_cap_ms: int = 100
var stale_ms: int = 500
var stale_mode: int = HOLD
func _init(world: CouchReplicatedWorld) -> void   # kind registry source; never mutates world
func set_channels(kind: int, channels: CouchBodyChannels) -> bool   # false unless channels.fits(world.kind_channels(kind)); replaces
func set_owner(peer_id: String, entity_id: int, kind: int, mass: float, inertia: float, now_ms: int) -> bool
func forget(peer_id: String) -> void
func reset() -> void
func note_input(peer_id: String, body: Variant, now_ms: int) -> bool
func target_for(peer_id: String, now_ms: int) -> PackedFloat32Array
func is_stale(peer_id: String, now_ms: int) -> bool
func entity_of(peer_id: String) -> int     # -1 if not an owner
func mass_of(peer_id: String) -> float     # 0.0 if not an owner
func inertia_of(peer_id: String) -> float
func push_impulse(ring: CouchEventRing, peer_id: String, impulse: Vector2, angular: float, host_tick: int) -> int
func accepted_count(peer_id: String) -> int
func reject_count(peer_id: String, reason: String) -> int
func last_reject_reason(peer_id: String) -> String
func stale_gap_count(peer_id: String) -> int
```
**set_owner**: false (no change) if `set_channels` not done for `kind`, `entity_id` outside
[0, 2^31-1], another peer already owns `entity_id`, `mass` not finite or <= 0, `inertia` not
finite or < 0. Re-calling for the same peer replaces ownership and clears its report state
(last tick, report, staleness clock restarts at `now_ms`). Counters persist until forget/reset.
**forget(peer)**: drops ownership, report, last accepted tick and the peer's counters (a
rejoining client's clock restarts, so its ticks must be accepted again).
**reset()** (new epoch): everything except `set_channels` registrations and the policy vars.

**note_input** -- validation IN THIS ORDER, first failure wins; a rejection changes NO state
except `reject_count(peer, reason) += 1` and `last_reject_reason(peer)`:
1. `peer_id` owns no entity                                     -> `"unowned"`
2. body not a Dictionary; `"t"` missing / not int; `"o"` missing / not PackedFloat32Array
                                                                 -> `"bad-shape"`
3. `o.size() != stride(kind)`                                    -> `"bad-stride"`
4. any value of `o` non-finite                                   -> `"non-finite"`
5. a tick was accepted from this peer since set_owner and `t <= ` it  -> `"stale-tick"`
Accept: store a COPY of `o`, last tick = t, report time = now_ms; if
`now_ms - previous_report_or_owner_ms > stale_ms` -> `stale_gap_count += 1`;
`accepted_count += 1`; return true. `"ev"` is ignored here (game does `ring.ack`).

**target_for(peer, now)** -> a NEW array each call: empty if not an owner or no report since
set_owner. Else `age = now - report_ms` (clamped >= 0):
- `is_stale` and `stale_mode == REPORT_ONLY` -> empty.
- `age <= extrapolate_cap_ms` -> report with `x += vx*age/1000`, `y += vy*age/1000`, and with
  rotation `rot = wrapf(rot + w*age/1000, -PI, PI)`; velocity channels as reported; other
  channels as reported.
- `age > extrapolate_cap_ms` (includes HOLD-stale) -> same with `age = extrapolate_cap_ms`, and
  `vx`, `vy` (and `w`) set to 0.0.
**is_stale(peer, now)**: owner and `now - (report_ms if any report else owner_ms) > stale_ms`;
false for non-owners.
**push_impulse**: -1 (nothing pushed) if peer not an owner or any value non-finite; else
`ring.push(peer, IMPULSE_EVENT_KIND, PackedFloat32Array([impulse.x, impulse.y, angular]), host_tick)`.

### CouchOwnedEntity (owner)
```
const IMPULSE_EVENT_KIND := -1
func _init(world: CouchReplicatedWorld, entity_id: int, kind: int) -> void
var refused_count: int
func input_fields(tick: int, state: PackedFloat32Array, inbox: CouchEventInbox) -> Dictionary
static func impulse_of(event: Variant) -> Dictionary
```
`input_fields`: `state.size() != stride(kind)` (or kind unregistered) or any non-finite value
-> `{}`, `refused_count += 1`. Else `{"t": tick, "o": COPY of state, "ev": inbox.last_applied()}`
(`"ev"` = 0 when inbox is null). The game merges these into its own input body.
`impulse_of(event)`: event is `[id, kind, payload]` from `CouchEventInbox.receive`; returns
`{"j": Vector2, "a": float}` iff kind == IMPULSE_EVENT_KIND and payload is a
PackedFloat32Array of size 3 with finite values; else `{}`.

### Game wiring (class `##` docs, not library code)
Host setup: `targets.set_channels(PLAYER_KIND, CouchBodyChannels.new({...}))`; on player_joined
`targets.set_owner(peer, eid, PLAYER_KIND, mass, inertia, now)` + `world.set_entity(eid, ...)`;
on player_left `targets.forget(peer)`, `ring.forget(peer)`, `world.remove_entity(eid)`.
Host on input: `ring.ack(peer, int(body.get("ev", 0))); targets.note_input(peer, body, now)`.
Host per physics step per stand-in: `r = follower.step(state_of(body), targets.target_for(peer, now))`
then snap -> set transform/velocities, else `force_from` (RigidBody2D) or `velocity_after`
(kinematic); then `world.set_entity(eid, kind, state_of(body))` before `pack`.
Host knock: `targets.push_impulse(ring, peer, J, aj, host_tick)`.
Owner per tick: on snapshot `for e in inbox.receive(ps.ev): var imp = CouchOwnedEntity.impulse_of(e)`
-> `body.apply_central_impulse(imp.j)`, `apply_torque_impulse(imp.a)`; step physics; then
`input.merge(owned.input_fields(t, state_of(body), inbox))`. `world.set_local([my_eid, ...])`.
The host's own player is just a local entity on the host (no targets entry).

### G16 additions from the contract (on top of the draft cases above)
- P1: omega clamp -- with physics_dt 1/60 a 50 ms settle_ms is clamped (omega == 30) and the toy
  symplectic integrator neither diverges nor overshoots; unclamped values match the formula.
- C1: CouchBodyChannels validity + `fits` against LERP/ANGLE layouts; `kind_channels` returns a copy.
- T1: every reject reason in order (one case per step, plus first-failure-wins pairs); HOLD vs
  REPORT_ONLY; staleness clock starts at set_owner; stale_gap_count; entity owned twice refused.
- I1: push_impulse payload/kind exact; impulse_of round-trip and refusals; S1's owners obey the
  alignment rule and the knocked owner applies the impulse exactly once.
