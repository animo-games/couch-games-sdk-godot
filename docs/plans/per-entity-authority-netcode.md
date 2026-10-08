# Per-entity authority netcode for a physics-sandbox co-op game

Status: proposal, not started. Target is a two-player Mosa Lina-like (dynamic rigid-body sandbox, randomized tools, short chaotic rounds) built on `CouchSession`. This replaces the "continuous input prediction with reconciliation" direction for that game; the discrete `CouchPredictionCore` path is untouched and stays the model for grid/turn games.

## Goal and scope

Two players share one physics sandbox with acceptable feel for both, on phones, over the platform tunnel, without a determinism contract on the game. The guest's own body must respond instantly; interactions with the rest of the world may lag by one round trip and may visibly disagree for a moment. Spectators render the host's world.

In scope: the wire bodies carried by the existing `input` / `intent` / `snapshot` kinds, the host and guest simulation loops, event delivery for impulsive effects, tool use as host-validated intents, and the sizing budget. Out of scope: rollback of any kind, lag compensation, more than one guest, delta-compressed snapshots (noted as a follow-up).

## Why not rewind-and-replay

Reconciliation replays the guest's unacked inputs against a locally re-run copy of its own movement and assumes that replay lands close to the host's answer. In this game the player's motion is dominated by contact with host-owned dynamic bodies (a wobbling plank, a box that just got kicked, a bomb impulse), and Godot's `PhysicsServer2D` is not deterministic across two machines, so the replay would disagree with the host on nearly every snapshot and the guest would see a correction snap thirty times a second. Rollback proper is ruled out for the same underlying reason: the solver's contact, warm-start and island state cannot be captured or restored, so there is no snapshot to roll back to.

Per-entity authority sidesteps both. Nothing is ever rewound. Each body has exactly one simulating owner; everyone else displays it.

## Authority model

| Entity | Simulated by | Displayed by others as |
|---|---|---|
| Host player body | host | interpolated kinematic |
| Guest player body | guest | host: PD-driven rigid body; spectators: interpolated kinematic |
| Every tool object, prop, hazard, fruit, portal | host | interpolated kinematic |
| Level state, inventories, round outcome | host | fields in the snapshot |

The host is authoritative for everything except the guest's body transform. The guest is authoritative for its body transform and nothing else. This is the only asymmetry; the host's own body follows the same path as any other host-owned entity.

