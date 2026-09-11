# Shared game assets review checkpoint

Status: post-rebase local implementation, source review, and verification complete. The rebased branches are pushed and PRs are open: [platform #249](https://github.com/animo-games/platform-dev/pull/249) and [SDK #16](https://github.com/animo-games/couch-games-sdk-godot/pull/16). Nothing has been deployed.

Platform feature checkpoint: `f819ecd`, rebased onto GitHub master `48221c5`, is in the prepared clone `/tmp/couch-shared-platform` on branch `feat/shared-game-assets`. The permanent checkout `/home/daniel/Repositories/platform-dev-shared-game-assets` still holds the pre-rebase source checkpoint `326d232` until remote synchronization. SDK implementation checkpoint: `8a09449`, rebased onto origin/main `6069bdc`; documentation commits follow. The original dirty platform checkout was preserved.

## Goal alignment

Root Astra reviewed the approved plan and executable handoff directly. The implementation provides independent uploads, immutable content-hashed objects, a fresh manifest snapshot per launch, explicit platform roots, Godot byte/pack helpers, local mocks, portal/CLI management, and documentation. The acceptance fixture exercises two builds and a standalone experience without requiring an existing consuming game.

The review corrected first-write recovery, delayed-operation fencing, stage inheritance, once-decoded serving paths, retained-object migration, cursorless migration recovery, and repeated migration identities. The scope still includes a later deployed consuming-game acceptance demonstration.

## Review verdicts

- Claude Opus 5 reviewed runtime, launch wiring, portal, CLI, and Godot implementation through two iterations. Its second verdict was: “No remaining actionable in-scope findings.”
- Opus's first storage review identified recovery and existing-migration gaps, subsequently fixed. Its second storage review ended on a session quota before producing a verdict.
- The user selected Astra for final storage review. Astra found and verified fixes for concurrent rejected-migration helpers and competing destination reservations. Seven migration tests and the full API suite pass.
- Astra completed the final source review: **No remaining actionable in-scope findings.** The approved shared-byte retention correction, fixed deletion attempt/terminal, stale tombstone handling, retained-fence migration gates, and fresh-game namespace reservation are implemented. The latest deletion/migration tests pass (11 tests), and post-rebase verification against platform feature commit `f819ecd` is complete.

## Approved deletion-policy correction

The user approved retaining shared bytes and allowing slug reuse. The correction uses a fixed manifest fence and durable terminal evidence and defers physical reclamation of shared objects to future garbage collection. Existing legacy cleanup remains separate from the shared namespace. This explicitly supersedes the original whole-game physical-cleanup expectation for shared bytes.

Implementation and delayed-helper regressions are complete. Shared serving distinguishes a current authoritative catalog after reuse from a delayed legacy tombstone. Physical cleanup excludes the shared namespace and still removes ordinary build files.

The existing legacy cleanup/tombstone mechanism also has concurrency limitations; shared changes must not claim that a lookup alone makes its unconditional deletion safe.

## Verified locally

- Post-rebase platform API run against `f819ecd`: **73 files total, 72 pass / 1 fail; 1,244 tests pass / 1 fail**. The sole failure is the unrelated exact-object expectation in `player-lobby-retirement.test.ts`, which omits upstream-added `createdAt` and fails identically on pristine GitHub master `48221c5`. All shared-assets API tests, including real workerd/R2 multipart/hash checks, pass.
- Post-rebase root `bun run test:run` remains non-green independently of that API failure because of the known web test-environment class: web reports **10 failed / 92 passed files** and **59 failed / 817 passed tests**, including duplicate-React invalid-child/hooks failures and unresolved `cloudflare:workers`.
- Runtime full suite: **5 files, 225 tests pass**. Developer portal: **90 tests pass**. Shared web characterization and launch mapping: **26 tests pass**. Config and CLI: **13 tests pass**.
- Post-rebase `bun run build` passed **5/5 tasks**.
- Post-rebase `bun run check-types` still fails only with the same three baseline React-version errors in `friends-drawer.tsx:807` and `ui/tooltip.tsx:30,38`.
- Native Godot fixture, real Web export, and no-parent Web compatibility all pass.
- Full actual Godot Web + platform runtime + local workerd/R2 acceptance passes on fresh state: two build depths, standalone depth, exact binary/empty/pack reads, replacement with old snapshot retention, identical-content URL reuse, and logical deletion.

Local workerd is from installed Wrangler 4.60.0 and uses its maximum supported compatibility date, 2026-01-20. These results are local evidence, not live deployment verification.

## Rollout still open

No consuming game or deployment stage has been selected. The available Cloudflare token authenticates but lacks Rulesets Read, so live cache rules could not be inspected. Verify manifest cache exclusions and full hashed-path cache keys before uploading shared assets to a live stage, then perform the deployed two-build/standalone demonstration.

## Resume without repeating the investigation

1. No additional design/review iteration is queued. Source review and post-rebase verification against `f819ecd` are complete; the type-check result remains limited to the documented baseline errors, and the sole API failure reproduces on pristine upstream master.
2. Complete cache-rule verification and choose a deployment stage before live rollout. The real deployed consuming-game demonstration remains open.

The permanent platform checkout contains source only; the existing prepared dependency installation, generated ignored local worker config, and detailed logs remain in `/tmp/couch-shared-platform` and `/tmp/couch-shared-*.log` for a quick continuation.
