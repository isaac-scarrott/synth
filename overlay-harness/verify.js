/*
 * Headless verification of CommentOverlay.js (batch flow) against harness.html + react-page.html.
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
const OVERLAY_JS = path.join(__dirname, '..', 'app', 'Sources', 'Synth', 'Resources', 'CommentOverlay.js');
const SHOT_DIR = process.env.SHOT_DIR || path.join(__dirname, 'shots');

const LABEL = 'claude · fix/browser-header';

const results = [];
const check = (name, ok, extra) => results.push(`${ok ? 'PASS' : 'FAIL'} ${name}${extra ? ' — ' + extra : ''}`);
const approx = (a, b, tol = 3) => Math.abs(a - b) <= tol;

/* Everything the debug hook exposes that survives JSON. `root` is a live ShadowRoot, so it
   is only ever touched inside page.evaluate — never returned. */
const dbgOf = (pg) => pg.evaluate(() => {
  const d = window.__synthOverlayDebug;
  return d ? {
    state: d.state, hoveredTag: d.hoveredTag, highlightRect: d.highlightRect,
    cardOpen: d.cardOpen, cardRect: d.cardRect, listOpen: d.listOpen,
    sending: d.sending, sentToastVisible: d.sentToastVisible,
    queuedCount: d.queuedCount, islandText: d.islandText, comments: d.comments,
    pendingSendCount: d.pendingSendCount
  } : null;
});
const msgsOf = (pg) => pg.evaluate(() => window.__synthReceived.map((j) => JSON.parse(j)));
const hostsOf = (pg) => pg.evaluate(() => document.querySelectorAll('[data-synth-comment-overlay]').length);

/* The pins, as actually rendered — numeral, draft-ness and on-screen centre. */
const pinsOf = (pg) => pg.evaluate(() => {
  const root = window.__synthOverlayDebug.root;
  return Array.prototype.map.call(root.querySelectorAll('.pin'), (p) => {
    const r = p.getBoundingClientRect();
    return {
      id: Number(p.getAttribute('data-id')), numeral: p.textContent,
      draft: p.classList.contains('is-draft'),
      cx: r.left + r.width / 2, cy: r.top + r.height / 2
    };
  });
});

/* The island's queue list, as actually rendered. */
const rowsOf = (pg) => pg.evaluate(() => {
  const root = window.__synthOverlayDebug.root;
  return Array.prototype.map.call(root.querySelectorAll('.row'), (r) => ({
    id: Number(r.getAttribute('data-id')),
    no: r.querySelector('.row__no').textContent,
    text: r.querySelector('.row__txt').textContent,
    selector: r.querySelector('.row__sel').textContent
  }));
});

/* Every rendered pin against its target element's live box: dx/dy is how far the pin has
   drifted off the fraction of the element it was pinned to. */
const pinDriftOf = (pg) => pg.evaluate(() => {
  const d = window.__synthOverlayDebug, root = d.root;
  return d.comments.map((c) => {
    const pin = root.querySelector('.pin[data-id="' + c.id + '"]');
    const el = document.querySelector(c.selector);
    if (!pin || !el) return { n: c.n, dx: NaN, dy: NaN, why: pin ? 'no element' : 'no pin' };
    const p = pin.getBoundingClientRect(), r = el.getBoundingClientRect();
    return {
      n: c.n,
      dx: (p.left + p.width / 2) - (r.left + c.fx * r.width),
      dy: (p.top + p.height / 2) - (r.top + c.fy * r.height)
    };
  });
});
const locked = (drift, tol = 1) => drift.length > 0 &&
  drift.every((d) => Math.abs(d.dx) <= tol && Math.abs(d.dy) <= tol);

/* Pins ride the page in the overlay's own rAF loop, so geometry is only meaningful after it
   has ticked. Wall-clock waits are not enough: headless only produces frames on demand. */
const settle = (pg, frames = 3) => pg.evaluate((n) => new Promise((done) => {
  let i = 0;
  (function step() { requestAnimationFrame(++i >= n ? done : step); })();
}), frames);

/* Click something inside the closed shadow root by CSS selector. */
const shadowClick = (pg, sel) => pg.evaluate((s) => {
  const el = window.__synthOverlayDebug.root.querySelector(s);
  if (!el) throw new Error('no shadow element for ' + s);
  el.click();
}, sel);

