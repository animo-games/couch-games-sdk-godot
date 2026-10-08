# Step 0d design: CouchReplicatedWorld + CouchEventRing

Repo: /home/daniel/Repositories/couch-games-sdk-godot, branch `feat/replicated-world` from main 8dcb018.
Roadmap: docs/plans/realtime-netcode-roadmap.md. Carries over wire shapes from
docs/plans/per-entity-authority-netcode.md (ids/kinds/packed state, full world per
snapshot, impulse-event ring acked via input), generalised to N players.
STATUS: SETTLED -- A, B, C, D decided by Daniel 2026-10-05.

## Scope

Pure data structures, no Nodes, no physics, no transport. The game calls them from its
own loops; CouchSession is untouched (bodies are still game Dictionaries it never reads).

- Host: pack the world (entities + 0c clock fields + per-peer event streams + game extra)
  into ONE snapshot body for `broadcast_snapshot`.
- Client: ingest snapshot bodies (stale/duplicate/malformed handled), keep a per-entity
  interpolation buffer, sample at `CouchNetClock.render_tick_milli()`, spawn/despawn.
- Event ring: host-side per-peer monotone event streams carried in every snapshot until
  acked; client-side inbox that yields each event exactly once.

Out of scope: delta compression, interest management, CouchInputBuffer / redundant input
packing (step 2), PD follower (step 1), adaptive render delay.

## Entity model [DECIDED A, Daniel 2026-10-05: option 1]

Decided: entity = (id: int, kind: int, state: PackedFloat32Array). The game registers
each kind on BOTH sides with a channel layout, e.g.
`world.register_kind(KIND_CRATE, [LERP, LERP, ANGLE, LERP, LERP, LERP])`
(x, y, rot, vx, vy, w). Channel types: LERP (linear), ANGLE (shortest-arc lerp, radians),
SNAP (step: takes the older sample's value until the newer one is reached; for flags,
animation ids, hp). Stride = channel count; the layout is NOT on the wire.
No pack/apply Callables: the host game calls `set_entity(id, kind, state)` per tick and
`remove_entity(id)`; the client game reads `sample()` results and applies them to its nodes.
Plain data in, plain data out -> fully gateable headless.
Layout-mismatch guard: the packer stamps `"lh"` (int hash of every registered kind's id +
channel list, order-independent across kinds) on every snapshot; the client rejects a
snapshot whose `lh` differs from its own registry (reason `layout-mismatch`, counted). This
catches same-length channel swaps that the stride check cannot. Kept in the snapshot, not
the hello, so CouchSession stays untouched.
Known limits, accepted: state is float32 (ints exact to 2^24; strings / variable-length data
go in `"x"` or events); no SLERP channel (2D test bed). Later extensions, no wire break: more
channel types; an optional per-kind interpolate Callable override (option 2 layered on top).
Rejected: game Callables as the primary model (interpolation maths untestable in G15,
re-implemented per game); Dictionary per entity (keys repeated on the wire every snapshot,
still needs per-key type info for ANGLE).

## Snapshot body (owned by CouchReplicatedWorld)

```
{
  "ht":  host_tick (int),
  "lh":  layout hash (int),
  "ids": PackedInt32Array, "kinds": PackedInt32Array,
  "st":  PackedFloat32Array,          # concatenated states, ids order, stride per kind
  "pl":  { peer_id: {"ack": ack_tick, "rt": recv_tick, "hm": hold_ms, "mg": margin,
                     "ev": [[event_id, kind, payload], ...] } },
  "x":   game extra Dictionary (optional, passthrough)
}
```
Host API: `CouchWorldPacker` (or methods on CouchReplicatedWorld in host role):
`set_entity`, `remove_entity`, `pack(host_tick, peer_fields: Dictionary, ring: CouchEventRing, extra := {}) -> Dictionary`.
`peer_fields[peer] = {"ack": int}` merged with `CouchNetClockEcho.echo_for(peer, now)`.
Client: `ingest(body) -> bool` and `peer_section(my_peer_id) -> Dictionary` so the game
feeds `clock.on_snapshot(ht, now)`, `clock.on_echo(rt, hm, mg, now)` and inbox from it.
Every snapshot is the FULL world: latest-wins loss is invisible.

