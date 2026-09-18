# Shared game assets implementation plan

Status: local implementation and source review complete on `feat/shared-game-assets`; final full verification rerun and deployed acceptance remain open. See the [review checkpoint](shared-game-assets-review.md) and [executable handoff](shared-game-assets-handoff.md).

## Goal and scope

Let a game upload assets independently of its builds and fetch them on demand from any of its versions or experiences. Use the existing R2 bucket, with a shared prefix under each game. Public downloads remain public; uploading, replacing, listing for management, and deleting use the developer portal's existing authentication and game ownership checks.

This spans `platform-dev` and `couch-games-sdk-godot`. The first release includes a developer upload workflow, the platform-to-SDK contract, Godot download/pack helpers, local mock support, and documentation. Existing build uploads and experience delivery retain their behavior. No migration of existing assets is required.

## Storage and update contract

```text
games/<slug>/
  shared/
    manifest.json
    objects/
      audio/theme.<sha256>.ogg
      config/rules.<sha256>.json
      packs/common.<sha256>.pck
  v73-abcd1234/
    index.html
    index.pck
  experiences/<experience-id>/
    level.pck
```

- Game code uses logical paths such as `audio/theme.ogg`. The manifest maps each logical path to a content-hashed object path relative to the shared root.
- Use the full SHA-256 digest of the original file bytes, inserted before the last filename extension; append it for extensionless files. Identical bytes at the same logical path produce the same URL. Do not use an upload timestamp, random suffix, or R2 multipart ETag as the content hash.
- The manifest lives at `games/<slug>/shared/manifest.json` in the existing R2 bucket and is served at `/api/assets/games/<slug>/shared/manifest.json`. Published files use `/api/assets/games/<slug>/shared/objects/<encoded-hashed-path>` on the serving platform origin.
- Uploading a shared file does not create a version, change the active build, or attach anything to an experience. Upload files as their original bytes; a `.pck` or `.zip` remains an object rather than being extracted.
- Replacing a logical path writes a new immutable object, then updates the manifest to reference it. Never change bytes at an existing hashed URL. Publication is atomic per manifest update, not across an entire directory upload; multi-file uploads report outcomes per file.
- Replacements must remain compatible with builds still in use. For incompatible changes, publish a new filename or subdirectory, such as `packs/common-v2.pck`, and retain the old one as needed.
- Fetch a fresh manifest once per game launch and keep that snapshot for the launch. Updates become visible on a new launch/reload, not midway through play. Keep previous hashed objects readable for sessions holding older manifests. Mounted Godot packs remain mounted for the process.
- Deleting through the management API removes the logical entry from the manifest. It does not immediately delete or tombstone its hashed objects. The first release retains published objects, including superseded versions; storage reclamation is a separate future policy.

Manifest format (hashes abbreviated here only):

```json
{
  "schemaVersion": 1,
  "revision": "manifest-publication-id",
  "files": {
    "audio/theme.ogg": {
      "revision": "file-publication-id",
      "objectPath": "objects/audio/theme.a81f92....ogg",
      "sha256": "a81f92...",
      "size": 123456,
      "contentType": "audio/ogg"
    }
  }
}
```

The platform generates the manifest; developers upload logical files, not manifest documents. Store it as one JSON object in R2, with no database required for the catalog. Bound its serialized size to 4 MiB initially, rejecting a publication that would exceed that limit before changing the live manifest. Validate schema, entry paths, and sizes when reading it. Entry revision IDs support conflict detection independently of content hashes.

### Preview stages

Preserve stage-local writes and production fallback reads with explicit manifest semantics:

- If the stage has no manifest, use the production manifest as a whole. Its hashed objects resolve through the existing bucket fallback.
- On the first stage edit, copy the effective manifest into the stage and apply the edit with a conditional create. After that, the stage manifest is authoritative, including missing entries and an intentionally empty file map. Do not merge missing entries back from production on reads.
- Hashed objects may still fall back by exact key, so inherited entries remain readable. A logical deletion stays deleted in the stage; it requires no per-file KV tombstone. Existing whole-game deletion checks continue to apply.
- Further production changes are not automatically merged into a stage once it has its own manifest. Show this behavior in the portal; a stage refresh/rebase operation can be added later.

