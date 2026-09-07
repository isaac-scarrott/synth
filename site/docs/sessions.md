# Sessions

A session is one live thing inside a branch. There are six kinds, they all run in that branch's checkout, and every one of them is something an agent can drive.

Press `⌘N` in a branch to open one. Every kind gets a row, a status, and a pane, and every kind runs with its working directory set to that branch's checkout.

## The kinds

|  |  |
|---|---|
| **Agent** | A coding agent. See [Agents](agents.md). |
| **Terminal** | A shell, on the GPU. `⌘T` opens one directly. |
| **Browser** | A real Chromium page in the pane, which you and your agent can both use. |
| **Inspect** | Chromium's DevTools for one browser session, as a pane of its own. |
| **Simulator** | A booted iPhone from the fleet you already have installed. |
| **Markdown** | A rendered document you can also edit, beside the agent that wrote it. |

## The browser

The browser is a real Chromium page, not a preview. It keeps a profile per project, so a login survives quitting Synth and survives cutting new branches, and it is the same page your agent drives through the [browser tools](tools.md).

Useful things it does that a preview cannot: `⌘F` finds in the page, right-click works, popups open as real windows so sign-in flows complete, and self-signed certificates on a local dev server are answerable rather than fatal.

### Comments

Turn on comment mode and click an element to leave a note on it. Notes accumulate as numbered pins rather than interrupting anyone, and `⌘⌥⏎` sends the batch to the agent the browser belongs to, with a screenshot and enough context to find the element again.

A comment names an element, not a coordinate, so a pin survives scrolling, resizing and the agent reloading the page underneath it. Leaving comment mode parks the batch rather than discarding it, and a batch is only cleared once it has actually been delivered.

### Conditions

`⌘⇧M` opens four menus that fail apart: the **screen** the page is emulated at, the **network**, the **CPU**, and the **theme** the page is told to prefer. Each rests at Normal, and closing the bar puts them all back. The numbers are Chromium's own presets.

## Inspect

`⌥⌘I`, the `</>` button, or right-click and choose Inspect. You get the real Chromium inspector as a session: a row, a pane you can move, and a split under the page it belongs to, which is the classic bottom dock except that it is a real pane. There is one per browser, and asking again returns to it.

## Simulator

A simulator session claims a device from the fleet you have installed, boots it, and streams its screen into the pane. You can tap, type, swipe and rotate it, and so can your agent.

Synth reads the device's own framebuffer rather than launching Simulator.app, so the session keeps working when that window would have been minimised, on another Space, or closed by Xcode. A device Synth booted is a device Synth shuts down; a device that was already running is left alone.

> Simulator sessions need a full Xcode installed, and can be switched off in **Settings ▸ Synth ▸ Integrations**.

## Markdown

Command-click any `.md` link, or run `synth <file>` in any Synth terminal, and the document opens as a session beside the agent that wrote it. Click a block to see its raw markdown with a cursor in it, click away and it renders again.

It saves as you go and watches the file, so an agent rewriting the document underneath you does not cost you what you were typing.

## The scratch terminal

`⌘⇧T` summons a full terminal in the branch you are in, over everything else. It is for the errand you finish and leave: an `aws sso login`, a one-off script.

It is deliberately *not* a session: it has no row in the sidebar and no status. Dismissing it kills it, and every summon is a fresh shell, which is what keeps the rule that nothing runs that the sidebar does not show. Escape closes it at an idle, empty prompt and otherwise reaches the shell, so vim and other full-screen programs work normally. Closing it while something is running confirms first, and names what it would end.

## Sessions that belong to other sessions

A browser an agent opened **belongs to** that agent. An inspect belongs to the browser it inspects. The owned session sits as a sibling row wearing its owner's mark, rather than indented underneath it, because the sidebar draws one level of nesting and this is a relation rather than a level.

What ownership decides:

- Comments made in a browser go to the agent that owns it. A browser you opened yourself belongs to nobody, and comments in it start an agent to receive them.
- Closing an owner closes what belongs to it, all the way down.
- An agent may drive any browser, and may close only the ones it opened.

**Attach to** and **Detach** make and break the relation for a browser. An inspect is born attached and stays that way.

## Splitting

Sessions can share the pane. `⌘⇧` with an arrow splits toward that arrow, `⌘⌥` with an arrow moves between panes, and `⌘⇧⏎` zooms one to fill the surface and back again. The full set is in the [keyboard reference](keyboard.md).

A split is owned by its branch and persists, so coming back to a branch gives you the layout you left. A split never crosses branches: everything on screen together is one branch's work.
