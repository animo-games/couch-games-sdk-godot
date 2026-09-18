#!/usr/bin/env node
// Isolated compatibility check for the actual Godot Web export. The full
// workerd/R2 + parent-runtime integration is separate; this only proves that a
// no-parent page leaves existing mock APIs intact while shared assets report
// unavailable instead of falling through to a local shared-files directory.
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { extname, join, normalize, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const outputDir = resolve(process.argv[2] ?? "");
const playwrightModule = process.env.PLAYWRIGHT_MODULE;
if (!process.argv[2] || !playwrightModule) {
  throw new Error("Usage: PLAYWRIGHT_MODULE=/path/to/playwright node run_web_no_parent.mjs /absolute/export-dir");
}
const playwrightPath = resolve(playwrightModule);
const playwrightEntry = (await stat(playwrightPath)).isDirectory()
  ? join(playwrightPath, "index.mjs")
  : playwrightPath;
const { chromium } = await import(pathToFileURL(playwrightEntry).href);
const mimeTypes = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".wasm": "application/wasm",
  ".pck": "application/octet-stream",
  ".png": "image/png",
};

const server = createServer(async (request, response) => {
  const relative = normalize(new URL(request.url, "http://fixture").pathname)
    .replace(/^[/\\]+/, "");
  const path = join(outputDir, relative || "shared-assets-fixture.html");
  if (!path.startsWith(outputDir + "/") && path !== outputDir) {
    response.writeHead(400).end();
    return;
  }
  try {
    if (!(await stat(path)).isFile()) throw new Error("not a file");
    response.writeHead(200, {
      "content-type": mimeTypes[extname(path)] ?? "application/octet-stream",
      "cross-origin-opener-policy": "same-origin",
      "cross-origin-embedder-policy": "require-corp",
      "cross-origin-resource-policy": "cross-origin",
    });
    response.end(await readFile(path));
  } catch {
    response.writeHead(404).end();
  }
});

let listening = false;
await new Promise((resolveListen, rejectListen) => {
  const onError = (error) => {
    server.off("error", onError);
    rejectListen(error);
  };
  server.once("error", onError);
  server.listen(0, "127.0.0.1", () => {
    server.off("error", onError);
    listening = true;
    resolveListen();
  });
});
const address = server.address();
const url = `http://127.0.0.1:${address.port}/shared-assets-fixture.html`;
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  const output = [];
  page.on("console", (message) => output.push(message.text()));
  await page.goto(url, { waitUntil: "networkidle", timeout: 120_000 });
  await page.waitForFunction(() =>
    Array.from(document.querySelectorAll("canvas")).length > 0, null, { timeout: 30_000 });
  await page.waitForTimeout(1_000);
  if (!output.some((line) => line.includes("SHARED_FIXTURE_UNAVAILABLE"))) {
    throw new Error(`Expected no-parent shared capability result. Console:\n${output.join("\n")}`);
  }
  console.log("SHARED_ASSETS_WEB_NO_PARENT_PASS");
} finally {
	await browser.close();
	if (listening) await new Promise((resolveClose) => server.close(resolveClose));
}
