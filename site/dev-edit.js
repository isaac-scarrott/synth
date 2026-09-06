/* Inline copy editing, injected by devserver.py and never present in the published page.

   Each editable element remembers the exact innerHTML it was served with. That string is
   what the server searches for, so an edit is unambiguous without index.html carrying ids
   for the benefit of a dev tool. */
(() => {
  if (!/^(localhost|127\.0\.0\.1)$/.test(location.hostname)) return;

  var SEL = [
    'main h1 span', 'main h2', 'main h3', 'main p',
    'main dd', 'main .card__t', 'main .card__s', 'main .legend__r',
    'main .island__note', 'main .chord', 'footer p', 'footer .foot'
  ].join(', ');

  var served = new WeakMap();
  var els = [].slice.call(document.querySelectorAll(SEL)).filter(function (el) {
    return !el.querySelector(SEL);          // leaf copy only, never a wrapper
  });
  els.forEach(function (el) { served.set(el, el.innerHTML); });

  var style = document.createElement('style');
  style.textContent =
    '[data-edit]{outline:1px dashed rgba(241,221,215,.28);outline-offset:4px;border-radius:3px}' +
    '[data-edit]:hover{outline-color:rgba(241,221,215,.5)}' +
    '[data-edit]:focus{outline:1px solid var(--accent,#f1ddd7);outline-offset:4px}' +
    '[data-edit-dirty]{outline-color:#7ea6dc !important}' +
    '#devbar{position:fixed;right:16px;bottom:16px;z-index:9999;display:flex;gap:8px;align-items:center;' +
    'font:500 12px/1 ui-sans-serif,system-ui;color:#f1ddd7}' +
    '#devbar button{font:inherit;padding:8px 12px;border-radius:8px;border:1px solid rgba(255,255,255,.16);' +
    'background:rgba(20,22,26,.9);color:inherit;cursor:pointer;backdrop-filter:blur(12px)}' +
    '#devbar button[aria-pressed="true"]{background:#f1ddd7;color:#14161a;border-color:transparent}' +
    '#devtoast{position:fixed;left:50%;bottom:20px;transform:translateX(-50%);z-index:9999;max-width:min(560px,90vw);' +
    'padding:10px 14px;border-radius:8px;font:500 12.5px/1.45 ui-sans-serif,system-ui;opacity:0;' +
    'transition:opacity .18s ease-out;pointer-events:none;background:rgba(20,22,26,.95);color:#f1ddd7;' +
    'border:1px solid rgba(255,255,255,.16)}' +
    '#devtoast[data-bad]{background:#3a1714;color:#ffcfc9;border-color:#7a2b23}' +
    '#devtoast.show{opacity:1}';
  document.head.appendChild(style);

  var bar = document.createElement('div');
  bar.id = 'devbar';
  bar.innerHTML = '<button type="button" aria-pressed="false">Edit copy</button>';
  document.body.appendChild(bar);
  var toggle = bar.querySelector('button');

  var toast = document.createElement('div');
  toast.id = 'devtoast';
  document.body.appendChild(toast);
  var toastTimer;
  function say(msg, bad) {
    toast.textContent = msg;
    if (bad) toast.setAttribute('data-bad', ''); else toast.removeAttribute('data-bad');
    toast.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toast.classList.remove('show'); }, bad ? 6000 : 1800);
  }

  var editing = false;
  function setEditing(on) {
    editing = on;
    toggle.setAttribute('aria-pressed', String(on));
    toggle.textContent = on ? 'Editing — click to stop' : 'Edit copy';
    els.forEach(function (el) {
      if (on) { el.setAttribute('data-edit', ''); el.contentEditable = 'true'; el.spellcheck = true; }
      else { el.removeAttribute('data-edit'); el.contentEditable = 'false'; }
    });
    // reveal-on-scroll leaves unseen sections invisible; editing needs all of it reachable
    if (on) document.querySelectorAll('.rev').forEach(function (r) { r.classList.add('in'); });
  }
  toggle.addEventListener('click', function () { setEditing(!editing); });

  function save(el) {
    var before = served.get(el), after = el.innerHTML;
    if (before === after) return Promise.resolve();
    return fetch('/__save', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ original: before, updated: after, tag: el.tagName.toLowerCase() })
    })
      .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, body: j }; }); })
      .then(function (res) {
        if (!res.ok || !res.body.ok) {
          el.removeAttribute('data-edit-dirty');
          say(res.body.error || 'save failed', true);
          return;
        }
        served.set(el, after);
        el.removeAttribute('data-edit-dirty');
        say('saved to index.html');
      })
      .catch(function (e) { say('save failed: ' + e.message, true); });
  }

  document.addEventListener('input', function (e) {
    var el = e.target.closest('[data-edit]');
    if (el) el.setAttribute('data-edit-dirty', '');
  });

  document.addEventListener('blur', function (e) {
    var el = e.target.closest && e.target.closest('[data-edit]');
    if (el) save(el);
  }, true);

  document.addEventListener('keydown', function (e) {
    if (e.altKey && e.code === 'KeyE') { e.preventDefault(); setEditing(!editing); return; }
    if (!editing) return;
    if ((e.metaKey || e.ctrlKey) && e.key === 's') {
      e.preventDefault();
      var dirty = document.querySelectorAll('[data-edit-dirty]');
      if (!dirty.length) return say('nothing changed');
      Promise.all([].map.call(dirty, save));
      return;
    }
    if (e.key === 'Enter' && e.target.closest('[data-edit]')) e.preventDefault();
    if (e.key === 'Escape' && e.target.closest('[data-edit]')) {
      var el = e.target.closest('[data-edit]');
      el.innerHTML = served.get(el);
      el.removeAttribute('data-edit-dirty');
      el.blur();
      say('reverted');
    }
  });

  // paste as text, so a copy out of a doc doesn't drag styling into the file
  document.addEventListener('paste', function (e) {
    if (!e.target.closest || !e.target.closest('[data-edit]')) return;
    e.preventDefault();
    document.execCommand('insertText', false, (e.clipboardData || window.clipboardData).getData('text'));
  });

  // links would navigate away mid-edit
  document.addEventListener('click', function (e) {
    if (editing && e.target.closest('[data-edit] a, a [data-edit]')) e.preventDefault();
  });

  // ── live reload ──────────────────────────────────────────────────────────
  // Reloading mid-sentence would throw away what you were typing, so an edit in
  // progress defers the reload until you stop rather than cancelling it.
  var pendingReload = false;

  function scrollKey() { return 'dev:scroll:' + location.pathname; }
  try {
    var back = sessionStorage.getItem(scrollKey());
    if (back !== null) { sessionStorage.removeItem(scrollKey()); window.scrollTo(0, +back); }
  } catch (e) {}

  function reload() {
    try { sessionStorage.setItem(scrollKey(), String(window.scrollY)); } catch (e) {}
    location.reload();
  }

  function reloadWhenSafe() {
    var busy = editing && document.querySelector('[data-edit-dirty]');
    if (!busy) return reload();
    if (pendingReload) return;
    pendingReload = true;
    say('index.html changed on disk, reloading when you stop typing');
  }

  var src = new EventSource('/__events');
  src.onmessage = function (e) { if (e.data && e.data !== 'ping') reloadWhenSafe(); };
  src.onerror = function () { /* the server went away; EventSource retries on its own */ };

  // once the last edit is saved, take the reload that was waiting
  var wasSave = save;
  save = function (el) {
    return wasSave(el).then(function (r) {
      if (pendingReload && !document.querySelector('[data-edit-dirty]')) reload();
      return r;
    });
  };

  console.log('[dev] copy editing — ⌥E to toggle, ⌘S to save, Esc to revert. Live reload on.');
})();
