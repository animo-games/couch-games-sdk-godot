# Shared-assets fixture

The fixture projects link the SDK checkout into a disposable Godot project;
they never recursively copy the addon or download dependencies.

Native coverage uses Godot 4.5.1 and a loopback HTTP server for transfer
de-duplication and retry:

```sh
XDG_DATA_HOME=/tmp/couch-games-sdk-xdg-data \
XDG_CONFIG_HOME=/tmp/couch-games-sdk-xdg-config \
XDG_CACHE_HOME=/tmp/couch-games-sdk-xdg-cache \
GODOT=/path/to/Godot_v4.5.1-stable_linux.x86_64 \
./fixtures/shared-assets/run_native.sh
```

Build a real Web export and its deterministic publication assets with:

```sh
GODOT=/path/to/Godot_v4.5.1-stable_linux.x86_64 \
./fixtures/shared-assets/export_web.sh /tmp/couch-shared-assets-web-export
GODOT=/path/to/Godot_v4.5.1-stable_linux.x86_64 \
./fixtures/shared-assets/prepare_assets.sh /tmp/couch-shared-godot-fixture-assets
```

The isolated Web compatibility check accepts either the Playwright package
directory or its `index.mjs` entry, starts a local COOP/COEP static host, and
checks that a no-parent export prints `SHARED_FIXTURE_UNAVAILABLE`:

```sh
PLAYWRIGHT_MODULE=/tmp/couch-shared-platform/node_modules/playwright \
node ./fixtures/shared-assets/run_web_no_parent.mjs /tmp/couch-shared-assets-web-export
```

The complete integration test publishes generated assets through the real
shared-files helpers and serves this export under two build URL depths and a
standalone-experience depth. It needs the platform checkout at
`/tmp/couch-shared-platform` and an empty, dedicated local R2 directory. From
the platform repository root, start its fixture worker with:

```sh
cd /tmp/couch-shared-platform
bun x wrangler dev --config packages/api/shared-assets.fixture.wrangler.jsonc \
  --local --port 8789 --persist-to /tmp/couch-shared-r2-fixture
```

When the working directory is `/tmp/couch-shared-platform/packages/api`, use
`--config shared-assets.fixture.wrangler.jsonc` instead. Remove the dedicated
`/tmp/couch-shared-r2-fixture` directory only before starting a fresh fixture
state. With that worker running, execute this Bun command only in the scheduled
serial slot from this SDK checkout:

```sh
PLATFORM_DIR=/tmp/couch-shared-platform \
WORKER_ORIGIN=http://127.0.0.1:8789 \
PLAYWRIGHT_MODULE=/tmp/couch-shared-platform/node_modules/playwright \
bun ./fixtures/shared-assets/run_web_integration.ts \
  /tmp/couch-shared-assets-web-export \
  /tmp/couch-shared-godot-fixture-assets
```

It verifies immutable URL reuse for identical bytes, changed URL after a
replacement, retention through an old runtime snapshot, and missing resolution
after deletion.
