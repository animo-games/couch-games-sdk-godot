# App-ID-free SDK export fixture

This fixture stages only SDK runtime directories in a disposable project. It
never installs anything in a game. Use the pinned ordinary Godot engine/templates
and the Steam GDExtension archive from the dependency locks.

```sh
python3 tests/steam/acquire.py --cache /tmp/sdk-dependencies
python3 fixtures/steam/package/build.py --godot /path/to/pinned/godot \
  --templates /path/to/pinned/templates.tpz \
  --godotsteam-zip /path/to/pinned/steam.zip --output /tmp/sdk-packages
cd fixtures/steam/package
npm ci --ignore-scripts
npx --no-install playwright install chromium
node web.mjs /tmp/sdk-packages
```

The output directory must not already exist. The builder exports Linux/Windows
x86_64 debug and release packages with the extension installed and absent, plus
native release packages carrying the `steam` feature. It exports Web release
packages from both source configurations. It uses custom template paths and the
real SDK export plugin, without manual Web exclusion filters. Generated projects
and templates stay in hidden output directories; runtime artifacts are the
named `linux-*`, `windows-*`, and `web-*` directories.

Each PCK is mounted and enumerated with the ordinary engine. Web must exclude
Steam scripts, descriptor and all native libraries. Native installed packages
must contain the descriptor and exact target/debug-or-release extension and
Steamworks runtime bytes from the checksum-verified archive. No App ID file is
created. Source and native-host smoke runs verify backend selection, shared
initialization, installed singleton loading and visible explicit Steam failure.
Native Steam-feature auto failure is also tested. Shared native packages retain
optional adapter scripts; they have no GodotSteam native dependency.

The builder executes native packages on the matching OS and records other
platforms as unexecuted. The browser runner executes both actual Web packages
in mock, explicit Steam and simulated Couch-parent modes. The Couch parent API
is a fixture double, not a live platform. Playwright and its browser revision
are pinned by `package-lock.json`. Local diagnostic overrides are available via
`PLAYWRIGHT_MODULE=/absolute/playwright/package` and
`CHROMIUM_EXECUTABLE=/absolute/chromium`; record when using a system browser.

Outputs:

- `evidence.json`: build/inspection results with explicit execution labels.
- `<artifact>/pack-paths.json`: actual mounted resource inventory.
- `web-evidence.json`: completed browser smoke results.
- `logs/`: import, build, inspection and smoke output.

A browser timeout, missing native dependency, wrong version/hash, script error,
nonzero exit or missing result fails the command. The workflow runs this builder
on both Linux and Windows and the browser runner on Linux. Remote CI execution
and live Steam acceptance are separate evidence; this fixture proves neither
until those runs actually happen.

See [Steam documentation](../../../docs/steam.md) and the checked-in
[local verification report](../../../docs/steam-verification.json). Live Steam
lobbies, invitations and achievement storage still require an App ID and
multiple authorized accounts.