## Client ingest + interpolation

- Snapshot with ht <= newest ingested ht: ignored (stale/duplicate), counted.
- Malformed (missing keys, wrong types, ids/kinds size mismatch, unknown kind, st length
  != sum of strides, duplicate id): rejected whole, counted, `rejected(reason)` signal.
- Per entity: ring of the last K (=8) samples (tick, state).
- `sample(render_milli) -> Dictionary{id: PackedFloat32Array}` for every entity alive at
  render time:
  - between two samples a <= r <= b: per-channel interpolation, alpha from milliticks.
  - r beyond newest sample: extrapolate LERP/ANGLE channels linearly from the last two
    samples for at most `extrapolate_cap_ticks` (default 6), then HOLD; SNAP holds.
    Counted: `extrapolated_frames`, `held_frames` (underrun observability).
  - r before oldest sample: hold the oldest.
- `local_ids` exclusion: `set_local(ids)` -- the client's own owned/predicted entity is not
  interpolated (sample omits it) but `latest(id) -> {tick, state}` and
  `state_at(id, tick)` expose host truth (system 2 reconciles from the host state at
  ack_tick; system 1 ignores it).

## Spawn/despawn timing [DECIDED B, Daniel 2026-10-05: render time]

Decided: at RENDER time. An entity first present in snapshot ht=S is spawned when
render time reaches S (signal `entity_spawned(id, kind)` from sample()); an entity absent
from snapshot S (after being present before) despawns when render time reaches S
(`entity_despawned(id)`). Otherwise things appear/vanish ~render-delay before their
interpolated motion says they should (a crate vanishes before it visibly reaches the pit).
Receive-time alternative is simpler but visibly early.
An id that despawns and reappears is a NEW spawn (ids should be monotone host-side; reuse
is tolerated and treated as despawn+spawn at the boundary).

## Event ring [DECIDED C, Daniel 2026-10-05: per-peer streams]

Decided: per-peer streams. (The body is still broadcast, so every peer receives every
`pl` section; a client reads only its own. Accepted: sections are small and per-peer
sends would need a transport change.) Host `CouchEventRing`:
- `push(peer_id, kind: int, payload: Variant, host_tick) -> int` -- id monotone PER PEER,
  starting at 1 each epoch.
- `pending_for(peer_id) -> Array` -- un-acked events (ids ascending), into `pl[peer].ev`.
- `ack(peer_id, last_applied)` -- from the peer's input body (key `"ev"`); drops <= it.
  Non-monotone/older acks ignored; an ack beyond the highest pushed id is clamped & counted.
- Ageing: an un-acked event older than `max_age_ticks` (default 2 s worth) is dropped and
  counted `expired_count(peer)` -- observable loss, never silent.
- `max_pending` per peer (default 64): overflow drops oldest, counted.
- `forget(peer)` on player_left, `reset()` on new epoch.
Client `CouchEventInbox`: `receive(events: Array) -> Array` returns events with
id > last_applied in ascending order, exactly once, across duplicates/reordering/stale
snapshots; detects a GAP (lowest pending id > last_applied+1 => events expired host-side)
and counts it (`gap_count`) instead of stalling; `last_applied` is what goes in input "ev";
`reset()` on epoch.
Alternative: one global stream with per-peer cursors -- every peer sees every event
(bigger snapshots, but spectators/other players could render others' impulses).

## Clock integration [DECIDED D, Daniel 2026-10-05: packer owns them]

Decided: the packer OWNS the 0c fields (ht + per-peer ack/rt/hm/mg) so games stop
carrying them by hand; key names short (wire size). 0c's echo keys (recv_tick/hold_ms/
margin) are mapped to rt/hm/mg by the packer; CouchNetClockEcho unchanged.

