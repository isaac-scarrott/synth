// Leave a comment on each element the scene file names, through the overlay's own UI.
//
//   node comments.js <cdp-port> <url-needle> '<json array of {at, text}>'
//   PLAYWRIGHT=<path to playwright-core>
//
// The pins, the composer and the island are the product's — this only supplies the pointer and
// the words. ⏎ queues a comment and never sends it, which is the state the figure wants: the
// island standing with its count, before anything has gone to an agent.
const { chromium } = require(process.env.PLAYWRIGHT);
const [port, needle, payload] = process.argv.slice(2);
const wanted = JSON.parse(payload);

(async () => {
  const b = await chromium.connectOverCDP(`http://127.0.0.1:${port}`);
  const page = b.contexts().flatMap(c => c.pages()).find(p => p.url().includes(needle));
  if (!page) { console.log('NOPAGE'); process.exit(2); }
  if (!await page.evaluate(() => !!document.querySelector('[data-synth-comment-overlay]'))) {
    console.log('NOOVERLAY'); process.exit(3);
  }
  for (const { at, text } of wanted) {
    // Scroll the element into view before measuring it. A rect taken while the element is below
    // the fold has a viewport y the pointer can never reach, so the click lands on whatever is
    // actually at those coordinates — or nowhere — and the comment is silently never left.
    const box = await page.evaluate((sel) => {
      const el = document.querySelector(sel);
      if (!el) return null;
      el.scrollIntoView({ block: 'center', behavior: 'instant' });
      const r = el.getBoundingClientRect();
      return { x: r.left + r.width / 2, y: r.top + Math.min(r.height / 2, 14) };
    }, at);
    await page.waitForTimeout(250);
    if (!box) { console.log('NOELEMENT ' + at); process.exit(4); }
    await page.mouse.click(box.x, box.y);
    await page.waitForTimeout(450);
    await page.keyboard.type(text);
    await page.waitForTimeout(150);
    await page.keyboard.press('Enter');   // queues; the island keeps it
    await page.waitForTimeout(350);
  }
  // Back to the top, so the figure shows the page's own first screen rather than wherever the
  // last pin happened to leave it.
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'instant' }));
  await page.waitForTimeout(400);
  console.log('QUEUED ' + wanted.length);
  await b.close();
})().catch(e => { console.log('ERR ' + e.message); process.exit(5); });
