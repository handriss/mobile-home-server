// Compare headless vs headed-on-virtual-display for fingerprint / bot detection
// and memory cost. Run as:  node --require ./shim.cjs display-bench.mjs headless|headed
import { chromium } from 'playwright-core';

const MODE = process.argv[2] || 'headed';
const HEADED = MODE === 'headed';
const EXEC = '/data/data/com.termux/files/usr/lib/chromium/chrome';
const PROFILE = `${process.env.HOME}/job-search-pipeline-data/profiles/vd-${MODE}`;

const ARGS = [
  '--no-sandbox',
  '--disable-dev-shm-usage',
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-blink-features=AutomationControlled',
  '--disable-features=Translate,MediaRouter,OptimizationHints',
  '--disable-background-networking',
  '--disable-sync',
  '--mute-audio',
];
// Headed on a software-rendered X server: let Chromium use SwiftShader rather
// than trying (and failing) to reach a real GPU.
if (HEADED) ARGS.push('--window-size=1280,900', '--use-gl=swiftshader');
else ARGS.push('--disable-gpu');

const ms = (t) => `${Math.round(t)}ms`;

const run = async () => {
  const t0 = performance.now();
  const ctx = await chromium.launchPersistentContext(PROFILE, {
    executablePath: EXEC,
    headless: !HEADED,
    args: ARGS,
    viewport: HEADED ? null : { width: 1280, height: 900 },
    locale: 'en-US',
    timeout: 180000,
  });
  console.log(`MODE=${MODE} COLD_START ${ms(performance.now() - t0)}`);
  const page = await ctx.newPage();

  // --- what the page can observe about us
  await page.goto('https://bot.sannysoft.com/', { waitUntil: 'domcontentloaded', timeout: 90000 });
  await page.waitForTimeout(4000);
  const fp = await page.evaluate(() => ({
    webdriver: navigator.webdriver,
    headlessUA: /headless/i.test(navigator.userAgent),
    ua: navigator.userAgent.slice(0, 95),
    plugins: navigator.plugins.length,
    languages: (navigator.languages || []).join(','),
    hardwareConcurrency: navigator.hardwareConcurrency,
    deviceMemory: navigator.deviceMemory,
    webglVendor: (() => {
      try {
        const gl = document.createElement('canvas').getContext('webgl');
        const d = gl.getExtension('WEBGL_debug_renderer_info');
        return gl.getParameter(d.UNMASKED_RENDERER_WEBGL).slice(0, 60);
      } catch { return 'unavailable'; }
    })(),
    outerDims: `${window.outerWidth}x${window.outerHeight}`,
    screen: `${screen.width}x${screen.height}`,
  }));
  console.log('FINGERPRINT', JSON.stringify(fp, null, 1).replace(/\n\s*/g, ' '));

  // sannysoft marks failures with a red cell; count them
  const failed = await page.evaluate(() =>
    [...document.querySelectorAll('td.result.failed, td.failed')].map(td =>
      td.parentElement?.firstElementChild?.textContent?.trim()).filter(Boolean));
  console.log(`SANNYSOFT_FAILED[${failed.length}] ${failed.join(' | ') || '(none)'}`);

  // --- do real gatekeepers let us in?
  for (const [name, url] of [
    ['google  ', 'https://www.google.com/search?q=weather+budapest'],
    ['amazon  ', 'https://www.amazon.com/'],
    ['bing    ', 'https://www.bing.com/search?q=test'],
  ]) {
    try {
      const r = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
      await page.waitForTimeout(2500);
      const body = (await page.evaluate(() => document.body?.innerText || '')).replace(/\s+/g, ' ');
      const blocked = /unusual traffic|are you a robot|not a robot|captcha|enter the characters|sorry, we just/i.test(body);
      console.log(`GATE ${name} HTTP ${r.status()} len=${body.length} ${blocked ? 'BLOCKED' : (body.length < 200 ? 'EMPTY/SOFT-BLOCK' : 'OK')} :: ${body.slice(0, 80)}`);
    } catch (e) {
      console.log(`GATE ${name} ERR ${e.message.split('\n')[0].slice(0, 80)}`);
    }
  }

  await ctx.close();
  console.log('DONE');
};

run().catch(e => { console.error('FATAL', e.message); process.exit(1); });