## Conventions

GDScript, tabs, `class_name Couch...`, RefCounted, `##` contract docs, typed. Timing math
integer (milliticks); entity state is float (game data). Nothing in netcode/ references
webrtc/ or lobby/. Do not touch existing files except: none needed.

## Gate G15: netcode/fixtures/run_replicated_world.gd

Headless SceneTree, seeded, virtual time, like G14. Cases (draft):
- W1 pack/ingest round trip through the REAL wire codecs (CouchEnvelope.to_json_frame ->
  decode, and the binary var_to_bytes path): ids/kinds/state bit-exact, extra passthrough.
- W2 malformed bodies each rejected with a distinct reason, world state unchanged; a
  same-stride channel-swapped layout on one side is rejected as `layout-mismatch`.
- W3 stale/duplicate/out-of-order snapshots ignored and counted; newest wins.
- W4 interpolation: LERP midpoint exact, ANGLE across +/-PI takes the short arc, SNAP steps
  at the newer sample's tick, alpha from milliticks.
- W5 extrapolation cap then hold; counters; resumes interpolating when data returns.
- W6 spawn/despawn at render time (not receive time); reappearing id = new spawn.
- W7 local exclusion: sample omits local ids; latest/state_at expose host truth.
- E1 ring: per-peer monotone ids; ack prunes; stale ack ignored; over-ack clamped+counted;
  ageing expires+counts; overflow drops oldest+counts; forget/reset.
