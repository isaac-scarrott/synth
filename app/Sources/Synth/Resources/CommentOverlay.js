/*
 * Synth comment overlay — stage three of the embedded-browser plan (ADR-0011).
 *
 * Injected by the host via Page.addScriptToEvaluateOnNewDocument (and evaluated once on the
 * already-loaded page). Defines window.__synthOverlay = { enter(cfg), exit() }. Comments travel
 * back over the CDP binding window.__synthComment(JSON.stringify(payload)); when the binding is
 * not visible in this world yet, payloads buffer and retry for 5s, then degrade to console.warn.
 *
 * Works in the MAIN world or an isolated world. reactSource extraction needs the MAIN world
 * (fiber expandos are per-world); elsewhere it degrades to null.
 */
(function () {
  'use strict';

  if (window.__synthOverlay && window.__synthOverlay.__synthCommentOverlay) return;

  var MAX_Z = 2147483647;
  var HOST_ATTR = 'data-synth-comment-overlay';
  var RETRY_MS = 200;
  var RETRY_WINDOW_MS = 5000;
  var TOAST_MS = 900;

  /* ---------------------------------------------------------------- channel */

  var pendingSends = [];
  var retryTimer = null;
  var retryDeadline = 0;

  function bindingFn() {
    return typeof window.__synthComment === 'function' ? window.__synthComment : null;
  }

  function send(payload) {
    var msg = JSON.stringify(payload);
    var fn = bindingFn();
    if (fn) {
      try { fn(msg); } catch (e) { console.warn('[synth-overlay] __synthComment threw:', e); }
      return;
    }
    pendingSends.push(msg);
    if (retryTimer) return;
    retryDeadline = Date.now() + RETRY_WINDOW_MS;
    retryTimer = setInterval(function () {
      var f = bindingFn();
      if (f) {
        clearInterval(retryTimer); retryTimer = null;
        while (pendingSends.length) {
          try { f(pendingSends.shift()); } catch (e) { console.warn('[synth-overlay] __synthComment threw:', e); }
        }
      } else if (Date.now() > retryDeadline) {
        clearInterval(retryTimer); retryTimer = null;
        while (pendingSends.length) {
          console.warn('[synth-overlay] __synthComment binding unavailable; dropping payload:', pendingSends.shift());
        }
      }
    }, RETRY_MS);
  }

  /* ------------------------------------------------------- selector / xpath */

  function cssEscape(s) {
    return (window.CSS && CSS.escape) ? CSS.escape(s) : String(s).replace(/([^a-zA-Z0-9_-])/g, '\\$1');
  }

  function matchesOnly(sel, el) {
    try {
      var found = document.querySelectorAll(sel);
      return found.length === 1 && found[0] === el;
    } catch (e) { return false; }
  }

  function idIsUnique(id) {
    try { return document.querySelectorAll('#' + cssEscape(id)).length === 1; } catch (e) { return false; }
  }

  function segmentFor(node) {
    var tag = node.tagName.toLowerCase();
    var parent = node.parentElement;
    if (!parent) return tag;
    var sameTag = 0, index = 0;
    for (var c = parent.firstElementChild; c; c = c.nextElementSibling) {
      if (c.tagName === node.tagName) {
        sameTag++;
        if (c === node) index = sameTag;
      }
    }
    return sameTag > 1 ? tag + ':nth-of-type(' + index + ')' : tag;
  }

  /* Best selector: unique #id, else the shortest unique tail of a tag/nth-of-type path
     (optionally anchored on the nearest ancestor with a unique id), verified via
     querySelectorAll().length === 1 and matching the element. */
  function computeSelector(el) {
    if (el.id && idIsUnique(el.id)) return '#' + cssEscape(el.id);

    var segs = [];
    var node = el;
    while (node && node.nodeType === 1) {
      segs.unshift(segmentFor(node));
      node = node.parentElement;
    }
    // segs[0] is html. Try the shortest tail first, growing toward the root; at each length
    // also try anchoring on a unique-id ancestor just above the tail.
    var anc = [];
    node = el;
    while (node && node.nodeType === 1) { anc.unshift(node); node = node.parentElement; }
    for (var start = segs.length - 1; start >= 0; start--) {
      var tail = segs.slice(start).join(' > ');
      var above = anc[start - 1];
      if (above && above.id && idIsUnique(above.id)) {
        var anchored = '#' + cssEscape(above.id) + ' > ' + tail;
        if (matchesOnly(anchored, el)) return anchored;
      }
      if (matchesOnly(tail, el)) return tail;
    }
    return segs.join(' > '); // full absolute path; structurally unique
  }

  function computeXPath(el) {
    var parts = [];
    var node = el;
    while (node && node.nodeType === 1) {
      var idx = 1;
      for (var sib = node.previousElementSibling; sib; sib = sib.previousElementSibling) {
        if (sib.tagName === node.tagName) idx++;
      }
      parts.unshift(node.tagName.toLowerCase() + '[' + idx + ']');
      node = node.parentElement;
    }
    return '/' + parts.join('/');
  }

  /* ------------------------------------------------------------ reactSource */

  function extractReactSource(el) {
    try {
      var node = el;
      for (var depth = 0; depth < 4 && node; depth++, node = node.parentElement) {
        var keys = Object.keys(node);
        var fiberKey = null;
        for (var i = 0; i < keys.length; i++) {
          if (keys[i].indexOf('__reactFiber$') === 0) { fiberKey = keys[i]; break; }
        }
        if (!fiberKey) continue;
        var fiber = node[fiberKey];
        var hops = 0;
        while (fiber && hops++ < 50) {
          var src = fiber._debugSource;
          if (src && src.fileName) {
            return {
              fileName: String(src.fileName),
              lineNumber: typeof src.lineNumber === 'number' ? src.lineNumber : null,
              columnNumber: typeof src.columnNumber === 'number' ? src.columnNumber : null
            };
          }
          fiber = fiber._debugOwner;
        }
      }
    } catch (e) { /* never throw */ }
    return null;
  }

  /* -------------------------------------------------------------------- UI */

  var STYLE = [
    ':host { all: initial; }',
    '* { margin: 0; padding: 0; box-sizing: border-box; }',
    '.veil { position: fixed; inset: 0; z-index: 1; pointer-events: auto; cursor: crosshair; background: transparent; }',
    '.veil[data-mode="card"] { cursor: default; }',
    '.hi { position: fixed; z-index: 2; pointer-events: none; display: none;',
    '  border: 1.5px solid #0a84ff; background: rgba(10,132,255,0.10); border-radius: 3px; }',
    '.hi[data-frozen] { border-color: #0a84ff; background: rgba(10,132,255,0.16);',
    '  box-shadow: 0 0 0 3px rgba(10,132,255,0.18); }',
    '.chip { position: fixed; z-index: 3; pointer-events: none; display: none; max-width: 60vw;',
    '  font: 500 11px/1 ui-monospace, "SF Mono", Menlo, monospace; color: #f5f5f7;',
    '  background: rgba(28,28,32,0.96); border: 0.5px solid rgba(255,255,255,0.14);',
    '  border-radius: 6px; padding: 5px 8px; white-space: nowrap; overflow: hidden;',
    '  text-overflow: ellipsis; box-shadow: 0 2px 8px rgba(0,0,0,0.35); }',
    '.chip__dims { color: #98989f; margin-left: 7px; }',
    '.card { position: fixed; z-index: 4; pointer-events: auto; display: none; width: 288px;',
    '  background: rgba(30,30,34,0.98); border: 0.5px solid rgba(255,255,255,0.12);',
    '  border-radius: 10px; box-shadow: 0 1px 2px rgba(0,0,0,0.3), 0 12px 32px rgba(0,0,0,0.45);',
    '  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;',
    '  color: #e8e8ea; overflow: hidden; }',
    '.card__head { display: flex; align-items: center; gap: 6px; padding: 9px 12px 7px;',
    '  font-size: 11.5px; font-weight: 600; color: #98989f; }',
    '.card__arrow { color: #0a84ff; font-weight: 700; }',
    '.card__target { color: #e8e8ea; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }',
    '.card__input { display: block; width: calc(100% - 20px); margin: 0 10px; min-height: 62px;',
    '  resize: none; font: 13px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;',
    '  color: #f5f5f7; background: rgba(255,255,255,0.06); border: 0.5px solid rgba(255,255,255,0.10);',
    '  border-radius: 7px; padding: 7px 9px; outline: none; }',
    '.card__input:focus { border-color: rgba(10,132,255,0.7); box-shadow: 0 0 0 2.5px rgba(10,132,255,0.22); }',
    '.card__input::placeholder { color: #6e6e76; }',
    '.card__foot { display: flex; align-items: center; gap: 7px; padding: 9px 10px 10px; }',
    '.card__hint { flex: 1; font-size: 10.5px; color: #6e6e76; padding-left: 2px; }',
    '.card__btn { appearance: none; border: 0; font: 600 12px/1 -apple-system, BlinkMacSystemFont,',
    '  "SF Pro Text", system-ui, sans-serif; border-radius: 7px; padding: 6px 11px; cursor: pointer; }',
    '.card__btn--ghost { color: #b9b9c0; background: rgba(255,255,255,0.07); }',
    '.card__btn--ghost:hover { background: rgba(255,255,255,0.12); }',
    '.card__btn--primary { color: #fff; background: #0a84ff; }',
    '.card__btn--primary:hover { background: #2492ff; }',
    '.card__btn--primary:disabled { opacity: 0.45; cursor: default; }',
    '.card__toast { display: none; align-items: center; justify-content: center; gap: 6px;',
    '  position: absolute; inset: 0; background: #1e1e22; font-size: 13px;',
    '  font-weight: 600; color: #34c759; }',
    '.card[data-sent] .card__toast { display: flex; }'
  ].join('\n');

  var state = 'off';          // 'off' | 'pick' | 'card'
  var cfg = { targetLabel: '' };
  var hostEl = null, veil = null, hiBox = null, chip = null, card = null;
  var cardTarget = null, cardInput = null, cardSend = null, cardCancel = null;
  var hoveredEl = null, frozenEl = null, snapshot = null;
  var lastPoint = null, needsHitTest = false;
  var rafId = 0, moveRafPending = false, toastTimer = null;
  var teardownFns = [];

  function on(target, type, fn, opts) {
    target.addEventListener(type, fn, opts);
    teardownFns.push(function () { target.removeEventListener(type, fn, opts); });
  }

  function isOurs(ev) {
    var path = ev.composedPath ? ev.composedPath() : [];
    return hostEl !== null && path.indexOf(hostEl) !== -1;
  }

  function buildUI() {
    hostEl = document.createElement('div');
    hostEl.setAttribute(HOST_ATTR, '');
    hostEl.style.cssText = 'all: initial; position: fixed; inset: 0; z-index: ' + MAX_Z +
      '; pointer-events: none;';
    hostEl.style.setProperty('display', 'block', 'important');
    var root = hostEl.attachShadow({ mode: 'closed' });

    var style = document.createElement('style');
    style.textContent = STYLE;
    root.appendChild(style);

    veil = document.createElement('div');
    veil.className = 'veil';
    root.appendChild(veil);

    hiBox = document.createElement('div');
    hiBox.className = 'hi';
    root.appendChild(hiBox);

    chip = document.createElement('div');
    chip.className = 'chip';
    root.appendChild(chip);

    card = document.createElement('div');
    card.className = 'card';
    card.innerHTML =
      '<div class="card__head"><span class="card__arrow">→</span>' +
      '<span class="card__target"></span></div>' +
      '<textarea class="card__input" rows="3" placeholder="Describe the change…"></textarea>' +
      '<div class="card__foot"><span class="card__hint">⌘↩ to send</span>' +
      '<button type="button" class="card__btn card__btn--ghost">Cancel</button>' +
      '<button type="button" class="card__btn card__btn--primary" disabled>Send to Claude</button></div>' +
      '<div class="card__toast">Sent ✓</div>';
    root.appendChild(card);

    cardTarget = card.querySelector('.card__target');
    cardCancel = card.querySelector('.card__btn--ghost');
    cardSend = card.querySelector('.card__btn--primary');
    cardInput = card.querySelector('.card__input');
    cardTarget.textContent = cfg.targetLabel || 'Claude';

    document.documentElement.appendChild(hostEl);
    teardownFns.push(function () { if (hostEl && hostEl.parentNode) hostEl.parentNode.removeChild(hostEl); });
  }

  /* ------------------------------------------------------------ geometry */

  function elementLabel(el) {
    var t = el.tagName.toLowerCase();
    if (el.id) t += '#' + el.id;
    var cls = (typeof el.className === 'string' ? el.className : '').trim().split(/\s+/).filter(Boolean);
    for (var i = 0; i < Math.min(cls.length, 2); i++) t += '.' + cls[i];
    if (t.length > 48) t = t.slice(0, 47) + '…';
    return t;
  }

  function positionHighlight(el, frozen) {
    if (!el || !el.isConnected) { hiBox.style.display = 'none'; chip.style.display = 'none'; return; }
    var r = el.getBoundingClientRect();
    hiBox.style.display = 'block';
    if (frozen) hiBox.setAttribute('data-frozen', ''); else hiBox.removeAttribute('data-frozen');
    hiBox.style.left = r.left - 1.5 + 'px';
    hiBox.style.top = r.top - 1.5 + 'px';
    hiBox.style.width = Math.max(r.width, 0) + 'px';
    hiBox.style.height = Math.max(r.height, 0) + 'px';

    chip.style.display = 'block';
    chip.innerHTML = '';
    chip.appendChild(document.createTextNode(elementLabel(el)));
    var dims = document.createElement('span');
    dims.className = 'chip__dims';
    dims.textContent = Math.round(r.width) + '×' + Math.round(r.height);
    chip.appendChild(dims);
    var chipTop = r.top - 28;
    if (chipTop < 6) chipTop = Math.min(r.bottom + 6, window.innerHeight - 30);
    var chipLeft = Math.max(6, Math.min(r.left, window.innerWidth - chip.offsetWidth - 6));
    chip.style.left = chipLeft + 'px';
    chip.style.top = chipTop + 'px';
  }

  function positionCard(el) {
    var vw = window.innerWidth, vh = window.innerHeight, pad = 10, gap = 10;
    var cw = card.offsetWidth || 288, ch = card.offsetHeight || 150;
    var r = (el && el.isConnected) ? el.getBoundingClientRect()
      : (snapshot ? snapshot.freezeRect : { left: vw / 2, top: vh / 2, right: vw / 2, bottom: vh / 2, width: 0, height: 0 });
    var left, top;
    if (r.right + gap + cw + pad <= vw) {          // right of the element
      left = r.right + gap; top = r.top;
    } else if (r.left - gap - cw >= pad) {         // left of the element
      left = r.left - gap - cw; top = r.top;
    } else if (r.bottom + gap + ch + pad <= vh) {  // below
      left = r.left; top = r.bottom + gap;
    } else if (r.top - gap - ch >= pad) {          // above
      left = r.left; top = r.top - gap - ch;
    } else {                                       // overlap, clamped
      left = r.left; top = r.top;
    }
    card.style.left = Math.max(pad, Math.min(left, vw - cw - pad)) + 'px';
    card.style.top = Math.max(pad, Math.min(top, vh - ch - pad)) + 'px';
  }

  /* ------------------------------------------------------------- hit test */

  function hitTest(x, y) {
    var els = document.elementsFromPoint(x, y);
    for (var i = 0; i < els.length; i++) {
      if (els[i] !== hostEl) return els[i];
    }
    return null;
  }

  function updateHover() {
    if (state !== 'pick' || !lastPoint) return;
    var el = hitTest(lastPoint.x, lastPoint.y);
    hoveredEl = el;
    positionHighlight(el, false);
  }

  /* ------------------------------------------------------------ frame loop */

  function frame() {
    if (state === 'off') return;
    if (state === 'pick') {
      if (needsHitTest) { needsHitTest = false; updateHover(); }
      else if (hoveredEl) positionHighlight(hoveredEl, false); // stay glued through mutation/animation
    } else if (state === 'card') {
      positionHighlight(frozenEl, true);
      positionCard(frozenEl);
    }
    rafId = requestAnimationFrame(frame);
  }

  /* ---------------------------------------------------------- pick / card */

  function takeSnapshot(el) {
    var r = el.getBoundingClientRect();
    return {
      el: el,
      freezeRect: { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height, x: r.x, y: r.y },
      selector: computeSelector(el),
      xpath: computeXPath(el),
      elementHTML: String(el.outerHTML || '').slice(0, 2000),
      elementText: String(el.innerText != null ? el.innerText : (el.textContent || '')).slice(0, 500),
      reactSource: extractReactSource(el)
    };
  }

  function openCard(el) {
    frozenEl = el;
    snapshot = takeSnapshot(el);
    state = 'card';
    veil.setAttribute('data-mode', 'card');
    cardTarget.textContent = cfg.targetLabel || 'Claude';
    card.removeAttribute('data-sent');
    cardInput.value = '';
    cardSend.disabled = true;
    card.style.display = 'block';
    positionHighlight(frozenEl, true);
    positionCard(frozenEl);
    requestAnimationFrame(function () { try { cardInput.focus(); } catch (e) {} });
  }

  function closeCard() {
    if (toastTimer) { clearTimeout(toastTimer); toastTimer = null; }
    card.style.display = 'none';
    card.removeAttribute('data-sent');
    cardInput.value = '';
    frozenEl = null;
    snapshot = null;
    state = 'pick';
    veil.removeAttribute('data-mode');
    needsHitTest = true;
  }

  function buildCommentPayload() {
    var el = snapshot.el;
    var r = (el && el.isConnected) ? el.getBoundingClientRect() : snapshot.freezeRect;
    return {
      type: 'comment',
      url: location.href,
      title: document.title,
      selector: snapshot.selector,
      xpath: snapshot.xpath,
      rect: {
        x: r.x, y: r.y, width: r.width, height: r.height,
        scrollX: window.scrollX, scrollY: window.scrollY,
        dpr: window.devicePixelRatio
      },
      elementHTML: snapshot.elementHTML,
      elementText: snapshot.elementText,
      comment: cardInput.value,
      reactSource: snapshot.reactSource
    };
  }

  function submit() {
    if (state !== 'card' || !snapshot) return;
    if (!cardInput.value.trim()) { cardInput.focus(); return; }
    send(buildCommentPayload());
    card.setAttribute('data-sent', '');
    toastTimer = setTimeout(function () { toastTimer = null; closeCard(); }, TOAST_MS);
  }

  /* --------------------------------------------------------------- events */

  function onVeilMove(ev) {
    lastPoint = { x: ev.clientX, y: ev.clientY };
    if (state !== 'pick' || moveRafPending) return;
    moveRafPending = true;
    requestAnimationFrame(function () { moveRafPending = false; updateHover(); });
  }

  function onVeilClick(ev) {
    ev.preventDefault();
    ev.stopPropagation();
    if (state === 'pick') {
      lastPoint = { x: ev.clientX, y: ev.clientY };
      var el = hitTest(ev.clientX, ev.clientY);
      if (el) openCard(el);
    } else if (state === 'card' && !card.hasAttribute('data-sent')) {
      closeCard(); // click outside the card cancels back to pick
    }
  }

  function onKeyDown(ev) {
    if (state === 'off') return;
    if (ev.key === 'Escape') {
      ev.preventDefault();
      ev.stopImmediatePropagation();
      if (state === 'card') closeCard();
      else doExit(true);
      return;
    }
    if (state === 'card' && ev.key === 'Enter' && (ev.metaKey || ev.ctrlKey)) {
      ev.preventDefault();
      ev.stopImmediatePropagation();
      submit();
    }
  }

  // Backup suppressor: any mouse event that somehow bypasses the veil while picking must not
  // reach the page's handlers (capture phase; preventDefault on click only).
  function onSuppress(ev) {
    if (state === 'off' || isOurs(ev)) return;
    ev.stopImmediatePropagation();
    if (ev.type === 'click') ev.preventDefault();
  }

  function onScroll() { needsHitTest = true; }

  /* ---------------------------------------------------------- enter / exit */

  function doEnter(config) {
    config = config || {};
    if (state !== 'off') {
      cfg.targetLabel = config.targetLabel != null ? String(config.targetLabel) : cfg.targetLabel;
      if (cardTarget) cardTarget.textContent = cfg.targetLabel || 'Claude';
      return;
    }
    cfg.targetLabel = config.targetLabel != null ? String(config.targetLabel) : '';
    buildUI();
    state = 'pick';

    on(veil, 'mousemove', onVeilMove);
    on(veil, 'click', onVeilClick);
    on(window, 'keydown', onKeyDown, true);
    on(window, 'scroll', onScroll, { capture: true, passive: true });
    on(window, 'resize', onScroll, { passive: true });
    var types = ['pointerdown', 'pointerup', 'mousedown', 'mouseup', 'click', 'dblclick', 'auxclick'];
    for (var i = 0; i < types.length; i++) on(window, types[i], onSuppress, true);

    on(cardCancel, 'click', function (ev) { ev.stopPropagation(); closeCard(); });
    on(cardSend, 'click', function (ev) { ev.stopPropagation(); submit(); });
    on(cardInput, 'input', function () { cardSend.disabled = !cardInput.value.trim(); });
    // Keep typed keys inside the card (page shortcut handlers must not fire while commenting).
    on(card, 'keydown', function (ev) { ev.stopPropagation(); });
    on(card, 'keyup', function (ev) { ev.stopPropagation(); });
    on(card, 'keypress', function (ev) { ev.stopPropagation(); });

    if (config.debug) installDebug();

    rafId = requestAnimationFrame(frame);
  }

  function teardown() {
    state = 'off';
    if (rafId) { cancelAnimationFrame(rafId); rafId = 0; }
    if (toastTimer) { clearTimeout(toastTimer); toastTimer = null; }
    while (teardownFns.length) {
      try { teardownFns.pop()(); } catch (e) {}
    }
    hostEl = veil = hiBox = chip = card = null;
    cardTarget = cardInput = cardSend = cardCancel = null;
    hoveredEl = frozenEl = snapshot = lastPoint = null;
    moveRafPending = false; needsHitTest = false;
    try { delete window.__synthOverlayDebug; } catch (e) {}
  }

  function doExit(notifyHost) {
    if (state === 'off') return;
    teardown();
    if (notifyHost) {
      send({
        type: 'exitMode',
        url: location.href,
        title: document.title,
        selector: '',
        xpath: '',
        rect: { x: 0, y: 0, width: 0, height: 0, scrollX: window.scrollX, scrollY: window.scrollY, dpr: window.devicePixelRatio },
        elementHTML: '',
        elementText: '',
        comment: '',
        reactSource: null
      });
    }
  }

  /* ------------------------------------------------------------ debug hooks
     Test-only introspection (the shadow root is closed); created only when
     enter({ debug: true }) is passed. The host never passes debug. */
  function installDebug() {
    window.__synthOverlayDebug = {
      get state() { return state; },
      get hoveredTag() { return hoveredEl ? hoveredEl.tagName.toLowerCase() : null; },
      get highlightRect() {
        if (!hiBox || hiBox.style.display === 'none') return null;
        var r = hiBox.getBoundingClientRect();
        return { x: r.x, y: r.y, width: r.width, height: r.height };
      },
      get cardOpen() { return state === 'card'; },
      get cardRect() {
        if (!card || card.style.display === 'none') return null;
        var r = card.getBoundingClientRect();
        return { x: r.x, y: r.y, width: r.width, height: r.height };
      },
      get sentToastVisible() { return !!(card && card.hasAttribute('data-sent')); },
      get pendingSendCount() { return pendingSends.length; }
    };
  }

  window.__synthOverlay = {
    __synthCommentOverlay: true,
    enter: function (config) { try { doEnter(config); } catch (e) { console.warn('[synth-overlay] enter failed:', e); } },
    exit: function () { try { doExit(true); } catch (e) { console.warn('[synth-overlay] exit failed:', e); } }
  };
})();
