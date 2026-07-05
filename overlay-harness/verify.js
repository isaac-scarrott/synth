/*
 * Headless verification of CommentOverlay.js against harness.html + react-page.html.
 *
 * Usage:
 *   PW_CORE=/path/to/node_modules/playwright-core \
 *   CHROME_EXEC="/path/to/Google Chrome for Testing" \
 *   SHOT_DIR=/tmp/shots \
 *   node overlay-harness/verify.js
 *
 * PW_CORE defaults to a plain `playwright-core` require; CHROME_EXEC defaults to the
 * ms-playwright chromium-1228 cache path; SHOT_DIR defaults to overlay-harness/shots.
 */
const os = require('os');
const path = require('path');
const fs = require('fs');

const { chromium } = require(process.env.PW_CORE || 'playwright-core');
const EXEC = process.env.CHROME_EXEC || path.join(
  os.homedir(),
  'Library/Caches/ms-playwright/chromium-1228/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing'
);
const HARNESS = path.join(__dirname, 'harness.html');
const REACT_PAGE = path.join(__dirname, 'react-page.html');
const SHOT_DIR = process.env.SHOT_DIR || path.join(__dirname, 'shots');

const results = [];
const check = (name, ok, extra) => results.push(`${ok ? 'PASS' : 'FAIL'} ${name}${extra ? ' — ' + extra : ''}`);
const approx = (a, b, tol = 3) => Math.abs(a - b) <= tol;

