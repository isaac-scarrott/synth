// Render the share card — site/og/card.html — to site/img/share-card.png.
//
//   node site/og/render.js
//   PLAYWRIGHT=<path to playwright-core>   (found for you if Synth's browser MCP is installed)
//
// Drawn, not photographed, so it does not go through site/capture/: that rig builds an app
// bundle, clones repos and spawns live agents to take a picture of the product. This is 1200x630
// of type, and type at that size is a layout problem, not a scene.
//
// Rendered at 2x and downsampled to 1200x630, which is the size every unfurl scales down from.
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const CARD = path.join(__dirname, 'card.html');
const OUT = path.join(__dirname, '..', 'img', 'share-card.png');

function playwright() {
  if (process.env.PLAYWRIGHT) return process.env.PLAYWRIGHT;
  const p = path.join(process.env.HOME, 'Library/Application Support/Synth',
                      'browser-mcp/node_modules/playwright-core');
  if (fs.existsSync(p)) return p;
  console.error("error: no playwright-core. Set PLAYWRIGHT, or install Synth's browser MCP.");
  process.exit(1);
}

(async () => {
  const { chromium } = require(playwright());
  const b = await chromium.launch();
  const page = await b.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 2 });
  await page.goto('file://' + CARD);
  await page.evaluate(() => document.fonts.ready);

  // A card whose webfont never arrived is set in the system sans: close enough to look right at
  // a glance and wrong in every letterform, and nothing downstream would ever say so. Fail here
  // instead of shipping it.
  if (!await page.evaluate(() => document.fonts.check('500 68px Geist'))) {
    console.error('error: Geist never loaded — the card would ship in the fallback face');
    process.exit(1);
  }

  await page.screenshot({ path: OUT });
  await b.close();

  execFileSync('sips', ['-z', '630', '1200', OUT], { stdio: 'ignore' });
  console.log('%s  %d KB', path.relative(process.cwd(), OUT),
              Math.round(fs.statSync(OUT).size / 1024));
})();
