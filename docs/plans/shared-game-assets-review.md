# Shared game assets review checkpoint

Status: implementation and local integration complete; final storage sign-off awaits implementation and verification of the approved deletion correction below. Nothing has been pushed or deployed.

## Goal alignment

Root Astra reviewed the approved plan and executable handoff directly. The implementation provides independent uploads, immutable content-hashed objects, a fresh manifest snapshot per launch, explicit platform roots, Godot byte/pack helpers, local mocks, portal/CLI management, and documentation. The acceptance fixture exercises two builds and a standalone experience without requiring an existing consuming game.

The review corrected first-write recovery, delayed-operation fencing, stage inheritance, once-decoded serving paths, retained-object migration, cursorless migration recovery, and repeated migration identities. The scope still includes a later deployed consuming-game acceptance demonstration.

## Review verdicts

- Claude Opus 5 reviewed runtime, launch wiring, portal, CLI, and Godot implementation through two iterations. Its second verdict was: “No remaining actionable in-scope findings.”
- Opus's first storage review identified recovery and existing-migration gaps, subsequently fixed. Its second storage review ended on a session quota before producing a verdict.
- The user selected Astra for final storage review. Astra found and verified fixes for concurrent rejected-migration helpers and competing destination reservations. Seven migration tests and the full API suite pass.
- Astra has **not signed off whole-game deletion**. Concurrent deletion helpers can issue an old unconditional prefix delete after another helper completes and the slug is reused. A reread of ownership cannot fence an already delayed request. The deletion-manifest writer also needs one persisted fixed-base candidate instead of rebasing.

## Approved deletion-policy correction

The user approved retaining shared bytes and allowing slug reuse. The correction uses a fixed manifest fence and durable terminal evidence and defers physical reclamation of shared objects to future garbage collection. Existing legacy cleanup remains separate from the shared namespace. This explicitly supersedes the original whole-game physical-cleanup expectation for shared bytes.

Implementation and delayed-helper regression coverage are in progress. Shared serving must also distinguish a current catalog after reuse from a delayed legacy tombstone.

The existing legacy cleanup/tombstone mechanism also has concurrency limitations; shared changes must not claim that a lookup alone makes its unconditional deletion safe.

## Verified locally

- API: **68 files, 1,162 tests pass**, including recovery, migration races, serving, and real workerd/R2 multipart/hash checks.
- Developer portal: **90 tests pass**. Shared web characterization and launch mapping: **26 tests pass**.
- Full platform build: **5/5 tasks pass**.
- Type checking: only the three unchanged React-version errors in `friends-drawer.tsx:799` and `ui/tooltip.tsx:30,38` remain.
- Native Godot fixture, real Web export, and no-parent Web compatibility pass.
- Actual Godot Web + platform runtime + local workerd/R2 acceptance passes on fresh state: two build depths, standalone depth, exact binary/empty/pack reads, replacement with old snapshot retention, identical-content URL reuse, and logical deletion.
- The full workspace test command is not green because of existing web React-version test-environment errors and a missing `VITE_SERVER_URL`. Representative failures reproduce from baseline `ed2aefd` with the same installed dependencies. The additive API-shape assertion was updated and its focused suite passes.

Local workerd is from installed Wrangler 4.60.0 and uses its maximum supported compatibility date, 2026-01-20. These results are local evidence, not live deployment verification.

## Rollout still open

No consuming game or deployment stage has been selected. The available Cloudflare token authenticates but lacks Rulesets Read, so live cache rules could not be inspected. Verify manifest cache exclusions and full hashed-path cache keys before uploading shared assets to a live stage, then perform the deployed two-build/standalone demonstration.
