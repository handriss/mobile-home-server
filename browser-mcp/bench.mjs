// Feasibility benchmark: can this phone drive a real Chromium?
// Measures cold start, warm navigation, and profile persistence.
import { chromium } from 'playwright-core';
import fs from 'node:fs';

const EXEC = process.env.CHROME_BIN || '/data/data/com.termux/files/usr/lib/chromium/chrome';
const PROFILE = process.env.PROFILE_DIR || `${process.env.HOME}/job-search-pipeline-data/profiles/bench`;
const MODE = process.argv[2] || 'full';

// Flags chosen for a no-namespace, no-GPU, memory-constrained Android host.
const ARGS = [
  '--no-sandbox',
  '--disable-dev-shm-usage',       // /dev/shm is tiny/absent; use disk instead
  '--disable-gpu',
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-features=Translate,MediaRouter,OptimizationHints',
  '--disable-background-networking',
  '--disable-sync',
  '--metrics-recording-only',
  '--mute-audio',
];

const PAGES = [
  ['hn        ', 'https://news.ycombinator.com/'],
  ['wikipedia ', 'https://en.wikipedia.org/wiki/Android_(operating_system)'],
  ['theverge  ', 'https://www.theverge.com/'],
  ['amazon    ', 'https://www.amazon.com/'],
];

const ms = (t) => `${Math.round(t)}ms`;
const results = { cold: null, navs: [], errors: [] };

async function run() {
  if (MODE === 'persist-check') return persistCheck();

  fs.mkdirSync(PROFILE, { recursive: true });

  // ---- COLD START: process spawn -> CDP ready -> usable page object
  const t0 = performance.now();
  const ctx = await chromium.launchPersistentContext(PROFILE, {
    executablePath: EXEC,
    headless: true,
    args: ARGS,
    viewport: { width: 1280, height: 900 },
    timeout: 120000,
  });
  const coldMs = performance.now() - t0;
  results.cold = coldMs;
  console.log(`COLD_START ${ms(coldMs)}`);

  const page = await ctx.newPage();

  // ---- NAVIGATIONS on real pages
  for (const [name, url] of PAGES) {
    try {
      const t = performance.now();
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 90000 });
      const dcl = performance.now() - t;
      let settled = dcl;
      try {
        await page.waitForLoadState('load', { timeout: 45000 });
        settled = performance.now() - t;
      } catch { /* some ad-heavy pages never fire a clean load; DCL is the useful number */ }

      // Measure what an agent would actually consume: a11y snapshot vs raw HTML.
      // page.accessibility was removed in modern Playwright; ariaSnapshot is the
      // supported equivalent and is what @playwright/mcp serves to the model.
      const html = (await page.content()).length;
      const text = (await page.evaluate(() => document.body?.innerText || '')).length;
      let snap = -1;
      const tSnap = performance.now();
      try { snap = (await page.locator('body').ariaSnapshot({ timeout: 30000 })).length; } catch { /* leave -1 */ }
      const snapMs = performance.now() - tSnap;

      console.log(`NAV ${name} dcl=${ms(dcl)} load=${ms(settled)} html=${(html/1024).toFixed(0)}kB text=${(text/1024).toFixed(0)}kB a11y=${(snap/1024).toFixed(0)}kB(${ms(snapMs)})`);
      results.navs.push({ name: name.trim(), dcl, settled, html, text, snap, snapMs });
    } catch (e) {
      console.log(`NAV ${name} FAILED: ${e.message.split('\n')[0]}`);
      results.errors.push({ page: name.trim(), error: e.message.split('\n')[0] });
    }
  }

  // ---- WARM NAVIGATION: same page twice, browser already hot
  const warm = [];
  for (let i = 0; i < 3; i++) {
    const t = performance.now();
    await page.goto('https://en.wikipedia.org/wiki/Chromium_(web_browser)', { waitUntil: 'domcontentloaded', timeout: 60000 });
    warm.push(performance.now() - t);
  }
  console.log(`WARM_NAV ${warm.map(ms).join(' ')}`);
  results.warm = warm;

  // ---- SCREENSHOT cost
  const ts = performance.now();
  const shot = await page.screenshot({ type: 'jpeg', quality: 60 });
  console.log(`SCREENSHOT ${ms(performance.now() - ts)} ${shot.length}b`);
  results.screenshot = { ms: performance.now() - ts, bytes: shot.length };

  // ---- PROFILE PERSISTENCE: write a cookie + localStorage, then exit
  await page.goto('https://example.com/', { waitUntil: 'domcontentloaded' });
  await ctx.addCookies([{
    name: 'phone_persist_probe', value: 'survived-restart',
    domain: '.example.com', path: '/',
    expires: Math.floor(Date.now() / 1000) + 86400 * 30,
    httpOnly: false, secure: true, sameSite: 'Lax',
  }]);
  await page.evaluate(() => localStorage.setItem('phone_probe', 'ls-survived'));
  console.log('PERSIST_WRITTEN cookie+localStorage');

  await ctx.close();
  fs.writeFileSync(`${process.env.HOME}/job-search-pipeline-data/bench.json`, JSON.stringify(results, null, 2));
  console.log('DONE');
}

// Relaunch the SAME profile in a NEW process and check the cookie survived.
async function persistCheck() {
  const t0 = performance.now();
  const ctx = await chromium.launchPersistentContext(PROFILE, {
    executablePath: EXEC, headless: true, args: ARGS, timeout: 120000,
  });
  console.log(`RESTART_COLD ${ms(performance.now() - t0)}`);
  const cookies = await ctx.cookies('https://example.com');
  const probe = cookies.find(c => c.name === 'phone_persist_probe');
  const page = await ctx.newPage();
  await page.goto('https://example.com/', { waitUntil: 'domcontentloaded' });
  const ls = await page.evaluate(() => localStorage.getItem('phone_probe'));
  console.log(`COOKIE_SURVIVED ${probe ? 'YES value=' + probe.value : 'NO'}`);
  console.log(`LOCALSTORAGE_SURVIVED ${ls ? 'YES value=' + ls : 'NO'}`);
  await ctx.close();
  console.log('DONE');
}

run().catch(e => { console.error('FATAL', e); process.exit(1); });