Continuous force fields (fan, balloon lift, goo drag, gravity zones) are a function of a body's position and the field's replicated state, so each owner computes them locally for the bodies it owns. Only *impulsive* effects (explosions, trampoline launches applied by the host's solver to the guest body) need a delivery mechanism; see [Impulse events](#impulse-events).

## Wire contract

All three bodies ride the existing envelope and its per-kind loss policy: `input` and `snapshot` are latest-wins, `intent` is reliable-in-spirit (a gap is surfaced as `sequence_gap`). Bodies go through `var_to_bytes`, so Godot types survive; use packed arrays for anything sized by entity count. Frame body cap is 256 KiB; the budget below stays two orders of magnitude under it.

### `input` — guest → host, every physics frame

```gdscript
{
  "t": 1412,                      # guest physics tick, monotone
  "p": Vector2(...), "r": 0.31,   # guest body transform
  "v": Vector2(...), "w": -1.2,   # linear / angular velocity
  "aim": Vector2(...),            # tool aim direction
  "ev": 87,                       # highest impulse-event id applied, see below
}
```

Latest-wins is correct here: a lost frame is superseded by the next. `send_input` already returns false for anyone but the pinned guest, so spectators cost nothing.

### `intent` — guest → host, on discrete actions

```gdscript
{"req": 12, "kind": "use_tool", "tool": "bomb", "pos": Vector2(...), "dir": Vector2(...)}
{"req": 13, "kind": "cycle_tool", "delta": 1}
{"req": 14, "kind": "ready"}
```

`req` is the guest's own monotone request counter and is echoed in the snapshot (`"acked_req"`) so the game can show a pending state. Host validates every intent (tool exists in inventory, instance limit, cooldown, round is live) and either applies it or drops it; the next snapshot is the answer either way. No optimistic spawn in the first cut; add a ghost preview only if the round trip feels bad.

### `snapshot` — host → everyone, 20–30 Hz

```gdscript
{
  "t": 2831,                       # host physics tick
  "acked_req": 12,
  "ids": PackedInt32Array,         # entity ids, host-assigned, monotone
  "kinds": PackedInt32Array,       # entity kind enum, parallel to ids
  "xf": PackedFloat32Array,        # [x, y, rot, vx, vy, w] * ids.size()
  "flags": PackedByteArray,        # bit 0 sleeping, bit 1 owned-by-guest
  "players": {"host": {...}, "guest": {...}},   # inventory, tool index, hp
  "level": {"id": 3, "seed": 91, "phase": "live", "fruit_taken": false},
  "events": [[86, 3, Vector2(..), Vector2(..)], [87, ...]],   # impulse ring
}
```

Every snapshot is the full world. The guest diffs `ids` against its local set: unseen id → instantiate from `kinds`, missing id → free. Latest-wins means a lost snapshot is invisible; there is no delta state to fall behind on. Entities that are asleep on the host are still listed (their transform is what the guest needs to keep collision correct) but the guest skips interpolation work for them.

## Host loop

Per physics frame:

1. Read the newest `input`. Store the reported guest transform and velocity as the PD target, timestamped with the local receive time.
2. In the guest body's `_integrate_forces`, drive toward the target: extrapolate the target by `velocity * time_since_receive` (capped at ~100 ms), apply a critically-damped spring on position and rotation with the reported velocity as feed-forward. If the error exceeds a snap threshold (~1.5 body widths, or a level reset) teleport instead. The body stays a real `RigidBody2D` so the host's solver resolves its contacts: a guest standing on a box still pushes it, a guest wedged under a plank still lifts it.
3. Step physics normally for everything else.
4. Drain applied intents in `req` order, validate, apply.
5. Every `snapshot_interval` ticks, pack the world and `broadcast_snapshot`.

The host never rewinds. Its own play is exactly single-player plus a PD-driven second body.

### Impulse events

When the host's solver or gameplay applies an impulse to the guest body (bomb blast, trampoline, being hit by a thrown box above a momentum threshold) the guest must feel it, but the PD controller on the host will otherwise fight its own solver's result and the guest, who owns the body, never sees it. So:

- Host appends `[event_id, kind, impulse, point]` to a ring of the last ~1 s of events and includes the ring in every snapshot. `event_id` is monotone.
- Guest applies every event with `id > last_applied` to its own body and reports `last_applied` back as `"ev"` in `input`.
- Host drops ring entries once acked or aged out.

Latest-wins on the snapshot is safe because the ring, not any single snapshot, carries the events. Contact impulses below the threshold are not events; the PD spring absorbs them and the guest simply doesn't feel a nudge, which is fine.

Continuous forces are not events. A fan is a replicated entity with a position and direction; the guest computes the force on its own body from the interpolated fan each frame. Same for balloon lift on a balloon attached to the guest, goo, and any future field. The rule: if the effect is a function of state, replicate the state; if it is a one-off, send an event.

## Guest loop

Per physics frame:

1. Sample local input, apply to the local guest body as forces/impulses exactly as single-player would.
2. Apply any unseen impulse events from the newest snapshot.
3. Compute field forces from the interpolated field entities.
4. Step physics. Every host-owned entity exists locally as a `RigidBody2D` with `freeze = true`, `freeze_mode = FREEZE_MODE_KINEMATIC`, moved each frame to its interpolated transform, so it supports and pushes the guest body. The guest body pushing a box moves nothing locally; the host's solver moves the real box and the next snapshot shows it. That one-round-trip delay on "I pushed it" is the accepted cost of the model.
5. `send_input` with the resulting transform.
6. Render: interpolate host-owned entities between the two newest snapshots at `now - 2 * snapshot_interval` (~66 ms at 30 Hz). If the buffer runs dry, extrapolate using the snapshot velocity for at most ~150 ms, then hold.

Spectators run steps 4 and 6 for every entity, including both player bodies, and never send.

## Level and round flow

The host owns the round. `level.phase` in the snapshot is the state machine (`lobby`, `live`, `won`, `failed`, `loading`), `level.seed` drives tool randomization on both sides so inventories match without sending the inventory list every frame. On a phase change the guest frees every entity and rebuilds from the next snapshot; nothing is preserved across a level load, which is what makes the "full world every snapshot" rule cheap to reason about. Host restart and guest rejoin are already handled by `CouchSession` (`session_started` / `session_stopped`); on `session_started` the guest discards everything and waits for a snapshot.

Host selection: the room creator hosts. If ping data is available from the lobby, prefer the lowest-ping player when the room starts; the guest is the only one who pays latency, so this is the one free lever.

## Sizing

Per entity in `xf`: 6 floats = 24 bytes, plus 4 for id, 4 for kind, 1 flag ≈ 33 bytes. A busy level with 60 entities is ~2 KB before base64, ~2.7 KB on the tunnel. At 30 Hz that is ~80 KB/s downstream per receiver; at 20 Hz ~55 KB/s. `input` is ~100 bytes at 60 Hz, ~6 KB/s upstream. Both are well inside the tunnel and far below the 256 KiB frame cap. If the snapshot becomes the platform's cost driver, the follow-ups are (in order) 20 Hz, omitting sleeping entities from `xf` and sending them in a 2 Hz side channel, and the star transport.

CPU: the physics world is simulated once on the host at normal cost; the guest simulates one body plus kinematic updates; nobody snapshots or hashes anything per tick. This is the cheapest profile available and is the reason to prefer it on phones.

## What lives where

Game-side, first cut: entity registry and kind enum, snapshot pack/unpack, interpolation buffer, PD controller, event ring, intent validation. All of it is a few hundred lines and is specific to the game's entity set.

Candidate SDK helpers once proven in one game, kept engine-seam-clean like the rest of `netcode/`: a `CouchReplicatedWorld` that owns the id/kind/xf packing and the interpolation buffer, and a `CouchEventRing` for the acked impulse list. `CouchPredictionCore`, `drain_coordinator.gd` and `recovery_coordinator.gd` are not used by this model and should not be bent toward it.

## Testing

- Two editor instances over the mock backend's loopback lobby is the primary loop; `CouchLobbyTransport.fault_drop_permille` covers loss on both kinds.
- The lobby transport has no latency injection today. Add a debug-only `fault_delay_ms` (delay outgoing envelopes by a fixed amount) next to the existing drop levers so interpolation buffer sizing and the PD snap threshold can be tuned without a WAN. This is the one SDK change the plan needs before the game work starts.
- Scenarios to script by hand: guest stands on a host-owned box while the host kicks it; bomb goes off between both players; guest throws a box at the host player; host restarts mid-round; guest loses 30 % of frames for five seconds; guest tab throttled for two seconds (extrapolation cap and snap-on-return must both fire).

## Open questions

- Snapshot rate: start at 30 Hz; drop to 20 Hz if the tunnel cost matters. Decide after measuring a real level's entity count.
- Whether the two player bodies should collide with each other on the guest's machine. On the host they do (PD body vs rigid body). On the guest the host body is kinematic, so the guest can be pushed by it but cannot push back locally; that is consistent with every other host-owned entity and is probably fine, but it is the interaction most likely to look odd.
- Guest-owned tool objects. Balloons and planks attached to the guest body could be guest-owned to remove one round trip from the "attach" feel. Not in the first cut; it doubles the authority surface.
