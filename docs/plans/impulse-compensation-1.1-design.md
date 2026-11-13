# Step 1.1 design: host-side compensation for un-acked impulses (gate G17)

Repo: /home/daniel/Repositories/couch-games-sdk-godot. Branch `feat/impulse-compensation` from
`main` c9afe31 (step 1, PR #26, merged 2026-10-05). Roadmap step 1.1; [DECIDE G] option 2 of
`owner-authority-step1-design.md`.
STATUS: BUILT 2026-10-05, committed locally f90557e on feat/impulse-compensation (PR #27 open). G17 197 checks, mutations 80/82 red (2 equivalent), full matrix green. Decisions H-O settled
(Daniel: "all recommended"); contract frozen 2026-10-05.

## The problem, measured first

Host knocks a stand-in at host time T0 (`push_impulse`). The event reaches the owner ~d later,
the owner applies it, and its first report that reflects it (the COVERING report: first accepted
report with `"ev" >= id`) reaches the host at Tc ~= T0 + RTT. `target_for` treats every report as
"now", so in the host's view the knock starts at Tc, not T0.

A 1-D model (`docs/plans/impulse-compensation-model.py`, untracked: dv = 200, owner velocity decays with time
constant 167 ms like G16's toy body, default settle 150 ms, symplectic Euler at 60 Hz) gives, as
"retreat" (largest backward move after a forward peak) and "lag50" (time from T0 until the
stand-in has covered half of its final knock displacement; physics alone needs ~116 ms):

| RTT | today (no comp) | drop at cover, dx = dv*t | drop at cover, tau = 167 | hand-off, tau = 167 | hand-off, tau = 500 | hand-off, tau = 60 |
|---|---|---|---|---|---|---|
| 50  | retreat 0.2, lag 150 | 0.0, 133 | 0.0, 133 | 0.0, 100 | 1.9, 83 | 0.0, 150 |
| 150 | 0.2, 250 | **10.0**, 67 | 3.1, 100 | 0.0, 100 | 8.5, 83 | 0.0, 233 |
| 250 | 0.2, 350 | **26.9**, 67 | 7.0, 100 | 0.0, 100 | 16.0, 83 | 0.0, 333 |

(Fable re-ran it with discrete per-tick reports, the one-tick displacement the covering report
already carries, and target_for's extrapolate/hold: hand-off tau 120 still gives retreat 0.0 and
lag50 ~100 ms at all three RTTs.)

Two corrections to the step-1 framing:
1. At the default spring stiffness the visible artefact today is mostly DELAY (~RTT + 100 ms),
   not a back-and-forth: even if the host applies J to the stand-in directly, the stiff spring
   absorbs it in a tick or two (peak ~2 units), then nothing happens until Tc. G16 S1's knock
   window error of 6 matches this. "Rubber band" is the right word only for a soft spring.
2. The obvious fix (shift the target by dv*t until covered, then drop) puts a backward target
   step of ~|dv|*RTT at Tc, because the covering report shows the impulse only just begun. At
   250 ms that is a 27-unit retreat with linear dx = dv*t -- worse than today. With a decaying
   model it shrinks to 7 units, but it is still a backward move the hand-off removes entirely
   for one extra number per entry.

## The model (recommended; the [DECIDE] points below pick its details)

Each impulse i has dv_i = J_i / m, dw_i = aj_i / inertia (0 if inertia == 0), push time T0_i,
and, once covered, cover time Tc_i. The library predicts its displacement with a decaying
velocity, P(s) = dv * tau * (1 - exp(-s / tau)) for s >= 0, velocity P'(s) = dv * exp(-s / tau).
The compensation added to the target is

    offset_i(t) = P(t - T0_i) - P(t - Tc_i)          (second term 0 until covered)

Equivalently, and how it should be coded: before the cover the lead is P(t - T0) with velocity
P'(t - T0); at Tc the lead is frozen at L = P(Tc - T0) and from then on decays,
offset = L * exp(-(t - Tc) / tau), velocity -L / tau * exp(-(t - Tc) / tau). An entry is {dv, t0}
until covered, then {lead, tc}. The error bound is just "never more than L".

Before the cover the lead grows from T0. From Tc the reports themselves carry the impulse
(starting from ~0 displacement), so the second term subtracts exactly what the reports will
add if the model is right. The sum of offset and reports is then P(t - T0) at every moment: an
immediate response, no step at Tc, and the offset decays to 0 (the owner stays authoritative).
If the model is wrong, the error is bounded by |dv| * tau * (1 - exp(-RTT / tau)) <= |dv| *
min(tau, RTT) and decays with tau. A tau that is too SHORT is safe (falls back toward today's
delay); a tau that is too LONG overshoots (table above). tau = infinity (pure dv*t) never
decays, so it is not allowed.

## Decisions

### [DECIDE H] Drop at cover vs hand-off
[DECIDED: recommended option, Daniel 2026-10-05]
1. Drop the entry when covered (the pickup's starting idea). Simple, but adds a backward step
   at Tc: 27 units at 250 ms with dx = dv*t, 7 units with the decaying model.
2. **Recommended: hand-off as above.** One extra number per entry, and two one-line formulas
   (growing lead, decaying lead). Entries are pruned once `t - Tc > 8 * tau` (residual < 0.04% of |dv| * tau).

### [DECIDE I] The velocity model and its knob
[DECIDED: recommended option, Daniel 2026-10-05]
1. **Recommended: exponential decay, one `impulse_tau_ms: int` on CouchOwnerTargets (default 120),
   applied to linear and angular alike.** Default deliberately on the short side, because too
   short only loses some benefit and too long overshoots. Games with floaty bodies raise it.
2. Per-owner tau passed to `set_owner` (next to mass / inertia). More precise for mixed body
   types; changes set_owner's signature again. Could be added later as an override.
3. Constant velocity with a hard cap on t. Needs a drop or a blend at the cap anyway, and is
   worse at both ends.
Gravity, friction against a wall, and collisions are not modelled; the bound above is the worst
case and G17 measures it with a wall-like case (owner velocity zeroed after the knock).

### [DECIDE J] Which "ev" counts, and how "ev" is validated (CONTRACT CHANGE to note_input)
[DECIDED: recommended option, Daniel 2026-10-05]
Compensation must key on the `"ev"` of the latest ACCEPTED report, never on `ring.ack`: the
wiring acks before `note_input`, so a malformed or stale-tick input still advances the ring
while the stored report predates the impulse (the ALIGNMENT RULE ties `"o"` to its own body's
`"ev"`). So note_input starts reading `"ev"`.
1. **Recommended:** `"ev"` missing -> 0 (inputs built without an inbox stay valid). Present but
   not an int, or negative -> rejected as `"bad-shape"` (same step as `"t"`). On accept,
   covered_ev = max(covered_ev, ev): a lower ev on a newer tick does not un-cover (the inbox is
   monotone; the ring also ignores lower acks). An ev higher than any impulse id is legal: ring
   ids are shared with game events pushed straight to the ring, so CouchOwnerTargets cannot know
   the highest id; it simply covers every impulse <= ev.
2. Same, but a bad `"ev"` is treated as 0 instead of rejecting the report. Keeps the position
   but hides a broken owner; inconsistent with how `"t"` is handled.
Cover time Tc_i = now_ms of the accepted report that first raises covered_ev to >= id_i.
Known approximation: if the first covering report is lost, the next one already shows a tick or
two of the impulse and the hand-off assumes 0, so up to |dv| * (lost reports * tick) of extra
lead (~3 units per lost report at dv 200, 60 Hz). Even with no loss the covering report already
holds one tick of the impulse (the ALIGNMENT RULE: apply, step, then report), ~3 units; the
discrete model shows no visible effect.

### [DECIDE K] Where the push time comes from (CONTRACT CHANGE to push_impulse)
[DECIDED: recommended option, Daniel 2026-10-05]
`push_impulse(ring, peer, J, aj, host_tick)` has no wall time and the target maths is in ms.
1. **Recommended: add a required `now_ms: int` as the last parameter.** The API merged today and
   no game calls it yet; G16's call sites get the extra argument (count unchanged).
2. Optional `now_ms: int = -1` meaning "do not compensate". Keeps the signature but makes
   compensation silently opt-in per call.
3. A separate `note_impulse(peer, id, J, aj, now_ms)`. Lets games push impulses through the ring
   themselves, but splits one action across two calls that must agree.

### [DECIDE L] Timeouts, staleness, extrapolate cap, lifecycle
[DECIDED: recommended option, Daniel 2026-10-05]
1. **Recommended:**
   - Not covered within `impulse_timeout_ms` (default 1000, well inside the ring's 120-tick
     expiry): handed off at T0 + timeout as if covered then (counted in
     `impulse_timeout_count`). The stand-in drifts back over ~tau instead of jumping. This is
     for a peer that stops reporting. An event the ring expired or overflowed is covered the
     normal way: the owner's inbox skips the gap, its next ev passes the id, and the lead
     decays (correct, since nobody will apply it).
   - Known, not worth code: if reports stop right after the cover, the target is held while the
     lead keeps decaying, a small retreat (~3 units for a 150 ms gap at dv 200).
   - Compensation is independent of report age: applied below and above `extrapolate_cap_ms`
     and in HOLD-stale (a parked stand-in that gets knocked moves by ~|dv| * tau, then drifts
     back via the timeout). REPORT_ONLY-stale and before the first report: target stays empty.
   - Velocity channels get the offset's velocity (sum of dv * exp terms) on top of the report's
     or the held zero, so the follower's feed-forward agrees with the shifted position.
   - Rotation: the angular offset is added, then wrapf to [-PI, PI].
   - `set_owner` (replace), `forget`, `reset` clear the peer's entries and covered_ev.
2. Drop un-acked entries at the timeout (a step back of up to |dv| * tau).
3. No compensation while stale or past the cap. Simpler, but a knocked parked stand-in would
   not move at all.

### [DECIDE M] Host also applies J to the stand-in, or target only
[DECIDED: recommended option, Daniel 2026-10-05]
The library is physics-free either way; this is wiring docs plus what G17 measures. In the model
both give the same numbers (the spring is stiff, and the target velocity now carries dv, so
neither fights the other).
1. **Recommended: document both, recommend target-only for scripted knocks** (one place to
   change; no double-apply risk). If host physics already moved the stand-in (a contact the game
   turns into an event), the game must NOT apply J again; compensation keeps the spring from
   pulling it back.
2. Recommend applying J directly to the stand-in too. Marginal gain at default settle_ms, larger
   with a soft spring; easy to double-apply by mistake.

### [DECIDE N] Kill switch
[DECIDED: recommended option, Daniel 2026-10-05]
1. **Recommended: `var impulse_compensation: bool = true`.** Needed so G17 can measure
   before/after in one build, and games can turn it off. With false, target_for is exactly
   step 1's (G17 pins this byte for byte).
2. No switch; G17 measures "before" with tau = 0 or by not pushing. Less honest.

### [DECIDE O] Gate shape
[DECIDED: recommended option, Daniel 2026-10-05]
1. **Recommended: new `netcode/fixtures/run_impulse_compensation.gd` (G17) with its own
   copy of a trimmed S1 harness** (host + 2 owners, real CouchSessions, seeded 0a links),
   the same as G13/G15/G16 each carry their own. G16 changes only at push_impulse call sites.
   The copied harness duplicates ~500 lines; extracting a shared fixture is a follow-up
   (known-issues).
2. Extract the S1 harness into a shared fixture now and refactor G16 onto it. Less code,
   but the PR now changes a gate it is supposed to be checked against.
3. Extend G16. One giant file; G16's count stops being step 1's.

## API contract (frozen 2026-10-05)

Where this section and the prose above differ, THIS section wins.

CouchOwnerTargets only (plus G16 call sites). Same rules as step 1: typed, tabs, `##` docs,
4.4-4.7, no Nodes / physics server / Time / webrtc / lobby.

```
var impulse_compensation: bool = true
var impulse_tau_ms: int = 120           # clamped to >= 1 when read
var impulse_timeout_ms: int = 1000
func push_impulse(ring, peer_id: String, impulse: Vector2, angular: float, host_tick: int, now_ms: int) -> int
func covered_ev(peer_id: String) -> int                 # 0 if not an owner
func pending_impulse_count(peer_id: String) -> int      # entries not yet pruned
func impulse_timeout_count(peer_id: String) -> int
func compensation_of(peer_id: String, now_ms: int) -> Dictionary
    # {"pos": Vector2, "vel": Vector2, "rot": float, "w": float}; zeros when none / not an owner
```
- `push_impulse`: as step 1, plus on success (id >= 1) record {id, dv = J / mass,
  dw = aj / inertia or 0.0, t0 = now_ms, covered: false}; also prunes / times out the peer's
  entries at now_ms. Recorded even when compensation is off
  (switching on later applies to entries still live).
- `note_input`: step 2 also rejects `"ev"` present and (not int or < 0) as `"bad-shape"`. On
  accept: first prune / time out at now_ms, then `ev = int(body.get("ev", 0))`; if
  `ev > covered_ev`: covered_ev = ev and every uncovered entry with id <= ev freezes
  lead = P(now - t0) (and its angular lead), tc = now_ms.
- Prune / timeout (inside push_impulse and note_input only): an uncovered entry with
  now - t0 > timeout is handed off as if covered at tc = t0 + timeout (lead = P(timeout)) and
  counted once; a covered entry with now - tc > 8 * tau is dropped. A silent peer's entries
  linger until forget (same as its report).
- `compensation_of(peer, now)` is PURE: sums, per entry, P(now - t0) / P'(now - t0) while
  uncovered (an uncovered entry already past the timeout is evaluated as handed off at
  t0 + timeout, so the value does not depend on when the last prune ran), else
  lead * exp(-(now - tc) / tau) / -lead / tau * exp(...). P(s) = 0 for s < 0.
- `target_for`: step 1 result; if empty -> empty. Else if impulse_compensation: add pos to x/y,
  vel to vx/vy, and with rotation add rot (then wrapf) and w. Same in extrapolating, held and
  HOLD-stale states.
- `set_owner` (replace), `forget`, `reset`: clear entries and covered_ev for the peer(s).

Exact definitions (no choice left to the implementer):
- tau = max(impulse_tau_ms, 1) / 1000.0 seconds, read at each call. Times are ms ints; s in
  seconds = (now - t) / 1000.0. P(s) = dv * tau * (1 - exp(-s / tau)), P'(s) = dv * exp(-s / tau)
  for s >= 0; both 0 for s < 0. dv is a Vector2 (J / mass of the owner at push time); the
  angular entry uses the scalar dw the same way and gives "rot" / "w".
- Handed-off entry at time now: pos = lead * e, vel = -lead / tau * e, with
  e = exp(-(now - tc) / 1000.0 / tau) (same for the angular lead).
- Timeout hand-off: tc = t0 + impulse_timeout_ms, lead = P(impulse_timeout_ms / 1000.0).
  "now - t0 > impulse_timeout_ms" is strict. impulse_timeout_count += 1 exactly when an entry is
  handed off by timeout during a prune (never in compensation_of, never twice).
- Prune order inside note_input: rejections first (a rejected input changes nothing, as in step
  1, so no prune); on accept: prune at now_ms, then cover. Inside push_impulse: prune at now_ms
  before recording the new entry; nothing is recorded or pruned when it returns -1.
- Drop rule: covered entry with now - tc > 8 * tau * 1000 (strict) is removed.
- pending_impulse_count = entries currently stored (uncovered + handed-off, not yet dropped).
- compensation_of for a non-owner, or an owner with no entries: {"pos": Vector2.ZERO,
  "vel": Vector2.ZERO, "rot": 0.0, "w": 0.0}. It does not look at impulse_compensation (it
  reports what would be added); target_for does.
- target_for adds "rot" / "w" only when the kind has rotation channels; position wrap is not
  applied (only rot is wrapped).
- The class `##` CONTRACT and GAME WIRING docs are updated: note_input now reads "ev" (and
  why not ring.ack), push_impulse takes now_ms, the hand-off in two sentences, the kill switch,
  and [DECIDE M]'s wiring rule (target-only for scripted knocks; never apply J again when host
  physics already moved the stand-in).
- Amendments 2026-10-05 after the gate writer's report (orchestrator rulings, minor):
  - impulse_timeout_count lives with the step-1 counters: persists across set_owner, cleared by
    forget / reset.
  - A handed-off entry uses max(now - tc, 0) (a call with now < tc gives the frozen lead).
  - "ev" present means the key exists: null, bool, float, Array, etc. are all "bad-shape".
  - G16 T1 `_t1_accept` sent "ev": "ignored garbage" to pin step 1's "ev is ignored"; decision J
    reverses that rule, so that one body now sends "ev": 0 (check count unchanged; G17 U2 pins
    the new rule). This is the only G16 edit besides the call sites.
  - [DECIDE M] wiring note: at the default clamped spring (2*omega*dt = 1) the follower sets the
    stand-in's velocity to the target velocity every step, so a direct velocity kick applied
    before the follower step is erased; direct apply only shows if done after it. Another reason
    target-only is the recommended wiring.
- G16: only its push_impulse call sites gain the now_ms argument (the sim's T). G16 runs with
  compensation ON (the default) and must still pass all 375 checks unchanged; if one fails,
  that is a finding to report, not a check to edit.


## Gate G17 case list (draft)

Headless, deterministic, seeded, virtual time; final line `G17 impulse compensation: N/N checks
passed`; red run against inert stubs on 4.7 and 4.4 before the implementation exists.

- U1 offset maths: exact values of compensation_of at chosen times (pre-cover, at cover,
  after cover, after timeout) against the closed form; velocity = derivative; inertia 0 -> no
  angular; tau clamp; prune at 8 tau and not before.
- U2 cover bookkeeping: ev missing -> 0; ev float / negative -> "bad-shape", nothing stored;
  ev covers every impulse <= ev; lower ev on a newer tick does not un-cover; ev above every
  impulse covers all; game events interleaved in the ring (impulse id 3 after game ids 1, 2:
  ev 2 covers nothing).
- U3 alignment edges: ring acked by a malformed input / a stale-tick input -> covered_ev and
  the hand-off unchanged; reordered reports (newer accepted first, older rejected) -> no
  un-cover; lost covering report -> the next accepted report hands off at its arrival.
- U4 lifecycle: timeout hand-off + counter (once); set_owner replace / forget / reset clear;
  HOLD-stale and past-the-cap still compensated; REPORT_ONLY-stale empty; no report yet empty;
  impulse_compensation = false -> target_for byte-equal to step 1 on the same inputs.
- Harness: the toy owner applies the impulse as v += J / mass (G16's applies J unscaled, which
  is only right for p2, mass 1; slot 1 has mass 2.0). Otherwise M1/M2 measure a mismatch the
  harness made.
- M1 measurement (the review focus): host + 2 owners as real CouchSessions over seeded 0a links
  at RTT 50 / 150 / 250 (jitter 30, loss 2-3%), one knock. Each scenario runs twice with the
  same seeds, with and without the knock; the stand-in's knock displacement is the difference
  of the two runs projected on J, so the owner's path cancels out (the gate first checks the
  runs agree before T0). Report retreat, overshoot and lag50, compensation off vs on, target-only
  vs direct-apply. Assert: on -> retreat and overshoot <= a small bound at every RTT and lag50
  within a tick or two of the owner's own; off -> lag50 grows with RTT (proves the measurement
  sees the problem). Bounds fixed from the reference run, not guessed.
- M2 model mismatch: owner tau 167 vs impulse_tau_ms 60 / 167 / 500, and a wall case (owner's
  velocity zeroed one tick after applying): overshoot stays inside |dv| * tau * (1 - exp(-RTT /
  tau)) and the stand-in re-converges to the owner's true path.
- M3 the knocked owner still applies the impulse exactly once; G16's alignment check still
  holds with compensation on.

## Build discipline (unchanged from step 1)

Gate-first writer (G17 + inert stubs, red run on 4.7 and 4.4) -> separate implementer from the
frozen contract, gate md5 recorded -> review against the contract (timing / ordering edges
first) -> mutation pass modelled on `owner-authority-mutations.py` with SCRIPT ERROR as red ->
survivors get gate cases, red first -> full matrix (`matrix.sh` + G17) -> long-form commit, no
trailers -> ask Daniel before push / PR.
