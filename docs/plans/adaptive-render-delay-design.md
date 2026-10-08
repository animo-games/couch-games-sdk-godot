# Adaptive render delay: an arrival-measured jitter buffer

Repo: /home/daniel/Repositories/couch-games-sdk-godot, branch `feat/adaptive-render-delay` from
main eafd993. Roadmap: `docs/plans/realtime-netcode-roadmap.md` (the render delay left as later
work in `replicated-world-0d-design.md`). Demo consumer: couch-netcode-demo, its own PR after
this one merges.
STATUS: BUILT, PR pending. D1-D6 decided by Daniel 2026-10-08.

## Decisions

| # | Decision | Why |
|---|---|---|
| D1 | `render_delay_adaptive` defaults to ON | A fixed 6 ticks extrapolates on ~100% of frames above ~50 ms one-way; every gate passes either way. |
| D2 | The floor stays `render_delay_ticks = 6` | The floor never binds at 40 or 117 ms; 3 cost late snapshots at join and makes adaptive-off games extrapolate ~65%. |
| D3 | The demo gates the cost relative to RTT, not "<= 6 ticks at 40/15" | The data refutes 6 ticks at 40/15 (lobby 8.2-8.3); mean <= RTT/2 + one snapshot interval + 4 ticks holds everywhere. Demo-side. |
| D4 | Add `history_ticks = 34` next to `history_size` | Additive: no API break, and independent of the snapshot interval. |
| D5 | Decay over the last two quiet windows, in one step | One tick per 2 s left a 300 ms hitch on screen for 25 s; one step after two quiet windows still covers a spike that recurs within a window. |
| D6 | Grow slew 500 permille | Half-speed playback while growing; never freezes. Untested for feel at runtime: try it with the demo's F3 slider. |

## The problem

`CouchNetClock.render_tick_milli` rendered at a fixed `render_delay_ticks` (6, 100 ms) behind
the host-time estimate. Interpolation needs a snapshot at or after the render time. When the
newest snapshot is older, `CouchReplicatedWorld` extrapolates. At 117 ms one-way plus 15 ms
jitter, the newest snapshot is ~10-12 ticks old just before the next one lands, so with 6 ticks
every guest extrapolated on ~100% of frames. A pushed crate was drawn 333-353 px into a wall,
and puppets jumped 21-22 px a frame when fresh data snapped them back.

## The rule

**What is measured.** On every accepted snapshot (the normal path of `on_snapshot`, never a
resync), `lag = estimate - previous host_tick * 1000`, in milliticks. That is how stale the
newest snapshot had become just before this one arrived. One number covers one-way delay, the
snapshot interval, jitter, a lost snapshot and frame phase, with no model of any of them.

- The first lag after any sync (first sync or hard resync) is skipped: at first sync the RTT is
  still the 100 ms default, so the estimate has not settled.
- `late_snapshots` counts arrivals whose lag exceeded the delay in use, in both modes. Each is a
  stretch of extrapolated frames. The demo compares fixed against adaptive with it.
- A repeat of the same host tick would be measured again, but `CouchReplicatedWorld.ingest`
  rejects `ht <= newest_tick()` before the clock sees it.

**The target.** `need = clamp(lag + render_margin_ticks, render_delay_ticks, render_delay_max_ticks)`
(all in milliticks).

- **Grow at once:** a need above `render_target_milli` becomes the target immediately.
- **Shrink after two quiet windows (D5):** windows close on the first non-growing arrival at
  least `render_shrink_interval_ms` (2000) after the previous close. At each close the target
  becomes `max(previous window's peak, this window's peak) + render_shrink_hysteresis_ticks`,
  if that is below it. Then the next window starts with the closing arrival's need as its peak.
- After a sync, the "previous window" is seeded with the current target, so the first window
  after a sync cannot shrink the target on its own.
- No `maxi(floor, ...)` on the shrink: every need is already at least the floor.
- Hard resync: the delay in use snaps to the target. The timeline jumps anyway, and the
  monotone clamp holds render time until it catches up.

**Fixed mode** (`render_delay_adaptive = false`): `render_tick_milli` re-pins target and delay to
`render_delay_ticks * 1000` on every call, so the floor slider stays a live lever.

