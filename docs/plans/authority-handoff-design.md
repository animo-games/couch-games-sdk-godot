# Authority handoff for pushed props (finding 14)

Status: REV 3 STEP 1 BUILT (2026-10-08, demo b4d5ea3, see "Rev 3" at the end). Next goal: adaptive render delay (Daniel, option 1). PHASES 1 AND 2 BUILT (2026-10-07, Daniel approved rev 2 "try phase one first", then
"start phase 2"): demo a7b8416 (phase 1, prediction) and 9ac1b24 (phase 2, handoff). Results at
the end ("Outcome"). Design text below is rev 2 as approved.
Was: DESIGN rev 2, awaiting Daniel's review (2026-10-07). No code yet. Rev 2 folds in a Fable
frame review: build owner-side PREDICTION first (phase 1), promote to full handoff (phase 2) only
if the measured release jump says so; four lifecycle flaws fixed (see "Rev 2 changes"). Consumer: the netcode demo
(`~/Repositories/couch-netcode-demo`, step 3a); addon changes only in phase 2, and only with
Daniel's OK.

## Problem

In system 1 a player owns its body and the host owns every prop. A guest pushing the crate walks
into its crate copy, which moves only after input -> host -> push -> snapshot -> render delay,
about RTT + 100 ms. At 250 ms RTT and ~270 px/s that is ~95 px: through a 56 px crate. Daniel,
watching the 2026-10-07 latency clips: "the guests go way too far into the crates ... not
shippable". It is inherent (finding 14 measured ~45 px at ZERO delay), and neither lever fixes
it: colliding with the delayed copy deadlocks (finding 3), and lower render delay only shrinks it.

Lesson recorded with it: every gate so far measured owner-vs-host error. None measured what a
player sees, which is penetration into props. This design adds that metric and gates on it.

## The idea

While a player pushes a prop, that player OWNS it: its client simulates the prop as a real body,
collides with it and pushes it with zero latency, and reports the prop's state exactly as it
reports its own body. The host's prop follows that report with the same PD follower a stand-in
uses, and everyone else displays the host's prop as before. When the player lets go and the prop
settles, ownership returns to the host. The owner has an object it touches that does what it
expects, now; disagreement moves to the rare case of two players touching one prop.

Same rule as per-entity-authority-netcode.md ("each body has exactly one simulating owner;
everyone else displays it"), with the owner of a prop allowed to change at runtime.

## Phasing (rev 2)

The sinking is visible on the pusher's (P's) screen only, so it is fixed entirely on P's machine:
while P touches the crate, P simulates it locally as a real body P collides with and pushes; when
P lets go and it settles, P blends back to the interpolated puppet. The host keeps pushing its
crate from P's stand-in through CrateContacts exactly as today (58dd282), and both start the push
from the same contact, so the host's crate trails P's by about one-way delay, which only others
see (the same as handoff's table below).

- **Phase 1: prediction, owner-only, zero host change.** Claim / grant / deny do not exist. What
  it can get wrong: P's local crate and the host's drift apart during a long push (the
  speed-matching push vs a real solver contact, mostly rotation), which shows as a jump when P
  hands back to the puppet. That is measured (release jump metric below), not guessed.
- **Phase 2: handoff (the lifecycle below), only if phase 1's release jump fails its gate** or
  Daniel wants Q's bumps on P's crate. Adds: host crate tracks P's report exactly (release jump
  ~0), and contacts by others reach P. Everything phase 1 builds (freeze toggle, local push,
  present-time start, penetration metrics) is reused.

## Lifecycle of one prop (phase 2: handoff)

```
            claim granted                       release, or owner stale / left
 HOST-OWNED ------------------> OWNED by peer P ------------------------------> HOST-OWNED
   ^   host simulates it;          P simulates it; host prop = PD body chasing      host resumes from
   |   CrateContacts pushes it     P's report; others' contacts become impulse      its own (PD-tracked)
   |   (58dd282)                   events to P + knocks to the toucher              state: no jump
```

