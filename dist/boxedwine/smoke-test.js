// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors
//
// Plays a relay mod on the site's Windows emulator page (dist/pages/windows.html) in headless Chromium for a
// while and keeps what happened: a screenshot every 30 seconds, the page's status lines, what Wine printed and
// how fast the emulator ran. The WebAssembly workflow runs it after publishing the site and keeps the results
// in the repository's windows-test branch.
//
//   node smoke-test.js PAGE_URL OUTPUT_DIR [MINUTES]
//
// The mod: the one named in WINDOWS_TEST_PACK (an id or part of a title), else the first whose id or title
// mentions Naruto, else the first one.
'use strict';
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const [pageUrl, outDir, minutesText = '12'] = process.argv.slice(2);
if (!pageUrl || !outDir) {
  console.error('usage: node smoke-test.js PAGE_URL OUTPUT_DIR [MINUTES]');
  process.exit(2);
}
const minutes = Number(minutesText);
fs.mkdirSync(outDir, { recursive: true });
const summary = { page: pageUrl, started: new Date().toISOString(), pack: null, samples: [], errors: [] };
const save = () => fs.writeFileSync(path.join(outDir, 'summary.json'), JSON.stringify(summary, null, 2));

(async () => {
  const browser = await chromium.launch({
    args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
      '--autoplay-policy=no-user-gesture-required'],
  });
  const page = await browser.newPage({ viewport: { width: 1400, height: 1000 } });
  page.on('pageerror', (error) => summary.errors.push('page: ' + error.message));
  page.on('crash', () => summary.errors.push('the page crashed'));
  await page.goto(pageUrl, { waitUntil: 'load', timeout: 120000 });
  // The relay's mods fill the list.
  await page.waitForFunction(() => document.querySelectorAll('#pack option').length > 1
    || /no Windows emulator|unavailable|no mods/.test(document.getElementById('status').textContent), null, { timeout: 120000 })
    .catch(() => {});
  const options = await page.$$eval('#pack option', (list) => list.filter((o) => o.value).map((o) => ({ id: o.value, title: o.textContent })));
  summary.options = options;
  const wanted = (process.env.WINDOWS_TEST_PACK || '').toLowerCase();
  const matches = (test) => options.find((o) => test(o.id.toLowerCase()) || test(o.title.toLowerCase()));
  const choice = (wanted && matches((text) => text.includes(wanted))) || matches((text) => text.includes('naruto')) || options[0];
  if (!choice) {
    summary.errors.push('no mod to play: ' + await page.$eval('#status', (e) => e.textContent));
    save();
    await page.screenshot({ path: path.join(outDir, 'no-mod.png') });
    await browser.close();
    return;
  }
  summary.pack = choice;
  await page.selectOption('#pack', choice.id);
  await page.click('#start');
  const started = Date.now();
  let shot = 0;
  let keysSent = false;
  while (Date.now() - started < minutes * 60000) {
    await page.waitForTimeout(30000);
    shot += 1;
    const elapsed = Math.round((Date.now() - started) / 1000);
    const name = `${String(shot).padStart(2, '0')}-${elapsed}s.png`;
    const screen = await page.$('#screen:not([hidden])');
    await (screen || page).screenshot({ path: path.join(outDir, name) }).catch((error) => summary.errors.push('screenshot: ' + error.message));
    const state = await page.evaluate(() => {
      const log = window.OpenLF2WindowsLog || [];
      const mips = log.filter((line) => line.startsWith('[MIPS]')).slice(-1)[0] || '';
      return { status: document.getElementById('status').textContent, lines: log.length, mips, last: log.slice(-3) };
    });
    summary.samples.push({ seconds: elapsed, screenshot: name, ...state });
    save();
    // Halfway: the keys LF2 starts a game with, to see whether the game takes keyboard input.
    if (!keysSent && Date.now() - started > minutes * 30000) {
      keysSent = true;
      const box = screen && await screen.boundingBox();
      if (box) await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
      for (const key of ['Enter', 'j', 'j', 'Enter']) {
        await page.keyboard.down(key);
        await page.waitForTimeout(150);
        await page.keyboard.up(key);
        await page.waitForTimeout(1500);
      }
      summary.keys = 'clicked the game, then pressed Enter, J, J, Enter';
    }
  }
  const log = await page.evaluate(() => (window.OpenLF2WindowsLog || []).join('\n'));
  fs.writeFileSync(path.join(outDir, 'wine-log.txt'), log);
  summary.finished = new Date().toISOString();
  save();
  await browser.close();
})().catch((error) => {
  summary.errors.push(String(error && error.stack ? error.stack : error));
  save();
  process.exitCode = 1;
});
