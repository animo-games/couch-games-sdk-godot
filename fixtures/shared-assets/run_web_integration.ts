/**
 * Cross-component acceptance fixture. Run this only against A's actual local
 * workerd/R2 worker on a fresh local state directory. It publishes through the
 * real shared-files helpers, bundles B's actual runtime source into a parent
 * page, and drives the exported Godot game at two build depths plus a
 * standalone-like depth.
 *
 * Required environment:
 *   PLATFORM_DIR=/tmp/couch-shared-platform
 *   WORKER_ORIGIN=http://127.0.0.1:8789
 *   PLAYWRIGHT_MODULE=/tmp/couch-shared-platform/node_modules/playwright
 */
import { readFile, stat } from "node:fs/promises";
import { basename, extname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const platformDir = process.env.PLATFORM_DIR ? resolve(process.env.PLATFORM_DIR) : "";
const workerOrigin = process.env.WORKER_ORIGIN?.replace(/\/$/, "") ?? "";
const playwrightModule = process.env.PLAYWRIGHT_MODULE ?? "";
const exportDir = resolve(process.argv[2] ?? "");
const assetsDir = resolve(process.argv[3] ?? "");
if (!platformDir || !workerOrigin || !playwrightModule || !process.argv[2] || !process.argv[3]) {
  throw new Error(
    "Usage: PLATFORM_DIR=/platform WORKER_ORIGIN=http://127.0.0.1:8789 " +
      "PLAYWRIGHT_MODULE=/path/to/playwright bun run_web_integration.ts /export-dir /assets-dir",
  );
}

const playwrightPath = resolve(playwrightModule);
const playwrightEntry = (await stat(playwrightPath)).isDirectory()
  ? join(playwrightPath, "index.mjs")
  : playwrightPath;
const { chromium } = await import(pathToFileURL(playwrightEntry).href);
const injectionEntry = join(platformDir, "packages/config/src/injections.ts");
const injectionModule = await import(pathToFileURL(injectionEntry).href);
const sdkBridge = injectionModule.SDK_BRIDGE;
if (typeof sdkBridge !== "string" || !sdkBridge.includes("window.CouchGames")) {
  throw new Error(`Platform SDK bridge is unavailable from ${injectionEntry}`);
}

const tempDir = await Bun.$`mktemp -d /tmp/couch-shared-runtime-parent.XXXXXX`.text();
const parentDir = tempDir.trim();
const runtimeEntry = join(platformDir, "packages/sdk-runtime/src/index.ts");
const parentEntry = join(parentDir, "parent.ts");
const parentBundle = join(parentDir, "parent.js");
await Bun.write(parentEntry, `
  import { createSdkRuntime, SdkRuntimeState } from ${JSON.stringify(runtimeEntry)};
  const state = new SdkRuntimeState();
  state.setSessionReadyState("ready");
  const runtime = createSdkRuntime({
    authentication: { getUserId: async () => "fixture-user" },
    endpoints: { dispatch: async () => ({ success: true }), shouldApplyMutation: () => true },
    browser: {
      publicTarget: window,
      getLocation: () => ({ origin: location.origin, protocol: location.protocol, host: location.host }),
      postToPublicTarget: (message, origin) => window.postMessage(message, origin),
      addMessageListener: (listener) => window.addEventListener("message", listener),
      removeMessageListener: (listener) => window.removeEventListener("message", listener),
      createWebSocket: (url) => new WebSocket(url),
      webSocketOpenState: WebSocket.OPEN,
      fetch: (url, init) => fetch(url, init),
    },
    signaling: { buildUrl: (base, room) => new URL("/ws/signaling/" + room, base).toString() },
    events: { sdkLog: () => {}, saveSucceeded: () => {}, saveRefused: () => {}, gameplayCompleted: () => {} },
    logger: { error: (message, error) => console.error(message, error) },
    clock: { now: () => Date.now(), setTimeout: (callback, delay) => setTimeout(callback, delay), clearTimeout: (id) => clearTimeout(id) },
  }, state);
  runtime.install(window);
  const frame = new URL(location.href).searchParams.get("frame");
  if (!frame) throw new Error("Missing frame path");
  const context = {
    activatedAt: new Date(), files: [], type: "regular", experienceIndex: 0,
    title: "Fixture", experienceId: "fixture", experienceUrl: location.href,
    experienceName: "Fixture", gameId: "shared-fixture", gameTitle: "Fixture",
    sharedRoot: new URL("/api/assets/games/shared-fixture/shared/", location.origin).toString(),
  };
  const generation = runtime.beginLaunch(context);
  const iframe = document.createElement("iframe");
  iframe.src = frame;
  document.body.append(iframe);
  addEventListener("beforeunload", () => runtime.endLaunch(generation));
`);
const build = await Bun.build({
  entrypoints: [parentEntry],
  // Bun.build writes through `outdir`; its CLI-only `--outfile` counterpart
  // is not a build-API output option and previously left parent.js absent.
  outdir: parentDir,
  target: "browser",
  minify: false,
});
if (!build.success) throw new Error(build.logs.map((entry) => entry.message).join("\n"));
let parentScript: Uint8Array;
try {
  parentScript = await readFile(parentBundle);
} catch (error) {
  throw new Error(
    `Runtime parent bundle missing at ${parentBundle}; Bun wrote: `
    + `${build.outputs.map((output) => output.path).join(", ")}`,
    { cause: error },
  );
}

const mime = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".wasm": "application/wasm",
  ".pck": "application/octet-stream",
  ".png": "image/png",
} as Record<string, string>;
const isolationHeaders = {
  "cross-origin-opener-policy": "same-origin",
  "cross-origin-embedder-policy": "require-corp",
  "cross-origin-resource-policy": "cross-origin",
};
const hopByHopHeaders = [
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
];

