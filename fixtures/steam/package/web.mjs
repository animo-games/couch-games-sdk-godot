// Actual exported Web artifact; Couch parent API is simulated, not live service acceptance.
import { createServer } from 'node:http';
import { readFile, writeFile } from 'node:fs/promises';
import { join, resolve, extname } from 'node:path';
import { pathToFileURL } from 'node:url';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE
  ? pathToFileURL(resolve(process.env.PLAYWRIGHT_MODULE, 'index.mjs')).href : 'playwright');
const output = resolve(process.argv[2]);
if (!process.argv[2]) throw new Error('Usage: node web.mjs /absolute/package-output');
const types = { '.html': 'text/html', '.js': 'application/javascript', '.wasm': 'application/wasm', '.pck': 'application/octet-stream' };
const server = createServer(async (request, response) => {
  const name = decodeURIComponent(new URL(request.url, 'http://fixture').pathname).slice(1);
  const file = resolve(output, name);
  if (!file.startsWith(output + '/')) return response.writeHead(403).end();
  try {
    const body = await readFile(file);
    response.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream' });
    response.end(body);
  } catch { response.writeHead(404).end(); }
});
await new Promise((done, fail) => { server.once('error', fail); server.listen(0, '127.0.0.1', done); });
const browser = await chromium.launch({ headless: true,
  ...(process.env.CHROMIUM_EXECUTABLE ? { executablePath: process.env.CHROMIUM_EXECUTABLE } : {}),
  args: ['--enable-webgl', '--use-gl=angle', '--use-angle=swiftshader'] });
const reports = [];
try {
  for (const artifact of ['web-release-shared', 'web-release-steam']) {
    for (const mode of ['mock', 'steam', 'couch']) {
      const page = await browser.newPage();
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      page.on('console', message => {
        if (/SCRIPT ERROR|FAIL:|Failed to load script|No GDExtension library found/.test(message.text())) errors.push(message.text());
      });
      if (mode === 'couch') await page.addInitScript(() => {
        const me = { userId: 'browser-user', username: 'Browser Fixture', role: 'host', controllerSlot: 0, status: 'lobby', ping: -1 };
        window.CouchGames = {
          lobby: {
            onAnyEvent() {}, onPlayersChanged(callback) { callback([me]); },
            getLobbyPlayers() { return [me]; }, getMe() { return me; },
            getCurrentGame() { return { gameId: 'sdk-package', experienceId: 'fixture' }; }, sendEvent() {},
          },
          getExperienceData() { return Promise.resolve({ success: true, payload: {} }); },
          getAchievements() { return Promise.resolve({ success: true, payload: { achievements: [] } }); },
        };
      });
      await page.goto(`http://127.0.0.1:${server.address().port}/${artifact}/smoke.html?mode=${mode}`);
      try {
        await page.waitForFunction(() => window.sdkPackageResult, { timeout: 45000 });
      } catch (error) { throw new Error(`${artifact}/${mode}: no smoke result; ${errors.join('\n')}`, { cause: error }); }
      const report = await page.evaluate(() => window.sdkPackageResult);
      if (report.failures || errors.length || report.backend !== mode || !report.web) {
        throw new Error(`${artifact}/${mode}: ${JSON.stringify(report)}; ${errors.join('\n')}`);
      }
      reports.push({ artifact, ...report, couch_provider: mode === 'couch' ? 'simulated JavaScript parent API' : undefined });
      await page.close();
    }
  }
  await writeFile(join(output, 'web-evidence.json'), JSON.stringify(reports, null, 2) + '\n');
  console.log(`WEB_PACKAGE_SMOKE_OK: ${reports.length} actual browser runs`);
} finally {
  await browser.close();
  await new Promise(done => server.close(done));
}