(async () => {
  fs.mkdirSync(SHOT_DIR, { recursive: true });
  const browser = await chromium.launch({ executablePath: EXEC, headless: true });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  const pageErrors = [];
  page.on('pageerror', (e) => pageErrors.push('pageerror: ' + e.message));
  page.on('console', (m) => { if (m.type() === 'error') pageErrors.push('console.error: ' + m.text()); });

  const dbg = () => page.evaluate(() => {
    const d = window.__synthOverlayDebug;
    return d ? {
      state: d.state, hoveredTag: d.hoveredTag, highlightRect: d.highlightRect,
      cardOpen: d.cardOpen, cardRect: d.cardRect, sentToastVisible: d.sentToastVisible,
      pendingSendCount: d.pendingSendCount
    } : null;
  });
  const hostCount = () => page.evaluate(() => document.querySelectorAll('[data-synth-comment-overlay]').length);
  const received = () => page.evaluate(() => window.__synthReceived.map((j) => JSON.parse(j)));

  await page.goto('file://' + HARNESS);
  await page.waitForTimeout(200);

  // ---- enter via API (as the host will call it) --------------------------------
  await page.evaluate(() => window.__synthOverlay.enter({ targetLabel: 'claude · fix/browser-header', debug: true }));
  check('enter mounts exactly one shadow host', (await hostCount()) === 1);

  // ---- hover: highlight glued to the element -----------------------------------
  const deepBox = await page.locator('#deep-button').boundingBox();
  await page.mouse.move(deepBox.x + deepBox.width / 2, deepBox.y + deepBox.height / 2);
  await page.waitForTimeout(120);
  let d = await dbg();
  check('pick mode hovers the deep button', d.state === 'pick' && d.hoveredTag === 'button');
  check('highlight tracks element rect',
    d.highlightRect && approx(d.highlightRect.x, deepBox.x) && approx(d.highlightRect.y, deepBox.y) &&
    approx(d.highlightRect.width, deepBox.width) && approx(d.highlightRect.height, deepBox.height),
    JSON.stringify(d.highlightRect));
  check('veil intercepts hit-testing (elementFromPoint is the overlay host)',
    await page.evaluate(([x, y]) => {
      const el = document.elementFromPoint(x, y);
      return el && el.hasAttribute('data-synth-comment-overlay');
    }, [deepBox.x + 5, deepBox.y + 5]));
  await page.screenshot({ path: path.join(SHOT_DIR, 'overlay-hover.png') });

  // hover side effects suppressed: move across the hover-sensitive element
  const hoverBox = await page.locator('#hover-me').boundingBox();
  await page.mouse.move(hoverBox.x + 10, hoverBox.y + 10, { steps: 4 });
  await page.waitForTimeout(80);
  check('page mouseenter handler did not fire during pick',
    (await page.evaluate(() => window.__clickCounts.hoverEnter)) === 0);

  // ---- click: freeze + card, page handler suppressed ---------------------------
  await page.mouse.move(deepBox.x + deepBox.width / 2, deepBox.y + deepBox.height / 2);
  await page.waitForTimeout(60);
  await page.mouse.click(deepBox.x + deepBox.width / 2, deepBox.y + deepBox.height / 2);
  await page.waitForTimeout(120);
  d = await dbg();
  check('click opens the comment card', d.cardOpen && d.cardRect && d.cardRect.width > 200);
  check('card stays inside the viewport',
    d.cardRect.x >= 0 && d.cardRect.y >= 0 &&
    d.cardRect.x + d.cardRect.width <= 1280 && d.cardRect.y + d.cardRect.height <= 800,
    JSON.stringify(d.cardRect));
  const counts = await page.evaluate(() => window.__clickCounts);
  check('page click handlers did not fire (button + document)', counts.deep === 0 && counts.docClicks === 0,
    JSON.stringify(counts));

  // ---- type into autofocused textarea, page shortcuts must not see keys ---------
  await page.evaluate(() => { window.__pageKeys = 0; window.addEventListener('keydown', () => window.__pageKeys++); });
  await page.keyboard.type('Make this button purple and 2px larger');
  await page.screenshot({ path: path.join(SHOT_DIR, 'overlay-card.png') });
  check('typed keys do not reach page keydown handlers',
    (await page.evaluate(() => window.__pageKeys)) === 0);

  // ---- submit via ⌘↩ -------------------------------------------------------------
  await page.keyboard.press('Meta+Enter');
  await page.waitForTimeout(120);
  d = await dbg();
  check('Sent toast shows after submit', d.sentToastVisible === true);
  await page.screenshot({ path: path.join(SHOT_DIR, 'overlay-sent.png') });
  await page.waitForTimeout(1000);
  d = await dbg();
  check('card returns to pick mode after toast', d.state === 'pick' && !d.cardOpen);

  // ---- payload contract ----------------------------------------------------------
  let msgs = await received();
  check('exactly one payload received', msgs.length === 1);
  const p = msgs[0];
  const keys = Object.keys(p);
  const expectedKeys = ['type', 'url', 'title', 'selector', 'xpath', 'rect', 'elementHTML', 'elementText', 'comment', 'reactSource'];
  check('payload has exactly the contract keys in order', JSON.stringify(keys) === JSON.stringify(expectedKeys), JSON.stringify(keys));
  check('type/url/title correct',
    p.type === 'comment' && p.url.startsWith('file://') && p.title === 'Synth Comment Overlay — Harness');
  check('selector is unique and resolves to the clicked element',
    await page.evaluate((sel) => {
      const found = document.querySelectorAll(sel);
      return found.length === 1 && found[0] === document.getElementById('deep-button');
    }, p.selector), p.selector);
  check('xpath resolves to the clicked element',
    await page.evaluate((xp) => {
      const r = document.evaluate(xp, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
      return r.singleNodeValue === document.getElementById('deep-button');
    }, p.xpath), p.xpath);
  check('rect matches the element and carries scroll + dpr',
    approx(p.rect.x, deepBox.x) && approx(p.rect.y, deepBox.y) &&
    approx(p.rect.width, deepBox.width) && approx(p.rect.height, deepBox.height) &&
    typeof p.rect.scrollX === 'number' && typeof p.rect.scrollY === 'number' && p.rect.dpr >= 1,
    JSON.stringify(p.rect));
  check('elementHTML present and capped', p.elementHTML.includes('deep-button') && p.elementHTML.length <= 2000);
  check('elementText present and capped', p.elementText.includes('Deep button') && p.elementText.length <= 500);
  check('comment carried verbatim', p.comment === 'Make this button purple and 2px larger');
  check('reactSource is null on a non-React page', p.reactSource === null);

  // ---- nth-of-type path for a twin element (no id) --------------------------------
  const twinBox = await page.locator('p.twin >> nth=1').boundingBox();
  await page.mouse.click(twinBox.x + 10, twinBox.y + 8);
  await page.waitForTimeout(100);
  await page.keyboard.type('twin comment');
  await page.keyboard.press('Meta+Enter');
  await page.waitForTimeout(1100);
  msgs = await received();
  const twin = msgs[msgs.length - 1];
  check('twin selector unique + correct element',
    await page.evaluate((sel) => {
      const found = document.querySelectorAll(sel);
      return found.length === 1 && found[0] === document.querySelectorAll('p.twin')[1];
    }, twin.selector), twin.selector);

  // ---- Esc cancels the card back to pick, nothing sent ------------------------------
  const before = (await received()).length;
  await page.mouse.click(deepBox.x + 5, deepBox.y + 5);
  await page.waitForTimeout(80);
  check('card reopened for cancel test', (await dbg()).cardOpen);
  await page.keyboard.press('Escape');
  await page.waitForTimeout(80);
  d = await dbg();
  check('Esc cancels card back to pick mode', d.state === 'pick' && !d.cardOpen);
  check('cancel sends nothing', (await received()).length === before);

  // ---- scroll keeps the highlight glued ---------------------------------------------
  await page.mouse.move(640, 400);
  await page.evaluate(() => window.scrollTo(0, 600));
  await page.waitForTimeout(150);
  d = await dbg();
  if (d.hoveredTag) {
    const glued = await page.evaluate((hr) => {
      const el = document.elementsFromPoint(640, 400).find((e) => !e.hasAttribute || !e.hasAttribute('data-synth-comment-overlay'));
      if (!el) return false;
      const r = el.getBoundingClientRect();
      return Math.abs(r.x - hr.x) <= 3 && Math.abs(r.y - hr.y) <= 3;
    }, d.highlightRect);
    check('highlight glued to hovered element after scroll', glued, JSON.stringify(d.highlightRect));
  } else {
    check('highlight glued to hovered element after scroll', false, 'no hovered element after scroll');
  }
  // scroll the way-down button into view and pick it while scrolled
  await page.evaluate(() => document.getElementById('way-down').scrollIntoView({ block: 'center' }));
  await page.waitForTimeout(150);
  const scrollYNow = await page.evaluate(() => window.scrollY);
  const wayBox = await page.evaluate(() => {
    const r = document.getElementById('way-down').getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: r.height };
  });
  await page.mouse.click(wayBox.x + 10, wayBox.y + 10);
  await page.waitForTimeout(100);
  await page.keyboard.type('scrolled pick');
  await page.keyboard.press('Meta+Enter');
  await page.waitForTimeout(1100);
  msgs = await received();
  const scrolled = msgs[msgs.length - 1];
  check('scrolled pick reports scrollY and viewport-relative rect',
    scrollYNow > 0 && scrolled.rect.scrollY === scrollYNow && approx(scrolled.rect.y, wayBox.y) &&
    scrolled.selector === '#way-down',
    JSON.stringify(scrolled.rect) + ' scrollYNow=' + scrollYNow);
  check('way-down page handler suppressed', (await page.evaluate(() => window.__clickCounts.wayDown)) === 0);
  await page.evaluate(() => window.scrollTo(0, 0));

  // ---- zero-size element hover does not crash ----------------------------------------
  const zeroPos = await page.evaluate(() => {
    const r = document.querySelector('.zero-size').getBoundingClientRect();
    return { x: r.x, y: r.y };
  });
  await page.mouse.move(zeroPos.x, zeroPos.y);
  await page.waitForTimeout(80);
  check('zero-size region hover does not crash', (await dbg()).state === 'pick');

  // ---- Esc in pick mode exits and sends exitMode --------------------------------------
  const beforeExit = (await received()).length;
  await page.keyboard.press('Escape');
  await page.waitForTimeout(100);
  msgs = await received();
  const exitMsg = msgs[msgs.length - 1];
  check('Esc in pick mode sends exitMode', msgs.length === beforeExit + 1 && exitMsg.type === 'exitMode');
  check('exitMode carries url/title and empty fields',
    exitMsg.url.startsWith('file://') && exitMsg.title.length > 0 && exitMsg.selector === '' &&
    exitMsg.xpath === '' && exitMsg.comment === '' && exitMsg.reactSource === null &&
    exitMsg.rect.width === 0 && exitMsg.rect.height === 0);
  check('Esc exit unmounts the shadow host', (await hostCount()) === 0);

  // ---- enter/exit/enter cycles leave nothing behind ------------------------------------
  for (let i = 0; i < 3; i++) {
    await page.evaluate(() => window.__synthOverlay.enter({ targetLabel: 'cycle', debug: true }));
    await page.evaluate(() => window.__synthOverlay.exit());
  }
  check('3 enter/exit cycles leave zero shadow hosts', (await hostCount()) === 0);
  await page.evaluate(() => window.__synthOverlay.enter({ targetLabel: 'cycle', debug: true }));
  await page.evaluate(() => window.__synthOverlay.enter({ targetLabel: 'cycle2', debug: true })); // idempotent enter
  check('double enter still one host', (await hostCount()) === 1);
  await page.evaluate(() => window.__synthOverlay.exit());
  await page.evaluate(() => window.__synthOverlay.exit()); // idempotent exit
  check('double exit leaves zero hosts, no error', (await hostCount()) === 0);

  // after exit, page handlers work again (no leaked suppressors)
  await page.click('#deep-button');
  check('page handlers restored after exit', (await page.evaluate(() => window.__clickCounts.deep)) === 1);

  // ---- binding-missing buffering ---------------------------------------------------------
  await page.evaluate(() => {
    window.__realBinding = window.__synthComment;
    delete window.__synthComment;
    window.__synthOverlay.enter({ targetLabel: 'buffered', debug: true });
  });
  await page.mouse.click(deepBox.x + deepBox.width / 2, deepBox.y + deepBox.height / 2);
  await page.waitForTimeout(100);
  await page.keyboard.type('buffered comment');
  await page.keyboard.press('Meta+Enter');
  await page.waitForTimeout(150);
  const bufBefore = (await received()).length;
  d = await dbg();
  check('payload buffered while binding missing', d.pendingSendCount === 1 && bufBefore === (await received()).length);
  await page.evaluate(() => { window.__synthComment = window.__realBinding; });
  await page.waitForTimeout(500);
  msgs = await received();
  check('buffered payload flushed once binding appears',
    msgs.length === bufBefore + 1 && msgs[msgs.length - 1].comment === 'buffered comment');
  await page.waitForTimeout(900);
  await page.evaluate(() => window.__synthOverlay.exit());
  await page.waitForTimeout(100);

  check('no page errors on harness', pageErrors.length === 0, pageErrors.join(' | '));

  // ================================ React page ============================================
  const rp = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  const rpErrors = [];
  rp.on('pageerror', (e) => rpErrors.push('pageerror: ' + e.message));
  await rp.goto('file://' + REACT_PAGE);
  await rp.waitForTimeout(300);
  await rp.evaluate(() => window.__synthOverlay.enter({ targetLabel: 'claude · feat/react-panel', debug: true }));

  const rBtn = await rp.locator('#react-button').boundingBox();
  await rp.mouse.move(rBtn.x + 10, rBtn.y + 10);
  await rp.waitForTimeout(80);
  await rp.mouse.click(rBtn.x + 10, rBtn.y + 10);
  await rp.waitForTimeout(100);
  await rp.keyboard.type('rename this to Save');
  await rp.keyboard.press('Meta+Enter');
  await rp.waitForTimeout(300);
  let rMsgs = await rp.evaluate(() => window.__synthReceived.map((j) => JSON.parse(j)));
  const rPayload = rMsgs[rMsgs.length - 1];
  check('react button payload has reactSource file + line',
    rPayload.reactSource && rPayload.reactSource.fileName === '/app/src/components/Panel.jsx' &&
    rPayload.reactSource.lineNumber === 14 && rPayload.reactSource.columnNumber === 7,
    JSON.stringify(rPayload.reactSource));
  check('react click handler suppressed during pick', (await rp.evaluate(() => window.__reactClicks || 0)) === 0);
  await rp.waitForTimeout(800);

  // leaf without own __source: owner-chain fallback
  const rLeaf = await rp.locator('#react-leaf').boundingBox();
  await rp.mouse.click(rLeaf.x + 5, rLeaf.y + 5);
  await rp.waitForTimeout(100);
  await rp.keyboard.type('leaf');
  await rp.keyboard.press('Meta+Enter');
  await rp.waitForTimeout(300);
  rMsgs = await rp.evaluate(() => window.__synthReceived.map((j) => JSON.parse(j)));
  const leafPayload = rMsgs[rMsgs.length - 1];
  check('owner-chain fallback finds the component source',
    leafPayload.reactSource && leafPayload.reactSource.lineNumber === 15,
    JSON.stringify(leafPayload.reactSource));
  await rp.screenshot({ path: path.join(SHOT_DIR, 'overlay-react.png') });
  check('no page errors on react page', rpErrors.length === 0, rpErrors.join(' | '));

  console.log(results.join('\n'));
  const fail = results.some((r) => r.startsWith('FAIL'));
  console.log(fail ? 'RESULT: FAIL' : 'RESULT: PASS');
  await browser.close();
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('HARNESS ERROR', e); process.exit(2); });