function injectSdkBridge(html: string): string {
  const head = html.match(/<head(?:\s[^>]*)?>/i);
  if (!head) throw new Error("Exported Godot HTML has no <head> for the platform SDK bridge");
  // This is the production by-reference iframe bridge. It assigns the parent
  // runtime object in the game realm before Godot's loader starts.
  return html.replace(head[0], `${head[0]}${sdkBridge}`);
}

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/parent") {
      return new Response("<script type=module src=/parent.js></script>", {
        headers: { "content-type": "text/html; charset=utf-8", ...isolationHeaders },
      });
    }
    if (url.pathname === "/parent.js") {
      return new Response(parentScript, {
        headers: { "content-type": "application/javascript; charset=utf-8", ...isolationHeaders },
      });
    }
    if (url.pathname.startsWith("/api/assets/")) {
      const upstream = await fetch(workerOrigin + url.pathname + url.search, {
        method: request.method,
        headers: request.headers,
      });
      const body = await upstream.arrayBuffer();
      const headers = new Headers(upstream.headers);
      // Bun fetches decoded bytes. Retaining the upstream encoding or original
      // compressed length makes Chromium decode the response a second time.
      headers.delete("content-encoding");
      headers.delete("content-length");
      for (const header of hopByHopHeaders) headers.delete(header);
      headers.set("content-length", String(body.byteLength));
      return new Response(body, { status: upstream.status, headers });
    }
    // Godot's HTML, JS, WASM and PCK request siblings from whichever build or
    // standalone depth they were launched at. A basename-only mapping prevents
    // that route depth from becoming a second asset namespace.
    const file = basename(url.pathname) || "shared-assets-fixture.html";
    const path = join(exportDir, file);
    try {
      if (!(await stat(path)).isFile()) throw new Error("not a file");
      const extension = extname(path);
      const body = await readFile(path);
      const servedBody = extension === ".html" ? injectSdkBridge(body.toString()) : body;
      return new Response(servedBody, {
        headers: {
          "content-type": mime[extension] ?? "application/octet-stream",
          ...isolationHeaders,
        },
      });
    } catch {
      return new Response("Not found", { status: 404 });
    }
  },
});

const origin = server.url.origin;
function browserAssetUrl(workerUrl: string): string {
  const published = new URL(workerUrl);
  // The parent runtime correctly maps through this fixture's same-origin proxy.
  // Publication reports the workerd origin, so normalize only its path/query
  // before comparing it with the iframe-visible immutable URL.
  return new URL(published.pathname + published.search, origin).toString();
}

async function publish(path: string, file: string, expectedRevision: string | null) {
  const sourcePath = file.startsWith("/") ? file : join(assetsDir, file);
  const response = await fetch(
    `${workerOrigin}/fixture/publish?path=${encodeURIComponent(path)}&expectedRevision=${expectedRevision ?? "null"}`,
    { method: "POST", headers: { "content-type": "application/octet-stream" }, body: await readFile(sourcePath) },
  );
  const data = await response.json() as { entry?: { revision?: string; sha256?: string }; url?: string; error?: string };
  if (!response.ok || !data.entry?.revision || !data.url) throw new Error(`Publish ${path} failed: ${data.error ?? response.status}`);
  return { revision: data.entry.revision, url: browserAssetUrl(data.url) };
}
async function seedEmpty() {
  const response = await fetch(`${workerOrigin}/fixture/seed-empty`, { method: "POST" });
  if (!response.ok) throw new Error(`Seed empty failed: ${await response.text()}`);
}
async function deleteFile(path: string, revision: string) {
  const response = await fetch(`${workerOrigin}/fixture/delete?path=${encodeURIComponent(path)}&expectedRevision=${encodeURIComponent(revision)}`, { method: "DELETE" });
  if (!response.ok) throw new Error(`Delete ${path} failed: ${await response.text()}`);
}

const browser = await chromium.launch({ headless: true });
type LaunchExpectation = {
  url: string;
  bytes: number;
  hex: string;
};

