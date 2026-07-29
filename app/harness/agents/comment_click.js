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
  // The overlay batches, so its delivery message is a commentBatch even for one comment —
  // this stands in for the real one so the gate exercises the host's receive path, not a
  // shape the page can no longer produce.
  await page.evaluate((text) => {
    const el = document.querySelector('#cta');
    const r = el.getBoundingClientRect();
    window.__synthComment(JSON.stringify({
      type: 'commentBatch', url: location.href, title: document.title,
      viewport: { width: innerWidth, height: innerHeight, dpr: devicePixelRatio },
      comments: [{
        n: 1, comment: text, url: location.href, onCurrentPage: true,
        selector: '#cta', xpath: '', elementHTML: el.outerHTML, elementText: el.textContent,
        reactSource: null,
        rect: { x: r.x, y: r.y, width: r.width, height: r.height,
                scrollX: scrollX, scrollY: scrollY, dpr: devicePixelRatio },
      }],
    }));
  }, comment);
  console.log('SENT');
  await b.close();
})().catch(e => { console.log('ERR ' + e.message); process.exit(4); });