| Policy field | Default | Meaning |
|---|---|---|
| `render_delay_adaptive` | true | D1 |
| `render_delay_ticks` | 6 | The floor; the delay itself in fixed mode (D2) |
| `render_delay_max_ticks` | 30 | Cap; `history_ticks` must stay above it |
| `render_margin_ticks` | 1 | Added to the lag so a slightly later snapshot still lands |
| `render_shrink_interval_ms` | 2000 | Window length |
| `render_shrink_hysteresis_ticks` | 1 | Settles one tick above the two windows' peak need |
| `render_slew_grow_permille` | 500 | D6 |
| `render_slew_shrink_permille` | 50 | 5% fast while shrinking |

## The slew

The delay in use, `render_delay_milli`, moves toward the target inside `render_tick_milli`, by a
share of the estimate's advance since the previous call (`step`):

- growing: `+ step * 500 / 1000`, so render time plays at half speed. 6 ticks of growth take
  ~200 ms (R3 measures 210);
- shrinking: `- step * 50 / 1000`, so render time plays 5% fast. 12 ticks of shrink take ~4 s.

Moving things briefly slow down or speed up but never freeze or jump. It only applies when
`step > 0` and the previous estimate belongs to the same sync. At 60 fps `step` is ~1000, so
integer truncation is harmless.

## World history (D4)

`CouchReplicatedWorld` used to keep `history_size = 8` samples per entity life. At 2-tick
snapshots that is 16 ticks, which a delay capped at 30 overruns: render time falls before the
oldest sample and every entity holds frozen.

- `history_size` now means "always keep at least this many".
- New `history_ticks = 34`: samples are also kept while needed to bracket
  `newest_tick() - history_ticks`. 34 = the cap of 30 plus two 2-tick intervals.
- Prune rule: drop the oldest while `size > history_size and ticks[1] <= ht - history_ticks`.

## Gates

G14 (`run_net_clock.gd`) cases R1-R6 drive one clock by hand through `_Feed`. It syncs at host
tick 100 at 1000 ms, then delivers a snapshot 3 ticks later every 50 ms and renders every 10 ms.
Each on-time lag is exactly 6000. R7 runs the network `_Sim`.

| Case | Proves |
|---|---|
| R1 | Fixed mode: lag 6000 is not late, a 100 ms hold (12000) is; target stays 6000; every frame at `est - 6000`. C3 also pins fixed mode. |
| R2 | Floor 3: first lag skipped, second sets 7000; a 100 ms hold sets 13000 at once, counts as late, and the delay in use does not jump. |
| R3 | Per-frame slew bounds both ways; 7000 -> 13000 in 180-300 ms (210); render never freezes. |
| R4 | Two-window decay: grown at 4150, windows close at 5000/7000/9000, and the only drop is at 9000, by 4970 to 8030 (on-time need 7030 + 1 tick). The 30 is the offset EWMA's steady truncation error after the hold. One-window decay would drop at 7000. |
| R5 | Cap 9 holds a 13000 need at 9000 with no resync; floor 9 is never undercut in 10 s. |
| R6 | A backwards resync mid-slew (7591 of 13000) snaps to 13000 and render holds; the first lag after it is skipped, the next is measured. |
| R7 | 50 +/- 30 ms links: fixed 3 ticks draws past the newest snapshot on 677/1056 frames; adaptive on 0/1056, settling at 8095. |

G15 (`run_replicated_world.gd`):

| Case | Proves |
|---|---|
| W4b (changed) | `history_size 3` + `history_ticks 0` keeps 4..6; defaults keep 26..60 of 1..60; 10-tick snapshots still keep 8. |
| W4c (new) | `history_ticks >= render_delay_max_ticks + 2`; at 1, 2 and 3-tick snapshots, render at `newest - 30.5` interpolates exactly. |
| S1d (new) | The S1 network adaptive from floor 3: held 0, extrapolated 0/684-688, mover error 0.0000, delay 8604-9373. |

Results on this branch (Godot 4.7; G14 and G15 also on 4.4):

| Gate | main | branch |
|---|---|---|
| G14 net clock | 112/112 | 135/135 |
| G15 replicated world | 223/223 | 237/237 |
| G16 owner authority | 375/375 | 375/375 |
| G17 impulse compensation | 197/197 | 197/197 |

## Mutants