async function launch(framePath: string, expected: LaunchExpectation) {
  const page = await browser.newPage();
  const output: string[] = [];
  const resultPromise = new Promise<string>((resolve, reject) => {
    let settled = false;
    let timeout: ReturnType<typeof setTimeout> | undefined;
    const fail = (error: Error) => {
      if (settled) return;
      settled = true;
      if (timeout !== undefined) clearTimeout(timeout);
      reject(error);
    };
    const succeed = (result: string) => {
      if (settled) return;
      settled = true;
      if (timeout !== undefined) clearTimeout(timeout);
      resolve(result);
    };
    timeout = setTimeout(
      () => fail(new Error(`No Godot result at ${framePath}:\n${output.join("\n")}`)),
      30_000,
    );
    page.on("console", (message: { text(): string }) => {
      const line = message.text();
      output.push(line);
      if (line.includes("SHARED_FIXTURE_UNAVAILABLE")) {
        fail(new Error(`Godot selected the mock backend at ${framePath}:\n${output.join("\n")}`));
      } else if (line.includes("ERR_CONTENT_DECODING_FAILED")) {
        fail(new Error(`Proxy response was decoded twice: ${line}`));
      } else if (line.includes("SHARED_FIXTURE_RESULT")) {
        succeed(line);
      }
    });
    page.on("pageerror", (error: Error) => {
      fail(new Error(`Browser page error at ${framePath}: ${error.message}`, { cause: error }));
    });
  });
  await page.goto(`${origin}/parent?frame=${encodeURIComponent(framePath)}`, {
    waitUntil: "domcontentloaded",
    timeout: 120_000,
  });
  const result = await resultPromise;
  if (!result.includes(`url=${expected.url}`)
      || !result.includes(`bytes=${expected.bytes}`)
      || !result.includes("empty=0")
      || !result.includes("pack=true")
      || !result.includes(`hex=${expected.hex} mock=false`)) {
    throw new Error(`Unexpected Godot fixture result: ${result}`);
  }
  return { page, result };
}

try {
  const first = await publish("nested/binary.bin", "nested/binary.bin", null);
  await seedEmpty();
  await publish("packs/common.pck", "packs/common.pck", null);
  const firstExpected = { url: first.url, bytes: 7, hex: "000102ff008040" };
  const one = await launch("/build/one/shared-assets-fixture.html", firstExpected);
  const oldInfo = await one.page.evaluate(() => window.CouchGames.game.getSharedFileInfo("nested/binary.bin"));
  const two = await launch("/build/deeper/two/shared-assets-fixture.html", firstExpected);
  const standalone = await launch("/standalone/experience/depth/shared-assets-fixture.html", firstExpected);
  if (![one.result, two.result, standalone.result].every((line) => line.includes(`url=${first.url}`))) {
    throw new Error("Build-depth or standalone launch did not resolve the first immutable URL");
  }

  const replacementBytes = new Uint8Array([7, 6, 5, 4, 3, 2, 1]);
  const replacementPath = join(parentDir, "replacement.bin");
  await Bun.write(replacementPath, replacementBytes);
  const replacement = await publish("nested/binary.bin", replacementPath, first.revision);
  if (replacement.url === first.url) throw new Error("Changed bytes reused the old immutable URL");
  const oldAgain = await one.page.evaluate(() => window.CouchGames.game.getSharedFileInfo("nested/binary.bin"));
  if (oldAgain.url !== oldInfo.url || oldAgain.url !== first.url) throw new Error("Existing runtime snapshot changed after replacement");
  const oldBytes = await one.page.evaluate(async (url) => Array.from(new Uint8Array(await (await fetch(url)).arrayBuffer())), oldInfo.url);
  if (oldBytes.join(",") !== "0,1,2,255,0,128,64") throw new Error("Old immutable object was not retained");
  const fresh = await launch("/build/fresh/replaced/shared-assets-fixture.html", {
    url: replacement.url,
    bytes: 7,
    hex: "07060504030201",
  });
  if (!fresh.result.includes(`url=${replacement.url}`)) throw new Error("Fresh launch did not read replaced manifest entry");

  const identical = await publish("nested/binary.bin", replacementPath, replacement.revision);
  if (identical.url !== replacement.url) throw new Error("Identical reupload did not reuse immutable URL");
  await deleteFile("nested/binary.bin", identical.revision);
  const removed = await launch("/standalone/removed/shared-assets-fixture.html", {
    url: "",
    bytes: 0,
    hex: "",
  });
  if (!/url=\s+bytes=0\b/.test(removed.result)) throw new Error("New launch resolved deleted logical path");
  console.log("SHARED_ASSETS_WEB_INTEGRATION_PASS");
} finally {
  await browser.close();
  server.stop(true);
  await Bun.$`rm -rf ${parentDir}`;
}
