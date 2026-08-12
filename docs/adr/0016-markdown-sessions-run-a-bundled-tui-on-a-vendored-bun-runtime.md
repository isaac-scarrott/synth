# Markdown sessions run a bundled TUI on a vendored Bun runtime

Agents write markdown constantly — plans, TODO lists, findings, reports — and Synth had nowhere to put
it. A clicked `.md` link left the app entirely, for whatever has claimed the extension on that Mac. This
ADR commits to what a markdown session *is*, and to the one choice everything downstream rests on:
**Synth ships a JavaScript runtime**.

## The document surface is a TUI in a ghostty session, not a native SwiftUI view

A markdown row is a terminal session whose launch command is fixed, exactly like an agent row
(`SYNTH_LAUNCH_COMMAND`, `TerminalManager`). The pane is the same libghostty surface every other session
uses, so PTY lifecycle, process reaping, focus, theming, selection and the child-exited signal that
closes a row all come free and stay in step with the rest of the app by construction.

The obvious alternative — render markdown natively in SwiftUI — was rejected on the *editor*, not the
viewer. A viewer would have been straightforward. But the locked scope is Obsidian-style live preview:
click into a block and it becomes raw source with a cursor, click away and it re-renders. That is a text
editor with block-level reveal, and building one in SwiftUI means owning caret placement, word-wrap-aware
motion, selection, undo, and IME — a body of work with no end, for a surface that is not what Synth is
about. The TUI route gets a mature editing core (`TextareaRenderable`) and tree-sitter highlighting off
the shelf, and confines our work to the part that is actually ours: the block model and the reveal seam.

The cost is honest and worth naming. Text renders as terminal cells, so there is no proportional type, no
sub-pixel layout, and image support is whatever the terminal's graphics protocol gives. Within a terminal
grid it can still be beautiful — a centred column, real margins, concealed markers — and it sits beside
the agent that wrote the document, which is the point.

## The runtime is OpenTUI, and it is vendored whole

The TUI is built on `@opentui/core` — the Zig + TypeScript engine behind opencode. It brings a real
layout engine (Yoga), a native renderer, tree-sitter highlighting, and an edit buffer with the CUA
behaviours the brief calls table stakes.

That means Synth needs a JavaScript runtime, and **the user's machine cannot be asked for one**. Synth's
existing MCP servers do lean on the user's node (`MCPInstaller.resolveNpm`), and that is exactly the
precedent not to repeat here: an MCP server that cannot start degrades a capability an agent may not
reach for, while a markdown session that cannot start is a broken row in the sidebar. So the runtime
ships: `md/vendor/fetch-bun.sh` fetches Bun, `md/build.ts` bundles the TUI to one file and stages
OpenTUI's assets, and `stage_resources` copies all of it into `Contents/Resources/md`.

**The Bun version is load-bearing, and its failure is silent.** OpenTUI highlights markdown through a
tree-sitter worker whose message bridge is selected by `process.getBuiltinModule`, which arrived in Bun
1.3. On Bun 1.2.4 the bridge never registers: the worker starts, answers nothing, initialization times
out after ten seconds, and **every paragraph renders blank** while tables and code fences still draw. It
presents as a styling bug, not a crash. The fetch script pins the version and says why, because the next
person to bump it will not otherwise connect the symptom to the cause.

Relocation out of `node_modules` is a supported path, not a hack: `OTUI_ASSET_ROOT` makes OpenTUI resolve
its native dylib, tree-sitter grammars and parser worker by key from an absolute directory. `asset-root.ts`
sets it from the bundle's own location, so the payload can be copied anywhere in the app and still find
its parts, and the nested Mach-Os (the Bun binary, `libopentui.dylib`) are signed before the bundle so
notarization accepts them.

**The payload is optional at build time.** A checkout that cannot fetch Bun still builds a working Synth:
`MarkdownSession.isAvailable` reports the payload absent, markdown rows stop being offered, and a clicked
`.md` link falls back to the OS handler — the behaviour from before this ADR.

## arm64 only, which is what Synth already is

The payload ships one architecture. This is not a new limitation: `vendor/fetch-cef.sh` takes the
`macosarm64` CEF distro and `dist.sh`'s `swift build` is host-arch, so the shipped app is already a single
arm64 slice. Adding x64 would mean a second ~70MB payload for a machine that could not run the rest of the
app. The lookup stays arch-keyed (`bun/<arch>/bun`, `@opentui/core-darwin-<arch>/libopentui.dylib`) so
adding a slice is a build-script change rather than a code change.

## Link routing stays in the app, behind one control-socket verb

The TUI keeps exactly one link decision of its own: a relative `.md` link is *navigation* and stays inside
the viewer, with a back stack. Everything else — web pages, `mailto:`, non-markdown files — is handed back
to Synth over the existing control socket as `link.open`, and the app's `openTerminalLink` decides as it
already does: loopback pages to the synth browser, other pages to the default browser, files through
`openFileLink`.

The alternative was to re-implement that routing in TypeScript. It is four lines of logic, which is
precisely why it would have drifted: two copies of a rule that only one of them owns. `link.open` is
answered before the control server's worktree guard, because routing a link needs no branch and the
document being read may sit outside every managed worktree.

## The surface is a choice, and the session model does not care which

Settings → Markdown picks between Synth's own document surface, a terminal editor, and the OS default.
A markdown row is "a session showing this document", not "a session running synth-md" — so choosing nvim
changes only the launch line, and the row, its persistence, its icon and its teardown are unchanged.

Editor detection reads the login shell's PATH (`ShellEnvironment`, already probed for agent detection)
rather than a list of install prefixes. That is not a refinement, it is the whole reason it works: on the
machine this was built on, `nvim` lives under `~/.local/share/bob/nvim-bin` because it is managed by bob,
and no plausible hint list contains that. The hints remain as a fallback for the window before the probe
resolves.

## Consequences

- Synth's download grows by roughly 70MB, nearly all of it the Bun binary.
- A second runtime is now shipped and must be kept current — a Bun release is a Synth release concern,
  and the pinned version has a stated reason that any bump has to re-establish.
- `SessionKind.markdown` decodes as a bogus agent on a Synth older than this change
  (`Model.swift`'s unknown-rawValue default). The row appears with a sparkle and never starts a process;
  it does not corrupt the snapshot, and re-opening on a current build restores it.
- The document surface cannot show proportional type or native text selection, and inline images depend
  on the terminal's graphics protocol.
