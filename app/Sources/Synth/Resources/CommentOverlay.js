/*
 * Synth comment overlay — stage three of the embedded-browser plan (ADR-0011), batched.
 *
 * Injected by the host via Page.addScriptToEvaluateOnNewDocument (and evaluated once on the
 * already-loaded page). Defines window.__synthOverlay = { enter(cfg), exit(), send() }.
 *
 * Comments accumulate on the page as numbered pins and leave together: a pass over a page is
 * one delivery instead of one interruption per remark. ⏎ queues, Send ships the batch over the
 * CDP binding window.__synthComment(JSON.stringify(payload)); when the binding is not visible
 * in this world yet, payloads buffer and retry for 5s, then degrade to console.warn.
 *
 * A comment holds the element it was left on plus where inside it the click landed, as a
 * fraction of that element's box — never a page coordinate. So a pin rides its own paragraph
 * through scroll, resize and zoom, and widening the comment's scope up the ancestor chain
 * leaves the pin exactly where it was put.
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
  var SENT_MS = 1500;          // the sent confirmation stands this long, then the mode closes

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

  var EASE = 'cubic-bezier(0.22, 1, 0.36, 1)';
  var COPPER = '#a05633';          // the pin, on the page's own colours
  var COPPER_LIT = '#c2724c';      // the same mark on the overlay's dark chrome
  var FONT = '-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif';
  var MONO = 'ui-monospace, "SF Mono", Menlo, monospace';

  var ICON_CHEV = '<svg viewBox="0 0 256 256" fill="currentColor"><path d="M213.66,101.66l-80,80a8,8,0,0,1-11.32,0l-80-80A8,8,0,0,1,53.66,90.34L128,164.69l74.34-74.35a8,8,0,0,1,11.32,11.32Z"/></svg>';
  var ICON_X = '<svg viewBox="0 0 256 256" fill="currentColor"><path d="M205.66,194.34a8,8,0,0,1-11.32,11.32L128,139.31,61.66,205.66a8,8,0,0,1-11.32-11.32L116.69,128,50.34,61.66A8,8,0,0,1,61.66,50.34L128,116.69l66.34-66.35a8,8,0,0,1,11.32,11.32L139.31,128Z"/></svg>';
  var ICON_TICK = '<svg viewBox="0 0 256 256" fill="currentColor"><path d="M229.66,77.66l-128,128a8,8,0,0,1-11.32,0l-56-56a8,8,0,0,1,11.32-11.32L96,188.69,218.34,66.34a8,8,0,0,1,11.32,11.32Z"/></svg>';
  var ICON_PIN = '<svg viewBox="0 0 256 256" fill="currentColor"><path d="M128,64a40,40,0,1,0,40,40A40,40,0,0,0,128,64Zm0,64a24,24,0,1,1,24-24A24,24,0,0,1,128,128Zm0-112a88.1,88.1,0,0,0-88,88c0,31.4,14.51,64.68,42,96.25a254.19,254.19,0,0,0,41.45,38.3,8,8,0,0,0,9.18,0A254.19,254.19,0,0,0,174,200.25c27.45-31.57,42-64.85,42-96.25A88.1,88.1,0,0,0,128,16Zm0,206c-16.53-13-72-60.75-72-118a72,72,0,0,1,144,0C200,161.23,144.53,209,128,222Z"/></svg>';

  var STYLE = [
    ':host { all: initial; }',
    '* { margin: 0; padding: 0; box-sizing: border-box; }',
    '.veil { position: fixed; inset: 0; z-index: 1; pointer-events: auto; cursor: crosshair; background: transparent; }',
    '.veil[data-mode="card"] { cursor: default; }',

    /* what a click would attach to, named before you commit to it */
    '.hi { position: fixed; z-index: 2; pointer-events: none; display: none;',
    '  border: 1.5px solid ' + COPPER + '; border-radius: 3px; background: rgba(160,86,51,0.07); }',
    '.chip { position: fixed; z-index: 3; pointer-events: none; display: none; max-width: 60vw;',
    '  font: 500 10.5px/1 ' + MONO + '; color: #fff; background: ' + COPPER + ';',
    '  border-radius: 4px; padding: 4px 7px; white-space: nowrap; overflow: hidden;',
    '  text-overflow: ellipsis; box-shadow: 0 2px 8px rgba(0,0,0,0.28); }',
    '.chip__dims { opacity: 0.7; margin-left: 7px; }',

    /* the comment's scope — the target element's own bounds, so it is exact by construction
       and it slides as you widen up the tree */
    '.scope { position: fixed; z-index: 2; pointer-events: none; display: none;',
    '  border: 1.5px solid ' + COPPER + '; border-radius: 3px; background: rgba(160,86,51,0.07); }',
    '.scope.is-widening { transition: left 160ms ' + EASE + ', top 160ms ' + EASE + ',',
    '  width 160ms ' + EASE + ', height 160ms ' + EASE + '; }',

    /* The pin marks a place; it never competes with the page. Its ring is the page's own
       background colour, so it reads as cut out of the page on light and dark alike. */
    '.layer { --ring: #ffffff; position: fixed; inset: 0; z-index: 4; pointer-events: none; }',
    '.pin { position: fixed; pointer-events: auto; width: 22px; height: 22px; margin: -11px 0 0 -11px;',
    '  display: flex; align-items: center; justify-content: center; border-radius: 999px; border: 0;',
    '  cursor: pointer; background: ' + COPPER + '; color: #fff; font: 700 11px/1 ' + FONT + ';',
    '  font-variant-numeric: tabular-nums; box-shadow: 0 0 0 2px var(--ring), 0 2px 8px rgba(0,0,0,0.28);',
    '  transition: transform 140ms ' + EASE + ', opacity 140ms ease; animation: pop 260ms ' + EASE + '; }',
    '@keyframes pop { from { transform: scale(0.4); opacity: 0; } to { transform: none; opacity: 1; } }',
    '.pin:hover { transform: scale(1.14); }',
    /* unwritten: a composer someone opened, not a comment — hollow until it has words */
    '.pin.is-draft { background: var(--ring); color: ' + COPPER + ';',
    '  box-shadow: 0 0 0 1.5px ' + COPPER + ', 0 2px 8px rgba(0,0,0,0.22); }',
    '.pin.is-active { transform: scale(1.14); box-shadow: 0 0 0 2px var(--ring),',
    '  0 0 0 6px rgba(160,86,51,0.28), 0 2px 8px rgba(0,0,0,0.28); }',
    /* non-invasive by construction: working one comment recedes the others, rather than
       dropping a scrim over the page */
    '.layer.is-focused .pin:not(.is-active) { opacity: 0.28; }',
    '.pin.is-lit { animation: lit 620ms ' + EASE + '; }',
    '@keyframes lit { 0%, 100% { transform: none; } 40% { transform: scale(1.45); } }',
    '.pin.is-going { transform: scale(0.3); opacity: 0; }',

    /* hover peek: the comment's own words, without opening anything */
    '.peek { position: fixed; z-index: 5; pointer-events: none; max-width: 250px; padding: 7px 10px;',
    '  border-radius: 9px; background: rgba(28,28,32,0.97); border: 0.5px solid rgba(255,255,255,0.12);',
    '  box-shadow: 0 12px 30px rgba(0,0,0,0.4); font-family: ' + FONT + '; }',
    '.peek__sel { font: 10px/1.3 ' + MONO + '; color: #8e8e96; margin-bottom: 3px; }',
    '.peek__txt { font-size: 12px; line-height: 1.45; color: #e8e8ea; white-space: pre-wrap; word-break: break-word; }',

    /* Composer — anchored to its pin, and it queues. Nothing here reaches an agent. */
    '.card { position: fixed; z-index: 6; width: 300px; pointer-events: auto; padding: 9px;',
    '  border-radius: 12px; background: rgba(28,28,32,0.97); border: 0.5px solid rgba(255,255,255,0.12);',
    '  box-shadow: 0 1px 2px rgba(0,0,0,0.3), 0 14px 38px rgba(0,0,0,0.45); font-family: ' + FONT + ';',
    '  animation: drop 150ms ' + EASE + '; }',
    '@keyframes drop { from { opacity: 0; transform: translateY(-6px); } to { opacity: 1; transform: none; } }',
    /* The path is the scope control, not a caption: each ancestor is a target you can promote
       the comment to. Opens scrolled to the element you actually hit. */
    '.card__sel { display: flex; align-items: center; gap: 6px; padding: 0 0 7px; }',
    '.card__no { flex-shrink: 0; width: 15px; height: 15px; display: flex; align-items: center;',
    '  justify-content: center; border-radius: 999px; background: ' + COPPER + '; color: #fff;',
    '  font: 700 9.5px/1 ' + FONT + '; }',
    '.crumb { display: flex; align-items: center; gap: 1px; min-width: 0; overflow-x: auto; scrollbar-width: none; }',
    '.crumb::-webkit-scrollbar { display: none; }',
    '.crumb__seg { flex-shrink: 0; padding: 2px 5px; border: 0; border-radius: 5px; background: transparent;',
    '  color: #8e8e96; font-family: ' + MONO + '; font-size: 10px; white-space: nowrap; cursor: pointer;',
    '  transition: background-color 110ms ease, color 110ms ease; }',
    '.crumb__seg:hover { background: rgba(255,255,255,0.08); color: #e8e8ea; }',
    '.crumb__seg.is-on { background: rgba(194,114,76,0.18); color: ' + COPPER_LIT + '; cursor: default; }',
    '.crumb__sep { flex-shrink: 0; color: #6e6e76; font-size: 9px; }',
    '.card textarea { display: block; width: 100%; resize: none; min-height: 56px;',
    '  border: 0.5px solid rgba(255,255,255,0.12); border-radius: 8px; background: rgba(255,255,255,0.06);',
    '  padding: 8px 9px; font-family: ' + FONT + '; font-size: 12.5px; line-height: 1.45; color: #f5f5f7; outline: none; }',
    '.card textarea::placeholder { color: #6e6e76; }',
    '.card textarea:focus { border-color: rgba(255,255,255,0.24); }',
    '.card__row { display: flex; align-items: center; gap: 8px; margin-top: 8px; }',
    '.card__hint { flex: 1; font-size: 10.5px; color: #8e8e96; }',
    '.card__hint kbd { font-family: ' + FONT + '; font-size: 10px; padding: 1px 4px; border-radius: 4px;',
    '  background: rgba(255,255,255,0.09); color: #b9b9c0; }',

    /* ---- The island: one floating home for the batch — how much is queued, where it lands,
       and the single send. It steps back while you type, and returns on hover. */
    '.island { position: fixed; left: 50%; bottom: 18px; transform: translateX(-50%); z-index: 7;',
    '  display: flex; flex-direction: column; width: max-content; max-width: calc(100vw - 32px);',
    '  pointer-events: auto; border-radius: 15px; overflow: hidden; background: rgba(28,28,32,0.97);',
    '  border: 0.5px solid rgba(255,255,255,0.12); box-shadow: 0 1px 2px rgba(0,0,0,0.3), 0 18px 44px rgba(0,0,0,0.5);',
    '  font-family: ' + FONT + '; color: #e8e8ea; animation: island-in 260ms ' + EASE + ';',
    '  transition: opacity 180ms ease, transform 220ms ' + EASE + '; }',
    '@keyframes island-in { from { opacity: 0; transform: translate(-50%, 14px) scale(0.96); } to { opacity: 1; transform: translateX(-50%); } }',
    '.island.is-shy { opacity: 0.34; transform: translateX(-50%) scale(0.97); }',
    '.island.is-shy:hover { opacity: 1; transform: translateX(-50%); }',
    '.bar { display: flex; align-items: center; gap: 10px; padding: 7px 8px; }',
    '.div { width: 1px; align-self: stretch; margin: 2px 0; background: rgba(255,255,255,0.1); }',
    /* with nothing queued the island says what the mode is for, rather than showing a dead 0 */
    '.hint { display: flex; align-items: center; gap: 7px; padding: 5px 4px 5px 8px; font-size: 12px; color: #b9b9c0; }',
    '.hint svg { width: 13px; height: 13px; flex-shrink: 0; color: #8e8e96; }',
    /* the count doubles as the disclosure for the list — one control, one place */
    '.count { display: flex; align-items: center; gap: 7px; padding: 5px 9px 5px 6px; border: 0;',
    '  border-radius: 8px; background: transparent; color: #e8e8ea; font: 500 12px/1 ' + FONT + ';',
    '  cursor: pointer; transition: background-color 120ms ease; }',
    '.count:hover { background: rgba(255,255,255,0.07); }',
    '.count__n { min-width: 19px; height: 19px; padding: 0 5px; display: flex; align-items: center;',
    '  justify-content: center; border-radius: 999px; background: ' + COPPER + '; color: #fff;',
    '  font: 700 11px/1 ' + FONT + '; font-variant-numeric: tabular-nums; }',
    '.count__chev { display: flex; width: 11px; height: 11px; color: #8e8e96; transition: transform 200ms ' + EASE + '; }',
    '.count__chev svg { width: 11px; height: 11px; }',
    '.island.is-open .count__chev { transform: rotate(180deg); }',
    /* the target, said up front — the same promise comment mode has always made */
    '.target { display: flex; align-items: center; gap: 6px; padding: 4px 10px; border-radius: 999px;',
    '  background: rgba(194,114,76,0.18); color: ' + COPPER_LIT + '; font-size: 11px; font-weight: 500;',
    '  white-space: nowrap; max-width: 230px; overflow: hidden; text-overflow: ellipsis; }',
    '.btn { display: inline-flex; align-items: center; justify-content: center; gap: 5px; padding: 6px 11px;',
    '  border-radius: 7px; border: 0.5px solid rgba(255,255,255,0.12); background: rgba(255,255,255,0.07);',
    '  color: #e8e8ea; font: 500 12px/1.2 ' + FONT + '; cursor: pointer; white-space: nowrap;',
    '  transition: background-color 100ms ease, transform 110ms ' + EASE + '; }',
    '.btn:hover { background: rgba(255,255,255,0.13); }',
    '.btn:active { transform: scale(0.97); }',
    /* The island is dark glass wherever it lands, so the primary carries the mark's own dark
       pair (--accent / --on-accent) rather than system blue — nothing else here is blue, and
       the page's CSS variables are not ours to read. */
    '.btn--pri { background: #eee0cd; color: #191b1f; border-color: transparent; font-weight: 600; }',
    '.btn--pri:hover { background: #f6ece0; }',
    '.btn--pri:disabled { opacity: 0.45; cursor: default; }',
    '.btn--ghost { background: transparent; border-color: transparent; color: #b9b9c0; }',
    '.kbd { margin-left: 5px; opacity: 0.7; font-size: 10.5px; }',
    '.x { width: 26px; height: 26px; padding: 0; display: flex; align-items: center; justify-content: center;',
    '  border: 0; border-radius: 7px; background: transparent; color: #8e8e96; cursor: pointer; }',
    '.x:hover { background: rgba(255,255,255,0.09); color: #e8e8ea; }',
    '.x svg { width: 13px; height: 13px; }',
    /* the batch as a document, in the order you left it */
    '.list { max-height: 244px; overflow-y: auto; padding: 4px 6px 8px;',
    '  border-top: 0.5px solid rgba(255,255,255,0.1); width: 100%; }',
    '.island:not(.is-open) .list { display: none; }',
    '.row { display: flex; gap: 9px; padding: 8px; border-radius: 9px; cursor: pointer; transition: background-color 110ms ease; }',
    '.row:hover { background: rgba(255,255,255,0.07); }',
    '.row__no { flex-shrink: 0; width: 18px; height: 18px; margin-top: 1px; display: flex; align-items: center;',
    '  justify-content: center; border-radius: 999px; background: ' + COPPER + '; color: #fff;',
    '  font: 700 10.5px/1 ' + FONT + '; font-variant-numeric: tabular-nums; }',
    '.row__body { flex: 1; min-width: 0; }',
    /* the island is as wide as its bar; a comment's line length is not, so it caps for reading */
    '.row__txt { max-width: 64ch; font-size: 12.5px; line-height: 1.45; color: #e8e8ea;',
    '  white-space: pre-wrap; word-break: break-word; }',
    '.row__sel { margin-top: 3px; font-family: ' + MONO + '; font-size: 10px; color: #8e8e96;',
    '  white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }',
    '.row__del { flex-shrink: 0; width: 22px; height: 22px; padding: 0; display: flex; align-items: center;',
    '  justify-content: center; border: 0; border-radius: 6px; background: transparent; color: #8e8e96;',
    '  cursor: pointer; opacity: 0; transition: opacity 110ms ease, background-color 110ms ease; }',
    '.row:hover .row__del { opacity: 1; }',
    '.row__del:hover { background: rgba(255,255,255,0.12); color: #e8e8ea; }',
    '.row__del svg { width: 12px; height: 12px; }',
    '.sent { display: flex; align-items: center; gap: 8px; padding: 9px 14px; font-size: 12.5px;',
    '  font-weight: 500; color: #e8e8ea; }',
    '.sent svg { width: 14px; height: 14px; color: #34c759; }',
    /* a rejected batch is a state, not a result — amber, and the bar comes straight back */
    '.sent--warn { color: #f0c674; }',
    '.spin { width: 12px; height: 12px; flex-shrink: 0; border-radius: 50%;',
    '  border: 1.5px solid rgba(255,255,255,0.22); border-top-color: ' + COPPER_LIT + ';',
    '  animation: synth-cm-spin 0.7s linear infinite; }',
    '@keyframes synth-cm-spin { to { transform: rotate(360deg); } }',
    '@media (prefers-reduced-motion: reduce) { .spin { animation: none; } }'
  ].join('\n');

  /* ------------------------------------------------------------------ state */

  var state = 'off';          // 'off' | 'pick' | 'card'
  var deferredTimer = null, deferredConfig = null;   // document-start: mount deferred
  var cfg = { targetLabel: '' };
  var hostEl = null, root = null, veil = null, hiBox = null, chip = null;
  var scopeBox = null, layerEl = null, island = null, card = null, cardInput = null;
  var hoveredEl = null, lastPoint = null, needsHitTest = false;
  var rafId = 0, moveRafPending = false, sentTimer = null;
  var teardownFns = [];

  // A comment: { id, chain, level, fx, fy, url, text, snap, listed, anchor }
  var comments = [], seq = 0, activeId = null, listOpen = false, sending = false;
  var lastCount = 0;

  function on(target, type, fn, opts) {
    target.addEventListener(type, fn, opts);
    teardownFns.push(function () { target.removeEventListener(type, fn, opts); });
  }

  function isOurs(ev) {
    var path = ev.composedPath ? ev.composedPath() : [];
    return hostEl !== null && path.indexOf(hostEl) !== -1;
  }

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (ch) {
      return ch === '&' ? '&amp;' : ch === '<' ? '&lt;' : ch === '>' ? '&gt;'
        : ch === '"' ? '&quot;' : '&#39;';
    });
  }

  /* ------------------------------------------------------------ the comments */

  // An empty comment is not a comment — it is a composer someone opened. It holds a pin and a
  // number while it is being written, but it never counts, never lists, and never sends.
  function written(c) { return !!(c && c.text && c.text.trim()); }

  function queued() {
    var out = [];
    for (var i = 0; i < comments.length; i++) if (written(comments[i])) out.push(comments[i]);
    return out;
  }

  function byId(id) {
    for (var i = 0; i < comments.length; i++) if (comments[i].id === id) return comments[i];
    return null;
  }

  function numberOf(c) { return comments.indexOf(c) + 1; }
  function active() { return activeId ? byId(activeId) : null; }
  function targetOf(c) { return c.chain[c.level]; }

  // The host mirrors the queue (toolbar badge, menu state), so every change in what would
  // actually be sent is announced — including the drop back to nothing.
  function announceCount() {
    var n = queued().length;
    if (n === lastCount) return;
    lastCount = n;
    send({ type: 'batchCount', n: n });
  }

  // Every ancestor of the thing you hit, outermost first. This is a comment's whole vocabulary
  // of scope: "this button", "the row of buttons", "the section".
  function chainFor(el) {
    var chain = [];
    for (var cur = el; cur && cur.nodeType === 1; cur = cur.parentElement) chain.unshift(cur);
    return chain;
  }

  // The element's name as the page itself would give it.
  function shortName(el) {
    var t = el.tagName.toLowerCase();
    if (el.id) return t + '#' + el.id;
    var cls = (el.getAttribute && el.getAttribute('class') || '').trim().split(/\s+/);
    var last = cls[cls.length - 1];
    if (last) t += '.' + last;
    return t.length > 30 ? t.slice(0, 29) + '…' : t;
  }

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

  // Where the pin belongs right now, in viewport pixels, derived from the target element's
  // live box. Detached elements keep the last place their pin was seen.
  function anchorOf(c) {
    var el = targetOf(c);
    if (!el || !el.isConnected) return c.anchor || { x: 0, y: 0 };
    var r = el.getBoundingClientRect();
    c.anchor = { x: r.left + c.fx * r.width, y: r.top + c.fy * r.height };
    return c.anchor;
  }

  function addComment(el, x, y) {
    var chain = chainFor(el);
    if (!chain.length) return;
    var r = el.getBoundingClientRect();
    var c = {
      id: ++seq,
      chain: chain,
      level: chain.length - 1,
      fx: r.width ? (x - r.left) / r.width : 0.5,
      fy: r.height ? (y - r.top) / r.height : 0.5,
      url: location.href,
      text: '',
      snap: takeSnapshot(el),
      listed: false,
      anchor: { x: x, y: y }
    };
    comments.push(c);
    openComposer(c);
  }

  function removeComment(id) {
    var pin = pinFor(id);
    if (pin) pin.classList.add('is-going');
    for (var i = 0; i < comments.length; i++) {
      if (comments[i].id === id) { comments.splice(i, 1); break; }
    }
    if (activeId === id) { activeId = null; state = 'pick'; }
    announceCount();
    setTimeout(refresh, 120);
  }

  // Promote a comment to an ancestor (or back down). The pin must not move for it — you chose
  // that spot — so its fractions are re-derived against the element it now belongs to, and the
  // payload is re-snapshotted against the element the comment now means.
  function retarget(c, level) {
    if (level === c.level || level < 0 || level >= c.chain.length) return;
    var a = anchorOf(c);
    c.level = level;
    var el = targetOf(c);
    var r = el.getBoundingClientRect();
    c.fx = r.width ? (a.x - r.left) / r.width : 0.5;
    c.fy = r.height ? (a.y - r.top) / r.height : 0.5;
    c.snap = takeSnapshot(el);
    c.anchor = a;
    if (scopeBox) {
      scopeBox.classList.add('is-widening');
      setTimeout(function () { if (scopeBox) scopeBox.classList.remove('is-widening'); }, 220);
    }
    markCrumb(c);
    renderIsland();
    layout();
    focusComposer();
  }

  function openComposer(c) {
    activeId = c.id;
    state = 'card';
    clearHover();
    refresh();
    focusComposer();
  }

  // A comment you opened and left blank was never a comment — dropping it on close keeps the
  // queue honest about what will actually be sent.
  function closeComposer() {
    var c = active();
    if (c && !written(c)) {
      var i = comments.indexOf(c);
      if (i >= 0) comments.splice(i, 1);
    }
    activeId = null;
    if (state !== 'off') state = 'pick';
    announceCount();
    refresh();
  }

  // ⏎ ends the comment and leaves the batch open — the whole point is that it does not send.
  function queueActive() {
    var c = active();
    if (!c) return;
    if (!written(c)) { closeComposer(); return; }
    activeId = null;
    state = 'pick';
    announceCount();
    refresh();
  }

  /* --------------------------------------------------------------- rendering */

  function pinFor(id) { return layerEl ? layerEl.querySelector('.pin[data-id="' + id + '"]') : null; }

  function refresh() {
    if (state === 'off' || sending) return;
    renderPins();
    renderIsland();
    layout();
  }

  function renderPins() {
    if (!layerEl) return;
    layerEl.innerHTML = '';
    card = null; cardInput = null;
    layerEl.classList.toggle('is-focused', !!activeId);
    veil.setAttribute('data-mode', state === 'card' ? 'card' : 'pick');

    for (var i = 0; i < comments.length; i++) {
      layerEl.appendChild(buildPin(comments[i], i + 1));
    }
    var c = active();
    if (c) buildCard(c);
  }

  function buildPin(c, no) {
    var p = document.createElement('button');
    p.type = 'button';
    p.className = 'pin' + (written(c) ? '' : ' is-draft') + (activeId === c.id ? ' is-active' : '');
    p.setAttribute('data-id', c.id);
    p.textContent = no;
    p.addEventListener('click', function (ev) {
      ev.stopPropagation();
      dropPeek();
      if (activeId === c.id) closeComposer();
      else openComposer(c);
    });
    p.addEventListener('mouseenter', function () { if (activeId !== c.id && written(c)) peek(c, no); });
    p.addEventListener('mouseleave', dropPeek);
    return p;
  }

  function dropPeek() {
    if (!layerEl) return;
    var old = layerEl.querySelectorAll('.peek');
    for (var i = 0; i < old.length; i++) old[i].parentNode.removeChild(old[i]);
  }

  function peek(c, no) {
    dropPeek();
    if (!layerEl) return;
    var a = anchorOf(c);
    var el = document.createElement('div');
    el.className = 'peek';
    el.innerHTML = '<div class="peek__sel">' + no + ' · ' + esc(c.snap.selector) + '</div>' +
      '<div class="peek__txt">' + esc(c.text) + '</div>';
    el.style.left = (a.x + 16) + 'px';
    el.style.top = (a.y - 6) + 'px';
    layerEl.appendChild(el);
    if (el.getBoundingClientRect().right > window.innerWidth - 8) {
      el.style.left = Math.max(8, a.x - el.offsetWidth - 16) + 'px';
    }
  }

  function buildCard(c) {
    card = document.createElement('div');
    card.className = 'card';
    var crumb = '';
    for (var i = 0; i < c.chain.length; i++) {
      crumb += (i ? '<span class="crumb__sep">›</span>' : '') +
        '<button type="button" class="crumb__seg' + (i === c.level ? ' is-on' : '') +
        '" data-level="' + i + '">' + esc(shortName(c.chain[i])) + '</button>';
    }
    card.innerHTML = '<div class="card__sel"><span class="card__no">' + numberOf(c) + '</span>' +
      '<div class="crumb">' + crumb + '</div></div>' +
      '<textarea rows="3" placeholder="What\'s off here?" spellcheck="true"></textarea>' +
      '<div class="card__row"><span class="card__hint"><kbd>⏎</kbd> add · <kbd>⌥↑</kbd> widen</span>' +
      '<button type="button" class="btn btn--ghost" data-cm="drop">Discard</button>' +
      '<button type="button" class="btn" data-cm="add">Add</button></div>';
    layerEl.appendChild(card);

    cardInput = card.querySelector('textarea');
    cardInput.value = c.text;
    cardInput.addEventListener('input', function () { c.text = cardInput.value; syncDraft(c); });

    card.addEventListener('click', function (ev) {
      ev.stopPropagation();
      var seg = ev.target.closest ? ev.target.closest('[data-level]') : null;
      if (seg) { retarget(c, Number(seg.getAttribute('data-level'))); return; }
      var btn = ev.target.closest ? ev.target.closest('[data-cm]') : null;
      if (!btn) return;
      if (btn.getAttribute('data-cm') === 'drop') { c.text = ''; closeComposer(); }
      else queueActive();
    });
    // Keep typed keys inside the composer (page shortcut handlers must not fire while commenting).
    card.addEventListener('keydown', onCardKey);
    card.addEventListener('keyup', function (ev) { ev.stopPropagation(); });
    card.addEventListener('keypress', function (ev) { ev.stopPropagation(); });

    markCrumb(c);
  }

  // The path scrolls the least it can to keep the current target in view — on open that is the
  // element you hit, after widening it is wherever you climbed to.
  function markCrumb(c) {
    if (!card) return;
    var segs = card.querySelectorAll('.crumb__seg');
    for (var i = 0; i < segs.length; i++) segs[i].classList.toggle('is-on', i === c.level);
    var cr = card.querySelector('.crumb'), on = segs[c.level];
    if (cr && on) {
      cr.scrollLeft = Math.min(
        Math.max(cr.scrollLeft, on.offsetLeft + on.offsetWidth - cr.clientWidth + 4),
        on.offsetLeft - 4);
    }
  }

  function focusComposer() {
    if (!cardInput) return;
    var ta = cardInput;
    requestAnimationFrame(function () {
      try { ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length); } catch (e) {}
    });
  }

  // The first character makes a draft into a comment (and deleting the last takes it back).
  // Only that transition redraws the island; the rest is an in-place text update, because a
  // full render would tear out the textarea under the cursor.
  function syncDraft(c) {
    var has = written(c);
    var pin = pinFor(c.id);
    if (pin) pin.classList.toggle('is-draft', !has);
    if (has !== c.listed) {
      c.listed = has;
      announceCount();
      renderIsland();
      return;
    }
    var row = island && island.querySelector('.row[data-id="' + c.id + '"] .row__txt');
    if (row) row.textContent = c.text;
  }

  /* ---------------------------------------------------------------- geometry */

  function elementLabel(el) {
    var t = el.tagName.toLowerCase();
    if (el.id) t += '#' + el.id;
    var cls = (typeof el.className === 'string' ? el.className : '').trim().split(/\s+/);
    for (var i = 0; i < Math.min(cls.length, 2); i++) if (cls[i]) t += '.' + cls[i];
    if (t.length > 48) t = t.slice(0, 47) + '…';
    return t;
  }

  function hideHighlight() {
    if (hiBox) hiBox.style.display = 'none';
    if (chip) chip.style.display = 'none';
  }

  function positionHighlight(el) {
    if (!el || !el.isConnected) { hideHighlight(); return; }
    var r = el.getBoundingClientRect();
    hiBox.style.display = 'block';
    hiBox.style.left = (r.left - 1.5) + 'px';
    hiBox.style.top = (r.top - 1.5) + 'px';
    hiBox.style.width = Math.max(r.width, 0) + 'px';
    hiBox.style.height = Math.max(r.height, 0) + 'px';

    chip.style.display = 'block';
    chip.innerHTML = '';
    chip.appendChild(document.createTextNode(elementLabel(el)));
    var dims = document.createElement('span');
    dims.className = 'chip__dims';
    dims.textContent = Math.round(r.width) + '×' + Math.round(r.height);
    chip.appendChild(dims);
    var top = r.top - 26;
    if (top < 6) top = Math.min(r.bottom + 6, window.innerHeight - 28);
    chip.style.left = Math.max(6, Math.min(r.left, window.innerWidth - chip.offsetWidth - 6)) + 'px';
    chip.style.top = top + 'px';
  }

  function setBox(el, l, t, w, h) {
    if (el.__l === l && el.__t === t && el.__w === w && el.__h === h) return;
    el.__l = l; el.__t = t; el.__w = w; el.__h = h;
    el.style.left = l + 'px'; el.style.top = t + 'px';
    if (w != null) { el.style.width = w + 'px'; el.style.height = h + 'px'; }
  }

  // The composer opens beside its pin, folding to the other side / above rather than running
  // off the viewport — and never over the island it is about to feed.
  function positionCard(c) {
    var a = anchorOf(c);
    var w = card.offsetWidth || 300, h = card.offsetHeight || 150;
    var vw = window.innerWidth, vh = window.innerHeight, pad = 10, floor = vh - 76;
    var left = a.x + 18, top = a.y - 10;
    if (left + w > vw - 12) left = a.x - w - 18;
    if (top + h > floor) top = a.y - h - 12;
    setBox(card, Math.max(pad, Math.min(left, vw - w - pad)), Math.max(pad, top));
  }

  function layout() {
    if (state === 'off' || !layerEl) return;
    var c = active();
    if (c && targetOf(c) && targetOf(c).isConnected) {
      var r = targetOf(c).getBoundingClientRect();
      scopeBox.style.display = 'block';
      setBox(scopeBox, r.left - 1.5, r.top - 1.5, Math.max(r.width, 0), Math.max(r.height, 0));
    } else {
      scopeBox.style.display = 'none';
    }
    for (var i = 0; i < comments.length; i++) {
      var pin = pinFor(comments[i].id);
      if (!pin) continue;
      var a = anchorOf(comments[i]);
      setBox(pin, a.x, a.y);
    }
    if (c && card) positionCard(c);
  }

  /* ------------------------------------------------------------------ island */

  function renderIsland() {
    if (!island) return;
    var q = queued(), n = q.length;
    island.className = 'island' + (listOpen && n ? ' is-open' : '') + (activeId ? ' is-shy' : '');
    if (sending) {
      island.className = 'island';
      island.innerHTML = '<div class="sent"><span class="spin"></span><span>Sending ' + n + ' ' +
        (n === 1 ? 'comment' : 'comments') + '\u2026</span></div>';
      return;
    }
    var label = esc(cfg.targetLabel || 'Claude');
    var word = n === 1 ? 'comment' : 'comments';
    var head = n
      ? '<button type="button" class="count" data-cm="list"><span class="count__n">' + n + '</span>' +
        '<span>' + word + '</span><span class="count__chev">' + ICON_CHEV + '</span></button>'
      : '<span class="hint">' + ICON_PIN + 'Click anything to comment</span>';
    island.innerHTML = '<div class="bar">' + head +
      '<div class="div"></div><span class="target">→ ' + label + '</span>' +
      '<button type="button" class="btn btn--pri" data-cm="send"' + (n ? '' : ' disabled') + '>Send ' +
      (n || '') + '<span class="kbd">⌘⌥⏎</span></button>' +
      '<button type="button" class="x" data-cm="off" aria-label="Exit comment mode">' + ICON_X + '</button>' +
      '</div>' + (n ? listHTML() : '');
    wireIsland();
  }

  // Numbered off the full array, so a row's number is the number on its pin even while an
  // unwritten draft sits between them.
  function listHTML() {
    var rows = '';
    for (var i = 0; i < comments.length; i++) {
      var c = comments[i];
      if (!written(c)) continue;
      rows += '<div class="row" data-id="' + c.id + '"><span class="row__no">' + (i + 1) + '</span>' +
        '<div class="row__body"><div class="row__txt">' + esc(c.text) + '</div>' +
        '<div class="row__sel">' + esc(c.snap.selector) + '</div></div>' +
        '<button type="button" class="row__del" aria-label="Remove comment">' + ICON_X + '</button></div>';
    }
    return '<div class="list">' + rows + '</div>';
  }

  function wireIsland() {
    var btns = island.querySelectorAll('[data-cm]');
    for (var i = 0; i < btns.length; i++) {
      btns[i].addEventListener('click', function (ev) {
        ev.stopPropagation();
        var a = this.getAttribute('data-cm');
        if (a === 'list') { listOpen = !listOpen; renderIsland(); }
        else if (a === 'send') doSend();
        else if (a === 'off') doExit(true);
      });
    }
    var rows = island.querySelectorAll('.row');
    for (var r = 0; r < rows.length; r++) {
      (function (row) {
        var id = Number(row.getAttribute('data-id'));
        row.addEventListener('mouseenter', function () {
          var p = pinFor(id);
          if (!p) return;
          p.classList.remove('is-lit');
          void p.offsetWidth;
          p.classList.add('is-lit');
        });
        row.addEventListener('click', function (ev) {
          ev.stopPropagation();
          if (ev.target.closest && ev.target.closest('.row__del')) return;
          var c = byId(id);
          if (c) openComposer(c);
        });
        var del = row.querySelector('.row__del');
        if (del) del.addEventListener('click', function (ev) { ev.stopPropagation(); removeComment(id); });
      })(rows[r]);
    }
  }

  /* -------------------------------------------------------------------- send */

  function buildCommentPayload(c, i) {
    var el = targetOf(c);
    var r = (el && el.isConnected) ? el.getBoundingClientRect() : c.snap.freezeRect;
    return {
      n: i + 1,
      comment: c.text,
      url: c.url,
      onCurrentPage: c.url === location.href,
      selector: c.snap.selector,
      xpath: c.snap.xpath,
      elementHTML: c.snap.elementHTML,
      elementText: c.snap.elementText,
      reactSource: c.snap.reactSource,
      rect: {
        x: r.x, y: r.y, width: r.width, height: r.height,
        scrollX: window.scrollX, scrollY: window.scrollY,
        dpr: window.devicePixelRatio
      }
    };
  }

  // One delivery for the whole pass. A blank composer standing open is not the batch, so it is
  // dropped rather than sent as an empty comment.
  function doSend() {
    if (state === 'off' || sending) return;
    var batch = queued();
    if (!batch.length) return;
    comments = batch;
    activeId = null;
    state = 'pick';

    var payload = [];
    for (var i = 0; i < comments.length; i++) payload.push(buildCommentPayload(comments[i], i));
    send({
      type: 'commentBatch',
      url: location.href,
      title: document.title,
      viewport: { width: window.innerWidth, height: window.innerHeight, dpr: window.devicePixelRatio },
      comments: payload
    });
    // The batch stays on the page — pins, text and all — until the host confirms it landed.
    // A delivery can fail on the last rung (the target session never reports live), and a
    // batch cleared on the way out would be gone from both sides. So no batchCount 0 here,
    // no pins flying out, and no exit: doConfirm/doReject own that.
    sending = true;
    listOpen = false;
    renderIsland();
  }

  /* Delivery landed. Now the batch may go. */
  function doConfirm(label) {
    if (state === 'off' || !hostEl || !sending) return;
    sending = false;
    var count = comments.length;
    if (!count) return;
    lastCount = 0;
    send({ type: 'batchCount', n: 0 });
    var pins = layerEl.querySelectorAll('.pin');
    for (var p = 0; p < pins.length; p++) {
      (function (pin, k) { setTimeout(function () { pin.classList.add('is-going'); }, k * 45); })(pins[p], p);
    }
    island.className = 'island';
    island.innerHTML = '<div class="sent">' + ICON_TICK + '<span>' + count + ' ' +
      (count === 1 ? 'comment' : 'comments') + ' sent to ' + esc(label || cfg.targetLabel || 'Claude') + '</span></div>';
    sentTimer = setTimeout(function () { sentTimer = null; comments = []; doExit(true); }, SENT_MS);
  }

  /* Delivery never happened. Hand the batch back exactly as it was and say why — a comment
     nobody received is still a comment somebody wrote. */
  function doReject(why) {
    if (state === 'off' || !hostEl || !sending) return;   // nothing in flight, nothing to hand back
    sending = false;
    renderPins();
    layout();
    if (!why) { renderIsland(); return; }
    // Say why in the island itself — it is the thing that claimed to be sending — then hand
    // the bar straight back with the batch still counted.
    var n = comments.length;
    island.className = 'island';
    island.innerHTML = '<div class="sent sent--warn"><span>' + esc(why) + ' \u2014 ' + n + ' ' +
      (n === 1 ? 'comment' : 'comments') + ' kept</span></div>';
    if (sentTimer) clearTimeout(sentTimer);
    sentTimer = setTimeout(function () { sentTimer = null; renderIsland(); }, 2600);
  }

  /* --------------------------------------------------------------- hit test */

  function hitTest(x, y) {
    var els = document.elementsFromPoint(x, y);
    for (var i = 0; i < els.length; i++) {
      if (els[i] !== hostEl) return els[i];
    }
    return null;
  }

  function clearHover() { hoveredEl = null; hideHighlight(); }

  function updateHover() {
    if (state !== 'pick' || !lastPoint) return;
    hoveredEl = hitTest(lastPoint.x, lastPoint.y);
    positionHighlight(hoveredEl);
  }

  /* ------------------------------------------------------------ frame loop */

  function frame() {
    if (state === 'off') return;
    if (state === 'pick' && !sending) {
      if (needsHitTest) { needsHitTest = false; updateHover(); }
      else if (hoveredEl) positionHighlight(hoveredEl); // stay glued through mutation/animation
    } else {
      hideHighlight();
    }
    layout();                                          // pins ride scroll, resize and zoom
    rafId = requestAnimationFrame(frame);
  }

  /* ---------------------------------------------------------------- events */

  function onVeilMove(ev) {
    lastPoint = { x: ev.clientX, y: ev.clientY };
    if (state !== 'pick' || moveRafPending) return;
    moveRafPending = true;
    requestAnimationFrame(function () { moveRafPending = false; updateHover(); });
  }

  function onVeilClick(ev) {
    ev.preventDefault();
    ev.stopPropagation();
    if (sending) return;
    lastPoint = { x: ev.clientX, y: ev.clientY };
    if (state === 'card') closeComposer();   // clicking away discards a blank draft
    var el = hitTest(ev.clientX, ev.clientY);
    if (el) addComment(el, ev.clientX, ev.clientY);
  }

  function onCardKey(ev) {
    ev.stopPropagation();
    var c = active();
    if (!c) return;
    if (ev.key === 'Enter' && !ev.shiftKey && !ev.metaKey && !ev.ctrlKey) {
      ev.preventDefault();
      queueActive();
    } else if (ev.altKey && ev.key === 'ArrowUp') {
      ev.preventDefault();
      retarget(c, c.level - 1);
    } else if (ev.altKey && ev.key === 'ArrowDown') {
      ev.preventDefault();
      retarget(c, c.level + 1);
    }
  }

  // Esc unwinds one layer at a time: the open composer, then the batch list, then the mode.
  function onKeyDown(ev) {
    if (state === 'off') return;
    if (ev.key === 'Escape') {
      ev.preventDefault();
      ev.stopImmediatePropagation();
      if (sending) return;
      if (state === 'card') closeComposer();
      else if (listOpen) { listOpen = false; renderIsland(); }
      else doExit(true);
      return;
    }
    if (ev.key === 'Enter' && ev.altKey && (ev.metaKey || ev.ctrlKey)) {
      ev.preventDefault();
      ev.stopImmediatePropagation();
      if (state === 'card') queueActive();
      doSend();
    }
  }

  // Backup suppressor: any mouse event that somehow bypasses the veil while commenting must not
  // reach the page's handlers (capture phase; preventDefault on click only).
  function onSuppress(ev) {
    if (state === 'off' || isOurs(ev)) return;
    ev.stopImmediatePropagation();
    if (ev.type === 'click') ev.preventDefault();
  }

  // The veil's own press events must never bubble to the page's document-level handlers
  // (onSuppress treats them as "ours" and lets them through). pointerdown skips preventDefault
  // so the browser still synthesizes the click the picker runs on.
  function onVeilPress(ev) {
    ev.stopPropagation();
    if (ev.type !== 'pointerdown') ev.preventDefault();
  }

  function onScroll() { needsHitTest = true; }

  /* ------------------------------------------------------------------ mount */

  // The pin's ring is the page's own background, so it reads as cut out of the page rather
  // than stamped on top of it.
  function pageBackground() {
    var els = [document.body, document.documentElement];
    for (var i = 0; i < els.length; i++) {
      if (!els[i]) continue;
      var bg = '';
      try { bg = window.getComputedStyle(els[i]).backgroundColor; } catch (e) {}
      if (bg && bg !== 'transparent' && bg.replace(/\s/g, '') !== 'rgba(0,0,0,0)') return bg;
    }
    return '#ffffff';
  }

  function buildUI() {
    hostEl = document.createElement('div');
    hostEl.setAttribute(HOST_ATTR, '');
    hostEl.style.cssText = 'all: initial; position: fixed; inset: 0; z-index: ' + MAX_Z +
      '; pointer-events: none;';
    hostEl.style.setProperty('display', 'block', 'important');
    root = hostEl.attachShadow({ mode: 'closed' });

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

    scopeBox = document.createElement('div');
    scopeBox.className = 'scope';
    root.appendChild(scopeBox);

    layerEl = document.createElement('div');
    layerEl.className = 'layer';
    layerEl.style.setProperty('--ring', pageBackground());
    root.appendChild(layerEl);

    island = document.createElement('div');
    island.className = 'island';
    root.appendChild(island);

    document.documentElement.appendChild(hostEl);
    teardownFns.push(function () { if (hostEl && hostEl.parentNode) hostEl.parentNode.removeChild(hostEl); });
  }

  /* ---------------------------------------------------------- enter / exit */

  function stopDeferred() {
    if (deferredTimer) { clearInterval(deferredTimer); deferredTimer = null; }
    deferredConfig = null;
  }

  function domReady() { return !!(document.documentElement && document.body); }

  function doEnter(config) {
    config = config || {};
    if (state !== 'off') {
      cfg.targetLabel = config.targetLabel != null ? String(config.targetLabel) : cfg.targetLabel;
      renderIsland();
      return;
    }
    // Injected via Page.addScriptToEvaluateOnNewDocument this runs at document-start,
    // when documentElement/body may not exist yet — mounting now would throw and leave
    // the overlay absent for the whole document. Defer until the DOM can host it;
    // enter() stays idempotent while the wait is pending (the config just refreshes).
    if (!domReady()) {
      deferredConfig = config;
      if (deferredTimer) return;
      var tryMount = function () {
        if (!deferredConfig) return;
        if (state !== 'off') { stopDeferred(); return; }
        if (!domReady()) return;
        var pending = deferredConfig;
        stopDeferred();
        doEnter(pending);
      };
      deferredTimer = setInterval(tryMount, 50);
      document.addEventListener('DOMContentLoaded', tryMount, { once: true });
      return;
    }
    stopDeferred();
    cfg.targetLabel = config.targetLabel != null ? String(config.targetLabel) : '';
    comments = []; seq = 0; activeId = null; listOpen = false; sending = false; lastCount = 0;
    buildUI();
    state = 'pick';

    on(veil, 'mousemove', onVeilMove);
    on(veil, 'click', onVeilClick);
    var veilPress = ['pointerdown', 'pointerup', 'mousedown', 'mouseup', 'dblclick', 'auxclick'];
    for (var v = 0; v < veilPress.length; v++) on(veil, veilPress[v], onVeilPress);
    on(window, 'keydown', onKeyDown, true);
    on(window, 'scroll', onScroll, { capture: true, passive: true });
    on(window, 'resize', onScroll, { passive: true });
    var types = ['pointerdown', 'pointerup', 'mousedown', 'mouseup', 'click', 'dblclick', 'auxclick'];
    for (var i = 0; i < types.length; i++) on(window, types[i], onSuppress, true);

    if (config.debug) installDebug();

    refresh();
    rafId = requestAnimationFrame(frame);
  }

  function teardown() {
    state = 'off';
    if (rafId) { cancelAnimationFrame(rafId); rafId = 0; }
    if (sentTimer) { clearTimeout(sentTimer); sentTimer = null; }
    while (teardownFns.length) {
      try { teardownFns.pop()(); } catch (e) {}
    }
    hostEl = root = veil = hiBox = chip = scopeBox = layerEl = island = card = cardInput = null;
    hoveredEl = lastPoint = null;
    comments = []; activeId = null; listOpen = false; sending = false;
    moveRafPending = false; needsHitTest = false;
    try { delete window.__synthOverlayDebug; } catch (e) {}
  }

  function doExit(notifyHost) {
    stopDeferred();               // exit during a deferred (pre-DOM) mount cancels it
    if (state === 'off') return;
    var hadQueue = lastCount !== 0;
    teardown();
    if (notifyHost) {
      if (hadQueue) { lastCount = 0; send({ type: 'batchCount', n: 0 }); }
      send({ type: 'exitMode' });
    }
    lastCount = 0;
  }

  /* ------------------------------------------------------------ debug hooks
     Test-only introspection (the shadow root is closed); created only when
     enter({ debug: true }) is passed. The host never passes debug. */
  function installDebug() {
    window.__synthOverlayDebug = {
      get state() { return state; },
      get root() { return root; },
      get hoveredTag() { return hoveredEl ? hoveredEl.tagName.toLowerCase() : null; },
      get highlightRect() {
        if (!hiBox || hiBox.style.display === 'none') return null;
        var r = hiBox.getBoundingClientRect();
        return { x: r.x, y: r.y, width: r.width, height: r.height };
      },
      get cardOpen() { return state === 'card'; },
      get cardRect() {
        if (!card) return null;
        var r = card.getBoundingClientRect();
        return { x: r.x, y: r.y, width: r.width, height: r.height };
      },
      get listOpen() { return listOpen; },
      get sending() { return sending; },
      get inFlight() { return sending; },
      get queuedCount() { return queued().length; },
      get islandText() { return island ? island.textContent.replace(/\s+/g, ' ').trim() : null; },
      get comments() {
        var out = [];
        for (var i = 0; i < comments.length; i++) {
          var c = comments[i], a = anchorOf(c);
          out.push({
            n: i + 1, id: c.id, text: c.text, selector: c.snap.selector, level: c.level,
            chain: c.chain.length, fx: c.fx, fy: c.fy, x: a.x, y: a.y, url: c.url
          });
        }
        return out;
      },
      get pendingSendCount() { return pendingSends.length; }
    };
  }

  window.__synthOverlay = {
    __synthCommentOverlay: true,
    enter: function (config) { try { doEnter(config); } catch (e) { console.warn('[synth-overlay] enter failed:', e); } },
    exit: function () { try { doExit(true); } catch (e) { console.warn('[synth-overlay] exit failed:', e); } },
    send: function () { try { doSend(); } catch (e) { console.warn('[synth-overlay] send failed:', e); } },
    // The host's answer to a batch. Until one of these lands the comments stay on the page.
    confirm: function (label) { try { doConfirm(label); } catch (e) { console.warn('[synth-overlay] confirm failed:', e); } },
    reject: function (why) { try { doReject(why); } catch (e) { console.warn('[synth-overlay] reject failed:', e); } }
  };
})();