`docs/plans/render-delay-mutations.py <scratch project>` applies each mutant to a plain copy of
the addon inside a scratch Godot project. It refuses a symlinked addon or one with a `.git`
entry, restores every file in `finally`, and counts a mutant as KILLED only when a `FAIL:` line of
the named case appears. 18 mutants, 18 killed, no survivors:

| Mutant | Change | Killed by |
|---|---|---|
| r01 / r02 | drop the grow / shrink slew | R3 |
| r03 | grow on every arrival (no peak hold) | R4 |
| r04 | no margin | R2 |
| r05 / r08 | no cap / no floor | R5 |
| r06 | shrink without waiting for the interval | R4 |
| r07 | no hysteresis | R4 |
| r09 / r10 | no snap / no skipped lag on resync | R6 |
| r11 | fixed mode adapts | R1 |
| r12 / r13 | late counts ties / never counts | R1 |
| r14 | render from the target, not the delay in use | R3 |
| r15 | never adapts | R2 |
| r16 | judge one window, not the last two (D5) | R4 |
| w01 / w02 | count-only / window-only history | W4c / W4b |

Not pinned by any case (both survive as mutants, which is acceptable for behaviour this small):
starting the next window's peak at 0 instead of the closing arrival's need, and seeding the
previous window with 0 instead of the target after a sync.

Do not run `matrix.sh` or `net-clock-mutations.py` for this work: both mutate the real repo.

## Evidence (planner's demo smoke, 2026-10-08)

Runs from a scratch demo copy with the prototype clock, guest1 + guest2 per run. "plan" is
adaptive, floor 6, margin 1. These runs used one-tick-per-interval decay; D5 changed that
afterwards, and the demo PR reruns the smoke on the built version. In steady runs the one-step
variant made no measurable difference (same late counts, same mean delay).

| config | late / guest | delay mean, ticks | past newest | crate in wall, px (host) | jump max, px |
|---|---|---|---|---|---|
| star 40/15 fixed 6 | 0 | 6.0 | 0.00% | 4.97 | 1.44 |
| star 40/15 plan | 0 | 6.2-6.6 | 0.00% | 4.84 (7.31) | 2.12 |
| lobby 40/15 fixed 6 | 11-14 | 6.0 | 0.94% | 9.52 | 2.35 |
| lobby 40/15 plan | 0-1 | 8.2-8.3 | 0.04% | 9.41 (9.65) | 1.49 |
| star 117/15 fixed 6 | 550-555 | 6.0 | ~100% | 333 | 21.4 |
| star 117/15 plan | 0 | 11.1-11.5 | 0.00% | 6.77 (10.79) | 1.69 |
| lobby 117/15 fixed 6 | 564-569 | 6.0 | ~100% | 353 | 22.4 |
| lobby 117/15 plan | 2-3 | 12.7-12.9 | 0.08% | 7.28 (8.08) | 1.42 |

The cost, against fixed 6 ticks (100 ms):

- 40/15: star +3-10 ms, lobby +37 ms.
- 117/15: star +85-92 ms, lobby +112-115 ms.

What it buys at 117/15:

- frames drawn past the newest snapshot go from ~100% to 0-0.08%;
- late snapshots go from ~555 per 20 s to 0-3;
- puppet jumps go from 22 px to under 2 px;
- the crate is never drawn deeper into a wall than the host's own crate.

Margin 0 got the star to 6.0 ticks (floor-bound) but gave the lobby 6-8 late snapshots, so the
margin stays at 1.

**Stall experiment** (the clock alone). A one-off host hitch of 100/200/300/600 ms raises the
target to 13/19/25/30 ticks. Under the old one-tick decay it took 10/22/>26/>26 s to come back
to 8 ticks. Under D5 the target drops in one step 4-6 s after the hitch (two quiet windows),
then the delay slews down at 5% fast (12 ticks in ~4 s). A network hold longer than ~133 ms
trips the existing error-over-threshold resync instead, which skips the lag, so it inflates
nothing.

## Known issues (outside this change)

- Host physics sinks a pushed crate 7-11 px into a wall by itself. That is why the demo's wall
  gate compares a guest's puppet against the host's own crate (+1 px), not an absolute 1 px.
- The owner's own predicted crate copy (a physics body) sinks up to 10 px. The demo reports it
  but does not gate it.
- The R4 settle point carries the clock's 30-millitick EWMA truncation error. It is harmless
  here, but it is a reminder that `_smoothed_err` never decays fully to zero.