- E2 inbox: exactly-once in order under dup/reorder/stale; gap detected and counted.
- S1 end-to-end _Sim: host + 3 clients, 0a-style delay/jitter/loss on each link (seeded),
  CouchFixedTicker + CouchNetClock + world + ring/inbox: every event applied exactly once
  per target peer or counted expired; no peer sees another's events; render never runs
  backwards; under 50+/-30 ms with snapshots every 2 ticks and a fitting render delay
  (set explicitly; 0c's default of 3 is NOT changed in 0d -- Daniel 2026-10-05),
  post-warmup held_frames == 0 and extrapolated_frames bounded; sampled positions of a
  constant-velocity entity track truth within a bound.
- S1b render-delay sweep (report, not a pass/fail threshold on the default): same sim at
  render_delay_ticks 2..8; print held/extrapolated frames per value and the smallest delay
  with post-warmup held_frames == 0. That number picks the future default.
- S2 new epoch: reset() on everything -> clean rebuild, no stale events re-applied.

## API contract (frozen 2026-10-05 for the gate writer and the implementer)

Where this section and the prose above differ, THIS section wins. New files only, all
under `netcode/`; nothing else in the repo changes except new `.uid` files from import.

### Files and classes
- `netcode/replicated_world.gd` -- `class_name CouchReplicatedWorld extends RefCounted`.
  ONE class used in either role: the kind registry is shared; host methods
  (`set_entity`/`remove_entity`/`pack`) and client methods (`ingest`/`sample`/...) live on
  the same object. A game uses one instance per role.
- `netcode/event_ring.gd` -- `class_name CouchEventRing extends RefCounted` (host).
- `netcode/event_inbox.gd` -- `class_name CouchEventInbox extends RefCounted` (client).
- `netcode/fixtures/run_replicated_world.gd` -- gate G15, `extends SceneTree`, same style as
  `run_net_clock.gd` (deterministic, no await, no Time reads, `_check`, one `quit()`
  followed by `return`). Final line on success: `G15 replicated world: N/N checks passed`;
  exit code 0 iff no failures; each failed check prints a line containing `FAIL:`.

Nothing in these files references `webrtc/`, `lobby/`, Nodes, or Time. Peer ids are
`String` (same as `CouchNetClockEcho`). Ticks are `int`; render time is MILLITICKS (`int`).

### CouchReplicatedWorld
```
const LERP := 0     # linear
const ANGLE := 1    # radians, shortest arc, result wrapped to [-PI, PI)  (wrapf(v, -PI, PI))
const SNAP := 2     # step

signal entity_spawned(id: int, kind: int)
signal entity_despawned(id: int)
signal rejected(reason: String)

var history_size: int = 8           # samples kept per entity life (client)
var extrapolate_cap_ticks: int = 6  # client

# read-only counters (client); reset() zeroes them
var stale_count: int
var rejected_count: int
var last_reject_reason: String       # "" until the first rejection
var extrapolated_frames: int
var held_frames: int

func register_kind(kind: int, channels: Array) -> bool
func layout_hash() -> int
# host
func set_entity(id: int, kind: int, state: PackedFloat32Array) -> bool
func remove_entity(id: int) -> bool
func has_entity(id: int) -> bool
func pack(host_tick: int, now_ms: int, acks: Dictionary,
          echo: CouchNetClockEcho = null, ring: CouchEventRing = null,
          extra: Dictionary = {}) -> Dictionary
# client
func ingest(body: Variant) -> bool
func newest_tick() -> int            # -1 before the first accepted snapshot
func peer_section(peer_id: String) -> Dictionary
func extra() -> Dictionary             # newest accepted snapshot's "x" (a copy), {} if absent
func set_local(ids: Array) -> void
func sample(render_milli: int) -> Dictionary   # int id -> PackedFloat32Array
func latest(id: int) -> Dictionary             # {"tick": int, "state": PackedFloat32Array} or {}
func state_at(id: int, tick: int) -> PackedFloat32Array   # exact sample, or empty
func reset() -> void
```

**register_kind**: `kind` in [0, 2^31-1], `channels` non-empty Array of ints each in
{LERP, ANGLE, SNAP}. Returns false (and registers nothing) if invalid or if `kind` is already
registered. Stride of a kind = channel count.

**layout_hash**: FNV-1a 32-bit over a sequence of ints, folding each int `v` as
`h = ((h ^ (v & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF`, starting from `2166136261`. The
sequence is, for each registered kind in ASCENDING kind order: `kind, channel_count,
channel_0 .. channel_n-1`. Independent of registration order. Empty registry -> 2166136261.

**set_entity** (host): false if `kind` unregistered, `state.size() != stride`, or
`id` outside [0, 2^31-1]; else stores a COPY (later mutation of the caller's array does not
change it). Re-setting an existing id with a different kind is allowed (replaces).
**remove_entity**: false if absent. State persists between packs until changed/removed.

**pack** (host). Returns a NEW Dictionary:
```
{
  "ht":    host_tick,
  "lh":    layout_hash(),
  "ids":   PackedInt32Array   # every current entity, ASCENDING id
  "kinds": PackedInt32Array   # same order
  "st":    PackedFloat32Array # states concatenated in that order
  "pl":    { peer_id: section } for every key of `acks`
  "x":     extra              # key present ONLY when extra is non-empty
}
section = {"ack": int(acks[peer_id])}
  + if echo != null and echo.echo_for(peer_id, now_ms) is non-empty:
      "rt" = recv_tick, "hm" = hold_ms, "mg" = margin
  + if ring != null: "ev" = ring.pending_for(peer_id)   (always present when ring given)
```
When `ring != null`, pack calls `ring.expire(host_tick)` once before building sections.
`pack` never mutates `acks`/`extra` and the returned arrays are not aliased to internal state.

**ingest** (client). `body` must be a Dictionary. Validation, IN THIS ORDER, first failure
wins; a rejection changes NO state except `rejected_count += 1`, `last_reject_reason`, and
the `rejected(reason)` signal:
1. not a Dictionary; `ht` or `lh` missing / not int; `ids` or `kinds` missing / not
   PackedInt32Array; `st` missing / not PackedFloat32Array; `pl` missing / not Dictionary;
   `x` present and not Dictionary                              -> `"bad-shape"`
2. `lh != layout_hash()`                                         -> `"layout-mismatch"`
3. `ids.size() != kinds.size()`                                  -> `"size-mismatch"`
4. any kind not registered                                       -> `"unknown-kind"`
5. an id repeated                                                -> `"duplicate-id"`
6. `st.size() != sum of strides`                                 -> `"bad-state-length"`
7. any `pl` key not a String, or value not a Dictionary, or a value whose `ack`/`rt`/`hm`/
   `mg` is present and not int, or whose `ev` is present and not an Array
                                                                  -> `"bad-peer-section"`
Then: if `ht <= newest_tick()` -> `stale_count += 1`, return false, no signal, no state
change. Otherwise accept: return true, `newest_tick() == ht`.

Accepting snapshot at tick S updates each entity's LIFE:
- id present in S with no current life, or whose current life has a despawn tick set, or
  whose current life's kind != the kind in S -> the old life (if any, and if not already
  despawning) gets despawn tick S, and a NEW life starts with spawn tick S.
