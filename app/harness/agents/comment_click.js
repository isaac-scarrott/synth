// Fire the exact CDP binding the comment overlay uses, from inside the real page.
//
//   node comment_click.js <port> <needle> <comment> [more comments…]
//
// One argument per comment, so a batch is just more arguments — the overlay batches, so its
// delivery message is a commentBatch even for one comment. A comment whose text starts with
// "offpage:" is stamped with another URL and onCurrentPage:false, standing in for a pin left
// on a page the browser has since navigated away from (the host must skip its screenshot and
// still carry its text).
const path = require('path'), os = require('os');
const PW = path.join(os.homedir(), 'Library/Application Support/Synth/browser-mcp/node_modules/playwright-core');
const { chromium } = require(PW);
const [port, needle, ...comments] = process.argv.slice(2);
(async () => {
  const b = await chromium.connectOverCDP(`http://127.0.0.1:${port}`);
  const pages = b.contexts().flatMap(c => c.pages());
  const page = pages.find(p => p.url().includes(needle)) || pages[0];
  if (!page) { console.log('NOPAGE'); process.exit(2); }
  const has = await page.evaluate(() => typeof window.__synthComment === 'function');
  if (!has) { console.log('NOBINDING'); process.exit(3); }
  await page.evaluate((texts) => {
    // Spread the pins over whatever the page actually has, so each comment names a different
    // element — a batch whose comments all resolved to one selector would prove nothing.
    const pool = [document.querySelector('#cta'), ...document.querySelectorAll('h1,h2,p,button,a')]
      .filter(Boolean);
    const comments = texts.map((raw, i) => {
      const off = raw.startsWith('offpage:');
      const text = off ? raw.slice('offpage:'.length) : raw;
      const el = pool[i % pool.length];
      const r = el.getBoundingClientRect();
      return {
        n: i + 1, comment: text,
        url: off ? 'http://example.invalid/gone.html' : location.href,
        onCurrentPage: !off,
        selector: el.id ? '#' + el.id : el.tagName.toLowerCase() + ':nth-of-type(' + (i + 1) + ')',
        xpath: '', elementHTML: el.outerHTML, elementText: (el.textContent || '').trim(),
        reactSource: null,
        rect: { x: r.x, y: r.y, width: r.width, height: r.height,
                scrollX: scrollX, scrollY: scrollY, dpr: devicePixelRatio },
      };
    });
    window.__synthComment(JSON.stringify({
      type: 'commentBatch', url: location.href, title: document.title,
      viewport: { width: innerWidth, height: innerHeight, dpr: devicePixelRatio },
      comments,
    }));
  }, comments);
  console.log('SENT');
  await b.close();
})().catch(e => { console.log('ERR ' + e.message); process.exit(4); });