## 1. Platform storage helpers and serving policy

Primary files: `packages/api/src/assets.ts`, `packages/api/src/asset-tombstones.ts`, a new shared-assets path/helper module, and the callers in `apps/web`, `apps/images`, `apps/dev`, and `apps/admin`.

1. Centralize shared-prefix construction, detection, and relative-path validation. Match exactly `games/<slug>/shared/`, not similarly named directories. Validate decoded logical paths once and encode URL segments once. Reject absolute paths, URLs, backslashes, control characters, empty segments, and `.`/`..` segments. Test spaces, Unicode, literal percent signs, query/hash characters, and encoded traversal attempts.
2. Separate manifest handling from hashed-file handling before the existing edge-cache lookup and range-response early return. For shared data, serve exact object bytes without game HTML injection, image transformations, or implicit `.gz`/`.br` filename substitution. Serve HTML-like objects as downloads rather than treating them as game entry points.
3. The manifest uses `Cache-Control: no-store`, `Content-Type: application/json`, and fresh R2 lookup. Bypass both `caches.default.match()` and `cache.put()` for it, including missing/error responses. Only use production fallback if the stage manifest is absent; an invalid or unreadable stage manifest is an error, not permission to serve a different catalog.
4. Successful hashed-file responses use `Cache-Control: public, max-age=31536000, immutable`. Use the complete hashed path in the cache key and retain ETag and range support. Set this policy explicitly for every asset extension. Missing/error responses remain uncached; do not cache partial bodies under the full-file cache key.
5. Apply both policies through every route serving these keys, including direct images-host requests and portal previews. Override conflicting uploaded metadata and host defaults. Logical un-hashed URLs must not silently resolve to mutable bytes under the immutable policy.
6. Inspect deployed Cloudflare cache rules for the relevant hosts. Exclude the stable manifest URL from forced caching and confirm any custom cache keys retain the hashed path. Verify actual browser/edge behavior, not only response headers or local mocks.

Changed content produces a different cache key, while unchanged files can be reused from browser and edge caches. The small manifest is the only mutable download that must always be fresh. Cloudflare's default cache key includes the URL path; see [Cache keys](https://developers.cloudflare.com/cache/how-to/cache-keys/). Publication requires no asset-cache purge. Local `cache.delete()` would not suffice for global invalidation anyway; see the [Workers Cache API](https://developers.cloudflare.com/workers/runtime-apis/cache/).

Deploy the serving policy before the first shared upload. If the intended manifest URL has already been served with long-lived caching, use a fresh manifest URL for rollout or explicitly resolve that migration first; changing server headers cannot retroactively invalidate a browser's cached response.

## 2. Independent developer upload and management

Primary files: `apps/dev/src/index.tsx`, a new `apps/dev/src/lib/shared-assets.ts`, `apps/dev/src/pages/GameDetailPage.tsx`, and `apps/dev/src/lib/client.js`.

Add routes under `/api/games/:slug/shared-files`:

| Operation | Proposed endpoint | Behavior |
| --- | --- | --- |
| List | `GET /shared-files?cursor=...` | Paginated logical entries from the effective manifest; size, hash, entry revision, hashed public URL, and whether the manifest is inherited. |
| Begin upload | `POST /shared-files/uploads` | Validate logical path, declared size, and expected entry revision; create a staged multipart upload bound to this game. |
| Upload part | `POST /shared-files/uploads/:id/parts/:partNumber` | Accept bounded binary parts. |
| Publish | `POST /shared-files/uploads/:id/complete` | Complete staging, verify/hash bytes, store the immutable object, then conditionally update the manifest. |
| Abort | `POST /shared-files/uploads/:id/abort` | Abort that pending upload. |
| Delete | `DELETE /shared-files?path=...` | Remove the logical entry, conditional on its expected entry revision; retain hashed objects. |

Use the existing `requireAuth` and `getOwnedGameOr404` checks for every operation, including each part and completion. Browser requests use the established session/CSRF handling; CLI requests use the existing developer API key. Construct the bucket key on the server.

