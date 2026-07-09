// Fire the exact CDP binding the comment overlay uses, from inside the real page.
const path = require('path'), os = require('os');
const PW = path.join(os.homedir(), 'Library/Application Support/Synth/browser-mcp/node_modules/playwright-core');
const { chromium } = require(PW);
const [port, needle, comment] = process.argv.slice(2);
(async () => {
  const b = await chromium.connectOverCDP(`http://127.0.0.1:${port}`);
  const pages = b.contexts().flatMap(c => c.pages());
  const page = pages.find(p => p.url().includes(needle)) || pages[0];
  if (!page) { console.log('NOPAGE'); process.exit(2); }
  const has = await page.evaluate(() => typeof window.__synthComment === 'function');
  if (!has) { console.log('NOBINDING'); process.exit(3); }
  await page.evaluate((text) => {
    const el = document.querySelector('#cta');
    const r = el.getBoundingClientRect();
    window.__synthComment(JSON.stringify({
      type: 'comment', url: location.href, selector: '#cta',
      rect: { x: r.x, y: r.y, width: r.width, height: r.height },
      elementHTML: el.outerHTML, comment: text,
    }));
  }, comment);
  console.log('SENT');
  await b.close();
})().catch(e => { console.log('ERR ' + e.message); process.exit(4); });
