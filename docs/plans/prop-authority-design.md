# Prop authority in the addon (Rev 3 step 3)

Status: DESIGN rev 1 APPROVED (Daniel, 2026-10-08). Design #31 and host slice A1 #32
merged; addon main is `233d6d1`. Owner slice A2 is implemented, verified and published as
[PR #33](https://github.com/animo-games/couch-games-sdk-godot/pull/33) on
`feat/prop-authority-owner` (verified code commit `664c364`), worktree
`~/Repositories/addon-prop-owner`. All decisions taken: P1-P3 and P5-P7 as recommended;
P4 dropped for now with the API shaped so the fix is additive. The API contract is frozen.
Next: review and merge A2; then demo port B1. Daniel requested discussion of next work.

Summary. The netcode demo's crate ownership (`CrateAuthority` on the host, `CratePrediction` on
each guest) moves into the addon as two pure `RefCounted` classes: `CouchPropAuthority` (host:
who simulates each prop, grants, releases, take-backs, the host hold, press routing, the
snapshot section) and `CouchPropController` (owner: when to claim, when a claim was granted or
lost, when to release, press spreading, and the pose to draw). Both handle any number of props,
keyed by entity id. The game keeps the bodies: it owns the `RigidBody2D`s, decides when its player
is near a prop, and computes presses from contacts. The addon returns decisions (CLAIM, RELEASE,
"apply this press now", "follow this target") and never touches a body. The first addon slices are
behaviour-identical to the demo; the demo then becomes a thin consumer, and open items 1, 3, 4, 5
and 6 from Rev 3 step 2 land as their own small PRs, each with a gate. Item 2 (host-acknowledged
release) is dropped for now ([DECIDE P4]). This doc lands on its own as a docs PR
before any code.

## Problem and goal

Rev 3 step 1 (demo b4d5ea3, still current at demo HEAD 4af9e66) proved owner authority with
handoff for one crate, all in demo code. Daniel's rule (2026-10-08): no more demo-only code
unless it is needed to test addon code and is easily ported. So the crate logic moves into the
addon as a general API for **pushable props** any game can use. The demo stays the test bed: its
smoke gates and mutants are the evidence.

### The rule (Rev 3, Daniel-approved, `authority-handoff-design.md` "Rev 3")

Every controller is always solid against the prop as drawn on its own screen. Exactly one peer
simulates a prop. Anyone else's push is a per-tick **press** forwarded to the simulator: never an
ownership change, never a knock. Owner authority with handoff, paying with delayed response,
never walking through.

### What moves and what stays

| Moves to the addon | Stays in the game (demo) |
|---|---|
| Owner per prop: grant, host hold, host let-go, release, stale and leave take-back | The `RigidBody2D`s (`Crate`, `CratePuppet`), their shapes, mass, damping, layers |
| Claim rule, grant detection, denial and backoff, settled release (owner) | "Near": the player-to-prop gap and `CLAIM_MARGIN` |
| Claim-time extrapolation of the newest snapshot to the owner tick | Press computation from contacts (`PlayerController._add_press`) |
| Press routing (apply now, or sum for the owner), press spreading on the owner | Applying a press to a body (`apply_central_impulse` + `apply_torque_impulse`) |
| Wire keys and validation for claims, presses and the owner section | The PD follow inside `_integrate_forces` (it uses `CouchPDFollower`, already in the addon) |
| The drawn pose (release blend; from slice C the decaying offset) | Every metric: `CratePenetration`, `CrateWallDepth`, `PuppetMotion`, `StandIn`, `DemoNet`, smoke traces |

The physics-body recipe (static puppet, `body_set_state` on claim, `can_sleep`, the controller
layer toggle) is documented in the class docs as gotchas, not wrapped in a Node (Nodes are banned
in `netcode/`, untestable headless, and 2D-only).

## API contract (frozen on approval)

Where this section and the prose elsewhere differ, THIS section wins. Same rules as the step 1
contract: new files under `netcode/`, `RefCounted`, typed, tabs, `##` contract docs, Godot 4.4-4.7,
nothing references `webrtc/`, `lobby/`, Nodes, a physics server or `Time`. Peer ids are `String`,
ticks `int`, wall time `now_ms: int` passed in. Nothing in `couch_session.gd` changes; the classes
are wired by the game, like `CouchOwnerTargets`.

### Files
- `netcode/prop_authority.gd`: `class_name CouchPropAuthority extends RefCounted` (host).
- `netcode/prop_controller.gd`: `class_name CouchPropController extends RefCounted` (owner).
- `netcode/fixtures/run_prop_authority.gd`: gate G18, `extends SceneTree`.
- `docs/plans/prop-authority-mutations.py`: the mutation script.
- Doc-only additions: one line in `owned_entity.gd`'s header and one on
  `CouchReplicatedWorld.pack`'s `extra` parameter, reserving the keys below.

### Wire keys (constants on CouchPropAuthority, read by both classes)
```gdscript
const INPUT_CLAIMS := "p"     # input: {eid: {"t": int, "o": PackedFloat32Array}}
const INPUT_PRESSES := "pr"   # input: {eid: PackedFloat32Array([jx, jy, aj])}
const EXTRA_KEY := "pp"       # snapshot extra: {eid: {"ow": String, "pr": PackedFloat32Array}}
const EXTRA_OWNER := "ow"
const EXTRA_PRESS := "pr"
```

### CouchPropAuthority (host)
```gdscript
## Host let-go: the host's own player stops holding a prop this long after it was last near it.
var release_idle_ms: int = 300
var grants: int = 0             # guest claims granted
var releases: int = 0           # guest owners that released (an input without the prop's claim)
var takebacks: int = 0          # guest owners that went stale or left
var presses_forwarded: int = 0  # owner entries in take_snapshot_extra() that carried a press
var bad_presses: int = 0        # malformed INPUT_PRESSES entries ignored
var refused_claims: int = 0     # slice D: claims ignored after a take-back (item 5)

func _init(world: CouchReplicatedWorld, host_id: String) -> void
func set_channels(kind: int, channels: CouchBodyChannels) -> bool
func add_prop(entity_id: int, kind: int, mass: float, inertia: float) -> bool
func remove_prop(entity_id: int) -> void
func owner_of(entity_id: int) -> String
func is_guest_owned(entity_id: int) -> bool
func update(entity_id: int, host_near: bool, now_ms: int) -> Dictionary   # {eid: Vector3} recovered presses
func on_input(peer_id: String, body: Dictionary, now_ms: int) -> Dictionary
func apply_now(entity_id: int, press: Vector3) -> bool   # true = the caller applies the press now
func target_for(entity_id: int, now_ms: int) -> PackedFloat32Array
func take_snapshot_extra() -> Dictionary
func forget(peer_id: String) -> Dictionary                                # {eid: Vector3} recovered presses
static func press_of(field: Variant) -> Vector3
```
- **_init**: `world` is read only (kind registry). `host_id` is the host's own peer id; it is the
  owner while the host's player holds a prop.
- **set_channels**: as `CouchOwnerTargets.set_channels`; false unless the channels fit the world's
  registered layout for `kind`. Replaces.
- **add_prop**: false (no change) if the kind has no channels, `entity_id` is outside
  [0, 2^31-1] or already added, or mass/inertia fail `CouchOwnerTargets.set_owner`'s rules. A new
  prop is free (owner ""). Internally each prop gets its OWN `CouchOwnerTargets` (channels for its
  kind, `impulse_compensation = false`, other tuning at defaults: `stale_ms` 500,
  `extrapolate_cap_ms` 100, `HOLD`), so a prop has at most one owner and a peer may own several.
- **remove_prop**: drops the prop and its sums. Unknown id: no-op.
- **owner_of**: "" = free and host-simulated; `host_id` = the host's player holds it; else the
  guest that owns it. "" for an unknown id.
- **is_guest_owned**: `owner_of(eid)` is neither "" nor `host_id`.
- **Recovered presses** (item 2, [DECIDE P4]). Every host call through which a release, take-back
  or forget can happen (`update`, `forget`, `on_input`) returns presses for the game to apply NOW,
  in one shape: `Dictionary` int eid -> `Vector3`, applied with the same call the game uses for
  `apply_now` presses. They are "presses recovered at a release; empty until item 2 is built": in
  slices A-D `update` and `forget` always return `{}`, and `on_input` returns only its routed
  presses. Slice E fills them without changing any signature. Class docs state the limit until
  then: presses forwarded within one round trip plus one snapshot interval of a release under
  press are lost (~280 ms at 250 ms RTT; on every transfer once item 1 lands).