Reuse the existing chunk-size and size-validation helpers from `apps/dev/src/lib/chunked-upload.ts`, initially matching the current 200 MiB build-upload ceiling **per shared file**. Extract only reusable helpers; shared uploads must not create `gameVersions` rows or invoke ZIP extraction. Initially reject zero-byte uploads with a clear validation error, while keeping raw download support for valid empty objects.

Store upload records and staged bytes under the denied `staging/shared/` prefix. Record game ID, logical path, expected previous entry revision (or absence), R2 upload ID, expected size, operation ID, and creation time. Recheck ownership on subsequent calls.

Publication sequence:

1. Complete the staged multipart object and verify its byte length. Read it as a stream and calculate SHA-256 incrementally on the server; do not buffer a 200 MiB asset or trust a client-supplied hash. Use the supported incremental hashing facility with the Worker's Node compatibility configuration, and verify it in the deployed runtime. See [Cloudflare Node crypto](https://developers.cloudflare.com/workers/runtime-apis/nodejs/crypto/).
2. Derive the final hashed object key. Stream the staged bytes into that key with correct metadata, using a conditional create so an existing immutable object is never overwritten. If it already exists, verify the stored size/hash metadata and reuse it. Publish no manifest entry before this object is readable.
3. Read the manifest and its R2 ETag, apply the one-entry patch, and write with an ETag precondition; use a create-if-absent condition for the first manifest. R2 supports conditional writes via `onlyIf`; see the [R2 Workers API](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/).
4. If another writer changed the manifest, re-read and retry the patch a bounded number of times. Preserve edits to other logical files. If the same entry's revision changed, return `409 Conflict` instead of silently replacing it. Apply the same rule to deletes and preview-manifest creation.
5. Record the completed operation and return the object path/hash plus manifest revision. Completion retries return the recorded outcome, or reconcile the operation's publication revision after a lost response; they must never reapply an old publication over a newer edit. Listing cursors are tied to a manifest revision and must restart after it changes.
6. Remove completed staging bytes and retain a bounded completion receipt for retries. Expire abandoned uploads/records using the existing retention period. A failure before manifest publication leaves the old entry working; an unreferenced hashed object may remain and is harmless. Ordinary deletion removes only a manifest entry, preserving older snapshots.

Add a “Shared assets” section to the game detail page with upload, logical file list, copy logical path/hashed URL, replace, and delete controls. Support nested relative paths and multi-file selection; uploads do not delete unmentioned files. Show inherited versus stage-owned manifest state. Require an explicit replace action for a duplicate logical path and confirmation for removal; explain that removal affects new launches and retains previously published bytes.

Add `scripts/upload-game-shared-assets.ts` for directory uploads using the same API, preserving relative paths, bounded concurrency, and API-key configuration. Keep it separate from the build uploader. Default to refusing overwrites unless `--overwrite` is supplied; never infer deletion from a missing local file.

## 3. Explicit platform SDK context

Primary files: `packages/sdk-runtime/src/index.ts`, `apps/web/src/hooks/useCouchGamesListener.ts`, `apps/web/src/components/game-player-page.tsx`, and `apps/web/src/routes/dev-preview.$experienceId.tsx` plus its loader.

