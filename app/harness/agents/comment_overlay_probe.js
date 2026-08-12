// What the overlay is actually showing on the live page, from *inside* its closed shadow root.
//
//   node comment_overlay_probe.js <port> <needle> [reload|click]
//
// The host never passes debug, so there is no introspection hook on a real build and the page's
// own scripts cannot reach a closed shadow root. CDP's DOM domain pierces it, which is the only
// way a gate can assert what the user is looking at. `reload` reloads the page first — the dev
// server's own move when an agent edits the code — and waits for the overlay to come back.
// `click` clicks the page's own button and reports whether the page got it, which is how a gate
// tells a parked overlay (the page is the user's again) from a live one (the veil takes the click).
//
// Prints one JSON line: { host, pins, parked, islandText, pageClicks }.
const path = require('path'), os = require('os');
const PW = path.join(os.homedir(), 'Library/Application Support/Synth/browser-mcp/node_modules/playwright-core');
const { chromium } = require(PW);
const [port, needle, mode] = process.argv.slice(2);

const findHost = (node, out = []) => {
  const attrs = node.attributes || [];
  for (let i = 0; i < attrs.length; i += 2) {
    if (attrs[i] === 'data-synth-comment-overlay') out.push(node);
  }
  for (const kid of node.children || []) findHost(kid, out);
  for (const sr of node.shadowRoots || []) findHost(sr, out);
  if (node.contentDocument) findHost(node.contentDocument, out);
  return out;
};

(async () => {
  const b = await chromium.connectOverCDP(`http://127.0.0.1:${port}`);
  const ctx = b.contexts()[0];
  const page = ctx.pages().find((p) => p.url().includes(needle)) || ctx.pages()[0];
  if (!page) { console.log(JSON.stringify({ error: 'NOPAGE' })); process.exit(2); }

  if (mode === 'reload') {
    await page.reload({ waitUntil: 'load' });
    await page.waitForTimeout(1200);          // the injected script mounts on the new document
  }
  // A page-side counter, to prove whether the veil is still swallowing clicks.
  await page.evaluate(() => {
    if (window.__probeWired) return;
    window.__probeWired = true;
    window.__probeClicks = 0;
    document.addEventListener('click', () => { window.__probeClicks++; });
  });

  // Bare page, clear of both the pins (which stay interactive while parked) and the island.
  if (mode === 'click') {
    const y = await page.evaluate(() => Math.round(window.innerHeight / 2));
    await page.mouse.click(24, y);
    await page.waitForTimeout(250);
  }

  const cdp = await ctx.newCDPSession(page);
  await cdp.send('DOM.enable');
  const doc = await cdp.send('DOM.getDocument', { depth: -1, pierce: true });
  const hosts = findHost(doc.root);
  let html = '';
  if (hosts.length && (hosts[0].shadowRoots || []).length) {
    html = (await cdp.send('DOM.getOuterHTML', { nodeId: hosts[0].shadowRoots[0].nodeId })).outerHTML;
  }
  // The stylesheet names every class the overlay has, so it goes before anything is looked up in
  // here — otherwise the CSS answers for the UI.
  html = html.replace(/<style[\s\S]*?<\/style>/g, '');
  const text = html.replace(/<svg[\s\S]*?<\/svg>/g, '')
                   .replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
  const island = (html.match(/class="island[^"]*"/) || [''])[0];
  console.log(JSON.stringify({
    host: hosts.length,
    pins: (html.match(/class="pin[^"]*"/g) || []).length,
    parked: island.includes('is-parked'),
    islandText: text.slice(0, 240),
    pageClicks: await page.evaluate(() => window.__probeClicks)
  }));
  await b.close();
})().catch((e) => { console.log(JSON.stringify({ error: String(e && e.message || e) })); process.exit(3); });