- id present in S in a live life of the same kind -> append sample (S, state) to that life,
  keeping at most `history_size` newest samples.
- id in a live life but absent from S -> that life gets despawn tick S (it keeps its samples).
Lives whose despawn has been rendered and whose despawned signal fired may be discarded.

**peer_section(peer_id)**: from the NEWEST ACCEPTED snapshot: `{}` if none or the peer has
no section; else `{"ht": newest_tick(), "ack": int, "ev": Array}` plus `"rt","hm","mg"` when
present on the wire (`"ev"` is `[]` when absent on the wire, `"ack"` is -1 when absent).

**sample(render_milli)**. If `render_milli` is lower than the previous call's value, the
previous value is used (render never runs backwards; no signal fires twice).
Let `r = render_milli`. A life is ALIVE at r iff `r >= spawn*1000` and (no despawn tick or
`r < despawn*1000`).
- Signals (REVISED 2026-10-05 after implementation review): each life fires
  `entity_spawned` exactly once, on the first call with `r >= spawn*1000`, and
  `entity_despawned` exactly once, on the first call with `r >= despawn*1000` (and never
  before its own spawned). A spawn/despawn tick that is ALREADY <= r when its snapshot is
  ingested (a late snapshot: render time had passed it) still fires, on the next call --
  fire-once flags, not "crossed since the previous call", or a late snapshot would create a
  never-spawned entity or a never-despawned ghost. Within one call: ascending tick; at an
  equal tick despawns before spawns; ties by ascending id. A life whose spawn AND despawn
  are both due in one call fires both (spawned first). Local ids fire NO signals, and a
  life's spawn/despawn that comes due while its id is local is CONSUMED silently (it is
  not announced later if the id stops being local: the game already owns that node).
- Returned Dictionary: one entry per non-local id with an ALIVE life, value computed from
  that life's samples (never mixes lives):
  - a <= r <= b for consecutive samples a, b: per channel with
    `alpha = float(r - a*1000) / float((b - a) * 1000)`: LERP `va + (vb - va) * alpha`;
    ANGLE `wrapf(va + wrapf(vb - va, -PI, PI) * alpha, -PI, PI)`; SNAP `va` if
    `r < b*1000` else `vb`.
  - r beyond the newest sample n with a previous sample p: `rc = min(r, (n + extrapolate_cap_ticks) * 1000)`,
    `k = float(rc - n*1000) / float((n - p) * 1000)`; LERP `vn + (vn - vp) * k`;
    ANGLE `wrapf(vn + wrapf(vn - vp, -PI, PI) * k, -PI, PI)`; SNAP `vn`.
  - r beyond the only sample, or before the oldest kept sample: that sample's values (hold).
  - Exactly at a sample tick, LERP/ANGLE equal that sample's values (alpha 0 or 1).