1. Add a nullable shared-assets root and a launch-scoped manifest loader to the runtime's current game context. Build the root from the known game slug and serving origin. Start one manifest fetch during launch setup, using `fetch(..., { cache: "no-store" })`; the first shared read awaits it. Do not download asset bodies until asked.
2. Extend the JavaScript API additively with synchronous `window.CouchGames.game.getSharedRoot()` and asynchronous `getSharedFileInfo(logicalPath)`, returning the validated absolute hashed URL, SHA-256, and size. Add `getSharedFileURL(logicalPath)` as a thin URL-only wrapper for custom loaders. The Godot backend uses the file info for its own HTTP downloader, preserving progress reporting without a second JavaScript asset download.
3. Cover ordinary, pinned, developer-active, standalone, and native-guest launches. The dev-preview loader currently returns game ID/title but not slug; return the explicit root there and carry it through `customData`.
4. Establish context before iframe execution using the existing pre-start setup or a layout effect. Guard the manifest fetch with the launch generation: discard results from a departed game, and clear the root, snapshot, and pending resolver state on teardown. Reloading the same game creates a fresh generation and fetches a new manifest; ordinary React rerenders do not. Update all current-experience assignment paths so effects cannot restore stale context.
5. Construct the additive `game` namespace as part of the runtime API before its top-level object is frozen. The existing iframe bridge passes the parent's SDK by reference; verify that it exposes the new method. Launches without the parent SDK report the capability as unavailable.
6. Keep a successfully loaded manifest snapshot unchanged for that launch. Treat a missing manifest as an empty catalog for games without shared assets. Malformed data, network failures, and unknown paths produce descriptive errors; do not silently fall back to a previous launch's snapshot. Bound manifest fetching and allow retry after transient failure before a snapshot has been established.
7. Validate that every manifest entry points into the current game's `shared/objects/` namespace and that the filename agrees with its hash. Resolve and encode paths against the explicit root; never accept arbitrary remote URLs. Share one loader/snapshot across concurrent callers, separate from the gameplay authentication/session gate.

The Godot SDK must not calculate `../shared` from a version URL. Standalone experiences use a different directory depth, and the platform already knows the game identity. A root plus a logical filename is no longer a downloadable URL; custom loaders must resolve the filename through the manifest too.

## 4. Godot API and local development

Extend `CouchGames.game` with:

```gdscript
shared_root() -> String
get_shared_file_url(relative_path: String) -> String
get_shared_file(relative_path: String, on_progress: Callable = Callable()) -> PackedByteArray
load_shared_pack(relative_path: String, on_progress: Callable = Callable()) -> bool
is_shared_pack_loaded(relative_path: String) -> bool
```

Example:

```gdscript
await CouchGames.init()
var bytes := await CouchGames.game.get_shared_file("audio/theme.ogg")
if await CouchGames.game.load_shared_pack("packs/common.pck"):
    var room := load("res://shared/rooms/lobby.tscn")
```

Implementation files:

- `backends/backend.gd`: define optional `shared_root()` and asynchronous shared-file resolution capabilities; resolution returns a structured success/error result and file identity.
- `backends/web_backend.gd`: call `window.CouchGames.game.getSharedRoot()` / `getSharedFileInfo()`. An older platform without them should produce a clear unsupported-feature error when a shared read is attempted, without breaking existing calls.
- `backends/mock_backend.gd` and `editor/couch_games_plugin.gd`: add `couch_games/mock/shared_files_dir`, default `res://shared_files`. Local development reads ordinary logical filenames directly, with no author-maintained manifest or hashed copies required. The local relay backend inherits this behavior. Document export exclusions if developers want these files remote-only.
- `game/couch_game_files.gd`: resolve logical names before HTTP requests; reuse path validation, encoding, local/HTTP readers, progress reporting, and idle timeout. `get_shared_file_url()` is asynchronous and returns the manifest-resolved HTTP URL on web, or a local file path in the mock. Preserve `load_pack()` as build-relative.
- `core/pack_installer.gd`: reuse the existing installer. Stage web shared packs under `user://couch_shared/<root-identity>/<content-hash>/<relative-path>`. The mock can compute an identity from the local pack bytes. This prevents equal filenames in different scopes, games, or content revisions from aliasing the mounted-pack record.

Key in-flight downloads by resolved immutable URL/file identity. Concurrent requests for one shared file should use one transfer; clear in-flight state on success, failure, or timeout so retries work. Keep the current convention that only the initiating request receives progress callbacks. Repeated reads resolve through the same launch manifest and can reuse browser-cached bytes. The SDK needs no permanent asset byte cache; mounted packs remain idempotent for the process. `is_shared_pack_loaded()` uses identities already resolved in this launch and returns false before resolution.

Support arbitrary binary data, including a valid empty file for raw reads; pack loading must reject empty or invalid pack bytes. Preserve descriptive HTTP, local-file, timeout, and mount errors. Mount-directory separation does not isolate `res://` paths inside packs: document distinct resource paths and deliberate override order.