- **update** (once per physics tick per prop, before the host's player steps; returns recovered
  presses, `{}` until item 2), in this order:
  1. guest-owned and the owner is stale (`CouchOwnerTargets.is_stale`): take back (`takebacks += 1`,
     owner "", the inner targets forget the peer; slice D also marks the refusal, item 5).
  2. `host_near` (the game's gap < `CLAIM_MARGIN`, not actual contact): note the time; a free
     prop becomes host-held.
  3. else host-held and `now_ms - last host contact >= release_idle_ms`: free. No settle wait.
- **on_input** (every input the game accepted from a remote player; after the player ring ack and
  `driver.on_input`, as today): returns `{eid: Vector3}`, the presses the game must apply to its
  bodies NOW: the routed presses of step 3, plus (from slice E only) presses recovered at a
  release in step 1, summed per eid into the same Dictionary. Processing order:
  1. Releases. Let `claims = body.get("p")`, or `{}` if that is not a Dictionary. Every prop
     owned by `peer_id` whose eid is not a key of `claims` is released (`releases += 1`, owner "",
     the inner targets forget the peer).
  2. Claims, for each key of `claims` that is an int naming an added prop: free (and, from slice D,
     not refused for this peer) -> `set_owner` then `note_input` on that prop's targets; granted
     (`grants += 1`, owner = peer) only if both succeed, otherwise the targets forget the peer and
     nothing changes. A rejected first report is not a denial: the owner's next input claims
     again (no backoff; `set_owner` resets the accepted tick, so "stale-tick" cannot reject a
     first report). Owned by `peer_id` -> `note_input` (rejections only count inside the targets).
     Held by anyone else, host included: ignored.
  3. Presses, for each entry of `body.get("pr")` if a Dictionary: key not an int naming an added
     prop, or value not a `PackedFloat32Array` of size 3 with finite values -> `bad_presses += 1`,
     skipped. A valid zero press is skipped silently. Else `apply_now(eid, press)`; true -> add
     it to the returned Dictionary.
- **apply_now** (the host's own presses, and on_input's; the bool reads "apply it now?"): guest-owned -> add to that prop's sum
  for its current owner (a sum collected for a previous owner is discarded first) and return false.
  Free or host-held -> return true: the caller applies it now. Unknown id: false.
- **target_for**: empty while the host simulates the prop (free or host-held, or unknown id); else
  the owner's report extrapolated by the inner `CouchOwnerTargets.target_for(owner, now_ms)`. Empty
  if and only if `not is_guest_owned(eid)`.
- **take_snapshot_extra** (exactly once per snapshot sent; it consumes the sums): `{}` when no prop
  is held; else `{"pp": {eid: {"ow": owner}}}` for every held prop (guest- or host-held), with
  `"pr": PackedFloat32Array([jx, jy, aj])` added when that prop's sum is non-zero and was collected
  for its current owner (`presses_forwarded += 1`). Every sum is then cleared. Free props are left
  out: a missing prop means free.
- **forget** (player_left): every prop the peer owns is taken back (`takebacks += 1`, owner "").
  Returns recovered presses, `{}` until item 2.
  Slice D also marks the refusal (item 5).
- **press_of**: `PackedFloat32Array` of size 3 with finite values -> `Vector3(jx, jy, aj)`; anything
  else -> `Vector3.ZERO`. Used for input presses and, on the owner, snapshot presses.

### CouchPropController (owner)
```gdscript
const NONE := 0
const CLAIM := 1
const RELEASE := 2

var release_idle_ms: int = 300      # own contact gap before a settled (or, slice C, transfer) release
var settle_speed: float = 10.0      # units/s: the copy must be slower than this to release
var release_match: float = 1.0      # units: the sample must show the prop this close to the copy
var blend_ms: int = 100             # slices A-B: release blend; replaced in slice C (see below)
var extrapolate_cap_ms: int = 250   # claim: newest snapshot advanced by at most this
var claim_grace_ms: int = 150       # slack before an unanswered claim is given up
var claims: int = 0
var releases: int = 0               # every RELEASE decision
var denials: int = 0                # RELEASE for "lost", "taken-back" or "unanswered"
var presses_applied: int = 0        # snapshots whose forwarded press was queued

func _init(world: CouchReplicatedWorld, my_id: String, physics_dt: float) -> void
func set_channels(kind: int, channels: CouchBodyChannels) -> bool
func add_prop(entity_id: int, kind: int) -> bool
func remove_prop(entity_id: int) -> void
func on_snapshot(extra: Dictionary, snapshot_ticks: int, now_ms: int) -> void
func update(entity_id: int, near: bool, copy: PackedFloat32Array, tick: int, now_ms: int, rtt_ms: float) -> Dictionary
func drain_press(entity_id: int) -> Vector3
func input_fields(tick: int, copies: Dictionary, presses: Dictionary) -> Dictionary
func render_pose(entity_id: int, sample_pos: Vector2, sample_rot: float, copy_pos: Vector2, copy_rot: float, now_ms: int) -> Dictionary
func owner_of(entity_id: int) -> String
func is_predicting(entity_id: int) -> bool
func is_blending(entity_id: int) -> bool
```
Slice C adds (and removes `blend_ms`):
```gdscript
var transfer_gap_ms: int = 100       # forwarded presses closer than this are one continuous run
var offset_tau_ms: int = 100         # decay time constant of the claim and release offsets
var offset_max_speed: float = 150.0  # units/s: an offset never closes faster than this
var transfers: int = 0               # RELEASE for "transfer"
```
- **_init**: `world` is the owner's replicated world (read: `latest`, `kind_channels`).
  `physics_dt` converts ticks to seconds.
- **set_channels / add_prop**: as on the host; `add_prop` false if the kind has no channels or the
  id is already added. Call `add_prop` on `entity_spawned`, `remove_prop` on `entity_despawned`.
- **on_snapshot** (after EVERY accepted `world.ingest`, with `world.extra()`; until the first
  call `snapshot_ms` is 0, which makes the "unanswered" rule stricter): for every added prop,
  owner = `extra["pp"][eid]["ow"]` if present, else "". If that owner is `my_id` and the prop is
  predicted, a non-ZERO `press_of(entry["pr"])` is queued: `left += press`, `ticks_left =
  snapshot_ticks`, `presses_applied += 1`. Otherwise the press is dropped. Stores
  `snapshot_ms = int(snapshot_ticks * physics_dt * 1000.0)` for `update`. `now_ms` is used from
  slice C (press runs for the transfer rule).
- **update** (once per owner tick per prop, after applying inbox events and BEFORE the player
  steps). `copy` is the body's state in the kind's layout (the frozen puppet's pose when not
  predicting). Returns `{"action": int, "state": PackedFloat32Array, "reason": String}`; `state`
  is empty except on CLAIM, `reason` is "" except on RELEASE. The state machine is below.
- **drain_press** (once per owner tick, after `update`): `ticks_left == 0` -> ZERO. Else returns
  `left / ticks_left`, subtracts it from `left`, and `ticks_left -= 1`. The game applies it to the
  predicted copy.
- **input_fields** (after the player steps; merge into the input body next to
  `CouchOwnedEntity.input_fields`): `copies` is `{eid: state}` for at least every predicted prop;
  `presses` is `{eid: Vector3}` of this tick's presses. Returns `{"p": {eid: {"t": tick, "o":
  copy of state}}}` for predicted props (slice C: the state plus the claim offset, see item 3), plus `"pr": {eid: PackedFloat32Array([x, y, z])}` for
  non-ZERO presses on props this peer does NOT predict; each key only when non-empty; `{}` when
  both are. Presses on predicted props are left out: the game applies those to its copy itself.
- **render_pose** (once per render frame per prop): returns `{"pos": Vector2, "rot": float}`, the
  pose to DRAW. Predicted: exactly the copy's pose (the body is what is drawn, in every slice).
  Not predicted: the sample, blended out of the last prediction (slice A: `lerp` / `lerp_angle`
  from the copy pose at release to the sample over `blend_ms`; slice C: the decaying release
  offset). The game puts the frozen body there, so drawn = solid. It also remembers the sample
  for the settled-release rule and the last drawn pose (slice C claims there).
- **owner_of**: the newest snapshot's owner of the prop, "" when free or unknown.
- **is_predicting**: this peer simulates its copy (between CLAIM and RELEASE).
- **is_blending**: the drawn puppet is not yet purely the sample (the release blend). The slice C
  claim offset lives in the report, not the drawing, so it does not count.

### What the game computes: presses

A press is the momentum the player's controller loses against a prop, at the contact: with `n` the
contact normal (from the prop toward the player) and `v` the controller's velocity BEFORE the
slide, `into = -v.dot(n)`; when `into > 0`, `j = -n * into * player_mass` and the press is
`Vector3(j.x, j.y, (contact_point - prop_centre).cross(j))`. Presses add up by plain vector sum.
The game keys them by entity id: its controller sums per collider (the demo's `PlayerController`
gets `_presses: Dictionary` collider -> Vector3 and `take_presses()`), and the role maps each
collider to its `entity_id` (both prop body scripts carry `var entity_id: int`). Host: each entry
goes to `apply_now`. Owner: entries on predicted props are applied to the copy, all are passed to
`input_fields`, which keeps only the others.

### Consumer sketch: host (what a third-party dev writes)
```gdscript
# setup
props = CouchPropAuthority.new(world, my_id)
props.set_channels(CRATE_KIND, crate_channels)
props.add_prop(crate.entity_id, CRATE_KIND, Crate.MASS, Crate.INERTIA)