(async () => {
  fs.mkdirSync(SHOT_DIR, { recursive: true });
  const browser = await chromium.launch({ executablePath: EXEC, headless: true });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  const pageErrors = [];
  page.on('pageerror', (e) => pageErrors.push('pageerror: ' + e.message));
  page.on('console', (m) => { if (m.type() === 'error') pageErrors.push('console.error: ' + m.text()); });

  await page.goto('file://' + HARNESS);
  await page.waitForTimeout(200);

  // ---- enter via API (as the host will call it) --------------------------------
  await page.evaluate((label) => window.__synthOverlay.enter({ targetLabel: label, debug: true }), LABEL);
  check('enter mounts exactly one shadow host', (await hostsOf(page)) === 1);
  check('shadow root is closed to the page',
    await page.evaluate(() => document.querySelector('[data-synth-comment-overlay]').shadowRoot === null));
  let d = await dbgOf(page);
  check('empty island states the mode instead of a dead zero',
    d.queuedCount === 0 && d.islandText.includes('Click anything to comment') && d.islandText.includes(LABEL),
    d.islandText);
  check('entering alone emits nothing', (await msgsOf(page)).length === 0);

  // ---- hover: highlight glued to the element -----------------------------------
  const deepBox = await page.locator('#deep-button').boundingBox();
  await page.mouse.move(deepBox.x + deepBox.width / 2, deepBox.y + deepBox.height / 2);
  await page.waitForTimeout(120);
  d = await dbgOf(page);
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

  // ---- comment 1: click drops a draft pin, page handlers stay silent -------------
  await page.mouse.move(deepBox.x + deepBox.width / 2, deepBox.y + deepBox.height / 2);
  await page.waitForTimeout(60);
  await page.mouse.click(deepBox.x + deepBox.width / 2, deepBox.y + deepBox.height / 2);
  await page.waitForTimeout(150);
  d = await dbgOf(page);
  check('click opens the composer', d.cardOpen && d.cardRect && d.cardRect.width > 200);
  check('composer stays inside the viewport',
    d.cardRect.x >= 0 && d.cardRect.y >= 0 &&
    d.cardRect.x + d.cardRect.width <= 1280 && d.cardRect.y + d.cardRect.height <= 800,
    JSON.stringify(d.cardRect));
  let pins = await pinsOf(page);
  check('a numbered pin lands where the click did, hollow until it has words',
    pins.length === 1 && pins[0].numeral === '1' && pins[0].draft === true &&
    approx(pins[0].cx, deepBox.x + deepBox.width / 2) && approx(pins[0].cy, deepBox.y + deepBox.height / 2),
    JSON.stringify(pins));
  check('an unwritten composer does not count', d.queuedCount === 0 && (await msgsOf(page)).length === 0);
  const counts = await page.evaluate(() => window.__clickCounts);
  check('page click handlers did not fire (button + document)', counts.deep === 0 && counts.docClicks === 0,
    JSON.stringify(counts));

  // ---- type: keys stay in the composer, first character joins the queue ----------
  await page.evaluate(() => { window.__pageKeys = 0; window.addEventListener('keydown', () => window.__pageKeys++); });
  await page.keyboard.type('Make this button purple');
  await page.keyboard.press('Shift+Enter');
  await page.keyboard.type('and 2px larger');
  const C1 = 'Make this button purple\nand 2px larger';
  await page.waitForTimeout(80);
  check('typed keys do not reach page keydown handlers',
    (await page.evaluate(() => window.__pageKeys)) === 0);
  d = await dbgOf(page);
  check('Shift+⏎ is a newline, not a queue',
    d.cardOpen && d.comments.length === 1 && d.comments[0].text === C1, JSON.stringify(d.comments[0]));
  check('first character queues the comment (batchCount 1)',
    d.queuedCount === 1 && JSON.stringify(await msgsOf(page)) === JSON.stringify([{ type: 'batchCount', n: 1 }]),
    JSON.stringify(await msgsOf(page)));
  pins = await pinsOf(page);
  check('written pin is no longer a draft', pins.length === 1 && pins[0].draft === false);
  await page.screenshot({ path: path.join(SHOT_DIR, 'overlay-composer.png') });

  // ---- ⏎ queues and leaves the batch open ----------------------------------------
  await page.keyboard.press('Enter');
  await page.waitForTimeout(120);
  d = await dbgOf(page);
  check('⏎ closes the composer without sending',
    d.state === 'pick' && !d.cardOpen && d.queuedCount === 1 &&
    (await msgsOf(page)).length === 1);

  // ---- comment 2 on a twin paragraph (nth-of-type selector) -----------------------
  const twinBox = await page.locator('p.twin >> nth=1').boundingBox();
  const twinPoint = { x: twinBox.x + 10, y: twinBox.y + 8 };
  await page.mouse.click(twinPoint.x, twinPoint.y);
  await page.waitForTimeout(150);
  const C2 = 'these two read the same';
  await page.keyboard.type(C2);
  await page.keyboard.press('Enter');
  await page.waitForTimeout(120);

  // ==== ASSERTION 1: two comments queue, nothing is delivered =======================
  d = await dbgOf(page);
  let msgs = await msgsOf(page);
  check('two comments queue with no commentBatch — only batchCount 1 then 2',
    d.queuedCount === 2 &&
    JSON.stringify(msgs) === JSON.stringify([{ type: 'batchCount', n: 1 }, { type: 'batchCount', n: 2 }]),
    JSON.stringify(msgs));
  check('island shows the queue, the target and the single send',
    d.islandText.includes('2') && d.islandText.includes('comments') &&
    d.islandText.includes(LABEL) && d.islandText.includes('Send 2'), d.islandText);
  check('twin selector is unique and correct before widening',
    await page.evaluate((sel) => {
      const f = document.querySelectorAll(sel);
      return f.length === 1 && f[0] === document.querySelectorAll('p.twin')[1];
    }, d.comments[1].selector), d.comments[1].selector);

  // ==== ASSERTION 2: a blank composer never counts and Escape drops it ==============
  const beforeBlank = (await msgsOf(page)).length;
  await page.mouse.click(hoverBox.x + 10, hoverBox.y + 10);
  await page.waitForTimeout(150);
  d = await dbgOf(page);
  let rows = await rowsOf(page);
  pins = await pinsOf(page);
  check('a blank composer holds a pin but does not count or list',
    d.cardOpen && d.comments.length === 3 && pins.length === 3 && pins[2].draft === true &&
    d.queuedCount === 2 && rows.length === 2 && rows.every((r) => r.text.trim().length > 0) &&
    (await msgsOf(page)).length === beforeBlank,
    'queued=' + d.queuedCount + ' rows=' + rows.length);
  await page.keyboard.press('Escape');
  await page.waitForTimeout(150);
  d = await dbgOf(page);
  check('Escape discards the blank composer entirely',
    d.state === 'pick' && !d.cardOpen && d.comments.length === 2 &&
    (await pinsOf(page)).length === 2 && d.queuedCount === 2 &&
    (await msgsOf(page)).length === beforeBlank,
    JSON.stringify(d.comments.map((c) => c.text)));

  // ==== ASSERTION 3: widening re-targets the comment without moving the pin =========
  const pin2Before = (await pinsOf(page)).find((p) => p.numeral === '2');
  await page.mouse.click(pin2Before.cx, pin2Before.cy);
  await page.waitForTimeout(150);
  d = await dbgOf(page);
  check('clicking a pin reopens that comment', d.cardOpen && d.comments[1].text === C2);
  const selBefore = d.comments[1].selector, levelBefore = d.comments[1].level;
  await page.evaluate(() => {
    const root = window.__synthOverlayDebug.root;
    const on = root.querySelector('.crumb__seg.is-on');
    const up = root.querySelector('.crumb__seg[data-level="' + (Number(on.getAttribute('data-level')) - 1) + '"]');
    up.click();
  });
  await page.waitForTimeout(200);
  d = await dbgOf(page);
  const pin2After = (await pinsOf(page)).find((p) => p.numeral === '2');
  const widenedSel = d.comments[1].selector;
  check('breadcrumb widening re-targets the comment to the ancestor',
    d.comments[1].level === levelBefore - 1 && widenedSel !== selBefore &&
    await page.evaluate((sel) => {
      const f = document.querySelectorAll(sel);
      return f.length === 1 && f[0] === document.querySelectorAll('p.twin')[1].parentElement;
    }, widenedSel),
    selBefore + ' → ' + widenedSel);
  check('the pin does not move when the comment widens',
    approx(pin2After.cx, pin2Before.cx, 0.5) && approx(pin2After.cy, pin2Before.cy, 0.5),
    'dx=' + (pin2After.cx - pin2Before.cx).toFixed(3) + ' dy=' + (pin2After.cy - pin2Before.cy).toFixed(3));
  check('the scope outline follows the widened target',
    await page.evaluate((sel) => {
      const box = window.__synthOverlayDebug.root.querySelector('.scope');
      if (!box || box.style.display === 'none') return false;
      const b = box.getBoundingClientRect(), r = document.querySelector(sel).getBoundingClientRect();
      return Math.abs(b.x - (r.x - 1.5)) <= 2 && Math.abs(b.height - r.height) <= 4;
    }, widenedSel));
  await page.keyboard.press('Enter');
  await page.waitForTimeout(120);
  check('widening did not disturb the queue',
    (await dbgOf(page)).queuedCount === 2 && (await msgsOf(page)).length === 2);

  // ==== ASSERTION 4: pins stay locked to their element through scroll and reflow ====
  await settle(page);
  check('pins are locked to their elements at rest', locked(await pinDriftOf(page)),
    JSON.stringify(await pinDriftOf(page)));
  await page.evaluate(() => window.scrollTo(0, 420));
  await settle(page);
  let drift = await pinDriftOf(page);
  check('pins stay locked to their elements after scroll', locked(drift), JSON.stringify(drift));
  // highlight must stay glued to whatever is now under the cursor
  await page.mouse.move(640, 400);
  await page.waitForTimeout(150);
  d = await dbgOf(page);
  check('highlight glued to the hovered element after scroll',
    !!d.hoveredTag && await page.evaluate((hr) => {
      const el = document.elementsFromPoint(640, 400)
        .find((e) => !e.hasAttribute || !e.hasAttribute('data-synth-comment-overlay'));
      if (!el) return false;
      const r = el.getBoundingClientRect();
      return Math.abs(r.x - hr.x) <= 3 && Math.abs(r.y - hr.y) <= 3;
    }, d.highlightRect), JSON.stringify(d.highlightRect));
  // a forced reflow moves the elements under the pins
  await page.evaluate(() => { document.querySelector('main').style.paddingTop = '320px'; });
  await settle(page);
  drift = await pinDriftOf(page);
  check('pins stay locked to their elements through a reflow', locked(drift), JSON.stringify(drift));
  await page.evaluate(() => { document.querySelector('main').style.paddingTop = ''; window.scrollTo(0, 0); });
  await settle(page);
  drift = await pinDriftOf(page);
  check('pins return with their elements when the reflow is undone', locked(drift), JSON.stringify(drift));

  // ---- comment 3: the throwaway that assertion 6 deletes ---------------------------
  const navBox = await page.locator('#nav-link-a').boundingBox();
  await page.mouse.click(navBox.x + navBox.width / 2, navBox.y + navBox.height / 2);
  await page.waitForTimeout(150);
  await page.keyboard.type('delete me');
  await page.keyboard.press('Enter');
  await page.waitForTimeout(120);

  // ---- comment 4: picked while the page is scrolled --------------------------------
  await page.evaluate(() => document.getElementById('way-down').scrollIntoView({ block: 'center' }));
  await page.waitForTimeout(200);
  const scrollYAtPick = await page.evaluate(() => window.scrollY);
  const wayBox = await page.evaluate(() => {
    const r = document.getElementById('way-down').getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: r.height };
  });
  await page.mouse.click(wayBox.x + 10, wayBox.y + 10);
  await page.waitForTimeout(150);
  const C4 = 'this button is stranded down here';
  await page.keyboard.type(C4);
  await page.keyboard.press('Enter');
  await page.waitForTimeout(120);
  check('a pick while scrolled lands on the right element',
    scrollYAtPick > 0 && (await dbgOf(page)).comments[3].selector === '#way-down');
  check('way-down page handler suppressed', (await page.evaluate(() => window.__clickCounts.wayDown)) === 0);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(200);

  msgs = await msgsOf(page);
  check('every queue change is announced (1,2,3,4)',
    JSON.stringify(msgs.map((m) => m.type + ':' + m.n)) ===
    JSON.stringify(['batchCount:1', 'batchCount:2', 'batchCount:3', 'batchCount:4']),
    JSON.stringify(msgs));

  // ==== ASSERTION 6: deleting a row drops the comment and renumbers =================
  await shadowClick(page, '[data-cm="list"]');
  await page.waitForTimeout(120);
  check('the count toggles the queue list', (await dbgOf(page)).listOpen === true);
  rows = await rowsOf(page);
  check('the list is the batch in the order it was left',
    rows.length === 4 && JSON.stringify(rows.map((r) => r.no)) === JSON.stringify(['1', '2', '3', '4']) &&
    rows[2].text === 'delete me' && rows[1].selector === widenedSel,
    JSON.stringify(rows.map((r) => r.no + ':' + r.text)));
  await page.screenshot({ path: path.join(SHOT_DIR, 'overlay-island-list.png') });
  const doomedId = rows[2].id;
  const beforeDelete = (await msgsOf(page)).length;
  await shadowClick(page, '.row[data-id="' + doomedId + '"] .row__del');
  await page.waitForTimeout(300);
  d = await dbgOf(page);
  rows = await rowsOf(page);
  pins = await pinsOf(page);
  msgs = await msgsOf(page);
  check('deleting a row drops that comment and renumbers the rest',
    d.queuedCount === 3 && rows.length === 3 &&
    !rows.some((r) => r.id === doomedId) &&
    JSON.stringify(rows.map((r) => r.no)) === JSON.stringify(['1', '2', '3']) &&
    JSON.stringify(pins.map((p) => p.numeral)) === JSON.stringify(['1', '2', '3']) &&
    rows[2].text === C4,
    JSON.stringify(rows.map((r) => r.no + ':' + r.text)));
  check('deleting a row announces the new count',
    msgs.length === beforeDelete + 1 && msgs[msgs.length - 1].type === 'batchCount' && msgs[msgs.length - 1].n === 3,
    JSON.stringify(msgs[msgs.length - 1]));

  // ==== ASSERTION 5: Send delivers exactly one batch ================================
  const sels = (await dbgOf(page)).comments.map((c) => c.selector);
  const live = await page.evaluate((ss) => ({
    scrollX: window.scrollX, scrollY: window.scrollY, dpr: window.devicePixelRatio,
    width: window.innerWidth, height: window.innerHeight,
    rects: ss.map((s) => {
      const r = document.querySelector(s).getBoundingClientRect();
      return { x: r.x, y: r.y, width: r.width, height: r.height };
    })
  }), sels);
  const pinNumerals = (await pinsOf(page)).map((p) => p.numeral);
  const beforeSend = (await msgsOf(page)).length;
  await shadowClick(page, '[data-cm="send"]');
  await page.waitForTimeout(200);
  msgs = await msgsOf(page);
  const batches = msgs.filter((m) => m.type === 'commentBatch');
  check('Send emits exactly one commentBatch', batches.length === 1 && msgs.length === beforeSend + 2,
    JSON.stringify(msgs.slice(beforeSend).map((m) => m.type)));
  check('the batch drops back to a zero count',
    msgs[msgs.length - 1].type === 'batchCount' && msgs[msgs.length - 1].n === 0);
  const batch = batches[0];
  check('batch envelope has exactly the contract keys in order',
    JSON.stringify(Object.keys(batch)) === JSON.stringify(['type', 'url', 'title', 'viewport', 'comments']),
    JSON.stringify(Object.keys(batch)));
  check('batch envelope carries url, title and viewport',
    batch.url.startsWith('file://') && batch.title === 'Synth Comment Overlay — Harness' &&
    batch.viewport.width === live.width && batch.viewport.height === live.height && batch.viewport.dpr >= 1,
    JSON.stringify(batch.viewport));
  check('the batch is exactly the queued comments, 1-based, in pin order',
    batch.comments.length === 3 &&
    JSON.stringify(batch.comments.map((c) => String(c.n))) === JSON.stringify(pinNumerals) &&
    JSON.stringify(batch.comments.map((c) => c.comment)) === JSON.stringify([C1, C2, C4]) &&
    JSON.stringify(batch.comments.map((c) => c.selector)) === JSON.stringify(sels) &&
    !batch.comments.some((c) => c.comment === 'delete me'),
    JSON.stringify(batch.comments.map((c) => c.n + ':' + c.selector)));
  check('comment has exactly the contract keys in order',
    JSON.stringify(Object.keys(batch.comments[0])) === JSON.stringify(
      ['n', 'comment', 'url', 'onCurrentPage', 'selector', 'xpath', 'elementHTML', 'elementText', 'reactSource', 'rect']),
    JSON.stringify(Object.keys(batch.comments[0])));
  check('every selector is unique and resolves to its own element',
    await page.evaluate((ss) => ss.every((s) => document.querySelectorAll(s).length === 1), sels),
    sels.join(' | '));
  check('comment 1 selector is the clicked button',
    await page.evaluate((s) => document.querySelector(s) === document.getElementById('deep-button'), sels[0]), sels[0]);
  check('widened comment reaches the host as the ancestor, not the paragraph',
    await page.evaluate((s) => document.querySelector(s) === document.querySelectorAll('p.twin')[1].parentElement,
      batch.comments[1].selector), batch.comments[1].selector);
  check('every xpath resolves to the same element as its selector',
    await page.evaluate((pairs) => pairs.every(([sel, xp]) => {
      const r = document.evaluate(xp, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
      return r.singleNodeValue === document.querySelector(sel);
    }), batch.comments.map((c) => [c.selector, c.xpath])),
    batch.comments.map((c) => c.xpath).join(' | '));
  check('rects are viewport-relative and carry scroll + dpr',
    batch.comments.every((c, i) =>
      approx(c.rect.x, live.rects[i].x) && approx(c.rect.y, live.rects[i].y) &&
      approx(c.rect.width, live.rects[i].width) && approx(c.rect.height, live.rects[i].height) &&
      c.rect.scrollX === live.scrollX && c.rect.scrollY === live.scrollY && c.rect.dpr >= 1),
    JSON.stringify(batch.comments.map((c) => c.rect)));
  check('url + onCurrentPage set per comment',
    batch.comments.every((c) => c.url === batch.url && c.onCurrentPage === true));
  check('elementHTML present and capped',
    batch.comments[0].elementHTML.includes('deep-button') &&
    batch.comments.every((c) => c.elementHTML.length <= 2000));
  check('elementText present and capped',
    batch.comments[0].elementText.includes('Deep button') &&
    batch.comments.every((c) => c.elementText.length <= 500));
  check('reactSource is null on a non-React page', batch.comments.every((c) => c.reactSource === null));

  d = await dbgOf(page);
  check('the send confirmation stands before the mode closes',
    d.sending === true && d.islandText.includes('sent to') && d.islandText.includes(LABEL), d.islandText);
  await page.screenshot({ path: path.join(SHOT_DIR, 'overlay-sent.png') });
  await page.waitForTimeout(1700);
  check('the mode closes itself after the confirmation', (await hostsOf(page)) === 0);
  msgs = await msgsOf(page);
  check('closing after a send emits exitMode last', msgs[msgs.length - 1].type === 'exitMode',
    JSON.stringify(msgs.slice(-2)));

  // ==== ASSERTION 7: the Escape ladder — composer, then list, then the mode =========
  await page.evaluate(() => window.__synthOverlay.enter({ targetLabel: 'ladder', debug: true }));
  await page.waitForTimeout(120);
  let ladderBase = (await msgsOf(page)).length;
  await page.evaluate(() => window.__synthOverlay.send());
  await page.waitForTimeout(150);
  check('send() no-ops on an empty queue',
    (await msgsOf(page)).length === ladderBase && (await dbgOf(page)).state === 'pick');

  await page.mouse.click(deepBox.x + deepBox.width / 2, deepBox.y + deepBox.height / 2);
  await page.waitForTimeout(150);
  await page.keyboard.type('ladder one');
  await page.keyboard.press('Enter');
  await page.waitForTimeout(120);
  await shadowClick(page, '[data-cm="list"]');
  await page.waitForTimeout(120);
  await page.mouse.click(hoverBox.x + 10, hoverBox.y + 10);
  await page.waitForTimeout(150);
  d = await dbgOf(page);
  check('ladder set up: composer open over an open list', d.cardOpen === true && d.listOpen === true);
  ladderBase = (await msgsOf(page)).length;

  await page.keyboard.press('Escape');
  await page.waitForTimeout(150);
  d = await dbgOf(page);
  msgs = await msgsOf(page);
  check('Escape 1 discards the composer only',
    !d.cardOpen && d.state === 'pick' && d.listOpen === true && (await hostsOf(page)) === 1 &&
    !msgs.slice(ladderBase).some((m) => m.type === 'exitMode'),
    JSON.stringify(msgs.slice(ladderBase)));

  await page.keyboard.press('Escape');
  await page.waitForTimeout(150);
  d = await dbgOf(page);
  msgs = await msgsOf(page);
  check('Escape 2 closes the list only',
    d.listOpen === false && d.state === 'pick' && (await hostsOf(page)) === 1 &&
    !msgs.slice(ladderBase).some((m) => m.type === 'exitMode'),
    JSON.stringify(msgs.slice(ladderBase)));

  await page.keyboard.press('Escape');
  await page.waitForTimeout(150);
  msgs = await msgsOf(page);
  check('Escape 3 exits the mode and emits exitMode',
    (await hostsOf(page)) === 0 && msgs[msgs.length - 1].type === 'exitMode' &&
    msgs.slice(ladderBase).filter((m) => m.type === 'exitMode').length === 1,
    JSON.stringify(msgs.slice(ladderBase)));
  check('abandoning a queue tells the host it is gone',
    msgs[msgs.length - 2].type === 'batchCount' && msgs[msgs.length - 2].n === 0,
    JSON.stringify(msgs.slice(-2)));
  check('exit deletes the debug hook', (await dbgOf(page)) === null);

  // ---- enter/exit cycles leave nothing behind ---------------------------------------
  for (let i = 0; i < 3; i++) {
    await page.evaluate(() => window.__synthOverlay.enter({ targetLabel: 'cycle', debug: true }));
    await page.evaluate(() => window.__synthOverlay.exit());
  }
  check('3 enter/exit cycles leave zero shadow hosts', (await hostsOf(page)) === 0);
  await page.evaluate(() => window.__synthOverlay.enter({ targetLabel: 'cycle', debug: true }));
  await page.evaluate(() => window.__synthOverlay.enter({ targetLabel: 'cycle2', debug: true })); // idempotent enter
  check('double enter still one host', (await hostsOf(page)) === 1);
  check('a re-enter only refreshes the target label',
    (await dbgOf(page)).islandText.includes('cycle2'), (await dbgOf(page)).islandText);
  await page.evaluate(() => window.__synthOverlay.exit());
  await page.evaluate(() => window.__synthOverlay.exit()); // idempotent exit
  check('double exit leaves zero hosts, no error', (await hostsOf(page)) === 0);

  // after exit, page handlers work again (no leaked suppressors)
  await page.click('#deep-button');
  check('page handlers restored after exit', (await page.evaluate(() => window.__clickCounts.deep)) === 1);

  // ---- zero-size element hover does not crash ----------------------------------------
  await page.evaluate(() => window.__synthOverlay.enter({ targetLabel: 'edge', debug: true }));
  const zeroPos = await page.evaluate(() => {
    const r = document.querySelector('.zero-size').getBoundingClientRect();
    return { x: r.x, y: r.y };
  });
  await page.mouse.move(zeroPos.x, zeroPos.y);
  await page.waitForTimeout(120);
  check('zero-size region hover does not crash', (await dbgOf(page)).state === 'pick');
  await page.evaluate(() => window.__synthOverlay.exit());
  await page.waitForTimeout(100);

  // ---- binding-missing buffering -------------------------------------------------------
  await page.evaluate(() => {
    window.__realBinding = window.__synthComment;
    delete window.__synthComment;
    window.__synthOverlay.enter({ targetLabel: 'buffered', debug: true });
  });
  await page.mouse.click(deepBox.x + deepBox.width / 2, deepBox.y + deepBox.height / 2);
  await page.waitForTimeout(150);
  await page.keyboard.type('buffered comment');
  await page.waitForTimeout(100);
  const bufBefore = (await msgsOf(page)).length;
  check('batchCount buffered while the binding is missing',
    (await dbgOf(page)).pendingSendCount === 1 && (await msgsOf(page)).length === bufBefore);
  await page.keyboard.press('Meta+Alt+Enter');   // queue-and-send with no binding
  await page.waitForTimeout(200);
  check('the batch buffers too, rather than being dropped',
    (await dbgOf(page)).pendingSendCount === 3 && (await msgsOf(page)).length === bufBefore,
    'pending=' + (await dbgOf(page)).pendingSendCount);
  await page.evaluate(() => { window.__synthComment = window.__realBinding; });
  await page.waitForTimeout(600);
  msgs = await msgsOf(page);
  const flushed = msgs.slice(bufBefore);
  check('buffered payloads flush in order once the binding appears',
    JSON.stringify(flushed.map((m) => m.type)) === JSON.stringify(['batchCount', 'commentBatch', 'batchCount']) &&
    flushed[1].comments.length === 1 && flushed[1].comments[0].comment === 'buffered comment',
    JSON.stringify(flushed.map((m) => m.type)));
  await page.waitForTimeout(1700);
  check('no page errors on harness', pageErrors.length === 0, pageErrors.join(' | '));

  // ================================ deferred mount ========================================
  // Injected the way the host does it (document-start, before <body> exists), enter() must
  // wait for a DOM it can host rather than throwing and never mounting.
  const dp = await browser.newPage({ viewport: { width: 1024, height: 768 } });
  const dpErrors = [];
  dp.on('pageerror', (e) => dpErrors.push('pageerror: ' + e.message));
  await dp.addInitScript({ path: OVERLAY_JS });
  await dp.addInitScript(() => {
    window.__synthDomAtEnter = !!document.body;
    window.__synthOverlay.enter({ targetLabel: 'deferred', debug: true });
    window.__synthMountedAtEnter = document.querySelectorAll('[data-synth-comment-overlay]').length;
  });
  await dp.goto('file://' + HARNESS);
  await dp.waitForTimeout(400);
  check('enter() at document-start finds no body and mounts nothing yet',
    (await dp.evaluate(() => window.__synthDomAtEnter)) === false &&
    (await dp.evaluate(() => window.__synthMountedAtEnter)) === 0);
  check('the deferred mount lands once the DOM exists',
    (await hostsOf(dp)) === 1 && (await dbgOf(dp)).state === 'pick');
  await dp.evaluate(() => window.__synthOverlay.exit());
  check('no page errors on the deferred-mount page', dpErrors.length === 0, dpErrors.join(' | '));
  await dp.close();

  // ================================ React page ============================================
  const rp = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  const rpErrors = [];
  rp.on('pageerror', (e) => rpErrors.push('pageerror: ' + e.message));
  rp.on('console', (m) => { if (m.type() === 'error') rpErrors.push('console.error: ' + m.text()); });
  await rp.goto('file://' + REACT_PAGE);
  await rp.waitForTimeout(300);
  await rp.evaluate(() => window.__synthOverlay.enter({ targetLabel: 'claude · feat/react-panel', debug: true }));

  const rBtn = await rp.locator('#react-button').boundingBox();
  await rp.mouse.click(rBtn.x + 10, rBtn.y + 10);
  await rp.waitForTimeout(150);
  await rp.keyboard.type('rename this to Save');
  await rp.keyboard.press('Enter');
  await rp.waitForTimeout(120);

  const rLeaf = await rp.locator('#react-leaf').boundingBox();
  await rp.mouse.click(rLeaf.x + 5, rLeaf.y + 5);
  await rp.waitForTimeout(150);
  await rp.keyboard.type('leaf');
  await rp.screenshot({ path: path.join(SHOT_DIR, 'overlay-react.png') });
  const rBefore = (await msgsOf(rp)).length;
  await rp.keyboard.press('Meta+Alt+Enter');     // ⌘⌥⏎ queues the open composer and sends
  await rp.waitForTimeout(250);
  let rMsgs = await msgsOf(rp);
  const rBatches = rMsgs.filter((m) => m.type === 'commentBatch');
  check('⌘⌥⏎ queues the open composer and sends one batch',
    rBatches.length === 1 && rBatches[0].comments.length === 2 &&
    JSON.stringify(rBatches[0].comments.map((c) => c.n)) === JSON.stringify([1, 2]) &&
    rBatches[0].comments[1].comment === 'leaf',
    JSON.stringify(rMsgs.slice(rBefore).map((m) => m.type)));
  check('react button comment carries reactSource file + line',
    rBatches[0].comments[0].reactSource &&
    rBatches[0].comments[0].reactSource.fileName === '/app/src/components/Panel.jsx' &&
    rBatches[0].comments[0].reactSource.lineNumber === 14 &&
    rBatches[0].comments[0].reactSource.columnNumber === 7,
    JSON.stringify(rBatches[0].comments[0].reactSource));
  check('owner-chain fallback finds the component source for the leaf',
    rBatches[0].comments[1].reactSource && rBatches[0].comments[1].reactSource.lineNumber === 15,
    JSON.stringify(rBatches[0].comments[1].reactSource));
  check('react click handler suppressed during pick', (await rp.evaluate(() => window.__reactClicks || 0)) === 0);
  await rp.waitForTimeout(1700);
  check('react page returns to no overlay after the send', (await hostsOf(rp)) === 0);
  check('no page errors on react page', rpErrors.length === 0, rpErrors.join(' | '));

  console.log(results.join('\n'));
  const fail = results.some((r) => r.startsWith('FAIL'));
  console.log(fail ? 'RESULT: FAIL' : 'RESULT: PASS');
  await browser.close();
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('HARNESS ERROR', e); process.exit(2); });