- Counters, once per call (not per entity), only after at least one accepted snapshot:
  if `r > newest_tick()*1000`: `extrapolated_frames += 1` when
  `r <= (newest_tick() + extrapolate_cap_ticks)*1000`, else `held_frames += 1`.

**set_local(ids)**: replaces the local set. Local ids are buffered like any other (so
`latest`/`state_at` work) but omitted from `sample()` and its signals.
**latest(id)**: newest sample of the id's current life, `{}` if none. **state_at(id, tick)**:
the current life's sample at exactly `tick`, else empty array.
**extra()**: copy of `x` from the newest accepted snapshot, `{}` when absent or none.
**reset()** (new epoch): clears host entities, every life, extra, newest tick, local set, render
memory and all counters; keeps the kind registry.

### CouchEventRing (host)
```
var max_age_ticks: int = 120
var max_pending: int = 64
func push(peer_id: String, kind: int, payload: Variant, host_tick: int) -> int
func expire(host_tick: int) -> void
func pending_for(peer_id: String) -> Array   # [[id, kind, payload], ...] ascending id; outer AND inner arrays are new (payload itself not deep-copied)
func ack(peer_id: String, last_applied: int) -> void
func highest_id(peer_id: String) -> int      # highest id ever pushed to this peer this epoch (kept across forget); 0 if none
func expired_count(peer_id: String) -> int
func overflow_count(peer_id: String) -> int
func over_ack_count(peer_id: String) -> int
func forget(peer_id: String) -> void
func reset() -> void
```
- `push` returns the new id: per peer, 1, 2, 3, ... within an epoch. If pending then exceeds
  `max_pending`, the OLDEST pending event is dropped and `overflow_count += 1`.
- `expire(t)`: drops every pending event with `t - event_host_tick > max_age_ticks`,
  `expired_count += 1` each.
- `ack(peer, n)`: `n <= ` the peer's acked id -> ignored. `n > highest_id` -> clamped to
  `highest_id`, `over_ack_count += 1`. Then drops pending events with id <= n.
- `forget(peer)` (player_left): drops the peer's pending events and its expired/overflow/
  over_ack counters but KEEPS its next id and its acked id, so a returning peer's ids stay
  monotone within the epoch and an old ack is still ignored.
- `reset()` (new epoch): everything, ids restart at 1.

### CouchEventInbox (client)
```
func receive(events: Variant) -> Array   # newly applicable [id, kind, payload], ascending
func last_applied() -> int               # 0 initially; goes in the input body as "ev"
var gap_count: int
var lost_count: int
var malformed_count: int
func reset() -> void
```
- Non-Array `events` -> `[]`, `malformed_count += 1`. Elements that are not an Array of size 3
  with int id >= 1 and int kind -> skipped, `malformed_count += 1` each.
- Of the valid elements, take the unique ids > last_applied in ascending order (a duplicate
  id inside one call is applied once); for each: if `id != last_applied + 1` ->
  `gap_count += 1`, `lost_count += id - last_applied - 1`; return it; `last_applied = id`.
- `reset()` (new epoch): last_applied 0, counters 0.

### Game wiring this enables (documented in the class `##` docs, not library code)
Host per snapshot: `body = world.pack(tick, now, acks, echo, ring, extra)`;
`session.broadcast_snapshot(body)`. Host on input from peer: drop stale-epoch inputs, then
`echo.note_input(...)` and `ring.ack(peer, int(input_body.get("ev", 0)))`.
Client on snapshot: `if world.ingest(body): ps = world.peer_section(me); clock.on_snapshot(ps.ht, now);
if ps.has("rt"): clock.on_echo(ps.rt, ps.hm, ps.mg, now); for e in inbox.receive(ps.ev): apply(e)`.
Client per frame: `world.sample(clock.render_tick_milli(now))`.