func _physics_process(_d):
	var now := Time.get_ticks_msec()
	for eid in crates:
		apply_all(props.update(eid, gap(crates[eid], me.position) < CLAIM_MARGIN, now))   # {} until item 2
		crates[eid].set_followed(props.is_guest_owned(eid))   # can_sleep + controller layer (gotchas)
	me.step(read_input(), DT)
	var presses := me.take_presses()
	for body in presses:
		if props.apply_now(body.entity_id, presses[body]):
			apply_press(body, presses[body])
	# ... world.set_entity(...) for every crate, then per snapshot:
	extra.merge(props.take_snapshot_extra())

# Crate._integrate_forces: var t := props.target_for(entity_id, now); if not t.is_empty(): PD-follow t

func _on_input(body: Dictionary, sender: String) -> void:
	# ... ring.ack, driver.on_input (reject -> return), acks, echo, as today
	var now := Time.get_ticks_msec()
	apply_all(props.on_input(sender, body, now))

func _on_player_left(peer: String, _slot: int) -> void:
	apply_all(props.forget(peer))   # {} until item 2

func apply_all(presses: Dictionary) -> void:   # eid -> Vector3, same call as apply_now presses
	for eid in presses:
		apply_press(crates[eid], presses[eid])
```

### Consumer sketch: owner
```gdscript
# setup
ctl = CouchPropController.new(world, my_id, DT)
ctl.set_channels(CRATE_KIND, crate_channels)
# entity_spawned(eid, CRATE_KIND): ctl.add_prop(eid, CRATE_KIND); despawned: ctl.remove_prop(eid)

func _on_snapshot(body: Dictionary) -> void:
	if world.ingest(body):
		ctl.on_snapshot(world.extra(), snapshot_every, Time.get_ticks_msec())

# per owner tick, after applying inbox events, before the player steps
for eid in crates:
	var c: CratePuppet = crates[eid]
	var d := ctl.update(eid, gap(c, me.position) < CLAIM_MARGIN, c.state(), tick, now, clock.rtt_ms)
	if d["action"] == CouchPropController.CLAIM:
		c.claim(d["state"])          # unfreeze + body_set_state + velocities (gotchas)
	elif d["action"] == CouchPropController.RELEASE:
		c.freeze = true              # back to a STATIC puppet
	apply_press(c, ctl.drain_press(eid))
me.step(read_input(), DT)
var presses := by_eid(me.take_presses())
for eid in presses:
	if ctl.is_predicting(eid):
		apply_press(crates[eid], presses[eid])
var fields := owned.input_fields(tick, me.state(), inbox)
if not fields.is_empty():
	fields.merge(ctl.input_fields(tick, states_of(crates), presses))
	session.send_input(fields)

# per render frame
var p := ctl.render_pose(eid, Vector2(st[0], st[1]), st[2], c.position, c.rotation, now)
if not ctl.is_predicting(eid):
	c.position = p["pos"]; c.rotation = p["rot"]    # frozen STATIC body = what is drawn
# while predicting physics moves the body and it is drawn as is: no visual offset, ever
```

### Physics-body recipe (class `##` docs, "observed on Godot 4.7")
1. **Owner puppet: freeze STATIC, not KINEMATIC.** A frozen kinematic body went to sleep on the
   controller's first contact (`can_sleep = false` did not help) and stopped taking node moves:
   guests walked 45.8 px into it. A static body takes every node move at once and still blocks the
   controller.
2. **On CLAIM:** set `transform`, `freeze = false`, then ALSO
   `PhysicsServer2D.body_set_state(rid, BODY_STATE_TRANSFORM, xf)`, then `linear_velocity` and
   `angular_velocity` from the state. Without the server write a jump back was seen once.
3. **On RELEASE:** `freeze = true` (STATIC); `render_pose` places it from then on.
4. **Host follower:** while guest-owned set `can_sleep = false` and `sleeping = false` (a sleeping
   body gets no `_integrate_forces`: a settled crate ignored a 300 px target move); restore
   `can_sleep` when the host simulates it again. Snap inside `_integrate_forces` only.
5. **Host controller layer:** while a guest owns the prop, drop the controller layer from the
   prop's collision MASK (the host's controller is still blocked by it and presses it; the prop is
   not shoved off its owner's path). Restore when the host simulates it.
6. **Same body everywhere:** mass, explicit inertia, damping and shape equal on the host's body
   and every owner copy; zero gravity and frictionless walls as the demo uses.
7. **Skip zero presses:** `apply_central_impulse(Vector2.ZERO)` still wakes a sleeping body.

## Wire format

| Direction | Key | Type | When |
|---|---|---|---|
| owner -> host input | `"t"`, `"o"`, `"ev"` | as `CouchOwnedEntity` | unchanged |
| owner -> host input | `"p"` | `Dictionary` int eid -> `{"t": int, "o": PackedFloat32Array}` | every tick, for every prop this peer predicts; a prop's absence releases it |
| owner -> host input | `"pr"` | `Dictionary` int eid -> `PackedFloat32Array` size 3 `[jx, jy, aj]` | ticks with a non-zero press on a prop this peer does not predict |
| host -> all snapshot `"x"` | `"pp"` | `Dictionary` int eid -> `{"ow": String, "pr"?: PackedFloat32Array size 3}` | every snapshot with at least one held prop; free props absent |

- **Validation (host, untrusted input).** `"p"` not a Dictionary counts as no claims. A claim key
  that is not an int naming an added prop is ignored. A claim value goes to
  `CouchOwnerTargets.note_input` unchanged (its order: unowned, bad-shape, bad-stride, non-finite,
  stale-tick). `"pr"` not a Dictionary is ignored; each bad entry (key not an added prop's int id,
  value not a finite size-3 `PackedFloat32Array`) counts in `bad_presses`.
- **Snapshot (owner, trusted host).** Read with `get` and defaults; presses go through `press_of`.
- **Int keys survive both wires.** Every input and snapshot body is one `var_to_bytes` (see
  `envelope.gd`), so int Dictionary keys and packed arrays arrive as sent. G18 O5 round-trips the
  fields through `var_to_bytes` / `bytes_to_var` to pin it.
- **Compat with CouchOwnedEntity.** `CouchOwnerTargets.note_input` reads only `"t"`, `"o"`, `"ev"`
  of the top-level body, so the player path ignores `"p"` and `"pr"`. The per-prop `{"t","o"}` is
  exactly what `note_input` takes, so prop reports get the same validation as player reports.