### Owner side (peer P)
1. Prop host-owned and P's controller comes within a contact margin of its prop copy (gap <
   margin, NOT overlap: a body spawned around an overlapping CharacterBody2D depenetrates or
   sticks) -> P **claims optimistically**: its ONE crate node, a RigidBody2D frozen kinematic
   while a puppet, is unfrozen at its best estimate of NOW (`world.latest(CRATE_EID)` advanced by
   one-way + render delay; NetOwner must keep the newest snapshot's receive time), its
   controller starts colliding with it, and P pushes it from this frame on. (Phase 1 stops here
   and below drops the host side.)
2. While owned: P steps the prop locally (RigidBody2D, walls, P's controller pushing it by
   applying its contact impulse - CharacterBody2D does not push rigid bodies by itself), and
   reports the prop state in EVERY input while it believes it owns it (`"p": {"id", "t", "o"}`:
   `note_input` requires `"t"`), same alignment rule as the player body. Level-triggered:
   inputs are latest-wins, so a one-shot claim or release could be lost; presence of `"p"` IS
   the claim, absence IS the release.
3. Release: no contact with P for `RELEASE_IDLE_MS` (300) AND prop speed < `SETTLE_SPEED`
   (10 px/s) -> P stops sending `"p"` and refreezes the prop as a puppet. Because
   the prop is at rest, the delayed puppet and the local body agree: nothing visible happens.
4. Denied (a snapshot says someone else owns it, or no grant within `CLAIM_TIMEOUT_MS` = RTT +
   margin): revert to the puppet, blended over ~100 ms rather than snapped.

### Host side
- Grant on the first valid claim for a host-owned prop (arrival order). Ignore claims for an
  owned prop. Ownership is published in the snapshot (`owner` per prop), which is also the
  grant/deny answer.
- While owned by P: the host prop is a PD-driven RigidBody2D chasing P's report
  (`target_for`), exactly like a stand-in. CrateContacts no longer pushes it directly:
  - P's own stand-in vs P's prop: skipped (P resolved it locally).
  - Another player Q's stand-in vs the prop: Q gets the impact knock as today, and P gets the
    ONCE-PER-CONTACT impact (`J = reduced mass * closing`, opposite sign) as an impulse event for
    the prop. The per-frame speed-matching push never leaves the host: the host prop is
    PD-driven and does not move from Q's push, so Q would keep closing and emit a full push
    every frame for a whole RTT (~15 events at 250 ms), all applied to P's crate one way later
    (the double count `owner_targets.gd` 45-47 warns about). Q sinking for one RTT is the stated
    residual.
  - Prop impulses use a GAME event kind (>= 0) pushed with `ring.push`, never
    `push_impulse`: that hardcodes `IMPULSE_EVENT_KIND = -1`, which `impulse_of` applies to P's
    PLAYER body. Not a preference: forced by the phase-2-without-addon-change trick.
- Take-back: when P's inputs stop carrying `"p"`, on P stale (> `stale_ms`, 500), or on P leaving. The host prop
  is already at P's last reported state (PD-tracked), so the host simply stops driving it and
  lets its own physics continue; for a stale/left owner the prop keeps its PD velocity.

### What each screen shows
| Situation | P (pusher) | Others |
|---|---|---|
| P pushes a free prop | solid, immediate push | prop moves ~one-way + render delay late (as any remote motion) |
| P pushes a prop into a wall | blocked by it, no sinking | P's puppet blocked (P's reported body is) |
| Q bumps a prop P owns | prop jolts one round trip later | Q passes in, knock reaches Q one RTT later (as today) |
| P and Q claim the same free prop | first claim wins; loser's local copy blends back (~100 ms) | - |

The only remaining sinking is a player touching a prop someone ELSE is pushing. That needs two
players on one prop and lasts one round trip; it is the residual cost, stated.

## Decisions

### [DECIDE H1] How the pusher gets a solid crate
1. **Phase 1: owner-side prediction without authority; phase 2 handoff with an optimistic,
   level-triggered claim only if the release jump fails** (recommended, rev 2). The host stays
   authoritative throughout phase 1; local copies are predictions that reconcile at release.
