// Drive the REAL comment overlay on the live page — trusted clicks and typing, its own queue.
//
//   node comment_overlay_drive.js <port> <needle> queue "text one" "text two"
//   node comment_overlay_drive.js <port> <needle> send  "text one" "text two"
//
// `queue` leaves the comments standing so the host's pending count can be asserted and the
// send driven by the app's own chord; `send` clicks the island's Send button instead. Prints
// QUEUED <n> / SENT <n>, or ERR.
//
// The stand-in in comment_click.js fires the binding directly, which exercises only the host.
// This one goes through the overlay: pins, composer, ⏎-queues, island — so a break in the
// page half fails the gate too.
const path = require('path'), os = require('os');
const PW = path.join(os.homedir(), 'Library/Application Support/Synth/browser-mcp/node_modules/playwright-core');
const { chromium } = require(PW);
const [port, needle, mode, ...texts] = process.argv.slice(2);

(async () => {
  const b = await chromium.connectOverCDP(`http://127.0.0.1:${port}`);
  const pages = b.contexts().flatMap(c => c.pages());
  const page = pages.find(p => p.url().includes(needle)) || pages[0];
  if (!page) { console.log('NOPAGE'); process.exit(2); }
  if (!await page.evaluate(() => !!document.querySelector('[data-synth-comment-overlay]'))) {
    console.log('NOOVERLAY'); process.exit(3);
  }

  // Distinct targets, each big enough to click reliably; the overlay's own hit-test decides
  // what a click lands on, which is the point of driving it this way.
  const targets = await page.evaluate((want) => {
    const seen = new Set(), out = [];
    for (const el of document.querySelectorAll('h1,h2,p,button,a,#cta')) {
      const r = el.getBoundingClientRect();
      if (r.width < 24 || r.height < 12 || r.top < 0) continue;
      const key = Math.round(r.top) + ':' + Math.round(r.left);
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({ x: r.left + r.width / 2, y: r.top + Math.min(r.height / 2, 12) });
      if (out.length >= want) break;
    }
    return out;
  }, texts.length);
  if (targets.length < texts.length) { console.log('NOTARGETS ' + targets.length); process.exit(4); }

  for (let i = 0; i < texts.length; i++) {
    await page.mouse.click(targets[i].x, targets[i].y);
    await page.waitForTimeout(400);
    await page.keyboard.type(texts[i]);
    await page.waitForTimeout(150);
    await page.keyboard.press('Enter');       // queues, never sends
    await page.waitForTimeout(300);
  }

  if (mode === 'send') {
    // the island's own Send button, inside the closed shadow root
    const clicked = await page.evaluate(() => {
      const host = document.querySelector('[data-synth-comment-overlay]');
      const sr = host && host.shadowRoot;
      const btn = sr && sr.querySelector('.btn--pri');
      if (!btn) return false;
      btn.click();
      return true;
    });
    if (!clicked) { console.log('NOSEND'); process.exit(5); }
    await page.waitForTimeout(600);
    console.log('SENT ' + texts.length);
  } else {
    console.log('QUEUED ' + texts.length);
  }
  await b.close();
})().catch(e => { console.log('ERR ' + e.message); process.exit(6); });