- **Reservation.** Top-level input keys `"t"`, `"o"`, `"ev"`, `"p"`, `"pr"` and snapshot extra key
  `"pp"` are reserved for the addon (doc lines in `owned_entity.gd` and on `pack`'s `extra`).
- **Demo wire change.** The demo's `"p"` (one PackedFloat32Array report), `"pr"` (one press) and
  `"co"` / `"pr"` extra go away in slice B1. All peers run one build, so there is no mixed-version
  compat to keep.
- **Size.** A held prop costs about 20-35 bytes per snapshot; free props cost nothing.

## State machines

### Host, per prop (CouchPropAuthority)

States: FREE (owner "", host simulates), HOST (owner = host id, host simulates), GUEST(g) (owner g,
the host's body PD-follows g's reports).

| From | Event | To | Notes |
|---|---|---|---|
| FREE | `update` with host_near | HOST | contact time noted |
| FREE | input from g with a claim for this prop, `set_owner` and `note_input` succeed | GUEST(g) | `grants += 1`; slice D: not if (g, prop) refused |
| HOST | `update`, not touching, `now - last contact >= release_idle_ms` (300) | FREE | no settle wait: the host's body is the real one |
| HOST | claim from anyone | HOST | ignored |
| GUEST(g) | input from g without a claim for this prop | FREE | `releases += 1` |
| GUEST(g) | `update` with g stale (> 500 ms since g's last accepted report) | FREE | `takebacks += 1`; slice D marks (g, prop) refused |
| GUEST(g) | `forget(g)` | FREE | `takebacks += 1`; slice D marks refused |
| GUEST(g) | claim from h != g, or host touching | GUEST(g) | ignored; the host's contact is a press |

Press routing: FREE or HOST -> apply now; GUEST(g) -> sum for g, sent in the next snapshot as
`"pp"[eid]["pr"]` only if the owner is still g, then cleared. In `update`, the stale check runs
before the host hold, so a take-back and a host touch in one tick end HOST.

### Owner, per prop (CouchPropController)

States: PUPPET (frozen, drawn at the sample), CLAIMING (predicting, not yet granted), HELD
(predicting, granted). Constants carried over from demo 4af9e66 `CratePrediction` (= b4d5ea3 plus a
read-only `blending()` accessor), unchanged in value: `CLAIM_MARGIN` 12 px stays in the game;
`release_idle_ms` 300, `settle_speed` 10.0, `release_match` 1.0, `blend_ms` 100,
`extrapolate_cap_ms` 250, `claim_grace_ms` 150; host `release_idle_ms` 300.

`update(eid, near, copy, tick, now, rtt)`, with `owner` from the newest `on_snapshot`:

PUPPET:
- CLAIM when `near` and `owner in ["", my_id]` (a prop the snapshot still says is mine counts as
  free: for a round trip after a release snapshots still name me) and `world.latest(eid)` is not
  empty and `now >= backoff_until`. The returned state is the latest state advanced to this tick:
  `age = clamp((tick - latest.tick) * physics_dt, 0, extrapolate_cap_ms / 1000)`;
  `x += vx * age`, `y += vy * age`, `rot = wrapf(rot + w * age, -PI, PI)` (if the kind has
  rotation); velocities and other channels as in the snapshot. (Slice C: position and rotation
  come from the last drawn pose instead and the difference goes into the report; item 3.) On CLAIM: `claims += 1`, granted
  false, `claim_ms = now`, `last_contact_ms = now`, any release blend cancelled -> CLAIMING.

CLAIMING / HELD, checked in this order:
1. `owner == my_id and now - claim_ms >= int(rtt)` -> granted (HELD). An earlier "mine" is the
   previous grant still on the wire.
2. Denial -> RELEASE, `denials += 1`, `backoff_until = now + int(rtt)`, reason:
   - "lost": `owner` is neither "" nor `my_id`;
   - "taken-back": granted and `owner == ""`;
   - "unanswered": not granted and `now - claim_ms > int(rtt) + snapshot_ms + claim_grace_ms`.
3. `near` -> `last_contact_ms = now`.
4. Else settled release -> RELEASE reason "settled" when ALL of: `now - last_contact_ms >=
   release_idle_ms`; `|copy velocity| < settle_speed`; `copy position` within `release_match` of
   the last sample passed to `render_pose`; no queued press (`ticks_left == 0`).
5. Slice C: else transfer -> RELEASE reason "transfer" (see item 1).

Every RELEASE: `releases += 1`, the queued press is cleared, the copy pose is kept as the blend
start, -> PUPPET. Presses arriving while PUPPET or CLAIMING-but-not-named-owner are dropped (the
presser keeps pressing; latest-wins like inputs).

### Intentional deviations from demo 4af9e66 in slices A-B

1. **A claim whose report is rejected grants nothing.** The demo granted on `set_owner` and ignored
   `note_input`'s result, so a malformed first report left the crate following an empty target.
   Now "target empty" means exactly "the host simulates it". Unreachable for a well-behaved client.
2. **The body switches at the next physics tick, not inside the input callback.** The game polls
   `is_guest_owned` before the step instead of `CrateAuthority` calling `Crate.follow`. Both land
   before the same physics step.
3. **Claim rotation is wrapped** to [-PI, PI]. Same transform.
4. **Free props are absent from `"pp"`** where the demo sent `"co": ""`. Same meaning.
5. **Several props, per-eid release.** An input that omits one prop's claim releases that prop
   only. With one crate this is the demo's rule.
6. **The host passes `now_ms` to `target_for`** instead of the demo lambda reading `Time`.

Nothing else changes: B1's gate is that the demo's numbers do not move (see Verification).

### Intentional deviations in slice C (gated behaviour that changes on purpose)

1. **Claim placement.** CLAIM puts the copy at the drawn puppet pose with the "now" velocity, not
   at the "now" pose; the difference rides in the report and decays (item 3).
2. **Release blend.** The 100 ms linear `lerp` becomes the decaying offset: exponential with
   `offset_tau_ms` 100 and closing speed capped at `offset_max_speed` 150 units/s. A release gap
   under 15 px fades about as fast as before; larger ones (transfers) fade over up to ~0.5 s.
3. **New release reason "transfer"** (item 1); run tracking resets on every CLAIM and RELEASE.
4. **`release_jumps` changes meaning in C'.** Until C' it is the internal gap at release (copy vs
   last sample, B1 below). From C' on it is, per release, the largest per-frame displacement of the
   drawn crate beyond its own velocity within 500 ms after the release, the same measure as the
   claim jump. `RELEASE_JUMP_BOUND` 4.5 then applies to every release, transfers included. The
   internal gap is still recorded as `release_gaps`, printed, not gated.

## Open items 1-6

### Items 1 and 3: transfer on press, claim blend (slice C, one shared mechanism)

**Item 1, transfer on press.** Today an idle owner whose prop others keep pressing never releases:
the queued presses block the settled rule, so pressers wait a round trip per push for as long as
they push. Rule (owner, HELD only): track runs of forwarded presses. In `on_snapshot`, a queued
non-zero press at `now_ms` starts a new run if `now_ms - run_last_ms > transfer_gap_ms` (100 ms, 3
snapshot intervals at the default `snapshot_every` 2), and sets `run_last_ms = now_ms`. In `update`,
after the settled check: RELEASE reason "transfer" (`transfers += 1`, `releases += 1`, not a
denial, no backoff) when not near, `now - last_contact_ms >= release_idle_ms`, `now - run_last_ms
<= transfer_gap_ms`, and `run_last_ms - run_start_ms >= release_idle_ms`. Speed and match are not
required: the prop is moving by design. Nothing changes on the host: the release is an input
without the claim; a guest presser then sees the prop free and claims it; the host presser, still
touching, holds it.

Run tracking (`run_start_ms`, `run_last_ms`) resets on every CLAIM and every RELEASE, so a run
from one hold never counts toward the next.

**Item 3, claim blend.** Claiming a moving prop moves the copy from the render-delayed puppet to
"now" (up to ~40 px seen). The fix keeps the Rev 3 rule literally: on the claimer's screen the copy
IS what is drawn and IS what the controller collides with, at every frame. The jump is moved out
of the drawing and into the **report**, where it eases away:
- **CLAIM** returns a state with position and rotation = the last pose `render_pose` drew (the
  puppet the player is touching), and velocities = the extrapolated "now" state's. The controller
  stores `off_pos = now_pos - drawn_pos`, `off_rot = wrapf(now_rot - drawn_rot, -PI, PI)`, `k = 1`.
  With no `render_pose` yet, the state is the "now" state and the offset is zero.
- **Each `update` tick** (`dt = physics_dt`): `rate = min(k / tau, max_speed / |off_pos|)` (just
  `k / tau` when `|off_pos| == 0`), `k = max(0, k - rate * dt)`, `k = 0` once `k < 0.001`.
- **`input_fields`** reports `"o"` = the copy state with `x, y += off_pos * k` and `rot =
  wrapf(rot + off_rot * k, -PI, PI)`; velocities as the copy's. So the host's crate never yanks
  back to the delayed pose: its first target is about where it already is, and it eases onto the
  copy as `k` decays, never faster than `offset_max_speed` (150 units/s; a 40 px offset takes about
  0.5 s, under 15 px after 0.2 s). The cost: every OTHER screen sees the crate ease back by up to
  the claim jump over that time.
- **Release** keeps drawn = solid too: the release blend moves the frozen STATIC puppet, which is
  the collider. Slice C replaces the 100 ms lerp with the same decay applied to a render offset:
  on the first `render_pose` after a RELEASE, `off = last_drawn - sample`, `k = 1`, decayed per
  render frame with the same rule and `dt = (now - last_frame_ms) / 1000`, drawn = `sample +
  off * k`. `is_blending` is that release `k > 0`.
- **Interaction with the settled release.** `release_match` compares the copy with the sample, and
  the sample shows the host's crate, which follows the report (copy + offset). So while
  `|off_pos * k| >= release_match` the settled release cannot fire; it waits until the offset has
  decayed and the puppet has caught up. That is the right answer (releasing earlier would jump by
  the leftover offset), it cannot hang (k reaches 0 in under a second), and it adds no rule.
  A **transfer** does not check the match: a transfer under a live offset leaves the host's crate
  at copy + leftover offset, and the release blend on the owner covers that gap on screen.
- **Interaction with grant timing.** None in the rules: grant detection reads the snapshot owner
  and `rtt`, not positions. Before the grant arrives the host simulates its own crate (already at
  "now"); at the grant its target is copy + `off * k`, with `k` already decayed for about one
  one-way trip, so the follower starts with a small error instead of today's full jump. Denials
  ("lost", "unanswered") never reach a follower; the release blend covers the owner's screen.
- **Walls.** The eased target can sit a few px inside a wall the copy stopped at; the host's
  follower presses into the wall and physics holds it out. Measured in C', not gated.

Gates: G18 C1 (transfer boundaries) and C2 (claim placement, report offset, release offset); demo
transfer gate and the claim/release jump gate on the drawn (= copy) pose (Verification).

### Item 2: host-acknowledged release (DECIDED, Daniel 2026-10-08, [DECIDE P4])

What is lost today: when an owner releases, presses the host forwarded in snapshots that reach the
owner after it released are dropped (it no longer simulates), and the host only stops forwarding
when the release input arrives. **Correction to the frame review:** the window is one full round
trip plus one snapshot interval, not one one-way trip (snapshots sent after `T - one_way` arrive
after the release at T; forwarding continues until `T + one_way`). At 250 ms RTT that is ~280 ms
of presses, felt as the prop easing off for a moment. With item 1 this happens on every transfer
under press, not only on rare releases. Presses are already loss-tolerant (inputs are
latest-wins; the lobby run drops 2%), and the presser keeps pressing.

Decision (Daniel, 2026-10-08): dropped for now. The limit is stated in the class docs ("presses
forwarded within one round trip plus one snapshot interval of a release under press are lost";
~280 ms at 250 ms RTT, on every transfer with item 1). The API is shaped so the fix is additive:
`update`, `forget` and `on_input` already return recovered presses (empty until then; see the
contract). The 250 ms clip after slice C decides whether slice E is built. Slice E would cost
(addon + demo, ~90 non-test lines):
- owner: in the releasing input, send the undrained queue as its own `"pr"` press (no wire change);
- a new input field (e.g. `"sa"`: newest snapshot host tick ingested) on every input;
- host: a per-prop history of forwarded sums by snapshot tick; on release, return the sums newer
  than the owner's `"sa"` from `on_input`; on take-back or forget, newer than the last accepted
  `"sa"`, from `update` and `forget` (the return values already exist);
- G18 conservation cases and a demo press-conservation gate, which the lobby's 2% input loss makes
  noisy.

### Item 4: gate coverage for every press path (slice B2)

Today the press-response gate judges only the scripted host->guest press. B2 extends the press
phase so each run has a judged press on every path (see Verification, "Press phase v2") and makes
`check_press_responses` require at least one judged episode for each of host->guest,
guest->host (host-held crate) and guest->guest. Nothing changes in the addon.

### Item 5: in-flight claims re-grant after a take-back (slice D, addon)

After a stale take-back or `forget`, inputs still in flight from that owner carry the prop's claim
and grant it again at the old place (the demo's press-phase placement works around it with a
retry). Rule: on take-back or forget, mark (peer, prop) refused. While marked, that peer's claims
on that prop are ignored (`refused_claims += 1`, no grant). An input from that peer WITHOUT a claim
for that prop clears the mark (the owner saw the take-back and stopped). Other props and other
peers are unaffected; `remove_prop` drops the prop's marks. Owner side needs nothing: it already
releases on "taken-back" and stops claiming for a round trip. Gate: G18 D1. The smoke harness has
no stall lever, so the demo only re-runs its batch.

### Item 6: shockwave on a guest-held crate becomes a press (slice B2, demo)

`NetHost.shockwave` pushes the crate with `apply_central_impulse` whatever its owner; on a
guest-held crate the follower pulls it back and the owner never sees it. Change: the crate branch
calls `props.apply_now(eid, Vector3(j.x, j.y, 0.0))` with `j = crate_dv * Crate.MASS`, and
applies it only if that returns true. Gate: the shockwave sub-phase in "Press phase v2" makes it a
judged host->guest press episode.

## Slices (each its own PR)

| # | Repo | Concern | Non-test lines (est.) | Depends on |
|---|---|---|---|---|
| 0 | addon | This design doc | doc | none |
| A1 | addon | `CouchPropAuthority` + G18 host cases + mutation script (host mutants) + reservation doc lines | ~200 | 0 |
| A2 | addon | `CouchPropController` (slice A behaviour) + G18 owner and E1 cases + owner mutants | ~260 | A1, stacked |
| B1 | demo | Port: delete `CrateAuthority` / `CratePrediction`, thin `Crate` / `CratePuppet`, presses by eid, new wire; submodule to A2 | ~430 incl. ~300 deleted | A2 merged |
| B2 | demo | Press coverage: shockwave as a press (item 6), press phase v2 + per-path gate (item 4) | ~150 | B1 |
| D | addon | Refuse in-flight claims after a take-back (item 5) + G18 D1 + mutants | ~30 | A2 |
| D' | demo | Submodule bump to D, batch only | ~2 | B2, D merged |
| C | addon | Transfer on press + decaying offset (items 1, 3) + G18 C1/C2 + mutants | ~90 | D |
| C' | demo | Transfer sub-phase, transfer gate, claim/release jumps on the drawn pose, clip | ~120 | C merged, D' |
| E | both | Item 2, only if the 250 ms clip after C' calls for it (additive: fills the recovered-press returns) | ~90 | C' |

- Addon PRs stack (A1 -> A2, then D, then C), merged with merge commits. Demo PRs stack the same way
  and pin the submodule to the addon's `main` merge commit before merging (as 4af9e66 did); while
  in review they may pin the addon branch commit.
- B1 is over the soft budget because it deletes ~300 lines while adding ~130; the PR description
  says so. It cannot split without leaving the demo half on each implementation.
- A was one slice in the frame review; it is split for the 400-line budget. Each half has its own
  gate cases and mutants.

## Verification

### G18: `netcode/fixtures/run_prop_authority.gd`

Same style as G16: `extends SceneTree`, deterministic, virtual time, no `await`, no `Time`, no
physics server, every check guarded so a stub or wrong type gives a `FAIL:` line, never a script
error; each failed check prints `FAIL: <case> ...`; one `quit()`; final line `G18 prop authority:
N/N checks passed`; exit 0 iff no failures. Written gate-first against inert stubs from the
contract, red, then implemented. Toy bodies as in G16: a prop is a state array integrated by the
fixture (`x += vx * dt`, linear damping), presses change velocity by `j / mass`, the host's body
follows `target_for` with a real `CouchPDFollower` and `force_from`. Real `CouchReplicatedWorld`s on
both sides (host `pack` -> owner `ingest`) so `latest`, `extra` and int keys are the real thing.

Cases (slice that adds them):
- **A1 registration** (A1): set_channels / add_prop refusals one by one; a new prop is free;
  remove_prop; owner_of "" for unknown ids.
- **A2 grants** (A1): first claim on a free prop wins; a second claimant and claims on a host-held
  prop are ignored; a claim with a rejected report grants nothing; counters.
- **A3 host hold** (A1): touching takes a free prop, never a guest-held one; let-go at exactly
  `release_idle_ms` (299 ms holds, 300 frees) with no settle wait; stale check runs before the hold.
- **A4 releases** (A1): an input without `"p"`, with `"p"` not a Dictionary, and with `"p"` lacking
  one of two owned eids, each releasing exactly the right props.
- **A0 recovered presses** (A1): one check each that `update` and `forget` return an empty
  Dictionary, including on the calls that release or take back, and that `on_input`'s return
  holds only routed presses (no recovered press) on an input that releases a prop.
- **A5 take-back** (A1): stale at `stale_ms` boundary -> free on `update`; `forget` frees every
  prop of the peer and only those; `target_for` empty afterwards.
- **A6 presses** (A1): `apply_now` true for free / host-held, false for guest-held; the sum
  reaches `take_snapshot_extra` for the owner it was collected for and never for a new owner after
  a release or a re-grant; sums cleared per call; `on_input` handles releases and claims before
  presses (an input releasing a prop and pressing it returns the press to apply); every malformed
  `"pr"` entry counted in `bad_presses`; free props absent, `{}` when nothing is held.
- **A7 several props** (A1): one peer holds two props; two peers hold one each; take-back of one
  touches nothing else; `target_for` per prop.
- **O1 claim** (A2): claim fires only with near AND free-or-mine AND latest AND past backoff (one
  negative per condition); state advanced exactly by `(tick - latest.tick) * dt`, capped at 250 ms
  (boundary), rotation wrapped; negative age clamped to 0.
- **O2 grant and denial** (A2): "mine" earlier than `rtt` after the claim is not a grant, at `rtt`
  it is; lost, taken-back and unanswered (boundary: `rtt + snapshot_ms + grace` holds, +1 releases)
  each RELEASE with their reason and set backoff to `now + rtt`.
- **O3 settled release** (A2): fires with all four conditions; each condition alone blocks it;
  near refreshes the contact time; no release before any `render_pose`.
- **O4 press spreading** (A2): a press P with `snapshot_ticks` n drains as P/n for n ticks summing
  to P; a second press mid-way re-spreads the remainder plus it over n; presses dropped when not
  predicting, when the owner is someone else, or zero; RELEASE clears the queue.
- **O5 input fields** (A2): `"p"` only for predicted props with a copy of the state; `"pr"` only for
  non-zero presses on props not predicted; `{}` when neither; the fields survive
  `var_to_bytes` / `bytes_to_var` with int keys and packed types intact.
- **O6 render** (A2): predicted -> copy pose; puppet -> sample; after RELEASE the lerp values at 0,
  50 and 100 ms; `is_blending` true until the frame that draws the end.
- **E1 end to end** (A2): one host authority, two controllers, a fixed-delay in-fixture link (inputs
  and snapshots, 3 ticks each way), toy bodies. Owner 1 claims and is granted; the host's body
  converges to owner 1's copy; owner 2 presses and owner 1's copy moves by the forwarded press;
  owner 1 idles and settles and releases; owner 2 then claims; the host's player holds a free prop
  and owner 2's claim is refused. No snapshot ever names two owners; every claim ends in a grant,
  a denial or a release.
- **D1 refusal** (D): after a stale take-back and after `forget`, in-flight claims are refused and
  counted; an input without that prop's claim clears it; other props and peers unaffected.
- **C1 transfer** (C): transfer only when HELD, not near, idle >= 300 ms, and a press run >= 300 ms
  still live; runs split by gaps > `transfer_gap_ms` (boundary); own contact blocks it; reason
  "transfer", counted in `transfers` not `denials`, no backoff.
- **C2 offsets** (C): CLAIM state = the last drawn pose with the "now" velocities (the "now" state
  when nothing was drawn yet); `input_fields` `"o"` = copy + `off * k`, rotation wrapped on the
  short arc; per-tick change of the reported offset never above `max_speed * dt`; monotone decay to
  exactly 0; zero jump gives zero offset; `render_pose` while predicting returns exactly the copy;
  the release offset obeys the same bounds per render frame and `is_blending` follows it; run
  tracking resets on CLAIM and RELEASE.

What G18 gates: grant order, host hold, take-back, release on an absent claim, the press sum
never crossing an ownership change, spreading arithmetic, the claim extrapolation and its cap,
grant after RTT, denial and backoff, item 5, the transfer rule and the offset maths. What it cannot:
penetration, jump magnitudes in real physics, the puppet falling asleep, `body_set_state`, frame
timing. Those are the demo smoke gates' job.

### Mutation script: `docs/plans/prop-authority-mutations.py`

Newer scratch-copy style, copied from `render-delay-mutations.py`: `python3
prop-authority-mutations.py <scratch project> [mutant ...]`; asserts the addon in the project is a
plain copy (no symlink, no `.git`); each mutant is one exact, unique search/replace; KILLED only if
a line starts with `FAIL: <expected case>`; restores every file in `finally`; prints survivors and
exits 1 if any. The writer turns each behaviour below into an exact string against the code it
wrote. Survivors get a case, then the script is re-run.

| Mutant | Behaviour | Case |
|---|---|---|
| h01 | claim on a held prop also grants | A2 |
| h02 | grant despite a rejected report | A2 |
| h03 | no host hold | A3 |
| h04 | host let-go uses `>` instead of `>=` | A3 |
| h05 | host waits for the prop to settle before letting go | A3 |
| h06 | a missing claim keeps every prop (no per-eid release) | A4 |
| h07 | no stale take-back | A5 |
| h08 | `forget` leaves the owner | A5 |
| h09 | press applied (true) while guest-held | A6 |
| h10 | sum forwarded to a new owner | A6 |
| h11 | presses handled before releases in `on_input` | A6 |
| h12 | press size check dropped | A6 |
| h13 | one shared `CouchOwnerTargets` for all props | A7 |
| o01 | claim state not extrapolated | O1 |
| o02 | extrapolation uncapped | O1 |
| o03 | a prop still named mine is not claimable | O1 |
| o04 | backoff ignored | O1 |
| o05 | "mine" counts as a grant before `rtt` | O2 |
| o06 | unanswered without `claim_grace_ms` | O2 |
| o07 | taken-back not detected | O2 |
| o08 | settled release without the match check | O3 |
| o09 | settled release with a press still queued | O3 |
| o10 | settled release without the speed check | O3 |
| o11 | press applied as one lump | O4 |
| o12 | press queued when not predicting | O4 |
| o13 | RELEASE keeps the queue | O4 |
| o14 | `"p"` sent for a prop not predicted | O5 |
| o15 | `"pr"` sent for a predicted prop | O5 |
| o16 | no release blend | O6 |
| d01 | no refusal | D1 |
| d02 | refusal never cleared | D1 |
| d03 | refusal blocks every prop of the peer | D1 |
| d04 | claim-free rule cleared by any input, claims included (added in D) | D1 |
| c01 | no transfer | C1 |
| c02 | transfer while the owner touches it | C1 |
| c03 | run gap ignored | C1 |
| c04 | claim at the "now" pose (old jump), no report offset | C2 |
| c05 | no speed cap | C2 |
| c06 | offset never decays to 0 | C2 |
| c07 | claim at the drawn pose but report the bare copy (host yanked back) | C2 |
| c08 | release blend back to the 100 ms lerp | C2 |

### Godot matrix: 4.4 and 4.7, safe invocation

`docs/plans/matrix.sh` hardcodes another session's paths and runs `rm` / `git checkout` inside
`~/Repositories/couch-games-sdk-godot`, which has someone else's branch checked out. Do not run it.
Use fresh scratch projects instead (fresh directory names, no `rm -rf` of variables):
```bash
S=<session scratchpad>/prop-matrix-<slice>        # a new name per run
V=~/.local/share/godot/app_userdata/Godots/versions
G44=$V/Godot_v4_4-stable_linux_x86_64/Godot_v4.4-stable_linux.x86_64
G47=$V/Godot_v4_7-stable_linux_x86_64/Godot_v4.7-stable_linux.x86_64
for p in g44 g47; do
	mkdir -p $S/$p/addons/couch-games-sdk
	rsync -a --exclude=.git <addon worktree of the slice>/ $S/$p/addons/couch-games-sdk/
	printf 'config_version=5\n\n[application]\nconfig/name="prop-matrix"\n' > $S/$p/project.godot
done
timeout 300 $G44 --headless --path $S/g44 --import > $S/g44-import.log 2>&1
timeout 300 $G47 --headless --path $S/g47 --import > $S/g47-import.log 2>&1
for p in g44 g47; do for f in run_prop_authority run_owner_authority run_impulse_compensation run_replicated_world; do
	B=$G47; [[ $p == g44 ]] && B=$G44
	timeout 600 $B --headless --path $S/$p --script res://addons/couch-games-sdk/netcode/fixtures/$f.gd > $S/$p-$f.log 2>&1
	echo "$p $f rc=$? $(tail -1 $S/$p-$f.log)"
done; done
```
Pass: rc 0, final line `... N/N checks passed`, no `SCRIPT ERROR` or `Parse Error` in any log.
`netcode/` needs no `CouchGames` autoload. New `.gd.uid` files appear in the scratch copy on
import; copy them back next to their `.gd` in the worktree and commit them. The mutation script
runs against `$S/g47`.

### Demo smoke gates that must not regress (B1, B2, D', C')

All from `tools/smoke_check.py` at 4af9e66, same bounds:
- own penetration into the crate as drawn <= 2.0 px, host and every guest;
- release jump <= 4.5 px (from C' measured as drawn, every release; see slice C deviations);
- press response within path RTTs + snapshot interval + the presser's max render delay + 150 ms,
  and at least one judged press on a guest-held crate;
- frames drawn past the newest snapshot <= 1%; puppet jump beyond its velocity <= 3.0 px;
- guest crate wall depth <= host's + 1.0 px; render delay mean <= RTT/2 + snapshot interval + 6 ticks;
- error p50 <= 17.5 lobby / 15.5 star, p95 <= 30, max <= 70 (tuned for 40/15);
- knocks exactly once, ring and inbox clean, host rejected 0 inputs and 0 per reason, sampled > 95%;
- vacuity: a grant, a release, a press sent, a press applied, crate wall contact on host and a
  guest, a player-contact knock.

**Claim and release jumps after B1.** `CratePrediction` goes, but `smoke_check.py` (L401-412)
reads `claim_jumps` and `release_jumps`. NetOwner computes them: on CLAIM, the copy's position
before `update` vs `d["state"]`'s position; on RELEASE, the copy's position vs NetOwner's last
sample of the crate (what it passed to `render_pose`). Same numbers as `CratePrediction` recorded.

**Baseline first.** Before B1, run the batch on demo 4af9e66 on the same machine and keep its
numbers (grants, releases, denials, claim/release jumps, press responses per path). B1 passes if
every gate holds AND those numbers stay within the baseline's run-to-run range. That is the
evidence for "behaviour-identical".

### New demo gates

**Press phase v2 (B2, items 4 and 6).** The press phase becomes four sub-phases of ~2.5 s, each
starting with the host re-placing the crate at rest on open floor once the host simulates it (the
existing `Crate.place` retry):
1. holder guest 1 (gap 8 px above, as today), presser host from the left: host->guest (today's);
2. holder guest 1, presser guest 2 from the left: guest->guest;
3. holder host (standing 6 px off the left face: inside `CLAIM_MARGIN`, not touching; guests'
   stations away so nobody claims first), presser guest 2 from above: guest->host;
4. holder guest 1, host at its station, scripted shockwave: host->guest via `apply_now` (item 6).
Pressers start ~60 px away on a side perpendicular to the holder and walk in for 1.5 s. The run
grows: `GUEST_SECONDS` 20 -> 28, `HOST_SECONDS` 22 -> 30, `MEET_AT` 15 -> 23 (exact numbers are the
writer's, within these rules). Gate: at least one judged episode per path per run, each within its
bound. Mutants (2 runs per transport each, all must fail their gate): host does not apply guest
presses on a host-held crate (guest->host late); host drops guest presses on a guest-held crate
(guest->guest late); shockwave back to `apply_central_impulse` (sub-phase 4 late); plus Rev 3's three
(no forwarding, guest collision tied to prediction, wrong press sign) re-run on the port in B1.

**B1 mutants on the port** (2 runs per transport): no CLAIM ever (penetration or grant vacuity
fails); never grant (grant vacuity); KINEMATIC puppet (penetration); no forwarding (press response).

**Transfer (C').** A fifth sub-phase: guest 1 claims, then walks 80 px away (idle); guest 2 presses
the idle-held crate for 1.5 s, so guest 1 transfers and guest 2 claims a moving crate. Gate: at
least one "transfer" per run, and guest 2's first press episode on the idle-held crate is followed
by guest 2's claim within `release_idle_ms` + guest 1's RTT + guest 2's RTT + snapshot interval +
150 ms. Mutant: c01 (no transfer) fails both.

**Claim and release jumps on what is drawn (C', item 3).** Per guest, over render frames within
500 ms after each CLAIM or RELEASE, the drawn crate's displacement beyond its own velocity,
`PuppetMotion` style: `|drawn_t - drawn_(t-1)| - |v| * dt`, with `v` the copy's velocity while
predicting and the sample's while not. The drawn crate is the body (copy or frozen puppet), so
this is also the collider. Gate: max <= 4.5 px for claims (`CLAIM_JUMP_BOUND`) and for releases
(`release_jumps`, see slice C deviations). Vacuity, per BATCH not per run: at least one claim in
the batch whose raw jump (`|off_pos|` at the claim, i.e. drawn vs "now") is >= 5 px, else the gate
proved nothing. Mutants: c04 (claim at "now") must fail the claim gate at 40/15; c08 (100 ms lerp)
is expected to fail the release gate on transfers; c05 (no speed cap) is gated by G18 and recorded
here. Penetration (bound 2.0 px) is unchanged and still measured against the body, which is now
always what is drawn.

**Host-side ease (C', reported, not gated).** On the host and on third screens, the crate's
per-frame displacement beyond its velocity within 500 ms after each grant, printed per run: the
visible cost of the claim offset. Mutant c07 (bare copy reported) should show here as a jump of
the full claim offset; G18 C2 gates it.

### Batches, accepted failures and the clip

- Every demo slice: 18 runs per transport at 40/15 (lobby 2% loss, star none) and 9 per transport
  at `SMOKE_DELAY=117 SMOKE_JITTER=15`, plus the slice's mutants.
- Accepted at 117/15: **error p50 and p95 only** (tuned for 40/15), as in the adaptive render delay
  evidence (demo 70d16c2 on addon 0f6b9fa). Rev 3's one-frame penetration failures at 117/15 were
  fixed by the adaptive delay and are no longer accepted. Anything else failing at 117/15 is a
  failure.
- The 250 ms clip: star at 117/15, recorded the same way as `~/Videos/rtt250-adaptive1.mp4`, after
  C' (`~/Videos/rtt250-props1.mp4`), covering a transfer, a claim of a moving crate and a guest
  pressing a held crate. It is also where Daniel looks for item 2's ease-off.

## Decisions for Daniel

### [DECIDE P1] API shape: DECIDED (Daniel, 2026-10-08)
Ruling: option 1, as recommended.

1. **Two new classes, `CouchPropAuthority` (host) and `CouchPropController` (owner), each holding
   N props by entity id, one hidden `CouchOwnerTargets` per prop** (recommended). The step 1
   contract and G16/G17's ~570 checks stay untouched; a prop's lifecycle (claim, grant, hold,
   release) differs from a player's (owned for the whole session); one targets per prop already
   gives "one owner per prop, several props per peer".
2. Generalise `CouchOwnerTargets` / `CouchOwnedEntity` to N entities per peer. Reopens a frozen
   contract keyed by peer, for no gain the wrapper does not already give.
3. A Node helper that also drives the bodies. Banned in `netcode/`, not testable headless, 2D only.

### [DECIDE P2] Wire format: DECIDED (Daniel, 2026-10-08)
Ruling: option 1, as recommended.

1. **Input `"p"` and `"pr"` as Dictionaries keyed by entity id; snapshot extra under one key
   `"pp"`: `{eid: {"ow": owner, "pr": press}}`, free props absent** (recommended). Reports reuse
   `note_input`; three floats per press; no change to `pack()` or per-peer sections.
2. Per-peer snapshot sections for presses (only the owner receives them). Changes the 0d `pack()`
   wire for ~12 bytes per held prop.
3. Longer, namespaced keys (`"prop_claims"`, ...). Safer against game key clashes, a few bytes more
   per input. Reasonable if Daniel prefers explicit names; the reservation note covers the short ones.

### [DECIDE P3] Several props per peer: DECIDED (Daniel, 2026-10-08)
Ruling: option 1, as recommended.

1. **Yes, no cap, keyed by eid from day one** (recommended). The press loop and the wire are per
   prop anyway. Unresolved and untested: two props held by DIFFERENT peers pushing each other (each
   owner's copy meets the other's static puppet and is blocked by it, but neither feels the other).
   The demo has one crate.
2. One prop per peer. Simpler, but a player pushing two crates side by side breaks the rule.

### [DECIDE P4] Item 2, host-acknowledged release: DECIDED (Daniel, 2026-10-08)
Ruling: a new option 3, **drop for now, but shape the API so a later fix is additive**. `update`,
`forget` and `on_input` return recovered presses (`{eid: Vector3}`, empty in slices A-D); the
limit is in the class docs; the 250 ms clip after slice C decides whether slice E is built.
Options as presented, for the record:
1. Drop (was recommended): document the bound (one round trip plus one snapshot interval of
   presses at a release under press; ~280 ms at 250 ms RTT, now on every transfer), and judge it
   in the clip.
2. Do it as slice E (~90 lines, a new input field, an API change to `update` / `forget`, a noisy
   conservation gate; see Item 2).

### [DECIDE P5] Slicing order: DECIDED (Daniel, 2026-10-08)
Ruling: option 1, as recommended.

1. **0 -> A1 -> A2 -> B1 -> B2 -> D -> D' -> C -> C' (-> E)** (recommended). Port first with no
   behaviour change, so B1's batch proves the move; then coverage, so later changes are measured on
   every press path; D before C because a take-back re-grant jumps the crate and would muddy C's
   claim-jump gate.
2. C before B2 / D: the feel improvements sooner, measured with weaker coverage.

### [DECIDE P6] Where the claim jump goes: DECIDED (Daniel, 2026-10-08)
Ruling: option 1, as recommended.

1. **Keep copy = drawn = solid; claim at the drawn puppet pose with the "now" velocity and put the
   difference into the report, decaying** (recommended, item 3). The Rev 3 rule holds on the
   claimer's screen at every frame, the penetration gate is unchanged, and the host's crate never
   yanks back. Cost: every other screen sees the crate ease back by up to the claim jump over
   ~0.5 s. The settled release waits for the offset to decay (via `release_match`, no new rule).
2. Offset the visual only: the copy jumps to "now" and only the drawing trails it. Breaks the rule
   invisibly when the prop is thrown AT the claimer (the shockwave case behind item 3): the player
   is stopped by an invisible wall in front of the drawn crate while penetration-as-drawn reads 0.
   It would need a two-sided gate: on any owner tick with a non-zero press on a predicted prop, the
   drawn crate's gap to the controller <= 2 px.
3. Claim at the puppet pose and report the bare copy: no jump for the claimer, but the host's crate
   is yanked back by the render delay for everyone else.
4. Keep the jump (today, up to ~40 px).

### [DECIDE P7] Transfer threshold (item 1): DECIDED (Daniel, 2026-10-08)
Ruling: option 1, as recommended.

1. **Owner idle for 300 ms AND someone else pressing continuously for 300 ms** (recommended; reuses
   `release_idle_ms`). Two players pushing together never trade the prop.
2. Transfer on the first press while idle. Faster, but a brush against an idle-held prop moves its
   ownership, and with item 2 dropped each transfer costs a round trip of presses.

## Risks

- The eased host target can sit a few px inside a wall the claimer's copy stopped at; physics holds
  the host's crate out, but third screens may see it press there for up to ~0.5 s (measured in C').
- A transfer under a live claim offset hands the host a crate offset from the owner's copy; the
  owner's release blend covers it on screen, other screens see the remaining ease.
- B1's "behaviour-identical" is shown statistically (batch ranges), not by a trace diff.
- Headless frame times: a long frame makes the offset close faster per frame; 150 units/s keeps a
  30 ms frame under the gate, a 50 ms hitch would not. If C' fails only on long frames, report the
  frame time rather than retune silently.
- The run grows from ~22 s to ~30 s (B2) and longer in C'; a full batch takes ~40% longer.
- Snapshot size grows with held props; fine for tens, unmeasured for hundreds.
- Two props held by different peers colliding is unresolved ([DECIDE P3]).

## Out of scope

- Godot sinking a pushed body into walls (host 7-11 px) and the owner's copy sinking ~10 px.
- Other players drawn 15-33 px inside the crate on third screens.
- Impulse compensation for props, wiring into `CouchSession`, 3D bodies, prop-prop contention
  between owners, rollback or deterministic physics.


## A2 verification milestone (2026-10-08)

The A2 implementation reviewed was `de7bcc0` (local, unpushed), based on merged A1
`233d6d1`. It adds `CouchPropController`, O1-O6/E1 fixtures, and 16 owner mutants.
No production code changes were needed after the fresh review.

- Fresh read-only gpt-6-sol review: **"No in-scope findings. CONVERGED."**
  Covered the frozen A2 contract, host helper, existing demo consumer, and new fixtures.
- Independent Godot 4.4 and 4.7 matrix in fresh disposable projects: G18 213/213,
  G14 137/137, G15 237/237, G16 375/375, G17 197/197. No script or parse errors.
  The same gates were also run against clean `233d6d1` projects on both versions:
  existing G15/G16 resource-exit messages match that baseline. Godot 4.4 editor-import
  progress-dialog messages also reproduce there; Godot 4.7 imports cleanly.
- Full Godot 4.7 mutation pass: **29/29 killed by their named cases**, 16 owner and
  13 host. No survivors. The deliberately malformed host-size mutant h12 also emits
  script errors, but fails its A6 assertions; no mutant was counted by errors alone.
- Every tracked netcode file was restored byte for byte; restored G18 passed 213/213
  without errors. `git diff --check` passed.
- Evidence for this run: `/tmp/codex-prop-a2-6l6zlzvo/` (`results.json`, baseline and
  A2 gate logs, `mutations.log`, `g47-after-mutations.log`, `review.md`, `pr-body.md`).
  These paths are disposable; the counts and baseline observations above are durable.

This is a prerequisite API slice. Real physics-body and demo integration verification
belongs to B1 after A2 merges; the demo submodule is still pinned to `2e5b123`.
The approved P4 press-loss limit is unchanged. Daniel authorized push and PR creation
on 2026-10-08; A2 is pushed and PR #33 is open against addon main. This publication
status update changes docs only; production code remains exactly the verified `664c364`.
No merge or demo edits yet. Next work is a discussion with Daniel, then B1 after A2 merges.

## D verification milestone (2026-10-09)

Slice D (item 5) is implemented in code commit `fea1ccd` on `feat/prop-authority-refuse`,
based on addon main `07829c8` (A2 merged, PR #33). The diff is about 21 added and 7 removed
lines of production code, comments included. The refusal is per (prop, peer); no
game-specific logic.

- Fresh read-only Codex adversarial review (background job, no build or test commands run
  concurrently; the reviewer model was not recorded): **approve, no material findings.** It checked
  the item 5 rule, the host state table, the per-peer and per-prop scope, and the
  generality check.
- G18 on Godot 4.4 and 4.7 in fresh scratch projects holding a plain copy of the addon:
  **220/220 on each**, no FAIL, SCRIPT ERROR or Parse Error lines. That is the 213
  pre-existing checks plus 7 D1 checks.
- Two existing A0 and A5 steps now send a claim-free input from the peer between a
  take-back and its next claim. Without it, the re-claim is the in-flight case this slice
  refuses, and the old assertions fail. The assertions are unchanged; only the input
  sequence changed. A real owner sends that claim-free input after a take-back.
- Full Godot 4.7 mutation pass (`prop-authority-mutations.py` in a scratch copy with no
  `.git`): **33/33 killed by their named cases**, 29 pre-existing and d01 to d04. No
  survivors. The two script-error lines belong to h12, as in A2.
- d03 survived the first D1 draft. Its refused-on-one-prop, granted-on-another step was
  not in the test, because the claim on the other prop cleared the mark first. The D1 case
  now sends both props in one input, so the mark stays in force while the other claim is
  granted.
- Not added: a mutant for "`remove_prop` keeps marks". Marks live in the prop's record, so
  removing the prop drops them by construction; a mutant would mean restructuring the record.
  D1's re-add check covers the behaviour.
- Demo: unchanged. The demo submodule stays pinned to `07829c8`. D' is folded into C', as
  Daniel decided on 2026-10-09; C' includes D and its batch covers both.
