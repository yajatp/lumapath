// Requires Playwright (npm install --no-save playwright) and Chrome.
// Run from the repository root: node Tools/Design/render_deck.cjs
const {chromium} = require('playwright');
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const {execFileSync} = require('node:child_process');
(async () => {
  const root = path.resolve(__dirname, '../..');
  const browser = await chromium.launch({channel: 'chrome', headless: true});
  try {
    const page = await browser.newPage({viewport: {width: 1600, height: 1200}, deviceScaleFactor: 2});
    await page.goto(pathToFileURL(path.join(root, '.impeccable/reference/index.html')).href);
    await page.evaluate(() => document.fonts.ready);
    const sections = page.locator('section');
    const names = ['home', 'find', 'live', 'objects', 'accessibility', 'watch'];
    for (let i = 0; i < names.length; i++) {
      const figure = sections.nth(i + 1).locator('figure').last();
      // Exclude deck-version metadata from the public previews.
      await figure.locator(':scope > div').first().evaluate(e => e.remove());
      await figure.screenshot({path: path.join(root, `docs/demos/${names[i]}.png`)});
    }
    await page.setViewportSize({width: 1024, height: 1024});
    await page.goto(pathToFileURL(path.join(root, 'docs/brand/lumapath-icon.svg')).href);
    const icon = path.join(root, 'docs/brand/lumapath-icon.png');
    await page.screenshot({path: icon});
    execFileSync('sips', ['-z', '1024', '1024', icon, '--out', icon]);
    for (const target of ['LumaPath/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png', 'LumaPath/WatchApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png']) {
      execFileSync('sips', ['-z', '1024', '1024', icon, '--out', path.join(root, target)]);
    }
    for (const scale of [1, 2, 3]) {
      execFileSync('sips', ['-z', String(64 * scale), String(64 * scale), icon, '--out', path.join(root, `LumaPath/App/Assets.xcassets/LumaBrand.imageset/lantern@${scale}x.png`)]);
    }
  } finally { await browser.close(); }
})();