2. Handoff straight away (rev 1's pick). Same visible result for the pusher; more moving parts
   (arbitration, take-back, prop events) before we know they are needed.
3. Host detects contact, then grants. The toucher sinks one round trip before owning: the bug,
   halved.

### [DECIDE H2] When ownership (phase 1: prediction) returns
1. **Idle + settled: no contact for 300 ms and speed < 10 px/s, then stop reporting (level-
   triggered);
   host also takes it back on stale or leave** (recommended). Settled release makes the
   handback invisible.
2. Release on contact end. A pushed prop still sliding would jump back by the render delay.
3. Never release (owner keeps it until someone else claims). Ownership piles up on whoever
   touched last; a stale owner freezes props.

### [DECIDE H3] Contention while owned
1. **No stealing: others' contacts become ONE impact event per contact to the owner**
   (recommended; rev 2: impact only, never the per-frame push). One simulator at a time,
   exactly-once delivery through the existing ring. Phase 2 only.
2. Transfer ownership on any contact. Thrashes when two players push together.

### [DECIDE H4] Where it is built
Phase 1 (prediction) is demo-only and touches no host code and no addon code. For phase 2:
1. **Demo only, no addon change** (recommended): a SECOND `CouchOwnerTargets`
   instance for props (it holds one entity per peer, so a peer owns at most one prop at a time,
   which is enough for the demo's one crate and is what a player can push anyway), prop
   impulses as a GAME event kind (>= 0) in the existing ring, so no impulse compensation for
   props yet. Proves the feel in clips at 50 / 150 / 250 ms before any API is frozen.
2. Addon first: step "1.2 handoff" with multi-entity ownership and entity-addressed impulses.
   Right end state, wrong order: it freezes an API before we know the feel is good.
   Phase 2 (after Daniel likes phase 1): exactly this, gate-first, its own design doc.

### [DECIDE H5] How the owner pushes its local prop
1. **Controller collides with the prop and applies the contact impulse (mass ratio) to it**
   (recommended): the standard CharacterBody2D-pushes-RigidBody2D recipe; slowing the player
   while pushing comes for free if the controller keeps the post-slide velocity. Local walls and
   crate friction 0, as on the host (finding 18).
2. Make the controller a RigidBody2D. Changes the player model of the whole demo.

## Verification (the shippability gate that was missing)

New smoke metrics, GATED at both 40/15 and 250 ms (the complaint is at 250, and the metric does
not depend on latency by design), measured at 150:
- **Owner penetration**: on EVERY frame P's body touches the crate AS DISPLAYED ON P'S SCREEN,
  the depth of P into it, unconditionally (before a claim, after a denial, during a blend: the
  windows where sinking would come back). Gate: max of a few px (contact slop).
- **Observer penetration**: depth of other players' puppets into the prop on each screen
  (measured, not gated: contention cases are expected).
- Handoff counts: claims, grants, denials, releases, take-backs (stale / left); a bot that
  pushes the crate (the existing `--bot=crate`) so every run exercises a grant and a release.
- **Release jump**: distance between P's local crate and the puppet position at the frame P hands
  back, and the claim jump at the frame P takes over. GATED in clean runs (bound set from the
  measurements, method of [DECIDE K]); this is the number that decides phase 2.
- Host prop vs owner's local prop error while predicted / owned.
- Scenario runs, not only wander bots: a crate-pushing bot (`--bot=crate`) every run; a wall
  push (crate pinned on a wall); contention (host player + a bot on one crate).
- Mutants: no prediction (penetration gate fails), release while sliding (release-jump gate
  fails), phase 2: per-frame push events (crate flies; contention run fails).
Then a recorded 250 ms clip for Daniel next to the 2026-10-07 one.

## Out of scope / follow-ups

- Phase 2 addon API (multi-entity ownership, entity-addressed impulses with compensation).
- More props per peer, prop-prop contacts while owned by different peers (each owner simulates
  its own; their contact resolves one RTT late on the host).
- The defaults goal (render delay too short at 150+ ms) is independent and still open.

## Rev 2 changes (Fable frame review, 2026-10-07)

1. Prediction first (H1, H4): handoff only if the release jump fails.
2. Contention sends the once-per-contact impact only, never the per-frame push (H3); the push
   would have arrived ~15 times at 250 ms and flung P's crate.
3. No body spawned around an overlap: one crate node, kinematic-frozen as a puppet, unfrozen to
   predict; trigger on a contact margin, not overlap.
4. Claim / release level-triggered (presence of `"p"`), since inputs are latest-wins; `"p"`
   carries `"t"`.
5. Prop impulses must be a game event kind: `push_impulse` hardcodes kind -1 = player body.
6. Penetration measured as displayed on P's screen, unconditionally, and gated at 250 too;
   release / claim jump gated in clean runs; wall and contention scenarios added.

## Outcome (2026-10-07)

- Phase 1 (a7b8416): penetration on every screen 0 px, but the release jump failed: one pusher
  28-110 px (controller-contact push vs stand-in overlap push diverge ~100 px over a 3 s push),
  three pushers up to ~585 px. That triggered phase 2, as designed.
- Phase 2 (9ac1b24): host crate PD-follows the owner's reported copy. Final tree, 18 runs per
  transport at 40/15 and 9 at 250 ms: penetration into a free or own crate 0.0 px on every
  screen, release jump max 2.8 px over 136 releases (p50 ~2). Gated in smoke_check at any delay:
  penetration <= 2.0 px, release jump <= 4.5 px, plus a grant, a release and an impact per run.
  Mutants (no prediction / never grant / no impacts) each fail their own gate 4/4.
- Implementation deviations from the text above: crate knocks for one's own contact are gone
  (every player is blocked by its own copy; a knock would double it); the host's own player
  holds the crate while touching it and releases on idle alone; a crate the snapshot still lists
  as mine is claimable, and "co" == me counts as a grant only a round trip after the claim;
  LAYER_CONTROLLER so a crate thrown at a standing player stops at it.
- Residuals, measured: a player touching a crate someone ELSE holds walks in (up to 46 px, fully
  through) and gets one knock a round trip later; claiming a crate that is already moving jumps
  it from the delayed puppet to the present (up to ~40 px, seen once).
- Next candidates: (a) non-owners collide with a held crate's puppet and their contact impulses
  go to the owner (solid contention); (b) blend the claim jump; (c) phase 3 = addon API:
  multi-entity ownership in CouchOwnerTargets and entity-addressed impulses with compensation.
- 250 ms clip recorded 2026-10-08 (`~/Videos/rtt250-handoff2.mp4`). Daniel: "looks pretty good
  overall but now the host seems to pass through the crate the most". Measured: the host is inside
  a crate someone else holds ~80 frames per run (every run), guests ~43 (two thirds of players).
  Cause: `set_crate_collision(host_simulated)` turns host collision off while a guest owns it.

## Rev 3: one contact rule (Daniel approved step 1, 2026-10-08)

Daniel rejected a host-only patch as a band-aid and asked for the principled answer. Fable
advised (2026-10-08), and Daniel approved step 1.

**The trade-off.** At 250 ms, two players touching one rigid prop cannot both see a lag-free,
consistent result. Someone sees (a) walking through it, (b) being stopped by a solid prop whose
response comes a round trip late, or (c) a correction afterwards. Host-authoritative props with
prediction pay (c) all the time and bring back finding 14's sink, since Godot physics cannot
rewind. Rollback and lockstep need deterministic physics. Owner authority with handoff is the
model Unity NGO distributed authority and Photon Fusion shared mode use. **Decision: keep owner
authority with handoff, and pay with (b), never (a).**

**The rule.** Every controller is always solid against the prop as drawn on its own screen.
Exactly one peer simulates a prop. Anyone else's push is a per-tick press forwarded to the
simulator, never an ownership change and never a knock.
- A non-owner's controller (host included) collides with its local copy: the host with the
  PD-following crate, a guest with the render-delayed puppet. It pushes the body only when this
  peer simulates it. Otherwise it reports a press (normal, into-speed, contact offset, from the
  velocity before the slide) in that tick's input.
- The host forwards presses to the owner (latest-wins, loss-tolerant, no ring). The owner applies
  them as a force. If the host simulates the crate, it applies them directly.
- **Goes:** `CrateContacts.step` (stand-in overlap push), `CrateContacts.impacts` (knocks), the
  `CRATE_IMPULSE_KIND` events, the host crate-collision toggle, and the penetration exemption for
  crates other players hold.
- **Stays:** claim, grant and release, `CrateAuthority`, `Crate.follow`, `CrateContacts.contact`,
  and the metrics.

**Steps, each gated at 250 ms on what each player sees:**
1. Everyone solid, with presses forwarded (demo only). Gate: penetration <= 2 px on every screen,
   with no ownership exception. A presser's view of a held crate starts moving within RTT + 150 ms.
   A no-forwarding mutant fails that gate. Then a clip for Daniel.
2. Transfer on uncontested press (the owner releases on idle when someone else is pressing), and
   blend the claim jump. Gate: claim jump <= 4.5 px.
3. Promote to the addon (multi-entity ownership, press stream, prop authority). This is an
   addon API change, so it needs Daniel's OK after the step 1 clip.

**Risks:** pressing someone else's crate feels heavy for ~RTT at 250 ms (only a clip settles it);
coalesced presses could jitter the owner's crate; a kinematic puppet shoving a CharacterBody2D
depends on depenetration. On a third screen, a presser can look slightly inside the crate, since
stand-ins never collide with it. Step 1 measures that too.

Step 1 state: BUILT and committed, demo b4d5ea3 (2026-10-08). Converge loop: Luna
explore, Opus plan + delta, Fable plan checks x2, Opus writer, Sol reviews x2.
- Implementation changes found on the way: the guest puppet freezes STATIC (a frozen KINEMATIC
  body went to sleep on first controller contact and stopped tracking its node: guests walked
  45 px into it); an idle owner releases only when the puppet shows the crate within
  RELEASE_MATCH_PX (1 px) of its copy and no forwarded press is still queued (an instant "slow"
  read at a wall bounce released with a 23 px jump); the host crate drops the controller layer
  while a guest holds it (one-way: the host is blocked and presses, the crate keeps following).
- Harness: a scripted press phase (--bot-press-at 9): the host places the crate at rest in open
  floor once it simulates it, guest slot 1 claims it and stands, the host presses it sideways.
- Gate (b), final form: judged only for presses that start while the crate as drawn on the
  presser's screen is at rest (and not wall-blocked or opposed); response = moved >= 1 px along
  the press direction; bound = path rtts + snapshot interval + render delay + 150 ms. Two earlier
  forms (a velocity course; "responded or held") misread the crate's own damped motion.
- Single runs: own penetration 0.0 px on every screen at 40/15 and 117/15, both transports;
  release jump <= 1.0 px; host->guest response 166 ms (bound ~280) at 40/15, 318-331 ms (bound
  ~430) at 117/15. Mutants: no forwarding, guest collision tied to prediction, wrong press sign
  each fail their own gate.
- Deferred (Sol, review 2): a forwarded press still in flight when the owner releases is dropped
  (the host never applies it). Loss is bounded to one one-way trip of presses at release; the
  principled fix is a host-acknowledged release, which belongs with step 2's release redesign.
- Coverage gap: gate (b) judges only the scripted host->guest press. Guest->host-simulated and
  guest->guest presses are counted and printed, not gated; the host-applies-guest-press path was
  not exercised in these runs. Step 2's harness should add a guest press on a host-held crate.
- Measured, not gated: other players drawn inside the crate on third screens, 15-33 px.
- Known (pre-existing): the shockwave pushes a guest-held crate directly on the host; under the
  rule it should be a press to the owner.
- Batches (2026-10-08, c18/c250 in the session scratchpad): 40/15 lobby 18/18 and star 18/18 PASS.
  117/15: every run fails only the error p50/p95 bounds (tuned for 40/15), EXCEPT 2 of 9 lobby
  runs where guest2 read 4.5 and 13.2 px into the crate for ONE render frame. Cause: with a late
  or lost snapshot the guest extrapolates the crate puppet up to ~12 px into the bottom wall; the
  next snapshot snaps it back ~15 px into the guest standing beside it; the controller is pushed
  out on its next physics step. Not caused by the contact rule (render delay 6 is too short at
  250 ms, already evidenced by the latency run). DECIDED (Daniel, 2026-10-08, option 1): commit step 1 as is, keep the gate
  strict (these count as known failures at 117/15), and make the real fix the next goal: a
  render delay that adapts to latency and loss so the crate is never drawn through walls or
  snapped back. Rejected: clamping extrapolation at walls (symptom only) and gating only
  overlaps of two frames or more (a band-aid).
- Clip: `~/Videos/rtt250-contact1.mp4` (star, 250 ms; the game starts ~2 s into the video).
