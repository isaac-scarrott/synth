// Placeholder overlay (ADR-0011 stage three). The real selection/comment overlay is a
// parallel slice that replaces this file's content at the SAME path with the SAME surface:
//   window.__synthOverlay = { enter(cfg), exit() }   // cfg: { targetLabel: string }
// The page reports back by calling window.__synthComment(JSON.stringify(payload)) — the
// host binds that name via Runtime.addBinding before injecting this script.
(() => {
  if (window.__synthOverlay) return;
  window.__synthOverlay = {
    enter(cfg) {
      console.log("[synth] comment mode active (stub overlay)",
                  cfg && cfg.targetLabel ? "→ " + cfg.targetLabel : "");
    },
    exit() {
      console.log("[synth] comment mode exit (stub overlay)");
    },
  };
})();