Text/JSON wrappers and runtime file enumeration can be added later; the first release provides bytes, pack loading, and resolved URLs for custom requests.

## 5. Lifecycle checks and verification

Keep shared data outside version cleanup. Verify the build garbage collector cannot delete `shared/` and that whole-game slug migration includes the manifest and retained objects. Manifest object paths are relative, so moving the whole prefix requires no entry rewrite. Whole-game deletion hides shared assets with a retained manifest fence and deletion marker. Per the user-approved review correction, it retains shared object bytes for future garbage collection, allowing safe slug reuse; physical legacy cleanup excludes the shared namespace. During a slug migration, coordinate shared writes with the existing migration workflow; do not promise a consistent copy while allowing uncoordinated replacements.

The first release does not garbage-collect published hashed objects. That preserves references held by active sessions and avoids confusing a manifest entry removal with byte revocation. Only abandoned staging data is automatically reclaimed. Future GC needs an explicit retention policy for older snapshots.

Add targeted tests for:

- Upload ownership, path confinement, nested/extensionless names, multipart failure/abort, bounded streaming hash calculation, completion retry, and listing revision changes.
- Identical content keeping its URL; changed content receiving a new URL; immutable objects never being overwritten. Manifest references appear only after their objects exist.
- Concurrent publications to different paths both surviving; same-path conflicts, first-manifest creation races, and retries after publication or response failure preserving newer edits.
- Public reads without a session; exact bytes for JSON, PNG, PCK, HTML, and empty files; missing files and valid/invalid range requests.
- Manifest cache bypass on web, images, and preview routes, including a pre-existing stale edge-cache entry. Hashed bodies remain cacheable across all extensions; partial responses cannot poison full responses. Verify deployed rules allow fresh manifests and cached bodies.
- Stage manifest fallback, first-edit snapshot, intentionally empty catalogs, retained inherited object reads, and deletion not resurrecting production entries.
- One manifest fetch per launch, fresh fetch on same-game reload, concurrent lookup sharing, startup error/retry, malformed manifest rejection, and old responses discarded on navigation.
- SDK initialization, game switching, pinned/standalone/dev-preview/native-guest roots, and compatibility with older platform or game SDK versions.
- Godot local and HTTP reads, byte/progress/error behavior, concurrent callers, retry after failure, and identical pack names in different scopes.
- Version cleanup leaving shared files intact and slug migration preserving their paths and metadata.

Run the relevant platform tests and type checks, plus the required platform build. Add a minimal Godot fixture project for file/pack tests; this SDK checkout is an addon, not a standalone Godot project. Verify a real Web export as well as headless native/local fixtures.

Acceptance demonstration: upload one shared asset and read it from two distinct builds and a standalone experience. Confirm repeated requests use the same hashed URL and can hit caches. Replace it without uploading a build: existing launches keep their original mapping and can still fetch its bytes, while new launches retrieve the fresh manifest and new hashed URL. Reupload identical bytes and confirm URL reuse. Remove the logical asset and confirm new launches report it missing while older manifest snapshots still resolve their retained objects. Exercise this through each serving host.

## Delivery order

1. Platform manifest schema, hashing/publication helpers, serving/cache policy, upload API, portal management, and CLI.
2. Platform shared-root context, launch manifest loader, and JavaScript SDK capability; deploy with the serving changes and manifest cache-rule exclusions before a game depends on them.
3. Godot helpers, mock setting, fixture coverage, and SDK README examples.
4. Update `platform-dev/docs/developer-portal.md`, `docs/couch-games-sdk.md`, and the runtime README with logical/hashed paths, manifest behavior, upload limits, cache policies, retention, preview inheritance, and compatibility requirements.
5. Update one consuming game to the new Godot SDK and perform the acceptance demonstration.

Future options, driven by actual need: atomic publication of multi-file batches, retained-object garbage collection, explicit snapshot refresh/rebase controls, larger file limits, and engine SDKs beyond Godot. Download authentication remains outside this work, per the agreed public-access policy.
